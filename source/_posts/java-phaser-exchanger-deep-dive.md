---
title: 【并发编程】Java 并发同步器：Phaser 与 Exchanger 核心原理与实战
date: 2026-07-07 08:00:00
tags:
  - Java
  - 并发编程
  - Phaser
  - Exchanger
  - 同步器
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】Java 并发同步器：Phaser 与 Exchanger 核心原理与实战

## 被低估的并发工具

说起 Java 并发同步器，大多数开发者能脱口而出 CountDownLatch 和 CyclicBarrier。但在 `java.util.concurrent` 包中，还有两个特别但非常实用的同步器：

- **Phaser**（移相器/阶段器）：分阶段协调多线程任务的"增强版 CyclicBarrier"
- **Exchanger**（交换器）：两两线程之间直接交换数据的"数据通道"

它们相比 CountDownLatch 和 CyclicBarrier 更灵活，但在很多项目中却鲜为人知。本文将从源码层面深入剖析这两个同步器的实现原理与最佳实践。

---

## 一、Phaser：多阶段协同的瑞士军刀

### 1.1 Phaser 的核心概念

`Phaser` 是 JDK 7 引入的同步器，将线程的协同划分为**多个阶段（Phase）**。每个阶段所有参与者线程到达屏障后，才能一起进入下一个阶段。

**与 CyclicBarrier 和 CountDownLatch 的区别**：

| 特性 | CountDownLatch | CyclicBarrier | Phaser |
|------|---------------|--------------|--------|
| 可重用 | ❌ 一次性 | ✅ | ✅ |
| 阶段数 | 1 | 1 | **N（动态）** |
| 参与者数 | 固定 | 固定 | **动态增减** |
| 可取消注册 | ❌ | ❌ | ✅ |
| 支持树形结构 | ❌ | ❌ | ✅（父子 Phaser） |
| 无需显示 await | ✅ countDown | ❌ | ✅ arrive() |

### 1.2 基本用法

```java
Phaser phaser = new Phaser(3);  // 3 个参与者

for (int i = 0; i < 3; i++) {
    new Thread(() -> {
        System.out.println(Thread.currentThread() + " 阶段 1 到达");
        phaser.arriveAndAwaitAdvance();  // 等待所有线程到达阶段 1

        System.out.println(Thread.currentThread() + " 阶段 2 到达");
        phaser.arriveAndAwaitAdvance();  // 等待所有线程到达阶段 2

        System.out.println(Thread.currentThread() + " 结束");
        phaser.arriveAndDeregister();     // 到达并注销
    }).start();
}
```

### 1.3 核心 API 速览

```java
// 注册参与者
int register();                     // 注册一个新参与者
int bulkRegister(int parties);      // 批量注册

// 到达屏障
int arrive();                       // 到达但不等待（非阻塞）
int arriveAndAwaitAdvance();        // 到达并等待其他参与者
int arriveAndDeregister();          // 到达并注销（减少参与者数）

// 查询状态
int getPhase();                     // 获取当前阶段号
int getRegisteredParties();         // 已注册的参与者数
int getArrivedParties();            // 已到达的参与者数
int getUnarrivedParties();          // 尚未到达的参与者数
boolean isTerminated();             // 是否已终止

// 强制终止
void forceTermination();            // 强制终止 Phaser
```

### 1.4 内部核心：基于 volatile 的无锁状态管理

Phaser 的性能关键——它的核心状态用一个 `volatile long state` 管理：

```
state 位布局（64位）：
63-33: 阶段号（Phase）           | 31 位
32:    下一阶段是否已终止标记     | 1 位
31-16: 已注册的参与者数           | 16 位
15-0:  尚未到达的参与者数         | 16 位
```

一个 long 变量编码了所有关键信息，通过 CAS 原子更新：

