---
title: 【架构实战】整洁架构与六边形架构深度实践：端口适配器、依赖倒置与 Spring Boot 分层重构
date: 2026-09-13 08:00:00
tags:
  - Java
  - 架构设计
  - 整洁架构
  - 六边形架构
  - DDD
categories:
  - Java
  - 架构设计
author: 东哥
---

# 【架构实战】整洁架构与六边形架构深度实践：端口适配器、依赖倒置与 Spring Boot 分层重构

## 面试官：你们项目怎么分层的？

「Controller → Service → Mapper，三层架构。」

「那你的 Service 里有没有直接 `@Autowired` 一个 FeignClient？有没有直接注入 `RedisTemplate`？有没有直接 `new` 一个 `RestTemplate`？」

「……有。」

「那你的业务逻辑怎么单测？换个数据库要改几层？**这不叫分层，这叫按文件类型排了下目录。**」

这个追问点出了一个非常普遍的问题：**大部分 Java 项目的「三层架构」只做到了「目录分层」，没有做到「依赖分层」。**

这篇文章讲清楚两件事：

1. **整洁架构（Clean Architecture）与六边形架构（Hexagonal / Ports & Adapters）的核心到底是什么**（不是画几个同心圆）。
2. **怎么在一个真实的 Spring Boot 项目里落地**，包括包结构、代码、测试、以及**如何从三层架构渐进式重构过去**。

---

## 一、先破一个错觉：三层架构为什么会烂

### 1.1 典型的三层架构代码

```java
// Controller
@RestController
@RequestMapping("/orders")
public class OrderController {
    @Autowired private OrderService orderService;

    @PostMapping
    public Result<Long> create(@RequestBody CreateOrderRequest req) {
        return Result.ok(orderService.create(req));
    }
}

// Service —— 问题全在这里
@Service
public class OrderService {
    @Autowired private OrderMapper orderMapper;
    @Autowired private UserClient userClient;         // 跨服务调用
    @Autowired private RedisTemplate<String, Object> redis;  // 缓存
    @Autowired private InventoryFeignClient inventory; // 库存服务
    @Autowired private KafkaTemplate<String, String> kafka;  // 发消息

    public Long create(CreateOrderRequest req) {
        UserDTO user = userClient.getUser(req.getUserId());
        if (user == null || !user.isActive()) {
            throw new BizException("用户不可用");
        }
        // 库存扣减（远程）
        inventory.deduct(req.getSkuId(), req.getQuantity());
        Order order = new Order();
        order.setOrderNo(generateOrderNo());
        order.setUserId(req.getUserId());
        order.setAmount(calcAmount(req, user));
        order.setStatus(OrderStatus.CREATED);
        orderMapper.insert(order);
        redis.opsForValue().set("order:" + order.getId(), order, Duration.ofHours(1));
        kafka.send("order-created", JSON.toJSONString(order));
        return order.getId();
    }
}
```

### 1.2 这段代码的四个致命问题

**问题一：业务逻辑无法单测。**

想测「用户不可用时不创建订单」，就必须 mock 掉 `UserClient`、`InventoryFeignClient`、`OrderMapper`、`RedisTemplate`、`KafkaTemplate`。测试代码比业务代码还长，而且**一旦换了 Feign 实现或换掉 Redis，测试全废**。

**问题二：业务规则散落在技术细节之间。**

「用户不可用不能下单」和「Kafka 要发哪条消息」在同一个方法里。半年后你无法回答「我们的下单规则总共有几条」。

**问题三：依赖方向反了。**

```
Controller → Service → Mapper/Redis/Kafka/Feign
                ↑
        （业务逻辑依赖具体技术实现）
```

**业务规则本该是最稳定的东西，却依赖了最容易变的东西。** 这就是整洁架构要解决的核心命题。

**问题四：换技术要改业务代码。**

从 Redis 换到 Caffeine、从 Feign 换到 Dubbo、从 MyBatis 换到 JPA——**都要改 `OrderService`**。而 `OrderService` 应该对这些都是无感的。

---

## 二、核心原理：依赖倒置与端口适配器

### 2.1 六边形架构的主语

六边形架构（Alistair Cockburn 提出），也叫 **Ports & Adapters（端口与适配器）**，结构只有三个角色：

```
                    ┌──────────────────────────┐
       入站适配器    │                          │   出站适配器
   ┌────────────┐  │      领域模型 / 业务逻辑   │  ┌────────────┐
   │ REST 控制器 │──▶│                          │─▶│ JDBC 仓储   │
   ├────────────┤  │   Order / Money / 规则    │  ├────────────┤
   │ 消息消费者  │──▶│                          │─▶│ HTTP 客户端 │
   ├────────────┤  │                          │  ├────────────┤
   │ 定时任务    │──▶│                          │─▶│ 消息发送者  │
   ├────────────┤  │                          │  ├────────────┤
   │ CLI / gRPC │──▶│                          │─▶│ 缓存实现    │
   └────────────┘  │                          │  └────────────┘
                    └──────────────────────────┘
                        ▲                ▲
                    入站端口            出站端口
```

