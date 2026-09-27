---
title: 【消息队列】RocketMQ 延迟消息深度解析：从 18 个延迟级别到任意时间定时消息
date: 2026-09-27 08:20:00
tags:
  - RocketMQ
  - 消息队列
  - 源码
  - 架构设计
categories:
  - 消息队列
  - 中间件
author: 东哥
---

# 【消息队列】RocketMQ 延迟消息深度解析：从 18 个延迟级别到任意时间定时消息

## 面试官：订单 30 分钟未支付自动关闭，你怎么实现？

这是最经典的延迟消息场景题。候选人的答案通常有三种：

1. 「用定时任务扫描订单表」；
2. 「用 RabbitMQ 的死信队列 + TTL」；
3. 「用 RocketMQ 的延迟消息，`delayLevel=16`」。

如果答第 3 种，我会继续追问：

- 「`delayLevel=16` 代表延迟多久？」
- 「为什么 RocketMQ 4.x 只有 18 个固定级别，不能任意时间？」
- 「延迟消息是存在哪里的？它和普通消息在存储上有什么区别？」
- 「如果我要延迟 2 小时，你会怎么写？」
- 「RocketMQ 5.x 的定时消息是怎么做到任意时间的？」

这一串问题下去，能完整答上来的候选人非常少。而这篇文章，就是把这串问题从头到尾讲清楚。

---

## 一、为什么需要延迟消息

延迟消息（也叫定时消息）指：**消息发送到 Broker 后，不立即投递给消费者，而是等待指定时间后才可见。**

典型场景：

| 场景 | 延迟需求 |
| --- | --- |
| 订单超时未支付自动关闭 | 30 分钟 |
| 优惠券到期提醒 | 提前 1 天 / 1 小时 |
| 支付结果查询重试 | 5s / 10s / 30s / 1m / 5m（阶梯重试） |
| 用户注册后 N 天未下单营销触达 | 3 天 |
| 外卖配送超时预警 | 45 分钟 |
| 分布式事务的本地消息表补偿 | 秒级 |

**为什么不用定时任务扫表？** 因为：

1. 扫表有精度和延迟的 trade-off：扫描间隔 1 分钟，就有最多 1 分钟的误差；间隔太短又会给 DB 造成压力；
2. 大表扫描（几十万待处理订单）性能堪忧，需要分库分表 + 索引设计；
3. 水平扩展困难，多个实例扫同一张表要做分布式锁；
4. **本质上是「轮询模型」，消息队列的延迟投递是「事件模型」，后者更高效。**

---

## 二、RocketMQ 4.x 的延迟消息：18 个固定级别

### 2.1 延迟级别定义

RocketMQ 4.x 内置 18 个延迟级别，定义在 `MessageDelayLevel` 中：

```
1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h
```

对应关系：

| delayLevel | 延迟时间 | delayLevel | 延迟时间 |
| --- | --- | --- | --- |
| 1 | 1s | 10 | 6m |
| 2 | 5s | 11 | 7m |
| 3 | 10s | 12 | 8m |
| 4 | 30s | 13 | 9m |
| 5 | 1m | 14 | 10m |
| 6 | 2m | 15 | 20m |
| 7 | 3m | 16 | **30m** |
| 8 | 4m | 17 | 1h |
| 9 | 5m | 18 | 2h |

所以「订单 30 分钟未支付关闭」用 `delayLevel = 16`。

**注意 `delayLevel=0` 表示不延迟（立即投递）。**

使用方式：

```java
Message message = new Message(
        "ORDER_TOPIC",
        "ORDER_TIMEOUT",
        orderId.getBytes(StandardCharsets.UTF_8));

// 方式一：设置延迟级别
message.setDelayTimeLevel(16);   // 30 分钟

producer.send(message);
```

RocketMQ 5.x 之后提供了更友好的 API：

