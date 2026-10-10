---
title: 【分布式锁】Redis Redlock 红锁深度解析：时钟漂移、论战争议与 Fencing Token
date: 2026-10-10 08:20:00
tags:
  - Java
  - Redis
  - 分布式锁
  - 分布式
  - 面试
categories:
  - Java
  - 分布式
author: 东哥
---

# 【分布式锁】Redis Redlock 红锁深度解析：时钟漂移、论战争议与 Fencing Token

## 面试官：你说用 Redis 做分布式锁，那 Redis 主从切换时锁丢了怎么办？

这是一个连环追问的经典开场。候选人一般会答：

> "用 SetNX + 过期时间就行，Redisson 都封装好了。"

面试官接着问：

> "主节点写入锁之后还没同步到从节点就宕机了，从节点升主，锁就消失了——这时候另一个线程也能拿到锁，临界区被两个线程同时进入。怎么办？"

如果这时候你只知道"Redisson 有看门狗自动续期"，那这个题就到这里了。能拉开差距的，是**讲清楚 Redlock 怎么设计、以及它为什么至今仍有争议**。

---

## 一、Redis 分布式锁的三个层次

先建立全局视角，面试时按层次回答比直接抛 Redlock 更清晰：

| 层次 | 方案 | 单点故障 | 时钟依赖 | 锁丢失风险 |
| --- | --- | --- | --- | --- |
| L1 | 单实例 SetNX | 有 | 是 | 主从切换丢锁 |
| L2 | 哨兵/主从 + 续期 | 有（切换窗口） | 是 | **切换窗口内丢锁** |
| L3 | Redlock（多独立节点多数派） | 无 | **强依赖** | 理论大幅降低，但不为零 |
| L4 | 共识系统（etcd/ZK） | 无 | 无（或弱） | 无（严格正确） |

### L1/L2 的失败机理

```
时刻 T1  客户端 A: SET lock:order:1 <tokenA> NX PX 30000  → master OK
时刻 T2  master 宕机，锁尚未复制到 slave
时刻 T3  slave 升主（还没收到 A 的写）
时刻 T4  客户端 B: SET lock:order:1 <tokenB> NX PX 30000  → OK
结果：A 和 B 同时持有锁 → 并发写同一资源 → 数据错乱
```

注意：**这不是"Redis 不够快"的问题，而是"Redis 复制是异步的"的必然结果。** 只要用单 master，就无法避免。

---

## 二、Redlock 算法：用多数派抵抗单点故障

Redlock 的思路很直觉：**既然一个 Redis 不可靠，那就用 N 个互相独立的 Redis**。

### 算法流程（N = 5 为例）

1. 客户端记录开始时间 `T0`；
2. 依次向 **5 个互相独立**（无主从关系、无集群关系）的 Redis 节点发起 `SET key value NX PX <ttl>`；
3. 只有当**至少 3 个（多数派）节点加锁成功**，且**总耗时 < 锁 TTL**，才认为加锁成功；
4. 加锁成功后，**有效锁时间 = TTL − 已耗时 − 时钟漂移余量**；
5. 若加锁失败（成功数 < 多数派 或 超时），立即向所有节点发起删除（**只删自己持有的**）；
6. 解锁：向所有节点发起"比对 value 后删除"的 Lua 脚本。

### 关键实现细节

```java
public class RedLock {

    private final List<RedisClient> nodes;
    private final int quorum;              // N/2 + 1
    private static final long RETRY_DELAY_MS = 200;

    public LockToken tryLock(String key, long ttlMillis) {
        String token = UUID.randomUUID().toString();
        long deadline = System.currentTimeMillis() + ttlMillis;

        int acquired = 0;
        List<RedisClient> successNodes = new ArrayList<>();
        for (RedisClient node : nodes) {
            try {
                if (setNxPx(node, key, token, ttlMillis)) {
                    acquired++;
                    successNodes.add(node);
                }
            } catch (Exception ignore) { /* 单节点失败不影响多数派判断 */ }
        }

        long elapsed = System.currentTimeMillis() - deadline + ttlMillis;
        // 多数派成功 && 未超时（要扣除时钟漂移余量）
        if (acquired >= quorum && elapsed < ttlMillis) {
            return new LockToken(token, successNodes, ttlMillis - elapsed - clockDrift());
        }
        // 失败：清理所有已加成功的锁，避免残留
        unlockAll(key, token, successNodes);
        return null;
    }

    public void unlock(String key, LockToken token) {
        // 释放时向所有节点（包括未成功的）发送删除，保证不漏
        unlockAll(key, token.getValue(), nodes);
    }

    private void unlockAll(String key, String token, List<RedisClient> targets) {
        String lua = "if redis.call('get', KEYS[1]) == ARGV[1] then " +
                     "  return redis.call('del', KEYS[1]) else return 0 end";
        for (RedisClient node : targets) {
            try { node.eval(lua, key, token); } catch (Exception ignore) {}
        }
    }

    private long clockDrift() {
        // 典型取其 TTL 的 1%，或固定 10ms，用于兜底时钟回拨
        return 10;
    }
}
```

