---
title: 【Java IO】RandomAccessFile 与 FileChannel 深度实战：随机读写、指针定位与大文件分片断点续传
date: 2026-10-06 08:20:00
tags:
  - Java
  - IO
  - 大文件
  - 断点续传
categories:
  - Java
  - Java 实战
author: 东哥
---

# 【Java IO】RandomAccessFile 与 FileChannel 深度实战：随机读写、指针定位与大文件分片断点续传

## 面试官：如何对一个 10GB 的文件做"从中间开始读"？

普通 `FileInputStream` 只会**顺序读**，你没法直接跳到第 5GB 的位置。要做随机访问，Java 给了两把钥匙：**`RandomAccessFile`** 和 **`FileChannel`**。

这两个类也是"断点续传""分片下载""日志文件尾部读取""数据库页文件"等场景的底层基础。这篇文章把它们讲透。

---

## 一、RandomAccessFile：带指针的文件流

`RandomAccessFile` 不属于 `InputStream`/`OutputStream` 体系，它同时支持读和写，核心是**文件指针（file pointer）**。

### 四种打开模式

| 模式 | 含义 | 说明 |
| --- | --- | --- |
| `"r"` | 只读 | 文件不存在抛 `FileNotFoundException` |
| `"rw"` | 读写 | 文件不存在则创建 |
| `"rws"` | 读写 + 同步内容与元数据 | 每次写都 `fsync`，**极慢** |
| `"rwd"` | 读写 + 同步内容 | 同步数据、不同步元数据，比 `rws` 快 |

> 生产里除非有强持久化要求，否则别用 `rws`/`rwd`，它们每一次写都落盘，性能会差一两个数量级。

### 基础操作

```java
try (RandomAccessFile raf = new RandomAccessFile("data.bin", "rw")) {
    long len = raf.length();                 // 文件长度
    raf.seek(1024);                          // 跳到第 1024 字节
    long pos = raf.getFilePointer();          // 当前指针位置

    raf.writeInt(2026);                       // 写 4 字节大端整数
    raf.writeLong(System.currentTimeMillis());

    raf.seek(1024);                           // 回到刚才的位置读
    int year = raf.readInt();
    long ts = raf.readLong();

    raf.setLength(4096);                      // 截断/扩展到指定长度
}
```

### 写"定长记录"的经典用法

`RandomAccessFile` 最擅长的场景是**定长记录文件**：每条记录固定 N 字节，第 i 条记录的偏移就是 `i * N`。

```java
static final int RECORD_SIZE = 4 + 20 + 8; // id + name(20 bytes) + score

// 写第 i 条
public void writeRecord(RandomAccessFile raf, int index, int id, String name, long score)
        throws IOException {
    raf.seek((long) index * RECORD_SIZE);
    raf.writeInt(id);
    byte[] nameBytes = new byte[20];
    byte[] src = name.getBytes(StandardCharsets.UTF_8);
    System.arraycopy(src, 0, nameBytes, 0, Math.min(src.length, 20));
    raf.write(nameBytes);                      // 定长 20 字节
    raf.writeLong(score);
}

// 读第 i 条，O(1)
public String[] readRecord(RandomAccessFile raf, int index) throws IOException {
    raf.seek((long) index * RECORD_SIZE);
    int id = raf.readInt();
    byte[] nameBytes = new byte[20];
    raf.readFully(nameBytes);                  // 保证读满
    long score = raf.readLong();
    String name = new String(nameBytes, StandardCharsets.UTF_8).trim();
    return new String[]{String.valueOf(id), name, String.valueOf(score)};
}
```

**要点：**
- `readFully(byte[])` 比 `read(byte[])` 靠谱——`read` 可能返回实际读到的字节数 < 数组长度，必须自己循环；`readFully` 读不满就抛 `EOFException`。
- 中文按 UTF-8 变长，写定长记录时要**手动补零**并用 `trim()` 或记录实际长度，否则会串位。

### 写入立即生效但可能未落盘

`raf.write()` 后数据进入 OS 页缓存，`close()` 时才保证可见（`rws/rwd` 除外）。需要强制落盘可用 `raf.getFD().sync()`。

---

## 二、FileChannel：更底层、更快的通道

`RandomAccessFile.getChannel()` 或 `FileInputStream/FileOutputStream.getChannel()` 都能拿到 `FileChannel`。它的优势：

