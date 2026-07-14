---
title: 【并发编程】Java 同步器（Semaphore/CountDownLatch/CyclicBarrier）源码深度解析：从 AQS 到实战
date: 2026-07-14 08:01:00
tags:
  - Java
  - 并发编程
  - AQS
  - 源码分析
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】Java 同步器（Semaphore/CountDownLatch/CyclicBarrier）源码深度解析：从 AQS 到实战

## 前言

Java 并发包 (`java.util.concurrent`) 中除了 ThreadPoolExecutor、ConcurrentHashMap 这些大明星，还有一群低调但极为实用的**同步器（Synchronizer）**：

- **CountDownLatch** — 让一个线程等待其他线程「倒计时」结束
- **CyclicBarrier** — 让一组线程互相等待，到达屏障再一起出发
- **Semaphore** — 控制同时访问资源的线程数量

这三个工具在面试中频率极高，但很多人只停留在「会用 API」的层面。今天我们从 **AQS（AbstractQueuedSynchronizer）** 源码层面把它们彻底讲透。

<!-- more -->

---

## 一、AQS：所有同步器的基石

### 1.1 什么是 AQS？

AQS（AbstractQueuedSynchronizer）是 Java 并发包的**灵魂组件**。ReentrantLock、CountDownLatch、Semaphore、ReentrantReadWriteLock 等全部基于 AQS 实现。

```
┌─────────────────────────────────────────┐
│              AQS 核心三要素                │
├─────────────────────────────────────────┤
│  ① state: volatile int 共享状态变量        │
│  ② CLH 队列: 双向链表 等待队列             │
│  ③ 模板方法: tryAcquire/tryRelease 等      │
└─────────────────────────────────────────┘
```

```java
public abstract class AbstractQueuedSynchronizer
    extends AbstractOwnableSynchronizer {

    // 核心状态：volatile 保证可见性
    private volatile int state;

    // CLH 同步队列头尾
    private transient volatile Node head;
    private transient volatile Node tail;

    // 状态操作
    protected final int getState() { return state; }
    protected final void setState(int newState) { state = newState; }
    protected final boolean compareAndSetState(int expect, int update) {
        return unsafe.compareAndSwapInt(this, stateOffset, expect, update);
    }
}
```

### 1.2 CLH 队列架构

AQS 内部维护了一个**双向队列**（CLH 变体），所有获取同步状态失败的线程都会被包装成 Node 节点进入队列等待。

```java
static final class Node {
    static final Node SHARED = new Node();  // 共享模式标记
    static final Node EXCLUSIVE = null;     // 独占模式标记

    // 等待状态
    volatile int waitStatus;
    static final int CANCELLED = 1;   // 取消
    static final int SIGNAL   = -1;   // 后继需要唤醒
    static final int CONDITION = -2;  // 条件等待
    static final int PROPAGATE = -3;  // 传播

    volatile Node prev;     // 前驱
    volatile Node next;     // 后继
    volatile Thread thread; // 持有线程

    Node nextWaiter;        // 条件队列中的后继
}
```

**两种模式：**
- **独占模式（EXCLUSIVE）**：一次只有一个线程能获取锁 — ReentrantLock
- **共享模式（SHARED）**：一次可以有多个线程获取 — Semaphore、CountDownLatch

---

## 二、CountDownLatch：一次性倒计时门闩

### 2.1 核心概念

CountDownLatch 像一个**一次性门闩**：门闩上有一个计数器（`count`），只有计数器归零时，门才会打开，等待的线程才能继续执行。

```
         count=3                      count=2
    ┌────────────┐               ┌────────────┐
    │   ●  ●  ●  │   countDown   │   ●  ●     │
    │            │  ──────────→  │            │
    │  [等待线程] │               │  [等待线程]  │
    └────────────┘               └────────────┘

         count=0（门开了！）
    ┌────────────┐
    │    空       │
    │            │  ─────→ 等待线程全部放行
    │   [放行!]   │
    └────────────┘
```

### 2.2 源码分析：基于 AQS 共享模式

CountDownLatch 内部有一个 **Sync 内部类**，继承自 AQS：

```java
public class CountDownLatch {
    private final Sync sync;

    // 初始化计数器
    public CountDownLatch(int count) {
        if (count < 0) throw new IllegalArgumentException("count < 0");
        this.sync = new Sync(count);
    }

    private static final class Sync extends AbstractQueuedSynchronizer {
        Sync(int count) {
            setState(count); // AQS 的 state 就是计数器
        }

        int getCount() {
            return getState();
        }
    }
}
```

