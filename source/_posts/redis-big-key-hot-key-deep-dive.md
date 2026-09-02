---
title: 【Redis 实战】Redis 大 Key 与热 Key 问题深度解析：从危害识别、监控定位到完整治理方案
date: 2026-09-02 08:00:00
tags:
  - Redis
  - 中间件
  - 高并发
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Redis 实战】Redis 大 Key 与热 Key 问题深度解析：从危害识别、监控定位到完整治理方案

## 面试官：线上 Redis 突然变慢、CPU 飙升、甚至发生阻塞，你会怎么排查？

很多同学第一反应是"看慢日志、看 bigkeys"，但真正能系统讲清楚**大 Key 和热 Key 的完整治理链路**的人不多。今天我们从原理到实战，一次性把这两个"Redis 头号杀手"讲透。

---

## 一、什么是大 Key？什么是热 Key？

### 1.1 大 Key（Big Key）

大 Key 不是指某个 Key 的**字符串值**很长，而是指单个 Key 占用内存过大或元素数量过多。业界一般没有绝对标准，常用的判断线是：

| 类型 | 判定标准（参考） | 举例 |
| --- | --- | --- |
| String | value 超过 10KB | 一个 JSON 序列化的大对象、一张 Base64 图片 |
| Hash / Set / ZSet / List | 元素数量超过 5000 个，或总大小超过 10MB | 一个存了几万条用户行为的 Hash |
| 单个 value 过大 | 超过 1MB 就要警惕 | 缓存整张报表数据 |

### 1.2 热 Key（Hot Key）

热 Key 指**在极短时间内被高频访问**的 Key，典型场景：

- 双十一秒杀商品详情（一个商品 Key 扛下千万级 QPS）
- 微博热搜榜第一条
- 微信朋友圈的某条爆款动态

判定标准一般是：单个 Key 的 QPS 超过集群单节点能力的 10%~20% 就要重点关注。

---

## 二、大 Key 的四大危害（面试必答）

### 2.1 阻塞 Redis 单线程

Redis 是单线程执行命令的，**任何耗时的操作都会阻塞后续所有命令**。对大 Key 执行以下命令时阻塞风险极高：

- `KEYS *`：全库遍历，O(N)
- `SMEMBERS`、`HGETALL`、`LRANGE 0 -1`：一次性取回所有元素
- `DEL` 一个包含几百万元素的集合：释放内存的耗时会让 Redis 卡顿数秒
- `SUNIONSTORE`、`ZUNIONSTORE`：计算复杂度 O(N+M)

```bash
# 一个 500 万元素的 Set，DEL 它可能阻塞 1~2 秒
> DEL huge_set
(error) 或卡顿...
```

### 2.2 网络拥塞与带宽打满

大 Key 的 value 动辄几十 MB，一次 `GET` 就要在网络上传输几十 MB 数据，多个客户端同时请求直接打满网卡带宽，拖垮整个集群。

### 2.3 内存不均与数据倾斜

Redis Cluster 中，大 Key 只存在于**一个分片**上，导致：

- 该分片内存使用率远超其他分片，触发 maxmemory 淘汰
- 该分片所在节点成为性能瓶颈，集群整体"木桶效应"

### 2.4 主从复制阻塞与数据不一致

大 Key 在主从全量同步、增量同步（写命令传递）时会显著增加同步耗时，极端情况下导致主从延迟暴涨、从节点持续追不上主节点。

---

## 三、如何发现大 Key？（监控定位手段）

### 3.1 慢日志优先排查

```bash
# 查看最近 100 条慢日志
> SLOWLOG GET 100
```

如果慢日志里大量出现 `DEL`、`SMEMBERS`、`HGETALL` 等命令，大概率就是大 Key 在做祟。

### 3.2 redis-cli --bigkeys（离线扫描）

```bash
redis-cli --bigkeys --i 0.1
```

`--i 0.1` 表示每扫描 100 个 Key 暂停 0.1 秒，**避免扫描本身阻塞线上**。它会分类型统计出最大的 String / Hash / List / Set / ZSet。

