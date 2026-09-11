---
title: 【JVM 云原生】JVM 容器化深度解析：cgroup 内存限制、UseContainerSupport 与 K8s OOMKilled 排查
date: 2026-09-11 08:10:00
tags:
  - JVM
  - Kubernetes
  - 云原生
  - 面试
categories:
  - JVM
  - 云原生
author: 东哥
---

# 【JVM 云原生】JVM 容器化深度解析：cgroup 内存限制、UseContainerSupport 与 K8s OOMKilled 排查

## 面试官：Pod limit 是 2Gi，堆只用了 1G，为什么容器还是被 OOMKilled？

这是容器化 Java 应用最经典的线上事故。我们先把结论摆出来：

> 容器的 `OOMKilled` 是 **Linux 内核 cgroup 层面的 OOM Killer** 干的，不是 JVM 的 `OutOfMemoryError`。它看的是**进程组的 RSS 总量（堆 + 非堆 + 栈 + 直接内存 + 代码缓存 + JVM 自身）**，而不仅仅是堆。

而事故的第一根因往往是：**JVM 根本没意识到自己跑在容器里**，默认按"宿主机物理内存的 1/4"来设置 `-Xmx`。

本文从 cgroup 原理讲到 Java 版本演进，再到 K8s 排查手法。

## 一、根因：JVM 眼中的"内存"是谁的内存

JDK 8 早期（8u131 之前），JVM 通过 `sysconf(_SC_PHYS_PAGES)` 这类系统调用拿"物理内存"，容器里这返回的是**宿主机**的内存。

于是经典事故现场：

```
宿主机：64C / 128G
Pod limit：memory 2Gi, cpu 2
JVM：-Xmx 默认 = 128G / 4 = 32G
结果：容器刚启动就疯狂分配，cgroup 到达 2Gi 上限 → OOMKilled（exit code 137）
```

修复时间线：

| 版本 | 能力 |
| --- | --- |
| JDK 8u131 | `-XX:+UnlockExperimentalVMOptions -XX:+UseCGroupMemoryLimitForHeap`（实验） |
| JDK 8u191 / JDK 10 | **默认开启**容器感知 `-XX:+UseContainerSupport`（JEP 无号，通过 backport） |
| JDK 10+ | `MaxRAMPercentage / InitialRAMPercentage / MinRAMPercentage` 按百分比配置 |
| JDK 11+ | cgroup v2 支持逐步完善 |

**判断你的 JVM 有没有容器感知：**

```bash
# 打印最终生效的所有参数（最权威）
java -XX:+PrintFlagsFinal -version 2>/dev/null | grep -iE "UseContainerSupport|MaxHeapSize|MaxRAMPercentage|ActiveProcessorCount"

# 运行中查看
jcmd <pid> VM.flags
jinfo -flag UseContainerSupport <pid>
```

只要看到 `UseContainerSupport = true`，就说明 JVM 会读取 cgroup 限制。

## 二、cgroup v1 与 v2 的差异

容器感知依赖读取 cgroup 文件：

| | cgroup v1 | cgroup v2 |
| --- | --- | --- |
| 内存限制文件 | `/sys/fs/cgroup/memory/memory.limit_in_bytes` | `/sys/fs/cgroup/memory.max` |
| 当前用量 | `.../memory.usage_in_bytes` | `/sys/fs/cgroup/memory.current` |
| CPU 配额 | `.../cpu/cpu.cfs_quota_us` + `period_us` | `/sys/fs/cgroup/cpu.max`（"quota period"） |
| 事件计数 | `memory.failcnt` / `oom_control` | `/sys/fs/cgroup/memory.events`（`oom`、`oom_kill`） |

容器里直接验证：

```bash
cat /sys/fs/cgroup/memory.max            # v2
cat /sys/fs/cgroup/memory/memory.limit_in_bytes  # v1
cat /sys/fs/cgroup/memory.current
cat /sys/fs/cgroup/memory.events         # oom_kill 计数 > 0 说明被内核杀过
```

**JDK 11 之前对 cgroup v2 支持不完整**，很多"明明开了容器感知还是 OOM"的案例，根因就是宿主机用了 cgroup v2 而 JDK 版本太老读不到限制。解决方式：升级 JDK（至少 11.0.16+ / 17+），或者显式用 `-Xmx` 兜底。

## 三、容器内存 = 堆 + 一堆你看不见的东西

一个 Java 进程在 cgroup 里被计入的内存包括：

