---
title: 【JVM 云原生】容器 CPU Limit 与 JVM 并行度适配深度解析：ActiveProcessorCount、GC 线程与线程池 sizing
date: 2026-11-01 08:15:00
tags:
  - Java
  - JVM
  - Kubernetes
  - cgroup
  - 性能调优
  - 云原生
categories:
  - JVM
author: 东哥
---

# 【JVM 云原生】容器 CPU Limit 与 JVM 并行度适配深度解析

## 前言

先说一个我亲历的事故。

一个 Spring Boot 服务迁到 K8s，Pod 配置 `limits.cpu: 2`。上线后 P99 从 80ms 涨到 900ms，CPU 使用率却只有 **35%**——监控上看"资源很闲"，业务上"响应很慢"。

排查了两天才定位：**JVM 认为这台机器有 64 个核**。

于是：

- G1 开了 **41 个 ParallelGCThreads**（`8 + (64-8)×5/8 = 43`，受堆大小微调）
- `ForkJoinPool.commonPool` 并行度 = **63**
- Netty EventLoop = **128** 个线程
- 虚拟线程的 carrier pool 并行度 = **64**
- 各种 `Executors.newFixedThreadPool(availableProcessors)` 全部按 64 起步

64 个线程抢 2 个核的 quota，**每次 cgroup 周期（100ms）配额在 20ms 内就被打光**，剩下 80ms 全部被 throttle（限流挂起）。表现出来就是：CPU 利用率低（因为大部分时间被强制睡眠），延迟却极高（每次唤醒要等下一个周期）。

这篇文章把 **cgroup CPU 语义 → JVM 如何感知 → 哪些组件跟着变 → 怎么调** 这条链讲透。这是 Java 上云之后必须掌握的一块，也是中高级面试的高频区。

---

## 一、JVM 是怎么"看见" CPU 的

### 1.1 三个关键开关

| 参数 | 默认值 | 作用 |
|---|---|---|
| `-XX:+UseContainerSupport` | **true**（JDK 10+，8u191 回移） | 让 JVM 读 cgroup 限制，而不是只看宿主机核数 |
| cgroup v2 支持 | JDK 15+ | 读 `cpu.max`、`memory.max` 等 unified 层级 |
| `-XX:ActiveProcessorCount=N` | 未设置 | **强行覆盖** JVM 计算出的 CPU 数 |

验证当前 JVM 到底看到了什么，一条命令：

```bash
java -XshowSettings:system -version
```

输出里这段是关键：

```
Operating System Metrics:
    Provider: cgroupv2
    Effective CPU Count: 2
    CPU Period: 100000us
    CPU Quota: 200000us
    CPU Shares: 1024us
    ...
    Container (cgroup) Host Name: my-pod-7d9f8
```

**如果 `Effective CPU Count` 等于宿主机核数，那 `UseContainerSupport` 就是没生效**（常见于用了非标准 JDK 镜像、或 `JAVA_TOOL_OPTIONS` 里被显式关掉）。

### 1.2 JVM 内部的计算逻辑

HotSpot 的 `os::active_processor_count()` 大致是：

```
候选 1：CPU affinity / cpuset 的 CPU 数（taskset、cpuset.cpus）
候选 2：cgroup CPU quota 换算出的核数 = ceil(quota / period)
结果   ：min(候选1, 候选2)，且至少为 1
```

三个必须记住的细节：

**① 是 `ceil` 不是 `floor`。**
`cpu.max = 150000 100000`（1.5 核）→ JVM 认为有 **2** 个核。所以 1.5 核的 limit 会让 JVM 高估 33%。

**② 只看 quota（limit），不看 shares（request）。**
K8s 会把 `requests.cpu` 换算成 cgroup 的 `cpu.shares`/`cpu.weight`（相对权重，只在节点争抢时生效），把 `limits.cpu` 换算成 `cpu.cfs_quota_us`/`cpu.max`（硬上限）。**JVM 完全不读 shares**。

这带来一个经典困惑：**"我只设了 requests 没设 limits，JVM 为什么还是看到 64 核？"** 因为没设 limit = 没有 quota = JVM 只看 cpuset，而 K8s 默认不绑 cpuset。

