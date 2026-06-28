---
title: 「彻底搞懂 ThreadPoolExecutor」核心源码、拒绝策略与实战调优
date: 2026-06-28 08:00:00
tags:
  - Java
  - 并发
  - 线程池
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 「彻底搞懂 ThreadPoolExecutor」核心源码、拒绝策略与实战调优

线程池是 Java 并发编程中最常用的组件之一。无论是 Web 服务器的请求处理、异步任务的执行，还是消息队列的消费端，背后都离不开线程池。但你真的了解它吗？本文从源码到实战，帮你彻底搞懂 ThreadPoolExecutor。

---

## 一、为什么需要线程池？

在没有线程池之前，我们创建一个线程来处理一个任务：

```java
new Thread(() -> {
    // do something
}).start();
```

这种方式的三个致命问题：

| 问题 | 说明 |
|------|------|
| 频繁创建/销毁 | 线程创建和销毁需要系统调用，开销大 |
| 资源无上限 | 大量并发时线程数爆炸，OOM 或系统崩溃 |
| 管理缺失 | 无法控制最大并发数，无法复用，无法监控 |

线程池解决了这些问题：**复用线程、控制并发、统一管理**。

---

## 二、ThreadPoolExecutor 核心构造参数

```java
public ThreadPoolExecutor(int corePoolSize,
                          int maximumPoolSize,
                          long keepAliveTime,
                          TimeUnit unit,
                          BlockingQueue<Runnable> workQueue,
                          ThreadFactory threadFactory,
                          RejectedExecutionHandler handler)
```

| 参数 | 含义 | 说明 |
|------|------|------|
| corePoolSize | 核心线程数 | 即使空闲也保留的线程数（允许超时除外）|
| maximumPoolSize | 最大线程数 | 线程池中允许的最大线程数 |
| keepAliveTime | 空闲存活时间 | 线程数超过 corePoolSize 时，多余线程空闲存活时间 |
| unit | 时间单位 | keepAliveTime 的时间单位 |
| workQueue | 工作队列 | 等待执行的任务队列 |
| threadFactory | 线程工厂 | 创建新线程的工厂 |
| handler | 拒绝策略 | 队列满且线程数已达最大时的处理策略 |

### 处理流程（非常重要，面试高频）

```
           提交任务
              │
              ▼
       corePoolSize 满？ ──否──→ 创建核心线程执行
              │是
              ▼
       workQueue 满？  ──否──→ 入队等待
              │是
              ▼
      maximumPoolSize 满？ ──否──→ 创建非核心线程执行
              │是
              ▼
         执行拒绝策略
```

**注意流程细节**：
- 先判断 corePoolSize，再判断 workQueue，最后判断 maxPoolSize
- 核心线程不满时新建线程，**不入队**
- 核心线程满时**先入队**，队列满了才创建非核心线程
- 假设 core=2, max=4, queue=5，提交第 1、2 个任务 → 创建 2 个核心线程；第 3～7 个 → 入队；第 8 个 → 创建非核心线程（到 max=4）；第 9、10 个 → 创建非核心线程...第 11 个 → 触发拒绝策略

---

## 三、核心源码解析

### 3.1 线程池的运行状态

ThreadPoolExecutor 用一个 `ctl` 原子整数同时保存**运行状态**和**线程数量**：

```java
private final AtomicInteger ctl = new AtomicInteger(ctlOf(RUNNING, 0));
private static final int COUNT_BITS = Integer.SIZE - 3;  // 29
private static final int CAPACITY   = (1 << COUNT_BITS) - 1; // 536870911

// 运行状态（高3位）
private static final int RUNNING    = -1 << COUNT_BITS;  // 111
private static final int SHUTDOWN   =  0 << COUNT_BITS;  // 000
private static final int STOP       =  1 << COUNT_BITS;  // 001
private static final int TIDYING    =  2 << COUNT_BITS;  // 010
private static final int TERMINATED =  3 << COUNT_BITS;  // 011
```

**高 3 位 → 状态，低 29 位 → 线程数**，一个 int 搞定两个字段，省一个 int 是小事，关键是保证状态和数量的**原子一致性**。

