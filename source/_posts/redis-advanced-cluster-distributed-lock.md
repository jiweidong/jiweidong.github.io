---
title: Redis 进阶：高可用集群与分布式锁实战
date: 2026-06-16 08:15:00
tags: [Redis, 集群, 分布式锁, 哨兵, Redisson]
categories: 中间件
---

# Redis 进阶：高可用集群与分布式锁实战

Redis 作为当前最流行的内存数据库，早已超越了单纯的缓存角色，在高可用架构、分布式锁、集群分片等方面发挥着关键作用。本文将从 Redis Sentinel 高可用架构、Redis Cluster 数据分片、分布式锁实现方案、缓存经典问题以及 Redis 7 新特性等五个方面，为你呈现 Redis 进阶实战的全景图谱。

<!-- more -->

## 一、Redis Sentinel：高可用架构

### 1.1 架构解析

Redis Sentinel 是官方提供的高可用解决方案，由一个或多个 Sentinel 实例组成的 Sentinel 系统，监视任意多个主服务器及其从服务器，在主服务器下线时自动完成故障转移。

```
┌─────────────────────────────────────────────────────────────┐
│                      Sentinel 集群                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │Sentinel 1│  │Sentinel 2│  │Sentinel 3│  │Sentinel N│    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       │             │            │            │             │
└───────┼─────────────┼────────────┼────────────┼─────────────┘
        │             │            │            │
        ▼             ▼            ▼            ▼
┌──────────────────────────────────────────────────────────────────┐
│                         Redis 实例层                              │
│                                                                  │
│   ┌──────────────┐           ┌──────────────┐                    │
│   │  Master      │◄─────────►│  Replica 1   │  ← 主从复制        │
│   │  (Active)    │           └──────────────┘                    │
│   └──────┬───────┘           ┌──────────────┐                    │
│          │                  │  Replica 2   │  ← 主从复制        │
│          │                  └──────────────┘                    │
│          │                  ┌──────────────┐                    │
│          └─────────────────►│  Replica N   │  ← 主从复制        │
│                             └──────────────┘                    │
│                                                                  │
│   ★ Master 下线时，Sentinel 选举新 Master                          │
│   ┌──────────────┐           ┌──────────────┐                    │
│   │  Master      │     ✗     │  Replica 1   │──► 提升为新 Master  │
│   │  (Down)      │           └──────────────┘                    │
│   └──────────────┘                                              │
└──────────────────────────────────────────────────────────────────┘
                     ┌──────────┐
                     │  Client  │─── 从 Sentinel 获取当前 Master 地址
                     └──────────┘
```

### 1.2 核心工作机制

Sentinel 通过三个关键机制保障高可用：

1. **心跳检测（Ping/Pong）**：Sentinel 每隔 1 秒向 Redis 实例发送 PING 命令，若在 `down-after-milliseconds` 内未收到响应，标记为主观下线（SDOWN）。

2. **Raft 共识选举**：当 Sentinel 集群中达到 `quorum` 数量的 Sentinel 都认为某主节点主观下线时，触发客观下线（ODOWN）。随后通过 Raft 算法选举领头 Sentinel 执行故障转移。

3. **故障转移**：领头 Sentinel 选择一个优先级最高（配置 `slave-priority`）、数据最完整的从节点升级为新的主节点，更新其他从节点指向新主，并通过发布/订阅通知客户端。

```bash
# Sentinel 配置示例
sentinel monitor mymaster 127.0.0.1 6379 2    # 2 个 Sentinel 同意即判定故障
sentinel down-after-milliseconds mymaster 5000 # 5 秒未响应判定下线
sentinel failover-timeout mymaster 30000       # 故障转移超时 30 秒
sentinel parallel-syncs mymaster 1            # 同时同步的新从节点数
```

### 1.3 Sentinel 的痛点

- 故障转移期间存在秒级不可用
- 主从复制异步，极端情况下可能丢数据
- 水平扩展困难，写能力受限于单主节点
- 资源利用率不高（大量从节点只读）

## 二、Redis Cluster：数据分片

### 2.1 分片原理：CRC16 与 Hash Slot

Redis Cluster 采用无中心化架构，每个节点都保存完整的集群元数据。数据分片基于 **CRC16 哈希算法** 和 **16384 个哈希槽（Hash Slot）**：

```
键的槽位 = CRC16(key) mod 16384
```

