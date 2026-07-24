---
title: 【Redis 原理】Redis 内存淘汰策略（Eviction Policies）深度解析与实战
date: 2026-07-24 08:00:00
tags:
  - Redis
  - 缓存
  - 内存管理
  - 性能优化
categories:
  - Redis
  - 原理
author: 东哥
---

# 【Redis 原理】Redis 内存淘汰策略（Eviction Policies）深度解析与实战

## 前言

Redis 作为内存数据库，其所有数据都存储在内存中。当写入速度超过内存容量时，Redis 必须决定**应该删除哪些数据**——这就是内存淘汰策略（Eviction Policy）。选错淘汰策略可能导致缓存命中率断崖式下跌、大量请求穿透到数据库，甚至引发雪崩。

很多开发者只知道 `allkeys-lru` 或 `volatile-ttl` 这些名字，但面试官一旦追问"Redis 的近似 LRU 和标准 LRU 有什么区别？""LFU 的 counter 是如何衰减的？"，就容易答不上来。

本文将对 Redis 的 8 种淘汰策略进行深度解析，从源码层面揭秘近 LRU/LFU 的实现，并通过实战案例帮你做出最佳选择。

---

## 一、Redis 内存淘汰机制总览

### 1.1 触发条件

当以下条件满足时，Redis 会触发内存淘汰：

```bash
# 设置最大内存（默认不限制）
maxmemory 4gb

# 达到 maxmemory 后，Redis 会尝试淘汰数据
# 如果无法释放足够内存，写入操作会返回 OOM 错误
```

触发细节：
- **每次执行命令前**，Redis 会检查内存使用是否超过 `maxmemory`
- 如果超过，根据配置的策略**同步或异步**淘汰数据
- **写命令**（SET、LPUSH、SADD 等）会触发淘汰；**读命令**不会

### 1.2 八种淘汰策略速览

| 策略 | 适用范围 | 淘汰目标 | 特点 |
|------|----------|----------|------|
| `noeviction` | - | 不淘汰 | 写入直接报错 |
| `allkeys-lru` | 所有 key | 最近最少使用 | 最常用策略 |
| `allkeys-lfu` | 所有 key | 最不经常使用 | Redis 4.0+ 新增 |
| `volatile-lru` | 带 TTL 的 key | 最近最少使用 | 只淘汰有 TTL 的 key |
| `volatile-lfu` | 带 TTL 的 key | 最不经常使用 | - |
| `volatile-ttl` | 带 TTL 的 key | TTL 最短优先 | 即将过期的先淘汰 |
| `volatile-random` | 带 TTL 的 key | 随机 | - |
| `allkeys-random` | 所有 key | 随机 | - |

> **核心建议**：绝大多数场景推荐使用 `allkeys-lru`。如果数据访问频率差异明显（如热数据明显），选择 `allkeys-lfu`。

---

## 二、LRU 策略深度解析

### 2.1 标准 LRU 与近似 LRU

**标准 LRU** 需要在每次访问时更新链表，Redis 作为单线程模型，维护精确的 LRU 链表代价太高。

因此 Redis 采用**近似 LRU（Approximated LRU）**算法：

```c
// Redis 源码 evict.c 中的核心逻辑
struct evictionPoolEntry {
    unsigned long long idle;    // 空闲时间（秒）
    sds key;                    // key
    sds cached;                 // 缓存的 key 名称
    int dbid;                   // 数据库 id
    uint64_t prev_candidate_id; // 上一个候选
};

void evictionPoolPopulate(int dbid, dict *sampledict, 
                          dict *keydict, struct evictionPoolEntry *pool) {
    int count = dictGetSomeKeys(sampledict, samples, EVICTION_SAMPLES_SIZE);
    // 采样 dictGetSomeKeys 的 key，放入淘汰池
    for (int i = 0; i < count; i++) {
        // 计算 idle time = 当前时间 - 对象的 lru 字段
        idle = estimateObjectIdleTime(o);
        // 放入淘汰池，按 idle 时间排序
        poolInsert(pool, key, idle, dbid);
    }
}
```

**近似 LRU 的关键步骤**：

1. **采样**：从所有 key 中随机取 `maxmemory-samples` 个（默认 5 个）
2. **比较**：比较这些 key 的 `idle time`（空闲时间）
3. **淘汰**：淘汰 `idle time` 最大的 key

### 2.2 逐出池（Eviction Pool）优化

从 Redis 3.0 开始，引入了**淘汰池（Eviction Pool）**，大小固定为 `EVPOOL_SIZE = 16`：

- 每次淘汰不是立即丢弃采样结果
- 将采样的 key 放入一个按 `idle time` 排序的小顶堆中
- 下次淘汰时，先从池中取最优候选
- 如果池中元素不够，继续采样补充

