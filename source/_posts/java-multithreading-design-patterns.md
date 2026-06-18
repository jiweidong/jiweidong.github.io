---
title: Java 多线程设计模式详解
date: 2026-06-18 08:00:00
tags:
  - Java
  - 多线程
  - 设计模式
  - 并发编程
categories:
  - Java 进阶
author: 东哥
---

# Java 多线程设计模式详解

## 一、引言

多线程设计模式是 Java 并发编程的精髓。它们不仅解决了特定的并发问题，更体现了经过验证的并发编程思想。Doug Lea 的《Java Concurrency in Practice》和《Concurrent Programming in Java》中系统总结了大量并发设计模式。本文将深入剖析 10 种最实用的 Java 多线程设计模式，配合大量代码示例和实际应用场景。

## 二、Immutable Object（不可变对象）

### 2.1 模式概述

不可变对象模式是最简单也是最有效的线程安全策略——既然对象状态不能被修改，自然不存在竞态条件。

### 2.2 实现要点

```java
public final class ImmutableOrder {  // 1. final 类防止子类化
    
    private final String orderId;          // 2. final 字段
    private final long userId;
    private final BigDecimal amount;
    private final List<OrderItem> items;   // 3. 不可变集合
    private final Instant createdAt;

    public ImmutableOrder(String orderId, long userId, BigDecimal amount, List<OrderItem> items) {
        this.orderId = orderId;
        this.userId = userId;
        this.amount = amount;
        // 4. 防御性拷贝
        this.items = items.stream()
                .map(item -> new OrderItem(item.productId(), item.quantity(), item.price()))
                .collect(Collectors.toUnmodifiableList());
        this.createdAt = Instant.now();
    }
    
    // 5. 只有 getter，没有 setter
    public String getOrderId() { return orderId; }
    
    // 6. 返回不可变数据或防御性拷贝
    public List<OrderItem> getItems() {
        return items; // 已经是 unmodifiableList
    }
    
    // 7. 修改操作返回新对象
    public ImmutableOrder withNewItem(OrderItem item) {
        List<OrderItem> newItems = new ArrayList<>(this.items);
        newItems.add(item);
        return new ImmutableOrder(this.orderId, this.userId, this.amount, newItems);
    }
}
```

### 2.3 Record 实现

```java
// Java 16+ Record 天然支持不可变
public record OrderRecord(String orderId, long userId, BigDecimal amount,
                         List<OrderItem> items, Instant createdAt) {
    
    // 紧凑构造函数中的防御性拷贝
    public OrderRecord {
        items = List.copyOf(items);  // 不可变副本
    }
}
```

### 2.4 应用场景

| 场景 | 说明 | 示例 |
|------|------|------|
| 配置对象 | 加载后不再修改的系统配置 | Spring @ConfigurationProperties |
| 值对象 | DTO、查询结果 | 订单 VO、用户信息 |
| 缓存键 | HashMap 的 key | 不可变对象 hashCode 稳定 |
| 消息体 | 跨线程传递的消息 | Event 对象 |

## 三、Guarded Suspension（保护性暂停）

### 3.1 模式概述

Guarded Suspension 模式的核心思想是：当条件不满足时，线程主动等待，直到条件满足后被唤醒。

### 3.2 经典实现

```java
public class GuardedQueue<T> {
    
    private final Queue<T> queue = new LinkedList<>();
    
    public synchronized void put(T item) {
        queue.add(item);
        notifyAll();  // 唤醒等待的消费者
    }
    
    public synchronized T take() throws InterruptedException {
        while (queue.isEmpty()) {  // 必须用 while 循环检查
            wait();  // 条件不满足，等待
        }
        return queue.poll();
    }
}

// 带超时的版本
public synchronized T take(long timeout, TimeUnit unit) 
        throws InterruptedException {
    long deadline = System.nanoTime() + unit.toNanos(timeout);
    long remaining = unit.toNanos(timeout);
    
    while (queue.isEmpty() && remaining > 0) {
        wait(remaining / 1_000_000, (int)(remaining % 1_000_000));
        remaining = deadline - System.nanoTime();
    }
    return queue.poll();
}
```

### 3.3 使用 Lock/Condition

