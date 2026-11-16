---
title: 【性能调优】Linux 块层 blk-mq 与 IO 调度器深度解析：从 mq-deadline 到 Java 落盘延迟
date: 2026-11-16 08:20:00
tags:
  - Java
  - Linux
  - 性能调优
  - blk-mq
  - IO 调度
  - fsync
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】Linux 块层 blk-mq 与 IO 调度器深度解析

## 一、前言

Java 应用「写日志慢」「刷盘抖动」「数据库 fsync 延迟高」，很多人第一反应是换 SSD、加 IOPS。但一块 NVMe 在 `fio` 里能跑 50 万 IOPS，业务侧 `fsync` 的 P99 却是 80ms —— 差距往往不在硬件，而在**块层的排队方式**。

从 `FileChannel.force()` 返回到数据真正落到介质，中间要穿过：page cache → 文件系统 → 块层 blk-mq → 设备队列 → 控制器缓存 → 介质。blk-mq 是 Linux 4.x 之后的重写，把「每 CPU 一个软件队列 + 多硬件队列」变成了默认模型；IO 调度器（`none`/`mq-deadline`/`kyber`/`bfq`）则决定了请求怎么合并、排序、限流。

本文把这层拆开，讲清楚三件事：**请求怎么排队、调度器怎么选、Java 侧怎么量**。

<!-- more -->

## 二、IO 路径全景

```
write(2)
  └─ VFS → page cache（脏页）
       └─ writeback 内核线程 / fsync 主动回写
            └─ 文件系统：ext4/XFS 分配 extent、生成 bio
                 └─ 块层 blk-mq
                      ├─ 软件队列（per-CPU）
                      ├─ IO 调度器（合并/排序/限流）
                      └─ 硬件队列 hctx → 设备驱动
                           └─ NVMe 队列对 / SCSI 队列
                                └─ 设备缓存 → 介质
```

两个关键事实：

1. **普通 `write()` 不落盘**，只写 page cache，返回即成功。真正的 IO 发生在 writeback 或 `fsync`；
2. **`fsync` 也不是「一次 IO」**，它要等文件数据 + 元数据（extent、inode 时间、journal 提交）全部持久化，物理上是多次 IO + 一次 FLUSH 命令。

## 三、blk-mq 的队列模型

### 3.1 三代演进

| 代际 | 模型 | 问题 |
|---|---|---|
| 旧 block 层 | 全局 `request_queue` + 单锁 | 多核下锁竞争，NUMA 远程访问 |
| blk-mq（3.13+） | per-CPU 软件队列 + 多硬件队列 | 需要设备支持多队列 |
| blk-mq + io_uring（5.1+） | 用户态提交/完成环，绕过部分 syscall | 生态与权限限制 |

### 3.2 软件队列与硬件队列

- **软件队列（`ctx`）**：每个 CPU 一个，应用提交 bio 时先落到本地队列，避免跨核竞争；
- **硬件队列（`hctx`）**：与设备队列一一映射。NVMe 通常支持 64~128 个队列对，SATA 通常只有 1 个；
- **映射关系**：CPU → 软件队列 → 硬件队列。队列数不匹配时会出现多对一，成为瓶颈。

查看：

```bash
ls /sys/block/nvme0n1/mq/
# 0 1 2 ... 63        ← 64 个 hctx

cat /sys/block/nvme0n1/queue/nr_requests      # 每个 hctx 的请求数上限，默认 1023
cat /sys/block/nvme0n1/queue/scheduler        # [none] mq-deadline kyber bfq
cat /sys/block/nvme0n1/queue/nr_hw_queues
```

### 3.3 tag 与队列深度

blk-mq 用 **tag** 标识 in-flight 请求，tag 数量就是队列深度。NVMe 的队列深度可以到 1024，SATA 的 NCQ 只有 32。

队列深度决定了**能同时压给设备多少个请求**。按 Little 定律：

```
并发请求数 = 吞吐(IOPS) × 单请求延迟
```

一块 100μs 延迟、50 万 IOPS 的 NVMe，需要 50 个并发请求才能打满。如果应用是「一次 `fsync` 等一个」，并发度只有 1，IOPS 上限就是 1/100μs = 1 万。这就是「硬件很强、业务很慢」的数学原因。

## 四、四种 IO 调度器

### 4.1 对比

