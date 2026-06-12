---
title: Java IO 与 NIO 详解
date: 2026-06-13 15:00:00
tags:
  - Java
  - IO
  - NIO
  - Netty
  - 网络编程
categories: Java基础
---

## 一、前言

Java 的 I/O（Input/Output）体系是每个 Java 开发者都必须掌握的核心知识。从传统 BIO（Blocking I/O）到 NIO（Non-blocking I/O），再到 AIO（Asynchronous I/O），Java 的 I/O 模型经历了多次演进。本文将深入剖析 Java IO 的核心概念、设计模式演进、底层原理及最佳实践。

<!-- more -->

## 二、BIO：传统阻塞 I/O

### 2.1 流的概念

Java 1.0 引入的 IO 体系基于**流（Stream）** 模型。流是一组有序的数据序列，按方向分为：

- **输入流**：从数据源（文件、网络、内存等）读取数据到程序
- **输出流**：将程序中的数据写出到目标

### 2.2 字节流与字符流

#### 字节流（Byte Stream）

`InputStream` 和 `OutputStream` 是所有字节流的抽象基类，以 8 位字节为单位处理数据。

```java
// 文件复制 - 字节流方式
try (FileInputStream fis = new FileInputStream("source.txt");
     FileOutputStream fos = new FileOutputStream("dest.txt")) {
    byte[] buffer = new byte[8192];
    int bytesRead;
    while ((bytesRead = fis.read(buffer)) != -1) {
        fos.write(buffer, 0, bytesRead);
    }
} // try-with-resources 自动关闭
```

#### 字符流（Character Stream）

`Reader` 和 `Writer` 是字符流的抽象基类，以 16 位的 Unicode 字符为单位，自动处理编码转换。

```java
// 文件复制 - 字符流方式（指定编码）
try (BufferedReader reader = new BufferedReader(
         new InputStreamReader(new FileInputStream("source.txt"), StandardCharsets.UTF_8));
     BufferedWriter writer = new BufferedWriter(
         new OutputStreamWriter(new FileOutputStream("dest.txt"), StandardCharsets.UTF_8))) {
    String line;
    while ((line = reader.readLine()) != null) {
        writer.write(line);
        writer.newLine();
    }
}
```

### 2.3 装饰器模式（Decorator Pattern）

Java IO 体系最经典的设计就是**装饰器模式**。`InputStream` 作为抽象组件，`FileInputStream`、`ByteArrayInputStream` 等作为具体组件，而 `BufferedInputStream`、`DataInputStream`、`ObjectInputStream` 等作为装饰器，动态地为组件添加功能。

```java
// 装饰器链：给文件输入流加上缓冲 + 数据读取功能
DataInputStream dis = new DataInputStream(
    new BufferedInputStream(
        new FileInputStream("data.bin")));
double value = dis.readDouble();  // 直接读取基本类型
int count = dis.readInt();
```

常见的装饰器关系：

| 抽象组件        | 具体组件                      | 装饰器                                                 |
| --------------- | ----------------------------- | ------------------------------------------------------ |
| `InputStream`   | `FileInputStream`/`ByteArrayInputStream` | `BufferedInputStream`/`DataInputStream`/`ObjectInputStream` |
| `OutputStream`  | `FileOutputStream`            | `BufferedOutputStream`/`DataOutputStream`/`ObjectOutputStream` |
| `Reader`        | `FileReader`/`CharArrayReader` | `BufferedReader`/`InputStreamReader`                    |
| `Writer`        | `FileWriter`/`CharArrayWriter` | `BufferedWriter`/`OutputStreamWriter`                   |

### 2.4 BIO 的缺点

BIO 模型最根本的问题是**阻塞**：`read()` 和 `write()` 在没有数据可读或可写时会阻塞当前线程。面向连接的 Socket 编程中，每个连接都需要一个独立线程处理，当连接数增长时，线程数量激增，上下文切换和内存开销急剧上升，这就是**C10K 问题**的根源。

```java
// BIO Socket 服务端 - 一个连接一个线程
public class BioServer {
    public static void main(String[] args) throws IOException {
        ServerSocket serverSocket = new ServerSocket(8080);
        while (true) {
            Socket socket = serverSocket.accept(); // 阻塞等待连接
            new Thread(() -> handle(socket)).start(); // 每个连接新建线程
        }
    }
    private static void handle(Socket socket) {
        try (BufferedReader in = new BufferedReader(
                 new InputStreamReader(socket.getInputStream()));
             PrintWriter out = new PrintWriter(socket.getOutputStream(), true)) {
            String line;
            while ((line = in.readLine()) != null) { // 阻塞读取
                out.println("Echo: " + line);
            }
        } catch (IOException e) { e.printStackTrace(); }
    }
}
```

