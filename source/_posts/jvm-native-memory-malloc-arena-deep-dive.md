---
title: 【JVM 排障】Native Memory 与 glibc malloc Arena 深度解析：堆才 4G，RSS 为什么涨到 12G
date: 2026-11-05 08:10:00
tags:
  - Java
  - JVM
  - 内存
  - glibc
  - 性能调优
categories:
  - JVM 深挖
author: 东哥
---

# 【JVM 排障】Native Memory 与 glibc malloc Arena 深度解析

## 前言

「堆内存 OOM 我能查，堆内存泄漏我能 dump，但 RSS 一直涨、容器一直被杀，heap dump 却是健康的」——这是 Java 生产排障里最让人无力的场景之一。

一个真实工单：Spring Boot 服务，`-Xmx4g`，容器 limit 8Gi。运行 3 天后 `container_memory_working_set_bytes` 稳定爬到 7.6Gi，被 kubelet OOMKilled。`jmap -histo` 正常，`jstat` 正常，MAT 打开 heap dump 只用了 2.8G。

剩下那 4G 去哪了？

答案通常是三个字：**malloc arena**。

---

## 一、先把内存账算清楚：JVM 的 RSS 由什么构成

JVM 进程的 RSS ≠ 堆大小。完整构成大致如下：

| 组成 | 典型大小 | 是否受 `-Xmx` 控制 | 观测手段 |
|---|---|---|---|
| Java Heap | `-Xmx` | 是 | `jmap -heap`、`jstat -gc` |
| Metaspace | 100~500MB | `-XX:MaxMetaspaceSize` | NMT、`jcmd VM.metaspace` |
| Code Cache | 50~300MB | `-XX:ReservedCodeCacheSize` | NMT |
| 线程栈 | 线程数 × `-Xss`（默认 1MB） | 间接 | NMT、`jstack` 计数 |
| GC 数据结构 | 堆的 1~3% | 部分 | NMT |
| DirectByteBuffer | 受 `-XX:MaxDirectMemorySize` 限制 | 部分 | `BufferPoolMXBean` |
| JNI / native lib | 视依赖 | 否 | NMT（partial） |
| **glibc malloc arena / 堆碎片** | **几十 MB ~ 数 GB** | **否** | `malloc_info`、`pmap` |

重点看最后一行：**它完全在 JVM 的账本之外**。NMT（Native Memory Tracking）统计的是 JVM 自己 `os::malloc` 的部分，glibc 层面的 arena 碎片、线程栈保护区、mmap 的匿名页，NMT 只能部分覆盖。

所以才会出现「NMT 说总共 5G，RSS 却有 12G」的经典错位。

---

## 二、glibc malloc 的 arena 机制

### 2.1 为什么有 arena

glibc 的 `malloc` 为了减少多线程锁竞争，引入了 **arena** 概念：

- 主线程用 `main_arena`
- 其他线程首次 `malloc` 时，尝试**独占**一个新 arena
- 每个 arena 有自己的锁和 free list
- arena 数量上限：64 位系统默认 `8 × CPU 核数`（32 位是 `2 × 核数`）

每个非主 arena 通过 `mmap` 预留 **64MB** 虚拟地址空间（`HEAP_MAX_SIZE`），首次分配时提交 128KB 的 heap，之后按需增长。**关键点：arena 里的内存 free 之后不会立刻还给操作系统**，而是留在该 arena 的 free list 里等待复用。

### 2.2 一个算例

假设：64 核机器，容器 limit 8Gi，业务有 200 个线程（Tomcat 200 + 连接池 + 定时任务）。

- arena 上限 = 8 × 64 = 512 个
- 实际创建数取决于有多少线程调用过 `malloc`，假设 64 个
- 每个 arena 在高负载下涨到 32MB 且不归还
- 合计 = 64 × 32MB = **2GB**，全部计入 RSS，`-Xmx` 完全管不到

这就是「堆 4G + arena 2GB + Metaspace 300MB + 线程栈 200MB + CodeCache 200MB ≈ 7G」的过程。

更糟的是**容器里 `nproc` 返回的是宿主机核数**，arena 上限按 64 核算，而容器可能只分到 4 核。线程数没那么多，但 arena 的上限逻辑已经放大。

### 2.3 一个小实验

```java
// ArenaGrowth.java —— 观察 arena 造成的 RSS 膨胀
public class ArenaGrowth {
    public static void main(String[] args) throws Exception {
        int threads = 32;
        for (int i = 0; i < threads; i++) {
            new Thread(() -> {
                // 每个线程反复申请/释放不同大小的块，制造碎片
                for (int round = 0; round < 200_000; round++) {
                    byte[] a = new byte[8 * 1024];
                    byte[] b = new byte[64 * 1024];
                    if (a[0] + b[0] == 42) System.out.print("");
                }
            }).start();
        }
        Thread.sleep(600_000);
    }
}
```

