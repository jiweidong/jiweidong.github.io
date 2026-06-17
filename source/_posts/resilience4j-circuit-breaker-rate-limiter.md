---
title: Resilience4j 实战：断路器、限流器与重试机制深度解析
date: 2026-06-17 10:00:00
tags:
  - Resilience4j
  - 断路器
  - 限流
  - 容错
  - Spring Cloud
categories:
  - 微服务
author: 东哥
---

# Resilience4j 实战：断路器、限流器与重试机制深度解析

## 一、为什么需要 Resilience4j

在微服务架构中，服务之间的调用链条越来越长。任何一个下游服务的故障，都可能通过调用链向上传播，最终导致整个系统雪崩。**Resilience4j** 是 Netfilx Hystrix 停更后的官方推荐替代方案，它提供了一套轻量、易用的容错组件。

### 1.1 Resilience4j vs Hystrix

| 特性 | Hystrix | Resilience4j |
|------|---------|-------------|
| 状态 | 维护模式（Archived） | 活跃维护 |
| 底层 | 基于 HystrixCommand 注解 | 基于 Vavr 函数式编程 |
| 隔离方式 | 线程池 / 信号量 | 信号量（更轻量） |
| 模块化 | 单 Jar 包 | 按需引入（6大模块） |
| 熔断状态 | CLOSED / OPEN | CLOSED / OPEN / HALF_OPEN + DISABLED / FORCED_OPEN |
| 配置方式 | 配置文件 | Java Config + 配置文件 |
| 响应式支持 | 有限 | 原生支持 Reactor / RxJava |

## 二、核心模块详解

### 2.1 六大组件

```xml
<!-- 按需引入 -->
<dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-spring-boot3</artifactId>
    <version>2.2.0</version>
</dependency>

<dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-all</artifactId>
    <!-- 包含全部模块 -->
</dependency>
```

| 模块 | 功能 | 解决什么问题 |
|------|------|-------------|
| CircuitBreaker | 断路器（熔断器） | 防止级联故障 |
| RateLimiter | 限流器 | 控制请求速率 |
| Retry | 重试器 | 自动重试失败请求 |
| TimeLimiter | 超时限制器 | 设置调用超时 |
| Bulkhead | 舱壁隔离 | 限制并发调用数 |
| Cache | 缓存 | 缓存成功调用结果 |

### 2.2 架构关系

```
┌─────────────────────────────────────────────────┐
│                   用户请求                       │
├─────────────────────────────────────────────────┤
│  Decorators.ofFuture(supplier)                   │
│    .withCircuitBreaker(circuitBreaker)           │
│    .withRateLimiter(rateLimiter)                 │
│    .withRetry(retryContext)                      │
│    .withTimeLimiter(timeLimiter)                 │
│    .withBulkhead(bulkhead)                       │
│    .get()                                        │
├─────────────────────────────────────────────────┤
│               目标服务调用                        │
└─────────────────────────────────────────────────┘
```

## 三、断路器(CircuitBreaker) 实战

### 3.1 状态机与流转

```
         ┌──────────────────────┐
         │      CLOSED          │
         │  正常运行，请求通过    │
         └──────┬───────────────┘
                │ 失败率 > 阈值
                ▼
         ┌──────────────────────┐
         │       OPEN           │◄─────────┐
         │  熔断开启，快速失败    │          │
         └──────┬───────────────┘          │
                │ 超时时间到                │
                ▼                          │
         ┌──────────────────────┐          │
         │     HALF_OPEN        │──────────┤
         │  试探性的放行请求     │ 失败     │
         └──────┬───────────────┘          │
                │ 试探请求成功              │
                ▼                          │
         ┌──────────────────────┐          │
         │      CLOSED          │──────────┘
         │     恢复正常         │
         └──────────────────────┘
```

### 3.2 配置详解

```yaml
resilience4j:
  circuitbreaker:
    configs:
      default:
        registerHealthIndicator: true
        # 滑动窗口类型：COUNT_BASED / TIME_BASED
        slidingWindowType: TIME_BASED
        # 滑动窗口大小（10秒）
        slidingWindowSize: 10
        # 最低调用数（达到后才开始计算）
        minimumNumberOfCalls: 5
        # 熔断阈值：50% 的请求失败则熔断
        failureRateThreshold: 50
        # 半开状态下允许通过的最大请求数
        permittedNumberOfCallsInHalfOpenState: 3
        # 自动从 OPEN 切换到 HALF_OPEN 的等待时间
        waitDurationInOpenState: 10s
        # 慢调用阈值
        slowCallDurationThreshold: 2s
        slowCallRateThreshold: 60
        # 记录异常
        recordExceptions:
          - java.io.IOException
          - java.util.concurrent.TimeoutException
        # 忽略异常（不计入失败）
        ignoreExceptions:
          - com.example.BusinessException
    instances:
      # 订单服务熔断器
      orderService:
        baseConfig: default
        failureRateThreshold: 30  # 更敏感
        waitDurationInOpenState: 30s
      # 库存服务熔断器
      inventoryService:
        baseConfig: default
        failureRateThreshold: 60
        slidingWindowSize: 20
```

