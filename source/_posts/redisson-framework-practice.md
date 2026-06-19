---
title: Redisson 分布式框架实战：从分布式锁到消息队列
date: 2026-06-19 09:30:00
tags:
  - Redis
  - Redisson
  - 分布式锁
  - 分布式框架
categories:
  - 中间件
author: 东哥
---

Redisson 是基于 Redis 的 Java 分布式框架，提供了分布式锁、分布式集合、分布式队列、分布式服务等丰富的功能。与 Jedis 和 Lettuce 不同，Redisson 专注于提供高层次的分布式编程抽象，让开发者像使用本地 Java 集合一样使用分布式对象。本文将深入解析 Redisson 的核心特性和源码实现。

<!-- more -->

## 一、Redisson 整体架构

### 1.1 架构层次

Redisson 的架构自上而下分为三层：

```
应用程序层（Distributed Objects）
    ├── 分布式锁（RLock, RFairLock, RReadWriteLock）
    ├── 分布式集合（RMap, RSet, RList, RQueue）
    ├── 分布式服务（RScheduledExecutorService, RRemoteService）
    ├── 分布式工具（RAtomicLong, RCountDownLatch, RBloomFilter）
    └── 限流器（RRateLimiter）
          │
    核心框架层（Core Framework）
    ├── Netty 通信（独立连接管理器）
    ├── Lua 脚本引擎（脚本驱动核心逻辑）
    ├── 命令执行器（异步 CommandAsyncService）
    ├── 连接池管理（ConnectionManager）
    └── WatchDog（自动续期机制）
          │
    Redis 基础设施层（Redis Infrastructure）
    ├── 单节点模式
    ├── 哨兵模式
    ├── 集群模式
    └── 云托管模式（AWS ElastiCache, Azure Redis）
```

### 1.2 初始化配置

```java
// 1. 单节点模式
Config config = new Config();
config.useSingleServer()
    .setAddress("redis://127.0.0.1:6379")
    .setConnectionMinimumIdleSize(10)
    .setConnectionPoolSize(100)
    .setPassword("password");

RedissonClient redisson = Redisson.create(config);

// 2. 哨兵模式
Config sentinelConfig = new Config();
sentinelConfig.useSentinelServers()
    .setMasterName("mymaster")
    .addSentinelAddress("redis://127.0.0.1:26379", "redis://127.0.0.1:26380")
    .setMasterConnectionPoolSize(50)
    .setSlaveConnectionPoolSize(50);

// 3. 集群模式
Config clusterConfig = new Config();
clusterConfig.useClusterServers()
    .setScanInterval(2000)
    .addNodeAddress("redis://127.0.0.1:6379", "redis://127.0.0.1:6380")
    .setMasterConnectionPoolSize(50);

// 4. 云托管模式
Config cloudConfig = new Config();
cloudConfig.useReplicatedServers()
    .addNodeAddress("redis://cluster.xxxxx.cache.amazonaws.com:6379")
    .setScanInterval(2000);
```

## 二、分布式锁（Distributed Locks）

分布式锁是 Redisson 最核心的功能之一，支持多种锁类型。

### 2.1 可重入锁（RLock）

最基本的分布式可重入锁，基于 Redis 的 Hash 数据结构实现：

```java
// 获取锁实例
RLock lock = redisson.getLock("myLock");

// 🔴 最简单的用法（不推荐：没有自动释放，可能死锁）
lock.lock();

// ✅ 推荐用法：自动释放
lock.lock(10, TimeUnit.SECONDS);
try {
    // 执行业务逻辑
    Thread.sleep(3000);
} finally {
    lock.unlock();
}

// ✅ 更推荐：tryLock 支持等待和超时
if (lock.tryLock(5, 30, TimeUnit.SECONDS)) {  // 等待5秒，锁30秒超时
    try {
        // 执行业务逻辑
    } finally {
        lock.unlock();
    }
} else {
    System.out.println("获取锁失败");
}
```

### 2.2 公平锁（Fair Lock）

