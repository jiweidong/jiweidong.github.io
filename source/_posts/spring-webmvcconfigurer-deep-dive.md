---
title: 【Spring Boot 实战】WebMvcConfigurer 与 Spring MVC 配置深度解析：从拦截器到消息转换器
date: 2026-07-27 08:00:00
tags:
  - Spring Boot
  - WebMvcConfigurer
  - Spring MVC
  - 拦截器
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】WebMvcConfigurer 与 Spring MVC 配置深度解析：从拦截器到消息转换器

## 前言

在 Spring Boot 项目中，我们经常需要自定义 MVC 配置——加拦截器、配 CORS、定制消息转换器……这一切的核心入口就是 **`WebMvcConfigurer`** 接口。

很多人对它的理解停留在"实现接口、加个 `@Configuration`"，但它的底层机制是什么？为什么 Spring Boot 不用 XML 也能配置 MVC？`WebMvcConfigurer` 和 `WebMvcConfigurationSupport` 有什么区别？

本文将带你从源码到实战，全面掌握 WebMvcConfigurer。

---

## 一、WebMvcConfigurer 是什么？

`WebMvcConfigurer` 是 Spring 5 引入的一个**配置回调接口**，用于在 Java 配置模式下定制 Spring MVC 的行为：

```java
// 取代旧的 WebMvcConfigurerAdapter（Spring 5 已弃用）
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        // 添加拦截器
    }

    @Override
    public void configureMessageConverters(List<HttpMessageConverter<?>> converters) {
        // 配置消息转换器
    }
}
```

### 1.1 它提供了哪些配置能力？

| 配置方法 | 功能 | 使用场景 |
|---------|------|---------|
| `addInterceptors()` | 添加拦截器 | 登录校验、日志、权限 |
| `addCorsMappings()` | 配置跨域 | 前后端分离项目 |
| `configureMessageConverters()` | 自定义消息转换器 | 定制 JSON 序列化 |
| `extendMessageConverters()` | 扩展消息转换器 | 追加而非覆盖 |
| `addResourceHandlers()` | 静态资源映射 | 自定义静态资源路径 |
| `configureViewResolvers()` | 视图解析器 | JSP/Thymeleaf 配置 |
| `configurePathMatch()` | URL 路径匹配 | 设置后缀匹配策略 |
| `addFormatters()` | 格式化器 | 日期/枚举转换 |
| `configureContentNegotiation()` | 内容协商 | 根据 Accept 头返回不同格式 |
| `addReturnValueHandlers()` | 返回值处理器 | 自定义 Controller 返回值处理 |
| `addArgumentResolvers()` | 参数解析器 | 自定义 Controller 参数 |
| `configureAsyncSupport()` | 异步支持 | 异步请求超时设置 |
| `configureDefaultServletHandling()` | 默认 Servlet | 处理静态资源 |

---

## 二、Spring Boot 自动配置原理

### 2.1 WebMvcAutoConfiguration

Spring Boot 通过 `WebMvcAutoConfiguration` 自动配置 Spring MVC：

```java
// WebMvcAutoConfiguration.java（Spring Boot 3.x）
@AutoConfiguration(after = { DispatcherServletAutoConfiguration.class })
@ConditionalOnWebApplication(type = Type.SERVLET)
@ConditionalOnClass({ Servlet.class, DispatcherServlet.class, WebMvcConfigurer.class })
@EnableConfigurationProperties(WebMvcProperties.class)
public class WebMvcAutoConfiguration {

    @Configuration
    @Import(EnableWebMvcConfiguration.class)
    @EnableConfigurationProperties({ WebMvcProperties.class, ResourceProperties.class })
    @Order(0)
    public static class WebMvcAutoConfigurationAdapter implements WebMvcConfigurer, ServletContextAware {
        // 默认实现
    }
}
```

关键点：`WebMvcAutoConfigurationAdapter` 本身也实现了 `WebMvcConfigurer`，提供了 Spring Boot 的默认 MVC 配置。

### 2.2 DelegatingWebMvcConfiguration 如何汇总配置

Spring Boot 使用 **`DelegatingWebMvcConfiguration`** 来聚合所有 `WebMvcConfigurer` Bean：

