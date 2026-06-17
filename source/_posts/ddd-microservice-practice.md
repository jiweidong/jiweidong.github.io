---
title: 领域驱动设计（DDD）在微服务中的落地实践
date: 2026-06-17 12:30:00
tags:
  - DDD
  - 领域驱动设计
  - 微服务
  - 架构设计
categories:
  - 架构设计
author: 东哥
---

# 领域驱动设计（DDD）在微服务中的落地实践

## 一、DDD 为什么在微服务时代重新流行

微服务拆分有个经典问题：**服务边界怎么划？** 很多团队按技术层划分（Controller / Service / DAO），结果一个变更要改十几二十个文件，耦合度极高。

DDD（Domain-Driven Design）主张**按业务领域划分服务边界**，这正是微服务拆分最自然的依据。

### 1.1 传统分层 vs DDD 分层

```
传统三层架构:                    DDD 四层架构:
┌─────────────────┐            ┌─────────────────┐
│   Controller    │            │ Interface (API) │
├─────────────────┤            ├─────────────────┤
│                 │            │  Application    │
│   Service       │            │  (应用服务层)    │
│   (业务逻辑)    │            ├─────────────────┤
├─────────────────┤            │   Domain        │
│                 │            │  (领域层)       │
│   DAO/Repository │            ├─────────────────┤
│                 │            │ Infrastructure  │
└─────────────────┘            │  (基础设施层)    │
                               └─────────────────┘
```

| 对比维度 | 传统分层 | DDD 四层 |
|---------|---------|---------|
| 业务逻辑位置 | Service 层（贫血模型） | Domain 层（富模型） |
| 数据模型 | 数据库表驱动 | 领域模型驱动 |
| 服务边界 | 技术耦合 | 业务边界（限界上下文） |
| 变更影响 | 逻辑分散，改一处影响多处 | 高内聚、低耦合 |
| 可测试性 | 依赖数据库 | 领域层纯业务，Mock 友好 |

## 二、DDD 核心概念

### 2.1 战略设计：限界上下文

**限界上下文（Bounded Context）** 是 DDD 最重要的概念。每个限界上下文有自己独立的领域模型、业务规则和语言。

```
订单上下文
┌─────────────────────────────┐
│ Order (订单聚合)             │
│ - orderId                    │
│ - orderItems                 │
│ - totalAmount                │
│ - status                     │
│ + cancel()                   │
│ + pay()                      │
│ + addItem()                  │
└─────────────┬───────────────┘
              │
              │ 上下文映射
              ▼
库存上下文
┌─────────────────────────────┐
│ Product (商品聚合)           │
│ - skuId                      │
│ - stock                      │
│ + deductStock()              │
│ + restoreStock()             │
└─────────────────────────────┘
```

**上下文映射模式：**

| 映射关系 | 说明 | 适用场景 |
|---------|------|---------|
| 合作关系 | 两个上下文紧密合作 | 订单 + 支付 |
| 共享内核 | 共享部分领域模型 | 公共值对象 |
| 客户方-供应方 | 一方依赖另一方 | 订单 → 库存 |
| 防腐层 | 隔离外部系统变化 | 对接遗留系统 |
| 开放主机服务 | 对外提供 API | 开放平台 |

### 2.2 战术设计：核心构件

| 构件 | 英文 | 说明 | 特征 |
|------|------|------|------|
| 实体 | Entity | 有唯一标识、可变 | `==` 比较 ID |
| 值对象 | Value Object | 无标识、不可变 | `==` 比较属性值 |
| 聚合 | Aggregate | 实体 + 值对象的组合 | 一致性边界 |
| 聚合根 | Aggregate Root | 聚合的入口 | 外部只能引用聚合根 |
| 领域事件 | Domain Event | 领域中发生的事 | 发布 + 订阅 |
| 领域服务 | Domain Service | 跨实体的业务逻辑 | 无状态 |
| 仓储 | Repository | 聚合的持久化 | 对集合操作 |
| 工厂 | Factory | 复杂对象的创建 | 封装创建逻辑 |

## 三、DDD 代码实战

### 3.1 聚合根设计示例

