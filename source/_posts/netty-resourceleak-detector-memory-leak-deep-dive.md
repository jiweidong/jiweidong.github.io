---
title: 【Netty 实战】ResourceLeakDetector 与 ByteBuf 内存泄漏排查深度解析：采样原理、报告解读与生产治理
date: 2026-11-11 08:10:00
tags:
  - Java
  - Netty
  - 内存泄漏
  - 排障
categories:
  - Java 实战
author: 东哥
---

# 【Netty 实战】ResourceLeakDetector 与 ByteBuf 内存泄漏排查深度解析：采样原理、报告解读与生产治理

## 前言

Netty 应用最典型的内存事故不是堆 OOM，而是**堆外内存缓慢泄漏**：服务跑一周没事，第十天开始 `OutOfMemoryError: Direct buffer memory`，重启后恢复，周而复始。堆 dump 看不出来（对象在堆外），GC 日志干干净净，`top` 里 RSS 却一路爬。

这类问题的定位工具就是 `ResourceLeakDetector`。但大多数人对它的使用停留在"加个 `-Dio.netty.leakDetection.level=paranoid` 重启试试"，既不知道它为什么能报出泄漏点，也不知道采样率、性能开销、报告字段怎么读。

本文从引用计数模型讲起，拆开 `ResourceLeakDetector` 的采样与记录机制，给出四类高频泄漏模板、可复现的单测写法，以及一套生产环境的分级排查流程。

---

## 一、引用计数：Netty 内存管理的基石

JVM 有 GC，为什么 Netty 还要自己管内存？因为堆外内存（DirectByteBuffer）的回收依赖 `Cleaner` + Full GC 触发，时机不可控；而网络 IO 的生命周期非常明确——**一次读写用完就还**。引用计数把回收时机从"GC 决定"变成"代码决定"。

```java
public interface ReferenceCounted {
    int refCnt();
    ReferenceCounted retain();          // +1
    ReferenceCounted retain(int inc);
    boolean release();                  // -1，归零时 deallocate
    ReferenceCounted touch(Object hint);// 记录访问点（供 LeakDetector 用）
}
```

几条必须记牢的语义：

1. **初始 refCnt = 1**，谁创建谁负责 release。
2. **`release()` 返回 true 表示"这次释放后归零并已回收"**，返回 false 表示还有别人持有。
3. **归零后再 release 会抛 `IllegalReferenceCountException`**，但在池化 + 复用的场景里，更常见的是"双重 release → 内存被池回收给别人 → 脏数据/串包"，比异常更难查。
4. **派生缓冲区共享同一个 refCnt**：`slice()`、`duplicate()`、`readSlice()`、`retainedSlice()` 都共享底层内存。`retainedSlice()` 会额外 `retain()`，所以必须配对 release。
5. **`CompositeByteBuf.release()` 会释放所有组件**，单独 release 组件会导致父 buf 悬空。

池化分配器（`PooledByteBufAllocator`）下，release 只是把 chunk 归还 arena，**不会还给操作系统** —— 所以"RSS 不降"不代表没泄漏，反过来"泄漏了 RSS 也可能看不出来"，必须看 `usedDirectMemory`。

---

## 二、ResourceLeakDetector 是怎么"抓到"泄漏的

核心思路：**给每个被采样的 ByteBuf 挂一个虚引用（或弱引用），对象被 GC 回收后，如果引用计数还没归零，就说明有人忘了 release。**

```
allocate() → 采样命中 → 创建 DefaultResourceLeak（PhantomReference 子类）
          → 包装成 AdvancedLeakAwareByteBuf / SimpleLeakAwareByteBuf
          → 每次访问（writeBytes/readBytes/release）记录一个 Record（环形数组）
release() → 归零 → leak.close() → 从 allLeaks 移除，不再报告
GC 回收 ByteBuf 对象 → ReferenceQueue 出队 → 仍在 allLeaks 中 → 打印 LEAK 报告
```

### 2.1 四个级别与开销

| 级别 | 采样策略 | 记录内容 | 相对开销 | 使用场景 |
|---|---|---|---|---|
| `DISABLED` | 不检测 | 无 | 0 | 极致性能、已确认无泄漏 |
| `SIMPLE`（默认） | 每 113 次分配采样 1 次（`samplingInterval=113`） | 仅创建位置 | ~1~3% | 生产常态 |
| `ADVANCED` | 同样采样，但记录最近 N 次访问（`targetRecords` 默认 4） | 创建点 + 最近 4 次访问栈 | ~5~15% | 预发/灰度排查 |
| `PARANOID` | **每次都采样** | 完整访问链 | 20%+（高分配率下更差） | 本地复现、单测 |