| 角色 | 含义 | Java 中的形态 |
| --- | --- | --- |
| **领域（Domain）** | 业务规则与状态，**零技术依赖** | 实体、值对象、领域服务 |
| **入站端口（Inbound Port）** | 领域「能提供什么能力」 | `interface OrderUseCase` |
| **出站端口（Outbound Port）** | 领域「需要外界提供什么」 | `interface OrderRepository` |
| **入站适配器** | 把外部请求翻译成领域调用 | `OrderController`、`OrderMessageListener` |
| **出站适配器** | 把领域需求翻译成技术调用 | `OrderJpaAdapter`、`InventoryHttpAdapter` |

**六边形不是「有六个边」**，而是说「有多少种外部交互方式都能接进来，形状随意」。核心是**内外分离**。

### 2.2 与整洁架构的关系

Clean Architecture（Robert C. Martin）是同一思想的另一种表述，多了几层同心圆：

```
        ┌─── Frameworks & Drivers（Spring、MyBatis、Redis）
        │  ┌─── Interface Adapters（Controller、Presenter、Gateway 实现）
        │  │  ┌─── Application / Use Cases（应用服务、用例编排）
        │  │  │  ┌─── Entities / Domain（企业级业务规则）
        └──│──│──│
           └──│──│
              └──│
                 └─── 越内层越稳定、越不依赖框架
```

**两者本质相同，可以等价看待**：

| 整洁架构 | 六边形架构 | 本项目包名建议 |
| --- | --- | --- |
| Entities | Domain Model | `domain` |
| Use Cases | Application / Ports (in) | `application` |
| Interface Adapters | Adapters (in/out) | `adapter` |
| Frameworks & Drivers | 具体技术实现 | `infrastructure` / `adapter.out` |

**唯一的黄金规则（The Dependency Rule）**：

> **依赖只能由外向内。内层代码不能 import 外层代码，内层不能知道任何框架的存在。**

### 2.3 依赖倒置：怎么让内层「调用」外层

这是最容易绕晕的点。领域层需要「保存订单」，但保存是 JDBC 的事，而领域层不能依赖 JDBC。

解法就是 **DIP（依赖倒置原则）**：

```java
// 领域层定义「我需要什么」（出站端口）—— 注意：接口和领域实体在同一个包里
package com.demo.order.domain.port;

public interface OrderRepository {
    Order save(Order order);
    Optional<Order> findById(OrderId id);
    Optional<Order> findByNo(String orderNo);
}

// 基础设施层实现「怎么做」（出站适配器）
package com.demo.order.adapter.out.persistence;

@Repository
@RequiredArgsConstructor
public class OrderJpaAdapter implements OrderRepository {
    private final OrderJpaMapper jpaMapper;

    @Override
    public Order save(Order order) {
        OrderPO po = OrderConverter.toPO(order);
        jpaMapper.insert(po);
        return OrderConverter.toDomain(po);
    }
    // ...
}
```

**关键洞察**：接口的定义权在**内层**，实现在**外层**。所以「外层依赖内层」——依赖方向被倒置了，但方向仍然统一指向内层。

```
❌ 领域 → 依赖 → MyBatis           （领域依赖技术，错）
✅ 领域 ← 实现 ← MyBatis Adapter   （技术依赖领域定义的接口，对）
```

---

## 三、Spring Boot 项目落地：完整包结构

### 3.1 按限界上下文分包（推荐）

**不要按技术层分包**（controller/service/mapper），那样每个业务都散落在各处。**按业务能力分包**：

