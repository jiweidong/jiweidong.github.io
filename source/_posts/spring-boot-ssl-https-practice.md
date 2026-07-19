---
title: 【运维实战】Spring Boot 生产级 HTTPS/SSL 配置全指南：证书管理与最佳实践
date: 2026-07-19 08:00:00
tags:
  - Spring Boot
  - HTTPS
  - SSL
  - 安全
  - 证书
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【运维实战】Spring Boot 生产级 HTTPS/SSL 配置全指南：证书管理与最佳实践

## 一、为什么要给 Spring Boot 配置 HTTPS？

在当今的 Web 生态中，HTTPS 已经不再是"可选项"，而是"必选项"：

- **安全性**：防止中间人攻击（MITM），确保数据传输加密
- **浏览器强制**：Chrome 将 HTTP 标记为"不安全"
- **合规要求**：等保 2.0、PCI-DSS、GDPR 均要求传输加密
- **接口要求**：微信小程序、苹果 App Transport Security 均要求 HTTPS
- **SEO 加分**：Google 将 HTTPS 作为搜索排名因素

Spring Boot 内嵌了 Tomcat、Jetty 或 Undertow 容器，配置 HTTPS 完全可以在应用层完成，不需要额外的反向代理（当然，生产环境通常配合 Nginx 做 SSL 终结）。

## 二、SSL/TLS 基础概念速览

### 2.1 核心术语

| 术语 | 含义 |
|-----|------|
| SSL/TLS | 传输层安全协议，SSL 是前身（已弃用），TLS 是标准 |
| X.509 证书 | 数字证书的标准格式，包含公钥、身份信息、签名等 |
| CSR | 证书签名请求（Certificate Signing Request），向 CA 申请证书时使用 |
| CA | 证书颁发机构（Certificate Authority），如 Let's Encrypt、DigiCert |
| 自签名证书 | 自己签发的证书，适合开发测试，不被浏览器信任 |
| PKCS12 | 一种密钥库格式（.p12/.pfx），Java 常用的证书存储格式 |
| KeyStore | Java 密钥库，存储私钥和证书（JKS / PKCS12） |
| TrustStore | 信任库，存储受信任的 CA 证书 |

### 2.2 TLS 握手过程（简化版）

```
客户端                            服务端
  │──── ClientHello ────────────→│
  │←── ServerHello + 证书 + ... ─│
  │──── 验证证书, 生成预主密钥 ──→│
  │←── 完成握手, 开始加密通信 ────│
```

关键的验证环节：
1. **证书链验证**：客户端的 TrustStore 必须包含签发服务端证书的 CA 根证书
2. **域名验证**：证书中的 CN/SAN 必须与访问域名匹配
3. **有效期验证**：证书必须在有效期内
4. **吊销检查**：可选，通过 CRL/OCSP 检查证书是否被吊销

## 三、Spring Boot HTTPS 配置实战

### 3.1 准备证书

#### 方式一：自签名证书（开发环境）

```bash
# 使用 JDK 自带的 keytool 生成自签名证书
keytool -genkeypair \
  -alias myserver \
  -keyalg RSA \
  -keysize 2048 \
  -validity 365 \
  -keystore keystore.p12 \
  -storetype PKCS12 \
  -storepass changeit \
  -dname "CN=localhost, OU=Dev, O=Company, L=Beijing, ST=Beijing, C=CN" \
  -ext SAN=DNS:localhost,IP:127.0.0.1
```

参数说明：
- `-keyalg RSA -keysize 2048`：使用 RSA 2048 位密钥（生产环境建议 4096）
- `-validity 365`：有效期 365 天
- `-storetype PKCS12`：推荐使用 PKCS12 格式（JKS 已过时）
- `-ext SAN`：Subject Alternative Name，指定域名和 IP

#### 方式二：Let's Encrypt 免费证书（生产环境推荐）