公平锁按请求顺序分配锁，避免了线程饥饿：

```java
RFairLock fairLock = redisson.getFairLock("fairLock");

// 用法和 RLock 类似，但内部维护了一个等待队列
fairLock.lock();
try {
    // 业务逻辑
} finally {
    fairLock.unlock();
}
```

### 2.3 读写锁（ReadWriteLock）

读写锁允许多个读操作并发，但写操作互斥：

```java
RReadWriteLock rwLock = redisson.getReadWriteLock("rwLock");
RLock readLock = rwLock.readLock();
RLock writeLock = rwLock.writeLock();

// 读线程
public void readData() {
    readLock.lock();
    try {
        // 多个读线程可以同时进入
        System.out.println("Reading data at " + System.currentTimeMillis());
        Thread.sleep(1000);
    } finally {
        readLock.unlock();
    }
}

// 写线程
public void writeData() {
    writeLock.lock();
    try {
        // 写线程独占，其他读写都会被阻塞
        System.out.println("Writing data at " + System.currentTimeMillis());
        Thread.sleep(1000);
    } finally {
        writeLock.unlock();
    }
}
```

**读写锁性能对比**：

| 操作 | 无锁 | 读锁 | 写锁 |
|-----|------|------|------|
| 读操作 | ✅ 并发 | ✅ 并发 | ❌ 等待 |
| 写操作 | ❌ 数据竞争 | ❌ 等待 | ❌ 互斥 |

### 2.4 红锁（RedLock）

RedLock 是 Redis 官方提出的分布式锁算法，用于跨多个独立 Redis 节点实现强一致性锁。Redisson 提供了 `RedissonRedLock`：

```java
// 创建三个独立的 RLock 实例（对应三个不同的 Redis 节点）
RLock lock1 = redisson1.getLock("redlock");
RLock lock2 = redisson2.getLock("redlock");
RLock lock3 = redisson3.getLock("redlock");

// 组装成红锁
RedissonRedLock redLock = new RedissonRedLock(lock1, lock2, lock3);

if (redLock.tryLock(10, 30, TimeUnit.SECONDS)) {
    try {
        // 大多数节点（这里 3 个中的 2 个）加锁成功
        // 执行业务逻辑
    } finally {
        redLock.unlock();
    }
}
```

**RedLock 要点**：
- 使用奇数个 Redis 节点（至少 3 个），互相独立
- 需要在超过半数节点上加锁成功才算获取锁
- 锁的有效期需要是一个较短的时间
- 如果一个节点加锁失败，要在其他节点释放锁

### 2.5 联锁（MultiLock）

MultiLock 要求在所有指定 Redis 实例上加锁成功：

```java
RLock lock1 = redisson1.getLock("lock1");
RLock lock2 = redisson2.getLock("lock2");
RLock lock3 = redisson3.getLock("lock3");

RedissonMultiLock multiLock = new RedissonMultiLock(lock1, lock2, lock3);
multiLock.lock();
try {
    // 所有三个锁都成功获取
} finally {
    multiLock.unlock();
}
```

**RedLock 与 MultiLock 区别**：

| 特性 | RedLock | MultiLock |
|-----|---------|-----------|
| 锁成功条件 | 超过半数 | 全部节点 |
| 容错性 | 可容忍部分节点故障 | 任一节点故障则失败 |
| 典型用途 | 跨数据中心强一致性 | 资源分片保护 |

## 三、锁的 WatchDog 自动续期机制

WatchDog 是 Redisson 分布式锁的自动续期机制，解决了"业务执行时间超过锁超时时间"导致锁被提前释放的问题。这是 Redisson 相比原生 SETNX 的重要优势。

### 3.1 源码级分析

