---
title: 【Java 网络】TLS 会话复用与证书热轮换深度实战：握手成本、0-RTT 风险与不停机换证
date: 2026-11-23 08:20:00
tags:
  - Java
  - TLS
  - 网络安全
  - 性能优化
categories:
  - Java 深挖
author: 东哥
---

# 【Java 网络】TLS 会话复用与证书热轮换深度实战

## 面试官：你们的证书 90 天轮换一次，怎么做到不停机？握手能不能省掉？

这两个问题其实是一枚硬币的两面：**TLS 握手既是最贵的部分，也是证书生效的唯一时机**。想省掉握手，就要理解会话复用；想不停机换证，就要理解 JSSE 在什么时候读取 keystore。

先说结论：

- TLS 1.3 完整握手 1-RTT，TLS 1.2 需要 2-RTT；一次 ECDSA P-256 握手在服务端的 CPU 开销约为对称加密的**两个数量级**。
- 会话复用能把握手压到 0-RTT（TLS 1.3 PSK）或 1-RTT（TLS 1.2 session ticket），但**复用的会话里没有"证书"这个概念**——客户端认的是会话票据，不是新证书。
- 因此"轮换证书"和"复用会话"必须一起设计：换证要让旧会话可控地失效，否则新证书上线后仍有一批连接在跑旧会话。

下面按"握手 → 复用 → 换证 → 排障"四段拆。

## 一、握手成本到底花在哪

| 阶段 | TLS 1.2 | TLS 1.3 | 主要开销 |
|---|---|---|---|
| 协商 + 密钥交换 | 2-RTT | 1-RTT | ECDHE 点乘（最大头） |
| 证书传输与校验 | 握手内 | 握手内（加密） | 证书链大小、OCSP |
| 对称加密 | 1-RTT 后 | 1-RTT 后 | AES-NI 下很便宜 |
| 会话复用 | 1-RTT（ticket） | **0-RTT**（PSK + early data） | 免密钥交换 |

一个常被忽略的点：**证书链大小直接影响握手字节数**。中间证书多带两级，每个新连接多传 2~4KB；在移动弱网下，这就是几十毫秒。用 `openssl s_client -showcerts` 看链路，只发 leaf + 必要中间证书。

TLS 1.3 还有一个隐藏收益：**握手消息加密**后，中间设备无法再窥探 SNI 之外的握手内容，但也意味着传统基于明文的中间盒观测手段失效。

## 二、会话复用的三种机制

### 2.1 Session ID（服务端有状态）

服务端在 `SSLSessionContext` 里缓存会话，客户端拿 32 字节 session id 来恢复。JDK 默认：

```java
SSLContext ctx = SSLContext.getInstance("TLS");
ctx.init(keyManagers, trustManagers, null);
SSLSessionContext cache = ctx.getServerSessionContext();
cache.setSessionTimeout(86400);   // 默认 24h
cache.setSessionCacheSize(2048);  // 默认 2048
```

问题是**多实例不共享**：负载均衡把第二次连接打到另一台机器，session id 命中不了，退化成完整握手。所以 K8s 多副本 + 四层 LB 场景下，Session ID 的命中率通常只有 `1/N`。

### 2.2 Session Ticket（无状态票据）

服务端用一张 **ticket key**（AES 加密 + HMAC）把会话状态加密成票据交给客户端，自己不存。任何持有同一 ticket key 的实例都能解密恢复——这正好解决多实例问题。

JDK 里要显式开启：

```bash
-Djdk.tls.server.enableSessionTicketExtension=true
-Djdk.tls.server.sessionTicketTimeout=3600
```

注意：**ticket key 需要自行轮换**。JDK 不暴露 ticket key 的轮换 API，实务中要么定期滚动重启（配合双 key 兼容期），要么在 Netty/OpenSSL 侧自己管理 `SSL_CTX_set_tlsext_ticket_key_cb`（支持新旧两把 key 并存）。

### 2.3 TLS 1.3 PSK 与 0-RTT

TLS 1.3 把会话复用统一成 PSK：服务端下发 NewSessionTicket，客户端下次带 `pre_shared_key` 扩展，**在第一个飞行包里就能带应用数据**（early data）。这就是 0-RTT。

三种机制对比：

| 机制 | 服务端状态 | 多实例可用 | 恢复 RTT | 前向安全 | 重放风险 |
|---|---|---|---|---|---|
| Session ID | 有 | 否（需共享缓存） | 1-RTT | 是 | 无 |
| Session Ticket（1.2） | 无 | 是（共享 key） | 1-RTT | 取决于 key 轮换 | 无 |
| TLS 1.3 PSK / 0-RTT | 无 | 是 | **0-RTT** | 是 | **有（early data 可重放）** |

