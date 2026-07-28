---
title: 【缓存实战】EhCache 与 JCache（JSR 107）缓存规范深度实战：从入门到集群
date: 2026-07-28 08:00:00
tags:
  - Java
  - EhCache
  - JCache
  - 缓存
categories:
  - Java
  - 性能优化
author: 东哥
---

# 【缓存实战】EhCache 与 JCache（JSR 107）缓存规范深度实战：从入门到集群

## 一、EhCache 是什么？为什么还在用它？

在 Caffeine 大行其道的今天，EhCache 似乎有些「过气」。但实际上，EhCache 依然在许多场景中不可替代：

| 特性 | EhCache 3.x | Caffeine | Redis |
|------|-------------|----------|-------|
| JCache (JSR 107) 兼容 | ✅ 原生支持 | ❌ 需适配 | ❌ |
| 磁盘持久化 | ✅ | ❌ | 本身已持久化 |
| 集群缓存 | ✅ (Terracotta/RMI/JGroups) | ❌ | 本身就支持 |
| 堆外内存 | ✅ | ❌ | 不适用 |
| Spring Boot 集成 | ✅ 自动配置 | ✅ 自动配置 | ✅ |
| 分布式事务 | ✅ 支持 XA | ❌ | ❌ |

**EhCache 最适合的场景**：
- 本地缓存需要突破堆内存限制（堆外内存/磁盘）
- 需要 JCache 标准 API 兼容
- 小型集群需要分布式缓存但不想引入 Redis
- 需要持久化缓存的离线处理

## 二、JCache（JSR 107）标准

### 2.1 核心 API

JCache（JSR 107）定义了 Java 缓存的标准 API：

```java
// 核心接口：CacheManager、Cache、Entry
CacheManager manager = Caching.getCachingProvider()
    .getCacheManager();
    
MutableConfiguration<String, User> config = new MutableConfiguration<>()
    .setTypes(String.class, User.class)
    .setExpiryPolicyFactory(
        CreatedExpiryPolicy.factoryOf(Duration.ONE_HOUR))
    .setStoreByValue(false);  // 引用存储 vs 值复制

Cache<String, User> cache = manager.createCache("users", config);

// 基础操作
cache.put("user:1001", new User(1001, "张三"));
User user = cache.get("user:1001");
cache.remove("user:1001");
```

### 2.2 EhCache 对 JCache 的实现

```xml
<!-- JCache 标准 API -->
<dependency>
    <groupId>javax.cache</groupId>
    <artifactId>cache-api</artifactId>
    <version>1.1.1</version>
</dependency>

<!-- EhCache 实现 -->
<dependency>
    <groupId>org.ehcache</groupId>
    <artifactId>ehcache</artifactId>
    <version>3.10.8</version>
</dependency>
```

**SPI 自动发现机制**：EhCache 实现了 `javax.cache.spi.CachingProvider`，放在 `META-INF/services/` 下供 JCache 自动加载。

```java
// 获取 EhCache 的 CachingProvider
CachingProvider provider = Caching.getCachingProvider();
// 默认使用 EhCache 实现（如果有多个实现可通过类名指定）
```

## 三、EhCache 3.x 深度配置

### 3.1 XML 配置

```xml
<!-- ehcache.xml -->
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xmlns="http://www.ehcache.org/v3"
        xsi:schemaLocation="http://www.ehcache.org/v3 
                            http://www.ehcache.org/schema/ehcache-core-3.0.xsd">
    
    <!-- 磁盘持久化路径 -->
    <persistence directory="/data/cache/ehcache" />
    
    <!-- 默认缓存模板 -->
    <cache-template name="default">
        <expiry>
            <ttl unit="seconds">3600</ttl>
        </expiry>
        <heap unit="entries">10000</heap>
    </cache-template>
    
    <!-- 用户缓存 -->
    <cache alias="users" uses-template="default">
        <key-type>java.lang.String</key-type>
        <value-type>com.example.User</value-type>
        <expiry>
            <ttl unit="seconds">1800</ttl>  <!-- 30 分钟 -->
        </expiry>
        <heap unit="entries">50000</heap>
        <offheap unit="MB">200</offheap>    <!-- 堆外内存 -->
        <disk persistent="true" unit="GB">1</disk>  <!-- 磁盘持久化 -->
    </cache>
    
    <!-- 令牌缓存（短 TTL） -->
    <cache alias="tokens" uses-template="default">
        <expiry>
            <ttl unit="seconds">300</ttl>  <!-- 5 分钟 -->
        </expiry>
        <heap unit="entries">100000</heap>
    </cache>
</config>
```

