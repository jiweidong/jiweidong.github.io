---
title: 【网络排查】tcpdump 与 Wireshark 抓包实战：Java 服务偶发超时、连接异常与丢包定位全流程
date: 2026-09-14 08:00:00
tags:
  - Java
  - 网络
  - tcpdump
  - 排障
categories:
  - Java
  - 运维
author: 东哥
---

# 【网络排查】tcpdump 与 Wireshark 抓包实战：Java 服务偶发超时、连接异常与丢包定位全流程

## 面试官：一个接口偶发 3 秒超时，应用日志里只有一条 `Read timed out`，你怎么查？

这是线上最常见也最折磨人的一类问题：**下游说是你的问题，你说是网络的问题，中间还隔着一个网关和一堆负载均衡。**应用日志只能告诉你「读超时了」，但：

- 是请求没发出去？
- 是对端没回？
- 是回了但半路丢了？
- 是 TCP 层在重传？
- 是连接被 RST 了？
- 还是应用层自己处理慢？

**这四个问题，只有抓包能回答。** 应用日志看到的是结果，抓包看到的是过程。

这篇讲 tcpdump 与 Wireshark 的完整实战方法，包含 10 条可以直接抄的抓包命令，以及 5 个真实排查场景。

---

## 一、先建立坐标系：Java 网络栈的四层可见性

排查网络问题，先明确「哪一层能看到什么」：

| 层级 | 观测手段 | 能看到 | 看不到 |
| --- | --- | --- | --- |
| 应用层 | 应用日志、Arthas trace | 请求/响应、业务耗时 | 是否真的发出、TCP 状态 |
| Socket 层 | `ss -ti`、`netstat -s` | 重传数、RTT、cwnd、发送队列 | 具体报文内容 |
| TCP/IP 层 | **tcpdump**、Wireshark | 每个报文、时序、重传、RST、窗口 | 加密内容（HTTPS） |
| 链路层 | `ip -s link`、`ethtool -S` | 网卡 drop/error、CRC 错误 | 上层协议 |

**排查顺序建议**：先 `ss -ti` 看有没有重传（一秒搞定），有重传再抓包定位具体报文，最后结合应用日志对齐时间线。

```bash
# 最高性价比的一条诊断命令：看连接的 TCP 内部状态
ss -tinp state established '( dport = :8080 or sport = :8080 )'
```

输出里的关键字段：

| 字段 | 含义 | 异常信号 |
| --- | --- | --- |
| `rtt:` | 平滑往返时延 | 突增到几百 ms |
| `rttvar:` | RTT 方差 | 方差大说明网络不稳定 |
| `retrans:` | **重传段数** | **> 0 就是丢包证据** |
| `cwnd:` | 拥塞窗口 | 突然缩小说明拥塞 |
| `ssthresh:` | 慢启动阈值 | 变小说明经历过丢包 |
| `unacked:` | 未确认字节数 | 持续 > 0 且不降 → 卡住 |
| `send` / `recv` 队列 | 内核发送/接收队列 | send-q 持续 > 0 → 对端接收慢 |

**`retrans` 大于 0，基本可以断定存在丢包**，接下来就该抓包了。

---

## 二、tcpdump 核心语法（一页速查）

```bash
tcpdump [选项] [过滤表达式]
```

### 2.1 必知选项

| 选项 | 作用 | 实战备注 |
| --- | --- | --- |
| `-i <if>` | 指定网卡 | `-i any` 抓所有网卡（虚拟化环境常用） |
| `-nn` | 不解析主机名和端口名 | **必加**，否则每行都做 DNS 反查，性能和可读性都差 |
| `-s 0` | 抓完整报文（默认 262144 字节） | 老版本默认 68 字节会截断，**建议显式加 `-s0`** |
| `-w file.pcap` | 写入文件 | 生产抓包**一定写文件**，不要直接刷屏 |
| `-r file.pcap` | 读文件 | 离线分析 |
| `-c N` | 抓 N 个包后退出 | 防止无限抓 |
| `-A` | ASCII 打印负载 | 看 HTTP 明文请求 |
| `-X` | hex + ASCII | 看二进制协议 |
| `-vvv` | 最详细输出 | 显示选项、序列号 |
| `-tttt` | 绝对时间（带日期） | **对齐应用日志必备** |
| `-l` | 行缓冲 | 配合 `| head` 用，避免缓冲卡住 |
| `-B <KB>` | 内核缓冲区大小 | 高流量时必须调大，否则内核丢包 |
| `-Z <user>` | 抓完降权 | 安全加固 |

