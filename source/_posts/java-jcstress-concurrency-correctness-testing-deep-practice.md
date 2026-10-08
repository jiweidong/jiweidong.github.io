---
title: 【Java 并发】JCStress 并发正确性测试深度实战：@Actor 模型、JMM 可见性与冲突探测
date: 2026-10-08 08:10:00
tags:
  - Java
  - 并发编程
  - JCStress
  - JMM
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【Java 并发】JCStress 并发正确性测试深度实战：@Actor 模型、JMM 可见性与冲突探测

## 面试官：你的单例 DCL 写法，真的没有并发问题吗？

先看这段被封为教科书的代码：

```java
public class Singleton {
    private static volatile Singleton instance;   // 换成非 volatile 会怎样？

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

几乎所有面试题都会告诉你："**`volatile` 必须加，否则可能拿到半初始化对象**"。

但如果你想继续追问一句：**"你怎么证明它真的会出问题？或者证明加了 volatile 就真的没问题？"**

大多数人的答案是"书上都这么写"。而真正的高手会说：**"我用 JCStress 跑一百万次才信。"**

JCStress 是 OpenJDK 官方（Aleksey Shipilev 主导）的**并发正确性压力测试工具**，专门用来验证 JMM 层面的可见性、有序性、原子性问题。JSR 133 的很多结论、`VarHandle` 的语义、`StampedLock` 的 bug 复现，都是用它验出来的。

这篇文章从"为什么 JMH 不够用"开始，一路讲到怎么写、怎么读、怎么在生产代码上跑 JCStress。

---

## 一、为什么 JMH 和单元测试都不够

### 1.1 单元测试的盲区

```java
@Test
void testSingleton() {
    Singleton s1 = Singleton.getInstance();
    Singleton s2 = Singleton.getInstance();
    assertSame(s1, s2);   // ✅ 永远通过
}
```

单线程测试**根本不会触发数据竞争**。并发 Bug 的危险在于：

- **需要特定指令重排**才出现；
- **需要特定 CPU 缓存状态**（Store Buffer / Invalidate Queue）才出现；
- **需要特定内存对齐/伪共享**才出现；
- 出现概率可能是 1/1000000，但生产环境 QPS 10 万，一天必炸。

### 1.2 JMH 的定位

JMH 是**性能**测试工具：测吞吐、测延迟、测分配率。它不负责判定"结果是否正确"——你写个 `x++` 的基准，JMH 只会告诉你它跑得很快，不会告诉你它丢计数。

### 1.3 JCStress 的定位

JCStress 做三件事：

1. **生成大量交错执行的组合**（通过两个/多个 Actor 线程 + 不同的同步/栅栏策略）；
2. **记录每次执行的结果组合**（比如 (r1, r2) 的分布）；
3. **汇总成一张"结果直方图"**，并支持用 `@Outcome` 标注"哪些结果允许/禁止"。

```
  Observed state   Occurrences   Expectation   Description
  ---------------- -----------   -----------   -----------
  [0, 0]           8,745,321     ACCEPTABLE    Both actors see 0
  [1, 0]           3,102,443     ACCEPTABLE    ...
  [0, 1]           1,992,817     ACCEPTABLE
  [1, 1]              2,104     FORBIDDEN  ← 抓到 Bug！
```

看到一个 `FORBIDDEN` 出现哪怕只有 1 次，就说明你的代码语义被破坏了。

---

## 二、JCStress 的核心概念

### 2.1 依赖

```xml
<dependency>
  <groupId>org.openjdk.jcstress</groupId>
  <artifactId>jcstress-core</artifactId>
  <version>0.16</version>
  <scope>test</scope>
