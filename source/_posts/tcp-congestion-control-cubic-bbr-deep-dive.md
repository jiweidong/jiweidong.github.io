---
title: 【网络编程】TCP 拥塞控制深度解析：从慢启动、CUBIC 到 BBR 的演进
date: 2026-09-30 08:00:00
tags:
  - TCP
  - 网络编程
  - 拥塞控制
  - 性能优化
categories:
  - 网络编程
  - 系统设计
author: 东哥
---

# 【网络编程】TCP 拥塞控制深度解析：从慢启动、CUBIC 到 BBR 的演进

## 面试官：客户端和服务端网络都很好，为什么传输大文件还是慢？

很多人会回答"带宽不够"。但如果你真的抓过包，会发现更常见的情况是：**链路带宽明明还剩一大半，发送方的发送速率却上不去**。原因几乎总是同一个——TCP 的拥塞控制（Congestion Control）在"自我刹车"。

拥塞控制和流量控制经常被混淆，但它们是两件完全不同的事：

- **流量控制（Flow Control）**：解决"接收方处理不过来"的问题，靠接收窗口 `rwnd` 实现，是端到端的。
- **拥塞控制（Congestion Control）**：解决"网络中间链路处理不过来"的问题，靠拥塞窗口 `cwnd` 实现，是面向整个网络的。

真正的发送窗口是这两者的最小值：

```text
SendWindow = min(cwnd, rwnd)
```

流量控制在滑动窗口那篇文章里已经讲透了，本文专门啃拥塞控制：它在 Linux 内核里怎么实现、CUBIC 为什么能取代 Reno、为什么 Google 要重写一套 BBR，以及生产环境该怎么选。

## 一、先把四个核心概念钉死

### 1.1 拥塞窗口 cwnd

`cwnd` 是发送方自己维护的一个"猜测量"：我一次能在网络上放飞多少未确认的数据。它不写在 TCP 报文里，完全由发送方本地算法决定，是拥塞控制的核心状态变量。

### 1.2 四个经典阶段

| 阶段 | 触发条件 | 行为 | 直观理解 |
| --- | --- | --- | --- |
| 慢启动 Slow Start | 连接建立 / 超时重传 | cwnd 从 1 个 MSS 起，**每收到一个 ACK 加 1 MSS**（指数增长） | 试探网络容量，快速翻倍 |
| 拥塞避免 Congestion Avoidance | cwnd ≥ ssthresh | **每个 RTT 加 1 MSS**（线性增长） | 接近极限，小步试探 |
| 快速重传 Fast Retransmit | 收到 3 个重复 ACK | 立刻重传丢失段，不等超时 | 别等 RTO，太慢 |
| 快速恢复 Fast Recovery | 快速重传之后 | ssthresh = cwnd/2，cwnd = ssthresh + 3 MSS，之后进入拥塞避免 | 小幅回退，不回到 1 |

慢启动为什么叫"慢"？因为它起手只有 1 个 MSS，起点低所以"慢"；但它的增长是指数的，每个 RTT 翻一倍，实际提速非常暴力。以 1460 字节 MSS、RTT 50ms 计算：

```text
RTT 1:  1 MSS    →   1460 B
RTT 2:  2 MSS    →   2920 B
RTT 3:  4 MSS    →   5840 B
...
RTT 10: 512 MSS  →  747 KB/RTT  ≈ 14.9 MB/s
RTT 12: 2048 MSS → 2.99 MB/RTT  ≈ 59.8 MB/s
```

也就是说，慢启动只需要十几个 RTT（不到 1 秒）就能吃满千兆链路。**慢启动真正的代价不是"慢"，而是每次丢包后都要重新来一遍，以及它对短连接（HTTP 请求-响应）几乎全程生效。**

### 1.3 ssthresh 与 AIMD

