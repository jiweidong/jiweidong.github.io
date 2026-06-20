---
title: API限流策略与算法全解析（令牌桶/漏桶/滑动窗口）
date: 2026-06-20 08:00:00
tags:
  - 架构设计
  - 限流
  - 高并发
  - 系统设计
  - API网关
categories:
  - 架构设计
author: 东哥
---

# API限流策略与算法全解析（令牌桶/漏桶/滑动窗口）

在微服务架构中，限流是保障系统稳定性的第一道防线。无论是应对突发流量、防止恶意攻击，还是保障后端服务的公平使用，合理的限流策略都是系统设计的核心课题。本文将深入对比四种主流限流算法，并提供基于Java的生产级实现。

## 一、为什么需要限流？

### 1.1 限流与熔断的关系

| 策略 | 目的 | 触发条件 | 影响范围 | 恢复方式 |
|-----|------|---------|---------|---------|
| 限流 | 控制流量速率 | 超过阈值 | 当前请求 | 速率降低后自动恢复 |
| 熔断 | 保护被调用方 | 错误率/延迟超限 | 后续请求 | 半开探测恢复 |
| 降级 | 提供降级服务 | 资源不足 | 特定功能 | 手动或自动恢复 |
| 隔离 | 资源隔离 | 流量高峰 | 线程池/信号量 | 依赖隔离机制 |

### 1.2 常见限流场景

```java
// 1. API接口限流 — 控制每秒请求数
@RateLimiter(name = "order-api", fallbackMethod = "fallback")
@PostMapping("/orders")
public OrderResponse createOrder(@RequestBody OrderRequest request) {
    return orderService.create(request);
}

// 2. 用户级别限流 — 每个用户的QPS
// 基于userId维度的限流

// 3. 接口级别限流 — 不同接口不同速率
// GET /api/products: 1000 QPS
// POST /api/orders: 200 QPS
// DELETE /api/orders: 50 QPS

// 4. 全局限流 — 整个网关/服务的总QPS
// 整个API gateway: 5000 QPS
```

## 二、四大核心限流算法

### 2.1 固定窗口计数器

#### 原理
将时间划分为固定大小的窗口，每个窗口内维护一个计数器：

```text
时间轴: |----1s----|----1s----|----1s----|
        |计数=5    |计数=100  |计数=3    |
        ^          ^
        窗口A      窗口B（超出阈值）
```

#### 实现
```java
public class FixedWindowRateLimiter {
    private final long windowSizeMs;      // 窗口大小（毫秒）
    private final long maxRequests;       // 窗口内最大请求数
    private final AtomicLong counter;     // 当前窗口计数器
    private volatile long windowStart;    // 窗口开始时间
    
    public FixedWindowRateLimiter(long windowSizeMs, long maxRequests) {
        this.windowSizeMs = windowSizeMs;
        this.maxRequests = maxRequests;
        this.counter = new AtomicLong(0);
        this.windowStart = System.currentTimeMillis();
    }
    
    public boolean tryAcquire() {
        long now = System.currentTimeMillis();
        long start = this.windowStart;
        
        if (now - start >= windowSizeMs) {
            // 进入新窗口，重置
            synchronized (this) {
                if (now - this.windowStart >= windowSizeMs) {
                    this.windowStart = now;
                    this.counter.set(0);
                }
            }
        }
        
        long count = counter.incrementAndGet();
        return count <= maxRequests;
    }
}
```

#### 问题：临界突变（热点问题）

固定窗口算法在窗口切换时存在严重缺陷：

```text
阈值: 100请求/秒
|----1s(窗口A)----|----1s(窗口B)----|
  0:00:  99请求          0:00:  99请求
  0:59:1请求             0:01:1请求
  ----------------临界点----------------
在0:59和0:01交界处，实际2秒内处理了200请求！
```

**这就是著名的「热点问题」（Traffic Burst at Boundaries）**，固定窗口算法无法平滑限制流量。

### 2.2 滑动窗口日志

#### 原理
记录每个请求的时间戳，计算过去窗口内的请求总数：

```text
时间轴: ←———— 1秒窗口 ————→
        |   |   |   |   |
        0.1 0.3 0.5 0.8 1.1 (请求时间戳)
        ↑ 窗口内有4个请求
```

