---
title: 【Nginx 实战】Nginx 代理 gRPC 深度实战：grpc_pass、HTTP/2 端到端与流式长连接治理
date: 2026-11-19 08:00:00
tags:
  - Java
  - Nginx
  - gRPC
  - HTTP/2
  - 微服务
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】Nginx 代理 gRPC 深度实战

## 前言

这两年做 AI 应用，后端服务大量用 gRPC：流式 ASR、流式 TTS、推理服务、内部 Agent 工具网关，几乎都是 proto 定义 + HTTP/2 长连接。于是 Nginx 又多了一个新身份——gRPC 网关。

很多人第一次配 gRPC 反代，写出来是这样：

```nginx
location / {
    proxy_pass http://backend;
}
```

结果客户端报 `UNAVAILABLE: upstream connect error`，或者 Nginx 日志里一行 `client intended to send too large body`，或者更诡异：**普通一元调用（unary）全正常，一上服务端流式就 60 秒断流**。

这不是玄学。gRPC 对代理有三条硬要求，任何一条不满足都会以「看起来像业务 bug」的方式失败：

1. 必须说 HTTP/2（客户端侧和上游侧都要）；
2. 必须原样转发 **trailers**（gRPC 的 status 和 status-message 在 trailers 里，不在 HTTP 状态行）；
3. 必须支持**长度未知的流式 body**，不能缓存完整请求/响应再转发。

本文按「协议要求 → 最小可用配置 → 超时与长连接 → 负载均衡 → 观测 → 排障」的顺序，把 Nginx 反代 gRPC 这件事讲透，最后给一份 Java 客户端侧的配合参数和一张排障对照表。

---

## 一、先搞清楚 gRPC 在 HTTP/2 上长什么样

一个 gRPC 调用在线上就是一次 HTTP/2 请求：

```
:method         POST
:scheme         https
:path           /helloworld.Greeter/SayHello
:authority      api.example.com
content-type    application/grpc+proto
te              trailers
grpc-timeout    3S
grpc-encoding   identity

<5 字节前缀 + protobuf 消息>
```

响应侧：

```
:status         200
content-type    application/grpc+proto

<5 字节前缀 + protobuf 消息>
...
grpc-status     0
grpc-status-message
```

几个关键点，直接决定了代理配置：

| 特性 | 说明 | 对代理的影响 |
|---|---|---|
| `te: trailers` | 客户端声明自己能接 trailers | 代理必须转发，不能吞掉 |
| `grpc-status` 在 trailers | 业务错误码在流末尾 | HTTP 状态码永远是 200，Nginx 的 `$status` 看不出业务失败 |
| 5 字节长度前缀 | 消息体自带长度帧 | 代理不能按 Content-Length 理解 body |
| 双向流 | 请求和响应可以一直开着 | 读/写超时是「两次 IO 之间」而非总时长 |
| 二进制 body | protobuf 不是文本 | 不要对它开 `gzip`，gRPC 自己有 `grpc-encoding` |

> 一个非常常见的误判：看到 Nginx access log 里全是 `200`，就以为接口成功率 100%。实际上 gRPC 的失败（`DEADLINE_EXCEEDED`、`RESOURCE_EXHAUSTED`）在 HTTP 层全是 200。**gRPC 的成功率必须由应用侧拦截器统计，不能看 Nginx 状态码。**

---

## 二、最小可用配置

### 2.1 客户端侧：HTTP/2 必须显式开启

```nginx
server {
    listen 443 ssl;
    http2 on;                 # Nginx 1.25.1+；老版本写 listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/nginx/certs/api.crt;
    ssl_certificate_key /etc/nginx/certs/api.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_alpn_protocols  h2 http/1.1;   # 没有 h2，gRPC 客户端直接降级失败

    location /helloworld.Greeter/ {
        grpc_pass grpc://grpc_backend;
    }
}
```

`grpc_pass grpc://` 表示**明文 HTTP/2（h2c，prior knowledge）**；`grpcs://` 表示到上游走 TLS。注意这里不是 `http://`——写 `proxy_pass http://` 会退化成 HTTP/1.1，直接 502。

### 2.2 上游侧：连接复用要显式打开

```nginx
upstream grpc_backend {
    least_conn;
    server 10.0.1.11:9090;
    server 10.0.1.12:9090;

    keepalive 64;              # 关键：不复用连接，每次调用都要 TCP+TLS 握手
    keepalive_requests 100000;
    keepalive_timeout 60s;
}
```