**③ cgroup v1 和 v2 的路径不同。**

```bash
# cgroup v1
cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us    # 200000
cat /sys/fs/cgroup/cpu/cpu.cfs_period_us   # 100000
cat /sys/fs/cgroup/cpu/cpu.shares          # 1024

# cgroup v2
cat /sys/fs/cgroup/cpu.max                 # "200000 100000"  或 "max 100000"
cat /sys/fs/cgroup/cpu.weight              # 1~10000
cat /sys/fs/cgroup/cpu.stat                # nr_periods / nr_throttled / throttled_usec
```

在 Pod 里执行这几条命令，是排查 CPU 相关问题的**第一步**，比你翻任何文档都快。

---

## 二、三种 CPU 语义：quota / shares / cpuset

这是面试最爱问、落地最容易混的地方。

| 机制 | K8s 来源 | cgroup 文件 | 语义 | JVM 是否感知 |
|---|---|---|---|---|
| **quota（带宽限制）** | `limits.cpu` | `cpu.max` / `cfs_quota_us` | **硬上限**：每 100ms 周期内最多用 N ms CPU，超了就被 throttle | ✅ 感知（换算成核数） |
| **shares（权重）** | `requests.cpu` | `cpu.weight` / `cpu.shares` | **相对权重**：只在节点 CPU 争抢时决定分配比例，空闲时可用满 | ❌ 不感知 |
| **cpuset（绑核）** | `--cpuset-cpus` / CPU Manager static 策略 | `cpuset.cpus` | **物理绑定**：只能用指定核，无 throttle，无争抢 | ✅ 感知（数量） |

### 2.1 为什么"低 CPU 使用率 + 高延迟"会同时出现

这是 quota 机制的核心副作用。假设 2 核 quota = 每 100ms 有 200ms CPU 时间：

```
0ms    进程被唤醒，64 个线程同时跑
0~20ms 疯狂消耗 CPU（20ms × 64 并发 = 远超 200ms 配额？不，是实际占用时间）
       —— 实际上 20ms 内就能把 200ms 配额耗完（10 个线程常驻就够）
20ms   cgroup 判定超额 → 本周期内所有线程被 throttle（强制不可运行）
100ms  新周期开始，配额重置，线程重新被调度
```

于是：

- **CPU 使用率 = 200ms / 1000ms（10 核秒尺度上）= 20%** —— 看起来"很闲"
- **每次唤醒平均要等 40ms**（100ms 周期内随机点被 throttle）—— 延迟爆炸

**这就是"CPU 利用率低但延迟高"的根因。** 看到这个组合，第一反应就应该是查 throttle。

### 2.2 量化 throttle

```bash
# cgroup v2（Pod 内）
cat /sys/fs/cgroup/cpu.stat
```

```
nr_periods 14820        # 总周期数
nr_throttled 9134       # 被 throttle 的周期数  ← 61.6% 的周期都在被限流！
throttled_usec 594128000 # 累计被限流的总时长（微秒）
```

**经验阈值：**

- `nr_throttled / nr_periods` > 10% → 有问题
- > 30% → 严重，延迟尖刺必然出现
- `throttled_usec / nr_periods` 均值 > 10ms → 每次限流都是可感知的卡顿

Prometheus 侧对应指标（cadvisor）：

```promql
rate(container_cpu_cfs_throttled_periods_total{container="app"}[5m])
/
rate(container_cpu_cfs_periods_total{container="app"}[5m])
```

**这个指标应该进你的 SLO 看板。** 它比 CPU 使用率有用十倍。

---

## 三、JVM 里有哪些东西跟着 `availableProcessors` 变

这是本文的核心表格，建议收藏。

