---
title: Prometheus + Grafana 监控体系从入门到生产实践
date: 2026-06-16 08:45:00
tags:
  - Prometheus
  - Grafana
  - 监控
  - 告警
categories:
  - DevOps
author: 东哥
---

# Prometheus + Grafana 监控体系从入门到生产实践

## 前言

在微服务和云原生架构盛行的今天，**可观测性（Observability）** 已经成为系统稳定运行的基石。而谈到监控，Prometheus 和 Grafana 几乎是业界标配的组合。

本文将带你从零搭建一套完整的 Prometheus + Grafana 监控体系，覆盖指标采集、告警规则、可视化面板设计等核心实践。

## 一、架构总览

一个生产级的 Prometheus 监控架构通常包含以下组件：

| 组件 | 作用 | 生产建议 |
|------|------|----------|
| Prometheus Server | 指标采集、存储、查询 | 至少 2 台做联邦或高可用 |
| Exporters | 暴露指标端点（Node、MySQL、Redis 等） | 每个节点/服务部署 |
| Alertmanager | 告警路由、去重、静默 | 高可用部署 |
| Grafana | 可视化面板 | 对接 Prometheus 数据源 |

```
+----------------+      +------------------+      +----------------+
|  Node_Exporter |----->|                  |      |   Grafana      |
|  MySQL_Exporter |----->|   Prometheus     |<----->|   Dashboard    |
|  Custom_Exporter |----->|   Server         |      |   + Alert      |
+----------------+      |   + Alertmanager  |      +----------------+
                         +------------------+
                                  |
                                  v
                          PagerDuty/钉钉/邮件
```

## 二、Prometheus 核心概念

### 2.1 数据模型

Prometheus 使用**多维时序数据模型**：

```
<metric_name>{<label_name>=<label_value>, ...}
```

示例：
```promql
http_requests_total{method="POST", handler="/api/v1/orders", status="200"}
```

### 2.2 四种指标类型

| 类型 | 说明 | 适用场景 |
|------|------|----------|
| Counter | 只增不减的计数器 | 请求数、错误数 |
| Gauge | 可增可减的测量值 | CPU 使用率、内存占用 |
| Histogram | 直方图，分桶统计 | 请求延迟分布 |
| Summary | 类似 Histogram，但计算分位数 | 延迟 P99 监控 |

### 2.3 PromQL 查询语言

常用 PromQL 表达式：

```promql
# CPU 使用率
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 内存使用率
100 * (node_memory_MemTotal_bytes - node_memory_MemFree_bytes - node_memory_Buffers_bytes - node_memory_Cached_bytes) / node_memory_MemTotal_bytes

# QPS
sum(rate(http_requests_total[1m]))

# P99 延迟
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, handler))
```

## 三、生产部署方案

### 3.1 Docker Compose 部署

```yaml
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:v2.53.0
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
      - '--storage.tsdb.retention.size=50GB'
    ports:
      - "9090:9090"

  node_exporter:
    image: prom/node-exporter:v1.8.0
    network_mode: host

  alertmanager:
    image: prom/alertmanager:v0.27.0
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml
    ports:
      - "9093:9093"

  grafana:
    image: grafana/grafana:11.0.0
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=strongpassword
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"

volumes:
  prometheus_data:
  grafana_data:
```

### 3.2 Prometheus 配置文件

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - 'alerts/*.yml'

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets:
        - '10.0.0.10:9100'  # 生产服务器
        - '10.0.0.11:9100'
        - '10.0.0.12:9100'

  - job_name: 'spring-boot'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
        - 'app1.example.com:8080'
        - 'app2.example.com:8080'

  - job_name: 'mysql'
    static_configs:
      - targets: ['mysql-exporter:9104']
```

## 四、告警规则实战

### 4.1 基础设施告警

```yaml
# alerts/infra.yml
groups:
  - name: infra
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} down"
          description: "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 1 minute."

      - alert: HighCpuUsage
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage is above 80% for 5 minutes (current: {{ $value }}%)"

      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100 < 10
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk space low on {{ $labels.instance }}"
          description: "Disk available is below 10% (mount: {{ $labels.mountpoint }})"
