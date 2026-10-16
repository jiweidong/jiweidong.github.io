---
title: 【Java 底层】Spliterator 深度解析：分割迭代器原理、trySplit 与自定义 Stream 源
date: 2026-10-15 08:05:00
tags:
  - Java
  - Stream
  - Spliterator
  - 集合
  - 并发
categories:
  - Java 进阶
author: 东哥
---

# 【Java 底层】Spliterator 深度解析：分割迭代器原理、trySplit 与自定义 Stream 源

## 前言

你写 `list.stream().filter(...).collect(...)` 的时候，数据是怎么"流"进管道里的？答案不是 `Iterator`，而是 **`Spliterator`（Splitable Iterator，可分割迭代器）**。

`Spliterator` 是 Java 8 为并行流引入的核心抽象：它不仅要能**逐个遍历**元素，还要能**把自己一分为二**，从而让 `ForkJoinPool` 把数据切成多段并行处理。理解它，你才能解释三个高频困惑：

1. 为什么 `parallelStream()` 有时候快、有时候更慢？
2. 为什么 `ArrayList` 的并行流很快，`LinkedList` 的并行流很慢？
3. 为什么 `Stream.iterate` 的并行流几乎没加速，而 `IntStream.range` 可以？

本文从接口契约讲到 JDK 内置实现，最后手写一个自定义 `Spliterator`（分页拉取数据库），把"分割质量"这个隐藏变量彻底讲透。

## 一、Spliterator 是什么

`Iterator` 只解决"顺序取下一个"，`Spliterator` 则同时承担两件事：

- **遍历**：`tryAdvance` / `forEachRemaining`
- **分割**：`trySplit`，把当前元素的一部分"让"给一个新的 Spliterator

```java
public interface Spliterator<T> {
    boolean tryAdvance(Consumer<? super T> action);      // 处理一个元素，返回是否还有
    Spliterator<T> trySplit();                            // 尝试分割，返回"前半段"；不能分则返回 null
    long estimateSize();                                  // 预估剩余元素数（可能不准）
    int characteristics();                                 // 位掩码，描述数据特性
    default long getExactSizeIfKnown() { ... }
    default boolean hasCharacteristics(int c) { ... }
    default Comparator<? super T> getComparator() { throw new IllegalStateException(); }
    default void forEachRemaining(Consumer<? super T> action) { ... }
}
```

### trySplit 的语义（最容易搞错的点）

`trySplit()` 的返回值约定非常关键：

- 返回的 Spliterator **覆盖原范围的"前半段"**（prefixed 部分）；
- **原 Spliterator 自身**变为**剩余的后半段**；
- 如果不能分割（例如只剩一个元素、或数据结构不支持），返回 `null`。

一次并行流的执行，本质上就是**递归调用 `trySplit()` 长出一棵"分割二叉树"**：叶子节点各由一个 ForkJoinTask 处理，直到 `estimateSize()` 足够小（默认目标 1/4 个 `parallelism` 批次）或无法再分。

```
         [0..1000]  split
        /          \
    [0..500]        [500..1000]
    /     \          /    \
 [0..250] [250..500] ...   ...
```

> 关键推论：**分割是否均匀，直接决定并行效率**。树的形状由 `trySplit` 的实现决定，而不是由 ForkJoinPool 决定。

## 二、characteristics：8 个"提示位"

`characteristics()` 返回一个位或值，它是给 Stream 框架的**优化提示**：

| 常量 | 含义 | 作用 |
|---|---|---|
| `ORDERED` | 元素有确定顺序 | `findFirst`、`forEachOrdered` 依赖它；无序时可用更快的归约 |
| `DISTINCT` | 元素不重复 | `distinct()` 可省一次去重 |
| `SORTED` | 按 `getComparator()` 排序 | `sorted()` 可短路成 no-op |
| `SIZED` | `estimateSize()` 精确 | `toArray`/`count` 可预分配、走快路径 |
| `SUBSIZED` | `trySplit` 出的子段也是 SIZED | 让并行归约保持尺寸信息 |
| `NONNULL` | 不含 null | 可省 `Objects.requireNonNull` |
| `IMMUTABLE` | 结构不可变 | 遍历期间不会修改 |
| `CONCURRENT` | 可安全并发修改 | 并发集合用，`forEach` 可弱一致 |

一句话：**`SIZED | SUBSIZED` 是并行流性能最重要的两个位**。`ArrayList.spliterator()` 同时具备它们，所以 `parallelStream().count()` 是 O(1) 级别的快；`Stream.iterate` 不 SIZED，`trySplit` 只能"批量化"切，效果差很多。

## 三、JDK 内置实现剖析

