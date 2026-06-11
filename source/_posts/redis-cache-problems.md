---
title: Redis 缓存常见问题与解决方案实战
date: 2026-06-11 14:00:00
tags: [Redis, 缓存, 缓存穿透, 缓存击穿, 缓存雪崩, 分布式锁]
categories: 中间件
---

## 前言

缓存是提升系统性能最有效的手段之一，但用不好也可能带来灾难性后果。**缓存穿透、缓存击穿、缓存雪崩**是面试中的"三座大山"，更是生产环境中的高频故障。

本文将从原理、场景、解决方案三个维度，结合代码实战，彻底讲清楚这些问题。

---

## 一、缓存穿透

### 1.1 什么是缓存穿透？

> **缓存穿透**指查询一个**不存在的数据**。由于缓存中也没有，请求直接打到数据库，导致数据库压力激增。

```
用户请求 → 查缓存（不存在）→ 查数据库（也不存在）→ 返回空
                                   ↑
                             恶意攻击者不断请求不存在的 ID，数据库被打爆
```

### 1.2 解决方案

#### 方案一：缓存空值（简单有效）

```java
public User getUserById(Long id) {
    // 1. 查缓存
    String cacheKey = "user:" + id;
    Object cacheData = redis.get(cacheKey);
    
    if (cacheData != null) {
        // 缓存命中
        return (User) cacheData;
    }
    
    // 2. 缓存未命中，查数据库
    User user = userMapper.selectById(id);
    
    // 3. 处理空值缓存
    if (user == null) {
        // 缓存空值，TTL 设置短一些（30~60秒）
        redis.set(cacheKey, "NULL_VALUE", 30);
        return null;
    }
    
    // 4. 写入缓存
    redis.set(cacheKey, user, 3600);
    return user;
}
```

#### 方案二：布隆过滤器（更优解）

布隆过滤器在缓存之前再加一层过滤，判断 key 是否存在：

```
用户请求 → 布隆过滤器（key 不存在则拦截）→ 查缓存 → 查数据库
                   ↓ (过滤掉无效请求)
               直接返回
```

```java
@Component
public class BloomFilterHelper {
    
    private static final int EXPECTED_INSERTIONS = 100_0000;  // 预估数据量
    private static final double FPP = 0.01;                    // 误判率 1%
    
    private final RedisTemplate<String, Object> redisTemplate;
    private final UserMapper userMapper;
    
    @PostConstruct
    public void initBloomFilter() {
        // 启动时加载所有用户 ID 到布隆过滤器
        List<Long> allIds = userMapper.selectAllIds();
        // 构建布隆过滤器（可以用 Redisson 或 Guava + Redis Bitmap）
        RBloomFilter<Long> bloomFilter = redisson.getBloomFilter("userBloomFilter");
        bloomFilter.tryInit(EXPECTED_INSERTIONS, FPP);
        allIds.forEach(bloomFilter::add);
    }
    
    public User getUserById(Long id) {
        // 布隆过滤器拦截
        RBloomFilter<Long> bloomFilter = redisson.getBloomFilter("userBloomFilter");
        if (!bloomFilter.contains(id)) {
            // 肯定不存在，直接返回，避免穿透
            return null;
        }
        // 后面正常走缓存 + 数据库
        // ...
    }
}
```

> **布隆过滤器特点：** 说不存在一定不存在，说存在不一定存在（有误判率）。

#### 方案三：参数校验拦截

```java
public User getUserById(Long id) {
    // 基础参数校验，过滤非法 ID
    if (id == null || id <= 0) {
        throw new IllegalArgumentException("参数非法");
    }
    // ...
}
```

---

## 二、缓存击穿

### 2.1 什么是缓存击穿？

> **缓存击穿**指某个**热点 key** 在缓存过期的瞬间，大量并发请求同时打到数据库。

```
时间线：
t1: key 在缓存中，请求正常走缓存
t2: key 过期（缓存失效）
t3: 大量请求同时发现缓存无数据 → 全部打到数据库
t4: 数据库压力爆增，可能导致雪崩
```

### 2.2 解决方案