</dependency>
```

跑法：

```bash
# 直接运行 main（把 .java 编译进去）
java -jar jcstress.jar -t MyTest         # 只跑某个测试
java -jar jcstress.jar -m quick -v       # 快速模式 + 详细输出
java -c 4 -iters 100 -time 1000         # 并发度/迭代数/单次时长
```

### 2.2 注解全景

| 注解 | 作用 |
| --- | --- |
| `@JCStressTest` | 标记一个并发测试类 |
| `@State` | 被多个 Actor 共享的状态对象（字段就是被观测的变量） |
| `@Actor` | 一个并发执行体，返回值会被当作"观测结果" |
| `@Arbiter` | 在所有 Actor 完成后执行一次（用于最后校验，不计入并发） |
| `@Outcome` | 声明某个结果组合的期望：`id` / `expect` / `desc` |
| `@Result` | 对 Actor 返回值做匹配 |
| `@Description` | 测试描述（会打进报告） |
| `@JCStressTest(Mode.Termination)` | 终止性测试（验证阻塞/中断是否正确） |
| `@Stress` / `@Gracy`（`ic` 命令） | 用 `stress`/`gracy` 模式生成不同的栅栏与循环策略 |

其中 `@Actor` 的返回值很关键：**JCStress 会观察 Actor 返回的值，并把本次交错执行的所有返回值组合成一个"state"**。一个测试最多用两个 Actor（`@Actor` 出现两次），返回值组合就是结果元组。

### 2.3 运行模式（`@JCStressTest` 的 Mode）

- **`Mode.Continuous`（默认）**：Actor 无限循环，靠 JCStress 注入的内存栅栏/循环方式制造交错。
- **`Mode.Termination`**：每个 Actor 跑一次并必须"终止"（不能卡住），用于测试 `wait/notify`、`LockSupport`、`interrupt` 的语义。

`Continuous` 模式下，JCStress 会尝试多种"同步策略"（`stress`、`ic`、`acqrel`），分别代表"无栅栏"、"生产者-消费者顺序"、"Acquire-Release"，以此来发现仅靠硬件顺序假设才能通过的错误代码。

---

## 三、实战 1：验证 DCL + volatile

### 3.1 先造一个"不安全的 DCL"

```java
@JCStressTest
@Outcome(id = "0, 1", expect = Expect.ACCEPTABLE, desc = "未初始化完成")
@Outcome(id = "1, 1", expect = Expect.ACCEPTABLE, desc = "初始化完成且可见")
@Outcome(id = "1, 0", expect = Expect.FORBIDDEN,  desc = "❌ 看到非 null 但字段未初始化")
@State
public class UnsafeDclTest {

    // 被测试的"单例"
    static class Holder {
        int value;                    // 未加 final，也未用 volatile 发布
        Holder() {
            // 模拟耗时初始化；即使 value 在第 2 行赋值，
            // JIT 仍可能把构造中的写重排到引用发布之后
            value = 1;
        }
    }

    // 关键：非 volatile 的引用
    Holder instance;

    @Actor
    public void writer() {
        instance = new Holder();
    }

    @Actor
    public void reader(int[] result) {
        Holder h = instance;
        result[0] = (h == null) ? 0 : 1;
        result[1] = (h == null) ? 0 : h.value;
    }
}
```

注意 `@Actor` 的写法：可以返回 `int[]`（多值结果）或直接返回 `int`/`String` 等。上面的 `reader` 用输出参数 `int[] result` 是 JCStress 支持的另一种风格（`@Actor` 方法参数可以是 `int[]`、`long[]`、`Object[]` 等，作为结果缓冲；也可以用返回值）。

运行后会看到类似：

```
Observed state  Occurrences  Expectation
[0, 0]          42,331,201   ACCEPTABLE
[1, 0]             198,442   FORBIDDEN   ← 半初始化对象被看到
[1, 1]          18,220,913   ACCEPTABLE
```

> 注：在现代 x86 + 较新 JVM 上，因 `Holder` 构造函数很短、`value` 是常量折叠，这个具体例子不一定能稳定复现；要稳定复现，需要让构造函数变复杂（比如多个字段 + 循环）或使用 `-XX:-UseCompressedOops` 等环境差异。**这正是 JCStress 的价值：把"会不会发生"变成可测量。**

### 3.2 修复版本

```java
@State
public class SafeDclTest {
    static class Holder { int value = 1; }
    volatile Holder instance;          // ✅ volatile 禁止重排 + 保证可见性