```java
public class ConditionBoundedQueue<T> {
    private final Lock lock = new ReentrantLock();
    private final Condition notEmpty = lock.newCondition();
    private final Queue<T> queue = new LinkedList<>();
    private final int capacity;
    
    public ConditionBoundedQueue(int capacity) {
        this.capacity = capacity;
    }
    
    public void put(T item) throws InterruptedException {
        lock.lock();
        try {
            while (queue.size() >= capacity) {
                notEmpty.await();  // 等待不满
            }
            queue.add(item);
            notEmpty.signalAll(); // 唤醒消费者
        } finally {
            lock.unlock();
        }
    }
    
    public T take() throws InterruptedException {
        lock.lock();
        try {
            while (queue.isEmpty()) {
                notEmpty.await();  // 等待不空
            }
            T item = queue.poll();
            notEmpty.signalAll(); // 唤醒生产者
            return item;
        } finally {
            lock.unlock();
        }
    }
}
```

## 四、Two-Phase Termination（两阶段终止）

### 4.1 模式概述

优雅地终止线程：第一阶段发出终止信号，第二阶段等待线程清理资源后自行结束。

### 4.2 实现示例

```java
public class BackgroundTaskRunner {
    private volatile boolean shutdown = false;  // 终止标志
    private final Thread workerThread;
    
    public BackgroundTaskRunner() {
        workerThread = new Thread(this::run, "background-worker");
    }
    
    public void start() {
        workerThread.start();
    }
    
    // 第一阶段：发出终止信号
    public void shutdown() {
        System.out.println("发送终止信号...");
        shutdown = true;
        workerThread.interrupt();  // 中断等待中的操作
    }
    
    // 第二阶段：等待线程完成清理
    public void awaitTermination(long timeout, TimeUnit unit) 
            throws InterruptedException {
        workerThread.join(unit.toMillis(timeout));
        if (workerThread.isAlive()) {
            System.err.println("线程未能在超时内终止");
        }
    }
    
    private void run() {
        try {
            while (!shutdown && !Thread.currentThread().isInterrupted()) {
                doWork();
            }
        } finally {
            cleanup();  // 清理资源
            System.out.println("工作线程已终止");
        }
    }
    
    private void doWork() {
        try {
            // 模拟阻塞操作
            Thread.sleep(1000);
            System.out.println("执行工作任务...");
        } catch (InterruptedException e) {
            System.out.println("工作中断，准备终止");
            Thread.currentThread().interrupt(); // 恢复中断状态
        }
    }
    
    private void cleanup() {
        System.out.println("清理资源：关闭连接、释放锁等");
    }
}
```

### 4.3 高级：线程池优雅关闭

```java
public class ThreadPoolGracefulShutdown {
    
    private final ThreadPoolExecutor executor;
    
    public ThreadPoolGracefulShutdown(int corePoolSize, int maxPoolSize) {
        this.executor = new ThreadPoolExecutor(
            corePoolSize, maxPoolSize,
            60, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(1000),
            new ThreadFactoryBuilder().setNameFormat("worker-%d").build()
        );
    }
    
    public void shutdown() {
        System.out.println("=== 开始优雅关闭线程池 ===");
        
        executor.shutdown();  // 不再接受新任务
        
        try {
            // 等待已有任务完成
            if (!executor.awaitTermination(30, TimeUnit.SECONDS)) {
                System.out.println("强制关闭未完成的任务");
                executor.shutdownNow();  // 强制中断
                
                if (!executor.awaitTermination(30, TimeUnit.SECONDS)) {
                    System.err.println("线程池无法正常关闭");
                }
            }
        } catch (InterruptedException e) {
            executor.shutdownNow();
            Thread.currentThread().interrupt();
        }
        
        System.out.println("=== 线程池已关闭 ===");
    }
}
```

## 五、Producer-Consumer（生产者-消费者）

### 5.1 模式概述

生产者-消费者模式通过缓冲区解耦生产者和消费者，是最经典的并发设计模式之一。

### 5.2 BlockingQueue 实现

