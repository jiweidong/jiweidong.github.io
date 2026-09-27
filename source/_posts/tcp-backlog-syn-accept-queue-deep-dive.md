---
title: 【网络编程】TCP 半连接队列与全连接队列深度解析：SYN Flood、backlog 与 accept 阻塞
date: 2026-09-27 08:10:00
tags:
  - Java
  - 网络编程
  - TCP
  - 生产实战
categories:
  - Java
  - 网络编程
author: 东哥
---

# 【网络编程】TCP 半连接队列与全连接队列深度解析：SYN Flood、backlog 与 accept 阻塞

## 面试官：服务端 accept 慢，客户端会怎样？

这个问题看起来很基础，但能答透的人不多。常见的错误答案是「客户端会重试」。

正确的链条是这样的：

```
应用层 accept 不及时
  -> 全连接队列（accept queue）被填满
  -> 内核默认丢弃新完成握手的连接（或发 RST）
  -> 客户端认为自己已经 connect 成功，开始发数据
  -> 数据被丢弃，客户端重传，一段时间后才报 timeout
```

如果你是 Java 服务端开发者，`ServerSocket` 构造方法里的那个 `backlog` 参数，你已经写了无数遍，但未必真的知道它控制的是什么。

这篇文章把 TCP 三次握手过程中**两个队列**讲透：半连接队列、全连接队列，包括内核参数、溢出行为、观测手段、Java/Netty/Tomcat 的配置，以及一次真实线上事故的复盘。

---

## 一、三次握手与两个队列

### 1.1 内核数据结构

服务端在 `listen()` 之后，内核会为这个监听 socket 维护两个队列：

| 队列 | 内核名称 | 存放内容 | 状态 |
| --- | --- | --- | --- |
| 半连接队列 | SYN Queue（syn table / reqsk_queue） | 收到 SYN，已发 SYN+ACK，等待 ACK | SYN_RECV |
| 全连接队列 | Accept Queue（accept queue / icsk_accept_queue） | 三次握手完成，等待应用 accept | ESTABLISHED |

时序图：

```
Client                        Server(kernel)                Server(App)
  |                                |                             |
  |-------- SYN (seq=x) ---------->|  进入 SYN Queue             |
  |                                |  [SYN_RECV]                 |
  |<----- SYN+ACK (seq=y,ack=x+1)-|                             |
  |                                |                             |
  |-------- ACK (ack=y+1) -------->|  出 SYN Queue               |
  |                                |  进入 Accept Queue          |
  |                                |  [ESTABLISHED]              |
  |                                |                             |
  |                                |<-------- accept() ----------|
  |                                |--------- 返回新 fd -------->|
```

**关键：三次握手全程由内核完成，应用进程根本没参与。** 应用只在最后调 `accept()` 从全连接队列里取。

### 1.2 `listen(backlog)` 到底控制什么？

```c
int listen(int sockfd, int backlog);
```

历史上有两种语义：

- **BSD 语义**：`backlog` = 全连接队列长度上限（Linux 采用这个）；
- 部分早期实现：`backlog` = 半连接队列上限。

Linux 真实行为：

```
全连接队列实际上限 = min(backlog, net.core.somaxconn)
半连接队列实际上限 = 受 net.ipv4.tcp_max_syn_backlog 和 somaxconn 共同影响
```

所以你在 Java 里写：

```java
ServerSocket server = new ServerSocket(8080, 1024);
```

只是**上限请求**，最终由 `net.core.somaxconn` 兜底。很多机器的 `somaxconn` 默认是 128 或 4096，如果你传 4096 而 `somaxconn=128`，实际就是 128。

查看与调整：

```bash
# 查看
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_max_syn_backlog
sysctl net.ipv4.tcp_abort_on_overflow

# 调整（写 /etc/sysctl.d/99-tcp.conf 持久化）
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
```

---

## 二、半连接队列：SYN Queue

### 2.1 上限怎么算

Linux 中半连接队列的长度上限与 `net.ipv4.tcp_max_syn_backlog`、`somaxconn`、以及 `backlog` 都有关系，粗略公式：

```
max_qlen = min(tcp_max_syn_backlog, somaxconn, roundup_pow_of_two(backlog)) * 2   # 视内核版本
```

不同内核版本实现有差异（4.x 之后合并了部分逻辑），不要死记公式，**记「三个参数共同决定，取较小值」这个结论**。

