---
title: 【并发编程】ScheduledThreadPoolExecutor 源码深度解析：DelayedWorkQueue 与定时任务原理
date: 2026-08-06 08:00:00
tags:
  - Java
  - 并发
  - 定时任务
  - 源码
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】ScheduledThreadPoolExecutor 源码深度解析：DelayedWorkQueue 与定时任务原理

## 面试官：说说 JDK 里的定时任务调度是怎么实现的？

一提到定时任务，很多人的第一反应是 `Timer` 或者 Spring 的 `@Scheduled`。但面试官真正想听到的，是 `ScheduledThreadPoolExecutor`（以下简称 STPE）——JDK 定时调度的正统实现。

被追问下去就是灵魂三连：

- Timer 有什么缺陷？为什么现在都用 STPE？
- `scheduleAtFixedRate` 和 `scheduleWithFixedDelay` 到底差在哪？
- STPE 底层用什么数据结构存任务？延迟任务是怎么"到点触发"的？
- 为什么 STPE 的 `execute()` 永远只创建一个线程？核心线程数会被"清零"吗？

本文结合 JDK 8 源码，把 STPE 和它的秘密武器 `DelayedWorkQueue` 彻底拆开。

<!-- more -->

## 一、Timer 的四大缺陷（面试必答）

| 缺陷 | 说明 |
|------|------|
| 单线程串行 | 一个任务执行时间过长，会阻塞后续所有任务 |
| 异常中断 | 任务抛出未捕获异常，Timer 线程直接挂掉，整个调度终止 |
| 基于绝对时间 | 受系统时钟调整影响（如改系统时间），可能跳过或重复执行 |
| 无并发能力 | 无法利用多核，吞吐有限 |

STPE 完美解决这些问题：**多线程并发执行 + 任务异常不影响调度线程 + 基于相对延迟时间 + 可配置线程池**。所以 JDK 5 之后官方建议用 STPE 替代 Timer，Spring 的 `@Scheduled` 默认也走 STPE（`ThreadPoolTaskScheduler` 内部封装）。

## 二、类体系与核心字段

```java
public class ScheduledThreadPoolExecutor extends ThreadPoolExecutor
        implements ScheduledExecutorService {

    // 核心线程数设为 0 时，默认不保活核心线程
    private volatile boolean continueExistingPeriodicTasksAfterShutdown;
    private volatile boolean executeExistingDelayedTasksAfterShutdown = true;
    private volatile boolean removeOnCancel; // 取消时是否从队列移除

    public ScheduledThreadPoolExecutor(int corePoolSize) {
        super(corePoolSize, Integer.MAX_VALUE,
              DEFAULT_KEEPALIVE_MILLIS, MILLISECONDS,
              new DelayedWorkQueue());
    }
}
```

注意构造函数：**workQueue 固定是 `DelayedWorkQueue`**，而 maximumPoolSize 是 Integer.MAX_VALUE——因为 DelayedWorkQueue 是无界队列，线程数永远不会超过 corePoolSize（无界队列不触发创建非核心线程），所以 maximumPoolSize 设多少都无所谓。

## 三、DelayedWorkQueue：基于二叉堆的延迟队列

这是 STPE 最精妙的部分。它**不是**用时间轮，也不是用优先队列 + 轮询，而是一棵**小顶堆**：

```java
static class DelayedWorkQueue extends AbstractQueue<Runnable>
        implements BlockingQueue<Runnable> {

    private static final int INITIAL_CAPACITY = 16;
    private RunnableScheduledFuture<?>[] queue =   // 小顶堆数组
        new RunnableScheduledFuture<?>[INITIAL_CAPACITY];
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition available = lock.newCondition();
    private Thread leader;  // leader-follower 模式
    ...
}
```

### 3.1 堆的排序规则

堆顶永远是 **delay 最小（最该先执行）** 的任务，比较逻辑：

```java
// ScheduledFutureTask 的 compareTo
public int compareTo(Delayed other) {
    if (other == this) return 0;
    long diff = getDelay(NANOSECONDS) - other.getDelay(NANOSECONDS);
    return (diff < 0) ? -1 : (diff > 0) ? 1 : 0; // 相同延迟按序号
}
```

入队 `offer` 走**上浮（siftUp）**，出队 `take` 走**下沉（siftDown）**，插入和删除都是 **O(log n)**，比 Timer 的线性扫描高效得多。

### 3.2 take()：leader-follower 模式的精准唤醒