**线程池优化版**（伪异步 IO）可以通过线程池复用线程来缓解资源压力，但本质仍然是阻塞模型，无法从根本上解决问题。

## 三、NIO：非阻塞 I/O

### 3.1 概述

Java 1.4 引入 `java.nio` 包，带来了**非阻塞 I/O** 能力。核心三要素是 **Buffer**、**Channel** 和 **Selector**。

### 3.2 Buffer（缓冲区）

Buffer 是 NIO 的数据容器，本质是一块可以读写数据的内存块。所有数据都通过 Buffer 在 Channel 间传输。

核心属性：
- **capacity**：缓冲区容量，一旦确定不可改变
- **position**：当前位置，初始为 0
- **limit**：读写上限
- **mark**：标记位置，可 reset 回退

```java
// Buffer 的基础使用
ByteBuffer buffer = ByteBuffer.allocate(64); // 堆内存分配

// 写入数据
buffer.put("Hello NIO".getBytes(StandardCharsets.UTF_8));

// 切换为读模式
buffer.flip();

// 读取数据
byte[] dst = new byte[buffer.limit()];
buffer.get(dst);
System.out.println(new String(dst, StandardCharsets.UTF_8));

// 重置位置，重新读
buffer.rewind();

// 清空缓冲区（切换到写模式）
buffer.clear();
```

Buffer 的**状态流转图**：

```
写模式:  position → 写入位置, limit = capacity
         ↓ flip()
读模式:  position = 0, limit = 原写入位置
         ↓ clear() / compact()
写模式:  position = 0, limit = capacity
```

Buffer 的类型：
- `ByteBuffer` / `CharBuffer` / `ShortBuffer` / `IntBuffer` / `LongBuffer` / `FloatBuffer` / `DoubleBuffer`
- `MappedByteBuffer`（内存映射文件）

### 3.3 Channel（通道）

Channel 类似于 BIO 的流，但有两个关键区别：
1. **双向**：既可以读也可以写
2. **非阻塞**：可以设置非阻塞模式

```java
// 使用 FileChannel 复制文件（零拷贝方式）
try (FileChannel src = FileChannel.open(Paths.get("source.txt"), StandardOpenOption.READ);
     FileChannel dest = FileChannel.open(Paths.get("dest.txt"), 
             StandardOpenOption.WRITE, StandardOpenOption.CREATE)) {
    // 零拷贝：数据从内核空间直接传输到内核空间，无需经过用户空间
    long pos = 0;
    long count = src.size();
    src.transferTo(pos, count, dest);
}
```

`transferTo()` 和 `transferFrom()` 利用操作系统的 DMA 和 PageCache 实现**零拷贝**，避免数据在内核态和用户态之间来回拷贝，在大文件传输场景下性能提升显著。

常用的 Channel：
| Channel              | 用途                 | 是否可非阻塞 |
| -------------------- | -------------------- | ------------ |
| `FileChannel`        | 文件 IO              | ❌            |
| `SocketChannel`      | TCP Socket           | ✅            |
| `ServerSocketChannel`| 服务端 TCP Socket    | ✅            |
| `DatagramChannel`    | UDP Socket           | ✅            |

### 3.4 Selector（选择器）

Selector 是 NIO 多路复用的核心。它可以注册多个 Channel，通过单线程轮询就绪事件，实现**一个线程管理多个连接**。

```java
// NIO 多路复用服务端
public class NioServer {
    public static void main(String[] args) throws IOException {
        Selector selector = Selector.open();
        ServerSocketChannel ssc = ServerSocketChannel.open();
        ssc.configureBlocking(false);
        ssc.bind(new InetSocketAddress(8080));
        ssc.register(selector, SelectionKey.OP_ACCEPT);

        ByteBuffer buffer = ByteBuffer.allocate(8192);

        while (true) {
            int ready = selector.select(); // 阻塞，直到有事件就绪
            if (ready == 0) continue;

            Set<SelectionKey> selectedKeys = selector.selectedKeys();
            Iterator<SelectionKey> iter = selectedKeys.iterator();
            while (iter.hasNext()) {
                SelectionKey key = iter.next();
                iter.remove();

                if (key.isAcceptable()) {
                    // 接受新连接
                    ServerSocketChannel server = (ServerSocketChannel) key.channel();
                    SocketChannel sc = server.accept();
                    sc.configureBlocking(false);
                    sc.register(selector, SelectionKey.OP_READ);
                    System.out.println("新连接: " + sc.getRemoteAddress());
                } else if (key.isReadable()) {
                    // 读取数据
                    SocketChannel sc = (SocketChannel) key.channel();
                    buffer.clear();
                    int bytesRead = sc.read(buffer);
                    if (bytesRead == -1) {
                        sc.close(); // 连接关闭
                        continue;
                    }
                    buffer.flip();
                    byte[] data = new byte[buffer.limit()];
                    buffer.get(data);
                    System.out.println("收到: " + new String(data, StandardCharsets.UTF_8));

                    // 注册写事件，回显
                    buffer.rewind();
                    sc.write(buffer);
                }
            }
        }
    }
}
```

