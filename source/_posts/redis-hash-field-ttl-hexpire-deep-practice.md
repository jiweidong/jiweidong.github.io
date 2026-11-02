---
title: 【Redis 8 实战】字段级 TTL 深度解析：HEXPIRE 命令族、底层 ebuckets 与 Java 落地
date: 2026-11-02 08:00:00
tags:
  - Java
  - Redis
  - HEXPIRE
  - 缓存设计
  - 会话管理
categories:
  - 中间件
author: 东哥
---

# 【Redis 8 实战】字段级 TTL 深度解析

## 前言

Redis 的过期能力长期停留在 **key 粒度**：一个 key 到期，整个 Hash/Set 灰飞烟灭。这个限制在真实业务里制造了无数丑陋设计：

- 用户会话用 `Hash` 存 `token -> userId`、`deviceId`，不同设备登录时间不同，但只能给整个 Hash 设一个 TTL，要么全部提前失效，要么全部续命；
- 购物车用 `Hash` 存 `skuId -> 数量`，商品加购时间不同，想「加购 7 天自动清理」，只能每个 sku 拆一个 key，导致 key 数量爆炸；
- 限流窗口用 `ZSet`，历史成员只能靠业务侧定时清理，清理任务一挂就内存泄漏。

Redis 7.4 引入了 **Hash 字段级 TTL**（`HEXPIRE` 命令族），Redis 8 稳定后开始被广泛使用。它让「一个 key 内不同字段拥有独立生命周期」成为原生能力，很多原本需要拆 key 的场景可以收回到单个 Hash 里，内存和请求次数都能降一个量级。

本文从命令语义、底层实现、Java 客户端落地、生产坑四个层面把它讲透。

## 一、命令族：不止 HEXPIRE

字段级 TTL 相关命令共 9 个，分成「设置 / 查询 / 移除」三组：

| 命令 | 作用 | 示例 |
|---|---|---|
| `HEXPIRE key seconds FIELDS n f1...` | 相对过期（秒） | `HEXPIRE cart:1 604800 FIELDS 2 sku:100 sku:101` |
| `HPEXPIRE key ms FIELDS ...` | 相对过期（毫秒） | 用于短窗口限流 |
| `HEXPIREAT key ts FIELDS ...` | 绝对过期（秒级 Unix 时间戳） | 与业务到期时间对齐 |
| `HPEXPIREAT key ts FIELDS ...` | 绝对过期（毫秒） | 跨时区对齐 |
| `HTTL key FIELDS n f1...` | 查询剩余秒数 | 返回 `-2` 字段不存在 / `-1` 无 TTL |
| `HPTTL key FIELDS ...` | 查询剩余毫秒 | 精度更高 |
| `HEXPIRETIME key FIELDS ...` | 查询绝对到期秒 | 返回 `-2`/`-1` |
| `HPERSIST key FIELDS ...` | 移除字段 TTL，变永久 | 用户「记住我」永久续期 |
| `HGETEX` / `HSETEX` | 读/写并设置 TTL（原子） | 8.0 新增，避免 GET+EXPIRE 两次往返 |

注意语法细节：`FIELDS` 是**必需的关键字**，后面跟字段个数，再跟字段名。这是为了未来扩展（比如以后可能支持 `VALUES`），也让命令解析更快。

```
127.0.0.1:6379> HSET session:u100 dev:ios "tokenA" dev:web "tokenB"
(integer) 2
127.0.0.1:6379> HEXPIRE session:u100 3600 FIELDS 1 dev:ios
1) (integer) 1
127.0.0.1:6379> HTTL session:u100 FIELDS 2 dev:ios dev:web
1) (integer) 3596
2) (integer) -1
```

## 二、返回值语义：比想象中复杂

`HEXPIRE` 返回一个整数数组，每个元素对应一个字段，取值含义必须背下来，否则线上排查会误判：

| 返回值 | 含义 |
|---|---|
| `1` | 过期时间设置成功 |
| `0` | 设置了条件（NX/XX/GT/LT）但条件不满足 |
| `-1` | **字段不存在**（key 也不存在时同理） |
| `2` | 字段存在，但**因为过期时间已过，字段被立即删除**（注意：仍算「成功删除」，不报错） |

`-1` 和 `2` 是最容易踩的两个。`-1` 常见于「先 HEXPIRE 再 HSET」的顺序错误；`2` 则出现在给「已过期但尚未被惰性删除」的字段设置过去时间时——它会把字段直接删掉，业务侧看起来像「数据莫名消失」。

