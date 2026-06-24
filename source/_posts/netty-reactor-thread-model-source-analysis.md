---
title: 【源码深度】Netty Reactor 线程模型全解析：从 NioEventLoop 到百万并发
date: 2026-06-24 08:00:00
tags:
  - Java
  - Netty
  - 网络编程
  - 源码
categories:
  - Java
  - 网络编程
author: 东哥
---

# 【源码深度】Netty Reactor 线程模型全解析：从 NioEventLoop 到百万并发

## 面试官：说说 Netty 的线程模型？跟传统 BIO 比有什么优势？

Netty 作为业界最流行的异步事件驱动网络框架，支撑了 Dubbo、RocketMQ、Elasticsearch 等众多中间件的高性能网络通信。理解 Netty 的线程模型，是深入 Java 网络编程的必修课。

## 一、从传统 BIO 到 NIO 再到 Netty

### 1.1 BIO 模型的问题

传统 BIO（Blocking I/O）采用"一个线程处理一个连接"的模式：

```java
// 传统 BIO 服务端
ServerSocket serverSocket = new ServerSocket(8080);
while (true) {
    Socket socket = serverSocket.accept(); // 阻塞
    new Thread(() -> handle(socket)).start(); // 每个连接一个线程
}
```

**问题**：当并发连接数达到上千甚至上万时，会创建大量线程，导致：
- 线程上下文切换开销巨大
- 内存占用过高（每个线程默认栈 1MB）
- 连接越多，性能越差

### 1.2 Reactor 模式

Reactor 模式的核心思想是 **事件驱动** + **非阻塞 I/O**：

- 一个或多个 **Reactor**（反应器）负责监听 I/O 事件
- 事件到达后分发给对应的 **Handler** 处理
- 使用少量线程处理大量连接

```
┌─────────────┐    事件分发     ┌─────────────┐
│  Reactor    │ ──────────────→ │  Handler1   │
│  (Selector) │                ├─────────────┤
│             │                │  Handler2   │
│             │                ├─────────────┤
│             │                │  Handler... │
└─────────────┘                └─────────────┘
```

## 二、Netty 的线程模型演进

Netty 主要支持两种线程模型：**Reactor 单线程模型** 和 **主从 Reactor 多线程模型**。

### 2.1 单 Reactor 单线程模型

所有 I/O 操作由一个线程完成，适用于小规模场景：

```java
EventLoopGroup group = new NioEventLoopGroup(1);
ServerBootstrap b = new ServerBootstrap();
b.group(group)
 .channel(NioServerSocketChannel.class)
 .childHandler(new ChannelInitializer<SocketChannel>() {
     @Override
     protected void initChannel(SocketChannel ch) {
         ch.pipeline().addLast(new EchoServerHandler());
     }
 });
```

**适用**：连接数少（<100），处理速度快。

### 2.2 主从 Reactor 多线程模型（Netty 推荐）

这是 Netty 的经典模型，**也是面试重点**：

```java
EventLoopGroup bossGroup = new NioEventLoopGroup(1);      // 接收连接
EventLoopGroup workerGroup = new NioEventLoopGroup();      // 处理读写
ServerBootstrap b = new ServerBootstrap();
b.group(bossGroup, workerGroup)
 .channel(NioServerSocketChannel.class)
 .childHandler(new ChannelInitializer<SocketChannel>() {
     @Override
     protected void initChannel(SocketChannel ch) {
         ch.pipeline().addLast(
             new LengthFieldBasedFrameDecoder(...),
             new StringDecoder(),
             new ServerBizHandler()
         );
     }
 });
```

**架构图**：

```
                    ┌─────────────────┐
                    │  Boss Group     │
                    │  (1 Thread)     │
                    │  NioEventLoop   │
                    └────────┬────────┘
                             │ accept 连接
                             ▼
              ┌──────────────────────────────┐
              │     Worker Group             │
              │  (默认 CPU核数×2 个线程)      │
              │                              │
              │  NioEventLoop1 → Selector    │
              │  NioEventLoop2 → Selector    │
              │  NioEventLoop3 → Selector    │
              │  ...                         │
              └──────────────────────────────┘
```

**核心职责**：
- **Boss Group**：负责 accept 新连接，将连接注册到 Worker Group
- **Worker Group**：负责读写 I/O 事件，执行 ChannelHandler 链

## 三、NioEventLoop 源码深度解析

这是 Netty 线程模型的核心类，**面试最常问**。

### 3.1 创建过程

```java
// NioEventLoopGroup 构造
public NioEventLoopGroup(int nThreads) {
    this(nThreads, (Executor) null);
}

// 默认线程数 = CPU核数 × 2
// 如果不传参，Netty 会调用 NettyRuntime.availableProcessors() * 2
```

