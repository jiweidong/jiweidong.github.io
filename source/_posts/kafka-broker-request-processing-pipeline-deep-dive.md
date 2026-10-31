---
title: 【Kafka 底层】Broker 请求处理全链路深度解析：Acceptor、Processor、RequestChannel 与 Purgatory
date: 2026-10-31 08:05:00
tags:
  - Java
  - Kafka
  - 中间件
  - 源码
  - 性能调优
categories:
  - 中间件
author: 东哥
---

# 【Kafka 底层】Broker 请求处理全链路深度解析

## 前言

大部分人学 Kafka 的路径是：分区 → 副本 → ISR → 幂等 → 事务。这些是"语义层"。但真到了线上，`Produce` 请求 P99 突然从 8ms 涨到 300ms、`RequestQueueTimeMs` 报警、`NetworkProcessorAvgIdlePercent` 掉到 10%、消费者 fetch 全部超时——这时候语义层的知识一点用都没有，你必须知道**一个请求从网卡进来到响应写回，到底经过了哪几个队列、哪几把锁、哪几个线程池**。

Kafka 的网络层设计非常经典：**1 个 Acceptor + N 个 Processor + 1 个共享请求队列 + M 个 Handler + Purgatory 延时机制**。这套结构在 3.x/4.x 基本没变（4.0 只是把 KRaft 变成唯一元数据模式），理解了它，绝大多数"Kafka 变慢"的问题都能在 10 分钟内定位到具体环节。

本文按请求生命周期逐段拆，配合源码入口、关键参数、监控指标，最后给一份调优决策表。

---

## 一、全局视图：一条 Produce 请求的旅程

```
 ┌─────────┐   OP_ACCEPT    ┌──────────┐   round-robin   ┌───────────┐
 │ Acceptor│───────────────▶│ Processor│────────────────▶│ Processor │
 └─────────┘                │  (N 个)  │                 │  Selector │
                            └────┬─────┘                 └─────┬─────┘
                                 │ requestQueue.put()          │ responseQueue.poll()
                                 ▼                             ▲
                        ┌──────────────────┐            ┌──────┴───────┐
                        │  RequestChannel  │            │ 每个 Processor│
                        │ requestQueue(500)│            │ 独立响应队列  │
                        └────────┬─────────┘            └──────────────┘
                                 │ take()
                                 ▼
                     ┌────────────────────────┐
                     │ KafkaRequestHandlerPool│  (num.io.threads)
                     │  Handler × M           │
                     └───────────┬────────────┘
                                 │ KafkaApis.handle()
                                 ▼
              ┌──────────────────────────────────────┐
              │ 需要等待？ → Purgatory + TimingWheel  │
              │ 不需要   → 直接生成 Response           │
              └──────────────────────────────────────┘
```

关键点先说结论：

1. **网络线程（Processor）不做业务**，只做字节读写与队列搬运；**业务全在 IO 线程（Handler）**。
2. `requestQueue` 是**全局共享**的，容量 `queued.max.requests`（默认 500）。队列满时 Processor **阻塞**，这是 Kafka 的天然背压。
3. 响应不是 Handler 直接写回，而是塞进**对应 Processor 的响应队列**，由 Processor 在 `poll` 时写回，从而保证**同一连接上的响应顺序**。
4. 需要等待的请求（`acks=all` 等 ISR、无数据的 fetch、延迟 produce）**不占用 Handler 线程**，而是挂到 Purgatory，由时间轮与事件驱动唤醒。这是 Kafka 高吞吐的关键设计。

---

## 二、Acceptor：只做一件事——把连接分给 Processor

源码入口：`kafka.network.Acceptor`。

