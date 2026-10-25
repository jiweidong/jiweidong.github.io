---
title: 【Nginx 实战】upstream 负载均衡、长连接与被动健康检查深度实战
date: 2026-10-25 08:00:00
tags:
  - Nginx
  - 负载均衡
  - 长连接
  - 中间件
  - 高可用
  - Java
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】upstream 负载均衡、长连接与被动健康检查深度实战

## 前言

一个很典型的生产事故：Java 服务扩到 8 个实例，QPS 上去了，但 P99 延迟反而从 40ms 涨到 300ms，`netstat` 一看 TIME_WAIT 上万，Nginx error.log 里零星出现：

```
upstream prematurely closed connection while reading response header from upstream
```

排查半天发现三个配置问题叠在一起：`upstream` 没开 `keepalive`、`proxy_http_version` 还是 1.0、后端 Tomcat 的 `keep-alive-timeout` 比 Nginx 短。于是每次请求都是「新建 TCP → 后端已经准备关连接 → 撞上关闭窗口」的恶性组合。

这篇把 Nginx `upstream` 这一层从**算法选型 → 长连接池 → 健康检查 → 故障排查**串起来，重点讲清楚「配置项之间的相互制约」，而不是罗列指令。

---

## 一、负载均衡算法：不是选最花的，是选最匹配的

```nginx
upstream order_service {
    least_conn;
    server 10.0.0.11:8080 weight=3 max_fails=2 fail_timeout=10s;
    server 10.0.0.12:8080 weight=1;
    server 10.0.0.13:8080 backup;
    keepalive 64;
}
```

| 算法 | 指令 | 适用场景 | 关键缺点 |
|---|---|---|---|
| 轮询 | 默认 | 实例同构、请求耗时均匀 | 慢请求会堆积（长尾放大） |
| 加权轮询 | `weight=` | 机器配置不均、灰度放量 | 权重是静态的，不知道后端忙不忙 |
| 最少连接 | `least_conn` | 请求耗时差异大（报表、导出） | 突发流量下新实例会被瞬间打满 |
| IP 哈希 | `ip_hash` | 需要会话粘性、无共享 Session | NAT 出口后大量用户落同一台 |
| 一致性哈希 | `hash $key consistent` | 缓存分片、要求节点变动影响小 | key 选不好就会数据倾斜 |
| 随机二选一 | `random two least_conn` | 大规模实例（>20）且追求低开销 | 需要较新版本 Nginx |
| 最少耗时 | `least_time` | 需 Nginx Plus 或第三方模块 | 开源版不可用 |

几个生产经验：

1. **加权轮询的 `weight` 不是「按机器性能等比分配」的银弹**。Nginx 的平滑加权轮询（smooth weighted round-robin）确实能把长序列摊平，但它的假设是「请求成本相同」。如果你的接口里有 5% 的长耗时请求（比如导出 Excel），就该用 `least_conn`，否则那 5% 会全部压到权重最高的机器上。

2. **`ip_hash` 在现代架构里基本是技术债**。用户的 IP 在移动网络下频繁漂移，会话粘性并不可靠；正确做法是把 Session 外置（`spring-session-data-redis`），让 upstream 无状态。

3. **`slow_start` 只在商业版可用**，开源版做灰度要靠「先改权重到 1，观察 5 分钟再放大」的人工流程，或者用 Nginx 的 `split_clients` / OpenResty 动态 upstream（`balancer_by_lua`）。

4. `backup` 实例平时不接流量，**它上面的连接池是冷的**，切换瞬间会有一次明显的毛刺。所以「备用节点」也要定期做健康流量探活（哪怕 1 QPS）。

---

## 二、长连接：三个配置必须一起改，少一个都白搭

这是最容易踩的坑，因为「只改一半」不会报错，只会让你的 QPS 上不去、端口耗尽。