### 2.2 半连接队列溢出的行为

当半连接队列满了，收到新的 SYN 时：

**默认（`tcp_syncookies=1`，RHEL/CentOS 默认开启）**：不丢弃，而是启用 **SYN Cookie**。

SYN Cookie 的原理非常巧妙：

1. 收到 SYN 时**不分配资源**（不保存连接状态）；
2. 把关键信息（客户端 IP、端口、时间戳、MSS）**编码进 SYN+ACK 的 sequence number** 里；
3. 收到客户端 ACK 时，从 `ack-1` 中解码验证，验证通过就直接建连。

因此：

```
tcp_syncookies=1  -> 半连接队列满了也能建连（无状态）
tcp_syncookies=0  -> 半连接队列满了直接丢弃 SYN
```

**SYN Cookie 是抵御 SYN Flood 的关键武器**，但它有两个副作用：

- 无法支持 TCP 选项的完整协商（如 Window Scaling、SACK 信息可能丢失），**吞吐会下降**；
- 只有在队列满时才启用，所以正常流量不受影响。

### 2.3 SYN Flood 与半连接队列

攻击者伪造大量源 IP 发 SYN，服务端回复 SYN+ACK 后进入 SYN_RECV，攻击者不回 ACK。于是：

- 半连接队列被快速填满；
- 正常用户的 SYN 被丢弃或降级到 SYN Cookie；
- 如果 SYN Cookie 也关了，服务直接不可用。

观测：

```bash
# 查看 SYN_RECV 状态的连接数
ss -s
netstat -n -p | grep SYN_RECV | wc -l
ss -n state syn-recv | wc -l

# 内核统计
netstat -s | grep -i -E "SYNs to LISTEN|listen queue|SYN flooding"
```

常见输出含义：

```
14640 SYNs to LISTEN sockets dropped        # 半连接队列溢出，SYN 被丢
1203 times the listen queue of a socket overflowed   # 全连接队列溢出
```

**这两个计数器是最关键的排查入口。**

---

## 三、全连接队列：Accept Queue

### 3.1 上限怎么算

```
全连接队列上限 = min(backlog, net.core.somaxconn)
```

注意 `somaxconn` 只影响全连接队列（在 Linux 上），`tcp_max_syn_backlog` 影响半连接队列。

### 3.2 溢出的两种行为

由 `net.ipv4.tcp_abort_on_overflow` 决定：

**`tcp_abort_on_overflow = 0`（默认，推荐）**：

```
队列满 -> 内核「无视」最后收到的 ACK（视为没收到）
       -> 客户端认为连接已建立，可以发数据
       -> 服务端因无对应连接记录，回 RST 或丢包
       -> 客户端重传 SYN+ACK（服务端会重试发 SYN+ACK）
       -> 最终客户端超时，报 connection timeout
```

这个行为很迷惑：**客户端 `connect()` 已经返回成功了**（因为收到过 SYN+ACK），但发第一条数据时才发现问题。

**`tcp_abort_on_overflow = 1`**：

```
队列满 -> 直接回 RST
       -> 客户端立刻收到 connection reset by peer
```

**生产建议是 0**。为什么？因为 1 会让「短暂溢出」升级为「客户端立即失败」，而 0 给了内核重试的窗口，短时抖动下客户端可能自愈（重传的 SYN 被重新处理）。

### 3.3 观测全连接队列

```bash
# Recv-Q 表示当前全连接队列里等待 accept 的连接数
# Send-Q 表示全连接队列的最大长度
ss -lnt

State   Recv-Q  Send-Q  Local Address:Port
LISTEN  129     128     0.0.0.0:8080
```

⚠️ **注意坑**：`ss -lnt` 里的 `Recv-Q`/`Send-Q` 语义**只在 LISTEN 状态时**才表示队列积压长度。

- LISTEN 状态：`Recv-Q` = 当前已完成三握手的连接数（等 accept）；`Send-Q` = 队列上限；
- 非 LISTEN 状态（ESTABLISHED）：`Recv-Q`/`Send-Q` 表示**接收/发送缓冲区中未被应用读取/发送的字节数**。

所以如果你看到：

```
LISTEN  129  128   -> 已经溢出（129 > 128）
LISTEN  128  128   -> 正好满了，再来的连接会被丢
```

这就是典型的「应用 accept 太慢」。

