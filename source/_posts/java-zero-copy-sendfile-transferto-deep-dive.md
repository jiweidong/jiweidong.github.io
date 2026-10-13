---
title: 【Java 性能】零拷贝深度解析：sendfile、mmap 与 FileChannel.transferTo 在 Kafka/Netty 中的落地
date: 2026-10-13 08:00:00
tags:
  - Java
  - 零拷贝
  - NIO
  - 性能优化
  - Kafka
  - Netty
categories:
  - Java 深挖
author: 东哥
---

# 【Java 性能】零拷贝深度解析：sendfile、mmap 与 FileChannel.transferTo

## 前言

几乎所有高性能中间件的源码里，你都会看到一个反复出现的词：**零拷贝（Zero-Copy）**。Kafka 号称单机百万级吞吐、Netty 号称百万连接、RocketMQ 号称高吞吐，背后都离不开零拷贝。

但很多 Java 工程师对它的理解停留在「少了一次拷贝」这句正确的废话上。面试官追问一句就会露馅：

- 零拷贝到底省掉的是哪几次拷贝？CPU 拷贝还是 DMA 拷贝？
- `FileChannel.transferTo` 底层用的是 `sendfile` 还是别的？为什么它可能退化成普通读写？
- `mmap` 和 `sendfile` 都叫零拷贝，它们的区别是什么？各自适合什么场景？
- Kafka 的 `FileRecords`、`TransportLayer` 为什么不用 `transferTo` 全程？为什么还要有 `MappedByteBuffer`？

这篇文章从操作系统 I/O 路径讲起，把零拷贝的三种实现方式掰开揉碎，最后落到 Java 代码与中间件源码，并补充面试高频追问与生产踩坑。

---

## 一、先搞清楚：一次普通文件发送，数据到底搬了几次？

假设我们要把一个文件通过 Socket 发给客户端，最朴素的 Java 代码是：

```java
byte[] buf = new byte[8192];
int len;
while ((len = in.read(buf)) != -1) {
    out.write(buf, 0, len);
}
```

这背后，操作系统实际发生了 **4 次上下文切换 + 4 次数据拷贝**：

1. `read()`：用户态 → 内核态切换；DMA 把磁盘数据拷到**内核缓冲区（Page Cache）**；CPU 再把内核缓冲区拷到**用户缓冲区**。
2. `write()`：用户缓冲区数据 CPU 拷贝到**内核 Socket 缓冲区**；DMA 再把 Socket 缓冲区拷到**网卡**。

```
磁盘 --DMA--> 内核页缓存 --CPU--> 用户缓冲区 --CPU--> Socket 缓冲区 --DMA--> 网卡
               (拷贝1)            (拷贝2)            (拷贝3)           (拷贝4)
```

**问题在于拷贝 2 和拷贝 3 完全是多余的**：数据在用户态只是「路过」，应用并没有真正加工它。零拷贝要消除的，正是这两次 CPU 拷贝以及其中的上下文切换。

> 严格来说，零拷贝不是「零次拷贝」，而是**消除 CPU 参与的数据拷贝**，DMA 拷贝依然存在（那是硬件干的，不占用 CPU）。

---

## 二、四种零拷贝技术对比

| 技术 | 系统调用 | CPU 拷贝次数 | 上下文切换 | 能否修改数据 | 典型应用 |
|---|---|---|---|---|---|
| 传统 read/write | `read`+`write` | 2 | 4 | 能 | 小文件、需加工 |
| `mmap`+`write` | `mmap`+`write` | 1 | 4 | 能 | Kafka 索引、RocketMQ |
| `sendfile` | `sendfile` | 0（+1 若带用户缓冲） | 2 | 不能 | Kafka 日志段发送 |
| `splice` / `sendfile(DMA gather)` | `splice` | 0 | 2 | 不能 | Nginx、代理转发 |

关键结论：

- **`mmap`** 把内核页缓存直接映射到用户地址空间，**省掉了「内核→用户」这一次拷贝**，但用户态仍然要把数据 write 到 Socket，所以还有 1 次 CPU 拷贝。
- **`sendfile`（Linux 2.4+ 配合 DMA gather scatter）** 真正做到了数据不经过用户态：直接从页缓存进 Socket 缓冲区，网卡 DMA 直接 gather 页缓存。**0 次 CPU 拷贝、2 次上下文切换**（一次 `sendfile` 调用）。
- `sendfile` 的致命限制：**数据在传输过程中不能被修改**，因为你根本没有拿到用户态指针。

---

## 三、Java 里的零拷贝 API

Java NIO 提供了三个入口，注意它们**都不是纯 Java 实现，而是 JNI 调用系统调用**。

### 3.1 FileChannel.transferTo / transferFrom

