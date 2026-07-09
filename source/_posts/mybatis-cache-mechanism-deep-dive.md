---
title: 【面试必备】MyBatis 缓存机制深度解析：一级缓存、二级缓存与自定义缓存的源码级分析
date: 2026-07-09 08:00:00
tags:
  - MyBatis
  - 缓存
  - 面试
  - 源码分析
categories:
  - Java
  - 持久层框架
author: 东哥
---

# 【面试必备】MyBatis 缓存机制深度解析：一级缓存、二级缓存与自定义缓存

## 一、MyBatis 缓存体系概览

MyBatis 内置了一个强大的缓存体系来减少数据库的查询压力，分为 **一级缓存（Local Cache）** 和 **二级缓存（Global Cache）**。

```
┌─────────────────────────────────────────────────┐
│               MyBatis 缓存体系                     │
├──────────────────────┬──────────────────────────┤
│    一级缓存（本地缓存） │     二级缓存（全局缓存）     │
│   SqlSession 级别     │    SqlSessionFactory 级别  │
│   默认开启，无法关闭    │   默认关闭，需手动开启      │
│   作用范围：单个会话    │   作用范围：全局共享        │
│   基于 PerpetualCache  │   基于 PerpetualCache +    │
│   (HashMap 实现)      │   装饰器链（可选 Redis）    │
└──────────────────────┴──────────────────────────┘
```

> **面试官：说说 MyBatis 的一级缓存和二级缓存有什么不同？**
>
> 答：一级缓存是 SqlSession 级别的，默认开启，同一个 SqlSession 中相同查询会直接返回缓存结果。二级缓存是 SqlSessionFactory 级别的，跨 SqlSession 共享，需要手动开启。

## 二、一级缓存深度剖析

### 2.1 缓存实现原理

一级缓存的实现类是 `PerpetualCache`，本质上就是一个 `HashMap`：

```java
// MyBatis 源码：PerpetualCache.java
public class PerpetualCache implements Cache {
    private final String id;
    private final Map<Object, Object> cache = new HashMap<>();
    
    @Override
    public void putObject(Object key, Object value) {
        cache.put(key, value);
    }
    
    @Override
    public Object getObject(Object key) {
        return cache.get(key);
    }
}
```

**缓存 Key 的生成机制：**

MyBatis 通过 `CacheKey` 类来生成缓存的 Key，包含以下要素：

```java
// MyBatis 源码：CacheKey.java（简化）
public class CacheKey implements Cloneable, Serializable {
    private static final int DEFAULT_MULTIPLYER = 37;
    private static final int DEFAULT_HASHCODE = 17;
    
    private int multiplier;
    private int hashcode;
    private long checksum;
    private int count;
    private List<Object> updateList;
    
    public CacheKey(Object... objects) {
        this.multiplier = DEFAULT_MULTIPLYER;
        this.hashcode = DEFAULT_HASHCODE;
        this.checksum = 0;
        this.count = 0;
        this.updateList = new ArrayList<>();
        // 对传入的所有参数进行 hash
        for (Object object : objects) {
            update(object);
        }
    }
    
    public void update(Object object) {
        int baseHashCode = object.hashCode();
        count++;
        checksum += baseHashCode;
        baseHashCode *= multiplier;
        hashcode = multiplier * hashcode + baseHashCode;
        updateList.add(object);
    }
    
    @Override
    public boolean equals(Object object) {
        if (this == object) return true;
        if (!(object instanceof CacheKey)) return false;
        
        CacheKey cacheKey = (CacheKey) object;
        if (hashcode != cacheKey.hashcode) return false;
        if (checksum != cacheKey.checksum) return false;
        if (count != cacheKey.count) return false;
        
        // 比较 updateList 中的每个元素
        for (int i = 0; i < updateList.size(); i++) {
            if (!this.updateList.get(i).equals(cacheKey.updateList.get(i)))
                return false;
        }
        return true;
    }
}
```

