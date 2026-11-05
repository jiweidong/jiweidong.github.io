---
title: 【JVM 性能】NUMA 架构与 JVM 调优深度解析：跨节点访存、UseNUMA 与容器绑定实战
date: 2026-11-05 08:00:00
tags:
  - Java
  - JVM
  - NUMA
  - 性能调优
  - Linux
categories:
  - JVM 深挖
author: 东哥
---

# 【JVM 性能】NUMA 架构与 JVM 调优深度解析

## 前言

一个很典型的线上怪象：两台机器，A 是 32 核 128G 单路，B 是 2×64 核 512G 双路。压测同一个 Spring Boot 服务，B 的 CPU 利用率上不去，P99 反而比 A 慢 30%，GC 次数还更多。

很多人第一反应是「GC 参数没调好」「线程池太小」，把 `-Xmx`、`-XX:ParallelGCThreads`、Tomcat 线程数全试了一遍，收益甚微。真实原因往往藏在 CPU 和内存的物理拓扑里——**这台机器是 NUMA 架构，而 JVM 默认并不知道这件事**。

这篇文章把 NUMA 的原理、JVM 在 NUMA 上的真实行为、四种落地方案、容器里的坑，以及面试会怎么问，一次讲清楚。

---

## 一、NUMA 到底是什么

### 1.1 从 SMP 到 NUMA

早期多核 server 是 SMP（Symmetric Multiprocessing）：所有 CPU 通过一条前端总线访问同一块内存，任意核访问任意内存地址的延迟都一样（UMA）。

核数一多，总线就成了瓶颈。于是有了 NUMA（Non-Uniform Memory Access）：内存被切分到多个 **Node**，每个 Node 绑定若干 CPU 核和一块本地内存控制器。

- CPU 访问**本地 Node** 的内存：走片上内存控制器，延迟约 70~90ns
- CPU 访问**远程 Node** 的内存：走 UPI/QPI/CCX 互联总线，延迟约 130~180ns，且带宽减半

双路机器 2 个 Node，4 路 4 个 Node。AMD EPYC 更细：一个 socket 内可能有 4 个 NUMA Node（NPS4 模式）。

### 1.2 用命令看清拓扑

```bash
# 查看 NUMA 节点、每节点的 CPU 与内存
numactl -H

# 输出示意
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 ... 31
node 0 size: 257000 MB
node 0 free: 189000 MB
node 1 cpus: 32 33 ... 63
node 1 size: 257000 MB
node 1 free: 201000 MB
node distances:
node   0   1
  0:  10  21      # 10 = 本地, 21 = 远程，约 2.1 倍延迟
  1:  21  10
```

`node distances` 里那个 `21` 就是问题的量化来源：**远程访存延迟是本地 2.1 倍**。

### 1.3 三个关键指标

```bash
# 全局 NUMA 命中率（最直观）
numastat -m

# 进程级别：看某个 JVM 的本地/远程分配比例
numastat -p $(pgrep -f 'java.*myapp')

# 单节点明细
cat /sys/devices/system/node/node0/numastat
```

`numastat -p` 输出里的 `local_node` / `other_node` 是重点。如果 `other_node` 占比超过 20%，说明这个 JVM 有大量跨节点访存——这就是「CPU 上不去、延迟下不来」的物理原因。

---

## 二、JVM 在 NUMA 上到底做了什么

这里是最容易踩坑的地方。很多人以为加了 `-XX:+UseNUMA` 就万事大吉，实际上：

**`-XX:+UseNUMA` 的分配器路径主要服务于 Parallel GC。** 它的做法是：为每个 NUMA 节点维护独立的年轻代空间，GC 线程尽量从本地节点分配对象，让对象落在「分配它的线程所在的那个节点」上。

而 G1 和 ZGC（截至 JDK 25）：

- G1 把堆切成等大的 Region，Region 与 NUMA 节点之间**没有绑定关系**
- 应用线程从全局 Region 列表里抢 Region 来分配，谁抢到算谁的
- ZGC 同理，它关注的是并发标记/转移的停顿，不是内存本地性

所以现实是：

| GC | 是否感知 NUMA | 说明 |
|---|---|---|
| Serial | 否 | 单线程，无意义 |
| Parallel | 是（需 `-XX:+UseNUMA`） | 按节点划分年轻代，本地分配 |
| G1 | 否 | Region 全局池化，跨节点访存随机发生 |
| ZGC | 否 | 以低停顿为目标，不做 NUMA 亲和 |
| Shenandoah | 否 | 同上 |

