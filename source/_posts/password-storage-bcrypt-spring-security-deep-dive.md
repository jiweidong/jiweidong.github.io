---
title: 【安全实战】密码存储安全深度解析：从 MD5 加盐到 BCrypt/Argon2 与 Spring Security PasswordEncoder
date: 2026-09-07 08:04:00
tags:
  - 安全
  - Spring Security
  - 密码学
  - 面试
categories:
  - Java
  - 安全
author: 东哥
---

# 【安全实战】密码存储安全深度解析：从 MD5 加盐到 BCrypt/Argon2 与 Spring Security PasswordEncoder

## 先看事故：600 万条 MD5 密码被拖库后，5 分钟破解 70%

某创业公司数据库被拖，用户表里存的是**裸 MD5**。攻击者拿彩虹表一比对，几分钟就还原了 70% 的弱密码——因为"123456"的 MD5 是公开固定的 `e10adc3949ba59abbe56e057f20f883e`，彩虹表里直接查得到。即使用户密码再复杂，只要撞了常见字典，MD5 一次计算只需微秒级，GPU 每秒能跑几十亿次，**暴力破解成本低到可以忽略**。

密码存储的本质矛盾是：**数据库可能被拖走，所以库里的"密码"必须让攻击者即使拿到也几乎无法还原**。本文从 MD5 为什么不行讲起，到 BCrypt/Argon2 的原理，再到 Spring Security 的完整落地。

## 一、为什么 MD5/SHA-256 不适合存密码

### 1. 无盐哈希：彩虹表一击即溃

MD5 是**确定性**的：同样的输入永远得到同样的输出。攻击者可以预先计算海量常见密码的哈希值建成"彩虹表"，拿到库后直接查表。

### 2. 加盐就安全了吗？不，还差"慢"这一步

```java
// 常见但不够好的做法：MD5(密码 + 固定盐)
String hash = md5(password + "my-fixed-salt");
```

加随机盐（每个用户一个盐）确实能防彩虹表，但**没解决计算速度问题**：MD5/SHA-256 是为"快"设计的（用于校验文件完整性），现代 GPU 每秒可算 **数十亿次** SHA-256。哪怕加盐，攻击者拿到库后对单个用户暴力穷举，弱密码照样秒破。

### 3. 密码哈希算法的真正要求

专用密码哈希算法必须满足三个特性：

| 特性 | 说明 |
|---|---|
| **慢** | 单次计算要消耗毫秒级时间，让暴力破解成本放大百万倍 |
| **带随机盐** | 每个用户盐不同，防彩虹表、防批量破解 |
| **可调参** | 硬件升级后能增大代价因子，未来可迁移 |

这就是 BCrypt、scrypt、Argon2 存在的意义——它们都是**故意设计得很慢**的 KDF（密钥派生函数）。

> 面试官追问：SHA-256 也算"哈希"，为什么不能用来存密码？
> 哈希函数的设计目标是"快"——MD5/SHA 系列为了校验数据完整性而生，速度是核心指标。密码存储恰恰需要"慢"，所以直接用 SHA 系列是方向性错误。这也解释了为什么 SHA-256(password+salt) 在安全审计里依然是高风险项。

## 二、BCrypt 原理：Blowfish 的成本参数与盐

BCrypt 基于 Blowfish 分组密码的 EksBlowfish 方案，1999 年由 Niels Provos 提出，是 OpenBSD 默认密码算法，也是目前 Java 生态最主流的密码哈希算法。

### 1. 输出格式长什么样

一个 BCrypt 哈希长这样：

```
$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy
```

拆解：

| 段 | 值 | 含义 |
|---|---|---|
| 版本 | `2a` | 算法版本（还有 2b/2y，修正了长度扩展 bug） |
| cost | `10` | 代价因子，实际迭代次数 = 2^10 = 1024 次 |
| salt | `N9qo8uLOickgx2ZMRZoMye` | 22 字符（128 bit）随机盐，Base64 编码 |
| hash | 31 字符 | 最终哈希值 |

**盐就嵌在哈希串里**——校验时不需要单独存盐，直接解析哈希串里的 salt 重算比对即可，这也是 BCrypt 存储方便的原因。

### 2. cost 参数：从 2^10 到 2^12 的权衡

cost 每 +1，计算时间翻倍。实测参考（单核）：

| cost | 迭代次数 | 单次耗时（约） | 安全等级 |
|---|---|---|---|
| 10 | 1024 | ~50-80ms | 2010 年代标准 |
| 12 | 4096 | ~200-300ms | 当前推荐（OWASP） |
| 14 | 16384 | ~0.8-1.2s | 高安全场景 |

