---
title: Spring Security + JWT 认证授权实战（面试跳槽篇）
date: 2026-06-13 11:29:00
tags:
  - Spring Security
  - JWT
  - OAuth2
  - 认证授权
  - RBAC
  - 安全框架
categories: Spring框架
author: 东哥
cover: https://img.icons8.com/color/96/spring-logo.png
---

# Spring Security + JWT 认证授权实战（面试跳槽篇）

## 一、认证与授权核心概念

### 1.1 认证（Authentication）vs 授权（Authorization）

这两个概念是安全体系的基石，面试时经常被问到，一定要分清：

**认证（Authentication）**：你是谁？——验证用户身份的过程。比如输入用户名密码登录，或者用指纹、验证码等方式证明"我是我"。

**授权（Authorization）**：你能做什么？——确定已认证用户拥有哪些权限。比如普通用户只能看文章，管理员可以删除文章。

> 💡 **一句话区分**：认证是**身份验证**，授权是**权限分配**。先认证，后授权。

### 1.2 RBAC（Role-Based Access Control）模型

RBAC 是目前最广泛使用的权限模型，核心思想是：

```
用户 → 角色 → 权限
```

- **用户（User）**：系统的操作主体
- **角色（Role）**：权限的集合，如 ROLE_ADMIN、ROLE_USER
- **权限（Permission）**：具体操作，如 article:read、article:delete

这种设计的好处是解耦——给用户分配角色，就不用给每个用户单独配置权限了。比如来了个新员工，只需要给他分配"研发工程师"角色，所有相关权限自动就有了。

Spring Security 原生支持 RBAC，通过 `hasRole()`、`hasAuthority()` 等方法就能轻松实现。

### 1.3 Session 认证 vs Token 认证

| 对比项 | Session 认证 | Token 认证（JWT） |
|--------|-------------|-----------------|
| 存储位置 | 服务端内存/Redis | 客户端（浏览器/App） |
| 扩展性 | 差（Session 黏性问题） | 好（无状态） |
| 跨域 | 需要额外配置 | 天然支持 |
| 安全性 | 依赖 Cookie，易 CSRF | Token 存在 localStorage |
| 移动端 | 不支持 | 完美支持 |

### 1.4 无状态认证的优势

现代应用（尤其是前后端分离 + 微服务架构）更倾向于无状态认证：

1. **水平扩展轻松**：任何服务器都可以处理请求，不需要共享 Session 存储
2. **跨域/跨端**：App、Web、小程序都能用同一套认证机制
3. **减少服务端压力**：不需要维护海量 Session 信息
4. **微服务友好**：一个 Token 可在多个服务间传递认证信息

---

## 二、Spring Security 核心架构

Spring Security 本质上是**一组 Servlet Filter 组成的过滤器链**。理解这个架构是掌握 Spring Security 的关键。

### 2.1 SecurityFilterChain 过滤器链

Spring Security 通过 `SecurityFilterChain` 将多个过滤器串联起来。当请求进来时，会依次经过这些过滤器：

```
请求 → ... → SecurityContextPersistenceFilter
            → UsernamePasswordAuthenticationFilter
            → ExceptionTranslationFilter
            → FilterSecurityInterceptor
            → 实际 Controller/Method
```

每个过滤器只做自己那一件事，职责单一，这也是经典的**责任链模式**。

### 2.2 核心过滤器

#### UsernamePasswordAuthenticationFilter
处理表单登录请求（`POST /login`），从请求中提取用户名和密码，封装成 `UsernamePasswordAuthenticationToken`，交给 `AuthenticationManager` 处理。

```java
public Authentication attemptAuthentication(HttpServletRequest request,
                                            HttpServletResponse response) {
    String username = obtainUsername(request);
    String password = obtainPassword(request);
    UsernamePasswordAuthenticationToken authRequest =
        new UsernamePasswordAuthenticationToken(username, password);
    return this.getAuthenticationManager().authenticate(authRequest);
}
```