**await()：尝试获取共享锁**

```java
public void await() throws InterruptedException {
    sync.acquireSharedInterruptibly(1);
}

// AQS 模板方法
public final void acquireSharedInterruptibly(int arg)
        throws InterruptedException {
    if (Thread.interrupted())
        throw new InterruptedException();
    // 如果 tryAcquireShared 返回 < 0，表示获取失败，进入等待队列
    if (tryAcquireShared(arg) < 0)
        doAcquireSharedInterruptibly(arg);
}

// CountDownLatch.Sync 实现：
protected int tryAcquireShared(int acquires) {
    // state == 0 表示门闩已开，返回 1（获取成功）
    // state != 0 表示门闩未开，返回 -1（获取失败，进队列）
    return (getState() == 0) ? 1 : -1;
}
```

**countDown()：释放共享锁**

```java
public void countDown() {
    sync.releaseShared(1);
}

public final boolean releaseShared(int arg) {
    if (tryReleaseShared(arg)) {
        doReleaseShared(); // 唤醒等待队列中所有节点
        return true;
    }
    return false;
}

// CountDownLatch.Sync 实现：
protected boolean tryReleaseShared(int releases) {
    for (;;) {
        int c = getState();
        if (c == 0)
            return false; // 已经归零，无需操作
        int nextc = c - 1;
        if (compareAndSetState(c, nextc)) // CAS 递减
            return nextc == 0; // 归零时返回 true，触发唤醒
    }
}
```

### 2.3 关键特性：一次性

CountDownLatch 的计数器**只能减不能加**。一旦归零，就不能重置。

```java
CountDownLatch latch = new CountDownLatch(3);

// 线程1 await()
// 线程2、3、4 各 countDown() 一次

// 当 count 归零后：
latch.await(); // 立即返回，不再阻塞
latch.countDown(); // 什么也不做，tryReleaseShared 返回 false
```

如果需要「重复使用倒计时」→ 用 CyclicBarrier。

### 2.4 实战：多任务并行等待

```java
// 场景：模拟多服务启动检查
public class ServiceChecker {
    private static final int SERVICE_COUNT = 3;
    private static final CountDownLatch latch = new CountDownLatch(SERVICE_COUNT);

    public static void main(String[] args) throws InterruptedException {
        System.out.println("正在启动服务...");

        ExecutorService executor = Executors.newFixedThreadPool(SERVICE_COUNT);

        executor.submit(() -> {
            try {
                startDatabase();
            } finally {
                latch.countDown();
            }
        });
        executor.submit(() -> {
            try {
                startCache();
            } finally {
                latch.countDown();
            }
        });
        executor.submit(() -> {
            try {
                startMQ();
            } finally {
                latch.countDown();
            }
        });

        // 等待所有服务启动完成
        latch.await();
        System.out.println("所有服务启动完成，系统就绪！");
        executor.shutdown();
    }

    static void startDatabase() { sleep(2000); System.out.println("数据库启动完成"); }
    static void startCache() { sleep(1500); System.out.println("缓存启动完成"); }
    static void startMQ() { sleep(3000); System.out.println("消息队列启动完成"); }
    static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) {} }
}
```

> **面试追问：** `await()` 和 `await(long, TimeUnit)` 的区别？
>
> 后者设置超时时间，超时后无论 count 是否归零都返回 false。可用于「服务启动不超过 10 秒」的场景。

---

## 三、Semaphore：信号量/许可证管理

### 3.1 核心概念

Semaphore 维护一组「许可证（permits）」，线程获取许可证才能执行，执行完释放许可证。常用于**限流**和**资源池控制**。

```
許可証プール（5枚）
┌──┬──┬──┬──┬──┐
│  │  │  │  │  │  ← 3 个线程已获取
└──┴──┴──┴──┴──┘
  ↑  ↑  ↑
  T1 T2 T3     T4、T5 等待中（CLH 队列）
```

### 3.2 源码分析：公平与非公平

Semaphore 内部也是 Sync，但区分了**公平（FairSync）**和**非公平（NonfairSync）**：

