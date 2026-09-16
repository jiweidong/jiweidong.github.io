---
title: 【Java 24 新特性】Stream Gatherers 深度解析：从内置 gatherer 到自定义中间操作的完整实现
date: 2026-09-16 08:00:00
tags:
  - Java
  - Stream
  - Java 24
  - 函数式编程
categories:
  - Java
  - Java 新特性
author: 东哥
---

# 【Java 24 新特性】Stream Gatherers 深度解析：从内置 gatherer 到自定义中间操作的完整实现

## 面试官：Stream 的中间操作只有 map/filter/flatMap，如果我要做"滑动窗口聚合"，你怎么办？

这是一个非常经典的"能力边界"问题。

在 JDK 24 之前，标准答案通常有三种，而且都不体面：

1. **用 `collect` 兜底**：把整个流物化成一个 `List`，再用循环做窗口切分。问题是——流式语义没了，内存占用从 O(1) 变成 O(n)，遇到无限流直接卡死。
2. **自己写 `Spliterator`**：可行，但要同时处理串行、并行、`tryAdvance`/`forEachRemaining`、`characteristics` 四个维度，代码量巨大且极易踩坑。
3. **上第三方库（如 StreamEx、protonpack）**：能用，但引入了额外依赖，团队里还得统一认知。

JDK 22 引入预览、JDK 24 正式转正的 **Stream Gatherers（JEP 461 → JEP 473 → JEP 485）** 就是为了填这个坑：它给 `Stream` 打开了"自定义中间操作"的扩展点。

这篇文章我们从 API 模型讲到源码实现思路，再到生产级自定义 Gatherer，把它一次性讲透。

---

## 一、为什么现有中间操作不够用

先明确一个事实：`Stream` 的中间操作是**封闭集合**。`java.util.stream.Stream` 接口上能用的中间操作，就是 `filter`/`map`/`flatMap`/`distinct`/`sorted`/`peek`/`limit`/`skip`/`takeWhile`/`dropWhile` 这些。

它们的共同特点是：**每次处理一个元素，输出 0 或 1 个（或扁平化后的若干个）元素，且不依赖"跨元素的累积状态"**（`sorted`、`distinct` 是有状态的，但语义被写死在 JDK 里）。

于是下面这些需求就都成了"表达力盲区"：

| 需求 | 用现有算子的困境 |
| --- | --- |
| 每 3 个元素打成一个 `List` 窗口 | `flatMap` 无法"收集后再吐出"，只能靠外部缓存 |
| 滑动窗口（步长 1）取均值 | 需要跨元素状态 + 顺序保证 |
| 去重但只保留每个 key 的第一个 | `distinct` 只支持 `equals` 全等去重 |
| 折叠成单个结果（如拼接） | `reduce` 能做到一部分，但无法中途短路/无法作为中间操作继续接流 |
| 按"空闲超时"切分批次 | 需要同时感知元素内容与外部时间 |
| 并发抓取但限制并发度 | 只能用 `CompletableFuture` 手写编排 |

**Gatherer 的本质：把"有状态、可短路、可并行、可自定义"的中间操作变成一个可插拔的接口。**

---

## 二、Gatherer 的核心模型

`Gatherer<T, A, R>` 是一个泛型接口，三个类型参数：

- `T`：输入元素类型
- `A`：**可变状态**类型（accumulator，内部私有状态）
- `R`：输出元素类型

它由四个函数式组件构成，可以理解为"一个带状态机的 push 式转换器"：

```java
public interface Gatherer<T, A, R> {

    // 1. 初始化：为每条流（每个任务）创建一份独立状态
    default Supplier<A> initializer() { return () -> null; }

    // 2. 核心：每次来一个元素就调用一次，返回是否还能继续接收
    Integrator<A, T, R> integrator();

    // 3. 并行合并：把两个状态合并为一个（并行流必需）
    default BinaryOperator<A> combiner() { return (a1, a2) -> a1; }

    // 4. 收尾：流结束后，把残余状态吐出去
    default BiConsumer<A, Downstream<? super R>> finisher() { return (a, d) -> {}; }

    interface Integrator<A, T, R> {
        boolean integrate(A state, T element, Downstream<? super R> downstream);
    }

    interface Downstream<R> {
        boolean push(R element);  // 返回 false 表示下游已饱和/已短路
        boolean isRejecting();    // 下游是否已拒绝更多元素
    }
}
```

### 2.1 关键语义一：`initializer` 是"每任务一份"

这是最容易踩坑的地方。`A` 不是全局单例，而是**每条流的每个并行分支各持有一份**。

