---
title: 【Java 网络】Nagle 算法、延迟 ACK 与 TCP_NODELAY 深度解析：40ms 延迟抖动排查实录
date: 2026-10-29 08:10:00
tags:
  - Java
  - TCP
  - Netty
  - 网络调优
  - 性能排查
categories:
  - Java
author: 东哥
---

# 【Java 网络】Nagle 算法、延迟 ACK 与 TCP_NODELAY 深度解析：40ms 延迟抖动排查实录

## 前言

线上一个内部 RPC 网关，P99 延迟本该在 15ms 以内，监控却稳定地冒出 **40~45ms** 的尖刺。奇怪的是：

- 服务端日志显示业务处理耗时 2ms；
- CPU、GC、连接池全部正常；
- 尖刺不随机，而是"每隔一段时间来一批"，且同一时刻多个客户端一起中招；
- 换机器、换网卡没解决，重启进程会好一段时间，然后复发。

最后定位到根因：**请求被拆成两个小包发送，第二个包被 Nagle 算法扣住，等第一个包的 ACK；而服务端开了延迟 ACK，ACK 又要等 40ms 才发。** 两个算法各自"合理"，凑在一起就是经典的 **Nagle + Delayed ACK 死锁式延迟**。

这篇把这条链路讲透：两个算法分别在做什么、为什么会产生 40ms、Java/Netty 里怎么关、关掉之后有什么代价、以及其他容易混淆的 TCP 参数。

## 一、Nagle 算法：用延迟换带宽

### 1.1 它要解决的问题

1984 年的网络，链路带宽小、路由器缓冲区浅。如果应用每次 `write` 一个字节就发一个包，一个 1 字节的 payload 要配 40 字节的 TCP/IP 头（IPv4+TCP），头部开销 4000%，还会放大拥塞。

Nagle 的规则非常简洁（RFC 896）：

> 一个连接上，**最多只能有一个未被 ACK 的小包（小于 MSS）在途**。在收到 ACK 之前，后续的小数据必须攒起来，等攒够一个 MSS 或者等到 ACK 再发。

伪代码：

```
if (有未确认的小包在途 && 新数据 < MSS) {
    缓存起来
} else {
    立即发送
}
```

它把"多次小写"合并成"一次大写"，本质是 **客户端侧的发送端合并（coalescing）**。

### 1.2 它带来的副作用

对"请求-响应"式交互，尤其是 **写-写-读** 的模式，Nagle 会强行插入等待：

```
客户端：write(header)   -> 小包发出（在途 1 个）
客户端：write(body)     -> 小于 MSS 且有在途小包 -> 被扣住！
服务端：收到 header，但数据不完整，无法处理
服务端：等 body ... 等 body ...
```

如果服务端这时又开了延迟 ACK，它不会立刻回 ACK（它在等"有没有数据要回带"），于是客户端等 ACK 才能发 body，服务端等 body 才能回 ACK——**互相等待**，直到延迟 ACK 的定时器（通常 40ms，Linux 上最小 40ms、常见翻倍到 200ms）到期。

这就是 40ms 的来源。不是网络慢，是两端协议栈在"礼貌地互相等"。

## 二、延迟 ACK：用延迟换包头

### 2.1 规则

接收端收到数据后并不总是立刻回 ACK，而是：

1. 如果有数据要回给对端（双向流量），ACK 搭车（piggyback）发出去，零成本；
2. 如果没有，最多等一小段时间，希望在这段时间内有回程数据可以捎带 ACK；
3. 如果收到**两个**满 MSS 的段，立刻 ACK（quickack 模式）。

Linux 的实现里，延迟 ACK 的超时是 `TCP_DELACK_MIN` = 40ms（HZ=1000 时），并且在某些情况下会退避到 200ms。

### 2.2 为什么"两个段就立刻 ACK"