设置方式（三种优先级从低到高）：

```bash
# 1) 系统属性
-Dio.netty.leakDetection.level=paranoid
-Dio.netty.leakDetection.targetRecords=32
-Dio.netty.leakDetection.samplingInterval=1

# 2) 代码（启动时，早于任何 ByteBuf 分配）
ResourceLeakDetector.setLevel(ResourceLeakDetector.Level.PARANOID);

# 3) 环境变量（部分版本支持）
export io.netty.leakDetection.level=advanced
```

> 采样率为什么是 113？这是一个质数，避免与 2 的幂对齐的业务周期（如每 128 次一批的处理逻辑）产生"采样永远命中同一批对象"的偏差。改成 2 的幂会显著降低检出率。

### 2.2 报告解读

```
LEAK: ByteBuf.release() was not called before it's garbage-collected.
See https://netty.io/wiki/reference-counted-objects.html for more information.
Recent access records:
#1:
	io.netty.buffer.AdvancedLeakAwareByteBuf.writeBytes(AdvancedLeakAwareByteBuf.java:589)
	com.example.handler.UplinkHandler.channelRead(UplinkHandler.java:42)
	...
#2:
	io.netty.buffer.AdvancedLeakAwareByteBuf.retain(AdvancedLeakAwareByteBuf.java:495)
	com.example.handler.UplinkHandler.channelRead(UplinkHandler.java:38)
Created at:
	io.netty.buffer.PooledByteBufAllocator.newDirectBuffer(PooledByteBufAllocator.java:402)
	io.netty.buffer.AbstractByteBufAllocator.directBuffer(AbstractByteBufAllocator.java:187)
	com.example.codec.FrameDecoder.decode(FrameDecoder.java:27)
```

读法：

- **`Recent access records` 从上到下是"最近 → 较早"**。`#1` 是最接近泄漏时刻的操作，通常是"最后一次 retain 或最后一次读取"。
- **`Created at` 是分配点**，决定"这个 buf 是谁生的"，配合栈里的业务类名直接定位到代码行。
- 如果只有 `Created at` 没有 access records，说明这个 buf 创建后**从未被访问过** —— 典型是"分配后放进队列/Map，然后忘了"。
- 报告里出现 `retain` 而没有对应 `release`，说明引用计数被加到 2，只释放了一次。

### 2.3 为什么"报告要等 GC"

虚引用只有在对象被 GC 回收后才入队。所以：

- 泄漏报告**有延迟**，不是分配时立刻报。
- 单测里要 `System.gc()` + 短暂 sleep 才能让报告出现（`ResourceLeakDetector` 在 `reportLeak()` 里处理队列，由分配动作触发）。
- 堆越大、GC 越少，报告越晚 —— 生产上开着 SIMPLE 也可能几天才看到一条。

---

## 三、四类高频泄漏模板

### 3.1 异常路径漏 release（最常见）

```java
// ❌ 错误：write 抛异常后 buf 泄漏
public void channelRead(ChannelHandlerContext ctx, Object msg) {
    ByteBuf buf = (ByteBuf) msg;
    ByteBuf out = ctx.alloc().buffer();
    out.writeBytes(transform(buf));       // 抛异常 → out 永远不释放
    ctx.writeAndFlush(out);
    buf.release();
}
```

```java
// ✅ 正确：所有路径都释放，且不重复释放
public void channelRead(ChannelHandlerContext ctx, Object msg) {
    ByteBuf in = (ByteBuf) msg;
    ByteBuf out = null;
    try {
        out = ctx.alloc().buffer();
        out.writeBytes(transform(in));
        ctx.writeAndFlush(out);
        out = null;                       // 所有权交给 pipeline，置空防重复释放
    } catch (Exception e) {
        log.error("transform failed", e);
    } finally {
        ReferenceCountUtil.release(in);
        ReferenceCountUtil.release(out);  // null 安全
    }
}
```

或者更省心：继承 `SimpleChannelInboundHandler<ByteBuf>`，它会在 `channelRead0` 返回后自动 release 入参 —— **但前提是你不把 msg 传出去**：

```java
// ❌ 把 msg 存起来后又指望自动释放
public class BadHandler extends SimpleChannelInboundHandler<ByteBuf> {
    private final Queue<ByteBuf> pending = new ConcurrentLinkedQueue<>();

    @Override
    protected void channelRead0(ChannelHandlerContext ctx, ByteBuf msg) {
        pending.add(msg.retain());   // 加了 retain 却没人 release → 泄漏
    }
}
```