`NioEventLoopGroup` 内部会创建 `NioEventLoop` 数组，每个 `NioEventLoop` 持有一个 `Selector`：

```java
// MultithreadEventLoopGroup 中
private static final int DEFAULT_EVENT_LOOP_THREADS =
    Math.max(1, SystemPropertyUtil.getInt(
        "io.netty.eventLoopThreads",
        NettyRuntime.availableProcessors() * 2));
```

### 3.2 NioEventLoop 的核心结构

```java
public final class NioEventLoop extends SingleThreadEventLoop {
    private Selector selector;           // 持有的 Selector
    private SelectedSelectionKeySet selectedKeys; // 优化后的就绪事件集合
    private final SelectorProvider provider;
    
    // 核心 run() 方法
    @Override
    protected void run() {
        int selectCnt = 0;
        for (;;) {
            try {
                int strategy = selectStrategy.calculateStrategy(selectNowSupplier, hasTasks());
                switch (strategy) {
                    case SelectStrategy.CONTINUE:  // 继续
                        continue;
                    case SelectStrategy.BUSY_WAIT: // 自旋等待
                        // fall through to SELECT
                    case SelectStrategy.SELECT:    // 正常 select
                        long curDeadlineNanos = nextScheduledTaskDeadlineNanos();
                        if (curDeadlineNanos == -1) {
                            curDeadlineNanos = 0; // 无定时任务，阻塞 select
                        }
                        // IO 比例控制：默认 50%
                        if (selectCnt == 0) {
                            // 阻塞 select，直到有事件或定时任务到期
                            selector.select(curDeadlineNanos);
                        }
                        selectCnt = 0;
                        break;
                }
                
                // 处理 I/O 事件
                processSelectedKeys();
                
                // 执行任务队列中的普通任务
                runAllTasks();
                
                // 处理优雅关闭
                if (isShuttingDown()) {
                    closeAll();
                    return;
                }
            } catch (Exception e) {
                // 防止空轮询 bug
                if (selectCnt > 0) {
                    rebuildSelector();
                }
            }
        }
    }
}
```

### 3.3 IO 比例控制

Netty 通过 `ioRatio` 控制 I/O 事件处理与普通任务的执行比例：

```java
// 默认 ioRatio = 50
private volatile int ioRatio = 50;

protected void runAllTasks() {
    runAllTasks0(ioRatio == 100 ? 0 : 
                 TimeUnit.MILLISECONDS.toNanos(
                     (long) (ioTimeMillis * (100.0 / ioRatio - 1.0))));
}
```

含义：I/O 事件处理用了 **T** 时间，则普通任务最多用 `T × ((100/ioRatio) - 1)` 时间。

- `ioRatio = 50`：I/O 和任务各占一半时间
- `ioRatio = 100`：不限制任务执行时间

### 3.4 NioEventLoop 的任务执行机制

`NioEventLoop` 不仅处理 I/O 事件，还承担着 **任务队列** 的执行：

```java
// 1. 普通任务 - 在非 I/O 线程中提交的任务
eventLoop.execute(() -> {
    System.out.println("在 EventLoop 中执行任务");
});

// 2. 定时任务 - 基于 ScheduledExecutorService
eventLoop.schedule(() -> {
    System.out.println("延迟 5 秒执行");
}, 5, TimeUnit.SECONDS);

// 3. Channel 写入任务 - 确保线程安全
channel.write(new TextWebSocketFrame("hello"));
```

**为什么 Netty 不建议在 Handler 中做耗时操作？** 
因为 Handler 直接在 NioEventLoop 中执行，会阻塞其他 Channel 的读写。

### 3.5 Selector 空轮询 Bug 处理

JDK NIO 在 Linux 上有个著名的 **epoll 空轮询 bug**：即使没有就绪事件，`selector.select()` 也不会阻塞，导致 CPU 100%。

Netty 的解决方案：

```java
// 在 NioEventLoop 中
if (SELECTOR_AUTO_REBUILD_THRESHOLD > 0 &&
    selectCnt >= SELECTOR_AUTO_REBUILD_THRESHOLD) {
    // 超过阈值(默认512次)，重建 Selector
    rebuildSelector();
    selectCnt = 0;
    break;
}
```

**处理流程**：
1. 记录 `selectCnt`，判断是否连续空转
2. 如果超过 512 次，创建新的 Selector
3. 将旧 Selector 上注册的所有 Channel 重新注册到新 Selector
4. 关闭旧 Selector

## 四、ChannelPipeline 与 Handler 执行链路

### 4.1 Pipeline 架构

