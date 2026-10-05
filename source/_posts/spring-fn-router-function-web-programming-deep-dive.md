---
title: 【Spring 实战】Spring 函数式 Web 编程深度解析：RouterFunction、HandlerFilterFunction 与 WebMvc.fn/WebFlux.fn 全解析
date: 2026-10-05 08:50:00
tags:
  - Spring Boot
  - Spring MVC
  - WebFlux
  - 函数式编程
  - 实战
categories:
  - Spring 全家桶
  - Java
author: 东哥
---

# 【Spring 实战】Spring 函数式 Web 编程深度解析：RouterFunction、HandlerFilterFunction 与 WebMvc.fn/WebFlux.fn 全解析

## 面试官：除了 `@RestController`，Spring 还有什么方式定义 HTTP 接口？

如果只答"'还可以用 `@Controller`+`@ResponseBody`"，那就漏掉了 Spring 5 引入的一个很重要的能力：**函数式 Web 端点（Functional Web Endpoints）**，也就是 `WebMvc.fn` 和 `WebFlux.fn`。

它的价值在于：

- **路由即代码**：路由表是普通的 Java 代码，可以组合、可测试、可动态装配，不用依赖注解和反射扫描；
- **无框架魔法**：请求 → 响应的映射是显式函数 `HandlerFunction`，方便做多租户动态路由、API 网关式转发；
- **与 WebFlux 天然契合**：`RouterFunction` 返回 `Mono<HandlerFunction>`，可以按需异步决定路由，这是注解式做不到的。

下面从抽象到实战,把它彻底讲透。

---

## 一、核心抽象只有三个

函数式 Web 编程的 API 面极其精简，只有三个角色：

| 抽象 | 职责 | 类比 |
| --- | --- | --- |
| `RouterFunction<T>` | 判断"请求该交给谁"，返回 `Optional<HandlerFunction<T>>` | `@RequestMapping` |
| `HandlerFunction<T>` | 处理请求，返回响应 | `@RestController` 方法体 |
| `ServerRequest` / `ServerResponse` | 请求与响应的不可变封装 | `HttpServletRequest` / `ResponseEntity` |

```java
@FunctionalInterface
public interface RouterFunction<T extends ServerResponse> {
    Optional<HandlerFunction<T>> route(ServerRequest request);
    // 提供 and()/andRoute()/andNest() 组合方法
}

@FunctionalInterface
public interface HandlerFunction<T extends ServerResponse> {
    T handle(ServerRequest request) throws ServletException, IOException;
}
```

**关键理解：`RouterFunction` 是一个"谓词 + 处理器"的组合。** Spring 提供了 `RequestPredicates` 工厂来构造谓词：

```java
import static org.springframework.web.servlet.function.RequestPredicates.*;
import static org.springframework.web.servlet.function.RouterFunctions.*;

RouterFunction<ServerResponse> route = route()
    .GET("/users/{id}", accept(APPLICATION_JSON), this::getUser)
    .GET("/users", this::listUsers)
    .POST("/users", contentType(APPLICATION_JSON), this::createUser)
    .build();
```

这里用到了 `RequestPredicate`：`GET(...)`、`accept(...)`、`contentType(...)`、`path(...)`、`header(...)`、`queryParam(...)`。它们支持 `and()` / `or()` / `negate()`，表达能力比注解更强。

---

## 二、`ServerRequest` 与 `ServerResponse`

### 2.1 `ServerRequest`：不可变、可重复读

```java
public ServerResponse getUser(ServerRequest request) throws Exception {
    Long id = Long.valueOf(request.pathVariable("id"));
    String traceId = request.headers().firstHeader("X-Trace-Id");
    String q = request.param("q").orElse("");
    User user = userService.getById(id);
    return ServerResponse.ok().contentType(MediaType.APPLICATION_JSON).body(user);
}
```

`ServerRequest` 的几个有用能力：

- `body(Class<T>)`：把请求体反序列化成对象（WebFlux 下是 `bodyToMono`）；
- `attributes()`：**请求级上下文**，可以在 Filter 里塞数据、在 Handler 里取；
- `session()` / `principal()`：会话与安全上下文；
- `cookies()`、`params()`：多值参数。

### 2.2 `ServerResponse`：链式构建

