---
title: 【性能调优】Linux Page Cache 与 Java 文件 IO 深度解析：脏页回写、fsync 语义与写放大
date: 2026-11-04 08:10:00
tags:
  - Java
  - Linux
  - 性能调优
  - IO
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】Linux Page Cache 与 Java 文件 IO 深度解析

## 前言

一个很典型的现象：Java 服务写日志/写文件，代码里 `fileChannel.write()` 返回成功、耗时 0.1ms，看起来磁盘快得离谱；但某天机器内存紧张，同一个写入突然变成 20ms，甚至出现大量 `kswapd` CPU 占用。

还有人问：`FileOutputStream.write()` 之后数据到底在哪？`flush()` 和 `fsync()` 有什么区别？为什么用 `BufferedOutputStream` 快 10 倍，但数据丢了？为什么 Kafka 号称"用页缓存所以快"，而 MySQL 却要自己管 buffer pool？

这些问题的答案都在同一层：**Linux Page Cache（页缓存）**。这篇从内核机制讲到 Java API 语义，把"写文件"这件事彻底拆开。

---

## 一、Page Cache 是什么：内核的"第二层内存"

### 1.1 一切皆页

Linux 用 4KB 的页（page）管理物理内存，Page Cache 就是**文件内容在内存中的副本**，以 `struct page` 组织，用 `address_space`（`inode->i_mapping`）做"文件偏移 → 页"的映射。

读写文件的两种路径：

```
读：
  用户 read() → 查 page cache
                ├─ 命中 → copy_to_user，返回（微秒级）
                └─ 未命中 → 发起块设备 IO → 填充 page → copy_to_user

写（普通 write，非 O_DIRECT）：
  用户 write() → 查/创建 page cache 页 → copy_from_user → 标记 dirty → 返回
                （真正的落盘由内核后台异步完成）
```

**这就是"写文件看起来很快"的原因：`write()` 只是把数据拷进内存并标脏，根本没有碰磁盘。**

### 1.2 脏页回写：pdflush 已被 writeback 取代

脏页由内核的 writeback 线程异步刷盘，触发条件有三类：

| 触发方式 | 参数 | 默认值 | 说明 |
|---|---|---|---|
| 时间 | `dirty_expire_centisecs` | 3000（30s） | 脏页存在超过该时间会被回写 |
| 后台阈值 | `dirty_background_ratio` | 10% | 脏页达此比例，后台开始刷（不阻塞） |
| 硬阈值 | `dirty_ratio` | 20% | 脏页达此比例，**写入进程被同步阻塞** |

```bash
$ sysctl vm.dirty_ratio vm.dirty_background_ratio
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
```

**生产踩坑**：内存 64G 的机器，`dirty_ratio=20%` 意味着允许 12.8G 脏页堆积。当写入速率持续高于磁盘回写带宽时，脏页会一路涨到硬阈值，然后**所有写入线程同时被阻塞**，表现为"周期性卡顿 1~2 秒"（俗称 IO 毛刺）。

调优建议（数据库/消息队列机器尤其重要）：

```bash
# 用绝对字节数限制比百分比更可预测
sysctl -w vm.dirty_ratio=5
sysctl -w vm.dirty_background_ratio=2
# 或直接指定字节
sysctl -w vm.dirty_bytes=268435456          # 256MB 硬阈值
sysctl -w vm.dirty_background_bytes=67108864 # 64MB 后台阈值
```

`dirty_bytes` 和 `dirty_ratio` **互斥**，设置一个会清零另一个。

---

## 二、Java 的四层"写"：write / flush / fsync / close

这是面试高频题，也是最容易误解的地方。用一张表说清：

| 层次 | API | 数据去哪了 | 掉电会丢吗 |
|---|---|---|---|
| 1. JVM 缓冲区 | `BufferedOutputStream.write()` | 进程堆内存 byte[] | **会丢** |
| 2. 内核页缓存 | `FileOutputStream.write()` | Page Cache（脏页） | **会丢** |
| 3. 文件系统元数据+数据 | `FileChannel.force(true)` / `RandomAccessFile("rws")` | 磁盘（含 inode/size） | 不丢 |
| 4. 硬件缓存 | 需配合磁盘 write cache 策略 | 磁盘盘片/闪存 | `force` 未覆盖硬件缓存时可能丢 |

### 2.1 `flush()` 是假的

`BufferedOutputStream.flush()` **只是把 Java 堆里的字节推给内核**，它对"持久化"零保证：