```java
public class TransferToDemo {
    public static void sendFile(SocketChannel socketChannel, File file) throws IOException {
        try (FileChannel fileChannel = new FileInputStream(file).getChannel()) {
            long position = 0;
            long size = fileChannel.size();
            while (position < size) {
                // 返回本次实际传输的字节数，可能小于请求量
                long transferred = fileChannel.transferTo(position, size - position, socketChannel);
                if (transferred <= 0) {
                    break;
                }
                position += transferred;
            }
        }
    }
}
```

**三个必须知道的坑：**

1. **必须循环传输**。`transferTo` 单次能传多少取决于内核 `SO_SNDBUF`、网卡 gather 上限。JDK 文档明确写了「可能传输少于请求的字节数」。单次调用就返回是新手最常犯的错。
2. **可能退化为普通拷贝**。Linux 上 `transferTo` 会优先尝试 `sendfile`；如果目标不是 SocketChannel 或者内核不支持，会 fallback 到 `mmap` + `write`，甚至退化成用户态拷贝。也就是说，**它并不保证零拷贝**。
3. **文件 >2GB 的问题**。旧版本在高位偏移场景下有坑，虽然现代 JDK 已修复，但跨平台（尤其 Windows）行为不一致，生产上要注意。

### 3.2 MappedByteBuffer（mmap）

```java
public class MmapDemo {
    public static byte[] readHead(File file, int length) throws IOException {
        try (RandomAccessFile raf = new RandomAccessFile(file, "r");
             FileChannel channel = raf.getChannel()) {
            MappedByteBuffer buffer = channel.map(
                    FileChannel.MapMode.READ_ONLY, 0, length);
            byte[] data = new byte[length];
            buffer.get(data);
            return data;
        }
    }
}
```

`MappedByteBuffer` 底层就是 `mmap`。它的优势：

- 读大文件时避免了「内核→用户」拷贝；
- 支持随机访问，天然适合索引文件（Kafka 的 `.index`、`.timeindex` 就是 mmap）。

它的坑：

- **内存回收不受 GC 控制**。`MappedByteBuffer` 的释放依赖 `Cleaner`（虚引用 + `Unsafe.invokeCleaner`），只有在 GC 回收对应 DirectByteBuffer 对象时才 unmap。这也是为什么「删不掉的文件」在 Windows 上屡见不鲜。
- 想手动释放，得反射调用 `sun.misc.Unsafe#invokeCleaner`，或者换用 `FileChannel#unmap`（JDK 14+ 才有公开 API 的等价能力，实际上 `FileChannelImpl.unmap` 仍是内部方法）。JDK 22+ 可通过 `Arena`/FFM API 更干净地管理。
- `mmap` 会触发**缺页中断**，且无法利用 `madvise(MADV_SEQUENTIAL)` 之外的优化，随机访问大量小页时性能不一定比直接读好。

### 3.3 DirectByteBuffer + SocketChannel

```java
ByteBuffer direct = ByteBuffer.allocateDirect(64 * 1024);
// 读取后写入，数据在堆外，避免了一次「堆内→堆外」的拷贝
```

堆外内存在 Socket 写入时**天然是零拷贝的一部分**：因为内核需要的就是一块连续的本地内存，堆内数组必须先拷到堆外临时缓冲。这就是 Netty 大量使用 `ByteBuf.allocateDirect()` 的原因。

---

## 四、中间件源码里的零拷贝

### 4.1 Kafka：不止 sendfile

Kafka 的 `FileRecords.writeTo` 是零拷贝落地的经典：

```java
public long writeTo(GatheringByteChannel channel, long offset, int length) throws IOException {
    if (channel instanceof TransportLayer) {
        // 走 TransportLayer -> 最终 socketChannel.transferTo，即 sendfile
        return ((TransportLayer) channel).write(channelBuffer, offset, length);
    }
    // 退化为 mmap + 普通写
    ...
}
```

为什么 Kafka 不用全程 `transferTo`？

1. **消息格式转换（down-conversion）**：老版本 consumer 需要 v0/v1 消息格式，Broker 必须把数据读到用户态转换，此时零拷贝失效。
2. **SSL/TLS**：加密必须在用户态做，`transferTo` 无法加密，TLS 场景自动退化为普通写。**这是生产上「开了 TLS 吞吐掉一半」的根本原因之一**。
3. **多副本 + 分层索引**：`transferTo` 只能发连续文件区域，而 Kafka 一次请求可能要发多个 segment。

Kafka 的**旁路设计**也很值得学：索引文件用 `mmap`（随机访问、小块），日志数据文件用 `sendfile`（顺序大块）。**用对场景，而不是迷信一种技术。**

### 4.2 Netty：CompositeByteBuf 与 FileRegion

Netty 的零拷贝概念更宽泛，包含三类：

