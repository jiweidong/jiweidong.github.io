---
title: 设计模式在企业级Java开发中的最佳实践
date: 2026-06-17 08:03:00
tags:
  - 设计模式
  - Java
  - Spring
  - 架构设计
  - 重构
categories: 架构设计
author: 东哥
---

# 设计模式在企业级Java开发中的最佳实践

## 一、为什么需要设计模式？

设计模式是经过验证的、可复用的解决方案模板。它们不是代码片段，而是解决特定问题的**设计思路**。在复杂的业务系统中，合理运用设计模式可以显著提升代码的可维护性、可扩展性和可读性。

### 1.1 设计模式分类

| 类型 | 模式名称 | 核心意图 | Spring中的应用 |
|------|---------|---------|--------------|
| **创建型** | 工厂方法 | 延迟对象创建到子类 | BeanFactory |
| 创建型 | 抽象工厂 | 创建相关对象族 | 无 |
| 创建型 | 单例模式 | 确保类只有一个实例 | ApplicationContext |
| 创建型 | 建造者模式 | 分步创建复杂对象 | Builder模式无处不在 |
| 创建型 | 原型模式 | 通过克隆创建对象 | Bean scope=prototype |
| **结构型** | 适配器模式 | 接口转换 | MVC中的HandlerAdapter |
| 结构型 | 代理模式 | 控制对象访问 | AOP动态代理 |
| 结构型 | 装饰器模式 | 动态添加职责 | BufferedReader包装 |
| 结构型 | 组合模式 | 树形结构的统一处理 | Spring Security过滤器链 |
| 结构型 | 外观模式 | 简化接口 | JdbcTemplate |
| **行为型** | 策略模式 | 算法族封装 | Resource接口 |
| 行为型 | 模板方法 | 算法骨架定义 | JdbcTemplate, RestTemplate |
| 行为型 | 观察者模式 | 一对多依赖通知 | ApplicationListener |
| 行为型 | 责任链模式 | 请求链式处理 | FilterChain |
| 行为型 | 状态模式 | 状态驱动的行为变化 | 工作流引擎 |

## 二、策略模式：消除if-else

### 2.1 业务场景

电商系统中，不同用户等级享受不同折扣，常规写法：

```java
// ❌ 坏味道：大量if-else
public BigDecimal calculateDiscount(String userLevel, BigDecimal amount) {
    if ("NORMAL".equals(userLevel)) {
        return amount.multiply(new BigDecimal("1.0"));
    } else if ("VIP".equals(userLevel)) {
        return amount.multiply(new BigDecimal("0.9"));
    } else if ("SVIP".equals(userLevel)) {
        return amount.multiply(new BigDecimal("0.8"));
    } else if ("PLATINUM".equals(userLevel)) {
        return amount.multiply(new BigDecimal("0.7"));
    }
    throw new IllegalArgumentException("Unknown level: " + userLevel);
}
```

### 2.2 策略模式重构

```java
// 策略接口
public interface DiscountStrategy {
    String getUserLevel();
    BigDecimal applyDiscount(BigDecimal amount);
}

// 具体策略
@Component
public class NormalDiscountStrategy implements DiscountStrategy {
    @Override
    public String getUserLevel() { return "NORMAL"; }
    
    @Override
    public BigDecimal applyDiscount(BigDecimal amount) {
        return amount;
    }
}

@Component
public class VipDiscountStrategy implements DiscountStrategy {
    @Override
    public String getUserLevel() { return "VIP"; }
    
    @Override
    public BigDecimal applyDiscount(BigDecimal amount) {
        return amount.multiply(new BigDecimal("0.9"));
    }
}

@Component
public class SvipDiscountStrategy implements DiscountStrategy {
    @Override
    public String getUserLevel() { return "SVIP"; }
    
    @Override
    public BigDecimal applyDiscount(BigDecimal amount) {
        return amount.multiply(new BigDecimal("0.8"));
    }
}

// 策略上下文
@Component
public class DiscountStrategyContext {
    
    private final Map<String, DiscountStrategy> strategyMap;
    
    @Autowired
    public DiscountStrategyContext(List<DiscountStrategy> strategies) {
        this.strategyMap = strategies.stream()
            .collect(Collectors.toMap(DiscountStrategy::getUserLevel, Function.identity()));
    }
    
    public BigDecimal calculateDiscount(String userLevel, BigDecimal amount) {
        DiscountStrategy strategy = strategyMap.get(userLevel);
        if (strategy == null) {
            throw new IllegalArgumentException("Unknown level: " + userLevel);
        }
        return strategy.applyDiscount(amount);
    }
}
```

