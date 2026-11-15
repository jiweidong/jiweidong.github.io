---
title: 【性能调优】ext4 与 XFS 文件系统深度解析：延迟分配、fsync 代价与 Java 持久化语义
date: 2026-11-15 08:30:00
tags:
  - Java
  - Linux
  - 文件系统
  - ext4
  - XFS
  - 性能调优
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】ext4 与 XFS 文件系统深度解析

## 前言

Java 里写「持久化」看起来只有两行：

```java
fileChannel.write(buf);
fileChannel.force(true);
```

但只要你在生产里认真对待过数据安全，就会撞上两个方向相反的问题：

- **方向一（丢数据）**：`force(true)` 明明调了，断电后最后几条记录还是没了；或者文件在，但目录项不见了，重启后文件「消失」。
- **方向二（慢）**：为了安全，每条记录都 `force()`，结果吞吐只有 800 条/秒；改成每 100 条刷一次，吞吐上去了，但断电丢 100 条。

这两个问题的答案都不在 Java 里，而在**文件系统层**：ext4 的延迟分配、journal 的三种模式、`fsync` 到底触发了什么、XFS 的 extent 与预分配、以及「元数据」和「数据」是两条独立的持久化路径。

> 说明：脏页回写的三个水位线（`dirty_ratio`、`dirty_background_ratio`、`dirty_expire_centisecs`）以及 `write/flush/force/close` 四层语义已经在《Linux Page Cache 与 Java 文件 IO》里讲过。本篇**只讲文件系统层**：块分配、journal、fsync 的物理代价、崩溃后的一致性边界。

## 一、先建立正确的分层模型

一次 `write()` 到数据真正落到介质，要穿过四层：

```
[1] JVM / JNI           write(fd, buf, n) 系统调用
[2] Page Cache          数据进内存页，标记 dirty（此时返回成功）
[3] 文件系统            ext4/XFS 决定块分配、写 journal、更新 inode
[4] 块层 / 设备         调度、合并、下发到 SSD/云盘，最终 FLUSH
```

关键认知：

- `write()` 返回成功 **只代表数据进了 page cache**；
- `fsync()` 才要求「数据 + 必要的元数据」都到达**持久介质**；
- 中间任何一层都可能把多个 `fsync` 合并（这是吞吐的来源，也是「你以为刷了其实没刷」的边界）。

## 二、ext4：延迟分配与 extent

### 2.1 延迟分配（delayed allocation）

ext4 默认开启 `delalloc`：`write()` 时**只分配 page cache 页，不分配磁盘块**。真正的块分配推迟到 writeback 时刻。

好处很实在：

- 连续的小写入在 writeback 时被合并成大 extent（减少碎片、减少元数据更新）；
- 短命文件（写完就删）根本不占磁盘块。

坏处更实在，而且很多人不知道：

| 现象 | 原因 |
|---|---|
| 磁盘满了但报错发生在 `close()` 或 writeback，不在 `write()` | 块分配被推迟，`write()` 时无块可分配这件事还不知道 |
| `EDQUOT`（超配额）延迟报出 | 同上 |
| 写入 10GB 后 `df` 只涨了 2GB | 还没 writeback |
| 进程被 kill 后文件内容是 0 字节 | 数据只在 page cache，没进文件系统 |

**Java 侧的直接影响**：如果你用「先写临时文件再 rename」的模式，`write()` 成功不代表文件有内容。断电后可能出现「文件存在但长度为 0」——这比「文件不存在」更危险，因为你的恢复逻辑可能会把它当成有效文件。

### 2.2 extent tree

ext4 用 extent（连续块区间）替代早期的「间接块」三级指针：

```
inode（i_block 60 字节）
  └─ 内联 extent：最多 4 个 extent（每个 12 字节）
       └─ 深度 ≥ 1：extent 索引树（每个节点一个 4KB 块，可存 340 个 extent 项）
```

这意味着：

- **碎片少的文件，元数据极少**，一次 inode 读取就能定位全部数据块；
- **碎片多的文件**（随机追加、并发写多文件）需要遍历 extent 树，`stat` 和读取都会变慢；
- 单文件最大 16TB（4KB 块）。对日志文件来说远远够。

一个实践推论：**追加写的日志文件是 ext4 的最优场景**（extent 只向后扩展），而「随机位置覆写」会让 extent 树膨胀。

