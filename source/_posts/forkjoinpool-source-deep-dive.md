---
title: 【并发编程】ForkJoinPool 深度解析：分治思想、工作窃取与源码级实现
date: 2026-08-08 08:00:00
tags:
  - Java
  - 并发编程
  - ForkJoinPool
  - 线程池
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】ForkJoinPool 深度解析：分治思想、工作窃取与源码级实现

## 面试官：除了 ThreadPoolExecutor，你还知道哪些线程池？

很多人在简历上写"熟悉 Java 并发编程"，但一问线程池只能答出 `ThreadPoolExecutor` 和 `ScheduledThreadPoolExecutor`。而 `ForkJoinPool` —— 这个 JDK 7 引入、支撑了 `Parallel Stream` 和 `CompletableFuture` 默认异步池的"分治线程池"，却常常被忽略。

本文从分治思想出发，深挖 ForkJoinPool 的核心机制：工作窃取（Work Stealing）、ForkJoinTask 状态机、ForkJoinWorkerThread 调度，最后用源码级别的视角回答面试官可能的全部追问。

<!-- more -->

## 一、分治思想：Fork/Join 框架要解决什么问题

### 1.1 传统线程池的痛点

`ThreadPoolExecutor` 基于 **生产者-消费者** 模型：任务被提交到共享的 `BlockingQueue`，工作线程从队列头部取任务执行。这种模型在处理"一个大任务可以拆成多个互不依赖的小任务"时存在两个问题：

1. **任务拆分后无法优雅地等待子任务完成**：主任务需要阻塞等待所有子任务，然后合并结果，`Future.get()` 的嵌套调用很容易写成一坨屎。
2. **负载不均衡**：某个线程的任务提前执行完，只能干等，而其他线程的队列里还排着长队。

### 1.2 Fork/Join 的核心思想

Fork/Join 框架由 Doug Lea 设计，核心就是 **分治（Divide and Conquer）+ 工作窃取（Work Stealing）**：

- **Fork**：把大任务递归拆分成小任务（直到阈值）；
- **Join**：等待子任务完成并合并结果；
- **工作窃取**：每个线程维护自己的双端队列，自己从队头取任务执行；当自己的队列空了，就**从其他线程队列的队尾"偷"任务**来执行。

```
                大任务
               /      \
         Fork 子任务1  子任务2  Fork
            /    \      /    \
        任务A  任务B  任务C  任务D   ← 递归拆分到阈值
           \    /      \    /
         Join 合并1  合并2  Join
               \      /
              最终结果
```

> 为什么从队尾偷？因为队头的任务往往是"更老、更大的任务"，而队尾是"最新拆分出来的小任务"。偷小任务可以进一步细分，减少竞争，同时保证大任务优先被处理。

### 1.3 典型应用场景

| 场景 | 说明 |
| --- | --- |
| `Arrays.parallelSort()` | 并行归并排序 |
| `Stream.parallel()` | 并行流底层使用 ForkJoinPool.commonPool() |
| `CompletableFuture` | 默认使用 ForkJoinPool.commonPool() 执行并行任务 |
| 大数据量聚合 | 求和、求最大值、统计等可拆分聚合运算 |

## 二、核心类体系

### 2.1 ForkJoinPool 类结构

```java
public class ForkJoinPool extends AbstractExecutorService {
    // 工作线程数组：每个线程一个槽位
    volatile WorkQueue[] workQueues;
    // 工作线程工厂
    final ForkJoinWorkerThreadFactory factory;
    // 默认并行度 = CPU 核数
    static final int DEFAULT_COMMON_PARALLELISM =
        Runtime.getRuntime().availableProcessors() - 1;
    // 全局公共池：静态方法 commonPool() 返回
    static final ForkJoinPool common;
}
```

### 2.2 ForkJoinTask 的三种形态

`ForkJoinTask` 是任务的抽象基类，它本身实现了 `Future` 接口，有三种典型子类：

| 子类 | 特点 | 使用场景 |
| --- | --- | --- |
| `RecursiveAction` | 无返回值 | 数组排序、遍历 |
| `RecursiveTask<V>` | 有返回值 | 求和、聚合计算 |
| `CountedCompleter` | 完成回调 | 复杂 DAG 任务、树形遍历 |

