---
title: 【性能调优】eBPF 观测 Java 应用深度实战：无侵入定位 off-CPU、锁等待与 IO 抖动
date: 2026-11-05 08:20:00
tags:
  - Java
  - eBPF
  - bpftrace
  - 性能调优
  - 可观测性
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】eBPF 观测 Java 应用深度实战

## 前言

Java 的性能观测工具链已经很成熟：JFR 看 JVM 内部事件，async-profiler 出 CPU/分配/锁火焰图，Arthas 做在线诊断。但它们有一个共同的盲区——**它们都活在 JVM 内部**。

有些问题从 JVM 里根本看不见：

- 线程明明在 RUNNABLE，CPU 却上不去（等锁、等 IO、等缺页）
- GC 时间正常、业务代码正常，但 P99 有 200ms 尖刺（内核调度、TCP 重传、磁盘抖动）
- 「CPU 使用率 40% 但系统 load 30」（不可中断睡眠，D 状态）
- 容器被 CPU throttling 限制，JVM 完全无感知

这些都在内核态。而 eBPF 正是「从内核视角看 Java 进程」的那双眼睛。

---

## 一、eBPF 为什么适合做 Java 观测

### 1.1 它能观测什么

| 观测面 | JFR | async-profiler | eBPF |
|---|---|---|---|
| Java 方法耗时 | ✅ | ✅ | ❌（需 USDT，见下） |
| 对象分配 | ✅ | ✅ | ❌ |
| **off-CPU 阻塞归因** | 部分（`jdk.ThreadPark`） | ✅（wall-clock 模式） | ✅✅（内核栈 + 完整原因） |
| **锁竞争（futex）** | 部分 | ✅ | ✅ |
| **系统调用耗时** | ❌ | ❌ | ✅ |
| **TCP 重传 / 连接队列溢出** | ❌ | ❌ | ✅ |
| **块设备 IO 延迟** | ❌ | ❌ | ✅ |
| **调度延迟 / 运行队列** | ❌ | ❌ | ✅ |
| **页缺失 / 内存回收** | ❌ | ❌ | ✅ |
| 生产开销 | 低 | 中 | 可调（采样后极低） |

结论不是「谁替代谁」，而是**分工**：

> JFR 管 JVM 内部，async-profiler 管 Java 栈，eBPF 管内核与硬件之间那一层。

### 1.2 原理一句话

eBPF 把用户写的程序挂到内核的钩子上（kprobe / tracepoint / uprobe / perf_event），事件触发时在内核态执行，结果通过 ring buffer 送回用户态。**不需要改应用代码、不需要重启、不需要 agent**。

---

## 二、环境准备（含容器限制）

```bash
# 内核版本（建议 >= 5.4，最好 5.10+）
uname -r

# 安装工具
apt install -y bpfcc-tools bpftrace linux-tools-common linux-tools-$(uname -r)

# 验证
bpftrace -l 'tracepoint:syscalls:sys_enter_*' | head -3
```

### 2.1 容器里的权限

从内核 5.8 起，BPF 权限被拆成 `CAP_BPF` + `CAP_PERFMON`：

```yaml
securityContext:
  capabilities:
    add: ["BPF", "PERFMON", "SYS_RESOURCE", "SYS_PTRACE"]
```

- `SYS_RESOURCE`：提高 `RLIMIT_MEMLOCK`（老内核必须）
- `SYS_PTRACE`：读 `/proc/<pid>/stack`、做 uprobe
- 内核 < 5.8 只能 `privileged: true`（不推荐）
- 需要挂载 bpffs：`/sys/fs/bpf`

```bash
# 检查是否被禁用
cat /proc/sys/kernel/unprivileged_bpf_disabled   # 2 = 完全禁用，需特权
```

> 阿里云/腾讯云的托管 K8s，很多默认策略会拦 `CAP_BPF`，需要走特权 DaemonSet 或在节点侧采集。这是落地时第一个现实障碍。

---

## 三、四个高频实战脚本

### 3.1 场景一：CPU 不高但慢——off-CPU 分析

**症状**：8 核机器，Java 进程 CPU 300%，QPS 上不去，P99 400ms。

```bash
# bcc 自带，统计被阻塞的时长与内核栈
offcputime -f -p $(pgrep -f 'java.*myapp') 30 > offcpu.folded
# 生成火焰图
flamegraph.pl --color=io --title="Off-CPU" offcpu.folded > offcpu.svg
```

输出里最常看到的栈：

```
futex_wait_queue_me
  do_futex
    __futex_wait
      [java] java.util.concurrent.locks.LockSupport.park
```

这就是「Java 层看到的 `park`」，但 eBPF 补上了**内核侧等了多久、被谁唤醒**。

用 bpftrace 自己写一个更聚焦的版本（统计每个 Java 线程的阻塞分布）：