```java
// 方式二：直接设置延迟时间（5.x）
message.setDelayTimeSec(1800);                    // 1800 秒后投递
// 或
message.setDeliverTimeMs(System.currentTimeMillis() + 1800_000L);
```

**但 5.x 的 `setDelayTimeSec` 底层也是映射到延迟级别**（如果 Broker 未开启定时消息功能），或者走新的 TimerWheel 机制（如果开启了 `timerWheel`）。这点后面详细说。

### 2.2 延迟消息的存储实现在哪？

这是面试的重点，也是很多人答不出来的地方。

**核心设计：延迟消息会被「改写」到一个内部 Topic 里。**

流程如下：

```
1. Producer 发送带 delayLevel 的消息到 Broker
2. Broker 在 CommitLog 中正常存储（和普通消息一样），
   但会把消息的 Topic 和 QueueId 替换为：
      Topic   -> SCHEDULE_TOPIC_XXXX
      QueueId -> delayLevel - 1
   并在消息属性里保留原始 Topic/QueueId（PROPERTY_REAL_TOPIC / PROPERTY_REAL_QUEUE_ID）
3. ConsumeQueue 中也记录为 SCHEDULE_TOPIC_XXXX 的对应队列
4. Broker 启动一个定时任务 ScheduleMessageService，
   为每个 delayLevel 创建一个 Timer，定时扫描对应 ConsumeQueue
5. 到达延迟时间后，把消息的 Topic 还原为原始 Topic，
   重新写入 CommitLog（这次是真的投递），消费者就能消费到了
```

源码关键点（`ScheduleMessageService`）：

```java
// 每个延迟级别一个 TimerTask
for (Map.Entry<Integer, Long> entry : delayLevelTable.entrySet()) {
    int level = entry.getKey();
    long delayTime = entry.getValue();

    Timer timer = new Timer("ScheduleMessageTimerThread_" + level, true);
    timer.scheduleAtFixedRate(new DeliverDelayedMessageTimerTask(level, offset), ...);
}
```

`DeliverDelayedMessageTimerTask` 的逻辑：

```java
// 1. 从 SCHEDULE_TOPIC_XXXX 的 ConsumeQueue 中拉取消息
MessageExt msg = ...;

// 2. 判断是否到期
long deliverTimestamp = msg.getStoreTimestamp() + delayLevelTable.get(level) * 1000;
if (System.currentTimeMillis() >= deliverTimestamp) {
    // 3. 还原原始 Topic 和 QueueId
    MessageExtBrokerInner msgInner = ...;
    msgInner.setTopic(msg.getProperty(MessageConst.PROPERTY_REAL_TOPIC));
    msgInner.setQueueId(Integer.parseInt(msg.getProperty(MessageConst.PROPERTY_REAL_QUEUE_ID)));

    // 4. 重新写入 CommitLog（实际上是再次存储，消费者此时可见）
    putMessage(msgInner);
}
```

**结论**：延迟消息在磁盘上**存了两份**（一份 SCHEDULE_TOPIC 的原始消息，一份投递时的重写消息）。这也是为什么大量使用延迟消息会放大存储和 IO 压力。

### 2.3 关键配置：`messageDelayLevel`

在 `broker.conf` 中可以自定义延迟级别：

```properties
# 自定义延迟级别（必须是 18 个？不，可以任意个数，但要注意顺序以 s/m/h/d 结尾）
messageDelayLevel=1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h
```

**注意**：修改 `messageDelayLevel` 后，**已经投递的延迟消息不受影响**（因为级别 -> 时间的映射在投递时才读取），但**队列数量会变化**（`SCHEDULE_TOPIC_XXXX` 的队列数 = 级别数），需要重启 Broker。

### 2.4 4.x 延迟消息的四大痛点