```scala
class Acceptor(val endPoint: EndPoint,
               val sendBufferSize: Int,
               val recvBufferSize: Int,
               connectionQuotas: ConnectionQuotas,
               metricPrefix: String) extends AbstractServerThread(connectionQuotas) with KafkaMetricsGroup {

  private val nioSelector = NSelector.open()
  val serverChannel = openServerSocket(endPoint.host, endPoint.port)

  def run(): Unit = {
    serverChannel.register(nioSelector, SelectionKey.OP_ACCEPT)
    while (isRunning) {
      try {
        val ready = nioSelector.select(500)
        if (ready > 0) {
          val keys = nioSelector.selectedKeys()
          val iter = keys.iterator()
          while (iter.hasNext && isRunning) {
            val key = iter.next()
            iter.remove()
            if (key.isAcceptable) accept(key, metrics)
          }
        }
      } catch { case e: Throwable => ... }
    }
  }

  def accept(key: SelectionKey, metrics: Metrics): Unit = {
    val socketChannel = serverChannel.accept()
    if (socketChannel != null) {
      socketChannel.configureBlocking(false)
      connectionQuotas.inc(endPoint.listenerName, socketChannel.socket.getInetAddress, time)
      val processor = synchronized {   // ← 轮询分配
        var i = currentProcessorIndex
        var processor: Processor = null
        do {
          processor = processors(i)
          i = (i + 1) % processors.length
        } while (processor.isNotAssignedToAnyConnection && i != currentProcessorIndex)
        currentProcessorIndex = i
        processor
      }
      processor.accept(socketChannel, mayBlock = false)
    }
  }
}
```

两个细节值得记住：

- **分配的起点是"上一次分配到的下一个"**，而不是每次从 0 开始。这是为了避免"总是 0 号 Processor 拿到新连接"，让新连接在 N 个 Processor 间均匀铺开。
- `isNotAssignedToAnyConnection` 的判断是为了**跳过刚被 mute 的 Processor**（比如正在处理阻塞的 `accept`），避免把连接塞给一个暂时不可用的线程。

### 关键参数

```properties
# 每个 listener 的 Acceptor 有 1 个，Processor 数量：
num.network.threads=3          # 默认 3，通常设为 CPU 核数
```

**什么时候要调大 `num.network.threads`？** 看 `NetworkProcessorAvgIdlePercent`：

- 长期 > 70%：网络线程空闲，不用动。
- 长期 < 30%：网络线程是瓶颈，通常是**小消息高频**场景（比如每条 100B、每秒几十万条），或者 TLS 握手/加解密吃满 CPU。此时增大到 8~16 有意义。
- 但注意：网络线程数**不能超过** `num.io.threads` 太多，否则请求会堆在队列里等 Handler。

---

## 三、Processor：Selector 多路复用 + 队列搬运工

`Processor` 是 Kafka 网络层真正干活的地方，一个 Processor 独享一个 `Selector`，管理一组连接。

```scala
class Processor(id: Int, endPoint: EndPoint, requestChannel: RequestChannel,
                apis: ApiVersions, ...) extends AbstractServerThread(connectionQuotas) with KafkaMetricsGroup {

  private val selector = new Selector(
    maxReceiveSize = config.socketRequestMaxBytes,
    maxSendSize = config.socketSendBufferBytes,
    connectionsMaxIdleMs = config.connectionsMaxIdleMs)

  override def run(): Unit = {
    while (isRunning) {
      try {
        selector.poll(300)   // ← 300ms 一次
      } catch { ... }

      // 1) 处理新完成接收的请求
      selector.completedReceives.forEach { receive =>
        val channel = selector.channel(receive.source)
        val request = RequestHeader.parse(receive.payload)
        val context = new RequestContext(...)
        requestChannel.sendRequest(new RequestChannel.Request(...))  // ← 入全局请求队列
      }

      // 2) 处理待发送的响应
      selector.mute(...)   // 有待发响应时，暂停该连接的读事件
      while (selector.completedSends.nonEmpty) { ... }
      selector.unmute(...)
    }
  }
}
```

### 三个必须理解的行为

**（1）`mute` / `unmute` 保证响应顺序与背压**

Kafka 协议**不保证请求乱序响应**（客户端按 correlationId 匹配），但 Kafka 服务端仍然做了"同一连接上响应按序写回"的简化：一旦某个连接有响应待发，Processor 会 **mute 该连接的读事件**，先把响应写完再恢复读。

