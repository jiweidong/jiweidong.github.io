---
title: 【并发编程】FutureTask 源码深度解析：从 Callable 到异步任务状态机
date: 2026-08-06 08:00:00
tags:
  - Java
  - 并发
  - FutureTask
  - 源码
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】FutureTask 源码深度解析：从 Callable 到异步任务状态机

## 面试官：说说 FutureTask 是怎么实现异步获取结果的？

很多同学对 `Future` 的印象停留在"线程池 submit 后返回一个 Future，调 get() 能拿到结果"，但一旦被追问：

- get() 是怎么**阻塞**的？为什么调用后线程会停下来？
- cancel(true) 之后任务真的被取消了吗？
- 为什么同一个 FutureTask 的 run() 只能执行一次？
- FutureTask 和 CompletableFuture 有什么本质区别？

就会卡壳。本文从 JDK 8 源码出发，把 FutureTask 的**状态机、阻塞唤醒机制、取消语义**彻底讲透。

<!-- more -->

## 一、FutureTask 的身世：接口与类体系

先看类定义：

```java
public class FutureTask<V> implements RunnableFuture<V> {
    // RunnableFuture 同时继承了 Runnable 和 Future
    public interface RunnableFuture<V> extends Runnable, Future<V> {
        void run();
    }
}
```

所以 FutureTask **既是 Runnable 又是 Future**——既能被线程执行，又能获取执行结果。这也是为什么线程池的 `execute()` 也能接收 FutureTask（通过 Runnable 适配器包装）。

整个异步体系分成三层：

| 角色 | 代表 | 职责 |
|------|------|------|
| 任务定义 | Callable / Runnable | 定义要执行的计算逻辑 |
| 任务封装 | FutureTask / RunnableAdapter | 包装任务，管理状态与结果 |
| 任务执行 | Thread / ThreadPoolExecutor | 负责调度执行 |
| 结果获取 | Future 接口 | get() / cancel() / isDone() |

`Executors.callable(Runnable)` 内部就是通过 `RunnableAdapter` 把 Runnable 适配成 Callable，再包进 FutureTask。

## 二、核心字段与状态机

```java
// 任务状态，volatile 保证多线程可见性
private volatile int state;
private static final int NEW          = 0; // 新建，任务尚未开始
private static final int COMPLETING   = 1; // 正在设置结果（中间态）
private static final int NORMAL       = 2; // 正常完成
private static final int EXCEPTIONAL  = 3; // 执行异常
private static final int CANCELLED    = 4; // 被取消（不中断）
private static final int INTERRUPTING = 5; // 正在中断（中间态）
private static final int INTERRUPTED  = 6; // 已中断

private Callable<V> callable;   // 任务
private Object outcome;         // 结果或异常
private volatile Thread runner; // 正在执行任务的线程
private volatile WaitNode waiters; // 等待结果的线程链表（栈）
```

状态迁移图：

```
        NEW ──┬─► COMPLETING ──► NORMAL       （正常完成）
              ├─► COMPLETING ──► EXCEPTIONAL  （执行异常）
              ├─► CANCELLED                  （cancel(false)）
              └─► INTERRUPTING ──► INTERRUPTED（cancel(true)）
```

注意几个关键点：

1. `NEW -> COMPLETING -> NORMAL` 中间存在一个**瞬时中间态** COMPLETING，这是为了在 CAS 更新状态时避免 ABA 问题。
2. 只有 `NEW` 状态才能被 `run()` 或 `cancel()` 转移，这就是**任务只能执行一次**的保证。
3. 状态一旦离开 NEW 就**不可逆**，所以结果只能设置一次，这也是 Future 天然幂等的原因。

## 三、run() 方法：任务的真正执行点

