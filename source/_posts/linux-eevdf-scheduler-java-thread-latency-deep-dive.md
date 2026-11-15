---
title: 【性能调优】Linux EEVDF 调度器与 Java 线程延迟深度解析：从 CFS 的 vruntime 到 lag/vslice
date: 2026-11-15 08:10:00
tags:
  - Java
  - Linux
  - 性能调优
  - 调度器
  - EEVDF
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】Linux EEVDF 调度器与 Java 线程延迟深度解析

## 前言

先看一个线上真实场景：

一个 Spring Boot 服务，接口 P99 从 40ms 涨到 380ms。GC 日志干净（单次 8ms），CPU 使用率 62%（没打满），线程池队列不深，下游依赖 RT 正常。`top` 看每个线程都在 R 状态，没死锁没 BLOCKED。

最后定位到的原因是：**这台机器上同时跑了一个数据导出任务，两者共享同一 cgroup，EEVDF/CFS 把可运行线程按权重公平分配 CPU 时间片，业务线程每次被唤醒后，要等「别人用完属于它的那一段」才能拿到 CPU。**

也就是说，Java 侧的线程池、GC、异步编排都做对了，但**真正决定你的请求什么时候被 CPU 执行的是内核调度器**，而这一层几乎没有人写进 Java 的性能排查清单。

这篇把 CFS → EEVDF 的演进讲清楚，然后把「内核调度语义」翻译成 Java 工程师能用的东西：哪些 JVM 参数是假的、哪些指标能观测、混部时怎么隔离。

## 一、先回顾 CFS：Java 工程师最该知道的三件事

CFS（Completely Fair Scheduler，2.6.23 起）的核心只有一个变量：

```
vruntime += 实际运行时间 × (NICE_0_LOAD / 该任务权重)
```

- 权重由 nice 值决定（nice 0 → 权重 1024，nice -20 → 88761，nice 19 → 15，近似 1.25 倍等比）。
- 调度实体挂在红黑树上，**每次选 vruntime 最小的那个**运行。
- 时间片不是固定的，而是由 `sched_latency`（默认 6ms~24ms 自适应）除以「可运行任务数」得到，再受 `sched_min_granularity`（默认 0.75ms）兜底。

对 Java 工程师来说，需要记住的三个推论：

**推论 1：`Thread.setPriority()` 在 Linux 上基本是装饰品。**
JVM 在 Linux 上把 Java 优先级映射到 pthread 的调度策略时，默认策略是 `SCHED_OTHER`（即 CFS/EEVDF），而 `SCHED_OTHER` **不看** `sched_priority`（它只对 `SCHED_FIFO/SCHED_RR` 有效）。所以 `new Thread(...).setPriority(MAX_PRIORITY)` 在 Linux 上不会让线程多拿 CPU。真正能改的是 nice 值，但 JDK 没有公开 API（只能通过 JNI 调 `setpriority(2)`，且需要权限）。

**推论 2：线程数远超核数时，公平 = 谁都在等。**
8 核机器上开 200 个可运行线程，每个线程的 vruntime 增长都很慢，但每次被调度到只跑 0.75ms 就被换下。上下文切换本身（~1~3μs）加上 cache 污染，会让每个线程的实际吞吐断崖下跌。这就是「线程池不是越大越好」在内核层的解释。

**推论 3：`availableProcessors()` 只看 cpuset，不看 quota。**
容器里 `--cpus=2` 但没有 `--cpuset-cpus` 时，`Runtime.getRuntime().availableProcessors()` 仍然返回宿主机核数（除非开了 `-XX:ActiveProcessorCount` 或新版 JDK 的容器感知）。线程池、ForkJoinPool 并行度、GC 线程数全部会按宿主机核数算，然后被 cgroup quota 硬掐。

## 二、CFS 到底哪里不够：延迟敏感任务没有表达渠道

CFS 的唯一目标是「公平」。它有一个补救机制叫**唤醒抢占**：一个新唤醒的任务如果 vruntime 比当前任务小 `wakeup_granularity`，就可以抢占。

