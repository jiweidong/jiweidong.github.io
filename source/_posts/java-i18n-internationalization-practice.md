---
title: 【Java 实战】Java 国际化（i18n）企业级实战：从 ResourceBundle 到 Spring 国际化
date: 2026-07-13 08:00:00
tags:
  - Java
  - Spring Boot
  - i18n
categories:
  - Java
  - Web开发
author: 东哥
---

# 【Java 实战】Java 国际化（i18n）企业级实战：从 ResourceBundle 到 Spring 国际化

## 一、为什么要做国际化？

i18n（Internationalization，因首尾 i 和 n 之间有 18 个字母而得名）是大型系统走向海外市场的必修课。

我曾经接手过一个电商系统的国际化改造——当时系统原本只支持中文，上线东南亚市场后，所有用户看到的都是中文界面，订单地址填的是英文、商品标题却显示中文，整个用户体验一言难尽。改完之后，我总结了 Java 国际化的全套方案，从最底层的 ResourceBundle 到 Spring 框架的完整集成。

一个完整的国际化系统要支持：

| 场景 | 需要国际化的内容 |
|------|----------------|
| **前端 UI** | 按钮文字、提示信息、菜单标题 |
| **后端消息** | 异常提示、校验错误、邮件模板 |
| **数据内容** | 商品名称/描述（多语言存储） |
| **时间日期** | 不同地区的日期格式、时区转换 |
| **货币数字** | 货币符号、千分位格式、小数点 |

本文重点讲**后端消息的国际化**，这是 Java 程序员接触最多的场景。

## 二、Java 国际化的基石：Locale 与 ResourceBundle

### 2.1 Locale 类

任何国际化的起点都是 `java.util.Locale`，它代表一个特定的地理/语言区域：

```java
// 常见 Locale
Locale chinese = Locale.CHINESE;              // zh
Locale china = Locale.CHINA;                   // zh_CN
Locale us = Locale.US;                         // en_US
Locale japan = Locale.JAPAN;                   // ja_JP
Locale france = Locale.FRANCE;                 // fr_FR
Locale germany = Locale.GERMANY;               // de_DE

// 自定义 Locale
Locale thailand = new Locale("th", "TH");      // 泰语
Locale vietnam = new Locale("vi", "VN");       // 越南语

// 从 HTTP 请求头解析
Locale requestLocale = request.getLocale();    // 来自 Accept-Language 头
```

### 2.2 ResourceBundle：最底层的国际化方案

`ResourceBundle` 是 Java 标准库提供的资源文件加载机制：

**资源文件命名规则：**

```
基础名_语言_地区.properties
messages_en_US.properties   → 美式英文
messages_zh_CN.properties   → 简体中文
messages_ja_JP.properties   → 日文
messages.properties         → 默认（fallback）
```

**messages_zh_CN.properties：**
```properties
user.login.success=登录成功
user.login.fail=用户名或密码错误
order.create.success=订单创建成功，订单号：{0}
order.total=订单总计：{0,number,currency}
welcome.message=欢迎 {0}，今天是 {1,date,long}
```

**messages_en_US.properties：**
```properties
user.login.success=Login successful
user.login.fail=Invalid username or password
order.create.success=Order created successfully, order number: {0}
order.total=Order total: {0,number,currency}
welcome.message=Welcome {0}, today is {1,date,long}
```

**代码调用：**

```java
public class I18nDemo {
    public static void main(String[] args) {
        Locale locale = Locale.CHINA;
        ResourceBundle bundle = ResourceBundle.getBundle("messages", locale);

        // 简单文本
        String msg = bundle.getString("user.login.success");
        System.out.println(msg);  // 登录成功

        // 带占位符的文本（使用 MessageFormat）
        String pattern = bundle.getString("order.create.success");
        String formatted = MessageFormat.format(pattern, "ORD-20260713-001");
        System.out.println(formatted);  // 订单创建成功，订单号：ORD-20260713-001

        // 国际化数字和日期
        String welcomePattern = bundle.getString("welcome.message");
        String welcome = MessageFormat.format(welcomePattern,
            "张三", new Date());
        System.out.println(welcome);
        // zh_CN: 欢迎 张三，今天是 2026年7月13日
        // en_US: Welcome 张三, today is July 13, 2026
    }
}
```

### 2.3 ResourceBundle 的加载机制

`ResourceBundle.getBundle()` 的查找顺序非常关键（以 `Locale.CHINA` 为例）：

1. 查找 `messages_zh_CN.properties`
2. 查找 `messages_zh.properties`
3. 查找 `messages.properties`（默认 fallback）
4. 如果都没找到，抛出 `MissingResourceException`

**控制类加载器：** 如果资源文件在非默认位置：