### 3.2 Java API 配置

```java
// 纯 Java 配置，无 XML
CacheManager cacheManager = CacheManagerBuilder.newCacheManagerBuilder()
    .with(CacheManagerBuilder.persistence("/data/cache/ehcache"))
    .withCache("users", CacheConfigurationBuilder
        .newCacheConfigurationBuilder(
            String.class, User.class,
            ResourcePoolsBuilder.newResourcePoolsBuilder()
                .heap(50000, EntryUnit.ENTRIES)  // 堆内存
                .offheap(200, MemoryUnit.MB)     // 堆外内存
                .disk(1, MemoryUnit.GB, true)    // 磁盘持久化
        )
        .withExpiry(ExpiryPolicyBuilder
            .timeToLiveExpiration(Duration.ofMinutes(30)))
        .withService(new DefaultCacheEventLogger()
            .setEventTypes(EnumSet.of(
                EventType.CREATED, EventType.EVICTED)))
    )
    .build(true);  // true = 初始化

Cache<String, User> cache = cacheManager.getCache("users", String.class, User.class);
```

### 3.3 Spring Boot 集成

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-cache</artifactId>
</dependency>
<dependency>
    <groupId>org.ehcache</groupId>
    <artifactId>ehcache</artifactId>
</dependency>
<dependency>
    <groupId>javax.cache</groupId>
    <artifactId>cache-api</artifactId>
</dependency>
```

```yaml
spring:
  cache:
    type: jcache          # 使用 JCache
    jcache:
      config: classpath:ehcache.xml
      provider: org.ehcache.jsr107.EhcacheCachingProvider
```

```java
@Service
public class UserService {
    
    // 使用 JCache 注解
    @CacheResult(cacheName = "users")
    public User getUserById(String userId) {
        // 模拟数据库查询
        return userRepository.findById(userId);
    }
    
    @CachePut(cacheName = "users")
    public User updateUser(User user) {
        userRepository.save(user);
        return user;
    }
    
    @CacheRemove(cacheName = "users")
    public void deleteUser(String userId) {
        userRepository.deleteById(userId);
    }
    
    @CacheRemoveAll(cacheName = "users")
    public void clearCache() {
        // 清空整个缓存
    }
}
```

## 四、三级存储架构详解

EhCache 最强大的特性是**三级存储架构**：

```
┌──────────────────┐  最快   容量小
│    Heap (堆内)   │  ≈ ns 级  有限
├──────────────────┤
│   Off-Heap (堆外) │  ≈ μs 级  较大
├──────────────────┤
│    Disk (磁盘)    │  ≈ ms 级  巨大
└──────────────────┘
```

### 4.1 堆内缓存（Heap）

```java
ResourcePoolsBuilder.newResourcePoolsBuilder()
    .heap(10000, EntryUnit.ENTRIES)    // 按条目数
    // 或
    .heap(256, MemoryUnit.MB)          // 按内存大小
```

- **优点**：访问速度最快（纳秒级），无序列化开销
- **缺点**：受 GC 影响，占堆内存
- **适用**：热点数据，数量可控

### 4.2 堆外缓存（Off-Heap）

```java
ResourcePoolsBuilder.newResourcePoolsBuilder()
    .heap(10000, EntryUnit.ENTRIES)
    .offheap(512, MemoryUnit.MB)       // 堆外 512MB
