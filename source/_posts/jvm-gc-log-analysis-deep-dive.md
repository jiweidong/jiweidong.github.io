---
title: 【JVM 实战】GC 日志分析全攻略：从读懂 GC 日志到性能调优决策
date: 2026-08-14 08:00:00
tags:
  - JVM
  - GC
  - 调优
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 实战】GC 日志分析全攻略：从读懂 GC 日志到性能调优决策

## 面试官：线上 JVM 频繁 Full GC，你怎么排查？

"看 GC 日志啊！"——但很多人打开 GC 日志的那一刻就懵了：`[GC (Allocation Failure) [PSYoungGen: 65536K->8192K(76288K)] 65536K->12416K(251392K), 0.0112332 secs]` 这一行到底在说什么？吞吐量、暂停时间、晋升阈值怎么算？

GC 日志是 JVM 性能问题的第一现场，也是面试官最爱考的"实战题"。本文从开启日志、逐字段拆解、到真实调优案例，一次性讲透。

---

## 一、怎么开启 GC 日志

### 1.1 JDK 8 及以前

```bash
java -Xloggc:/opt/logs/gc.log \
     -XX:+PrintGCDetails \
     -XX:+PrintGCDateStamps \
     -XX:+PrintHeapAtGC \
     -XX:+PrintTenuringDistribution \
     -XX:+PrintGCApplicationStoppedTime \
     -XX:+PrintGCApplicationConcurrentTime \
     -XX:+HeapDumpOnOutOfMemoryError \
     -XX:HeapDumpPath=/opt/logs/heap.hprof \
     -Xms1g -Xmx1g \
     -jar app.jar
```

### 1.2 JDK 9+ 统一日志框架（推荐）

```bash
java -Xlog:gc*:file=/opt/logs/gc.log:time,uptime,level,tags \
     -Xlog:gc+heap=debug \
     -Xlog:gc+age=trace \
     -Xlog:gc+promotion=debug \
     -Xms1g -Xmx1g \
     -jar app.jar
```

```bash
# 或者简短版：输出到 stdout，便于容器日志采集
java -Xlog:gc* -jar app.jar
```

### 1.3 动态开启（生产环境免重启）

```bash
jinfo -flag +PrintGCDetails <pid>      # JDK 8
jcmd <pid> VM.log output=gc.log        # JDK 9+
jcmd <pid> VM.log what=gc,gc+heap=debug
```

---

## 二、逐字段拆解一行 GC 日志

以 Parallel Scavenge（PS）为例：

```
[GC (Allocation Failure) [PSYoungGen: 65536K->8192K(76288K)] 65536K->12416K(251392K), 0.0112332 secs] [Times: user=0.02 sys=0.01, real=0.01 secs]
```

| 字段 | 含义 |
|------|------|
| `GC` | Minor GC（`Full GC` 则是 Full GC） |
| `(Allocation Failure)` | 触发原因：年轻代分配失败（Eden 不够了） |
| `PSYoungGen` | 收集器：Parallel Scavenge 年轻代 |
| `65536K->8192K(76288K)` | 年轻代 GC 前 64M → GC 后 8M（年轻代总容量 74.5M） |
| `65536K->12416K(251392K)` | **整个堆** GC 前 64M → GC 后 12.1M（堆总容量 245.5M） |
| `0.0112332 secs` | GC 耗时 11ms |
| `Times: user=0.02 sys=0.01 real=0.01` | user 用户态 CPU 时间、sys 内核态 CPU 时间、real 实际耗时（多线程 GC 时 real < user 正常） |

Full GC 示例：

```
[Full GC (Metadata GC Threshold) [PSYoungGen: 8192K->0K(76288K)]
 [ParOldGen: 120960K->118480K(175104K)] 129152K->118480K(251392K),
 [Metaspace: 20648K->20648K(1069056K)], 0.1862068 secs]
```

**重点看两个数：**

1. `堆前->堆后` 的差值：回收了多少内存
2. GC 后堆占用：如果 GC 后堆占用依然很高（接近堆上限），说明要么对象都是存活的，要么内存泄漏

### 2.1 关键指标换算

```java
// 堆总容量 = 年轻代 + 老年代（Parallel 下）
251392K = 76288K + 175104K   // ≈ 245.5 MB

// 回收率
回收内存 = 65536K - 12416K = 53120K ≈ 52 MB
回收率   = 53120K / 65536K ≈ 81%
```

---

## 三、看懂 GC 后的堆状态（PrintHeapAtGC）

```
{Heap before GC invocations=10 (full 2):
 PSYoungGen      total 76288K, used 65536K ...
  eden space 65536K, 100% used
  from space 9728K, 0% used
  to   space 9728K, 0% used
 ParOldGen       total 175104K, used 0K ...
}
```

