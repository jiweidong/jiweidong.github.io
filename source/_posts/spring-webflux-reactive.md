---
title: Spring WebFlux 响应式编程实战
date: 2026-06-16 08:30:00
tags:
  - Spring WebFlux
  - WebFlux
  - Reactor
  - 响应式编程
  - Project Reactor
categories: Spring Boot
description: 深入解析响应式编程范式与 Reactive Streams 规范，从 Project Reactor 核心概念到 Spring WebFlux 实战，涵盖 Flux/Mono 操作符、背压策略、函数式端点、WebClient、异常处理与 MongoDB 响应式集成。
---

## 一、引言

随着微服务架构的普及和云原生理念的演进，传统的 Servlet 阻塞 I/O 模型在高并发、低延迟场景下逐渐暴露瓶颈。Java 生态在 JDK 9 引入 Flow API（Reactive Streams 实现）后，响应式编程迎来了快速发展。Spring WebFlux 正是 Spring 5 推出的面向响应式编程的 Web 框架，它基于 Project Reactor，运行在 Netty、Undertow 等非阻塞服务器上，为构建高吞吐、低延迟的 Web 应用提供了全新选择。

本文将从响应式编程的核心概念出发，深入 Project Reactor 的运作机理，再通过实战示例全面展示 Spring WebFlux 的开发模式与最佳实践。

## 二、响应式编程概念

### 2.1 什么是响应式编程

响应式编程（Reactive Programming）是一种基于数据流和变化传播的异步编程范式。当数据流中的元素可用或被修改时，系统会以声明式的方式自动做出反应。可以将其理解为"异步数据流 + 观察者模式 + 声明式组合"。

```
传统命令式编程：                        响应式编程：
                        │
List<String> result     │   Flux<String> result
  = new ArrayList<>();  │     = Flux.fromIterable(data)
                        │       .filter(s -> s.startsWith("A"))
for (String s : data) {  │       .map(String::toUpperCase)
  if (s.startsWith("A"))│       .subscribe(System.out::println);
    result.add(          │
      s.toUpperCase());  │
}                       │
                        ▼
"我来问，你来答"              "数据推过来，我来处理"
（Pull / 拉模式）              （Push / 推模式）
```

### 2.2 Reactive Streams 规范

Reactive Streams 是 JVM 生态响应式编程的事实标准，于 2015 年发布 1.0 规范。它定义了四个核心接口：

| 接口 | 角色 | 说明 |
|------|------|------|
| Publisher | 数据发布者 | 可以订阅的数据源 |
| Subscriber | 数据订阅者 | 接收并处理数据的消费者 |
| Subscription | 订阅关系 | 连接 Publisher 与 Subscriber，支持背压请求 |
| Processor | 处理器 | 同时是 Publisher 和 Subscriber，位于中间环节 |

**规范的核心是背压（Backpressure）**：下游消费速度慢于上游生产速度时，下游主动向上游请求可控数量的数据，避免内存溢出或系统崩溃。

```
Publisher (数据源)
    │ publish(onNext/dOnComplete/onError)
    ▼
Subscriber
    │ onSubscribe(Subscription s) → s.request(n)
    │ onNext(T item)  × n 次
    │ onComplete() 或 onError(Throwable)
    ▼
Subscription (纽带)
    - request(long n)：请求 n 个元素
    - cancel()：取消订阅
```

## 三、Project Reactor 核心

### 3.1 Flux 与 Mono

Project Reactor 是 Reactive Streams 规范在 Spring 生态的实现，提供了两种主要的 Publisher 类型：

- **Flux\<T\>**：代表包含 0 到 N 个元素的异步序列
- **Mono\<T\>**：代表包含 0 或 1 个元素的异步序列

```java
// Flux：多元素序列
Flux<String> fruitFlux = Flux.just("apple", "banana", "cherry", "date");
Flux<Integer> rangeFlux = Flux.range(1, 100);
Flux<Long> intervalFlux = Flux.interval(Duration.ofSeconds(1));  // 无限流

// Mono：0 或 1 个元素
Mono<String> mono = Mono.just("hello");
Mono<String> emptyMono = Mono.empty();
Mono<User> userMono = Mono.justOrEmpty(findUserById(42));
Mono<User> errorMono = Mono.error(new RuntimeException("Not found"));
```

### 3.2 核心操作符

