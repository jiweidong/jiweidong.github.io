---
title: Spring Cloud 微服务架构核心实战（面试跳槽篇）
date: 2026-06-13 11:29:00
updated: 2026-06-13 11:29:00
tags:
  - Spring Cloud
  - 微服务
  - Nacos
  - Gateway
  - Sentinel
  - Feign
categories: Spring框架
author: 东哥
toc: true
description: Nacos 注册配置中心、Gateway 网关、Sentinel 限流降级、Feign 声明式调用、分布式链路追踪，覆盖 Spring Cloud 微服务面试核心知识点。  
---

# Spring Cloud 微服务架构核心实战（面试跳槽篇）

> 微服务已经是后端开发的标配，Spring Cloud 是 Java 生态中最主流的微服务解决方案。本文从架构设计到核心组件，从原理到面试题，系统梳理微服务面试必知必会的知识体系。

---

## 一、微服务架构基础

### 1.1 单体架构 vs 微服务架构

| 维度 | 单体架构 | 微服务架构 |
|------|---------|-----------|
| **定义** | 所有功能在一个进程中 | 每个服务独立进程部署 |
| **代码管理** | 单仓库 | 多仓库（每个服务独立） |
| **部署** | 整体部署，牵一发而动全身 | 独立部署，互不影响 |
| **扩展** | 只能整个应用水平扩展 | 按需扩展单个服务 |
| **技术栈** | 统一技术栈 | 每个服务可选不同技术栈 |
| **团队协作** | 团队耦合高，合并冲突频繁 | 独立团队，独立迭代 |
| **故障隔离** | 一个模块出问题导致整个服务不可用 | 故障隔离在单个服务内 |
| **测试成本** | 回归测试范围大 | 单个服务测试成本低 |
| **运维成本** | 低，只需运维一个应用 | 高，需要服务发现、配置中心、链路追踪等基础设施 |

**单体痛点：** 代码量膨胀（百万行级别）、构建部署慢、无法按模块扩展、技术债务积累快。

**微服务挑战：** 分布式复杂性（网络延迟、数据一致性）、服务治理成本、运维复杂度飙升。

### 1.2 微服务带来的核心挑战

将单体拆成微服务后，需要解决以下问题：

1. **服务发现** — 服务实例动态上下线，调用方如何找到目标服务？
2. **配置管理** — 各个服务的配置如何集中管理、动态刷新？
3. **网关路由** — 统一入口、路由转发、鉴权限流、协议转换
4. **服务调用** — 微服务之间如何高效、可靠地远程调用？
5. **熔断降级** — 依赖服务故障时如何保护自身不被拖垮？
6. **负载均衡** — 多实例之间如何分配请求？
7. **链路追踪** — 一个请求跨多个服务，如何定位问题？
8. **日志聚合** — 分布式日志如何统一采集和分析？

### 1.3 Spring Cloud 生态全景

Spring Cloud 经历了从 **Netflix OSS 全家桶**到 **Spring Cloud Alibaba** 的演进：

| 功能 | Netflix OSS（已维护模式） | Spring Cloud Alibaba（活跃） |
|------|-------------------------|----------------------------|
| 注册中心 | Eureka（2.0 停更） | **Nacos** ✅ |
| 配置中心 | Spring Cloud Config | **Nacos Config** ✅ |
| 网关 | Zuul 1.0（阻塞式，已停更） | **Spring Cloud Gateway** ✅ |
| 熔断降级 | Hystrix（已停更） | **Sentinel** ✅ |
| 负载均衡 | Ribbon（已进入维护模式） | **Spring Cloud LoadBalancer** ✅ |
| 远程调用 | Feign（贡献给 OpenFeign） | **OpenFeign** ✅ |
| 分布式事务 | — | **Seata** ✅ |
| 消息驱动 | Stream | **RocketMQ** |

> 当前主流选型：**Nacos + Gateway + Sentinel + OpenFeign + LoadBalancer** 已成为微服务新标配。除非维护老项目，否则不建议再学 Netflix OSS 组件。

---

## 二、Nacos（服务注册与配置中心）

### 2.1 什么是 Nacos？

