---
title: 【并发编程】Java 阻塞队列 BlockingQueue 深度解析：源码、原理与实战
date: 2026-07-03 08:02:00
tags:
  - Java
  - 并发
  - 集合
categories:
  - Java
  - Java基础
author: 东哥
---

# 【并发编程】Java 阻塞队列 BlockingQueue 深度解析：源码、原理与实战

## 为什么需要阻塞队列？

在生产者-消费者模式中，生产者生产数据，消费者消费数据。如果两者速率不一致，就需要一个缓冲区。阻塞队列就是这样一个**线程安全的缓冲区**：

- **队列为空时**：消费者线程阻塞等待，直到有数据可用
- **队列满时**：生产者线程阻塞等待，直到有空间可用

阻塞队列是 `java.util.concurrent` 包中最核心的组件之一，**线程池、消息中间件的底层都离不开它。**

## BlockingQueue 接口总览

```java
public interface BlockingQueue<E> extends Queue<E> {
    // 添加元素
    boolean add(E e);       // 满时抛出 IllegalStateException
    boolean offer(E e);     // 满时返回 false
    void put(E e) throws InterruptedException;  // 满时阻塞
    boolean offer(E e, long timeout, TimeUnit unit) throws InterruptedException; // 限时阻塞

    // 移除元素
    E take() throws InterruptedException;       // 空时阻塞
    E poll(long timeout, TimeUnit unit) throws InterruptedException; // 限时阻塞

    // 非阻塞读取
    E poll();               // 空时返回 null
    E peek();               // 空时返回 null（不删除）

    // 剩余容量
    int remainingCapacity();
}
```

四种行为的对比：

| 操作 | 抛出异常 | 返回特殊值 | 一直阻塞 | 超时退出 |
|------|---------|-----------|---------|---------|
| 插入 | `add(e)` | `offer(e)` | `put(e)` | `offer(e, time, unit)` |
| 移除 | `remove()` | `poll()` | `take()` | `poll(time, unit)` |
| 检查 | `element()` | `peek()` | 不支持 | 不支持 |

## 7 种阻塞队列一览

| 实现类 | 数据结构 | 是否有界 | 锁策略 | 特点 |
|--------|---------|---------|-------|------|
| ArrayBlockingQueue | 数组 | 有界 | 单一锁 | 公平/非公平可选 |
| LinkedBlockingQueue | 单向链表 | 有界（默认 Integer.MAX_VALUE） | 双锁 | 吞吐量高 |
| PriorityBlockingQueue | 堆（数组） | 无界 | 单一锁 | 优先级排序 |
| DelayQueue | 优先队列 | 无界 | 单一锁 | 延迟执行 |
| SynchronousQueue | 无存储 | 容量为 0 | CAS | 直接传递 |
| LinkedTransferQueue | 链表 | 无界 | CAS | 支持 transfer |
| LinkedBlockingDeque | 双向链表 | 有界（默认 Integer.MAX_VALUE） | 双锁 | 双端操作 |

## ArrayBlockingQueue 源码深度解析

### 数据结构

```java
public class ArrayBlockingQueue<E> extends AbstractQueue<E>
        implements BlockingQueue<E>, java.io.Serializable {
    
    final Object[] items;          // 环形数组存储元素
    int takeIndex;                 // 取元素指针
    int putIndex;                  // 放元素指针
    int count;                     // 元素数量
    final ReentrantLock lock;      // 全局锁
    private final Condition notEmpty;  // 非空条件
    private final Condition notFull;   // 非满条件
}
```

**核心设计：** 一个全局锁 + 两个 Condition，实现了生产者-消费者的精确唤醒。

### put 方法（阻塞插入）

```java
public void put(E e) throws InterruptedException {
    Objects.requireNonNull(e);
    final ReentrantLock lock = this.lock;
    lock.lockInterruptibly(); // 可中断锁
    try {
        while (count == items.length)
            notFull.await(); // 队列满，阻塞生产者
        enqueue(e);          // 入队
    } finally {
        lock.unlock();
    }
}

private void enqueue(E x) {
    final Object[] items = this.items;
    items[putIndex] = x;
    if (++putIndex == items.length)
        putIndex = 0;       // 环形数组，回绕
    count++;
    notEmpty.signal();      // 唤醒消费者
}
```

### take 方法（阻塞取出）

```java
public E take() throws InterruptedException {
    final ReentrantLock lock = this.lock;
    lock.lockInterruptibly();
    try {
        while (count == 0)
            notEmpty.await(); // 队列空，阻塞消费者
        return dequeue();
    } finally {
        lock.unlock();
    }
}

private E dequeue() {
    final Object[] items = this.items;
    @SuppressWarnings("unchecked")
    E x = (E) items[takeIndex];
    items[takeIndex] = null;  // 帮助 GC
    if (++takeIndex == items.length)
        takeIndex = 0;
    count--;
    if (itrs != null)
        itrs.elementDequeued();
    notFull.signal();        // 唤醒生产者
    return x;
}
```

**核心机制：** `put` 唤醒 `notEmpty`（消费线程），`take` 唤醒 `notFull`（生产线程），避免无效竞争。