### 3.4 应用 accept 慢的常见原因

1. **单线程 accept**：accept 之后还要做一堆初始化（比如 SSL 握手、鉴权、DB 查询），导致取连接速度跟不上；
2. **GC 停顿**：STW 期间无法 accept；
3. **线程池满**：`new Thread` 或线程池拒绝，但 accept 仍在进行；
4. **Netty 的 bossGroup 线程被阻塞**：比如在 `ChannelInitializer` 里做了阻塞操作；
5. **`accept` 循环里做了同步 IO**。

---

## 四、Java 侧的配置与常见误区

### 4.1 `ServerSocket` backlog

```java
// backlog = 1024，但最终受 somaxconn 限制
try (ServerSocket server = new ServerSocket()) {
    server.bind(new InetSocketAddress(8080), 1024);
    while (true) {
        Socket socket = server.accept();   // 从全连接队列取
        handle(socket);
    }
}
```

**误区 1**：`backlog` 越大越好？
> 不是。队列越大，`accept` 不及时时积压越多，客户端以为自己连上了，实际排队时间变长，**超时更隐蔽**。合理值是「预计的瞬时并发建连数」。

**误区 2**：`backlog` 单方面调大就行？
> 不对。还要同步调 `net.core.somaxconn`，否则 `min()` 取到的是小的那个。

### 4.2 Tomcat

Tomcat 的 `acceptCount` 对应 backlog：

```yaml
server:
  tomcat:
    accept-count: 200          # 全连接队列长度（backlog）
    max-connections: 10000     # 最大连接数（NIO 下是已注册的连接数）
    threads:
      max: 200                 # 工作线程数
```

Tomcat 默认 `acceptCount=100`。**高并发短连接场景下，100 太小了**，建议 512~1024，同时确认 `somaxconn` 足够大。

Tomcat NIO 的 Accept 线程会持续 `accept`，把连接注册到 Poller，所以 Tomcat 一般不会出现 accept 队列积压。**但如果 `maxConnections` 达到上限，Tomcat 会停止 accept**：

```
达到 maxConnections -> Acceptor 线程 stopAccept()
                   -> 全连接队列开始堆积 -> 溢出丢连接
```

这是 Tomcat 全连接队列溢出的**最主要原因**。

### 4.3 Netty

```java
ServerBootstrap bootstrap = new ServerBootstrap();
bootstrap.group(bossGroup, workerGroup)
        .channel(NioServerSocketChannel.class)
        .option(ChannelOption.SO_BACKLOG, 1024)          // 对应 backlog
        .option(ChannelOption.SO_REUSEADDR, true)
        .childOption(ChannelOption.SO_KEEPALIVE, true)
        .childOption(ChannelOption.TCP_NODELAY, true)    // 禁用 Nagle，降低延迟
        .childOption(ChannelOption.SO_RCVBUF, 64 * 1024)
        .childOption(ChannelOption.SO_SNDBUF, 64 * 1024)
        .childHandler(new ChannelInitializer<SocketChannel>() {
            @Override
            protected void initChannel(SocketChannel ch) {
                ch.pipeline().addLast(new LengthFieldBasedFrameDecoder(1024 * 1024, 0, 4, 0, 4));
                ch.pipeline().addLast(new MyHandler());
            }
        });

bootstrap.bind(8080).sync();
```

**Netty 容易踩的坑**：

1. `SO_BACKLOG` 只对服务端监听 socket 有效，必须用 `option()` 而不是 `childOption()`；
2. `initChannel` 里不要做耗时操作（它是 boss 线程/worker 线程串行执行的），否则会拖慢 accept/register；
3. `bossGroup` 线程数默认是 `2 * CPU`，但 Netty 4.x 之后 boss 只需要 1 个线程，多余的会浪费。

### 4.4 加快 accept 的手段

```java
// 手段一：多线程 accept（用一个线程专门 accept，多个线程处理）
// 手段二：accept 后立刻转交给线程池，避免阻塞 accept 循环
public static void main(String[] args) throws IOException {
    ExecutorService workers = new ThreadPoolExecutor(8, 200, 60, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(1000), new ThreadPoolExecutor.CallerRunsPolicy());

    try (ServerSocket server = new ServerSocket()) {
        server.bind(new InetSocketAddress(8080), 1024);
        while (!Thread.currentThread().isInterrupted()) {
            Socket socket = server.accept();
            workers.execute(() -> handle(socket));   // 快速让出 accept 循环
        }
    }
}
```

