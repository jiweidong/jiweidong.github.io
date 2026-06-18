---
title: OpenTelemetry 可观测性实践指南
date: 2026-06-18 08:00:00
tags:
  - OpenTelemetry
  - 可观测性
  - 分布式追踪
  - 监控
categories:
  - 运维
author: 东哥
---

# OpenTelemetry 可观测性实践指南

## 一、可观测性的三大支柱

可观测性（Observability）是云原生时代的核心能力。OpenTelemetry 作为 CNCF 的孵化项目，统一了遥测数据的采集标准，成为可观测性领域的事实标准。

### 1.1 三大信号

```
┌────────────────────────────────────────────────────────┐
│                   OpenTelemetry                          │
├─────────────┬──────────────────┬────────────────────────┤
│    Metrics  │     Traces       │        Logs           │
│  (指标)     │   (链路追踪)      │       (日志)          │
├─────────────┼──────────────────┼────────────────────────┤
│  CPU使用率   │  请求完整路径     │    应用日志文本        │
│  请求QPS    │  各服务耗时       │    错误堆栈           │
│  内存占用   │  调用依赖关系      │    业务流水记录       │
│  延迟分布   │  Span事件详情      │    审计日志           │
├─────────────┼──────────────────┼────────────────────────┤
│  ↑ "系统健不健康" │ → "请求经历了什么" │ → "具体发生了什么" │
└─────────────┴──────────────────┴────────────────────────┘
```

### 1.2 与传统监控对比

| 维度 | 传统监控 | OpenTelemetry 可观测性 |
|------|---------|----------------------|
| 数据类型 | 指标为主 | 指标+追踪+日志统一 |
| 数据采集 | 轮询 Pull | 推拉结合 Push+Pull |
| 标准化 | 厂商绑定 | 开放标准 |
| 上下文关联 | 独立 | 通过 TraceId 关联 |
| 采样策略 | 全量采集 | 智能采样+头部采样 |
| 传输协议 | HTTP/JSON | OTLP(gRPC) 高性能 |

## 二、OpenTelemetry 架构

### 2.1 核心组件

```
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│   Application │     │   Application │     │   Application │
│ ┌───────────┐│     │ ┌───────────┐│     │ ┌───────────┐│
│ │  SDK+API  ││     │ │  SDK+API  ││     │ │  SDK+API  ││
│ └─────┬─────┘│     │ └─────┬─────┘│     │ └─────┬─────┘│
│       │OTLP  │     │       │OTLP  │     │       │OTLP  │
└───────┼───────┘     └───────┼───────┘     └───────┼───────┘
        ▼                     ▼                     ▼
┌──────────────────────────────────────────────────────────────┐
│                   OpenTelemetry Collector                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Receivers│  │Processors│  │ Exporters│  │ Extensions│   │
│  │ OTLP     │  │ Batch    │  │ Jaeger   │  │ Health    │   │
│  │ Prometheus│  │ Filter   │  │ Prometheus│  │ PProf     │   │
│  │ Kafka    │  │ Sampling │  │ Loki     │  │           │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└───────────────────────┬──────────────────────────────────────┘
                        ▼
            ┌─────────────────────┐
            │    Backend Systems    │
            │  ┌────┐┌────┐┌────┐ │
            │  │Cora││Jaeg││Loki│ │
            │  │lia ││er  ││    │ │
            │  └────┘└────┘└────┘ │
            └─────────────────────┘
```

### 2.2 数据模型

```protobuf
// Trace 数据模型（简化）
message Span {
  bytes trace_id = 1;           // Trace 唯一标识
  bytes span_id = 2;            // Span 唯一标识
  bytes parent_span_id = 3;     // 父 Span ID
  string name = 4;              // Span 名称
  SpanKind kind = 5;            // Span 类型
  int64 start_time_unix_nano = 6;
  int64 end_time_unix_nano = 7;
  repeated KeyValue attributes = 8;  // 属性
  repeated SpanEvent events = 9;     // 事件
  Status status = 10;           // 状态
}

// Metric 数据模型
message Metric {
  string name = 1;
  string description = 2;
  string unit = 3;
  oneof data {
    Gauge gauge = 4;            // 瞬时值
    Sum sum = 5;                // 累积值
    Histogram histogram = 6;    // 直方图
  }
}
```

