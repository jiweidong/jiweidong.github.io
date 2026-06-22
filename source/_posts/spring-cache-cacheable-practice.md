---
title: Spring Cache 缓存抽象 @Cacheable 实战与原理
date: 2026-06-22 08:40:00
tags:
  - Java
  - Spring
  - 缓存
  - Redis
categories:
  - Java
  - Spring生态
author: 东哥
---

# Spring Cache 缓存抽象 @Cacheable 实战与原理

## 一、为什么需要缓存抽象？

在项目中，缓存需求无处不在：
- 热点数据缓存（配置、字典、用户信息）
- 接口防重复查询
- 数据库查询结果缓存

如果每个模块都自己写缓存逻辑，代码会变成这样：

```java
// ❌ 手动缓存管理——重复代码爆炸
public User getUserById(Long id) {
    // 1. 查缓存
    String key = "user:" + id;
    String json = redisTemplate.opsForValue().get(key);
    if (json != null) {
        return JSON.parseObject(json, User.class);
    }
    // 2. 查数据库
    User user = userMapper.selectById(id);
    // 3. 写缓存
    if (user != null) {
        redisTemplate.opsForValue().set(key, JSON.toJSONString(user), 30, TimeUnit.MINUTES);
    }
    return user;
}
```

**Spring Cache 抽象** 用注解解决了这个问题——一行注解搞定缓存读写：

```java
@Cacheable(value = "user", key = "#id")
public User getUserById(Long id) {
    return userMapper.selectById(id);
}
```

## 二、快速入门

### 2.1 依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-cache</artifactId>
</dependency>
```

### 2.2 启用缓存

```java
@Configuration
@EnableCaching  // 开启缓存
public class CacheConfig {
}
```

### 2.3 配置缓存实现

**方案一：使用 Caffeine（本地缓存，推荐）**

```xml
<dependency>
    <groupId>com.github.ben-manes.caffeine</groupId>
    <artifactId>caffeine</artifactId>
</dependency>
```

```java
@Configuration
@EnableCaching
public class CacheConfig {
    
    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager manager = new CaffeineCacheManager();
        // 默认配置
        manager.setCaffeine(Caffeine.newBuilder()
            .initialCapacity(100)
            .maximumSize(500)
            .expireAfterWrite(30, TimeUnit.MINUTES));
        return manager;
    }
}
```

**方案二：使用 Redis（分布式缓存）**

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

```java
@Configuration
@EnableCaching
public class RedisCacheConfig {
    
    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory factory) {
        RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(30))           // 默认过期时间
            .serializeKeysWith(
                RedisSerializationContext.SerializationPair.fromSerializer(
                    new StringRedisSerializer()))
            .serializeValuesWith(
                RedisSerializationContext.SerializationPair.fromSerializer(
                    new GenericJackson2JsonRedisSerializer()))
            .disableCachingNullValues();                 // 不缓存空值
            
        return RedisCacheManager.builder(factory)
            .cacheDefaults(config)
            .withInitialCacheConfigurations(Map.of(
                "user", RedisCacheConfiguration.defaultCacheConfig().entryTtl(Duration.ofHours(1)),
                "config", RedisCacheConfiguration.defaultCacheConfig().entryTtl(Duration.ofDays(1))
            ))
            .build();
    }
}
```

### 2.4 业务中使用

```java
@Service
public class UserService {
    
    @Cacheable(value = "user", key = "#id")
    public User getUserById(Long id) {
        slowQuery(); // 模拟慢查询
        return userMapper.selectById(id);
    }
    
    @CachePut(value = "user", key = "#user.id")
    public User updateUser(User user) {
        userMapper.updateById(user);
        return user;
    }
    
    @CacheEvict(value = "user", key = "#id")
    public void deleteUser(Long id) {
        userMapper.deleteById(id);
    }
}
```

## 三、核心注解详解

### 3.1 @Cacheable — 缓存读取

```java
@Cacheable(
    value = "user",          // 缓存分区名（类似表名）
    key = "#id",             // 缓存的 key（SpEL 表达式）
    unless = "#result == null",  // 条件：结果为 null 时不缓存
    condition = "#id > 0",   // 条件：id > 0 时才走缓存逻辑
    sync = true              // 同步锁，防止缓存击穿
)
public User getUserById(Long id) {
    return userMapper.selectById(id);
}
```

| 属性 | 作用 | 示例 |
|------|------|------|
| `value/cacheNames` | 缓存分区名 | `"user"`, `{"user", "userCache"}` |
| `key` | 缓存 key（SpEL） | `#id`, `#user.id`, `#root.methodName` |
| `keyGenerator` | 自定义 Key 生成器 | `@Cacheable(keyGenerator = "myKeyGenerator")` |
| `condition` | 条件满足才缓存 | `#id % 2 == 0`（只缓存偶数 ID） |
| `unless` | 条件满足不缓存 | `#result == null`（空值不缓存） |
| `sync` | 同步锁（防缓存击穿） | `sync = true` |

