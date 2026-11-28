---
title: 【Netty 实战】写缓冲与水位线深度解析：为什么 Channel.isWritable() 是背压的唯一起点
date: 2026-11-28 08:00:00
tags:
  - Java
  - Netty
  - 背压
  - 网络编程
  - 生产实战
categories:
  - Java 实战
author: 东哥
---

# 【Netty 实战】写缓冲与水位线深度解析

## 前言

一个消息推送服务，20 万长连接，平时内存 3GB。某天做了一次「全量广播」，十分钟后容器被 OOMKilled，堆 dump 里堆对象不多，但 Native Memory 涨到 12GB，`pmap` 显示大量 64KB 的匿名映射块。

排查到最后，根因只有一句话：**业务代码把 `channel.writeAndFlush(msg)` 当成了「发出去」，而它实际只是「放进队列」**。慢客户端消费不过来，队列里的 `ByteBuf` 就一直堆着；每个连接堆几十条，20 万连接就是几个 GB 的堆外内存。

Netty 早就给了这个问题的答案：`Channel.isWritable()` 和 `WRITE_BUFFER_WATER_MARK`。但很多人只在文档里见过这两个词，不知道它统计的是什么、什么时候翻转、翻转了该怎么用。

这篇把出站写链路拆开讲清楚：一次 `write` 到底做了什么、水位线怎么算、`isWritable()` 为什么是背压的**唯一正确起点**、以及四种典型积压的归因方式。

> 分工说明：站内已有《Netty ByteBuf 内存池》《ResourceLeakDetector 内存泄漏排查》《Netty Reactor 线程模型》《WebFlux 背压》。本篇只讲**出站方向的应用层写队列**：数据从 `channel.write()` 进入到 `socketChannel.write()` 离开之间的那段缓冲，以及围绕它的水位线与背压设计。

---

## 一、`writeAndFlush` 不是「发出去」

先把一次调用的完整路径摆出来：

```
业务线程                                     EventLoop 线程
   |                                              |
   |-- channel.writeAndFlush(msg) --------------->|
   |      (若不在 EventLoop 内，封装成 task 入队)   |
   |                                              |
   |                                     pipeline 出站传播
   |                                              |
   |                              ChannelOutboundBuffer.addMessage()
   |                                              |
   |                                     addFlush() 标记 flush 点
   |                                              |
   |                                     flush0() -> doWrite()
   |                                              |
   |                                     socketChannel.write()  // 可能只写一部分
   |                                              |
   |                                     写不完 -> 注册 OP_WRITE，返回
```

关键点有三个：

1. **跨线程调用是异步的**。业务线程调用 `writeAndFlush` 时，如果当前线程不是该 Channel 的 EventLoop 线程，Netty 会把操作包装成 task 丢进 EventLoop 的 `taskQueue`，方法立刻返回。所以「调用返回了」连「数据进了队列」都不一定保证。
2. **进了队列不等于出了网卡**。`ChannelFuture` 只有在数据真正交给内核并且 Netty 认为这条消息写完时才 `complete`。
3. **一次 `socketChannel.write()` 可能只写一部分**。内核发送缓冲区满了就返回 0 或部分字节，剩下的留在 `ChannelOutboundBuffer` 里等 `OP_WRITE` 事件。

所以「背压」这件事，Netty 不可能替你自动做完——它只能告诉你「我这里积压了多少」，剩下的「要不要继续读上游、要不要丢、要不要限速」必须业务决定。

---

## 二、ChannelOutboundBuffer 的结构

`ChannelOutboundBuffer` 本质是一个单向链表 + 三个游标：

| 字段 | 含义 |
|---|---|
| `unflushedEntry` | 已 `write` 但还没 `flush` 的第一条 |
| `flushedEntry` | 已 `flush`、等待真正写出的第一条 |
| `tailEntry` | 链表尾部 |
| `totalPendingSize` | **所有未写完消息的字节数之和**（水位线就统计它） |
| `unwritable` | 当前是否处于「不可写」状态的布尔标记 |

三个动作对应三段语义：

- `addMessage(msg)`：挂到 `tailEntry`，`totalPendingSize += size`，并检查是否越过**高水位**。
- `addFlush()`：把 `unflushedEntry` 到 `tailEntry` 这一段标记为 flushed（移动 `flushedEntry` 指针）。
- `remove()`：某条消息真正写完，从链表摘除，`totalPendingSize -= size`，检查是否回落到**低水位**以下。

注意 `totalPendingSize` 的统计口径：Netty 用的是 `buf.readableBytes()` 再加每条消息一个固定的 entry 估算开销（约 96 字节，不同版本常量略有差异）。所以它统计的是「用户态待发字节」，**不包含** `ByteBuf` 池的碎片、`CompositeByteBuf` 的组件对象开销、也不包含内核 `SO_SNDBUF` 里已经拷贝的数据。

