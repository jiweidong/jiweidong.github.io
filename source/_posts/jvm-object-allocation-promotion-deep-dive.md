---
title: 【JVM 底层】对象分配与晋升机制深度解析：从 TLAB 到老年代的一生
date: 2026-08-15 08:00:00
tags:
  - Java
  - JVM
  - 内存
  - 面试
categories:
  - Java
  - JVM
  - 后端面试
author: 东哥
---

# 【JVM 底层】对象分配与晋升机制深度解析：从 TLAB 到老年代的一生

## 面试官：new 出来的对象一定在堆上吗？它从出生到进入老年代经历了什么？

很多同学背了"对象优先在 Eden 区分配，大对象直接进老年代"，但被追问到"什么是 TLAB？对象年龄多大晋升？动态年龄判定怎么算？空间分配担保是什么？"就卡壳了。

今天我们把一个 Java 对象的"一生"彻底讲透：**栈上分配 → TLAB → Eden → Survivor → 老年代**，每一站的原理、源码和调优参数全部覆盖。

## 一、对象分配的总览：一条完整的路径

HotSpot 中对象分配的完整决策链如下：

```
new Object()
    │
    ├─ 1. 逃逸分析：能栈上分配？ ──→ 是 → 栈上分配（方法返回即销毁）
    │       否
    ├─ 2. 能 TLAB 分配？ ──→ 是 → TLAB 内 fast-path 分配（无锁）
    │       否
    ├─ 3. 大对象（> -XX:PretenureSizeThreshold）？ ──→ 是 → 直接进老年代
    │       否
    └─ 4. Eden 区分配（CAS 或加锁兜底）
              │
              └─ Minor GC 后存活 → Survivor，年龄 +1
                        │
                        └─ 年龄达阈值 / 动态年龄判定 → 晋升老年代
```

### 1.1 逃逸分析：栈上分配的关键

JIT 编译时（C2 / Graal），编译器会分析对象是否"逃逸"出当前方法：

- 不逃逸（没有赋值给外部变量、没有作为返回值/参数传出）→ 可以**栈上分配**或**标量替换**（把对象的字段拆成局部变量）；
- 逃逸 → 只能走堆分配。

```java
// 逃逸分析示例
public class EscapeTest {
    // point 对象没有逃逸出方法，可被标量替换
    public long sum(int[] arr) {
        Point p = new Point(1, 2);  // 无逃逸：栈上分配/标量替换
        long sum = 0;
        for (int i = 0; i < arr.length; i++) {
            sum += arr[i] + p.x + p.y;
        }
        return sum;
    }

    // point 对象作为返回值，逃逸了
    public Point getPoint() {
        return new Point(1, 2);  // 逃逸：必须堆分配
    }
}
```

相关参数：`-XX:+DoEscapeAnalysis`（JDK 8 默认开启）、`-XX:+EliminateAllocations`（标量替换）、`-XX:+EliminateLocks`（锁消除）。

## 二、TLAB：线程本地分配缓冲

### 2.1 为什么需要 TLAB？

Eden 区是所有线程共享的，如果每次 new 都要 CAS 竞争 Eden 的分配指针（top），高并发下分配会成为性能瓶颈。TLAB（Thread Local Allocation Buffer）的思路是：**给每个线程在 Eden 里划一块私有区域，线程在自己区域内分配对象，无需任何同步**。

```
┌──────────────────── Eden 区 ────────────────────┐
│  TLAB(线程A) │  TLAB(线程B) │ TLAB(线程C) │ 共享区 │
└──────────────────────────────────────────────────┘
```

### 2.2 TLAB 分配流程与源码

HotSpot 的 `ThreadLocalAllocBuffer::allocate` 核心逻辑（伪代码）：

```
allocate(size):
    if (top + size <= end):      # 剩余空间够，fast path
        obj = top
        top += size
        return obj
    else:
        # slow path：尝试从 Eden 重新申请一块 TLAB
        if (refill 成功): return 在新 TLAB 中分配
        else: 降级为 Eden 共享区 CAS 分配（慢速兜底）
```

