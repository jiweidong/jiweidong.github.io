---
title: 【生产实战】HTTP 连接池与 keep-alive 治理深度实战：TIME_WAIT、连接复用与超时三件套
date: 2026-10-23 08:10:00
tags:
  - Java
  - HTTP
  - 连接池
  - 性能优化
  - 生产踩坑
categories:
  - Java 进阶
author: 东哥
---

# 【生产实战】HTTP 连接池与 keep-alive 治理深度实战

## 前言

先看一段线上真实日志（脱敏）：

```
java.net.SocketException: Connection reset
    at java.base/sun.nio.ch.SocketDispatcher.read0(Native Method)
    ...
Caused by: java.io.IOException: 你的主机中的软件中止了一个已建立的连接
```

同时监控上出现：QPS 没涨，但接口 P99 从 80ms 涨到 2s；机器 `ss -s` 显示 `TIME_WAIT` 两万多个；下游服务说「我没报错啊」。

这三个现象连在一起，90% 是**连接池 + keep-alive 配置错配**。这类问题不会在功能测试里暴露，只会在有流量、有网络抖动、有中间设备（NAT / 防火墙 / SLB）的环境里集中爆发。

这篇文章把 HTTP 连接的完整生命周期、连接池参数、超时三件套、TIME_WAIT 治理、以及排障命令一次讲清。

---

## 一、先搞清楚一条连接的一生

```
TCP 三次握手 → TLS 握手（HTTPS）→ 发送请求 → 读取响应 → 连接归还/复用 → 空闲 → 关闭
                                    ↑                          ↓
                                    └──── keep-alive 复用 ─────┘
```

关键点在于：**HTTP 本身是无状态的，连接复用是 HTTP/1.1 的默认行为**。

```
HTTP/1.1 默认：Connection: keep-alive（持久连接）
HTTP/1.0 默认：Connection: close（每次新建）
HTTP/2   ：多路复用，一条连接并发多个请求流
```

一次 HTTPS 请求的成本构成（粗算）：

| 阶段 | 耗时量级 | 说明 |
|---|---|---|
| DNS 解析 | 0–50ms | 有缓存则接近 0 |
| TCP 三次握手 | 1×RTT | 同机房 0.5ms，跨地域 30ms+ |
| TLS 1.2 握手 | 2×RTT | TLS 1.3 降到 1×RTT |
| 请求 + 响应 | 业务耗时 | — |

也就是说，复用连接能省掉 **握手 + TLS**，在同机房能省 1–3ms，在跨地域能省 **60–100ms**。这就是为什么连接池不是「优化项」而是「必选项」。

---

## 二、Connection reset 的真正原因：空闲连接竞态

这是最经典、也最容易被误判为「下游不稳定」的问题。

时序如下：

```
T0: 客户端建立连接，请求完成，连接进入池中空闲（idle）
T1: 客户端池认为连接还有效（默认不校验）
T2: 服务端 / NAT / 防火墙 / SLB 认为空闲超时，主动发 FIN 或直接丢弃连接表项
T3: 客户端从池中取出这条「看起来活着」的连接，write 请求
T4: 读到 RST → SocketException: Connection reset
```

核心矛盾：**客户端 idle 超时 > 服务端（或中间设备）keep-alive 超时**。

常见设备的默认值：

| 组件 | 参数 | 常见默认值 |
|---|---|---|
| Tomcat | `server.tomcat.keep-alive-timeout` | 20s（Spring Boot 3 起默认） |
| Nginx | `keepalive_timeout` | 75s |
| AWS ALB | idle timeout | 60s |
| 阿里云 SLB | 空闲超时 | 900s（可配） |
| Linux conntrack | `nf_conntrack_tcp_timeout_established` | 432000s（5 天）但 NAT 常更短 |

结论：**客户端的 idle 超时必须明显小于链路中最短的那个 keep-alive 超时**，一般取 1/3 到 1/2，并配合「取用前校验」。

### 2.1 三个层次的解法

| 层次 | 手段 | 效果 |
|---|---|---|
| 配置层 | 客户端 idle 超时 < 服务端 keep-alive 超时 | 避免大部分竞态 |
| 校验层 | `validateAfterInactivity` / `evictIdleConnections` | 取用前探活，捕获残余竞态 |
| 协议层 | 重试（幂等请求）+ 关闭 `stale connection` | 兜底 |

---

## 三、连接池参数：以 Apache HttpClient 5 为例

