---
title: 【Spring Boot 3.x】RestClient 新特性全面解析：从 RestTemplate 到 RestClient 迁移实战
date: 2026-07-10 08:00:15
tags:
  - Spring Boot
  - HTTP客户端
  - RestClient
categories:
  - Java
  - Spring
author: 东哥
---

# 【Spring Boot 3.x】RestClient 新特性全面解析：从 RestTemplate 到 RestClient 迁移实战

## 引言

Spring Framework 6.1 / Spring Boot 3.2 引入了一个全新的 HTTP 客户端——**RestClient**。它是 Spring 团队对已有 HTTP 客户端（RestTemplate、WebClient）的反思和总结后的产物：

- **RestTemplate**：阻塞式，API 重载过多，用法不够直观
- **WebClient**：响应式，功能强大但对同步场景而言过于厚重
- **RestClient**：阻塞式 + 流式 API = 两者的最佳结合

本文将全面解析 RestClient 的设计理念、API 用法、配置方式以及从 RestTemplate 迁移的全流程。

---

## 一、为什么需要 RestClient？

### 1.1 RestTemplate 的问题

```java
// RestTemplate 的常见痛点
RestTemplate restTemplate = new RestTemplate();

// 痛点1：方法重载过多
// getForObject、getForEntity、exchange、execute 等方法大量重载
String result1 = restTemplate.getForObject(url, String.class);
ResponseEntity<String> result2 = restTemplate.getForEntity(url, String.class);
String result3 = restTemplate.getForObject(url, String.class, params);

// 痛点2：错误处理不直观
try {
    ResponseEntity<User> response = restTemplate.getForEntity(
        url, User.class);
    // 只有 2xx 才会返回，其他状态码抛出异常
} catch (HttpClientErrorException e) {
    // 4xx 错误
} catch (HttpServerErrorException e) {
    // 5xx 错误
} catch (ResourceAccessException e) {
    // 连接超时等
}

// 痛点3：没有流畅的链式调用
// 需要手动构造 Header、Entity 等
HttpHeaders headers = new HttpHeaders();
headers.setBearerAuth(token);
headers.setContentType(MediaType.APPLICATION_JSON);
HttpEntity<User> requestEntity = new HttpEntity<>(user, headers);
ResponseEntity<String> response = restTemplate.exchange(
    url, HttpMethod.POST, requestEntity, String.class);
```

### 1.2 WebClient 的问题

```java
// WebClient 虽然功能强大，但对同步场景太重
// 同步场景也需要引入 reactive 依赖
// 需要调用 .block() 将异步转为同步

// 同步调用需要一个 .block() 调用
User user = webClient.get()
    .uri("/users/{id}", id)
    .retrieve()
    .bodyToMono(User.class)
    .block();  // 容易忘记调用，抛出异常
```

### 1.3 RestClient 的设计目标

```java
// RestClient = RestTemplate 的简洁 + WebClient 的流式 API
// 同步、阻塞式、流式 API
```

| 特性 | RestTemplate | WebClient | RestClient |
|------|-------------|-----------|------------|
| 同步/阻塞 | ✅ | ❌（需要 .block()） | ✅ |
| 流式 API | ❌ | ✅ | ✅ |
| 响应式 | ❌ | ✅ | ❌ |
| 错误处理 | 异常机制 | 状态处理器 | 状态处理器 |
| 可扩展性 | ClientHttpRequestInterceptor | ExchangeFilterFunction | RestClientInterceptor |
| 依赖 | spring-web | spring-webflux | spring-web |

---

## 二、RestClient 快速上手

### 2.1 基础用法

```java
// 方式一：直接创建
RestClient restClient = RestClient.create();
RestClient restClient = RestClient.create("https://api.example.com");

// 方式二：使用 Builder
RestClient restClient = RestClient.builder()
    .baseUrl("https://api.example.com")
    .defaultHeader("Authorization", "Bearer " + token)
    .defaultHeader("Accept", "application/json")
    .requestInterceptor(myInterceptor)
    .build();

// 方式三：在 Spring Bean 中注入
@Service
public class UserService {
    private final RestClient restClient;

    public UserService(RestClient.Builder builder) {
        this.restClient = builder
            .baseUrl("https://api.example.com")
            .defaultHeader("Accept", "application/json")
            .build();
    }
}
```

### 2.2 GET 请求

