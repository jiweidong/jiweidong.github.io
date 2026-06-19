---
title: Spring Cloud Alibaba 微服务全家桶实战
date: 2026-06-17 08:00:00
tags:
  - Spring Cloud Alibaba
  - Nacos
  - Sentinel
  - Seata
  - Gateway
categories:
  - 微服务
author: 东哥
---

# Spring Cloud Alibaba 微服务全家桶实战

## 一、为什么选择 Spring Cloud Alibaba？

在微服务架构的演进过程中，Spring Cloud Netflix 系列（Eureka、Hystrix、Zuul 等）曾经是业界标准。但随着 Netflix 进入维护模式，Spring Cloud Alibaba 凭借阿里系产品在双十一等极端场景下的验证，逐渐成为国内微服务架构的首选方案。

Spring Cloud Alibaba 的核心优势在于它不仅提供了完整的微服务治理能力，还深度适配了国内企业常见的中间件生态，包括分布式配置、服务发现、流量控制、分布式事务等关键能力。

| 组件 | 作用 | 替代对象 |
|------|------|----------|
| Nacos | 注册中心 + 配置中心 | Eureka + Config |
| Sentinel | 流量控制、熔断降级 | Hystrix |
| Seata | 分布式事务 | - |
| RocketMQ | 异步消息 | RabbitMQ |
| Dubbo | RPC 调用 | Feign 可选 |
| Gateway | API 网关 | Zuul |

---

## 二、项目搭建与基础环境

### 2.1 项目结构

```
cloud-practice/
├── cloud-common/          # 公共模块
├── cloud-gateway/         # 网关服务
├── cloud-auth/            # 认证服务
├── cloud-order/           # 订单服务
├── cloud-storage/         # 库存服务
└── cloud-account/         # 账户服务
```

### 2.2 父工程依赖

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>2.7.18</version>
</parent>

<properties>
    <java.version>17</java.version>
    <spring-cloud.version>2021.0.8</spring-cloud.version>
    <spring-cloud-alibaba.version>2021.0.5.0</spring-cloud-alibaba.version>
</properties>

<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-dependencies</artifactId>
            <version>${spring-cloud.version}</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
        <dependency>
            <groupId>com.alibaba.cloud</groupId>
            <artifactId>spring-cloud-alibaba-dependencies</artifactId>
            <version>${spring-cloud-alibaba.version}</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>
```

---

## 三、Nacos 注册中心与配置中心

Nacos（Dynamic Naming and Configuration Service）是阿里巴巴开源的一个更易于构建云原生应用的动态服务发现、配置管理和服务管理平台。

### 3.1 部署 Nacos Server

通过 Docker 快速部署：

```bash
docker run -d \
  --name nacos-server \
  -p 8848:8848 \
  -p 9848:9848 \
  -e MODE=standalone \
  -e JVM_XMS=256m \
  -e JVM_XMX=512m \
  nacos/nacos-server:2.2.3
```

### 3.2 服务注册与发现

添加依赖：

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

配置 application.yml：

```yaml
spring:
  application:
    name: order-service
  cloud:
    nacos:
      discovery:
        server-addr: 127.0.0.1:8848
        namespace: dev
        group: DEFAULT_GROUP

server:
  port: 8081
```

验证服务注册：

```java
@SpringBootApplication
@EnableDiscoveryClient
public class OrderApplication {
    public static void main(String[] args) {
        SpringApplication.run(OrderApplication.class, args);
    }
}

@RestController
@RequestMapping("/order")
public class OrderController {

    @Autowired
    private DiscoveryClient discoveryClient;

    @GetMapping("/instances")
    public List<ServiceInstance> getInstances() {
        // 获取 order-service 的所有可用实例
        return discoveryClient.getInstances("order-service");
    }
}
```

### 3.3 配置中心——动态刷新

添加依赖：

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
</dependency>
```

创建 bootstrap.yml（注意是 bootstrap，不是 application）：

```yaml
spring:
  cloud:
    nacos:
      config:
        server-addr: 127.0.0.1:8848
        namespace: dev
        group: DEFAULT_GROUP
        file-extension: yaml
        refresh-enabled: true
```

在 Nacos 控制台创建配置：`Data ID = order-service-dev.yaml`

```yaml
# Data ID: order-service-dev.yaml
order:
  timeout: 5000
  max-count: 100
  discount:
    enabled: true
    rate: 0.85
```

代码中动态获取配置：