问题在于：

1. `wakeup_granularity` 是从 `sched_latency` 推出来的，而 `sched_latency` 随可运行任务数**变大**（有上限），于是任务越多，抢占越难。
2. 公平调度**不区分「我需要多久内被调度」**。一个跑 50ms 的批处理任务和一个只需要 0.2ms 就能返回的 RPC 线程，权重相同时待遇一样。
3. 结果：**平均延迟很好，尾延迟很差**。CFS 时代所有「CPU 密集 + 延迟敏感混部」的团队都在调 `sched_wakeup_granularity_ns`、`sched_min_granularity_ns`，本质上是在打补丁。

这就是 EEVDF（Earliest Eligible Virtual Deadline First）进入主线的动机。

## 三、EEVDF：把「公平」换成「公平 + 截止时间」

EEVDF 的理论来自 1995 年的一篇论文，Linux 6.6 起成为 CFS 的替代实现（内核里代码路径仍然叫 `fair.c`，但算法换了）。它引入两个关键概念：

**1. lag（滞后）= 应得服务时间 − 实际获得服务时间**

```
lag_i = (虚拟时间 - vruntime_i) × 权重_i
```

- `lag > 0`：这个任务「被欠了」，应该优先补给它。
- `lag < 0`：这个任务「超支了」，得等别人追上。
- **只有 lag ≥ 0 的任务才是 eligible（有资格）**。这保证了不会出现「某个任务靠低权重长期霸占 CPU」的不公平。

**2. virtual deadline（虚拟截止时间）= eligible 时间 + 请求的片长折算**

每个任务有一个「片长请求」`slice`，EEVDF 在任务变为 eligible 的时刻加上它的片长，得到一个虚拟截止时间：

```
virtual_deadline_i = eligible_time_i + slice_i / 权重_i
```

调度决策变成：**在 eligible 集合里，选 virtual deadline 最小的那个**。

这两步的语义非常关键：

- **lag 保证公平**（谁被欠得多谁先有资格）；
- **virtual deadline 保证延迟**（短片长的任务截止时间天然更早，先跑）。

所以 EEVDF 给了延迟敏感任务一个**正式的、非特权的表达渠道**：把 `slice` 调小，截止时间就提前，就能更快被调度，同时因为它仍然要满足 lag ≥ 0，不会饿死别人。

### 3.1 参数对照

| 维度 | CFS | EEVDF |
|---|---|---|
| 选择依据 | vruntime 最小 | eligible 集合中 virtual deadline 最小 |
| 时间片 | `sched_latency / nr_running`，受 `sched_min_granularity` 兜底 | 每个任务自带 `slice`，由 `sched_base_slice`（默认 3ms）派生 |
| 延迟敏感 | 只能靠 `wakeup_granularity` 抢占 | 调小 `slice` 提前截止时间 |
| 主要可调项 | `sched_latency_ns`、`sched_min_granularity_ns`、`sched_wakeup_granularity_ns` | `sched_base_slice_ns`（`/sys/kernel/debug/sched/base_slice_ns`）、`/proc/sys/kernel/sched_*` 大幅缩减 |
| 用户侧接口 | nice | **nice + `sched_setattr(2)` 的 `SCHED_FLAG_UTIL_CLAMP` / slice 请求** |

这里有一个现实检查：**内核暴露给用户态的 slice 调节接口非常有限**。`sched_setattr(2)` 里的 `sched_runtime` 字段在 EEVDF 下可以被解释为 slice 请求，但不是所有发行版都开放，glibc 也没有包装。**在 Java 里你几乎不可能直接改 slice。** 所以对应用层来说，EEVDF 的实际收益是「内核默认行为更合理了」，而不是「我能精细调它」。

那 Java 工程师能做什么？往下看。

## 四、把调度语义翻译成 Java 侧的动作

### 4.1 cgroup v2 的 `cpu.weight` 和 `cpu.max` 语义完全不同