Reactor 提供了丰富的操作符，支持链式调用（Fluent API），以下是实战中最常用的操作符分类：

#### 创建操作符

```java
// 从已有数据创建
Flux<String> fromIterable = Flux.fromIterable(list);
Flux<String> fromArray = Flux.fromArray(array);
Flux<Integer> fromStream = Flux.fromStream(stream);

// 程序化创建
Flux<Object> flux = Flux.generate(sink -> {
    sink.next("A");
    sink.complete();
});

Flux<Object> fluxSink = Flux.create(sink -> {
    // 在多线程中安全发射元素
    executorService.submit(() -> {
        sink.next("async");
        sink.complete();
    });
});
```

#### 转换操作符

```java
// map：同步转换（1:1）
Flux<String> upper = names.map(String::toUpperCase);

// flatMap：异步转换（1:N）—— 核心！将每个元素映射为 Flux，再合并
Flux<String> words = sentences
    .flatMap(s -> Flux.fromArray(s.split(" ")));

// concatMap：flatMap 的顺序版本
Flux<String> ordered = sentences
    .concatMap(s -> Flux.fromArray(s.split(" ")));

// flatMapSequential：保持顺序的 flatMap
Flux<String> seq = sentences
    .flatMapSequential(s -> asyncProcess(s));
```

#### 过滤操作符

```java
Flux<User> adults = users
    .filter(u -> u.getAge() >= 18);

Flux<User> unique = users
    .distinct(User::getId);

// 仅取前 10 个
Flux<User> top10 = users.take(10);

// 跳过前 5 个
Flux<User> skip = users.skip(5);

// 去重之前/之后的元素
Flux<User> last3 = users.takeLast(3);
```

#### 组合操作符

```java
// zip：合并多个流（一对一对齐）
Flux<Tuple2<String, Integer>> zipped = Flux
    .zip(names, ages);

// merge：按时间先后合并
Flux<String> merged = Flux.merge(flux1, flux2);

// concat：按顺序合并
Flux<String> concated = Flux.concat(flux1, flux2);

// combineLatest：任意流有新元素时，取各流最新值
Flux<Tuple2<Long, String>> combined =
    Flux.combineLatest(interval, messages, Tuples::of);
```

#### 错误处理操作符

```java
// 发生错误时返回默认值
Mono<String> safe = mono.onErrorReturn("default");

// 发生错误时切换到另一个流
Mono<String> fallback = mono.onErrorResume(e -> Mono.just("fallback"));

// 根据异常类型做不同处理
Mono<String> smart = mono.onErrorResume(NullPointerException.class, e -> Mono.empty())
                          .onErrorResume(TimeoutException.class, e -> retry())
                          .onErrorReturn("error");
```

### 3.3 背压策略

Reactive Streams 的核心特性之一是背压控制。Reactor 提供了多种策略：

| 策略 | 方法 | 行为 | 适用场景 |
|------|------|------|----------|
| 缓冲 | onBackpressureBuffer | 无限制缓冲所有元素 | 内存充足，下游偶发性慢 |
| 丢弃 | onBackpressureDrop | 丢弃无法处理的元素 | 允许数据丢失（如实时监控） |
| 保留最新 | onBackpressureLatest | 仅保留最新元素 | 只关心最新状态（如股票价格） |
| 错误 | onBackpressureError | 背压发生时抛出异常 | 需要严格的数据完整性 |
| 缓冲有界 | onBackpressureBuffer(capacity) | 有限缓冲，超限报错 | 推荐方案，平衡内存与完整性 |

```java
// 缓冲策略：最多缓冲 256 个元素，超限报错
flux.onBackpressureBuffer(256, BufferOverflowStrategy.ERROR)
    .subscribe(subscriber);

// 丢弃策略：放不下的元素直接丢弃
flux.onBackpressureDrop(dropped -> log.warn("Dropped: {}", dropped))
    .subscribe(subscriber);

// 保留最新：缓冲区满时淘汰旧元素保留最新的
flux.onBackpressureLatest()
    .subscribe(subscriber);

// 自定义请求量：通过 Subscription 控制
Flux.range(1, 1000)
    .subscribe(new BaseSubscriber<Integer>() {
        @Override
        protected void hookOnSubscribe(Subscription subscription) {
            request(10);  // 每次请求 10 个
        }
        @Override
        protected void hookOnNext(Integer value) {
            process(value);
            request(1);   // 每处理完一个再请求一个
        }
    });
```