```java
// RedissonLock.java（核心源码，精简版）
public class RedissonLock extends RedissonExpirable implements RLock {
    
    // 默认的锁超时时间：30 秒
    private static final long LOCK_EXPIRATION_INTERVAL_SECONDS = 30;
    
    // 锁续期调度器（WatchDog）
    private ScheduledExecutorService executorService;
    
    // lock() 无参调用的路径
    @Override
    public void lock() {
        try {
            lockInterruptibly();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
    
    @Override
    public void lockInterruptibly() throws InterruptedException {
        // 1. 尝试加锁
        Long ttl = tryAcquire(-1, null);
        
        if (ttl == null) {
            // 加锁成功，WatchDog 会自动续期
            return;
        }
        
        // 2. 加锁失败，订阅锁释放的消息
        RFuture<RedissonLockEntry> future = subscribe(threadId);
        future.syncUninterruptibly();
        
        try {
            while (true) {
                // 3. 再次尝试加锁
                ttl = tryAcquire(-1, null);
                if (ttl == null) {
                    break;
                }
                
                // 4. 等待锁释放的信号
                if (ttl >= 0) {
                    getEntry().getLatch().tryAcquire(ttl, TimeUnit.MILLISECONDS);
                } else {
                    getEntry().getLatch().acquire();
                }
            }
        } finally {
            unsubscribe(future);
        }
    }
}
```

### 3.2 Lua 加锁脚本

```java
// RedissonLock 使用 Lua 脚本保证原子性
private <T> RFuture<Long> tryAcquireAsync(long waitTime, long leaseTime, 
                                           TimeUnit unit, long threadId) {
    if (leaseTime != -1) {
        // 如果指定了超时时间，不加 WatchDog
        return tryLockInnerAsync(
            getRawName(), threadId, leaseTime, unit);
    }
    
    // leaseTime == -1：使用默认超时 + WatchDog 续期
    RFuture<Long> ttlRemainingFuture = tryLockInnerAsync(
        getRawName(), threadId, 
        LOCK_EXPIRATION_INTERVAL_SECONDS * 1000, TimeUnit.MILLISECONDS);
    
    ttlRemainingFuture.onComplete((ttlRemaining, e) -> {
        if (e != null) return;
        
        if (ttlRemaining == null) {
            // 加锁成功，启动 WatchDog
            scheduleExpirationRenewal(threadId);
        }
    });
    
    return ttlRemainingFuture;
}

// 核心 Lua 脚本
// KEYS[1] = 锁的 key 名称
// ARGV[1] = 锁超时时间（毫秒）
// ARGV[2] = 线程标识（UUID:threadId）
<T> RFuture<T> tryLockInnerAsync(String key, long threadId, 
                                  long leaseTime, TimeUnit unit) {
    return commandExecutor.evalWriteAsync(key, LongCodec.INSTANCE,
        // 检查锁是否已存在
        "if (redis.call('exists', KEYS[1]) == 0) then " +
            // 不存在，创建锁（Hash：key -> {threadId: 1}）
            "redis.call('hincrby', KEYS[1], ARGV[2], 1); " +
            "redis.call('pexpire', KEYS[1], ARGV[1]); " +
            "return nil; " +
        "end; " +
        // 锁已存在，检查是否是当前线程持有
        "if (redis.call('hexists', KEYS[1], ARGV[2]) == 1) then " +
            // 可重入：增加计数
            "redis.call('hincrby', KEYS[1], ARGV[2], 1); " +
            "redis.call('pexpire', KEYS[1], ARGV[1]); " +
            "return nil; " +
        "end; " +
        // 锁被其他线程持有，返回剩余 TTL
        "return redis.call('pttl', KEYS[1]);",
        List.of(key),
        unit.toMillis(leaseTime), 
        getLockName(threadId)
    );
}
```

### 3.3 WatchDog 续期逻辑