```nginx
upstream order_service {
    server 10.0.0.11:8080;
    server 10.0.0.12:8080;
    keepalive 64;                # ① 每个 worker 对每个 upstream 保留的空闲连接数
    keepalive_requests 10000;    # ② 单条连接最多复用多少次
    keepalive_timeout 60s;       # ③ 空闲连接存活时间
}

server {
    location /api/ {
        proxy_pass http://order_service;
        proxy_http_version 1.1;              # ④ 必须显式设置，默认是 1.0
        proxy_set_header Connection "";      # ⑤ 必须清空，否则发 Connection: close
        proxy_set_header Host $host;
    }
}
```

**为什么 ④⑤ 是必须的？** 因为 `proxy_set_header Connection close;` 是 Nginx 的默认行为（历史原因，为了兼容不支持 keep-alive 的后端）。HTTP/1.0 不支持持久连接，只有显式声明 `1.1` 且不发送 `Connection: close`，Nginx 才会把连接放回池子。

### 连接池大小怎么算

`keepalive` 的值不是一个「越大越好」的参数，用 Little's Law 估算：

```
需要的空闲连接数 ≈ QPS_per_worker × 平均响应时间(s)
```

假设单 worker 承载 800 QPS，平均 RT 30ms：`800 × 0.03 ≈ 24`。考虑到流量的尖峰和 RT 抖动，取 2~3 倍，`keepalive 64` 是合理值。设成 1024 只会让你的后端 Tomcat 的 `max-connections` 提前打满——**连接数是被后端限制的，不是被 Nginx 限制的**。

### 三个超时参数的「寿命对齐」原则

| 参数 | 位置 | 建议关系 |
|---|---|---|
| `keepalive_timeout`（upstream 块） | Nginx → 后端 空闲连接 | **小于**后端的空闲超时 |
| `server.tomcat.keep-alive-timeout`（Spring Boot） | 后端 空闲超时 | 基准，建议 60s |
| `proxy_read_timeout` | Nginx 等响应 | 大于后端 P99 RT，不要用默认 60s 糊弄一切 |
| `keepalive_requests` | 单连接复用次数 | 小于后端 `maxKeepAliveRequests` |

**核心原则：让 Nginx 先关，别让后端先关。** 如果后端先关，Nginx 的连接池里会残留一批「已死连接」，下一个请求打上去就是 502，这就是 `upstream prematurely closed connection` 的根因。

Spring Boot 侧对应配置：

```yaml
server:
  tomcat:
    threads:
      max: 200
    max-connections: 8192
    accept-count: 200
    keep-alive-timeout: 60s      # 要比 Nginx 的 upstream keepalive_timeout 长
    max-keep-alive-requests: 1000
```

---

## 三、被动健康检查：`max_fails` 的语义和它的坑

开源版 Nginx 只有**被动**健康检查：不主动探活，而是靠真实请求的失败来判定。

```nginx
upstream order_service {
    server 10.0.0.11:8080 max_fails=3 fail_timeout=15s;
    server 10.0.0.12:8080 max_fails=3 fail_timeout=15s;
}
```

语义是：在 `fail_timeout` 窗口内失败 `max_fails` 次 → 标记为不可用 `fail_timeout` 时长 → 之后再放一个请求去试探（半开）。`max_fails=0` 表示关闭该机制。