```java
// 200 + JSON
ServerResponse.ok().contentType(MediaType.APPLICATION_JSON).body(user);

// 201 + Location
ServerResponse.created(URI.create("/users/" + user.getId())).body(user);

// 204
ServerResponse.noContent().build();

// 自定义状态与头
ServerResponse.status(HttpStatus.ACCEPTED)
    .header("X-Rate-Limit", "100")
    .body(result);
```

**注意**：WebMvc.fn 的 `body(Object)` 走的是 **HttpMessageConverter**，和 `@RestController` 完全一样的 JSON 序列化机制，所以 Jackson 的所有配置（命名策略、时间格式）都自动生效。

---

## 三、嵌套路由：`nest()`

真实业务的路由要按模块/版本分组。`nest()` 是函数式路由最优雅的地方：

```java
RouterFunction<ServerResponse> api = route()
    .nest(path("/api/v1"), builder -> builder
        .GET("/users", this::listUsers)
        .GET("/users/{id}", this::getUser)
        .nest(path("/users/{userId}/orders"), nested -> nested
            .GET("", this::listUserOrders)       // /api/v1/users/{id}/orders
            .GET("/{orderId}", this::getOrder)
        )
    )
    .build();
```

`nest` 会自动把前缀谓词与子路由组合，路径变量（如 `{userId}`）也会**正确传递到子路由**。对比注解式，你要么重复写 `@RequestMapping("/api/v1/users")`，要么用类级注解；函数式这里更直观。

---

## 四、`HandlerFilterFunction`：函数式世界的过滤器

这是最容易被忽略、也最容易被问到的一块。

```java
@FunctionalInterface
public interface HandlerFilterFunction<T extends ServerResponse, R extends ServerResponse> {
    R filter(ServerRequest request, HandlerFunction<T> next) throws Exception;
}
```

它长得很像 `Filter`，但语义完全不同：

| 维度 | `javax.servlet.Filter` | `HandlerFilterFunction` |
| --- | --- | --- |
| 作用范围 | 整个 Servlet 容器 | **仅 RouterFunction 链** |
| 请求对象 | `HttpServletRequest` | `ServerRequest`（不可变封装） |
| 能否短路 | 可以 | 可以（不调 `next.handle()`） |
| 是否可拿到 handler | 否 | **可以，能拿到要执行的 Handler** |
| 可否注册到指定路由 | 否（全局） | **可以按路由精确绑定** |

**"能按路由绑定"是它的杀手级能力**：你可以在只给 `POST /orders` 挂鉴权，其它路由不管，而不需要写一堆 `if (path.startsWith(...))`。

```java
RouterFunction<ServerResponse> app = route()
    .GET("/health", req -> ServerResponse.ok().body("UP"))
    .build();

// 给业务路由统一加鉴权 + 日志 + 耗时统计
RouterFunction<ServerResponse> secured = app.filter((request, next) -> {
    String token = request.headers().firstHeader("Authorization");
    if (token == null || !authService.valid(token)) {
        return ServerResponse.status(HttpStatus.UNAUTHORIZED).body("unauthorized");
    }
    request.attributes().put("userId", authService.userIdOf(token));  // 传递上下文
    long start = System.nanoTime();
    try {
        return next.handle(request);
    } finally {
        log.info("{} {} cost={}ms", request.method(), request.uri(),
                 (System.nanoTime() - start) / 1_000_000);
    }
});
```

### 4.1 多个 Filter 的执行顺序：洋葱模型

```java
RouterFunction<ServerResponse> r = base
    .filter(traceFilter)      // 最外层
    .filter(authFilter)       // 中间
    .filter(rateLimitFilter)  // 最内层
;
```

执行顺序是 `trace → auth → rateLimit → handler → rateLimit后置 → auth后置 → trace后置`，即**洋葱模型**。后加的在更内层（`filter()` 每次返回的是包裹后的新 RouterFunction）。

**这一点务必说清**：`filter()` 的调用顺序与执行进入顺序一致，但返回时逆序——和 Servlet Filter 链一致。

### 4.2 用 `before` / `after` 简化

Spring 也提供了 `RouterFunctions.before()` / `after()`，用于"只做前置/后置"的场景：

```java
RouterFunction<ServerResponse> withTrace = route().before(traceAll()).build();
```