这个优化让近似 LRU 的效果**非常接近标准 LRU**。

### 2.3 lru 时钟

每个 Redis 对象都有一个 `lru` 字段，记录最后一次被访问时的 LRU 时钟：

```c
typedef struct redisObject {
    unsigned type:4;      // 类型
    unsigned encoding:4;  // 编码
    unsigned lru:LRU_BITS; // LRU 时间（24 bit，精度秒）
    int refcount;         // 引用计数
    void *ptr;            // 指向实际数据
} robj;
```

- `LRU_BITS = 24`，最大可表示约 **194 天**
- 如果超过 194 天没有访问，`lru` 会回绕
- Redis 使用 `server.lruclock`（每 100ms 更新一次全局时钟）来比较

```c
// 计算对象空闲时间
unsigned long long estimateObjectIdleTime(robj *o) {
    unsigned long long lruclock = LRU_CLOCK();
    if (lruclock >= o->lru) {
        return (lruclock - o->lru) * LRU_CLOCK_RESOLUTION;
    } else {
        return (lruclock + (LRU_CLOCK_MAX - o->lru)) * LRU_CLOCK_RESOLUTION;
    }
}
```

---

## 三、LFU 策略深度解析

Redis 4.0 引入了 LFU（Least Frequently Used）策略，它考虑了**访问频率**而不仅仅是**最近访问时间**。

### 3.1 LFU 的计数器设计

LFU 复用了 `redisObject.lru` 字段（24 bit），但分成两部分：

```
┌──────────────────────────────────────────────┐
│  lru (24 bits)                                │
├──────────────────────┬───────────────────────┤
│  counter (16 bits)   │  timestamp (8 bits)    │
│  访问频次计数器       │   上次衰减时间戳(分钟)  │
└──────────────────────┴───────────────────────┘
```

**16 bit 计数器**理论上只能计数 65535 次，但 Redis 使用**对数递增 + 概率递减**机制，使计数器能反映真实的频率差异。

### 3.2 对数递增机制

计数器并非每次访问 +1，而是遵循**概率递增**：

```c
// evict.c - LFUDecrAndReturn
uint8_t LFULogIncr(uint8_t counter) {
    if (counter == 255) return 255;
    
    double r = (double)rand() / RAND_MAX;
    double p = 1.0 / (counter * lfu_log_factor + 1);
    
    if (r < p) counter++;
    return counter;
}
```

核心逻辑：
- `counter` 越大，下次递增的概率越小
- `lfu_log_factor`（默认 10）控制递增速度
- 访问 100 次 → counter ≈ 10
- 访问 1000 次 → counter ≈ 20
- 访问 100 万次 → counter ≈ 40
- 访问 1000 万次 → counter ≈ 100

这样，**高频和低频的差异被明显拉开**，且高频访问的 counter 不会太快饱和。

### 3.3 周期性衰减机制

**不能只看频率，还要看时间窗口**。如果一个 key 昨天被访问 1 万次，今天 0 次，它不应该比今天被访问 100 次的 key 更受欢迎。

衰减策略：

```c
unsigned long LFUDecrAndReturn(robj *o) {
    unsigned long ldt = o->lru >> 8;     // 上次衰减时间戳
    unsigned long counter = o->lru & 255; // 当前 counter
    unsigned long num_periods = server.lruclock - ldt;
    
    if (num_periods) {
        // 每隔 lfu_decay_time 分钟衰减一次
        counter = (num_periods > counter) ? 0 : counter - num_periods;
    }
    return counter;
}
```

默认 `lfu_decay_time = 1`，即每分钟衰减一次，每次减 1。

### 3.4 LFU 配置参数

```bash
# 计数器递增因子（默认 10）
# 越大则相同访问次数下 counter 增长越慢
lfu-log-factor 10

# 衰减时间（分钟，默认 1）
# 越大衰减越慢，热数据持久性越强
lfu-decay-time 1
```

**调优建议**：
- 缓存命中率低（频繁颠簸）：增大 `lfu-log-factor` 或减小 `lfu-decay-time`
- 热数据切换慢（新数据很难缓存）：减小 `lfu-log-factor` 或增大 `lfu-decay-time`

---

## 四、淘汰策略执行流程

### 4.1 完整执行链路

```
客户端写入命令 (SET/HSET/LPUSH ...)
    │
    ▼
processCommand() → 检查内存
    │
    ├─ 未超过 maxmemory
    │   └─ 正常执行
    │
    └─ 超过 maxmemory
        └─ freeMemoryIfNeeded()
            │
            ├─ noeviction → 返回 OOM 错误
            │
            └─ 其他策略
                │
                ├─ 1. 确定淘汰池范围（allkeys / volatile）
                ├─ 2. 采样并填充淘汰池
                ├─ 3. 从淘汰池选最优候选
                ├─ 4. 删除候选 key（异步释放内存）
                ├─ 5. 检查是否释放足够内存
                └─ 6. 不足则回到步骤 2
```

