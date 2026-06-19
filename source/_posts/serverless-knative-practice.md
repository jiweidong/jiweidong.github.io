---
title: Serverless 架构与 Knative 入门实践
date: 2026-06-17 08:00:00
tags:
  - Serverless
  - Knative
  - K8s
  - 云原生
  - 微服务
categories:
  - 云原生
  - Kubernetes
author: 东哥
---

# Serverless 架构与 Knative 入门实践

> Serverless 架构正在重塑云原生应用的构建和部署方式。Knative 作为 Kubernetes 上最流行的 Serverless 框架，提供了基于流量的自动伸缩、缩零和事件驱动能力。本文从基础概念到实战部署，带您全面掌握 Knative。

## 一、Serverless 架构演进与核心理念

### 1.1 什么是 Serverless

Serverless（无服务器计算）是一种云计算执行模型，云服务商动态管理资源的分配和伸缩。开发者只需关注业务代码本身，而无需关心底层服务器。

### 1.2 Serverless 的演进之路

```
裸机服务器 → 虚拟机 → 容器 → K8s Pod → Serverless
  手动     虚拟化   封装    编排     完全抽象
```

| 阶段 | 特点 | 运维复杂度 | 资源利用率 |
|------|------|-----------|-----------|
| 裸机 | 物理服务器，手动部署 | 极高 | 低 |
| 虚拟机 | 资源隔离，虚拟化 | 高 | 中 |
| 容器 | 轻量级，快速启动 | 中 | 高 |
| K8s | 自动编排，弹性伸缩 | 较高 | 高 |
| Serverless | 无需管理服务器，按需付费 | 低 | 极高 |

### 1.3 Serverless 的核心特征

1. **弹性伸缩**：从零到无限，自动伸缩
2. **按需付费**：只为实际使用的计算资源付费
3. **无服务器管理**：无需管理 OS、运行时、中间件
4. **事件驱动**：通过事件触发函数执行
5. **状态外部化**：无状态计算，状态存储在外部服务

### 1.4 Serverless 的优缺点

**优点：**
- 降低运维成本
- 自动弹性伸缩
- 高资源利用率
- 按使用量计费

**缺点：**
- 冷启动延迟
- 有状态服务不友好
- 本地调试困难
- 供应商锁定风险

## 二、Knative 项目架构：Serving + Eventing

Knative 是 Google 发起的开源项目，旨在 Kubernetes 上提供 Serverless 工作负载的构建、部署和管理能力。2022 年 Knative 成为 CNCF 毕业项目。

### 2.1 两大核心组件

```
                    Knative
        ┌───────────────────────────┐
        │                           │
    ┌───┴────┐               ┌─────┴────────┐
    │ Serving │               │   Eventing   │
    │         │               │              │
    │ 自动伸缩 │               │ 事件路由    │
    │ 流量管理 │               │ 事件源      │
    │ 版本管理 │               │ 触发器      │
    │ 缩零    │               │ Broker/Sink  │
    └─────────┘               └──────────────┘
```

### 2.2 Knative Serving 详解

#### 核心资源模型

Knative Serving 定义了四个核心 CRD（Custom Resource Definition）：

```
Service (ksvc)
  └── Configuration
       └── Revision (revisions)
            └── Route
                 └── 流量分配
```

| 资源 | 说明 | 
|------|------|
| **Service** | 用户入口，管理整个服务生命周期 |
| **Configuration** | 描述期望的服务状态，每次变更创建新 Revision |
| **Revision** | 代码+配置的不可变快照，每个版本一个 Revision |
| **Route** | 流量路由，支持按百分比分发到不同 Revision |

#### Service YAML 示例

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello-world
  namespace: default
spec:
  template:
    metadata:
      name: hello-world-v1
      annotations:
        autoscaling.knative.dev/min-scale: "0"     # 最小实例数（0 = 允许缩零）
        autoscaling.knative.dev/max-scale: "10"    # 最大实例数
        autoscaling.knative.dev/target: "100"      # 每个 Pod 目标并发数
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: "Knative"
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
  traffic:
  - latestRevision: true
    percent: 100
```

### 2.3 Knative Eventing 详解

Eventing 提供了事件驱动架构的完整解决方案：

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│  Source   │────▶│  Broker  │────▶│  Sink    │
│ (事件源)  │     │   (代理)  │     │ (消费者) │
└──────────┘     └──────────┘     └──────────┘
                      │
                      ▼
                ┌──────────┐
                │  Trigger │
                │ (触发器) │
                └──────────┘
```

**核心概念：**

