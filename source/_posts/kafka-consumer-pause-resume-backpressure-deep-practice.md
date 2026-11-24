---
title: 【Kafka 实战】消费者 pause/resume 与分区级背压治理：把拉取速率压回下游能力
date: 2026-11-24 08:05:00
tags:
  - Java
  - Kafka
  - 背压
  - 消费治理
  - 中间件
categories:
  - 中间件
author: 东哥
---

# 【Kafka 实战】消费者 pause/resume 与分区级背压治理

## 前言：Kafka 是 pull 模型，为什么还会把消费者撑死？

「Kafka 是拉模型，消费多快就拉多快，怎么会有背压问题？」——这是面试里最常见的误解。

拉模型只保证**不会推爆你**，但保证不了**你自己不会拼命拉**。一旦你把消息处理改成异步（`poll` 拿到就丢进线程池），poll 循环立刻继续下一轮，Kafka 会源源不断地把数据塞进你的进程内存。下游数据库连接池只有 20 个，队列却堆了 20 万条消息，最后不是 OOM，就是因为处理太慢超过 `max.poll.interval.ms` 被踢出消费组，触发 rebalance——**越忙越乱，越乱越慢**。

这篇专讲一个被严重低估的 API：`KafkaConsumer.pause()/resume()`。它和「rebalance」「分区分配」是两件完全不同的事，本站已有 rebalance 专篇，本篇只谈**消费速率的主动刹车**。

---

## 一、先把语义说准：pause 到底停掉了什么

```java
consumer.pause(partitions);   // 停止从这些分区拉取新消息
consumer.resume(partitions);  // 恢复
consumer.paused();            // 当前被暂停的分区集合
```

准确表述是：

| 动作 | pause 后是否发生 |
|---|---|
| 从该分区 fetch 新消息 | ❌ 停止（已在途的响应仍可能返回少量数据） |
| 心跳 / 加入消费组 | ✅ 继续（心跳由独立线程处理） |
| `poll()` 调用 | ✅ 必须继续调用 |
| 位点提交 | ✅ 可正常提交已处理的消息 |
| 触发 rebalance | ❌ 不会，pause 与分配无关 |
| lag 增长 | ✅ 会，因为不再消费 |

四个必须记住的结论：

1. **pause 不是「停止消费线程」**。如果暂停后你不再 `poll()`，超过 `max.poll.interval.ms`（默认 5 分钟）消费者仍会被踢出组，然后 rebalance，暂停集合全部失效。
2. **pause 的粒度是 `TopicPartition`**，但一个分区在同一个消费组内只会分配给一个消费者，所以对这个消费者 pause 就等于全局暂停该分区。
3. **pause 不影响位点**。已处理并提交的不会回退，未处理的下次 resume 继续拉。
4. **pause 期间 lag 会持续上涨**，这是正常的；不正常的是「pause 了却没人知道」，监控上只看到 lag 涨、消费者还活着，很容易误判成「消费能力不足」而去扩容，实际上是自己刹着车。

---

## 二、什么时候该 pause，什么时候不该

先分清三种「消费变慢」的场景，只有第三种需要 pause：

| 场景 | 表现 | 正确做法 |
|---|---|---|
| 单条处理慢（同步） | poll 循环被业务阻塞 | 调 `max.poll.records`、加并发、优化下游；**不需要 pause** |
| 下游短时不可用（DB 主从切换） | 大量异常、重试 | 暂停消费或直接停容器，避免无效重试打满日志 |
| 异步处理 + 有界队列将满 | 队列水位持续上涨 | **pause 刹车，水位下来再 resume** |

第一类场景下 `poll` 本身就自带背压：处理 100 条要 10 秒，下一批就 10 秒后才拉。真正失控的是第二类和第三类——尤其是把消息丢进线程池之后，`poll` 与「处理完成」彻底解耦，此时**队列水位是唯一的刹车信号**。

---

## 三、实现：水位驱动的分区级刹车

### 3.1 不要用容器级 pause 做精细控制

Spring Kafka 的 `MessageListenerContainer.pause()/resume()` 是**容器级**的，会暂停该容器下所有分区。它适合「整体停一下」，不适合按水位精细控制，而且容器级 pause 后 `poll` 仍在跑（这点是对的），但你对分区的掌控力基本为零。

分区级要用 `ConsumerAwareMessageListener` 拿到底层 `Consumer`：

