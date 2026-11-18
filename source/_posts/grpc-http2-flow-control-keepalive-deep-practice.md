---
title: 【Java 网络】gRPC 流控、Keepalive 与长连接治理深度实战：WINDOW_UPDATE、GOAWAY 与生产参数
date: 2026-11-18 08:20:00
tags:
  - gRPC
  - HTTP/2
  - Java
  - 流控
  - 微服务
categories:
  - Java 进阶
author: 东哥
---

# 【Java 网络】gRPC 流控、Keepalive 与长连接治理深度实战

## 前言

gRPC 用起来很舒服：定义 proto、生成 stub、`blockingStub.call(req)` 一行搞定。但它把 HTTP/2 的复杂度藏了起来，一旦出问题，报错信息往往指向「超时」这个结果，而不是原因。

三种典型故障，本质都是 HTTP/2 连接层的问题：

- **流式接口中途卡死**，没有报错，就是不往下走；
- **服务端扩容后客户端大批 `UNAVAILABLE`**，几秒后自愈；
- **每隔 60 秒或 350 秒断一次连接**，日志里全是 `GOAWAY`。

这篇从 HTTP/2 的帧层讲起，把流控窗口、keepalive、连接池、优雅下线四件事串起来，最后给一份可以直接抄的参数表。

---

## 一、HTTP/2 帧层：gRPC 的地基

gRPC over HTTP/2 的最小帧集合：

| 帧类型 | 作用 | gRPC 中的意义 |
|---|---|---|
| `HEADERS` | 传输 header（HPACK 压缩） | 包含 `:method=POST`、`content-type=application/grpc`、`grpc-timeout` |
| `DATA` | 传输 body | 每个消息前缀 5 字节（1 字节压缩标志 + 4 字节长度） |
| `WINDOW_UPDATE` | 流量控制窗口更新 | 增量值，单位字节 |
| `SETTINGS` | 连接级参数协商 | `INITIAL_WINDOW_SIZE`、`MAX_CONCURRENT_STREAMS`、`MAX_FRAME_SIZE` |
| `RST_STREAM` | 终止单个流 | 对应 gRPC 的 `CANCELLED` |
| `GOAWAY` | 终止整个连接 | 对应客户端 `UNAVAILABLE`，是优雅下线的关键 |
| `PING` | 保活/测 RTT | keepalive 机制 |

一个 unary 调用的帧序列：

```
Client                          Server
  |-- SETTINGS ------------------>|
  |<------------------- SETTINGS --|
  |-- HEADERS (stream 1) -------->|
  |-- DATA (grpc-timeout=1s) ---->|
  |<------------------- HEADERS ---|   (200, content-type)
  |<------------------- DATA ------|
  |<------------------- HEADERS ---|   (trailers: grpc-status=0)
```

注意 **trailers**：gRPC 的状态码放在 HTTP/2 的 trailing HEADERS 里，而不是 HTTP 状态码。所以「HTTP 200 但业务失败」是常态，抓包时不能只看 `:status`。

---

## 二、流控：两个窗口，两条链路

HTTP/2 有**两级流量控制**：

1. **连接级窗口**：所有 stream 共享，初始 65535 字节；
2. **流级窗口**：每个 stream 独立，初始值由 `SETTINGS_INITIAL_WINDOW_SIZE` 决定（gRPC 默认也是 65535，但 grpc-java 会把目标窗口设到 1MB）。

发送方每发一个 `DATA` 帧就扣减窗口，接收方处理完数据后回 `WINDOW_UPDATE` 补充。**窗口耗尽时发送方必须停下**，这就是流控的本质。

### 2.1 为什么流式接口会「卡死」

经典场景：服务端流式推送（`StreamObserver`），客户端消费慢。

```
服务端：onNext(msg) × 1000  → 窗口耗尽 → 阻塞在 Netty 的 write
客户端：还在处理第 3 条消息，没有调用 request(1)
```

gRPC-java 的 `StreamObserver` **不会自动背压**。`onNext` 只是把消息放进队列，队列满后才开始阻塞。默认队列大小是 32，加上 1MB 窗口，意味着服务端可以先推 ~1MB 数据，然后彻底停住。

如果服务端是**单线程 event loop**（比如 `directExecutor()`），阻塞会直接卡死整个连接：这个连接上的其他 stream 也一起完蛋。

正确做法有三种：

**方案 1：手动流控（推荐）**

