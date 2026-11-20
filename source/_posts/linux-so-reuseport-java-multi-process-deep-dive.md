---
title: 【性能调优】SO_REUSEPORT 深度解析：内核四元组哈希、Netty 落地与滚动发布零丢连接
date: 2026-11-20 08:20:00
tags:
  - Java
  - Linux
  - 网络
  - Netty
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】SO_REUSEPORT 深度解析

## 前言

同一个端口，能不能被多个进程同时监听？

在默认语义下不能——第二个 `bind()` 直接报 `EADDRINUSE`。这正是很多人对"滚动发布"的直觉：新进程起不来，必须先停旧的。

`SO_REUSEPORT` 打破了这个限制：**多个 socket 可以 bind 同一个地址+端口，由内核负责把新连接分给其中一个**。Linux 3.9 引入，Nginx 1.9.1 开始支持 `listen ... reuseport`，Netty 的 epoll 传输层也提供了开关。

它带来两个直接价值：**滚动发布零拒绝**、**多进程/多实例分摊 accept 压力**。但它不是银弹，用错会导致长连接严重倾斜。

这篇文章讲清楚内核怎么选 socket、Java 怎么落地、以及四个真实踩坑。

## 一、内核怎么选：四元组哈希，不是轮询

### 1.1 复用组（reuseport group）

当多个 socket 用 `SO_REUSEPORT` bind 同一 `(addr, port)` 时，内核把它们组织成一个 **reuseport group**。前提条件（Linux）：

- 所有 socket 必须设置 `SO_REUSEPORT`；
- 必须是**相同的有效 UID**（防止普通用户劫持别人的端口）；
- 协议、地址族、绑定地址一致。

之后每来一个新连接，内核在这个组里选一个 socket。

### 1.2 选择算法

对 TCP，内核用**四元组**（源 IP、源端口、目的 IP、目的端口）加一个随机密钥做哈希，再对组成员取模：

```text
idx = hash(sip, sport, dip, dport, secret) % group_size
```

三个直接推论，决定了它的全部优缺点：

1. **同一个连接永远落到同一个 socket**。所以它是"连接级"负载均衡，不是"请求级"。HTTP/1.1 keep-alive 的长连接、gRPC 的长连接、数据库连接池的长连接，都会**黏在**某个进程上。
2. **组大小变化会重映射**。加一个进程，`% N` 变了，一部分**新连接**会换目标；已有连接不受影响（它们已经在内核里绑定了 socket）。
3. **哈希带密钥**，防止外部构造四元组来定向打某一个进程。

第 1 点是最大的坑：如果你的流量是"少量超长连接"（比如 200 个 gRPC 长连接撑起全部 QPS），那么 8 个进程里可能有 1 个吃满 CPU，其余闲着。**连接数远大于进程数，分布才均匀。**

### 1.3 和普通 `accept` 争抢的区别

不开 `SO_REUSEPORT` 时，多进程共享监听 socket 只能靠**父进程创建、子进程继承**，然后多个进程同时 `accept()` 同一个队列。这有两个问题：

- **惊群**：一个连接到达唤醒所有进程，只有一个成功，其余白跑（现代内核有 `EPOLLEXCLUSIVE` 缓解，但不是所有框架都用）。
- **单队列瓶颈**：所有连接先进同一个 accept queue，队列长度、锁竞争都集中在一处。

`SO_REUSEPORT` 给每个 socket **独立的 accept queue**，从内核层面把压力分散开，也不存在惊群。这是它在高连接速率场景下真正的性能价值。

## 二、Netty 落地

标准 JDK NIO 没有提供可移植的 `SO_REUSEPORT` 开关（能不能设取决于 JDK 版本与 `supportedOptions()`），生产上一般走 Netty 的 epoll native transport：

```java
EventLoopGroup boss = new EpollEventLoopGroup(1);
EventLoopGroup worker = new EpollEventLoopGroup();

ServerBootstrap bootstrap = new ServerBootstrap();
bootstrap
    .group(boss, worker)
    .channel(EpollServerSocketChannel.class)
    // 注意：是 option()，作用在监听 socket 上；childOption 作用在每条连接上
    .option(EpollChannelOption.SO_REUSEPORT, true)
    .option(ChannelOption.SO_BACKLOG, 4096)
    .childOption(ChannelOption.TCP_NODELAY, true)
    .childHandler(new ChannelInitializer<SocketChannel>() {
        @Override
        protected void initChannel(SocketChannel ch) {
            ch.pipeline().addLast(new HttpServerCodec(), new HttpObjectAggregator(1 << 20),
                                   new BizHandler());
        }
    });

Channel server = bootstrap.bind(8080).sync().channel();
```