### 3.2 跨 handler 传递所有权

pipeline 里 `ctx.fireChannelRead(msg)` 是"传递所有权"，不需要额外 retain；但**异步回调**里再用 `msg` 就必须 retain：

```java
// ❌ channelRead0 自动 release 后，异步线程还在用
protected void channelRead0(ChannelHandlerContext ctx, ByteBuf msg) {
    executor.submit(() -> process(msg));   // use-after-free（池化后会读到别人数据）
}

// ✅ 异步使用前 retain，用完 release
protected void channelRead0(ChannelHandlerContext ctx, ByteBuf msg) {
    ByteBuf copy = msg.retain();
    executor.submit(() -> {
        try { process(copy); } finally { copy.release(); }
    });
}

// ✅ 更推荐：拷贝出 byte[]，彻底脱离引用计数
protected void channelRead0(ChannelHandlerContext ctx, ByteBuf msg) {
    byte[] data = ByteBufUtil.getBytes(msg);
    executor.submit(() -> process(data));
}
```

### 3.3 出站写失败与 `ChannelOutboundBuffer`

`ctx.write(msg)` 会把 msg 放进 `ChannelOutboundBuffer`，由 Netty 在写成功后释放。但以下情况会漏：

- `write` 之后 channel 已关闭，消息被丢弃（Netty 会释放，但自定义 `ChannelOutboundHandler` 里缓存了引用就会漏）。
- 自己实现了 `flush` 逻辑，`remove()` 取出的 `Entry` 没释放。
- 用 `ChannelFutureListener` 失败回调里再次 `write` 同一个 buf（已被释放）。

### 3.4 池化分配器指标与"假泄漏"

```java
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.buffer.PooledByteBufAllocatorMetric;

PooledByteBufAllocatorMetric m = PooledByteBufAllocator.DEFAULT.metric();
log.info("directUsed={}MB heapUsed={}MB arenas={} chunkSize={}KB",
        m.usedDirectMemory() >> 20,
        m.usedHeapMemory() >> 20,
        m.numDirectArenas(),
        m.chunkSize() >> 10);
```

`usedDirectMemory` 持续单调上升 = 真泄漏；周期性锯齿 = 正常（chunk 归还 arena 但不还给 OS）。注意 `PlatformDependent.maxDirectMemory()` 才是真正的上限（默认等于 `-XX:MaxDirectMemorySize`，未设置时约等于堆最大值）。

---

## 四、把泄漏挡在单测里

`EmbeddedChannel` + `PARANOID` 是性价比最高的防线：

```java
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.util.ResourceLeakDetector;
import org.junit.jupiter.api.*;

import static org.assertj.core.api.Assertions.assertThat;

class FrameDecoderLeakTest {

    @BeforeAll
    static void paranoid() {
        ResourceLeakDetector.setLevel(ResourceLeakDetector.Level.PARANOID);
    }

    @Test
    void should_release_all_buffers_on_partial_frame() throws Exception {
        FrameDecoder decoder = new FrameDecoder(1024);
        EmbeddedChannel ch = new EmbeddedChannel(decoder);

        ByteBuf partial = Unpooled.buffer();
        partial.writeBytes(new byte[]{0x00, 0x00, 0x00, 0x10, 0x01}); // 长度 16，只给 1 字节
        ch.writeInbound(partial);

        assertThat(ch.finish()).isTrue();   // finish 会释放残留的 inbound/outbound buffer

        // 触发 ReferenceQueue 处理，让泄漏报告有机会打印
        for (int i = 0; i < 3; i++) {
            System.gc();
            Thread.sleep(50);
            Unpooled.buffer(1).release();   // 触发 reportLeak()
        }
    }
}
```

要点：

- `ch.finish()` 会检查并释放未消费的 buffer，是发现"handler 吞了消息"的好方法。
- `System.gc()` 不保证立即回收，循环几次并做一次分配来触发 `reportLeak()`。
- CI 里跑 `PARANOID` 成本可接受（测试数据量小），能把泄漏拦在合并前。

---

## 五、生产排查流程（分级，别一上来就 paranoid）

