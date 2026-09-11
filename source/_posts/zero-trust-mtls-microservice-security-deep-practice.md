---
title: 【安全实战】零信任架构与 mTLS 双向认证深度实战：从服务身份、证书签发到 Spring Boot 落地
date: 2026-09-11 08:20:00
tags:
  - 安全
  - 微服务
  - TLS
  - 面试
categories:
  - 安全
  - 微服务
author: 东哥
---

# 【安全实战】零信任架构与 mTLS 双向认证深度实战：从服务身份、证书签发到 Spring Boot 落地

## 面试官：微服务之间的调用，为什么不能只靠"内网就安全"？

传统安全模型是**边界防御**：防火墙把网络切成"可信内网"和"不可信外网"，进了内网就是自己人。这套模型在微服务时代有三个致命问题：

1. **东西向流量爆炸**：一个请求可能穿过网关 → 用户服务 → 订单服务 → 库存服务 → 支付服务，内网里全是明文 HTTP；
2. **横向移动成本极低**：任意一个 Pod 被拿下（依赖漏洞、镜像投毒、配置泄漏），攻击者就能在内网随意调用其它服务；
3. **身份不可验证**：内网调用默认"调用方是可信的"，服务无法分辨请求到底来自谁。

零信任（Zero Trust）的核心原则是一句话：

> **永不信任，始终验证（Never Trust, Always Verify）；假设网络已被攻破（Assume Breach）。**

落地时对应四个可执行的动作：

| 原则 | 工程落地 |
| --- | --- |
| 永不信任网络位置 | 内网服务间也强制加密 + 认证 |
| 始终验证身份 | 每个服务有**可验证的身份**（证书/Token） |
| 最小权限 | 服务级别的授权策略（谁能调谁） |
| 假设已失陷 | 短周期凭据、可吊销、全链路审计 |

mTLS（Mutual TLS）就是"始终验证"最直接的实现。

## 一、回顾单向 TLS 与 mTLS 的差别

单向 HTTPS 握手（服务端认证）：

```
Client                                Server
  |  -- ClientHello ----------------->   |
  |  <-- ServerHello + Certificate --    |  Server 发证书
  |  -- 验证证书链，生成 pre-master -->  |
  |  <-- Finished -------------------    |
  |  == 加密通道建立（Client 是匿名的）== |
```

**客户端不提供证书**，所以服务端只知道"有个客户端连进来了"，不知道它是谁。

mTLS 在握手中增加了一步：服务端在 `CertificateRequest` 中要求客户端证书。

```
Client                                Server
  |  <-- CertificateRequest ---------    |  要求客户端出示证书
  |  -- Certificate + CertificateVerify >  |  Client 发证书并证明持有私钥
  |  <-- Finished ---------------------   |  Server 用 CA 验证 Client 证书
  |  == 双向身份确认 ==                     |
```

关键校验点：

1. **证书链可信**：客户端证书必须由服务端信任的 CA 签发（`truststore`）；
2. **持有私钥**：`CertificateVerify` 用私钥签名握手数据，防止有人拿别人的证书冒充；
3. **身份校验**：服务端检查证书的 `SAN`（Subject Alternative Name，如 `spiffe://cluster.local/ns/prod/sa/order-service`）而不是 `CN`（现代实现已弃用 CN）；
4. **有效期与吊销状态**：`notBefore/notAfter`、CRL/OCSP。

## 二、证书体系：CA、KeyStore、TrustStore 的关系

Java 世界里最容易被绕晕的就是这几个概念：

| 概念 | 作用 | 存放内容 | 常用格式 |
| --- | --- | --- | --- |
| CA 根证书 | 签发信任链的锚点 | CA 自己的证书 | `.crt` / `.pem` |
| KeyStore | **本服务的身份** | 私钥 + 证书链 | JKS / PKCS12 |
| TrustStore | **信任谁** | 受信 CA 证书 | JKS / PKCS12 |

记忆口诀：**KeyStore 证明"我是谁"，TrustStore 决定"我信谁"。**

### 用 keytool 搭一套本地 CA（生产请用 Vault / cert-manager / SPIRE）

```bash
# 1. 生成 CA（自签名）
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=MyInternalCA/O=Demo"

# 2. 生成服务端私钥 + CSR
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=order-service" \
  -addext "subjectAltName=DNS:order-service,DNS:order-service.prod.svc.cluster.local"

# 3. 用 CA 签发
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 90 -sha256 \
  -extfile <(printf "subjectAltName=DNS:order-service,DNS:order-service.prod.svc.cluster.local")

# 4. 打包成 PKCS12（Java 推荐格式）
openssl pkcs12 -export -in server.crt -inkey server.key -certfile ca.crt \
  -name order-service -out order-service.p12 -passout pass:changeit

# 5. 客户端证书同理（CN=user-service）
```