### 3.4 调度器（Schedulers）

Reactor 通过 Schedulers 提供线程调度能力，用于控制操作符在哪个线程池中执行：

| 调度器 | 说明 | 适用场景 |
|--------|------|----------|
| Schedulers.immediate() | 当前线程执行 | 默认，测试 |
| Schedulers.single() | 单线程可复用池 | 轻量后台任务 |
| Schedulers.boundedElastic() | 弹性线程池（默认无界最大 CPU×10） | 阻塞 I/O 操作（JDBC 等） |
| Schedulers.parallel() | 固定大小（CPU 核心数）的工作窃取池 | CPU 密集型计算 |
| Schedulers.fromExecutorService() | 自定义线程池 | 已有线程池复用 |

```java
// 指定上游在 elastic 线程池执行（适合阻塞操作）
flux.subscribeOn(Schedulers.boundedElastic())
    .subscribe();

// 下游处理在 parallel 线程池执行（CPU 密集型）
flux.publishOn(Schedulers.parallel())
    .map(this::heavyCpuCompute)
    .subscribe();
```

## 四、WebFlux 与传统 Servlet 对比

### 4.1 架构对比

| 维度 | Spring Web MVC (Servlet) | Spring WebFlux |
|------|--------------------------|----------------|
| I/O 模型 | 阻塞式（Blocking I/O） | 非阻塞式（Non-Blocking I/O） |
| 线程模型 | 1 请求 = 1 线程 | 少量线程处理大量请求（事件循环） |
| 底层容器 | Tomcat / Jetty | Netty / Undertow / Servlet 3.1+ |
| API 风格 | 注解驱动 @Controller | 注解 + 函数式端点 |
| 安全性 | Spring Security（阻塞） | Spring Security Reactive |
| 数据访问 | JDBC / JPA（阻塞） | R2DBC / MongoDB Reactive |
| 内存效率 | 每个请求一个线程栈（~1MB） | 极低，无线程栈开销 |
| 并发能力 | 受限于线程池大小 | 可达数十万并发连接 |

### 4.2 性能对比（基准测试）

以下为典型场景下的性能对比（基于简单 CRUD，Netty vs Tomcat）：

| 场景 | Servlet (Tomcat) | WebFlux (Netty) | 提升倍数 |
|------|------------------|-----------------|----------|
| 10K 并发 / 简单查询 | 3500 req/s | 12000 req/s | ~3.4× |
| 10K 并发 / 延迟 100ms 下游调用 | 800 req/s | 9500 req/s | ~11.9× |
| 100K 并发长连接 | 部分拒绝 | 稳定处理 | 质的区别 |
| P99 延迟 (10K 并发) | 850ms | 120ms | ~7× |

> **注意**：以上数据是 I/O 密集型场景的对比。对于纯 CPU 密集型业务，WebFlux 的优势不明显。

### 4.3 何时选择 WebFlux

**适合 WebFlux 的场景：**
- 高并发网关和 BFF（Backend For Frontend）
- 大量远程调用（聚合多个微服务响应）
- 实时数据流处理（SSE、WebSocket）
- 流式数据传输和大文件处理
- 与响应式数据层（MongoDB Reactive、Redis Reactive、R2DBC）配合

**仍推荐传统 MVC 的场景：**
- 使用 JDBC/JPA 作为数据访问层
- 团队缺乏响应式编程经验
- CPU 密集型计算任务为主
- 第三方 SDK 不支持响应式

## 五、注解式控制器

```java
@RestController
@RequestMapping("/api/users")
public class UserController {

    private final UserService userService;

    public UserController(UserService userService) {
        this.userService = userService;
    }

    // GET /api/users — 返回 Flux（流式响应）
    @GetMapping
    public Flux<User> getAllUsers(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        return userService.findAll(page, size);
    }

    // GET /api/users/{id} — 返回 Mono
    @GetMapping("/{id}")
    public Mono<User> getUserById(@PathVariable String id) {
        return userService.findById(id)
                .switchIfEmpty(Mono.error(
                    new ResponseStatusException(HttpStatus.NOT_FOUND, "User not found: " + id)));
    }

    // POST /api/users
    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Mono<User> createUser(@Valid @RequestBody Mono<User> userMono) {
        return userMono.flatMap(userService::save);
    }

    // PUT /api/users/{id}
    @PutMapping("/{id}")
    public Mono<User> updateUser(@PathVariable String id,
                                  @Valid @RequestBody Mono<User> userMono) {
        return userMono.flatMap(user -> userService.update(id, user));
    }

    // DELETE /api/users/{id}
    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public Mono<Void> deleteUser(@PathVariable String id) {
        return userService.deleteById(id);
    }

    // GET /api/users/stream — SSE 服务器推送
    @GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<User> streamUsers() {
        return userService.streamAll();
    }
}
```

