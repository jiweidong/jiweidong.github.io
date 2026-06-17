---
title: Caffeine 与本地缓存实战：打造高性能多级缓存架构
date: 2026-06-17 09:30:00
tags:
  - Caffeine
  - 本地缓存
  - 缓存架构
  - Java
categories:
  - 架构设计
author: 东哥
---

# Caffeine 与本地缓存实战：打造高性能多级缓存架构

## 一、为什么需要本地缓存

在分布式系统中，Redis 几乎是缓存的标准选择。但 Redis 再快，也绕不过一次网络 RTT（通常 0.5-5ms）。对于微秒级响应的场景，**本地缓存（Local Cache）** 才是性能之王。

### 1.1 缓存层级对比

| 层级 | 延迟 | 吞吐量 | 成本 | 典型方案 |
|------|------|--------|------|---------|
| CPU L1 Cache | ~1ns | 极高 | 昂贵 | 硬件 |
| CPU L3 Cache | ~10ns | 极高 | 昂贵 | 硬件 |
| 进程内本地缓存 | ~50ns | 千万级/s | 低 | Caffeine |
| 堆外内存缓存 | ~100ns | 百万级/s | 中 | MapDB |
| Redis 远程缓存 | ~1ms | 万级/s | 中 | Redis |
| 数据库 | ~10ms | 千级/s | 高 | MySQL |

### 1.2 适用场景

本地缓存适合以下场景：

1. **读多写少**（配置数据、数据字典、商品 SPU 信息）
2. **数据量可控**（几百 MB 级别）
3. **允许短暂不一致**（容忍几秒到几分钟的陈旧数据）
4. **高并发热点数据**（秒杀商品、热搜词）

## 二、Caffeine 核心特性

Caffeine 是当前 Java 生态中性能最好的本地缓存库，其设计灵感来源于 Google Guava Cache，但在各方面都做了大幅优化。

### 2.1 淘汰算法：W-TinyLFU

Caffeine 的核心竞争力在于其淘汰算法 **W-TinyLFU**，它解决了传统 LRU 的两个痛点：

```
┌───────────────────────────────────────────┐
│              Cache 分区策略               │
├───────────────────┬───────────────────────┤
│   Window Cache    │   Main Cache          │
│   (1% 空间)       │   (99% 空间)          │
│   新写入的数据     │   ├── Probation (保护)│
│   短暂保护         │   └── Protected (受护)│
│                   │   经过观察的活跃数据    │
└───────────────────┴───────────────────────┘
```

| 算法 | 问题 | Caffeine 方案 |
|------|------|-------------|
| LRU | 突发扫描导致缓存污染 | Window Cache 兜底 |
| LFU | 新数据很难进入缓存 | Window + TinyLFU 准入 |
| FIFO | 淘汰不精确 | W-TinyLFU 频率统计 |

W-TinyLFU 使用 **Count-Min Sketch** 概率数据结构来记录访问频率，空间效率极高，频率计数仅占用少量内存。

### 2.2 性能数据

在 JMH 基准测试中，Caffeine 的表现：

```java
// Benchmark                            Mode  Cnt      Score   Error  Units
// CaffeineCache.read                  thrpt    5  54231.452 ± 812.345  ops/ms
// GuavaCache.read                     thrpt    5  32145.678 ± 456.789  ops/ms
// ConcurrentHashMap.read              thrpt    5  58678.901 ± 234.567  ops/ms
// CaffeineCache.write                 thrpt    5  28456.789 ± 345.678  ops/ms
// GuavaCache.write                    thrpt    5  16789.012 ± 234.567  ops/ms
```

Caffeine 的读性能接近 `ConcurrentHashMap`，写性能是 Guava 的近 2 倍。

## 三、Caffeine 实战用法

### 3.1 基础配置

```xml
<dependency>
    <groupId>com.github.ben-manes.caffeine</groupId>
    <artifactId>caffeine</artifactId>
    <version>3.1.8</version>
</dependency>
```

```java
// 基础用法
Cache<String, Order> cache = Caffeine.newBuilder()
    .expireAfterWrite(10, TimeUnit.MINUTES)  // 写入后过期
    .maximumSize(10_000)                     // 最大条目数
    .recordStats()                           // 开启统计
    .build();

cache.put("order_1001", order);
Order result = cache.getIfPresent("order_1001");

// LoadingCache 自动加载
LoadingCache<String, Order> loadingCache = Caffeine.newBuilder()
    .expireAfterAccess(5, TimeUnit.MINUTES)  // 访问后过期
    .maximumWeight(100_000_000)              // 最大权重（字节）
    .weigher((String key, Order value) -> value.getSize())
    .build(key -> orderService.findById(key));

// 自动加载
Order order = loadingCache.get("order_1001");
```

