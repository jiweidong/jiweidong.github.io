---
title: 【并发编程】ReadWriteLock 与 StampedLock 深度解析：并发读写的锁优化之路
date: 2026-07-07 08:00:00
tags:
  - Java
  - 并发编程
  - 锁
  - 性能优化
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】ReadWriteLock 与 StampedLock 深度解析：并发读写的锁优化之路

## 从读写分离说起

在高并发场景中，"读多写少"是一个非常典型的数据访问模式。比如缓存系统、配置中心、黑名单校验——读操作远远多于写操作。

如果我们一刀切地用 `synchronized` 或 `ReentrantLock` 来保护共享资源，所有线程无论是读还是写都必须串行执行，这对读操作密集的场景来说无疑是巨大的性能浪费。

**核心思想很简单**：多个读操作之间并不互斥，它们可以同时进行；只有写-写、读-写之间才需要互斥。这就是读写锁（ReadWriteLock）的设计出发点。

Java 提供了两种读写锁实现：
- **ReentrantReadWriteLock** — 经典的读写锁，JDK 5 引入
- **StampedLock** — JDK 8 引入，更进一步支持乐观读，性能更优

本文将从源码层面深入分析二者的实现原理、适用场景与性能对比。

---

## 一、ReentrantReadWriteLock 源码深入分析

### 1.1 核心设计：一个状态位，两种模式

`ReentrantReadWriteLock` 依赖 AQS（AbstractQueuedSynchronizer）实现，但它的同步状态（`state`）比较特殊：

> **一个 int 类型的 state 被切分成两部分：高 16 位表示读锁的持有数，低 16 位表示写锁的重入数。**

```java
// 读锁计数偏移量
static final int SHARED_SHIFT   = 16;
// 读锁单位值（1 左移 16 位）
static final int SHARED_UNIT    = (1 << SHARED_SHIFT);
// 读锁最大持有数
static final int MAX_COUNT      = (1 << SHARED_SHIFT) - 1;
// 写锁重入次数的掩码
static final int EXCLUSIVE_MASK = (1 << SHARED_SHIFT) - 1;

// 获取读锁持有数：state 无符号右移 16 位
static int sharedCount(int c)    { return c >>> SHARED_SHIFT; }
// 获取写锁重入数：state & 低16位掩码
static int exclusiveCount(int c) { return c & EXCLUSIVE_MASK; }
```

**这样做的好处**：一个 int 变量同时记录两种状态，无需额外的成员变量，CAS 操作一次完成。

### 1.2 写锁的获取与释放

写锁是独占锁。当线程尝试获取写锁时，AQS 的 `tryAcquire()` 会被调用：

```java
protected final boolean tryAcquire(int acquires) {
    Thread current = Thread.currentThread();
    int c = getState();
    int w = exclusiveCount(c);

    if (c != 0) {
        // 有线程持有锁：要么是读锁被占用，要么是写锁被其他线程占用
        if (w == 0 || current != getExclusiveOwnerThread())
            return false;
        // 当前线程已经持有写锁，检查重入上限
        if (w + exclusiveCount(acquires) > MAX_COUNT)
            throw new Error("Maximum lock count exceeded");
        setState(c + acquires);
        return true;
    }
    // 无锁状态：需要满足写公平性要求
    if (writerShouldBlock() || !compareAndSetState(c, c + acquires))
        return false;
    setExclusiveOwnerThread(current);
    return true;
}
```

**写锁获取的关键逻辑**：
1. 如果 `state != 0`，要么读锁被占用，要么写锁被其他线程占用，写锁获取失败
2. 如果是当前线程已持有写锁，重入计数累加
3. 无锁状态下，检查写是否需要阻塞（公平/非公平策略），CAS 设置状态

写锁的释放对应 `tryRelease()`：

```java
protected final boolean tryRelease(int releases) {
    if (!isHeldExclusively())
        throw new IllegalMonitorStateException();
    int nextc = getState() - releases;
    boolean free = exclusiveCount(nextc) == 0;
    if (free)
        setExclusiveOwnerThread(null);
    setState(nextc);
    return free;
}
```

### 1.3 读锁的获取与释放

读锁是共享锁。多个线程可以同时持有读锁：

```java
protected final int tryAcquireShared(int unused) {
    Thread current = Thread.currentThread();
    int c = getState();

    // 写锁被其他线程持有 → 读锁获取失败
    if (exclusiveCount(c) != 0 && getExclusiveOwnerThread() != current)
        return -1;

    int r = sharedCount(c);
    // 读不需要阻塞 && 读锁未满 && CAS 成功
    if (!readerShouldBlock() && r < MAX_COUNT && compareAndSetState(c, c + SHARED_UNIT)) {
        // 第一个读线程
        if (r == 0) {
            firstReader = current;
            firstReaderHoldCount = 1;
        } else if (firstReader == current) {
            firstReaderHoldCount++;
        } else {
            // 记录每个线程的读锁重入数
            HoldCounter rh = cachedHoldCounter;
            if (rh == null || rh.tid != getThreadId(current))
                cachedHoldCounter = rh = readHolds.get();
            else if (rh.count == 0)
                readHolds.set(rh);
            rh.count++;
        }
        return 1;
    }
    return fullTryAcquireShared(current);
}
```

