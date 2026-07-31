---
title: Elastic APM 与 Spring Boot 集成：全链路应用性能监控实战
date: 2026-07-31 08:00:00
tags:
  - Java
  - Elastic APM
  - 性能监控
  - Spring Boot
  - 可观测性
categories:
  - Java
  - 运维监控
author: 东哥
---

# Elastic APM 与 Spring Boot 集成：全链路应用性能监控实战

## 为什么需要 APM？

当你的 Spring Boot 服务部署到生产环境后，用户反馈"页面加载很慢"。你怎么排查？

1. 登录服务器 → 2. top 看 CPU → 3. jstack 看线程 → 4. 翻日志 → 5. 猜原因...

这个过程耗时且不精确。**APM（Application Performance Monitoring）** 就是为了解决这个问题而生——它自动采集应用运行时数据，通过拓扑图、事务追踪、慢调用链路等方式，让你**一眼定位性能瓶颈**。

> 面试官：你用过哪些 APM 工具？说说 Elastic APM 的核心原理。

---

## 一、Elastic APM 架构概览

Elastic APM 基于 Elastic Stack（ELK）生态，由 4 个核心组件构成：

```
┌─────────────┐     ┌───────────────┐     ┌────────────┐     ┌─────────────┐
│  Java Agent │────▶│  APM Server   │────▶│  Elasticsearch │────▶│  Kibana    │
│  (应用内)    │     │  (数据接收)    │     │  (存储/索引)  │     │  (可视化)   │
└─────────────┘     └───────────────┘     └────────────┘     └─────────────┘
```

| 组件 | 说明 | 部署方式 |
|------|------|---------|
| **APM Agent** | Java 字节码增强，无侵入采集 | 随应用启动（javaagent） |
| **APM Server** | 接收 Agent 数据，校验后写入 ES | 独立服务（Docker 或二进制） |
| **Elasticsearch** | 存储 APM 数据（索引 templates） | 集群部署 |
| **Kibana** | APM UI 仪表盘 | 集成 APM 插件 |

### 1.1 关键能力

- **分布式链路追踪**：跨服务请求全链路追踪（支持 HTTP、gRPC、消息队列等）
- **事务与 Span**：自动采集 Spring MVC、JDBC、Redis、HTTP Client 调用
- **错误采集**：自动捕获未处理异常及堆栈
- **慢查询/SQL 诊断**：自动标记超过阈值的数据库查询
- **JVM 指标**：堆内存、GC 次数、线程数、CPU 使用率
- **自定义 Span**：业务代码任意埋点

---

## 二、Elastic APM Server 部署

### 2.1 Docker Compose 一键部署

```yaml
# docker-compose.yml
version: '3.8'
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.14.0
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
      - xpack.security.enabled=false  # 开发环境关闭安全认证
    ports:
      - "9200:9200"
    volumes:
      - es-data:/usr/share/elasticsearch/data

  apm-server:
    image: docker.elastic.co/apm/apm-server:8.14.0
    ports:
      - "8200:8200"
    environment:
      - output.elasticsearch.hosts=["http://elasticsearch:9200"]
      - apm-server.host="0.0.0.0:8200"
    depends_on:
      - elasticsearch

  kibana:
    image: docker.elastic.co/kibana/kibana:8.14.0
    ports:
      - "5601:5601"
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    depends_on:
      - elasticsearch

volumes:
  es-data:
```

```bash
docker compose up -d
```

### 2.2 生产环境配置要点

```yaml
# apm-server.yml（生产配置节选）
apm-server:
  host: "0.0.0.0:8200"
  rum:
    enabled: true          # 启用 RUM（真实用户监控）
    event_rate:
      limit: 300
      lru_size: 1000

output.elasticsearch:
  hosts: ["es-cluster-node1:9200", "es-cluster-node2:9200"]
  # 高可用配置
  worker: 3
  bulk_max_size: 50
  flush_interval: 5s

# 数据采样率（生产环境推荐）
sampling:
  keep_unsampled: true
  transactions_per_second: 10
```