```java
// 最简：获取 String 响应
String result = restClient.get()
    .uri("/users")
    .retrieve()
    .body(String.class);

// 获取对象
List<User> users = restClient.get()
    .uri("/users")
    .retrieve()
    .body(new ParameterizedTypeReference<List<User>>() {});

// 带路径参数
User user = restClient.get()
    .uri("/users/{id}", userId)
    .retrieve()
    .body(User.class);

// 带查询参数
List<User> users = restClient.get()
    .uri(uriBuilder -> uriBuilder
        .path("/users/search")
        .queryParam("name", keyword)
        .queryParam("page", 0)
        .queryParam("size", 20)
        .build())
    .retrieve()
    .body(new ParameterizedTypeReference<List<User>>() {});

// 获取完整响应，包含状态码和Header
ResponseEntity<User> response = restClient.get()
    .uri("/users/{id}", userId)
    .retrieve()
    .toEntity(User.class);

HttpStatus statusCode = response.getStatusCode();
HttpHeaders headers = response.getHeaders();
User body = response.getBody();
```

### 2.3 POST 请求

```java
// POST JSON 对象
User created = restClient.post()
    .uri("/users")
    .contentType(MediaType.APPLICATION_JSON)
    .body(new CreateUserRequest("alice", "alice@example.com"))
    .retrieve()
    .body(User.class);

// 获取完整响应
ResponseEntity<User> response = restClient.post()
    .uri("/users")
    .header("X-Request-Id", UUID.randomUUID().toString())
    .body(new CreateUserRequest("bob", "bob@example.com"))
    .retrieve()
    .toEntity(User.class);

// 提交表单数据
String result = restClient.post()
    .uri("/login")
    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
    .body("username=admin&password=123456")
    .retrieve()
    .body(String.class);
```

### 2.4 PUT / DELETE / PATCH

```java
// PUT：更新资源
restClient.put()
    .uri("/users/{id}", userId)
    .contentType(MediaType.APPLICATION_JSON)
    .body(updateRequest)
    .retrieve()
    .toBodilessEntity(); // 不需要响应体时使用

// DELETE：删除资源
restClient.delete()
    .uri("/users/{id}", userId)
    .retrieve()
    .toBodilessEntity();

// PATCH：部分更新
User patched = restClient.patch()
    .uri("/users/{id}", userId)
    .contentType(MediaType.APPLICATION_JSON)
    .body(Map.of("email", "new-email@example.com"))
    .retrieve()
    .body(User.class);
```

---

## 三、高级特性

### 3.1 错误处理

RestClient 提供了声明式的错误处理方式，告别 try-catch 地狱：

```java
// 自定义错误处理
User user = restClient.get()
    .uri("/users/{id}", userId)
    .retrieve()
    .onStatus(HttpStatusCode::is4xxClientError, (request, response) -> {
        // 读取错误响应体
        byte[] body = response.getBody().readAllBytes();
        String errorBody = new String(body, StandardCharsets.UTF_8);
        log.error("Client error {}: {}", response.getStatusCode(), errorBody);
        throw new UserServiceException("User request failed: " + errorBody);
    })
    .onStatus(HttpStatusCode::is5xxServerError, (request, response) -> {
        throw new UserServiceException("Server error: "
            + response.getStatusCode());
    })
    .body(User.class);

// 全局默认错误处理器配置
RestClient restClient = RestClient.builder()
    .defaultStatusHandler(HttpStatusCode::is4xxClientError, (req, res) -> {
        log.error("4xx error: {} {}", res.getStatusCode(), req.getURI());
        throw new HttpClientErrorException(res.getStatusCode());
    })
    .defaultStatusHandler(HttpStatusCode::is5xxServerError, (req, res) -> {
        log.error("5xx error: {} {}", res.getStatusCode(), req.getURI());
        throw new HttpServerErrorException(res.getStatusCode());
    })
    .build();
```

### 3.2 拦截器（Interceptor）

类似 RestTemplate 的 `ClientHttpRequestInterceptor`：

