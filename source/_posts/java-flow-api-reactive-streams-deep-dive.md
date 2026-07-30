---
title: 【并发编程】Java 9+ Flow API 深度解析：JDK 内置的响应式流（Reactive Streams）全面实战
date: 2026-07-30 08:00:00
tags:
  - Java
  - 并发
  - Flow API
  - 响应式编程
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】Java 9+ Flow API 深度解析：JDK 内置的响应式流全面实战

## 前言：响应式革命与 JDK 的回应

> 面试官：你知道 Java 9 引入的 Flow API 吗？它和 Project Reactor、RxJava 有什么关系？

响应式编程（Reactive Programming）在 Java 生态中越来越重要。Spring WebFlux、Vert.x、RSocket 等框架都基于响应式流规范。但在 Java 9 之前，响应式编程的核心规范 **Reactive Streams** 只是一个外部规范，由 `org.reactivestreams` 包定义。

Java 9 将 Reactive Streams 规范直接纳入了 JDK，以 `java.util.concurrent.Flow` 类的形式出现。这意味着**不需要任何第三方依赖**，你就可以在 JDK 原生 API 中使用响应式流。

## 一、核心接口体系

`java.util.concurrent.Flow` 定义了四个核心接口：

```java
public final class Flow {
    
    // 1. 发布者 - 产生数据
    @FunctionalInterface
    public static interface Publisher<T> {
        void subscribe(Subscriber<? super T> subscriber);
    }
    
    // 2. 订阅者 - 消费数据
    public static interface Subscriber<T> {
        void onSubscribe(Subscription subscription);
        void onNext(T item);
        void onError(Throwable throwable);
        void onComplete();
    }
    
    // 3. 订阅关系 - 控制流量
    public static interface Subscription {
        void request(long n);       // 请求 n 个元素
        void cancel();              // 取消订阅
    }
    
    // 4. 处理器 - 既是发布者又是订阅者
    public static interface Processor<T, R> 
        extends Subscriber<T>, Publisher<R> {
    }
}
```

### 1.1 协议核心：背压（Backpressure）

响应式流的核心在于 **背压**（Backpressure）——订阅者告诉发布者自己能处理多少数据，防止发布者"淹没"订阅者。

```
Publisher(发布者)          Subscriber(订阅者)
    │                            │
    │── subscribe() ────────────→│
    │←──── onSubscribe(sub) ────│
    │←──── request(n) ──────────│  ← 订阅者控制流量
    │── onNext(item) ──────────→│
    │── onNext(item) ──────────→│
    │←──── request(n) ──────────│  ← 处理完后再请求
    │── onNext(item) ──────────→│
    │── onComplete() ──────────→│
```

## 二、从零实现响应式流

### 2.1 自定义发布者

```java
public class SimplePublisher<T> implements Flow.Publisher<T> {
    
    private final List<T> data;
    
    public SimplePublisher(List<T> data) {
        this.data = new ArrayList<>(data);
    }
    
    @Override
    public void subscribe(Flow.Subscriber<? super T> subscriber) {
        // 每个订阅者获得独立的数据副本
        subscriber.onSubscribe(new SimpleSubscription<>(subscriber, data));
    }
    
    // 内部订阅类
    private static class SimpleSubscription<T> implements Flow.Subscription {
        private final Flow.Subscriber<? super T> subscriber;
        private final List<T> data;
        private final AtomicLong requested = new AtomicLong(0);
        private volatile boolean cancelled = false;
        private int index = 0;
        
        SimpleSubscription(Flow.Subscriber<? super T> subscriber, List<T> data) {
            this.subscriber = subscriber;
            this.data = data;
        }
        
        @Override
        public void request(long n) {
            if (n <= 0) {
                subscriber.onError(
                    new IllegalArgumentException("request must be positive"));
                return;
            }
            
            // 累加请求量
            requested.addAndGet(n);
            drainLoop();
        }
        
        @Override
        public void cancel() {
            cancelled = true;
        }
        
        private void drainLoop() {
            while (!cancelled && index < data.size() && requested.get() > 0) {
                subscriber.onNext(data.get(index++));
                requested.decrementAndGet();
            }
            
            // 数据全部发送完毕
            if (!cancelled && index >= data.size()) {
                subscriber.onComplete();
            }
        }
    }
}
```

