---
title: 【JVM 实战】Code Cache 代码缓存深度解析：分层编译、缓存耗尽与 ReservedCodeCacheSize 调优
date: 2026-09-18 08:00:00
tags:
  - Java
  - JVM
  - JIT
  - 性能调优
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 实战】Code Cache 代码缓存深度解析：分层编译、缓存耗尽与 ReservedCodeCacheSize 调优

## 面试官：你见过日志里出现 `CodeCache is full. Compiler has been disabled` 吗？

这句话是 JIT 的求救信号。它出现在 `stdout` / GC 日志里时，意味着 **JVM 已经不再编译新代码，所有热点方法退化为解释执行**。表面上看服务「没挂」，但 RT 会毫无征兆地翻倍甚至翻十倍。

很多同学对 Code Cache 的印象停留在「JIT 编译后的代码放哪」，真要问「它多大、怎么分区域、满了会怎样、怎么监控」，就答不上来了。这篇把它讲透。

---

## 一、Code Cache 是什么，为什么必须有它

Java 是解释 + 编译混合执行的：

- 解释器（`interpreter`）：启动快、执行慢；
- JIT 编译器（C1/C2）：执行快、编译有成本，**编译产物必须存在某个可执行内存区**。

这块可执行内存就是 **Code Cache（代码缓存）**，属于 **非堆内存（Non-Heap）**，位于 JVM 的 Native Memory 中，不受 `-Xmx` 控制。

它有自己的 MBean，可以用 `jcmd` 直接看：

```bash
jcmd <pid> Compiler.code_heap_memory_usage
```

输出：

```text
CodeHeap 'non-nmethods'    used 1629K, committed 1920K, reserved 5056K
CodeHeap 'profiled nmethods' used 14318K, committed 15872K, reserved 122880K
CodeHeap 'non-profiled nmethods' used 27654K, committed 28672K, reserved 122880K
```

## 二、三段式结构：Code Cache 不是一个整块

从 JDK 8 起（更准确说是 JDK 9 之后稳定成型），Code Cache 被切成 3 个独立 Segmented Code Heap：

| 分区 | 存放内容 | 特点 |
| --- | --- | --- |
| `non-nmethods` | JIT 自身元数据、适配器（i2c/c2i adapter）、运行时存根 | 大小固定，通常几 MB |
| `profiled nmethods` | C1 编译产物（带 profiling 计数） | 生命周期短、会被回收 |
| `non-profiled nmethods` | C2 编译产物（最高优化级别） | 基本不会被卸载，长期占用 |

为什么要分 3 段？因为如果混在一起，**C1 产出的短命代码会把空间碎片化，导致大块的 C2 代码放不进去**。分段后各自独立，避免互相挤占。

⚠️ 关键：**分段是按字节切分的，不能互相借空间**。所以经常出现「总体来说还有空，但 `non-profiled` 满了」的诡异现场。排查时一定要看三个分区各自的 `used/committed/reserved`。

---

## 三、分层编译（Tiered Compilation）与 Code Cache 的关系

JDK 8 之后默认 `-XX:+TieredCompilation`，执行路径分 5 层：

| 层级 | 编译器 | 说明 |
| --- | --- | --- |
| 0 | 解释器 | 无 profiling |
| 1 | C1 | 简单快速编译，无 profiling |
| 2 | C1 | 带基础 profiling |
| 3 | C1 | 带完整 profiling |
| 4 | C2 | 重量级优化（内联、逃逸分析、循环展开） |

典型流转：`0 → 3 → 4`。方法先被 C1 快速编译（层 2/3），攒够热度后交给 C2（层 4）。

**这就导致同一方法可能同时存在多份编译产物**：C1 版本先进 Code Cache，C2 版本再进来，等 C1 版本「过期」后被回收（sweeper）。所以 Code Cache 的占用并不等于「编译过的方法数 × 一份」。

这也是为什么 **Code Cache 默认要 240MB**——因为分层编译让编译产物数量激增。

---

## 四、默认值到底是多少

| JVM 配置 | 默认 `ReservedCodeCacheSize` |
| --- | --- |
| 开启分层编译（默认） | **240 MB** |
| 关闭分层编译（`-XX:-TieredCompilation`） | 48 MB |
| 未开启 `CompileThreshold` 优化的小型容器 | 同 240MB |

对应参数：