#### ExceptionTranslationFilter
捕获过滤器链中的异常，做出对应的响应：
- `AuthenticationException` → 返回 401 或跳转登录页
- `AccessDeniedException` → 返回 403 或访问拒绝页面

#### FilterSecurityInterceptor
**最后一个过滤器**，负责最终决定当前用户是否有权限访问资源。它调用 `AccessDecisionManager` 来做授权决策。

### 2.3 AuthenticationManager → ProviderManager → AuthenticationProvider

认证流程的核心链路：

```java
AuthenticationManager (接口)
    └── ProviderManager (实现)
            ├── DaoAuthenticationProvider (用户名密码认证)
            ├── JwtAuthenticationProvider (JWT 认证)
            └── OAuth2LoginAuthenticationProvider (OAuth2 登录)
```

- `AuthenticationManager`：顶层接口，定义 `authenticate()` 方法
- `ProviderManager`：实现类，维护一个 `AuthenticationProvider` 列表，逐个尝试
- `AuthenticationProvider`：真正执行认证逻辑的组件

### 2.4 SecurityContextHolder / SecurityContext / Authentication

这三个是存储认证信息的容器：

```
SecurityContextHolder (存储当前线程的上下文)
    └── SecurityContext (持有 Authentication 对象)
            └── Authentication (认证信息)
                    ├── principal: 用户主体（UserDetails）
                    ├── credentials: 凭据（密码/Token）
                    └── authorities: 权限列表（GrantedAuthority）
```

```java
// 在业务代码中获取当前用户
SecurityContext context = SecurityContextHolder.getContext();
Authentication auth = context.getAuthentication();
String username = auth.getName();
```

> ⚠️ 默认使用 `ThreadLocal` 存储，所以在请求处理完毕后一定要清除，否则会有线程安全问题。

### 2.5 UserDetailsService 与 PasswordEncoder

**UserDetailsService**：定义如何从存储中加载用户信息。

```java
public interface UserDetailsService {
    UserDetails loadUserByUsername(String username) 
        throws UsernameNotFoundException;
}
```

实际开发中你需要实现这个接口，从数据库/Redis 中查询用户：

```java
@Service
public class CustomUserDetailsService implements UserDetailsService {
    @Autowired
    private UserMapper userMapper;
    
    @Override
    public UserDetails loadUserByUsername(String username) {
        User user = userMapper.findByUsername(username);
        if (user == null) {
            throw new UsernameNotFoundException("用户不存在");
        }
        return new org.springframework.security.core.userdetails.User(
            user.getUsername(),
            user.getPassword(),
            AuthorityUtils.commaSeparatedStringToAuthorityList(user.getRoles())
        );
    }
}
```

**PasswordEncoder**：密码加密/验证策略。**永远不要存储明文密码！**

```java
// 推荐使用 BCrypt（自动加盐）
@Bean
public PasswordEncoder passwordEncoder() {
    return new BCryptPasswordEncoder();
}

// 加密：$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy
passwordEncoder.encode("123456");

// 验证
passwordEncoder.matches("123456", encodedPassword); // true
```

BCrypt 每次生成的密文都不一样（自动加盐），而且可以调节计算强度，有效抵御彩虹表攻击。

---

## 三、JWT（JSON Web Token）详解

### 3.1 什么是 JWT

JWT 是一种**自包含**的 Token 格式，将用户信息编码到 Token 本身，服务端不需要存储 Session 就能认证。

### 3.2 JWT 结构

一个 JWT 由三部分组成，用点号 `.` 分隔：

```
eyJhbGciOiJIUzI1NiJ9
.eyJzdWIiOiJhZG1pbiIsInJvbGVzIjoiUk9MRV9BRE1JTiJ9
.7dQ3P1u0KsFQ8tG7X9X9z6X9X9X9X9X9X9X9X9X9X9w
```

1. **Header**：声明类型和签名算法
   ```json
   {"alg": "HS256", "typ": "JWT"}
   ```
2. **Payload**：存放实际数据（claims）
   ```json
   {"sub": "admin", "roles": "ROLE_ADMIN", "iat": 1700000000, "exp": 1700086400}
   ```