关键点：

- **TLAB 内分配是纯指针碰撞（bump-the-pointer）**，无锁，是对象分配最快的路径；
- TLAB 空间用完会**重新申请（refill）**，申请本身需要 CAS 操作 Eden 的分配指针；
- 新线程启动时并不立即创建 TLAB，而是按需 lazy 创建（`-XX:+UseTLAB` 默认开启）；
- TLAB 默认大小约等于 Eden 的 1%（`-XX:TLABWasteTargetPercent=1`），JVM 会根据线程数动态调整。

### 2.3 TLAB 的浪费问题

对象大小不可能刚好填满 TLAB，末尾会留下无法使用的碎片。对象大时（超过 TLAB 剩余空间），JVM 会判断：**如果对象本身够大，直接去 Eden 共享区分配，不再浪费 TLAB 剩余空间**（`TLABRefillWaste` 相关逻辑），避免"大对象把 TLAB 撑爆后又白白浪费整块缓冲区"。

```bash
# 观察 TLAB 使用情况
java -XX:+PrintTLAB -version
# 或
jcmd <pid> GC.heap_info
```

## 三、大对象直接进入老年代

### 3.1 为什么要直接进老年代？

大对象（如超长数组、大字符串）在 Eden 分配后，如果发生 Minor GC 时存活，需要复制到 Survivor 区。**Survivor 区本来就小（默认 Eden:Survivor = 8:1），大对象复制开销巨大**，而且大对象在 Survivor 间来回复制极耗性能。

### 3.2 参数与验证

```bash
# 设置大对象阈值：超过 3MB 直接进老年代
java -Xms256m -Xmx256m -XX:PretenureSizeThreshold=3145728 -XX:+UseSerialGC
```

> 注意：`-XX:PretenureSizeThreshold` **只对 Serial 和 ParNew 收集器生效**，G1 等收集器不支持（G1 有自己的大对象区 Humongous Region，超过 Region 大小一半的对象直接进入 Humongous 分配）。

G1 相关参数：

```bash
# Region 大小默认 1MB~32MB，超过 Region 一半的对象为 Humongous
java -XX:G1HeapRegionSize=4m
# Humongous 对象占用连续多个 Region，会造成碎片，需谨慎
```

**调优启示**：频繁创建大数组导致老年代快速增长的场景，优先考虑是否能用池化/复用代替，而不是盲目调大阈值。

## 四、Eden → Survivor → 老年代：对象晋升全流程

### 4.1 Minor GC 与对象复制

Eden 和 Survivor 采用**复制算法**：Minor GC 时，把 Eden + From Survivor 中存活的对象复制到 To Survivor，然后 Eden 和 From 一次性清空，From/To 互换。

### 4.2 年龄计数器

每个对象的对象头 Mark Word 中有一个 4 位的**分代年龄字段**（最大 15）。每熬过一次 Minor GC 存活，年龄 +1。

### 4.3 晋升阈值

默认晋升年龄阈值 `-XX:MaxTenuringThreshold=15`（Parallel 收集器默认 15，CMS 默认 6）。

```
对象年龄 = 0（Eden 出生）
   │  Minor GC 存活 → 复制到 Survivor，age=1
   │  Minor GC 存活 → 复制到另一个 Survivor，age=2
   │  ...
   └─ age >= MaxTenuringThreshold → 晋升老年代
```

### 4.4 动态年龄判定：别被阈值骗了

很多人只知道"年龄达到 15 晋升"，但 JVM 还有一条**动态年龄判定**规则（HotSpot 源码 `TenuredGeneration` 相关逻辑）：

> **如果 Survivor 中相同年龄的所有对象大小之和，超过了 Survivor 空间的一半，那么年龄大于等于该年龄的对象直接晋升老年代，无需等待阈值。**

