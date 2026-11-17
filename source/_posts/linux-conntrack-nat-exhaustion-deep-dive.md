---
title: 【性能调优】nf_conntrack 表满与 NAT 深度解析：为什么连接会「莫名超时」而服务端毫无日志
date: 2026-11-17 08:00:00
tags:
  - Java
  - Linux
  - 网络
  - conntrack
  - 性能调优
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】nf_conntrack 表满与 NAT 深度解析

## 前言

先说一个几乎每个 Java 后端都会遇到的现场：

- 客户端侧偶发 `ConnectException: Connection timed out`，概率 0.1%~1%，集中在高峰期；
- 服务端 QPS 曲线平稳，CPU、GC、线程池、连接数全部正常，业务日志一条报错都没有；
- `ping` 正常、`telnet` 偶尔失败、重试一次又能通；
- 运维说「网络没问题」，开发说「代码没问题」，最后靠重启某个节点"恢复"。

如果你在宿主机（或节点）上 `dmesg -T | grep conntrack`，大概率能看到这一行：

```text
nf_conntrack: table full, dropping packet
```

这就是本文要讲的主角：**Linux 连接跟踪表（conntrack）耗尽**。它不产生 RST、不进应用日志、不打满 CPU，只安静地把包丢掉，把故障伪装成"网络抖动"。

本文从内核表结构讲到 K8s Service 的 DNAT、从超时参数讲到 Java 侧连接池治理，最后给出可以直接抄的排查与治理模板。

---

## 一、conntrack 到底是什么

Linux netfilter 为了实现有状态防火墙和 NAT，必须"记住"每条连接。这个记忆就是 `nf_conntrack`：

```text
一条 conntrack entry 包含：
  - 原始方向五元组 (src ip, src port, dst ip, dst port, proto)
  - 回复方向五元组（NAT 改写后的）
  - 连接状态 status bits（SEEN_REPLY / ASSURED / CONFIRMED ...）
  - 超时时间 timeout（按协议/状态不同）
  - NAT 映射信息（SNAT/DNAT 的源或目的改写记录）
  - 扩展信息（helper、accounting、timestamp）
```

关键点：

1. **conntrack 在 netfilter 的 hook 上工作**，优先级 `NF_IP_PRI_CONNTRACK = -200`，比绝大多数 iptables 规则更早执行。所以包在进入你的 `INPUT` 链之前，就已经被记录（或已被丢弃）。
2. **它是"表"，不是"连接数"**。表容量由 `nf_conntrack_max` 控制，哈希桶数由 `nf_conntrack_buckets` 控制（默认 max/4）。
3. **每一条 entry 都要占内存**，含扩展约 300 字节量级，100 万条大约 300MB。这也是为什么"把 max 调到 1000 万"不是免费的。

查看当前用量：

```bash
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_buckets
ss -s          # 对比 TCP 连接总数，看是否"连接不多但表项很多"
```

一个非常典型的信号：`ss -s` 显示 established 只有 3000，而 `nf_conntrack_count` 已经是 60 万。说明**大量表项不是你以为的"业务连接"**（后面第五节会解释谁在吃表项）。

---

## 二、表满时到底发生了什么

### 2.1 丢包路径

当 `nf_conntrack_count` 达到上限，新包需要新建 entry 时会走 `nf_conntrack_alloc` 失败分支：

```text
nf_conntrack: table full, dropping packet
```

注意两个细节：

- **是 drop，不是 reject**。内核不会回 RST，客户端看到的是"没有响应"。
- 对于 TCP 的 SYN 包，客户端会按 SYN 重传退避（约 1s、2s、4s、8s…）继续尝试，直到 `connect()` 超时。于是故障表现就是 `connect timeout`，而且**每次重试可能落在不同后端**，看起来像"偶发"。

### 2.2 为什么应用层完全无感知

包在 PREROUTING 阶段就被丢了，根本没到 socket，所以：

