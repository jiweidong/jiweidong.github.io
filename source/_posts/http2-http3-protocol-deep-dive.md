---
title: 【网络协议】HTTP/2 与 HTTP/3 深度解析：多路复用、队头阻塞与 Java 客户端实战
date: 2026-08-17 08:00:00
tags:
  - Java
  - HTTP
  - 网络协议
  - 性能优化
categories:
  - Java
  - 网络
author: 东哥
---

# 【网络协议】HTTP/2 与 HTTP/3 深度解析：多路复用、队头阻塞与 Java 客户端实战

## 一、从 HTTP/1.1 的痛点说起

HTTP/1.1 有几个根深蒂固的问题：

1. **队头阻塞（Head-of-Line Blocking）**：同一连接上请求必须串行，前一个响应没返回，后面的请求只能排队。浏览器用"每个域名 6 个连接"来缓解，但治标不治本。
2. **头部冗余**：Cookie、User-Agent 等请求头动辄几百字节，每次请求都要完整重发。
3. **只能客户端主动请求**：服务端想推送资源（比如 HTML 里的 JS/CSS），做不到。

HTTP/2 和 HTTP/3 就是针对这些问题给出的两代答案。面试高频题："HTTP/2 解决了什么问题？HTTP/2 的队头阻塞为什么没根除？HTTP/3 为什么用 UDP？"——看完这篇你都能答。

## 二、HTTP/2 的核心机制

### 1. 二进制分帧（Binary Framing Layer）

HTTP/1.1 是文本协议（`GET /index HTTP/1.1\r\n`），HTTP/2 把报文拆成二进制**帧（Frame）**：

```
帧结构：9 字节帧头 + 载荷
- Length（3字节）: 载荷长度
- Type（1字节）: DATA / HEADERS / SETTINGS / PING / RST_STREAM ...
- Flags（1字节）: END_STREAM、END_HEADERS 等
- Stream Identifier（4字节）: 所属流 ID
```

所有帧在一个 TCP 连接上交错发送，接收方按 **Stream ID** 重组出完整的请求/响应。

### 2. 多路复用（Multiplexing）

一个 TCP 连接上可以同时跑**上百个流（Stream）**，每个流对应一个请求-响应交换。HTTP/1.1 的"6 连接上限"成为历史，连接数大幅下降，减少了 TCP 握手和慢启动的开销。

### 3. 头部压缩（HPACK）

HPACK 用**静态表 + 动态表 + Huffman 编码**压缩头部：

- **静态表**：61 个高频头字段（`:method: GET`、`content-type` 等）编成固定索引，1 字节搞定
- **动态表**：连接上出现过的自定义头（如 `x-token: abc123`）加入动态表，后续用索引引用
- **Huffman 编码**：对剩余文本压缩

效果：头部体积通常下降 80%+，一个请求从 500 字节降到几十字节。

### 4. 服务端推送（Server Push）

服务端可以在客户端请求 HTML 时，主动推送它即将用到的 CSS/JS，省去客户端二次请求的 RTT。注意：**Chrome 106 起已移除对 Server Push 的支持**，现在更推荐用 103 Early Hints，所以这个特性了解即可。

## 三、HTTP/2 的遗留问题：TCP 层队头阻塞

HTTP/2 解决了**应用层**的队头阻塞（多个流并行），但底层还是 TCP：

**TCP 保证有序交付**——一个包丢了，后续所有包都在内核缓冲区里等着重传，即使这些包属于其他完全无关的流。

比如一个连接上有 100 个流的请求，其中一个流的包丢了，TCP 要等超时重传，**其余 99 个流全部被堵住**。这就是"TCP 层队头阻塞"，HTTP/2 无能为力。

另外 TCP 握手也慢：TLS 1.2 需要 2 个 RTT（TCP 1 个 + TLS 1 个），加上连接数少导致慢启动恢复慢。

## 四、HTTP/3：换掉 TCP，用 QUIC

HTTP/3 的答案很激进：**底层不用 TCP，改用基于 UDP 的 QUIC 协议**。

### QUIC 解决了什么？

| 问题 | TCP（HTTP/2） | QUIC（HTTP/3） |
|------|--------------|----------------|
| 队头阻塞 | 单包丢失阻塞整条连接 | **每个流独立**，丢包只影响该流 |
| 握手延迟 | 1 RTT（TCP）+ 1-2 RTT（TLS） | **0-RTT/1-RTT** 合并握手 |
| 连接迁移 | IP 变了连接就断 | **连接 ID 标识**，IP 变了不断连 |
| 头部加密 | TLS 加密载荷，明文暴露头 | **全部加密**（含头部） |

关键机制：

1. **流独立（Per-Stream Flow Control）**：QUIC 在 UDP 之上自己实现可靠传输（序号 + 重传 + 流量控制），每个流独立管理。一个流的包丢了只重传该流，其他流照常推进——队头阻塞从根上消除（传输层级）。
2. **合并握手**：QUIC 的握手（TLS 1.3 内嵌在 QUIC 里）只需 1 RTT；有缓存时 **0-RTT** 直接发数据。
3. **连接迁移**：连接用 64 位 **Connection ID** 标识而非 IP:端口，手机从 Wi-Fi 切到 4G，连接不断。
4. **加密默认开启**：TLS 1.3 是 QUIC 的一部分，HTTP/2 那种"头部明文可见"的问题不复存在。