1. **零拷贝**：`transferTo`/`transferFrom` 走内核，避免用户态内存拷贝；
2. **批量 + 内存映射**：`MappedByteBuffer` 把文件映射到内存；
3. **文件锁**：跨进程的 `FileLock`；
4. **显式 position**：`channel.position(long)` 等价于 `seek`。

### 显式定位读写

```java
try (FileChannel channel = FileChannel.open(
        Path.of("data.bin"),
        StandardOpenOption.READ, StandardOpenOption.WRITE,
        StandardOpenOption.CREATE)) {

    ByteBuffer buf = ByteBuffer.allocate(8);
    channel.position(1024);       // 定位
    int read = channel.read(buf); // 读取（可能 < 8，需循环）
    buf.flip();
    long value = buf.getLong();
}
```

> 注意：`channel.read()` 是**非阻塞语义的"能读多少读多少"**，和 `InputStream.read` 一样需要循环，别假设一次读满。

### 大文件分片读取（配合断点续传）

这是"10GB 文件从中间读"的正解：

```java
/**
 * 读取指定区间 [start, end]
 */
public byte[] readRange(Path file, long start, long length, int bufSize)
        throws IOException {
    try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ)) {
        channel.position(start);
        ByteBuffer buf = ByteBuffer.allocate(bufSize);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        long remaining = length;
        while (remaining > 0) {
            buf.clear();
            buf.limit((int) Math.min(buf.capacity(), remaining));
            int n = channel.read(buf);
            if (n == -1) break;
            buf.flip();
            out.write(buf.array(), 0, n);
            remaining -= n;
        }
        return out.toByteArray();
    }
}
```

### 零拷贝：transferTo 做文件复制

```java
try (FileChannel in = FileChannel.open(src, StandardOpenOption.READ);
     FileChannel out = FileChannel.open(dst,
             StandardOpenOption.WRITE, StandardOpenOption.CREATE)) {
    long pos = 0;
    long size = in.size();
    while (pos < size) {
        pos += in.transferTo(pos, size - pos, out); // 内核态直接搬运
    }
}
```

在小文件上差异不大，但在 GB 级复制上，`transferTo` 能显著降低 CPU 占用和拷贝次数。

### 文件锁 FileLock

多个进程（或同一 JVM 多个线程）同时写一个文件时，用文件锁互斥：

```java
try (FileChannel channel = FileChannel.open(Path.of("data.bin"),
        StandardOpenOption.WRITE)) {
    FileLock lock = channel.tryLock();  // 独占锁，拿不到返回 null
    if (lock == null) {
        System.out.println("文件已被其他进程占用");
        return;
    }
    try {
        // 安全写入
    } finally {
        lock.release();
    }
}
```

| 锁类型 | 获取方式 | 说明 |
| --- | --- | --- |
| 独占锁 | `lock()` / `tryLock()` | 其他进程不可读写 |
| 共享锁 | `lock(0, size, true)` | 允许多个读、禁止写 |

**坑**：`FileLock` 是**进程级**的，同一 JVM 内两个线程争同一文件的锁会抛 `OverlappingFileLockException`。JVM 内互斥请用 `synchronized`/`ReentrantLock`；`FileLock` 只解决跨进程。

### 内存映射 MappedByteBuffer

`FileChannel.map()` 返回 `MappedByteBuffer`，把文件（或一部分）映射进虚拟内存，读写像操作数组：

```java
try (FileChannel channel = FileChannel.open(Path.of("big.dat"),
        StandardOpenOption.READ)) {
    MappedByteBuffer mbb = channel.map(FileChannel.MapMode.READ_ONLY, 0, 1L << 30); // 1GB
    byte b = mbb.get(1024 * 1024 * 100); // 直接跳到 100MB 处读
}
```

适合**随机访问 + 读多写少**；缺点是占用虚拟内存、映射大小受地址空间限制、删除文件在 Windows 上会被占用。小文件不如普通流。

---

## 三、做一个断点续传下载器

把上面的能力组合起来，就是 HTTP `Range` + 本地随机写：