```java
public class Semaphore {
    private final Sync sync;

    public Semaphore(int permits) {
        sync = new NonfairSync(permits); // 默认非公平
    }

    public Semaphore(int permits, boolean fair) {
        sync = fair ? new FairSync(permits) : new NonfairSync(permits);
    }
}
```

**非公平模式（默认）：**

```java
static final class NonfairSync extends Sync {
    NonfairSync(int permits) { super(permits); }

    protected int tryAcquireShared(int acquires) {
        return nonfairTryAcquireShared(acquires);
    }
}

// Sync 中的实现：
final int nonfairTryAcquireShared(int acquires) {
    for (;;) {
        int available = getState();
        int remaining = available - acquires;
        if (remaining < 0 || compareAndSetState(available, remaining))
            return remaining;
    }
}
```

**公平模式：**

```java
static final class FairSync extends Sync {
    protected int tryAcquireShared(int acquires) {
        for (;;) {
            // 关键区别：先检查是否有线程在排队
            if (hasQueuedPredecessors())
                return -1; // 有等待的线程，当前线程去排队
            int available = getState();
            int remaining = available - acquires;
            if (remaining < 0 || compareAndSetState(available, remaining))
                return remaining;
        }
    }
}
```

### 3.3 acquire() 与 release() 源码

```java
// 获取许可证
public void acquire() throws InterruptedException {
    sync.acquireSharedInterruptibly(1);
}

// 释放许可证
public void release() {
    sync.releaseShared(1);
}

// AQS.releaseShared:
public final boolean releaseShared(int arg) {
    if (tryReleaseShared(arg)) {
        doReleaseShared(); // 唤醒等待队列中的后继节点
        return true;
    }
    return false;
}

// Semaphore.Sync.tryReleaseShared:
protected final boolean tryReleaseShared(int releases) {
    for (;;) {
        int current = getState();
        int next = current + releases; // 增加许可
        if (next < current) // overflow
            throw new Error("Maximum permit count exceeded");
        if (compareAndSetState(current, next))
            return true; // 成功释放，触发 doReleaseShared
    }
}
```

### 3.4 实战：数据库连接池限流

```java
public class DatabaseConnectionPool {
    private final Semaphore semaphore;
    private final List<Connection> connections = new ArrayList<>();

    public DatabaseConnectionPool(int poolSize) {
        // 初始化连接
        for (int i = 0; i < poolSize; i++) {
            connections.add(createConnection());
        }
        semaphore = new Semaphore(poolSize, true); // 公平模式
    }

    public Connection getConnection() throws InterruptedException {
        semaphore.acquire(); // 获取许可，没有则阻塞
        return getNextAvailableConnection();
    }

    public void releaseConnection(Connection conn) {
        returnToPool(conn);
        semaphore.release(); // 释放许可
    }

    // 尝试获取（带超时）
    public Connection tryGetConnection(long timeout, TimeUnit unit)
            throws InterruptedException {
        if (semaphore.tryAcquire(timeout, unit)) {
            return getNextAvailableConnection();
        }
        return null; // 超时未获取到
    }

    private synchronized Connection getNextAvailableConnection() {
        // 轮询连接
        return connections.remove(0);
    }

    private synchronized void returnToPool(Connection conn) {
        connections.add(conn);
    }
}
```

### 3.5 面试 Q&A

**Q：Semaphore 能让单个线程同时获取多个许可吗？**

可以！`acquire(2)` 获取 2 个许可。但需要注意死锁风险——如果你需要 2 个许可但只获取到 1 个，会阻塞在队列中。

**Q：Semaphore 公平和非公平的区别？**

- **非公平**：新来的线程直接先尝试 CAS 获取许可，不排队。性能高，但可能造成线程饥饿。
- **公平**：严格 FIFO，性能较低但公平。

**Q：Semaphore 可以用作互斥锁吗？**

可以。`new Semaphore(1)` 相当于一个互斥锁，但与 ReentrantLock 不同的是，Semaphore 允许不同线程进行 acquire/release，而 ReentrantLock 要求持有锁的线程才能释放。

---

## 四、CyclicBarrier：可循环使用的屏障

### 4.1 核心概念

CyclicBarrier 让一组线程互相等待，直到所有线程都到达屏障（barrier）后，才一起继续执行。

```
         T1 → [到达屏障] ─┐
         T2 → [到达屏障] ─┼── [屏障打开] → T1、T2、T3 一起执行
         T3 → [到达屏障] ─┘

         可重复使用 ↓
         T4 → [到达屏障] ─┐
         T5 → [到达屏障] ─┼── [屏障打开] → T4、T5、T6 一起执行
         T6 → [到达屏障] ─┘
```

