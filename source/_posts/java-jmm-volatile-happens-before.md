---
title: 【面试必备】JVM 内存模型（JMM）与 happens-before 规则，这一篇就够了
date: 2026-06-21 08:00:00
tags:
  - Java
  - JVM
  - 并发
  - 面试
categories:
  - Java
  - JVM底层
author: 东哥
---

# 【面试必备】JVM 内存模型（JMM）与 happens-before 规则，这一篇就够了

## 面试官：说说什么是 JMM（Java 内存模型）？

**JMM（Java Memory Model）** 是一个抽象的概念，它定义了一套规则和规范，用来屏蔽不同硬件和操作系统的内存访问差异，确保 Java 程序在各种平台上都能达到内存访问的一致性。

> JMM 的核心围绕着三个特性展开：**原子性（Atomicity）**、**可见性（Visibility）**、**有序性（Ordering）**。

### 为什么需要 JMM？

现代 CPU 采用多级缓存架构（L1/L2/L3 Cache）来加速数据访问，但这也带来了缓存一致性问题。每个 CPU 核心有自己私有的缓存，当多个线程在不同核心上运行时，它们看到的共享变量值可能不一致。

```
┌─────────────────────────────────────────┐
│               Java 线程                   │
│   ┌──────────┐     ┌──────────┐          │
│   │ 线程 A    │     │ 线程 B    │          │
│   └────┬─────┘     └────┬─────┘          │
│        │                 │                │
│   ┌────▼─────┐     ┌────▼─────┐          │
│   │工作内存   │     │工作内存   │          │
│   │(本地缓存) │     │(本地缓存) │          │
│   └────┬─────┘     └────┬─────┘          │
│        │                 │                │
│        └────────┬────────┘                │
│                 │                         │
│          ┌──────▼──────┐                  │
│          │  主内存(Main)│                  │
│          └─────────────┘                  │
└─────────────────────────────────────────┘
```

JMM 规定了：
1. **所有变量存储在主内存**中
2. **每个线程有自己的工作内存**，保存了主内存中变量的副本
3. 线程对变量的操作必须在工作内存中进行，不能直接操作主内存
4. 不同线程之间无法直接访问对方的工作内存，**线程间通信必须通过主内存完成**

---

## 面试官：那 JMM 如何保证可见性？

### 可见性问题的根源

```java
// 这段代码可能永远不会停止！
public class VisibilityProblem {
    static boolean running = true;
    
    public static void main(String[] args) throws InterruptedException {
        new Thread(() -> {
            while (running) {
                // 循环等待
            }
            System.out.println("线程结束");
        }).start();
        
        Thread.sleep(1000);
        running = false;  // 主线程修改了 running
        System.out.println("主线程已修改 running = false");
    }
}
```

上述代码中，子线程可能永远看不到 `running = false` 的修改，因为它在自己的工作内存中缓存了 `running = true`。

**解决方案**：使用 `volatile` 关键字或 `synchronized` 来保证可见性。

### volatile 的可见性原理

`volatile` 关键字的本质是 **禁止编译器/运行时进行指令重排序**，并且对 volatile 变量的读写会强制同步到主内存：

```java
static volatile boolean running = true;  // volatile 保证可见性
```

**底层实现**：volatile 变量在编译后会增加 **Lock 前缀指令**，该指令在多核 CPU 下会触发：
1. 将当前核心的缓存行写回主内存
2. **缓存一致性协议（MESI）** 会使其他核心中缓存了该变量的缓存行失效
3. 其他线程读取时发现缓存失效，必须从主内存重新读取

---

## 面试官：能说说 happens-before 原则吗？

**happens-before** 是 JMM 中最核心的概念，它是判断数据是否存在竞争、线程是否安全的主要依据。

> 如果两个操作满足 happens-before 关系，那么第一个操作的结果对第二个操作是可见的，并且第一个操作的执行顺序在第二个操作之前。

### 8 大 happens-before 规则

