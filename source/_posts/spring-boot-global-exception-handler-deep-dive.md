---
title: Spring Boot 全局异常处理：从 @ControllerAdvice 到源码原理
date: 2026-06-27 08:00:04
tags:
  - Java
  - Spring Boot
  - 异常处理
categories:
  - Java
  - Spring Boot
author: 东哥
---

# Spring Boot 全局异常处理：从 @ControllerAdvice 到源码原理

## 一、为什么需要全局异常处理？

没有全局异常处理的 Controller 代码是这样的：

```java
@RestController
@RequestMapping("/api/users")
public class UserController {
    
    @GetMapping("/{id}")
    public Result getUser(@PathVariable Long id) {
        try {
            User user = userService.findById(id);
            if (user == null) {
                return Result.error(404, "用户不存在");
            }
            return Result.success(user);
        } catch (Exception e) {
            log.error("查询用户失败", e);
            return Result.error(500, "系统错误");
        }
    }
}
```

每个方法都要 try-catch，又丑又容易遗漏。使用全局异常处理后，Controller 回归清爽：

```java
@RestController
@RequestMapping("/api/users")
public class UserController {
    
    @GetMapping("/{id}")
    public Result<User> getUser(@PathVariable Long id) {
        // 不用 try-catch，异常交给全局处理器
        User user = userService.findById(id);
        return Result.success(user);
    }
}
```

## 二、@ControllerAdvice 入门

### 2.1 基础用法

```java
@RestControllerAdvice  // = @ControllerAdvice + @ResponseBody
public class GlobalExceptionHandler {
    
    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);
    
    // 处理所有未捕获的异常
    @ExceptionHandler(Exception.class)
    public Result<Void> handleException(Exception e) {
        log.error("系统异常", e);
        return Result.error(500, "服务器繁忙，请稍后再试");
    }
    
    // 处理特定异常
    @ExceptionHandler(NullPointerException.class)
    public Result<Void> handleNullPointer(NullPointerException e) {
        log.error("空指针异常", e);
        return Result.error(500, "系统内部错误");
    }
}
```

### 2.2 细化异常分类

```java
@RestControllerAdvice
public class GlobalExceptionHandler {
    
    // 1. 参数校验异常
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public Result<Map<String, String>> handleValidation(
            MethodArgumentNotValidException e) {
        Map<String, String> errors = new HashMap<>();
        e.getBindingResult().getAllErrors().forEach(error -> {
            String field = ((FieldError) error).getField();
            String msg = error.getDefaultMessage();
            errors.put(field, msg);
        });
        return Result.error(400, "参数校验失败", errors);
    }
    
    // 2. 业务异常
    @ExceptionHandler(BusinessException.class)
    public Result<Void> handleBusiness(BusinessException e) {
        log.warn("业务异常: {}", e.getMessage());
        return Result.error(e.getCode(), e.getMessage());
    }
    
    // 3. 资源不存在
    @ExceptionHandler(ResourceNotFoundException.class)
    @ResponseStatus(HttpStatus.NOT_FOUND)
    public Result<Void> handleNotFound(ResourceNotFoundException e) {
        return Result.error(404, e.getMessage());
    }
    
    // 4. 无权限访问
    @ExceptionHandler(AccessDeniedException.class)
    @ResponseStatus(HttpStatus.FORBIDDEN)
    public Result<Void> handleAccessDenied(AccessDeniedException e) {
        return Result.error(403, "没有权限访问");
    }
    
    // 5. 请求方法不支持
    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public Result<Void> handleMethodNotSupported(HttpRequestMethodNotSupportedException e) {
        return Result.error(405, "不支持的请求方法: " + e.getMethod());
    }
    
    // 6. 参数类型转换异常
    @ExceptionHandler(HttpMessageConversionException.class)
    public Result<Void> handleMessageConversion(HttpMessageConversionException e) {
        log.warn("参数转换异常", e);
        return Result.error(400, "请求参数格式不正确");
    }
    
    // 7. 兜底
    @ExceptionHandler(Exception.class)
    public Result<Void> handleException(Exception e) {
        log.error("未捕获异常", e);
        return Result.error(500, "服务器内部错误");
    }
}
```

## 三、自定义业务异常

创建业务异常是全局异常处理的最佳实践：

