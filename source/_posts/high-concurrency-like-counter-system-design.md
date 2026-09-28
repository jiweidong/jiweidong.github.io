---
title: 【系统设计】高并发点赞系统架构设计：Redis 计数、去重、热点与异步落库全解析
date: 2026-09-28 08:20:00
tags:
  - Java
  - 系统设计
  - Redis
  - 高并发
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】高并发点赞系统架构设计：Redis 计数、去重、热点与异步落库全解析

## 面试官：设计一个点赞系统，10 万 QPS，要求点赞数实时准确、不重复、不能丢

看起来是个"小而美"的功能，实际上它把高并发系统的经典难点全踩了一遍：**写放大（大量高并发写）、唯一性约束（去重）、计数一致性（并发加减）、热点（大 V 爆款）、持久化（不能丢）、以及"读多写更多"的混合负载**。

很多人第一反应是"一张表 `insert into likes(...) unique key(user_id, post_id)` 完事"。这个方案在小流量下能用，一问"10 万 QPS 怎么办"就崩了。本文从需求拆解一路讲到可落地的分片架构。

---

## 一、需求与约束拆解

先把模糊需求变成可设计的约束：

| 需求 | 隐含技术问题 |
|---|---|
| 10 万 QPS 点赞 | 单机 MySQL 写不动，必须前置缓存/异步 |
| 不能重复点赞 | 需要 `(userId, postId)` 唯一性判断，且要**原子** |
| 点赞数实时准确 | 计数必须强一致或准实时，不能等对账 |
| 不能丢 | 缓存是易失的，必须有持久化 + 补偿 |
| 取消点赞 | 计数可减，且需处理"未点赞却取消"的异常 |
| 显示"我是否已赞" | 需要高频点查，命中率要求高 |
| 点赞列表（谁赞了） | 分页查询，且要按时间顺序 |

再补两个现实约束：

- **读写比**：点赞是"写多"，但展示页面是"读更多"（每次刷 Feed 都要读点赞数 + 我是否已赞）；
- **热点极不均匀**：99% 的帖子点赞数 < 100，而 1% 的爆款可能有千万级点赞——**平均值会骗人，必须按热点设计**。

---

## 二、先想清楚：到底哪些数据要存

点赞系统本质维护**三个视图**：

1. **明细**：谁赞了谁（`userId → postId`），用于去重与"我是否已赞"、点赞列表；
2. **计数**：某帖总赞数，用于展示；
3. **反向索引**：某帖的点赞用户列表（按时间排序），用于"谁赞了"页面。

MySQL 建表（持久层）：

```sql
CREATE TABLE t_like (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id   BIGINT UNSIGNED NOT NULL,
  post_id   BIGINT UNSIGNED NOT NULL,
  status    TINYINT NOT NULL DEFAULT 1 COMMENT '1=点赞 0=取消',
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_user_post (user_id, post_id),   -- 去重的最终保证
  KEY idx_post_created (post_id, created_at)    -- 点赞列表分页
) ENGINE=InnoDB;

CREATE TABLE t_like_count (
  post_id BIGINT UNSIGNED NOT NULL,
  cnt     BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (post_id)
) ENGINE=InnoDB;
```

**但 MySQL 绝对不能直接承接 QPS**：唯一键冲突是行锁 + 索引维护，10 万 QPS 下锁竞争和 redo 写入会把数据库打爆。所以 MySQL 在这里的角色是**最终落地的持久化层**，而不是高并发入口。

---

## 三、核心架构：Redis 前置 + Lua 原子 + 异步落库

```
                    ┌──────────────────────────────────────┐
   写: 点赞/取消    │  Redis Cluster                        │
   ───────────────▶ │  ├ set:like:u:{postId}   (去重集合)    │
                    │  ├ hash/string:like:c:{postId}(计数)  │
                    │  └ zset:like:z:{postId} (时间排序)     │
                    └──────────────┬───────────────────────┘
                                   │ 异步（MQ/Kafka）
                                   ▼
                    ┌──────────────────────────────────────┐
                    │  MySQL: t_like / t_like_count         │
                    │  （唯一键兜底 + 对账补偿）             │
                    └──────────────────────────────────────┘
```

三层各司其职：

- **Redis**：承接 10 万 QPS，提供原子性与低延迟；
- **异步链路**：把"点赞事件"投到 Kafka，削峰填谷，让 MySQL 以稳定速率消费；
- **MySQL**：唯一键是**最终真相**，即使 Redis 出错也能靠对账修复。

---

## 四、原子性：为什么必须用 Lua

一个点赞动作包含多个步骤：