```java
public void run() {
    // 1. 状态必须是 NEW，且用 CAS 把 runner 从 null 置为当前线程
    if (state != NEW ||
        !RUNNER.compareAndSet(this, null, Thread.currentThread()))
        return; // 已被执行或取消，直接返回

    try {
        Callable<V> c = callable;
        if (c != null && state == NEW) {
            V result;
            boolean ran;
            try {
                result = c.call();      // 真正执行业务逻辑
                ran = true;
            } catch (Throwable ex) {
                result = null;
                ran = false;
                setException(ex);       // 异常封装进 outcome
            }
            if (ran)
                set(result);            // 正常结果封装进 outcome
        }
    } finally {
        runner = null;                  // 释放 runner
        int s = state;
        if (s >= INTERRUPTING)
            handlePossibleCancellationInterrupt(s); // 处理中断竞态
    }
}
```

核心逻辑就是三步：**CAS 抢占 runner -> 执行 call() -> 设置结果**。CAS 抢占保证了并发调用 run() 时只有一个线程真正执行。

### set() 与结果发布

```java
protected void set(V v) {
    // NEW -> COMPLETING
    if (STATE.compareAndSet(this, NEW, COMPLETING)) {
        outcome = v;
        // COMPLETING -> NORMAL，并唤醒所有等待线程
        STATE.setRelease(this, NORMAL); // JDK 9+ 使用 VarHandle release
        finishCompletion();
    }
}
```

`finishCompletion()` 会遍历 waiters 链表，逐个 `LockSupport.unpark` 唤醒，然后清空 callable 帮助 GC：

```java
private void finishCompletion() {
    for (WaitNode q; (q = waiters) != null;) {
        if (WAITERS.weakCompareAndSet(this, q, null)) {
            for (;;) {
                Thread t = q.thread;
                if (t != null) {
                    q.thread = null;
                    LockSupport.unpark(t); // 唤醒等待线程
                }
                WaitNode next = q.next;
                if (next == null) break;
                q.next = null;
                q = next;
            }
            break;
        }
    }
    done();
    callable = null; // 帮助 GC
}
```

## 四、get() 方法：阻塞与唤醒的真相

```java
public V get() throws InterruptedException, ExecutionException {
    int s = state;
    if (s <= COMPLETING)
        s = awaitDone(false, 0L);   // 任务未完成，阻塞等待
    return report(s);               // 解析 outcome
}
```

### awaitDone：等待者链表 + LockSupport

```java
private int awaitDone(boolean timed, long nanos) throws InterruptedException {
    long deadline = timed ? System.nanoTime() + nanos : 0L;
    WaitNode q = null;
    boolean queued = false;
    for (;;) {
        if (Thread.interrupted()) {
            removeWaiter(q);        // 中断则从链表移除自己
            throw new InterruptedException();
        }
        int s = state;
        if (s > COMPLETING) {       // 已结束（含取消/异常）
            if (q != null) q.thread = null;
            return s;
        }
        else if (s == COMPLETING)   // 正在收尾，让出 CPU
            Thread.yield();
        else if (q == null)
            q = new WaitNode();     // 初始化等待节点
        else if (!queued)
            queued = WAITERS.compareAndSet(this, q.next = waiters, q); // 头插法入栈
        else if (timed) {
            // 超时版本：parkNanos
            nanos = deadline - System.nanoTime();
            if (nanos <= 0L) { removeWaiter(q); return state; }
            LockSupport.parkNanos(this, nanos);
        }
        else
            LockSupport.park(this); // 挂起当前线程
    }
}
```

**这就是 get() 阻塞的底层原理**：调用 get() 的线程会被 `LockSupport.park()` 挂起，并把自己的 WaitNode 挂到 waiters 栈上；任务完成时 `finishCompletion()` 用 `unpark` 唤醒。**不是自旋忙等，而是真正的线程挂起**，不浪费 CPU。

### report：结果解析

```java
private V report(int s) throws ExecutionException {
    Object x = outcome;
    if (s == NORMAL)      return (V)x;                  // 正常返回
    if (s >= CANCELLED)   throw new CancellationException(); // 取消
    throw new ExecutionException((Throwable)x);         // 异常包装
}
```