```bash
# 安装 certbot
apt install certbot

# 获取证书（需要 80 端口可访问）
certbot certonly --standalone -d yourdomain.com -d www.yourdomain.com

# 证书位置：
# /etc/letsencrypt/live/yourdomain.com/fullchain.pem
# /etc/letsencrypt/live/yourdomain.com/privkey.pem

# 转换为 PKCS12 格式
openssl pkcs12 -export \
  -in fullchain.pem \
  -inkey privkey.pem \
  -out keystore.p12 \
  -name mydomain \
  -password pass:changeit
```

#### 方式三：从 CA 购买证书

从 DigiCert、GlobalSign、Symantec 等 CA 购买证书后，通常你会收到：
- `yourdomain.crt`（服务器证书）
- `yourdomain.key`（私钥）
- `ca-bundle.crt`（中间 CA 证书链）

使用 OpenSSL 将其合并为 PKCS12：

```bash
# 先合并证书链
cat yourdomain.crt ca-bundle.crt > fullchain.crt

# 转为 PKCS12
openssl pkcs12 -export \
  -in fullchain.crt \
  -inkey yourdomain.key \
  -out keystore.p12 \
  -name tomcat \
  -password pass:changeit
```

### 3.2 配置 application.yml

```yaml
server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:keystore.p12
    key-store-password: changeit
    key-store-type: PKCS12
    key-alias: myserver
    # 如果只想用 TLS 1.2 和 1.3（推荐禁用 1.0/1.1）
    enabled-protocols: TLSv1.2,TLSv1.3
    # 自定义加密套件（可选，通常用默认即可）
    ciphers: TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256
```

### 3.3 HTTP 自动跳转 HTTPS

生产环境中通常需要把 80 端口的 HTTP 请求自动 301 跳转到 HTTPS：

```java
@Configuration
public class HttpsRedirectConfig {
    
    @Bean
    public TomcatServletWebServerFactory servletContainer() {
        TomcatServletWebServerFactory factory = new TomcatServletWebServerFactory() {
            @Override
            protected void postProcessContext(Context context) {
                SecurityConstraint constraint = new SecurityConstraint();
                constraint.setUserConstraint("CONFIDENTIAL");
                SecurityCollection collection = new SecurityCollection();
                collection.addPattern("/*");
                constraint.addCollection(collection);
                context.addConstraint(constraint);
            }
        };
        
        // 监听 80 端口，重定向到 443
        factory.addAdditionalTomcatConnectors(createHttpConnector());
        return factory;
    }
    
    private Connector createHttpConnector() {
        Connector connector = new Connector(TomcatServletWebSocketEngine.NIO_PROTOCOL);
        connector.setScheme("http");
        connector.setPort(8080);
        connector.setSecure(false);
        connector.setRedirectPort(8443);
        return connector;
    }
}
```

### 3.4 配置双向 TLS（mTLS）

在某些高安全场景（如金融机构内部通信），需要客户端也提供证书进行验证：

```yaml
server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:server-keystore.p12
    key-store-password: changeit
    key-store-type: PKCS12
    # 客户端证书验证
    client-auth: need  # need = 强制客户端证书, want = 可选
    trust-store: classpath:client-truststore.p12
    trust-store-password: changeit
    trust-store-type: PKCS12
```

### 3.5 编程式获取客户端证书信息

```java
@RestController
public class CertInfoController {
    
    @GetMapping("/api/client-cert")
    public Map<String, Object> getClientCert(HttpServletRequest request) {
        // 获取客户端证书链
        X509Certificate[] certs = (X509Certificate[]) 
            request.getAttribute("javax.servlet.request.X509Certificate");
        
        if (certs == null || certs.length == 0) {
            return Map.of("error", "No client certificate");
        }
        
        X509Certificate clientCert = certs[0];
        return Map.of(
            "subject", clientCert.getSubjectX500Principal().getName(),
            "issuer", clientCert.getIssuerX500Principal().getName(),
            "serialNumber", clientCert.getSerialNumber().toString(),
            "notBefore", clientCert.getNotBefore().toString(),
            "notAfter", clientCert.getNotAfter().toString(),
            "san", clientCert.getSubjectAlternativeNames()
        );
    }
}
```