### 2.2 自定义订阅者

```java
public class PrintSubscriber<T> implements Flow.Subscriber<T> {
    
    private Flow.Subscription subscription;
    private final String name;
    
    public PrintSubscriber(String name) {
        this.name = name;
    }
    
    @Override
    public void onSubscribe(Flow.Subscription subscription) {
        this.subscription = subscription;
        System.out.println(name + " 订阅成功");
        // 首次请求 3 个元素
        subscription.request(3);
    }
    
    @Override
    public void onNext(T item) {
        System.out.println(name + " 收到: " + item + " (线程: " 
            + Thread.currentThread().getName() + ")");
        
        // 模拟慢消费者：处理完后再请求下一个
        try {
            Thread.sleep(100);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        
        // 每次只请求 1 个，严格限制速率
        subscription.request(1);
    }
    
    @Override
    public void onError(Throwable throwable) {
        System.err.println(name + " 错误: " + throwable.getMessage());
    }
    
    @Override
    public void onComplete() {
        System.out.println(name + " 收到所有数据");
    }
}
```

### 2.3 测试运行

```java
public class FlowDemo {
    public static void main(String[] args) throws InterruptedException {
        List<Integer> data = IntStream.rangeClosed(1, 20)
                                      .boxed()
                                      .collect(Collectors.toList());
        
        SimplePublisher<Integer> publisher = new SimplePublisher<>(data);
        
        publisher.subscribe(new PrintSubscriber<>("订阅者A"));
        publisher.subscribe(new PrintSubscriber<>("订阅者B"));
        
        // 等待异步处理完成
        Thread.sleep(5000);
    }
}
```

## 三、JDK 内置的 Flow 工具

### 3.1 SubmissionPublisher — JDK 内置的发布者

JDK 自带了 `SubmissionPublisher` 实现，提供了线程安全的发布机制：

```java
public class SubmissionPublisherExample {
    
    public static void main(String[] args) throws InterruptedException {
        // 创建发布者：缓冲池大小 32，使用 ForkJoinPool
        SubmissionPublisher<String> publisher = new SubmissionPublisher<>();
        
        // 注册订阅者
        publisher.subscribe(new PrintSubscriber<>("订阅者1"));
        publisher.subscribe(new PrintSubscriber<>("订阅者2"));
        
        System.out.println("开始发布消息...");
        
        // 发布数据
        for (int i = 1; i <= 10; i++) {
            String item = "消息-" + i;
            int delay = publisher.offer(
                item,
                (subscriber, msg) -> {
                    // 背压处理：当订阅者跟不上时，此回调触发
                    System.out.println("背压！丢弃消息: " + msg);
                    return false; // 返回 false 表示丢弃
                }
            );
            
            if (delay < 0) {
                System.out.println("提交成功");
            } else if (delay == 0) {
                System.out.println("缓冲区满，消息被丢弃");
            } else {
                System.out.println("缓冲区满，等待 " + delay + "ms");
            }
            
            Thread.sleep(50);
        }
        
        // 关闭发布者
        publisher.close();
        
        // 等待所有订阅者处理完成
        Thread.sleep(3000);
    }
}
```

**SubmissionPublisher 核心特性：**

| 特性 | 说明 |
|------|------|
| 线程安全 | 支持多线程并发提交 |
| 背压感知 | 阻塞直到消费者可以接收 |
| 缓冲机制 | 内部有缓冲区，可配置大小 |
| 可关闭 | close() 后发送 onComplete |
| 自动管理 | 使用 ForkJoinPool 执行 |

### 3.2 背压控制策略

`SubmissionPublisher` 提供了三种提交方式：

