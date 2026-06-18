---
title: 事件驱动架构设计实战
date: 2026-06-18 08:00:00
tags:
  - 事件驱动
  - 架构设计
  - 消息队列
  - CQRS
categories:
  - 架构设计
author: 东哥
---

# 事件驱动架构设计实战

## 一、事件驱动架构概述

### 1.1 核心概念

事件驱动架构（Event-Driven Architecture, EDA）是一种基于事件的产生、检测、消费和响应的软件架构模式。与传统的请求-响应模式不同，事件驱动架构中的组件通过事件进行松耦合通信。

```
传统请求-响应:
┌──────┐  请求   ┌──────┐
│服务A  │───────→│服务B  │
│      │←───────│      │
└──────┘  响应   └──────┘

事件驱动:
┌──────┐  事件    ┌───────┐
│服务A  │───────→│事件总线│
│(生产者)│        │(Broker)│──────→ 服务B, 服务C, 服务D...
└──────┘          └───────┘        (消费者)
```

### 1.2 事件类型

| 事件类型 | 描述 | 示例 | 特点 |
|---------|------|------|------|
| 领域事件 | 业务领域中发生的重大事 | OrderCreated, PaymentReceived | 不可变，有业务意义 |
| 事件通知 | 状态变更的简单通知 | UserUpdated | 仅包含变更事实 |
| 事件携带状态 | 包含变更后的完整状态 | OrderStatusChanged{orderId, status} | 减少查询依赖 |
| 命令事件 | 请求执行某个操作 | SendEmail, ValidatePayment | 期望被处理 |
| 调度事件 | 定时触发的事件 | BatchJobTrigger | 定时/计划执行 |

### 1.3 架构优势与挑战

| 维度 | 优势 | 挑战 |
|------|------|------|
| 松耦合 | 生产者和消费者互相不感知 | 调试困难，流程不可见 |
| 可扩展 | 消费者可独立扩缩容 | 事件顺序难以保证 |
| 弹性 | 消费者故障不影响生产者 | 最终一致性带来复杂度 |
| 异步 | 提高系统吞吐量 | 回调地狱，超时处理 |
| 可追踪 | 事件溯源提供完整审计 | 事件版本管理复杂 |

## 二、核心模式

### 2.1 事件通知（Event Notification）

```java
// 事件定义
public record OrderCreatedEvent(
    String eventId,
    String orderId,
    Long userId,
    BigDecimal totalAmount,
    List<OrderItem> items,
    Instant occurredAt
) implements DomainEvent {
    public OrderCreatedEvent {
        Objects.requireNonNull(eventId);
        Objects.requireNonNull(orderId);
    }
}

// 事件发布
@Service
public class OrderDomainService {
    
    private final EventPublisher eventPublisher;
    private final OrderRepository orderRepository;
    
    @Transactional
    public Order createOrder(CreateOrderCommand command) {
        // 1. 创建订单
        Order order = Order.create(
            command.userId(),
            command.items(),
            command.shippingAddress()
        );
        
        // 2. 保存到数据库
        order = orderRepository.save(order);
        
        // 3. 发布领域事件
        eventPublisher.publish(new OrderCreatedEvent(
            UUID.randomUUID().toString(),
            order.getOrderId(),
            order.getUserId(),
            order.getTotalAmount(),
            order.getItems(),
            Instant.now()
        ));
        
        return order;
    }
}

// 事件消费者
@Component
public class OrderCreatedEventHandler {
    
    private final InventoryService inventoryService;
    private final NotificationService notificationService;
    private final AnalyticsService analyticsService;
    
    @EventListener
    public void handleOrderCreated(OrderCreatedEvent event) {
        // 并行执行多个无关的副作用
        CompletableFuture.allOf(
            CompletableFuture.runAsync(() -> 
                inventoryService.reserveInventory(event.items())),
            CompletableFuture.runAsync(() -> 
                notificationService.sendOrderConfirmation(event.userId(), event.orderId())),
            CompletableFuture.runAsync(() -> 
                analyticsService.recordOrder(event))
        ).join();
    }
}
```

### 2.2 事件溯源（Event Sourcing）

事件溯源的核心思想是：不存储对象的当前状态，而是存储所有状态变更的事件。当前状态通过重放事件计算得到。

