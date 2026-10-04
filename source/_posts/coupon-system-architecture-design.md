---
title: 【系统设计】高并发优惠券系统架构设计：券模板、库存扣减、领券防刷与核销对账
date: 2026-10-04 08:00:00
tags:
  - 系统设计
  - 高并发
  - 优惠券
  - 分布式
categories:
  - 系统设计
  - 后端架构
author: 东哥
---

# 【系统设计】高并发优惠券系统架构设计：券模板、库存扣减、领券防刷与核销对账

## 面试官：设计一个电商优惠券系统，要能扛住大促的领券洪峰

优惠券看起来是个"发钱"的小功能，但它几乎把分布式系统里所有棘手问题都凑齐了：

- **超卖**：100 万张券，1 秒 50 万请求，怎么保证不多发一张？
- **防刷**：黄牛用脚本批量领券，怎么拦住？
- **一致性**：Redis 扣了库存，MySQL 没落库怎么办？
- **对账**：用户说"我明明领了券却用不了"，怎么查？
- **过期**：几千万张券同时过期，怎么回收？

能把这几个问题讲清楚，系统设计这一轮基本就稳了。

---

## 一、需求拆解与领域建模

先别急着设计表。优惠券在业务上至少要拆成三个概念，这是很多人一上来就搞混的地方：

| 概念 | 含义 | 生命周期 |
| --- | --- | --- |
| 券模板（Template） | "满 100 减 20"这条规则本身 | 运营创建 → 下线 |
| 券实例（User Coupon） | 用户 A 领到的那一张具体券 | 领取 → 使用/过期 |
| 券码（Code） | 券实例的可核销凭证（一串数字/字母） | 生成 → 核销 |

模板是**规则**，实例是**资产**，码是**凭证**。三者分开建模，后面所有设计都会顺很多。

再确认几个关键产品约束：

1. **券类型**：满减券、折扣券、立减券、兑换券。
2. **适用范围**：全站通用 / 指定品类 / 指定商品 / 指定店铺。
3. **叠加规则**：能否与平台券、店铺券叠加（这是最容易被追问的点）。
4. **有效期**：固定区间 或 领取后 N 天生效。
5. **数量**：限量（有库存）或 不限量（活动券）。

---

## 二、表结构设计

```sql
-- 券模板
CREATE TABLE coupon_template (
  id              BIGINT PRIMARY KEY AUTO_INCREMENT,
  name            VARCHAR(128)   NOT NULL,
  type            TINYINT        NOT NULL COMMENT '1满减 2折扣 3立减',
  discount_rule   JSON           NOT NULL COMMENT '门槛/面额/折扣率',
  scope_type      TINYINT        NOT NULL COMMENT '1全站 2品类 3商品 4店铺',
  scope_value     JSON           NULL,
  total_stock     INT            NOT NULL DEFAULT -1 COMMENT '-1 不限量',
  per_user_limit  INT            NOT NULL DEFAULT 1,
  valid_start     DATETIME       NULL,
  valid_end       DATETIME       NULL,
  valid_days      INT            NULL COMMENT '领取后 N 天有效',
  status          TINYINT        NOT NULL DEFAULT 0,
  created_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_status (status, valid_end)
) COMMENT '券模板';

-- 用户券实例
CREATE TABLE user_coupon (
  id           BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id      BIGINT      NOT NULL,
  template_id  BIGINT      NOT NULL,
  coupon_code  VARCHAR(32) NOT NULL,
  status       TINYINT     NOT NULL DEFAULT 0 COMMENT '0未使用 1已使用 2已过期 3已冻结',
  order_id     BIGINT      NULL COMMENT '核销订单',
  received_at  DATETIME    NOT NULL,
  expire_at    DATETIME    NOT NULL,
  used_at      DATETIME    NULL,
  UNIQUE KEY uk_code (coupon_code),
  KEY idx_user_status (user_id, status, expire_at),
  KEY idx_template (template_id)
) COMMENT '用户券';
```

⚠️ 一个面试常考点：**`user_coupon` 是按 `user_id` 分库分表的**，因为主查询永远是"查我的券"。但运营需要按模板维度统计，那是走**异步双写到统计库**，不要在业务库上做跨分片聚合。

---

## 三、库存扣减：防止超卖

