---
title: 【Java 响应式】WebFlux 背压深度解析：Reactive Streams 请求协议、onBackpressure 策略与 SSE 流式限速
date: 2026-10-18 08:00:00
tags:
  - Java
  - Spring
  - WebFlux
  - Reactor
  - 背压
  - 响应式编程
categories:
  - Java 深挖
author: 东哥
---

# 【Java 响应式】WebFlux 背压深度解析：Reactive Streams 请求协议、onBackpressure 策略与 SSE 流式限速

## 前言

很多人用 WebFlux 的理由是「高并发」，但真正把 WebFlux 用出问题的，往往也是「高并发」——不是并发不够，而是**下游消费不过来时，上游还在拼命生产**，最后内存被队列撑爆，`OutOfMemoryError: Java heap space` 或者 GC 直接飙到 90%。

这就是背压（Backpressure）要解决的问题。它不是 WebFlux 的附加功能，而是 **Reactive Streams 规范里的一等公民**：`Publisher` 不能想推多少就推多少，必须等 `Subscriber` 通过 `request(n)` 明确表达「我还能处理 n 个」。

但在真实项目里，背压极容易被悄悄破坏：`flatMap` 不设并发上限、`Flux.create` 里无视 `requestedFromDownstream`、随手一个 `collectList()`、或者在响应式链路里 `block()`。链路一旦有一处不遵守协议，整条链的背压就失效了，而且**不会报错**，只会在压测时表现为「内存缓慢上涨 → 延迟抖动 → 雪崩」。

这篇文章从协议层讲到生产落地：Reactor 的请求如何传递、四种 `onBackpressure*` 策略怎么选、`limitRate/prefetch` 到底调什么、SSE 流式接口（尤其是对接大模型 token 流）如何做限速，最后给出线上排查清单和面试追问。

---

## 一、Reactive Streams 协议：背压的本质是「信用额度」

Reactive Streams 只定义了四个接口：

```java
public interface Publisher<T> {
    void subscribe(Subscriber<? super T> s);
}

public interface Subscriber<T> {
    void onSubscribe(Subscription s);
    void onNext(T t);
    void onError(Throwable t);
    void onComplete();
}

public interface Subscription {
    void request(long n);   // 消费者声明还能处理 n 个
    void cancel();
}

public interface Processor<T, R> extends Subscriber<T>, Publisher<R> {}
```

关键在 `Subscription.request(long n)`：

- **初始请求量为 0**。`onSubscribe` 之后，Publisher 一个元素都不能发，直到 Subscriber 调用 `request(n)`。
- `request` 是**累加**语义：先 `request(10)` 再 `request(5)`，一共可以发 15 个。
- `request(Long.MAX_VALUE)` 表示「无界需求」，等价于关闭背压——这是绝大多数背压失效的根源。

Reactor 在规范之上补了两个重要抽象：

| 抽象 | 作用 | 典型实现 |
|---|---|---|
| `Subscription` | 单订阅者的信用通道 | `FluxRange.RangeSubscription` |
| `QueueSubscription` | 带队列的订阅，支持 `poll()` 拉模式 | `FluxCreate`、`FluxPublishOn` 内部使用 |
| `Fuseable` | 允许算子融合，减少中间队列 | `map`、`filter` 等无状态算子 |

`QueueSubscription` 的 `requestFusion(NONE/SYNC/ASYNC)` 是 Reactor 的性能关键：融合后 `map` 不再产生独立队列，直接同步 poll，避免每个算子一层 `ConcurrentLinkedQueue`。但**融合只在支持背压的链路上成立**，一旦上游是无界的（比如 `Flux.create` 没有检查请求量），融合会退化成 `NONE`，队列重新出现。

### 1.1 请求量在链路中如何流动

```text
Netty Channel (TCP 窗口) 
   → Reactor Netty HttpServer (读事件)
   → ReactorServerHttpRequest (Publisher<DataBuffer>)
   → WebFlux Handler (业务 Flux)
   → 下游算子 (map/filter/flatMap/...)
   → 最终 Subscriber (HttpMessageWriter / SSE writer)
       ↓ request(n)
   逐级向上游传递 request
```

注意最后一环：**真正的背压发起者是写出端**。`HttpMessageWriter` 在 socket 可写时才会 `request(1)` 或 `request(N)`；当客户端 TCP 接收窗口满了，Netty 的 `isWritable=false`，写出暂停，`request` 停止，背压才沿着链路一路传回数据源。

