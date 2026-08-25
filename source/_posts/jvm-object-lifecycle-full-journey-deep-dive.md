---
title: 【JVM 实战】对象的一生：从栈上分配到老年代晋升的完整路径与 GC 触发时机
date: 2026-08-25 08:00:00
tags:
  - Java
  - JVM
  - 内存
  - GC
  - 面试
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 实战】对象的一生：从栈上分配到老年代晋升的完整路径与 GC 触发时机

## 面试官：new 出来的对象一定在堆上吗？什么情况下对象直接进老年代？

很多人以为 `new Object()` 就是"堆里分配一块内存"——**太天真了**。一个对象从诞生到被回收，要经过"栈上分配 → TLAB → Eden → Survivor → 老年代"的层层关卡，每一关都有 JVM 的参数和策略在把关。本文完整梳理一个对象的"一生"，顺便把面试里所有"什么对象进老年代"的问题一网打尽。

## 一、对象的诞生：创建流程四步走

```java
Object obj = new Object();
```

这行代码在 JVM 里经历四步：

```
1. 类加载检查：检查 Object 类是否已加载、解析、初始化（没有则触发类加载）
2. 分配内存：在堆上（或栈上）划一块空间
3. 初始化零值：把内存空间置零（obj 的字段默认值：0 / null / false）
4. 设置对象头 + 执行构造方法：设置 Mark Word（哈希码、GC 分代年龄、锁状态）、
   Klass Pointer（指向类元数据），然后调用 <init> 执行构造函数
```

## 二、内存分配方式：指针碰撞 vs 空闲列表

- **指针碰撞（Bump the Pointer）**：堆内存规整（Serial/ParNew + 标记-复制），已用/未用分界清晰，只需移动指针。**快**
- **空闲列表（Free List）**：堆内存不规整（CMS + 标记-清除），维护空闲块链表，找一块足够大的。**慢**

**并发安全怎么办？** 两种手段：① **CAS + 失败重试**（乐观锁）；② **TLAB 本地线程分配缓冲**（每个线程预分配一块私有的 Eden 空间，线程内分配无需竞争，用完了再 CAS 申请新的）。

## 三、对象的第一站：栈上分配（逃逸分析）

**关键结论：满足逃逸分析条件的对象，根本不上堆！**

```java
// 逃逸：对象被方法外引用（返回值、静态变量、传给别的线程）
public User getUser() {
    User u = new User();
    return u;          // u 逃逸了，必须分配在堆上
}

// 不逃逸：对象只在方法内使用
public long sum() {
    User u = new User();   // u 没逃逸
    u.setAge(18);
    return u.getAge();     // 对象没被外面引用
}
```

JIT 编译器（C2/Graal）做**逃逸分析**：如果对象**不逃逸**，做两件事：

1. **栈上分配**：对象直接分配在栈帧里，方法结束随栈帧弹出而销毁，**零 GC 压力**
2. **标量替换**：更激进——对象拆成多个局部变量（`int age = 18`），**连对象都不创建了**

```java
// 标量替换后，sum() 里根本没有 User 对象：
public long sum() {
    int age = 18;      // 标量替换：User 的字段变成局部变量
    return age;
}
```

> 注意：**HotSpot 目前实际做的是标量替换，而不是真正的栈上分配**（栈上分配在 Graal 等实现中有）。但面试说"逃逸分析后对象可能在栈上/被替换掉"都对。JVM 参数：`-XX:+DoEscapeAnalysis`（JDK 8 默认开启）。

**好处**：大量短命小对象（如迭代器、局部 DTO）被消灭在栈上，**大幅减少 GC 压力**——这也是为什么"对象尽量局部化"能提升性能。

## 四、堆上的第一站：TLAB → Eden

逃逸失败的对象进堆。分配顺序：

```
Eden 区（新生代，占 8/10）
  └─ 优先在 TLAB（线程私有 Eden 子空间）分配 → 无锁、最快
      └─ TLAB 不够 → 尝试直接分配在 Eden（CAS 竞争）
          └─ Eden 不够 → 触发 Minor GC（或大对象直接进老年代）
```

**为什么新生代要分 Eden + 两个 Survivor（8:1:1）？**
因为**绝大多数对象朝生夕死**（IBM 统计 98% 的对象活不过第一轮 GC）。标记-复制算法只复制存活对象，Eden 清空后留下的碎片极小。**两个 Survivor 轮换（from/to）**保证复制时有一块干净的目的地，避免内存碎片。