```
                            ┌─────────────────────────────┐
                            │      ChannelPipeline        │
                            │                             │
   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐ │
   │ Handler1│←──│ Handler2│←──│ Handler3│←──│ Handler4│←┤ 入站 (inbound)
   │ (In)    │   │ (In)    │   │ (Out)   │   │ (Out)   │ │
   └─────────┘   └─────────┘   └─────────┘   └─────────┘ │
         │             │             │             │       │
   ──────┴─────────────┴─────────────┴─────────────┴───────┘
   出站 (outbound)     →     →     →     →     →     →
```

### 4.2 事件传播源码

```java
// 入站事件传播：从 head 到 tail
public class DefaultChannelPipeline {
    final AbstractChannelHandlerContext head;
    final AbstractChannelHandlerContext tail;
    
    @Override
    public final ChannelPipeline fireChannelRead(Object msg) {
        // 从 head 开始，沿着链表依次调用
        AbstractChannelHandlerContext.invokeChannelRead(head, msg);
        return this;
    }
}

// 出站事件传播：从 tail 到 head
@Override
public final ChannelFuture write(Object msg) {
    return tail.write(msg);
}
```

每个 Handler 可以通过 `ctx.fireChannelRead(msg)` 将事件传递给下一个 Handler。

## 五、Netty 的内存管理

### 5.1 堆外内存（Direct Buffer）

```java
// 分配堆外内存
ByteBuf buffer = Unpooled.directBuffer(1024);

// Netty 使用 PooledByteBufAllocator 进行池化管理
// 默认开启，比 Unpooled 性能提升显著
```

**为什么用堆外内存？**
- 减少 GC 压力
- 避免 I/O 操作时的内存拷贝（堆内存 → 堆外 → Socket）
- 零拷贝技术的基石

### 5.2 内存池 Jemalloc 算法

Netty 借鉴 jemalloc 实现了 `PooledByteBufAllocator`：

| 层级 | 名称 | 大小范围 |
|------|------|---------|
| Tiny | 微块 | 512B 以内（16B 递增） |
| Small | 小块 | 512B ~ 8KB |
| Normal | 普通块 | 8KB ~ 16MB |
| Huge | 大块 | 16MB 以上 |

通过 `Recycler` 对象池复用对象，进一步减少 GC 压力。

## 六、Netty 核心配置最佳实践

### 6.1 参数调优

```java
ServerBootstrap b = new ServerBootstrap();
b.group(bossGroup, workerGroup)
 .option(ChannelOption.SO_BACKLOG, 1024)       // TCP 半连接队列大小
 .option(ChannelOption.TCP_NODELAY, true)       // 禁用 Nagle 算法
 .option(ChannelOption.SO_KEEPALIVE, true)      // 启用 TCP 保活
 .option(ChannelOption.SO_REUSEADDR, true)      // 地址复用
 .childOption(ChannelOption.WRITE_BUFFER_WATER_MARK,
     new WriteBufferWaterMark(32 * 1024, 64 * 1024)); // 写缓冲区水位线
```

### 6.2 性能对比

| 指标 | BIO | NIO (原生) | Netty |
|------|-----|-----------|-------|
| 线程数 | 连接数 × 1 | 1 ~ 少量 | 少量 (CPU×2) |
| 最大连接数 | 几千 | 数万 | 百万+ |
| 编码难度 | 低 | 高 | 中 |
| 零拷贝 | 不支持 | 支持 | 全面支持 |
| 内存池 | 无 | 无 | jemalloc 池化 |

### 6.3 常见问题

**Q：NioEventLoop 和 Channel 的关系？**
A：一个 NioEventLoop 可以管理多个 Channel，但一个 Channel 只属于一个 NioEventLoop（保证了 Channel 的线程安全）。

**Q：Netty 的 write 操作是线程安全的吗？**
A：是的。无论从哪个线程调用 `channel.write()`，最终都会包装成任务提交到该 Channel 绑定的 NioEventLoop 中执行。

**Q：什么是 Netty 的"零拷贝"？**
A：包括：FileRegion 文件传输、CompositeByteBuf 组合缓冲区、Unpooled.wrappedBuffer 包装数组等。

## 七、总结

Netty 的线程模型基于 **主从 Reactor 多线程模型**，核心是 `NioEventLoop` —— 一个线程对应一个 Selector + 任务队列的循环。理解 NioEventLoop 的运行机制、I/O 比例控制、Selector 空轮询修复等源码细节，是面试通关的关键。

Netty 的设计很多地方都值得学习：事件驱动、责任链模式、内存池化、零拷贝、对象复用……这些思想可以用在任何一个高性能 Java 系统中。

🔥 **面试追问准备**：
1. Netty 如何解决 JDK Selector 空轮询 bug？
2. Netty 的 EventLoop 和 Channel 是如何绑定的？
3. Pipeline 中 Handler 的执行顺序是怎样的？
4. Netty 的 heap buffer 和 direct buffer 有什么区别？
5. 什么是 Netty 的背压机制（Writability）？
