---
title: 系统稳定性设计：限流、熔断、降级、容错实战
date: 2026-06-15 23:30:00
tags:
  - 高可用
  - 限流
  - 熔断
  - 降级
  - 稳定性
categories:
  - 架构
author: 东哥
---

# 系统稳定性设计：限流、熔断、降级、容错实战

> 系统越复杂，出问题的概率越大。稳定性设计的本质是：在不可避免的故障中，让系统表现得足够优雅。本文从限流、熔断、降级、容错四个维度，系统梳理稳定性设计的方法论。

## 一、稳定性设计原则

### 1.1 设计目标

```
可用性目标（SLA）：
  - 99.9%：每年宕机 < 8.76 小时
  - 99.99%：每年宕机 < 52.56 分钟
  - 99.999%：每年宕机 < 5.26 分钟

设计原则：
1. 冗余设计：没有单点
2. 优雅降级：核心功能不可用时，降级非核心
3. 快速失败：失败要快，不拖累系统
4. 隔离开关：故障隔离，不扩散
```

### 1.2 防御层次

```
流量入口层：Nginx 限流、WAF 防护
     │
网关层：Sentinel 流控、熔断
     │
服务层：Hystrix/Resilience4J 熔断
     │
数据层：连接池、读写分离、缓存保护
     │
业务层：兜底策略、数据校验
```

## 二、限流策略

### 2.1 限流算法

```java
// 1. 计数器算法（固定窗口）
// 简单但有临界问题
public class CounterLimiter {
    private final int maxCount = 100;
    private final AtomicInteger counter = new AtomicInteger(0);
    private volatile long lastResetTime = System.currentTimeMillis();
    private final long windowMs = 1000;  // 1 秒窗口

    public boolean tryAcquire() {
        long now = System.currentTimeMillis();
        if (now - lastResetTime > windowMs) {
            counter.set(0);
            lastResetTime = now;
        }
        return counter.incrementAndGet() <= maxCount;
    }
}

// 2. 滑动窗口算法（解决临界问题）
public class SlidingWindowLimiter {
    private final int windowSize = 10;  // 10 个格子
    private final long windowMs = 1000;
    private final long perSlotMs = windowMs / windowSize;
    private final int[] slots = new int[windowSize];
    private volatile int currentSlot = 0;
    private volatile long lastSlotTime = System.currentTimeMillis();
    
    public synchronized boolean tryAcquire() {
        long now = System.currentTimeMillis();
        // 清理过期格子
        while (now - lastSlotTime > windowMs) {
            int slotToClear = (currentSlot + 1) % windowSize;
            slots[slotToClear] = 0;
            currentSlot = slotToClear;
            lastSlotTime += perSlotMs;
        }
        
        int total = Arrays.stream(slots).sum();
        if (total >= 100) {  // 每秒限流 100
            return false;
        }
        slots[currentSlot]++;
        return true;
    }
}

// 3. 漏桶算法（匀速处理）
public class LeakyBucket {
    private final int capacity;     // 桶容量
    private final int rate;         // 漏水速率
    private long lastLeakTime;
    private int water;

    public synchronized boolean tryAcquire() {
        long now = System.currentTimeMillis();
        // 漏水
        int leaked = (int) ((now - lastLeakTime) * rate / 1000);
        water = Math.max(0, water - leaked);
        lastLeakTime = now;
        
        if (water < capacity) {
            water++;
            return true;
        }
        return false;
    }
}

// 4. 令牌桶算法（允许突发流量）
public class TokenBucket {
    private final int capacity;     // 桶容量
    private final int rate;         // 令牌生成速率
    private long lastRefillTime;
    private int tokens;

    public synchronized boolean tryAcquire(int requested) {
        long now = System.currentTimeMillis();
        int newTokens = (int) ((now - lastRefillTime) * rate / 1000);
        tokens = Math.min(capacity, tokens + newTokens);
        lastRefillTime = now;
        
        if (tokens >= requested) {
            tokens -= requested;
            return true;
        }
        return false;
    }
}
```

### 2.2 应用层限流