### 为什么敢用 UDP？

因为 TCP 的内核实现无法定制（改 TCP = 改操作系统），而 UDP 只是个"带端口的 IP"，QUIC 在**用户态**自己实现了可靠传输和拥塞控制。代价是 CPU 开销略高（用户态协议栈），但现代 CPU 和内核加速（如 GSO/GRO）已大幅缓解。

## 五、HTTP/3 的现状与坑

- **浏览器支持**：Chrome/Firefox/Edge/Safari 均支持，且已默认开启（`--enable-quic` 时代早已过去）
- **服务端支持**：Nginx 1.25+ 支持 HTTP/3（`listen quic`），Cloudflare/Google 大规模生产使用
- **国内现状**：UDP 在某些网络环境（尤其部分企业防火墙/运营商 QoS）会被限速或丢弃，**降级到 HTTP/2 的能力必须有**

## 六、Java 客户端实战

### 1. 启用 HTTP/2（Java 11+ HttpClient）

```java
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

HttpClient client = HttpClient.newBuilder()
        .version(HttpClient.Version.HTTP_2)   // 优先 HTTP/2，协商失败自动降级 HTTP/1.1
        .connectTimeout(Duration.ofSeconds(5))
        .build();

HttpRequest request = HttpRequest.newBuilder()
        .uri(URI.create("https://example.com/api"))
        .GET()
        .build();

HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
System.out.println(response.version());  // 打印实际使用的协议版本：HTTP_2 或 HTTP_1_1
```

关键点：`version(HTTP_2)` 是**优先**而非强制，通过 ALPN（TLS 扩展）与服务端协商，服务端不支持就回落到 HTTP/1.1。

### 2. HTTP/2 多路复用验证

```java
// 同一个 HttpClient 实例 = 同一个连接池，HTTP/2 下共享单连接
List<HttpRequest> requests = IntStream.range(0, 20)
        .mapToObj(i -> HttpRequest.newBuilder()
                .uri(URI.create("https://example.com/api/item/" + i))
                .build())
        .toList();

// 并发发送，HTTP/2 下 20 个请求复用同一 TCP 连接并行
CompletableFuture<?>[] futures = requests.stream()
        .map(req -> client.sendAsync(req, HttpResponse.BodyHandlers.ofString()))
        .toArray(CompletableFuture[]::new);
CompletableFuture.allOf(futures).join();
```

用 `ss -tn` 观察连接数：HTTP/1.1 会建多个连接，HTTP/2 只有一个连接。

### 3. Nginx 开启 HTTP/2 与 HTTP/3

```nginx
server {
    listen 443 ssl http2;              # HTTP/2
    listen 443 quic reuseport;         # HTTP/3（Nginx 1.25+）
    http2 on;                          # Nginx 1.25.1+ 新指令

    ssl_certificate     /etc/nginx/cert.pem;
    ssl_certificate_key /etc/nginx/cert.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    add_header Alt-Svc 'h3=":443"; ma=86400';  # 告知客户端支持 HTTP/3
}
```

### 4. OkHttp 启用 HTTP/2

```java
OkHttpClient client = new OkHttpClient.Builder()
        .protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1))
        .build();
```

## 七、面试常见追问

**Q1：HTTP/2 的多路复用和 HTTP/1.1 的 keep-alive 有什么区别？**
keep-alive 只是复用连接，但请求仍然串行（同一时刻一个请求）；HTTP/2 是真正的并行——同一连接上多个流同时收发。而且 HTTP/1.1 的并发受浏览器 6 连接限制，HTTP/2 单连接即可。

**Q2：HTTP/2 还存在队头阻塞吗？**
存在，但只在 **TCP 层**：单个包丢失导致 TCP 重传，阻塞整条连接上所有流。HTTP/3 用 QUIC 的独立流解决了传输层队头阻塞。

**Q3：为什么 HTTP/3 不用 TCP 而是 UDP？**
TCP 的可靠传输实现在内核里，无法在不升级操作系统的情况下改造；QUIC 在用户态用 UDP 实现了可靠传输 + TLS 1.3 + 多路复用，协议演进完全掌控在自己手里，能快速迭代。

**Q4：gRPC 为什么基于 HTTP/2？**
gRPC 需要双向流式通信（客户端流、服务端流、双向流），HTTP/2 的多路复用 + 流式帧（DATA 帧无边界限制）天然支持；同时 HTTP/2 的二进制帧适合传输 Protobuf 二进制载荷。gRPC-Web 和部分 gRPC 实现也在向 HTTP/3 演进。

**Q5：你的 Java 服务怎么确认实际用了 HTTP/2？**
`response.version()` 打印协议版本；服务端看 access log 的 `$http2` 变量；或者抓包看 ALPN 协商结果（TLS ClientHello 里的 ALPN 扩展）。

## 总结

一句话记住三者的关系：**HTTP/1.1 是"排队买票"，HTTP/2 是"一窗多办"（但有人插队全队等），HTTP/3 是"每个窗口独立排队"**。面试答这题的关键是分清"应用层队头阻塞"（HTTP/2 已解决）和"传输层队头阻塞"（HTTP/3 才根除），再补上 QUIC 的连接迁移和 0-RTT 特性，就是满分答案。