## 三、Java 应用接入 OTel

### 3.1 Maven 依赖

```xml
<!-- OpenTelemetry BOM -->
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>io.opentelemetry</groupId>
            <artifactId>opentelemetry-bom</artifactId>
            <version>1.40.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<!-- 核心依赖 -->
<dependencies>
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-api</artifactId>
    </dependency>
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-sdk</artifactId>
    </dependency>
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-exporter-otlp</artifactId>
    </dependency>
    <!-- 自动注入 agent -->
    <dependency>
        <groupId>io.opentelemetry</groupId>
        <artifactId>opentelemetry-extension-annotations</artifactId>
    </dependency>
</dependencies>
```

### 3.2 Java Agent 零代码接入

```bash
# 下载 OTel Java Agent
wget https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.6.0/opentelemetry-javaagent.jar

# 启动应用（零代码接入）
java -javaagent:opentelemetry-javaagent.jar \
     -Dotel.service.name=order-service \
     -Dotel.traces.exporter=otlp \
     -Dotel.metrics.exporter=otlp \
     -Dotel.logs.exporter=otlp \
     -Dotel.exporter.otlp.endpoint=http://otel-collector:4318 \
     -jar order-service.jar
```

### 3.3 手动埋点（代码级）

```java
@RestController
@RequestMapping("/api/orders")
public class OrderController {
    
    private static final Tracer tracer = 
        GlobalOpenTelemetry.getTracer("order-service");
    
    private final Meter meter = 
        GlobalOpenTelemetry.getMeter("order-service");
    
    private final DoubleHistogram orderAmountHistogram = 
        meter.histogramBuilder("order.amount")
            .setDescription("订单金额分布")
            .setUnit("CNY")
            .build();
    
    private final LongCounter orderCounter = 
        meter.counterBuilder("order.created.total")
            .setDescription("创建订单总数")
            .build();
    
    @PostMapping
    public ResponseEntity<OrderResponse> createOrder(
            @RequestBody @Valid CreateOrderRequest request) {
        
        Span span = tracer.spanBuilder("createOrder")
                .setSpanKind(SpanKind.SERVER)
                .startSpan();
        
        try (Scope scope = span.makeCurrent()) {
            span.setAttribute("user.id", request.userId());
            span.setAttribute("order.items.count", request.items().size());
            
            // 调用下游服务
            OrderResponse response = processOrder(request);
            
            // 记录业务指标
            orderCounter.add(1);
            orderAmountHistogram.record(response.totalAmount().doubleValue());
            
            return ResponseEntity.status(HttpStatus.CREATED).body(response);
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }
    
    // 使用注解的方式
    @WithSpan("validateInventory")
    public boolean validateInventory(List<OrderItem> items) {
        Span span = Span.current();
        span.addEvent("开始库存校验", 
            Attributes.of(AttributeKey.stringKey("items"), items.toString()));
        
        boolean valid = inventoryService.check(items);
        
        span.setAttribute("inventory.valid", valid);
        return valid;
    }
}
```

### 3.4 上下文传播

```java
// 手动传播 Trace 上下文
@Service
public class OrderService {
    
    private final RestTemplate restTemplate;
    private final TextMapPropagator propagator;
    
    public OrderService(RestTemplate restTemplate) {
        this.restTemplate = restTemplate;
        this.propagator = OpenTelemetry.getGlobalPropagators()
            .getTextMapPropagator();
    }
    
    public PaymentResult callPaymentService(Order order) {
        // 注入 Trace 上下文到 HTTP 请求头
        HttpHeaders headers = new HttpHeaders();
        propagator.inject(Context.current(), headers, (carrier, key, value) -> {
            carrier.set(key, value);
        });
        
        HttpEntity<PaymentRequest> entity = new HttpEntity<>(
            new PaymentRequest(order), headers);
        
        return restTemplate.postForObject(
            "http://payment-service/api/payments", 
            entity, PaymentResult.class);
    }
}
```