```

- **原理**：使用 `ByteBuffer.allocateDirect()` 分配堆外内存
- **优点**：不占用堆内存，不受 GC 影响
- **缺点**：需要序列化（对象→字节→对象），微秒级访问
- **适用**：大量缓存数据，减少 GC 压力

### 4.3 磁盘持久化

```java
PersistentCacheManager manager = CacheManagerBuilder.newCacheManagerBuilder()
    .with(CacheManagerBuilder.persistence("/var/cache"))
    .withCache("persistent-cache",
        CacheConfigurationBuilder.newCacheConfigurationBuilder(
            String.class, String.class,
            ResourcePoolsBuilder.newResourcePoolsBuilder()
                .heap(1000, EntryUnit.ENTRIES)
                .disk(10, MemoryUnit.GB, true)  // 1GB 磁盘
        ))
    .build(true);

// 关闭时持久化
manager.close();  // 数据写入磁盘
// 重启后数据恢复
```

**磁盘缓存性能对比**：

| 存储层级 | 延迟 | 吞吐量（读） | 吞吐量（写） |
|---------|------|------------|------------|
| Heap | 10-50 ns | 10M+ ops/s | 5M+ ops/s |
| Off-Heap | 1-5 μs | 500K ops/s | 200K ops/s |
| Disk (SSD) | 50-200 μs | 50K ops/s | 20K ops/s |

## 五、集群模式

### 5.1 Terracotta 集群

```xml
<!-- EhCache 集群配置 -->
<config xmlns="http://www.ehcache.org/v3">
    <!-- Terracotta 集群 -->
    <cluster>
        <connection url="terracotta://192.168.1.10:9410/my-application"/>
    </cluster>
    
    <cache alias="shared-cache">
        <key-type>java.lang.String</key-type>
        <value-type>java.lang.String</value-type>
        <expiry>
            <ttl unit="seconds">3600</ttl>
        </expiry>
        <heap unit="entries">10000</heap>
        <offheap unit="MB">100</offheap>
    </cache>
</config>
```

### 5.2 RMI 集群

```xml
<!-- 使用 RMI 进行缓存复制 -->
<cacheManagerPeerProviderFactory
    class="net.sf.ehcache.distribution.RMICacheManagerPeerProviderFactory"
    properties="peerDiscovery=automatic,
                multicastGroupAddress=230.0.0.1,
                multicastGroupPort=4446,
                timeToLive=255"
/>

<cache name="distributed-cache"
       maxEntriesLocalHeap="10000"
       eternal="false"
       timeToIdleSeconds="300"
       timeToLiveSeconds="600">
    <cacheEventListenerFactory
        class="net.sf.ehcache.distribution.RMICacheReplicatorFactory"
        properties="replicateAsynchronously=true,
                    replicatePuts=true,
                    replicateUpdates=true,
                    replicateUpdatesViaCopy=true,
                    replicateRemovals=true"/>
</cache>
```

## 六、EhCache 在 Spring Boot 中的性能优化

### 6.1 序列化配置

```xml
<cache alias="users">
    <key-type>java.lang.String</key-type>
    <value-type>com.example.User</value-type>
    <heap unit="entries">50000</heap>
    <offheap unit="MB">200</offheap>
    <!-- 使用 Kryo 序列化（比 JDK 快 10x） -->
    <serializer>
        <class>org.ehcache.impl.serialization.CompactJavaSerializer</class>
    </serializer>
</cache>
```

### 6.2 缓存统计与监控

```java
CacheManager manager = CacheManagerBuilder.newCacheManagerBuilder()
    .withCache("users", 
        CacheConfigurationBuilder.newCacheConfigurationBuilder(...),
        true)  // 启用统计
    .build(true);

Cache<String, User> cache = manager.getCache("users", String.class, User.class);

// 获取统计信息
CacheStatistics stats = cache.getRuntimeConfiguration()
    .getStatistics(StatisticsService.class);

System.out.println("命中率: " + stats.getCacheHitPercentage());
System.out.println("命中次数: " + stats.getCacheHits());
System.out.println("未命中次数: " + stats.getCacheMisses());
System.out.println("驱逐次数: " + stats.getCacheEvictions());
System.out.println("平均获取时间: " + stats.getAverageGetTime() + " ns");
```

### 6.3 缓存事件监听

```java
CacheConfiguration<String, User> config = CacheConfigurationBuilder
    .newCacheConfigurationBuilder(String.class, User.class, 
        ResourcePoolsBuilder.heap(10000))
    .add(new CacheEventListenerConfigurationBuilder() {
        @Override
        public Class<CacheEventListener> serviceType() {
            return CacheEventListener.class;
        }
    })
    .build();

