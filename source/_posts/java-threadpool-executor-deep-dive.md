---
title: 【源码分析】Java 线程池 ThreadPoolExecutor 核心原理与最佳实践
date: 2026-06-26 08:00:00
tags:
  - Java
  - 并发
  - 线程池
  - 源码分析
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【源码分析】Java 线程池 ThreadPoolExecutor 核心原理与最佳实践

## 面试官：线程池的核心参数有哪些？拒绝策略怎么选？

线程池是 Java 并发编程的基石，不管是日常开发还是高并发系统，都离不开它。今天我们从源码层面把它彻底讲透。

## 一、核心参数与执行流程

### 1.1 七个核心参数

```java
public ThreadPoolExecutor(int corePoolSize,        // 核心线程数
                          int maximumPoolSize,     // 最大线程数
                          long keepAliveTime,      // 非核心线程空闲存活时间
                          TimeUnit unit,           // 时间单位
                          BlockingQueue<Runnable> workQueue, // 工作队列
                          ThreadFactory threadFactory,       // 线程工厂
                          RejectedExecutionHandler handler)  // 拒绝策略
```

### 1.2 执行流程（重要！）

```java
public void execute(Runnable command) {
    if (command == null)
        throw new NullPointerException();
    
    int c = ctl.get();
    // 流程1：workerCount < corePoolSize → 创建核心线程
    if (workerCountOf(c) < corePoolSize) {
        if (addWorker(command, true))
            return;
        c = ctl.get();
    }
    // 流程2：加入工作队列
    if (isRunning(c) && workQueue.offer(command)) {
        int recheck = ctl.get();
        if (!isRunning(recheck) && remove(command))
            reject(command);
        else if (workerCountOf(recheck) == 0)
            addWorker(null, false);
    }
    // 流程3：尝试创建非核心线程
    else if (!addWorker(command, false))
        reject(command);  // 流程4：拒绝
}
```

**流程图解：**

```
提交任务
    │
    ├─ 核心线程未满 → 创建核心线程执行
    │
    ├─ 核心线程已满 → 加入工作队列
    │        │
    │        ├─ 队列没满 → 等待被消费
    │        │
    │        └─ 队列已满 → 创建非核心线程
    │               │
    │               ├─ 未达最大线程 → 创建非核心线程执行
    │               │
    │               └─ 已达最大线程 → 执行拒绝策略
    │
    └─ 非核心线程空闲 → keepAliveTime 后回收
```

| 线程池参数 | 场景建议 |
|-----------|---------|
| **corePoolSize** | CPU密集型 = CPU核数+1；IO密集型 = CPU核数 × 2 |
| **maximumPoolSize** | 根据系统承载能力计算，避免过多线程导致上下文切换 |
| **workQueue** | 有界队列（如ArrayBlockingQueue）比无界队列更安全 |

## 二、ctl 状态控制字段（精髓）

ThreadPoolExecutor 用一个 AtomicInteger 同时表示**线程池状态**和**线程数量**，这是面试亮点。

```java
private final AtomicInteger ctl = new AtomicInteger(ctlOf(RUNNING, 0));

// 用高3位表示线程池状态，低29位表示工作线程数
private static final int COUNT_BITS = Integer.SIZE - 3; // 29
private static final int CAPACITY   = (1 << COUNT_BITS) - 1; // 536870911

// 线程池状态（数值大小顺序：RUNNING < SHUTDOWN < STOP < TIDYING < TERMINATED）
private static final int RUNNING    = -1 << COUNT_BITS;
private static final int SHUTDOWN   =  0 << COUNT_BITS;
private static final int STOP       =  1 << COUNT_BITS;
private static final int TIDYING    =  2 << COUNT_BITS;
private static final int TERMINATED =  3 << COUNT_BITS;

// 提取状态
private static int runStateOf(int c)     { return c & ~CAPACITY; }
// 提取线程数
private static int workerCountOf(int c)  { return c & CAPACITY; }
// 组合
private static int ctlOf(int rs, int wc) { return rs | wc; }
```

**为什么这么设计？** 用一个原子变量同时管理状态和数量，加锁/解锁时 CAS 一次搞定，无需两个锁变量。

**状态流转：**

```
RUNNING → SHUTDOWN（调 shutdown()）
RUNNING → STOP（调 shutdownNow()）
SHUTDOWN → TIDYING（队列为空且workerCount=0）
STOP → TIDYING（workerCount=0）
TIDYING → TERMINATED（terminated()钩子执行完）
```

## 三、Worker 运行机制

### 3.1 Worker 是什么？

Worker 是 ThreadPoolExecutor 的内部类，一个 Worker 封装了一个线程和一个任务：