| 痛点 | 说明 |
| --- | --- |
| **只能是固定 18 个级别** | 要延迟 45 分钟？做不到，只能用 1h 或 30m |
| **延迟精度差** | 定时器默认每 100ms 扫一次，但消费的是整级队列，实际延迟有抖动 |
| **存储翻倍** | 磁盘占两倍，IO 也翻倍 |
| **同一 level 的消息串行投递** | `SCHEDULE_TOPIC_XXXX` 的单个队列中，如果队头消息未到期，后面的消息即使到期也要等（**队列是顺序扫描的！**） |

最后一条特别重要，很多人踩过坑：

```
delayLevel=5 队列里：
  msg1 (storeTimestamp=T, 需等 1m, 到期时间 T+60s)
  msg2 (storeTimestamp=T+30s, 需等 1m, 到期时间 T+90s)

在 T+60s 时：
  扫到 msg1，投递，offset++；
  扫到 msg2，未到期 -> break（注意是 break 不是 continue）
  -> 定时器 reset offset，下次从 msg2 开始
```

**注意：如果消息是「先存的消息延迟级别小、后存的消息延迟级别大」，不会阻塞；但如果是同一个队列里消息的到期时间乱序，就会导致后面到期的消息被前面的长延迟消息阻塞。** 因为 RocketMQ 4.x 的扫描逻辑遇到未到期消息就 `break`（依赖同队列内 storeTimestamp 递增，从而到期时间递增）。

由于 `SCHEDULE_TOPIC_XXXX` 的队列是按 delayLevel 划分的，**同一队列内所有消息的延迟时长相同**，storeTimestamp 递增 → 到期时间递增，所以不会乱序。这个设计是「用队列隔离级别」换来的正确性。

### 2.5 一个真实的踩坑：延迟级别满了怎么办？

**问题**：产品要求「延迟 45 分钟」，但只有 30m 和 1h 两个选项。

**方案一：降级到 1h**（业务能接受就最省事，但会晚 15 分钟）。

**方案二：二次延迟**（自己实现补偿）：

```java
// 先用 30m 级别，消费时判断是否到期，未到期再发一次
consumer.registerMessageListener((MessageListenerConcurrently) (msgs, ctx) -> {
    for (MessageExt msg : msgs) {
        long targetTime = Long.parseLong(msg.getUserProperty("targetTime"));
        if (System.currentTimeMillis() >= targetTime) {
            processOrderTimeout(msg);
        } else {
            // 还没到，再发一个延迟消息补差
            long remain = targetTime - System.currentTimeMillis();
            Message again = new Message("ORDER_TOPIC", msg.getBody());
            again.setDelayTimeLevel(levelFor(remain));   // 只能选 <= remain 的最大级别
            again.putUserProperty("targetTime", String.valueOf(targetTime));
            producer.send(again);
        }
    }
    return ConsumeConcurrentlyStatus.CONSUME_SUCCESS;
});
```

**方案三：升级到 RocketMQ 5.x 用定时消息**（下文详述）。

**方案四：改用时间轮/时间堆自行实现**（引入复杂度，不推荐）。

---

## 三、RocketMQ 5.x 定时消息（Timer Message）

RocketMQ 5.0 引入了**任意时间精度**的定时消息，原理基于**时间轮（Timing Wheel）+ 两层日志文件**。

### 3.1 整体架构

```
                    ┌──────────────────────────────┐
   Producer ───────▶│  CommitLog + ConsumeQueue    │ (正常存储)
   (deliverTimeMs)  └──────────────────────────────┘
                              │ 提取定时消息
                              ▼
                    ┌──────────────────────────────┐
                    │  TimerWheel (时间轮, 内存)     │
                    │  - 每个槽对应一个时间范围      │
                    │  - 槽内是链表，指向 TimerLog   │
                    └──────────────────────────────┘
                              │ 到期槽
                              ▼
                    ┌──────────────────────────────┐
                    │  TimerLog (磁盘文件)          │
                    │  - TimerLogFile 按大小滚动     │
                    │  - 记录真实消息的位置/位移     │
                    └──────────────────────────────┘
                              │ 拉取真实消息
                              ▼
                    ┌──────────────────────────────┐
                    │  重新投递到原始 Topic          │
                    └──────────────────────────────┘
```