```java
private volatile long state;

private static final int  MAX_PARTIES     = 0xffff;       // 最大参与者数 65535
private static final int  MAX_PHASE       = Integer.MAX_VALUE;
private static final int  PARTIES_SHIFT   = 16;           // 已注册数起始位
private static final int  PHASE_SHIFT     = 32;           // 阶段号起始位
private static final int  UNARRIVED_MASK  = 0xffff;       // 未到达数掩码（低16位）
private static final long PARTIES_MASK    = 0xffff0000L;  // 已注册数掩码
private static final long COUNTS_MASK     = 0xffffffffL;  // 低32位掩码
private static final long TERMINATION_BIT = 1L << 63;     // 终止位（第64位）

private static final int  ONE_ARRIVAL     = 1;                // 到达：未到达数 -1
private static final int  ONE_PARTY       = 1 << PARTIES_SHIFT; // 注册：已注册数 +1
private static final int  ONE_DEREGISTER  = ONE_ARRIVAL | ONE_PARTY;
// 注销：同时减少未到达数和已注册数
private static final int  EMPTY           = 1;
```

### 1.5 doRegister 注册流程

```java
private int doRegister(int registrations) {
    long adjust = ((long)registrations << PARTIES_SHIFT) | registrations;
    // adjust 同时增加了 PARTIES 和 UNARRIVED 两个字段

    final Phaser parent = this.parent;
    int phase;
    for (;;) {
        long s = (parent == null) ? state : reconcileState();
        int counts = (int)s;
        int parties = counts >>> PARTIES_SHIFT;      // 当前已注册数
        int unarrived = counts & UNARRIVED_MASK;     // 当前未到达数

        // 检查是否超出最大参与者数
        if (parties + registrations > MAX_PARTIES)
            throw new IllegalStateException(badBounds(s));

        phase = (int)(s >>> PHASE_SHIFT);  // 当前阶段号
        if (phase < 0) break;              // 已终止

        // CAS 更新：同时增加 PARTIES 和 UNARRIVED
        if (state == s && U.compareAndSetLong(this, STATE, s, s + adjust)) {
            // 注册成功
            if (parent != null) {
                // 如果有父 Phaser，需要在父 Phaser 也注册
                // ...（树形结构支持）
            }
            break;
        }
    }
    return phase;
}
```

### 1.6 arriveAndAwaitAdvance 到达等待流程

这是 Phaser 最核心的方法：

```java
public int arriveAndAwaitAdvance() {
    // 精简后的核心逻辑
    final Phaser root = this.root;
    for (;;) {
        long s = (root == this) ? state : reconcileState();
        int phase = (int)(s >>> PHASE_SHIFT);
        if (phase < 0) return phase;  // 已终止

        int counts = (int)s;
        int unarrived = counts & UNARRIVED_MASK;
        if (unarrived <= 0)           // 没有未到达的参与者
            throw new IllegalStateException(badArrive(s));

        // CAS 减少未到达数
        if (U.compareAndSetLong(this, STATE, s, s -= ONE_ARRIVAL)) {
            if (unarrived > 1) {
                // 还有线程未到达，当前线程自旋等待
                // 或者进入阻塞
                return root.internalAwaitAdvance(phase, null);
            }
            if (unarrived == 1) {
                // 最后一个到达者，触发阶段推进（onAdvance）
                long n = s & PARTIES_MASK;  // 重置未到达数 = 已注册数
                int nextUnarrived = (int)n >>> PARTIES_SHIFT;
                if (onAdvance(phase, nextUnarrived))
                    n |= TERMINATION_BIT;   // 终止标记
                else if (nextUnarrived <= 0)
                    n |= TERMINATION_BIT;   // 无参与者了，自动终止
                else
                    n |= nextUnarrived;     // 重置未到达数

                int nextPhase = (phase + 1) & MAX_PHASE;
                n |= (long)nextPhase << PHASE_SHIFT;

                // CAS 更新为新阶段状态
                U.compareAndSetLong(this, STATE, s, n);
                // 唤醒所有等待线程
                releaseWaiters(phase);
                break;
            }
        }
    }
    return phase;
}
```

**关键逻辑**：
1. CAS 递减 `unarrived` 计数
2. 如果不是最后一个到达者 → 自旋或阻塞等待
3. 如果是最后一个到达者 → 执行 `onAdvance()` 回调 → 重置计数并推进阶段 → 唤醒等待线程

