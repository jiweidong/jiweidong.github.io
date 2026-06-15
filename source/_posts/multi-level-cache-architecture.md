---
title: 多级缓存架构设计：从本地缓存到分布式缓存的实战演进
date: 2026-06-15 23:30:00
tags:
  - 缓存
  - 架构设计
  - 高性能
  - Redis
categories:
  - 架构
author: 东哥
---

# 多级缓存架构设计：从本地缓存到分布式缓存的实战演进

> 缓存是提升系统性能最有效的手段之一。本文从单机缓存开始，逐步演进到多级缓存架构，深入分析每层缓存的选型、策略和最佳实践。

## 一、为什么需要多级缓存

### 1.1 缓存的层级

```
客户端缓存（浏览器/CDN）
    │ 加速：最快，命中即返回
    │ 成本：低
    ▼
本地缓存（Caffeine/Guava）
    │ 加速：毫秒级，无网络开销
    │ 成本：占用 JVM 堆内存
    ▼
分布式缓存（Redis）
    │ 加速：亚毫秒级，共享数据
    │ 成本：需要额外部署
    ▼
数据库（MySQL）
    │ 加速：基础存储
    │ 成本：最高
```

### 1.2 多级缓存的收益

| 场景 | 无缓存 | 单层 Redis | 多级缓存 |
|------|--------|------------|----------|
| 平均延迟 | 50ms | 5ms | < 1ms |
| QPS | 1000 | 50000 | 200000+ |
| 数据库压力 | 100% | 30% | 5% |
| 系统成本 | 低 | 中 | 中高 |

## 二、第一层：本地缓存（Caffeine）

### 2.1 Caffeine 基础使用

```java
// 声明式缓存
@Configuration
@EnableCaching
public class CacheConfig {
    
    @Bean
    public CacheManager caffeineCacheManager() {
        CaffeineCacheManager manager = new CaffeineCacheManager();
        manager.setCaffeine(Caffeine.newBuilder()
            .maximumSize(10_000)           // 最大条目数
            .expireAfterWrite(10, TimeUnit.MINUTES)  // 写入后过期
            .recordStats()                  // 记录统计信息
            .softValues());                 // 软引用（GC 可回收）
        return manager;
    }
}

// 使用缓存
@Service
public class UserService {
    
    @Cacheable(value = "users", key = "#userId", 
               unless = "#result == null")
    public User getUserById(Long userId) {
        return userMapper.selectById(userId);
    }
}
```

### 2.2 手动缓存操作

```java
@Component
public class LocalCacheManager {
    
    // 不同业务使用不同缓存配置
    private final Cache<Long, User> userCache = Caffeine.newBuilder()
        .maximumSize(50_000)
        .expireAfterWrite(5, TimeUnit.MINUTES)
        .refreshAfterWrite(1, TimeUnit.MINUTES)  // 自动刷新
        .build(key -> loadUserFromRedis(key));    // 缓存回源

    private final Cache<String, Product> productCache = Caffeine.newBuilder()
        .maximumSize(10_000)
        .expireAfterWrite(2, TimeUnit.MINUTES)
        .build();

    // 手动操作
    public User getUser(Long id) {
        return userCache.get(id, key -> {
            // 缓存未命中时加载
            return redisTemplate.opsForValue().get("user:" + key);
        });
    }

    public void invalidate(Long id) {
        userCache.invalidate(id);  // 主动失效
    }

    // 获取缓存统计
    public CacheStats getStats() {
        return userCache.stats();
    }
}
```

### 2.3 本地缓存注意事项

```java
// ❌ 本地缓存的常见问题

// 1. 数据一致性（集群环境）
// 服务 A 更新了用户数据，服务 B 本地缓存还是旧的
// → 解决方案：Redis Pub/Sub 广播失效消息

public void updateUser(User user) {
    userMapper.updateById(user);
    localCache.invalidate(user.getId());
    redisTemplate.convertAndSend("cache:invalidate", 
        "user:" + user.getId());  // 通知其他节点
}

// 2. 内存占用（避免缓存大对象）
// ❌ 缓存大对象
@Cacheable("orders")  
public List<Order> getUserOrders(Long userId) { ... }  // 可能很大

// ✅ 只缓存热点数据
@Cacheable("userBrief")
public UserBrief getUserBrief(Long userId) { ... }  // 轻量版本
```

## 三、第二层：分布式缓存（Redis）

### 3.1 Redis 缓存策略