```java
// 日志拦截器
public class LoggingInterceptor implements RestClientInterceptor {
    @Override
    public <T> T execute(HttpRequest request, byte[] body,
            RestClientInterceptorExecution execution) {
        long start = System.currentTimeMillis();
        log.info("→ {} {}", request.getMethod(), request.getURI());
        try {
            T result = execution.execute(request, body);
            long duration = System.currentTimeMillis() - start;
            log.info("← {} {} completed in {}ms",
                request.getMethod(), request.getURI(), duration);
            return result;
        } catch (Exception e) {
            log.error("✗ {} {} failed: {}",
                request.getMethod(), request.getURI(), e.getMessage());
            throw e;
        }
    }
}

// 重试拦截器
public class RetryInterceptor implements RestClientInterceptor {
    private final int maxRetries;
    private final Set<HttpStatusCode> retryableStatuses = Set.of(
        HttpStatus.TOO_MANY_REQUESTS,
        HttpStatus.SERVICE_UNAVAILABLE,
        HttpStatus.GATEWAY_TIMEOUT
    );

    public RetryInterceptor(int maxRetries) {
        this.maxRetries = maxRetries;
    }

    @Override
    public <T> T execute(HttpRequest request, byte[] body,
            RestClientInterceptorExecution execution) {
        Exception lastException = null;
        for (int attempt = 0; attempt <= maxRetries; attempt++) {
            try {
                if (attempt > 0) {
                    log.info("Retry attempt {}/{} for {} {}",
                        attempt, maxRetries, request.getMethod(),
                        request.getURI());
                    Thread.sleep(100L * (1L << attempt)); // 指数退避
                }
                return execution.execute(request, body);
            } catch (HttpStatusCodeException e) {
                if (attempt >= maxRetries
                        || !retryableStatuses.contains(e.getStatusCode())) {
                    throw e;
                }
                lastException = e;
            } catch (IOException e) {
                if (attempt >= maxRetries) {
                    throw new RuntimeException(e);
                }
                lastException = e;
            }
        }
        throw new RuntimeException("Failed after " + maxRetries + " retries",
            lastException);
    }
}

// 注册拦截器
RestClient restClient = RestClient.builder()
    .requestInterceptor(new LoggingInterceptor())
    .requestInterceptor(new RetryInterceptor(3))
    .build();
```

### 3.3 超时与连接池配置

```java
// 通过底层 HttpClient 配置（推荐使用 JDK HttpClient 或 Apache HC）
@Bean
public RestClient restClient(RestClient.Builder builder) {
    // 使用 JDK HttpClient 作为底层
    HttpClient jdkClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();

    ClientHttpRequestFactory requestFactory =
        new JdkClientHttpRequestFactory(jdkClient);

    // 或者使用 Apache HttpClient（需要额外依赖）
    // PoolingHttpClientConnectionManager pool = ...
    // CloseableHttpClient apacheClient = ...

    return builder
        .requestFactory(requestFactory)
        .build();
}

// 使用 properties 配置（Spring Boot auto-configuration）
// application.yml:
// spring:
//   restclient:
//     connect-timeout: 5s
//     read-timeout: 30s
```

### 3.4 URI Builder

```java
// 使用 UriBuilder 构建复杂 URI
URI uri = UriComponentsBuilder
    .fromUriString("https://api.example.com/users/search")
    .queryParam("name", "Alice")
    .queryParam("age", 25, 35)    // age=25&age=35
    .queryParam("page", 0)
    .queryParam("size", 20)
    .encode()
    .build()
    .toUri();

List<User> users = restClient.get()
    .uri(uri)
    .retrieve()
    .body(new ParameterizedTypeReference<List<User>>() {});
```

---

## 四、从 RestTemplate 迁移到 RestClient

### 4.1 对照迁移指南

| RestTemplate 写法 | 对应 RestClient 写法 |
|-------------------|---------------------|
| `restTemplate.getForObject(url, String.class)` | `restClient.get().uri(url).retrieve().body(String.class)` |
| `restTemplate.getForEntity(url, String.class)` | `restClient.get().uri(url).retrieve().toEntity(String.class)` |
| `restTemplate.postForObject(url, obj, String.class)` | `restClient.post().uri(url).body(obj).retrieve().body(String.class)` |
| `restTemplate.exchange(url, POST, entity, String.class)` | `restClient.post().uri(url).headers(h -> h.addAll(...)).body(...).retrieve().toEntity(String.class)` |
| `restTemplate.execute(url, ...)` | `restClient...retrieve().toEntity(...)` |
| try-catch 异常处理 | `onStatus()` 处理器 |

### 4.2 完整迁移示例

**RestTemplate 原始代码：**

```java
@Component
public class PaymentClient {
    private final RestTemplate restTemplate;

    public PaymentClient(RestTemplateBuilder builder) {
        this.restTemplate = builder
            .rootUri("https://payment.example.com")
            .setConnectTimeout(Duration.ofSeconds(3))
            .setReadTimeout(Duration.ofSeconds(10))
            .build();
    }

    public PaymentResponse createPayment(PaymentRequest request) {
        try {
            HttpHeaders headers = new HttpHeaders();
            headers.setContentType(MediaType.APPLICATION_JSON);
            headers.setBearerAuth(getToken());
            HttpEntity<PaymentRequest> entity =
                new HttpEntity<>(request, headers);

            ResponseEntity<PaymentResponse> response = restTemplate.exchange(
                "/api/payments",
                HttpMethod.POST,
                entity,
                PaymentResponse.class
            );
            return response.getBody();
        } catch (HttpClientErrorException e) {
            log.error("Payment client error: {}", e.getResponseBodyAsString());
            throw new PaymentException("Client error: "
                + e.getStatusCode());
        } catch (HttpServerErrorException e) {
            log.error("Payment server error");
            throw new PaymentException("Server error");
        } catch (ResourceAccessException e) {
            log.error("Payment connection timeout");
            throw new PaymentException("Connection timeout");
        }
    }
}
```

