---
title: 【Spring 源码】Spring MVC 异步请求全链路深度解析：DeferredResult、SseEmitter 与 AsyncContext 线程模型
date: 2026-10-28 08:00:00
tags:
  - Java
  - Spring
  - Spring MVC
  - 异步编程
  - 源码
categories:
  - Spring
author: 东哥
---

# 【Spring 源码】Spring MVC 异步请求全链路深度解析

## 前言

绝大多数 Java 后端的接口都是「同步阻塞」模型：Tomcat 的工作线程从收到请求开始，一直占到业务处理完、响应写回为止。这个模型简单可靠，但一旦遇到**慢下游**——第三方 API、大模型调用、报表导出、长轮询——线程就被白白占住。

一个 200 线程的 Tomcat，如果每个请求要等 3 秒的下游，理论吞吐只有 66 QPS，而且稍微来点抖动线程池就满了，后面所有接口一起排队。这不是「加机器」能优雅解决的问题，而是**线程模型**的问题。

Spring MVC 在 Servlet 3.0 之上提供了一整套异步请求能力：`Callable`、`WebAsyncTask`、`DeferredResult`、`ResponseBodyEmitter`、`SseEmitter`、`StreamingResponseBody`。很多人会用，但说不清：

- 异步请求到底在哪个线程上执行？Tomcat 线程什么时候被释放？
- 为什么 `HandlerInterceptor#preHandle` 执行了两次？
- 为什么 `ThreadLocal` 里的用户上下文在异步线程里是 null？
- `DeferredResult` 超时后，业务线程还在跑，结果去哪了？

这篇文章把整条链路拆开讲透。这也是面试里区分「用过 Spring」和「懂 Spring」的高频分水岭。

## 一、Servlet 3.0 的异步模型：AsyncContext 才是根

Spring MVC 的异步,底层就是 Servlet 3.0 的 `AsyncContext`。理解它，后面所有封装都只是语法糖。

同步模型的调用栈：

```
Tomcat Worker Thread
  └─ FilterChain
      └─ DispatcherServlet#doService
          └─ Controller 方法（阻塞 3 秒）
              └─ 返回 ModelAndView
          └─ 视图渲染 / 消息转换
      └─ response.flush()
  └─ 线程归还线程池
```

异步模型的关键动作只有三步：

```java
// 1. 业务线程调用 startAsync()，把 AsyncContext 拿出来
AsyncContext asyncContext = request.startAsync();
asyncContext.setTimeout(3000);

// 2. 立即 return，Tomcat 工作线程归还线程池，但连接不关闭
//    注意：此时 response 还没有提交

// 3. 另一个线程（业务线程池 / MQ 回调 / 事件监听）处理完成后
asyncContext.getResponse().getWriter().write("done");
asyncContext.complete();   // 真正结束请求，连接可以复用
```

这里有两个容易忽略的点：

**第一，`startAsync()` 必须在响应提交之前调用。** 一旦 `response.getWriter().write()` 并且 buffer 被 flush，再调 `startAsync()` 会抛 `IllegalStateException`。这也是为什么 Spring 里如果 Controller 里手动写了 response，异步就失效了。

**第二，异步不等于「不占资源」。** Tomcat 线程释放了，但 **连接（socket）还占着**，`AsyncContext` 对象还占着堆内存。异步提升的是「线程利用率」，不是「连接数上限」。所以长轮询场景下你要担心的不是线程池，而是 `maxConnections` 和文件描述符。

## 二、Spring MVC 的异步封装全景

Spring 把 `AsyncContext` 包装成了 `WebAsyncManager`，并对返回值类型做了适配。常见六种写法，适用场景完全不同：

| 返回值类型 | 谁执行任务 | 谁写响应 | 典型场景 | 是否会重复 dispatch |
|---|---|---|---|---|
| `Callable<T>` | Spring 的 `AsyncTaskExecutor` | Spring | 简单异步，一次性结果 | 是 |
| `WebAsyncTask<T>` | 同上，可指定超时/回调 | Spring | 需要超时与完成回调 | 是 |
| `DeferredResult<T>` | **业务自己**（任意线程） | Spring | 等待外部事件：MQ、RPC 回调、长轮询 | 是 |
| `ListenableFuture<T>` | 提交者 | Spring | 已有异步框架返回 Future | 是 |
| `ResponseBodyEmitter` | 业务线程多次 `send()` | 业务 | 流式推送多条消息 | 否（一次 dispatch） |
| `SseEmitter` | 同上，封装 SSE 协议 | 业务 | 服务端推送、AI 流式输出 | 否 |
| `StreamingResponseBody` | Spring 的 taskExecutor | 业务写 OutputStream | 大文件下载、导出 | 否 |