```java
// 客户端：显式请求，处理完再要下一条
StreamObserver<Chunk> responseObserver = new StreamObserver<>() {
    private ClientCallStreamObserver<Chunk> requestStream;

    @Override
    public void onNext(Chunk chunk) {
        try {
            process(chunk);            // 处理
        } finally {
            requestStream.request(1);  // 处理完再要一条
        }
    }
    // ...
};

ClientCallStreamObserver<Req> reqStream =
        (ClientCallStreamObserver<Req>) stub.download(req);
((ClientCallStreamObserver<Chunk>) ...).setOnReadyHandler(...);
reqStream.request(1);
```

**方案 2：加大窗口，接受内存代价**

```java
// 服务端：把目标窗口设大，适合「服务端推、客户端快」的场景
NettyServerBuilder.forPort(9090)
    .flowControlWindow(4 * 1024 * 1024)   // 4MB
    .build();
```

代价是每连接最多 4MB 缓冲 × 连接数。1000 连接就是 4GB，**必须算内存账**。

**方案 3：改用分页/拉模式**

把「服务端推」改成「客户端按游标拉」，用 unary 接口循环调用。牺牲实时性，换来可控的内存与重试语义。大批量数据导出场景通常这么干。

### 2.2 窗口大小与 BDP

窗口的物理意义是「在途未确认字节数」，必须 ≥ BDP（带宽时延积）：

```
BDP = 带宽(bps) × RTT(s) / 8   (字节)
```

例：跨地域 100Mbps、RTT 40ms → BDP = 100e6 × 0.04 / 8 = 500KB。

如果窗口只有 64KB，吞吐上限就是 `64KB / 0.04s = 1.6MB/s ≈ 13Mbps`，**带宽跑不满**。所以跨地域链路的 gRPC 流式传输，窗口至少要设到 1~4MB。

grpc-java 默认通过 BDP 探测自动调整连接级窗口（`NettyServerBuilder.flowControlWindow` 是初始值），但在高 RTT + 高带宽场景下探测偏保守，建议显式设置。

| 场景 | 建议窗口 | 理由 |
|---|---|---|
| 同机房 unary 小消息 | 默认 1MB | 够用，省内存 |
| 同机房流式（日志/事件） | 1~2MB | 平衡 |
| 跨地域流式 | 4~8MB | 满足 BDP |
| 移动端弱网 | 256KB~1MB | 避免内存放大 |

---

## 三、Keepalive：不是「有心跳就行」

gRPC 的 keepalive 是 HTTP/2 `PING` 帧，参数有三组：

| 参数 | 客户端 | 服务端 | 含义 |
|---|---|---|---|
| `keepAliveTime` | ✅ | ✅ | 空闲多久发 PING |
| `keepAliveTimeout` | ✅ | ✅ | 发 PING 后等多久算超时 |
| `permitKeepAliveTime` | — | ✅ | 服务端允许客户端的最小 PING 间隔 |
| `permitKeepAliveWithoutCalls` | — | ✅ | 无活跃调用时是否允许 PING |
| `maxConnectionIdle` | — | ✅ | 连接空闲多久发 GOAWAY |
| `maxConnectionAge` | — | ✅ | 连接最长存活时间 |
| `maxConnectionAgeGrace` | — | ✅ | 到龄后给多久排空 |

### 3.1 三个必须理解的默认值

**默认 1：客户端默认不开 keepalive。**

```java
// 默认 keepAliveTime = Long.MAX_VALUE，即不发 PING
ManagedChannel channel = ManagedChannelBuilder.forTarget("svc:9090")
        .usePlaintext()
        .build();
```

这意味着：连接被 LB/NAT 静默回收后，客户端**毫不知情**，下一次调用直接超时。这是「服务端重启后第一次请求必失败」的常见原因。

**默认 2：服务端默认 `permitKeepAliveTime = 5 分钟`。**

如果客户端把 `keepAliveTime` 设成 10 秒，服务端会认为是滥用，回 `GOAWAY` + `ENHANCE_YOUR_CALM`：

```
io.grpc.StatusRuntimeException: UNAVAILABLE: HTTP status code 503
  ... debug data: too_many_pings
```

**默认 3：`maxConnectionAge` 默认无限。**

服务端不会主动轮换连接，长连接可以活几天。这带来两个问题：一是负载不均（老连接一直压在某几个 Pod 上），二是滚动发布时连接迁移慢。

### 3.2 生产参数模板

**客户端**：