```java
// 指定 ClassLoader
ResourceBundle bundle = ResourceBundle.getBundle(
    "com.example.i18n.messages",
    locale,
    Thread.currentThread().getContextClassLoader()
);

// 使用 Properties 文件不在 classpath 时
try (FileInputStream fis = new FileInputStream("/etc/app/messages.properties")) {
    Properties props = new Properties();
    props.load(new InputStreamReader(fis, StandardCharsets.UTF_8));
    // 注意：properties 文件默认使用 ISO-8859-1 编码
    // 中文要使用 Unicode 转义或指定 UTF-8 加载
}
```

> ⚠️ **坑点警告**：`.properties` 文件的默认编码是 ISO-8859-1！如果写入中文字符，要么使用 native2ascii 转义为 Unicode，要么使用 XML 格式的资源文件，或者在 Java 9+ 中指定 UTF-8：

```java
// Java 9+ 支持 UTF-8 的 properties 文件
// 启动参数：-Dfile.encoding=UTF-8
ResourceBundle bundle = ResourceBundle.getBundle("messages", locale,
    ResourceBundle.Control.getControl(ResourceBundle.Control.FORMAT_PROPERTIES));
```

## 三、Spring 国际化（i18n）实战

Spring 在 ResourceBundle 之上做了一层抽象——`MessageSource` 接口，让国际化变得更加与容器集成。

### 3.1 配置 MessageSource

```java
@Configuration
public class I18nConfig {

    @Bean
    public MessageSource messageSource() {
        ResourceBundleMessageSource source = new ResourceBundleMessageSource();
        source.setBasenames("i18n/messages", "i18n/validation");
        source.setDefaultEncoding("UTF-8");
        source.setFallbackToSystemLocale(false);  // 找不到时用默认 locale
        source.setUseCodeAsDefaultMessage(true);  // 找不到 key 时返回 key 自身
        source.setCacheSeconds(3600);             // 缓存时间（生产环境建议大一点）
        return source;
    }

    // Reloadable 版本（开发环境用，无需重启即可加载修改后的 properties）
    @Bean
    @Profile("dev")
    public MessageSource reloadableMessageSource() {
        ReloadableResourceBundleMessageSource source =
            new ReloadableResourceBundleMessageSource();
        source.setBasenames("classpath:i18n/messages");
        source.setDefaultEncoding("UTF-8");
        source.setCacheSeconds(10);  // 开发环境每 10 秒重新加载
        return source;
    }
}
```

### 3.2 通过 ReloadableResourceBundleMessageSource 支持 UTF-8

```properties
# classpath:i18n/messages_zh_CN.properties
# 直接写中文，不用 native2ascii！Spring 的 Reloadable 实现用了 UTF-8 读取
user.not.found=用户不存在：{0}
order.status.paid=已支付
validation.password.length=密码长度必须在 {min} 到 {max} 之间
```

### 3.3 在代码中获取国际化消息

```java
@Service
public class I18nService {

    @Autowired
    private MessageSource messageSource;

    // 当前线程的 Locale（从请求拦截器设置）
    public String getMessage(String code, Object... args) {
        Locale locale = LocaleContextHolder.getLocale();
        return messageSource.getMessage(code, args, locale);
    }

    // 指定默认消息
    public String getMessageWithDefault(String code, String defaultMsg, Object... args) {
        Locale locale = LocaleContextHolder.getLocale();
        return messageSource.getMessage(code, args, defaultMsg, locale);
    }
}
```

### 3.4 Locale 解析器：从请求中获取用户的 Locale

Spring 提供了 `LocaleResolver` 来从每次 HTTP 请求中解析用户的语言偏好：

```java
@Configuration
public class LocaleConfig {

    @Bean
    public LocaleResolver localeResolver() {
        // 方案一：从 Accept-Language 头解析（浏览器自动发送）
        AcceptHeaderLocaleResolver resolver = new AcceptHeaderLocaleResolver();
        resolver.setDefaultLocale(Locale.CHINA);
        resolver.setSupportedLocales(List.of(
            Locale.CHINA, Locale.US, Locale.JAPAN, Locale.UK
        ));
        return resolver;
    }

    // 方案二：从 Cookie 中获取（用户手动选择的语言）
    @Bean
    public LocaleResolver cookieLocaleResolver() {
        CookieLocaleResolver resolver = new CookieLocaleResolver();
        resolver.setCookieName("LANG");
        resolver.setCookieMaxAge(60 * 60 * 24 * 30); // 30天
        resolver.setDefaultLocale(Locale.CHINA);
        return resolver;
    }

    // 方案三：从 Session 获取
    @Bean
    public LocaleResolver sessionLocaleResolver() {
        SessionLocaleResolver resolver = new SessionLocaleResolver();
        resolver.setDefaultLocale(Locale.CHINA);
        return resolver;
    }
}
```

