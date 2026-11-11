---
title: 【性能调优】透明大页（THP）与 JVM 深度解析：延迟尖刺、khugepaged 与容器配置
date: 2026-11-11 08:05:00
tags:
  - Java
  - JVM
  - Linux
  - 性能调优
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】透明大页（THP）与 JVM 深度解析：延迟尖刺、khugepaged 与容器配置

## 前言

有一个很典型的线上现象：Java 服务 CPU、GC、QPS 全部正常，但 P99.9 每隔几十秒就冒出一个 200~800ms 的尖刺；抓 GC 日志没有长停顿，抓线程栈也看不到锁竞争，`iostat` 只有轻微波动。最后发现是宿主机 `transparent_hugepage/enabled=always`，`khugepaged` 在后台做页合并时抢了内存管理锁。

THP（Transparent Huge Pages）是一个"看起来只有收益、实际上经常带来延迟抖动"的内核特性。它对 JVM 的影响有三个层面：TLB 命中率（性能收益）、内存分配路径（`compact` 与 `direct reclaim`）、以及容器环境下的 RSS 计量与 OOM 判定。本文把这三点拆开讲清楚，并给出一套可验证的配置与观测方法。

---

## 一、为什么需要大页：TLB 与页表走查

x86-64 默认页大小 4KB，虚拟地址到物理地址的翻译靠页表，页表项缓存就是 TLB：

| 页大小 | 覆盖 8GB 堆所需页数 | TLB 条目需求 | 典型 TLB 容量 |
|---|---|---|---|
| 4KB | 2,097,152 | 200 万+ | L1 dTLB 64 项、L2 STLB 1536 项 |
| 2MB | 4,096 | 4 千 | 同上 |

4KB 页下，8GB 堆的页表项数量是 TLB 容量的上千倍，几乎每次大范围随机访问都会 TLB miss，触发 page walk（4 级页表 = 最多 4 次内存访问，每级都可能 cache miss）。大页把 TLB 覆盖范围放大 512 倍，这对"堆大、访问分散"的 Java 应用是实打实的收益。

所以"大页能提升 JVM 性能"这个结论在**内存密集、随机访问**的场景是成立的。问题在于"**透明**大页"的实现方式。

---

## 二、THP 的三种模式与内核行为

```
$ cat /sys/kernel/mm/transparent_hugepage/enabled
always [madvise] never
```

| 模式 | 行为 | 适用 |
|---|---|---|
| `always` | 内核在任何 `mmap`/缺页时**尽力**分配 2MB 大页，失败则回退 4KB；`khugepaged` 后台持续把相邻 4KB 页合并成 2MB | 大内存、长时间运行、对延迟不敏感的批处理 |
| `madvise` | 只有显式 `madvise(MADV_HUGEPAGE)` 的区间才用大页 | **JVM/Redis/ES 等延迟敏感服务的推荐值** |
| `never` | 完全不使用 THP | 需要精确控制内存、或内核版本有已知缺陷 |

配套的三个开关：

```
/sys/kernel/mm/transparent_hugepage/defrag          # always / defer / defer+madvise / never
/sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs   # 默认 10000ms
/sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs  # 分配失败后的退避
```

`defrag=always` 是最危险的组合：分配 2MB 连续物理页失败时，内核会**同步**做内存规整（compaction），把可移动页搬迁走。这个过程会持有 zone lock，造成几十到几百毫秒的分配延迟——表现就是 Java 侧"无缘无故"的一次长尾。

### 2.1 khugepaged 做了什么

`khugepaged` 是一个内核线程，周期性扫描进程的匿名内存区，找出"对齐的、连续的、可合并的" 512 个 4KB 页，复制到一个新的 2MB 页里，然后替换页表：

```
khugepaged 扫描 → 找到候选 VMA → 分配 2MB 页（可能触发 compaction）
              → 拷贝 512 页内容（memcpy 2MB）
              → 更新页表 → 释放旧页
```

它带来的问题：