```java
ManagedChannel channel = NettyChannelBuilder.forTarget("dns:///order-svc:9090")
        .usePlaintext()
        // 30s 空闲发 PING，必须 ≥ 服务端 permitKeepAliveTime
        .keepAliveTime(30, TimeUnit.SECONDS)
        // 10s 内没收到 PING ACK 就判定连接死
        .keepAliveTimeout(10, TimeUnit.SECONDS)
        // 关键：没有活跃 RPC 时也发 PING，否则空闲连接照样被回收
        .keepAliveWithoutCalls(true)
        .maxInboundMessageSize(8 * 1024 * 1024)
        .build();
```

**服务端**：

```java
Server server = NettyServerBuilder.forPort(9090)
        // 允许客户端 10s 一次 PING（要小于客户端配置）
        .permitKeepAliveTime(10, TimeUnit.SECONDS)
        .permitKeepAliveWithoutCalls(true)
        // 连接最长活 30 分钟（带 10% 抖动），强制轮换，均衡负载
        .maxConnectionAge(30, TimeUnit.MINUTES)
        .maxConnectionAgeGrace(30, TimeUnit.SECONDS)
        // 空闲 5 分钟关闭
        .maxConnectionIdle(5, TimeUnit.MINUTES)
        .flowControlWindow(2 * 1024 * 1024)
        .build();
```

**核心规则：客户端 `keepAliveTime` ≥ 服务端 `permitKeepAliveTime`，且 < 链路上最短的空闲超时。**

### 3.3 中间设备的空闲超时

| 中间设备 | 默认空闲超时 | 说明 |
|---|---|---|
| AWS ALB | 60s | 可调至 4000s |
| AWS NLB | 350s | TCP 流空闲 |
| GCP TCP LB | 600s | |
| Azure LB | 4min（默认） | |
| Nginx `keepalive_timeout` | 75s | 只影响客户端侧 |
| NAT 网关 | 300s（常见） | 各家不同 |
| 容器 CNI conntrack | 5 天（ESTABLISHED） | 但 NAT 设备更短 |

取最小值，再打 1/2 折扣：

```
keepAliveTime = min(所有设备空闲超时) / 2
```

如果 ALB 是 60s，keepAliveTime 就该是 25~30s。

---

## 四、GOAWAY：优雅下线的正确姿势

`GOAWAY` 帧的语义是「我不再接受新 stream，但已存在的 stream 可以继续」。它带一个 `lastStreamID`，客户端据此判断哪些请求需要重试。

### 4.1 服务端滚动发布

K8s 滚动更新时，Pod 收到 `SIGTERM` 后如果直接退出，所有在途请求全部 `UNAVAILABLE`。正确流程：

```java
// 1. 收到 SIGTERM 后，先调用 server.shutdown()
Runtime.getRuntime().addShutdownHook(new Thread(() -> {
    // shutdown 会发送 GOAWAY，等待在途请求完成
    server.shutdown();
    try {
        // 等待期要小于 K8s terminationGracePeriodSeconds
        if (!server.awaitTermination(25, TimeUnit.SECONDS)) {
            server.shutdownNow();
        }
    } catch (InterruptedException e) {
        server.shutdownNow();
        Thread.currentThread().interrupt();
    }
}));
```

关键配套：

```yaml
# deployment.yaml
terminationGracePeriodSeconds: 40   # > shutdown 等待的 25s + 注册中心下线时间
```

还有一个坑：**K8s 会同时发 SIGTERM 和移除 Endpoints**。如果 Endpoints 移除有延迟（kube-proxy 规则更新需要时间），会有一小段时间新流量还在打到正在关停的 Pod。

标准解法是加一个 `preStop` 钩子做延迟：

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
```

这 5 秒让 kube-proxy / Ingress 把该 Pod 从后端摘掉，然后再开始优雅关闭。

### 4.2 客户端如何应对 GOAWAY

grpc-java 内置了重试逻辑：收到 GOAWAY 后，对**未被服务端处理**的 stream（streamID > lastStreamID）自动重试到新连接。被处理过的 stream 会返回 `UNAVAILABLE`。

所以业务代码必须处理 `UNAVAILABLE`：

```java
// 只对幂等操作重试，且必须配退避
RetryPolicy retryPolicy = RetryPolicy.newBuilder()
        .setMaxAttempts(3)
        .setInitialBackoff(Duration.ofMillis(100))
        .setMaxBackoff(Duration.ofSeconds(2))
        .setBackoffMultiplier(1.5)
        .setRetryableStatusCodes(Set.of(Code.UNAVAILABLE))
        .build();