## 四、OpenTelemetry Collector 部署

### 4.1 Collector 配置

```yaml
# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  # 从 Prometheus 抓取的指标
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector'
          scrape_interval: 10s
          static_configs:
            - targets: ['localhost:8888']

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  # 尾部采样（基于错误率）
  tail_sampling:
    policies:
      - name: error-sampling
        type: status_code
        config:
          status_code: ERROR
          sampling_percentage: 100
      - name: slow-request-sampling
        type: latency
        config:
          threshold_ms: 500
          sampling_percentage: 50

exporters:
  # 发送到 Jaeger（Trace）
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
  # 发送到 Prometheus（Metric）
  prometheus:
    endpoint: 0.0.0.0:8889
  # 发送到 Loki（Log）
  loki:
    endpoint: http://loki:3100/loki/api/v1/push

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, tail_sampling]
      exporters: [otlp/jaeger]
    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [loki]
```

### 4.2 Docker Compose 部署

```yaml
version: '3.8'
services:
  # OpenTelemetry Collector
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.105.0
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml
    ports:
      - "4317:4317"   # OTLP gRPC
      - "4318:4318"   # OTLP HTTP
      - "8888:8888"   # Collector 自身指标
      - "8889:8889"   # Prometheus 导出
  
  # 后端存储
  jaeger:
    image: jaegertracing/all-in-one:1.60
    environment:
      - COLLECTOR_OTLP_ENABLED=true
    ports:
      - "16686:16686"  # UI
  
  prometheus:
    image: prom/prometheus:v2.53.0
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"
  
  grafana:
    image: grafana/grafana:11.1.0
    environment:
      - GF_AUTH_ANONYMOUS_ENABLED=true
    ports:
      - "3000:3000"
    volumes:
      - ./grafana-datasources:/etc/grafana/provisioning/datasources
```

### 4.3 Kubernetes 部署

```yaml
# otel-collector.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  config.yaml: |-
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 1s
    exporters:
      otlp:
        endpoint: jaeger:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
      - name: otel-collector
        image: otel/opentelemetry-collector-contrib:0.105.0
        args: ["--config=/conf/config.yaml"]
        ports:
        - containerPort: 4317
        - containerPort: 4318
        volumeMounts:
        - name: config
          mountPath: /conf
      volumes:
      - name: config
        configMap:
          name: otel-collector-config
```

## 五、高级功能

### 5.1 采样策略

```java
// 基于头部采样
@Bean
public Sampler sampler() {
    // 默认采样率 10%
    return Sampler.parentBased(Sampler.traceIdRatioBased(0.1));
}

// 基于请求路径的采样
public class PathBasedSampler implements Sampler {
    
    private final Sampler defaultSampler = Sampler.traceIdRatioBased(0.1);
    private final Set<String> highPriorityPaths = Set.of("/api/payments", "/api/orders");
    
    @Override
    public SamplingResult shouldSample(SpanContext parentContext, 
                                       String traceId,
                                       String name, 
                                       SpanKind spanKind,
                                       Attributes attributes,
                                       Context parentLinks) {
        // 高优先级路径全量采样
        if (highPriorityPaths.stream().anyMatch(name::startsWith)) {
            return SamplingResult.recordAndSample();
        }
        return defaultSampler.shouldSample(parentContext, traceId, 
                                          name, spanKind, attributes, parentLinks);
    }
    
    @Override
    public String getDescription() {
        return "PathBasedSampler";
    }
}
```

### 5.2 自定义 Processor