`ssthresh`（slow start threshold）是慢启动和拥塞避免的分界点。初始值通常很大（Linux 中约等于 `tcp_max_initial_ssthresh` / 无限大，即一直慢启动直到丢包或到达 `tcp_max_ssthresh` 限制）。

Reno 时代总结出的黄金法则是 **AIMD（Additive Increase, Multiplicative Decrease）**：

- 加法增大：拥塞避免阶段每个 RTT 加 1 MSS；
- 乘法减小：检测到拥塞（丢包）时 cwnd 直接减半。

AIMD 的美妙之处在于**收敛性**：两条 AIMD 流共享瓶颈时，最终一定会收敛到公平的均分点。但它也有致命的工程缺陷，这正是 CUBIC 出现的理由。

### 1.4 拥塞信号：丢包 ≠ 拥塞

传统 TCP 把**丢包当作拥塞的唯一信号**。这个假设在 1988 年（Reno 诞生的年代）是成立的：当时链路是铜线/光纤，误码率极低，丢包几乎只可能来自路由器队列溢出。

但今天的网络早已不是这样：

- Wi-Fi、4G/5G 空口本身就有随机丢包（1%~5% 很常见）；
- 数据中心里，浅缓冲区交换机（如 100Gbps 交换机只有几百 KB 缓冲）会疯狂丢包；
- 长肥管道（LFN，长 RTT + 高带宽）下，ACK 到得晚，丢包时已经飞出去太多数据。

用丢包判断拥塞，等于**把误码也当成拥塞**，结果就是无缘无故降速。BBR 就是从根上否定这个假设。

## 二、Linux 的 cwnd 长什么样？

### 2.1 内核中 cwnd 的表示

Linux 里 cwnd 不是字节数，而是**以 MSS 为单位的整数**，存在 `struct tcp_sock` 中：

```c
struct tcp_sock {
    /* 拥塞控制状态 */
    u32 snd_cwnd;            /* 拥塞窗口，单位：MSS */
    u32 snd_cwnd_clamp;      /* cwnd 上限 */
    u32 snd_cwnd_cnt;        /* 拥塞避免阶段已累积的 ACK 数（用于每 RTT +1） */
    u32 snd_ssthresh;        /* 慢启动阈值 */
    u32 snd_cwnd_used;       /* 实际使用的窗口 */
    u8  snd_cwnd_stamp;      /* 上次 cwnd 更新的时间戳 */
    ...
};
```

`snd_cwnd` 乘以 MSS 才是"字节窗口"，再和 `rwnd` 取最小值，得到真实可发送量。这也解释了为什么 `tcp_wmem`、MSS、GSO/TSO 这些参数会间接影响吞吐——它们改变的是"MSS 换算成字节"的比例。

### 2.2 可用的拥塞控制算法

```bash
# 查看当前可用的算法
sysctl net.ipv4.tcp_available_congestion_control
# net.ipv4.tcp_available_congestion_control = reno cubic

# 查看当前默认算法
sysctl net.ipv4.tcp_congestion_control
# net.ipv4.tcp_congestion_control = cubic

# 查看某条连接的实时状态
ss -tin state established dst 10.0.0.5
```

`ss -tin` 输出的关键字段：

```text
cubic wscale:8,8 rto:204 rtt:0.5/0.2 ato:40 mss:1448
rcvmss:1448 advmss:1448 cwnd:120 ssthresh:56 bytes_acked:...
```

这里 `cwnd:120` 表示 120 个 MSS（约 170KB），`ssthresh:56` 说明已经丢过包，当前处于拥塞避免阶段。

### 2.3 常用内核参数

```bash
# 允许的最大 ssthresh（慢启动最多涨到多少，防止一步涨太多）
net.ipv4.tcp_max_ssthresh = 0        # 0 表示不限制（由 cwnd_clamp 控制）

# 初始化窗口（IW10，RFC 6928 建议 10 个 MSS，对短连接提升巨大）
net.ipv4.tcp_init_cwnd = 10

# 接收缓冲区（与 rwnd 相关，间接影响公平性）
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 队列相关：拥塞控制的"上游"
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
```

