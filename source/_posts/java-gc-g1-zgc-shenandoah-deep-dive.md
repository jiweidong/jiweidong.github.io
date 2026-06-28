---
title: 「JVM 垃圾收集器深度对比」G1、ZGC 与 Shenandoah 核心原理与调优实践
date: 2026-06-28 08:00:00
tags:
  - Java
  - JVM
  - GC
  - 性能优化
categories:
  - Java
  - JVM
author: 东哥
---

# 「JVM 垃圾收集器深度对比」G1、ZGC 与 Shenandoah 核心原理与调优实践

从 Serial 到 ZGC，Java 垃圾收集器已经发展了近三十年。面对低延迟还是高吞吐的抉择，我们常常陷入选择困难。本文系统梳理 G1、ZGC 和 Shenandoah 三大主流收集器的核心原理、关键参数和调优实践。

---

## 一、GC 发展的演进路线

```
Serial (单线程, STW)
  │
  ├── ParNew (多线程年轻代)
  │     └── Parallel Scavenge (吞吐量优先)
  │
  ├── Parallel Old (老年代并行)
  │
  └── CMS (并发低延迟) ──→ G1 (分区化, 可预测停顿)
                                  │
                                  ├── ZGC (超低延迟, 不分区)
                                  │
                                  └── Shenandoah (并发压缩)
```

### GC 核心指标

| 指标 | 说明 | 追求方向 |
|------|------|---------|
| 吞吐量（Throughput） | 应用时间 / (应用时间+GC时间) | 越高越好 |
| 停顿时间（Latency） | GC 导致 STW 的时间 | 越短越好 |
| 内存占用（Footprint） | GC 消耗的额外内存 | 越小越好 |
| 可扩展性（Scalability） | 能支持多大的堆 | 越大越好 |

这三者构成了**不可能三角**：低延迟、高吞吐、小内存占用，最多只能同时满足两项。

---

## 二、G1 GC——区域化与可预测停顿

G1（Garbage First）自 JDK 7u4 引入，JDK 9 成为默认收集器。它将堆划分为多个大小相等的 Region，每次收集优先回收垃圾最多的 Region（Garbage First 的由来）。

### 2.1 内存布局

```
┌─────────────────────────────────────────────┐
│  Heap (分 Region，每块约 1~32MB)              │
│                                              │
│  [E][E][E][S][S][O][O][O][O][H][H]          │
│  [E][E][E][O][O][O][O][O][H][H][H]          │
│  [E][E][S][O][O][O][O][O][H][H][H]          │
│  [E][E][E][O][O][O][O][O][O][H][H]          │
│                                              │
│  E = Eden      S = Survivor                  │
│  O = Old       H = Humongous (大对象)         │
└─────────────────────────────────────────────┘
```

Region 大小计算公式：
```
Region Size = Heap Size / 2048
但限制在 1MB ~ 32MB 之间
Region 数量通常为 2048 左右
```

### 2.2 G1 收集周期

**年轻代 GC（Young GC）**：当 Eden 区满时触发，所有活对象复制到 Survivor 或直接晋升到 Old，**STW 但极短**。

**并发标记周期（Concurrent Marking）**：
```
初始标记 (Initial Mark)    [STW, 很短]
    │
    ▼
并发标记 (Concurrent Mark) [与应用并发执行]
    │
    ▼
最终标记 (Final Mark)      [STW, 很短]
    │
    ▼
筛选回收 (Live Data Counting & Cleanup) [STW, 可预测]
```

**混合回收（Mixed GC）**：标记完成后，会回收部分老年代 Region + 全部年轻代 Region。

**Full GC**：当并发标记来不及回收（对象分配太快）时，G1 退化到 Serial Old 做 **单线程 Full GC**——这是 G1 最需要避免的场景。

### 2.3 Remembered Set（RSet）与写屏障

G1 的核心挑战之一是解决跨 Region 引用。对象在 Region A，被 Region B 引用——如果 GC 只回收 Region A，怎么知道它还被引用着？

G1 使用 **RSet（Remembered Set）** 维护其他 Region 对当前 Region 的引用：

```
Region A 的 RSet:
  → Region B 的 Card 0x123
  → Region C 的 Card 0x456
  → Region D 的 Card 0x789
```

**写屏障（Write Barrier）**：当代码修改一个引用时，JIT 插入的屏障代码会记录该引用变更：

```java
// Java 代码
obj.field = newValue;

// JIT 编译后插入的写屏障（伪代码）
obj.field = newValue;
// 检查目标对象和源对象是否在不同 Region
if (card_for(obj).region != card_for(newValue).region) {
    // 记录到目标 Region 的 RSet
    newValue.getRegion().rset.add(card_for(obj));
}
```

G1 使用 **卡表（Card Table）** + **RSet** 双重结构，RSet 的实际存储会经过压缩（PRT = Per Region Table），使用位图和稀疏表来节省内存。

### 2.4 G1 关键 JVM 参数