0-RTT 的重放是真实风险：攻击者截获 early data 包可以重复发送，服务端会再次执行。所以**只允许幂等请求走 0-RTT**。实践中更稳的做法是：开启 PSK 复用（省掉密钥交换），但**服务端拒绝 early data**（`max_early_data_size=0`），拿到 1-RTT 的收益又不承担重放风险。

## 三、Java 客户端侧：连接池与会话的配合

服务间调用常用 OkHttp / Apache HttpClient / Netty。会话复用对短连接意义不大——连接都复用了，握手本来就少。真正需要关注的是**连接池的 TTL 与 TLS 会话 TTL 的关系**：

```
连接空闲超时(pool idle) < TLS 会话超时(session timeout)
```

如果连接池 5 分钟就回收，而会话缓存 24 小时，那每次新建连接都能命中会话票据，这是最优组合。反过来，如果连接池 TTL 比会话还长，连接一直不重建，会话复用的收益就被"连接复用"覆盖了——也没问题，只是要保证长连接能感知证书吊销。

JDK 客户端开启会话缓存（默认开启，但要注意共享）：

```java
SSLContext ctx = SSLContext.getInstance("TLS");
ctx.init(null, null, null);
SSLSessionContext clientCache = ctx.getClientSessionContext();
clientCache.setSessionTimeout(3600);
clientCache.setSessionCacheSize(512);

HttpsURLConnection.setDefaultSSLSocketFactory(ctx.getSocketFactory());
```

如果是自建连接池，每个 `SSLSocketFactory` 共享同一个 `SSLContext` 才有复用价值；每请求 new 一个 `SSLContext` 等于每次冷启动。

## 四、证书热轮换：三条可行路径

### 4.1 路径一：重建 SSLContext（最通用）

JSSE 的 `KeyManagerFactory` 在初始化时把 keystore 读进内存，**之后改文件不生效**。所以"热加载"的本质是：检测到文件变化 → 重新加载 keystore → 重建 `SSLContext` → 新连接用新 context，旧连接自然结束。

```java
@Component
public class ReloadableSslContextFactory {
    private final AtomicReference<SSLContext> current = new AtomicReference<>();
    private final Path keyStorePath;
    private final char[] password;

    public SSLContext get() { return current.get(); }

    @Scheduled(fixedDelay = 30_000)
    public void reloadIfChanged() throws Exception {
        long mtime = Files.getLastModifiedTime(keyStorePath).toMillis();
        if (mtime == lastMtime) return;

        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (InputStream in = Files.newInputStream(keyStorePath)) {
            ks.load(in, password);
        }
        KeyManagerFactory kmf =
            KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, password);

        SSLContext next = SSLContext.getInstance("TLS");
        next.init(kmf.getKeyManagers(), null, null);

        current.set(next);          // 原子替换
        lastMtime = mtime;
        log.info("TLS certificate reloaded, notAfter={}",
            ((X509Certificate) ks.getCertificate(ks.aliases().nextElement()))
                .getNotAfter());
    }
}
```

关键点：

- **原子替换**，不要在旧 context 上做 `init`（会有并发可见性问题）。
- **先校验再切换**：加载后检查 `notAfter` 是否在未来、私钥与证书是否匹配（`KeyStore.getKey` 能取到私钥即匹配），校验失败就保留旧 context 并告警。
- **旧连接不强制断**。想立刻生效可以配合连接池的最大生命周期（如 10 分钟自然轮空）。

### 4.2 路径二：Netty 双 SslContext 切换

Netty 的 `SslContext` 是重量级对象，不能每连接重建。做法是持有一个 `AtomicReference<SslContext>`，在 `SniHandler` 或 `ChannelInitializer` 里按引用取：

```java
public final class HotSwappableSslContext extends SniHandler {
    private final AtomicReference<SslContext> ref;

    public HotSwappableSslContext(Mapping<String, SslContext> mapping,
                                  AtomicReference<SslContext> ref) {
        super(mapping);
        this.ref = ref;
    }

    @Override
    protected SslContext newSslContext() { return ref.get(); }
}
```

Netty 原生支持 OpenSSL（`netty-tcnative`），配合 `SslContextBuilder.forServer(certChainFile, keyFile)` 可以直接读 PEM，**文件变更后重建即可**，不需要 keystore 转换。这也是很多网关（Spring Cloud Gateway + Netty）的标准做法。

### 4.3 路径三：交给 Sidecar / Ingress 终止 TLS

K8s 里更常见的是证书挂到 Ingress Controller（或 cert-manager + Secret 自动轮换），应用只跑明文 HTTP。此时"热轮换"由 controller 负责，应用侧要关注的是：

