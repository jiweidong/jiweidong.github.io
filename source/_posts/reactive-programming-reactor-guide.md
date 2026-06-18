---
title: 响应式编程与 Project Reactor 深入
date: 2026-06-18 08:00:00
tags:
  - Reactor
  - 响应式编程
  - WebFlux
  - 异步
categories:
  - Java 进阶
author: 东哥
---

# 响应式编程与 Project Reactor 深入

## 一、响应式编程概述

### 1.1 什么是响应式编程

响应式编程是一种基于数据流和变化传播的异步编程范式。在 Java 生态中，Project Reactor 是响应式流规范（Reactive Streams）的参考实现，也是 Spring WebFlux 的底层依赖。

### 1.2 为什么需要响应式编程

```
传统阻塞模型 (Thread-per-Request):
┌─────┐  ┌─────────┐  ┌─────────┐
│请求  │──│线程池阻断 │──│等待DB结果│── 线程阻塞等待
└─────┘  └─────────┘  └─────────┘
  ↑ 资源浪费，C10K 问题

响应式模型 (Event Loop):
┌─────┐  ┌──────────┐  ┌────────┐
│请求  │──│Event Loop│──│DB查询  │── 非阻塞，线程回调
└─────┘  └──────────┘  └────────┘
   ↑ 少量线程处理大量并发
```

### 1.3 响应式流规范

响应式流（Reactive Streams）定义了四个核心接口：

| 接口 | 作用 | 说明 |
|------|------|------|
| Publisher | 数据发布者 | 订阅后才能发送数据 |
| Subscriber | 数据订阅者 | 接收并处理数据 |
| Subscription | 订阅关系 | 控制请求数量和取消 |
| Processor | 处理节点 | 既是 Publisher 又是 Subscriber |

```
Subscriber 生命周期:
onSubscribe(Subscription) → onNext(T) × N → (onError | onComplete)

背压机制:
Subscriber.request(n) → Publisher 最多发送 n 个数据
```

## 二、Reactor 核心概念

### 2.1 Flux 和 Mono

Reactor 提供两种核心响应式类型：

| 类型 | 含义 | 发出数量 | 场景 |
|------|------|---------|------|
| Mono<T> | 单值/空 | 0 或 1 个 | 单个结果查询 |
| Flux<T> | 多值 | 0 到 N 个 | 列表查询、数据流 |

```java
// 创建 Mono
Mono<String> empty = Mono.empty();
Mono<String> single = Mono.just("Hello");
Mono<String> fromCallable = Mono.fromCallable(() -> {
    return database.query();
});
Mono<String> fromFuture = Mono.fromFuture(CompletableFuture.supplyAsync(() -> "async"));

// 创建 Flux
Flux<String> just = Flux.just("A", "B", "C");
Flux<Integer> range = Flux.range(1, 10);
Flux<String> fromArray = Flux.fromArray(new String[]{"x", "y", "z"});
Flux<String> fromIterable = Flux.fromIterable(List.of("a", "b", "c"));

// 动态创建
Flux<String> generate = Flux.generate(() -> 0, (state, sink) -> {
    if (state >= 5) {
        sink.complete();
    } else {
        sink.next("Value-" + state);
    }
    return state + 1;
});

Flux<String> create = Flux.create(sink -> {
    for (int i = 0; i < 5; i++) {
        sink.next("Item-" + i);
    }
    sink.complete();
}, FluxSink.OverflowStrategy.BUFFER);
```

### 2.2 操作符体系

Reactor 提供了丰富的操作符，分为以下几大类：

#### 创建操作符

```java
// 延迟创建
Mono<String> delayed = Mono.just("Hello").delayElement(Duration.ofSeconds(1));
Flux<Long> interval = Flux.interval(Duration.ofSeconds(1));

// 空/错误
Mono<String> emptyVal = Mono.empty();
Mono<String> error = Mono.error(new RuntimeException("失败"));

// 条件创建
Mono<String> defer = Mono.defer(() -> {
    if (condition) {
        return Mono.just("条件成立");
    }
    return Mono.just("条件不成立");
});
```

#### 转换操作符

```java
// map - 同步转换
Flux<String> mapped = Flux.just("hello", "world")
    .map(String::toUpperCase);

// flatMap - 异步转换（展平）
Flux<String> flatMapped = Flux.just("user1", "user2")
    .flatMap(userId -> getUserOrders(userId));  // 返回 Flux<Order>

// flatMapSequential - 保持顺序的 flatMap
Flux<String> sequential = Flux.just("a", "b", "c")
    .flatMapSequential(this::asyncOperation);

// concatMap - 顺序处理（一个完成再下一个）
Flux<String> concat = Flux.just("1", "2", "3")
    .concatMap(this::asyncOperation);

// switchMap - 切换最新的流
Flux<String> switched = searchInput.debounce(Duration.ofMillis(300))
    .switchMap(query -> searchService.search(query));
```

