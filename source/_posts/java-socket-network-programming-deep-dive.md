---
title: 【面试必备】Java Socket 网络编程深度解析：从 TCP 三次握手到 Socket 选项与生产实践
date: 2026-08-12 08:00:00
tags:
  - Java
  - 网络编程
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】Java Socket 网络编程深度解析：从 TCP 三次握手到 Socket 选项与生产实践

## 面试官：用过 Socket 吗？说说 TCP 建立连接的过程？

**候选人**：用过，TCP 建立连接需要三次握手……

面试官打断：**"三次握手具体发生在哪一层？你的 Java 代码里，哪个方法调用触发了第一次握手？"**

这个问题能问倒一大半人。很多人天天写 `new Socket(host, port)`，却说不清这行代码背后操作系统做了什么。今天我们从 Socket 编程的底层原理出发，把 TCP 连接管理、backlog 队列、Socket 选项这些"知道就加分"的知识点全部串起来。

---

## 一、Socket 是什么：操作系统给程序员的一扇门

Socket（套接字）是**传输层提供给应用层的编程接口**。在 Linux 中，它本质上是一个**文件描述符（fd）**，对 socket 的读写就是通过 read/write 系统调用完成的。

Java 的网络编程模型如下：

```
应用层（Java 代码）
   ↓ Socket API
传输层（TCP/UDP，由操作系统内核实现）
   ↓
网络层（IP）
   ↓
链路层（网卡驱动）
```

Java 的 `java.net.Socket` / `ServerSocket` 只是对操作系统 socket 接口的封装。Java 源码里，`Socket` 底层通过 `SocketImpl` 调用 JVM 本地方法（`java.net.PlainSocketImpl.socketConnect`），最终落到 `connect()` 系统调用。

## 二、TCP 三次握手与 Java 代码的对应关系

### 2.1 三次握手时序

```
Client                                Server
  |--- SYN (seq=x) -------------------->|  connect() 发起
  |<--- SYN+ACK (seq=y, ack=x+1) -------|  accept() 可返回
  |--- ACK (seq=x+1, ack=y+1) -------->|
  |                                    |
  |<======== 连接建立，可以传输数据 =======>|
```

### 2.2 每一步对应 Java 的哪个方法

| 阶段 | 操作系统行为 | Java 对应代码 |
|------|-------------|--------------|
| 第一次握手 | 客户端发 SYN | `new Socket(host, port)` / `socket.connect()` 触发 |
| 第二次握手 | 服务端回 SYN+ACK | 内核自动完成（半连接队列） |
| 第三次握手 | 客户端回 ACK | 内核自动完成，`connect()` 返回 |
| 连接就绪 | 服务端建立完整连接 | `serverSocket.accept()` 返回 |

**关键结论：**

1. `connect()` 返回时，三次握手**已经完成**（客户端视角），此时并不代表服务端应用层已经 `accept()`。
2. `accept()` 只是**从已完成连接队列（全连接队列）中取出一个连接**，握手早就在内核里完成了。
3. 所以真正的"握手"过程，服务端 Java 代码**一行都不用写**，全是内核干的。

### 2.3 backlog 队列：面试高频考点

服务端内核维护两个队列：

```
客户端 SYN 到达
   ↓
[半连接队列 syn queue]  ← 未完成握手
   ↓ 握手完成
[全连接队列 accept queue]  ← 等待 accept()
   ↓
accept() 取出
```

**backlog 参数**控制的是**全连接队列（accept queue）的长度**：

```java
ServerSocket serverSocket = new ServerSocket();
serverSocket.bind(new InetSocketAddress(8080), 512); // backlog = 512
```

**面试追问：backlog 设多大合适？**

- 太小：高并发下连接被内核直接丢弃，客户端报 `Connection refused`（因为队列满时内核发 RST）。
- 太大：队列积压大量已完成握手的连接，占用内存，且客户端等待 accept 的时间变长。
- 经验值：结合 QPS 与 accept 处理速度，一般 128~1024。注意 Linux 内核还有个上限 `somaxconn`（默认 4096，可调 `/proc/sys/net/core/somaxconn`），超过会被截断。

**JDK 9+ 还有一个细节**：`ServerSocket` 提供了 `getOption(SO_BACKLOG)` 可以读取实际生效的 backlog 值，方便排查。

## 三、Socket 核心 API 与读写模型

### 3.1 客户端完整示例

