---
title: 【微服务实战】Spring Cloud Gateway 自定义过滤器与谓词工厂高级实战：从 SPI 到动态路由
date: 2026-07-08 08:00:00
tags:
  - Spring Cloud
  - Gateway
  - 微服务
  - 过滤器
categories:
  - Java
  - Spring Cloud
author: 东哥
---

# 【微服务实战】Spring Cloud Gateway 自定义过滤器与谓词工厂高级实战：从 SPI 到动态路由

## 前言

Spring Cloud Gateway 作为微服务网关的标配，其核心能力来自两大组件：**Predicate（谓词）** 和 **Filter（过滤器）**。虽然内置了 11 种谓词工厂和 30+ 种过滤器，但在生产环境中，我们几乎**必定需要自定义**——比如：自定义鉴权逻辑、灰度发布规则、动态路由、请求加密解密、参数校验签名等。

本文将从源码角度深入剖析 Gateway 的扩展机制，并通过 4 个实战案例，带你彻底掌握自定义开发。

---

## 一、Gateway 核心架构回顾

### 1.1 请求处理流程

```
客户端请求
    ↓
RoutePredicateHandlerMapping (匹配路由)
    ↓
FilteringWebHandler (构建过滤器链)
    ↓
前置过滤器链 (pre filters) → 代理请求 → 后置过滤器链 (post filters)
    ↓
响应返回
```

### 1.2 三大核心抽象

```java
// 路由：包含 ID、谓词列表、过滤器列表、URI
public class Route {
    private final String id;
    private final URI uri;
    private final int order;
    private final AsyncPredicate<ServerWebExchange> predicate;
    private final List<GatewayFilter> gatewayFilters;
    private final Map<String, Object> metadata;
}

// 谓词工厂：匹配请求条件
public interface RoutePredicateFactory<C> extends ShortcutConfigurable, Configurable<C> {
    String NAME_KEY = "name";
    String ARGS_KEY = "args";
    
    default AsyncPredicate<ServerWebExchange> applyAsync(Consumer<C> consumer) {
        C config = newConfig();
        consumer.accept(config);
        return applyAsync(config);
    }
    
    AsyncPredicate<ServerWebExchange> applyAsync(C config);
}

// 网关过滤器：在请求前后执行逻辑
public interface GatewayFilter {
    String NAME_KEY = "name";
    
    Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain);
}
```

---

## 二、自定义 GatewayFilter：第一个实战

### 2.1 场景：请求耗时统计过滤器

```java
/**
 * 自定义过滤器：统计每个请求的处理耗时，并写入日志和响应头
 */
@Component
@Slf4j
public class ElapsedGatewayFilter implements GatewayFilter, Ordered {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        long startTime = System.currentTimeMillis();
        String requestId = exchange.getRequest().getId();

        return chain.filter(exchange).then(Mono.fromRunnable(() -> {
            long elapsed = System.currentTimeMillis() - startTime;
            exchange.getResponse().getHeaders().add("X-Elapsed-Time", elapsed + "ms");
            log.info("[{}] {} {} -> {} ms",
                    requestId,
                    exchange.getRequest().getMethod(),
                    exchange.getRequest().getURI().getPath(),
                    elapsed
            );
        }));
    }

    @Override
    public int getOrder() {
        return 0; // 优先级最高
    }
}
```

使用方式（application.yml）：

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
            - name: Elapsed  # 使用自定义过滤器（类名去掉 GatewayFilter 后缀）
```

**问题**：这种方式 `@Component` 注册会**全局生效**，所有路由都会执行。如何只让特定路由使用？

### 2.2 解决方案：GatewayFilterFactory

```java
/**
 * 可配置的过滤器工厂，支持参数传递
 */
