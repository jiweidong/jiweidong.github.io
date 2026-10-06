---
title: 【网络排查】TIME_WAIT 与 CLOSE_WAIT 深度解析：连接堆积定位、内核参数与 Java 客户端治理
date: 2026-10-06 08:00:00
tags:
  - Java
  - 网络编程
  - TCP
  - 线上排查
categories:
  - Java
  - 网络与排查
author: 东哥
---

# 【网络排查】TIME_WAIT 与 CLOSE_WAIT 深度解析：连接堆积定位、内核参数与 Java 客户端治理

## 面试官：说说 TIME_WAIT 和 CLOSE_WAIT 的区别？

这是网络方向面试的保留曲目。很多人能背出"主动关闭方进入 TIME_WAIT，被动关闭方在收到 FIN 后进入 CLOSE_WAIT"，但一追问"线上 5 万台 CLOSE_WAIT 说明什么"，就答不上来了。

这两个状态看着像双胞胎，本质却完全不同：

- **TIME_WAIT 是协议规定必须存在的正常状态**，是内核行为，属于"设计使然"；
- **CLOSE_WAIT 是应用没把连接关干净**，是代码 bug，属于"人祸"。

一句话总结：**TIME_WAIT 多，多数要调内核；CLOSE_WAIT 多，一定要改代码。**

---

## 一、先把 TCP 状态机摊开

要讲清楚这两个状态，必须回到 TCP 的四次挥手：

| 步骤 | 主动关闭方（Client） | 被动关闭方（Server） |
| --- | --- | --- |
| ① | 发送 FIN，进入 `FIN_WAIT_1` | 收到 FIN，回 ACK，进入 `CLOSE_WAIT` |
| ② | 收到 ACK，进入 `FIN_WAIT_2` | 应用调用 `close()`，发送 FIN，进入 `LAST_ACK` |
| ③ | 收到 FIN，回 ACK，进入 `TIME_WAIT` | 收到 ACK，连接彻底关闭 |
| ④ | 等待 2MSL 后进入 `CLOSED` | — |

关键点：**CLOSE_WAIT 出现在"收到对方的 FIN、但自己还没调用 close()"的时间窗口里**。这个窗口理论上极短，如果它长期大量存在，说明应用层压根没关连接。

而 TIME_WAIT 只在**主动关闭的一方**出现，且会持续 `2 × MSL`（Linux 默认 MSL=60s，即 60 秒）。

### 为什么需要 TIME_WAIT？

1. **保证最后一个 ACK 能到达对端**。如果这个 ACK 丢了，对端会重传 FIN。若本端已经 CLOSED，收到 FIN 只能回 RST，对端就会异常。有了 TIME_WAIT，本端还能重发 ACK。
2. **让本次连接的老报文在网络中自然消亡**。否则同一四元组（源 IP、源端口、目的 IP、目的端口）的新连接可能收到上一轮的迟到报文，导致数据错乱。

所以 TIME_WAIT 不是"问题"，是"保护"。真正的问题只有一个：**端口被占满，无法发起新连接**。

---

## 二、TIME_WAIT 堆积的定位

先看现状：

```bash
# 统计各状态连接数
ss -ant | awk '{print $1}' | sort | uniq -c | sort -rn

# 单独看 TIME_WAIT 有多少
ss -ant state time-wait | wc -l

# 按"对端 IP:端口"聚合，找出被打爆的对端
ss -ant state time-wait | awk '{print $5}' | sort | uniq -c | sort -rn | head
```

判断标准（单机经验值）：

| 指标 | 健康 | 需要关注 | 危险 |
| --- | --- | --- | --- |
| TIME_WAIT 数量 | < 1 万 | 1 万 ~ 2.8 万 | > 2.8 万（本地端口耗尽） |
| TIME_WAIT / 总连接 | < 30% | 30% ~ 60% | > 60% |
| CLOSE_WAIT 数量 | 接近 0 | 数十~数百 | 上千或持续增长 |