Spring Boot 3 的 `RestClient` 底层常用 Apache HttpClient 5 或 JDK `HttpClient`。生产上更可控的是显式配置 `PoolingHttpClientConnectionManager`。

```java
@Configuration
public class HttpClientConfig {

    @Bean
    public CloseableHttpClient httpClient() {
        PoolingHttpClientConnectionManager cm = new PoolingHttpClientConnectionManager(
                RegistryBuilder.<ConnectionSocketFactory>create()
                        .register("http", PlainConnectionSocketFactory.getSocketFactory())
                        .register("https", SSLConnectionSocketFactory.getSocketFactory())
                        .build(),
                30, TimeUnit.SECONDS,          // timeToLive：连接最大存活时间
                30, TimeUnit.SECONDS           // pending：等待获取连接的超时
        );

        cm.setMaxTotal(200);                   // 全局最大连接数
        cm.setDefaultMaxPerRoute(50);          // 单路由（单 host:port）最大连接数
        cm.setValidateAfterInactivity(TimeValue.ofSeconds(5)); // 空闲 5s 后取用前校验

        RequestConfig rc = RequestConfig.custom()
                .setConnectTimeout(1000)               // 建连超时
                .setConnectionRequestTimeout(500)      // 从池中取连接的超时
                .setResponseTimeout(3000)              // 读超时（socket timeout）
                .build();

        return HttpClients.custom()
                .setConnectionManager(cm)
                .setDefaultRequestConfig(rc)
                .evictIdleConnections(TimeValue.ofSeconds(20))  // 后台清理空闲连接
                .evictExpiredConnections()
                .setRetryHandler(new DefaultHttpRequestRetryHandler(2, true)) // 幂等重试
                .build();
    }
}
```

### 3.1 参数怎么算，不要拍脑袋

| 参数 | 计算方式 | 说明 |
|---|---|---|
| `maxPerRoute` | `目标QPS × 平均RT(秒) × 冗余系数(1.5)` | 例：500 QPS × 0.05s × 1.5 ≈ 38 |
| `maxTotal` | `maxPerRoute × 下游host数量` | 有多个下游时按最大者估算 |
| `connectTimeout` | P99 建连耗时 × 2，一般 500–2000ms | 太大会让故障扩散 |
| `responseTimeout` | 下游 P99 × 2–3 | 必须小于上游对你的超时 |
| `connectionRequestTimeout` | 通常 200–1000ms | 拿不到连接要快速失败，别无限等 |
| TTL | 小于服务端连接最大存活 | 避免用到被服务端强杀的连接 |

**最容易被忽视的是 `connectionRequestTimeout`**：很多人只设了 connect/socket 超时，结果池被占满时线程在 `poll()` 上无限等待，表现为「接口卡死不报错」，比快速失败危险得多。

### 3.2 超时链必须逐级递减

```
网关 5s
  └─ 服务A 3s
       └─ 服务B 2s
            └─ 服务C 1s
```

如果下游超时比上游还长，故障时会形成**线程堆积 → 池耗尽 → 雪崩**。这是「超时三件套」之外必须遵守的第四条铁律：**超时预算逐级收敛**。

---

## 四、JDK HttpClient 的连接池

JDK 11+ 的 `java.net.http.HttpClient` 内置连接池，但**可调参数极少**（这是个真实痛点）：

```java
HttpClient client = HttpClient.newBuilder()
        .version(HttpClient.Version.HTTP_2)      // 默认 HTTP/2，自动降级
        .connectTimeout(Duration.ofSeconds(1))
        .executor(Executors.newVirtualThreadPerTaskExecutor()) // JDK 21+
        .build();

HttpRequest req = HttpRequest.newBuilder(URI.create(url))
        .timeout(Duration.ofSeconds(3))          // 只能设请求总超时
        .GET()
        .build();
```

限制：

- 没有 `maxTotal` / `maxPerRoute` 的公开配置（内部固定，无法调）；
- keep-alive 时长不可配；
- 只能通过系统属性 `jdk.httpclient.keepalive.timeout`（秒）做全局控制；
- HTTP/2 下多路复用会掩盖连接数问题，但单流阻塞仍会发生。

所以在需要精细控制的场景（高 QPS、多下游、需要连接数隔离），还是用 Apache HttpClient 5 或 OkHttp。

| 客户端 | 连接池可控性 | HTTP/2 | 虚拟线程友好 | 推荐场景 |
|---|---|---|---|---|
| Apache HttpClient 5 | 高 | 支持 | 是 | 生产主力，需要精细控制 |
| OkHttp | 中高 | 支持 | 是 | Android / 需要拦截器链 |
| JDK HttpClient | 低 | 默认开启 | 是 | 简单调用、内部工具 |
| Spring RestClient | 取决于底层 | 取决于底层 | 是 | Spring 项目统一门面 |

