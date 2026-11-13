---
title: 【性能调优】cgroup v2 IO 控制深度解析：io.max、io.latency 与 Java 应用的磁盘争抢治理
date: 2026-11-13 08:00:00
tags:
  - Java
  - Linux
  - cgroup
  - 性能调优
  - 容器化
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】cgroup v2 IO 控制深度解析：io.max、io.latency 与 Java 应用的磁盘争抢治理

## 前言

一个很典型的线上现象：某个 Java 服务部署到 K8s 之后，CPU 用了 limit 的 40%，堆内存稳定，GC 也正常，但接口 P99 从 80ms 涨到 900ms。查 `iostat -x` 发现磁盘 `%util` 接近 100%，`aqu-sz` 排队深度飙到几十。最后一查，同节点上另一个服务的日志疯狂刷盘，把本地盘的 IOPS 吃干净了。

CPU 有 `cpu.max`，内存有 `memory.max`，**磁盘却没有天然的隔离**——这是很多团队容器化踩得最深的一个坑。cgroup v1 时代的 `blkio` 控制器只做「权重」，v2 把 IO 控制重做成 `io` 控制器，提供了 `io.max`（硬上限）、`io.latency`（延迟保障）、`io.weight`（权重）、`io.stat`（用量统计）、`io.pressure`（压力失速）五件套，但**默认一个都不生效**，而且有几个反直觉的语义陷阱。

这篇文章按「原理 → 参数语义 → Java 落地 → 排查手册 → 面试追问」的顺序，把 cgroup v2 IO 控制讲透。

## 一、先搞清楚：IO 路径上有哪几层

很多人以为限流就是「限制进程写磁盘的速度」。实际写入路径是这样的：

```
Java 应用 write()/FileChannel.write()
        │
        ├─ buffered write ──> page cache（脏页）──> kworker/flusher 回写 ──> block layer
        │
        └─ O_DIRECT ─────────────────────────────────────────────> block layer
                                                                     │
                                                            blk-mq 调度器（mq-deadline / bfq / none）
                                                                     │
                                                              cgroup io 控制器（blkcg）
                                                                     │
                                                                  物理设备
```

关键点：**cgroup 的 IO 限制作用在 block layer 的 bio 提交点**，而不是 `write()` 系统调用点。所以：

- `O_DIRECT` 写：同步经过 block layer，`io.max` 立即精确生效。
- buffered write：`write()` 只是拷贝进 page cache，立刻返回；真正的 IO 由内核回写线程发起。回写线程的 blkcg 归属在内核演进中反复调整过，**在很多内核版本上，脏页回写可以突破 `io.max`**。
- 这意味着：**把 `io.max` 当成「应用写入速率上限」是不可靠的**，它更像「设备层队列的配额」。

这也解释了最常见的困惑：「我明明设了 `io.max wbps=10M`，为什么 `iostat` 里这个设备还是跑到 400MB/s？」

## 二、io.max：硬上限，语义与陷阱

### 2.1 基本用法

```bash
# 找到磁盘的 major:minor
$ lsblk -o NAME,MAJ:MIN,SIZE,TYPE,MOUNTPOINT
nvme0n1        259:0    500G disk
├─nvme0n1p1    259:1    500M part /boot
└─nvme0n1p2    259:2  499.5G part /

# 给某个容器 cgroup 设置上限（单位：字节/秒 或 IOPS）
$ echo "259:2 rbps=104857600 wbps=52428800 riops=2000 wiops=1000" \
    > /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/.../io.max

# 查看当前生效值与累计用量
$ cat /sys/fs/cgroup/.../io.max
259:2 rbps=104857600 wbps=52428800 riops=2000 wiops=1000
$ cat /sys/fs/cgroup/.../io.stat
259:2 rbytes=1876543210 wbytes=9876543210 rios=98213 wios=421233 dbytes=0 dios=0
```

`io.stat` 的六个字段要会读：

| 字段 | 含义 | 用途 |
|---|---|---|
| `rbytes/wbytes` | 实际下发的字节数 | 计费、容量核算 |
| `rios/wios` | 实际下发的 IO 次数 | 判断是否小 IO 密集 |
| `dbytes/dios` | 被丢弃（discard）的字节/次数 | fstrim、SSD 擦除 |
| `cost.*` | iocost 模型下的成本与权重 | 高级权重控制 |

### 2.2 四个反直觉的坑

**坑 1：buffered write 不可靠（前面已说）。** 要精确限速，业务侧用 `O_DIRECT` 或 `fdatasync` 自己做节流，别指望 `io.max`。

**坑 2：`io.max` 只对「叶子 cgroup」有效。** 给父 cgroup 设置，子 cgroup 不继承配额——这和 `cpu.max` 的继承行为不同，很多人在这里翻车。