Nacos（Dynamic **Na**ming and **Co**nfiguration **S**ervice）是阿里巴巴开源的一个更易于构建云原生应用的动态服务发现、配置管理和服务管理平台。

**核心能力：**
- **注册中心**：服务注册与发现、健康检查
- **配置中心**：配置管理、动态刷新

### 2.2 Nacos vs 其他注册中心对比

| 功能 | Nacos | Eureka | Consul | Zookeeper |
|------|-------|--------|--------|-----------|
| **CAP 模型** | AP + CP 切换 | AP | CP | CP |
| **健康检查** | 心跳 + TCP/HTTP | 心跳 | TCP/HTTP/gRPC | 心跳 |
| **一致性协议** | Distro（AP）/ Raft（CP） | 自我保护 | Raft | ZAB |
| **配置中心** | ✅ 内置 | ❌ 需第三方 | ✅ | ❌ 需第三方 |
| **控制台** | ✅ Web UI 完善 | ✅ | ✅ | ❌ |
| **接入** | 官方 SDK + Spring Cloud | Eureka Client | 原生 SDK | 三方适配 |
| **生态** | Spring Cloud Alibaba | Spring Cloud Netflix | 自成一派 | 大数据生态 |
| **维护状态** | ✅ 活跃 | ❌ 2.0 停更 | ✅ 活跃 | ✅ 活跃 |

### 2.3 注册中心：服务注册与发现

**服务注册流程：**

```java
// 1. 引入依赖
// <dependency>
//     <groupId>com.alibaba.cloud</groupId>
//     <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
// </dependency>

// 2. 配置 application.yml
// spring:
//   cloud:
//     nacos:
//       discovery:
//         server-addr: 127.0.0.1:8848

// 3. 启动后自动注册到 Nacos
@SpringBootApplication
@EnableDiscoveryClient
public class UserServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(UserServiceApplication.class, args);
    }
}
```

**心跳检测机制：**

```
服务实例启动 → 注册到 Nacos → 每 5 秒发送一次心跳

Nacos Server → 超过 15 秒未收到心跳 → 标记为不健康
              → 超过 30 秒未收到心跳 → 从服务列表中剔除
```

**Nacos AP 模式（Distro 协议）：**

Nacos 默认采用 AP 模式（> 0.7 版本），使用 Distro 协议（阿里巴巴自研的分布式一致性协议）：

- **特点：** 优先保证可用性（AP），允许短暂的数据不一致
- **写请求：** 写入任意节点，异步同步到其他节点
- **读请求：** 读取任意节点，最终一致性
- **适用场景：** 服务发现场景对一致性要求不高，AP 模式更合适

**Nacos CP 模式（Raft 协议）：**

可通过配置切换为 CP 模式：

```yaml
# 切换为 CP 模式（一致性优先）
spring:
  cloud:
    nacos:
      discovery:
        server-addr: 127.0.0.1:8848
        ephemeral: false  # 非临时实例，使用 CP 模式
```

- **特点：** 保证强一致性（CP），但可用性下降
- **Leader 选举：** 基于 Raft 协议，Leader 挂掉需要选主
- **适用场景：** 配置管理、分布式锁等需要强一致的场景

### 2.4 配置中心

**三大核心概念：**

```yaml
# 数据模型
# Data ID: user-service-dev.yaml
# Group: DEFAULT_GROUP
# Namespace: dev

spring:
  cloud:
    nacos:
      config:
        server-addr: 127.0.0.1:8848
        file-extension: yaml
        namespace: dev
        group: DEFAULT_GROUP
```

| 概念 | 说明 | 类比 |
|------|------|------|
| **Data ID** | 配置文件唯一标识 | 文件名 |
| **Group** | 配置分组 | 文件夹 |
| **Namespace** | 命名空间，隔离多环境 | 仓库 |

**动态刷新：**

```java
@Component
@RefreshScope  // 关键注解：支持动态刷新
public class DynamicConfig {
    
    @Value("${user.timeout:5000}")
    private Integer timeout;
    
    @Value("${user.thread-pool-size:10}")
    private Integer threadPoolSize;
    
    // Nacos 中修改配置 → 发布 → 自动推送 → Bean 属性自动更新
    // 不需要重启应用！
}
```

**长轮询机制：**

