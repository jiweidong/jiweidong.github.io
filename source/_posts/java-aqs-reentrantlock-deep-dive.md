---
title: 面试官：说说 ReentrantLock 与 AQS 的底层原理？
date: 2026-06-21 08:00:00
tags:
  - Java
  - 并发
  - AQS
  - 源码分析
categories:
  - Java
  - 后端面试
author: 东哥
---

# 面试官：说说 ReentrantLock 与 AQS 的底层原理？

## 面试官：先说说 ReentrantLock 和 Synchronized 的区别？

这是并发领域最经典的问题了。简单总结一下：

| 特性 | Synchronized | ReentrantLock |
|------|-------------|---------------|
| 实现方式 | JVM 关键字 | JDK API（AQS 实现） |
| 锁类型 | 非公平 | 公平/非公平可选 |
| 可重入 | ✅ | ✅ |
| 可中断 | ❌ 不响应中断 | ✅ lockInterruptibly() |
| 超时 | ❌ | ✅ tryLock(time, unit) |
| 条件队列 | 1个（wait/notify） | 多个 Condition |
| 灵活性 | 低 | 高（tryLock、轮询） |
| 释放锁 | 自动释放 | 手动 unlock（需 finally） |

```java
// ReentrantLock 标准用法
public class LockDemo {
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition notEmpty = lock.newCondition();
    
    public void doSomething() {
        lock.lock();    // 获取锁
        try {
            // 临界区
            notEmpty.await();    // 条件等待
        } finally {
            lock.unlock();  // 一定要在 finally 中释放
        }
    }
}
```

## 面试官：那你知道 ReentrantLock 的核心实现依赖 AQS 吗？先说说 AQS 是什么？

AQS 的全称是 **AbstractQueuedSynchronizer**（抽象队列同步器），是 JDK 并发包的核心基础设施。看名字就知道它干了什么：**用队列实现同步器**。

它是 JUC 锁和同步器的"骨架"：

```
        AbstractQueuedSynchronizer (AQS)
        ┌────────────────────────────┐
        │     state（volatile int）    │ ← 资源状态
        │     CLH 队列（FIFO）          │ ← 等待队列
        │     独占/共享模式            │
        └────────────────────────────┘
                    │
        ┌───────────┼───────────────┐
        │           │               │
    ReentrantLock  Semaphore   CountDownLatch
        │           │               │
    ReentrantReadWriteLock    CyclicBarrier
```

AQS 的设计模式——**模板方法模式**：定义好骨架（入队、出队、阻塞、唤醒），具体的"如何判断获取锁成功"交给子类实现。

AQS 子类需要实现的 5 个方法：

| 方法 | 用途 | 锁典型实现 |
|------|------|-----------|
| tryAcquire(int) | 独占式获取锁 | ReentrantLock |
| tryRelease(int) | 独占式释放锁 | ReentrantLock |
| tryAcquireShared(int) | 共享式获取资源 | Semaphore、CountDownLatch |
| tryReleaseShared(int) | 共享式释放资源 | Semaphore、CountDownLatch |
| isHeldExclusively() | 是否独占模式 | ReentrantLock |

## 面试官：好，那从 ReentrantLock 的非公平锁讲起，非公平锁加锁怎么实现的？

### 非公平锁的加锁过程

```java
// ReentrantLock 构造器
public ReentrantLock() {
    sync = new NonfairSync();  // 默认非公平锁
}

// NonfairSync.lock()
final void lock() {
    // ◆ 第一步：上来就抢（插队）
    if (compareAndSetState(0, 1)) {
        // 抢到锁，设置当前线程为独占线程
        setExclusiveOwnerThread(Thread.currentThread());
    } else {
        // 没抢到，进入标准获取流程
        acquire(1);
    }
}
```

"非公平"体现在哪里？就体现在进入 acquire 之前，**先尝试 CAS 抢一把**，不管队列里有没有人在等。这就是所谓的"插队"。

```java
// AbstractQueuedSynchronizer.acquire()
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&           // 步骤1：尝试获取锁
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))  // 步骤2+3
        Thread.currentThread().interrupt();  // 步骤4
}
```

### tryAcquire——尝试获取锁

