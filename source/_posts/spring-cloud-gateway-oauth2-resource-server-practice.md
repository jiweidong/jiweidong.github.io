---
title: 【Spring Cloud 实战】Spring Cloud Gateway 集成 OAuth2 资源服务器实战
date: 2026-07-24 08:00:00
tags:
  - Spring Cloud
  - Spring Security
  - OAuth2
  - 微服务
categories:
  - Spring Cloud
  - 认证授权
author: 东哥
---

# 【Spring Cloud 实战】Spring Cloud Gateway 集成 OAuth2 资源服务器实战

## 前言

在微服务架构中，API 网关是流量的统一入口，也是**认证鉴权的最佳拦截点**。将 OAuth2 资源服务器集成到网关层，可以让下游服务不再关心 Token 校验逻辑，真正做到认证逻辑的集中化。

但很多开发者在实践中会遇到一系列问题：

- 如何在 Gateway 层面统一校验 JWT Token？
- 如何将解析后的用户信息传递给下游微服务？
- Token 过期了是直接返回 401 还是走刷新流程？
- 哪些请求需要鉴权，哪些是公开的？
- Socket.IO / WebSocket 怎么携带 Token？

本文将从零开始，搭建一个基于 **Spring Cloud Gateway + Spring Authorization Server + Nacos** 的完整认证授权体系，并深入源码解析网关层鉴权的底层原理。

---

## 一、整体架构设计

### 1.1 架构图

```
                        ┌─────────────────┐
                        │  前端 (SPA/App)   │
                        └────────┬────────┘
                                 │ Bearer Token
                                 ▼
                  ┌──────────────────────────┐
                  │  Spring Cloud Gateway     │
                  │  (OAuth2 Resource Server) │
                  │  - Token 校验              │
                  │  - 角色/权限判断           │
                  │  - 用户信息传递             │
                  └────────┬─────────────────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
            ▼              ▼              ▼
      ┌──────────┐  ┌──────────┐  ┌──────────┐
      │ 订单服务  │  │ 用户服务  │  │ 商品服务  │
      │(无认证)   │  │(无认证)   │  │(无认证)   │
      └──────────┘  └──────────┘  └──────────┘
                           │
                    ┌──────┴──────┐
                    │ Authorization│
                    │  Server      │
                    │ (/oauth2/*)  │
                    └─────────────┘
```

### 1.2 技术栈

| 组件 | 技术选型 | 版本 |
|------|---------|------|
| 网关 | Spring Cloud Gateway | 2023.0.x |
| 资源服务器 | Spring Security OAuth2 Resource Server | 6.x |
| 授权服务器 | Spring Authorization Server | 1.x |
| 服务发现 | Nacos | 2.3.x |
| 密钥管理 | Nacos Config / 本地密钥对 | - |

---

## 二、授权服务器搭建

### 2.1 依赖配置

```xml
<!-- authorization-server/pom.xml -->
<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-security</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.security</groupId>
        <artifactId>spring-security-oauth2-authorization-server</artifactId>
        <version>1.3.0</version>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
        <groupId>com.nimbusds</groupId>
        <artifactId>nimbus-jose-jwt</artifactId>
    </dependency>
</dependencies>
```

### 2.2 授权服务器配置

```java
@Configuration
@EnableAuthorizationServer
public class AuthorizationServerConfig {
    
    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    public SecurityFilterChain authServerSecurityFilterChain(HttpSecurity http) throws Exception {
        OAuth2AuthorizationServerConfiguration.applyDefaultSecurity(http);
        
        http.getConfigurer(OAuth2AuthorizationServerConfigurer.class)
            .oidc(Customizer.withDefaults()); // 启用 OpenID Connect 1.0
        
        http.oauth2ResourceServer(oauth2 -> oauth2
            .jwt(Customizer.withDefaults()));
        
        return http.formLogin(Customizer.withDefaults()).build();
    }
    
    @Bean
    public RegisteredClientRepository registeredClientRepository() {
        RegisteredClient client = RegisteredClient.withId(UUID.randomUUID().toString())
            .clientId("gateway-client")
            .clientSecret("{noop}secret")
            .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
            .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
            .authorizationGrantType(AuthorizationGrantType.REFRESH_TOKEN)
            .authorizationGrantType(AuthorizationGrantType.CLIENT_CREDENTIALS)
            .redirectUri("http://localhost:8080/login/oauth2/code/gateway")
            .postLogoutRedirectUri("http://localhost:8080/")
            .scope("openid", "profile", "read", "write")
            .tokenSettings(TokenSettings.builder()
                .accessTokenTimeToLive(Duration.ofMinutes(30))
                .refreshTokenTimeToLive(Duration.ofDays(7))
                .reuseRefreshTokens(false)
                .build())
            .build();
        
        return new InMemoryRegisteredClientRepository(client);
    }
    
    @Bean
    public JWKSource<SecurityContext> jwkSource() {
        RSAKey rsaKey = Jwks.generateRsa();
        JWKSet jwkSet = new JWKSet(rsaKey);
        return (jwkSelector, securityContext) -> jwkSelector.select(jwkSet);
    }
    
    @Bean
    public ProviderSettings providerSettings() {
        return ProviderSettings.builder()
            .issuer("http://auth-server:9000")
            .build();
    }
}
```

