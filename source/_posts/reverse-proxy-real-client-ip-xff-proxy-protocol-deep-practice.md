---
title: 【Java 网络】真实客户端 IP 深度实战：X-Forwarded-For 伪造、PROXY Protocol 与信任链建模
date: 2026-11-28 08:10:00
tags:
  - Java
  - 网络
  - Nginx
  - 安全
  - 生产实战
categories:
  - Java 实战
author: 东哥
---

# 【Java 网络】真实客户端 IP 深度实战

## 前言

一次安全评审，风控同学说：「我们的接口限流是按 IP 做的，但压测发现换个请求头就能绕过。」

打开代码：

```java
String ip = request.getHeader("X-Forwarded-For");
if (ip == null) ip = request.getRemoteAddr();
```

问题一眼就出来了：`X-Forwarded-For` 是**客户端可以自己带的请求头**。攻击者随便写 `X-Forwarded-For: 1.1.1.1`，每次换一个，限流就形同虚设；更糟的是审计日志里全是伪造 IP，出了事根本追不到人。

另一个常见现象：日志里 `remoteAddr` 一律是 `10.244.3.17`。这不是 bug，而是流量经过了 Ingress / Nginx / 云 SLB，Java 进程看到的是**最后一跳代理**的地址，不是用户。

这篇把「真实客户端 IP」这件事讲透：四层与七层分别能看到什么、XFF 的正确解析方向、PROXY Protocol 的适用场景、Nginx 与 Spring Boot 的配置陷阱、以及 Java 侧怎么建一条可被审计的信任链。

---

## 一、先分清：哪一层能看见什么

| 位置 | 能看到 | 看不到 |
|---|---|---|
| 四层负载均衡（LVS / 云 SLB / F5） | TCP 源 IP（真实客户端） | HTTP 头（不解包） |
| 七层代理（Nginx / Ingress / API 网关） | TCP 源 IP + HTTP 头 | 四层之前的原始连接（除非透传） |
| Java 进程（Tomcat/Netty） | 与它直连的那一端的 IP | 前面所有跳的信息（除非代理写入头部） |

所以「真实 IP」从来不是一个字段，而是一条**链**：

```
client(1.2.3.4) --> SLB --> nginx --> ingress --> java pod
                    |         |          |
              可写 PROXY  可写 XFF   可写 XFF
              protocol
```

每一跳都有两种选择：**透传**（把上一跳的信息带上）或**覆盖**（用自己的直连地址替换）。选错了，链就断了或者被污染。

常见头部语义：

| 头部 | 写入者 | 语义 |
|---|---|---|
| `X-Forwarded-For` | 各级七层代理 | 逗号分隔的 IP 链，**左边最早、右边最近** |
| `X-Real-IP` | 通常是 Nginx | 单个 IP，一般等于 `$remote_addr` |
| `Forwarded` | 标准化代理（RFC 7239） | `for=1.2.3.4;proto=https;host=...` |
| `X-Forwarded-Proto` | 七层代理 | 原始协议（http/https），影响重定向与 Cookie Secure |
| `CF-Connecting-IP` | Cloudflare | CF 边缘看到的客户端 IP |
| PROXY protocol | 四层代理 | 在 TCP 载荷最前面插入一行/一段二进制，不占 HTTP 头 |

---

## 二、XFF 的语义，以及为什么「取第一个」是错的

### 规范语义

RFC 7239 与事实标准都规定：代理**应当追加**而不是覆盖。假设客户端 `1.2.3.4`，经过 `10.0.0.1`、`10.0.0.2` 两台代理：

```
X-Forwarded-For: 1.2.3.4, 10.0.0.1
X-Forwarded-For: 1.2.3.4, 10.0.0.1, 10.0.0.2
```

最左边是客户端，最右边是「离当前服务最近的一跳」。

### 但客户端可以伪造

如果入口代理用的是「追加」语义：

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

而客户端请求里自带 `X-Forwarded-For: 8.8.8.8`，那么入口代理追加后就是：

```
X-Forwarded-For: 8.8.8.8, 1.2.3.4
```

此时「取第一个」得到 `8.8.8.8` —— 攻击者完全控制了这个值。

