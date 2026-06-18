---
title: Spring 事件驱动编程机制详解
date: 2026-06-19 08:00:00
author: 东哥
categories:
  - Spring框架
tags:
  - Spring
  - SpringBoot
  - 事件驱动
  - ApplicationEvent
  - 观察者模式
---

## 前言

Spring 的事件机制是框架内部解耦的核心手段之一——启动流程中的各种状态广播、事务同步、微服务中的异步通信，底层都依赖它。

本质是 **观察者模式** 在 Spring 容器中的实现：事件发布者（Publisher）无需关心谁在处理，监听者（Listener）也无需被发布者知晓。

---

## 一、核心组件

Spring 事件机制由三个角色组成：

| 角色 | 接口/类 | 职责 |
|------|---------|------|
| **事件** | `ApplicationEvent` | 封装事件数据 |
| **发布者** | `ApplicationEventPublisher` | 发布事件 |
| **监听者** | `ApplicationListener<E>` / `@EventListener` | 处理事件 |

### 1.1 事件（Event）

所有自定义事件继承自 `ApplicationEvent`：

```java
public abstract class ApplicationEvent extends EventObject {
    private final long timestamp;

    public ApplicationEvent(Object source) {
        super(source);
        this.timestamp = System.currentTimeMillis();
    }
    // getTimestamp()
}
```

Spring 内置了一些常用事件（均继承自 `ApplicationContextEvent`）：

- `ContextRefreshedEvent` — 容器刷新完成
- `ContextStartedEvent` — 容器启动（调用 start）
- `ContextStoppedEvent` — 容器停止
- `ContextClosedEvent` — 容器关闭
- `ServletRequestHandledEvent` — 请求处理完毕（DispatcherServlet 触发）

### 1.2 发布者（Publisher）

`ApplicationEventPublisher` 接口：

```java
@FunctionalInterface
public interface ApplicationEventPublisher {
    default void publishEvent(ApplicationEvent event) {
        publishEvent((Object) event);
    }
    void publishEvent(Object event);  // 也接受普通对象（包装为 PayloadApplicationEvent）
}
```

Spring 容器本身（`AbstractApplicationContext`）实现了该接口，所以 **在任何地方注入 ApplicationEventPublisher 即可发布事件**。

### 1.3 监听者（Listener）

两种实现方式：

**方式一：实现接口**

```java
@Component
public class MyListener implements ApplicationListener<MyEvent> {
    @Override
    public void onApplicationEvent(MyEvent event) {
        System.out.println("收到事件：" + event.getSource());
    }
}
```

**方式二：注解驱动（推荐）**

```java
@Component
public class MyListener {
    @EventListener
    public void handleMyEvent(MyEvent event) {
        System.out.println("收到事件：" + event.getSource());
    }
}
```

---

## 二、快速上手实战

### 2.1 定义自定义事件

```java
public class OrderCreatedEvent extends ApplicationEvent {
    private final Long orderId;
    private final String orderNo;

    public OrderCreatedEvent(Object source, Long orderId, String orderNo) {
        super(source);
        this.orderId = orderId;
        this.orderNo = orderNo;
    }

    public Long getOrderId() { return orderId; }
    public String getOrderNo() { return orderNo; }
}
```

### 2.2 发布事件

```java
@Service
public class OrderService {
    @Autowired
    private ApplicationEventPublisher eventPublisher;

    public void createOrder(OrderDTO orderDTO) {
        // 1. 业务逻辑：创建订单
        Order order = doCreateOrder(orderDTO);

        // 2. 发布事件
        eventPublisher.publishEvent(new OrderCreatedEvent(this, order.getId(), order.getOrderNo()));
    }
}
```

### 2.3 监听事件

```java
@Component
public class OrderEventListener {

    @EventListener
    public void sendNotification(OrderCreatedEvent event) {
        System.out.println("发送下单通知，订单号：" + event.getOrderNo());
    }

    @EventListener
    public void updateInventory(OrderCreatedEvent event) {
        System.out.println("扣减库存，订单ID：" + event.getOrderId());
    }
}
```

**注意**：默认情况下所有 `@EventListener` 方法在同一个线程同步执行。这意味着发布者线程会等所有监听者执行完才继续。

---

## 三、高级特性

### 3.1 异步事件

用 `@Async` 让监听者异步执行：

```java
@Component
@EnableAsync   // 通常在配置类开启
public class OrderEventListener {

    @Async
    @EventListener
    public void sendEmail(OrderCreatedEvent event) {
        // 异步发送邮件，不影响主流程
        mailService.sendOrderConfirmation(event.getOrderId());
    }
}
```

注意：

- 需要 `@EnableAsync` 开启异步支持
- 需要配置线程池（`TaskExecutor`），否则使用 `SimpleAsyncTaskExecutor`

**配置推荐**：