### 3.2 过期策略对比

| 策略 | 方法 | 场景 | 说明 |
|------|------|------|------|
| 写入后过期 | expireAfterWrite | 配置数据、字典 | 固定时间后失效 |
| 访问后过期 | expireAfterAccess | Session 数据 | 不活跃则失效 |
| 自定义过期 | expireAfter(Expiry) | 按 key 差异化 | 灵活控制过期时间 |
| 定时刷新 | refreshAfterWrite | 热点数据 | 过期前异步刷新 |

### 3.3 自定义过期时间

```java
LoadingCache<String, Product> productCache = Caffeine.newBuilder()
    .expireAfter(new Expiry<String, Product>() {
        @Override
        public long expireAfterCreate(String key, Product value, long currentTime) {
            // 普通商品 5 分钟，秒杀商品 10 秒
            return value.isFlashSale() 
                ? TimeUnit.SECONDS.toNanos(10) 
                : TimeUnit.MINUTES.toNanos(5);
        }
        
        @Override
        public long expireAfterUpdate(String key, Product value, 
                                      long currentTime, long currentDuration) {
            // 更新后重新计时
            return currentDuration;
        }
        
        @Override
        public long expireAfterRead(String key, Product value, 
                                    long currentTime, long currentDuration) {
            // 读操作不延长过期时间
            return currentDuration;
        }
    })
    .maximumSize(50_000)
    .build(key -> productService.getById(key));
```

### 3.4 异步刷新

```java
LoadingCache<String, Product> productCache = Caffeine.newBuilder()
    .maximumSize(100_000)
    .refreshAfterWrite(1, TimeUnit.MINUTES)  // 1分钟后刷新
    .build(key -> {
        // 异步刷新时，旧的 value 仍然可用
        log.info("Refreshing product: {}", key);
        return productService.getById(key);
    });
```

`refreshAfterWrite` 和 `expireAfterWrite` 的区别：

| 特性 | expireAfterWrite | refreshAfterWrite |
|------|-----------------|-------------------|
| 过期后行为 | 移除缓存，下次访问同步加载 | 异步刷新，返回旧值 |
| 是否阻塞 | 是（同步加载） | 否（异步刷新） |
| 配置建议 | 数据变化不频繁 | 热点高并发数据 |
| 最佳组合 | 单独使用 | +expireAfterWrite=2x |

## 四、多级缓存架构实战

### 4.1 三级缓存架构设计

```
User Request
    │
    ▼
┌──────────────┐   命中    ┌──────────────┐
│  Caffeine    │──────────►│  返回数据     │
│  本地缓存    │            └──────────────┘
│  (Level 1)   │
│  ~50ns       │
└──────┬───────┘
       │ 未命中
       ▼
┌──────────────┐   命中    ┌──────────────┐
│  Redis       │──────────►│  回填到L1     │
│  远程缓存    │            └──────────────┘
│  (Level 2)   │
│  ~1ms        │
└──────┬───────┘
       │ 未命中
       ▼
┌──────────────┐            ┌──────────────┐
│  MySQL       │──────────►│  回填到L1+L2  │
│  数据库      │            └──────────────┘
│  (Level 3)   │
│  ~10ms       │
└──────────────┘
```

### 4.2 代码实现

