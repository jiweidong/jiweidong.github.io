---
title: 【面试必备】Java 并发同步工具类深度解析：CountDownLatch、CyclicBarrier、Semaphore 与 Phaser
date: 2026-07-02 08:00:00
tags:
  - Java
  - 并发
  - AQS
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【面试必备】Java 并发同步工具类深度解析：CountDownLatch、CyclicBarrier、Semaphore 与 Phaser

## 引言

在 Java 并发编程中，除了 `synchronized`、`ReentrantLock` 和 `volatile` 这些基础同步手段，`java.util.concurrent` 包还提供了一组强大的同步工具类。本文将深入剖析 **CountDownLatch、CyclicBarrier、Semaphore 和 Phaser** 四大同步器的核心原理、源码实现与典型应用场景。

## 一、CountDownLatch：倒计时门闩

### 1.1 核心概念

`CountDownLatch` 允许一个或多个线程等待，直到在其他线程中执行的一组操作完成。它像一个**倒计时门闩**——初始设置一个计数值，每当一个线程完成任务后调用 `countDown()` 使计数器减1，计数器归零时，等待的线程被唤醒。

### 1.2 典型应用场景

**场景一：主线程等待多个子线程完成初始化**

```java
CountDownLatch latch = new CountDownLatch(3);

// 启动3个服务初始化线程
for (int i = 0; i < 3; i++) {
    new Thread(() -> {
        // 模拟服务启动
        TimeUnit.SECONDS.sleep(ThreadLocalRandom.current().nextInt(5));
        latch.countDown();
    }, "init-thread-" + i).start();
}

// 主线程等待所有服务初始化完成
latch.await();
System.out.println("所有服务已就绪，开始处理请求");
```

**场景二：并行测试——并发压测起跑线**

```java
CountDownLatch readyLatch = new CountDownLatch(1);  // 起跑线
CountDownLatch doneLatch = new CountDownLatch(10);   // 完成计数器

for (int i = 0; i < 10; i++) {
    new Thread(() -> {
        try {
            readyLatch.await();  // 所有线程就位后统一起跑
            // 执行并发请求...
        } finally {
            doneLatch.countDown();
        }
    }).start();
}

// 发令枪响
readyLatch.countDown();
// 等待所有线程完成
doneLatch.await();
```

### 1.3 源码分析

CountDownLatch 基于 AQS（AbstractQueuedSynchronizer）实现，内部定义了一个 **共享模式** 的同步器：

```java
// CountDownLatch 内部类
private static final class Sync extends AbstractQueuedSynchronizer {
    Sync(int count) {
        setState(count);  // 初始化 AQS 的 state
    }

    int getCount() {
        return getState();
    }

    // 尝试获取共享锁：state == 0 时才允许通过
    protected int tryAcquireShared(int acquires) {
        return (getState() == 0) ? 1 : -1;
    }

    // 尝试释放共享锁：CAS 减1
    protected boolean tryReleaseShared(int releases) {
        for (;;) {
            int c = getState();
            if (c == 0)
                return false;
            int nextc = c - 1;
            if (compareAndSetState(c, nextc))
                return nextc == 0;  // 只有归零时才唤醒等待线程
        }
    }
}
```

**关键设计点：**
- `countDown()` → 调用 `releaseShared(1)`，每次 CAS 减1，归零时唤醒等待队列
- `await()` → 调用 `acquireSharedInterruptibly(1)`，state ≠ 0 时线程阻塞
- **不可重用** — 计数归零后该实例永久失效

### 1.4 面试追问

> **Q：CountDownLatch 为什么不可重用？**
> **A：** 其设计意图就是一次性门闩。重新设置 state 会导致 state 从 0 变成正数，已经唤醒的线程可能重新进入等待，破坏语义。需要可重用请使用 CyclicBarrier。

---

## 二、CyclicBarrier：可循环屏障

### 2.1 核心概念

`CyclicBarrier` 允许一组线程全部到达某个屏障点时互相等待，全部到达后屏障打开，所有线程继续执行。与 CountDownLatch 最大的区别在于 **可循环使用**（reset）。

### 2.2 典型场景：分段并行计算

```java
CyclicBarrier barrier = new CyclicBarrier(3, () -> {
    System.out.println("所有线程到达屏障，进入下一轮计算");
});

for (int i = 0; i < 3; i++) {
    new Thread(() -> {
        for (int round = 1; round <= 3; round++) {
            // 执行第 round 轮计算...
            System.out.println(Thread.currentThread().getName() + " 完成第 " + round + " 轮");
            barrier.await();  // 等待其他线程
        }
    }, "worker-" + i).start();
}
```

### 2.3 核心源码解析

CyclicBarrier 基于 **ReentrantLock + Condition** 实现，而非 AQS 的直接子类：

