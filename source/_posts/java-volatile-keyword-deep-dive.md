---
title: 面试官：volatile 到底能保证什么？从 JMM 到可见性、有序性深度解析
date: 2026-08-04 08:00:00
tags:
  - Java
  - 并发
  - JMM
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 面试官：volatile 到底能保证什么？从 JMM 到可见性、有序性深度解析

## 面试官：先说说你对 volatile 的理解？

**候选人：** volatile 是 Java 提供的最轻量级的同步机制，它有两个核心语义：**保证可见性** 和 **禁止指令重排序**。但 volatile 不保证原子性，这是它和 synchronized 最本质的区别。

**面试官：** 好，那我们一层层往下挖。先说说"可见性"到底是怎么实现的？

## 一、可见性的本质：从 CPU 缓存到 JMM

### 1.1 问题从哪来？

先看一段经典代码：

```java
public class VisibilityDemo {
    private static boolean flag = false;

    public static void main(String[] args) throws InterruptedException {
        new Thread(() -> {
            while (!flag) {
                // 空转等待
            }
            System.out.println("flag 变为 true，线程退出");
        }).start();

        Thread.sleep(1000);
        flag = true;  // 主线程修改 flag
        System.out.println("主线程已将 flag 置为 true");
    }
}
```

这段代码在开启 JIT 优化后（`-server` 模式），**很可能永远不会退出**。为什么？

原因在于现代 CPU 的**多级缓存架构**：

| 层次 | 位置 | 访问耗时（约） |
|------|------|---------------|
| 寄存器 | CPU 内部 | 1 个时钟周期 |
| L1 Cache | CPU 内部 | 2~4 个时钟周期 |
| L2 Cache | CPU 内部 | 10~20 个时钟周期 |
| L3 Cache | 多核共享 | 20~60 个时钟周期 |
| 主内存 | 内存条 | 100+ 个时钟周期 |

每个 CPU 核心都有自己私有的 L1/L2 缓存。线程 1 在核心 A 上运行时，它读取 `flag` 的副本缓存在自己的缓存行里。主线程在核心 B 上修改 `flag = true`，这个修改先落在核心 B 的缓存里，**并不会立刻同步到核心 A 的缓存**。

更要命的是，JIT 编译器发现 `while (!flag)` 循环里 `flag` 没有被循环体修改，可能做**循环提升（Loop Hoisting）**优化，直接把 `flag` 的值缓存在寄存器里——这样连内存都不读了。

### 1.2 JMM（Java 内存模型）的抽象

JMM 是 Java 规范层面的内存模型，它屏蔽了不同 CPU 架构的差异，定义了线程与主内存之间的抽象关系：

- **主内存（Main Memory）**：所有变量（实例字段、静态字段、数组元素）都存储在主内存中
- **工作内存（Working Memory）**：每个线程有自己的工作内存，保存了变量的副本，线程对变量的所有操作都必须在工作内存中进行，不能直接读写主内存

线程、工作内存、主内存之间的关系：

```
线程A ──→ 工作内存A ──→┐
                       ├── 主内存
线程B ──→ 工作内存B ──→┘
```

JMM 的核心目标是：**定义一套规则，让多线程程序的执行结果与顺序执行的结果一致**，同时允许编译器和处理器进行合理的优化。

## 二、volatile 的三大语义

### 2.1 语义一：保证可见性

volatile 变量的读写有特殊语义：

- **写 volatile 变量**：JMM 会把该线程工作内存中这个变量的值**强制刷新回主内存**
- **读 volatile 变量**：JMM 会把主内存中该变量的值**重新加载到工作内存**

也就是说，volatile 变量的读写**必须直接与主内存交互**，绕过了"先更新工作内存副本、再择机同步"的默认行为。

修改后的代码：

```java
public class VisibilityDemo {
    private static volatile boolean flag = false;
    // ... 其余代码不变
}
```

加上 `volatile` 后，主线程写 `flag = true` 会立刻刷新到主内存；子线程每次循环判断 `!flag` 都会从主内存重新读取，循环就能正常退出了。

**在 x86 架构下，volatile 写是如何实现的？** 写 volatile 变量时，编译器会生成带有 `lock` 前缀的指令（或者用内存屏障）。`lock` 指令会触发**缓存一致性协议（MESI）**中的总线锁/缓存锁，让其他核心的缓存行失效，从而实现跨核心的可见性。

### 2.2 语义二：禁止指令重排序

**重排序的三种来源：**

