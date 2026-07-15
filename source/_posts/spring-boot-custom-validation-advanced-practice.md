---
title: 【Spring Boot 实战】自定义校验注解深度实战：从 @Valid 到高级参数校验
date: 2026-07-15 08:00:00
tags:
  - Spring Boot
  - Bean Validation
  - 参数校验
  - 面试
categories:
  - Spring Boot
  - 实战
author: 东哥
---

# 【Spring Boot 实战】自定义校验注解深度实战：从 @Valid 到高级参数校验

## 引言

你有写过这样的代码吗？

```java
@PostMapping("/user")
public Result createUser(@RequestBody UserDTO user) {
    // 手动校验：又臭又长，到处重复
    if (user.getName() == null || user.getName().trim().isEmpty()) {
        return Result.fail("用户名不能为空");
    }
    if (user.getEmail() == null || !user.getEmail().matches("^[A-Za-z0-9+_.-]+@(.+)$")) {
        return Result.fail("邮箱格式不正确");
    }
    if (user.getAge() < 18 || user.getAge() > 150) {
        return Result.fail("年龄必须在18-150之间");
    }
    // ... 业务逻辑
}
```

这种硬编码的校验方式**污染了业务逻辑、难以复用、难以维护**。

而使用 Spring Boot 的 Bean Validation 机制，你可以写出这样的代码：

```java
@PostMapping("/user")
public Result createUser(@Valid @RequestBody UserDTO user) {
    // 参数校验自动完成，一路清爽
    return Result.success(userService.createUser(user));
}
```

但这只是基本功。当标准注解无法满足复杂业务校验时，**自定义校验注解**就派上了用场。本文将带你深入 Spring Boot 校验体系，从源码层面理解 @Valid 的工作原理，并手写多个生产级自定义校验注解。

---

## 一、Bean Validation 标准注解速览

### 1.1 Jakarta Validation 内置注解

| 注解 | 作用 | 示例 |
|---|---|---|
| `@NotNull` | 值不能为 null | `@NotNull String name` |
| `@NotEmpty` | 字符串/集合不为 null 且不为空 | `@NotEmpty List<String> tags` |
| `@NotBlank` | 字符串不为 null 且去除空格后不为空 | `@NotBlank String title` |
| `@Size` | 限制长度或大小 | `@Size(min=6, max=20) String password` |
| `@Min` / `@Max` | 数字最小值/最大值 | `@Min(0) @Max(100) int score` |
| `@Email` | 邮箱格式 | `@Email String email` |
| `@Pattern` | 正则匹配 | `@Pattern(regexp="^1[3-9]\\d{9}$") String phone` |
| `@Positive` / `@PositiveOrZero` | 正数/非负 | `@Positive BigDecimal price` |
| `@Past` / `@Future` | 过去/将来日期 | `@Past LocalDate birthday` |
| `@AssertTrue` / `@AssertFalse` | 布尔值真假 | `@AssertTrue boolean agreed` |

### 1.2 使用方式

```java
@Data
public class UserCreateRequest {
    @NotBlank(message = "用户名不能为空")
    @Size(min = 2, max = 50, message = "用户名长度需在2-50之间")
    private String name;

    @NotBlank
    @Email(message = "邮箱格式不正确")
    private String email;

    @NotNull
    @Min(value = 18, message = "年龄不能小于18")
    @Max(value = 150, message = "年龄不能大于150")
    private Integer age;

    @Pattern(regexp = "^1[3-9]\\d{9}$", message = "手机号格式不正确")
    private String phone;

    @NotNull
    @Past(message = "生日必须是过去的日期")
    private LocalDate birthday;
}
```

在 Controller 中启用：

```java
@RestController
@Validated  // 类级别启用校验
public class UserController {

    @PostMapping("/user")
    public Result createUser(@Valid @RequestBody UserCreateRequest request) {
        // 进入方法时，参数已自动校验完成
        return Result.success(userService.create(request));
    }

    @GetMapping("/user/{id}")
    public Result getUser(@PathVariable @Min(1) Long id) {
        // 路径变量也支持校验（需要 @Validated 在类上）
        return Result.success(userService.getById(id));
    }
}
```

---

## 二、自定义校验注解——入门

### 2.1 第一步：定义注解

```java
import jakarta.validation.Constraint;
import jakarta.validation.Payload;
import java.lang.annotation.*;

@Target({ElementType.FIELD, ElementType.PARAMETER, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = PhoneValidator.class)  // 指定校验器
@Documented
public @interface Phone {

    // 默认错误消息（支持国际化）
    String message() default "手机号格式不正确";

    // 分组校验
    Class<?>[] groups() default {};

    // 负载信息
    Class<? extends Payload>[] payload() default {};
}
```

### 2.2 第二步：实现校验器