### 3.3 代码实战

```java
@Service
public class OrderServiceClient {
    
    @CircuitBreaker(name = "orderService", fallbackMethod = "fallback")
    public OrderDTO getOrder(Long orderId) {
        // 调用远程服务
        return restTemplate.getForObject(
            "http://order-service/api/orders/" + orderId, 
            OrderDTO.class
        );
    }
    
    // 熔断后的降级方法
    private OrderDTO fallback(Long orderId, Throwable t) {
        log.warn("订单服务熔断，返回兜底数据: orderId={}, error={}", 
            orderId, t.getMessage());
        // 从本地缓存获取旧数据
        return orderCache.get(orderId);
    }
}
```

### 3.4 编程式使用

```java
@Configuration
public class CircuitBreakerConfig {
    
    @Bean
    public CircuitBreaker inventoryCircuitBreaker(
            CircuitBreakerRegistry registry) {
        CircuitBreakerConfig config = CircuitBreakerConfig.custom()
            .slidingWindowType(SlidingWindowType.TIME_BASED)
            .slidingWindowSize(10)
            .failureRateThreshold(50)
            .waitDurationInOpenState(Duration.ofSeconds(30))
            .permittedNumberOfCallsInHalfOpenState(3)
            .recordExceptions(IOException.class, TimeoutException.class)
            .build();
        
        return registry.circuitBreaker("inventoryService", config);
    }
}

@Service
public class InventoryService {
    
    private final CircuitBreaker circuitBreaker;
    private final RestTemplate restTemplate;
    
    public InventoryService(CircuitBreaker circuitBreaker,
                            RestTemplate restTemplate) {
        this.circuitBreaker = circuitBreaker;
        this.restTemplate = restTemplate;
    }
    
    public InventoryDTO checkStock(String skuId) {
        Supplier<InventoryDTO> supplier = () -> 
            restTemplate.getForObject(
                "http://inventory/api/stock/" + skuId, 
                InventoryDTO.class);
        
        // 编程式使用断路器
        Supplier<InventoryDTO> decorated = CircuitBreaker
            .decorateSupplier(circuitBreaker, supplier);
        
        // 添加降级逻辑
        Supplier<InventoryDTO> withFallback = Try
            .ofSupplier(decorated)
            .recover(throwable -> {
                log.warn("Inventory check failed, use default: {}", 
                    throwable.getMessage());
                return new InventoryDTO(skuId, 0, false);
            })
            .toSupplier();
        
        return withFallback.get();
    }
}
```

## 四、限流器(RateLimiter) 实战

### 4.1 令牌桶算法

Resilience4j 的 RateLimiter 基于 **令牌桶算法**：

```java
// 原理：每秒往桶里放 N 个令牌，请求需要消耗令牌
RateLimiterConfig config = RateLimiterConfig.custom()
    .limitRefreshPeriod(Duration.ofSeconds(1))  // 刷新周期
    .limitForPeriod(100)                         // 每个周期 100 个令牌
    .timeoutDuration(Duration.ofMillis(500))     // 等待令牌的超时时间
    .build();
```

### 4.2 配置与使用

```yaml
resilience4j:
  ratelimiter:
    configs:
      default:
        limitForPeriod: 1000
        limitRefreshPeriod: 1s
        timeoutDuration: 500ms
    instances:
      # 支付接口限流：每秒 50 次
      paymentRateLimiter:
        limitForPeriod: 50
        limitRefreshPeriod: 1s
        timeoutDuration: 100ms
      # 短信接口限流：每分钟 10 次
      smsRateLimiter:
        limitForPeriod: 10
        limitRefreshPeriod: 1m
        timeoutDuration: 0s  # 超时即拒绝
```

```java
@Service
public class PaymentService {
    
    @RateLimiter(name = "paymentRateLimiter", fallbackMethod = "rateLimitFallback")
    public PaymentResult processPayment(PaymentRequest request) {
        return paymentClient.pay(request);
    }
    
    private PaymentResult rateLimitFallback(PaymentRequest request, 
                                            RequestNotPermitted e) {
        log.warn("支付接口限流触发: {}", request.getOrderId());
        return PaymentResult.builder()
            .success(false)
            .message("系统繁忙，请稍后再试")
            .code("RATE_LIMITED")
            .build();
    }
}
```