---

## 五、WebMvc.fn vs WebFlux.fn：别搞混

这是面试常考陷阱。两者 API 高度相似，但**底层线程模型完全不同**。

| 维度 | `WebMvc.fn`（Servlet） | `WebFlux.fn`（Reactive） |
| --- | --- | --- |
| 包名 | `o.s.web.servlet.function` | `o.s.web.reactive.function.server` |
| Handler 签名 | `ServerResponse handle(ServerRequest)` | `Mono<ServerResponse> handle(ServerRequest)` |
| 请求体 | `request.body(Class<T>)`（阻塞） | `request.bodyToMono(Class<T>)` |
| 线程模型 | 一请求一线程（或虚拟线程） | EventLoop，非阻塞 |
| 数据库 | JDBC/JPA 阻塞调用 | R2DBC / 响应式驱动 |
| 适用 | 传统 MVC 项目渐进引入 | 高并发 IO 密集、流式接口 |

```java
// WebFlux.fn 写法：返回值是 Mono
public Mono<ServerResponse> getUser(ServerRequest request) {
    long id = Long.parseLong(request.pathVariable("id"));
    return userRepository.findById(id)
            .flatMap(u -> ServerResponse.ok().bodyValue(u))
            .switchIfEmpty(ServerResponse.notFound().build());
}
```

**选型建议**：项目已经用 Spring MVC + JDBC/JPA，就别为了"函数式"去上 WebFlux——**WebFlux 的价值在非阻塞，而不是函数式写法**。想体验函数式风格，用 `WebMvc.fn` 完全够。

---

## 六、与注解式混用：优先级与装配

`RouterFunction` 和 `@Controller` **可以共存**。优先级规则：

Spring MVC 的默认 order（**数值越小优先级越高**）：

| HandlerMapping | order |
| --- | --- |
| `RequestMappingHandlerMapping` | 0 |
| `RouterFunctionMapping` | 3 |
| `SimpleUrlHandlerMapping`（静态资源） | `Ordered.LOWEST_PRECEDENCE - 1` |

所以**注解式先匹配，函数式后匹配**。想在函数式里"覆盖"某个注解端点，要用更精确的谓词 + 把 `RouterFunctionMapping` 的 order 提前。

```java
@Bean
public RouterFunction<ServerResponse> userRoutes(UserHandler handler) {
    return route()
        .path("/api/users", b -> b
            .GET("/{id}", handler::get)
            .GET("", handler::list)
            .POST("", handler::create))
        .build();
}
```

注册方式就是把这个 `RouterFunction` 注册成 `@Bean`，Spring Boot 自动装配（`WebMvcAutoConfiguration` 里会注入 `RouterFunctionMapping`）。

---

## 七、错误处理与内容协商

### 7.1 异常处理

函数式端点的异常有两种处理方式：

```java
// 方式一：Handler 内部 try-catch，返回规范错误响应
public ServerResponse getUser(ServerRequest req) {
    try {
        return ServerResponse.ok().body(userService.get(id(req)));
    } catch (UserNotFoundException e) {
        return ServerResponse.status(HttpStatus.NOT_FOUND)
                .contentType(MediaType.APPLICATION_JSON)
                .body(ApiError.of("USER_NOT_FOUND", e.getMessage()));
    }
}

// 方式二：全局 @ControllerAdvice（对 WebMvc.fn 同样生效！）
@RestControllerAdvice
public class GlobalErrorHandler {
    @ExceptionHandler(UserNotFoundException.class)
    public ResponseEntity<ApiError> handle(UserNotFoundException e) {
        return ResponseEntity.status(404).body(ApiError.of("USER_NOT_FOUND", e.getMessage()));
    }
}
```

**面试加分点**：`WebMvc.fn` 依然走 `DispatcherServlet`，所以 `@ControllerAdvice`、`HandlerExceptionResolver` 全部生效。但 `WebFlux.fn` 下要用 `@ControllerAdvice` 或 `WebExceptionHandler`。

### 7.2 内容协商

```java
ServerResponse.ok().contentType(MediaType.APPLICATION_JSON).body(dto);
// 或让 Spring 根据 Accept 自动协商
ServerResponse.ok().body(dto);
```