这带来一个重要副作用：**如果客户端 pipelining 很多请求、而某个响应很大（比如大 fetch），这个连接的后续请求会被"堵"住**。这就是为什么 `fetch.max.bytes` / `max.partition.fetch.bytes` 设置过大时，会拖慢同一连接上的其他请求。

**（2）`requestQueue` 满 → Processor 阻塞**

```java
// RequestChannel.sendRequest
public void sendRequest(Request request) throws InterruptedException {
    if (!requestQueue.offer(request, Timeout)) {
        throw new RuntimeException("Request queue is full ...");
    }
}

// RequestChannel.RequestQueue（有界阻塞队列实现）
def put(req: Request, timeout: Long): Boolean = {
    if (queue.offer(req, timeout, TimeUnit.MILLISECONDS)) true
    else false
}
```

队列容量：`queued.max.requests`（默认 500）。**队列一满，Processor 线程就卡在 `offer` 上**，此时它不再 `poll`，同一 Processor 上的所有连接都停止读写——这就是 Kafka 的背压实现：**不丢请求，直接让客户端感知到慢**。

> 生产经验：`RequestQueueSize` 持续接近 500，说明 **IO 线程不够**或**请求处理变慢**（磁盘慢、锁竞争、Purgatory 里堆积）。此时优先查 `RequestHandlerAvgIdlePercent` 与磁盘 `await`，而不是盲目加 `queued.max.requests`——调大只是把内存里的排队变长，延迟更高。

**（3）请求解析在 Processor 线程完成**

`RequestHeader.parse`、`MemoryRecords` 的 CRC 校验（部分）、TLS 解密都在网络线程。所以**网络线程 CPU 高不一定是流量大**，也可能是消息体过大导致解析耗时。

---

## 四、RequestChannel：全局请求队列 + 每 Processor 响应队列

```scala
class RequestChannel(val queueSize: Int, val metricNamePrefix: String) extends KafkaMetricsGroup {
  private val requestQueue = new ArrayBlockingQueue[RequestChannel.Request](queueSize)
  private val responseQueues = new ArrayBuffer[BlockingQueue[RequestChannel.Response]]
  // 每个 Processor 对应一个响应队列
  def addResponseQueue(): Int = { ... }

  def sendRequest(request: RequestChannel.Request): Unit = {
    requestQueue.put(request)
  }

  def receiveRequest(): RequestChannel.Request = requestQueue.take()

  def sendResponse(response: RequestChannel.Response): Unit = {
    responseQueues(response.processor).put(response)
    processors(response.processor).wakeup()   // ← 唤醒对应 Processor 的 Selector
  }
}
```

这里的 `wakeup()` 是 `Selector.wakeup()`，让阻塞在 `poll(300)` 的 Processor 立刻醒来处理响应。**这是 Kafka 低延迟的关键细节**：如果没有 wakeup，最坏情况下响应要多等 300ms 才被写回。

> 排查技巧：如果看到 `RequestQueueTimeMs` 高但 `ResponseQueueTimeMs` 低，说明**Handler 取请求慢**（IO 线程不足或处理慢）；反过来 `ResponseQueueTimeMs` 高，说明**Processor 写回慢**（网络拥塞、客户端不收、TLS 慢）。这两个指标一左一右，能直接把问题切成两半。

---

## 五、KafkaRequestHandlerPool：真正干活的地方

```scala
class KafkaRequestHandlerPool(val brokerId: Int,
                              val requestChannel: RequestChannel,
                              val apis: KafkaApis,
                              time: Time,
                              numThreads: Int,
                              requestHandlerAvgIdleMetricName: String,
                              logAndAwaitShutdown: Boolean) {

  val threads = new Array[Thread](numThreads)
  val runnables = new Array[KafkaRequestHandler](numThreads)
  for (i <- 0 until numThreads) {
    runnables(i) = new KafkaRequestHandler(i, brokerId, aggregateIdleMeter,
      numThreads, requestChannel, apis, time)
    threads(i) = KafkaThread.daemon("kafka-request-handler-" + i, runnables(i))
    threads(i).start()
  }
}

class KafkaRequestHandler(...) extends Runnable {
  def run(): Unit = {
    while (!stopped) {
      try {
        val req = requestChannel.receiveRequest(300)   // ← 阻塞 300ms 取请求
        req match {
          case RequestChannel.ShutdownRequest => ...
          case request: RequestChannel.Request =>
            try {
              request.requestDequeueTimeNanos = time.nanoseconds
              apis.handle(request)                      // ← 分发到具体 API
            } catch { ... }
            finally { request.releaseBuffer() }
          case null => // 超时，继续循环
        }
      } catch { ... }
    }
  }
}
```