| 状态 | 说明 |
|------|------|
| RUNNING | 正常运行，接受新任务并处理队列中的任务 |
| SHUTDOWN | 不接受新任务，但处理队列中的任务 |
| STOP | 不接受新任务，不处理队列中的任务，中断正在执行的任务 |
| TIDYING | 所有任务已终止，即将调用 terminated() |
| TERMINATED | terminated() 已执行完成 |

**状态转换**：
```
RUNNING → SHUTDOWN（调用 shutdown()）
RUNNING → STOP（调用 shutdownNow()）
SHUTDOWN → STOP（调用 shutdownNow()）
SHUTDOWN/STOP → TIDYING（队列空 + 工作线程空）
TIDYING → TERMINATED（执行 terminated()）
```

### 3.2 execute() 核心逻辑

```java
public void execute(Runnable command) {
    if (command == null) throw new NullPointerException();
    
    int c = ctl.get();
    // 第一步：workerCount < corePoolSize → 创建核心线程
    if (workerCountOf(c) < corePoolSize) {
        if (addWorker(command, true))
            return;
        c = ctl.get();  // 重新获取，防止并发
    }
    
    // 第二步：线程池运行中且成功入队
    if (isRunning(c) && workQueue.offer(command)) {
        int recheck = ctl.get();
        // 双重检查：如果线程池已关闭，回滚入队任务
        if (!isRunning(recheck) && remove(command))
            reject(command);
        // 核心线程数为0时，确保至少有一个线程在运行
        else if (workerCountOf(recheck) == 0)
            addWorker(null, false);
    }
    // 第三步：核心满且入队失败 → 创建非核心线程
    else if (!addWorker(command, false))
        reject(command);  // 达到 maxPoolSize → 拒绝策略
}
```

**关键设计点**：
- **双重检查（Double Check）**：入队后再次检查线程池状态，防止线程池已关闭但任务已入队
- **核心线程数为 0 时的兜底**：如果 `allowCoreThreadTimeOut(true)` + `corePoolSize=0`，入队成功后需要确保至少一个工作线程可以消费队列

### 3.3 addWorker() — 真正的线程创建

```java
private boolean addWorker(Runnable firstTask, boolean core) {
    retry:
    for (;;) {
        int c = ctl.get();
        int rs = runStateOf(c);

        // 状态检查：只有在 RUNNING 状态或 SHUTDOWN+空任务时才可创建
        if (rs >= SHUTDOWN && 
            !(rs == SHUTDOWN && firstTask == null && !workQueue.isEmpty()))
            return false;

        for (;;) {
            int wc = workerCountOf(c);
            // 容量检查（区分核心/非核心上限）
            if (wc >= CAPACITY || wc >= (core ? corePoolSize : maximumPoolSize))
                return false;
            if (compareAndIncrementWorkerCount(c))  // CAS 增加 workerCount
                break retry;
            c = ctl.get();
            if (runStateOf(c) != rs)
                continue retry;
        }
    }

    boolean workerStarted = false;
    boolean workerAdded = false;
    Worker w = new Worker(firstTask);
    Thread t = w.thread;
    
    if (t != null) {
        mainLock.lock();
        try {
            if (runStateOf(ctl.get()) < STOP) {
                if (t.isAlive())
                    throw new IllegalThreadStateException();
                workers.add(w);  // 添加到工作线程集合
                workerAdded = true;
            }
        } finally {
            mainLock.unlock();
        }
        if (workerAdded) {
            t.start();  // 启动线程 → 执行 Worker.run()
            workerStarted = true;
        }
    }
    return workerStarted;
}
```

### 3.4 Worker 的 run() — runWorker()