**正确做法：从右往左走，跳过所有可信代理，取第一个不可信地址。**

```
XFF: 8.8.8.8, 1.2.3.4, 10.0.0.1, 10.0.0.2
                          ^ 可信      ^ 可信
              ^ 第一个不可信 -> 这才是客户端
```

这就是「信任链建模」：你必须显式声明哪些网段是代理，然后从最右端开始剥。

### 三种取值的对比

| 策略 | 结果 | 安全性 |
|---|---|---|
| 取最左 | 客户端可控 | ❌ 可任意伪造 |
| 取最右 | 永远是最后一跳代理 | ❌ 无意义 |
| 从右往左跳过可信代理 | 第一个不可信地址 | ✅ 正确 |

如果整条链都是可信代理（比如客户端直连且没有代理），则退化为 `getRemoteAddr()`。

---

## 三、Nginx 侧：入口必须「清洗」

关键点：**第一跳必须覆盖，后续跳才追加。**

```nginx
# 最外层入口（直接面对公网的那一层）
# 1) 丢弃客户端自带的 XFF，用真实连接地址重建
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# 内层代理（前面已经有可信代理了）
# 2) 追加而不是覆盖
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

这一步如果漏了，后面所有解析逻辑都是在「信任攻击者输入」的基础上做的，怎么解析都没用。

### realip 模块

Nginx 自己也提供了解析能力：

```nginx
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.16.0.0/12;
set_real_ip_from 192.168.0.0/16;
real_ip_header X-Forwarded-For;
real_ip_recursive on;

# 之后 $remote_addr 就是「解析后的客户端 IP」
log_format main '$remote_addr - $http_x_forwarded_for "$request"';
```

`real_ip_recursive on` 的语义：从右往左跳过 `set_real_ip_from` 声明的可信地址，取第一个不可信的，替换 `$remote_addr`。**这正是我们要的方向**。默认 `off` 时只取最右一个值，多级代理下会取到代理 IP。

注意 `set_real_ip_from` 必须精确到真实的可信网段。写成 `0.0.0.0/0` 等于「全世界都可信」，比不配还危险。

---

## 四、PROXY Protocol：四层代理的唯一选择

四层 LB 不解 HTTP，没法写 `X-Forwarded-For`。它的做法是在 TCP 连接建立后、业务数据之前，先发一段特殊前缀：

```
# v1（文本，一行）
PROXY TCP4 1.2.3.4 10.0.0.5 51234 443\r\n

# v2（二进制）
\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A | ver/cmd | fam | len | src addr | dst addr | src port | dst port | TLVs
```

Nginx 侧开启：

```nginx
server {
    listen 443 ssl proxy_protocol;   # 关键：这条 listen 上的所有连接都必须带 PROXY header
    ssl_certificate     /etc/ssl/site.crt;
    ssl_certificate_key /etc/ssl/site.key;

    set_real_ip_from 10.0.0.0/8;     # LB 的网段
    real_ip_header proxy_protocol;
}
```

三个必须注意的点：

1. **开启后，所有连接都必须带 header**。LB 的健康检查如果不带，会直接被 Nginx 断开，表现为「后端全 down」。解决：健康检查走另一个不开 `proxy_protocol` 的端口。
2. **顺序是 PROXY protocol → TLS → HTTP**。PROXY header 在 TLS 之前，所以 LB 必须能同时处理二者（大多数云 SLB 支持）。
3. **安全边界**：只有可信 LB 才能发 PROXY protocol，否则任何直连者都能伪造源 IP。Nginx 里可以配合 `allow`/`deny` 或安全组限制来源网段。

另外，PROXY protocol 也可以由 Java 侧解析（Netty 有 `HAProxyMessageDecoder`），但绝大多数架构会在 Nginx 层就转成 XFF，Java 侧不必直接处理。

---

## 五、Java 侧落地：框架能做什么，不能做什么

### Tomcat：RemoteIpValve

```yaml
server:
  forward-headers-strategy: native   # 让 Tomcat 的 RemoteIpValve 生效
  tomcat:
    remoteip:
      remote-ip-header: X-Forwarded-For
      protocol-header: X-Forwarded-Proto
      internal-proxies: "10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}|192\\.168\\..*|172\\.(1[6-9]|2\\d|3[01])\\..*"