一个判断口诀：

- **结果是一次性的** → `Callable` / `DeferredResult`
- **结果是多次推送的** → `ResponseBodyEmitter` / `SseEmitter`
- **结果是二进制大流量** → `StreamingResponseBody`

## 三、源码链路：一次异步请求到底发生了什么

### 3.1 第一次 dispatch：识别异步返回值

`DispatcherServlet#doDispatch` 的核心流程没变，关键在于 `HandlerAdapter#handle` 返回值之后：

```java
// RequestMappingHandlerAdapter#invokeHandlerMethod
ServletInvocableHandlerMethod invocableMethod =
        createInvocableHandlerMethod(handlerMethod);
invocableMethod.invokeAndHandle(webRequest, mavContainer);
```

`invokeAndHandle` 内部：

```java
Object returnValue = invokeForRequest(webRequest, mavContainer, providedArgs);

// 关键：AsyncHandlerMethodReturnValueHandler 在这里接管
this.returnValueHandlers.handleReturnValue(
        returnValue, getReturnValueType(returnValue), mavContainer, webRequest);
```

对于 `DeferredResult`，`DeferredResultMethodReturnValueHandler` 会调用：

```java
WebAsyncUtils.getAsyncManager(webRequest)
        .startDeferredResultProcessing(deferredResult, mavContainer);
```

这一步做了三件很重要的事：

1. `WebAsyncManager#startAsyncProcessing` 调用 `request.startAsync()`，并把 `AsyncContext` 存进 `asyncContext`；
2. 把 `DeferredResult` 注册到 `WebAsyncManager`，并设置超时回调；
3. 返回 `mavContainer.setRequestHandled(true)`，告诉 DispatcherServlet「这个请求我已经接管了，别往下走视图渲染」。

`WebAsyncManager` 的源码简化后：

```java
public void startDeferredResultProcessing(DeferredResult<?> deferredResult,
        Object... processingContext) throws Exception {
    Assert.notNull(deferredResult, "DeferredResult must not be null");
    Assert.state(this.asyncWebRequest != null, "AsyncWebRequest must not be null");

    Long timeout = deferredResult.getTimeoutValue();
    if (timeout != null) {
        this.asyncWebRequest.setTimeout(timeout);
    }

    // 拦截器：AsyncHandlerInterceptor#afterConcurrentHandlingStarted
    List<DeferredResultProcessingInterceptor> interceptors = new ArrayList<>();
    interceptors.add(deferredResult.getInterceptor());
    interceptors.addAll(this.deferredResultInterceptors.values());
    interceptors.add(timeoutDeferredResultInterceptor);

    DeferredResultInterceptorChain chain = new DeferredResultInterceptorChain(interceptors);
    chain.applyBeforeConcurrentHandling(this.asyncWebRequest, deferredResult);
    registerDeferredResultInterceptors(chain);

    // 关键：超时回调
    this.asyncWebRequest.addTimeoutHandler(() -> {
        deferredResult.setResultInternal(null);   // 触发 onTimeout
    });

    // 错误回调
    this.asyncWebRequest.addErrorHandler(ex -> {
        deferredResult.setErrorResult(ex);
    });

    // 业务线程 setResult 时，触发 dispatch 回容器
    deferredResult.setResultHandler(result -> {
        result = interceptorChain.applyPostProcess(this.asyncWebRequest, deferredResult, result);
        setConcurrentResultAndDispatch(result);
    });

    // 如果业务已经 setResult 了（race），立即处理
    if (deferredResult.isSetOrExpired()) {
        setConcurrentResultAndDispatch(deferredResult.getResult());
    }
}
```

