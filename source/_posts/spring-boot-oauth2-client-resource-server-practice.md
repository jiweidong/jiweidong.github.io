---
title: 【微服务实战】Spring Boot 3.x OAuth2 Client 与 Resource Server 认证授权实战
date: 2026-07-19 08:00:00
tags:
  - Spring Boot
  - OAuth2
  - Spring Security
  - 认证授权
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【微服务实战】Spring Boot 3.x OAuth2 Client 与 Resource Server 认证授权实战

## 一、场景与背景

在微服务架构中，认证和授权通常不是由每个微服务自己实现的，而是通过统一的 **OAuth 2.0** 协议委托给授权服务器处理。这就涉及到两个核心角色：

| 角色 | 职责 | Spring Boot 组件 |
|-----|------|----------------|
| **OAuth2 Client** | 代表用户向授权服务器请求令牌，用于"第三方登录" | `spring-boot-starter-oauth2-client` |
| **Resource Server** | 验证访问令牌（JWT），决定是否允许访问资源 | `spring-boot-starter-oauth2-resource-server` |

### 典型架构

```
┌──────────┐      ┌──────────────┐      ┌────────────────┐      ┌───────────┐
│ 浏览器/App │────→│ OAuth2 Client │────→│  Authorization  │────→│  用户确认  │
│           │      │ (Spring Boot) │      │    Server      │      │           │
└──────────┘      └──────────────┘      └────────────────┘      └───────────┘
     │                    │                      │
     │                   GET /api/orders         │
     │←──── JWT ──────────│                      │
     │                    │                      │
     │←───────────── 资源 ───────────────────────│
```

本文聚焦两个实战场景：

1. **OAuth2 Client**：集成 GitHub/Google 第三方登录
2. **Resource Server**：JWT 令牌验证，保护微服务 API

> 注意：本文不涉及搭建 Authorization Server，如果需要，请参考 `spring-authorization-server-guide.md`。

## 二、OAuth2 Client 实战：第三方登录

### 2.1 添加依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-client</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
```

### 2.2 GitHub OAuth App 注册

在 GitHub Settings → Developer Settings → OAuth Apps → Register a new application：

```
Application name: My Spring App
Homepage URL:     http://localhost:8080
Authorization callback URL: http://localhost:8080/login/oauth2/code/github
```

注册后获取 `Client ID` 和 `Client Secret`。

### 2.3 配置 application.yml

```yaml
spring:
  security:
    oauth2:
      client:
        registration:
          github:
            client-id: ${GITHUB_CLIENT_ID}
            client-secret: ${GITHUB_CLIENT_SECRET}
            scope: read:user,user:email
            # 自定义各参数（可选）
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/{registrationId}"
            
          google:  # 可以同时配置多个 Provider
            client-id: ${GOOGLE_CLIENT_ID}
            client-secret: ${GOOGLE_CLIENT_SECRET}
            scope: profile,email
            
        # Provider 配置（如果是自定义 OAuth2 服务）
        provider:
          my-idp:
            authorization-uri: https://my-idp.com/oauth2/authorize
            token-uri: https://my-idp.com/oauth2/token
            user-info-uri: https://my-idp.com/userinfo
            user-name-attribute: sub
