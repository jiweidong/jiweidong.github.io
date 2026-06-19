---
title: OAuth 2.0 与 OpenID Connect 认证授权协议深度解析
date: 2026-06-17 08:15:00
tags:
  - OAuth2
  - OpenID Connect
  - JWT
  - 认证授权
  - Spring Security
categories:
  - 安全
author: 东哥
---

# OAuth 2.0 与 OpenID Connect 认证授权协议深度解析

## 一、引言：为什么需要 OAuth 2.0？

回想 2000 年代初的互联网，几乎所有网站都自己管理用户名密码。随着「第三方登录」的需求出现——用户希望用 Google/微信/GitHub 身份登录其他应用——但直接分享密码显然不可行。

**OAuth 2.0 的核心思想**是：令牌（Token）代替密码，授权与认证分离。

在深入理解 OAuth 2.0 之前，我们先厘清几个关键术语：

| 术语 | 英文 | 说明 |
|------|------|------|
| 资源所有者 | Resource Owner | 用户本人，拥有数据的所有权 |
| 客户端 | Client | 需要获取访问权限的第三方应用 |
| 授权服务器 | Authorization Server | 颁发令牌的服务器，如微信开放平台 |
| 资源服务器 | Resource Server | 存储受保护资源的 API 服务 |
| 访问令牌 | Access Token | 客户端访问资源的凭证 |
| 刷新令牌 | Refresh Token | 用于获取新的 Access Token 的凭证 |

> **注意**：OAuth 2.0 本身是**授权协议**，不是认证协议。它只解决"你能访问什么"，不解决"你是谁"。认证需要靠 OpenID Connect 来补充，我们会在后半段详细展开。

---

## 二、OAuth 2.0 四种授权模式详解

OAuth 2.0 定义了四种授权模式（Grant Types），分别适用不同的客户端场景。

### 2.1 授权码模式（Authorization Code）

这是功能最完整、安全性最高的模式，也是目前最主流的方式。

**流程图如下：**

```
┌────────┐     ① 授权请求（含 redirect_uri）     ┌─────────────┐
│        │ ────────────────────────────────────▶ │              │
│  用户  │                                        │  Authorization│
│        │ ◀────────────────────────────────────  │    Server    │
│ (浏览器)│     ② 用户认证 + 授权确认              │              │
│        │                                        │              │
│        │     ③ 授权码（code）                    │              │
│        │ ◀────────────────────────────────────  │              │
└────────┘                                        └──────────────┘
     │                                                  │
     │ ④ 传递 code                                  ⑤ code + client_secret
     ▼                                                  ▼
┌────────┐                                        ┌─────────────┐
│  Client │     ⑥ Access Token + Refresh Token     │  Token      │
│  (后端)  │ ◀────────────────────────────────────  │  Endpoint   │
│         │                                        │             │
│ ⑦ 用 Token 访问资源                               └─────────────┘
│         │                                               ▲
│         ▼                                               │
│  ┌────────────┐    ⑧ 返回受保护资源                      │
│  │  Resource  │ ◀────────────────────────────────────────┘
│  │  Server    │
│  └────────────┘
```

**详细请求示例：**

**第①步：构造授权请求**

```http
GET https://auth-server.com/authorize?
    response_type=code
    &client_id=app123
    &redirect_uri=https://myapp.com/callback
    &scope=openid%20profile%20email
    &state=xyz123
    &code_challenge=Yjk4Yz...  // PKCE 扩展
    &code_challenge_method=S256
```

**第③步：授权服务器返回授权码**

```http
HTTP/1.1 302 Found
Location: https://myapp.com/callback?code=A1b2C3d4E5f6&state=xyz123
```

**第⑤步：后端用授权码换取令牌**

```http
POST https://auth-server.com/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=A1b2C3d4E5f6
&redirect_uri=https://myapp.com/callback
&client_id=app123
&client_secret=secret456
```

**第⑥步：响应令牌**

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "def456ghi789",
  "id_token": "eyJraWQiOiIxZTlnZ...",
  "scope": "openid profile email"
}
```

**为什么 state 参数重要？**

`state` 参数用于防止 CSRF 攻击。客户端在发起请求时生成一个随机值，回调时验证该值是否一致。如果攻击者伪造了授权回调，客户端能立刻识别。

### 2.2 简化模式（Implicit）

> **已淘汰！** OAuth 2.1 已正式移除该模式。

简化模式原本为纯前端 SPA 应用设计，直接返回 Access Token，省略了授权码交换步骤。但安全缺陷明显——Token 暴露在 URL Fragment 中，浏览历史、Referer Header 都可能泄露令牌。

**替代方案**：SPA 应使用授权码模式 + PKCE。

### 2.3 密码模式（Resource Owner Password Credentials）

用户直接将用户名密码交给客户端，客户端携带去授权服务器换取 Token。

```http
POST https://auth-server.com/token
Content-Type: application/x-www-form-urlencoded