### 3.1 ArrayList / 数组：ArrayListSpliterator

```java
static final class ArrayListSpliterator<E> implements Spliterator<E> {
    // 用 (list, origin, fence, expectedModCount) 表示一个区间
    public Spliterator<E> trySplit() {
        int hi = getFence(), lo = index, mid = (lo + hi) >>> 1;
        return (lo >= mid) ? null
            : new ArrayListSpliterator<>(list, lo, mid, expectedModCount); // 前半段
        // 自身 index 不在这里改——注意：ArrayList 用的是"前半段返回 + 自身从 lo 开始"的变体
    }
}
```

它的分割就是**下标二分**，天然均匀、有 O(1) 的 `estimateSize`，因此并行性能最好。数组的 `ArraySpliterator` 同理。

### 3.2 LinkedList：基于 size 的 IteratorSpliterator

`LinkedList` 的 `spliterator()` 走的是通用的 `IteratorSpliterator`：分割靠"数一半元素换到新迭代器"。每次分割都要**逐个 next() 走指针**，且无法随机访问，所以：

- 分割成本高（要遍历一半）；
- 并行后的每个任务仍在链表上顺藤摸瓜，缓存不友好。

**结论：`LinkedList` 别用 `parallelStream()`**，先转 `ArrayList` 再说。

### 3.3 HashMap / HashSet：HashMapSpliterator

`HashMapSpliterator` 按**桶数组（table）区间**分割：`trySplit` 时把后半段桶让出去，遍历时跳过空桶。它有 `estimateSize`（桶数），但没有 `SIZED`（实际元素数未知），`distinct` 等优化会打折。

### 3.4 不 SIZED 的流：generate / iterate

```java
Stream.iterate(0, i -> i + 1).parallel()   // 几乎无法并行加速
IntStream.range(0, N).parallel()           // 可以，SIZED 且均匀
```

`iterate`/`generate` 无法预知长度，`trySplit` 只能靠"预取一批元素"来分割，且 `ORDERED` 语义限制了并行空间。**要并行就先用 `range` 或集合造出有界数据源。**

## 四、StreamSupport：把任意 Spliterator 变成 Stream

平时你拿到的 Stream 都是集合给的，要自己接入，就得用：

```java
Spliterator<T> sp = ...;
Stream<T> stream = StreamSupport.stream(sp, /*parallel=*/true);
IntStream intStream = StreamSupport.intStream(spOfInt, false);
```

这是**自定义数据源进入 Stream 体系的唯一正规入口**。

## 五、实战：为"分页接口"写 Spliterator

场景：数据在远端（数据库/HTTP 分页接口），不能一次性 `loadAll` 到内存，但我们希望像操作本地流一样处理它，最好还能并行拉取。

```java
public final class PagingSpliterator<T> implements Spliterator<T> {

    public interface PageLoader<T> {
        // 返回一页数据（从 offset 开始，最多 limit 条）；空列表表示结束
        List<T> load(long offset, int limit);
    }

    private final PageLoader<T> loader;
    private final int pageSize;
    private long offset;
    private List<T> buffer;   // 当前这一页的数据
    private int cursor;       // buffer 内游标

    public PagingSpliterator(PageLoader<T> loader, long offset, int pageSize) {
        this.loader = loader;
        this.offset = offset;
        this.pageSize = pageSize;
    }

    @Override
    public boolean tryAdvance(Consumer<? super T> action) {
        if (!ensureBuffer()) return false;
        action.accept(buffer.get(cursor++));
        return true;
    }

    private boolean ensureBuffer() {
        if (buffer != null && cursor < buffer.size()) return true;
        buffer = loader.load(offset, pageSize);
        offset += pageSize;
        cursor = 0;
        return buffer != null && !buffer.isEmpty();
    }

    @Override
    public Spliterator<T> trySplit() {
        // 关键：先"跳过"若干页，把跳过的那段本 Spliterator 让出去，
        // 但分页接口通常只能顺序推进，无法真正随机切割。
        // 这里采用"整页让渡 + 自身前进"的折中：让出当前整页的剩余部分。
        if (buffer == null || cursor >= buffer.size()) {
            if (tryAdvanceNoop()) { /* 保证有数据 */ }
        }
        // 简化实现：以"半页"为粒度分裂
        if (buffer == null) return null;
        int mid = (cursor + buffer.size()) >>> 1;
        if (mid == cursor) return null;
        List<T> head = buffer.subList(cursor, mid);
        PagingSpliterator<T> half =
            new PagingSpliterator<>(loader, offset - pageSize, pageSize);
        half.buffer = head;
        half.cursor = 0;
        half.offset = offset; // 自身继续从 mid 处理本页剩余
        this.cursor = mid;
        return half;
    }

    private boolean tryAdvanceNoop() { return ensureBuffer(); }

    @Override
    public long estimateSize() {
        return Long.MAX_VALUE; // 未知总量
    }

    @Override
    public int characteristics() {
        // ORDERED（分页天然有序），非 SIZED
        return ORDERED | NONNULL;
    }
}
```

