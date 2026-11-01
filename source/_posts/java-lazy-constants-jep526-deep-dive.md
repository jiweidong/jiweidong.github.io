---
title: 【Java 前沿】惰性常量（JEP 526 Lazy Constants）深度解析：启动性能、常量折叠与 static final 的正确替代
date: 2026-11-01 08:05:00
tags:
  - Java
  - Java 25
  - Lazy Constants
  - JEP 526
  - 启动优化
  - JVM
categories:
  - Java 进阶
author: 东哥
---

# 【Java 前沿】惰性常量（JEP 526 Lazy Constants）深度解析

## 前言

`static final` 是 Java 里最"安全"的写法，也是最容易被滥用的写法。

一个典型的 Spring Boot 应用里，你会看到大量这样的代码：

```java
public class ModelRegistry {
    static final ObjectMapper MAPPER = new ObjectMapper()
            .registerModule(new JavaTimeModule())
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    static final Pattern ID_PATTERN = Pattern.compile("^[A-Za-z0-9_-]{8,32}$");

    static final Map<String, PromptTemplate> TEMPLATES = loadTemplates(); // 读 classpath / 打远端
}
```

这段代码有三个隐藏代价：

1. **启动期一次性初始化**：`loadTemplates()` 可能读磁盘、解析 YAML、甚至打远端配置中心。所有类初始化都在主线程串行执行，直接拉长启动时间。
2. **可能永远用不到**：某个只在错误码分支里用到的 `Pattern`，99% 的请求路径根本不会碰，但它照样被编译进启动开销。
3. **JIT 看不见它的"常量性"**：字段是 `static final` 引用了，但值本身是运行时算出来的，JIT 无法把它当成编译期常量做折叠，也就无法在 `getfield` 处消除空检查、无法做激进内联。

过去我们靠 **Holder 类（Initialization-on-demand holder）** 和 **双重检查锁（DCL）** 解决第 1、2 点，但第 3 点基本无解：`Holder.INSTANCE` 对 JIT 来说仍然是一个普通的静态字段读取。

**JEP 526（Lazy Constants）** 就是为了同时解决这三件事：JDK 25 引入 `java.lang.LazyConstant`，它是一个 **线程安全、至多初始化一次、且对 JIT 表现为"常量"** 的惰性容器。

> 说明：本文基于 JDK 25（LTS）preview 阶段的 JEP 526。preview API 在转正前可能微调，落地前请以你所用 JDK 的 javadoc 为准。本文重点讲**设计意图、语义边界和工程选型**，这些不会变。

---

## 一、为什么 `static final` 不够：三种经典替代方案的局限

### 1.1 Holder 类惯用法

```java
public final class Templates {
    private Templates() {}

    private static final class Holder {
        static final Map<String, PromptTemplate> MAP =
                loadTemplatesFromClasspath();
    }

    public static Map<String, PromptTemplate> all() {
        return Holder.MAP;
    }
}
```

优点：类加载语义保证线程安全（JVM 保证 `<clinit>` 只执行一次，且对其他线程有 happens-before），不依赖锁，延迟到首次调用。

局限：

- **代码噪音大**：每加一个惰性值就要多一个内部类，`Templates` 变成一堆 Holder 的注册表。
- **异常语义糟糕**：`<clinit>` 抛异常会变成 `ExceptionInInitializerError`，并且类被标记为 `erroneous`，**后续任何访问都会抛 `NoClassDefFoundError`，无法重试**。配置中心抖动一下，这个类就永久废了。
- **JIT 仍然不认为它是常量**：`getstatic Holder.MAP` 只保证读到同一个引用，JIT 不能把值当 `ConstantValue` 折叠。

### 1.2 双重检查锁（DCL）

```java
private static volatile Map<String, PromptTemplate> cache;

public static Map<String, PromptTemplate> all() {
    Map<String, PromptTemplate> local = cache;
    if (local == null) {
        synchronized (Templates.class) {
            local = cache;
            if (local == null) {
                cache = local = loadTemplatesFromClasspath();
            }
        }
    }
    return local;
}
```

优点：可重试（失败不污染类状态）、可编程处理异常。

局限：

