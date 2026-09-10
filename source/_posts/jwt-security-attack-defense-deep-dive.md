---
title: 【安全实战】JWT 安全攻防深度解析：从算法混淆、密钥泄露到双 Token 刷新与注销黑名单
date: 2026-09-10 08:00:00
tags:
  - JWT
  - 安全
  - Spring Security
  - 认证
categories:
  - Java
  - 安全
  - 后端
author: 东哥
---

# 【安全实战】JWT 安全攻防深度解析：从算法混淆、密钥泄露到双 Token 刷新与注销黑名单

## 面试官：JWT 一定安全吗？token 被别人拿到怎么办？

JWT 不是"防伪标签"，它只是**防篡改**——服务端验签只能证明 token 没被改过，证明不了"持有者就是本人"。市面上 JWT 相关的漏洞（算法混淆、密钥硬编码、无过期时间、无法注销）几乎都是**使用姿势错误**导致的。

本文从 JWT 结构讲起，拆解 5 类真实攻击手法，再给出生产级的双 Token + 黑名单注销方案，最后附 Spring Boot 落地代码。

## 一、JWT 结构回顾

JWT = `Header.Payload.Signature` 三段，Base64Url 编码：

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMDAxIn0.签名部分

Header:   {"alg":"HS256","typ":"JWT"}
Payload:  {"sub":"1001","exp":1770000000,"iat":1769900000}
```

**关键认知**：Header 和 Payload 只是 Base64 编码，**任何人可读**——所以绝不能在 payload 里放密码、手机号等敏感信息（除非额外加密，即 JWE）。Signature 才是安全核心，由服务端私钥/密钥计算。

## 二、五类典型攻击与防御

### 攻击 1：算法混淆攻击（alg=none / RS256→HS256）

这是 JWT 最经典的漏洞，分两种：

**（1）alg: none**——某些老库若未禁用 `none` 算法，攻击者把 alg 改成 `none`、删掉签名，服务端可能直接信任：

```json
// 篡改后的 Header
{"alg":"none","typ":"JWT"}
```

防御：**服务端必须白名单校验 alg**，遇到 `none` 直接拒绝。

**（2）非对称→对称混淆**：服务端用 RSA 公钥验签（RS256），攻击者把 alg 改成 **HS256**（对称 HMAC），并用**公钥内容作为 HMAC 密钥**对 token 重新签名。若服务端校验时只认 alg 不校验密钥类型，就会用公钥字符串当密钥验签 → 伪造成功（经典 CVE-2015-9235，影响大量 JWT 库）。

防御：验签前强制校验 `alg` 必须与预期一致（如只允许 RS256），且**密钥解析严格按类型**：

```java
// 错误示范：拿 alg 去动态选算法
Jwts.parser().parse(token);

// 正确示范：固定算法与密钥
Jwts.parserBuilder()
    .setSigningKey(publicKey)          // 明确 RSA 公钥
    .build().parseClaimsJws(token);    // parseClaimsJws 只接受签名 JWS，拒绝 none