#### 方案一：互斥锁（Mutex Lock）

只让一个线程去查数据库重建缓存，其他线程等待或返回旧数据。

```java
public User getUserById(Long id) {
    String cacheKey = "user:" + id;
    
    // 1. 查缓存
    User user = redis.get(cacheKey);
    if (user != null) {
        return user;
    }
    
    // 2. 缓存未命中，加锁
    String lockKey = "lock:user:" + id;
    String requestId = UUID.randomUUID().toString();
    boolean locked = redis.setNx(lockKey, requestId, 10, TimeUnit.SECONDS);
    
    if (locked) {
        try {
            // 3. 拿到锁，再次查缓存（双重检测）
            user = redis.get(cacheKey);
            if (user != null) {
                return user;
            }
            
            // 4. 查数据库
            user = userMapper.selectById(id);
            if (user != null) {
                redis.set(cacheKey, user, 3600);
            } else {
                redis.set(cacheKey, "NULL_VALUE", 30);
            }
            return user;
        } finally {
            // 释放锁（Lua 脚本保证原子性）
            releaseLock(lockKey, requestId);
        }
    } else {
        // 5. 未拿到锁，等待后重试
        Thread.sleep(50);
        return getUserById(id);  // 递归重试
    }
}
```

#### 方案二：逻辑过期（不设置 TTL）

不给缓存设置实际的过期时间，而是在 value 中保存一个**逻辑过期时间戳**，通过后台线程异步更新。

```java
public class CacheItem<T> {
    private T data;
    private long expireTime;  // 逻辑过期时间
}

public T getData(String key, Class<T> type, Runnable reloadTask) {
    CacheItem<T> cacheItem = redis.get(key);
    
    if (cacheItem == null) {
        // 缓存不存在，同步加载
        reloadTask.run();
        return null;
    }
    
    if (cacheItem.getExpireTime() > System.currentTimeMillis()) {
        // 逻辑未过期，直接返回
        return cacheItem.getData();
    }
    
    // 逻辑已过期：先返回旧数据，异步更新缓存
    String lockKey = "lock:" + key;
    boolean locked = redis.setNx(lockKey, "1", 3, TimeUnit.SECONDS);
    
    if (locked) {
        // 异步线程更新缓存
        threadPool.execute(reloadTask);
    }
    
    // 不管是否拿到锁，都返回旧数据
    return cacheItem.getData();
}
```

**优势：** 返回旧数据，绝不阻塞，对用户体验友好。

#### 方案三：永不过期 + 定时更新

对于极端热点数据，不设置过期时间，通过后台定时任务定期刷新缓存。

```java
@Component
public class HotKeyRefresher {
    
    @PostConstruct
    public void init() {
        // 定时刷新热门商品缓存（每 10 分钟）
        ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(5);
        scheduler.scheduleAtFixedRate(() -> {
            List<Long> hotProductIds = getHotProductIds();
            for (Long id : hotProductIds) {
                Product product = productMapper.selectById(id);
                redis.set("product:" + id, product);
            }
        }, 0, 10, TimeUnit.MINUTES);
    }
}
```

---

## 三、缓存雪崩

### 3.1 什么是缓存雪崩？

> **缓存雪崩**指大量缓存 key 在同一时间集中过期，或者缓存服务宕机，所有请求直接打到数据库。

```
正常情况：      缓存层（挡掉 95%+ 请求）→ 数据库（少量请求）
雪崩时：      ❌ 缓存集体失效 → 数据库（承受全部请求）→ 数据库崩溃
```

### 3.2 解决方案

#### 方案一：过期时间加随机值

避免大量 key 在同一时间过期，给过期时间加一个随机偏移：

```java
// 设置缓存时，TTL 加上随机值
int baseTTL = 3600;                       // 基础过期时间 1 小时
int randomRange = new Random().nextInt(600);  // 随机 0~10 分钟
redis.set(key, value, baseTTL + randomRange);
```

#### 方案二：多级缓存

引入本地缓存作为第二道防线：

