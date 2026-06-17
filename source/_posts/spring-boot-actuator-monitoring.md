---
title: Spring Boot Actuator与生产级监控最佳实践
date: 2026-06-17 08:00:00
tags:
  - Spring Boot
  - Actuator
  - 监控
  - Micrometer
categories:
  - Spring
author: 东哥
---

# Spring Boot Actuator与生产级监控最佳实践

在生产环境中，仅仅把应用跑起来是远远不够的。我们需要实时了解应用的运行状态、性能指标、健康情况，才能在问题发生前预警、在故障发生时快速定位。Spring Boot Actuator 就是 Spring Boot 生态中专门解决这一问题的利器。

## 一、Actuator 核心原理

### 1.1 什么是 Actuator

Spring Boot Actuator 是 Spring Boot 提供的生产级监控组件，它通过 HTTP Endpoint 和 JMX 两种方式暴露应用的运行时信息。其核心设计思想是 **"端点（Endpoint）即监控点"**——每个端点负责采集一类特定的监控数据。

### 1.2 端点体系架构

Actuator 的端点体系可以分为三个层次：

| 层次 | 组件 | 职责 |
|------|------|------|
| 数据采集层 | HealthIndicator / MetricsExporter / InfoContributor | 采集具体指标数据 |
| 端点管理层 | Endpoint (WebExtension) | 将数据暴露为 HTTP/JMX 端点 |
| 安全与过滤层 | CorsFilter / SecurityFilter | 控制端点访问权限 |

架构描述：

```
┌─────────────────────────────────────────────┐
│               HTTP Endpoints                │
│  /actuator/health  /actuator/metrics  ...  │
├─────────────────────────────────────────────┤
│           Endpoint 管理层 (WebMvc)           │
├─────────────────────────────────────────────┤
│  HealthIndicator  MetricsExporter  Info     │
│  Env              Beans          Loggers    │
│  ...                                       │
├─────────────────────────────────────────────┤
│            Micrometer 监控体系               │
├─────────────────────────────────────────────┤
│      JVM  | 系统 | 数据库 | 缓存 | MQ       │
└─────────────────────────────────────────────┘
```

## 二、快速集成与配置

### 2.1 Maven 依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

仅需一个依赖，Spring Boot 会自动配置所有内置端点。

### 2.2 端点配置

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,env,beans,loggers,threaddump,heapdump
        # 暴露所有端点（生产环境慎用）
        # include: "*"
    enabled-by-default: true
  endpoint:
    health:
      show-details: always
      show-components: always
    shutdown:
      enabled: false  # 安全考虑，禁止远程 shutdown
  server:
    port: 8081       # 监控端口与业务端口分离
    address: 127.0.0.1
```

### 2.3 核心端点清单

| 端点 | 路径 | 用途 | 是否敏感 |
|------|------|------|---------|
| health | /actuator/health | 应用健康检查 | 否 |
| info | /actuator/info | 自定义信息 | 否 |
| metrics | /actuator/metrics | JVM/系统指标 | 否 |
| env | /actuator/env | 环境属性 | 是 |
| beans | /actuator/beans | Bean 清单 | 是 |
| configprops | /actuator/configprops | 配置属性 | 是 |
| loggers | /actuator/loggers | 日志级别管理 | 否 |
| threaddump | /actuator/threaddump | 线程快照 | 是 |
| heapdump | /actuator/heapdump | 堆转储 | 是 |
| mappings | /actuator/mappings | 请求映射 | 否 |
| scheduledtasks | /actuator/scheduledtasks | 定时任务状态 | 否 |
| caches | /actuator/caches | 缓存管理器信息 | 否 |

## 三、自定义 HealthIndicator

### 3.1 内置健康检查

Spring Boot 内置了多种 HealthIndicator，当依赖相关的 Bean 存在时会自动生效：

- `DataSourceHealthIndicator` — 数据库连接健康
- `RedisHealthIndicator` — Redis 连接健康
- `RabbitHealthIndicator` — RabbitMQ 健康
- `ElasticsearchHealthIndicator` — ES 健康
- `MongoHealthIndicator` — MongoDB 健康
- `DiskSpaceHealthIndicator` — 磁盘空间

### 3.2 自定义业务健康检查

下面是一个检查外部 API 服务可用性的自定义示例：

```java
@Component
public class ExternalApiHealthIndicator implements HealthIndicator {
    