```
传统存储:
┌──────┐    ┌──────────────┐
│账户   │───→│ accounts     │
│余额=100│   │ id=1, balance=100│
└──────┘    └──────────────┘

事件溯源:
┌──────┐    ┌──────────────────┐
│账户   │───→│ account_events   │
│余额=100│   │ id=1, type=CREATED, amt=100│
│(重放)  │   │ id=2, type=WITHDRAW, amt=30 │
└──────┘    │ id=3, type=DEPOSIT, amt=50  │
            │ ...                          │
            └──────────────────┘
```

```java
// 事件存储
@Entity
@Table(name = "domain_events")
public class DomainEventEntity {
    @Id
    private String eventId;
    private String aggregateId;
    private String eventType;
    private int version;
    private String eventData;     // JSON 序列化的事件
    private Instant occurredAt;
    
    // getters, setters
}

// 事件仓库
@Repository
public class EventStore {
    
    private final JdbcTemplate jdbcTemplate;
    private final ObjectMapper objectMapper;
    
    @Transactional
    public void saveEvents(String aggregateId, 
                          List<DomainEvent> events, 
                          int expectedVersion) {
        for (DomainEvent event : events) {
            jdbcTemplate.update("""
                INSERT INTO domain_events 
                (event_id, aggregate_id, event_type, version, event_data, occurred_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                event.eventId(),
                aggregateId,
                event.getClass().getSimpleName(),
                ++expectedVersion,
                toJson(event),
                event.occurredAt()
            );
        }
    }
    
    public List<DomainEvent> getEvents(String aggregateId) {
        return jdbcTemplate.query("""
            SELECT * FROM domain_events 
            WHERE aggregate_id = ? ORDER BY version ASC
            """,
            (rs, rowNum) -> deserializeEvent(rs),
            aggregateId
        );
    }
    
    // 快照（性能优化）
    public Optional<Snapshot> getSnapshot(String aggregateId) {
        return jdbcTemplate.query("""
            SELECT * FROM snapshots 
            WHERE aggregate_id = ? 
            ORDER BY version DESC LIMIT 1
            """,
            (rs, rowNum) -> new Snapshot(
                rs.getInt("version"),
                rs.getString("snapshot_data")
            ),
            aggregateId
        ).stream().findFirst();
    }
}

// 聚合根：从事件重建状态
public class BankAccount {
    
    private String accountId;
    private BigDecimal balance;
    private int version;
    private boolean closed;
    
    // 从事件流重建
    public static BankAccount recreateFrom(String accountId, 
                                          List<DomainEvent> events) {
        BankAccount account = new BankAccount();
        account.accountId = accountId;
        events.forEach(account::applyEvent);
        return account;
    }
    
    // 处理命令
    public List<DomainEvent> withdraw(BigDecimal amount, String reason) {
        if (closed) {
            throw new IllegalStateException("账户已关闭");
        }
        if (balance.compareTo(amount) < 0) {
            throw new InsufficientBalanceException(
                "余额不足: 需要 " + amount + ", 可用 " + balance);
        }
        
        return List.of(new MoneyWithdrawn(
            UUID.randomUUID().toString(),
            accountId, amount, reason, Instant.now()
        ));
    }
    
    // 应用事件（状态变化）
    private void applyEvent(DomainEvent event) {
        version = event.version();
        switch (event) {
            case AccountCreated e -> {
                this.balance = e.initialBalance();
            }
            case MoneyDeposited e -> {
                this.balance = this.balance.add(e.amount());
            }
            case MoneyWithdrawn e -> {
                this.balance = this.balance.subtract(e.amount());
            }
            case AccountClosed ignored -> {
                this.closed = true;
            }
            default -> {}
        }
    }
}
```

### 2.3 CQRS（Command Query Responsibility Segregation）

CQRS 将读操作和写操作分离到不同的模型中：

