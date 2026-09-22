---
title: 【并发编程】生产者-消费者模型深度解析：wait/notify、条件变量与 BlockingQueue 实战
date: 2026-09-22 08:00:00
tags:
  - Java
  - 并发
  - 线程通信
  - BlockingQueue
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】生产者-消费者模型深度解析：wait/notify、条件变量与 BlockingQueue 实战

## 面试官：手写一个生产者-消费者模型，要求不能用阻塞队列

这道题看起来简单，但它是**并发编程的照妖镜**。我面过的人里，能一次写对的不到三成。常见的翻车点有：

- 用 `if` 判断条件，被虚假唤醒了直接往下执行；
- 只调 `notify()` 不调 `notifyAll()`，导致同类线程互相唤醒、程序卡死；
- 把 `wait()` 写在 `synchronized` 块外面，直接抛 `IllegalMonitorStateException`；
- 有界队列满了/空了，不做背压（backpressure），直接 OOM。

这篇文章从零讲起：先讲清楚这个模型到底解决什么问题，再给四种实现（由浅入深），最后把 JDK 里 `BlockingQueue` 的源码和面试追问一起串起来。

---

## 一、为什么需要生产者-消费者模型

先明确动机，面试时先讲动机比直接写代码分高。

```
生产者 ──► [ 队列 / 缓冲区 ] ──► 消费者
  快              有界              慢
```

三类典型诉求：

1. **解耦**：生产者不需要知道消费者是谁、有几个、用的是什么实现。
2. **削峰填谷**：生产者瞬时流量大，队列先缓冲，消费者按自己的处理能力匀速消费。
3. **异步**：生产者提交任务后立即返回，不必等待处理结果。

它的本质是**用一块共享缓冲区协调两种速率不同的线程**。而所有难点，都来自"这块缓冲区是共享可变状态"。

### 1.1 并发难点在哪里

- **互斥**：队列的入队/出队要原子，否则会丢元素或越界；
- **同步（协作）**：队列满了生产者在哪儿停？队列空了消费者在哪儿等？
- **唤醒**：什么时候、唤醒谁、唤醒后条件是否还成立？

`synchronized` 只解决了互斥，**协作要靠 `wait/notify`**。这正是这个模型的考点。

---

## 二、实现一：synchronized + wait/notifyAll

### 2.1 正确版本

```java
import java.util.LinkedList;
import java.util.Queue;

public class WaitNotifyQueue<T> {
    private final Queue<T> queue = new LinkedList<>();
    private final int capacity;

    public WaitNotifyQueue(int capacity) {
        this.capacity = capacity;
    }

    public synchronized void put(T item) throws InterruptedException {
        // ★ 必须用 while，不能用 if
        while (queue.size() == capacity) {
            // 释放锁 + 挂起当前线程，被唤醒后重新竞争锁并从下一行继续
            wait();
        }
        queue.offer(item);
        // ★ 用 notifyAll，唤醒可能等待的消费者
        notifyAll();
    }

    public synchronized T take() throws InterruptedException {
        while (queue.isEmpty()) {
            wait();
        }
        T item = queue.poll();
        notifyAll();
        return item;
    }
}
```

### 2.2 三个"为什么"

**为什么用 `while` 而不是 `if`？**

因为 `wait()` 返回**不代表条件已经满足**：

1. **虚假唤醒（spurious wakeup）**：JVM/OS 规范的允许 `wait()` 在没有 `notify` 的情况下返回；
2. **被同类唤醒**：消费者被唤醒后，可能在拿到锁之前，另一个消费者已经把元素抢走了；它拿到锁时队列又空了。

所以唤醒后必须**重新检查条件**。`if` 只检查一次，逻辑就错了。

```java
// 错误示范
if (queue.isEmpty()) {
    wait();     // 被虚假唤醒后不再检查 → poll() 返回 null → NPE
}
T item = queue.poll();  // 可能为 null
```

**为什么用 `notifyAll()` 而不是 `notify()`？**

假设两个消费者 C1、C2 都在等，队列空。生产 P 放入一个元素后 `notify()` **只唤醒一个**，假设唤醒了 C1（正确）。但如果场景反过来：队列满时两个生产者 P1、P2 等待，消费者拿走后 `notify()` 恰好唤醒了另一个生产者……更经典的死锁场景是：**队列里有两个元素，P 唤醒的是另一个生产者而不是消费者**。

用 `notifyAll()` 时，所有等待线程都被唤醒去竞争锁，条件不满足的会继续 `wait()`，虽然多了一次调度开销，但**逻辑一定正确**。所以默认用 `notifyAll()`，只有确认"同一种角色、状态完全对等"时才考虑 `notify()`。

