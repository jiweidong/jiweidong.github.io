---
title: 【系统设计】扫码登录系统设计：从二维码生成到轮询/WebSocket 实时通知的完整方案
date: 2026-08-28 08:00:00
tags:
  - Java
  - 系统设计
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】扫码登录系统设计：从二维码生成到轮询/WebSocket 实时通知的完整方案

## 面试官：说说扫码登录的完整流程？

扫码登录已经是 PC 端登录的标配交互——微信、钉钉、淘宝、GitHub 全在用。面试官问这个题，考察的不是你会不会调接口，而是**状态机设计、轮询 vs 长连接、二维码安全、过期与失效处理**这些系统设计基本功。

先画一个整体流程：

```
用户打开 PC 登录页         手机 App              后端服务
    │                        │                      │
    ├─ 1.请求生成二维码 ──────►                      │
    │                        │  2.返回 qrId + 二维码图 │
    │◄── 3.展示二维码 ────────┤                      │
    │  4.启动轮询/建立长连接   │                      │
    │                        │                      │
    │                        │  5.手机扫码（解析 qrId）│
    │                        ├──6.确认登录──────────►│
    │                        │                      │  7.校验 qrId 状态
    │                        │                      │  8.绑定用户，生成 ticket
    │◄──── 9.轮询返回 ticket/ ──────────────────────┤
    │         WebSocket 推送  │                      │
    │ 10.用 ticket 换 token   │                      │
    │◄────────────────────────┤                      │
```

核心链路就三步：**生成二维码 → 手机确认 → PC 换取凭证**。每一步都有设计细节。

## 一、二维码的生成：qrId 才是灵魂

二维码本身只是一个"字符串的图形化编码"，它承载的内容才是关键。设计上有两种方案：

| 方案 | 内容 | 优点 | 缺点 |
|------|------|------|------|
| 方案 A | 直接编码登录页 URL + 参数 | 无状态，扫码即跳转 | 参数易被篡改，无法预绑定会话 |
| 方案 B | 编码一个随机 qrId（UUID） | 无敏感信息，服务端可控 | 需要维护 qrId 状态 |

生产中几乎都选方案 B。qrId 需要满足：

- **随机且不可预测**：用 `UUID.randomUUID()` 或 `SecureRandom` 生成 32 位随机串，防止攻击者遍历猜测。
- **不包含用户信息**：二维码里只有 qrId，任何用户信息都在服务端按 qrId 索引。
- **服务端维护状态**：qrId → 状态机（待扫描/已扫描待确认/已确认/已过期/已取消）。

qrId 与状态的存储，首选 Redis：

```java
// 生成二维码
String qrId = UUID.randomUUID().toString().replace("-", "");

// Redis 存储扫码状态机，5 分钟过期（与二维码有效期一致）
stringRedisTemplate.opsForValue().set(
    "login:qr:" + qrId,
    QrState.WAITING_SCAN.name(),
    Duration.ofMinutes(5)
);
```

返回给前端的响应：

```json
{
  "qrId": "a3f9c2e1...",
  "qrContent": "https://login.example.com/qr?a3f9c2e1...",
  "expireIn": 300
}
```

二维码图片本身可以由前端用 qrcode 库生成，也可以后端用 ZXing 生成 Base64 返回。**推荐前端生成**——后端少一次图片处理，二维码内容就是一个 URL。

## 二、状态机设计：四种状态一个流转

扫码登录的状态机是整个系统的核心，务必画清楚：

```
WAITING_SCAN(待扫描) ──手机扫码──► SCANNED(已扫描待确认)
     │                                  │
     │ 超时/刷新                         │ 用户点"确认登录"
     ▼                                  ▼
  EXPIRED(已过期)                    CONFIRMED(已确认)
     ▲                                  │
     │       用户点"取消"                │ PC 换取 token 成功
     └──── CANCELLED(已取消) ◄───────────┘
```

用 Redis 实现时，推荐用 **Hash + 原子操作**而不是简单 String，因为状态流转需要"读-改-写"原子性：

```java
// 手机扫码后：WAITING_SCAN -> SCANNED
// 必须原子操作，防止并发确认导致状态错乱
public boolean transition(String qrId, QrState from, QrState to) {
    String key = "login:qr:" + qrId;
    String script = """
        local cur = redis.call('HGET', KEYS[1], 'state')
        if cur == ARGV[1] then
            redis.call('HSET', KEYS[1], 'state', ARGV[2])
            return 1
        end
        return 0
        """;
    Long result = stringRedisTemplate.execute(
        new DefaultRedisScript<>(script, Long.class),
        List.of(key), from.name(), to.name());
    return Long.valueOf(1).equals(result);
}
```

用 Lua 脚本保证 CAS（Compare-And-Swap）原子性，这是扫码登录正确性的关键——**两个手机同时扫同一个码，只有第一个能成功**。

## 三、PC 端如何知道"扫码成功"？轮询 vs 长连接

这是面试官最爱追问的点。PC 端获取状态的方式有三种：

| 方式 | 原理 | 实时性 | 服务器压力 | 适用场景 |
|------|------|--------|-----------|----------|
| 短轮询 | 每 2-3s 拉一次状态接口 | 秒级 | 高（QPS = 在线数/间隔） | 简单、可靠、易实现 |
| 长轮询 | 请求挂起，有结果才返回 | 准实时 | 中（连接挂起占线程） | 兼容性好，无额外依赖 |
| WebSocket | 服务端主动推送 | 实时 | 中（长连接资源） | 交互丰富的现代应用 |

**面试回答要点：**