注意最后的 `isSetOrExpired()` 判断：**业务线程可能在 `startDeferredResultProcessing` 还没执行完就已经 `setResult()` 了**（比如 MQ 回包极快）。这个 race 处理是很多手写异步框架会漏的坑，漏了就会「结果丢了、请求一直挂着直到超时」。

### 3.2 释放 Tomcat 线程

第一次 dispatch 结束时，`DispatcherServlet` 检测到异步已启动，直接 return，不再走 `processDispatchResult` 的视图渲染：

```java
// FrameworkServlet#doService 之后，doDispatch 的 finally
if (asyncManager.isConcurrentHandlingStarted()) {
    // 不调用 cleanupMultipartFiles 之外的收尾工作，直接返回
    return;
}
```

Tomcat 检测到 `AsyncContext` 已开启，工作线程归还线程池，但 **socket 保持打开**，请求进入 `asyncSupported` 状态。

### 3.3 第二次 dispatch：把结果写回

业务线程 `deferredResult.setResult(value)` 之后，`setConcurrentResultAndDispatch` 会调用 `asyncContext.dispatch()`。容器会**重新走一遍 Filter 链和 DispatcherServlet**，这次 `request.getAttribute(WebAsyncManager.CONCURRENT_RESULT_ATTRIBUTE)` 里已经有结果了。

第二次 dispatch 走到 `RequestMappingHandlerAdapter#invokeHandlerMethod` 时，因为 `mavContainer` 已经标记 handled，直接执行 `handleReturnValue` 写响应：

```java
if (!mavContainer.isRequestHandled()) {
    // 正常路径
}
// 异步路径：concurrentResult 已存在，走 processDispatchResult
```

这就解释了一个经典现象：**Filter 和 Interceptor 的 `preHandle` 会被执行两次**。

- 第一次是原始请求；
- 第二次是 ASYNC dispatch，`DispatcherType` 是 `ASYNC`。

如果你在 `preHandle` 里做了「请求计数」「幂等校验」「限流」，就会**重复计数**。正确做法：

```java
@Override
public boolean preHandle(HttpServletRequest request,
        HttpServletResponse response, Object handler) {
    if (DispatcherType.ASYNC.equals(request.getDispatcherType())) {
        return true;   // 异步回派，跳过业务前置逻辑
    }
    // 幂等、限流、鉴权……
    return true;
}
```

同时在 `web.xml` / `FilterRegistrationBean` 里给 Filter 加上 `asyncSupported=true`，否则第二次 dispatch 会抛 `IllegalStateException: It is illegal to call this method if the current request is not in asynchronous mode`。

## 四、线程池：异步请求的真实瓶颈所在

`Callable` 用的是 `WebAsyncManager` 里的 `AsyncTaskExecutor`。默认情况下 Spring Boot 会注入 `applicationTaskExecutor`，而它的默认值非常「朴素」：

```java
// TaskExecutionAutoConfiguration
ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
executor.setCorePoolSize(8);
executor.setMaxPoolSize(Integer.MAX_VALUE);   // 无界！
executor.setQueueCapacity(Integer.MAX_VALUE); // 无界！
```

**无界队列 + 无界最大线程数**，意味着「不拒绝、不扩容」——所有任务在队列里排队，`maxPoolSize` 永远用不到。下游变慢时表现就是：接口不报错，延迟线性上涨，内存持续增长，最后 Full GC 或 OOM。

必须显式配置：

```java
@Configuration
public class AsyncConfig implements WebMvcConfigurer {

    @Bean("mvcAsyncExecutor")
    public AsyncTaskExecutor mvcAsyncExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(32);
        executor.setMaxPoolSize(64);
        executor.setQueueCapacity(200);          // 有界，触发拒绝
        executor.setKeepAliveSeconds(60);
        executor.setThreadNamePrefix("mvc-async-");
        executor.setRejectedExecutionHandler(
                new ThreadPoolExecutor.CallerRunsPolicy()); // 背压给容器线程
        executor.initialize();
        return executor;
    }

    @Override
    public void configureAsyncSupport(AsyncSupportConfigurer configurer) {
        configurer.setTaskExecutor(mvcAsyncExecutor());
        configurer.setDefaultTimeout(5000);       // 统一默认超时
    }
}
```