依赖：

```xml
<dependency>
  <groupId>io.netty</groupId>
  <artifactId>netty-transport-native-epoll</artifactId>
  <version>4.1.115.Final</version>
  <classifier>linux-x86_64</classifier>
</dependency>
```

三个必须注意的点：

1. **`option` 必须设在 bind 之前**，也就是在 `bind()` 前调用。事后设置无效。
2. **必须真的用 `EpollServerSocketChannel`**。`NioServerSocketChannel` 上设置这个 option 不会生效（会被忽略或抛异常），很多人踩这个坑后以为内核不支持。
3. **`SO_REUSEPORT` 是"每个进程都要设"**。旧进程没设、新进程设了，第二个 bind 依然失败——组要求成员资格一致。

## 三、滚动发布：怎么做到零拒绝

有了 `SO_REUSEPORT`，发布流程可以变成"先起新、再停旧"：

```text
1. 启动新版本进程（同样 bind 8080 + SO_REUSEPORT）→ 成功，内核开始给它分新连接
2. 从注册中心/负载均衡摘掉旧实例（停止导流）
3. 旧进程关闭监听 socket（不再收新连接，但在途连接继续）
4. 等待在途请求处理完（graceful shutdown，比如 30s 上限）
5. 旧进程退出
```

第 3 步是关键：**关闭监听 socket 不会重置已建立的连接**。内核里那些连接的 socket 仍然有效，直到对端关闭或进程退出。所以第 4 步的等待窗口就是你的"零丢连接"保障。