```java
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {
    @Override
    public Executor getAsyncExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(5);
        executor.setMaxPoolSize(10);
        executor.setQueueCapacity(100);
        executor.setThreadNamePrefix("event-exec-");
        executor.setWaitForTasksToCompleteOnShutdown(true);
        executor.initialize();
        return executor;
    }
}
```

### 3.2 事件执行顺序

多个监听同一事件的 `@EventListener` 可以用 `@Order` 控制顺序：

```java
@Component
public class OrderEventListener {

    @Order(1)
    @EventListener
    public void updateInventory(OrderCreatedEvent event) {
        // 先执行
    }

    @Order(2)
    @EventListener
    public void sendNotification(OrderCreatedEvent event) {
        // 后执行
    }
}
```

数字越小优先级越高。

### 3.3 条件监听

`@EventListener` 支持 SpEL 条件表达式，只有满足条件才触发：

```java
@Component
public class OrderEventListener {

    @EventListener(condition = "#event.orderAmount > 1000")
    public void handleBigOrder(OrderCreatedEvent event) {
        // 仅处理大额订单（> 1000）
    }

    @EventListener(condition = "#event.source == 'vip'")
    public void handleVipOrder(OrderCreatedEvent event) {
        // 仅处理 VIP 用户订单
    }
}
```

### 3.4 泛型事件支持

事件本身可以带泛型，监听器能精确匹配类型：

```java
// 泛型事件
public class BaseEvent<T> extends ApplicationEvent {
    private final T data;
    public BaseEvent(Object source, T data) {
        super(source);
        this.data = data;
    }
    public T getData() { return data; }
}

// 监听器
@Component
public class GenericEventListener {

    @EventListener
    public void handleStringEvent(BaseEvent<String> event) {
        System.out.println("String 事件：" + event.getData());
    }

    @EventListener
    public void handleIntegerEvent(BaseEvent<Integer> event) {
        System.out.println("Integer 事件：" + event.getData());
    }
}
```

Spring 4.2+ 通过 `ResolvableType` 支持这种泛型事件精确分发。

### 3.5 事件转发

一个监听方法可以返回新事件，Spring 会自动发布：

```java
@EventListener
public PaymentCompletedEvent handleOrderCreated(OrderCreatedEvent event) {
    // 处理订单创建
    return new PaymentCompletedEvent(this, event.getOrderId());
}

@EventListener
public void handlePaymentCompleted(PaymentCompletedEvent event) {
    // 支付完成后继续处理
}
```

这种方法支持链式流程编排。

---

## 四、底层原理

### 4.1 事件多播器

事件的分发由 `ApplicationEventMulticaster` 负责：

```java
public interface ApplicationEventMulticaster {
    void addApplicationListener(ApplicationListener<?> listener);
    void removeApplicationListener(ApplicationListener<?> listener);
    void multicastEvent(ApplicationEvent event, ResolvableType eventType);
}
```

默认实现：`SimpleApplicationEventMulticaster`

```java
public class SimpleApplicationEventMulticaster extends AbstractApplicationEventMulticaster {
    @Nullable
    private Executor taskExecutor;   // 有 executor 就异步

    @Override
    public void multicastEvent(ApplicationEvent event, ResolvableType eventType) {
        ResolvableType type = (eventType != null) ? eventType : resolveDefaultEventType(event);

        Executor executor = getTaskExecutor();
        for (ApplicationListener<?> listener : getApplicationListeners(event, type)) {
            if (executor != null) {
                // 异步执行
                executor.execute(() -> invokeListener(listener, event));
            } else {
                // 同步执行
                invokeListener(listener, event);
            }
        }
    }
}
```

**关键**：`taskExecutor` 为 null 时同步执行，不为 null 时异步执行。这是 `@Async` + `@EventListener` 实现异步的底层原理。

### 4.2 容器初始化时注册监听器

在 `AbstractApplicationContext.refresh()` 的 `initApplicationEventMulticaster()` 和 `registerListeners()` 中完成：

```java
// 初始化多播器
protected void initApplicationEventMulticaster() {
    ConfigurableListableBeanFactory beanFactory = getBeanFactory();
    if (beanFactory.containsLocalBean(APPLICATION_EVENT_MULTICASTER_BEAN_NAME)) {
        this.applicationEventMulticaster =
                beanFactory.getBean(APPLICATION_EVENT_MULTICASTER_BEAN_NAME, ApplicationEventMulticaster.class);
    } else {
        this.applicationEventMulticaster = new SimpleApplicationEventMulticaster(beanFactory);
        beanFactory.registerSingleton(APPLICATION_EVENT_MULTICASTER_BEAN_NAME, this.applicationEventMulticaster);
    }
}

// 注册监听器
protected void registerListeners() {
    // 1. 注册硬编码的静态监听器
    for (ApplicationListener<?> listener : getApplicationListeners()) {
        getApplicationEventMulticaster().addApplicationListener(listener);
    }

    // 2. 从 BeanFactory 中获取所有 ApplicationListener Bean
    String[] listenerBeanNames = getBeanNamesForType(ApplicationListener.class, true, false);
    for (String listenerBeanName : listenerBeanNames) {
        getApplicationEventMulticaster().addApplicationListenerBean(listenerBeanName);
    }

    // 3. 发布早期事件
    Set<ApplicationEvent> earlyEvents = getEarlyApplicationEvents();
    if (earlyEvents != null) {
        for (ApplicationEvent earlyEvent : earlyEvents) {
            getApplicationEventMulticaster().multicastEvent(earlyEvent);
        }
        earlyEvents = null;
    }
}
```

