---
title: 【设计模式】观察者模式深度解析：从手写实现到 Spring Event 与 MQ 发布订阅
date: 2026-08-06 08:00:00
tags:
  - Java
  - 设计模式
  - Spring
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】观察者模式深度解析：从手写实现到 Spring Event 与 MQ 发布订阅

## 面试官：说说观察者模式？它和发布订阅模式有什么区别？

观察者模式（Observer Pattern）是行为型设计模式中最常用的一种，核心思想是：**定义对象间一对多的依赖关系，当一个对象（主题 Subject）的状态发生变化时，所有依赖它的对象（观察者 Observer）都会收到通知并自动更新**。

用一句话概括：**「发布」与「订阅」解耦，「事件」驱动「联动」。**

观察者模式解决的核心问题是**耦合**：如果不使用观察者模式，被观察者需要显式依赖所有关注它的对象，新增一个关注者就要修改被观察者的代码，违反开闭原则。观察者模式把「通知」这个动作抽象出来，让主题只依赖观察者接口，实现反向解耦。

### 观察者模式 vs 发布订阅模式

这是面试高频追问点，务必分清：

| 维度 | 观察者模式 | 发布订阅模式 |
|------|-----------|-------------|
| 耦合关系 | 主题与观察者**互相知道**（观察者注册到主题上） | 发布者与订阅者**互不知道**，通过 Broker/事件总线中转 |
| 通信方式 | 同步调用为主，主题直接调用观察者方法 | 异步解耦，消息通过中间件（MQ、事件总线）分发 |
| 典型实现 | JDK Observable、手写 Listener | Kafka、RabbitMQ、Spring ApplicationEvent |
| 是否支持跨进程 | 不支持，通常同一 JVM 内 | 支持，可跨进程、跨服务 |
| 观察者数量变化 | 主题持有观察者集合，动态增删 | 订阅者与发布者独立伸缩 |

**结论**：发布订阅是观察者模式的「分布式升级版」。面试时能说出这个演进关系，会加分不少。

---

## 手写一个观察者模式

### 经典实现（JDK 1.0 风格）

先看 JDK 自带的 `java.util.Observable` 和 `java.util.Observer`（JDK 9 起已标记废弃，但理解它有助于理解模式本质）：

```java
// 主题：新闻中心
public class NewsCenter extends Observable {
    public void publish(String news) {
        setChanged();          // 标记状态已改变
        notifyObservers(news); // 通知所有观察者
    }
}

// 观察者：用户
public class User implements Observer {
    private final String name;
    public User(String name) { this.name = name; }

    @Override
    public void update(Observable o, Object arg) {
        System.out.println(name + " 收到新闻：" + arg);
    }
}

// 使用
NewsCenter center = new NewsCenter();
center.addObserver(new User("东哥"));
center.addObserver(new User("小美"));
center.publish("今天发布 Java 21 新特性");
```

注意 `setChanged()` 是关键：**只有调用 setChanged 标记变更后，notifyObservers 才会真正触发通知**。这给了主题控制「什么才算一次有效变更」的能力，避免每次设置属性都触发通知风暴。

### 事件对象 + 监听器模式（现代企业级写法）

实际项目中更常用「事件对象 + 监听器」的变体，这也是 Spring 事件机制的雏形：

```java
// 1. 事件对象：携带上下文信息
public class OrderEvent {
    private final Long orderId;
    private final BigDecimal amount;
    // getter / constructor...
}

// 2. 监听器接口
public interface OrderEventListener {
    void onOrderCreated(OrderEvent event);
}

// 3. 事件源：持有监听器集合，负责注册与广播
public class OrderService {
    private final List<OrderEventListener> listeners = new CopyOnWriteArrayList<>();

    public void addListener(OrderEventListener listener) {
        listeners.add(listener);
    }

    public void createOrder(Long orderId, BigDecimal amount) {
        // 业务逻辑：落库、扣库存...
        System.out.println("订单创建成功：" + orderId);
        // 广播事件
        OrderEvent event = new OrderEvent(orderId, amount);
        listeners.forEach(l -> l.onOrderCreated(event));
    }
}

// 4. 业务监听器：互不干扰
public class SmsListener implements OrderEventListener {
    public void onOrderCreated(OrderEvent e) { /* 发短信 */ }
}
public class CouponListener implements OrderEventListener {
    public void onOrderCreated(OrderEvent e) { /* 发优惠券 */ }
}
```

这里用 `CopyOnWriteArrayList` 存储监听器，保证遍历时并发增删安全——这也是面试中可以主动提的优化点。

---

## 观察者模式在 JDK / Spring 中的落地

### 1. Spring 事件机制（ApplicationEvent + @EventListener）

Spring 从 4.2 起推荐使用注解方式，把观察者模式用到了极致：

```java
// 定义事件：继承 ApplicationEvent（或直接传 Object）
public class OrderCreatedEvent extends ApplicationEvent {
    private final Long orderId;
    public OrderCreatedEvent(Object source, Long orderId) {
        super(source);
        this.orderId = orderId;
    }
}

// 发布事件
@Service
public class OrderService {
    @Autowired
    private ApplicationEventPublisher publisher;

    public void createOrder(Long orderId) {
        System.out.println("订单创建：" + orderId);
        publisher.publishEvent(new OrderCreatedEvent(this, orderId));
    }
}

// 监听事件：@EventListener 优雅声明
@Component
public class OrderEventListener {
    @EventListener
    public void onOrderCreated(OrderCreatedEvent event) {
        System.out.println("发送短信，订单：" + event.getOrderId());
    }
}
```

**Spring 事件的三个底层原理**（面试深挖点）：

