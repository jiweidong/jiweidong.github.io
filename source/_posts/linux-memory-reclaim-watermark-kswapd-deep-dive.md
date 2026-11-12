---
title: 【性能调优】Linux 内存回收与水位线深度解析：kswapd、direct reclaim 与容器 OOM 归因
date: 2026-11-12 08:20:00
tags:
  - Linux
  - 内存管理
  - 性能调优
  - Java
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】Linux 内存回收与水位线深度解析：kswapd、direct reclaim 与容器 OOM 归因

## 前言

两个经典现场：

1. 机器 `free -m` 显示 available 还有 200MB，但 Java 服务的 TP99 突然从 30ms 飙到 800ms，日志里没有任何异常。
2. Pod 的 `memory.limit` 是 4Gi，`memory.current` 只有 3.2Gi，容器却被 OOMKilled 了。

两个现象都与"内存还够不够"的判断逻辑有关。Linux 判断内存压力的依据不是"剩余多少"，而是**相对于三条水位线（watermark）的位置**；容器的判断依据也不是 `memory.current`，而是**回收失败后的 charge 失败**。

本文讲清楚 zone 水位线、kswapd 与 direct reclaim 的触发链路、cgroup v2 的回收语义，最后给出 Java 服务的调优参数与归因清单。

---

## 一、三条水位线：zone 的"红黄绿"

每个 NUMA node 下的每个 zone（DMA/DMA32/Normal/Movable）都有三条水位线：

```
        high ──────────────────  kswapd 停止回收
          ↑
        low  ──────────────────  kswapd 被唤醒（异步回收开始）
          ↑
        min  ──────────────────  分配器直接进入 direct reclaim（同步回收）
          ↑
         0   ──────────────────  回收失败 → OOM Killer
```

- **高于 high**：内存充足，谁都不用干活。
- **low ~ high**：kswapd 后台线程回收，应用无感（但 CPU 有消耗）。
- **min ~ low**：分配路径上的应用线程必须自己回收（direct reclaim），**这就是延迟毛刺的来源**。
- **低于 min 且回收不出页**：触发 OOM Killer。

### 1.1 水位线怎么算

```bash
# 查看每个 zone 的实际水位（单位 pages，1 page = 4KB）
cat /proc/zoneinfo | egrep "Node|zone|min|low|high|managed|free"
```

`min` 的基准值来自 `vm.min_free_kbytes`，然后按 zone 的 `managed` 页数做平方根缩放：

```
watermark[min]_zone ≈ min_free_kbytes × sqrt(zone_managed_pages / total_managed_pages)
```

`low = min × 5/4`，`high = min × 3/2`。此外还有 `watermark_boost`（碎片化严重时临时抬高水位，加速回收）和 `watermark_scale_factor`（默认 10，即 0.1%，调大可让 kswapd 更早介入）。

```bash
sysctl vm.min_free_kbytes        # 默认通常 45MB~90MB
sysctl vm.watermark_scale_factor # 默认 10
cat /proc/sys/vm/watermark_boost_factor
```

> 大内存机器（256GB+）建议把 `min_free_kbytes` 提到 1GB 左右，否则 kswapd 介入太晚，应用频繁掉进 direct reclaim；太大会浪费可用内存。经验公式：`min_free_kbytes ≈ 0.4% × 物理内存`，上限 2GB。

---

## 二、回收链路：从慢路径到 OOM

### 2.1 分配快慢路径

```c
// 简化后的内核逻辑（mm/page_alloc.c）
page = get_page_from_freelist(order, alloc_flags);   // 快路径
if (!page) {
    page = __alloc_pages_slowpath(order, alloc_flags); // 慢路径
}
```

慢路径依次尝试：

1. **唤醒 kswapd** 并等待一小会儿（`wait_iff_congested`）；
2. **direct reclaim**：当前线程自己扫 LRU 回收；
3. **内存规整（compaction）**：解决高阶分配的外部碎片；
4. **OOM Killer**（仅在有 `__GFP_NOFAIL` 或无法回收时）。

关键：**direct reclaim 是在应用线程上下文里跑的**。它要持 `lru_lock` 扫链表、可能触发回写（`pageout` → 块层 IO），这段时间你的业务线程完全被卡住。Java 侧表现就是"没有 GC、没有锁竞争，但 P99 莫名其妙尖刺"。