### 2.2 过滤表达式

```bash
# 基础
host 10.0.0.5                    # 主机
src host 10.0.0.5                # 源
dst host 10.0.0.5                # 目的
net 10.0.0.0/24                  # 网段
port 8080                        # 端口
src port 8080 / dst port 8080    # 方向
portrange 8000-9000              # 端口范围

# 协议
tcp / udp / icmp / arp
tcp[tcpflags] & tcp-syn != 0     # 所有 SYN 包
tcp[tcpflags] & tcp-rst != 0     # 所有 RST 包
tcp[tcpflags] & (tcp-syn|tcp-fin) != 0   # 连接建立/关闭

# 组合：not / and / or，用括号要转义
host 10.0.0.5 and port 8080 and not port 22
'(tcp[tcpflags] & tcp-rst) != 0' and port 8080

# 长度过滤
greater 1000                     # 长度 > 1000 字节（大响应）
less 100                         # 小包（可能是 ACK/心跳）

# 负载内容匹配（明文协议才有用）
tcpdump -A -s0 'tcp port 8080' | grep -i "timeout"
```

---

## 三、10 条可直接抄的抓包命令

### 命令 1：抓某个下游服务的完整交互（最常用）

```bash
tcpdump -i any -nn -s0 -tttt \
  -w /tmp/downstream-$(date +%H%M%S).pcap \
  'host 10.0.0.100 and port 8080' &
# 复现问题后
kill %1
```

### 命令 2：只抓 TCP 异常（RST / FIN / 重传相关）

```bash
tcpdump -i any -nn -tttt \
  'host 10.0.0.100 and (tcp[tcpflags] & (tcp-rst|tcp-fin|tcp-syn) != 0)'
```

### 命令 3：抓 DNS 解析问题

```bash
tcpdump -i any -nn -tttt 'udp port 53 or tcp port 53'
```

`Java` 里 DNS 解析慢是超时的常见元凶（`InetAddress` 缓存默认永不刷新 / `networkaddress.cache.ttl`）。

### 命令 4：抓 ICMP（丢包/不可达）

```bash
tcpdump -i any -nn -tttt 'icmp'
```

`ICMP port unreachable` 说明对端没有监听；`ICMP frag needed` 说明 MTU 问题。

### 命令 5：高流量下先落盘再分析

```bash
# -B 64MB 内核缓冲，-c 限包数，写到文件
tcpdump -i eth0 -nn -s0 -B 65536 -c 200000 -w /tmp/traffic.pcap 'port 3306'
```

### 命令 6：只看 SYN，评估连接建立情况

```bash
tcpdump -i any -nn -tttt 'tcp[tcpflags] & tcp-syn != 0 and port 8080'
```

若看到大量 SYN 但没有对应 SYN-ACK → 对端未响应或 backlog 满（syn flood / `somaxconn` 太小）。
若看到 SYN 被重发多次 → **SYN 丢包或对端过载**。

### 命令 7：抓 MySQL 交互（定位连接池/DB 超时）

```bash
tcpdump -i any -nn -s0 -tttt -w /tmp/mysql.pcap 'port 3306'
```

### 命令 8：抓 HTTP 明文请求体

```bash
tcpdump -i any -nn -s0 -A -tttt 'port 8080 and host 10.0.0.100' | grep -A5 "HTTP/1.1"
```

### 命令 9：过滤出重传相关报文（配合 Wireshark 使用更佳）

```bash
# 抓全部，用 Wireshark 的 tcp.analysis.retransmission 过滤
tcpdump -i any -nn -s0 -w /tmp/all.pcap 'port 8080'
```

### 命令 10：多实例/容器环境抓指定进程

容器里没有 tcpdump 时，在**宿主机**抓容器 veth：

```bash
# 找容器 IP
docker inspect -f '{{.NetworkSettings.IPAddress}}' myapp
# 宿主机抓
tcpdump -i any -nn -s0 -w /tmp/container.pcap 'host 172.17.0.5 and port 8080'
```

---

## 四、Wireshark 实战：把 pcap 读懂

`tcpdump` 负责「抓」，`Wireshark` 负责「解读」。核心操作：

### 4.1 必用的显示过滤器

