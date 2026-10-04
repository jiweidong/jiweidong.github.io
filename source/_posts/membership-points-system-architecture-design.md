---
title: 【系统设计】会员积分体系架构设计：积分账务、过期回收、等级体系与防刷
date: 2026-10-04 09:00:00
tags:
  - 系统设计
  - 高并发
  - 会员体系
  - 分布式
categories:
  - 系统设计
  - 后端架构
author: 东哥
---

# 【系统设计】会员积分体系架构设计：积分账务、过期回收、等级体系与防刷

## 面试官：设计一个会员积分系统，积分可以获取、消耗、过期，还要支持等级成长

积分系统看着像 CRUD，实际上它是一个**简化版的账务系统**。一旦你意识到"积分就是钱"，很多设计问题就有了标准答案。

它同时涉及：账务一致性、幂等、高并发扣减、定时过期、风控防刷、等级计算。是系统设计里非常好的综合题。

---

## 一、领域建模：账户 + 流水

第一个要建立的认知：**积分不能只存一个余额字段**。

```text
❌ 错误设计：user_point(user_id, balance)
   —— 无法追溯、无法对账、无法实现"按批次过期"
```

正确设计是**账务双表模型**：

| 表 | 作用 | 特征 |
| --- | --- | --- |
| `point_account` | 账户余额（快照） | 一个用户一行，读多写少 |
| `point_flow` | 流水明细（事实） | 只追加，不修改，可对账 |
| `point_batch` | 批次记录（用于过期） | 每笔收入一个批次 |

```sql
CREATE TABLE point_account (
  user_id      BIGINT PRIMARY KEY,
  balance      BIGINT NOT NULL DEFAULT 0 COMMENT '可用积分',
  frozen       BIGINT NOT NULL DEFAULT 0 COMMENT '冻结积分',
  total_earned BIGINT NOT NULL DEFAULT 0 COMMENT '累计获得',
  total_used   BIGINT NOT NULL DEFAULT 0 COMMENT '累计消耗',
  version      BIGINT NOT NULL DEFAULT 0,
  updated_at   DATETIME NOT NULL
);

CREATE TABLE point_flow (
  id           BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id      BIGINT      NOT NULL,
  biz_no       VARCHAR(64) NOT NULL COMMENT '业务幂等键',
  type         TINYINT     NOT NULL COMMENT '1获取 2消耗 3过期 4回退',
  points       BIGINT      NOT NULL COMMENT '正数获取/负数消耗',
  balance_after BIGINT     NOT NULL COMMENT '变动后余额(冗余,便于对账)',
  batch_id     BIGINT      NULL,
  remark       VARCHAR(255) NULL,
  created_at   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_biz (biz_no, type),
  KEY idx_user_time (user_id, created_at)
);

CREATE TABLE point_batch (
  id            BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id       BIGINT   NOT NULL,
  points        BIGINT   NOT NULL COMMENT '批次总积分',
  remain        BIGINT   NOT NULL COMMENT '批次剩余',
  expire_at     DATETIME NOT NULL,
  status        TINYINT  NOT NULL DEFAULT 0,
  KEY idx_expire (status, expire_at),
  KEY idx_user (user_id, status, expire_at)
);
```

**为什么要有 `point_batch`？** 因为积分过期是按"获得时间 + N 个月"算的（先进先出 FIFO 过期）。如果没有批次，你根本算不清"该过期多少"。

---

## 二、获取与消耗：幂等是生命线

积分变动的第一原则：**任何一个业务动作只能加/扣一次积分**。

`uk_biz (biz_no, type)` 唯一索引就是幂等的基础：

```java
@Transactional
public void changePoints(PointChangeCmd cmd) {
    // 1. 幂等：先插流水，唯一索引冲突即已处理
    try {
        flowMapper.insert(buildFlow(cmd));
    } catch (DuplicateKeyException e) {
        log.warn("duplicate point change, bizNo={}", cmd.getBizNo());
        return; // 幂等返回
    }
    // 2. 更新账户余额（带 CAS 防并发）
    int rows = accountMapper.casUpdate(
        cmd.getUserId(), cmd.getPoints(), cmd.getVersion());
    if (rows == 0) {
        throw new RetryableException("concurrent modify");
    }
}
```