### 2.3 journal 的三种模式：决定「数据」还是「元数据」有保障

这是 ext4 最重要的语义差异，`mount` 选项 `data=`：

| 模式 | 记录什么到 journal | 崩溃后一致性 | 性能 | 适用 |
|---|---|---|---|---|
| `data=journal` | 数据 + 元数据都先写 journal | 最强，数据不撕裂 | 最差（写两遍） | 极少数（数据库自己不做 WAL 时） |
| `data=ordered`（**默认**） | 只记元数据，但**保证数据先于元数据落盘** | 元数据一致，不会出现「元数据指向未写数据块」 | 好 | 绝大多数场景 |
| `data=writeback` | 只记元数据，数据顺序不保证 | 崩溃后可能读到旧数据/垃圾数据 | 最好 | 数据可重建（缓存类） |

`data=ordered` 的关键保证是：**你永远不会读到「文件长度已经变长，但内容是旧的/空的」这种状态**。这正是 Java 应用最需要的性质。

但注意，`ordered` **不保证**「`write()` 返回了就一定持久」。它只保证顺序，不保证时间。

## 三、XFS：AG、B+tree 与预分配

XFS 的结构和 ext4 差异很大，理解这三点就够了：

**1. Allocation Group（AG）**
文件系统被切成多个 AG（类似「分区里的分区」），每个 AG 有自己的空闲空间 B+tree、inode B+tree、日志。**多个 AG 意味着元数据操作可以并行**——这是 XFS 在大目录、高并发创建文件场景碾压 ext4 的根因。

**2. 全部用 B+tree**
ext4 用 extent 树 + 位图，XFS 用「按块号索引的空闲空间 B+tree」和「按 inode 号索引的 inode B+tree」。目录项也是 B+tree（ext4 是 htree，本质也是树，但 XFS 更彻底）。大目录下 `ls` 和 `create` 的复杂度都是 O(log n)。

**3. speculative preallocation（推测性预分配）**
XFS 对「正在增长的文件」会**预分配一段空闲空间**（默认最多 1GB，或文件大小的 2 倍），避免每次追加都要改 extent 树和空闲空间树。空闲 5 分钟后自动回收。

这个机制对 Java 应用的影响非常具体：

| 场景 | 影响 |
|---|---|
| 日志文件持续追加 | 吞吐明显好于 ext4（减少元数据事务） |
| 写很多小文件后立刻 `df` | 磁盘占用比实际数据大（预分配未回收） |
| 写小文件后立刻删除 | 空间要等定时回收，可能触发短暂 ENOSPC |
| 容器 rootfs 是 overlayfs + XFS 底层 | 空间统计容易误判（`du` 和 `df` 差很多） |

如果确实受影响，可以关掉：`mount -o allocsize=4k`（代价是元数据开销上升），或者对特定文件用 `fallocate` 精确控制。

## 四、`fsync` 到底做了什么，代价是多少

### 4.1 一次 `fsync` 的物理路径

```
fsync(fd)
 ├─ 1. 把该文件所有 dirty page 提交 writeback（可能要分配块）
 ├─ 2. 等待这些数据写到设备
 ├─ 3. 提交 journal 事务（ext4：commit record + 刷 journal）
 ├─ 4. 等待 journal 落盘（如果 journal 在独立设备则更快）
 ├─ 5. 更新 inode 的 mtime/size 等元数据（可能再触发一次 journal 提交）
 └─ 6. 下发 FLUSH/FUA 命令给设备，确保设备缓存也刷了
```

第 6 步经常被忽略：**SSD 和云盘都有易失写缓存**。`fsync` 必须发 `FLUSH CACHE` 命令让设备把缓存刷到闪存/远端。这一步的延迟在消费级 SSD 上可能是 0.1ms，在云盘上可能是 1~5ms，在带电池保护 RAID 卡上可以做「写缓存即持久」而降到 10μs 级。

### 4.2 代价量级表（决定你的组提交策略）