```java
// 经典例子：1~N 求和
public class SumTask extends RecursiveTask<Long> {
    private static final int THRESHOLD = 10000;
    private final long[] arr;
    private final int start, end;

    public SumTask(long[] arr, int start, int end) {
        this.arr = arr; this.start = start; this.end = end;
    }

    @Override
    protected Long compute() {
        if (end - start <= THRESHOLD) {
            long sum = 0;
            for (int i = start; i < end; i++) sum += arr[i];
            return sum;
        }
        int mid = (start + end) >>> 1;
        SumTask left = new SumTask(arr, start, mid);
        SumTask right = new SumTask(arr, mid, end);
        left.fork();               // 异步执行左半部分
        long rightResult = right.compute();  // 当前线程直接算右半部分
        long leftResult = left.join();       // 阻塞等待左半部分结果
        return leftResult + rightResult;
    }
}

// 使用
ForkJoinPool pool = new ForkJoinPool();
long result = pool.invoke(new SumTask(arr, 0, arr.length));
```

> **面试追问：为什么 `compute()` 里要一个 `fork()` 一个直接 `compute()`，而不是两个都 `fork()`？**
> 因为 fork 一个任务意味着把它压入队列等待其他线程窃取，涉及入队和状态变更；而当前线程反正要算一个子任务，直接同步 `compute()` 省一次入队开销，还能让子任务尽量在当前线程完成，减少窃取竞争。这就是 Doug Lea 著名的"偷一个算一个"优化。

## 三、工作窃取机制源码解析

### 3.1 WorkQueue 双端队列

每个工作线程对应一个 `WorkQueue`，内部是一个 `ForkJoinTask<?>[] array` 环形数组，用 `base`（队头）和 `top`（队尾）两个指针维护：

```java
static final class WorkQueue {
    volatile int base;      // 队头指针：被其他线程窃取
    int top;                // 队尾指针：自己 push/pop
    ForkJoinTask<?>[] array; // 任务数组
    volatile int hint;      // 偷取时记录上一次成功偷取的队列
    // ...
}
```

**关键点：锁分离设计**

- 线程**自己**操作：`push()` 入队、`pop()` 出队，都操作 `top` 指针，**无需加锁**（因为只有自己访问 top）；
- 其他线程**窃取**：`poll()` 操作 `base` 指针，通过 `CAS` 保证并发安全。

这种"单写多读 + CAS"的设计让最频繁的自有队列操作完全无锁，性能极高。

### 3.2 窃取过程 scan()

工作线程执行完自己的任务后，如果队列空了，就进入 `scan()` 方法尝试窃取：

```java
private ForkJoinTask<?> scan(WorkQueue w, int r) {
    WorkQueue[] ws = workQueues;
    for (int m = ws.length - 1; m >= 0; --m) {  // 随机起点遍历所有队列
        WorkQueue q = ws[r & m];
        if (q != null && q != w) {
            ForkJoinTask<?> t = q.poll();        // CAS 从队尾偷
            if (t != null) return t;
        }
        if (--n <= 0) break;
        r = nextRandomInt(r);                    // 伪随机步长，减少冲突
    }
    // 没偷到就阻塞当前线程
    return awaitWork(w, r);
}
```

**为什么要随机遍历？** 如果所有空闲线程都从 0 号队列开始扫，会产生"惊群效应"——大家同时抢同一个队列的任务，CAS 冲突剧烈。伪随机起始位置 + 伪随机步长让窃取请求均匀散开。

### 3.3 窃取不到怎么办：阻塞与补偿

`awaitWork()` 中，如果窃取失败且没有任务可做，线程会：
1. 尝试 `UNSIGNAL` 状态位更新 + `LockSupport.park()` 挂起；
2. 若池中线程数过多，会执行**补偿（Compensation）**逻辑：允许额外创建线程来处理被阻塞线程本该执行的任务，避免"一个任务阻塞等待另一个任务，而池里没有可用线程"的**死等**（Thread starvation deadlock）。

## 四、ForkJoinTask 状态机

`ForkJoinTask` 内部用 `int status` 表示任务状态：

| 状态常量 | 值 | 含义 |
| --- | --- | --- |
| `NORMAL` | `-1 << 16` | 正常完成 |
| `CANCELLED` | `-2 << 16` | 被取消 |
| `EXCEPTIONAL` | `-3 << 16` | 执行抛出异常 |
| `SIGNAL` | `1 << 16` | 有线程在等待该任务结果（唤醒标记） |

`join()` 的完整流程：

