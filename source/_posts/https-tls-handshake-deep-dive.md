---
title: 【网络与安全】HTTPS 与 TLS 握手深度解析：从 RSA 密钥交换到 TLS 1.3 的加密之旅
date: 2026-08-24 09:00:00
tags:
  - 网络
  - 安全
  - HTTPS
  - 面试
categories:
  - 网络
  - 安全
author: 东哥
---

# 【网络与安全】HTTPS 与 TLS 握手深度解析：从 RSA 密钥交换到 TLS 1.3 的加密之旅

## 面试官：HTTPS 到底比 HTTP 安全在哪？

HTTP 是明文传输，存在三大风险：**窃听**（数据被截获可读）、**篡改**（中间人改数据）、**冒充**（伪装成目标服务器）。HTTPS = HTTP + TLS（传输层安全协议），通过四层手段解决：

| 风险 | 解决手段 | 用的密码学技术 |
| --- | --- | --- |
| 窃听 | 机密性 | 对称加密（会话密钥） |
| 篡改 | 完整性 | MAC / HMAC 消息认证码 |
| 冒充 | 身份认证 | 数字证书 + 非对称签名 |
| 重放攻击 | 抗重放 | 随机数 + 序列号 |

一个常见的误区：**HTTPS 并不是全程用非对称加密**。非对称加密太慢，实际方案是「非对称加密握手换密钥，对称加密传输数据」——握手阶段协商出一个会话密钥，之后所有业务数据都用对称加密（AES-GCM 等）快速加解密。

## 密码学地基：三块砖

### 1. 对称加密
同一个密钥加密和解密。代表：AES、ChaCha20。**问题**：密钥怎么安全地送到对方手里？

### 2. 非对称加密
公钥加密、私钥解密（或反之）。代表：RSA、ECDSA、SM2。**问题**：慢，且有中间人冒充风险——你怎么确定拿到的公钥真的是对方的？

### 3. 数字签名与证书
用 CA（证书颁发机构）给服务器的公钥「盖章」：CA 用自己的私钥对「服务器公钥 + 域名等信息」做签名，生成证书。客户端用**系统内置的 CA 公钥（信任锚）**验证证书签名，从而信任证书里的服务器公钥。这就是**证书链**：根证书 → 中间 CA 证书 → 服务器证书。

```bash
# 用 openssl 查看一个网站的证书链
openssl s_client -connect www.baidu.com:443 -showcerts 2>/dev/null | head -30
```

## TLS 1.2 握手流程（重点！）

TLS 1.2 有两种主流密钥交换方式：**RSA 密钥交换**（旧，已被弃用）和 **ECDHE 密钥交换**（现代标配）。这里以 ECDHE 为例讲完整流程：

```
客户端                                 服务器
  │ 1. ClientHello                      │
  │    支持的 TLS 版本、加密套件、随机数 │
  │ ───────────────────────────────────→ │
  │                                      │
  │ 2. ServerHello                       │
  │    选定的版本/套件、服务器随机数     │
  │ 3. Certificate（服务器证书+证书链）  │
  │ 4. ServerKeyExchange（ECDHE 参数）   │
  │ 5. ServerHelloDone                   │
  │ ←─────────────────────────────────── │
  │                                      │
  │ 6. 验证证书链 ✓                      │
  │ 7. ClientKeyExchange（ECDHE 参数）   │
  │ 8. 双方各自算出相同的预主密钥        │
  │    再派生出会话密钥                  │
  │ ───────────────────────────────────→ │
  │ 9. ChangeCipherSpec + Finished       │
  │ ←─────────────────────────────────── │
  │ 10. ChangeCipherSpec + Finished      │
  │ ───────────────────────────────────→ │
  │ 开始用会话密钥加密传输业务数据       │
```

关键点逐个拆：

- **随机数**：ClientHello 和 ServerHello 各带一个随机数，用于防止重放攻击和参与密钥派生；
- **ECDHE 密钥交换**：双方交换椭圆曲线 DH 的公开参数，各自算出同一个预主密钥。即使攻击者截获全部握手报文，也算不出私钥（离散对数难题）——这保证了**前向保密（Forward Secrecy）**：即使服务器私钥泄露，历史流量也无法解密；
- **为什么弃用 RSA 密钥交换**：RSA 模式是用服务器公钥直接加密预主密钥，一旦服务器私钥泄露，所有历史会话都能被解密，**没有前向保密**；
- **Finished 消息**：对前面所有握手消息做 MAC，双方互相验证，防止握手过程被篡改。

## TLS 1.3：一次握手搞定

TLS 1.3（RFC 8446，2018 年）做了大幅简化：

| 对比项 | TLS 1.2 | TLS 1.3 |
| --- | --- | --- |
| 握手往返 | 2-RTT | 1-RTT（首次） |
| 再次连接 | 1-RTT（会话恢复） | 0-RTT（可以带数据） |
| 密钥交换 | RSA / ECDHE / DHE | 仅 ECDHE（强制前向保密） |
| 加密套件 | 上百种组合 | 仅 5 种 AEAD 套件 |
| RSA 密钥交换 | 支持 | **移除** |
| 握手加密 | 明文 | 全程加密（包括证书） |

