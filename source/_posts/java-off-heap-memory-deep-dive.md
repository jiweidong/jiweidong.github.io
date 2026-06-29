---
title: Java 堆外内存（Off-Heap Memory）深度解析：DirectBuffer、Unsafe 与 Netty 零拷贝
date: 2026-06-29 08:30:00
tags:
  - Java
  - JVM
  - 内存管理
  - Netty
categories:
  - Java
  - JVM底层
author: 东哥
---

# Java 堆外内存（Off-Heap Memory）深度解析：DirectBuffer、Unsafe 与 Netty 零拷贝

## 面试官：堆外内存是什么？为什么需要堆外内存？

**堆外内存（Off-Heap Memory）是指 JVM 堆以外、直接由操作系统管理的内存区域。** 在 Java 中通过 `java.nio.DirectByteBuffer` 来分配，底层调用 `Unsafe.allocateMemory()` 并通过 JNI 调用 C 标准库的 `malloc()`。

```java
// 分配 1GB 堆外内存
ByteBuffer buffer = ByteBuffer.allocateDirect(1024 * 1024 * 1024);
```

不需要 `-Xmx` 配置这块内存。

### 堆内 vs 堆外对比

| 维度 | 堆内（Heap） | 堆外（Off-Heap） |
|------|-------------|-----------------|
| **内存位置** | JVM 堆区 | OS 原生内存 |
| **GC 影响** | 受 GC 管理，频繁 GC 有 Stop-The-World | 不受 GC 管理 |
| **IO 操作** | 需拷贝到 DirectBuffer 再 IO | 直接 IO，零拷贝 |
| **分配/释放** | JVM 自动管理 | 需手动释放，易泄漏 |
| **容量** | 受 -Xmx 限制 | 受物理内存限制 |
| **序列化** | 无需额外转换 | 需要序列化/反序列化 |
| **读写速度** | 受 GC 影响 | 稳定低延迟 |

## 为什么需要堆外内存？

### 1. 网络 IO 零拷贝

Java 进行 Socket IO 或 File IO 时，如果使用 HeapByteBuffer，数据流转是：

```
HeapByteBuffer → DirectBuffer（拷贝）→ Socket / File
```

而使用 DirectByteBuffer 可以直接：

```
DirectByteBuffer → Socket / File（零拷贝）
```

### 2. 减少 GC 压力

在**高频交易、缓存系统、大数据处理**场景下，如果使用堆内存存储大量短期对象，会给 GC 带来巨大压力。堆外内存不受 GC 管理，大幅降低 Full GC 频率。

### 3. 突破堆大小限制

有些场景需要分配远超 `-Xmx` 的内存（如 100GB 缓存），此时只能使用堆外内存或 MMAP 文件映射。

## DirectByteBuffer 源码深度解析

### 分配入口

```java
// java.nio.ByteBuffer
public static ByteBuffer allocateDirect(int capacity) {
    return new DirectByteBuffer(capacity);
}
```

### DirectByteBuffer 构造函数

```java
// java.nio.DirectByteBuffer
DirectByteBuffer(int cap) {
    super(-1, 0, cap, cap);
    boolean pa = VM.isDirectMemoryPageAligned();
    int ps = Bits.pageSize();
    long size = Math.max(1L, (long)cap + (pa ? ps : 0));
    // 检查是否超出 -XX:MaxDirectMemorySize 限制
    Bits.reserveMemory(size, cap);
    
    long base = 0;
    try {
        // 核心调用：Unsafe.allocateMemory()
        base = unsafe.allocateMemory(size);
    } catch (OutOfMemoryError x) {
        Bits.unreserveMemory(size, cap);
        throw x;
    }
    unsafe.setMemory(base, size, (byte) 0);
    if (pa && (base % ps != 0)) {
        // 地址对齐
        address = base + ps - (base & (ps - 1));
    } else {
        address = base;
    }
    // 注册 Cleaner，用于 GC 时回收堆外内存
    cleaner = Cleaner.create(this, new Deallocator(base, size, cap));
}
```

### 关键点

1. **`Unsafe.allocateMemory()`** 最终调用 `os::malloc()`（C 函数）
2. **Cleaner 机制**：DirectByteBuffer 对象本身在堆上（很小），当它被 GC 回收时，Cleaner 回调 `Deallocator` 释放底层堆外内存
3. **`-XX:MaxDirectMemorySize`** 控制最大堆外内存，默认等于 `-Xmx`