| 序号 | 规则 | 说明 |
|------|------|------|
| 1 | **程序次序规则** | 同一个线程中，写在前面的操作 happens-before 后面的操作 |
| 2 | **监视器锁规则** | 对一个锁的解锁 happens-before 后续对这个锁的加锁 |
| 3 | **volatile 变量规则** | 对一个 volatile 变量的写 happens-before 后续对这个变量的读 |
| 4 | **传递性** | A happens-before B，B happens-before C => A happens-before C |
| 5 | **线程启动规则** | Thread.start() happens-before 该线程的每一个动作 |
| 6 | **线程终止规则** | 线程的所有操作 happens-before 其他线程检测到该线程终止 |
| 7 | **线程中断规则** | 调用 interrupt() happens-before 被中断线程检测到中断事件 |
| 8 | **对象终结规则** | 对象构造函数的结束 happens-before finalize() 的开始 |

### 规则应用示例

```java
// volatile 规则 + 传递性的应用
class VolatileExample {
    int a = 0;
    volatile boolean flag = false;
    
    public void writer() {
        a = 1;               // 1. 普通写
        flag = true;         // 2. volatile 写
    }
    
    public void reader() {
        if (flag) {          // 3. volatile 读
            int i = a;       // 4. 普通读 → 能读到 a = 1
        }
    }
}
```

根据 happens-before 规则：
- 1 happens-before 2（程序次序规则）
- 2 happens-before 3（volatile 变量规则）
- 3 happens-before 4（程序次序规则）
- **通过传递性：1 happens-before 4** → 所以 `a = 1` 对后续的读取可见 🎯

---

## 面试官：volatile 能保证原子性吗？

**不能。** volatile 只保证可见性和有序性，不保证原子性。

```java
public class VolatileNotAtomic {
    static volatile int count = 0;
    
    public static void main(String[] args) throws InterruptedException {
        for (int i = 0; i < 10; i++) {
            new Thread(() -> {
                for (int j = 0; j < 1000; j++) {
                    count++;  // 不是原子操作！
                }
            }).start();
        }
        Thread.sleep(2000);
        System.out.println("count = " + count);  // 经常 < 10000
    }
}
```

为什么 `count++` 不是原子操作？因为它实际分三步：
```
count++ = 读取 count → count + 1 → 写回 count
         (读)         (计算)       (写)
```

即使 volatile 保证了第一步读到最新值，但在「读」和「写」之间可能有其他线程插进来修改了 count。

**解决方案**：
- 使用 `synchronized`
- 使用 `AtomicInteger`（CAS 机制）

---

## 面试官：指令重排序是怎么回事？volatile 如何禁止？

### 指令重排序的类型

为了提高性能，编译器和 CPU 可能会对指令进行重排序，分为三类：

```
源代码
  ↓
编译器优化重排序（编译器级别）
  ↓
指令级并行重排序（CPU 级别）
  ↓
内存系统重排序（缓存/写缓冲区）
  ↓
最终执行指令序列
```

### 经典案例：双重检查锁（DCL）中的重排序问题

```java
// 错误的单例模式
class Singleton {
    private static Singleton instance;
    
    public static Singleton getInstance() {
        if (instance == null) {           // 第一次检查
            synchronized (Singleton.class) {
                if (instance == null) {   // 第二次检查
                    instance = new Singleton();  // 问题在这里！
                }
            }
        }
        return instance;
    }
}
```

`instance = new Singleton()` 并非原子操作，实际分为三步：

```
memory = allocate();      // 1. 分配内存空间
ctorInstance(memory);     // 2. 初始化对象
instance = memory;        // 3. 将引用指向内存地址
```

如果 2 和 3 被重排序，变为：

```
memory = allocate();      // 1. 分配内存空间
instance = memory;        // 3. 先赋值（此时对象尚未初始化！）
ctorInstance(memory);     // 2. 再初始化
```

此时另一个线程在「第一次检查」发现 `instance != null`，直接返回了一个**未初始化完成的对象**，后续使用就会出问题！

