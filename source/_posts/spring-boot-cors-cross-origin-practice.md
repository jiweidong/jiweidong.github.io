---
title: 【Spring Boot 实战】CORS 跨域配置：从原理到生产级最佳实践
date: 2026-07-12 08:00:00
tags:
  - Java
  - Spring Boot
  - CORS
  - 跨域
  - Web安全
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】CORS 跨域配置：从原理到生产级最佳实践

## 一、CORS 是什么？为什么会出现？

### 1.1 同源策略

浏览器的**同源策略（Same-Origin Policy）**规定：只有**协议 + 域名 + 端口**都相同的请求才被允许读取响应。

```
❌ http://localhost:3000 → http://localhost:8080/api    (端口不同)
❌ https://example.com  → http://example.com/api        (协议不同)
❌ http://a.com         → http://b.com/api              (域名不同)
✅ http://example.com   → http://example.com/api        (同源)
```

### 1.2 跨域请求的场景

| 场景 | 说明 |
|------|------|
| 前后端分离 | 前端 localhost:3000，后端 localhost:8080 |
| 微服务前端聚合 | 一个前端调多个后端服务 |
| 三方 API 嵌入 | 页面需要跨域调第三方服务 |
| OAuth 回调 | 认证服务回调到前端页面 |

## 二、CORS 原理详解

### 2.1 简单请求 vs 预检请求

**简单请求**满足以下条件：
- 方法：GET、HEAD、POST
- 请求头：Accept、Accept-Language、Content-Language、Content-Type（仅限 application/x-www-form-urlencoded、multipart/form-data、text/plain）

**预检请求（Preflight）**：不满足简单请求条件时，浏览器先发一个 `OPTIONS` 请求询问服务器是否允许：

```
// 预检请求
OPTIONS /api/users HTTP/1.1
Origin: http://localhost:3000
Access-Control-Request-Method: PUT
Access-Control-Request-Headers: Authorization, Content-Type

// 预检响应
HTTP/1.1 200 OK
Access-Control-Allow-Origin: http://localhost:3000
Access-Control-Allow-Methods: GET, POST, PUT, DELETE
Access-Control-Allow-Headers: Authorization, Content-Type
Access-Control-Max-Age: 3600
```

### 2.2 核心响应头

| 响应头 | 说明 | 示例值 |
|--------|------|--------|
| `Access-Control-Allow-Origin` | 允许的源 | `*` 或 `http://example.com` |
| `Access-Control-Allow-Methods` | 允许的 HTTP 方法 | `GET, POST, PUT, DELETE` |
| `Access-Control-Allow-Headers` | 允许的请求头 | `Authorization, Content-Type` |
| `Access-Control-Expose-Headers` | 浏览器可读取的响应头 | `X-Total-Count` |
| `Access-Control-Allow-Credentials` | 是否允许发送 Cookie | `true` |
| `Access-Control-Max-Age` | 预检结果的缓存时间（秒） | `3600` |

## 三、Spring Boot CORS 配置的 4 种方式

### 3.1 全局配置（推荐）

```java
@Configuration
public class CorsConfig implements WebMvcConfigurer {

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/api/**")      // 拦截路径
            .allowedOriginPatterns("*")     // 允许所有源（生产环境应指定具体域名）
            .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
            .allowedHeaders("*")
            .allowCredentials(true)
            .exposedHeaders("X-Total-Count", "Authorization")
            .maxAge(3600);
    }
}
```

> ⚠️ `allowCredentials(true)` 时，`allowedOriginPatterns("*")` 不能使用 `"*"`，必须使用具体域名或 `allowedOriginPatterns("*")`。

### 3.2 生产环境精确配置

```java
@Configuration
public class CorsConfig implements WebMvcConfigurer {

    @Value("${cors.allowed-origins:http://localhost:3000}")
    private String[] allowedOrigins;

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/api/**")
            // 生产环境：只允许指定前端域名
            .allowedOrigins(allowedOrigins)
            .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
            .allowedHeaders("Authorization", "Content-Type", "X-Requested-With")
            .allowCredentials(true)
            .maxAge(3600);
    }
}
```

```yaml
# application-prod.yml
cors:
  allowed-origins: https://jiweidong.github.io,https://admin.example.com
```

### 3.3 注解方式（细粒度控制）

```java
@RestController
@RequestMapping("/api/users")
@CrossOrigin(origins = "http://localhost:3000", maxAge = 3600)
public class UserController {

    @GetMapping("/{id}")
    @CrossOrigin(origins = "http://admin.example.com")  // 方法级覆盖
    public User getUser(@PathVariable Long id) {
        return userService.getById(id);
    }

    @PostMapping
    public User createUser(@RequestBody User user) {
        return userService.save(user);
    }
}
```