**影响 CacheKey 的因素：**
- MappedStatement ID（即 namespace + 方法名）
- 分页范围（RowBounds 的 offset 和 limit）
- SQL 语句本身
- 所有参数值
- 环境 ID（Environment）

### 2.2 一级缓存的生命周期

```java
// 一级缓存的作用域
SqlSession session = sqlSessionFactory.openSession();
try {
    User user1 = session.selectOne("selectUser", 1);  // 查询数据库，放入缓存
    User user2 = session.selectOne("selectUser", 1);  // 从缓存取，不查数据库
    assert user1 == user2;  // true，同一个对象引用
    
    user1.setName("NewName");
    User user3 = session.selectOne("selectUser", 1);  // 仍从缓存取
    System.out.println(user3.getName());  // "NewName" — 注意！缓存是对象引用
} finally {
    session.close();  // 一级缓存被清空
}
```

**一级缓存何时被清空？**

```java
// 1. 执行任何 insert/update/delete 操作后
User user = session.selectOne("selectUser", 1);  // 缓存
session.update("updateUser", newUser);  // 清空一级缓存！
User user2 = session.selectOne("selectUser", 1);  // 重新查询数据库

// 2. 手动调用 clearCache
session.clearCache();

// 3. 调用 commit/rollback/close
session.commit();    // 清空一级缓存
session.rollback();  // 清空一级缓存
session.close();     // 清空一级缓存
```

### 2.3 一级缓存的问题：脏读

**经典问题：** 不同 SqlSession 更新数据后，另一个 SqlSession 读到脏数据。

```java
// 场景：两个会话同时操作
SqlSession session1 = sqlSessionFactory.openSession();
SqlSession session2 = sqlSessionFactory.openSession();

User user = session1.selectOne("selectUser", 1);  // 查询，session1 缓存
session2.update("updateUser", updatedUser);       // 更新，事务提交
session2.commit();

// session1 仍持有旧缓存
User userAgain = session1.selectOne("selectUser", 1);  // 从缓存取！脏数据！
```

> **面试追问：怎么解决 MyBatis 一级缓存的脏读问题？**
>
> 答：1️⃣ 可以调用 `session.clearCache()` 手动清空；2️⃣ 使用 `sqlSessionFactory.openSession(true)` 开启自动提交（每次执行后清空缓存）；3️⃣ 但根本解决方案是使用二级缓存，并配置合适的刷新策略。

## 三、二级缓存深度剖析

### 3.1 开启二级缓存

```xml
<!-- MyBatis 全局配置 - 开启二级缓存 -->
<settings>
    <setting name="cacheEnabled" value="true"/>  <!-- 默认就是 true -->
</settings>
```

```xml
<!-- Mapper XML - 为某个命名空间开启二级缓存 -->
<mapper namespace="com.example.mapper.UserMapper">
    <cache 
        eviction="LRU"           <!-- 淘汰策略：LRU（默认）/ FIFO / SOFT / WEAK -->
        flushInterval="60000"    <!-- 刷新间隔（毫秒），默认不刷新 -->
        size="512"               <!-- 缓存引用数量，默认 1024 -->
        readOnly="true"          <!-- 是否只读，默认 false -->
        blocking="false"         <!-- 是否阻塞，默认 false -->
    />
</mapper>
```

```xml
<!-- 或通过 cache-ref 引用其他命名空间的缓存 -->
<cache-ref namespace="com.example.mapper.CommonMapper"/>
```

**用注解方式：**

```java
@CacheNamespace(
    eviction = LruCache.class,
    flushInterval = 60000,
    size = 512,
    readOnly = true,
    blocking = false
)
public interface UserMapper {
    // ...
}
```

### 3.2 二级缓存架构：装饰器模式

MyBatis 的二级缓存使用 **装饰器模式（Decorator Pattern）**，多个装饰器层层包裹：

```
SynchronizedCache       ← 装饰：线程安全同步
    ↓
LoggingCache            ← 装饰：缓存命中日志
    ↓
SerializedCache         ← 装饰：序列化反序列化（readOnly=false 时）
    ↓
ScheduledCache          ← 装饰：定时刷新
    ↓
LruCache / FifoCache    ← 装饰：淘汰策略
    ↓
SoftCache / WeakCache   ← 装饰：软引用/弱引用
    ↓
PerpetualCache          ← 核心：HashMap 存储
```