**坑 3：设备号写错。** 容器里看到的 `/dev/sda` 在宿主机上可能是 `253:0`（device-mapper），也可能是 overlay 的上层设备。LVM、EBS、Ceph RBD 的 major:minor 各不相同。**必须用宿主机视角的设备号**，容器内 `lsblk` 看到的不一定对。

**坑 4：网络盘基本无效。** `io.max` 作用在块设备队列上，NFS/CephFS 这类文件系统级存储根本不走 blk-mq，配额写了等于没写。EBS gp3 虽然暴露成块设备，但底层带宽由云厂商的突发积分模型控制，`io.max` 只能限制「你发多少请求」，管不了「云盘给你多少 IOPS」。

## 三、io.latency：才是解决「邻居吵闹」的正解

`io.max` 是「我不许多用」，`io.latency` 是「我必须够快」。后者的思路是：给 cgroup 声明一个目标延迟（如 `target=10ms`），内核在检测到该 cgroup 的 IO 延迟超过目标时，**主动压制同设备上其他 cgroup 的 IO**。

```bash
# 声明：这个 cgroup 的 IO 延迟目标是 10ms，超出就压制别人
$ echo "259:2 target=10" > /sys/fs/cgroup/.../io.latency
```

语义细节：

- `target=10` 单位是**微秒级的毫秒值**，写 `10` 表示 10ms。
- 它是 **work-conserving** 的：没人抢的时候不限制你；有人抢的时候保你。
- 依赖内核对 blkcg 延迟统计的支持，实践中需要较新内核（5.0+），并且设备队列不能是 `none` 调度器（`mq-deadline` 下可用，`bfq` 下行为不同）。
- 官方标注为实验性特性，**必须用 `io.stat` 和业务 P99 双验证**，不能只看配置写成功。

这就是「保障型」与「限制型」的根本差别。生产里通常是组合拳：

| 场景 | 用哪个 | 理由 |
|---|---|---|
| 日志/备份/离线任务 | `io.max` | 明确不许抢占 |
| 在线核心服务 | `io.latency` | 保证 P99，不浪费空闲带宽 |
| 多租户混部 | `io.weight` + `io.max` | 平时按权重分，峰值有天花板 |

## 四、BFQ、mq-deadline 与「Java 应用最怕的写放大」

调度器决定 cgroup IO 控制能不能精细化：

```bash
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq
```

- `none`（NVMe 默认）：纯多队列直通，**没有调度就没有公平性**，cgroup 控制力最弱，但延迟最低。
- `mq-deadline`：保证请求不会饿死，读优先，适合数据库/日志混合负载，cgroup 控制可用。
- `bfq`：单队列时代的公平调度器，按 cgroup 做 BFQ 队列，公平性好但吞吐下降明显，**高并发 Java 服务不建议**。

Java 应用最怕的其实不是「带宽被抢」，而是**写放大**：

1. 日志框架同步刷盘（Logback `immediateFlush=true` + 每行 `fsync`）→ 小 IO 密集 → IOPS 先被打满，而不是带宽。
2. RocksDB / Kafka 的 `fsync` 与 page cache 回写叠加 → 一次业务写触发多次物理写。
3. JVM GC 日志、堆 dump、JFR 录制写到同一块盘 → STW 期间集中爆发。

所以治理顺序永远是：**先降写放大，再谈限流**。给一个日志服务设 `wiops=1000`，如果它每次 `logger.info` 都 `fsync`，那只是把它自己限死，问题没解决。

## 五、Java 侧怎么落地

### 5.1 一个必须认清的事实

JVM 的容器感知（`-XX:+UseContainerSupport`）只覆盖 **CPU 和内存**：

- CPU：`ActiveProcessorCount`、GC 线程数、`ForkJoinPool.commonPool` 并行度、Netty `EventLoopGroup` 线程数都受 `cpu.max` 影响。
- 内存：`MaxRAMPercentage` 读 `memory.max`。
- **IO：JVM 完全无感知**。`FileChannel` 不知道自己被限了 50MB/s，`KafkaProducer` 也不知道。

所以 IO 限流的后果必须由应用自己承担：**写入变慢 → 队列堆积 → 内存上涨 → GC 压力 → 更慢**。这条链路才是容器里 Java 服务雪崩的真实路径。

### 5.2 用 Micrometer 把 io.stat / io.pressure 接进监控