@Component
public class ElapsedGatewayFilterFactory
        extends AbstractGatewayFilterFactory<ElapsedGatewayFilterFactory.Config> {

    public ElapsedGatewayFilterFactory() {
        super(Config.class);
    }

    @Override
    public GatewayFilter apply(Config config) {
        return (exchange, chain) -> {
            long startTime = System.currentTimeMillis();
            String requestId = exchange.getRequest().getId();

            return chain.filter(exchange).then(Mono.fromRunnable(() -> {
                long elapsed = System.currentTimeMillis() - startTime;
                if (config.isEnabled()) {
                    exchange.getResponse().getHeaders().add("X-Elapsed-Time", elapsed + "ms");
                }
                if (elapsed > config.getThresholdMs()) {
                    log.warn("[SLOW] [{}] {} {} -> {} ms (threshold: {} ms)",
                            requestId,
                            exchange.getRequest().getMethod(),
                            exchange.getRequest().getURI().getPath(),
                            elapsed, config.getThresholdMs());
                } else {
                    log.info("[{}] {} {} -> {} ms",
                            requestId, exchange.getRequest().getMethod(),
                            exchange.getRequest().getURI().getPath(), elapsed);
                }
            }));
        };
    }

    @Data
    public static class Config {
        private boolean enabled = true;
        private long thresholdMs = 1000; // 慢请求阈值
    }
}
```

**YAML 配置**：

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
            - name: Elapsed
              args:
                enabled: true
                thresholdMs: 500
```

---

## 三、自定义谓词工厂

### 3.1 场景：基于请求参数的灰度发布

```java
/**
 * 灰度发布谓词：根据 Header 中的 version 参数，将请求路由到不同版本
 * 如果 Header 中有 X-Version=v2，且配置了 version=v2，则匹配
 */
@Component
public class VersionRoutePredicateFactory
        extends AbstractRoutePredicateFactory<VersionRoutePredicateFactory.Config> {

    public VersionRoutePredicateFactory() {
        super(Config.class);
    }

    @Override
    public Predicate<ServerWebExchange> apply(Config config) {
        return exchange -> {
            String version = exchange.getRequest().getHeaders()
                    .getFirst("X-Version");
            if (StringUtils.isEmpty(version)) {
                return config.isMatchEmpty(); // 未传版本时是否匹配
            }
            return config.getValues().contains(version);
        };
    }

    @Override
    public ShortcutType shortcutType() {
        return ShortcutType.GATHER_LIST; // 支持列表类型参数
    }

    @Data
    public static class Config {
        private List<String> values = new ArrayList<>();
        private boolean matchEmpty = false;
    }
}
```

**YAML 配置**：

```yaml
- id: user-service-v2
  uri: lb://user-service-v2
  predicates:
    - Path=/api/user/**
    - name: Version
      args:
        values: v2,v2.1
        matchEmpty: false
  filters:
    - StripPrefix=1

- id: user-service-default
  uri: lb://user-service-default
  predicates:
    - Path=/api/user/**
    - name: Version
      args:
        values: v1
        matchEmpty: true  # 默认走稳定版
```

### 3.2 谓词工厂的短路类型（ShortcutType）

| 类型 | 说明 | 示例 |
|------|------|------|
| `DEFAULT` | 默认，key-value 对 | `key1=value1,key2=value2` |
| `GATHER_LIST` | 收集为列表 | `values=v1,v2,v3` |
| `GATHER_LIST_TAIL_FLAG` | 列表，末尾标记 | `header=v,t/v1,v2,v3` |

---

## 四、SPI 机制与自动注册

### 4.1 Gateway 的自发现机制

你可能好奇：为什么自定义的 `GatewayFilterFactory` 和 `RoutePredicateFactory` 不需要手动注册？

**答案：Spring Cloud Gateway 使用了 Spring Boot 的自动配置 + 自定义 SPI 扫描。**

核心代码在 `GatewayAutoConfiguration` 中：

```java
@Bean
@ConditionalOnMissingBean
public RoutePredicateFactory<?> versionRoutePredicateFactory() {
    // 如果自定义的工厂标注了 @Component，会自动注册
    return new VersionRoutePredicateFactory();
}
```

但更优雅的方式是使用 `GatewayFilterFactory` 的命名约定：

```
类名:    ElapsedGatewayFilterFactory
Bean名:  elapsedGatewayFilterFactory
配置名:  Elapsed  (去掉 GatewayFilterFactory 后缀)
```

Spring Cloud Gateway 在初始化时，会扫描所有 `AbstractGatewayFilterFactory` 和 `AbstractRoutePredicateFactory` 的子类，自动注册并建立名称映射。

### 4.2 手动注册（不使用 @Component）

```java
@Configuration
public class GatewayConfig {

    @Bean
    public ElapsedGatewayFilterFactory elapsedGatewayFilterFactory() {
        return new ElapsedGatewayFilterFactory();
    }

    @Bean
    public VersionRoutePredicateFactory versionRoutePredicateFactory() {
        return new VersionRoutePredicateFactory();
    }

    @Bean
    public AuthGatewayFilterFactory authGatewayFilterFactory() {
        return new AuthGatewayFilterFactory();
    }
}
```