这就解释了一个常见困惑：`totalPendingSize` 只有 40MB，进程 RSS 却涨了 300MB。差额在对象头、池化管理、以及内核缓冲。

---

## 三、水位线：一个迟滞比较器

默认值来自 `WriteBufferWaterMark.DEFAULT`：

```java
// Netty 源码语义
new WriteBufferWaterMark(32 * 1024, 64 * 1024); // low, high
```

规则只有两条：

1. `totalPendingSize > high` → `unwritable = true`，触发 `fireChannelWritabilityChanged()`。
2. `totalPendingSize < low` → `unwritable = false`，再次触发事件。

为什么要有两个阈值而不是一个？因为单阈值会在边界上疯狂抖动：写一条越界、写出去一条又回落，`writabilityChanged` 事件会变成风暴，而每次事件通常伴随「暂停/恢复上游读取」这种重操作。**低水位低于高水位，形成迟滞（hysteresis）**，是控制系统里的标准做法。

也可以自己指定：

```java
ServerBootstrap b = new ServerBootstrap();
b.childOption(ChannelOption.WRITE_BUFFER_WATER_MARK,
        new WriteBufferWaterMark(128 * 1024, 512 * 1024));
```

调大还是调小，取决于三个量：

| 参数 | 调大的后果 | 调小的后果 |
|---|---|---|
| 高水位 | 单连接可积压更多，抗突发强；内存上限抬高 | 更早触发背压，可能误伤正常突发 |
| 低水位 | 恢复更迟钝，容易长时间停读 | 频繁翻转，事件风暴 |
| 高低差 | 抗抖动强，但内存摆动幅度大 | 抖动敏感 |

一个粗略的容量算式：

```
单连接内存上限 ≈ high + 单条最大消息大小
总内存上限   ≈ 连接数 × (high + 单条最大消息大小) × 安全系数(1.5~2)
```

2 万连接、默认 64KB 高水位，理论上限就是 1.3GB —— 这个数字在「默认配置没人管」的服务里非常常见，也非常危险。

---

## 四、`isWritable()` 的正确用法

先看三种典型写法，只有第三种是对的。

### 错误写法 1：写完再判断

```java
// 错：判断时消息已经进队列了
channel.writeAndFlush(msg);
if (!channel.isWritable()) {
    // 此时才想停，已经晚了，而且这条消息已经在队列里
}
```

### 错误写法 2：只在写之前判一次

```java
// 半错：单线程下看似能用，多线程下必翻车
if (channel.isWritable()) {
    channel.writeAndFlush(msg);
}
```

问题在于跨线程：`isWritable()` 是读 `unwritable` 标记，而标记由 EventLoop 线程在 `addMessage` / `removeBytes` 时修改；业务线程判完到真正入队之间，EventLoop 可能又把队列写满了。**判断和入队不是原子的**，所以这只是「降低概率」，不能作为背压依据。

### 正确写法：事件驱动

```java
public class WritabilityGuardHandler extends ChannelDuplexHandler {

    private final AtomicBoolean paused = new AtomicBoolean();
    private volatile Upstream upstream; // 例如 KafkaConsumer / MQ 消费者 / 数据库游标

    @Override
    public void channelWritabilityChanged(ChannelHandlerContext ctx) throws Exception {
        boolean writable = ctx.channel().isWritable();
        if (!writable && paused.compareAndSet(false, true)) {
            // 进入不可写：暂停上游数据源，这是真正的背压
            upstream.pause();
            log.warn("channel {} unwritable, pending={}, bytesBeforeWritable={}",
                    ctx.channel().id().asShortText(),
                    pendingOf(ctx.channel()),
                    ctx.channel().bytesBeforeWritable());
        } else if (writable && paused.compareAndSet(true, false)) {
            upstream.resume();
        }
        ctx.fireChannelWritabilityChanged();
    }
}
```

这里有几个细节值得强调：

- **`channelWritabilityChanged` 必须在 `ChannelInitializer` 里加上**，而且 `ctx.fireChannelWritabilityChanged()` 别忘，否则后面的 handler 收不到。
- **暂停上游才是背压**。仅仅 `isWritable() == false` 时不写，只是把压力留在自己的业务队列里，内存只是换了个地方爆。
- **恢复要有「水位回落到低水位」这个条件**，不能一看到能写就全速恢复，否则立刻又打满。
- **`bytesBeforeWritable()` / `bytesBeforeUnwritable()`** 这两个 API 很实用：前者告诉你还差多少字节能恢复写，后者告诉你还能再塞多少字节才翻转。