⚠️ 注意 `CallerRunsPolicy`：队列满时会让 `accept` 线程自己跑任务，**这又阻塞了 accept**。极端情况下反而加剧问题。更稳的做法是自己实现降级（比如直接关闭新连接）。

---

## 五、从「连接超时」反推根因的完整方法论

线上出现「客户端连接超时」时，按这个顺序查：

### Step 1：确认是建连超时还是读写超时

```bash
# 客户端侧
timeout 3 bash -c "cat < /dev/null > /dev/tcp/10.0.0.1/8080" && echo OK || echo FAIL
```

- 建连超时（`Connection timed out`）：三次握手没完成 → 查两个队列；
- `Connection refused`：端口没监听，或 `tcp_abort_on_overflow=1` 且队列满；
- `Connection reset`：服务端拒绝，可能被防火墙 REJECT，或队列满发 RST。

### Step 2：看服务端两个队列

```bash
ss -lnt
# 关注 Recv-Q 是否接近或超过 Send-Q
```

### Step 3：看内核统计

```bash
netstat -s | grep -i -E "listen|overflow|syn|drop" | head -20
```

重点看：

```
<N> SYNs to LISTEN sockets dropped              # 半连接队列溢出
<N> times the listen queue of a socket overflowed  # 全连接队列溢出
```

```
netstat -s | grep -i "listen"
```

### Step 4：看 SYN_RECV 数量

```bash
ss -n state syn-recv | wc -l
```

- 数值很大且持续（比如 1000+）：可能是 SYN Flood，或半连接队列太小；
- 数值为 0 但客户端建连超时：可能是全连接队列问题。

### Step 5：抓包验证（终极手段）

```bash
tcpdump -i eth0 -nn 'tcp port 8080 and (tcp[tcpflags] & (tcp-syn) != 0)' -c 100

# 或者看完整握手
tcpdump -i eth0 -nn 'host 10.0.0.5 and port 8080'
```

Wireshark 里的判断技巧：

- 客户端发了 SYN，服务端**没有回 SYN+ACK** → 半连接队列满（或防火墙丢包）；
- 服务端回了 SYN+ACK，客户端 ACK 后**服务端又重传 SYN+ACK** → 全连接队列满（`abort_on_overflow=0`，内核重试）；
- 服务端回了 RST → 队列满且 `abort_on_overflow=1`。

**「服务端重复发 SYN+ACK」是全连接队列溢出的经典特征**，因为内核认为没收到客户端的 ACK。

---

## 六、一次真实事故复盘

### 6.1 现象

某次大促压测，客户端报「连接超时」，但服务端 CPU、内存、GC 全部正常，RT 也很低。

### 6.2 排查

```bash
$ ss -lnt
State   Recv-Q  Send-Q  Local Address:Port
LISTEN  1024    1024    0.0.0.0:8080       # 队列满！

$ netstat -s | grep -i "listen queue"
8542132 times the listen queue of a socket overflowed
```

队列**正好等于上限**，8.5 亿次溢出。

进一步看 Tomcat 日志：

```
[http-nio-8080-Acceptor] ... maxConnections reached
```

原来 `maxConnections` 设的是 8192，压测并发连接数到了 1 万+，Tomcat 主动停止 accept。

### 6.3 根因

业务用了 **HTTP 短连接**（每次请求新建连接），QPS 1 万 → 每秒 1 万次建连。而 Tomcat 的 `maxConnections=8192`，加上连接释放有延迟（`TIME_WAIT`），很快就达到上限。

### 6.4 治理

| 措施 | 具体做法 | 效果 |
| --- | --- | --- |
| 复用连接 | 客户端开启 HTTP Keep-Alive，连接池 `maxPerRoute=200` | 建连数下降 95% |
| 调大队列 | `accept-count: 1024` + `net.core.somaxconn=65535` | 溢出缓冲变大 |
| 提高上限 | `max-connections: 20000` | 不再触发 stopAccept |
| 优化内核 | `net.ipv4.tcp_tw_reuse=1`、`tcp_fin_timeout=15` | 加快端口回收 |
| 客户端重试 | 指数退避 + 抖动，避免重试风暴 | 削峰 |

治理后 `listen queue overflowed` 归零。