```java
@Component
public class CgroupIoMetrics {

    private final Path cgroupRoot = Path.of("/sys/fs/cgroup");

    @EventListener(ApplicationReadyEvent.class)
    public void bind(MeterRegistry registry) {
        Gauge.builder("cgroup.io.write_bytes", this, c -> c.readStat("wbytes"))
             .description("cgroup v2 io.stat wbytes")
             .register(registry);
        Gauge.builder("cgroup.io.write_ios", this, c -> c.readStat("wios"))
             .register(registry);
        // PSI：some = 至少一个任务被 IO 阻塞的时间占比
        Gauge.builder("cgroup.io.pressure_some", this,
                c -> c.readPressure("some"))
             .register(registry);
    }

    private double readStat(String key) {
        try {
            for (String line : Files.readAllLines(cgroupRoot.resolve("io.stat"))) {
                for (String kv : line.split(" ")) {
                    if (kv.startsWith(key + "=")) {
                        return Double.parseDouble(kv.substring(key.length() + 1));
                    }
                }
            }
        } catch (IOException ignored) { }
        return 0;
    }

    private double readPressure(String kind) {
        try {
            for (String line : Files.readAllLines(cgroupRoot.resolve("io.pressure"))) {
                if (line.startsWith(kind)) {
                    // some avg10=1.23 avg60=0.50 avg300=0.12 total=1234567
                    String avg10 = line.split(" ")[1];   // avg10=1.23
                    return Double.parseDouble(avg10.substring(6));
                }
            }
        } catch (IOException ignored) { }
        return 0;
    }
}
```

有了 `io.pressure` 的 `some avg10`，你就能回答一个关键问题：**「我的服务是不是在被 IO 拖累」**——`some` 高说明有任务在等 IO，`full` 高说明所有任务都在等（对单线程写盘的服务几乎等于全阻塞）。

### 5.3 应用层自适应限流：别让队列把内存吃光

既然 JVM 不知道被限速，就得自己做一个「写入预算」：

```java
public class DiskWriteBudget {

    private final RateLimiter limiter;          // 每秒字节预算
    private final Semaphore inflight;           // 未完成写请求上限

    public DiskWriteBudget(long bytesPerSec, int maxInflight) {
        this.limiter = RateLimiter.create(bytesPerSec);
        this.inflight = new Semaphore(maxInflight);
    }

    public void write(Path file, byte[] payload, boolean sync) throws IOException {
        limiter.acquire(payload.length);        // 阻塞式获取预算，天然背压
        if (!inflight.tryAcquire()) {
            throw new RejectedExecutionException("disk write queue full");
        }
        try (FileChannel ch = FileChannel.open(file,
                StandardOpenOption.CREATE, StandardOpenOption.WRITE,
                StandardOpenOption.APPEND)) {
            ch.write(ByteBuffer.wrap(payload));
            if (sync) ch.force(false);          // 只刷数据，不刷元数据
        } finally {
            inflight.release();
        }
    }
}
```

三条设计原则：

1. **预算要比 `io.max` 略小**（比如设为配额的 80%），留出内核回写与元数据的余量。
2. **必须有 inflight 上限**，否则限速只是把阻塞从磁盘搬到内存，最终还是 OOM。
3. **`force(false)` 而不是 `force(true)`**，避免每次写都刷元数据造成额外 IOPS。

### 5.4 Kafka / RocksDB 这类「自己管盘」的组件

- Kafka：`log.dirs` 单独挂盘，配 `io.max` 保护在线服务；`flush.messages` 不要设成 1（等于每消息 fsync）。
- Flink + RocksDB：`state.backend.rocksdb.localdir` 放本地 NVMe，同时用 `io.max` 限制 compaction 的写带宽，否则 checkpoint 期间 compaction 风暴会拖垮整个 TaskManager。
- ES：`index.translog.durability=async` 可以显著降低 fsync 次数，但会引入数据丢失窗口（这一点在另一篇 translog 文章里详谈）。

## 六、K8s 里的现实问题

1. **kubelet 没有 `io.max` 的 Pod spec 字段**。只能通过 `--feature-gates=...` 或者直接写 cgroup 文件（DaemonSet / initContainer），也可以用 `containerd` 的 `runtimeClass` 配合 annotation，或者干脆上 `cgroup v2 + systemd 的 IOAccounting`。
2. **必须确认节点是 cgroup v2**：`stat -fc %T /sys/fs/cgroup` 返回 `cgroup2fs` 才是。
3. **确认 IO 控制器已启用**：父 cgroup 的 `cgroup.subtree_control` 必须包含 `io`，否则子目录里根本没有 `io.max` 文件。
4. **`systemd` driver 下路径带转义**：`kubepods-burstable-pod1234_5678.slice`，别手拼。
5. **容器内看不到宿主机设备号**，需要在宿主机或特权 sidecar 里配置。

一个可用的验证脚本：

