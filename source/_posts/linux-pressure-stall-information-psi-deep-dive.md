---
title: 【性能调优】PSI 压力失速信息深度解析：内存、IO、CPU 争抢的量化归因与 Java 应用落地
date: 2026-11-09 08:00:00
tags:
  - Linux
  - 性能调优
  - PSI
  - JVM
  - 容器
  - Java
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】PSI 压力失速信息深度解析

## 前言：那个"CPU 只用了 35%，但 P99 抖到 800ms"的下午

先说一个真实场景。线上支付服务，8 核容器，CPU 使用率稳定在 30%~40%，JVM GC 日志干净（Young GC 30ms 一次，一天没有 Full GC），但每天下午三点和晚上八点，接口 P99 从 60ms 飙升到 700~900ms，且抖动持续 10~20 分钟。查 JVM 什么都查不到，查应用日志只能看到"耗时变长"，查业务代码没有慢查询。

最后定位到的答案是：**宿主机上另一台虚拟机的备份任务在猛写磁盘，导致这个容器的脏页回写排队，Java 线程在做任何有磁盘/内存分配的路径上被内核 block 住了**。JVM 完全不知道自己被 block 了——因为在 JVM 看来，那只是一次"有点慢的系统调用"。

这就是传统观测体系的盲区：`top` 告诉你 CPU 不满，`vmstat` 告诉你 `wa` 高，但"到底有多少任务被卡住了、卡了多久、卡在哪个资源上",这些指标回答不了。Linux 4.20 引入的 **PSI（Pressure Stall Information，压力失速信息）** 就是为了填补这个空白。

本文从内核语义讲到 Java 落地：PSI 到底在数什么、`some` 和 `full` 的区别为什么关键、cgroup v2 下怎么按容器读、如何接进 Micrometer 做告警、以及四种典型抖动组合的归因决策树。

## 一、PSI 到底在数什么

PSI 的核心定义只有一句话：**它统计的是"任务因为等待某个资源而无法推进"的时间占比，而不是资源的利用率。**

这两个视角的差别是本质性的。CPU 利用率 35% 可能意味着"两个线程在 8 个核上跑满"，也可能意味着"一个线程在跑，七个在等 IO"；而 PSI 直接告诉你后者。

内核在三个位置暴露 PSI：

| 资源 | 路径 | 有 `some` | 有 `full` |
|---|---|---|---|
| CPU | `/proc/pressure/cpu` | ✅ | ❌ |
| 内存 | `/proc/pressure/memory` | ✅ | ✅ |
| IO | `/proc/pressure/io` | ✅ | ✅ |

内容格式如下（单位是百分比和微秒）：

```
$ cat /proc/pressure/memory
some avg10=12.41 avg60=8.02 avg300=3.17 total=8745123661
full avg10=6.90 avg60=4.11 avg300=1.02 total=4102331877
```

### 1.1 `some` 与 `full` 的语义差异（面试常考）

- **`some`**：至少有一个任务（`cpu` 上是至少一个可运行任务）因为该资源而停滞的时间占比。它衡量"有任务受影响"，是**广度**指标。
- **`full`**：**所有**非 idle 任务都因为该资源停滞的时间占比。也就是说在这段时间里，整个系统/整组任务**一行代码都没往前推进**。它衡量"完全瘫痪"，是**深度**指标。

为什么 CPU 没有 `full`？因为 CPU 的可运行队列里只要还有任务能跑，就不算全停；而"所有可运行任务都在等 CPU"在内核的统计口径里等价于……其实也有（runqueue 有任务但没 CPU 分给它），但内核对 CPU 只维护 `some`，因为对 CPU 来说"完全没有进度"的语义容易与调度延迟混淆。这一点在面试里被问到时要能说清楚：**不是漏了，而是 CPU 的 `full` 语义与 `some` 在设计上被认为重叠度高，只保留 `some`。**

### 1.2 三个平均窗口与累计值

`avg10 / avg60 / avg300` 是内核用指数加权移动平均（EWMA）算出的 10 秒 / 60 秒 / 300 秒压力占比，**单位是百分比**；`total` 是从开机（或 cgroup 创建）以来的**累计停滞微秒数**。

工程上怎么用这三组数？

- `avg10` 高、`avg300` 低 → **瞬时尖刺**，看是不是周期性任务（备份、日志切割、定时批处理）。
- 三个窗口都高 → **持续性资源不足**，容量问题。
- `avg300` 高、`avg10` 已经回落 → 抖动**刚刚过去**，适合做"事后归因"的触发器。

而 `total` 的真正价值是**算增量**：不要用 `avg` 做精确计算，两次采样求 `total` 差值，才能得到这段时间内准确的停滞时长。这点和 `/proc/stat` 的 jiffies 差值思路一致。