| 组件 | 默认值公式 | 过大后果 | 调优参数 |
|---|---|---|---|
| G1 ParallelGCThreads | `ncpu ≤ 8 ? ncpu : 8 + (ncpu-8)×5/8` | 并发标记/Young GC 线程过多，抢 CPU、GC 停顿反而变长 | `-XX:ParallelGCThreads=N` |
| G1 ConcGCThreads | 约 `ParallelGCThreads / 4` | 并发标记阶段抢走业务 CPU | `-XX:ConcGCThreads=N` |
| ForkJoinPool.commonPool | `ncpu - 1`（最小 1） | `parallelStream` / `CompletableFuture.supplyAsync` 默认用它，任务排队 | `-Djava.util.concurrent.ForkJoinPool.common.parallelism=N` |
| 虚拟线程 carrier pool | `ncpu`（`jdk.virtualThreadScheduler.parallelism`） | 64 个 carrier 抢 2 核 → pinning 之外还要抢调度 | `-Djdk.virtualThreadScheduler.parallelism=N` |
| JIT 编译线程 | `CICompilerCount`，随 ncpu 缩放 | 编译线程和业务抢 CPU（启动期尤其明显） | `-XX:CICompilerCount=N` |
| Netty EventLoop | `ncpu × 2` | 128 个 EventLoop 线程，每个 1MB 栈 → 128MB + 上下文切换 | 自定义 `NioEventLoopGroup(n)` |
| Tomcat `maxThreads` | 200（**不随 CPU 变**） | 与 CPU 无关但常被误调 | `server.tomcat.threads.max` |
| HikariCP `maximumPoolSize` | 10（**不随 CPU 变**） | 同上 | `spring.datasource.hikari.maximum-pool-size` |
| ScheduledThreadPool 默认 | 1 | 无影响 | — |
| `ForkJoinPool` 自定义 | 需显式传参 | — | — |

**两个反直觉的点：**

1. **Tomcat 和 HikariCP 的默认值不随 CPU 变**，所以"64 核 → 2 核"的迁移里，它们不是问题源。真正爆炸的是 **GC 线程、Netty、commonPool、虚拟线程 carrier**。
2. **GC 线程爆炸的伤害是隐性的**：不是"线程太多所以慢"，而是"GC 线程抢走了业务线程的 CPU 配额，导致 quota 提前耗尽"。你会在 GC 日志里看到"GC 时间不长"（因为每个线程干得少），但业务延迟暴涨。

---

## 四、诊断：一次完整的现场勘查

### 4.1 容器内一次性取证脚本

```bash
#!/bin/sh
echo "===== cgroup 版本 ====="
stat -fc %T /sys/fs/cgroup/ 2>/dev/null   # cgroup2fs => v2

echo "===== CPU 限制 ====="
[ -f /sys/fs/cgroup/cpu.max ] && cat /sys/fs/cgroup/cpu.max
[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && \
  echo "quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"

echo "===== CPU 统计（throttle） ====="
[ -f /sys/fs/cgroup/cpu.stat ] && cat /sys/fs/cgroup/cpu.stat

echo "===== JVM 视角 ====="
java -XshowSettings:system -version 2>&1 | grep -A6 "Operating System Metrics"

echo "===== 运行时真实值 ====="
jcmd 1 VM.system_properties 2>/dev/null | grep -i processor
jcmd 1 VM.flags 2>/dev/null | tr ' ' '\n' | grep -Ei "ParallelGCThreads|ConcGCThreads|ActiveProcessor"
```

### 4.2 打印"JVM 实际用了几核、几个 GC 线程"

```java
@Component
public class RuntimeDiagnostics implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(RuntimeDiagnostics.class);

    @Override
    public void run(ApplicationArguments args) {
        Runtime rt = Runtime.getRuntime();
        log.info("availableProcessors={}", rt.availableProcessors());
        log.info("commonPool.parallelism={}", ForkJoinPool.commonPool().getParallelism());
        log.info("maxMemory={}MB", rt.maxMemory() / 1024 / 1024);

        // 通过 MXBean 读 GC 线程数的近似值
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            log.info("GC[{}] collections={} time={}ms",
                    gc.getName(), gc.getCollectionCount(), gc.getCollectionTime());
        }

        // 虚拟线程 carrier 并行度（JDK 21+ 可通过系统属性推断）
        log.info("vthread.parallelism={}",
                System.getProperty("jdk.virtualThreadScheduler.parallelism", "default(=ncpu)"));

        // 容器环境下的"有效核数"与宿主机核数对比
        int ncpu = rt.availableProcessors();
        if (ncpu <= 2) {
            log.warn("Running with {} CPUs — 请检查 GC 线程/Netty/线程池是否按小规格调优", ncpu);
        }
    }
}
```