```java
private final class Worker extends AbstractQueuedSynchronizer implements Runnable {
    final Thread thread;        // 执行线程
    Runnable firstTask;         // 初始任务（可以是 null）
    volatile long completedTasks; // 已完成任务数
    
    Worker(Runnable firstTask) {
        setState(-1); // AQS 状态，-1 表示禁止中断
        this.firstTask = firstTask;
        this.thread = getThreadFactory().newThread(this); // 用线程工厂创建线程
    }
    
    public void run() {
        runWorker(this);
    }
}
```

**Worker 继承 AQS 而非使用 ReentrantLock 的原因：**
- 实现**不可重入锁**：runWorker 中加锁执行任务，如果任务内部调用了 shutdown 等操作，不会让自己中断自己
- ReentrantLock 是可重入的，Worker 需要的是不可重入语义

### 3.2 runWorker 核心循环

```java
final void runWorker(Worker w) {
    Thread wt = Thread.currentThread();
    Runnable task = w.firstTask;
    w.firstTask = null;
    w.unlock(); // 允许中断（state从-1变为0）
    
    boolean completedAbruptly = true;
    try {
        // 核心循环：不断获取任务并执行
        while (task != null || (task = getTask()) != null) {
            w.lock(); // 执行前加锁，防止shutdown时中断正在运行的任务
            
            // 检查线程池状态：若为STOP，确保线程被中断
            if ((runStateAtLeast(ctl.get(), STOP) ||
                 (Thread.interrupted() && runStateAtLeast(ctl.get(), STOP))) &&
                !wt.isInterrupted())
                wt.interrupt();
            
            try {
                beforeExecute(wt, task); // 钩子方法
                Throwable thrown = null;
                try {
                    task.run(); // 真正的任务执行
                } catch (RuntimeException x) {
                    thrown = x; throw x;
                } catch (Error x) {
                    thrown = x; throw x;
                } catch (Throwable x) {
                    thrown = x; throw new Error(x);
                } finally {
                    afterExecute(task, thrown); // 钩子方法
                }
            } finally {
                task = null;
                w.completedTasks++;
                w.unlock();
            }
        }
        completedAbruptly = false;
    } finally {
        processWorkerExit(w, completedAbruptly); // Worker退出处理
    }
}
```

## 四、getTask() —— 线程如何从队列获取任务

```java
private Runnable getTask() {
    boolean timedOut = false;
    
    for (;;) {
        int c = ctl.get();
        int rs = runStateOf(c);
        
        // 检查：是否应该停止
        if (rs >= SHUTDOWN && (rs >= STOP || workQueue.isEmpty())) {
            decrementWorkerCount();
            return null;
        }
        
        int wc = workerCountOf(c);
        
        // 判断是否启用超时机制
        boolean timed = allowCoreThreadTimeOut || wc > corePoolSize;
        
        if ((wc > maximumPoolSize || (timed && timedOut))
            && (wc > 1 || workQueue.isEmpty())) {
            if (compareAndDecrementWorkerCount(c))
                return null;  // 返回 null → Worker 退出循环 → 线程结束
            continue;
        }
        
        try {
            Runnable r = timed ?
                workQueue.poll(keepAliveTime, TimeUnit.NANOSECONDS) :  // 超时等待
                workQueue.take();                                     // 阻塞等待
            if (r != null)
                return r;
            timedOut = true;  // poll超时，下次循环尝试减少Worker
        } catch (InterruptedException retry) {
            timedOut = false;
        }
    }
}
```

**关键设计：**
- **核心线程 vs 非核心线程**：实际上并没有"核心/非核心 Worker"之分，所有 Worker 一视同仁
- **超时回收**：`wc > corePoolSize` 的 Worker 会超时等待，超时后自我销毁
- `allowCoreThreadTimeOut`：设为 true 后核心线程也会超时回收

## 五、四大拒绝策略对比

| 策略 | 实现类 | 行为 |
|------|-------|------|
| **AbortPolicy**（默认） | 抛出 RejectedExecutionException | 调用方感知失败 |
| **CallerRunsPolicy** | 调用者线程自己执行 | 降低提交速度，自然限流 |
| **DiscardPolicy** | 静默丢弃 | 不通知不抛出 |
| **DiscardOldestPolicy** | 丢弃队列头部的任务 | 尝试提交新任务 |

```java
// CallerRunsPolicy 的实现
public static class CallerRunsPolicy implements RejectedExecutionHandler {
    public void rejectedExecution(Runnable r, ThreadPoolExecutor e) {
        if (!e.isShutdown()) {
            r.run(); // 谁提交谁执行
        }
    }
}
```

**选型建议：**
- 关键业务 → **CallerRunsPolicy**（慢下来保正确）
- 非关键业务，可丢数据 → **DiscardPolicy**
- 想感知异常 → **AbortPolicy**
- 优先级任务 → **DiscardOldestPolicy**（丢弃旧任务保新任务）