### 3.2 时间轮参数

关键参数（`broker.conf`）：

```properties
# 时间轮基本单元：每个刻度 1000ms
timerPrecisionMs=1000

# 时间轮槽位数：默认 604800000 / 1000 = 604800 个槽（7天）？不对，看下面
# 实际参数：
#   timerWheel 共 6048 个槽（按默认精度 1000ms，最远 3600 * 1000ms = 1小时水位）
#   超过 1 小时的定时消息会走「分段 + 链表」逐级传递
```

精确一点说，RocketMQ 的 TimerWheel 参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `timerPrecisionMs` | 1000 | 时间轮刻度精度（ms） |
| `timerRollWindowSlot` | 3600 | 单圈槽数（精度 1000ms 时 = 1 小时） |
| `timerInterceptDelayMs` | 0 | 若定时时间小于该值，走延迟消息（快速路径） |
| `enableTimerWheel` | true | 是否启用时间轮（5.x） |
| `timerStopTimeBoundary` | - | 定时时间上限（默认约 2 天） |

**设计精髓**：

1. **轻量内存索引 + 磁盘日志**：时间轮只在内存存「槽 -> TimerLog 偏移量」的映射，真实消息仍在 CommitLog/TimerLog 里，内存不会随消息量线性增长；
2. **单圈 + 溢出轮**：超过一圈时间的定时消息，放入更高层的轮（类似层级时间轮），逐级下沉；
3. **只有到期的槽才会被扫描**，避免了 4.x「扫整级队列」的低效。

### 3.3 与 4.x 的本质区别

| 维度 | 4.x 延迟消息 | 5.x 定时消息 |
| --- | --- | --- |
| 时间精度 | 固定 18 级 | 任意毫秒（受 `timerPrecisionMs` 限制） |
| 精度误差 | 秒~分钟级 | 通常 < 1s |
| 时间范围 | 最长 2h | 最长 2 天（可配） |
| 存储位置 | CommitLog（重写 Topic） | CommitLog + TimerLog |
| 内存占用 | 低 | 时间轮索引，可控 |
| 扫描方式 | 每级独立定时任务 | 时间轮到期槽驱动 |
| 消息是否存两份 | 是 | 是（TimerLog + CommitLog） |
| 幂等要求 | 需要 | 需要（可能重复投递） |

### 3.4 使用方式

```java
// 5.x 客户端
Message message = new Message("ORDER_TOPIC", "ORDER_TIMEOUT", orderId.getBytes());

// 指定绝对投递时间（毫秒时间戳）
message.setDeliverTimeMs(System.currentTimeMillis() + 45 * 60 * 1000L);

// 或指定相对延迟（秒）
message.setDelayTimeSec(45 * 60);

producer.send(message);
```

⚠️ **注意**：`setDelayTimeSec` 在 5.x 里默认会**优先尝试定时消息**，如果 `enableTimerWheel=false` 或时间超出边界，则退化到延迟级别（会被对齐到最近级别，导致精度下降）。**上线前一定要确认 Broker 的 `enableTimerWheel` 状态。**

---

## 四、延迟消息的可靠性设计

这是生产落地最容易出问题的地方。

### 4.1 消息可能重复

RocketMQ 保证 **at-least-once**，延迟消息在「投递阶段」如果 Broker 重启、时间轮重建失败，都可能重复。

所以**消费端必须幂等**：