---

## 五、高级实战：动态路由

### 5.1 场景：基于数据库的动态路由配置

内置的路由配置是静态的（写在 yml 中），生产环境中路由信息通常存储在 **Nacos / Apollo / MySQL** 中，需要支持动态刷新。

```java
@Component
@Slf4j
public class DynamicRouteService implements ApplicationEventPublisherAware {

    private final RouteDefinitionWriter routeDefinitionWriter;
    private ApplicationEventPublisher publisher;

    public DynamicRouteService(RouteDefinitionWriter routeDefinitionWriter) {
        this.routeDefinitionWriter = routeDefinitionWriter;
    }

    @Override
    public void setApplicationEventPublisher(ApplicationEventPublisher publisher) {
        this.publisher = publisher;
    }

    /**
     * 增加路由
     */
    public Mono<Void> add(RouteDefinition definition) {
        return routeDefinitionWriter.save(Mono.just(definition))
                .then(Mono.defer(() -> {
                    publisher.publishEvent(new RefreshRoutesEvent(this));
                    log.info("动态路由已添加: {}", definition.getId());
                    return Mono.empty();
                }));
    }

    /**
     * 更新路由
     */
    public Mono<Void> update(RouteDefinition definition) {
        return routeDefinitionWriter.delete(Mono.just(definition.getId()))
                .then(routeDefinitionWriter.save(Mono.just(definition)))
                .then(Mono.defer(() -> {
                    publisher.publishEvent(new RefreshRoutesEvent(this));
                    log.info("动态路由已更新: {}", definition.getId());
                    return Mono.empty();
                }));
    }

    /**
     * 删除路由
     */
    public Mono<Void> delete(String routeId) {
        return routeDefinitionWriter.delete(Mono.just(routeId))
                .then(Mono.defer(() -> {
                    publisher.publishEvent(new RefreshRoutesEvent(this));
                    log.info("动态路由已删除: {}", routeId);
                    return Mono.empty();
                }));
    }
}
```

**配合 Nacos 实现配置中心动态路由**：

```java
@Component
@Slf4j
public class NacosDynamicRouteListener {

    @Resource
    private DynamicRouteService dynamicRouteService;

    @PostConstruct
    public void init() {
        String dataId = "gateway-routes.json";
        String group = "DEFAULT_GROUP";

        // 添加 Nacos 配置监听
        ConfigService configService = NacosFactory.createConfigService("localhost:8848");
        configService.addListener(dataId, group, new Listener() {
            @Override
            public Executor getExecutor() {
                return Executors.newSingleThreadExecutor();
            }

            @Override
            public void receiveConfigInfo(String configInfo) {
                log.info("路由配置变更: {}", configInfo);
                List<RouteDefinition> routes = JSON.parseArray(configInfo, RouteDefinition.class);
                // 清空旧路由，批量加载新路由
                for (RouteDefinition route : routes) {
                    dynamicRouteService.add(route).subscribe();
                }
            }
        });
    }
}
```

---

## 六、全局过滤器实战

### 6.1 场景：统一请求签名验证

```java
/**
 * 全局过滤器：对所有请求进行签名验证
 */
@Component
@Order(-1) // 优先级最高
@Slf4j
public class SignatureGlobalFilter implements GlobalFilter {

    private static final String SIGN_HEADER = "X-Sign";
    private static final String TIMESTAMP_HEADER = "X-Timestamp";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();
        String path = request.getURI().getPath();

        // 跳过不需要签名的路径
        if (path.startsWith("/api/public/") || path.equals("/api/login")) {
            return chain.filter(exchange);
        }

        String sign = request.getHeaders().getFirst(SIGN_HEADER);
        String timestamp = request.getHeaders().getFirst(TIMESTAMP_HEADER);

        // 参数校验
        if (StringUtils.isEmpty(sign) || StringUtils.isEmpty(timestamp)) {
            return unauthorized(exchange, "缺少签名参数");
        }

        // 时间戳防重放（允许 5 分钟误差）
        long ts = Long.parseLong(timestamp);
        if (Math.abs(System.currentTimeMillis() - ts) > 5 * 60 * 1000) {
            return unauthorized(exchange, "签名已过期");
        }

        // 签名验证逻辑
        String body = resolveBodyFromRequest(exchange);
        String expectedSign = generateSign(body, timestamp, getSecretKey());

        if (!expectedSign.equals(sign)) {
            log.warn("签名验证失败: expected={}, actual={}, path={}", expectedSign, sign, path);
            return unauthorized(exchange, "签名验证失败");
        }

        return chain.filter(exchange);
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange, String msg) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        exchange.getResponse().getHeaders().setContentType(MediaType.APPLICATION_JSON);
        byte[] body = ("{\"code\":401,\"msg\":\"" + msg + "\"}").getBytes(StandardCharsets.UTF_8);
        return exchange.getResponse().writeWith(Mono.just(exchange.getResponse()
                .bufferFactory().wrap(body)));
    }
}
```