这是最容易搞错的一点：

| 参数 | 语义 | 生效条件 | 后果 |
|---|---|---|---|
| `cpu.weight`（1~10000，默认 100） | 竞争时的**比例分配** | 只在同层级 cgroup 之间有 CPU 竞争时生效 | 不限制上限。独占机器时用到 100% 也没人管 |
| `cpu.max`（如 `200000 100000` = 2 核） | **带宽上限** | 每个 100ms 周期结算一次 | 用超了就被 throttle 到下个周期，**产生周期性抖动** |

`cpu.max` 的抖动是 Java 服务 P99 的经典杀手：

```
周期 100ms，配额 50ms
业务线程在周期前 50ms 用完全部配额
剩余 50ms 内所有可运行线程被 throttle（R 状态但不被调度）
下一个周期开始，积压的线程一起冲上来，cache 全冷
```

现象就是：CPU 使用率看起来只有 50%，但 P99 周期性尖刺。观测点是 `cpu.stat`：

```
$ cat /sys/fs/cgroup/myapp/cpu.stat
usage_usec 48123456
nr_periods 1200
nr_throttled 87
throttled_usec 4350000
```

`nr_throttled / nr_periods` 超过 5% 就值得动手了。

### 4.2 GC 线程和业务线程权重相同，这是默认宿命

JVM 的 GC 线程、编译线程、业务线程在同一个 cgroup 里，权重一样。G1 的并发标记线程会吃掉不少 CPU，而这些 CPU 是从业务线程嘴里抢的。

EEVDF 下有一个「帮忙」：GC 线程是长期可运行的，它们的 lag 会逐渐变负（因为它们一直在超支），业务线程（频繁睡眠、唤醒）lag 保持 ≥ 0，因此在 eligible 集合里更容易抢到 virtual deadline 优先权。**这是 EEVDF 相比 CFS 对 Java 服务的一个隐性改善**：交互型负载（线程频繁阻塞/唤醒）比批处理型负载（线程长期可运行）更容易拿到 CPU。

但要主动利用它，还得做两件事：

1. **把 CPU 密集的旁路任务（导出、重建索引、离线计算）拆到独立 cgroup**，给低 `cpu.weight`，并且加 `cpu.max` 硬顶。
2. **不要用 `-XX:ParallelGCThreads` 拉满**。容器里默认按 cpuset 算，如果 cpuset 是宿主机全核而 quota 只有 2 核，GC 线程数会严重超配。

```java
// 容器感知自检：启动时打印，别等出事才查
public class CpuBudgetPrinter {
    public static void main(String[] args) throws Exception {
        System.out.println("availableProcessors = " + Runtime.getRuntime().availableProcessors());
        System.out.println("cpu.max   = " + readOrNull("/sys/fs/cgroup/cpu.max"));
        System.out.println("cpu.weight= " + readOrNull("/sys/fs/cgroup/cpu.weight"));
        System.out.println("cpuset    = " + readOrNull("/sys/fs/cgroup/cpuset.cpus.effective"));
        System.out.println("cpu.stat  = " + readOrNull("/sys/fs/cgroup/cpu.stat"));
    }

    private static String readOrNull(String path) {
        try {
            return Files.readString(Path.of(path)).trim().replace('\n', ' ');
        } catch (Exception e) {
            return null; // cgroup v1 或非容器环境
        }
    }
}
```

### 4.3 虚拟线程的 carrier 数与调度叠加

虚拟线程的 carrier 线程数默认等于 `availableProcessors()`。在 EEVDF 下，carrier 线程是**长期可运行**的（它们跑 ForkJoinPool 的工作队列），而阻塞的虚拟线程不占 carrier。

这里有一个容易忽视的叠加效应：

- 如果 carrier 数 < 真实可用 CPU（比如 quota 2 核但 `availableProcessors()` 返回 32），虚拟线程的并行度会被高估，实际执行时被 throttle；
- 如果 carrier 数 > 真实可用 CPU，上下文切换变多，cache 命中率下降，但 EEVDF 的 lag 机制会让频繁 yield 的 carrier 更容易被调度，抖动比 CFS 时代小一些。