```
┌────────────────────────────────────────────────────┐
│                   Application                        │
├─────────────────┬──────────────────────────────────┤
│  Command Side   │          Query Side               │
│  (写模型)        │         (读模型)                    │
├─────────────────┼──────────────────────────────────┤
│                 │                                   │
│  CreateOrder    │   OrderSummary                    │
│  UpdateOrder    │   OrderDetail                     │
│  CancelOrder     │   OrderHistory                    │
│                 │                                   │
│  ┌───────────┐  │   ┌─────────────┐                │
│  │ Postgres   │  │   │ Elasticsearch│               │
│  │ (规范化)   │  │   │ (反规范化)   │               │
│  └─────┬─────┘  │   └──────┬──────┘                │
└────────┼────────┴──────────┼───────────────────────┘
         │                   │
         │     ┌───────────┐ │
         └────→│ Event Bus │─┘
               │ (Kafka)   │
               └───────────┘
```

```java
// Command 侧
@RestController
@RequestMapping("/api/commands/orders")
public class OrderCommandController {
    
    private final OrderCommandHandler commandHandler;
    
    @PostMapping
    public CompletableFuture<CreateOrderResult> createOrder(
            @RequestBody CreateOrderCommand command) {
        return commandHandler.handle(command);
    }
    
    @PutMapping("/{orderId}/cancel")
    public CompletableFuture<Void> cancelOrder(
            @PathVariable String orderId,
            @RequestBody CancelOrderCommand command) {
        return commandHandler.handle(
            new CancelOrderCommand(orderId, command.reason()));
    }
}

// 命令处理器
@Component
public class OrderCommandHandler {
    
    private final OrderRepository orderRepository;
    private final EventBus eventBus;
    private final Validator validator;
    
    public CompletableFuture<CreateOrderResult> handle(CreateOrderCommand command) {
        return CompletableFuture.supplyAsync(() -> {
            // 1. 验证
            var violations = validator.validate(command);
            if (!violations.isEmpty()) {
                throw new ValidationException(violations);
            }
            
            // 2. 创建订单
            Order order = Order.create(command);
            orderRepository.save(order);
            
            // 3. 发布事件（Event Bus 负责同步到查询侧）
            eventBus.publish(new OrderCreatedEvent(
                order.getOrderId(), order.getUserId(), 
                order.getTotalAmount(), Instant.now()));
            
            return new CreateOrderResult(order.getOrderId());
        });
    }
}

// Query 侧
@RestController
@RequestMapping("/api/queries/orders")
public class OrderQueryController {
    
    private final OrderQueryRepository queryRepository;
    
    @GetMapping("/{orderId}")
    public CompletableFuture<OrderProjection> getOrder(
            @PathVariable String orderId) {
        return CompletableFuture.supplyAsync(() ->
            queryRepository.findById(orderId)
                .orElseThrow(() -> new OrderNotFoundException(orderId)));
    }
    
    @GetMapping
    public CompletableFuture<Page<OrderSummary>> listOrders(
            @RequestParam Long userId,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        return CompletableFuture.supplyAsync(() ->
            queryRepository.findByUserId(userId, PageRequest.of(page, size)));
    }
}

// 投影更新器（监听事件更新读模型）
@Component
public class OrderProjectionUpdater {
    
    private final OrderQueryRepository queryRepository;
    
    @EventListener
    @Transactional
    public void on(OrderCreatedEvent event) {
        OrderProjection projection = OrderProjection.builder()
            .orderId(event.orderId())
            .userId(event.userId())
            .totalAmount(event.totalAmount())
            .status("PENDING")
            .createdAt(event.occurredAt())
            .items(List.of())
            .build();
        
        queryRepository.save(projection);
    }
    
    @EventListener
    public void on(OrderShippedEvent event) {
        queryRepository.updateStatus(event.orderId(), "SHIPPED");
    }
}
```

## 三、事件驱动基础设施

### 3.1 Kafka 事件总线实现