- 每次读取都是一次 **volatile 读**，在热路径上有内存屏障代价（虽然 x86 上成本低于锁，但它彻底杀死了 JIT 的常量折叠能力）。
- 手写容易错（漏 volatile → 指令重排导致发布半初始化对象）。
- 业务代码里到处是模板代码，可读性差。

### 1.3 `Supplier` + `ConcurrentHashMap#computeIfAbsent`

```java
private static final Map<String, Supplier<Object>> REGISTRY = new ConcurrentHashMap<>();

public static Object get(String key) {
    return REGISTRY.computeIfAbsent(key, k -> SUPPLIERS.get(k).get());
}
```

这是很多框架的做法，但 `computeIfAbsent` 在同一个 bin 上有锁竞争，且**初始化函数里递归调用同一个 map 会死锁**（JDK 9 修复了一部分，但仍然有 `IllegalStateException: Recursive update`）。用在"常量"场景是杀鸡用牛刀。

### 1.4 四种方案横向对比

| 维度 | `static final` 直接初始化 | Holder 类 | DCL + volatile | JEP 526 LazyConstant |
|---|---|---|---|---|
| 启动期开销 | 有（必然） | 无 | 无 | 无 |
| 线程安全 | JVM 保证 | JVM 保证 | 需正确实现 | JVM/实现保证 |
| 初始化失败可重试 | 否（类污染） | 否（类污染） | 是 | 是（异常语义明确） |
| 读取开销 | 一次 getstatic | 一次 getstatic | volatile 读 | 一次 `get()`，JIT 可折叠 |
| JIT 常量折叠 | 否 | 否 | 否 | **是（核心卖点）** |
| 递归初始化检测 | N/A | 死锁/StackOverflow | 死锁 | 显式异常 |
| 代码噪音 | 低 | 高 | 高 | 低 |

---

## 二、JEP 526 的基本用法

### 2.1 最小示例

```java
import java.lang.LazyConstant;

public final class ModelRegistry {
    private ModelRegistry() {}

    private static final LazyConstant<ObjectMapper> MAPPER =
            LazyConstant.of(() -> new ObjectMapper()
                    .registerModule(new JavaTimeModule())
                    .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false));

    private static final LazyConstant<Map<String, PromptTemplate>> TEMPLATES =
            LazyConstant.of(() -> loadTemplatesFromClasspath());

    public static ObjectMapper mapper() { return MAPPER.get(); }

    public static PromptTemplate template(String name) {
        return TEMPLATES.get().get(name);
    }
}
```

注意几个关键点：

1. **`LazyConstant` 本身用 `static final` 修饰**——被 hold 的是"容器"，容器对象在类初始化时就创建好了（几乎零成本），真正的值延迟计算。
2. 初始化函数是 `Supplier<T>`，**不接受参数**。这也是它叫"常量"而不是"缓存"的原因：一个 `LazyConstant` 只对应一个值。
3. `get()` 返回 `T`，首次调用触发初始化。

### 2.2 语义边界（面试常问）

JEP 526 的语义契约可以概括为四条：

- **至多执行一次**：初始化函数最多被调用一次，无论多少线程并发 `get()`。
- **并发安全**：其他线程在初始化进行中调用 `get()` 会**等待**（而不是拿到 `null` 或半初始化对象），初始化完成后所有线程看到同一个引用。
- **递归初始化报错**：同一条线程在初始化函数内部再次 `get()` 同一个 `LazyConstant`，会抛出明确的异常（而不是死锁或 `StackOverflowError`）。这一点比 `computeIfAbsent` 友好得多。
- **初始化失败可重试**：初始化函数抛出异常时，异常不会被缓存成永久失败状态（这一点与 Holder 的 `<clinit>` 有本质区别），下一次 `get()` 可以重新尝试。

> 第 4 条是落地时最容易踩的点，也是和 Holder 类最大的差别。**配置中心、数据库连接、远端模型列表** 这类"外部依赖"的初始化，一定要用 LazyConstant 而不是 Holder，否则一次网络抖动就能让整个类永久不可用。

### 2.3 与 `LazyList`（preview 配套）