`KafkaApis.handle` 是一个巨型 `match`，按 `apiKey` 分发：

```scala
def handle(request: RequestChannel.Request): Unit = {
  try {
    request.header.apiKey match {
      case ApiKeys.PRODUCE => handleProduceRequest(request, requestLocal)
      case ApiKeys.FETCH => handleFetchRequest(request)
      case ApiKeys.LIST_OFFSETS => handleListOffsetRequest(request)
      case ApiKeys.METADATA => handleTopicMetadataRequest(request)
      case ApiKeys.JOIN_GROUP => handleJoinGroupRequest(request, requestLocal)
      case ApiKeys.COMMIT_OFFSET => handleOffsetCommitRequest(request, requestLocal)
      // ... 80+ 种
    }
  } finally {
    request.apiLocalCompleteTimeNanos = time.nanoseconds
  }
}
```

### Handler 的数量与空闲率

```properties
num.io.threads=8        # 默认 8，建议 = 磁盘数 × 2 或 CPU 核数
```

监控指标 `RequestHandlerAvgIdlePercent`：

| 取值 | 含义 | 动作 |
|---|---|---|
| > 60% | IO 线程充足 | 无需调整 |
| 20%~60% | 中等负载 | 关注趋势 |
| < 20% | IO 线程接近饱和 | 加线程 / 查磁盘 / 查锁 |
| ≈ 0 且 queue 满 | 已过载 | 先限流或扩容，别调参 |

**注意**：`num.io.threads` 不是越大越好。Handler 线程多了会加剧：① 页缓存竞争；② 分区锁（`Log` 对象的锁）竞争；③ 上下文切换。经验值是**不超过 CPU 核数的 2 倍**。

---

## 六、Purgatory：Kafka 高并发的真正秘密

这是最容易被忽略、也最值得学的一段。

### 6.1 为什么需要 Purgatory

考虑 `acks=all` 的 Produce：

1. Leader 写入本地 log。
2. 等待 ISR 中所有 follower 拉取并确认。
3. 才能返回响应。

如果 Handler 线程在这里 `sleep` 或 `wait`，8 个 IO 线程会被少量慢请求全部占满——**吞吐直接塌方**。Kafka 的解法是：**把"等待"从线程模型里剥离出来**，放进 `Purgatory`，由事件回调触发完成。

```scala
class DelayedOperationPurgatory[T <: DelayedOperation](purgatoryName: String,
                                                       brokerId: Int = 0,
                                                       purgeInterval: Int = 1000,
                                                       reaperEnabled: Boolean = true,
                                                       timerEnabled: Boolean = true) {

  private val watchersForKey = new ConcurrentHashMap[Any, Watchers]()

  def tryCompleteElseWatch(operation: T, watchKeys: Seq[Any]): Boolean = {
    // 1) 先尝试直接完成（条件可能已经满足）
    var isCompletedByMe = operation.tryComplete()
    if (isCompletedByMe) return true
    // 2) 挂到 watchKey 上（如某个分区的 ISR 变化、某个 offset 写入）
    var watchCreated = false
    for (key <- watchKeys) {
      if (operation.isCompleted) return false
      watchForOperation(key, operation)
      if (!watchCreated) { watchCreated = true; estimatedTotalOperations.incrementAndGet() }
    }
    // 3) 再试一次（避免 watch 期间条件已满足的竞态）
    isCompletedByMe = operation.tryComplete()
    if (isCompletedByMe) return true
    // 4) 交给时间轮做超时兜底
    if (!operation.isCompleted) {
      if (timerEnabled) timeoutTimer.add(operation)
      if (operation.isCompleted) operation.cancel()
    }
    false
  }

  def checkAndComplete(key: Any): Int = {
    val watchers = inReadLock(removeWatchersLock) { watchersForKey.get(key) }
    if (watchers == null) 0 else watchers.tryCompleteWatched()
  }
}
```