| 概念 | 说明 | 示例 |
|------|------|------|
| Source | 事件的产生者 | PingSource、KafkaSource、AWSS3Source |
| Broker | 事件代理，负责接收和路由事件 | InMemoryBroker、KafkaBroker |
| Trigger | 事件过滤和路由规则 | 基于事件类型/来源的路由 |
| Sink | 事件的消费者 | Knative Service、K8s Service、URI |
| Channel | 事件传输通道 | InMemoryChannel、KafkaChannel |

#### PingSource 示例

```yaml
apiVersion: sources.knative.dev/v1
kind: PingSource
metadata:
  name: ping-source
spec:
  schedule: "*/1 * * * *"
  contentType: "application/json"
  data: '{"message": "Hello Knative!"}'
  sink:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: event-display
```

#### Broker + Trigger 示例

```yaml
# 创建 Broker
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  name: default
  namespace: default
---
# 创建 Trigger（只路由特定事件）
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: order-trigger
spec:
  broker: default
  filter:
    attributes:
      type: com.example.order.created
      source: order-service
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: order-processor
```

## 三、自动伸缩：KPA 原理深度解析

### 3.1 KPA（Knative Pod Autoscaler）

KPA 是 Knative 内置的自动伸缩器，基于并发请求数（Concurrency）进行伸缩决策。

```
                     ┌────────────────┐
                     │  Queue-Proxy   │
                     │  (Sidecar)     │
                     └───────┬────────┘
                             │ 上报并发数
                             ▼
                     ┌────────────────┐
                     │  Autoscaler    │
                     │  计算期望 Pod  │
                     └───────┬────────┘
                             │ 伸缩指令
                             ▼
                     ┌────────────────┐
                     │  K8s HPA/      │
                     │  K8s Scale     │
                     └────────────────┘
```

### 3.2 伸缩算法

```text
期望 Pod 数 = 当前并发请求数 / TargetConcurrency

示例：
- Target = 100（每个 Pod 目标处理 100 并发）
- 当前请求数 = 450
- 期望 Pod 数 = 450 / 100 = 4.5 → 向上取整 = 5
```

### 3.3 缩零能力

Knative 最强大的特性之一：在没有流量时可以将 Pod 缩到 0。

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: my-service
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "0"       # 允许缩零
        autoscaling.knative.dev/window: "60s"        # 观察窗口
        autoscaling.knative.dev/scale-to-zero-pod-retention: "10m"  # 缩零保留时间
```

### 3.4 冷启动优化

冷启动是 Serverless 面临的普遍挑战，Knative 提供了多种优化方案：

| 方案 | 说明 | 适用场景 |
|------|------|----------|
| min-scale > 0 | 保持最小实例数 | 对延迟敏感的服务 |
| Blob Storage | 从远程加载运行时 | 大型镜像 |
| 预留 Activator | 快速转发请求 | 一般场景 |
| 预热请求 | 通过健康检查预热 | 需要初始化缓存 |

```yaml
# 保持 2 个 Ready Pod 来消除冷启动
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: low-latency-service
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "2"
        autoscaling.knative.dev/max-scale: "20"
        autoscaling.knative.dev/target: "80"
```

## 四、安装部署 Knative

### 4.1 前置条件

- Kubernetes 集群 1.24+
- kubectl 已配置
- 至少 4 GB 可用内存（测试环境）

### 4.2 使用 Knative Operator 安装

```bash
# 安装 Knative Operator
kubectl apply -f https://github.com/knative/operator/releases/latest/download/operator.yaml

# 等待 Operator Ready
kubectl wait --for=condition=ready pod -l app=knative-operator -n knative-operator

# 安装 Knative Serving
cat <<EOF | kubectl apply -f -
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec:
  config:
    autoscaler:
      scale-to-zero-enabled: "true"
      scale-to-zero-grace-period: "30s"
EOF

# 安装 Knative Eventing
cat <<EOF | kubectl apply -f -
apiVersion: operator.knative.dev/v1beta1
kind: KnativeEventing
metadata:
  name: knative-eventing
  namespace: knative-eventing
spec: {}
EOF
```

### 4.3 选择网络层

Knative 需要网络层来处理流量路由，支持以下选项：

| 网络层 | 特点 | 适用场景 |
|--------|------|----------|
| Kourier | 轻量级，基于 Envoy | 开发/测试环境 |
| Contour | 基于 Envoy，功能完整 | 生产环境 |
| Istio | 功能最丰富，具备完整 Service Mesh | 大型生产环境 |

```bash
# 安装 Kourier（推荐开发环境）
kubectl apply -f https://github.com/knative/net-kourier/releases/latest/download/kourier.yaml