```bash
#!/bin/bash
set -e
CG=$1
DEV=$2   # 259:2
echo "cgroup2? $(stat -fc %T /sys/fs/cgroup)"
grep -q io /sys/fs/cgroup/cgroup.controllers && echo "io controller: ok"
[ -f "$CG/io.max" ] || { echo "io.max missing: subtree_control 未开 io"; exit 1; }
echo "$DEV wbps=52428800 wiops=1000" > "$CG/io.max"
cat "$CG/io.max"
# 压测 10s 后看实际是否被限
dd if=/dev/zero of=/tmp/iotest bs=1M count=2000 oflag=direct 2>&1 | tail -1
cat "$CG/io.stat"
```

## 七、排查手册：磁盘慢到底是「我慢」还是「别人吵」

按这个顺序走，基本 15 分钟内能定位：

```bash
# 1. 设备整体饱和度
iostat -x 1 5
#   %util 接近 100 + aqu-sz 高 → 设备层排队
#   r_await/w_await 高 → 单个 IO 慢（可能是网络盘/坏盘）

# 2. 谁在写
cat /sys/fs/cgroup/<cg>/io.stat     # 逐 cgroup 对比 wbytes/wios
pidstat -d 1 5                       # 进程级

# 3. 是不是小 IO 打满 IOPS 而不是带宽
#    wios 高但 wbytes/wios 很小（<16KB）→ 写放大/同步刷盘

# 4. 是不是脏页回写
grep -E "Dirty|Writeback" /proc/meminfo
vmstat 1 5    # bo 列

# 5. 压力归因
cat /sys/fs/cgroup/<cg>/io.pressure
```

决策树：

- `%util` 高 + 本 cgroup `wbytes` 也高 → **自己写太多** → 降写放大（批量、异步、压缩）。
- `%util` 高 + 本 cgroup `wbytes` 不高 → **邻居吵闹** → `io.latency` 保障自己，或迁盘。
- `%util` 不高但 `w_await` 高 → **单 IO 延迟问题** → 网络盘/云盘积分耗尽/坏盘。
- `wios` 高、`wbytes/wios` 极小 → **写放大** → 查 fsync、日志、RocksDB compaction。

## 八、面试常见追问

**Q1：cgroup v2 的 `io.max` 和 `io.weight` 有什么区别？**

`io.max` 是绝对上限（字节/秒、IOPS），超出直接排队；`io.weight` 是相对权重（1-10000），只在设备饱和时按比例分配，空闲时不限制。前者防「打爆」，后者做「公平」。

**Q2：为什么设了 `io.max` 还是把盘打满了？**

三个可能：① buffered write 的回写线程不受该 cgroup 配额约束（最常见）；② 设在了父 cgroup，子 cgroup 不继承；③ 设备号写错（LVM/overlay 的真实设备是 `dm-*`）。

**Q3：`io.latency` 能保证延迟吗？靠什么实现？**

它声明的是「目标延迟」，内核通过 blkcg 的延迟统计检测超标，然后压制同设备其他 cgroup 的队列深度。它是 work-conserving 的保障，不是硬实时保证；且依赖内核版本与调度器，属于实验性特性，必须用 `io.stat` 与业务指标双验证。

**Q4：Java 应用在容器里被限 IO 后，最先出问题的地方是哪？**

不是 `write()` 变慢本身，而是**调用方线程被阻塞**：Tomcat 工作线程卡在日志刷盘、Kafka producer 的 `BufferPool` 耗尽后 `send()` 阻塞、`ArrayBlockingQueue` 堆积导致堆上涨。表现是「CPU 不高、GC 频繁、线程池打满」，很容易误判成数据库慢。

**Q5：既然 JVM 不感知 IO 限流，框架层能做什么？**

三件事：① 所有写入路径给超时（`FileChannel` 没有超时，要用 `AsynchronousFileChannel` + `Future.get(timeout)`）；② 有界队列 + 明确的拒绝策略，避免无限堆积；③ 用虚拟线程跑阻塞写，把「线程被占用」的成本降到最低（但注意 pinning）。

## 九、总结

- cgroup v2 的 `io` 控制器提供 `io.max`（上限）、`io.latency`（保障）、`io.weight`（权重）、`io.stat`（观测）、`io.pressure`（归因）五件套，**默认全不生效，要手动开 `subtree_control`**。
- `io.max` 作用在 block layer，**buffered write 的回写可能突破配额**，精确限速要靠 `O_DIRECT` 或应用层预算。
- 治理顺序：**先降写放大，再限流，最后才是加机器**。
- Java 侧必须自己做背压（预算 + inflight 上限 + 超时），因为 JVM 只感知 CPU/内存，不感知 IO。
- 线上归因看三样：`iostat -x` 的 `%util/aqu-sz`、cgroup 的 `io.stat`、`io.pressure` 的 `some/full`。

磁盘隔离这件事，配好了是「静默生效的基础设施」，配不好就是「每次大促都复现的玄学抖动」。
