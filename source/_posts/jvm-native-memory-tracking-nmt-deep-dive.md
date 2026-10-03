---
title: 【JVM 实战】Native Memory Tracking（NMT）深度解析：本地内存追踪、直接内存与 Metaspace 泄漏排查
date: 2026-10-03 08:00:02
tags:
  - JVM
  - NMT
  - 内存泄漏
  - 性能调优
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 实战】Native Memory Tracking（NMT）深度解析：本地内存追踪、直接内存与 Metaspace 泄漏排查

## 面试官：容器被 OOMKilled 了，但堆内存只用了 40%，内存去哪了？

这是线上最让人头疼的一类问题。`-Xmx4g`，容器 limit 也是 4g，`jstat` 看堆稳稳的，GC 日志一切正常，结果 K8s 时不时把 Pod 干掉，事件里只有一行冷冰冰的：

```
Reason: OOMKilled  Exit Code: 137
```

堆没问题，那内存去哪了？答案通常是：**堆外（Native Memory）**。

而要看清楚堆外内存的去向，JDK 自带了一个专门工具——**Native Memory Tracking（NMT）**。这篇文章把它从原理到实战讲清楚。

---

## 一、JVM 的内存到底由哪些部分组成

很多人脑中的 JVM 内存 = 堆 + 栈 + 方法区。真实情况要复杂得多：

```
进程 RSS（resident set size）
├── Java Heap                 (-Xmx 控制)
├── Metaspace                 (-XX:MaxMetaspaceSize)
├── Compressed Class Space
├── Code Cache                (-XX:ReservedCodeCacheSize)
├── Thread Stacks             (线程数 × -Xss)
├── GC 自身数据结构            (卡表、标记位图、G1 region 元数据…)
├── Direct Memory             (-XX:MaxDirectMemorySize)
├── JNI / Native Libraries    (Netty、RocksDB、JNA、native 加密库…)
├── Mapped Files              (mmap、Lucene、Kafka…)
├── NMT 自身开销
└── 内核/glibc arena 碎片
```

注意最后几项：**它们完全不受 `-Xmx` 约束**。这就是"堆只用了 40%，进程却被杀"的根源。

---

## 二、NMT 是什么

NMT（Native Memory Tracking）是 HotSpot 提供的一个**追踪 JVM 自身 native 内存分配**的机制。它通过 hook JVM 内部的内存分配器（`malloc` 的封装层 `os::malloc` / `Metaspace::allocate` 等），把每一次分配按**类别**记账。

### 开启方式

```bash
java -XX:NativeMemoryTracking=summary -Xmx4g -jar app.jar
# detail 更细，但开销更大
java -XX:NativeMemoryTracking=detail -Xmx4g -jar app.jar
```

| 模式 | 粒度 | 性能开销 | 适用 |
| --- | --- | --- | --- |
| `off` | 不追踪 | 无 | 默认 |
| `summary` | 按类别汇总 | 约 2%~5% | 生产常驻 |
| `detail` | 精确到调用点 | 约 5%~10% | 临时排查 |

**重要限制**：NMT 只能在启动时开启，**运行中无法打开**（`jcmd` 改不了）。所以要么生产长期用 `summary`，要么提前在预发复现。

---

## 三、读懂 NMT 输出

```bash
jcmd <pid> VM.native_memory summary
```

典型输出（节选）：

