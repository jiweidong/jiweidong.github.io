---
title: 【并发编程】Java 线程中断机制深度解析：interrupt、isInterrupted 与 InterruptedException 的真相
date: 2026-08-07 08:00:00
tags:
  - Java
  - 并发
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】Java 线程中断机制深度解析：interrupt、isInterrupted 与 InterruptedException 的真相

## 面试官：如何停止一个线程？说说 interrupt 和 InterruptedException 的关系？

"停止线程"是并发编程面试的经典题，也是日常开发最容易写错的点。很多人以为 `interrupt()` 能"杀死"线程，或者靠 `volatile boolean` 标志位就万事大吉。这篇文章从源码层面彻底讲清楚 Java 的中断机制。

## 一、先纠正一个误区：interrupt 不是"强制停止"

```java
Thread t = new Thread(() -> {
    while (true) {
        System.out.println("running...");
    }
});
t.start();
t.interrupt();  // ❌ 线程并不会停！
```

`interrupt()` 的本质是**给目标线程设置一个"中断标志位"（interrupt status）**，并**唤醒**它可能处于的阻塞状态。线程要不要响应、怎么响应，完全由线程自己决定。

为什么 Java 不提供 `stop()` 强制终止？因为 `stop()`（已废弃）会在线程任意位置突然抛 `ThreadDeath`，导致**资源不释放、数据不一致、锁被莫名释放**——这是灾难性的。中断机制是**协作式**的：被中断线程有机会清理资源、安全退出。

## 二、三个核心方法：interrupt / isInterrupted / interrupted

| 方法 | 作用 | 是否清除中断标志 |
|------|------|------------------|
| `thread.interrupt()` | 设置中断标志；若线程阻塞在可中断方法上则抛 `InterruptedException` | 不清除（设置） |
| `thread.isInterrupted()` | 查询中断标志（实例方法） | **不**清除 |
| `Thread.interrupted()` | 查询当前线程中断标志（静态方法） | **清除**（重置为 false） |

### 源码验证

```java
// Thread 中的核心实现
public void interrupt() {
    if (this != Thread.currentThread()) {
        checkAccess();
    }
    synchronized (blockedLock) {
        Interruptible b = blockedOn;   // 可中断阻塞的钩子
        if (b != null) {
            interrupt0();              // 设置中断标志（native）
            b.interrupt(this);         // 唤醒阻塞（如 NIO 通道）
            return;
        }
    }
    interrupt0();                      // 纯设置标志位
}

private native void interrupt0();      // 底层设置 JVM 层面的中断状态

public static boolean interrupted() {
    return currentThread().isInterrupted(true);   // true = 清除标志
}

public boolean isInterrupted() {
    return isInterrupted(false);                  // false = 不清除
}
```

注意 `interrupted()` 传 `true`、`isInterrupted()` 传 `false`——这就是"静态方法会清除标志"的根源。

## 三、阻塞与中断：InterruptedException 何时抛出？

当线程处于**可中断的阻塞状态**时，收到 `interrupt()` 会立刻抛 `InterruptedException`，并**清除中断标志**：

| 阻塞场景 | 方法 | 收到 interrupt 的行为 |
|----------|------|----------------------|
| 线程休眠 | `Thread.sleep()` | 抛 InterruptedException，标志清除 |
| 等待 | `Object.wait()` / `wait(timeout)` | 抛 InterruptedException，标志清除 |
| 条件等待 | `Condition.await()` | 抛 InterruptedException，标志清除 |
| 阻塞队列 | `BlockingQueue.take()` / `put()` | 抛 InterruptedException，标志清除 |
| 线程池 | `ExecutorService.awaitTermination()` | 抛 InterruptedException，标志清除 |
| 锁获取 | `ReentrantLock.lockInterruptibly()` | 抛 InterruptedException，标志清除 |
| 非可中断 | `synchronized`、`Thread.join()`（无参）、普通 IO | **不响应**（阻塞到底） |

**关键认知**：抛出 `InterruptedException` 时标志位已经被清除了。所以捕获异常后想查询标志，得到的是 `false`。

### 为什么 synchronized 不响应中断？

`synchronized` 的阻塞在 JVM 监视器上，属于**不可中断阻塞**。如果想"抢锁可以被中断"，用 `ReentrantLock.lockInterruptibly()`。