grant_type=password
&username=user@example.com
&password=pass123
&client_id=app123
&client_secret=secret456
```

**安全风险**：客户端直接接触用户密码，完全违背了 OAuth 设计的初衷。仅在**高度信任**的场景下使用（如第一方官方 App 的登录）。OAuth 2.1 同样将其移除。

### 2.4 客户端凭证模式（Client Credentials）

适用于**机器对机器**（M2M）的场景，没有用户参与，只有客户端自身需要访问资源。

```http
POST https://auth-server.com/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=serviceA
&client_secret=secret789
&scope=read%20write
```

**典型场景**：
- 微服务间的内部 RPC 调用
- 后端定时任务的 API 访问
- 批处理系统的数据同步

---

## 三、PKCE：授权码模式的增强

PKCE（Proof Key for Code Exchange，读作 "pixie"）是授权码模式的安全增强，专门解决客户端无法安全持有 `client_secret` 的问题。

### PKCE 流程

```
1. 客户端生成一个随机字符串 code_verifier（43-128 个 ASCII 字符）
2. 计算 code_challenge = SHA256(code_verifier)
3. 授权请求中携带 code_challenge 和 code_challenge_method=S256
4. 授权码回调后，用 code_verifier 去换取 Token
5. 授权服务器验证 code_verifier 是否与之前注册的 code_challenge 匹配
```

**客户端代码实现：**

```typescript
// TypeScript 实现 PKCE 流程
class PKCEGenerator {

    /**
     * 生成 Code Verifier：43-128 个 URL 安全字符
     */
    static generateVerifier(): string {
        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
                      'abcdefghijklmnopqrstuvwxyz0123456789-._~';
        const array = new Uint8Array(64);
        crypto.getRandomValues(array);

        return Array.from(array)
            .map(b => chars[b % chars.length])
            .join('');
    }

    /**
     * 计算 Code Challenge (SHA256 base64url 编码)
     */
    static async computeChallenge(verifier: string): Promise<string> {
        const encoder = new TextEncoder();
        const data = encoder.encode(verifier);
        const hash = await crypto.subtle.digest('SHA-256', data);

        // URL 安全的 Base64 编码（移除 = 填充）
        return btoa(String.fromCharCode(...new Uint8Array(hash)))
            .replace(/\+/g, '-')
            .replace(/\//g, '_')
            .replace(/=+$/, '');
    }
}

// 使用示例
const verifier = PKCEGenerator.generateVerifier();
const challenge = await PKCEGenerator.computeChallenge(verifier);

// 存储在 localStorage 中，回调后用于验证
sessionStorage.setItem('code_verifier', verifier);

// 授权请求 URL
const authUrl =
    `https://auth.example.com/authorize?` +
    `response_type=code&` +
    `client_id=spa-client&` +
    `redirect_uri=${encodeURIComponent(redirectUri)}&` +
    `code_challenge=${challenge}&` +
    `code_challenge_method=S256&` +
    `state=${state}`;
```

**为什么 PKCE 是安全的？** 即使攻击者截获了授权码，如果没有 `code_verifier`，也无法换取 Access Token。

---

## 四、JWT 深度解析

JWT（JSON Web Token）是目前 OAuth 2.0 + OIDC 中令牌的事实标准。

### 4.1 JWT 结构

JWT 由三个 Base64url 编码的部分组成，用 `.` 分隔：

```
header.payload.signature
```

以 debug 模式查看：

```
# Header
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9

# Payload
eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IuiPnOW4gOW8gCIsImlhdCI6MTUxNjIzOTAyMn0

# Signature
Ew94Qb0g3s2z1uFq8XvF9w...
```

### 4.2 Header 结构

```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "key-id-2026"
}
```

| 字段 | 说明 | 常见值 |
|------|------|--------|
| `alg` | 签名算法，必填 | HS256、RS256、ES256 |
| `typ` | Token 类型 | JWT |
| `kid` | Key ID，用于 JWKS 多密钥验证 | 任意的密钥标识符 |
| `jku` | JWK Set URL | HTTPS URL |

### 4.3 Payload 结构（标准声明）

```json
{
  // 标准注册声明
  "iss": "https://auth.example.com",    // Issuer：令牌签发者
  "sub": "user_abc_123",                // Subject：令牌主体（用户唯一标识）
  "aud": "order-service",               // Audience：令牌接收方
  "exp": 1753030400,                    // Expiration：过期时间（Unix 时间戳）
  "nbf": 1753026800,                    // Not Before：生效时间
  "iat": 1753026800,                    // Issued At：签发时间
  "jti": "token_unique_id_001",         // JWT ID：令牌唯一标识

  // 自定义声明（业务数据）
  "name": "张三",
  "email": "zhangsan@example.com",
  "roles": ["admin", "user"],
  "permissions": ["order:create", "order:read", "report:export"]
}
```

### 4.3 签名算法怎么选？

| 算法 | 类型 | 密钥管理 | 性能 | 安全性 | 推荐场景 |
|------|------|---------|------|--------|---------|
| **HS256** | 对称 | 共享密钥 | ★★★★★ | ★★★ | 单服务、内部微服务（小心密钥泄露） |
| **RS256** | 非对称 | 公钥+私钥 | ★★★★ | ★★★★★ | 跨服务、第三方集成，**最推荐** |
| **ES256** | 非对称 | 椭圆曲线密钥对 | ★★★★ | ★★★★★ | 资源受限设备、移动端 |
| **EdDSA** | 非对称 | Edwards 曲线 | ★★★★★ | ★★★★★ | 新兴标准，性能最优 |

**安全建议**：
- **生产环境使用 RS256**，授权服务器持有私钥签名，资源服务器只持有公钥验签
- 不要使用 `alg: none`
- 解码 JWT 时**必须验证签名**，不能仅做 Base64 解码

### 4.4 Java 中 JWT 签名与验签

```java
// ========== 签发 Token ==========
@Slf4j
@Component
public class JwtTokenProvider {

