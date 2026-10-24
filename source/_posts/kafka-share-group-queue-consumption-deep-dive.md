---
title: 【Kafka 4.x】共享组（Share Group）深度解析：KIP-932 队列语义、协同消费与位移治理
date: 2026-10-24 08:15:00
tags:
  - Java
  - Kafka
  - KIP-932
  - 消息队列
  - 消费模型
categories:
  - Java 深挖
author: 东哥
---

# 【Kafka 4.x】共享组（Share Group）深度解析：KIP-932 队列语义、协同消费与位移治理

## 前言

Kafka 的经典消费模型是「**一个分区只能被同一个消费组内的一个消费者消费**」。这个模型简单、有序、位移管理清晰，但也带来三个绕不过去的限制：

1. **并发上限被分区数锁死**。一个 topic 只有 12 个分区，就算你有 200 个消费者实例，也只有 12 个在干活，其余 188 个空转。
2. **rebalance 代价高**。扩容、缩容、实例抖动都会触发分区重新分配，期间整个组消费停摆（KIP-848 的新协议缓解了这一点，但没改变「分区独占」的本质）。
3. **慢消息阻塞整条分区**。一条消息处理 30 秒，后面 10 万条就得排队等——因为同一个分区同一时刻只能有一个消费者持有。

对于「订单履约」「图片转码」「报表导出」这类**任务型**负载，我们真正想要的是**队列语义**：一条消息被一个 worker 拿走，处理完确认，其他人不要重复拿；处理超时自动重新投递。这正是 RabbitMQ / SQS / RocketMQ 的强项，而 Kafka 一直缺。

**KIP-932（Queues for Kafka）** 就是补这个缺口的：引入 **Share Group（共享组）**，让多个消费者**协同消费同一批分区**，以「单条记录」为单位做获取锁与确认。

> ⚠️ 版本说明：共享组在 Kafka 4.0 以 Early Access 形式引入，后续版本持续完善（配置项与方法签名有调整）。本文讲的是**模型与落地思路**，示例代码基于 4.0 的 `KafkaShareConsumer` API，实际落地前请对照你所用版本的官方 JavaDoc。

---

## 一、核心概念：从「分区独占」到「记录级协作」

### 1.1 传统消费组

```
Topic T (3 partitions)           Consumer Group G (2 consumers)
┌──────────┐                     ┌─────────────┐
│ P0 ──────┼────────────────────▶│ Consumer A  │  独占 P0、P1
│ P1 ──────┼────────────────────▶│             │
│ P2 ──────┼────────────────────▶│ Consumer B  │  独占 P2
└──────────┘                     └─────────────┘
```

消费者对分区是**排他**的。位移（offset）是按「消费组 + 分区」提交的，粒度是**分区级**。

### 1.2 共享组

```
Topic T (3 partitions)           Share Group SG (3 consumers)
┌──────────┐                     ┌─────────────┐
│ P0 ──────┼──┐                  │ Consumer A  │ 拿到 P0 的 record 0-9
│ P1 ──────┼──┼──▶ 协作分发 ────▶│ Consumer B  │ 拿到 P0 的 record 10-19 + P2 的 5-9
│ P2 ──────┼──┘                  │ Consumer C  │ 拿到 P1 的 record 20-29
└──────────┘                     └─────────────┘
```

**三个关键变化：**

| 维度 | 传统消费组 | 共享组 |
|---|---|---|
| 分配单位 | 分区 | **记录（record）** |
| 分区归属 | 排他 | **共享** |
| 确认粒度 | offset（分区级） | **单条记录 ack** |
| 顺序性 | 分区内有序 | **不保证**（同一分区可能被多个消费者并发处理） |
| 并发上限 | 分区数 | **消费者数**（受 broker 负载与锁容量限制） |
| 失败重投 | 靠位点回退 / 手动 seek | **锁超时自动重新投递**，带 delivery count |

### 1.3 关键机制

**① Acquisition Lock（获取锁）**

消费者拿到一批记录时，broker 会为这些记录加一个**有时限的锁**（默认 30 秒量级，由 `group.share.record.lock.duration.ms` 一类的配置控制）。在锁有效期内，这些记录不会被分配给其他消费者。