1. 判断用户是否已赞（`SISMEMBER`）；
2. 未赞则加入集合（`SADD`）；
3. 计数 +1（`INCR`）；
4. 记录到 ZSet（`ZADD`）；
5. 发送异步事件。

**这五步必须原子**，否则并发下会出现"重复计数""计数漏加"。用 Lua 脚本把 1~4 包成一次原子执行：

```lua
-- like.lua: KEYS[1]=set:like:u:{postId} KEYS[2]=cnt:like:{postId} KEYS[3]=zset:like:{postId}
-- ARGV[1]=userId ARGV[2]=timestamp ARGV[3]=ttl(-1 表示不过期)
local setKey = KEYS[1]
local cntKey = KEYS[2]
local zsetKey = KEYS[3]
local userId = ARGV[1]
local ts = tonumber(ARGV[2])

-- 1) 已赞则幂等返回
if redis.call('SISMEMBER', setKey, userId) == 1 then
    return 0
end

-- 2) 写入集合、计数、时间序
redis.call('SADD', setKey, userId)
redis.call('INCR', cntKey)
redis.call('ZADD', zsetKey, ts, userId)

local ttl = tonumber(ARGV[3])
if ttl > 0 then
    redis.call('EXPIRE', setKey, ttl)
    redis.call('EXPIRE', cntKey, ttl)
    redis.call('EXPIRE', zsetKey, ttl)
end
return 1   -- 1 表示本次是有效点赞
```

取消点赞同理，只是把 `SREM` / `DECR` / `ZREM` 反过来，**并且必须判断"是否真的赞过"才能减计数**，否则会出现负数：

```lua
if redis.call('SISMEMBER', setKey, userId) == 0 then
    return 0        -- 没赞过，取消操作直接幂等返回，不动计数
end
redis.call('SREM', setKey, userId)
-- 计数保护，避免减到负数
local c = tonumber(redis.call('GET', cntKey) or '0')
if c > 0 then redis.call('DECR', cntKey) end
redis.call('ZREM', zsetKey, userId)
return 1
```

**关键点：Redis 单线程执行 Lua，脚本执行期间不会有其他命令插入，天然满足原子性。** 这也意味着**脚本必须写短**——一个耗时 10ms 的 Lua 会阻塞整个 Redis 实例，这在 10 万 QPS 下是灾难。所以脚本里绝对不能做 `SMEMBERS`（大集合遍历）这类操作。

---

## 五、去重：Set / Bitmap / BloomFilter 怎么选

"是否已赞"的判定方案：

| 方案 | 内存 | 时间复杂度 | 适用 |
|---|---|---|---|
| Redis Set（`SADD`） | 每用户约 40~80B | O(1) | 通用，**推荐** |
| Bitmap（`SETBIT userId 1`） | 用户数/8 字节 | O(1) | userId 稠密且连续时最优 |
| HyperLogLog | 极小（12KB） | O(1) | 只统计**去重总数**，不能判成员；不适用于点赞 |
| BloomFilter | 极小 | O(1) | 判"未赞"极快，有假阳性；适合前置过滤 |
| MySQL 唯一键 | — | 索引查找 | 最终兜底 |

**Bitmap 的取舍**：若 userId 是自增且总量可控（比如 1 亿以内），一个帖子的点赞 Bitmap 只需 12.5MB；但**若 userId 是雪花 ID（几十位）会直接爆炸**，这时 Bitmap 不可用。

**生产常见组合**：

- 小帖（占比 99%）：Redis Set，随帖过期；
- 大帖（爆款）：Bitmap 或**分桶 Set**（`like:u:{postId}:{bucket}`，bucket = userId % 64），避免单 key 过大；
- 极热帖：本地缓存（Caffeine）+ 布隆过滤器前置，挡住对 Redis 的重复击穿。

> 面试追问：**"为什么不用 HyperLogLog 存点赞用户？"**
>
> 答：HyperLogLog 只能估算**基数**（去重后的数量），无法判断"某个 userId 是否在集合中"。点赞需要 `SISMEMBER` 式的成员判定和"谁赞了"的明细，所以只能用 Set/Bitmap。

---

## 六、热点治理：大 V 爆款怎么做

这是整个系统最难的部分。当一个帖子火了，`postId` 对应的几个 key（Set/计数/ZSet）会承受**几乎全部 QPS**。Redis Cluster 按 key 分片，同一个 key 只落一个分片 → **单分片被打满，集群其他节点闲置**。

### 6.1 计数拆桶（Counter Sharding）

把总计数拆成 N 个桶，写入时随机/按 userId 散列：

