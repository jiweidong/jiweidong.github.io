---
title: 【并发底层】LockSupport 深度解析：park/unpark 许可机制、伪唤醒与 AQS 基石
date: 2026-10-24 08:05:00
tags:
  - Java
  - 并发编程
  - JUC
  - AQS
  - LockSupport
categories:
  - Java 深挖
author: 东哥
---

# 【并发底层】LockSupport 深度解析：park/unpark 许可机制、伪唤醒与 AQS 基石

## 前言

写并发代码时，我们最常用的阻塞/唤醒套路是 `Object.wait()` / `notify()`。但它有三个绕不过去的硬伤：

1. **必须在 `synchronized` 块内调用**，否则直接 `IllegalMonitorStateException`；
2. **必须成对有序**：先 `wait` 后 `notify`，如果 `notify` 抢在 `wait` 之前执行，信号就丢了，等待线程永远挂住；
3. **只能唤醒「某个随机等待者」或「全部」**，没法精确唤醒指定线程。

`java.util.concurrent.locks.LockSupport` 就是 JDK 给并发库作者准备的底层原语：**不需要锁、不要求顺序、可以精确唤醒某个线程**。它是 `AQS`（`AbstractQueuedSynchronizer`）的基石，`ReentrantLock`、`CountDownLatch`、`Semaphore`、`FutureTask`、`SynchronousQueue`、`ThreadPoolExecutor` 的 worker 阻塞，底层全是 `LockSupport.park()`。

很多人对它的理解停留在「park 是阻塞，unpark 是唤醒」，但真正的坑都在**许可（permit）语义**、**伪唤醒**、**中断**和**残留许可**上。这篇文章把它讲透，最后手写一个基于 `LockSupport` 的简易锁和生产者消费者。

---

## 一、LockSupport 到底是什么

`LockSupport` 是一个门面类，核心只有两个 native 方法（通过 `Unsafe` 暴露）：

```java
public static void park();
public static void unpark(Thread thread);
```

另外还有带 blocker、带超时的变体：

```java
public static void park(Object blocker);
public static void parkNanos(long nanos);
public static void parkNanos(Object blocker, long nanos);
public static void parkUntil(long deadline);
public static void parkUntil(Object blocker, long deadline);
```

它们最终都调用到 JVM 的 `Parker` 对象：

```java
// 简化后的 HotSpot 逻辑
class Parker : public os::PlatformParker {
  volatile int _counter;   // 就是那个"许可"
  // park: counter > 0 ? counter = 0 : 阻塞
  // unpark: counter = 1（不是我 park 就通知）
};
```

**每个 Java 线程都持有一个 `Parker` 实例**，所以 park/unpark 是「线程私有」的，天然不需要全局锁。

---

## 二、许可（permit）语义：一个容量为 1 的信号量

这是理解 `LockSupport` 的唯一关键：

> **`LockSupport` 内部维护一个二元信号量，许可最多只有 1 个。`unpark` 是「发放许可」，`park` 是「消耗许可」。**

规则只有四条：

| 操作 | 当前许可 | 结果 |
|---|---|---|
| `park()` | 1 | **立即返回**，许可清零 |
| `park()` | 0 | 阻塞，直到被 unpark / 中断 / 伪唤醒 |
| `unpark(t)` | 0 | 许可置 1，若 t 在 park 中则唤醒 |
| `unpark(t)` | 1 | 保持不变（**不会累加**） |

由此推出两个非常重要的结论：

### 结论 1：park 和 unpark 没有顺序要求

```java
Thread t = new Thread(() -> {
    LockSupport.park();          // 此时许可已经是 1
    System.out.println("继续执行");
});
t.start();

// 先 unpark，后 park —— 完全合法
LockSupport.unpark(t);
Thread.sleep(1000);
```

即使 `unpark` 在 `park` 之前执行，`park` 也会立刻返回。这正好补上了 `wait/notify` 的「信号丢失」问题。

### 结论 2：许可不累加，连续 unpark 只算一次

