---
title: Grafana Loki 日志聚合系统实战
date: 2026-06-18 08:00:00
tags:
  - Grafana
  - Loki
  - 日志
  - 可观测性
categories:
  - 运维
author: 东哥
---

# Grafana Loki 日志聚合系统实战

## 一、Loki 简介

### 1.1 什么是 Loki

Grafana Loki 是一个受 Prometheus 启发的水平可扩展、高可用、多租户的日志聚合系统。与 Elasticsearch 不同，Loki 不索引日志内容，而是只索引标签，日志本身以压缩方式存储，这使得它的资源消耗比 ELK 栈低得多。

### 1.2 核心设计理念

```
传统的日志系统（ELK）:
┌──────────┐    ┌──────────┐    ┌──────────┐
│ Filebeat │───→│   ES     │───→│  Kibana   │
│ (采集)   │    │ (索引+存储)│    │ (可视化)  │
└──────────┘    └──────────┘    └──────────┘
    ↑ 全局索引所有内容，存储成本高

Loki 方案:
┌──────────┐    ┌──────────┐    ┌──────────┐
│ Promtail │───→│   Loki   │───→│  Grafana  │
│ (采集)   │    │ (只索引标签)│    │ (可视化)  │
└──────────┘    └──────────┘    └──────────┘
    ↑ 只索引标签，日志内容压缩存储
```

### 1.3 ELK vs Loki 对比

| 维度 | Elasticsearch | Loki | 差异说明 |
|------|-------------|------|---------|
| 索引策略 | 全文索引所有字段 | 仅索引标签 | Loki 存储成本低 50-70% |
| 查询方式 | DSL JSON 查询 | LogQL (类 PromQL) | 对 Prometheus 用户友好 |
| 存储开销 | 高（副本+索引） | 低（对象存储） | Loki 压缩比可达 5:1 |
| 延迟 | 近实时 (~1s) | 近实时 (~1s) | 接近 |
| 高可用 | 需 ES 集群 | Loki 集群+对象存储 | 运维复杂度相当 |
| 可视化 | Kibana | Grafana | 统一可观测性仪表盘 |
| 资源消耗 | 8C32G 起步 | 2C4G 起步 | Loki 资源需求更低 |

## 二、Loki 架构

### 2.1 组件架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Loki 架构                              │
├───────────┬───────────┬───────────┬───────────┬────────────┤
│ Distributor│ Ingester  │ Querier   │ Query     │ Compactor │
│ (分发器)   │ (摄入器)  │ (查询器)  │ Frontend │ (压缩器)  │
├───────────┼───────────┼───────────┼───────────┼────────────┤
│ 验证日志   │ 缓存写入   │ 执行查询   │ 查询分片   │ 合并索引   │
│ 哈希分发   │ 内存批次   │ 合并结果   │ 缓存控制   │ 清理数据   │
│ 负载均衡   │ 刷写到S3  │ 去重返回   │ 限流       │ 降低存储   │
└───────────┴───────────┴───────────┴───────────┴────────────┘
      │            │           │              │
      ▼            ▼           ▼              ▼
┌─────────────────────────────────────────────────────────────┐
│              对象存储 (S3/MinIO/GCS) + 索引                   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 读写路径

```
写入路径:
Agent(Promtail) → Distributor (2副本写入) → Ingester (内存批次) → 对象存储

读取路径:
Grafana → Query Frontend (分片/缓存) → Querier (从 Ingester+Store 查询) → Grafana

Ingester 生命周期:
  − Transferring: 接收数据
  − Active: 提供服务
  − Idle: 准备刷写
  − Flushing: 刷写到对象存储
  − Unavailable: 下线
```

## 三、Loki 部署

### 3.1 Docker Compose 单机部署

```yaml
version: '3.8'
services:
  loki:
    image: grafana/loki:3.0.0
    ports:
      - "3100:3100"
    command: -config.file=/etc/loki/config.yaml
    volumes:
      - ./loki-config.yaml:/etc/loki/config.yaml
      - ./loki-data:/loki
    networks:
      - loki-net

  promtail:
    image: grafana/promtail:3.0.0
    volumes:
      - ./promtail-config.yaml:/etc/promtail/config.yaml
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
    command: -config.file=/etc/promtail/config.yaml
    networks:
      - loki-net
    depends_on:
      - loki

  grafana:
    image: grafana/grafana:11.1.0
    ports:
      - "3000:3000"
    environment:
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
    volumes:
      - ./grafana-datasources:/etc/grafana/provisioning/datasources
    networks:
      - loki-net

networks:
  loki-net:
    driver: bridge
```