### 4.2 淘汰内存计算

```c
int freeMemoryIfNeeded(void) {
    while (mem_reported > server.maxmemory) {
        // 如果是渐进式删除，分批释放
        if (server.maxmemory_policy == MAXMEMORY_FLAG_LRU_LFU ||
            server.maxmemory_policy == MAXMEMORY_FLAG_TTL) {
            // 从淘汰池中逐个淘汰
            bestkey = evictFromPool(server.db[i]);
            // 删除 key，释放内存
            deleteKey(server.db[i], bestkey);
        }
        // 重新计算内存
        mem_reported = zmalloc_used_memory();
    }
}
```

---

## 五、最佳实践与案例

### 5.1 生产环境配置模板

```bash
# 最大内存：物理内存的 60-70%
maxmemory 4gb

# 推荐策略：allkeys-lru
maxmemory-policy allkeys-lru

# 采样数（默认 5，越大越精确但越慢）
maxmemory-samples 10

# LFU 配置（如果使用 allkeys-lfu）
lfu-log-factor 10
lfu-decay-time 1
```

### 5.2 不同场景策略推荐

| 场景 | 推荐策略 | 理由 |
|------|----------|------|
| 通用缓存 | `allkeys-lru` | 兼顾最近热点 |
| 有明显热数据 | `allkeys-lfu` | 保留高频 key |
| 永不过期的 Session | `allkeys-lru` | Session 最近活跃优先 |
| 有时效的验证码 | `volatile-ttl` | 即将过期的直接删 |
| 配置项多数带 TTL | `volatile-lru` | 仅淘汰有过期的 |
| 只读不写 | `noeviction` | 数据不能丢 |

### 5.3 监控淘汰情况

```bash
# 查看淘汰 key 总数
INFO stats | grep evicted_keys

# 查看内存使用
INFO memory

# 查看配置的策略
CONFIG GET maxmemory-policy
```

实时监控脚本：

```bash
watch -n 2 "redis-cli info stats | grep -E 'evicted_keys|keyspace_hits|keyspace_misses'"
```

---

## 六、常见问题与面试问答

### Q1：为什么 Redis 不用标准的 LRU 链表？

Redis 是单线程模型，维护双向链表需要加锁或阻塞，对性能影响大。而近似 LRU 通过**随机采样 + 淘汰池**实现了接近标准 LRU 的效果，时间复杂度低且实现简单。

### Q2：采样数（maxmemory-samples）怎么调？

默认 5。每增加 10 个采样，淘汰准确度提升约 5%，但 CPU 开销增加约 10%。**生产环境建议 10**，超过 20 后边际效益递减。

### Q3：allkeys-lru 和 volatile-lru 怎么选？

- `allkeys-lru`：所有 key 一视同仁，按 LRU 淘汰。**推荐大多数场景使用。**
- `volatile-lru`：只淘汰有 TTL 的 key。如果 Redis 中同时存在缓存数据和不淘汰的配置数据，可以选择此项。

### Q4：有没有办法手动触发内存淘汰？

Redis 没有直接的命令手动触发淘汰。但可以通过 `MEMORY PURGE` 命令整理内存碎片，间接帮助释放内存。

### Q5：设置了过期时间的 key 还会被淘汰吗？

会！**过期时间和淘汰策略是两个独立机制**：
- **过期**：key 到达 TTL 后，通过惰性删除 + 定时删除来移除
- **淘汰**：内存不足时，根据策略主动删除 key（即使是未过期的）

如果一个 key 的 TTL 还未到，但内存不足了，它照样可能被淘汰。

---

## 七、总结

| 策略 | 淘汰标准 | 适用场景 | Redis 版本 |
|------|---------|---------|-----------|
| noeviction | 不淘汰 | 数据不可丢失 | 所有 |
| allkeys-lru | 近似 LRU | 通用缓存 ★ | 2.0+ |
| allkeys-lfu | 对数频率 | 热数据明显 | 4.0+ |
| volatile-lru | 近似 LRU | 部分数据需持久 | 2.0+ |
| volatile-ttl | 过期时间 | 有时效的数据 | 2.0+ |
| volatile-random | 随机 | 均匀访问 | 2.0+ |
| allkeys-random | 随机 | 均匀访问 | 2.0+ |

Redis 内存淘汰策略的选择直接影响缓存的**命中率和系统稳定性**。理解和选择正确的策略，是 Redis 生产化运维的重要基本功。

建议：**默认 allkeys-lru，采样数 10，定期监控 evicted_keys。** 如果发现数据颠簸，再考虑切换到 LFU 或优化 `lfu-log-factor`。