`if redis.call('get', KEYS[1]) == ARGV[1]` 这个判断必不可少：**防止 A 的锁已经过期、B 拿到锁后，A 的错误释放把 B 的锁删掉**。

---

## 三、争议：Kleppmann vs antirez

这是分布式领域最著名的一场技术论战，面试里讲到它，基本就是加分题。

### Kleppmann（《DDIA》作者）的反对意见

1. **Redlock 强依赖系统时钟**。它假设多个节点的时钟只会"线性缓慢漂移"，忽略了**时钟跳变**（NTP 校正、虚拟机迁移、运维手动改时间）。一旦发生时钟跳变，Redlock 的正确性论证就崩了。
2. **GC / 网络延迟导致的"锁失去保护"问题**。持有锁的进程可能因 STW GC 停顿很久，等它恢复时锁已过期，但它自己并不知道，仍然进入临界区。**这不是 Redlock 能解决的问题——任何基于超时过期的锁都有这个问题。**
3. **没有 Fencing Token**。Redlock 的 value 是随机串，不是单调递增的数字，存储层无法识别"过期的旧持有者"。Kleppmann 举的经典例子是向存储服务写数据：A（旧 token）和 B（新 token）都能写，但存储层无法判断谁更"新"。

### antirez（Redis 作者）的回应

1. 时钟跳变确实是问题，但可以通过**禁止 Redis 节点使用 NTP 强制时间调整**（只允许 slew，不允许 step）来规避；
2. GC 停顿问题对**所有**锁方案都成立，不是 Redlock 特有问题，不能因此否定它；
3. Fencing Token 需要一个单调递增的发号器，这本身就是另一个共识问题，把它塞进锁的定义里是**要求过高**。

### 结论怎么答

面试官想要的不是"你站哪边"，而是：

> **Redlock 相比单实例确实提升了容错性，但它并没有提供"严格正确"的分布式锁。是否需要 Redlock，取决于业务对锁失效时的容忍度。**

- 如果锁失效只是"多干一次活"（幂等操作、统计任务），用 Redisson 单实例 + 看门狗**完全够用**；
- 如果锁失效会导致**资金错乱、超卖、数据损坏**，就不要用 Redis 锁，用 **etcd / ZooKeeper / 数据库唯一约束 + fencing token**；
- 更根本的做法：**让临界区操作本身幂等 + 带版本号（乐观锁）**，这样"锁失效"最多导致"白做一次"，而不是"做错"。

---

## 四、Fencing Token：真正的解法

Fencing Token 的核心思想是：**锁服务每次授予锁时，返回一个单调递增的序号（fencing token），下游存储服务记录最后一次写入的 token，拒绝更小的 token。**

```
锁服务（如 ZK 的 zxid、etcd 的 revision / lease）
   │
   ├─ A 获得锁，token = 33
   ├─ A 发生 GC 停顿，锁超时
   ├─ B 获得锁，token = 34
   ├─ A 恢复，向存储服务写入，携带 token = 33
   └─ 存储服务: 34 > 33，拒绝 A 的写入  ✅
```

在存储层落地：

```sql
-- 每次写入带上 fencing token，只有更大的 token 才能写入
UPDATE resource
SET value = ?, fence_token = ?
WHERE id = ? AND fence_token < ?;
```

Java 里更常见的落地形式是**版本号乐观锁**：

```java
@Transactional
public void updateWithFence(long id, String value, long fenceToken) {
    int rows = jdbcTemplate.update(
        "UPDATE resource SET value = ?, fence_token = ? " +
        "WHERE id = ? AND fence_token < ?",
        value, fenceToken, id, fenceToken);
    if (rows == 0) {
        throw new StaleTokenException("检测到过期的锁持有者，拒绝写入");
    }
}
```