### 3.2 Loki 配置

```yaml
# loki-config.yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9095
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache
  filesystem:
    directory: /loki/chunks

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20
  max_query_series: 10000
  max_query_bytes_read: 2GB
  
  # 每个租户的日志保留策略
  retention_period: 720h  # 30d

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
        ttl: 24h

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-tmp
  alertmanager_url: http://alertmanager:9093
  ring:
    kvstore:
      store: inmemory
  enable_api: true
```

### 3.3 Promtail 日志采集配置

```yaml
# promtail-config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  # 采集 Docker 容器日志
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.*)'
        target_label: 'container'
      - source_labels: ['__meta_docker_container_log_stream']
        target_label: 'stream'
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        target_label: 'service'
      - source_labels: ['__meta_docker_container_label_com_docker_compose_project']
        target_label: 'project'
  
  # 采集系统日志
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          __path__: /var/log/*.log
  
  # 采集 Java 应用日志
  - job_name: java-apps
    static_configs:
      - targets: [localhost]
        labels:
          job: java-app
          __path__: /data/logs/*/*.log
          environment: production
    pipeline_stages:
      # 多行合并（处理 Java 堆栈跟踪）
      - multiline:
          firstline: '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
          max_lines: 100
          max_wait_time: 3s
      # 解析 JSON 格式日志
      - json:
          expressions:
            level: level
            logger: logger_name
            thread: thread_name
            message: message
            trace_id: trace_id
      # 添加标签
      - labels:
          level:
          trace_id:
      # 删除不需要的字段
      - drop:
          source: "message"
          value: "^\\s*$"
```

## 四、LogQL 查询语言

### 4.1 基础查询

```logql
# 基础查询
{app="order-service", env="production"}
# 返回该标签组合下所有日志

# 带日志内容过滤
{app="order-service"} |= "ERROR"
{app="order-service"} |= "NullPointerException"
{app="order-service"} != "health-check"
{app="order-service"} |~ "order-\\d{6}"  # 正则匹配
{app="order-service"} !~ "\\s+DEBUG"      # 正则排除

# 多条件组合
{app="order-service", env="production"} 
    |= "ERROR" 
    != "timeout" 
    |~ "OOM|OutOfMemory"
```

### 4.2 指标查询

```logql
# 日志速率
rate({app="order-service"} |= "ERROR" [5m])

# 按级别统计
sum by (level) (count_over_time({app="order-service"} | json [5m]))

# 计算 P99 延迟
quantile_over_time(0.99, 
  {app="order-service"} 
  | json 
  | unwrap response_time [5m]
)

# 错误率
sum(rate({app="order-service"} |= "ERROR" [5m])) 
/ 
sum(rate({app="order-service"}[5m]))
```

### 4.3 高级查询示例

```logql
# 1. 解析结构化日志后分析
{app="payment-service", env="production"}
  | json
  | level = "error"
  | line_format "{{.message}}"
  | pattern "<ip> - - <_> \"<method> <path> <_>\" <status> <_> <duration>"
  | status >= 500
  | unwrap duration
  | duration > 1000
  | topk(10, duration) by (path)

# 2. 基于 Trace ID 关联日志
{app=~"order-service|payment-service|inventory-service"}
  | json
  | trace_id =~ "abc123.*"
  
# 3. SLO 计算
(
  sum(rate({app="order-service"} |= "200" [5m]))
  /
  sum(rate({app="order-service"} |= "5.." [5m]))
) > 0.995

# 4. 异常检测（对比前一天的同一时间段）
sum by (app) (
  rate({app=~".+"} |= "ERROR" [5m] offset 1d)
)
```

## 五、Grafana 集成

### 5.1 数据源配置

```yaml
# grafana-datasources.yaml
apiVersion: 1

datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      maxLines: 1000
      derivedFields:
        - name: traceID
          type: json
          matcherType: label
          matcherRegex: "trace_id=(\\w+)"
          url: "$${__value.raw}"
          datasourceUid: tempo
    editable: true
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
```

### 5.2 日志 Dashboard