| 过滤器 | 作用 |
| --- | --- |
| `tcp.analysis.retransmission` | **重传**（超时重传） |
| `tcp.analysis.fast_retransmission` | 快速重传（3 个重复 ACK 触发） |
| `tcp.analysis.duplicate_ack` | 重复 ACK |
| `tcp.analysis.out_of_order` | 乱序 |
| `tcp.analysis.zero_window` | 零窗口（接收方缓冲满） |
| `tcp.analysis.window_update` | 窗口更新 |
| `tcp.analysis.lost_segment` | 疑似丢包 |
| `tcp.flags.reset == 1` | RST 包 |
| `tcp.flags.syn == 1 and tcp.flags.ack == 0` | SYN |
| `tcp.time_delta > 1` | 报文间隔 > 1 秒（**找空白期，超时排查神器**） |
| `http.response.code >= 500` | 5xx 响应 |
| `tcp.stream eq 5` | 某条连接的全部报文 |
| `ip.addr == 10.0.0.100 and tcp.port == 8080` | 组合条件 |

### 4.2 三个必用功能

1. **Follow → TCP Stream**：把一条连接的交互按顺序排开，发送/接收用不同颜色区分。**排查应用层协议问题第一选择。**
2. **Statistics → Flow Graph**：把一次连接画成时序图，一眼看出「谁在等谁」。超时问题看这里最快。
3. **Statistics → TCP Stream Graphs → Time Sequence (tcptrace)**：把吞吐和窗口变化画成图，看拥塞窗口收缩与重传。

### 4.3 关键列设置

Wireshark 默认列不够用，建议加：

- `tcp.time_delta`（与上包时间差）— **首要！** 超时排查就是找时间差大的地方
- `tcp.len`（TCP 负载长度）
- `tcp.stream`（流编号）
- `tcp.analysis.ack_rtt`（RTT）

---

## 五、五个真实排查场景

### 场景 1：偶发 3 秒读超时（TCP 重传导致）

**现象**：应用日志 `Read timed out after 3000ms`，概率约 0.1%。

**排查步骤**：

```bash
# 1. 看有没有重传
ss -tinp state established '( dport = :8080 )' | grep -E "retrans|rtt"
# 发现某条连接 retrans:5

# 2. 抓包
tcpdump -i any -nn -s0 -tttt -w /tmp/t.pcap 'port 8080'
```

Wireshark 打开，用 `tcp.analysis.retransmission` 过滤，看到：

```
No.  Time      Delta   Source        Dest       Info
100  1.000000  0.000   10.0.0.1:54321 10.0.0.100:8080  [PSH,ACK] Seq=1 Len=1400
101  2.003000  1.003   10.0.0.1:54321 10.0.0.100:8080  [TCP Retransmission] Seq=1 Len=1400
102  4.009000  2.006   10.0.0.1:54321 10.0.0.100:8080  [TCP Retransmission] Seq=1 Len=1400
103  8.021000  4.012   10.0.0.1:54321 10.0.0.100:8080  [TCP Retransmission] Seq=1 Len=1400
```

**读法**：1s、2s、4s 的重传间隔是 TCP 的**指数退避**（RTO doubling）。三次重传累计约 7 秒，应用 3 秒超时正好卡在这里。

**结论**：请求报文丢了，或响应丢了。查中间链路（LB、防火墙、网卡）的丢包计数：

```bash
ip -s link show eth0        # RX/TX dropped
ethtool -S eth0 | grep -i drop
netstat -s | grep -i retrans
```

**根因常见于**：网卡 ring buffer 溢出（`ethtool -g` 看 `rx_dropped`）、防火墙会话表满、LB 后端连接复用不当。

### 场景 2：连接建立慢（SYN 重传）

**现象**：新建连接耗时几百 ms 到 1s，但请求处理很快。

```bash
tcpdump -i any -nn -tttt 'tcp[tcpflags] & tcp-syn != 0 and port 8080'
```

输出：
```
1.000000 10.0.0.1.54321 > 10.0.0.100.8080: Flags [S], seq 100
2.001000 10.0.0.1.54321 > 10.0.0.100.8080: Flags [S], seq 100   ← SYN 重传，间隔 1s
2.050000 10.0.0.100.8080 > 10.0.0.1.54321: Flags [S.], ack 101
```

**结论**：SYN 或 SYN-ACK 丢了。SYN 重传的初始 RTO 是 1s（Linux `TCP_TIMEOUT_INIT`），所以**每次 SYN 丢失直接增加 1 秒延迟**。