```

### 攻击 2：密钥泄露/弱密钥爆破

HS256 的密钥一旦硬编码进前端或泄露到 GitHub，攻击者可以任意伪造 token。更常见的是**弱密钥**：网上有公开的 jwt 弱密钥字典（如 `secret`、`123456`），用 hashcat 秒破。

防御：
- 密钥强度 ≥ 256 bit 随机数，**禁止硬编码**，放环境变量/KMS/配置中心加密存储；
- 优先用 **RS256/ES256 非对称算法**：私钥只在服务端，公钥才下发（如 jwks 端点），泄露公钥不影响安全；
- 定期轮换密钥，轮换期间用 `kid`（Key ID）支持多密钥共存验证。

### 攻击 3：token 窃取（XSS/日志泄露）与重放

JWT 存 localStorage 被 XSS 一锅端；token 打在全链路日志里被运维/第三方看到；HTTPS 缺失导致中间人抓包重放。

防御：
- 存 **httpOnly + Secure + SameSite Cookie**（防 JS 读取）而非 localStorage；
- 日志框架对 Authorization 头**脱敏**（只打前几位）；
- 全链路 HTTPS；
- 敏感操作（改密、支付）要求**二次校验**（密码/验证码），即使 token 被重放也无法直接操作。

### 攻击 4：无过期/超长过期 token

JWT 一旦签发**无法主动失效**（无状态），过期时间越长风险越大。有人把 exp 设成一年甚至不设。

防御：access token 有效期控制在 **15 分钟 ~ 2 小时**，配合 refresh token 续期（见下节）。

### 攻击 5：注销失效（登出无效）

服务端不存状态，`logout` 接口只是前端删 token——被偷的 token 依然有效。

防御：引入**黑名单/版本号机制**（见下节），登出、改密、封号时让旧 token 立即失效。

## 三、生产级方案：双 Token + 黑名单

无状态是 JWT 的优点，但安全场景需要"可控失效"。业界标准做法是 **access token（短命、无状态） + refresh token（长命、可吊销）**：

| 维度 | Access Token | Refresh Token |
|---|---|---|
| 有效期 | 15min ~ 2h | 7 ~ 30 天 |
| 存储 | 前端内存/Cookie | httpOnly Cookie 或服务端 |
| 状态 | 无状态，纯验签 | 有状态（Redis 存 hash/版本） |
| 用途 | 每次请求携带 | 仅调 /refresh 换新 access token |
| 泄露影响 | 短时间窗口 | 可吊销，配合轮换检测 |

### 3.1 刷新与轮换流程

```
1. access 过期 → 前端带 refresh 调 POST /auth/refresh
2. 服务端校验 refresh 签名 + Redis 中版本号一致
3. 校验通过 → 签发新 access + 新 refresh（refresh 轮换）
4. 旧 refresh 立即作废（Redis 版本号 +1 或删除）
5. 若旧 refresh 再次出现 → 判定被盗，吊销该用户全部 token
```

Refresh Token **轮换**是防重放的关键：每次刷新都发新 refresh，旧的一旦被重用就触发告警并全量吊销——攻击者拿到旧 refresh 也无法持续续期。

### 3.2 Redis 注销黑名单

登出/改密/封号时，把 access token 的 `jti`（JWT ID）写入 Redis 黑名单，TTL 设为剩余有效期：

```java
@PostMapping("/logout")
public Result logout(@RequestHeader("Authorization") String auth) {
    String token = auth.replace("Bearer ", "");
    Claims claims = jwtUtil.parse(token);          // 先验签
    String jti = claims.getId();
    long remain = claims.getExpiration().getTime() - System.currentTimeMillis();
    if (remain > 0) {
        redisTemplate.opsForValue().set("jwt:blacklist:" + jti, "1", remain, TimeUnit.MILLISECONDS);
    }
    // refresh token 也一并吊销（删除/版本号+1）
    return Result.ok();
}
```

请求过滤器里验签后**先查黑名单**：

```java
if (redisTemplate.hasKey("jwt:blacklist:" + jti)) {
    throw new UnauthorizedException("token 已注销");
}
```

> 黑名单只存未过期的 jti，量级可控；配合短 access 有效期，Redis 内存开销很小。

## 四、Spring Boot 落地示例（jjwt + 拦截器）

### 4.1 签发与校验工具类

```java
@Component
public class JwtUtil {

    @Value("${jwt.secret}")        // 环境变量注入，绝不硬编码
    private String secret;

    private static final long ACCESS_TTL = 30 * 60 * 1000L;      // 30 分钟
    private static final long REFRESH_TTL = 7 * 24 * 3600 * 1000L; // 7 天

    public String createAccessToken(Long userId, String role) {
        return createToken(userId, role, ACCESS_TTL);
    }