### 3.4 Filter 方式（底层）

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class CorsFilter implements Filter {

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {

        HttpServletResponse response = (HttpServletResponse) res;
        HttpServletRequest request = (HttpServletRequest) req;

        response.setHeader("Access-Control-Allow-Origin", request.getHeader("Origin"));
        response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
        response.setHeader("Access-Control-Max-Age", "3600");
        response.setHeader("Access-Control-Allow-Credentials", "true");

        if ("OPTIONS".equalsIgnoreCase(request.getMethod())) {
            response.setStatus(HttpServletResponse.SC_OK);
        } else {
            chain.doFilter(req, res);
        }
    }
}
```

## 四、常见坑与解决方案

### 4.1 Nginx 反向代理配置

如果使用 Nginx 反代后端，CORS 也可以在 Nginx 层面配置：

```nginx
location /api/ {
    if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin' '$http_origin';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type';
        add_header 'Access-Control-Max-Age' 3600;
        add_header 'Access-Control-Allow-Credentials' 'true';
        return 204;
    }

    add_header 'Access-Control-Allow-Origin' '$http_origin' always;
    add_header 'Access-Control-Allow-Credentials' 'true' always;

    proxy_pass http://backend:8080;
}
```

### 4.2 Spring Security 拦截问题

配置了 Spring Security 后，OPTIONS 预检请求会被拦截：

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .cors(Customizer.withDefaults())   // 开启 CORS 支持
            .csrf(csrf -> csrf.disable())       // 跨域时一般需要关闭 CSRF
            .authorizeHttpRequests(auth -> auth
                .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()  // 放行预检
                .anyRequest().authenticated()
            );
        return http.build();
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOriginPatterns(List.of("*"));
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(List.of("*"));
        config.setAllowCredentials(true);
        config.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }
}
```

### 4.3 跨域携带 Cookie

```javascript
// 前端：必须设置 withCredentials
fetch('http://localhost:8080/api/user', {
    credentials: 'include'   // 携带 Cookie
});

// 后端配置要点
// 1. allowCredentials(true)
// 2. allowedOrigins 不能为 "*"，必须指定具体源
```

## 五、CORS vs 其他跨域方案

| 方案 | 原理 | 优点 | 缺点 |
|------|------|------|------|
| **CORS** | 浏览器 + 服务器协商 | 标准方案，安全可控 | 需服务端改造 |
| JSONP | `<script>` 标签回调 | 兼容老浏览器 | 仅支持 GET，不安全 |
| 代理服务器 | Nginx 反向代理 | 对后端透明 | 增加运维复杂度 |
| WebSocket | ws:// 协议无跨域限制 | 全双工通信 | 协议不同 |
| postMessage | iframe 通信 | 跨窗口通信 | 使用场景受限 |

## 六、最佳实践总结

```
┌─────────────────────────────────────────────────────────┐
│   CORS 生产配置 Checklist                                │
├─────────────────────────────────────────────────────────┤
│  ✅ 指定具体允许的 origin，不使用 *                      │
│  ✅ allowCredentials 为 true 时 origin 不能为 *          │
│  ✅ maxAge 设 1 小时减少 OPTIONS 请求                   │
│  ✅ Spring Security 配置中放行 OPTIONS                   │
│  ✅ 只对需要跨域的路径开放（如 /api/**）                 │
│  ✅ 生产环境用 Nginx + CORS 双重保障                    │
│  ✅ 调试时查看浏览器 Network 面板的 OPTIONS 请求         │
└─────────────────────────────────────────────────────────┘
```

## 七、常见面试题

### Q1: CORS 的简单请求和预检请求区别？

**简单请求**：浏览器直接发实际请求，响应头带 CORS 字段。
**预检请求**：浏览器先发 OPTIONS 问服务器是否允许，服务器回复允许后再发实际请求。

### Q2: 为什么会看到两次请求（OPTIONS + GET）？

这是正常的预检机制。如果不想每次请求都发 OPTIONS，可以：
1. 使用简单请求（限制 Content-Type 和请求头）
2. 设置 `Access-Control-Max-Age` 缓存预检结果

### Q3: allowCredentials(true) 时 allowedOrigins 不能用 * 怎么办？

有 3 种解决方案：
1. 用 `allowedOriginPatterns("*")`（Spring 5.3+）
2. 反射请求头 Origin 动态设置
3. 通过 Nginx 层统一处理

## 八、总结

CORS 是前后端分离架构中绕不开的问题。理解其原理和 Spring Boot 的配置方式，能帮你快速定位和解决跨域问题。**记住最关键的一点**：生产环境永远不要无脑用 `*`，按最小权限原则只开放需要的源和方法。