```java
@RocketMQMessageListener(topic = "ORDER_TOPIC", consumerGroup = "order_timeout_group")
public class OrderTimeoutConsumer implements RocketMQListener<MessageExt> {

    @Autowired
    private OrderMapper orderMapper;

    @Autowired
    private IdempotentHelper idempotentHelper;

    @Override
    public void onMessage(MessageExt message) {
        String orderId = new String(message.getBody(), StandardCharsets.UTF_8);

        // 幂等：以「订单关闭」这个动作 + 订单号做唯一键去重
        String idemKey = "close_order:" + orderId;
        if (!idempotentHelper.tryLock(idemKey, 10, TimeUnit.MINUTES)) {
            log.warn("重复消息，忽略: {}", orderId);
            return;
        }

        try {
            // 条件更新：只有「待支付」状态才关闭，天然幂等
            int affected = orderMapper.closeIfUnpaid(orderId);
            log.info("订单超时关闭: orderId={}, affected={}", orderId, affected);
        } finally {
            idempotentHelper.unlock(idemKey);
        }
    }
}
```

对应 SQL（**状态机 + 条件更新是天然幂等**）：

```xml
<update id="closeIfUnpaid">
    UPDATE t_order
    SET status = 'CLOSED', close_time = NOW()
    WHERE order_id = #{orderId}
      AND status = 'UNPAID'
</update>
```

### 4.2 消息可能丢失

延迟消息丢失的场景：

1. Broker 刷盘失败（异步刷盘 + 宕机）；
2. 时间轮重建时未正确恢复（5.x 已知问题，早期版本有 bug）；
3. 消费者处理异常但返回了 `CONSUME_SUCCESS`。

**兜底手段**：

- **本地消息表 + 定时补偿**：延迟消息是快路径，兜底是扫表慢路径；
- **延迟消息 + 定时巡检**：延迟消息负责「及时性」，兜底任务负责「不漏」；
- 消费端返回 `RECONSUME_LATER`，配合重试队列。

```java
@Override
public ConsumeConcurrentlyStatus consumeMessage(List<MessageExt> msgs,
                                               ConsumeConcurrentlyContext context) {
    try {
        doProcess(msgs);
        return ConsumeConcurrentlyStatus.CONSUME_SUCCESS;
    } catch (Exception e) {
        log.error("处理失败", e);
        return ConsumeConcurrentlyStatus.RECONSUME_LATER;   // 触发重试
    }
}
```

### 4.3 延迟消息 vs 其他方案对比

| 方案 | 精度 | 可靠性 | 复杂度 | 适用 |
| --- | --- | --- | --- | --- |
| 定时任务扫表 | 分钟级 | 高（DB 持久） | 低 | 量小、精度要求低 |
| DB 定时任务 + 分片 | 秒级 | 高 | 中 | 量中等 |
| Redis ZSet 延迟队列 | 秒级 | 中（需持久化） | 中 | 量小、可容忍丢失 |
| JDK `DelayQueue` | 高 | 低（单机内存） | 低 | 单机、可丢 |
| 时间轮（Netty/Kafka 风格） | 高 | 低（内存） | 中 | 进程内 |
| **RocketMQ 4.x 延迟消息** | 固定级别 | 高 | 低 | 匹配级别即可 |
| **RocketMQ 5.x 定时消息** | 秒级 | 高 | 低 | 推荐 |
| RabbitMQ TTL + DLX | 秒级 | 高 | 中 | 需注意队头阻塞 |
| RabbitMQ 延迟插件 | 秒级 | 高 | 低 | 推荐 |

**特别提醒 RabbitMQ 的坑**：用「TTL + 死信队列」实现延迟消息时，如果**同一个队列里消息的 TTL 不同**，会有严重的**队头阻塞**——队头长 TTL 消息未过期，后面的短 TTL 消息即使过期也不会进入死信队列。解决办法是**每个 TTL 一个队列**（和 RocketMQ 4.x 按 level 分队列是同一个思路）。

---

## 五、源码级：4.x 延迟消息投递的完整链路

把关键源码串一遍，面试时能讲出类名和文件名会加分很多。

### 5.1 发送阶段：`CommitLog#putMessage`

