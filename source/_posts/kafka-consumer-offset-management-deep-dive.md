---
title: 【Kafka 实战】消费者位移（Offset）管理深度解析：自动提交陷阱、手动提交与重复消费治理
date: 2026-10-21 08:10:00
tags:
  - Java
  - Kafka
  - Offset
  - 消息队列
  - 分布式
categories:
  - 消息队列
author: 东哥
---

# 【Kafka 实战】消费者位移（Offset）管理深度解析

## 前言

线上 MQ 出的问题，九成不是「消息丢了」，而是「消息重复了」或者「消费卡住了」。这两件事的根，几乎都指向同一个地方——**位移（Offset）**。

先看两个真实工单：

**工单 A**：订单履约服务重启后，把 3 小时前的 2 万条发货消息又消费了一遍，导致重复发货。日志显示 `enable.auto.commit=true`，且消费逻辑里有 200ms 的 RPC 调用。

**工单 B**：某个 consumer group 的 lag 一直涨，但消费线程是活的、日志没报错。最后发现是某台机器的处理线程卡在一个没有超时的 HTTP 调用上，`poll()` 再也回不来，触发了 `max.poll.interval.ms`，rebalance 后它又拿回同一个分区，继续卡。

这两个案例都不是「Kafka 的 bug」，而是**对位移语义理解不到位**。这一篇把 offset 这件事从存储结构讲到代码实践：自动提交到底什么时候提交、手动提交怎么选、rebalance 时会发生什么、重复消费怎么治理、lag 怎么算才是对的。

---

## 一、Offset 到底存在哪

### 1.1 消费者位点的三个层次

先厘清四个容易混淆的概念：

| 名称 | 含义 | 谁维护 |
|---|---|---|
| **position** | 消费者**下一条要消费**的消息位点（内存中） | Consumer 客户端 |
| **committed offset** | 已**提交**的位点，存在 broker 上，代表「这个 group 处理到哪了」 | Broker（`__consumer_offsets`） |
| **last stable offset (LSO)** | 事务场景下，所有**已提交事务**的最大位点；消费者只能读到 LSO 之前 | Broker |
| **log end offset (LEO)** | 分区日志末尾位点（下一条要写入的位置） | Broker |

它们的关系是：

```
committed offset ≤ position ≤ LSO ≤ LEO
```

`Lag = LEO - committed offset`（严格说是 `LEO - position` 用于客户端自算，服务端 `kafka-consumer-groups` 用的是 committed）。

注意一个细节：**消费者实际是从 `position` 开始拉的，不是从 `committed offset`**。`committed offset` 只在两种时机被读取：消费者启动时（无本地状态）、以及 rebalance 后重新分配分区时。这就是为什么「提交了但没消费完」会导致消息丢失——重启后从 committed 开始，中间那段被跳过了。

### 1.2 `__consumer_offsets` 的内部结构

Kafka 把位移存在一个内部 topic：`__consumer_offsets`，默认 50 个分区。

它的消息 key 是三段式：

```
[version(short)][group(String)][topic(String)][partition(int)]
```

value 是：

```
[version(short)][offset(long)][metadata(String)][commit_timestamp(long)]
```

分区算法：

```java
partition = Math.abs(groupId.hashCode()) % groupMetadataTopicPartitionCount
```

也就是说 **同一个 group 的所有位移都落在同一个分区**，这保证了提交的原子性和顺序性。这个设计很关键：如果你有一个 group 有 500 个分区、QPS 很高，`__consumer_offsets` 的单个分区会成为写入热点——这也是官方建议「尽量用少量大 group，而不是海量小 group」的原因之一。

### 1.3 位移什么时候被清理

`offsets.retention.minutes` 默认 **10080**（7 天）。注意这个「7 天」不是从最后一条消息算，而是从**该 group 最后一次提交位移**算。如果一个 group 停止消费超过 7 天，位移会被删除，重新启动时会走 `auto.offset.reset` 策略。