```java
// WatchDog 实现
private void scheduleExpirationRenewal(long threadId) {
    ExpirationEntry entry = new ExpirationEntry();
    ExpirationEntry oldEntry = EXPIRATION_RENEWAL_MAP.putIfAbsent(
        getEntryName(), entry);
    
    if (oldEntry != null) {
        oldEntry.addThreadId(threadId);
    } else {
        entry.addThreadId(threadId);
        // 启动定时任务：每 10 秒执行一次续期
        // 续期到 30 秒
        renewalTimeout = commandExecutor.getServiceManager()
            .newTimeout(new TimerTask() {
                @Override
                public void run(Timeout timeout) throws Exception {
                    // 执行 Lua 续期脚本
                    RFuture<Boolean> future = renewExpirationAsync(threadId);
                    future.onComplete((res, e) -> {
                        if (e != null) return;
                        if (res) {
                            // 续期成功，重新调度
                            scheduleExpirationRenewal(threadId);
                        }
                    });
                }
            }, LOCK_EXPIRATION_INTERVAL_SECONDS / 3, TimeUnit.SECONDS);
    }
}
```

**WatchDog 工作机制总结**：

| 步骤 | 说明 |
|------|------|
| 1. 锁超时设置 | 默认 30 秒 |
| 2. 续期间隔 | 每 10 秒续期一次（锁超时的 1/3） |
| 3. 续期动作 | 执行 Lua 脚本重新设置 PEXPIRE |
| 4. 续期终止条件 | unlock() 被调用或应用进程退出 |
| 5. 进程崩溃 | Redis 等待 30 秒后自动释放锁 |

## 四、分布式限流器（RRateLimiter）

Redisson 的分布式限流器基于令牌桶算法实现：

```java
// 创建限流器：每秒最多 10 个请求
RRateLimiter rateLimiter = redisson.getRateLimiter("myRateLimiter");

// 初始化设置：每 1 秒生成 10 个令牌
rateLimiter.trySetRate(RateType.OVERALL, 10, 1, RateIntervalUnit.SECONDS);

// 1. 阻塞方式获取令牌
rateLimiter.acquire();           // 获取 1 个令牌（阻塞直到有令牌）
rateLimiter.acquire(5);          // 获取 5 个令牌

// 2. 非阻塞方式
if (rateLimiter.tryAcquire()) {
    // 获取成功，执行请求
} else {
    // 限流了，返回错误或重试
}

// 3. 带等待时间的 tryAcquire
if (rateLimiter.tryAcquire(500, TimeUnit.MILLISECONDS)) {
    // 等待最多 500ms，如果还没有令牌则放弃
}
```

**RateType 类型**：

```java
// 全局限流：所有客户端共享限流
rateLimiter.trySetRate(RateType.OVERALL, 100, 1, RateIntervalUnit.SECONDS);

// 客户端级限流：每个客户端独立限流
rateLimiter.trySetRate(RateType.PER_CLIENT, 100, 1, RateIntervalUnit.SECONDS);
```

**Lua 实现**：

```lua
-- RRateLimiter 的核心 Lua 脚本（简化版）
local rate = redis.call('hget', KEYS[1], 'rate');
local interval = redis.call('hget', KEYS[1], 'interval');
local type = redis.call('hget', KEYS[1], 'type');

-- 计算当前可用的令牌数量
local currentValue = redis.call('get', KEYS[1] .. ':value');
if currentValue == false then
    currentValue = tonumber(rate);
    redis.call('set', KEYS[1] .. ':value', currentValue);
    redis.call('set', KEYS[1] .. ':timestamp', 1800000);
else
    -- 根据时间差补充令牌
    local lastTime = redis.call('get', KEYS[1] .. ':timestamp');
    local passedTime = redis.call('time')[1] - lastTime;
    local addTokens = math.floor(passedTime / interval * rate);
    if addTokens > 0 then
        currentValue = math.min(tonumber(currentValue) + addTokens, tonumber(rate));
        redis.call('set', KEYS[1] .. ':value', currentValue);
        redis.call('set', KEYS[1] .. ':timestamp', redis.call('time')[1]);
    end
end

-- 判断是否有足够令牌
if currentValue >= tonumber(ARGV[1]) then
    redis.call('decrby', KEYS[1] .. ':value', tonumber(ARGV[1]));
    return 1;
else
    return 0;
end
```

## 五、分布式队列

Redisson 提供了丰富的分布式队列实现，底层基于 List、Set、SortedSet 等 Redis 数据结构。

