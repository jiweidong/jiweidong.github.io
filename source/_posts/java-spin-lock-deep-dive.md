---
title: 【并发编程】自旋锁深度解析：从 CAS 手写自旋到 CLH/MCS 队列锁与自适应自旋
date: 2026-08-24 09:00:00
tags:
  - Java
  - 并发
  - 锁
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】自旋锁深度解析：从 CAS 手写自旋到 CLH/MCS 队列锁与自适应自旋

## 面试官：为什么需要自旋锁？阻塞锁有什么问题？

阻塞锁（synchronized 重量级锁、`LockSupport.park()`）在锁竞争时会让线程进入阻塞态，但**阻塞和唤醒是有代价的**：

- 线程状态切换需要**上下文切换**（内核态切换，约 1~10 微秒级开销）；
- 阻塞线程需要**操作系统调度**，唤醒还有排队延迟；
- 频繁的「竞争 → 阻塞 → 唤醒」在锁持有时间极短时，开销甚至超过临界区本身。

自旋锁的思路很简单：**拿不到锁就不让出 CPU，原地空转（自旋）反复尝试，直到拿到锁**。如果临界区代码很短（比如只是一个 `count++`），自旋等待的消耗远小于线程挂起/唤醒的消耗。

```java
// 自旋锁 vs 阻塞锁的核心区别
// 阻塞：线程休眠，等唤醒（上下文切换）
synchronized (lock) { critical(); }

// 自旋：线程忙等，不停尝试
while (!lock.tryAcquire()) { /* 空转 */ }
```

一句话总结：**自旋是用 CPU 时间换线程切换开销，适合临界区极短、锁竞争不激烈的场景；临界区长或竞争激烈时自旋会白白烧 CPU**。

## 一、手写一个自旋锁：从 AtomicBoolean 到 AtomicReference

### 版本 1：AtomicBoolean 互斥自旋锁

```java
public class SpinLock {
    private final AtomicBoolean locked = new AtomicBoolean(false);

    public void lock() {
        // CAS：期望 false，置为 true；失败则自旋重试
        while (!locked.compareAndSet(false, true)) {
            // 自旋等待（可加 Thread.onSpinWait() 提示 CPU）
        }
    }

    public void unlock() {
        locked.set(false); // 释放
    }
}
```

**问题**：
1. **不公平**：后来者可能抢到（CAS 成功）而排队者饿死；
2. **无锁重入**：同一个线程重复 lock() 会死锁（自己把自己挡住）；
3. **缓存一致性开销**：所有线程自旋都读写同一个变量，争抢总线。

### 版本 2：支持可重入

```java
public class ReentrantSpinLock {
    private final AtomicReference<Thread> owner = new AtomicReference<>();
    private int count = 0; // 重入计数

    public void lock() {
        Thread t = Thread.currentThread();
        if (t == owner.get()) {      // 已持有：重入
            count++;
            return;
        }
        while (!owner.compareAndSet(null, t)) { } // 自旋抢锁
        count = 1;
    }

    public void unlock() {
        Thread t = Thread.currentThread();
        if (t == owner.get()) {
            if (--count == 0) owner.set(null); // 完全释放
        }
    }
}
```

### 版本 3：乐观锁式自旋（读写场景）

```java
// 经典的 CAS 自旋更新：AtomicInteger 的 incrementAndGet 内部就是自旋
public final int incrementAndGet() {
    for (;;) { // 自旋循环
        int cur = get();
        int next = cur + 1;
        if (compareAndSet(cur, next)) return next; // 失败就重读再试
    }
}
```

这正是 `AtomicInteger.incrementAndGet()` 的真实实现——**原子类的乐观重试本身就是一种自旋**。

## 二、自旋锁的公平性进化：TicketLock、CLH、MCS

普通自旋锁是「抢锁」模型，高并发下线程饥饿 + 缓存抖动严重。解决思路：**排队 + 每个线程只自旋自己的标志位**。

### TicketLock：取号排队
每个线程取一个递增号，自旋等待「叫号」到自己：

```java
public class TicketLock {
    private final AtomicInteger ticket = new AtomicInteger(); // 发号
    private final AtomicInteger serving = new AtomicInteger(); // 叫号

    public int lock() {
        int myTicket = ticket.getAndIncrement();
        while (serving.get() != myTicket) { } // 自旋等叫号
        return myTicket;
    }

    public void unlock(int myTicket) {
        serving.compareAndSet(myTicket, myTicket + 1); // 叫下一个
    }
}
```

公平了，但所有线程自旋读取同一个 `serving` 变量，**缓存行仍然共享**——这就是「伪共享（False Sharing）」问题。

### CLH 锁：每个线程自旋自己的前驱节点
每个线程在队列尾部追加自己的节点，然后**自旋检查前驱节点的状态**。前驱释放后自己成为队首，获得锁。

### MCS 锁：每个线程自旋自己的节点
CLH 的变体改进，自旋的是**自己的节点**（由前驱负责唤醒），对 **NUMA 架构**更友好——线程只访问自己本地内存的自旋变量，避免远程内存访问。

| 锁 | 公平性 | 自旋变量 | 适用架构 | 实现复杂度 |
| --- | --- | --- | --- | --- |
| 简单 CAS 自旋锁 | 不公平 | 共享变量（争抢） | 单核/少线程 | ★ |
| TicketLock | 公平 | 共享 serving（伪共享） | 多核 | ★★ |
| CLH | 公平 | 前驱节点 | SMP | ★★★ |
| MCS | 公平 | 自己的节点 | NUMA | ★★★★ |