---

## 三、Spring Boot 集成 APM Agent

### 3.1 下载 Java Agent

```bash
# 方式一：直接下载
wget https://search.maven.org/remotecontent?filepath=co/elastic/apm/elastic-apm-agent/1.52.0/elastic-apm-agent-1.52.0.jar

# 方式二：Maven 依赖（不会自动注入，仅用于版本管理）
```

### 3.2 JVM 参数注入

```bash
# 启动时添加 javaagent 参数
java -javaagent:/path/to/elastic-apm-agent-1.52.0.jar \
     -Delastic.apm.service_name=my-user-service \
     -Delastic.apm.server_url=http://localhost:8200 \
     -Delastic.apm.environment=production \
     -Delastic.apm.application_packages=com.example.userservice \
     -jar my-app.jar
```

### 3.3 使用配置文件

```properties
# elastic-apm.properties
service_name=my-user-service
server_url=http://10.0.0.10:8200
environment=production
application_packages=com.example.userservice
transaction_sample_rate=0.2          # 20% 采样率
capture_body=all                     # 捕获请求/响应体
capture_headers=true                 # 捕获请求头
log_level=info
# 忽略健康检查等非业务端点
disable_instrumentations=spring-scheduling
transaction_ignore_urls=/actuator/health,/actuator/info
```

启动命令：

```bash
java -javaagent:/path/to/agent.jar \
     -Delastic.apm.config_file=/etc/apm/elastic-apm.properties \
     -jar my-app.jar
```

---

## 四、Docker 容器化集成

### 4.1 Dockerfile 集成

```dockerfile
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# 下载 APM Agent
ADD https://search.maven.org/remotecontent\
 ?filepath=co/elastic/apm/elastic-apm-agent/1.52.0/elastic-apm-agent-1.52.0.jar \
 /app/elastic-apm-agent.jar

COPY target/app.jar app.jar

ENV JAVA_OPTS="-javaagent:/app/elastic-apm-agent.jar \
    -Delastic.apm.service_name=user-service \
    -Delastic.apm.server_url=http://apm-server:8200 \
    -Delastic.apm.environment=production \
    -Delastic.apm.application_packages=com.example"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

### 4.2 Kubernetes Sidecar 方式（推荐）

```yaml
# k8s-deployment.yaml（摘录）
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      initContainers:
        - name: apm-agent-download
          image: busybox:latest
          command:
            - wget
            - -O
            - /agent/elastic-apm-agent.jar
            - https://search.maven.org/remotecontent?filepath=co/elastic/apm/elastic-apm-agent/1.52.0/elastic-apm-agent-1.52.0.jar
          volumeMounts:
            - name: apm-agent
              mountPath: /agent
      containers:
        - name: user-service
          image: user-service:latest
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/agent/elastic-apm-agent.jar"
            - name: ELASTIC_APM_SERVICE_NAME
              value: "user-service"
            - name: ELASTIC_APM_SERVER_URL
              value: "http://apm-server:8200"
            - name: ELASTIC_APM_ENVIRONMENT
              value: "production"
            - name: ELASTIC_APM_APPLICATION_PACKAGES
              value: "com.example"
          volumeMounts:
            - name: apm-agent
              mountPath: /agent
      volumes:
        - name: apm-agent
          emptyDir: {}
```

---

## 五、APM 数据可视化

### 5.1 Kibana APM 核心面板

启动 Kibana 后访问 `http://localhost:5601/app/apm`：

**服务仪表盘**（Service Dashboard）：
- 吞吐量（TPM/TPS）
- 平均响应时间与 P95/P99 延迟
- 错误率趋势
- 事务类型分布（HTTP / DB / Cache 等）

