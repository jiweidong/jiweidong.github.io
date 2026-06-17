---
title: 可观测性三支柱：Metrics、Logs 与 Traces 统一实战
date: 2026-06-17 14:00:00
tags:
  - 可观测性
  - Metrics
  - 日志
  - 链路追踪
  - Observability
categories:
  - 架构设计
author: 东哥
---

# 可观测性三支柱：Metrics、Logs 与 Traces 统一实战

## 一、可观测性 vs 监控

很多人认为"可观测性（Observability）就是监控"，其实不然。监控是你知道要问什么问题，所以设置告警；可观测性是你不知道问题是什么，但系统能让你找到答案。

### 1.1 三支柱定义

| 支柱 | 定义 | 典型问题 | 工具 |
|------|------|---------|------|
| Metrics（指标） | 聚合的、时序的数字 | 现在的 QPS 是多少？ | Prometheus + Grafana |
| Logs（日志） | 离散的事件记录 | 这个请求的参数是什么？ | ELK / Loki |
| Traces（链路追踪） | 请求的调用链 | 这次请求慢在哪个环节？ | Jaeger / Zipkin |

### 1.2 三者的关系

```
                    ┌─────────────┐
                    │   Metrics   │
                    │  "系统在做什么" │
                    │  QPS=1000   │
                    │  延迟P99=200ms│
                    └──────┬──────┘
                           │
            发现延迟上升 ──►│
                           │
                    ┌──────▼──────┐
                    │   Traces    │
                    │  "请求去了哪里"│
                    │  调用链展开   │
                    │  发现 Redis   │
                    │  耗时500ms   │
                    └──────┬──────┘
                           │
            定位到具体请求─►│
                           │
                    ┌──────▼──────┐
                    │    Logs     │
                    │  "到底发生了什么"│
                    │  查看错误日志  │
                    │  Redis 连接   │
                    │  超时异常     │
                    └─────────────┘
```

实际排查时的完整链路：
1. **Grafana 面板** 发现订单接口 P99 延迟从 50ms 飙升到 500ms
2. **Jaeger 查看链路**，发现耗时集中在 Redis 调用（占 450ms）
3. **ELK 搜索日志**，确认 `redis.clients.jedis.exceptions.JedisConnectionException`
4. **结论**：Redis 集群某个节点网络抖动，触发告警由 SRE 处理

## 二、Metrics：指标采集体系

### 2.1 四大黄金信号

Google SRE 提出的四大黄金信号：

| 信号 | 含义 | 指标示例 |
|------|------|---------|
| 延迟 Latency | 请求处理时间 | `http_request_duration_seconds` |
| 流量 Traffic | 系统负载 | `http_requests_total` |
| 错误 Errors | 失败率 | `http_requests_errors_total` |
| 饱和度 Saturation | 资源占用 | `jvm_memory_used_bytes` |

### 2.2 自定义指标埋点

```java
@Component
public class BusinessMetrics {
    
    private final MeterRegistry registry;
    
    // 订单相关指标
    private final Counter orderCreateCounter;
    private final Timer orderCreateTimer;
    private final Counter orderCancelCounter;
    
    // 库存相关指标
    private final Gauge stockGauge;
    
    public BusinessMetrics(MeterRegistry registry) {
        this.registry = registry;
        
        orderCreateCounter = Counter.builder("business.order.create.total")
            .tag("service", "order-service")
            .description("订单创建总数")
            .register(registry);
        
        orderCreateTimer = Timer.builder("business.order.create.duration")
            .tag("service", "order-service")
            .publishPercentiles(0.5, 0.9, 0.95, 0.99)
            .publishPercentileHistogram()
            .register(registry);
        
        orderCancelCounter = Counter.builder("business.order.cancel.total")
            .tag("service", "order-service")
            .register(registry);
        
        stockGauge = Gauge.builder("business.stock.remaining", this,
                BusinessMetrics::getTotalRemainingStock)
            .tag("service", "order-service")
            .register(registry);
    }
    
    // 业务方法埋点
    public void recordOrderCreate(long durationMs) {
        orderCreateCounter.increment();
        orderCreateTimer.record(Duration.ofMillis(durationMs));
    }
    
    public void recordOrderCancel(String reason) {
        orderCancelCounter.increment();
        // 多维度标签
        Counter.builder("business.order.cancel.reason")
            .tag("reason", reason)
            .register(registry)
            .increment();
    }
    
    private int getTotalRemainingStock() {
        return 10000;  // mock
    }
}
```

### 2.3 告警规则配置

```yaml
# prometheus-alerts.yml
groups:
  - name: application-alerts
    rules:
      # 高错误率告警
      - alert: HighErrorRate
        expr: |
          rate(http_requests_total{status=~"5.."}[5m]) 
          /
          rate(http_requests_total[5m]) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "错误率超过 5%"
          description: "服务 {{ $labels.service }} 错误率 {{ $value | humanizePercentage }}"
      
      # P99 延迟告警
      - alert: HighLatency
        expr: |
          histogram_quantile(0.99, 
            rate(http_request_duration_seconds_bucket[5m])
          ) > 1
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "P99 延迟超过 1 秒"
```