## 四、响应中断的两种正确姿势

### 姿势一：传递中断（推荐）

```java
// 方法本身声明了 InterruptedException，直接抛出去
public void doTask() throws InterruptedException {
    Thread.sleep(1000);
}
```

调用方继续处理或继续上抛，让中断信号沿着调用链传播——这是**最优雅**的方式。

### 姿势二：恢复中断标志（捕获后重新设置）

```java
public void run() {
    while (!Thread.currentThread().isInterrupted()) {
        try {
            Thread.sleep(100);   // 可中断阻塞
        } catch (InterruptedException e) {
            // 异常抛出时标志已被清除，这里要恢复它
            Thread.currentThread().interrupt();
            // 记录日志、清理资源
            break;
        }
    }
}
```

**为什么不恢复标志是 bug？**

```java
// ❌ 错误示范：吞掉中断
catch (InterruptedException e) {
    // 什么都不做 —— 中断信号丢失！
}
// 上层代码 isInterrupted() 永远是 false，线程无法感知"该停了"
```

中断标志是**唯一的信号载体**，不恢复就等于信号丢失。这也是阿里巴巴 Java 开发手册明确要求的：`InterruptedException` 不能吞掉，要么上抛、要么 `Thread.currentThread().interrupt()` 恢复。

## 五、线程池场景：shutdown 与 interrupt

`ExecutorService` 的中断语义：

```java
ExecutorService pool = Executors.newFixedThreadPool(4);

// shutdown()：不再接收新任务，已提交任务执行完，不中断
pool.shutdown();

// shutdownNow()：尝试中断正在执行的任务（发 interrupt 信号）
List<Runnable> pending = pool.shutdownNow();
```

注意 `shutdownNow()` 只发**中断信号**，如果你的任务里没有响应中断的代码，线程照样执行完。配合正确写法：

```java
// 线程池中的任务正确响应中断
pool.submit(() -> {
    while (!Thread.currentThread().isInterrupted()) {
        // 干活...
        try {
            TimeUnit.SECONDS.sleep(1);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();  // 恢复标志
            break;
        }
    }
});
```

**面试追问：`Future.cancel(true)` 能取消正在运行的任务吗？**

```java
Future<?> f = pool.submit(task);
f.cancel(true);   // true = 发送 interrupt 信号
```

`cancel(true)` 底层调用 `interrupt()`，但**同样依赖任务自身响应**。若任务里有 `Thread.sleep()`、`take()` 这类可中断阻塞，就会立刻抛异常取消；若是纯 CPU 计算循环且不检查标志，则取消无效。

## 六、中断 vs volatile 标志位，怎么选？

```java
// 方式一：volatile 标志（适合无阻塞的循环任务）
volatile boolean running = true;
while (running) { /* 干活 */ }
// 停止：running = false（注意：若线程阻塞在 sleep/wait，无法立即唤醒！）

// 方式二：中断机制（适合含阻塞操作的任务）
while (!Thread.currentThread().isInterrupted()) {
    Thread.sleep(100);  // 阻塞时也能被唤醒
}
// 停止：t.interrupt()
```

**选择原则**：
- 任务里有 `sleep/wait/take` 等阻塞 → **必须用中断**（volatile 改不了阻塞状态）
- 纯计算无阻塞 → volatile 标志更简单直观，但中断机制同样适用
- 混合场景 → 中断机制一统天下

## 七、面试速答

1. **interrupt 会停止线程吗？** 不会。它只是设置中断标志 + 唤醒可中断阻塞，线程需自行协作响应。
2. **InterruptedException 抛出时标志位还在吗？** 不在了，已被清除，所以捕获后要 `Thread.currentThread().interrupt()` 恢复。
3. **interrupted 和 isInterrupted 区别？** 前者是静态方法且清除标志，后者是实例方法不清除。
4. **synchronized 能被中断吗？** 不能，用 `ReentrantLock.lockInterruptibly()` 实现可中断锁。
5. **优雅关闭线程池？** `shutdown()` 等任务完成；需要立即停用 `shutdownNow()` + 任务内响应中断。

中断是 Java 并发协作的灵魂之一，理解它，你的线程池、异步任务、分布式任务调度才能"想停就停、安全地停"。
