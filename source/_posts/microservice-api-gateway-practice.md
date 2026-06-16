---
title: 微服务 API 网关选型与生产实践：Nginx / Kong / APISIX 对比
date: 2026-06-16 08:50:00
tags:
  - API网关
  - Nginx
  - Kong
  - APISIX
categories:
  - 微服务
author: 东哥
---

# 微服务 API 网关选型与生产实践

## 一、为什么需要 API 网关？

在微服务架构中，随着服务数量的增长，客户端直接调用每个服务会面临诸多问题：

| 问题 | 说明 |
|------|------|
| 客户端耦合 | 客户端需要知道所有服务的地址和协议 |
| 认证分散 | 每个服务都要实现一套认证逻辑 |
| 协议异构 | 不同服务使用 HTTP、gRPC、WebSocket 等不同协议 |
| 运维复杂 | 限流、熔断、日志分散在每个服务中 |

**API 网关**作为系统的统一入口，承担了路由、认证、限流、协议转换等职责，成为微服务架构的"大门"。

## 二、常见网关方案对比

| 特性 | Nginx + Lua | Kong | Apache APISIX | Spring Cloud Gateway |
|------|-------------|------|---------------|---------------------|
| 语言 | C + Lua | Lua (OpenResty) | Lua + Go Plugin | Java (Reactor) |
| 性能（QPS） | ~10万+ | ~3万 | ~5万 | ~2万 |
| 配置热更新 | 需 reload | Admin API | Admin API + ETCD | 需重启 |
| 插件生态 | 手动开发 | 丰富（150+） | 丰富（80+） | 较少 |
| K8s 支持 | 手动 | Ingress Controller | Ingress Controller | 手动 |
| 动态路由 | 有限 | ✅ 支持 | ✅ 极佳 | ✅ 支持 |
| 学习成本 | 高 | 中 | 中 | 低（Spring 团队） |

### 选型建议

- **团队 Java 为主、网关逻辑简单** → Spring Cloud Gateway
- **需要高性能、丰富插件** → APISIX（国产开源，社区活跃）
- **已经在用 OpenResty / 偏运维** → Kong（成熟稳定）
- **极致性能、自定义程度高** → Nginx + Lua 手写

## 三、Apache APISIX 生产级部署

APISIX 是目前性能最强、活跃度最高的国产 API 网关之一。

### 3.1 Docker Compose 部署

```yaml
version: "3.8"
services:
  etcd:
    image: bitnami/etcd:3.5
    environment:
      ETCD_ENABLE_V2: "true"
      ALLOW_NONE_AUTHENTICATION: "yes"
      ETCD_ADVERTISE_CLIENT_URLS: "http://etcd:2379"
    ports:
      - "2379:2379"

  apisix:
    image: apache/apisix:3.9.0
    depends_on:
      - etcd
    volumes:
      - ./apisix_conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
    ports:
      - "9080:9080"
      - "9180:9180"
    restart: always
```

### 3.2 核心配置

```yaml
# config.yaml
apisix:
  node_listen:
    - port: 9080        # 数据面端口
  enable_admin: true
  enable_debug: false

deployment:
  role: traditional     # 传统模式
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "http://etcd:2379"
    prefix: "/apisix"
```

### 3.3 动态路由配置

通过 Admin API 动态创建路由：

```bash
# 创建路由 → 转发到 user-service
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" -X PUT -d '{
    "uri": "/api/users/*",
    "upstream": {
      "type": "roundrobin",
      "scheme": "http",
      "nodes": {
        "user-service:8080": 1
      }
    },
    "plugins": {
      "limit-count": {
        "count": 100,
        "time_window": 60,
        "rejected_code": 429
      },
      "jwt-auth": {}
    }
  }'
```

## 四、Spring Cloud Gateway 实战

如果你的技术栈是 Java/Spring，SCG 是集成度最高的选择。

### 4.1 路由配置

```yaml
# application.yml
spring:
  cloud:
    gateway:
      routes:
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - StripPrefix=1
            - name: RequestRateLimiter
              args:
                key-resolver: "#{@userKeyResolver}"
                redis-rate-limiter.replenishRate: 100
                redis-rate-limiter.burstCapacity: 200

        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/orders/**
          filters:
            - StripPrefix=1
            - name: CircuitBreaker
              args:
                name: orderCircuitBreaker
                fallbackUri: forward:/fallback/orders

        - id: websocket-route
          uri: ws://ws-service:8080
          predicates:
            - Path=/ws/**
```

### 4.2 全局过滤器实现认证

```java
@Component
public class JwtAuthenticationFilter implements GlobalFilter, Ordered {

    private final JwtUtil jwtUtil;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();

        // 白名单不校验
        String path = request.getURI().getPath();
        if (isWhitelist(path)) {
            return chain.filter(exchange);
        }

        // 提取 Token
        String authHeader = request.getHeaders().getFirst(HttpHeaders.AUTHORIZATION);
        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            return unauthorized(exchange, "Missing or invalid Authorization header");
        }

        try {
            String token = authHeader.substring(7);
            Claims claims = jwtUtil.parseToken(token);
            String userId = claims.getSubject();
            String role = claims.get("role", String.class);

            // 把用户信息传到下游
            ServerHttpRequest modifiedRequest = request.mutate()
                .header("X-User-Id", userId)
                .header("X-User-Role", role)
                .build();
            return chain.filter(exchange.mutate().request(modifiedRequest).build());

        } catch (ExpiredJwtException e) {
            return unauthorized(exchange, "Token expired");
        } catch (JwtException e) {
            return unauthorized(exchange, "Invalid token");
        }
    }

    private boolean isWhitelist(String path) {
        return path.startsWith("/api/auth/login") ||
               path.startsWith("/api/auth/register") ||
               path.startsWith("/actuator/health");
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange, String msg) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        return exchange.getResponse().writeWith(
            Mono.just(exchange.getResponse().bufferFactory()
                .wrap(("{\"code\":401,\"msg\":\"" + msg + "\"}").getBytes())));
    }

    @Override
    public int getOrder() {
        return -100; // 高优先级
    }
}
```