```

### 4.2 应用层告警

```yaml
# alerts/app.yml
groups:
  - name: application
    rules:
      - alert: HighErrorRate
        expr: sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "High error rate on {{ $labels.instance }}"
          description: "Error rate above 5% for 3 minutes"

      - alert: HighP99Latency
        expr: histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 1.0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High P99 latency"
          description: "P99 latency exceeds 1 second"
```

## 五、Grafana 面板设计

### 5.1 推荐的面板布局

| 面板名 | 数据源 | 说明 |
|--------|--------|------|
| 系统概览 | Prometheus | CPU、内存、磁盘、网络 |
| 应用概览 | Prometheus | QPS、错误率、延迟、线程数 |
| JVM 监控 | Prometheus + Micrometer | 堆内存、GC、类加载 |
| 慢查询 | MySQL Exporter | 慢 SQL、连接数、吞吐 |
| 业务大盘 | Prometheus + 自定义指标 | 订单量、转化率、活跃用户 |

### 5.2 面板变量设计

Grafana 的模板变量可以大幅提升面板的复用性：

```ini
# 变量定义
env = Label：prometheus > label_values(up, env)
instance = Label：prometheus > label_values(up{env="$env"}, instance)
app = Label：prometheus > label_values(http_requests_total{env="$env"}, app)
```

### 5.3 一个完整的 JVM 监控面板

**内存面板：**
```
# 堆内存使用率
100 * (sum(jvm_memory_used_bytes{area="heap"}) / sum(jvm_memory_max_bytes{area="heap"}))

# GC 频率
rate(jvm_gc_pause_seconds_count[5m])
```

**线程面板：**
```promql
# 活跃线程数
jvm_threads_live_threads{application="$app", instance="$instance"}

# 阻塞线程
jvm_threads_states_threads{state="BLOCKED", application="$app"}
```

## 六、最佳实践总结

### 6.1 指标命名规范

- 使用 `_total` 后缀表示 Counter：`http_requests_total`
- 使用 `_seconds` 后缀表示时间：`request_duration_seconds`
- 使用 `_bytes` 后缀表示字节：`memory_usage_bytes`
- 统一前缀表示域：`node_`、`jvm_`、`http_`

### 6.2 常见坑与解决方案

| 问题 | 原因 | 方案 |
|------|------|------|
| 指标基数爆炸 | Label 值无限增长 | 使用 `chunked` 存储，限制 Label 基数 |
| 查询慢 | 全表扫描 | 使用 Recording Rules 预聚合 |
| 数据丢失 | 存储空间不足 | 设置 `--storage.tsdb.retention.size` |
| 告警风暴 | 依赖链故障 | Alertmanager 配置分组和抑制 |

### 6.3 告警避免噪声的技巧

```yaml
# alertmanager.yml
route:
  group_by: ['alertname', 'cluster']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h  # 已恢复的告警 4 小时后才重发
  receiver: 'default'
  routes:
    - matchers:
        - severity = critical
      receiver: 'pagerduty'
    - matchers:
        - severity = warning
      receiver: 'email'

receivers:
  - name: 'pagerduty'
    pagerduty_configs:
      - routing_key: 'your-key'
  - name: 'email'
    email_configs:
      - to: 'ops@example.com'
        from: 'alert@example.com'
        smarthost: 'smtp.example.com:587'
```

## 七、总结

一套完善的监控体系不只是搭几个组件，它需要从**指标设计 → 采集 → 存储 → 告警 → 可视化**形成完整的闭环。Prometheus + Grafana 组合之所以成为标准，不仅因为其开源免费，更因为其生态和灵活性。

后续可以延伸的方向：
- **Thanos / VictoriaMetrics**：长期存储和全局视图
- **OpenTelemetry**：统一 traces + metrics + logs
- **AI 驱动的异常检测**：基于历史数据的智能告警

希望本文能帮你搭建出适合自己的监控体系。