**事件类型**：`OP_ACCEPT`（接受连接）、`OP_CONNECT`（连接建立）、`OP_READ`（可读）、`OP_WRITE`（可写）。

### 3.5 直接缓冲区与堆缓冲区

| 特性               | HeapByteBuffer              | DirectByteBuffer                   |
| ------------------ | --------------------------- | ---------------------------------- |
| 内存位置           | JVM 堆内存                   | 系统物理内存（堆外）                 |
| 分配/释放成本       | 低                          | 高（需系统调用）                     |
| IO 操作性能        | 需要额外拷贝到堆外           | 零拷贝（直接从内核空间读写）          |
| 适用场景           | 小数据量、频繁创建           | 大数据量、长生命周期、网络 IO 频繁    |

```java
// 分配直接缓冲区
ByteBuffer directBuf = ByteBuffer.allocateDirect(64 * 1024);
// 判断是否直接缓冲区
boolean isDirect = buffer.isDirect();
```

## 四、NIO vs BIO 对比

| 维度         | BIO                 | NIO                             |
| ------------ | ------------------- | ------------------------------- |
| 数据单位     | 流（字节/字符）     | 块（Buffer）                     |
| 方向         | 单向                | 双向（Channel 可读可写）          |
| 阻塞性       | 阻塞                | 非阻塞/阻塞                      |
| 线程模型     | 一个连接一个线程    | 一个 Selector 管理多个连接        |
| 并发连接     | 受限于线程数        | 可支持上万连接                    |
| 零拷贝       | 不支持              | 支持（FileChannel.transferTo）    |
| 编程复杂度   | 简单                | 复杂（需处理事件分发和缓冲区管理）  |
| 适用场景     | 低并发、短连接      | 高并发、长连接、实时通信           |

## 五、AIO：异步 I/O

Java 7 引入了 AIO（NIO.2），提供真正的异步 I/O：发起 IO 操作后立即返回，操作完成时通过 Future 或 CompletionHandler 获取结果。

```java
// AIO 异步文件读取
Path path = Paths.get("data.txt");
AsynchronousFileChannel channel = AsynchronousFileChannel.open(path, StandardOpenOption.READ);
ByteBuffer buffer = ByteBuffer.allocate(1024);

channel.read(buffer, 0, buffer, new CompletionHandler<Integer, ByteBuffer>() {
    @Override
    public void completed(Integer result, ByteBuffer attachment) {
        attachment.flip();
        byte[] data = new byte[attachment.limit()];
        attachment.get(data);
        System.out.println("读取完成: " + new String(data, StandardCharsets.UTF_8));
    }

    @Override
    public void failed(Throwable exc, ByteBuffer attachment) {
        System.err.println("读取失败: " + exc.getMessage());
    }
});

// 不阻塞，继续执行其他工作
System.out.println("IO 操作已提交，继续执行...");
Thread.sleep(1000); // 等待异步完成
```

AIO 底层依赖操作系统真正的异步 IO 支持（如 Linux 的 AIO、Windows 的 IOCP），但在 Linux 上实现不够成熟，实际使用仍以 NIO 为主。

## 六、Reactor 模式

NIO 多路复用的本质就是 **Reactor 模式**——事件驱动的设计模式。

### 6.1 单线程 Reactor

所有 IO 事件（接受、读、写）都在**一个线程**中处理，适用于处理逻辑简单的场景。

```
                ┌─────────────────────┐
                │     Reactor         │
                │  (Selector 轮询)     │
                └─────┬──┬──┬──┬─────┘
                    │  │  │  │
                Accept Read Write ...
```

### 6.2 多线程 Reactor

将 IO 处理与业务处理分离，IO 线程负责事件分发，业务线程池负责实际处理。

```java
// 多线程 Reactor 伪代码示意
public class MultiThreadReactor implements Runnable {
    private final Selector selector;
    private final ExecutorService workerPool = Executors.newFixedThreadPool(4);

    public void run() {
        while (!Thread.interrupted()) {
            selector.select();
            Set<SelectionKey> keys = selector.selectedKeys();
            for (SelectionKey key : keys) {
                dispatch(key);
            }
        }
    }

    private void dispatch(SelectionKey key) {
        if (key.isAcceptable()) {
            handleAccept(key);
        } else if (key.isReadable()) {
            workerPool.submit(() -> handleRead(key)); // 业务处理交给线程池
        }
    }
}
```