### 3.5 支持用户手动切换语言

提供 API 让用户可以手动切换界面语言：

```java
@RestController
public class LanguageController {

    @GetMapping("/api/lang/{lang}")
    public Result<Void> switchLanguage(
            @PathVariable String lang,
            HttpServletRequest request,
            HttpServletResponse response) {

        Locale locale = Locale.forLanguageTag(lang); // en-US, zh-CN, ja-JP
        // 方式一：写入 Cookie
        CookieLocaleResolver resolver = new CookieLocaleResolver();
        resolver.setLocale(request, response, locale);

        // 方式二：写入 Session
        // ((SessionLocaleResolver) localeResolver).setLocale(request, response, locale);

        return Result.success();
    }
}
```

前端调用：
```javascript
// Vue/React 中切换语言
function switchLanguage(lang) {
    // 方案一：后端 Cookie 方案
    axios.get(`/api/lang/${lang}`).then(() => {
        window.location.reload();
    });

    // 方案二：前端纯 i18n 方案（vue-i18n / react-i18next）
    i18n.global.locale = lang;
}
```

## 四、高级实战技巧

### 4.1 Controller 参数校验国际化

Spring Boot 的 Bean Validation 默认支持国际化，只是很多人忽略了：

```java
@Data
public class CreateUserRequest {
    @NotBlank(message = "{validation.user.name.notblank}")
    @Length(min = 2, max = 50, message = "{validation.user.name.length}")
    private String name;

    @Email(message = "{validation.user.email.invalid}")
    private String email;

    @Pattern(regexp = "^1[3-9]\\d{9}$", message = "{validation.user.phone.pattern}")
    private String phone;
}
```

```properties
# i18n/validation_zh_CN.properties
validation.user.name.notblank=用户名不能为空
validation.user.name.length=用户名长度必须在 {min} 到 {max} 之间
validation.user.email.invalid=邮箱格式不正确
validation.user.phone.pattern=手机号格式不正确

# i18n/validation_en_US.properties
validation.user.name.notblank=Username cannot be blank
validation.user.name.length=Username length must be between {min} and {max}
validation.user.email.invalid=Invalid email format
validation.user.phone.pattern=Invalid phone number format
```

**实现原理**：Spring 的 `LocalValidatorFactoryBean` 会自动从 `MessageSource` 解析 `{...}` 中的消息 key。

### 4.2 异常消息国际化

全局异常处理 + 国际化：

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @Autowired
    private MessageSource messageSource;

    @ExceptionHandler(BusinessException.class)
    public Result<Void> handleBusinessException(BusinessException e) {
        // BusinessException 中存储错误码，根据错误码翻译
        Locale locale = LocaleContextHolder.getLocale();
        String message = messageSource.getMessage(
            e.getErrorCode(),
            e.getArgs(),
            e.getDefaultMessage(),
            locale
        );
        return Result.error(e.getErrorCode(), message);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public Result<Void> handleValidation(MethodArgumentNotValidException e) {
        // 参数校验错误：提取国际化后的错误信息
        String message = e.getBindingResult()
            .getFieldErrors()
            .stream()
            .map(FieldError::getDefaultMessage) // 已经过 MessageSource 解析
            .collect(Collectors.joining("; "));
        return Result.error("VALIDATION_FAILED", message);
    }

    @ExceptionHandler(Exception.class)
    public Result<Void> handleUnknown(Exception e) {
        Locale locale = LocaleContextHolder.getLocale();
        String message = messageSource.getMessage(
            "system.error",
            null,
            "System error, please try again later",
            locale
        );
        log.error("Unexpected error", e);
        return Result.error("SYSTEM_ERROR", message);
    }
}
```

### 4.3 前端 Thymeleaf/Freemarker 国际化

```html
<!-- Thymeleaf 模板中使用 #messages 工具 -->
<!DOCTYPE html>
<html xmlns:th="http://www.thymeleaf.org">
<head>
    <title th:text="#{page.title}">默认标题</title>
</head>
<body>
    <h1 th:text="#{welcome.message(${user.name})}">欢迎</h1>
    <p th:text="#{order.total}">订单总计</p>

    <!-- 选择语言 -->
    <a th:href="@{/?lang=zh_CN}">中文</a>
    <a th:href="@{/?lang=en_US}">English</a>
    <a th:href="@{/?lang=ja_JP}">日本語</a>
</body>
</html>
```

### 4.4 邮件模板国际化

```java
@Service
public class MailService {

    @Autowired
    private MessageSource messageSource;