```java
LockSupport.unpark(t);
LockSupport.unpark(t);
LockSupport.unpark(t);
LockSupport.park();  // 返回
LockSupport.park();  // 阻塞！因为许可最多 1 个
```

**这个特性是线上面试题的重灾区**：如果代码逻辑依赖「unpark 了 N 次就能 park 通过 N 次」，必然死锁。

### 结论 3：park 不释放任何锁

这是新手最容易误解的一点：

```java
synchronized (lock) {
    LockSupport.park();  // 线程挂起，但 lock 依然被它持有！
}
```

`Object.wait()` 会释放 monitor，**`park()` 不会释放任何锁**。所以千万不能在持锁状态下随意 park，否则其他线程永远进不来，直接死锁。要「释放锁再等待」，必须用 `Condition.await()`（它在内部先释放锁再 park）。

---

## 三、和 wait/notify 的完整对比

| 维度 | `Object.wait/notify` | `LockSupport.park/unpark` |
|---|---|---|
| 是否需要在同步块内 | **必须**（否则抛异常） | 不需要 |
| 是否释放监视器锁 | 是 | **否** |
| 顺序要求 | 必须先 wait 后 notify | 无要求（许可可预存） |
| 唤醒粒度 | 随机一个 / 全部 | **指定线程** |
| 中断响应 | 抛 `InterruptedException` | **不抛异常**，返回后需自行检查中断标志 |
| 伪唤醒 | 存在 | 存在（JVM 允许自发返回） |
| 超时支持 | `wait(long)` | `parkNanos` / `parkUntil` |
| 定位能力 | 无 | `blocker` 参数可出现在线程栈 |
| 使用门槛 | 语言级 | 底层原语，不建议业务直接用 |

一句话总结：**业务代码用 `Condition` / `BlockingQueue`；框架代码用 `LockSupport`。**

---

## 四、伪唤醒（spurious wakeup）：为什么必须写 while 循环

JVM 规范明确允许 `park()` 在没有任何 `unpark`、没有中断的情况下「莫名其妙」返回。这不是 bug，而是为了兼容不同操作系统的底层实现（POSIX 的 `pthread_cond_wait` 同样允许）。

所以**任何 park 都必须放在条件循环里**：

```java
// ❌ 错误：伪唤醒后条件还没满足就往下走了
LockSupport.park();
doSomething();

// ✅ 正确：醒来后重新检查条件
while (!conditionMet()) {
    LockSupport.park(this);
}
doSomething();
```

`AQS` 的源码就是这么写的：

```java
final boolean acquireQueued(final Node node, int arg) {
    boolean failed = true;
    try {
        boolean interrupted = false;
        for (;;) {
            final Node p = node.predecessor();
            if (p == head && tryAcquire(arg)) {   // 醒来先试一次
                setHead(node);
                p.next = null;
                failed = false;
                return interrupted;
            }
            if (shouldParkAfterFailedAcquire(p, node) &&
                parkAndCheckInterrupt())          // 里面就是 LockSupport.park(this)
                interrupted = true;
        }
    } finally {
        if (failed) cancelAcquire(node);
    }
}
```

注意 `for (;;)` 这个自旋：**每次被唤醒都要重新竞争一次，抢不到就继续 park**。这就是「循环 + 条件」的标准范式。

---

## 五、中断语义：不抛异常，但会「吃掉」标志位

`park()` 被中断时**不会抛 `InterruptedException`**，它会直接返回，并且**清除线程的中断标志**。这意味着如果你不检查，中断信号就静默丢失了。

```java
Thread t = new Thread(() -> {
    while (true) {
        LockSupport.park();
        // 关键：必须自己判断中断
        if (Thread.interrupted()) {      // 注意：interrupted() 会清除标志
            System.out.println("收到中断，退出");
            break;
        }
    }
});
```

`AQS` 的做法是把中断「记下来」，等拿到锁之后再补上：

```java
private final boolean parkAndCheckInterrupt() {
    LockSupport.park(this);
    return Thread.interrupted();   // 清除并返回，交给上层记录
}

// acquireQueued 返回后
if (interrupted) Thread.currentThread().interrupt();  // 恢复中断标志
```