```java
@Component
public class MultiLevelCache {
    
    @Resource
    private RedisTemplate<String, Object> redisTemplate;
    
    // Guava 本地缓存
    private final Cache<String, Object> localCache = CacheBuilder.newBuilder()
            .maximumSize(10000)
            .expireAfterWrite(5, TimeUnit.MINUTES)
            .build();
    
    public Object get(String key) {
        // 1. 查本地缓存
        Object localData = localCache.getIfPresent(key);
        if (localData != null) {
            return localData;
        }
        
        // 2. 查 Redis
        Object redisData = redisTemplate.opsForValue().get(key);
        if (redisData != null) {
            localCache.put(key, redisData);  // 回填本地缓存
            return redisData;
        }
        
        // 3. 查数据库
        return loadFromDB(key);
    }
}
```

#### 方案三：缓存预热 + 加锁

系统上线前预先加载缓存，避免高并发时重建：

```java
@Component
public class CacheWarmUp implements CommandLineRunner {
    
    @Override
    public void run(String... args) {
        // 启动时预热热门数据
        List<Product> hotProducts = productMapper.selectHotProducts();
        hotProducts.forEach(p -> {
            redis.set("product:" + p.getId(), p, 3600 + new Random().nextInt(600));
        });
    }
}
```

#### 方案四：Redis 高可用

```yaml
# Redis 哨兵模式保证高可用
spring:
  redis:
    sentinel:
      master: mymaster
      nodes:
        - 192.168.1.10:26379
        - 192.168.1.11:26379
        - 192.168.1.12:26379
```

或者使用 Redis Cluster，避免单点故障。

---

## 四、三兄弟对比总结

| 问题 | 定义 | 原因 | 关键解决方案 |
|------|------|------|------------|
| **缓存穿透** | 查询不存在的数据 | 恶意攻击/非法请求 | 布隆过滤器、缓存空值、参数校验 |
| **缓存击穿** | 热 key 过期瞬间高并发 | 热点数据失效 + 高并发 | 互斥锁、逻辑过期、永不过期 |
| **缓存雪崩** | 大量 key 同时失效 | 缓存集体过期/宕机 | 随机 TTL、多级缓存、预热、高可用 |

## 五、其他常见缓存问题

### 5.1 缓存与数据库一致性

**最终一致性方案（推荐）：**

```
更新操作：
1. 更新数据库
2. 删除缓存（而不是更新缓存）
            ↓
下次读取时：发现缓存无数据 → 从数据库加载 → 写回缓存
```

> 为什么是删除缓存而不是更新缓存？因为更新操作频繁时，缓存被反复更新但很少被读取，浪费资源。而且并发写时，旧数据可能覆盖新数据。

### 5.2 Big Key 问题

单个 key 的 value 过大（比如上 MB），会导致：
- 网络传输瓶颈
- 操作阻塞（Redis 单线程，大 key 操作会阻塞其他命令）
- 内存不均匀分布（集群模式下）

**解决方案：**
- **拆分**：将大 key 拆成多个小 key
- **压缩**：对 value 进行压缩存储
- **分段读取**：用 `hscan`、`sscan` 分批读取

### 5.3 Hot Key 问题

某个 key 的访问量极高（比如双十一的秒杀商品）：

**解决方案：**
- **本地缓存**：客户端本地缓存热点 key
- **读写分离**：使用 Redis 从节点分担读压力
- **散列 key**：将一个 hot key 拆成多个副本（`product_1`、`product_2`...），让请求分散

---

## 六、总结

1. **缓存穿透** —— 防不存在的数据 ⇒ 布隆过滤器 + 空值缓存
2. **缓存击穿** —— 防单个热 key 失效 ⇒ 互斥锁 + 逻辑过期
3. **缓存雪崩** —— 防大量 key 同时失效 ⇒ 随机 TTL + 多级缓存 + 高可用
4. **核心原则**：让缓存挡住绝大多数请求，数据库做最后防线
5. **最佳实践**：组合使用多种策略，没有银弹

缓存用好了是性能利器，用砸了就是生产事故的导火索。理解这几类问题的本质，才能在架构设计中做到胸有成竹。