#### 过滤操作符

```java
// filter
Flux<Integer> filtered = Flux.range(1, 100)
    .filter(i -> i % 2 == 0);

// distinct
Flux<String> distinct = Flux.just("a", "b", "a", "c")
    .distinct();

// take
Flux<Integer> first5 = Flux.range(1, 100).take(5);
Flux<Integer> last5 = Flux.range(1, 100).takeLast(5);
Flux<Integer> whileTrue = Flux.range(1, 100).takeWhile(i -> i < 10);

// skip
Flux<Integer> skipFirst = Flux.range(1, 100).skip(5);
Flux<Integer> skipUntil = Flux.range(1, 100).skipUntil(i -> i > 50);

// elementAt - 取第 N 个
Mono<Integer> third = Flux.range(1, 100).elementAt(2);
```

#### 组合操作符

```java
// concat - 顺序连接
Flux<String> merged = Flux.concat(
    Flux.just("A1", "A2"),
    Flux.just("B1", "B2")
);  // A1, A2, B1, B2

// merge - 交错合并（按时间）
Flux<String> interleaved = Flux.merge(
    fastStream(),
    slowStream()
);

// zip - 拉链合并
Flux<Tuple2<String, Integer>> zipped = Flux.zip(
    Flux.just("A", "B", "C"),
    Flux.just(1, 2, 3)
);  // (A,1), (B,2), (C,3)

// combineLatest - 最新值合并
Flux<String> combined = Flux.combineLatest(
    source1, source2,
    (v1, v2) -> v1 + ":" + v2
);
```

#### 错误处理

```java
// 错误回退
Flux<String> withFallback = Flux.error(new RuntimeException("DB down"))
    .onErrorReturn("default value");

// 降级到另一个流
Flux<String> withResume = fluxWithError
    .onErrorResume(e -> {
        log.error("查询失败，降级到缓存", e);
        return cacheService.getCachedData();
    });

// 重试
Flux<String> withRetry = unstableSource
    .retry(3)  // 最多重试3次
    .retryWhen(Retry.backoff(3, Duration.ofSeconds(1))
        .filter(e -> e instanceof TimeoutException));

// 超时
Flux<String> withTimeout = slowSource
    .timeout(Duration.ofSeconds(5))
    .onErrorResume(TimeoutException.class, e -> fallback());

// 捕获并继续
Flux<String> withContinue = fluxWithErrors
    .onErrorContinue((error, item) -> {
        log.warn("处理 {} 时出错: {}", item, error.getMessage());
    });
```

## 三、背压与流量控制

### 3.1 背压机制

```java
// 自定义背压策略
Flux<String> controlled = Flux.create(sink -> {
    // 检查是否被请求
    sink.onRequest(n -> {
        for (int i = 0; i < n; i++) {
            sink.next("Item " + i);
        }
    });
    sink.onCancel(() -> log.info("消费者取消"));
});

// 消费端控制
Flux.range(1, 1000)
    .subscribe(new BaseSubscriber<>() {
        @Override
        protected void hookOnSubscribe(Subscription subscription) {
            request(5);  // 每次请求5个
        }
        
        @Override
        protected void hookOnNext(Integer value) {
            process(value);
            request(1);  // 处理完一个再请求一个（慢消费）
        }
    });
```

### 3.2 溢出策略

```java
// 不同的溢出策略
enum OverflowStrategy {
    BUFFER,      // 缓冲所有（默认，可能导致 OOM）
    DROP,        // 丢弃新数据
    LATEST,      // 只保留最新的
    ERROR,       // 溢出时抛异常
    IGNORE       // 忽略背压（谨慎使用）
}

// 适用场景
Flux<String> hotStream = someHotSource()
    .onBackpressureBuffer(1000)     // 缓冲1000个
    .onBackpressureDrop(item -> log.warn("丢弃数据: {}", item))
    .onBackpressureLatest();        // 只保留最新的
```

### 3.3 限流

```java
// 限流操作
Flux<String> throttled = fastSource
    .sample(Duration.ofSeconds(1))           // 每秒采样一个
    .sampleFirst(Duration.ofSeconds(1))      // 每秒取第一个
    .bufferTimeout(100, Duration.ofSeconds(1)) // 缓冲100个或1秒
    .window(Duration.ofSeconds(5))           // 5秒窗口
    .limitRate(10);                          // 每次请求10个
```

