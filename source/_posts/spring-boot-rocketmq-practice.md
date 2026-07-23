---
title: 【Spring Boot 实战】Spring Boot 集成 RocketMQ 实战：消息发送、消费与事务消息全流程
date: 2026-07-23 08:00:00
tags:
  - Spring Boot
  - RocketMQ
  - 消息队列
  - 事务消息
categories:
  - Java
  - Spring Boot
  - 中间件
author: 东哥
---

# 【Spring Boot 实战】Spring Boot 集成 RocketMQ 实战：消息发送、消费与事务消息全流程

## 一、RocketMQ 与 Spring Boot 集成概述

RocketMQ 是阿里巴巴开源的分布式消息中间件，在阿里内部经历了多年双 11 的洗礼，具备高吞吐、低延迟、强一致性的特点。相比 Kafka，RocketMQ 在**事务消息、延迟消息、消息重试、死信队列**等企业级特性上更加完善。

Spring Boot 集成 RocketMQ 主要有两种方式：

| 集成方式 | 说明 | 适用场景 |
|:---|:---|:---|
| RocketMQ-Spring-Boot-Starter | 官方 Starter，声明式注解 | 大多数 Spring Boot 项目 |
| RocketMQ原生 Client | 直接使用 producer/consumer API | 需要精细控制或特殊配置 |

本文默认使用**官方 Starter** 方式。

## 二、环境搭建与依赖配置

### 2.1 Maven 依赖

```xml
<dependency>
    <groupId>org.apache.rocketmq</groupId>
    <artifactId>rocketmq-spring-boot-starter</artifactId>
    <version>2.3.0</version>
</dependency>
```

### 2.2 配置文件

```yaml
rocketmq:
  name-server: 192.168.1.100:9876;192.168.1.101:9876
  producer:
    group: order-producer-group
    send-message-timeout: 3000
    compress-message-body-threshold: 4096
    max-message-size: 4194304  # 4MB
    retry-times-when-send-failed: 3
  consumer:
    listen-concurrency: 20
```

## 三、消息生产者实战

### 3.1 基本消息发送

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderMessageProducer {

    private final RocketMQTemplate rocketMQTemplate;

    /**
     * 同步发送（可靠性最高，推荐）
     */
    public SendResult sendSync(OrderEvent event) {
        // 使用有序的 HashKey 保证同一订单的消息顺序
        SendResult result = rocketMQTemplate.syncSend(
                "order-topic:create",   // topic:tag
                MessageBuilder.withPayload(event)
                        .setHeader("orderId", event.getOrderId())
                        .build(),
                3000     // timeout ms
        );
        log.info("同步发送结果: status={}, msgId={}",
                result.getSendStatus(), result.getMsgId());
        return result;
    }

    /**
     * 异步发送（吞吐量优先）
     */
    public void sendAsync(OrderEvent event) {
        rocketMQTemplate.asyncSend(
                "order-topic:create",
                event,
                new SendCallback() {
                    @Override
                    public void onSuccess(SendResult result) {
                        log.info("异步发送成功: msgId={}", result.getMsgId());
                    }

                    @Override
                    public void onException(Throwable e) {
                        log.error("异步发送失败: orderId={}", event.getOrderId(), e);
                        // 落库重试或补偿
                        compensationService.addFailedMessage(event);
                    }
                }
        );
    }

    /**
     * 单向发送（不关心结果，日志场景）
     */
    public void sendOneWay(OrderEvent event) {
        rocketMQTemplate.sendOneWay("order-topic:log", event);
    }
}
```

### 3.2 顺序消息发送

顺序消息要求同一业务 ID 的消息发送到同一个 MessageQueue。

```java
@Service
@Slf4j
public class OrderSequentialProducer {

    private final RocketMQTemplate rocketMQTemplate;

    /**
     * 发送顺序消息，使用 orderId 作为选择 key
     */
    public void sendInOrder(List<OrderEvent> events) {
        for (OrderEvent event : events) {
            // 按 orderId 取模选择 queue，保证同一订单的消息进入同一 queue
            rocketMQTemplate.syncSendOrderly(
                    "order-seq-topic",
                    event,
                    event.getOrderId(),   // hash key
                    3000
            );
        }
    }
}
```

### 3.3 延迟消息

```java
/**
 * RocketMQ 内置延迟级别（不可自定义时间）：
 * 1s, 5s, 10s, 30s, 1m, 2m, 3m, 4m, 5m, 6m, 7m, 8m, 9m, 10m,
 * 20m, 30m, 1h, 2h
 * 对应 level: 1-18
 */