```java
@Configuration
public class KafkaEventBusConfig {
    
    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, DomainEvent> 
            kafkaListenerContainerFactory(
            ConsumerFactory<String, DomainEvent> consumerFactory,
            KafkaTemplate<String, DomainEvent> kafkaTemplate) {
        
        var factory = new ConcurrentKafkaListenerContainerFactory<String, DomainEvent>();
        factory.setConsumerFactory(consumerFactory);
        factory.setConcurrency(3);
        factory.getContainerProperties().setAckMode(AckMode.MANUAL);
        factory.setCommonErrorHandler(new DefaultErrorHandler(
            new FixedBackOff(1000L, 3L)));
        
        return factory;
    }
    
    @Bean
    public KafkaTemplate<String, DomainEvent> kafkaTemplate(
            ProducerFactory<String, DomainEvent> producerFactory) {
        KafkaTemplate<String, DomainEvent> template = 
            new KafkaTemplate<>(producerFactory);
        template.setDefaultTopic("domain-events");
        return template;
    }
}

@Component
public class KafkaEventBus implements EventBus {
    
    private final KafkaTemplate<String, DomainEvent> kafkaTemplate;
    private final ObjectMapper objectMapper;
    private static final String TOPIC = "domain-events";
    
    @Override
    public void publish(DomainEvent event) {
        // 使用 aggregateId 作为分区键保证同一聚合的事件有序
        ListenableFuture<SendResult<String, DomainEvent>> future = 
            kafkaTemplate.send(TOPIC, event.aggregateId(), event);
        
        future.addCallback(
            result -> log.debug("事件发布成功: {} {}", 
                event.getType(), result.getRecordMetadata().offset()),
            ex -> log.error("事件发布失败: {}", event.getType(), ex)
        );
    }
    
    @Override
    public void publishAll(List<DomainEvent> events) {
        events.forEach(this::publish);
    }
}

// 批量消费者
@Component
public class EventConsumer {
    
    @KafkaListener(topics = "domain-events", groupId = "order-service")
    public void consume(@Payload List<DomainEvent> events,
                       Acknowledgment acknowledgment) {
        try {
            events.forEach(event -> {
                log.info("处理事件: type={}, aggregateId={}", 
                    event.getClass().getSimpleName(), event.aggregateId());
                handleEvent(event);
            });
            acknowledgment.acknowledge();
        } catch (Exception e) {
            log.error("事件消费异常", e);
            // 死信队列处理
            sendToDlq(events, e);
        }
    }
}
```

### 3.2 事件版本管理

```java
// 事件版本演化
// v1 - 初始版本
public record OrderCreatedEventV1(
    String eventId,
    String orderId,
    Long userId,
    BigDecimal totalAmount,
    List<OrderItem> items,
    Instant occurredAt
) implements DomainEvent {}

// v2 - 新增 shippingAddress 和 paymentMethod 字段
public record OrderCreatedEventV2(
    String eventId,
    String orderId,
    Long userId,
    BigDecimal totalAmount,
    List<OrderItem> items,
    Address shippingAddress,      // 新增
    String paymentMethod,          // 新增
    String couponId,              // 新增
    Instant occurredAt
) implements DomainEvent {}

// 版本升级器
@Component
public class EventUpgrader {
    
    private final Map<String, Function<JsonNode, DomainEvent>> upgraderMap = Map.of(
        "OrderCreatedEvent", this::upgradeOrderCreated
    );
    
    public DomainEvent upgrade(String eventType, JsonNode eventData, int version) {
        Function<JsonNode, DomainEvent> upgrader = upgraderMap.get(eventType);
        if (upgrader == null) {
            throw new IllegalArgumentException("未知事件类型: " + eventType);
        }
        
        DomainEvent event = upgrader.apply(eventData);
        
        // 多版本升级
        while (event.version() < currentVersion(eventType)) {
            event = upgradeToNext(event);
        }
        
        return event;
    }
    
    private DomainEvent upgradeOrderCreated(JsonNode data) {
        // v1: 基本字段
        // 添加默认值
        if (data.get("shippingAddress") == null) {
            // v1 → v2 升级逻辑
            return new OrderCreatedEventV2(
                data.get("eventId").asText(),
                data.get("orderId").asText(),
                data.get("userId").asLong(),
                BigDecimal.valueOf(data.get("totalAmount").asDouble()),
                parseItems(data.get("items")),
                Address.defaultAddress(),
                "UNKNOWN",
                null,
                Instant.parse(data.get("occurredAt").asText())
            );
        }
        // 已经是 v2
        return objectMapper.convertValue(data, OrderCreatedEventV2.class);
    }
}
```

## 四、幂等性与最终一致性

### 4.1 幂等消费者

