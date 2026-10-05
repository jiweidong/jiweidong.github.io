---
title: 【系统设计】社交关注关系系统架构设计：关系存储、大V扇出与计数一致性
date: 2026-10-05 08:20:00
tags:
  - 系统设计
  - 高并发
  - 社交
  - 关注
  - 缓存
categories:
  - 系统设计
  - 后端架构
author: 东哥
---

# 【系统设计】社交关注关系系统架构设计：关系存储、大V扇出与计数一致性

## 面试官：设计一个支持亿级用户的关注关系系统

关注关系看起来是"最简单的社交功能"——不就是一张表存 `(follower_id, followee_id)` 吗？

但当你把量级摊开，会发现这里藏着三个非常经典的高并发难题：

1. **存储**：100 亿条关系怎么存、怎么分片？
2. **读写不对称**：普通用户粉丝几百，大 V 粉丝几千万，同一个接口要同时扛住两种极端；
3. **计数一致性**：粉丝数显示 1000 万，点进去只能列出 500 万（因为大 V 粉丝列表根本不给你翻），这个"数字"怎么维护？

面试官问"设计关注系统"，实际上是在考你对**关系图谱、扇出模型、计数与缓存一致性**的综合理解。

---

## 一、需求拆解与量级估算

先把业务模型想清楚。关注系统的核心实体只有三种：

| 实体 | 说明 | 索引方向 |
| --- | --- | --- |
| 关注关系 | A 关注 B | follower → followee |
| 好友关系 | A 与 B 互关（或申请通过） | 双向 |
| 黑名单 | A 拉黑 B | 单向屏蔽 |

还有一些扩展属性：**特别关注、分组、备注、关注时间、来源渠道、是否互关**。

量级估算（按 5 亿注册用户、人均关注 200 算）：

```text
关系总数 = 5 亿 × 200 = 1000 亿条
写入 QPS：峰值关注/取关 50 万/秒（活动/热点事件）
读取 QPS：Feed 流扇出读取 > 500 万/秒
单大 V 粉丝数：上限 5000 万
```

**关键结论：1000 亿条关系必须分库分表，而"大 V 粉丝列表"这种查询在线服务端根本不可能做全量分页。**

这里就必须引入一个核心设计原则：

> **关注关系是"双向查询、单向写入"的——关注列表（我关注了谁）必须强一致可查，粉丝列表（谁关注了我）可以做最终一致、可以截断。**

因为用户视角里：**我关注的人我要能马上看到；谁关注我，晚几秒、只看到前 1000 个也没关系。**

这个"产品预期"直接决定了架构：两条独立的存储链路。

---

## 二、存储选型：三套引擎各司其职

### 2.1 MySQL：关系的事实来源（Source of Truth）

```sql
CREATE TABLE t_follow (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  follower_id BIGINT UNSIGNED NOT NULL,   -- 关注者
  followee_id BIGINT UNSIGNED NOT NULL,   -- 被关注者
  rel_type    TINYINT  NOT NULL DEFAULT 1,-- 1普通 2特别关注
  group_id    INT      NOT NULL DEFAULT 0,
  status      TINYINT  NOT NULL DEFAULT 1,-- 1有效 0取消
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_follower_followee (follower_id, followee_id),
  KEY idx_followee_time (followee_id, create_time)
) ENGINE=InnoDB;
```

分库分表策略：

- **按 `follower_id` 分片**：保证"我关注了谁"的查询单库命中，这是最高频的查询。
- **按 `followee_id` 建异步副本表（宽表/从表）**：用 binlog 同步（Canal/Debezium）生成"谁关注了我"的读副本。
- 分片数：1024 库表，用 `follower_id % 1024` 或一致性哈希。

为什么不做双向都同步写？因为**关注是一次写、两次读（关注列表 + 粉丝列表）**。同步写两张表意味着写放大 2 倍、还要分布式事务。用 binlog 异步生成粉丝副本，把写冲突和一致性复杂度全部后移。

### 2.2 Redis：高性能关系缓存

MySQL 扛不住 500 万 QPS 的关系判断（"我有没有关注他"）。所以 Redis 承担三类职责：

```text
1. 关注列表缓存：SET  follow:list:{userId}  → member = followeeId
2. 粉丝集合（部分）：SET follow:fans:{userId} → 只存"活跃粉丝/前 N 页"
3. 关系判断：SISMEMBER follow:list:{userId} {followeeId}  → O(1)
```

**大 V 的粉丝集合怎么办？** 5000 万粉丝全塞进一个 Redis Set，单 key 内存几个 G，直接触发大 key 问题。方案：

- 大 V 粉丝集合**只存最近/活跃的粉丝**（比如最近 30 天内互动过的），超过阈值直接截断；
- 或用 **分桶 Set**：`follow:fans:{userId}:bucket:{0..1023}`，按 `followerId % 1024` 分桶，单桶几十 KB，可并行取；
- 粉丝列表产品上本身就做了"仅展示前 N 页"的限制，所以缓存也只需前 N 页。

### 2.3 图数据库：用于"关系探索"而非主链路