// 自定义事件监听器
public class LoggingCacheEventListener 
        implements CacheEventListener<String, User> {
    
    @Override
    public void onEvent(CacheEvent<? extends String, ? extends User> event) {
        switch (event.getType()) {
            case CREATED:
                log.info("缓存添加: key={}", event.getKey());
                break;
            case EVICTED:
                log.warn("缓存驱逐: key={}, 原因={}", 
                    event.getKey(), event.getOldValue());
                break;
            case EXPIRED:
                log.info("缓存过期: key={}", event.getKey());
                break;
            case REMOVED:
                log.info("缓存删除: key={}", event.getKey());
                break;
        }
    }
}
```

## 七、EhCache vs Caffeine 选型对比

| 对比维度 | EhCache 3.x | Caffeine | 
|---------|-------------|----------|
| 性能（纯堆内） | 优秀 | ⭐ 极致（接近理论极限） |
| 堆外内存 | ✅ | ❌ |
| 磁盘持久化 | ✅ | ❌ |
| 集群支持 | ✅ Terracotta/RMI/JGroups | ❌ |
| JCache 标准 | ✅ 原生 | ❌ 需适配 |
| Spring Boot 自动配置 | ✅ | ✅ |
| 配置复杂度 | 中等 | 简单 |
| 学习成本 | 较高 | 低 |

**选型建议**：
- **纯本地缓存，追求极致性能** → Caffeine
- **需要持久化/堆外内存/集群** → EhCache
- **需要 JCache 标准兼容** → EhCache
- **Spring Boot 默认** → Caffeine（Spring Boot 1.x 默认 EhCache，2.x+ 默认 Caffeine）

## 八、面试常见追问

**Q：EhCache 的 Off-Heap 和 Direct Memory 有什么区别？**

A：EhCache 的 Off-Heap 实质就是使用 Java `ByteBuffer.allocateDirect()` 分配的 Direct Memory。优点是绕过堆内存，不受 Full GC 影响，适合存放大量长生命周期数据。但需要注意：1）Direct Memory 默认上限是 `-XX:MaxDirectMemorySize`；2）堆外缓存的读写需要序列化/反序列化，有额外 CPU 开销；3）堆外内存的释放依赖于 `Cleaner` 机制，使用不当可能导致 OOM。

**Q：EhCache 的磁盘持久化在应用重启后数据会恢复吗？**

A：会。EhCache 使用 `PersistentCacheManager` 时，数据在 `manager.close()` 时写入磁盘，重启调用 `manager.build(true)` 时自动从磁盘加载。恢复的数据放入已配置的资源池（heap + offheap），超出部分保留在磁盘上。注意使用 `disk(1, MemoryUnit.GB, true)` 第三个参数 `persistent=true` 启用 CRASH 级别的持久化（即使 JVM 崩溃也不丢失）。

**Q：EhCache 3.x 和 EhCache 2.x 有什么区别？**

A：EhCache 3.x 是重写版本：1）完全实现 JCache（JSR 107）标准；2）移除 Hibernate 缓存 SPI 的紧耦合；3）新的 API（`CacheManagerBuilder` 替代 `CacheManager.create`）；4）新的 XML Schema；5）Terracotta 集群升级到新协议。EhCache 2.x 在 Hibernate 社区仍有广泛使用，但新项目建议使用 3.x。

## 总结

EhCache 是 Java 领域最成熟的本地缓存框架之一，从堆内到堆外再到磁盘的三级存储架构让它能灵活应对各种场景。通过 JCache 标准整合，在 Spring Boot 中的配置和使用极为便捷。虽然 Caffeine 在纯堆内场景表现更优，但 EhCache 在持久化、堆外内存和集群方面的独特优势使其在企业应用中依然占有重要地位。