```java
@Configuration
public class DelegatingWebMvcConfiguration extends WebMvcConfigurationSupport {

    private final WebMvcConfigurerComposite configurers = new WebMvcConfigurerComposite();

    @Autowired(required = false)
    public void setConfigurers(List<WebMvcConfigurer> configurers) {
        if (!CollectionUtils.isEmpty(configurers)) {
            // 将所有 WebMvcConfigurer Bean 聚合到 Composite 中
            this.configurers.addWebMvcConfigurers(configurers);
        }
    }

    // 在各个配置方法中，委托给 composite
    @Override
    protected void addInterceptors(InterceptorRegistry registry) {
        this.configurers.addInterceptors(registry);
    }

    @Override
    protected void configureMessageConverters(List<HttpMessageConverter<?>> converters) {
        this.configurers.configureMessageConverters(converters);
    }
}
```

**核心机制**：Spring Boot 通过 `@Autowired` 注入所有 `WebMvcConfigurer` 类型的 Bean，然后通过 `WebMvcConfigurerComposite` 顺序调用每个配置器的同名方法。这样，无论你写多少个 `WebMvcConfigurer` 实现类，它们都会被合并生效。

### 2.3 @EnableWebMvc 的影响

```java
@Configuration
@EnableWebMvc  // ← 加了它会怎样？
public class WebConfig implements WebMvcConfigurer {
}
```

**`@EnableWebMvc`** 导入了 `DelegatingWebMvcConfiguration`，而它继承自 `WebMvcConfigurationSupport`：

```java
@Import(DelegatingWebMvcConfiguration.class)
public @interface EnableWebMvc {
}
```

一旦加了 `@EnableWebMvc`，**Spring Boot 的 `WebMvcAutoConfiguration` 就不再生效**，因为：

```java
@ConditionalOnMissingBean(WebMvcConfigurationSupport.class)
public class WebMvcAutoConfiguration { ... }
```

`DelegatingWebMvcConfiguration` 是 `WebMvcConfigurationSupport` 的子类，所以 `@ConditionalOnMissingBean` 条件不满足，Boot 的自动配置被跳过。

**结论**：加了 `@EnableWebMvc`，你就得**自己配置所有 MVC 行为**（包括静态资源映射等 Boot 默认帮你做的）。大多数情况下**不要加**，直接实现 `WebMvcConfigurer` 即可。

---

## 三、实战：拦截器配置

### 3.1 编写拦截器

```java
public class AuthInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, 
                              Object handler) throws Exception {
        // 1. 检查是否是静态资源
        if (handler instanceof ResourceHttpRequestHandler) {
            return true;
        }
        
        // 2. 检查是否需要跳过
        String path = request.getRequestURI();
        if (path.contains("/login") || path.contains("/register")) {
            return true;
        }
        
        // 3. 验证 Token
        String token = request.getHeader("Authorization");
        if (StringUtils.isBlank(token)) {
            response.setStatus(401);
            response.setContentType("application/json");
            response.getWriter().write("{\"code\":401,\"msg\":\"未登录\"}");
            return false;
        }
        
        // 4. 验证通过，将用户信息存入请求上下文
        // 注意：使用请求域而非 ThreadLocal（避免虚拟线程问题）
        request.setAttribute("userId", JwtUtil.parseToken(token));
        return true;
    }

    @Override
    public void postHandle(HttpServletRequest request, HttpServletResponse response,
                           Object handler, ModelAndView modelAndView) {
        // Controller 执行后、视图渲染前
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response,
                                 Object handler, Exception ex) {
        // 请求完成后（无论是否异常），清理资源
    }
}
```

### 3.2 注册拦截器

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Autowired
    private AuthInterceptor authInterceptor;

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(authInterceptor)
                .addPathPatterns("/api/**")          // 拦截 /api 下的所有请求
                .excludePathPatterns(
                    "/api/auth/login",               // 排除登录
                    "/api/auth/register",            // 排除注册
                    "/api/swagger-resources/**",     // 排除 Swagger
                    "/api/v3/api-docs/**",
                    "/error"                         // 排除错误页
                );
        
        // 第二个拦截器：记录接口耗时
        registry.addInterceptor(new TimeCostInterceptor())
                .addPathPatterns("/**");
    }
}
```

### 3.3 拦截器执行顺序

所有拦截器的 `preHandle` 按注册顺序正序执行，`postHandle` 和 `afterCompletion` 按注册顺序**倒序**执行：

```
Interceptor1.preHandle()  →  Interceptor2.preHandle()  →  Controller
Controller  →  Interceptor2.postHandle()  →  Interceptor1.postHandle()
Controller  →  Interceptor2.afterCompletion()  →  Interceptor1.afterCompletion()
```

---

## 四、实战：CORS 跨域配置

### 4.1 全局跨域配置

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/api/**")
                .allowedOriginPatterns("*")          // Spring Boot 2.4+ 使用 patterns
                .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
                .allowedHeaders("*")
                .allowCredentials(true)              // 允许携带 Cookie
                .maxAge(3600)                        // 预检请求缓存 1 小时
                .exposedHeaders("Authorization");    // 暴露自定义响应头
    }
}
```