JEP 526 在 preview 阶段还提供了针对集合的惰性元素支持（`LazyConstant.List` 之类）。它的价值在于：**一个 10000 个元素的常量表，只有被读到的元素才初始化**。这对"大型枚举表 / 词表 / Prompt 模板集合"意义很大——避免了"用了 3 个模板却加载了全部 200 个"的浪费。

由于该部分 API 在 preview 期间仍在演进，本文只讲场景不贴具体签名。生产落地时建议从单值 `LazyConstant` 开始，集合场景视 JDK 版本决定。

---

## 三、JIT 视角：为什么"常量"这两个字值钱

这是 JEP 526 最容易被忽略、也最能体现实力的部分。

### 3.1 普通 `static final` 引用为什么不能折叠

```java
static final int TIMEOUT = 3000;              // 编译期常量，进常量池
static final String NAME = "bge-m3";          // 编译期常量，进常量池
static final ObjectMapper MAPPER = build();   // 运行时构造，只是个"只读引用"
```

前两者会被 **内联进调用方的字节码**（`ldc` 直接拿常量），连 `getstatic` 都没有。

第三者不行。字节码里永远是 `getstatic ModelRegistry.MAPPER`，JIT 在编译 `mapper().writeValueAsString(x)` 时，看到的是一个可能为 `null` 的字段读取：

- 必须保留 **空检查**（哪怕你 100% 确定它不为 null）；
- 无法把 `MAPPER` 的具体类型信息"钉死"到某个具体类，只能做 **类型画像（type profile）** 驱动的去虚化，一旦画像被污染（比如测试里 mock 过）就会退回虚调用。

### 3.2 `LazyConstant.get()` 给了 JIT 什么

`LazyConstant` 的设计目标之一，是让 JIT 能在**稳定态（stable）** 下把 `get()` 的结果当作编译期常量处理：

1. 值一旦初始化完成，**永不改变**（不像 volatile 字段可能被写）；
2. 初始化完成这个状态是 **单向的、可观测的**，JIT 可以插入一个"稳定态保护（stable dimension / dependency）"——如果假设被破坏（理论上不会），退优化（deoptimize）重编即可；
3. 于是可以做到：**空检查消除 + 类型钉死 + 直接内联目标方法 + 甚至把整个对象图的一部分常量折叠**。

举个直观的例子：

```java
public static int patternCacheSize() {
    return ID_PATTERN.get().matcher("").groupCount();
}
```

用 Holder 时，JIT 每次都要 `getstatic` + 空检查 + 虚调用 `matcher()`；用 `LazyConstant` 且该调用点被判定为稳定后，JIT 可以认为 `ID_PATTERN.get()` 恒等于某个具体 `Pattern` 实例，进而把 `matcher("")` 内联展开。

**这就是为什么说它不是"带锁的懒加载"，而是"让 JVM 承认的常量"。**

### 3.3 和 AOT / CDS / Leyden 的关系

Project Leyden（JEP 483/514/515/516）解决的是"**启动时把已经算好的东西存下来**"——训练运行（training run）把类加载、JIT 编译结果、甚至堆快照缓存进 AOT cache，下次启动直接恢复。

LazyConstant 与之互补：

- **AOT cache 会记录哪些 LazyConstant 已经初始化**，重启后如果初始化函数是纯函数（无外部依赖），理论上可以直接恢复值，跳过初始化；
- 反过来，**不是所有值都适合被 AOT 记录**（比如带时间戳、带随机盐的），这些值用 `static final` 会在训练运行时就被固化成一个"错误的值"，而 LazyConstant 至少让"何时初始化"变得可控。

一句话总结：**`static final` 是"类加载时算"，LazyConstant 是"首次用时算，且算完就当常量"，AOT 是"上次算过的直接搬过来"。三者是三个不同的时间维度。**

---

## 四、工程落地：哪些地方该用，哪些地方千万别用

### 4.1 适合的场景（收益明显）

| 场景 | 例子 | 收益 |
|---|---|---|
| 重量级单例 | `ObjectMapper`、`Gson`、`Validator`、`Cipher` | 启动时间 ↓，常驻内存 ↓ |
| 正则 / 模板编译 | `Pattern.compile`、`MessageFormat`、Prompt 模板 | 启动期 CPU ↓ |
| 外部依赖初始化 | 配置中心快照、模型清单、路由表 | 失败可重试，不污染类 |
| 只在大流量分支用到 | 导出、报表、风控规则 | 冷路径零成本 |
| 大型只读常量表 | 词表、字典、码表 | 按需加载（配合 LazyList） |