## 二、为什么 Java 应用特别需要 PSI

JVM 自带的可观测手段都有明确的"视野边界"：

| 观测手段 | 能看到 | 看不到 |
|---|---|---|
| GC 日志 | STW、晋升失败、并发周期 | 线程在 `read()` / `write()` / `mmap` 上被 block |
| `jstack` / 线程 dump | 阻塞在 socket/file 的线程 | 阻塞了多久、是不是全局性的 |
| JFR | `jdk.FileRead`、`jdk.SocketRead` 事件 | 宿主机/邻居的争抢 |
| `top` / `vmstat` | CPU 利用率、`wa` | 有多少任务真被卡住 |
| **PSI** | 任务级停滞时间的占比与累计值 | 具体是哪个进程（需配合 cgroup 分层） |

一个非常典型的链路是这样的：

```
Java 线程分配对象 → 年轻代不足 → 触发扩容 / 大对象直接进老年代
   → 需要新的物理页 → page fault → 空闲内存不足
   → 进入 direct reclaim（直接回收）→ 内核同步等待回写脏页
   → 该 Java 线程被 block 数毫秒到数十毫秒
   → 接口耗时上升，但 GC 日志里只有一次 20ms 的 Young GC
```

**`direct reclaim` 的时间是不会进 GC 日志的**，它散落在业务线程的每一次内存分配里。而 `memory.pressure` 的 `full` 值会把这段时间明确地统计出来。这正是 PSI 对 Java 服务最大的价值：**它把"JVM 之外的等待"变成了可观测的数字**。

## 三、按容器读 PSI：cgroup v2 才是关键

cgroup v1 没有 per-cgroup 的 PSI。cgroup v2 里每个 cgroup 目录下都有同名的三个文件：

```
/sys/fs/cgroup/payment-service/memory.pressure
/sys/fs/cgroup/payment-service/io.pressure
/sys/fs/cgroup/payment-service/cpu.pressure
```

在 Kubernetes 里，容器内的 `/sys/fs/cgroup` 通常就是该容器自己的 cgroup 根（cgroup v2 + systemd 驱动时可能是 `/sys/fs/cgroup/` 直接挂载），所以应用内直接读固定路径就能拿到"我这个容器"的压力，而 `/proc/pressure/*` 拿到的是**整个宿主机**的压力。二者必须区分：

| 数据源 | 视角 | 用途 |
|---|---|---|
| `/proc/pressure/*` | 宿主机全局 | 判断是不是邻居/宿主机问题 |
| `/sys/fs/cgroup/.../x.pressure` | 本容器 | 判断是不是自己被限流/被回收 |

**排查铁律：如果宿主机的 `io.pressure` 高而你的容器 `io.pressure` 低，问题不在你身上，在邻居身上。** 这个判断能省掉一整天的无效优化。

同时建议一起读 `memory.events`（cgroup v2）：

```
$ cat /sys/fs/cgroup/payment-service/memory.events
low 0
high 12402       # 触发 memory.high 节流的次数
max 0
oom 0
oom_kill 0
```

`high` 有计数而 `max` 为 0，说明容器一直被 `memory.high` 温和节流（内核在回收，不给 OOM），这往往就是"内存压着 limit 跑、延迟莫名变高"的元凶。

## 四、Java 侧落地：把 PSI 接进 Micrometer

内核自 5.2 起支持 PSI trigger（对 pressure 文件做 `poll(POLLPRI)`，超过阈值就唤醒）。Java NIO 无法对普通文件做 `POLLPRI` 等待，所以**Java 侧用固定周期采样更实际**，而 trigger 留给 systemd-oomd / oomd 这类 C 程序。

### 4.1 解析器

```java
public record PsiLine(double avg10, double avg60, double avg300, long totalMicros) {}

public record PsiSample(String resource, PsiLine some, PsiLine full) {

    private static final Pattern FIELD =
            Pattern.compile("(avg10|avg60|avg300|total)=(\\d+(?:\\.\\d+)?)");

    public static PsiSample read(Path path, String resource) throws IOException {
        PsiLine some = null, full = null;
        for (String line : Files.readAllLines(path)) {
            boolean isFull = line.startsWith("full");
            if (!isFull && !line.startsWith("some")) continue;
            double a10 = 0, a60 = 0, a300 = 0;
            long total = 0;
            Matcher m = FIELD.matcher(line);
            while (m.find()) {
                switch (m.group(1)) {
                    case "avg10"  -> a10  = Double.parseDouble(m.group(2));
                    case "avg60"  -> a60  = Double.parseDouble(m.group(2));
                    case "avg300" -> a300 = Double.parseDouble(m.group(2));
                    case "total"  -> total = Long.parseLong(m.group(2));
                }
            }
            PsiLine parsed = new PsiLine(a10, a60, a300, total);
            if (isFull) full = parsed; else some = parsed;
        }
        return new PsiSample(resource, some, full);
    }
}
```