## 三、模板方法模式：封装不变，扩展变

```java
// 抽象模板：定义流程骨架
public abstract class AbstractPaymentService {
    
    // 模板方法 - final防止子类重写
    public final PaymentResult processPayment(PaymentRequest request) {
        // 1. 参数校验（不变）
        validate(request);
        
        // 2. 风控检查（不变）
        riskControl(request);
        
        // 3. 实际支付（可变 - 子类实现）
        PaymentResult result = doPay(request);
        
        // 4. 支付后处理（不变）
        postProcess(request, result);
        
        // 5. 发送通知（半可变 - 有默认实现）
        sendNotification(request, result);
        
        return result;
    }
    
    private void validate(PaymentRequest request) {
        if (request.getAmount() == null || request.getAmount().compareTo(BigDecimal.ZERO) <= 0) {
            throw new PaymentException("金额无效");
        }
        if (StringUtils.isEmpty(request.getOrderNo())) {
            throw new PaymentException("订单号不能为空");
        }
    }
    
    private void riskControl(PaymentRequest request) {
        // 风控校验逻辑
        log.info("风控检查通过: {}", request.getOrderNo());
    }
    
    // 抽象方法 - 子类必须实现
    protected abstract PaymentResult doPay(PaymentRequest request);
    
    private void postProcess(PaymentRequest request, PaymentResult result) {
        // 更新订单状态、记录日志等
        log.info("支付后处理: {}", request.getOrderNo());
    }
    
    // 钩子方法 - 子类可选覆盖
    protected void sendNotification(PaymentRequest request, PaymentResult result) {
        // 默认发送短信通知
        log.info("发送支付通知: {}", request.getOrderNo());
    }
}

// 支付宝支付实现
@Component
public class AlipayService extends AbstractPaymentService {
    @Override
    protected PaymentResult doPay(PaymentRequest request) {
        // 调用支付宝SDK
        AlipayClient alipayClient = new DefaultAlipayClient(...);
        AlipayTradePayRequest payRequest = new AlipayTradePayRequest();
        // ... 组装参数
        AlipayTradePayResponse response = alipayClient.execute(payRequest);
        return PaymentResult.of(response);
    }
}

// 微信支付实现
@Component
public class WechatPayService extends AbstractPaymentService {
    @Override
    protected PaymentResult doPay(PaymentRequest request) {
        // 调用微信支付SDK
        return PaymentResult.success();
    }
    
    @Override
    protected void sendNotification(PaymentRequest request, PaymentResult result) {
        // 微信支付发送微信模板消息
        log.info("发送微信模板消息: {}", request.getOrderNo());
    }
}
```

## 四、观察者模式：解耦事件通知

```java
// 事件定义
@Getter
public class OrderEvent extends ApplicationEvent {
    private final Long orderId;
    private final String orderNo;
    private final OrderEventType eventType;
    
    public OrderEvent(Object source, Long orderId, String orderNo, OrderEventType eventType) {
        super(source);
        this.orderId = orderId;
        this.orderNo = orderNo;
        this.eventType = eventType;
    }
}

// 事件发布者
@Service
public class OrderService {
    
    @Autowired
    private ApplicationEventPublisher eventPublisher;
    
    @Transactional
    public void createOrder(CreateOrderRequest request) {
        // 创建订单
        Order order = createOrderInDB(request);
        
        // 发布事件 - 完全解耦后续处理
        eventPublisher.publishEvent(
            new OrderEvent(this, order.getId(), order.getOrderNo(), OrderEventType.CREATED)
        );
    }
}

// 事件监听者1：积分服务
@Component
@Slf4j
public class PointEventListener {
    
    @EventListener
    @Async // 异步执行，不影响主流程
    public void handleOrderCreated(OrderEvent event) {
        if (event.getEventType() == OrderEventType.CREATED) {
            log.info("订单创建 - 赠送积分: {}", event.getOrderNo());
            // 调用积分服务
        }
    }
}

// 事件监听者2：短信服务
@Component
@Slf4j
public class SmsEventListener {
    
    @EventListener
    @Async
    public void handleOrderCreated(OrderEvent event) {
        if (event.getEventType() == OrderEventType.CREATED) {
            log.info("订单创建 - 发送通知短信: {}", event.getOrderNo());
            // 调用短信服务
        }
    }
}
```