### 正确的 DCL：加 volatile

```java
class Singleton {
    private static volatile Singleton instance;  // volatile 禁止重排序
    
    public static Singleton getInstance() {
        if (instance == null) {
            synchronized (Singleton.class) {
                if (instance == null) {
                    instance = new Singleton();
                }
            }
        }
        return instance;
    }
}
```

volatile 会在赋值操作前后插入**内存屏障（Memory Barrier）**，禁止指令重排序。

---

## 面试官：内存屏障是什么？JMM 中如何实现？

### 内存屏障类型

JMM 中的内存屏障分为四类：

| 屏障类型 | 指令示例 | 作用 |
|----------|---------|------|
| **LoadLoad** | Load1; LoadLoad; Load2 | 确保 Load1 的读操作在 Load2 之前完成 |
| **StoreStore** | Store1; StoreStore; Store2 | 确保 Store1 的写操作对后续 Store2 可见 |
| **LoadStore** | Load1; LoadStore; Store2 | 确保 Load1 的读在 Store2 写之前完成 |
| **StoreLoad** | Store1; StoreLoad; Load2 | 确保 Store1 的写对后续 Load2 可见（最昂贵） |

### volatile 的内存屏障策略

JMM 为 volatile 制定了保守的内存屏障插入策略：

```
volatile 写操作前：插入 StoreStore 屏障
volatile 写操作后：插入 StoreLoad 屏障
volatile 读操作后：插入 LoadLoad + LoadStore 屏障
```

**synchronized 的实现**则依赖于操作系统的 **Monitor** 机制，在进入同步块时加锁并清空工作内存，退出同步块时将修改刷新到主内存。

---

## 面试官：JMM 和 JVM 内存区域有什么关系？

这是面试中常见的混淆点，一定要注意区分：

| 方面 | JMM（Java 内存模型） | JVM 内存区域（运行时数据区） |
|------|---------------------|--------------------------|
| **本质** | 抽象规范，定义线程与内存的交互规则 | JVM 运行时的具体内存划分 |
| **关注点** | 并发安全、可见性、有序性 | 对象分配、GC 回收、方法执行 |
| **核心内容** | 主内存 vs 工作内存 | 堆、栈、方法区、程序计数器等 |
| **解决的问题** | 多线程数据竞争 | 内存分配与回收 |
| **对应概念** | 抽象概念（对应 CPU 缓存 + 主存） | 具体的内存区域划分 |

简单来说：
- **JMM** 回答的是「多线程环境下，数据如何正确传递」
- **JVM 内存区域** 回答的是「数据在内存中怎么存放」

---

## 面试追问总结

| 问题 | 核心要点 |
|------|---------|
| volatile 和 synchronized 的区别？ | volatile 轻量级，只保证可见性/有序性；synchronized 重量级，保证原子性/可见性/有序性 |
| volatile 能替代锁吗？ | 不能。count++ 这种复合操作 volatile 无法保证原子性 |
| 为什么 JMM 需要 happens-before？ | 让程序员不用关心底层 CPU/编译器的细节，只关注逻辑正确性 |
| 什么是 as-if-serial？ | 单线程下重排序不影响执行结果，看起来像是串行执行 |
| final 在 JMM 中有特殊保证吗？ | final 字段在构造函数中正确初始化后，其他线程无需同步就能看到正确的值 |

---

## 总结

JMM 是 Java 并发编程的基石，理解 JMM 对于编写线程安全的代码至关重要。本文从可见性、有序性、原子性三个维度展开，深入分析了 volatile 原理、happens-before 规则、内存屏障以及指令重排序问题。

**一句话记住 JMM**：线程不能直接操作主内存，必须通过工作内存，工作内存之间的数据传递必须走主内存，而 happens-before 规则定义了哪些情况下工作内存的数据对另一个线程是可见的。

在下一篇文章中，我们将深入分析 ConcurrentHashMap 在 JDK 7 和 8 中的实现与演变，敬请期待！
