---
title: Spring Cloud Gateway 源码深度解析：请求路由与过滤器链核心实现
date: 2026-06-19 08:00:00
tags:
  - Spring Cloud
  - Gateway
  - 源码分析
categories:
  - Spring Cloud
author: 东哥
---

## 一、引言

Spring Cloud Gateway 是 Spring 官方基于 Spring WebFlux 构建的 API 网关解决方案，旨在为微服务架构提供统一的路由、过滤、限流、熔断等功能。相比第一代网关 Zuul 1.x（基于 Servlet 同步阻塞模型），Gateway 采用 Reactor 响应式编程模型，具备更高的吞吐量和更低的资源消耗。本文将深入 Spring Cloud Gateway 源码，剖析其请求路由与过滤器链的核心实现机制。

### Gateway 与 Zuul 核心对比

| 维度 | Spring Cloud Gateway | Zuul 1.x | Zuul 2.x |
|------|----------------------|----------|----------|
| 底层框架 | Spring WebFlux (Reactor) | Servlet (同步阻塞) | Netty (异步) |
| 编程模型 | 响应式 (非阻塞) | 同步阻塞 | 响应式 (异步) |
| 长连接支持 | 原生支持 WebSocket | 不支持 | 支持 |
| 路由匹配 | Predicate + Filter 链 | 路由规则 + Filter 链 | 路由规则 + Filter 链 |
| 性能吞吐 | 高 | 低（线程阻塞） | 中高 |
| Spring 生态集成 | 原生 Reactive 支持 | 需适配 | 需适配 |
| 社区活跃度 | 活跃（官方维护） | 维护模式 | 维护模式 |
| 限流实现 | RequestRateLimiter + Redis | 需自定义 | 需自定义 |
| 配置方式 | YAML/Java DSL/注解 | YAML/Java DSL | YAML/Java DSL |

从上表可以看出，Gateway 在性能、生态集成和功能完备性上具有显著优势，已成为 Spring Cloud 微服务网关的事实标准。

## 二、整体架构概览

Spring Cloud Gateway 的核心处理流程可分为三个主要阶段：

1. **路由定位阶段**：客户端请求到达后，`DispatcherHandler` 根据请求路径在 `RouteLocator` 注册的路由表中匹配对应的 `Route`。
2. **谓词匹配阶段**：匹配到的 Route 包含一组 Predicate（断言条件），只有所有 Predicate 都满足时才会进入该路由的过滤器链。
3. **过滤器链执行阶段**：`FilteringWebHandler` 组装全局过滤器（GlobalFilter）和路由级过滤器（GatewayFilter），构建过滤器链并顺序执行。

### 核心类关系

```
DispatcherHandler
  └── handle() 
       └── RoutePredicateHandlerMapping.getHandler()  → 匹配 Route
            └── FilteringWebHandler.handle()           → 构建过滤器链
                 └── GatewayFilterChain.filter()       → 执行过滤器
```

### 核心组件说明

| 组件 | 接口/类 | 职责 |
|------|---------|------|
| 路由定位器 | `RouteLocator` | 定义路由来源，从 YAML、Bean 或自定义源加载路由 |
| 组合路由定位器 | `CompositeRouteLocator` | 组合多个 RouteLocator 的查询结果 |
| 路由断言映射器 | `RoutePredicateHandlerMapping` | 根据请求匹配 Route，返回 WebHandler |
| 过滤 Web 处理器 | `FilteringWebHandler` | 组装全局过滤器和路由过滤器 |
| 网关过滤器链 | `GatewayFilterChain` | 按顺序执行过滤器链 |
| 路由定义 | `RouteDefinition` | 路由的配置模型（id, uri, predicates, filters） |
| 路由 | `Route` | 运行时路由对象，包含 id, uri, predicates, filters |

## 三、路由定位机制源码分析

### 3.1 RouteLocator 接口体系

`RouteLocator` 是路由定位的核心接口，定义了 `getRoutes()` 方法返回一个 `Flux<Route>`：

```java
// org.springframework.cloud.gateway.route.RouteLocator
public interface RouteLocator {
    Flux<Route> getRoutes();
}
```

Spring Cloud Gateway 提供了多种 RouteLocator 实现：