注意两个坑：

1. **`full` 行可能不存在**（`cpu.pressure`），不能 `Objects.requireNonNull`。
2. `total` 是**微秒**，别当毫秒用，否则差 1000 倍。

### 4.2 采样与指标暴露

```java
@Component
public class PsiMetrics {

    private final Path base;
    private final MeterRegistry registry;

    public PsiMetrics(MeterRegistry registry) {
        this.registry = registry;
        // 容器内优先用 cgroup 视角，读不到再退回全局
        Path cg = Path.of("/sys/fs/cgroup");
        this.base = Files.isReadable(cg.resolve("memory.pressure")) ? cg : Path.of("/proc/pressure");
    }

    @Scheduled(fixedDelay = 1000)
    public void sample() {
        for (String res : List.of("cpu", "memory", "io")) {
            try {
                PsiSample s = PsiSample.read(base.resolve(res + ".pressure"), res);
                gauge("psi.some.avg10", res, s.some().avg10());
                gauge("psi.some.total", res, s.some().totalMicros());
                if (s.full() != null) {
                    gauge("psi.full.avg10", res, s.full().avg10());
                    gauge("psi.full.total", res, s.full().totalMicros());
                }
            } catch (IOException e) {
                // 内核未开 PSI 时静默降级，不要影响业务
                log.debug("PSI unavailable for {}", res, e);
            }
        }
    }

    private void gauge(String name, String res, double v) {
        Gauge.builder(name, () -> v).tag("resource", res).register(registry);
    }
}
```

`total` 用 Gauge 上报后，在 Prometheus 侧就能用 `rate(psi_some_total_micros[1m])` 得到"每秒停滞微秒数"，再除以 1e6 就是真实的压力占比——**比用 `avg10` 做聚合准确得多**。

### 4.3 告警阈值

经验值（不同业务需要校准，但方向一致）：

| 指标 | 预警 | 严重 | 说明 |
|---|---|---|---|
| `memory.full.avg10` | > 5% | > 15% | 超过 5% 意味着每秒有 50ms 全体停摆 |
| `io.full.avg10` | > 10% | > 25% | IO 完全停摆最难忍 |
| `io.some.avg10` | > 30% | > 60% | 部分任务在等 IO |
| `cpu.some.avg10` | > 50% | > 80% | 结合 throttling 判断是否 quota 不足 |
| `memory.events.high` 增速 | > 100/min | > 1000/min | 正在被持续节流 |

阈值必须和 SLA 联动：P99 目标 100ms 的服务和 2s 的服务，能容忍的 `full` 完全不同。**别抄别人的阈值，用自己抖动时段的 PSI 曲线反推。**

## 五、四种典型组合的归因决策树

这是本文最实用的部分。PSI 的价值不在于单个数字，而在于三个资源之间的组合关系。

```
抖动发生
├── cpu.some 高，memory/io 低
│   ├── 有 cpu.stat 的 nr_throttled 增长  → cgroup CPU quota 太小（被 throttle）
│   └── nr_throttled 不增长             → 真实 CPU 密集（GC 线程、正则、序列化）
├── io.some 高，io.full 中高，memory 低
│   ├── 本容器 io.pressure 高 → 自己的日志/落盘/大查询
│   └── 仅宿主机 io.pressure 高 → 邻居噪声，需隔离/换盘/限 io.max
├── memory.full 高
│   ├── memory.events.high 增长 → memory.high 节流，回收跟不上分配
│   ├── memory.events.max 增长  → 逼近硬限，随时 OOM
│   └── pgscan_direct 增长      → direct reclaim，分配路径被阻塞
└── 三者都不高，但 P99 高
    ├── 检查 synchronized / 锁竞争（jstack 大量 BLOCKED）
    ├── 检查 safepoint 时间（-Xlog:safepoint）
    └── 检查 DNS / 下游 RT（这已经超出 PSI 的能力范围）
```

### 5.1 案例复盘：三个同时发生的"内存问题"

回到开头那个支付服务。事后拉出的三条曲线非常典型：

1. `memory.full.avg10` 在抖动时段从 0 跳到 8%；
2. `pgscan_direct` 同步上升，`pgsteal_direct` 跟上；
3. `memory.events` 的 `high` 未增长（说明不是 `memory.high` 节流），但 `max` 也没增长（没到硬限）。

