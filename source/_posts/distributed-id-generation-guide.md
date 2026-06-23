---
title: 分布式 ID 生成方案深度解析：雪花算法、美团 Leaf、百度 UidGenerator 与 Redis
date: 2026-06-23 08:00:00
tags:
  - 分布式
  - ID生成
  - 雪花算法
categories:
  - 架构
  - 分布式
author: 东哥
---

# 分布式 ID 生成方案深度解析：雪花算法、美团 Leaf、百度 UidGenerator 与 Redis

## 面试官：说说分布式系统中如何生成全局唯一 ID？

在单库时代，MySQL 自增 ID 就能搞定一切。但一旦进入分布式、分库分表场景，一个全局唯一、趋势递增的 ID 生成方案就成了刚需。

## 一、分布式 ID 的核心要求

| 要求 | 说明 |
|------|------|
| **全局唯一** | 整个分布式系统不能重复 |
| **趋势递增** | 按时间有序，利于 B+Tree 索引 |
| **高可用** | 服务不能挂，99.999% 可用 |
| **高性能** | 生成速度要快，QPS 要够高 |
| **业务含义** | 可选：能解析时间戳、机器信息 |

## 二、UUID：最直接但最糟糕的方案

```java
String id = UUID.randomUUID().toString().replace("-", "");
```

**优点：** 本地生成，无需网络，性能极高。

**致命缺陷：**
- **无序**：完全随机，B+Tree 频繁页分裂
- **存储膨胀**：分布式 ID 需要 32 字节 + 分隔符，占空间
- **查询慢**：二级索引性能急剧下降

> **结论**：UUID 只适合文件名、日志 traceId，千万别当数据库主键。

## 三、数据库自增方案：分段批量获取

### 3.1 传统自增 + 步长

```sql
-- 实例1：步长2，初始1 → 1,3,5,7...
-- 实例2：步长2，初始2 → 2,4,6,8...
```

**问题：** 扩缩容时需要重新计算步长，运维复杂。

### 3.2 美团的 Leaf-Segment 方案

核心思想：**一次取一段 ID，用完了再取下一段**。

```sql
CREATE TABLE `leaf_alloc` (
  `biz_tag`     VARCHAR(128) NOT NULL COMMENT '业务标识',
  `max_id`      BIGINT(20) NOT NULL COMMENT '当前最大ID',
  `step`        INT(11) NOT NULL COMMENT '步长',
  `description` VARCHAR(256),
  `update_time` TIMESTAMP,
  PRIMARY KEY (`biz_tag`)
) ENGINE=InnoDB;
```

**核心流程：**

```
[应用A] 请求 order_tag 的ID
    ↓
Leaf服务: UPDATE leaf_alloc SET max_id=max_id+step WHERE biz_tag='order_tag'
    ↓
Leaf服务: 获得 [1000, 2000) 号段 → 缓存到内存
    ↓
[应用A] 从Leaf分配ID: 1000, 1001, 1002...
    ↓
号段用光 → 再去 DB 取下一段 [2000, 3000)
```

**双 Buffer 优化：** 内存中始终维护两个号段，当前号段消耗超过 50% 时，异步加载下一段。

```java
public class SegmentBuffer {
    private Segment current;    // 当前使用的号段
    private Segment next;       // 预加载的下一号段
    private volatile boolean ready; // 下一段是否已加载
    private volatile long threshold; // 触发预加载的阈值

    public long nextId() {
        long id = current.nextId();
        // 当前段消耗过半，触发异步加载
        if (current.usage() > threshold) {
            asyncLoadNext();
        }
        return id;
    }
}
```

**性能：** QPS 可达 5W+，取决于 DB 性能。步长 step 越大，DB 压力越低。

## 四、雪花算法：时间戳 + 机器号 + 序列号

### 4.1 标准结构（64 bit）

```
 0 | 0000000000 0000000000 0000000000 0000000000 0 | 00000 | 00000 | 0000000000
└─┴────────────── 41 bit 时间戳 ──────────────┴──┴─────┴─────┴── 12 bit 序列号
  ↑                                                  ↑  ↑
符号位(不用)                                      datacenter  worker
```

- **1 bit**：符号位，固定为 0
- **41 bit**：毫秒时间戳（约 69 年）
- **5 bit**：数据中心 ID（最多 32 个）
- **5 bit**：工作节点 ID（最多 32 个）
- **12 bit**：同一毫秒内的序列号（4096 个/ms）

### 4.2 标准实现