### 1.4 读锁重入计数：ThreadLocal 的妙用

注意到代码中出现了 `firstReader`、`cachedHoldCounter`、`readHolds（ThreadLocal）`。为什么需要这么复杂？

**原因**：读锁的 state 只记录总持有数，但 Java 的锁可重入特性要求知道每个线程各自的重入次数。

`ReentrantReadWriteLock` 做了双重优化：
1. **firstReader**：记录第一个获取读锁的线程，避免频繁操作 ThreadLocal
2. **cachedHoldCounter**：缓存最后一个操作读锁的线程计数，利用时间局部性
3. **readHolds（ThreadLocal）**：兜底方案，每个线程自己的计数器

### 1.5 公平 vs 非公平

**非公平模式（默认）**：
- 读锁：`readerShouldBlock()` 检查等待队列头部是否是写锁请求，如果不是则允许插队
- 写锁：`writerShouldBlock()` 直接返回 false，写锁可以插队

**公平模式**：
- 读锁和写锁都检查队列中是否有前驱节点，严格 FIFO

### 1.6 锁降级

`ReentrantReadWriteLock` 支持**锁降级**：持有写锁的线程可以获取读锁，然后释放写锁，将写锁降级为读锁。

```java
// 示例：缓存更新中的锁降级
w.lock();         // 获取写锁
try {
    // 更新缓存...
    r.lock();     // 获取读锁（锁降级）
} finally {
    w.unlock();   // 释放写锁（此时仍持有读锁）
}
try {
    // 继续读...
} finally {
    r.unlock();   // 释放读锁
}
```

**注意**：只支持降级，不支持升级（持有读锁时获取写锁），因为读锁升级为写锁会导致死锁。

---

## 二、StampedLock：性能更激进的读写锁

`StampedLock` 是 JDK 8 引入的锁机制，它的设计目标是在读多写少场景下提供比 `ReentrantReadWriteLock` 更高的吞吐量。

### 2.1 与 ReadWriteLock 的核心区别

| 特性 | ReentrantReadWriteLock | StampedLock |
|------|----------------------|-------------|
| 实现方式 | AQS（CLH队列） | 自旋 + CLH 变体 |
| 锁模式 | 读锁、写锁 | 读锁、写锁、**乐观读** |
| 可重入 | 支持 | **不支持** |
| 锁升级/降级 | 降级 | 支持状态转换 |
| condition | 支持 | **不支持** |
| 适用场景 | 通用读写场景 | 读多写极少，性能敏感 |

### 2.2 三种锁模式详解

**写锁（Write Lock）**：
```java
long stamp = stampedLock.writeLock();  // 阻塞直到获取写锁
try {
    // 写操作...
} finally {
    stampedLock.unlockWrite(stamp);
}
```

**读锁（Read Lock）**：
```java
long stamp = stampedLock.readLock();  // 阻塞读锁
try {
    // 读操作...
} finally {
    stampedLock.unlockRead(stamp);
}
```

**乐观读（Optimistic Read）**：
```java
long stamp = stampedLock.tryOptimisticRead();  // 不阻塞
// 读操作（数据可能正在被写）
if (!stampedLock.validate(stamp)) {  // 检查是否有写操作发生
    stamp = stampedLock.readLock();   // 升级为悲观读
    try {
        // 重新读取...
    } finally {
        stampedLock.unlockRead(stamp);
    }
}
```

### 2.3 乐观读的精妙设计

`stampedLock` 的 state 是一个 64 位的 long：

```
写锁位 | 读锁计数（第8位开始） | 版本戳（低8位）
```

当调用 `tryOptimisticRead()` 时：

```java
public long tryOptimisticRead() {
    long s;
    return (((s = state) & WBIT) == 0L) ? (s & SBITS) : 0L;
}
```

- 如果没有写锁被持有（`(state & WBIT) == 0`），返回当前状态的版本戳
- 如果有写锁，返回 0（验证永远失败）

当调用 `validate(stamp)` 时：

```java
public boolean validate(long stamp) {
    return (stamp & SBITS) == (state & SBITS);
}
```

- 检查在获取 stamp 到验证之间，是否有写操作修改了 state
- 如果没有写操作，状态不变，验证通过
- 如果发生过写操作，状态已变，验证失败

