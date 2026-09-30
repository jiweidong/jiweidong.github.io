---
title: 【消息队列】RocketMQ 事务消息深度解析：半消息、回查机制与分布式事务落地
date: 2026-09-30 08:00:00
tags:
  - RocketMQ
  - 消息队列
  - 分布式事务
  - 源码
categories:
  - 消息队列
  - 微服务
author: 东哥
---

# 【消息队列】RocketMQ 事务消息深度解析：半消息、回查机制与分布式事务落地

## 面试官：下单成功后要发消息扣积分，怎么保证"订单写了、消息也发了"？

这是分布式事务最经典的场景之一。候选人通常会给出三个答案：

1. 先写订单库，再发 MQ——**如果发消息失败，订单写了但积分不扣**；
2. 先发 MQ，再写订单——**如果写库失败，积分扣了但订单不存在**；
3. 用本地消息表——**可行，但要额外建表 + 定时任务兜底**。

第 4 个答案经常被忘掉：**RocketMQ 的事务消息**。它把"本地事务 + 消息发送"的原子性下沉到了 Broker 层，不需要业务方自己建兜底表。

但很多人的理解停留在"发个消息、执行本地事务、提交或回滚"这个层面，往下追问就答不上来了：

- 半消息（Half Message）存在哪里？能消费到吗？
- 为什么 RocketMQ 4.x 事务消息**不支持延迟消息**、不支持批量？
- 事务回查的触发条件是"超时"还是"没提交"？默认多久查一次？
- 回查次数有上限吗？超过会怎样？

本文从设计动机讲到源码实现，把这套机制彻底讲透。

## 一、要解决什么问题

### 1.1 本地消息表方案的痛点

先看最朴素可靠的方案——本地消息表：

```sql
CREATE TABLE t_local_message (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    biz_id VARCHAR(64) NOT NULL UNIQUE,
    topic VARCHAR(128) NOT NULL,
    payload TEXT NOT NULL,
    status TINYINT NOT NULL DEFAULT 0,  -- 0待发送 1已发送 2已完成
    retry_count INT DEFAULT 0,
    next_retry_time DATETIME,
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

流程：

```text
1. 开启本地事务
2. INSERT INTO t_order ...           ← 业务表
3. INSERT INTO t_local_message ...   ← 消息表（同一个事务）
4. COMMIT
5. 异步线程扫描 status=0 的记录，发 MQ，成功后置为 1
```

它的问题：

| 问题 | 说明 |
| --- | --- |
| 业务侵入 | 每张需要发消息的表都要配套一张消息表 |
| 额外扫描 | 定时任务扫描 + 重试，有延迟（秒级） |
| 表膨胀 | 消息表会随业务量线性增长，需要归档 |
| 重复投递 | 扫描线程并发时可能重复发送（要幂等） |

**RocketMQ 事务消息的目标：把第 3 步和第 5 步的职责搬到 MQ 侧，让业务代码只写自己的表。**

### 1.2 核心思路：两阶段提交的变体

RocketMQ 事务消息本质是**两阶段提交（2PC）**，但做了一次非常重要的改造——把"决定提交或回滚"的权力交给业务方，并且引入了**回查（Check Back）**机制来兜底"业务方没回应"的第三种状态：

```text
阶段一：发送半消息
    Producer → Broker：我要发消息，但先别投递
    Broker：收到，存起来，回复你"我存好了"（此时对 Consumer 不可见）

阶段二：执行本地事务
    Producer：执行数据库事务（写订单、扣库存...）
    ├─ 成功 → 向 Broker 发送 COMMIT
    ├─ 失败 → 向 Broker 发送 ROLLBACK
    └─ 超时/进程挂了/网络断了 → 什么都没发（消息处于"待确认"状态）
                                    ↓
                            ★ Broker 定期回查 Producer
                            Producer 回来查本地事务的最终状态，补发 COMMIT/ROLLBACK
