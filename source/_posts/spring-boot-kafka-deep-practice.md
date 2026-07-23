---
title: 【Spring Boot 实战】Spring Boot 集成 Kafka 深度实战：从 @KafkaListener 到消息重试与死信
date: 2026-07-23 08:00:00
tags:
  - Spring Boot
  - Kafka
  - 消息队列
  - 消息中间件
categories:
  - Java
  - Spring Boot
  - 中间件
author: 东哥
---

# 【Spring Boot 实战】Spring Boot 集成 Kafka 深度实战：从 @KafkaListener 到消息重试与死信

## 一、为什么选择 Spring for Apache Kafka？

在实际项目中，Kafka 是处理高吞吐量消息流的首选中间件。而 Spring for Apache Kafka（以下简称 Spring Kafka）为 Spring Boot 应用提供了开箱即用的 Kafka 集成，屏蔽了底层 Consumer/Producer API 的复杂性，提供了声明式消费、消息转换、重试机制、事务消息等企业级特性。

**核心优势对比：**

| 特性 | 原生 Kafka Client | Spring Kafka |
|------|:---:|:---:|
| 声明式消费 | ❌ 手动循环 poll | ✅ @KafkaListener 注解 |
| 反序列化 | 手动处理 | ✅ 自动类型转换 + MessageConverter |
| 重试机制 | 需自行实现 | ✅ @RetryableTopic / SeekToCurrentErrorHandler |
| 事务消息 | 需手动控制 | ✅ @Transactional + KafkaTemplate 事务 |
| 批量消费 | 手动管理 offset | ✅ 自动确认 + 批量监听 |

## 二、基础集成与配置

### 2.1 Maven 依赖

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
```

### 2.2 application.yml 配置

```yaml
spring:
  kafka:
    # 生产者配置
    producer:
      bootstrap-servers: localhost:9092
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
      properties:
        # 生产者幂等性
        enable.idempotence: true
        acks: all
        retries: 3
    # 消费者配置
    consumer:
      bootstrap-servers: localhost:9092
      group-id: my-group
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      properties:
        spring.json.trusted.packages: '*'
        # 自动提交关闭，使用手动确认
        enable.auto.commit: false
        auto.offset.reset: earliest
    # 监听容器工厂
    listener:
      type: single
      ack-mode: manual_immediate
      concurrency: 3
```

## 三、核心功能实战

### 3.1 定义消息体

```java
@Data
@AllArgsConstructor
@NoArgsConstructor
public class OrderEvent {
    private String orderId;
    private String userId;
    private BigDecimal amount;
    private LocalDateTime createTime;
    private String status; // CREATED, PAID, SHIPPED
}
```

### 3.2 生产者：发送消息

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventProducer {

    private final KafkaTemplate<String, Object> kafkaTemplate;

    /**
     * 发送订单事件
     */
    public void sendOrderEvent(OrderEvent event) {
        // 使用异步发送 + Callback
        CompletableFuture<SendResult<String, Object>> future =
                kafkaTemplate.send("order-events", event.getOrderId(), event);

        future.whenComplete((result, ex) -> {
            if (ex == null) {
                log.info("消息发送成功: topic={}, partition={}, offset={}, key={}",
                        result.getRecordMetadata().topic(),
                        result.getRecordMetadata().partition(),
                        result.getRecordMetadata().offset(),
                        result.getProducerRecord().key());
            } else {
                log.error("消息发送失败: key={}, error={}", event.getOrderId(), ex.getMessage());
            }
        });
    }

    /**
     * 发送事务消息（保证生产者和本地事务一致性）
     */
    @Transactional
    public void sendOrderEventInTransaction(OrderEvent event) {
        // 在事务中发送
        kafkaTemplate.send("order-events", event.getOrderId(), event);
        // 模拟数据库操作
        orderRepository.save(event);
        // 如果 save 抛异常，消息也不会提交
    }
}
```

### 3.3 消费者：@KafkaListener

```java
@Component
@Slf4j
public class OrderEventListener {

    /**
     * 自动提交 offset（使用 AckMode）
     */
    @KafkaListener(
            topics = "order-events",
            groupId = "order-processing-group",
            containerFactory = "kafkaListenerContainerFactory",
            concurrency = "3"  // 3个并发消费者
    )
    public void handleOrderEvent(
            @Payload OrderEvent event,
            @Header(KafkaHeaders.RECEIVED_PARTITION) int partition,
            @Header(KafkaHeaders.OFFSET) long offset,
            Acknowledgment ack) {

        try {
            log.info("收到订单事件: orderId={}, amount={}, partition={}, offset={}",
                    event.getOrderId(), event.getAmount(), partition, offset);

            // 业务处理
            processOrder(event);

            // 手动确认 offset
            ack.acknowledge();
        } catch (Exception e) {
            log.error("处理订单事件失败: orderId={}", event.getOrderId(), e);
            // 不 ack，消息将在下次 rebalance 时重新消费
        }
    }

    private void processOrder(OrderEvent event) {
        if (event.getAmount().compareTo(BigDecimal.ZERO) <= 0) {
            throw new IllegalArgumentException("订单金额无效: " + event.getAmount());
        }
        // ... 其余业务逻辑
    }
}
```

