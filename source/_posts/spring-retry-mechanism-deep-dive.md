---
title: 【Spring实战】Spring Retry 重试机制深度解析：从 @Retryable 到源码级原理
date: 2026-07-06 08:00:00
tags:
  - Java
  - Spring
  - Spring Boot
  - 重试
  - 容错
categories:
  - Java
  - Spring
author: 东哥
---

# Spring Retry 重试机制深度解析

## 一、引言

在分布式系统中，网络抖动、服务暂时不可用、数据库锁冲突等瞬时故障是常态。**自动重试（Retry）** 是一种简单有效的容错策略——在操作失败时自动重新执行，直到成功或达到上限。

Spring Retry 是 Spring 生态中专门处理重试逻辑的框架，支持声明式（`@Retryable` 注解）和编程式（`RetryTemplate`）两种方式。本文将从使用到源码，全面解析其实现原理。

---

## 二、快速上手

### 2.1 依赖引入

```xml
<dependency>
    <groupId>org.springframework.retry</groupId>
    <artifactId>spring-retry</artifactId>
</dependency>
<!-- 需要 AOP 支持 -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-aop</artifactId>
</dependency>
```

### 2.2 启用重试

```java
@Configuration
@EnableRetry  // 开启声明式重试支持
public class RetryConfig {
}
```

### 2.3 @Retryable 基本使用

```java
@Service
public class OrderService {
    
    private static final Logger log = LoggerFactory.getLogger(OrderService.class);
    
    @Retryable(
        retryFor = {RemoteAccessException.class, TimeoutException.class},
        maxAttempts = 3,
        backoff = @Backoff(delay = 1000, multiplier = 2.0)
    )
    public Order createOrder(OrderRequest request) {
        log.info("尝试创建订单...");
        // 调用远程服务，可能抛出 RemoteAccessException
        return remoteOrderService.create(request);
    }
    
    @Recover  // 所有重试都失败后调用
    public Order recover(RemoteAccessException e, OrderRequest request) {
        log.error("创建订单失败，进入降级处理", e);
        return Order.fallback(request, "重试失败，已降级");
    }
}
```

**执行流程**：
1. 方法抛出 `RemoteAccessException`
2. 等待 1 秒后重试（delay=1000）
3. 再次失败，等待 2 秒（multiplier=2.0）
4. 第三次失败，不再重试
5. 调用 `@Recover` 方法返回降级结果

---

## 三、核心概念与配置

### 3.1 @Retryable 注解属性

| 属性 | 类型 | 默认值 | 说明 |
|:----|:---:|:-----:|:----|
| value / retryFor | Class[] | {} | 需要重试的异常类型 |
| noRetryFor | Class[] | {} | 不需要重试的异常类型 |
| maxAttempts | int | 3 | 最大重试次数（包含第一次） |
| backoff | @Backoff | — | 退避策略 |
| listeners | String[] | {} | RetryListener 的 bean 名称 |
| recover | String | "recover" | @Recover 方法名 |
| exceptionExpression | String | "" | SpEL 表达式过滤异常 |
| stateful | boolean | false | 是否为有状态重试 |

### 3.2 @Backoff 退避策略

```java
@Backoff(delay = 1000)                         // 固定间隔 1 秒
@Backoff(delay = 1000, multiplier = 2.0)       // 指数退避：1s → 2s → 4s
@Backoff(delay = 1000, maxDelay = 30000)       // 最大退避不超过 30s
@Backoff(delay = 1000, multiplier = 2.0, random = true)  // 指数退避 + 随机抖动
```

**退避策略详解**：

| 策略 | 实现类 | 说明 |
|:----|:-----:|:----|
| 固定间隔 | FixedBackOffPolicy | 每次等待固定时长 |
| 指数退避 | ExponentialBackOffPolicy | 每次等待间隔指数增长 |
| 均匀指数退避 | ExponentialRandomBackOffPolicy | 指数退避 + 随机抖动 |
| 无等待 | NoBackOffPolicy | 立即重试 |
| 自定义 | — | 实现 BackOffPolicy 接口 |

### 3.3 使用 RetryTemplate（编程式重试）