```

这个"第三种状态"的处理，是 RocketMQ 事务消息与普通 2PC 最大的区别，也是它能在生产环境落地的关键。

## 二、半消息（Half Message）机制

### 2.1 半消息存在哪

半消息（也叫预备消息、Prepared Message）的存储方式很有讲究：

- **存放在真实 Topic 的 CommitLog 中**，但不是原 Topic，而是被替换成 `RMQ_SYS_TRANS_HALF_TOPIC`；
- 原有的 Topic 和 QueueId 被**备份到消息属性**里：

```java
// org.apache.rocketmq.common.message.MessageConst
public static final String PROPERTY_TRANSACTION_PREPARED = "TRAN_MSG";
public static final String PROPERTY_PRODUCER_GROUP = "PGROUP";
public static final String PROPERTY_MIN_OFFSET = "MIN_OFFSET";
public static final String PROPERTY_MAX_OFFSET = "MAX_OFFSET";
// 原始 topic / queueId 存在属性中：
// REAL_TOPIC = "REAL_TOPIC"
// REAL_QUEUE_ID = "REAL_QID"
```

Producer 发送半消息时，请求里带 `TRAN_MSG=true`，Broker 端的 `SendMessageProcessor` 会做 topic 替换：

```java
// SendMessageProcessor#sendMessage （简化）
String tranMsg = requestHeader.getProperty(MessageConst.PROPERTY_TRANSACTION_PREPARED);
if (tranMsg != null && Boolean.parseBoolean(tranMsg)) {
    // 关键：把 topic 换成半消息专用的系统 topic
    requestHeader.setTopic(
        MixAll.RMQ_SYS_TRANS_HALF_TOPIC);   // "RMQ_SYS_TRANS_HALF_TOPIC"
    // 把真实 topic 和 queueId 存进属性
    requestHeader.putProperty(MessageConst.PROPERTY_REAL_TOPIC, realTopic);
    requestHeader.putProperty(MessageConst.PROPERTY_REAL_QUEUE_ID, String.valueOf(queueId));
    // 标记为事务消息
    sysFlag |= MessageSysFlag.TRANSACTION_PREPARED_TYPE;
}
```

**为什么要换 Topic？** 因为 `RMQ_SYS_TRANS_HALF_TOPIC` **没有 Consumer 订阅**，所以消息虽然写进了 CommitLog，但**永远不会被投递**。这是一个非常巧妙的设计：

- 复用 CommitLog 的写入路径（顺序写、零拷贝、可靠性都有保障）；
- 靠"没有订阅者"实现"不可见"，比用单独的存储介质更简单高效。

### 2.2 从半消息到真实消息：Commit 做了什么

Commit 时，Broker 的 `EndTransactionProcessor` 会：

1. 找到半消息在 `RMQ_SYS_TRANS_HALF_TOPIC` 里的 CommitLog offset；
2. **把原消息重新写一遍**，但这次 topic 用真实 Topic，并把 `TRAN_MSG` 属性去掉、打上 `TRANSACTION_COMMIT_TYPE` 标记；
3. 写一条"Op 消息"（操作记录）到 `RMQ_SYS_TRANS_OP_HALF_TOPIC`，内容记录"这个半消息已被 commit/rollback"。

```java
// EndTransactionProcessor#processRequest （简化）
if (requestHeader.getCommitOrRollback() ==
        TransactionResolution.COMMIT_MESSAGE) {
    // 1. 从半消息构建真实消息
    MessageExtBrokerInner msgInner = endMessageTransaction(requestHeader,
            msgExt, tranStateTable.findOffset(...));
    // 2. 写回真实 topic
    PutMessageResult putMessageResult = this.brokerController
            .getMessageStore().putMessage(msgInner);
    // 3. 半消息本身被删掉（实际上是被标记为已完成）
}
```

**注意这里有个"双写"**：原始半消息 + 重新写入的真实消息。所以一条事务消息在 CommitLog 里**占两份空间**。这也是为什么 RocketMQ 不建议用事务消息承载超大 payload。

### 2.3 Rollback 做了什么

Rollback 比 Commit 更"轻"：

- **不写真实消息**，只写一条 Op 记录到 `RMQ_SYS_TRANS_OP_HALF_TOPIC`；
- 半消息本身仍然躺在 CommitLog 里（因为 CommitLog 只能追加，不能删除），但会被**定期清理**。

这也解释了为什么"回滚"事务消息实际上已经消耗了磁盘——**半消息已经写进去了，物理空间不会因为回滚而释放**，直到 CommitLog 过期删除。

## 三、事务回查（Transaction Check）机制

这是整套机制里最精妙、也最容易答不上来的部分。

### 3.1 回查的触发条件

**不是"超时"触发的，而是"没有被 Commit 或 Rollback"触发的。**

具体来说，Broker 端有一个定时任务 `TransactionalMessageCheckService`，默认**每 60 秒**执行一次（`transactionCheckInterval`，可配置）：

```java
// TransactionalMessageCheckService
public class TransactionalMessageCheckService extends ServiceThread {
    private BrokerController brokerController;