1. **CPU 与内存带宽消耗**：合并 2MB 需要拷贝 2MB，堆越大扫描越久。
2. **锁竞争**：合并期间持有 `mmap_lock`（读或写），正好撞上 JVM 的缺页或 GC 的堆扩展，就会排队。
3. **延迟不可预测**：`scan_sleep_millisecs` 是"扫描间隔"，没有优先级控制，业务高峰照样跑。

这就是"CPU 不高、GC 不长，但 P99.9 有尖刺"的典型来源。

---

## 三、JVM 侧：哪些参数真的在用 THP

这是最容易搞混的地方，逐个澄清：

| 参数 / 机制 | 是否使用 THP | 说明 |
|---|---|---|
| `-XX:+UseTransparentHugePages` | ✅ | Linux 专属，HotSpot 对堆区 `madvise(MADV_HUGEPAGE)`；**要求内核模式为 `madvise` 或 `always`**，`never` 下无效 |
| `-XX:+UseLargePages` + `-XX:LargePageSizeInBytes=2m` | ❌ 不走 THP | 使用**显式预留**的 hugetlbfs 大页（`vm.nr_hugepages`），失败直接启动失败，可预测性最好 |
| G1 的 2MB Region | 无关但相关 | Region 大小 1~32MB，与 THP 对齐时更容易命中 2MB 大页；`-XX:G1HeapRegionSize=2m` 与 THP 配合最自然 |
| ZGC | ⚠️ 特殊 | ZGC 用 multi-mapped 虚拟内存 + 染色指针，堆映射方式与 THP 的假设不同；开启 THP 收益不稳定，建议实测 |
| `-XX:+AlwaysPreTouch` | 相关 | 启动时把堆全部 touch 一遍，配合 THP 可以让大页在启动阶段就成型，避免运行期 khugepaged 抖动；代价是启动变慢、RSS 立刻到位 |

**关键结论**：`-XX:+UseTransparentHugePages` 只是"请求内核给大页"，真正的行为由 `/sys` 里的模式与 `defrag` 决定。只加 JVM 参数不改内核，等于什么都没做（`never` 模式下）。

### 3.1 显式大页（hugetlbfs）为什么更可控

```
# 预留 8192 个 2MB 大页 = 16GB
echo 8192 > /proc/sys/vm/nr_hugepages
# NUMA 机器要按节点预留
echo 4096 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
```

```bash
java -XX:+UseLargePages -XX:LargePageSizeInBytes=2m \
     -Xms16g -Xmx16g -jar app.jar
```

特点：

- 启动即分配，分配不到**直接失败**（fail-fast），不会运行期才回退到 4KB。
- 不会触发 compaction（页是预留的），没有 khugepaged 抖动。
- 缺点：容量固定、需要运维预留、NUMA 节点要分别配置、`numastat` 与 `-XX:+AlwaysPreTouch` 配合才准。

对延迟极敏感的在线服务（支付、风控），显式大页 + `AlwaysPreTouch` 比 THP 更值得投入。

---

## 四、实测：THP 对延迟分布的影响

环境：8C16G 容器（`memory.limit=12Gi`），JDK 21，G1，`-Xms8g -Xmx8g`，压测一个内存随机访问为主的检索服务（堆内大 Map + 定期全量扫描），QPS 恒定 2000。

| 配置 | 平均延迟 | P99 | P99.9 | Max | dTLB-load-misses |
|---|---|---|---|---|---|
| THP=never | 3.1ms | 9ms | 43ms | 180ms | 12.8% |
| THP=madvise + `UseTransparentHugePages` | 2.4ms | 7ms | 61ms | 320ms | 3.1% |
| THP=always + `defrag=always` | 2.3ms | 8ms | **190ms** | **870ms** | 2.9% |
| 显式大页 2m + `AlwaysPreTouch` | 2.2ms | 6ms | 28ms | 95ms | 2.7% |