| 实现类 | 作用 | 优先级顺序 |
|--------|------|-----------|
| `RouteDefinitionRouteLocator` | 从 RouteDefinition 转换为 Route，支持 YAML/Java DSL | 最低（但最常用） |
| `CompositeRouteLocator` | 组合多个 RouteLocator 的结果 | 无（组合器） |
| `CachingRouteLocator` | 缓存路由列表，定期刷新 | 包裹在其他 Locator 之上 |

### 3.2 CompositeRouteLocator 组合模式

`CompositeRouteLocator` 使用组合模式将所有 RouteLocator 合并：

```java
public class CompositeRouteLocator implements RouteLocator {
    private final List<RouteLocator> delegates;

    public CompositeRouteLocator(List<RouteLocator> delegates) {
        this.delegates = delegates;
    }

    @Override
    public Flux<Route> getRoutes() {
        return Flux.fromIterable(delegates)
            .flatMap(RouteLocator::getRoutes)
            .sort();  // 按 Route.order 排序
    }
}
```

### 3.3 RouteDefinitionRouteLocator 核心实现

这是最核心的 RouteLocator 实现，负责将 `RouteDefinition` 转换为运行时 `Route`。其 `getRoutes()` 方法核心流程：

```java
@Override
public Flux<Route> getRoutes() {
    return this.routeDefinitionLocator.getRouteDefinitions()
        .map(this::convertToRoute)  // 将 RouteDefinition 转换为 Route
        .map(route -> {
            // 记录路由加载日志
            if (log.isDebugEnabled()) {
                log.debug("RouteDefinition matched: " + route.getId());
            }
            return route;
        });
}
```

`convertToRoute` 方法将 RouteDefinition 中的 predicates 和 filters 转换为运行时对象：

```java
private Route convertToRoute(RouteDefinition definition) {
    // 1. 解析路由断言
    Predicate<ServerWebExchange> predicate = combinePredicates(definition);
    
    // 2. 解析网关过滤器
    List<GatewayFilter> gatewayFilters = loadGatewayFilters(definition);
    
    // 3. 构建 Route 对象
    return Route.async(definition)
        .id(definition.getId())
        .uri(definition.getUri())
        .order(definition.getOrder())
        .predicate(predicate)
        .filters(gatewayFilters)
        .build();
}
```

### 3.4 路由加载配置源

`PropertiesRouteDefinitionLocator` 从 YAML/Properties 配置中加载路由，而 `InMemoryRouteDefinitionRepository` 支持通过 Actuator API 动态管理路由。

```yaml
# application.yml 中的路由配置
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
                redis-rate-limiter.replenishRate: 10
                redis-rate-limiter.burstCapacity: 20
```

## 四、请求匹配与谓词体系

### 4.1 RoutePredicateHandlerMapping 匹配策略

`RoutePredicateHandlerMapping` 继承自 `AbstractHandlerMapping`，核心匹配逻辑在 `getHandlerInternal()` 方法：

```java
@Override
protected Mono<?> getHandlerInternal(ServerWebExchange exchange) {
    return this.routeLocator.getRoutes()
        .filter(route -> {
            // 使用 route 的 predicate 进行过滤
            return route.getPredicate().test(exchange);
        })
        .next()  // 取第一个匹配的路由
        .flatMap(route -> {
            // 将匹配到的 Route 存入 exchange 属性
            exchange.getAttributes().put(GATEWAY_ROUTE_ATTR, route);
            // 返回 FilteringWebHandler
            return Mono.just(webHandler);
        });
}
```

### 4.2 RoutePredicateFactory 工厂体系

`RoutePredicateFactory` 是所有谓词工厂的顶层接口，每种路由谓词对应一个工厂实现：