```java
@Component
@RefreshScope
@ConfigurationProperties(prefix = "order")
public class OrderConfig {

    private int timeout;
    private int maxCount;
    private Discount discount;

    // getters & setters

    @Data
    public static class Discount {
        private boolean enabled;
        private double rate;
    }
}

@RestController
@RequestMapping("/config")
public class ConfigController {

    @Autowired
    private OrderConfig orderConfig;

    @GetMapping("/show")
    public OrderConfig showConfig() {
        return orderConfig;
    }
}
```

`@RefreshScope` 注解是关键——当 Nacos 配置发生变更时，Nacos 会主动推送变更通知，Spring Cloud 自动刷新 Bean 的属性，无需重启应用。

### 3.4 配置管理核心概念

| 概念 | 说明 | 注意事项 |
|------|------|----------|
| Data ID | 配置的唯一标识，格式通常为 `${spring.application.name}-${profile}.${file-extension}` | 支持 yaml、properties、json、xml 等格式 |
| Group | 配置分组，默认为 DEFAULT_GROUP | 可用来区分环境、项目、业务线 |
| Namespace | 命名空间，用于多环境/多租户隔离 | 不同 namespace 之间配置完全隔离 |
| 配置格式 | 支持 YAML、Properties、JSON、XML、TEXT | 推荐使用 YAML，支持层级结构 |

---

## 四、Sentinel 流量控制与熔断降级

Sentinel 是阿里巴巴开源的流量防卫兵，其核心原则是：**先统一规则，后流量控制，以资源为核心**。

### 4.1 集成 Sentinel

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
</dependency>
```

```yaml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: localhost:8080
      eager: true
      datasource:
        ds1:
          nacos:
            server-addr: 127.0.0.1:8848
            data-id: sentinel-order-flow-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: flow
```

### 4.2 流量控制规则详解

Sentinel 的流量控制有多个维度的控制行为：

```java
@Component
public class SentinelConfig {

    @PostConstruct
    public void initFlowRules() {
        List<FlowRule> rules = new ArrayList<>();

        FlowRule rule = new FlowRule();
        rule.setResource("createOrder");
        rule.setGrade(RuleConstant.FLOW_GRADE_QPS);  // 按 QPS 限流
        rule.setCount(100);                          // 阈值
        rule.setLimitApp("default");
        rule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_DEFAULT);  // 快速失败

        // 方式二：Warm Up（冷启动）
        FlowRule warmUpRule = new FlowRule();
        warmUpRule.setResource("doPayment");
        warmUpRule.setGrade(RuleConstant.FLOW_GRADE_QPS);
        warmUpRule.setCount(200);
        warmUpRule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_WARM_UP);
        warmUpRule.setWarmUpPeriodSec(10);  // 预热时间 10 秒

        // 方式三：排队等待（漏桶算法）
        FlowRule queueRule = new FlowRule();
        queueRule.setResource("batchExport");
        queueRule.setGrade(RuleConstant.FLOW_GRADE_QPS);
        queueRule.setCount(10);
        queueRule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_RATE_LIMITER);
        queueRule.setMaxQueueingTimeMs(500);  // 最大排队时间 500ms

        rules.add(rule);
        rules.add(warmUpRule);
        rules.add(queueRule);

        FlowRuleManager.loadRules(rules);
    }
}
```

### 4.3 熔断降级实战

```java
@Service
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    @SentinelResource(
        value = "createOrder",
        blockHandler = "handleBlock",
        fallback = "handleFallback"
    )
    public Order createOrder(OrderDTO dto) {
        // 复杂的下单逻辑，可能调用多个远程服务
        if (dto.getAmount() <= 0) {
            throw new IllegalArgumentException("金额不能为 0");
        }

        // 模拟下游调用
        boolean result = inventoryService.deductStock(dto.getSkuId(), dto.getCount());
        if (!result) {
            throw new RuntimeException("库存扣减失败");
        }

        return orderMapper.save(dto.toOrder());
    }

    /**
     * blockHandler —— 触发限流/熔断时调用
     * 参数必须与原始方法一致，需额外加 BlockException 参数
     */
    public Order handleBlock(OrderDTO dto, BlockException ex) {
        log.warn("createOrder 被限流/熔断，QPS 超过阈值，原因: {}", ex.getRule());
        throw new BlockedException("系统繁忙，请稍后重试");
    }

    /**
     * fallback —— 业务异常时调用（运行时异常）
     */
    public Order handleFallback(OrderDTO dto, Throwable t) {
        log.error("createOrder 执行异常，回退处理", t);
        Order fallback = new Order();
        fallback.setOrderNo("FALLBACK-" + System.currentTimeMillis());
        fallback.setStatus(OrderStatus.FAILED);
        return fallback;
    }
}
```

### 4.4 熔断规则配置——慢调用比例与异常比例

```java
@PostConstruct
public void initDegradeRules() {
    List<DegradeRule> rules = new ArrayList<>();

    // 慢调用比例熔断：RT > 200ms 的请求占比超过 50% 时触发
    DegradeRule slowRule = new DegradeRule();
    slowRule.setResource("createOrder");
    slowRule.setGrade(RuleConstant.DEGRADE_GRADE_RT);     // 按响应时间
    slowRule.setCount(200);                                 // 慢调用阈值 200ms
    slowRule.setSlowRatioThreshold(0.5);                    // 慢调用比例阈值 50%
    slowRule.setMinRequestAmount(5);                        // 触发熔断的最小请求数
    slowRule.setStatIntervalMs(10000);                      // 统计时长 10s
    slowRule.setTimeWindow(10);                             // 熔断时长 10s

    // 异常比例熔断：异常占比超过 30% 时触发
    DegradeRule exceptionRule = new DegradeRule();
    exceptionRule.setResource("doPayment");
    exceptionRule.setGrade(RuleConstant.DEGRADE_GRADE_EXCEPTION_RATIO);
    exceptionRule.setCount(0.3);        // 异常比例阈值 30%
    exceptionRule.setMinRequestAmount(10);
    exceptionRule.setStatIntervalMs(10000);
    exceptionRule.setTimeWindow(30);    // 熔断后 30s 进入半开状态

    rules.add(slowRule);
    rules.add(exceptionRule);

    DegradeRuleManager.loadRules(rules);
}
```

### 4.5 流控模式对比

| 流控模式 | 说明 | 适用场景 |
|---------|------|---------|
| **直接** | 对当前资源直接限流 | 接口级限流，如创建订单不超过 100 QPS |
| **关联** | 当关联资源达到阈值时，限流当前资源 | 读写分离场景，写操作超过阈值时限制读操作 |
| **链路** | 根据调用链路入口限流 | 多个入口调用同一资源时差异化限流 |

---

## 五、Feign 远程调用与负载均衡

### 5.1 引入 Feign

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-openfeign</artifactId>
</dependency>
```

