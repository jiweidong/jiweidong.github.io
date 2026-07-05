---
title: 【并发编程】Java 线程通信与协作机制详解：wait/notify、Condition、LockSupport 与管程模型
date: 2026-07-05 08:00:00
tags:
  - Java
  - 并发
  - 面试
  - JUC
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【并发编程】Java 线程通信与协作机制详解：wait/notify、Condition、LockSupport 与管程模型

## 一、为什么要学线程通信？

多线程编程的核心问题有两个：**互斥（Mutual Exclusion）** 和 **协作（Cooperation）**。

互斥解决的是"同一时间谁能访问共享资源"——我们用 `synchronized` 或 `Lock` 来实现。

协作解决的是"线程之间如何协调执行节奏"——当一个线程需要等待某个条件满足时（如队列空了要等待生产），就需要线程通信机制。

**面试官开场即问**："用 `wait/notify` 实现一个生产者-消费者模式，说说细节。"

## 二、Java 管程模型（Monitor）

要理解线程通信，必须先理解**管程（Monitor）** 模型。Java 中每个对象都关联一个 Monitor，这是 `synchronized` 和 `wait/notify` 的底层基础。

### 2.1 Mesa 管程模型

Java 采用 **Mesa 管程模型**（区别于 Hansen 管程和 Hoare 管程），核心特征：

```
Monitor（管程）
├── 入口等待队列（Entry Set）— 等待获取锁的线程
├── 条件变量等待队列（Wait Set）— 调用 wait() 的线程
└── 占有者（Owner）— 当前持有锁的线程
```

**关键特性**：
- 只有 Owner 线程可以调用 `wait()` 和 `notify()`
- `wait()` 释放锁并进入 Wait Set
- `notify()` 将 Wait Set 中一个线程移回 Entry Set
- 被唤醒的线程重新竞争锁，**不会立即恢复执行**（这是 Mesa 模型的重要特性）

### 2.2 Mesa 模型 vs Hoare 模型

| 特性 | Mesa（Java 采用） | Hoare |
|------|------------------|-------|
| notify 后谁执行 | 通知者继续持有锁，等待者进 Entry Set | 立即切换给等待者 |
| 是否需要重新检查条件 | ✅ 需要（while 循环） | ❌ 不需要 |
| 实现复杂度 | 较低 | 较高 |
| 上下文切换次数 | 较少 | 较多 |

**Mesa 模型的实践结果**：`wait()` 必须在 `while` 循环中使用，而非 `if`。

```java
// ✅ 正确写法
synchronized (lock) {
    while (condition == false) {  // 用 while 不是 if
        lock.wait();
    }
    // 条件满足后继续
}

// ❌ 错误写法
synchronized (lock) {
    if (condition == false) {
        lock.wait();  // 被唤醒后条件可能仍不满足！
    }
}
```

## 三、经典 wait/notify 机制

### 3.1 Object 层级 API

| 方法 | 作用 | 前置条件 |
|------|------|---------|
| `wait()` | 释放锁，进入等待状态 | 持有锁 |
| `wait(long timeout)` | 超时等待 | 持有锁 |
| `notify()` | 唤醒一个等待线程 | 持有锁 |
| `notifyAll()` | 唤醒所有等待线程 | 持有锁 |

### 3.2 实战：生产者-消费者

```java
public class ProducerConsumerDemo {
    private final LinkedList<Integer> queue = new LinkedList<>();
    private final int maxSize = 10;
    
    // 生产者
    public void produce(int value) throws InterruptedException {
        synchronized (queue) {
            // ★ 必须用 while，不能用 if
            while (queue.size() == maxSize) {
                System.out.println("队列满，生产者等待...");
                queue.wait();  // 释放锁等待
            }
            queue.add(value);
            System.out.println("生产: " + value + ", 队列大小: " + queue.size());
            queue.notifyAll();  // 唤醒所有消费者
        }
    }
    
    // 消费者
    public int consume() throws InterruptedException {
        synchronized (queue) {
            while (queue.isEmpty()) {
                System.out.println("队列空，消费者等待...");
                queue.wait();
            }
            int value = queue.poll();
            System.out.println("消费: " + value + ", 队列大小: " + queue.size());
            queue.notifyAll();
            return value;
        }
    }
}
```

**为什么用 `notifyAll()` 而不是 `notify()`？**