### 公平模式 vs 非公平模式

```java
public ArrayBlockingQueue(int capacity, boolean fair) {
    // fair = true 时，lock 是公平锁，等待时间最长的线程优先获取
    this.lock = new ReentrantLock(fair);
    notEmpty = lock.newCondition();
    notFull =  lock.newCondition();
}
```

公平模式保证 FIFO 但性能下降约 1-2 个数量级，**绝大多数场景用非公平模式即可**。

## LinkedBlockingQueue 源码解析

### 与 ArrayBlockingQueue 的关键区别

```java
public class LinkedBlockingQueue<E> extends AbstractQueue<E>
        implements BlockingQueue<E>, java.io.Serializable {

    // 链表节点
    static class Node<E> {
        E item;
        Node<E> next;
        Node(E x) { item = x; }
    }

    private final int capacity;            // 容量，默认 Integer.MAX_VALUE
    private final AtomicInteger count;     // 原子计数器
    
    // 双锁设计：取锁和放锁分离
    private final ReentrantLock takeLock = new ReentrantLock();
    private final Condition notEmpty = takeLock.newCondition();
    
    private final ReentrantLock putLock = new ReentrantLock();
    private final Condition notFull = putLock.newCondition();
}
```

**双锁设计的优势：** put 和 take 可以并发执行，大幅提升吞吐量。

### put 方法

```java
public void put(E e) throws InterruptedException {
    if (e == null) throw new NullPointerException();
    int c = -1;
    Node<E> node = new Node<>(e);
    final ReentrantLock putLock = this.putLock;
    final AtomicInteger count = this.count;
    putLock.lockInterruptibly();
    try {
        while (count.get() == capacity) {
            notFull.await();
        }
        enqueue(node);    // 单链表的尾插
        c = count.getAndIncrement();
        if (c + 1 < capacity)
            notFull.signal(); // 还有空间，唤醒其他生产者
    } finally {
        putLock.unlock();
    }
    if (c == 0)
        signalNotEmpty(); // 之前队列为空，唤醒消费者
}
```

关键优化：`signalNotEmpty()` 放在锁外，减少锁竞争。

## PriorityBlockingQueue — 优先阻塞队列

```java
// 内部使用堆（数组）实现，无界队列
public class PriorityBlockingQueue<E> extends AbstractQueue<E>
        implements BlockingQueue<E>, java.io.Serializable {
    
    private transient Object[] queue;      // 二叉堆数组
    private transient int size;
    private transient Comparator<? super E> comparator;
    private final ReentrantLock lock;
    private final Condition notEmpty;
    
    // ⚠️ 扩容时使用自旋 CAS 防止并发扩容
    private transient volatile int allocationSpinLock;
}
```

**特点：**
- 元素按优先级出队（最小堆或最大堆）
- **无界队列**，put 不会阻塞
- 扩容时用 CAS 控制并发

```java
// 使用方式
BlockingQueue<Task> queue = new PriorityBlockingQueue<>(
    11, // 初始容量
    (t1, t2) -> t1.priority - t2.priority // 优先级高的先出
);

queue.put(new Task("紧急任务", 1));
queue.put(new Task("普通任务", 5));
queue.put(new Task("重要任务", 2));

// 出队顺序：紧急任务 → 重要任务 → 普通任务
```

## DelayQueue — 延迟队列

```java
public class DelayQueue<E extends Delayed> extends AbstractQueue<E>
        implements BlockingQueue<E> {
    
    private final transient ReentrantLock lock = new ReentrantLock();
    private final PriorityQueue<E> q = new PriorityQueue<E>(); // 内部用优先队列
    private Thread leader;     // 等待队首元素的线程（Leader-Follower 模式）
}
```

**核心机制：** 元素必须实现 `Delayed` 接口，只有延迟时间到期的元素才能被取出。

```java
// 自定义延迟任务
public class DelayedTask implements Delayed {
    private final String name;
    private final long executeTime; // 执行时间戳(ms)
    
    public DelayedTask(String name, long delayMs) {
        this.name = name;
        this.executeTime = System.currentTimeMillis() + delayMs;
    }
    
    @Override
    public long getDelay(TimeUnit unit) {
        long diff = executeTime - System.currentTimeMillis();
        return unit.convert(diff, TimeUnit.MILLISECONDS);
    }
    
    @Override
    public int compareTo(Delayed o) {
        return Long.compare(this.executeTime, ((DelayedTask) o).executeTime);
    }
    
    public void execute() {
        System.out.println("执行任务: " + name + " at " + System.currentTimeMillis());
    }
}
```

**Leader-Follower 模式**：当多个线程同时 take 时，只有一个 leader 线程 wait 队首，其他线程无限等待，leader 取走元素后唤醒一个 follower。这种设计减少了不必要的锁竞争。

## SynchronousQueue — 同步队列