| 区域 | 典型大小 | 控制手段 |
| --- | --- | --- |
| Java Heap | `-Xmx` | `-Xmx` / `-XX:MaxRAMPercentage` |
| Metaspace | 64~256MB+ | `-XX:MaxMetaspaceSize` |
| 线程栈 | 线程数 × (512KB~1MB) | `-Xss`、`-XX:MaxDirectMemorySize` |
| 直接内存/Netty ByteBuf | `-XX:MaxDirectMemorySize`，默认≈堆大小 | `-XX:MaxDirectMemorySize` |
| CodeCache | ~50~240MB | `-XX:ReservedCodeCacheSize` |
| GC 辅助结构 | G1 的 Remembered Set、Card Table、TLAB | `-XX:+AlwaysPreTouch` 会一次吃满 |
| JVM 自身 / JNI / 线程元数据 / 内存映射 jar | 数十 MB | 减少依赖、`-XX:MaxMetaspaceSize` |
| glibc arena（malloc 碎片） | 可能几十 MB | `MALLOC_ARENA_MAX=2` |

所以**堆绝对不能顶满 limit**。工程经验：

```
堆上限 ≈ limit × 0.7 ~ 0.75
剩余 25%~30% 留给 Metaspace + 栈 + DirectMemory + CodeCache + JVM 自身
```

配置示例：

```bash
# 明确指定，不依赖默认 1/4
java -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=40 \
     -XX:MaxMetaspaceSize=256m \
     -XX:MaxDirectMemorySize=256m \
     -XX:ReservedCodeCacheSize=128m \
     -XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
     -Xss512k \
     -jar app.jar
```

> 注意 `MaxRAMPercentage` 的分母是 **cgroup limit**（容器感知生效时），不是宿主机内存。如果你的启动脚本里同时写了 `-Xmx2g` 和 `-XX:MaxRAMPercentage=70`，**`-Xmx` 优先级更高**（`MaxRAMPercentage` 只在没显式设置 `-Xmx` 时生效）。

## 四、CPU 感知：另一种"看不见的手"

`Runtime.getRuntime().availableProcessors()` 在容器里返回什么？

- 老 JDK：返回宿主机核数 → 线程池、ForkJoinPool、GC 线程、Netty 线程全都按 64C 开 → 大量上下文切换，P99 抖动
- 新 JDK（支持 `UseContainerSupport` 后）：按 cgroup CPU quota 计算

```bash
jcmd <pid> VM.info | grep -A5 "CPU"
java -XX:+PrintFlagsFinal -version | grep ActiveProcessorCount
```

手动兜底（有些环境 cgroup 信息不标准，或刻意要少开线程）：

```bash
java -XX:ActiveProcessorCount=2 -jar app.jar
```

**踩坑**：`-XX:ActiveProcessorCount` 会同时影响 G1 的并行 GC 线程数、ForkJoinPool 的并发度、`CompletableFuture` 默认线程池、`ParallelStream` 的并行度。设小了会 GC 变慢，设大了会 CPU 争抢，建议与 `limits.cpu` 对齐。

## 五、K8s 侧 OOMKilled 的完整排查链路

### 第 1 步：确认是不是被内核杀的

```bash
kubectl describe pod <pod> | grep -A5 "Last State"
# Last State: Terminated
#   Reason: OOMKilled
#   Exit Code: 137
```

`137 = 128 + 9`（SIGKILL）。但注意 **137 也可能是 liveness probe 失败后 kubelet 杀进程、或应用自己 `kill -9`**，必须结合 `Reason: OOMKilled` 判断。

### 第 2 步：区分是容器 OOM 还是节点 OOM

| 现象 | 含义 |
| --- | --- |
| `Last State: OOMKilled` 且容器 limit 被触及 | **容器级 cgroup OOM**：JVM 内存超 limit |
| 节点 `dmesg` 出现 `Memory cgroup out of memory: Killed process ... java` | 同上，内核日志佐证 |
| 节点整体 MemoryPressure、多个 Pod 被杀 | 节点级 OOM，`limit` 总和超过节点容量 |
| Java 输出 `java.lang.OutOfMemoryError: Java heap space` | **JVM 堆 OOM**，属于应用问题（对象泄漏） |

```bash
# 节点内核日志
dmesg -T | grep -i "killed process"
journalctl -k | grep -i oom

# 容器 cgroup 事件计数
cat /sys/fs/cgroup/memory.events
# low 0
# high 0
# max 1234     <- 触及上限次数
# oom 5
# oom_kill 5   <- 被杀次数

# K8s 事件
kubectl get events --field-selector involvedObject.name=<pod>
```

### 第 3 步：Native Memory Tracking（NMT）定位非堆内存

这是排查"堆没满但进程 RSS 高"的杀手锏：

```bash
# 启动时开启（有约 5%~10% 性能开销，线上谨慎/按需开启）
java -XX:NativeMemoryTracking=summary -jar app.jar

# 查看分类汇总
jcmd <pid> VM.native_memory summary

# 与基线对比，找出增长的部分
jcmd <pid> VM.native_memory baseline
jcmd <pid> VM.native_memory summary.diff
```