**使用 RestClient 重构：**

```java
@Component
public class PaymentClient {
    private final RestClient restClient;

    public PaymentClient(RestClient.Builder builder) {
        this.restClient = builder
            .baseUrl("https://payment.example.com")
            .defaultHeader("Content-Type", "application/json")
            .requestInterceptor((request, body, execution) -> {
                // 统一添加 Token
                request.getHeaders().setBearerAuth(getToken());
                return execution.execute(request, body);
            })
            .build();
    }

    public PaymentResponse createPayment(PaymentRequest request) {
        return restClient.post()
            .uri("/api/payments")
            .body(request)
            .retrieve()
            .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                String errorBody = new String(
                    res.getBody().readAllBytes(), StandardCharsets.UTF_8);
                log.error("Payment client error {}: {}",
                    res.getStatusCode(), errorBody);
                throw new PaymentException(
                    "Client error: " + res.getStatusCode());
            })
            .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                throw new PaymentException("Server error: "
                    + res.getStatusCode());
            })
            .onStatus(status -> status.value() == 408, (req, res) -> {
                throw new PaymentException("Request timeout");
            })
            .body(PaymentResponse.class);
    }
}
```

### 4.3 迁移注意事项

| 注意事项 | 说明 |
|---------|------|
| 区分 Header 类型 | RestTemplate 的 `HttpHeaders` 需要替换为 RestClient 的声明式 header 设置 |
| 错误处理迁移 | 从 catch 异常改为 `onStatus` 处理器 |
| URI 变量 | 两者都支持 `{id}` 占位符，语法相同 |
| 拦截器重命名 | `ClientHttpRequestInterceptor` → `RestClientInterceptor` |
| 序列化配置 | 通过 `RestClient.builder().messageConverters()` 配置 JSON 序列化 |

---

## 五、与 WebClient 的选择策略

### 5.1 场景对比

| 场景 | RestClient | WebClient |
|------|-----------|-----------|
| 同步阻塞调用 | ✅ 首选 | ❌ 需要 .block() |
| 响应式/异步链式 | ❌ | ✅ 首选 |
| 高并发小请求 | ✅ 配合连接池 | ✅ 原生异步 |
| 已有 RestTemplate 迁移 | ✅ 推荐 | ❌ 改动大 |
| 与 WebFlux 集成 | ❌ | ✅ 天然支持 |

### 5.2 选择指南

```
是否在 WebFlux 项目中？  → 是 → WebClient
                  → 否
                     ↓
是否已有大量 RestTemplate 代码？  → 是 → RestClient（渐进迁移）
                            → 否
                               ↓
需要异步/响应式支持？  → 是 → WebClient
                  → 否 → RestClient
```

---

## 六、最佳实践总结

1. **优先依赖注入 `RestClient.Builder`**，而非直接 `new`
2. **将错误处理逻辑封装到 `onStatus` 中**，保持业务代码干净
3. **使用拦截器处理横切关注点**：日志、认证、重试
4. **配置连接池和超时时间**，避免连接耗尽
5. **新项目直接用 RestClient**，废弃 RestTemplate

```java
// 推荐的配置 Bean 写法
@Configuration
public class RestClientConfig {
    @Bean
    public RestClient.Builder restClientBuilder() {
        return RestClient.builder()
            .requestInterceptor(new LoggingInterceptor())
            .defaultStatusHandler(HttpStatusCode::is4xxClientError,
                ClientErrorHandler::handle)
            .defaultStatusHandler(HttpStatusCode::is5xxServerError,
                ServerErrorHandler::handle);
    }
}
```

---

## 总结

RestClient 是 Spring 团队多年 HTTP 客户端使用经验的集大成者。它不是一次革命，而是一次优雅的进化——将 RestTemplate 的能力和 WebClient 的 API 风格合并为一个更易用的同步客户端。

对于已经开始使用 Spring Boot 3.2+ 的团队，**建议在新项目中全面采用 RestClient**，并逐步将现有的 RestTemplate 调用迁移过来。