    private final RSAPrivateKey privateKey;
    private final RSAPublicKey publicKey;

    public JwtTokenProvider() throws Exception {
        // 生产环境应从安全存储加载密钥
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        KeyPair keyPair = generator.generateKeyPair();

        this.privateKey = (RSAPrivateKey) keyPair.getPrivate();
        this.publicKey = (RSAPublicKey) keyPair.getPublic();
    }

    public String generateAccessToken(UserDetails user) {
        Date now = new Date();
        Date expiry = new Date(now.getTime() + 3600_000); // 1小时

        Set<String> roles = user.getAuthorities().stream()
            .map(GrantedAuthority::getAuthority)
            .collect(Collectors.toSet());

        return Jwts.builder()
            .setIssuer("auth-service")
            .setSubject(user.getUsername())
            .setAudience("order-service")
            .setIssuedAt(now)
            .setNotBefore(now)
            .setExpiration(expiry)
            .claim("roles", roles)
            .claim("userId", ((CustomUser) user).getUserId())
            .signWith(privateKey, SignatureAlgorithm.RS256)
            .compact();
    }

    public String generateRefreshToken(UserDetails user) {
        Date now = new Date();
        Date expiry = new Date(now.getTime() + 30L * 24 * 3600_000); // 30天

        return Jwts.builder()
            .setIssuer("auth-service")
            .setSubject(user.getUsername())
            .setId(UUID.randomUUID().toString())
            .setIssuedAt(now)
            .setExpiration(expiry)
            .signWith(privateKey, SignatureAlgorithm.RS256)
            .compact();
    }

    // ========== 验证 Token ==========
    public Claims validateToken(String token) {
        try {
            return Jwts.parserBuilder()
                .setSigningKey(publicKey)
                .requireIssuer("auth-service")
                .build()
                .parseClaimsJws(token)
                .getBody();
        } catch (JwtException | IllegalArgumentException e) {
            log.warn("JWT 验证失败: {}", e.getMessage());
            throw new AuthException("令牌无效或已过期");
        }
    }
}
```

---

## 五、OpenID Connect：在 OAuth 2.0 之上做认证

OAuth 2.0 只关心授权（"你能做什么"），不关心认证（"你是谁"）。OpenID Connect（OIDC）在 OAuth 2.0 之上增加了**身份层**，返回一个 `id_token`（JWT 格式）来明确标识用户身份。

### 5.1 OIDC 核心流程

```
User  ──→  Client  ──→  OP (OpenID Provider)
                          │
                          ├── 签发 id_token（JWT，包含身份信息）
                          ├── 签发 access_token（用于调 userinfo endpoint）
                          └── 返回 refresh_token