这个坑在生产上非常常见：一个季度才跑一次的批处理任务，每次启动都从 `latest` 开始，等于漏掉了中间所有数据。

---

## 二、自动提交：五个必踩的坑

`enable.auto.commit=true`（默认值）是新手最容易踩的雷。它的行为是：

**在 `poll()` 方法内部，如果距离上次提交超过 `auto.commit.interval.ms`（默认 5000），就提交「上一次 poll 返回的最后一条消息的 offset + 1」。**

注意这句话的三个关键词：**poll 内部**、**上一次 poll 的**、**+1**。

### 坑 1：提交的是「拉取位点」，不是「处理位点」

```java
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> r : records) {
        handle(r);   // 假设这里跑了 3 秒
    }
    // 下一轮 poll 时，自动提交的是「本轮 records 的最后 offset + 1」
    // 但此时如果本轮还没处理完，就会提前提交
}
```

如果 `handle` 处理到第 5 条时进程被 kill，自动提交可能已经把整批 500 条的 offset 提交了。**剩下 495 条永久丢失**。

### 坑 2：rebalance 会「丢一批」

`poll()` 返回后，如果发生 rebalance，分区被回收，但自动提交发生在**下一次 poll**。这段时间内处理完的消息位移没有提交，新 owner 会从旧的 committed offset 重新消费——重复。

### 坑 3：处理失败也照样提交

自动提交不关心你的业务是否成功。异常被 catch 住了、消息进了死信、数据库事务回滚了——它统统不管，到点就提交。

### 坑 4：`poll()` 间隔必须小于 `max.poll.interval.ms`

`max.poll.interval.ms` 默认 **300000**（5 分钟）。如果你一批拉 500 条、每条处理 1 秒，就是 500 秒 > 300 秒，消费者会被踢出 group，触发 rebalance，然后**它可能又拿回同一个分区，继续超时**，形成活锁。

这不是 offset 问题，但和 offset 强耦合：rebalance 后位移回退，重复消费。

### 坑 5：`auto.commit.interval.ms` 调大不能解决重复

很多人以为「调大提交间隔 = 少提交 = 少重复」，实际上正好相反：间隔越大，崩溃时回退的位点越多，重复越多。

### 什么时候可以用自动提交

只有一种场景：**消息处理是幂等的，且允许少量重复/丢失**（比如纯日志采集、指标上报）。业务消息一律手动提交。

---

## 三、手动提交：同步、异步与时机

### 3.1 两种 API

```java
// 同步提交：阻塞直到 broker 确认，失败会重试（可重试异常）
consumer.commitSync();

// 异步提交：不阻塞，回调里拿结果
consumer.commitAsync((offsets, exception) -> {
    if (exception != null) {
        log.error("commit failed, offsets={}", offsets, exception);
    }
});
```

**提交的 offset 语义是「下一条要消费的位置」**，所以必须 `record.offset() + 1`：

```java
Map<TopicPartition, OffsetAndMetadata> toCommit = new HashMap<>();
toCommit.put(
    new TopicPartition(record.topic(), record.partition()),
    new OffsetAndMetadata(record.offset() + 1)
);
consumer.commitSync(toCommit);
```

这是最容易写错的一行。写成 `record.offset()` 会导致每次重启重复消费最后一条——不致命，但如果最后一条恰好是「扣款」，就致命了。

### 3.2 提交时机的三种模式

**模式 A：逐条同步提交（最安全，最慢）**

```java
for (ConsumerRecord<String, String> record : records) {
    process(record);                       // 业务处理
    consumer.commitSync(Map.of(tp(record), new OffsetAndMetadata(record.offset() + 1)));
}
```

每条一次 RPC，吞吐掉到几百 TPS。只在金融级强一致场景用。

**模式 B：整批处理完再提交（推荐）**

```java
for (ConsumerRecord<String, String> record : records) {
    process(record);
}
consumer.commitSync();   // 提交本批最后位置
```

吞吐高，语义是「至少一次」。崩溃会重放整批，所以**必须幂等**。

**模式 C：异步提交 + 定期同步兜底**