```java
// CommitLog.java
private PutMessageResult putMessage(DispatchRequest request) {
    // ...
    String topic = msg.getTopic();
    int queueId = request.getQueueId();

    // 关键：如果 delayLevel > 0，改写 topic
    if (msg.getDelayTimeLevel() > 0) {
        if (msg.getDelayTimeLevel() > this.defaultMessageStore.getMessageDelayLevel()) {
            msg.setDelayTimeLevel(this.defaultMessageStore.getMessageDelayLevel());
        }
        topic = TopicValidator.RMQ_SYS_SCHEDULE_TOPIC;   // SCHEDULE_TOPIC_XXXX
        queueId = msg.getDelayTimeLevel() - 1;

        // 保留原始信息，用于到期后还原
        if (msg.getPropertiesString() == null) {
            msg.putProperty(MessageConst.PROPERTY_REAL_TOPIC, msg.getTopic());
        } else {
            // 追加 PARSE 属性（用空格分隔，追加替换）
            msg.putProperty(MessageConst.PROPERTY_REAL_TOPIC, msg.getTopic());
            msg.putProperty(MessageConst.PROPERTY_REAL_QUEUE_ID, String.valueOf(request.getQueueId()));
        }

        request.setTopic(topic);
        request.setQueueId(queueId);
        // 设置 tags 为 null，避免 SCHEDULE_TOPIC 的 tag 过滤
        msg.setTags(MessageConst.PROPERTY_SCHEDULE_TAGS);
    }
    // 写入 CommitLog ...
}
```

### 5.2 投递阶段：`DeliverDelayedMessageTimerTask#executeOnTimeup`

```java
// ScheduleMessageService.java
public void executeOnTimeup() {
    // 1. 从 SCHEDULE_TOPIC_XXXX 对应 level-1 的队列读 ConsumeQueue
    ConsumeQueue cq = this.defaultMessageStore.findConsumeQueue(
            TopicValidator.RMQ_SYS_SCHEDULE_TOPIC, queueId);
    SelectMappedBufferResult bufferCQ = cq.getIndexBuffer(this.offset);
    // ...

    // 2. 遍历，判断是否到期
    for (; i < bufferCQ.getSize(); i += ConsumeQueue.CQ_STORE_UNIT_SIZE) {
        long offsetPy = bufferCQ.getByteBuffer().getLong();
        int sizePy = bufferCQ.getByteBuffer().getInt();
        long tagsCode = bufferCQ.getByteBuffer().getLong();   // 这里存的是「投递时间戳」

        long now = System.currentTimeMillis();
        long deliverTimestamp = this.correctDeliverTimestamp(now, tagsCode);

        nextOffset = offset + i / ConsumeQueue.CQ_STORE_UNIT_SIZE;

        if (deliverTimestamp <= now) {
            // 3. 到期，回读 CommitLog 拿到真实消息体
            MessageExt msgExt = this.defaultMessageStore.lookMessageByOffset(offsetPy, sizePy);
            // 4. 还原 Topic/QueueId 后重新投递
            MessageExtBrokerInner msgInner = messageTimeup(msgExt);
            // ...
            PutMessageResult putMessageResult = this.scheduleMessageService
                    .getDefaultMessageStore().putMessage(msgInner);

            if (putMessageResult.getPutMessageStatus() == PutMessageStatus.PUT_OK) {
                continue;   // 继续处理下一条
            }
        } else {
            // 5. 未到期：重置 offset，等下次定时触发
            if (i > 0) {
                this.scheduleMessageService.updateOffset(queueId, nextOffset, ...);
            }
            break;   // ⚠️ 关键：break，依赖队列内到期时间有序
        }
    }
    // ...
    // 6. 处理完换出，再调度自己
    if (bufferCQ != null) { bufferCQ.release(); }
    this.scheduleNextTimerTask(nextOffset, DELAY_FOR_A_WHILE);   // 100ms 后再次触发
}
```