```sql
UPDATE point_account
SET balance = balance + #{delta},
    version = version + 1,
    updated_at = NOW()
WHERE user_id = #{userId}
  AND balance + #{delta} >= 0;   -- 防止扣成负数
```

⚠️ 这里有两个面试重点：

1. **`balance + delta >= 0` 条件更新**，比"先查余额再判断"安全得多。后者在并发下会扣穿。
2. **唯一索引抛异常不要紧**，但要注意事务回滚——如果把幂等判断和业务放在同一个事务里，异常会把整个事务标记回滚。更稳的做法是**先用 `INSERT IGNORE` 或独立的幂等表判断**。

---

## 三、FIFO 批次扣减与过期

消耗积分时，按**最早到期的批次优先扣**（FIFO），这样能让用户少浪费即将过期的积分。

```java
@Transactional
public void consume(long userId, long points, String bizNo) {
    long remain = points;
    // 1. 按 expire_at 升序取可用批次
    List<PointBatch> batches = batchMapper.listAvailable(userId);
    for (PointBatch b : batches) {
        if (remain <= 0) break;
        long deduct = Math.min(b.getRemain(), remain);
        // 2. 条件更新批次剩余，防并发
        int rows = batchMapper.casDeduct(b.getId(), deduct, b.getRemain());
        if (rows == 0) continue;   // 被并发抢了，换下一批
        remain -= deduct;
    }
    if (remain > 0) {
        throw new BizException("积分不足");
    }
    // 3. 记流水 + 扣账户
    // ...
}
```

**过期回收**则是一个定时任务：

```sql
-- 每 10 分钟扫描即将过期的批次（分片轮询，避免全表扫）
SELECT id, user_id, remain
FROM point_batch
WHERE status = 0
  AND expire_at <= DATE_ADD(NOW(), INTERVAL 10 MINUTE)
  AND id % #{shardTotal} = #{shardIndex}
LIMIT 500;
```

对每个批次扣减账户余额，并写一条 `type=3` 的过期流水。注意**过期也要幂等**：批次状态从 0 改 1 用 CAS，只有改成功的那个任务才写流水。

**批量过期优化**：如果一秒钟有几万用户同时过期（比如月初），逐条处理会打爆 DB。解法是把过期拆成"账户变更聚合"，或者提前把到期日**打散**（不同用户积分有效期错开几天）。

---

## 四、防刷与风控

积分 = 钱，必然被薅。常见手段：

| 攻击 | 防御 |
| --- | --- |
| 刷单获取积分 | 订单完成 N 天后才发积分 + 退款自动退回 |
| 脚本批量签到 | 验证码、设备指纹、行为风控 |
| 重复提交任务 | 业务幂等键（`uk_biz`） |
| 内部超发 | 上限校验（单日/单笔上限）+ 对账 |

**退款要退回积分**，这是一个容易被忘的点：用户用积分抵扣下了单，退款时不仅要退钱，还要把扣掉的积分还回去。实现上用 `type=4` 的回退流水，且要**恢复原批次**（把积分还回原来的 `batch_id`，保持过期时间不变），而不是新建一个批次——否则用户可以借退款把积分"续期"。

---

## 五、等级与成长值

等级体系和积分余额是**两套东西**，千万不要混用：

| | 积分（Points） | 成长值（Growth） |
| --- | --- | --- |
| 用途 | 抵扣消费 | 决定会员等级 |
| 会消耗吗 | 会 | **不会**，只增不减 |
| 会过期吗 | 会 | 通常以自然年为周期清零/降级 |

因为成长值"只增不减"，所以它本质上是一个**累计和**，实现上非常简单：直接 `total_earned` 字段累加即可，不需要批次。

等级计算建议**异步化**：积分/成长值变动时发 MQ，由等级服务消费并更新等级，再发通知。避免下单主链路里做等级判断。

```text
下单完成 → MQ → 成长值服务累加 → 等级服务重算等级 → 通知/权益刷新
```

---

## 六、一致性与对账

积分系统必须能"自证清白"：

