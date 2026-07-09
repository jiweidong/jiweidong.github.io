---
title: 【消息队列】Kafka 事务与 Exactly-Once 语义深度实战：从原理到源码级解析
date: 2026-07-09 08:00:00
tags:
  - Kafka
  - 消息队列
  - 分布式事务
  - Exactly-Once
categories:
  - 中间件
  - Kafka
author: 东哥
---

# 【消息队列】Kafka 事务与 Exactly-Once 语义深度实战

## 一、消息投递语义：你了解几种？

在分布式消息系统中，消息投递保证通常分为三个等级：

| 语义级别 | 含义 | 可能出现的问题 |
|---------|------|--------------|
| **At Most Once**（至多一次） | 消息可能丢失，但不会重复 | 消费端处理完但提交前宕机，重启后消息丢失 |
| **At Least Once**（至少一次） | 消息不会丢失，但可能重复 | 消费端处理完且提交，但提交后重启，消息重复消费 |
| **Exactly Once**（恰好一次） | 消息既不丢失也不重复 | 需要事务机制保证 |

> **面试官：说说 Kafka 默认提供哪种语义？**
>
> 答：Kafka 默认是 At Least Once 语义。生产者重试可能导致消息重复，消费者在自动提交模式下也可能重复消费。Kafka 通过幂等生产者、事务 API 来实现 Exactly Once 语义。

## 二、Kafka Exactly Once 的三层保证

### 2.1 幂等生产者（Idempotent Producer）

从 Kafka 0.11 开始引入，通过 `enable.idempotence=true` 开启。

**原理：** 每个生产者会被分配一个唯一的 `ProducerId（PID）`，每个分区维护一个 `序列号（Sequence Number）`。Broker 根据 PID+序列号去重。

```properties
# 生产者配置 - 开启幂等
enable.idempotence=true
acks=all        # 必须设置为 all
max.in.flight.requests.per.connection=5  # 开启幂等后，即使 >1 也能保证有序
retries=Integer.MAX_VALUE  # 无限重试
```

```java
// Java 生产者代码
Properties props = new Properties();
props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);  // 开启幂等
props.put(ProducerConfig.ACKS_CONFIG, "all");

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
```

**去重机制示意图：**
```
Producer (PID=1000)
    ├── Partition 0: Seq=1, Seq=2, Seq=3
    ├── Partition 1: Seq=1, Seq=2, Seq=3
    └── Partition 2: Seq=1, Seq=2, Seq=3
    
Broker 收到消息时:
- 检查 (PID=1000, Partition=0, Seq=2) 是否已存在
- 如果 Seq=2 已确认，Seq=2 再次到来 → 丢弃
- 如果 Seq=2 已确认，Seq=4 到来（跳过了 Seq=3）→ 报错，说明有乱序
```

**局限性：** 幂等生产者只能保证单个生产者会话内、单分区的写操作幂等性。重启生产者会重新分配 PID，之前的 PID 状态丢失。

### 2.2 事务性生产者（Transactional Producer）

事务 API 解决了幂等生产者的局限性，实现跨分区、跨会话的原子写入。

```java
// 初始化事务
Properties props = new Properties();
props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "txn-order-service-1");
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);  // 事务必须同时开启幂等

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
producer.initTransactions();  // 初始化事务 ID

try {
    producer.beginTransaction();
    // 发送到多个分区
    producer.send(new ProducerRecord<>("order-topic", orderId, orderData));
    producer.send(new ProducerRecord<>("payment-topic", paymentId, paymentData));
    producer.sendOffsetsToTransaction(offsets, "consumer-group-1");  // 原子提交消费位移
    producer.commitTransaction();  // 事务提交
} catch (Exception e) {
    producer.abortTransaction();  // 事务回滚
    throw e;
}
```

**事务关键配置：**