OWASP 建议 2023 年后新系统 **cost ≥ 12**。注意：cost 太高会拖垮登录接口的吞吐（每个登录请求都要几百毫秒 CPU），要做压测平衡。

### 3. BCrypt 的两个经典限制

- **72 字节输入限制**：BCrypt 只使用密码的前 72 字节，更长的部分被静默截断。对策：先做一次预哈希（如 SHA-256）再喂给 BCrypt，但要注意兼容性；Spring Security 的 `BCryptPasswordEncoder` 对超长密码会直接抛异常提醒（这是个 feature 不是 bug）。
- **单次计算量固定**：BCrypt 的 cost 只影响迭代次数，内存占用恒定（4KB），所以抗 GPU 不错，但抗 **ASIC/FPGA 专用矿机**不如 scrypt/Argon2（后两者是内存困难型）。

## 三、现代之选：Argon2（OWASP 第一名）

Argon2 是 2015 年 Password Hashing Competition 的冠军，也是 OWASP 密码存储速查表的**首选**。它有三种变体：

- **Argon2d**：抗 GPU 破解最强（数据依赖内存访问），但侧信道风险高；
- **Argon2i**：抗侧信道，但抗 GPU 稍弱；
- **Argon2id**：混合模式，**默认推荐**。

Argon2 有三个可调参数：

```java
// 以 jBcrypt 同源的 argon2-jvm 为例
Argon2 argon2 = Argon2Factory.create(Argon2Factory.Argon2Types.ARGON2id);
// 参数：内存 64MB，迭代 3 次，并行度 4
String hash = argon2.hash(3, 64 * 1024, 4, password.toCharArray());
argon2.wipeArray(password.toCharArray()); // 主动擦除内存中的明文
```

| 参数 | 含义 | 推荐值（OWASP） |
|---|---|---|
| m（内存） | 占用 KiB 数 | 19456 KiB（19MB）起步，交互场景 64MB |
| t（迭代） | 迭代次数 | 2 起步 |
| p（并行度） | 线程数 | 1（在线服务单线程防 DoS） |

Argon2 是**内存困难型**算法：需要大块内存且访问模式依赖输入，专用矿机的成本优势被大幅抹平——这是它超越 BCrypt 的核心。

> 关键提醒：Argon2 需要依赖 `BouncyCastle` 或 `argon2-jvm`（JNI 调原生库）。生产选型时如果团队没精力引入原生依赖，**BCrypt（纯 Java 实现）依然是安全且务实的默认选择**——安全上够用，生态成熟，Spring Security 开箱即用。

## 四、Spring Security 落地：PasswordEncoder 体系

Spring Security 5+ 用 `PasswordEncoder` 接口抽象密码编码与校验，核心方法是 `encode()` 和 `matches()`。默认推荐用 **`DelegatingPasswordEncoder`**，它的哈希串带前缀标明算法：

```
{bcrypt}$2a$12$...    ← BCrypt
{argon2}$argon2id$v=19$m=65536,t=3,p=4$...
{noop}123456          ← 明文（仅测试用！）
```

### 1. 推荐配置：BCrypt + cost 12

```java
@Bean
public PasswordEncoder passwordEncoder() {
    // 生产推荐：BCrypt，cost 12
    return new BCryptPasswordEncoder(12);
}

// 或者用 DelegatingPasswordEncoder 支持未来算法迁移
@Bean
public PasswordEncoder passwordEncoder() {
    return PasswordEncoderFactories.createDelegatingPasswordEncoder();
    // 默认委托给 BCrypt，哈希格式 {bcrypt}$2a$10$...
}
```

注册用户时加密：

```java
user.setPassword(passwordEncoder.encode(rawPassword));
```

登录校验由框架完成——`DaoAuthenticationProvider` 的核心逻辑就是调用 `passwordEncoder.matches(rawPassword, storedHash)`：

```java
// Spring Security 内部逻辑（简化）
public Authentication authenticate(Authentication authentication) {
    // 1. 按用户名查库，拿到 {bcrypt}$2a$12$... 形式的 storedHash
    // 2. 校验
    if (!passwordEncoder.matches(rawPassword, storedHash)) {
        throw new BadCredentialsException("密码错误");
    }
    // 3. 通过后，擦除明文密码，返回认证信息
}
```

### 2. 密码升级策略：校验通过后"顺手"换新算法

老系统存量密码是 MD5 加盐的怎么办？用 `DelegatingPasswordEncoder` + 自定义校验逻辑平滑升级：