3. **Signature**：对前两部分签名，防止篡改

### 3.3 签名算法：HS256 vs RS256

| 对比项 | HS256（对称） | RS256（非对称） |
|--------|-------------|---------------|
| 密钥 | 同一个密钥签名和验证 | 私钥签名，公钥验证 |
| 速度 | 快 | 慢 |
| 分发 | 密钥不能泄露 | 公钥可以公开分发 |
| 适用场景 | 单体应用 | 微服务、第三方分发 |
| 安全风险 | 密钥泄露则全完 | 私钥泄露才完 |

> 微服务架构推荐 **RS256**：认证服务用私钥签发，其他服务用公钥验证，公钥可以随便给。

### 3.4 生成 JWT（jjwt 库）

项目中一般用 **jjwt**（Java JWT）库，配置简单，功能完善：

```xml
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-api</artifactId>
    <version>0.12.5</version>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-impl</artifactId>
    <version>0.12.5</version>
    <scope>runtime</scope>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-jackson</artifactId>
    <version>0.12.5</version>
    <scope>runtime</scope>
</dependency>
```

```java
@Component
public class JwtUtil {
    
    private final SecretKey key = Jwts.SIG.HS256.key().build();
    private final long expiration = 3600000; // 1小时
    
    // 生成 Token
    public String generateToken(String username, List<String> roles) {
        return Jwts.builder()
            .subject(username)
            .claim("roles", roles)
            .issuedAt(new Date())
            .expiration(new Date(System.currentTimeMillis() + expiration))
            .signWith(key)
            .compact();
    }
    
    // 解析 Token
    public Claims parseToken(String token) {
        return Jwts.parser()
            .verifyWith(key)
            .build()
            .parseSignedClaims(token)
            .getPayload();
    }
    
    // 验证 Token 是否过期
    public boolean isTokenExpired(String token) {
        return parseToken(token).getExpiration().before(new Date());
    }
}
```

### 3.5 JWT 校验流程

```
客户端请求 → 携带 JWT（Authorization: Bearer xxx）
  ↓
自定义过滤器提取 Token
  ↓
解析 Token（验证签名 & 有效期）
  ↓
提取用户信息（username、roles）
  ↓
创建 UsernamePasswordAuthenticationToken
  ↓
设置到 SecurityContextHolder
  ↓
放行请求 → 后续过滤器进行权限校验
```

### 3.6 JWT 的优缺点

**优点**：
- ✅ 无状态，服务端不需要存储
- ✅ 自包含，一次解析拿到全部信息
- ✅ 跨域、跨端、跨服务
- ✅ 适合分布式/微服务架构

**缺点**：
- ❌ **无法主动失效**：签发后到期前一直有效
- ❌ Payload 不是加密的（只是 Base64 编码），**不能放敏感信息**
- ❌ Token 越长，每次请求的带宽开销越大

### 3.7 如何解决 JWT 登出问题

JWT 最大的痛点就是无法真正登出（服务端没法让已签发的 Token 失效）。常见解决方案：

**方案一：黑名单（简单粗暴）**
```java
// 用户登出时，将 Token 加入 Redis 黑名单
// 每次请求检查 Token 是否在黑名单中
redisTemplate.opsForValue().set("blacklist:" + token, "1", 
    Duration.ofMillis(jwtUtil.getRemainingTime(token)));
```

**方案二：短 TTL + Refresh Token（推荐）**
- Access Token：有效期 15-30 分钟
- Refresh Token：有效期 7-30 天
- Access Token 过期后，用 Refresh Token 换取新的 Access Token
- 登出时只需删除 Refresh Token

**方案三：Token 版本号**
- 在 Redis 中存一个用户版本号
- JWT 中包含这个版本号
- 登出时递增版本号，所有旧 Token 自动失效

> 💡 **推荐用方案二**：短 TTL 降低泄露风险，Refresh Token 保证用户体验，登出只需删除 Refresh Token。

---

## 四、Spring Security + JWT 集成实战