把 `tcp_init_cwnd` 从默认 10 改小是**反模式**，除非你明确知道自己在做什么。

## 三、Reno：第一代实用算法

Reno 是 1990 年 Jacobson 提出的版本，整个逻辑可以浓缩成下面这段伪代码：

```text
慢启动：
    cwnd = 1
    while 收到新 ACK:
        cwnd += 1 MSS
        if cwnd >= ssthresh: break

拥塞避免：
    while 收到新 ACK:
        cwnd_cnt++
        if cwnd_cnt >= cwnd:      # 累计收到 cwnd 个 ACK ≈ 一个 RTT
            cwnd += 1 MSS
            cwnd_cnt = 0

超时（RTO）:
    ssthresh = cwnd / 2
    cwnd = 1                      # 回到慢启动，惩罚极重

快速重传 + 快速恢复:
    ssthresh = cwnd / 2
    cwnd = ssthresh + 3
    # 每收到一个重复 ACK，cwnd += 1；收到新 ACK，cwnd = ssthresh
```

**Reno 的三个硬伤：**

1. **丢包即减半，减半即减半**——高速网络下 cwnd 动辄上千 MSS，一次减半就丢掉几百个 MSS 的发送能力，恢复需要几十个 RTT。
2. **恢复速度与 RTT 强相关**——长 RTT 链路上每个 RTT 只加 1 MSS，一条 RTT=200ms、带宽 10Gbps 的链路，从 1000 MSS 恢复到 2000 MSS 要 200 秒。
3. **公平性差**——多条流共享时，RTT 小的流抢占能力强，形成著名的 "RTT unfairness"。

## 四、CUBIC：用三次函数替代线性增长

Linux 2.6.19 起默认算法就是 CUBIC（由韩国 KAIST 的 Injong Rhee 提出），至今仍是全球互联网的事实标准。

### 4.1 核心思想

CUBIC 不再用"时间"驱动窗口增长，而是用**距离上次拥塞点的相对距离**来决定增长速度，窗口函数是一条三次曲线：

```text
W(t) = C * (t - K)^3 + W_max

其中：
  W_max = 上次发生拥塞时的窗口大小
  C     = 缩放常数（Linux 默认 0.4）
  K     = 从当前窗口增长到 W_max 所需的时间 = (W_max * β / C)^(1/3)
  β     = 乘法减小系数（Linux 默认 0.7，而 Reno 是 0.5）
```

这条曲线的形状是关键：

- **远离 W_max 时（t 远小于 K）**：三次项很平，增长慢，快速收敛到公平点；
- **接近 W_max 时**：曲线变陡，增长加速，快速夺回丢包前失去的带宽；
- **超过 W_max 后**：进入"探顶阶段"，增长明显变缓，小心翼翼试探新上限。

### 4.2 直观对比

| 特性 | Reno | CUBIC |
| --- | --- | --- |
| 增长模型 | 线性（每 RTT +1 MSS） | 三次函数 |
| 丢包后降幅 | ×0.5 | ×0.7（更温和） |
| 是否依赖 RTT | 强依赖 | **弱依赖**（窗口是绝对时间的函数） |
| 高速长距（LFN）表现 | 极差 | 优秀 |
| 公平性 | RTT 不公平 | 显著改善 |
| 是否依赖 TCP 友好性参数 | — | 有 TCP-friendly 区域兜底 |

**为什么 CUBIC 是 RTT 无关的**：因为 `W(t)` 只依赖于绝对时间 `t`，不依赖 ACK 到达的个数。RTT=10ms 的流和 RTT=200ms 的流，在相同时间内窗口增长的幅度是同一个数量级，这就抹平了"近的流占便宜"的问题。

### 4.3 Linux 中的 CUBIC 参数