```java
// 注解式限流
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RateLimiter {
    String key() default "";
    int limit() default 100;
    int timeout() default 1;
}

// AOP 实现
@Aspect
@Component
public class RateLimiterAspect {
    
    private final RedisTemplate<String, String> redis;
    private final Map<String, com.google.common.util.concurrent.RateLimiter> 
        localLimiters = new ConcurrentHashMap<>();

    @Around("@annotation(rateLimiter)")
    public Object around(ProceedingJoinPoint point, RateLimiter rateLimiter) 
            throws Throwable {
        
        String key = rateLimiter.key();
        
        // 本地限流（第一道防线）
        RateLimiter local = localLimiters.computeIfAbsent(
            key, k -> RateLimiter.create(rateLimiter.limit()));
        
        if (!local.tryAcquire()) {
            throw new BusinessException("请求过于频繁");
        }
        
        // Redis 分布式限流（第二道防线）
        String redisKey = "rate:limit:" + key;
        Long count = redis.opsForValue().increment(redisKey);
        if (count == 1) {
            redis.expire(redisKey, rateLimiter.timeout(), TimeUnit.SECONDS);
        }
        if (count > rateLimiter.limit()) {
            throw new BusinessException("已达到限流上限");
        }
        
        return point.proceed();
    }
}
```

## 三、熔断机制

### 3.1 Resilience4J 实战

```java
@Configuration
public class CircuitBreakerConfig {

    @Bean
    public Customizer<Resilience4JCircuitBreakerFactory> config() {
        return factory -> factory.configureDefault(id -> 
            new Resilience4JConfigBuilder(id)
                .circuitBreakerConfig(CircuitBreakerConfig.custom()
                    // 滑动窗口大小
                    .slidingWindowSize(10)
                    // 最小请求数（窗口内至少 5 个请求才判断熔断）
                    .minimumNumberOfCalls(5)
                    // 失败率阈值
                    .failureRateThreshold(50)
                    // 慢调用阈值
                    .slowCallDurationThreshold(Duration.ofSeconds(2))
                    .slowCallRateThreshold(60)
                    // 熔断后等待时间
                    .waitDurationInOpenState(Duration.ofSeconds(30))
                    // 半开状态允许请求数
                    .permittedNumberOfCallsInHalfOpenState(3)
                    .build())
                .build());
    }
}

// 使用熔断器
@Service
public class PaymentService {
    
    @CircuitBreaker(name = "paymentService", 
                    fallbackMethod = "paymentFallback")
    public String createPayment(Order order) {
        // 调用第三方支付
        return paymentClient.pay(order);
    }
    
    public String paymentFallback(Order order, Throwable t) {
        log.error("支付服务熔断，降级处理", t);
        return "支付服务暂时不可用，请稍后重试";
    }
}
```

### 4.2 熔断状态监控

```java
@Component
public class CircuitBreakerMonitor {
    
    @EventListener
    public void onCircuitBreakerEvent(CircuitBreaker event) {
        CircuitBreaker.State state = event.getState();
        String name = event.getName();
        
        log.warn("熔断器 [{}] 状态变更为: {}", name, state);
        
        if (state == CircuitBreaker.State.OPEN) {
            // 发送告警
            alertService.sendAlert("熔断告警", 
                String.format("服务 [%s] 已被熔断", name));
        }
    }
}
```

## 四、降级策略

### 4.1 业务降级

```java
@Component
public class DegradeService {
    
    private final boolean degradeEnabled = 
        configManager.getBoolean("degrade.enabled", false);

    // 降级开关
    @Value("${feature.recommend.enabled:true}")
    private boolean recommendEnabled;

    public List<Product> getRecommendProducts(Long userId) {
        if (!recommendEnabled || degradeEnabled) {
            // 降级：返回默认推荐
            return getDefaultRecommend();
        }
        
        try {
            return recommendService.getRecommend(userId);
        } catch (Exception e) {
            log.warn("推荐服务异常，降级返回默认推荐", e);
            return getDefaultRecommend();
        }
    }

    // 降级级别
    public interface DegradeLevel {
        int NONE = 0;        // 正常运行
        int WARN = 1;        // 非核心功能降级
        int CRITICAL = 2;    // 核心功能简化
        int EMERGENCY = 3;   // 只保留读能力
    }
}
```

### 4.2 配置中心动态降级

```yaml
# Nacos 配置
# data-id: degrade-config
# group: DEFAULT_GROUP

degrade:
  enabled: false
  level: 0
  rules:
    - service: user-service
      fallback: return-default
    - service: recommend-service
      fallback: return-empty
```

## 五、容错设计

### 5.1 重试机制