```java
public class SocketClient {
    public static void main(String[] args) throws Exception {
        // 1. 建立连接（触发三次握手）
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1", 8080), 3000); // 3s 连接超时

            // 2. 设置读写超时（防止阻塞导致线程挂死）
            socket.setSoTimeout(5000);

            // 3. 读写数据
            OutputStream out = socket.getOutputStream();
            out.write("hello server".getBytes(StandardCharsets.UTF_8));
            out.flush();

            InputStream in = socket.getInputStream();
            byte[] buf = new byte[1024];
            int len = in.read(buf);
            System.out.println("receive: " + new String(buf, 0, len));

            // 4. 关闭：通知对端 FIN，触发四次挥手
            socket.close();
        }
    }
}
```

### 3.2 服务端完整示例

```java
public class SocketServer {
    public static void main(String[] args) throws Exception {
        try (ServerSocket serverSocket = new ServerSocket(8080, 512)) {
            while (true) {
                // 从全连接队列取连接，没有则阻塞
                Socket socket = serverSocket.accept();
                // 每连接一线程（生产环境要用线程池！）
                new Thread(() -> handle(socket)).start();
            }
        }
    }

    private static void handle(Socket socket) {
        try (socket) {
            BufferedReader reader = new BufferedReader(
                new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            String line = reader.readLine();
            System.out.println("receive: " + line);

            PrintWriter writer = new PrintWriter(socket.getOutputStream(), true);
            writer.println("echo: " + line);
        } catch (IOException e) {
            e.printStackTrace();
        }
    }
}
```

### 3.3 四次挥手与 TIME_WAIT

```
主动关闭方                         被动关闭方
  |--- FIN ---------------->|
  |<--- ACK ----------------|  半关闭，被动方还能发数据
  |<--- FIN ----------------|
  |--- ACK ---------------->|
  |    进入 TIME_WAIT（2MSL） |
```

**面试追问：为什么主动关闭方要等 2MSL？**

1. **保证最后的 ACK 能到达对端**：如果 ACK 丢失，对端会重发 FIN，2MSL 内能收到并重发 ACK。
2. **让旧连接的报文在网络中消失**：防止新连接收到属于旧连接的延迟报文（端口复用场景）。

**生产启示**：大量短连接 + 主动关闭，会积累大量 TIME_WAIT 连接。调优手段：

- 服务端尽量**不主动关闭**（让客户端关），或使用连接池复用连接。
- 谨慎使用 `SO_REUSEADDR`（可缓解但非根治，还会引入报文串扰风险）。
- 减少 `net.ipv4.tcp_fin_timeout`（默认 60s）可加快 TIME_WAIT 回收，但不要盲目调小。

## 四、常用 Socket 选项：知道就是加分项

### 4.1 选项总表

| 选项 | 作用 | 典型值/场景 |
|------|------|------------|
| `SO_TIMEOUT` | 读超时，超时抛 `SocketTimeoutException` | 5000ms，防止线程卡死 |
| `SO_REUSEADDR` | 允许端口复用（TIME_WAIT 状态下也能 bind） | 服务端重启场景 |
| `TCP_NODELAY` | 禁用 Nagle 算法，小包立即发送 | 低延迟场景必须开 |
| `SO_LINGER` | 控制 close 时是否等待数据发完 | 默认立即返回 |
| `SO_KEEPALIVE` | 2 小时探测一次连接是否存活 | 默认关闭，不推荐依赖 |
| `SO_RCVBUF/SO_SNDBUF` | 收发缓冲区大小 | 大文件传输可调大 |
| `SO_BACKLOG` | 全连接队列长度 | 高并发 512+ |

### 4.2 Nagle 算法与 TCP_NODELAY（高频考点）

**Nagle 算法**：一个 TCP 连接上最多只有**一个小包（小于 MSS）在途**，后续小数据要等 ACK 或攒够大包才发。目的是减少网络中的小包数量，提高带宽利用率。

**但它和延迟敏感场景冲突**：

- 发一个字节 → 等 40ms（或等到 ACK）才能发下一个字节。
- 典型的"**粘包 + 延迟**"双杀。

**解决方案**：

```java
socket.setTcpNoDelay(true); // 关闭 Nagle，低延迟交互场景（IM、游戏）必备
```

**面试追问：Nagle 和延迟 ACK（Delayed ACK）相遇会发生什么？**

经典死锁场景：客户端开了 Nagle 发小包，服务端开启延迟 ACK（40ms 后才回 ACK），客户端等 ACK 才发第二个小包 → 双向等待，最坏 40ms 延迟。**Netty 等高性能框架默认关闭 Nagle**，原因就在这里。

### 4.3 SO_LINGER 的坑

```java
socket.setSoLinger(true, 0); // close() 时立即发 RST 而不是 FIN
```

