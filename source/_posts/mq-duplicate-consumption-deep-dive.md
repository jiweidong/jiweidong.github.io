---
title: 【消息队列】消息重复消费深度解析：从 at-least-once 原理到幂等消费的六种治理方案
date: 2026-09-02 08:00:00
tags:
  - 消息队列
  - Kafka
  - RabbitMQ
  - 高并发
categories:
  - Java
  - 中间件
author: 东哥
---

# 【消息队列】消息重复消费深度解析：从 at-least-once 原理到幂等消费的六种治理方案

## 面试官：Kafka 或者 RabbitMQ 会丢消息吗？会重复消费吗？怎么解决重复消费？

这是消息队列面试的"送命题"之一。很多人只会背一句"消费端做幂等"，但被追问"为什么一定会重复""幂等方案怎么选""Exactly-Once 真的存在吗"就露馅了。今天把重复消费这件事彻底讲清楚。

---

## 一、为什么消息一定会被重复消费？（底层原理）

### 1.1 消息队列的三种投递语义

| 语义 | 含义 | 实现代价 |
| --- | --- | --- |
| At-Most-Once（最多一次） | 消息可能丢，但绝不重复 | 低 |
| At-Least-Once（至少一次） | 消息不丢，但**可能重复** | 中 |
| Exactly-Once（恰好一次） | 不丢也不重复 | 极高（通常需分布式事务/幂等配合） |

**主流 MQ（Kafka、RabbitMQ、RocketMQ）默认都是 At-Least-Once**，因为"不丢消息"是业务底线，而"去重"的兜底责任交给了消费端。

### 1.2 重复消费的四大典型场景

**场景一：消费超时导致 Broker 重投**

```java
// Kafka 中，如果处理时间超过 max.poll.interval.ms（默认 5 分钟）
// 消费者会被判定"死亡"，触发 Rebalance，分区重新分配
// 而 offset 还没提交，新消费者会从上次提交的位置重新拉取
```

**场景二：手动 ACK 失败重投（RabbitMQ）**

```java
// RabbitMQ 手动 ack，业务处理完但 ack 前进程挂了
// 消息回到队列头部，下个消费者再次收到
channel.basicConsume(queue, false, (consumerTag, delivery) -> {
    process(delivery);      // 业务处理成功
    // 这里挂了，没执行 basicAck
    // channel.basicAck(delivery.getEnvelope().getDeliveryTag(), false);
});
```

**场景三：消费者处理成功但提交位移失败（Kafka）**

```java
// 业务处理完成，但 commitSync 时网络抖动/超时
// 下次 poll 会重新拉到这条消息
consumer.commitSync();  // 抛异常没提交成功
```

**场景四：网络重试导致发送方重复投递**

生产者发送后没收到确认就重试，Broker 可能已经落盘了，于是同一条消息被写入两次（Producer 幂等开启后此场景可避免）。

### 1.3 小结：重复消费是"特性"不是"bug"

只要满足"先处理后确认"（At-Least-Once 的标准模型），在**处理成功到确认成功之间**的任何故障都会造成重复。所以——**消费端必须幂等**。

---

## 二、幂等消费的六种治理方案（核心干货）

### 方案一：数据库唯一索引（最可靠）

利用数据库的唯一约束做天然去重，重复插入直接报错被吞掉。

```sql
-- 消费记录表，message_id 建唯一索引
CREATE TABLE mq_consume_record (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  message_id VARCHAR(64) NOT NULL,
  biz_key VARCHAR(64) NOT NULL,
  status TINYINT NOT NULL,
  create_time DATETIME NOT NULL,
  UNIQUE KEY uk_message_id (message_id)
);
```

```java
public void onMessage(OrderMessage msg) {
    try {
        consumeRecordMapper.insert(msg.getMessageId(), "PROCESSING");
    } catch (DuplicateKeyException e) {
        log.info("重复消息，直接忽略: {}", msg.getMessageId());
        return;
    }
    // 处理业务：更新订单状态、扣库存...
    consumeRecordMapper.updateStatus(msg.getMessageId(), "DONE");
}
```