## 六、函数式端点

WebFlux 支持通过 RouterFunction 和 HandlerFunction 以函数式方式定义路由，无需 Controller 注解：

```java
@Configuration
public class UserRouterConfig {

    @Bean
    public RouterFunction<ServerResponse> userRoutes(UserHandler handler) {
        return RouterFunctions
            .route()
            .path("/api/users", builder -> builder
                .GET("", handler::getAllUsers)
                .GET("/{id}", handler::getUserById)
                .POST("", handler::createUser)
                .PUT("/{id}", handler::updateUser)
                .DELETE("/{id}", handler::deleteUser)
                .GET("/stream", handler::streamUsers, accept(MediaType.TEXT_EVENT_STREAM))
            )
            .before(request -> {
                log.info("Request: {} {}", request.method(), request.uri());
                return request;
            })
            .after((request, response) -> {
                log.info("Response status: {}", response.statusCode());
                return response;
            })
            .build();
    }
}

@Component
class UserHandler {

    private final UserService userService;

    UserHandler(UserService userService) {
        this.userService = userService;
    }

    public Mono<ServerResponse> getAllUsers(ServerRequest request) {
        int page = Integer.parseInt(request.queryParam("page").orElse("0"));
        int size = Integer.parseInt(request.queryParam("size").orElse("20"));

        return ServerResponse.ok()
                .body(userService.findAll(page, size), User.class);
    }

    public Mono<ServerResponse> getUserById(ServerRequest request) {
        return userService.findById(request.pathVariable("id"))
                .flatMap(user -> ServerResponse.ok().bodyValue(user))
                .switchIfEmpty(ServerResponse.notFound().build());
    }

    public Mono<ServerResponse> createUser(ServerRequest request) {
        return request.bodyToMono(User.class)
                .flatMap(userService::save)
                .flatMap(saved -> ServerResponse
                        .created(URI.create("/api/users/" + saved.getId()))
                        .bodyValue(saved));
    }

    public Mono<ServerResponse> updateUser(ServerRequest request) {
        return request.bodyToMono(User.class)
                .flatMap(user -> userService.update(request.pathVariable("id"), user))
                .flatMap(updated -> ServerResponse.ok().bodyValue(updated))
                .switchIfEmpty(ServerResponse.notFound().build());
    }

    public Mono<ServerResponse> deleteUser(ServerRequest request) {
        return userService.deleteById(request.pathVariable("id"))
                .then(ServerResponse.noContent().build());
    }

    public Mono<ServerResponse> streamUsers(ServerRequest request) {
        return ServerResponse.ok()
                .contentType(MediaType.TEXT_EVENT_STREAM)
                .body(userService.streamAll(), User.class);
    }
}
```

## 七、WebClient — 响应式 HTTP 客户端

WebClient 是 WebFlux 提供的响应式 HTTP 客户端，替代传统的 RestTemplate：