- 服务端 `accept()` 不会返回，业务日志不会有记录；
- 服务端 `netstat/ss` 看不到这条连接；
- 服务端 CPU、GC、线程池全部正常；
- 只有**客户端**能看到超时，且 `tcpdump` 在服务端抓不到 SYN 到达（因为它被丢在了更前面）。

这就是这类问题最难排查的原因：**证据不在应用侧**。

### 2.3 与其他"连不上"的区分

| 现象 | 根因 | 客户端表现 | 服务端证据 |
|---|---|---|---|
| conntrack 表满 | 新 entry 分配失败，SYN 被丢 | connect timeout，重试可能成功 | dmesg 有 `table full`，`conntrack -S` 的 drop 增长 |
| accept 队列满 | 全连接队列溢出（backlog 太小/accept 太慢） | 部分 timeout，部分成功 | `ss -lnt` 的 `Recv-Q` 接近 `Send-Q`，`netstat -s` 的 listen overflows 增长 |
| 本地端口耗尽 | `connect()` 无可用源端口 | `Cannot assign requested address` | `ss -tan state time-wait` 数量巨大 |
| 后端不可达 | 路由/安全组/进程未监听 | connection refused 或 timeout | 服务端无监听，或 RST 可见 |
| NAT 端口耗尽 | SNAT 源端口池耗尽 | 随机 timeout | 网关侧 conntrack/NAT 日志 |

**这张表建议直接背下来**，面试和排障都用得上。

---

## 三、谁在偷偷吃表项

很多人以为"表项 ≈ 业务连接数"，实际差一个数量级。常见的放大器：

### 3.1 Kubernetes Service 的 DNAT

Pod 访问 `ClusterIP` 的 Service 时，kube-proxy（iptables/IPVS 模式）会做 DNAT。**每一条 Pod→Service 的连接都会在节点上创建 conntrack entry**，而且是双向两条 tuple。

更麻烦的是：

- 同一个 Pod 访问同一个 Service，如果**每次新建连接**，就是每次一条新 entry；
- hairpin（Pod 通过 Service 访问自己）会额外多一跳；
- 有 Service Mesh sidecar 时，一跳变两跳，entry 翻倍。

### 3.2 出口 NAT（SNAT）

访问外部 API（比如大模型 API、短信、支付网关）时，节点做 SNAT。**每条 HTTPS 连接一条 entry**，如果 SDK 每次请求都新建连接（很多 Python/Go 示例代码就是这么写的，Java 里 `new URL().openConnection()` 也是），QPS 1000 就是 1000 条/秒的新 entry。

### 3.3 短连接与健康检查

- Liveness/Readiness 探针每秒一次，如果每次新建 TCP；
- 监控采集、日志上报、配置中心长轮询（长轮询断开重连）；
- DNS 查询走 UDP，默认 `nf_conntrack_udp_timeout=30`，高 QPS 下也会占不少；
- 数据库/Redis 客户端没有池化，或者池的 `maxIdle` 设置导致频繁销毁重建。

### 3.4 一条经验公式

```text
表项峰值 ≈ Σ(每类连接的 新建速率 × 该类连接的平均存活时间) + 长连接总数
```

比如：

- 出口 HTTPS 短连接 500/s，平均存活 60s（TIME_WAIT 被跟踪）→ 3 万条；
- Pod→Service 短连接 2000/s，存活 120s → 24 万条；
- 长连接 2 万条 → 2 万条；
- UDP DNS 5000/s × 30s → 15 万条。

加起来 44 万，而默认 `nf_conntrack_max` 在不少发行版上只有 65536 或 262144。**表满几乎是必然的。**

---

## 四、观测与定位命令

### 4.1 三个必看计数

```bash
# 当前/上限
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 内核统计（重点看 insert_failed / drop / early_drop / invalid）
conntrack -S
```

输出示例：

```text
cpu=0  found=0 invalid=0 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=0
cpu=3  found=88213 invalid=12 insert=9921 insert_failed=147 drop=147 early_drop=31 error=0 search_restart=8821
```

字段含义：