```
客户端请求配置 → Nacos Server

如果配置没有变更：
  传统方式：立即返回空（短轮询，浪费资源）
  Nacos 方式：挂起请求 30 秒（长轮询）
    ① 30 秒内配置变更 → 立即返回变更内容
    ② 30 秒超时 → 返回 304 Not Modified，客户端重新发起请求

优点：减少网络开销，配置变更秒级生效
```

### 2.5 Nacos vs Spring Cloud Config 对比

| 对比项 | Nacos | Spring Cloud Config |
|--------|-------|-------------------|
| **存储后端** | 内置存储 | Git（需额外部署） |
| **动态刷新** | 原生支持 @RefreshScope | 需配合 Bus + MQ |
| **实时推送** | 长轮询（秒级生效） | Webhook + MQ 广播 |
| **控制台** | Web UI 完善 | 依赖 Git 管理 |
| **配置回滚** | ✅ 支持 | ✅ Git 回滚 |
| **版本管理** | ✅ 内置版本历史 | ✅ Git 天然支持 |
| **部署** | 单进程（集成注册中心） | Config Server 独立部署 |

> **结论：** Nacos 在配置中心方面比 Spring Cloud Config 更轻量、功能更完善，已成为主流选择。

---

## 三、Gateway 网关

### 3.1 Spring Cloud Gateway vs Zuul 1.0

| 对比项 | Spring Cloud Gateway | Zuul 1.0 |
|--------|---------------------|----------|
| **底层** | **Reactor**（WebFlux，非阻塞） | **Servlet**（Tomcat，阻塞式） |
| **线程模型** | 事件驱动，少量线程处理大量请求 | 每个请求一个线程 |
| **性能** | 高（非阻塞 I/O） | 低（阻塞 I/O，线程池瓶颈） |
| **长连接** | ✅ 支持 WebSocket | ❌ 不支持 |
| **路由匹配** | 更灵活（Path/Header/Cookie/Query 等） | 较简单 |
| **维护状态** | ✅ 活跃（Spring Cloud 官方推荐） | ❌ 已停更 |

> 面试中问到网关，直接说**用 Spring Cloud Gateway**，Zuul 1.0 已经落后了。Zuul 2.0 虽然是非阻塞，但 Spring Cloud 没有集成，生态不佳。

### 3.2 核心概念

Spring Cloud Gateway 三个核心概念：

```
Client Request
      ↓
  Predicate（断言） — 匹配条件，决定请求是否走该路由
      ↓
  Filter（过滤器） — 对请求/响应进行修改增强
      ↓
  Route（路由） — 目标服务地址
```