如果生产者唤醒了一个生产者（而非消费者），且队列已满，被唤醒的生产者发现条件仍不满足，再次等待。极端情况可能造成"信号丢失"（thread convoy）。使用 `notifyAll()` 能保证正确的线程被唤醒，虽然稍有性能损耗。

### 3.3 三个核心问点

**① `wait()` 释放锁后会丢失之前的中断状态吗？**

不会。`wait()` 在抛出 `InterruptedException` 时，线程的中断标志位会被清除。因此需要在 catch 块中重新中断。

```java
synchronized (lock) {
    try {
        lock.wait();
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();  // 恢复中断状态
        return;
    }
}
```

**② `wait()` 和 `sleep()` 有什么区别？**

| 对比项 | wait() | sleep() |
|--------|-------|---------|
| 释放锁 | ✅ 释放 | ❌ 不释放 |
| 属于哪个类 | Object | Thread |
| 必须 synchronized | ✅ 是 | ❌ 否 |
| 用途 | 线程协作 | 暂停执行 |
| 唤醒方式 | notify/notifyAll/超时 | 超时/Interrupt |

**③ `notify()` 唤醒的线程能立即执行吗？**

不能。被唤醒的线程进入 Entry Set，需要重新竞争锁。这是 Mesa 模型的特性。

## 四、Lock + Condition 机制

### 4.1 Condition 与 wait/notify 对比

`Lock` 配合 `Condition` 是 `synchronized` + `wait/notify` 的增强版。

```java
// wait/notify 对应
synchronized(obj) { obj.wait(); }     → lock.lock(); condition.await();
synchronized(obj) { obj.notify(); }   → lock.lock(); condition.signal();
synchronized(obj) { obj.notifyAll(); } → lock.lock(); condition.signalAll();
```

**Condition 的优势**：
- 支持 **多个条件变量**（一个锁可绑定多个 Condition）
- 支持 **超时等待**（`await(long time, TimeUnit unit)`）
- 支持 **不响应中断的等待**（`awaitUninterruptibly()`）
- 更灵活的唤醒控制

### 4.2 多条件变量实战：阻塞队列

`ArrayBlockingQueue` 内部正是用两个 Condition 实现的：

```java
public class BoundedBuffer<T> {
    private final Lock lock = new ReentrantLock();
    private final Condition notFull = lock.newCondition();   // 队列未满
    private final Condition notEmpty = lock.newCondition();  // 队列非空
    
    private final Object[] items;
    private int putIndex, takeIndex, count;
    
    public BoundedBuffer(int capacity) {
        items = new Object[capacity];
    }
    
    public void put(T item) throws InterruptedException {
        lock.lock();
        try {
            while (count == items.length) {
                notFull.await();  // 队列满 → 等待"未满"条件
            }
            items[putIndex] = item;
            if (++putIndex == items.length) putIndex = 0;
            count++;
            notEmpty.signal();  // 队列不空 → 唤醒消费者
        } finally {
            lock.unlock();
        }
    }
    
    @SuppressWarnings("unchecked")
    public T take() throws InterruptedException {
        lock.lock();
        try {
            while (count == 0) {
                notEmpty.await();  // 队列空 → 等待"非空"条件
            }
            T item = (T) items[takeIndex];
            items[takeIndex] = null;
            if (++takeIndex == items.length) takeIndex = 0;
            count--;
            notFull.signal();  // 队列不满 → 唤醒生产者
        } finally {
            lock.unlock();
        }
        return item;
    }
}
```

**对比 wait/notify 版本的优势**：用两个 Condition 分别管理生产者和消费者，`signal()` 唤醒的就是"另一边"的线程，不存在信号丢失问题，效率更高。

## 五、LockSupport：最底层的线程阻塞/唤醒

### 5.1 核心 API

`LockSupport` 是 `JUC` 中最底层的线程阻塞工具，基于 `Unsafe` 的 `park/unpark`。

| 方法 | 说明 |
|------|------|
| `park()` | 阻塞当前线程 |
| `parkNanos(long nanos)` | 限时阻塞 |
| `park(Object blocker)` | 阻塞并记录阻塞对象（方便诊断） |
| `unpark(Thread t)` | 唤醒指定线程 |

### 5.2 核心特性：许可机制（Permit）

`LockSupport` 底层维护了一个**许可（Permit）** 信号量，默认值为 0：

```
unpark(thread) → 设置 thread 的 permit = 1
park()         → 检查 permit： 
                   ├── permit = 1 → 消耗 permit，继续执行
                   └── permit = 0 → 阻塞等待
```