```java
public class CyclicBarrier {
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition trip = lock.newCondition();
    private final int parties;    // 参与线程数
    private final Runnable barrierCommand;  // 屏障打开时的回调
    private int count;            // 剩余等待线程数
    private Generation generation = new Generation();  // 当前代

    private static class Generation {
        boolean broken = false;  // 是否被打破
    }

    public int await() throws InterruptedException, BrokenBarrierException {
        try {
            return dowait(false, 0L);
        } catch (BrokenBarrierException e) {
            ...
        }
    }

    private int dowait(boolean timed, long nanos) throws ... {
        final ReentrantLock lock = this.lock;
        lock.lock();
        try {
            final Generation g = generation;
            if (g.broken) throw new BrokenBarrierException();

            int index = --count;  // 剩余等待数减1
            if (index == 0) {     // 最后一个到达的线程
                // 执行回调（如果有）
                if (barrierCommand != null) barrierCommand.run();
                // 唤醒所有等待线程，重置到下一代
                nextGeneration();
                return 0;
            }

            // 非最后一个线程，进入等待
            for (;;) {
                try {
                    if (!timed) trip.await();
                } catch (InterruptedException ie) {
                    breakBarrier();  // 中断时打破屏障
                    throw ie;
                }
                if (g.broken) throw new BrokenBarrierException();
                if (g != generation) return index;  // 已换代，正常返回
            }
        } finally {
            lock.unlock();
        }
    }

    private void nextGeneration() {
        trip.signalAll();       // 唤醒所有等待线程
        count = parties;        // 重置计数器
        generation = new Generation();  // 创建新代
    }
}
```

### 2.4 CountDownLatch vs CyclicBarrier 对比

| 维度 | CountDownLatch | CyclicBarrier |
|------|---------------|---------------|
| 可重用 | ❌ 一次性 | ✅ 可重复使用 |
| 实现机制 | AQS 共享模式 | ReentrantLock + Condition |
| 参与者 | 等待者不参与计数 | 所有线程都是参与者 |
| 回调机制 | 无 | 支持 barrierAction |
| 计数方式 | countDown() 减少计数 | await() 到达屏障后减少计数 |
| 经典比喻 | 发令枪 + 终点线 | 起跑线 + 接力点 |

---

## 三、Semaphore：信号量

### 3.1 核心概念

`Semaphore` 维护一个许可集，线程获取许可后才能执行，使用完释放许可。用于 **限流/资源池控制**。

### 3.2 实战：数据库连接池限流

```java
Semaphore semaphore = new Semaphore(5);  // 最多5个并发连接

public void executeQuery(String sql) {
    try {
        semaphore.acquire();  // 获取许可，无许可时阻塞
        // 执行数据库查询...
    } finally {
        semaphore.release();  // 释放许可
    }
}
```

### 3.3 核心源码：公平与非公平模式

Semaphore 内部同样基于 AQS，支持**公平**和**非公平**两种模式：

```java
// 非公平模式（默认）
static final class NonfairSync extends Sync {
    protected int tryAcquireShared(int acquires) {
        return nonfairTryAcquireShared(acquires);
    }
}

// 公平模式
static final class FairSync extends Sync {
    protected int tryAcquireShared(int acquires) {
        for (;;) {
            // 关键区别：先检查同步队列中是否有等待线程
            if (hasQueuedPredecessors())
                return -1;
            int available = getState();
            int remaining = available - acquires;
            if (remaining < 0 || compareAndSetState(available, remaining))
                return remaining;
        }
    }
}
```

**非公平模式**：直接 CAS 抢许可，抢不到再入队等待
**公平模式**：先看队列有没有人等，有则排队，没有才尝试获取

### 3.4 Semaphore 使用注意事项

```java
// ❌ 错误：不在 finally 中 release，可能导致泄漏
semaphore.acquire();
// 如果这里抛异常，许可永远不回！

// ✅ 正确写法
semaphore.acquire();
try {
    // 业务逻辑
} finally {
    semaphore.release();
}

// ✅ tryAcquire 超时版
if (semaphore.tryAcquire(3, TimeUnit.SECONDS)) {
    try {
        // ...
    } finally {
        semaphore.release();
    }
} else {
    System.out.println("获取许可超时，降级处理");
}
```

---

## 四、Phaser：灵活的分阶段同步器

### 4.1 核心概念

`Phaser` 是 JDK 7 引入的**分阶段同步器**，可以看作 CountDownLatch + CyclicBarrier 的增强版。它支持**动态调整参与者数量**，每个 Phaser 实例管理一个阶段号。

### 4.2 三个核心优势