**关键点**：
- `tagsCode` 在 `SCHEDULE_TOPIC` 里存的是**投递时间戳**（不是 tag 的 hash），这是为了扫描时无需回读 CommitLog 就能判断是否到期（性能优化）；
- `correctDeliverTimestamp` 处理了「时间回拨」场景；
- `break` 而非 `continue`，依赖「同队列内到期时间有序」这一不变量。

### 5.3 时间轮（5.x）：`TimerMessageStore`

```java
// TimerMessageStore.java
// 核心字段
private volatile TimerWheel timerWheel;          // 内存时间轮
private volatile TimerLog timerLog;              // 磁盘日志

// 1. 从 CommitLog 分发时，若消息是定时消息，加入时间轮
public void addTimerMessage(MessageExtBrokerInner msg, long deliverTimeMs) {
    // 写入 TimerLog
    TimerRequest timerRequest = new TimerRequest(msg, deliverTimeMs);
    timerLog.append(timerRequest);
    // 加入时间轮对应槽
    timerWheel.addSlot(timerRequest);
}

// 2. 定时任务：每 timerPrecisionMs 推进一个槽
public void run() {
    while (!isStopped()) {
        // 获取到期槽
        LinkedList<TimerRequest> requests = timerWheel.getSlot(now);
        // 从 TimerLog 拉取真实消息并投递
        for (TimerRequest req : requests) {
            doEnqueue(req);   // 重新写入 CommitLog，还原原 Topic
        }
        Thread.sleep(timerPrecisionMs);
    }
}
```

---

## 六、生产实践清单

### 6.1 容量规划

延迟消息**存储会占用 2 倍空间**（原始消息 + 重写消息），并且 `SCHEDULE_TOPIC_XXXX` 的 ConsumeQueue 也需要空间。如果延迟消息量很大（比如每单一条，日均 1000 万单），要提前评估磁盘。

建议：**延迟消息只用于「时间敏感 + 量可控」的场景**，大规模通知类改用定时任务扫表（成本更低）。

### 6.2 监控指标

```bash
# 各延迟级别队列的积压量
mqadmin consumerProgress -n 127.0.0.1:9876 -g SCHEDULE_TOPIC_XXXX

# 或者看 Broker 的定时消息统计
# 5.x: mqadmin statsMessageTimer / broker 指标
```

关键监控项：

| 指标 | 含义 | 告警阈值 |
| --- | --- | --- |
| 延迟消息积压量 | 各 level 队列未投递量 | 持续增长即异常 |
| 定时消息投递延迟 | 实际投递时间 - 目标时间 | > 10s |
| TimerLog 磁盘占用 | 定时日志文件大小 | 超过预期增长 |
| 投递失败率 | `putMessage` 返回非 OK | > 0.1% |

### 6.3 常见故障

| 故障 | 原因 | 处理 |
| --- | --- | --- |
| 延迟消息不投递 | 定时器线程挂了 / offset 异常 | 重启 Broker，检查 `SCHEDULE_TOPIC_XXXX` ConsumeQueue |
| 延迟消息大量重复 | 投递阶段重试 + 消费未幂等 | 消费端补幂等 |
| 延迟时间不准 | 4.x 队列扫描 + 单级任务压力 | 升级到 5.x 时间轮 |
| 磁盘暴涨 | TimerLog 未清理 | 检查 `timerLogFileSize` 与清理策略 |
| 延迟消息乱序 | 同一原始队列的消息被写入不同 level | 业务侧按 orderId 保证顺序 |

---

## 七、面试追问集

**Q1：`delayLevel=16` 是延迟多久？**

> 30 分钟。4.x 的 18 个级别依次是 `1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h`，从 1 开始编号，所以 16 是 30 分钟。

**Q2：延迟消息存在哪里？**