```java
public class OrderProcessingSystem {
    
    private static final int CAPACITY = 100;
    private final BlockingQueue<Order> queue = new LinkedBlockingQueue<>(CAPACITY);
    private final AtomicInteger orderCounter = new AtomicInteger(0);
    
    // 生产者
    public void produceOrders(int count) {
        CompletableFuture<?>[] futures = new CompletableFuture[count];
        for (int i = 0; i < count; i++) {
            futures[i] = CompletableFuture.runAsync(() -> {
                try {
                    Order order = createOrder();
                    queue.put(order);
                    System.out.printf("[生产者-%s] 创建订单: %s (队列大小: %d)%n",
                            Thread.currentThread().getName(), 
                            order.orderId(), queue.size());
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            });
        }
        CompletableFuture.allOf(futures).join();
    }
    
    // 消费者
    public void consumeOrders(int workerCount) {
        for (int i = 0; i < workerCount; i++) {
            Thread worker = new Thread(() -> {
                try {
                    while (!Thread.currentThread().isInterrupted()) {
                        Order order = queue.take();
                        processOrder(order);
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }, "consumer-" + i);
            worker.start();
        }
    }
    
    private Order createOrder() {
        int id = orderCounter.incrementAndGet();
        return new Order(String.format("ORD-%06d", id), 
                        ThreadLocalRandom.current().nextLong(1000, 9999),
                        BigDecimal.valueOf(ThreadLocalRandom.current().nextDouble(100, 9999)));
    }
    
    private void processOrder(Order order) {
        // 模拟订单处理
        System.out.printf("[消费者-%s] 处理订单: %s%n",
                Thread.currentThread().getName(), order.orderId());
    }
    
    record Order(String orderId, long userId, BigDecimal amount) {}
}
```

### 5.3 多生产者多消费者对比

| 方案 | 吞吐量 | 公平性 | 适用场景 |
|------|-------|--------|---------|
| SynchronousQueue | 低 | 直接交付 | 高并发单对单 |
| LinkedBlockingQueue | 高 | 默认非公平 | 大部分场景 |
| ArrayBlockingQueue | 中 | 可选公平 | 固定容量 |
| PriorityBlockingQueue | 中 | 优先级排序 | 任务优先级 |
| LinkedTransferQueue | 高 | 直接传递 | 高吞吐即时消费 |

## 六、Read-Write Lock（读写锁）

### 6.1 模式概述

读写锁允许多个读线程并发访问，但写线程独占资源。适用于读多写少的场景。

### 6.2 缓存实现

```java
public class ConcurrentCache<K, V> {
    
    private final ReadWriteLock lock = new ReentrantReadWriteLock();
    private final Lock readLock = lock.readLock();
    private final Lock writeLock = lock.writeLock();
    private final Map<K, V> cache = new HashMap<>();
    private final Map<K, Instant> expiryMap = new HashMap<>();
    private final long ttlMillis;
    
    public ConcurrentCache(long ttlMillis) {
        this.ttlMillis = ttlMillis;
    }
    
    public V get(K key) {
        readLock.lock();
        try {
            V value = cache.get(key);
            if (value != null && isExpired(key)) {
                // 读锁中不能执行写操作，使用双重检查
                readLock.unlock();
                writeLock.lock();
                try {
                    // 双重检查
                    if (cache.containsKey(key) && isExpired(key)) {
                        cache.remove(key);
                        expiryMap.remove(key);
                        return null;
                    }
                    return cache.get(key);
                } finally {
                    writeLock.unlock();
                    readLock.lock();
                }
            }
            return value;
        } finally {
            readLock.unlock();
        }
    }
    
    public void put(K key, V value) {
        writeLock.lock();
        try {
            cache.put(key, value);
            expiryMap.put(key, Instant.now().plusMillis(ttlMillis));
        } finally {
            writeLock.unlock();
        }
    }
    
    public void clear() {
        writeLock.lock();
        try {
            cache.clear();
            expiryMap.clear();
        } finally {
            writeLock.unlock();
        }
    }
    
    private boolean isExpired(K key) {
        Instant expiry = expiryMap.get(key);
        return expiry != null && Instant.now().isAfter(expiry);
    }
}
```

## 七、Thread Pool（线程池）

### 7.1 自定义线程池

```java
public class PriorityThreadPool {
    
    private final ThreadPoolExecutor executor;
    
    public PriorityThreadPool(int coreSize, int maxSize) {
        this.executor = new ThreadPoolExecutor(
            coreSize, maxSize,
            60L, TimeUnit.SECONDS,
            new PriorityBlockingQueue<>(1000),       // 优先级队列
            new ThreadFactoryBuilder()
                .setNameFormat("priority-worker-%d")
                .setDaemon(true)
                .build(),
            (r, e) -> {
                // 拒绝策略：将任务提交到调用者线程执行
                if (!e.isShutdown()) {
                    r.run();
                }
            }
        );
        // 允许核心线程超时
        executor.allowCoreThreadTimeOut(true);
    }
    
    public <T> CompletableFuture<T> submit(Callable<T> task, int priority) {
        var future = new CompletableFuture<T>();
        executor.execute(new PriorityTask<>(task, priority, future));
        return future;
    }
    
    record PriorityTask<T>(Callable<T> task, int priority, 
                          CompletableFuture<T> future) 
            implements Comparable<PriorityTask<T>>, Runnable {
        
        @Override
        public int compareTo(PriorityTask<T> other) {
            return Integer.compare(other.priority, this.priority);
        }
        
        @Override
        public void run() {
            try {
                T result = task.call();
                future.complete(result);
            } catch (Exception e) {
                future.completeExceptionally(e);
            }
        }
    }
}
```