```java
public final V join() {
    int s;
    if ((s = status) >= 0) {          // 任务还没完成
        s = doJoin();                 // 尝试不阻塞地完成
        if (s >= 0) {
            externalAwaitDone();      // 真正阻塞等待 + 帮助执行
        }
    }
    V result = getRawResult();
    if (s < 0) { ... 检查异常或取消 ... }
    return result;
}
```

**`doJoin()` 的精髓**：如果任务还没被别的线程拿走（`status >= 0` 且还在当前队列），当前线程会**直接执行它**（`doExec()`），而不是傻等。这就是 ForkJoin 与 `Future.get()` 最大的不同——**等待者主动帮忙干活**，整个池子没有"纯等待"的线程。

## 五、常见问题与面试追问

### 5.1 ForkJoinPool 和 ThreadPoolExecutor 怎么选？

| 维度 | ThreadPoolExecutor | ForkJoinPool |
| --- | --- | --- |
| 任务模型 | 独立任务，互不依赖 | 可分治的父子任务 |
| 队列 | 共享 BlockingQueue | 每线程双端队列 + 工作窃取 |
| 阻塞等待 | Future.get() 干等 | join() 时帮助执行任务 |
| 最佳场景 | IO 密集型、任务间无依赖 | CPU 密集的分治计算 |
| 默认池 | 无 | commonPool（并行度=CPU核数-1） |

### 5.2 什么情况下 ForkJoinPool 会变慢甚至死锁？

1. **任务里做了阻塞 IO**：工作线程被 IO 阻塞，无法帮助执行其他任务，窃取链条断裂，池利用率急剧下降。解决办法：IO 密集型任务不要用 ForkJoinPool，或者把 IO 也拆成可窃取的小任务。
2. **任务依赖外部线程**：如子任务内部调用 `Thread.sleep()` 或等待外部锁，可能引发 **Thread starvation deadlock**——所有工作线程都在等一个被阻塞线程的结果，而池里没有多余线程执行它。`commonPool` 默认不补偿这种场景（除非配置 `-Djava.util.concurrent.ForkJoinPool.common.threadFactory` 等），自建池可用 `new ForkJoinPool(parallelism, factory, handler, true)` 开启异步补偿模式。
3. **拆分阈值太小**：任务拆分过细，fork/join 的上下文开销大于计算收益。

### 5.3 如何观测 ForkJoinPool？

```java
ForkJoinPool pool = new ForkJoinPool(8);
// 统计信息
pool.getPoolSize();        // 当前线程数
pool.getStealCount();      // 窃取次数（衡量负载均衡效果）
pool.getQueuedTaskCount(); // 队列中等待的任务数
pool.getRunningThreadCount();
```

`StealCount` 是衡量工作窃取效果的直观指标：并行度设置合理且任务可分时，窃取次数会比较高；如果为 0，说明任务根本没被拆分或并行度不足。

### 5.4 并行流一定比串行快吗？

不一定。`Stream.parallel()` 底层用的是 `commonPool`，并行度 = CPU 核数 - 1。对于：
- **小数据量**：拆分、合并、线程调度的开销超过收益；
- **存在共享可变状态**（如并发写同一个 ArrayList）：线程安全问题 + 缓存伪共享，可能更慢；
- **IO 密集型**：线程都在等 IO，并行无意义。

经验法则：数据量达到十万级以上、计算密集且可拆分，才考虑并行流；否则串行更稳。

## 六、总结

| 知识点 | 一句话记忆 |
| --- | --- |
| 分治思想 | 大任务拆小任务，小到阈值直接算 |
| 工作窃取 | 自己的队列空了，从别人队尾偷任务 |
| 双端队列 | 自己从队头（top）操作无锁，别人从队尾（base）CAS 偷 |
| join 不傻等 | 等待者主动帮助执行未完成的任务 |
| 三大子类 | RecursiveAction / RecursiveTask / CountedCompleter |
| 使用红线 | 任务内别做阻塞 IO，别依赖外部线程结果 |

ForkJoinPool 是理解"如何把 CPU 压榨到极致"的最佳教材。搞懂它的双端队列与窃取算法，你不仅能答好面试题，更能在真正的并行计算场景中写出高性能代码。

**面试官最后会问：如果让你设计一个分治框架，你会怎么做？** 现在你可以自信地回答：每线程一个队列避免全局锁竞争，任务拆到阈值直接算，空闲线程从其他队列偷任务，等待任务时主动帮忙执行——这就是 ForkJoinPool 的全部秘密。
