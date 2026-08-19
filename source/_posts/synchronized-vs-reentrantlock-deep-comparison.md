---
title: 【面试必备】synchronized vs ReentrantLock 深度对比：8 大区别与源码级解析
date: 2026-08-19 08:00:00
tags:
  - Java
  - 并发
  - 面试
  - 锁
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】synchronized vs ReentrantLock 深度对比：8 大区别与源码级解析

## 面试官：你平时用 synchronized 还是 ReentrantLock？它俩有什么区别？

这是 Java 并发面试的"必考题"，但大部分候选人的回答停留在"一个是关键字一个是类、一个自动释放一个手动释放"这种表面层。今天我们从**语法、功能、底层原理、性能**四个维度，把这两个锁彻底掰开揉碎。

---

## 一、先看结论：8 大区别一览表

| 维度 | synchronized | ReentrantLock |
|---|---|---|
| 1. 本质 | JVM 关键字（语言级） | JUC 类（API 级） |
| 2. 锁的获取/释放 | 自动（JVM 管理） | 手动（lock/unlock，必须 finally 释放） |
| 3. 可中断性 | 不可中断（等待时无法响应 interrupt） | 可中断（lockInterruptibly） |
| 4. 超时获取 | 不支持 | 支持 tryLock(timeout, unit) |
| 5. 公平性 | 非公平 | 默认非公平，可配公平 |
| 6. 多条件变量 | 只能 wait/notify，一个条件队列 | Condition，可多个条件队列精确唤醒 |
| 7. 底层实现 | Monitor（对象头 Mark Word + 锁升级） | AQS（CLH 变体队列 + CAS） |
| 8. 性能 | JDK 6 优化后与 ReentrantLock 基本持平 | 高竞争下略优，且功能更丰富 |

下面逐个深挖。

---

## 二、区别 1&2：语法与锁管理方式

### synchronized：隐式，JVM 托管

```java
public synchronized void method() { ... }          // 方法级

public void block() {
    synchronized (this) {                          // 代码块级
        ...
    }
}
```

无论正常结束还是抛异常，JVM 都会通过 monitorenter/monitorexit 字节码自动释放锁，**不可能忘释放**。

### ReentrantLock：显式，程序员负责

```java
Lock lock = new ReentrantLock();
lock.lock();                                       // 获取锁
try {
    // 临界区
} finally {
    lock.unlock();                                 // 必须手动释放！
}
```

**如果忘记 unlock，锁永远不会释放，直接导致死锁**。这是 ReentrantLock 最大的"使用成本"，也是它被诟病的点。

---

## 三、区别 3&4：可中断与超时获取

这是 synchronized 永远做不到的两个能力，也是**分布式锁、复杂并发场景必须用 Lock 的原因**。

### 3.1 可中断：lockInterruptibly()

```java
Lock lock = new ReentrantLock();
Thread t = new Thread(() -> {
    try {
        lock.lockInterruptibly();      // 等待期间可响应中断
        try {
            // 临界区
        } finally {
            lock.unlock();
        }
    } catch (InterruptedException e) {
        System.out.println("等待锁的过程中被中断，放弃获取");
    }
});
```

场景：一个线程长时间拿不到锁，外部想要"叫停"它。synchronized 等待时**连 interrupt 都响应不了**（中断标志会被挂起，直到拿到锁才处理），容易造成无法优雅退出。

### 3.2 超时获取：tryLock()

```java
if (lock.tryLock(3, TimeUnit.SECONDS)) {
    try {
        // 3 秒内拿到锁才执行
    } finally {
        lock.unlock();
    }
} else {
    // 超时未拿到，走降级逻辑（比如返回失败、走异步）
    System.out.println("获取锁超时，执行降级策略");
}
```

典型场景：**防止死锁**。两个线程互相持锁等对方，如果都用 tryLock 加超时，超时后自动放弃并重试，死锁就"活不过"超时时间。而 synchronized 一旦死锁只能靠 dump + kill。

---

## 四、区别 5：公平性