#### 实现
```java
public class SlidingWindowLogRateLimiter {
    private final long windowSizeMs;
    private final long maxRequests;
    private final Queue<Long> timestamps = new ConcurrentLinkedQueue<>();
    
    public SlidingWindowLogRateLimiter(long windowSizeMs, long maxRequests) {
        this.windowSizeMs = windowSizeMs;
        this.maxRequests = maxRequests;
    }
    
    public synchronized boolean tryAcquire() {
        long now = System.currentTimeMillis();
        long cutoff = now - windowSizeMs;
        
        // 移除过期的时间戳
        while (!timestamps.isEmpty() && timestamps.peek() < cutoff) {
            timestamps.poll();
        }
        
        // 检查当前窗口内请求数
        if (timestamps.size() < maxRequests) {
            timestamps.offer(now);
            return true;
        }
        
        return false;
    }
}
```

#### 优点 vs 缺点
| 方面 | 评价 |
|-----|------|
| 准确性 | 精确，无热点问题 |
| 内存占用 | O(n)，n为窗口内请求数，窗口大时内存高 |
| 适合场景 | 低QPS接口，需要精确限制 |
| 不适合场景 | 高QPS接口（10万+ QPS），内存消耗大 |

### 2.3 滑动窗口计数器

#### 原理
将窗口细分为更小的时间片，每个时间片独立计数，整体窗口的请求数等于所有时间片之和：

```text
1秒窗口，分为5个200ms时间片：
|---0.2s---|---0.2s---|---0.2s---|---0.2s---|---0.2s---|
[计数: 30] [计数: 20] [计数: 10] [计数: 40] [计数: 0]
                  ←———— 当前1秒窗口 ————————→
                  总和: 20+10+40+0 = 70
```

#### 实现
```java
public class SlidingWindowCounterRateLimiter {
    private final int windowSizeMs;
    private final int slotCount;          // 时间片数量
    private final int slotSizeMs;         // 每个时间片大小
    private final int maxRequests;
    
    private final AtomicLongArray slotCounts;
    private volatile int currentSlot;
    
    public SlidingWindowCounterRateLimiter(int windowSizeMs, int slotCount, int maxRequests) {
        this.windowSizeMs = windowSizeMs;
        this.slotCount = slotCount;
        this.slotSizeMs = windowSizeMs / slotCount;
        this.maxRequests = maxRequests;
        this.slotCounts = new AtomicLongArray(slotCount);
        this.currentSlot = 0;
    }
    
    public boolean tryAcquire() {
        long now = System.currentTimeMillis();
        int slot = (int)((now / slotSizeMs) % slotCount);
        
        // 如果时间片已切换，重置旧时间片
        if (slot != currentSlot) {
            synchronized (this) {
                if (slot != currentSlot) {
                    slotCounts.set(slot, 0);
                    currentSlot = slot;
                }
            }
        }
        
        // 计算当前窗口总请求数
        long totalRequests = 0;
        for (int i = 0; i < slotCount; i++) {
            totalRequests += slotCounts.get(i);
        }
        
        if (totalRequests >= maxRequests) {
            return false;
        }
        
        slotCounts.incrementAndGet(slot);
        return true;
    }
}
```

时间片数量对精度的影响：

| 时间片数 | 内存占用 | 精度 | 临界问题 |
|---------|---------|------|---------|
| 2 | 极低 | 低 | 仍有热点问题 |
| 5 | 低 | 中 | 热点问题减轻 |
| 10 | 中 | 较高 | 基本消除 |
| 20 | 较高 | 高 | 近似精确 |
| 100 | 高 | 极高 | 接近日志模式 |

### 2.4 令牌桶算法（Token Bucket）

#### 原理
以一个固定速率向桶中添加令牌，请求需要消耗令牌才能通过。桶有最大容量限制。

```text
                +----------+
  令牌生成器 ---→| 令牌桶   |---→ 请求消耗令牌
  (固定速率)    | 容量: N  |
                +----------+
                    |
                    ↓
              请求通过/拒绝
```

Token Bucket vs Leaky Bucket的核心理念对比：

| 区别 | 令牌桶 | 漏桶 |
|-----|-------|------|
| 核心 | 令牌生成速率 | 水滴流出速率 |
| 是否允许突发 | 是（可在桶满时突发） | 否（严格控制流出速率） |
| 空闲表现 | 桶装满令牌 | 桶变空 |
| 实现难度 | 中等 | 简单 |