1. **默认同步执行**：`publishEvent` 在调用线程同步调用所有监听器，监听器抛异常会向上传播。需要异步时在监听方法上加 `@Async`，或让事件实现 `ApplicationEventMulticaster` 异步广播。
2. **继承关系匹配**：监听器监听父类事件也能收到子类事件，Spring 通过 `ResolvableType` 做类型匹配。
3. **@TransactionalEventListener**：可以指定事务阶段（`AFTER_COMMIT` 等），事务提交后才触发监听，解决「事务未提交就发事件，监听方查不到数据」的经典坑。

### 2. MQ 发布订阅：跨进程的观察者

当「观察者」分布在不同服务时，观察者模式自然演化为消息队列的发布订阅：

```java
// 生产者：发布订单事件到 Kafka
@RestController
public class OrderController {
    @Autowired
    private KafkaTemplate<String, String> kafkaTemplate;

    @PostMapping("/order")
    public void create(@RequestBody Order order) {
        kafkaTemplate.send("order-topic", JSON.toJSONString(order));
    }
}

// 消费者：短信服务订阅
@KafkaListener(topics = "order-topic", groupId = "sms-group")
public void onOrder(String message) {
    // 发短信
}

// 消费者：积分服务订阅，互不影响
@KafkaListener(topics = "order-topic", groupId = "points-group")
public void onOrder2(String message) {
    // 加积分
}
```

**什么时候用 Spring Event，什么时候用 MQ？**

- 同 JVM 内、非核心链路、可以同步 → 优先 Spring Event（轻量、无额外依赖、调试方便）
- 跨服务、需要削峰、需要可靠投递（重试/死信）、需要解耦生命周期 → 用 MQ
- 一个常见坑：**把 Spring Event 当作事务的一部分，监听器里做重业务**，会导致请求变慢。正确的姿势是监听器只做「事件驱动」的轻量联动，重逻辑放 MQ 异步。

---

## 手写一个通用事件总线（观察者模式实战）

自己实现一个线程安全的简易事件总线，能体现对模式的深入理解：

```java
public class SimpleEventBus {
    // 事件类型 -> 监听器集合
    private final Map<Class<?>, List<Consumer<Object>>> listeners = new ConcurrentHashMap<>();

    public <T> void register(Class<T> eventType, Consumer<T> listener) {
        listeners.computeIfAbsent(eventType, k -> new CopyOnWriteArrayList<>())
                 .add(e -> listener.accept((T) e));
    }

    public void post(Object event) {
        List<Consumer<Object>> list = listeners.get(event.getClass());
        if (list != null) {
            list.forEach(l -> l.accept(event));
        }
    }

    public static void main(String[] args) {
        SimpleEventBus bus = new SimpleEventBus();
        bus.register(OrderEvent.class, e -> System.out.println("短信：" + e.getOrderId()));
        bus.register(OrderEvent.class, e -> System.out.println("优惠券：" + e.getOrderId()));
        bus.post(new OrderEvent(1001L, new BigDecimal("99.00")));
    }
}
```

这里用 `ConcurrentHashMap + CopyOnWriteArrayList` 保证并发安全，用泛型 + 函数式接口简化 API。实际项目中如果不想引入 Guava EventBus，这样 50 行就能搞定一个够用的事件总线。

---

## 观察者模式最佳实践与避坑指南

### ✅ 最佳实践

1. **一个事件一个职责**：事件类字段要完备（携带上下文），不要图省事直接传 Map。
2. **监听器保持幂等**：事件可能被重发（MQ 重试），监听器逻辑必须幂等。
3. **关注点分离**：监听器里不要再发同类事件，容易造成事件风暴/循环调用。
4. **异步要控制线程池**：`@Async` 默认用 `SimpleAsyncTaskExecutor`（每次新建线程），生产环境务必自定义线程池。

### ❌ 常见坑

| 坑 | 现象 | 解决方案 |
|----|------|---------|
| 监听器异常导致主流程失败 | 发短信失败，订单创建报错 | 监听器内 try-catch，或使用 `@Async` + 自定义异常处理 |
| 事件在事务提交前发出 | 监听器查不到刚插入的数据 | `@TransactionalEventListener(phase = AFTER_COMMIT)` |
| 循环事件 | A 事件触发 B，B 又触发 A，死循环 | 设计时梳理事件依赖图，加防重入标记 |
| 同步监听器拖慢接口 | 接口 RT 变长 | 评估是否改异步/MQ，或拆分监听器职责 |
| 内存泄漏 | 监听器注册后未注销（尤其静态/长生命周期对象） | 生命周期匹配：单例监听单例，Bean 由 Spring 管理即可避免 |

---

## 面试追问清单

1. **观察者模式和发布订阅模式的区别？** → 耦合度、通信方式、进程边界（见开头表格）。
2. **Spring 事件默认是同步还是异步？如何改异步？** → 默认同步；监听器加 `@Async` 或配置 `ApplicationEventMulticaster` 的 `setTaskExecutor`。
3. **@TransactionalEventListener 解决了什么问题？** → 事务提交时机与事件触发的错位问题，避免监听器读到未提交数据。
4. **观察者模式违反了哪些原则、遵循了哪些原则？** → 遵循开闭原则（新增观察者不改主题）、依赖倒置（依赖抽象接口）；但观察者之间顺序依赖时可能引入隐式耦合。
5. **JDK 的 Observable 为什么被废弃？** → 序列化问题、API 设计不佳（setChanged 是 protected 等）、不支持泛型、事件通知顺序不受控。

观察者模式是「事件驱动架构」的最小原型：从手写 Listener 到 Spring Event，再到跨服务的 MQ 发布订阅，本质都是「状态变化 → 通知感兴趣的一方」。理解透这个模式，你就理解了消息驱动架构的一半。