结论：**显式设置 `-Djdk.virtualThreadScheduler.parallelism=N`，N 取 cgroup 有效核数**，别让它猜。

## 五、观测：三个层次，按成本从低到高

**第一层：cgroup 与进程级（零成本，先看这个）**

| 指标 | 位置 | 判读 |
|---|---|---|
| `throttled_usec` | `/sys/fs/cgroup/<path>/cpu.stat` | 周期 throttling，P99 周期尖刺 |
| `cpu.pressure` | `/sys/fs/cgroup/<path>/cpu.pressure` | `some avg10` 反映「有任务等 CPU」的比例 |
| `nr_running` | `/proc/<pid>/schedstat` 第 1 列 | 超过核数 2 倍说明排队严重 |
| `se.statistics.wait_sum` | `/proc/<pid>/sched`（需 root） | 累计等 CPU 时间，**最直接的证据** |

`schedstat` 三列语义（很多文章写错）：

```
$ cat /proc/self/schedstat
1234567890 45678901 12345
# 第1列：在 CPU 上运行的纳秒数
# 第2列：在运行队列里等待的纳秒数   ← 关键
# 第3列：被调度到的次数（slice 数）
```

**第二层：Java 内部（能区分「等 CPU」和「等锁」）**

```java
// 用 ThreadMXBean 的 CPU 时间 + 墙钟时间对比，定位线程到底在等什么
ThreadMXBean mx = ManagementFactory.getThreadMXBean();
if (mx.isThreadCpuTimeSupported() && !mx.isThreadCpuTimeEnabled()) {
    mx.setThreadCpuTimeEnabled(true);
}

long wallStart = System.nanoTime();
long cpuStart  = mx.getCurrentThreadCpuTime();

doWork();

long wall = System.nanoTime() - wallStart;
long cpu  = mx.getCurrentThreadCpuTime() - cpuStart;
// cpu/wall ≈ 1  → 一直在跑（CPU 密集 或 自旋）
// cpu/wall ≈ 0.1 → 大部分时间不在 CPU 上：等锁 / 等 IO / 被 throttle
System.out.printf("wall=%.2fms cpu=%.2fms ratio=%.2f%n",
        wall / 1e6, cpu / 1e6, (double) cpu / wall);
```

这个比值是排查的第一步分流器：**ratio 低但线程状态是 RUNNABLE，就是被 throttle 或等 CPU**（Java 的 RUNNABLE 包含「在运行队列里排队」，这是 JDK 的语义，别被误导）。

**第三层：内核级（需要 root / debugfs）**

```bash
# 每个任务的调度延迟分布
perf sched latency -p <pid>

# 调度器内部状态（EEVDF 下能看到 slice / deadline 相关字段）
cat /proc/sched_debug | head -50

# 动态追踪：谁在抢 CPU
bpftrace -e 'tracepoint:sched:sched_switch /pid == 12345/ {
  @wait[comm] = hist(nsecs - @start[tid]);
}'
```

## 六、混部治理：一张决策表

| 场景 | 症状 | 动作 |
|---|---|---|
| 周期 throttling | `nr_throttled` 高，P99 呈方波 | 提高 `cpu.max` 或降低峰值并发；把批任务移到别的 cgroup |
| 长期 CPU 排队 | `cpu.pressure some` > 20% | 减少线程池大小 / 拆服务 / 加核 |
| 批任务抢业务 CPU | 业务 P99 与批任务启动时间强相关 | 批任务独立 cgroup，`cpu.weight=10`，`cpu.max` 硬顶 |
| GC 抢占 | GC 时间正常但 STW 变长 | 限制 `ParallelGCThreads`，或把 GC 与批任务错峰 |
| 容器核数识别错误 | 线程池远大于 quota | `-XX:ActiveProcessorCount=N` + 虚拟线程 parallelism |
| 尾延迟抖动但 CPU 空闲 | `wait_sum` 高、`nr_running` 高 | 检查是否有 CPU 密集线程在自旋（`cpu/wall≈1`） |