```java
// 基础业务异常
public class BusinessException extends RuntimeException {
    private final int code;
    
    public BusinessException(int code, String message) {
        super(message);
        this.code = code;
    }
    
    public BusinessException(String message) {
        this(500, message);
    }
    
    public int getCode() {
        return code;
    }
}

// 更细粒度的异常
public class ResourceNotFoundException extends BusinessException {
    public ResourceNotFoundException(String resource, Object id) {
        super(404, resource + " 不存在: " + id);
    }
}

public class UnauthorizedException extends BusinessException {
    public UnauthorizedException(String message) {
        super(401, message);
    }
}

public class ForbiddenException extends BusinessException {
    public ForbiddenException(String message) {
        super(403, message);
    }
}
```

在业务代码中使用：

```java
@Service
public class UserService {
    
    @Autowired
    private UserRepository userRepository;
    
    public User findById(Long id) {
        return userRepository.findById(id)
            .orElseThrow(() -> new ResourceNotFoundException("用户", id));
    }
    
    public User updatePassword(Long id, String oldPwd, String newPwd) {
        User user = findById(id);
        if (!user.getPassword().equals(oldPwd)) {
            throw new BusinessException("原密码不正确");
        }
        user.setPassword(newPwd);
        return userRepository.save(user);
    }
}
```

## 四、统一响应体格式

```java
@Data
@NoArgsConstructor
@AllArgsConstructor
public class Result<T> {
    private int code;
    private String message;
    private T data;
    private long timestamp;
    
    public static <T> Result<T> success(T data) {
        return new Result<>(200, "success", data, System.currentTimeMillis());
    }
    
    public static <T> Result<T> success() {
        return success(null);
    }
    
    public static <T> Result<T> error(int code, String message) {
        return new Result<>(code, message, null, System.currentTimeMillis());
    }
    
    public static <T> Result<T> error(int code, String message, T data) {
        return new Result<>(code, message, data, System.currentTimeMillis());
    }
}
```

## 五、进阶：处理上下文与国际化

### 5.1 获取请求上下文

```java
@RestControllerAdvice
public class AdvancedExceptionHandler {
    
    @ExceptionHandler(BusinessException.class)
    public Result<Void> handleBusiness(BusinessException e, 
                                        HttpServletRequest request) {
        String requestURI = request.getRequestURI();
        String method = request.getMethod();
        String ip = request.getRemoteAddr();
        
        log.warn("业务异常 | URI: {} {} | IP: {} | 异常: {}", 
            method, requestURI, ip, e.getMessage());
        
        return Result.error(e.getCode(), e.getMessage());
    }
}
```

### 5.2 国际化的错误消息

```java
@Component
public class I18nExceptionHandler {
    
    @Autowired
    private MessageSource messageSource;
    
    @ExceptionHandler(BusinessException.class)
    public Result<Void> handle(BusinessException e, 
                                HttpServletRequest request) {
        Locale locale = RequestContextUtils.getLocale(request);
        String message = messageSource.getMessage(
            e.getMessageKey(), e.getArgs(), 
            e.getMessage(), locale);
        return Result.error(e.getCode(), message);
    }
}
```

### 5.3 敏感信息脱敏

```java
@ExceptionHandler(Exception.class)
public Result<Void> handleException(Exception e, HttpServletRequest request) {
    // 脱敏处理敏感参数
    String queryString = sanitizeSensitiveParams(request.getQueryString());
    
    log.error("未捕获异常 | URI: {}?{} | 异常: {}", 
        request.getRequestURI(), 
        queryString,
        e.getMessage(), e);
    
    // 生产环境不泄露详细错误信息
    return Result.error(500, "服务器繁忙，请稍后再试");
}

private String sanitizeSensitiveParams(String queryString) {
    if (queryString == null) return null;
    return queryString.replaceAll("password=[^&]*", "password=****")
                      .replaceAll("token=[^&]*", "token=****")
                      .replaceAll("secret=[^&]*", "secret=****");
}
```

## 六、源码原理：异常处理是怎么工作的？

### 6.1 核心组件

```
DispatcherServlet
    ↓ 请求处理过程中发生异常
ExceptionHandlerExceptionResolver（核心异常解析器）
    ↓ 寻找匹配的 @ExceptionHandler 方法
HandlerMethod（包装的异常处理方法）
    ↓ 通过反射调用
全局/局部异常处理方法
    ↓ 返回 ModelAndView / @ResponseBody 结果
正常视图/消息处理流程
```