### 5.2 声明式远程调用

```java
// 库存服务客户端
@FeignClient(
    name = "storage-service",
    path = "/storage",
    fallbackFactory = StorageClientFallbackFactory.class
)
public interface StorageClient {

    @PostMapping("/deduct")
    Result deductStock(@RequestBody DeductRequest request);

    @GetMapping("/query/{skuId}")
    Result<StockInfo> queryStock(@PathVariable("skuId") String skuId);
}

// 账户服务客户端
@FeignClient(
    name = "account-service",
    path = "/account",
    configuration = AccountFeignConfig.class
)
public interface AccountClient {

    @PostMapping("/debit")
    Result debit(@RequestBody DebitDTO dto);
}
```

### 5.3 统一的降级处理

```java
@Slf4j
@Component
public class StorageClientFallbackFactory implements FallbackFactory<StorageClient> {

    @Override
    public StorageClient create(Throwable cause) {
        return new StorageClient() {
            @Override
            public Result deductStock(DeductRequest request) {
                log.error("调用库存服务扣减失败，skuId: {}, cause: {}",
                    request.getSkuId(), cause.getMessage());
                return Result.error("库存服务暂时不可用");
            }

            @Override
            public Result<StockInfo> queryStock(String skuId) {
                log.error("查询库存失败，skuId: {}, cause: {}", skuId, cause.getMessage());
                return Result.error("查询库存失败");
            }
        };
    }
}
```

### 5.4 Feign 高级配置

```yaml
feign:
  client:
    config:
      default:
        connect-timeout: 5000
        read-timeout: 10000
        logger-level: BASIC
      storage-service:
        connect-timeout: 3000
        read-timeout: 5000
  compression:
    request:
      enabled: true
      mime-types: application/json
      min-request-size: 2048
    response:
      enabled: true
  circuitbreaker:
    enabled: true
```

### 5.5 请求拦截器——传递 Trace ID

```java
@Component
public class FeignRequestInterceptor implements RequestInterceptor {

    @Override
    public void apply(RequestTemplate template) {
        // 传递 Trace ID 用于全链路追踪
        String traceId = MDC.get("traceId");
        if (StringUtils.hasText(traceId)) {
            template.header("X-Trace-Id", traceId);
        }

        // 传递认证 Token
        ServletRequestAttributes attributes =
            (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
        if (attributes != null) {
            HttpServletRequest request = attributes.getRequest();
            String token = request.getHeader("Authorization");
            if (StringUtils.hasText(token)) {
                template.header("Authorization", token);
            }
        }
    }
}
```

