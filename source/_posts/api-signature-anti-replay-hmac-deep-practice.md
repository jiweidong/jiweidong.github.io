---
title: 【Spring Boot 实战】接口安全签名与防重放攻击深度实战：HMAC、时间戳与 Nonce 机制
date: 2026-08-29 08:00:00
tags:
  - Spring Boot
  - 安全
  - 接口设计
  - 实战
categories:
  - Java
author: 东哥
---

# 【Spring Boot 实战】接口安全签名与防重放攻击深度实战：HMAC、时间戳与 Nonce 机制

## 面试官：开放平台给第三方提供 API，怎么保证请求是合法的、没被篡改的、不是重放的？讲讲签名机制的设计。

HTTP 是明文协议，抓包工具（Charles/Fiddler）能轻易看到请求内容。没有签名机制的接口，等于把「改金额、换参数、重放请求」的大门敞开。这一篇从**签名要解决的三类问题**出发，讲透 HMAC 签名、时间戳、Nonce 防重放的设计，并给出一套可直接落地的 Spring Boot 拦截器实现。

## 一、签名机制到底在防什么

| 威胁 | 攻击方式 | 签名方案对应手段 |
|---|---|---|
| **篡改** | 中间人改参数（如把 `amount=100` 改成 `amount=1`） | 参数参与签名，验签失败即拒绝 |
| **伪造** | 攻击者伪造一个合法请求 | 签名密钥（AppSecret）只有客户端和服务端知道 |
| **重放** | 截获合法请求，原样重复发送 N 次（如重复下单、重复转账） | 时间戳 + Nonce（一次性随机数） |
| **伪装** | 冒充合法客户端 | AppId 标识身份 + Secret 签名 |

> 注意：签名解决的是**身份认证 + 完整性 + 抗重放**，但**不解决机密性**——敏感数据仍要走 HTTPS（见本站《HTTPS 与 TLS 握手深度解析》）。签名 + HTTPS 是标配组合，不是二选一。

## 二、签名算法选型：为什么是 HMAC

### 2.1 常见方案对比

| 方案 | 原理 | 安全性 | 性能 |
|---|---|---|---|
| **HMAC-SHA256** | 密钥参与哈希（`H(K XOR opad, H(K XOR ipad, msg))`） | 高：无密钥无法伪造 | 快（~1μs 级） |
| MD5(拼接+盐) | 简单拼接后 MD5 | **低**：拼接顺序泄露易碰撞，已被弃用 | 快 |
| RSA 签名 | 私钥签名、公钥验签 | 高：**非对称**，服务端不存客户端私钥 | 慢（毫秒级） |
| AES 加密参数 | 参数加密传输 | 中：防窥探，但不防重放 | 中 |

**选型结论**：
- **大部分场景用 HMAC-SHA256**：对称密钥、计算快、实现简单。
- **高安全场景（开放平台对外）用 RSA/国密 SM2**：客户端持有私钥，即使服务端数据库泄露也伪造不了签名（见本站《国密算法深度实战》）。
- **签名和加密要分清**：签名保证「没被改」，加密保证「看不见」。两者可以叠加（先签名后加密，或 HTTPS 只加密不签名则必须配合防篡改）。

### 2.2 HMAC-SHA256 的原理

```
HMAC(K, m) = H( (K' ⊕ opad) || H( (K' ⊕ ipad) || m ) )
K' = K（长度不足则补零，超过则先 H(K)）
opad = 0x5c 重复块，ipad = 0x36 重复块
```

关键特性：**即使消息 m 相同，没有密钥 K 也无法计算/验证 HMAC**；且 HMAC 对消息逐字节敏感，改一个字符签名完全不同。

## 三、防重放：时间戳 + Nonce 双保险

### 3.1 为什么单独的时间戳不够

```java
// 请求头
X-Timestamp: 1724822400   // 当前秒级时间戳
```