一个反直觉结论：**在某些大内存 NUMA 机器上，G1 的 P99 反而不如 Parallel + UseNUMA**，因为 Parallel 至少有内存亲和性，而 G1 的跨节点访问在 GC 复制存活对象时会被放大。

> 别急着改 GC。先量。如果你连 `other_node` 占比都不知道是多少，换什么 GC 都是猜。

---

## 三、四种落地方案（含对比）

### 方案 1：单大 JVM + 内存交织（interleave）

适用：读多写少、对象生命周期长、不想改架构。

```bash
# 所有内存分配在多个节点间轮转，牺牲峰值带宽换延迟均衡
numactl --interleave=all java -Xms32g -Xmx32g -jar app.jar
```

优点：配置一行，立竿见影降低 `other_node` 比例（趋近按节点均分）。
缺点：单次访存仍然有一半概率是远程，只是把「最坏情况」摊平了；对极致延迟不友好。

### 方案 2：多实例 + cpuset/cpuset-mems 硬绑定（推荐）

把一台大机器切成 N 个「逻辑小机」，每个 JVM 独占一个 NUMA 节点。

```bash
# 实例 A 绑到 node0 的 CPU 与内存
numactl --cpunodebind=0 --membind=0 java -Xms16g -Xmx16g -jar app.jar --server.port=8080
# 实例 B 绑到 node1
numactl --cpunodebind=1 --membind=1 java -Xms16g -Xmx16g -jar app.jar --server.port=8081
```

前面挂 Nginx 或 LVS 做负载。优点：访存 100% 本地，GC 线程也本地，吞吐和 P99 双赢；单实例故障域更小。
缺点：部署复杂度上升，需要容量规划（每个实例的内存要小于单节点可用内存，否则 `membind` 会 OOM 而不是回退）。

### 方案 3：Parallel GC + UseNUMA

```bash
java -XX:+UseParallelGC -XX:+UseNUMA -Xms32g -Xmx32g -XX:ParallelGCThreads=16 -jar app.jar
```

优点：不改部署形态，JVM 自己做本地分配。
缺点：Parallel 的停顿模型不如 G1 平滑；只对年轻代分配有效，老年代晋升后仍然可能跨节点。

### 方案 4：容器里用 cpuset + topology manager

K8s 里要真正拿到 NUMA 亲和，必须满足：

1. kubelet 开启 `--cpu-manager-policy=static` 和 `--topology-manager-policy=single-numa-node`
2. Pod 的 requests == limits，且是**整数核**（Guaranteed QoS）
3. 节点上装了 `numad` 或使用 `cpu-manager-policy=static` 的 `cpuset`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myapp
spec:
  containers:
    - name: app
      image: myapp:1.0
      resources:
        requests: { cpu: "8", memory: "32Gi" }
        limits:   { cpu: "8", memory: "32Gi" }
      env:
        - name: MALLOC_ARENA_MAX
          value: "4"
```

只有 Guaranteed + 整数核，kubelet 才会把 cpuset 分配成「同一 NUMA 节点内」的连续核。否则你的容器可能一半核在 node0、一半在 node1，JVM 却以为自己是 16 核单机——**这是云上最隐蔽的性能损耗来源**。

### 方案对比表

| 方案 | 改动成本 | 本地访存率 | P99 收益 | 适用场景 |
|---|---|---|---|---|
| interleave | 极低 | 50%（均衡） | 中 | 长生命周期大对象、批处理 |
| 多实例 + membind | 中 | ~100% | 高 | 在线服务、延迟敏感（首选） |
| Parallel + UseNUMA | 低 | 60~80% | 中 | 不方便改部署、吞吐型 |
| 容器 topology manager | 高 | ~100% | 高 | 云原生、Guaranteed 负载 |

---

## 四、一个真实排查案例

现象：64C/512G 双路机器，Spring Boot 服务 24 个 Tomcat 线程 + 32 个业务线程池，`-Xmx48g -XX:+UseG1GC`。压测 3000 QPS，CPU 只有 45%，P99 从 42ms 涨到 78ms。

排查步骤：

```bash
# 1. 确认拓扑
numactl -H          # 2 nodes, distance 21