- 处理完了 → `acknowledge(record, ACCEPT)`，锁释放，记录标记为已消费；
- 处理不完 → `acknowledge(record, RELEASE)`，立刻释放锁给其他人；
- 明确失败 → `acknowledge(record, REJECT)`，记录进入「跳过」状态（不再重投，取决于配置）；
- **什么都不做** → 锁超时，记录**自动重新投递**给其他消费者。

这就是「至少一次」语义的天然实现，也意味着**你的消费逻辑必须幂等**。

**② Delivery Count（投递次数）**

每次记录被重新分配，它的投递次数 +1。达到上限（`group.share.max.delivery.count` 一类配置）后，记录会被归档到**死信（DLQ）**，避免一条毒消息无限循环。这是共享组相对传统消费组的一大进步——以前毒消息治理全靠自己写。

**③ Share Session（共享会话）**

共享组内部维护会话，用于跟踪「哪些消费者还活着、持有多少锁」。会话超时后，其持有的记录全部释放并重新分配。这比 rebalance 轻量得多：**新成员加入不会触发全组重平衡**，只是开始领取新记录。

**④ 状态持久化**

共享组的协作状态（每条记录的锁归属、投递次数、确认状态）持久化在内部 topic 中（`__share_group_state`）。这意味着 broker 重启后状态不丢，但也意味着**共享组会带来额外的写入放大**——这是它的成本。

---

## 二、状态机：一条记录的一生

```
        ┌──────────┐
        │ AVAILABLE│◀─────────────────┐
        └────┬─────┘                  │
             │ broker 分配给消费者      │ 锁超时 / RELEASE
             ▼                        │
        ┌──────────┐                  │
        │ ACQUIRED │──────────────────┘
        └────┬─────┘
             │ acknowledge
     ┌───────┼────────┐
     ▼       ▼        ▼
  ACCEPT  REJECT   (超时重投)
     │       │
     ▼       ▼
 ┌──────┐ ┌──────┐
 │ 完成  │ │ 跳过  │   delivery count 超限 → DLQ
 └──────┘ └──────┘
```

**注意一个反直觉的点**：共享组**没有「分区位移提交」这个概念**。它的进度是**每条记录的状态**，而不是一个数字。所以：

- 你不能再靠 `consumer.position()` 判断进度；
- 消费 lag 需要新的指标（未确认记录数），不能简单用 `log end offset - committed offset`；
- 监控面板要重做，这是落地时最容易漏的一环。

---

## 三、Java 落地：KafkaShareConsumer

### 3.1 基础配置

```java
Properties props = new Properties();
props.put("bootstrap.servers", "kafka-1:9092,kafka-2:9092");
props.put("group.id", "order-fulfillment-share");
props.put("group.protocol", "share");                     // ← 关键：声明这是共享组
props.put("key.deserializer",   "org.apache.kafka.common.serialization.StringDeserializer");
props.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
props.put("max.poll.records", "50");                       // 一次领取上限，直接影响锁压力
props.put("share.acknowledgement.mode", "explicit");       // 显式 ack，生产必选
props.put("group.share.record.lock.duration.ms", "60000"); // 按 P99 处理时长放宽
```

### 3.2 消费循环

```java
try (KafkaShareConsumer<String, String> consumer = new KafkaShareConsumer<>(props)) {
    consumer.subscribe(List.of("order-events"));

    while (!Thread.currentThread().isInterrupted()) {
        ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(500));
        if (records.isEmpty()) continue;

        for (ConsumerRecord<String, String> record : records) {
            try {
                handle(record);                                     // 业务处理
                consumer.acknowledge(record);                       // 默认 ACCEPT
            } catch (RetryableException e) {
                // 可重试：立刻释放，让别人拿走，别占着锁
                consumer.acknowledge(record, AcknowledgeType.RELEASE);
            } catch (PoisonMessageException e) {
                // 毒消息：直接拒绝，避免无限重投
                log.error("毒消息 partition={} offset={}", record.partition(), record.offset(), e);
                consumer.acknowledge(record, AcknowledgeType.REJECT);
            } catch (Exception e) {
                // 未知异常：不 ack，等锁超时自动重投
                log.error("处理失败，等待重投", e);
            }
        }
        // 批量确认模式下需要显式提交（explicit 模式下建议定期提交，减少往返）
        consumer.commitSync();
    }
}
```

