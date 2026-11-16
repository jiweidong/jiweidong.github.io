---
title: 【云原生】Kubernetes Pod 驱逐与 JVM 内存治理深度解析：QoS、memory.high 与 OOM 边界
date: 2026-11-16 08:00:00
tags:
  - Java
  - Kubernetes
  - JVM
  - 云原生
  - 内存治理
  - OOM
categories:
  - 性能调优
author: 东哥
---

# 【云原生】Kubernetes Pod 驱逐与 JVM 内存治理深度解析

## 一、前言

把 Java 应用搬进 Kubernetes 之后，很多团队都遇到过这样的怪事：容器退出码 137，但翻遍应用日志**找不到 `OutOfMemoryError`**；明明堆只用了 60%，Pod 却被反复驱逐；调大了 `-Xmx`，重启反而更频繁。

根因是：容器里的内存死亡路径**不止一条**。JVM 堆 OOM、cgroup OOM Kill、kubelet 驱逐、节点内核 OOM Killer，四条路径的触发者、判断依据、退出表现都不一样。只盯着 `-Xmx` 调参，等于在四条并行的高速公路上只修了一条。

本文按「谁在什么条件下杀进程」这条主线，把 Pod 驱逐与 JVM 内存治理拆开讲清楚，并给出可直接落地的配置模板与 Java 侧代码。

<!-- more -->

## 二、四条内存死亡路径

### 2.1 全景对比

| 路径 | 触发者 | 判断依据 | 进程信号 | K8s 侧表现 | 应用日志 |
|---|---|---|---|---|---|
| JVM 堆 OOM | JVM 自身 | 堆/元空间/直接内存超限 | 抛 `OutOfMemoryError` | 可能仍 Running，随后崩溃 | 有明确异常栈 |
| cgroup OOM Kill | 内核 memcg | `memory.max` 用尽且回收失败 | SIGKILL（137） | `OOMKilled`，重启计数 +1 | 通常无 |
| kubelet 驱逐 | kubelet | 节点资源低于 eviction 阈值 | SIGTERM→宽限→SIGKILL | `Evicted`，Pod 重建（可能换节点） | 可能只有 shutdown 日志 |
| 节点 OOM Killer | 内核全局 | 节点内存耗尽 | SIGKILL（137） | 可能无状态，节点 NotReady | 无 |

关键点：**137 = 128 + 9，只能说明「被 SIGKILL」，不能区分是谁杀的**。区分靠 `kubectl describe pod` 的 `Reason`/`Exit Code`/`Last State`，以及节点上的 `dmesg`。

```bash
kubectl get pod app-0 -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
# reason: OOMKilled   → cgroup 内存超限
# reason: Error, exitCode: 137 → 需要再看 describe 的 Reason: Evicted

kubectl describe pod app-0 | grep -A3 -E 'Reason|Events'
# Reason: Evicted / The node was low on resource: memory.
```

### 2.2 为什么「堆没满也会被杀」

JVM 的常驻内存远不止堆：

```
RSS ≈ Heap + Metaspace + Code Cache + Direct ByteBuffer + Thread Stack
      + GC 辅助结构（卡表/标记位图/RSet）+ JNI/glibc malloc arena + mmap 文件页
```

一个 `-Xmx2g` 的 Spring Boot 服务，实测 RSS 常见 2.6~3.2GB：堆 2g、Metaspace 150~250MB、Code Cache 100~240MB、Direct 128MB、200 个线程 × 1MB 栈、G1 的 RSet 与卡表、再加 glibc 每线程 arena（默认上限 8 × 核数，容器里 32 核就是 256 个 arena，碎片化非常明显）。如果 `limits.memory` 设成 2Gi，堆还没满，容器先被 memcg 杀掉。

## 三、kubelet 驱逐机制

### 3.1 驱逐信号与阈值

kubelet 周期性采集四类信号：

| 信号 | 默认硬阈值 | 含义 |
|---|---|---|
| `memory.available` | `< 100Mi` | 节点可分配内存 |
| `nodefs.available` | `< 10%` | 节点根盘（镜像、日志、emptyDir） |
| `imagefs.available` | `< 15%` | 镜像/容器可写层所在文件系统 |
| `pid.available` | `< 10%` | 可用 PID |

