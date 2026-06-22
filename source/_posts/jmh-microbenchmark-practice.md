---
title: JMH 微基准测试实战：精确衡量 Java 代码性能
date: 2026-06-22 08:20:00
tags:
  - Java
  - 性能优化
  - JMH
  - 测试
categories:
  - Java
  - 性能优化
author: 东哥
---

# JMH 微基准测试实战：精确衡量 Java 代码性能

## 一、为什么需要 JMH？

写 Java 的时候，你肯定遇到过这些场景：

- ArrayList 和 LinkedList 到底谁遍历更快？
- StringBuilder 真的比 StringBuffer 快吗？
- Lambda 比匿名内部类慢多少？
- Stream 和 for 循环谁性能更好？

很多人会写一个 `main` 方法，循环几万次打个时间戳就下结论。**但这种方式严重不靠谱。**

### 普通测试的陷阱

```java
// ❌ 这种测试方式不可信
public static void main(String[] args) {
    long start = System.currentTimeMillis();
    List<String> list = new ArrayList<>();
    for (int i = 0; i < 100000; i++) {
        list.add("item-" + i);
    }
    long end = System.currentTimeMillis();
    System.out.println("耗时：" + (end - start) + "ms");
}
```

**问题在哪？**
1. JVM 预热（Warm-up）没做，结果包含 JIT 编译时间
2. 编译器可能做死代码消除（Dead Code Elimination）
3. GC 暂停会污染测量结果
4. 无法控制 CPU 频率缩放、系统负载等干扰

**JMH（Java Microbenchmark Harness）** 就是用来解决这些问题的官方微基准测试工具，由 OpenJDK 开发，精确到纳秒级别。

## 二、快速开始

### 2.1 Maven 依赖

```xml
<dependency>
    <groupId>org.openjdk.jmh</groupId>
    <artifactId>jmh-core</artifactId>
    <version>1.37</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.openjdk.jmh</groupId>
    <artifactId>jmh-generator-annprocess</artifactId>
    <version>1.37</version>
    <scope>test</scope>
</dependency>
```

### 2.2 第一个 Benchmark

```java
@BenchmarkMode(Mode.Throughput)        // 吞吐量模式
@OutputTimeUnit(TimeUnit.MILLISECONDS) // 输出单位
@State(Scope.Thread)                   // 每个线程独立状态
public class StringConcatBenchmark {
    
    private String a = "Hello";
    private String b = "World";
    private int count = 1000;
    
    @Benchmark
    public String plus() {
        String s = "";
        for (int i = 0; i < count; i++) {
            s += a + b;  // ❌ String + 拼接
        }
        return s;
    }
    
    @Benchmark
    public String builder() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < count; i++) {
            sb.append(a).append(b);
        }
        return sb.toString();
    }
    
    @Benchmark
    public String buffer() {
        StringBuffer sb = new StringBuffer();
        for (int i = 0; i < count; i++) {
            sb.append(a).append(b);
        }
        return sb.toString();
    }
    
    public static void main(String[] args) throws RunnerException {
        Options opt = new OptionsBuilder()
            .include(StringConcatBenchmark.class.getSimpleName())
            .warmupIterations(5)     // 5轮预热
            .measurementIterations(5) // 5轮测量
            .forks(1)                 // 1个Fork
            .build();
        new Runner(opt).run();
    }
}
```

运行结果示例：
```
Benchmark                          Mode  Cnt      Score     Error  Units
StringConcatBenchmark.buffer      thrpt    5  45678.123 ± 123.456  ops/ms
StringConcatBenchmark.builder     thrpt    5  52345.678 ± 98.765   ops/ms
StringConcatBenchmark.plus        thrpt    5    123.456 ± 3.456    ops/ms
```

结论：`StringBuilder ≈ StringBuffer >>>> +` 拼接，差了 **400 多倍**。

## 三、JMH 核心概念

### 3.1 模式（@BenchmarkMode）

| 模式 | 含义 | 适用场景 |
|------|------|----------|
| `Throughput` | 吞吐量（ops/time） | 服务端性能评估 |
| `AverageTime` | 平均耗时 | 延迟敏感场景 |
| `SampleTime` | 采样耗时（含分布） | 分析 P99/P999 延迟 |
| `SingleShotTime` | 单次执行耗时 | 冷启动测试 |
| `All` | 以上全部 | 全面评估 |

### 3.2 状态（@State）

```java
@State(Scope.Benchmark)  // 所有线程共享同一个实例
public class SharedState { ... }

@State(Scope.Thread)     // 每个线程独立的实例 ✅ 最常用
public class ThreadState { ... }

@State(Scope.Group)      // 同一个Group内的线程共享
public class GroupState { ... }
```