    private final RestTemplate restTemplate = new RestTemplate();
    
    @Value("${external.api.url}")
    private String apiUrl;
    
    @Override
    public Health health() {
        try {
            ResponseEntity<String> response = restTemplate.exchange(
                apiUrl + "/ping",
                HttpMethod.GET,
                null,
                String.class
            );
            if (response.getStatusCode().is2xxSuccessful()) {
                return Health.up()
                    .withDetail("statusCode", response.getStatusCodeValue())
                    .withDetail("responseTime", "ok")
                    .build();
            } else {
                return Health.down()
                    .withDetail("statusCode", response.getStatusCodeValue())
                    .build();
            }
        } catch (Exception e) {
            return Health.down(e)
                .withDetail("error", e.getMessage())
                .build();
        }
    }
}
```

### 3.3 聚合健康状态

健康状态的聚合逻辑是：**下级全部 UP 才返回 UP，否则返回 DOWN**。

```yaml
management:
  endpoint:
    health:
      group:
        custom:
          include: db,redis,externalApi
          show-components: always
          status:
            order: DOWN, OUT_OF_SERVICE, UNKNOWN, UP
```

这样我们可以定义一个自定义健康组，只关注关键依赖的健康状态。在 K8s 环境中，可以将 readinessProbe 和 livenessProbe 指向不同的健康组：

```yaml
# deployment.yaml
livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: 8081
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: 8081
  initialDelaySeconds: 15
  periodSeconds: 5
```

## 四、Micrometer 指标体系

### 4.1 Micrometer 架构

Spring Boot Actuator 从 2.x 开始使用 Micrometer 作为指标门面（类似 SLF4J 之于日志），支持丰富的监控后端：

```
┌──────────────────────────────────────────────────┐
│                  你的应用代码                      │
│  MeterRegistry.counter()  timer()  gauge()      │
├──────────────────────────────────────────────────┤
│                Micrometer (门面层)                │
├────────────┬──────────┬──────────┬───────────────┤
│ Prometheus │ Datadog  │  JMX     │  Graphite     │
│   Registry │ Registry │ Registry │  Registry     │
└────────────┴──────────┴──────────┴───────────────┘
```

### 4.2 核心指标类型

| 指标类型 | 接口 | 说明 | 典型场景 |
|---------|------|------|---------|
| Counter | `Counter` | 单调递增计数器 | 请求数、错误数 |
| Gauge | `Gauge` | 可增可减的值 | 当前线程数、队列大小 |
| Timer | `Timer` | 计时+计数 | 接口响应时间、SQL 执行时间 |
| DistributionSummary | `DistributionSummary` | 分布统计 | 请求体大小、批处理批次大小 |
| LongTaskTimer | `LongTaskTimer` | 长任务计时 | 定时任务执行时间 |

### 4.3 自定义埋点实战

```java
@Component
public class OrderMetricsCollector {
    
    private final Counter orderCreateCounter;
    private final Timer orderCreateTimer;
    private final Gauge pendingOrderGauge;
    private final DistributionSummary orderAmountSummary;
    
    public OrderMetricsCollector(MeterRegistry registry) {
        this.orderCreateCounter = Counter.builder("order.create.count")
            .tag("service", "order-service")
            .description("订单创建总数")
            .register(registry);
            
        this.orderCreateTimer = Timer.builder("order.create.time")
            .tag("service", "order-service")
            .description("订单创建耗时")
            .publishPercentileHistogram()
            .publishPercentiles(0.5, 0.75, 0.95, 0.99)
            .register(registry);
            
        this.pendingOrderGauge = Gauge.builder("order.pending.count", this,
                OrderMetricsCollector::getPendingOrderCount)
            .tag("service", "order-service")
            .description("待处理订单数")
            .register(registry);
            
        this.orderAmountSummary = DistributionSummary.builder("order.amount")
            .tag("service", "order-service")
            .description("订单金额分布")
            .publishPercentileHistogram()
            .minimumExpectedValue(1.0)
            .maximumExpectedValue(100000.0)
            .register(registry);
    }
    
    public void recordOrderCreated(long durationMs, double amount) {
        orderCreateCounter.increment();
        orderCreateTimer.record(Duration.ofMillis(durationMs));
        orderAmountSummary.record(amount);
    }
    