```bash
bpftrace -e '
tracepoint:sched:sched_switch
/args->prev_comm == "java" && args->prev_state == 2/
{
    @start[args->prev_pid] = nsecs;
}

tracepoint:sched:sched_switch
/args->next_comm == "java" && @start[args->next_pid]/
{
    $d = nsecs - @start[args->next_pid];
    @blocked_us = hist($d / 1000);
    delete(@start[args->next_pid]);
}

interval:s:30 { exit(); }
'
```

`prev_state == 2` 是 `TASK_UNINTERRUPTIBLE`，也就是 D 状态。**如果 D 状态时间很长，八成是磁盘或网络文件系统**。

### 3.2 场景二：系统调用谁最慢

```bash
bpftrace -e '
tracepoint:raw_syscalls:sys_enter
/pid == $1/ { @start[tid] = nsecs; @name[tid] = args->id; }

tracepoint:raw_syscalls:sys_exit
/pid == $1 && @start[tid]/
{
    $us = (nsecs - @start[tid]) / 1000;
    @lat[@name[tid]] = hist($us);
    delete(@start[tid]); delete(@name[tid]);
}

interval:s:20 { exit(); }
' -p $(pgrep -f 'java.*myapp')
```

Java 服务里最慢的 syscall 通常是 `epoll_wait`（正常，是空闲等待）、`futex`（锁）、`read`/`write`（IO）、`sendto`（网络）。

判断要点：**`epoll_wait` 占大头 = 正常；`futex` 占大头 = 锁竞争；`read` 慢 = 磁盘或 NFS**。

### 3.3 场景三：TCP 层的问题（JVM 看不见）

```bash
# 重传统计
bpftrace -e 'tracepoint:tcp:tcp_retransmit_skb { @[comm, args->saddr] = count(); }'

# 或者用现成工具
tcpretrans -p $(pgrep -f java)     # bcc
```

线上一个经典案例：客户端 P99 抖动，服务端 JFR 完全正常。eBPF 抓到最后是 `tcp_retransmit_skb` 每 30 秒集中出现——原因是 NAT 网关的 conntrack 表满，不是应用问题。

同类还有：

```bash
# 连接队列溢出（SYN 丢包）
bpftrace -e 'tracepoint:sock:inet_sock_set_state
/args->newstate == 7/ { @over = count(); }'   # TCP_CLOSE 状态转换异常

# 监听队列溢出计数
nstat -az | grep -E 'ListenOverflows|ListenDrops'
```

`ListenOverflows > 0` 说明 `backlog` 太小或 accept 太慢，这个指标在 JVM 里永远看不到。

### 3.4 场景四：块设备 IO 延迟

```bash
biolatency -m 10        # 毫秒级直方图
# 或按进程过滤
biolatency -m -P 10 | grep java
```

如果 P99 落在 50~100ms 档，而应用层只读几百 KB，那大概率是 **page cache miss + 云盘 IOPS 打满**（云盘有 burst 额度，用完就掉速）。

---

## 四、能不能直接用 eBPF 抓 Java 方法？

可以，但有前提。HotSpot 支持 USDT 探针（`hotspot:gc__begin`、`hotspot:method__entry`），但：

```bash
# 检查 libjvm.so 是否带 USDT
readelf -n $JAVA_HOME/lib/server/libjvm.so | grep -i provider
```

**大多数发行版 OpenJDK 构建默认不开启 DTrace/USDT**（需要 `--enable-dtrace` 编译）。没有 provider 输出，就挂不上 `uprobe:/path/libjvm.so:...`。

替代路径：

1. **async-profiler 的 wall-clock 模式**：`-e wall -t`，本质是用 `perf_event` 采样线程栈，能覆盖 off-CPU，Java 栈完整。
2. **JFR 的 `jdk.ExecutionSample` + `jdk.NativeMethodSample`**：JFR 从 JDK 16 起支持 native 方法采样。
3. **eBPF uprobe 到 JVM 的 `Java_*` JNI 入口**：只能抓 native 方法调用，粒度粗。
4. **自建 USDT**：用 `-XX:+DTraceMethodProbes`（需 DTrace 构建版本），生产罕见。

所以实战建议是：**Java 栈用 async-profiler/JFR，内核栈用 eBPF，两者用同一时间窗对齐**。

---

## 五、生产落地的四个注意点

### 5.1 开销控制

| 手段 | 说明 |
|---|---|
| 用采样不用全量 | `profile:hz:99` 而非每次事件 |
| 缩小过滤范围 | `pid == $1` 一定要加，否则全机事件 |
| 限制 map 大小 | `--map-keys 1024`，避免内核内存膨胀 |
| 控制输出频率 | 用 `hist()`/`count()` 聚合，不要每条 `printf` |
| 定时退出 | `interval:s:30 { exit(); }` |

经验值：99Hz 采样 + pid 过滤，CPU 开销通常 < 1.5%。

### 5.2 不能做的事

- **不要在内核里做字符串拼接**（bpftrace 的 `printf` 会走 perf buffer，量大时丢事件）
- **不要在 kprobe 里 sleep**（不可能，验证器会拒绝）
- **不要依赖 eBPF 做业务埋点**（它是观测工具，不是 tracing 系统）