### 2.3 RSA 密钥生成工具

```java
public final class Jwks {
    
    private Jwks() {}
    
    public static RSAKey generateRsa() {
        KeyPair keyPair = KeyGenerator.generateRsaKey();
        RSAPublicKey publicKey = (RSAPublicKey) keyPair.getPublic();
        RSAPrivateKey privateKey = (RSAPrivateKey) keyPair.getPrivate();
        
        return new RSAKey.Builder(publicKey)
            .privateKey(privateKey)
            .keyID(UUID.randomUUID().toString())
            .build();
    }
}

final class KeyGenerator {
    
    static KeyPair generateRsaKey() {
        KeyPairGenerator keyPairGenerator;
        try {
            keyPairGenerator = KeyPairGenerator.getInstance("RSA");
            keyPairGenerator.initialize(2048);
            return keyPairGenerator.generateKeyPair();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
```

```yaml
# application.yml
server:
  port: 9000

spring:
  application:
    name: authorization-server
```

---

## 三、网关层 OAuth2 资源服务器配置

### 3.1 依赖

```xml
<!-- gateway/pom.xml -->
<dependencies>
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-gateway</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
    </dependency>
    <dependency>
        <groupId>com.nimbusds</groupId>
        <artifactId>nimbus-jose-jwt</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-loadbalancer</artifactId>
    </dependency>
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
    </dependency>
</dependencies>
```

### 3.2 网关配置文件

```yaml
spring:
  application:
    name: api-gateway
  cloud:
    nacos:
      discovery:
        server-addr: ${NACOS_HOST:localhost}:8848
    
    gateway:
      routes:
        # 公开路由（无需认证）
        - id: auth-server-public
          uri: lb://authorization-server
          predicates:
            - Path=/oauth2/**, /.well-known/**, /login/**
          filters:
            - StripPrefix=0
        
        # 受保护路由（需要 JWT）
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/orders/**
          filters:
            - StripPrefix=1
            - name: AddTokenRelay
            - name: JwtClaimRelay
        
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - StripPrefix=1
            - name: AddTokenRelay
            - name: JwtClaimRelay

  security:
    oauth2:
      resourceserver:
        jwt:
          # 从授权服务器获取公钥
          issuer-uri: http://auth-server:9000
          # 或者直接指定 jwk-set-uri
          jwk-set-uri: http://auth-server:9000/oauth2/jwks

server:
  port: 8080
```

### 3.3 资源服务器安全配置

```java
@Configuration
@EnableWebFluxSecurity
public class ResourceServerConfig {
    
    @Bean
    public SecurityWebFilterChain securityWebFilterChain(ServerHttpSecurity http) {
        http
            .authorizeExchange(exchanges -> exchanges
                // 公开端点
                .pathMatchers(
                    "/oauth2/**", 
                    "/.well-known/**", 
                    "/login/**",
                    "/actuator/health",
                    "/api/public/**"
                ).permitAll()
                // 需要特定角色
                .pathMatchers("/api/admin/**").hasRole("ADMIN")
                // 其他所有请求需要认证
                .anyExchange().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt
                    .jwtAuthenticationConverter(jwtAuthenticationConverter())
                )
            )
            .csrf(ServerHttpSecurity.CsrfSpec::disable);
        
        return http.build();
    }
    
    /**
     * 自定义 JWT 认证转换器，提取 claims 到 Authentication
     */
    private ReactiveJwtAuthenticationConverter jwtAuthenticationConverter() {
        ReactiveJwtAuthenticationConverter converter = new ReactiveJwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(jwt -> {
            // 从 JWT 的 "roles" claim 中提取角色
            Object roles = jwt.getClaims().get("roles");
            if (roles instanceof Collection<?> roleList) {
                return Flux.fromIterable(roleList)
                    .map(role -> new SimpleGrantedAuthority("ROLE_" + role.toString()));
            }
            return Flux.empty();
        });
        return converter;
    }
}
```

### 3.4 用户信息传递过滤器