`ServerResponse.body()` 会经过 `HttpMessageConverter` 链按 `Accept` 协商，和注解式一致。

---

## 八、测试：`WebTestClient` 与 `MockMvc`

函数式端点最大的好处之一就是**好测**：

```java
@WebMvcTest
class UserRoutesTest {
    @Autowired MockMvc mockMvc;

    @Test
    void get_user() throws Exception {
        mockMvc.perform(get("/api/users/1"))
               .andExpect(status().isOk())
               .andExpect(jsonPath("$.name").value("东哥"));
    }
}
```

`RouterFunction` 本身也是纯函数，可以直接单测**路由匹配**，不用启动容器：

```java
@Test
void route_matches() {
    RouterFunction<ServerResponse> r = route().GET("/ping", req -> ServerResponse.ok().build()).build();
    MockServerRequest request = MockServerRequest.builder().method(HttpMethod.GET).uri(URI.create("/ping")).build();
    assertThat(r.route(request)).isPresent();
}
```

**这是注解式做不到的**——注解路由的匹配逻辑藏在 `RequestMappingHandlerMapping` 里，只能通过容器集成测试验证。

---

## 九、面试常见追问

**Q1：函数式端点和 `@Controller` 性能差多少？**
**几乎没有差别**（<5%）。因为 `RouterFunctionMapping` 内部也是遍历匹配，`@Controller` 也是。唯一区别是注解式会做预计算（`RequestMappingInfo` 索引），函数式是顺序 `route()` 匹配——**路由数量大（>1000）时建议用纯路径前缀 nest 分组，减少匹配开销**。

**Q2：`RouterFunction` 支持动态路由吗？**
支持，而且这是它的强项。你可以让 `route()` 返回的 `Optional` 依赖外部配置/DB，实现"运行时动态路由"。不过要注意**每次请求都查配置**的性能问题，通常会加本地缓存 + 版本号刷新。

**Q3：`filter()` 和实现 `HandlerInterceptor` 有什么区别？**
`HandlerFilterFunction` 只在函数式路由链上生效，且能精确绑定到某组路由；`HandlerInterceptor` 对所有 Handler（含注解式）生效。两者可以同时用，执行顺序由 `HandlerMapping` 决定。

**Q4：WebFlux 下能不能用阻塞的 JDBC？**
不能直接用，会阻塞 EventLoop 线程导致整个服务假死。必须用 R2DBC，或者用 `Schedulers.boundedElastic()` 显式切到阻塞线程池（有风险，要严格限制并发数）。

**Q5：为什么 Spring 要引入函数式端点？**
两个原因：① `RouterFunction` 返回 `Mono<HandlerFunction>`，让"路由决策"本身可以异步（微服务网关式场景）；② 让路由行为可编程、可测试，符合"composition over configuration"的设计哲学。

---

## 十、完整实战：一个可运行的用户模块

把前面所有片段拼起来，看一个完整的、可直接落地的写法。

**① Handler 类：只做业务，不关心路由**

```java
@Component
@RequiredArgsConstructor
public class UserHandler {
    private final UserService userService;

    public ServerResponse list(ServerRequest req) {
        int page = req.param("page").map(Integer::parseInt).orElse(1);
        int size = req.param("size").map(Integer::parseInt).orElse(20);
        PageResult<User> result = userService.page(page, Math.min(size, 100));
        return ServerResponse.ok().body(result);
    }

    public ServerResponse get(ServerRequest req) {
        Long id = Long.valueOf(req.pathVariable("id"));
        User user = userService.getById(id);
        if (user == null) {
            return ServerResponse.status(HttpStatus.NOT_FOUND)
                    .body(ApiError.of("USER_NOT_FOUND", "用户不存在"));
        }
        return ServerResponse.ok().body(user);
    }

    public ServerResponse create(ServerRequest req) throws Exception {
        CreateUserCmd cmd = req.body(CreateUserCmd.class);   // 自动校验可配合 Validator
        User created = userService.create(cmd);
        return ServerResponse.created(URI.create("/api/v1/users/" + created.getId()))
                .body(created);
    }

    public ServerResponse update(ServerRequest req) throws Exception {
        Long id = Long.valueOf(req.pathVariable("id"));
        UpdateUserCmd cmd = req.body(UpdateUserCmd.class);
        userService.update(id, cmd);
        return ServerResponse.noContent().build();
    }
}
```