```
src/main/java/com/demo/
├── order/                              # 限界上下文：订单
│   ├── domain/                         # 领域层（零依赖）
│   │   ├── model/
│   │   │   ├── Order.java              # 聚合根
│   │   │   ├── OrderItem.java          # 实体
│   │   │   ├── OrderId.java            # 值对象
│   │   │   ├── Money.java              # 值对象
│   │   │   ├── OrderStatus.java        # 枚举（含状态迁移规则）
│   │   │   └── OrderNo.java
│   │   ├── event/
│   │   │   ├── OrderCreatedEvent.java
│   │   │   └── OrderCancelledEvent.java
│   │   ├── service/
│   │   │   └── OrderPricingService.java   # 领域服务（纯计算）
│   │   └── port/
│   │       ├── in/                     # 入站端口（用例接口）
│   │       │   ├── CreateOrderUseCase.java
│   │       │   └── CancelOrderUseCase.java
│   │       └── out/                    # 出站端口
│   │           ├── OrderRepository.java
│   │           ├── InventoryPort.java
│   │           └── OrderEventPublisher.java
│   ├── application/                    # 应用层（用例编排）
│   │   ├── OrderApplicationService.java
│   │   └── command/
│   │       ├── CreateOrderCommand.java
│   │       └── CancelOrderCommand.java
│   ├── adapter/
│   │   ├── in/                         # 入站适配器
│   │   │   ├── web/
│   │   │   │   ├── OrderController.java
│   │   │   │   ├── OrderConverter.java
│   │   │   │   └── dto/
│   │   │   │       ├── CreateOrderRequest.java
│   │   │   │       └── OrderResponse.java
│   │   │   └── mq/
│   │   │       └── OrderTimeoutListener.java
│   │   └── out/                        # 出站适配器
│   │       ├── persistence/
│   │       │   ├── OrderJpaAdapter.java
│   │       │   ├── OrderJpaMapper.java
│   │       │   ├── po/OrderPO.java
│   │       │   └── OrderConverter.java
│   │       ├── client/
│   │       │   ├── InventoryHttpAdapter.java
│   │       │   └── InventoryFeignClient.java
│   │       └── mq/
│   │           └── KafkaOrderEventPublisher.java
│   └── config/                         # 该上下文的 Spring 配置
│       └── OrderBeanConfiguration.java
├── inventory/                          # 另一个上下文，结构同上
└── shared/                             # 共享内核（谨慎使用）
    ├── domain/  (Money、DomainEvent 等通用值对象)
    └── error/   (BizException、ErrorCode)
```

**用 ArchUnit 把依赖规则写成测试**（这样架构不会随时间腐化）：

```java
@AnalyzeClasses(packages = "com.demo", importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureTest {

    @ArchTest
    static final ArchRule domain_should_not_depend_on_anything_outer = noClasses()
            .that().resideInAPackage("..domain..")
            .should().dependOnClassesThat()
            .resideInAnyPackage(
                    "..application..", "..adapter..", "..config..",
                    "org.springframework..", "org.apache.ibatis..",
                    "com.baomidou..", "redis.clients..", "javax.persistence..",
                    "jakarta.persistence..", "com.fasterxml.jackson..")
            .because("领域层必须零技术依赖，这是整洁架构的底线");

    @ArchTest
    static final ArchRule application_should_not_depend_on_adapter = noClasses()
            .that().resideInAPackage("..application..")
            .should().dependOnClassesThat().resideInAPackage("..adapter..")
            .because("应用层只能通过端口（interface）与外界交互");

    @ArchTest
    static final ArchRule domain_should_not_use_spring_annotations = noClasses()
            .that().resideInAPackage("..domain..")
            .should().beAnnotatedWith("org.springframework.stereotype.Component")
            .orShould().beAnnotatedWith("org.springframework.beans.factory.annotation.Autowired")
            .because("领域对象由业务语义驱动，不该被框架注解污染");

    @ArchTest
    static final ArchRule adapters_should_not_depend_on_each_other = noClasses()
            .that().resideInAPackage("..adapter.in..")
            .should().dependOnClassesThat().resideInAPackage("..adapter.out..");
}
```

**这就是「可执行的架构」**——违反规则时编译期（测试期）直接红。比写在 Confluence 上的架构文档强一万倍。

### 3.2 领域模型：把规则写进实体

整洁架构最大的收益，是把业务规则从 Service 里挖出来，放进**有状态的领域对象**。