**为什么 `wait()` 必须在 `synchronized` 里？**

`wait()` 的语义是"释放当前持有的监视器锁并挂起"。如果线程没有持有监视器锁，调用会抛 `IllegalMonitorStateException`。同时，释放锁和挂起必须是原子的，否则会出现"检查完条件、还没挂起，就被 notify 了"的**丢失唤醒**问题——锁正好保证了这个原子性。

### 2.3 `wait/notify` 与锁的关系

```
线程 A                   监视器锁                        线程 B
  │                   Object Monitor                      │
  ├── synchronized(obj) ──► 持有锁
  ├── while(条件不满足)
  ├── obj.wait()
  │      ├─ 释放锁 ──────► 锁空闲
  │      └─ 进入 WaitSet（挂起）                          │
  │                                   ◄── synchronized(obj) 获取锁
  │                                   ◄── obj.notifyAll()
  │      ◄─ 从 WaitSet 移到 EntryList（等锁，不立即执行）
  ├── 重新竞争锁 ────────────────────►
  ├── 拿到锁，从 wait() 下一行继续（重新检查 while）
```

**关键点：被唤醒 ≠ 立即执行**，只是从 WaitSet 移到 EntryList 重新抢锁。

---

## 三、实现二：ReentrantLock + Condition（两个条件队列）

`synchronized` 只有一个等待集合，所以生产者满了、消费者空了会挤在一起唤醒，效率不高。`Condition` 允许**为不同角色建立独立的等待队列**：

```java
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

public class ConditionQueue<T> {
    private final Deque<T> queue = new ArrayDeque<>();
    private final int capacity;
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition notFull = lock.newCondition();   // 生产者等待队列
    private final Condition notEmpty = lock.newCondition();  // 消费者等待队列

    public ConditionQueue(int capacity) {
        this.capacity = capacity;
    }

    public void put(T item) throws InterruptedException {
        lock.lockInterruptibly();
        try {
            while (queue.size() == capacity) {
                notFull.await();          // 只挂生产者
            }
            queue.offerLast(item);
            notEmpty.signal();            // ★ 精准唤醒一个消费者
        } finally {
            lock.unlock();
        }
    }

    public T take() throws InterruptedException {
        lock.lockInterruptibly();
        try {
            while (queue.isEmpty()) {
                notEmpty.await();          // 只挂消费者
            }
            T item = queue.pollFirst();
            notFull.signal();              // ★ 精准唤醒一个生产者
            return item;
        } finally {
            lock.unlock();
        }
    }
}
```

对比一下：

| 维度 | synchronized + wait/notifyAll | ReentrantLock + Condition |
|---|---|---|
| 等待队列 | 一个 | 多个（按角色分离） |
| 唤醒精度 | `notifyAll` 全员竞争 | `signal` 精准唤醒对方角色 |
| 可中断/超时 | 有 `wait` 超时，无公平性 | `lockInterruptibly`、`tryLock`、公平锁 |
| 性能 | 早期更好，JDK 6 后优化明显 | 竞争激烈时更稳定 |
| 复杂度 | 低 | 高（必须 `finally` 里 unlock） |

> 重点：这里的 `signal()` 不是 `signalAll()`，因为两个角色各有独立队列——**消费者只可能因"队列非空"而等待**，所以唤醒一个即可。这是比 `notifyAll` 更精确的做法，但要保证"同类等待条件完全等价"，否则又会出现唤醒错人的死锁。

### 3.1 Condition 的内部原理

`Condition.await()` 内部和 `Object.wait()` 很像，但多了一层：线程会被加入该 Condition 对应的等待队列，并在 `await()` 时**释放锁**；被 `signal()` 时从等待队列移到 AQS 的同步队列重新竞争锁。

```java
// AQS 中 ConditionObject 的简化结构
// firstWaiter / lastWaiter 串起等待队列
// signal() → doSignal() → 把节点从条件队列转移到同步队列（transferForSignal）
```

---

## 四、实现三：直接用 BlockingQueue（生产首选）

面试写代码时，如果没有特别要求，**应该直接用 JDK 的 `BlockingQueue`**——它把上面所有坑都堵上了。

```java
import java.util.concurrent.*;

public class BqDemo {
    public static void main(String[] args) {
        BlockingQueue<Task> queue = new ArrayBlockingQueue<>(1000);

        // 生产者
        ExecutorService producers = Executors.newFixedThreadPool(2);
        for (int p = 0; p < 2; p++) {
            producers.submit(() -> {
                try {
                    for (int i = 0; ; i++) {
                        queue.put(new Task("t-" + i));   // 队列满 → 阻塞
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            });
        }

        // 消费者
        ExecutorService consumers = Executors.newFixedThreadPool(4);
        for (int c = 0; c < 4; c++) {
            consumers.submit(() -> {
                while (!Thread.currentThread().isInterrupted()) {
                    try {
                        Task t = queue.take();        // 队列空 → 阻塞
                        handle(t);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            });
        }
    }

    static void handle(Task t) { /* ... */ }
    static class Task { final String id; Task(String id) { this.id = id; } }
}
```