---

## 五、服务端视角：别只盯着客户端

连接是双方的事。服务端的三个参数同样关键。

```yaml
server:
  tomcat:
    threads:
      max: 200
    accept-count: 100
    max-connections: 8192
    keep-alive-timeout: 20s       # 空闲多久关闭
    max-keep-alive-requests: 100  # 一条连接最多复用多少次
```

`max-keep-alive-requests` 很多人不知道：达到次数后服务端会在响应头里带 `Connection: close`，客户端必须重建连接。设置过小会导致频繁重建（握手成本上升），过大则不利于负载均衡（连接长期压在同一个实例上）。

Nginx 侧：

```nginx
upstream backend {
    server 10.0.0.1:8080;
    keepalive 64;                 # 与上游保持的空闲连接数
    keepalive_requests 1000;
    keepalive_timeout 60s;
}
```

`s keepalive` 不配的话，Nginx 对上游默认是短连接，QPS 一高就是海量 TIME_WAIT。

---

## 六、TIME_WAIT 到底要不要治

先明确：**TIME_WAIT 是 TCP 的正常状态，不是 bug**。它的作用有两个：

1. 保证最后一个 ACK 能重传（防止被动关闭方收不到）；
2. 让旧连接的残余报文在网络中消亡，避免污染新连接（同四元组）。

主动关闭方会进入 TIME_WAIT，持续 `2×MSL`（Linux 固定 60s）。一条连接占一个本地端口，理论上限约 2.8 万（`net.ipv4.ip_local_port_range` 默认 32768–60999）。

**什么时候算问题？**

```bash
# 看总量与状态分布
ss -s
# TCP:   12345 (estab 800, closed 11000, orphaned 0, timewait 10500)

# 按对端聚合，找出「谁在制造 TIME_WAIT」
ss -tan state time-wait | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head

# 看端口范围
sysctl net.ipv4.ip_local_port_range
```

如果 `timewait` 持续 > 2 万且伴随 `Cannot assign requested address`，才是真问题。

### 6.1 正确的治理顺序

| 顺序 | 手段 | 说明 |
|---|---|---|
| 1 | **开连接池 / 提高复用** | 治本。短连接改长连接，TIME_WAIT 直接降一个数量级 |
| 2 | 让**服务端**主动关闭 | 主动关闭方承担 TIME_WAIT，把成本转移给连接数更少的服务端 |
| 3 | `net.ipv4.tcp_tw_reuse=1` | 允许复用 TIME_WAIT 连接发 SYN（仅对**客户端**出向连接有效，需时间戳开启） |
| 4 | 扩大 `ip_local_port_range` | 32768–60999 → 10240–65000 |
| 5 | `tcp_max_tw_buckets` | **不建议调小**，超限会直接 kill 连接并打日志 |
| ❌ | `tcp_tw_recycle` | Linux 4.12 起已移除，NAT 环境下会导致连接随机失败，绝对不要用 |

```bash
# 安全的 sysctl 调整（写入 /etc/sysctl.d/99-net.conf）
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_fin_timeout = 30
```

⚠️ 改 sysctl 前先 `sysctl -a | grep xxx` 看现值，并保留原配置，别整文件覆盖。

---

## 七、可观测：让连接池问题在监控上可见

黑盒排查太慢，必须埋点。Apache HttpClient 5 自带连接池指标：

```java
@Bean
public MeterBinder connectionPoolMetrics(PoolingHttpClientConnectionManager cm) {
    return registry -> {
        Gauge.builder("httpclient.pool.leased", cm, m -> m.getTotalStats().getLeased())
             .register(registry);
        Gauge.builder("httpclient.pool.available", cm, m -> m.getTotalStats().getAvailable())
             .register(registry);
        Gauge.builder("httpclient.pool.pending", cm, m -> m.getTotalStats().getPending())
             .register(registry);
        Gauge.builder("httpclient.pool.max", cm, m -> m.getTotalStats().getMax())
             .register(registry);
    };
}
```

四个指标对应的告警语义：

| 指标 | 异常表现 | 含义 |
|---|---|---|
| `leased` 接近 `max` | 长期 95%+ | 池太小，或下游变慢导致连接不释放 |
| `pending` > 0 持续 | 有排队 | 拿不到连接，即将超时 |
| `available` 长期 0 | 无空闲 | 同上 |
| 连接创建速率突增 | 频繁 new | keep-alive 错配，连接被反复重建 |