**事务追踪**（Transaction Trace）：
- 每次请求的完整调用链
- 每个 Span 的耗时明细
- JDBC 查询 SQL 原文
- HTTP 调用 URL 和状态码

### 5.2 关键指标解读

| 指标 | 含义 | 预警阈值参考 |
|------|------|-----------|
| **Apdex** | 用户满意度评分（0-1） | &lt; 0.85 需关注 |
| **P99 延迟** | 99% 请求的耗时 | &gt; 2s 需排查 |
| **吞吐量** | 每分钟事务数 | 同比降幅 &gt; 30% 预警 |
| **错误率** | 500 错误占比 | &gt; 1% 触发告警 |
| **GC 耗时** | GC 暂停占总时间比例 | &gt; 10%（CMS/G1）需调优 |

---

## 六、自定义埋点与业务监控

### 6.1 使用 OpenTelemetry API（推荐）

```xml
<dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-api</artifactId>
    <version>1.36.0</version>
</dependency>
```

```java
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;

@Service
public class OrderService {

    private final Tracer tracer;

    public OrderService(Tracer tracer) {
        this.tracer = tracer;
    }

    public OrderResult createOrder(OrderRequest request) {
        // 创建自定义 Span
        Span span = tracer.spanBuilder("createOrder")
            .setAttribute("order.amount", request.amount())
            .setAttribute("order.userId", request.userId())
            .setAttribute("order.itemCount", request.items().size())
            .startSpan();

        // 需要 OpenTelemetry Agent 或手动处理 context 传播
        try (Scope ignored = span.makeCurrent()) {
            // 业务逻辑...
            validateInventory(request);  // 子方法调用自动关联
            processPayment(request);
            sendNotification(request);

            span.setStatus(StatusCode.OK);
            return new OrderResult(true, "Success");
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }
}
```

### 6.2 使用 Elastic APM 原生 API

```xml
<dependency>
    <groupId>co.elastic.apm</groupId>
    <artifactId>apm-agent-api</artifactId>
    <version>1.52.0</version>
    <scope>provided</scope>
</dependency>
```

```java
import co.elastic.apm.api.ElasticApm;
import co.elastic.apm.api.Span;
import co.elastic.apm.api.Transaction;

@Service
public class OrderService {

    private static final Transaction TX = ElasticApm.currentTransaction();

    public OrderResult createOrder(OrderRequest request) {
        Transaction transaction = ElasticApm.currentTransaction()
            .setName("CreateOrder")
            .setType("business");

        try (Span span = transaction.createSpan()
                 .setName("validateInventory")
                 .setType("app.custom")) {
            validateInventory(request);
        }

        try (Span span = transaction.createSpan()
                 .setName("processPayment")
                 .setType("app.custom")) {
            // 设置自定义标签
            span.setLabel("payment_method", request.paymentMethod());
            span.setLabel("amount", request.amount());
            processPayment(request);
        }

        return new OrderResult(true, "Success");
    }
}
```

### 6.3 @Traced 注解方式

```java
import co.elastic.apm.api.Traced;

@Service
public class OrderService {

    @Traced("validateInventory")
    public void validateInventory(OrderRequest request) {
        // 自动创建名为 "validateInventory" 的 Span
    }

    @Traced("processPayment")
    public void processPayment(OrderRequest request) {
        // 自动追踪此方法耗时
    }
}
```

---

## 七、告警配置

### 7.1 Kibana 预定义告警规则

在 Kibana → Stack Management → Rules 中配置：

```json
{
  "name": "High Error Rate Alert",
  "rule_type_id": "apm.transaction_error_rate",
  "params": {
    "threshold": 5,
    "window": "5m",
    "services": ["*"]
  },
  "actions": [
    {
      "group": "threshold_met",
      "id": "my-webhook-connector",
      "params": {
        "body": "服务 {{service.name}} 最近 5 分钟错误率 {{context.errorRate}}%"
      }
    }
  ]
}
```

### 7.2 Prometheus + AlertManager（与 APM 互补）