```java
// NonfairSync.tryAcquire()
protected final boolean tryAcquire(int acquires) {
    return nonfairTryAcquire(acquires);
}

// Sync.nonfairTryAcquire()
final boolean nonfairTryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState();           // 获取当前 state 值
    if (c == 0) {                 // 锁没有被占用
        // ◆ 非公平：再来一次 CAS 抢锁
        if (compareAndSetState(0, acquires)) {
            setExclusiveOwnerThread(current);
            return true;
        }
    } else if (current == getExclusiveOwnerThread()) {
        // ◆ 可重入：state + 1
        int nextc = c + acquires;
        if (nextc < 0) // overflow
            throw new Error("Maximum lock count exceeded");
        setState(nextc);
        return true;
    }
    return false;
}
```

**关键洞察**：可重入的实现方式就是 **state 累加**。同一个线程每获取一次锁，state 就 +1；释放时 -1，减到 0 才算真正释放。

## 面试官：那 acquireQueued 和 addWaiter 是怎么实现排队等待的？

### addWaiter——将线程封装成 Node 加入等待队列

```java
private Node addWaiter(Node mode) {
    Node node = new Node(Thread.currentThread(), mode);
    // 尝试快速入队（尾插法）
    Node pred = tail;
    if (pred != null) {
        node.prev = pred;
        if (compareAndSetTail(pred, node)) {
            pred.next = node;
            return node;
        }
    }
    // 快速入队失败，执行完整入队流程
    enq(node);
    return node;
}

// 完整入队
private Node enq(final Node node) {
    for (;;) {
        Node t = tail;
        if (t == null) { // 队列为空，初始化头节点
            if (compareAndSetHead(new Node()))
                tail = head;
        } else {
            node.prev = t;
            if (compareAndSetTail(t, node)) {
                t.next = node;
                return t;
            }
        }
    }
}
```

AQS 的队列是一个 **CLH 锁的变体**，FIFO 双向链表：

```
      head                                    tail
        │                                      │
        ▼                                      ▼
  ┌──────────┐    ┌──────────┐    ┌──────────┐
  │  dummy   │◄──►│  Node 1  │◄──►│  Node 2  │
  │ (空节点)  │    │ Thread A │    │ Thread B │
  └──────────┘    └──────────┘    └──────────┘
```

### acquireQueued——排队自旋

```java
final boolean acquireQueued(final Node node, int arg) {
    boolean failed = true;
    try {
        boolean interrupted = false;
        for (;;) {
            final Node p = node.predecessor();  // 前驱节点
            if (p == head && tryAcquire(arg)) { // 只有老二能抢锁
                setHead(node);    // 抢到，设为新 head
                p.next = null;    // 原 head 出队
                failed = false;
                return interrupted;
            }
            // 没抢到或不是老二 → 判断是否需要 park
            if (shouldParkAfterFailedAcquire(p, node) &&
                parkAndCheckInterrupt())
                interrupted = true;
        }
    } finally {
        if (failed)
            cancelAcquire(node);
    }
}
```

**核心逻辑：**
1. 只有 **head 的下一个节点**（老二）才有资格获取锁
2. 抢到锁 → 设为新 head，原 head 出队
3. 没抢到 → 检查是否能 park

### shouldParkAfterFailedAcquire——找到该睡觉的信号

```java
private static boolean shouldParkAfterFailedAcquire(Node pred, Node node) {
    int ws = pred.waitStatus;
    if (ws == Node.SIGNAL)
        return true;  // 前驱告诉你：你安心睡吧，我醒了会叫你
    
    if (ws > 0) {     // CANCELLED（>0）
        // 跳过所有取消的节点
        do {
            node.prev = pred = pred.prev;
        } while (pred.waitStatus > 0);
        pred.next = node;
    } else {
        // waitStatus = 0 或 PROPAGATE
        // 设置前驱为 SIGNAL，下次循环就可以 park 了
        compareAndSetWaitStatus(pred, ws, Node.SIGNAL);
    }
    return false;
}
```

Node 的 waitStatus 含义：

| 状态值 | 名称 | 含义 |
|--------|------|------|
| 1 | CANCELLED | 线程已取消（超时或中断），不会再竞争 |
| -1 | SIGNAL | 后继节点需要被唤醒 |
| -2 | CONDITION | 线程在条件队列中等待 |
| -3 | PROPAGATE | 共享模式下传播唤醒 |

### parkAndCheckInterrupt——线程阻塞

```java
private final boolean parkAndCheckInterrupt() {
    LockSupport.park(this);  // 线程阻塞，进入 WAITING 状态
    return Thread.interrupted();  // 返回中断标志
}
```