所以背压链路是否有效，取决于两件事：

1. 中间每一层是否**如实转发** `request`；
2. 是否存在**无界缓冲**（无界队列、`collectList`、`UnicastProcessor` 老 API 等）。

---

## 二、四种 onBackpressure 策略：选错就是灾难

当上游是「无法被背压」的源（定时器、监听器回调、阻塞队列、第三方推送），Reactor 提供四种适配策略：

| 策略 | 行为 | 内存 | 数据完整性 | 适用场景 |
|---|---|---|---|---|
| `onBackpressureBuffer()` | 无界队列缓存 | 无上限，**OOM 风险最高** | 不丢 | 下游短暂变慢、数据不可丢且有界输入 |
| `onBackpressureBuffer(n, ...)` | 有界队列，满了按策略处理 | 有界 | 可配置溢出策略 | **生产首选**，配合溢出回调告警 |
| `onBackpressureDrop()` | 满了直接丢弃 | 有界 | 丢数据 | 监控指标、日志采样、非关键遥测 |
| `onBackpressureLatest()` | 只保留最新一个 | O(1) | 丢中间值 | 实时行情、传感器快照、UI 刷新 |
| `onBackpressureError()` | 满了抛 `IllegalStateException` | 有界 | 快速失败 | 强一致场景，宁可失败不可延迟 |

代码对比：

```java
// 1) 无界缓冲：压测时最容易把堆打满
Flux.interval(Duration.ofMillis(1))
    .onBackpressureBuffer()          // 危险：默认 Integer.MAX_VALUE
    .publishOn(Schedulers.boundedElastic())
    .subscribe(this::slowConsume);

// 2) 有界缓冲 + 溢出策略 + 告警（推荐）
Flux.interval(Duration.ofMillis(1))
    .onBackpressureBuffer(
        10_000,
        dropped -> log.warn("backpressure overflow, dropped={}", dropped),
        BufferOverflowStrategy.DROP_OLDEST)
    .publishOn(Schedulers.boundedElastic(), 256)
    .subscribe(this::slowConsume);

// 3) 只保留最新值：适合"状态型"数据
Flux.interval(Duration.ofMillis(10))
    .onBackpressureLatest()
    .subscribe(price -> ui.push(price));

// 4) 快速失败：让上游感知压力
Flux.interval(Duration.ofMillis(1))
    .onBackpressureError()
    .subscribe(v -> slowConsume(v),
               err -> metrics.counter("bp.error").increment());
```

几个容易忽略的细节：

- `onBackpressureBuffer()` **无参版本是 `Integer.MAX_VALUE`**，等于没有上限。代码评审看到无参版本必须问一句「上游速率上限是多少」。
- `BufferOverflowStrategy` 有四个值：`ERROR`、`DROP_OLDEST`、`DROP_LATEST`、`IGNORE`（配合回调）。`IGNORE` 不会丢，但会继续增长，慎用。
- `onBackpressureDrop()` 丢弃的是**当前元素**，并且只在 `request` 不足时丢；它不会缓存任何东西，所以更适合「丢了也无所谓」的指标流。
- 这四种策略**只能作用于 `Flux`，`Mono` 不需要**——`Mono` 最多一个元素，天然不存在背压问题。

---

## 三、真正破坏背压的六个写法

比「选错策略」更常见的是「根本不知道自己破坏了背压」。下面六种写法，只要出现一种，整条链的背压就形同虚设。

### 3.1 `Flux.create` 不检查请求量

```java
// 反例：无视下游需求，有多少推多少
Flux<Event> flux = Flux.create(sink -> {
    listener.onEvent(e -> sink.next(e));   // 下游 request(1)，这里推了 10000 个
});
```

正确写法是用 `sink.onRequest` 做「按需拉取」，或者改用 `Flux.push` + 有界队列：

```java
Flux<Event> flux = Flux.create(sink -> {
    sink.onRequest(n -> {
        // 只有下游要，才从队列里取 n 个
        for (long i = 0; i < n; i++) {
            Event e = queue.poll();
            if (e == null) break;
            sink.next(e);
        }
    });
    sink.onDispose(() -> listener.unregister());
});
```