# 配置 Knative 使用 Kourier
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
```

### 4.4 配置域名

```bash
# 配置自定义域名
kubectl patch configmap/config-domain \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"example.com":""}}'

# 获取 Knative 网关 IP
kubectl get svc kourier -n kourier-system

# 在 DNS 中配置通配符域名 *.example.com 指向该 IP
```

## 五、函数式服务开发实战

### 5.1 Go 语言 Knative Service

```go
// main.go
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func handler(w http.ResponseWriter, r *http.Request) {
    target := os.Getenv("TARGET")
    if target == "" {
        target = "World"
    }
    fmt.Fprintf(w, "Hello %s!\n", target)
}

func main() {
    log.Print("Hello world sample started.")
    http.HandleFunc("/", handler)
    http.ListenAndServe(":8080", nil)
}
```

```dockerfile
# Dockerfile
FROM golang:1.22 AS builder
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o app .

FROM alpine:3.19
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/app .
EXPOSE 8080
CMD ["./app"]
```

```bash
# 构建并推送镜像
docker build -t my-registry/hello-knative:latest .
docker push my-registry/hello-knative:latest

# 部署 Knative Service
cat <<EOF | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello-knative
spec:
  template:
    spec:
      containers:
      - image: my-registry/hello-knative:latest
        env:
        - name: TARGET
          value: "Knative"
        readinessProbe:
          httpGet:
            path: /
          periodSeconds: 5
          initialDelaySeconds: 5
EOF

# 测试
kubectl get ksvc hello-knative
curl -H "Host: hello-knative.default.example.com" http://<gateway-ip>
```

### 5.2 Python 函数服务

```python
# app.py
from flask import Flask
import os

app = Flask(__name__)

@app.route('/')
def hello():
    target = os.environ.get('TARGET', 'World')
    return f'Hello {target}!\n'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

```yaml
# service.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello-python
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "0"
        autoscaling.knative.dev/max-scale: "5"
    spec:
      containers:
      - image: my-registry/hello-python:latest
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: "Knative Python"
```

## 六、流量管理与灰度发布

### 6.1 多版本流量分发

```yaml
# 创建新版本并分配流量
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello-world
spec:
  template:
    metadata:
      name: hello-world-v2  # 新 Revision
    spec:
      containers:
      - image: my-registry/hello-world:v2
        env:
        - name: TARGET
          value: "v2"
  traffic:
  - revisionName: hello-world-v1
    percent: 90  # 90% 流量到 v1
  - revisionName: hello-world-v2
    percent: 10  # 10% 流量到 v2
```

### 6.2 基于 Tag 的流量路由

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello-world
spec:
  traffic:
  - revisionName: hello-world-v1
    percent: 100
  - revisionName: hello-world-v2
    percent: 0
    tag: staging  # 通过 staging 标签可以直接访问
```

访问方式：
- 正式 URL：`hello-world.default.example.com` → 100% v1
- 预发布 URL：`staging-hello-world.default.example.com` → v2

### 6.3 蓝绿部署

```bash
# 第一步：部署蓝环境（当前生产）
kubectl apply -f service-blue.yaml

# 第二步：创建绿环境
kubectl apply -f service-green.yaml

# 第三步：观察绿环境稳定后，切换流量
kubectl replace -f - <<EOF
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: my-service
spec:
  traffic:
  - revisionName: my-service-green
    percent: 100
EOF
```

## 七、与其他 Serverless 平台对比

| 对比维度 | Knative | OpenWhisk | OpenFaaS | AWS Lambda |
|----------|---------|-----------|----------|------------|
| **基础设施** | Kubernetes | 自定义 + K8s | Kubernetes | 托管平台 |
| **启动时间** | ~100ms-1s (冷启动) | ~200ms-1s | ~200ms-1s | ~100ms-500ms |
| **编程语言** | 任意（容器化） | 多语言（Action） | 任意（容器化） | 限定运行时 |
| **状态管理** | 无状态 | 无状态 | 无状态 | 无状态 |
| **事件源** | 丰富（K8s原生） | 丰富 | 中等 | 极丰富（AWS生态） |
| **伸缩到零** | ✅ | ✅ | ✅ | ✅ |
| **流量管理** | ✅ 完善 | ❌ | ⚠️ 有限 | ✅ (通过 API GW) |
| **冷启动优化** | 多方案 | 预热容器 | 热函数 | Provisioned Concurrency |
| **开源** | ✅ Apache 2.0 | ✅ Apache 2.0 | ✅ MIT | ❌ 闭源 |
| **运维复杂度** | 中高（需 K8s） | 中 | 低 | 无需运维 |
| **企业级特性** | 完善 | 中 | 基础 | 极完善 |
| **社区活跃度** | 高（CNCF毕业） | 中（Apache孵化） | 中 | N/A |

### 7.1 AWS Lambda vs Knative

当需要决定使用 AWS Lambda 还是自建 Knative 时，可以参考以下决策指标：

**选择 AWS Lambda 的场景：**
- 短时长任务（<15 分钟执行时间）
- 与 AWS 生态紧密集成（S3、DynamoDB、SQS 等）
- 需要极低运维成本
- 事件型、处理型工作负载

**选择 Knative 的场景：**
- 需要容器化部署的灵活性
- 长运行时间服务（Web 服务、API）
- 已有 Kubernetes 基础设施
- 需要避免供应商锁定
- 需要与现有微服务架构一致

## 八、生产环境注意事项与性能调优

### 8.1 生产环境配置建议

```yaml
# config-autoscaler.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-autoscaler
  namespace: knative-serving