    @Actor public void writer() { instance = new Holder(); }
    @Actor public void reader(int[] result) {
        Holder h = instance;
        result[0] = (h == null) ? 0 : 1;
        result[1] = (h == null) ? 0 : h.value;
    }
}
```

加上 `volatile` 后，`[1, 0]` 应该彻底消失：volatile 写之前的所有操作（构造函数的字段写）**不能重排到 volatile 写之后**（`happens-before` 语义），volatile 读之后能看到所有在 volatile 写之前发生的写。

### 3.3 更现代的写法：`VarHandle` + `release/acquire`

```java
private static final VarHandle INSTANCE;
static {
    try {
        INSTANCE = MethodHandles.lookup().findStaticVarHandle(
                SafeHolder.class, "instance", SafeHolder.class);
    } catch (ReflectiveOperationException e) { throw new ExceptionInInitializerError(e); }
}

@Actor
public static void writer() {
    INSTANCE.setRelease(new SafeHolder());   // Release 语义：写之前的操作不会后移
}

@Actor
public static void reader(int[] result) {
    SafeHolder h = (SafeHolder) INSTANCE.getAcquire();  // Acquire 语义
    ...
}
```

`setRelease/getAcquire` 比 `volatile` 的 `setVolatile/getVolatile` **弱**（不需要全局有序），在高频场景下性能更好，且足以保证"发布-订阅"的正确性。可以用 JCStress 验证二者都不允许 `[1, 0]`。

---

## 四、实战 2：复现"丢失更新"和"长篇化"

### 4.1 非原子自增的四种结果

```java
@JCStressTest
@Outcome(id = "1, 1", expect = Expect.ACCEPTABLE, desc = "两个线程都读到 0")
@Outcome(id = "1, 2", expect = Expect.ACCEPTABLE_INTERESTING, desc = "丢失更新")
@Outcome(id = "2, 1", expect = Expect.ACCEPTABLE_INTERESTING, desc = "丢失更新")
@Outcome(id = "2, 2", expect = Expect.FORBIDDEN, desc = "不可能：都需要读到 1")
@State
public class LostUpdateTest {
    int x;

    @Actor public void a() { x = 1; }
    @Actor public void b() { x = 2; }
}
```

这里 `ACCEPTABLE_INTERESTING` 很实用：表示"允许出现，但值得注意"。JCStress 报告里会把它单独标出来，方便 Review 的人一眼看到"数据竞争确实发生了"。

### 4.2 用 `@Arbiter` 做终态校验

`@Arbiter` 在所有 Actor 完成后执行一次，可以把"每轮最终状态"作为结果：

```java
@JCStressTest
@State
public class CounterTest {
    volatile int counter;

    @Actor public void actor1() { counter++; }
    @Actor public void actor2() { counter++; }

    @Arbiter
    public void arbiter(I_Result r) {
        // 因为 ++ 不是原子的，最终结果可能是 1 —— 丢失更新
        r.r1 = counter;
    }
}
```

跑出来如果 `r1 == 1` 有一定比例，就证明 `counter++` 确实丢更新。把 `counter` 换成 `AtomicInteger.incrementAndGet()` 后，`r1 == 2` 应该 100%。

### 4.3 验证"伪共享"和内存可见性延迟

JCStress 还能验证：

- **`volatile` 读的可见性延迟**：一个 Actor 写、另一个 Actor 循环读，观察"多久能看到新值"，配合 `@Actor` 返回迭代次数。
- **`final` 字段的"安全发布"语义**：`final` 字段在构造完成后对所有线程可见（JMM 保证），可以用 JCStress 验证 `final` 与普通字段的行为差异。
- **`String` 的 `externally-synchronized` 语义**。

---

## 五、实战 3：`Mode.Termination` 验证阻塞与中断

`Termination` 模式用来测试"某个操作最终一定会返回"或"某个操作在特定条件下会永久阻塞"。

### 5.1 验证 `wait` 会被 `notify` 唤醒

```java
@JCStressTest(Mode.Termination)
@Outcome(id = "TERMINATED", expect = Expect.ACCEPTABLE)
@Outcome(id = "STALE",      expect = Expect.FORBIDDEN)
@State
public class WaitNotifyTerminationTest {
    final Object lock = new Object();
    volatile boolean ready;