**对策**：
- 服务端 backlog 满：调大 `net.core.somaxconn`、Tomcat `acceptCount`、`server.socket` 相关参数
- 客户端端口耗尽：看 `net.ipv4.ip_local_port_range` 与 `TIME_WAIT` 数量
- 中间设备丢包：查 LB 的 SYN 处理能力

### 场景 3：响应体大时慢（零窗口 / 带宽时延积）

**现象**：小响应正常，返回大 JSON（几 MB）时慢。

Wireshark 过滤 `tcp.analysis.zero_window`：

```
[TCP ZeroWindow] 10.0.0.100:8080 → 10.0.0.1:54321  Win=0 Len=0
[TCP Window Update] Win=64240
```

**读法**：接收方（应用）来不及读，socket 接收缓冲区满了，通告零窗口，发送方停止发送。这不是网络慢，是**应用消费慢**。

**对策**：
- 增大 `SO_RCVBUF`（Java 里 `-Dsun.net.inetaddr.ttl` 无关，要用 `Socket.setReceiveBufferSize` 或 `net.ipv4.tcp_rmem`）
- 应用侧异步消费、分页返回
- 检查是否有 `stream.read()` 处理慢（GC 停顿、JSON 解析慢）

### 场景 4：连接被 RST，报 `Connection reset by peer`

**现象**：偶发 `java.net.SocketException: Connection reset`。

```bash
tcpdump -i any -nn -tttt 'tcp[tcpflags] & tcp-rst != 0 and port 8080'
```

三种典型 RST 场景：

| 场景 | 报文特征 | 根因 |
| --- | --- | --- |
| 服务端进程崩溃/重启 | 收到请求后立即 RST | 应用退出，socket 关闭 |
| 连接被中间设备拆除 | 长时间空闲后 RST | LB/防火墙空闲超时（如 60s/300s） |
| 半开连接 | 一方已关闭，另一方还发数据 | 无 keepalive |

**对策**：
- 应用层心跳（Netty `IdleStateHandler`）或开启 TCP KeepAlive（`net.ipv4.tcp_keepalive_time`，默认 7200s 太长）
- 连接池配置**小于** LB 空闲超时（如 LB 60s，连接池 `maxIdleTime` 设 30s）
- HTTP 客户端重试策略要区分幂等性

### 场景 5：超时但网络完全正常（延迟 ACK + Nagle）

**现象**：内网调用偶发 40ms 延迟（不是超时，但延迟突兀）。

Wireshark 看 Flow Graph：

```
Client → Server: [PSH,ACK] Len=100    t=0.000
Server → Client: [ACK]     Len=0      t=0.040   ← 延迟 ACK，等了 40ms
Server → Client: [PSH,ACK] Len=200    t=0.041
```

**读法**：服务端应用先写响应头再写体，中间有停顿。客户端开了 Nagle 算法（等更多数据凑一个包），服务端开了延迟 ACK（等 40ms 或凑两个包才 ACK），**两者叠加产生 40ms 固定延迟**。

**对策**：`socket.setTcpNoDelay(true)`（Java 里即为 `TCP_NODELAY`），这是**所有 RPC/HTTP 客户端都应该开的**。Netty 默认开启，但手写的 `Socket` 默认是关闭的。

---

## 六、生产环境抓包的 8 条纪律

1. **一定用 `-w` 写文件，不要刷屏**。刷屏会拖慢终端甚至卡死，且无法回溯。
2. **一定加 `-c` 或 `timeout`**。抓包不设限，磁盘写满 = 服务挂掉。

   ```bash
   timeout 60 tcpdump -i any -nn -s0 -c 100000 -w /tmp/x.pcap 'port 8080'
   ```

3. **一定加 `-B` 调大缓冲区**。高流量（> 100Mbps）时默认缓冲会溢出，内核 `ps_drop` 会丢包，抓出来的包不可信：

   ```bash
   tcpdump -i any -nn -s0 -B 32768 -w /tmp/x.pcap
   # 结束后看「packets dropped by kernel」，必须为 0 才可信
   ```