| 配置项 | 说明 | 默认值 |
|-------|------|-------|
| `transactional.id` | 全局唯一的事务 ID | 空（不启用事务） |
| `transaction.timeout.ms` | 事务超时时间 | 60000（60s） |
| `transaction.state.log.replication.factor` | 事务日志副本数 | 3 |
| `transaction.state.log.min.isr` | 事务日志最小 ISR | 2 |

> **面试追问：`transactional.id` 和 `PID` 有什么关系？**
>
> 答：`transactional.id` 是用户指定的逻辑标识，Kafka 利用它来恢复旧的 PID。当生产者重启时，会使用同样的 `transactional.id`，向协调器请求获取之前的 PID 和 epoch，从而实现跨会话的事务恢复。

### 2.3 事务协调器（Transaction Coordinator）

Kafka 事务的核心组件。

**事务协议流程：**

```
1. 生产者通过 FindCoordinator 请求找到 Transaction Coordinator
2. 生产者发送 InitPidRequest（带 transactional.id）
3. Coordinator 分配 PID 并递增 epoch（用于 fencing 旧的 producer）
4. 生产者发送 AddPartitionsToTxnRequest → Coordinator 记录事务涉及的分区到事务日志
5. 生产者发送 ProduceRequest（带事务标记）→ Broker 将消息写入，标记为未提交
6. 生产者发送 EndTxnRequest（commit 或 abort）
7. Coordinator 写入 PREPARE_COMMIT/PREPARE_ABORT 到事务日志
8. Coordinator 向所有参与分区的 Leader 发送 WriteTxnMarkersRequest
9. Leader 写入控制消息（COMMIT/ABORT marker）到日志
10. Coordinator 写入 COMPLETED_COMMIT/COMPLETED_ABORT 到事务日志
```

**关键概念：控制消息（Control Message）**

控制消息是一种特殊的消息记录（Record），有 `CONTROL` 类型。消费端通过这个判断事务是否提交：

```java
// 消费者读取时的事务隔离
Properties props = new Properties();
props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");  
// "read_uncommitted"（默认）能看到所有消息，包括未提交的事务消息
// "read_committed" 只看到已提交的事务消息 + 非事务消息
```

## 三、Kafka 事务实战：跨系统原子写入

### 3.1 经典场景：消息队列中的事务消息

```java
public class OrderService {
    
    private final KafkaProducer<String, Order> producer;
    private final JdbcTemplate jdbcTemplate;
    
    public void createOrder(Order order) {
        producer.beginTransaction();
        try {
            // 1. 更新数据库订单状态
            jdbcTemplate.update(
                "INSERT INTO orders (id, status) VALUES (?, ?)",
                order.getId(), "PENDING"
            );
            
            // 2. 发送订单消息到 Kafka
            producer.send(new ProducerRecord<>("order-events", 
                order.getId(), order));
            
            // 3. 数据库操作 + 消息发送原子提交
            producer.commitTransaction();
            jdbcTemplate.getDataSource().getConnection().commit();
        } catch (Exception e) {
            producer.abortTransaction();
            jdbcTemplate.getDataSource().getConnection().rollback();
            throw new RuntimeException("订单创建失败", e);
        }
    }
}
```

### 3.2 事务性消费：Consumer-Transform-Producer 模式

```java
public class TransactionalCopyProcessor {
    
    private final KafkaConsumer<String, String> consumer;
    private final KafkaProducer<String, String> producer;
    
    public void process() {
        // 订阅源 Topic
        consumer.subscribe(Arrays.asList("source-topic"));
        
        while (true) {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
            if (!records.isEmpty()) {
                producer.beginTransaction();
                try {
                    Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
                    for (ConsumerRecord<String, String> record : records) {
                        // 处理并发送到目标 Topic
                        String transformed = transform(record.value());
                        producer.send(new ProducerRecord<>("target-topic", 
                            record.key(), transformed));
                        offsets.put(
                            new TopicPartition(record.topic(), record.partition()),
                            new OffsetAndMetadata(record.offset() + 1)
                        );
                    }
                    // 在事务中原子提交消费位移
                    producer.sendOffsetsToTransaction(offsets, consumer.groupMetadata());
                    producer.commitTransaction();
                } catch (Exception e) {
                    producer.abortTransaction();
                    // 不提交位移，下次 poll 会重新消费
                }
            }
        }
    }
}
```