**这段代码的价值在于：它把"JVM 以为的世界"写进日志。** 每次发版都能看到，比事后排查便宜太多。

---

## 五、调优：从"能跑"到"跑得好"

### 5.1 方案一：直接对齐（最简单）

```yaml
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:ActiveProcessorCount=2
      -XX:ParallelGCThreads=2
      -XX:ConcGCThreads=1
      -XX:CICompilerCount=2
```

**注意 `ActiveProcessorCount` 是"命令行级别"的最高优先级**，设了它，`availableProcessors()`、GC 线程推导、commonPool、虚拟线程 carrier 全部跟着变。

一个 2 核 Pod 的合理取值：

| 参数 | 建议值 | 理由 |
|---|---|---|
| `ActiveProcessorCount` | = limit 向上取整 | 与 cgroup 一致 |
| `ParallelGCThreads` | `min(ncpu, 4)`，2 核就 2 | 超过 ncpu 无意义，只是抢 CPU |
| `ConcGCThreads` | `max(1, ncpu/4)` | 1~2 |
| `CICompilerCount` | 2（分层编译）| 默认值在大核数下是 4+ |
| commonPool parallelism | ncpu-1（默认即可，设了 ActiveProcessorCount 后自动对） | — |
| Netty EventLoop | 显式 `new NioEventLoopGroup(2)` | 别用默认 `2×ncpu` |
| Tomcat maxThreads | 200 → 视 IO 比例，2 核建议 50~100 | 太大只是排队更长 |

### 5.2 方案二：不设 limit，只设 request（推荐给延迟敏感服务）

这是 K8s 社区的经典建议（"CPU limits are harmful"）：

```yaml
resources:
  requests:
    cpu: "2"        # 保证调度 + 设置 shares 权重
  # limits.cpu 不设 → 没有 quota → 不会被 throttle
```

**代价**：节点超卖时可能被别的 Pod 抢 CPU（但至少不会出现 100ms 周期的硬截断）。

**收益**：彻底消灭 throttle 尖刺，P99 通常能降 30%~60%。

但有个坑：**不设 limit 时 JVM 看到的是宿主机核数**（没 cpuset 绑定），所以**必须显式配 `ActiveProcessorCount`**，否则还是会开 40+ 个 GC 线程去抢。

**最佳实践组合：**

```yaml
resources:
  requests: { cpu: "2", memory: "2Gi" }
  limits:   { memory: "2Gi" }        # 只限内存，不限 CPU
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-XX:ActiveProcessorCount=2 -XX:MaxRAMPercentage=70"
```

### 5.3 方案三：CPU Manager static 绑核（低延迟场景）

```yaml
# kubelet 配置
cpuManagerPolicy: static
```

Pod 声明 `requests.cpu` 为整数且等于 `limits.cpu`，即可获得 **独占物理核**：

```yaml
resources:
  requests: { cpu: "2", memory: "2Gi" }
  limits:   { cpu: "2", memory: "2Gi" }
```

此时容器看到 `cpuset.cpus = 3-4`，**没有 throttle、没有 CPU 迁移、没有邻居干扰**。JVM 会自动读到 2 核，**不需要 `ActiveProcessorCount`**。

代价：节点上可绑核的 Pod 数量受限，碎片率高。适合交易、网关这类延迟敏感服务。

### 5.4 线程池 sizing：别再写 `availableProcessors * 2`

最常见的错误代码：

```java
// ❌ 在容器里就是灾难
int core = Runtime.getRuntime().availableProcessors() * 2;
ExecutorService pool = Executors.newFixedThreadPool(core);
```

正确的思路是 **按"任务类型"而不是"核数"来定**：