> 本地端口范围默认 `net.ipv4.ip_local_port_range = 32768 60999`，约 2.8 万个。如果 TIME_WAIT 全部集中在连同一个后端，端口很快耗尽，报错通常是 `Cannot assign requested address`。

### 根因通常是这几类

1. **短连接 + 高 QPS**：每次请求新建连接，关闭后必然产生 TIME_WAIT。
2. **HTTP 客户端没复用连接**：`HttpURLConnection` 默认不使用 keep-alive；`Connection: close`。
3. **客户端主动关闭**：谁先 close 谁 TIME_WAIT，这在反向代理场景很常见（Nginx 代理后端时，若后端先关，Nginx 侧就 TIME_WAIT）。

### 治理手段（按优先级）

| 手段 | 参数 / 做法 | 说明 |
| --- | --- | --- |
| 连接复用 | 启用 keep-alive、连接池 | **首选**，从源头减少关闭次数 |
| 让对端先关 | 由服务端设置 `Connection: close` 或超时更短 | 把 TIME_WAIT 转移到对端 |
| 复用 TIME_WAIT | `net.ipv4.tcp_tw_reuse = 1` | 仅对**出站**连接有效，且需要 `tcp_timestamps=1` |
| 扩大端口范围 | `net.ipv4.ip_local_port_range = 10000 65535` | 治标 |
| 增加可用四元组 | 多绑定几个源 IP（多网卡/多 VIP） | 治本，本质是扩四元组空间 |

**注意：`net.ipv4.tcp_tw_recycle` 在 Linux 4.12 后已被移除**，且开启它会导致 NAT 环境下大量连接被丢弃，现在不要再用。很多老文章还在推荐它，属于过时知识。

```bash
# 查看当前值
sysctl net.ipv4.tcp_tw_reuse net.ipv4.tcp_max_tw_buckets
```

---

## 三、CLOSE_WAIT 堆积：一定是代码问题

CLOSE_WAIT 的语义是"我已经收到你的 FIN，但还没轮到我 close"。它堆积只有两种可能：

1. **应用没有调用 `close()`**（忘了关流、忘了关连接）；
2. **应用在 `close()` 之前被阻塞了**（比如线程池满、下游 hang 住，导致处理线程拿不到）。

### 经典事故：`HttpURLConnection` 没读完响应流

```java
// ❌ 错误示范：只读状态码，不读 body，也不 disconnect
public String badCall(String url) throws IOException {
    HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
    conn.setRequestMethod("GET");
    int code = conn.getResponseCode();
    return String.valueOf(code);   // 连接永远不会被释放！
}
```

很多人以为 `getResponseCode()` 之后就完事了。实际上，**只要响应体没被读完，底层 socket 就不会被归还/关闭**，连接一直挂在 CLOSE_WAIT，直到 GC 或进程退出。

正确写法：

```java
// ✅ 正确：try-with-resources 读干净 + finally disconnect
public String goodCall(String url) throws IOException {
    HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
    try {
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(2000);
        conn.setReadTimeout(3000);
        try (InputStream in = conn.getResponseCode() >= 400
                ? conn.getErrorStream() : conn.getInputStream()) {
            if (in != null) {
                // 必须读干净（或至少读到 -1）
                while (in.read(new byte[8192]) != -1) { /* drain */ }
            }
        }
        return "ok";
    } finally {
        conn.disconnect();   // 关键：释放底层连接
    }
}
```

### 其它常见泄漏点

- `try { ... } finally { }` 里没有关 `InputStream` / `Socket` / `Channel`；
- 使用 JDBC 时 `ResultSet` / `Statement` / `Connection` 未关闭（用 try-with-resources 或连接池）；
- Netty 中 `ChannelHandlerContext` 没 `close()`，或业务线程抛异常后没走到 `close`；
- Nginx 等代理场景下，后端超时时间 > 前端，导致代理先关、后端还在处理。

### 排查命令

