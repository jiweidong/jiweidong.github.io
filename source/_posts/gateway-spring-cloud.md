---
title: Spring Cloud Gateway 微服务网关深度实践
date: 2026-06-15 23:30:00
tags:
  - Spring Cloud
  - Gateway
  - 微服务
  - 网关
categories:
  - 架构
author: 东哥
---

# Spring Cloud Gateway 微服务网关深度实践

> 网关是微服务架构的流量入口，承担着路由、鉴权、限流、日志等核心职责。本文全面解析 Spring Cloud Gateway 的核心概念和高阶用法。

## 一、为什么需要 API 网关

### 1.1 网关的职责

```
                      ┌─→ 用户服务 ─→ 数据库
客户端 ──→ [Gateway] ─┼─→ 订单服务 ─→ 数据库
                      └─→ 商品服务 ─→ 数据库
```

| 功能 | 说明 | 传统实现 |
|------|------|----------|
| 路由转发 | URL → 微服务 | Nginx 配置 |
| 统一鉴权 | JWT/OAuth2 验证 | 各服务重复实现 |
| 限流熔断 | 保护后端服务 | 接入 Sentinel |
| 日志监控 | 请求日志全链路 | 日志中间件 |
| 协议转换 | HTTP → Dubbo | 额外适配层 |
| 灰度发布 | 流量按比例分发 | 负载均衡策略 |
| 跨域处理 | CORS 统一配置 | 各服务配置 |
| 请求聚合 | 合并多个后端请求 | BFF 层 |

### 1.2 Gateway vs Zuul

| 特性 | Spring Cloud Gateway | Zuul 1.x |
|------|---------------------|----------|
| 底层 | WebFlux (Netty) | Servlet (Tomcat) |
| 性能 | 高（非阻塞） | 低（阻塞 IO） |
| 异步 | 原生支持 | 不支持 |
| WebSocket | 支持 | 不支持 |
| 长连接 | 支持 | 有限 |
| 依赖 | Spring Boot 2.x+ | Spring Boot 1.x |

## 二、快速入门

### 2.1 Maven 依赖

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-gateway</artifactId>
</dependency>
```

### 2.2 基础路由配置

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/user/**
          filters:
            - StripPrefix=1

        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/order/**
            - Method=GET,POST
          filters:
            - StripPrefix=1
            - name: RequestRateLimiter
              args:
                key-resolver: "#{@userKeyResolver}"
                redis-rate-limiter:
                  replenishRate: 100
                  burstCapacity: 200
```

## 三、断言工厂

### 3.1 内置断言

```yaml
# 路径匹配
predicates:
  - Path=/api/**,/admin/**

# 方法匹配
  - Method=GET,POST,PUT,DELETE

# Header 匹配
  - Header=X-Request-Id, \d+

# Query 参数
  - Query=status, active|pending

# Cookie
  - Cookie=sessionId, .*

# 时间路由
  - Before=2026-12-31T23:59:59+08:00
  - After=2026-01-01T00:00:00+08:00
  - Between=2026-01-01, 2026-12-31

# 权重路由（灰度发布）
  - Weight=user-service, 90
  - Weight=user-service-v2, 10

# 远程地址
  - RemoteAddr=10.0.0.0/24
```

### 3.2 自定义断言

```java
@Component
public class AuthHeaderRoutePredicateFactory 
        extends AbstractRoutePredicateFactory<Config> {

    public AuthHeaderRoutePredicateFactory() {
        super(Config.class);
    }

    @Override
    public Predicate<ServerWebExchange> apply(Config config) {
        return exchange -> {
            String token = exchange.getRequest()
                .getHeaders().getFirst("Authorization");
            if (token == null || !token.startsWith("Bearer ")) {
                return false;  // 无 Token 直接拒绝
            }
            
            // 验证 Token 有效性
            String jwt = token.substring(7);
            return JwtUtils.validateToken(jwt);
        };
    }

    @Data
    public static class Config {
        private String requiredRole;
    }
}
```