```

### 2.4 安全配置

```java
@Configuration
@EnableWebSecurity
public class OAuth2LoginConfig {
    
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            // 配置 OAuth2 登录
            .oauth2Login(oauth2 -> oauth2
                .loginPage("/login")  // 自定义登录页面
                .defaultSuccessUrl("/home", true)
                .failureUrl("/login?error=true")
                .userInfoEndpoint(userInfo -> userInfo
                    .userService(customOAuth2UserService())
                )
            )
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/login", "/error", "/webjars/**").permitAll()
                .anyRequest().authenticated()
            )
            .logout(logout -> logout
                .logoutSuccessUrl("/login")
                .invalidateHttpSession(true)
                .deleteCookies("JSESSIONID")
            );
        return http.build();
    }
    
    private OAuth2UserService<OAuth2UserRequest, OAuth2User> customOAuth2UserService() {
        // 自定义用户信息处理
        return userRequest -> {
            String registrationId = userRequest.getClientRegistration().getRegistrationId();
            // 默认的 OAuth2UserService
            OAuth2UserService<OAuth2UserRequest, OAuth2User> delegate = 
                new DefaultOAuth2UserService();
            OAuth2User oAuth2User = delegate.loadUser(userRequest);
            
            // 可以在这里将用户信息保存到数据库
            // userService.saveOrUpdate(oAuth2User, registrationId);
            
            return oAuth2User;
        };
    }
}
```

### 2.5 自定义登录页面

```html
<!-- src/main/resources/templates/login.html -->
<!DOCTYPE html>
<html xmlns:th="http://www.thymeleaf.org">
<head><title>登录</title></head>
<body>
  <h1>请登录</h1>
  <div th:each="entry : ${oauth2AuthorizationUrl}">
    <a th:href="${entry.value}" th:text="'使用 ' + ${entry.key} + ' 登录'">
    </a>
  </div>
</body>
</html>
```

```java
@Controller
public class LoginController {
    
    @GetMapping("/login")
    public String login(Model model) {
        // 获取所有 OAuth2 登录链接
        // Spring Boot 会自动将这些链接注入到 /oauth2/authorization/{registrationId}
        return "login";
    }
}
```

### 2.6 获取用户信息

```java
@RestController
public class UserController {
    
    @GetMapping("/user")
    public Map<String, Object> user(@AuthenticationPrincipal OAuth2User principal) {
        return Map.of(
            "name", principal.getAttribute("name"),
            "login", principal.getAttribute("login"),
            "email", principal.getAttribute("email"),
            "avatar", principal.getAttribute("avatar_url")
        );
    }
    
    @GetMapping("/home")
    public String home(Model model, @AuthenticationPrincipal OAuth2User user) {
        model.addAttribute("name", user.getAttribute("name"));
        return "home";
    }
}
```

## 三、Resource Server 实战：JWT 令牌验证

### 3.1 添加依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
</dependency>
```

### 3.2 配置 application.yml

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          # 方式一：从授权服务器的 JWK Set URI 获取公钥（推荐）
          jwk-set-uri: https://auth.example.com/.well-known/jwks.json
          
          # 方式二（可选）：直接指定公钥
          # public-key-location: classpath:public-key.pem
          
          # 方式三（可选）：自定义 issuer-uri
          # issuer-uri: https://auth.example.com
```

### 3.3 安全配置

```java
@Configuration
@EnableWebSecurity
@EnableGlobalMethodSecurity(prePostEnabled = true)
public class ResourceServerConfig {
    
    @Bean
    public SecurityFilterChain resourceServerFilterChain(HttpSecurity http) throws Exception {
        http
            .securityMatcher("/api/**")  // 只保护 /api/** 路径
            .authorizeHttpRequests(auth -> auth
                .requestMatchers(HttpMethod.GET, "/api/public/**").permitAll()
                .requestMatchers(HttpMethod.GET, "/api/users/**").hasAuthority("SCOPE_read")
                .requestMatchers(HttpMethod.POST, "/api/orders/**").hasAuthority("SCOPE_write")
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt
                    .jwtAuthenticationConverter(jwtAuthenticationConverter())
                )
                // 也可以配置 opaque token（不透明令牌）
                // .opaqueToken(opaque -> opaque
                //     .introspectionUri("https://auth.example.com/introspect")
                //     .introspectionClientCredentials("client-id", "client-secret")
                // )
            )
            .sessionManagement(session -> session
                .sessionCreationPolicy(SessionCreationPolicy.STATELESS)  // 无状态
            )
            .csrf(csrf -> csrf.disable());  // REST API 不需要 CSRF
        
        return http.build();
    }
    
    /**
     * 自定义 JWT 认证转换器：将 JWT 的 claims 映射为 Spring Security 的 GrantedAuthority
     */
    private JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter grantedAuthorities = 
            new JwtGrantedAuthoritiesConverter();
        grantedAuthorities.setAuthorityPrefix("ROLE_");       // 角色前缀
        grantedAuthorities.setAuthoritiesClaimName("roles"); // 从 JWT 的 roles claim 中提取
        
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(grantedAuthorities);
        return converter;
    }
}
```

### 3.4 自定义 JWT 校验

```java
@Component
public class CustomJwtDecoder {
    
    private final JwtDecoder jwtDecoder;
    
