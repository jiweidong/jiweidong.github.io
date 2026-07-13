---
title: 【系统设计】CQRS + Event Sourcing 架构模式实战：Axon Framework 从入门到生产
date: 2026-07-13 08:00:00
tags:
  - Java
  - 架构设计
  - CQRS
  - Axon
categories:
  - 系统设计
  - 架构模式
author: 东哥
---

# 【系统设计】CQRS + Event Sourcing 架构模式实战：Axon Framework 从入门到生产

## 一、从传统 CRUD 的困境说起

在日常的后端开发中，我们习惯用同一套数据模型来承载**读**和**写**两大类操作。用户下单 → 插入订单表 → 查询订单 → 返回给前端。看起来简单直接，但当系统成长到一定规模后，这种"一刀切"的模式会暴露出几个严重问题：

| 问题 | 表现 |
|------|------|
| **读写负载不均衡** | 读请求数量通常是写请求的 10-100 倍，但共用一个模型 |
| **查询维度爆炸** | 订单列表需要按状态、时间、金额、商品名、用户等多维度组合查询，单表 SQL 越来越复杂 |
| **业务逻辑耦合** | 创建订单时既要写数据、又要校验库存、又要发消息通知，一个 `save()` 方法越改越臃肿 |
| **历史追踪缺失** | 用户说"这个订单状态怎么变的？"——传统做法只能看日志，没有系统化的审计能力 |

这就是 CQRS（Command Query Responsibility Segregation，命令查询职责分离）和 Event Sourcing（事件溯源）要解决的根问题。

## 二、CQRS 是什么？

### 2.1 核心思想

**CQRS** 的核心极简：**将写操作（Command）和读操作（Query）的模型分离**。

- **Command 端（写模型）**：处理业务逻辑、校验规则、状态变更，最终产生事件。方法命名通常是动词命令式：`createOrder()`、`cancelOrder()`。
- **Query 端（读模型）**：为查询场景量身定制，可能反范式、预聚合、甚至使用完全不同的存储（Elasticsearch、Redis、只读库）。

```java
// 传统模式：一个 Order 既管写又管读
public class OrderService {
    public void createOrder(CreateOrderRequest req) { /* 写逻辑 */ }
    public OrderVO queryOrder(Long id) { /* 读逻辑 */ }
    public PageResult<OrderVO> pageQuery(PageReq req) { /* 又读又可能有写逻辑 */ }
}

// CQRS 模式：分离
public class OrderCommandService {
    public void handle(CreateOrderCommand cmd) { /* 纯写逻辑 */ }
}

public class OrderQueryService {
    public OrderView getOrder(Long id) { /* 纯读逻辑，直接查视图表或ES */ }
}
```

### 2.2 不需要 ES 的"轻量 CQRS"

很多人一提到 CQRS 就觉得必须搭一套 Kafka + Elasticsearch。实际上，即便只在单库中做**表的分离**，也能收获大部分好处：

- **写表**（Orders）：按业务范式设计，3NF 或更严格
- **读表**（OrderViews）：按前端展示反范式设计，一个宽表存所有需要展示的字段
- 写入后通过同一个事务或最终一致性同步给读表

这被称为 **"表级 CQRS"**，是性价比最高的切入点。

## 三、Event Sourcing 又是什么？

### 3.1 不存状态，存事件

**Event Sourcing（事件溯源）** 的思想更加颠覆：**不保存当前状态，只保存所有发生过的事件**。当前状态由事件流"重放"得出。

举个例子，传统订单表：

```
orders 表：
| id | status    | total | updated_at          |
|----|-----------|-------|---------------------|
| 1  | PAID      | 100   | 2026-07-13 10:00:00 |
```

Event Sourcing 下的存储：

```
order_events 表：
| id | aggregate_id | event_type            | data                                  | timestamp           |
|----|--------------|-----------------------|---------------------------------------|---------------------|
| 1  | order-1      | OrderCreatedEvent     | {"total":100, "userId":42}            | 2026-07-13 09:00:00 |
| 2  | order-1      | OrderPaidEvent        | {"paymentId":"pay-001", "amount":100} | 2026-07-13 09:30:00 |
| 3  | order-1      | OrderDispatchedEvent  | {"expressNo":"SF123"}                 | 2026-07-13 10:00:00 |
```