**② Router 配置：只做路由与横切**

```java
@Configuration
@RequiredArgsConstructor
public class UserRouterConfig {
    private final UserHandler userHandler;

    @Bean
    public RouterFunction<ServerResponse> userRoutes() {
        return route()
            .nest(path("/api/v1/users"), b -> b
                .GET("", userHandler::list)
                .GET("/{id}", userHandler::get)
                .POST("", contentType(MediaType.APPLICATION_JSON), userHandler::create)
                .PUT("/{id}", userHandler::update))
            .filter(this::requireLogin)
            .build();
    }

    private ServerResponse requireLogin(ServerRequest req, HandlerFunction<ServerResponse> next)
            throws Exception {
        Object userId = req.attributes().get("userId");
        if (userId == null) {
            return ServerResponse.status(HttpStatus.UNAUTHORIZED)
                    .body(ApiError.of("UNAUTHORIZED", "请先登录"));
        }
        return next.handle(req);
    }
}
```

**③ 注意三个易错点**

- `nest(path(...))` 里的路径必须**以 `/` 开头且不带尾斜杠**，子路由写相对路径（`""` 表示前缀本身）；
- `POST/PUT` 一定要显式加 `contentType(APPLICATION_JSON)`，否则一个错误 Content-Type 的请求会先被路由命中、再在 `body()` 时报 415；
- `filter()` 的调用要放在 `nest()` 之后，才能覆盖整组路由；放在某个 `GET()` 之后是**不生效**的（`filter` 是 `RouterFunction` 上的方法，不是 builder 的）。

**④ 与参数校验集成**

函数式端点默认不触发 `@Valid`，需要在 Handler 里手动调用 `Validator`：

```java
private final Validator validator;

public ServerResponse create(ServerRequest req) throws Exception {
    CreateUserCmd cmd = req.body(CreateUserCmd.class);
    Set<ConstraintViolation<CreateUserCmd>> violations = validator.validate(cmd);
    if (!violations.isEmpty()) {
        String msg = violations.stream()
                .map(v -> v.getPropertyPath() + " " + v.getMessage())
                .collect(Collectors.joining("; "));
        return ServerResponse.badRequest().body(ApiError.of("INVALID_PARAM", msg));
    }
    // ...
}
```

这一点经常被忽略：**注解式的 `@Valid` 是框架帮忙做的，函数式必须自己接**。想省事可以写一个通用的 `validate` Filter。

---

## 十一、收益与代价：什么时候该用它

| 场景 | 推荐 |
| --- | --- |
| 业务 CRUD 接口 | 注解式更省事 |
| API 网关 / 动态路由转发 | **函数式更合适** |
| 多租户按配置组装路由 | **函数式（路由即代码）** |
| 高并发流式接口（WebFlux） | **函数式 + 反应式** |
| 团队不熟函数式 | 别引入，维护成本 > 收益 |

一句话：**函数式的收益在"路由需要被编程"的场景，而不是"少写注解"**。如果只是为了代码看起来简洁而全面改造，反而会让新同事找不到接口入口。

---

## 总结

函数式 Web 端点，记住这张图就够了：

```text
请求 ──→ RequestPredicate（GET/POST/path/accept...）
              │ 命中
              ▼
         HandlerFilterFunction（洋葱模型：trace→auth→limit）
              │
              ▼
         HandlerFunction（业务，返回 ServerResponse）
              │
              ▼
         HttpMessageConverter（JSON 序列化）
```

三个要点：

1. **路由即代码**：`RouterFunction.nest()` + `RequestPredicates` 组合，比注解更灵活、更可测；
2. **Filter 是函数式的**：`HandlerFilterFunction` 能按路由精确绑定，是它相对 `Filter` 的最大优势；
3. **别搞混 WebMvc.fn 与 WebFlux.fn**：前者阻塞（一请求一线程），后者 `Mono`（EventLoop），选型看你的 IO 模型，不要为了"函数式"强行上反应式。

下次面试官问"有没有用过 Spring 的函数式端点"，你就能从 `HandlerFunction` 讲到 `WebFlux.fn` 的线程模型差异——这个知识点在候选人里覆盖率极低，属于容易被反杀的加分项。