#### 实现
```java
public class TokenBucketRateLimiter {
    private final long capacity;          // 桶容量
    private final double refillRate;      // 令牌补充速率（个/秒）
    private final AtomicLong tokens;      // 当前令牌数（放大1000倍，避免浮点）
    private volatile long lastRefillTime; // 上次补充时间
    
    private static final long SCALE = 1000;
    
    public TokenBucketRateLimiter(long capacity, double refillRate) {
        this.capacity = capacity;
        this.refillRate = refillRate;
        this.tokens = new AtomicLong(capacity * SCALE);
        this.lastRefillTime = System.nanoTime();
    }
    
    public boolean tryAcquire(int permits) {
        refillTokens();
        
        long scaledPermits = permits * SCALE;
        while (true) {
            long current = tokens.get();
            if (current < scaledPermits) {
                return false;
            }
            if (tokens.compareAndSet(current, current - scaledPermits)) {
                return true;
            }
        }
    }
    
    private void refillTokens() {
        long now = System.nanoTime();
        long last = lastRefillTime;
        
        // 使用CAS避免加锁
        if (lastRefillTime < now) {
            long elapsed = now - last;
            long newTokens = (long)(elapsed * refillRate * SCALE / 1_000_000_000);
            
            if (newTokens > 0) {
                if (lastRefillTime.compareAndSet(last, now)) {
                    long maxTokens = capacity * SCALE;
                    tokens.updateAndGet(current -> 
                        Math.min(current + newTokens, maxTokens)
                    );
                }
            }
        }
    }
}
```

#### 令牌桶 vs 漏桶对比

| 特性 | 令牌桶 | 漏桶 |
|-----|-------|------|
| 突发处理 | ✅ 允许一定突发 | ❌ 严格平滑 |
| 实现复杂度 | 中等 | 简单 |
| 适合场景 | 一般API限流 | 需要严格速率控制的场景 |
| 空闲行为 | 桶填满令牌 | 桶变空 |
| 常用框架 | Guava RateLimiter | Nginx limit_req |
| 分布式实现 | 较复杂 | 较简单 |

### 2.5 漏桶算法（Leaky Bucket）

#### 原理
将请求视为水滴，以固定速率从桶底漏出，桶已满时新请求被丢弃。

```text
      请求进入
    ↓↓↓↓↓
  +---------+
  |  漏桶    |  桶满则丢弃请求
  | (缓冲区) |
  +----+----+
       |
       ↓ (固定速率漏出)
      请求处理

```

#### 实现
```java
public class LeakyBucketRateLimiter {
    private final long capacity;           // 桶容量
    private final long leakRate;           // 漏水速率（请求/秒）
    private final AtomicLong waterLevel;   // 当前水量
    private volatile long lastLeakTime;    // 上次漏水时间
    
    public LeakyBucketRateLimiter(long capacity, long leakRate) {
        this.capacity = capacity;
        this.leakRate = leakRate;
        this.waterLevel = new AtomicLong(0);
        this.lastLeakTime = System.nanoTime();
    }
    
    public boolean tryAcquire() {
        leakWater();  // 先漏水
        
        long current = waterLevel.get();
        if (current >= capacity) {
            return false;  // 桶已满，丢弃
        }
        
        return waterLevel.compareAndSet(current, current + 1);
    }
    
    private void leakWater() {
        long now = System.nanoTime();
        long elapsed = now - lastLeakTime;
        
        // 计算应该漏掉的水量
        long leaked = (long)(elapsed * leakRate / 1_000_000_000L);
        
        if (leaked > 0) {
            lastLeakTime = now;
            waterLevel.updateAndGet(current -> 
                Math.max(0, current - leaked)
            );
        }
    }
}
```

## 三、分布式限流方案

### 3.1 Redis + Lua 实现分布式令牌桶

**核心思路**：利用Redis的原子操作和Lua脚本实现跨节点的令牌管理。

```java
@Component
public class RedisTokenBucketRateLimiter {
    
    private final StringRedisTemplate redisTemplate;
    private final DefaultRedisScript<Long> rateLimitScript;
    
    public RedisTokenBucketRateLimiter(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
        
        // 加载Lua脚本
        this.rateLimitScript = new DefaultRedisScript<>();
        this.rateLimitScript.setScriptSource(
            new ResourceScriptSource(new ClassPathResource("rate_limiter.lua"))
        );
        this.rateLimitScript.setResultType(Long.class);
    }
    
    public boolean tryAcquire(String key, long capacity, long refillRate, int permits) {
        Long result = redisTemplate.execute(
            rateLimitScript,
            List.of(key),
            String.valueOf(capacity),
            String.valueOf(refillRate),
            String.valueOf(permits),
            String.valueOf(System.currentTimeMillis())
        );
        return result != null && result == 1L;
    }
}
```

**Lua脚本（rate_limiter.lua）：**

