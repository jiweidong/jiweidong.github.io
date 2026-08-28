---
title: 【Spring Boot 实战】验证码与接口防刷深度实战：图形验证码、短信验证码与 Redis 频控
date: 2026-08-28 08:00:00
tags:
  - Java
  - Spring Boot
  - 安全
  - Redis
categories:
  - Java
  - Spring Boot 实战
author: 东哥
---

# 【Spring Boot 实战】验证码与接口防刷深度实战：图形验证码、短信验证码与 Redis 频控

## 面试官：登录接口被脚本刷爆了怎么办？

验证码和接口防刷是每个后端都要面对的基础安全课题。短信轰炸、撞库、薅羊毛、爬虫——攻击者永远比产品经理勤快。本文用 Spring Boot 3 + Redis 从零搭建一套**图形验证码 + 短信验证码 + 频控**体系，全部可落地的代码。

## 一、验证码的分类与选型

| 类型 | 原理 | 安全性 | 用户体验 | 成本 |
|------|------|--------|----------|------|
| 图形验证码 | 扭曲字符图片 | 低（OCR 可破） | 差 | 极低 |
| 算术/点选 | 简单交互 | 中 | 中 | 低 |
| 滑块验证 | 行为轨迹分析 | 较高 | 好 | 依赖第三方 |
| 短信验证码 | 手机号 + 一次性码 | 高（需防轰炸） | 中 | 每条几分钱 |
| 行为验证（无感） | 鼠标轨迹+环境指纹 | 高 | 最好 | 第三方 |

**核心认知**：验证码不是用来"完全挡住机器人"的，而是**提高攻击成本**。成本低于收益时，攻击者就转移目标了。所以线上通常组合使用：图形验证码挡第一层，短信验证码做高价值操作，频控兜底。

## 二、图形验证码：从生成到校验

用开源的 `EasyCaptcha`（或 Hutool 的 captcha 模块），几行代码生成：

```xml
<dependency>
    <groupId>com.github.whvcse</groupId>
    <artifactId>easy-captcha</artifactId>
    <version>1.6.2</version>
</dependency>
```

```java
@RestController
public class CaptchaController {

    @GetMapping("/captcha")
    public Result<CaptchaVO> captcha() {
        // 生成算术验证码（比字符验证码抗 OCR）
        ArithmeticCaptcha captcha = new ArithmeticCaptcha(130, 48);
        captcha.setLen(2);  // 2 位运算，如 3+5=?
        String code = captcha.text();       // 明文答案："8"
        String uuid = UUID.randomUUID().toString();

        // 答案存 Redis，5 分钟过期，验证一次即失效
        stringRedisTemplate.opsForValue().set(
            "captcha:" + uuid, code, Duration.ofMinutes(5));

        return Result.success(new CaptchaVO(uuid, captcha.toBase64()));
    }

    // 校验：登录时带上 uuid + 用户输入的答案
    private void verifyCaptcha(String uuid, String input) {
        String key = "captcha:" + uuid;
        String right = stringRedisTemplate.opsForValue().get(key);
        if (right == null) {
            throw new BizException("验证码已过期，请刷新");
        }
        // 无论对错都删除——一次性，防重放
        stringRedisTemplate.delete(key);
        if (!right.equalsIgnoreCase(input.trim())) {
            throw new BizException("验证码错误");
        }
    }
}
```

三个要点：

1. **答案只存 Redis，不返回前端**——返回的是 Base64 图片。
2. **一次性消费**：校验完立刻删除，防止验证码复用。
3. **算术验证码优先**：纯字符验证码用 OCR 工具库几秒钟就能识别，算术题成本高一个量级。

## 三、短信验证码：防轰炸是第一优先级

短信验证码的敌人不是"猜答案"，而是**短信轰炸**——攻击者用你的接口给任意手机号狂发短信，让你付短信费还骚扰用户。

### 发送前：三层防线