条件选项与 key 级 `EXPIRE` 一致：

```bash
# 只在字段当前没有 TTL 时设置（不覆盖已有 TTL）
HEXPIRE session:u100 3600 NX FIELDS 1 dev:ios
# 只在字段有新 TTL 更短时更新（防止续期把短 TTL 拉长）
HEXPIRE session:u100 60 LT FIELDS 1 dev:ios
# 只在字段 TTL 更长时更新（用于「至少保留 1 小时」）
HEXPIRE session:u100 3600 GT FIELDS 1 dev:ios
```

`GT`/`LT` 是幂等续期的关键：客户端重试可能导致 TTL 被反复延长，用 `LT` 可以保证「只缩短不延长」，避免会话永不过期。

## 三、底层实现：从 listpack 到 ebuckets

理解实现才能理解坑。Redis Hash 有两种编码：

- **listpack**（小 Hash，字段少且短）：字段连续存储，没有独立元数据位置；
- **hashtable**（大 Hash）：哈希桶 + `dictEntry`。

字段级 TTL 需要给每个字段存「到期时间」，listpack 里没有地方放。Redis 的做法是：

1. 当对一个 listpack 编码的 Hash 执行 `HEXPIRE` 时，**强制转换为 hashtable 编码**（`hashTypeConvert`）；
2. 在 `dictEntry` 的元数据区（利用 `key` 指针的低位标记）挂上过期时间；
3. 同时把 `(db, key, field, expireAt)` 注册到全局的 **ebuckets**（expire buckets）结构里。

`ebuckets` 是 Redis 7.4 新增的数据结构，本质是「按过期时间分桶的哈希表 + 每个桶内的有序链表」，专门支撑字段级过期。它的设计目标是**低内存开销**（每个条目约 16~24 字节）和 **O(1) 摊销取最小过期时间**。

主动过期由 `activeExpireCycle` 扩展而来：每 100ms 一轮，从 ebuckets 里取到期条目，采样删除。惰性过期则在 `HGET`/`HGETALL` 等读取路径上判断。

**这里有两个直接推论：**

- 小 Hash 一加 `HEXPIRE` 就从 listpack 变 hashtable，内存可能**翻 2~3 倍**。如果你的 Hash 平均只有 3 个字段，用字段级 TTL 反而更费内存。
- 过期是**近似实时**的：设置了 `HPEXPIRE key 0 FIELDS 1 f` 后，`HGET` 立刻读不到（惰性过期生效），但 `HLEN` 的返回值在主动过期跑完前可能仍包含它。

## 四、与旧方案对比：什么时候该用

| 方案 | key 数量 | 内存 | 批量读 | 过期精度 | 适用场景 |
|---|---|---|---|---|---|
| 每个元素一个 key + `EXPIRE` | N（爆炸） | 高（每个 key 有 dictEntry + expires 开销约 80~100B） | 需要 pipeline/MGET | 秒级，精确 | 元素少、独立访问频繁 |
| 单 Hash + key 级 TTL | 1 | 低 | `HGETALL` 一次拿全 | **最粗**（整体过期） | 全量同时失效（如配置缓存） |
| 单 Hash + 业务侧定时清理 | 1 | 低 | 一次拿全 | 取决于任务周期 | 能容忍延迟清理、量大 |
| **单 Hash + 字段级 TTL** | 1 | 中（hashtable + ebuckets） | 一次拿全 | 秒/毫秒级 | **元素生命周期独立、需批量读** |
| `ZSet` score 存到期时间 | 1 | 中 | `ZRANGEBYSCORE` 取有效 | 靠读时过滤 | 排行榜 + 滑动窗口 |

判断标准很简单：**「同一批数据经常要一起读」且「各自过期时间不同」→ 字段级 TTL**。典型的三个场景：

**场景 1：多端会话**
```bash
HSET session:u100 ios:t1 "..." android:t2 "..." web:t3 "..."
HEXPIRE session:u100 2592000 FIELDS 1 ios:t1     # iOS 30 天
HEXPIRE session:u100 604800  FIELDS 1 web:t3     # Web 7 天
```
用户在某端登出，只需 `HDEL` 单个字段，其他端不受影响——这是 key 级 TTL 完全做不到的。

**场景 2：购物车**
每个 sku 独立 7 天过期，`HGETALL cart:u100` 一次拿全，比 100 个 key 的 `MGET` 省一个数量级的 RTT。