## 六、Executors 四大快捷工厂（为什么阿里不建议用？）

| 工厂方法 | 线程池 | 工作队列 | 问题 |
|---------|--------|---------|------|
| newFixedThreadPool | 固定线程数 | LinkedBlockingQueue（无界） | 任务堆积可能导致 OOM |
| newCachedThreadPool | 0核心，Integer.MAX 最大 | SynchronousQueue | 线程数无限，CPU/内存耗尽 |
| newSingleThreadExecutor | 单线程 | LinkedBlockingQueue（无界） | 同 Fixed，无界队列 |
| newScheduledThreadPool | coreSize可配 | DelayedWorkQueue | 定时场景专用 |

**阿里巴巴 Java 开发手册明确禁止**使用 Executors 创建线程池，要求通过 ThreadPoolExecutor 手动配置：

```java
// ✅ 推荐方式
ThreadPoolExecutor executor = new ThreadPoolExecutor(
    8,                    // core
    16,                   // max
    60L, TimeUnit.SECONDS,// 空闲回收
    new ArrayBlockingQueue<>(1000), // 有界队列
    new ThreadFactoryBuilder()      // Guava 自定义线程名
        .setNameFormat("biz-pool-%d")
        .build(),
    new ThreadPoolExecutor.CallerRunsPolicy()
);
```

## 七、线程池大小如何估算？

### 7.1 理论公式

```
CPU密集型：Ncpu + 1
IO密集型：2 * Ncpu

更精确的公式：
线程数 = Ncpu * (1 + 等待时间 / 计算时间)
```

### 7.2 压测才是王道

```java
// 通过动态调整验证
public class ThreadPoolTuning {
    public static void main(String[] args) {
        // 记录各线程数下的 TPS
        for (int threads : new int[]{4, 8, 16, 32, 64}) {
            ThreadPoolExecutor pool = new ThreadPoolExecutor(
                threads, threads, 0L, TimeUnit.SECONDS,
                new LinkedBlockingQueue<>()
            );
            
            long start = System.currentTimeMillis();
            CountDownLatch latch = new CountDownLatch(10000);
            for (int i = 0; i < 10000; i++) {
                pool.execute(() -> {
                    // 模拟业务：50ms计算+50msIO
                    doSomething();
                    latch.countDown();
                });
            }
            latch.await();
            long cost = System.currentTimeMillis() - start;
            System.out.printf("threads=%d, TPS=%.0f%n", 
                threads, 10000.0 / cost * 1000);
            pool.shutdown();
        }
    }
}
```

## 八、常见生产问题排查

### 8.1 如何监控线程池？

```java
// 继承 ThreadPoolExecutor 记录指标
public class MonitoredThreadPool extends ThreadPoolExecutor {
    private final AtomicLong taskCount = new AtomicLong();
    private final AtomicLong totalTime = new AtomicLong();
    
    public MonitoredThreadPool(...) { super(...); }
    
    @Override
    protected void afterExecute(Runnable r, Throwable t) {
        super.afterExecute(r, t);
        // 上报指标到监控系统
        Metrics.gauge("pool.queue.size", getQueue().size());
        Metrics.gauge("pool.active.count", getActiveCount());
        Metrics.gauge("pool.pool.size", getPoolSize());
    }
}
```

### 8.2 线程池满了怎么办？

```java
// 兜底方案：降级 + 告警
public <T> T submitWithDegrade(Callable<T> task, T fallback) {
    try {
        Future<T> future = executor.submit(task);
        return future.get(100, TimeUnit.MILLISECONDS);
    } catch (RejectedExecutionException e) {
        log.warn("线程池已满，执行降级");
        Metrics.counter("pool.rejected").inc();
        return fallback; // 降级返回默认值
    } catch (TimeoutException e) {
        log.warn("任务超时，执行降级");
        return fallback;
    }
}
```

## 面试追问清单

1. **ctl 高3位为什么设计成 RUNNING < SHUTDOWN < STOP < TIDYING < TERMINATED？**
   → 方便用 `>=` 比较判断是否已关闭
2. **Worker 为什么要实现 AQS？**
   → 不可重入锁语义，防止任务中断自己
3. **核心线程会被回收吗？**
   → 默认不会，但 allowCoreThreadTimeOut(true) 可以
4. **shutdown() 和 shutdownNow() 的区别？**
   → shutdown() 等待队列任务完成；shutdownNow() 返回未执行任务列表
5. **线程池中的线程抛出异常会怎样？**
   → Worker 退出，processWorkerExit 中会补充新线程
6. **如何动态调整线程池参数？**
   → setCorePoolSize/setMaximumPoolSize 可以运行时调整

通过这篇文章，你不仅能回答面试官的问题，还能在生产环境中真正用好线程池。