```java
try (var out = new BufferedOutputStream(new FileOutputStream("data.bin"))) {
    out.write(payload);
    out.flush();        // ✅ 数据进入 Page Cache
    // 此刻 kill -9 或机器掉电 → 数据丢失
}
```

很多人把 `flush()` 当"落盘"，这是最危险的理解偏差。

### 2.2 `force()` 才是真落盘

```java
try (var channel = FileChannel.open(path, CREATE, WRITE)) {
    channel.write(buffer);
    channel.force(false);   // false: 只保证数据；true: 连元数据一起
}
```

`force(boolean metaData)`：
- `force(false)`：刷数据 + 必要的元数据（比如文件大小变化时的 inode 更新）
- `force(true)`：数据 + 全部元数据（mtime、权限等），等价于 `fsync()`

**代价**：一次 `fsync` 在 SSD 上是 0.1~1ms，在机械盘上是 5~15ms。逐条 `fsync` 会让吞吐掉到几百 TPS。这就是为什么 WAL 要"组提交"。

### 2.3 `close()` 不保证持久化

`close()` 会 flush Java 缓冲并关闭 fd，但**不会调用 fsync**。数据仍在 Page Cache 里，等内核异步回写。关掉 JVM 后立刻断电，数据依然会丢。

---

## 三、写放大：为什么"顺序写"也会慢

很多人以为"顺序写没有写放大"，这只对了一半。

### 3.1 Page Cache 层的写放大：整页写回

Page Cache 以 4KB 页为单位。如果你在文件里**随机改 1 字节**，内核必须把整页（4KB）回写 → **4096 倍写放大**。这是随机小写最致命的成本。

### 3.2 文件系统层的写放大：COW 与日志

- **ext4（data=ordered 默认）**：元数据走 journal，数据直接写。追加写基本无放大。
- **XFS**：B+树管理 extent，超大文件追加性能好。
- **Btrfs/ZFS**：COW 文件系统，**改一个块要重写整条路径**，随机写放大严重，不适合数据库。

### 3.3 SSD 层的写放大（WAF）

SSD 以 4KB~16KB 的 page 写，但以更大的 block（如 256KB~2MB）擦除。小随机写会造成"读-改-写"，WAF 可能到 3~10 倍。这就是为什么：

> **Kafka / MySQL redo log 都坚持顺序追加、大块写。**

数据库和消息队列的性能秘密，一半在算法，一半在"把随机写变成顺序写"。

---

## 四、O_DIRECT：绕开 Page Cache 的代价

Java 直到 JDK 9 的 `ExtendedOpenOption.DIRECT`（`com.sun.nio.file`）才勉强支持，且**依赖底层文件系统**：

```java
// JDK 内部 API，需 --add-exports
FileChannel ch = FileChannel.open(path,
    StandardOpenOption.WRITE,
    ExtendedOpenOption.DIRECT);   // O_DIRECT
```

必须配合**对齐**（偏移、长度、缓冲区地址都按 512B/4KB 对齐），否则 `EINVAL`。Java 里拿不到堆外对齐地址，实践中几乎不可用，多数团队改用 JNI/JNA 或直接换语言。

**为什么大家还是要 O_DIRECT？** 因为数据库不想被"双重缓存"坑：

```
MySQL buffer pool（自己管，16KB 页，有 LRU、有刷脏策略）
        ↕
Page Cache（内核管，4KB 页，双链表 LRU，不可控）
        ↕
磁盘
```

同一份数据在内存里存两遍，且内核的 LRU 完全不受数据库控制 —— 一次全表扫描会污染 Page Cache，把热数据挤出去。所以 InnoDB 用 `innodb_flush_method=O_DIRECT` 让写绕过 Page Cache（读仍可走）。

而 **Kafka 恰恰相反，它极其依赖 Page Cache**：

- 消息写入 Page Cache 即返回（依赖副本机制而非 fsync 保证可靠）
- 消费时如果消费者跟得上，**直接从 Page Cache 读，根本不碰磁盘**
- 配合 `sendfile` 零拷贝，Page Cache → socket buffer 全程不经过用户态

这就是"Kafka 单机几十万 QPS"的底层原因：**它把 Page Cache 当成了一级存储，而不是缓存。** 代价是：消费者落后太多时，读会穿透到磁盘，性能断崖式下降。

---

## 五、实战：一个高性能 Java 写文件模板

需求：写日志/导出文件，要求 ①顺序追加 ②崩溃后可恢复到最后一条完整记录 ③高吞吐。