对于 gRPC，`keepalive` 的意义比 HTTP/1.1 更大：HTTP/2 一条连接可以承载成百上千个 stream，复用连接等于复用了多路复用能力。没有 `keepalive`，每个 RPC 都要新建连接，在 QPS 高的时候会看到大量 `TIME_WAIT` 和握手延迟。

### 2.3 请求体大小：默认 1MB 会咬人

```nginx
client_max_body_size 0;        # 流式上传/大 proto 必须放开，否则 413
```

gRPC 的流式上传（比如音频分片、文件分块）没有 Content-Length，Nginx 依然会按累计读取量校验 `client_max_body_size`。默认 1m，超过就 413，而客户端看到的可能只是一个含糊的 `UNKNOWN`。

### 2.4 不要开 gzip

```nginx
# 错误示范
gzip on;
gzip_types application/grpc;
```

gRPC 消息是二进制帧，外面再套一层 gzip 会破坏 5 字节长度前缀的解析；而且 gRPC 协议本身支持 `grpc-encoding: gzip` 的按消息压缩。代理层要压缩就交给 gRPC 自己做。

---

## 三、超时：最容易配错的一组参数

Nginx gRPC 模块的超时语义和 `proxy_read_timeout` 一致，都是**两次成功 IO 之间的间隔**，不是整个请求的总时长：

| 指令 | 默认值 | 语义 | 长流场景怎么配 |
|---|---|---|---|
| `grpc_connect_timeout` | 60s | 与上游建立连接 | 1~3s，快速失败 |
| `grpc_read_timeout` | 60s | 两次读上游之间的间隔 | 按「心跳间隔 × 2」配，如 120s |
| `grpc_send_timeout` | 60s | 两次写上游之间的间隔 | 30~60s |
| `grpc_buffer_size` | 4k/8k | 读响应缓冲区 | 保持默认，别调大 |

这里有个经典事故：一个服务端流式接口每 90 秒推一次进度，`grpc_read_timeout` 用默认 60s，于是**每次都在第 60 秒被 Nginx 切断**，客户端报 `UNAVAILABLE`。业务侧以为是自己流断了，查了半天。

正确的做法是把「业务心跳间隔」当成 SLA 的一部分来设计：

```nginx
location /agent.AgentService/StreamRun {
    grpc_pass grpc://agent_backend;
    grpc_read_timeout 150s;    # 心跳 60s，留 2.5 倍余量
    grpc_send_timeout 60s;
    grpc_socket_keepalive on;
}
```

### 3.1 客户端 deadline 与 Nginx 超时的关系

gRPC 客户端会带 `grpc-timeout` 头，Nginx 默认透传，但**两者是独立生效的**：

- 客户端 deadline 到了，客户端自己取消，发 `RST_STREAM`；
- Nginx 超时到了，Nginx 断开上游，客户端看到 `UNAVAILABLE`。

所以正确的取值是：

```
客户端 deadline  <  Nginx read_timeout  <  上游业务最大处理时间 + 余量
```

反了会怎样？客户端 30s deadline，Nginx 配 60s：客户端取消后，Nginx 可能还在等上游，上游继续跑完，白白消耗一次推理。对按 token 计费的 LLM 调用，这就是真金白银的浪费。

---

## 四、负载均衡：连接级，不是请求级

这是 Nginx OSS 做 gRPC 网关最大的认知差。

HTTP/1.1 时代，「一个连接一个请求」，`round_robin` 基本等于按请求轮询。到了 HTTP/2，一条连接上可以并发几百个 stream，而 **Nginx OSS 的 upstream 选择发生在连接建立时**，一旦连接建好，后续 stream 都复用这条连接。

后果：

- `round_robin`：连接数分布均匀，但请求数可能严重倾斜（某条连接上跑了 80% 的流）；
- `least_conn`：按**活跃连接数**选，长流场景下连接数长期不变，等于失效；
- `ip_hash`：同一客户端固定一台，做不了真正的请求级均衡。

| 方案 | 均衡粒度 | 适合场景 | 局限 |
|---|---|---|---|
| Nginx OSS + `least_conn` | 连接 | 短 unary 调用为主 | 长流会倾斜 |
| Nginx Plus | 连接 + 部分健康检查增强 | 企业内网 | 收费 |
| Envoy | **请求/stream 级** | 大规模 gRPC、需要重试预算/熔断 | 运维复杂度高 |
| 客户端 LB（gRPC-Java `round_robin` + Headless Service） | 连接级但客户端可控 | K8s 内部 | 需要服务发现配合 |