**核心源码：装饰器链的构建**

```java
// MyBatis 源码：CacheBuilder.java
public Cache build() {
    setDefaultImplementations();
    Cache cache = newBaseCacheInstance(implementation, id);
    cache = new PerpetualCache(id);  // 基础缓存
    // 设置大小
    cache = new LruCache(cache);     // 装饰 LRU 淘汰策略
    cache = new ScheduledCache(cache); // 装饰定时刷新
    cache = new SerializedCache(cache); // 装饰序列化
    cache = new LoggingCache(cache);   // 装饰日志
    cache = new SynchronizedCache(cache); // 装饰同步锁
    return cache;
}
```

### 3.3 二级缓存的读写流程

**写入流程（事务提交时）：**

```java
// 1. 执行查询时，结果先放入一级缓存
// 2. 提交事务时，一级缓存数据转移到二级缓存
// 源码：SqlSession 的 commit() → DefaultSqlSession.flushStatements()
// → Executor.commit() → CachingExecutor.flushCacheIfRequired(ms)
// → TransactionalCacheManager.commit()
```

**读取流程：**

```java
// CachingExecutor 的 query 方法（简化后的逻辑）
public <E> List<E> query(MappedStatement ms, Object parameterObject,
                          RowBounds rowBounds, ResultHandler resultHandler) throws SQLException {
    BoundSql boundSql = ms.getBoundSql(parameterObject);
    // 生成缓存 Key
    CacheKey key = createCacheKey(ms, parameterObject, rowBounds, boundSql);
    Cache cache = ms.getCache();  // 获取二级缓存实例
    
    if (cache != null) {
        // 尝试从二级缓存获取
        List<E> list = (List<E>) cache.getObject(key);
        if (list == null) {
            // 二级缓存未命中 → 查询数据库（先查一级缓存，再查数据库）
            list = delegate.query(ms, parameterObject, rowBounds, resultHandler, key, boundSql);
            // 存入二级缓存（但标记为待提交，事务提交时才真正写入）
            cache.putObject(key, list);
        }
    }
    return list;
}
```

### 3.4 二级缓存的关键配置解析

**readOnly vs readWrite 对比：**

| 配置 | 说明 | 性能 | 序列化 |
|------|------|------|-------|
| `readOnly=true` | 直接返回缓存对象的引用 | 快 | 不需要 |
| `readOnly=false`（默认） | 返回序列化后的副本 | 慢 | 需要实现 Serializable |

**readOnly=false 的问题：**
```java
// 缓存返回的是对象的副本，修改不影响缓存
List<User> cached = mapper.selectUser(1);
cached.get(0).setName("改了");  // 只改了副本，缓存不变
List<User> again = mapper.selectUser(1);  // 还是原来的值
```

**flushInterval 机制：**
```java
// ScheduledCache 源码
public class ScheduledCache implements Cache {
    private final Cache delegate;
    protected long lastClear;      // 上次清空时间
    protected long flushInterval;  // 清空间隔
    
    @Override
    public Object getObject(Object key) {
        // 检查是否到期
        if (flushInterval != 0 && System.currentTimeMillis() - lastClear > flushInterval) {
            clear();  // 清空缓存
        }
        return delegate.getObject(key);
    }
}
```

## 四、自定义缓存实现

当内置缓存无法满足需求时（如需要 Redis 分布式缓存），可以实现 `Cache` 接口：