    @Actor
    public void waiter() throws InterruptedException {
        synchronized (lock) {
            while (!ready) {
                lock.wait();
            }
        }
    }

    @Signal
    public void signaler() {
        synchronized (lock) {
            ready = true;
            lock.notifyAll();
        }
    }
}
```

要点：

- `@Signal` 方法在 **waiter 进入阻塞后**才执行（JCStress 会检测到线程进入 `WAITING` 状态再触发 Signal），所以 `ready` 必须在 `signal` 里设置以避免丢失唤醒；
- 结果只有 `TERMINATED`（正常醒来）和 `STALE`（一直卡住）；
- **`wait` 必须放在 `while` 循环里**：即使 Signal 只设一次 `ready`，虚假唤醒也可能让 waiter 提前返回，用 while 重检才安全。

### 5.2 验证 `LockSupport.park` 的"丢失唤醒"

`park/unpark` 的经典陷阱：**`unpark` 先于 `park` 执行会丢信号**（许可被提前消费）。JCStress 的 `Termination` 模式 + `@Signal` 的顺序控制，是复现这类问题的理想工具。

---

## 六、怎么读 JCStress 报告

一份典型报告：

```
RESULT SAMPLES  OBSERVED   EXPECTATION   DESCRIPTION
---------------  -------  -----------  -----------
[0, 0]            8,104    ACCEPTABLE
[1, 1]           12,553    ACCEPTABLE
[1, 0]                3    FORBIDDEN    ❌ 看到非 null 但字段为 0
[0, 1]            4,102    ACCEPTABLE_INTERESTING
```

读报告的三个原则：

1. **`FORBIDDEN` 出现一次就够了** —— 说明语义被破坏，必须修；
2. **`ACCEPTABLE_INTERESTING` 是"信号"，不是"错误"** —— 它告诉你"数据竞争真实发生了"，可能对应性能问题（比如应该用 `setRelease` 而不是 `setVolatile`）；
3. **一个结果 0 次 ≠ 不可能** —— 可能只是当前硬件/JVM 没触发。要换 `-XX:+UnlockDiagnosticVMOptions`、换 CPU 架构、加 `ic`/`stress` 模式多跑几轮才能下结论。

**常见调参**：

```bash
java -jar jcstress.jar \
  -t com.example.SafeDclTest \
  -m quick \
  -iters 20 \
  -time 1000 \
  -jvmArgs "-XX:+UseSerialGC" \
  -v