```java
@Configuration
public class ExecutorConfig {

    /**
     * CPU 密集型：并行度 ≈ ncpu + 1
     * 用于：本地计算、编解码、序列化
     */
    @Bean("cpuPool")
    public ExecutorService cpuPool() {
        int n = Math.max(1, Runtime.getRuntime().availableProcessors()) + 1;
        return new ThreadPoolExecutor(n, n, 0L, TimeUnit.MILLISECONDS,
                new LinkedBlockingQueue<>(1024),
                namedFactory("cpu-"),
                new ThreadPoolExecutor.CallerRunsPolicy());
    }

    /**
     * IO 密集型：并行度 ≈ ncpu × (1 + 等待时间/计算时间)
     * 但上限受下游容量约束 —— 打 LLM / 打数据库时，瓶颈不在你这边
     */
    @Bean("ioPool")
    public ExecutorService ioPool() {
        int ncpu = Math.max(1, Runtime.getRuntime().availableProcessors());
        int n = ncpu * 8;               // 经验起点，再用压测校准
        return new ThreadPoolExecutor(n, n, 60L, TimeUnit.SECONDS,
                new LinkedBlockingQueue<>(2048),
                namedFactory("io-"),
                new ThreadPoolExecutor.CallerRunsPolicy());
    }

    private static ThreadFactory namedFactory(String prefix) {
        AtomicInteger seq = new AtomicInteger();
        return r -> {
            Thread t = new Thread(r, prefix + seq.incrementAndGet());
            t.setDaemon(true);
            return t;
        };
    }
}
```

**关于 `CallerRunsPolicy`**：很多人怕它"阻塞调用线程"，但在 IO 池里它恰恰是最好的背压手段——队列满了就让提交者自己跑，天然限速，比 `AbortPolicy` 抛异常导致业务失败要好。

**关于虚拟线程**：如果你用 `Executors.newVirtualThreadPerTaskExecutor()`，**不要再用固定大小池**——虚拟线程的价值就是"一任务一线程，靠 carrier 池限流"。此时唯一要调的是：

```bash
-Djdk.virtualThreadScheduler.parallelism=2   # 默认 = ActiveProcessorCount
-Djdk.virtualThreadScheduler.maxPoolSize=8   # carrier 池上限
```

**`parallelism` 不要大于 CPU limit**，否则 carrier 之间互相抢配额，等于自己给自己制造 throttle。

---

## 六、一个完整的对照实验设计

想证明"CPU 数调对了有用"，别靠感觉，做对照：

```bash
# A 组：默认（JVM 看到宿主核数）
java -jar app.jar

# B 组：对齐 limit
java -XX:ActiveProcessorCount=2 -XX:ParallelGCThreads=2 -jar app.jar

# 压测（固定 QPS，看延迟分布）
wrk -t4 -c64 -d60s --latency http://localhost:8080/api/search
```

**观察四个指标：**

| 指标 | 看哪里 | A 组（错误配置） | B 组（对齐） |
|---|---|---|---|
| P99 延迟 | wrk / Prometheus | 高且有规律尖刺 | 平滑 |
| CPU 使用率 | container_cpu_usage | 低（20%~35%） | 接近 limit |
| throttle 比例 | `nr_throttled/nr_periods` | 高（>50%） | 低（<5%） |
| GC 线程数 | `jcmd VM.flags` | 40+ | 2 |

**如果 A 组 CPU 使用率低而延迟高，B 组两样都正常，结论就成立。** 这个实验做一次，你对这块的理解就固化了。

---

## 七、面试追问与踩坑清单

**Q1：JVM 怎么知道容器给了几个核？**

JDK 10+ 默认开 `UseContainerSupport`，读 cgroup 的 CPU quota（v1 `cpu.cfs_quota_us`/`cpu.cfs_period_us`，v2 `cpu.max`）和 cpuset，取**两者最小值**，且至少为 1。注意是 `ceil(quota/period)`，1.5 核会被算成 2。

**Q2：为什么 CPU 利用率上不去，延迟却很高？**

cgroup CPU quota 是**按 100ms 周期结算**的。线程在周期前段就把配额耗尽，后段被 throttle 强制睡眠，直到下个周期。这期间 CPU "空闲"但不给用，所以利用率低、延迟高。查 `cpu.stat` 的 `nr_throttled`。

**Q3：`requests.cpu` 和 `limits.cpu` 在 cgroup 里分别对应什么？**

request → `cpu.weight`（v2）/ `cpu.shares`（v1），是**相对权重**，只在争抢时生效；limit → `cpu.max`（v2）/ `cpu.cfs_quota_us`（v1），是**硬上限**，超了 throttle。**JVM 只认后者。**

