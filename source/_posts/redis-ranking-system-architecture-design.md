---
title: 【系统设计】高并发排行榜系统架构设计：Redis ZSet、分桶策略、实时更新与海量数据分页
date: 2026-10-02 08:00:00
tags:
  - 系统设计
  - Redis
  - 高并发
  - 排行榜
categories:
  - 系统设计
  - 高并发
author: 东哥
---

# 【系统设计】高并发排行榜系统架构设计：Redis ZSet、分桶策略、实时更新与海量数据分页

## 面试官：让你设计一个千万级用户的积分排行榜，你会怎么做？

这是系统设计面试里非常经典的一道题。看起来简单——"排个序而已"——但它几乎把高并发场景里所有的坑都踩了一遍：海量数据、实时更新、热点写入、深分页、周期榜与总榜的切换、缓存与数据库的一致性。

很多人第一反应是：

```sql
SELECT user_id, score FROM user_score
ORDER BY score DESC
LIMIT 0, 100;
```

在小数据量下没问题，但一旦数据量到千万级，这条 SQL 就会全表扫描 + 文件排序（filesort），再加上高并发 QPS，数据库基本必挂。

所以我们要从"能用"一步步推到"生产级高并发可用"。

---

## 一、需求拆解：先把问题定义清楚

在动手之前，先把需求拆成几个维度，不同维度的答案完全不同：

| 维度 | 需要问清楚的问题 |
| --- | --- |
| 数据规模 | 用户量是百万、千万还是上亿？ |
| 榜单类型 | 总榜 / 日榜 / 周榜 / 月榜 / 好友榜？ |
| 实时性 | 秒级实时，还是允许 5 分钟延迟？ |
| 读取模式 | 只看 Top 100，还是要能翻到第 1000 名？ |
| 写入模式 | 每次行为都更新，还是批量上报？ |
| 一致性 | 允许最终一致，还是必须强一致？ |

面试里最忌讳的是不追问就直接开写。真正加分的是先确认需求边界，比如"假设用户量 5000 万，榜单需要日榜和周榜，Top 100 强实时，100 名以后允许分钟级延迟"。

---

## 二、方案演进：从数据库到 Redis ZSet

### 2.1 方案一：数据库 ORDER BY LIMIT（淘汰）

```sql
-- 依赖 (score) 上的联合索引
ALTER TABLE user_score ADD INDEX idx_score_user (score DESC, user_id);
SELECT user_id, score FROM user_score ORDER BY score DESC, user_id LIMIT 100;
```

有索引的情况下 Top 100 是快的，因为索引本身有序，MySQL 只要顺着 B+ 树叶子节点从前到后取 100 条即可，不需要 filesort。

但问题在于：

1. **写入成本高**。用户积分变一次就 UPDATE 一次，索引页频繁分裂，热点行锁竞争严重。
2. **深分页灾难**。`LIMIT 100000, 100` 需要先扫描并丢弃前 10 万条，越翻越慢。
3. **周期榜很难做**。日榜/周榜要靠时间范围过滤，索引利用率低。
4. **扛不住 QPS**。榜单是典型读多写多的热点，数据库很容易被打爆。

结论：数据库只适合做**最终落库的持久层**，不适合做实时排名。

### 2.2 方案二：Redis ZSet（核心方案）

Redis 的 `Sorted Set`（ZSet）天生就是为排名设计的：

- 底层是**跳表（Skip List）+ 哈希表（dict）**，插入/删除/更新 O(log N)，按 rank 查询 O(log N)。
- 天然有序，`ZREVRANGE` 直接拿 Top N。
- 支持 `ZINCRBY` 原子自增，天然并发安全。
- 支持 `ZREVRANK` 获取某用户排名，`ZSCORE` 获取分数。

常用命令：

```bash
# 加分（超出则创建）
ZINCRBY rank:daily:20261002 10 user:1001

# 直接设定分数（适合权重总分整体重算）
ZADD rank:daily:20261002 GT CH 1580 user:1001

# 取 Top 100（含分数，从高到低）
ZREVRANGE rank:daily:20261002 0 99 WITHSCORES

# 查某人排名（从 0 开始，注意要 +1 转成业务排名）
ZREVRANK rank:daily:20261002 user:1001

# 查某人分数
ZSCORE rank:daily:20261002 user:1001

# 分页：取 100~199 名
ZREVRANGE rank:daily:20261002 100 199
```

`ZINCRBY` 是一个非常关键的原子操作——多个线程同时给同一个用户加分，不会丢更新，也不需要我们自己加锁。