```bash
java -Xmx512m ArenaGrowth &
PID=$!
sleep 60
grep VmRSS /proc/$PID/status          # 观察 RSS
cat /proc/$PID/smaps_rollup
# 加环境变量对比
MALLOC_ARENA_MAX=2 java -Xmx512m ArenaGrowth &
```

同样的代码，`MALLOC_ARENA_MAX=2` 下 RSS 通常能低 40%~60%。

---

## 三、三件套排查法

### 3.1 NMT：JVM 自己的账本

```bash
java -XX:NativeMemoryTracking=summary -Xmx4g -jar app.jar
# 运行中
jcmd <pid> VM.native_memory summary scale=MB
jcmd <pid> VM.native_memory detail.diff   # 与基线对比
```

NMT 能定位到 `Java Heap`、`Class`、`Thread`、`Code`、`GC`、`Internal`、`Other` 各分类。**如果 `Other` 或 `Internal` 异常大，说明 JVM 内部或 native 库在吃内存**；如果所有分类加起来远小于 RSS，那就是 glibc 层面的事。

### 3.2 pmap / smaps：操作系统的账本

```bash
pmap -x <pid> | sort -k3 -n -r | head -20
# 重点看 [heap] 和大量 64MB 的匿名映射 —— 每个 64MB 匿名段很可能就是一个 arena

cat /proc/<pid>/smaps_rollup
```

典型的 arena 泄漏长这样：几十上百个 `00000000xxx00000 65536K rw--- [ anon ]`，每个 64MB，全在 `[heap]` 附近。

### 3.3 malloc_info：glibc 的自白书

```bash
# glibc >= 2.10 支持，输出 XML
gdb -p <pid> -batch -ex 'call malloc_info(0, stdout)' 2>/dev/null | head -100
```

输出里每个 `<heap nr="N">` 就是一个 arena，`<total type="fast" count=".." size=".."/>` 是碎片量。如果 `size` 很大而 `count` 很小，说明碎片严重（大量小对象被 free 后留在 free list）。

> 生产环境用 gdb attach 要谨慎，`malloc_info` 会持有 arena 锁，可能造成秒级停顿。建议在低峰或预发环境做。

### 3.4 一张对照表

| 现象 | 可能原因 | 验证 |
|---|---|---|
| NMT 总和 ≈ RSS | JVM 内部问题 | `VM.native_memory detail` |
| NMT 远小于 RSS，`pmap` 有多个 64MB anon | arena 碎片 | `malloc_info` |
| RSS 高但可回收，容器 kill 后重启正常 | page cache 计入 cgroup | 看 `container_memory_cache` |
| `DirectByteBuffer` 增长 | Netty/NIO 堆外 | `BufferPoolMXBean` |
| 线程数暴涨 | 线程池无界 / 虚拟线程平台线程 | `jstack \| grep -c java.lang.Thread.State` |

---

## 四、五种治理手段

### 4.1 `MALLOC_ARENA_MAX`（最便宜的一招）

```bash
# Dockerfile
ENV MALLOC_ARENA_MAX=2
# 或 JVM 启动脚本
export MALLOC_ARENA_MAX=4
java -Xmx4g -XX:MaxMetaspaceSize=512m -jar app.jar
```

经验值：`2~4`。代价是高并发下 malloc 锁竞争上升，但 Java 应用的主要分配走 TLAB（线程本地分配缓冲），本来就不怎么调用 `malloc`，所以影响通常很小（<3% 吞吐损失）。

**先测再定**：用 `wrk`/`JMeter` 在预发压一轮，对比 `MALLOC_ARENA_MAX=2` 与默认值的 QPS 和 RSS。

### 4.2 换分配器：jemalloc / tcmalloc

```bash
# Debian/Ubuntu
apt install libjemalloc2
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 java -Xmx4g -jar app.jar
```

jemalloc 的优势：按 size class 划分、更积极的归还策略、内置 `prof` 可做分配采样。Spring Boot 官方镜像里也能用。

```dockerfile
FROM eclipse-temurin:21-jre
RUN apt-get update && apt-get install -y libjemalloc2 && rm -rf /var/lib/apt/lists/*
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
```

### 4.3 主动 `malloc_trim`

glibc 提供 `malloc_trim(0)` 把 arena 顶部的空闲内存还给 OS。可以挂个定时任务：

```java
import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;

public class TrimTask {
    private static final MethodHandle TRIM;

    static {
        Linker linker = Linker.nativeLinker();
        SymbolLookup libc = linker.defaultLookup();
        TRIM = linker.downcallHandle(
                libc.find("malloc_trim").orElseThrow(),
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_LONG));
    }

    public static void trim() {
        try {
            int released = (int) TRIM.invokeExact(0L);
            System.out.println("malloc_trim released pages: " + released);
        } catch (Throwable t) {
            // ignore
        }
    }
}
```

> 注意：`malloc_trim` 会遍历 arena 并加锁，高频调用会造成 STW 级别的抖动。**建议 10~30 分钟一次，且在低峰期**。这是「止血」不是「治病」。

