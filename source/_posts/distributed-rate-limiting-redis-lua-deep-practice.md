---
title: 【高并发实战】分布式限流深度实战：Redis + Lua 原子限流与网关级方案
date: 2026-08-26 08:00:00
tags:
  - Java
  - Redis
  - 高并发
  - 限流
categories:
  - Java
  - 高并发
author: 东哥
---

# 【高并发实战】分布式限流深度实战：Redis + Lua 原子限流与网关级方案

## 面试官：单机限流和分布式限流有什么区别？Redis 限流怎么保证原子性？

上一篇文章讲了限流的四种算法（固定窗口、滑动窗口、漏桶、令牌桶），那都是**单机视角**。生产环境服务是集群部署的——你有 10 个实例，每个实例限 100 QPS，整体就能被冲到 1000 QPS，限流形同虚设。所以必须做**分布式限流**：把限流状态放到所有实例共享的地方（Redis），让整个集群统一限流。

本文实战讲解分布式限流的完整方案：Redis + Lua 的原子实现、滑动窗口与令牌桶的 Lua 脚本、网关层（Spring Cloud Gateway）限流落地，以及各种方案的对比与坑。

## 一、为什么必须用 Lua 脚本？

### 1.1 分布式限流的本质矛盾

分布式限流的核心操作是"读计数 → 判断 → 写计数"，例如固定窗口：

```
INCR key          # 计数 +1
if 计数 > 限额: 拒绝
```

如果是"先 GET 再 INCR"，在高并发下会出现**竞态条件**：两个请求同时读到计数=99，都 INCR 到 100，都放行，实际 101 个请求。这不是 Redis 单线程的问题，而是**客户端多条命令之间不是原子的**。

### 1.2 解决方案对比

| 方案 | 原子性 | 网络开销 | 复杂度 | 评价 |
|------|--------|---------|--------|------|
| 多条命令（GET+INCR） | ❌ 有竞态 | 2 次 RTT | 低 | 不可用 |
| 事务 MULTI/EXEC | ✅ | 2 次 RTT | 中 | 无法在事务中做判断（EXEC 才执行） |
| **Lua 脚本** | ✅✅ | 1 次 RTT | 中 | **标准答案** |
| 原生 Redis 命令组合 | 部分 | 1 次 | 低 | 如 INCR+EXPIRE 仍有窗口期问题 |

Redis 从 2.6 开始支持 Lua 脚本，**整个脚本在 Redis 服务端原子执行**（脚本执行期间其他命令排队），天然解决竞态。而且脚本在网络中只传一次，减少了 RTT。

> 面试追问：为什么 Redis 的 Lua 脚本是原子的？
> 答：Redis 是单线程执行命令，Lua 脚本被当作一个整体在服务端执行，执行期间不会有其他命令插入（Redis 6 的异步线程只处理耗时的 IO 类命令，不影响脚本的原子性语义）。另外 Redis 内置了 Lua 解释器，无需额外安装。

## 二、方案一：固定窗口限流（Lua 版）

固定窗口算法：每个时间窗口内计数，超过阈值拒绝，窗口结束清零。

```lua
-- 固定窗口限流脚本
-- KEYS[1] = 限流 key，如 rate:limit:user:1001
-- ARGV[1] = 窗口大小（秒）
-- ARGV[2] = 窗口内最大请求数
local key = KEYS[1]
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])

local current = redis.call('INCR', key)
if current == 1 then
    -- 第一次访问，设置过期时间（窗口大小），到期自动清空
    redis.call('EXPIRE', key, window)
end
if current > limit then
    return 0   -- 拒绝
end
return 1       -- 放行
```

Java 端调用：

```java
@Component
public class RedisRateLimiter {
    @Autowired
    private StringRedisTemplate redisTemplate;

    // 预加载脚本，返回 SHA 缓存，避免每次发送整个脚本
    private DefaultRedisScript<Long> fixedWindowScript = new DefaultRedisScript<>(
            "local key = KEYS[1]\n" +
            "local window = tonumber(ARGV[1])\n" +
            "local limit = tonumber(ARGV[2])\n" +
            "local current = redis.call('INCR', key)\n" +
            "if current == 1 then redis.call('EXPIRE', key, window) end\n" +
            "if current > limit then return 0 end\n" +
            "return 1", Long.class);

    public boolean tryAcquire(String key, int windowSeconds, int limit) {
        Long result = redisTemplate.execute(fixedWindowScript,
                List.of("rate:limit:" + key), windowSeconds + "", limit + "");
        return result != null && result == 1L;
    }
}
```

**关键点**：`INCR` 返回 1 说明是新窗口，此时设置 `EXPIRE`，窗口自然过期。这个 Lua 脚本是**原子**的：INCR 和 EXPIRE 之间不会插入其他命令。