1. **余额 = 流水累加**：`point_account.balance` 应该等于 `SUM(point_flow.points)`。
2. 每日对账任务：比对两者，差异写入告警表。
3. **批次剩余 = 批次总量 - 已消耗 - 已过期**。

对账公式：

```text
account.balance == SUM(flow.points)               -- 账户级
account.balance == SUM(batch.remain where status=0) -- 批次级
```

如果发现 Redis 缓存余额与 DB 不一致，**以 DB 为准**，重建缓存。

---

## 七、缓存与热点优化

积分查询是高频读（账户页、下单页都要展示），积分变动是高频写，两者都需要专门优化。

### 7.1 缓存设计

```text
Key:   point:balance:{userId}
Type:  String（值为可用余额）
TTL:   7 天（惰性过期）
更新:  积分变动时 INCRBY 同步更新，DB 异步落库
```

⚠️ 关键难点：**"先改 DB 还是先改缓存"**。积分余额不能用"删缓存 + 下次回源"的模式，因为下一次读很可能在异步落库完成前发生，会读到旧值。正确做法是**写时直接 `INCRBY` 更新缓存**，并保证 DB 与缓存的更新顺序；若缓存更新失败，则**删除缓存**让后续读取回源 DB，避免缓存长期陈旧。

```java
public void onPointsChanged(long userId, long delta) {
    String key = "point:balance:" + userId;
    try {
        redis.incrBy(key, delta);
        mq.send(new PointChangeEvent(userId, delta)); // 异步落库
    } catch (Exception e) {
        redis.del(key);  // 缓存已不可信，删掉回源
        throw e;         // 让上游重试，保证不丢变更
    }
}
```

### 7.2 不一致的兜底

即使做了上述处理，仍可能出现缓存与 DB 偏差（比如异步落库最终失败）。所以要加**读时校验**：

1. 用户打开积分明细页时，同步查一次 DB 余额（低频操作，成本可接受）；
2. 缓存与 DB 不一致则以 DB 为准，并重建缓存；
3. 每日对账任务全量比对，发现偏差立即告警。

### 7.3 热点与大账户

积分账户天然按 `userId` 分散，一般不会出现单 key 热点。但两类情况要小心：

- **平台级积分活动**（如全员发积分）：会瞬间产生海量流水，应改为**分批投递 + 限流消费**；
- **企业 / 商户账户**：单账户可能承载大量积分流转，需要单独分片或串行化处理。

## 面试官追问

**Q：积分账户 QPS 很高，怎么优化？**

A：
1. **余额缓存**：Redis 存 `point:balance:{userId}`，读走缓存；写时用 `INCRBY` 同步，DB 异步落。
2. **热点用户分片**：大 V 积分账户会热，但好在积分变动是按用户维度的，天然分散。
3. **流水异步写**：可以先把流水写 MQ/Kafka，再批量落库，DB 只保证最终一致。
4. **冷热分离**：历史流水归档到冷库。

**Q：用户积分被扣成负数怎么排查？**

A：先看 `point_flow`，按 `created_at` 排序还原余额变化轨迹（`balance_after` 就是为这个冗余的）。然后检查是否有：
- 缺少 `balance + delta >= 0` 的条件更新；
- 并发下未加锁导致"查-判断-扣"竞态；
- 批次扣减与账户扣减不在同一事务。

**Q：如何支持"积分 + 现金"混合支付并保证不退积分套利？**

A：核心是**记录订单与积分消耗的映射**（`order_id → 积分消耗明细 + 批次`），退款时按比例或原路退回，并强制"退回原批次"。同时设置风控规则：短时间内频繁"下单-退款"的用户冻结积分功能。

---

## 总结

| 问题 | 方案 |
| --- | --- |
| 账务一致性 | 账户表 + 流水表 + 对账 |
| 幂等 | 业务唯一索引 `uk_biz` |
| 并发扣减 | 条件更新 `balance + delta >= 0` |
| 过期 | 批次 FIFO + 分片轮询任务 |
| 防刷 | 延迟发放 + 风控 + 退款回退原批次 |
| 等级 | 独立成长值，只增不减，异步计算 |

积分系统的核心思想只有一句话：**把它当账务系统做**。账户是快照，流水是事实，批次管理时效，对账保证正确。想通这四点，代码和面试都能写对。