### 4.2 与 CountDownLatch 的关键区别

| 对比维度 | CountDownLatch | CyclicBarrier |
|---------|---------------|---------------|
| 核心机制 | 等待 count 归零 | 等待 parties 个线程到达 |
| 可重用 | ❌ 一次性的 | ✅ 调用 reset() 可重置 |
| 计数方向 | 递减（countDown） | 递增（到达后归零） |
| 参与者 | 不关心谁 countDown | 明确等待 parties 个线程 |
| action | ❌ 无 | ✅ 可选 barrierAction |
| 底层 | AQS 共享模式 | ReentrantLock + Condition |

### 4.3 源码分析：ReentrantLock + Condition 实现

CyclicBarrier 没有用 AQS，而是用 ReentrantLock + Condition：

```java
public class CyclicBarrier {
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition trip = lock.newCondition();
    private final int parties;           // 屏障等待的线程数
    private final Runnable barrierCommand; // 屏障打开时执行的动作
    private Generation generation = new Generation(); // 代（用于复用）

    private int count; // 剩余未到达的线程数（递减）

    private static class Generation {
        boolean broken = false; // 屏障是否被打破
    }
}
```

**核心逻辑 await()：**

```java
public int await() throws InterruptedException, BrokenBarrierException {
    try {
        return dowait(false, 0L);
    } catch (TimeoutException toe) {
        throw new Error(toe);
    }
}

private int dowait(boolean timed, long nanos)
        throws InterruptedException, BrokenBarrierException, TimeoutException {
    final ReentrantLock lock = this.lock;
    lock.lock(); // 加锁
    try {
        final Generation g = generation;

        if (g.broken)
            throw new BrokenBarrierException();

        if (Thread.interrupted()) {
            breakBarrier(); // 线程中断 → 打破屏障
            throw new InterruptedException();
        }

        int index = --count; // 到达一个线程，count 减 1
        if (index == 0) {    // 所有线程都到达了！
            boolean ranAction = false;
            try {
                final Runnable command = barrierCommand;
                if (command != null)
                    command.run(); // 执行屏障动作（在最后一个到达的线程中执行）
                ranAction = true;
                nextGeneration(); // 进入下一代，唤醒所有等待线程
                return 0;
            } finally {
                if (!ranAction)
                    breakBarrier(); // 异常 → 打破屏障
            }
        }

        // count != 0，进入等待循环
        for (;;) {
            try {
                if (!timed)
                    trip.await();          // condition.await()
                else if (nanos > 0)
                    nanos = trip.awaitNanos(nanos);
            } catch (InterruptedException ie) {
                if (g == generation && !g.broken) {
                    breakBarrier();
                    throw ie;
                }
                Thread.currentThread().interrupt();
            }

            if (g.broken)
                throw new BrokenBarrierException();
            if (g != generation)
                return index; // 下一代已开始，返回
            if (timed && nanos <= 0) {
                breakBarrier(); // 超时 → 打破屏障
                throw new TimeoutException();
            }
        }
    } finally {
        lock.unlock();
    }
}
```

**重置逻辑 nextGeneration()：**

```java
private void nextGeneration() {
    trip.signalAll();  // 唤醒所有等待线程
    count = parties;   // 重置计数器
    generation = new Generation(); // 创建新的一代
}

// 打破屏障
private void breakBarrier() {
    generation.broken = true;
    count = parties;
    trip.signalAll();
}
```

### 4.4 实战：并行计算与数据合并