## 五、晋升之路：Survivor 与老年代

### 1. 年龄计数器：熬过一轮 Minor GC，年龄 +1

```java
// 对象头 Mark Word 里有 4 位分代年龄（最大 15）
// 每次 Minor GC 幸存：年龄 +1
// 年龄 ≥ MaxTenuringThreshold（默认 15）→ 晋升老年代
```

### 2. 动态年龄判定（容易被忽略）

**不是非得熬到 15 岁**。HotSpot 规则：**Survivor 中相同年龄所有对象大小总和 > Survivor 空间的一半**，年龄 ≥ 该年龄的对象**直接晋升老年代**。防止 Survivor 塞满后频繁复制。

### 3. 大对象直接进老年代（`-XX:PretenureSizeThreshold`）

**超过阈值（默认 0，即不启用；设置如 1MB）的大对象直接进老年代**：

```java
byte[] big = new byte[2 * 1024 * 1024];   // 2MB 大对象 → 直接老年代
```

**为什么？** 大对象在 Eden 里复制代价高（Eden→Survivor 要复制一整块大内存），且容易触发提前 GC。直接进老年代用**标记-整理/标记-清除**处理，避免新生代复制开销。

### 4. 分配担保（Handle Promotion Failure）

Minor GC 前，JVM 检查老年代**最大连续空间**是否大于新生代所有对象总大小：

- 大于 → Minor GC 安全
- 小于且 `HandlePromotionFailure` 允许 → 冒险 Minor GC（老年代可能放不下晋升对象，失败则触发 Full GC）
- 不允许 → 直接升级为 **Full GC**（老年代空间不够，全堆回收）

## 六、GC 触发时机全景

| GC 类型 | 触发条件 | 回收范围 | 停顿 |
|---------|----------|----------|------|
| **Minor GC（Young GC）** | Eden 空间不足 | 新生代 | 短（毫秒级） |
| **Major GC（Old GC）** | 老年代空间不足（CMS 等） | 老年代 | 较长 |
| **Full GC** | 老年代不足 / 元空间不足 / System.gc() / 分配担保失败 / CMS concurrent mode failure | 全堆 + 方法区 | 长（秒级，尽量少触发） |

**调优核心思路**：**Full GC 是万恶之源**。调优的目标就是"让对象死在新生代"——调大新生代、合理设置晋升阈值、减少大对象、避免 System.gc()（用 `-XX:+DisableExplicitGC` 屏蔽）。

## 七、实战：看 GC 日志验证对象的一生

```bash
java -Xms256m -Xmx256m -Xmn128m -XX:SurvivorRatio=8 \
     -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:gc.log \
     -jar myapp.jar
```

```text
[GC (Allocation Failure) [PSYoungGen: 98304K->8192K(112640K)] 
 98304K->8320K(256000K), 0.0032 secs]   ← Minor GC：Eden 满，存活对象进 Survivor
[Full GC (Allocation Failure) [PSYoungGen: 8192K->0K(112640K)]
 [ParOldGen: 101888K->102400K(143360K)] 256000K->102400K(256000K), 0.5120 secs]
                                          ← Full GC：老年代也满了，全堆回收
```

**日志解读**：`PSYoungGen: 前->后(总)`，前后差值就是本次回收量。如果日志里 **Full GC 频繁**，说明老年代一直在涨——检查是否有大对象、缓存无界、晋升过快（动态年龄判定生效）。

## 八、面试高频追问

**Q1：new 的对象一定在堆上吗？**
不一定。逃逸分析后不逃逸的对象会被**标量替换**（拆成局部变量）或栈上分配，根本不创建堆对象。这解释了很多性能优化场景。

**Q2：什么对象会直接进老年代？**
① 超过 `PretenureSizeThreshold` 的大对象；② 年龄 ≥ `MaxTenuringThreshold`（默认 15）的幸存者；③ 动态年龄判定（同龄对象总大小超 Survivor 一半）触发的提前晋升；④ **分配担保失败时**（新生代放不下）。