> 注意：`--bigkeys` 只是"抽样统计"，且扫描时用了 `SCAN` 而非 `KEYS`，相对安全，但仍建议低峰期执行。

### 3.3 自定义 SCAN 脚本精确统计

生产上更推荐写脚本，定期对指定 Key 做 `HLEN`、`LLEN`、`SCARD`、`ZCARD`、`STRLEN` 统计：

```bash
# 用 SCAN 游标遍历，避免阻塞
redis-cli -h 127.0.0.1 -p 6379 --scan --pattern 'user:*' | while read key; do
  size=$(redis-cli -h 127.0.0.1 -p 6379 STRLEN "$key")
  if [ "$size" -gt 10240 ]; then
    echo "BIG KEY: $key size=$size"
  fi
done
```

### 3.4 内存分析工具

- **redis-rdb-tools（rdb.py）**：离线解析 RDB 文件，精确统计每个 Key 的大小
- **RDB 分析 + 可视化**：rdr（Redis Data Reveal）等工具生成可视化报告

---

## 四、大 Key 治理方案（核心干货）

### 4.1 拆分：大 Key 拆小

**String 大 value**：拆成多个 Key，按业务维度分片：

```java
// 原来是：SET user:10001 一大坨JSON
// 拆成：user:10001:base（基本信息）、user:10001:orders（最近订单）...
```

**Hash 大 Key**：按 HashTag 或字段前缀拆分成多个 Hash：

```java
// 原：HSET user:fans 1000001 1 1000002 1 ...（百万粉丝）
// 拆：按粉丝 ID 取模，拆成 100 个 Hash：user:fans:0 ~ user:fans:99
int shard = userId % 100;
redis.hset("user:fans:" + shard, fanId, "1");
```

### 4.2 删除：拒绝 DEL，用 UNLINK 或渐进式删除

Redis 4.0+ 提供了 `UNLINK`，**异步释放内存**，命令立即返回，不阻塞主线程：

```bash
> UNLINK huge_key
```

如果 Redis 版本低于 4.0，只能渐进式删除：

```bash
# 渐进式删除大 List
> LLEN mylist
> LTRIM mylist 0 -101   # 每次删掉尾部 100 个
> LTRIM mylist 0 -101
...
# 直到 LLEN 为 0，最后再 DEL
```

### 4.3 过期时间：给 Key 加 TTL

很多大 Key 是历史数据堆积导致的，业务上应设置合理的过期时间，防止无限膨胀：

```java
// 设置 7 天过期
redis.opsForValue().set(key, value, 7, TimeUnit.DAYS);
```

### 4.4 数据压缩

对 String 大 value 使用压缩（如 gzip 后 Base64），可减少 80%+ 的空间占用和网络传输量。**但要注意压缩/解压本身消耗 CPU**，高频访问的场景要权衡。

---

## 五、热 Key 的四大危害

1. **单节点热点**：Cluster 模式下热 Key 只落在单个分片，该分片 CPU 打满，其他分片空闲
2. **缓存击穿连锁反应**：热 Key 过期瞬间，大量请求同时穿透到数据库，DB 直接被压垮
3. **服务端阻塞**：单 Key 的并发读写命令排队执行，表现为 RT 急剧上升
4. **缓存雪崩放大器**：多个热 Key 同时过期，放大雪崩效应

## 六、如何发现热 Key？

| 手段 | 原理 | 特点 |
| --- | --- | --- |
| `redis-cli --hotkeys` | 基于 `object freq`（需开启 LFU 淘汰策略） | 快速但只统计访问频率，且要求 maxmemory-policy 为 allkeys-lfu/volatile-lfu |
| `MONITOR` 命令 | 实时抓取所有命令 | 准确但**极其消耗性能**，只建议短时间低峰用 |
| 客户端统计 | 在 Jedis/Lettuce 调用处埋点计数 | 最灵活，推荐生产使用 |
| 代理层统计 | Codis/Twemproxy 等代理统计 Key 访问次数 | 中间件方案，无需改代码 |