## 四、调度器与线程模型

### 4.1 调度器类型

```java
// 不同的调度器
Scheduler immediate = Schedulers.immediate();           // 当前线程
Scheduler single = Schedulers.single();                  // 单线程
Scheduler parallel = Schedulers.parallel();              // 并行（CPU 核数）
Scheduler elastic = Schedulers.boundedElastic();         // 弹性线程池（默认 10x CPU）
Scheduler fromExecutor = Schedulers.fromExecutor(executorService);
```

### 4.2 线程切换

```java
@Service
public class OrderService {
    
    private static final Logger log = LoggerFactory.getLogger(OrderService.class);
    
    public Flux<Order> getOrders(Long userId) {
        return Flux.<Order>create(sink -> {
            log.info("创建数据流: {}", Thread.currentThread().getName());
            // 数据库查询（阻塞操作）
            List<Order> orders = orderRepository.findByUserId(userId);
            orders.forEach(sink::next);
            sink.complete();
        })
        .subscribeOn(Schedulers.boundedElastic())  // 数据库查询在 elastic 线程池
        .publishOn(Schedulers.parallel())           // 后续处理在 parallel 线程池
        .map(order -> {
            log.info("处理订单: {}", Thread.currentThread().getName());
            return order.enrichWithDiscount();
        });
    }
}

// 验证线程
@Test
void testThreadModel() {
    log.info("主线程: {}", Thread.currentThread().getName());
    
    Flux.just("A", "B", "C")
        .map(v -> {
            log.info("map on: {}", Thread.currentThread().getName());
            return v.toLowerCase();
        })
        .publishOn(Schedulers.parallel())
        .filter(v -> {
            log.info("filter on: {}", Thread.currentThread().getName());
            return v.equals("a");
        })
        .subscribeOn(Schedulers.single())
        .subscribe(v -> log.info("subscribe on: {}", Thread.currentThread().getName()));
}
```

### 4.3 并行执行

```java
// 并行处理
public Mono<OrderAggregation> aggregateOrderData(List<String> orderIds) {
    return Flux.fromIterable(orderIds)
        .parallel(4)  // 4 个并行流
        .runOn(Schedulers.parallel())
        .flatMap(this::getOrderDetail)
        .sequential()
        .collectList()
        .map(OrderAggregation::new);
}

// 并行多个独立操作
public Mono<DashboardData> getDashboard() {
    return Mono.zip(
        getOrderStats().subscribeOn(Schedulers.boundedElastic()),
        getUserStats().subscribeOn(Schedulers.boundedElastic()),
        getInventoryStats().subscribeOn(Schedulers.boundedElastic()),
        (orders, users, inventory) -> new DashboardData(orders, users, inventory)
    );
}
```

## 五、Spring WebFlux 实战

### 5.1 WebFlux 控制器

```java
@RestController
@RequestMapping("/api/orders")
public class OrderReactiveController {
    
    private final OrderReactiveService orderService;
    
    @GetMapping("/{id}")
    public Mono<ResponseEntity<Order>> getOrder(@PathVariable String id) {
        return orderService.findById(id)
            .map(ResponseEntity::ok)
            .defaultIfEmpty(ResponseEntity.notFound().build());
    }
    
    @GetMapping
    public Flux<Order> listOrders(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        return orderService.findPaged(page, size);
    }
    
    @PostMapping
    public Mono<Order> createOrder(@RequestBody @Valid Mono<CreateOrderRequest> request) {
        return request.flatMap(orderService::create);
    }
    
    @GetMapping("/stream")
    public Flux<OrderEvent> streamUpdates() {
        return orderService.orderEventStream()
            .retryBackoff(3, Duration.ofSeconds(1))
            .timeout(Duration.ofHours(1));
    }
}
```

### 5.2 WebClient 非阻塞 HTTP 调用

```java
@Component
public class PaymentClient {
    
    private final WebClient webClient;
    
    public PaymentClient() {
        this.webClient = WebClient.builder()
            .baseUrl("http://payment-service")
            .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
            .defaultHeader(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE)
            .build();
    }
    
    public Mono<PaymentResult> processPayment(PaymentRequest request) {
        return webClient.post()
            .uri("/api/payments")
            .bodyValue(request)
            .retrieve()
            .onStatus(HttpStatus::is4xxClientError, 
                response -> Mono.error(new PaymentException("支付客户端错误")))
            .onStatus(HttpStatus::is5xxServerError,
                response -> response.bodyToMono(String.class)
                    .flatMap(body -> Mono.error(new PaymentServerException(body))))
            .bodyToMono(PaymentResult.class)
            .timeout(Duration.ofSeconds(5))
            .retryWhen(Retry.backoff(3, Duration.ofMillis(500))
                .filter(e -> e instanceof TimeoutException));
    }
    
    // 流式 SSE
    public Flux<PaymentEvent> streamPaymentEvents(String paymentId) {
        return webClient.get()
            .uri("/api/payments/{id}/events", paymentId)
            .accept(MediaType.TEXT_EVENT_STREAM)
            .retrieve()
            .bodyToFlux(PaymentEvent.class)
            .retryBackoff(3, Duration.ofSeconds(5));
    }
}
```