```java
// 在 Collector 中运行的自定义 Processor
public class RedactionProcessor implements SpanProcessor {
    
    private static final Set<String> SENSITIVE_KEYS = 
        Set.of("password", "token", "secret", "credit_card");
    
    @Override
    public void onStart(Context context, ReadWriteSpan span) {
        // 开始时不处理
    }
    
    @Override
    public boolean isStartRequired() {
        return false;
    }
    
    @Override
    public void onEnd(ReadableSpan span) {
        span.toSpanData().getAttributes().forEach((key, value) -> {
            if (SENSITIVE_KEYS.contains(key.getKey())) {
                span.setAttribute(key.getKey(), "[REDACTED]");
            }
        });
    }
    
    @Override
    public boolean isEndRequired() {
        return true;
    }
}
```

## 六、与 Spring Boot 集成

### 6.1 Spring Boot 3.x 自动配置

```yaml
# application.yml
otel:
  service:
    name: order-service
  exporter:
    otlp:
      endpoint: http://otel-collector:4318
  traces:
    sampler: parentbased_traceidratio
    sampler.arg: "0.1"
  resource:
    attributes:
      environment: production
      region: cn-shanghai
      version: 2.1.0
```

```java
@Configuration
public class ObservabilityConfiguration {
    
    @Bean
    public OpenTelemetry openTelemetry() {
        Resource resource = Resource.getDefault().toBuilder()
            .put("service.name", "order-service")
            .put("deployment.environment", "production")
            .put("service.version", "2.1.0")
            .build();
        
        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
            .setResource(resource)
            .addSpanProcessor(BatchSpanProcessor.builder(
                OtlpGrpcSpanExporter.builder()
                    .setEndpoint("http://otel-collector:4317")
                    .build())
                .build())
            .setSampler(Sampler.traceIdRatioBased(0.1))
            .build();
        
        SdkMeterProvider meterProvider = SdkMeterProvider.builder()
            .setResource(resource)
            .registerMetricReader(PeriodicMetricReader.builder(
                OtlpGrpcMetricExporter.builder()
                    .setEndpoint("http://otel-collector:4317")
                    .build())
                .setInterval(Duration.ofSeconds(30))
                .build())
            .build();
        
        return OpenTelemetrySdk.builder()
            .setTracerProvider(tracerProvider)
            .setMeterProvider(meterProvider)
            .setPropagators(ContextPropagators.create(
                W3CTraceContextPropagator.getInstance()))
            .build();
    }
}
```

### 6.2 自定义指标

```java
@Component
public class BusinessMetrics {
    
    private final Meter meter;
    private final LongCounter orderCreateCounter;
    private final DoubleHistogram orderProcessingTime;
    private final LongUpDownCounter activeOrdersGauge;
    
    public BusinessMetrics(Meter meter) {
        this.meter = meter;
        
        this.orderCreateCounter = meter
            .counterBuilder("orders.created")
            .setDescription("订单创建总数")
            .build();
        
        this.orderProcessingTime = meter
            .histogramBuilder("orders.processing.time")
            .setDescription("订单处理时间")
            .setUnit("ms")
            .setExplicitBucketBoundariesAdvice(List.of(10.0, 50.0, 100.0, 200.0, 
                500.0, 1000.0, 2000.0, 5000.0))
            .build();
        
        this.activeOrdersGauge = meter
            .upDownCounterBuilder("orders.active")
            .setDescription("当前活跃订单数")
            .build();
    }
    
    @WithSpan("processOrderMetrics")
    public void recordOrderMetrics(Order order, long processingTimeMs) {
        // 按订单类型记录
        Attributes attributes = Attributes.of(
            AttributeKey.stringKey("order.type"), order.type(),
            AttributeKey.stringKey("payment.method"), order.paymentMethod(),
            AttributeKey.stringKey("region"), order.region()
        );
        
        orderCreateCounter.add(1, attributes);
        orderProcessingTime.record(processingTimeMs, attributes);
        activeOrdersGauge.add(1);
    }
}
```