**哈希槽分配示例（3 主节点集群）：**

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Redis Cluster                              │
│                                                                     │
│   ┌───────────────┐    ┌───────────────┐    ┌───────────────┐       │
│   │  Node A       │    │  Node B       │    │  Node C       │       │
│   │  Slots 0-5460 │    │  Slots 5461-  │    │  Slots 10923- │       │
│   │               │    │  10922        │    │  16383        │       │
│   │  ┌─────────┐  │    │  ┌─────────┐  │    │  ┌─────────┐  │       │
│   │  │Replica A1│  │    │  │Replica B1│  │    │  │Replica C1│  │       │
│   │  └─────────┘  │    │  └─────────┘  │    │  └─────────┘  │       │
│   └───────────────┘    └───────────────┘    └───────────────┘       │
│                                                                     │
│        Key: user:1001 => Slot 4545 => Node A                         │
│        Key: session:abc => Slot 9182 => Node B                       │
│        Key: cart:xyz  => Slot 15023 => Node C                        │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 智能客户端与 MOVED 重定向

Redis Cluster 客户端使用集群模式连接，当客户端需要访问某个键时：

1. 客户端通过 CRC16 计算槽位
2. 查本地缓存的路由表找到对应节点
3. 直接连接该节点操作
4. 如果槽位已迁移到其他节点，节点返回 `MOVED` 错误，客户端更新路由表

```bash
# MOVED 重定向示例
redis-cli -c -p 6379     # -c 开启集群模式
> SET user:1001 "Alice"
-> Redirected to slot [4545] located at 192.168.1.10:6379
OK
> GET user:1001
"Alice"   # 后续请求自动路由到正确节点
```

### 2.3 集群搭建与扩缩容

**搭建 3 主 3 从集群：**

```bash
# 启动 6 个 Redis 实例（3 主 3 从）
redis-server redis_7000.conf --cluster-enabled yes
redis-server redis_7001.conf --cluster-enabled yes
# ... 启动 7002-7005

# 创建集群
redis-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 \
    127.0.0.1:7002 127.0.0.1:7003 127.0.0.1:7004 \
    127.0.0.1:7005 --cluster-replicas 1
```

**扩容：新增节点并迁移槽位：**

```bash
# 添加新节点
redis-cli --cluster add-node 127.0.0.1:7006 127.0.0.1:7000

# 分配槽位（从现有节点迁移 1000 个槽位到新节点）
redis-cli --cluster reshard 127.0.0.1:7000

# How many slots do you want to move? 1000
# What is the receiving node ID? <new_node_id>
# Source node #1: all
```

**缩容：迁移槽位后删除节点：**

```bash
# 先迁移出待删除节点的所有槽位
redis-cli --cluster reshard 127.0.0.1:7003 --cluster-from <node_to_remove_id> \
    --cluster-to <target_node_id> --cluster-slots <slot_count>

# 删除节点
redis-cli --cluster del-node 127.0.0.1:7003 <node_to_remove_id>
```

### 2.4 集群的限制与注意事项

- **不支持多键操作**：跨 slot 的 MGET、MSET 等操作需要 `hashtag` 保证键落在同一 slot
- **事务限制**：事务中的键必须在同一节点
- **Lua 脚本**：脚本中涉及的所有键必须在同一 slot
- **数据倾斜**：热点 key 可能导致单节点负载过高
- **网络开销**：节点间 Gossip 协议通信占用带宽

```bash
# 使用 hashtag 将相关键分配到同一 slot
SET user:1001:profile "{...}"
SET user:1001:orders "{...}"
# 用大括号标注 hashtag
SET {user:1001}:profile "{...}"
SET {user:1001}:orders "{...}"   # 两键均在 slot(user:1001) 上
```

## 三、分布式锁实现实战

### 3.1 使用 SETNX 实现基础分布式锁

```bash
# 加锁
SET lock_key unique_value NX PX 30000
# NX: 键不存在时设置，确保互斥
# PX 30000: 自动过期 30 秒，防止死锁
# unique_value: 唯一标识，确保只能由自己释放

# 释放锁（Lua 脚本保证原子性）
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else
    return 0
end
```

### 3.2 分布式锁方案对比

| 方案 | 原理 | 优点 | 缺点 | 适用场景 |
|-----|------|------|------|---------|
| **SETNX + Lua** | 单点 Redis，直接加锁 | 实现简单、性能极高 | 单点故障风险、无法防重入 | 非严格场景、单体架构 |
| **RedLock 算法** | N/2+1 个独立 Redis 节点 | 高可用、无单点故障 | 实现复杂、时钟依赖 | 严格互斥场景 |
| **Redisson** | 封装 RedLock + Watchdog | 开箱即用、自动续期 | 引入依赖、有学习成本 | 生产环境首选 |
| **ZooKeeper** | 临时顺序节点 + Watch | 强一致、无时钟问题 | 性能低于 Redis、重客户端 | 对一致性要求极为苛刻 |
| **Etcd** | Lease + Revision | 强一致、好用的 API | 性能不及 Redis | Kubernetes 生态 |