### 2.2 kswapd 在回收什么

LRU 是双链表结构，每类（anon / file）各有一对 active/inactive：

```
inactive_file → active_file → (回收) 
inactive_anon → active_anon → (需要 swap 才能回收)
```

回收优先级：

1. **干净的文件页**（page cache，无需回写）——最便宜；
2. **脏文件页**（需要 writeback，可能阻塞）；
3. **匿名页**（需要 swap；容器无 swap 时基本回收不了）。

这就是为什么**没有 swap 的容器里，page cache 被扫光后就直接 OOM**：匿名页（堆内存）无法回收。

### 2.3 refault 与 workingset

内核会记录每个页被回收后多久又被读回来（refault distance）。如果"刚回收就被读回"，说明工作集比可用内存大，内核会给该页打上 `workingset` 标记并**把它直接放进 active 链表**，同时抬高水位。指标在：

```bash
grep -E "workingset_(refault|activate|restore)" /proc/vmstat
grep -E "pgscan|pgsteal|pgmajfault" /proc/vmstat
```

`workingset_refault` 持续增长 = 你的应用正在"抖动"（thrashing）：内存不够，回收有效数据，马上又缺页读回。

---

## 三、容器：cgroup v2 的回收语义

容器里有两套水位：**宿主机 zone 水位** 和 **cgroup 自己的 memory.high/max**。两者互相独立，这是"全局还有空闲内存但容器 OOM"的根源。

### 3.1 cgroup v2 关键文件

| 文件 | 语义 |
|---|---|
| `memory.current` | 当前 charge 的总量（anon + file + kernel） |
| `memory.min` | **硬保护**，任何情况下不回收 |
| `memory.low` | **软保护**，有压力时优先不回收 |
| `memory.high` | **限流阈值**，超过则 throttle 并强制回收，不杀进程 |
| `memory.max` | **硬限制**，回收失败则 OOM Kill |
| `memory.stat` | `anon` / `file` / `pgscan` / `pgsteal` / `workingset_refault` 等 |
| `memory.events` | `high` / `max` / `oom` / `oom_kill` 计数 |
| `memory.pressure` | PSI：`some avg10=...` `full avg10=...` |

### 3.2 为什么 current 没到 max 也会 OOM

三个常见原因：

1. **统计口径差异**：`memory.current` 包含 page cache，而 page cache 在容器内是"可回收"的。当 charge 失败时，内核会先尝试回收该 cgroup 的 page cache；如果剩余的全是匿名页（堆+堆外），且 `memory.max` 已到，就直接 OOM。
2. **瞬时峰值**：`memory.current` 是采样值，1 秒粒度根本抓不到 malloc 峰值。看 `memory.events:max` 计数，而不是 current。
3. **kmem 未计入你关注的指标**：socket buffer、dentry、`TCP` 内存、`kernel stack` 都算在 `memory.stat` 的 `kernel` 里，Java 应用的 NIO 直接内存 + 大量连接时，这部分可以到几百 MB。

```bash
# 容器内自查
cat /sys/fs/cgroup/memory.events
cat /sys/fs/cgroup/memory.stat | egrep "^(anon|file|kernel|slab|sock|pgscan|pgsteal|workingset_refault)"
cat /sys/fs/cgroup/memory.pressure
```

判读规则：

- `memory.events:high` 在涨 → 已经在被 throttle，延迟抖动来自这里；
- `pgscan` 涨而 `pgsteal` 不涨 → 扫了但回收不出来（全是匿名页），下一步就是 OOM；
- `workingset_refault` 涨 → 工作集 > 限额，扩容或减内存。

---

## 四、Java 侧：哪些内存算进 cgroup

| 区域 | 是否计入 `memory.current` | 说明 |
|---|---|---|
| Java 堆（`-Xmx`） | ✅ anon | 主要部分 |
| Metaspace / CodeCache | ✅ anon | 类多、JIT 多的应用可达 500MB+ |
| 直接内存（`-XX:MaxDirectMemorySize`） | ✅ anon | Netty、NIO、gRPC 常见 |
| 线程栈（`-Xss × 线程数`） | ✅ anon | 虚拟线程的 stack chunk 也是 |
| GC 结构（卡表、RSet、标记位图） | ✅ anon | G1/ZGC 可到堆的 5%~20% |
| mmap 文件（`MappedByteBuffer`） | ⚠️ file（可回收） | 被回收后再次访问会缺页 |
| page cache（日志、Lucene 段） | ⚠️ file（可回收） | 容器内存打满时最先被牺牲 |