- **synchronized 只能是非公平锁**：新来的线程可能"插队"直接抢到锁，不管等待队列里有没有老线程在排队
- **ReentrantLock 默认也是非公平**，但可以通过构造器开启公平：

```java
Lock fairLock = new ReentrantLock(true);   // 公平锁
Lock unfairLock = new ReentrantLock(false); // 非公平锁（默认）
```

**为什么默认非公平？** 因为非公平锁的吞吐更高——被唤醒的线程要经历"阻塞→唤醒"的上下文切换，新来的线程在锁刚释放的瞬间直接 CAS 抢到，省掉一次切换。代价是**可能造成线程饥饿**（极端情况下老线程一直抢不到）。

**公平锁的实现**：AQS 的 `hasQueuedPredecessors()` 检查队列中是否有等待者，有则老老实实排队。

```java
// ReentrantLock.FairSync 中
protected final boolean tryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState();
    if (c == 0) {
        // 公平锁核心：先检查队列里有没有排队的
        if (!hasQueuedPredecessors() &&
            compareAndSetState(0, acquires)) {
            setExclusiveOwnerThread(current);
            return true;
        }
    }
    ...
}
```

---

## 五、区别 6：多条件变量 Condition

### synchronized 的 wait/notify 之痛

`synchronized` 里只有一个隐式的条件队列，`wait()/notify()/notifyAll()` 无法精确唤醒：

- `notify()` 随机唤醒**一个**等待线程，可能唤醒错对象
- `notifyAll()` 唤醒**所有**，大部分线程醒来后发现条件不满足又睡回去（惊群效应）

经典反例：**生产者-消费者**场景中，生产者 notify 可能唤醒的是另一个生产者，造成无效唤醒。

### ReentrantLock + Condition：精确分组唤醒

```java
ReentrantLock lock = new ReentrantLock();
Condition notFull = lock.newCondition();   // "不满"条件队列
Condition notEmpty = lock.newCondition();  // "不空"条件队列

// 生产者
lock.lock();
try {
    while (queue.isFull()) notFull.await();   // 满了，进"不满"队列等
    queue.put(item);
    notEmpty.signal();                        // 精确唤醒一个消费者
} finally {
    lock.unlock();
}

// 消费者
lock.lock();
try {
    while (queue.isEmpty()) notEmpty.await(); // 空了，进"不空"队列等
    Object item = queue.take();
    notFull.signal();                         // 精确唤醒一个生产者
} finally {
    lock.unlock();
}
```

一个锁可以 new 多个 Condition，每个 Condition 是一个独立的等待队列，`signal()` 精确唤醒对应类型的等待者——**ArrayBlockingQueue 内部就是这么实现的**（notEmpty、notFull 两个 Condition）。

---

## 六、区别 7：底层实现原理（源码级）

### 6.1 synchronized 的底层：Monitor + 锁升级

synchronized 依赖对象头的 **Mark Word** 和操作系统 Monitor：

1. **无锁**：对象头无锁标记
2. **偏向锁**：同一个线程反复进入，只需 CAS 一次记录线程 ID（JDK 15 起废弃，默认关闭）
3. **轻量级锁**：CAS 自旋抢锁，抢不到膨胀
4. **重量级锁**：进入 Monitor，未抢到锁的线程进入 OS 内核态的阻塞队列，涉及**用户态/内核态切换**，开销最大

锁升级路径：`无锁 → 偏向锁 → 轻量级锁 → 重量级锁`（单向不可逆）。

字节码层面，`monitorenter / monitorexit` 成对出现，JVM 保证异常路径也会执行 monitorexit 释放。

### 6.2 ReentrantLock 的底层：AQS + CLH 队列

ReentrantLock 基于 **AQS（AbstractQueuedSynchronizer）**：

- **state 变量**：`volatile int state`，0 表示无锁，>0 表示重入次数
- **CLH 变体队列**：抢锁失败的线程封装成 Node 挂到双向队列尾部，前驱节点释放时唤醒后继
- **CAS 操作**：`compareAndSetState(0, 1)` 抢锁