```
Native Memory Tracking:

Total: reserved=6325871KB, committed=3289463KB
-                 Java Heap (reserved=4194304KB, committed=2097152KB)
                            (mmap: reserved=4194304KB, committed=2097152KB)

-                     Class (reserved=1156789KB, committed=98561KB)
                            (classes #17234)
                            (  instance classes #16210, array classes #1024)
                            (malloc=3429KB #63215)
                            (mmap: reserved=1153360KB, committed=95132KB)

-                    Thread (reserved=287432KB, committed=287432KB)
                            (thread #278)
                            (stack: reserved=286272KB, committed=286272KB)
                            (malloc=848KB #1673)
                            (arena=312KB #553)

-                      Code (reserved=252118KB, committed=86518KB)
                            (malloc=9318KB #10241)
                            (mmap: reserved=242800KB, committed=77200KB)

-                        GC (reserved=189342KB, committed=189342KB)
-                  Compiler (reserved=1532KB, committed=1532KB)
-                  Internal (reserved=8642KB, committed=8642KB)
-                     Other (reserved=12482KB, committed=12482KB)
-                    Symbol (reserved=21456KB, committed=21456KB)
-    Native Memory Tracking (reserved=6720KB, committed=6720KB)
-                     Arena (reserved=1245KB, committed=1245KB)
```

### 逐项解读

| 类别 | 含义 | 常见异常 |
| --- | --- | --- |
| Java Heap | 堆，`-Xmx` 控制 | 堆泄漏，GC 日志就能看出 |
| Class | Metaspace + 压缩类空间 | 动态类生成、热部署导致**类泄漏** |
| Thread | 线程栈 | 线程泄漏，线程数 × `-Xss` 飙升 |
| Code | JIT 编译后的机器码 | Code Cache 满，`ReservedCodeCacheSize` 太小 |
| GC | 垃圾收集器元数据 | G1 卡表随堆增长 |
| Compiler | JIT 编译器自身 | 一般很小 |
| Internal | 命令行解析、启动参数等 | 一般很小 |
| Symbol | 常量池字符串、方法名 | intern 字符串过多 |
| Arena | C++ 分配器 arena | 通常很小 |
| **Other** | 其它 native 分配 | 这里经常藏着 DirectByteBuffer / JNI |
| **Unknown** | 未追踪到的 | 第三方 native 库（NMT 追踪不到） |

**关键提醒**：`reserved` 是虚拟地址空间预留，`committed` 才是真正占用物理内存的部分。判断内存问题要看 **committed**，不要被巨大的 reserved 吓到。

---

## 四、实战：用 baseline + diff 定位增长

NMT 最强大的用法是**做差值**——一次排查就看到"这段时间谁涨了"。

```bash
# 1. 建立基线
jcmd <pid> VM.native_memory baseline

# 2. 等一段时间（或复现问题）

# 3. 查看差值
jcmd <pid> VM.native_memory summary.diff
```

输出会带上 `+` / `-` 标记，一眼看出增长来源：

```
-                     Class (reserved=1156789KB, committed=98561KB +48213KB)
                            (classes #17234 +4210)   <-- 类数量持续增长！
-                    Thread (reserved=287432KB, committed=287432KB +102400KB)
                            (thread #278 +100)        <-- 线程泄漏！
```

看到 `+4210` 个类、`+100` 个线程，问题基本锁定了。也可以用 `detail.diff` 拿到更细的调用栈。

---

## 五、四大"堆外凶手"逐个击破

### 1）Metaspace 泄漏（Class 增长）

**症状**：NMT 里 Class 的 committed 持续增长，`classes #` 不断增加，且 GC 后不回落。

**根因**：Metaspace 只有在**类加载器被回收**时才能卸载类。如果 ClassLoader 被强引用（缓存、静态字段、ThreadLocal、线程上下文），它加载的所有类就永远无法卸载。

**高危场景**：

- 动态代理 / CGLIB / 字节码增强框架：每个代理类都会生成 `XXX$$EnhancerByCGLIB$$xxx`；
- **热部署 / 热加载**：每次 reload 新建一个 ClassLoader，旧的不释放；
- 脚本引擎（Groovy/Nashorn/GraalJS）反复 eval；
- `ThreadLocal` 的 key 弱引用、value 强引用导致的经典泄漏（线程池常驻线程尤其明显）。

**排查**：