public void sendDelayedMessage(OrderEvent event) {
    Message<OrderEvent> message = MessageBuilder.withPayload(event).build();
    // 设置延迟级别为 3 → 10s
    rocketMQTemplate.syncSend(
            "order-topic:delay",
            message,
            3000,
            3  // delay level
    );
}
```

## 四、消息消费者实战

### 4.1 基本消费监听

```java
@Component
@Slf4j
@RocketMQMessageListener(
        consumerGroup = "order-create-consumer",
        topic = "order-topic",
        selectorExpression = "create",   // Tag 过滤
        consumeMode = ConsumeMode.CONCURRENTLY,   // 并发消费
        messageModel = MessageModel.CLUSTERING     // 集群模式
)
public class OrderCreateConsumer implements RocketMQListener<OrderEvent> {

    @Override
    public void onMessage(OrderEvent message) {
        log.info("收到订单创建消息: orderId={}, amount={}",
                message.getOrderId(), message.getAmount());
        // 业务处理，抛异常则触发重试
        processOrder(message);
    }

    private void processOrder(OrderEvent event) {
        // 幂等性检查
        if (idempotentService.isProcessed(event.getOrderId())) {
            log.warn("订单已处理: {}", event.getOrderId());
            return;
        }
        // 业务逻辑
        orderService.createOrder(event);
        // 记录已处理
        idempotentService.markProcessed(event.getOrderId());
    }
}
```

### 4.2 顺序消费

```java
@Component
@RocketMQMessageListener(
        consumerGroup = "order-seq-consumer",
        topic = "order-seq-topic",
        consumeMode = ConsumeMode.ORDERLY,  // 有序消费
        messageModel = MessageModel.CLUSTERING
)
public class OrderSequentialConsumer implements RocketMQListener<OrderEvent> {

    @Override
    public void onMessage(OrderEvent message) {
        log.info("顺序消费: orderId={}, status={}",
                message.getOrderId(), message.getStatus());
        // 同一个 queue 中的消息串行处理
        orderService.updateOrderStatus(message);
    }
}
```

### 4.3 批量消费

```java
@Component
@RocketMQMessageListener(
        consumerGroup = "batch-order-consumer",
        topic = "order-topic",
        consumeMode = ConsumeMode.CONCURRENTLY
)
public class BatchOrderConsumer implements RocketMQListener<List<OrderEvent>> {

    @Override
    public void onMessage(List<OrderEvent> messages) {
        log.info("批量收到 {} 条消息", messages.size());
        // 批量处理
        orderService.batchCreateOrders(messages);
    }
}
```

## 五、事务消息实战

事务消息是 RocketMQ 最核心的特性之一——保证**本地事务与消息发送的最终一致性**。

### 5.1 业务场景

订单创建流程：
```
用户下单 → 创建订单(DB) + 发送"订单创建"消息
```
需要保证：要么订单创建成功且消息发送成功，要么都回滚。

### 5.2 事务消息实现

```java
@Component
@Slf4j
@RocketMQTransactionListener(rocketMQTemplateBeanName = "rocketMQTemplate")
public class OrderTransactionListener implements RocketMQLocalTransactionListener {

    private final ConcurrentHashMap<String, OrderEvent> localTrans =
            new ConcurrentHashMap<>();

    /**
     * 执行本地事务（在半消息发送成功后回调）
     */
    @Override
    @Transactional(rollbackFor = Exception.class)
    public RocketMQLocalTransactionState executeLocalTransaction(Message msg, Object arg) {
        OrderEvent event = (OrderEvent) arg;
        String transactionId = (String) msg.getHeaders().get("rocketmq_TRANSACTION_ID");

        try {
            log.info("执行本地事务: orderId={}", event.getOrderId());

            // 保存本地事务记录
            localTransactionService.saveTransaction(transactionId, event);

            // 执行业务逻辑
            orderService.createOrder(event);

            // 记录事务状态
            localTrans.put(transactionId, event);

            // 提交消息
            return RocketMQLocalTransactionState.COMMIT;
        } catch (Exception e) {
            log.error("本地事务执行失败: orderId={}", event.getOrderId(), e);
            localTrans.put(transactionId, event);
            // 回滚消息
            return RocketMQLocalTransactionState.ROLLBACK;
        }
    }