## 五、责任链模式：灵活的处理流水线

```java
// 处理器接口
public interface OrderHandler {
    void handle(OrderContext context);
    void setNext(OrderHandler next);
}

// 抽象基类
public abstract class AbstractOrderHandler implements OrderHandler {
    protected OrderHandler next;
    
    @Override
    public void setNext(OrderHandler next) {
        this.next = next;
    }
    
    protected void doNext(OrderContext context) {
        if (next != null) {
            next.handle(context);
        }
    }
}

// 具体处理器
@Component
@Order(1)
public class OrderValidationHandler extends AbstractOrderHandler {
    @Override
    public void handle(OrderContext context) {
        log.info("订单校验处理器");
        if (context.getOrder().getAmount().compareTo(BigDecimal.ZERO) <= 0) {
            throw new BusinessException("订单金额无效");
        }
        doNext(context);
    }
}

@Component
@Order(2)
public class InventoryCheckHandler extends AbstractOrderHandler {
    @Override
    public void handle(OrderContext context) {
        log.info("库存检查处理器");
        // 检查库存
        if (!checkInventory(context.getOrder().getProductId(), context.getOrder().getQuantity())) {
            throw new BusinessException("库存不足");
        }
        doNext(context);
    }
}

@Component
@Order(3)
public class OrderPersistenceHandler extends AbstractOrderHandler {
    @Override
    public void handle(OrderContext context) {
        log.info("订单持久化处理器");
        // 保存订单到数据库
        doNext(context);
    }
}

// 链组装
@Configuration
public class OrderHandlerChainConfig {
    
    @Autowired
    private List<AbstractOrderHandler> handlers;
    
    @Bean
    public OrderHandler orderHandlerChain() {
        // 按Order注解排序
        handlers.sort(Comparator.comparing(h -> 
            h.getClass().getAnnotation(Order.class).value()
        ));
        
        // 构建链
        for (int i = 0; i < handlers.size() - 1; i++) {
            handlers.get(i).setNext(handlers.get(i + 1));
        }
        
        return handlers.get(0);
    }
}
```

## 六、工厂模式 + 策略模式综合实战

```java
// 支付处理器工厂 - 结合Spring容器
@Component
public class PaymentStrategyFactory implements InitializingBean {
    
    @Autowired
    private ApplicationContext applicationContext;
    
    private Map<String, PaymentStrategy> strategyMap;
    
    @Override
    public void afterPropertiesSet() {
        // 从Spring容器获取所有Strategy实现
        strategyMap = applicationContext.getBeansOfType(PaymentStrategy.class)
            .values()
            .stream()
            .collect(Collectors.toMap(
                strategy -> strategy.getPaymentType().name(),
                Function.identity()
            ));
    }
    
    public PaymentStrategy getStrategy(PaymentType paymentType) {
        PaymentStrategy strategy = strategyMap.get(paymentType.name());
        if (strategy == null) {
            throw new UnsupportedOperationException("不支持的支付方式: " + paymentType);
        }
        return strategy;
    }
}

// 使用
@Service
public class PaymentFacade {
    
    @Autowired
    private PaymentStrategyFactory factory;
    
    public PaymentResult pay(PaymentRequest request) {
        PaymentStrategy strategy = factory.getStrategy(request.getPaymentType());
        return strategy.pay(request);
    }
}
```

## 七、设计模式运用原则

### 7.1 不要过度设计

设计模式是工具，不是目标。过度使用设计模式会让简单问题复杂化。

### 7.2 组合优于继承

优先使用组合模式而非继承来复用代码。继承会暴露父类实现细节，组合则通过接口协作。

### 7.3 面向接口编程

依赖抽象而非具体实现，这是所有设计模式的核心思想。

### 7.4 单一职责

每个类只负责一件事。如果一个类负责的事情太多，就应该拆分为多个类。

## 八、总结

设计模式不是死板的模板，而是解决特定问题的思路。在Java企业级开发中，策略模式消除if-else、模板方法封装流程骨架、观察者模式解耦事件通知、责任链模式构建灵活处理流水线，这些都是最常用的模式组合。关键在于理解每种模式的适用场景，在正确的场景使用正确的模式，同时避免过度设计。记住：**好的代码不是用了多少模式，而是代码多容易理解和修改**。