```

`server.forward-headers-strategy` 有三个值：

| 值 | 行为 |
|---|---|
| `NONE` | 不处理，`getRemoteAddr()` 是直连地址 |
| `NATIVE` | 用容器（Tomcat/Undertow/Jetty）自带机制 |
| `FRAMEWORK` | 用 Spring 的 `ForwardedHeaderFilter`（Servlet） |

**最大的坑**：`RemoteIpValve` 的 `internalProxies` 默认值包含 `10.x`、`172.16-31.x`、`192.168.x`、`127.x` 等私网段，而且**没有 100.64.0.0/10（运营商 NAT）和 IPv6 ULA**。在 K8s 里 Pod 网段恰好是 `10.x`，所以「碰巧能用」；一旦 LB 在公网段或用了 IPv6，解析立刻失效，而且不会报错，只是 IP 悄悄变成代理地址。

**结论：永远显式配置 `internal-proxies`，不要依赖默认值。**

### WebFlux：另一套机制

WebFlux 走的是 `ForwardedHeaderTransformer`：

```java
@Bean
public ForwardedHeaderTransformer forwardedHeaderTransformer() {
    return new ForwardedHeaderTransformer();
}
```

注意 WebFlux 默认**不启用**（除非设置 `server.forward-headers-strategy=framework`），而且它只处理 `Forwarded` / `X-Forwarded-*`，同样依赖「信任所有代理」，在严格场景下仍需要自己做信任链校验。

### 自己写解析器（推荐）

框架的解析要么「盲目信任」，要么配置不透明。生产上建议显式实现一个解析器，把信任链写进代码和配置：

```java
public final class ClientIpResolver {

    private final List<IpRange> trustedProxies;   // 可信代理网段（CIDR）
    private final int maxHops;                    // 防御超长链

    public String resolve(HttpServletRequest req) {
        String remote = normalize(req.getRemoteAddr());
        if (!isTrusted(remote)) {
            // 直连且不可信：这就是客户端，忽略所有头部
            return remote;
        }
        String xff = req.getHeader("X-Forwarded-For");
        if (xff == null || xff.isBlank()) {
            return remote;
        }
        String[] parts = xff.split(",");
        int start = Math.max(0, parts.length - maxHops);
        // 从右往左，找到第一个不可信地址
        for (int i = parts.length - 1; i >= start; i--) {
            String ip = normalize(parts[i].trim());
            if (ip.isEmpty() || !isValidIp(ip)) {
                continue;               // 垃圾值直接跳过
            }
            if (!isTrusted(ip)) {
                return ip;
            }
        }
        // 全是可信代理，退化为最左的有效值（或 remote）
        return normalize(parts[start].trim());
    }

    private boolean isTrusted(String ip) {
        InetAddress addr = parse(ip);
        return addr != null && trustedProxies.stream().anyMatch(r -> r.contains(addr));
    }

