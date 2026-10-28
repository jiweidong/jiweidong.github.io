---
title: 【JVM 深挖】G1 大对象分配全链路：Humongous Region、TLAB 与 PLAB 的底层机制
date: 2026-10-28 09:00:00
tags:
  - Java
  - JVM
  - G1
  - GC
  - 性能调优
categories:
  - JVM
author: 东哥
---

# 【JVM 深挖】G1 大对象分配全链路：Humongous Region、TLAB 与 PLAB

## 前言

线上有个服务，堆 8G，G1，平时 Young GC 40ms，一切正常。某天加了个「批量导出」功能，一次查 20 万条记录塞进 `ArrayList`，GC 日志开始出现：

```
[GC pause (G1 Evacuation Pause) (young) 812M->790M(8192M), 0.4123456 secs]
[GC pause (G1 Humongous Allocation) (young) 790M->1200M(8192M), 0.6123456 secs]
[GC pause (G1 Evacuation Pause) (mixed) 1200M->1180M(8192M), 0.9876543 secs]
```

注意第二行的 `(G1 Humongous Allocation)`——这不是普通的 Young GC，是**大对象直接触发**的回收。再往后就是 `to-space exhausted`，然后 Full GC，接口全线超时。

大多数人知道「大对象进老年代」，但说不清：

- 多大的对象算 Humongous？阈值怎么算？
- Humongous 对象为什么会导致 Full GC？
- TLAB 和 PLAB 分别解决什么问题？跟大对象什么关系？
- `-XX:G1HeapRegionSize` 该不该调？

这篇文章把 G1 的**分配路径**从头走一遍：TLAB → Eden → Humongous，以及对象晋升时的 PLAB。理解了分配，才能理解 GC 日志里那些莫名的停顿。

## 一、G1 的堆布局：Region 是一切的度量单位

G1 把堆切成大小相等的 Region（默认 2048 个左右）：

```
堆 = N × RegionSize
RegionSize 默认 = 堆大小 / 2048，向上取 2 的幂，范围 [1MB, 32MB]
```

| 堆大小 | 默认 RegionSize | Region 数量 |
|---|---|---|
| 2GB | 1MB | 2048 |
| 4GB | 2MB | 2048 |
| 8GB | 4MB | 2048 |
| 16GB | 8MB | 2048 |
| 32GB | 16MB | 2048 |
| 64GB | 32MB | 2048 |

每个 Region 在任意时刻属于一种角色：

- **Eden** / **Survivor** / **Old**（常规对象）
- **Humongous**（大对象专用）
- **Free**（空闲）

Region 角色是**动态**的，这是 G1 相比 CMS 最大的不同——不需要连续的 Young/Old 空间，回收时按 Region 粒度挑「垃圾最多」的那些（Garbage First 的名字由来）。

**关键推论：RegionSize 决定了「多大算大对象」。**

```java
// G1 判定 Humongous 的条件
boolean isHumongous(size_t wordSize) {
    return wordSize > (regionSize() / 2);   // 超过 Region 一半
}
```

所以：

- RegionSize = 4MB → 对象 ≥ 2MB 就是 Humongous；
- RegionSize = 32MB → 对象 ≥ 16MB 才算。

**这意味着同一个对象，在不同堆大小下待遇完全不同。** 一个 3MB 的 `byte[]`，在 8G 堆（Region 4MB）里是 Humongous，在 64G 堆（Region 32MB）里是普通对象。这个反直觉的结论是很多「压测环境没问题、生产环境炸」的根因。

## 二、普通对象的分配路径：TLAB 是第一站

### 2.1 为什么要 TLAB

多线程同时 `new Object()`，如果都从同一个 Eden 顶部指针分配，就必须加锁（CAS 或全局锁）。JVM 的解法是**给每个线程划一小块私有区域**——TLAB（Thread Local Allocation Buffer）。

```
Eden Region
┌──────────────────────────────────────────────┐
│ TLAB-Thread1 │ TLAB-Thread2 │ TLAB-Thread3 │ 剩余空间 │
└──────────────────────────────────────────────┘
```

