---
title: 【Redis 实战】缓存穿透、击穿、雪崩三兄弟：原理、区别与解决方案全解析
date: 2026-08-03 08:00:00
tags:
  - Java
  - Redis
  - 缓存
  - 面试
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Redis 实战】缓存穿透、击穿、雪崩三兄弟：原理、区别与解决方案全解析

## 面试官：说说缓存穿透、缓存击穿、缓存雪崩，以及各自的解决方案？

缓存三兄弟是 Redis 面试的**开场必问题**，但很多人只背了"布隆过滤器、互斥锁、随机过期时间"这几个词，被追问"为什么""怎么实现"就露馅。这篇从原理出发，把三个问题讲透，每个都带代码实现和面试追问。

## 一、三兄弟一句话区分

先建立整体认知，它们都发生在"缓存 Miss 之后回源数据库"这个环节，但病因不同：

| 问题 | 本质 | 一句话描述 | 危害 |
|------|------|-----------|------|
| **缓存穿透** | 查询的 key **不存在** | 查一个缓存和 DB 都没有的数据，每次请求都打到 DB | DB 被无效流量打爆 |
| **缓存击穿** | 热点 key **过期瞬间** | 一个热点 key 过期，大量并发同时回源 DB | DB 单点压力瞬间飙升 |
| **缓存雪崩** | **大量 key 同时过期** 或 Redis 宕机 | 缓存层大面积失效，流量全部涌向 DB | DB 直接宕机，系统整体不可用 |

区别的关键：**穿透是"没有数据"，击穿是"一个热点 key 过期"，雪崩是"一批 key 过期/缓存层挂了"**。

## 二、缓存穿透：查不存在的数据

### 原理

```java
// 常规读缓存逻辑
Object val = redis.get(key);
if (val != null) return val;          // 命中
Object dbVal = dao.query(key);        // 未命中，回源 DB
if (dbVal != null) redis.set(key, dbVal, 10min);
return dbVal;
```

攻击者构造大量**不存在的 key**（如 `user:-1`、`user:99999999`），每次查缓存 Miss → 查 DB 也查不到 → 不写缓存 → 下一次同样的请求继续打 DB。一个恶意脚本用 1 万个不存在的 id 循环请求，就能把 DB 打垮。这就是穿透——**"查什么什么没有"**。

### 解决方案

**方案 1：参数合法性校验（最廉价的第一道防线）**
```java
if (id == null || id <= 0 || id > 10000000) {
    throw new IllegalArgumentException("非法参数");
}
```
把明显非法的请求直接拦截在入口。

**方案 2：缓存空值（最简单有效）**
```java
Object dbVal = dao.query(key);
if (dbVal == null) {
    // 缓存空值，设置较短过期时间（如 5 分钟），防止攻击者用同一 key 反复打 DB
    redis.set(key, "", 5 * 60);
    return null;
}
redis.set(key, dbVal, 10 * 60);
return dbVal;
```
注意：空值过期时间要**短**（几分钟），否则大量空 key 占内存；同时要防止"DB 写入新数据后，空缓存挡住新数据"（5 分钟窗口内读不到，业务可接受）。

**方案 3：布隆过滤器（治本）**
把所有可能存在的 key（如所有用户 id）预先放入布隆过滤器，查询前先判断"key 是否可能存在"：

```java
// 初始化：加载所有用户 id 到布隆过滤器
BloomFilter<Long> filter = BloomFilter.create(
        Funnels.longFunnel(), 1000_0000, 0.01);   // 预计 1000 万，误判率 1%

// 查询时
public Object get(Long id) {
    if (!filter.mightContain(id)) {
        return null;   // 一定不存在，直接返回，不打 DB
    }
    // 走正常缓存逻辑...
}
```

布隆过滤器原理：一个**位数组 + 多个哈希函数**。插入时把 key 用 k 个哈希函数映射到位数组的 k 个位置并置 1；查询时检查 k 个位置是否全为 1，**有一个为 0 则必然不存在，全为 1 则可能存在（有误判）**。