NMT 会把内存按 `Java Heap / Class / Thread / Code / GC / Compiler / Internal / Other` 分类。常见结论：

- `Thread` 持续增长 → **线程泄漏**（线程池没复用、`new Thread` 泛滥、`ThreadLocal` 持有大对象不算这里但线程元数据算）
- `Code` 增长到 `ReservedCodeCacheSize` → JIT 代码缓存满，性能下降
- `Internal` 高 → DirectByteBuffer / `sun.misc.Unsafe` 分配
- `Class` 增长 → 动态代理/CGLIB 类无限生成（`@Configuration` + 频繁刷新、Groovy 脚本、反射代理）

### 第 4 步：看实际 RSS 构成

```bash
# 容器内（需要特权或用 PID namespace 共享）
cat /proc/<pid>/status | grep -E "VmRSS|VmSwap|Threads"
cat /proc/<pid>/smaps_rollup
# 或者用 pmap 看匿名段
pmap -x <pid> | tail -5
```

**`VmSwap` 也要看**：如果容器没有 swap limit，JVM 可能把一部分内存换出，RSS 看起来正常但延迟爆炸。

## 六、生产最佳实践清单

1. **总是显式设置堆**：`-XX:MaxRAMPercentage=70`，别依赖默认值。
2. **limit 与 request 都要设**，且 `request == limit`（Guaranteed QoS），避免节点内存超卖导致被驱逐。
3. **限制 Metaspace 和 DirectMemory**：`-XX:MaxMetaspaceSize`、`-XX:MaxDirectMemorySize`，否则它们会无限蚕食容器内存。
4. **控制线程数与栈大小**：`-Xss512k` + 限制业务线程池上限；容器里栈内存比堆更容易被忽视。
5. **开启容器感知**：JDK 11+，并确认 `UseContainerSupport = true`。
6. **`AlwaysPreTouch` 慎用**：会让 JVM 启动时把整个堆真实分配，启动变慢、容易被 OOMKilled（但能避免运行时页错误抖动）。低内存 limit 下建议关闭。
7. **不要用 `UseCGroupMemoryLimitForHeap`**（已被废弃），用 `MaxRAMPercentage`。
8. **构建镜像时用 jemalloc 或 `MALLOC_ARENA_MAX=2`**，控制 glibc 的 arena 碎片。
9. **接监控**：JVM 指标（堆、非堆、GC、线程数）+ 容器指标（RSS、`container_memory_working_set_bytes`、cgroup `oom_kill`），两边对比才能定位。
10. **退避策略**：OOMKilled 后 kubelet 会重启容器，但若 JVM 启动后立即吃满内存，会形成 `CrashLoopBackOff`，此时要先把 `request/limit` 调大止血。

## 面试官追问

**Q1：`container_memory_working_set_bytes` 和 RSS 有什么区别？K8s 按哪个判定 OOM？**
cgroup 的 memory 统计包含 page cache。**working set = usage - inactive_file**，即扣掉可回收的文件缓存。K8s 的驱逐判定用 working set，内核 OOM Killer 则是在 cgroup 到达 `memory.max` 时触发。所以"容器内存看起来满了但没被杀"通常是 page cache 被算进去了。

**Q2：为什么堆明明没满，JVM 却先 OOM 了？**
两种 OOM 完全不同：`java.lang.OutOfMemoryError: Java heap space` 是 JVM 堆分配失败；`OOMKilled` 是内核杀进程。写代码时的 OOM 属于前者，容器被杀属于后者，排查路径完全不同。

**Q3：G1 的 `-XX:MaxGCPauseMillis` 会不会影响内存占用？**
会。G1 为了满足停顿目标会用更小的年轻代、更频繁的 GC；同时维护 Remembered Set 需要额外内存（一般占堆的 1%~2%，跨区引用多时更高）。Region 数量（`region_size`）也会影响 RSet 大小。

**Q4：JDK 8 升到 JDK 17 后内存行为有什么变化？**
默认 GC 从 Parallel 变为 G1，默认 `MaxRAMPercentage` 行为统一（1/4 容器内存），Metaspace 默认无上限仍需显式限制，cgroup v2 支持更完善。升级前建议用 `-XX:+PrintFlagsFinal` 对比两个版本的差异。

## 总结

容器化 Java 的内存问题，本质是**三个"看不见"**：

1. **JVM 看不见容器**——老版本按宿主机内存算堆；
2. **堆看不见非堆**——Metaspace、栈、直接内存、CodeCache 不在 `-Xmx` 里；
3. **开发者看不见 cgroup**——`OOMKilled` 与 `OutOfMemoryError` 是两条完全不同的链路。

排查顺序建议固定为：`kubectl describe` → cgroup `memory.events` → `dmesg` → NMT → `smaps_rollup`，先定性（谁杀的），再定量（谁吃的内存），最后才谈调优。