**重要**：`SAN` 必须写对。K8s 里用 Service DNS 名字调用（`http://order-service.prod.svc.cluster.local`）， SAN 里就必须包含它，否则报 `No subject alternative names matching IP address / hostname`。

## 三、Spring Boot 服务端开启 mTLS

`application.yml`：

```yaml
server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:tls/order-service.p12
    key-store-password: ${TLS_KEYSTORE_PASSWORD}
    key-store-type: PKCS12
    key-alias: order-service
    # 关键三行
    client-auth: need                 # none | want | need
    trust-store: classpath:tls/truststore.p12
    trust-store-password: ${TLS_TRUSTSTORE_PASSWORD}
    trust-store-type: PKCS12
    enabled-protocols: TLSv1.3,TLSv1.2
    ciphers: >-
      TLS_AES_256_GCM_SHA384,
      TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
```

`client-auth` 三个取值的含义：

| 取值 | 行为 | 适用场景 |
| --- | --- | --- |
| `none` | 不要求客户端证书 | 普通 HTTPS |
| `want` | 请求但不强制，有则验证 | **灰度迁移期**，兼容未改造的调用方 |
| `need` | 强制要求，否则握手失败 | 完全零信任，服务间强制 mTLS |

> 迁移技巧：先用 `want` 上线，观察有多少请求不带客户端证书（日志里看 `javax.servlet.request.X509Certificate` 是否为 null），全量改造完再切 `need`。

## 四、客户端如何调用 mTLS 服务

### 1. RestTemplate / WebClient（JVM 侧）

```java
@Configuration
class MtlsHttpClientConfig {

    @Bean
    SslBundle orderServiceBundle() {
        return SslBundle.of(KeyStoreBundle.of(
                KeyStoreBundle.KeyStore.of(
                        new FileSystemResource("/etc/tls/client.p12"), "changeit"),
                KeyStoreBundle.TrustStore.of(
                        new FileSystemResource("/etc/tls/truststore.p12"), "changeit")));
    }

    @Bean
    RestClient restClient(SslBundle orderServiceBundle) {
        var factory = new JdkClientHttpRequestFactory(
                HttpClient.newBuilder()
                        .sslContext(orderServiceBundle.createSslContext())
                        .build());
        return RestClient.builder()
                .requestFactory(factory)
                .baseUrl("https://order-service:8443")
                .build();
    }
}
```

更省事的做法是用 Spring Boot 3.1+ 的 `spring.ssl.bundle`：

```yaml
spring:
  ssl:
    bundle:
      pem:
        order-service:
          keystore:
            certificate: /etc/tls/client.crt
            private-key: /etc/tls/client.key
          truststore:
            certificate: /etc/tls/ca.crt
```

然后在 `RestClient`/`WebClient` 上用 `ServerSpec` 关联 bundle 名称。

### 2. 服务端读取调用方身份

```java
@RestController
class OrderController {

    @GetMapping("/api/orders/{id}")
    public Order get(@PathVariable Long id, HttpServletRequest request) {
        X509Certificate[] certs =
                (X509Certificate[]) request.getAttribute("javax.servlet.request.X509Certificate");
        if (certs == null || certs.length == 0) {
            throw new AccessDeniedException("mTLS client certificate required");
        }
        // 取 SAN 中的 SPIFFE ID 作为服务身份
        String identity = extractSpiffeId(certs[0]);
        if (!"spiffe://cluster.local/ns/prod/sa/user-service".equals(identity)) {
            throw new AccessDeniedException("service not allowed: " + identity);
        }
        return orderService.findById(id);
    }
}
```

### 3. 通过网关透传身份（常见的错误做法与正确做法）

如果网关终结了 mTLS，再往后端走内部 HTTP，**不能简单把身份放在明文 Header 里**（比如 `X-Service-Id: user-service`），否则内网任意服务都能伪造。

正确做法有两条：

- **Header 里放证书原文 + 网关签名**：如 Istio 的 `X-Forwarded-Client-Cert`（XFCC）会带证书哈希，并由网格内的 sidecar 校验；
- **换成短期 Token**：由网关签发一个内部 JWT（有效期 30s~5min，Audience 指向目标服务），后端校验签名。这就是 **OAuth2 Token Exchange / RFC 8693** 的思路。

## 五、证书的生命周期管理

零信任里**证书轮换是常态，不是例外**。

| 环节 | 手段 |
| --- | --- |
| 签发 | cert-manager（K8s）、HashiCorp Vault PKI、SPIRE |
| 分发 | K8s Secret 挂载 / Vault Agent Sidecar 注入 |
| 有效期 | **越短越好**：服务间证书 24h~30d（甚至 1h） |
| 轮换 | 到期前自动重签 + **热加载**，不重启进程 |
| 吊销 | CRL / OCSP，短有效期可降低对吊销的依赖 |
| 审计 | 证书指纹与 SPIFFE ID 入日志，接入 SIEM |