```java
final void runWorker(Worker w) {
    Thread wt = Thread.currentThread();
    Runnable task = w.firstTask;
    w.firstTask = null;
    w.unlock(); // 允许中断

    try {
        while (task != null || (task = getTask()) != null) {
            w.lock();  // Worker 继承 AQS，用于锁住工作线程
            // 线程池 STOP 后要中断线程
            if ((runStateAtLeast(ctl.get(), STOP) ||
                 (Thread.interrupted() && runStateAtLeast(ctl.get(), STOP))) &&
                !wt.isInterrupted())
                wt.interrupt();
            try {
                beforeExecute(wt, task);  // 前置钩子
                task.run();               // 真正的任务执行
                afterExecute(task, null); // 后置钩子
            } finally {
                task = null;
                w.completedTasks++;
                w.unlock();
            }
        }
    } catch (Throwable ex) {
        afterExecute(task, ex);
        throw ex;
    } finally {
        processWorkerExit(w, completedAbruptly);
    }
}
```

关键点：
- Worker 继承 AQS，**实现不可重入的独占锁**，用于在任务执行时控制中断
- `getTask()` 从阻塞队列中取任务，如果取不到且超过 keepAliveTime，线程退出

---

## 四、四种拒绝策略

当队列满且线程数已达 maximumPoolSize 时，触发拒绝策略：

| 策略 | 类名 | 行为 |
|------|------|------|
| 抛异常 | AbortPolicy（默认） | 抛出 `RejectedExecutionException` |
| 调用者运行 | CallerRunsPolicy | 由提交任务的线程执行该任务 |
| 丢弃当前 | DiscardPolicy | 直接丢弃任务，不抛异常 |
| 丢弃最旧 | DiscardOldestPolicy | 丢弃队列头部的任务，重试提交当前任务 |

### CallerRunsPolicy 的特殊价值

```java
// 自定义线程池，核心线程2，最大4，队列100
ThreadPoolExecutor executor = new ThreadPoolExecutor(
    2, 4, 60, TimeUnit.SECONDS,
    new LinkedBlockingQueue<>(100),
    new ThreadPoolExecutor.CallerRunsPolicy());
```

当所有线程和队列都满时，任务由主线程（提交者）执行。此时主线程被占用，**自然地限制了任务提交速度**——起到了背压（back pressure）的效果。

### 自定义拒绝策略

```java
new ThreadPoolExecutor(
    // ... 其他参数
    new RejectedExecutionHandler() {
        @Override
        public void rejectedExecution(Runnable r, ThreadPoolExecutor executor) {
            // 记录日志 + 告警
            log.warn("Task rejected: {}", r.toString());
            // 或发送到死信队列
            deadLetterQueue.offer(r);
            // 或降级处理
            fallbackHandler.handle(r);
        }
    }
);
```

---

## 五、线程池实战调优

### 5.1 线程数怎么配？

业界经典公式：

**CPU 密集型**（计算为主）：
```
最佳线程数 = CPU核数 + 1（或 + 1~2）
```
+1 是为了补偿页缺失等导致的阻塞。

**IO 密集型**（网络/磁盘IO为主）：
```
最佳线程数 = CPU核数 × (1 + IO等待时间 / CPU计算时间)
```
如果 IO 等待时间和 CPU 计算时间难以精确测量，可以用经验值：CPU核数 × 2 到 CPU核数 × 3。

**混合型**：将 CPU 密集部分和 IO 密集部分分离到不同的线程池。

### 5.2 队列怎么选？

| 队列 | 特性 | 适用场景 |
|------|------|---------|
| SynchronousQueue | 不存任务，交给线程 | 大并发短任务，配合 maxPoolSize 大 |
| LinkedBlockingQueue | 链表无界（或指定容量） | 任务较均匀，希望稳定线程数 |
| ArrayBlockingQueue | 数组有界，公平可配 | 严格限制队列长度，防 OOM |
| PriorityBlockingQueue | 优先级排序 | 任务有优先级要求 |
| DelayedWorkQueue | 延迟执行 | 定时任务（ScheduledThreadPoolExecutor 用） |

### 5.3 生产环境配置示例