| 调度器 | 排序/合并 |  fairness | 延迟控制 | 适用 |
|---|---|---|---|---|
| `none` | 仅简单合并 | 无 | 无 | NVMe / 低延迟 SSD / 多队列设备 |
| `mq-deadline` | 按截止时间排序，读优先 | 弱 | 读 500ms、写 5s 截止 | SATA SSD、HDD、通用 |
| `kyber` | 按读/写/discard 三类限流 | 无 | 令牌桶控制延迟目标 | 低延迟 SSD、可预测负载 |
| `bfq` | 按 cgroup/进程公平排队 | 强 | 预算控制 | 桌面、SATA、混合负载 |

### 4.2 none

`none` 不是「什么都不做」，它仍做相邻请求合并（merge），只是不做重排。对 NVMe 来说，设备内部有完整的调度能力（多队列、内部并行），内核再排序反而增加延迟。

**判断标准**：设备是 NVMe 或多队列 SSD，且队列深度 > 32，用 `none`。数据库（MySQL/PostgreSQL）在这类盘上通常也建议 `none`。

### 4.3 mq-deadline

为每个请求设截止时间，读请求优先：

```bash
cat /sys/block/sda/queue/iosched/read_expire     # 500 (ms)
cat /sys/block/sda/queue/iosched/write_expire    # 5000
cat /sys/block/sda/queue/iosched/fifo_batch      # 16
cat /sys/block/sda/queue/iosched/writes_starved  # 2
```

参数含义：

- `fifo_batch`：每批处理多少个同方向请求再切换方向。调大提高吞吐、增加读延迟；调小相反；
- `writes_starved`：读请求可以「饿死」写请求多少轮。默认 2 表示读优先但不完全饿死写。

HDD 上必须用它，因为机械盘需要减少寻道；SATA SSD 上也可用，收益有限。

### 4.4 kyber

kyber 的思路很直接：给读、写、discard 三类请求各一个令牌桶，按目标延迟反推令牌数。

```bash
cat /sys/block/nvme0n1/queue/iosched/read_lat_nsec      # 2000000 (2ms)
cat /sys/block/nvme0n1/queue/iosched/write_lat_nsec     # 10000000 (10ms)
```

当某类请求的延迟超过目标，就暂停分发该类请求，把设备让给其他类。适合「读写混跑、要求读延迟可控」的场景。缺点是参数需要按设备实测调，默认值在高端 NVMe 上偏保守。

### 4.5 bfq

bfq 是唯一提供**进程/cgroup 级公平**的调度器。它会为每个队列维护预算（budget），按权重分配带宽。

适合：桌面环境（防止 `dd` 卡死桌面）、多租户但没用 cgroup io 控制的场景。不适合：高 IOPS 的数据库，因为它的排队与预算计算本身有 CPU 开销。

### 4.6 怎么选

```
NVMe / 多队列 SSD
├─ 数据库 / 低延迟       → none
├─ 混合读写、要延迟可控   → kyber
└─ 多租户、要公平         → bfq（或 none + cgroup io.max）

SATA SSD
├─ 通用                  → mq-deadline
└─ 桌面/公平              → bfq

HDD
└─ mq-deadline（唯一正确选择）
```

临时切换：

```bash
echo mq-deadline > /sys/block/sda/queue/scheduler
# 持久化用 udev 规则或 tuned profile
```

## 五、被误读的 iostat

### 5.1 %util 不是「磁盘使用率」

`iostat -x` 的 `%util` 计算方式是「设备有 IO 在途的时间占比」。对支持并行的 NVMe，同一时刻可以有几十个请求在途，`%util` 很容易显示 100%，但设备远未饱和。

**NVMe 上 `%util` 基本没有参考价值**，要看：

- `r/s`、`w/s`：实际 IOPS；
- `rMB/s`、`wMB/s`：带宽；
- `await`：平均延迟（含排队）；
- `aqu-sz`：平均队列长度；
- `rareq-sz`、`wareq-sz`：平均请求大小。

### 5.2 await 的构成

```
await = 队列等待时间 + 设备处理时间
```

`await` 高但 `%util` 低，说明请求在**排队**（队列深度不够、调度器限流、cgroup `io.max` 卡住）；`await` 高且 `%util` 高，才是设备真饱和。

### 5.3 用 bpftrace 看真实延迟分布

平均值会骗人，要看直方图：

```bash
bpftrace -e '
kprobe:blk_account_io_done {
  @us[tid] = hist((nsecs - @start[arg0]) / 1000);
}
kprobe:blk_account_io_start { @start[arg0] = nsecs; }
'
```

或者用 `biolatency`（bcc）：

```bash
biolatency -m 10      # 按毫秒桶输出直方图
```

典型双峰分布：左边 100μs 是缓存命中/正常 IO，右边 10ms+ 的小峰是**日志提交或 writeback 抖动**。只有直方图能看出这种结构。