### 4.2 不适合的场景（会翻车）

**① 需要"刷新"的东西**

```java
// ❌ 错误：LazyConstant 一旦初始化就不能换值
private static final LazyConstant<Map<String, String>> CONFIG =
        LazyConstant.of(() -> configCenter.snapshot());
```

配置要动态刷新（Nacos/Apollo 推送），`LazyConstant` 帮不了你。这类需求请用 `volatile` 引用 + 监听回调替换，或者 `AtomicReference` + CAS。

**② 每个 key 一个值**

`LazyConstant` 是 **一值一容器**，不是缓存。`Map<String, LazyConstant<X>>` 这种结构在 key 无界时就是内存泄漏。多 key 场景用 Caffeine。

**③ 初始化函数有副作用**

初始化函数可能被"重试"，所以它必须是 **幂等** 的。往数据库 insert 一条初始化记录、发一条 MQ 消息，这些都不该放进去。

**④ 需要拿到"是否已初始化"**

preview 期间"探测是否已初始化"的 API 有限，别把业务逻辑建立在"惰性状态可观测"上。

### 4.3 一个完整的 Spring Boot 落地例子

```java
@Configuration(proxyBeanMethods = false)
public class AiClientConfig {

    /** 模型清单：启动时不拉取，首次用到才拉；拉取失败下次还能重试 */
    private static final LazyConstant<Map<String, ModelSpec>> MODEL_SPECS =
            LazyConstant.of(AiClientConfig::fetchModelSpecs);

    /** 重型单例 */
    private static final LazyConstant<ObjectMapper> MAPPER =
            LazyConstant.of(() -> JsonMapper.builder()
                    .addModule(new JavaTimeModule())
                    .enable(DeserializationFeature.READ_UNKNOWN_ENUM_VALUES_AS_NULL)
                    .build());

    @Bean
    ObjectMapper objectMapper() {
        return MAPPER.get();
    }

    @Bean
    ModelRouter modelRouter() {
        return new ModelRouter(MODEL_SPECS.get());
    }

    private static Map<String, ModelSpec> fetchModelSpecs() {
        // 幂等、无副作用、失败可重试
        return HttpSupport.getJson("/internal/models", ...);
    }
}
```

注意 `@Bean` 方法里调 `MAPPER.get()` 本身不构成"启动期强制初始化"的矛盾——Spring 创建这个 Bean 时确实要 `ObjectMapper`，这里延迟的意义在于**顺序无关**：`objectMapper()` 什么时候被创建，`MAPPER` 就什么时候初始化，而不是在 `AiClientConfig` 类加载时。

---

## 五、实测方法：怎么证明它真的更好

不要相信任何"性能提升 X%"的文章（包括本文），自己跑：

```java
import org.openjdk.jmh.annotations.*;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(java.util.concurrent.TimeUnit.NANOSECONDS)
@Warmup(iterations = 5, time = 1)
@Measurement(iterations = 5, time = 1)
@Fork(2)
public class ConstantReadBenchmark {

    static final java.util.regex.Pattern EAGER = java.util.regex.Pattern.compile("[a-z]+");
    private static final java.lang.LazyConstant<java.util.regex.Pattern> LAZY =
            java.lang.LazyConstant.of(() -> java.util.regex.Pattern.compile("[a-z]+"));

    @Benchmark
    public boolean eager() {
        return EAGER.matcher("abcdef").matches();
    }

    @Benchmark
    public boolean lazy() {
        return LAZY.get().matcher("abcdef").matches();
    }
}
```

**看结果时注意两点：**

1. **必须开 `-XX:+PrintCompilation` 或 JFR 确认方法真的被 C2 编译了**，否则你测的是解释执行。
2. **单次读开销的差异通常在纳秒级**，真正的收益在 **启动时间** 和 **整体内存占用**。建议用 `-Xlog:class+init=info` 看类初始化耗时，用 `-XX:StartFlightRecording` 看启动阶段 CPU 分布。

启动耗时对比的粗粒度方法：