### 3.3 Redisson 实战代码

```java
// 引入 Redisson
<dependency>
    <groupId>org.redisson</groupId>
    <artifactId>redisson-spring-boot-starter</artifactId>
    <version>3.30.0</version>
</dependency>

@Configuration
public class RedissonConfig {
    @Bean
    public RedissonClient redissonClient() {
        Config config = new Config();
        config.useSingleServer()
            .setAddress("redis://127.0.0.1:6379")
            .setConnectionPoolSize(10);
        // 或使用集群模式
        // config.useClusterServers()
        //     .addNodeAddress("redis://127.0.0.1:7000", "redis://127.0.0.1:7001");
        return Redisson.create(config);
    }
}

// 业务使用
@Service
public class OrderService {
    @Autowired
    private RedissonClient redissonClient;

    public boolean createOrder(String orderId) {
        RLock lock = redissonClient.getLock("order:lock:" + orderId);
        try {
            // 尝试加锁，等待 3 秒，锁过期 30 秒（Watchdog 自动续期）
            if (lock.tryLock(3, 30, TimeUnit.SECONDS)) {
                // 执行业务逻辑
                return processOrder(orderId);
            }
            return false;  // 获取锁失败
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        } finally {
            if (lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }
}
```

**Redisson Watchdog 机制**：当加锁线程执行业务的时间超过锁的超时时间时，Watchdog 会每 10 秒自动续期一次，确保业务未完成时锁不会提前释放。这解决了 SETNX 方案中超时时间难以设定的痛点。

### 3.4 RedLock 算法

RedLock 算法由 Redis 作者 antirez 提出，通过 N 个独立的 Redis 节点（通常 N=5）实现高可用的分布式锁：

```java
// Redisson 中的 RedLock 实现
@Bean
public RedissonRedLock redLock() {
    RLock lock1 = redissonClient1.getLock("resource:lock");
    RLock lock2 = redissonClient2.getLock("resource:lock");
    RLock lock3 = redissonClient3.getLock("resource:lock");
    return new RedissonRedLock(lock1, lock2, lock3);
}

// 使用
boolean locked = redLock.tryLock(3, 30, TimeUnit.SECONDS);
```

**RedLock 原理**：
1. 客户端获取当前时间 T1
2. 依次向 N 个 Redis 节点申请锁，超时时间远小于锁过期时间
3. 统计成功获取锁的节点数 ≥ N/2 + 1
4. 计算获取锁耗时 = T2 - T1，若小于锁过期时间则加锁成功
5. 失败时向所有节点发送解锁请求

**RedLock 争议**：知名分布式系统专家 Martin Kleppmann 曾发文质疑 RedLock 的时钟假设问题。实践中建议：若对一致性要求极高，优先考虑 ZooKeeper/Etcd；若接受极小概率的竞态，则 Redisson 和 RedLock 完全够用。

## 四、缓存经典问题与解决方案

### 4.1 缓存穿透、击穿、雪崩

| 问题 | 描述 | 解决方案 | 实现方式 |
|-----|------|---------|---------|
| **缓存穿透** | 查询不存在的数据，缓存和数据库都没有 | 1. 布隆过滤器<br>2. 缓存空对象 | 布隆过滤器检验 key 是否存在；空值缓存短 TTL |
| **缓存击穿** | 热点 key 失效，高并发打到数据库 | 1. 互斥锁<br>2. 逻辑过期 | SETNX 加锁回源；后台异步更新缓存 |
| **缓存雪崩** | 大量 key 同一时间失效，大量请求打到 DB | 1. 随机 TTL<br>2. 缓存预热<br>3. 本地缓存 + 熔断 | TTL 加上随机值；提前加载热点数据 |

#### 布隆过滤器实现

```java
// 使用 Guava BloomFilter
BloomFilter<String> bloomFilter = BloomFilter.create(
    Funnels.stringFunnel(Charset.defaultCharset()),
    1_000_000,        // 预估元素数量
    0.01              // 误判率 1%
);

// 初始化时将有效 key 加入布隆过滤器
// 查询时先检查布隆过滤器
public Order getOrder(String orderId) {
    if (!bloomFilter.mightContain(orderId)) {
        return null;  // 布隆过滤器判断不存在，直接返回
    }
    // 查询缓存
    Order order = redisTemplate.opsForValue().get("order:" + orderId);
    if (order == null) {
        // 查询数据库
        order = orderMapper.selectById(orderId);
        if (order != null) {
            redisTemplate.opsForValue().set("order:" + orderId, order, 300, TimeUnit.SECONDS);
        } else {
            // 缓存空对象（短 TTL）
            redisTemplate.opsForValue().set("order:" + orderId, NULL_VALUE, 60, TimeUnit.SECONDS);
        }
    }
    return order;
}
```