### 3.6 在配置类中管理 SSLContext

对于需要自定义 SSL 的客户端（如 RestTemplate、WebClient），需要显式创建 SSLContext：

```java
@Configuration
public class RestTemplateConfig {
    
    @Bean
    public RestTemplate restTemplate() throws Exception {
        // 从 KeyStore 加载
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (InputStream is = new ClassPathResource("keystore.p12").getInputStream()) {
            keyStore.load(is, "changeit".toCharArray());
        }
        
        SSLContext sslContext = SSLContextBuilder
            .create()
            .loadKeyMaterial(keyStore, "changeit".toCharArray())
            .loadTrustMaterial(keyStore, (cert, authType) -> true)
            .build();
        
        CloseableHttpClient httpClient = HttpClients.custom()
            .setSSLContext(sslContext)
            .build();
        
        HttpComponentsClientHttpRequestFactory factory = 
            new HttpComponentsClientHttpRequestFactory(httpClient);
        
        return new RestTemplate(factory);
    }
}
```

## 四、生产环境最佳实践

### 4.1 Nginx 做 SSL 终结 + Spring Boot 内部 HTTP

这是最常见的生产架构：Nginx 处理 SSL，内部转发 HTTP 到 Spring Boot：

```
用户 ──HTTPS──→ Nginx(:443) ──HTTP──→ Spring Boot(:8080)
```

```nginx
server {
    listen 443 ssl http2;
    server_name yourdomain.com;
    
    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    
    # 安全的 SSL 配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # HSTS 头（强制浏览器始终使用 HTTPS）
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# HTTP 跳转 HTTPS
server {
    listen 80;
    server_name yourdomain.com;
    return 301 https://$server_name$request_uri;
}
```

Spring Boot 端只需关注 HTTP：

```yaml
server:
  port: 8080
# 不需要任何 SSL 配置
# 但要正确处理 Forwarded 头，确保重定向使用 HTTPS
server:
  forward-headers-strategy: nature  # 或 framework
```

### 4.2 证书自动续期（Let's Encrypt + ACME）

```bash
# 安装 certbot
apt install certbot python3-certbot-nginx

# 自动续期（通过 cron 每天执行）
echo "0 3 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx" \
  | crontab -
```

### 4.3 使用 SSL 评估工具检查配置

部署后务必用以下工具检查：
- **SSL Labs**：https://www.ssllabs.com/ssltest/
- **SSL Checker**：https://www.sslshopper.com/ssl-checker.html
- **本地测试**：`openssl s_client -connect yourdomain.com:443 -tls1_2`

### 4.4 安全头配置

Spring Boot 中配置安全响应头：

```java
@Configuration
public class SecurityHeaderConfig implements WebServerFactoryCustomizer<TomcatServletWebServerFactory> {
    
    @Override
    public void customize(TomcatServletWebServerFactory factory) {
        factory.addContextCustomizers(context -> {
            context.addServletContainerInitializer(
                (c, ctx) -> {
                    ctx.setResponseCharacterEncoding("UTF-8");
                }, null);
        });
    }
}
```