### 3.3 参数化（@Param）

```java
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
public class ArrayListBenchmark {
    
    @Param({"100", "1000", "10000", "100000"})
    private int size;
    
    private List<String> arrayList;
    private List<String> linkedList;
    
    @Setup
    public void setup() {
        arrayList = new ArrayList<>();
        linkedList = new LinkedList<>();
        for (int i = 0; i < size; i++) {
            arrayList.add("item-" + i);
            linkedList.add("item-" + i);
        }
    }
    
    @Benchmark
    public void arrayListTraverse(Blackhole bh) {
        for (String s : arrayList) {
            bh.consume(s);  // 防止死代码消除
        }
    }
    
    @Benchmark
    public void linkedListTraverse(Blackhole bh) {
        for (String s : linkedList) {
            bh.consume(s);
        }
    }
}
```

### 3.4 Blackhole — 防止死代码消除

JVM 编译器非常聪明，如果计算结果没有被使用，它可能直接优化掉：

```java
@Benchmark
public long sumArray() {
    long sum = 0;
    for (long v : values) {
        sum += v;
    }
    return sum;  // ✅ 返回值会被 JMH 使用
}

@Benchmark
public void consumeArray(Blackhole bh) {
    for (long v : values) {
        bh.consume(v);  // ✅ Blackhole 让 JVM 以为结果被使用了
    }
}
```

## 四、深入配置

### 4.1 完整 Benchmark 配置

```java
@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
@Warmup(iterations = 5, time = 1, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 5, time = 3, timeUnit = TimeUnit.SECONDS)
@Fork(value = 3, jvmArgs = {"-Xms2G", "-Xmx2G", "-XX:+UseG1GC"})
@State(Scope.Thread)
public class CompleteBenchmark { ... }
```

### 4.2 编译器控制

```java
@Benchmark
@CompilerControl(CompilerControl.Mode.DONT_INLINE)  // 禁止内联
public void dontInlineMethod() { ... }

@Benchmark
@CompilerControl(CompilerControl.Mode.INLINE)       // 强制内联
public void forceInlineMethod() { ... }
```

### 4.3 避免常量折叠

```java
// ❌ 错误：JVM 会把 2 * Math.PI 编译为常量
@Benchmark
public double wrong() {
    return Math.log(2 * Math.PI);
}

// ✅ 正确：使用 @Param 或 State 传入
@State(Scope.Thread)
public static class Params {
    double x = 2 * Math.PI;
}

@Benchmark
public double right(Params p) {
    return Math.log(p.x);
}
```

## 五、实战案例

### 案例 1：Stream vs For 循环

```java
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Fork(2)
public class StreamVsLoopBenchmark {
    
    @Param({"100", "10000", "1000000"})
    private int size;
    
    private List<Integer> numbers;
    
    @Setup
    public void setup() {
        numbers = new ArrayList<>(size);
        for (int i = 0; i < size; i++) {
            numbers.add(ThreadLocalRandom.current().nextInt());
        }
    }
    
    @Benchmark
    public int forLoop() {
        int max = Integer.MIN_VALUE;
        for (int n : numbers) {
            if (n > max) max = n;
        }
        return max;
    }
    
    @Benchmark
    public int streamMax() {
        return numbers.stream().mapToInt(Integer::intValue).max().orElse(0);
    }
    
    @Benchmark
    public int parallelStream() {
        return numbers.parallelStream().mapToInt(Integer::intValue).max().orElse(0);
    }
}
```

典型结果：

| Size | For Loop | Stream | Parallel Stream |
|------|----------|--------|----------------|
| 100 | **最快** | 稍慢 20% | 更慢（线程开销） |
| 10,000 | 基线 | 慢 10-30% | **可能更快** |
| 1,000,000 | 基线 | 慢 20-40% | **快 2-4 倍** |

**结论：**
- 小数据量（<1000）：for 循环最优
- 中等数据量：差距不大，选可读性更好的 Stream
- 大数据量 + 多核：Parallel Stream 有明显优势

### 案例 2：枚举 vs 常量字符串比较

```java
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Fork(2)
public class EnumVsStringBenchmark {
    
    static final String STATUS_ACTIVE = "ACTIVE";
    static final String STATUS_INACTIVE = "INACTIVE";
    
    enum Status { ACTIVE, INACTIVE }
    
    String strValue = "ACTIVE";
    Status enumValue = Status.ACTIVE;
    
    @Benchmark
    public boolean stringEquals() {
        return STATUS_ACTIVE.equals(strValue);
    }
    
    @Benchmark
    public boolean enumEquals() {
        return Status.ACTIVE == enumValue;  // 引用比较
    }
}
```