实践建议：

1. 内部服务间调用优先用 **gRPC 客户端侧负载均衡 + K8s Headless Service**，把 Nginx 留给「南北向入口」；
2. 南北向必须用 Nginx 时，给长流接口单独建 upstream，并接受「连接级均衡」这个事实；
3. 不要指望 Nginx OSS 做 gRPC 感知的健康检查——它只会做 TCP 连接检查，进程活着但 gRPC 服务未注册时依然会转发。

---

## 五、重试：流式接口上的重试是灾难

```nginx
grpc_next_upstream error timeout;
grpc_next_upstream_tries 2;
```

默认配置在 unary 只读接口上没问题，但对**有副作用的流式接口**非常危险：

- 上游已经执行了一半（扣了款、发了消息、跑了工具），Nginx 因为读超时重试到另一台，等于执行两次；
- 双向流重试时，客户端已经发出去的请求帧无法重放，重试的连接从半路开始，协议状态直接错乱。

原则：

| 接口类型 | 是否允许 Nginx 重试 |
|---|---|
| 只读 unary（Get/List） | 可以，`error timeout` |
| 写操作 unary | 只在有幂等键时允许 |
| 服务端流式 | 不建议（重试要客户端做，且要带 resume token） |
| 双向流 | 禁止 |

gRPC 自己的重试策略（`service config` 里的 `retryPolicy`）比 Nginx 更合适，因为它能识别 `grpc-status`，而 Nginx 只认传输层错误。

---

## 六、观测：Nginx 看不到 gRPC 的业务状态

前面说过，gRPC 错误的 HTTP 状态码是 200。所以：

- access log 的 `$status`、`$upstream_status` 只能反映传输层；
- `$request_time` 包含流式连接的整个生命周期，长流会显示成几百秒，直接拿来做 P99 会失真；
- `$body_bytes_sent` 对 HTTP/2 多路复用连接意义有限。

可以拿到的有用信号：

```nginx
log_format grpc '$remote_addr [$time_local] "$request" '
                'up=$upstream_addr urt=$upstream_response_time '
                'rt=$request_time sent=$body_bytes_sent recv=$request_length '
                'proto=$server_protocol';

access_log /var/log/nginx/grpc.log grpc;
```

真正要看的指标在应用侧：

1. **gRPC status 分布**：用 `ServerInterceptor` / `ClientInterceptor` 打点到 Micrometer；
2. **端到端延迟**：从收到首字节到流结束，分 unary / server-stream / bidi 三类统计；
3. **流被中断的位置**：区分「客户端取消」「Nginx 超时」「上游异常」——这决定了你该调哪个参数。

Java 侧一个最小拦截器：

```java
public class GrpcMetricsInterceptor implements ServerInterceptor {
    private final MeterRegistry registry;

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call, Metadata headers, ServerCallHandler<ReqT, RespT> next) {

        long start = System.nanoTime();
        ServerCall<ReqT, RespT> wrapped = new ForwardingServerCall.SimpleForwardingServerCall<>(call) {
            @Override
            public void close(Status status, Metadata trailers) {
                registry.timer("grpc.server.duration",
                                "method", call.getMethodDescriptor().getFullMethodName(),
                                "code", status.getCode().name())
                        .record(System.nanoTime() - start, TimeUnit.NANOSECONDS);
                super.close(status, trailers);
            }
        };
        return next.startCall(wrapped, headers);
    }
}
```

---

## 七、Java 客户端要配合的四个参数

代理配对了，客户端配错一样断流。以 grpc-java + Netty 为例：

```java
ManagedChannel channel = NettyChannelBuilder.forTarget("dns:///api.example.com:443")
        .useTransportSecurity()
        .keepAliveTime(30, TimeUnit.SECONDS)      // 有长流时不要关掉，防中间设备静默断连
        .keepAliveTimeout(10, TimeUnit.SECONDS)
        .keepAliveWithoutCalls(true)
        .maxInboundMessageSize(16 * 1024 * 1024)  // 默认 4MB，大响应会 RESOURCE_EXHAUSTED
        .flowControlWindow(1024 * 1024)
        .build();
```

