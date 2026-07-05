---
title: Spring Boot 集成 Redis 深度实战：RedisTemplate、序列化、Pipeline 与 Lua 脚本
date: 2026-07-05 08:00:00
tags:
  - Java
  - Spring Boot
  - Redis
  - 数据库
categories:
  - Java
  - 中间件
author: 东哥
---

# Spring Boot 集成 Redis 深度实战：RedisTemplate、序列化、Pipeline 与 Lua 脚本

## 一、引言

Redis 在 Java 后端几乎是标配：缓存、分布式锁、计数器、排行榜、消息队列……但很多项目对 Redis 的用法停留在 `opsForValue().set()` / `opsForValue().get()` 的层面，对底层序列化机制、Pipeline 批处理、Lua 脚本原子性等进阶用法缺乏了解。

本文从 Spring Boot 集成 Redis 开始，逐步深入 RedisTemplate 的核心原理和 Redis 在 Spring 生态中的高级用法。

**面试官开场就问**："你们项目里 Redis 用的 Spring Data Redis 还是 Jedis？RedisTemplate 的序列化是怎么配的？遇到过什么问题吗？"

## 二、Spring Boot Redis 核心配置

### 2.1 依赖与基础配置

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
<!-- 连接池依赖 -->
<dependency>
    <groupId>org.apache.commons</groupId>
    <artifactId>commons-pool2</artifactId>
</dependency>
```

```yaml
spring:
  data:
    redis:
      host: localhost
      port: 6379
      password: 
      database: 0
      timeout: 3000ms
      lettuce:
        pool:
          max-active: 16    # 连接池最大连接数
          max-idle: 8       # 连接池最大空闲连接
          min-idle: 4       # 连接池最小空闲连接
          max-wait: -1ms    # 获取连接最大等待时间（-1 无限制）
```

### 2.2 Lettuce vs Jedis：默认客户端的进化

| 特性 | Jedis | Lettuce（Spring Boot 2.x 默认） |
|------|-------|------|
| 连接模式 | 阻塞 I/O | 基于 Netty 的 NIO |
| 线程安全 | ❌ 不安全（需连接池） | ✅ 线程安全（可共享连接） |
| 连接复用 | 单连接，非线程安全 | 多路复用，一个连接多个线程 |
| 异步/响应式 | ❌ | ✅ 支持 Redis Reactive |
| 集群支持 | 需额外配置 | 内置集群、哨兵、主从 |
| 性能（高并发） | 连接池模式较好 | 连接复用模式更好 |

**Lettuce 的线程模型**：使用 Netty 的 EventLoop 处理 I/O，单个连接可被多个线程共享，底层通过 Command 队列和 Pipeline 机制实现多路复用。

## 三、RedisTemplate 序列化机制详解

### 3.1 为什么要关注序列化？

```java
redisTemplate.opsForValue().set("key", new User("东哥", 28));
User user = (User) redisTemplate.opsForValue().get("key");
```

这段代码能正常工作，原因是 RedisTemplate 默认使用 **JDK 序列化**。但实际项目中，JDK 序列化存在严重问题：

| 问题 | 说明 |
|------|------|
| 可读性差 | Redis 中看到的是 `\xac\xed\x00\x05t\x00\x03key` 乱码 |
| 体积大 | JDK 序列化二进制体积是 JSON 的 3~5 倍 |
| 兼容性差 | 类结构变更后无法反序列化 |
| 性能差 | 序列化/反序列化速度远低于 JSON |

### 3.2 建议的序列化配置

```java
@Configuration
public class RedisConfig {