```bash
-XX:ReservedCodeCacheSize=256m   # 预留上限
-XX:InitialCodeCacheSize=8m      # 初始提交大小
-XX:+SegmentedCodeCache          # 默认开启，强制分段
```

`Reserved` 是地址空间预留（不占物理内存），`Committed` 是按需提交，真正占 RSS 的是 committed 部分。

---

## 五、耗尽会发生什么：性能滑坡而非崩溃

看 JVM 的日志：

```text
Java HotSpot(TM) 64-Bit Server VM warning: CodeCache is full.
Compiler has been disabled. Switch off the compiler to make it restart.
```

一旦触发（HotSpot 里的 `CodeCacheSweeper` 清不出足够空间）：

1. **编译器被禁用**，`Method` 的热度不再触发编译；
2. 已编译的方法仍然可用，但 **新进来的热点方法只能解释执行**；
3. 更糟的是 **反优化（Deoptimization）**：如果 C2 代码需要回退（例如类型假设失败），回退后无法再被重新编译 → 永久留在解释器；
4. 表现为：CPU 升高（解释执行更耗 CPU）、P99 延迟劣化、吞吐下降。

**关键认知：Code Cache 不会 OOM。** 它不是堆，满了只是禁用编译器，服务继续跑（只是变慢）。所以它经常被监控忽略，直到被压测/大促打脸。

顺带一个常考混淆点：

| 情况 | 现象 |
| --- | --- |
| Code Cache 满 | 警告日志 + 性能下降，**不抛异常** |
| Metaspace 满 | `java.lang.OutOfMemoryError: Metaspace` |
| 直接内存满 | `java.lang.OutOfMemoryError: Direct buffer memory` |

---

## 六、谁最容易把 Code Cache 吃满

经验上按「元凶」排序：

1. **动态生成类大户**：CGLIB、Javassist、ByteBuddy、Groovy/Kotlin 脚本、JSP 编译、MyBatis 动态语句缓存、Fastjson ASM 反序列化器；
2. **大量 Lambda / 方法引用**：每个 Lambda 会走 `invokedynamic` → `LambdaMetafactory` 生成合成类；
3. **超大单体应用**：方法数量巨大（几万到十几万方法），C2 编译产物累积；
4. **频繁 Deopt + 重编译**：类型不确定的代码（大量反射、`Object` 类型流转）反复失效重编；
5. **APM Agent 大量插桩**：字节码增强让方法体膨胀，编译产物更大。

有一个特别隐蔽的场景：**JSON 库对每个 POJO 动态生成 Reader/Writer 类**。系统里 POJO 类型越多、字段越多，生成的类越多，这些类的方法很快变热并被编译，Code Cache 迅速膨胀。

---

## 七、监控与排查实战

### 7.1 快速查看

```bash
jcmd <pid> Compiler.code_heap_memory_usage

# 打印 Code Cache 汇总（进程退出时）
-XX:+PrintCodeCache
-XX:+PrintCodeCacheOnCompilation   # 每次编译都打印，压测时用

# 编译活动（谁在被编译、谁在被反优化）
-XX:+PrintCompilation
-XX:+PrintInlining
-XX:+TraceDeoptimization
```

### 7.2 JFR 观察（推荐线上用）

```bash
jcmd <pid> JFR.start duration=60s filename=code.jfr
```

在 JFR 事件里关注：

- `jdk.CodeCacheFull` —— Code Cache 满事件；
- `jdk.CodeSweeperStatistics`；
- `jdk.CompilerStatistics` / `jdk.Compilation` —— 编译耗时与产物大小；
- `jdk.Deoptimization` —— 反优化次数与原因。

`jdk.Deoptimization` 事件特别有用：如果某个方法在反复 deopt，说明它才是 Code Cache 的增长源。

### 7.3 JMX / Micrometer

```java
MemoryPoolMXBean pool = ManagementFactory.getMemoryPoolMXBeans().stream()
        .filter(p -> p.getName().contains("CodeHeap"))
        .findFirst().orElseThrow();
System.out.println(pool.getName() + " " + pool.getUsage());
```

Spring Boot Actuator 里 `/actuator/metrics/jvm.memory.used` 带 tag `area=nonheap, id=CodeHeap 'non-profiled nmethods'`，可以直接接 Prometheus 告警。

### 7.4 三步定位法

```text
1) 确认是否满：jcmd Compiler.code_heap_memory_usage，看哪个分区 used ≈ reserved
2) 确认增长源：JFR 的 jdk.Compilation + PrintCompilation 聚合类名
3) 确认是否在用：PrintCompilation 里出现大量 make not entrant / deoptimization
```