```java
// 手写一个极简布隆过滤器核心逻辑
public class SimpleBloomFilter {
    private final BitSet bits = new BitSet(1 << 24);
    private final int[] seeds = {3, 5, 7, 11, 13, 17};   // 6 个哈希种子

    private int hash(Object key, int seed) {
        int h = key.hashCode() ^ (seed * 0x9e3779b9);
        return Math.abs(h) % bits.size();
    }

    public void add(String key) {
        for (int s : seeds) bits.set(hash(key, s));
    }

    public boolean mightContain(String key) {
        for (int s : seeds) {
            if (!bits.get(hash(key, s))) return false;   // 有一个 0 → 必然不存在
        }
        return true;   // 全部为 1 → 可能存在
    }
}
```

生产直接用 **Guava 的 BloomFilter** 或 **Redis 的 BF 模块**（`BF.ADD` / `BF.EXISTS`）即可。注意布隆过滤器的数据要**定期重建**（新注册用户要能加进去）。

## 三、缓存击穿：热点 key 过期的瞬间

### 原理

某个**访问量极高的热点 key**（如秒杀商品、微博热搜），它的缓存过期的那一瞬间，成千上万的并发请求同时 Miss，**全部回源 DB**，DB 压力瞬间打满。穿透是"故意查不存在的"，击穿是"热点数据缓存失效的瞬间"。

### 解决方案

**方案 1：互斥锁（最常用，保证只有一个请求回源）**

```java
public Object get(String key) {
    Object val = redis.get(key);
    if (val != null) return val;

    // 加锁（Redis 分布式锁，如 Redisson）
    String lockKey = "lock:" + key;
    RLock lock = redisson.getLock(lockKey);
    boolean locked = lock.tryLock(2, 5, TimeUnit.SECONDS);
    if (!locked) {
        // 没抢到锁：短暂休眠后重试（或直接返回旧数据/默认值）
        Thread.sleep(100);
        return get(key);   // 递归重试
    }
    try {
        // 双重检查：抢到锁后可能已有别的线程回源并写好了缓存
        val = redis.get(key);
        if (val != null) return val;
        // 真正回源 DB 并写缓存
        val = dao.query(key);
        redis.set(key, val, 10 * 60);
        return val;
    } finally {
        lock.unlock();
    }
}
```

**方案 2：逻辑过期（热 key 永不过期 + 后台异步更新）**

```java
// 缓存里不设过期时间，value 里带一个逻辑过期时间戳
// 写缓存时：redis.set(key, json{value, expireAt=now+10min}, -1)

public Object get(String key) {
    CacheObj obj = json.parse(redis.get(key));
    if (obj == null) return dao.query(key);          // 缓存没了（正常淘汰）才回源
    if (obj.expireAt > System.currentTimeMillis()) {
        return obj.value;                            // 未到逻辑过期，直接返回
    }
    // 逻辑过期：先返回旧值（保证可用性），异步线程去更新缓存
    asyncExecutor.execute(() -> {
        Object fresh = dao.query(key);
        redis.set(key, json{value: fresh, expireAt: now + 10min}, -1);
    });
    return obj.value;   // 返回旧值，用户无感知
}
```

逻辑过期方案的优点是**不会阻塞请求**（读永远返回旧值），代价是**短时间可能读到旧数据**（缓存与 DB 不一致窗口），适合一致性要求不高、并发极高的场景。两个方案对比：

| 维度 | 互斥锁 | 逻辑过期 |
|------|--------|---------|
| 数据一致性 | 强（始终拿最新值） | 弱（可能读到旧值） |
| 性能 | 有锁竞争，少量阻塞 | 无阻塞，吞吐最高 |
| 实现复杂度 | 简单 | 中等（要维护逻辑过期字段） |
| 适用场景 | 一般高并发 | 极高并发、可容忍短暂旧数据 |

## 四、缓存雪崩：大面积缓存同时失效

### 原理

两种情况：
1. **大量 key 设置了相同的过期时间**（如全部 10 分钟），在同一时刻集体过期 → 那一瞬间所有请求一起回源 DB；
2. **Redis 整个宕机** → 缓存层完全失效，流量全打 DB → DB 宕机 → 系统雪崩。