    @Bean
    public RedisTemplate<String, Object> redisTemplate(RedisConnectionFactory factory) {
        RedisTemplate<String, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(factory);

        // ★ 核心：使用 JSON 序列化替换 JDK 序列化
        Jackson2JsonRedisSerializer<Object> jsonSerializer = 
            new Jackson2JsonRedisSerializer<>(Object.class);
        
        ObjectMapper om = new ObjectMapper();
        om.setVisibility(PropertyAccessor.ALL, JsonAutoDetect.Visibility.ANY);
        om.activateDefaultTyping(
            ObjectMapper.DefaultTyping.NON_FINAL, 
            JsonTypeInfo.As.PROPERTY);
        om.setDateFormat(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"));
        jsonSerializer.setObjectMapper(om);

        // String 序列化（key 使用）
        StringRedisSerializer stringSerializer = new StringRedisSerializer();

        // key 和 hashKey 用 String 序列化
        template.setKeySerializer(stringSerializer);
        template.setHashKeySerializer(stringSerializer);
        // value 和 hashValue 用 JSON 序列化
        template.setValueSerializer(jsonSerializer);
        template.setHashValueSerializer(jsonSerializer);

        template.afterPropertiesSet();
        return template;
    }
}
```

**配置生效后的表现**：

```bash
# 之前
redis> GET user:1001
"\xac\xed\x00\x05t\x00\x03..."

# 之后
redis> GET user:1001
"{\"@class\":\"com.example.User\",\"name\":\"东哥\",\"age\":28}"
```

### 3.3 专用 StringRedisTemplate

对于纯字符串操作，使用 `StringRedisTemplate`，它的 key 和 value 都使用 String 序列化，性能更好：

```java
@Autowired
private StringRedisTemplate stringRedisTemplate;

// 适合：缓存 JSON 字符串、计数器、验证码等
stringRedisTemplate.opsForValue().set("captcha:phone:138xxxx", "123456", 5, TimeUnit.MINUTES);
```

## 四、Pipeline 管道批量操作

### 4.1 为什么需要 Pipeline？

网络开销是 Redis 操作的主要瓶颈。发送一条命令 → 等待响应 → 发送下一条，RTT（Round Trip Time）累积起来非常可观。

**Pipeline 将多条命令打包，一次性发送，一次性接收响应**：

```
无 Pipeline：
  client → SET k1 v1 → server → OK → client
  client → SET k2 v2 → server → OK → client  
  client → SET k3 v3 → server → OK → client
  3次 RTT

有 Pipeline：
  client → SET k1 v1 / SET k2 v2 / SET k3 v3 → server → OK / OK / OK → client
  1次 RTT
```

### 4.2 Pipeline 实战

```java
// ★ 批量写入 10000 条数据
@Autowired
private RedisTemplate<String, Object> redisTemplate;

public void batchWrite(List<User> users) {
    long start = System.currentTimeMillis();
    
    redisTemplate.executePipelined((RedisCallback<Object>) connection -> {
        for (User user : users) {
            String key = "user:" + user.getId();
            // 使用 byte[] 操作避免序列化干扰
            byte[] value = JSON.toJSONString(user).getBytes(StandardCharsets.UTF_8);
            connection.stringCommands().set(
                key.getBytes(StandardCharsets.UTF_8), value);
        }
        return null;  // 不关心返回值
    });
    
    long end = System.currentTimeMillis();
    System.out.println("Pipeline 写入 " + users.size() + " 条耗时: " + (end - start) + "ms");
}
```

**性能对比**（10000 条写入，本地 Redis）：

| 方式 | 耗时 | 提升倍数 |
|------|------|---------|
| 逐条写入 | ~3800ms | 1x |
| Pipeline 批量 | ~120ms | ~31x |
| Pipeline + 连接复用 | ~90ms | ~42x |

### 4.3 Pipeline 的注意事项

1. **Pipeline 不支持读取依赖前一条结果的操作**（无法在 Pipeline 中先 GET 再基于结果 SET）
2. **Pipeline 返回的 list 顺序与命令顺序一致**
3. **Pipeline 占用连接时间较长，注意连接池配置**
4. **Pipeline 不是原子操作**——如果中间某条命令出错，其他命令仍然执行

## 五、Lua 脚本：原子性与复杂逻辑

### 5.1 Lua 脚本的优势

```java
// 不安全的操作（竞态条件）
Integer count = redisTemplate.opsForValue().get("stock:1001");
if (count != null && count > 0) {
    redisTemplate.opsForValue().decrement("stock:1001");
}
```

这段代码有竞态条件——两个线程同时读到 count=1，都执行 decrement，库存变负。

**使用 Lua 脚本将"检查+扣减"合并为原子操作**：

```lua
-- stock_decrement.lua
-- KEYS[1]: 库存键名, ARGV[1]: 扣减数量
local stock = redis.call('GET', KEYS[1])
if not stock or tonumber(stock) < tonumber(ARGV[1]) then
    return 0  -- 库存不足
end
redis.call('DECRBY', KEYS[1], ARGV[1])
return 1  -- 扣减成功
```

Spring Boot 中调用：

```java
@Autowired
private RedisTemplate<String, Object> redisTemplate;

public boolean decrementStock(String key, int delta) {
    DefaultRedisScript<Long> script = new DefaultRedisScript<>();
    script.setScriptText(
        "local stock = redis.call('GET', KEYS[1])\n" +
        "if not stock or tonumber(stock) < tonumber(ARGV[1]) then\n" +
        "    return 0\n" +
        "end\n" +
        "redis.call('DECRBY', KEYS[1], ARGV[1])\n" +
        "return 1"
    );
    script.setResultType(Long.class);
    
    Long result = redisTemplate.execute(script, 
        Collections.singletonList(key), delta);
    return Long.valueOf(1).equals(result);
}
```

### 5.2 Lua 脚本典型场景

| 场景 | Lua 逻辑 | 替代方案 |
|------|---------|---------|
| 库存扣减 | GET → 检查 → DECRBY | 分布式锁（性能差） |
| 限量抢购 | GET → 检查上限 → INCR | TX 事务（复杂） |
| 限流器 | GET 计数 → 检查阈值 → INCR | RedisCell 模块 |
| 原子续约 | GET → 检查归属 → EXPIRE | 多条命令（非原子） |
| 排行榜更新 | ZINCRBY → ZREMRANGEBYRANK | 多条命令（非原子） |

### 5.3 Lua 脚本性能与最佳实践

**性能数据**（10万次扣库存操作）：

| 方案 | 耗时 | 原子性 |
|------|------|--------|
| GET + IF + DECR（非原子） | ~300ms | ❌ |
| 分布式锁 + GET + DECR | ~3200ms | ✅ |
| Lua 脚本 | ~280ms | ✅ |
| Pipeline + Lua | ~95ms | ✅ |

**最佳实践**：

```java
// ★ 从文件加载 Lua 脚本（推荐）
@Component
public class RedisScriptRegistry {
    