**这是并发框架的标准套路：内部用标志位记录，返回给调用方之前再恢复，不吞掉中断。**

对比一下三种阻塞方式的中断行为：

| 方法 | 中断表现 | 中断标志 |
|---|---|---|
| `Thread.sleep` | 抛 `InterruptedException` | 清除 |
| `Object.wait` | 抛 `InterruptedException` | 清除 |
| `LockSupport.park` | **正常返回** | **清除** |
| `LockSupport.park` + 显式检查 | 正常返回 | 需手动恢复 |

---

## 六、blocker 参数：别小看这个诊断利器

`park(Object blocker)` 的唯一作用是**让 jstack / Arthas 的线程栈变得可读**。

不传 blocker：

```
"pool-1-thread-3" #23 waiting on condition [0x00007f...]
   java.lang.Thread.State: WAITING (parking)
        at sun.misc.Unsafe.park(Native Method)
        at java.util.concurrent.locks.LockSupport.park(LockSupport.java:175)
        at com.example.Worker.run(Worker.java:42)
```

传 blocker：

```
"pool-1-thread-3" #23 waiting on condition [0x00007f...]
   java.lang.Thread.State: WAITING (parking)
        at sun.misc.Unsafe.park(Native Method)
        at java.util.concurrent.locks.LockSupport.park(LockSupport.java:194)
        - parking to wait for  <0x000000076b5c8a10> (a java.util.concurrent.locks.ReentrantLock$NonfairSync)
        at com.example.Worker.run(Worker.java:42)
```

多出来的 `parking to wait for <地址> (a 具体类型)` 直接告诉你「它在等谁」。线上排查线程全部 park 住的问题时，这一行能省半小时。

**实践建议**：自己写同步组件时，`park(this)` 里的 `this` 就是那个同步器对象；`AQS` 内部统一用 `park(this)`，`this` 是 `Sync` 对象。

---

## 七、LockSupport 在 AQS 中的真实角色

`ReentrantLock` 加锁失败的路径，压缩后是这样的：

```java
// AbstractQueuedSynchronizer.acquire
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
        selfInterrupt();
}

// 入队后
private static boolean shouldParkAfterFailedAcquire(Node pred, Node node) {
    int ws = pred.waitStatus;
    if (ws == Node.SIGNAL) return true;          // 前驱会唤醒我，可以安心 park
    if (ws > 0) {                                // 前驱已取消，往前找
        do {
            node.prev = pred = pred.prev;
        } while (pred.waitStatus > 0);
        pred.next = node;
    } else {
        compareAndSetWaitStatus(pred, ws, Node.SIGNAL);  // 告诉前驱：记得叫我
    }
    return false;
}
```

解锁时：

```java
public final boolean release(int arg) {
    if (tryRelease(arg)) {
        Node h = head;
        if (h != null && h.waitStatus != 0)
            unparkSuccessor(h);   // 里面调用 LockSupport.unpark(s.thread)
        return true;
    }
    return false;
}
```

**设计精髓**：`SIGNAL` 状态是「契约」——前驱节点承诺释放时会唤醒后继。所以 park 之前必须先 CAS 把前驱置为 `SIGNAL`，否则可能出现「我刚决定 park，你正好释放并检查到我不需要唤醒」的丢失唤醒问题。

这也是为什么 `shouldParkAfterFailedAcquire` 第一次返回 `false`（只设置状态），**第二次循环才返回 `true` 真正 park**。这个「多自旋一次」的设计经常被面试官拿出来问。

---

## 八、手写一个基于 LockSupport 的简易锁

理解了许可语义，自己实现一个互斥锁就是十几行：

```java
public class SimpleMutex {
    private final AtomicReference<Thread> owner = new AtomicReference<>();
    private final Queue<Thread> waiters = new ConcurrentLinkedQueue<>();

    public void lock() {
        Thread current = Thread.currentThread();
        // 快速路径：CAS 抢锁
        if (owner.compareAndSet(null, current)) return;

        // 慢路径：入队 + 循环 park
        waiters.add(current);
        while (true) {
            if (owner.compareAndSet(null, current)) {
                waiters.remove(current);
                return;
            }
            LockSupport.park(this);   // 允许伪唤醒，所以外层是 while
        }
    }

    public void unlock() {
        if (!owner.compareAndSet(Thread.currentThread(), null)) {
            throw new IllegalMonitorStateException("未持有锁");
        }
        // 唤醒一个等待者
        Thread next = waiters.peek();
        if (next != null) LockSupport.unpark(next);
    }
}
```