    private int getPendingOrderCount() {
        // 查询待处理订单数
        return orderRepository.countByStatus(OrderStatus.PENDING);
    }
}
```

## 五、Prometheus + Grafana 集成

### 5.1 启用 Prometheus 端点

```xml
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```yaml
management:
  endpoints:
    web:
      exposure:
        include: prometheus,health,metrics
  metrics:
    export:
      prometheus:
        enabled: true
    tags:
      application: ${spring.application.name}
```

### 5.2 Prometheus 配置

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'spring-boot-apps'
    metrics_path: '/actuator/prometheus'
    scrape_interval: 15s
    static_configs:
      - targets:
        - 'app-prod-01:8081'
        - 'app-prod-02:8081'
        labels:
          environment: 'production'
```

### 5.3 关键监控指标

| Prometheus 指标 | 含义 | 告警阈值 |
|----------------|------|---------|
| jvm_memory_used_bytes | JVM 已用内存 | > 80% heap |
| jvm_gc_pause_seconds | GC 暂停时间 | > 1s |
| http_server_requests_seconds_max | 请求最大延迟 | > 3s |
| jvm_threads_live_threads | 活跃线程数 | > 200 |
| logback_events_total | 日志事件计数 | ERROR > 0 |
| process_cpu_usage | CPU 使用率 | > 85% |

PromQL 示例：
```promql
# 99分位响应时间
histogram_quantile(0.99, 
  rate(http_server_requests_seconds_bucket{uri!~".*actuator.*"}[5m])
)

# 应用错误率
rate(http_server_requests_seconds_count{status=~"5.."}[5m])
/
rate(http_server_requests_seconds_count[5m])
* 100

# JVM 堆内存使用率
jvm_memory_used_bytes{area="heap"}
/
jvm_memory_max_bytes{area="heap"}
* 100
```

## 六、安全加固

### 6.1 敏感端点保护

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
      base-path: /internal/actuator  # 修改默认路径
      path-mapping:
        health: health-check          # 路径混淆

spring:
  security:
    user:
      name: monitor
      password: ${MONITOR_PASSWORD}
```

### 6.2 Spring Security 集成

```java
@Configuration(proxyBeanMethods = false)
public class ActuatorSecurityConfig {
    
    @Bean
    public SecurityFilterChain actuatorFilterChain(HttpSecurity http) throws Exception {
        http.securityMatcher("/actuator/**")
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health/**").permitAll()
                .requestMatchers("/actuator/info").permitAll()
                .requestMatchers("/actuator/prometheus").hasRole("MONITOR")
                .anyRequest().hasRole("ADMIN")
            )
            .httpBasic(Customizer.withDefaults())
            .csrf(AbstractHttpConfigurer::disable);
        return http.build();
    }
}
```

### 6.3 网络层防护

```yaml
# 内网专用，绑定到本地或内网 IP
management.server.port: 8081
management.server.address: 192.168.1.100
```

## 七、生产最佳实践总结

### 7.1 启用清单检查表

| 项目 | 推荐配置 | 说明 |
|------|---------|------|
| 健康检查分组 | liveness + readiness + custom | K8s 环境必备 |
| 指标暴露 | Prometheus 格式 | 统一监控标准 |
| 日志级别管理 | /actuator/loggers | 线上临时排查问题 |
| 线程 Dump | /actuator/threaddump | 死锁分析 |
| Heap Dump | /actuator/heapdump | OOM 定位 |
| 安全加固 | 修改路径 + 认证 | 防止信息泄露 |

### 7.2 常见问题

1. **Actuator 端点被外网访问**：务必绑定内网 IP 或增加认证
2. **Heap Dump 撑爆磁盘**：设置触发限流，通常在内存达到阈值时自动触发
3. **监控端口暴露过多敏感信息**：只暴露必要的端点，`env`、`configprops` 等生产环境慎用
4. **Prometheus 拉取超时**：当 JVM 发生 Full GC 时，应用可能会暂停响应，建议加大 scrape_timeout

通过合理配置 Spring Boot Actuator，再结合 Prometheus + Grafana 搭建监控体系，我们能够全方位掌握生产环境的应用状态，真正做到在看板中发现问题、在代码里定位问题、在告警前解决问题。