**固定窗口的缺陷**：窗口切换瞬间会有"双倍请求"问题——59 秒和 60 秒两个窗口的边界各能放行 limit 个请求，突发流量可能打穿。解决：滑动窗口。

## 三、方案二：滑动窗口限流（ZSet 版）

滑动窗口用 ZSet 记录每个请求的时间戳，统计窗口内（当前时间 - 窗口大小）的请求数：

```lua
-- 滑动窗口限流脚本（ZSet 实现）
-- KEYS[1] = 限流 key
-- ARGV[1] = 窗口大小（毫秒）
-- ARGV[2] = 窗口内最大请求数
-- ARGV[3] = 当前时间戳（毫秒）
local key = KEYS[1]
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

-- 1. 清理窗口外的过期记录（score < now - window）
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

-- 2. 统计窗口内请求数
local count = redis.call('ZCARD', key)

if count >= limit then
    return 0   -- 拒绝
end

-- 3. 记录本次请求（score 和时间戳都取 now）
redis.call('ZADD', key, now, now .. '-' .. math.random(1000000))
-- 4. 设置过期时间，防止 key 永久占内存
redis.call('PEXPIRE', key, window)
return 1
```

Java 端：

```java
public boolean tryAcquire(String key, long windowMillis, int limit) {
    Long result = redisTemplate.execute(slidingWindowScript,
            List.of("sliding:" + key),
            windowMillis + "", limit + "", String.valueOf(System.currentTimeMillis()));
    return result != null && result == 1L;
}
```

**滑动窗口的代价**：每个请求都要往 ZSet 写一条记录，内存开销大；高 QPS 下 ZSet 会很大。优化手段：**采样滑动窗口**（用多个固定窗口加权平均）或者直接用令牌桶。

## 四、方案三：令牌桶限流（Lua 版）——生产最常用

令牌桶算法：以恒定速率往桶里放令牌，请求必须拿到令牌才能通过，桶满则丢弃令牌。它允许一定的**突发流量**（桶容量），又能限制**平均速率**，是生产环境最常用的算法（Guava RateLimiter、Sentinel 默认都是令牌桶思路）。

```lua
-- 令牌桶限流脚本
-- KEYS[1] = 令牌桶 key（存放当前令牌数）
-- KEYS[2] = 上次补充时间 key
-- ARGV[1] = 桶容量 capacity
-- ARGV[2] = 每秒补充速率 rate（每秒新增令牌数）
-- ARGV[3] = 当前时间戳（秒）
local bucketKey = KEYS[1]
local timeKey = KEYS[2]
local capacity = tonumber(ARGV[1])
local rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local tokens = tonumber(redis.call('GET', bucketKey) or capacity)
local lastTime = tonumber(redis.call('GET', timeKey) or now)

-- 1. 计算这段时间补充的令牌数
local elapsed = math.max(0, now - lastTime)
tokens = math.min(capacity, tokens + elapsed * rate)

-- 2. 更新补充时间
redis.call('SET', timeKey, now, 'EX', 3600)

-- 3. 判断是否放行
if tokens >= 1 then
    redis.call('SET', bucketKey, tokens - 1, 'EX', 3600)
    return 1   -- 拿到令牌，放行
else
    redis.call('SET', bucketKey, tokens, 'EX', 3600)
    return 0   -- 桶空了，拒绝
end
```

**为什么这个脚本更优雅？** 不需要后台任务定时放令牌——令牌按时间差**惰性计算**，每次请求时根据"上次补充时间"算出应补充的令牌数，省掉了定时器，这是生产实现的标准手法（Guava RateLimiter 内部也是惰性计算）。

**注意**：速率单位是"每秒"，如果对精度要求高，可以把时间单位换成毫秒，用 `PEXPIRE` 配合。

## 五、方案四：网关层分布式限流（Spring Cloud Gateway + Redis RateLimiter）

微服务架构下，最优雅的限流位置是**网关**——所有流量必经之地，在网关限流可以保护下游所有服务。