    @Override
    public void run() {
        while (!this.isStopped()) {
            this.waitForRunning(1000 * 60);   // 每 60 秒一轮

            try {
                // 核心：检查半消息
                brokerController.getTransactionalMessageService()
                        .check(this.brokerController.getMessageStore());
            } catch (Throwable e) {
                log.error("Failed to check transaction op message", e);
            }
        }
    }
}
```

`check()` 的详细逻辑（`TransactionalMessageServiceImpl#check`）：

```java
public void check(MessageStore ms) {
    // 1. 从 RMQ_SYS_TRANS_OP_HALF_TOPIC 拉取"已完成"的 op 消息，
    //    建立一个 Set<offset> 作为"已完成集合"
    // 2. 从 RMQ_SYS_TRANS_HALF_TOPIC 按消费位点拉取半消息
    // 3. 对于每条半消息：
    //      if (opSet.contains(halfOffset))  → 已处理，跳过
    //      else → 需要回查
    //         如果需要回查：发送 CHECK_TRANSACTION_STATE 请求给 Producer
}
```

**关键：回查是逐条"遍历半消息"然后对比 op 集合。** 所以半消息的消费进度（`transactionCheckMax` 等）也是通过 `RMQ_SYS_TRANS_HALF_TOPIC` 的 ConsumerOffset 来维护的——**Broker 自己是这个 topic 的"消费者"**。

### 3.2 真的"超时"判断在哪

上面看到回查是"每 60 秒扫一遍所有未完成的半消息"。但实际实现里还有一个"过滤"：**只看已经等待足够久的半消息。**

```java
// 关键常量（BrokerConfig）
/**
 * 最大检查次数，默认 15 次
 */
private int transactionCheckMax = 15;

/**
 * 回查间隔，默认 60 秒（单位秒）
 */
private int transactionCheckInterval = 60;

/**
 * 事务消息超时时间，默认 6 秒（在这个时间内不检查，因为可能事务还在执行）
 */
private long transactionTimeOut = 6_000;
```

所以在 `check()` 内部会计算：

```java
// 距离半消息写入的时间
long halfOffsetInMsg = ...;
long valueOfCurrentTime = System.currentTimeMillis();

if (valueOfCurrentTime - halfOffsetInMsg < transactionTimeOut) {
    // 还没超过 transactionTimeOut（默认 6s），认为事务可能还在执行，跳过
    continue;
}
```

**所以完整的触发条件是：半消息写入后超过 `transactionTimeOut`（默认 6s），且没有被 Commit/Rollback，且当前处在 60s 一轮的扫描中。** 换算下来，生产环境里一次未确认事务通常在 **6~66 秒**内被回查。

### 3.3 回查请求怎么发

Broker 通过 Netty 向 Producer 所在的那个 **Producer Group 里的任意一个实例**发请求：

```java
// 请求码
public static final int CHECK_TRANSACTION_STATE = 39;
```

请求体里带上半消息的关键信息：

```java
CheckTransactionStateRequestHeader {
    long commitLogOffset;     // 半消息在 CommitLog 的位置
    int tranStateTableOffset; // op 表里的位置
    String transactionId;     // 事务 ID（UNIQ_KEY）
    MessageExt messageExt;    // 原始消息内容
}
```

**注意"任意一个实例"这个细节**：Broker 是按 **Producer Group** 来找的，不是按发送方实例。这意味着：

> 如果你的 Producer Group 有 3 个实例，Broker 可能把回查请求发给**没执行过这个事务的那 2 个实例**。

所以 `TransactionListener` 的回查实现**不能依赖本地内存状态**，必须去查数据库或者共享存储！这是生产落地最常见的坑，后面会详细讲。

### 3.4 回查次数与最终归宿

```java
private int transactionCheckMax = 15;
```

如果回查了 15 次（15 × 60s ≈ 15 分钟，实际还要加上 ~6s 的初始延迟）仍然没有结果，Broker 会**直接丢弃这条半消息**（并打日志、写 op 记录）：

```java
if (messageExt.getReconsumeTimes() >= transactionCheckMax) {
    log.warn("Check transaction failed, discard the message: {}", ...);
    // 记录到事务状态表，标记为"丢弃"
    // 最终半消息不再回查
}
```