```
现象：RSS / usedDirectMemory 单调上升 → 疑似堆外泄漏
  │
  ├─ 1. 确认是 Netty 还是 JDK/其他库
  │     jcmd <pid> VM.native_memory summary   # 看 "Other" / "Internal" 增长
  │     BufferPoolMXBean (java.nio:type=BufferPool,name=direct) 看 count/memoryUsed
  │
  ├─ 2. 灰度一台开 ADVANCED（targetRecords=16）
  │     观察 24h，等 LEAK 报告；采样率保持 113，开销可控
  │
  ├─ 3. 报告定位到类 → 代码审查该路径的 release
  │     重点看：异常分支、异步回调、缓存/队列、retainedSlice
  │
  ├─ 4. 仍无法定位 → 单机 PARANOID + 复现流量回放
  │     必要时 -Dio.netty.leakDetection.samplingInterval=1
  │
  └─ 5. 兜底：-XX:MaxDirectMemorySize 显式限制 + 告警
        （Netty 的 PlatformDependent 会读该值，避免吃光容器内存）
```

几个实战经验：

- **先看是不是 `CompositeByteBuf`**。很多泄漏来自 `CompositeByteBuf.addComponent(true, buf)` 后只 release 了 composite，或者反过来只 release 了 component。
- **看 channel 关闭路径**。连接异常关闭时 `channelInactive` 里缓存的 buf 最容易漏。
- **警惕 `retain()` 的"防御性写法"**。有人为了"保险"到处 retain，结果计数永远归不了零；`retain` 必须有明确的所有权转移理由。
- **`paranoid` 会让吞吐掉 20%+**，绝不能在核心集群全量开；ADVANCED 足够定位大多数问题。
- **报告可能被日志框架吞掉**。`ResourceLeakDetector` 用 `InternalLoggerFactory`，如果 slf4j 绑定到了错误的 logger 级别（`io.netty` 设成 OFF），报告就消失了。

---

## 六、面试常见追问

**Q1：JVM 有 GC，为什么 Netty 还要引用计数？**
堆外内存的回收时机不可控（依赖 `Cleaner` + GC），而网络缓冲区生命周期明确。引用计数让"用完即还"成为确定性行为，避免堆外内存堆积到 GC 才释放，也避免大 buf 长期占用导致的 RSS 膨胀。

**Q2：为什么泄漏检测要采样？**
每次分配都挂引用、记录栈，开销在 20% 以上且会产生大量短命对象。采样（1/113）在"泄漏通常成规模发生"的前提下仍能高概率命中，同时把开销压到个位数。

**Q3：`SimpleChannelInboundHandler` 自动释放，为什么还会泄漏？**
它只释放 `channelRead0` 的入参。如果你 `retain()` 后存起来、传给异步线程、或者放进 `CompositeByteBuf`，这些额外引用不会被自动释放。

**Q4：`release()` 返回 false 意味着泄漏吗？**
不。返回 false 表示"还有引用持有"，是正常的多所有者场景。只有当所有持有者都不再 release、对象被 GC 时才叫泄漏。

**Q5：双重 release 会怎样？**
归零后再 release 会抛 `IllegalReferenceCountException`；但在池化分配器下更危险的是"归零 → chunk 被复用给别的连接 → 原代码还在写"，表现为串包、协议解析错乱，且不会抛异常。

**Q6：怎么证明泄漏的是 Netty 而不是 JDK 的 DirectByteBuffer？**
`BufferPoolMXBean` 统计的是 JDK 层的 direct buffer（Netty 的池化 buf 也走 `ByteBuffer.allocateDirect`，会计入）；配合 NMT 的 `Other` 区、`PooledByteBufAllocatorMetric.usedDirectMemory` 三者交叉对比：MXBean 涨但 Netty metric 不涨 → 非 Netty 泄漏。

---

## 七、小结

- Netty 用引用计数把堆外内存回收变成确定性行为，代价是每个使用点都要正确配对 `retain/release`。
- `ResourceLeakDetector` 基于"虚引用 + 引用队列 + 采样"，报告延迟到 GC 之后，`SIMPLE` 是生产默认，`ADVANCED` 用于定位，`PARANOID` 只用于本地与单测。
- 报告里 `Created at` 找"谁分配的"，`Recent access records` 找"谁最后碰过"，两者结合基本能锁定代码行。
- 四类高频泄漏：异常路径、跨 handler 异步使用、出站失败缓存、Composite/派生 buf 的所有权混乱。
- 治理闭环：`EmbeddedChannel + PARANOID` 单测拦截 → 灰度 `ADVANCED` 观测 → `usedDirectMemory` 告警 → `MaxDirectMemorySize` 兜底。