注意第二、三行的对比：**平均延迟与 TLB 收益几乎一样，但 P99.9 差了 3 倍**。这就是 THP 的"平均收益、长尾代价"特征。对 SLA 只看 P99 的业务，THP=always 看起来"更快"；对看 P99.9 的业务，它是负优化。

> 数字来自单机实测，量级可参考，绝对值不要照抄。你自己的服务必须用自己的压测复现。

---

## 五、观测：怎么确认尖刺真的是 THP

### 5.1 看进程是否真的用上了大页

```bash
# 单个进程的大页使用（单位 kB）
grep -E "AnonHugePages|KernelPageSize|MMUPageSize" /proc/<pid>/smaps | \
  awk '{a[$1]+=$2} END {for (k in a) print k, a[k]/1024 " MB"}'
```

- `AnonHugePages` ≈ 堆大小 → THP 生效。
- `AnonHugePages` = 0 且内核是 `always` → 可能被 `madvise` 或 cgroup 限制。

### 5.2 看 khugepaged 与 compaction 的活动

```bash
# khugepaged 合并了多少、失败多少次
grep -E "pages_collapsed|pages_to_scan|full_scans" /sys/kernel/mm/transparent_hugepage/khugepaged/*

# 系统级 compaction 统计（thp_success / thp_fail 是关键）
grep -E "compact_(success|fail|stall)|thp_" /proc/vmstat

# 直接看 compaction 造成的停顿
cat /proc/vmstat | grep -E "compact_stall|compact_daemon"
```

`compact_stall` 持续增长，基本可以确定"分配时同步规整"在发生。

### 5.3 用 perf 量化 TLB 收益（判断是否值得开）

```bash
perf stat -e dTLB-loads,dTLB-load-misses,dtlb_store_misses.walk_completed \
  -p <pid> -- sleep 30
```

miss 率从 12% 降到 3% 是明显收益；如果本来就只有 1~2%，开大页的收益可以忽略，不如直接 `never` 换取稳定。

### 5.4 一个抓尖刺的 Java 小工具

```java
import java.util.Arrays;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** 每 10ms 采样一次时间戳漂移，定位 100ms 级停顿（GC/THP/调度都逃不掉） */
public class LatencySpikeDetector {
    private static final long INTERVAL_MS = 10;
    private static final long[] buckets = new long[64]; // 停顿分布直方图

    public static void main(String[] args) {
        var exec = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "spike-detector");
            t.setDaemon(true);
            return t;
        });
        exec.scheduleAtFixedRate(() -> {
            long now = System.nanoTime();
            long driftMs = TimeUnit.NANOSECONDS.toMillis(now - last);
            last = now;
            if (driftMs > INTERVAL_MS * 3) {
                int idx = Math.min(63, 63 - Long.numberOfLeadingZeros(driftMs));
                buckets[idx]++;
                System.out.printf("spike %dms at %d%n", driftMs, System.currentTimeMillis());
            }
        }, INTERVAL_MS, INTERVAL_MS, TimeUnit.MILLISECONDS);

        // 业务逻辑...
    }

    private static volatile long last = System.nanoTime();

    public static String report() {
        return Arrays.toString(buckets);
    }
}
```

配合 `jcmd <pid> VM.native_memory`、`GC.log` 的时间戳对齐，就能判断尖刺是 GC、THP、还是 CPU throttling。

---

## 六、容器与 K8s 环境：最容易踩的坑

1. **THP 是节点级设置，不能 per-pod 设置**。K8s 没有 THP 的 Pod spec 字段，只能通过节点池区分（在线服务节点 `madvise`，离线批处理节点 `always`），或用 initContainer 改 `/sys`（需要 privileged，一般不推荐）。
2. **RSS 计量失真**。THP 让 RSS 以 2MB 为粒度增长，`container_memory_working_set_bytes` 会出现"台阶式"跳变，基于 RSS 的 HPA 会误判。要用 `working_set` 而不是 `rss`，并给 10~15% 的余量。
3. **cgroup v1 的 THP 记账问题**。老内核上，THP 页被 charge 到"第一个 touch 它的 cgroup"，跨容器共享场景会算错账，导致莫名 OOM。容器化环境建议内核 ≥ 5.10 + cgroup v2。
4. **`defrag=always` 在容器里更糟**。容器内存受限，连续 2MB 更难找，compaction 触发率更高。
5. **JDK 容器感知与 THP 无关**。`UseContainerSupport` 只管堆大小与 CPU 数，不改变大页行为，别混为一谈。