这里有个**极其重要的生产隐患**：**丢弃意味着"这条消息永远不会被投递"**，而且**业务方不会收到任何通知**。如果你的业务逻辑需要"100% 最终一致"，就必须：

1. 监控 Broker 日志里的 `Check transaction failed, discard the message`；
2. 在回查逻辑里保证一定能查到状态（而不是依赖内存）；
3. 或者干脆别用事务消息，回到本地消息表方案。

## 四、Producer 端 API 与代码实战

### 4.1 核心接口：TransactionListener

```java
public interface TransactionListener {
    /**
     * 执行本地事务（阶段二）
     * 返回 LOCAL_TRANSACTION_STATE，决定 COMMIT / ROLLBACK / UNKNOW
     */
    LocalTransactionState executeLocalTransaction(Message msg, Object arg);

    /**
     * 事务回查（Broker 主动调用）
     * 返回 UNKNOW 会让 Broker 继续回查
     */
    LocalTransactionState checkLocalTransaction(MessageExt msg);
}
```

状态枚举：

```java
public enum LocalTransactionState {
    COMMIT_MESSAGE,      // 提交，消息对 Consumer 可见
    ROLLBACK_MESSAGE,    // 回滚，消息被丢弃
    UNKNOW               // 未知，触发 Broker 回查
}
```

### 4.2 完整发送示例

```java
@Service
public class OrderTransactionProducer {

    private final TransactionMQProducer producer;
    private final OrderDao orderDao;

    public OrderTransactionProducer(OrderDao orderDao) throws MQClientException {
        this.orderDao = orderDao;

        producer = new TransactionMQProducer("order_tx_producer_group");
        producer.setNamesrvAddr("10.0.0.1:9876;10.0.0.2:9876");
        producer.setRetryTimesWhenSendAsyncFailed(3);

        // 回查线程池（必须设置，否则回查请求会被拒绝！）
        producer.setExecutorService(new ThreadPoolExecutor(
            2, 5, 60, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(2000),
            new ThreadFactoryImpl("tx-check-thread-")));

        // 设置事务监听器
        producer.setTransactionListener(new OrderTransactionListener(orderDao));

        producer.start();
    }

    public void createOrder(Order order) throws Exception {
        Message message = new Message(
                "order_topic",
                "CREATE_ORDER",
                order.getOrderId().toString(),
                JSON.toJSONBytes(order));

        // 关键：把业务参数通过 arg 传给 listener（不会发送到 Broker）
        TransactionSendResult result = producer.sendMessageInTransaction(
                message, order);

        if (result.getLocalTransactionState() != LocalTransactionState.COMMIT_MESSAGE) {
            throw new IllegalStateException("订单事务失败: " + result);
        }
    }
}
```

### 4.3 关键点：本地事务与消息发送的分工

```java
public class OrderTransactionListener implements TransactionListener {

    private final OrderDao orderDao;

    @Override
    public LocalTransactionState executeLocalTransaction(Message msg, Object arg) {
        Order order = (Order) arg;
        try {
            // ① 执行本地事务（写订单 + 写扣积分任务记录）
            orderDao.createOrder(order);
            orderDao.savePointDeductTask(order.getOrderId(), order.getPoints());
            return LocalTransactionState.COMMIT_MESSAGE;
        } catch (Exception e) {
            log.error("本地事务执行失败, orderId={}", order.getOrderId(), e);
            return LocalTransactionState.ROLLBACK_MESSAGE;
        }
    }

    @Override
    public LocalTransactionState checkLocalTransaction(MessageExt msg) {
        // ★ 绝对不能依赖本地内存！必须查数据库
        String orderId = msg.getKeys();
        try {
            boolean exists = orderDao.existsOrder(Long.valueOf(orderId));
            boolean taskSaved = orderDao.existsPointTask(Long.valueOf(orderId));
            if (exists && taskSaved) {
                return LocalTransactionState.COMMIT_MESSAGE;
            }
            // 注意：订单不存在不代表"回滚"，可能是事务还在执行中
            // 返回 UNKNOW 让 Broker 稍后再查
            return LocalTransactionState.UNKNOW;
        } catch (Exception e) {
            log.error("回查失败, orderId={}", orderId, e);
            return LocalTransactionState.UNKNOW;   // 出错时也必须 UNKNOW，不能猜
        }
    }
}
```