---

## 八、调优建议（按优先级）

### 8.1 先调参数（成本最低）

```bash
-XX:ReservedCodeCacheSize=512m
-XX:+UseCodeCacheFlushing            # JDK 8+ 默认开启，允许刷新旧代码
-XX:StartAggressiveSweepingAt=50     # 增加到 50%，更早开始清扫
```

`-XX:+UseCodeCacheFlushing` 是 JDK 8 引入的重要特性：允许在满之前主动回收「冷」的编译产物。**不要关掉它**，有人为了「保留优化」关掉它，结果反而更快触发 full。

### 8.2 减少动态类生成

```java
// 反例：每次请求都新建 ObjectMapper
ObjectMapper om = new ObjectMapper();

// 正例：单例复用，模块化注册
```

- 复用 `ObjectMapper` / `Gson` / `JSON` 实例；
- 避免在循环里做动态代理创建（例如每次调用新建 `Proxy.newProxyInstance`）；
- 检查 APM Agent 的插桩范围，只留必要的类。

### 8.3 控制反优化

- 尽量让方法参数类型稳定（少用 `Object` 泛化、慎用反射调用热点路径）；
- 检查 `-XX:TypeProfileLevel`（默认 `111`，调整需谨慎，会加大 Code Cache 压力）；
- 关注 `@Contended`、大对象、`Class.isInstance` 密集调用等易触发 deopt 的写法。

### 8.4 何时该「升级容器规格」

如果 `non-profiled` 长期 >85% 且业务无法收敛动态类，最务实的做法就是 **把 `ReservedCodeCacheSize` 提到 512MB**。这点 native 内存换来 JIT 正常工作是划算的——**注意容器内存 limit 要把它算进去**（Code Cache 属于 native memory，K8s OOMKilled 会因为非堆内存涨而触发）。

```yaml
# K8s 里的典型翻车配置
resources:
  limits:
    memory: 2Gi     # 里面 -Xmx1536m + CodeCache512m + Metaspace256m + 线程栈 = 超了
```

正确姿势：`limits ≈ -Xmx + MaxMetaspace + ReservedCodeCache + 线程栈预留 + 直接内存`。

---

## 九、面试追问合集

**Q1：Code Cache 满了会 OOM 吗？**
不会。它抛不出 `OutOfMemoryError`，只会警告并禁用编译器。但它会让性能断崖式下降，比某些 OOM 更难发现。

**Q2：为什么要分三个区，各自满了会怎样？**
`non-nmethods` 满 → 运行时存根都放不下，问题严重，通常说明参数被错误地设得太小；`profiled nmethods` 满 → C1 编译受阻，方法难以进入 C2；`non-profiled nmethods` 满 → C2 无法编译，最高优化级别缺失，性能损失最大。

**Q3：`CodeCacheFlushing` 会不会把正在执行的代码回收掉？**
不会。回收（sweeper）会把方法标记为 `not entrant`，已进入栈的旧版本仍然可以执行完（on-stack replacement / 栈上替换技术处理过渡），新调用走新版本。

**Q4：为什么关掉分层编译后默认只有 48MB？**
因为只有 C2 一层编译，产物数量大幅减少；而且很多团队关闭分层是为了让代码尽快达到 C2 最优状态（代价是启动慢）。

**Q5：为什么 APM Agent 会显著加剧 Code Cache 压力？**
它通过字节码增强给大量方法插入埋点代码，方法体变大 → 编译产物更大；同时它引入了新的合成方法（`$agent_xxx`），都是额外的方法计数。

---

## 十、小结

| 维度 | 结论 |
| --- | --- |
| 归属 | 非堆 Native Memory，不受 `-Xmx` 管辖 |
| 结构 | `non-nmethods` / `profiled nmethods` / `non-profiled nmethods` 三段 |
| 默认 | 分层编译开启时 240MB |
| 满了的后果 | 编译器禁用 + 性能劣化，不抛异常 |
| 监控 | `jcmd ... Compiler.code_heap_memory_usage`、JFR `jdk.CodeCacheFull` |
| 调优 | 提 `ReservedCodeCacheSize`、保留 flushing、减少动态类生成、控制 deopt |

记住一句话：**看 GC 日志只看 GC 是不够的，`CodeCache is full` 这条警告往往才是真正拖垮吞吐的那一根稻草。**