- `insert_failed`：插入失败（通常是表满或哈希冲突后重试失败）；
- `drop`：直接丢弃的包；
- `early_drop`：表使用率超过 7/8 时，内核开始主动丢弃 **UNREPLIED**（只看到单向包）的 entry 来腾位置；
- `invalid`：状态机判定非法的包（常见于 NAT 设备提前删表项后，后续包变成 INVALID）。

### 4.2 看是谁在占表项

```bash
# 按目的端口聚合，找出 TOP 消耗者
conntrack -L -p tcp --dport 443 2>/dev/null | wc -l

conntrack -L -o extended 2>/dev/null \
  | awk '{print $5}' | sed 's/dport=//' | sort | uniq -c | sort -rn | head -20
```

注意 `conntrack -L` 在大表上很慢且有性能开销，**生产上不要在高峰期全量 dump**，可以抽样或用 `conntrack -C`（计数）。

### 4.3 容器里的坑

`/proc/sys/net/netfilter/*` 是 **network namespace 隔离**的。在 Pod 里看到的 `nf_conntrack_count` 是 Pod 自己 netns 的（通常很小甚至为 0），**看不到宿主机那张表**。

正确做法：

```bash
# 在节点上，进入宿主 netns
nsenter -t 1 -n conntrack -S
# 或者用 node-exporter 的 node_nf_conntrack_entries 指标
```

Prometheus 里可以直接用：

```promql
node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
```

---

## 五、超时参数：那张必须记住的表

```bash
sysctl -a | grep nf_conntrack
```

| 参数 | 默认值 | 含义 | 调小的风险 |
|---|---|---|---|
| `nf_conntrack_tcp_timeout_established` | 432000（5 天） | 已建立连接的空闲超时 | 长连接被提前删除，后续包变 INVALID |
| `nf_conntrack_tcp_timeout_time_wait` | 120 | TIME_WAIT 状态 | 同上 |
| `nf_conntrack_tcp_timeout_close_wait` | 60 | CLOSE_WAIT | 应用未 close 时被清掉 |
| `nf_conntrack_tcp_timeout_fin_wait` | 120 | FIN_WAIT | 同上 |
| `nf_conntrack_tcp_timeout_syn_sent` | 120 | SYN_SENT | 握手慢的链路会被误杀 |
| `nf_conntrack_udp_timeout` | 30 | UDP 单向 | DNS 响应慢时丢包 |
| `nf_conntrack_udp_timeout_stream` | 180 | UDP 双向流 | 音视频/QUIC 受影响 |
| `nf_conntrack_icmp_timeout` | 30 | ICMP | 影响 ping/traceroute |

**最经典的故障组合**：

```text
云厂商 NAT 网关 / SLB 的空闲超时 = 300s
应用连接池 keepAlive = 不设置（或 60s 但没有探测包）
conntrack established 超时 = 432000s
```

结果：连接在中间设备上已经失效，但两端都以为还活着。下一次请求发出去，服务端回 RST 或者包被丢弃，客户端表现为"偶发 timeout / connection reset"。**这类问题必须靠应用层 TCP keepalive 或心跳解决，不能靠调 conntrack 超时。**

---

## 六、治理方案对比

| 方案 | 做法 | 优点 | 代价/风险 |
|---|---|---|---|
| 扩表 | `nf_conntrack_max=1048576`，同步调 `buckets` | 立竿见影 | 内存上涨；只治标；哈希冲突可能升高 CPU |
| 缩短超时 | `tcp_timeout_established=3600` | 快速回收 | 长连接可能被误删；需小于中间设备超时 |
| 应用长连接 | HTTP/DB/Redis 连接池 + keepalive | 从源头减少新建 | 需要改代码；要处理连接失效重连 |
| NOTRACK | `iptables -t raw -j CT --notrack` | 特定流量不进表 | 该流量失去 NAT/状态防火墙能力，慎用 |
| 减少 DNAT 跳数 | 同命名空间直连 Pod/Pod IP、Service 内部直连 | 表项减半 | 牺牲服务发现抽象 |
| eBPF / Cilium | 用 eBPF 做 Service 转发，绕过 conntrack | 性能好、可观测强 | 架构改造成本高 |
| 出口代理集中 | 统一出口网关做连接池 | 收敛连接数 | 多一跳，需要高可用 |