data:
  scale-to-zero-enabled: "true"
  scale-to-zero-grace-period: "30s"     # 缩零前的等待时间
  stable-window: "60s"                   # 稳定窗口（避免抖动）
  panic-window: "10s"                    # 紧急窗口（突发流量检测）
  panic-threshold: "2.0"                 # 突发倍数，超过 2x 触发紧急伸缩
  max-scale-up-rate: "10"                # 最大扩容速率（每秒）
  max-scale-down-rate: "2"               # 最大缩容速率（每秒）
```

### 8.2 资源限制与请求

合理的资源配额配置对稳定性和成本控制至关重要：

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: production-service
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/target: "50"       # 每个 Pod 目标并发数
        autoscaling.knative.dev/metric: "concurrency"
    spec:
      containerConcurrency: 100                     # 每个 Pod 最大并发数
      containers:
      - image: my-registry/my-service:latest
        resources:
          requests:
            cpu: 500m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /healthz
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /healthz
          periodSeconds: 30
          failureThreshold: 3
```

### 8.3 监控与告警

部署 Knative 后需要监控的关键指标：

| 指标 | 说明 | 推荐告警阈值 |
|------|------|-------------|
| knative_service_ready_pods | Ready Pod 数量 | Min = 0 超过 5min |
| knative_activator_requests | Activator 转发请求数 | Sudden spike |
| knative_autoscaler_pods_count | Autoscaler 计算的目标 Pod | > maxScale 的 80% |
| queue_proxy_avg_concurrent_requests | 平均并发请求数 | > target 的 80% |
| cold_start_duration | 冷启动延迟 | > 1s |

```yaml
# Prometheus ServiceMonitor 示例
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: knative-serving-monitor
  namespace: knative-serving
spec:
  endpoints:
  - port: http-metrics
    interval: 15s
  selector:
    matchLabels:
      app: activator
      app: autoscaler
```

### 8.4 常见问题与解决方案

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 请求 503 | Activator 超时或容器未就绪 | 增大 readinessProbe 超时，调整稳定窗口 |
| 冷启动慢 | 镜像过大或依赖初始化 | 优化镜像大小，使用 min-scale > 0 |
| 频繁伸缩 | 流量抖动 | 增大 stable-window，降低 panic-threshold |
| Pod 启动失败 | 资源不足 | 调整 requests/limits，检查节点资源 |
| DNS 解析失败 | 域名配置错误 | 确认 ingress 配置和 DNS 记录 |

## 九、总结

Knative 为 Kubernetes 带来了真正的 Serverless 体验，在保留 K8s 灵活性的同时，提供了自动伸缩、缩零和事件驱动等 Serverless 核心能力。

### 实践建议

1. **从小规模开始**：先部署非关键服务，验证 Knative 的伸缩行为
2. **优化镜像大小**：使用多阶段构建，减小冷启动时间
3. **合理配置伸缩参数**：根据流量模式调整 target、window 和 scale 参数
4. **监控先行**：部署前配置好 Prometheus + Grafana 监控
5. **选择合适的网络层**：生产环境推荐 Istio 或 Contour
6. **事件驱动架构**：充分利用 Eventing 实现松耦合

### 未来展望

随着 WASM（WebAssembly）、eBPF 等新技术的成熟，Serverless 领域正在经历更深层次的变革。Knative 社区也在积极探索与这些技术的融合。对于团队而言，现在开始拥抱 Serverless 架构，将为未来的云原生转型奠定坚实基础。

> Serverless 不是没有服务器，而是让开发者不再关心服务器。