# 2. 确认 JVM 的跨节点分配
numastat -p 12345
# 输出：
# Node 0: local_node 12.3 GB, other_node 18.9 GB
# Node 1: local_node  9.1 GB, other_node 14.2 GB
# => 跨节点访存占 61%

# 3. 确认 GC 是否频繁晋升大对象
jstat -gcutil 12345 1000 10
# YGC 频繁、老年代增长快 => 存活对象多，复制成本被跨节点放大

# 4. 用 perf 看远程访存
perf stat -e node-load-misses,node-loads -p 12345 -- sleep 10
```

方案：改成 3 个实例，每实例 `-Xmx14g`，分别 `numactl --cpunodebind=0/1 --membind`。结果 P99 回到 39ms，CPU 利用率升到 68%（说明单位时间做了更多有效工作），跨节点访存降到 3%。

**最关键的认知：CPU 利用率低不一定是「活不够多」，可能是「访存慢导致核在等内存」。**

---

## 五、面试追问与答题框架

**Q1：NUMA 是什么？和 SMP 的区别？**

按「拓扑 → 延迟差异 → 对程序的影响」三层回答：NUMA 把内存分到多个节点，本地访存快、远程访存慢（1.5~2.5 倍延迟、带宽减半），因此程序性能取决于「谁在哪儿分配、谁在哪儿访问」。

**Q2：JVM 支持 NUMA 吗？**

分层回答：`-XX:+UseNUMA` 存在但主要对 Parallel GC 的年轻代分配生效；G1/ZGC 不感知 NUMA；因此生产上更可靠的做法是 `numactl --membind` 多实例绑定，或用 K8s topology manager。

**Q3：怎么判断一个 Java 进程有没有跨节点访存问题？**

`numactl -H` 看拓扑和 distance → `numastat -p <pid>` 看 local/other 比例 → `perf stat -e node-load-misses` 量化 → 结合 `jstat` 看 GC 复制量。四步闭环。

**Q4：`--interleave=all` 和 `--membind` 有什么区别？哪个更好？**

interleave 是「轮流分配」，把远程访问摊平到所有节点，适合大对象/批处理；membind 是「只准在指定节点分配」，实现真本地化，适合延迟敏感的在线服务。前者是折中，后者是根治，代价是容量规划更严格。

**Q5：K8s 里怎么保证 Pod 拿到 NUMA 亲和？**

Guaranteed QoS（requests==limits）+ 整数 CPU + kubelet `cpu-manager-policy=static` + `topology-manager-policy=single-numa-node`。三个条件缺一不可，只设 limit 不设 request 是拿不到独占 cpuset 的。

---

## 六、踩坑清单

1. **把 `-XX:+UseNUMA` 加在 G1 上就以为优化了**：无用，甚至因为额外的启动检查造成困惑。
2. **`--membind` 配得比节点内存还大**：进程直接 OOM 被杀，不是「回退到远程」。`--preferred` 才是允许回退的柔性绑定。
3. **容器里 `nproc` 看到宿主机核数**：JVM 的 `ParallelGCThreads`、Netty worker 数、线程池 core 数全部按物理核算，导致线程数爆炸、上下文切换飙升。必须配 `-XX:ActiveProcessorCount` 或 `-XX:+UseContainerSupport`（JDK 10+ 默认开，但 cpuset 场景仍需校验）。
4. **透明大页（THP）与 NUMA 的叠加效应**：`always` 模式下 khugepaged 合并会造成瞬时延迟抖动，延迟敏感服务建议 `madvise`。
5. **只盯 GC 日志，不看 `numastat`**：GC 日志只告诉你「停了多久」，不告诉你「为什么慢」。

---

## 总结

NUMA 是「硬件拓扑决定软件性能」的典型案例。对 Java 工程师来说，记住三句话就够了：

1. **先量后调**：`numactl -H` + `numastat -p` 是排查的第一步，没有数据不要动参数。
2. **GC 不解决拓扑问题**：G1/ZGC 不感知 NUMA，靠改 GC 治不了跨节点访存。
3. **多实例绑定是生产最优解**：`--cpunodebind` + `--membind`，或者 K8s Guaranteed + topology manager。

下一篇会讲 **Native Memory 与 glibc malloc Arena**——那个「堆只有 4G，RSS 却涨到 12G」的经典问题，和 NUMA 一样，属于 JVM 参数管不到的地方。