### 4.3 限流最佳实践

```java
@Bean
public KeyResolver userKeyResolver() {
    return exchange -> {
        // 按用户 ID 限流
        String userId = exchange.getRequest().getHeaders()
            .getFirst("X-User-Id");
        if (userId == null) {
            userId = exchange.getRequest().getRemoteAddress().getAddress().getHostAddress();
        }
        return Mono.just(userId);
    };
}
```

## 五、Kong 网关生态

Kong 是最成熟的云原生 API 网关之一，插件生态极其丰富。

### 5.1 核心插件速查

| 插件 | 功能 | 典型场景 |
|------|------|----------|
| Key-Auth / JWT / OAuth2 | 认证 | 接口鉴权 |
| Rate-Limiting | 限流 | 防刷 |
| IP-Restriction | IP 白名单 | 内网 API |
| Proxy-Cache | 缓存 | 缓存静态数据 |
| Prometheus | 指标暴露 | 对接监控系统 |
| File-Log / HTTP-Log | 日志 | 审计日志 |

### 5.2 服务+路由配置

```bash
# 添加 upstream 服务
curl -X POST http://localhost:8001/services \
  --data "name=payment-service" \
  --data "url=http://payment.internal:8080"

# 添加路由
curl -X POST http://localhost:8001/services/payment-service/routes \
  --data "paths[]=/api/payments" \
  --data "methods[]=GET" \
  --data "methods[]=POST"

# 启用限流插件
curl -X POST http://localhost:8001/services/payment-service/plugins \
  --data "name=rate-limiting" \
  --data "config.minute=100" \
  --data "config.policy=local"

# 启用 JWT 认证
curl -X POST http://localhost:8001/services/payment-service/plugins \
  --data "name=jwt"
```

## 六、网关部署高可用方案

### 6.1 多节点部署

```
                    +----------+
                    |   DNS     |
                    |  Round    |
                    |  Robin    |
                    +-----+----+
                          |
            +-------------+-------------+
            |             |             |
      +-----v-----+ +----v------+ +----v------+
      |   Nginx   | |   Nginx   | |   Nginx   |
      |   LB      | |   LB      | |   LB      |
      +-----------+ +-----------+ +-----------+
            |             |             |
      +-----v-----+ +----v------+ +----v------+
      |  APISIX-1 | |  APISIX-2 | |  APISIX-3 |
      +-----------+ +-----------+ +-----------+
            |             |             |
      +-----v-----+ +----v------+ +----v------+
      |   Service  | |   Service  | |   Service  |
      |   Mesh     | |   Mesh     | |   Mesh     |
      +-----------+ +-----------+ +-----------+
```

### 6.2 健康检查与自动摘除

```yaml
# 在 upstream 中配置健康检查
upstream:
  nodes:
    "10.0.1.10:8080": 1
    "10.0.1.11:8080": 1
  health_check:
    active:
      http_path: /actuator/health
      healthy:
        interval: 5
        successes: 2
      unhealthy:
        interval: 3
        http_failures: 3
      type: http
    passive:
      unhealthy:
        http_failures: 5
        timeout: 5
```

## 七、性能优化最佳实践

### 7.1 关键参数调优

| 参数 | Nginx 建议值 | APISIX 建议值 | 说明 |
|------|-------------|---------------|------|
| worker_processes | auto | auto | 与 CPU 核数一致 |
| worker_connections | 65536 | 65536 | 连接数上限 |
| proxy_buffer_size | 8k | 8k | 响应头缓冲区 |
| proxy_buffers | 8 16k | 8 16k | 响应体缓冲区 |
| keepalive_timeout | 65 | 65 | 长连接超时 |

### 7.2 减少不必要的序列化

```java
// ❌ 不推荐：字符串拼接 + 二次序列化
String json = "{\"code\":200,\"data\":...}";
return Mono.just(json).map(s -> exchange.getResponse()
    .bufferFactory().wrap(s.getBytes()));

// ✅ 推荐：直接返回字节，避免序列化开销
return exchange.getResponse()
    .writeWith(Mono.just(exchange.getResponse()
        .bufferFactory().wrap(byteData)));
```

## 八、总结

API 网关是微服务架构中的重要组件，选型时需综合考虑：

1. **性能需求**：高并发场景优先 APISIX / Nginx
2. **团队技术栈**：Java 团队推荐 Spring Cloud Gateway
3. **生态需求**：丰富插件选 Kong / APISIX
4. **运维复杂度**：APISIX 和 Kong 都有 Admin API 和 Dashboard

无论选择哪种方案，网关层都应只处理**跨横切关注点**（认证、限流、路由），不要在其中写业务逻辑。