注意：任务内部抛出的异常会被包装成 `ExecutionException` 抛出，**而不会直接抛原始异常**。这是面试常考细节。

## 五、cancel() 方法：真的能取消吗？

```java
public boolean cancel(boolean mayInterruptIfRunning) {
    // 只有 NEW 状态才能取消
    if (!(state == NEW && STATE.compareAndSet
          (this, NEW, mayInterruptIfRunning ? INTERRUPTING : CANCELLED)))
        return false;

    try {
        if (mayInterruptIfRunning) {
            Thread t = runner;
            if (t != null)
                t.interrupt();          // 给执行线程发中断信号
        }
    } finally {
        STATE.setRelease(this, mayInterruptIfRunning ? INTERRUPTED : CANCELLED);
    }
    finishCompletion();                  // 唤醒所有等待者
    return true;
}
```

**关键结论（面试高频）**：

1. `cancel()` 返回 `true` 只代表**状态切换成功**，不代表业务代码真的停止了。
2. `cancel(true)` 只是给执行线程发了一个**中断信号**（`interrupt()`），业务代码如果不响应中断（不检查 `Thread.interrupted()`、不抛 InterruptedException），**任务依然会跑完**。
3. 对于 `cancel(false)`，如果任务已经在运行，它完全不受影响。
4. 任务**已结束**或**已取消**后，`cancel()` 返回 `false`。

## 六、与 CompletableFuture 的本质区别

| 维度 | FutureTask | CompletableFuture |
|------|-----------|-------------------|
| 结果获取 | 阻塞式 get() | 回调式 thenApply/whenComplete |
| 任务编排 | 不支持 | 支持链式编排、组合 |
| 异常处理 | 统一抛 ExecutionException | 可精细化处理 |
| 手动完成 | 不支持 | complete() 可手动完成 |
| 本质 | 单任务状态管理 | 完整异步编程模型 |

一句话总结：**FutureTask 是"单任务的异步封装"，CompletableFuture 是"异步任务编排框架"**。FutureTask 是 JDK 5 的产物，CompletableFuture 是 JDK 8 引入的补全。

## 七、面试官连环追问

**Q1：submit() 和 execute() 的区别？**
execute 只接收 Runnable 且无返回值；submit 接收 Callable/Runnable，返回 Future，内部通过 `RunnableAdapter` 适配并包装成 FutureTask。

**Q2：get(timeout) 超时后任务还在跑吗？**
在跑。超时只是让调用线程不再等待（从 waiters 链表移除自己返回），任务本身继续执行，结果会被丢弃。

**Q3：一个 FutureTask 能被两个线程同时执行吗？**
不能。run() 里 CAS 抢占 runner 失败会直接返回，保证同一时刻只有一个线程真正执行 call()。

**Q4：为什么 get() 不消耗 CPU？**
因为用的是 LockSupport.park() 线程挂起 + 完成时 unpark 唤醒，属于真正的阻塞等待，而非忙等。

**Q5：任务执行抛出异常，get() 会怎样？**
get() 抛出 ExecutionException，原始异常被包装在 cause 里，可通过 `e.getCause()` 获取。

**Q6：FutureTask 里的 callable 为什么要置 null？**
`finishCompletion()` 里 `callable = null` 是为了帮助 GC 回收任务对象，避免结果已获取后任务仍被长期持有。

## 八、实战建议

1. **能用 CompletableFuture 就别用 FutureTask** 做编排，除非是简单的一对一异步。
2. 用 `get(timeout, TimeUnit)` 代替无参 `get()`，防止线程永久阻塞。
3. 取消任务时业务代码要**响应中断**：循环里检查 `Thread.currentThread().isInterrupted()`。
4. 线程池的 shutdownNow 依赖的就是 interrupt 机制，所以任务对中断的响应决定了它能否被快速终止。

FutureTask 虽然简单，但它是理解整个 Java 异步体系的地基——状态机、CAS、LockSupport、中断协作，全在这一个类里。吃透它，再去啃 AQS 和 CompletableFuture 会轻松很多。
