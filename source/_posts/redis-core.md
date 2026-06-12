---
title: Redis 核心技术与实战（面试跳槽篇）
date: 2026-06-13 06:30:00
tags:
  - Redis
  - 缓存
  - 分布式锁
  - 持久化
  - 高可用
categories:
  - 中间件
author: 东哥
---

# Redis 核心技术与实战（面试跳槽篇）

> Redis 是后端面试的"必考点"，本文从底层原理到生产实战，全面覆盖 Redis 核心知识点。

## 一、Redis 基础

### 1.1 为什么这么快

Redis 单机 QPS 可达 10 万+，主要归功于以下几点：

**纯内存操作**：数据全在内存中，读写速度远快于磁盘 IO。内存寻址是纳秒级，而磁盘寻址是毫秒级，差了三个数量级。

**单线程模型**：Redis 6.0 之前，核心命令执行是单线程的。单线程避免了线程切换和锁竞争的开销。值得注意的是，"单线程"指的是网络 IO 和命令执行在同一个线程中串行处理，但持久化、异步删除等操作由后台线程完成。

**IO 多路复用（epoll）**：Redis 使用基于 epoll 的 IO 多路复用技术，单线程可以监听多个套接字。当有事件就绪时，才会处理该事件，避免了阻塞等待。epoll 相比 select/poll 的优势在于：没有最大连接数限制，使用红黑树管理 fd，通过事件回调避免轮询。

**高效的数据结构**：Redis 为每种数据类型设计了高效的底层编码，如压缩列表、跳表等。

### 1.2 五大核心数据结构

| 结构 | 底层编码 | 使用场景 |
|------|----------|----------|
| String | int/embstr/raw（SDS） | 缓存、计数器、分布式锁 |
| List | quicklist（ziplist + linkedlist） | 消息队列、最新列表 |
| Hash | ziplist / hashtable | 对象存储、购物车 |
| Set | intset / hashtable | 标签、去重、共同关注 |
| ZSet | ziplist / skiplist + hashtable | 排行榜、延时队列 |

**String 的 SDS（Simple Dynamic String）**：相比 C 语言字符串，SDS 有 O(1) 获取长度、二进制安全、预分配空间避免频繁扩容等优势。

**ZSet 的跳表**：ZSet 使用跳表 + 哈希表实现，跳表支持 O(logN) 的查找和范围查询。为什么不用红黑树？因为跳表实现更简单、区间查询更方便、支持范围查询 ZRANGEBYSCORE。

### 1.3 Redis 6.0 多线程模型

Redis 6.0 引入了 **IO 多线程**，但**命令执行依然是单线程的**。

- **IO 线程**：负责网络读写的并行处理（读取客户端请求、写回响应）
- **主线程**：依然串行执行命令，保证了原子性和有序性

默认 IO 线程数为 3（配置 `io-threads 4`），读请求分发到 IO 线程并行处理，解析完成后主线程串行执行命令。这样做的收益是：当处理大批量数据读写时，IO 不再是瓶颈。

## 二、持久化

### 2.1 RDB 快照

RDB 是 Redis 的默认持久化方式，生成一个经过压缩的二进制快照文件。

**触发方式**：
- `save`：同步阻塞，不推荐生产使用
- `bgsave`：fork 子进程，后台生成 RDB 快照

**写时复制（COW，Copy On Write）**：`bgsave` 调用 `fork()` 创建子进程，父子进程共享内存页。当父进程需要修改某个内存页时，先复制一份再修改。这样保证了子进程得到的是 fork 时刻的内存快照。

**配置示例**：
```
save 900 1      # 900 秒内至少 1 次写操作
save 300 10     # 300 秒内至少 10 次写操作
save 60 10000   # 60 秒内至少 10000 次写操作
```

**优点**：文件紧凑、恢复快、适合备份
**缺点**：可能丢失最近一次快照后的数据、fork 耗时与内存大小相关

### 2.2 AOF 日志

AOF 以追加写的方式记录每条写命令，恢复时重放所有命令。

**三种刷盘策略**：

| 策略 | 说明 | 安全性 | 性能 |
|------|------|--------|------|
| appendfsync always | 每条命令同步刷盘 | 最安全，最多丢 1 条 | 最慢 |
| appendfsync everysec | 每秒刷一次 (默认) | 最多丢 1 秒数据 | 较快 |
| appendfsync no | 由 OS 决定何时刷盘 | 可能丢多秒数据 | 最快 |