**跳表为什么适合排名？**

普通链表查找是 O(N)，跳表通过多级索引把查找降到 O(log N)。而且跳表每个节点维护了跨度（span），`ZREVRANK` 可以通过累加 span 直接算出排名，不需要真的遍历。这是 ZSet 能在榜单场景碾压其他结构的根本原因。

---

## 三、生产级设计：分桶、分层与分片

单个 ZSet 能撑住多大？理论上几百万成员没问题（单 key 内存几 MB 到几十 MB），但一旦上千万，就会遇到两个问题：

1. **大 Key**：单个 ZSet 几 GB，操作阻塞主线程，迁移困难。
2. **深分页**：`ZREVRANGE key 100000 100099` 虽然复杂度是 O(log N + M)，但网络传输和序列化成本高，且用户翻到深处本质上无意义。

所以真实系统会做**分层 + 分桶 + 分片**。

### 3.1 分层：总榜 + 周期榜 + 好友榜

```text
rank:total            # 总榜（长期累计）
rank:daily:20261002   # 日榜，按天 key，自动过期
rank:weekly:2026-W40  # 周榜
rank:friend:{userId}  # 好友榜，数据量小，可实时
```

日榜设置 7 天过期，周榜设置 8 周过期，用 Redis 的 `EXPIRE` 自动清理，避免无限增长：

```bash
EXPIRE rank:daily:20261002 604800
```

### 3.2 分桶：只维护 Top N + 用户自己的排名

榜单产品形态通常是"Top 100 + 我的排名"。所以：

- Redis 里维护完整的 ZSet 用于计算，但对外只暴露 Top 100。
- 用户自己的排名通过 `ZREVRANK + 1` 实时获取，O(log N)，非常快。
- 如果只需要 Top 100，可以在应用层做一层本地缓存（Caffeine），把 100 个用户的结果缓存 1~5 秒，把 Redis 的读 QPS 降一到两个数量级。

### 3.3 分片：大榜拆小榜

当 ZSet 真的到千万级，可以按**分片键**拆：

```text
rank:daily:20261002:shard0
rank:daily:20261002:shard1
...
rank:daily:20261002:shard15
```

规则：`shard = hash(userId) % 16`。

**分片后最大的问题是全局 Top N**：你不可能从 16 个分片各取 Top 100 再合并成"全局 Top 100"吗？其实可以——从每个分片取 Top N，然后做**归并**。因为全局 Top 100 必然包含在每个分片的 Top 100 里。这是一个很漂亮的结论：

> 全局 Top N 一定是各分片 Top N 的并集的子集。

所以每次查全局榜，从 16 个分片各 `ZREVRANGE 0 99`，拿到 1600 条，在应用层归并排序取前 100。这 16 次请求可以 pipeline 并发发出，延迟很低。

代价是归并开销随分片数增长，且要缓存结果（比如 1 秒缓存），否则每次请求都归并会很浪费。

### 3.4 榜单更新链路

真实链路通常是异步的：

```text
用户行为 -> 消息队列(Kafka) -> 积分计算服务 -> Redis ZINCRBY -> 异步落库 -> 定时快照
```

用 MQ 削峰的好处：

- 行为高峰不会直接打到 Redis 和 DB。
- 积分的计算规则（权重、去重、防刷）可以独立演进。
- 可以按用户 ID 分区，保证同一用户的行为顺序。

---

## 四、代码实战：一个可用的排行榜服务

### 4.1 加分与查榜

```java
@Component
public class RankingService {

    private final StringRedisTemplate redis;

    public RankingService(StringRedisTemplate redis) {
        this.redis = redis;
    }

    private String dailyKey(LocalDate date) {
        return "rank:daily:" + date.format(DateTimeFormatter.BASIC_ISO_DATE);
    }

    /** 加分：原子自增 */
    public void addScore(long userId, long delta) {
        String key = dailyKey(LocalDate.now());
        redis.opsForZSet().incrementScore(key, "user:" + userId, delta);
        redis.expire(key, Duration.ofDays(7));
    }

    /** Top N */
    public List<RankItem> topN(int n) {
        String key = dailyKey(LocalDate.now());
        Set<ZSetOperations.TypedTuple<String>> tuples =
                redis.opsForZSet().reverseRangeWithScores(key, 0, n - 1L);
        if (tuples == null) {
            return List.of();
        }
        int rank = 1;
        List<RankItem> result = new ArrayList<>(tuples.size());
        for (ZSetOperations.TypedTuple<String> t : tuples) {
            result.add(new RankItem(rank++, parseUserId(t.getValue()), t.getScore()));
        }
        return result;
    }

    /** 我的排名（从 1 开始） */
    public long myRank(long userId) {
        Long rank = redis.opsForZSet().reverseRank(dailyKey(LocalDate.now()), "user:" + userId);
        return rank == null ? -1 : rank + 1;
    }

    private long parseUserId(String member) {
        return Long.parseLong(member.substring("user:".length()));
    }

    public record RankItem(int rank, long userId, Double score) {}
}
```