### 6.2 源码关键路径

Spring MVC 异常处理的核心是 `DispatcherServlet.processDispatchResult()`：

```java
// DispatcherServlet.java (简化)
private void processDispatchResult(...) {
    // 1. 判断是否有异常
    if (exception != null) {
        // 2. 交给 HandlerExceptionResolver 链处理
        ModelAndView mv;
        try {
            mv = handlerExceptionResolvers.get(0)
                     .resolveException(request, response, handler, exception);
        } catch (Exception ex) {
            // 解析器本身也有异常……
        }
    }
}
```

`ExceptionHandlerExceptionResolver` 的 `doResolveHandlerMethodException` 方法：

```java
@Override
protected ModelAndView doResolveHandlerMethodException(...) {
    // 1. 从已注册的 @ControllerAdvice 中查找
    // 2. 从当前 Controller 中查找 @ExceptionHandler
    ServletInvocableHandlerMethod exceptionHandlerMethod = 
        getExceptionHandlerMethod(handlerMethod, exception);
    
    if (exceptionHandlerMethod == null) {
        return null;  // 没有找到处理器，继续走下一个 Resolver
    }
    
    // 3. 调用异常处理方法
    exceptionHandlerMethod.invokeAndHandle(webRequest, mavContainer, 
        exception, handlerMethod);
    
    // 4. 返回 ModelAndView
    return getModelAndView(mavContainer, ...);
}
```

**异常匹配规则**：

```
@ExceptionHandler(RuntimeException.class)
匹配：RuntimeException 及其子类

@ExceptionHandler(Exception.class)
匹配：所有 Exception

匹配顺序：精确匹配 > 父类匹配
同一层级多个异常类型时，按方法定义的顺序
```

**⚠️ 注意**：如果有多个 `@ExceptionHandler` 能匹配同一个异常，Spring 会选择**最精确的匹配**。如果精度相同，则按方法定义顺序。

### 6.3 @ControllerAdvice vs @RestControllerAdvice

```java
@ControllerAdvice             // 返回 ModelAndView（适合模板引擎）
@RestControllerAdvice         // = @ControllerAdvice + @ResponseBody，返回 JSON
```

## 七、Spring Boot 默认的错误页面是怎么工作的？

Spring Boot 提供了 `ErrorMvcAutoConfiguration` 自动配置：

```java
// 默认的错误处理机制
// ErrorController → BasicErrorController
// /error 端点，返回错误信息 JSON 或错误页面
```

禁用默认错误页面（如果你有自己的全局处理）：

```yaml
# application.yml
server:
  error:
    include-message: never  # 不包含错误详情
    include-stacktrace: never
    whitelabel:
      enabled: false  # 关闭默认页面
```

## 八、最佳实践清单

### ✅ 推荐做法

1. **分层异常**：框架异常 → 业务异常(BusinessException) → 系统异常
2. **统一响应格式**：code + message + data + timestamp
3. **异常日志分级**：业务异常用 warn，系统异常用 error
4. **兜底处理器**：最顶层的 `@ExceptionHandler(Exception.class)` 不能丢
5. **自定义业务异常**：不直接 throw RuntimeException
6. **敏感信息不泄露**：生产环境不返回异常堆栈
7. **区分 4xx 和 5xx**：客户端错误和服务端错误分清楚

### ❌ 避免做法

1. **Controller 中 try-catch** 所有异常——失去了全局处理的意义
2. **全局处理器中继续抛异常**——造成死循环
3. **在异常处理中做耗时操作**（如发送 HTTP 请求）
4. **堆栈信息返回给前端**——安全漏洞
5. **异常处理忽略日志**——排查问题全靠猜

### 模板代码

每次新建 Spring Boot 项目，先写好异常处理基础设施：

```java
// 1. 统一 Result 类 ✓
// 2. 自定义 BusinessException ✓
// 3. GlobalExceptionHandler（覆盖主流异常） ✓
// 4. 配置 server.error 关闭默认错误页 ✓
```

全局异常处理是 Spring Boot 项目中性价比最高的代码之一——写一次，全项目受益。无论是参数校验、业务异常还是系统异常，都能用统一的方式优雅处理，既节省代码量又保证接口一致性。