```java
import jakarta.validation.ConstraintValidator;
import jakarta.validation.ConstraintValidatorContext;
import java.util.regex.Pattern;

public class PhoneValidator implements ConstraintValidator<Phone, String> {

    // 中国大陆手机号正则：1开头的11位数字
    private static final Pattern PHONE_PATTERN = 
        Pattern.compile("^1[3-9]\\d{9}$");

    @Override
    public void initialize(Phone annotation) {
        // 可以读取注解上的属性
    }

    @Override
    public boolean isValid(String value, ConstraintValidatorContext context) {
        // null 值由 @NotNull 负责校验，我们不关心
        if (value == null) {
            return true;
        }
        return PHONE_PATTERN.matcher(value).matches();
    }
}
```

### 2.3 第三步：使用

```java
@Data
public class UserDTO {
    @Phone(message = "手机号格式错误")
    private String phone;
}
```

**ConstraintValidator 接口**：

```java
public interface ConstraintValidator<A extends Annotation, T> {
    // 初始化：可以读取注解的属性值
    default void initialize(A constraintAnnotation) {}
    
    // 校验逻辑：返回 true 表示校验通过
    boolean isValid(T value, ConstraintValidatorContext context);
}
```

---

## 三、高级自定义校验实战

### 3.1 带参数的自定义注解

**场景**：校验枚举值是否合法

```java
@Target({ElementType.FIELD})
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = EnumValidator.class)
@Documented
public @interface EnumValue {

    // 指定枚举类
    Class<? extends Enum<?>> enumClass();

    // 校验规则：是否允许 null
    boolean allowNull() default false;

    // 校验方式：name() 还是 ordinal() 还是自定义方法
    String method() default "name";

    String message() default "枚举值不正确";

    Class<?>[] groups() default {};

    Class<? extends Payload>[] payload() default {};
}
```

```java
public class EnumValidator implements ConstraintValidator<EnumValue, Object> {

    private Class<? extends Enum<?>> enumClass;
    private boolean allowNull;
    private String method;

    @Override
    public void initialize(EnumValue annotation) {
        this.enumClass = annotation.enumClass();
        this.allowNull = annotation.allowNull();
        this.method = annotation.method();
    }

    @Override
    public boolean isValid(Object value, ConstraintValidatorContext context) {
        if (value == null) {
            return allowNull;
        }

        Enum<?>[] enumConstants = enumClass.getEnumConstants();
        if (enumConstants == null) {
            return false;
        }

        for (Enum<?> e : enumConstants) {
            try {
                Object enumValue;
                if ("name".equals(method)) {
                    enumValue = e.name();
                } else if ("ordinal".equals(method)) {
                    enumValue = e.ordinal();
                } else {
                    // 通过反射调用自定义方法
                    enumValue = enumClass.getMethod(method).invoke(e);
                }

                if (enumValue.equals(value)) {
                    return true;
                }
            } catch (Exception ex) {
                throw new RuntimeException("Enum validation failed", ex);
            }
        }
        return false;
    }
}
```

**使用示例**：

```java
public enum OrderStatus {
    PENDING("待支付"),
    PAID("已支付"),
    SHIPPED("已发货"),
    COMPLETED("已完成"),
    CANCELLED("已取消");

    private final String description;

    OrderStatus(String description) {
        this.description = description;
    }

    public String getDescription() {
        return description;
    }
}

@Data
public class OrderQueryRequest {
    @EnumValue(enumClass = OrderStatus.class, message = "订单状态不合法")
    private String status;
}
```

### 3.2 跨字段校验

**场景**：密码和确认密码必须一致

```java
@Target({ElementType.TYPE})  // 类级别注解
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = FieldsMatchValidator.class)
@Documented
public @interface FieldsMatch {

    String field();         // 第一个字段
    String fieldMatch();    // 第二个字段

    String message() default "两个字段不匹配";

    Class<?>[] groups() default {};

    Class<? extends Payload>[] payload() default {};
}
```

```java
public class FieldsMatchValidator 
    implements ConstraintValidator<FieldsMatch, Object> {

    private String field;
    private String fieldMatch;

    @Override
    public void initialize(FieldsMatch annotation) {
        this.field = annotation.field();
        this.fieldMatch = annotation.fieldMatch();
    }

    @Override
    public boolean isValid(Object value, ConstraintValidatorContext context) {
        try {
            Object fieldValue = getFieldValue(value, field);
            Object fieldMatchValue = getFieldValue(value, fieldMatch);

            // 如果两者都为 null，视为有效（由 @NotNull 决定是否必填）
            if (fieldValue == null && fieldMatchValue == null) {
                return true;
            }

            boolean matched = fieldValue != null && fieldValue.equals(fieldMatchValue);

            if (!matched) {
                // 禁用默认消息，只针对 fieldMatch 字段报告错误
                context.disableDefaultConstraintViolation();
                context.buildConstraintViolationWithTemplate(context.getDefaultConstraintMessageTemplate())
                    .addPropertyNode(fieldMatch)
                    .addConstraintViolation();
            }

            return matched;
        } catch (Exception e) {
            return false;
        }
    }

    private Object getFieldValue(Object object, String fieldName) throws Exception {
        PropertyDescriptor pd = new PropertyDescriptor(fieldName, object.getClass());
        Method getter = pd.getReadMethod();
        return getter.invoke(object);
    }
}
```