配合 Spring Security 添加安全头：

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {
    
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .headers(headers -> headers
                .httpStrictTransportSecurity(hsts -> hsts
                    .maxAgeInSeconds(31536000)
                    .includeSubDomains(true)
                )
                .contentSecurityPolicy(csp -> csp
                    .policyDirectives("default-src 'self'")
                )
                .xssProtection(xss -> xss
                    .block(true)
                )
                .contentTypeOptions(Customizer.withDefaults())
            );
        return http.build();
    }
}
```

## 五、常见问题排查

| 问题 | 原因 | 解决方案 |
|-----|------|---------|
| `PKIX path building failed` | 客户端 TrustStore 不包含服务端证书链的 CA | 导入 CA 根证书到 TrustStore |
| `No subject alternative names present` | 证书的 SAN 不包含访问域名 | 重新生成包含 SAN 的证书 |
| `SSLHandshakeException: No appropriate protocol` | 服务端和客户端没有共同的协议版本 | 确保 `enabled-protocols` 包含双方都支持的版本 |
| `Connection refused` | 端口被防火墙阻断或端口已被占用 | `netstat -tlnp | grep 8443` 检查 |
| 浏览器报"证书无效" | 自签名证书未被信任 | 使用 Let's Encrypt 或商业 CA |

## 六、单测验证 SSL 配置

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class SslConfigurationTest {
    
    @LocalServerPort
    private int port;
    
    @Test
    void testHttpsWorks() throws Exception {
        // 创建信任所有证书的 TrustManager（仅用于测试）
        TrustManager[] trustAll = new TrustManager[]{
            new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] c, String a) {}
                public void checkServerTrusted(X509Certificate[] c, String a) {}
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }
        };
        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(null, trustAll, new SecureRandom());
        
        URL url = new URL("https://localhost:" + port + "/actuator/health");
        HttpsURLConnection conn = (HttpsURLConnection) url.openConnection();
        conn.setSSLSocketFactory(sslContext.getSocketFactory());
        conn.setHostnameVerifier((host, session) -> true);
        
        assertEquals(200, conn.getResponseCode());
    }
}
```

## 七、面试常见追问

> **面试官：KeyStore 和 TrustStore 的区别是什么？**

**答：** KeyStore 存储**自己的身份**（私钥 + 证书），通常在服务端用于向客户端证明自己是合法的；TrustStore 存储**信任的第三方**（CA 根证书），用于验证对方证书的合法性。在 SSL 握手过程中，服务端从 KeyStore 取自己的证书发给客户端，客户端用 TrustStore 里的 CA 证书验证服务端证书的签名。

---

> **面试官：Spring Boot 使用 Nginx 做 SSL 终结和直接在 Spring Boot 中配置 SSL 各有什么优缺点？**

**答：** 
- **Nginx 终结**：性能更好（Nginx 的 SSL engine 高度优化）、证书管理集中、便于多应用共享 IP 和证书、可配合 Nginx 的其他功能（限流、缓存、WAF）。但会增加一跳网络延迟（通常很小）。
- **应用层配置**：架构更简单、不依赖额外组件、便于容器化部署（K8s Ingress 也可以终结 SSL）。但 SSL 卸载会消耗应用服务器的 CPU。

生产环境通常推荐 Nginx/K8s Ingress 终结 SSL。只有在小型部署或测试环境才直接让 Spring Boot 处理 HTTPS。

---

> **面试官：TLS 1.0 和 TLS 1.1 为什么被禁用？**

**答：** TLS 1.0 和 1.1 使用了较弱的加密算法和过时的协议设计，存在已知安全漏洞（如 POODLE、BEAST、Lucky13 攻击）。PCI-DSS 等合规标准也要求禁用。TLS 1.2（2008年）和 1.3（2018年）是目前的安全基线，TLS 1.3 还通过 1-RTT 握手大幅减少了延迟。

---

## 八、总结

Spring Boot 配置 HTTPS 的核心步骤：

1. 准备证书（自签名 / Let's Encrypt / 商业 CA）
2. 转换为 PKCS12 格式
3. 配置 `server.ssl.*` 属性
4. 可选：配置 HTTP→HTTPS 跳转
5. 生产环境推荐 Nginx 做 SSL 终结
6. 启用 HSTS、配置安全头
7. 设置证书自动续期

HTTPS 配置是每个后端开发者的基本功。掌握了这些，无论你是部署个人博客还是企业级应用，都能确保通信安全。