如果已有 Prometheus 体系，APM Server 支持暴露 Prometheus 指标：

```yaml
# apm-server.yml
apm-server:
  metrics:
    enabled: true
  self_metrics:
    enabled: true
```

```yaml
# prometheus.yml 配置 scrape
scrape_configs:
  - job_name: 'apm-server'
    metrics_path: '/metrics'
    static_configs:
      - targets: ['apm-server:8200']
```

---

## 八、性能开销与优化

### 8.1 APM Agent 的性能开销

| 采样率 | 额外 CPU 开销 | 额外内存开销 | 推荐场景 |
|--------|-------------|------------|---------|
| 100% | ~3-5% | ~100MB | 预发/验收环境 |
| 10% | ~1-2% | ~50MB | 生产低流量服务 |
| 1%（采样） | &lt; 1% | ~30MB | 生产高流量服务 |

### 8.2 生产最佳实践

```properties
# 生产环境推荐配置
transaction_sample_rate=0.1          # 10% 采样率
span_frames_min_duration=5ms         # 小于 5ms 的 Span 不记录栈
capture_body=off                     # 不采集请求体（安全考虑）
capture_headers=false                # 不采集请求头
disable_instrumentations=spring-scheduling,jdbc,redis  # 按需禁用不需要的采集
breakdown_metrics=false              # 关闭耗时拆解指标
```

---

## 九、Elastic APM vs 其他 APM 工具

| 维度 | Elastic APM | SkyWalking | Pinpoint | Grafana Faro |
|------|------------|-----------|---------|-------------|
| 存储 | Elasticsearch | H2/ES/TiDB | HBase | Loki/Tempo |
| 部署复杂度 | 中等 | 低 | 高 | 中等 |
| 社区活跃度 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| Java Agent 兼容 | JDK 7+ | JDK 6+ | JDK 6+ | OpenTelemetry |
| 无侵入采集 | ✅ | ✅ | ✅ | ✅ |
| 链路采样 | ✅ | ✅ | ❌ | ✅ |
| 业务埋点 API | ✅ | ✅ | ✅ | OpenTelemetry |
| 告警体系 | Kibana Rule | 内置 | 内置 | Grafana Alert |
| 前端/移动端 | ✅ RUM | ❌ | ❌ | ✅ Faro |

---

## 十、常见面试追问

**Q：APM Agent 是如何做到无侵入采集的？**
A：基于 Java Instrumentation + Byte Buddy 字节码增强。在类加载时动态修改字节码，在目标方法前后插入追踪代码。不需要修改业务源码。

**Q：采样率怎么设置？全量采集有什么问题？**
A：高流量服务（>1000 TPS）建议 1%-10% 采样，否则 ES 存储压力和 Agent CPU 开销都会线性增长。P99 延迟在低采样率下依然准确，因为它的计算基于直方图而非全量数据。

**Q：Elastic APM 的事务和 Span 有什么区别？**
A：Transaction 代表一次"业务请求"（如 HTTP 请求），Span 代表事务内部的一次"操作"（如 SQL 查询、RPC 调用）。一个 Transaction 包含多个 Span，形成树状结构。

**Q：APM 监控和日志监控（ELK）怎么配合？**
A：APM 负责"定位问题"，日志负责"排查细节"。通过 `trace.id` 和 `transaction.id` 可以在 APM 事务中直接跳转到关联的日志上下文（结合 ECS 日志格式效果最佳）。

---

## 总结

Elastic APM 提供了一站式的应用性能监控方案，从自动采集到可视化分析，再到告警响应，形成了一个完整的可观测性闭环。对于 Spring Boot 微服务架构，集成过程无侵入、成本可控，建议在**预发环境全量开启、生产环境按 10% 采样**，在控制资源开销的同时获得足够的性能洞察。

记住一句：**没有监控的发布是盲人摸象，没有 APM 的监控是管中窥豹。**