```java
try {
    for (ConsumerRecord<String, String> record : records) {
        process(record);
    }
    consumer.commitAsync();            // 快
} catch (Exception e) {
    log.error("batch failed", e);
    consumer.commitSync();             // 失败时同步确认一次
} finally {
    // 关闭前必须同步提交，否则异步请求可能丢失
}
```

⚠️ 异步提交有一个经典陷阱：**后发的提交可能先到**。如果 `commitAsync(offset=100)` 失败重试，而 `commitAsync(offset=200)` 成功，重试的 100 会把位点回退。所以异步提交**不要自己加重试**，失败就留给下一轮。

### 3.3 Spring Kafka 的 AckMode

用 Spring Kafka 时，`AckMode` 决定了「什么时候 ack」：

| AckMode | 提交时机 | 提交方式 | 适用场景 |
|---|---|---|---|
| `RECORD` | 每条记录处理完 | 同步 | 强一致、低吞吐 |
| `BATCH`（默认） | 一批 poll 的记录全部处理完 | 同步 | 大多数业务 |
| `TIME` | 超过 `ackTime` 毫秒 | 同步 | 对延迟敏感 |
| `COUNT` | 累积 `ackCount` 条 | 同步 | 批量写 |
| `COUNT_TIME` | 两者任一满足 | 同步 | 折中 |
| `MANUAL` | 手动调 `ack.acknowledge()` | 批量后提交 | 需要精确控制 |
| `MANUAL_IMMEDIATE` | 调用即提交 | 立即 | 精确控制 + 低延迟 |

配置：

```yaml
spring:
  kafka:
    consumer:
      enable-auto-commit: false        # 用 Spring 的 ack 机制，必须关掉 Kafka 原生自动提交
    listener:
      ack-mode: manual_immediate
```

⚠️ **最容易错的配置组合**：`enable-auto-commit: true` + `AckMode.MANUAL`。Spring 的 ack 完全失效，因为 Kafka 客户端自己在提交。这两个开关必须成对出现：`enable-auto-commit=false` + 任意 Spring AckMode。

---

## 四、一份可直接用的消费端骨架

下面这个实现覆盖了：手动提交、幂等、死信、优雅停机、批量提交。

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventConsumer {

    private final KafkaTemplate<String, String> kafkaTemplate;
    private final IdempotentRepository idempotentRepository;  // Redis / DB 唯一键
    private final ObjectMapper objectMapper;

    @KafkaListener(
        topics = "order-events",
        groupId = "fulfillment-service",
        concurrency = "4",
        containerFactory = "manualAckContainerFactory"
    )
    public void onMessage(ConsumerRecord<String, String> record, Acknowledgment ack) {
        String msgId = record.key() + "@" + record.partition() + "@" + record.offset();

        try {
            // 1) 幂等：同一 (partition, offset) 只处理一次
            if (!idempotentRepository.tryLock(msgId, Duration.ofMinutes(30))) {
                log.info("duplicate message skipped, msgId={}", msgId);
                ack.acknowledge();     // 重复消息也要 ack，否则会一直重投
                return;
            }

            OrderEvent event = objectMapper.readValue(record.value(), OrderEvent.class);
            process(event);            // 业务处理（内部有本地事务）

            idempotentRepository.markDone(msgId);
            ack.acknowledge();         // 处理成功后才提交位移

        } catch (RetryableException e) {
            // 可重试：不 ack，让容器在 max.poll.interval 内重试（注意配置 errorHandler）
            log.warn("retryable failure, msgId={}", msgId, e);
            throw e;
        } catch (Exception e) {
            // 不可重试：进死信，然后 ack，避免无限重投
            log.error("poison message, msgId={}, payload={}", msgId, record.value(), e);
            kafkaTemplate.send("order-events.DLT", record.key(), record.value());
            ack.acknowledge();
        }
    }

    private void process(OrderEvent event) {
        // 业务逻辑：更新履约单、调用仓储
    }
}
```

关键点解释：

1. **重复消息也必须 ack**。否则它会被反复投递，把消费线程占满。幂等层判断重复后直接 ack 是正确做法。
2. **死信要 ack**。毒消息（反序列化失败、字段缺失）重试一万次也不会成功。
3. **可重试异常要抛出去**，交给容器的 `DefaultErrorHandler` 做退避重试。
4. **`concurrency=4`** 对应 4 个消费线程，每个线程独立 poll，实际并发受分区数限制（一个分区只能被一个线程消费）。

---

## 五、位移重置：`auto.offset.reset` 与线上操作

### 5.1 三个取值

| 值 | 行为 |
|---|---|
| `latest`（默认） | 无位移时从 LEO 开始，只消费新消息 |
| `earliest` | 无位移时从 0 开始，全量重放 |
| `none` | 无位移时直接抛 `NoOffsetForPartitionException` |

⚠️ 注意：这个参数**只在「没有 committed offset」时生效**，不是「每次都从这开始」。这是面试高频陷阱题。

### 5.2 线上重置位移的正确姿势

**不要**用「停消费 + 删 group + 重启」这种土办法，会丢掉所有分区的进度。

用官方工具：

```bash
# 1) 先停掉所有消费者（必须，否则重置会被运行中的消费者覆盖）
kubectl scale deploy/fulfillment --replicas=0