**三个必须理解的行为：**

1. **不 ack ≠ 失败**。它只是「等锁超时」，会带来一次完整的锁等待延迟（默认几十秒），所以能明确表态就明确表态；
2. **`RELEASE` 会立刻让记录可被别人领取**，适合「依赖的下游暂时不可用」这类场景；
3. **`REJECT` 不重投**，务必只在确定是毒消息时使用，否则就是丢数据。

### 3.3 幂等：不是可选项

共享组天然「至少一次」，重复投递会在以下场景发生：

- 处理成功但 ack 请求丢失（网络抖动）；
- 处理时长超过锁时长，记录已被别人领走；
- 消费者崩溃，会话超时后记录重投。

所以消费逻辑必须幂等：

```java
@Transactional
public void handle(ConsumerRecord<String, String> record) {
    String msgId = record.headers().lastHeader("msg-id") != null
            ? new String(record.headers().lastHeader("msg-id").value(), StandardCharsets.UTF_8)
            : record.topic() + "-" + record.partition() + "-" + record.offset();

    // 唯一索引兜底：insert ignore / on duplicate key update
    if (!dedupRepository.tryMarkProcessed(msgId)) {
        log.info("重复消息，跳过: {}", msgId);
        return;
    }
    // 真正的业务
    orderService.fulfill(record.value());
}
```

**推荐用「业务唯一键」而不是 offset 做幂等键**——因为共享组下同一条消息可能在不同消费者上拿到同一个 offset，用 offset 做键是可行的，但业务唯一键更稳（能覆盖生产端重复发送）。

---

## 四、与传统消费组的完整对比

| 维度 | Consumer Group | Share Group |
|---|---|---|
| 语义 | 流（stream） | 队列（queue） |
| 顺序 | 分区内严格有序 | 不保证 |
| 并发扩展 | 受分区数限制 | 消费者数线性扩展 |
| 扩缩容 | 触发 rebalance | 增删成员，无全组重平衡 |
| 失败处理 | 位点回退 / 阻塞后续消息 | 单条重投，不阻塞其他消息 |
| 毒消息 | 自行实现 DLQ | 内置 delivery count + DLQ |
| 位移 | 分区 offset | 记录级状态（无 offset 概念） |
| 监控 | lag = LEO - committed | 未确认记录数 / 锁等待数 |
| 资源开销 | 低 | 较高（状态持久化 + 锁管理） |
| 适用 | 事件流、CDC、日志、需要顺序 | 任务队列、异步作业、慢任务、流量削峰 |

**一句话选型：**

> 需要「按 key 保序」→ 消费组；需要「横向扩容处理慢任务」→ 共享组。

---

## 五、什么时候真的该用它

### 适合

- **任务型负载**：每个消息是一个独立任务（转码、导出、对账、发券），任务之间无顺序依赖；
- **处理时长差异极大**：99% 的消息 10ms，1% 的消息 5 分钟。消费组里那个 5 分钟的消息会把整条分区堵死；共享组里它只是占一个 consumer；
- **突发流量削峰**：瞬时 10 万条任务，需要临时把 worker 从 20 扩到 200；
- **需要内置重试与 DLQ**：不想自己写「重试表 + 定时扫描」。

### 不适合

- **严格顺序**：同一订单的状态变更必须按序处理 → 用消费组 + key 分区；
- **需要精确的消费进度**：依赖 `committed offset` 做断点续传 / 数据校验；
- **超低延迟**：共享组的锁管理有额外开销，纯转发场景不如消费组；
- **老版本集群**：broker 必须支持共享组，客户端也要升级。

---

## 六、生产落地踩坑清单

### 坑 1：锁时长 < 处理时长 → 无限重复消费

```yaml
group.share.record.lock.duration.ms: 30000   # 30 秒
# 但你的下游调用 P99 是 45 秒
```

结果：每条消息都被处理两次以上，而且日志看起来「都成功了」。

**做法**：锁时长 ≥ 处理时长 P99.9 × 1.5。处理时长不可控（比如调外部 API）时，改用 `RELEASE` + 自建重试队列，而不是硬占锁。

### 坑 2：`max.poll.records` 开太大