注意 `memory.available` 是**节点级**的，不是 Pod 级。也就是说：隔壁一个没有 limit 的 Pod 打爆节点，你的 Guaranteed Pod 也可能被驱逐（虽然排序靠后）。

软驱逐需要配合宽限期，写法是 `memory.available<500Mi,nodefs.available<10%,nodefs.inodesFree<5%` 这类组合：

```yaml
# kubelet 配置片段
evictionHard:
  memory.available: "300Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
evictionSoft:
  memory.available: "800Mi"
evictionSoftGracePeriod:
  memory.available: "1m30s"
evictionPressureTransitionPeriod: "30s"
```

工程经验：`evictionHard.memory.available` 不要低于 200Mi。留太少，内核在 kubelet 反应过来之前就会触发全局 OOM；留太多，又浪费节点容量。

### 3.2 QoS 与驱逐排序

| QoS | 条件 | OOM score adj | 驱逐优先级 |
|---|---|---|---|
| Guaranteed | 所有容器 CPU/内存 requests == limits | -997 | 最后 |
| Burstable | 至少一个容器设了 request/limit，但不满足 Guaranteed | 2~999（按 request 占节点比例） | 中间 |
| BestEffort | 所有容器都没设 request/limit | 1000 | 最先 |

驱逐排序不是单纯按 QoS，而是分三轮：

1. 先驱逐 **BestEffort / Burstable 且用量超过 request** 的 Pod，按「用量超出 request 的绝对值 + Priority」排序；
2. 再驱逐 **Burstable 且用量未超 request**；
3. 最后才动 Guaranteed。

所以「request 设小、limit 设大」是最危险的组合：平时跑得欢，节点一紧张就是第一批被清退的对象。

### 3.3 PriorityClass 与 PDB 的边界

`priorityClassName` 影响的是**调度抢占**和驱逐排序权重，不是免死金牌。PDB（PodDisruptionBudget）只约束**自愿中断**（drain、升级），kubelet 因资源压力驱逐时**不受 PDB 保护**。这一点在故障复盘里经常被误解。

## 四、cgroup v2：memory.high 与 memory.max

### 4.1 三个水位

| 文件 | 行为 | 是否杀进程 | JVM 是否感知 |
|---|---|---|---|
| `memory.low` | 尽力保护，回收时优先跳过 | 否 | 否 |
| `memory.high` | 超过就**限流**（直接回收 + throttle），分配变慢 | 否 | 否 |
| `memory.max` | 超过且回收失败 → memcg OOM Kill | 是 | 否 |

`memory.high` 是最容易被忽略的一档：它不杀进程，但会让应用**变慢**。表现是 GC 时间没涨、CPU 不高，但 P99 抖动、日志写入卡顿、`malloc` 变慢。因为进程每次缺页都要先做直接回收，回收不动就被 throttle 睡眠。

Java 侧完全看不到这个信号：`MemoryMXBean` 只报堆，`OperatingSystemMXBean.getCommittedVirtualMemorySize()` 也不等于 cgroup 用量。要观测只能读 cgroup 文件：

```java
// 读取容器内存状态（cgroup v2）
public record CgroupMemory(long current, long max, long high, long eventsHigh) {}

public static CgroupMemory read() throws IOException {
    Path base = Path.of("/sys/fs/cgroup");
    return new CgroupMemory(
        readLong(base.resolve("memory.current")),
        readLong(base.resolve("memory.max")),   // "max" 表示无限制
        readLong(base.resolve("memory.high")),
        readLong(base.resolve("memory.events")).stream()... // 见下
    );
}
```

`memory.events` 里几个计数器很有价值：

```
low 0
high 1273          # 触发 memory.high 限流的次数
max 12             # 触达 memory.max 的次数（危险）
oom 3              # memcg OOM 次数
oom_kill 3
```

把 `high`/`max`/`oom_kill` 三个计数打到监控里，比看 RSS 曲线更早发现「内存墙」。

### 4.2 JVM 怎么读容器 limit

`-XX:+UseContainerSupport`（JDK 10+ 默认开启）让 JVM 从 cgroup 读取 `memory.max` 作为 `MaxMemory`。注意：