```java
public class ThreadPoolConfig {
    
    // IO密集型：Web服务请求处理
    public static ThreadPoolExecutor ioBoundPool() {
        int cpus = Runtime.getRuntime().availableProcessors();
        return new ThreadPoolExecutor(
            cpus * 2,         // core
            cpus * 4,         // max
            60L, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(1000),   // 有界队列，防OOM
            new ThreadFactoryBuilder()
                .setNameFormat("io-pool-%d")
                .build(),
            new ThreadPoolExecutor.CallerRunsPolicy()
        );
    }
    
    // CPU密集型：计算任务
    public static ThreadPoolExecutor cpuBoundPool() {
        int cpus = Runtime.getRuntime().availableProcessors();
        return new ThreadPoolExecutor(
            cpus + 1,
            cpus + 1,
            0L, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(100),
            new ThreadFactoryBuilder()
                .setNameFormat("cpu-pool-%d")
                .build(),
            new ThreadPoolExecutor.AbortPolicy()
        );
    }
}
```

### 5.4 线程池监控

```java
executor.setRejectedExecutionHandler((r, e) -> {
    // 监控：记录拒绝次数
    rejectedCount.incrementAndGet();
    log.error("Task rejected: poolSize={}, activeCount={}, queueSize={}, completed={}",
              e.getPoolSize(), e.getActiveCount(), e.getQueue().size(), e.getCompletedTaskCount());
    throw new RejectedExecutionException();
});

// 定时监控
ScheduledExecutorService monitor = Executors.newScheduledThreadPool(1);
monitor.scheduleAtFixedRate(() -> {
    log.info("Pool: core={}, active={}, poolSize={}, queue={}, completed={}",
             executor.getCorePoolSize(),
             executor.getActiveCount(),
             executor.getPoolSize(),
             executor.getQueue().size(),
             executor.getCompletedTaskCount());
}, 0, 10, TimeUnit.SECONDS);
```

---

## 六、Executors 的陷阱

`Executors` 工厂方法虽然方便，但在生产环境**不推荐直接使用**：

| 方法 | 问题 | 风险 |
|------|------|------|
| newFixedThreadPool | LinkedBlockingQueue 无界 | 队列堆积 OOM |
| newCachedThreadPool | maxPoolSize=Integer.MAX_VALUE | 线程无限创建 OOM |
| newSingleThreadExecutor | LinkedBlockingQueue 无界 | 队列堆积 OOM |
| newScheduledThreadPool | DelayedWorkQueue 无界 | 堆积 OOM |

**结论**：任何时候都使用 `new ThreadPoolExecutor(...)` 并指定有界队列。

---

## 七、面试高频追问

### Q1：核心线程数设置为 0 会怎样？

当 corePoolSize=0 时，提交第一个任务，由于 workerCount(0) < corePoolSize(0) 不成立，任务会入队；然后 addWorker(null, false) 创建一个非核心线程去取队列中的任务执行。

### Q2：线程池如何优雅关闭？

```java
executor.shutdown();         // 不再接收新任务，执行完队列已有任务
try {
    if (!executor.awaitTermination(60, TimeUnit.SECONDS)) {
        executor.shutdownNow();     // 超时则强制关闭
        if (!executor.awaitTermination(60, TimeUnit.SECONDS)) {
            // 仍没关闭，记录告警
        }
    }
} catch (InterruptedException e) {
    executor.shutdownNow();
    Thread.currentThread().interrupt();
}
```

### Q3：如何动态调整线程池参数？

ThreadPoolExecutor 提供了动态调整方法：
```java
executor.setCorePoolSize(10);       // 动态调整核心线程
executor.setMaximumPoolSize(20);    // 动态调整最大线程
executor.setKeepAliveTime(30, TimeUnit.SECONDS);  // 调整空闲时间
```

可以配合动态配置中心（如 Apollo/Nacos），实现线程池参数的热更新。

---

## 八、总结

ThreadPoolExecutor 是 Java 并发编程的基石，理解它的核心流程、源码设计和参数调优，是应对高并发场景的必备技能。

**一句话总结**：线程池的本质是用空间（队列）换时间（避免频繁创建线程），用资源约束（core/max/queue）防止系统过载。用好线程池，关键是理解你的业务是 CPU 密集型还是 IO 密集型，然后选择合理的核心参数、队列类型和拒绝策略。