### 4.1 自定义 JwtAuthenticationTokenFilter

核心过滤器，继承 `OncePerRequestFilter`，确保每次请求只执行一次：

```java
@Component
public class JwtAuthenticationTokenFilter extends OncePerRequestFilter {
    
    @Autowired
    private JwtUtil jwtUtil;
    @Autowired
    private UserDetailsService userDetailsService;
    
    @Override
    protected void doFilterInternal(@NonNull HttpServletRequest request,
                                    @NonNull HttpServletResponse response,
                                    @NonNull FilterChain filterChain)
            throws ServletException, IOException {
        
        // 1. 从请求头获取 Token
        String token = extractToken(request);
        
        // 2. 如果 Token 存在，解析并设置认证信息
        if (token != null && jwtUtil.validateToken(token)) {
            String username = jwtUtil.getUsernameFromToken(token);
            UserDetails userDetails = userDetailsService.loadUserByUsername(username);
            
            UsernamePasswordAuthenticationToken authentication =
                new UsernamePasswordAuthenticationToken(
                    userDetails, null, userDetails.getAuthorities());
            authentication.setDetails(
                new WebAuthenticationDetailsSource().buildDetails(request));
            
            SecurityContextHolder.getContext().setAuthentication(authentication);
        }
        
        filterChain.doFilter(request, response);
    }
    
    private String extractToken(HttpServletRequest request) {
        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            return header.substring(7);
        }
        return null;
    }
}
```

### 4.2 SecurityConfig 配置类

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity // 开启方法级权限控制
public class SecurityConfig {
    
    @Autowired
    private JwtAuthenticationTokenFilter jwtAuthFilter;
    @Autowired
    private UserDetailsService userDetailsService;
    
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            // 1. 关闭 CSRF（前后端分离不需要）
            .csrf(AbstractHttpConfigurer::disable)
            
            // 2. CORS 配置
            .cors(cors -> cors.configurationSource(corsConfigurationSource()))
            