结论：**不是 cgroup 限的，是宿主机整体内存紧张导致全局 direct reclaim**。真正的原因是宿主机上跑了一台备份 VM，它的 page cache 吃掉了大部分空闲内存，导致所有容器的分配路径都要先回收。

处理方式（三步，成本从低到高）：

- **短期**：把支付服务的 `-XX:+AlwaysPreTouch` 打开，让 JVM 启动时就把堆的物理页全部拿到（避免运行时 page fault 走 reclaim），代价是启动变慢、RSS 立即到位。
- **中期**：容器加 `memory.high`（比如 limit 的 90%），把回收压力**提前、平滑**地施加在自己身上，而不是在接近 limit 时被硬回收；同时把日志目录换成独立盘，避免日志回写污染数据盘。
- **长期**：宿主机层面做资源隔离（备份任务 `io.max` + `memory.max`，或直接迁走），并对 `io.pressure`/`memory.pressure` 建告警。

改完之后 `memory.full.avg10` 峰值从 8% 降到 0.3%，P99 回到 80ms 以内。

## 六、容易踩的五个坑

1. **内核没开 PSI**：`CONFIG_PSI` 编译选项 + 启动参数 `psi=1`（多数发行版默认开）。读不到文件时应用必须优雅降级，不要抛异常打爆日志。
2. **cgroup v1 没有 per-cgroup PSI**。如果你的集群还是 v1，只能在宿主机维度看，容器归因会失效——这是升级 cgroup v2 的一个实打实的理由。
3. **把 `avg10` 当精确值做容量规划**。EWMA 只适合看趋势，容量计算一律用 `total` 差值。
4. **只盯 `full` 忽略 `some`**。很多抖动是"部分任务被卡"，`full` 依然是 0，只看 `full` 会漏掉。
5. **PSI 高就加内存**。`io.pressure` 高加内存没用；`memory.full` 高也可能是脏页回写慢而非内存不足，要看 `pgscan_direct` 与 `nr_dirty`。

## 七、面试追问

**Q1：PSI 和 load average 的区别？**
load average 数的是"可运行 + 不可中断（D 状态）"的任务数，是**队列长度**；PSI 数的是"被卡住的**时间**"。load 5 在 64 核上毫无压力，load 2 在 2 核上已经过载；而 PSI 直接给出百分比，跨机器可比。此外 load 无法区分 CPU 等待与 IO 等待的贡献，PSI 天然分资源统计。

**Q2：为什么说 `full` 比 `some` 更能代表"用户体验崩塌"？**
`some` 只要求有一个任务受影响，一个后台低优先级线程被卡就能拉高 `some`；`full` 要求所有非 idle 任务都无法推进，此时没有任何请求在被处理，直接对应请求超时。

**Q3：PSI 能替代 trace 吗？**
不能。PSI 告诉你"这段时间有 12% 的时间全体停摆"，但不告诉你是哪个 SQL、哪个文件、哪把锁。正确姿势是 **PSI 做触发与归因方向，trace/profiler 做定位**：PSI 报警 → 拉 `perf`/`biolatency`/`offcputime` → 落到具体调用栈。

**Q4：`iowait` 高就是 IO 瓶颈吗？**
不一定，这是老牌误区。`iowait` 是 CPU 处于 idle 且存在未完成 IO 的时间占比。如果 IO 是异步预读、或者设备是高速 NVMe，`iowait` 可以一直是 0 而应用依然被 IO 卡住（线程在 D 状态但 CPU 不 idle）。PSI 的 `io.some/full` 没有这个问题。

**Q5：容器里读 `/proc/pressure` 和 `/sys/fs/cgroup/*.pressure` 有什么区别？**
前者是宿主机全局视角，后者是当前 cgroup 视角。K8s 里排查必须两者对比，否则会把邻居问题误判成自己的问题。

## 八、总结

PSI 是近几年 Linux 观测体系里**性价比最高**的一个补充：零侵入、零依赖、开销极低（内核里就是几个计数器和 EWMA），却能回答"为什么 CPU 不满但服务慢"这个最贵的问题。

给 Java 团队的最小落地清单：

1. 确认内核与 cgroup 版本（PSI 需要 4.20+，per-cgroup 需要 v2）；
2. 应用内每秒采样三个 `.pressure` 文件，`total` 上报为 Counter/Gauge，用 `rate()` 算真实占比；
3. 同时采集 `memory.events`、`cpu.stat` 的 `nr_throttled`、`pgscan_direct`；
4. 按上面的决策树建 3~4 条组合告警，而不是给单个指标设阈值；
5. 把 PSI 曲线和 GC 日志、P99 曲线放在**同一张时间轴**上看——三者对齐的那一刻，答案基本就出来了。