### 7.2 虚拟线程适配

```java
// Java 21+ 虚拟线程
public class VirtualThreadPool {
    
    private final ExecutorService executor;
    
    public VirtualThreadPool() {
        this.executor = Executors.newVirtualThreadPerTaskExecutor();
    }
    
    public void execute(Runnable task) {
        executor.execute(task);
    }
    
    // 虚拟线程 + 结构化并发
    public <T> List<T> executeAll(List<Callable<T>> tasks) throws Exception {
        try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
            List<StructuredTaskScope.Subtask<T>> subtasks = tasks.stream()
                .map(scope::fork)
                .toList();
            
            scope.join();
            scope.throwIfFailed();
            
            return subtasks.stream()
                .map(StructuredTaskScope.Subtask::get)
                .toList();
        }
    }
}
```

## 八、Future & Promise

### 8.1 异步结果模式

```java
public class AsyncOrderService {
    
    private final ExecutorService executor = Executors.newFixedThreadPool(10);
    
    // 基本 Future
    public Future<OrderResult> getOrderAsync(String orderId) {
        return executor.submit(() -> {
            Thread.sleep(1000);  // 模拟查询延迟
            return new OrderResult(orderId, "COMPLETED", BigDecimal.valueOf(199.99));
        });
    }
    
    // CompletableFuture 链式调用
    public CompletableFuture<OrderDetail> getOrderDetailAsync(String orderId) {
        return CompletableFuture.supplyAsync(() -> getBasicInfo(orderId))
            .thenCombine(
                CompletableFuture.supplyAsync(() -> getItems(orderId)),
                (basic, items) -> new OrderDetail(basic, items)
            )
            .thenApply(detail -> enrichWithDiscount(detail))
            .exceptionally(throwable -> {
                log.error("获取订单详情失败: {}", orderId, throwable);
                return OrderDetail.empty();
            })
            .orTimeout(5, TimeUnit.SECONDS)
            .whenComplete((result, ex) -> {
                if (ex != null) {
                    log.warn("订单 {} 查询超时", orderId);
                }
            });
    }
    
    // 合并多个异步结果
    public CompletableFuture<OrderAggregation> aggregateOrderData(List<String> orderIds) {
        List<CompletableFuture<OrderDetail>> futures = orderIds.stream()
            .map(this::getOrderDetailAsync)
            .toList();
        
        return CompletableFuture.allOf(futures.toArray(new CompletableFuture[0]))
            .thenApply(v -> futures.stream()
                .map(CompletableFuture::join)
                .collect(Collectors.collectingAndThen(
                    Collectors.toList(),
                    OrderAggregation::new
                )));
    }
}
```

## 九、Balking（犹豫模式）

### 9.1 模式概述

当操作不满足条件时，直接放弃操作而不是等待。

```java
public class DatabaseInitializer {
    private volatile boolean initialized = false;
    private volatile boolean initializing = false;
    
    public boolean initialize() {
        if (initialized) {
            return true;  // 已初始化，直接返回
        }
        
        synchronized (this) {
            if (initialized) {
                return true;  // 双重检查
            }
            if (initializing) {
                return false;  // 其他线程正在初始化，放弃
            }
            
            initializing = true;
        }
        
        // 执行初始化（在同步块外执行以避免阻塞）
        try {
            doInitialize();
            initialized = true;
            return true;
        } catch (Exception e) {
            log.error("初始化失败", e);
            return false;
        } finally {
            initializing = false;
        }
    }
    
    private void doInitialize() {
        // 打开数据库连接、加载驱动等
    }
}
```

## 十、Scheduler（调度器模式）

### 10.1 定时任务调度