| 谓词工厂 | 配置示例 | 功能说明 |
|----------|---------|---------|
| `PathRoutePredicateFactory` | `- Path=/api/**` | 请求路径模式匹配（Ant 风格） |
| `MethodRoutePredicateFactory` | `- Method=GET,POST` | HTTP 方法匹配 |
| `HeaderRoutePredicateFactory` | `- Header=X-Request-Id, \d+` | 请求头名称+值正则匹配 |
| `QueryRoutePredicateFactory` | `- Query=foo, ba.` | 查询参数键名+值正则匹配 |
| `CookieRoutePredicateFactory` | `- Cookie=chocolate, ch.p` | Cookie 名称+值正则匹配 |
| `HostRoutePredicateFactory` | `- Host=**.example.com` | Host 域名通配匹配 |
| `RemoteAddrRoutePredicateFactory` | `- RemoteAddr=192.168.1.1/24` | 客户端 IP 地址匹配 |
| `WeightRoutePredicateFactory` | `- Weight=group1, 80` | 权重路由（金丝雀发布） |
| `AfterRoutePredicateFactory` | `- After=2024-01-01T00:00:00+08:00` | 时间之后生效 |
| `BetweenRoutePredicateFactory` | `- Between=2024-01-01,2024-12-31` | 时间区间匹配 |
| `BeforeRoutePredicateFactory` | `- Before=2024-12-31T23:59:59+08:00` | 时间之前生效 |

### 4.3 PathRoutePredicateFactory 源码分析

以最常用的路径匹配为例：

```java
public class PathRoutePredicateFactory 
    extends AbstractRoutePredicateFactory<PathRoutePredicateFactory.Config> {
    
    private final PathPatternParser pathPatternParser = new PathPatternParser();

    @Override
    public Predicate<ServerWebExchange> apply(Config config) {
        // 解析路径模式
        List<PathPattern> patterns = config.patterns.stream()
            .map(this.pathPatternParser::parse)
            .collect(Collectors.toList());

        return exchange -> {
            // 获取请求路径
            PathContainer path = exchange.getRequest().getURI().getPathContainer();
            
            // 逐个模式匹配
            for (PathPattern pattern : patterns) {
                PathPattern.PathMatchInfo matched = pattern.matchAndExtract(path);
                if (matched != null) {
                    // 将路径变量存入 exchange 属性
                    Map<String, String> uriVariables = 
                        matched.getUriVariables();
                    exchange.getAttributes().put(
                        GATEWAY_PREDICATE_PATH_MATCH_ATTR, uriVariables);
                    exchange.getAttributes().put(
                        GATEWAY_PREDICATE_PATH_PATTERN_ATTR, 
                        pattern.getPatternString());
                    return true;
                }
            }
            return false;
        };
    }
}
```

路径匹配使用 Spring 5.3 引入的 `PathPattern`（基于解析树），相比 AntPathMatcher 性能更优，并且天然支持 `{segment}` 和 `**` 模式。

## 五、过滤器链核心实现

### 5.1 过滤器体系架构

Gateway 的过滤器分为两类：

| 类型 | 接口 | 作用域 | 配置方式 | 排序机制 |
|------|------|--------|---------|---------|
| 全局过滤器 | `GlobalFilter` | 所有路由 | 自动生效 | `@Order` / Ordered 接口 |
| 网关过滤器 | `GatewayFilter` | 指定路由 | 路由配置中声明 | 工厂类自带 order |

### 5.2 FilteringWebHandler 过滤器组装

`FilteringWebHandler` 负责将全局过滤器与路由过滤器合并，构建有序的过滤器链：

```java
public class FilteringWebHandler implements WebHandler {
    private final List<GlobalFilter> globalFilters;

    @Override
    public Mono<Void> handle(ServerWebExchange exchange) {
        // 1. 从 exchange 中获取匹配到的 Route
        Route route = exchange.getAttribute(GATEWAY_ROUTE_ATTR);
        
        // 2. 获取该路由的网关过滤器列表
        List<GatewayFilter> gatewayFilters = route.getFilters();
        
        // 3. 将全局过滤器转换为 GatewayFilter 适配器
        List<GatewayFilter> combined = combine(globalFilters, gatewayFilters);
        
        // 4. 构建有序过滤器链
        GatewayFilterChain chain = new DefaultGatewayFilterChain(combined);
        
        return chain.filter(exchange);
    }

    private List<GatewayFilter> combine(
            List<GlobalFilter> globalFilters, 
            List<GatewayFilter> routeFilters) {
        
        // 将 GlobalFilter 包装为 GatewayFilter 适配器
        List<GatewayFilter> all = new ArrayList<>();
        for (GlobalFilter globalFilter : globalFilters) {
            all.add(new GatewayFilterAdapter(globalFilter));
        }
        all.addAll(routeFilters);
        
        // 按 order 排序（从小到大）
        AnnotationAwareOrderComparator.sort(all);
        
        return all;
    }
}
```