### 5.1 基础队列

```java
// RQueue：先进先出，类似 Queue
RQueue<String> queue = redisson.getQueue("myQueue");
queue.add("task1");
queue.add("task2");
queue.add("task3");

String task = queue.poll();  // 获取并移除头部元素
String peek = queue.peek();  // 查看头部元素，不移除

// RDeque：双端队列
RDeque<String> deque = redisson.getDeque("myDeque");
deque.addFirst("front_task");
deque.addLast("back_task");
deque.offerFirst("high_priority");

// 遍历队列
for (String item : queue) {
    System.out.println(item);
}
```

### 5.2 阻塞队列

阻塞队列在列表为空时会阻塞等待，适合生产者-消费者模式：

```java
// RBlockingQueue
RBlockingQueue<String> blockingQueue = redisson.getBlockingQueue("taskQueue");

// 生产者
public void produceTasks() {
    for (int i = 0; i < 100; i++) {
        blockingQueue.put("task-" + i);  // 如果队列满则阻塞
        System.out.println("Produced: task-" + i);
    }
}

// 消费者 - 带超时的阻塞获取
public void consumeTasks() {
    while (!Thread.currentThread().isInterrupted()) {
        // 等待 30 秒，如果还没有元素就返回 null
        String task = blockingQueue.poll(30, TimeUnit.SECONDS);
        
        if (task != null) {
            System.out.println("Processing: " + task);
            process(task);
        } else {
            // 超时，检查是否应该退出
            break;
        }
    }
}

// 也可以使用 take() 无限等待
String task = blockingQueue.take();  // 如果没有元素，永远阻塞
```

### 5.3 延迟队列（RDelayedQueue）

延迟队列中的元素会在指定延迟时间后才可被消费：

```java
// 创建一个延迟队列
RBlockingQueue<String> destinationQueue = redisson.getBlockingQueue("orderQueue");
RDelayedQueue<String> delayedQueue = redisson.getDelayedQueue(destinationQueue);

// 向延迟队列添加消息，30 分钟后才可消费
delayedQueue.offer("order-12345", 30, TimeUnit.MINUTES);
delayedQueue.offer("order-12346", 1, TimeUnit.HOURS);
delayedQueue.offer("order-12347", 7, TimeUnit.DAYS);

// 消费者从 destinationQueue 获取到期元素
// 时间未到的元素不会出现在 destinationQueue 中
String expiredOrder = destinationQueue.poll(); // 只拿到已到期的订单
```

**队列类型对比**：

| 队列类型 | 底层数据结构 | 特点 | 适用场景 |
|---------|-------------|------|---------|
| RQueue | List | 基础 FIFO | 简单任务队列 |
| RDeque | List | 双端操作 | 优先级任务 |
| RBlockingQueue | List | 支持阻塞 | 生产者-消费者 |
| RBoundedBlockingQueue | List | 有界阻塞 | 限流队列 |
| RBlockingDeque | List | 双端阻塞 | 特殊调度需求 |
| RDelayedQueue | ZSet + List | 延迟可见 | 延时任务 |

## 六、分布式布隆过滤器（RBloomFilter）

布隆过滤器用于高效判断元素"不存在"而不保证"一定存在"：

```java
// 创建布隆过滤器，预计插入 10000 个元素，误判率 1%
RBloomFilter<String> bloomFilter = redisson.getBloomFilter("sampleBloomFilter");
bloomFilter.tryInit(10000L, 0.01);  // expectedInsertions, falseProbability

// 添加元素
bloomFilter.add("user_001");
bloomFilter.add("user_002");
bloomFilter.add("user_003");

// 判断是否存在
System.out.println(bloomFilter.contains("user_001")); // true
System.out.println(bloomFilter.contains("user_004")); // false（大概率）
System.out.println(bloomFilter.contains("user_999")); // 可能返回 true（误判）

// 实际应用：缓存穿透防护
public Object queryUser(String userId) {
    // 1. 先检查布隆过滤器
    if (!bloomFilter.contains(userId)) {
        // 用户一定不存在，直接返回空，避免查询数据库
        return null;
    }
    
    // 2. 布隆过滤器说存在，再查缓存
    Object user = cache.get(userId);
    if (user != null) return user;
    
    // 3. 缓存未命中，查询数据库
    user = database.findUser(userId);
    if (user != null) {
        cache.put(userId, user);
    }
    return user;
}
```

