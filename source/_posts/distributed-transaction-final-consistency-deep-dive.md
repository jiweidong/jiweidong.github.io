---
title: 分布式事务最终一致性实战：本地消息表、事务消息与最大努力通知深度对比
date: 2026-08-16 08:00:00
tags:
  - Java
  - 分布式事务
  - 微服务
  - 消息队列
  - 面试
categories:
  - Java
  - 微服务架构
author: 东哥
---

# 分布式事务最终一致性实战：本地消息表、事务消息与最大努力通知深度对比

## 面试官：跨服务调用怎么保证数据一致性？

微服务架构下，一个业务往往横跨多个服务、多个数据库。比如"下单"要同时完成：订单库扣减库存、账户库扣减余额、积分库增加积分——任何一个失败，数据就乱了。

强一致方案（2PC/XA）在互联网场景基本被抛弃（性能差、协调者单点、阻塞）。真正落地的是**最终一致性**：允许中间状态不一致，但通过消息、对账等手段保证**最终**一致。

本文深挖三个最核心的最终一致性方案：**本地消息表、事务消息、最大努力通知**，讲清原理、代码和选型。

## 一、先看问题本质

```java
// 伪代码：下单同时扣库存
@Transactional
public void createOrder(Order order) {
    orderMapper.insert(order);                    // ① 本地订单
    inventoryService.deduct(order.getSkuId());    // ② 远程扣库存
    // ② 失败了怎么办？① 已经提交了！
}
```

核心矛盾：**本地事务和远程调用无法放进同一个事务**。RPC 调用失败、超时、网络抖动，都会造成两边数据不一致。

解决思路就两条线：

1. **把远程调用变成"发消息"**：本地事务里只写库 + 发消息，消息一定可靠送达（本地消息表 / 事务消息）
2. **让下游"尽力执行 + 补偿"**：下游失败就重试，重试不行就人工/对账兜底（最大努力通知）

## 二、方案一：本地消息表（最朴素可靠）

### 2.1 核心思想

把"发消息"和"业务操作"放进**同一个本地事务**：业务数据写业务表，消息写消息表。然后由一个**定时任务**扫描消息表，把未发送的消息投递到 MQ。

### 2.2 完整流程

```
① 本地事务：订单表 INSERT + 消息表 INSERT(status=待发送)
② 定时任务：扫描消息表 status=待发送 的记录
③ 投递 MQ，投递成功 → 更新消息表 status=已发送
④ 消费方收到消息处理，处理成功 → 回调/ACK
⑤ 消息表记录 status=已完成；失败则重试
```

### 2.3 消息表设计

```sql
CREATE TABLE `t_msg` (
  `id`          BIGINT PRIMARY KEY AUTO_INCREMENT,
  `biz_type`    VARCHAR(32)  NOT NULL COMMENT '业务类型：order/create',
  `biz_id`      VARCHAR(64)  NOT NULL COMMENT '业务ID：订单号',
  `payload`     TEXT         NOT NULL COMMENT '消息内容(JSON)',
  `status`      TINYINT      NOT NULL DEFAULT 0 COMMENT '0待发送 1已发送 2已完成',
  `retry_count` INT          NOT NULL DEFAULT 0 COMMENT '重试次数',
  `next_retry`  DATETIME     NOT NULL COMMENT '下次重试时间',
  `create_time` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY `idx_status_retry` (`status`, `next_retry`)
) COMMENT '本地消息表';
```

### 2.4 代码实现

```java
@Transactional
public void createOrder(Order order) {
    // ① 业务操作
    orderMapper.insert(order);
    // ② 同事务写消息表
    MsgRecord msg = MsgRecord.of("order/create", order.getId(),
            JSON.toJSONString(order), 0);
    msgMapper.insert(msg);
    // 事务提交：两条记录要么都成功，要么都失败 ✅
}

// ③ 定时任务投递
@Scheduled(fixedDelay = 5000)
public void scanAndSend() {
    List<MsgRecord> pending = msgMapper.selectPending(100);
    for (MsgRecord msg : pending) {
        try {
            // 用 biz_id 做幂等键，防止重复投递
            mqProducer.send("ORDER_TOPIC", msg.getBizId(), msg.getPayload());
            msgMapper.markSent(msg.getId());
        } catch (Exception e) {
            // 投递失败，retry_count+1，指数退避，超过阈值告警人工介入
            msgMapper.markRetry(msg.getId());
        }
    }
}
```

### 2.5 关键点