| 参数 | 说明 | 建议值 |
|------|------|--------|
| -XX:+UseG1GC | 启用 G1 | JDK 9+ 默认 |
| -XX:MaxGCPauseMillis | 目标最大停顿时间 | 100~200ms |
| -XX:G1HeapRegionSize | Region 大小 | 自动计算 |
| -XX:G1NewSizePercent | 年轻代初始占比 | 默认 5% |
| -XX:G1MaxNewSizePercent | 年轻代最大占比 | 默认 60% |
| -XX:G1HeapWastePercent | 允许浪费的堆百分比 | 默认 5% |
| -XX:G1MixedGCLiveThresholdPercent | Mixed GC 中存活对象阈值 | 默认 85% |
| -XX:+G1PrintHeapRegions | 打印 Region 信息 | 调试用 |
| -XX:G1ReservePercent | 预留空间（防晋升失败） | 默认 10% |

**调优口诀**：先调 MaxGCPauseMillis，再看日志调大小。

### 2.5 G1 调优案例分析

**案例：100ms → 50ms 停顿优化**

```log
// 优化前 GC 日志
2026-06-28T10:00:00.123+0800: [GC pause (G1 Evacuation Pause) (young)
  Desired threshold: 100ms → Actual: 120ms (超时了)
```

**分析**：年轻代 GC 超时是因为 Eden 太大，一次性复制对象太多。

**优化方案**：
```bash
# 减小年轻代最大值，让 GC 更频繁但更短
-XX:G1MaxNewSizePercent=40
# 增加并发标记线程
-XX:ConcGCThreads=4
# 设置更积极的停顿目标
-XX:MaxGCPauseMillis=50
```

---

## 三、ZGC——超低延迟的杰作

ZGC（The Z Garbage Collector）从 JDK 11 实验性引入，JDK 15 生产可用，JDK 21 已经非常成熟。

### 3.1 核心特性

| 特性 | 说明 |
|------|------|
| 最大 STW 时间 | &lt; 10ms（无论堆多大）|
| 最大堆大小 | 支持 TB 级别 |
| 并发整理 | 所有阶段几乎完全并发 |
| 压缩指针 | 使用 64 位指针的地址空间（染色指针）|

**核心设计哲学**：GC 停顿时间不随堆大小增长，O(1) 级别的 STW。

### 3.2 ZGC 的核心创新：染色指针（Colored Pointer）

这是 ZGC 最巧妙的设计。在 64 位系统中，ZGC 将指针的高位用于存储标记信息：

```
|0000|0000-0000|0000-0000|0000-0000|0000-0000|0000-0000|0000-0000|0000-0000|
| M0 | M1 | Remapped | Finalizable |                         Object Address |
```

- **M0 / M1**：标记位（Mark Bit）。ZGC 使用两个标记位，标记周期交替使用
- **Remapped**：重映射位。标记对象是否已被重映射到新地址
- **Finalizable**：表示对象是否只被 Finalizer 引用

**好处**：对象引用本身记录了 GC 状态，不需要额外的标记位图。加载引用时通过位运算检查状态：

```c
// 伪代码：引用加载时的位测试
void* load_reference(void* colored_ptr) {
    if (colored_ptr & (M0 | M1 | Remapped) == 0) {
        return colored_ptr;  // 好指针，无需处理
    }
    // 需要自愈（Self-Healing）
    return remap_or_mark(colored_ptr);
}
```

**自愈（Self-Healing）**：当应用线程加载一个"坏"指针时，ZGC 会自动修复这个指针，后续访问不需要再修复。这是 ZGC 性能的关键——GC 停顿不随堆增长。

### 3.3 ZGC 的收集周期

```
并发标记 (Concurrent Mark)
    │
    ▼
并发预备重映射
    │
    ▼
并发重分配 (Concurrent Relocation)
    │
    ▼
初始标记 (Initial Mark)       [STW, < 1ms]
并发标记 (Concurrent Mark)     [主体]
最终标记 (Final Mark)         [STW, < 1ms]
并发重分配准备                 
并发重分配 (Relocation)       [主体]
```

```log
// ZGC 实际 GC 日志
[2023-06-01T10:00:00.000+0800] GC(0) Garbage Collection (Proactive)
[2023-06-01T10:00:00.000+0800] GC(0) Pause Mark Start 0.214ms  // STW: 0.2ms
[2023-06-01T10:00:00.002+0800] GC(0) Concurrent Mark 1.856ms
[2023-06-01T10:00:00.002+0800] GC(0) Pause Mark End 0.132ms   // STW: 0.13ms
[2023-06-01T10:00:00.003+0800] GC(0) Concurrent Process Non-Strong References 0.534ms
[2023-06-01T10:00:00.003+0800] GC(0) Concurrent Reset Relocation Set 0.002ms
[2023-06-01T10:00:00.004+0800] GC(0) Concurrent Select Relocation Set 0.812ms
[2023-06-01T10:00:00.004+0800] GC(0) Pause Relocate Start 0.151ms  // STW: 0.15ms
[2023-06-01T10:00:00.007+0800] GC(0) Concurrent Relocate 2.891ms
```