线程内分配 = 指针加法（`top += size`），**完全无锁**。只有 TLAB 用完需要 refill 时，才去 Eden 里再抢一块（这时候才需要 CAS）。

### 2.2 一次分配的完整判断链

`HotSpot` 的 `InstanceAllocator::allocate` 简化后：

```cpp
// 1. 先试 TLAB 快速路径
if (tlab->remaining() >= size) {
    obj = tlab->allocate(size);        // 指针碰撞，几纳秒
    return obj;
}

// 2. TLAB 不够，尝试分配新的 TLAB（慢路径）
if (tlab->refill(size)) {
    obj = tlab->allocate(size);
    return obj;
}

// 3. TLAB 分配失败，走共享 Eden（需要 CAS）
obj = eden->allocate(size);
if (obj == nullptr) {
    // 4. Eden 满，触发 Young GC
    collect(GCCause::_allocation_failure);
    // 5. GC 后重试
}
```

**TLAB 的「浪费」是设计的一部分。** 每个 TLAB 尾部可能有几十字节到几 KB 用不掉（放不下下一个对象），这部分叫 **TLAB waste**。JVM 用 `-XX:TLABWasteTargetPercent`（默认 1%）控制「允许的浪费比例」——浪费超过 1%，就缩小 TLAB 大小；浪费很少，就扩大 TLAB。这是自适应逻辑。

相关参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-XX:+UseTLAB` | true | 是否启用 TLAB |
| `-XX:TLABSize` | 0（自适应） | 初始 TLAB 大小，0 表示由 JVM 估算 |
| `-XX:MinTLABSize` | 2048 | TLAB 最小字节数 |
| `-XX:TLABWasteTargetPercent` | 1 | 允许的浪费百分比 |
| `-XX:TLABRefillWasteFraction` | 64 | 单次 refill 允许浪费 1/64 |

**什么时候该关注 TLAB？**

- 分配极快、对象极小（比如日志、DTO 转换）→ TLAB 命中率高，几乎无锁，很好；
- **线程数远大于 CPU 核数** → 每个线程的 TLAB 都很小，频繁 refill，反而增加 Eden 竞争；
- **大对象多** → 大对象**永远不走 TLAB**（TLAB 通常只有几百 KB，放不下），直接走 Humongous 路径。

最后这条是重点：**TLAB 优化的是小对象，对大对象完全无效。** 所以「加大 TLAB」从来不能解决大对象问题。

### 2.3 大对象为什么绕过 TLAB

`InstanceAllocator` 里有明确判断：

```cpp
if (size > tlab->max_size() || is_humongous(size)) {
    // 直接走 Humongous 或 Eden 慢路径
}
```

原因很直白：TLAB 是从 Eden 里切的一小块，如果允许大对象进 TLAB，一个对象就把 TLAB 撑爆，还会造成巨大的内部碎片。所以大对象必须「整块」分配——这就是 Humongous Region 的由来。

## 三、Humongous 分配：连续 Region 的代价

### 3.1 分配规则

```
对象大小 size
需要 Region 数 = ceil(size / RegionSize)

如果 size < RegionSize：
    找一个 Free Region，整个 Region 给这个对象（内部碎片！）
如果 size >= RegionSize：
    找一段连续的 N 个 Free Region