```lua
-- 分布式令牌桶Lua脚本
-- KEYS[1]: 限流key
-- ARGV[1]: 桶容量
-- ARGV[2]: 每秒补充速率
-- ARGV[3]: 请求的令牌数
-- ARGV[4]: 当前时间戳

local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refillRate = tonumber(ARGV[2])
local permits = tonumber(ARGV[3])
local now = tonumber(ARGV[4])

-- 获取当前桶状态
local tokens_key = key .. ".tokens"
local timestamp_key = key .. ".ts"

local current_tokens = redis.call("get", tokens_key)
local last_refill = redis.call("get", timestamp_key)

if current_tokens == false then
    current_tokens = capacity
else
    current_tokens = tonumber(current_tokens)
end

if last_refill == false then
    last_refill = now
else
    last_refill = tonumber(last_refill)
end

-- 计算需要补充的令牌
local elapsed = math.max(0, now - last_refill)
local refill = math.floor(elapsed * refillRate / 1000)

if refill > 0 then
    current_tokens = math.min(capacity, current_tokens + refill)
    redis.call("set", timestamp_key, now)
end

-- 判断是否足够
if current_tokens >= permits then
    redis.call("set", tokens_key, current_tokens - permits)
    -- 设置过期时间（防止内存泄漏）
    redis.call("expire", tokens_key, 10)
    redis.call("expire", timestamp_key, 10)
    return 1  -- 允许通过
else
    return 0  -- 限流
end
```

### 3.2 Sentinel集成限流

Spring Cloud Alibaba Sentinel提供了丰富的限流规则配置：

```java
@Configuration
public class SentinelConfig {
    
    @PostConstruct
    public void initRules() {
        // 1. QPS限流规则
        List<FlowRule> rules = new ArrayList<>();
        
        FlowRule rule = new FlowRule();
        rule.setResource("createOrder");
        rule.setGrade(RuleConstant.FLOW_GRADE_QPS);  // QPS模式
        rule.setCount(200);                          // 200 QPS
        rule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_RATE_LIMITER);  // 匀速排队
        rule.setMaxQueueingTimeMs(500);              // 最大排队时间
        rules.add(rule);
        
        // 2. 并发线程数限流
        FlowRule threadRule = new FlowRule();
        threadRule.setResource("processPayment");
        threadRule.setGrade(RuleConstant.FLOW_GRADE_THREAD);
        threadRule.setCount(20);                     // 最多20个并发线程
        rules.add(threadRule);
        
        // 3. 热点参数限流
        ParamFlowRule hotRule = new ParamFlowRule("getProduct");
        hotRule.setParamIdx(0);                      // 对第一个参数限流
        hotRule.setCount(10);                        // 每秒10次
        hotRule.setDurationInSec(1);
        ParamFlowRuleManager.loadRules(List.of(hotRule));
        
        FlowRuleManager.loadRules(rules);
    }
    
    // 使用Sentinel注解
    @SentinelResource(
        value = "createOrder",
        blockHandler = "handleBlock",
        fallback = "handleFallback"
    )
    public Order createOrder(OrderRequest request) {
        return orderService.create(request);
    }
    
    public Order handleBlock(OrderRequest request, BlockException e) {
        // 限流后的处理
        log.warn("Request blocked by rate limiter: {}", request);
        throw new BizException(429, "Too many requests, please try later");
    }
}
```

## 四、生产级限流最佳实践

### 4.1 多层限流架构

```text
                      ┌──────────────────┐
                      │  CDN层限流        │
                      │  (CloudFlare/CDN) │
                      │  全局10万QPS      │
                      └────────┬─────────┘
                               ↓
                      ┌──────────────────┐
                      │  API网关限流       │
                      │  (Kong/APISIX)    │
                      │  服务级5000QPS    │
                      └────────┬─────────┘
                               ↓
                      ┌──────────────────┐
                      │  应用层限流        │
                      │  (Sentinel/Resi-  │
                      │   lience4j)       │
                      │  接口级200QPS     │
                      └────────┬─────────┘
                               ↓
                      ┌──────────────────┐
                      │  分布式限流        │
                      │  (Redis+Lua)     │
                      │  用户级10QPS      │
                      └──────────────────┘
```

### 4.2 限流响应策略

| 策略 | 实现方式 | 适用场景 |
|-----|---------|---------|
| 直接拒绝 | 返回HTTP 429 | 超过硬限制 |
| 排队等待 | 等待直到获取令牌 | 可以容忍延迟 |
| 降级服务 | 返回缓存/默认值 | 非核心接口 |
| 预热模式 | 从低速率逐步提升 | 系统冷启动 |