```java
// NonfairSync.tryAcquire → AQS.compareAndSetState
protected final boolean tryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState();
    if (c == 0) {
        if (compareAndSetState(0, acquires)) {   // CAS 抢锁
            setExclusiveOwnerThread(current);
            return true;
        }
    } else if (current == getExclusiveOwnerThread()) {
        int nextc = c + acquires;                // 重入 +1
        setState(nextc);
        return true;
    }
    return false;
}
```

两者殊途同归：**最终都是"CAS 抢锁 + 队列排队"**，synchronized 的重量级锁底层 Monitor 队列与 AQS 队列本质类似，所以性能差距在 JDK 6 之后几乎消失。

---

## 七、区别 8：性能真相

JDK 6 之前，synchronized 因重量级锁性能差被诟病；JDK 6 引入**锁升级、自旋、适应性自旋、锁消除、锁粗化**后，两者性能基本持平：

- **低竞争场景**：synchronized 略优（偏向锁/轻量级锁是纯用户态 CAS，无队列）
- **高竞争场景**：ReentrantLock 略优且稳定（AQS 队列管理更精细，支持中断/超时）

**性能不是选型的主要理由**，功能才是。

---

## 八、什么时候用哪个？实战选型指南

| 场景 | 推荐 |
|---|---|
| 普通方法/代码块互斥，代码简单 | synchronized（简洁、不易出错） |
| 需要等待可中断/可超时 | ReentrantLock |
| 需要公平锁 | ReentrantLock(true) |
| 生产者-消费者等多条件精确唤醒 | ReentrantLock + Condition |
| 读多写少场景 | 两个都不用，用 ReadWriteLock / StampedLock |
| 分布式环境跨进程互斥 | 用 Redis/数据库分布式锁（与本文无关） |
| 需要锁降级、源码可读性、调试友好 | ReentrantLock（可 tryLock 探测） |

**面试加分回答模板**："我默认用 synchronized，因为它由 JVM 托管、不会忘释放、可读性好；当业务需要可中断等待、超时获取、公平性或多条件变量时，我才切换到 ReentrantLock，并且一定在 finally 中释放。"

---

## 面试官常见追问

**Q：既然 synchronized 也能重入，两者重入机制有什么不同？**
A：synchronized 的重入靠 Monitor 中的计数器（同线程再次 monitorenter 计数 +1）；ReentrantLock 靠 AQS 的 state 累加。本质都是"记录持有线程 + 计数"。

**Q：公平锁为什么慢？**
A：公平锁每次抢锁前都要检查队列（`hasQueuedPredecessors`），并且锁释放后必须唤醒队首线程，多一次阻塞唤醒的上下文切换；非公平锁允许新线程 CAS 直接抢，省掉切换，吞吐更高，但可能饥饿。

**Q：synchronized 的锁升级为什么是单向的？**
A：因为锁只能从轻到重膨胀，不能"降级"。一旦发生竞争膨胀到重量级，Mark Word 布局已变，再降级需要复杂的撤销逻辑且收益低。JVM 设计上放弃降级换取简单与稳定（偏向锁撤销到无锁算例外，但偏向锁已废弃）。

**Q：Condition 的 await/signal 和 Object 的 wait/notify 有什么区别？**
A：① await 可超时/可中断，wait 只能被 notify 唤醒；② 一个 Lock 可创建多个 Condition，精确唤醒指定类型的等待线程，wait/notify 只有一个隐式队列；③ await 释放锁后进入 Condition 队列，signal 将其移到 AQS 同步队列等待重新竞争锁。

**Q：分布式场景下这两个锁还有用吗？**
A：它们只能解决**单 JVM 内**的线程互斥。多实例部署时需要分布式锁（Redis SETNX、ZooKeeper、数据库行锁）。面试里常考的是"本地锁 + 分布式锁"组合：先本地锁减少竞争，再分布式锁保证跨节点互斥。

---

## 总结

一句话记住核心：**synchronized 是 JVM 帮你看管的隐式锁，简单可靠；ReentrantLock 是握在你手里的显式锁，灵活强大**。面试时从"语法、中断、超时、公平、条件变量、底层、性能"七个维度展开，再结合选型理由，这道题基本就稳了。