- 串行流：只有一份状态。
- 并行流：多个任务并行处理各自分片，每个任务一份状态。

所以自定义状态**不需要加锁**，但必须保证 `combiner` 能在最后正确合并——否则并行结果就是错的。

### 2.2 关键语义二：`integrate` 的返回值决定"还能不能喂"

```java
// 返回 true  = 我还能继续接收元素
// 返回 false = 不要再给我元素了（短路）
```

这就是 Gatherer 支持**惰性/短路**的机制。比如 `Gatherers.limit(3)` 语义的 Gatherer，在 push 完第 3 个元素后直接返回 `false`，上游就不会再产生元素——配合无限流（`Stream.iterate`）也安全。

### 2.3 关键语义三：`finisher` 是"排空残留"

滑动窗口这类操作，最后几个元素还留在状态里没输出，必须靠 `finisher` 吐出去。忘了写 `finisher` 是自定义 Gatherer 的头号 Bug 来源。

---

## 三、内置的四个 Gatherers

JDK 在 `java.util.stream.Gatherers` 里提供了四个开箱即用的实现（Java 24 起为标准 API）：

### 3.1 `windowFixed(n)`：固定窗口，不重叠

```java
List<List<Integer>> r = Stream.of(1, 2, 3, 4, 5, 6, 7)
        .gather(Gatherers.windowFixed(3))
        .toList();
// [[1,2,3], [4,5,6], [7]]   —— 最后不足 n 个也会输出
```

典型场景：**分页式批量处理**、把大流切成固定大小批次再批量入库。

### 3.2 `windowSliding(n)`：滑动窗口，步长 1

```java
List<List<Integer>> r = Stream.of(1, 2, 3, 4, 5)
        .gather(Gatherers.windowSliding(3))
        .toList();
// [[1,2,3], [2,3,4], [3,4,5]]
```

典型场景：**移动平均线**、滑动窗口内的异常检测、计算相邻 N 项的相关性。

### 3.3 `fold(seed, folder)`：增量折叠（reduce 的"中间操作版"）

```java
String s = Stream.of("a", "b", "c")
        .gather(Gatherers.fold(() -> "", (acc, e) -> acc + e))
        .findFirst()
        .orElse("");
// "abc"
```

和 `reduce` 的区别很微妙：`fold` 会**把每一步中间结果都 push 到下游**，然后你用自己的算子挑一个（比如 `findFirst` 取最终值、`collect` 取中间快照）。

```java
// 拿到每一步的累积值 —— reduce 做不到
Stream.of(1, 2, 3, 4)
      .gather(Gatherers.fold(() -> 0, Integer::sum))
      .toList(); // [1, 3, 6, 10]
```

这个特性在**计算累计指标（如累计 GMV、累计 UV 曲线）**时非常好用。

### 3.4 `mapConcurrent(n, fn)`：限并发的虚拟线程映射

```java
List<String> bodies = urls.stream()
        .gather(Gatherers.mapConcurrent(8, this::fetch))
        .toList();
```

这是 JDK 24 里比较惊艳的一个：它在**平台线程/虚拟线程**上并发执行 `fn`，并把并发度限制在 `n`，同时**保持输出顺序与输入顺序一致**。

放在 Java 21+ 的虚拟线程背景下，这意味着：

> 以前要写 `CompletableFuture + Semaphore + 结果排序` 才能实现的"限并发保序并发调用"，现在一行 `.gather(mapConcurrent(8, fn))` 搞定。

而且它正是"用 Gatherer 实现"的绝佳教学案例：并行度用 Gatherer 的状态管理，保序用状态里的队列缓冲。

---

## 四、Gatherer vs Collector：别搞混

这是面试高频追问。两者名字像，定位完全不同：

| 维度 | `Collector` | `Gatherer` |
| --- | --- | --- |
| 位置 | **终止操作**（`collect`） | **中间操作**（`gather`） |
| 输入/输出 | 流 → 单个结果容器 | 流 → **流** |
| 能否继续接算子 | 不能 | 能（`gather(...).filter(...).gather(...)`） |
| 惰性 | 否（必须消费完整流） | **是**（支持短路、支持无限流） |
| 并行模型 | `combiner` 合并容器 | `combiner` 合并状态 + 下游 push 语义 |
| 典型用途 | 分组、一次聚合、生成 Map | 窗口、去重、限流、批处理、状态转换 |

一句话总结：**Collector 是"聚合成结果"，Gatherer 是"流到流的可插拔变换器"。**