```java
@Service
public class PaymentService {
    
    private final RetryTemplate retryTemplate;
    
    public PaymentService() {
        // 构建 RetryTemplate
        this.retryTemplate = RetryTemplate.builder()
            .maxAttempts(3)
            .exponentialBackoff(1000, 2.0, 10000)
            .retryOn(RemoteAccessException.class)
            .withListener(new RetryListenerSupport() {
                @Override
                public <T, E extends Throwable> void onError(
                        RetryContext context, 
                        RetryCallback<T, E> callback, 
                        Throwable throwable) {
                    System.out.println("第 " + context.getRetryCount() + " 次重试");
                }
            })
            .build();
    }
    
    public void processPayment(PaymentRequest req) {
        retryTemplate.execute(ctx -> {
            // 重试的执行体
            return paymentClient.process(req);
        }, ctx -> {
            // 回退方法（所有重试都失败）
            log.error("支付处理失败", ctx.getLastThrowable());
            return fallbackResult(req);
        });
    }
}
```

---

## 四、源码深度解析

### 4.1 AOP 拦截器链

`@EnableRetry` 注解导入 `RetryConfiguration`，核心是注册了一个 `BeanPostProcessor`：

```java
@Configuration
public class RetryConfiguration extends AbstractPointcutAdvisor
        implements IntroductionAdvisor, BeanFactoryAware {

    @Bean
    @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
    public RetryOperationsInterceptor retryOperationsInterceptor() {
        RetryOperationsInterceptor interceptor = new RetryOperationsInterceptor();
        // 配置 RetryTemplate 等
        return interceptor;
    }
    
    // 通过 AOP 自动代理，拦截 @Retryable 注解的方法
    @Override
    public Advice getAdvice() {
        return interceptor;
    }
}
```

### 4.2 RetryOperationsInterceptor

这是 AOP 拦截器的核心：

```java
public class RetryOperationsInterceptor implements MethodInterceptor {
    
    private RetryOperations retryOperations;  // 实际是 RetryTemplate
    
    @Override
    public Object invoke(MethodInvocation invocation) throws Throwable {
        // 获取方法的 Retry 元数据
        Method method = invocation.getMethod();
        // 构建 RetryCallback，将方法调用包装进来
        RetryCallback<Object, Throwable> callback = retryCallback(invocation);
        // 获取 RecoveryCallback（@Recover 方法）
        RecoveryCallback<Object> recoveryCallback = recoveryCallback(invocation, attribute);
        
        // 用 RetryTemplate 执行
        return retryOperations.execute(callback, recoveryCallback, retryContext);
    }
}
```

### 4.3 RetryTemplate.execute() 核心逻辑

```java
public final <T, E extends Throwable> T execute(
        RetryCallback<T, E> retryCallback,
        RecoveryCallback<T> recoveryCallback,
        RetryState state) throws E {
    
    RetryContext context = open(state);
    context.setAttribute(RetryContext.NAME, name);
    
    // 1. 前置通知
    doOpenInterceptors(retryCallback, context);
    
    Throwable lastException = null;
    boolean exhausted = false;
    
    try {
        // 2. 核心重试循环
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            // 检查是否要强制终止（有状态重试时会用到）
            if (canRetry(context, state)) {
                try {
                    // 重试前的退避等待
                    if (attempt > 1) {
                        backOffPolicy.backOff(context);
                    }
                    
                    // 执行目标方法
                    return retryCallback.doWithRetry(context);
                    
                } catch (Throwable e) {
                    // 注册异常信息
                    lastException = e;
                    context.registerThrowable(e);
                    
                    // 中置通知
                    doOnErrorInterceptors(callback, context, e);
                    
                    // 检查是否还能继续重试
                    if (canRetry(context, state) && !isExhausted(context)) {
                        // 继续循环，执行下一次重试
                        continue;
                    }
                    
                    // 检查是否需要重新抛出
                    if (shouldRethrow(context, state)) {
                        throw Retryable.wrap(e);
                    }
                    
                    exhausted = true;
                    break;
                }
            }
        }
        
        // 3. 所有重试都失败，调用 recovery 回调
        if (recoveryCallback != null) {
            return recoveryCallback.recover(context);
        }
        
        // 没有 recovery 回调，直接抛出最后一次异常
        throw Retryable.wrap((Throwable) lastException);
        
    } finally {
        // 4. 关闭拦截器
        doCloseInterceptors(retryCallback, context, lastException != null);
        close(state);
    }
}
```

**关键流程**：
1. 在重试次数范围内，每次调用 `retryCallback.doWithRetry()` 尝试执行目标方法
2. 如果抛出异常，检查能否继续重试
3. 在两次重试之间执行 `backOffPolicy.backOff(context)` 进行退避等待
4. 重试次数耗尽后调用 `RecoveryCallback`
5. 如果没有 recovery 回调，则抛出原始异常