- **先发消息再提交事务的问题**：消息发出去了，事务回滚了 → 消息是脏数据。所以必须是"先提交事务，再由定时任务发消息"
- **幂等投递**：投递成功但 markSent 失败，会重复投递，消费方必须幂等
- **对账兜底**：重试 N 次仍失败，告警人工处理，或定期对账脚本

| 优点 | 缺点 |
|------|------|
| 原理简单，不依赖 MQ 特殊能力 | 消息表耦合业务库，入侵业务 |
| 可靠性高，消息落库不丢 | 定时任务有秒级延迟 |
| 通用，任何 MQ 都能用 | 消息表会膨胀，需要定期清理 |

## 三、方案二：事务消息（RocketMQ 半消息）

### 3.1 核心思想

把"本地事务 + 发消息"的原子性，交给 MQ 自己解决。RocketMQ 支持**半消息（Half Message）**：生产者发送后，消息先处于"半消息"状态，**消费者看不到**；等本地事务执行完，生产者**提交/回滚**这条消息，消息才可见或丢弃。

### 3.2 完整流程

```
① 生产者发送半消息 → Broker 存储，暂不可见
② 生产者执行本地事务（订单入库）
③ 本地事务成功 → commit 半消息 → 消费者可见
④ 本地事务失败 → rollback 半消息 → 消息删除
⑤ 半消息超时未确认 → Broker 主动"回查"生产者
⑥ 生产者查本地事务结果，再次 commit/rollback
```

**回查机制**是事务消息的精华：即使生产者执行本地事务后宕机了，Broker 也会通过回查拿到最终结果，保证**不丢消息、不多发消息**。

### 3.3 代码实现

```java
@Component
public class OrderTransactionListener implements TransactionListener {

    @Autowired
    private OrderMapper orderMapper;

    // ② 执行本地事务（与发送半消息不在同一事务，注意幂等设计）
    @Override
    public LocalTransactionState executeLocalTransaction(Message msg, Object arg) {
        try {
            Order order = (Order) arg;
            orderMapper.insert(order); // 本地事务
            return LocalTransactionState.COMMIT_MESSAGE;
        } catch (Exception e) {
            return LocalTransactionState.ROLLBACK_MESSAGE;
        }
    }

    // ⑤ Broker 回查：根据消息里的订单号查库
    @Override
    public LocalTransactionState checkLocalTransaction(MessageExt msg) {
        String orderId = msg.getKeys();
        return orderMapper.selectById(orderId) != null
                ? LocalTransactionState.COMMIT_MESSAGE
                : LocalTransactionState.ROLLBACK_MESSAGE;
    }
}
```

```java
@Autowired
private RocketMQTemplate rocketMQTemplate;

public void createOrder(Order order) {
    Message msg = MessageBuilder.withPayload(order)
            .setHeader(RocketMQHeaders.KEYS, String.valueOf(order.getId())) // 回查键
            .build();
    // ① 发送半消息，arg 传给 executeLocalTransaction
    rocketMQTemplate.sendMessageInTransaction(
            "ORDER_TOPIC", msg, order);
}
```

### 3.4 事务消息 vs 本地消息表

| 维度 | 本地消息表 | 事务消息 |
|------|-----------|---------|
| 原子性保证 | 本地数据库事务 | MQ 半消息 + 回查 |
| 业务入侵 | 要建消息表，侵入业务库 | 无侵入 |
| 依赖 | 任意 MQ + 定时任务 | RocketMQ（或支持事务消息的 MQ） |
| 延迟 | 秒级（定时扫描） | 毫秒级（直接投递） |
| 实现复杂度 | 低 | 中（要处理回查幂等） |
| 消息量 | 消息表膨胀，不适合大流量 | 适合大流量 |

**结论**：技术栈里有 RocketMQ，直接选事务消息；只有 RabbitMQ/Kafka，就用本地消息表。

## 四、方案三：最大努力通知（对结果不敏感场景）

### 4.1 适用场景

**结果不要求实时、甚至不要求一定成功**，只要"尽力通知"，失败就重试，重试不行就人工。典型：支付结果回调、短信通知、App 推送。

### 4.2 两种实现

**实现 A：MQ 重试**（简单版）

```
业务方发消息 → MQ → 通知服务消费 → 调用第三方接口
失败 → 按延迟级别重试（RocketMQ 默认重试 16 次）
最终失败 → 进死信队列 → 告警人工处理
```

**实现 B：定时任务 + 状态机**（可靠版）