```bash
# 记录类初始化耗时，找出启动期最贵的 20 个类
java -Xlog:class+init=info:file=init.log -jar app.jar
sort -t' ' -k1 init.log | tail -20
```

如果你把 top20 里的重量级单例改成 `LazyConstant`，启动时间会有可观测的下降（具体幅度取决于你的应用，10%~30% 是常见区间，但别当承诺）。

---

## 六、面试追问与踩坑清单

**Q1：`LazyConstant` 和 `static final` 有什么区别？**

`static final` 修饰的是"引用只读"，值在类初始化（`<clinit>`）时就算好；`LazyConstant` 修饰的是一个惰性容器，值首次 `get()` 时才算，且 JVM 能在稳定态把它当常量处理。前者是"编译期/类加载期的常量"，后者是"运行期的稳定值"。

**Q2：为什么不用 DCL？不是一样线程安全吗？**

DCL 每次读都是一次 volatile 读，有内存屏障语义，**JIT 无法把它当常量**。而且手写 volatile 容易漏，递归初始化会死锁。LazyConstant 把"懒加载 + 线程安全 + 常量性"三件事一次解决。

**Q3：初始化函数抛异常会怎样？**

不会被永久缓存为失败状态，后续 `get()` 可以重试。所以初始化函数必须**幂等、无副作用**。这跟 Holder 类 `<clinit>` 失败导致 `NoClassDefFoundError`（永久失效）是本质区别。

**Q4：能不能刷新？**

不能。它叫 Constant 不叫 Refreshable。要刷新请用 `volatile` 引用整体替换 + `AtomicReference`。

**Q5：preview 特性能不能上生产？**

JDK 25 上需要 `--enable-preview`，且 class 文件的 minor version 会绑定具体 JDK，**升级 JDK 必须重新编译**，跨版本运行会 `UnsupportedClassVersionError`。建议：核心框架/中间件可以先在工具类里试用，业务主干等转正。

**踩坑 1：以为它是缓存。**
`LazyConstant` 不存多值，不做淘汰，不做 TTL。多值请用 Caffeine。

**踩坑 2：初始化里做重活却没设超时。**
`get()` 会阻塞所有并发调用者。如果初始化要打远端，**必须自带超时**，否则第一个请求会把整条线程池挂死。建议初始化函数内部用 `CompletableFuture.orTimeout()` 或 HTTP 客户端超时兜底。

**踩坑 3：在 `static` 初始化块里主动 `get()`。**
那就等于退化成 `static final`，白折腾。要延迟就一个字都别提前碰。

**踩坑 4：`--enable-preview` 忘记加在运行参数上。**
编译通过、运行报 `UnsupportedClassVersionError` 或 `NoSuchMethodError`，排查半天。CI 里把 `--enable-preview` 写进 `JAVA_TOOL_OPTIONS`。

---

## 七、总结

| 结论 | 说明 |
|---|---|
| LazyConstant 不是"懒加载工具" | 它的核心价值是**让 JIT 承认的常量**，而不是省一次 new |
| 选型口诀 | 启动期贵 + 只读 + 可能用不到 → LazyConstant；要刷新 → volatile 引用；多 key → Caffeine；纯常量 → `static final` |
| 落地顺序 | 先改 top20 重量级单例 → 再用 `-Xlog:class+init` 验证启动收益 |
| 最大风险 | 以为是缓存、初始化没超时、忘了 `--enable-preview` |

Java 的"常量"概念在 JDK 25 之后变得立体了：**编译期常量（`ConstantValue`）→ 类加载期常量（`static final`）→ 运行期稳定常量（`LazyConstant`）→ 上次运行算好的常量（AOT cache）**。理解了这条时间轴，你再看 Spring 的 `@Lazy`、Guava 的 `Suppliers.memoize`、Caffeine 的 `LoadingCache`，会发现它们各自站在不同的位置上——而 `LazyConstant` 是唯一一个**同时**做到"延迟、线程安全、可重试、JIT 可见"的方案。

> 下一篇会结合 Project Leyden 的 AOT cache，讲"哪些常量能被缓存进 CDS 归档、哪些不能"，以及 Spring Boot 4 的多阶段镜像怎么吃到这波红利。