共同关注、二度人脉、社交推荐属于**图遍历查询**，用 Neo4j 很自然，但**绝不能放在主链路上**：

| 查询 | 引擎 | 是否主链路 |
| --- | --- | --- |
| 我关注列表 | MySQL/Redis | ✅ 主链路 |
| 是否关注 | Redis | ✅ 主链路 |
| 粉丝列表 | MySQL 读副本 | ✅ 主链路 |
| 共同关注 | Redis SINTER 或图库 | ⚠️ 半在线 |
| 二度人脉/推荐 | 离线图计算 | ❌ 离线 |

```text
共同关注的最快实现：SINTER follow:list:A follow:list:B
（Redis 集合交，O(N)，N 取小的那个集合，对小 V 场景毫秒级）
```

---

## 三、大 V 扇出：写扩散还是读扩散

这是关注系统最经典的面试深水区。关注关系本身不扇出，但**关注之后要影响 Feed 流**，就出现了扇出模型选择。

### 3.1 写扩散（Push / Fan-out on Write）

A 发内容时，立刻写进所有粉丝的收件箱（inbox）。

- 优点：读极快（直接读自己的 inbox）
- 缺点：大 V 发一条，要写 5000 万次——**写放大灾难**

### 3.2 读扩散（Pull / Fan-out on Read）

A 发内容只写自己的发件箱（outbox），粉丝读时实时拉取所有关注的人再合并。

- 优点：写极轻
- 缺点：读放大——关注 2000 人，读一次要 merge 2000 个 outbox

### 3.3 混合模型（工业界实际方案）

```text
普通用户（粉丝 < 阈值 T，如 10 万）→ 写扩散，粉丝 inbox 预计算
大 V（粉丝 ≥ T）                 → 读扩散，粉丝读时在线合并
                                      ↓
                              读时：inbox（普通关注） + 拉取大V outbox 合并排序
```

这个阈值通常做成**动态阈值**（`T = 总请求量 / 平均扇出承受能力`），并且大 V 的内容会**缓存在 Rank 服务的热池**里，避免每次真去拉。

面试时能说出"混合模型 + 动态阈值 + 大V热池"这三点，基本就过关了。

### 3.4 扇出延迟队列

写扩散不能同步做（用户点"发布"不能等 5000 万次写）。所以走异步：

```text
发布 → outbox 落库 → 投递 Kafka(topic=post_publish) → 扇出消费者
        → 批量写粉丝 inbox（Redis ZSet，score=发布时间）→ 截断到 1000 条
```

```java
// 扇出消费者：分批扫描粉丝并写 inbox
public void fanout(Post post) {
    long cursor = 0;
    while (true) {
        List<Long> fans = fanRepo.pageFollowers(post.getAuthorId(), cursor, 5000);
        if (fans.isEmpty()) break;
        // pipeline 批量写，降低 RTT
        redis.pipelined(p -> {
            for (Long fanId : fans) {
                String key = "inbox:" + fanId;
                p.zadd(key, post.getPublishTime(), String.valueOf(post.getId()));
                p.zremrangeByRank(key, 0, -1001);   // 只留最近 1000 条
            }
        });
        cursor = fans.get(fans.size() - 1);
    }
}
```

注意 `zremrangeByRank` 的截断——**收件箱只保留最近 1000 条**，这就是"允许丢"的产品兜底（用户不会翻到第 1001 条）。

---

## 四、计数一致性：粉丝数这个"坑"

`粉丝数` 这个数字，是关注系统里最容易出错的地方。因为它**写频繁、读更高频、且要求最终一致**。

### 4.1 计数存储分层

```text
Redis String：follow:count:fans:{userId}   （毫秒级读，可能不准）
MySQL 计数列：t_user_stat.fans_count        （准，但慢）
离线对账任务：每天校准                               （真相）
```

**关键设计：Redis 计数用 INCR/DECR 原子自增，绝不用 `SCARD` 去数集合**（大 key 上 `SCARD` 是 O(1)，但桶化之后就不行了，且 Set 会被截断）。

```java
// 关注操作：MySQL 事务内写关系 + 异步改计数
@Transactional
public void follow(long followerId, long followeeId) {
    boolean inserted = followMapper.insertIgnore(followerId, followeeId);
    if (!inserted) return;                     // 幂等：已关注直接返回
    // 事务提交后异步更新计数（本地消息表保证不丢）
    localMessageService.send(FollowCountMsg.of(followerId, followeeId, +1));
}
```

### 4.2 为什么不能"事务里直接 INCR Redis"

因为 Redis 和 MySQL 不在一个事务里。做法是：

1. 事务内写 MySQL 关系 + 写**本地消息表**；
2. 事务提交后，异步消费者读本地消息表 → `INCR` Redis 计数；
3. 每天离线任务 `SELECT COUNT(*)` 校准 Redis 与 MySQL 统计列。

### 4.3 计数漂移的三种典型场景