这里调用了 `LockSupport.park()`，底层是 `Unsafe.park()`，依赖操作系统 **POSIX pthread_cond_wait** 或 Windows 的等待机制。线程进入 **WAITING** 状态，不消耗 CPU。

## 面试官：那解锁过程是怎么样的？

```java
// ReentrantLock.unlock()
public void unlock() {
    sync.release(1);
}

// AQS.release()
public final boolean release(int arg) {
    if (tryRelease(arg)) {           // state 减到 0 了吗？
        Node h = head;
        if (h != null && h.waitStatus != 0)
            unparkSuccessor(h);      // 唤醒 head 的后继节点
        return true;
    }
    return false;
}

// Sync.tryRelease()
protected final boolean tryRelease(int releases) {
    int c = getState() - releases;
    if (Thread.currentThread() != getExclusiveOwnerThread())
        throw new IllegalMonitorStateException();
    boolean free = false;
    if (c == 0) {    // state 减到 0 → 真正释放
        free = true;
        setExclusiveOwnerThread(null);
    }
    setState(c);
    return free;
}

// 唤醒后继节点
private void unparkSuccessor(Node node) {
    int ws = node.waitStatus;
    if (ws < 0)
        compareAndSetWaitStatus(node, ws, 0);
    
    Node s = node.next;
    if (s == null || s.waitStatus > 0) {  // 后继被取消
        s = null;
        // 从尾部向前找第一个没有被取消的节点
        for (Node t = tail; t != null && t != node; t = t.prev)
            if (t.waitStatus <= 0)
                s = t;
    }
    if (s != null)
        LockSupport.unpark(s.thread);  // 唤醒线程
}
```

## 面试官：那公平锁和非公平锁的区别在哪里？

```java
// FairSync.tryAcquire()
protected final boolean tryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState();
    if (c == 0) {
        // ◆ 公平锁的额外判断：hasQueuedPredecessors()
        if (!hasQueuedPredecessors() &&
            compareAndSetState(0, acquires)) {
            setExclusiveOwnerThread(current);
            return true;
        }
    }
    // ... 可重入逻辑与非公平锁相同
}

// 判断队列中是否有等待时间更长的线程
public final boolean hasQueuedPredecessors() {
    Node t = tail;  // 尾节点
    Node h = head;  // 头节点
    Node s;
    return h != t &&
        ((s = h.next) == null || s.thread != Thread.currentThread());
}
```

**公平 vs 非公平：仅一行代码的差距**

非公平锁：`if (compareAndSetState(0, 1))` — 不管队列，直接抢
公平锁：`if (!hasQueuedPredecessors() && compareAndSetState(0, 1))` — 先看前面有没有人排队

公平锁避免了"线程饥饿"，但代价是 **吞吐量更低**。实际场景中非公平锁更常用，因为"插队"减少了线程的 park/unpark 开销。

## 面试官：那 Condition 的实现原理呢？

```java
// 使用示例
ReentrantLock lock = new ReentrantLock();
Condition condition = lock.newCondition();

// 线程1：等待
lock.lock();
try {
    while (条件不满足) {
        condition.await();  // 释放锁 + 加入等待队列
    }
    // 条件满足，继续执行
} finally {
    lock.unlock();
}

// 线程2：唤醒
lock.lock();
try {
    // 修改条件
    condition.signal();  // 唤醒等待队列中的一个线程
} finally {
    lock.unlock();
}
```

### await 原理

```java
// AbstractQueuedSynchronizer.ConditionObject
public final void await() throws InterruptedException {
    // 1. 创建等待节点，加入条件队列
    Node node = addConditionWaiter();
    // 2. 完全释放锁（保存并清空 state）
    int savedState = fullyRelease(node);
    int interruptMode = 0;
    // 3. 检查是否在同步队列中
    while (!isOnSyncQueue(node)) {
        LockSupport.park(this);  // 4. 阻塞等待
        if ((interruptMode = checkInterruptWhileWaiting(node)) != 0)
            break;
    }
    // 5. 重新竞争锁
    if (acquireQueued(node, savedState) && interruptMode != THROW_IE)
        interruptMode = REINTERRUPT;
    // 6. 清理取消的节点
    if (node.nextWaiter != null)
        unlinkCancelledWaiters();
    if (interruptMode != 0)
        reportInterruptAfterWait(interruptMode);
}
```