> 注意：先插记录再处理，能挡住绝大多数重复；但进程在"插入后、处理前"崩溃，重投时看到 PROCESSING 状态，需要配合状态机/超时重试机制兜底。

### 方案二：Redis SETNX / 分布式锁去重

适合对 DB 压力敏感的场景，用 Redis 的原子性做"一次性标记"：

```java
public boolean tryAcquire(String messageId) {
    // setIfAbsent + 过期时间，天然原子
    Boolean ok = redis.opsForValue()
        .setIfAbsent("mq:dedup:" + messageId, "1", Duration.ofHours(24));
    return Boolean.TRUE.equals(ok);
}

public void onMessage(OrderMessage msg) {
    if (!tryAcquire(msg.getMessageId())) {
        log.info("重复消息: {}", msg.getMessageId());
        return;
    }
    // 业务处理...
}
```

> 缺点：Redis 本身是 AP 的，极端情况下（主从切换、锁过期）仍有小概率重复；且 Redis 故障时去重失效。适合"容忍极小概率重复"的业务。

### 方案三：业务状态机校验（最推荐）

不依赖额外存储，直接用**业务自身的状态流转**判断：

```java
// 订单状态：CREATED -> PAID -> SHIPPED -> DONE
public void handlePaidMessage(Order order) {
    // 先查订单当前状态
    Order cur = orderMapper.selectById(order.getId());
    if (cur.getStatus() == OrderStatus.PAID.getCode()) {
        log.info("订单已支付，重复消息忽略: {}", order.getId());
        return;
    }
    // 用 UPDATE ... WHERE status='CREATED' 做乐观锁，防止并发
    int rows = orderMapper.paidIfCreated(order.getId(), OrderStatus.CREATED.getCode());
    if (rows == 0) {
        log.info("状态已变更，重复/并发消息忽略: {}", order.getId());
        return;
    }
    // 继续后续流程...
}
```

核心思想：**状态只能单向流转，重复的消息无法让状态"再流转一次"**。这是电商支付、订单场景的标配方案。

### 方案四：去重表 + 本地事务

把"写业务数据"和"写消费记录"放进**同一个本地事务**，彻底原子：

```java
@Transactional
public void handleMessage(OrderMessage msg) {
    // 1. 插入消费记录（唯一索引兜底）
    consumeRecordMapper.insert(msg.getMessageId());
    // 2. 更新业务数据
    orderMapper.update(...);
    // 3. 事务提交后，offset/ack 才推进
}
```

事务保证：要么业务数据和消费记录一起成功，要么一起回滚。**这是单库场景下最严谨的方案**，代价是每条消息多一次 DB 写入。

### 方案五：消息内携带业务唯一键（Token 机制）

发送方在消息里放一个全局唯一的业务键（如订单号、流水号），消费端用该键做幂等判断，而不是依赖 messageId：

```json
{
  "bizId": "ORDER_20260902_10001",
  "type": "ORDER_PAID",
  "payload": { "...": "..." }
}
```

```java
public void onMessage(Msg msg) {
    String dedupKey = msg.getType() + ":" + msg.getBizId();
    if (dedupRedis.acquire(dedupKey)) {
        process(msg);
    }
}
```

好处：同一笔业务的多条消息（如重试补偿消息）共享同一个幂等键；跨 MQ 迁移时幂等逻辑不用改。

### 方案六：乐观锁版本号

业务表带 version 字段，更新时带上版本号：

```sql
UPDATE t_order
SET status = 'PAID', version = version + 1
WHERE id = #{id} AND version = #{version};
```

更新影响行数为 0 说明已被处理过，直接忽略。适合更新型业务，与方案三思路一致但更通用。

---

## 三、六种方案对比与选型