    public void sendOrderConfirmation(String email, Order order, Locale locale) {
        String subject = messageSource.getMessage(
            "mail.order.confirm.subject",
            new Object[]{order.getOrderNo()},
            locale
        );
        String body = messageSource.getMessage(
            "mail.order.confirm.body",
            new Object[]{order.getTotalAmount(), order.getCreatedAt()},
            locale
        );
        // 发送邮件...
    }
}
```

## 五、数据库层面的多语言方案

有时消息文本不足以满足需求——商品名称、分类描述等**业务数据**也需要多语言。这时需要使用**数据库多语言存储**：

### 方案一：多语言字段

```sql
CREATE TABLE product (
    id BIGINT PRIMARY KEY,
    name_zh VARCHAR(200),
    name_en VARCHAR(200),
    name_ja VARCHAR(200),
    description_zh TEXT,
    description_en TEXT,
    description_ja TEXT,
    created_at DATETIME
);
```

**优点**：查询简单，一条 SQL 搞定
**缺点**：增加一个新语言要加两列，扩展性差

### 方案二：多语言关联表（推荐）

```sql
CREATE TABLE product (
    id BIGINT PRIMARY KEY,
    created_at DATETIME
);

CREATE TABLE product_i18n (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    product_id BIGINT NOT NULL,
    locale VARCHAR(10) NOT NULL,  -- zh_CN, en_US, ja_JP
    field_name VARCHAR(50) NOT NULL,  -- name, description
    value TEXT NOT NULL,
    UNIQUE KEY uk_product_locale_field (product_id, locale, field_name)
);
```

**优点**：扩展性好，新增语言不需要改表结构
**缺点**：查询时需 JOIN，建议配合 Redis 缓存

```java
// 本地缓存 + 数据库查多语
@Component
public class I18nEntityHelper {

    @Cacheable(value = "product_i18n", key = "#productId + '-' + #locale")
    public Map<String, String> getI18nFields(Long productId, Locale locale) {
        // 从 product_i18n 表查询
        List<ProductI18n> list = i18nRepository.findByProductIdAndLocale(
            productId, locale.toString());

        // 如果没找到精确匹配，fallback 到默认语言
        if (list.isEmpty()) {
            list = i18nRepository.findByProductIdAndLocale(
                productId, Locale.CHINA.toString());
        }

        return list.stream()
            .collect(Collectors.toMap(ProductI18n::getFieldName, ProductI18n::getValue));
    }
}
```

## 六、国际化方案对比与选择

| 方案 | 适用场景 | 优点 | 缺点 |
|------|---------|------|------|
| **ResourceBundle** | 纯 Java 应用、非 Web 项目 | 无框架依赖，轻量 | 不支持热加载，需重启 |
| **Spring MessageSource** | Spring Boot Web 项目 | 与容器集成好，支持热加载 | 需 Spring 环境 |
| **数据库多语言** | 业务数据多语言 | 灵活可扩展，支持动态新增语言 | 查询复杂需缓存 |
| **前端 i18n 框架** | 纯前端国际化 | 减少后端请求，体验好 | 前后端需维护两套语言包 |
| **全局 CDN 多语言** | SaaS 多租户国际化 | 集中管理 | 架构复杂 |

## 七、最佳实践总结

1. **尽早引入国际化**：项目一开始就做，比后面几十个 Controller 改起来容易 100 倍
2. **统一 key 命名规范**：`module.section.description` 格式，避免冲突
3. **使用 UTF-8 编码**：Spring 的 `ReloadableResourceBundleMessageSource` 原生支持，不要再 `native2ascii`
4. **设置 fallback**：开启 `useCodeAsDefaultMessage`，找不到 key 时直接显示 code，方便定位
5. **分离校验消息**：把校验相关的消息单独放一个文件，方便维护
6. **合理设置缓存**：生产环境设置较长时间的缓存，减少文件 IO
7. **时区也要注意**：国际化不止语言，时间显示也要根据用户时区转换
8. **所有用户可见的字符串都要国际化**：日志不需要国际化，但异常消息和邮件模板必须国际化

```java
// 获取用户时区的工具
public class TimeZoneHelper {
    public static String formatDateTime(Date date, Locale locale, String timeZoneId) {
        ZoneId zoneId = timeZoneId != null ?
            ZoneId.of(timeZoneId) : ZoneId.systemDefault();
        return date.toInstant()
            .atZone(zoneId)
            .toLocalDateTime()
            .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM)
                .withLocale(locale));
    }
}
```

国际化看着简单，但在一个多语言、跨国团队的项目里，细节决定成败。好的国际化设计让产品走向世界变得丝滑，做差了就是处处碰壁的"中式英文"体验。
