---
title: 【面试必备】Java Atomic 原子类深度解析：从 CAS 原理到 LongAdder 的性能演进
date: 2026-07-05 08:00:00
tags:
  - Java
  - 并发
  - 面试
  - JUC
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】Java Atomic 原子类深度解析：从 CAS 原理到 LongAdder 的性能演进

## 一、开篇：为什么需要原子类？

在多线程并发场景下，对共享变量的操作（如 `count++`）并非原子操作。它实际上分为三步：读取 → 修改 → 写入。传统的 `synchronized` 或 `Lock` 虽然能保证线程安全，但带来了上下文切换的开销。

Java 从 JDK 1.5 开始提供了 `java.util.concurrent.atomic` 包，基于 **CAS（Compare-And-Swap）** 乐观锁机制，实现了无锁的线程安全操作，性能远优于锁方案。

**面试官常见开场白**："说说你对 JUC 中 Atomic 原子类的理解？它们和锁相比有什么区别？"

## 二、原子类体系总览

JUC 原子类可以划分为四大类：

| 类别 | 代表类 | 适用场景 |
|------|--------|----------|
| **基本类型原子类** | AtomicInteger, AtomicLong, AtomicBoolean | 对单个数值/布尔变量的原子操作 |
| **引用类型原子类** | AtomicReference, AtomicStampedReference, AtomicMarkableReference | 对对象引用进行原子更新，解决 ABA 问题 |
| **数组原子类** | AtomicIntegerArray, AtomicLongArray, AtomicReferenceArray | 对数组中的元素进行原子更新 |
| **字段/属性原子类** | AtomicIntegerFieldUpdater, AtomicReferenceFieldUpdater | 对对象的 volatile 字段进行原子更新 |
| **高性能累加器** | LongAdder, LongAccumulator, DoubleAdder, DoubleAccumulator | 高并发下的计数/累加场景（JDK 8+） |

## 三、核心基石：CAS 算法详解

### 3.1 CAS 是什么？

CAS（Compare-And-Swap）是一条 CPU 级别的原子指令，包含三个操作数：

```
CAS(V, Expected, NewValue)
```

- **V**：内存地址（要更新的变量）
- **Expected**：预期值（期望 V 当前的值）
- **NewValue**：新值

执行逻辑：只有当 V 当前的值等于 Expected 时，才将 V 更新为 NewValue，否则不更新。整个过程是原子的。

### 3.2 源码级分析：AtomicInteger.incrementAndGet()

```java
// JVM 运行时保证
private static final Unsafe U = Unsafe.getUnsafe();
private static final long VALUE = U.objectFieldOffset(
    AtomicInteger.class.getDeclaredField("value"));
private volatile int value;

public final int incrementAndGet() {
    return U.getAndAddInt(this, VALUE, 1) + 1;
}
```

核心是 `Unsafe.getAndAddInt`：

```java
// Unsafe.class (JDK 8 实现)
public final int getAndAddInt(Object o, long offset, int delta) {
    int v;
    do {
        v = getIntVolatile(o, offset);      // 1. 读取当前值
    } while (!compareAndSwapInt(o, offset, v, v + delta)); // 2. CAS 自旋
    return v;
}
```

**自旋 CAS 的流程图**：

```
读取 V 当前值 → 计算新值 → CAS(V, 当前值, 新值)
                               ├── 成功 ✓ → 返回
                               └── 失败 ✗ → 重新读取 → 重试
```

### 3.3 CAS 的三大问题

**问题一：ABA 问题**

假设线程 T1 读到 V=1，准备 CAS(1,2)。此时 T2 将 V 改为 1→2→1，T1 执行 CAS 时发现 V 仍为 1，更新成功——但中间状态被忽略了。

✅ **解决方案**：使用 `AtomicStampedReference`（带版本号）或 `AtomicMarkableReference`（带布尔标记）：

```java
AtomicStampedReference<Integer> ref = new AtomicStampedReference<>(1, 0);
// 使用时传入 expectedStamp 和 newStamp
boolean ok = ref.compareAndSet(expected, newValue, expectedStamp, newStamp);
```

**问题二：自旋开销（CPU 空转）**

高竞争下 CAS 不断失败重试，浪费 CPU。`LongAdder` 通过分段思想缓解此问题。

**问题三：只能保证单个变量的原子性**

多个变量需要原子操作时，使用 `AtomicReference` 包装对象，或使用锁。

## 四、AtomicReference 与 ABA 解决方案

```java
public class AtomicReferenceDemo {
    static AtomicReference<String> ref = new AtomicReference<>("A");
    
    public static void main(String[] args) {
        // 基本 CAS 操作
        ref.compareAndSet("A", "B");
        System.out.println(ref.get()); // B
    }
}
```

**带版本号的 ABA 解决示例**：

```java
AtomicStampedReference<String> ref = new AtomicStampedReference<>("A", 0);
int[] stampHolder = new int[1];
String value = ref.get(stampHolder);  // "A", stamp=0
// CAS + 版本号
boolean ok = ref.compareAndSet("A", "B", stampHolder[0], stampHolder[0] + 1);
```