### 4.4 退避策略实现

以 `ExponentialBackOffPolicy` 为例：

```java
public class ExponentialBackOffPolicy extends DefaultBackOffPolicy {
    
    private long initialInterval = 100;        // 初始间隔 100ms
    private double multiplier = 2.0;           // 倍数
    private long maxInterval = 30000;           // 最大间隔 30s
    
    @Override
    protected BackOffContext createBackOffContext(RetryContext context) {
        return new ExponentialBackOffContext(initialInterval, multiplier, maxInterval);
    }
    
    public static class ExponentialBackOffContext implements BackOffContext {
        
        private long interval;
        private final double multiplier;
        private final long maxInterval;
        
        @Override
        public synchronized long getSleepAndIncrement() {
            long sleep = this.interval;
            // 计算下一次间隔
            if (sleep > maxInterval) {
                sleep = maxInterval;
            } else {
                // 指数增长
                this.interval = (long) (this.interval * this.multiplier);
            }
            return sleep;
        }
    }
}
```

**计算公式**：`sleep = initialInterval * multiplier^(retryCount-1)`

即：重试第 1 次等待 100ms，第 2 次等待 200ms，第 3 次等待 400ms...直到达到 `maxInterval`。

### 4.5 @Recover 方法的匹配机制

```java
public class RecoveryCallbackProvider {
    
    // 收集被 @Recover 标记的方法
    private List<Method> recoveryMethods = new ArrayList<>();
    
    // 匹配逻辑
    public Method findRecoveryMethod(Method method, Throwable exception) {
        for (Method recoveryMethod : recoveryMethods) {
            Class<?>[] paramTypes = recoveryMethod.getParameterTypes();
            // 规则：第一个参数必须是异常类型，且与当前异常类型匹配
            if (paramTypes.length > 0 && 
                paramTypes[0].isAssignableFrom(exception.getClass())) {
                // 方法返回类型必须与原方法兼容
                if (recoveryMethod.getReturnType() == method.getReturnType()) {
                    return recoveryMethod;
                }
            }
        }
        throw new NoSuchMethodException("No recovery method found");
    }
}
```

**匹配规则**：
1. 与 `@Retryable` 方法在**同一个类**中
2. 方法签名：`(Throwable exception, [原方法参数...])`
3. 返回类型与原方法一致
4. 第一个参数是异常类型，用于匹配具体异常

---

## 五、高级用法

### 5.1 条件重试（SpEL 表达式）

```java
@Retryable(
    retryFor = {BusinessException.class},
    exceptionExpression = "#{#root.message.contains('超时')}",
    maxAttempts = 5
)
public void processOrder(String orderId) {
    // 只有异常消息包含 "超时" 时才重试
}
```

### 5.2 有状态重试（Stateful Retry）

```java
@Retryable(stateful = true)
public void deductInventory(String skuId, int quantity) {
    // 幂等性操作：重试时需要恢复到之前的状态
    // 适用于 AT-least-once 语义的场景
}
```

有状态重试会为每个请求维护一个 `RetryContext`，确保同一请求的多次重试共享上下文。通常配合 `RetryStateCache` 使用。

### 5.3 自定义 RetryListener

```java
@Component
public class LoggingRetryListener implements RetryListener {
    
    @Override
    public <T, E extends Throwable> boolean open(
            RetryContext context, RetryCallback<T, E> callback) {
        System.out.println("开始重试: " + callback);
        return true;  // 返回 true 表示继续重试，false 直接放弃
    }
    
    @Override
    public <T, E extends Throwable> void onError(
            RetryContext context, RetryCallback<T, E> callback, 
            Throwable throwable) {
        System.out.println("重试失败 (" + context.getRetryCount() + "): " 
            + throwable.getMessage());
    }
    
    @Override
    public <T, E extends Throwable> void close(
            RetryContext context, RetryCallback<T, E> callback, 
            Throwable throwable) {
        System.out.println("重试结束: ");
        if (throwable != null) {
            System.out.println("最终失败: " + throwable.getMessage());
        } else {
            System.out.println("重试成功");
        }
    }
}
```

在 `@Retryable` 中引用：

```java
@Retryable(
    retryFor = {RemoteAccessException.class},
    listeners = {"loggingRetryListener"}  // Bean 名称
)
```