#### 本地缓存 + 熔断兜底

```java
@Component
public class MultiLevelCacheService {
    @Autowired
    private RedissonClient redissonClient;

    // Caffeine 本地缓存作为一级缓存
    private final Cache<String, Object> localCache = Caffeine.newBuilder()
        .maximumSize(10000)
        .expireAfterWrite(5, TimeUnit.SECONDS)
        .build();

    public Object getWithMultiLevelCache(String key, CacheLoader loader) {
        // 1. 查本地缓存
        Object result = localCache.getIfPresent(key);
        if (result != null) return result;

        // 2. 查 Redis
        result = redisTemplate.opsForValue().get(key);
        if (result != null) {
            localCache.put(key, result);
            return result;
        }

        // 3. 查数据库（加锁防止击穿）
        RLock lock = redissonClient.getLock("cache:reload:" + key);
        if (lock.tryLock()) {
            try {
                // 双重检查
                result = redisTemplate.opsForValue().get(key);
                if (result != null) {
                    localCache.put(key, result);
                    return result;
                }
                result = loader.load();
                if (result != null) {
                    redisTemplate.opsForValue().set(key, result, 300, TimeUnit.SECONDS);
                    localCache.put(key, result);
                }
                return result;
            } finally {
                lock.unlock();
            }
        }

        // 4. 熔断兜底：短暂返回旧数据或降级
        return fallbackResult(key);
    }
}
```

## 五、Redis 7 新特性

### 5.1 Redis Functions

Redis 7 引入了 Redis Functions，作为 Lua 脚本的进化版，提供了更好的管理和部署体验：

- 函数级管理（FUNCTION LOAD / FUNCTION LIST / FUNCTION DELETE）
- 代码库化，多个函数共享代码
- 原子执行，与 EVAL 相同的原子性保证
- 可携带多个函数，按命名空间组织

```lua
# 加载 Redis Function
redis> FUNCTION LOAD "#!lua name=mylib\n redis.register_function('hgetall_del', function(keys, args) local val = redis.call('hgetall', keys[1]); redis.call('del', keys[1]); return val; end)"

# 调用函数
redis> FCALL hgetall_del 1 myhash
```

相比 Lua 脚本，Functions 的优势在于：可管理、可版本控制、集中部署。不再需要每次都发送完整的脚本内容。

### 5.2 Sharded Pub/Sub

Redis Cluster 在 7.0 之前不支持 Pub/Sub 的跨节点广播。使用普通的 PUBLISH/SUBSCRIBE 时，消息会在集群所有节点间广播，造成不必要的网络开销。

Redis 7 引入了 **Sharded Pub/Sub**（分片发布订阅）：
- 消息只在哈希槽所在的分片上传播
- 扩展性更好，消息不会广播到所有节点
- 适用于大规模集群环境

```bash
# Sharded Pub/Sub 命令
SSUBSCRIBE channel:orders    # 订阅分片频道
SPUBLISH channel:orders "order.created"  # 向分片频道发布消息
```

### 5.3 其他值得关注的特性

- **ACL v2 改进**：支持更细粒度的权限控制
- **Redis Stack**：整合 RedisJSON、RediSearch、RedisTimeSeries、RedisGraph 等模块
- **自动故障恢复优化**：Cluster 故障转移速度提升
- **Memory 命令优化**：更好的内存分析工具

## 六、总结

本文从 Sentinel 高可用架构、Cluster 数据分片、分布式锁实现方案、缓存经典问题解决方案到 Redis 7 新特性，全面覆盖了 Redis 进阶实战的核心知识。

生产环境中建议：
1. 小规模应用（< 10 节点）：选择 Sentinel 即可满足高可用需求
2. 大规模应用（> 10 节点或数据量超 100G）：优先使用 Cluster
3. 分布式锁：推荐 Redisson，高一致性场景考虑 ZooKeeper
4. Redis 版本：推荐升级到 7.x 获得 Functions 和 Sharded Pub/Sub 等新特性
5. 监控不可少：使用 RedisInsight 或 Grafana + Prometheus 进行全方位观测