```java
// 1. 实现 Cache 接口
public class RedisCache implements Cache {
    private final String id;
    private final JedisPool jedisPool;
    private static final int TTL = 3600;  // 1小时过期
    
    public RedisCache(String id) {
        this.id = id;
        this.jedisPool = new JedisPool("localhost", 6379);
    }
    
    @Override
    public String getId() {
        return id;
    }
    
    @Override
    public void putObject(Object key, Object value) {
        try (Jedis jedis = jedisPool.getResource()) {
            String keyStr = id + ":" + key.toString();
            byte[] valueBytes = SerializeUtil.serialize(value);  // 序列化
            jedis.setex(keyStr.getBytes(), TTL, valueBytes);
        }
    }
    
    @Override
    public Object getObject(Object key) {
        try (Jedis jedis = jedisPool.getResource()) {
            String keyStr = id + ":" + key.toString();
            byte[] valueBytes = jedis.get(keyStr.getBytes());
            return valueBytes != null ? SerializeUtil.deserialize(valueBytes) : null;
        }
    }
    
    @Override
    public Object removeObject(Object key) {
        try (Jedis jedis = jedisPool.getResource()) {
            String keyStr = id + ":" + key.toString();
            return jedis.del(keyStr.getBytes());
        }
    }
    
    @Override
    public void clear() {
        try (Jedis jedis = jedisPool.getResource()) {
            Set<String> keys = jedis.keys(id + ":*");
            if (!keys.isEmpty()) {
                jedis.del(keys.toArray(new String[0]));
            }
        }
    }
    
    @Override
    public int getSize() {
        try (Jedis jedis = jedisPool.getResource()) {
            return jedis.keys(id + ":*").size();
        }
    }
}

// 2. 在 Mapper 中配置自定义缓存
// <cache type="com.example.cache.RedisCache"/>
```

## 五、缓存集成与性能优化实践

### 5.1 整合 Redis 做二级缓存

```xml
<cache type="org.mybatis.caches.redis.RedisCache">
    <property name="redis.host" value="localhost"/>
    <property name="redis.port" value="6379"/>
    <property name="redis.password" value="xxx"/>
    <property name="redis.database" value="0"/>
</cache>
```

对于某些不需要缓存的查询，用 `useCache="false"` 禁用：

```xml
<select id="selectUserById" resultType="User" useCache="false">
    select * from user where id = #{id}
</select>
```

### 5.2 缓存的 flush / 脏读控制

```xml
<!-- 更新操作自动刷新相关缓存 -->
<update id="updateUser" flushCache="true" parameterType="User">
    update user set name = #{name} where id = #{id}
</update>

<!-- 查询操作清空一级缓存 -->
<select id="selectUser" resultType="User" flushCache="false">
    <!-- flushCache: true 清空一级缓存，false 不清空（默认 false） -->
    select * from user where id = #{id}
</select>
```

### 5.3 缓存最佳实践

| 场景 | 建议 |
|------|------|
| 低频更新、高频查询 | 推荐二级缓存 |
| 实时性要求高（如金融） | 关闭二级缓存 |
| 多表关联查询 | 注意脏读，设置 flush |
| 分布式环境 | 用 Redis 实现分布式缓存 |
| 大数据量 | 设置合理的 size，用 LRU 淘汰 |

## 六、源码分析：缓存执行链路

```
用户请求
    ↓
SqlSession.selectOne()
    ↓
DefaultSqlSession.selectList()
    ↓
CachingExecutor.query()          ← 二级缓存检查
    ├── hit  → 返回缓存
    └── miss → BaseExecutor.query()  ← 一级缓存检查
                ├── hit  → 返回缓存
                └── miss → doQuery() → 数据库查询
                            ↓
                          结果写入一级缓存
```

## 七、总结

**MyBatis 二级缓存的优缺点：**

**优点：**
- 减少数据库查询，提升系统性能
- 分布式环境下可扩展为 Redis 缓存
- 配置灵活，支持多种淘汰策略

**缺点：**
- 脏读问题（不同 namespace 操作同一张表）
- 序列化开销（readOnly=false 时）
- 内存占用（大数据量）
- 调试困难（缓存的数据可能与数据库不一致）

**最后建议：** 个人不推荐过度依赖 MyBatis 的二级缓存。对于高并发系统，建议在应用层使用独立的缓存组件（如 Redis、Caffeine）来实现更细粒度的缓存控制，MyBatis 缓存更多作为辅助。