## 七、分布式原子操作

### 7.1 RAtomicLong

```java
RAtomicLong atomicLong = redisson.getAtomicLong("myAtomicLong");
atomicLong.set(0);

// 原子递增/递减
atomicLong.incrementAndGet();  // 1
atomicLong.getAndIncrement();  // 1 (返回旧值 1，新值为 2)
atomicLong.addAndGet(10);      // 12
atomicLong.decrementAndGet();  // 11

// 比较并交换
boolean success = atomicLong.compareAndSet(11, 100);
System.out.println(success); // true

// 获取并更新
long oldValue = atomicLong.getAndUpdate(v -> v * 2);
```

### 7.2 RCountDownLatch

```java
// 分布式 CountDownLatch：等待多个节点完成
RCountDownLatch latch = redisson.getCountDownLatch("taskLatch");
latch.trySetCount(3);  // 需要等待 3 个完成信号

// 任务节点 1
new Thread(() -> {
    doWork("Node1");
    latch.countDown();  // 计数减 1
}).start();

// 任务节点 2
new Thread(() -> {
    doWork("Node2");
    latch.countDown();
}).start();

// 任务节点 3
new Thread(() -> {
    doWork("Node3");
    latch.countDown();
}).start();

// 主线程等待所有节点完成
boolean completed = latch.await(60, TimeUnit.SECONDS);
if (completed) {
    System.out.println("All nodes completed");
} else {
    System.out.println("Timeout waiting for nodes");
}
```

## 八、分布式缓存

### 8.1 RMapCache

RMapCache 在 RMap 基础上增加了 TTL 支持，每个元素可以设置不同的过期时间：

```java
RMapCache<String, Session> sessionMap = redisson.getMapCache("sessions");

// 存储 session，30 分钟后过期
sessionMap.put("session-001", new Session("user-001"), 
    30, TimeUnit.MINUTES);

// 存储 session，10 分钟不访问则过期，最 大 1 小时
sessionMap.put("session-002", new Session("user-002"),
    10, TimeUnit.MINUTES,  // 闲置过期时间
    60, TimeUnit.MINUTES); // 最 大过期时间

// 缓存数据库查询结果（带 TTL）
public User getUserById(String userId) {
    // 先查缓存
    User user = userCache.get(userId);
    if (user != null) return user;
    
    // 查数据库
    user = database.findUser(userId);
    if (user != null) {
        userCache.put(userId, user, 5, TimeUnit.MINUTES);
    }
    return user;
}
```

### 8.2 RLocalCachedMap

RLocalCachedMap 在 RMap 基础上增加了本地缓存层，大幅减少对 Redis 的网络请求：

```java
// 配置本地缓存
LocalCachedMapOptions<String, Product> options = LocalCachedMapOptions
    .<String, Product>defaults()
    .evictionPolicy(LocalCachedMapOptions.EvictionPolicy.LRU) // LRU 淘汰
    .cacheSize(1000)              // 本地缓存容量
    .maxIdleTime(10, TimeUnit.SECONDS) // 最大闲置时间
    .timeToLive(60, TimeUnit.SECONDS); // TTL

RLocalCachedMap<String, Product> productCache = 
    redisson.getLocalCachedMap("productCache", options);

// 读操作优先从本地缓存读取，极大提升性能
Product product = productCache.get("product-001");

// 本地缓存同步策略
// 其他客户端修改后，通过消息通知使本地缓存失效
```

**RLocalCachedMap 同步策略**：