### 自动读与写背压的联动

Netty 的 `autoRead` 控制的是**读方向**。很多「服务端推送」场景其实没有读流量，`autoRead` 帮不上忙；但对双向协议（如 MQTT、自定义 RPC），可以这样联动：

```java
if (!ch.isWritable()) {
    ch.config().setAutoRead(false);   // 停止从对端读，压制请求速率
} else {
    ch.config().setAutoRead(true);
}
```

注意：`setAutoRead(false)` 只能压住**同一连接上的请求**。如果上游是 Kafka 消费者或另一个服务，必须像上面那样显式 pause。

---

## 五、四种积压，归因方式完全不同

看到内存涨，很多人第一反应是「水位线设小了」。其实积压有四类，处理手段不同：

| 类型 | 特征 | 判据 | 处理 |
|---|---|---|---|
| 应用写入过快 | `totalPendingSize` 高，`unwritable` 占比高，EventLoop CPU 不高 | 写入 QPS × 平均消息大小 > 出口带宽 | 限速 / 合并消息 / 背压上游 |
| EventLoop 被阻塞 | 写队列堆积但 socket 可写，`OP_WRITE` 不触发 | 单次 `channelRead`/业务回调耗时 > 10ms，`EventLoop` pending task 多 | 业务逻辑移出 EventLoop，用 `DefaultEventExecutorGroup` |
| 对端接收慢 | `ss -tmi` 显示 `Send-Q` 满、零窗口、retrans 增长 | 客户端网络差 / 客户端不读 | 丢旧消息 / 降级 / 断开慢连接 |
| TLS / 握手未完成 | 连接建立但写不出去 | `SslHandler` 未完成握手时写入会被缓存 | 握手超时 + 限额 |

第二类最隐蔽。`EventLoop` 线程如果被一次慢 SQL 或一次同步 HTTP 调用卡住 500ms，这 500ms 内所有连接的写都停摆，队列全部堆积。这时候水位线会全行业务翻红，但根因根本不在水位线。

排查顺序建议：先看 `unwritable` 连接占比是否**集中在少数连接**（对端慢）还是**全量同时翻红**（EventLoop 卡住 / 下游过载），再看 EventLoop 的 task 队列积压和执行耗时。

---

## 六、可观测：三个必看指标

Netty 没有直接暴露 `ChannelOutboundBuffer.totalPendingSize` 的公开 API，但我们可以用等价手段：

```java
public final class WriteBufferMetricsHandler extends ChannelDuplexHandler {

    private final MeterRegistry registry;
    private final AtomicLong unwritableSince = new AtomicLong(0);

    @Override
    public void channelActive(ChannelHandlerContext ctx) {
        Gauge.builder("netty_write_bytes_before_unwritable",
                ctx.channel(), ch -> ch.bytesBeforeUnwritable())
             .register(registry);
        ctx.fireChannelActive();
    }

    @Override
    public void channelWritabilityChanged(ChannelHandlerContext ctx) {
        if (!ctx.channel().isWritable()) {
            unwritableSince.compareAndSet(0, System.nanoTime());
            registry.counter("netty_channel_unwritable_total").increment();
        } else {
            long since = unwritableSince.getAndSet(0);
            if (since > 0) {
                registry.timer("netty_unwritable_duration")
                        .record(System.nanoTime() - since, TimeUnit.NANOSECONDS);
            }
        }
        ctx.fireChannelWritabilityChanged();
    }
}
```

三个核心指标：

1. **`unwritable` 连接比例**：全局 1% 和全局 80% 是完全不同的故障。
2. **`unwritable` 持续时长分布**：短抖动是正常突发，P99 超过几秒说明客户端确实不消费。
3. **`WriteTimeoutHandler` 触发次数**：写 Future 长时间不 complete，说明对端或链路有问题。

```java
pipeline.addLast(new WriteTimeoutHandler(30, TimeUnit.SECONDS));
```

这个 handler 会在「写操作超过 30 秒还没完成」时抛 `WriteTimeoutException` 并关闭连接 —— 对推送类服务，这是防止慢连接吃掉内存的最后一道闸。

---

## 七、和 TCP 发送缓冲的关系

容易混淆的一点：用户态水位线和内核 `SO_SNDBUF` 是**两级缓冲**，方向一致但量级差很多。

```
应用 ByteBuf --> ChannelOutboundBuffer(用户态) --> SO_SNDBUF(内核) --> 网卡队列 --> 对端
                 ^ 水位线在这里                 ^ 这里满了 write 返回 0
```