1. **编译器优化**：在不改变单线程语义的前提下，编译器可以调整指令顺序
2. **CPU 指令级并行（ILP）**：CPU 可以对无依赖的指令乱序执行
3. **内存系统重排序**：写缓冲（Store Buffer）等硬件机制可能导致指令实际生效顺序不同

看这个经典的单例模式——双重检查锁（DCL）：

```java
public class Singleton {
    private static volatile Singleton instance;  // 关键：必须 volatile

    private Singleton() {}

    public static Singleton getInstance() {
        if (instance == null) {                    // 第一次检查
            synchronized (Singleton.class) {
                if (instance == null) {            // 第二次检查
                    instance = new Singleton();    // 问题点！
                }
            }
        }
        return instance;
    }
}
```

`instance = new Singleton()` 在字节码层面是三步操作：

```java
// 伪代码，对应字节码
memory = allocate();       // 1. 分配内存空间
ctorInstance(memory);      // 2. 调用构造函数初始化
instance = memory;         // 3. 将引用指向内存地址
```

如果没有 volatile，CPU/编译器可能把 2、3 两步重排序：

```java
memory = allocate();       // 1. 分配内存空间
instance = memory;         // 3. 先赋值引用（此时对象还没初始化！）
ctorInstance(memory);      // 2. 再调用构造函数
```

此时如果线程 A 执行完第 3 步（引用已赋值但对象未初始化），线程 B 第一次检查 `instance != null` 成立，直接返回，**拿到一个未初始化完成的对象**——这就是著名的 DCL 失效问题。加上 volatile 后，禁止了这种重排序，DCL 才真正安全。

**volatile 如何禁止重排序？——内存屏障（Memory Barrier）**

JMM 针对 volatile 制定了 happens-before 规则：**对一个 volatile 变量的写操作 happens-before 后续对它的读操作**。

在 x86 架构下，编译器会在 volatile 写之后插入 `StoreLoad` 屏障，在 volatile 读之后插入 `LoadLoad` 屏障等，确保屏障前后的指令不会跨越屏障重排。JDK 内部把这些抽象成了 `Unsafe.loadFence() / storeFence() / fullFence()`，LockSupport 的 `park/unpark` 也依赖了这些原语。

### 2.3 volatile 不保证原子性

看这个例子，多线程对 volatile 变量做自增：

```java
public class AtomicityDemo {
    private static volatile int count = 0;

    public static void main(String[] args) throws InterruptedException {
        for (int i = 0; i < 10; i++) {
            new Thread(() -> {
                for (int j = 0; j < 10000; j++) {
                    count++;   // 不是原子操作！
                }
            }).start();
        }
        // 等待所有线程结束
        Thread.sleep(3000);
        System.out.println("count = " + count);  // 结果大概率不是 100000
    }
}
```

`count++` 在字节码层面是**读-改-写**三步：

```java
GETSTATIC count   // 1. 读取 count 到栈顶
ICONST_1          // 2. 压入常量 1
IADD              // 3. 相加
PUTSTATIC count   // 4. 写回 count
```

虽然每一步都可见，但**三步之间可以被其他线程插入**。两个线程可能同时读到 `count = 10`，各自加 1 后都写回 11，于是丢了一次更新。这就是经典的**丢失更新（Lost Update）**问题。

**结论**：volatile 只保证"看到的是最新值"，不保证"读-改-写"的复合操作是原子的。

## 三、volatile 与 synchronized、Atomic 的对比

| 维度 | volatile | synchronized | Atomic 类 |
|------|----------|--------------|-----------|
| 可见性 | ✅ | ✅ | ✅（基于 volatile + CAS） |
| 原子性 | ❌ | ✅ | ✅（单变量 CAS） |
| 有序性 | ✅ 禁止重排序 | ✅ 加锁串行 | 部分（CAS 自带内存屏障） |
| 开销 | 最小（无锁） | 较大（锁竞争） | 较小（无锁自旋） |
| 适用场景 | 状态标志、单次写多线程读 | 复合操作、临界区 | 计数器、累加器 |
| 可重入 | — | ✅ | — |
| 阻塞 | 不阻塞 | 可能阻塞 | 不阻塞（自旋） |

**选型建议：**

- 只做**状态标志位**（如开关、初始化标记）→ volatile
- 需要**读-改-写复合操作**（计数、累加）→ Atomic 类
- 需要**多变量联合操作或复杂临界区** → synchronized / Lock

## 四、volatile 在 JDK 源码中的经典应用

### 4.1 AQS 中的 state

`AbstractQueuedSynchronizer` 的核心字段：

```java
private volatile int state;
```