### 3.4 批量消费配置

```java
@Configuration
public class KafkaConsumerConfig {

    @Bean
    public KafkaListenerContainerFactory<ConcurrentMessageListenerContainer<String, Object>>
            batchFactory(ConsumerFactory<String, Object> consumerFactory) {

        ConcurrentKafkaListenerContainerFactory<String, Object> factory =
                new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(consumerFactory);
        factory.setBatchListener(true); // 开启批量消费
        factory.setConcurrency(3);
        factory.getContainerProperties().setAckMode(ContainerProperties.AckMode.MANUAL_IMMEDIATE);
        return factory;
    }
}
```

```java
@KafkaListener(
        topics = "order-events",
        containerFactory = "batchFactory"
)
public void batchListen(List<OrderEvent> events, Acknowledgment ack) {
    log.info("批量收到 {} 条消息", events.size());
    events.forEach(this::processOrder);
    ack.acknowledge(); // 批量确认
}
```

## 四、消息重试机制深度解析

### 4.1 基础重试：SeekToCurrentErrorHandler

```java
@Component
public class KafkaErrorHandlerConfig {

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, Object>
            retryContainerFactory(ConsumerFactory<String, Object> consumerFactory) {

        ConcurrentKafkaListenerContainerFactory<String, Object> factory =
                new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(consumerFactory);

        // 最多重试3次，间隔1秒、2秒、4秒
        SeekToCurrentErrorHandler errorHandler = new SeekToCurrentErrorHandler(
                new FixedBackOff(1000L, 3L));

        factory.setErrorHandler(errorHandler);
        return factory;
    }
}
```

### 4.2 重试超过次数后发送到死信队列（DLQ）

```java
@Bean
public ConcurrentKafkaListenerContainerFactory<String, Object>
        dlqContainerFactory(ConsumerFactory<String, Object> consumerFactory,
                            KafkaTemplate<String, Object> kafkaTemplate) {

    ConcurrentKafkaListenerContainerFactory<String, Object> factory =
            new ConcurrentKafkaListenerContainerFactory<>();
    factory.setConsumerFactory(consumerFactory);

    // 重试3次后发送到死信队列
    DeadLetterPublishingRecoverer recoverer =
            new DeadLetterPublishingRecoverer(
                    kafkaTemplate,
                    // 自定义死信主题命名规则
                    (record, ex) -> new TopicPartition(
                            record.topic() + ".DLT",
                            record.partition()
                    )
            );

    SeekToCurrentErrorHandler errorHandler = new SeekToCurrentErrorHandler(
            recoverer, new FixedBackOff(1000L, 3L));

    factory.setErrorHandler(errorHandler);
    return factory;
}
```

### 4.3 使用 @RetryableTopic 注解（推荐方式）

```java
@Component
@Slf4j
public class RetryableOrderEventListener {

    /**
     * @RetryableTopic 自动创建重试主题和死信主题
     * - 重试间隔：2秒
     * - 最大重试次数：4次
     * - 重试主题后缀：.retry
     * - 死信主题后缀：.dlt
     */
    @RetryableTopic(
            attempts = "4",
            backoff = @Backoff(delay = 2000, multiplier = 2.0),
            dltTopicSuffix = "-dlt",
            retryTopicSuffix = "-retry",
            autoCreateTopics = "true"
    )
    @KafkaListener(topics = "order-events", groupId = "retry-group")
    public void handleWithRetry(OrderEvent event, Acknowledgment ack) {
        log.info("收到消息(可重试): orderId={}", event.getOrderId());
        processOrder(event);
        ack.acknowledge();
    }

    /**
     * 处理死信消息（兜底逻辑）
     */
    @DltHandler
    public void handleDlt(OrderEvent event, @Header(KafkaHeaders.RECEIVED_TOPIC) String topic) {
        log.error("消息进入死信队列, 请人工介入: orderId={}, topic={}",
                event.getOrderId(), topic);
        // 发送告警通知
        alertService.sendAlert("Kafka 死信告警: " + event.getOrderId());
    }
}
```