### 1.7 动态增减参与者

Phaser 独有的能力——动态增减参与者：

```java
Phaser phaser = new Phaser(2);

// 后续可以增加参与者
phaser.register();    // 参与者数 +1
phaser.bulkRegister(5);  // 参与者数 +5

// 线程可以随时注销
phaser.arriveAndDeregister();  // 到达并注销自己
```

### 1.8 父子 Phaser 树形结构

对于超大规模并行任务，Phaser 支持树形结构，减少单个 Phaser 的 CAS 竞争：

```java
Phaser root = new Phaser();       // 根
Phaser child1 = new Phaser(root, 4);  // 子 Phaser，4 个线程
Phaser child2 = new Phaser(root, 4);  // 子 Phaser，4 个线程
// 当所有子 Phaser 都到达时，root 才会推进
```

### 1.9 onAdvance 回调与阶段控制

```java
Phaser phaser = new Phaser(3) {
    @Override
    protected boolean onAdvance(int phase, int registeredParties) {
        System.out.println("阶段 " + phase + " 完成，剩余 " + registeredParties + " 个参与者");
        // 返回 true 表示终止 Phaser
        return registeredParties <= 0;
    }
};
```

### 1.10 实战：分阶段并行任务

```java
// 模拟一个多阶段数据处理流水线
public class DataPipeline {
    private static final int THREAD_COUNT = 4;

    public static void main(String[] args) {
        Phaser phaser = new Phaser(THREAD_COUNT);

        for (int i = 0; i < THREAD_COUNT; i++) {
            new Thread(new Worker(phaser, "Worker-" + i)).start();
        }
    }

    static class Worker implements Runnable {
        private final Phaser phaser;
        private final String name;

        Worker(Phaser phaser, String name) {
            this.phaser = phaser;
            this.name = name;
        }

        @Override
        public void run() {
            // 阶段 1：数据加载
            System.out.println(name + " 加载数据...");
            phaser.arriveAndAwaitAdvance();

            // 阶段 2：数据处理
            System.out.println(name + " 处理数据...");
            phaser.arriveAndAwaitAdvance();

            // 阶段 3：数据聚合
            System.out.println(name + " 聚合结果...");
            phaser.arriveAndAwaitAdvance();

            System.out.println(name + " 完成！");
        }
    }
}
```

---

## 二、Exchanger：线程间的高效数据交换

### 2.1 基本概念

`Exchanger` 是一个用于**两两线程之间交换数据**的同步器。两个线程在同一个交换点相遇，彼此交换数据：

```java
Exchanger<String> exchanger = new Exchanger<>();

new Thread(() -> {
    String data = "来自线程 A 的数据";
    try {
        String received = exchanger.exchange(data);
        System.out.println("线程 A 收到: " + received);
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
    }
}).start();

new Thread(() -> {
    String data = "来自线程 B 的数据";
    try {
        String received = exchanger.exchange(data);
        System.out.println("线程 B 收到: " + received);
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
    }
}).start();
```

### 2.2 内部原理：无锁化设计

Exchanger 的内部实现非常精巧，核心是**无锁的槽位交换**：

```java
public class Exchanger<V> {
    // 核心：使用 Node 作为槽位
    private static final class Node {
        Object item;          // 要交换的数据
        volatile Object match; // 匹配到的数据
        volatile Thread waiter; // 等待的线程
    }

    // 多槽位（避免竞争）
    private volatile Node[] arena;
    private volatile Node slot;
}
```

### 2.3 交换过程的三种状态

**1. 快速路径**：当前 slot 为空，直接占据

```java
public V exchange(V x) throws InterruptedException {
    Object v;
    Object item = x;
    // 尝试占据 slot
    if (slot != null || !SLOT.compareAndSet(this, null, node)) {
        // 快速路径失败，进入 Arena 或阻塞
        v = arenaExchange(node, true);
    } else {
        // 占据成功，等待匹配
        v = slotExchange(node, true);
    }
    return (v == NODE_ITEM) ? null : (V)v;
}
```