## 四、过滤器工厂

### 4.1 内置过滤器

```yaml
filters:
  # 请求头操作
  - AddRequestHeader=X-Gateway, my-gateway
  - AddRequestParameter=source, app
  - RemoveRequestHeader=Cookie

  # 响应头操作
  - AddResponseHeader=X-Response-Time, ${timestamp}
  - RemoveResponseHeader=X-Powered-By

  # 路径重写
  - StripPrefix=1           # /api/user/1 → /user/1
  - PrefixPath=/api        # /user/1 → /api/user/1
  - RewritePath=/api/(?<segment>.*), /$\{segment}

  # 重定向
  - RedirectTo=302, https://new.example.com

  # 重试
  - name: Retry
    args:
      retries: 3
      statuses: BAD_GATEWAY, SERVICE_UNAVAILABLE
      methods: GET
```

### 4.2 自定义全局过滤器

```java
@Component
@Order(-1)
public class RequestLoggingFilter implements GlobalFilter {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, 
                             GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();
        String path = request.getURI().getPath();
        String method = request.getMethod().name();
        long startTime = System.currentTimeMillis();

        return chain.filter(exchange).then(Mono.fromRunnable(() -> {
            long elapsed = System.currentTimeMillis() - startTime;
            int status = exchange.getResponse().getStatusCode().value();
            log.info("[Gateway] {} {} → {} ({}ms)", 
                method, path, status, elapsed);
        }));
    }
}
```

### 4.3 鉴权过滤器

```java
@Component
public class AuthGlobalFilter implements GlobalFilter, Ordered {

    @Override
    public int getOrder() {
        return -100;  // 高优先级
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, 
                             GatewayFilterChain chain) {
        String path = exchange.getRequest().getURI().getPath();

        // 白名单路径跳过鉴权
        if (path.startsWith("/api/auth/login") || 
            path.startsWith("/api/auth/register")) {
            return chain.filter(exchange);
        }

        // 获取 Token
        String token = exchange.getRequest()
            .getHeaders().getFirst("Authorization");
        if (token == null || !token.startsWith("Bearer ")) {
            return unauthorized(exchange, "缺少 Token");
        }

        try {
            // 解析 Token
            Claims claims = JwtUtils.parseToken(token.substring(7));
            
            // 将用户信息放入请求头（传递给下游服务）
            ServerHttpRequest mutatedRequest = 
                exchange.getRequest().mutate()
                    .header("X-User-Id", claims.get("userId").toString())
                    .header("X-User-Name", claims.get("userName").toString())
                    .build();

            ServerWebExchange mutatedExchange = 
                exchange.mutate().request(mutatedRequest).build();

            return chain.filter(mutatedExchange);

        } catch (JwtException e) {
            return unauthorized(exchange, "Token 无效或已过期");
        }
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange, 
                                     String message) {
        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(HttpStatus.UNAUTHORIZED);
        response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        
        Map<String, Object> body = new HashMap<>();
        body.put("code", 401);
        body.put("message", message);
        
        DataBuffer buffer = response.bufferFactory()
            .wrap(JSON.toJSONString(body).getBytes());
        return response.writeWith(Mono.just(buffer));
    }
}
```

## 五、限流实现