### 4.3 @EventListener 是如何被发现的？

核心：`EventListenerMethodProcessor` 实现了 `SmartInitializingSingleton`，在所有单例 Bean 创建完成后扫描每个 Bean 中带 `@EventListener` 的方法：

```java
@Override
public void afterSingletonsInstantiated() {
    // 遍历所有单例 Bean
    for (String beanName : beanNames) {
        // 检查是否有 @EventListener 方法
        processBean(beanName, type);
    }
}

private void processBean(String beanName, Class<?> targetType) {
    // 查找 @EventListener 方法
    Map<Method, EventListener> annotatedMethods = MethodIntrospector.selectMethods(targetType,
            (MethodIntrospector.MetadataLookup<EventListener>) method ->
                    AnnotatedElementUtils.findMergedAnnotation(method, EventListener.class));

    // 为每个方法创建 ApplicationListener 适配器
    for (Method method : annotatedMethods.keySet()) {
        ApplicationListener<?> listener = createApplicationListener(beanName, targetType, method);
        // 注册到多播器
        context.addApplicationListener(listener);
    }
}
```

---

## 五、与消息队列的区别

| 特性 | Spring 事件 | 消息队列（Kafka/RabbitMQ） |
|------|------------|--------------------------|
| 范围 | 同一 JVM 进程内 | 跨进程、跨服务 |
| 可靠性 | 无持久化，容器销毁后丢失 | 消息持久化到磁盘 |
| 顺序 | 默认同步有序 | 支持分区内有序 |
| 重试 | 异常直接抛出 | 支持死信队列、重试机制 |
| 解耦程度 | 类级别解耦 | 服务级别解耦 |

**适用场景**：

- Spring 事件：同一进程内的模块解耦（如订单→通知→积分）
- 消息队列：微服务之间的最终一致性事件驱动

---

## 六、常见面试题

### 6.1 同一个事件有多个监听器，如何保证事务一致性？

将业务操作和事件发布放在同一个事务中，使用 `@TransactionalEventListener`：

```java
@Component
public class OrderEventListener {

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void handleAfterCommit(OrderCreatedEvent event) {
        // 事务提交后执行
    }
}
```

`@TransactionalEventListener` 的 phase 可选值：

- `AFTER_COMMIT`（默认）— 提交后执行
- `AFTER_ROLLBACK` — 回滚后执行
- `AFTER_COMPLETION` — 事务完成后（不论成败）
- `BEFORE_COMMIT` — 提交前执行（仍在事务中）

### 6.2 事件发布后监听器抛异常会怎样？

- **同步**：异常会传播给发布者，后续监听器不会执行
- **异步**：异步线程抛异常不影响发布者，但会被 `AsyncUncaughtExceptionHandler` 处理

**建议**：监听器内自己 try-catch，不要抛到上层。

```java
@EventListener
public void safeHandle(OrderCreatedEvent event) {
    try {
        // 业务逻辑
    } catch (Exception e) {
        log.error("事件处理失败: {}", event.getOrderId(), e);
        // 可以根据策略决定是否重试
    }
}
```

### 6.3 如何自定义 ApplicationEventMulticaster？

配置一个 `ApplicationEventMulticaster` Bean 即可覆盖默认实现：

```java
@Bean
public ApplicationEventMulticaster applicationEventMulticaster() {
    SimpleApplicationEventMulticaster multicaster = new SimpleApplicationEventMulticaster();
    multicaster.setTaskExecutor(Executors.newFixedThreadPool(5));  // 全局异步
    multicaster.setErrorHandler(new SimpleErrorHandler());         // 异常处理
    return multicaster;
}
```

---

## 总结

Spring 事件机制是观察者模式的优雅实现，理解它有助于：

1. 写出松耦合的代码（发布者不关心谁在处理）
2. 理解 Spring 容器生命周期（各种内置事件）
3. 构建事务内/事务后的异步处理流程
4. 看透 `@Async` + `@EventListener` 的异步实现原理

事件机制虽简单，但用好它能让代码结构更清晰、扩展性更强。