### 4.1 四种入队/出队语义

| 方法 | 队列满/空时的行为 |
|---|---|
| `add(e)` / `remove()` | 直接抛异常（`IllegalStateException` / `NoSuchElementException`） |
| `offer(e)` / `poll()` | 返回 `false` / `null`，不阻塞 |
| `offer(e, timeout, unit)` / `poll(timeout, unit)` | 等超时，返回 `false` / `null` |
| `put(e)` / `take()` | **无限期阻塞**，直到成功或被中断 |

选择建议：

- 要有背压 → `put` / `take`；
- 要避免线程无限挂起 → `offer(timeout)` / `poll(timeout)`；
- 明确知道不该满/不该空 → `add` / `remove`（让问题快速暴露）。

### 4.2 常用实现对比

| 实现 | 数据结构 | 锁 | 有界 | 特点 |
|---|---|---|---|---|
| `ArrayBlockingQueue` | 数组 | 1 个 ReentrantLock + 2 Condition | 必须指定 | 内存连续，性能稳定 |
| `LinkedBlockingQueue` | 链表 | **2 把锁**（put/take 分离） | 可选（默认 `Integer.MAX_VALUE`） | 吞吐高，但默认容量≈无界，慎用 |
| `PriorityBlockingQueue` | 堆 | 1 把锁 | 无界 | 按优先级出队 |
| `DelayQueue` | 堆 + 延迟 | 1 把锁 | 无界 | 延迟任务/超时订单 |
| `SynchronousQueue` | 无缓冲 | — | 容量 0 | 生产者必须等消费者直接交接 |
| `LinkedTransferQueue` | 链表 | 无锁 CAS | 无界 | 高吞吐，支持 `transfer` |

### 4.3 `ArrayBlockingQueue` 源码精要

```java
public void put(E e) throws InterruptedException {
    Objects.requireNonNull(e);
    final ReentrantLock lock = this.lock;
    lock.lockInterruptibly();
    try {
        while (count == items.length)
            notFull.await();            // 和手写版本一模一样的 while + await
        enqueue(e);                     // 入队，count++
        notFull... // 实际是 notEmpty.signal()
    } finally {
        lock.unlock();
    }
}

public E take() throws InterruptedException {
    final ReentrantLock lock = this.lock;
    lock.lockInterruptibly();
    try {
        while (count == 0)
            notEmpty.await();
        return dequeue();
    } finally {
        lock.unlock();
    }
}
```

看到没？**JDK 的实现和你手写的正确版本，骨架完全一致**：`lock` + `while` + `await` + `signal` + `finally unlock`。所以手写题其实就是考你有没有真正理解 `BlockingQueue`。

`LinkedBlockingQueue` 的区别在于用了两把锁：

```java
/** 出队锁 */
private final ReentrantLock takeLock = new ReentrantLock();
private final Condition notEmpty = takeLock.newCondition();
/** 入队锁 */
private final ReentrantLock putLock = new ReentrantLock();
private final Condition notFull = putLock.newCondition();
private final AtomicInteger count = new AtomicInteger();
```

入队和出队操作不同队列位置，用两把锁可以真正并行，代价是 `count` 必须用原子变量维护。**这也是为什么 `LinkedBlockingQueue` 在高并发下吞吐通常高于 `ArrayBlockingQueue`。**

---

## 五、背压：比"写对代码"更重要的事

面试里我会追问："如果消费者比生产者慢得多，会发生什么？"

- 用**无界队列**：内存持续增长 → 最终 `OutOfMemoryError`；
- 用**有界队列 + 阻塞**：生产者被反压，上游响应变慢（这是好事，压力不会转移给内存）。

所以工程上正确的姿势是：**有界队列 + 明确的拒绝/降级策略**。

```java
ThreadPoolExecutor pool = new ThreadPoolExecutor(
    4, 8, 60, TimeUnit.SECONDS,
    new ArrayBlockingQueue<>(2000),                 // ★ 有界
    new ThreadFactoryBuilder().setNameFormat("consumer-%d").build(),
    new ThreadPoolExecutor.CallerRunsPolicy()       // ★ 拒绝时由提交者自己执行，天然背压
);
```

JDK 的四种拒绝策略对应不同的"背压"含义：