```java
package com.demo.order.domain.model;

/**
 * 聚合根。注意：
 * 1. 没有 @Entity / @Table / Lombok @Data（避免 equals/hashCode 被滥用）
 * 2. 没有 setter —— 只通过业务方法改变状态
 * 3. 构造函数私有，通过工厂方法创建
 */
public class Order {

    private final OrderId id;
    private final OrderNo orderNo;
    private final UserId userId;
    private final List<OrderItem> items;
    private final Money totalAmount;
    private OrderStatus status;
    private final Instant createdAt;

    private Order(OrderId id, OrderNo orderNo, UserId userId,
                  List<OrderItem> items, Money totalAmount, Instant createdAt) {
        this.id = id;
        this.orderNo = orderNo;
        this.userId = userId;
        this.items = List.copyOf(items);   // 不可变集合，防止外部篡改
        this.totalAmount = totalAmount;
        this.status = OrderStatus.CREATED;
        this.createdAt = createdAt;
    }

    /** 工厂方法：创建即保证所有不变量 */
    public static Order create(UserId userId, List<OrderItem> items, Money discount) {
        if (items == null || items.isEmpty()) {
            throw new DomainException("订单至少包含一个商品");
        }
        Money total = items.stream()
                .map(OrderItem::subtotal)
                .reduce(Money.ZERO, Money::add);

        if (discount.isGreaterThan(total)) {
            throw new DomainException("折扣金额不能超过订单总额");
        }
        Money payable = total.subtract(discount);

        if (payable.isLessThan(Money.ofMinor(1))) {
            throw new DomainException("应付金额必须大于 0");
        }
        return new Order(OrderId.generate(), OrderNo.generate(),
                userId, items, payable, Instant.now());
    }

    /** 领域行为：取消订单，内部校验状态迁移合法性 */
    public void cancel(String reason) {
        if (!status.canTransferTo(OrderStatus.CANCELLED)) {
            throw new DomainException(
                    "订单状态 " + status + " 不允许取消");
        }
        if (reason == null || reason.isBlank()) {
            throw new DomainException("取消原因不能为空");
        }
        this.status = OrderStatus.CANCELLED;
    }

    public void markPaid(String paymentNo) {
        if (!status.canTransferTo(OrderStatus.PAID)) {
            throw new DomainException("订单状态 " + status + " 不允许支付");
        }
        this.status = OrderStatus.PAID;
    }

    public Money getTotalAmount() { return totalAmount; }
    public OrderStatus getStatus() { return status; }
    public OrderId getId() { return id; }
    public OrderNo getOrderNo() { return orderNo; }
    public UserId getUserId() { return userId; }
    public List<OrderItem> getItems() { return items; }
}
```

**注意这里做了几件「反直觉」但对的事**：

1. **没有 setter**。状态只能通过 `cancel()` / `markPaid()` 改变，且内部校验。**业务规则不可能被绕过**。
2. **不变量在构造函数/工厂中检查**（金额 > 0、items 非空）。**不存在「非法的 Order 对象」**。
3. **不依赖任何框架**。可以直接 `new Order.create(...)` 在单测里跑，零 mock。
4. **状态迁移用枚举承载**：

```java
public enum OrderStatus {
    CREATED, PAID, SHIPPED, COMPLETED, CANCELLED;

    private static final Map<OrderStatus, Set<OrderStatus>> TRANSITIONS = Map.of(
        CREATED,   EnumSet.of(PAID, CANCELLED),
        PAID,      EnumSet.of(SHIPPED, CANCELLED),
        SHIPPED,   EnumSet.of(COMPLETED),
        COMPLETED, EnumSet.noneOf(OrderStatus.class),
        CANCELLED, EnumSet.noneOf(OrderStatus.class)
    );

    public boolean canTransferTo(OrderStatus target) {
        return TRANSITIONS.getOrDefault(this, Set.of()).contains(target);
    }
}
```

### 3.3 值对象 Money：杜绝浮点金额

```java
package com.demo.order.domain.model;

import java.math.BigDecimal;
import java.util.Objects;

/** 值对象：不可变、无标识、通过值相等 */
public final class Money {

    public static final Money ZERO = new Money(BigDecimal.ZERO);

    private final BigDecimal amount;   // 内部精度固定为 2

    private Money(BigDecimal amount) {
        this.amount = amount.setScale(2, java.math.RoundingMode.HALF_UP);
    }

    public static Money of(String value)   { return new Money(new BigDecimal(value)); }
    public static Money ofMinor(long cents) { return new Money(BigDecimal.valueOf(cents, 2)); }

    public Money add(Money other) {
        return new Money(this.amount.add(other.amount));
    }

    public Money subtract(Money other) {
        return new Money(this.amount.subtract(other.amount));
    }

    public Money multiply(BigDecimal factor) {
        return new Money(this.amount.multiply(factor));
    }

    public boolean isGreaterThan(Money other) { return amount.compareTo(other.amount) > 0; }
    public boolean isLessThan(Money other)    { return amount.compareTo(other.amount) < 0; }

    public long toMinor() { return amount.movePointRight(2).longValueExact(); }

    @Override public boolean equals(Object o) {
        return o instanceof Money m && amount.compareTo(m.amount) == 0;
    }
    @Override public int hashCode() { return amount.stripTrailingZeros().hashCode(); }
    @Override public String toString() { return amount.toPlainString(); }
}
```

**为什么要自己包一层而不是直接用 `BigDecimal`？**

- **语义明确**：`Money` 出现的地方就知道是金额。
- **禁止了危险操作**：没有 `divide`（金额除法的舍入规则必须业务决定），避免有人随手写 `a.divide(b)`。
- **统一精度**：所有金额都是 2 位小数，不会再出现 `1.0` 和 `1.00` 比较不相等的问题。