---

## 七、面试追问集

**Q1：`backlog` 到底对应哪个队列？**

> Linux 上对应**全连接队列**，且实际长度是 `min(backlog, net.core.somaxconn)`。半连接队列的长度由 `net.ipv4.tcp_max_syn_backlog` 和 `somaxconn` 共同影响。

**Q2：全连接队列满了，客户端会感知到吗？**

> **默认情况下不会立刻感知**。因为三次握手已经在内核完成，客户端 `connect()` 会返回成功。只有当它发数据、服务端回 RST，或内核重传 SYN+ACK 最终超时后，客户端才报错。所以「客户端 connect 成功但发数据失败」是队列溢出的典型症状。

**Q3：为什么 `tcp_abort_on_overflow` 推荐为 0？**

> 因为它给了内核重试的机会。队列短暂满的时候，内核会重发 SYN+ACK，客户端重传 ACK，队列有空间后就握上手了。设为 1 会立刻 RST，把短暂抖动放大成客户端故障。

**Q4：SYN Cookie 是怎么工作的？有什么代价？**

> 服务端不保存任何状态，把连接信息（客户端 IP/PORT、MSS、时间戳）编码进 SYN+ACK 的 seq 里，收到 ACK 时解码校验。代价是**无法完整协商 TCP 选项**（Window Scaling、SACK），吞吐会下降，所以只在队列满时启用。它是抵御 SYN Flood 的核心手段。

**Q5：`ss -lnt` 里的 Recv-Q 表示什么？和 ESTABLISHED 状态下一样吗？**

> 不一样。**LISTEN 状态下**，`Recv-Q` 是已完成握手但未被 accept 的连接数，`Send-Q` 是队列上限；**ESTABLISHED 状态下**，它们分别表示接收缓冲区和发送缓冲区中未被应用处理的字节数。这是最常见的误读点。

**Q6：Tomcat 的 `acceptCount` 和 `maxConnections` 什么关系？**

> `acceptCount` 是 backlog（全连接队列长度），`maxConnections` 是 Tomcat 允许同时持有的连接数上限（注意是「持有」，包括已 accept 但未处理完的）。**当连接数达到 `maxConnections`，Tomcat 会停止 accept**，于是全连接队列开始堆积 → 溢出 → 丢连接。所以调 `acceptCount` 只能缓冲，扩容 `maxConnections` 才是根治。

**Q7：Netty 里怎么避免 accept 队列积压？**

> 核心是**缩短 accept 到 register 的时间**：① `initChannel` 里不做阻塞操作；② 耗时初始化（鉴权、限流）异步化；③ `bossGroup` 线程数不要过多（1~2 个即可）；④ 合理设置 `SO_BACKLOG`，并确保 `somaxconn` 匹配；⑤ 监控 `ChannelGroup` 大小和 accept 速率。

**Q8：客户端大量 TIME_WAIT 怎么处理？**

> 客户端主动关闭才会产生 TIME_WAIT。三个方向：① 开启 `net.ipv4.tcp_tw_reuse=1`（注意仅对**主动发起连接**的方向有效，且需要 `tcp_timestamps=1`）；② 用连接池复用连接，减少建连；③ 让服务端先关闭（但要注意这会转移问题）。**不要用 `tcp_tw_recycle`，它在 NAT 环境下会导致丢包，已被内核移除。**

---

## 八、总结

一张图记住全部要点：

```
                  ┌─────────────── 内核 ───────────────┐
端口 8080          │                                    │
  → SYN ──────────▶ SYN Queue (半连接队列)              │
                    │   上限 ≈ min(tcp_max_syn_backlog, somaxconn) │
                    │   溢出：SYN Cookie / 丢弃 SYN      │
                    │            ↓ ACK                   │
                    │ Accept Queue (全连接队列)          │
                    │   上限 = min(backlog, somaxconn)   │
                    │   溢出：重传 SYN+ACK / RST         │
                  └───────────────┬────────────────────┘
                                  │ accept()
                         应用进程（Java/Netty/Tomcat）
```

排查口诀：

> **先看 `ss -lnt` 的 Recv-Q/Send-Q，再看 `netstat -s` 的两个 overflow 计数器，最后抓包看有没有重复 SYN+ACK。**

配好这三个参数，能解决 90% 的建连超时问题：

```
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_abort_on_overflow = 0
```
