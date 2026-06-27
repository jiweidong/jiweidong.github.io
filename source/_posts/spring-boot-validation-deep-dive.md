---
title: Spring Boot 参数校验（@Valid/@Validated）从入门到源码
date: 2026-06-27 08:00:01
tags:
  - Java
  - Spring Boot
  - 校验
categories:
  - Java
  - Spring Boot
author: 东哥
---

# Spring Boot 参数校验（@Valid/@Validated）从入门到源码

## 一、为什么需要参数校验？

在 Web 应用中，参数校验是第一道防线。没有校验的代码就像没有安检的机场——任何非法数据都可能进入系统核心。

```java
// ❌ 没有校验：后果很严重
@PostMapping("/user")
public Result createUser(@RequestBody User user) {
    userService.save(user);  // 万一 name 是 null 或空字符串？
    return Result.success();
}

// ✅ 加上校验：清爽又安全
@PostMapping("/user")
public Result createUser(@Valid @RequestBody User user) {
    userService.save(user);
    return Result.success();
}
```

## 二、快速上手：Spring Boot 集成 Bean Validation

### 2.1 引入依赖

Spring Boot 2.3+ 之后，`spring-boot-starter-web` **不再自动包含** `hibernate-validator`，需要手动引入：

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-validation</artifactId>
</dependency>
```

> 底层基于 **Jakarta Bean Validation 2.0+**（javax.validation → jakarta.validation），实现是 Hibernate Validator。

### 2.2 实体类定义校验规则

```java
@Data
public class UserCreateRequest {
    
    @NotBlank(message = "用户名不能为空")
    @Size(min = 2, max = 32, message = "用户名长度需要在 2-32 之间")
    private String username;
    
    @NotBlank(message = "密码不能为空")
    @Pattern(regexp = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d).{8,20}$",
             message = "密码需包含大小写字母和数字，长度8-20")
    private String password;
    
    @Email(message = "邮箱格式不正确")
    private String email;
    
    @Range(min = 1, max = 200, message = "年龄必须在 1-200 之间")
    private Integer age;
    
    @NotNull(message = "性别不能为空")
    private Integer gender;
    
    @Past(message = "生日必须是过去的时间")
    private LocalDate birthday;
    
    @NotEmpty(message = "爱好不能为空")
    @Size(min = 1, message = "至少选择一个爱好")
    private List<String> hobbies;
}
```

### 2.3 Controller 中启用校验

```java
@RestController
@RequestMapping("/api/users")
@Validated  // 类级别注解，支持分组校验
public class UserController {
    
    @PostMapping
    public Result create(@Valid @RequestBody UserCreateRequest request) {
        // 校验通过后才会进入方法体
        return Result.success(userService.create(request));
    }
    
    @GetMapping("/{id}")
    public Result get(@PathVariable @Min(1) Long id) {
        return Result.success(userService.getById(id));
    }
}
```

## 三、常用校验注解一览

| 注解 | 作用 | 适用类型 |
|------|------|---------|
| `@Null` | 必须为 null | 任意对象 |
| `@NotNull` | 必须不为 null | 任意对象 |
| `@NotBlank` | 不能为 null 且去掉空格后长度 > 0 | String |
| `@NotEmpty` | 不能为 null 且长度/大小 > 0 | String、Collection、Map、数组 |
| `@Size(min, max)` | 长度/大小在范围内 | String、Collection、Map、数组 |
| `@Min / @Max` | 数值最小值/最大值 | 数值类型 |
| `@Range(min, max)` | 数值在范围内 | 数值类型 |
| `@Email` | 邮箱格式 | String |
| `@Pattern(regexp)` | 正则匹配 | String |
| `@Past / @Future` | 过去/未来时间 | Date、LocalDate 等 |
| `@PastOrPresent / @FutureOrPresent` | 过去或现在/未来或现在 | 时间类型 |
| `@Positive / @PositiveOrZero` | 正数/非负数 | 数值类型 |
| `@Negative / @NegativeOrZero` | 负数/非正数 | 数值类型 |
| `@Digits(integer, fraction)` | 数字精度限制 | 数值类型 |
| `@AssertTrue / @AssertFalse` | 布尔值检查 | Boolean |

## 四、分组校验（Group Validation）

不同场景下同一个实体需要不同的校验规则：

```java
// 定义分组接口
public interface CreateGroup {}
public interface UpdateGroup {}

@Data
public class UserDTO {
    
    @Null(groups = CreateGroup.class, message = "创建时 ID 必须为空")
    @NotNull(groups = UpdateGroup.class, message = "更新时 ID 不能为空")
    private Long id;
    
    @NotBlank(groups = {CreateGroup.class, UpdateGroup.class})
    private String username;
    
    @NotBlank(groups = CreateGroup.class)
    private String password;
    
    @Null(groups = UpdateGroup.class, message = "更新时密码不能传") // 或者忽略
    private String password;
}
```

Controller 中指定分组：

```java
@PostMapping
public Result create(@Validated(CreateGroup.class) @RequestBody UserDTO dto) {
    return Result.success(userService.create(dto));
}

@PutMapping
public Result update(@Validated(UpdateGroup.class) @RequestBody UserDTO dto) {
    return Result.success(userService.update(dto));
}
```

## 五、嵌套校验

当 DTO 中包含复杂对象时，需要加上 `@Valid` 级联校验：

```java
@Data
public class OrderCreateRequest {
    
    @NotNull
    private Long userId;
    