```java
public class CronScheduler {
    
    private final ScheduledExecutorService scheduler = 
        Executors.newScheduledThreadPool(4);
    private final Map<String, ScheduledFuture<?>> tasks = new ConcurrentHashMap<>();
    
    // 固定频率执行
    public void scheduleAtFixedRate(String taskId, Runnable task,
                                    long initialDelay, long period, TimeUnit unit) {
        ScheduledFuture<?> future = scheduler.scheduleAtFixedRate(
            wrapWithLogging(task), initialDelay, period, unit);
        tasks.put(taskId, future);
    }
    
    // Cron 表达式调度
    public void scheduleWithCron(String taskId, Runnable task, String cronExpression) {
        CronTrigger trigger = new CronTrigger(cronExpression);
        scheduler.schedule(wrapWithLogging(task), 
            trigger.nextExecutionTime(), TimeUnit.MILLISECONDS);
    }
    
    public boolean cancel(String taskId) {
        ScheduledFuture<?> future = tasks.remove(taskId);
        if (future != null) {
            return future.cancel(false);
        }
        return false;
    }
    
    private Runnable wrapWithLogging(Runnable task) {
        return () -> {
            try {
                long start = System.currentTimeMillis();
                task.run();
                long duration = System.currentTimeMillis() - start;
                log.info("任务执行完成，耗时: {}ms", duration);
            } catch (Exception e) {
                log.error("任务执行异常", e);
            }
        };
    }
    
    public void shutdown() {
        scheduler.shutdown();
        try {
            if (!scheduler.awaitTermination(30, TimeUnit.SECONDS)) {
                scheduler.shutdownNow();
            }
        } catch (InterruptedException e) {
            scheduler.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }
}
```

### 10.2 延迟队列实现

```java
public class DelayedTaskScheduler {
    
    private final DelayQueue<DelayedTask> delayQueue = new DelayQueue<>();
    private final ExecutorService executor = Executors.newFixedThreadPool(4);
    
    public void start() {
        Thread consumerThread = new Thread(() -> {
            try {
                while (!Thread.currentThread().isInterrupted()) {
                    DelayedTask task = delayQueue.take();
                    executor.submit(task);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }, "delay-consumer");
        consumerThread.setDaemon(true);
        consumerThread.start();
    }
    
    public void schedule(Runnable task, long delay, TimeUnit unit) {
        delayQueue.put(new DelayedTask(task, System.nanoTime() + unit.toNanos(delay)));
    }
    
    record DelayedTask(Runnable task, long executionTime) implements Delayed {
        @Override
        public long getDelay(TimeUnit unit) {
            return unit.convert(executionTime - System.nanoTime(), TimeUnit.NANOSECONDS);
        }
        
        @Override
        public int compareTo(Delayed other) {
            return Long.compare(this.executionTime, ((DelayedTask)other).executionTime);
        }
        
        @Override
        public void run() {
            task.run();
        }
    }
}
```

## 十一、实际应用场景

### 11.1 Web 应用中的模式组合

| 组件 | 使用的模式 | 说明 |
|------|-----------|------|
| 请求缓存 | ReadWriteLock + Immutable | 缓存热数据 |
| 订单处理 | Producer-Consumer + ThreadPool | 异步处理订单 |
| 服务关闭 | Two-Phase Termination | 优雅关闭 |
| 配置管理 | Immutable Object + Balking | 配置热加载 |
| 异步查询 | Future & Promise | 聚合多个服务 |

### 11.2 性能对比

| 模式 | 无锁开销 | 实际应用延迟 | 适用并发级别 |
|------|---------|-------------|------------|
| Immutable Object | 0 | 0-1μs | 无限制 |
| Read-Write Lock | 50-100ns | 1-10μs | 读多写少 |
| Producer-Consumer | 100-200ns | 10-100μs | 高吞吐 |
| Guarded Suspension | 50-100ns | 10-1000μs | 条件等待 |
| Two-Phase Termination | 10-50ns | 100μs-1s | 生命周期管理 |

## 总结

Java 多线程设计模式是解决并发问题的纲领性指导。理解这些模式的核心思想和适用场景，能帮助我们在面对复杂的并发问题时，快速找到成熟的解决方案。关键不在于死记硬背代码模板，而在于理解每种模式试图解决的根本问题。

在实际项目中，往往是多种模式的组合使用。例如一个消息处理系统可能同时用到 Producer-Consumer、Thread Pool、Guarded Suspension 和 Two-Phase Termination。掌握这些模式的本质，就能灵活组合，构建出高效、稳定的并发系统。