```java
public void sendSmsCode(String phone) {
    // 防线 1：全局频率——同一 IP 每分钟最多 5 条
    Long ipCount = stringRedisTemplate.opsForValue()
        .increment("sms:ip:" + getClientIp());
    if (ipCount != null && ipCount > 5) {
        stringRedisTemplate.expire("sms:ip:" + getClientIp(), Duration.ofMinutes(1));
        throw new BizException("操作过于频繁");
    }

    // 防线 2：手机号维度——同一手机号 60s 只能发 1 条
    Boolean ok = stringRedisTemplate.opsForValue()
        .setIfAbsent("sms:phone:" + phone, "1", Duration.ofSeconds(60));
    if (Boolean.FALSE.equals(ok)) {
        throw new BizException("验证码发送太频繁，请稍后再试");
    }

    // 防线 3：手机号 + IP 组合——同一手机号每天最多 10 条
    Long dayCount = stringRedisTemplate.opsForValue()
        .increment("sms:phone-day:" + phone + ":" + LocalDate.now());
    if (dayCount > 10) {
        throw new BizException("今日发送次数已达上限");
    }

    // 生成 6 位随机码，存 Redis 5 分钟
    String code = String.valueOf(new Random().nextInt(900000) + 100000);
    stringRedisTemplate.opsForValue().set(
        "sms:code:" + phone, code, Duration.ofMinutes(5));

    // 调短信服务商发送（阿里云/腾讯云）
    smsClient.send(phone, "您的验证码是 " + code + "，5 分钟内有效");
}
```

### 校验时：限次 + 一次性

```java
public void verifySmsCode(String phone, String code) {
    String key = "sms:code:" + phone;
    // 错误次数限制：最多 5 次
    Long err = stringRedisTemplate.opsForValue().increment(key + ":err");
    if (err > 5) {
        stringRedisTemplate.delete(key);  // 超过次数直接作废验证码
        throw new BizException("错误次数过多，请重新获取");
    }
    String right = stringRedisTemplate.opsForValue().get(key);
    if (right == null) {
        throw new BizException("验证码已过期，请重新获取");
    }
    if (!right.equals(code)) {
        throw new BizException("验证码错误");
    }
    stringRedisTemplate.delete(key);  // 校验成功即删除（一次性）
}
```

## 四、接口频控：Redis 滑动窗口实现

验证码只是"门槛"，真正的防刷核心是**全局限流**。用 Redis 实现滑动窗口限流（比固定窗口更平滑，防临界突发）：

```java
@Component
public class SlidingWindowRateLimiter {

    @Resource
    private StringRedisTemplate redis;

    /**
     * 滑动窗口限流
     * @param key       资源标识（如 login:u10086 或 login:ip:1.2.3.4）
     * @param maxCount  窗口内最大请求数
     * @param windowSec 窗口大小（秒）
     */
    public boolean allow(String key, int maxCount, long windowSec) {
        String script = """
            local key = KEYS[1]
            local now = tonumber(ARGV[1])
            local window = tonumber(ARGV[2])
            local max = tonumber(ARGV[3])
            -- 移除窗口外的记录
            redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
            local count = redis.call('ZCARD', key)
            if count < max then
                redis.call('ZADD', key, now, now .. ':' .. math.random())
                redis.call('EXPIRE', key, window)
                return 1
            end
            return 0
            """;
        Long allow = redis.execute(
            new DefaultRedisScript<>(script, Long.class),
            List.of(key), String.valueOf(System.currentTimeMillis() / 1000),
            String.valueOf(windowSec), String.valueOf(maxCount));
        return Long.valueOf(1).equals(allow);
    }
}
```

用 **ZSET（有序集合）** 记录每个请求的时间戳，窗口滑动时淘汰过期记录，`ZCARD` 数窗口内请求数。为什么用 Lua？因为"检查 + 添加"必须原子，多线程并发下不能有竞态。

### 应用层组合拳