**注意**：`allowCredentials(true)` 时不能设置 `allowedOrigins("*")`，必须指定具体的 origin 或使用 `allowedOriginPatterns("*")`。

### 4.2 CORS 配置的原理

Spring MVC 通过 `CorsProcessor` 处理跨域请求：

```
浏览器发送 OPTIONS 预检请求 → 
    CorsFilter / CorsInterceptor 拦截 →
    检查 Origin 是否在 allowedOrigins 中 →
    返回 Access-Control-Allow-Origin 等响应头 →
    浏览器放行实际请求
```

如有多个 `WebMvcConfigurer` 配置了的 CORS，会按照 `@Order` 顺序合并。

---

## 五、实战：消息转换器配置

### 5.1 自定义 Jackson 配置

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void extendMessageConverters(List<HttpMessageConverter<?>> converters) {
        // 使用 extend 而非 configure，避免覆盖 Spring Boot 的默认转换器
        
        // 找到已有的 MappingJackson2HttpMessageConverter
        for (HttpMessageConverter<?> converter : converters) {
            if (converter instanceof MappingJackson2HttpMessageConverter) {
                MappingJackson2HttpMessageConverter jsonConverter =
                    (MappingJackson2HttpMessageConverter) converter;
                
                ObjectMapper objectMapper = jsonConverter.getObjectMapper();
                
                // 配置日期格式
                objectMapper.setDateFormat(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"));
                
                // 忽略未知字段
                objectMapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
                
                // 序列化配置
                objectMapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
                objectMapper.enable(SerializationFeature.INDENT_OUTPUT);
                
                // 属性命名策略：下划线转驼峰
                objectMapper.setPropertyNamingStrategy(
                    PropertyNamingStrategies.SNAKE_CASE);
                
                // Java 8 时间模块
                JavaTimeModule timeModule = new JavaTimeModule();
                timeModule.addSerializer(LocalDateTime.class, 
                    new LocalDateTimeSerializer(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")));
                timeModule.addDeserializer(LocalDateTime.class,
                    new LocalDateTimeDeserializer(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")));
                objectMapper.registerModule(timeModule);
            }
        }
    }
}
```

### 5.2 configure vs extend 的区别

| 方法 | 行为 | 什么时候用 |
|------|------|-----------|
| `configureMessageConverters()` | 替换所有默认转换器 | 全新定制 |
| `extendMessageConverters()` | 追加到默认列表末尾 | 保留默认，自定义扩展 |

**源码验证**：

```java
// DelegatingWebMvcConfiguration
protected final List<HttpMessageConverter<?>> getMessageConverters() {
    if (this.messageConverters == null) {
        this.messageConverters = new ArrayList<>();
        configureMessageConverters(this.messageConverters);  // 1. 先调用 configure
        if (this.messageConverters.isEmpty()) {
            addDefaultHttpMessageConverters(this.messageConverters);  // 只有为空时才加默认
        }
        extendMessageConverters(this.messageConverters);  // 2. 再调用 extend
    }
    return this.messageConverters;
}
```

**重要**：如果覆写了 `configureMessageConverters()` 但没有加任何转换器，默认转换器也不会加载——这会导致 Spring MVC 无法处理 JSON 请求。所以通常建议用 `extendMessageConverters()`。

---

## 六、实战：路径匹配配置

Spring Boot 2.x 默认使用 `PathPatternParser`（基于解析树的路径匹配），替代了传统的 `AntPathMatcher`：

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void configurePathMatch(PathMatchConfigurer configurer) {
        // 设置尾斜杠匹配（默认 true）
        // /api/users 和 /api/users/ 视为同一个路径
        configurer.setUseTrailingSlashMatch(true);
        
        // 设置后缀匹配（5.3+ 已弃用）
        // configurer.setUseSuffixPatternMatch(false);
        
        // 给特定 Controller 加路径前缀
        configurer.addPathPrefix("/api", c -> 
            c.isAnnotationPresent(RestController.class));
    }
}
```

---

## 七、实战：内容协商配置

让同一个接口根据请求头返回不同格式的数据：

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void configureContentNegotiation(ContentNegotiationConfigurer configurer) {
        configurer
            .favorParameter(true)          // 支持 ?format=json 参数
            .parameterName("format")      
            .ignoreAcceptHeader(true)      // 忽略 Accept 头
            .defaultContentType(MediaType.APPLICATION_JSON)
            .mediaType("json", MediaType.APPLICATION_JSON)
            .mediaType("xml", MediaType.APPLICATION_XML);
    }
}
```

访问效果：
```
GET /api/users           → JSON（默认）
GET /api/users?format=xml → XML
```

---

## 八、WebMvcConfigurer 最常见的坑

### 8.1 坑一：静态资源 404

```java
// ❌ 错误姿势：加了 @EnableWebMvc，但没有配置静态资源
@Configuration
@EnableWebMvc
public class WebConfig implements WebMvcConfigurer {
}
```

**解决**：要么不加 `@EnableWebMvc`（推荐），要么手动配置静态资源：

```java
@Override
public void addResourceHandlers(ResourceHandlerRegistry registry) {
    registry.addResourceHandler("/**")
            .addResourceLocations("classpath:/static/")
            .addResourceLocations("classpath:/public/");
    
    registry.addResourceHandler("swagger-ui/**")
            .addResourceLocations("classpath:/META-INF/resources/webjars/springfox-swagger-ui/");
}
```

### 8.2 坑二：拦截器不生效

```java
// ❌ 错误：拦截器 Bean 不在 Spring 容器中
public class AppConfig implements WebMvcConfigurer {
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(new AuthInterceptor());  // new 出来的，不是 Bean！
    }
}
```

**正确做法**：要么将拦截器注释为 `@Component` 然后注入，要么直接在配置类中创建 Bean：

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {
    
    @Bean
    public AuthInterceptor authInterceptor() {
        return new AuthInterceptor();
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(authInterceptor());
    }
}
```

### 8.3 坑三：多个 WebMvcConfigurer 执行顺序

Spring Boot 会聚合所有 `WebMvcConfigurer` Bean，按 `@Order` 注解排序执行。不同配置器中如果有冲突（比如同一个路径的拦截器配置），后执行的覆盖先执行的。

```java
@Configuration
@Order(1)  // 数字小的先执行
public class SecurityConfig implements WebMvcConfigurer { ... }

@Configuration
@Order(2)
public class LogConfig implements WebMvcConfigurer { ... }
```

---

## 九、面试高频问题

### Q1：WebMvcConfigurer 和 WebMvcConfigurationSupport 的区别？

`WebMvcConfigurationSupport` 是 Spring MVC 的核心配置类，提供所有默认配置；`WebMvcConfigurer` 是**配置回调接口**，用于对 `WebMvcConfigurationSupport` 的默认行为进行定制。

加 `@EnableWebMvc` 后会导入 `DelegatingWebMvcConfiguration`（继承自 `WebMvcConfigurationSupport`），这会**禁用** Spring Boot 的自动配置。所以除非要完全控制，否则不要加 `@EnableWebMvc`。

### Q2：为什么 Spring Boot 推荐用 WebMvcConfigurer 而不是继承 WebMvcConfigurationSupport？

因为 Spring Boot 的自动配置已经加载了 `WebMvcConfigurationSupport`，你再用继承就是另起炉灶，会丢失 Boot 的默认配置。而 `WebMvcConfigurer` 是回调注入机制，与自动配置**共存**。

### Q3：configureMessageConverters 和 extendMessageConverters 有什么区别？

`configure` 会**覆盖**所有默认转换器；`extend` 在默认转换器之后**追加**。除非你明确不要默认转换器，否则用 `extend`。

---

## 总结

`WebMvcConfigurer` 是 Spring Boot 项目中定制 MVC 行为的**统一入口**。理解它的背后机制（`DelegatingWebMvcConfiguration` 聚合 + Spring Boot 自动配置条件判断），能帮你避免静态资源 404、拦截器不生效、JSON 序列化异常等常见问题。

记住几个要点：
- **不要加 `@EnableWebMvc`**，除非你真的需要完全控制
- 用 `extendMessageConverters` 而非 `configureMessageConverters`
- 拦截器、CORS、资源映射、消息转换器——所有配置都从实现 `WebMvcConfigurer` 开始