因为两个满段意味着对端在批量发送，此时延迟 ACK 会拖慢发送窗口推进，得不偿失。所以 Linux 用 `inet_delack_min` 与"收到第二个段"作为快速路径。

### 2.3 两个算法的"共振"

| 组合 | 结果 |
|---|---|
| Nagle 开 + 延迟 ACK 开 | ❌ 最差：小包互相等待，40ms 起 |
| Nagle 开 + 延迟 ACK 关 | 尚可：等一个 RTT 的 ACK，不再叠加 40ms |
| Nagle 关 + 延迟 ACK 开 | 尚可：小包随便发，ACK 延迟不影响发送 |
| Nagle 关 + 延迟 ACK 关 | ✅ 低延迟，但小包可能变多 |

**注意**：Nagle 是发送端行为，延迟 ACK 是接收端行为。你不能控制对端，但你能控制自己这一侧的 `TCP_NODELAY`，把等待链打断。

## 三、怎么确认是这个问题

### 3.1 抓包看时间差

```bash
tcpdump -i eth0 -nn -ttt 'host 10.0.3.21 and port 8080' -w /tmp/rpc.pcap
```

在 Wireshark 里看这一段（`-ttt` 让时间差变成相对值）：

```
0.000000  client -> server  [PSH, ACK] Seq=1:41   Len=40     # header
0.000180  server -> client  [ACK]  Seq=1 Ack=41              # 立刻 ACK? 不一定
0.040123  client -> server  [PSH, ACK] Seq=41:141 Len=100    # body 被扣了 40ms
0.040400  server -> client  [PSH, ACK] Len=512               # 响应
```

判读要点：

- 两个连续的小包之间差 ~40ms，且第二个包的发送时间 ≈ 第一个包 ACK 的时间 → 典型 Nagle；
- 服务端 ACK 与收到数据之间差 ~40ms → 延迟 ACK；
- 如果两个包间隔是 RTT 级别（0.2ms）而整体仍慢，那就不是 Nagle，去看应用层。

### 3.2 看 TCP 状态与统计

```bash
# 查看连接的拥塞窗口、RTT、重传
ss -tin 'dport = :8080'

# 关键字段
#  cwnd:10  ssthresh:...  rtt:0.21/0.10  retrans:0/0
#  => rtt 很小但业务慢，基本排除网络

# 重传/超时统计
netstat -s | grep -iE "retrans|timeout|delay"
```

### 3.3 Java 侧看 socket 选项

```java
// 打印当前连接是否开了 TCP_NODELAY
Socket socket = ...;
System.out.println("tcpNoDelay=" + socket.getTcpNoDelay()); // 默认 true
```

JDK 的 `Socket` 默认 `TCP_NODELAY = true`（自 JDK 1.4 起），`SocketChannel` 也是。**所以纯 Java NIO/Socket 场景，Nagle 一般是关的**。但下面这些地方会悄悄打开或绕过它。

## 四、Java 生态里的四个陷阱

### 4.1 Netty：`write` 与 `flush` 分离

Netty 的 `Channel.write()` 只是把消息放进 `ChannelOutboundBuffer`，**不保证立刻 flush**。真正的发送由 `flush()` 触发。如果你写：

```java
// ❌ 可能把两个逻辑包合并，也可能因为 flush 时机被延迟
ctx.write(header);
ctx.writeAndFlush(body);
```

`writeAndFlush` 会 flush 整个 outbound buffer，所以 header + body 会一起发——这其实是**好事**（合并成一次 writev）。但如果你写：

```java
ctx.write(header);
// ... 中间有别的逻辑，甚至跨线程 ...
ctx.writeAndFlush(body);
```

在两个 write 之间如果有 `EventLoop` 切换或异步等待，可能产生多次 syscall，配合 `TCP_NODELAY=false` 就会触发 Nagle。

正确配置：