```json
{
  "dashboard": {
    "title": "应用日志分析面板",
    "panels": [
      {
        "title": "错误日志趋势",
        "type": "graph",
        "targets": [{
          "expr": "sum by (level) (count_over_time({app=\"$service\"} | json [5m]))",
          "legendFormat": "{{level}}"
        }]
      },
      {
        "title": "Top 10 错误路径",
        "type": "table",
        "targets": [{
          "expr": "topk(10, sum by (path) (count_over_time({app=\"$service\"} |= \"5..\" | pattern \"<path>\" [24h])))",
          "format": "table"
        }]
      },
      {
        "title": "实时日志流",
        "type": "logs",
        "targets": [{
          "expr": "{app=\"$service\", env=\"$env\"} |= \"$search\"",
          "legendFormat": ""
        }],
        "options": {
          "showLabels": true,
          "showTime": true,
          "wrapLogMessage": true,
          "enableLogDetails": true
        }
      },
      {
        "title": "错误率 (5xx)",
        "type": "stat",
        "targets": [{
          "expr": "sum(rate({app=\"$service\",env=\"$env\"} |~ \"5\\\\d\\\\d\" [5m])) / sum(rate({app=\"$service\",env=\"$env\"} [5m])) * 100",
          "legendFormat": "错误率"
        }],
        "options": {
          "colorMode": "background",
          "graphMode": "area",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 1 },
              { "color": "red", "value": 5 }
            ]
          }
        }
      }
    ],
    "templating": {
      "list": [
        { "name": "service", "query": "label_values(app)", "type": "query" },
        { "name": "env", "query": "label_values(env)", "type": "query" },
        { "name": "search", "type": "textbox", "hide": 2 }
      ]
    }
  }
}
```

## 六、Kubernetes 部署

### 6.1 Helm 部署 Loki Stack

```bash
# 添加 Helm 仓库
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 部署 Loki Stack（含 Promtail、Grafana）
helm upgrade --install loki grafana/loki-stack \
  --namespace=loki \
  --create-namespace \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=50Gi \
  --set promtail.enabled=true \
  --set grafana.enabled=true \
  --set grafana.service.type=LoadBalancer \
  --set loki.config.ingestionRateMB=10

# 或者使用 Loki 分布式模式
helm upgrade --install loki grafana/loki-distributed \
  --namespace=loki \
  --create-namespace \
  --values loki-values.yaml
```

```yaml
# loki-values.yaml - 分布式部署
loki:
  structuredConfig:
    auth_enabled: false
    ingester:
      chunk_idle_period: 30m
      chunk_target_size: 1.5MB
      max_chunk_age: 1h
    limits_config:
      reject_old_samples: true
      reject_old_samples_max_age: 168h
    storage_config:
      aws:
        s3: s3://minio:9000/loki
        s3forcepathstyle: true
        insecure: true
        access_key_id: minioadmin
        secret_access_key: minioadmin

gateway:
  enabled: true
  replicas: 2

distributor:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi

ingester:
  replicas: 3
  resources:
    requests:
      cpu: 1
      memory: 2Gi

querier:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 1Gi

queryFrontend:
  replicas: 2
  resources:
    requests:
      cpu: 500m
      memory: 512Mi

compactor:
  enabled: true
  replicas: 1

minio:
  enabled: true
  replicas: 1
  persistence:
    size: 100Gi
```

### 6.2 采集 K8s 容器日志

```yaml
# promtail 的额外配置
daemonset:
  enabled: true
  extraArgs:
    - -config.file=/etc/promtail/promtail.yaml

config:
  snippets:
    scrapeConfigs:
    - job_name: kubernetes-pods
      pipeline_stages:
        - cri: {}  # CRI 日志格式解析
        - multiline:
            firstline: '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
            max_wait_time: 3s
      kubernetes_sd_configs:
        - role: pod
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_label_app]
          target_label: app
        - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
          target_label: app_kubernetes
        - source_labels: [__meta_kubernetes_pod_container_name]
          target_label: container
        - source_labels: [__meta_kubernetes_namespace]
          target_label: namespace
        - source_labels: [__meta_kubernetes_pod_node_name]
          target_label: node
        - source_labels: [__meta_kubernetes_pod_name]
          target_label: pod
        - action: replace
          replacement: /var/log/pods/*$1*/*.log
          separator: /
          source_labels:
            - __meta_kubernetes_pod_uid
            - __meta_kubernetes_pod_container_name
          target_label: __path__
```

## 七、告警配置

### 7.1 Loki Ruler 告警规则