### 5.1 RequestRateLimiter

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/order/**
          filters:
            - name: RequestRateLimiter
              args:
                key-resolver: "#{@ipKeyResolver}"
                redis-rate-limiter:
                  replenishRate: 10   # 令牌填充速率
                  burstCapacity: 20    # 令牌桶容量
                  requestedTokens: 1   # 每次请求消耗令牌数

# 自定义 Key Resolver
@Bean
public KeyResolver ipKeyResolver() {
    return exchange -> {
        String ip = exchange.getRequest()
            .getRemoteAddress().getAddress().getHostAddress();
        return Mono.just(ip);
    };
}

@Bean
public KeyResolver userKeyResolver() {
    return exchange -> Mono.justOrEmpty(
        exchange.getRequest()
            .getHeaders().getFirst("X-User-Id"))
        .defaultIfEmpty("anonymous");
}
```

## 六、跨域配置

```yaml
spring:
  cloud:
    gateway:
      globalcors:
        cors-configurations:
          '[/**]':
            allowedOrigins:
              - "https://admin.example.com"
              - "https://www.example.com"
            allowedMethods:
              - GET
              - POST
              - PUT
              - DELETE
            allowedHeaders: "*"
            allowCredentials: true
            maxAge: 3600
```

## 七、网关高可用

### 7.1 超时配置

```yaml
spring:
  cloud:
    gateway:
      httpclient:
        connect-timeout: 5000      # 连接超时 5s
        response-timeout: 30s      # 响应超时 30s
        pool:
          max-connections: 1000    # 连接池最大连接数
          acquire-timeout: 5000    # 获取连接超时

      # 熔断降级
      default-filters:
        - name: CircuitBreaker
          args:
            name: defaultCircuitBreaker
            fallbackUri: forward:/fallback
```

### 7.2 灰度发布配置

```yaml
spring:
  cloud:
    gateway:
      routes:
        # 旧版本（90% 流量）
        - id: user-service-v1
          uri: lb://user-service-v1
          predicates:
            - Path=/api/user/**
            - Weight=user-service, 90
          filters:
            - StripPrefix=1

        # 新版本（10% 流量）
        - id: user-service-v2
          uri: lb://user-service-v2
          predicates:
            - Path=/api/user/**
            - Weight=user-service, 10
          filters:
            - StripPrefix=1
```

### 7.3 网关熔断

```java
@Bean
public Customizer<ReactiveResilience4JCircuitBreakerFactory> 
        defaultCustomizer() {
    return factory -> factory.configureDefault(id -> new Resilience4JConfigBuilder(id)
        .circuitBreakerConfig(CircuitBreakerConfig.custom()
            .slidingWindowSize(10)
            .minimumNumberOfCalls(5)
            .failureRateThreshold(50)
            .waitDurationInOpenState(Duration.ofSeconds(30))
            .permittedNumberOfCallsInHalfOpenState(3)
            .build())
        .timeLimiterConfig(TimeLimiterConfig.custom()
            .timeoutDuration(Duration.ofSeconds(5))
            .build())
        .build());
}
```

## 八、生产最佳实践

### 8.1 性能优化

```yaml
# 1. 使用 WebClient 替代 RestTemplate
# Gateway 默认使用 WebClient（非阻塞）

# 2. 禁用不必要的过滤器
spring.cloud.gateway:
  default-filters:
    - name: RemoveResponseHeader
      args:
        name: Server

# 3. 调整 Netty 参数
server:
  netty:
    connection-timeout: 5000
server.reactive.netty:
  worker-count: 16   # Netty Worker 线程数

# 4. 启用数据压缩
server.netty.compression:
  enabled: true
  mime-types: text/html,text/xml,text/plain,application/json
```

### 8.2 监控集成

```yaml
# 集成 Prometheus
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
  metrics:
    tags:
      application: ${spring.application.name}

# Gateway 暴露的指标
# gateway.requests: 请求计数
# gateway.request.time: 请求耗时
# gateway.requests.rate: 请求速率
```

## 九、总结

Spring Cloud Gateway 作为微服务网关的核心组件，提供了丰富的路由、过滤器、限流和熔断能力。核心要点：

1. **非阻塞架构**：基于 WebFlux 和 Netty，性能优于传统 Servlet 网关
2. **声明式路由**：通过 YAML 配置即可完成复杂的路由规则
3. **过滤器链**：灵活的自定义扩展机制
4. **生态整合**：与 Sentinel、Resilience4J 等组件无缝对接

生产环境建议结合 Nacos 实现路由的动态刷新，配合 Prometheus 监控网关指标。