```java
// Spring Retry
@Service
public class RetryableService {

    @Retryable(value = {RemoteAccessException.class, TimeoutException.class},
               maxAttempts = 3,
               backoff = @Backoff(delay = 100, multiplier = 2))
    public String callRemoteService(String param) {
        return remoteClient.call(param);
    }

    @Recover
    public String recover(RemoteAccessException e, String param) {
        log.error("远程调用失败（已重试3次）: {}", param, e);
        return "default";
    }
}

// 手动重试（更精细的控制）
public class SmartRetry {
    
    public <T> T retry(RetryCallback<T> callback) {
        Exception lastException = null;
        
        for (int i = 0; i < 3; i++) {
            try {
                return callback.doBiz();
            } catch (Exception e) {
                lastException = e;
                if (shouldRetry(e) && i < 2) {
                    long wait = calculateWait(i);
                    Thread.sleep(wait);
                    continue;
                }
                break;
            }
        }
        throw new RuntimeException("重试失败", lastException);
    }
    
    private boolean shouldRetry(Exception e) {
        // 只重试网络相关异常
        return e instanceof TimeoutException 
            || e instanceof SocketException;
    }
}
```

### 5.2 隔离策略

```java
// 线程池隔离
@Service
public class IsolatedService {
    
    // 核心业务：独立线程池
    private final ExecutorService corePool = new ThreadPoolExecutor(
        20, 40, 60, TimeUnit.SECONDS, 
        new ArrayBlockingQueue<>(1000),
        new ThreadPoolExecutor.CallerRunsPolicy());
    
    // 非核心业务：共享线程池
    private final ExecutorService nonCorePool = new ThreadPoolExecutor(
        5, 10, 60, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(200),
        new ThreadPoolExecutor.AbortPolicy());

    public CompletableFuture<String> doCoreBusiness() {
        return CompletableFuture.supplyAsync(() -> {
            return coreTask();
        }, corePool);
    }

    public CompletableFuture<String> doNonCoreBusiness() {
        return CompletableFuture.supplyAsync(() -> {
            return nonCoreTask();
        }, nonCorePool);
    }
}
```

### 5.3 舱壁隔离（Bulkhead）

```java
// Resilience4J 舱壁模式
@Bulkhead(name = "inventoryService", 
          type = Bulkhead.Type.THREADPOOL,
          fallbackMethod = "inventoryFallback")
public Inventory checkInventory(Long productId) {
    return inventoryClient.check(productId);
}

// 信号量舱壁
@Bulkhead(name = "cacheService", 
          type = Bulkhead.Type.SEMAPHORE,
          fallbackMethod = "cacheFallback")
public String getFromCache(String key) {
    return cacheClient.get(key);
}
```

## 六、应急预案

### 6.1 分级响应

```
P0（严重）：核心服务不可用
  响应：5分钟内响应，立即恢复
  负责人：全组

P1（高）：非核心功能异常
  响应：30分钟内响应
  负责人：接口 owner

P2（中）：功能降级
  响应：2小时内响应
  负责人：值班人员

P3（低）：体验优化
  响应：24小时内响应
  负责人：开发人员
```

### 6.2 故障演练

```java
// Chaos Engineering（混沌工程）
@Component
public class ChaosExperiment {

    @Scheduled(cron = "0 0 3 * * ?")  // 凌晨 3 点演练
    public void injectFault() {
        String target = pickRandomService();
        
        switch (random.nextInt(4)) {
            case 0:
                injectDelay(target, 3000);   // 注入延迟
                break;
            case 1:
                injectError(target, 500);    // 注入错误
                break;
            case 2:
                injectException(target);     // 注入异常
                break;
            case 3:
                killInstance(target);        // 杀实例
                break;
        }
        
        // 验证系统表现
        assertCircuitBreakerWorks(target);
        assertDegradeWorks(target);
        assertNoFullFailure();
    }
}
```

## 七、总结

系统稳定性不是靠运气，而是靠设计。核心要点：

1. **限流是防御**：保护系统不被流量冲垮
2. **熔断是止损**：防止故障扩散
3. **降级是妥协**：用部分功能换整体可用
4. **容错是兜底**：保证最终有响应

**设计路线图：**
```
第一阶段：接入限流 + 超时控制
第二阶段：实现熔断 + 降级兜底
第三阶段：完善监控 + 告警
第四阶段：混沌工程 + 自动修复
```

记住：**没有 100% 可用的系统，但有 100% 的应对预案。**