经典估算公式：

```
容器 limit ≥ Xmx + MaxMetaspace + MaxDirectMemory + CodeCache
           + 线程数 × Xss + GC 额外开销(堆的 10%~20%) + 安全余量(256MB+)
```

`-XX:MaxRAMPercentage=75` 只约束**堆**，不约束上面其他项。K8s 里最常见的错误就是 `limit=2Gi` + `-Xmx1536m`，剩下 512MB 装不下 Metaspace + 直接内存 + GC 结构。

---

## 五、观测三件套

```bash
# 1) 全局：水位与回收压力
cat /proc/zoneinfo | egrep "Node|zone|min|low|high|free"
grep -E "pgscan_direct|pgsteal_direct|allocstall|compact_stall" /proc/vmstat
cat /proc/pressure/memory

# 2) 进程：谁在吃内存
grep -E "Rss|Pss|Anonymous|Private_Dirty" /proc/<pid>/smaps_rollup
jcmd <pid> VM.native_memory summary   # 需 -XX:NativeMemoryTracking=summary

# 3) 容器
cat /sys/fs/cgroup/memory.events /sys/fs/cgroup/memory.stat /sys/fs/cgroup/memory.pressure
```

`/proc/vmstat` 里最值钱的三个计数器：

- `allocstall_*`：进入 direct reclaim 的次数（**延迟毛刺的直接证据**）；
- `pgscan_direct` / `pgsteal_direct`：直接回收扫描/回收页数；
- `compact_stall`：因内存规整而停顿的次数（THP 场景常见）。

---

## 六、调优清单

| 参数 | 默认 | 建议 | 理由 |
|---|---|---|---|
| `vm.min_free_kbytes` | ~64MB | 0.4% × 物理内存，≤2GB | 让 kswapd 更早介入，避免 direct reclaim |
| `vm.watermark_scale_factor` | 10 | 50~150（大内存机器） | 扩大 low~high 缓冲带 |
| `vm.swappiness` | 60 | 有 swap：10~30；无 swap：无所谓 | 降低匿名页回收倾向 |
| `vm.dirty_ratio` / `dirty_background_ratio` | 20/10 | 5/2（大内存 + 高写入） | 避免一次性回写洪峰 |
| cgroup `memory.high` | max | max 的 85%~90% | 用限流代替杀进程，留出回收时间 |
| cgroup `memory.max` | — | 按上面的公式算 | 别只按 Xmx 设 |
| THP | `madvise` | `madvise` + Java 侧 `-XX:+UseTransparentHugePages` 慎用 | always 会导致 compaction 抖动 |

补充两点：

1. **优先用 `memory.high` 做软限流**。设成 `max` 的 90%，超了就 throttle + 回收，虽然会慢但不会重启；`memory.max` 才是杀手。
2. **多代 LRU（MGLRU，kernel 6.1+）** 显著改善了"扫了不该扫的页"的问题，容器场景建议开启（`CONFIG_LRU_GEN`，通过 `/sys/kernel/mm/lru_gen/enabled` 确认）。

---

## 七、swap、zram 与 zswap：要不要开

云主机默认关 swap，容器也几乎不给 swap。原因很直接：swap 会把"内存不足"变成"IO 抖动"，延迟从毫秒级变成几十毫秒级，对 Java 服务往往是更差的体验。但完全不 swap 有一个副作用：**匿名页永远无法回收**，page cache 被扫光后只能 OOM。

三种方案对比：

| 方案 | 原理 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| 磁盘 swap | 匿名页换出到块设备 | 能避免 OOM | IO 延迟高（尤其云盘） | 几乎不推荐给在线 Java 服务 |
| **zram** | 内存中压缩块设备做 swap | 无磁盘 IO，压缩比 2~3 倍 | 吃 CPU；本质仍是内存 | 内存型应用、边缘设备 |
| **zswap** | swap 前置压缩缓存（frontswap） | 保留磁盘 swap 能力 + 减少 IO | 需要配置 pool | 有 swap 的物理机 |

调优要点：