| 介质 | 单次 fsync 延迟 | 每秒 fsync 上限（单线程） |
|---|---|---|
| NVMe SSD（企业级，PLP） | 50~200μs | 5k~20k |
| SATA SSD（消费级） | 0.5~2ms | 500~2k |
| 云盘（ESSD PL1） | 0.5~1ms | 1k~2k |
| 云盘（普通 SSD 云盘） | 2~5ms | 200~500 |
| HDD（7200rpm） | 5~15ms | 70~200 |
| NFS / 网络存储 | 5~50ms | 20~200 |

**这张表解释了为什么「每条记录 fsync」的吞吐总是上不去**：不是 Java 慢，是物理定律。单条记录 fsync = 吞吐被设备 IOPS-for-fsync 限死。

### 4.3 组提交（group commit）：把 N 次 fsync 合并成 1 次

正确做法不是「少刷」，而是「**合并刷**」：

```java
/**
 * 组提交写入器：多个线程的写请求合并成一次 fsync。
 * 语义：commit() 返回时，该线程的数据一定已持久化。
 */
public class GroupCommitWriter implements Closeable {
    private final FileChannel channel;
    private final Object lock = new Object();
    private final ArrayDeque<WriteRequest> pending = new ArrayDeque<>();
    private Thread flusher;
    private volatile boolean running = true;

    private record WriteRequest(byte[] data, CompletableFuture<Void> done) {}

    public GroupCommitWriter(Path path) throws IOException {
        this.channel = FileChannel.open(path,
                StandardOpenOption.CREATE, StandardOpenOption.WRITE, StandardOpenOption.APPEND);
        this.flusher = Thread.ofPlatform().name("gc-flusher").daemon(true).start(this::loop);
    }

    public void append(byte[] record) {
        CompletableFuture<Void> f = new CompletableFuture<>();
        synchronized (lock) {
            pending.add(new WriteRequest(record, f));
            lock.notifyAll();
        }
        f.join();   // 调用方阻塞到「自己的数据已落盘」
    }

    private void loop() {
        while (running) {
            List<WriteRequest> batch;
            synchronized (lock) {
                while (pending.isEmpty() && running) {
                    try { lock.wait(); } catch (InterruptedException e) { return; }
                }
                batch = new ArrayList<>(pending);
                pending.clear();
            }
            try {
                // 1. 先全部 write（此时只进 page cache）
                for (WriteRequest r : batch) {
                    channel.write(ByteBuffer.wrap(r.data()));
                }
                // 2. 一次 force 覆盖整批
                channel.force(false);   // false: 不需要同步文件的元数据（mtime 等）
                batch.forEach(r -> r.done().complete(null));
            } catch (IOException e) {
                batch.forEach(r -> r.done().completeExceptionally(e));
            }
        }
    }

    @Override
    public void close() throws IOException {
        running = false;
        synchronized (lock) { lock.notifyAll(); }
        try { flusher.join(1000); } catch (InterruptedException ignored) {}
        channel.force(true);
        channel.close();
    }
}
```

要点：

- **`force(false)` vs `force(true)`**：`force(true)` 要求连元数据（长度、mtime）一起刷。Append 场景下文件长度变化本身就是元数据，所以严格来说**追加写需要 `force(true)`**，否则崩溃后可能长度没更新 → 尾部数据「看不见」。上面代码为了性能用了 `false`，生产上应改成 `true`，或者接受「长度可能滞后」并用记录内的长度/CRC 做前向扫描。这个细节 99% 的文章都写错了。
- 组提交的收益：N 个并发请求共享 1 次 fsync，吞吐 ≈ `N / fsync_latency`，直到 write 本身成为瓶颈。
- `f.join()` 会让调用线程阻塞——在虚拟线程里没问题（不占 carrier），在线程池里要控制并发数。

### 4.4 `fsync` vs `fdatasync`

| 系统调用 | 刷数据 | 刷元数据 | Java 对应 |
|---|---|---|---|
| `fsync` | 是 | 是（size/mtime 等） | `FileChannel.force(true)` |
| `fdatasync` | 是 | 只刷「读取数据所必需的」元数据（如 size） | `FileChannel.force(false)` |
| `sync_file_range` | 只提交 writeback，不等待 | 否 | 无 |

注意 `fdatasync` 在文件**变大**时仍然要刷 size 元数据，所以「追加写」时 `force(false)` 和 `force(true)` 差别不大；只有在「覆写已有区间」时 `false` 才明显更快。

## 五、原子替换：Java 里最容易写错的持久化模式