**坑 1：什么算「失败」由 `proxy_next_upstream` 决定。**

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504 non_idempotent;
proxy_next_upstream_tries 2;
proxy_next_upstream_timeout 5s;
```

默认配置**不包含** `non_idempotent`，也就是说 POST 请求在连接失败时**不会**重试到下一台——这是救命的设计。如果你为了「提高成功率」加上 `non_idempotent`，等于给所有写接口开了自动重放，重复下单、重复扣款会立刻出现。

正确姿势是**后端做幂等**，然后再谨慎开启重试：

```java
@PostMapping("/orders")
public Result create(@RequestBody CreateOrderReq req,
                     @RequestHeader(value = "Idempotency-Key", required = false) String key) {
    // 1) 唯一索引兜底：uk_idempotency_key
    // 2) Redis SETNX 预占，TTL 24h
    if (key == null) {
        throw new BizException("缺少 Idempotency-Key");
    }
    Boolean first = redis.opsForValue().setIfAbsent("idem:" + key, "1", Duration.ofHours(24));
    if (Boolean.FALSE.equals(first)) {
        return Result.ok(orderService.findByKey(key)); // 直接返回上次结果
    }
    return Result.ok(orderService.create(req));
}
```

**坑 2：`fail_timeout` 同时是两个时间。** 它既是「统计失败的窗口」，也是「摘除后多久再试」。设成 10s 意味着：坏节点每 10 秒会被放一个真实用户请求进去（半开探测），这个用户会超时。所以健康检查的「粒度」不能太细，否则用户侧会持续有零星失败。

**坑 3：节点被摘除后没有告警。** Nginx 没有原生指标暴露「哪个 upstream 当前不可用」，需要靠 `stub_status`（全局粒度）+ 日志分析（`$upstream_addr`、`$upstream_status`）自己聚合。一个可用的采集方案：

```nginx
log_format upstream_log '$remote_addr - $host "$request" $status '
                        'upstream=$upstream_addr status=$upstream_status '
                        'rt=$request_time urt=$upstream_response_time '
                        'cache=$upstream_cache_status';