---

## 五、手写自定义 Gatherer（生产级示例）

### 5.1 示例一：按 key 去重（只保留首次出现）

```java
public class DistinctByKey<T, K> implements Gatherer<T, Set<K>, T> {

    private final Function<T, K> keyFn;

    public DistinctByKey(Function<T, K> keyFn) {
        this.keyFn = keyFn;
    }

    @Override
    public Supplier<Set<K>> initializer() {
        return HashSet::new;   // 每个并行任务一份，无需加锁
    }

    @Override
    public Integrator<Set<K>, T, T> integrator() {
        return (seen, element, downstream) -> {
            if (seen.add(keyFn.apply(element))) {
                return downstream.push(element);  // 首次出现，放行
            }
            return true;                          // 重复元素，丢弃但继续收
        };
    }

    @Override
    public BinaryOperator<Set<K>> combiner() {
        return (a, b) -> { a.addAll(b); return a; };  // 并行时合并去重集
    }
}
```

使用：

```java
List<Order> latest = orders.stream()
        .gather(new DistinctByKey<>(Order::getUserId))
        .toList();
```

注意几个工程细节：

- `combiner` 里 `a.addAll(b)` 的合并**不保证跨分片顺序**，所以"首次出现"的语义在**并行流下不严格成立**。想要严格保序，就得加 `.sequential()`，或者在 `combiner` 里维护顺序信息。这是自定义 Gatherer 时最容易忽略的语义陷阱。
- 状态用 `HashSet` 会导致内存随流长度线性增长。如果流可能是无限的，必须配合 `limit` 或改用布隆过滤器思路。

### 5.2 示例二：按"时间间隔"切分批次（超时切分）

```java
public class BatchByGap<T> implements Gatherer<T, BatchByGap.State<T>, List<T>> {

    static class State<T> {
        List<T> batch = new ArrayList<>();
        long lastTs = Long.MIN_VALUE;
    }

    private final ToLongFunction<T> tsFn;
    private final long gapMillis;
    private final int maxBatch;

    // 构造略

    @Override
    public Supplier<State<T>> initializer() { return State::new; }

    @Override
    public Integrator<State<T>, T, List<T>> integrator() {
        return (st, element, downstream) -> {
            long ts = tsFn.applyAsLong(element);
            boolean gap = st.lastTs != Long.MIN_VALUE && ts - st.lastTs > gapMillis;
            if (gap || st.batch.size() >= maxBatch) {
                if (!downstream.push(new ArrayList<>(st.batch))) {
                    return false;          // 下游不要了，短路
                }
                st.batch.clear();
            }
            st.batch.add(element);
            st.lastTs = ts;
            return true;
        };
    }

    @Override
    public BiConsumer<State<T>, Downstream<? super List<T>>> finisher() {
        return (st, downstream) -> {
            if (!st.batch.isEmpty()) {
                downstream.push(new ArrayList<>(st.batch));  // 别忘了最后一批
            }
        };
    }
}
```

这个模式在**日志聚合、埋点批量上报、物联网数据分段**场景非常实用：既要控制单批大小（防 OOM），又要按空闲间隔切段（保证语义边界）。

### 5.3 示例三：带背压的限并发映射（理解 `mapConcurrent` 的骨架）

```java
public class ConcurrentMapGatherer<T, R> implements Gatherer<T, Object, R> {
    // 简化骨架：虚拟线程池 + 有界队列 + 按序回收
    // 状态里维护 (序号 -> Future) 的有序 Map
    // integrate 时提交任务，当队列达到并发上限就阻塞等待最老的完成并按序 push
    // finisher 时按序排空剩余任务
}
```

核心思想有三点，值得面试时讲：

1. **并发度 = 状态里"在途任务数"上限**，不是线程池大小；
2. **保序 = 序号索引 + 有序缓冲**，任务完成顺序与输出顺序解耦；
3. **背压 = `integrate` 返回前主动等待**，而不是无界提交导致内存膨胀。

---

## 六、并行语义与源码视角

`Stream.gather(gatherer)` 在实现层面会：

1. 校验 gatherer 非空；
2. 构造一个**有状态的中间操作节点**（类似 `GathererOp`），把上游流 + `integrator`/`finisher` 包装成一个新的 `Stream`；
3. 串行执行时，单状态顺序调用 `integrate`，结束后调 `finisher`；
4. 并行执行时，按上游分片切出多个任务，**每个任务独立 `initializer()`**，各自 `integrate`，最后用 `combiner` 逐层合并，再 `finisher`。