再看生产者消费者：

```java
public class LockSupportQueue<T> {
    private final Queue<T> queue = new ArrayDeque<>();
    private final int capacity;
    private final Set<Thread> producers = ConcurrentHashMap.newKeySet();
    private final Set<Thread> consumers = ConcurrentHashMap.newKeySet();

    public LockSupportQueue(int capacity) { this.capacity = capacity; }

    public void put(T item) throws InterruptedException {
        Thread self = Thread.currentThread();
        synchronized (this) {
            while (queue.size() == capacity) {
                producers.add(self);
                // 注意：必须在 synchronized 之外 park，否则消费者进不来
            }
        }
        // 正确写法见下方说明
    }
}
```

上面的骨架暴露了一个真实的设计难点：**用 `LockSupport` 做条件队列，必须自己管理「谁在等哪个条件」，而且不能持锁 park**。这也是 `AQS` 要引入 `ConditionObject`（每个条件一条等待队列）的原因。

一个更接近生产可用的写法是用「状态 + CAS + park」：

```java
public class BoundedBuffer<E> {
    private final Object[] items;
    private int count, putIdx, takeIdx;
    private final Set<Thread> notFullWaiters  = ConcurrentHashMap.newKeySet();
    private final Set<Thread> notEmptyWaiters = ConcurrentHashMap.newKeySet();

    public BoundedBuffer(int capacity) { items = new Object[capacity]; }

    public void put(E e) throws InterruptedException {
        while (true) {
            if (Thread.interrupted()) throw new InterruptedException();
            synchronized (this) {
                if (count < items.length) {
                    items[putIdx] = e;
                    putIdx = (putIdx + 1) % items.length;
                    count++;
                    wakeOne(notEmptyWaiters);
                    return;
                }
                notFullWaiters.add(Thread.currentThread());
            }
            LockSupport.park(this);          // 锁已释放，可以安全 park
            notFullWaiters.remove(Thread.currentThread());
        }
    }

    @SuppressWarnings("unchecked")
    public E take() throws InterruptedException {
        while (true) {
            if (Thread.interrupted()) throw new InterruptedException();
            synchronized (this) {
                if (count > 0) {
                    E e = (E) items[takeIdx];
                    items[takeIdx] = null;
                    takeIdx = (takeIdx + 1) % items.length;
                    count--;
                    wakeOne(notFullWaiters);
                    return e;
                }
                notEmptyWaiters.add(Thread.currentThread());
            }
            LockSupport.park(this);
            notEmptyWaiters.remove(Thread.currentThread());
        }
    }

    private void wakeOne(Set<Thread> waiters) {
        for (Thread t : waiters) {
            if (waiters.remove(t)) { LockSupport.unpark(t); return; }
        }
    }
}
```

注意这里的三个细节，都是面试常考点：

1. **`park` 放在 `synchronized` 块外面**——否则消费者拿不到锁，永远唤不醒它；
2. **入队后、park 前有窗口期**：可能在释放锁到 park 之间被 `unpark`，此时许可已存下，`park` 立即返回，不会丢信号——这正是 `LockSupport` 相比 `wait/notify` 的优势；
3. **醒来自动 `remove`**，避免集合无限增长。

---

## 九、生产踩坑清单

### 坑 1：线程池里残留许可导致「假唤醒」

```java
// 提交任务前先 unpark 一下（比如为了"预热"）
LockSupport.unpark(workerThread);
```

如果这个 `unpark` 发生在线程归还到池子之后、下一次 `park` 之前，许可就被「存」在这个线程上了。等它下次执行任务 park 时，直接穿透。表象是「偶发空转 / 条件没满足就执行」，极难排查。