**使用示例**：

```java
@FieldsMatch(field = "password", fieldMatch = "confirmPassword", 
             message = "两次输入的密码不一致")
@Data
public class PasswordResetRequest {
    @NotBlank
    @Size(min = 6, max = 32)
    private String password;

    @NotBlank
    private String confirmPassword;
}
```

### 3.3 列表元素校验

**场景**：校验 List 中的每个元素符合特定条件

```java
@Target({ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = ListNotEmptyValidator.class)
@Documented
public @interface ListNotEmpty {
    String message() default "列表元素不能为空";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}
```

更好的方案是直接在字段上使用 `@Valid` 嵌套校验：

```java
@Data
public class BatchCreateRequest {
    @NotEmpty(message = "用户列表不能为空")
    @Valid  // 嵌套校验每个元素
    private List<@Valid UserCreateRequest> users;
}

// 或者使用集合元素的约束
@Data
public class IdListRequest {
    @NotEmpty
    private List<@Min(1) @NotNull Long> ids;  // Java 8+ 支持类型使用约束
}
```

### 3.4 条件必填校验

**场景**：当某个字段为特定值时，另一个字段必填

```java
@Target({ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = RequiredIfValidator.class)
@Documented
public @interface RequiredIf {

    String field();                 // 条件字段
    String fieldValue();            // 条件值
    String requireField();          // 依赖字段

    String message() default "当前条件下该字段必填";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}
```

```java
public class RequiredIfValidator 
    implements ConstraintValidator<RequiredIf, Object> {

    private String field;
    private String fieldValue;
    private String requireField;

    @Override
    public void initialize(RequiredIf annotation) {
        this.field = annotation.field();
        this.fieldValue = annotation.fieldValue();
        this.requireField = annotation.requireField();
    }

    @Override
    public boolean isValid(Object value, ConstraintValidatorContext context) {
        try {
            Object fieldActualValue = getFieldValue(value, field);
            
            // 条件满足时，检查依赖字段
            if (fieldValue.equals(String.valueOf(fieldActualValue))) {
                Object requireFieldValue = getFieldValue(value, requireField);
                if (requireFieldValue == null) {
                    context.disableDefaultConstraintViolation();
                    context.buildConstraintViolationWithTemplate(
                        String.format("当 %s=%s 时，%s 必填", field, fieldValue, requireField))
                        .addPropertyNode(requireField)
                        .addConstraintViolation();
                    return false;
                }
            }
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private Object getFieldValue(Object obj, String fieldName) throws Exception {
        Field field = obj.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        return field.get(obj);
    }
}
```

**使用示例**：

```java
@RequiredIf(field = "orderType", fieldValue = "EXPRESS", 
            requireField = "expressCompany")
@Data
public class OrderCreateRequest {
    @NotBlank
    private String orderType;  // NORMAL / EXPRESS / VIRTUAL

    private String expressCompany;  // 当 orderType=EXPRESS 时必填
}
```

---

## 四、分组校验

### 4.1 定义分组

```java
public interface CreateGroup {}
public interface UpdateGroup {}
public interface QueryGroup {}
```

### 4.2 按组配置校验规则

```java
@Data
public class UserRequest {
    @Null(groups = CreateGroup.class, message = "新增时ID必须为空")
    @NotNull(groups = UpdateGroup.class, message = "更新时ID不能为空")
    @Min(value = 1, groups = UpdateGroup.class)
    private Long id;

    @NotBlank(groups = {CreateGroup.class, UpdateGroup.class})
    @Size(min = 2, max = 50)
    private String name;

    @NotBlank(groups = CreateGroup.class)
    @Email
    private String email;

    @Null(groups = CreateGroup.class)
    @NotNull(groups = UpdateGroup.class)
    private LocalDateTime updateTime;
}
```

### 4.3 在 Controller 中指定分组

```java
@RestController
@Validated
public class UserController {

    @PostMapping("/user")
    public Result create(@Validated(CreateGroup.class) @RequestBody UserRequest request) {
        // 只校验 CreateGroup 组的规则
        return Result.success(userService.create(request));
    }

    @PutMapping("/user")
    public Result update(@Validated(UpdateGroup.class) @RequestBody UserRequest request) {
        // 只校验 UpdateGroup 组的规则
        return Result.success(userService.update(request));
    }
}
```