### 3.4 应用层：只做编排，不做业务决策

```java
package com.demo.order.application;

@Service
@RequiredArgsConstructor
public class OrderApplicationService implements CreateOrderUseCase, CancelOrderUseCase {

    private final OrderRepository orderRepository;      // 出站端口
    private final InventoryPort inventoryPort;          // 出站端口
    private final OrderEventPublisher eventPublisher;   // 出站端口
    private final OrderPricingService pricingService;   // 领域服务

    @Override
    @Transactional
    public OrderId create(CreateOrderCommand cmd) {
        // 1. 准备数据（调用外部，属于「编排」）
        List<OrderItem> items = cmd.items().stream()
                .map(i -> OrderItem.of(i.skuId(), i.quantity(), i.unitPrice()))
                .toList();

        // 2. 预占库存（出站端口调用）
        inventoryPort.reserve(cmd.items());

        // 3. 计算折扣（领域服务，纯逻辑）
        Money discount = pricingService.calculateDiscount(cmd.userId(), items);

        // 4. 创建聚合根（业务规则在领域层，这里只是调用）
        Order order = Order.create(cmd.userId(), items, discount);

        // 5. 持久化
        orderRepository.save(order);

        // 6. 发布领域事件
        eventPublisher.publish(new OrderCreatedEvent(order.getId(), order.getOrderNo(),
                order.getUserId(), order.getTotalAmount()));

        return order.getId();
    }

    @Override
    @Transactional
    public void cancel(CancelOrderCommand cmd) {
        Order order = orderRepository.findById(cmd.orderId())
                .orElseThrow(() -> new NotFoundException("订单不存在: " + cmd.orderId()));

        order.cancel(cmd.reason());                 // 领域规则在这里生效
        orderRepository.save(order);
        inventoryPort.release(cmd.orderId());       // 释放库存
    }
}
```

**应用层的三条纪律**：

1. **不写 if/else 业务判断**——只做「取数据 → 调领域方法 → 存数据 → 发事件」的流水线。
2. **只依赖端口接口**——`import` 里不应出现 `FeignClient`、`RedisTemplate`、`JdbcTemplate`。
3. **事务边界在这层**——领域层不关心事务（那是技术关注点）。这也解决了「领域层不能用 `@Transactional`（框架依赖）」的矛盾。

### 3.5 出站适配器：把技术细节关在门外

```java
package com.demo.order.adapter.out.client;

@Component
@RequiredArgsConstructor
public class InventoryHttpAdapter implements InventoryPort {

    private final InventoryFeignClient feignClient;   // 技术细节只在这里出现

    @Override
    public void reserve(List<OrderItemCommand> items) {
        List<DeductItem> req = items.stream()
                .map(i -> new DeductItem(i.skuId(), i.quantity()))
                .toList();
        ApiResponse<Boolean> resp = feignClient.deduct(new DeductRequest(req));
        if (resp == null || !resp.isSuccess()) {
            // 把技术异常翻译成领域语义的异常
            throw new InventoryInsufficientException("库存不足: " + items);
        }
    }

    @Override
    public void release(OrderId orderId) {
        feignClient.release(orderId.value());
    }
}
```

```java
package com.demo.order.adapter.out.persistence;

@Repository
@RequiredArgsConstructor
public class OrderJpaAdapter implements OrderRepository {

    private final OrderJpaMapper mapper;

    @Override
    public Order save(Order order) {
        OrderPO po = OrderConverter.toPO(order);
        OrderPO existing = mapper.selectById(po.getId());
        if (existing == null) {
            mapper.insert(po);
        } else {
            mapper.updateById(po);
        }
        return order;
    }

    @Override
    public Optional<Order> findById(OrderId id) {
        return Optional.ofNullable(mapper.selectById(id.value()))
                .map(OrderConverter::toDomain);
    }
    // ...
}
```

**适配器的职责只有一件：翻译。** 领域模型 ↔ 持久化对象（PO）、领域模型 ↔ DTO、领域异常 ↔ HTTP 状态码。

---

## 四、收益：用测试说话

### 4.1 领域逻辑测试：零 mock，毫秒级