- JVM **只看 `memory.max`，不看 `memory.high`**；
- 如果 `memory.max` 是 `max`（无限制），JVM 回退到**节点物理内存**，容器里就会算出巨大的堆 —— 这是「容器里默认堆过大」的经典原因；
- `-XX:MaxRAMPercentage=75` 的基数是 `memory.max`，不是 request。

推荐配比：

```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "2Gi"     # 与 request 相等，拿到 Guaranteed
    cpu: "2000m"
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:MaxRAMPercentage=70
      -XX:InitialRAMPercentage=40
      -XX:MaxMetaspaceSize=256m
      -XX:MaxDirectMemorySize=256m
      -XX:ReservedCodeCacheSize=128m
      -XX:+ExitOnOutOfMemoryError
      -XX:+HeapDumpOnOutOfMemoryError
      -XX:HeapDumpPath=/dump
      -Xlog:gc*:file=/log/gc.log:time,uptime:filecount=5,filesize=20m
```

70% 而不是 75%：给 Metaspace、Code Cache、线程栈、Direct、GC 结构留 30%。对于高并发 Netty 服务（大量 Direct ByteBuffer + 堆外池），建议降到 60~65%。

## 五、真实故障：堆转储把节点盘打满

一个很典型的连环故障：

1. 应用发生堆 OOM，`HeapDumpOnOutOfMemoryError` 把 2GB 的 `java_pid1.hprof` 写到 `emptyDir`；
2. `emptyDir` 默认落在节点根盘，节点 `nodefs.available` 跌破 10%；
3. kubelet 触发 `nodefs` 驱逐，把**同节点上其他 Pod**（包括没出问题的服务）全部 Evicted；
4. 雪崩。

治理要点：

- 堆转储目录挂**独立 PVC**，或者给 `emptyDir` 设 `sizeLimit`（超限会驱逐该 Pod，但不会拖垮节点）；
- 只在排障窗口开 `HeapDumpOnOutOfMemoryError`，日常用 `-XX:+ExitOnOutOfMemoryError` 快速失败 + 重启；
- 日志同样要限大小，`-Xlog` 的 `filecount/filesize` 必须写；
- 给 `nodefs` 单独划盘，把镜像层与业务日志分离（`imagefs` 与 `nodefs` 分开时驱逐信号才准确）。

## 六、Java 侧的可观测与自保

### 6.1 内存预算自检

启动时算一遍预算，超了就**拒绝启动**，比运行期随机被杀好得多：

```java
@Component
public class MemoryBudgetChecker implements ApplicationRunner {

    private static final long MB = 1024 * 1024;

    @Override
    public void run(ApplicationArguments args) {
        long max = Runtime.getRuntime().maxMemory();
        long cgroupMax = CgroupSupport.memoryMaxBytes();   // -1 表示无限制
        long nonHeapBudget = 256 * MB   // Metaspace
                           + 128 * MB   // Code Cache
                           + 256 * MB   // Direct
                           + 64L * MB * 200; // 200 线程栈（粗算）
        long expected = max + nonHeapBudget;

        if (cgroupMax > 0 && expected > cgroupMax * 0.95) {
            throw new IllegalStateException(String.format(
                "内存预算超限: heap=%dMB nonHeap≈%dMB total≈%dMB limit=%dMB",
                max / MB, nonHeapBudget / MB, expected / MB, cgroupMax / MB));
        }
    }
}
```

配合 Micrometer 暴露 cgroup 指标（Spring Boot 3 已自动绑定 `process.memory.usage` 等）：

```java
Gauge.builder("app.cgroup.memory.high.events", () -> readEvent("high"))
     .register(meterRegistry);
Gauge.builder("app.cgroup.memory.oom.kills", () -> readEvent("oom_kill"))
     .register(meterRegistry);
```

告警规则建议：`oom_kill` 增量 > 0 立即 P1；`high` 计数 5 分钟内持续增长 → 预警（说明已经在被限流，只是还没死）。

### 6.2 优雅停机