- `SO_LINGER(true, 0)`：close 立即返回，同时发 **RST** 强制终止连接，**丢弃发送缓冲区未发数据**。会造成对端读到 "Connection reset"。
- 默认（false）：close 立即返回，内核后台尽力发送剩余数据，正常四次挥手。
- **生产建议**：非特殊需求不要设置 linger=0，会导致数据丢失且对端异常感知连接。

## 五、UDP Socket：无连接的数据报

```java
// 发送端
try (DatagramSocket socket = new DatagramSocket()) {
    byte[] data = "ping".getBytes(StandardCharsets.UTF_8);
    DatagramPacket packet = new DatagramPacket(data, data.length,
            new InetSocketAddress("127.0.0.1", 9090));
    socket.send(packet);
}

// 接收端
try (DatagramSocket socket = new DatagramSocket(9090)) {
    byte[] buf = new byte[1024];
    DatagramPacket packet = new DatagramPacket(buf, buf.length);
    socket.receive(packet); // 阻塞等待
    System.out.println(new String(packet.getData(), 0, packet.getLength()));
}
```

**UDP vs TCP 对比表：**

| 维度 | TCP | UDP |
|------|-----|-----|
| 连接 | 面向连接（三次握手） | 无连接 |
| 可靠性 | 可靠（重传、排序） | 不可靠（可能丢包乱序） |
| 有序性 | 保证 | 不保证 |
| 传输方式 | 字节流 | 数据报（有边界） |
| 头部开销 | 20 字节 | 8 字节 |
| 应用场景 | HTTP、MySQL、Kafka | DNS、音视频、游戏、日志采集 |

## 六、从 Socket 到生产级：连接池与线程模型演进

### 6.1 阻塞模型的瓶颈

"每连接一线程"模型的问题：

- 线程占用 1MB 左右的栈内存，10000 连接就要 10000 线程，直接 OOM。
- 大量线程阻塞在 `read()` 上，CPU 时间浪费在上下文切换。

### 6.2 演进路线（面试必答）

```
BIO（每连接一线程）
  → 线程池 + 长连接（缓解，但连接数仍受限）
  → NIO（Selector 多路复用，单线程管万连接）
  → Netty（Reactor 模型，事件驱动）
  → 虚拟线程（JDK 21，用轻量线程复活 BIO 写法）
```

**结论**：Socket API 本身不变，变的只是"谁来处理连接、如何调度 IO"。这也是为什么面试官总把 Socket 和 NIO/Netty 连着问——底层都是这套东西。

## 七、生产实践避坑清单

1. **必须设置 `connect` 和 `SO_TIMEOUT` 超时**，否则线程可能永久阻塞。
2. **读写用缓冲流 + 指定字符集**，别用默认编码（跨平台乱码）。
3. **连接用完要 close**，用 try-with-resources；否则连接泄漏 → fd 耗尽 → `Too many open files`。
4. **不要用 `SO_KEEPALIVE` 做心跳**：默认 2 小时才探测一次，业务心跳要自己实现（应用层 ping/pong）。
5. **明确消息边界**：TCP 是字节流，没有消息边界，必须自定义协议（长度前缀 / 分隔符 / JSON 换行），这就是 Netty 解决"粘包拆包"的原因。
6. **服务端别开线程裸处理**：用线程池限制并发，或用 NIO/Netty 重构。
7. **大文件传输调大收发缓冲区**，并配合 `sendfile` 零拷贝（Netty 的 FileRegion）减少用户态拷贝。

## 八、面试追问总结

| 追问 | 核心答案要点 |
|------|------------|
| 三次握手对应 Java 哪个方法？ | `connect()` 触发 SYN，握手由内核完成，`accept()` 只是取连接 |
| backlog 是什么？ | 全连接队列长度，满了会 RST，受 somaxconn 限制 |
| 为什么有 TIME_WAIT？ | 保证最后 ACK 到达 + 让旧报文消亡，等 2MSL |
| TCP_NODELAY 干嘛的？ | 关 Nagle，小包立发，低延迟必开 |
| 怎么处理粘包？ | 自定义协议定边界：长度前缀 / 分隔符 / 固定长度 |
| Socket 和 NIO 什么关系？ | Socket 是传输层接口，NIO 用 Selector 多路复用解决连接数瓶颈 |
| 连接过多会怎样？ | fd 耗尽、线程 OOM、TIME_WAIT 堆积，需要连接池 + 复用 |

---

**总结**：Socket 编程看着简单，背后是操作系统网络协议栈一整条知识链。面试时从 `new Socket()` 往下深挖，能聊到三次握手、backlog、Nagle、TIME_WAIT、粘包、NIO——每层都有考点。建议结合 Netty 一起复习，形成"API → 原理 → 框架落地"的完整知识闭环。