## 五、LongAdder：高并发下的性能王者

### 5.1 为什么需要 LongAdder？

在高并发场景下，大量线程同时 CAS 同一个 AtomicLong 变量，会导致大量自旋失败，CPU 利用率飙升。

| 指标 | AtomicLong | LongAdder |
|------|-----------|-----------|
| 原理 | 单变量 CAS 自旋 | 分段累加 + 最终求和 |
| 低并发性能 | ★★★★★ | ★★★★ |
| 高并发性能 | ★★★ | ★★★★★ |
| 内存开销 | 小（一个 long） | 较大（base + Cell 数组） |
| 适用场景 | 低竞争计数、自增 ID | 高并发统计、监控指标 |

### 5.2 LongAdder 的核心原理

**核心思想：空间换时间，通过分段降低 CAS 冲突。**

```
LongAdder
├── base（基础值，低竞争时使用）
├── Cell[]（分段数组，高竞争时分散线程到不同 Cell）
│   ├── Cell[0] ← thread1, thread2, thread3
│   ├── Cell[1] ← thread4, thread5
│   └── Cell[2] ← thread6
└── sum() = base + Σ Cell[i]
```

**源码核心流程**（简化版）：

```java
// LongAdder.add(long x) 的核心逻辑
public void add(long x) {
    Cell[] cs = cells;
    if (cs == null) {
        // 1. 先尝试 CAS base
        if (casBase(base, base + x))
            return;
    }
    // 2. base CAS 失败 → 进入 cells 分段累加
    // 通过 hash 决定落到哪个 Cell
    // 如果对应 Cell 为 null 则创建，否则 CAS 更新
    // 3. CAS 仍失败 → 扩容 cells 或重试
}
```

**注意**：`LongAdder.sum()` 在并发下不是精确值，但最终一致性对统计场景足够了。如果需要强一致性，调用 `sum()` 后加同步，或使用 `AtomicLong`。

### 5.3 实战对比

```java
// 使用 AtomicLong
AtomicLong atomicCount = new AtomicLong(0);
// 40 线程各累加 10 万次 → 约 150ms

// 使用 LongAdder
LongAdder adderCount = new LongAdder();
// 40 线程各累加 10 万次 → 约 30ms（5倍提升）
```

## 六、AtomicIntegerFieldUpdater：零侵入地让普通字段原子化

当你无法修改类的源码时（比如第三方库），可以用 Updater 让已有类的 `volatile` 字段支持原子操作：

```java
public class GamePlayer {
    volatile int score;  // 必须是 volatile
}

AtomicIntegerFieldUpdater<GamePlayer> updater = 
    AtomicIntegerFieldUpdater.newUpdater(GamePlayer.class, "score");

GamePlayer player = new GamePlayer();
updater.incrementAndGet(player);  // score + 1
```

**使用限制**：
- 字段必须是 `volatile` 修饰
- 字段不能是 `static` 或 `final`
- 必须使用 `public` 或同包可见（取决于调用包）

## 七、面试高频追问

### Q1：AtomicInteger 的底层实现是什么？

> 基于 Unsafe 的 CAS 指令，利用 CPU 的 cmpxchg 指令实现原子比较和交换。通过自旋（do-while）保证在竞争时不断重试直到成功。

### Q2：LongAdder 比 AtomicLong 快多少？为什么？

> 高竞争场景下可实现数倍到数十倍的性能提升。核心原因是 LongAdder 将单点 CAS 冲突分散到多个 Cell 上，大大降低了自旋失败率。

### Q3：什么场景不适合用 LongAdder？

> 需要强一致性的精确计数（如分布式 ID 生成）用 AtomicLong；需要大量求和统计的场景（如 QPS 计数、监控指标）用 LongAdder。

### Q4：AtomicStampedReference 和 AtomicMarkableReference 有什么区别？

> `AtomicStampedReference` 使用 int 版本号，可以精确记录修改次数；`AtomicMarkableReference` 使用 boolean 标记，只关心是否被修改过（适合 A→B→A 只需知道 A 被改过，不关心次数）。

### Q5：JDK 8 中新增了哪几个原子类？

> `LongAdder`、`LongAccumulator`、`DoubleAdder`、`DoubleAccumulator`。其中 `Accumulator` 比 `Adder` 更通用，支持自定义运算函数。

## 八、总结

| 场景 | 推荐方案 |
|------|---------|
| 单变量低并发计数 | AtomicInteger / AtomicLong |
| 高并发统计计数 | LongAdder / LongAccumulator |
| 对象引用原子更新 | AtomicReference |
| 引用更新 + ABA 防范 | AtomicStampedReference |
| 无法修改类源码时 | AtomicIntegerFieldUpdater |
| 数组元素原子更新 | AtomicIntegerArray |

原子类是 JUC 的基石，理解 CAS 原理和分段思想，再遇到并发计数场景就不会只想到 `synchronized` 了。从 AtomicLong 到 LongAdder 的演进，也是整个并发编程从"单点 CAS"到"分段无锁"思想演进的缩影。