# 2) 干跑，确认要动哪些分区
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group fulfillment-service --topic order-events \
  --reset-offsets --to-datetime 2026-10-21T00:00:00.000 \
  --dry-run

# 3) 真正执行
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group fulfillment-service --topic order-events \
  --reset-offsets --to-datetime 2026-10-21T00:00:00.000 \
  --execute

# 4) 验证
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --group fulfillment-service --describe
```

支持的目标：`--to-earliest`、`--to-latest`、`--to-offset N`、`--to-datetime`、`--shift-by N`（负数回退）。

**重置前必须确认**：下游是否幂等。回退位移 = 必然重复消费。

---

## 六、Lag 监控：怎么算才是对的

`kafka-consumer-groups.sh --describe` 的 `LAG` 列是：

```
LAG = LOG-END-OFFSET - CURRENT-OFFSET
```

但这里有两个坑：

**坑 1：`CURRENT-OFFSET` 是 committed offset，有延迟。** 消费者正在处理但还没提交的那批消息，会被算进 lag。所以 lag 有轻微抖动是正常的。

**坑 2：lag 短暂为负。** 当消费者提交了位移但 broker 的 LEO 还没更新（副本同步延迟），会出现 `LAG = -1`。这是正常的，不用报警。

用 Java 自己算（Micrometer 指标）：

```java
@Component
@RequiredArgsConstructor
public class LagMonitor {

    private final AdminClient adminClient;
    private final MeterRegistry meterRegistry;