```bash
# CUBIC 的关键参数（在 net/ipv4/tcp_cubic.c 中定义）
net.ipv4.tcp_cubic_alpha = 0      # 可调，一般不动
net.ipv4.tcp_fast_convergence = 1 # 快速收敛模式

# 低缓冲/高速场景下常调的参数
net.ipv4.tcp_slow_start_after_idle = 0
# 默认 1：空闲一段时间后 cwnd 重置回慢启动，对 HTTP keep-alive 是严重伤害
# 建议在内网/长连接服务上关掉
```

`tcp_slow_start_after_idle` 是**最容易被忽略的调优项**：它是为了照顾 2003 年的老网络，但对今天的 HTTP/2、gRPC 长连接、Kafka 长连接来说，空闲后重新慢启动会直接造成请求毛刺。

## 五、BBR：不再把丢包当拥塞信号

### 5.1 BBR 的出发点

Google 在 2016 年发布 BBR（Bottleneck Bandwidth and RTT），核心洞察是：

> 要让链路跑满，需要的不是"丢包才降速"，而是**找到链路的 BDP（Bandwidth-Delay Product，带宽时延积）**，并让"在途数据量 = BDP"。

```text
BDP = BtlBw × RTprop

BtlBw   : 瓶颈链路带宽（取一段时间内观测到的最大传输速率）
RTprop  : 最小 RTT（排队最少的往返时延）
报文在途量（inflight）目标 = BDP
```

关键区分：**BDP 是"管道容积"，缓冲队列（buffer）是额外的**。传统算法总是把队列填满（因为不填满就丢不了包，不丢包就不降速），结果就是永远在排队、永远高延迟——这就是著名的 **bufferbloat（缓冲区膨胀）**。

BBR 想要的是：撑满管道，但不填队列。

### 5.2 BBR 的四个状态机

BBR 通过周期性探测来估计 `BtlBw` 和 `RTprop`：

| 状态 | 作用 | 持续时间 |
| --- | --- | --- |
| Startup | 类似慢启动，但按 2/ln2 ≈ 2.885 倍增速（比指数更激进） | 直到带宽估计不再增长 |
| Drain | 把 Startup 阶段灌进队列的数据排空 | 约 1 个 RTT |
| ProbeBW | 周期性探测带宽上限（以 1.25 倍速率飙升一轮，再降回） | 稳态主循环，占绝大部分时间 |
| ProbeRTT | 每 10 秒降低 inflight 到 4 个包，持续 200ms，重测最小 RTT | 定期触发 |

伪代码感受一下核心逻辑：

```text
每收到一个 ACK:
    BtlBw = max(BtlBw_窗口内, 本次测得的 delivered_rate)
    RTprop = min(RTprop_窗口内10s, 本次测得的 RTT)

    if 处于 Startup:
        pacing_rate = 2.885 * BtlBw
        cwnd = 2 * BDP
    elif ProbeBW:
        pacing_rate = pacing_gain * BtlBw    # gain 在 1.25 / 0.75 间循环
    elif ProbeRTT:
        cwnd = 4 * MSS                       # 强制排空队列
    ...
```

### 5.3 BBR vs CUBIC 实测特征

| 维度 | CUBIC | BBR |
| --- | --- | --- |
| 拥塞信号 | 丢包 | 带宽 + 最小 RTT |
| 队列行为 | 倾向于填满缓冲 | 尽量不填队列 |
| 高丢包链路（3% 误码） | 吞吐暴跌 | 基本不受影响 |
| RTT 表现 | 随缓冲增大而升高 | 稳定在最小 RTT 附近 |
| 公平性 | 自身公平性好 | **对 CUBIC 有抢占性**（v1 的著名问题） |
| 部署 | 默认开启 | 需要显式开启，且需 `fq` 队列调度 |
| 内核要求 | 任何版本 | 4.9+（BBR v1），5.18+ 有 BBR v2/v3 |