### 解决方案

**方案 1：过期时间加随机值（防集体过期）**
```java
// 不要用固定过期时间
redis.set(key, val, 60 * 10);
// 改为：基础时间 + 随机抖动，让过期时间错开
redis.set(key, val, 60 * 10 + RandomUtil.randomInt(0, 300));
```

**方案 2：多级缓存（本地缓存兜底）**
在 Redis 前面加一层 **Caffeine 本地缓存**，即使 Redis 整体不可用，本机内存还能扛住大部分读流量：

```java
// Caffeine 本地缓存（每个 JVM 一份）
Cache<String, Object> localCache = Caffeine.newBuilder()
        .maximumSize(100_000)
        .expireAfterWrite(1, TimeUnit.MINUTES)   // 本地缓存过期时间更短
        .build();

public Object get(String key) {
    Object local = localCache.getIfPresent(key);
    if (local != null) return local;             // ① 本地缓存
    Object redisVal = redis.get(key);
    if (redisVal != null) {
        localCache.put(key, redisVal);           // ② Redis，并回填本地
        return redisVal;
    }
    Object dbVal = dao.query(key);               // ③ DB
    redis.set(key, dbVal, 10min);
    localCache.put(key, dbVal);
    return dbVal;
}
```

**方案 3：Redis 高可用（防 Redis 宕机）**
主从 + 哨兵、Redis Cluster、多机房部署，让 Redis 本身不成为单点。

**方案 4：服务降级 + 熔断（最后防线）**
DB 扛不住时，直接返回默认值/缓存快照（如"活动已结束"、旧价格），而不是让请求打到 DB。用 Sentinel/Hystrix 做熔断，DB 恢复后自动放行。

## 五、面试追问整理

**Q1：布隆过滤器的误判率怎么控制？**
答：误判率由位数组长度 m 和哈希函数个数 k 决定：m 越大误判率越低，k 越多误判率越低（但有最优值，约 `k = (m/n)·ln2`）。Guava 的 `BloomFilter.create(funnel, expectedInsertions, fpp)` 可以指定误判率，框架自动算 m 和 k。

**Q2：布隆过滤器能删除元素吗？**
答：标准布隆过滤器**不能删除**（一个位置可能被多个元素共享置 1，清零会误删其他元素）。需要删除用**计数布隆过滤器（Counting Bloom Filter）**，每个位置存计数器。另外它只能"判断不存在"，不能精确判断存在。

**Q3：缓存击穿和缓存穿透怎么区分？从请求特征上看？**
答：穿透是**key 在 DB 和缓存都不存在**，请求的 key 是"假 key"，特征是 DB 查询结果为空、缓存永远 Miss；击穿是**key 真实存在且很热**，只是过期瞬间并发回源，特征是 DB 能查到数据、命中率平时很高、只是某个瞬间 QPS 突刺。

**Q4：雪崩时多级缓存本地缓存的数据怎么保证新鲜？**
答：本地缓存过期时间设短（如 1 分钟）+ 主动失效：Redis 更新时通过消息广播（或 Redis Pub/Sub）通知各节点清除本地缓存。允许最终一致，秒级收敛。

**Q5：三个问题的通用防御手段有哪些？**
答：入口限流降级、参数校验、缓存预热、DB 连接池保护（`hikari.maximum-pool-size` 有上限本身就是天然限流）、监控告警（缓存命中率、DB QPS 突刺）。**预防永远比事后补救便宜**。

## 总结

| 问题 | 核心手段 |
|------|---------|
| 穿透（查不存在） | 参数校验 + 缓存空值 + **布隆过滤器** |
| 击穿（热点过期） | **互斥锁** / 逻辑过期 |
| 雪崩（批量过期/宕机） | 过期时间加随机值 + **多级缓存** + Redis 高可用 + 熔断降级 |

面试时先讲清三者的**本质区别**（不存在 / 单个热点过期 / 批量失效），再逐个给方案，最后补一句"穿透用布隆、击穿用互斥锁、雪崩靠随机过期+多级缓存+高可用"的总纲，这个题就答全了。