### 3.2 Event Sourcing 的优点

| 优势 | 说明 |
|------|------|
| **完整的审计日志** | 每一个状态变更都有据可查，天然满足金融、合规场景需求 |
| **时间旅行能力** | 可以重建任意时间点的状态，调试bug时特别有用 |
| **事件驱动友好** | 每个事件都可以作为消息发布到消息队列，触发其他服务 |
| **CQRS 天然拍档** | 事件存储可以作为写模型，读模型从事件流构建投射 |

### 3.3 缺点也不能忽视

- **查询复杂**：没有当前状态的"快照"，每次查询都要重放事件（需快照优化）
- **事件模式演进困难**：已发布的事件不能修改，新版本代码必须兼容老事件
- **学习曲线陡峭**：团队需要转变思维方式

## 四、Axon Framework 实战

Axon Framework 是目前 Java 生态中最成熟的 CQRS/ES 框架，它提供了四层抽象：

### 4.1 项目搭建

**Maven 依赖：**

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.0</version>
</parent>

<properties>
    <axon.version>4.9.3</axon.version>
</properties>

<dependencies>
    <dependency>
        <groupId>org.axonframework</groupId>
        <artifactId>axon-spring-boot-starter</artifactId>
        <version>${axon.version}</version>
    </dependency>
    <!-- Axon 提供了内存、JPA、MongoDB 几种 Event Store，生产推荐 JPA -->
    <dependency>
        <groupId>org.axonframework</groupId>
        <artifactId>axon-eventsourcing</artifactId>
        <version>${axon.version}</version>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
        <groupId>org.axonframework</groupId>
        <artifactId>axon-configuration</artifactId>
        <version>${axon.version}</version>
    </dependency>
</dependencies>
```

### 4.2 定义命令、事件和聚合

**步骤一：定义 Command 和 Event**

```java
// OrderCreateCommand.java
@Data
@AllArgsConstructor
public class CreateOrderCommand {
    @TargetAggregateIdentifier  // 标识聚合ID
    private String orderId;
    private String userId;
    private BigDecimal totalAmount;
    private List<OrderItem> items;
}

// OrderCreatedEvent.java
@Data
@AllArgsConstructor
public class OrderCreatedEvent {
    private String orderId;
    private String userId;
    private BigDecimal totalAmount;
    private List<OrderItem> items;
    private Instant createdAt;
}
```

**步骤二：定义聚合（Aggregate）**

聚合是 CQRS 中最核心的概念——它是一组业务实体的"一致性边界"：

```java
@Aggregate
public class OrderAggregate {

    @AggregateIdentifier
    private String orderId;
    private OrderStatus status;
    private BigDecimal totalAmount;
    private String userId;

    // Axon 需要无参构造
    public OrderAggregate() {}

    // 命令处理器：@CommandHandler 标记处理哪个命令
    @CommandHandler
    public OrderAggregate(CreateOrderCommand cmd) {
        // 校验业务规则...
        if (cmd.getItems() == null || cmd.getItems().isEmpty()) {
            throw new IllegalArgumentException("订单项不能为空");
        }
        // 核心：apply() 会发布事件，并触发同聚合内的 @EventSourcingHandler
        AggregateLifecycle.apply(new OrderCreatedEvent(
            cmd.getOrderId(),
            cmd.getUserId(),
            cmd.getTotalAmount(),
            cmd.getItems(),
            Instant.now()
        ));
    }

    // 事件处理器（用于重建状态）：@EventSourcingHandler
    @EventSourcingHandler
    public void on(OrderCreatedEvent event) {
        this.orderId = event.getOrderId();
        this.userId = event.getUserId();
        this.totalAmount = event.getTotalAmount();
        this.status = OrderStatus.CREATED;
    }

    // 另一个命令：支付
    @CommandHandler
    public void handle(PayOrderCommand cmd) {
        if (this.status != OrderStatus.CREATED) {
            throw new IllegalStateException("订单状态不允许支付");
        }
        AggregateLifecycle.apply(new OrderPaidEvent(
            orderId, cmd.getPaymentId(), cmd.getAmount(), Instant.now()
        ));
    }

