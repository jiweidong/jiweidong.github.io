---
title: 【面试必备】Fork/Join 框架与工作窃取算法：从分治任务到并行计算
date: 2026-06-29 08:00:00
tags:
  - Java
  - 并发
  - 面试
  - 多线程
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【面试必备】Fork/Join 框架与工作窃取算法：从分治任务到并行计算

## 面试官：说说 Fork/Join 框架是什么？和线程池有什么关系？

**Fork/Join 框架是 Java 7 引入的并行计算框架，核心思想是分治法（Divide and Conquer）。** 它位于 `java.util.concurrent` 包下，是对传统线程池 `ThreadPoolExecutor` 的一种补充和优化。

我们先看一个经典的例子——使用 Fork/Join 进行大数组求和：

```java
public class SumTask extends RecursiveTask<Long> {
    private static final int THRESHOLD = 1000;
    private final long[] array;
    private final int start, end;

    public SumTask(long[] array, int start, int end) {
        this.array = array;
        this.start = start;
        this.end = end;
    }

    @Override
    protected Long compute() {
        int length = end - start;
        if (length <= THRESHOLD) {
            // 小任务：直接计算
            long sum = 0;
            for (int i = start; i < end; i++) {
                sum += array[i];
            }
            return sum;
        }
        // 大任务：分治
        int mid = start + length / 2;
        SumTask leftTask = new SumTask(array, start, mid);
        SumTask rightTask = new SumTask(array, mid, end);

        leftTask.fork();     // 异步执行左子任务
        Long rightResult = rightTask.compute(); // 当前线程执行右子任务
        Long leftResult = leftTask.join();      // 等待左子任务结果

        return leftResult + rightResult;
    }

    public static void main(String[] args) {
        long[] array = new long[10_000_000];
        Arrays.fill(array, 1);

        ForkJoinPool pool = new ForkJoinPool();
        Long result = pool.invoke(new SumTask(array, 0, array.length));
        System.out.println("Sum = " + result); // 10000000
    }
}
```

### ForkJoinPool vs ThreadPoolExecutor

| 维度 | ThreadPoolExecutor | ForkJoinPool |
|------|-------------------|--------------|
| **任务类型** | 独立、无依赖的任务 | 可分解的递归任务 |
| **队列结构** | 一个共享的 BlockingQueue | 每个工作线程一个双端队列 |
| **任务窃取** | 不支持 | 支持工作窃取 |
| **调度机制** | 生产者-消费者模型 | 分治 + 窃取 |
| **适合场景** | IO密集型、短任务 | CPU密集型计算 |
| **线程数量** | 手动指定 | 默认 `Runtime.availableProcessors()` |

## 框架核心：两大角色三种类

### ForkJoinPool —— 调度池

与普通线程池不同，ForkJoinPool 内部维护着一个**工作线程数组**（`WorkQueue[]`），每个工作线程拥有自己的双端队列（Deque）。

```java
// ForkJoinPool 核心成员
volatile WorkQueue[] workQueues;  // 工作队列数组
ForkJoinTask<?>[] tasks;          // 窃取的任务
```

每个 `WorkQueue` 既有自己的任务队列，又可以从其他队列**窃取**任务。队列尾部存放自己提交的任务（LIFO），头部用来被窃取（FIFO）。

### ForkJoinTask —— 任务基类

三个抽象子类：

| 类名 | 返回值 | 使用场景 |
|------|--------|----------|
| `RecursiveAction` | void | 只需执行计算，不需返回结果 |
| `RecursiveTask<V>` | V | 需要返回计算结果 |
| `CountedCompleter` | void | 带完成回调的复杂任务 |

### WorkQueue —— 双端队列

每个工作线程的私有队列，支持三种操作：

- **push(task)**：线程将任务压入自己的队列尾部（LIFO）
- **pop()**：线程从自己队列尾部取任务（LIFO）
- **poll()**：其他线程从队首窃取任务（FIFO）

## 工作窃取算法（Work-Stealing）

**核心思想**：空闲的工作线程从其他正忙的线程队列末尾"偷"任务来执行。

### 为什么能提升并行效率？

```text
线程1 队列: [T1] [T2] [T3] → 线程1 从队尾取 T1 执行
线程2 队列: [T4] [T5] [T6] → 线程2 从队尾取 T4 执行
                    ↑
线程3 空闲 → 从线程1队首窃取 T3 执行（FIFO）
```

### 窃取策略细节

1. **窃取目标**：从其他 `WorkQueue` 的 **base（头部）** 窃取（FIFO）
2. **自身消费**：从自己的 `WorkQueue` 的 **top（尾部）** 消费（LIFO）
3. **窃取粒度**：每次窃取一个任务，递归执行其子任务

### 为什么窃取效率高？

使用 LIFO 消费 + FIFO 窃取的组合，保证了**窃取到的任务足够大**（越晚入队的分治任务越大），减少了窃取的次数和线程间竞争。

```java
// ForkJoinPool.scan() 简化逻辑
private int scan(WorkQueue[] ws, int r) {
    for (int i = 0; i < ws.length; ++i) {
        WorkQueue wq = ws[(((r + i) << 1) | 1) & m];
        if (wq != null && wq.base != wq.top) {
            ForkJoinTask<?> t = wq.poll(); // 从队首窃取
            if (t != null) {
                return doExec(t);
            }
        }
    }
    return 0; // 无任务可窃取
}
```

## join() 的隐式优化：静默合并

Fork/Join 的 `join()` 不是简单的 `future.get()` 阻塞等待，而是：

