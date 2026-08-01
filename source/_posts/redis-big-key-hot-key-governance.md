---
title: Redis 大 Key 与热 Key 问题排查与治理实战
date: 2026-08-01 08:30:00
tags:
  - Redis
  - 性能优化
  - 生产实战
categories:
  - Java
  - 中间件
author: 东哥
---

# Redis 大 Key 与热 Key 问题排查与治理实战

线上 Redis 突然延迟飙升、CPU 打满、请求超时？十有八九是**大 Key 或热 Key**在作祟。这两个问题是 Redis 生产事故的头号元凶，也是面试必问的高频题。本文从判定标准、危害原理、排查手段到治理方案，给你一套完整的实战方法论。

<!-- more -->

## 一、什么是大 Key 和热 Key？

### 大 Key（Big Key）

指单个 Key 的 value 体积过大或元素数量过多：

| 类型 | 判定标准 | 典型案例 |
|------|----------|----------|
| String | value 超过 **10KB**（严格标准 100KB） | 大 JSON、图片 Base64 |
| Hash / Set / ZSet / List | 元素超过 **5000 个**，或总大小超 10MB | 全量用户标签、日活名单 |

### 热 Key（Hot Key）

指在极短时间内被**极高频率访问**的 Key，比如：

- 热点新闻、秒杀商品、爆款直播间数据
- 某个 Key 的 QPS 占实例总 QPS 的 30% 以上即为严重热 Key

### 危害对比

| 问题 | 大 Key | 热 Key |
|------|--------|--------|
| 主要危害 | 阻塞单线程、网络拥塞、内存倾斜 | 单分片被打爆、缓存雪崩、连接耗尽 |
| 触发场景 | 读写该 Key 时 | 高并发访问该 Key 时 |
| 影响范围 | 该 Key 所在实例的所有请求 | 该 Key 所在分片，进而拖垮整个集群 |

## 二、为什么危害这么大？原理分析

### 1. Redis 是单线程模型

Redis 处理命令是单线程的（6.0 后多线程仅用于网络 IO 读写），**任何一条命令执行时间过长都会阻塞后续所有命令**。大 Key 的操作恰恰命中两个耗时点：

- **GET 大 String**：一次网络传输 10MB 数据，带宽打满，且序列化/反序列化耗时
- **DEL 大集合**：删除 100 万个元素的集合，需要逐个释放内存，**可能阻塞秒级**——这是最经典的线上事故：删了一个大 Key，整个 Redis 卡死几秒

### 2. 热 Key 引发缓存雪崩

热 Key 所在分片 CPU 打满 → 请求超时 → 大量请求穿透到数据库 → 数据库被打垮 → 缓存全部失效 → 雪崩。这是典型的**单点故障放大链**。

## 三、如何发现大 Key 和热 Key？

### 1. 发现大 Key

**方法一：redis-cli --bigkeys 扫描**

```bash
redis-cli -h 127.0.0.1 -p 6379 --bigkeys
# 输出各类数据类型中最大的 Key（注意：是采样扫描，不是全量精确统计）
```

**方法二：MEMORY USAGE 精确统计**

```bash
> MEMORY USAGE user:profile:12345
(integer) 12582912   # 12MB，确诊大 Key
```

**方法三：Redis 4.0+ 用 SCAN 写脚本统计**，避免 KEYS 阻塞：

```bash
redis-cli --scan --pattern 'user:*' | xargs -L 100 redis-cli MEMORY USAGE > sizes.txt
```

**方法四：控制台/监控平台**：阿里云 Redis 控制台自带大 Key 分析，每夜自动扫描，最省事。

### 2. 发现热 Key

- **redis-cli --hotkeys**（需开启 maxmemory-policy 为 LFU 淘汰策略）
- **MONITOR 命令采样**：短时间抓取命令统计频次（注意 MONITOR 本身有性能开销，只建议低峰期短暂开启）
- **客户端统计**：在 Jedis/Lettuce 的拦截器里做本地频次统计
- **代理层/云监控**：Codis、云厂商控制台都有热 Key 检测

## 四、大 Key 治理方案

### 1. 拆分（首选）

把大 Key 拆成多个小 Key：

- **Hash 大 Key**：按业务维度拆分，如 `user:tags:12345` 拆成 `user:tags:12345:type1`、`type2`...
- **List 大 Key**：按时间切片，如 `news:list:20260101`、`news:list:20260102`
- **String 大 JSON**：拆字段或压缩（如用 Protobuf / 压缩后存储）

### 2. 压缩

value 过大时先压缩再存，比如 Gzip 后 JSON 通常能缩小 70%+。注意压缩和解压的 CPU 开销，权衡后使用。

### 3. 删除/清理：用 UNLINK 代替 DEL

```bash
> DEL big_key          # 同步删除，可能阻塞
> UNLINK big_key       # 异步删除，后台线程回收内存，不阻塞
```