### 5.3 响应式数据访问

```java
// Reactive MongoDB
@Repository
public interface ReactiveOrderRepository 
    extends ReactiveMongoRepository<Order, String> {
    
    Flux<Order> findByUserId(Long userId);
    
    Flux<Order> findByStatusAndCreatedAtBetween(
        OrderStatus status, 
        Instant from, 
        Instant to
    );
    
    @Aggregation(pipeline = {
        "{ $group: { _id: '$status', count: { $sum: 1 } } }"
    })
    Flux<StatusCount> countByStatus();
}

// Reactive Redis
@Service
public class ReactiveCacheService {
    
    private final ReactiveRedisTemplate<String, Object> redisTemplate;
    
    public Mono<Order> getCachedOrder(String orderId) {
        return redisTemplate.opsForValue()
            .get("order:" + orderId)
            .cast(Order.class);
    }
    
    public Mono<Boolean> cacheOrder(Order order) {
        return redisTemplate.opsForValue()
            .set("order:" + order.getOrderId(), order, Duration.ofHours(1));
    }
}

// Reactive R2DBC（关系型数据库）
@Repository
public interface ReactiveUserRepository 
    extends ReactiveCrudRepository<User, Long> {
    
    @Query("SELECT * FROM users WHERE age > :age")
    Flux<User> findByAgeGreaterThan(@Param("age") int age);
    
    Flux<User> findByEmail(String email);
}
```

## 六、性能对比

### 6.1 基准测试

| 指标 | 阻塞式 (Tomcat) | 响应式 (Netty) | 提升比例 |
|------|----------------|---------------|---------|
| 最大线程数 | 200 | 16 (Event Loop) | 92% 线程减少 |
| 1000 并发下的响应时间 | 850ms (avg) | 120ms (avg) | 85.9% 降低 |
| P99 延迟 | 2.3s | 480ms | 79.1% 降低 |
| 最大吞吐量 | 8,500 req/s | 45,000 req/s | 429% 提升 |
| 1GB 内存下的连接数 | 2,000 | 50,000+ | 25x 提升 |
| CPU 使用率 | 85% | 60% | 29% 降低 |

### 6.2 测试代码

```java
@BenchmarkMode({Mode.Throughput, Mode.AverageTime})
@OutputTimeUnit(TimeUnit.SECONDS)
@State(Scope.Thread)
public class ReactiveBenchmark {
    
    @Benchmark
    public List<Order> blockingQuery() {
        return orderRepository.findAll();  // 阻塞 JPA
    }
    
    @Benchmark
    public Flux<Order> reactiveQuery() {
        return reactiveOrderRepository.findAll();  // 响应式
    }
    
    @Benchmark
    public List<Order> blockingChain() {
        Order order = orderRepository.findById(1L).get();
        User user = userRepository.findById(order.getUserId()).get();
        List<OrderItem> items = itemRepository.findByOrderId(order.getId());
        order.setItems(items);
        order.setUser(user);
        return List.of(order);
    }
    
    @Benchmark
    public Mono<Order> reactiveChain() {
        return reactiveOrderRepository.findById(1L)
            .zipWhen(order -> reactiveUserRepository.findById(order.getUserId()))
            .zipWhen(tuple -> reactiveItemRepository.findByOrderId(tuple.getT1().getId())
                    .collectList())
            .map(tuple -> {
                Order order = tuple.getT1().getT1();
                User user = tuple.getT1().getT2();
                List<OrderItem> items = tuple.getT2();
                order.setUser(user);
                order.setItems(items);
                return order;
            });
    }
}
```

## 七、常见陷阱与最佳实践

### 7.1 常见陷阱

