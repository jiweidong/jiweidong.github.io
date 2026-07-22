---
title: 【Spring Boot 3.x 实战】RFC 7807 Problem Details 错误响应规范与 ErrorController 深度解析
date: 2026-07-22 08:00:00
tags:
  - Spring Boot
  - 异常处理
  - REST
  - 规范
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 3.x 实战】RFC 7807 Problem Details 错误响应规范与 ErrorController 深度解析

## 一、为什么需要统一的错误响应格式？

在微服务架构中，服务间 API 调用频繁。如果每个服务返回的错误格式都不一样，调用方解析时会非常痛苦：

```json
// 服务 A 的错误格式
{ "code": 500, "msg": "系统异常", "timestamp": 1700000000 }

// 服务 B 的错误格式
{ "status": 500, "message": "Internal Server Error", "path": "/api/orders" }

// 服务 C 的错误格式
{ "error": { "code": "SYS_ERROR", "detail": "服务繁忙" } }
```

这直接导致了两个核心问题：

1. **调用方需要为每个下游服务编写不同的错误解析逻辑**
2. **监控系统难以统一采集和聚合错误信息**

**RFC 7807**（Problem Details for HTTP APIs）正是为了解决这个问题而诞生的标准化规范。Spring Boot 3.x（Spring 6.x）对其提供了原生支持。

## 二、RFC 7807 规范详解

### 2.1 标准响应结构

RFC 7807 定义了一个标准化的 JSON 错误响应格式：