```java
// HotSpot 源码逻辑（简化）：age_table 统计各年龄对象总大小
uint ageTable::compute_tenuring_threshold(size_t survivor_capacity) {
  size_t desired_survivor_size = (size_t)((((double)survivor_capacity) * TargetSurvivorRatio) / 100);
  size_t total = 0;
  uint age = 1;
  while (age < table_size) {
    total += sizes[age];       // 累加某年龄的对象总大小
    if (total > desired_survivor_size) {  // 超过 Survivor 目标容量一半
      return age;              // 该年龄及以上的对象直接晋升
    }
    age++;
  }
  return MaxTenuringThreshold;
}
```

`TargetSurvivorRatio` 默认 50，也就是说 Survivor 中同年龄对象超过 50% 容量就会触发提前晋升。**这是为了避免对象在 Survivor 中反复复制浪费性能**，但也意味着 Survivor 可能留不住"年龄不够但数量大"的对象。

### 4.5 空间分配担保

Minor GC 前，JVM 会检查老年代最大可用连续空间：

- **HandlePromotionFailure 开启时**：如果老年代剩余空间 > 历次 Minor GC 晋升对象的平均大小，则冒险进行 Minor GC；否则触发 Full GC；
- JDK 6u24 之后 `HandlePromotionFailure` 逻辑被简化：**只要老年代连续空间小于新生代总大小（或历次晋升平均大小），就直接 Full GC**，不再"赌"。

**实战含义**：老年代频繁 Full GC 时，除了检查老年代自身，也要排查是否因 Survivor 过小导致对象提前晋升、老年代被"挤爆"。

## 五、常用调优参数速查表

| 参数 | 作用 | 默认值 |
|------|------|--------|
| `-XX:+UseTLAB` | 开启线程本地分配缓冲 | 开启 |
| `-XX:TLABWasteTargetPercent=1` | TLAB 占 Eden 的期望百分比 | 1% |
| `-XX:+DoEscapeAnalysis` | 开启逃逸分析 | 开启 |
| `-XX:+EliminateAllocations` | 标量替换（配合逃逸分析） | 开启 |
| `-XX:PretenureSizeThreshold` | 大对象直接进老年代的阈值（仅 Serial/ParNew） | 0（不启用） |
| `-XX:MaxTenuringThreshold=15` | 最大晋升年龄 | 15（Parallel）/ 6（CMS） |
| `-XX:TargetSurvivorRatio=50` | Survivor 目标使用率（动态年龄判定） | 50% |
| `-XX:SurvivorRatio=8` | Eden:Survivor 比例 | 8 |
| `-XX:G1HeapRegionSize` | G1 Region 大小 | 1MB~32MB 自动 |

## 六、面试常见追问

**Q1：TLAB 分配的对象都在 Eden 吗？**
是的。TLAB 是 Eden 区里的逻辑划分，本质还是堆内存，只是"归属"某个线程私有。

**Q2：对象一定分配在堆上吗？**
不一定。开启逃逸分析且对象未逃逸时，可能栈上分配或被标量替换，完全不经过堆。

**Q3：大对象为什么直接进老年代？**
避免大对象在 Eden/Survivor 间反复复制产生巨大开销，同时防止大对象挤占 Survivor 空间。G1 中则进入 Humongous Region。

**Q4：动态年龄判定和 MaxTenuringThreshold 什么关系？**
两者取更早触发者。动态年龄判定是"Survivor 装不下时提前晋升"的兜底机制，阈值是"年龄上限"。

**Q5：怎么确认对象到底晋升到了哪里？**
加参数 `-XX:+PrintGCDetails -XX:+PrintTenuringDistribution`，GC 日志中会打印各年龄对象分布（`Desired survivor size`、`age 1: xxx bytes`），可以直观看到晋升行为。

## 七、小结

对象的一生可以用一句话概括：**能栈上就栈上（逃逸分析），能 TLAB 就 TLAB（无锁快路径），太大直接老年代（避免复制），否则 Eden 出生 → Survivor 历练 → 年龄够了或装不下了就晋升老年代**。理解这条链路，面试时从"对象分配在哪"一路深挖到"动态年龄判定怎么算"，都能从容应对；调优时也能快速定位"老年代暴涨"背后的真实原因。