关于拒绝策略：异步 Web 场景我更倾向 `CallerRunsPolicy`。它让 Tomcat 线程自己跑任务，相当于**把压力反向传导给上游**（连接堆积 → 负载均衡摘除），比直接抛 `RejectedExecutionException` 给用户一个 500 更可控。

`DeferredResult` 则完全不碰这个线程池——它由业务线程 `setResult`。这时候真正要治理的是**你自己的业务线程池 / MQ 消费线程数**。

## 五、四个必踩的坑

### 5.1 ThreadLocal 上下文丢失

`Callable` 是在另一个线程执行的，`ThreadLocal` 天然拿不到：

```java
// ❌ 错误：异步线程里 UserContext 是 null
@GetMapping("/orders")
public Callable<List<Order>> orders() {
    Long userId = UserContext.getUserId();   // 在 Tomcat 线程读，安全
    return () -> orderService.listByUser(UserContext.getUserId()); // 异步线程读，null
}
```

两种修法：

```java
// ✅ 方案一：在主线程取值，闭包捕获
@GetMapping("/orders")
public Callable<List<Order>> orders() {
    Long userId = UserContext.getUserId();
    return () -> orderService.listByUser(userId);
}

// ✅ 方案二：用 TaskDecorator 传递上下文
public class ContextCopyingDecorator implements TaskDecorator {
    @Override
    public Runnable decorate(Runnable runnable) {
        String traceId = MDC.get("traceId");
        Long userId = UserContext.getUserId();
        return () -> {
            try {
                MDC.put("traceId", traceId);
                UserContext.setUserId(userId);
                runnable.run();
            } finally {
                UserContext.clear();
                MDC.clear();
            }
        };
    }
}
```

`TaskDecorator` 一定要配 `finally` 清理，否则线程复用时会串号——这是排查「A 用户看到 B 用户数据」类事故的第一嫌疑点。

### 5.2 `DeferredResult` 超时后结果丢失

```java
DeferredResult<Result> dr = new DeferredResult<>(3000L);
dr.onTimeout(() -> log.warn("timeout"));
dr.onCompletion(() -> log.info("done"));

// 3.5 秒后业务线程才回包
executor.execute(() -> dr.setResult(Result.ok()));
```

`setResult()` 不会报错，但结果**直接被丢弃**（内部 `isSetOrExpired()` 为 true 时静默返回 false）。如果这是支付回调 / 订单状态同步，就等于**丢消息**。

正确姿势是把「请求超时」和「业务完成」解耦：超时只代表「这次 HTTP 不等待了」，业务结果必须落库或发 MQ，让客户端轮询/推送补偿。**永远不要把 DeferredResult 当成消息可靠通道。**

### 5.3 SseEmitter 忘记 complete 导致连接泄漏

```java
@GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public SseEmitter stream() {
    SseEmitter emitter = new SseEmitter(0L);   // 0 = 永不超时
    emitter.onCompletion(() -> registry.remove(emitter));
    emitter.onTimeout(() -> { emitter.complete(); registry.remove(emitter); });
    registry.add(emitter);
    return emitter;
}
```

`timeout=0` 表示永不超时，如果客户端异常断开而你没监听 `onError`，这个 emitter 会永久留在 `registry` 里——典型的**连接与内存双泄漏**。生产上必须有：心跳（每 15~30 秒发一次 comment）、前端断线重连、服务端定时清理僵尸连接。

另外注意：`SseEmitter` 的 `send()` 是**非线程安全**的，多个线程同时推会抛 `IllegalStateException`。要么加锁，要么每个 emitter 配一个单线程队列。

### 5.4 Filter 没开 asyncSupported

Spring Boot 里注册 Filter 必须显式声明：

```java
@Bean
public FilterRegistrationBean<TraceFilter> traceFilter() {
    FilterRegistrationBean<TraceFilter> bean = new FilterRegistrationBean<>();
    bean.setFilter(new TraceFilter());
    bean.addUrlPatterns("/*");
    bean.setAsyncSupported(true);   // 不写就默认 false
    return bean;
}
```

漏了这行，第一次 dispatch 正常，异步回派时直接 500。而且报错信息很不直观，容易查半天。

## 六、Spring MVC 异步 vs WebFlux：别再混着讲