BBR 开启了拥塞控制从"启发式丢包反应"到"主动带宽测量"的范式转变，但它并非银弹。BBR v1 与 CUBIC 流共存时抢带宽太凶，所以有 BBR v2（引入丢包率上限与 ECN 支持）。Google 内部大量流量跑 BBR，但**对 CDN 边缘、跨国传输效果最好，对数据中心内部（RTT < 1ms）收益有限**。

### 5.4 如何开启 BBR

```bash
# 1. 检查内核版本（需要 >= 4.9）
uname -r

# 2. 加载 BBR 模块
modprobe tcp_bbr

# 3. 验证可用
sysctl net.ipv4.tcp_available_congestion_control
# net.ipv4.tcp_available_congestion_control = reno cubic bbr

# 4. 设置默认算法
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 5. 把默认队列调度器改成 fq（BBR 依赖它做 pacing）
sysctl -w net.core.default_qdisc=fq

# 6. 持久化
cat >> /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system
```

注意 `net.core.default_qdisc=fq` 这一条：BBR 依赖 **pacing（匀速发送）** 来避免突发丢包，而 `fq`（Fair Queue）是内核里实现 pacing 的载体。没有 `fq`，BBR 退化成"用 cwnd 粗暴控制"，效果大打折扣。

## 六、Java 应用层怎么感知和配合

Java 应用无法直接操作 cwnd，但可以通过 socket 选项与参数影响它的"上游"。

### 6.1 查看连接的拥塞状态

```java
import java.net.Socket;
import java.net.SocketOption;

// JDK 标准库没有暴露 cwnd，但可以拿到缓冲区大小，间接判断 rwnd 配置是否生效
try (Socket socket = new Socket("10.0.0.5", 9090)) {
    System.out.println("SO_RCVBUF = " + socket.getReceiveBufferSize());
    System.out.println("SO_SNDBUF = " + socket.getSendBufferSize());
}
```

要真正看 cwnd，得用 `ss`、`tcp_info`（通过 JNI / `io.netty.channel.epoll` 的 `EpollTcpInfo`）：

```java
// Netty 的非公开但常用的方式：读取 EpollTcpInfo
EpollTcpInfo info = ((EpollSocketChannel) channel).tcpInfo();
System.out.println("cwnd=" + info.sndCwnd() + " rtt=" + info.rtt());
```

### 6.2 关键 socket 选项

```java
Socket socket = new Socket();
socket.setTcpNoDelay(true);      // 关闭 Nagle，避免小包被合并延迟（延迟敏感服务必开）
socket.setKeepAlive(true);       // 防连接被中间设备静默断开
socket.setReceiveBufferSize(1024 * 1024);
socket.setSendBufferSize(1024 * 1024);
```

`TCP_NODELAY` 与拥塞控制看似无关，实则关系密切：Nagle 算法会把小包攒起来合成大包，虽然提高带宽利用率，却会让 RTT 敏感的 RPC 出现几十毫秒的额外延迟；而开启 `TCP_NODELAY` 后小包变多，又会给拥塞控制带来更多"微突发"。**这两者需要一起调，不能只看一个。**

### 6.3 长连接空闲后的慢启动陷阱

典型症状：gRPC 服务在低峰期（连接空闲）之后，第一批请求耗时是平时的 3~5 倍。

原因就是 `tcp_slow_start_after_idle`：空闲超过 RTO（默认 200ms 以上）后 cwnd 被重置，而 HTTP/2 多路复用让连接生命周期很长，必然反复经历"空闲→慢启动"。

解决办法：

```bash
# 服务端/客户端都建议关闭
net.ipv4.tcp_slow_start_after_idle = 0
```

或者在应用层保持心跳，让连接不进入 idle 状态。

### 6.4 一次真实的排查案例

> **现象**：跨机房调用同一个服务，A 机房（RTT 0.5ms）P99 = 15ms，B 机房（RTT 30ms）P99 = 200ms，带宽均为 1Gbps，且 `ss` 显示无重传。

排查过程：