```java
@Component
public class CustomPasswordEncoder implements PasswordEncoder {

    @Override
    public boolean matches(CharSequence rawPassword, String encodedPassword) {
        if (encodedPassword.startsWith("{bcrypt}")) {
            return bcryptEncoder.matches(rawPassword, encodedPassword);
        }
        // 老格式：MD5(盐+密码)，校验通过后触发 upgradeEncoding
        String legacy = legacyMd5Encoder.matches(rawPassword, encodedPassword);
        return legacy;
    }

    @Override
    public boolean upgradeEncoding(String encodedPassword) {
        // 老格式或 cost 低于当前标准的，返回 true → 下次登录自动重加密
        return !encodedPassword.startsWith("{bcrypt}$2a$12$");
    }
}
```

`upgradeEncoding()` 返回 `true` 时，Spring Security 会在认证成功后**用当前 encoder 重新 encode 并更新数据库**——用户无感知地完成算法迁移，这是生产环境密码治理的标准姿势。

### 3. 登录接口防爆破：别让 BCrypt 白算

BCrypt 单次 200ms+，正好也成了**账号爆破的放大器**——攻击者用弱密码字典撞库，每个请求都让服务器白白消耗几百 ms CPU。必须叠加防护：

1. **登录失败限流**：IP + 账号双维度，Redis 计数，失败 5 次锁定 15 分钟；
2. **验证码**：失败 3 次后强制图形/滑块验证码；
3. **全链路 HTTPS**：防止中间人抓包拿密码；
4. 审计日志：记录登录失败来源，异常告警。

## 五、算法横向对比与选型建议

| 算法 | 类型 | 内存困难 | Java 生态 | OWASP 评级 | 适用 |
|---|---|---|---|---|---|
| MD5/SHA-1 | 普通哈希 | 否 | 原生 | ❌ 禁止 | 仅做完整性校验 |
| SHA-256 + 盐 | 普通哈希 | 否 | 原生 | ❌ 不推荐 | 无（速度即原罪） |
| PBKDF2 | KDF | 否 | 原生支持 | ⚠️ 可用（加高迭代） | 兼容旧系统 |
| BCrypt | KDF | 弱 | Spring 原生 | ✅ 推荐 | **Java 默认首选** |
| scrypt | KDF | 强 | 需依赖 | ✅ 推荐 | 高安全场景 |
| Argon2id | KDF | 强 | 需 BouncyCastle/JNI | ✅✅ 首选 | 新系统/最高标准 |

**选型结论**：
- 新项目、Spring 生态：**BCryptPasswordEncoder(cost=12)**，零额外依赖，安全达标；
- 极致安全 / 密码属于核心资产（金融、政务）：**Argon2id**（m=64MB, t=3, p=1 起步，按硬件上调）；
- 存量 MD5/明文：DelegatingPasswordEncoder + `upgradeEncoding` 平滑迁移。

## 面试连环问

**Q：MD5 加盐后为什么还不安全？**
A：加盐解决了彩虹表，但 MD5 计算太快（GPU 每秒数十亿次），攻击者可以对单个用户暴力穷举弱密码；且盐若为固定值或可预测，安全性进一步下降。核心问题是"快"，需要慢哈希算法。

**Q：BCrypt 的哈希串里为什么能看到盐？盐不是机密吗？**
A：盐不是机密，它的作用是让**相同密码产生不同哈希**、破坏彩虹表的批量预计算。盐随哈希一起存储是标准做法（校验时需要它），安全性不依赖盐保密。

**Q：BCrypt cost 参数怎么定？**
A：在目标硬件上压测，取"单次 250ms~1s"区间内尽量大的值；同时评估登录接口 QPS 承受力。2026 年推荐 12，硬件更强可上 13~14。

**Q：Spring Security 如何平滑升级老系统的密码算法？**
A：用 DelegatingPasswordEncoder 支持多种前缀格式；重写 matches() 兼容旧算法；upgradeEncoding() 在认证成功后自动用新算法重加密存储。

**Q：为什么 Argon2 比 BCrypt 更抗硬件破解？**
A：Argon2 是内存困难型算法，需要 GB 级内存带宽且访问模式依赖输入，GPU/ASIC 难以并行利用；BCrypt 内存占用固定且小，专用硬件可以堆并行度。

## 总结

密码存储安全的三条铁律：**① 绝不能用 MD5/SHA 等快速哈希直接存密码；② 必须用带盐的慢哈希（BCrypt 起步，Argon2id 最佳）；③ 算法参数要可调、格式要可迁移**。落到 Spring 生态，就是 `BCryptPasswordEncoder(12)` + `DelegatingPasswordEncoder` + `upgradeEncoding` 三件套。最后记住：密码安全是"库被拖走也不怕"的底线设计，别把安全寄托在"数据库不会泄露"的假设上。