## 三、Logs：日志体系

### 3.1 结构化日志

告别 `log.info("order created: " + orderId)` 的字符串拼接，使用结构化日志：

```java
@Slf4j
@Service
public class OrderLogger {
    
    public void logOrderCreated(Order order) {
        log.info("订单创建成功 event=order_created orderId={} userId={} amount={}",
            order.getId(), order.getUserId(), order.getTotalAmount());
    }
    
    public void logOrderFailed(Order order, String reason) {
        log.warn("订单创建失败 event=order_failed orderId={} userId={} reason={}",
            order.getId(), order.getUserId(), reason);
    }
    
    public void logPaymentTimeout(Long orderId) {
        log.error("支付超时 event=payment_timeout orderId={}", orderId);
    }
}
```

结构化日志配合 JSON 格式输出：

```xml
<!-- logback-spring.xml -->
<appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
        <!-- 添加额外字段 -->
        <customFields>{"service":"order-service","env":"prod"}</customFields>
    </encoder>
</appender>
```

### 3.2 日志采集架构

```
                     ┌─────────────────────────────────┐
                     │      Log 采集流程                │
                     │                                  │
  App ──► File ──► Filebeat ──► Kafka ──► Logstash ──► Elasticsearch
                     │                                  │
                     │                                  ▼
                     │                            ┌──────────┐
                     │                            │ Kibana   │
                     │                            │ 查询/可视化│
                     │                            └──────────┘
                     │
  App ──► stdout ──► Docker                  ┌──────────┐
                     │   json-file           │ Loki     │
                     └──────────────────────►│          │
                                             │ Grafana  │
                                             └──────────┘
```

### 3.3 日志查询最佳实践

```bash
# Kibana / Loki 查询示例

# 查找特定 traceId 的所有日志
{trace_id="abc123def456"}

# 查找某个接口的慢请求
{service="order-service"} |= "order_created" | json | duration > 1000

# 查找错误日志并按分钟聚合
{service="payment-service"} |= "ERROR" 
| json 
| rate by (5m)
```

| 日志级别 | 使用场景 | 生产环境策略 |
|---------|---------|------------|
| TRACE | 开发调试详细输出 | 关闭 |
| DEBUG | 临时排查问题 | 按需开启特定包 |
| INFO | 关键业务事件 | 开启（控制频率） |
| WARN | 可恢复的异常 | 开启 + 告警 |
| ERROR | 严重的异常 | 开启 + 告警 |

## 四、Traces：链路追踪

### 4.1 分布式追踪原理

OpenTelemetry 是目前最主流的可观测性标准，它定义了 Trace、Span、SpanContext 等概念：

```
一个 Trace 包含多个 Span:
─────────────────────────────────────────────────────
│ Trace ID: abc123                                    │
│                                                       │
│ Span A (Root): POST /api/orders                      │
│ ├── Span B: AuthService.validateToken()              │
│ ├── Span C: OrderService.createOrder()              │
│ │   ├── Span D: InventoryService.deduct()           │
│ │   │   └── Span E: Redis.incr()                    │
│ │   └── Span F: PaymentService.charge()             │
│ └── Span G: NotificationService.send()               │
└─────────────────────────────────────────────────────┘

时间轴:
A: ──────────────────────────────────────
B:   ──────
C:             ──────────────────────────
D:                  ────────────
E:                       ──
F:                             ────────
G:                                       ────
```

### 4.2 Spring Boot 集成 OpenTelemetry

```xml
<dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-spring-boot-starter</artifactId>
    <version>1.32.0</version>
</dependency>
```

```yaml
# application.yml
otel:
  service:
    name: order-service
  traces:
    exporter:
      endpoint: http://jaeger:4318/v1/traces
  resource:
    attributes:
      service.version: 1.0.0
      deployment.environment: production
```

### 4.3 自定义 Span

```java
@Component
public class CustomSpanService {
    
    private final Tracer tracer;
    private final OrderRepository orderRepository;
    
    public CustomSpanService(OpenTelemetry openTelemetry) {
        this.tracer = openTelemetry.getTracer("order-service");
    }
    
    public Order processCustomFlow(Long orderId) {
        // 创建自定义 Span
        Span customSpan = tracer.spanBuilder("processCustomFlow")
            .setAttribute("orderId", orderId)
            .setAttribute("processType", "special")
            .startSpan();
        
        // 将 Span 放入上下文
        try (Scope scope = customSpan.makeCurrent()) {
            // 在这个上下文中执行的所有操作都会自动关联到此 Span
            
            // 添加事件
            customSpan.addEvent("Start processing order");
            
            Order order = orderRepository.findById(orderId);
            
            // 异步操作
            CompletableFuture.runAsync(() -> {
                Span childSpan = tracer.spanBuilder("asyncTask")
                    .setParent(Context.current().with(customSpan))
                    .startSpan();
                try (Scope childScope = childSpan.makeCurrent()) {
                    // 异步操作
                    processAsync(order);
                    childSpan.setStatus(StatusCode.OK);
                } catch (Exception e) {
                    childSpan.recordException(e);
                    childSpan.setStatus(StatusCode.ERROR);
                } finally {
                    childSpan.end();
                }
            });
            
            customSpan.addEvent("Order processed");
            customSpan.setAttribute("processedItems", order.getItems().size());
            
            return order;
        } catch (Exception e) {
            customSpan.recordException(e);
            customSpan.setStatus(StatusCode.ERROR);
            throw e;
        } finally {
            customSpan.end();
        }
    }
}
```