### 读写原理

```java
// DirectByteBuffer.get() / put()
public byte get(int i) {
    return unsafe.getByte(address + i); // 直接通过内存地址读取
}

public ByteBuffer put(int i, byte x) {
    unsafe.putByte(address + i, x);     // 直接通过内存地址写入
    return this;
}
```

通过 `address` 字段直接操作原生内存地址，跳过了堆内对象的访问屏障。

## Unsafe 的堆外内存操作

`sun.misc.Unsafe` 提供了最底层的堆外内存操作：

```java
// 获取 Unsafe 实例（反射方式）
Field f = Unsafe.class.getDeclaredField("theUnsafe");
f.setAccessible(true);
Unsafe unsafe = (Unsafe) f.get(null);

// 分配内存
long address = unsafe.allocateMemory(1024 * 1024);

// 写入（按各种类型）
unsafe.putByte(address, (byte) 1);
unsafe.putInt(address + 4, 100);
unsafe.putLong(address + 8, 1000L);

// 读取
byte b = unsafe.getByte(address);
int i = unsafe.getInt(address + 4);

// 拷贝内存
unsafe.copyMemory(srcAddr, dstAddr, size);

// 释放（必须！）
unsafe.freeMemory(address);
```

### setMemory / copyMemory 的性能优势

`Unsafe.setMemory()` 调用 C 语言级别的 `memset()`，`copyMemory()` 调用 `memcpy()`，都是用 **SIMD 指令优化**过的，批量操作性能远高于 Java for 循环。

| 操作 | 1KB | 1MB | 100MB |
|------|-----|-----|-------|
| Java byte[] 循环置零 | 0.3μs | 320μs | 32ms |
| Unsafe.setMemory() | 0.2μs | 78μs | 5ms |
| 加速比 | 1.5x | 4.1x | 6.4x |

## 堆外内存泄漏与排查

### 堆外内存泄漏的典型场景

1. **DirectByteBuffer 未被回收**：Cleaner 未被触发，堆外内存无法释放
2. **Unsafe.allocateMemory() 未配对 freeMemory()**：手动分配的堆外内存容易遗忘
3. **NIO 的 Channel 未关闭**：底层关联的 DirectBuffer 无法回收

### 排查工具

```bash
# 查看堆外内存使用量
# -XX:NativeMemoryTracking=detail 启用 NMT
jcmd <pid> VM.native_memory summary

# 输出示例
Native Memory Tracking:
- Total: reserved=5120MB, committed=2048MB
- Java Heap: reserved=2048MB, committed=1024MB
- Class: reserved=64MB, committed=32MB
- Thread: reserved=128MB, committed=128MB
- Code: reserved=16MB, committed=8MB
- GC: reserved=128MB, committed=128MB
- Compiler: reserved=8MB, committed=8MB
- Internal: reserved=16MB, committed=16MB
- Other: reserved=2712MB, committed=704MB  ← 堆外内存部分
```

```java
// 运行时监控 DirectBuffer 使用量
// 通过 JMX 或代码
ByteBuffer buffer = ByteBuffer.allocateDirect(1024);
sun.misc.SharedSecrets.getJavaNioAccess()
    .getDirectBufferPool().getMemoryUsed(); // JDK 8
```

**生产推荐**：开启 NMT，设置报警阈值，定期检查堆外内存增长速率。

## Netty 的堆外内存管理

Netty 自己实现了堆外内存池（`PooledByteBufAllocator`），避免频繁分配/释放：

### Netty 内存池架构

```
PooledByteBufAllocator
  ├── PoolArena[] (CPU核心数 * 2)
  │    ├── PoolSubpage[] (tiny / small，8KB以下)
  │    │    ├── tiny: 16B, 32B, 48B, ... 496B 
  │    │    └── small: 512B, 1KB, 2KB, 4KB
  │    └── PoolChunkList (8KB以上)
  │         ├── qInit (初始化)
  │         ├── q000 (使用率 0-25%)
  │         ├── q025 (使用率 25-50%)
  │         ├── q050 (使用率 50-75%)
  │         └── q075 (使用率 75-100%)
  └── PoolThreadCache (线程本地缓存)
```

### 为什么 Netty 要自己管内存？

```java
// 直接在堆外分配
ByteBuf buffer = PooledByteBufAllocator.DEFAULT
    .directBuffer(1024);

// 写入数据
buffer.writeBytes(data);

// 发送（零拷贝）
ctx.writeAndFlush(buffer);

// 释放（Netty 自动回收到池中）
buffer.release();
```