```

关键点：**Humongous 对象必须占用「连续的」Region**。

举例：RegionSize = 4MB，分配一个 5MB 的数组：

- 需要 2 个连续 Region（8MB）；
- 实际只用 5MB，**浪费 3MB（37.5%）**；
- 这两个 Region 标记为 `starts humongous` / `continues humongous`。

如果堆里碎片化严重（Free Region 分散），即使总空闲空间够，也可能**找不到连续 Region**，直接触发 GC 甚至 Full GC。这就是日志里 `(G1 Humongous Allocation)` 的来源。

### 3.2 Humongous 对象直接进老年代

```cpp
// G1CollectedHeap::humongous_obj_allocate
HeapWord* G1CollectedHeap::humongous_obj_allocate(size_t word_size, ...) {
    // 1. 在 Free Region 列表里找连续区间
    // 2. 分配
    // 3. 标记为 Humongous，且逻辑上属于 Old Gen
}
```

注意最后一句：**Humongous 对象不经过 Eden/Survivor，直接算老年代对象**。这意味着：

- 它不会经历「Young GC 多次晋升」的过程；
- 它的回收只能在 **并发标记周期**（mixed GC）或 **Full GC** 时发生；
- 如果它一直有引用（比如被静态集合持有），就会长期占着 Region。

### 3.3 为什么 Humongous 会导致 Full GC

这是最需要讲清楚的一条链路：

```
1. 业务持续分配大对象（比如每请求一个 8MB 的缓冲）
2. Humongous Region 快速消耗 Free Region
3. Eden 变小 → Young GC 更频繁 → 每次 Young GC 都在找连续 Region
4. 并发标记周期来不及完成（或者根本没触发）
5. Free Region 不足以分配新的 Humongous → 触发 Full GC
6. Full GC 是单线程/少线程的，停顿可能是秒级
```

G1 有一个优化参数：

```
-XX:+G1EagerReclaimHumongousObjects    # 默认 true
```

它在 Young GC 时会**顺便检查**那些「看起来没人引用」的 Humongous Region，如果确认无引用就立即回收。这个「eager reclaim」能显著缓解问题，但它有个前提：**对象必须是「死亡且可判定」的**。如果 Humongous Region 里的对象还被并发标记标记为 alive（哪怕是上个周期的旧标记），就不能回收。

所以真正的高危场景是：

- 大对象**生命周期长**（缓存、连接池、静态 Map）；
- 大对象**分配速率高**（每个请求都 new 一个大数组）；
- **堆碎片化**（Free Region 不连续）。

三者叠加，Full GC 几乎必然发生。

### 3.4 怎么定位

打开详细日志：

```bash
-XX:+UseG1GC
-Xlog:gc*=info,gc+heap=debug:file=/var/log/gc.log:time,uptime,level,tags:filecount=5,filesize=50m
```

关键日志特征：

```
[info][gc,heap] GC(123) Humongous regions: 412->408
[info][gc     ] GC(124) Pause Young (Concurrent Start) (G1 Humongous Allocation) 7800M->7600M(8192M) 45.123ms
[info][gc,ergo] GC(125) To-space exhausted
```

`Humongous regions: 412` 表示有 412 个 Region 被大对象占用。如果这个数字持续上涨不下降，就是泄漏或分配过量。

用 `jcmd` 看实时分布：

```bash
jcmd <pid> GC.heap_info
```

输出里的 `garbage-first heap total 8388608K, used ...` 配合 `jmap -histo:live` 能定位到具体的类：

```bash
jmap -histo:live <pid> | head -20
```

如果看到 `[B`（byte 数组）占了几个 G，基本就是缓冲区/大文件/序列化问题。

### 3.5 解决方案（按优先级）

**方案一：从源头消除大对象（唯一根治）**

```java
// ❌ 一次查 20 万条，构造巨型 List
List<Order> all = orderMapper.selectAll();

// ✅ 分批，每批 1000 条
int pageSize = 1000;
long lastId = 0;
while (true) {
    List<Order> batch = orderMapper.selectByCursor(lastId, pageSize);
    if (batch.isEmpty()) break;
    process(batch);
    lastId = batch.get(batch.size() - 1).getId();
    // 流式写出，不累积
}
```

导出场景优先用**游标 + 流式写**（`StreamingResponseBody` 或 EasyExcel 的 `SXSSF`），永远不要把全量数据堆在堆里。

**方案二：复用缓冲区**

```java
// ❌ 每个请求 new 一个 8MB 数组
byte[] buffer = new byte[8 * 1024 * 1024];

// ✅ 池化
private static final int BUFFER_SIZE = 8 * 1024 * 1024;
private final ThreadLocal<byte[]> bufferHolder =
        ThreadLocal.withInitial(() -> new byte[BUFFER_SIZE]);
```

代价是内存常驻，要算清楚「线程数 × 缓冲区大小」。100 个线程 × 8MB = 800MB，很危险。更稳的是用 `PooledByteBufAllocator`（Netty）或直接用堆外内存。

**方案三：调大 RegionSize**

```
-XX:G1HeapRegionSize=16m
```

Region 变大，Humongous 阈值从 2MB 提到 8MB，那些 3~7MB 的对象就不再是 Humongous 了。

代价：

- Region 数量变少（大 Region 回收粒度粗，Mixed GC 的「精确打击」能力下降）；
- 每个 Humongous 对象的内部碎片更大（最大可能浪费 15MB）；
- 大 Region 回收一次的耗时会变长。

经验：**只在「确实有大量 2~8MB 的稳定大对象」时才调**，而且优先考虑方案一。

## 四、PLAB：晋升时的「TLAB」

Young GC 时，存活对象要从 Eden/Survivor 复制到 Survivor/Old。如果所有 GC 线程都往同一个目标 Region 里复制，同样需要加锁。

解法一样：**每个 GC 线程先在目标空间里划一块私有缓冲**——PLAB（Promotion Local Allocation Buffer）。

```
Survivor Region
┌──────────────────────────────────────────┐
│ PLAB-GCThread1 │ PLAB-GCThread2 │ 剩余   │
└──────────────────────────────────────────┘
```

PLAB 的特点：

1. **只在 GC 期间存在**，GC 结束就废弃；
2. **大小自适应**：JVM 根据「每个 PLAB 里浪费了多少」动态调整，目标是让 waste 小于 1%（`-XX:PLABWeight`? 实际是内部 ergonomics）；
3. **大对象不走 PLAB**：Humongous 对象直接整 Region 分配，不参与复制（G1 对 Humongous 的处理是「原地保留」或「整 Region 迁移」）。

GC 日志里能直接看到 PLAB 的浪费：

```
[debug][gc,plab] GC(123) PLAB: 1024 used, 12 wasted, 1 undo_waste
```

如果 `wasted` 占比很高，说明 PLAB 太大或对象大小不均，JVM 会自动缩小。**这一层基本不需要人工调参**，但知道它的存在，能解释「为什么 Young GC 里偶尔有几十 KB 的空间用不上」。

## 五、完整分配决策树

把上面所有路径串起来，一次 `new` 的决策过程是：

```
new Object()
    │
    ├─ 大小 > RegionSize/2 ?
    │     └─ 是 → Humongous 路径
    │            ├─ 找连续 Free Region
    │            ├─ 找不到 → 触发 GC / Full GC
    │            └─ 直接算 Old Gen
    │
    └─ 否 → 普通路径
          ├─ TLAB 剩余空间够？
          │     ├─ 够 → 指针碰撞（无锁，最快）
          │     └─ 不够 → refill TLAB（CAS）
          │                └─ refill 失败 → Eden 共享分配（CAS）
          │                        └─ Eden 满 → Young GC
          └─ 分配完成
```

对应到性能：

| 路径 | 耗时量级 | 是否加锁 |
|---|---|---|
| TLAB 指针碰撞 | ~1ns | 否 |
| TLAB refill | ~几十 ns | 是（CAS） |
| Eden 共享分配 | ~几十 ns | 是（CAS） |
| Humongous 分配 | ~微秒 | 是（需要找连续区间） |
| 触发 GC | 毫秒~秒 | — |

**所以「大对象」的代价不只是占内存，是它的分配路径本身就慢了 3 个数量级，还可能触发 GC。**

## 六、实战：一个小实验

写个程序验证阈值（RegionSize 用 4MB）：

```java
public class HumongousDemo {
    public static void main(String[] args) throws Exception {
        List<byte[]> keep = new ArrayList<>();
        // Region 4MB，阈值 2MB
        // 1.9MB：普通对象，走 Eden/TLAB 慢路径
        keep.add(new byte[(int) (1.9 * 1024 * 1024)]);
        // 2.1MB：Humongous
        keep.add(new byte[(int) (2.1 * 1024 * 1024)]);
        // 5MB：需要 2 个连续 Region
        keep.add(new byte[5 * 1024 * 1024]);

        Thread.sleep(1000);
        System.out.println("hold " + keep.size());
    }
}
```

```bash
java -Xms512m -Xmx512m -XX:+UseG1GC \
     -XX:G1HeapRegionSize=4m \
     -Xlog:gc+heap=debug:file=gc.log \
     HumongousDemo
```

`gc.log` 里会看到 `Humongous regions: 0->3` 之类的记录（2.1MB 占 1 个，5MB 占 2 个，共 3 个）。

这个实验的价值在于：**你可以用自己业务的堆参数，实测出「多大数据会变成 Humongous」**，而不是靠猜。

## 七、面试追问

**Q1：TLAB 里的对象会不会被其他线程看到？**

会。TLAB 只是**分配**隔离，不是**访问**隔离。对象分配后引用可以被任意线程访问。TLAB 的作用是避免分配时的指针竞争，和可见性/内存模型无关。

**Q2：为什么大对象不放在 Eden？**

两个原因：一是复制算法对大对象成本极高（Young GC 要复制存活对象，复制 100MB 数组比重建还慢）；二是 TLAB 装不下，破坏了「线程私有分配」的设计。所以 G1 让大对象直接进老年代，用标记-清除的方式处理，避免复制开销。

**Q3：`-XX:G1HeapRegionSize` 调大有什么副作用？**

三个：Humongous 阈值提高（好事）、Region 粒度变粗导致 Mixed GC 回收不精确（坏事）、单个 Humongous 对象的内部碎片上限变大（坏事）。**不要为了「少几个 Humongous」盲目调大**，先看是不是真的有大对象分配问题。

**Q4：G1 的 Humongous 对象什么时候回收？**

只有两个时机：并发标记周期结束后的 Mixed GC，以及 Full GC。`G1EagerReclaimHumongousObjects`（默认开）允许在 Young GC 时提前回收「确定无引用」的 Humongous Region，但它依赖标记信息，不是万能的。

**Q5：ZGC 有 Humongous 问题吗？**

ZGC 按页面（ZPage）管理，不要求 Region 大小一致，大对象用「大页面」（Medium/Large Page），不需要连续 Region 拼接，所以没有 G1 那种「找不到连续 Region」的问题。但大对象本身的内存占用和分配开销依然存在，只是不会引发 Full GC。这也是大堆、大对象场景推荐 ZGC 的原因之一。

## 八、上线前 checklist

- [ ] GC 日志开启 `gc+heap=debug`，能看到 `Humongous regions` 计数
- [ ] 用真实堆参数实测「多大算 Humongous」，写进团队文档
- [ ] 代码扫描：禁止在循环里 `new byte[大数]`、禁止一次性 `selectAll`
- [ ] 导出/报表类接口用游标 + 流式写，不堆全量数据
- [ ] 监控 `Humongous regions` 趋势，持续上涨就告警
- [ ] 大对象多的服务评估 ZGC（JDK 17+ 已生产可用）
- [ ] 缓冲区池化时算清楚 `线程数 × 缓冲区大小` 的总内存

## 结语

G1 的分配路径其实只有两条：**小对象走 TLAB，大对象走 Humongous**。前者是「无锁指针碰撞」的极致优化，后者是「连续 Region + 直接进老年代」的妥协方案。

线上大部分 G1 抖动，追到底都是「某个业务逻辑偷偷造了个大对象」。工具能帮你定位（GC 日志 + `jmap -histo`），但根治只能靠改代码——**分批、流式、复用**，这三招能解决 90% 的 Humongous 问题。

至于「调大 RegionSize」，它是止痛药，不是解药。