```java
// 方式一：submit() — 阻塞直到可以提交
publisher.submit("data"); // 如果缓冲区满，阻塞等待

// 方式二：offer() — 非阻塞，自定义降级
publisher.offer("data", 1, TimeUnit.SECONDS, 
    (subscriber, data) -> {
        System.out.println("订阅者" + subscriber + "太慢，丢弃: " + data);
        return true; // true = 不再尝试此订阅者
    }
);

// 方式三：trySubmit() — 非阻塞，失败立即返回
int result = publisher.offer("data", 
    (subscriber, data) -> false // 背压时直接丢弃
);
// 返回值: 正数=成功, 0=丢失, 负数=拒绝
```

## 四、Processor 实现 —— 数据转换器

Processor 同时是 Subscriber 和 Publisher，可以实现数据转换：

```java
public class TransformProcessor<T, R> 
    implements Flow.Processor<T, R> {
    
    private final SubmissionPublisher<R> publisher = new SubmissionPublisher<>();
    private Flow.Subscription subscription;
    private final Function<T, R> transformer;
    
    public TransformProcessor(Function<T, R> transformer) {
        this.transformer = transformer;
    }
    
    @Override
    public void subscribe(Flow.Subscriber<? super R> subscriber) {
        publisher.subscribe(subscriber);
    }
    
    @Override
    public void onSubscribe(Flow.Subscription subscription) {
        this.subscription = subscription;
        subscription.request(Long.MAX_VALUE); // 无限制拉取
    }
    
    @Override
    public void onNext(T item) {
        try {
            R result = transformer.apply(item);
            publisher.submit(result);
        } catch (Exception e) {
            publisher.closeExceptionally(e);
        }
    }
    
    @Override
    public void onError(Throwable throwable) {
        publisher.closeExceptionally(throwable);
    }
    
    @Override
    public void onComplete() {
        publisher.close();
    }
}

// 使用示例
public class ProcessorDemo {
    public static void main(String[] args) throws InterruptedException {
        SubmissionPublisher<Integer> source = new SubmissionPublisher<>();
        
        // 创建处理器：整数 → 字符串
        TransformProcessor<Integer, String> processor = 
            new TransformProcessor<>(i -> "数字: " + i);
        
        // 链式连接
        source.subscribe(processor);
        processor.subscribe(new PrintSubscriber<>("最终消费者"));
        
        // 发布数据
        source.submit(100);
        source.submit(200);
        source.submit(300);
        
        source.close();
        Thread.sleep(2000);
    }
}
```

## 五、实际应用场景

### 5.1 日志收集系统

```java
public class LogStreamCollector {
    
    private final SubmissionPublisher<LogEvent> publisher = new SubmissionPublisher<>();
    private final Map<String, Flow.Subscription> subscriptions = new ConcurrentHashMap<>();
    
    // 多消费者模型：同一份日志流同时被多个子系统消费
    public void startCollecting() {
        // 告警消费者
        publisher.subscribe(new AlertSubscriber());
        // 持久化消费者
        publisher.subscribe(new PersistenceSubscriber());
        // 实时监控消费者
        publisher.subscribe(new MetricsSubscriber());
    }
    
    public void ingest(LogEvent event) {
        publisher.submit(event);
    }
}

class AlertSubscriber implements Flow.Subscriber<LogEvent> {
    @Override
    public void onNext(LogEvent event) {
        if (event.level() == LogLevel.ERROR || event.level() == LogLevel.FATAL) {
            sendAlert(event);
        }
    }
}
```

### 5.2 数据管道

```java
// 构建处理流水线：原始数据 → 清洗 → 转换 → 加载
public class ETLPipeline {
    
    public void execute() {
        SubmissionPublisher<RawData> source = new SubmissionPublisher<>();
        
        // 清洗阶段
        TransformProcessor<RawData, RawData> cleaner = 
            new TransformProcessor<>(this::cleanData);
        
        // 转换阶段
        TransformProcessor<RawData, ProcessedData> transformer = 
            new TransformProcessor<>(this::transformData);
        
        // 加载阶段（最终消费者）
        LoadSubscriber loader = new LoadSubscriber();
        
        // 链式串联
        source.subscribe(cleaner);
        cleaner.subscribe(transformer);
        transformer.subscribe(loader);
        
        // 输入数据
        for (RawData data : fetchRawData()) {
            source.submit(data);
        }
        source.close();
    }
}
```