```java
@PostMapping("/login")
public Result<String> login(@RequestBody LoginReq req) {
    String ip = getClientIp();

    // 第一层：IP 维度，1 分钟 10 次
    if (!rateLimiter.allow("login:ip:" + ip, 10, 60)) {
        throw new BizException("登录尝试过于频繁，请稍后再试");
    }
    // 第二层：账号维度，5 分钟 5 次（防撞库）
    if (!rateLimiter.allow("login:acc:" + req.getUsername(), 5, 300)) {
        throw new BizException("该账号尝试过于频繁，请 5 分钟后再试");
    }
    // 第三层：连续失败锁定
    String failKey = "login:fail:" + req.getUsername();
    if (Boolean.TRUE.equals(redis.hasKey(failKey))) {
        throw new BizException("账号已锁定，请稍后再试");
    }

    // 校验验证码 + 账号密码
    verifyCaptcha(req.getUuid(), req.getCaptcha());
    User user = userService.checkPassword(req.getUsername(), req.getPassword());
    if (user == null) {
        Long failCount = redis.opsForValue().increment(failKey);
        redis.expire(failKey, Duration.ofMinutes(10));
        if (failCount >= 5) {
            redis.opsForValue().set(failKey, "LOCKED", Duration.ofMinutes(30));
            throw new BizException("连续失败 5 次，账号锁定 30 分钟");
        }
        throw new BizException("用户名或密码错误");
    }
    redis.delete(failKey);  // 登录成功清除失败计数
    return Result.success(jwtUtil.generateToken(user.getId()));
}
```

分层限流的思路：**IP 限频挡脚本，账号限频挡撞库，失败锁定挡爆破**。三层各自独立又互相补充。

## 五、更多防刷手段

| 手段 | 原理 | 适用场景 |
|------|------|----------|
| 滑块/行为验证 | 前端采集行为特征，后端二次校验 | 登录、注册 |
| 设备指纹 | 浏览器 canvas/UA/时区生成指纹 | 薅羊毛识别 |
| 风控规则引擎 | 规则组合（IP 段、设备、频次、时段） | 电商、金融 |
| 黑名单 | 恶意 IP/账号动态拉黑 | 攻击中实时封禁 |
| 人机验证（reCAPTCHA） | 无感行为分析 | 全站入口 |

**进阶**：网关层（Spring Cloud Gateway / Nginx）做 IP 限流，应用层做业务限流——网关挡流量洪峰，应用层做精细控制。两级配合才是生产标准。

## 六、面试追问汇总

**Q1：图形验证码为什么不用 UUID 当 key？**
答：可以用，但 uuid 就是 key 本身，重点是**答案必须存服务端**（Redis），前端永远只拿到图片。防的是"脚本自动识别+自动提交"，不是防人。

**Q2：短信轰炸怎么防？**
答：三层——IP 频控、手机号 60s 冷却、手机号日上限；再配合图形验证码前置（先过图码再发短信）、异常时段风控（深夜限制）、黑名单。核心原则是**把短信接口变成"高成本调用"**。

**Q3：固定窗口限流有什么问题？**
答：临界问题——窗口边界处流量可能翻倍（如 1 分钟 100 次，第 59 秒和第 61 秒各 100 次，实际 2 秒内 200 次）。滑动窗口或令牌桶能消除这个缺陷。

**Q4：Redis 限流的 key 膨胀怎么办？**
答：所有限流 key 都设置 TTL（ZSET 用 EXPIRE，计数用 expire），Redis 自动回收；定期用 SCAN 清理无 TTL 的残留 key。

## 总结

验证码防刷体系就是"**层层设卡，提高攻击成本**"：图形验证码挡自动化，短信验证码控发送频率，滑动窗口限流管全局，失败锁定防爆破。把本文的 Redis 频控组件和三层防线落地到登录/注册/下单接口，你的系统就比 90% 的同行抗揍。