**场景 3：滑动窗口限流（配合 `HINCRBY`）**
```bash
# 每个用户一个 Hash，字段是「秒级时间片」
HINCRBY rl:api:u100 1730592000 1
HEXPIRE rl:api:u100 60 FIELDS 1 1730592000
```
窗口外的字段自动过期，不需要定时任务清理，也不会因为清理任务挂掉而内存泄漏。

## 五、Java 落地：三个客户端的写法

### 5.1 Lettuce（推荐，原生支持）

Lettuce 6.4+ 提供了 `hexpire` 系列方法：

```java
@Configuration
public class RedisConfig {
    @Bean
    public RedisClient redisClient() {
        return RedisClient.create("redis://localhost:6379");
    }

    @Bean(destroyMethod = "shutdown")
    public StatefulRedisConnection<String, String> connection(RedisClient client) {
        return client.connect();
    }
}
```

```java
@Service
public class SessionService {

    private final RedisCommands<String, String> cmd;

    public SessionService(StatefulRedisConnection<String, String> conn) {
        this.cmd = conn.sync();
    }

    /** 写入会话并设置该设备独立 TTL，原子性由 HSETEX 保证 */
    public void putSession(String userId, String device, String token, Duration ttl) {
        String key = "session:" + userId;
        cmd.hsetex(key, HSetExArgs.Builder.ex(ttl).fnx(), Map.of(device, token));
    }

    /** 续期：只缩短不延长，避免重试把会话拉成永久 */
    public boolean touch(String userId, String device, Duration ttl) {
        List<Long> r = cmd.hexpire("session:" + userId,
                ttl.toSeconds(), ExpireArgs.Builder.lt(), device);
        // 1=成功 0=条件不满足 -1=字段不存在 2=已立即删除
        return !r.isEmpty() && r.get(0) == 1L;
    }

    /** 登出单端 */
    public long logout(String userId, String device) {
        return cmd.hdel("session:" + userId, device);
    }

    /** 批量查 TTL，用于「即将过期」提示 */
    public Map<String, Long> ttls(String userId, String... devices) {
        List<Long> list = cmd.httl("session:" + userId, devices);
        Map<String, Long> result = new HashMap<>();
        for (int i = 0; i < devices.length; i++) {
            result.put(devices[i], list.get(i));
        }
        return result;
    }
}
```

### 5.2 Spring Data Redis（需原生命令逃生口）

Spring Data Redis 3.4 目前还没有 `hexpire` 的 API 封装，用 `RedisTemplate.execute` 走原生命令：

```java
@Component
public class FieldTtlOps {

    private final RedisTemplate<String, String> redis;

    public List<Long> hexpire(String key, long seconds, String... fields) {
        return redis.execute((RedisCallback<List<Long>>) conn -> {
            byte[] rawKey = key.getBytes(StandardCharsets.UTF_8);
            byte[][] args = new byte[2 + fields.length][];
            args[0] = String.valueOf(seconds).getBytes(StandardCharsets.UTF_8);
            args[1] = "FIELDS".getBytes(StandardCharsets.UTF_8);
            for (int i = 0; i < fields.length; i++) {
                args[2 + i] = fields[i].getBytes(StandardCharsets.UTF_8);
            }
            // 注意：连接层返回的是 Long 列表
            return conn.execute("HEXPIRE", concat(new byte[][]{rawKey}, args))
                       .stream().map(v -> (Long) v).toList();
        });
    }
}
```

不建议用 `Lua` 包装，因为 `HEXPIRE` 已经是原子的，多包一层只增加维护成本。

### 5.3 Jedis

```java
try (Jedis jedis = pool.getResource()) {
    List<Long> r = jedis.hexpire("cart:u100", 604800, "sku:1", "sku:2");
    // Jedis 5.2+ 直接支持 varargs 形式
}
```

## 六、生产环境的五个坑

**坑 1：编码转换导致内存翻倍**
前面说过，`HEXPIRE` 会把 listpack 转 hashtable。一个存 5 个短字段的 Hash，listpack 可能只占 200 字节，转 hashtable 后 600 字节起步，外加每个字段 24 字节的 ebuckets 条目。**上线前用 `MEMORY USAGE key` 对比一次**，元素少于 10 个时优先考虑拆 key。

**坑 2：主从复制与持久化的一致性**
字段级 TTL 的过期时间会随 `HSET`/`HEXPIRE` 一起传播到副本和 AOF，但**过期删除动作以主库为准**。从库读到的「已过期字段」在主动过期同步过来之前仍可能存在（和 key 级 TTL 的老问题一样）。**读从库做会话校验时必须自己做一次 TTL 判断**：