- `eden space`：新对象都先分配在这里
- `from/to space`：Survivor 区（S0/S1），GC 后存活对象在这里来回倒腾
- 老年代对象来源：① 晋升（对象熬过多次 Minor GC）② 大对象直接进老年代 ③ Survivor 放不下直接进老年代

**Survivor 分配**：默认 `-XX:SurvivorRatio=8`，即 Eden:Survivor = 8:1:1。Eden 区 65536K，两个 Survivor 各 9728K（10% * 76288 ≈ 7628，四舍五入/对齐后）。

---

## 四、GC 日志分析五步法

拿到一份线上 GC 日志，按下面五步走：

### Step 1：看频率

```bash
# 统计 Minor GC 和 Full GC 次数
grep -c "\[GC " gc.log
grep -c "\[Full GC" gc.log

# 看时间分布
awk '/\[GC /{print $1}' gc.log | head -20
```

**健康标准：**
- Minor GC：每秒几次到几十次可接受，暂停通常 < 50ms
- Full GC：**生产环境应该趋近于 0**，一天几次就要警惕

### Step 2：看暂停时间（STW）

```bash
# 提取所有 GC 的耗时
grep -oE "\[GC[^]]*secs\]" gc.log | tail -20
# 找出最长停顿
grep -oE "Full GC[^]]*" gc.log | sort -t: -k4 -rn | head -5
```

- Minor GC 暂停 > 100ms：年轻代太大或对象太多
- Full GC 暂停 > 1s：老年代快满了 / 大对象多 / 用了 Serial 单线程 GC

### Step 3：看 GC 后堆占用趋势

```bash
# 提取每次 Full GC 后的堆占用
grep -oE "Full GC[^]]*\] [0-9]+K->[0-9]+K" gc.log | tail -10
```

**关键判断：**
- GC 后占用平稳 → 正常
- GC 后占用**持续缓慢上升** → 内存泄漏前兆
- GC 后占用**每次都接近堆上限** → 堆太小或对象存活率过高

### Step 4：看晋升情况（PrintTenuringDistribution）

```
Desired survivor size 5242880 bytes, new threshold 7 (max 15)
- age   1:   8388608 bytes,   8388608 total
- age   2:   4194304 bytes,  12582912 total
- age   3:    1048576 bytes,  13631488 total
```

- `new threshold`：对象熬过几次 Minor GC 后晋升老年代（这里 7 次）
- `age` 分布：如果大量对象集中在 age 1 就被回收，说明大部分是短命对象；如果 age 7 的对象很多，说明晋升压力大
- **Survivor 溢出**：如果 `to space` 经常 100% 满，对象被迫提前晋升老年代 → 调大 Survivor 或调高 MaxTenuringThreshold

### Step 5：结合监控看因果

GC 日志要结合：
- `-XX:+PrintGCApplicationStoppedTime`：应用真实停顿
- `-XX:+PrintGCApplicationConcurrentTime`：应用运行时间
- 业务指标：TPS、RT 曲线与 GC 时间线对齐

---

## 五、实战案例：三次典型 Full GC 排查

### 案例 1：频繁 Full GC（老年代被撑爆）

**现象**：一天 200+ 次 Full GC，每次 2-3 秒，服务频繁超时。

**日志特征**：

```
[Full GC (Ergonomics) [PSYoungGen: 0K->0K(76288K)]
 [ParOldGen: 172032K->172031K(175104K)] 172032K->172031K(251392K), 1.9871234 secs]
```

注意：老年代 GC 前后几乎没变化（172032K->172031K），回收不掉任何东西。

**排查**：
1. `jmap -dump:format=b,file=heap.hprof <pid>` 抓堆转储
2. MAT 分析 Dominator Tree，发现一个 `static HashMap` 持有 90% 内存，value 是不断增长的缓存且**从未清理**
3. 业务代码：`static Map<String, List<Log>> cache = new HashMap<>()`，高并发写入不设上限

**解决**：改用 Caffeine 本地缓存 + 过期策略，Full GC 归零。

### 案例 2：Full GC 频率低但每次 10 秒+

**现象**：每天凌晨一次 Full GC，持续 10 秒，恰好命中定时任务高峰。

**日志特征**：

```
[Full GC (System.gc()) ... 9.8765432 secs]
```

**原因**：某框架在定时任务里显式调用了 `System.gc()`（比如某些 RPC 框架的默认配置、Netty 的堆外内存回收策略 `-XX:+DisableExplicitGC` 未设置）。

**解决**：启动参数加 `-XX:+DisableExplicitGC`，禁止显式 GC 触发。同时排查框架配置。

### 案例 3：大对象导致老年代暴涨

**现象**：Full GC 一天 50 次，每次都能回收但很快又满。

**日志特征**：