| 策略 | 说明 | 数据一致性 |
|-----|------|-----------|
| NONE | 不通知其他节点 | ❌ 最终不一致 |
| INVALIDATE | 使其他节点的本地缓存失效 | ✅ 强一致（读时从 Redis 获取） |
| ALL | 通知所有节点更新 | ✅ |

## 九、分布式服务

### 9.1 分布式调度器（RScheduledExecutorService）

```java
// 注册调度任务
RScheduledExecutorService executor = 
    redisson.getExecutorService("myExecutor");

// 提交可执行任务（需要实现 Runnable/Serializable）
executor.submit(new MyTask());         // 立即执行
executor.schedule(new MyTask(), 10, TimeUnit.SECONDS);      // 延迟执行

// 定时执行
executor.schedule(new MyTask(), 5, 10, TimeUnit.MINUTES); // 延迟5分钟，每10分钟执行一次

// 分布式 Cron 任务
executor.schedule(new MyTask(), CronSchedule.of("0 0 2 * * ?")); // 每天凌晨2点

// 获取执行结果（分布式 Future）
ExecutorRScheduledFuture<String> future = 
    executor.schedule(new CallableTask(), 10, TimeUnit.SECONDS);
String result = future.get();  // 阻塞等待结果
```

### 9.2 远程服务（RRemoteService）

```java
// ===== 服务端 =====
// 定义远程服务接口
public interface RemoteCalcService {
    int add(int a, int b);
    int multiply(int a, int b);
}

// 实现类
public class RemoteCalcServiceImpl implements RemoteCalcService {
    @Override
    public int add(int a, int b) {
        return a + b;
    }
    
    @Override
    public int multiply(int a, int b) {
        return a * b;
    }
}

// 注册远程服务
RRemoteService remoteService = redisson.getRemoteService();
remoteService.register(RemoteCalcService.class, new RemoteCalcServiceImpl());


// ===== 客户端 =====
// 获取远程服务代理
RRemoteService clientRemoteService = redisson.getRemoteService();
RemoteCalcService calcService = 
    clientRemoteService.get(RemoteCalcService.class);

// 调用远程方法（像调用本地方法一样）
int sum = calcService.add(1, 2);           // 同步调用
int product = calcService.multiply(3, 4);  // 同步调用

// 执行引擎策略
// 1. REDIS_NATIVE：Redis 原生任务执行（默认）
// 2. WORKER：工人节点执行
```

## 十、Redisson 框架对比总结

| 功能类别 | Redisson | Jedis | Lettuce | 原生 Redis |
|---------|---------|-------|---------|-----------|
| 分布式锁 | ✅ 多种锁类型 | ❌ 需自己实现 | ❌ 需自己实现 | SETNX+NX |
| WatchDog | ✅ 内置自动续期 | ❌ | ❌ | ❌ |
| 分布式集合 | ✅ 丰富 | ❌ | ❌ | ❌ |
| 限流器 | ✅ 令牌桶 | ❌ | ❌ | CL.THROTTLE |
| 布隆过滤器 | ✅ | ❌ | ❌ | ❌ |
| 分布式服务 | ✅ 调度/远程调用 | ❌ | ❌ | ❌ |
| 线程模型 | Netty（异步） | 阻塞 IO | Netty（响应式） | N/A |

## 总结

Redisson 通过 Netty 异步通信 + Lua 脚本驱动的方式，在 Redis 基础能力之上构建了一套完整的分布式基础设施。其核心设计亮点包括：

1. **Lua 脚本原子性**：所有分布式操作的原子性都通过 Redis Lua 脚本保证，避免了竞态条件
2. **Netty 异步架构**：所有操作都是异步的，提供了极高的并发吞吐能力
3. **WatchDog 自动续期**：解决锁超时与业务执行时间不匹配的问题
4. **丰富的分布式抽象**：让 Java 开发者以使用本地集合的方式使用分布式数据结构

生产环境中，Redisson 是分布式应用开发的首选 Redis 客户端框架。理解其内部实现机制，能帮助我们更好地利用这些分布式能力，也能在遇到问题时快速定位和解决。