四个高频坑：

1. **`maxInboundMessageSize`**：默认 4MB。向量检索返回大 batch 时直接 `RESOURCE_EXHAUSTED`，报错信息还很像服务端问题。
2. **keepAlive 与 LB 的空闲超时**：云厂商 LB 常见 60s/350s 空闲断连。客户端 keepAlive 必须小于它，否则会出现「每隔几分钟一次莫名 UNAVAILABLE」。
3. **`GOAWAY` 处理**：上游滚动发布时发 GOAWAY，grpc-java 会自动迁移新连接，但如果用了自定义 `NameResolver` 或固定 IP，可能一直重连到已下线实例。
4. **deadline 必须设**：不设 deadline 的调用在连接半死（TCP 还在、对端不响应）时会永久挂住，线程池被拖满。

```java
// 正确：每次调用都带 deadline，流式用可取消的 Context
try (Context.CancellableContext ctx = Context.current().withDeadlineAfter(30, TimeUnit.SECONDS, forkJoinPool)) {
    stub.withDeadlineAfter(30, TimeUnit.SECONDS).sayHello(request);
}
```

---

## 八、排障对照表

| 现象 | 最可能原因 | 验证方式 | 修复 |
|---|---|---|---|
| `upstream connect error` / 502 | 用了 `proxy_pass` 或上游不是 h2c | 看配置是否有 `grpc_pass` | 改 `grpc_pass grpc://` |
| unary 正常，流式 60s 断 | `grpc_read_timeout` 默认 60s | 调大后观察 | 按心跳间隔配置 |
| 413 / 大请求失败 | `client_max_body_size` 默认 1m | 日志 `client intended to send too large body` | 设 0 或按需 |
| 客户端收到 `UNKNOWN`，服务端无日志 | trailers 被中间层吞掉 | 换直连对比 | 去掉会改写响应的中间件 |
| 每隔几分钟一次 UNAVAILABLE | 空闲连接被 LB 断开 | 抓包看 FIN/RST | 客户端 keepAlive < LB 空闲超时 |
| 上游负载不均 | HTTP/2 连接级均衡 | 看各实例连接数与 QPS | 客户端 LB 或 Envoy |
| `RESOURCE_EXHAUSTED` | 消息超过 4MB | 异常信息含 `maxInboundMessageSize` | 调大或改分页 |
| 发布时批量报错 | GOAWAY + 连接迁移失败 | 看是否集中在发布窗口 | 加 preStop 延迟、客户端刷新 DNS |

---

## 九、面试追问

**Q1：Nginx 反代 gRPC 为什么不能用 `proxy_pass`？**

`proxy_pass` 走 HTTP/1.1，没有流式多路复用，也不理解 gRPC 的 5 字节长度前缀和 trailers。`grpc_pass` 是专门的模块，负责 h2c/h2 转换、trailers 转发和流式透传。

**Q2：`grpc_read_timeout` 是总超时吗？**

不是。它是两次成功读操作之间的最大间隔。一个持续 10 分钟、每 30 秒推一次数据的流，只要 `read_timeout > 30s` 就不会被切断。

**Q3：为什么 Nginx 日志全是 200，监控却显示成功率 92%？**

gRPC 把业务状态放在 trailers 的 `grpc-status` 里，HTTP 层始终 200。必须在应用侧用拦截器统计 status code。

**Q4：Nginx 做 gRPC 负载均衡有什么先天缺陷？**

OSS 版本按连接均衡，而 HTTP/2 一条连接可以跑几百个 stream，导致请求级倾斜；也没有 gRPC 健康检查和 stream 级重试预算。大规模场景应该用 Envoy 或客户端 LB。

---

## 十、总结

把 Nginx 当 gRPC 网关，记住四句话：

1. **两端都必须是 HTTP/2**：`http2 on` + `grpc_pass grpc://`，缺一不可；
2. **超时按 IO 间隔算**：`grpc_read_timeout` 跟心跳走，客户端 deadline 要更短；
3. **重试要看幂等性**：流式和写操作不要交给 Nginx 重试；
4. **观测要下沉到应用**：HTTP 200 不代表 gRPC 成功。

配置本身不难，难的是理解「HTTP/2 多路复用 + 流式 + trailers」这三件事叠加后，代理层的语义发生了什么变化。想清楚这一层，后面调参就是查表的事了。