```java
class OrderTest {

    @Test
    void 订单总额不能为0() {
        DomainException ex = assertThrows(DomainException.class, () ->
                Order.create(UserId.of(1L),
                        List.of(OrderItem.of(1L, 1, Money.of("0.00"))),
                        Money.ZERO));
        assertThat(ex.getMessage()).contains("应付金额必须大于 0");
    }

    @Test
    void 折扣不能超过总额() {
        DomainException ex = assertThrows(DomainException.class, () ->
                Order.create(UserId.of(1L),
                        List.of(OrderItem.of(1L, 1, Money.of("99.00"))),
                        Money.of("100.00")));
        assertThat(ex.getMessage()).contains("折扣金额不能超过订单总额");
    }

    @Test
    void 已取消订单不能再次取消() {
        Order order = Order.create(UserId.of(1L),
                List.of(OrderItem.of(1L, 1, Money.of("99.00"))), Money.ZERO);
        order.cancel("用户主动取消");
        assertThrows(DomainException.class, () -> order.cancel("再取消一次"));
    }

    @Test
    void 非法状态迁移被拒绝() {
        Order order = Order.create(UserId.of(1L),
                List.of(OrderItem.of(1L, 1, Money.of("99.00"))), Money.ZERO);
        order.markPaid("PAY-001");
        // PAID -> SHIPPED 合法
        assertThat(OrderStatus.PAID.canTransferTo(OrderStatus.SHIPPED)).isTrue();
        // PAID -> COMPLETED 非法（必须先发货）
        assertThat(OrderStatus.PAID.canTransferTo(OrderStatus.COMPLETED)).isFalse();
    }
}
```

**注意：没有任何 `@SpringBootTest`、没有 `@Mock`、没有 `@ExtendWith`。** 一个测试类跑完不到 50ms。**这才是「业务逻辑可测」的样子。**

### 4.2 三种测试的分工

| 测试类型 | 测什么 | 依赖 | 速度 | 占比 |
| --- | --- | --- | --- | --- |
| **领域单元测试** | 业务规则、不变量、状态迁移 | **零依赖** | 毫秒 | 60% |
| **应用层测试** | 用例编排、端口调用顺序 | Mock 出站端口 | 毫秒 | 25% |
| **适配器集成测试** | SQL 正确性、序列化、协议 | Testcontainers（真实 MySQL/Redis） | 秒 | 15% |

```java
// 应用层测试：只 mock 端口（interface），不 mock 技术
@ExtendWith(MockitoExtension.class)
class OrderApplicationServiceTest {

    @Mock private OrderRepository orderRepository;
    @Mock private InventoryPort inventoryPort;
    @Mock private OrderEventPublisher eventPublisher;
    @Mock private OrderPricingService pricingService;
    @InjectMocks private OrderApplicationService service;

    @Test
    void 创建订单_应预占库存并发布事件() {
        given(pricingService.calculateDiscount(any(), any())).willReturn(Money.of("10.00"));

        var cmd = new CreateOrderCommand(UserId.of(1L),
                List.of(new OrderItemCommand(100L, 2, Money.of("50.00"))));

        OrderId id = service.create(cmd);

        assertThat(id).isNotNull();
        verify(inventoryPort).reserve(any());                 // 验证编排顺序
        verify(orderRepository).save(any());
        verify(eventPublisher).publish(any(OrderCreatedEvent.class));
    }
}
```

**关键：mock 的是 `InventoryPort`（自己定义的接口），不是 `InventoryFeignClient`。** 换了 RPC 框架，测试一行不用改。

### 4.3 换技术的成本对比

| 变更 | 三层架构 | 整洁架构 |
| --- | --- | --- |
| Redis → Caffeine | 改 Service + 单测 | 换适配器实现，**领域/应用层零改动** |
| Feign → Dubbo | 改 Service + 单测 | 换适配器实现 |
| MyBatis → JPA | 改 Service + 单测 | 换适配器 + Converter |
| 加一个 gRPC 入口 | 新写 Controller 调 Service | 新写入站适配器，**复用同一个 UseCase** |
| 同一用例给 MQ 调用 | Service 里加判断 | 新增 Listener 适配器 |

---

## 五、渐进式重构：别一次推倒重来

### 5.1 五步走

**第 1 步：只做「测试友好」的最小改造（1~2 天）**

不改包结构，只在 `domain` 包下建**纯 POJO + 领域方法**，把 Service 里的计算逻辑挪进去：

```java
// 改造前：Service 里散落计算
public Long create(CreateOrderRequest req) {
    BigDecimal total = BigDecimal.ZERO;
    for (Item i : req.getItems()) {
        total = total.add(i.getPrice().multiply(BigDecimal.valueOf(i.getQty())));
    }
    BigDecimal discount = user.getVip() ? total.multiply(new BigDecimal("0.9")) : total;
    // ...
}

// 改造后：抽到领域
Money total = OrderPricingService.calculate(items, user);
```

**第 2 步：引入端口接口（3~5 天）**

把 Service 直接注入的 `OrderMapper` / `RedisTemplate` / `FeignClient` 替换成**自己定义的接口**，先让老实现包装成适配器：