    public CustomJwtDecoder() {
        // 方式一：JWK Set URI
        NimbusJwtDecoder decoder = NimbusJwtDecoder
            .withJwkSetUri("https://auth.example.com/.well-known/jwks.json")
            .jwsAlgorithm(SignatureAlgorithm.RS256)
            .build();
        
        // 方式二（可选）：添加自定义校验
        OAuth2TokenValidator<Jwt> audienceValidator = new JwtClaimValidator<List<String>>(
            "aud", aud -> aud != null && aud.contains("my-service")
        );
        
        OAuth2TokenValidator<Jwt> issuerValidator = 
            JwtValidators.createDefaultWithIssuer("https://auth.example.com");
        
        OAuth2TokenValidator<Jwt> combinedValidator = 
            new DelegatingOAuth2TokenValidator<>(issuerValidator, audienceValidator);
        
        decoder.setJwtValidator(combinedValidator);
        this.jwtDecoder = decoder;
    }
    
    @Bean
    public JwtDecoder jwtDecoder() {
        return jwtDecoder;
    }
}
```

### 3.5 在 Controller 中获取认证信息

```java
@RestController
@RequestMapping("/api/users")
public class UserApiController {
    
    // 方式一：通过 @AuthenticationPrincipal 获取 JWT
    @GetMapping("/me")
    public Map<String, Object> me(@AuthenticationPrincipal Jwt jwt) {
        return Map.of(
            "subject", jwt.getSubject(),
            "claims", jwt.getClaims()
        );
    }
    
    // 方式二：通过 SecurityContextHolder 获取
    @GetMapping("/profile")
    public UserProfile profile() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        Jwt jwt = (Jwt) auth.getPrincipal();
        
        return new UserProfile(
            jwt.getSubject(),
            jwt.getClaimAsString("name"),
            jwt.getClaimAsString("email")
        );
    }
    
    // 方式三：方法级权限控制
    @GetMapping("/{id}")
    @PreAuthorize("hasRole('ADMIN') or #id == authentication.name")
    public User getUser(@PathVariable Long id) {
        return userService.findById(id);
    }
}
```

### 3.6 客户端调用（携带 JWT）

```java
// 使用 RestTemplate 调用 Resource Server
@RestController
public class OrderController {
    
    @GetMapping("/orders")
    public List<Order> getOrders(@AuthenticationPrincipal Jwt jwt) {
        // 在服务间调用时传递 JWT
        RestTemplate restTemplate = new RestTemplate();
        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth(jwt.getTokenValue());  // 传递当前 JWT
        
        HttpEntity<Void> entity = new HttpEntity<>(headers);
        ResponseEntity<List> response = restTemplate.exchange(
            "http://user-service/api/users/me",
            HttpMethod.GET,
            entity,
            List.class
        );
        return response.getBody();
    }
}
```

或者使用声明式的 `WebClient`：

```java
@Bean
public WebClient webClient() {
    return WebClient.builder()
        .baseUrl("http://user-service")
        .build();
}

// 使用时传递 JWT
@Service
public class OrderService {
    
    private final WebClient webClient;
    
    public Mono<UserInfo> getUserInfo(String token) {
        return webClient.get()
            .uri("/api/users/me")
            .headers(h -> h.setBearerAuth(token))
            .retrieve()
            .bodyToMono(UserInfo.class);
    }
}
```

## 四、完整流程：Client → Resource Server 调用链路

```
┌─────────┐     ┌──────────────┐     ┌────────────────┐     ┌──────────────┐
│ 浏览器   │     │ OAuth2 Client│     │ Auth Server    │     │Resource Server│
│         │     │ (前端 Gateway) │     │ (Keycloak)     │     │ (订单服务)    │
└────┬────┘     └──────┬───────┘     └───────┬────────┘     └──────┬───────┘
     │                  │                     │                     │
     │   访问首页        │                     │                     │
     │─────────────────→│                     │                     │
     │ ←─ 302 重定向 ────│                     │                     │
     │                  │                     │                     │
     │   跳转登录页面    │     /oauth2/authorize │                     │
     │────────────────────────────────────────→│                     │
     │                  │                     │                     │
     │   用户确认授权    │                     │                     │
     │←────────────────────────────────────────│                     │
     │                  │                     │                     │
     │  授权码回调       │  /login/oauth2/code │                     │
     │─────────────────→│────────────────────→│                     │
     │                  │ ←──── access_token ──│                     │
     │                  │                     │                     │
     │  携带 JWT 访问 API │                     │                     │
     │─────────────────→│   Authorization: Bearer <JWT>             │
     │                  │───────────────────────────────────────────→│
     │                  │                     │                      │
     │                  │                     │   验证 JWT 签名      │
     │                  │                     │← JWKS 获取公钥 ─────→│
     │                  │                     │                      │
     │                  │                     │   JWT 验证通过       │
     │                  │←───────── 资源 ─────────────────────────────│
     │←── 渲染页面 ─────│                     │                      │