```java
@Component
public class IdempotentEventConsumer {
    
    private final StringRedisTemplate redisTemplate;
    
    // 使用 Redis 实现去重
    public boolean tryProcess(String eventId, String consumerId) {
        String key = "event:processed:" + consumerId + ":" + eventId;
        
        // SET NX EX 86400（一天的去重窗口）
        Boolean success = redisTemplate.opsForValue()
            .setIfAbsent(key, "1", Duration.ofDays(1));
        
        return Boolean.TRUE.equals(success);
    }
    
    @EventListener
    public void handlePaymentReceived(PaymentReceivedEvent event) {
        if (!tryProcess(event.eventId(), "payment-handler")) {
            log.info("事件已处理，跳过: {}", event.eventId());
            return;
        }
        
        // 执行业务逻辑（自身也需要幂等）
        orderService.markOrderAsPaid(event.orderId(), event.transactionId());
    }
}

// 数据库级别的幂等（唯一约束）
@Repository
public interface EventProcessedLogRepository extends JpaRepository<EventProcessedLog, Long> {
    
    boolean existsByEventIdAndConsumerId(String eventId, String consumerId);
    
    // 唯一的 event_id + consumer_id 组合
    @Query(value = """
        INSERT INTO event_processed_log (event_id, consumer_id, processed_at)
        VALUES (:eventId, :consumerId, :processedAt)
        ON CONFLICT (event_id, consumer_id) DO NOTHING
        """, nativeQuery = true)
    void tryInsert(@Param("eventId") String eventId,
                   @Param("consumerId") String consumerId,
                   @Param("processedAt") Instant processedAt);
}
```

### 4.2 Saga 模式实现

```java
// Saga 编排器
@Component
public class OrderSagaOrchestrator {
    
    private final EventBus eventBus;
    private final SagaStateRepository sagaRepository;
    
    @EventListener
    public void startSaga(OrderCreatedEvent event) {
        SagaState state = new SagaState(
            UUID.randomUUID().toString(),
            event.orderId(),
            SagaStatus.IN_PROGRESS
        );
        sagaRepository.save(state);
        
        // 步骤1: 预留库存
        eventBus.publish(new ReserveInventoryCommand(
            state.sagaId(),
            event.orderId(),
            event.items()
        ));
    }
    
    @EventListener
    public void handleInventoryReserved(InventoryReservedEvent event) {
        SagaState state = sagaRepository.findBySagaId(event.sagaId());
        
        // 步骤2: 处理支付
        eventBus.publish(new ProcessPaymentCommand(
            state.sagaId(),
            event.orderId(),
            event.totalAmount()
        ));
    }
    
    @EventListener
    public void handlePaymentProcessed(PaymentProcessedEvent event) {
        SagaState state = sagaRepository.findBySagaId(event.sagaId());
        
        // 步骤3: 确认订单
        eventBus.publish(new ConfirmOrderCommand(
            state.sagaId(),
            event.orderId()
        ));
        
        state.setStatus(SagaStatus.COMPLETED);
        sagaRepository.save(state);
    }
    
    // 补偿处理
    @EventListener
    public void handleSagaFailure(SagaFailureEvent event) {
        SagaState state = sagaRepository.findBySagaId(event.sagaId());
        state.setStatus(SagaStatus.COMPENSATING);
        
        // 执行补偿操作
        if (event.failedAt().equals("reserve-inventory")) {
            // 无需补偿（还未执行任何操作）
        } else if (event.failedAt().equals("process-payment")) {
            eventBus.publish(new ReleaseInventoryCommand(
                state.sagaId(), event.orderId()));
        } else if (event.failedAt().equals("confirm-order")) {
            eventBus.publish(new RefundPaymentCommand(
                state.sagaId(), event.orderId()));
            eventBus.publish(new ReleaseInventoryCommand(
                state.sagaId(), event.orderId()));
        }
        
        state.setStatus(SagaStatus.COMPENSATED);
        sagaRepository.save(state);
    }
}
```

## 五、事件驱动与微服务结合

### 5.1 服务间事件通知模式

| 模式 | 传递内容 | 一致性 | 适用场景 |
|------|---------|--------|---------|
| Event Notification | 事件+ID | 最终一致 | 松耦合通知 |
| Event-Carried State | 完整状态 | 最终一致 | 减少服务查询 |
| CQRS | 命令+查询分离 | 最终一致 | 复杂查询场景 |
| Saga | 多步骤交易 | 最终一致 | 跨服务事务 |