```java
// ──────────────── 值对象 ────────────────

@Value
public class Money implements Serializable {
    BigDecimal amount;
    String currency;
    
    public Money(BigDecimal amount, String currency) {
        this.amount = amount.setScale(2, RoundingMode.HALF_UP);
        this.currency = currency;
    }
    
    public Money add(Money other) {
        if (!this.currency.equals(other.currency)) {
            throw new IllegalArgumentException("货币不匹配");
        }
        return new Money(this.amount.add(other.amount), this.currency);
    }
    
    public Money multiply(BigDecimal multiplier) {
        return new Money(this.amount.multiply(multiplier), this.currency);
    }
}

@Value
public class Address implements Serializable {
    String province;
    String city;
    String district;
    String detail;
    String zipCode;
}

@Value
public class OrderItemId implements Serializable {
    Long id;
}

// ──────────────── 实体 ────────────────

@Entity
@Table(name = "order_items")
public class OrderItem {
    
    @EmbeddedId
    private OrderItemId id;
    
    private Long productId;
    private String productName;
    private Money price;
    private Integer quantity;
    private Money subtotal;
    
    public OrderItem(Long productId, String productName, 
                     Money price, Integer quantity) {
        this.id = new OrderItemId(IdGenerator.nextId());
        this.productId = productId;
        this.productName = productName;
        this.price = price;
        this.quantity = quantity;
        this.subtotal = price.multiply(BigDecimal.valueOf(quantity));
    }
    
    public Money getSubtotal() {
        return subtotal;
    }
    
    public void increaseQuantity(Integer delta) {
        this.quantity += delta;
        this.subtotal = price.multiply(BigDecimal.valueOf(this.quantity));
    }
}

// ──────────────── 聚合根 ────────────────

@Entity
@Table(name = "orders")
@DomainAggregate
public class Order {
    
    @Id
    private Long id;
    
    private Long userId;
    private Money totalAmount;
    private OrderStatus status;
    
    @Embedded
    private Address shippingAddress;
    
    @OneToMany(cascade = CascadeType.ALL, orphanRemoval = true)
    @JoinColumn(name = "order_id")
    private List<OrderItem> items = new ArrayList<>();
    
    private LocalDateTime createdAt;
    private LocalDateTime paidAt;
    private LocalDateTime cancelledAt;
    
    protected Order() {  // JPA 需要无参构造
    }
    
    // 工厂方法
    public static Order create(Long userId, Address address) {
        Order order = new Order();
        order.id = IdGenerator.nextId();
        order.userId = userId;
        order.totalAmount = Money.zero("CNY");
        order.status = OrderStatus.CREATED;
        order.shippingAddress = address;
        order.createdAt = LocalDateTime.now();
        return order;
    }
    
    // 业务方法：添加商品
    public void addItem(Long productId, String productName, 
                         Money price, int quantity) {
        if (status != OrderStatus.CREATED) {
            throw new IllegalStateException("只能向未支付的订单添加商品");
        }
        
        // 查找是否已有该商品
        OrderItem existing = items.stream()
            .filter(item -> item.getProductId().equals(productId))
            .findFirst()
            .orElse(null);
        
        if (existing != null) {
            existing.increaseQuantity(quantity);
        } else {
            items.add(new OrderItem(productId, productName, price, quantity));
        }
        
        // 重新计算总价
        recalculateTotal();
    }
    
    // 业务方法：提交订单
    public void submit() {
        if (items.isEmpty()) {
            throw new IllegalStateException("订单不能为空");
        }
        this.status = OrderStatus.SUBMITTED;
        // 发布领域事件
        DomainEventPublisher.publish(
            new OrderSubmittedEvent(this.id, this.userId, this.totalAmount));
    }
    
    // 业务方法：支付
    public void pay() {
        if (status != OrderStatus.SUBMITTED) {
            throw new IllegalStateException("只有已提交的订单才能支付");
        }
        this.status = OrderStatus.PAID;
        this.paidAt = LocalDateTime.now();
        
        DomainEventPublisher.publish(
            new OrderPaidEvent(this.id, this.userId, this.totalAmount));
    }
    
    // 业务方法：取消
    public void cancel(String reason) {
        if (status == OrderStatus.SHIPPED || status == OrderStatus.DELIVERED) {
            throw new IllegalStateException("已发货的订单无法取消");
        }
        this.status = OrderStatus.CANCELLED;
        this.cancelledAt = LocalDateTime.now();
        
        DomainEventPublisher.publish(
            new OrderCancelledEvent(this.id, this.userId, reason));
    }
    
    private void recalculateTotal() {
        this.totalAmount = items.stream()
            .map(OrderItem::getSubtotal)
            .reduce(MonetaryAmount::add)
            .orElse(Money.zero("CNY"));
    }
}
```

### 3.2 仓储接口

```java
public interface OrderRepository {
    
    Order findById(Long orderId);
    
    void save(Order order);
    
    void delete(Order order);
    
    // 按用户查询（实际场景可能用 CQRS 拆分查询）
    Page<Order> findByUserId(Long userId, Pageable pageable);
    
    // 领域查询
    List<Order> findExpiredOrders(LocalDateTime before);
}
```