**最有用的一条**：`leased` 高 + `pending` 高 + 下游 RT 正常 → 池配置太小；`leased` 高 + 下游 RT 飙高 → 下游慢，先治下游。

---

## 八、排障速查表

```bash
# 1. 连接状态总览
ss -s

# 2. 某进程的所有 TCP 连接
ss -tanp | grep $(pgrep -f myapp)

# 3. 按状态统计
ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c

# 4. 抓包看 RST 是谁发的
tcpdump -i eth0 -nn 'tcp[tcpflags] & tcp-rst != 0' -c 50

# 5. 看 Java 线程卡在哪
jstack <pid> | grep -A 20 "httpclient\|SocketInputStream"

# 6. 看 DNS 是否成为瓶颈
jstack <pid> | grep -c "InetAddress"
```

如果 `tcpdump` 看到 RST 来自对端 IP，说明是服务端/中间设备主动拒绝；如果 RST 来自本机，通常是应用层关闭了已被对端关闭的连接。

---

## 九、面试高频追问

**Q1：HTTP/1.1 的 keep-alive 和 TCP 的 keepalive 是一回事吗？**
答：不是。HTTP keep-alive 是应用层的连接复用约定，通过 `Connection: keep-alive` 头协商；TCP keepalive 是传输层的探活机制（`SO_KEEPALIVE`），默认 2 小时才发第一个探测包，用于发现死连接，不能用于连接复用。两者名字像，作用完全不同。

**Q2：为什么 `connectionRequestTimeout` 比 `connectTimeout` 更需要关注？**
答：`connectTimeout` 管的是「建连」，失败会抛异常，是显性故障；`connectionRequestTimeout` 管的是「从池里拿连接」，不设的话线程会无限等待，表现为接口无响应、线程池打满，是隐性故障，更难排查。

**Q3：连接池越大越好吗？**
答：不是。连接数受下游承载能力约束，池过大只会把压力透传到下游，同时占用更多文件描述符和内存。正确做法是按 `QPS × RT × 1.5` 估算，并通过压测验证；下游是数据库时尤其要克制（数据库连接数上限通常很小）。

**Q4：TIME_WAIT 为什么必须存在 2MSL？**
答：一是保证被动关闭方在没收到最后一个 ACK 时能重传 FIN，主动方还能回 ACK；二是让本连接的所有报文在网络中过期消亡，避免同四元组的新连接收到旧报文。缩短 2MSL 会引入连接错乱风险。

**Q5：为什么 `tcp_tw_recycle` 被移除？**
答：它依赖时间戳做 PAWS 校验，在 NAT 环境下多个客户端共享同一公网 IP，时间戳不同步会导致服务端丢弃合法 SYN，表现为「部分用户随机连不上」。Linux 4.12 直接移除。

**Q6：HTTP/2 是否就不需要连接池了？**
答：仍然需要，但语义变了。HTTP/2 一条连接可并发多流，所以「连接数」不再是并发瓶颈，但仍有 `MAX_CONCURRENT_STREAMS` 限制、单连接 TCP 窗口限制、以及队头阻塞（TCP 层丢包会阻塞所有流）。连接池的作用从「提高并发」变成「故障隔离 + 流量分散」。

---

## 十、总结

| 问题 | 根因 | 解法 |
|---|---|---|
| `Connection reset` 偶发 | 客户端 idle > 服务端 keep-alive | idle 取 1/3，加 `validateAfterInactivity`，幂等重试 |
| 接口卡死不报错 | 未设 `connectionRequestTimeout` | 显式设置 200–1000ms，快速失败 |
| TIME_WAIT 暴涨 | 短连接 / 服务端不主动关 | 开池、服务端主动关、`tcp_tw_reuse=1` |
| 端口耗尽 | `ip_local_port_range` 太小 + 短连接 | 扩端口段 + 连接复用 |
| 故障雪崩 | 超时链倒挂 | 超时预算逐级递减 |
| 池长期打满 | `maxPerRoute` 太小 / 下游慢 | 按公式估算 + 监控 `leased/pending` |

HTTP 连接治理的本质，是**把「连接」当成一种有限资源来管理**：它有建立成本、有生命周期、有并发上限、有失效时机。把 idle 超时对齐、把超时三件套设全、把连接池指标接进监控，这三件事做完，80% 的「网络玄学问题」都会变成可解释、可复现、可治理的工程问题。