### 4.2 分片归并

```java
public List<RankItem> globalTopN(int n, int shardCount) {
    // Pipeline 并发取各分片 Top N
    List<Object> raw = redis.executePipelined((RedisCallback<Object>) connection -> {
        for (int i = 0; i < shardCount; i++) {
            connection.zSetCommands().zRevRangeWithScores(
                    shardKey(i).getBytes(StandardCharsets.UTF_8), 0, n - 1);
        }
        return null;
    });

    // 归并：用最小堆维护 Top N
    PriorityQueue<RankItem> heap = new PriorityQueue<>(Comparator.comparingDouble(RankItem::score));
    for (Object o : raw) {
        for (ZSetOperations.TypedTuple<String> t : (Set<ZSetOperations.TypedTuple<String>>) o) {
            heap.offer(new RankItem(0, parseUserId(t.getValue()), t.getScore()));
            if (heap.size() > n) {
                heap.poll();
            }
        }
    }
    List<RankItem> list = new ArrayList<>(heap);
    list.sort(Comparator.comparingDouble(RankItem::score).reversed());
    // 重新编号
    List<RankItem> ranked = new ArrayList<>(list.size());
    for (int i = 0; i < list.size(); i++) {
        RankItem it = list.get(i);
        ranked.add(new RankItem(i + 1, it.userId(), it.score()));
    }
    return ranked;
}
```

---

## 五、高频追问与避坑

**追问 1：分数相同时排名怎么定？**

ZSet 在分数相同时按 member 的字典序排序。如果要求"先到先得"或"同等分数按用户 ID 升序"，可以把 member 设计成 `score 补齐 + userId` 的复合字符串，或者在分数里加一个极小的小数位（不推荐，容易精度丢失）。更稳妥的做法是 member 用固定宽度零填充的 `userId`。

**追问 2：Redis 挂了怎么办？**

- 开启 AOF（`appendfsync everysec`）+ 定期 RDB 快照，恢复后重建榜单。
- Redis Cluster 做分片和高可用，主从 + 哨兵/集群自动故障转移。
- 数据库里保留明细流水，可以随时重算榜单（这是最重要的兜底）。

**追问 3：怎么防止刷榜？**

- 行为侧风控：频率限制、设备指纹、行为序列异常检测。
- 积分侧幂等：同一行为 ID 只加一次分，用 Redis SETNX 或唯一索引。
- 榜单侧平滑：对短时间内的暴涨做衰减，比如热度分 `score = base * e^(-λt)`。

**追问 4：热度榜怎么算？**

很多榜单不是简单累加，而是"热度分"，典型公式是 Hacker News 的做法：

```text
score = (p - 1) / (t + 2)^1.8
```

其中 p 是点赞/互动数，t 是以小时为单位的发布时间差。它会随时间自然衰减，新内容更容易上榜。也可以用 `score = w1 * like + w2 * comment + w3 * share - w4 * report` 这类加权模型，权重配置化、可热更新。

**追问 5：为什么不用 MySQL + 定时任务算榜？**

可以，但只适合 T+1 的离线榜。实时榜如果每分钟全表排序一次，数据量大时根本跑不完，而且会放大数据库压力。Redis ZSet 的价值就在于把"排序"这个操作的成本从 O(N log N) 降到 O(log N)。

---

## 六、总结

把这道题串起来，核心思路是：

1. **数据模型选 ZSet**：跳表 + 哈希，排名场景的最优解。
2. **分层设计**：总榜/日榜/周榜分 key，配合 EXPIRE 自动清理。
3. **分片 + 归并**：解决单 key 过大，全局 Top N = 各分片 Top N 归并。
4. **异步链路**：MQ 削峰，Redis 承载实时读写，DB 做最终落地和重算兜底。
5. **缓存 Top N**：本地缓存削弱热点读，把 QPS 降一到两个数量级。
6. **防刷与幂等**：行为去重 + 频率限制 + 衰减模型。

排行榜看起来是"排序"，本质是**高并发下的读写分离、分片归并和一致性取舍**。想清楚这几点，这道题就稳了。