| 策略 | 行为 | 适用 |
|---|---|---|
| `AbortPolicy`（默认） | 抛 `RejectedExecutionException` | 快速失败，由上游决定降级 |
| `CallerRunsPolicy` | 提交者线程自己执行 | 天然限流，平滑降速 |
| `DiscardPolicy` | 静默丢弃 | 可丢数据的场景（埋点） |
| `DiscardOldestPolicy` | 丢最老的再重试 | 只关心最新值的场景 |

**线程池本身就是一个生产者-消费者模型**：`execute()` 是生产者（往 workQueue 放任务），Worker 线程是消费者（从 workQueue 取任务）。理解了这一点，线程池的参数调优和拒绝策略就不难解释了。

---

## 六、进阶：Disruptor 与无锁队列

当队列成为瓶颈时（比如百万级 TPS 的订单/行情场景），锁 + 条件变量的开销就不可忽视了。`Disruptor` 用了一组技术：

1. **环形数组（RingBuffer）**：预分配对象，避免 GC；
2. **CAS 序号分配**：生产者用 CAS 抢槽位，无锁；
3. **缓存行填充**：避免伪共享（`Sequence` 前后各填 8 个 long）；
4. **序号屏障（SequenceBarrier）+ 批量消费**：消费者批量推进，减少协调开销。

```java
// Disruptor 典型用法（简化）
Disruptor<OrderEvent> disruptor = new Disruptor<>(
    OrderEvent::new, 1024 * 1024,           // RingBuffer 大小，必须是 2 的幂
    DaemonThreadFactory.INSTANCE,
    ProducerType.MULTI,                      // 多生产者用 MULTI
    new BusySpinWaitStrategy()               // 低延迟等链式等待策略
);
disruptor.handleEventsWith(this::onEvent);
disruptor.start();
disruptor.publishEvent((event, seq, order) -> event.set(order), order);
```

不过要清醒：**绝大多数业务用 `ArrayBlockingQueue` 就够了**，Disruptor 是在极端场景下的优化。面试时能说清"什么时候才需要它"比背 API 更有价值。

---

## 七、面试常见追问

**Q1：`wait()` 和 `sleep()` 的区别？**

`wait()` 释放锁、属于 `Object`、必须在 `synchronized` 内、可被 `notify` 唤醒；`sleep()` 不释放锁、属于 `Thread`、不需要锁、到时间自然醒。两者都会响应中断并抛 `InterruptedException`。

**Q2：`notifyAll()` 唤醒所有线程，会不会有惊群效应？**

会，但唤醒的线程都要重新竞争锁，条件不满足的会继续 `await`，只是多一次上下文切换。用 `Condition` 分离等待队列就是为了减少这种无效唤醒。

**Q3：`wait()` 被唤醒后，是从 `wait()` 的下一行继续，还是从头执行？**

从 `wait()` 的**下一行**继续，并且**会重新获取锁**。所以必须用 `while` 包住，重新判断条件。

**Q4：`BlockingQueue` 的 `put/take` 是如何响应中断的？**

内部用 `lock.lockInterruptibly()` + `Condition.await()`，等待期间可被中断，抛 `InterruptedException`。捕获后应恢复中断标记（`Thread.currentThread().interrupt()`）并退出循环。

**Q5：为什么 `LinkedBlockingQueue` 默认容量是 `Integer.MAX_VALUE`，这算无界吗？**

算"逻辑无界"，理论最大约 21 亿，届时也会 OOM。所以生产环境**必须显式传容量**，否则队列会一直涨到内存耗尽。

**Q6：手写实现时，`notifyAll` 放在循环内还是循环外？**

放在**修改共享状态之后**、仍在 `synchronized` 块内。位置在循环外（解锁前）即可，关键是必须在状态改变之后调用，否则可能丢失唤醒。

---

## 八、总结

- 生产者-消费者的本质：**用共享缓冲区协调两种不同速率的线程**，核心是互斥 + 协作。
- `synchronized + wait/notifyAll` 手写要点：**`while` 判条件、`notifyAll` 唤醒、`wait` 在锁内**。
- 更好的写法：`ReentrantLock + Condition` 分离不同角色的等待队列，`signal` 精准唤醒。
- 生产首选 `BlockingQueue`：`put/take` 天然背压，`offer/poll` 带超时，`ArrayBlockingQueue` 与 `LinkedBlockingQueue` 的选择取决于吞吐与锁竞争。
- **有界队列 + 合理拒绝策略** 比"把代码写对"更重要，否则一定会 OOM。
- 线程池就是生产者-消费者模型的一个特例；极端场景再考虑 Disruptor 这类无锁方案。

一句话记住：**写对 `while(条件) wait()` 只是及格，想清楚"队列满了怎么办"才是工程。**