| 场景 | 原因 | 解决 |
| --- | --- | --- |
| 重复关注导致计数虚高 | 并发重复 insert | 唯一索引 + insertIgnore 幂等 |
| 取关后计数没减 | 异步消息丢失 | 本地消息表 + 重试 + 对账 |
| 大 V 计数不准 | Redis 被截断/分桶 | 计数独立 key，不依赖集合大小 |
| 拉黑后计数不变 | 业务定义（拉黑不解除关注） | 明确产品语义，别乱减 |

**面试加分点**：主动说出"计数不是精确值，而是缓存值 + 定期对账"，比硬讲"强一致性"要专业得多。

---

## 五、缓存设计：热点 Key 与穿透

关注系统有两个典型缓存问题：

### 5.1 热点大 V

某明星发声明，1 秒内 100 万人点开他的主页并查询"我是否关注他"。

- Redis 单 key 热点：可以用**本地缓存（Caffeine）+ 多级缓存**，本地缓存只放"是否关注"这种布尔值，TTL 3~5 秒；
- 或者用 **Redis Cluster 的 hash tag** 把同一用户的数据打散到不同分片，避免单分片打爆。

```java
// 多级缓存：Caffeine(50ms TTL) → Redis → MySQL
public boolean isFollowing(long me, long target) {
    String key = me + ":" + target;
    Boolean local = localCache.getIfPresent(key);
    if (local != null) return local;

    Boolean inRedis = redis.sismember("follow:list:" + me, target);
    localCache.put(key, inRedis);
    return inRedis;
}
```

注意本地缓存 TTL 一定要**极短**（几十毫秒到几秒），否则取关后用户会看到"还关注着"的脏读。

### 5.2 缓存穿透与雪崩

- 用户不存在 / 无关系 → 缓存空值（`"NULL"` + 短 TTL），别每次都打 DB；
- 热点 key 过期时间加**随机抖动**，防雪崩；
- 用**布隆过滤器**挡掉不存在的 `userId`。

---

## 六、关注链路的性能与幂等

一次"关注"点击，完整链路：

```text
1. 参数校验 + 风控（防刷、拉黑检查、关注上限）
2. Redis 预判：SISMEMBER 快速幂等判断
3. MySQL 幂等写入（唯一索引 insert ignore）
4. 写本地消息表（计数、扇出、通知）
5. 删除/更新相关缓存
6. 异步：更新计数、投递通知、构建 Feed 关系
```

几个工程细节：

- **关注上限**：普通用户最多关注 5000 人，防止恶意刷粉；存在 Redis ZSet 里按时间淘汰；
- **频繁关注/取关**：加**用户级令牌桶限流**，并且"取关立即生效、关注延迟生效"可减少抖动；
- **拉黑语义**：A 拉黑 B 时，B 对 A 的关注关系要"隐藏"但不删除（产品上还要恢复），用 `status` 字段区分，别物理删。

```java
// 关注上限：ZSet 按时间保留最近 5000 个
public boolean tryAcquireFollowQuota(long userId) {
    String key = "follow:quota:" + userId;
    Long cnt = redis.zcard(key);
    if (cnt != null && cnt >= 5000) {
        // 允许"取关再关注"，不新增总量
        return false;
    }
    redis.zadd(key, System.currentTimeMillis(), UUID.randomUUID().toString());
    return true;
}
```

---

## 七、面试常见追问

**Q1：为什么不用一个中间表存双向关系？**
互关不等于好友（微博互关≠好友）。且双向存储会让写入放大 2 倍，语义也难以承载"单向屏蔽""特别关注"等属性。**用单向关系 + 运行时判定互关（双向存在）** 最灵活。

**Q2：粉丝数为什么可以和真实条数不一致？**
因为它只是**展示值**，产品不需要精确。工业界统一做法是 Redis 计数 + 离线对账；一致性的成本远高于收益。

**Q3：大 V 粉丝列表怎么分页？**
不让分页。产品上限制最多查看前 5 页（或前 1000），超出提示"仅展示部分"。技术上按 `(followee_id, create_time)` 走覆盖索引 + 游标分页，避免深分页。

**Q4：怎么算共同关注？**
`SINTER` 两个关注列表（小集合优先）；超大 V 用**离线预计算 + BitMap**：把 5000 万粉丝映射到位图，两两 AND 求共同粉丝，百万级用户的共同关注用 RoaringBitmap 毫秒出结果。

**Q5：关注关系需要事务吗？**
只需要保证"关系表"本身的唯一性和计数最终一致。跨服务用本地消息表 / 事务消息，别上分布式事务——关注这种业务天然可容忍短暂不一致。

---

## 总结

关注关系系统的四根支柱：

1. **单向关系 + 双向索引**：主表按 `follower_id` 分片，粉丝表用 binlog 异步生成读副本；
2. **混合扇出**：普通用户写扩散，大 V 读扩散，阈值动态可调；
3. **计数是缓存不是事实**：Redis INCR + 离线对账，接受最终一致；
4. **大 V 是万恶之源**：大 key 分桶、本地缓存、位图求交、产品截断，全是为它准备的。

把"产品预期决定架构取舍"这句话讲透，这道题就不再是背八股，而是真正的架构设计了。