```java
long ttl = cmd.httl(key, device).get(0);
if (ttl <= 0) { /* 视为过期 */ }
```

**坑 3：大量字段同时到期造成 CPU 尖刺**
`activeExpireCycle` 是单线程的。如果你把 100 万个字段的 TTL 都设成同一个整点（比如「每天 0 点清理」），0 点会出现明显的 CPU 抖动。**给 TTL 加随机抖动**：

```java
long base = Duration.ofDays(7).toSeconds();
long jitter = ThreadLocalRandom.current().nextLong(0, 3600); // 0~1h
cmd.hexpire(key, base + jitter, ExpireArgs.Builder.nx(), field);
```

**坑 4：Cluster 下的多 key 限制**
字段级 TTL 的所有命令都是单 key 操作，天然对 Cluster 友好。但如果你想「批量给 100 个用户的会话设 TTL」，必须按 slot 分组用 pipeline，不能指望一条命令搞定。

**坑 5：监控缺失**
`INFO` 里没有「字段级 TTL 数量」的直接指标。要监控内存增长，只能靠 `MEMORY USAGE` 采样 + 业务侧埋点（每次 `HEXPIRE` 计数）。建议在网关层加一个「会话 Hash 平均字段数」的 gauge，字段数异常增长往往意味着登出逻辑漏了 `HDEL`。

## 七、面试追问

**Q1：字段级 TTL 和 key 级 TTL 在实现上有什么本质区别？**
key 级 TTL 存在 `redisDb.expires` 字典里（key -> 过期时间），一个 key 一个条目；字段级 TTL 需要额外的 `ebuckets` 结构按过期时间组织 `(key, field)` 对，并且要求 Hash 必须是 hashtable 编码，因为 listpack 没有存放元数据的位置。两者的主动过期都跑在 `activeExpireCycle` 里，但字段级需要额外的「按 db 分桶」逻辑。

**Q2：为什么 HEXPIRE 需要 FIELDS 关键字？**
为了命令可扩展性和解析性能。Redis 命令参数一旦定型很难改，`FIELDS` 把「字段列表」和未来可能的其他参数（如 `VALUES`）隔离开，同时让解析器可以快速定位参数区，避免逐个判断。

**Q3：设置字段 TTL 后，`HLEN` 会立即变化吗？**
不一定。字段已在逻辑上过期（`HGET` 读不到），但物理删除依赖惰性/主动过期。`HLEN` 统计的是字典里的条目数，可能短暂包含已过期字段。做精确计数应该用 `HGETALL` + 过滤，或用 `HTTL` 判断。

**Q4：字段全部过期后，key 会自动删除吗？**
会。当 Hash 的最后一个字段被删除（无论 `HDEL` 还是过期），Redis 会删除整个 key，不会留下空 Hash。这一点比很多人预期的更友好。

**Q5：这个特性对 AOF 重写有什么影响？**
AOF 重写时，Redis 会把 Hash 的所有字段用 `HSET` 重放，然后对每个仍有 TTL 的字段追加 `HPEXPIREAT`（绝对时间）。所以重写后的 AOF 体积会略大，且重放时必须保证时钟正确——容器环境里 `CLOCK_REALTIME` 异常会导致 TTL 计算错乱。

## 总结

- **HEXPIRE 命令族**把过期粒度从 key 下沉到 field，解决了会话、购物车、限流窗口三类经典拆 key 问题；
- 返回值 `1/0/-1/2` 必须背熟，`-1`（字段不存在）和 `2`（立即删除）是最容易误判的两个；
- `NX`/`XX`/`GT`/`LT` 是**幂等续期**的关键，客户端重试场景务必用 `LT`；
- 底层依赖 `ebuckets` + hashtable，**小 Hash 会有 2~3 倍内存放大**，元素少于 10 个时慎用；
- Java 侧 Lettuce 6.4+ 原生支持，Spring Data Redis 需走 `RedisCallback` 逃生口；
- 生产上注意主从延迟、整点过期尖刺（加抖动）、以及「字段级 TTL 数量」的监控盲区。

字段级 TTL 不是银弹，但在「同批读、各自过期」这个明确场景下，它是目前 Redis 上最优的建模方式。下次再有人想拆 100 个 key 存购物车，你可以把 `HEXPIRE` 甩给他。