1. **短轮询是默认方案**。扫码确认的时效性要求是"秒级"，2 秒一次轮询完全够用。100 万在线用户，2s 间隔也就是 50 万 QPS 的状态查询——全部走 Redis GET，扛得住（Redis 单机轻松 10 万+ QPS，集群化更稳）。

2. **长轮询**：请求到达后不立即返回，在服务端挂起（如 25s 超时），状态变化时由回调唤醒返回。相比短轮询减少了无效请求次数，但**会占用连接和线程**，配合 Servlet 3.1 异步或 WebFlux 才能高并发。

3. **WebSocket**：PC 端与后端建立长连接，手机确认后后端主动推送。最实时，但要维护连接池、心跳、重连逻辑，复杂度最高。

实践中微信/钉钉用的是"短轮询 + 状态缓存"的变体：轮询接口先查本地缓存，没变化直接返回"未变"标识，减少数据传输。**记住一句话：能用轮询解决的就别上 WebSocket，这是架构师的基本克制。**

## 四、扫码后手机端做了什么

手机端扫码，本质是解析出 URL 中的 qrId，然后：

1. **校验 qrId 合法性**：查 Redis 是否存在、是否已过期。
2. **展示确认页**：显示 PC 端会话信息（如"确认登录 XX 网页版"）+ 登录账号头像昵称。
3. **用户确认**：调用 `POST /api/login/scan/confirm`，携带 qrId + 用户 token（手机端已登录）。
4. **服务端处理**：原子更新状态为 `SCANNED` → `CONFIRMED`，同时生成一个**一次性 ticket**（短期有效，如 30 秒），存入 Redis：

```java
// 确认登录后，生成一次性 ticket 供 PC 换取 token
String ticket = UUID.randomUUID().toString().replace("-", "");
stringRedisTemplate.opsForValue().set(
    "login:ticket:" + ticket,
    userId.toString(),
    Duration.ofSeconds(30)   // 短时效，降低被劫持风险
);
```

## 五、PC 端用 ticket 换 token：最后的闭环

PC 端轮询到状态为 `CONFIRMED` 后，拿着 ticket 调登录接口：

```java
@PostMapping("/api/login/confirm")
public Result<String> confirm(@RequestBody ConfirmReq req) {
    // 1. 校验 ticket 存在且未使用（一次性）
    String userId = stringRedisTemplate.opsForValue()
        .getAndDelete("login:ticket:" + req.getTicket());
    if (userId == null) {
        return Result.fail("凭证已失效，请重新扫码");
    }
    // 2. 签发 token（JWT 或服务端 session）
    String token = jwtUtil.generateToken(Long.valueOf(userId));
    return Result.success(token);
}
```

注意这里用的是 **`getAndDelete`（GETDEL）**——ticket 一次性使用，取走即删除，防止重放攻击。

## 六、安全设计：扫码登录的五个坑

| 风险 | 攻击方式 | 防御手段 |
|------|----------|----------|
| 二维码伪造 | 恶意站点生成假码诱导扫码 | qrId 服务端签发、URL 绑定域名、签名校验 |
| qrId 枚举 | 遍历 qrId 抢注登录 | 随机数 128bit+，Redis 限频 |
| 扫码劫持 | 用户扫了攻击者的码 | 确认页展示"PC 端 IP/浏览器"信息，用户确认 |
| ticket 重放 | 截获 ticket 重复使用 | 一次性使用（GETDEL）+ 30s 短时效 |
| 中间人 | 传输中被篡改 | 全链路 HTTPS，二维码内容签名 |

另外两个容易被忽略的点：

- **异地提醒**：扫码成功后若检测到 PC 端 IP 与常用地不符，可触发风控（短信验证或延迟登录）。
- **设备互踢**：同一账号多地扫码登录，策略可以是"后者踢前者"或"全部保留"，微信是后者，但很多企业系统用前者。

## 七、高并发与性能优化

扫码登录的并发压力点在**状态查询接口**（PC 端轮询）。优化三板斧：

1. **Redis 扛读**：状态全部在 Redis，天然抗压；热 qrId 可加本地缓存（Caffeine）二级兜底。
2. **轮询加随机抖动**：客户端在 1.5~3s 间随机取间隔，避免所有客户端同步请求造成"心跳洪峰"。
3. **状态合并接口**：轮询接口一次返回"登录态 + 未读消息数 + 版本号"，减少请求次数。

## 八、面试追问汇总

**Q1：为什么不用 WebSocket 而是轮询？**
答：扫码确认本身是低频事件（用户扫一次码），实时性要求只有秒级；轮询实现简单、无连接管理成本、天然兼容各种网络环境（公司防火墙可能封长连接）。只有需要持续双向通信（如 IM、协同编辑）才值得上 WebSocket。

**Q2：二维码过期了怎么办？**
答：前端在 qrId 快过期时（如剩 30s）自动重新请求新二维码并切换轮询目标；用户已扫码但未确认时过期，需重新扫码。

**Q3：一个码能被扫多次吗？**
答：不能。状态机 + Lua 原子流转保证只有第一次扫码能进入 SCANNED，后续扫码直接拒绝并提示"二维码已被使用"。

**Q4：ticket 和 token 有什么区别？**
答：ticket 是短期（30s）、一次性、仅用于换取 token 的凭证，换取后即销毁；token 是长期会话凭证（JWT 或 session id），用于后续所有接口鉴权。这是"最小权限 + 短时效"的安全分层。

## 总结

扫码登录的完整答案就一句话：**用随机 qrId 建立 PC 与手机的关联，用 Redis 维护状态机，用短轮询通知 PC，用一次性 ticket 完成凭证交换**。把状态机画清楚、把原子流转和 ticket 一次性这两个细节讲出来，面试官就知道你是真做过而不是背概念。