TLS 1.3 把「密钥协商」提前到第一条消息：ClientHello 里直接带上 ECDHE 参数，服务器回复 ServerHello 时参数也一并返回，双方**一个往返**就能算出会话密钥。0-RTT 更是把上次会话的密钥恢复用起来，首次请求就能带数据，代价是牺牲部分安全性（有重放风险，仅用于幂等请求）。

## Java 实战：客户端与服务端

### 1. 客户端信任证书：truststore
JVM 用 `cacerts`（位于 `$JAVA_HOME/lib/security/cacerts`）作为信任库。自签名证书或内网 CA 证书需要导入：

```bash
keytool -importcert -alias myca -file myca.crt \
  -keystore $JAVA_HOME/lib/security/cacerts -storepass changeit
```

或者运行时指定（推荐，不动全局）：

```bash
java -Djavax.net.ssl.trustStore=/path/truststore.jks \
     -Djavax.net.ssl.trustStorePassword=changeit -jar app.jar
```

### 2. 代码层面控制 TLS 版本
Java 8 默认支持到 TLS 1.2；**JDK 8u261 之后、JDK 11+ 默认启用 TLS 1.3**（JDK 11 的 JEP 332 引入 TLS 1.3）。

```java
// 显式指定 TLS 版本，避免弱协议
System.setProperty("https.protocols", "TLSv1.3,TLSv1.2");

// 或对 HttpsURLConnection 单独设置
HttpsURLConnection conn = (HttpsURLConnection) url.openConnection();
conn.setSSLSocketFactory(sslContext.getSocketFactory());
```

### 3. 自定义 SSLContext（对接自签名证书）
```java
KeyStore ks = KeyStore.getInstance("JKS");
try (InputStream in = Files.newInputStream(Paths.get("truststore.jks"))) {
    ks.load(in, "changeit".toCharArray());
}
TrustManagerFactory tmf = TrustManagerFactory.getInstance(
        TrustManagerFactory.getDefaultAlgorithm());
tmf.init(ks);

SSLContext ctx = SSLContext.getInstance("TLS");
ctx.init(null, tmf.getTrustManagers(), new SecureRandom());
```

**强烈警告**：网上流传的「信任所有证书」代码（自定义 X509TrustManager 全部返回 true）**严禁用于生产**——等于把 HTTPS 降级成明文，中间人攻击畅通无阻。只可用于本地调试。

### 4. Spring Boot 配置 HTTPS
```yaml
server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:keystore.p12
    key-store-type: PKCS12
    key-store-password: changeit
    key-alias: myserver
    protocol: TLS
```

## 面试追问环节

**Q1：什么是前向保密？**
即使服务器长期私钥泄露，已捕获的历史密文也无法解密。实现方式是 ECDHE：每次会话的临时密钥独立派生，与长期私钥无关。TLS 1.3 强制要求。

**Q2：证书过期/域名不匹配会怎样？**
客户端握手直接失败（`PKIX path building failed` / `SSLHandshakeException`），浏览器显示「不安全」。内部系统要提前续期，现在 Let's Encrypt 免费证书有效期 90 天，务必自动化续期。

**Q3：HTTPS 性能开销大吗？**
一次 TLS 1.3 握手约 1-RTT，且现代 CPU 有 AES-NI 硬件加速，对称加密开销极小（<5%）。主要开销在握手，所以有**会话复用**（Session Ticket）和 **HTTP/2 多路复用**来摊薄成本。实际生产中 HTTPS 性能完全可接受。

**Q4：为什么 TLS 1.3 移除 RSA 密钥交换？**
没有前向保密 + 兼容性包袱太重（加密套件组合爆炸）。现代密码学实践要求默认安全，宁可少功能也不能留后门。

**Q5：国密 SSL（GMTLS）和标准 TLS 什么关系？**
国密 SSL 是中国的 TLS 标准（GB/T 38636-2020），使用 SM2 签名、SM4 对称加密、SM3 摘要，用于金融、政务等合规场景。原理与 TLS 同构，只是替换了密码套件。

## 总结

- HTTPS = HTTP + TLS，非对称换密钥、对称传数据；
- 证书链解决「公钥是谁的」问题，信任锚在系统内置；
- TLS 1.2 的 ECDHE 模式提供前向保密，TLS 1.3 强制 ECDHE 并压缩到 1-RTT/0-RTT；
- Java 侧关注 truststore 导入、TLS 版本、禁止「信任所有证书」；
- 排障用 `openssl s_client`、`keytool -printcert`、`-Djavax.net.debug=ssl:handshake`。

网络层是后端面试的必考区，把握手流程画出来讲清楚，面试官很难不给高分。
