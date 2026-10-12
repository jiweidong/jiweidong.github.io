---
title: 【Java 并发】并行流（Parallel Stream）深度解析：ForkJoinPool 公共池、工作窃取与性能陷阱
date: 2026-10-12 08:00:00
tags:
  - Java
  - 并发
  - Stream
  - ForkJoinPool
  - 性能优化
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【Java 并发】并行流（Parallel Stream）深度解析：ForkJoinPool 公共池、工作窃取与性能陷阱

## 面试官：`list.parallelStream()` 和 `list.stream()` 有什么区别？

很多同学张口就来：「加个 `parallel` 就是并行，跑得更快」。

这个回答在面试里基本是及格线以下。真正被追问的是：

- 它底层用的哪个线程池？线程数是几个？
- 为什么线上用并行流反而更慢，甚至把服务打挂？
- 并行流的**任务拆分规则**是什么？小集合拆分有意义吗？
- 为什么在并行流里调 RPC / 查数据库是灾难？

今天这篇文章，我们从 API 表面一路挖到 `ForkJoinPool` 的工作窃取、`Spliterator` 拆分机制和「公共池陷阱」，把并行流讲透。

---

## 一、并行流的本质：一条 `parallel` 标志位

`Collection.stream()` 返回的是 `Head` 流，`parallelStream()` 返回的是 `Head` 但 `parallel` 标志位为 `true`：

```java
default Stream<E> stream() {
    return StreamSupport.stream(spliterator(), false);
}

default Stream<E> parallelStream() {
    return StreamSupport.stream(spliterator(), true);
}
```

注意：`parallel` 只是一个**布尔状态**。你甚至可以在流中间随意切换：

```java
list.stream()
    .filter(x -> x > 0)
    .parallel()          // 从此处开始转为并行
    .map(this::compute)
    .sequential()        // 又切回串行
    .forEach(System.out::println);
```

也就是说，**并行流不是一种新的数据结构，而是执行模式的开关**。这个开关的最终落点是 `TerminalOp`，比如 `ReduceOp`、`ForEachOp`。

### 流水线结构

```text
Head(数据源) → StatelessOp(filter/map) → StatefulOp(sorted/distinct) → TerminalOp
```

- **无状态中间操作**（`filter`、`map`、`flatMap`）：元素之间互不影响，可以任意并行拆分。
- **有状态中间操作**（`sorted`、`distinct`、`limit`、`skip`）：需要看到部分或全部元素，拆分会受到限制，并行收益大幅下降。
- **终止操作**：决定是「每个元素独立处理」还是「需要归约合并」。

---

## 二、执行引擎：ForkJoinPool 与工作窃取

并行流的终止操作由 `AbstractTask` 家族实现，本质是一个 `ForkJoinTask`：

```java
// 简化后的核心流程
abstract class AbstractTask<P_IN, P_OUT, R, K extends AbstractTask<P_IN, P_OUT, R, K>>
        extends CountedCompleter<R> {

    @Override
    public void compute() {
        Spliterator<P_IN> rs = spliterator, ls;
        long sizeEstimate = rs.estimateSize();
        long sizeThreshold = getTargetSize(sizeEstimate);
        boolean forkRight = false;
        K task = this;
        while (sizeEstimate > sizeThreshold && (ls = rs.trySplit()) != null) {
            K leftChild, rightChild;
            task.leftChild = leftChild = task.makeChild(ls);
            task.rightChild = rightChild = task.makeChild(rs);
            task.setPendingCount(1);
            if (forkRight) {
                forkRight = false;
                rs = ls;
                task = leftChild;
                task.fork();      // 右边任务丢给其他线程“偷”
            } else {
                forkRight = true;
                task = rightChild;
                leftChild.fork();
            }
            sizeEstimate = rs.estimateSize();
        }
        task.setLocalResult(task.doLeaf());
        task.tryComplete();
    }
}
```

几个关键点：

1. **递归二分 + `trySplit`**：每次把当前待处理区间一分为二，直到 `estimateSize()` 小于阈值。
2. **`fork()` 把子任务压入当前线程的工作队列**（队尾），自己继续处理另一半。
3. **工作窃取（Work-Stealing）**：空闲线程从其他线程队列的**队头**偷任务，减少竞争。