### 3.3 事务过期与超时处理

```java
// 设置合适的事务超时
props.put(ProducerConfig.TRANSACTION_TIMEOUT_CONFIG, 60000);  // 60s

// 处理事务超时的 fencing 机制
while (true) {
    try {
        producer.beginTransaction();
        // ... 业务逻辑
        producer.commitTransaction();
        break;
    } catch (ProducerFencedException e) {
        // 旧的事务被隔离，需要关闭并重建生产者
        producer.close();
        producer = createNewProducer();
        producer.initTransactions();
    } catch (KafkaException e) {
        // 其他错误，回滚后重试
        producer.abortTransaction();
    }
}
```

## 四、源码级原理：事务状态机

Kafka 事务状态机定义了事务的生命周期：

```
                    +----> ABORTABLE_ERROR <----+
                    |         |                 |
                    |         v                 |
EMPTY --> ONGOING --> PREPARE_ABORT --> COMPLETE_ABORT
  |                    |                           
  |                    v                           
  +---> PREPARE_COMMIT --> COMPLETE_COMMIT
```

**状态转换的关键时机：**
- `EMPTY`：事务刚刚初始化
- `ONGOING`：有分区加入事务（`AddPartitionsToTxnRequest`）
- `PREPARE_COMMIT`：`EndTxnRequest(commit=true)` 到达 Coordinator
- `PREPARE_ABORT`：`EndTxnRequest(commit=false)` 或发生错误
- `COMPLETE_COMMIT`：所有参与分区的 marker 写入完成
- `COMPLETE_ABORT`：所有参与分区的 marker 写入完成

## 五、性能与最佳实践

### 5.1 性能对比

| 模式 | 延迟 | 吞吐量 | 适用场景 |
|-----|------|-------|---------|
| 普通生产（acks=1） | 低 | 高 | 日志收集、监控数据 |
| 幂等生产（acks=all） | 中 | 中 | 普通业务消息 |
| 事务生产 | 较高 | 中低 | 金融交易、跨系统数据一致性 |

### 5.2 最佳实践

**1. 选择合适的 isolation.level**

```java
// 默认是 read_uncommitted，性能更好
props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_uncommitted");
// read_committed 保证只读取已提交的事务消息
props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
```

**2. 事务 ID 命名规范：** `{业务模块}-{实例ID}`，保证全局唯一

**3. 事务超时不能太长：** 建议 30-60s，太大会阻塞事务日志的清理

**4. 合理控制事务范围：** 一个事务不要包含太多消息（建议 <1000 条）

**5. 监控事务指标：**
```
# JMX 指标
kafka.coordinator.transaction:type=TransactionCoordinatorMetrics
  - TransactionCount: 事务总数
  - AbortedTransactionCount: 已回滚事务数
  - TransactionTimeoutCount: 超时事务数
```

## 六、常见问题与排查

| 异常 | 原因 | 解决方案 |
|------|------|---------|
| `ProducerFencedException` | epoch 过期，有新的生产者实例 | 关闭旧生产者，重建 |
| `InvalidTxnStateException` | 事务状态异常（如重复 commit） | 检查事务调用生命周期 |
| `TimeoutException` | 事务超时 | 增大 `transaction.timeout.ms` |
| `NotCoordinatorException` | Coordinator 变更 | 生产者自动重试 |

## 七、总结

Kafka 的 Exactly Once 语义通过三层架构实现：

1. **幂等生产者** → 单分区、单会话的去重保证
2. **事务 API** → 跨分区、跨会话的原子性保证
3. **事务协调器 + 事务日志** → 分布式事务状态管理

在实际项目中，**不一定要追求 Exactly Once**。对于大多数业务场景，At Least Once + 业务幂等（如去重表、状态机）已经足够。事务会带来额外的性能开销和复杂度，只在真正需要时使用。