判断标准很简单：**你的 `sink.next()` 调用频率是否由下游 `request` 驱动**。如果不是，这层就是无界生产。

### 3.2 `flatMap` 不设并发上限

`flatMap` 默认 `concurrency = 256`，且内部 `prefetch = 32`（Reactor 3.5+）。如果不设上限，遇到慢下游时，256 个内部流各自缓冲 32 个元素，瞬间就是 8192 个对象在内存里；如果每个元素是大对象（比如一张图片、一段文档），直接 OOM。

```java
// 危险：并发无界，内部预取叠加
flux.flatMap(this::callRemoteApi)

// 安全：限制并发 + 限制预取
flux.flatMap(item -> callRemoteApi(item), 8, 2)
```

`concatMap` 是更保守的选择：并发固定为 1，严格保序，但吞吐低。**需要保序 + 有限并发**时，用 `flatMapSequential(item -> ..., concurrency, prefetch)`。

### 3.3 `collectList()` / `collectMap()`

```java
// 把整个流物化成 List：背压彻底消失，内存 = 全量数据
Mono<List<Order>> all = orderFlux.collectList();
```

`collectList` 本身不违反协议（它确实按需 request），但它把「流式」变成了「全量驻留」。如果上游有 100 万条订单，这 100 万条会同时存在于堆里。分页查询、`bufferTimeout(n, duration)` 批量处理、或者直接 `flatMap` 逐条处理，才是可扩展的做法。

### 3.4 响应式链路里 `block()`

```java
// 反例：在 Netty event loop 上 block
@GetMapping("/orders")
public List<Order> list() {
    return orderService.findAll().collectList().block();  // 可能直接抛异常
}
```

`block()` 在 event loop 线程上会抛 `IllegalStateException: block()/blockFirst()/blockLast() are blocking, which is not supported in thread reactor-http-nio-x`。即使侥幸在 `boundedElastic` 上执行，它也把一个非阻塞链路退化成了「一个请求占一个线程」，WebFlux 的线程模型优势全没了。

### 3.5 混用阻塞驱动

在 Reactor 链路里调用 JDBC（阻塞 IO），必须 `subscribeOn(Schedulers.boundedElastic())`，否则会占满 event loop。但要注意：`boundedElastic` 的队列是**无界的**（`LinkedBlockingQueue`），默认队列长度 `Integer.MAX_VALUE`。也就是说，**阻塞任务一多，背压在调度器这一层就断了**。

```java
// boundedElastic 的队列无界，压力会堆在线程池队列里
Mono.fromCallable(() -> jdbcQuery())        // 阻塞
    .subscribeOn(Schedulers.boundedElastic())
```

治理手段：限制入口并发（`flatMap(..., concurrency)`）、给 `boundedElastic` 设置上限（`reactor.schedulers.defaultBoundedElasticSize`、`...QueueSize`）、或者干脆用 R2DBC。

### 3.6 忘记 `limitRate`

`limitRate(n)` 是把「无界需求」切成「n 个一批」的最简单手段：

```java
flux.limitRate(64)   // 每 75% 消耗后重新 request，避免 request(Long.MAX_VALUE)
```

它的实现是 `request(75% * n)` 预取、消耗到 75% 时再补一批，既减少 `request` 往返次数，又不会一次要太多。**任何从外部源（MQ、文件、DB 游标）读取的流，都应该显式 `limitRate`。**

---

## 四、prefetch、concurrency、limitRate 三者关系

这是面试和调优的高频混淆点：

| 参数 | 作用层 | 默认值 | 调大 | 调小 |
|---|---|---|---|---|
| `limitRate(n)` | 订阅者请求节奏 | 无（默认无界） | 吞吐↑，内存↑ | 内存↓，往返↑ |
| `flatMap` 的 `concurrency` | 同时订阅的内部流数量 | 256 | 并发↑，下游压力↑ | 并发↓，延迟↑ |
| `flatMap` 的 `prefetch` | 每个内部流的预取量 | 32 | 单流吞吐↑，内存↑ | 内存↓，可能饥饿 |
| `publishOn(scheduler, prefetch)` | 跨线程队列容量 | 256 | 跨线程吞吐↑ | 切线程开销占比↑ |

一个经验公式：**单机内存预算 ÷ (元素平均大小 × 并发数) ≈ prefetch 上限**。比如堆 2G、单元素 10KB、并发 32，那么 prefetch 最多 `2G × 0.2 / (10KB × 32) ≈ 1300`，实际取 32~64 更稳妥。