- 内核缓冲满了，`socketChannel.write()` 返回 0，Netty 注册 `OP_WRITE` 等待。
- 对端窗口为 0 时，内核甚至不会消费 `SO_SNDBUF`，最终表现出来就是「用户态队列越堆越高」。
- 所以 `totalPendingSize` 持续上涨，永远是**下游链路或对端**的问题，不可能是「Netty 写得太慢」。

`ss -tmi` 里的 `Send-Q` 是内核里还没被 ACK 的字节数，`skmem` 里的 `wmem_alloc` 是已分配的内核写缓冲。这两个数加上用户态的 pending，才是完整的「在途数据」。

---

## 八、生产配置清单

1. **高水位按「单条消息大小 × 可接受积压条数」反推**，不要用默认 64KB。一条 1MB 的消息，默认高水位连一条都装不下，水位线形同虚设。
2. **单条消息大小要设硬上限**。水位线是「累计」控制，挡不住单条 50MB 的消息直接吃满内存。
3. **必须实现 `channelWritabilityChanged` 并真的暂停上游**，否则水位线只是观测，不是控制。
4. **加 `WriteTimeoutHandler`**，给慢连接一个明确的死亡时间。
5. **广播类场景不要用 `writeAndFlush` 循环全量推**，改成「按可写状态分批推 + 丢弃过期消息」，因为广播的语义本来就是「最新的才有价值」。
6. **监控 unwritable 比例和持续时间**，而不是只看堆内存。

一个「按可写状态分批」的广播骨架：

```java
public void broadcast(List<Channel> targets, Object msg, int batch) {
    int sent = 0;
    for (Channel ch : targets) {
        if (!ch.isActive()) continue;
        if (!ch.isWritable()) {
            // 广播场景：不可写就丢，不排队（避免内存放大）
            dropped.incrementAndGet();
            continue;
        }
        ch.write(msg);           // 只 write，不 flush
        if (++sent % batch == 0) {
            for (Channel c : targets) if (c.isActive()) c.flush();
        }
    }
    for (Channel c : targets) if (c.isActive()) c.flush();
}
```

`write` 与 `flush` 分离的价值在于：一批小消息合并成一次系统调用，减少 syscall 次数和 TCP 小包。但要注意，`write` 不 flush 时数据只停在 `unflushedEntry`，**不会触发 `totalPendingSize` 的高水位判断吗？** 会的 —— `addMessage` 时就已经累加了，所以水位线对「只 write 不 flush」同样生效。这也是为什么长时间不 flush 会看到「明明没发数据，怎么就不可写了」。

---

## 九、面试常见追问

**Q1：`writeAndFlush` 返回的 Future 完成，代表对端收到了吗？**
不代表。它只代表数据已经写入内核发送缓冲区（或者在 TLS 场景下已完成加密并写出）。对端是否收到需要应用层 ACK。

**Q2：为什么水位线默认是 32KB / 64KB？**
这是「大多数 RPC 场景单条消息几 KB、允许积压十几条」的经验值。它对大消息场景完全不适用，所以生产必须显式配置。

**Q3：`isWritable()` 为 true 就一定能 write 成功吗？**
不一定。它只表示「当前用户态队列低于高水位」。write 本身不会失败（只是入队），真正写出仍可能部分写、延后写。

**Q4：为什么在业务线程里 `writeAndFlush` 后立刻 `isWritable()` 判断不可靠？**
因为跨线程时写操作被封装成 task 投递到 EventLoop，标记的更新发生在 EventLoop 线程；业务线程读到的可能是旧值。

**Q5：水位线能替代 TCP 流控吗？**
不能，两者在不同层。TCP 流控保护的是网络和对端接收缓冲；水位线保护的是本进程的堆外内存。必须两级都有。

**Q6：`ChannelOutboundBuffer` 里的 ByteBuf 什么时候释放？**
写出完成后由 Netty 释放（引用计数减一）。所以业务代码在 `write` 之后**不能**再 `release()`，否则就是 use-after-free；反之，如果消息在入队前就抛异常，业务侧必须自己释放。

---

## 小结

出站写链路的本质是「用户态队列 + 事件驱动 + 迟滞水位」：

- `write` 只是入队，`flush` 才触发真正的写；
- `totalPendingSize` 越过**高水位**变不可写，回落到**低水位**才恢复；
- `isWritable()` 是背压的**信号**，不是背压本身，背压要靠暂停上游；
- 积压分四类，先分清是「对端慢」「EventLoop 卡」「应用写太快」还是「握手未完成」，再谈调参；
- 水位线挡不住单条超大消息，也挡不住跨线程的竞态，必须有消息大小上限和 `WriteTimeoutHandler` 兜底。

把这几个点做对，推送服务和网关才不会在流量高峰时用 OOM 的方式提醒你「该做背压了」。