    /**
     * 事务状态回查（RocketMQ 会定期回查 UNKNOWN 状态的事务）
     */
    @Override
    public RocketMQLocalTransactionState checkLocalTransaction(Message msg) {
        String transactionId =
                (String) msg.getHeaders().get("rocketmq_TRANSACTION_ID");
        OrderEvent event = localTrans.get(transactionId);

        if (event == null) {
            return RocketMQLocalTransactionState.UNKNOWN;
        }

        // 查询本地事务是否已提交
        boolean success = localTransactionService.isCommitted(transactionId);
        if (success) {
            return RocketMQLocalTransactionState.COMMIT;
        } else {
            return RocketMQLocalTransactionState.ROLLBACK;
        }
    }
}
```

### 5.3 发送事务消息

```java
public void sendTransactionMessage(OrderEvent event) {
    Message<OrderEvent> message = MessageBuilder
            .withPayload(event)
            .setHeader("orderId", event.getOrderId())
            .build();

    TransactionSendResult result = rocketMQTemplate.sendMessageInTransaction(
            "order-tx-topic:create",
            message,
            event  // 传递到 executeLocalTransaction 的 arg 参数
    );

    log.info("事务消息发送结果: status={}, transactionId={}",
            result.getLocalTransactionState(),
            result.getTransactionId());
}
```

### 5.4 事务消息流程图解

```
Producer                    RocketMQ Broker                 Consumer
   │                             │                            │
   ├── ① 发送半消息 ─────────→  │                            │
   │                             │ 存储半消息(不可见)         │
   │←── 半消息确认 ─────────────┤                            │
   │                             │                            │
   ├── ② 执行本地事务 ───┐     │                            │
   │                     │     │                            │
   │  ← 成功: COMMIT     │     │                            │
   │  ← 失败: ROLLBACK   │     │                            │
   ├── ③ 提交/回滚 ──────┘─→  │                            │
   │                             │                            │
   │                             ├── COMMIT → 消息可见 ──→ Consumer
   │                             └── ROLLBACK → 消息删除     │
   │                             │                            │
   │←── ④ 状态回查(定期间隔) ──┤ (当事务状态 UNKNOWN)       │
   └─────────────────────────────┘                            │
```

## 六、消息重试与死信处理

### 6.1 消费者失败重试

RocketMQ 默认的消费重试机制：

```java
@Component
@RocketMQMessageListener(
        consumerGroup = "order-retry-consumer",
        topic = "order-topic",
        maxReconsumeTimes = 16  // 最大重试次数
)
public class RetryableConsumer implements RocketMQListener<OrderEvent> {

    @Override
    public void onMessage(OrderEvent message) {
        try {
            process(message);
        } catch (Exception e) {
            log.error("消息处理失败, 将重试: orderId={}", message.getOrderId());
            // 抛异常触发重试（注意：不要 catch 后不抛）
            throw new RuntimeException(e);
        }
    }

    private void process(OrderEvent message) {
        // 获取重试次数
        int reconsumeTimes = message.getReconsumeTimes();
        if (reconsumeTimes >= 3) {
            // 超过3次直接记录死信，不继续重试
            log.error("消息重试{}次仍失败, 写入死信: orderId={}",
                    reconsumeTimes, message.getOrderId());
            deadLetterService.record(message);
            return;  // 不抛异常，视为消费成功
        }
        // 正常处理
        orderService.createOrder(message);
    }
}
```

### 6.2 死信队列手动处理

```java
@EventListener
public void handleDeadLetter(DeadLetterEvent event) {
    log.warn("处理死信消息: topic={}, reconsumeTimes={}, body={}",
            event.getTopic(), event.getReconsumeTimes(), event.getBody());
    // 发送告警
    alertService.sendAlert("RocketMQ 死信告警: " + event.getMsgId());
    // 人工介入或自动补偿
}
```

## 七、最佳实践总结

### 幂等性设计

消息消费最大的坑就是**重复消费**。RocketMQ 支持至少一次（At Least Once），所以消费者必须具备幂等性：

```java
@Transactional
public void createOrder(OrderEvent event) {
    // 1. 幂等表去重
    if (duplicateChecker.isProcessed(event.getOrderId())) {
        return;
    }
    // 2. 执行业务
    orderMapper.insert(event);
    // 3. 记录处理标记
    duplicateChecker.markProcessed(event.getOrderId());
}
```

### 参数推荐

```yaml
rocketmq:
  producer:
    retry-times-when-send-failed: 3
    send-message-timeout: 3000
  consumer:
    # 消费重试次数（达到次数后进入死信）
    max-reconsume-times: 16
```

## 八、面试常见追问

**Q：RocketMQ 事务消息和 Kafka 事务有什么区别？**
A：RocketMQ 事务消息的核心是**本地事务 + 消息 final 一致性**：先发半消息（不可见），执行本地事务后 commit/rollback，Broker 还支持回查。Kafka 事务则是基于原子写入多个分区 + 事务协调器，保证一批消息要么都写入成功要么都失败。两者解决的问题不同：RocketMQ 解决的是「DB 操作 + 消息发送」的原子性，Kafka 解决的是「多个 Topic/Partition 写入」的原子性。

**Q：RocketMQ 消息堆积了怎么处理？**
A：① 扩容 Consumer 实例（注意 Topic 的 Queue 数决定了最大并发度，Queue 数不够要先扩容 Queue）；② 检查消费端是否有慢逻辑（如 RPC 调用、数据库慢查询）；③ 临时增加 Broker 的 Queue 数量；④ 使用批量消费提高吞吐；⑤ 紧急时可以跳过非关键消息，只处理最新的。

---

本文覆盖了 Spring Boot 集成 RocketMQ 的全流程实战。核心能力：消息发送、顺序消息、事务消息、消费重试与死信处理。掌握这些，你就能在生产环境中搭建一套可靠的消息驱动架构。