- Secret 更新到 Pod 内文件的延迟（kubelet 同步周期，通常 1~2 分钟）。
- Nginx Ingress 是否监听文件变化（`--watch-ingress-without-class` 之外，证书是每个 server block 独立 reload）。
- **不要**把证书 copy 到镜像里，否则轮换等于重新发布。

| 方案 | 生效速度 | 需要重启 | 适用 |
|---|---|---|---|
| 应用内重建 SSLContext | 秒级（轮询间隔） | 否 | 自建服务、mTLS 双向 |
| Netty 双 context | 秒级 | 否 | 网关、长连接 |
| Ingress 终止 | 分钟级 | 否 | 标准七层入口 |
| 重新发布（挂载新 Secret） | 分钟~十分钟级 | **是** | 兜底方案 |

## 五、换证期间最容易翻车的五个点

**1. 只换了 leaf，没换 chain。** 客户端信任链校验失败，报 `unable to find valid certification path`。换证时把 fullchain 一起校验：`openssl verify -CAfile ca.pem fullchain.pem`。

**2. SNI 与 SAN 不匹配。** 多域名共用 IP 时，客户端按 SNI 选证书；新证书漏了某个 SAN，那一个域名直接握手失败。上线前用 `openssl s_client -servername xxx -connect ip:443` 逐个域名验证。

**3. 时钟问题导致"证书未生效"。** `notBefore` 依赖本机时钟，容器时间漂移会报 `certificate is not yet valid`。检查 `chronyd`/`ntpd` 状态，而不是怀疑证书。

**4. OCSP stapling 没刷新。** 换证后 stapling 缓存里还是旧响应，部分客户端因 `must-staple` 拒绝连接。Nginx 需 `ssl_stapling on` + `resolver` 配置正确，换证后观察 `ssl_stapling_verify` 日志。

**5. 双向 TLS 的信任库没更新。** 服务端换证后，如果客户端是 pin 证书（certificate pinning）而不是 pin CA，会全部失败。mTLS 场景要预留"新旧证书双信任"的过渡期。

## 六、排障命令速查

```bash
# 看握手全过程（含会话复用是否命中）
openssl s_client -connect api.example.com:443 -servername api.example.com \
  -reconnect -state -tls1_3 </dev/null 2>&1 | grep -E "Reused|New|Session-ID|TLS"

# 看证书链与有效期
openssl s_client -connect api.example.com:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# 检查 OCSP stapling
openssl s_client -connect api.example.com:443 -status </dev/null 2>&1 | grep -A3 "OCSP"

# Java 侧握手细节（生产慎用，日志量极大）
java -Djavax.net.debug=ssl:handshake -jar app.jar
```

常见错误码对照：

| 错误 | 含义 | 排查方向 |
|---|---|---|
| `handshake_failure` | 无共同密码套件/协议版本 | 双方 TLS 版本、cipher suite |
| `certificate_unknown` | 证书链不被信任 | 中间证书、信任库 |
| `protocol_version` | 版本不匹配 | TLS 1.3 vs 只支持 1.2 的老客户端 |
| `bad_certificate` | 证书内容非法/过期 | `notBefore/notAfter`、SAN |
| `SSLV3_ALERT_HANDSHAKE_FAILURE` | 常见于 mTLS 客户端证书缺失 | 客户端 KeyManager |

## 七、面试追问

**Q：TLS 1.3 的 0-RTT 为什么危险？**
early data 可以被重放，服务端无法区分首次与重放。只对幂等 GET 开启，或者干脆 `max_early_data_size=0` 只用 PSK 省密钥交换。

**Q：session ticket 的 key 泄露会怎样？**
攻击者能解密历史票据，恢复会话密钥，从而解密抓到的流量——**前向安全性丧失**。所以 ticket key 要定期轮换，且与证书私钥分开管理。

**Q：为什么改了 keystore 文件不生效？**
`KeyManagerFactory.init` 已经把内容读进内存，JSSE 不会监听文件变化。必须重建 `SSLContext` 并替换引用。

**Q：如何在换证时保证零 5xx？**
双证书并存期（新旧都在信任链里）+ 连接池自然轮空 + 灰度按实例分批 reload + 监控握手失败率。不要在同一秒全量替换。

**Q：mTLS 和单向 TLS 在会话复用上有什么差别？**
mTLS 的客户端证书在握手时校验，会话复用后不再重复校验，所以**吊销客户端证书对已复用会话无效**。需要缩短会话 TTL 或主动踢连接。

## 小结

TLS 的性能优化不是"开个开关"，而是把**握手成本、会话生命周期、证书生命周期**三者对齐：连接池 TTL 小于会话 TTL，会话 TTL 小于证书有效期，证书轮换走"校验-原子替换-灰度"三步。把这套链路讲清楚，既能答性能题，也能答稳定性题。