```java
// 容量为 0！put 必须等待 take，take 必须等待 put
BlockingQueue<String> queue = new SynchronousQueue<>();

// 必须配对使用，否则永远阻塞
new Thread(() -> {
    try { queue.put("数据"); } catch (InterruptedException e) {}
}).start();

new Thread(() -> {
    try { String data = queue.take(); } catch (InterruptedException e) {}
}).start();
```

**使用场景：** `Executors.newCachedThreadPool()` 内部就用 SynchronousQueue，有新任务就开始新线程处理。

## 实战场景：生产者-消费者

```java
public class BlockingQueueDemo {
    
    static class Producer implements Runnable {
        private final BlockingQueue<Integer> queue;
        private final int id;
        private final AtomicInteger counter = new AtomicInteger(0);
        
        Producer(BlockingQueue<Integer> queue, int id) {
            this.queue = queue;
            this.id = id;
        }
        
        @Override
        public void run() {
            try {
                while (!Thread.currentThread().isInterrupted()) {
                    int value = counter.incrementAndGet();
                    queue.put(value); // 满了就阻塞
                    System.out.println("生产者" + id + " 生产: " + value);
                    Thread.sleep(ThreadLocalRandom.current().nextInt(200, 500));
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
    
    static class Consumer implements Runnable {
        private final BlockingQueue<Integer> queue;
        private final int id;
        
        Consumer(BlockingQueue<Integer> queue, int id) {
            this.queue = queue;
            this.id = id;
        }
        
        @Override
        public void run() {
            try {
                while (!Thread.currentThread().isInterrupted()) {
                    Integer value = queue.take(); // 空了就阻塞
                    System.out.println("消费者" + id + " 消费: " + value);
                    Thread.sleep(ThreadLocalRandom.current().nextInt(500, 1000));
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
    
    public static void main(String[] args) throws InterruptedException {
        // 有界队列，容量 10
        BlockingQueue<Integer> queue = new ArrayBlockingQueue<>(10);
        
        // 2 个生产者，4 个消费者
        for (int i = 0; i < 2; i++) {
            new Thread(new Producer(queue, i)).start();
        }
        for (int i = 0; i < 4; i++) {
            new Thread(new Consumer(queue, i)).start();
        }
        
        Thread.sleep(10000);
        System.exit(0);
    }
}
```

## 在线程池中的应用

```java
// 不同线程池使用的阻塞队列
ExecutorService fixedPool = Executors.newFixedThreadPool(5);
// LinkedBlockingQueue<Runnable>() — 无界队列

ExecutorService cachedPool = Executors.newCachedThreadPool();
// SynchronousQueue<Runnable>() — 直接交付

ScheduledExecutorService scheduledPool = Executors.newScheduledThreadPool(5);
// DelayedWorkQueue — 延迟队列

// 自定义线程池推荐
ThreadPoolExecutor executor = new ThreadPoolExecutor(
    2,                       // corePoolSize
    10,                      // maxPoolSize
    60, TimeUnit.SECONDS,    // keepAliveTime
    new ArrayBlockingQueue<>(100), // 有界队列，防止 OOM
    new ThreadPoolExecutor.CallerRunsPolicy() // 拒绝策略
);
```

## 阻塞队列选型指南

| 场景 | 推荐队列 | 原因 |
|------|---------|------|
| 有界缓冲区、流控 | ArrayBlockingQueue | 有界，公平可选，性能好 |
| 高吞吐任务队列 | LinkedBlockingQueue | 双锁设计，并发度高 |
| 延迟任务调度 | DelayQueue | 支持延迟执行 |
| 优先级任务 | PriorityBlockingQueue | 按优先级处理 |
| 线程池非核心任务 | SynchronousQueue | 直接交付 |
| 双端操作 | LinkedBlockingDeque | 支持两端插入/移除 |

## 面试常见追问

### Q1：ArrayBlockingQueue 和 LinkedBlockingQueue 选哪个？

- **ArrayBlockingQueue**：有界、单一锁、预分配数组无 GC 压力，适合有界流控
- **LinkedBlockingQueue**：默认无界（易 OOM），双锁并发高，适合高吞吐任务池
- **高性能选 ArrayBlockingQueue，高并发选 LinkedBlockingQueue**

### Q2：BlockingQueue 的线程安全如何保证？

通过 **锁 + Condition** 实现：
1. 所有读写操作先在锁保护下执行
2. 条件不满足时通过 Condition.await() 释放锁并等待
3. 条件变化时通过 Condition.signal() 唤醒等待线程

### Q3：什么是"虚假唤醒"？如何处理？

线程可能在没有被 signal 的情况下被唤醒。**必须用 while 循环检查条件，而不是 if：**

```java
// ✅ 正确
while (count == items.length) {
    notFull.await();
}

// ❌ 错误
if (count == items.length) {
    notFull.await(); // 可能被虚假唤醒
}
```

## 总结

BlockingQueue 是 Java 并发编程的基石之一，理解它的实现原理对写出正确的并发代码至关重要。从单锁的 ArrayBlockingQueue、双锁的 LinkedBlockingQueue 到 Leader-Follower 模式的 DelayQueue，每种设计都在特定场景下做了时空权衡。掌握这些实现思路，也能帮助你设计自己的并发数据结构。