**推荐顺序**：先量化（谁在吃表）→ 应用侧长连接治理 → 扩表兜底 → 再考虑架构级方案。**只扩表不治理，等于把炸弹埋得更深。**

---

## 七、Java 侧落地：把连接数管住

### 7.1 统一 HTTP 客户端（OkHttp）

```java
@Configuration
public class HttpClientConfig {

    @Bean
    public OkHttpClient okHttpClient(MeterRegistry registry) {
        ConnectionPool pool = new ConnectionPool(200, 5, TimeUnit.MINUTES);

        OkHttpClient client = new OkHttpClient.Builder()
                .connectionPool(pool)
                .connectTimeout(Duration.ofSeconds(2))
                .readTimeout(Duration.ofSeconds(10))
                .writeTimeout(Duration.ofSeconds(10))
                .retryOnConnectionFailure(true)
                // 关键：让空闲连接定期发探测，避免被 NAT 静默回收
                .pingInterval(Duration.ofSeconds(30))
                .build();

        // 把连接池指标暴露出去，才能知道有没有泄漏
        registry.gauge("http.pool.connection.count",
                Tags.of("client", "okhttp"), pool, ConnectionPool::connectionCount);
        return client;
    }
}
```

三个要点：

1. `ConnectionPool(maxIdle, keepAlive)` 的 `maxIdle` 要和 QPS×RT 匹配，不要无脑 5；
2. `pingInterval` 是 **HTTP/2 的 PING 帧**，能穿透大多数 NAT，比 TCP keepalive 更可靠；
3. 一定要把 `connectionCount` 暴露成指标，否则"连接泄漏"你永远发现不了。

### 7.2 JDBC 与 Redis

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20        # 单实例连接数上限，不是越大越好
      minimum-idle: 5
      idle-timeout: 300000
      max-lifetime: 1200000        # 必须小于中间设备/数据库的 wait_timeout
      keepalive-time: 60000        # HikariCP 4.0.3+，定期探活
  data:
    redis:
      lettuce:
        pool:
          max-active: 32
          max-idle: 16
          min-idle: 4
          max-wait: 500ms
```

`max-lifetime` 是最容易被忽略的一项。MySQL 默认 `wait_timeout=28800`（8 小时），云数据库常常是 600s；如果 HikariCP 的 `max-lifetime` 大于它，就会出现"池里全是死连接"的经典故障。

### 7.3 出口流量收敛

访问外部大模型 API 时，最忌讳"每个请求 new 一个 client"。建议：

```java
// 按供应商/租户维度做连接数上限，避免一个租户打满出口
public final class UpstreamClientRegistry {
    private final Map<String, OkHttpClient> clients = new ConcurrentHashMap<>();

    public OkHttpClient get(String vendor) {
        return clients.computeIfAbsent(vendor, v -> new OkHttpClient.Builder()
                .connectionPool(new ConnectionPool(50, 5, TimeUnit.MINUTES))
                .connectTimeout(Duration.ofSeconds(3))
                .readTimeout(Duration.ofSeconds(60))   // 流式接口要更长
                .pingInterval(Duration.ofSeconds(30))
                .build());
    }
}
```

### 7.4 一个可直接用的 conntrack 指标采集器

```java
@Component
public class ConntrackMetrics {

    @Scheduled(fixedDelay = 15_000)
    public void collect(MeterRegistry registry) {
        long count = readLong("/proc/sys/net/netfilter/nf_conntrack_count");
        long max = readLong("/proc/sys/net/netfilter/nf_conntrack_max");
        if (max <= 0) {
            return;
        }
        registry.gauge("node.conntrack.usage.ratio", count / (double) max);
        registry.gauge("node.conntrack.count", count);
    }