```java
/**
 * 将 JWT Claims 以 Header 方式传递给下游服务
 */
@Component
public class JwtClaimRelayFilter implements GlobalFilter, Ordered {
    
    private static final List<String> CLAIM_HEADERS = List.of(
        "X-User-Id",
        "X-User-Name",
        "X-User-Roles"
    );
    
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        return exchange.getPrincipal()
            .filter(principal -> principal instanceof JwtAuthenticationToken)
            .cast(JwtAuthenticationToken.class)
            .map(JwtAuthenticationToken::getToken)
            .flatMap(jwt -> {
                ServerHttpRequest request = exchange.getRequest().mutate()
                    .header("X-User-Id", jwt.getSubject())
                    .header("X-User-Name", jwt.getClaimAsString("preferred_username"))
                    .header("X-User-Roles", String.join(",", 
                        jwt.getClaimAsStringList("roles") != null 
                            ? jwt.getClaimAsStringList("roles") 
                            : List.of()))
                    .build();
                return chain.filter(exchange.mutate().request(request).build());
            })
            .switchIfEmpty(chain.filter(exchange));
    }
    
    @Override
    public int getOrder() {
        return Ordered.LOWEST_PRECEDENCE - 10;
    }
}
```

### 3.5 Token 中继过滤器

```java
/**
 * 将原始 Bearer Token 转发给下游服务
 */
@Component
public class AddTokenRelayGatewayFilterFactory 
        extends AbstractGatewayFilterFactory<Object> {
    
    public AddTokenRelayGatewayFilterFactory() {
        super(Object.class);
    }
    
    @Override
    public String name() {
        return "AddTokenRelay";
    }
    
    @Override
    public GatewayFilter apply(Object config) {
        return (exchange, chain) -> 
            exchange.getPrincipal()
                .filter(principal -> principal instanceof JwtAuthenticationToken)
                .cast(JwtAuthenticationToken.class)
                .map(token -> {
                    exchange.getRequest().mutate()
                        .header("Authorization", "Bearer " + token.getToken().getTokenValue());
                    return exchange;
                })
                .defaultIfEmpty(exchange)
                .flatMap(chain::filter);
    }
}
```

---

## 四、客户端集成与测试

### 4.1 前端 SPA 集成

```javascript
// 使用 OAuth2 PKCE 流程（推荐 SPA 使用）
import { createAuthClient } from '@openid/appauth';

const authClient = createAuthClient({
    authorizationEndpoint: 'http://localhost:9000/oauth2/authorize',
    tokenEndpoint: 'http://localhost:8080/oauth2/token',
    clientId: 'gateway-client',
    redirectUri: window.location.origin + '/callback',
    scope: 'openid profile read write',
    usePkce: true  // PKCE 增强授权码模式
});

// 获取 Token
async function login() {
    const token = await authClient.signIn();
    localStorage.setItem('access_token', token.accessToken);
}

// 调用 API
async function fetchOrders() {
    const token = localStorage.getItem('access_token');
    const response = await fetch('http://localhost:8080/api/orders', {
        headers: {
            'Authorization': `Bearer ${token}`
        }
    });
    return response.json();
}
```

### 4.2 下游服务接收用户信息

```java
@RestController
@RequestMapping("/orders")
public class OrderController {
    
    @GetMapping
    public Result<List<Order>> list(
            @RequestHeader("X-User-Id") String userId,
            @RequestHeader("X-User-Name") String userName,
            @RequestHeader("X-User-Roles") String roles) {
        // 直接使用网关传递的用户信息，无需再次解析 Token
        return Result.success(orderService.listByUserId(userId));
    }
}
```

或者使用 RequestInterceptor 统一提取：

```java
@Component
public class UserContextInterceptor implements HandlerInterceptor {
    
    @Override
    public boolean preHandle(HttpServletRequest request, 
                            HttpServletResponse response, 
                            Object handler) {
        String userId = request.getHeader("X-User-Id");
        String userName = request.getHeader("X-User-Name");
        String roles = request.getHeader("X-User-Roles");
        
        if (userId != null) {
            UserContextHolder.set(new UserContext(userId, userName, roles));
        }
        return true;
    }
    
    @Override
    public void afterCompletion(HttpServletRequest request,
                                HttpServletResponse response,
                                Object handler, Exception ex) {
        UserContextHolder.clear();
    }
}

// 线程安全的用户上下文
public class UserContextHolder {
    private static final ThreadLocal<UserContext> CONTEXT = new ThreadLocal<>();
    
    public static void set(UserContext ctx) { CONTEXT.set(ctx); }
    public static UserContext get() { return CONTEXT.get(); }
    public static void clear() { CONTEXT.remove(); }
}

public record UserContext(String userId, String userName, String roles) {}
```

---

## 五、高级配置与最佳实践