            // 3. 无需登录的接口
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/auth/**", "/api/public/**").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated()
            )
            
            // 4. 异常处理
            .exceptionHandling(ex -> ex
                .authenticationEntryPoint(authenticationEntryPoint())
                .accessDeniedHandler(accessDeniedHandler())
            )
            
            // 5. 添加 JWT 过滤器（在 UsernamePasswordAuthenticationFilter 之前）
            .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class)
            
            // 6. Session 管理（无状态）
            .sessionManagement(session -> 
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS));
        
        return http.build();
    }
    
    // CORS 配置
    private CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOrigins(List.of("http://localhost:3000"));
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(List.of("*"));
        config.setAllowCredentials(true);
        
        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }
    
    // 未认证处理
    private AuthenticationEntryPoint authenticationEntryPoint() {
        return (request, response, authException) -> {
            response.setContentType("application/json;charset=UTF-8");
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            response.getWriter().write("{\"code\":401,\"msg\":\"未登录\"}");
        };
    }
    
    // 无权限处理
    private AccessDeniedHandler accessDeniedHandler() {
        return (request, response, accessDeniedException) -> {
            response.setContentType("application/json;charset=UTF-8");
            response.setStatus(HttpServletResponse.SC_FORBIDDEN);
            response.getWriter().write("{\"code\":403,\"msg\":\"权限不足\"}");
        };
    }
}
```

### 4.3 角色/权限控制

Spring Security 支持多种授权方式：

**1. URL 路径控制（SecurityConfig 中配置）**
```java
.requestMatchers("/api/admin/**").hasRole("ADMIN")
.requestMatchers("/api/user/**").hasRole("USER")
```

**2. 方法注解控制（推荐）**
```java
@RestController
@RequestMapping("/api/articles")
public class ArticleController {
    
    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('article:read')")  // 拥有 article:read 权限
    public R<Article> getById(@PathVariable Long id) {
        return R.ok(articleService.getById(id));
    }
    
    @PostMapping
    @PreAuthorize("hasRole('ADMIN')")  // 需要 ADMIN 角色
    public R<Void> create(@RequestBody Article article) {
        articleService.save(article);
        return R.ok();
    }
    
    @DeleteMapping("/{id}")
    @PreAuthorize("hasRole('ADMIN')")  // 只有管理员能删除
    public R<Void> delete(@PathVariable Long id) {
        articleService.removeById(id);
        return R.ok();
    }
}
```

常用 SpEL 表达式：
- `hasRole('ADMIN')` — 是否拥有 ADMIN 角色（自动加 ROLE_ 前缀）
- `hasAuthority('article:read')` — 是否拥有指定权限
- `hasAnyRole('ADMIN', 'MANAGER')` — 是否拥有任一角色
- `@ss.hasPermission(#id, 'article')` — 自定义权限评估器

### 4.4 CORS 配置

前后端分离必须解决跨域问题。在 SecurityConfig 中配置即可：

```java
@Bean
public CorsConfigurationSource corsConfigurationSource() {
    CorsConfiguration config = new CorsConfiguration();
    config.setAllowedOriginPatterns(List.of("*")); // 允许的域名
    config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "OPTIONS"));
    config.setAllowedHeaders(List.of("*"));
    config.setAllowCredentials(true);
    config.setMaxAge(3600L);
    
    UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
    source.registerCorsConfiguration("/**", config);
    return source;
}
```

> ⚠️ 注意：设置了 `allowCredentials(true)` 后，`allowedOrigins` 不能使用 `"*"` 通配符，必须使用 `allowedOriginPatterns`。

---

## 五、OAuth2 协议

### 5.1 OAuth2 四种授权模式

OAuth2 定义了四种授权模式，适用于不同场景：

| 模式 | 适用场景 | 安全级别 |
|------|---------|---------|
| **授权码模式** | 第三方 Web 应用登录 | ⭐⭐⭐⭐⭐ |
| 简化模式 | 纯前端应用（SPA） | ⭐⭐⭐ |
| 密码模式 | 自家应用（不推荐） | ⭐⭐ |
| 客户端模式 | 服务间调用 | ⭐⭐⭐⭐ |

**授权码模式（最常用）** 的工作流程：

```
1. 用户点击"微信登录"
2. 重定向到微信授权页
3. 用户确认授权
4. 微信返回授权码（code）
5. 后端用 code 换 access_token
6. 用 access_token 获取用户信息
7. 创建/登录本地账号
```

为什么要有授权码这一步？因为授权码是一次性的，且后端直接和认证服务器交互拿 Token，Token 不会暴露给前端，安全性大大提升。

### 5.2 Spring Authorization Server

Spring 官方在 2022 年推出了 **Spring Authorization Server**，替代已停更的 Spring Security OAuth2 模块。

使用 Maven 依赖：

```xml
<dependency>
    <groupId>org.springframework.security</groupId>
    <artifactId>spring-security-oauth2-authorization-server</artifactId>
    <version>1.3.1</version>
</dependency>
```

### 5.3 第三方登录流程解析

以微信登录为例：

```java
// 1. 前端点击微信登录按钮，跳转微信授权页
String wechatAuthUrl = "https://open.weixin.qq.com/connect/qrconnect"
    + "?appid=APP_ID"
    + "&redirect_uri=" + URLEncoder.encode(callbackUrl, "UTF-8")
    + "&response_type=code"
    + "&scope=snsapi_login"
    + "&state=" + generateState();

// 2. 回调处理
@GetMapping("/oauth2/callback/wechat")
public R<String> wechatCallback(@RequestParam String code) {
    // 用 code 换 access_token
    String tokenUrl = "https://api.weixin.qq.com/sns/oauth2/access_token"
        + "?appid=APP_ID&secret=APP_SECRET&code=" + code + "&grant_type=authorization_code";
    
    // 获取用户信息
    String userInfoUrl = "https://api.weixin.qq.com/sns/userinfo"
        + "?access_token=" + accessToken + "&openid=" + openId;
    
    // 创建/查找本地用户，签发 JWT
    String jwt = jwtUtil.generateToken(user.getUsername(), user.getRoles());
    return R.ok(jwt);
}
```

---

## 六、安全防护

### 6.1 CSRF 防御

**CSRF（跨站请求伪造）**：用户登录 A 网站后，访问恶意网站 B，B 网站伪造请求让用户在不知情的情况下执行操作。

在传统表单应用中，通过 CSRF Token 来防御——请求必须携带一个随机 Token，攻击者无法获取这个 Token。

**前后端分离为什么关 CSRF？**
1. 使用 Token 认证（JWT），不依赖 Cookie
2. 攻击者用不了你的 JWT
3. 跨域限制（CORS）本身就是一层防御
4. CSRF Token 在前后端分离架构中实现起来反而麻烦

```java
// 前后端分离：关掉 CSRF
http.csrf(AbstractHttpConfigurer::disable);
```

### 6.2 XSS 防护

**XSS（跨站脚本攻击）**：攻击者向页面注入恶意脚本。

防御措施：
1. **输出编码**：前端框架（React/Vue）默认对输出进行 HTML 编码
2. **Content-Security-Policy**：限制资源加载来源
3. **HttpOnly Cookie**：禁止 JavaScript 访问 Cookie
4. **输入过滤**：使用 OWASP 库过滤用户输入

### 6.3 密码加密策略

```java
@Bean
public PasswordEncoder passwordEncoder() {
    // strength=10 表示 2^10 次哈希，推荐 10-12
    return new BCryptPasswordEncoder(10);
}
```

**BCrypt 特性**：
- 自动加盐（每次生成的 Hash 都不一样）
- 可调节计算强度（强度越高越慢）
- 能抵御彩虹表攻击

**密码存储建议**：
- 不要限制密码长度和特殊字符
- 使用 BCrypt 加密存储
- 传输层使用 HTTPS 加密

### 6.4 敏感接口防刷（限流）

```java
@Component
public class RateLimitInterceptor implements HandlerInterceptor {
    
    private final RateLimiter loginLimiter = 
        RateLimiter.create(1.0); // 每秒 1 个请求
    
    @Override
    public boolean preHandle(HttpServletRequest request, 
                             HttpServletResponse response, 
                             Object handler) {
        String ip = request.getRemoteAddr();
        if (!loginLimiter.tryAcquire()) {
            throw new RateLimitException("操作太频繁，请稍后再试");
        }
        return true;
    }
}
```

高级实现可使用 Redis 进行分布式限流（滑动窗口/令牌桶/漏桶算法）。

---

## 七、面试高频题

### 7.1 如何设计一个安全的登录系统

回答要点：
1. **传输层**：HTTPS 加密
2. **密码存储**：BCrypt 加密，绝不存明文
3. **登录限制**：验证码、失败次数限制、IP 限流
4. **Token 管理**：短 TTL + Refresh Token，防重放
5. **异常检测**：异地登录提醒、常用设备识别
6. **日志审计**：记录所有登录操作

### 7.2 JWT 如何实现自动续期

**方案：Refresh Token 机制**

```
Access Token（15分钟） + Refresh Token（7天）
  ↓
Access Token 过期 → 前端发现 401
  ↓
用 Refresh Token 请求 /api/auth/refresh
  ↓
服务端验证 Refresh Token 有效性
  ↓
签发新的 Access Token + 可选的 Refresh Token（滚动续期）
  ↓
前端用新 Token 重新请求
```

```java
@PostMapping("/refresh")
public R<AuthResponse> refresh(@RequestBody RefreshRequest request) {
    String refreshToken = request.getRefreshToken();
    
    // 1. 验证 Refresh Token
    if (!jwtUtil.validateRefreshToken(refreshToken)) {
        return R.error(401, "Refresh Token 已过期，请重新登录");
    }
    
    // 2. 检查 Refresh Token 是否被撤销（Redis 黑名单）
    if (redisTemplate.hasKey("refresh:blacklist:" + refreshToken)) {
        return R.error(401, "Refresh Token 已被撤销");
    }
    
    // 3. 签发新的 Token
    String username = jwtUtil.getUsernameFromRefreshToken(refreshToken);
    UserDetails userDetails = userDetailsService.loadUserByUsername(username);
    
    String newAccessToken = jwtUtil.generateToken(username, userDetails.getAuthorities());
    String newRefreshToken = jwtUtil.generateRefreshToken(username);
    
    return R.ok(new AuthResponse(newAccessToken, newRefreshToken));
}
```

### 7.3 多端登录（手机/PC）互踢如何实现

**方案：Token 版本号 + Redis**

```java
// 1. 用户登录时，生成版本号并存入 Redis
String loginId = username + ":" + deviceType; // 按设备区分
String version = UUID.randomUUID().toString();
redisTemplate.opsForValue().set("token:version:" + loginId, version, 
    Duration.ofDays(7));

// 2. JWT 中携带版本号
String token = Jwts.builder()
    .subject(username)
    .claim("version", version)   ← 包含版本号
    .claim("device", deviceType)
    .expiration(...)
    .signWith(key)
    .compact();

// 3. 过滤器验证 Token 时检查版本号
Claims claims = jwtUtil.parseToken(token);
String currentVersion = redisTemplate.opsForValue()
    .get("token:version:" + username + ":" + claims.get("device"));
    
// 如果 Redis 中的版本号 ≠ JWT 中的版本号，说明已被踢下线
if (!claims.get("version").equals(currentVersion)) {
    throw new AuthenticationException("账号在其他设备登录");
}
```

**手机和 PC 不互踢**：不同的 deviceType 生成不同的 Redis key，两个设备可以同时在线。

### 7.4 @PreAuthorize 底层实现原理

`@PreAuthorize` 基于 **Spring AOP + 方法拦截器**，底层流程：

```
1. @EnableMethodSecurity 注册 MethodSecurityInterceptor
2. 创建代理对象（CGLIB/JDK 动态代理）
3. 目标方法执行前，MethodSecurityInterceptor 拦截
4. 解析 @PreAuthorize 中的 SpEL 表达式
5. SecurityExpressionRoot 计算表达式结果
6. 结果为 true → 放行；false → 抛出 AccessDeniedException
```

内部使用 `SecurityExpressionOperations` 接口，默认实现是 `SecurityExpressionRoot`，提供 `hasRole()`、`hasAuthority()` 等方法。

### 7.5 Spring Security 过滤器链的执行顺序

过滤器在链中的顺序至关重要，可以通过 `@Order` 注解或配置类的添加顺序控制。

常见过滤器执行顺序：

| 序号 | 过滤器 | 职责 |
|------|--------|------|
| 1 | SecurityContextPersistenceFilter | 从 Session 恢复/保存 SecurityContext |
| 2 | LogoutFilter | 处理登出请求 |
| 3 | JwtAuthenticationTokenFilter | 自定义 JWT 认证（加在 UsernamePassword 之前） |
| 4 | UsernamePasswordAuthenticationFilter | 处理表单登录 |
| 5 | BasicAuthenticationFilter | HTTP Basic 认证 |
| 6 | ExceptionTranslationFilter | 捕获并处理认证/授权异常 |
| 7 | FilterSecurityInterceptor | 最后的权限拦截器 |
| 8 | Controller/API | 业务方法 |

> 💡 自定义过滤器一般放在 `UsernamePasswordAuthenticationFilter` 之前，这样 JWT 认证优先于表单登录。

---

## 总结

本文从认证授权的基础概念出发，深入解析了 Spring Security 的核心架构、JWT 的原理与实现，并给出了完整的 Spring Security + JWT 集成方案。

在实际项目中，根据业务复杂度选择合适的安全方案：
- **小项目**：Spring Security + JWT 一把梭
- **中大型项目**：引入 OAuth2 + Spring Authorization Server
- **微服务架构**：推荐统一认证服务 + 各服务间用 RS256 验证

安全无小事，设计系统时一定要把安全作为**第一优先级**来考虑。希望对你的面试和实战有帮助！🚀