```

## 五、生产环境最佳实践

### 5.1 JWT 配置要点

```yaml
# 推荐生产配置
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          # 使用 JWK Set URI（支持密钥轮转）
          jwk-set-uri: https://auth.example.com/.well-known/jwks.json
          # 配置可信的 issuer
          issuer-uri: https://auth.example.com
```

### 5.2 Token 缓存

Resource Server 每次请求都会去 JWKS URI 拉取公钥，会造成不必要的网络开销。建议配置缓存：

```java
@Bean
public JwtDecoder jwtDecoder() {
    // 使用 Spring Cache 包装 JWK Set 的拉取
    NimbusJwtDecoder decoder = NimbusJwtDecoder
        .withJwkSetUri("https://auth.example.com/.well-known/jwks.json")
        .cache(1000, Duration.ofMinutes(5))  // 缓存最多 1000 个密钥，5分钟过期
        .build();
    
    return decoder;
}
```

### 5.3 服务间令牌传递（Token Relay）

当请求链路过长时，下游服务也需要当前用户的认证信息。Spring Cloud Gateway + OAuth2 Client 可以实现自动传递：

```yaml
# Gateway 配置
spring:
  cloud:
    gateway:
      routes:
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - TokenRelay  # 自动传递 JWT 到下游服务
```

### 5.4 安全性增强

```java
@Configuration
public class SecurityEnhanceConfig {
    
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            // 限制 JWT 的 issuer
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt
                    .jwtAuthenticationConverter(jwtAuthenticationConverter())
                )
            )
            // 添加审计日志
            .addFilterAfter(new AuditFilter(), BearerTokenAuthenticationFilter.class);
        
        return http.build();
    }
}
```

## 六、面试常见追问

> **面试官：OAuth2 Client 和 Resource Server 的职责有什么区别？**

**答：** OAuth2 Client 负责"获取令牌"——它帮用户完成授权码流程，拿到 JWT 令牌，通常用在需要登录的 Web 应用中。Resource Server 负责"验证令牌"——它配置了 JWT 解码器，拦截 API 请求并验证令牌的签名、有效期、作用域，确保调用方有权限访问资源。简单说：**Client 是"入口"，Resource Server 是"检查站"**。

---

> **面试官：JWT 令牌的自动刷新是怎么做的？**

**答：** Spring Security 的 OAuth2 Client 默认支持 Token 刷新。当配置了 `refresh-token` grant type 并在 token 过期时，`OAuth2AuthorizedClientManager` 会自动使用 refresh token 换取新的 access token。对于 Resource Server 端，它不关心令牌刷新——它只验证当前令牌的有效性。获取和刷新令牌是 Client 端或 Authorization Server 的职责。

---

> **面试官：Resource Server 如何验证 JWT 的真实性？**

**答：** Resource Server 验证 JWT 的核心步骤：
1. **签名验证**：使用 JWKS 端点返回的公钥验证 JWT 的签名（RS256/ES256）
2. **有效期检查**：`exp` claim 确保令牌未过期，`nbf` claim 确保令牌已生效
3. **Issuer 检查**：`iss` claim 必须匹配配置的 `issuer-uri`
4. **Audience 检查**（可选）：`aud` claim 应包含当前服务名
5. **作用域检查**：`scope` 或 `authorities` claim 中包含的操作权限

这些都配置好，Resource Server 就不需要每次去 Authorization Server 查令牌状态了 —— JWT 是"自包含"的。

---

## 七、总结

| 组件 | 依赖 | 核心配置 | 典型应用 |
|-----|------|---------|---------|
| OAuth2 Client | `oauth2-client` | `registration.*` | 第三方登录、SSO |
| Resource Server | `resource-server` | `jwk-set-uri` | 微服务 API 保护 |
| 两者结合 | 同时引入 | 混合配置 | Gateway 转发 + 下游资源 |

Spring Boot 3.x 对 OAuth2 的支持已经非常成熟，配合 Spring Security 可以快速构建安全的生产级微服务。关键是理解 OAuth2 协议的角色划分：**Client 管登录、Authorization Server 管发令牌、Resource Server 管验令牌**。