### 5.1 自定义 Token 解析（从 Nacos 获取公钥）

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          # 方式一：从授权服务器获取（推荐开发环境）
          issuer-uri: http://auth-server:9000
          
          # 方式二：直接指定 JWKS URI
          # jwk-set-uri: http://auth-server:9000/oauth2/jwks
          
          # 方式三：从 Nacos 配置读取公钥（生产环境推荐）
          # public-key-location: nacos://auth/jwt-public-key
```

通过代码配置：

```java
@Bean
public ReactiveJwtDecoder reactiveJwtDecoder() {
    NimbusReactiveJwtDecoder decoder = NimbusReactiveJwtDecoder
        .withJwkSetUri("http://auth-server:9000/oauth2/jwks")
        .jwsAlgorithm(SignatureAlgorithm.RS256)
        .build();
    return decoder;
}
```

### 5.2 Token 过期处理

```java
@Component
public class TokenExpirationFilter implements GlobalFilter, Ordered {
    
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        return exchange.getPrincipal()
            .filter(principal -> principal instanceof JwtAuthenticationToken)
            .cast(JwtAuthenticationToken.class)
            .flatMap(auth -> {
                Jwt jwt = auth.getToken();
                Instant expiresAt = jwt.getExpiresAt();
                if (expiresAt != null && Instant.now().isAfter(expiresAt)) {
                    // Token 已过期，返回 401
                    exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
                    return exchange.getResponse().setComplete();
                }
                return chain.filter(exchange);
            })
            .switchIfEmpty(chain.filter(exchange));
    }
    
    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE + 1;
    }
}
```

### 5.3 WebSocket 支持

```java
@Configuration
public class WebSocketAuthConfig {
    
    @Bean
    public WebSocketService webSocketService() {
        return (session, authentication) -> {
            // WebSocket 连接时的认证校验
            if (authentication instanceof JwtAuthenticationToken jwtAuth) {
                session.getAttributes().put("userId", jwtAuth.getToken().getSubject());
                return Mono.just(session);
            }
            return Mono.error(new AuthenticationException("Unauthorized"));
        };
    }
}

// 网关路由配置
spring:
  cloud:
    gateway:
      routes:
        - id: websocket-route
          uri: lb:ws://websocket-service
          predicates:
            - Path=/ws/**
          filters:
            - AddTokenRelay
```

---

## 六、面试高频问答

### Q1：网关鉴权 vs 各服务独立鉴权，怎么选？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 网关统一鉴权 | 集中管控，下游无感知 | 网关成为瓶颈 |
| 各服务独立鉴权 | 灵活，可局部定制 | 重复代码，管理分散 |
| 混合模式 | 网关负责 Token 校验，服务端负责业务权限 | 兼顾统一与灵活（推荐） |

**推荐策略**：网关做 Token 合法性校验和角色基础校验，细粒度权限交给各服务自己的 Spring Security 配置。

### Q2：JWT 的优缺点？

**优点**：无状态、跨语言、Payload 可携带信息

**缺点**：
- 无法主动吊销（除非黑名单或短 TTL）
- Payload 体积较大（Base64 编码膨胀约 33%）
- 密钥泄露风险大

### Q3：Token 刷新怎么做？

推荐使用 `refresh_token` grant type：

```
POST /oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=<refresh_token_value>
&client_id=gateway-client
&client_secret=secret
```

### Q4：如何实现动态路由 + OAuth2？

```java
@Component
public class DynamicRouteService {
    
    @Autowired
    private RouteDefinitionWriter routeDefinitionWriter;
    
    public Mono<Void> addRoute(RouteDefinition definition) {
        // 新增路由时，自动为受保护路由添加鉴权配置
        if (!definition.getPredicates().stream()
                .anyMatch(p -> p.getName().equals("AuthPublic"))) {
            // 该路由需要认证
        }
        return routeDefinitionWriter.save(Mono.just(definition));
    }
}
```

---

## 七、总结

本文完整演示了如何基于 Spring Cloud Gateway + OAuth2 Resource Server 构建微服务网关层的认证授权体系。核心要点：

1. **授权服务器负责签发 Token**，Gateway 负责校验 Token，各服务负责业务逻辑
2. 通过 **JWT Claims Relay** 将用户信息以 Header 方式传递给下游，避免重复解析
3. 使用 **PKCE 增强授权码模式**保障前端 SPA 的安全性
4. 灵活配置**公开路由与受保护路由**，并支持 Token 中继

这套架构在工业生产中得到广泛验证，能有效收敛认证逻辑、降低安全风险。下一篇文章我们将深入 Spring Cloud Gateway 如何与 Spring Authorization Server 实现动态权限控制。

---

*本文代码基于 Spring Boot 3.x / Spring Cloud 2023.0.x / Spring Authorization Server 1.3.x*