```java
// 出站端口
public interface OrderRepository { ... }

// 适配器：包装原有 Mapper，先写薄薄一层
@Repository
@RequiredArgsConstructor
public class OrderJpaAdapter implements OrderRepository {
    private final OrderMapper mapper;   // 原来的 Mapper 原封不动
    // 方法里直接委托
}
```

此时**应用层已经不 import 任何技术类**了。

**第 3 步：用 ArchUnit 加门禁（1 天）**

把 3.1 里的架构测试加进 CI。**从此刻起架构不再腐化**——这是最重要的一步，因为它把「约定」变成了「编译期约束」。

**第 4 步：搬包结构（1~2 天，纯 IDE 重构）**

按业务上下文（`order`/`inventory`）重组，每个上下文内分 `domain/application/adapter`。用 IDE 的 Move + 微调 import，**不动任何逻辑**。

**第 5 步：逐个上下文深挖领域模型（持续）**

每次需求改动哪个上下文，就把那个上下文的实体从「贫血 POJO + Service 事务脚本」改成「充血模型 + 领域方法」。**借助变更驱动，而不是专门排期重构。**

### 5.2 三个必须避开的坑

**坑一：过度设计。**

不是每个项目都需要六边形。判断标准：

| 场景 | 建议 |
| --- | --- |
| CRUD 为主的内部管理后台 | **不要用**。三层 + 简单 Service 足够 |
| 业务规则复杂、长期演进的核心域 | **一定要用** |
| 需要多种入口（REST + MQ + 定时 + gRPC） | 强烈建议 |
| 需要换技术栈或长期保留（5 年+） | 建议 |
| 短期交付的 MVP | 不要用，会拖慢交付 |

**坑二：领域层偷偷依赖框架。**

最常见的偷渡方式：

```java
// ❌ 用 Lombok 的 @Data —— 它生成 equals/hashCode/setter，破坏领域不变量
@Data
public class Order { ... }

// ❌ 用 Jackson 注解 —— 领域层背上了序列化依赖
public class Order {
    @JsonProperty("order_no")
    private String orderNo;
}

// ❌ 用 jakarta.validation —— 校验规则跑到领域外
public class Order {
    @NotNull @Min(1)
    private Integer quantity;
}
```

**对策**：用 ArchUnit 的 `noClasses().that().resideInAPackage("..domain..").should().dependOnClassesThat().resideInAnyPackage("org.springframework..","com.fasterxml..","jakarta.validation..")` 一条规则全部拦住。校验用**自定义异常 + 领域方法**，不在实体上挂注解。

**坑三：Converter 遍地开花、逻辑泄漏。**

```java
// ❌ Converter 里写业务规则
public static Order toDomain(OrderPO po) {
    Order o = new Order();
    o.setStatus(po.getStatus());
    if (po.getAmount().compareTo(BigDecimal.ZERO) == 0) {   // 业务规则跑到转换器了
        o.setStatus(OrderStatus.CANCELLED);
    }
    return o;
}
```

**Converter 只能做「字段搬运 + 类型映射」**，任何判断都该回到领域层。这条可以用 Code Review + 覆盖率（Converter 覆盖率要求低但评审严格）来守。

### 5.3 包结构与 Maven 模块的关系

**不需要为了整洁架构拆 Maven 模块。** 很多团队一开始就拆 `xxx-domain`、`xxx-application`、`xxx-infrastructure` 三个模块，结果：

- 编译变慢。
- 循环依赖反而更难发现（因为都要写 pom）。
- 重构成本高。

**推荐做法：先在同模块内用包分层 + ArchUnit 守规则。** 等某个上下文真的需要独立部署或被多个应用复用，再抽成独立模块（此时拆的边界也更准确）。

---

## 六、面试高频追问

**Q1：整洁架构和 DDD 是一回事吗？**

不是。**整洁架构是「代码组织与依赖方向」的规范，DDD 是「如何建模业务」的方法论。** 二者互补：

- DDD 告诉你「什么是聚合根、值对象、限界上下文、领域事件」。
- 整洁架构告诉你「这些代码放在哪一层、依赖指向哪里」。

你可以只用整洁架构（贫血模型也行），也可以只用 DDD 的战术模式（但代码依赖混乱）。**组合使用收益最大。**

**Q2：Controller 算不算适配器？为什么 Controller 里不能直接调 Repository？**

Controller 是**入站适配器**。它不能直接调 Repository，因为：

- 违反依赖规则（适配器不该互相调用，入站适配器不能直连出站适配器）。
- 会**绕过应用层的事务边界**（`@Transactional` 在应用层）。
- 会**绕过领域规则**（校验、状态迁移都在领域方法里）。