## 六、WBT：写回限流

Linux 4.10 引入 Writeback Throttling（WBT），防止「脏页写太猛把读延迟拖死」。

```bash
cat /sys/block/nvme0n1/queue/wbt_lat_usec    # 默认 75000 (75ms)
```

原理：跟踪每个 in-flight 写请求的完成延迟，如果超过 `wbt_lat_usec`，就限制新的写请求进入。它不是限带宽，而是**限并发**。

对延迟敏感的读服务，可以把 `wbt_lat_usec` 调低（如 20000）；对纯写吞吐场景，可以调高或关闭（`0`）。

## 七、Java 侧的落盘延迟

### 7.1 fsync 的实际代价

```java
public final class FsyncLatencyProbe {

    private final Histogram histogram = new Histogram(
        new LogarithmicBucketBoundaries(1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000));

    public void appendAndSync(Path path, byte[] payload) throws IOException {
        try (FileChannel ch = FileChannel.open(path,
                StandardOpenOption.CREATE, StandardOpenOption.WRITE,
                StandardOpenOption.APPEND)) {
            long start = System.nanoTime();
            ch.write(ByteBuffer.wrap(payload));
            ch.force(false);            // false = 只刷数据，不刷元数据
            histogram.record((System.nanoTime() - start) / 1_000_000);
        }
    }
}
```

`force(false)` 与 `force(true)` 的区别：

| 调用 | 刷数据 | 刷元数据（文件大小/时间） | 适用 |
|---|---|---|---|
| `force(false)` | 是 | 否 | 固定大小文件、预分配、覆盖写 |
| `force(true)` | 是 | 是 | 追加写、需要持久化文件长度 |

**追加写场景必须 `force(true)`**。很多「重启后最后几条日志丢了」的 bug，就是因为用了 `force(false)`：数据块落了盘，但 inode 里的 `size` 还是旧值，重启后文件被截断。

### 7.2 组提交：用并发换 IOPS

单线程 `fsync` 的 IOPS 上限是 `1/延迟`。要打满设备，必须让多个写请求同时在途 —— 这就是组提交：

```java
public final class GroupCommitWriter implements AutoCloseable {

    private final FileChannel channel;
    private final BlockingQueue<CompletableFuture<Void>> pending =
            new LinkedBlockingQueue<>();
    private final Thread flusher;

    public GroupCommitWriter(Path path) throws IOException {
        this.channel = FileChannel.open(path,
                StandardOpenOption.CREATE, StandardOpenOption.WRITE,
                StandardOpenOption.APPEND);
        this.flusher = Thread.ofPlatform().name("group-commit").daemon().start(this::loop);
    }

    public CompletableFuture<Void> write(byte[] data) {
        CompletableFuture<Void> f = new CompletableFuture<>();
        try {
            channel.write(ByteBuffer.wrap(data));   // 先写 page cache
            pending.add(f);
        } catch (IOException e) {
            f.completeExceptionally(e);
        }
        return f;
    }

    private void loop() {
        List<CompletableFuture<Void>> batch = new ArrayList<>(256);
        while (!Thread.currentThread().isInterrupted()) {
            try {
                batch.add(pending.take());
                pending.drainTo(batch, 255);       // 攒一批
                channel.force(true);               // 一次 fsync 覆盖一批
                batch.forEach(f -> f.complete(null));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (IOException e) {
                batch.forEach(f -> f.completeExceptionally(e));
            } finally {
                batch.clear();
            }
        }
    }

    @Override
    public void close() throws IOException {
        flusher.interrupt();
        channel.force(true);
        channel.close();
    }
}
```

这就是 Kafka、RocketMQ、MySQL 组提交的简化版。收益：100 个并发写、单次 `fsync` 5ms，串行是 200 IOPS，组提交后接近 2 万 IOPS 等效吞吐。

### 7.3 Java 能不能用 O_DIRECT

Java 标准库**没有** `O_DIRECT` 开关。三条路：

1. **JNI/JNA 调 `open(2)`**，再用 `FileChannel` 包装 fd。要求 buffer 地址与长度按逻辑块大小（512/4096）对齐；
2. **Java 21+ FFM API**（`java.lang.foreign`）直接调 `open`/`pread`，用 `Arena.allocate(size, 4096)` 保证对齐；
3. **Netty 的 `IoUring`/native transport** 或第三方库（如 `jnr`）。

FFM 示例（片段）：