```java
public class DurableLogWriter implements Closeable {
    private final FileChannel channel;
    private final ByteBuffer buf = ByteBuffer.allocateDirect(256 * 1024);
    private final CRC32C crc = new CRC32C();
    private long lastSyncNanos = System.nanoTime();
    private static final long SYNC_INTERVAL_NS = Duration.ofMillis(200).toNanos();

    public DurableLogWriter(Path path) throws IOException {
        this.channel = FileChannel.open(path,
            StandardOpenOption.CREATE, StandardOpenOption.WRITE,
            StandardOpenOption.APPEND);
    }

    /** 写入一条带长度前缀 + CRC 的记录 */
    public void append(byte[] payload) throws IOException {
        int need = 4 + 4 + payload.length;   // magic/len + crc + body
        if (buf.remaining() < need) {
            flushBuffer();                    // 缓冲满 → 刷到内核并组提交 fsync
        }
        buf.putInt(payload.length);
        crc.reset();
        crc.update(payload, 0, payload.length);
        buf.putInt((int) crc.getValue());
        buf.put(payload);

        // 组提交：不是每条都 fsync，而是按时间窗口批量
        if (System.nanoTime() - lastSyncNanos > SYNC_INTERVAL_NS) {
            flushBuffer();
        }
    }

    private void flushBuffer() throws IOException {
        buf.flip();
        while (buf.hasRemaining()) {
            channel.write(buf);              // 进入 Page Cache
        }
        buf.clear();
        channel.force(false);                // 刷盘（一次 force 覆盖多条记录）
        lastSyncNanos = System.nanoTime();
    }

    @Override
    public void close() throws IOException {
        flushBuffer();
        channel.close();
    }
}
```

### 关键设计点

1. **`allocateDirect` 而不是 `allocate`**：避免 `write()` 时的堆内 → 堆外拷贝（JNI 临界区），大块写差异明显。
2. **组提交**：把 N 条记录的 `fsync` 合并为一次。200ms 窗口下，吞吐能提升一到两个数量级，代价是最多丢 200ms 数据。这是**可靠性 vs 吞吐**的显式权衡，必须写进文档。
3. **长度前缀 + CRC**：崩溃后可以顺序扫描，遇到 CRC 不匹配就截断到最后一条完整记录。**没有这个结构，`fsync` 也救不了你**——因为可能写入一半。
4. **`force(false)` 而非 `force(true)`**：追加写场景元数据变化很少，`metaData=true` 会多一次 inode 写。

---

## 六、监控：Page Cache 的健康度看哪几个指标

```bash
# 1. 脏页与回写
$ grep -E "Dirty|Writeback" /proc/meminfo
Dirty:           1254328 kB
Writeback:            204 kB

# 2. 回写吞吐与阻塞
$ cat /proc/vmstat | grep -E "nr_dirty|nr_writeback|pgpgout"
nr_dirty 313582
nr_writeback 51
pgpgout 12839201

# 3. 是否发生因脏页超限的同步阻塞（关键！）
$ perf stat -e 'block:block_dirty_buffer' -a sleep 5
# 或看 iostat 的 await 是否有周期性尖刺
$ iostat -x 1
```

**判断 IO 毛刺根因的三步法**：

1. `Dirty` 持续接近 `dirty_bytes`/`dirty_ratio` → 回写能力不足，要么降写入量，要么换更快的盘，要么调小阈值让回写更平滑（**调小阈值不会提升总吞吐，但能消除毛刺**）。
2. `iostat` 的 `%util` 接近 100% 且 `await` 高 → 磁盘饱和。
3. `await` 周期性尖刺但 `%util` 不高 → 可能是 `dirty_ratio` 触发的同步阻塞，或 ext4 journal 提交（`commit=5` 默认 5 秒一次）。

Java 侧可以用 `procfs` 读取，做进健康检查：

```java
public record DirtyPages(long dirtyKb, long writebackKb) {}

public static DirtyPages read() throws IOException {
    long dirty = 0, wb = 0;
    for (String line : Files.readAllLines(Path.of("/proc/meminfo"))) {
        if (line.startsWith("Dirty:")) dirty = parseKb(line);
        else if (line.startsWith("Writeback:")) wb = parseKb(line);
    }
    return new DirtyPages(dirty, wb);
}
```

超过阈值就告警（例如 `Dirty > 512MB`），比等用户投诉卡顿要早得多。

---

## 七、五个高频误区