### 5.2 事件驱动架构选型

| 维度 | Kafka | RabbitMQ | Pulsar | AWS SQS/SNS |
|------|-------|---------|--------|------------|
| 吞吐量 | 极高 | 中高 | 高 | 高 |
| 延迟 | 低 | 极低 | 低 | 低 |
| 消息持久化 | 磁盘 | 磁盘/内存 | 分层存储 | 内置 |
| 消息顺序 | 分区内有序 | 队列有序 | 分片有序 | 非严格有序 |
| 重试机制 | 消费者实现 | 内置死信 | 内置重试 | DLQ |
| 运维复杂度 | 高 | 中 | 高 | 无 |
| 适用场景 | 事件溯源 | 任务调度 | 多租户 | 无服务器 |

## 六、实战注意事项

### 6.1 常见陷阱

```java
// ❌ 在事务内发送事件（事件发送失败会导致事务提交了但事件丢失）
@Transactional
public void createOrderWithEventInTx(CreateOrderCommand command) {
    Order order = orderRepository.save(Order.create(command));
    eventBus.publish(new OrderCreatedEvent(order.getOrderId()));  // 可能失败
}

// ✅ 使用发件箱模式（Outbox Pattern）
@Transactional
public void createOrderWithOutbox(CreateOrderCommand command) {
    Order order = orderRepository.save(Order.create(command));
    
    // 1. 事件写入发件箱表（和业务数据在同一事务）
    outboxRepository.save(new OutboxMessage(
        UUID.randomUUID().toString(),
        "OrderCreatedEvent",
        serializeEvent(new OrderCreatedEvent(order.getOrderId())),
        Instant.now()
    ));
}

// 2. 独立的发件箱发布器
@Component
public class OutboxPublisher {
    
    @Scheduled(fixedDelay = 1000)
    @Transactional
    public void publishOutboxMessages() {
        List<OutboxMessage> messages = outboxRepository
            .findTop100ByPublishedFalseOrderByCreatedAtAsc();
        
        for (OutboxMessage message : messages) {
            try {
                eventBus.publish(deserializeEvent(message));
                message.setPublished(true);
            } catch (Exception e) {
                log.error("发件箱消息发布失败: {}", message.getId(), e);
                if (message.getRetryCount()++ > 10) {
                    message.setStatus(MessageStatus.FAILED);
                }
            }
        }
    }
}
```

### 6.2 测试策略

```java
@SpringBootTest
@Testcontainers
class EventDrivenOrderServiceTest {
    
    @Container
    static KafkaContainer kafka = new KafkaContainer(
        DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));
    
    @Autowired
    private OrderCommandHandler commandHandler;
    
    @Autowired
    private OrderProjectionUpdater projectionUpdater;
    
    @Test
    void shouldUpdateReadModelWhenOrderCreated() {
        // 准备
        CreateOrderCommand command = new CreateOrderCommand(1L, 
            List.of(new OrderItem("P001", 2, BigDecimal.valueOf(99.99))));
        
        // 执行
        CreateOrderResult result = commandHandler.handle(command).join();
        
        // 等待事件处理完成
        await().atMost(10, TimeUnit.SECONDS).until(() ->
            projectionUpdater.findById(result.orderId()).isPresent()
        );
        
        // 验证
        OrderProjection projection = projectionUpdater
            .findById(result.orderId()).get();
        
        assertThat(projection.getStatus()).isEqualTo("PENDING");
        assertThat(projection.getItems()).hasSize(1);
    }
}
```

## 总结

事件驱动架构通过松耦合、异步通信的方式，解决了微服务架构中的服务协调和数据一致性问题。核心模式包括事件通知、事件溯源、CQRS 和 Saga，每种模式有其适用场景和挑战。

实施事件驱动架构的关键要点：
1. **明确事件边界**：领域事件应反映真实的业务变更
2. **保障幂等性**：消费者必须能够处理重复事件
3. **处理最终一致性**：使用补偿机制处理失败场景
4. **发件箱模式**：确保业务数据和事件的一致发布
5. **版本管理**：事件结构需要向前兼容

事件驱动不是银弹，选择合适的场景（跨服务通信、复杂工作流、审计记录）才能发挥其最大价值。