```

然后用 Filebeat → ES 聚合 `status` 里出现 `502, 503` 的 `upstream_addr`，超过阈值告警。**`$upstream_addr` 在一次请求重试时会变成逗号分隔的列表（如 `10.0.0.11:8080, 10.0.0.12:8080`），说明发生了切换**，这个字段是定位「到底是哪台挂了」的关键。

### 想要主动健康检查怎么办

| 方案 | 优点 | 代价 |
|---|---|---|
| Nginx Plus | 原生 `health_check` + 动态 API | 收费 |
| `nginx_upstream_check_module`（淘宝） | 开源、支持主动探测 | 需重新编译 Nginx |
| OpenResty + `lua-resty-healthcheck` | 灵活、可动态摘除 | 引入 Lua 技术栈 |
| K8s Service + readinessProbe | 由平台接管摘除 | 依赖容器编排 |
| APISIX / Envoy | 原生主动健康检查 + 动态配置 | 换网关 |

**如果跑在 Kubernetes 上，强烈建议把健康检查交给 readinessProbe**，Nginx 只做纯转发（或者用 Ingress Controller）。因为 K8s 的 Endpoints 摘除是「控制面级别」的，比 Nginx 被动探测快一个数量级，而且不会把探测请求打到真实用户身上。

---

## 四、故障排查：三个高频现场

### 现场 1：TIME_WAIT 暴涨

```bash
ss -s
# TCP: 12034 (estab 3200, closed 8100, orphaned 0, timewait 7900)
```

`timewait` 占 `closed` 的绝大部分，且 `estab` 很低 → 典型的「短连接」。检查：

```bash
# 确认 Nginx 是否真的在复用连接
ss -tn state established '( dport = :8080 )' | wc -l
# 如果是 QPS 级别而不是几十条，说明 keepalive 没生效
```

九成原因是 `proxy_http_version 1.1` / `Connection ""` 没配。少数原因是后端自己在响应头里返回了 `Connection: close`（Tomcat 在 `maxKeepAliveRequests` 用尽时会这么做）。

### 现场 2：长尾延迟，P99 抖动

先看 `$upstream_response_time` 与 `$request_time` 的差值：

- 差值大 → 时间花在 Nginx 与客户端之间（带宽、客户端慢、`proxy_buffering` 问题）
- `upstream_response_time` 本身大 → 后端问题
- `upstream_response_time` 出现**多个值**（`0.003, 0.820`）→ 发生了 upstream 重试，第一台超时了

```nginx
proxy_connect_timeout 2s;   # 连接超时应该远小于读超时
proxy_send_timeout 10s;
proxy_read_timeout 30s;     # 按业务 P99 设，不要照抄 60s
proxy_next_upstream_timeout 0;  # 整个重试过程的总时间预算
```

`proxy_next_upstream_timeout 0` 表示不限制总重试时间——这是个隐患，用户可能要等 `tries × read_timeout`。建议设成 `proxy_read_timeout` 的一半。

### 现场 3：502 Bad Gateway 但是后端活着

三件事按顺序查：

1. **`upstream prematurely closed connection`** → 连接池里的死连接（后端先关），按第二节的对齐原则修。
2. **`connect() failed (111: Connection refused)`** → 后端 `accept` 队列满或进程在重启。看 Tomcat `accept-count` 和 `max-connections`。
3. **`no live upstreams`** → 所有节点都被 `max_fails` 摘除了。这时候要做的是**立即把 `max_fails` 临时设为 0 恢复流量**，而不是继续排查配置。这类事故的典型触发条件是后端整体响应变慢（比如 DB 抖动），Nginx 把「慢」判定成「死」，然后把整组打挂——**`proxy_read_timeout` 设置过小是元凶**。

---

## 五、面试追问

**Q1：Nginx 的 `keepalive` 参数是「总连接数」还是「空闲连接数」？**
是每个 worker 进程、对每个 upstream 保留的**空闲连接数上限**。它不限制并发连接总数，超出时多出的连接会被关闭而不是排队。所以它不是限流参数。

**Q2：为什么 `proxy_next_upstream` 默认不给 POST 重试？**
因为 HTTP 语义上 POST 非幂等，重试可能导致重复副作用。Nginx 只有在 `non_idempotent` 被显式加入时才会重试，这是「安全默认值」的设计。

**Q3：upstream 里同一个 server 写两次会怎样？**
会被当成两个独立的 peer，流量翻倍。有人用这招做「权重 2」的等价写法，但 `weight=2` 才是正确做法，重复写会破坏 `max_fails` 的统计（两个 peer 各自计数）。

**Q4：`proxy_buffering` 开和关的取舍？**
默认开：Nginx 先把响应缓冲到磁盘/内存再发给客户端，能快速释放后端连接（对 keepalive 复用极其重要），但会增加首字节延迟并占用磁盘。SSE/流式接口必须关（`proxy_buffering off`），否则流会被「攒」起来。

**Q5：如何在不停机的情况下摘除一个节点？**
Nginx 开源版没有动态 API。做法是：把该节点 `weight` 改为 0（需要 `nginx -s reload`，reload 是平滑的，老 worker 处理完存量请求后退出），或者用 `down` 标记。`reload` 期间新老 worker 并存，连接池会重建，所以**不要在流量高峰做批量 reload**。

---

## 六、上线检查清单

- [ ] `upstream` 有 `keepalive`，且 `proxy_http_version 1.1` + `Connection ""` 都配了
- [ ] `keepalive_timeout` < 后端 `keep-alive-timeout`（让 Nginx 先关）
- [ ] `proxy_read_timeout` ≥ 后端 P99 RT × 2，不是拍脑袋的 60s
- [ ] `proxy_connect_timeout` ≤ 2s（连接阶段不该慢）
- [ ] `proxy_next_upstream` 不含 `non_idempotent`，或后端已完整幂等
- [ ] `max_fails` / `fail_timeout` 组合经过压测，不会「整体变慢 → 全组摘除」
- [ ] 日志含 `$upstream_addr` `$upstream_status` `$upstream_response_time`，并有聚合告警
- [ ] 流式接口（SSE/下载）单独 location，关闭 `proxy_buffering`
- [ ] 是否可以用 K8s readinessProbe 替代被动检查

Nginx 这一层的调优，本质是**在「连接复用」和「故障发现速度」之间找平衡**。连接复用越彻底，死连接残留的风险越大；健康检查越激进，误摘除的概率越高。把上面这些参数的相互制约理清楚，比背指令有用得多。