### 6.2 两类唤醒源

| 唤醒源 | 触发点 | 例子 |
|---|---|---|
| **事件驱动** | 条件变化时主动 `checkAndComplete(key)` | follower 的 fetch 带来 ACK → 唤醒 `delayedProduce`；消费者 fetch 有新数据 → 唤醒 `delayedFetch` |
| **时间驱动** | 分层时间轮到期 | `request.timeout.ms` 到了还没凑齐 ACK → 超时失败 |

时间轮实现是 Kafka 自研的**分层时间轮**（`TimerWheel`），默认 20 个 bucket、每 bucket 1ms 粒度、3 层，覆盖约 20ms × 20 × 20 = 8s 的量级，超过则退化为 `TimerTaskList` 的延迟队列。这跟 Netty 的 `HashedWheelTimer` 思路一致，但 Kafka 的 bucket 数是固定的，靠"层级降级"覆盖长时间跨度。

### 6.3 哪些请求会进 Purgatory

| 请求 | 等待条件 | 超时参数 |
|---|---|---|
| `Produce`（acks=all/-1） | ISR 全部 ACK | `request.timeout.ms`（默认 30s） |
| `Produce`（acks=1） | 本地写入完成（通常不进） | — |
| `Fetch` | `fetch.min.bytes` 未满足 / `max.wait.ms` 未到 | `fetch.max.wait.ms`（默认 500ms） |
| `JoinGroup` | 组内所有成员重新加入 | `group.initial.rebalance.delay.ms`（默认 3s） |
| `DeleteRecords` | 低水位推进 | `request.timeout.ms` |
| `InitProducerId` / 事务相关 | 事务状态机推进 | `transaction.timeout.ms` |

**长轮询（long polling）就是 `DelayedFetch`**：消费者 `fetch.min.bytes=1MB`，Broker 没凑够 1MB 数据时，不立即返回空响应，而是挂起等待最多 `fetch.max.wait.ms`，期间只要新数据写入就立刻唤醒返回。这一条把"消费者每秒空转 10 次"变成"有数据才返回"，是 Kafka 消费端低延迟 + 低 CPU 的核心。

### 6.4 监控 Purgatory

| 指标 | 含义 | 异常判断 |
|---|---|---|
| `PurgatorySize`（按类型） | 当前挂起操作数 | 持续增长 → 下游确认慢 |
| `DelayedOperationPurgatoryNumDelayedOperations` | 同上（新版本指标名） | 同上 |
| `ExpiredDelayedOperationsPerSec` | 超时率 | > 0 持续出现 → 客户端超时，需查 ISR/网络 |
| `FailedProduceRequestsPerSec` | 生产失败 | 配合 `Error` 分类看 |

> 真实案例：某集群 `PurgatorySize` 从 200 涨到 2 万，`RequestHandlerAvgIdlePercent` 却还有 60%。原因是**跨机房 follower 同步慢，`acks=all` 一直在等最后一个副本**。Handler 线程确实空闲（因为在 Purgatory 里），但客户端延迟已经爆炸。**只看 IO 线程空闲率会误判**，必须同时看 Purgatory 与 `RequestQueueTimeMs`。

---

## 七、调优决策表