```java
try (Arena arena = Arena.ofConfined()) {
    MemorySegment buf = arena.allocate(4096, 4096);   // 4K 对齐
    int fd = (int) open.invokeExact(pathAddress, O_RDWR | O_DIRECT);
    long n = (long) pread.invokeExact(fd, buf, 4096, 0L);
}
```

坑：

- `DirectByteBuffer` 的地址由 JVM 分配，默认只保证 8 字节对齐，**不能直接用于 O_DIRECT**；
- O_DIRECT 绕过 page cache，读会变慢（没有预读），写小片段会放大 IO；
- 容器里 seccomp 可能拦 `openat` 的 `O_DIRECT` 标志（少见，但云上遇到过）。

结论：**除非你在写存储引擎，否则不要碰 O_DIRECT**。用「page cache + 组提交 + 合理预读」就够了。

### 7.4 观测 Java 写延迟

```java
// Micrometer + Prometheus，按操作类型分桶
Timer.builder("app.disk.fsync")
     .tag("file", "wal")
     .publishPercentileHistogram()
     .serviceLevelObjectives(Duration.ofMillis(1), Duration.ofMillis(5),
                             Duration.ofMillis(20), Duration.ofMillis(100))
     .register(registry)
     .record(() -> channel.force(true));
```

再配合节点侧的 `biolatency`，就能把「应用慢」定位到「排队慢」还是「介质慢」。

## 八、实战：一次 P99 抖动归因

现象：订单服务 P99 从 30ms 涨到 300ms，CPU 正常，GC 正常，磁盘 `%util` 60%。

排查过程：

1. `iostat -x 1` 看 `await` 从 0.5ms 涨到 40ms，`aqu-sz` 从 2 涨到 30 → 请求在排队；
2. `biolatency` 直方图出现 50ms 的峰 → 不是介质慢，是排队；
3. `cat /sys/block/nvme0n1/queue/scheduler` 显示 `bfq` → 有人按「桌面优化」教程改了调度器；
4. 切回 `none`，`await` 回到 0.8ms，P99 回到 35ms。

根因：bfq 的公平排队在高并发小 IO 下引入了额外调度延迟，而这块 NVMe 根本不需要内核排序。

教训：**调度器不是越「智能」越好**。多队列设备上，内核越少干预越好。

## 九、面试高频追问

**Q1：blk-mq 解决了什么问题？**
旧块层是全局单队列单锁，多核高并发下锁竞争严重、NUMA 远程访问多。blk-mq 改成 per-CPU 软件队列 + 多硬件队列，每个 CPU 本地提交，减少竞争，并能充分利用 NVMe 的多队列能力。

**Q2：NVMe 为什么推荐 `none`？**
NVMe 设备内部有多队列和并行调度能力，内核再做排序/合并会增加延迟。`none` 只做相邻合并，把调度权交给设备。

**Q3：`%util` 100% 说明磁盘满了吗？**
不一定。`%util` 只表示「有 IO 在途的时间占比」，支持并行的设备可以同时处理多个请求。要看 IOPS、带宽、`await`、`aqu-sz` 综合判断。

**Q4：`fsync` 为什么比 `write` 慢几个数量级？**
`write` 只写 page cache 就返回；`fsync` 要等数据块、文件元数据、日志提交全部持久化，中间可能涉及多次 IO 与一次设备 FLUSH，还要等设备缓存落盘。

**Q5：组提交为什么能提升吞吐？**
把多个等待持久化的请求合并成一次 `fsync`，用一次设备往返覆盖多个事务，把「延迟 × 并发」的乘积用起来，等效吞吐提升一个数量级。

**Q6：`force(false)` 什么时候安全？**
文件大小固定、已预分配、只覆盖已有区间时安全。追加写、需要持久化文件长度时必须 `force(true)`，否则崩溃后文件可能被截断。

## 十、小结

1. blk-mq 的核心是「per-CPU 软件队列 + 多硬件队列 + tag 队列深度」，理解它才能理解 IOPS 上限。
2. 调度器选型看设备：NVMe 用 `none`，SATA 用 `mq-deadline`，要公平用 `bfq`，要延迟可控用 `kyber`。
3. `%util` 在 NVMe 上会骗人，看 `await`、`aqu-sz` 和直方图。
4. WBT 用并发限流保护读延迟，参数是 `wbt_lat_usec`。
5. Java 侧提升落盘吞吐的正道是**组提交**，不是换更贵的盘。
6. 追加写场景 `force(true)` 不能省；O_DIRECT 除非写存储引擎，否则别碰。

块层是「应用」与「硬件」之间最容易被忽略的一层。把它搞明白，很多所谓的「磁盘性能问题」其实只是排队问题。