被驱逐时 kubelet 发 SIGTERM，宽限期默认 30s。Java 侧要保证：

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]   # 等 Endpoints 摘除传播
terminationGracePeriodSeconds: 40
```

```java
// Spring Boot 3：开启优雅停机
// server.shutdown=graceful
// spring.lifecycle.timeout-per-shutdown-phase=25s
```

`preStop sleep 5` 不是玄学：Endpoints/iptables 规则传播有延迟，直接关进程会有几秒的 502。

### 6.3 探针不要互相打架

- `startupProbe`：给慢启动兜底（Spring Boot 冷启动 30~60s），失败阈值 `failureThreshold: 30`、`periodSeconds: 5`；
- `livenessProbe`：只判断「进程是否死锁」，**不要查数据库/下游**。下游抖动会导致全量重启，把小故障放大成血崩；
- `readinessProbe`：可以查关键依赖，失败只摘流量不重启。

一个常见的错误配置是 liveness 的 `timeoutSeconds: 1`：GC 停顿超过 1s 就被判死，Pod 反复重启，看起来像「内存问题」，其实是探针问题。

## 七、排障决策树

```
容器 137 退出
├─ describe 里 Reason=Evicted
│   ├─ 信号 memory.available → 节点内存压力（看谁在吃内存，检查无 limit 的 Pod）
│   ├─ 信号 nodefs.available → 日志/堆转储/镜像堆积（du -sh /var/lib/docker /var/log）
│   └─ 信号 pid.available  → 线程/进程泄漏
├─ describe 里 Reason=OOMKilled
│   ├─ 堆接近 Xmx → 真实内存泄漏或流量上涨（开 heap dump）
│   └─ 堆远低于 Xmx → 堆外（Direct/Metaspace/线程栈/glibc arena），看 NMT
└─ 无 Reason，节点 NotReady
    └─ 内核全局 OOM（dmesg -T | grep -i 'killed process'）
```

堆外排查用 NMT：

```
-XX:NativeMemoryTracking=summary
jcmd 1 VM.native_memory summary scale=MB
```

重点看 `Other`（malloc arena/JNI）与 `Thread`（栈）两项，通常就是「堆没满但 RSS 高」的答案。

## 八、面试高频追问

**Q1：requests 和 limits 到底怎么设？**
CPU 的 request 决定调度与 `cpu.weight`，limit 决定 `cpu.max` 配额（会被 throttle）；内存的 request 影响驱逐排序与 OOM score，limit 是硬墙。生产建议：内存 request == limit（Guaranteed），CPU request 按 P50 设、limit 按 P99 或干脆不设（避免 throttle），靠 HPA 扩容。

**Q2：为什么 `-Xmx` 等于 limit 一定会被杀？**
因为堆只是 RSS 的一部分。JVM 还有 Metaspace、Code Cache、Direct、线程栈、GC 结构，以及 glibc 的 arena 碎片。堆顶到 limit 时，堆外还没算，memcg 先 OOM。

**Q3：`memory.high` 和 `memory.max` 区别？**
`high` 是软限，超了限流不杀；`max` 是硬限，超了杀。JVM 只读 `max`。设了 `high` 之后出现「无 OOM 但变慢」，要查 `memory.events` 的 `high` 计数。

**Q4：Kubernetes 的 QoS 能保证不被驱逐吗？**
不能。Guaranteed 只是排序最后、OOM score 最低。节点真没内存时一样会被驱逐，只是优先牺牲别人。

**Q5：怎么区分 cgroup OOM 和节点 OOM？**
cgroup OOM 会在 `kubectl describe` 里显示 `OOMKilled` 且容器重启计数增加；节点 OOM 是内核杀的，Pod 状态可能不变，需要 `dmesg` 里找 `Out of memory: Killed process`，同时看节点是否 NotReady。

## 九、小结

1. 137 不是结论，只是起点；先看 `Reason` 再定位是四条路径里的哪一条。
2. JVM 只认 `memory.max`，不认 `memory.high`，更不认 request；堆外必须显式预留。
3. `MaxRAMPercentage` 建议 60~70%，高 Direct 场景更低；`-Xmx` 直接等于 limit 是自找 OOMKilled。
4. 堆转储、日志、emptyDir 都可能触发 `nodefs` 驱逐，必须限容量、分盘。
5. liveness 不要查下游，startup 要给足冷启动时间。
6. 把 `memory.events` 的 `high`/`max`/`oom_kill` 打进监控，比看 RSS 曲线更早发现问题。

容器化不是把 `-Xmx` 改小就完事，它要求你把「JVM 内存模型」和「cgroup 内存模型」两张账合起来算。算清了，驱逐和 OOM 就从玄学变成可解释的事件。