```text
线程 A 的工作队列: [Task5][Task3][Task1]  ← fork 从尾部压入
线程 B (空闲) 从头部偷: Task5 → 开始执行
```

工作窃取的精髓在于：**自己处理用 LIFO（尾部），被别人偷用 FIFO（头部）**，既提高了局部性（刚 fork 的任务数据可能还在缓存里），又减少了线程间锁竞争。

### 阈值是怎么算的？

```java
private static final long LEAF_TARGET = ForkJoinPool.getCommonPoolParallelism() << 2;

protected long getTargetSize(long sizeEstimate) {
    return sizeEstimate / (LEAF_TARGET << 1);
}

final long suggestTargetSize(long sizeEstimate) {
    long est = sizeEstimate / LEAF_TARGET;
    return est > 0L ? est : 1L;
}
```

- `getCommonPoolParallelism()` 默认是 `CPU 核心数 - 1`（最少 1）。
- `LEAF_TARGET = 并行度 << 2`，即 8 核机器上大约是 `7 * 4 = 28`。
- 阈值 = `集合大小 / (28 * 2)`。

这解释了一个常见现象：**小集合用并行流纯粹是负优化**。100 个元素的集合，阈值是 `100 / 56 = 1`，几乎每个元素都要走一遍 fork/join 的消息传递，线程调度开销远超计算本身。

经验值：**元素处理时间 × 元素数量 ≫ 任务拆分开销** 时才值得并行，一般建议数据量在 **1 万以上**且单个元素计算较耗时（毫秒级）再用。

---

## 三、致命陷阱一：公共池（Common Pool）被阻塞

`parallelStream()` 默认使用的是 `ForkJoinPool.commonPool()`——一个**全局共享**的线程池。它的并行度：

```java
// 默认为 CPU 核心数 - 1，可通过系统属性调整
System.getProperty("java.util.concurrent.ForkJoinPool.common.parallelism");
```

### 为什么危险？

假设你在并行流里发起 HTTP 调用：

```java
// ☠️ 千万别这么写
List<Result> results = ids.parallelStream()
    .map(id -> httpClient.call(id))   // 阻塞 200ms
    .collect(Collectors.toList());
```

8 核机器上公共池只有 7 个线程。一旦这 7 个线程全部阻塞在 IO 上：

- 并行流卡住，`parallelStream()` 退化成「串行的 1/7 速度」；
- **更严重的是，同一个 JVM 里任何其他使用公共池的代码（包括某些库内部使用的并行流）都会被拖死**。

这就是所谓的**公共池污染**。一个业务的慢查询能让整个应用里所有的并行流全部排队。

### 正确做法：自定义 ForkJoinPool

```java
ForkJoinPool pool = new ForkJoinPool(16);   // 按 IO 场景放大
try {
    List<Result> results = pool.submit(() ->
        ids.parallelStream()
           .map(id -> httpClient.call(id))
           .collect(Collectors.toList())
    ).get();
} finally {
    pool.shutdown();
}
```

**关键原理**：`parallelStream()` 会调用 `ForkJoinTask.fork()`，而 `fork()` 会把任务提交到**当前线程所属的池**。如果你在 `pool.submit(...)` 的 lambda 里执行并行流，那么这段代码运行在一个 ForkJoinPool 的 worker 线程上，`ForkJoinTask.getPool()` 返回的就是这个自定义池，而不是公共池。

这是面试里非常值得讲的一个点：**并行流用哪个池，取决于「执行并行流代码的线程属于哪个池」**。

---

## 四、致命陷阱二：`forEach` 顺序与副作用

并行流的 `forEach` **不保证顺序**，`forEachOrdered` 才保证（但会引入同步开销，性能往往比串行还差）。

```java
// 输出顺序不确定
IntStream.range(1, 100).parallel().forEach(System.out::print);

// 输出顺序确定，但内部有同步
IntStream.range(1, 100).parallel().forEachOrdered(System.out::print);
```

更常见的翻车是**共享可变状态**：

```java
// ☠️ 结果丢失（ArrayList 非线程安全）
List<Integer> result = new ArrayList<>();
IntStream.range(0, 10000).parallel().forEach(result::add);

// ✅ 用 collect 做归约
List<Integer> ok = IntStream.range(0, 10000).parallel()
        .boxed()
        .collect(Collectors.toList());
```