### 5.4 在 RestTemplate 中使用

```java
@Configuration
public class RestTemplateConfig {
    
    @Bean
    public RestTemplate restTemplate() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(3000);
        factory.setReadTimeout(5000);
        
        RestTemplate restTemplate = new RestTemplate(factory);
        
        // 使用 RetryTemplate 包装
        RetryTemplate retryTemplate = RetryTemplate.builder()
            .maxAttempts(3)
            .exponentialBackoff(1000, 2, 10000)
            .retryOn(SocketException.class, TimeoutException.class)
            .build();
        
        // 通过 Interceptor 实现重试
        restTemplate.getInterceptors().add((request, body, execution) -> {
            return retryTemplate.execute(ctx -> execution.execute(request, body));
        });
        
        return restTemplate;
    }
}
```

---

## 六、最佳实践与避坑

### 6.1 @Retryable 的限制

```java
// ❌ 错误：内部方法调用不会触发重试
@Service
public class OrderService {
    
    public void create() {
        // 同类内部的 doCreate() 调用不经过 AOP 代理
        doCreate();  // 即使 doCreate 有 @Retryable 也不会执行重试！
    }
    
    @Retryable
    public void doCreate() { ... }
}
```

**解决方案**：
1. 将 `@Retryable` 方法放在单独的被 `@Service` 注入的 Bean 中
2. 使用 `@Autowired` 注入自身代理（但要注意循环依赖问题）

### 6.2 事务与重试的顺序

```java
// ❌ 可能导致事务不回滚
@Service
public class OrderService {
    
    @Transactional
    @Retryable  // AOP 顺序问题！
    public void createOrder() {
        // 事务先开启，然后重试
        // 如果前一次重试已经修改了数据库，重试时可能造成数据重复
    }
}
```

**正确处理**：重试在外层，事务在内层

```java
// ✅ 正确：重试包围事务
@Service
public class OrderService {
    
    @Retryable
    public void createOrder() {
        innerCreateOrder();  // 内部方法使用 @Transactional
    }
    
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void innerCreateOrder() {
        // 每次重试都在新事务中执行
    }
}
```

### 6.3 幂等性设计

重试机制要求被调用的方法**必须幂等**——多次执行与一次执行的结果相同。

```java
// ✅ 幂等设计：使用唯一键防止重复
@Retryable
public void processPayment(String paymentId, BigDecimal amount) {
    // 先检查是否已经处理过
    if (paymentRepository.existsByPaymentId(paymentId)) {
        return;  // 已处理，直接返回
    }
    // 执行支付处理
    paymentRepository.save(new Payment(paymentId, amount));
}
```

### 6.4 监控与告警

重试不应该"静默"地修复所有问题。当重试发生时，应该有监控：

```java
@Component
public class MonitoringRetryListener extends RetryListenerSupport {
    
    private final MeterRegistry meterRegistry;
    
    @Override
    public <T, E extends Throwable> void onError(
            RetryContext context, RetryCallback<T, E> callback, 
            Throwable throwable) {
        // 记录重试 metrics
        meterRegistry.counter("retry.attempts", 
            "class", callback.getLabel(),
            "exception", throwable.getClass().getSimpleName()
        ).increment();
        
        // 如果已经是最后一次重试，发出告警
        if (context.getRetryCount() >= getMaxAttempts() - 1) {
            meterRegistry.counter("retry.exhausted").increment();
            log.error("重试耗尽: {}", callback.getLabel(), throwable);
        }
    }
}
```

---

## 七、总结

| 功能 | 实现方式 | 说明 |
|:----|:-------:|:----|
| 声明式重试 | @Retryable | 注解方式，简洁优雅 |
| 编程式重试 | RetryTemplate | 灵活可控，适合复杂场景 |
| 退避策略 | @Backoff / BackOffPolicy | 固定/指数/随机退避 |
| 降级处理 | @Recover | 重试耗尽后的 fallback |
| 条件重试 | exceptionExpression | SpEL 精确控制重试条件 |
| 有状态重试 | stateful=true | 共享重试上下文 |
| 监听器 | RetryListener | 重试生命周期回调 |
| 重试排除 | noRetryFor | 指定不重试的异常 |

Spring Retry 的核心设计思路就是**将重试逻辑与业务逻辑分离**，通过 AOP 拦截器和模板方法模式优雅地实现了可重用的重试能力。理解其源码有助于我们在实际项目中正确地使用它，避免常见的陷阱。