    @EventSourcingHandler
    public void on(OrderPaidEvent event) {
        this.status = OrderStatus.PAID;
    }
}
```

### 4.3 命令总线与命令分发

Axon 提供了 CommandBus 来分发命令：

```java
// 通过 CommandGateway 更简单地分发
@Service
public class OrderApplicationService {
    private final CommandGateway commandGateway;

    public OrderApplicationService(CommandGateway commandGateway) {
        this.commandGateway = commandGateway;
    }

    public String createOrder(CreateOrderRequest request) {
        String orderId = UUID.randomUUID().toString();
        CreateOrderCommand cmd = new CreateOrderCommand(
            orderId,
            request.getUserId(),
            request.getTotalAmount(),
            request.getItems()
        );
        // 发送命令，返回 CompletableFuture
        commandGateway.send(cmd);
        return orderId;
    }
}
```

### 4.4 查询模型（Projection）

事件被存储后，我们需要构建**查询模型**——这个过程叫 Projection（投射）：

```java
// OrderView.java - JPA 读模型实体
@Entity
@Table(name = "order_view")
public class OrderView {
    @Id
    private String id;
    private String userId;
    private String status;
    private BigDecimal totalAmount;
    private Instant createdAt;
    private Instant paidAt;
    // getters/setters...
}

// OrderProjection.java - 事件投射器
@Component
public class OrderProjection {

    private final OrderViewRepository orderViewRepository;

    public OrderProjection(OrderViewRepository orderViewRepository) {
        this.orderViewRepository = orderViewRepository;
    }

    // 监听事件并更新读模型
    @EventHandler
    public void on(OrderCreatedEvent event) {
        OrderView view = new OrderView();
        view.setId(event.getOrderId());
        view.setUserId(event.getUserId());
        view.setStatus("CREATED");
        view.setTotalAmount(event.getTotalAmount());
        view.setCreatedAt(event.getCreatedAt());
        orderViewRepository.save(view);
    }

    @EventHandler
    public void on(OrderPaidEvent event) {
        orderViewRepository.findById(event.getOrderId()).ifPresent(view -> {
            view.setStatus("PAID");
            view.setPaidAt(event.getPaidAt());
            orderViewRepository.save(view);
        });
    }
}

// OrderQueryService.java
@Service
public class OrderQueryService {
    private final OrderViewRepository repository;

    public OrderView getOrder(String orderId) {
        return repository.findById(orderId)
            .orElseThrow(() -> new RuntimeException("订单不存在"));
    }

    public Page<OrderView> listOrders(String userId, Pageable pageable) {
        return repository.findByUserId(userId, pageable);
    }
}
```

### 4.5 生产配置：Event Store 与快照

生产环境需要配置 Axon 的 Event Store 存储后端：

```yaml
# application.yml
axon:
  axonserver:
    enabled: false  # 不使用 Axon Server，使用 JPA Event Store
  eventhandling:
    processors:
      order-group:
        mode: SUBSCRIBING  # 订阅模式，也可用 TRACKING（追踪模式，支持重放）
  snapshot:
    trigger:
      threshold: 1000  # 每 1000 个事件自动生成快照
```

**快照**是 ES 性能的关键——如果放 10 万个事件还没快照，每次重建聚合都要重放 10 万条记录。快照相当于"中间态的检查点"：

```xml
<!-- 需要额外依赖 -->
<dependency>
    <groupId>org.axonframework</groupId>
    <artifactId>axon-eventsourcing</artifactId>
</dependency>
```

快照的配置和策略：

```java
@Configuration
public class AxonConfig {

    @Bean
    public SnapshotTriggerDefinition orderSnapshotTrigger(
            Snapshotter snapshotter) {
        return new EventCountSnapshotTriggerDefinition(snapshotter, 500);
        // 每 500 个事件打一次快照
    }
}
```

## 五、CQRS + ES 的架构全景图

```
┌──────────────┐     CommandBus      ┌──────────────────┐
│  Client App  │ ──────────────────> │  CommandHandler   │
│  (前端/API)   │                     │  (Aggregate)      │
└──────┬───────┘                     └────────┬─────────┘
       │                                     │
       │  Query (REST)                       │ apply(event)
       ▼                                     ▼