**关键特点**：
- **先 unpark 再 park 也能唤醒**：如果先 `unpark(thread)` 设置了 permit=1，线程再 `park()` 时直接消耗 permit 返回，不会阻塞
- **不要求持有锁**：与 `wait/notify` 不同，`park/unpark` 不需要在 synchronized 块中
- **对象级别唤醒**：`unpark` 精确控制唤醒哪个线程

### 5.3 源码级验证

```java
// LockSupport.park()
public static void park() {
    UNSAFE.park(false, 0L);  // native 方法
}

// LockSupport.unpark(Thread)
public static void unpark(Thread thread) {
    if (thread != null)
        UNSAFE.unpark(thread);  // native 方法
}
```

底层的 `Unsafe.park/unpark` 是对操作系统线程原语的直接调用（Linux 上基于 `pthread_cond_wait` / `pthread_cond_signal`）。

### 5.4 实战：用 LockSupport 实现简单的阻塞队列

```java
public class ParkUnparkQueue<T> {
    private final LinkedList<T> queue = new LinkedList<>();
    private volatile Thread consumerThread;
    
    public void put(T item) {
        synchronized (queue) {
            queue.add(item);
        }
        // 唤醒消费者
        if (consumerThread != null) {
            LockSupport.unpark(consumerThread);
        }
    }
    
    public T take() throws InterruptedException {
        consumerThread = Thread.currentThread();
        while (true) {
            synchronized (queue) {
                if (!queue.isEmpty()) {
                    return queue.poll();
                }
            }
            LockSupport.park();  // 队列空，阻塞
            // 检查是否被中断
            if (Thread.interrupted()) {
                throw new InterruptedException();
            }
        }
    }
}
```

### 5.5 三种机制对比

| 维度 | wait/notify | Condition | LockSupport |
|------|------------|-----------|-------------|
| 所属层级 | Object | JUC | JUC（最底层） |
| 需要锁 | ✅ 必须 synchronized | ✅ 必须 Lock | ❌ 不需要 |
| 精确唤醒 | ❌（notifyAll） | ✅ signal 选一个 | ✅ unpark 指定线程 |
| 超时等待 | ✅ wait(timeout) | ✅ await(time, unit) | ✅ parkNanos |
| 先通知后等待 | ❌ | ❌ | ✅ 允许 |
| 诊断支持 | Monitor 状态 | Lock 信息 | blocker 对象 |

## 六、面试高频题

### Q：`wait()` 为什么要放在 while 循环而不是 if 中？

> Java 采用 Mesa 管程模型。线程被唤醒后从 Wait Set 进入 Entry Set，重新竞争锁。拿到锁后**条件可能已经再次发生变化**（比如其他消费者先一步取走了数据），必须重新检查条件。while 循环确保条件满足后才继续执行。

### Q：`LockSupport.park()` 和 `Condition.await()` 有什么区别？

> `park()` 不需要持有锁，不依赖管程模型，基于许可（Permit）机制，支持先 unpark 后 park。`await()` 需要持有 Lock，是 Condition 条件变量的一部分，只能通过 signal/signalAll 唤醒。

### Q：一个线程可以调用两次 `unpark` 吗？permit 会叠加吗？

> permit 最大为 1。连续两次 `unpark` 和一次的效果相同。所以 `LockSupport` 不支持"带计数的许可"。

### Q：为什么 Thread 的 `suspend()` 和 `resume()` 被废弃了？

> 因为容易死锁。如果 `suspend()` 在持有锁时被调用，线程挂起但不释放锁，`resume()` 需要获取该锁才能执行，造成死锁。`wait/notify` 在挂起时释放锁，不存在此问题。

## 七、总结

Java 提供了三层线程通信机制，从底层到高层分别是：

```
LockSupport（原始许可机制）
    ↓
Condition（条件变量 + 精确唤醒）
    ↓
Object.wait/notify（Monitor 管程模型）
```

在日常开发中：
- 简单场景使用 `synchronized + wait/notify`
- 需精细控制时使用 `Lock + Condition`
- 高性能工具类和框架使用 `LockSupport`（`AQS` 的核心就是 `LockSupport.park/unpark`）

理解这些机制后，你会发现 `AQS`、`ReentrantLock`、`CountDownLatch`、`CyclicBarrier` 等 JUC 工具的原理豁然开朗——它们都是在这三种通信机制之上的封装。