```java
@Service
public class RedisCacheService {
    
    private final StringRedisTemplate redis;

    // 热点数据：不设置过期时间 + 主动更新
    public String getHotData(String key) {
        String value = redis.opsForValue().get(key);
        if (value == null) {
            // 双检锁防缓存击穿
            synchronized (key.intern()) {
                value = redis.opsForValue().get(key);
                if (value == null) {
                    value = loadFromDB(key);
                    redis.opsForValue().set(key, value);
                }
            }
        }
        return value;
    }

    // 普通数据：过期时间 + 被动失效
    public String getNormalData(String key) {
        String value = redis.opsForValue().get(key);
        if (value == null) {
            value = loadFromDB(key);
            if (value != null) {
                redis.opsForValue()
                    .set(key, value, 1, TimeUnit.HOURS);
            }
        }
        return value;
    }

    // 穿透防护：缓存空值
    public String getWithPenetrationProtection(String key) {
        String value = redis.opsForValue().get(key);
        if (value == null) {
            value = loadFromDB(key);
            if (value == null) {
                // 缓存空值，5 分钟过期
                redis.opsForValue()
                    .set(key, "NULL", 5, TimeUnit.MINUTES);
                return null;
            }
            redis.opsForValue().set(key, value, 1, TimeUnit.HOURS);
        }
        // 空值标记
        if ("NULL".equals(value)) {
            return null;
        }
        return value;
    }
}
```

### 3.2 缓存一致性方案

```java
// 方案一：Cache-Aside Pattern（旁路缓存）
public User getUser(Long id) {
    // 1. 先查缓存
    User user = cache.get(id);
    if (user != null) {
        return user;
    }
    
    // 2. 缓存未命中，查数据库
    user = db.selectById(id);
    
    // 3. 写入缓存
    if (user != null) {
        cache.set(id, user, 1, TimeUnit.HOURS);
    }
    return user;
}

// 方案二：延迟双删（更新数据时）
public void updateUser(User user) {
    // 1. 先删除缓存
    cache.delete(user.getId());
    
    // 2. 更新数据库
    db.updateById(user);
    
    // 3. 延迟再删一次（解决并发问题）
    scheduledExecutor.schedule(() -> {
        cache.delete(user.getId());
    }, 1, TimeUnit.SECONDS);
}
```

## 四、缓存穿透、击穿、雪崩

### 4.1 缓存穿透（查不存在的数据）

```
请求 → 缓存未命中 → 数据库查询 → 缓存空值
                              ↘ 恶意攻击：批量查不存在的 id
                                   → 数据库被打垮
```

**解决方案：**
```java
// 1. 缓存空值（已实现）
// 2. 布隆过滤器
@Component
public class BloomFilterCache {
    
    private final BloomFilter<Long> bloomFilter = 
        BloomFilter.create(Funnels.longFunnel(), 1000000, 0.01);
    
    @PostConstruct
    public void init() {
        // 预热：加载所有商品 ID
        List<Long> allIds = productDao.getAllIds();
        allIds.forEach(bloomFilter::put);
    }
    
    public Product getProduct(Long id) {
        // 布隆过滤器拦截
        if (!bloomFilter.mightContain(id)) {
            return null;  // 一定不存在
        }
        // 正常缓存逻辑
        return cache.get(id, key -> db.selectById(key));
    }
}
```

### 4.2 缓存击穿（热点 key 过期）

```java
// 解决方案：互斥锁
public String getHotProduct(Long id) {
    String key = "product:" + id;
    String value = redis.opsForValue().get(key);
    
    if (value == null) {
        // 尝试获取锁
        String lockKey = "lock:" + key;
        if (redis.opsForValue()
                .setIfAbsent(lockKey, "1", 3, TimeUnit.SECONDS)) {
            try {
                value = db.queryProduct(id);
                redis.opsForValue()
                    .set(key, value, 30, TimeUnit.MINUTES);
            } finally {
                redis.delete(lockKey);  // 释放锁
            }
        } else {
            // 没拿到锁，等待重试
            Thread.sleep(50);
            return getHotProduct(id);  // 递归重试
        }
    }
    return value;
}

// 解决方案：逻辑过期（不设置物理过期时间）
public String getWithLogicalExpire(String key) {
    CacheItem item = redis.opsForValue().get(key);
    if (item == null) {
        return null;
    }
    
    // 逻辑过期，异步更新
    if (item.isExpired()) {
        // 用锁控制只有一个线程去更新
        String lockKey = "lock:" + key;
        if (redis.opsForValue()
                .setIfAbsent(lockKey, "1", 1, TimeUnit.SECONDS)) {
            CompletableFuture.runAsync(() -> {
                String newValue = loadFromDB(key);
                redis.opsForValue().set(key, 
                    new CacheItem(newValue, 30, TimeUnit.MINUTES));
            });
        }
    }
    return item.getValue();  // 返回旧数据
}
```