```bash
# 方式一：开启 LFU 后使用 hotkeys
> CONFIG SET maxmemory-policy allkeys-lfu
> redis-cli --hotkeys

# 方式二：短时间 MONITOR（慎用！）
redis-cli MONITOR | awk '{print $4}' | sort | uniq -c | sort -rn | head -20
```

## 七、热 Key 治理方案

### 7.1 本地缓存兜底（最常用）

热 Key 打一层 JVM 本地缓存（Caffeine），把 Redis 的热点流量挡在应用内：

```java
Cache<String, Object> localCache = Caffeine.newBuilder()
        .maximumSize(10_000)
        .expireAfterWrite(5, TimeUnit.SECONDS)  // 本地缓存 5 秒，可容忍短暂不一致
        .build();

public Object get(String key) {
    Object v = localCache.getIfPresent(key);
    if (v == null) {
        v = redis.get(key);       // 只放行少量请求到 Redis
        if (v != null) localCache.put(key, v);
    }
    return v;
}
```

### 7.2 热点 Key 复制（读写分离 + 副本扩容）

把热 Key 在逻辑上复制成 N 份，散列到不同分片：

```java
// 原 Key：goods:1001
// 复制 Key：goods:1001:0、goods:1001:1 ... goods:1001:9
int copies = 10;
int idx = ThreadLocalRandom.current().nextInt(copies);
String key = "goods:1001:" + idx;
Object v = redis.get(key);
```

写入时同时写 N 份（或只在主分片写，读时对缺失副本回源）。这样单 Key 的 QPS 被摊到 N 个分片。

### 7.3 读写分离

把热 Key 的读请求全部路由到从节点，主节点只承担写，缓解主节点压力。

### 7.4 预热与过期时间加随机

- 活动开始前把热 Key **提前写入并设置较长 TTL**
- 过期时间加随机值：`TTL = base + random(0, 300)`，避免同时过期

### 7.5 限流与降级

对访问热 Key 的接口做限流（Sentinel/Guava RateLimiter），超出阈值的请求直接降级返回兜底数据，保护 Redis 和数据库。

---

## 八、面试高频追问

**Q1：大 Key 用 DEL 删除了，为什么 Redis 还是卡？**
因为 `DEL` 是同步释放内存的，几百万元素的内存释放（free、合并内存碎片）会阻塞主线程。所以要用 `UNLINK` 异步删除。

**Q2：`--bigkeys` 扫描会阻塞线上吗？**
它基于 `SCAN` 游标渐进遍历，不会一次性阻塞；但 `--bigkeys` 内部对每个 Key 会执行 `STRLEN/HLEN` 等命令，在大 Key 上仍有轻微开销，建议加 `--i` 限速并低峰执行。

**Q3：本地缓存 + Redis 双缓存，一致性怎么保证？**
本地缓存设置极短 TTL（秒级）+ 主动失效（Redis Pub/Sub 或 Canal 监听 binlog 通知各实例删除本地缓存）。业务上接受秒级延迟即可，强一致场景不要用本地缓存。

**Q4：热 Key 复制 N 份后，写操作怎么办？**
写操作仍写原始 Key（或同步写所有副本），读时随机读副本；副本未命中时回源原始 Key 并回填。牺牲一点写开销和一致性，换取读热点摊平。

**Q5：大 Key 和热 Key 同时存在怎么办？**
先治理大 Key（拆分 + 异步删除），再治理热 Key（本地缓存 + 副本复制）。大 Key 本身往往就是读写热点，拆小后热 Key 的 QPS 也会自然下降。

---

## 总结

大 Key 与热 Key 是 Redis 生产事故的两大源头：

- **大 Key**：拆小（Hash 分片、String 拆分）、异步删（UNLINK）、加 TTL、压缩
- **热 Key**：本地缓存兜底、副本复制摊平、读写分离、预热 + 随机过期、限流降级
- **监控**：慢日志、`--bigkeys`/`--hotkeys`、SCAN 脚本、rdb 分析工具，形成日常巡检机制

治理的核心思路就一句话：**让任何单个 Key 都不至于成为单点瓶颈**。