**配置示例：**

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: user-service          # 路由唯一标识
          uri: lb://user-service    # 目标服务（lb:// 表示负载均衡）
          predicates:
            - Path=/api/user/**     # 匹配路径
            - Header=X-Request-Type, web  # 匹配请求头
          filters:
            - StripPrefix=1         # 去掉前缀 /api
            - AddRequestHeader=X-Gateway, true
```

### 3.3 内置 Predicate 工厂

Spring Cloud Gateway 内置了丰富的 Predicate（断言）工厂：

| Predicate 工厂 | 示例 | 说明 |
|---------------|------|------|
| **Path** | `Path=/api/user/**` | 匹配请求路径 |
| **Method** | `Method=GET,POST` | 匹配 HTTP 方法 |
| **Header** | `Header=X-Token, \d+` | 匹配请求头（支持正则） |
| **Cookie** | `Cookie=sid, abc123` | 匹配 Cookie |
| **Query** | `Query=page, \d+` | 匹配查询参数 |
| **Host** | `Host=**.example.com` | 匹配域名 |
| **RemoteAddr** | `RemoteAddr=192.168.1.1/24` | 匹配客户端 IP |
| **Weight** | `Weight=user-service, 80` | 流量权重（灰度发布） |

**组合使用（所有条件都要满足）：**

```yaml
predicates:
  - Path=/api/order/**
  - Method=GET
  - Header=X-Version, v2
  - Query=userId, \d+
```

### 3.4 全局过滤器 vs 局部过滤器

**局部过滤器（GatewayFilter）：** 绑定到某个路由

```yaml
filters:
  - StripPrefix=1            # 去掉前缀
  - AddRequestHeader=X-Gateway, true  # 添加请求头
  - AddResponseHeader=X-Response-Time, 100  # 添加响应头
  - PrefixPath=/api          # 添加前缀
  - CircuitBreaker=myCircuitBreaker  # 熔断
  - RequestRateLimiter=myLimiter     # 限流
```

**全局过滤器（GlobalFilter）：** 应用到所有路由

```java
@Component
public class AuthGlobalFilter implements GlobalFilter, Ordered {
    
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // 1. 获取请求路径和 Token
        String path = exchange.getRequest().getURI().getPath();
        String token = exchange.getRequest().getHeaders().getFirst("Authorization");
        
        // 2. 白名单放行（登录、注册等）
        if (path.contains("/login") || path.contains("/register")) {
            return chain.filter(exchange);
        }
        
        // 3. 鉴权校验
        if (StringUtils.isBlank(token) || !JwtUtil.validate(token)) {
            exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
            return exchange.getResponse().setComplete();
        }
        
        // 4. 将用户信息传递到下游服务
        String userId = JwtUtil.getUserId(token);
        ServerWebExchange newExchange = exchange.mutate()
            .request(r -> r.header("X-User-Id", userId))
            .build();
        
        return chain.filter(newExchange);
    }
    
    @Override
    public int getOrder() {
        return -100;  // 数值越小，优先级越高
    }
}
```

### 3.5 网关的完整职责

| 职责 | 说明 | 实现方式 |
|------|------|---------|
| **路由转发** | 根据路径/Header/Cookie 转发到对应服务 | Path Predicate + lb:// |
| **鉴权认证** | 统一校验 Token、API Key | GlobalFilter |
| **限流** | 保护后端服务不被突发流量打垮 | RequestRateLimiter + Redis |
| **日志** | 记录请求/响应日志，用于排查问题 | GlobalFilter |
| **跨域** | 处理前端 CORS 请求 | CorsConfiguration |
| **熔断** | 下游服务故障时快速失败 | CircuitBreaker Filter |
| **重试** | 临时故障时自动重试 | Retry Filter |
| **灰度发布** | 按 Header/Cookie 将请求路由到特定版本 | Weight Predicate |

---

## 四、Sentinel 流量防卫兵

### 4.1 为什么需要限流降级？

```
正常流量 → 系统正常处理

突发流量 → 系统压力飙升 → 响应变慢 → 请求堆积
→ 连接池耗尽 → 线程阻塞 → 级联故障 → 整个系统雪崩

限流降级的思路：
  ① 控制入口流量（限流）
  ② 下游故障时走降级逻辑（降级）
  ③ 保护自身不被拖垮（隔离）
```

### 4.2 Sentinel 核心概念

**资源（Resource）：** 被保护的对象，可以是方法、接口或代码块

**规则（Rule）：** 定义如何保护资源，有四种核心规则：

| 规则 | 说明 | 典型案例 |
|------|------|----------|
| **流控规则** | 控制 QPS 或线程数 | 接口限流 100 QPS |
| **降级规则** | 熔断降级，不再调用下游 | 下游 50% 请求超时 → 熔断 |
| **热点规则** | 对特定参数限流 | 商品 ID=100 限流 10 QPS |
| **系统规则** | 整体系统负载保护 | Load > 5 时触发限流 |

### 4.3 限流算法对比

| 算法 | 原理 | 优势 | 劣势 |
|------|------|------|------|
| **计数器** | 固定时间窗口内计数，超过阈值拒绝 | 简单 | 突刺问题（窗口前后各 100 个请求可能突破阈值） |
| **滑动窗口** | 将时间窗口划分为多个小格，滑动统计 | 解决突刺问题，较精确 | 精度越高，内存消耗越大 |
| **漏桶** | 固定速率流出，超出桶容量则丢弃 | 平滑流量，适合保护系统 | 无法应对突发流量 |
| **令牌桶** | 匀速生产令牌，有令牌才能通过 | 允许一定突发，不浪费空闲资源 | 实现稍复杂 |

**Sentinel 默认使用滑动窗口算法：**

```
时间窗口 = 1000ms，划分为 2 个格子（500ms 一个）
请求抵达时，统计当前格子 + [前一个格子] 的计数

格子的精度越高（格子数越多），统计越精确，但内存占用越大
Sentinel 默认窗口格数为 2（即 500ms 的精度）
```

### 4.4 熔断降级策略

Sentinel 支持三种熔断策略：

**1. 慢调用比例：**

```java
// 当 1000ms 内请求数 >= 5，且慢调用比例 > 0.6
// 则熔断 10 秒
@SentinelResource(value = "getUser",
    blockHandler = "getUserBlockHandler",
    fallback = "getUserFallback")
```

**2. 异常比例：**

```java
// 当 1 秒内请求数 >= 5，且异常比例 > 0.5
// 则熔断 10 秒
// 适用：下游偶发故障时快速熔断
```

**3. 异常数：**

```java
// 当 1 分钟内请求数 >= 5，且异常数 > 10
// 则熔断 10 秒
// 适用：异常数量超过阈值时熔断
```

### 4.5 @SentinelResource 注解

```java
@RestController
@Slf4j
public class OrderController {
    
    // 限流 + 熔断 + 降级
    @SentinelResource(
        value = "createOrder",                    // 资源名
        blockHandler = "createOrderBlockHandler", // 限流/熔断时触发
        fallback = "createOrderFallback"          // 业务异常时触发
    )
    public Result createOrder(OrderDTO dto) {
        // 调用下游服务
        return Result.success(orderService.create(dto));
    }
    
    // 限流降级方法（必须与原方法同包名 + 静态方法，或同 Class）
    public Result createOrderBlockHandler(OrderDTO dto, BlockException e) {
        log.warn("createOrder 限流/熔断了: {}", e.getMessage());
        return Result.error("系统繁忙，请稍后重试");
    }
    
    // 业务降级方法
    public Result createOrderFallback(OrderDTO dto, Throwable t) {
        log.error("createOrder 业务异常", t);
        return Result.error("服务异常，请稍后");
    }
}
```

**配置流控规则（控制台或代码）：**

```java
@PostConstruct
public void initFlowRules() {
    List<FlowRule> rules = new ArrayList<>();
    
    // 针对 createOrder 资源限流
    FlowRule rule = new FlowRule();
    rule.setResource("createOrder");
    rule.setGrade(RuleConstant.FLOW_GRADE_QPS);  // QPS 限流
    rule.setCount(100);                          // 阈值：100 QPS
    rule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_DEFAULT);  // 快速失败
    
    rules.add(rule);
    FlowRuleManager.loadRules(rules);
}
```

### 4.6 Sentinel vs Hystrix vs Resilience4j

| 对比项 | Sentinel | Hystrix（已停更） | Resilience4j |
|--------|----------|-------------------|-------------|
| **隔离方式** | 信号量隔离 | 线程池隔离 + 信号量 | 信号量隔离 |
| **熔断策略** | 慢调用/异常比例/异常数 | 错误率阈值 | 慢调用/异常比例/异常数 |
| **限流** | ✅ 强大（多种限流算法） | ❌ 不内置 | ❌ 不内置 |
| **实时监控** | ✅ 控制台 Dashboard | ❌ 需要自行集成 | ❌ 需要自行集成 |
| **配置动态变更** | ✅ 控制台/API 动态修改 | ❌ 重启生效 | ❌ 重启生效 |
| **热点限流** | ✅ 支持 | ❌ | ❌ |
| **系统自适应** | ✅ Load/CPU/RT 保护 | ❌ | ❌ |
| **Spring Cloud 集成** | ✅ Spring Cloud Alibaba | Spring Cloud Netflix（已维护模式） | 需额外配置 |

> **结论：** Hystrix 已停更，Resilience4j 只是基本熔断库，Sentinel 是功能最全面的流量防卫组件。

---

## 五、Feign / OpenFeign 声明式调用

### 5.1 Feign 原理

Feign 是一个声明式的 HTTP 客户端，让微服务调用像调用本地方法一样简单。

**工作原理：**

```java
// 1. 定义接口 + 注解
@FeignClient(name = "user-service", path = "/user")
public interface UserClient {
    
    @GetMapping("/{id}")
    Result<UserDTO> getUser(@PathVariable("id") Long id);
    
    @PostMapping("/batch")
    Result<List<UserDTO>> batchGetUsers(@RequestBody List<Long> ids);
}

// 2. 像本地方法一样调用
@Service
public class OrderService {
    @Autowired
    private UserClient userClient;  // 注入 Feign 客户端
    
    public void process(Long userId) {
        Result<UserDTO> user = userClient.getUser(userId);  // HTTP 调用
    }
}
```

**Feign 底层原理（动态代理 + 反射 + URL 拼接）：**

```
1. Spring 启动时扫描 @FeignClient 注解
2. 为每个接口创建动态代理对象
3. 动态代理拦截方法调用：
   - 解析 @RequestMapping → 拼接 URL
   - 解析 @PathVariable/@RequestBody → 构造请求参数
   - 通过 HttpClient 发送 HTTP 请求
   - 解析响应 → 反序列化为返回类型
4. 将动态代理 Bean 注入到需要的地方
```

### 5.2 Ribbon 负载均衡（已进入维护模式）

```java
// 传统方式：Feign + Ribbon（Spring Cloud Netflix）
// Ribbon 负责从 Nacos 获取服务列表，负载均衡后发起调用

// 配置负载均衡策略（Ribbon）
user-service:
  ribbon:
    NFLoadBalancerRuleClassName: com.netflix.loadbalancer.RandomRule  # 随机策略
    # 可选：RoundRobinRule(轮询)、WeightedResponseTimeRule(加权响应时间)
```

### 5.3 Spring Cloud LoadBalancer 替换 Ribbon

Netflix Ribbon 已进入维护模式，Spring Cloud 官方推荐使用 **Spring Cloud LoadBalancer**：

```java
// 1. 排除 Ribbon
// <dependency>
//     <groupId>org.springframework.cloud</groupId>
//     <artifactId>spring-cloud-starter-loadbalancer</artifactId>
// </dependency>

// 2. 配置负载均衡策略
@Configuration
public class LoadBalancerConfig {
    
    @Bean
    public ReactorLoadBalancer<ServiceInstance> randomLoadBalancer(
            Environment environment, LoadBalancerClientFactory loadBalancerClientFactory) {
        String name = environment.getProperty(LoadBalancerClientFactory.PROPERTY_NAME);
        return new RandomLoadBalancer(
            loadBalancerClientFactory.getLazyProvider(name, ServiceInstanceListSupplier.class), name
        );
    }
}
```

```yaml
# 负载均衡配置
spring:
  cloud:
    loadbalancer:
      configurations: health-check  # 启用健康检查
    nacos:
      discovery:
        server-addr: 127.0.0.1:8848
```

**支持的负载均衡策略：**

| 策略 | 说明 |
|------|------|
| **RoundRobinLoadBalancer**（默认） | 轮询 |
| **RandomLoadBalancer** | 随机 |
| **WeightedLoadBalancer** | 权重（配合 Nacos 权重配置） |
| 自定义策略 | 实现 ReactorLoadBalancer 接口 |

---

## 六、分布式链路追踪

### 6.1 链路追踪的背景

在微服务架构中，一个前端请求可能经过 5~10 个服务：

```
客户端 → Gateway → OrderService → UserService → InventoryService → PaymentService
                                                                       ↓
                                                                  NotificationService
```

当请求变慢或报错时，需要知道：
- 请求经过了哪些服务？
- 每个服务耗时多少？
- 哪个环节出了问题？

**这就是链路追踪的价值。**

### 6.2 Sleuth（已进入维护模式）+ Zipkin

**Sleuth 是 Spring Cloud 的分布式链路追踪解决方案（已进入维护模式）。**

**推荐使用 Micrometer Tracing（新一代）：**

```xml
<!-- 新一代链路追踪（Spring Boot 3.x + Micrometer） -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-brave</artifactId>
</dependency>
<dependency>
    <groupId>io.zipkin.reporter2</groupId>
    <artifactId>zipkin-reporter-brave</artifactId>
</dependency>
```

```yaml
# 配置
management:
  tracing:
    sampling:
      probability: 1.0  # 采样率（生产环境建议 0.1）
  zipkin:
    tracing:
      endpoint: http://localhost:9411/api/v2/spans
```

### 6.3 TraceId + SpanId 传递机制

```
TraceId = 7a3b5c8d (全局唯一的链路 ID)
SpanId  = a1b2c3d4 (每个服务调用的 Span ID)
ParentSpanId = f0e1d2c3 (父 Span ID)

示例链路：
  [Gateway] TraceId=7a3b5c8d SpanId=a1b2c3d4
      ↓ (传递 TraceId)
  [OrderService] TraceId=7a3b5c8d SpanId=b2c3d4e5 ParentSpanId=a1b2c3d4
      ↓ (传递 TraceId)
  [UserService] TraceId=7a3b5c8d SpanId=c3d4e5f6 ParentSpanId=b2c3d4e5
```

**传递方式（HTTP Header）：**

| Header | 含义 |
|--------|------|
| `X-B3-TraceId` | 全局 Trace ID |
| `X-B3-SpanId` | 当前 Span ID |
| `X-B3-ParentSpanId` | 父 Span ID |
| `X-B3-Sampled` | 是否采样 |

**传递过程：**

```
服务 A 发起 HTTP 调用 → 自动将 TraceId/SpanId 放入请求头
服务 B 收到请求 → 从请求头中提取 TraceId → 创建新的 Span
服务 B 调用服务 C → 继续传递 TraceId → ...
```

链路数据最终上报到 **Zipkin**，通过 Zipkin UI 可视化查看：

```
Trace View (时间轴):
  Gateway:        ████████████████ 200ms
  OrderService:     ██████████████ 180ms
    UserService:      ████ 40ms
    InventoryService:  ██████ 50ms
    PaymentService:     ██████████ 100ms  ← 瓶颈在这里！
```

### 6.4 MDC 日志关联

```yaml
# logback-spring.xml 配置
<pattern>
    [%d{yyyy-MM-dd HH:mm:ss.SSS}] [%thread] 
    [%X{traceId:-}] [%X{spanId:-}]          <!-- MDC 中获取 TraceId -->
    %-5level %logger{36} - %msg%n
</pattern>
```

**输出效果：**

```
[2026-06-13 11:29:00.123] [http-nio-8080-exec-1] [7a3b5c8d-1] [a1b2c3d4] INFO  c.j.u.UserController - 查询用户: 1001
[2026-06-13 11:29:00.234] [http-nio-8081-exec-2] [7a3b5c8d-1] [b2c3d4e5] INFO  c.j.o.OrderController - 创建订单: 2001
```

**优势：** 通过 TraceId 可以跨服务关联日志，一个请求的完整调用链路一目了然。

---

## 七、高频面试题

### 7.1 微服务之间调用超时怎么处理？

**问题分析：** 微服务调用超时是多米诺骨牌的起点，必须层层设防。

**解决方案（由浅入深）：**

```yaml
# 1. 设置合理的超时时间（OpenFeign）
spring:
  cloud:
    openfeign:
      client:
        config:
          default:
            connectTimeout: 5000   # 连接超时 5s
            readTimeout: 10000     # 读取超时 10s
          user-service:
            connectTimeout: 3000
            readTimeout: 5000
```

**2. 重试机制（幂等接口）：**

```java
@FeignClient(name = "user-service", configuration = FeignRetryConfig.class)
public interface UserClient { ... }

@Configuration
public class FeignRetryConfig {
    @Bean
    public Retryer retryer() {
        return new Retryer.Default(100, 1000, 3);  // 重试 3 次
    }
}
```

**3. 熔断降级（Sentinel）：**

```java
@FeignClient(name = "user-service", fallback = UserClientFallback.class)
public interface UserClient { ... }

@Component
public class UserClientFallback implements UserClient {
    @Override
    public Result<UserDTO> getUser(Long id) {
        return Result.error("用户服务繁忙，请稍后重试");
    }
}
```

**4. 异步解耦 + 消息队列：**

适合非实时的调用（如发短信、推送通知），通过 MQ 解耦，调用方不等待下游响应。

### 7.2 如何设计一个高可用的微服务架构？

从**架构设计**和**运维保障**两个维度回答：

**架构设计：**

```
1. 冗余部署（多实例 + 多机房）
   → 每个服务至少 2 个实例，部署在不同物理机/可用区
   
2. 服务注册高可用（Nacos 集群）
   → Nacos 至少 3 节点集群，数据同步

3. 网关高可用（Gateway 集群 + 负载均衡）
   → 前置 Nginx 分发到多个 Gateway 实例

4. 配置管理高可用（Nacos Config + 本地缓存）
   → Nacos 不可用时，应用使用本地缓存配置启动

5. 数据存储高可用（主从 + 分库分表）
   → MySQL 主从/集群、Redis 哨兵/集群

6. 服务调用容错（Sentinel + 重试 + 降级）
   → 每一层调用都有超时、重试、熔断、降级策略
```

**运维保障：**

```
1. 健康检查 + 自动恢复（K8s + Readiness/Liveness Probe）
2. 全链路监控（Prometheus + Grafana + Zipkin + ELK）
3. 灰度发布 + 蓝绿部署
4. 容量评估 + 弹性伸缩（HPA）
```

### 7.3 Nacos AP vs CP 切换

```yaml
# AP 模式（临时实例、默认）
spring.cloud.nacos.discovery.ephemeral: true
# 服务实例心跳超时（15秒）→ 不健康；30秒 → 剔除
# 优先保证可用性，最终一致性
# 适合：服务发现场景

# CP 模式（非临时实例）
spring.cloud.nacos.discovery.ephemeral: false
# 采用 Raft 协议，强一致性
# 节点故障后需要 Leader 选举，期间不可用
# 适合：配置管理、分布式锁
```

**面试要点：** 什么时候 AP？什么时候 CP？

- **服务注册发现：** AP 模式足够，短暂的不一致不影响（服务可能已经下线）
- **配置管理：** CP 模式必须，配置不允许不一致

### 7.4 Sentinel 的滑动窗口数据统计原理

Sentinel 的滑动窗口是最核心的统计机制：

```
整个时间窗口：1000ms
分成：2 个格子（windowLengthInMs = 500ms）

每个格子维护一个 MetricBucket（包含 pass/block/exception/success/rt 等计数）

统计时：
  当前时间 → 确定所在的格子
  + 前 N-1 个格子 → 累加得到当前 QPS

示例（统计 1000ms 窗口内的数据）：
  [0-500ms]   [500-1000ms]   [1000-1500ms]  [1500-2000ms]
    格1           格2            格3             格4

  时间=1200ms 时，统计 = 格2(500-1000) + 格3(1000-1500)
  时间=1700ms 时，统计 = 格3(1000-1500) + 格4(1500-2000)
```

**滑动窗口的优势：** 相比固定窗口（计数器）的突刺问题，滑动窗口更精确、更平滑地反映真实流量。

**局限性：** 精度越高（格子越多），内存占用越大。

**其他限流算法对比（常考）：**

| 算法 | 是否能应对突发？ | 流量是否平滑？ | 实现复杂度 |
|------|:--------------:|:-------------:|:---------:|
| 固定窗口（计数器） | ❌ 有突刺问题 | ❌ | 低 |
| 滑动窗口 | ❌ 可应对突发，但不超过2倍阈值 | 一般 | 中 |
| 漏桶 | ❌ 削峰填谷 | ✅ 恒定速率 | 中 |
| 令牌桶 | ✅ 支持一定突发 | ✅ 较平滑 | 中 |

---

## 总结

Spring Cloud 微服务从 Netflix OSS 演进到 Alibaba 体系，核心组件已经形成新标配：

- **Nacos**：集注册中心与配置中心于一身，是微服务基石
- **Gateway**：非阻塞网关，鉴权、路由、限流一站式解决
- **Sentinel**：功能远超 Hystrix 的流量防卫兵
- **OpenFeign + LoadBalancer**：声明式远程调用，优雅简洁
- **Micrometer + Zipkin**：链路追踪，分布式排障利器

面试中的常见回答框架：

1. **选型理由** — 为什么用 A 不用 B（Nacos vs Eureka, Sentinel vs Hystrix）
2. **核心原理** — 底层怎么实现的（Feign 动态代理、Nacos 长轮询、Sentinel 滑动窗口）
3. **实践方案** — 生产环境中怎么配置、如何优化

掌握这套知识体系，微服务面试基本没问题。祝大家拿到心仪的 Offer！🚀