### 3.2 @CachePut — 缓存更新

始终执行方法并更新缓存，适用于更新操作：

```java
@CachePut(value = "user", key = "#user.id")
public User updateUser(User user) {
    userMapper.updateById(user);
    return user;  // 返回值会写入缓存
}
```

### 3.3 @CacheEvict — 缓存清除

```java
// 清除单个缓存
@CacheEvict(value = "user", key = "#id")
public void deleteUser(Long id) { ... }

// 清除整个分区所有缓存
@CacheEvict(value = "user", allEntries = true)
public void clearUserCache() { ... }

// 在方法执行前清除（默认是执行后）
@CacheEvict(value = "user", beforeInvocation = true)
public void clearBefore() { ... }
```

### 3.4 @Caching — 组合注解

```java
@Caching(
    put = {
        @CachePut(value = "user", key = "#user.id"),
        @CachePut(value = "user", key = "#user.username")
    },
    evict = {
        @CacheEvict(value = "userList", allEntries = true)
    }
)
public User saveUser(User user) {
    userMapper.insert(user);
    return user;
}
```

### 3.5 @CacheConfig — 类级别配置

```java
@Service
@CacheConfig(cacheNames = "user", cacheManager = "redisCacheManager")
public class UserService {
    
    @Cacheable(key = "#id")
    public User getById(Long id) { ... }
    
    @CachePut(key = "#user.id")
    public User update(User user) { ... }
    
    @CacheEvict(key = "#id")
    public void delete(Long id) { ... }
}
```

## 四、SpEL 表达式参考

| 表达式 | 描述 | 示例 |
|--------|------|------|
| `#root.methodName` | 方法名 | `getUserById` |
| `#root.method.name` | 方法对象名 | `getUserById` |
| `#root.target` | 目标对象 | — |
| `#root.targetClass` | 目标类 | `com.example.UserService` |
| `#root.args[0]` | 第一个参数 | 等同 `#id` |
| `#root.caches[0].name` | 缓存名称 | `user` |
| `#argumentName` | 参数名 | `#id`, `#user` |
| `#result` | 返回值（unless 中可用） | `#result?.id` |

## 五、缓存穿透/击穿/雪崩应对

### 5.1 缓存穿透（查不存在的数据）

```java
@Cacheable(value = "user", key = "#id", unless = "#result == null")
// ❌ 问题：null 不缓存，每次查询都穿透到 DB

@Cacheable(value = "user", key = "#id")
// ✅ 解决：缓存 null 值
// 但需要设置较短的过期时间
```

配置层解决：

```java
// Redis 配置：缓存空值
.disableCachingNullValues()  // 默认不缓存 null

// 也可以用 Caffeine 的写法直接缓存 null
```

### 5.2 缓存击穿（热点 key 过期）

```java
@Cacheable(value = "hot", key = "#id", sync = true)
// ✅ sync = true 开启本地锁，只允许一个线程查数据库
public HotData getHotData(Long id) { ... }
```

### 5.3 缓存雪崩（大量 key 同一时间过期）

```java
// 方案一：设置随机过期时间
RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig()
    .entryTtl(Duration.ofSeconds(1800 + new Random().nextInt(600)));
    // 30 分钟 ± 5 分钟随机偏移

// 方案二：多级缓存（本地 + 分布式）
```

## 六、多级缓存实现

**本地缓存 + Redis 组成多级缓存**，兼顾速度和一致性：

```java
@Configuration
@EnableCaching
public class MultiLevelCacheConfig {
    
    @Primary
    @Bean
    public CacheManager multiLevelCacheManager(
            RedisCacheManager redisCacheManager,
            CaffeineCacheManager caffeineCacheManager) {
        return new CacheManager() {
            @Override
            public Cache getCache(String name) {
                return new MultiLevelCache(
                    caffeineCacheManager.getCache(name),   // L1: 本地缓存
                    redisCacheManager.getCache(name)       // L2: 分布式缓存
                );
            }
            
            @Override
            public Collection<String> getCacheNames() {
                return Set.of("user", "config");
            }
        };
    }
}
```