---

## 五、SSE 流式接口的背压实战

SSE（Server-Sent Events）是 WebFlux 最典型的流式场景，也是背压最容易出问题的地方。典型代码：

```java
@GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<ServerSentEvent<Token>> stream(@RequestParam String q) {
    return llmClient.stream(q)                 // Flux<Token>，来自第三方 SDK
        .map(t -> ServerSentEvent.builder(t).build())
        .timeout(Duration.ofSeconds(60))
        .onErrorResume(e -> Flux.just(errorEvent(e)));
}
```

这段代码看起来没问题，但存在三个隐患：

1. **第三方 SDK 往往是无界推送**。如果 SDK 内部是「拿到就回调」，`Flux.create` 包装后不检查 `request`，客户端一慢，token 就在服务端堆起来。
2. **没有限速**。大模型出 token 的速度可能远高于慢客户端（移动网络）的消费速度，需要 `limitRate` 或 `onBackpressureBuffer` 有界化。
3. **客户端断开没有取消上游**。必须确保 `cancel` 能传播到 LLM 调用，否则模型还在烧 token（也就是烧钱）。

生产级写法：

```java
@GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<ServerSentEvent<Token>> stream(@RequestParam String q) {
    AtomicBoolean cancelled = new AtomicBoolean();

    return Flux.create(sink -> {
            LlmHandle handle = llmClient.stream(q, new Callback() {
                @Override public void onToken(Token t) {
                    if (sink.isCancelled()) return;     // 关键：取消后不再生产
                    sink.next(t);
                }
                @Override public void onComplete() { sink.complete(); }
                @Override public void onError(Throwable e) { sink.error(e); }
            });
            sink.onDispose(() -> {
                cancelled.set(true);
                handle.abort();                          // 传播取消，停止计费
            });
        }, FluxSink.OverflowStrategy.BUFFER)
        .limitRate(32)                                   // 每 32 个一批向 SDK 要
        .map(t -> ServerSentEvent.builder(t).build())
        .timeout(Duration.ofSeconds(60))
        .onErrorResume(e -> Flux.just(errorEvent(e)));
}
```

再配合 Netty 层的写缓冲控制：

```yaml
server:
  netty:
    connection-timeout: 5s
  compression:
    enabled: false       # SSE 不要压缩，避免缓冲整个响应
```

以及 Spring 的响应超时：

```java
// WebFlux 的响应超时不是 server.tomcat.*，而是 Reactor Netty 的 responseTimeout
// HttpClient 侧也要设置，避免半开连接
```

### 5.1 SSE 的三个反模式

- **在 SSE 里 `collectList()`**：等于放弃流式，客户端要等全部生成完才收到第一个字节，还会让首字节时间（TTFB）退化。
- **用 `Flux.interval` 做心跳但不设背压**：心跳本身很轻，但如果和业务流 `merge` 后没有 `limitRate`，慢客户端会让心跳也堆积。
- **忽略 `Last-Event-ID`**：断线重连后从头发，用户体验和成本都受影响。正确做法是把事件 ID 写进 `ServerSentEvent.id()`，重连时按 ID 续传。

---

## 六、背压与 TCP 流控：别把两件事混为一谈

一个常见误解是「有 TCP 窗口就够了，不需要应用层背压」。两者层级不同：

| 层级 | 机制 | 粒度 | 能否防 OOM |
|---|---|---|---|
| TCP | 接收窗口 / 拥塞窗口 | 字节 | 只能防内核缓冲区溢出 |
| Netty | `Channel.isWritable` / 高低水位 | 字节 | 防 Netty 写缓冲膨胀 |
| Reactor | `request(n)` | 元素 | **防应用层队列膨胀** |
| 业务 | 限流/队列长度/并发数 | 请求 | 防系统性过载 |

TCP 窗口满了，数据会堆在**用户态**（Netty 的 `ChannelOutboundBuffer`、Reactor 的操作符队列）——内核不背这个锅。所以「客户端慢」最终表现为 JVM 堆上涨，而不是 TCP 报错。

排查时可以用：

```bash
# 看 Netty 是否频繁不可写
# 在 handler 里统计 channel.isWritable() 的翻转次数
# 看 Reactor 的队列指标（Micrometer）
reactor_netty_connection_provider_pending_acquire_connections
reactor_netty_http_client_response_time_seconds
```