    public String createRefreshToken(Long userId, String role, String version) {
        // refresh 把版本号放进 payload，服务端与 Redis 比对
        return Jwts.builder()
            .setSubject(String.valueOf(userId))
            .claim("role", role)
            .claim("ver", version)
            .setId(UUID.randomUUID().toString())      // jti，用于黑名单
            .setIssuedAt(new Date())
            .setExpiration(new Date(System.currentTimeMillis() + REFRESH_TTL))
            .signWith(Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8)),
                      SignatureAlgorithm.HS256)
            .compact();
    }

    public Claims parse(String token) {
        // parseClaimsJws：强制要求签名且算法匹配配置的密钥，天然拒绝 alg=none
        return Jwts.parserBuilder()
            .setSigningKey(Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8)))
            .build()
            .parseClaimsJws(token)
            .getBody();
    }
}
```

### 4.2 刷接口的轮换与重放检测

```java
@PostMapping("/refresh")
public Result refresh(@CookieValue("refresh_token") String refreshToken) {
    Claims claims = jwtUtil.parse(refreshToken);           // 验签 + 过期校验
    Long userId = Long.valueOf(claims.getSubject());
    String ver = claims.get("ver", String.class);

    String currentVer = (String) redisTemplate.opsForValue()
        .get("refresh:ver:" + userId);
    if (currentVer == null || !currentVer.equals(ver)) {
        // 版本不匹配 → 疑似重放/被盗：吊销该用户全部 token
        redisTemplate.delete("refresh:ver:" + userId);
        throw new UnauthorizedException("refresh token 已失效，请重新登录");
    }

    // 轮换：版本号 +1，旧 refresh 立即作废
    String newVer = UUID.randomUUID().toString();
    redisTemplate.opsForValue().set("refresh:ver:" + userId, newVer, 7, TimeUnit.DAYS);

    return Result.ok(jwtUtil.createAccessToken(userId, "USER"),
                     jwtUtil.createRefreshToken(userId, "USER", newVer));
}
```

## 五、安全清单速查

| 检查项 | 要求 |
|---|---|
| 算法 | 服务端固定白名单（RS256/HS256），拒绝 none，防算法混淆 |
| 密钥 | ≥256bit 随机，环境变量/KMS，定期轮换 + kid |
| 有效期 | access ≤ 2h，refresh ≤ 30 天，payload 必带 exp/iat/jti |
| 传输 | 仅 HTTPS，Authorization 头或 httpOnly Cookie |
| 存储 | 禁 localStorage 存 access，日志脱敏 Authorization |
| 注销 | 黑名单（jti）+ refresh 版本号轮换 + 重放检测 |
| 敏感操作 | 二次认证，不依赖 token 本身 |

## 六、面试追问

**Q1：JWT 和 Session 怎么选？**
单体/同域、追求简单：Session（可随时踢人）；分布式/跨域/移动端、需要无状态：JWT，但必须配套 access+refresh 与黑名单解决"不可控失效"。

**Q2：为什么 access token 要短命？**
JWT 无状态，签发后服务端无法主动让它失效。短命 + refresh 续期 = 把泄露窗口压缩到分钟级，同时保留无状态扩展性。

**Q3：refresh token 被盗怎么办？**
轮换机制兜底：每次刷新换新 refresh，旧 refresh 重用即触发告警 + 全量吊销（清版本号/黑名单），让盗用者无法持续续期。

**Q4：为什么不能用公钥当 HS256 密钥验签？**
算法混淆攻击的核心。验签前必须校验 alg 白名单 + 按固定密钥类型解析，否则攻击者拿公开的 RSA 公钥字符串当 HMAC 密钥就能伪造合法签名。

## 七、总结

JWT 安全一句话：**"防篡改不防冒充，无状态不无风险"**。攻击面集中在算法选择、密钥管理、有效期与注销机制四块。生产落地务必做到：算法白名单、密钥进环境变量、双 Token 轮换、jti 黑名单、日志脱敏、二次认证。把攻防两条线都讲清楚，这类面试题就是送分题。