**正确路径永远只有一条**：`入站适配器 → 入站端口(UseCase) → 应用层 → 领域 + 出站端口 → 出站适配器`。

**Q3：领域事件怎么发？事务一致性怎么保证？**

三种方案，按可靠性递增：

```java
// 方案一（最简单，可能不一致）：应用层直接调 Publisher
eventPublisher.publish(event);   // 事务提交前发出？→ 事务回滚了但消息已发（脏消息）

// 方案二（Spring 事件 + 事务同步，推荐）：事务提交后才真正发
@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
public void onOrderCreated(OrderCreatedEvent event) {
    kafkaTemplate.send("order-created", JSON.toJSONString(event));
}

// 方案三（最高可靠）：本地消息表 + 定时补偿（或 Canal 抓 binlog）
// 业务数据与消息记录在同一个事务里落库，再由独立线程发送并更新状态
```

**方案二的关键实现**：领域层发布 Spring 事件（但领域层不能依赖 Spring……）。解法是**领域层定义自己的 `DomainEventPublisher` 端口，适配器用 Spring 的 `ApplicationEventPublisher` 实现**：

```java
// adapter/out/event/SpringDomainEventPublisher.java
@Component
@RequiredArgsConstructor
public class SpringDomainEventPublisher implements OrderEventPublisher {
    private final ApplicationEventPublisher delegate;

    @Override
    public void publish(OrderCreatedEvent event) { delegate.publishEvent(event); }
}
```

**Q4：如果 ORM 的实体（JPA `@Entity`）和领域模型是两套，转换开销大怎么办？**

这是个真实取舍，三条路：

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| **两套模型 + Converter**（推荐用于核心域） | 领域纯净、可独立演进 | 有转换代码与少量性能开销 |
| **一套模型（领域对象上加 JPA 注解）** | 无转换 | 领域被 JPA 污染（延迟加载、代理对象、equals 陷阱） |
| **用 jOOQ / MyBatis 手写映射** | 领域纯净 + 无 ORM 代理问题 | 需手写 SQL |

**经验法则**：**核心域（订单、支付、计费）用两套模型**，因为业务规则复杂、值得保护；**边缘域（配置、字典、日志）用一套模型**，因为基本是 CRUD。转换开销在绝大多数业务系统里**远小于收益**（一次对象映射通常 < 1μs，相比一次 DB 查询的 ms 级可以忽略）。

**Q5：六边形架构的「六边形」到底有几个边？**

**没有固定数量。** 「六边形」只是画图时比较美观（比正方形更容易容纳不同数量的端口）。核心概念只有两个：**端口（Port，接口）** 和 **适配器（Adapter，实现）**。如果一个系统只有一个 REST 入口和一个数据库出口，画成「哑铃形」也完全可以。

---

## 七、总结

```
整洁架构 / 六边形架构
├── 黄金规则：依赖只能由外向内；内层不知道框架的存在
├── 四种角色
│   ├── Domain（实体/值对象/领域服务）—— 零依赖，规则的家
│   ├── Inbound Port（UseCase 接口）—— 对外提供什么能力
│   ├── Outbound Port（Repository/Gateway 接口）—— 需要外界提供什么
│   └── Adapter（Web/MQ/DB/RPC 实现）—— 只做翻译
├── 落地要点
│   ├── 按业务上下文分包（不是按 controller/service/mapper）
│   ├── 端口接口定义在内层，实现写在外层（DIP）
│   ├── 领域对象无 setter、无框架注解、不变量在工厂中校验
│   ├── 金额用值对象 Money，禁止 double/float
│   ├── 事务边界在应用层，不在领域层
│   └── ArchUnit 把架构规则写成测试 → 架构不再腐化
├── 收益
│   ├── 领域逻辑单测零 mock，毫秒级
│   ├── mock 端口而非技术类 → 换技术不改测试
│   └── 多种入口复用同一 UseCase
└── 禁忌
    ├── 过度设计（CRUD 后台不需要）
    ├── 领域层偷偷 import Spring/Jackson/JPA 注解
    └── Converter 里写业务判断
```

最后回到面试开场那个追问。如果你的回答是：

> 「我们用整洁架构：领域层零框架依赖，对外通过 UseCase 端口暴露能力，对基础设施通过 Repository/Gateway 端口依赖。业务规则写在聚合根的方法里，应用层只做编排和事务边界。适配器层负责把领域模型翻译成 PO 和 DTO。我们用 ArchUnit 把依赖规则写成了测试，CI 里就能拦住架构腐化。由此带来的收益是领域逻辑可以零 mock 单测，换掉 Redis 或 RPC 框架时领域和应用层零改动。」

那么这道题，你就不只是答对了，而是答出了**架构判断力**。