**AOF 重写**：当 AOF 文件过大时，Redis 会 fork 子进程进行重写，将内存中的数据直接转化为写命令，合并重复操作，生成瘦身后的新 AOF。

重写触发条件：
```
auto-aof-rewrite-percentage 100   # 比上次增长 100%
auto-aof-rewrite-min-size 64mb    # 最小 64MB
```

**优点**：数据安全（最多丢 1 秒）、可读性好
**缺点**：文件体积大、恢复比 RDB 慢

### 2.3 混合持久化（Redis 4.0+）

结合 RDB 和 AOF 的优点：

- 将 RDB 全量快照作为 AOF 文件的起始部分
- RDB 之后增量的日志以 AOF 格式追加
- 恢复时先加载 RDB 部分（快），再重放 AOF 部分（增量）

配置：`aof-use-rdb-preamble yes`

**优点**：恢复快（不用重放所有命令）+ 数据不丢失（增量日志）
**缺点**：AOF 文件可读性降低

### 2.4 面试怎么选

| 对比维度 | RDB | AOF | 混合持久化 |
|----------|-----|-----|-----------|
| 数据完整性 | 可能丢多 | 最多丢 1 秒 | 不丢数据 |
| 恢复速度 | 快 | 慢 | 较快 |
| 文件大小 | 小 | 大 | 中等 |
| 对写性能影响 | fork 时有影响 | 持续轻微影响 | fork + AOF |
| 推荐场景 | 可接受丢失数据，追求速度 | 数据不能丢 | **推荐生产使用** |

## 三、过期策略与内存淘汰

### 3.1 三种过期删除策略

**定时删除**：为每个过期 key 创建定时器，到期立即删除。对 CPU 不友好，过期 key 多时消耗大，Redis 没有采用。

**惰性删除**：key 过期后不立即删除，下次访问时检查是否过期，过期则删除。对内存不友好（过期 key 一直占用内存）。

**定期删除**：折中方案。Redis 每 100ms 随机抽查一批设置了过期时间的 key，若过期则删除。如果过期比例超过 25%，则重复该过程。

> **实际执行**：惰性删除 + 定期删除配合使用。

### 3.2 八种内存淘汰策略

```
maxmemory-policy noeviction  # 默认
```

| 策略 | 说明 |
|------|------|
| **noeviction** | 不淘汰，写入返回 OOM 错误 |
| **allkeys-lru** | 对所有 key 使用 LRU 淘汰 |
| **volatile-lru** | 对有 TTL 的 key 使用 LRU 淘汰 |
| **allkeys-lfu** (4.0+) | 对所有 key 使用 LFU 淘汰 |
| **volatile-lfu** (4.0+) | 对有 TTL 的 key 使用 LFU 淘汰 |
| **volatile-ttl** | 淘汰 TTL 最小的 key |
| **volatile-random** | 从有 TTL 的 key 中随机淘汰 |
| **allkeys-random** | 从所有 key 中随机淘汰 |

### 3.3 LRU vs LFU

**LRU（Least Recently Used）**：淘汰最久未使用的 key。Redis 实现的是**近似 LRU**，不维护全量链表，而是随机采样 N 个 key，淘汰其中空闲时间最长的。

**LFU（Least Frequently Used）**：淘汰访问频率最低的 key。解决 LRU 的"偶发热点"问题——一个 key 刚被访问一次就被淘汰。

**LFU 优于 LRU 的场景**：比如频繁访问的热点数据，如果偶尔有大量冷数据打入，LRU 可能把热点淘汰掉，LFU 则通过访问频率判断，更合理。

### 3.4 缓存击穿解决方案

**缓存击穿**：某个热点 key 在缓存过期的瞬间，大量请求直接打到数据库。

**方案一：热点 key 永不过期**
没有设置过期时间，或者在 value 中存逻辑过期时间，后台异步更新。

**方案二：互斥锁**
```java
// 伪代码
String value = redis.get(key);
if (value == null) {
    if (redis.setnx(lockKey, 1, 10s)) {  // 获取锁
        value = db.query(key);
        redis.set(key, value, 3600s);
        redis.del(lockKey);
    } else {
        Thread.sleep(50);
        return redis.get(key); // 重试
    }
}
```

### 3.5 BigKey 问题

**BigKey 的危害**：
- 导致 Redis 阻塞（读写大 key 耗时久）
- 网络带宽占用大（一个请求返回几 MB 数据）
- 删除大 key 也会阻塞（用 `UNLINK` 异步删除）