// 或者在拦截器里做统一重试，避免每个调用点写一遍
```

**注意**：grpc-java 的重试是「透明重试」，只对 `UNAVAILABLE` 且**请求未发出**的情况生效。如果请求已发出、服务端已处理、只是响应丢了，重试会导致重复执行。写操作必须靠业务侧幂等键兜底。

### 4.3 `maxConnectionAge` 的抖动

如果所有客户端同时建立连接，且服务端 `maxConnectionAge` 相同，会导致**同一时刻大批连接同时被 GOAWAY**，形成周期性抖动。

grpc-java 的 `maxConnectionAge` 自带 ±10% 抖动，但连接建立时间本身是聚集的。更稳的做法：

```java
// 在服务端加随机化（部分版本支持），或者客户端侧错峰
.maxConnectionAge(30 + ThreadLocalRandom.current().nextInt(10), TimeUnit.MINUTES)
```

---

## 五、连接池：gRPC 的「池」和 HTTP 的「池」不一样

HTTP/1.1 时代每个连接同时只能处理一个请求，所以需要连接池（HikariCP 那种）。HTTP/2 多路复用后，**一个连接可以并发跑几百个 stream**，理论上一个连接就够。

但实际上：

1. `MAX_CONCURRENT_STREAMS` 默认 100（grpc-java 服务端），超过后新 stream 会排队；
2. 单个 TCP 连接受拥塞窗口限制，吞吐有上限；
3. 单连接故障会一次性影响所有在途请求。

所以生产上通常按「每目标 2~4 个连接」配置：

```java
// 用 round_robin 让连接分散到多个 Pod
ManagedChannel channel = NettyChannelBuilder
        .forTarget("dns:///order-svc:9090")
        .defaultLoadBalancingPolicy("round_robin")
        .build();
```

注意 `round_robin` 是**每个后端地址一个 subchannel**，不是「每个连接轮流」。如果你有 3 个 Pod，客户端会建 3 个连接（每个 Pod 一个），请求在这些连接间轮询。

### 5.1 `pick_first` 的陷阱

默认策略是 `pick_first`：只连第一个可用地址，其他地址**不建连接**。

后果：

- 服务端 3 个 Pod，客户端只用了 1 个 → 负载严重不均；
- 那个 Pod 挂了，客户端才切换，切换期间请求失败；
- K8s Service 的 ClusterIP 模式下，DNS 只返回一个 VIP，`pick_first` 完全无法负载均衡。

**K8s 环境必须用 `round_robin` + Headless Service**（或者用 `dns:///` + 客户端负载均衡）：

```yaml
# headless service
apiVersion: v1
kind: Service
metadata:
  name: order-svc
spec:
  clusterIP: None        # 关键
  selector:
    app: order
  ports:
    - port: 9090
```

---

## 六、一个完整的故障复盘

**现象**：某订单服务每晚 22:00 出现一批 `DEADLINE_EXCEEDED`，持续 1~2 分钟，之后自愈。

**排查过程**：

1. 服务端日志无异常，QPS 正常 → 排除应用层；
2. 客户端指标显示该时段大量 `UNAVAILABLE` + 重连；
3. `tcpdump` 抓到 `GOAWAY` 帧，`lastStreamID` 很大 → 服务端主动关连接；
4. 查服务端配置：`maxConnectionAge = 30min`，无抖动；
5. 查客户端：所有 Pod 在同一时间启动 → 连接建立时间聚集；
6. 30 分钟后，所有连接同时到龄 → 同时 GOAWAY → 客户端同时重连 → 瞬时连接风暴 → 部分请求超时。

**修复**：

- 服务端 `maxConnectionAge` 加随机抖动（25~35 分钟）；
- 客户端 `keepAliveTime` 从默认（不开）改为 30s，提前发现死连接；
- 客户端重试加指数退避 + 抖动，避免重连风暴；
- K8s 加 `preStop sleep 5`，配合优雅下线。

修复后该故障消失。

---

## 七、参数速查表