服务端校验 `|now - timestamp| <= 300s`，能挡住「很久以前的请求重放」，但**拦不住 5 分钟内的重放**——攻击者拿到请求后 1 秒内重放 100 次照样通过。

### 3.2 Nonce 一次性随机数

```java
// 请求头
X-Nonce: 9f8a7b6c-5d4e-4a3b-8c2d-1e0f9a8b7c6d   // UUID/随机串
```

服务端对每个 `(AppId, Nonce)` 在有效期内**只接受一次**：

```
收到请求 → 校验时间戳(窗口内) → 查 Nonce 是否用过
    ├─ 用过 → 拒绝（重复请求）
    └─ 没用过 → 记录 Nonce（TTL=时间窗口）→ 放行
```

**Nonce 存储方案对比**：

| 方案 | 优点 | 缺点 |
|---|---|---|
| Redis SETNX + EXPIRE | 原子、天然过期、分布式共享 | 需要 Redis |
| 本地 Caffeine 缓存 | 零依赖、快 | 多实例不共享（要粘性会话或每实例各自记） |
| MySQL 唯一索引 | 持久 | 慢、要清理过期数据 |

> **生产推荐 Redis**：`SET nonce:{appId}:{nonce} 1 EX 300 NX`，返回 OK 才是第一次。Redis 的分布式特性天然适配多实例部署（Redis 实战见本站系列文章）。

### 3.3 完整签名头设计（开放平台通用规范）

| 请求头 | 必选 | 说明 |
|---|---|---|
| `X-App-Id` | ✅ | 客户端身份标识 |
| `X-Timestamp` | ✅ | 秒级时间戳，服务端校验窗口（如 ±300s） |
| `X-Nonce` | ✅ | 一次性随机数，配合时间戳防重放 |
| `X-Signature` | ✅ | `HMAC-SHA256(secret, 待签名串)` 的 hex |
| `X-Version` | ❌ | 签名版本，方便升级算法（v1/v2 兼容期） |

## 四、待签名串的构造规范（最容易踩坑）

### 4.1 规范公式

```
待签名串 = HTTP方法 + "\n"
         + 请求路径 + "\n"
         + 规范化查询串 + "\n"     -- 参数名 ASCII 排序 & key=value& 拼接
         + 规范化请求体 + "\n"     -- 原始 body（或 body 的 SHA256）
         + AppId + "\n"
         + Timestamp + "\n"
         + Nonce
signature = hex( HMAC-SHA256(secret, 待签名串) )
```

**为什么这么设计**：
1. **方法 + 路径**：防止「把 GET 请求重放成 POST」「换路径复用签名」。
2. **参数排序拼接**：保证客户端服务端构造出**完全一致的串**（HashMap 遍历顺序不可控，必须排序）。
3. **body 参与签名**：防止请求体被篡改。**大 body 的优化**：只对 `SHA256(body)` 参与签名，避免把几 MB 的 body 直接拼进签名串。
4. **时间戳 + Nonce 参与签名**：让签名和「一次性」绑定，防重放更彻底。

### 4.2 客户端签名示例（Java）

```java
public class ApiSigner {

    public static String sign(String method, String path,
                              Map<String, String> query,
                              String body, String appId,
                              String secret, long timestamp, String nonce)
            throws Exception {

        // 1. 查询参数规范化：按 key 字典序拼接
        String queryStr = query.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .map(e -> e.getKey() + "=" + e.getValue())
                .collect(Collectors.joining("&"));

        // 2. body 摘要（大 body 只签名摘要）
        String bodyDigest = body == null || body.isEmpty() ? ""
                : DigestUtils.sha256Hex(body);

        // 3. 组装待签名串
        String raw = String.join("\n",
                method.toUpperCase(), path, queryStr, bodyDigest,
                appId, String.valueOf(timestamp), nonce);

        // 4. HMAC-SHA256 签名
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8),
                "HmacSHA256"));
        byte[] digest = mac.doFinal(raw.getBytes(StandardCharsets.UTF_8));
        return HexFormat.of().formatHex(digest);
    }
}
```