| 维度 | Spring MVC 异步 | Spring WebFlux |
|---|---|---|
| 底层 | Servlet 3.1 AsyncContext | Reactor Netty / Servlet 3.1 适配 |
| 编程模型 | 命令式，返回值包装 | 声明式，`Mono`/`Flux` |
| 线程模型 | 业务线程池（仍是一请求一线程的变体） | 事件循环，少量线程 |
| 背压 | 不支持（`SseEmitter` 靠 TCP 缓冲） | 原生支持 `request(n)` |
| 阻塞代码 | 可放心阻塞 | 严禁阻塞，必须 `subscribeOn(boundedElastic)` |
| 适用 | 已有 Spring MVC 项目做局部异步 | 网关、流式、高并发 IO 密集 |

一句话总结：**Spring MVC 异步是「把等待挪到别的线程」，WebFlux 是「根本不需要那个线程」**。前者的线程数上限依然是天花板，后者才是真正的伸缩性提升。

如果只是接一个大模型流式接口，`SseEmitter` 完全够用，别为了「技术先进」把整个项目改成 WebFlux——那通常是一场灾难。

## 七、面试高频追问

**Q1：异步请求能提升吞吐吗？**

能，但只对 **IO 等待占比高** 的场景。如果接口是 CPU 密集型，异步只是把任务从一个队列挪到另一个队列，总吞吐不变，还多了线程切换和两次 dispatch 的开销。

**Q2：`DeferredResult` 和 `Callable` 的本质区别？**

`Callable` 由 Spring 提交到 `AsyncTaskExecutor` 执行，你无法控制执行线程；`DeferredResult` 只提供一个「结果容器」，什么时候 `setResult`、在哪个线程 `setResult` 完全由你决定。所以跨系统回调、MQ 驱动、长轮询只能用 `DeferredResult`。

**Q3：异步请求超时后，Tomcat 会断开连接吗？**

会。`AsyncContext` 超时后容器会走 error dispatch，最终响应 503（可配置）。但**业务线程不会被中断**——Java 没有安全的线程抢占式中断，`Thread.interrupt()` 也只是协作式的。这就是为什么超时后必须靠落库/MQ 做状态补偿。

**Q4：为什么 `@Transactional` 在异步方法里不生效？**

两个原因：一是 `@Async` 方法内部调用（自调用）不走代理；二是事务绑定在 `ThreadLocal`（`TransactionSynchronizationManager`），异步线程是新的连接和事务上下文。跨线程的事务只能靠「业务补偿 / 本地消息表 / Seata」这类分布式事务方案。

**Q5：`SseEmitter` 和 WebSocket 怎么选？**

只用服务端单向推送 → SSE（HTTP 原生、自动重连、过代理友好）；需要双向通信 → WebSocket。AI 流式输出几乎都选 SSE，因为实现简单且对网关/负载均衡友好。

## 八、生产 checklist

- [ ] 所有异步接口显式设置超时（`setDefaultTimeout`），不要依赖容器默认 30 秒
- [ ] 异步线程池**队列有界** + 有意义的线程名前缀（便于 jstack 定位）
- [ ] `TaskDecorator` 传递并清理 `ThreadLocal` / MDC
- [ ] Filter/Interceptor 判断 `DispatcherType.ASYNC`，避免重复执行业务逻辑
- [ ] 所有 Filter 注册 `asyncSupported=true`
- [ ] `SseEmitter` 有 `onCompletion` / `onTimeout` / `onError` 三件套 + 心跳
- [ ] 监控指标：异步任务队列长度、活跃 emitter 数、超时率、dispatch 耗时
- [ ] 超时后的业务结果**必须**有落库/MQ 兜底，不能依赖请求本身

## 结语

Spring MVC 的异步能力不复杂，复杂的是它把「一个请求」拆成了「两次 dispatch + 两个线程 + 一个共享的并发结果容器」，每一处衔接都可能出问题。

理解 `AsyncContext` 这个根，再看 `WebAsyncManager` 的三个回调（timeout / error / result handler），整条链路就通了。真正上线前，把线程池、超时、上下文传递、连接清理这四件事做对，异步才不是「把 bug 藏得更深」。