Spring Cloud Gateway 内置了基于 **Redis + Lua 令牌桶**的 `RequestRateLimiter` 过滤器，用的是 Redis 官方 `token-bucket` 脚本（与上文的惰性令牌桶同思路），开箱即用：

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/order/**
          filters:
            - name: RequestRateLimiter
              args:
                # 限流 Key 解析器：按用户 ID 限流（每个用户独立配额）
                key-resolver: "#{@userKeyResolver}"
                # 令牌桶容量：桶里最多放 20 个令牌
                redis-rate-limiter.replenishRate: 10
                # 每秒补充 10 个令牌
                redis-rate-limiter.burstCapacity: 20
```

Key 解析器（决定按什么维度限流——用户、IP、接口）：

```java
@Bean
public KeyResolver userKeyResolver() {
    // 按用户 ID 限流；取不到用户时按 IP
    return exchange -> {
        String userId = exchange.getRequest().getHeaders().getFirst("X-User-Id");
        if (userId != null) {
            return Mono.just(userId);
        }
        String ip = exchange.getRequest().getRemoteAddress().getAddress().getHostAddress();
        return Mono.just(ip);
    };
}
```

网关限流返回 429 状态码，还可以自定义：

```java
@Bean
public RequestRateLimiterGatewayFilterFactory.RequestRateLimiterConfig ... 
// 或直接全局处理 429：在 GlobalExceptionHandler 中捕获 TOO_MANY_REQUESTS
```

### 网关限流的优势与注意点

- ✅ 统一入口，一处配置保护所有下游
- ✅ 天然分布式（Redis 共享状态）
- ✅ 内置 Lua 脚本，原子且高效
- ⚠️ 网关是单点瓶颈，网关本身要高可用、多实例部署
- ⚠️ 每个请求多一次 Redis 往返（约 0.1-1ms），对极端性能敏感的场景可先在网关层粗限流，服务内再用本地限流兜底（两级限流）

## 六、多级限流架构：单机 + 分布式组合拳

生产环境的完整限流应该是**分级**的：

```
客户端 → Nginx/LVS 层限流(连接数/IP) → API 网关层限流(Redis 分布式)
       → 服务内本地限流(Sentinel/Guava，单机兜底) → 依赖层限流(DB/第三方)
```

| 层级 | 技术 | 粒度 | 作用 |
|------|------|------|------|
| 接入层 | Nginx limit_req / OpenResty | IP/连接 | 防 DDoS、防刷 |
| 网关层 | Gateway RequestRateLimiter（Redis+Lua） | 用户/接口 | 全局配额 |
| 服务层 | Sentinel / Resilience4j | 接口/方法 | 单机保护 + 熔断降级 |
| 数据层 | 连接池/队列 | 资源 | 防止打垮存储 |

两层限流的典型组合：**网关分布式限流（总量控制）+ 服务内本地限流（快速失败，避免每次请求都打 Redis）**。本地限流可以先于分布式限流拒绝一部分请求，大幅降低 Redis 压力。

## 七、分布式限流的坑与最佳实践

1. **Redis 挂了怎么办？** 限流组件要支持**降级**：Redis 不可用时放行（牺牲限流保可用，防止限流组件拖垮业务）或本地限流兜底。Sentinel 的 `DegradeFlow` 思路值得借鉴。
2. **Redis 超时**：限流操作设置短超时（如 100ms），不能让一次 Redis 超时阻塞业务线程。
3. **Key 爆炸**：按用户维度限流时，key 数量 = 用户数。给 key 设置 TTL（窗口大小或略长），配合定期清理。
4. **时间戳依赖**：多实例时钟漂移会导致滑动窗口统计偏差，用 Redis 的 `TIME` 命令取时间或接受毫秒级误差。
5. **热 Key 问题**：限流 Key 集中在少数热点（如大促的爆款商品），单 Redis 分片可能扛不住，考虑 Redis Cluster + 分片。
6. **脚本预加载**：用 `SCRIPT LOAD` 预加载脚本拿 SHA，`EVALSHA` 调用，省去每次传输脚本的开销。
7. **限流响应**：统一返回 429 + Retry-After 头，客户端可据此退避重试。

## 八、面试追问汇总

1. **为什么不用 MULTI/EXEC 做限流？** 事务是"批量执行"，执行期间无法根据中间结果做判断（EXEC 之前命令不执行），做不了"先判断后决定"的逻辑；Lua 可以。
2. **Redis 单线程为什么还能扛高并发？** IO 多路复用 + 内存操作微秒级，瓶颈在网络 IO 而非 CPU；6.0 引入多线程处理 IO 读写，命令执行仍是单线程。
3. **固定窗口、滑动窗口、令牌桶怎么选？** 简单场景固定窗口；要求平滑选滑动窗口或令牌桶；允许突发流量选令牌桶（桶容量控制突发量）；严格均匀速率选漏桶。
4. **Sentinel 和 Redis 限流什么关系？** Sentinel 默认是单机限流（本地内存），也支持集群限流（Token Server 模式，底层类似分布式令牌桶）；Redis 限流是自己造轮子，适合不想引入 Sentinel 的场景。
5. **网关限流的 key-resolver 怎么设计？** 按用户（登录态）、按 IP（匿名）、按接口+用户（精细控制）、按参数（如商品 ID 防刷）。

## 总结

分布式限流的核心就三点：**共享状态放 Redis、原子操作靠 Lua、落地位置在网关**。本文的四个 Lua 脚本（固定窗口、滑动窗口、令牌桶）建议直接收藏，生产可直接改造使用；再配合网关 RequestRateLimiter 和 Sentinel 兜底，一套完整的分布式限流体系就搭起来了。面试时能画出"分级限流架构图"并说出 Lua 原子性的原理，这道题就是送分题。
