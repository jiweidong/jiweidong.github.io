---
title: 【JVM 实战】线上频繁 Full GC 排查与根治：从 GC 日志归因到内存泄漏定位
date: 2026-10-17 08:00:00
tags:
  - Java
  - JVM
  - GC
  - 性能调优
  - 线上排查
categories:
  - Java 深挖
author: 东哥
---

# 【JVM 实战】线上频繁 Full GC 排查与根治

## 前言

面试里问「Full GC 怎么排查」，很多人能背出 `jstat -gcutil`、`jmap -histo`、`MAT 分析堆 dump` 三板斧。但真到线上，问题往往更刁钻：**有的 Full GC 是内存泄漏，有的是大对象分配，有的是 `System.gc()` 被误调用，还有的是元空间/代码缓存触顶**。如果不先做「归因」，上来就 dump 堆，可能折腾几小时也没找到根因。

这篇文章按生产实战的顺序讲：**先确认现象 → 从 GC 日志读出「谁触发了 Full GC」→ 按归因树定位 → 分场景根治 → 参数与治理加固**。配套一个可复现的 Demo 和一套排查命令。

---

## 一、先确认：是不是真的「频繁」

「频繁」不能凭感觉。先量化三个指标：

| 指标 | 观察命令 | 健康阈值（参考） |
|---|---|---|
| Full GC 次数/频率 | `jstat -gcutil <pid> 1000 60` 看 `FGC` 增量 | 正常几小时甚至几天 1 次；每分钟 >1 次即异常 |
| Full GC 后老年代回收率 | `jstat -gc` 的 `OU`（老年代使用） | 每次 FGC 后 OU 明显下降才说明是「可回收垃圾」；几乎不降 = 泄漏 |
| 应用 RT 抖动 | 监控上的 P99 / STW 时长 | FGC 频繁必然带来毛刺 |

**关键判读**：
- Full GC 后老年代**显著下降** → 是「对象产生过快 / 晋升过快」，属于**分配压力**问题。
- Full GC 后老年代**几乎不降** → 大概率是**内存泄漏**或「存活对象确实很大」。
- 直接看 GC 日志里的 **`[Full GC (xxx) ...]` 括号里的 cause** → 这才是归因的钥匙。

开启 GC 日志（JDK 9+，统一日志）：

```bash
java -Xlog:gc*,gc+heap=info:file=/var/log/app/gc.log:time,uptime,level,tags:filecount=10,filesize=50M \
     -jar app.jar
```

---

## 二、按 `cause` 归因：Full GC 的五种触发器

GC 日志里 `Full GC` 后面的括号就是触发原因，照着它归类，效率提升一个数量级：

| cause | 含义 | 典型根因 | 治理方向 |
|---|---|---|---|
| `Allocation Failure`（并发收集器下少见） | 分配失败触发的兜底 | 晋升过快 / 大对象 | 加大年轻代、减少短命大对象 |
| `Metadata GC Threshold` | 元空间达到阈值 | 动态类生成过多（CGLIB/反射/热部署） | 排查类加载器泄漏，调 `MetaspaceSize` |
| `Ergonomics` | JVM 自适应决策触发 | 老年代占用超阈值（默认约 45%） | 调 `InitiatingHeapOccupancyPercent`（IHOP） |
| `System.gc()` / `System.gc() invoked` | 显式调用 | 代码/第三方库误调 | 排查调用点，或 `-XX:+ExplicitGCInvokesConcurrent` |
| `GCLocker Initiated GC` | JNI 临界区结束后触发 | JNI/`GetStringCritical` 阻塞了 GC | 优化 native 代码 |

> 一句话：**先看 cause，再决定是查堆、查元空间，还是改参数。** 盲目 dump 堆是本末倒置。

---

## 三、场景一：分配压力（Allocation Failure / Ergonomics）

**现象**：FGC 后老年代能明显回收，但很快又满。

**根因常见三类**：
1. **短命大对象**：比如把几十 MB 的列表/图片/`byte[]` 一次性造出来，直接落到老年代。
2. **晋升过快**：年轻代太小（或 `SurvivorRatio` 不合理），对象在 Survivor 熬不过 `MaxTenuringThreshold` 就被迫晋升。
3. **缓存无界**：本地 `Map` 缓存不设上限，本质是「泄漏式增长」。

**排查**：

```bash
# 1) 看各代使用与晋升速度
jstat -gc <pid> 1000 30
# 关注：YGC 频率、YGCT、FGC、FGCT、OU(老年代使用)

# 2) 看谁在大量分配（无需 dump 堆）
jcmd <pid> GC.class_histogram | head -30
# 或老版本
jmap -histo:live <pid> | head -30

# 3) 用 async-profiler 抓分配热点（allocation 模式）
./profiler.sh -e alloc -d 30 -f alloc.html <pid>
```