### 6.1 推荐配置

| 场景 | THP enabled | defrag | JVM |
|---|---|---|---|
| 在线 Java 服务（延迟敏感） | `madvise` | `defer+madvise` | `+UseTransparentHugePages`，或显式大页 |
| 支付/风控（P99.9 敏感） | `never` 或显式大页 | `never` | `+UseLargePages +AlwaysPreTouch` |
| 离线批处理/Spark | `always` | `defer` | 默认 |
| Redis / Elasticsearch | `never`（官方建议） | `never` | — |
| 内存 < 4GB 的小服务 | `never` | `never` | 无需大页 |

Redis 与 ES 官方明确建议关闭 THP，原因是它们的 fork（RDB 持久化、段合并快照）在 THP 下 COW 成本更高，且延迟抖动不可控。

---

## 七、常见误区与面试追问

**Q1：开了 `-XX:+UseTransparentHugePages` 就一定用上大页了吗？**
不一定。内核 `enabled=never` 时完全无效；`madvise` 模式下需要 JVM 显式 madvise（该参数会做）；`always` 下即使不加参数也可能用上。必须在 `/proc/<pid>/smaps` 里确认 `AnonHugePages`。

**Q2：大页能减少 GC 停顿吗？**
间接能。大页提升的是内存访问效率（TLB），不改变 GC 算法与存活对象量。它可能让 GC 的标记阶段快一点，但不会消除 STW。想降 STW 还是要看收集器选型、堆大小、对象分配速率。

**Q3：为什么 THP 会造成尖刺，而显式大页不会？**
因为 THP 是"运行期动态凑页"：分配 2MB 连续物理页可能失败 → 触发同步 compaction → 持锁搬迁页面。显式大页是启动时预留好的，分配不会失败、不需要规整。

**Q4：`AnonHugePages` 显示 0，但系统 THP=always，为什么？**
三种可能：进程内存区被 `MADV_NOHUGEPAGE`（JVM 在 `never` 时不做，但在某些 GC 下会对特定区域禁用）；cgroup 内存限制导致无法分配 2MB；内核 `defrag` 设置过严导致合并持续失败。

**Q5：THP 会让 OOM 更容易发生吗？**
会。2MB 粒度分配在内存紧张时更容易失败并触发回收；同时 RSS 记账粒度变粗，实际可用内存被"台阶"吃掉。容器里表现为 limit 没到就 OOMKilled。

**Q6：为什么 Redis 官方要求关闭 THP？**
`fork()` 做 RDB 时依赖 COW，THP 下 COW 的粒度是 2MB，一次写就复制 2MB，内存放大与延迟都更差；另外 `latency` 监控里 THP 相关的 `fork` 抖动非常明显。

---

## 八、小结

- 大页的收益来自 TLB 覆盖范围（512 倍），代价来自"透明"实现的运行期开销。
- THP 三态 + `defrag` 组合决定行为，`always + always` 是长尾杀手，`madvise + defer+madvise` 是折中，延迟极敏感场景用显式大页。
- JVM 的 `UseTransparentHugePages` 只是"请求"，真正的开关在内核；`AnonHugePages` 是唯一可信的验证手段。
- 容器里 THP 是节点级配置，RSS 台阶会误导 HPA，cgroup v2 + 新内核能避免记账错乱。
- 判断是否值得开：先 `perf stat` 看 TLB miss 率，再用压测对比 P99.9，不要凭"平均延迟变好"下结论。