配置文件热更新、快照落盘，标准模式是「写临时文件 + rename」：

```java
public static void atomicWrite(Path target, byte[] content) throws IOException {
    Path tmp = target.resolveSibling(target.getFileName() + ".tmp");
    // 1. 写临时文件
    try (FileChannel ch = FileChannel.open(tmp,
            StandardOpenOption.CREATE, StandardOpenOption.WRITE,
            StandardOpenOption.TRUNCATE_EXISTING)) {
        ch.write(ByteBuffer.wrap(content));
        ch.force(true);            // 2. 数据落盘（否则 rename 后可能是空文件）
    }
    // 3. 原子替换
    Files.move(tmp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    // 4. 目录项落盘 —— Java 做不到
}
```

**第 4 步是 Java 的硬伤**：`rename` 修改的是**目录项**，目录项也是需要持久化的元数据。POSIX 要求对目录 `fsync` 一次，但 **Java 无法以读写方式打开目录**（`FileChannel.open(dir)` 抛 `FileSystemException: Is a directory`）。

后果：断电后可能出现「`tmp` 文件还在、`target` 还是旧内容」，也可能出现「两个都不见了」（极端情况）。`Files.move` 的 `ATOMIC_MOVE` 保证了**原子性**（不会出现半个文件），但**不保证持久性**。

三种应对：

1. 接受这个风险（大多数场景，概率极低）；
2. 用 JNI/JNA 调 `open(dir, O_RDONLY)` + `fsync`；
3. 在目录里放一个「代际文件」（`current.version` 记录版本号），启动时扫描目录并选最新有效版本 —— 用**冗余**换掉对目录 fsync 的依赖。

生产推荐第 3 种，纯 Java 可落地：

```java
// 每个快照带自增版本 + CRC，启动时选「版本最大且 CRC 正确」的那个
record Snapshot(long version, byte[] payload, int crc) {}

static Snapshot loadLatest(Path dir) throws IOException {
    try (var files = Files.list(dir)) {
        return files.filter(p -> p.getFileName().toString().startsWith("snap-"))
                .map(p -> {
                    try {
                        byte[] b = Files.readAllBytes(p);
                        long v = Long.parseLong(p.getFileName().toString().split("\\.")[1]);
                        return new Snapshot(v, b, crc32(b));
                    } catch (Exception e) { return null; }
                })
                .filter(Objects::nonNull)
                .filter(s -> s.crc() == storedCrc(s))     // 尾部自带 CRC
                .max(Comparator.comparingLong(Snapshot::version))
                .orElseThrow(() -> new IllegalStateException("no valid snapshot"));
    }
}
```

## 六、ext4 vs XFS：选型对照表

| 维度 | ext4 | XFS |
|---|---|---|
| 大目录（百万文件） | 一般（htree，`create` 会变慢） | 优秀（AG 并行 + B+tree） |
| 并发创建/删除小文件 | 一般（inode 表全局锁竞争） | 优秀（每 AG 独立） |
| 单文件顺序追加写 | 很好 | 很好（预分配更省元数据事务） |
| 删除大文件 | 慢（需遍历 extent） | 快（AG 结构） |
| 缩容 | 支持 | **不支持**（只能扩） |
| 元数据校验 | 有限（`metadata_csum`） | 强（`crc=1` 默认） |
| 典型适用 | 通用 rootfs / 小文件少 | 大数据 / 容器 / 大目录 / 大文件 |
| Java 应用最相关 | 日志文件够用 | 高并发写日志/临时文件更稳 |

**Java 服务的实操建议**：rootfs 用 ext4 无所谓，但**挂载给应用写日志/快照/上传文件的独立数据盘，优先 XFS**；反过来，如果盘要缩容或用 LVM 频繁调整，ext4 更灵活。

## 七、观测：怎么确认「慢在文件系统」