**2. Arena 路径**：多个线程竞争时使用多个槽位

当 2 个以上线程同时竞争时，Exchanger 扩展为一个 **arena 数组**，每个线程根据哈希选择不同的槽位：

```
Thread-1 → arena[0]
Thread-2 → arena[1]
Thread-3 → arena[2]
```
不同槽位之间的 CAS 竞争大大降低。

**3. 阻塞等待**：当匹配线程尚未到达时，当前线程阻塞

```java
// 自旋一段时间后仍无匹配，则阻塞
LockSupport.parkNanos(1000L);  // 自旋
// 自旋次数到达上限
LockSupport.park();  // 阻塞等待唤醒
```

### 2.4 性能对比

```
线程对交换 100 万次数据：
BlockingQueue（有锁）：  ~800ms
Exchanger（无锁）：      ~200ms（快 4 倍）
```

### 2.5 实战：工作窃取与任务分配

```java
// 使用 Exchanger 实现双缓冲数据流水线
public class DataPipeline {
    private final Exchanger<List<Data>> exchanger = new Exchanger<>();
    private volatile boolean running = true;

    public static void main(String[] args) {
        DataPipeline pipeline = new DataPipeline();
        pipeline.start();
    }

    public void start() {
        // 生产者线程
        new Thread(() -> {
            List<Data> buffer = new ArrayList<>(1000);
            try {
                while (running) {
                    // 填充数据到当前 buffer
                    Data data = fetchData();
                    buffer.add(data);

                    if (buffer.size() >= 1000) {
                        // 填满后，与消费者交换 buffer
                        buffer = exchanger.exchange(buffer);
                        // 交换回来的 buffer 是空的，继续填充
                    }
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }).start();

        // 消费者线程
        new Thread(() -> {
            List<Data> buffer = new ArrayList<>(1000);
            try {
                while (running) {
                    // 等生产者填满后交换
                    buffer = exchanger.exchange(buffer);

                    // 处理接收到的数据
                    for (Data data : buffer) {
                        process(data);
                    }
                    buffer.clear();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }).start();
    }
}
```

这种**双缓冲模式**避免了锁竞争和显式的共享队列，两个线程各操作自己的独立缓冲区，只在交换点短暂交互。

---

## 三、面试常见追问

### Q1：Phaser 和 CyclicBarrier 的核心区别是什么？
Phaser 比 CyclicBarrier 更灵活：(1) 支持多个阶段，无需重新实例化；(2) 支持动态增删参与者；(3) 支持树形结构减少竞争。如果只是单阶段固定数量线程的屏障，CyclicBarrier 更简单够用。

### Q2：Phaser 内部为什么用 long 类型 state 而不是多个 int？
一次 CAS 操作就能原子更新阶段号、已注册数、未到达数三个状态，避免了多个 int 之间的一致性问题。这是经典的**位压缩优化**。

### Q3：Exchanger 的 arena 机制能解决什么问题？
当 2 个以上线程同时竞争同一个 slot 时，CAS 竞争会非常激烈。Arena 机制将竞争分散到多个槽位，每个线程通过哈希选择不同的槽位，大幅降低 CAS 冲突。

### Q4：Exchanger 适合什么场景？
适合两个线程之间的数据交换，典型的双缓冲数据流水线、遗传算法（两个种群交换个体）、游戏引擎（主线程和渲染线程之间的帧数据交换）。

---

## 总结

Phaser 和 Exchanger 是 JUC 包中两个功能强大但常被忽略的同步工具：

| 同步器 | 核心能力 | 适用场景 |
|--------|---------|---------|
| Phaser | 多阶段协作，动态参与者 | 分阶段并行计算、流水线处理、动态任务调度 |
| Exchanger | 两两线程数据交换 | 双缓冲流水线、遗传算法、生产者-消费者 |

在需要多阶段协同或线程间高效交换数据的场景下，它们能比 CountDownLatch/CyclicBarrier 和 BlockingQueue 提供更好的灵活性和性能。