```bash
# 1) 找出 CLOSE_WAIT 最多的本端端口
ss -ant state close-wait | awk '{print $4}' | sort | uniq -c | sort -rn | head

# 2) 找到持有该端口的进程
ss -antp state close-wait | grep ':8080'

# 3) 抓线程栈，看卡在哪
jstack <pid> > /tmp/stack.txt
grep -A 30 "http-" /tmp/stack.txt
```

如果 `jstack` 显示线程卡在 `socketRead0`、`read`、`park`，那基本就是"下游没响应 + 线程池被占满"的组合拳，最终表现为 CLOSE_WAIT 累积。

---

## 四、Java 客户端的最佳实践清单

1. **永远用连接池**：Apache HttpClient 5 的 `PoolingHttpClientConnectionManager`、OkHttp 的 `ConnectionPool`、Spring 的 `RestClient`/`WebClient` 都自带池化。
2. **显式设置超时**：连接超时、读超时、连接池获取超时三件套缺一不可，否则线程会被无限期挂住。
3. **try-with-resources 是底线**：任何 `Closeable` 都必须被关闭。
4. **监控 CLOSE_WAIT**：把 `ss -ant state close-wait | wc -l` 做成指标，比等报警强。
5. **合理设置 `maxConnTotal` / `maxConnPerRoute`**，避免连接池过大反向压垮下游。

```java
// HttpClient 5 关键配置
PoolingHttpClientConnectionManager cm = new PoolingHttpClientConnectionManager();
cm.setMaxTotal(200);
cm.setDefaultMaxPerRoute(50);
RequestConfig config = RequestConfig.custom()
        .setConnectTimeout(2000)
        .setResponseTimeout(3000)
        .setConnectionRequestTimeout(500)   // 从池里拿连接的等待时间
        .build();
```

---

## 五、面试追问连环炮

**Q1：TIME_WAIT 是 2MSL，MSL 是多少？能改吗？**
Linux 中 MSL 固定 60s，`TIME_WAIT` 即 60s，`/proc/sys/net/ipv4/tcp_fin_timeout` 控制的是 `FIN_WAIT_2` 而非 TIME_WAIT，别答错。

**Q2：服务端出现大量 TIME_WAIT 正常吗？**
如果服务端是**主动关闭方**就正常。真实生产里最常见的场景是：服务端对外提供短连接 API，客户端不快关，服务端读完就关 → 服务端 TIME_WAIT 暴涨。这时优先考虑让客户端先关或上 keep-alive。

**Q3：`tcp_tw_reuse` 会不会导致数据错乱？**
不会，因为它只对**客户端出站**连接复用，且要求 `tcp_timestamps` 打开，内核会校验时间戳确保新连接晚于旧连接。但它对**服务端入站的 TIME_WAIT 无用**。

**Q4：CLOSE_WAIT 能通过改内核参数解决吗？**
不能。内核参数只影响 TIME_WAIT。CLOSE_WAIT 的 `tcp_orphan_retries`、`tcp_max_orphans` 只作用于已关闭的孤儿连接，治不了应用不 close 的问题。

**Q5：怎么区分 CLOSE_WAIT 是"没 close"还是"线程被占满"？**
看增长形态：如果 CLOSE_WAIT 与请求量成正比且不回落 → 泄漏（没 close）；如果随下游超时尖刺同步上涨、下游恢复后回落 → 阻塞型。再结合 `jstack` 看线程栈即可确认。

---

## 六、总结

| 维度 | TIME_WAIT | CLOSE_WAIT |
| --- | --- | --- |
| 归属方 | 主动关闭方 | 被动关闭方 |
| 是否正常 | 正常，协议要求 | 异常，代码问题 |
| 兜底手段 | 连接复用 / 内核参数 / 扩端口 | 修代码 / 加超时 / 查线程池 |
| 典型错误 | `Cannot assign requested address` | 连接数打满、句柄耗尽 |

记住一句话：**TIME_WAIT 是内核的事，CLOSE_WAIT 是你的事。** 前者调参数、做复用；后者老老实实 `close()`，把 try-with-resources 和超时当成铁律。