```java
@Component
public class RateLimitResponseHandler {
    
    @Value("${rate-limit.response-strategy:reject}")
    private String strategy;
    
    public ResponseEntity<?> handleRateLimited(HttpServletRequest request) {
        return switch (strategy) {
            case "reject" -> ResponseEntity
                .status(429)
                .header("Retry-After", "1")
                .body(new ErrorResponse(
                    429,
                    "请求过于频繁，请稍后再试",
                    request.getRequestURI()
                ));
                
            case "degrade" -> {
                // 返回缓存数据
                Object cachedResult = cacheManager
                    .getCache("default")
                    .get(request.getRequestURI());
                yield ResponseEntity.ok(
                    cachedResult != null ? cachedResult : getDefaultResponse(request)
                );
            }
            
            case "queue" -> ResponseEntity
                .status(202)
                .header("X-Queue-Position", queueManager.enqueue(request))
                .body(new QueueResponse("请求已加入队列", request.getRequestURI()));
                
            default -> ResponseEntity
                .status(429)
                .body("Rate limit exceeded");
        };
    }
}
```

### 4.3 限流参数动态调整

```java
@Component
public class DynamicRateLimitManager {
    
    private final Map<String, TrafficRecord> records = new ConcurrentHashMap<>();
    
    @Scheduled(fixedRate = 60000)  // 每分钟评估一次
    public void adjustLimits() {
        records.forEach((key, record) -> {
            // 根据过去1分钟的指标动态调整
            double errorRate = record.getErrorRate();
            double avgLatency = record.getAvgLatency();
            double currentQps = record.getQps();
            
            // 如果错误率升高或延迟增大，降低限流阈值
            if (errorRate > 0.05 || avgLatency > 500) {
                double newLimit = currentQps * 0.8;  // 降低20%
                updateFlowRule(key, (int)newLimit);
                log.warn("Auto-adjusted rate limit for {}: {} → {}", 
                    key, currentQps, newLimit);
            }
            
            // 如果系统稳定，逐步提高阈值
            if (errorRate < 0.01 && avgLatency < 100 && currentQps < getMaxCapacity()) {
                double newLimit = Math.min(currentQps * 1.1, getMaxCapacity());
                updateFlowRule(key, (int)newLimit);
                log.info("Gradually increased rate limit for {}: {} → {}", 
                    key, currentQps, newLimit);
            }
        });
    }
}
```

### 4.4 限流告警与监控

```java
@Component
@Slf4j
public class RateLimitMonitor {
    
    private final MeterRegistry meterRegistry;
    private final NotificationService notificationService;
    
    public RateLimitMonitor(MeterRegistry meterRegistry, 
                           NotificationService notificationService) {
        this.meterRegistry = meterRegistry;
        this.notificationService = notificationService;
    }
    
    public void recordRateLimited(String resource, String userId) {
        // 记录限流次数指标
        Counter.builder("rate.limit.blocked.total")
            .tag("resource", resource)
            .register(meterRegistry)
            .increment();
        
        // 记录用户限流次数
        Counter.builder("rate.limit.blocked.by.user")
            .tag("userId", userId)
            .register(meterRegistry)
            .increment();
        
        // 高阈值触发告警
        double blockedRate = getBlockedRate(resource);
        if (blockedRate > 0.2) {  // 限流率超过20%
            notificationService.sendAlert(
                "Rate limiting alert: " + resource,
                String.format("Blocked rate: %.1f%%", blockedRate * 100)
            );
        }
    }
}
```

## 五、算法选择决策树

```
需要严格速率控制吗？
├─ 是 → 漏桶算法
│       └─ 实现：Nginx limit_req、Redis+队列
│
└─ 否 → 需要支持突发流量吗？
        ├─ 是 → 令牌桶算法
        │       └─ 实现：Guava RateLimiter、Resilience4j
        │
        └─ 否 → 需要精确控制吗？
                ├─ 是 → 滑动窗口日志
                │       └─ 实现：本地队列、Redis Sorted Set
                │
                └─ 否 → 滑动窗口计数器
                        └─ 实现：Redis + Lua、Sentinel
```

## 六、总结

限流是微服务架构中保障系统稳定性的重要手段。选择合适的限流算法需要综合考虑：

1. **精确度需求**：是否需要严格意义上的精确限流
2. **突发流量容忍度**：是否允许短时间的请求突发
3. **资源开销**：内存占用、Redis网络开销
4. **分布式支持**：是否需要跨节点共享限流状态

**推荐组合：**
- 网关层：滑动窗口计数器（高性能、可接受精度）
- 应用层：令牌桶（支持突发、平滑处理）
- 用户级：Redis + Lua分布式令牌桶（精确、共享）
- 核心接口：漏桶（严格速率控制）