---

## 五、源码解析：@Valid 是如何工作的？

### 5.1 Spring AOP 拦截

Spring Boot 自动配置了 `MethodValidationPostProcessor`，它在 `@Validated` 标注的类上创建 AOP 切面：

```java
// 核心入口：MethodValidationInterceptor
public class MethodValidationInterceptor implements MethodInterceptor {
    @Override
    public Object invoke(MethodInvocation invocation) throws Throwable {
        // 获取校验方法
        ExecutableValidator execVal = this.validator.forExecutables();
        
        // 校验参数
        Set<ConstraintViolation<Object>> violations = 
            execVal.validateParameters(目标对象, 方法, 参数值, 分组);
        
        if (!violations.isEmpty()) {
            // 抛出 ConstraintViolationException
            throw new ConstraintViolationException(violations);
        }
        
        return invocation.proceed();
    }
}
```

### 5.2 Spring MVC 集成

对于 `@RequestBody` 和 `@RequestParam`，Spring MVC 通过 `RequestResponseBodyMethodProcessor` 调用校验：

```java
public class RequestResponseBodyMethodProcessor 
    extends AbstractMessageConverterMethodArgumentResolver {

    @Override
    public Object resolveArgument(MethodParameter parameter, ...) {
        Object arg = readWithMessageConverters(webRequest, parameter, ...);
        
        // 检查是否有 @Valid / @Validated 注解
        if (parameter.hasParameterAnnotation(Valid.class)) {
            // 执行校验
            validate(parameter, arg);
        }
        
        return arg;
    }

    private void validate(MethodParameter parameter, Object arg) {
        // 获取 Validator（默认是 LocalValidatorFactoryBean）
        Validator validator = getValidator();
        
        // 执行校验，获取所有的 ConstraintViolation
        Set<ConstraintViolation<Object>> violations = validator.validate(arg);
        
        if (!violations.isEmpty()) {
            // 封装为 MethodArgumentNotValidException
            throw new MethodArgumentNotValidException(parameter, 
                new BeanPropertyBindingResult(arg, parameter.getParameterName()));
        }
    }
}
```

### 5.3 全局异常处理

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public Result handleValidationExceptions(MethodArgumentNotValidException ex) {
        Map<String, String> errors = new LinkedHashMap<>();
        ex.getBindingResult().getFieldErrors().forEach(error -> 
            errors.put(error.getField(), error.getDefaultMessage())
        );
        return Result.fail(400, "参数校验失败", errors);
    }

    @ExceptionHandler(ConstraintViolationException.class)
    public Result handleConstraintViolation(ConstraintViolationException ex) {
        Map<String, String> errors = new LinkedHashMap<>();
        ex.getConstraintViolations().forEach(violation -> {
            String field = violation.getPropertyPath().toString();
            errors.put(field, violation.getMessage());
        });
        return Result.fail(400, "参数校验失败", errors);
    }
}
```

---

## 六、最佳实践总结

### 6.1 校验策略建议

| 场景 | 推荐方式 |
|---|---|
| 单字段格式校验 | 标准注解 `@Email`, `@Pattern` |
| 复杂格式校验 | 自定义注解，如 `@Phone`, `@IdCard` |
| 枚举值校验 | 自定义 `@EnumValue` 注解 |
| 跨字段关联校验 | 类级别注解，如 `@FieldsMatch` |
| 条件校验 | 类级别注解，如 `@RequiredIf` |
| 嵌套对象校验 | `@Valid` 递归校验 |
| 增删改不同规则 | 分组校验 |
| 列表元素校验 | `List<@Valid T>` 或 `@NotEmpty List<@Email T>` |

### 6.2 常见坑

1. **@Validated 和 @Valid 的区别**：`@Valid` 是 Jakarta Validation 标准注解，支持嵌套校验；`@Validated` 是 Spring 的扩展，支持分组校验。建议两者配合使用。

2. **@RequestBody 默认不校验**：必须加上 `@Valid` 或 `@Validated` 才会触发校验。

3. **@RequestParam 和 @PathVariable 的校验**：需要在类上标注 `@Validated`，并在参数上加约束注解。

4. **国际化消息**：`message` 支持 EL 表达式，也可以使用 `{code}` 从 `ValidationMessages.properties` 读取。

5. **性能注意**：`@Pattern` 正则每次校验都会编译，频繁校验的大字段建议预编译 Pattern 后在自定义校验器中使用。

**自定义校验注解是 Spring Boot 参数校验体系中不可或缺的一部分。** 当标准注解无法满足业务需求时，自定义注解让你能将以声明式的方式优雅地表达复杂的校验逻辑，避免在业务代码中散落着大量的 if-else 校验。