## 六、与外部响应式框架的关系

### 6.1 兼容性

Flow API 与 Reactive Streams 规范**完全兼容**：

```
java.util.concurrent.Flow.Publisher
    → org.reactivestreams.Publisher（100% 方法签名一致）
    
Project Reactor:  Flux/Flux 实现了 Flow.Publisher
RxJava 3:         Flowable 实现了 Flow.Publisher
Spring WebFlux:   基于 Reactor，兼容 Flow API
```

这意味着你可以这样做：

```java
// Reactor Flux 可以直接与 Flow API 交互
Flux<Integer> flux = Flux.just(1, 2, 3);

// 直接转换为 Flow.Publisher
Flow.Publisher<Integer> flowPublisher = flux;
flowPublisher.subscribe(new PrintSubscriber<>());

// 也可以反过来
SubmissionPublisher<String> pub = new SubmissionPublisher<>();
Flux.from(pub).map(String::toUpperCase).subscribe(System.out::println);
```

### 6.2 定位差异

| 功能 | JDK Flow API | Project Reactor | RxJava 3 |
|------|-------------|----------------|----------|
| 基础规范 | ✅ 核心接口 | ✅ 实现 | ✅ 实现 |
| 大量操作符 | ❌ | ✅ 500+ | ✅ 400+ |
| 调度器 | ❌（仅 ForkJoinPool） | ✅ | ✅ |
| 错误处理 | ❌ | ✅ | ✅ |
| 重试机制 | ❌ | ✅ | ✅ |
| 背压策略 | ✅ 基础 | ✅ 丰富 | ✅ 丰富 |
| 学习曲线 | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |

**使用建议：**
- 简单的背压控制 → JDK Flow API
- 复杂的响应式数据管道 → Project Reactor 或 RxJava
- 框架内部集成 → 使用 Flow API 保证兼容性

## 七、最佳实践与注意事项

### 7.1 Subscription.request() 的幂等性

```java
// request() 调用必须是线程安全的，且累计请求数量
private final AtomicLong requested = new AtomicLong(0);

// 竞态条件示范：request() 和 onNext() 可能在不同线程执行
public void request(long n) {
    requested.addAndGet(n);
    drain(); // 可能和另一个线程的 drain() 同时执行
}
```

### 7.2 线程模型

`SubmissionPublisher` 默认使用 `ForkJoinPool.commonPool()` 执行异步任务：

```java
// 自定义线程池
Executor executor = Executors.newFixedThreadPool(4);
SubmissionPublisher<String> publisher = 
    new SubmissionPublisher<>(executor, Flow.defaultBufferSize());
```

### 7.3 常见陷阱

```java
// ❌ 错误：在 onNext 中阻塞
@Override
public void onNext(Data data) {
    Thread.sleep(1000); // 阻塞了整个线程池！
    subscription.request(1);
}

// ✅ 正确：使用异步边界
@Override
public void onNext(Data data) {
    executor.submit(() -> {
        process(data);     // 放入独立线程池处理
        subscription.request(1);
    });
}
```

## 总结

Java Flow API 是 **Reactive Streams 规范在 JDK 中的标准化**。它不是一个功能完备的响应式框架，而是一个**底层基础设施**。

```
你的定位：
JDK Flow API   = 响应式流的"接口规范 + 基础实现"
Project Reactor = 完整的响应式编程框架
```

理解 Flow API 的核心价值在于：当你看到任何实现 `Flow.Publisher` 的库时，你就知道它支持标准的背压协议。在现代 Java 开发中，这项基础知识已经和了解 `Collection`、`Stream` 一样重要。