```java
@Service
public class UserServiceClient {

    private final WebClient webClient;

    public UserServiceClient(WebClient.Builder builder) {
        this.webClient = builder.baseUrl("http://user-service")
                .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .defaultUriVariables(Map.of("timeout", "5"))
                .build();
    }

    // GET 请求，返回 Flux
    public Flux<User> getUsers(int page, int size) {
        return webClient.get()
                .uri("/api/users?page={page}&size={size}", page, size)
                .retrieve()
                .bodyToFlux(User.class);
    }

    // GET 请求，返回 Mono
    public Mono<User> getUserById(String id) {
        return webClient.get()
                .uri("/api/users/{id}", id)
                .retrieve()
                .onStatus(HttpStatus::is4xxClientError, response ->
                    Mono.error(new UserNotFoundException(id)))
                .onStatus(HttpStatus::is5xxServerError, response ->
                    response.bodyToMono(String.class)
                            .flatMap(body -> Mono.error(new ServiceException(body))))
                .bodyToMono(User.class);
    }

    // POST 请求
    public Mono<User> createUser(User user) {
        return webClient.post()
                .uri("/api/users")
                .bodyValue(user)
                .retrieve()
                .bodyToMono(User.class);
    }

    // 超时控制
    public Mono<User> getUserWithTimeout(String id) {
        return webClient.get()
                .uri("http://user-service/api/users/{id}", id)
                .retrieve()
                .bodyToMono(User.class)
                .timeout(Duration.ofMillis(500))
                .onErrorResume(TimeoutException.class, e -> {
                    log.warn("Request timeout for user: {}", id);
                    return Mono.empty();
                });
    }

    // 多服务并行聚合
    public Mono<UserDetail> getUserDetail(String userId) {
        Mono<User> userMono = getUserById(userId);
        Mono<List<Order>> ordersMono = getOrderClient()
                .getUserOrders(userId).collectList();
        Mono<List<Payment>> paymentsMono = getPaymentClient()
                .getUserPayments(userId).collectList();

        return Mono.zip(userMono, ordersMono, paymentsMono)
                .map(tuple -> new UserDetail(
                        tuple.getT1(),
                        tuple.getT2(),
                        tuple.getT3()));
    }
}
```

## 八、异常处理

### 8.1 全局异常处理

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    // 参数校验失败
    @ExceptionHandler(WebExchangeBindException.class)
    public Mono<ResponseEntity<ErrorResponse>> handleValidation(
            WebExchangeBindException ex) {
        List<String> errors = ex.getBindingResult()
                .getFieldErrors()
                .stream()
                .map(fe -> fe.getField() + ": " + fe.getDefaultMessage())
                .toList();

        return Mono.just(ResponseEntity
                .badRequest()
                .body(new ErrorResponse("VALIDATION_ERROR", errors)));
    }

    // 资源未找到
    @ExceptionHandler(ResponseStatusException.class)
    public Mono<ResponseEntity<ErrorResponse>> handleResponseStatus(
            ResponseStatusException ex) {
        return Mono.just(ResponseEntity
                .status(ex.getStatusCode())
                .body(new ErrorResponse(
                        ex.getStatusCode().toString(),
                        List.of(ex.getReason()))));
    }

    // 服务器内部错误
    @ExceptionHandler(Exception.class)
    public Mono<ResponseEntity<ErrorResponse>> handleUnknown(
            Exception ex) {
        log.error("Unexpected error", ex);
        return Mono.just(ResponseEntity
                .status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body(new ErrorResponse("INTERNAL_ERROR",
                        List.of("An unexpected error occurred"))));
    }
}

record ErrorResponse(String code, List<String> messages) {}
```

### 8.2 函数式端点的异常处理

```java
@Bean
public RouterFunction<ServerResponse> errorRoutes() {
    return RouterFunctions.route()
            .GET("/api/error-test", request -> {
                throw new IllegalArgumentException("test error");
            })
            .onError(IllegalArgumentException.class,
                    (e, request) -> ServerResponse
                            .badRequest()
                            .bodyValue(new ErrorResponse("BAD_REQUEST",
                                    List.of(e.getMessage()))))
            .onError(Exception.class,
                    (e, request) -> ServerResponse
                            .status(HttpStatus.INTERNAL_SERVER_ERROR)
                            .bodyValue(new ErrorResponse("INTERNAL_ERROR",
                                    List.of("Something went wrong"))))
            .build();
}
```

## 九、MongoDB Reactive 集成

### 9.1 配置

```yaml
spring:
  data:
    mongodb:
      uri: mongodb://localhost:27017/mydb
      auto-index-creation: true
      # 响应式 MongoDB 使用 netty 连接，无需阻塞连接池
```

### 9.2 Repository

```java
// 响应式 Repository 接口
@Repository
public interface UserReactiveRepository
        extends ReactiveMongoRepository<User, String> {

    // 根据条件查询
    Flux<User> findByAgeBetween(int min, int max);

    Mono<User> findByEmail(String email);

    // 使用 @Query 自定义查询
    @Query("{ 'status': ?0, 'age': { $gte: ?1 } }")
    Flux<User> findByStatusAndMinAge(String status, int minAge);

    // 聚合管道
    @Aggregation(pipeline = {
        "{ $match: { status: 'ACTIVE' } }",
        "{ $group: { _id: '$department', count: { $sum: 1 } } }",
        "{ $sort: { count: -1 } }"
    })
    Flux<DepartmentCount> countByDepartment();
}