```
[Full GC (Allocation Failure) [PSYoungGen: 76288K->0K(76288K)]
 [ParOldGen: 120000K->40000K(175104K)] ...
```

**排查**：`jmap -histo:live <pid> | head -20` 发现 `byte[][]` 占用巨大——业务里一次性加载大批量数据到内存（如一次查 10 万行 + 导出 Excel）。

**解决**：
1. 分批查询 + 流式导出（`XSSFWorkbook` 用 SXSSF）
2. 设置 `-XX:PretenureSizeThreshold=1m`（只对 Serial/ParNew 生效），让大对象直接进老年代避免 Eden 反复拷贝
3. 代码层面：杜绝一次性全量加载

---

## 六、调优决策速查表

| 症状 | 方向 | 常用参数 |
|------|------|----------|
| Minor GC 太频繁 | 堆太小 / Eden 太小 | 增大 `-Xmn` 或 `-Xms/-Xmx` |
| Minor GC 停顿长 | Survivor 不足 / 晋升早 | 调整 `-XX:SurvivorRatio`、`-XX:MaxTenuringThreshold` |
| Full GC 频繁且回收不动 | 内存泄漏 / 对象存活率太高 | 先 dump 分析，再考虑换 G1/ZGC |
| Full GC 是 System.gc() | 显式 GC | `-XX:+DisableExplicitGC` |
| GC 后占用缓慢上升 | 内存泄漏 | MAT 分析 Dominator Tree |
| 大对象过多 | 直接进老年代 | `-XX:PretenureSizeThreshold` |
| 追求低停顿 | 换收集器 | G1：`-XX:MaxGCPauseMillis=100`；低延迟用 ZGC |

### 6.1 G1 日志特点

G1 的日志格式不同，重点关注：

```
[GC pause (G1 Evacuation Pause) (young) 2048M->512M(4096M), 0.0234567 secs]
[GC pause (G1 Humongous Allocation) ...]          ← 大对象分配触发
[GC pause (G1 Evacuation Pause) (mixed) ...]      ← 混合回收（回收老年代）
[GC concurrent-mark-start] ...                    ← 并发标记周期
```

**G1 调优指标**：`-XX:MaxGCPauseMillis`（默认 200ms）、`-XX:G1HeapRegionSize`、`-XX:InitiatingHeapOccupancyPercent`（默认 45，老年代占比超过就启动并发标记）。

### 6.2 吞吐量 vs 低延迟

- **吞吐优先**（批处理、离线计算）：Parallel GC，大堆
- **低延迟优先**（在线交易、网关）：G1/ZGC，控制 `MaxGCPauseMillis`
- **超大堆 + 极致低延迟**（JDK 15+）：ZGC 分代收集（JDK 21 已支持分代 ZGC）

---

## 七、面试官追问环节

### Q1：GC 日志里 user 时间比 real 时间长正常吗？

正常。多线程 GC（Parallel、G1）会并行工作，user 是所有线程 CPU 时间之和，real 是墙钟时间。`user=0.4 sys=0.1 real=0.05` 说明约 8 个线程并行回收。

### Q2：如何判断是内存泄漏还是内存不足？

看 GC 后堆占用：
- **不足**：GC 后占用明显下降（能回收），只是很快又涨满 → 堆容量不够
- **泄漏**：GC 后占用缓慢但持续上升，最终 GC 回收量趋近于 0 → 泄漏

**金标准**：抓两次相隔数小时的 heap dump，对比存活对象集合，泄漏对象必然出现在两次 dump 中且数量增长。

### Q3：Full GC 日志里老年代回收量很小说明什么？

说明老年代中大部分对象是**存活的**（强引用可达）。要么是缓存/静态集合持有，要么是对象晋升后长期存活（如连接池、线程池对象本身），要么是内存泄漏。结合 `jmap -histo:live` 看对象分布。

### Q4：生产环境 GC 日志开多了影响性能吗？

影响很小。GC 日志本身在 STW 期间写（或异步写），主要开销是 IO。JDK 9+ 的 unified logging 做了大量优化，`-Xlog:gc*` 生产可常开，但要注意**日志轮转**：

```bash
# JDK 8
-XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=100M
# JDK 9+
-Xlog:gc*:file=/opt/logs/gc.log:time,uptime:filecount=10,filesize=100m
```

---

## 八、总结

**GC 日志分析的本质是回答三个问题：**

1. **多久一次**（频率）→ 堆是否够用、对象生命周期是否合理
2. **停多久**（暂停）→ 收集器与参数是否匹配业务延迟要求
3. **回收多少**（效率）→ GC 后占用趋势，区分"不足"与"泄漏"

**完整排查链路**：GC 日志定位现象 → jstat/jmap 佐证 → heap dump + MAT 定位根因 → 代码/参数修复 → 灰度验证。把这条链路背下来，面试和实战都能打。