```java
public class MultiLevelCache implements Cache {
    private final Cache l1;
    private final Cache l2;
    
    @Override
    public ValueWrapper get(Object key) {
        // 先查 L1
        ValueWrapper wrapper = l1.get(key);
        if (wrapper != null) return wrapper;
        
        // L1 没有查 L2
        wrapper = l2.get(key);
        if (wrapper != null) {
            l1.put(key, wrapper.get());  // 回填 L1
        }
        return wrapper;
    }
    
    @Override
    public void put(Object key, Object value) {
        l1.put(key, value);
        l2.put(key, value);
    }
    
    @Override
    public void evict(Object key) {
        l1.evict(key);
        l2.evict(key);
    }
    
    // ... 其他方法实现
}
```

## 七、自定义 KeyGenerator

```java
@Component("customKeyGenerator")
public class CustomKeyGenerator implements KeyGenerator {
    @Override
    public Object generate(Object target, Method method, Object... params) {
        StringBuilder sb = new StringBuilder();
        sb.append(target.getClass().getSimpleName());
        sb.append(":").append(method.getName());
        for (Object param : params) {
            sb.append(":").append(param);
        }
        return sb.toString();
    }
}

// 使用
@Cacheable(value = "user", keyGenerator = "customKeyGenerator")
public User findUser(Long id, String type) {
    // key = "UserService:findUser:1:admin"
}
```

## 八、缓存失效策略

```java
@Configuration
public class CacheInvalidationConfig {
    
    // 手动清除缓存的工具类
    @Component
    public static class CacheEvictHelper {
        
        private final CacheManager cacheManager;
        
        public CacheEvictHelper(CacheManager cacheManager) {
            this.cacheManager = cacheManager;
        }
        
        // 按前缀批量清除
        public void evictByPrefix(String cacheName, String keyPrefix) {
            Cache cache = cacheManager.getCache(cacheName);
            if (cache instanceof RedisCache redisCache) {
                // Redis 需要 scan 批量删除
                redisCache.clear();
            }
        }
        
        // 事件驱动缓存失效
        @EventListener
        public void handleUserUpdate(UserUpdateEvent event) {
            Cache cache = cacheManager.getCache("user");
            if (cache != null) {
                cache.evict(event.getUserId());
            }
        }
    }
}
```

## 九、性能对比

| 实现 | 速度 | 分布式 | 持久化 | 管理界面 | 适用场景 |
|------|------|--------|--------|----------|----------|
| **Caffeine** | ⭐⭐⭐⭐⭐ | ❌ | ❌ | ❌ | 单机、高并发、只读缓存 |
| **Redis** | ⭐⭐⭐⭐ | ✅ | ✅ | ✅ | 分布式、一致性要求高 |
| **Ehcache** | ⭐⭐⭐⭐ | ✅（Terracotta） | ✅ | ✅ | 企业级、需要持久化 |
| **Simple** | ⭐⭐ | ❌ | ❌ | ❌ | 测试环境 |

## 十、最佳实践总结

### 使用规范

1. **缓存命名要有规律** — `业务:模块:标识`，如 `user:profile:123`
2. **统一过期时间策略** — 热点数据短过期，配置类长过期
3. **警惕缓存与数据库一致性问题** — 先写 DB 再删缓存（Cache Aside Pattern）
4. **给缓存加容量限制** — 避免内存 OOM

### 避免的陷阱

```java
// ❌ 在类内部方法调用，缓存注解失效
@Cacheable(value = "user", key = "#id")
public User getById(Long id) { ... }

public void processUser(Long id) {
    // 内部调用：缓存注解不生效！
    User user = getById(id);  // ❌ 不会走缓存
}

// ✅ 方案一：注入自身
@Autowired
private UserService self;  // 循环依赖警告 ⚠️

// ✅ 方案二：提取到另一个 Service
// ✅ 方案三：使用 AopContext
((UserService) AopContext.currentProxy()).getById(id);
```

**原因：** Spring Cache 基于 AOP 代理实现，类内部调用不走代理，注解不生效。

### 总结

Spring Cache 抽象通过 `@Cacheable` / `@CachePut` / `@CacheEvict` 三个注解，覆盖了缓存读、写、删三个核心操作。配合不同的底层实现（Caffeine/Redis/Ehcache），可以灵活应对从单机到分布式的各种缓存场景。

**核心原则：先用缓存抽象减少模板代码，再用配置调优满足性能需求。**