```json
{
  "type": "https://api.example.com/errors/order-not-found",
  "title": "Order Not Found",
  "status": 404,
  "detail": "Order with ID 12345 does not exist",
  "instance": "/api/orders/12345"
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `type` | 是 | 问题类型的 URI（可指向文档） |
| `title` | 是 | 简短的人类可读描述 |
| `status` | 是 | HTTP 状态码 |
| `detail` | 否 | 详细的错误说明 |
| `instance` | 否 | 发生错误的 URI 引用 |

### 2.2 扩展字段

RFC 7807 允许添加自定义扩展字段：

```json
{
  "type": "https://api.example.com/errors/validation-failed",
  "title": "Validation Failed",
  "status": 422,
  "detail": "Request validation failed",
  "instance": "/api/users",
  "errors": [
    { "field": "email", "message": "邮箱格式不正确" },
    { "field": "age", "message": "年龄必须在 18-100 之间" }
  ],
  "timestamp": "2026-07-22T08:00:00.123+08:00",
  "traceId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

## 三、Spring Boot 3.x 的 ProblemDetails 支持

### 3.1 自动配置

Spring Boot 3.x 在引入 `spring-webmvc` 或 `spring-webflux` 后，**默认启用** Problem Details 支持。只需要在配置中开启即可：

```yaml
spring:
  mvc:
    problemdetails:
      enabled: true    # Spring MVC 启用
  webflux:
    problemdetails:
      enabled: true    # WebFlux 启用
```

### 3.2 底层实现类

Spring 6 提供了 `org.springframework.web.ErrorResponse` 接口和 `ProblemDetail` 类：

```java
// ProblemDetail 的源码（简化版）
public class ProblemDetail implements ErrorResponse {
    private URI type;           // 问题类型 URI
    private String title;       // 标题
    private int status;         // HTTP 状态码
    private String detail;      // 详情
    private URI instance;       // 实例 URI
    private Map<String, Object> properties;  // 扩展属性
    
    // 工厂方法
    public static ProblemDetail forStatus(int status) {
        return new ProblemDetail(status);
    }
    
    public static ProblemDetail forStatusAndDetail(int status, String detail) {
        ProblemDetail pd = new ProblemDetail(status);
        pd.setDetail(detail);
        return pd;
    }
    
    // 设置扩展属性
    public void setProperty(String name, Object value) {
        if (this.properties == null) {
            this.properties = new LinkedHashMap<>();
        }
        this.properties.put(name, value);
    }
}
```

### 3.3 内置的异常映射

当 `spring.mvc.problemdetails.enabled=true` 时，Spring Boot 会自动将标准异常映射为 Problem Details 响应：

```java
// 默认映射关系
// 404 异常
throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Order not found");
// → { type: "about:blank", title: "Not Found", status: 404, detail: "Order not found" }

// 400 异常
throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Invalid request");
// → { type: "about:blank", title: "Bad Request", status: 400, detail: "Invalid request" }

// 500 异常
throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR);
// → { type: "about:blank", title: "Internal Server Error", status: 500 }
```

## 四、实战：自定义 Problem Details

### 4.1 自定义异常类

```java
// 自定义业务异常，继承 RuntimeException 并实现 ErrorResponse
public class OrderNotFoundException extends RuntimeException 
        implements ErrorResponse {
    
    private final Long orderId;
    private final String traceId;
    
    public OrderNotFoundException(Long orderId, String traceId) {
        super("Order not found: " + orderId);
        this.orderId = orderId;
        this.traceId = traceId;
    }
    
    @Override
    public ProblemDetail getBody() {
        // 创建 ProblemDetail
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(
            HttpStatus.NOT_FOUND, 
            this.getMessage()
        );
        
        // 设置 type 指向错误文档
        problem.setType(URI.create("https://api.example.com/errors/order-not-found"));
        // 设置 title
        problem.setTitle("Order Not Found");
        // 设置 instance
        problem.setInstance(URI.create("/api/orders/" + orderId));
        
        // 添加扩展属性
        problem.setProperty("orderId", orderId);
        problem.setProperty("traceId", traceId);
        problem.setProperty("timestamp", Instant.now().toString());
        
        return problem;
    }
    
    @Override
    public HttpStatusCode getStatusCode() {
        return HttpStatus.NOT_FOUND;
    }
}
```

### 4.2 全局异常处理 + Problem Details

```java
@RestControllerAdvice
@Slf4j
public class GlobalExceptionHandler {
    
    // 处理自定义业务异常（自动返回 RFC 7807 格式）
    @ExceptionHandler(OrderNotFoundException.class)
    public ProblemDetail handleOrderNotFound(OrderNotFoundException ex) {
        log.warn("订单不存在: {}", ex.getOrderId());
        return ex.getBody();  // 直接返回 ProblemDetail
    }
    
    // 处理参数校验异常
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ProblemDetail handleValidation(MethodArgumentNotValidException ex) {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.UNPROCESSABLE_ENTITY);
        problem.setTitle("Validation Failed");
        problem.setDetail("Request validation failed");
        
        // 收集校验错误
        List<FieldError> fieldErrors = ex.getBindingResult().getFieldErrors();
        List<Map<String, String>> errors = fieldErrors.stream()
            .map(fe -> Map.of(
                "field", fe.getField(),
                "message", fe.getDefaultMessage(),
                "rejectedValue", String.valueOf(fe.getRejectedValue())
            ))
            .collect(Collectors.toList());
        
        problem.setProperty("errors", errors);
        problem.setProperty("timestamp", Instant.now().toString());
        
        return problem;
    }
    
    // 统一处理未捕获异常
    @ExceptionHandler(Exception.class)
    public ProblemDetail handleUnexpected(Exception ex) {
        log.error("未处理的异常", ex);
        
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.INTERNAL_SERVER_ERROR);
        problem.setTitle("Internal Server Error");
        problem.setDetail("服务内部异常，请联系管理员");
        problem.setProperty("traceId", MDC.get("traceId"));
        
        return problem;
    }
}
```

### 4.3 通过 ErrorController 全局覆盖

如果你需要完全接管错误响应（包括进入 Filter 之前的错误），可以实现 `ErrorController`：

```java
@RestController
public class CustomErrorController implements ErrorController {
    
    @RequestMapping("/error")
    public ProblemDetail handleError(HttpServletRequest request) {
        Integer status = (Integer) request.getAttribute(
            RequestDispatcher.ERROR_STATUS_CODE);
        String message = (String) request.getAttribute(
            RequestDispatcher.ERROR_MESSAGE);
        String uri = (String) request.getAttribute(
            RequestDispatcher.ERROR_REQUEST_URI);
        
        HttpStatus httpStatus = status != null 
            ? HttpStatus.valueOf(status) 
            : HttpStatus.INTERNAL_SERVER_ERROR;
        
        ProblemDetail problem = ProblemDetail.forStatus(httpStatus);
        problem.setTitle(httpStatus.getReasonPhrase());
        problem.setDetail(message);
        problem.setInstance(URI.create(uri != null ? uri : "unknown"));
        problem.setProperty("timestamp", Instant.now().toString());
        problem.setProperty("traceId", MDC.get("traceId"));
        
        return problem;
    }
}
```

## 五、深入源码：Spring 如何渲染 ProblemDetails

### 5.1 核心处理链路

让我们看 Spring MVC 中 Problem Details 的渲染流程：

```
请求进入 Controller
    ↓ 抛出异常
DispatcherServlet 的 HandlerExceptionResolver 链
    ↓ 匹配 ExceptionHandlerExceptionResolver
@ExceptionHandler 方法返回 ProblemDetail
    ↓
AbstractMessageConverterMethodProcessor.writeWithMessageConverters()
    ↓
查找能处理 ProblemDetail 的 HttpMessageConverter
    ↓
ProblemDetailHttpMessageConverter（Spring 6 新增）
    ↓
序列化为标准 JSON
```

### 5.2 ProblemDetailHttpMessageConverter 源码分析

```java
// Spring 6 新增的转换器
public class ProblemDetailHttpMessageConverter 
        extends AbstractJackson2HttpMessageConverter {
    
    public ProblemDetailHttpMessageConverter() {
        // 必须使用 application/problem+json 媒体类型
        super(MediaType.APPLICATION_PROBLEM_JSON,
              MediaType.APPLICATION_PROBLEM_JSON_UTF8);
    }
    
    @Override
    protected boolean supports(Class<?> clazz) {
        return ProblemDetail.class.isAssignableFrom(clazz);
    }
    
    // 序列化时自动添加媒体类型
    @Override
    protected void addDefaultHeaders(HttpHeaders headers, 
                                     ProblemDetail t, MediaType type) {
        if (headers.getContentType() == null) {
            headers.setContentType(MediaType.APPLICATION_PROBLEM_JSON);
        }
    }
}
```

关键点：RFC 7807 规范要求的 Content-Type 是 `application/problem+json`，Spring 自动完成了这个设置。

### 5.3 自定义渲染（如果需要）

如果你想完全控制序列化过程：

```java
@Component
public class CustomProblemDetailConverter 
        extends ProblemDetailHttpMessageConverter {
    
    @Override
    protected void writeInternal(ProblemDetail problemDetail, 
                                  HttpOutputMessage outputMessage) 
            throws IOException, HttpMessageNotWritableException {
        
        // 在序列化之前添加统一字段
        problemDetail.setProperty("serviceName", applicationName);
        problemDetail.setProperty("environment", activeProfile);
        
        super.writeInternal(problemDetail, outputMessage);
    }
}
```

## 六、与 Spring Security 集成

Spring Security 的异常处理也可以整合 Problem Details：

```java
@Configuration
public class SecurityConfig {
    
    @Bean
    public AuthenticationEntryPoint authenticationEntryPoint() {
        return (request, response, authException) -> {
            ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.UNAUTHORIZED);
            problem.setTitle("Unauthorized");
            problem.setDetail("需要登录才能访问此资源");
            problem.setInstance(URI.create(request.getRequestURI()));
            problem.setProperty("timestamp", Instant.now().toString());
            
            response.setContentType("application/problem+json;charset=UTF-8");
            response.setStatus(HttpStatus.UNAUTHORIZED.value());
            response.getWriter().write(
                new ObjectMapper().writeValueAsString(problem)
            );
        };
    }
    
    @Bean
    public AccessDeniedHandler accessDeniedHandler() {
        return (request, response, accessDeniedException) -> {
            ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.FORBIDDEN);
            problem.setTitle("Forbidden");
            problem.setDetail("没有权限访问此资源");
            problem.setInstance(URI.create(request.getRequestURI()));
            
            response.setContentType("application/problem+json;charset=UTF-8");
            response.setStatus(HttpStatus.FORBIDDEN.value());
            response.getWriter().write(
                new ObjectMapper().writeValueAsString(problem)
            );
        };
    }
}
```

## 七、最佳实践与避坑

### 7.1 type 字段设计

`type` 推荐指向一个可访问的文档页面：

```java
// 好的做法：指向文档
problem.setType(URI.create("https://docs.example.com/errors/out-of-stock"));

// 不推荐：about:blank（只有框架内置异常才用）
// Spring 默认设置为 about:blank
```

### 7.2 不要直接暴露堆栈信息

```java
// ❌ 错误：暴露了内部实现
problem.setDetail("NullPointerException at com.example.service.OrderService.getOrder(101)");

// ✅ 正确：只暴露业务可读信息
problem.setDetail("订单状态不允许当前操作");
```

### 7.3 国际化支持

```java
@RestControllerAdvice
public class I18nProblemDetailHandler {
    
    private final MessageSource messageSource;
    
    @ExceptionHandler(OrderNotFoundException.class)
    public ProblemDetail handle(OrderNotFoundException ex, Locale locale) {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
        problem.setTitle(messageSource.getMessage(
            "error.order.notfound.title", null, locale));
        problem.setDetail(messageSource.getMessage(
            "error.order.notfound.detail", 
            new Object[]{ex.getOrderId()}, locale));
        return problem;
    }
}
```

### 7.4 兼容旧版客户端

如果你的部分调用方还不支持 RFC 7807，可以通过内容协商兼容：

```java
@RestControllerAdvice
public class CompatibleErrorHandler {
    
    @ExceptionHandler(BusinessException.class)
    public Object handle(BusinessException ex, HttpServletRequest request) {
        String accept = request.getHeader("Accept");
        
        if (accept != null && accept.contains("application/problem+json")) {
            // 新客户端：返回 RFC 7807 格式
            ProblemDetail problem = ProblemDetail.forStatus(ex.getStatus());
            problem.setTitle(ex.getTitle());
            problem.setDetail(ex.getMessage());
            return problem;
        } else {
            // 旧客户端：返回传统格式
            return Map.of(
                "code", ex.getStatus().value(),
                "message", ex.getMessage(),
                "timestamp", Instant.now().toEpochMilli()
            );
        }
    }
}
```

## 八、面试常见追问

> **Q1：RFC 7807 和 OpenAPI 3.0 的 error 模型冲突吗？**

不冲突。OpenAPI 3.0 的 `discriminator` 模型可以引用 RFC 7807 的 `Problem` schema。实际上 OpenAPI 规范中推荐使用 RFC 7807 作为错误响应格式。

> **Q2：WebFlux 下的 Problem Details 支持如何？**

完全一致。`spring-webflux` 提供了 `ProblemDetail` 和 `ErrorResponse` 的响应式支持，`@ExceptionHandler` 在 WebFlux 中同样生效。

> **Q3：性能方面有没有影响？**

微乎其微。ProblemDetail 只是一个 POJO，序列化开销和普通 JSON 响应完全一致。额外的字段（type、title 等）都是轻量字符串。

## 九、总结

RFC 7807 Problem Details 为 REST API 提供了一套标准化、可扩展的错误响应格式。Spring Boot 3.x 的原生支持让集成变得非常简单——开启配置后，连框架内置异常都会自动转换为标准格式。

在微服务架构中，推行统一的错误响应规范是提升系统可维护性的重要一环。RFC 7807 加上自定义扩展字段，足以覆盖 99% 的 API 错误场景。