使用：

```java
var sp = new PagingSpliterator<>(myRepo::queryPage, 0L, 500);
try (Stream<Row> stream = StreamSupport.stream(sp, false)) {
    stream.filter(Row::isValid)
          .map(Row::toDto)
          .forEach(this::handle);
}
```

### 为什么这里**不建议**开并行

分页数据源有两个致命约束：

1. **`estimateSize()` 只能返回 `Long.MAX_VALUE`**，且非 `SIZED`，分割质量取决于你的 `trySplit`；
2. **后端每次分页都是 I/O**，并行会把"顺序扫表"变成"随机并发扫表"，很可能把一个**稳定的全表扫描**拆成**N 个互相争抢连接池的慢查询**，甚至因 `OFFSET` 越大越慢而负优化。

**经验法则：I/O 密集型数据源用并发要换思路**——不是"并行遍历"，而是"并行按分片/游标区间拉取"。真要提升吞吐，应该用 `CompletableFuture` 并发拉多个**独立分片**（如按 `id` 区间或时间分片），再 `Stream.concat` 或直接归约。

## 六、Spliterator 与 collect / reduce 的协作

`forEach` 只是 `Spliterator` 的一种用法。并行归约（`reduce`/`collect`）依赖的是**分割树上的合并**：

```java
// 每个叶子任务独立累加局部结果，再按树形结构合并
long sum = IntStream.range(0, 1_000_000).parallel()
        .filter(i -> i % 2 == 0)
        .sum();                       // 内部走 reduce，合并满足结合律
```

这里有一条**必须遵守的契约**：归约操作（accumulator / combiner）必须**满足结合律且无副作用**。因为并行时合并顺序不确定，`(a op b) op c` 与 `a op (b op c)` 的结果必须一致。用 `parallelStream` 去操作共享可变状态（如往 `ArrayList` 里 `add`），就会得到随机错误的结果——**这正是"并行流别用非线程安全集合"的底层原因。**

`Collectors` 里那些 `groupingByConcurrent`、`toConcurrentMap`，就是为并行场景专门设计的合并器。

## 七、分割质量：并行流性能的隐藏开关

并行流快不快，取决于两个数字：

- **N/Q**：元素数与并行度之比（N 太小，任务调度开销大于收益）；
- **分割均匀度**：树是否平衡。`ArrayList` 完美二分，`LinkedList` 严重失衡。

这也解释了 JDK 的默认分割策略（`AbstractTask`）：

```java
// 伪代码：目标是把任务切到 "叶子 ≈ size / (parallelism * 4)" 的大小
if (estimateSize() <= sizeThreshold) 顺序执行;
else { Spliterator<T> left = sp.trySplit(); if (left == null) 顺序执行; ... }
```

> 面试高频：「为什么 `parallelStream()` 有时比顺序还慢？」——答：分割成本 + 任务调度 + 归约合并开销，加上共享的 `ForkJoinPool.commonPool()` 可能被别人的阻塞任务占用（并发度默认 = CPU-1）。

## 八、面试追问

1. **Spliterator 和 Iterator 的区别？** 前者多了 `trySplit` 与 `characteristics`，为并行而生；Iterator 只能顺序。
2. **`trySplit` 返回的到底是前半还是后半？** 返回的是**前半段**，调用者（原对象）保留剩余部分。
3. **为什么 `ArrayList` 并行快、`LinkedList` 慢？** 随机访问 vs 指针遍历，`trySplit` 成本与缓存友好度天差地别。
4. **`SIZED` 有什么用？** 让 `count()`、`toArray()`、并行归约能预分配与走快路径。
5. **自定义 Spliterator 必须实现哪些方法？** 只有 `tryAdvance`、`trySplit`、`estimateSize`、`characteristics` 四个是抽象的。

## 九、总结

- `Spliterator` = 遍历能力 + 分割能力 + 特性声明，是 Stream（尤其并行流）的地基。
- `trySplit` 的**分割质量**决定并行效率；`SIZED/SUBSIZED` 是性能关键位。
- 集合的 Spliterator 实现各有权衡：数组二分最优，链表最差，哈希按桶切。
- 自定义数据源用 `StreamSupport.stream(sp, parallel)` 接入；I/O 数据源慎用并行遍历，改用分片并发。
- 记住一句话：**Stream 是表象，Spliterator 才是本质**。