### 5.3 与现有体系的组合

```
┌─────────────── JVM 层 ───────────────┐
│ JFR（GC、锁、异常、线程）             │
│ Micrometer → Prometheus（业务指标）    │
└──────────────────────────────────────┘
┌─────────────── 内核层 ───────────────┐
│ eBPF（syscall、调度、TCP、IO）        │
│ node_exporter（机器指标）              │
└──────────────────────────────────────┘
        ↓ 同一条 traceId / 同一时间窗
┌─────────────── 关联分析 ─────────────┐
│ 把 JFR 事件时间戳与 eBPF 直方图对齐     │
└──────────────────────────────────────┘
```

真实排障时最有价值的动作：**把 JFR 的 GC pause 时间窗和 eBPF 的 `runqlat`/`biolatency` 直方图叠在一起看**。如果 GC pause 期间正好有大量 D 状态，那「GC 慢」只是表象，根因是 IO。

### 5.4 云厂商的替代品

- 阿里云 ARMS / SLS 的 eBPF 采集
- Datadog 的 `system-probe`
- Pixie（K8s 原生，自带 eBPF 采集与 Java 支持）

自建 vs 采购，取决于你是否需要「按需临时抓 30 秒」的能力。托管产品通常只给你固定指标，临时深挖还得自己上手。

---

## 六、面试追问

**Q1：JFR 和 eBPF 的区别？**

JFR 是 JVM 内部事件记录器（GC、锁、异常、线程、分配采样），只能看到 JVM 认为发生的事；eBPF 是内核级可观测框架，能看到 syscall、调度、网络、块设备。前者回答「Java 里发生了什么」，后者回答「操作系统对 Java 做了什么」。

**Q2：线上 CPU 不高但 RT 高，你怎么排查？**

先用 `top` 看 load 与 CPU 的背离 → `vmstat 1` 看 `r`（运行队列）和 `b`（阻塞数）→ 若 `b` 大，用 eBPF `offcputime` 抓 off-CPU 栈 → 区分是 futex（锁）、IO（磁盘/NFS）、还是网络。最后回到 Java 层定位具体锁或连接池。

**Q3：eBPF 会不会影响性能？**

会，但可控。关键是采样率、pid 过滤、聚合输出、map 大小。99Hz + pid 过滤下通常 < 1.5% CPU。全量 `printf` 是性能杀手。

**Q4：容器里跑 eBPF 有什么限制？**

需要 `CAP_BPF`/`CAP_PERFMON`（内核 5.8+）或 privileged；需要访问 `/sys/kernel/debug` 或 bpffs；`unprivileged_bpf_disabled=2` 时普通用户完全不能用；部分托管 K8s 会直接拦截。

**Q5：怎么观测 Java 方法级耗时？**

eBPF 抓 Java 方法需要 USDT 探针，而主流 OpenJDK 构建默认未开启。所以方法级用 async-profiler（perf_event + Java 栈展开）或 JFR，eBPF 负责内核侧。

---

## 七、踩坑清单

1. **`bpftrace` 装了但 `-l` 列不出 tracepoint**：内核没开 `CONFIG_DEBUG_INFO_BTF`，或 debugfs 未挂载。
2. **容器里 `pgrep -f java` 拿到的是宿主机 PID**：要用 `nsenter -t <pid> -p` 或直接在容器 PID namespace 内执行。
3. **`offcputime` 输出全是 `epoll_wait`**：那是空闲等待，别当成问题。要看的是阻塞时长 **P99**，不是总和。
4. **`-p` 参数写错导致抓到全机事件**：`bpftrace` 的 `-p` 是 pid，`-c` 是 command，别混。
5. **火焰图看不出东西**：folded 文件必须先 `flamegraph.pl`，且 `-f`（full stack）要开。
6. **生产直接跑 `biolatency -D`**：`-D` 是输出到文件并常驻，忘记 `Ctrl-C` 会一直挂着。
7. **把 eBPF 当 APM 用**：它不适合做请求级追踪（没有 traceId），只适合做「系统行为归因」。

---

## 总结

eBPF 给 Java 工程师补上的，是「JVM 之外那半张图」：

- **off-CPU 归因**：线程在等什么，等了多久
- **syscall/网络/磁盘**：OS 层到底发生了什么
- **调度与容器 throttling**：CPU 上不去的真相

三层工具各司其职：

| 问题域 | 工具 |
|---|---|
| 业务指标 | Micrometer + Prometheus |
| JVM 内部 | JFR + jcmd |
| Java 栈（CPU/分配/锁/wall） | async-profiler |
| 内核与硬件 | eBPF（bpftrace/bcc） |

排障的最高境界不是「哪个工具最强」，而是**在正确的层次问正确的问题**。这篇讲完内核层，下一篇回到 Java 层，聊 `Prompt 版本管理` 那类工程化问题——从「观测」走向「治理」。