大促领券的 QPS 是十万级的，绝不能让请求都打到 MySQL。标准做法是 **Redis 原子扣减 + 异步落库**：

```lua
-- 领券 Lua 脚本：原子完成 校验 + 限领 + 扣库存 + 写领取记录
-- KEYS[1] 库存 key   KEYS[2] 用户已领集合 key
-- ARGV[1] userId     ARGV[2] perUserLimit
local stock = redis.call('GET', KEYS[1])
if not stock then
  return -1                 -- 库存未预热
end
if tonumber(stock) <= 0 then
  return -2                 -- 已领完
end
local cnt = redis.call('SCARD', KEYS[2])
if cnt >= tonumber(ARGV[2]) then
  return -3                 -- 超过个人限领
end
redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
redis.call('EXPIRE', KEYS[2], 86400 * 30)
return 1
```

Lua 脚本在 Redis 中单线程原子执行，天然杜绝并发超卖。返回码对应业务提示，避免把 Redis 细节泄漏到上层。

**库存预热的坑**：如果缓存丢了怎么办？答案是 **回源重建 + 用已发放数量反推**：

```text
剩余库存 = total_stock - (已成功落库的领取数)
```

重建前先加一把分布式锁（`SETNX`），并且**重建期间拒绝领券**（fail-closed），否则缓存击穿瞬间就会有超卖。

**分段库存**（hot-key 缓解）：把一个模板的库存拆成 N 份，每个实例持有 `stock/N`，请求按 `userId % N` 路由。这样单 key 的 QPS 降到 1/N。代价是可能出现"某个分片空了、另一个还有"，需要允许分片间调拨或适度冗余。

---

## 四、领券防刷

防刷是分层的，单靠一层拦不住：

| 层级 | 手段 | 拦截目标 |
| --- | --- | --- |
| 接入层 | IP / 设备指纹 / 验证码 限流 | 脚本、肉鸡 |
| 用户层 | 个人限领（Redis Set + DB 唯一索引双保险） | 单账号囤券 |
| 业务层 | 风控名单、画像评分、黑产识别 | 黄牛工作室 |
| 数据层 | 唯一索引 `uk_user_template` 兜底 | 一切并发穿透 |

注意最后一层：**业务唯一索引是最后的防线**。哪怕 Redis 被判重击穿，DB 层 `UNIQUE(user_id, template_id)` 也会让重复插入失败：

```sql
INSERT INTO user_coupon(user_id, template_id, ...) VALUES (...);
-- DuplicateKeyException → 直接返回"您已领取过"
```

个人限领计数如果用 Redis Set 存 userId，大活动下内存会爆，可以换成**布隆过滤器 + 计数 key**，或者在 DB 侧用 `COUNT(*)` 缓存。

---

## 五、券码生成：别让黄牛猜出来

券码有两个流派：

1. **预生成**：活动开始前批量生成 N 个码写库。优点是可控、可对账；缺点是百万级码写入慢，且容易被内部泄漏。
2. **实时生成**：领取时生成。灵活，但码必须**不可预测**。

如果券码是连续的（比如 `1000001`），黄牛直接遍历就能薅空。正确做法是**加密混淆**：

```java
// 自增ID → 不可预测的券码（Feistel 网络或简单可逆变换）
public String encode(long id, long secretSeed) {
    long x = id * secretSeed % MOD;   // 线性同余
    return Base32.encode(x) + checksum(x);  // 加校验位防手输错误
}
```

面试加分点：一定要提**校验位**。用户手输券码时，一个字符打错应该被本地校验拦下，而不是打到后端去查库。

---

## 六、核销与对账：状态机 + 幂等

券的生命周期是一个状态机：

```text
未使用 ──核销──▶ 已使用
   │
   └──到期──▶ 已过期
   │
   └──退款──▶ 未使用（回退）
```

核销必须是**幂等**的，用户连点两次、或网络重试，都不能扣两次：

```java
@Transactional
public void redeem(String code, long orderId) {
    // 乐观锁 + 状态CAS，天然幂等
    int rows = couponMapper.updateStatus(
        code, Status.UNUSED, Status.USED, orderId);
    if (rows == 0) {
        // 要么已核销，要么不存在 —— 幂等返回成功
        throw new IdempotentException("coupon already used or missing");
    }
}
```