### 4.4 多服务串联

在网关或拦截器中传递 Trace Context：

```java
@Component
public class TraceInterceptor implements WebMvcConfigurer {
    
    // 自动通过 HTTP Headers 传递 Trace 上下文
    // opentelemetry-java-instrumentation 会自动处理
    // 支持的 header: traceparent, tracestate
    
    // 如果使用 RestTemplate，自动注入拦截器
    @Bean
    public RestTemplate restTemplate(RestTemplateBuilder builder) {
        return builder.build();  // OpenTelemetry 自动注入
    }
}

// 监听异步事件时传递上下文
@Service
public class EventBridge {
    
    @EventListener
    public void handleOrderCreated(OrderCreatedEvent event) {
        // OpenTelemetry 自动从事件线程上下文继承
        // 确保在 @Async 方法中传递 Context
    }
}
```

## 五、三支柱统一：Grafana 集成

Grafana 从 8.x 开始支持统一的可观测性体验：

```yaml
# docker-compose 部署统一可观测性栈
version: '3.8'
services:
  # 指标
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - prometheus-data:/prometheus
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
  
  # 日志
  loki:
    image: grafana/loki:latest
    ports:
      - "3100:3100"
  
  # 追踪
  tempo:
    image: grafana/tempo:latest
    command: ["-config.file=/etc/tempo.yaml"]
    volumes:
      - ./tempo.yaml:/etc/tempo.yaml
  
  # 统一展示
  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_INSTALL_PLUGINS=grafana-trace-app
```

### 5.1 从 Metrics 到 Traces 的关联

在 Grafana Explore 中，可以配置 Metrics 到 Traces 的关联：

```yaml
# grafana.ini
[explore]
# 启用 Metrics → Traces 关联
# Prometheus 中的 trace_id label 会关联到 Tempo
```

配置完成后，在 Grafana 面板中点击任意指标数据点，可以直接跳转到对应的 Trace，再通过 Trace 中记录的 span ID 去 Loki 中查询对应日志。

## 六、生产环境常见问题

| 问题 | 表现 | 排查方法 |
|------|------|---------|
| 指标打爆 Prometheus | 时序数据库快速增长 | 控制指标基数，减少高基数标签 |
| 日志量过大 | ES 磁盘满 | 设置日志采样，控制 INFO 级别 |
| Trace 采样率太高 | Jaeger 存储暴涨 | 使用"头采样" + "尾采样"组合策略 |
| 指标与日志关联不上 | 查日志找不到对应 trace | 统一 trace_id 的传递和格式 |

### 6.1 智能采样策略

```java
@Component
public class SamplerConfig {
    
    @Bean
    public Sampler sampler() {
        // 高 QPS 接口只采样 10%
        // 错误请求 100% 采样
        // 慢请求 100% 采样
        return new MyCustomSampler();
    }
}

class MyCustomSampler implements Sampler {
    private static final Sampler defaultSampler = Sampler.traceIdRatioBased(0.1);
    
    @Override
    public SamplingResult shouldSample(Context context, 
                                        TraceId traceId, 
                                        String name, 
                                        SpanKind spanKind, 
                                        Attributes attributes, 
                                        Context parentContext) {
        
        // 错误或慢请求 100% 采样
        if (attributes.get(SemanticAttributes.HTTP_STATUS_CODE) != null) {
            int status = attributes.get(SemanticAttributes.HTTP_STATUS_CODE);
            if (status >= 400) {
                return SamplingResult.create(SamplingDecision.RECORD_AND_SAMPLE);
            }
        }
        
        return defaultSampler.shouldSample(
            context, traceId, name, spanKind, 
            attributes, parentContext);
    }
    
    @Override
    public String getDescription() {
        return "Error-full, Others-sampled";
    }
}
```

可观测性的核心理念是**让系统的内部状态可以向外导出**。好的可观测性建设，不是堆砌更多的监控工具，而是让 Metrics、Logs、Traces 三者打通、互相印证，形成完整的"故障诊断闭环"。当这三者在小范围内就能衔接自如时，任何线上问题都能在几分钟内定位。