| 方案 | 可靠性 | 侵入性 | 额外依赖 | 适用场景 |
| --- | --- | --- | --- | --- |
| 数据库唯一索引 | ★★★★★ | 中 | MySQL | 通用兜底，最稳 |
| Redis SETNX | ★★★☆ | 低 | Redis | 高频去重、可容忍极小概率重复 |
| 业务状态机 | ★★★★★ | 低 | 无 | 订单/支付等强状态业务 |
| 去重表+本地事务 | ★★★★★ | 中 | MySQL | 单库强一致场景 |
| 消息业务键 | ★★★★ | 低 | 取决于实现 | 多 MQ 迁移、补偿消息场景 |
| 乐观锁版本号 | ★★★★ | 中 | 无 | 更新型业务 |

**实战建议：状态机/乐观锁为主 + 唯一索引兜底**，这是生产环境最稳的组合。

---

## 四、Kafka 幂等生产者与 Exactly-Once 的真相

### 4.1 Producer 幂等（防"发送重复"）

Kafka 生产者开启 `enable.idempotence=true` 后，通过 PID + Sequence Number 让 Broker 识别重复的 Produce 请求，**解决的是"生产者重试导致的消息重复写入"**。

```properties
enable.idempotence=true
acks=all
```

### 4.2 事务 API 与 Exactly-Once

Kafka 的 `read_committed` 隔离级别 + 事务（`initTransactions` → `beginTransaction` → `sendOffsetsToTransaction`）可以实现**流处理场景下（Kafka → Kafka）**的精确一次语义：

```java
producer.initTransactions();
producer.beginTransaction();
producer.send(record);
// 把消费位移也提交进事务
producer.sendOffsetsToTransaction(offsets, consumerGroupId);
producer.commitTransaction();
```

### 4.3 残酷的真相：端到端 Exactly-Once 不存在

Kafka 的事务只覆盖 **Kafka 内部（读 Kafka → 写 Kafka）**。一旦消息进入**外部系统**（MySQL、Redis、调用第三方 API），Broker 无法感知外部操作结果，端到端必然退回 At-Least-Once + **消费端幂等**。

> 面试加分句："Exactly-Once 本质是 At-Least-Once + 幂等消费的组合，任何宣称端到端精确一次的方案，底层都藏着幂等或分布式事务。"

---

## 五、面试高频追问

**Q1：重复消费和消息乱序有什么关系？**
重复消费往往伴随乱序：重投的消息可能插到别的消息后面。所以幂等设计要基于"最终状态"而非"严格顺序"，订单场景用状态机天然免疫乱序。

**Q2：RabbitMQ 怎么保证不重复？**
RabbitMQ 没有消息去重能力，只能消费端幂等。配合手动 ACK + 唯一索引是标准做法。

**Q3：去重记录表会无限增长吗？**
会。定期清理（如只保留 7 天）或按 message_id 哈希分表。清理时注意：清得太早可能导致"迟到很久的重复消息"漏网，一般保留时间要大于消息最大重试周期。

**Q4：Redis 去重键过期时间怎么设？**
必须大于"消息最大可能的重投时间窗口"（通常是重试次数 × 重试间隔 + 余量），否则过期后重复消息会漏进来。

**Q5：消费端幂等能 100% 保证不重复吗？**
不能。任何方案都有极端场景（如唯一索引 + 主从切换丢数据、Redis 故障）。目标是把重复概率降到业务可接受范围，并配合监控（消费端重复率指标）及时发现异常。

---

## 总结

- **重复消费的根源**：At-Least-Once 语义下，"处理成功 → 确认成功"之间存在故障窗口
- **四大场景**：消费超时重投、ACK 失败、位移提交失败、发送方重试
- **治理核心**：消费端幂等——唯一索引、Redis SETNX、状态机、去重表+事务、业务键、乐观锁
- **选型口诀**：有状态的业务用状态机，通用场景用唯一索引兜底，高频场景加 Redis 去重
- **认清本质**：端到端 Exactly-Once 是伪命题，务实方案是"至少一次 + 幂等"