```bash
# 1. 看是不是 fsync 慢：iostat 的 f_await 是写完成的等待时间
iostat -x 1 /dev/nvme0n1
#   f_await > 5ms 且 w/s 不高 → fsync 密集
#   aqu-sz 高、%util 100% → 设备饱和

# 2. 看 page cache 里积压了多少脏页
grep -E "Dirty|Writeback|NFS" /proc/meminfo
#   Dirty 持续 > 1GB 且 Writeback 很小 → 回写跟不上

# 3. ext4 的块分配情况（延迟分配是否在合并）
cat /proc/fs/ext4/nvme0n1/mb_groups | head -5

# 4. XFS 的碎片与预分配
xfs_info /data
xfs_db -r -c "frag -f" /dev/nvme0n1   # 需卸载或只读

# 5. 直接测 fsync 延迟分布（不要用 fio 的默认配置）
fio --name=fsync --rw=write --bs=4k --size=64m --fsync=1 \
    --iodepth=1 --runtime=10 --lat_percentiles=1

# 6. 追一次慢 fsync 的内核栈
bpftrace -e 'kprobe:vfs_fsync { @s[tid] = nsecs; }
             kretprobe:vfs_fsync /@s[tid]/ { @lat = hist(nsecs - @s[tid]); delete(@s[tid]); }'
```

## 八、五个生产踩坑

1. **`write()` 成功就认为数据安全**。断电后文件在但内容为 0。必须 `force()`。
2. **`force(false)` 用在追加写场景**。文件长度元数据可能滞后，崩溃后尾部数据「不可见」。追加场景用 `force(true)`。
3. **`ATOMIC_MOVE` 当成「断电安全」**。它只保证原子，不保证持久；目录项可能没落盘。用「版本号 + CRC + 扫描最新」兜底。
4. **Kafka/RocksDB 类应用跑在 `data=writeback` 上**。以为库自己做了 WAL 就安全，但 WAL 文件本身的元数据顺序不被保证，恢复时可能读到损坏的尾部。要么用 `ordered`，要么确保库做了 CRC 校验（Kafka 有，多数自研 WAL 没有）。
5. **XFS 的预分配导致 ENOSPC 误判**。写大量小文件后 `df` 显示满，但 `du` 只有一半。要么等 5 分钟回收，要么 `allocsize=4k`，要么在代码里对 `ENOSPC` 做「清理 + 重试」而不是直接失败。

## 九、面试追问

**Q1：`fsync` 之后数据一定安全吗？**
不一定。`fsync` 保证文件数据 + 必要元数据到达**设备**，但设备缓存是否刷到介质取决于是否下发了 FLUSH/FUA，以及设备是否遵守。带易失写缓存的盘如果不支持 FLUSH 语义（或被 `-o barrier=0` 关掉），仍可能丢。真正的边界是「设备报告的持久化」。

**Q2：ext4 的 `data=ordered` 保证什么？**
保证数据块先于指向它的元数据落盘。因此崩溃后不会出现「元数据说文件有 10KB，但那 10KB 是垃圾」。它不保证 `write()` 返回即持久，也不保证多次写入的先后顺序在所有场景下成立。

**Q3：为什么 XFS 在大目录下比 ext4 快？**
XFS 用 AG 把元数据分散到多个独立的 B+tree，多个目录/文件的创建可以并行在不同 AG 上完成，锁竞争小；ext4 的 inode 分配和块位图在超大目录/高并发创建时更容易出现全局竞争。

**Q4：Java 能不能 fsync 一个目录？**
不能。`FileChannel.open()` 对目录抛异常。需要 JNI/JNA 调用 `open(O_RDONLY)` + `fsync`。纯 Java 方案是用「多版本文件 + 启动扫描」规避对目录项持久化的依赖。

## 总结

- 文件系统层解决的是「块怎么分配、元数据怎么记、崩溃后能不能对上」；page cache 层解决的是「什么时候写下去」。两者不是一回事。
- ext4 的关键词是**延迟分配 + extent + ordered journal**；XFS 的关键词是**AG 并行 + 全 B+tree + 推测性预分配**。
- `fsync` 的吞吐上限由介质决定（HDD 百级、云盘千级、企业 NVMe 万级），想要高吞吐只能**组提交**，不能靠「少刷」。
- Java 的持久化有两个先天缺口：不能 `fsync` 目录、`ATOMIC_MOVE` 不等于持久。解法是 CRC + 版本号 + 启动扫描。
- 观测的第一现场是 `iostat` 的 `f_await` 和 `/proc/meminfo` 的 `Dirty`，不是 JVM 的 GC 日志。

下次再有人问「为什么我的 WAL 每秒只能刷 800 次」，你可以先问一句：你的盘，单次 fsync 多少微秒？