**Q3：为什么要分代？为什么新生代要两个 Survivor？**
分代：绝大多数对象朝生夕死，用复制算法低成本回收；少数长命对象进老年代，用标记-整理避免反复复制。两个 Survivor：**复制算法需要一块干净的目的地**（from/to 轮换），同时保证不产生碎片。

**Q4：Minor GC 和 Full GC 哪个更该优化？**
Full GC。Minor GC 毫秒级、频繁但便宜；Full GC 秒级停顿、影响所有线程。**所有 JVM 调优最终都是"减少 Full GC 次数"**。

**Q5：Survivor 区太小会怎样？**
幸存对象放不下，触发**动态年龄判定**提前晋升老年代 → 老年代增长快 → Full GC 频繁。调优时 Survivor 太小是常见坑（`SurvivorRatio` 默认 8，可调成 4 甚至 2）。

**Q6：对象在 Survivor 间复制多少次？**
每次 Minor GC 幸存年龄 +1，默认到 15 晋升；但动态年龄判定可能提前。Mark Word 里年龄字段只有 4 位，**最大 15**——所以 `MaxTenuringThreshold` 超过 15 的配置是无效的（老版本有这个坑）。

## 九、JVM 内存分配相关参数速查表（面试默写清单）

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `-Xms / -Xmx` | 物理内存 1/64 | 堆初始/最大大小（生产务必相等，避免扩容抖动） |
| `-Xmn` | 堆 1/3 | 新生代大小（含 Eden + 两个 Survivor） |
| `-XX:SurvivorRatio` | 8 | Eden : Survivor = 8 : 1 : 1 |
| `-XX:MaxTenuringThreshold` | 15 | 晋升老年代的年龄阈值（最大 15，因为 Mark Word 只有 4 位） |
| `-XX:PretenureSizeThreshold` | 0（不启用） | 超过该大小的大对象直接进老年代 |
| `-XX:+UseTLAB` | 开启 | 线程本地分配缓冲，减少 Eden 分配竞争 |
| `-XX:+DoEscapeAnalysis` | 开启 | 逃逸分析（标量替换/栈上分配的开关） |
| `-XX:+DisableExplicitGC` | 关闭 | 屏蔽 `System.gc()`（防止线上被误触发 Full GC） |
| `-XX:+PrintGCDetails` | 关闭 | 打印 GC 详情（配合 `-Xloggc` 落盘分析） |

### 经典调优案例

**现象**：线上服务每分钟一次 Full GC，每次停顿 2s，接口超时率飙升。

**排查**：

```bash
# 1. 看 GC 日志，确认 Full GC 触发原因
# 2. jmap -histo 看老年代里什么对象最多
jmap -histo:live <pid> | head -20
# 3. 发现：某缓存 Map 无限增长，容量已达老年代一半
```

**根因**：一个 `static Map` 缓存了所有用户会话且无淘汰策略 → 大量长命对象进老年代 → 老年代满触发 Full GC。

**修复**：

1. 缓存加容量上限 + LRU 淘汰（用 Caffeine/Guava Cache）
2. 大对象用 `-XX:PretenureSizeThreshold` 引导进老年代避免新生代反复复制
3. 调大新生代 `-Xmn`，让短命对象死在 Eden
4. 加 `-XX:+DisableExplicitGC` 防止框架代码里残留的 `System.gc()`

**结果**：Full GC 从每分钟一次降到每天 1-2 次，接口 P99 下降 60%。**调优永远是"先找根因，再动参数"，盲目调参是玄学。**

## 十、总结

**对象的完整一生**：

```
new Object()
  ├─ 逃逸分析：不逃逸 → 标量替换/栈上分配（零 GC）✅
  └─ 逃逸 → 堆
        ├─ TLAB（线程私有，无锁）→ Eden
        │    └─ Eden 满 → Minor GC
        │         ├─ 幸存 → Survivor（年龄+1，动态判定可提前晋升）
        │         └─ 年龄≥15 或大对象 → 老年代
        └─ 老年代满 → Major/Full GC → 回收（标记-整理/清除）
```

**面试一句话**："对象先过逃逸分析这关（不逃逸就标量替换，不上堆），上堆的走 TLAB 进 Eden，Minor GC 幸存者按年龄和动态判定晋升老年代，大对象和晋升阈值对象直接进老年代；调优的本质就是让对象尽量死在新生代，减少 Full GC。"——背熟这句，JVM 内存题稳了。