### 3.3 领域服务

```java
@DomainService
public class OrderDomainService {
    
    private final OrderRepository orderRepository;
    private final ProductRepository productRepository;
    
    // 跨聚合的业务逻辑：下单时检查库存
    @Transactional
    public Order placeOrder(Long userId, Address address, 
                             List<OrderItemRequest> itemRequests) {
        
        Order order = Order.create(userId, address);
        
        for (OrderItemRequest req : itemRequests) {
            // 从库存上下文获取商品信息（通过防腐层）
            ProductInfo product = productRepository.findById(req.getProductId());
            
            if (product.getStock() < req.getQuantity()) {
                throw new InsufficientStockException(
                    "商品库存不足: " + product.getProductName());
            }
            
            order.addItem(
                product.getId(), 
                product.getProductName(),
                new Money(product.getPrice(), "CNY"),
                req.getQuantity()
            );
        }
        
        order.submit();
        orderRepository.save(order);
        
        return order;
    }
}
```

### 3.4 应用服务

```java
@Service
public class OrderApplicationService {
    
    private final OrderDomainService orderDomainService;
    private final PaymentClient paymentClient;
    private final NotificationClient notificationClient;
    
    @Transactional
    public OrderDTO placeOrder(PlaceOrderRequest request, Long userId) {
        // 1. 领域逻辑
        Order order = orderDomainService.placeOrder(
            userId,
            new Address(request.getProvince(), request.getCity(), 
                       request.getDistrict(), request.getDetail(), null),
            request.getItems()
        );
        
        // 2. 发送领域事件后的副作用（应用层编排）
        // 领域事件监听器会异步处理支付、通知等
        
        return OrderDTO.from(order);
    }
    
    public void handleOrderPaid(OrderPaidEvent event) {
        // 应用层编排：支付成功后，发送通知
        notificationClient.sendOrderConfirmation(
            event.getUserId(), event.getOrderId());
    }
}
```

## 四、DDD + CQRS 架构

在一个复杂的业务系统中，查询逻辑往往比命令逻辑复杂很多。CQRS（命令查询职责分离）将读操作和写操作分离：

```
写模型 (Command):                     读模型 (Query):
┌─────────────────────┐             ┌─────────────────────┐
│    Order 聚合根      │             │    OrderView        │
│    写操作 + 验证     │   同步      │    只读视图          │
│    领域事件          │───────────►│    ES / MySQL       │
└─────────────────────┘             └─────────────────────┘
```

```java
// 写（Command）
@Service
public class OrderCommandService {
    
    public void cancelOrder(Long orderId, String reason) {
        Order order = orderRepository.findById(orderId);
        order.cancel(reason);
        orderRepository.save(order);
    }
}

// 读（Query）
@Service
public class OrderQueryService {
    
    public OrderListView queryOrders(OrderQuery query) {
        // 直接从读库查询，不走聚合
        return orderViewRepository.query(query);
    }
}
```

## 五、DDD 落地避坑指南

### 5.1 常见误区

| 误区 | 错误做法 | 正确做法 |
|------|---------|---------|
| 过度建模 | 所有表都做成聚合 | 只对核心业务使用 DDD |
| 贫血模型 | Service 里写满逻辑 | 逻辑放到实体中 |
| 忽视值对象 | 用 String 代替 | 显式定义 Money、Address |
| 大聚合 | 一个聚合包含所有 | 保持小聚合，按事务边界 |
| 过度事件 | 每个操作都发事件 | 只发业务相关的事件 |

### 5.2 适用场景

**适合 DDD 的场景：**
- 业务逻辑复杂（如电商订单、金融结算）
- 业务规则经常变化
- 需要和领域专家沟通协作
- 团队有资质理解业务

**不必要用 DDD 的场景：**
- 简单的 CRUD 系统（CMS、管理后台）
- 数据报表类系统
- 团队规模小、交付压力大

### 5.3 实际工程化的建议

1. **不要一刀切**：核心业务用 DDD，非核心用传统方式
2. **先战略设计后战术设计**：先画限界上下文关系，再写实体代码
3. **事件风暴**：和产品经理一起用事件风暴工作坊梳理业务
4. **迭代演进**：不需要一开始就完美，让领域模型随业务一起演进

DDD 不是银弹，但它是目前解决微服务边界划分和复杂业务建模的最佳方法论。核心是要坚持"代码反映业务语言"的理念，让领域模型成为团队沟通的共同基础。