**规则：unpark 只能用于「我明确知道你正在等，或即将等这个条件」的场景。**

### 坑 2：把 park 当 sleep 用

```java
LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(1));  // 以为等于 sleep(1)
```

差别在于：任何 `unpark` 都会让它提前返回。如果这个线程被别人误 unpark，你的「定时」就废了。定时请用 `Thread.sleep` 或 `ScheduledExecutorService`。

### 坑 3：忘记循环判断，伪唤醒导致数据错乱

前面讲过，不再重复。**看到 `park()` 不在 `while` 里，就可以判定是 bug。**

### 坑 4：park 在 `synchronized` 内导致死锁

`park` 不释放 monitor。要「等条件」必须用 `Condition.await()` 或自己保证 park 时无锁。

### 坑 5：中断被吞

```java
LockSupport.park();
// 没有检查 Thread.interrupted()
continue;   // 线程无法响应 shutdown
```

线上表现为 **`kill -15` 之后应用关不掉、优雅停机卡住**。因为你的循环永远不退出。

### 坑 6：以为 unpark 能唤醒「正在 sleep 的线程」

`unpark` 只影响 `Parker` 的许可，对 `Thread.sleep`、`wait`、IO 阻塞**无效**。想打断它们只能用 `interrupt()`。

---

## 十、面试常见追问

**Q1：`LockSupport.park()` 和 `Thread.sleep()` 的区别？**

- park 可以被 `unpark` 唤醒，sleep 不能；
- park 响应中断但不抛异常，sleep 抛 `InterruptedException`；
- park 不释放锁，sleep 也不释放锁（两者相同）；
- park 是「等待某个条件」，sleep 是「等一段时间」，语义不同；
- park 底层是 `Parker` + 条件变量，sleep 走的是 `os::sleep`。

**Q2：为什么 AQS 用 `LockSupport` 而不是 `wait/notify`？**

- `wait/notify` 要求持有 monitor，而 AQS 本身要替代 `synchronized`，不能反向依赖；
- `notify` 只能随机唤醒，AQS 需要唤醒**队首后继**这个特定节点；
- `wait/notify` 有信号丢失窗口，AQS 的入队/park 之间必须无窗口；
- `park(blocker)` 能在线程栈上打印等待对象，便于诊断。

**Q3：`unpark` 一个还没启动的线程会怎样？**

许可会存在该线程的 `Parker` 上，等它第一次 `park` 时立即返回。**不会报错，但通常说明你的时序设计有问题。**

**Q4：`park` 会不会释放 CPU？**

会。线程进入 `WAITING (parking)`，不占 CPU。但它不会让出锁。

**Q5：`parkNanos` 的超时精度如何？**

依赖 OS 的条件变量超时（Linux 上是 `pthread_cond_timedwait`），毫秒级，且受调度影响。不要用它做精确定时。

**Q6：`LockSupport` 能替代 `Condition` 吗？**

能但不该。`Condition` 帮你管理了「条件队列 + 锁释放 + 精确唤醒 + 中断语义 + 超时」，`LockSupport` 这些全要自己写，且极易出错。业务代码没有任何理由直接用 `LockSupport`。

---

## 十一、总结

把 `LockSupport` 浓缩成一张图：

```
unpark(t)  ──→ 许可 = 1（最多 1） ──→ park() 立即返回并清零
                    │
                    └─ 线程在 park 中？唤醒它
park()   ──→ 许可 = 0？阻塞，直到 unpark / 中断 / 伪唤醒
```

记住四句话：

1. **许可是二元的，不累加**；
2. **park 必须写在 while 条件循环里**；
3. **park 不释放锁，持锁 park 必死锁**；
4. **中断不抛异常，必须自己检查并恢复标志**。

再往上一层看：`LockSupport` 是「线程级阻塞原语」，`AQS` 是「基于它的队列化同步框架」，`ReentrantLock` / `Semaphore` / `CountDownLatch` 是「面向业务的门面」。理解了这个分层，JUC 的源码就不再是玄学，而是一层层可以推导出来的设计。