几个必须记住的结论：

- **`initializer` 必须能安全地被多次调用**（并行时调用次数 > 1）。
- **`combiner` 不写或写错，并行结果必错。**有状态 Gatherer 在并行流下的正确性，取决于 `combiner` 是否满足结合律。
- **短路传播**：`downstream.push(...)` 返回 `false`（下游已饱和）时，`integrate` 应尽快返回 `false` 让上游停止。
- **`gather` 不会改变流的有序性特征**，但如果 Gatherer 本身按到达顺序处理，并行下到达顺序就是不确定的。

---

## 七、性能与踩坑清单

| 坑 | 表现 | 规避方式 |
| --- | --- | --- |
| 忘记 `finisher` | 尾部数据丢失，结果数量对不上 | 单元测试断言元素总数 |
| 并行下状态未合并 | 结果随并发度变化、偶发错误 | 实现 `combiner` 或强制 `sequential()` |
| 有状态 + 无限流 | 内存持续增长直到 OOM | 保证短路 / 加 `limit` / 用有界状态 |
| `gather` 内做阻塞 IO | 占用 ForkJoin 公共池线程，拖慢全局 | 用 `mapConcurrent` 或虚拟线程专用池 |
| 过度使用 Gatherer | 可读性下降，调试困难 | 能用内置算子表达就别自定义 |
| 与 `peek` 混淆 | 误以为 `peek` 能改状态 | `peek` 语义无保证，改状态用 `map`/`gather` |

另外还有一个性能层面的判断题：**Gatherer 并不"更快"，它只是"更可表达"。** 对已有算子能解决的需求，自研 Gatherer 往往因为状态管理而更慢。它的价值在于把"没法流式表达的逻辑"变成流式的，从而避免全量物化——**赢的是内存和延迟，不是单元素吞吐**。

---

## 八、面试常见追问

**Q1：Gatherer 和 `flatMap` 的区别是什么？**

`flatMap` 是"1 进 n 出、无跨元素状态"的特例；Gatherer 是"1 进 0~n 出 + 跨元素状态 + 短路 + 并行合并"的通用模型。任何 `flatMap` 能表达的都能用 Gatherer 表达（`integrator` 里直接 push），反之不成立。

**Q2：为什么 `mapConcurrent` 能做到保序？**

因为它把"任务提交顺序"和"结果输出顺序"解耦了：状态里维护一个序号递增的缓冲队列，只有当队首任务完成时才 push，否则先把已完成的结果暂存。这就是经典的**有序并发管道（ordered pipeline）**模式。

**Q3：`Gatherer` 能用在 `parallelStream()` 上吗？**

能，但有条件：必须正确实现 `combiner`，且逻辑本身满足结合律。像"按 key 去重保序"这种**依赖全局顺序**的语义，在并行下天然不成立，应显式改串行。

**Q4：它和 Reactor/`Flux` 的算子有什么区别？**

Reactor 的算子体系（`buffer`/`window`/`concatMap`）在表达力上早就覆盖了 Gatherer 的场景，并且原生支持背压与异步。Gatherer 的意义是**把这种能力带回 JDK 标准库**，让不引入响应式栈的项目也能拥有可扩展的流式变换，而不必替换整个编程模型。选型上：同步数据处理用 Gatherer，异步/流式/背压敏感场景仍是 Reactor 的主场。

---

## 九、小结

把这篇的核心结论压缩成一张表：

| 要点 | 结论 |
| --- | --- |
| 引入版本 | JDK 22 预览（JEP 461）→ JDK 23 二次预览（JEP 473）→ **JDK 24 正式转正（JEP 485）** |
| 本质 | 可自定义、有状态、可短路、可并行的**中间操作** |
| 四大组件 | `initializer` / `integrator` / `combiner` / `finisher` |
| 内置能力 | `windowFixed` / `windowSliding` / `fold` / `mapConcurrent` |
| 与 Collector 的边界 | Collector 终止聚合成结果；Gatherer 中间变换继续接流 |
| 最大收益 | 把"必须物化整个集合"的逻辑变成 O(1) 状态的流式处理 |
| 最大风险 | 并行 `combiner` 语义缺失、`finisher` 遗漏、无限流状态膨胀 |

Stream Gatherers 不是一个"更炫的语法糖"，而是 Stream API 十年来第一次真正的**扩展性开放**。它让 Java 的函数式流水线终于从"只能拼 JDK 给好的乐高"进化成了"可以自己造零件"——这才是它在 Java 24 里值得单独占一个 JEP 的原因。