Client 解码 id_token 获得用户信息：
{
  "iss": "https://accounts.example.com",
  "sub": "248289761001",                    // 用户唯一标识
  "preferred_username": "zhangsan",
  "email": "zhangsan@example.com",
  "email_verified": true,
  "picture": "https://example.com/avatar.png",
  "updated_at": 1753026800
}
```

### 5.2 OIDC 核心端点

| 端点 | 说明 | 示例 |
|------|------|------|
| `/.well-known/openid-configuration` | 发现端点，返回所有端点 URL | `https://auth.example.com/.well-known/openid-configuration` |
| `/authorize` | 用户授权端点 | 与 OAuth 2.0 共用 |
| `/token` | 令牌签发端点 | 与 OAuth 2.0 共用 |
| `/userinfo` | 获取用户信息的 API | 需要 Access Token 调用 |
| `/jwks.json` | 公钥列表，用于验证 id_token | RS256 使用的公钥集 |

**发现文档示例**：

```json
{
  "issuer": "https://accounts.example.com",
  "authorization_endpoint": "https://accounts.example.com/oauth2/authorize",
  "token_endpoint": "https://accounts.example.com/oauth2/token",
  "userinfo_endpoint": "https://accounts.example.com/oauth2/userinfo",
  "jwks_uri": "https://accounts.example.com/oauth2/jwks",
  "scopes_supported": ["openid", "profile", "email", "address", "phone"],
  "response_types_supported": ["code", "id_token", "code id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256", "ES256"],
  "claims_supported": [
    "sub", "name", "preferred_username", "email",
    "email_verified", "picture", "updated_at"
  }
}
```

### 5.3 id_token 的关键声明

OIDC 在标准 JWT 声明的基础上，规定了额外的 ID Token 声明：

| 声明 | 说明 | 必须 |
|------|------|------|
| `iss` | 签发者 URL，必须与发现文档的 issuer 一致 | ✔ |
| `sub` | 用户在 Issuer 下的唯一标识 | ✔ |
| `aud` | 令牌的目标客户端 ID 数组 | ✔ |
| `exp` | 过期时间 | ✔ |
| `iat` | 签发时间 | ✔ |
| `auth_time` | 用户认证时间 | |
| `nonce` | 防重放攻击，必须与授权请求中的 nonce 一致 | |
| `acr` | 认证上下文参考，如 `urn:mace:incommon:iap:silver` | |
| `amr` | 认证方法引用，如 `["pwd", "otp", "mfa"]` | |

---

## 六、Spring Security + OAuth 2.0 实战集成

### 6.1 引入依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-client</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-security</artifactId>
</dependency>
```

### 6.2 授权服务器配置

这里我们使用 Spring Authorization Server 搭建一个简单的授权服务器：

```java
@Configuration
@EnableAuthorizationServer
public class AuthorizationServerConfig {

    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    public SecurityFilterChain authServerFilterChain(HttpSecurity http) throws Exception {
        OAuth2AuthorizationServerConfiguration.applyDefaultSecurity(http);

        http.getConfigurer(OAuth2AuthorizationServerConfigurer.class)
            .oidc(Customizer.withDefaults()); // 启用 OIDC 支持

        http.oauth2ResourceServer(OAuth2ResourceServerConfigurer::jwt);

        return http.build();
    }

    @Bean
    public RegisteredClientRepository registeredClientRepository() {
        RegisteredClient registeredClient = RegisteredClient.withId(UUID.randomUUID().toString())
            .clientId("order-app")
            .clientSecret("{bcrypt}$2a$10$...")  // BCrypt 编码
            .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
            .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
            .authorizationGrantType(AuthorizationGrantType.REFRESH_TOKEN)
            .authorizationGrantType(AuthorizationGrantType.CLIENT_CREDENTIALS)
            .redirectUri("https://myapp.com/login/oauth2/code/order-app")
            .scope(OidcScopes.OPENID)
            .scope(OidcScopes.PROFILE)
            .scope("order:read")
            .scope("order:write")
            .clientSettings(ClientSettings.builder()
                .requireAuthorizationConsent(true)
                .requireProofKey(true) // PKCE 支持
                .build())
            .tokenSettings(TokenSettings.builder()
                .accessTokenTimeToLive(Duration.ofHours(1))
                .refreshTokenTimeToLive(Duration.ofDays(30))
                .reuseRefreshTokens(false)
                .build())
            .build();

        return new InMemoryRegisteredClientRepository(registeredClient);
    }
}
```

### 6.3 资源服务器配置

```java
@Configuration
@EnableWebSecurity
@EnableGlobalMethodSecurity(prePostEnabled = true)
public class ResourceServerConfig {