| 方案 | 分配吞吐 | GC影响 | 使用便利性 |
|------|---------|--------|-----------|
| DirectByteBuffer | 慢（200ns/次，JNI调用） | 无 | 差（需手动回收） |
| Netty Pooled | 极快（从线程缓存取，~20ns/次） | 极小 | 好（引用计数自动管理） |
| JDK Pooled | 一般 | 一般 | 一般（JDK 8+ 已有） |

## 零拷贝技术：从理论到实战

### 传统 IO 的四次拷贝

```
硬盘 → 内核缓冲区 → 用户缓冲区(JVM堆) → 内核Socket缓冲区 → 网卡
```

**四次上下文切换 + 两次 CPU 拷贝 + 两次 DMA 拷贝**

### 零拷贝两件套

1. **`FileChannel.transferTo()`**（`sendfile` 系统调用）

```java
FileChannel fileChannel = new FileInputStream("bigfile.dat").getChannel();
fileChannel.transferTo(0, fileChannel.size(), socketChannel);
```

```
硬盘 → 内核缓冲区 → Socket 缓冲区 → 网卡
        ↓               ↓
    DMA 拷贝        DMA 拷贝（或一次，取决于 OS 支持）
```
**两次拷贝（DMA），零 CPU 拷贝**

2. **`DirectByteBuffer` 直接写入 Channel**

```java
ByteBuffer buffer = ByteBuffer.allocateDirect(4096);
buffer.put(data);
buffer.flip();
SocketChannel channel = SocketChannel.open();
channel.write(buffer); // DirectBuffer → 内核缓冲区 → 网卡
```

## 面试追问合集

### Q1: -XX:MaxDirectMemorySize 设置多少合适？

> 默认等于 `-Xmx`，生产环境建议显式设置。计算公式：预留堆外 = 堆大小 × 0.5 ~ 1 倍。比如 8GB 堆 → 设置 `-XX:MaxDirectMemorySize=4g`。
> 
> 注意：这只是 DirectByteBuffer 的限制，`Unsafe.allocateMemory()` 不受这个限制。

### Q2: 堆外内存一定会引起 OOM 吗？怎么预防？

> 会。堆外内存泄漏是生产环境常见的 OOM 原因。预防手段：
> 1. 开启 `-XX:NativeMemoryTracking=summary`
> 2. 配合 `-XX:+ExitOnOutOfMemoryError` 自动重启
> 3. 使用 Netty 等有内存池的框架
> 4. 用 `pmap -x <pid>` 观察 RSS 增长

### Q3: Cleaner 机制有什么缺点？

> Cleaner 依赖 `ReferenceQueue` 后台线程（`Reference.Handler`），在 GC 时异步回调。如果 DirectByteBuffer 分配速度超过 Cleaner 释放速度，仍可能 OOM。
>
> JDK 9 引入了更加确定的释放机制，但归根结底还是要**主动释放**。

### Q4: Netty 的堆外内存池有什么 JDK 对应物？

> JDK 8u102+ 引入了 `sun.misc.Unsafe.allocateUninitializedArray()` 用于更快的数据结构分配。JDK 13+ 的 Vector API（JEP 338）也使用堆外内存。
>
> 但 Netty 的内存池在**碎片化控制、线程缓存效率、引用计数**方面仍然领先。

## 踩坑经验

### 内存姿态（footprint）翻倍陷阱

```java
// ❌ 错误
ByteBuffer.allocateDirect(500 * 1024 * 1024); // 500MB

// 实际占用 1GB！
// 原因：DirectByteBuffer 本身 + Cleaner + Memory mapping
```

### 频繁 allocateDirect / 不释放

```java
// ❌ 每次请求都分配堆外内存
void handleRequest(Request req) {
    ByteBuffer buf = ByteBuffer.allocateDirect(65536);
    // 处理... 用完不释放
}

// ✅ 用对象池或复用
ThreadLocal<ByteBuffer> bufferPool = ThreadLocal.withInitial(
    () -> ByteBuffer.allocateDirect(65536)
);
```

堆外内存是 Java 高性能编程的必修课，理解它才能写出低延迟、高吞吐的应用。面试时把 `DirectByteBuffer`、`Unsafe`、`Netty 内存池` 串起来讲，就是一份满分的答卷。