## 七、告警与 SLO

### 7.1 Prometheus 告警规则

```yaml
# alerts.yaml
groups:
- name: otel-alerts
  rules:
  # 高错误率告警
  - alert: HighErrorRate
    expr: |
      sum(rate(http.server.duration{status_code=~"5.."}[5m])) 
      / sum(rate(http.server.duration[5m])) > 0.01
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "服务错误率超过 1%"
      description: "服务 {{ $labels.service }} 错误率 {{ $value | humanizePercentage }}"
  
  # 高延迟告警
  - alert: HighLatency
    expr: |
      histogram_quantile(0.99, rate(http.server.duration_bucket[5m])) > 1000
    for: 3m
    labels:
      severity: warning
    annotations:
      summary: "P99 延迟超过 1s"
  
  # 链路错误
  - alert: TraceErrorDetected
    expr: |
      rate(traces.span_count{status_code="ERROR"}[5m]) > 0
    for: 1m
    labels:
      severity: warning
```

### 7.2 SLO 定义

```yaml
# service-level.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceLevelObjective
metadata:
  name: order-service-availability
spec:
  service: order-service
  description: "订单服务可用性 SLO"
  target: 99.9
  window: 28d
  indicator:
    ratio:
      errors:
        metric: http.server.duration_count{status_code!~"5.."}
      total:
        metric: http.server.duration_count
```

## 八、常见问题排查

| 问题 | 原因 | 排查方法 | 解决方案 |
|------|------|---------|---------|
| 无追踪数据 | Agent 未正确挂载 | 检查 JVM 参数 | 使用 -javaagent 正确路径 |
| 采样率异常 | 采样策略配置错误 | 检查 Sampler 配置 | 调整 traceIdRatioBased |
| Collector OOM | 内存限制未设置 | 监控 Collector 内存 | 启用 memory_limiter processor |
| 上下文丢失 | 异步线程未传播 | 检查线程池包装 | 使用 Context.taskWrapping |
| 时序数据缺失 | Batch 超时过长 | 检查 exporter 日志 | 降低 batch timeout |
| 高采样开销 | 采样率过高 | 检查 CPU 使用率 | 降低采样率或使用头部采样 |

## 九、最佳实践总结

### 9.1 部署架构建议

```
开发环境: Java Agent → Collector(单实例) → Jaeger/Prometheus (单节点)
测试环境: Java Agent → Collector(2副本) → Jaeger/Prometheus (高可用)
生产环境: Java Agent → Collector(多副本+负载均衡) → 后端集群 (生产级)
```

### 9.2 资源规划参考

| 服务规模 | Collector 规格 | 采样率 | 存储方案 | 预估成本 |
|---------|--------------|-------|---------|---------|
| 小 (<20服务) | 2C4G × 2 | 100% | Jaeger All-in-One | 低 |
| 中 (20-100服务) | 4C8G × 3 | 10-50% | Jaeger + ES | 中 |
| 大 (>100服务) | 8C16G × N | 1-10% | Grafana Tempo | 高 |

### 9.3 实施路线图

1. **第1周**：部署 OpenTelemetry Collector + Jaeger + Prometheus
2. **第2周**：所有微服务接入 Java Agent（零代码）
3. **第3周**：关键业务代码手动埋点，添加自定义指标
4. **第4周**：配置告警规则和 SLO，接入 Grafana Dashboard
5. **持续**：优化采样策略，调整告警阈值

## 总结

OpenTelemetry 统一了可观测性三大信号的数据采集标准，是云原生时代构建可观测性体系的基石。通过 Java Agent 的零代码接入和 SDK 的灵活埋点，可以在不侵入业务代码的情况下快速建立追踪、指标和日志体系。配合 OpenTelemetry Collector 的灵活处理能力，能够智能采样、过滤和路由遥测数据，为故障排查、性能优化和容量规划提供全面的数据支持。