```bash
# zram 示例：4GB 内存机器，开 2GB zram
modprobe zram num_devices=1
echo 2G > /sys/block/zram0/disksize
mkswap /dev/zram0 && swapon -p 100 /dev/zram0
sysctl vm.swappiness=100      # 用 zram 时应该调高，鼓励换出到压缩内存
```

注意最后一行反直觉：**用 zram 时 `swappiness` 要调高（100），用磁盘 swap 时要调低（10）**。因为前者换出成本是 CPU 压缩（便宜），后者是磁盘 IO（昂贵）。很多人照搬"swappiness=10"的模板，结果 zram 形同虚设。

容器场景的现实建议：**别给容器 swap**，改用 `memory.high` 做软限流 + 精确的 limit 计算 + page cache 的容量规划。K8s 的 `memory.swap.max`（cgroup v2）默认 0，就是这个道理。

### 7.1 vmstat 快速判读表

| 字段 | 含义 | 异常信号 |
|---|---|---|
| `si` / `so` | swap in / out（KB/s） | 持续 >0 说明内存真的不够 |
| `free` | 完全空闲页 | 长期接近 0 是正常的（page cache 在干活） |
| `buff/cache` | 可回收缓存 | 高不是问题，低才要担心 |
| `bi` / `bo` | 块设备读写 | 伴随高 `wa` 说明回写/换出压力 |
| `wa` | IO 等待占 CPU 比例 | >10% 且无业务写入 → 怀疑回收/回写 |

一条经验：**看 `si/so` 判断"是否真的缺内存"，看 `allocstall` 判断"缺内存是否伤害了延迟"**。两者都涨，才是需要动手的信号；只有 page cache 涨，那是正常干活。

## 八、一次真实排障复盘

**现象**：Java 服务每 10 分钟出现一次 500ms~1.2s 的 P99 尖刺，GC 日志正常，CPU 不高。

**排查**：

```bash
$ grep allocstall /proc/vmstat
allocstall_normal 18342        # 持续增长
$ cat /proc/pressure/memory
some avg10=18.42 avg60=6.11 avg300=2.30 total=...
$ cat /sys/fs/cgroup/memory.events
low 0
high 412
max 0
oom 0
$ cat /sys/fs/cgroup/memory.stat | grep -E "pgscan|pgsteal|workingset_refault"
pgscan 128934512
pgsteal 4123312                # 回收效率极低
workingset_refault 88213       # 工作集反复失效
```

**结论**：容器 `memory.high` 设得太贴近实际用量（= max 的 98%），每次日志轮转 + 批量任务写入把 page cache 冲高，立刻触发 cgroup 级回收，而回收对象主要是 Lucene/日志的 page cache，业务线程读文件时又要缺页读回 → 抖动。

**处置**：`memory.high` 下调到 85%，`memory.max` 上调 20%，日志目录改用独立 emptyDir + 单独限额。尖刺消失。

---

## 九、面试追问

**Q1：`free` 的 available 和 free 有什么区别？**
`free` 是完全未使用的页；`available` 是"估算的可供新应用使用的内存"，包含可回收的 page cache 与大部分 slab，扣除了不可回收部分。判断内存是否够用要看 `available` 与水位线，不是 `free`。

**Q2：kswapd 和 direct reclaim 的区别？**
kswapd 是每 zone 一个内核线程，异步回收，应用无感；direct reclaim 发生在分配内存的应用线程上下文，同步阻塞，是延迟毛刺的直接原因。前者在 low 水位触发，后者在 min 水位触发。

**Q3：容器没有 swap，为什么 page cache 会被优先回收？**
因为匿名页没有 swap 就无法回收，内核只能扫 file LRU。扫完 page cache 后如果仍然 charge 失败，就 OOM。这解释了"容器里 page cache 命中率莫名下降"。

---

## 十、总结

- 内存是否够用，看的是**与 min/low/high 三条水位线的相对位置**，不是 `free`。
- 延迟毛刺的头号嫌疑是 **direct reclaim**，用 `/proc/vmstat` 的 `allocstall` 一锤定音。
- 容器的 OOM 不是"`memory.current` 到 `memory.max`"，而是"**charge 失败且回收不出页**"；用 `memory.events` + `memory.stat` 归因。
- Java 的限额公式：`limit ≥ 堆 + 元空间 + 直接内存 + CodeCache + 线程栈 + GC 结构 + 余量`。
- 调优优先级：`memory.high` 软限流 > 调水位线 > 调 swappiness > 扩内存。