**如何发现**：`redis-cli --bigkeys` 或 `MEMORY USAGE key`

**如何处理**：拆分（如 Hash 分桶）、压缩、改用其他结构

## 四、缓存三大问题（面试超高频）

### 4.1 缓存穿透

**现象**：查询一个**根本不存在**的数据，缓存未命中，每次请求都穿透到数据库。

**解决方案**：

1. **参数校验**：请求到达缓存前先做基本校验（如 ID > 0）
2. **布隆过滤器**：将所有可能存在的数据哈希到位数组，若布隆过滤器判断不存在，则一定不存在

```java
// 布隆过滤器使用（Guava 实现）
BloomFilter<Integer> bloom = BloomFilter.create(
    Funnels.integerFunnel(), 
    expectedInsertions, 
    fpp);
if (!bloom.mightContain(id)) {
    return null; // 直接返回，不查 DB
}
```

3. **缓存空值**：查询 DB 不存在时，缓存空值（TTL 较短，如 5 分钟），防止重复穿透。

### 4.2 缓存击穿

**现象**：热点 key 过期瞬间，大量并发请求同时击穿到 DB。

**解决方案**：

**互斥锁**（前面已详述）：同一时间只有一个线程去加载数据。

**逻辑过期**：value 中存 `expireTime`，获取时判断是否逻辑过期，过期时拿到锁的线程去加载新数据，未拿到锁的线程返回旧数据。

```java
// 逻辑过期示例
V get(String key) {
    CacheObj obj = redis.get(key);
    if (obj.expireTime > System.currentTimeMillis()) {
        return obj.data; // 未过期，直接返回
    }
    // 逻辑过期，尝试获取锁异步刷新
    if (redis.setnx(lockKey, 1, 3s)) {
        new Thread(() -> {
            V newData = db.query(key);
            redis.set(key, new CacheObj(newData, TTL));
            redis.del(lockKey);
        }).start();
    }
    return obj.data; // 返回旧数据
}
```

### 4.3 缓存雪崩

**现象**：大量 key 同时过期，或 Redis 服务宕机，导致请求全部打到 DB。

**业务上**：大量缓存同时过期
**基础设施上**：Redis 宕机

**解决方案**：

1. **均匀过期**：基础 TTL + 随机偏移
```java
redis.set(key, value, baseTTL + RandomUtils.nextLong(0, 300));
```

2. **多级缓存**：本地缓存（Caffeine/Ehcache）+ Redis 缓存组合，Redis 挂了还有本地缓存兜底

3. **限流降级**：Hystrix/Sentinel 对 DB 请求限流，保护数据库

4. **Redis 高可用**：保证 Redis 服务不挂（主从/哨兵/集群）

## 五、分布式锁

### 5.1 为什么需要分布式锁

在分布式系统中，多个进程/服务需要互斥访问共享资源。Java 的 `synchronized` 和 `ReentrantLock` 只在一个 JVM 内有效，跨 JVM 需要用分布式锁。

### 5.2 正确实现（SET NX EX）

```java
// 加锁
String lockKey = "lock:order:12345";
String uuid = UUID.randomUUID().toString();
// SET key value NX EX seconds 是原子操作
Boolean locked = redisTemplate.opsForValue()
    .setIfAbsent(lockKey, uuid, 10, TimeUnit.SECONDS);

// 解锁（Lua 脚本保证原子性）
String luaScript = 
    "if redis.call('get', KEYS[1]) == ARGV[1] then " +
    "return redis.call('del', KEYS[1]) " +
    "else return 0 end";
redisTemplate.execute(
    new DefaultRedisScript<>(luaScript, Long.class),
    Arrays.asList(lockKey), uuid);
```

**关键点**：
- 使用 `NX` + `EX` 原子操作（防死锁）
- value 用 UUID，解锁时判断身份（防误删别人锁）
- 用 Lua 脚本保证解锁原子性（防删除时锁已过期被他人持有）

### 5.3 Redisson 可重入锁

```java
RLock lock = redissonClient.getLock(lockKey);
if (lock.tryLock(5, 10, TimeUnit.SECONDS)) { // 等待 5s, 锁 10s
    try {
        // 业务逻辑
    } finally {
        lock.unlock();
    }
}
```

Redisson 内部使用 Lua 脚本结合 Hash 结构实现可重入（`key = lockName, field = UUID:threadId, value = 重入次数`），并提供了**看门狗机制**（Watch Dog）——默认每 10 秒自动续期锁的过期时间，防止业务处理过程中锁过期。