### 6.2 全局过滤器 vs 路由过滤器对比

| 对比维度 | 全局过滤器 (GlobalFilter) | 路由过滤器 (GatewayFilter) |
|----------|--------------------------|--------------------------|
| 作用范围 | 所有路由 | 指定路由 |
| 自动注册 | 是（@Component） | 通过 Factory 注册 |
| 细粒度控制 | 在代码中按路径判断 | 按路由配置 |
| 参数配置 | 不灵活 | 可以通过 Args 传递 |
| 典型场景 | 鉴权、日志、限流 | 路径重写、请求改编 |

---

## 七、过滤器执行顺序

过滤器通过 `@Order` 或 `Ordered.getOrder()` 控制执行顺序，数值越小优先级越高：

```java
// 过滤器工厂中指定顺序
public static class ElapsedGatewayFilterFactory
        extends AbstractGatewayFilterFactory<Config> {

    @Override
    public GatewayFilter apply(Config config) {
        return new GatewayFilter() {
            @Override
            public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
                return chain.filter(exchange);
            }
            // 设置 order
            public int getOrder() {
                return config.getOrder();
            }
        };
    }
}
```

**内置过滤器默认顺序参考：**

| 顺序 | 过滤器 | 说明 |
|------|--------|------|
| -1 | `AdaptCachedBodyGlobalFilter` | 缓存请求体 |
| 0 | `NettyWriteResponseFilter` | 写入响应 |
| 1 | `ForwardRoutingFilter` | Forward 转发 |
| 2 | `GatewayMetricsFilter` | 指标采集 |
| 10000 | `RouteToRequestUrlFilter` | 路由转URL |
| 9000+ | ` StripPrefixGatewayFilterFactory` | 路径裁剪 |

---

## 八、常见面试题

### Q1：自定义过滤器如何读取 Request Body？
由于 Request Body 只能读取一次，需要用 `cachedBodyObject` 缓存：

```java
@Override
public GatewayFilter apply(Config config) {
    return (exchange, chain) -> {
        // 获取缓存的消息体
        Object cachedBody = exchange.getAttributeOrDefault(
                CachedBodyOutputMessage.CACHED_SERVER_HTTP_REQUEST_DECORATOR_ATTR, null);
        // 如果没有缓存，手动包装
        // ...
    };
}
```

### Q2：Gateway 和 Zuul 有什么区别？
Spring Cloud Gateway 基于 **WebFlux（Reactive）**，Zuul 1.x 基于 **Servlet（阻塞）**。Gateway 具有更好的性能、支持长连接（WebSocket）、非阻塞。

### Q3：如何实现 IP 黑白名单？
```java
@Component
public class IpBlacklistGlobalFilter implements GlobalFilter, Ordered {
    private static final Set<String> BLACKLIST = new HashSet<>();

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String ip = exchange.getRequest().getRemoteAddress().getAddress().getHostAddress();
        if (BLACKLIST.contains(ip)) {
            exchange.getResponse().setStatusCode(HttpStatus.FORBIDDEN);
            return exchange.getResponse().setComplete();
        }
        return chain.filter(exchange);
    }

    @Override
    public int getOrder() {
        return -100; // 在所有过滤器之前执行
    }
}
```

---

## 总结

Spring Cloud Gateway 的扩展机制非常灵活，掌握自定义开发后，你可以：

1. **自定义过滤器**——做鉴权、日志、加密、限流
2. **自定义谓词**——做灰度、A/B 测试、版本路由
3. **动态路由**——结合 Nacos/Apollo 实现配置热更新
4. **全局过滤器**——做跨切面的统一处理

记住三个要点：**命名约定（去掉 Factory 后缀）**、**@Component 自动注册**、**AbstractXXXFactory 继承体系**。