延迟队列最麻烦的是：任务还没到时间，消费者不能把它取走。STPE 用了经典的 **leader-follower 模式**：

```java
public RunnableScheduledFuture<?> take() throws InterruptedException {
    final ReentrantLock lock = this.lock;
    lock.lockInterruptibly();
    try {
        for (;;) {
            RunnableScheduledFuture<?> first = queue[0];
            if (first == null)
                available.await();                 // 队列空，全体等待
            else {
                long delay = first.getDelay(NANOSECONDS);
                if (delay <= 0)
                    return finishPoll(first);      // 到点了，取出
                first = null;
                if (leader != null)
                    available.await();             // 已有 leader，普通线程直接睡
                else {
                    Thread thisThread = Thread.currentThread();
                    leader = thisThread;           // 自己当 leader
                    try {
                        // 只有 leader 精确 sleep 到任务触发时刻
                        available.awaitNanos(delay);
                    } finally {
                        if (leader == thisThread)
                            leader = null;         // 醒来后让位
                    }
                }
            }
        }
    } finally {
        if (leader == null && queue[0] != null)
            available.signal();                    // 唤醒下一个
        lock.unlock();
    }
}
```

**为什么要 leader？** 如果所有线程都 `awaitNanos(delay)`，任务到点时所有线程同时醒来，只有一个人能抢到任务，其余人白醒（惊群效应）。leader-follower 保证**同一时刻只有一个线程精确等待，其余线程彻底休眠**，唤醒开销最小。

### 3.3 定时任务的"自我循环"：周期的秘密

周期任务能一直重复执行，靠的是 `ScheduledFutureTask.run()` 里的逻辑：

```java
public void run() {
    boolean periodic = isPeriodic();
    if (!canRunInCurrentRunState(periodic))
        cancel(false);
    else if (!periodic)
        ScheduledFutureTask.super.run();           // 一次性任务
    else if (ScheduledFutureTask.super.runAndReset()) { // 周期任务执行后重置状态
        setNextRunTime();                          // 计算下一次执行时间
        reExecutePeriodic(outerTask);              // 重新放入队列
    }
}
```

- `runAndReset()`：执行任务但**不设置结果**（周期任务结果无意义），执行完把状态重置回 NEW，供下次使用。
- `setNextRunTime()`：按 fixedRate 或 fixedDelay 计算下次触发时间。
- `reExecutePeriodic()`：把任务重新丢回 DelayedWorkQueue。

**关键点**：下次执行时间是在**本次执行完成之后**才计算的，所以如果任务执行时间超过周期，下次触发会顺延（fixedRate 也可能因此被"挤压"，但不会并发执行同一个任务——因为任务本身还在队列里等待，而不是同时有两个实例）。

## 四、fixedRate vs fixedDelay：一字之差，天壤之别

```java
// 固定频率：period > 0，下次 = 上次开始时间 + period
// 不管任务跑多久，都按固定节奏触发（可能积压）
public ScheduledFuture<?> scheduleAtFixedRate(Runnable command,
        long initialDelay, long period, TimeUnit unit) {
    ...
    return schedule(command, new ScheduledFutureTask<Void>(
        command, null, triggerTime(initialDelay, unit),
        unit.toNanos(period)));  // period > 0
}

// 固定延迟：period < 0，下次 = 上次完成时间 + delay
// 任务执行多久都无所谓，保证两次执行间隔至少为 delay
public ScheduledFuture<?> scheduleWithFixedDelay(Runnable command,
        long initialDelay, long delay, TimeUnit unit) {
    ...
    return schedule(command, new ScheduledFutureTask<Void>(
        command, null, triggerTime(initialDelay, unit),
        unit.toNanos(-delay)));  // period < 0（负数标记）
}
```

`setNextRunTime` 里的判断：

```java
private void setNextRunTime() {
    long p = period;
    if (p > 0)                 // fixedRate
        time += p;             // 基于上次的"计划时间"累加
    else                       // fixedDelay
        time = triggerTime(-p); // 基于"当前时间 + delay"
}
```

| 对比项 | scheduleAtFixedRate | scheduleWithFixedDelay |
|--------|--------------------|----------------------|
| period 符号 | 正数 | 负数 |
| 下次时间基准 | 上次计划开始时间 | 上次实际完成时间 |
| 任务超时影响 | 触发节奏不变，任务排队积压 | 触发间隔自动顺延 |
| 适用场景 | 心跳、指标采集 | 数据同步、轮询任务 |