```

| 参数 | 作用 |
| --- | --- |
| `-m quick\|default\|tough` | 运行模式，决定默认迭代次数/时长 |
| `-iters N` | 每个测试的迭代数 |
| `-time MS` | 每次迭代时长 |
| `-c N` | 并发线程数 |
| `-jvmArgs` | 传给被测 JVM 的参数（可以 `-XX:-UseCompressedOops` 制造更激进的乱序） |
| `-v` | 详细输出 |
| `-f` / `-r` | 输出/结果目录 |

---

## 七、什么代码值得用 JCStress 测

不是所有并发代码都值得上 JCStress。它最有价值的场景是**你无法通过阅读代码 100% 确定正确性**的地方：

| 场景 | 为什么值得测 |
| --- | --- |
| 自定义"无锁"数据结构 | 纯靠 volatile + CAS 手工编排，重排风险高 |
| `VarHandle` 的 `plain/opaque/acquire-release/volatile` 选型 | 语义差异细微，选错就是偶发 bug |
| DCL / 懒初始化 / 缓存发布 | 半初始化对象问题 |
| `wait/notify`、`park/unpark` 协议 | 丢失唤醒/虚假唤醒 |
| 自定义锁/屏障（AQS 扩展） | 状态机复杂，容易漏 happens-before |
| 伪共享优化（`@Contended`） | 验证优化后语义不变 |

**JCStress 不适合**：业务逻辑测试（用 JUnit）、性能测试（用 JMH）、压测（用 JMeter/Gatling）。三者分工清晰。

---

## 八、面试常见追问

**Q1：JCStress 和 JMH 的区别？**
JMH 测性能（吞吐/延迟），JCStress 测**语义正确性**（可见性/有序性/原子性）。JMH 假设代码逻辑正确；JCStress 假设性能不重要，只看结果组合。

**Q2：为什么 JCStress 要"无限循环" Actor？**
并发问题需要特定的交错时机。JCStress 通过多轮、多线程、多栅栏策略，把"低概率交错"放大到可观测。一次性执行（`Termination` 模式除外）几乎不可能复现。

**Q3：`@Outcome` 的 `ACCEPTABLE_INTERESTING` 有什么用？**
它把"合法但值得关注"的结果从"正常"里摘出来。比如数据竞争产生的"丢失更新"在语义上不是崩溃，但工程师需要知道它确实发生了，用于判断是否要升级同步强度。

**Q4：JCStress 报 `FORBIDDEN` 就一定是 Bug 吗？**
通常是的，但要先确认你的 `@Outcome` 语义写对了（比如 `@Actor` 的返回值顺序、`@Result` 的匹配规则）。也有"测试写错导致假阳性"的情况。

**Q5：现代 CPU（x86 TSO）下还用得着担心重排吗？**
用。① x86 只保证 **StoreStore 不重排**，Store-Load 仍可重排（Store Buffer），Load-Load/Load-Store 也有限制但并非全部；② **JIT 编译器重排不受硬件约束**（它按 JMM 优化）；③ **ARM 是弱内存模型**，重排空间更大，云上跑 ARM 实例时问题会更多。所以"x86 上没复现"不等于"没 Bug"。

**Q6：生产代码怎么引入 JCStress？**
把它作为 `test` 依赖，把关键并发组件（无锁队列、自定义锁、懒加载发布）单独抽成一个 `jcstress` 模块，CI 里跑 `-m quick`，本地/夜间跑 `-m tough`。⚠️ JCStress 会把 **CPU 跑满**，不要在开发机上长时间跑，也不要在共享构建机上跑 `tough` 模式。

---

## 九、总结

一张表收尾：

| 工具 | 关注点 | 输出 | 典型用途 |
| --- | --- | --- | --- |
| JUnit | 逻辑正确性 | 通过/失败 | 业务逻辑 |
| JMH | 性能 | 吞吐/延迟/分配 | 优化前后对比 |
| **JCStress** | **JMM 语义** | **结果直方图** | **并发原语/无锁结构/dcl** |
| async-profiler | 运行时画像 | 火焰图 | 线上排查 |

`volatile` 加不加、`VarHandle` 用哪个模式、`while` 循环要不要写——这些问题在 JCStress 面前没有"信仰"，只有"数据"。**能跑出 `[1, 0]` 的代码，不管理论上多漂亮，都是错的；跑不出来的代码，才配进核心链路。**

下次面试官问你"DCL 为什么加 volatile"，你可以顺手补一句："我用 JCStress 验证过 `[1, 0]` 被禁止，默认模式跑 20 轮没有 FORBIDDEN。"

这一句，比背十遍《Java 并发编程实战》都管用。