```java
@Component
public class BackpressureCoordinator {

    private static final int HIGH_WATERMARK = 2_000;
    private static final int LOW_WATERMARK  = 500;

    private final AtomicInteger inFlight = new AtomicInteger();
    private final AtomicBoolean paused = new AtomicBoolean(false);
    private final Set<TopicPartition> pausedPartitions = ConcurrentHashMap.newKeySet();

    /** 消息进入处理队列前调用 */
    public void onEnqueue(Consumer<?, ?> consumer, TopicPartition tp) {
        int now = inFlight.incrementAndGet();
        if (now >= HIGH_WATERMARK && paused.compareAndSet(false, true)) {
            // 暂停当前所有已分配分区，而不是只暂停这一条所在分区
            Set<TopicPartition> assignment = consumer.assignment();
            consumer.pause(assignment);
            pausedPartitions.addAll(assignment);
            log.warn("backpressure ON, inFlight={}, paused={}", now, assignment.size());
        }
    }

    /** 处理完成后调用 */
    public void onComplete(Consumer<?, ?> consumer, TopicPartition tp) {
        int now = inFlight.decrementAndGet();
        if (now <= LOW_WATERMARK && paused.compareAndSet(true, false)) {
            // 只恢复仍在本消费者名下的分区，避免恢复已飘走的分区
            Set<TopicPartition> assignment = consumer.assignment();
            Set<TopicPartition> toResume = new HashSet<>(pausedPartitions);
            toResume.retainAll(assignment);
            consumer.resume(toResume);
            pausedPartitions.removeAll(toResume);
            log.info("backpressure OFF, inFlight={}, resumed={}", now, toResume.size());
        }
    }

    public void onPartitionsRevoked(Collection<TopicPartition> revoked) {
        pausedPartitions.removeAll(revoked);
        if (pausedPartitions.isEmpty()) {
            paused.set(false);
        }
    }

    public void onPartitionsAssigned(Consumer<?, ?> consumer, Collection<TopicPartition> assigned) {
        // 重新分配后，如果仍处于背压状态，要把新分区也暂停
        if (paused.get()) {
            consumer.pause(assigned);
            pausedPartitions.addAll(assigned);
        }
    }
}
```

监听器里这样接：

```java
@Component
public class OrderListener implements ConsumerAwareMessageListener<String, Order> {

    private final BackpressureCoordinator coordinator;
    private final BoundedExecutor pool;   // 有界队列 + AbortPolicy/CallerRuns

    @Override
    public void onMessage(ConsumerRecord<String, Order> record,
                          Acknowledgment ack,
                          Consumer<?, ?> consumer) {
        TopicPartition tp = new TopicPartition(record.topic(), record.partition());
        coordinator.onEnqueue(consumer, tp);
        try {
            pool.submit(() -> {
                try {
                    handle(record);        // 真正的业务处理
                } finally {
                    coordinator.onComplete(consumer, tp);
                }
            });
        } catch (RejectedExecutionException e) {
            // 队列真满了：同步退化为「自己跑」，让 poll 阻塞形成天然背压
            coordinator.onComplete(consumer, tp);
            handle(record);
        }
    }
}
```

这里有一个关键设计：**高水位 2000 / 低水位 500 的滞回区间（hysteresis）**。如果只用一个阈值，队列会在阈值附近反复 pause/resume，日志刷屏、指标抖动，甚至把 fetch 请求打成脉冲。滞回区间让状态切换有明确边界。

### 3.2 队列必须有界，而且拒绝策略要「向上传导」

很多事故的根因不是「没 pause」，而是「队列无界」：

```java
// 错误：无界队列，pause 之前已经 OOM
new ThreadPoolExecutor(16, 16, 0, MILLISECONDS, new LinkedBlockingQueue<>());

// 正确：有界 + 让拒绝回流到调用线程
new ThreadPoolExecutor(
    16, 16, 0, MILLISECONDS,
    new ArrayBlockingQueue<>(2_000),
    new ThreadPoolExecutor.CallerRunsPolicy());
```

`CallerRunsPolicy` 会让 `poll` 线程自己执行任务，从而拖慢拉取——这是 JDK 线程池自带的、最朴素的背压。但它会阻塞 poll 线程，所以要确保处理耗时远小于 `max.poll.interval.ms`。

---

## 四、四个生产级坑

### 坑 1：pause 了没 resume（或 resume 错了集合）

最常见的是在 `onPartitionsRevoked` 里没清理 `pausedPartitions`，导致 rebalance 后代码以为「还暂停着」，但实际上新分配的分区是运行状态；或者反过来，对已经不属于自己的分区调用 `resume()`，抛 `IllegalStateException`。

**规范**：所有 pause/resume 前都用 `consumer.assignment()` 取交集；revoked 时清理集合。

### 坑 2：以为 pause 了就不占内存

pause 只停止**新**的 fetch，已经在途的响应、客户端缓冲区里的数据仍然存在。所以还要限制：