**面试亮点**：能讲出「CLH 自旋前驱、MCS 自旋自己、解决 NUMA 下的远程内存访问」这一层，说明你真读过并发书籍源码。

## 三、JVM 里的自旋：从 synchronized 到 AQS

### 1. synchronized 的锁升级路径（JDK 6 之后）
```
无锁 → 偏向锁 → 轻量级锁（自旋） → 重量级锁（阻塞）
```
**轻量级锁**就是自旋锁思想的体现：线程用 CAS 把对象头 Mark Word 替换为自己的锁记录指针，失败则**自旋重试**（默认自旋 10 次，可通过 `-XX:PreBlockSpin` 调整）。自旋超过阈值或竞争加剧，才升级为重量级锁（阻塞 + 操作系统互斥量）。

### 2. 自适应自旋（JDK 6 优化）
不再固定自旋次数，而是**根据上一次自旋的结果动态调整**：如果上次自旋成功拿到锁，说明自旋价值高，这次允许自旋更多次；如果上次自旋失败（浪费时间），就减少甚至不自旋。这是「自适应」的含义——JVM 会「学习」每个锁的竞争规律。

### 3. AQS 中的自旋：acquireQueued
`ReentrantLock` 的 `lock()` 最终走到 AQS 的 `acquireQueued`：线程入队后，**先自旋尝试获取锁**（`for (;;)` 循环 + `shouldParkAfterFailedAcquire` 判断），只有前驱节点状态标记为 `SIGNAL`（确定自己会被唤醒）时才真正 `park()` 挂起。

```java
// AbstractQueuedSynchronizer.acquireQueued 核心（简化）
final boolean acquireQueued(final Node node, int arg) {
    boolean failed = true;
    try {
        for (;;) {                    // 自旋！
            final Node p = node.predecessor();
            if (p == head && tryAcquire(arg)) { // 队首才有资格抢
                setHead(node);
                failed = false;
                return interrupted;
            }
            // 该挂起时才挂起，不该挂起就继续自旋
            if (shouldParkAfterFailedAcquire(p, node) &&
                parkAndCheckInterrupt())
                interrupted = true;
        }
    } finally { ... }
}
```

**AQS 的精髓**：自旋 + 排队 + 必要时才阻塞，把「忙等」和「阻塞」两种策略动态结合，兼顾了短临界区的低延迟和长临界区的 CPU 友好。

### 4. Thread.onSpinWait()（Java 9+）
JVM 层面的自旋提示，告诉 CPU「我在忙等，可以做优化」（如 Intel 的 PAUSE 指令，降低功耗、减少流水线冲突）：

```java
while (!flag) {
    Thread.onSpinWait(); // 提示 CPU：这是有意的自旋
}
```

## 四、自旋 vs 阻塞：怎么选？

| 维度 | 自旋锁 | 阻塞锁 |
| --- | --- | --- |
| 等待开销 | CPU 空转（烧 CPU） | 上下文切换（烧时间） |
| 临界区短 | ✅ 极快 | 切换开销占比大 |
| 临界区长 | ❌ 浪费 CPU | ✅ 让出 CPU 更优 |
| 竞争激烈 | ❌ 大量线程空转 | ✅ 排队挂起更稳 |
| 公平性 | 默认不公平 | 可公平（ReentrantLock(true)） |
| 实现 | 简单（CAS 循环） | 复杂（AQS 队列 + park） |

**工程经验**：
- 临界区是纯内存操作且极短（< 几百纳秒）→ 自旋/原子类；
- 涉及 IO、锁内做数据库操作 → 必须用阻塞锁；
- 拿不准时优先用 JDK 提供的 `ReentrantLock`/`synchronized`（内部已做自适应），**不要在生产代码里手写自旋锁**；
- 想用无锁就用 `Atomic*`、`LongAdder`、`ConcurrentLinkedQueue`，它们的自旋已调优。

## 面试追问环节

**Q1：自旋锁有什么致命缺点？**
单核 CPU 上自旋毫无意义（自旋的线程占着 CPU，持锁线程反而没机会运行，可能死锁）；临界区长时浪费 CPU；无法保证公平；不可重入（需额外实现）。

**Q2：轻量级锁为什么会有自旋？升级重量级锁的触发条件？**
轻量级锁假设竞争不激烈，用自旋等待持锁线程释放；自旋次数超阈值（或 JDK 6+ 自适应判定自旋收益低）时升级为重量级锁，线程挂起进入阻塞队列。

**Q3：CAS 自旋的 ABA 问题怎么解决？**
加版本号/时间戳，`AtomicStampedReference` 或 `AtomicMarkableReference`；或使用不介意中间状态的场景（如计数累加）。

**Q4：synchronized 和 ReentrantLock 谁在自旋？**
两者底层都会自旋：synchronized 在轻量级锁阶段自旋；ReentrantLock 的 AQS 在 `acquireQueued` 里自旋 + park 结合。只是实现位置不同。

## 总结

- 自旋锁 = 忙等换锁，用 CPU 换上下文切换开销，适合短临界区；
- 手写自旋锁要解决公平性、可重入、伪共享三大问题；
- TicketLock/CLH/MCS 是公平自旋锁的进化路线，MCS 对 NUMA 友好；
- JVM 侧：轻量级锁自旋 → 自适应自旋 → AQS 自旋+park 混合策略；
- 生产首选 JDK 现成并发工具，自旋锁主要用于理解原理和面试。

把自旋锁这条线（CAS → 手写锁 → 队列锁 → JVM 自适应自旋 → AQS）串起来讲，并发这块的功底就体现出来了。