```java
ServerBootstrap b = new ServerBootstrap();
b.childOption(ChannelOption.TCP_NODELAY, true)   // 关键：默认是 false！
 .childOption(ChannelOption.SO_KEEPALIVE, true)
 .childOption(ChannelOption.SO_BACKLOG, 1024)
 .childOption(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT);
```

⚠️ **Netty 的 `TCP_NODELAY` 默认值是 `false`**，这是很多人踩坑的地方。JDK Socket 默认 true，Netty 反而默认 false（为了批量吞吐）。做低延迟 RPC 必须显式打开。

### 4.2 HTTP 客户端：连接池复用与 `Connection: keep-alive`

`HttpURLConnection` 内部用 `keep-alive` 缓存连接，默认 `tcpNoDelay` 是 true。但如果你自己封装了 `Socket` 做私有协议：

```java
Socket s = new Socket();
s.setTcpNoDelay(true);   // 必须显式设置
s.connect(new InetSocketAddress(host, port), 1000);
```

Apache HttpClient 5：

```java
RequestConfig config = RequestConfig.custom()
        .setConnectTimeout(1000)
        .setResponseTimeout(Timeout.ofMilliseconds(3000))
        .build();
// 连接层 socket 配置
ConnectionConfig connConfig = ConnectionConfig.custom()
        .setBufferSize(8 * 1024)
        .build();
```

HttpClient 5 默认 `tcpNoDelay` 为 true，一般无需干预，但如果自定义了 `SocketFactory`，要自己设。

### 4.3 `write` 太小导致的"伪 Nagle"

即使关了 Nagle，如果你每次只 `write` 几十字节，仍然会有大量小包，带来：

- 网卡中断放大（每包一次中断，虽然有 GRO/NAPI 缓解）；
- 对端 softirq CPU 升高；
- 拥塞窗口推进慢（cwnd 按 MSS 增长）。

这时候正确的做法不是开 Nagle，而是 **应用层批量**：攒够 N 条或等 T 微秒再发。gRPC 的 `batching`、Kafka Producer 的 `linger.ms + batch.size` 都是这个思路。

### 4.4 `TCP_QUICKACK` 与"延迟 ACK 反悔"

Linux 在 `TCP_NODELAY` 打开后，仍可能在某些路径进入 quickack 模式再退出。应用层能做的很有限（`TCP_QUICKACK` 不是持久选项，设置后只对下一次生效）。实践上：

- 关闭 Nagle 已经能解决 99% 的 40ms 问题；
- 如果对端是"只收不回"的服务（如日志采集），可以在应用层周期性地发心跳，让 ACK 有搭车机会。

## 五、关掉 Nagle 的代价，以及什么时候不该关

`TCP_NODELAY=true` 之后，每次 `write` 都可能立即发包。风险：

| 场景 | 建议 | 原因 |
|---|---|---|
| 低延迟 RPC（gRPC、Dubbo、自研协议） | 开 | 请求-响应模式，延迟敏感 |
| 交互式终端 / SSH / 游戏 | 开 | 小包频繁，40ms 体感明显 |
| 大文件传输 / 日志批量上报 | 可关 | 应用层已批量，让 Nagle 再兜一层无妨 |
| 高频小写但无批量的老代码 | **先改应用层批量**，再开 | 否则小包风暴 |
| 移动端弱网 | 谨慎 | 小包会放大重传与耗电 |

一个更有用的判断标准：**你的写入模式是"一次请求一条消息"还是"持续小片段流"**。前者开 NODELAY + 应用层合并；后者（如实时音视频、终端输出）开 NODELAY，接受小包。

## 六、把配置做成可观测的

很多人改完 `TCP_NODELAY` 就结束了，但没有监控就无法证明有效。建议加两个指标：