## 五、消息过滤与拦截器

### 5.1 按条件过滤消息

```java
@Component
public class OrderEventFilter {

    @KafkaListener(
            topics = "order-events",
            groupId = "filter-group",
            filter = "orderFilter"
    )
    public void handleFilteredEvent(OrderEvent event) {
        // 只处理金额大于100的订单
        log.info("处理大额订单: {}", event.getOrderId());
    }
}

@Component
public class OrderFilter implements RecordFilterStrategy<String, Object> {

    @Override
    public boolean filter(ConsumerRecord<String, Object> record) {
        if (record.value() instanceof OrderEvent event) {
            // true = 过滤掉，false = 保留
            return event.getAmount().compareTo(new BigDecimal("100")) <= 0;
        }
        return false;
    }
}
```

### 5.2 自定义拦截器

```java
@Component
public class LoggingInterceptor implements ConsumerInterceptor<String, Object> {

    @Override
    public ConsumerRecords<String, Object> onConsume(ConsumerRecords<String, Object> records) {
        records.forEach(record ->
                log.debug("消费消息: topic={}, partition={}, offset={}, key={}",
                        record.topic(), record.partition(), record.offset(), record.key()));
        return records;
    }

    @Override
    public void onCommit(Map<TopicPartition, OffsetAndMetadata> offsets) {
        log.debug("offset 已提交: {}", offsets);
    }

    @Override
    public void close() {}

    @Override
    public void configure(Map<String, ?> configs) {}
}
```

## 六、性能调优实战

### 6.1 生产者端调优

```yaml
spring:
  kafka:
    producer:
      # 批量发送，提高吞吐量
      batch-size: 65536      # 64KB
      linger-ms: 5           # 最多等待5ms
      buffer-memory: 33554432 # 32MB 缓存
      compression-type: snappy  # 开启压缩
      properties:
        max.in.flight.requests.per.connection: 5
```

### 6.2 消费者端调优

```yaml
spring:
  kafka:
    consumer:
      fetch-min-bytes: 65536       # 一次拉取至少64KB
      fetch-max-wait-ms: 500       # 最长等待500ms
      max-poll-records: 500        # 一次最多拉取500条
    listener:
      concurrency: 6               # 消费者并发数
      poll-timeout: 3000           # poll 超时时间
```

## 七、Kafka 事务与 Exactly-Once 语义

```java
@Service
@Slf4j
public class OrderService {

    private final KafkaTemplate<String, Object> kafkaTemplate;
    private final OrderRepository orderRepository;

    /**
     * 原子性：数据库操作 + 消息发送要么都成功，要么都失败
     */
    @Transactional(rollbackFor = Exception.class)
    @KafkaTransactionManager
    public void createOrder(OrderEvent event) {
        // 1. 保存订单到数据库
        orderRepository.save(event);

        // 2. 发送消息到 Kafka（事务内）
        kafkaTemplate.send("order-events", event.getOrderId(), event);
        // 事务提交时消息才会可见; 回滚时消息不会发送
    }
}
```

## 八、面试常见追问

**Q1：@KafkaListener 底层是怎么实现消息重试的？**
A：核心是 `SeekToCurrentErrorHandler`。当监听器抛出异常时，它会计算重试次数（基于 `BackOff` 策略），如果未达到阈值则执行 `consumer.seek()` 将 offset 重置到失败位置，实现重新消费；超过阈值则调用 `Recoverer`（如 `DeadLetterPublishingRecoverer`）将消息写入死信队列。

**Q2：手动确认和自动确认有什么区别？**
A：`enable.auto.commit=true` 时，Kafka 客户端定期自动提交 offset，可能导致消息丢失（处理失败但 offset 已提交）或重复消费（offset 提交延迟）。手动确认（`ack-mode=manual_immediate`）由业务代码显式调用 `ack.acknowledge()`，确保消息处理完成后再提交 offset，更可靠。

**Q3：消息积压怎么排查和处理？**
A：① 用 `kafka-consumer-groups` 命令查看 Lag；② 检查消费者是否 hang 住或抛出异常未 ack；③ 增加分区数和消费者并发数；④ 检查网络带宽和磁盘 IO；⑤ 考虑批量消费减少 poll 次数。

## 九、总结

Spring Kafka 将 Kafka 的能力与 Spring 的声明式编程完美融合。本文从基础集成、消息发送/消费、重试机制（`@RetryableTopic` + 死信队列）、消息过滤、性能调优到事务消息，覆盖了生产环境中的绝大多数场景。掌握这些实战技巧，能够帮你在微服务架构中落地一套可靠的消息处理系统。