### 5.3 GatewayFilterChain 执行机制

`DefaultGatewayFilterChain` 通过索引遍历实现过滤器链的顺序执行：

```java
private static class DefaultGatewayFilterChain implements GatewayFilterChain {
    private final List<GatewayFilter> filters;
    private final int index;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange) {
        if (this.index < filters.size()) {
            GatewayFilter filter = filters.get(this.index);
            // 创建下一个链节点（index + 1）
            DefaultGatewayFilterChain chain = 
                new DefaultGatewayFilterChain(this, this.index + 1);
            // 执行当前过滤器，传入下一个链
            return filter.filter(exchange, chain);
        } else {
            // 所有过滤器执行完毕，返回空 Mono
            return Mono.empty();
        }
    }
}
```

这是典型的责任链模式实现，每个过滤器可以：

- **继续执行**：调用 `chain.filter(exchange)` 传递到下一个过滤器
- **短路返回**：不调用 chain.filter，直接返回响应
- **修改请求/响应**：在 filter 方法中处理 exchange

### 5.4 全局过滤器排序与执行顺序

| Order | 全局过滤器 | 职责 |
|-------|-----------|------|
| -1000 | `NettyWriteResponseFilter` | 将代理响应写回客户端（最后执行） |
| -1 | `ForwardRoutingFilter` | 处理 `forward://` 协议转发 |
| 0 | `GatewayMetricsFilter` | 记录请求指标（如无配置则不启用） |
| 10000 | `RouteToRequestUrlFilter` | 将路由 URI 转换为请求 URL |
| 10001 | `LoadBalancerClientFilter` | 负载均衡处理（lb:// 协议） |
| 10002 | `WebClientHttpRoutingFilter` | 使用 WebClient 发送 HTTP 请求 |
| 10100 | `NettyRoutingFilter` | 使用 Netty HttpClient 发送请求 |
| Integer.MAX_VALUE | 自定义全局过滤器 | 默认最后执行 |

## 六、Netty 运行时与请求转发

### 6.1 NettyRoutingFilter 源码分析

`NettyRoutingFilter` 是请求转发的执行者，使用 Reactor Netty 的 `HttpClient` 发送请求：

```java
public class NettyRoutingFilter implements GlobalFilter, Ordered {
    private final HttpClient httpClient;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // 获取路由目标 URI
        URI requestUrl = exchange.getAttribute(GATEWAY_REQUEST_URL_ATTR);
        
        // 1. 构建请求头
        HttpHeaders headers = exchange.getRequest().getHeaders();
        HttpHeaders filtered = filterRequestHeaders(headers);
        
        // 2. 构建 Netty 请求
        Flux<HttpClientRequest> request = ...;
        
        // 3. 发送请求
        return this.httpClient
            .headers(mergedHeaders -> filtered.forEach(mergedHeaders::set))
            .request(HttpMethod.valueOf(exchange.getRequest().getMethodValue()))
            .uri(requestUrl.toString())
            .send((req, nettyOutbound) -> {
                // 写入请求体
                return nettyOutbound.send(
                    exchange.getRequest().getBody()
                        .map(dataBuffer -> ...));
            })
            .response((nettyResponse, nettyInbound) -> {
                // 4. 构建响应对象存入 exchange
                ServerHttpResponse response = buildResponse(exchange, nettyResponse);
                exchange.getAttributes().put(
                    CLIENT_RESPONSE_ATTR, response);
                
                // 5. 继续过滤器链
                return chain.filter(exchange);
            });
    }
}
```

### 6.2 负载均衡集成

`ReactiveLoadBalancerClientFilter` 将 `lb://service-name` 地址解析为实际实例地址：