**乐观读的本质**：在读取数据前不获取任何锁，只是在读取前后各取一个"版本快照"。如果版本没有变化，说明读取过程中没有写操作发生，数据是有效的。

### 2.4 源码实现：自旋 + CLH 队列

`StampedLock` 的内部实现比 `ReentrantReadWriteLock` 更轻量：

**写锁获取**：
```java
public long writeLock() {
    long s, next;
    // 尝试 CAS 获取（快速路径）
    if (((s = state) & ABITS) == 0L && U.compareAndSwapLong(this, STATE, s, next = s + WBIT))
        return next;
    // 失败则进入自旋/阻塞
    return acquireWrite(false, 0L);
}
```

当 CAS 失败时，`acquireWrite()` 会先自旋一段时间（默认最多 1024 次），如果仍然获取不到才进入阻塞队列。

这种**自旋优先**的策略在锁持有时间很短的场景下尤为重要——避免了线程上下文切换的开销。

---

## 三、性能对比与实战选择

### 3.1 JMH 基准测试对比

| 场景 | synchronized | ReentrantLock | ReadWriteLock | StampedLock(乐观读) |
|-----|------------|--------------|--------------|-------------------|
| 纯读（0% 写） | 1x | 1.1x | 3.5x | **8-10x** |
| 低频写（5% 写） | 1x | 1.1x | 2.5x | **4-5x** |
| 中等写（20% 写） | 1x | 1.1x | 1.5x | 1.8x |
| 高频写（50% 写） | 1x | 1.1x | 0.8x | 0.6x |

> StampedLock 的乐观读在写操作极少时优势巨大，但随着写频率升高，乐观读失败率增加，重试成本上升，性能优势会减弱。

### 3.2 选型建议

| 场景 | 推荐方案 |
|-----|---------|
| 缓存更新（读远多于写） | StampedLock 乐观读 |
| 配置中心（极少更新） | StampedLock 乐观读 |
| 黑名单校验（低频更新） | StampedLock 乐观读 |
| 通用读写比例未知 | ReentrantReadWriteLock |
| 需要可重入特性 | ReentrantReadWriteLock |
| 需要 Condition 通知 | ReentrantReadWriteLock |
| 写操作较频繁 | ReentrantLock / synchronized |

### 3.3 StampedLock 使用的坑

**1. 不可重入**
```java
StampedLock lock = new StampedLock();
long stamp = lock.writeLock();
// ... 不能再次获取写锁，否则死锁
```
当前线程已持有写锁时再次 `writeLock()` 会导致死锁，因为没有重入计数支持。

**2. 不支持 Condition**
```java
// 编译报错！StampedLock 没有 newCondition 方法
Condition condition = stampedLock.newCondition();
```

**3. 中断异常不友好**
```java
// StampedLock 的方法不响应中断
// 如果需要中断响应，使用 lockInterruptibly() 变体
stampedLock.writeLockInterruptibly();
```

**4. 乐观读的非重入校验陷阱**
```java
long stamp = lock.tryOptimisticRead();
// ... 读数据，可能被写线程修改
if (!lock.validate(stamp)) {
    // 数据被修改，这段代码不会重入到读到的数据中
    // 需要业务代码保证重新读取的线程安全
}
```

---

## 四、常见面试追问

### Q1：ReentrantReadWriteLock 为什么最多支持 65535 个读锁？
A：因为读锁用高 16 位计数，最大值为 2^16 - 1 = 65535。实际上单个线程可能重入上万次，但在高并发系统中应该避免这种情况。

### Q2：StampedLock 为什么不可重入？
A：为了性能。可重入需要在内部维护每个线程的持有计数（如 ThreadLocal），增加了内存开销和代码复杂度。StampedLock 追求极致性能，牺牲了可重入性。

### Q3：乐观读失败时如何重试？
A：一般模式是：获取乐观读戳 → 读数据 → 验证 → 如果失败获取悲观读锁 → 重新读取。注意重试时要避免无限循环，可以加入自旋次数的上限。

### Q4：锁降级有什么实际用途？
A：最典型的场景是缓存更新。先获取写锁更新数据，然后在释放写锁之前获取读锁（降级），确保其他线程在写锁释放后看到的数据是一致的。

---

## 总结

`ReentrantReadWriteLock` 和 `StampedLock` 是 Java 并发工具包中两个重要的读写锁实现：

- **ReentrantReadWriteLock** 基于 AQS，支持可重入、条件等待、锁降级，是通用读写场景的首选
- **StampedLock** 引入了乐观读机制，在读多写极少的场景下性能大幅领先，但不支持重入和 Condition

在实际项目中，应根据读写比例、是否需要重入、是否需要 Condition 等维度综合考量。对于缓存类读多写少场景，StampedLock 的乐观读往往能带来显著的性能提升。