1. **参与者动态注册** — 运行时可以 `register()` / `bulkRegister()`
2. **阶段自动推进** — 每完成一个阶段，phase 递增
3. **层级 Phaser 树** — 大任务分而治之

```java
Phaser phaser = new Phaser(3) {
    // 每个阶段完成的回调
    @Override
    protected boolean onAdvance(int phase, int registeredParties) {
        System.out.println("阶段 " + phase + " 完成，当前参与数: " + registeredParties);
        return registeredParties == 0;  // 返回 true 则终止 Phaser
    }
};
```

### 4.3 实战：动态注册的并行计算

```java
Phaser phaser = new Phaser();
phaser.bulkRegister(3);  // 先注册3个参与者

for (int i = 0; i < 3; i++) {
    new Thread(() -> {
        for (int phase = 0; phase < 2; phase++) {
            // 执行阶段任务
            System.out.println(Thread.currentThread().getName() + " 完成阶段 " + phase);
            phaser.arriveAndAwaitAdvance();  // 到达并等待
        }
    }).start();
}

// 主线程也可以参与
phaser.register();
phaser.arriveAndDeregister();  // 到达后注销自己

// 等待所有阶段完成
while (!phaser.isTerminated()) {
    phaser.awaitAdvance(phaser.getPhase());
}
```

### 4.4 常见方法速查表

| 方法 | 行为 |
|------|------|
| `register()` / `bulkRegister(n)` | 动态增加参与者 |
| `arrive()` | 到达但不等其他人 |
| `arriveAndAwaitAdvance()` | 到达并等待本阶段所有人到齐 |
| `arriveAndDeregister()` | 到达后注销，总参与者减1 |
| `awaitAdvance(phase)` | 等待指定阶段完成 |
| `forceTermination()` | 强制终止 |
| `onAdvance(phase, parties)` | 阶段推进回调，可重写 |

---

## 五、四大同步器对比总结

| 特性 | CountDownLatch | CyclicBarrier | Semaphore | Phaser |
|------|---------------|---------------|-----------|--------|
| 引入版本 | JDK 5 | JDK 5 | JDK 5 | JDK 7 |
| 底层实现 | AQS共享锁 | ReentrantLock + Condition | AQS共享锁 | AQS + Spin |
| 重用性 | ❌ | ✅ (reset) | ✅ | ✅ (自动推进) |
| 动态注册 | ❌ | ❌ | ❌ | ✅ |
| 回调机制 | ❌ | ✅ barrierAction | ❌ | ✅ onAdvance |
| 核心用途 | 等待完成 | 等待汇合 | 限流控制 | 分阶段任务 |
| 公平性 | 不可控 | 不可控 | ✅ Fair/Nonfair | 不可控 |

---

## 六、面试高频追问与避坑指南

### Q1：`await()` 和 `countDown()` 调用顺序有要求吗？
**A：** 没有严格顺序要求。但注意 `countDown()` 调用次数必须 >= 初始化计数，否则 `await()` 线程永远等待。

### Q2：CyclicBarrier 的 BrokenBarrierException 什么情况下抛出？
**A：** 三个场景：① 某个线程 `await()` 超时；② 某个线程被中断；③ 显式调用 `reset()`。此时屏障被打破，已等待的线程全部抛出该异常。

### Q3：Phaser 的分层树结构有什么用？
**A：** 当参与者数量极大时（数万个），单 Phaser 的性能瓶颈在 AQS 队列竞争。分层后，子 Phaser 各自协调自己的参与者，再与根 Phaser 协调，大幅减少竞争。

### Q4：Semaphore 可以用来实现互斥锁吗？
**A：** 可以！`new Semaphore(1)` 就是互斥语义，称为**二元信号量**。但不如直接使用 `ReentrantLock`，因为后者有更丰富的能力（可重入、条件变量等）。

### Q5：Phaser 的 `arriveAndAwaitAdvance()` 和 `arrive()` + `awaitAdvance(phase)` 有什么区别？
**A：** `arriveAndAwaitAdvance()` 是原子的：先到达并通知他人，再等待本阶段完成。分开调用可能导致竞态——arrive 后其他线程看到已到齐就推进阶段，当前线程再 awaitAdvance 时已经是下一阶段了。

---

## 总结

这四大同步工具类的底层都离不开 **AQS** 或 **Lock + Condition**，但各自的语义和用途差异明显：

- **CountDownLatch**：一次性门闩，等事件完成
- **CyclicBarrier**：可循环屏障，等线程到齐
- **Semaphore**：信号量，资源限流
- **Phaser**：分阶段同步器，灵活多变

面试中不仅要会使用，更要理解底层源码设计。建议手写一个 AQS 的实现来加深理解。记住一句话：**理解 AQS，你就理解了 J.U.C 的半壁江山。**