**这是 Redis 4.0 提供的救命命令**，遇到必须删除的大 Key 一律用 UNLINK。

### 4. 渐进式清理

大集合按批次慢慢删（避免瞬时压力）：

```java
// 每次删 100 个元素，循环直到删完
while (jedis.zremrangeByRank("big:zset", 0, 99) > 0) {
    // 间隔 10ms，给 Redis 喘息时间
    Thread.sleep(10);
}
```

### 5. 过期策略关注

带过期时间的大 Key，到期时同样会阻塞（删除也是耗时的）。解决方案：过期时间加随机抖动，避免同一时刻集体过期。

## 五、热 Key 治理方案

### 1. 本地缓存兜底（最有效）

把热 Key 数据在 JVM 本地缓存一份（Caffeine），设置短过期时间（如 1~5 秒），把 90% 以上的流量拦截在应用层：

```java
@Cacheable(cacheNames = "hot", key = "#id", unless = "#result == null")
public HotData getHotData(String id) {
    // 先查本地 Caffeine，未命中再查 Redis
    return redisTemplate.opsForValue().get("hot:" + id);
}
```

注意一致性：本地缓存会短暂不一致，适合对实时性要求不高的热点数据（榜单、配置、商品详情）。

### 2. 读写分离 / 多副本

- 集群模式下给热 Key 所在分片扩容，或把热 Key 复制到多个分片（如 `hot:0` ~ `hot:9`，请求随机取一个），分散单点压力
- 配合 `client-output-buffer-limit` 调整，防止大量连接挤爆

### 3. 热点打散

秒杀场景常见的做法：**把单个 Key 拆成 N 个分片 Key + 随机后缀**，读的时候随机读一个分片。数据一致性要求不高的场景非常好用。

### 4. 限流与降级兜底

即使做了上面所有事，也要给热 Key 加一层保护：应用侧信号量限流 + 熔断降级，宁可返回旧数据，也不能打垮数据库。

### 5. 拒绝"读放大"

排查业务是否真的需要高频读：热点数据是否可静态化到 CDN？是否可合并批量查询？很多时候热 Key 是业务设计问题，不是 Redis 问题。

## 六、Java 侧检测与处理示例

```java
@Component
public class KeyHealthCheck {

    @Autowired
    private StringRedisTemplate redisTemplate;

    /** 定期扫描统计大 Key（示例：对指定 pattern 做抽样） */
    @Scheduled(fixedDelay = 3600_000L)
    public void scanBigKeys() {
        ScanOptions options = ScanOptions.scanOptions()
                .match("user:*").count(1000).build();
        try (Cursor<String> cursor = redisTemplate.scan(options)) {
            while (cursor.hasNext()) {
                String key = cursor.next();
                Long size = redisTemplate.execute(
                        connection -> connection.memoryUsage(key.getBytes()));
                if (size != null && size > 10 * 1024 * 1024) {  // >10MB 告警
                    log.warn("发现大 Key: {}，占用 {} bytes", key, size);
                }
            }
        }
    }
}
```

## 七、面试官追问

**Q1：为什么删除大 Key 会阻塞 Redis？**
答：Redis 主线程单线程执行命令，DEL 一个包含百万元素的集合，需要主线程逐一把元素从哈希表移除并释放内存，这个过程可能耗时数百毫秒甚至秒级，期间所有其他命令排队等待，表现为整个实例卡顿。UNLINK 把释放内存的工作丢给后台线程异步执行，主线程立即返回，所以不阻塞。

**Q2：热 Key 和缓存击穿有什么区别？**
答：击穿是单个 Key 缓存过期瞬间大量并发请求打到数据库，是"时间点问题"；热 Key 是某个 Key 被超高频率访问导致 Redis 单点压力过大，是"持续性问题"。但热 Key 会放大击穿风险，二者经常一起治理（本地缓存 + 互斥锁重建）。

**Q3：如何防止大 Key 的产生？**
答：规范先行：① 写入前预估 value 大小，超过阈值告警/拒绝；② 限制集合类 Key 最大元素数，超出自动拆分；③ 定期巡检（--bigkeys + MEMORY USAGE）；④ 关键业务写入时用 Lua 脚本做长度检查。

**Q4：本地缓存怎么保证一致性？**
答：常用方案：① 短过期时间兜底，容忍秒级延迟；② Redis 发布订阅/消息队列通知各节点失效本地缓存；③ 对一致性要求高的数据不做本地缓存，或用 Caffeine 的 refreshAfterWrite 异步刷新。

## 总结

大 Key 和热 Key 是 Redis 生产事故的"哼哈二将"：**大 Key 靠拆分、压缩、UNLINK、渐进删除来治；热 Key 靠本地缓存、多副本、打散、限流来防**。核心心法：把大流量挡在 Redis 之外，把大对象挡在 Redis 之外。建议把"定期巡检大 Key + 热点监控告警"纳入日常运维 SOP，别等事故来找你。