## 五、重试(Retry) 实战

### 5.1 智能重试策略

```yaml
resilience4j:
  retry:
    configs:
      default:
        maxRetryAttempts: 3
        waitDuration: 500ms
        # 指数退避
        exponentialBackoffMultiplier: 2
        # 随机等待时间（避免惊群效应）
        enableRandomizedWait: true
        randomizedWaitFactor: 0.5
        # 只重试特定异常
        retryExceptions:
          - org.springframework.web.client.HttpServerErrorException
          - java.net.ConnectException
          - java.util.concurrent.TimeoutException
        # 不重试的异常
        ignoreExceptions:
          - org.springframework.web.client.HttpClientErrorException  # 4xx 不重试
```

```java
@Service
public class NotificationService {
    
    @Retry(name = "smsRetry", fallbackMethod = "retryFallback")
    public void sendSms(String phone, String message) {
        smsClient.send(phone, message);
    }
    
    private void retryFallback(String phone, String message, Throwable t) {
        log.error("短信发送重试全部失败: phone={}, error={}", phone, t.getMessage());
        // 写入失败队列，后续异步重试
        failedSmsQueue.add(new FailedSms(phone, message));
    }
}
```

### 5.2 重试链路追踪

```java
@Configuration
public class RetryConfig {
    
    @Bean
    public RetryListenerCustomizer retryListenerCustomizer() {
        return registry -> registry.getEventPublisher()
            .onRetry(event -> {
                // 记录重试事件到链路追踪
                RetryEvent retryEvent = (RetryEvent) event;
                MDC.put("retryCount", String.valueOf(retryEvent.getNumberOfRetryAttempts()));
                log.warn("Retry attempt #{} for method: {}", 
                    retryEvent.getNumberOfRetryAttempts(),
                    retryEvent.getCreationTime());
                MDC.remove("retryCount");
            })
            .onSuccess(event -> {
                log.info("Retry succeeded after {} attempts", 
                    ((RetryOnSuccessEvent) event).getNumberOfRetryAttempts());
            })
            .onError(event -> {
                log.error("Retry exhausted after {} attempts", 
                    ((RetryOnErrorEvent) event).getNumberOfRetryAttempts());
            });
    }
}
```

## 六、组合使用：限流 + 熔断 + 重试

### 6.1 多层级保护策略

```java
@Service
public class PaymentFacadeService {
    
    // 使用 @Resilience4j 组合注解
    @Bulkhead(name = "paymentBulkhead", type = Bulkhead.Type.THREADPOOL)
    @TimeLimiter(name = "paymentTimeLimiter")
    @CircuitBreaker(name = "paymentService", fallbackMethod = "fallback")
    @RateLimiter(name = "paymentRateLimiter")
    @Retry(name = "paymentRetry")
    public CompletableFuture<PaymentResult> pay(PaymentRequest request) {
        return CompletableFuture.supplyAsync(() -> {
            // 实际支付调用
            return paymentClient.pay(request);
        });
    }
    
    public CompletableFuture<PaymentResult> fallback(
            PaymentRequest request, TimeoutException e) {
        return CompletableFuture.completedFuture(
            PaymentResult.timeout("支付超时，请稍后查询结果"));
    }
}
```

### 6.2 配置优先级

多个组件组合使用时，执行顺序为：

```
Request → Bulkhead → CircuitBreaker → RateLimiter → Retry → TimeLimiter → Target
```

这个顺序是经过精心设计的：
1. **Bulkhead** 最先执行：通过限制并发数保护系统
2. **CircuitBreaker** 其次：快速拒绝已熔断的请求
3. **RateLimiter** 再限流：控制请求速率
4. **Retry** 进行重试：只对通过的请求重试
5. **TimeLimiter** 最后兜底：确保整体超时

## 七、监控与指标

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,metrics,prometheus,circuitbreakers,ratelimiters
      base-path: /actuator

resilience4j:
  circuitbreaker:
    configs:
      default:
        registerHealthIndicator: true
        allowHealthIndicatorToFail: true
```

可以通过 `GET /actuator/circuitbreakers` 获取所有熔断器状态：

```json
{
  "circuitBreakers": {
    "orderService": {
      "state": "HALF_OPEN",
      "failureRate": 35.5,
      "slowCallRate": 12.3,
      "bufferedCalls": 20,
      "failedCalls": 7,
      "successfulCalls": 13
    }
  }
}
```

Resilience4j 是一个精心设计的容错框架，模块化、轻量级、无外部依赖，是 Spring Cloud 微服务容错的首选方案。正确使用断路器、限流器、重试等组件，可以让系统在面对各种故障时保持优雅的降级和服务质量。