```java
public class ResumeDownloader {

    private final Path target;
    private final String url;

    public ResumeDownloader(String url, Path target) {
        this.url = url;
        this.target = target;
    }

    public void download() throws IOException {
        long existing = Files.exists(target) ? Files.size(target) : 0;
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestProperty("Range", "bytes=" + existing + "-"); // 从断点开始
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(10000);

        long total = parseContentLength(conn.getHeaderField("Content-Range"),
                conn.getContentLengthLong());

        try (InputStream in = conn.getInputStream();
             RandomAccessFile raf = new RandomAccessFile(target.toFile(), "rw")) {
            raf.seek(existing);              // 关键：定位到断点
            byte[] buf = new byte[64 * 1024];
            int n;
            long written = existing;
            while ((n = in.read(buf)) != -1) {
                raf.write(buf, 0, n);
                written += n;
                System.out.printf("进度 %.2f%%%n", written * 100.0 / total);
            }
            raf.getFD().sync();              // 落盘，保证断点可靠
        } finally {
            conn.disconnect();
        }
    }

    private long parseContentLength(String contentRange, long fallback) {
        if (contentRange == null) return fallback + existingBits();
        // Content-Range: bytes 100-999/1000
        String totalPart = contentRange.substring(contentRange.indexOf('/') + 1);
        return Long.parseLong(totalPart);
    }

    private long existingBits() { return 0L; }
}
```

**关键点：**
- 服务端必须支持 `Range`（返回 `206 Partial Content`），否则退化全量下载；
- 本地用 `RandomAccessFile.seek()` 定位到已下载位置，避免内存里拼接；
- 临时文件 + 最终改名（`Files.move(..., ATOMIC_MOVE)`），避免下到一半被当成完整文件；
- 记录分片进度到断点文件或 SQLite，重启后从断点续。

---

## 四、性能对比与选型

| 方式 | 随机读 | 顺序读 | 写入 | 内存占用 | 适用 |
| --- | --- | --- | --- | --- | --- |
| `FileInputStream` | ❌ | ✅ 快 | ❌ | 低 | 纯顺序读 |
| `BufferedInputStream` | ❌ | ✅ 更快 | ❌ | 低 | 顺序读优化 |
| `RandomAccessFile` | ✅ | 一般 | ✅ | 低 | 定长记录、断点续传 |
| `FileChannel` | ✅ | ✅ 快 | ✅ | 低 | 大文件、零拷贝、锁 |
| `MappedByteBuffer` | ✅ 极快 | ✅ 快 | ✅（需 flush） | 虚拟内存 | 随机访问、读多写少 |

### 一张选型口决

- **纯顺序读写** → `BufferedInputStream` / `BufferedOutputStream`；
- **要跳着读、要断点续传** → `RandomAccessFile` 或 `FileChannel`；
- **GB 级复制 / 传输** → `FileChannel.transferTo`；
- **随机访问且文件稳定** → `MappedByteBuffer`；
- **跨进程互斥** → `FileLock`。

---

## 五、面试追问连环炮

**Q1：`RandomAccessFile` 是线程安全的吗？**
不是。它内部有指针，多线程共享会互相干扰。要么每线程一个实例，要么加锁。`FileChannel` 本身线程安全（位置读写在参数中指定），但 `position()` + `read()` 的组合不是原子的。

**Q2：`read(byte[])` 和 `readFully(byte[])` 的区别？**
`read` 可能读到的字节数小于数组长度（网络/文件边界），必须循环；`readFully` 读不满直接抛异常，适合定长结构。

**Q3：`MappedByteBuffer` 什么时候真正落盘？**
写操作进入页缓存，由 OS 异步刷盘；调用 `force()` 可强制刷盘。GC 时机不可控，`Unmapper` 在 JDK 9+ 通过 `Unsafe` 释放映射。

**Q4：`transferTo` 为什么快？**
它让数据在**内核态**从页缓存直接送到目标 socket/文件，避免用户态缓冲区的一次拷贝，且可以走 DMA，CPU 参与度低。

**Q5：如何读取一个正在被写入的日志文件的新增内容？**
记录上次读取的 `offset`，用 `RandomAccessFile.seek(offset)` 循环读新增部分（类似 `tail -f`）；注意处理"最后一行可能只写了一半"的情况。

---

## 六、总结

1. **`RandomAccessFile` = 带指针的读写流**，靠 `seek()` 实现 O(1) 随机定位，定长记录文件是它的主场；
2. **`FileChannel` = 更底层的通道**，提供零拷贝、内存映射和文件锁；
3. **断点续传 = HTTP Range + `seek()` 定位 + 临时文件改名**，三件套缺一不可；
4. **文件锁解决跨进程，JVM 内互斥还得靠 `synchronized`**；
5. 选型看访问模式：顺序用缓冲流，随机用 RandomAccessFile/FileChannel，超大可上 mmap。

理解了文件指针和通道，你就真正掌握了 Java 文件 IO 的底层，而不是只会 `Files.readAllBytes`。