// 或在 Service 中使用 ReactiveMongoTemplate
@Service
public class UserService {

    private final ReactiveMongoTemplate mongoTemplate;

    public UserService(ReactiveMongoTemplate mongoTemplate) {
        this.mongoTemplate = mongoTemplate;
    }

    public Flux<User> findAdvanced(String department, int minAge) {
        Query query = Query.query(
            Criteria.where("department").is(department)
                    .and("age").gte(minAge));
        query.with(Sort.by(Direction.DESC, "createdAt"));
        query.limit(50);

        return mongoTemplate.find(query, User.class);
    }

    public Mono<User> saveWithValidation(User user) {
        return Mono.just(user)
                .filter(u -> u.getEmail() != null)
                .switchIfEmpty(Mono.error(
                    new IllegalArgumentException("Email is required")))
                .flatMap(mongoTemplate::save);
    }
}
```

### 9.3 事务支持

MongoDB 4.0+ 支持多文档事务，WebFlux 中可通过 `ReactiveMongoTemplate` 操作：

```java
@Service
public class OrderService {

    private final ReactiveMongoTemplate mongoTemplate;

    @Transactional
    public Mono<Order> createOrder(Order order) {
        return mongoTemplate.inTransaction()
                .execute(reactiveTemplate -> {
                    // 创建订单
                    Mono<Order> savedOrder = reactiveTemplate.save(order);
                    // 扣减库存
                    Mono<Stock> updatedStock = reactiveTemplate
                            .findAndModify(
                                Query.query(Criteria.where("productId")
                                        .is(order.getProductId())),
                                new Update().inc("quantity", -order.getQuantity()),
                                Stock.class);
                    return savedOrder.then(updatedStock).thenReturn(order);
                });
    }
}
```

## 十、性能优化与注意事项

### 10.1 阻塞操作注意事项

**切勿在响应式流水线中插入阻塞调用**，否则会阻塞底层事件循环线程：

```java
// ❌ 错误做法 — 会阻塞 Netty 事件循环
return userService.findById(id)
        .map(user -> {
            Thread.sleep(1000);  // 阻塞！
            return user;
        });

// ✅ 正确做法 — 使用 publishOn 切换到弹性线程池
return userService.findById(id)
        .publishOn(Schedulers.boundedElastic())
        .map(user -> {
            Thread.sleep(1000);
            return user;
        });

// ✅ 或用 block() 在合适位置（仅限测试/边界）
// Blockhunt 或 subscribeOn(Schedulers.boundedElastic())
```

### 10.2 WebFlux 性能优化技巧

| 策略 | 操作 | 效果 |
|------|------|------|
| 减少操作链长度 | 合并 map/flatMap | 减少对象分配 |
| 使用共享运算符 | .share() 让多个订阅者共用 | 避免重复执行 |
| 缓存结果 | .cache() 或 .cache(Duration) | 减少重复计算 |
| 延迟日志 | 仅在 subscribe 阶段 logging | 避免干扰流水线 |
| 合理设置 buffer | exchangeStrategies.codec() | 减少内存碎片 |
| 使用 H2 Database | 测试友好 | 替代 MongoDB 做集成测试 |

## 十一、总结

Spring WebFlux 为 Java Web 开发带来了真正的响应式编程范式。其核心价值不在于替代传统 Servlet，而在于解决特定场景下的性能瓶颈：高并发、I/O 密集型、实时数据流。

关键要点回顾：

1. **Reactive Streams 规范**是响应式编程的基石，背压机制是其区别于普通异步编程的核心特性
2. **Flux 和 Mono** 是 Reactor 的两种基本类型，配合丰富的操作符链，可以实现声明式的数据流处理
3. **WebFlux 支持注解式和函数式两种编程模型**，函数式端点在路由和中间件方面更加灵活
4. **WebClient** 是构建响应式微服务间通信的首选工具，支持非阻塞的 HTTP 调用和并行聚合
5. **响应式 MongoDB** 集成提供了从数据层到 Web 层的全栈非阻塞能力

最后，响应式编程的学习曲线确实比传统 Servlet 编程陡峭，建议团队先在小范围的非核心服务中试点，积累经验后再推广到关键业务系统。理解其背后的背压机制和调度模型，远比记住 API 用法更为重要。