| 参数 | 位置 | 默认 | 生产建议 | 备注 |
|---|---|---|---|---|
| `keepAliveTime` | 客户端 | 不启用 | 30s | 必须 < 最短中间设备空闲超时 |
| `keepAliveTimeout` | 客户端 | 20s | 10s | 太长会导致故障发现慢 |
| `keepAliveWithoutCalls` | 客户端 | false | true | 否则空闲连接仍被回收 |
| `permitKeepAliveTime` | 服务端 | 5min | 10s | 必须 ≤ 客户端 keepAliveTime |
| `maxConnectionAge` | 服务端 | 无限 | 25~35min（带抖动） | 强制轮换，均衡负载 |
| `maxConnectionAgeGrace` | 服务端 | 无限 | 30s | 排空时间 |
| `maxConnectionIdle` | 服务端 | 无限 | 5min | 空闲回收 |
| `flowControlWindow` | 两端 | 1MB | 2MB（跨地域 4~8MB） | 按 BDP 算 |
| `maxInboundMessageSize` | 两端 | 4MB | 8MB | 超了报 `RESOURCE_EXHAUSTED` |
| `MAX_CONCURRENT_STREAMS` | 服务端 | 100 | 100~500 | 太高会内存放大 |
| `terminationGracePeriodSeconds` | K8s | 30s | 40s | > 排空时间 |

---

## 八、面试追问

**Q1：HTTP/2 的流控和 TCP 的流控有什么区别？**

TCP 流控是**端到端**的（接收窗口 `rwnd`），作用在字节流上，无法区分「哪个请求」。HTTP/2 流控是**应用层**的，按 stream 独立计窗口，能防止「一个大响应堵住其他请求」。两者叠加：HTTP/2 窗口决定应用层能发多少，TCP 窗口决定内核能发多少，**实际吞吐取两者较小值**。

**Q2：为什么 gRPC 的 `onNext` 不自动背压？**

因为 `StreamObserver` 是**推模型**，服务端不知道客户端的消费速度。真正的背压需要客户端显式 `request(n)`（`ClientCallStreamObserver` 的 `request` 方法）。gRPC 提供了 `isReady()` 和 `setOnReadyHandler` 给需要精确控制的场景，但默认不启用，因为大多数场景消息很小、队列够用。

**Q3：`GOAWAY` 和 `RST_STREAM` 的区别？**

`GOAWAY` 是**连接级**的，表示「这个连接不再接受新 stream」，已存在的 stream 可以继续完成；`RST_STREAM` 是**流级**的，立即终止某一个 stream。优雅下线用 `GOAWAY`，取消单个请求用 `RST_STREAM`。

**Q4：为什么客户端要配 `keepAliveWithoutCalls(true)`？**

因为很多 LB/NAT 只按「有无流量」判断连接活性。如果只在有 RPC 时发 PING，空闲期间连接照样会被回收，下一次调用时才发现连接已死。开启后，即使没有活跃调用也会定期发 PING，保持 NAT 表项。

**Q5：`maxInboundMessageSize` 调大有什么风险？**

每个入站消息都会**完整读入内存**再反序列化。设成 100MB，意味着一个恶意/异常请求可以让 JVM 直接 OOM。正确做法是保持 4~8MB，大文件走流式（分块 `stream`）而不是单条大消息。

**Q6：gRPC 的连接池该怎么定大小？**

不是越大越好。先看 `MAX_CONCURRENT_STREAMS` 和单连接吞吐：如果单连接能跑 5000 QPS，业务峰值 10000 QPS，那 2~3 个连接足够。连接太多反而增加 FD、内存和 LB 的负担。多副本场景用 `round_robin` 让每个后端一个 subchannel，比盲目加连接更有效。

---

## 九、小结

- gRPC 的问题大多在**连接层**，但错误信息只告诉你「超时」。抓 `GOAWAY`、看 `WINDOW_UPDATE` 才能定位。
- 流控是两级窗口，窗口耗尽是「流式卡死」的头号原因；要么手动 `request(n)`，要么按 BDP 把窗口调大（并算内存账）。
- keepalive 必须**两端配合**：客户端 `keepAliveTime` ≥ 服务端 `permitKeepAliveTime`，且小于链路上最短空闲超时。
- 优雅下线 = `shutdown()` + `preStop sleep` + `terminationGracePeriodSeconds` 三者对齐。
- K8s 环境必须 `round_robin` + Headless Service，`pick_first` 会导致负载严重不均。
- 所有重试都要配退避 + 抖动，写操作必须幂等，否则重试就是放大器。

gRPC 的默认值是为「理想网络」设计的。生产环境的网络从来不理想，把这些参数按上表调一遍，能消灭一大半「偶发超时」。