**热加载是个大坑**：Spring Boot 的 SSL 配置在启动时读一次，`SslBundle` 支持 `reload-on-update: true` 后可以监听文件变化重建 `SslContext`；但如果用原生 `SSLContext` 就需要自定义 `SSLContext` 刷新 + `RestClient` 重建。更省心的方案是把轮换交给 sidecar（Envoy/istio-agent），应用只连本地回环端口的明文流量，由 sidecar 负责 mTLS——这也是 Service Mesh 流行的原因。

## 六、方案对比：mTLS / JWT / API Key / OAuth2

| 维度 | mTLS | JWT（内部签发） | API Key | OAuth2 Client Credentials |
| --- | --- | --- | --- | --- |
| 认证对象 | 服务（机器身份） | 服务或用户 | 服务 | 服务/用户 |
| 传输层保护 | ✅ 自带加密 | ❌ 需配合 TLS | ❌ 需配合 TLS | ❌ 需配合 TLS |
| 防重放 | 握手层面天然防 | 需 jti + 时间窗 | 需 nonce + 签名 | 需 jti |
| 密钥泄漏风险 | 私钥不出进程 | 密钥可复制传播 | 密钥明文常驻配置 | 密钥集中管理 |
| 吊销 | 证书吊销 | 黑名单/短有效期 | 重新发 Key | 撤销授权 |
| 运维复杂度 | 高（PKI 全生命周期） | 中 | 低 | 中高 |
| 适用 | **服务间强身份** | 用户态 / 网关到后端 | 第三方开放接口 | 第三方接入授权 |

**常见组合姿势**：外部流量走 OAuth2/OIDC（用户身份）→ 网关校验后签发内部 JWT → 服务间再叠 mTLS（链路加密 + 服务身份）→ 授权策略基于 JWT 的 scope + mTLS 的 SPIFFE ID 双重判断。

## 七、生产踩坑清单

1. **只配了 KeyStore 没配 TrustStore**：握手直接失败，报 `unable to find valid certification path`。
2. **SAN 不匹配**：用 IP 调服务但证书只有 DNS SAN。用 `openssl x509 -in server.crt -noout -text | grep -A1 "Subject Alternative Name"` 检查。
3. **keystore 密码硬编码在 yml**：应该走 K8s Secret / Vault 注入，或用 `spring-boot-jasypt` 加密。
4. **JDK 版本策略不一致**：TLS 1.0/1.1 在 JDK 8u292+ 默认禁用，老客户端会握手失败。
5. **证书过期没有告警**：容器里 `kubectl get secret` 看不出过期时间，要做定时检查：`openssl x509 -enddate -noout -in cert.crt` + Prometheus exporter。
6. **`want` 模式忘切 `need`**：迁移完成后忘记切换，等于内网仍然匿名可调。
7. **用了自签 CA 但没做 CRL**：私钥泄漏后无法及时吊销，只能等过期，所以**短有效期**是必须的补偿手段。
8. **网关透传明文身份 Header**：等于把认证降级成"我说我是谁"，必须签名或换 Token。

## 面试官追问

**Q：mTLS 和 HTTPS 有什么区别？**
HTTPS 通常指单向 TLS，只验证服务端；mTLS 是双向，双方都出示证书。mTLS 也是运行在 TLS 之上的，只是多了客户端证书交换与验证环节。

**Q：为什么用 SAN 而不是 CN 来标识身份？**
RFC 6125 与浏览器/Java 的现代实现都要求主机名匹配基于 SAN；CN 匹配已在 Chrome 58+ 与 JDK 中逐步废弃。SPIFFE 标准也统一用 URI 型 SAN 承载服务身份。

**Q：证书轮换时如何做到零中断？**
三条路：① sidecar/SDS 动态推送证书（Istio 方案）；② 应用内监听证书文件变化并重建 `SSLContext`（`SslBundle reload-on-update`）；③ 双证书并行——新证书先在服务端信任列表里生效，客户端切换后再移除旧证书。顺序原则是"**先信任新、再切换用新、最后移除旧**"。

**Q：mTLS 能替代授权吗？**
不能。mTLS 只解决**认证**（你是谁）和**通道加密**，不解决**授权**（你能干什么）。一个被攻破的服务持有合法证书，仍可能越权访问所有服务。所以还需要服务级授权策略（Istio AuthorizationPolicy / OPA / 应用内 RBAC）和最小权限设计。

## 总结

零信任不是买一个产品，而是一组工程实践：

1. **身份先行**：给每个服务一个密码学身份（SPIFFE/证书/SAN）；
2. **默认加密**：内网东西向流量强制 TLS，服务间强制 mTLS（`client-auth: need`）；
3. **凭据短命**：证书/Token 短有效期 + 自动轮换 + 可吊销；
4. **授权独立**：认证解决"是谁"，授权解决"能干什么"，两者不能混为一谈；
5. **可观测**：身份（SPIFFE ID / 证书指纹）必须进日志与链路追踪，否则出事无从溯源。