```
like:cnt:{postId}:shard:{0..N-1}
```

读时把 N 个桶相加：

```java
long count = 0;
for (int i = 0; i < N; i++) {
    String v = redis.get("like:cnt:" + postId + ":shard:" + i);
    count += v == null ? 0 : Long.parseLong(v);
}
```

**分桶把单 key 的写压力平摊到 N 个切片**，N 通常取 16~64。代价是**读要聚合 N 次**（用 `MGET` 一次搞定，网络往返只有 1 次），且**不能用 `INCR` 的返回值当准确总数**。

### 6.2 本地缓存 + 异步合并

- 计数读走 **Caffeine 本地缓存**（TTL 100ms~1s），把热点读挡在 Redis 之前；
- 写走 Redis，**计数读"宁可用 1 秒前的旧值"**，用户体验无感，但 Redis 压力骤降。

这是典型的**"牺牲强一致换吞吐"**，点赞数场景完全可接受（没人会因为点赞数差 1 秒而投诉）。

### 6.3 写合并（Batch）

对同一个帖子的并发点赞，可在应用层做**微批**：把 100ms 内对同一 key 的 N 次操作合并成一次 Lua/一次 pipeline，极大降低 Redis QPS。

---

## 七、持久化：异步落库 + 幂等 + 对账

Redis 是缓存，**不能作为唯一真相**。持久化链路：

```
点赞请求 → Redis（立即返回）→ Kafka(topic=like-event) → 消费者 → MySQL upsert
```

### 7.1 事件消息设计

```json
{
  "eventId": "uuid",          // 用于消费端幂等
  "userId": 10086,
  "postId": 888888,
  "action": "LIKE",           // LIKE / UNLIKE
  "ts": 1760000000000
}
```

### 7.2 消费端幂等

MySQL 侧用 `INSERT ... ON DUPLICATE KEY UPDATE status=1` + 唯一键实现天然幂等：

```sql
INSERT INTO t_like(user_id, post_id, status, created_at, updated_at)
VALUES (#{userId}, #{postId}, 1, NOW(3), NOW(3))
ON DUPLICATE KEY UPDATE
  status = VALUES(status),
  updated_at = NOW(3);

INSERT INTO t_like_count(post_id, cnt)
VALUES (#{postId}, 1)
ON DUPLICATE KEY UPDATE cnt = cnt + #{delta};   -- delta 由"状态是否真的变化"决定
```

注意 `cnt` 的增减必须**基于状态是否发生真实变化**：如果 MySQL 里该行已经是 `status=1`，再来一条 `LIKE` 就不能再加计数——所以消费者要先判断变更是否生效（可用 `ROW_COUNT()` 或先 select 比对），否则会重复计数。

### 7.3 对账补偿（最重要的一环）

**异步链路一定会丢事件**（Kafka 消息过期、消费异常、Redis 挂掉）。所以必须有**对账任务**：

```
定时（如每 5 分钟）:
1. 采集"活跃帖子"列表（近 N 分钟有变更的 postId，来自 Redis 变更集或 Kafka 的 postId 去重）
2. 用 Redis 的 SCARD / 分桶求和得到"缓存计数"
3. 查 MySQL 的 t_like_count 得到"持久化计数"
4. 不一致 → 以 MySQL 明细为准重算，回写 Redis
```

更稳的做法是**以 MySQL 明细重算为准**：`select count(1) from t_like where post_id=? and status=1`，然后 `SET` Redis 计数。这样即使 Redis 完全挂掉重启，也能全量恢复。

---

## 八、读路径：三种高频查询怎么优化

| 查询 | 方案 |
|---|---|
| 点赞数 | 本地缓存 → Redis 计数（分桶聚合）→ MySQL 兜底 |
| 我是否已赞 | `SISMEMBER like:u:{postId} userId`，命中即返回；miss 才查 MySQL |
| 谁赞了（分页） | `ZREVRANGE like:z:{postId} start stop`，按时间倒序 |

分页要注意两个坑：

1. **`ZREVRANGE` 的 start/stop 是下标**，深分页（第 1000 页）性能退化，且并发插入会导致**漂移**。解决方案：用**时间游标分页** `ZREVRANGEBYSCORE like:z:{postId} (lastTs -inf LIMIT 0 20`；
2. **隐私与合规**：点赞列表天然暴露社交关系，需考虑访问控制和批量接口的抗刷。

还要处理**点赞列表为空但计数不为 0** 的不一致（缓存过期导致），表现形式是"显示 100 赞但列表为空"——用"计数小于阈值时直接回源 MySQL 查列表"来兜底。