1. `ss -tin` 发现 B 机房连接 `cwnd:30 ssthresh:8`，A 机房 `cwnd:200`。B 机房明显处于慢启动后期；
2. `nstat -az TcpExtTCPLostRetransmit` 全为 0，说明本地没丢包；
3. 抓包发现 B 机房的中间设备在突发时会丢包（`TcpExtTCPTimeouts` > 0），触发 CUBIC 减窗；
4. 结论：**骨干链路上存在微突发丢弃**，RTT 越长，微突发导致的丢包越致命。

处置：B 机房链路切到 BBR + `fq`，P99 从 200ms 降到 40ms；同时把应用层单连接并发请求数（HTTP/2 `maxConcurrentStreams`）调小，降低微突发强度。

## 七、面试常见追问

**Q1：慢启动的"慢"到底慢在哪？**

命名来自 1988 年——相对于"一次性把接收窗口全部填满"的粗暴做法，从 1 个 MSS 起步显得谨慎，所以叫慢启动。它的增长其实是指数的。真正的痛点是**每次丢包后 RTO 会重置 cwnd 到 1**，以及短连接几乎全程都在慢启动。

**Q2：为什么快速恢复用 cwnd = ssthresh + 3？**

因为收到 3 个重复 ACK 说明已经有 3 个包离开了网络到达接收方，网络里少承载了 3 个包，所以可以额外放出 3 个 MSS 而不会加剧拥塞。这是"3 个重复 ACK"这个数字的由来。

**Q3：CUBIC 的 β 为什么是 0.7 而不是 0.5？**

0.5 太保守，在高速链路上恢复太慢。0.7 是实验得出的折中：既保持对标准 TCP 的友好性，又能更快恢复。CUBIC 还实现了"TCP-friendly 区域"，通过与 Reno 窗口对比来保证公平。

**Q4：BBR 一定比 CUBIC 快吗？**

不一定。BBR 的优势在高丢包、长 RTT、带宽受限链路；在数据中心内部（RTT 微秒级、几乎不丢包）收益很小，甚至因为 pacing 开销和公平性问题不如 CUBIC。另外 BBR v1 在浅缓冲交换机上会因排队时间上升而误判 RTT。

**Q5：拥塞控制和流量控制同时作用时，哪个先算？**

发送窗口 = `min(cwnd, rwnd)`，两者同时约束，没有先后。但更新时机不同：`rwnd` 由 ACK 携带的窗口字段更新，`cwnd` 由本地算法根据 ACK 到达事件更新。

**Q6：QUIC 的拥塞控制有什么不同？**

QUIC 把拥塞控制移到了用户态，默认 CUBIC（可插拔），同时天然支持 ECN、每包 ACK、无队头阻塞的流级重传。用户态实现意味着**算法升级不需要升级内核**，这是它相对 TCP 最大的工程优势。

## 八、生产调优清单

| 场景 | 建议 |
| --- | --- |
| 公网/跨国传输、CDN 回源 | BBR + `fq`，`tcp_slow_start_after_idle=0` |
| 高丢包无线接入 | BBR 优先（丢包不再误判为拥塞） |
| 数据中心内部 RPC | CUBIC 即可，重点调 `TCP_NODELAY`、缓冲区 |
| 长连接服务（gRPC/HTTP2） | 关 `tcp_slow_start_after_idle`，加心跳 |
| 大文件传输 | 调大 `tcp_rmem/tcp_wmem`，考虑多连接分片 |
| 判断问题 | `ss -tin` 看 cwnd/ssthresh，`nstat -az` 看丢包计数 |

一句话总结：**流量控制管接收方，拥塞控制管网络；Reno 用丢包反应，CUBIC 用三次函数主动逼近，BBR 用带宽和 RTT 直接测量 BDP。** 理解了这三代算法的演进动机，再看到"带宽没跑满"这类问题时，你就知道该去 `ss -tin` 里找答案了。