`forEach` 传的是 `Consumer`，语义上就要求**无副作用**。需要汇聚结果请一律用 `collect`，让框架去做正确的并发归约。

---

## 五、性能实测：并行流到底快不快？

下面用一个微基准（实际项目请用 JMH，见 `jmh-microbenchmark-practice`）观察不同数据规模下的表现：

```java
static long sumSerial(long n) {
    return LongStream.rangeClosed(1, n).sum();
}

static long sumParallel(long n) {
    return LongStream.rangeClosed(1, n).parallel().sum();
}
```

| 数据规模 | 串行耗时 | 并行耗时 | 结论 |
| --- | --- | --- | --- |
| 1,000 | ~2 μs | ~20 μs | 并行更慢 10 倍 |
| 100,000 | ~150 μs | ~60 μs | 并行略优 |
| 10,000,000 | ~15 ms | ~3 ms | 并行明显优势 |
| 10,000,000（含阻塞 IO） | ~2 s | ~30 s（线程耗尽） | 并行灾难 |

规律很清晰：

- **数据量小** → 拆分/调度开销占主导，负优化；
- **计算密集 + 数据量大** → 收益明显；
- **IO 密集 / 阻塞** → 公共池线程被占满，性能暴跌。

### 影响性能的其他细节

1. **装箱开销**：`Stream<Integer>` 大量装箱，优先用 `IntStream`/`LongStream`/`DoubleStream`。
2. **自动拆分的质量取决于数据源**：`ArrayList`、数组、`IntStream.range` 的 `Spliterator` 支持精确拆分（`estimateSize` 准确、`trySplit` 均分），是并行的理想数据源；而 `LinkedList`、`Stream.iterate`、`BufferedReader.lines()` 拆分能力差，并行效果很差。

```java
// 差：LinkedList 的 split 几乎无法均分
linkedList.parallelStream()...

// 好：ArrayList 支持精确二分
arrayList.parallelStream()...
```

3. **`sorted`/`distinct` 会破坏并行度**：它们是有状态操作，需要在归约阶段合并，往往退化为串行。
4. **`findFirst` vs `findAny`**：`findFirst` 在并行下需要等待最前面的元素，代价高；`findAny` 直接返回任意一个，更适合并行。

```java
// 并行下 findAny 更快
list.parallelStream().filter(...).findAny();
```

---

## 六、Spliterator：并行流的拆分底座

`Spliterator`（splitable iterator）是并行流能「分而治之」的根本。核心方法：

```java
public interface Spliterator<T> {
    boolean tryAdvance(Consumer<? super T> action);   // 顺序遍历一个元素
    Spliterator<T> trySplit();                        // 尝试拆分出一半
    long estimateSize();                              // 预估剩余元素数
    int characteristics();                            // 特征位
}
```

特征位（`characteristics()`）非常关键，直接决定并行优化的可行性：

| 特征 | 含义 | 对并行的影响 |
| --- | --- | --- |
| `ORDERED` | 元素有顺序 | `forEach` 无序、`forEachOrdered` 有序 |
| `DISTINCT` | 元素唯一 | `distinct()` 可省一次去重 |
| `SORTED` | 已排序 | `sorted()` 可跳过 |
| `SIZED` | 大小已知 | 精确估算、便于均分 |
| `SUBSIZED` | 子分割大小也已知 | 支持精确并行拆分 |
| `NONNULL` | 不含 null | 可省 null 检查 |
| `IMMUTABLE` / `CONCURRENT` | 源不可变/并发安全 | 影响并发修改策略 |

`ArrayList.spliterator()` 返回的是 `ArrayListSpliterator`，`characteristics()` 包含 `SIZED | SUBSIZED | ORDERED`，所以它是**并行友好**的数据源。

手写一个支持并行的自定义 `Spliterator`（比如分片读取数据库）：

```java
public class RangeSpliterator implements Spliterator<Integer> {
    private int lo, hi;

    public RangeSpliterator(int lo, int hi) { this.lo = lo; this.hi = hi; }

    @Override
    public boolean tryAdvance(Consumer<? super Integer> action) {
        if (lo >= hi) return false;
        action.accept(lo++);
        return true;
    }

    @Override
    public Spliterator<Integer> trySplit() {
        int mid = (lo + hi) >>> 1;
        if (mid <= lo) return null;          // 太小，不再拆
        RangeSpliterator prefix = new RangeSpliterator(lo, mid);
        lo = mid;
        return prefix;
    }

    @Override
    public long estimateSize() { return hi - lo; }

    @Override
    public int characteristics() { return SIZED | SUBSIZED | ORDERED | IMMUTABLE; }
}
```