**误区 1：`BufferedOutputStream` 越大越快**
不一定。缓冲区大于 Page Cache 的单次回写批量后收益递减，且大缓冲会占用堆内存。8KB~64KB 是多数场景的甜点。真正的收益来自**减少 syscall 次数**，不是"缓冲越多越好"。

**误区 2：`mmap` 一定比 `read/write` 快**
`mmap` 省掉了 `copy_to_user`，但会带来**缺页中断（page fault）**和**无法处理大于物理内存的文件**（超过会触发换页，性能崩坏）。小文件随机读 `mmap` 有优势；大文件顺序读，`read()` + 大 buffer 往往更稳。

**误区 3：写完 `fsync` 就一定不丢数据**
如果磁盘/RAID 卡有 write cache 且未开启"write-through"，`fsync` 只保证数据到了设备缓存。掉电仍可能丢。**要真正持久，得关掉硬件缓存或使用带掉电保护的 RAID 卡/企业级 SSD。**

**误区 4：`O_DIRECT` 一定比 buffered 快**
`O_DIRECT` 绕过了内核预读和合并，**小 IO 下反而更慢**。数据库用它是因为"自己管缓存比内核管得好"，不是因为"绕过缓存更快"。

**误区 5：日志框架的 `immediateFlush=true` 会拖慢服务**
Logback 的 `immediateFlush` 默认 true，指的是 flush 到内核（不 fsync），成本是一次 syscall。真正的性能问题是**每条日志一次 syscall**，用 `AsyncAppender` 批量写更有效。**注意：`AsyncAppender` 在队列满时会丢日志（默认 `discardingThreshold` 行为），生产上要评估。**

---

## 八、面试常见追问

**Q1：`write()` 返回成功，数据一定落盘了吗？**
没有。只保证数据从用户态拷到了内核 Page Cache。落盘需要 `fsync`/`fdatasync`，或者等内核按 `dirty_expire_centisecs` 异步回写。

**Q2：`fdatasync` 和 `fsync` 差别？**
`fsync` 刷数据 + 全部元数据；`fdatasync` 只刷数据 + **影响读取所必需的元数据**（如文件大小），不刷 mtime/atime。日志追加场景用 `fdatasync` 更快，Java 没有直接暴露，只能通过 `force(false)` 近似。

**Q3：为什么 Kafka 不 fsync 也不丢消息？**
它靠**多副本**保证持久性，而不是单机 fsync。acks=all 时消息被写入所有 ISR 副本的 Page Cache 就算成功。单机掉电会丢 Page Cache 里的数据，但只要有一个副本活着，数据就不丢。这是"复制换持久性"的典型设计。

**Q4：Page Cache 会占满内存导致 OOM 吗？**
不会。Page Cache 是 `GFP_KERNEL` 可回收内存，内存紧张时内核会直接丢弃干净页（无需回写）。但**脏页不可立即丢弃**，必须先回写，所以脏页过多会导致分配内存的进程被阻塞甚至触发 OOM killer。容器环境更要注意：cgroup v1 的 `memory.limit_in_bytes` 会把 Page Cache 算进去，Java 堆 + Page Cache 超限就会 OOMKilled。

**Q5：容器里 Java 的 `maxDirectMemorySize` 和 Page Cache 有关系吗？**
没有直接关系。DirectByteBuffer 是堆外内存（`malloc` + `Unsafe.allocateMemory`），属于匿名内存，不是 Page Cache。但它同样被计入 cgroup memory，所以要留足余量：`容器 limit > heap + metaspace + direct + 线程栈 + 安全余量`。

---

## 九、小结

- `write()` 只进 Page Cache，`flush()` 只进内核，**`force()`/`fsync()` 才落盘**，`close()` 什么都不保证。
- 脏页三阈值（`dirty_expire_centisecs` / `dirty_background_ratio` / `dirty_ratio`）是 IO 毛刺的根因，用 `dirty_bytes` 更可控。
- 写放大有三层：页（4KB 整页回写）、文件系统（COW/journal）、SSD（块擦除）。**顺序大块写是通用解**。
- 数据库用 `O_DIRECT` 争夺缓存控制权，Kafka 把 Page Cache 当一级存储 —— 目标不同，取舍相反。
- 高性能写文件 = 堆外缓冲 + 组提交 + 长度前缀&CRC + 周期性 `force`。
- 监控 `Dirty` / `Writeback` / `await`，比等用户投诉早三步。

搞懂 Page Cache，很多"玄学性能问题"就不再玄学了：它只是内核在替你做缓存决策，而你可以选择接受、调参，或者绕开。