### 6.3 主从 Reactor

**Main Reactor** 只负责接收连接，**Sub Reactor** 负责处理该连接的读写事件。Netty 使用的正是这种模式。

```
     Main Reactor（1个）
          │ Accept
     ┌────┴────┐
  SubReactor1 SubReactor2 SubReactor3 ...
  (Read/Write) (Read/Write) (Read/Write)
```

## 七、Netty 简介

Netty 是基于 NIO 封装的高性能网络应用框架，解决了原生 NIO 的诸多痛点：

### 7.1 原生 NIO 的问题
- API 复杂，容易出错
- 需要处理 `ByteBuffer` 的扩容、粘包拆包
- 多线程处理容易引入并发问题
- 空轮询 Bug（Linux epoll 的 `Selector.select()` 在特定情况下会立即返回 0）

### 7.2 Netty 的优势
- **简单 API**：基于 Handler/ChannelPipeline 的事件驱动模型
- **零拷贝**：CompositeByteBuf / FileRegion / 直接内存
- **内存池**：ByteBuf 池化，减少 GC 压力
- **高性能**：主从 Reactor 模型、无锁设计
- **协议支持**：HTTP/HTTP2/WebSocket/MQTT 等开箱即用

```java
// Netty Echo 服务端
public class NettyEchoServer {
    public static void main(String[] args) {
        EventLoopGroup bossGroup = new NioEventLoopGroup(1);   // Main Reactor
        EventLoopGroup workerGroup = new NioEventLoopGroup();  // Sub Reactor

        try {
            ServerBootstrap b = new ServerBootstrap();
            b.group(bossGroup, workerGroup)
             .channel(NioServerSocketChannel.class)
             .childHandler(new ChannelInitializer<SocketChannel>() {
                 @Override
                 protected void initChannel(SocketChannel ch) {
                     ch.pipeline().addLast(new EchoServerHandler());
                 }
             })
             .option(ChannelOption.SO_BACKLOG, 128)
             .childOption(ChannelOption.TCP_NODELAY, true);

            ChannelFuture f = b.bind(8080).sync();
            f.channel().closeFuture().sync();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            bossGroup.shutdownGracefully();
            workerGroup.shutdownGracefully();
        }
    }
}

@ChannelHandler.Sharable
class EchoServerHandler extends ChannelInboundHandlerAdapter {
    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        ByteBuf buf = (ByteBuf) msg;
        ctx.write(buf); // 自动处理释放
    }

    @Override
    public void channelReadComplete(ChannelHandlerContext ctx) {
        ctx.flush();
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        cause.printStackTrace();
        ctx.close();
    }
}
```

## 八、IO 模型对比总结

| 模型   | 版本   | 线程模型                    | 适用场景                     |
| ------ | ------ | --------------------------- | ---------------------------- |
| BIO    | 1.0+   | 一个连接一个线程            | 传统连接数少的应用            |
| 伪异步BIO | 1.4+ | 线程池 + 阻塞 IO            | 连接数不多的短连接场景         |
| NIO    | 1.4+   | Selector 单线程管理多连接    | 高并发、网关、RPC 框架        |
| AIO    | 7+     | 操作系统异步回调             | 文件 IO、数据库（Linux 支持有限） |
| Netty  | 框架   | 主从 Reactor 模型            | 高性能网络应用、微服务、中间件  |

## 九、实际运用建议

1. **文件 IO**：使用 NIO 的 `FileChannel.transferTo()` 实现零拷贝复制，性能远高于 BIO 的流复制。
2. **服务端网络 IO**：直接使用 Netty，而不是原生 NIO。Netty 封装了绝大多数边缘情况，且性能已优化到极致。
3. **小文件读取**：使用 `Files.readAllBytes()`（NIO 封装），简洁高效。
4. **内存敏感场景**：使用 `DirectByteBuffer` 减少 GC 压力，但注意堆外内存需要手动管理，最好配合 Netty 的 `PooledByteBufAllocator`。
5. **缓冲区大小**：网络 IO 的缓冲区建议 8KB~64KB，文件 IO 建议 32KB~256KB，过大或过小都会影响性能。

## 十、结语

从 BIO 到 NIO 再到 AIO，Java 的 IO 体系不断演进，但核心思想始终围绕 "如何更高效地在有限的硬件资源下处理更多的并发连接"。理解 BIO 的装饰器模式、NIO 的 Buffer-Channel-Selector 三件套和 Reactor 模式，就掌握了 Java 网络编程的精髓。在实际项目中，选择合适的 IO 模型需要综合考虑并发量、数据量、开发成本和运维复杂度。

---

> 文章作者：东哥
> 欢迎讨论 Java IO 相关技术问题，欢迎在评论区留言交流！