### 4.4 从源头减少 native 分配

- **Netty**：用 `PooledByteBufAllocator`（默认），避免 `Unpooled`；控制 `maxOrder`；及时 `release()`
- **DirectByteBuffer**：设 `-XX:MaxDirectMemorySize`，并暴露指标：

```java
@GetMapping("/metrics/direct")
public Map<String, Object> direct() {
    Map<String, Object> result = new LinkedHashMap<>();
    for (BufferPoolMXBean pool : ManagementFactory.getPlatformMXBeans(BufferPoolMXBean.class)) {
        result.put(pool.getName(), Map.of(
                "count", pool.getCount(),
                "memoryUsed", pool.getMemoryUsed(),
                "totalCapacity", pool.getTotalCapacity()));
    }
    return result;
}
```

- **Zip/GZIP**：`Deflater`/`Inflater` 用完必须 `end()`，否则 native 内存泄漏（这是老牌坑，Spring 的 `GzipUtils` 已处理，但手写代码常见）
- **JNI 库**：有些 native 库（如老版本 snappy、lz4）会自己 malloc 且不 free

### 4.5 容器内存 limit 的正确设置

```
limit = -Xmx + Metaspace + CodeCache + 线程栈 + Direct + arena + 安全余量
```

实用公式：**`limit ≈ -Xmx × 1.5 ~ 1.8`**，再留 512MB 缓冲。`-Xmx4g` 配 `limit: 8Gi` 是比较稳的，`-Xmx4g` 配 `limit: 4.5Gi` 必死。

同时确保 JVM 认到容器限制：

```bash
java -XX:+UseContainerSupport -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=70 -jar app.jar
```

`MaxRAMPercentage` 是基于 cgroup limit 计算的，比硬编码 `-Xmx` 更能适配不同规格。

---

## 五、面试追问

**Q1：Java 进程的内存由哪些部分组成？**

堆、Metaspace、Code Cache、线程栈、GC 结构、Direct Memory、JNI/native、glibc arena。答题时务必强调「后三项不受 `-Xmx` 控制」，这是区分背题和实战的分水岭。

**Q2：什么情况下堆内存正常但 RSS 一直涨？**

三大方向：① glibc arena 碎片（线程多、分配模式多样）；② DirectByteBuffer/Netty 堆外泄漏；③ native 库（JNI/压缩/加密）未释放。排查顺序：NMT → `pmap -x` → `malloc_info` → jemalloc prof。

**Q3：`-Xmx` 设 4G，容器 limit 设 6G 可以吗？**

一般不行。4G 堆 + Metaspace 300M + CodeCache 200M + 200 线程 × 1M + Direct 512M + arena 若干百 M，很容易破 6G。建议 limit ≈ `-Xmx × 1.5` 起。

**Q4：`MALLOC_ARENA_MAX` 设小会不会影响性能？**

会有一定锁竞争，但 Java 的主分配路径是 TLAB，只有大对象、直接内存、native 分配才走 `malloc`，实测影响通常在 3% 以内。建议压测对比后固定为 2 或 4。

**Q5：`malloc_trim` 能当常规手段用吗？**

不能。它是应急止血，遍历 arena 需要加锁，频繁调用会引入延迟毛刺。根治要靠减少碎片来源或换 jemalloc。

---

## 六、踩坑清单

1. **只加 `-Xmx` 不管 RSS**：容器 OOMKilled 99% 是 RSS 超限，不是堆溢出。监控必须看 `container_memory_working_set_bytes`。
2. **用 `jmap -heap` 判断内存健康**：它只看堆，Metaspace/native 一概不知。
3. **NMT 开了 `detail` 模式忘了关**：NMT 本身有 5%~10% 的内存与性能开销，生产用 `summary` 即可。
4. **`malloc_trim` 定时任务写在业务线程池里**：会和业务抢 CPU，且锁竞争导致毛刺。用独立的单线程调度。
5. **容器 page cache 算进 limit**：读写大文件的服务，page cache 可能被算进 cgroup memory，导致「内存没泄漏也被杀」。`echo 3 > /proc/sys/vm/drop_caches` 需谨慎，更该做的是用 `O_DIRECT` 或减小文件缓存压力。
6. **升级 glibc 前不测 arena 行为**：不同版本 `M_ARENA_MAX` 默认值和归还策略有差异。

---

## 总结

- **堆内存只是 JVM 内存的一部分**，RSS 才是容器真正的生死线。
- **arena 碎片是「堆正常但 RSS 涨」的头号嫌疑**，`pmap` 看到一堆 64MB 匿名段基本可以确诊。
- 治理优先级：`MALLOC_ARENA_MAX` ＞ 换 jemalloc ＞ `malloc_trim`（止血）。
- 容器 limit 公式：`-Xmx × 1.5` 起，配合 `MaxRAMPercentage`。
- 面试答题要能把「NMT 账本」和「OS 账本」分开讲，这是深度所在。