    @Scheduled(fixedDelay = 30_000)
    public void report() {
        Map<TopicPartition, OffsetAndMetadata> committed =
            adminClient.listConsumerGroupOffsets("fulfillment-service")
                       .partitionsToOffsetAndMetadata().join();

        Map<TopicPartition, Long> endOffsets =
            adminClient.listOffsets(committed.keySet().stream()
                        .collect(Collectors.toMap(tp -> tp, tp -> OffsetSpec.latest())))
                       .all().join()
                       .entrySet().stream()
                       .collect(Collectors.toMap(Map.Entry::getKey, e -> e.getValue().offset()));

        committed.forEach((tp, om) -> {
            long lag = endOffsets.getOrDefault(tp, om.offset()) - om.offset();
            meterRegistry.gauge(
                "kafka.consumer.lag",
                Tags.of("topic", tp.topic(), "partition", String.valueOf(tp.partition())),
                Math.max(lag, 0)
            );
        });
    }
}
```

报警规则建议：

- `lag > 10000` 持续 5 分钟 → 警告；
- `lag` 持续增长且消费速率下降 → 严重（说明消费能力不足或卡住）；
- **`lag = 0` 但业务数据没更新** → 最危险，说明消费在空转（比如反序列化后过滤掉了）。

---

## 七、重复消费的四种治理方案

「至少一次」是 Kafka 的默认语义，重复不可避免。治理思路是**让重复变得无害**。

| 方案 | 实现 | 优点 | 缺点 |
|---|---|---|---|
| **唯一键去重表** | `INSERT ... ON DUPLICATE KEY` / 唯一索引 | 强一致、简单 | 每笔写一次 DB |
| **Redis SETNX** | `SET msgId NX EX 1800` | 快 | 有 TTL，超时后可能重复 |
| **状态机** | 只允许 `待支付 → 已支付`，重复事件直接忽略 | 业务语义清晰 | 需要设计状态 |
| **版本号/时间戳** | `UPDATE ... WHERE version < ?` | 天然幂等 | 要求事件有序 |

生产上通常是**组合拳**：Redis 做第一层快速去重（挡住 99%），DB 唯一索引做最终兜底。

```java
public void process(OrderEvent event) {
    // 第一层：Redis 快速去重
    Boolean first = redis.opsForValue()
        .setIfAbsent("evt:" + event.eventId(), "1", Duration.ofHours(2));
    if (Boolean.FALSE.equals(first)) {
        return;
    }
    // 第二层：DB 唯一约束兜底
    try {
        orderMapper.updateStatus(event.orderId(), event.fromStatus(), event.toStatus());
    } catch (DuplicateKeyException e) {
        log.info("already processed, orderId={}", event.orderId());
    }
}
```

---

## 八、面试高频追问

**Q1：`enable.auto.commit=true` 时，offset 到底在哪一刻提交？**
在 `poll()` 调用内部，由 `ConsumerCoordinator.maybeAutoCommitOffsetsAsync()` 触发，条件是两个：`auto.commit.interval.ms` 到期 **且** 有未提交的位点。提交的是「上一次 poll 返回的最后一条记录的 offset + 1」。

**Q2：手动提交 `commitSync` 失败怎么办？**
`commitSync` 内部会对可重试异常（`RetriableException`）无限重试直到成功或超时（`default.api.timeout.ms`）。所以它可能阻塞很久。生产上建议设 `default.api.timeout.ms` 并在外层加超时保护。

**Q3：rebalance 时位移是怎么交接的？**
旧 owner 在 `onPartitionsRevoked` 里提交最终位移（如果是 eager 协议），新 owner 在 `onPartitionsAssigned` 里从 broker 拉取 committed offset。如果旧 owner 没来得及提交，新 owner 就从上一次提交点开始——重复。

**Q4：为什么我的消费者一直 rebalance？**
排查顺序：(1) `max.poll.interval.ms` 是否超时（处理太慢）；(2) `session.timeout.ms` 是否太短（GC 停顿/网络抖动）；(3) 是否有多个实例用同一个 `client.id`；(4) 是否有人频繁上下线；(5) 是否用了 `CooperativeStickyAssignor` 但客户端版本不匹配。

**Q5：`__consumer_offsets` 可以改分区数吗？**
不能直接改。它是内部 topic，修改分区数会破坏 key 到分区的映射，导致已有位移读不到。官方明确不支持。

---

## 九、总结

- **offset 是「下一条要消费的位置」**，提交时记得 `+1`。
- 自动提交在 `poll()` 内部发生，提交的是上一批的末尾，**处理失败也照提**——业务消息必须手动提交。
- `AckMode` 与 `enable-auto-commit` 必须成对配置，否则 Spring 的 ack 静默失效。
- 重复消费治不了「不发生」，只能治「无害」：Redis 快筛 + DB 唯一键兜底 + 状态机。
- lag 看趋势不看瞬时值，`lag=0` 但业务没动，比 lag 高更可怕。
- 重置位移前先停消费者，先 dry-run，先确认下游幂等。

Kafka 的位移机制设计得很克制：它只保证「至少一次」，把「恰好一次」的责任交给了业务。理解这一点，很多线上问题就不再是玄学。