### 5.4 RedLock 算法与争议

RedLock 由 Redis 作者 antirez 提出，需要 Redis 集群中大多数节点（N/2+1）成功加锁才算成功。

**流程**：
1. 获取当前时间戳
2. 依次在 N 个 Redis 实例上加锁（超时时间远小于锁 TTL）
3. 计算累计用时，如果 >= N/2+1 个节点成功且总耗时 < 锁 TTL，则加锁成功
4. 加锁失败或超时时，在所有实例上解锁

**争议**：分布式系统专家 Martin Kleppmann 指出 RedLock 存在时钟漂移和 GC pause 导致的锁安全问题。建议场景：**对锁一致性要求不是极端苛刻时可用**，要求强一致性的场景应使用 ZooKeeper（ZAB 协议）或 etcd（Raft 协议）。

### 5.5 分布式锁面试 5 个要点

1. **加锁原子性**：`SET NX EX` 原子操作
2. **解锁安全**：Lua 脚本校验身份后删除
3. **可重入性**：Hash 结构 + 重入次数
4. **锁续期**：看门狗机制，防止业务未完成锁过期
5. **Redis 挂掉怎么办**：RedLock / ZooKeeper

## 六、主从、哨兵、集群

### 6.1 主从复制

**全量复制**：
1. Slave 发送 `PSYNC ? -1` 请求全量同步
2. Master 执行 `bgsave` 生成 RDB，发送给 Slave
3. Slave 清空旧数据，加载 RDB
4. Master 同步缓冲区中的数据给 Slave

**部分复制（psync2.0）**：
- Master 维护复制积压缓冲区（默认 1MB）
- Slave 记录已复制的 `repl_offset`
- 断线重连后，Slave 发送 `PSYNC <master_run_id> <offset>`
- 如果 offset 后的数据还在缓冲区，则进行增量同步，否则全量复制

### 6.2 哨兵模式

哨兵（Sentinel）是 Redis 高可用方案，主要功能：

- **监控**：Sentinel 节点定期检查 Master 和 Slave 是否正常
- **提醒**：当被监控的 Redis 出现问题时，Sentinel 会通知管理员
- **自动故障转移**：Master 宕机时，从 Slave 中选举新的 Master

**选举过程（类似 Raft 算法）**：
1. Sentinel 发现 Master 下线（主观下线 → 客观下线，需多数派确认）
2. Leader Sentinel 进行选举投票
3. 从 Slave 中选出一个作为新 Master（优先级高 → offset 新 → run_id 小）
4. 其他 Slave 复制新 Master

### 6.3 Redis Cluster

Redis Cluster 是 Redis 官方的分布式方案，**去中心化架构**。

**哈希槽分配**：
- 共 16384 个槽位
- 每个 key 通过 `CRC16(key) % 16384` 计算归属槽
- 槽位分配到不同的主节点

**Gossip 协议**：节点间通过 Gossip 协议交换元数据（节点状态、槽位信息），实现去中心化。

**请求路由**：客户端可以连任意节点，如果 `key` 不在该节点上，返回 `MOVED` 重定向给客户端。

### 6.4 三种架构对比

| 特性 | 主从复制 | 哨兵模式 | Cluster 模式 |
|------|----------|----------|-------------|
| 高可用 | ❌ Master 挂后需手动切换 | ✅ 自动故障转移 | ✅ 自动故障转移 |
| 水平扩展 | ❌ 不自动分片 | ❌ 读扩展（Slave） | ✅ 自动分片 |
| 数据分布 | 全量复制 | 全量复制 | 哈希槽分片 |
| 选主算法 | 无 | Raft 类 | 集群内投票 |
| 客户端复杂度 | 低 | 中 | 高（需支持 MOVED） |
| 适用场景 | 读写分离 | 高可用但数据量不大 | 大规模数据、高并发 |

## 七、缓存一致性

### 7.1 经典问题：先更新 DB 还是先操作缓存

**先删除缓存，再更新 DB** ❌
- 线程 A 删除缓存 → 线程 B 读缓存为空，从 DB 读到旧值并写回缓存 → 线程 A 更新 DB → 缓存为脏数据

**先更新 DB，再删除缓存** ✅（Cache Aside Pattern）
- 线程 A 更新 DB → 删除缓存 → 下次读时拉取新数据
- 问题：如果删除缓存失败，缓存还是旧数据

### 7.2 延迟双删（补偿方案）