```java
// RecursiveTask.join() 的简化逻辑
public final V join() {
    int s;
    if ((s = doJoin()) != NORMAL) {
        // 如果任务未完成，执行其他任务（包含窃取的任务）
        reportException(s);
    }
    return getRawResult();
}

private int doJoin() {
    Thread t = ForkJoinPool.common;
    return (t instanceof ForkJoinWorkerThread) 
        ? ((ForkJoinWorkerThread)t).workQueue.pushAndExec(this)
        : externalAwaitDone();
}
```

**关键优化**：在当前线程调用 `join()` 等待子任务时，如果子任务还未完成，当前线程不会傻等，而是去执行其他任务（甚至从其他队列窃取）。这叫 **help-join** 或 **静默合并**。

## JDK 8 中的 commonPool

JDK 8 引入了一个公共 ForkJoinPool（`ForkJoinPool.commonPool()`），被 `Parallel Stream`、`CompletableFuture` 等大量使用：

```java
// 默认 parallelism = CPU核心数 - 1
ForkJoinPool commonPool = ForkJoinPool.commonPool();
System.out.println(commonPool.getParallelism()); // 7 (8核CPU)
```

### 如何配置？

```bash
# JVM 参数设置公共池并行度
-Djava.util.concurrent.ForkJoinPool.common.parallelism=4
-Djava.util.concurrent.ForkJoinPool.common.threadFactory=...
```

### 误区：Parallel Stream 都使用 commonPool

```java
// 它们共享同一个 ForkJoinPool.commonPool()
list.parallelStream().forEach(...);
list2.parallelStream().forEach(...);
```

⚠️ 如果提交阻塞任务，它们会**互相影响**。推荐使用自定义 ForkJoinPool：

```java
ForkJoinPool customPool = new ForkJoinPool(10);
try {
    customPool.submit(() -> 
        list.parallelStream().forEach(this::process)
    ).get();
} finally {
    customPool.shutdown();
}
```

## 实战：排序算法加速

### 快速排序并行版

```java
public class ParallelQuickSort extends RecursiveAction {
    private final int[] arr;
    private final int left, right;

    @Override
    protected void compute() {
        if (left >= right) return;
        if (right - left < 1000) {
            Arrays.sort(arr, left, right + 1); // 小数组直接串行
            return;
        }
        int pivot = partition(arr, left, right);
        ParallelQuickSort leftSort = new ParallelQuickSort(arr, left, pivot - 1);
        ParallelQuickSort rightSort = new ParallelQuickSort(arr, pivot + 1, right);
        invokeAll(leftSort, rightSort); // forkAll + joinAll 的快捷方法
    }
}
```

### 性能对比（1000万随机数）

| 算法 | 耗时（ms） | 加速比 |
|------|-----------|--------|
| Arrays.sort()（串行） | 680 | 1x |
| Parallel QuickSort | 280 | 2.4x |
| Arrays.parallelSort() | 210 | 3.2x |

## 面试官常见追问

### Q1: ForkJoinPool 和 ThreadPoolExecutor 的工作窃取有什么区别？

> ThreadPoolExecutor 不原生支持工作窃取。虽然 JDK 8 引入了 `Executors.newWorkStealingPool()`，但其底层就是 ForkJoinPool，只是提供了不同的默认参数。
>
> 真正的区别在于任务队列的管理模式：TPE 所有线程共享一个队列，争抢严重；FJP 每个线程独立队列，空闲时窃取。

### Q2: ForkJoinPool 的线程数怎么确定？

> 默认使用 `Runtime.getRuntime().availableProcessors()`（commonPool 还减 1）。推荐设置 = CPU 核心数，因为 Fork/Join 适合 **CPU密集型** 计算。IO密集型场景不宜使用，因为工作窃取无法补偿 IO 等待。

### Q3: fork() 和 compute() 调用顺序有什么讲究？

```java
// ❌ 低效写法
leftTask.fork();
rightTask.fork();
Long leftResult = leftTask.join();
Long rightResult = rightTask.join(); // 两个子任务都被提交到队列

// ✅ 高效写法
leftTask.fork();           // 左任务入队
Long rightResult = rightTask.compute(); // 右任务当前线程直接执行
Long leftResult = leftTask.join();      // 等待左任务
```

推荐先 `fork()` 子任务，剩余的一个子任务用 `compute()` 在当前线程执行。这避免了不必要的入队和窃取开销。

### Q4: ForkJoinTask 抛异常怎么办？

```java
try {
    pool.invoke(task);
} catch (Exception e) {
    // 实际会被包装
}
// 或者用 completeExceptionally() 手动标记异常
```

通过 `getException()` 获取任务执行中抛出的原始异常。

## 最佳实践总结

1. **任务粒度**：阈值太小（频繁 fork/join）或太大（退化为串行）。推荐：每个子任务执行 100-10000 次基本操作
2. **避免阻塞**：不要在 ForkJoinTask 内调用阻塞 IO 或 `Thread.sleep()`
3. **使用 invokeAll()**：批量 fork + join 的优化版本
4. **自定线程池**：不要把不同类型的任务扔到 commonPool
5. **监控池状态**：`getStealCount()` 可以评估工作窃取的效率

```java
// 监控示例
ForkJoinPool pool = new ForkJoinPool(4);
System.out.println("Steal Count: " + pool.getStealCount());
System.out.println("Active Threads: " + pool.getActiveThreadCount());
System.out.println("Queued Tasks: " + pool.getQueuedTaskCount());
```

Fork/Join 是 Java 并发编程最后一块拼图，理解了它才算真正掌握了 Java 的并行计算能力。下次面试官问起 Parallel Stream 的底层原理，你就可以自信地回答：**基于 ForkJoinPool 的工作窃取算法**。