    private static final Map<String, DefaultRedisScript<?>> SCRIPTS = new HashMap<>();
    
    @PostConstruct
    public void init() {
        SCRIPTS.put("stock_decrement", loadScript("lua/stock_decrement.lua", Long.class));
        SCRIPTS.put("rate_limiter", loadScript("lua/rate_limiter.lua", Long.class));
        SCRIPTS.put("distributed_lock", loadScript("lua/distributed_lock.lua", Boolean.class));
    }
    
    @SuppressWarnings("unchecked")
    public <T> DefaultRedisScript<T> get(String name) {
        return (DefaultRedisScript<T>) SCRIPTS.get(name);
    }
    
    private <T> DefaultRedisScript<T> loadScript(String path, Class<T> resultType) {
        DefaultRedisScript<T> script = new DefaultRedisScript<>();
        script.setScriptSource(new ResourceScriptSource(
            new ClassPathResource(path)));
        script.setResultType(resultType);
        return script;
    }
}
```

Lua 脚本文件 `lua/distributed_lock.lua`：

```lua
-- 分布式锁：SET NX + 超时 + 原子释放
-- KEYS[1]: 锁 key
-- ARGV[1]: 请求 ID（唯一标识）
-- ARGV[2]: 超时时间（秒）

-- 加锁
if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'EX', ARGV[2]) then
    return true
end