```java
public void update(String key, Object data) {
    redis.del(key);          // 1. 先删缓存
    db.update(data);         // 2. 更新数据库
    Thread.sleep(500);       // 3. 等待可能出现的并发读
    redis.del(key);          // 4. 再删缓存
}
```

确保最终一致性。延迟时间 >= 并发查询将旧值写回缓存的时间。

### 7.3 终极方案：Binlog 监听

引入 Canal 监听 MySQL 的 Binlog 变更，通过 MQ 通知 Redis 更新。

```
业务写入 DB → MySQL Binlog → Canal → MQ → 消费者更新 Redis
```

**优点**：解耦业务代码，不侵入业务逻辑，保证最终一致性

### 7.4 强一致性 vs 最终一致性

- **强一致性**：确保每次读都能读到最新写的数据。分布式系统很难（需要 2PC/Paxos/Raft）。可以放弃使用缓存，直接读 DB。
- **最终一致性**：缓存允许短暂不一致，通常在毫秒级内达成一致。**99% 的系统选择最终一致性**。

## 八、其他高频面试题

### 8.1 Redis 事务

```
MULTI        # 开启事务
INCR key1    # 命令入队
SET key2 val # 命令入队
EXEC         # 执行事务 / DISCARD 取消
```

**特点**：
- 命令入队不会立即执行，`EXEC` 时批量执行
- 所有命令**串行**执行，不会被其他命令打断
- **不支持回滚**：如果命令入队时报错，全部回滚；如果执行时报错，已执行的不会回滚

### 8.2 管道（Pipeline）

Pipeline 将多条命令一次性发送，减少 RTT（Round Trip Time）。

```java
Pipeline pipeline = jedis.pipelined();
pipeline.set("k1", "v1");
pipeline.set("k2", "v2");
pipeline.incr("counter");
List<Object> results = pipeline.syncAndReturnAll();
```

**注意**：Pipeline 不是原子操作，只是减少了网络往返次数。

### 8.3 发布订阅（Pub/Sub）

```
PUBLISH channel msg   # 发布消息
SUBSCRIBE channel     # 订阅频道
PSUBSCRIBE pattern*   # 模式订阅
```

不支持持久化：如果消费者不在线，消息丢失。不用作可靠消息队列。

### 8.4 Stream 消息队列（Redis 5.0+）

Stream 是 Redis 5.0 引入的**可靠消息队列**：

```
XADD mystream * name alice age 30     # 添加消息
XREAD COUNT 1 BLOCK 5000 STREAMS mystream 0  # 阻塞读
XGROUP CREATE mystream mygroup $       # 创建消费组
XREADGROUP GROUP mygroup consumer1 COUNT 1 BLOCK 2000 STREAMS mystream >  # 消费者读取
XACK mystream mygroup messageId       # 确认消费
```

**相比 Pub/Sub 的优势**：消息持久化、消费者组、ACK 确认。

### 8.5 计数器 / 限流 / 滑动窗口

**计数器**：`INCR key` / `DECR key`

**滑动窗口限流**：
```java
// 1 分钟内的请求数
String key = "ratelimit:" + System.currentTimeMillis() / 60000;
Long count = redisTemplate.opsForValue().increment(key);
redisTemplate.expire(key, 1, TimeUnit.MINUTES);
if (count > limit) {
    return "限流了";
}
```

**更精确的滑动窗口（ZSet）**：
```java
// 当前时间戳作为分数
long now = System.currentTimeMillis();
redisTemplate.opsForZSet().add(key, String.valueOf(now), now);
// 移除窗口外的记录
redisTemplate.opsForZSet().removeRangeByScore(key, 0, now - windowSizeMs);
// 统计窗口内请求数
Long count = redisTemplate.opsForZSet().zCard(key);
if (count > limit) { /* 限流 */ }
```

## 总结

Redis 面试考察的核心可以归纳为：

1. **基础**：为什么快、数据结构
2. **持久化**：RDB vs AOF vs 混合持久化
3. **过期与淘汰**：过期策略、8 种淘汰策略、LRU vs LFU
4. **缓存三大问题**：穿透/击穿/雪崩的解决方案
5. **分布式锁**：正确实现 + Redisson + RedLock
6. **高可用**：主从/哨兵/集群的架构原理
7. **缓存一致性**：Cache Aside + 延迟双删 + Binlog 监听
8. **场景题**：Stream 消息队列、限流器、计数器

> 核心技术在手，面试跳槽不愁。祝找工作顺利！🍀