┌──────────────┐                     ┌──────────────────┐
│ QueryService │                     │   Event Store     │
│  (Read DB)   │ ◄──── Projection ◄──│  (事件存储表)      │
└──────────────┘                     └──────────────────┘
                                            │
                                            │ 发布事件
                                            ▼
                                     ┌──────────────────┐
                                     │  Message Broker   │
                                     │  (Kafka/RabbitMQ) │
                                     └──────────────────┘
                                            │
                                            ▼
                                     ┌──────────────────┐
                                     │  其他微服务/Mail/ │
                                     │  Notification等   │
                                     └──────────────────┘
```

## 六、面试常见追问

### Q1：CQRS 和 Event Sourcing 必须一起用吗？

**不必**。CQRS 是读写分离的策略，Event Sourcing 是存储模式，两者可以独立使用。

| 组合 | 说明 |
|------|------|
| 传统 CRUD + CQRS | 最常见入门方式，读写用不同表/DB，写表存当前状态 |
| CQRS + ES | 最终形态，写模型只存事件，读模型从事件流投射 |
| ES 不用 CQRS | 可行但少见，一般需要配合快照减少重放开销 |

### Q2：Event Sourcing 中事件结构变更怎么办？

这是一个经典难题。常见的策略：

1. **向前兼容**：新字段加默认值，永不删除旧字段
2. **Upcaster**：Axon 提供 Upcaster 机制，在读取事件时"升级"老版本事件
3. **版本号标记**：每个事件带 `version` 字段，代码按版本号选择性反序列化

```java
// Axon Upcaster 示例：将 v1 的 OrderCreatedEvent 升级到 v2
public class OrderCreatedUpcaster extends SingleEventUpcaster {

    @Override
    protected boolean canUpcast(IntermediateEventRepresentation intermediateRepresentation) {
        return intermediateRepresentation.getType()
            .getName().equals("com.example.event.OrderCreatedEvent");
    }

    @Override
    protected IntermediateEventRepresentation doUpcast(
            IntermediateEventRepresentation intermediateRepresentation) {
        return intermediateRepresentation.upcastPayload(
            new JacksonRevision("2.0"),
            Map.class,
            document -> {
                Map<String, Object> data = new HashMap<>(document);
                // v1 没有 region 字段，v2 加上
                data.putIfAbsent("region", "default");
                return data;
            }
        );
    }
}
```

### Q3：和 Event-Driven Architecture（事件驱动架构）有什么区别？

- **EDA** 是一种**通信模式**：组件之间通过事件消息进行异步通信
- **ES** 是一种**持久化模式**：用事件序列替代状态存储
- **CQRS** 是一种**架构模式**：分离读写职责

它们常常一起使用，但概念上是正交的。

### Q4：Axon 和 Spring Cloud 集成需要注意什么？

- Axon 4.x 完美支持 Spring Boot 3.x
- CommandBus 默认内存实现，生产建议用分布式 CommandBus（Kafka / RabbitMQ）
- 跨微服务 Saga 用 Axon Saga 管理，配合 `@Saga` 注解
- 注意事件序列化：默认 XStream（不够安全），生产建议改为 Jackson

```yaml
axon:
  serializer:
    events:
      jackson:
        enabled: true
    general:
      jackson:
        enabled: true
    messages:
      jackson:
        enabled: true
```

## 七、总结

| 维度 | 传统 CRUD | CQRS + ES |
|------|-----------|-----------|
| 模型 | 单模型 | 读写分离，各司其职 |
| 存储 | 当前状态 | 事件流 + 投射 |
| 扩展 | 读写耦合 | 可独立扩读写端 |
| 审计 | 日志 | 原生审计，不可篡改 |
| 复杂度 | 低 | 中高 |
| 适用场景 | 简单的CRUD应用 | 复杂业务、金融、协同、需要审计的高并发系统 |

CQRS + Event Sourcing 不是银弹，但在业务逻辑足够复杂、需要完整审计历史的系统中，这套组合拳能让你从"代码越改越乱"走向"架构优雅可演进"。

**推荐入门路径**：先从表级 CQRS 开始（同库读写分离）→ 引入消息队列做异步投射 → 再逐步过渡到 Event Sourcing。一步到位风险太大，循序渐进才是正道。