```bash
jcmd <pid> VM.classloader_stats   # JDK 11+，看 classloader 数量
jcmd <pid> GC.class_stats         # 需要 -XX:+UnlockDiagnosticVMOptions
jmap -clstats <pid>
```

**修复**：定位到泄漏的 ClassLoader（通常是自定义的），确保无强引用；配置 `-XX:MaxMetaspaceSize` 做兜底，让泄漏尽早暴露成 OOM 而不是拖垮整机。

### 2）Thread 泄漏（线程数增长）

**症状**：Thread committed 增长，`thread #` 上升；`jstack` 里有大量 parked/waiting 线程。

**根因**：线程池用了 `Executors.newCachedThreadPool()`（无上限）、`newFixedThreadPool` 但任务阻塞导致排队、`ScheduledExecutorService` 未 `shutdown`、每个请求 new Thread。

**脚手架代码**：

```java
// 危险：缓存线程池，60s 空闲才回收，流量尖峰后线程数长期高位
ExecutorService pool = Executors.newCachedThreadPool();

// 推荐：显式参数 + 有界队列 + 命名线程
ThreadPoolExecutor pool = new ThreadPoolExecutor(
        32, 64, 60, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(1000),
        new ThreadFactoryBuilder().setNameFormat("order-pool-%d").build(),
        new ThreadPoolExecutor.CallerRunsPolicy());
```

**注意 `-Xss`**：默认 1MB（Linux x64），1000 个线程就是约 1GB 栈空间。这也是"线程数一多，native 内存暴涨"的原因。

### 3）Direct Memory（直接内存）

**症状**：NMT 里 `Other` 或 committed 总量增长，但堆正常。`java.lang.OutOfMemoryError: Direct buffer memory`。

**根因**：`ByteBuffer.allocateDirect()`、Netty 的 `PooledByteBufAllocator`、NIO Channel 的读写缓冲。

**关键认知**：DirectByteBuffer 的**对象本身在堆里（很小）**，但**数据在堆外（很大）**。JVM 靠 `Cleaner`（虚引用）在 GC 时回收堆外内存——所以**堆空间充足时 GC 不触发，堆外就回收不了**，这是最反直觉的坑。

**控制手段**：

```bash
-XX:MaxDirectMemorySize=1g      # 显式限制，超过抛 OOM 而不是被容器杀
-Dio.netty.maxDirectMemory=0    # Netty 用 no-cleaner 策略，由 Netty 自己管理
```

**为什么显式设置 `MaxDirectMemorySize` 很重要**：不设置时，默认等于 `-Xmx`，堆外可以一直涨到进程被 OOMKilled 才报错；设置了之后，超限会抛 `OutOfMemoryError`，**能被捕获、能告警、能优雅降级**。

### 4）JNI / 第三方 native 库

NMT **追踪不到** JNI 库自己用 `malloc` 分配的内存，这部分会落在 `Unknown` 或干脆不计入。典型：RocksDB、Lucene（mmap）、某些加密/压缩库、JNA。

**排查手段**：

```bash
pmap -x <pid>                       # 看进程内存映射总览
cat /proc/<pid>/smaps_rollup        # 各段 RSS 汇总
cat /proc/<pid>/status | grep -i vm # VmRSS / VmSwap
gdb / pstack                        # 必要时看 native 栈
```

再配合 glibc 的 **`malloc_trim`** 问题（`MALLOC_ARENA_MAX` 太多 arena 导致碎片），可以加：

```bash
export MALLOC_ARENA_MAX=2
-jemalloc 或 -XX:+UseTransparentHugePages 的取舍
```

---

## 六、容器化场景的额外注意点

容器里有个"隐藏税"：

```
容器内存限制 = JVM 各部分 + native 库 + glibc 碎片 + 页缓存 + 内核开销
```

实践建议：