| 症状 | 指标特征 | 优先动作 |
|---|---|---|
| 吞吐上不去，CPU 不高 | `NetworkProcessorAvgIdlePercent` 低 | 加 `num.network.threads`；检查是否 TLS |
| 延迟高，队列堆积 | `RequestQueueSize` 接近 `queued.max.requests`，`RequestHandlerAvgIdlePercent` 低 | 加 `num.io.threads`；查磁盘 `await`、`iowait` |
| 延迟高，队列不堆 | `PurgatorySize` 高 | 查 ISR 同步、跨 AZ 网络、`acks` 配置 |
| 消费延迟高，Broker 正常 | `DelayedFetch` 多、`fetch.min.bytes` 大 | 调小 `fetch.min.bytes` 或 `fetch.max.wait.ms` |
| 大消息场景抖动 | `ResponseQueueTimeMs` 高 | 降 `fetch.max.bytes`；开压缩；拆大消息 |
| 频繁超时 | `ExpiredDelayedOperationsPerSec` > 0 | 查 GC、网络丢包、客户端 `request.timeout.ms` |

---

## 八、面试追问

**Q1：Kafka 为什么快？**

标准答案会提顺序写、页缓存、零拷贝、批量+压缩。**加分答案是线程模型**：网络线程只做 IO 搬运，业务在固定大小 IO 线程池处理，需要等待的操作全部剥离到 Purgatory 由事件/时间轮驱动——**用少量线程支撑大量并发等待**，这是与"一请求一线程"模型的本质差异。

**Q2：`num.network.threads` 和 `num.io.threads` 分别管什么？调优依据？**

network 线程负责 `accept`、读写 socket、请求解析、响应写回（含 TLS）；io 线程负责 `KafkaApis.handle` 的业务逻辑（写 log、读 log、更新 ISR、事务状态机）。调优依据分别是 `NetworkProcessorAvgIdlePercent` 与 `RequestHandlerAvgIdlePercent`，**低于 30% 才考虑加**，且 io 线程不建议超过 CPU × 2。

**Q3：一个 `acks=all` 的 Produce 请求，从进入到返回经历了哪些线程？**

客户端 → Acceptor（分配连接）→ Processor（解析、入 `requestQueue`）→ Handler（`handleProduceRequest`，append 到 log，创建 `DelayedProduce` 挂 Purgatory）→ 返回 Handler 线程（释放）。随后 follower fetch → Leader 处理 fetch 时更新 HW → `checkAndComplete` 唤醒 `DelayedProduce` → 生成 Response 入对应 Processor 的响应队列 → Processor 写回 socket。**整个等待期间不占任何 Handler 线程**。

**Q4：`queued.max.requests` 调大会怎样？**

请求队列变长 → 内存占用上升（每个请求持有 `MemoryRecords` 引用）→ 排队延迟上升 → 客户端更容易超时。**它是背压阈值，不是性能参数**。正确做法是让队列满时快速反馈（客户端重试/限流），而不是无限缓冲。

**Q5：`RequestQueueTimeMs` 和 `ResponseQueueTimeMs` 怎么用来定位？**

`RequestQueueTimeMs` = 请求入队到 Handler 取出，高 → Handler 侧瓶颈（线程不足/处理慢）。`ResponseQueueTimeMs` = 响应入队到 Processor 写回，高 → 网络侧瓶颈（带宽、客户端不读、TLS）。两者一左一右，把问题切成"计算"还是"网络"。

---

## 九、总结

1. Kafka 网络层是 **Acceptor（1）+ Processor（N）+ 全局 requestQueue + Handler（M）+ 每 Processor 响应队列** 的结构，职责边界极清晰。
2. `requestQueue`（默认 500）满会让网络线程阻塞，这是**天然背压**，不是 bug。
3. 响应必须回到原 Processor 写回，`mute/unmute` 保证同连接有序，也带来"大响应阻塞同连接"的副作用。
4. **Purgatory + 分层时间轮**是 Kafka 高并发的核心：把"等待"从线程里剥离，用事件驱动 + 超时兜底，`acks=all` 与长轮询 `fetch` 都靠它。
5. 排障顺序：先看 `RequestQueueTimeMs` / `ResponseQueueTimeMs` 切分计算 vs 网络，再看 `RequestHandlerAvgIdlePercent` 判断线程是否够，最后看 `PurgatorySize` 判断是否卡在下游确认。

把这套链路装进脑子，下次再遇到"Kafka 慢了"，你打开监控就有明确的下一步，而不是先去重启 Broker。