4. **抓包范围尽量精确**。`host + port` 组合，避免 `-i any` 全量抓。
5. **敏感数据要脱敏**。HTTP 明文可能含密码、手机号、token。pcap 不要随便传阅、不要提交到 Git。
6. **HTTPS 抓包需要密钥**。Spring Boot 可用 `-Djavax.net.ssl.keyStore` + `SSLKEYLOGFILE`（Java 不支持 `SSLKEYLOGFILE`，实际做法是用 Wireshark 的 pre-master secret 或直接抓内网明文段）。**更实际的做法是在应用侧加 HTTP 层日志（如 Spring 的 `CommonsRequestLoggingFilter`）**。
7. **注意时钟同步**。抓包时间与日志时间对齐，需要各机器 NTP 同步。`tcpdump -tttt` 输出系统本地时间。
8. **抓完记得删**。pcap 文件可能几百 MB 到 GB 级，别留在生产机上。

---

## 七、根因速查表

| 症状 | 先看什么 | 常见根因 |
| --- | --- | --- |
| 偶发读超时 | `ss -ti` 的 retrans | 丢包 → 指数退避重传 |
| 新建连接慢 | SYN 重传 | backlog 满 / SYN 洪水 / LB 限速 |
| 大响应慢 | `tcp.analysis.zero_window` | 应用消费慢 / 接收缓冲小 |
| Connection reset | RST 包时间点 | 服务重启 / LB 空闲超时 / 半开连接 |
| 固定 40ms 延迟 | Flow Graph | Nagle + 延迟 ACK |
| 首次请求慢，之后正常 | DNS 端口 53 | DNS 解析超时 / 未缓存 |
| 大面积超时 | ICMP | 路由黑洞 / MTU 问题 |
| 只在高峰期出现 | 网卡 drop 计数 | ring buffer 溢出 / `somaxconn` 太小 |

---

## 八、面试追问连环炮

**Q1：`tcpdump` 抓包会丢包吗？怎么办？**
会。默认内核缓冲区（Linux 下约 2MB）在高流量下会溢出。用 `-B` 调大（如 64MB），并在结束时检查 `packets dropped by kernel`，为 0 才可信。必要时先按端口/主机过滤缩小范围。

**Q2：怎么判断是网络丢包还是应用慢？**
看 RTT 与重传。`ss -ti` 中 `retrans > 0` 且 `rtt` 正常 → 网络丢包；`retrans = 0` 但 `recv-q` 长时间堆积 → 应用消费慢；Wireshark 中若「请求到达时间 → 响应发出时间」间隔大，则是应用处理慢。

**Q3：TCP 重传的退避规律是什么？**
RTO 初始 1s（Linux `TCP_TIMEOUT_INIT`），每次重传翻倍：1s、2s、4s、8s…直到 `tcp_retries2`（默认 15 次，约 15 分钟）后放弃。所以**一次重传平均造成 3 秒延迟**，与应用 3s 超时高度吻合。

**Q4：`-i any` 和 `-i eth0` 有什么区别？**
`any` 用 `AF_PACKET` 抓所有网卡的包，能看到容器 veth、lo 等；但**无法进入混杂模式，且链路层头信息可能不完整**。生产定位具体网卡问题建议指定真实网卡。

**Q5：容器里怎么抓包？**
两种方式：容器内装 tcpdump（`nsenter -t <pid> -n` 或 `docker exec`）；或宿主机抓容器 veth（`tcpdump -i any host <容器IP>`）。K8s 环境可用 `kubectl debug` 临时容器或节点侧抓包。

**Q6：为什么先看 `ss -ti` 而不是直接抓包？**
抓包成本高（磁盘、CPU、隐私），而 `ss -ti` 一秒给出 RTT、重传、窗口、队列——**80% 的问题在这一步就能定性**。抓包用于确认和定位具体报文。

---

## 九、总结

- **排查顺序**：应用日志 → `ss -ti`（RTT/重传/队列）→ tcpdump 抓包 → Wireshark 分析 → 定位根因
- **tcpdump 三件套**：`-nn -s0 -w file`，加 `-B` 调缓冲、`-c` 限包数、`-tttt` 对齐时间
- **Wireshark 三个过滤器**：`tcp.analysis.retransmission`、`tcp.analysis.zero_window`、`tcp.time_delta > 1`
- **五个典型场景**：重传超时、SYN 重传、零窗口、RST、Nagle+延迟 ACK
- **两条纪律**：`-B` 调大缓冲并检查 kernel drop；pcap 含敏感数据要脱敏

网络问题不再靠「猜」和「甩锅」，抓包是把「偶发」变成「可复现证据」的唯一办法。