1. **用户态零拷贝**：`CompositeByteBuf` 把多个 `ByteBuf` 逻辑拼成一个，避免合并时拷贝；`slice()`/`duplicate()` 共享底层内存；`Unpooled.wrappedBuffer()`。
2. **内核态零拷贝**：`DefaultFileRegion` 封装 `FileChannel.transferTo`，做文件发送。
3. **堆外内存**：`PooledByteBufAllocator` + `PlatformDependent` 直接分配。

```java
// Netty 文件发送：底层即 sendfile
FileRegion region = new DefaultFileRegion(new FileInputStream(file).getChannel(), 0, file.length());
ctx.writeAndFlush(region);
```

**注意 Netty 的 `FileRegion` 与 `ChunkedWriteHandler` 二选一**：如果你在 pipeline 里加了 SSL handler，`FileRegion` 无法被加密，必须用 `ChunkedWriteHandler` + 用户态读，否则会直接报错或数据错乱。

### 4.3 RocketMQ / Nginx

- RocketMQ 用 `MappedByteBuffer` 做 CommitLog 的读写，配合 `mlock`（`TransientStorePool` 预映射 + 锁页）减少缺页中断。
- Nginx 的 `sendfile on;` 一行配置就是开零拷贝；配合 `tcp_nopush`/`tcp_nodelay` 做延迟与吞吐的取舍。

---

## 五、生产踩坑清单

1. **`transferTo` 不循环 → 大文件传输截断。** 一定要 `while` 到 `position == size`。
2. **开了 TLS 还指望零拷贝 → 性能不及预期。** 加密必须零拷贝之外的路径，提前做容量规划。
3. **`MappedByteBuffer` 文件删不掉 / 磁盘空间不释放。** 用 `Cleaner` 或进程退出，别在长生命周期对象里持有映射。
4. **`allocateDirect` 太多 → 堆外内存 OOM。** 堆外不受 `-Xmx` 限制，需要用 `-XX:MaxDirectMemorySize` 限制，并用 NMT 监控。
5. **mmap 大文件触发 OOM-Killer。** 页缓存计入进程 RSS，容器里映射几百 GB 文件很容易被 cgroup 干掉。
6. **`transferTo` 到阻塞的 SocketChannel 可能「卡住」**：它会等待、甚至返回 0 或抛中断，需要非阻塞 + 事件循环配合（Netty 正是这么做的）。

---

## 六、面试高频追问

**Q1：零拷贝是「零次拷贝」吗？**
不是。零拷贝指消除 CPU 参与的数据拷贝，DMA 拷贝依然存在。`sendfile` 在支持 DMA gather 的网卡上是 0 次 CPU 拷贝。

**Q2：mmap 和 sendfile 的区别？**
`mmap` 把页缓存映射进用户空间，用户可读可改，但有 1 次 CPU 拷贝（写到 Socket 时）；`sendfile` 完全不经过用户态，0 次 CPU 拷贝，但数据不可改。选型上：需要加工/随机访问用 mmap，纯转发用 sendfile。

**Q3：为什么 Kafka 消费慢的时候，Broker 的页缓存会涨？**
`sendfile` 把文件页缓存直接送给网卡前，会先驻留在 Page Cache。消费者跟不上时，Page Cache 会持续堆积，最终触发脏页回写与内存压力——这是典型的「零拷贝把内存压力转移到了内核」现象。

**Q4：Java 里怎么手动释放 MappedByteBuffer？**
依赖 `Cleaner`（基于虚引用 + `Unsafe.invokeCleaner`）在 GC 时释放；也可以反射调用 `sun.misc.Unsafe`，或 JDK 22+ 用 FFM `Arena`。生产更推荐「短生命周期 + 及时丢弃引用」的用法。

---

## 七、总结

| 场景 | 推荐方案 | 原因 |
|---|---|---|
| 静态文件/日志纯转发 | `sendfile`（`transferTo`） | 0 次 CPU 拷贝，2 次切换 |
| 需要读取加工再发送 | `mmap` + 普通写 | 可读可改，省一次拷贝 |
| 随机访问索引文件 | `MappedByteBuffer` | 无需 read 系统调用 |
| 高频小包网络发送 | 堆外 `DirectByteBuffer` + Netty pool | 避免堆内外拷贝与 GC |
| 加密/压缩后再发送 | 普通流式读写 | 零拷贝无法参与计算 |

零拷贝的本质是「**认清数据链路，把不必要的拷贝砍掉**」。理解它，你才能真正看懂 Kafka 的吞吐数字、Netty 的线程模型，以及为什么一开 TLS 性能就跳水。面试时把「4 次拷贝、4 次切换 → 0 次 CPU 拷贝、2 次切换」这条链路和 `transferTo` 的三个坑讲清楚，基本就能秒杀大部分候选人。