## 五、服务端拦截器落地（Spring Boot）

### 5.1 自定义注解 + HandlerInterceptor

```java
@Target({ElementType.METHOD, ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
public @interface ApiSign {
    /** 时间戳允许的偏移窗口（秒） */
    int window() default 300;
}
```

```java
@Component
public class SignInterceptor implements HandlerInterceptor {

    private final StringRedisTemplate redis;
    private final AppSecretService appSecretService; // AppId → Secret 查询

    @Override
    public boolean preHandle(HttpServletRequest request,
                             HttpServletResponse response, Object handler) {
        if (handler instanceof HandlerMethod hm
                && hm.getMethodAnnotation(ApiSign.class) == null
                && hm.getBeanType().getAnnotation(ApiSign.class) == null) {
            return true; // 未标注的不拦截
        }

        String appId = request.getHeader("X-App-Id");
        String timestamp = request.getHeader("X-Timestamp");
        String nonce = request.getHeader("X-Nonce");
        String signature = request.getHeader("X-Signature");

        // 1. 必填校验
        if (anyBlank(appId, timestamp, nonce, signature)) {
            return reject(response, 40001, "缺少签名参数");
        }

        // 2. 时间戳窗口校验
        long ts = Long.parseLong(timestamp);
        if (Math.abs(System.currentTimeMillis() / 1000 - ts) > 300) {
            return reject(response, 40002, "请求已过期");
        }

        // 3. Nonce 防重放（Redis 原子写入）
        Boolean first = redis.opsForValue()
                .setIfAbsent("nonce:" + appId + ":" + nonce, "1",
                        Duration.ofSeconds(300));
        if (Boolean.FALSE.equals(first)) {
            return reject(response, 40003, "重复请求");
        }

        // 4. 验签
        String secret = appSecretService.getSecretByAppId(appId);
        if (secret == null) {
            return reject(response, 40004, "AppId 无效");
        }
        String expect = ApiSigner.sign(request.getMethod(), request.getRequestURI(),
                request.getParameterMap(), readBody(request),
                appId, secret, ts, nonce);
        if (!MessageDigest.isEqual(expect.getBytes(StandardCharsets.UTF_8),
                signature.getBytes(StandardCharsets.UTF_8))) {
            return reject(response, 40005, "签名校验失败");
        }
        return true;
    }
}
```

**关键细节**：
- 用 `MessageDigest.isEqual` 比较签名（**常量时间比较**，防时序攻击），别用 `String.equals`。
- Nonce 校验**先于**验签执行没问题，但要注意：验签失败的请求也消耗了 Nonce——这是可接受的（攻击者无法通过伪造请求消耗合法 Nonce，因为 Nonce 是客户端生成的）。
- 读取 body 时用 `ContentCachingRequestWrapper` 包装，避免 `getInputStream()` 读一次后后续读取为空。
- 验签失败写审计日志（appId、IP、路径、签名），用于风控。