Spring Boot 3.x 的优雅停机：

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
```

```java
// 自定义：先摘流量，再关容器
@Component
public class DeregisterBeforeShutdown implements ApplicationListener<ContextClosedEvent> {
    @Override
    public void onApplicationEvent(ContextClosedEvent event) {
        registry.deregister();              // 先让上游不再导流
        try { Thread.sleep(3_000); } catch (InterruptedException ignored) { }
        // 之后 Spring 才会停 Tomcat/Netty 监听
    }
}
```

顺序不能反。如果先停监听再摘流量，中间那几秒上游还在往这个实例发请求，就会拿到 `connection refused`。

### 一个容易忽略的细节：连接迁移窗口

滚动期间，旧进程可能还有几百条 keep-alive 连接。它们在旧进程退出时被 RST，客户端会重连——这次重连会被内核分到新进程，通常用户无感。但如果客户端没有重试逻辑（比如某些老 SDK 的长轮询），就会看到一次失败。

所以"零丢连接"的准确说法是：**零 accept 拒绝 + 依赖客户端重连**。要连一次失败都不允许，得靠上游负载均衡的 connection draining，而不是 `SO_REUSEPORT`。

## 四、四个真实踩坑

### 坑 1：长连接导致 CPU 严重倾斜

现象：8 个进程，1 个 CPU 90%，其余 10%。QPS 总量正常，但 P99 抖动。

原因：上游是 4 个 gRPC 客户端，每个客户端维持一条 HTTP/2 长连接 → 总共 4 条连接 → 只有 4 个进程被选中。

诊断：

```bash
# 看每个进程的活跃连接数（同一端口的多个监听者）
ss -tnp state established '( sport = :8080 )' | awk '{print $NF}' | sort | uniq -c | sort -rn
```

解法有三种，按推荐顺序：

1. **让客户端建更多连接**（gRPC 用 `round_robin` + 多个后端地址，而不是 `pick_first` 单连接）。
2. **在应用层做请求级分发**（前面加一层 L7 负载均衡）。
3. **用 eBPF 改写选择逻辑**（`SO_ATTACH_REUSEPORT_EBPF`，Linux 4.5+），按更细的维度分发——但复杂度高，除非你确实需要按 QUIC Connection ID 之类的东西分发。

### 坑 2：以为开了就"自动负载均衡"

`SO_REUSEPORT` 只作用于**新连接的建立**。已经建立的连接，无论后端多闲，都不会迁移。所以它解决的是"连接建立速率"与"accept 队列"问题，不解决"请求分发"问题。

一个自检指标：**每个进程的 `accept` 计数 / 活跃连接数**。差异超过 1.5 倍就说明倾斜了。

```java
// Netty 侧统计：每个 worker 进程的 accept 数
AtomicLong accepted = new AtomicLong();
bootstrap.childHandler(new ChannelInitializer<SocketChannel>() {
    @Override protected void initChannel(SocketChannel ch) {
        accepted.incrementAndGet();
        // ...
    }
});
meter.gauge("netty.accepted.total", accepted);
```

### 坑 3：和 `SO_REUSEADDR` 搞混

两者完全不是一回事：

| 选项 | 作用 | 典型用途 |
|---|---|---|
| `SO_REUSEADDR` | 允许 bind 处于 `TIME_WAIT` 的地址 | 重启后快速复用端口 |
| `SO_REUSEPORT` | 允许多个**活跃** socket 同时 bind 同一端口 | 多进程负载分摊、滚动发布 |

`SO_REUSEADDR` 不能让你起两个进程监听同一端口。很多人设了它还是 `EADDRINUSE`，就是混淆了。

### 坑 4：UDP 上的分布可能不符合预期

UDP 没有连接，内核按四元组分发。对于 DNS 这类"一请求一响应"的短交互，分布很均匀。但对 QUIC 就不一样了：QUIC 连接可以**迁移**（客户端换 IP/端口），迁移后四元组变了，可能被分到另一个进程，而那个进程没有这个连接的密钥与状态。

这也是为什么 QUIC 服务端通常要按 **Connection ID** 分发，而不是四元组——需要 eBPF 或用户态负载均衡。别指望 `SO_REUSEPORT` 直接解决。

## 五、什么时候该用、什么时候别用

**适合：**

- 多进程/多实例部署，希望内核层直接分摊 accept 压力；
- 短连接为主（HTTP/1.0、短轮询、DNS）；
- 滚动发布要求"新老并存"的零拒绝窗口；
- 单机多实例（比如 8 核跑 4 个 JVM 实例，各 2GB 堆）。

**不适合：**

- 长连接为主且连接数远小于进程数（先解决连接数问题）；
- 需要请求级精确均衡（用 L7 负载均衡）；
- 依赖 `SO_REUSEPORT` 做"多租户端口复用"（UID 校验会拦住你）。

## 六、面试追问

**Q1：`SO_REUSEPORT` 的哈希是基于什么的？为什么不用轮询？**

TCP 用四元组 + 内核随机密钥做哈希。不用轮询是因为**连接是有状态的**：同一个连接的所有报文必须落到同一个 socket，否则 TCP 状态机会崩。轮询只能按"包"分，无法保证连接亲和性。哈希天然满足"同四元组 → 同 socket"。

**Q2：加一个进程后，已有连接会重新分布吗？**

不会。已有连接在建立时就已经绑定到某个 socket，后续报文直接走那条路径。只有**新连接**会按新的组大小重新取模。所以扩容是"渐进生效"，不是瞬间均衡——这也是为什么扩容后倾斜可能持续很久（取决于连接生命周期）。

**Q3：`SO_REUSEPORT` 能替代负载均衡器吗？**

只能在"单机多进程"这一层替代 accept 分发。它看不到 HTTP 路径、看不到请求耗时、不能做健康检查、不能跨机。跨机、L7 路由、熔断重试这些还是得靠独立 LB。它更像是"内核帮你省掉了一个本地 accept 分发器"。

**Q4：为什么要求相同 UID？**

历史原因是一个安全漏洞：如果允许不同用户 bind 同一端口，恶意用户可以抢走本该发给别人服务的连接（相当于本地端口劫持）。内核在后续版本加了有效 UID 校验，把复用组限制在同一用户内。这也是容器里"不同用户跑的两个进程想复用端口"会失败的原因。

## 总结

- `SO_REUSEPORT` 让多个 socket 同时 bind 同一端口，由内核按**四元组哈希**分发新连接。
- 它是**连接级**分发：长连接会黏住进程，连接数少于进程数时必然倾斜。
- 每个 socket 有独立 accept queue，这才是它相对"多进程 accept 同一 socket"的性能优势（无惊群、无单队列瓶颈）。
- Java 侧走 Netty epoll：`EpollChannelOption.SO_REUSEPORT` + `EpollServerSocketChannel` + `option()` 在 bind 前设置。
- 滚动发布能做"零 accept 拒绝"，但"零失败"还要靠摘流量 + graceful shutdown + 客户端重连。
- 别和 `SO_REUSEADDR` 混为一谈；UDP/QUIC 场景要按 Connection ID 分发时，得上 eBPF。