```properties
fetch.max.bytes=52428800
max.partition.fetch.bytes=1048576
max.poll.records=200
```

`max.poll.records` 是「一次 poll 最多返回多少条」，配合有界队列，把「单批内存占用」控制在可计算范围内：`200 条 × 平均 2KB ≈ 400KB`，乘上并发线程数就是上限。

### 坑 3：pause 期间被判定为「消费停滞」

有些监控只看 `records-consumed-rate`，pause 后直接掉到 0，触发「消费者挂了」告警；另一些只看 lag，pause 后缓慢上涨，触发「消费堆积」告警。两者都会误报。

正确做法是**三指标联合判断**：

| 指标 | 含义 | pause 期间 |
|---|---|---|
| `kafka.consumer.paused.partitions` | 自定义 gauge | > 0 |
| `queue.depth` / `inflight` | 应用内水位 | 高位 |
| `records-lag-max` | 分区 lag | 上涨但**有心跳** |

告警规则改成：「paused > 0 且持续 > 5 分钟」才报「背压持续」，而不是「lag 上涨就扩容」。

### 坑 4：把 pause 当成「限流」，结果吞吐被锁死

pause/resume 是**开关型**控制，不是速率控制。想精确控制在 500 QPS，应该用令牌桶（Guava `RateLimiter` 或 Resilience4j），而不是「pause 1 秒 resume 1 秒」——后者会让消费呈现明显的锯齿，且延迟大增。

合理的分层是：

```
令牌桶（平滑速率） → 有界队列（吸收突发） → pause/resume（防雪崩）
```

---

## 五、一个真实案例：DB 主从切换期间的消费治理

场景：订单消费服务 8 个分区、4 个消费线程，下游 MySQL 做计划内主从切换，预计 30 秒不可写。

**错误做法**：什么都不做，让消息处理失败 → 重试 → 再失败。结果是 30 秒内堆积 6 万条重试，日志打满磁盘，且重试风暴在 DB 恢复后继续冲击新主库。

**正确做法**：

1. 监听 DB 切换事件（发布订阅或配置中心），把 `paused` 标志置位；
2. 消费者 `pause` 全部分区，**但保持 poll**，心跳正常，不发生 rebalance；
3. 切换完成后 `resume`，按正常速率消费，lag 在几分钟内追平；
4. 全程只有一个状态切换，无重试风暴、无 rebalance、无日志洪水。

这就是 pause/resume 最大的价值：**在不触发 rebalance 的前提下，把消费「挂起」**。停容器会触发 rebalance，重启又要重新分配、重新拉取、可能重复消费；而 pause 是进程内的一个集合操作，代价几乎为零。

---

## 六、面试追问

**Q1：pause 之后还需要 poll 吗？**
需要。心跳虽然由后台线程发送，但 `max.poll.interval.ms` 检查的是应用调用 poll 的间隔，长时间不 poll 依然会被踢出组。这是 pause 与「停止消费」最容易混淆的点。

**Q2：pause 会不会导致重复消费？**
不会直接导致。pause 不改变位点，resume 后从上次提交位置继续。但如果 pause 期间发生 rebalance，未提交的offset会被重新分配给别人，那就可能重复——这是 at-least-once 的固有语义，与 pause 无关。

**Q3：多个消费者实例，pause 一个会影响其他实例吗？**
不会。pause 是消费者实例本地状态，只影响它自己分配到的分区。别的实例照常消费自己的分区。

**Q4：Kafka 4.x 的 share group 还需要 pause 吗？**
share group（KIP-932）把「拉取」变成「acquire/release」的队列语义，单个分区的记录可以被多个消费者共享，背压通过「不 acquire」自然实现，pause 的必要性下降。但经典消费组的 pause 依然是主流方案，至少未来几年不会消失。

**Q5：`max.poll.records` 和 pause 该怎么配合？**
`max.poll.records` 控制**单批大小**（内存上限），pause 控制**是否继续拉**（速率上限）。前者是静态配置，后者是动态反馈，两者一起才能既控内存又控速率。

### 落地检查清单

- [ ] 处理是否异步？异步则必须有有界队列 + 水位刹车
- [ ] pause/resume 是否带滞回区间（避免抖动）
- [ ] rebalance 回调里是否清理/重建暂停集合
- [ ] 暂停状态是否有指标与告警（区分「背压」与「消费能力不足」）
- [ ] `max.poll.interval.ms` 是否大于「队列排空时间 + 单批处理时间」
- [ ] 长暂停场景是否有兜底：超过 N 分钟自动告警并降级

背压不是一个 API，而是一套「感知水位 → 刹车 → 恢复」的闭环。`pause/resume` 只是这套闭环里最便宜、最不打扰集群的那个执行器。