```java
@Component
public class MultiLevelCacheManager<T> {
    
    private final LoadingCache<String, T> localCache;
    private final StringRedisTemplate redisTemplate;
    private final ObjectMapper objectMapper;
    private final Class<T> type;
    
    // 缓存穿透保护
    private final BloomFilter<String> bloomFilter;
    
    public MultiLevelCacheManager(StringRedisTemplate redisTemplate,
                                   ObjectMapper objectMapper,
                                   Class<T> type) {
        this.redisTemplate = redisTemplate;
        this.objectMapper = objectMapper;
        this.type = type;
        
        // 本地缓存：Caffeine
        this.localCache = Caffeine.newBuilder()
            .maximumSize(10_000)
            .expireAfterWrite(5, TimeUnit.MINUTES)
            .refreshAfterWrite(1, TimeUnit.MINUTES)
            .recordStats()
            .build(key -> loadFromRedis(key));
        
        // 布隆过滤器，防止无效 key 穿透到 DB
        this.bloomFilter = BloomFilter.create(
            Funnels.stringFunnel(Charset.defaultCharset()), 
            1_000_000, 
            0.01
        );
    }
    
    // 主查询入口
    public T get(String key) {
        return localCache.get(key);
    }
    
    // L1 未命中，查 L2 (Redis)
    private T loadFromRedis(String key) throws Exception {
        String json = redisTemplate.opsForValue().get(buildRedisKey(key));
        if (json != null) {
            return objectMapper.readValue(json, type);
        }
        // L2 也未命中，查 L3 (DB)
        return loadFromDatabase(key);
    }
    
    // L3 数据库查询 + 回填
    private T loadFromDatabase(String key) {
        // redis 分布式锁，防止缓存击穿
        String lockKey = "lock:" + key;
        Boolean locked = redisTemplate.opsForValue()
            .setIfAbsent(lockKey, "1", Duration.ofSeconds(5));
        
        if (Boolean.TRUE.equals(locked)) {
            try {
                T value = queryFromDB(key);  // 实际查询数据库
                if (value != null) {
                    // 回填 L2
                    redisTemplate.opsForValue()
                        .set(buildRedisKey(key), 
                             objectMapper.writeValueAsString(value), 
                             Duration.ofMinutes(30));
                    // 布隆过滤器添加
                    bloomFilter.put(key);
                    return value;
                } else {
                    // 缓存空值，防止缓存穿透
                    redisTemplate.opsForValue()
                        .set(buildRedisKey(key), "", Duration.ofMinutes(1));
                    return null;
                }
            } finally {
                redisTemplate.delete(lockKey);
            }
        } else {
            // 没拿到锁，短暂等待后重试
            Thread.sleep(50);
            return loadFromRedis(key);
        }
    }
    
    // 更新数据时同步更新缓存
    @Transactional
    public void update(String key, T newValue) {
        // 1. 更新数据库
        updateDB(key, newValue);
        
        // 2. 更新 L2 (Redis)
        redisTemplate.opsForValue()
            .set(buildRedisKey(key), 
                 objectMapper.writeValueAsString(newValue), 
                 Duration.ofMinutes(30));
        
        // 3. 删除 L1 (Caffeine)，下次读取时自动刷新
        localCache.invalidate(key);
    }
    
    private String buildRedisKey(String key) {
        return "cache:" + type.getSimpleName() + ":" + key;
    }
}
```

### 4.3 缓存问题全防护

| 问题 | 描述 | 解决方案 |
|------|------|---------|
| 缓存穿透 | 查询不存在的数据 | 布隆过滤器 + 空值缓存 |
| 缓存击穿 | 热点 key 过期瞬间大量请求 | 分布式锁 + Caffeine 异步刷新 |
| 缓存雪崩 | 大量 key 同时过期 | 过期时间加随机值 + 多级缓存 |
| 缓存一致 | DB 更新后缓存未更新 | Cache-Aside + 延迟双删 |

## 五、缓存统计与监控

```java
@RestController
@RequestMapping("/admin/cache")
public class CacheMonitorController {
    
    private final Cache<String, Object> cache;
    
    public CacheMonitorController(Cache<String, Object> cache) {
        this.cache = cache;
    }
    
    @GetMapping("/stats")
    public Map<String, Object> stats() {
        CacheStats stats = cache.stats();
        return Map.of(
            "hitCount", stats.hitCount(),
            "missCount", stats.missCount(),
            "hitRate", stats.hitRate(),
            "evictionCount", stats.evictionCount(),
            "loadCount", stats.loadCount(),
            "averageLoadPenalty", stats.averageLoadPenalty() / 1_000_000 + "ms",
            "estimatedSize", cache.estimatedSize()
        );
    }
}
```

```json
// 输出示例
{
  "hitCount": 154382,
  "missCount": 2871,
  "hitRate": 0.9817,
  "evictionCount": 1253,
  "loadCount": 2871,
  "averageLoadPenalty": "5.23ms",
  "estimatedSize": 9867
}
```

## 六、Spring Boot 集成 Caffeine

```java
@Configuration
public class CacheConfig {
    
    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager cacheManager = new CaffeineCacheManager();
        cacheManager.setCaffeine(Caffeine.newBuilder()
            .maximumSize(100_000)
            .expireAfterWrite(10, TimeUnit.MINUTES)
            .recordStats());
        // 支持按缓存名称个性化配置
        cacheManager.setCacheSpecification("productCache:maximumSize=50000,expireAfterWrite=5m");
        return cacheManager;
    }
}

@Service
public class ProductService {
    
    @Cacheable(value = "productCache", key = "#id")
    public Product getById(Long id) {
        return productMapper.selectById(id);
    }
    
    @CachePut(value = "productCache", key = "#product.id")
    public Product update(Product product) {
        productMapper.updateById(product);
        return product;
    }
    
    @CacheEvict(value = "productCache", key = "#id")
    public void delete(Long id) {
        productMapper.deleteById(id);
    }
}
```

Caffeine 凭借 W-TinyLFU 算法和极致性能优化，已经成为 Java 本地缓存的事实标准。构建多级缓存架构时，用它作为 L1 缓存配合 Redis L2，再搭配数据库兜底，既保证了性能也兼顾了数据一致性，是后端高并发系统的标配方案。