**根治示例**（无界缓存 → 有界 + 过期）：

```java
// ❌ 危险：只增不减，等于慢性泄漏
private static final Map<String, byte[]> CACHE = new ConcurrentHashMap<>();

// ✅ 用 Caffeine 有界 + 过期 + 淘汰
Cache<String, byte[]> cache = Caffeine.newBuilder()
        .maximumSize(10_000)               // 有界
        .expireAfterWrite(Duration.ofMinutes(10))
        .softValues()                      // 内存吃紧时可被 GC 回收
        .build();
```

参数侧可适度 `-Xmn`（加大年轻代）或调大 `-XX:SurvivorRatio`，让短命对象「死于年轻代」，别晋升到老年代。**但记住：参数只能缓解，不能治愈泄漏。**

---

## 四、场景二：内存泄漏（FGC 后老年代不降）

这是最难也最常见的一类。**判据：连续多次 Full GC 后 `OU` 依然维持在高位**。

**常见泄漏源**（按出现频率排序）：

1. **静态集合 / 单例缓存**：`static Map` 越积越多。
2. **线程池 + ThreadLocal**：线程复用导致 `ThreadLocal` 的 value 不释放（经典 `ThreadLocal` 泄漏）。
3. **监听器/回调未注销**：注册了不注销，被长生命周期对象持有。
4. **连接/流未关闭**：`Connection`、`InputStream` 未 close。
5. **ClassLoader 泄漏**：类加载器被外部引用，导致整个类的元数据无法回收（伴随 `Metadata GC Threshold`）。

**定位流程**：

```bash
# 1) 连续两次 heap dump，做差分（比单次 dump 更准）
jcmd <pid> GC.heap_dump /tmp/heap1.hprof
# 触发一段时间业务后
jcmd <pid> GC.heap_dump /tmp/heap2.hprof

# 2) MAT 打开 → Leak Suspects / Dominator Tree
#    或命令行快速看大对象
jhat /tmp/heap1.hprof   # 老工具，仅应急

# 3) 看对象「谁在引用它」——MAT 的 Path to GC Roots（排除弱/软引用）
```

**实战案例**：某服务 FGC 每 30s 一次。`jmap -histo` 看到 `char[]` 与 `String` 异常多，MAT 里 Path to GC Roots 指向一个 `static final Map` 的「本地缓存」，写入只 put 不 evict。改成 Caffeine 有界缓存后，FGC 降到一天 1 次。

**ThreadLocal 泄漏的正确姿势**：

```java
private static final ThreadLocal<byte[]> BUF = ThreadLocal.withInitial(() -> new byte[8192]);

void handle() {
    try {
        // 使用 BUF
    } finally {
        BUF.remove();   // ✅ 线程池场景必须手动 remove
    }
}
```

---

## 五、场景三：元空间/代码缓存触顶（Metadata GC Threshold）

**现象**：FGC cause 是 `Metadata GC Threshold`，且堆回收率正常，但 FGC 仍频繁。

**根因**：动态生成类太多——CGLIB 代理、反射、脚本引擎、热部署、`Lambda` 大量生成、JSON 库动态类等。若这些类的加载器和类无法卸载，元空间持续增长。

**排查**：

```bash
jstat -gc <pid>            # 看 MC/MU（元空间容量/使用）
jcmd <pid> VM.metaspace     # JDK 11+ 直接看元空间明细
jcmd <pid> VM.native_memory summary   # NMT 看整体本地内存
-XX:+TraceClassUnloading   # 观察类是否能卸载
```

**治理**：
- 限制元空间上限：`-XX:MaxMetaspaceSize=256m`，让问题尽早暴露而不是拖垮机器。
- 排查 ClassLoader 泄漏（尤其容器/热部署场景），确保自定义加载器可回收。
- 减少不必要的动态代理/反射生成。

---

## 六、场景四：`System.gc()` 被误调

**现象**：FGC cause 明确写 `System.gc()`。

```bash
jcmd <pid> VM.flags | tr ' ' '\n' | grep -i ExplicitGC
```

**两个处理方向**：
1. **找出调用点**：`-XX:+PrintGCDetails` 结合堆栈，或直接全局搜代码 / 依赖（很多老库、RMI、NIO 的 `DirectByteBuffer` 清理、部分监控 agent 会调）。
2. **容错兜底**：
   ```bash
   -XX:+ExplicitGCInvokesConcurrent     # 把显式 GC 转成并发 GC，避免 STW
   -XX:+DisableExplicitGC               # 彻底禁用（谨慎！可能影响依赖 DirectByteBuffer 释放的逻辑）
   ```
   
> `-XX:+DisableExplicitGC` 是双刃剑：它能消灭 `System.gc()` 造成的 STW，但某些依赖显式 GC 回收直接内存的库可能出现堆外内存堆积。生产上更推荐「找到调用点根治」，而不是一刀切禁用。