**三个铁律：**

1. **回查逻辑必须查持久化状态**，不能依赖内存/ThreadLocal——因为回查请求可能发给同 Group 的其他实例；
2. **查不到时返回 `UNKNOW`，不要返回 `ROLLBACK`**——不然会把"事务还没提交完"误判成"失败"，消息永久丢失（极难排查）；
3. **`arg` 参数只能本地传递**，不会发给 Broker，也不会在回查时出现（回查拿到的是 `MessageExt`，`arg` 为 null），所以**回查所需的信息必须能从消息体里解析出来**——把 `orderId` 放进 `keys` 或消息体。

### 4.4 消费端幂等

事务消息保证的是"消息最终会被投递且只 Commit 一次（如果本地事务成功）"，但**不保证消费者只收到一次**。因为：

- Broker 端 Commit 后，消息正常投递；
- 如果消费者处理成功但 ACK 丢失，会重投（RocketMQ 至少一次语义）。

所以消费端必须幂等：

```java
@RocketMQMessageListener(
    topic = "order_topic",
    consumerGroup = "point_consumer_group",
    messageModel = MessageModel.CLUSTERING)
public class PointDeductConsumer implements RocketMQListener<MessageExt> {

    @Override
    public void onMessage(MessageExt message) {
        String orderId = message.getKeys();
        // 幂等表 + 唯一索引，靠数据库约束防重
        try {
            pointService.deduct(orderId);
        } catch (DuplicateKeyException e) {
            log.info("重复消费，忽略, orderId={}", orderId);
        }
    }
}
```

## 五、使用限制与生产陷阱

### 5.1 事务消息的硬限制

| 限制 | 说明 |
| --- | --- |
| 不支持延迟消息 | 半消息的延迟级别会被覆盖，RocketMQ 4.x 明确不支持 |
| 不支持批量发送 | 批量消息无法逐条确认事务状态 |
| 不支持顺序消息 | 事务消息在 Commit 前不可见，顺序无法保证 |
| 存储成本翻倍 | 半消息 + 真实消息各占一份 CommitLog |
| 回查有上限 | `transactionCheckMax` 默认 15 次，超限直接丢弃 |

**为什么事务消息不支持延迟消息？** 因为延迟消息在 Broker 端是通过 `SCHEDULE_TOPIC_XXXX` 转换 Topic 实现的，而事务消息也需要转换 Topic（转成 `RMQ_SYS_TRANS_HALF_TOPIC`），两个转换会互相覆盖，导致消息投递错乱。RocketMQ 5.x 的定时消息架构重构后支持了，但 4.x 不支持。

### 5.2 常见生产陷阱

**陷阱一：忘了设置回查线程池**

```java
producer.setExecutorService(executorService);   // 不设置会怎样？
```

`TransactionMQProducer` 默认 `executorService = null`。当 Broker 发回查请求时，Producer 端的 `ClientRemotingProcessor#checkTransactionState` 会尝试用这个线程池处理，null 会导致请求被直接丢弃并打日志。**表现为：事务一直不提交，最后被丢弃。**

**陷阱二：Producer Group 混用**

不同业务的事务消息**必须用不同的 Producer Group**。因为回查是按 Group 找 Producer 的，如果 Group 里有 A、B 两个业务的事务消息，Broker 的回查请求可能发给错误的实例，而该实例的 listener 未必认识这条消息。

**陷阱三：回查返回 ROLLBACK 导致静默丢单**

前面强调过。补充一个真实案例：

> 某团队的回查逻辑是"查订单表，不存在就返回 ROLLBACK"。上线后偶发丢单：**订单写入后数据库主从延迟**（回查走从库），从库还没同步到，回查判为不存在 → 返回 ROLLBACK → 消息被丢弃 → 积分永远不扣。改成 `UNKNOW` 后问题消失。

**陷阱四：Broker 磁盘满 / 主从切换**

- CommitLog 写满（`diskMaxUsedPercentage`）时 Broker 拒绝写入，半消息写不进去，`sendMessageInTransaction` 抛异常，但**本地事务可能已经执行**——这时要靠业务侧的补偿或对账；
- 主从切换时，如果半消息还没同步到新主，回查会查不到，可能导致重复 Commit（需消费端幂等兜底）。