    private long readLong(String path) {
        try {
            return Long.parseLong(Files.readString(Path.of(path)).trim());
        } catch (Exception e) {
            return -1;
        }
    }
}
```

注意：这段代码在**宿主机进程**里有效；在 Pod 里读到的是 Pod 自己的 netns，意义不大。容器场景请用 node-exporter。

---

## 八、生产踩坑清单

1. **改了 `nf_conntrack_max` 没调 `buckets`**：表大了但桶没变，哈希链变长，`search_restart` 飙升，CPU 反而更高。经验值 `buckets = max/4`，并且是 2 的幂。
2. **只扩表不治理**：表从 26 万扩到 100 万，两周后又满，而且这次满了更难受（内存被吃掉 300MB+）。
3. **容器内 sysctl 不生效**：`net.netfilter.nf_conntrack_max` 在容器里改的是容器 netns；要改宿主机必须 privileged + hostNetwork，或者直接在节点上配。
4. **忽略了云负载均衡的连接上限**：SLB/NAT 网关也有并发连接数和新建连接数（CPS）上限，超过同样是 timeout，和你自己的 conntrack 无关。
5. **`conntrack -L` 当成日常监控**：大表上全量遍历会持锁，可能造成业务抖动。用 `-S` 统计和 `-C` 计数。
6. **NAT 超时与应用心跳不匹配**：这是"偶发 timeout"的头号原因，排查时先对齐三处超时（客户端、中间设备、服务端），而不是先怀疑代码。

---

## 九、面试追问

**Q1：conntrack 表满为什么表现为超时，而不是 connection refused？**

因为丢包发生在 netfilter 的 PREROUTING 阶段，内核直接 `drop`，不会构造 RST。客户端收不到任何响应，只能等 SYN 重传耗尽后超时。`refused` 的前提是目标主机回了 RST（端口未监听）。

**Q2：为什么 `tcp_timeout_established` 默认是 5 天？**

因为内核无法区分"空闲的长连接"和"死连接"，保守地给一个很长的时间，避免误删合法连接。真正的回收责任在应用层（keepalive/心跳）和中间设备（NAT 超时）。

**Q3：`early_drop` 和 `drop` 有什么区别？**

表使用率超过 7/8 时，内核会主动丢弃 `UNREPLIED`（未收到回包）的 entry 来腾空间，计入 `early_drop`；真正分配失败丢弃包计入 `drop`。看到 `early_drop` 增长，说明已经进入"亚健康"状态，比 `drop` 更早预警。

**Q4：K8s 里 Pod 访问 Service，一条连接会产生几条 conntrack entry？**

iptables 模式下通常是 2 条 tuple（原始方向 + 回复方向）在同一个 entry 里，但 DNAT 会额外记录 reply tuple 的改写。若经过 sidecar 或 hairpin，跳数增加，entry 数量随之增加。经验上按"每条逻辑连接 1 条 entry、每多一跳 +1"估算即可。

**Q5：NAT 环境下为什么必须做应用层 keepalive？**

因为 NAT 设备只维护"最近活跃"的映射，空闲超时（常见 300s）后静默删表。之后原连接上的包会被判为 INVALID 或找不到映射而丢弃。TCP keepalive 默认 2 小时才发，来不及；必须用应用层心跳（HTTP/2 PING、Redis PING、连接池探活）把间隔压到分钟级以内。

---

## 总结

conntrack 表满是一个"沉默的杀手"：它不报错、不打日志、不打满 CPU，只让少量连接凭空消失。要治它，记住三件事：

1. **先量化**：`nf_conntrack_count / max`、`conntrack -S` 的 `drop/early_drop`、按端口的 TOP 消耗者；
2. **再收敛**：HTTP/DB/Redis 全部池化 + 应用层心跳，把"新建速率 × 存活时间"压下来；
3. **最后兜底**：扩表要同步扩 buckets，并且知道它只是止痛药。

下次再遇到"服务端一切正常但客户端偶发 timeout"，先去节点上敲 `dmesg | grep conntrack`，可能比翻一整天代码更快。