```java
public class SnowflakeIdWorker {
    /** 起始时间戳：2020-01-01 */
    private final long epoch = 1577808000000L;
    private final long workerIdBits = 5L;
    private final long maxWorkerId = ~(-1L << workerIdBits); // 31
    private final long sequenceBits = 12L;
    private final long workerIdShift = sequenceBits; // 12
    private final long timestampShift = sequenceBits + workerIdBits + datacenterIdBits;

    private long workerId;
    private long sequence = 0L;
    private long lastTimestamp = -1L;

    public synchronized long nextId() {
        long timestamp = timeGen();
        // 时钟回拨处理
        if (timestamp < lastTimestamp) {
            throw new RuntimeException("Clock moved backwards!");
        }
        if (timestamp == lastTimestamp) {
            sequence = (sequence + 1) & maxSequence;
            if (sequence == 0) {
                // 同一毫秒用完序列号，等待下一毫秒
                timestamp = tilNextMillis(lastTimestamp);
            }
        } else {
            sequence = 0L;
        }
        lastTimestamp = timestamp;
        return ((timestamp - epoch) << timestampShift)
             | (datacenterId << datacenterIdShift)
             | (workerId << workerIdShift)
             | sequence;
    }
}
```

### 4.3 时钟回拨问题

雪花算法的最大敌人是 **时钟回拨**。常见的处理策略：

| 策略 | 方案 | 缺点 |
|------|------|------|
| **抛异常** | 回拨直接抛异常 | 影响业务 |
| **等待** | 等待时间追上 lastTimestamp | 阻塞时间不定 |
| **占用下一毫秒序列号** | 回拨时用序列号补偿 | 复杂 |
| **记录历史时间** | 提前记录 NTP 同步记录 | 需额外存储 |

**改进方案（百度 UidGenerator）**：

## 五、百度 UidGenerator：定制化雪花算法

UidGenerator 基于 Snowflake，但做了关键改进：

### 5.1 支持自定义位分配

```java
// 通过 Spring 配置灵活分配位数
<property name="timeBits" value="28"/>    // 秒级时间戳
<property name="workerBits" value="22"/>   // 机器数
<property name="seqBits" value="13"/>      // 序列号
<property name="epochStr" value="2020-01-01"/>
```

### 5.2 两种 WorkerId 分配策略

| 策略 | 说明 | 适用场景 |
|------|------|----------|
| **DisposableWorkerIdAssigner** | 数据库自增分配 workerId | 常规 Spring 应用 |
| **CustomizedWorkerIdAssigner** | 自定义策略 | 容器化、K8s 环境 |

### 5.3 缓存预生成

```java
public class BufferAllocator {
    /** 环形缓冲区，预先生成好 ID */
    private final RingBuffer ringBuffer;
    /** 填充线程后台预填 */
    private final ScheduledExecutorService scheduler;

    public long take() {
        long id = ringBuffer.take();
        // 当剩余 ID 低于阈值时，触发填充
        if (ringBuffer.remaining() < paddingThreshold) {
            scheduler.submit(this::padding);
        }
        return id;
    }
}
```

通过 RingBuffer 预先生成好一批 ID 缓存起来，生成速度可达 **600万+/秒**。

## 六、Redis ID 生成方案

利用 Redis 的 INCR 原子命令：

```java
public class RedisIdGenerator {
    private StringRedisTemplate redisTemplate;

    public Long nextId(String keyPrefix) {
        // 按天自增，方便统计
        String date = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMMdd"));
        String key = keyPrefix + ":" + date;
        Long id = redisTemplate.opsForValue().increment(key);
        // 设置过期时间，防止 key 堆积
        redisTemplate.expire(key, 7, TimeUnit.DAYS);
        // 组合：日期(8位) + 自增值(6位)
        return Long.parseLong(date) * 1_000_000 + id;
    }
}
```

**优点：** 实现简单，天然递增。

**缺点：**
- Redis 单点故障风险
- 依赖网络，延迟比本地生成高
- 集群模式下需要考虑跨节点计数

## 七、方案对比总结

| 方案 | ID 特点 | QPS | 依赖 | 时钟回拨 | 适用场景 |
|------|---------|-----|------|----------|---------|
| UUID | 无序、长 | 极高 | 无 | 无 | 日志、traceId |
| 数据库号段 | 递增 | ~5W | MySQL | 无 | 订单号、用户ID |
| 雪花算法 | 趋势递增 | ~40W | 无 | 有影响 | 通用场景 |
| 百度 UidGenerator | 趋势递增 | ~600W | DB(可选) | 无影响 | 高并发场景 |
| Redis INCR | 严格递增 | ~10W | Redis | 无 | 短ID、流水号 |

## 八、面试常见追问

> **Q：雪花算法 69 年后怎么办？**
> A：重新设计 Epoch，或使用租户 ID + Snowflake 分段。

> **Q：号段方案机器重启会浪费多少 ID？**
> A：已分配未使用的 ID 确实浪费。但步长设计合理时，浪费比例可控（一般 < 1%）。

> **Q：如何保证 ID 不重复？**
> A：唯一性靠 key 源的原子性操作（DB REPLACE INTO / Redis INCR）。业务侧要容忍极小概率的重复风险，必要时在关键表加 unique key 兜底。

> **Q：分布式 ID 生成器还需要考虑什么？**
> A：监控（号段消耗速度、QPS、latency）、白名单鉴权、容灾降级（本地 Fallback 生成临时 ID）。

---

**总结：** 没有银弹。雪花算法适合通用场景，号段方案适合强递增需求，UidGenerator 适合极致性能场景。根据业务选型，永远比追求"最好的方案"更实际。