---

## 七、生产踩坑清单

**坑 1：压测 QPS 上去了，内存也上去了，但 CPU 不高。**
十有八九是某个算子用了无界队列。用 `-XX:+HeapDumpOnOutOfMemoryError` 抓 dump，看 `reactor.core.publisher.FluxCreate$BufferAsyncSink` 或 `Queues$OneQueue` 的 retained size。

**坑 2：`flatMap` 并发 256 + 下游 RT 2s，线程池打满。**
不是背压问题，是并发预算问题。用 Little's Law 估算：`并发 = QPS × RT`。100 QPS × 2s = 200 并发，`flatMap(…, 256)` 刚好卡在边缘，任何抖动都会排队。

**坑 3：SSE 连接数一多，`boundedElastic` 队列爆。**
SSE 本身不占线程（事件驱动），但如果 `map` 里调了阻塞方法（比如同步写数据库记录 token 用量），就会掉进 `boundedElastic` 的无界队列。把副作用改成异步批处理。

**坑 4：`onBackpressureDrop` 用在了不可丢的数据上。**
上线后表现为「偶发丢单」。背压策略必须和业务语义对齐：**能丢的才 drop，不能丢的要么 buffer 有界 + 降级，要么 error 快速失败**。

**坑 5：升级 Reactor 后行为变了。**
`flatMap` 的默认 `prefetch` 在 3.5 从 32 调整为按 `concurrency` 计算，`onBackpressureBuffer` 的默认容量也有变化。升级前跑一遍压测，别只看单元测试。

---

## 八、面试追问

**Q1：Reactive Streams 的背压和 TCP 背压有什么区别？**
TCP 是字节级、内核级；Reactive Streams 是元素级、应用级。TCP 窗口满只说明「网络暂时不收」，应用层仍可能把数据堆在用户态队列里；只有 `request(n)` 才能让上游**停止生产**，而不是「生产了但发不出去」。

**Q2：`request(Long.MAX_VALUE)` 意味着什么？**
关闭背压。它告诉上游「我永远有空」，上游可以全速生产。常见于 `subscribe()` 无参重载（内部就是 `request(Long.MAX_VALUE)`）和 `block()`。

**Q3：`onBackpressureBuffer` 和 `publishOn` 的队列有什么区别？**
前者是**溢出策略**，作用于「上游无法被背压」的场景；后者是**线程切换缓冲**，作用于「跨线程传递元素」。两者都会引入队列，但 `publishOn` 的队列容量由 `prefetch` 控制且有界，`onBackpressureBuffer()` 无参版本无界。

**Q4：为什么 `Flux.create` 容易破坏背压？**
因为它面向「推模式」的外部源，API 设计上允许你随时 `next()`。要恢复背压，必须用 `sink.onRequest(n -> ...)` 把拉取逻辑接进来，或者用 `OverflowStrategy` 显式声明溢出行为。

**Q5：`flatMap` 和 `concatMap` 在背压上的差异？**
`flatMap` 并发订阅多个内部流，请求量会放大 `concurrency × prefetch`；`concatMap` 一次只订阅一个，天然有界，但吞吐受限于单流速度。`flatMapSequential` 介于两者之间：并发订阅但按序发射。

**Q6：如何证明背压生效了？**
三个证据：① 上游生产速率随下游消费速率变化（打日志/埋点）；② 堆内存稳定，不随 QPS 线性增长；③ 在 `request` 上打断点或用 `doOnRequest` 观察请求量不是 `Long.MAX_VALUE`。

---

## 总结

背压不是「加个 `onBackpressureBuffer` 就完事」，而是一条**从写出端到数据源的完整信用链**。记住四句话：

1. **`request(n)` 是唯一的背压信号**，任何绕过它的生产都是无界生产。
2. **`onBackpressureXxx` 是兜底，不是方案**；真正的方案是让上游可被背压（分页、游标、`limitRate`）。
3. **`flatMap` 的并发和预取是内存预算问题**，不是性能参数随便调。
4. **SSE 场景必须传播取消**，否则客户端断开后模型还在烧钱。

在线上的判断标准很朴素：**QPS 涨 10 倍，堆内存是否只涨一点点**。如果不是，回去找那个无界队列。