## 七、面试常见追问

**Q1：CFS 的 vruntime 是怎么算的？为什么要除以权重？**
vruntime 是虚拟运行时间，等于实际运行时间按权重折算。权重越大（nice 越小），同样的实际时间折算出的 vruntime 增长越慢，因此在红黑树上越靠左，被调度得越频繁——这就是「高优先级拿更多 CPU」的实现方式。除以权重保证了不同优先级的任务在**虚拟时间轴**上是公平的。

**Q2：EEVDF 相比 CFS 解决了什么问题？**
CFS 只表达公平，不表达延迟需求，唤醒抢占靠 `wakeup_granularity` 打补丁。EEVDF 引入 lag 保证公平（只有 lag ≥ 0 才 eligible），引入 virtual deadline 表达延迟（slice 越短截止越早）。两者结合，可以在不牺牲公平的前提下让延迟敏感任务更快被调度。

**Q3：`Thread.setPriority` 为什么在 Linux 上无效？**
因为 Linux 的默认调度策略 `SCHED_OTHER` 不使用 `sched_priority` 字段，只使用 nice 值决定权重。JVM 不会把 Java 优先级翻译成 nice（历史上 `-XX:+UseThreadPriorities` 在 Linux 上也是空操作）。想要真实优先级只能用 `SCHED_FIFO/SCHED_RR`（需要 `CAP_SYS_NICE`，且会饿死其他线程，生产禁用）。

**Q4：容器里 `availableProcessors()` 为什么不准？**
它读的是 cpuset（`sched_getaffinity`），不是 cgroup CPU quota。`--cpus=2` 只设置 quota 不设置 cpuset，所以 JVM 看到的是宿主机全部核。JDK 10+ 有一部分容器感知（`UseContainerSupport`），但主要作用于**内存**；CPU 侧仍需 `-XX:ActiveProcessorCount` 显式指定。

## 八、落地踩坑清单

1. **别迷信「CPU 没打满就没问题」**。调度延迟发生在「有 CPU 空闲但你的线程没被选中」的时候，利用率指标看不出来。
2. **`nr_throttled` 要作为 SLO 指标上报**，和 P99 放同一个看板。
3. **不要把 `cpu.weight` 当成限流**。它只在竞争时按比例分配，独占时无限。
4. **批任务的 `cpu.max` 要留出余量**，否则批任务自己也会被 throttle 得极慢，反而拉长总时长。
5. **EEVDF 不是银弹**。它改善的是「同权重下的尾延迟」，如果你的问题是 quota 打满或者锁竞争，换调度器没用。
6. **升级内核要重新压测**。6.6 之后 EEVDF 的参数默认值还在调整，同样的负载在不同内核上 P99 可能差 30%。

## 总结

- CFS 用 vruntime 表达公平，用唤醒抢占勉强表达延迟；EEVDF 用 **lag 表达公平、virtual deadline 表达延迟**，把两件事拆开了。
- 对 Java 工程师来说，最要紧的不是调 EEVDF 参数（内核没给你接口），而是**认清三件事**：Java 线程优先级是假的、`availableProcessors()` 可能骗你、`cpu.max` 会制造周期性抖动。
- 可观测的三件套：`cpu.stat`（throttle）、`cpu.pressure`（排队）、`/proc/<pid>/schedstat` 第 2 列（累计等 CPU 时间）。
- 混部治理的正确姿势是**分层 cgroup + 权重 + 硬顶**，而不是在应用层调线程池参数祈祷。

下一篇我会把「文件系统层的持久化语义」拆开讲——`fsync` 之后数据到底在哪、ext4 和 XFS 的差别为什么会让你的 WAL 性能差一倍。那是另一层同样被 Java 工程师忽视的内核语义。