### 4.3 缓存雪崩（大量缓存同时过期）

```yaml
# 解决方案
# 1. 过期时间加随机值
cache.set(key, value, baseExpire + random.nextInt(600), TimeUnit.SECONDS)

# 2. 多级缓存降级
#    Redis 挂了 → 本地缓存顶住
#    本地缓存也挂了 → 限流降级

# 3. 缓存预热 + 双 Key
# 主 Key：1 小时过期
# 备 Key：2 小时过期（提前 10 分钟开始加载）
```

## 五、缓存预热与更新

### 5.1 缓存预热

```java
@Component
public class CacheWarmUp {
    
    @PostConstruct
    @EventListener(ApplicationReadyEvent.class)
    public void warmUp() {
        log.info("开始缓存预热...");
        
        // 1. 预热热点商品
        List<Long> hotProductIds = getHotProductIds();
        hotProductIds.parallelStream().forEach(id -> {
            Product product = db.selectById(id);
            localCache.put(id, product);
            redis.opsForValue()
                .set("product:" + id, JSON.toJSONString(product), 
                     30, TimeUnit.MINUTES);
        });
        
        log.info("缓存预热完成，共 {} 条", hotProductIds.size());
    }
}
```

### 5.2 缓存更新策略

| 策略 | 适用场景 | 实现复杂度 |
|------|----------|------------|
| TTL 过期 | 一致性要求低 | 低 |
| 主动更新 | 数据变更频繁 | 中 |
| 定时刷新 | 数据不常变 | 低 |
| 消息通知 | 实时性要求高 | 高 |

## 六、多级缓存实战架构

### 6.1 完整实现

```java
@Service
public class MultiLevelCacheService {
    
    // 第一层：本地缓存（最快）
    private final Cache<Long, Product> localCache;
    // 第二层：分布式缓存
    private final RedisTemplate<String, String> redis;
    // 第三层：数据库
    private final ProductMapper db;
    
    private static final String CACHE_KEY_PREFIX = "product:";
    
    public Product getProduct(Long id, boolean allowLocal) {
        // Level 1: 本地缓存
        if (allowLocal) {
            Product local = localCache.getIfPresent(id);
            if (local != null) {
                return local;
            }
        }

        // Level 2: Redis 缓存
        String key = CACHE_KEY_PREFIX + id;
        String json = redis.opsForValue().get(key);
        if (json != null) {
            Product product = JSON.parseObject(json, Product.class);
            // 回填本地缓存
            if (allowLocal) {
                localCache.put(id, product);
            }
            return product;
        }

        // Level 3: 数据库（兜底）
        Product product = db.selectById(id);
        if (product != null) {
            // 回填 Redis
            redis.opsForValue().set(key, 
                JSON.toJSONString(product), 30, TimeUnit.MINUTES);
            // 回填本地缓存
            if (allowLocal) {
                localCache.put(id, product);
            }
        }
        return product;
    }
}
```

### 6.2 缓存分层决策

```java
// 什么数据放本地缓存？
// 1. 读多写少，如商品详情
// 2. 数据量小，如配置信息
// 3. 不要求强一致，如用户昵称

// 什么数据放 Redis？
// 1. 所有需要共享的数据
// 2. 需要设置 TTL 的数据
// 3. 需要分布式锁的场景

// 什么数据不缓存？
// 1. 实时性要求极高（如库存）
// 2. 频繁更新的数据
// 3. 大对象（如文件流）
```

## 七、总结

多级缓存架构是高性能系统的基石。设计时需要在一致性、性能、成本之间找到平衡点：

1. **由近到远**：优先查本地缓存，再查 Redis，最后查数据库
2. **分级保护**：每层都是上一层的事故缓冲
3. **一致性取舍**：不是所有数据都需要强一致
4. **监控告警**：缓存命中率是核心指标，低于 90% 需要排查

最后记住：**缓存不是银弹，但正确的缓存架构能让你撑住 10 倍的流量。**