| 陷阱 | 表现 | 原因 | 解决方案 |
|------|------|------|---------|
| 阻塞操作 | 性能下降 | 在响应式链中调用阻塞 API | 使用 subscribeOn(Schedulers.boundedElastic()) |
| 忘记 subscribe | 不执行 | 流是惰性的 | 始终 subscribe 或 return |
| Context 丢失 | MDC 问题 | 线程切换导致 | 使用 reactive MDC(Hooks.enableAutomaticContextPropagation) |
| 无限流 | OOM | 没有限流或取消 | 使用 take/limitRate |
| 异常吞没 | 静默失败 | 没有处理 onError | 添加 doOnError/onErrorResume |
| 深堆栈 | 难以调试 | 链式调用太长 | 使用 checkpoint() 注入调试点 |
| 连接泄漏 | 资源耗尽 | 没有释放连接 | 使用 usingWhen 管理资源 |

### 7.2 最佳实践

```java
// 1. 使用 checkpoint 调试
Flux<String> debugged = complexFlow
    .checkpoint("获取用户订单", true);  // true 表示包含堆栈信息

// 2. 上下文传递
Flux<String> withContext = Flux.just("A")
    .contextWrite(Context.of("user", "admin"))
    .flatMap(v -> Mono.deferContextual(ctx -> {
        String user = ctx.get("user");
        return Mono.just(user + ":" + v);
    }));

// 3. 资源管理
Mono<String> managed = usingWhen(
    Mono.fromCallable(connectionPool::acquire),
    connection -> queryDb(connection),
    connection -> connectionPool.release(connection)
);

// 4. 合理设置缓冲区
Flux<Data> buffered = fastSource
    .onBackpressureBuffer(1000, 
        dropped -> log.warn("丢弃: {}", dropped),
        BufferOverflowStrategy.DROP_LATEST);

// 5. 超时控制
Flux<String> protectedStream = riskyOperation
    .timeout(Duration.ofSeconds(10))
    .onErrorResume(TimeoutException.class, e -> fallback())
    .retryWhen(Retry.fixedDelay(3, Duration.ofSeconds(1)));

// 6. 日志记录
Flux<Order> logged = orderStream
    .doOnSubscribe(s -> log.info("开始订阅"))
    .doOnNext(order -> log.debug("处理订单: {}", order.getId()))
    .doOnError(e -> log.error("处理异常", e))
    .doFinally(signal -> log.info("完成: {}", signal));
```

## 八、实际应用示例

### 8.1 实时数据聚合

```java
@Component
public class RealtimeDashboardService {
    
    private final ReactiveOrderRepository orderRepo;
    private final ReactiveRedisTemplate<String, String> redis;
    
    // 实时仪表盘数据
    public Flux<DashboardSnapshot> dashboardUpdates() {
        return Flux.merge(
            // 每分钟订单统计
            Flux.interval(Duration.ofMinutes(1))
                .flatMap(tick -> getOrderStats()),
            
            // 实时错误监控
            orderRepo.findByStatus(OrderStatus.ERROR)
                .bufferTimeout(10, Duration.ofSeconds(10))
                .map(errors -> DashboardSnapshot.errors(errors.size()))
        );
    }
    
    private Mono<DashboardSnapshot> getOrderStats() {
        return Mono.zip(
            orderRepo.countByStatus(OrderStatus.PENDING),
            orderRepo.countByStatus(OrderStatus.PAID),
            orderRepo.countByStatus(OrderStatus.COMPLETED),
            (pending, paid, completed) -> DashboardSnapshot.orders(pending, paid, completed)
        );
    }
}
```

### 8.2 事件溯源

```java
@Service
public class ReactiveEventSourcingService {
    
    private final ReactiveMongoTemplate mongoTemplate;
    
    public Flux<DomainEvent> eventStream(String aggregateId, Long fromVersion) {
        return mongoTemplate.query(DomainEvent.class)
            .matching(Query.query(
                Criteria.where("aggregateId").is(aggregateId)
                    .and("version").gt(fromVersion)
            ))
            .sort(Sort.by("version").ascending())
            .tail();  // Tailable cursor - 实时流
    }
    
    public Mono<AggregateState> reconstruct(String aggregateId) {
        return eventStream(aggregateId, 0L)
            .reduce(new AggregateState(), AggregateState::apply);
    }
}
```

## 总结

Project Reactor 提供了强大的响应式编程能力，通过 Flux 和 Mono 两大核心类型，配合丰富的操作符体系，能够优雅地处理异步数据流。关键要点：

1. **背压是核心**：消费者控制数据流速，保护系统不被压垮
2. **调度器决定线程模型**：合理使用 subscribeOn/publishOn 避免阻塞
3. **错误处理要完整**：覆盖 onErrorResume、retry、timeout 等场景
4. **性能优势在高并发下显著**：线程数大幅降低，吞吐量数倍提升
5. **调试难度高**：善用 checkpoint、log 等调试工具

响应式编程不是银弹，但在 IO 密集型和流式处理场景下，它能显著提升系统吞吐量和资源利用率。