```sql
CREATE TABLE `t_notify` (
  `id`          BIGINT PRIMARY KEY AUTO_INCREMENT,
  `biz_type`    VARCHAR(32) NOT NULL,
  `biz_id`      VARCHAR(64) NOT NULL,
  `url`         VARCHAR(255) NOT NULL COMMENT '回调地址',
  `payload`     TEXT        NOT NULL,
  `status`      TINYINT     NOT NULL DEFAULT 0 COMMENT '0待通知 1成功 2最终失败',
  `retry_count` INT         NOT NULL DEFAULT 0,
  `next_retry`  DATETIME    NOT NULL,
  UNIQUE KEY `uk_biz` (`biz_type`, `biz_id`)
) COMMENT '通知表';
```

```java
@Scheduled(fixedDelay = 3000)
public void notifyScan() {
    List<NotifyRecord> list = notifyMapper.selectPending(50);
    for (NotifyRecord record : list) {
        boolean ok = httpClient.post(record.getUrl(), record.getPayload());
        if (ok) {
            notifyMapper.markSuccess(record.getId());
        } else if (record.getRetryCount() >= MAX_RETRY) {
            notifyMapper.markFinalFailed(record.getId()); // 转人工
        } else {
            notifyMapper.markRetry(record.getId());       // 退避重试
        }
    }
}
```

### 4.3 与前面两个方案的本质区别

| 方案 | 通知方要求 | 失败策略 |
|------|-----------|---------|
| 本地消息表/事务消息 | 下游**必须**处理成功 | 重试直到成功，强保证 |
| 最大努力通知 | 下游**尽量**处理 | 重试有限次，最终失败转人工，弱保证 |

## 五、最终一致性必须配套的四个设计

不管用哪个方案，下面四点缺一不可：

### 5.1 消费幂等

消息可能重复投递，消费端必须幂等：

```java
// 方案A：数据库唯一键
INSERT INTO t_order_extra (order_id, ...) VALUES (?, ...)
ON DUPLICATE KEY UPDATE ...; -- 重复插入被唯一键挡住

// 方案B：Redis 去重
Boolean first = redis.opsForValue().setIfAbsent("consume:" + msgId, "1", 10, TimeUnit.MINUTES);
if (Boolean.TRUE.equals(first)) {
    handle(msg); // 只有第一次能拿到锁
}
```

### 5.2 状态机 + 对账

最终一致性必须有**对账兜底**：每天跑对账任务，找出"订单已创建但库存没扣/积分没加"的脏数据，自动补偿。

```sql
-- 对账：查订单但关联消息表状态不是已完成
SELECT o.id FROM t_order o
LEFT JOIN t_msg m ON m.biz_id = o.id AND m.biz_type = 'order/create'
WHERE o.create_time > #{yesterday} AND m.id IS NULL;
```

### 5.3 消息表清理

本地消息表只保留最近 N 天数据，历史数据归档，防止膨胀。

### 5.4 监控告警

监控：待发送消息积压量、重试超过 5 次的消息、死信队列深度。超过阈值立刻告警。

## 六、面试高频追问

**Q1：本地消息表为什么消息不会丢？**
消息和业务数据在同一个本地事务里写入，要么都成功要么都失败。之后靠定时任务保证投递，投递失败会重试，所以消息一定不会丢（除非数据库本身故障）。

**Q2：事务消息的回查会不会造成重复消费？**
回查只是确认"本地事务是否成功"，决定 commit 还是 rollback。消息一旦 commit，只会被消费一次语义下投递，但网络等异常仍可能造成重复投递，所以消费端幂等是底线。

**Q3：什么时候用 TCC 而不是最终一致性？**
对**实时性要求极高**（如账户扣款必须立即看到）、不允许中间不一致状态的场景用 TCC 等强一致方案；对实时性容忍、链路长的场景（下单→扣库存→发积分）用最终一致性，性能更好、更简单。

**Q4：事务消息和本地消息表能互相替代吗？**
能，语义等价。区别在于事务消息把"表 + 定时任务"下沉到了 MQ 内部，减少了业务代码和维护成本；本地消息表更通用，不挑 MQ。另外事务消息延迟更低。

**Q5：消息最终失败怎么办？**
重试超过阈值后：进死信队列 → 告警 → 人工处理 or 对账脚本自动补偿。任何分布式事务方案都必须有人工/对账兜底，这是生产铁律。

## 总结

一张图记住三个方案：

- **本地消息表**：本地事务写消息表 + 定时任务投递 → 通用、可靠、有延迟
- **事务消息**：MQ 半消息 + 回查 → 无侵入、低延迟、需 RocketMQ
- **最大努力通知**：有限重试 + 人工兜底 → 适合弱保证场景

面试回答框架：先讲问题本质（本地事务与远程调用的矛盾）→ 三个方案原理 → 对比选型 → 幂等/对账/监控兜底 → 加分收尾。