    @NotEmpty
    private List<@Valid OrderItem> items;  // 集合中的元素也需要校验
    
    @Valid
    @NotNull
    private Address address;  // 关联对象校验
}

@Data
public class OrderItem {
    @NotNull
    private Long productId;
    
    @Min(1)
    private Integer quantity;
    
    @Positive
    private BigDecimal price;
}
```

## 六、自定义校验注解

### 6.1 创建注解

```java
@Target({FIELD, PARAMETER})
@Retention(RUNTIME)
@Constraint(validatedBy = PhoneValidator.class)
public @interface Phone {
    String message() default "手机号格式不正确";
    
    Class<?>[] groups() default {};
    
    Class<? extends Payload>[] payload() default {};
}
```

### 6.2 实现校验器

```java
public class PhoneValidator implements ConstraintValidator<Phone, String> {
    
    private static final Pattern PHONE_PATTERN = 
        Pattern.compile("^1[3-9]\\d{9}$");
    
    @Override
    public boolean isValid(String value, ConstraintValidatorContext context) {
        if (value == null) {
            return true;  // @NotNull 负责 null 检查
        }
        return PHONE_PATTERN.matcher(value).matches();
    }
}
```

### 6.3 使用

```java
@Data
public class UserCreateRequest {
    @Phone
    private String phone;
}
```

## 七、全局异常处理：统一返回校验错误

```java
@RestControllerAdvice
public class GlobalExceptionHandler {
    
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public Result<?> handleValidationExceptions(
            MethodArgumentNotValidException ex) {
        Map<String, String> errors = new HashMap<>();
        ex.getBindingResult().getAllErrors().forEach(error -> {
            String fieldName = ((FieldError) error).getField();
            String errorMessage = error.getDefaultMessage();
            errors.put(fieldName, errorMessage);
        });
        return Result.error(400, "参数校验失败", errors);
    }
    
    @ExceptionHandler(ConstraintViolationException.class)
    public Result<?> handleConstraintViolation(
            ConstraintViolationException ex) {
        Map<String, String> errors = new HashMap<>();
        ex.getConstraintViolations().forEach(violation -> {
            String propertyPath = violation.getPropertyPath().toString();
            String message = violation.getMessage();
            errors.put(propertyPath, message);
        });
        return Result.error(400, "参数校验失败", errors);
    }
}
```

## 八、底层原理：Spring 如何拦截校验？

### 8.1 核心流程

```
请求进入 → HandlerMethodArgumentResolver（参数解析器）
              ↓
    方法参数上的 @Valid / @Validated 被检测到
              ↓
    DataBinder 绑定请求参数到 Java 对象
              ↓
    Validator 执行校验 → 收集 ConstraintViolation
              ↓
    有错 → 抛出 MethodArgumentNotValidException / ConstraintViolationException
    无错 → 正常执行 Controller 方法
```

### 8.2 关键类

- **`ModelAttributeMethodProcessor`**：检测 `@Valid` / `@Validated` 注解
- **`RequestResponseBodyMethodProcessor`**：处理 `@RequestBody` + `@Valid`
- **`ValidationAutoConfiguration`**：Spring Boot 自动配置 Validator
- **`LocalValidatorFactoryBean`**：桥接 Spring 和 Jakarta Validation
- **`MethodValidationPostProcessor`**：处理类级别 `@Validated` 的方法参数/返回值校验

### 8.3 源码片段

Spring 在 `RequestResponseBodyMethodProcessor.resolveArgument()` 中：

```java
@Override
public Object resolveArgument(MethodParameter parameter, ...) {
    Object arg = readWithMessageConverters(...);  // 反序列化 JSON
    
    // 检查是否有 @Valid / @Validated
    if (parameter.hasParameterAnnotation(Validated.class) || 
        parameter.hasParameterAnnotation(Valid.class)) {
        validateIfApplicable(binder, parameter);
    }
    
    if (binder.getBindingResult().hasErrors()) {
        if (isBindExceptionRequired(binder, parameter)) {
            throw new MethodArgumentNotValidException(parameter, 
                binder.getBindingResult());
        }
    }
    
    return arg;
}
```

`validateIfApplicable` 最终调用到 `Validator.validate()`，触发 Hibernate Validator 执行所有约束注解的校验逻辑。

## 九、最佳实践总结

### ✅ 推荐做法

1. **DTO 层统一校验**，而不是在 Service 层每个方法手写 if 判断
2. **统一错误格式**：全局异常处理返回结构化错误信息
3. **使用分组校验**处理创建/更新场景
4. **`@NotBlank` 优于 `@NotNull`**：同时检查 null 和空字符串
5. **自定义注解封装**：如 `@Phone`、`@IdCard`、`@EnumValue` 等

### ❌ 避免做法

1. **Entity 上直接加校验注解**：不同场景校验规则不同，容易耦合
2. **错误信息过于详细**：不要暴露内部实现细节
3. **过度追求零校验**：简单字段也得校验，别偷懒

### 性能建议

- 参数校验走 AOP，单次校验耗时通常在 0.1ms 以下
- 如果涉及数据库查询的校验（如用户名唯一），放到 Service 层通过 `@Validated(groups = ServiceGroup.class)` 或手动判断
- 高并发接口尽量减少 `@Pattern` 等正则校验，正则编译有性能开销，可预编译为 Pattern

参数校验虽然基础，但用好它能让代码质量提升一个档次。从简单的 `@NotBlank` 到自定义注解，从全局异常到分组校验，每个环节都值得认真对待。