    private static String normalize(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        // IPv4-mapped IPv6: ::ffff:1.2.3.4 -> 1.2.3.4
        if (s.startsWith("::ffff:")) s = s.substring(7);
        int pct = s.indexOf('%');        // 去掉 zone id: fe80::1%eth0
        if (pct > 0) s = s.substring(0, pct);
        return s;
    }
}
```

几个必须在单测里覆盖的用例：

| 输入 | 期望 |
|---|---|
| `remote=1.2.3.4`（不可信），XFF 任意 | 返回 `1.2.3.4`，**忽略 XFF** |
| `remote=10.0.0.5`（可信），XFF=`8.8.8.8, 1.2.3.4` | 返回 `1.2.3.4` |
| `remote=10.0.0.5`，XFF=`1.2.3.4` | 返回 `1.2.3.4` |
| `remote=10.0.0.5`，XFF=`garbage` | 返回 `10.0.0.5`（兜底） |
| `remote=::ffff:10.0.0.5` | 归一化为 `10.0.0.5` 后判可信 |
| XFF 长度 100 跳 | 只解析最后 `maxHops` 跳，防 DoS |

---

## 六、IP 归一化之后还要做什么

拿到「真实 IP」只是第一步，直接用它会踩三个坑：

### 1. IPv6 必须按 /64 聚合

一个家庭宽带用户通常被分配一个 /64 前缀，客户端可以在这个前缀内任意换地址。如果限流按单个 IPv6 地址计数，攻击者每次换一个地址就能绕过。

```java
// 按 /64 聚合：保留前 64 位，后 64 位置零
byte[] raw = addr.getAddress();
for (int i = 8; i < 16; i++) raw[i] = 0;
String bucket = InetAddress.getByAddress(raw).getHostAddress() + "/64";
```

### 2. NAT 出口导致「一个 IP 几万人」

企业出口、运营商 CGNAT 场景下，按 IP 限流会误伤整栋楼。此时限流维度必须叠加账号、设备指纹、API Key，IP 只作为辅助信号。

### 3. 代理/VPN/Tor 要打标，不要直接封

真实 IP 可能在数据中心网段（代理）、已知 VPN 出口、Tor 出口列表里。这类流量应该降权或加验证，而不是简单封禁 —— 封了会误伤正常企业用户。

---

## 七、八个生产踩坑

1. **入口不覆盖 XFF**，后面怎么解析都是错的。这是最高频的问题。
2. **`internal-proxies` 用默认值**，在 K8s/公网 LB 混合环境静默失效，日志里 IP 变成 `10.x`。
3. **Nginx 多处 `proxy_set_header X-Forwarded-For` 重复配置**，内层覆盖了外层，链断成一段。
4. **`X-Forwarded-Proto` 没透传**，Spring 生成的重定向链接变成 `http://`，Cookie 的 `Secure` 属性失效。
5. **gRPC / HTTP2 场景**，IP 要靠 metadata 传递，很多网关默认不透传 XFF。
6. **WebSocket 握手后 `remoteAddress` 不变**，但经过 LB 的连接可能被重建，长连接中途重连会换 IP，会话绑定 IP 的逻辑要允许漂移。
7. **把 XFF 原样透传给第三方服务**，等于把内网拓扑和用户 IP 泄露出去，出站请求要剥离。
8. **日志里同时记录 `remote_addr` 和解析后的 IP**，否则出问题时无法回溯「是解析错了还是链路变了」。

---

## 八、面试追问

**Q1：为什么不能取 `X-Forwarded-For` 的第一个？**
因为客户端可以自带该头部，入口代理若采用追加语义，最左值就是客户端可控的伪造值。必须从右往左、跳过可信代理。

**Q2：`X-Real-IP` 和 `X-Forwarded-For` 有什么区别？**
`X-Real-IP` 是 Nginx 习惯的单值头，通常等于 `$remote_addr`，多级代理下会丢失链路信息；XFF 是链，能还原路径，但也更需要信任模型。

**Q3：四层 LB 怎么传客户端 IP？**
PROXY protocol（v1 文本 / v2 二进制），或者 transparent proxy（内核层保留源 IP）。前者需要应用/代理显式支持，后者依赖网络配置。

**Q4：`server.forward-headers-strategy` 三个值怎么选？**
纯 Tomcat 用 `NATIVE`；WebFlux 或需要统一行为用 `FRAMEWORK`；有严格信任链要求时用 `NONE` 并自己解析。

**Q5：按 IP 限流为什么经常失效？**
三个原因：IP 可伪造（头部未清洗）、IPv6 可按地址漂移（未按 /64 聚合）、NAT 下大量用户共享 IP（误伤）。所以 IP 只能作为多维限流中的一维。

---

## 小结

- 「真实 IP」是一条链，不是单个字段；链的可靠性取决于**每一跳是否清洗与追加**；
- XFF 必须**从右往左**解析，跳过可信代理网段，取第一个不可信地址；
- 入口代理必须用 `$remote_addr` 覆盖客户端自带的 XFF，这是整个体系的地基；
- 四层代理只能用 PROXY protocol，且必须限制来源网段；
- Java 侧不要盲信框架默认值，`internal-proxies` 一定要显式配置；
- 拿到 IP 之后还要做 IPv6 /64 聚合、NAT 识别、代理打标，否则限流和风控依然是纸糊的。

真实 IP 这件事，做对了没人夸你，做错了会在某个安全评审的下午被当众翻出来。