要点：**`trySplit()` 返回 null 表示「不再拆分」**，这是终止递归的重要信号。如果 `trySplit` 返回的虽然是新对象但尺寸几乎没变小，会导致无限拆分或极差的分摊效果。

---

## 七、并行流是「可复用的」，但务必注意状态

```java
Stream<Integer> s = list.stream().parallel();
long count = s.count();       // ✅ 第一次终止，流被消费
long sum = s.mapToInt(x -> x).sum();  // ❌ IllegalStateException: stream has already been operated upon
```

流是**一次性**的，终止操作后不可复用。并行流也一样。

另外，`parallelStream()` 的调用本身有成本（构造 `ForkJoinTask`），高频小任务不要反复创建。

---

## 八、面试常见追问

**Q1：并行流的线程数能改吗？**

```bash
# 改公共池并行度（全局生效，慎用）
-Djava.util.concurrent.ForkJoinPool.common.parallelism=16
```

但**不推荐**动公共池，正确姿势是自定义 `ForkJoinPool` 并用 `submit` 包住并行流。

**Q2：`parallel()` 和 `parallelStream()` 有区别吗？**

没有本质区别，都是设置 `parallel` 标志位。`parallelStream()` 只是集合上的语法糖。

**Q3：并行流和线程池提交任务，谁更好？**

- 对于**纯计算、数据量大、无共享状态**的任务，并行流代码更简洁，性能接近。
- 对于**IO 密集、需要控制并发度、需要隔离/超时/降级**的任务，必须用显式线程池（`ExecutorService` + `CompletableFuture`），因为并行流：
  - 无法设置超时；
  - 无法优雅处理异常（异常会包成 `CompletionException` 向外抛）；
  - 无法限流、无法隔离；
  - 阻塞会污染公共池。

**Q4：并行流里抛异常会怎样？**

并行的 `map` 里抛出的异常，会被包装进 `ForkJoinTask` 内部，最终在终止操作时以 `RuntimeException`/`CompletionException` 抛出，**其他子任务的结果被丢弃，且无法优雅降级**。这也是它不适合生产 IO 场景的重要原因。

**Q5：为什么 `sorted()` 之后并行度会下降？**

`sorted` 是有状态操作，它会在归约阶段把各个子任务的结果**合并后统一排序**，合并本身是串行或半串行的，拆分收益被吃掉。`distinct`、`limit`、`skip` 同理。

---

## 九、生产实践清单

1. **数据量 < 1 万或单元素计算 < 1ms**：不要用并行流。
2. **有 IO、RPC、DB 调用**：禁止用并行流，改用显式线程池 + `CompletableFuture`。
3. **必须并行的计算场景**：用自定义 `ForkJoinPool` 包住，避免污染公共池。
4. **严禁在并行流中修改共享可变状态**，一律用 `collect` 归约。
5. **优先选择 `ArrayList`、数组、`range` 这类可精确拆分的数据源**，避免 `LinkedList`、`iterate()`。
6. **涉及顺序时用 `forEachOrdered`**，但要意识到它会削弱并行收益。
7. **基准测试一律用 JMH**，不要用 `System.currentTimeMillis()` 手搓。

---

## 十、总结

一句话概括并行流：**它是「把串行计算自动映射到 ForkJoinPool」的语法糖，而不是万能加速器。**

它的三层结构值得记住：

- **语法层**：`parallel` 标志位 + 流水线（无状态/有状态中间操作）；
- **执行层**：`AbstractTask` 递归二分 + `ForkJoinPool` 工作窃取；
- **数据层**：`Spliterator` 的 `trySplit` 与特征位决定拆分质量。

三个高频翻车点：

- 公共池污染（阻塞 IO）；
- `forEach` 无序 + 共享状态；
- 小数据量负优化。

面试时如果能主动说出「并行流用哪个池取决于执行线程所属的池」以及「`Spliterator` 的 `SUBSIZED` 特征决定拆分质量」，基本就能和「只会背 API」的候选人拉开差距了。