```yaml
# loki-rules.yaml
groups:
  - name: log-error-rules
    interval: 1m
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate({app="order-service", env="production"} 
            |= "ERROR" [5m])) > 10
        for: 5m
        labels:
          severity: critical
          team: sre
        annotations:
          summary: "订单服务错误率过高"
          description: "过去5分钟错误日志数 {{ $value }} 条/秒"
          
      - alert: OOMDetected
        expr: |
          count_over_time({app=~".+"} |~ "OutOfMemoryError|OOM" [5m]) > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "检测到 OOM 错误"
          
      - alert: ErrorSpike
        expr: |
          (
            sum(rate({app="order-service"} |= "ERROR" [5m]))
            /
            sum(rate({app="order-service"} |= "ERROR" [5m] offset 1h))
          ) > 3
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "错误率较1小时前上升3倍"
```

## 八、性能优化

### 8.1 优化策略对照表

| 问题 | 原因 | 优化方案 | 预期效果 |
|------|------|---------|---------|
| 查询慢 | 扫描数据量大 | 使用更精确的标签过滤 | 查询时间降低 80% |
| 摄入瓶颈 | 日志量突增 | 增加 Distributor 副本 | 吞吐量线性提升 |
| 存储膨胀 | 未开启压缩 | 启用 Compactor | 存储节省 50% |
| 查询超时 | 查询范围过大 | 设置 max_query_bytes_read | 避免 OOM |
| 写入丢数据 | Ingester OOM | 降低 chunk_target_size | 提高稳定性 |

### 8.2 标签设计最佳实践

```yaml
# ✅ 好的标签设计
labels:
  app: order-service          # 服务名（必选）
  env: production              # 环境（必选）
  namespace: default           # 命名空间
  container: order-api         # 容器名（K8s）

# ❌ 避免的高基数标签
labels:
  user_id: 12345              # 高基数！每个用户不同
  trace_id: abc123            # 高基数！每个请求不同
  ip: 10.0.1.100              # 高基数！每个 IP 不同
  request_id: req-xxx         # 高基数！每个请求不同

# 高基数信息应该放在日志内容中，而不是标签
# 通过 LogQL 的内容过滤来查询
{app="order-service"} |= "user_id=12345"
```

### 8.3 存储估算

```
日志量估算公式:
  每日存储 = 日志产生速率(MB/s) × 86400 × 压缩比例

示例:
  100个微服务, 每个服务 1MB/s
  每日原始日志: 100 × 1 × 86400 = 8.64 TB
  Loki 压缩 (5:1): ~1.73 TB/天
  保留30天: ~52 TB (对象存储)

推荐配置:
  - <10GB/天: 单实例文件系统
  - 10-100GB/天: 单实例 + MinIO
  - 100GB-1TB/天: 分布式 + S3
  - >1TB/天: 分布式 + 专用存储集群
```

## 九、故障排查

### 9.1 常见问题

| 症状 | 可能原因 | 解决命令 |
|------|---------|---------|
| Promtail 无法推送 | Loki 地址错误 | 检查 promtail.yaml 中的 clients.url |
| 日志不显示 | 标签不匹配 | 排查 Promtail 的 relabel_configs |
| 查询返回空 | 时间范围错误 | 检查 Grafana 时间选择器 |
| 摄入限流 | 超过 ingestion_rate_mb | 增加 limits_config 限制 |
| 高内存使用 | 查询扫描过多数据 | 添加更精确的标签过滤 |
| 索引损坏 | 版本升级不兼容 | 检查 schema_config 的 schema v13 |

### 9.2 诊断命令

```bash
# 检查 Loki 就绪状态
curl http://loki:3100/ready

# 查看配置
curl http://loki:3100/config

# 查看指标
curl http://loki:3100/metrics | grep -E "loki_ingester|loki_distributor"

# 检查日志推送
curl -v -H "Content-Type: application/json" \
  -X POST \
  -d '{"streams":[{"stream":{"app":"test"},"values":[["'$(date +%s%N)'","test log message"]]}]}' \
  http://loki:3100/loki/api/v1/push

# Promtail 状态
curl http://promtail:9080/targets

# 查询日志样本
curl -G -s "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={app="order-service"}' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode "limit=10" | jq .
```

## 总结

Grafana Loki 通过只索引标签、不索引日志内容的创新设计，以远低于 ELK 的资源消耗实现了高效的日志聚合。配合 Promtail 和 Grafana，构成了完整的日志采集、存储、查询和可视化解决方案。

**实施建议：**
1. 小规模场景使用单实例 Loki + 文件系统存储即可
2. 大规模场景采用分布式 Loki + 对象存储
3. 精心设计标签，避免使用高基数标签
4. 善用 LogQL 做日志分析和告警
5. 结合 Prometheus 指标和 Tempo 追踪，构建完整的可观测性体系