可以看到，三次 STW 事件加起来不到 **0.5ms**，对于 16GB 堆来说非常惊人。

### 3.4 G1 vs ZGC 性能对比

| 场景 | G1 平均延迟 | ZGC 平均延迟 | 吞吐量对比 |
|------|-----------|------------|----------|
| 小型堆 (4GB) | 50~100ms | 2~5ms | ZGC≈G1 |
| 中型堆 (16GB) | 100~200ms | 2~10ms | ZGC≈G1（-3~5%）|
| 大型堆 (128GB) | 300~1000ms | 3~10ms | ZGC略低于G1（-5~10%）|

**延迟差距随堆大小扩大而急剧拉大**，但吞吐量 ZGC 略逊于 G1（约 3~10%）。

---

## 四、Shenandoah——另一种低延迟选择

Shenandoah 是 Red Hat 贡献给 OpenJDK 的另一款低延迟收集器，JDK 12 引入实验性，JDK 15 生产可用。

### 4.1 与 ZGC 的核心差异

| 维度 | ZGC | Shenandoah |
|------|-----|-----------|
| 指针方案 | 染色指针（指针高位存标记）| 传统指针 + 额外位图/Forwarding 指针 |
| 内存开销 | 需额外地址空间 | 无额外地址开销 |
| 硬件要求 | 64 位（不支持 32 位） | 32/64 皆可 |
| 并发压缩 | 通过重分配 | 通过 **Brooks Pointer** |

### 4.2 Brooks Pointer（转发指针）

Shenandoah 在对象头前增加了一个**转发指针**（Brooks Pointer）：

```
Before对象布局:
|---- Mark Word ----|---- Klass Pointer ----|---- Fields ----|

Shenandoah对象布局:
|-- ForwardingPtr --|---- Mark Word ----|---- Klass ----|---- Fields ----|
```

- 对象的 Brooks Pointer 指向自身（未被移动时）
- 当对象被移动后，Brooks Pointer 指向新的地址
- 所有读取对象的引用，都要**多一次间接跳转**

```java
// 读取字段的伪代码（Shenandoah 写屏障）
obj.field = value;
// 实际上编译为：
Object actualObj = obj.brooks;  // 解引用转发指针
actualObj.field = value;
```

### 4.3 启用参数

```bash
# ZGC
-XX:+UseZGC
-XX:ZAllocationSpikeTolerance=2.0  # 分配波动容忍度

# Shenandoah
-XX:+UseShenandoahGC
-XX:ShenandoahGCHeuristics=adaptive  # 启发式策略
```

---

## 五、如何选择 GC？

### 决策树

```
你的应用对延迟敏感吗？
├── 否 → Parallel GC（吞吐量优先）
│       -XX:+UseParallelGC -XX:+UseParallelOldGC
│       适合：批处理、大数据离线计算、后台任务
│
└── 是 → 堆大小和延迟要求？
    ├── 堆 < 4GB，延迟 < 100ms → G1
    │       -XX:+UseG1GC -XX:MaxGCPauseMillis=100
    │       适合：大多数Web服务
    │
    ├── 堆 4GB~100GB，延迟 < 10ms → ZGC
    │       -XX:+UseZGC
    │       适合：金融交易、实时系统、高并发网关
    │
    └── 堆 > 100GB，延迟 < 10ms
        ├── ZGC（内存充足，稳定性要求高）
        └── Shenandoah（对内存开销敏感）
```

### 实战配置推荐

```bash
# Web 服务（16GB, G1）
java -Xms8g -Xmx16g \
     -XX:+UseG1GC \
     -XX:MaxGCPauseMillis=100 \
     -XX:G1HeapRegionSize=4m \
     -XX:+PrintGCDetails -Xloggc:gc.log \
     -jar app.jar

# 高并发网关（32GB, ZGC）
java -Xms16g -Xmx32g \
     -XX:+UseZGC \
     -XX:ConcGCThreads=4 \
     -Xlog:gc*:gc.log \
     -jar app.jar

# 批处理（64GB, Parallel）
java -Xms32g -Xmx64g \
     -XX:+UseParallelGC \
     -XX:ParallelGCThreads=16 \
     -jar batch.jar
```

---

## 六、总结

| 收集器 | 核心特点 | 适合场景 | 最大堆 | 典型 STW |
|--------|---------|---------|-------|---------|
| Parallel | 高吞吐，低 CPU 开销 | 批处理、离线计算 | 大 | 秒级 |
| G1 | 可预测停顿，区域化 | 大多数 Web 服务 | 中-大 | 50~200ms |
| ZGC | 超低延迟，TB级堆 | 金融、实时 | 极大 | &lt;10ms |
| Shenandoah | 并发压缩，低开销 | 对内存敏感的低延迟场景 | 大 | &lt;10ms |

**选型建议**：如果不是特别清楚需求，JDK 17+ 默认的 G1 已经够好了。如果你追求极限低延迟且内存充裕，ZGC 是最佳选择。如果需要极致吞吐量且可以接受较长的停顿，Parallel GC 仍然有价值。