```sql
UPDATE user_coupon
SET status = 1, order_id = #{orderId}, used_at = NOW()
WHERE coupon_code = #{code} AND status = 0;
```

**对账**是保证最终一致性的关键。每天跑离线任务比对：

- Redis 已发放数 vs `user_coupon` 实际行数；
- 券核销数 vs 订单优惠金额；
- 差异写入 `coupon_reconcile_diff`，人工介入或自动补发。

分布式场景下，券服务和订单服务可以用**本地消息表 / 事务消息**做最终一致，而不是上 XA——XA 在券这种高频场景下性能代价太大。

---

## 七、过期回收怎么做

三种方案对比：

| 方案 | 原理 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 定时扫描 | `WHERE status=0 AND expire_at<NOW()` | 简单 | 大表扫不动，写放大 |
| 延迟队列 | 领券时投递到期消息 | 准实时 | 消息堆积、需要可靠投递 |
| 分片轮询 | 按 expire_at 分桶，小批多批 | 可控 | 延迟最多一个轮询周期 |

生产上一般是 **分片轮询 + 缩短扫描区间**（比如每 10 分钟扫一次未来 10 分钟内到期的券），既能控制延迟，又避免全表扫描。券过期**只是改状态**，不要删数据——删了就失去对账和审计依据了。

---

## 八、券的分层与组合优化

优惠券真正复杂的地方在于**叠加规则**。成熟电商一般会把券分成几层：

| 层级 | 例子 | 是否与同层叠加 |
| --- | --- | --- |
| 平台券 | 满 100 减 20 | 同层互斥，取最优 |
| 店铺券 | 满 200 减 30 | 同层互斥，取最优 |
| 品类券 | 家电 9 折 | 可跨层叠加 |
| 商品券 | 单品直降 | 可与以上叠加 |

**叠加计算不能放在核销时做，必须在下单页预计算**。因为叠加规则的排列组合是组合爆炸的（N 张券有 2^N 种组合），实时计算会把下单接口拖垮。标准做法是：

```text
下单页渲染时：
  1. 拉取用户可用券（走缓存）
  2. 结合购物车商品，在内存中做贪心/动态规划求最优组合
  3. 结果缓存在 Redis：key = coupon:best:{userId}:{cartHash}，TTL 5 分钟

核销时：
  只做“这张券在当前订单上是否可用”的校验，不重新算最优
```

**幂等与越权防护**：核销时必须校验券归属（`user_coupon.user_id == 当前用户`），否则会出现用户 A 拿了用户 B 的券码去核销的越权问题。这也是券码不能包含用户明文 ID、而应该用不可预测随机码的原因之一。

## 面试官追问

**Q：Redis 扣减成功后进程挂了，消息没发出去怎么办？**

A：这是典型的"本地事务 + 远程调用"一致性。两种解法：
1. 把"扣库存"和"写领取记录"放到同一个 Lua + 同一条 MQ 消息里，用**事务消息**保证。
2. 更稳的是**对账补偿**：Redis 扣减只是"预占"，真正的券实例在 DB 落库成功才算数；定时任务比对预占与实际发放，回滚差额。

**Q：库存分段后，分片不均衡怎么办？**

A：允许**分片间调拨**需要分布式协调，代价高。更常见的做法是接受轻微浪费（预留 3%~5% 冗余库存），或者在分片余量低于阈值时从公共池补充。核心是：宁可少发一点，不能超发。

**Q：券能否叠加怎么设计？**

A：不要在核销时动态算。**最优券组合应该在下单页预先算好并缓存**（用户+购物车 hash 作为 key），核销只做校验。因为叠加规则的排列组合是 NP 的，实时算会把下单接口拖垮。

---

## 总结

| 问题 | 核心方案 |
| --- | --- |
| 超卖 | Redis Lua 原子扣减 + 唯一索引兜底 + 对账补偿 |
| 防刷 | 分层拦截 + 业务唯一索引最后防线 |
| 一致性 | 本地消息表/事务消息 + 每日对账 |
| 幂等 | 状态 CAS UPDATE，影响行数为 0 即幂等成功 |
| 过期 | 分片轮询 + 只改状态不删数据 |

优惠券系统的本质是**用可接受的少量不一致（少发几张券）换取高并发下的绝对不超卖**，再通过对账把偏差收敛回一致。想清楚这个 trade-off，面试就赢了一半。