**关键洞察：锁只是"降低并发冲突的概率"，真正保证正确性的是"存储层的条件写入"。** 这句话是这道题的终极答案。

---

## 五、Redisson 的看门狗：解决的是另一个问题

很多人把"看门狗"当成 Redlock 的答案，其实它解决的是**锁提前过期**：

```java
RLock lock = redisson.getLock("order:1");
lock.lock();               // 不指定 leaseTime → 触发看门狗
try {
    // 业务逻辑
} finally {
    lock.unlock();
}
```

- 默认 `lockWatchdogTimeout = 30s`，看门狗每 `30/3 = 10s` 续期一次，把 TTL 续回 30s；
- **一旦显式指定 `leaseTime`，看门狗就不生效**（Redisson 认为你已经自己管理了过期）；
- 看门狗要求客户端存活且能连上 Redis，如果客户端进程被 kill，续期停止，锁会在 30s 内自动释放。

| 场景 | 是否触发看门狗 | 风险 |
| --- | --- | --- |
| `lock()` | 是 | 客户端卡死时锁一直不释放（直到进程退出） |
| `lock(10, SECONDS)` | 否 | 业务超过 10s 锁就失效 |
| `tryLock(wait, lease, unit)` | 否 | 同上 |

> ⚠️ **面试陷阱**：看门狗是"锦上添花"，不是"雪中送炭"。它让锁在业务未完成时不会失效，但也让"客户端假死"变成"锁迟迟不释放"。所以业务锁的 TTL 与业务超时时间必须配套设计。

---

## 六、选型决策表

| 场景 | 推荐方案 | 理由 |
| --- | --- | --- |
| 定时任务防重复执行 | Redisson 单实例锁 | 锁失效最多多跑一次，且任务本身可幂等 |
| 缓存重建防击穿 | SetNX + 短 TTL | 失败重试即可，无一致性要求 |
| 订单状态流转 | 数据库行锁 / 乐观锁 | 无需引入外部锁 |
| 扣库存/扣余额 | **DB 条件更新 + 版本号** | 必须强一致，锁只是辅助 |
| 主备切换 / Leader 选举 | etcd / ZooKeeper | 需要严格的临时顺序节点语义 |
| 跨机房强一致协调 | etcd（Raft） | 有共识保证 |

---

## 七、面试常见追问

**Q1：Redlock 至少需要几个节点？为什么建议奇数？**
答：最少 3 个（quorum=2），生产建议 5 个。奇数是因为多数派判定 `N/2+1`，5 个节点能容忍 2 个节点故障，且比 4 个节点（同样容忍 1 个故障、但需要 3 个成功）更划算。

**Q2：Redlock 的 5 个节点必须完全独立吗？**
答：必须。如果它们之间存在主从复制或集群关系，就失去了"独立故障域"的意义，一起挂掉或一起丢数据，配额根本无法形成。

**Q3：为什么解锁要遍历所有节点，而不是只删成功的节点？**
答：因为可能存在"客户端未收到响应但服务端实际写入成功"的情况（网络超时）。只删成功节点会留下残留锁。遍历删除 + `get==value` 校验是安全且代价可控的。

**Q4：Redlock 加锁失败后为什么必须立刻清理？**
答：否则残留锁会占用 key，导致后续所有客户端在 TTL 内都无法加锁（假死锁），严重影响可用性。

**Q5：如果锁服务返回的 token 不能保证单调递增呢？**
答：那 Fencing Token 方案就退化了。ZK 的 `zxid`、etcd 的 `revision` 天然全局单调递增；如果锁服务基于 Redis，可以用 `INCR` 生成全局序号，但 `INCR` 本身又依赖单点——所以最终还是绕回"要么用共识系统，要么用存储层乐观锁"。

---

## 总结

把这道题答透的四个要点：

1. **Redis 单实例/主从锁的失效根因是"异步复制 + 超时过期"**，Redlock 只是缓解，不是根治；
2. **Redlock 的争议核心是"强依赖时钟"和"缺少 fencing token"**，能复述 Kleppmann 与 antirez 的主要论点就很加分；
3. **真正的正确性来自存储层的条件写入（版本号/fencing token）**，锁只是缩小并发窗口的工具；
4. **选型看容忍度**：锁失效只会"多做一次"就用 Redis，会"做错"就用共识系统或数据库约束。

记住那句话：**分布式锁不是用来保证正确性的，它是用来提升性能的。正确性永远由存储层兜底。**