---

## 七、场景五：GCLocker / 大对象直接进老年代

- **GCLocker Initiated GC**：JNI 里 `GetPrimitiveArrayCritical` 之类的临界区阻塞了 GC，退出临界区后 JVM 补一次 GC。多见于 native 库。
- **大对象直接进老年代**：超过 `-XX:PretenureSizeThreshold`（仅 Serial/ParNew 有效）或巨大数组会直接分配在老年代，快速把老年代顶满。

```bash
# 大对象阈值（配合年轻代收集器使用）
-XX:PretenureSizeThreshold=1m
```

---

## 八、G1 时代的参数加固清单

现在多数线上是 G1（JDK 9+ 默认）。G1 下的频繁 Full GC 常与 **并发标记跟不上分配速度**、**Humongous 对象**、**碎片**有关：

| 参数 | 作用 | 建议 |
|---|---|---|
| `-XX:InitiatingHeapOccupancyPercent` | 触发并发标记的堆占用阈值 | 分配快时适当调低（如 35~40） |
| `-XX:G1HeapRegionSize` | Region 大小 | Humongous（≥Region/2）对象多时，适当调大 Region |
| `-XX:MaxGCPauseMillis` | 目标停顿 | 设太小会导致 GC 更频繁、更激进 |
| `-XX:G1MixedGCLiveThresholdPercent` | Mixed GC 回收门槛 | 按存活率调优 |
| `-XX:+ParallelRefProcEnabled` | 并行处理引用 | 引用处理是 STW 大头时开启 |

开启并发类卸载（G1 默认已开，但值得确认）：

```bash
-XX:+ClassUnloadingWithConcurrentMark
```

**G1 频繁 Full GC 的经典信号**：GC 日志里 Full GC 前出现大量 `to-space exhausted` 或 `Evacuation Failure`——说明**疏散失败**（晋升/复制时没有可用 Region），此时 Full GC 是兜底。核心还是**降低分配、减少大对象、给足堆**。

---

## 九、一张图记住排查顺序

```
频繁 Full GC
  │
  ├─ 看 cause
  │   ├─ Allocation Failure / Ergonomics → 分配压力 → 减大对象 / 调年轻代
  │   ├─ Metadata GC Threshold          → 元空间 → 查类加载器泄漏
  │   ├─ System.gc()                    → 找调用点 / ExplicitGCInvokesConcurrent
  │   └─ GCLocker Initiated             → 检查 JNI
  │
  ├─ 看 FGC 后 OU 是否下降
  │   ├─ 下降 → 分配压力/晋升过快
  │   └─ 不降 → 内存泄漏 → 两次 heap dump 差分 + MAT
  │
  └─ 定参数（G1 调 IHOP/Region）+ 治理无界缓存 / ThreadLocal
```

---

## 十、面试高频追问

**Q1：频繁 Full GC，你会先 dump 堆吗？**
不会。先看 GC 日志的 `cause` 和 `jstat` 里 FGC 后老年代回收率。若回收率高，是分配压力，dump 堆意义不大；只有「FGC 后老年代不降」才高度怀疑泄漏，这时才 dump，且建议**两次 dump 做差分**。

**Q2：怎么区分「内存泄漏」和「内存不够」？**
泄漏的特征是：多次 Full GC 后老年代占用**稳定维持高位不降**，且随运行时间线性增长；内存不够则是回收后能降下来，只是很快又满。两者治理方向完全不同：前者查引用链，后者加堆/减分配。

**Q3：`System.gc()` 导致的 Full GC 怎么处理最稳妥？**
优先定位调用点（第三方库、DirectByteBuffer 清理、agent 都可能）。若短期无法改代码，用 `-XX:+ExplicitGCInvokesConcurrent` 降级为并发 GC；`-XX:+DisableExplicitGC` 谨慎使用，可能引发堆外内存回收延迟。

**Q4：G1 下 Full GC 都跟什么有关？**
并发标记滞后（IHOP 太高）、Humongous 大对象、疏散失败（to-space exhausted）、碎片化、元空间/引用处理等。

**Q5：`ThreadLocal` 为什么在线程池里会泄漏？**
`Thread` 持有 `ThreadLocalMap`，key 是弱引用但 **value 是强引用**，线程复用不复原导致 value 长期存活。正确做法是 `try/finally` 里 `remove()`。

---

## 结语

频繁 Full GC 的排查，本质是**先归因、再动手**：`cause` 定方向，回收率定性质（压力 vs 泄漏），差分 dump 定引用链，最后才是参数与代码治理。把这套流程内化成条件反射，线上再遇到「应用莫名其妙卡顿 + FGC 飙升」，你就能在十几分钟内给出判断，而不是盲目 dump 几个小时。下一篇我会讲 **G1 调优的参数全景与压测验证**，欢迎持续关注。