### 5.2 注册拦截器

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(signInterceptor)
                .addPathPatterns("/openapi/**")  // 只拦开放平台接口
                .excludePathPatterns("/openapi/callback/**"); // 回调走 RSA 验签等
    }
}
```

### 5.3 统一异常与返回

```java
public static boolean reject(HttpServletResponse response,
                             int code, String msg) throws IOException {
    response.setStatus(HttpStatus.UNAUTHORIZED.value());
    response.setContentType("application/json;charset=UTF-8");
    response.getWriter().write("{\"code\":" + code + ",\"msg\":\"" + msg + "\"}");
    return false;
}
```

> 生产上配合本站《全局异常处理》把验签错误纳入统一错误码体系，前端才能友好提示。

## 六、进阶与实战经验

### 6.1 密钥管理

1. **密钥永不落库明文**：Secret 用 AES 加密存储或 KMS 托管，查询时解密。
2. **Secret 生成**：`SecureRandom` 生成 32 字节随机数，Base64 编码（别用 UUID——熵不够且格式可预测）。
3. **密钥轮换**：支持 `X-Version` 头 + 双密钥，`v2` 上线后保留 `v1` 一段时间（兼容期），到期强制升级。

### 6.2 大文件上传怎么办

body 参与签名对大文件不现实。方案：**先申请上传凭证（预签名 URL）**——客户端先调用签名接口获取 OSS 预签名地址（含有效期），文件直传 OSS，业务参数（文件名、大小、SHA256）走正常签名接口。服务端回调校验文件 SHA256 一致性。详见本站《文件上传下载企业级实战》。

### 6.3 回调接口的签名（服务端 → 服务端）

回调方向相反：**我方是调用方**，需要**接收方**能验证「这真的是我们发的」。做法：回调 URL 参数带 `signature + timestamp + nonce`，接收方用约定好的 Secret 验签 + 防重放。微信支付、支付宝回调都是这个模式（它们用的是 RSA + 平台证书）。

### 6.4 性能与安全平衡

- 验签是 CPU 轻量操作（HMAC-SHA256 ~1μs），**瓶颈不在验签**，在 Nonce 的 Redis 访问——可以本地 Caffeine 做一层短 TTL 缓存（如 10s）批量去重，再回源 Redis 兜底。
- 全链路建议：**WAF/网关层先限流**（见本站《API 限流策略与算法》），签名拦截器放在业务层入口，双保险。

## 七、面试追问速答

**追问 1：时间戳 + Nonce 就能完全防重放吗？**
在窗口期内能防「同请求重复提交」。但**防不了「窗口内合法的多次调用」**（比如用户真的连续下单 3 次）——那是业务幂等（见本站《接口幂等性方案全解析》）的职责。签名防「非授权重放」，幂等防「业务重复」，两者配合才是完整方案。

**追问 2：为什么 Nonce 要参与签名计算？**
Nonce 不参与签名的话，攻击者可以**替换 Nonce 重放**：换一个新的 Nonce，绕过服务端「Nonce 已用」检查，而签名仍然有效（因为签名没绑定 Nonce）。Nonce 进签名后，换 Nonce 必然导致验签失败。

**追问 3：为什么用 HMAC 而不是直接把 Secret 拼在参数里 MD5？**
MD5(参数+Secret) 的方案容易被**长度扩展攻击**（当拼接格式为 `secret+msg` 时）且算法公开碰撞风险高；HMAC 用密钥做两次哈希（ipad/opad），不泄露密钥的任何信息，是密码学界公认的安全 MAC 构造。

**追问 4：HTTPS 已经有了，还要签名吗？**
要。HTTPS 防的是**传输途中被窃听/篡改**（中间人），但解决不了：①服务端日志/抓包工具在可信环境下的内部泄露；②客户端被攻破后重放合法请求；③B 端系统之间的信任边界（双方用证书互信太重）。签名是应用层的信任机制，和传输层加密互补。

## 总结

| 设计点 | 推荐做法 |
|---|---|
| 签名算法 | HMAC-SHA256（高安全场景 RSA/SM2） |
| 待签名串 | 方法+路径+排序查询串+body摘要+AppId+时间戳+Nonce |
| 防重放 | 时间戳窗口(300s) + Redis SETNX Nonce |
| 验签安全 | MessageDigest.isEqual 常量时间比较 |
| 密钥管理 | KMS 托管 + 版本化轮换 + 兼容期 |
| 边界 | 防重放 ≠ 幂等，两者都要做 |

签名机制是开放平台的第一道门禁。把「篡改、伪造、重放、伪装」四个威胁对号入座，这一套设计就能讲得清清楚楚、落地得稳稳当当。