---

## 六、Gateway 网关

### 6.1 引入依赖

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-gateway</artifactId>
</dependency>
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

### 6.2 配置路由规则

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
            - StripPrefix=1
            - name: RequestRateLimiter
              args:
                key-resolver: "#{@userKeyResolver}"
                redis-rate-limiter.replenishRate: 100
                redis-rate-limiter.burstCapacity: 200
            - name: CircuitBreaker
              args:
                name: orderCircuitBreaker
                fallbackUri: forward:/fallback/order

        - id: storage-service
          uri: lb://storage-service
          predicates:
            - Path=/api/storage/**
          filters:
            - StripPrefix=1
            - AddRequestHeader=X-Request-Source, gateway

        - id: auth-service
          uri: lb://auth-service
          predicates:
            - Path=/api/auth/**
          filters:
            - StripPrefix=1

      globalcors:
        cors-configurations:
          '[/**]':
            allowedOrigins: "http://localhost:3000"
            allowedMethods:
              - GET
              - POST
              - PUT
              - DELETE
            allowedHeaders: "*"
            allowCredentials: true
```

### 6.3 全局过滤器——认证拦截

```java
@Component
@Order(-1)
public class AuthGlobalFilter implements GlobalFilter {

    // 白名单路径
    private static final List<String> WHITE_LIST = Arrays.asList(
        "/api/auth/login",
        "/api/auth/register",
        "/api/auth/refresh",
        "/fallback/"
    );

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String path = exchange.getRequest().getURI().getPath();

        // 白名单直接放行
        if (WHITE_LIST.stream().anyMatch(path::startsWith)) {
            return chain.filter(exchange);
        }

        // 从 Header 获取 Token
        String token = exchange.getRequest().getHeaders()
            .getFirst("Authorization");

        if (!StringUtils.hasText(token) || !token.startsWith("Bearer ")) {
            exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
            return exchange.getResponse().setComplete();
        }

        // 验证 Token（可调用远程服务或本地 JWT 校验）
        String jwt = token.substring(7);
        try {
            Claims claims = Jwts.parserBuilder()
                .setSigningKey(SECRET_KEY)
                .build()
                .parseClaimsJws(jwt)
                .getBody();

            // 将用户信息放入 Header 传递到下游服务
            ServerWebExchange modifiedExchange = exchange.mutate()
                .request(r -> r.header("X-User-Id", claims.get("userId").toString())
                              .header("X-User-Name", claims.get("userName").toString()))
                .build();

            return chain.filter(modifiedExchange);
        } catch (JwtException e) {
            exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
            return exchange.getResponse().setComplete();
        }
    }
}
```

### 6.4 路由谓词工厂

Spring Cloud Gateway 提供了丰富的内置谓词：

| 谓词 | 说明 | 示例 |
|------|------|------|
| Path | 路径匹配 | `Path=/api/order/**` |
| Header | Header 匹配 | `Header=X-Request-Version, v1` |
| Method | 请求方法 | `Method=GET,POST` |
| Query | 查询参数 | `Query=source, micro` |
| Cookie | Cookie 匹配 | `Cookie=sessionId, \\d+` |
| Before/After | 时间限流 | `After=2026-01-01T00:00:00+08:00` |
| Weight | 灰度发布 | `Weight=group1, 80` |

---

## 七、Seata 分布式事务

### 7.1 部署 Seata Server

```bash
docker run -d \
  --name seata-server \
  -p 8091:8091 \
  -p 7091:7091 \
  -e SEATA_IP=192.168.1.100 \
  -e STORE_MODE=db \
  seataio/seata-server:1.7.0
```

### 7.2 引入依赖

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-seata</artifactId>
</dependency>
```

### 7.3 AT 模式实战

AT 模式是 Seata 的核心模式，基于**两阶段提交协议**的演变，对业务代码侵入最小。

```yaml
seata:
  enabled: true
  application-id: ${spring.application.name}
  tx-service-group: default_tx_group
  service:
    vgroup-mapping:
      default_tx_group: default
    grouplist:
      default: 127.0.0.1:8091
  config:
    type: nacos
    nacos:
      server-addr: 127.0.0.1:8848
      namespace: dev
      group: SEATA_GROUP
  registry:
    type: nacos
    nacos:
      application: seata-server
      server-addr: 127.0.0.1:8848
      namespace: dev
```

### 7.4 分布式事务入口——下单业务

```java
@Service
public class OrderServiceImpl implements OrderService {

    @Autowired
    private OrderMapper orderMapper;
    @Autowired
    private StorageClient storageClient;
    @Autowired
    private AccountClient accountClient;

    @Override
    @GlobalTransactional(name = "create-order-tx", rollbackFor = Exception.class)
    @GlobalLock
    public OrderVO placeOrder(PlaceOrderRequest request) {
        // 1. 创建本地订单（状态为待支付）
        Order order = Order.builder()
            .userId(request.getUserId())
            .skuId(request.getSkuId())
            .count(request.getCount())
            .amount(request.getAmount())
            .status(OrderStatus.PENDING)
            .createTime(LocalDateTime.now())
            .build();
        orderMapper.insert(order);

        // 2. 远程调用：扣减库存
        Result stockResult = storageClient.deductStock(
            new DeductRequest(request.getSkuId(), request.getCount()));
        if (!stockResult.isSuccess()) {
            throw new RuntimeException("库存扣减失败: " + stockResult.getMessage());
        }

        // 3. 远程调用：扣减账户余额
        Result accountResult = accountClient.debit(
            new DebitDTO(request.getUserId(), request.getAmount()));
        if (!accountResult.isSuccess()) {
            throw new RuntimeException("账户扣款失败: " + accountResult.getMessage());
        }

        // 4. 更新订单状态为已完成
        order.setStatus(OrderStatus.COMPLETED);
        orderMapper.updateById(order);

        return OrderVO.from(order);
    }
}
```

### 7.5 分支事务——库存服务的参与

```java
@Slf4j
@Service
public class StorageServiceImpl implements StorageService {

    @Autowired
    private StorageMapper storageMapper;

    @Override
    @Transactional(rollbackFor = Exception.class)
    public void deduct(String skuId, Integer count) {
        // 查询库存
        Storage storage = storageMapper.selectBySkuId(skuId);
        if (storage == null) {
            throw new RuntimeException("库存记录不存在");
        }

        log.info("当前库存：{}，扣减数量：{}", storage.getStock(), count);

        // 执行扣减
        int updated = storageMapper.deductStock(skuId, count);
        if (updated == 0) {
            throw new RuntimeException("库存不足");
        }

        // 此处无需额外代码！Seata AT 模式会自动：
        // 1. 生成 UNDO_LOG 记录（回滚时使用）
        // 2. 注册分支事务到 TC
        // 3. 二阶段提交或回滚
    }
}
```

### 7.6 Seata 三种模式对比

| 模式 | 原理 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| **AT** | 自动解析 SQL，生成前后镜像 + UNDO_LOG | 侵入性极小，代码零改造 | 性能开销较大，不支持多表 JOIN | 大部分业务场景，推荐优先使用 |
| **TCC** | Try-Confirm-Cancel 三阶段 | 性能高，粒度控制灵活 | 需要业务实现三阶段接口，侵入性强 | 高并发场景，短事务 |
| **SAGA** | 编排式补偿 | 支持长事务，异步执行 | 补偿逻辑复杂，无隔离性 | 长事务、业务流程编排 |

---

## 八、全链路监控与总结

### 8.1 整合 Sleuth + Zipkin

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-sleuth</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-sleuth-zipkin</artifactId>
</dependency>
```

```yaml
spring:
  zipkin:
    base-url: http://localhost:9411
    sender:
      type: web
  sleuth:
    sampler:
      probability: 1.0   # 生产环境建议调低，如 0.1
```

### 8.2 生产环境最佳实践清单

1. **Nacos 集群化**：至少 3 节点，搭配 MySQL 存储，避免单点故障
2. **Sentinel 规则持久化**：通过 Nacos 配置源持久化规则，避免重启丢失
3. **Seata 使用 DB 模式**：File 模式不适用于生产，必须切换为 DB
4. **Gateway 限流**：务必配置全局限流，防止突发流量打垮后端
5. **配置刷新**：谨慎使用 `@RefreshScope`，它对 `@Bean` 方法可能触发意想不到的销毁重建
6. **健康检查**：配置 Spring Boot Actuator + Nacos 心跳探测

### 8.3 总结

Spring Cloud Alibaba 已经形成了一个完整的微服务生态体系。从 Nacos 的服务治理，到 Sentinel 的流量防护，再到 Seata 的分布式事务保证，这套技术栈在国内互联网公司中得到了充分的验证。

掌握了这套全家桶，你基本就能应对 90% 以上的微服务架构场景。但切记：**技术选型没有银弹**，要根据业务场景合理选择组件，避免为了微服务而微服务。

如果你正在从 Spring Cloud Netflix 迁移，可以从 Nacos 替换 Eureka 开始，逐步引入 Sentinel 和 Seata，平稳过渡到 Alibaba 体系。希望本文能给你的落地实战带来帮助！