**Q4：`ActiveProcessorCount` 会影响什么？**

影响 `Runtime.availableProcessors()` 的返回值，进而影响：GC 线程数推导、`ForkJoinPool.commonPool` 并行度、虚拟线程 carrier 并行度、JIT 编译线程数、以及所有"按核数初始化"的池（Netty、部分框架）。**不影响** Tomcat `maxThreads`（默认 200）和 HikariCP `maximumPoolSize`（默认 10）。

**Q5：JDK 21 的虚拟线程在容器里要注意什么？**

carrier pool 的并行度默认等于 `availableProcessors`。如果 JVM 误判为 64 核而实际只有 2 核，会开 64 个 carrier 线程抢 2 核配额，throttle 更严重。用 `-Djdk.virtualThreadScheduler.parallelism=<ncpu>` 校正。另外注意 **pinning**（`synchronized` 块中阻塞会占住 carrier）。

**踩坑 1：只调 `-Xmx` 不调 CPU。**
内存和 CPU 是两套独立机制。`-XX:MaxRAMPercentage` 解决了堆，但 GC 线程数还是按错的核数来的。

**踩坑 2：`-XX:ParallelGCThreads` 设得比核数还大。**
"多线程 GC 更快"是错觉。GC 线程数 > 可用核数只会增加上下文切换和同步开销。2 核就配 2。

**踩坑 3：以为设了 `limits.cpu` 就不会被抢。**
limit 只保证"不超过"，不保证"能拿到"。如果 `requests` 设得低，节点超卖时你的进程可能连配额都跑不满。

**踩坑 4：在 initContainer 里跑 `java -XshowSettings` 判断配置。**
initContainer 的 cgroup 限制可能和主容器不同（取决于配置），要到**主容器运行时**验证。

**踩坑 5：JIT 编译线程和业务抢 CPU。**
大核数误判会开 4~8 个 C1/C2 编译线程。启动阶段它们疯狂抢 CPU，正好撞上业务预热，表现为"启动后前 30 秒延迟抖动"。配 `-XX:CICompilerCount=2`。

**踩坑 6：Netty 默认 `2 × ncpu`。**
64 核 → 128 个 EventLoop，每个线程 1MB 栈 = 128MB 常驻，加上 selector 的 fd 开销。**显式 `new NioEventLoopGroup(2)`**，或按"每个 EventLoop 处理 N 个连接"估算。

---

## 八、总结

| 结论 | 说明 |
|---|---|
| 上云第一件事 | 确认 `Effective CPU Count` 与 limit 一致，`java -XshowSettings:system` 一条命令搞定 |
| quota 的本质 | 100ms 周期的硬预算，超了就强制睡眠 → "低利用率 + 高延迟"的元凶 |
| JVM 只认 quota，不认 shares | request 调再大，JVM 核数也不会变 |
| 最省事的修法 | `-XX:ActiveProcessorCount=<limit>` + `ParallelGCThreads` + Netty 显式线程数 |
| 延迟敏感服务的更优解 | 不设 CPU limit（只设 request）+ 显式 `ActiveProcessorCount`，消灭 throttle |
| 线程池 sizing | 按任务类型（CPU/IO）算，别用 `ncpu×2`；虚拟线程场景只调 carrier 并行度 |

容器化把"机器"这个概念打碎了：**JVM 以为它在独占一台 64 核的机器，实际它只是这台机器上被限速的一个租户。** 所有"按核数自动推导"的默认值，在容器里都可能变成陷阱。

理解了 `quota/shares/cpuset` 三层语义，你再看 K8s 的 `resources` 配置、再看 JVM 的 GC 线程推导、再看 Netty 的 EventLoop 默认值，会发现它们本来就不是一个层面的东西——**把它们对齐，是云原生 Java 的基本功。**

> 下一篇会讲 **cgroup 内存限制这条线**：`MaxRAMPercentage` 与 `Xmx` 的冲突、`UseContainerSupport` 下的堆外内存核算、以及 K8s `OOMKilled`（exit 137）与 JVM `OutOfMemoryError` 的区分方法。