## 五、核心线程数为 0 的经典坑

面试官常问：**STPE 核心线程数设 0，任务还能执行吗？**

能。看 `ThreadPoolExecutor.execute()` 的逻辑：corePoolSize=0 时，提交任务不会立即创建核心线程（`workerCountOf(c) < corePoolSize` 为 false），而是**先把任务放进队列**；`addWorker` 里有个逻辑——当 `workerCountOf(c) == 0` 时，`setCorePoolSize(0)` 场景下会补一个非核心线程来消费队列：

```java
// execute() 中的核心逻辑
if (workerCountOf(c) == 0)
    addWorker(null, false); // 队列非空但没有工作线程时，补一个
```

所以**即使 core=0，任务也能被执行**，只是线程会有空闲回收（keepAliveTime 后销毁），适合"偶尔才有定时任务"的场景省资源。但要注意：如果 `allowCoreThreadTimeOut` 未开启且 core>0，线程会常驻。

## 六、与时间轮、@Scheduled 的对比

| 方案 | 数据结构 | 精度 | 适用场景 |
|------|---------|------|---------|
| Timer | 小顶堆 + 单线程 | 毫秒级 | 已被淘汰 |
| ScheduledThreadPoolExecutor | 二叉堆 + 线程池 | 纳秒级 | JDK 通用定时调度 |
| 时间轮（Netty/Kafka） | 环形数组 | 有刻度误差 | 海量定时任务、延时消息 |
| Quartz / XXL-Job | 数据库 + 调度器 | 秒级 | 分布式定时任务 |
| Spring @Scheduled | 内部封装 STPE | 毫秒级 | 单机业务定时 |

**STPE 的不足**：所有任务共用一个队列，单个任务执行时间过长会阻塞同线程队列里的其他任务（线程不够时）；且任务不支持分布式。这也是为什么秒杀场景的延时消息用时间轮，分布式场景用 XXL-Job。

## 七、面试官连环追问

**Q1：schedule() 和 scheduleAtFixedRate() 的返回结果有什么区别？**
schedule 返回的 Future 能拿到任务返回值；周期任务的 Future 永远拿不到结果（get() 会一直阻塞或抛异常），它的价值在于 `cancel()` 取消后续执行。

**Q2：周期任务执行抛出异常会怎样？**
异常会被吞掉，任务从队列移除，后续不再执行，但**不会影响其他任务和调度线程**。这是比 Timer 强的地方（Timer 会直接挂掉整个调度）。

**Q3：如何让一个周期任务取消后马上从队列移除？**
`setRemoveOnCancelPolicy(true)`，配合 `cancel(true)`，任务会从 DelayedWorkQueue 中删除，而不是等它自然过期。

**Q4：DelayedWorkQueue 是阻塞队列吗？扩容机制？**
是。内部数组初始 16，满时按 1.5 倍扩容（`grow()` 里 `newCapacity = n + (n >> 1)`），所有操作通过 ReentrantLock 保证线程安全。

**Q5：什么时候用 fixedRate，什么时候用 fixedDelay？**
需要"固定节奏"（如每 10 秒上报心跳，任务本身很快）用 fixedRate；任务执行时间不确定、要求"前一次必须完成后隔固定时间再跑"（如全量数据同步）用 fixedDelay。

**Q6：STPE 的线程数为什么不会超过 corePoolSize？**
因为 DelayedWorkQueue 是无界队列，`execute()` 时队列永远不满，永远不会触发 `maximumPoolSize` 分支，所以不会创建非核心线程。

## 八、实战配置建议

```java
@Bean
public ScheduledExecutorService scheduledExecutorService() {
    ScheduledThreadPoolExecutor executor =
        new ScheduledThreadPoolExecutor(4, r -> {
            Thread t = new Thread(r, "schedule-worker");
            t.setDaemon(true);   // 守护线程，避免阻止 JVM 退出
            return t;
        });
    executor.setRemoveOnCancelPolicy(true);
    executor.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
    return executor;
}
```

要点：
1. 线程数按**任务类型**分：IO 型任务可以多配几个线程，CPU 型别超过核数。
2. 任务内部一定要 catch 异常，别让异常静默杀死周期任务。
3. 长任务用 fixedDelay，别用 fixedRate，避免任务积压导致线程池被拖垮。

STPE 是"队列 + 线程池 + 时间调度"三个经典问题的交汇点，吃透它，等于同时拿下了二叉堆、leader-follower 模式、线程池协作三块硬骨头。