`state` 表示同步状态（锁的持有数、信号量许可数等），用 volatile 保证可见性，配合 CAS（`compareAndSetState`）实现无锁状态更新。

### 4.2 单例模式的 DCL（前面已讲）

### 4.3 安全的发布：double-checked locking 之外

```java
public class SafePublisher {
    private volatile Map<String, Config> configCache;

    public void updateConfig(Map<String, Config> newCache) {
        this.configCache = newCache;  // volatile 写，安全发布
    }

    public Config getConfig(String key) {
        return configCache.get(key);  // volatile 读
    }
}
```

通过 volatile 引用的**安全发布**模式，避免了加锁，实现了"读多写少"场景下的高性能配置热更新。这也是 CopyOnWriteArrayList、ConcurrentHashMap 内部使用的发布技巧的简化版。

### 4.4 双重检查锁的现代替代：延迟初始化 Holder 模式

```java
public class LazyHolderSingleton {
    private LazyHolderSingleton() {}

    private static class Holder {
        static final LazyHolderSingleton INSTANCE = new LazyHolderSingleton();
    }

    public static LazyHolderSingleton getInstance() {
        return Holder.INSTANCE;  // 类加载机制保证线程安全
    }
}
```

利用 JVM 的类加载机制（类初始化有锁保护），比 DCL 更简洁，且**不需要 volatile**。这是目前推荐的写法。

## 五、volatile 与 64 位变量：long/double 的特殊性

Java 规范规定：**对非 volatile 的 long/double 变量的读写不保证原子性**。因为 64 位变量的读写可能被拆成两个 32 位操作（取决于 JVM 实现，32 位 JVM 上常见）。

```java
// 危险写法：非 volatile 的 long 可能读到"半个值"
private long timestamp;

// 安全写法
private volatile long timestamp;   // volatile 保证 64 位读写原子
```

加上 volatile 后，JMM 强制对 volatile long/double 的读写是原子的（64 位 JVM 上 x86 架构本身单条指令可完成，但规范层面需要 volatile 保证）。

## 六、面试官追问环节

### Q1：volatile 能保证有序性吗？它和 synchronized 的有序性有什么区别？

volatile 通过内存屏障禁止了**指令重排序**（保证 happens-before 关系），synchronized 通过**加锁串行执行**保证有序性。区别在于：volatile 是"轻量级有序性"，不阻塞线程；synchronized 会阻塞竞争线程。

### Q2：内存屏障有哪几种？volatile 用到了哪些？

常见四种：

| 屏障 | 含义 | volatile 场景 |
|------|------|--------------|
| LoadLoad | 屏障前读先于屏障后读 | volatile 读之后 |
| LoadStore | 屏障前读先于屏障后写 | volatile 读之后 |
| StoreStore | 屏障前写先于屏障后写 | volatile 写之前 |
| StoreLoad | 屏障前写先于屏障后读（最强，全屏障） | volatile 写之后 |

在 x86 强内存模型下，只有 volatile 写后的 StoreLoad 屏障是必需的（防止 volatile 写被后续读重排），其他屏障大多由硬件隐式保证。

### Q3：volatile 能替代 synchronized 吗？

不能。volatile 不保证原子性，只能用于"单写多读"或"状态标志"场景；任何需要复合操作、临界区互斥的场景都必须用锁或 Atomic 类。

### Q4：LongAdder 和 AtomicLong 怎么选？和 volatile 有什么关系？

高并发写场景选 LongAdder（分段累加，Cell 数组分散竞争，最后 sum 合并）；低并发或需要精确返回值选 AtomicLong。Atomic 类的内部值本身就是 volatile 字段，依赖 volatile 可见性 + CAS 原子更新。

### Q5：轻量级锁、偏向锁和 volatile 有关系吗？

没有直接关系。偏向锁/轻量级锁是 synchronized 的锁升级机制，volatile 是独立的内存语义机制。但两者的底层都涉及 CAS 和内存屏障。

## 七、总结：volatile 的适用场景清单

1. **状态标志**（布尔开关、初始化完成标记）
2. **单次写、多线程读**的配置/快照发布
3. **DCL 单例**中的实例引用
4. **保证 64 位变量读写原子性**（long/double）
5. **与 CAS 配合**实现无锁数据结构（AQS state、Atomic 类内部值）

**一句话总结**：volatile 是 Java 并发编程中最轻量级的同步原语，它用"直接读写主内存 + 内存屏障"换来了可见性与有序性，但**不承诺原子性**——理解了这一点，你就理解了 volatile 的全部价值与边界。