**陷阱五：`executeLocalTransaction` 里做长耗时操作**

本地事务执行时间过长（超过 `transactionTimeOut`）会导致 Broker 在事务还在执行时就发起回查，此时回查必然返回 `UNKNOW`，白白消耗回查次数。

**建议：`executeLocalTransaction` 里的操作控制在 2 秒以内；长流程拆成"写状态 + 异步处理"。**

## 六、与本地消息表、Seata 的对比

| 维度 | RocketMQ 事务消息 | 本地消息表 | Seata AT |
| --- | --- | --- | --- |
| 一致性 | 最终一致 | 最终一致 | 最终一致（有全局锁，可做到接近强一致） |
| 业务侵入 | 低（实现 listener） | 中（建表 + 扫描） | 低（`@GlobalTransactional`） |
| 中间件依赖 | RocketMQ（新版功能） | 无 | Seata Server |
| 数据可靠性 | 依赖 Broker（回查上限 15 次后丢弃） | 依赖本地库（最可靠） | 依赖 undo_log |
| 延迟 | 秒级 | 秒级（扫描间隔） | 百毫秒级 |
| 适用场景 | 已有 RocketMQ 的异步链路 | 无 MQ 或要求最高可靠 | 强一致要求 + 跨服务 RPC |

**选型建议：**

- 已经是 RocketMQ 用户，且业务是"本地事务 + 异步通知"→ **事务消息**，最省事；
- 要求"绝不丢消息"（金融级）→ **本地消息表**，最可靠；
- 需要跨服务强一致回滚 → **Seata**；
- 业务量小、追求简单 → 干脆用"本地消息表 + 定时补偿"，代码几十行就够。

## 七、面试常见追问

**Q1：半消息为什么不会被消费？**

因为 Broker 把它的 Topic 替换成了 `RMQ_SYS_TRANS_HALF_TOPIC`（通过 `TRAN_MSG=true` 触发），这个 Topic 没有任何 Consumer 订阅，所以永远不投递。CommitLog 里确实写了数据，但"可见性"由订阅关系决定。

**Q2：为什么事务回查一定要查数据库？**

因为 Broker 按 **Producer Group** 找实例发回查请求，可能发给 Group 内任何一个实例，而不一定是执行本地事务的那个。依赖内存状态会导致"回查找不到，误判回滚"。

**Q3：回查 15 次后消息怎么办？**

被 Broker 丢弃（写日志 `Check transaction failed, discard the message`），半消息永远不再投递。**这是事务消息最危险的边界**，必须监控告警 + 对账兜底。

**Q4：事务消息能保证消息不重复吗？**

不能。RocketMQ 的投递语义是**至少一次（at least once）**，消费端必须幂等。与事务消息本身无关，所有 MQ 都一样。

**Q5：`arg` 参数在回查时能拿到吗？**

不能。`arg` 只在 Producer 本地内存里传递给 `executeLocalTransaction`，不发送到 Broker，回查时是 null。需要回查的信息必须能从消息体或 `keys` 解析出来。

**Q6：Commit 为什么要把消息重写一遍？不能直接改原位吗？**

CommitLog 是**只追加的顺序日志**（append-only），不能原地修改（这正是它高性能的根源：顺序写 + 零拷贝）。所以 Commit 只能"重新写一条真实 Topic 的消息"，同时写 op 记录标记半消息已完成。

## 八、总结

RocketMQ 事务消息的设计精髓可以浓缩成三句话：

1. **用 Topic 替换实现"写入但不可见"**——半消息落在 `RMQ_SYS_TRANS_HALF_TOPIC`，靠无订阅者实现隔离，复用了 CommitLog 的可靠性；
2. **用回查兜住"第三种状态"**——业务没回应不是失败，Broker 主动回查，把 2PC 的"阻塞等待"变成了"异步补偿"；
3. **用 op 记录实现幂等标记**——CommitLog 不可改，那就用另一份记录来表达"已完成"。

但它不是免费的午餐：**回查上限 15 次后会静默丢消息**，这决定了它只适合"最终一致 + 有对账"的场景，不适合"绝对不能丢"的场景。

落地时的三件必做事项：**回查逻辑查数据库且返回 UNKNOW、独立 Producer Group、配套对账与告警**。做到这三点，事务消息可以帮你省掉本地消息表和定时扫描任务；做不到，它可能会在某个大促的凌晨悄悄吞掉你的订单。