-- 锁重入检查（相同请求 ID）
if redis.call('GET', KEYS[1]) == ARGV[1] then
    redis.call('EXPIRE', KEYS[1], ARGV[2])
    return true
end

return false
```

## 六、Spring Cache + Redis 集成

### 6.1 零侵入缓存

```java
@EnableCaching  // 开启缓存注解
@Configuration
public class CacheConfig {
    
    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory factory) {
        RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(30))           // 默认 30 分钟
            .serializeKeysWith(
                RedisSerializationContext.SerializationPair.fromSerializer(
                    new StringRedisSerializer()))
            .serializeValuesWith(
                RedisSerializationContext.SerializationPair.fromSerializer(
                    new GenericJackson2JsonRedisSerializer()))
            .disableCachingNullValues();                // 不缓存 null
            
        return RedisCacheManager.builder(factory)
            .cacheDefaults(config)
            .withCacheConfiguration("long-term",         // 不同缓存策略
                RedisCacheConfiguration.defaultCacheConfig()
                    .entryTtl(Duration.ofHours(2)))
            .withCacheConfiguration("short-term",
                RedisCacheConfiguration.defaultCacheConfig()
                    .entryTtl(Duration.ofMinutes(5)))
            .build();
    }
}
```

### 6.2 使用示例

```java
@Service
public class UserService {
    
    @Cacheable(value = "users", key = "#id", unless = "#result == null")
    public User getUserById(Long id) {
        // 第一次调用查数据库，之后走缓存
        return userMapper.selectById(id);
    }
    
    @CachePut(value = "users", key = "#user.id")
    public User updateUser(User user) {
        userMapper.updateById(user);
        return user;
    }
    
    @CacheEvict(value = "users", key = "#id")
    public void deleteUser(Long id) {
        userMapper.deleteById(id);
    }
}
```

## 七、面试高频题

### Q1：RedisTemplate 的默认序列化方式是什么？有什么问题？

> 默认是 JdkSerializationRedisSerializer（JDK 序列化）。问题是：二进制不可读、体积大（JSON 的 3~5 倍）、类结构变更后无法反序列化、序列化性能差。

### Q2：Lettuce 和 Jedis 如何选择？

> Lettuce 是 Spring Boot 2.x 默认客户端，基于 Netty NIO，线程安全，支持异步/响应式，适合高并发。Jedis 是阻塞 I/O，线程不安全，需要连接池管理，适合简单场景。Spring Boot 3.x 默认也是 Lettuce。

### Q3：Pipeline 和事务有什么区别？

> Pipeline 只保证批量发送，不保证原子性（中间一条失败其他照常执行）。MULTI/EXEC 事务保证原子性（全部执行或全部不执行），但会阻塞其他客户端。Pipeline 的性能提升来自减少 RTT，事务来自隔离性。两者可以结合使用。

### Q4：Lua 脚本为什么能保证原子性？

> Redis 使用同一个 Lua 解释器串行执行脚本，脚本执行期间不会插入其他命令，所以 Lua 脚本中的所有操作是原子的。这类似于 MULTI/EXEC 事务的原子性保证。

### Q5：Spring Cache 的 @Cacheable 在 Redis 中 key 是什么格式？

> 默认格式为 `cache_name::key`，例如 `users::1001`。可以通过 `cacheManager` 配置自定义 key 前缀和序列化。

## 八、总结

Spring Boot 集成 Redis 看似简单，但要在生产环境用好，需要关注：

1. **序列化**：用 JSON 替代 JDK 序列化，提高可读性和性能
2. **连接管理**：Lettuce 连接池配置要合理，max-active 建议为核心数的 2~4 倍
3. **Pipeline**：批处理场景减少 RTT，性能提升数十倍
4. **Lua 脚本**：复杂逻辑的原子性保证，解决竞态条件问题
5. **Spring Cache 注解**：零侵入缓存，配合 Redis 实现声明式缓存管理

掌握了这些，Redis 就不只是"缓存"那么简单了——它可以是一个高性能的分布式计算平台。