```java
@Component
public class TcpOptionReporter {

    private final MeterRegistry registry;

    public TcpOptionReporter(MeterRegistry registry) {
        this.registry = registry;
    }

    /** 在连接建立后上报真实生效的 socket 选项 */
    public void report(String target, Socket socket) {
        try {
            registry.gauge("tcp.nodelay", Tags.of("target", target),
                    socket.getTcpNoDelay() ? 1 : 0);
            registry.gauge("tcp.sendbuf", Tags.of("target", target),
                    socket.getSendBufferSize());
        } catch (SocketException e) {
            // 连接已关闭，忽略
        }
    }
}
```

再配合客户端的"分段耗时"打点（DNS / connect / TLS / write / first-byte / total），一旦 write→first-byte 的差值出现 40ms 台阶，就能立刻定位到协议栈而不是业务代码。

## 七、面试常见追问

**Q1：Nagle 算法解决了什么问题？为什么现在还要讨论它？**
解决了"大量小包导致头部开销爆炸"的问题，提升带宽利用率。现在讨论它是因为低延迟场景（RPC、实时交互）下，它引入的等待成本远大于带宽收益，所以主流框架都默认或建议关闭。

**Q2：关闭 Nagle 就能保证低延迟吗？**
不能。它只消除了"发送端等 ACK"的等待。还能叠加的延迟源包括：延迟 ACK、拥塞控制（初始 cwnd 小）、TLS 握手、DNS、连接池排队、GC 停顿、线程池满。定位要按"分段耗时"逐段排除。

**Q3：为什么是 40ms 而不是别的数？**
Linux 的 `TCP_DELACK_MIN` 是 40ms（HZ=1000 时 40 个 tick），这是延迟 ACK 的最小等待时间。某些内核/场景下会退避到 200ms（`TCP_DELACK_MAX`）。所以看到 40ms 或 200ms 的台阶，优先怀疑延迟 ACK。

**Q4：HTTP/2 多路复用下还会有这个问题吗？**
会，但概率低。HTTP/2 把多个请求复用到一条连接，帧通常会被合并写入，且主流实现（Netty、nghttp2）都开 `TCP_NODELAY`。但如果你在 HTTP/2 之上自己做了"先发 HEADERS 帧、等一会儿再发 DATA 帧"的逻辑，仍可能踩到。

**Q5：`SO_KEEPALIVE` 和 Nagle 有关系吗？**
没有。`SO_KEEPALIVE` 是探测死连接（默认 2 小时才发第一个探测包，需要配合 `TCP_KEEPIDLE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT` 才有实用价值）；Nagle 是发送合并。两者常一起出现在 `ChannelOption` 里，但解决的是完全不同的问题。

## 八、一张"延迟归因"清单

| 观测到的特征 | 优先怀疑 | 验证方式 |
|---|---|---|
| 固定 40ms / 200ms 台阶 | 延迟 ACK + Nagle | tcpdump 看两包间隔 |
| 固定 ~1 个 RTT 的台阶 | 网络 RTT / 跨可用区 | `ping`、`ss -ti` 看 rtt |
| 台阶随并发升高 | 连接池 / 线程池排队 | 池指标 + 线程 dump |
| 台阶随流量升高且伴随重传 | 拥塞 / 丢包 | `netstat -s`、`tcpretrans` |
| 台阶与 GC 时间对齐 | STW | GC 日志 + JFR |
| 台阶只在首次请求 | DNS / TLS / 类加载 | 分段耗时打点 |

## 九、总结

1. **40ms 尖刺的经典根因是 Nagle 与延迟 ACK 的共振**，两者单独看都"合理"，组合起来就是互相等待。
2. **Netty 的 `TCP_NODELAY` 默认 false**，低延迟场景必须显式打开；JDK Socket 默认 true，别搞反。
3. **关 Nagle 只解决一半问题**，另一半在应用层的批量策略：要么合并成大包，要么接受小包并优化下游。
4. **用分段耗时 + tcpdump 归因**，不要靠猜。看到 40ms 台阶先抓包，比改十个参数都有效。

网络问题最怕"看起来像业务慢"。把协议栈的这几个默认行为搞清楚，很多玄学延迟会立刻变成确定性结论。