---

## 九、容量与成本估算（面试加分项）

假设 1 亿 DAU，人均每天点赞 20 次 → **20 亿次/天 ≈ 2.3 万 QPS 均值，峰值 ×5 ≈ 12 万 QPS**。

**Redis 内存**（Set 方案，1 亿帖子有赞、平均 20 个赞）：

```
每个 Set 元素 ≈ 40B（intset/ziplist 编码下更小）+ 对象开销
1 亿帖 × 20 元素 × 50B ≈ 100 GB
```

需要 **Redis Cluster 多分片 + 冷帖过期策略**：只对"活跃帖/近期帖"保留缓存计数，冷帖回源 MySQL（`postId` 维度 TTL 7 天）。

**MySQL 存储**：

```
20 亿行/天 × 60B ≈ 120 GB/天 → 月增 3.6 TB
```

必须**分库分表**（按 `post_id` 哈希，或按 `user_id` 便于"我的点赞列表"）+ 冷热分离归档。

---

## 十、极端情况与降级

| 场景 | 应对 |
|---|---|
| Redis 节点故障 | 主从/Cluster 自动故障转移；同时**本地缓存兜底读**，写降级为"仅落库 + 后续补偿" |
| Redis 全挂 | 直接写 MySQL（限流 + 队列缓冲），恢复后回填缓存 |
| Kafka 消费积压 | 扩容消费者 + 批量写入（`rewriteBatchedStatements=true`） |
| 刷赞攻击 | 接口签名 + 频控（用户级/设备级令牌桶）+ 风控名单 |
| 大 V 热点 | 计数分桶 + 本地缓存 + 微批 + 可能的话做"点赞幂等令牌" |
| 数据不一致 | 定时对账 + 以 MySQL 明细重算为准 |

**降级原则**：**点赞数可以短暂不准，但绝对不能丢数据。** 所以宁可牺牲计数实时性，也要保证事件进 Kafka / 明细落 MySQL。

---

## 十一、面试追问连环炮

**Q：为什么用 Lua 而不是 Redis 事务（MULTI/EXEC）？**
A：`MULTI` 只保证"命令打包不被插入"，**不保证原子回滚**（中间命令失败前面的仍生效），且无法做条件判断（"若已赞则返回"）。Lua 能在服务端做条件逻辑并原子执行，是更合适的选择。

**Q：Redis 挂了，点赞数怎么办？**
A：三件事——① 读降级到 MySQL/本地缓存；② 写降级到"仅落库 + 进本地队列"，恢复后回填 Redis；③ 对账任务在全量恢复时以 MySQL 明细重算 Redis 计数。

**Q：怎么保证 Redis 计数和 MySQL 计数最终一致？**
A：靠三个机制叠加：**唯一键幂等去重 + 变更检测（只有状态真变化才改计数）+ 定时对账（以明细为准重算）**。前两者防止发散，对账兜住漂移。

**Q：为什么不用 Redis 的 `INCR` 返回值直接当点赞数展示？**
A：因为热点时用了计数分桶，`INCR` 只反映单个桶；且分桶 + 异步落库后，Redis 计数本身是"准实时"，不是强一致。展示层必须接受"1 秒内可能差几个"。

**Q：点赞列表是不是应该放在 MySQL？**
A：是的，Redis 的 ZSet 只做**热帖的近期列表**缓存（如最近 1000 个赞），完整的"谁赞了"走 MySQL（`idx_post_created`）。避免把历史全量放进 Redis。

**Q：如何防止用户疯狂点赞刷数据？**
A：接口层限流（令牌桶，按用户 + 设备 + IP 维度）、请求签名 + 时间戳防重放、风控名单、以及**点赞与"关注/活跃度"挂钩的权重体系**（刷赞不计入热度榜）。

---

## 十二、总结

把点赞系统拆到底，就是四件事：

1. **入口必须前置**：Redis + Lua 承接高并发，用原子脚本保证"判定 + 计数 + 记录"不撕裂；
2. **去重要双保险**：Redis 精准判断 + MySQL 唯一键兜底；
3. **热点必须分片**：计数拆桶、本地缓存、写入微批，否则单 key 会打穿整个集群；
4. **一致性靠对账**：异步落库 + 唯一键幂等 + 定时以明细重算，把"最终一致"做成可运维的机制。

这套"缓存扛流量 + 消息削峰 + 数据库兜底 + 对账保一致"的骨架，不只适用于点赞——**计数、收藏、关注、投票、热度值**等一大类"高频小写入 + 展示型计数"的场景，都是同一个解法。