### signal 原理

```java
public final void signal() {
    if (!isHeldExclusively())
        throw new IllegalMonitorStateException();
    Node first = firstWaiter;
    if (first != null)
        doSignal(first);  // 将条件队列头节点转移到同步队列
}

private void doSignal(Node first) {
    do {
        if ((firstWaiter = first.nextWaiter) == null)
            lastWaiter = null;
        first.nextWaiter = null;  // 断开条件队列链接
    } while (!transferForSignal(first) &&   // 转移到同步队列
             (first = firstWaiter) != null);
}

final boolean transferForSignal(Node node) {
    // 将节点 waitStatus 从 CONDITION 改为 0
    if (!compareAndSetWaitStatus(node, Node.CONDITION, 0))
        return false;
    // 将节点加入同步队列尾部，返回前驱
    Node p = enq(node);
    int ws = p.waitStatus;
    // 如果前驱已取消或 CAS 设置 SIGNAL 失败，直接唤醒
    if (ws > 0 || !compareAndSetWaitStatus(p, ws, Node.SIGNAL))
        LockSupport.unpark(node.thread);
    return true;
}
```

**Condition 核心流程：**

```
   ┌─────────┐    signal()    ┌─────────────────┐
   │ 条件队列 │ ──────────────►│  同步等待队列    │
   │ CONDITION│               │  (CLH Queue)     │
   │  Node A  │               │   head → ... → A │
   │  Node B  │               │                   │
   │  Node C  │               │                   │
   └─────────┘               └─────────────────┘
        │                            │
        │ await()                    │ acquireQueued
        ▼                            ▼
   释放锁，park                  重新竞争锁
```

## 面试官：ReentrantReadWriteLock 和 ReentrantLock 的关系？

`ReentrantReadWriteLock` 也是基于 AQS 实现的，但它的 state 是一个 **32 位的 int，被分割为两部分使用**：

```
高位 16 位 ← 读锁计数
低位 16 位 ← 写锁计数
```

```java
static final int SHARED_SHIFT   = 16;
static final int SHARED_UNIT    = (1 << SHARED_SHIFT);  // 0x00010000
static final int EXCLUSIVE_MASK = (1 << SHARED_SHIFT) - 1;  // 0x0000FFFF

// 读锁数量 = state >>> 16
static int sharedCount(int c)    { return c >>> SHARED_SHIFT; }
// 写锁数量 = state & 0x0000FFFF
static int exclusiveCount(int c) { return c & EXCLUSIVE_MASK; }
```

| 特性 | ReentrantLock | ReentrantReadWriteLock |
|------|--------------|----------------------|
| 模式 | 独占 | 读共享 + 写独占 |
| state | 单个计数器 | 高16位(读) + 低16位(写) |
| 适用场景 | 写多读少 | 读多写少 |
| 性能 | 一般 | 读场景极高 |
| 锁降级 | N/A | 写锁可以降级为读锁 |
| 公平性 | 支持 | 支持 |

```java
// 经典应用：缓存读写
public class Cache {
    private final Map<String, Object> data = new HashMap<>();
    private final ReentrantReadWriteLock rwl = new ReentrantReadWriteLock();
    
    public Object get(String key) {
        rwl.readLock().lock();
        try {
            return data.get(key);
        } finally {
            rwl.readLock().unlock();
        }
    }
    
    public void put(String key, Object value) {
        rwl.writeLock().lock();
        try {
            data.put(key, value);
        } finally {
            rwl.writeLock().unlock();
        }
    }
}
```

## 总结

回到最开始的面试题：**ReentrantLock 与 AQS 的实现原理**，可以总结为：

1. **状态管理**：AQS 用 volatile int state 表示锁状态，0=未锁定，>0=被占用
2. **CLH 队列**：获取锁失败的线程通过 addWaiter 封装成 Node 入队
3. **自旋 + park**：acquireQueued 中前驱是 head 才尝试 CAS，否则 park 阻塞
4. **LockSupport**：底层 Unsafe.park/unpark，不消耗 CPU
5. **可重入**：state 累加，每次释放减 1，到 0 才真正释放
6. **公平性**：公平锁多一次 hasQueuedPredecessors 检查排队
7. **AQS 模板方法**：tryAcquire/tryRelease 由子类实现，排队逻辑由 AQS 统一管理

理解了 AQS，就等于掌握了 JUC 并发包的"心脏"。