| 建议 | 说明 |
| --- | --- |
| 容器 limit 留 25%~30% 余量 | 常用公式：`-Xmx = limit × 0.7`（再留出 CPU 密集型的 Code Cache 与线程栈） |
| 显式设置 `MaxDirectMemorySize` | 把不可控变成可控 OOM |
| 显式设置 `MaxMetaspaceSize` | 让类泄漏早暴露 |
| 限制线程数 | `-Xss512k` + 有界线程池 |
| 关闭 swap 或严格限制 | 避免 OOM 前的剧烈抖动 |
| 用 `-XX:+ExitOnOutOfMemoryError` | OOM 后直接退出，让 K8s 重建，避免僵死 |

JDK 10+ 已默认 `-XX:+UseContainerSupport`，会自动感知 cgroup 限制设置默认堆大小——但**它只算堆，不算堆外**，所以上面的余量必须自己留。

---

## 七、NMT 的局限性

1. **不追踪 JNI/native 库**——`Unknown` 里的内存可能来自任何地方。
2. **不追踪 mmap 文件映射**（部分计入）。
3. **有开销**——生产长期开 `summary` 需评估（通常 2%~5% 可接受）。
4. **只能启动时开启**——突发问题无法临时打开，"事后诸葛亮"式排查常常困难。
5. **`detail` 模式在高频分配下会拖慢应用**，慎用。

所以最佳实践是：**生产长期开 `summary` + 建立定时 baseline/diff 采集**，把"native 内存增长速率"变成一个可观测指标。

---

## 八、面试常见追问

**Q1：堆外内存泄漏和堆内存泄漏，排查手段有什么区别？**
堆泄漏看 `jmap -histo` / MAT 支配树；堆外泄漏看 NMT diff、`pmap`、`smaps`。堆外泄漏最坑的是**堆 dump 里看不到**，因为数据不在堆上。

**Q2：为什么 `ByteBuffer.allocateDirect` 的内存要等 GC 才回收？**
因为回收依赖 `Cleaner`（基于虚引用）。虚引用只有在 GC 时才会入队并触发 `Deallocate`。堆不紧张 → 不 GC → 堆外不回收，这就是"堆外泄漏"的假象。

**Q3：NMT 显示 Java Heap committed 比 `-Xmx` 小很多，正常吗？**
正常。堆是**按需 commit**的（`-XX:MinHeapFreeRatio` / `MaxHeapFreeRatio`），reserved 才是 `-Xmx` 的预留地址空间。判断内存是否吃紧看 committed 和 GC 日志。

**Q4：`Code Cache` 涨到顶会怎样？**
JIT 停止编译，应用退化为解释执行，性能骤降（不是 OOM）。可以通过 `-XX:ReservedCodeCacheSize` 调大，并关注 `jcmd <pid> Compiler.codecache`。

**Q5：怎么快速判断"内存到底是不是堆外问题"？**
三步：① 看 GC 日志与 `jstat` 确认堆健康；② 看容器 RSS 与 `-Xmx` 的差值；③ `jcmd VM.native_memory summary` 或 `pmap` 看 committed 分布。堆正常 + RSS 高 = 堆外问题。

---

## 九、总结

- **NMT** 是 HotSpot 内置的 native 内存追踪工具，按类别记账，`summary` 开销低、适合生产常驻。
- 排查三板斧：`summary` 看分布 → `baseline` + `diff` 看增长 → `/proc/<pid>/smaps` 看映射。
- 四大凶手：**Metaspace（类加载器泄漏）、Thread（线程泄漏）、Direct Memory（Cleaner 延迟回收）、JNI/native 库**。
- 容器场景务必：**留 25%+ 余量、显式设置 `MaxDirectMemorySize` 与 `MaxMetaspaceSize`、限制线程数**。
- NMT 有盲区（JNI/mmap），要配合 `pmap`/`smaps` 使用。

一句话：**别只盯着堆，进程内存是个综合体；NMT 就是那把照向黑暗角落的手电筒。**