结果：`enum ==` 比 `String.equals()` 快 **一个数量级**。因为枚举比较是引用比较（`==`），不需要字符遍历。

### 案例 3：序列化方案对比

```java
@State(Scope.Thread)
public class SerializationBenchmark {
    
    private User user;
    
    @Setup
    public void setup() {
        user = new User(1L, "test_user", "test@example.com", UserStatus.ACTIVE, LocalDateTime.now());
    }
    
    @Benchmark
    public byte[] jackson() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        return mapper.writeValueAsBytes(user);
    }
    
    @Benchmark
    public byte[] protobuf() throws Exception {
        return user.toProtobuf().toByteArray();
    }
    
    @Benchmark
    public byte[] javaSerialization() throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        ObjectOutputStream oos = new ObjectOutputStream(bos);
        oos.writeObject(user);
        return bos.toByteArray();
    }
}
```

结果：Protobuf > Jackson >> Java Serialization（慢 10-100 倍）。

## 六、常见陷阱与避坑

### 6.1 不要在 Benchmark 里创建对象

```java
// ❌ 错误：每次迭代都创建新对象（增加 GC 压力）
@Benchmark
public void wrong() {
    List<String> list = new ArrayList<>();
    for (int i = 0; i < 100; i++) list.add("x");
}

// ✅ 正确：在 @Setup 中初始化
@State(Scope.Thread)
public static class LocalState {
    List<String> list = new ArrayList<>();
}

@Benchmark
public void right(LocalState state) {
    state.list.clear();
    for (int i = 0; i < 100; i++) state.list.add("x");
}
```

### 6.2 避免分支预测干扰

```java
// 排序后的数组遍历更快（分支预测优化）
@Param({"0", "1"})
private int sorted;  // 0 = 随机, 1 = 排序

@Setup
public void setup() {
    data = new int[10000];
    Random rand = new Random();
    for (int i = 0; i < data.length; i++) {
        data[i] = rand.nextInt();
    }
    if (sorted == 1) {
        Arrays.sort(data);
    }
}

@Benchmark
public long sumIf(Blackhole bh) {
    long sum = 0;
    for (int n : data) {
        if (n > 0) sum += n;  // 排序后这个分支预测率更高
    }
    return sum;
}
```

### 6.3 伪共享（False Sharing）

```java
// ❌ 多个线程修改相邻变量，导致缓存行失效
class Counter {
    volatile long a;  // 线程1 修改
    volatile long b;  // 线程2 修改 - 同一个缓存行！
}

// ✅ 使用 @jdk.internal.vm.annotation.Contended 填充
@Contended
class PaddedCounter {
    volatile long a;
    volatile long b;
}
```

### 6.4 Benchmark 间干扰

```java
// ❌ 错误：不同的 Benchmark 在同一个 Fork 中运行会互相影响
@Fork(1)
public class MixedBenchmark { ... }

// ✅ 正确：每个 Benchmark 在新的 JVM 中运行
@Fork(3)  // 3 次独立的 JVM 进程
public class IsolatedBenchmark { ... }
```

## 七、JMH 结果解读

### 输出指标

```
Benchmark          (size)  Mode  Cnt    Score    Error  Units
MyBenchmark.test    1000  thrpt   10  1234.56 ± 12.34  ops/ms
```

- **Score**: 最终分数（吞吐量或平均时间）
- **Error**: 置信区间（通常是 99.9%），跨越大说明结果不稳定
- **Cnt**: 有效测量次数
- **Units**: 单位（ops/ms, us/op, ns/op 等）

### 如何判断结果是否可信

1. **Error/SD 占比 < 5%** — 结果稳定
2. **不同 Fork 间结果一致** — 没有跨进程干扰
3. **预热曲线收敛** — 最终稳定在某个值
4. **无 GC 事件** — GC 暂停会导致测量失真

## 八、总结

| 要点 | 说明 |
|------|------|
| **为什么用 JMH** | 消除 JIT、GC、死代码消除等干扰，获得可信结果 |
| **核心三要素** | @Benchmark + @State + Blackhole |
| **预热很重要** | 至少 3-5 轮预热让 JIT 完成优化 |
| **多 Fork** | 至少 2-3 次 Fork 消除进程内干扰 |
| **测试环境** | 尽量与生产环境一致（CPU、内存、GC、JVM 参数） |
| **相信 JMH** | 如果 JMH 结果和直觉不符，相信 JMH |

**最后的忠告：不要过早优化，但 JMH 可以帮你精准定位真正的热点。** 用 JMH 验证你的每一个性能假设，而不是靠直觉写测试代码。