    @Value("${auth.jwk-set-uri}")
    private String jwkSetUri;

    @Bean
    public SecurityFilterChain resourceServerFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(authz -> authz
                .antMatchers("/api/public/**").permitAll()
                .antMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt
                    .decoder(jwtDecoder())
                    .jwtAuthenticationConverter(jwtAuthenticationConverter())
                )
            )
            .sessionManagement(session -> session
                .sessionCreationPolicy(SessionCreationPolicy.STATELESS)
            );

        return http.build();
    }

    @Bean
    public JwtDecoder jwtDecoder() {
        return NimbusJwtDecoder.withJwkSetUri(jwkSetUri).build();
    }

    /**
     * 将 JWT claims 转换为 Spring Security 的 Authentication 对象
     */
    @Bean
    public JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter grantedAuthorities = new JwtGrantedAuthoritiesConverter();
        grantedAuthorities.setAuthorityPrefix("ROLE_");
        grantedAuthorities.setAuthoritiesClaimName("roles");

        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(grantedAuthorities);
        return converter;
    }
}
```

### 6.4 方法级权限控制

```java
@RestController
@RequestMapping("/api/orders")
public class OrderController {

    @GetMapping("/list")
    @PreAuthorize("hasAuthority('SCOPE_order:read')")
    public Result listOrders(@AuthenticationPrincipal Jwt jwt) {
        String userId = jwt.getClaimAsString("userId");
        String username = jwt.getClaimAsString("preferred_username");

        return Result.success(orderService.listByUserId(userId));
    }

    @PostMapping("/create")
    @PreAuthorize("hasAuthority('SCOPE_order:write') and #dto.amount <= 10000")
    public Result createOrder(@Valid @RequestBody OrderDTO dto,
                              @AuthenticationPrincipal Jwt jwt) {
        dto.setUserId(jwt.getSubject());
        return Result.success(orderService.create(dto));
    }

    @DeleteMapping("/{orderId}")
    @PreAuthorize("hasRole('ADMIN')")
    public Result cancelOrder(@PathVariable String orderId) {
        return Result.success(orderService.cancel(orderId));
    }
}
```

### 6.5 OAuth 2.1 重要变化

| OAuth 2.0 | OAuth 2.1 | 影响 |
|-----------|-----------|------|
| 隐式模式 | ❌ 移除 | SPA 必用授权码 + PKCE |
| 密码模式 | ❌ 移除 | 改为使用授权码 + 设备码流程 |
| 资源所有者密码 | ❌ 移除 | 无替代，不推荐使用 |
| 授权码 + PKCE | ✅ 必选 | 所有客户端必须使用 PKCE |
| Refresh Token rotation | ✅ 推荐 | 每次刷新后返回新的 Refresh Token |
| Bearer Token 使用 HTTPS | ✅ 必选 | 传输加密不可妥协 |

---

## 七、总结与最佳实践

### 常见安全漏洞与防护

| 攻击类型 | 说明 | 防护措施 |
|---------|------|---------|
| CSRF | 攻击者伪造授权回调 | 使用 state 参数 + nonce 验证 |
| 授权码拦截 | 授权码被截获 | PKCE 确保只有原始客户端能用 |
| Token 泄露 | Access Token 在传输中被截获 | 全链路 HTTPS，Token 有效期短 |
| 重放攻击 | 截获请求重复提交 | nonce、jti + 时间戳窗口 |
| 拒绝服务 | 授权服务器被打满 | 流控、Rate Limit |

### 生产环境 Checklist

1. **所有通信使用 HTTPS**——没有例外
2. **Access Token 有效期短**——15 分钟到 1 小时
3. **Refresh Token 有效期长但可撤销**——配合黑名单或版本号
4. **客户端类型选对模式**——后端用授权码，SPA 用授权码+PKCE，M2M 用客户端凭证
5. **scope 最小化**——只请求需要的最小权限
6. **JWT 必须验证签名**——永远不要 `alg: none`
7. **资源服务器不信任外部 JWT**——必须验证 `iss` 和 `aud`

OAuth 2.0 + OpenID Connect 是当前业界认证授权的事实标准。理解其设计哲学和流程细节，能帮助我们在构建安全系统时做出正确的技术决策。安全没有银弹，但遵循这些协议规范可以让我们站在巨人的肩膀上。