```java
public class ReactiveLoadBalancerClientFilter implements GlobalFilter, Ordered {
    private final LoadBalancerClientFactory clientFactory;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        URI url = exchange.getAttribute(GATEWAY_REQUEST_URL_ATTR);
        
        if (url == null || !"lb".equals(url.getScheme())) {
            return chain.filter(exchange);  // 非 lb 协议直接跳过
        }
        
        // 1. 提取服务名
        String serviceId = url.getHost();
        
        // 2. 获取负载均衡器并选择实例
        return choose(serviceId, exchange).flatMap(instance -> {
            if (instance == null) {
                return Mono.error(...);  // 无可用实例
            }
            
            // 3. 替换 URI 中的服务名为实际地址
            URI newUrl = loadBalancerURI(instance, url);
            exchange.getAttributes().put(GATEWAY_REQUEST_URL_ATTR, newUrl);
            
            // 4. 继续过滤器链
            return chain.filter(exchange);
        });
    }
}
```

## 七、限流与熔断实现

### 7.1 RequestRateLimiterGatewayFilterFactory

该过滤器基于令牌桶算法 + Redis 实现分布式限流：

```java
public class RequestRateLimiterGatewayFilterFactory 
    extends AbstractGatewayFilterFactory<RequestRateLimiterGatewayFilterFactory.Config> {
    
    private final KeyResolver defaultKeyResolver;  // 限流 key 解析
    private final RateLimiter defaultRateLimiter;    // 限流器实现（RedisRateLimiter）

    @Override
    public GatewayFilter apply(Config config) {
        KeyResolver resolver = getOrDefault(config.keyResolver, defaultKeyResolver);
        RateLimiter rateLimiter = getOrDefault(config.rateLimiter, defaultRateLimiter);
        
        return (exchange, chain) -> {
            // 1. 解析限流 key（如用户 ID、客户端 IP）
            return resolver.resolve(exchange).flatMap(key -> {
                
                // 2. 判断是否允许请求通过
                return rateLimiter.isAllowed(config.getRouteId(), key)
                    .flatMap(response -> {
                        // 3. 设置响应头
                        exchange.getResponse().getHeaders()
                            .add(X_RATE_LIMIT_REMAINING_HEADER, 
                                 String.valueOf(response.getTokensRemaining()));
                        
                        if (response.isAllowed()) {
                            return chain.filter(exchange);  // 放行
                        } else {
                            // 4. 限流触发：返回 HTTP 429
                            exchange.getResponse().setStatusCode(
                                HttpStatus.TOO_MANY_REQUESTS);
                            return exchange.getResponse()
                                .setComplete();  // 短路返回
                        }
                    });
            });
        };
    }
}
```

### 7.2 CircuitBreakerGatewayFilterFactory

熔断过滤器基于 Resilience4j CircuitBreaker 实现：

```java
public CircuitBreakerGatewayFilterFactory() {
    // 默认熔断配置
    CircuitBreakerConfig config = CircuitBreakerConfig.custom()
        .failureRateThreshold(50)           // 50% 请求失败触发熔断
        .waitDurationInOpenState(Duration.ofSeconds(30))  // 半开等待时间
        .slidingWindowSize(10)              // 滑动窗口大小
        .minimumNumberOfCalls(5)            // 最小调用次数
        .permittedNumberOfCallsInHalfOpenState(3)
        .build();
}
```

配置示例：

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/orders/**
          filters:
            - name: CircuitBreaker
              args:
                name: orderCircuitBreaker
                fallbackUri: forward:/fallback/order
```

## 八、总结

Spring Cloud Gateway 通过 WebFlux 响应式模型实现了高性能 API 网关。其核心设计模式包括：

1. **组合模式**：CompositeRouteLocator 统一管理多种路由来源
2. **工厂模式**：RoutePredicateFactory 和 GatewayFilterFactory 分别负责谓词和过滤器的创建
3. **责任链模式**：GatewayFilterChain 实现过滤器链的串联执行
4. **适配器模式**：GlobalFilter 通过 GatewayFilterAdapter 转为 GatewayFilter 统一管理

理解这些源码实现，能帮助我们在生产环境中更精准地配置调优 Gateway，遇到问题时也能快速定位。建议在生产部署前进行充分的压测，并根据业务场景选择合适的谓词和过滤器组合，避免全局过滤器的滥用导致性能瓶颈。