一次领 500 条，锁 30 秒，实际处理完要 5 分钟 → 后面 450 条全超时重投，形成「**重投风暴**」，集群负载反而飙升。

**做法**：`max.poll.records` 从 10~50 起步，按实测吞吐调。

### 坑 3：用 lag 做告警

共享组没有 committed offset，原来的 `kafka_consumergroup_lag` 指标直接失效（显示为 0 或 NaN）。上线后「看起来一切正常」，实际上堆了几十万条未确认记录。

**做法**：改用「未确认记录数」「平均投递次数」「锁超时次数」三个指标。**平均投递次数 > 1.2 就说明有重复消费在发生**。

### 坑 4：把 `REJECT` 当 `RELEASE` 用

`REJECT` 不重投。如果你的 catch 块里图省事写了 `REJECT`，等于**静默丢消息**。

**做法**：`REJECT` 只用于「反序列化失败 / 业务校验永久失败」这类确定不可恢复的场景，并且必须打 error 日志 + 落库留痕。

### 坑 5：忘记处理 rebalance 后的「半成品」

消费者被分配到一批记录后崩溃，其中一部分已处理完但没 ack。重投后这些记录会被重复处理。如果处理逻辑不是幂等的，就是**重复扣款 / 重复发货**。

**做法**：幂等表 + 唯一索引，双保险。

### 坑 6：以为共享组能替代分区扩容

共享组的并发上限确实不再等于分区数，但**单个分区的读取吞吐仍有上限**。分区太小，broker 侧的读取会成为瓶颈。

**做法**：分区数仍要按目标吞吐规划，共享组解决的是「消费端并发」，不是「存储端并行度」。

### 坑 7：混用两种协议

同一个 `group.id` 不能既是 `classic` 又是 `share`。迁移时**必须换 group.id**，否则客户端直接报错。

**做法**：灰度期用双写或影子 topic，两个组并行跑，比对结果后再切流。

---

## 七、面试常见追问

**Q1：KIP-932 解决了什么问题？**

解决了 Kafka「分区独占」导致的三个问题：并发受分区数限制、慢消息阻塞分区、缺少内置重试与死信。它把消费语义从「流」扩展到「队列」，让 Kafka 能覆盖任务队列场景。

**Q2：共享组怎么保证不重复消费？**

**保证不了**，它只保证「至少一次」。去重必须靠消费端幂等（唯一键 / 幂等表 / 状态机）。共享组能做的是通过 delivery count + DLQ 控制重复的上限。

**Q3：共享组的分区顺序还有意义吗？**

没有。同一分区的不同记录可能被不同消费者并发处理，顺序完全丢失。需要顺序就必须用传统消费组。

**Q4：为什么共享组的状态要持久化？**

因为 broker 需要知道「某条记录被谁锁着、投递了几次」。不持久化的话 broker 重启就会把正在处理中的记录重新分配，导致大规模重复消费，delivery count 也会丢。代价是额外的内部 topic 写入。

**Q5：共享组和 RabbitMQ 的队列有什么本质区别？**

- RabbitMQ 是「消息从队列删除」，Kafka 是「日志追加 + 状态标记」，共享组的记录仍在日志里，只是被标记为已确认；
- Kafka 的共享组仍受分区存储模型约束，单分区吞吐有上限；
- Kafka 保留了「回放」能力（数据仍在），RabbitMQ 消费完就没了。

**Q6：迁移到共享组要注意什么？**

四件事：换 `group.id`、重做监控指标、消费逻辑幂等化、锁时长按 P99 调优。缺一项都别上生产。

---

## 八、总结

Kafka 共享组的意义，不是「Kafka 变成 RabbitMQ 了」，而是**同一个日志存储可以同时服务两种消费语义**：

- 需要顺序、回放、流处理 → 传统消费组；
- 需要弹性扩容、任务分发、内置重试 → 共享组。

落地时的三条铁律：

1. **幂等是前提**，不是优化项；
2. **锁时长必须大于处理时长**，否则重投风暴比原问题更严重；
3. **监控指标要重建**，lag 那一套在共享组里不成立。

如果你正在用「Kafka + 自建重试表 + 定时补偿」拼一个任务队列，共享组值得认真评估一次——它把这套基础设施的成本，从你的应用层挪回了 broker。