```java
// 场景：分页查询多个数据源，汇总结果
public class DataAggregationTask {
    private static final int PAGE_COUNT = 3;
    private final List<String> results = new CopyOnWriteArrayList<>();
    private final CyclicBarrier barrier;

    public DataAggregationTask() {
        // 所有查询完成后，执行汇总操作
        barrier = new CyclicBarrier(PAGE_COUNT, () -> {
            System.out.println("=== 所有数据查询完成，开始汇总 ===");
            System.out.println("总记录数: " + results.size());
            results.forEach(r -> System.out.println("  - " + r));
        });
    }

    public void queryData(String queryParam) {
        ExecutorService executor = Executors.newFixedThreadPool(PAGE_COUNT);
        for (int i = 0; i < PAGE_COUNT; i++) {
            final int page = i;
            executor.submit(() -> {
                try {
                    // 模拟查询数据库
                    Thread.sleep((long) (Math.random() * 2000));
                    String result = "page=" + page + ", query=" + queryParam;
                    results.add(result);
                    System.out.println("查询完成: " + result);
                    barrier.await(); // 等待其他线程
                } catch (Exception e) {
                    e.printStackTrace();
                }
            });
        }
        executor.shutdown();
    }

    public static void main(String[] args) {
        DataAggregationTask task = new DataAggregationTask();
        task.queryData("user:active");

        // 第二次复用
        try { Thread.sleep(5000); } catch (InterruptedException e) {}
        task.queryData("order:pending");
    }
}
```

### 4.5 超时与异常处理

```java
CyclicBarrier barrier = new CyclicBarrier(3);

// 超时等待
try {
    barrier.await(3, TimeUnit.SECONDS);
} catch (TimeoutException e) {
    // 超时：屏障被打破，其他线程收到 BrokenBarrierException
} catch (BrokenBarrierException e) {
    // 屏障已被打破（其他线程超时或中断）
} catch (InterruptedException e) {
    // 当前线程被中断
}

// 检查屏障状态
barrier.isBroken();     // 是否被打破
barrier.getParties();   // 等待的线程总数
barrier.getNumberWaiting(); // 当前正在等待的线程数
barrier.reset();        // 强制重置（谨慎使用，等待中的线程会抛 BrokenBarrierException）
```

---

## 五、三大同步器对比总结

### 5.1 核心对比

| 特性 | CountDownLatch | CyclicBarrier | Semaphore |
|------|---------------|---------------|-----------|
| **本质** | 1→N 通知 | N→N 等待 | 资源许可控制 |
| **底层** | AQS 共享模式 | ReentrantLock + Condition | AQS 共享模式 |
| **计数器** | N→0 (递减) | N→0→N (循环) | 可增可减 |
| **可重用** | ❌ | ✅ reset() | ✅ |
| **等待者** | 等待 count 归零 | 等待 parties 个线程 | 等待获取许可 |
| **触发动作** | ❌ | ✅ barrierAction | ❌ |
| **常见用途** | 服务启动、并行任务 | 分步计算、数据聚合 | 限流、资源池 |

### 5.2 选型决策

```
需要等待其他线程完成？
├── 只需等待一次 → CountDownLatch
├── 需要循环使用 → CyclicBarrier
└── 需要结果汇总 → CyclicBarrier + barrierAction

需要限制并发量？
└── 限制同时访问资源的线程数 → Semaphore
```

### 5.3 常见面试追问

**Q：CountDownLatch 的 count 归零后，继续 await 会怎样？**

不会阻塞，`tryAcquireShared` 直接返回 1（获取成功），`await()` 立即返回。

**Q：CyclicBarrier 的线程数可以动态变化吗？**

不能。`parties` 在构造时固定，`reset()` 会恢复初始值。但可以用 `Phaser`（JDK 7+）来支持动态注册的屏障。

**Q：Semaphore 能用来实现连接池吗？为什么不用阻塞队列？**

可以。Semaphore + 链表实现的连接池很常见。阻塞队列更简单（直接 take/offer），但 Semaphore 提供了更细粒度的控制（公平模式、超时、批量获取）。

**Q：使用这些同步器有什么常见坑？**

1. CountDownLatch 忘记 countDown → 永远阻塞（务必放在 finally 中）
2. CyclicBarrier 线程中断 → BrokenBarrierException（需处理异常）
3. Semaphore 忘记 release → 许可证泄漏（务必放在 finally 中）
4. CyclicBarrier 和线程池大小不一致 → 如果线程池 < parties，部分线程永远无法到达

---

## 总结

| 同步器 | 一句话 | 源码精髓 |
|--------|-------|---------|
| CountDownLatch | 等倒计时结束 | AQS state = count，归零唤醒 |
| CyclicBarrier | 等人齐了一起走 | ReentrantLock + Condition，wait/signalAll 模式 |
| Semaphore | 凭许可证才能干活 | AQS state = permits，CAS 增减 |

掌握了 AQS，你就掌握了 Java 并发工具的半壁江山。这三兄弟虽然 API 简单，但源码设计极其精妙，值得反复阅读。