> 存在 **CommitLog** 里，但 Topic 被改写为 `SCHEDULE_TOPIC_XXXX`，QueueId = `delayLevel - 1`，原始 Topic/QueueId 保存在消息属性 `PROPERTY_REAL_TOPIC`/`PROPERTY_REAL_QUEUE_ID` 中。到期后由 `ScheduleMessageService` 的定时任务扫描对应 ConsumeQueue，还原 Topic 并再次写入 CommitLog 完成投递。

**Q3：为什么延迟消息会占两倍存储？**

> 因为投递时要「重写」：先按 `SCHEDULE_TOPIC_XXXX` 存一份，到期后再以原始 Topic 存一份。前者用于定时扫描，后者供消费者读取。所以磁盘和 IO 都是双份。

**Q4：4.x 为什么只能固定级别？**

> 设计上为了简化扫描：每个 level 一个独立队列 + 一个独立定时任务，队列内到期时间天然有序（因为延迟时长相同 + 存储时间递增），扫描时遇到未到期就 `break` 即可。如果要支持任意时间，就需要更复杂的数据结构（时间轮/最小堆），所以 5.x 才引入 TimerWheel。

**Q5：时间轮为什么比自己维护最小堆好？**

> 时间轮的插入和删除都是 O(1)（按槽定位），且天然按时间分桶，到期只需要扫描当前槽；最小堆插入 O(logN)，且需要频繁比较。时间轮的代价是「槽数量 × 精度」决定的时间跨度，超出跨度要走层级轮。RocketMQ 用「内存时间轮索引 + 磁盘 TimerLog」组合，避免了内存随消息量增长。

**Q6：延迟消息会丢吗？**

> 会。可能丢的场景：异步刷盘时 Broker 宕机、时间轮重建失败、消费端处理异常却返回成功。所以生产上一般用**「延迟消息 + 兜底扫表」双保险**：延迟消息保证及时性，扫表任务保证不漏，消费端再保证幂等。

**Q7：用 RocketMQ 实现「阶梯重试」（5s、10s、30s、1m、5m）怎么做？**

> 消费失败时返回 `RECONSUME_LATER`，用 RocketMQ 自带的重试机制（`%RETRY%group` 的 18 个重试级别，默认 `10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h`）。如果要精确控制，就在消费端手动发一条带指定 `delayTimeLevel` 的消息，并用 `userProperty` 记录重试次数（**消息自带的重试次数最多 16 次，超过进死信队列**）。

**Q8：延迟消息和分布式事务有什么配合？**

> 典型用法是**本地消息表 + 延迟消息做补偿**：事务提交后写一条延迟消息，若在延迟时间内收到下游成功确认则取消（用一个状态表标记），否则到期消费时触发补偿/回滚。RocketMQ 的事务消息（半消息 + 回查）解决的是「消息发送与本地事务的原子性」，延迟消息解决的是「超时补偿」，两者经常组合使用。

---

## 八、总结

| 版本 | 机制 | 精度 | 范围 | 关键类 |
| --- | --- | --- | --- | --- |
| 4.x | 18 个固定延迟级别 + 队列扫描 | 秒~分钟 | 最长 2h | `ScheduleMessageService`、`DeliverDelayedMessageTimerTask` |
| 5.x | 时间轮 + TimerLog | 毫秒~秒 | 最长 2 天 | `TimerMessageStore`、`TimerWheel`、`TimerLog` |

三句话记住核心：

1. **4.x 是「用队列隔离延迟级别」换来的扫描正确性**，代价是不支持任意时间；
2. **5.x 是「时间轮 + 磁盘日志」**，把内存索引和消息存储分离，支持任意时间；
3. **不管用哪个版本，消费端都必须幂等**，因为投递语义是 at-least-once。

最后一个实战建议：**延迟消息适合「时间点精确、量可控」的场景；如果是海量、精度要求不高的场景，定时任务扫表反而更省钱。** 技术选型从来不是「哪个先进用哪个」，而是「哪个匹配当前业务成本模型用哪个」。
