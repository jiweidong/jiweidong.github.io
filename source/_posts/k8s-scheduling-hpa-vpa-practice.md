---
title: Kubernetes 调度与自动伸缩深度实践：Pod 调度、HPA 与 VPA
date: 2026-06-17 11:00:00
tags:
  - Kubernetes
  - Pod调度
  - HPA
  - VPA
  - 自动伸缩
categories:
  - DevOps
author: 东哥
---

# Kubernetes 调度与自动伸缩深度实践：Pod 调度、HPA 与 VPA

## 一、Kubernetes 调度器原理

调度是 Kubernetes 的核心能力之一。kube-scheduler 负责为新创建的 Pod 选择一个最合适的 Node，这个过程本质上是一个"得分最高的节点获胜"的决策过程。

### 1.1 调度流程

```
Pending Pod
    │
    ▼
┌─────────────────────────────┐
│  1. 调度队列 (Scheduling Queue)  │
│     Priority Sort            │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  2. 预选阶段 (Filtering)       │
│     ┌───────────────────┐    │
│     │ NodeUnreachable   │    │
│     │ NodeResources     │    │
│     │ NodePorts         │    │
│     │ NodeAffinity      │    │
│     │ TaintToleration   │    │
│     │ PodFitsResources  │    │
│     │ PodTopologySpread │    │
│     └───────────────────┘    │
│     → 候选节点列表            │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  3. 优选阶段 (Scoring)        │
│     ┌───────────────────┐    │
│     │ ResourceWeighted  │ ← CPU/Memory 亲和
│     │ NodeAffinity      │    │
│     │ TaintToleration   │    │
│     │ ImageLocality     │ ← 本地镜像
│     │ InterPodAffinity  │    │
│     └───────────────────┘    │
│     → 各节点打分 (0-100)     │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  4. 绑定阶段 (Binding)        │
│     → 选取得分最高的节点      │
│     → 更新 Pod.NodeName      │
└─────────────────────────────┘
```

### 1.2 节点打分详解

| 评分插件 | 权重 | 说明 | 计算公式 |
|---------|------|------|---------|
| NodeResourcesBalanced | 1 | 资源均衡度 | 1 - |cpu-mem偏差| |
| NodeResourcesLeastAllocated | 1 | 最少已分配资源 | (空闲总量/总量) × 100 |
| ImageLocality | 0 | 本地镜像优先 | 已存在镜像的节点高分 |
| NodeAffinity | 2 | 节点亲和性 | 匹配则高分 |
| TaintToleration | 2 | 污点容忍 | 匹配加分 |
| InterPodAffinity | 2 | Pod 间亲和 | 亲和加分/反亲和加分 |
| PodTopologySpread | 2 | 拓扑分布 | 均匀分布加分 |

## 二、节点选择与控制

### 2.1 NodeSelector — 最简单的方式

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-gpu
spec:
  nodeSelector:
    hardware: gpu
    disk-type: ssd
  containers:
  - name: nginx
    image: nginx:alpine
```

给节点打标签：
```bash
kubectl label nodes worker-1 hardware=gpu
kubectl label nodes worker-1 disk-type=ssd
```

### 2.2 NodeAffinity — 更灵活的方式

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  replicas: 3
  template:
    spec:
      affinity:
        nodeAffinity:
          # 必须满足的条件（硬约束）
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:
                - us-east-1a
                - us-east-1b
          # 尽量满足的条件（软约束）
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 80
            preference:
              matchExpressions:
              - key: hardware
                operator: In
                values:
                - high-cpu
          - weight: 20
            preference:
              matchExpressions:
              - key: disk-type
                operator: In
                values:
                - ssd
      containers:
      - name: order-service
        image: order-service:latest
```

### 2.3 PodAffinity 与 PodAntiAffinity

```yaml
spec:
  affinity:
    podAffinity:
      # 与支付服务部署在同一节点
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - payment-service
        topologyKey: kubernetes.io/hostname
    
    podAntiAffinity:
      # 相同服务的副本分散到不同节点
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values:
              - order-service
          topologyKey: kubernetes.io/hostname
```

### 2.4 Taints 和 Tolerations

Taint 是打在 Node 上的"污点"，只有容忍了该污点的 Pod 才能调度上去。

```bash
# 给节点打污点
kubectl taint nodes node1 dedicated=prod:NoSchedule
kubectl taint nodes node2 gpu=true:NoExecute

# 查看污点
kubectl describe node node1 | grep Taints
```

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "prod"
        effect: "NoSchedule"
      - key: "gpu"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 300  # 300 秒后才被驱逐
```

| Effect | 行为 |
|--------|------|
| NoSchedule | 不调度到该节点（已有的 Pod 不受影响） |
| PreferNoSchedule | 尽量不调度（软约束） |
| NoExecute | 不调度 + 已有 Pod 会被驱逐 |

## 三、PodTopologySpread — 拓扑分布调度

### 3.1 均匀分布配置

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-service
spec:
  replicas: 9
  template:
    spec:
      topologySpreadConstraints:
      - maxSkew: 1           # 最大偏差（允许的不均衡度）
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule  # 调度约束
        labelSelector:
          matchLabels:
            app: web-service
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: web-service
```

三个可用区、9 个副本的分布效果：

| 可用区 | 节点 | Pod 数 | 分布效果 |
|-------|------|--------|---------|
| zone-a | node-1, node-2 | 3 | 每节点 ≤ 2 |
| zone-b | node-3, node-4 | 3 | 每节点 ≤ 2 |
| zone-c | node-5 | 3 | 可控的偏差 |

## 四、水平自动伸缩（HPA）

### 4.1 HPA 工作原理

HPA（Horizontal Pod Autoscaler）根据 CPU / 内存利用率或自定义指标自动调整 Pod 副本数。

```
Algorithms:
  desiredReplicas = ceil[currentReplicas × (currentMetric / desiredMetric)]

  实际 CPU = 60%, 目标 CPU = 50%, 当前副本 = 3
  desiredReplicas = ceil[3 × (60 / 50)] = ceil[3.6] = 4
```

### 4.2 基于 CPU/内存的 HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # 稳定窗口 5 分钟
      policies:
      - type: Percent
        value: 10      # 每分钟最多缩容 10%
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0    # 扩容无稳定窗口
      policies:
      - type: Percent
        value: 100     # 每分钟最多扩容 100%
        periodSeconds: 60
      - type: Pods
        value: 4       # 每分钟最多增加 4 个 Pod
        periodSeconds: 60
      selectPolicy: Max
```

### 4.3 基于自定义指标的 HPA

需要安装 Prometheus Adapter 或 Metrics Server：

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payment-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payment-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
  # 基于 QPS 伸缩
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: 1000
  # 基于队列长度伸缩
  - type: Object
    object:
      metric:
        name: rabbitmq_queue_depth
      describedObject:
        apiVersion: v1
        kind: Service
        name: rabbitmq-metrics
      target:
        type: Value
        value: 100
```

## 五、垂直自动伸缩（VPA）

VPA（Vertical Pod Autoscaler）自动调整 Pod 的 CPU/内存 Request 和 Limit。

### 5.1 VPA 工作模式

| 模式 | 行为 | 适用场景 |
|------|------|---------|
| Auto | 自动更新资源请求并重启 Pod | 无状态服务 |
| Initial | 仅创建时应用推荐值 | 启动时就设定合理值 |
| Off | 仅给出推荐值不自动调整 | 手动参考 |

### 5.2 VPA 配置

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: recommendation-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: recommendation-service
  updatePolicy:
    updateMode: Auto
  resourcePolicy:
    containerPolicies:
    - containerName: recommendation
      minAllowed:
        cpu: "100m"
        memory: "128Mi"
      maxAllowed:
        cpu: "2"
        memory: "1Gi"
      controlledResources: ["cpu", "memory"]
```

### 5.3 查看 VPA 建议

```bash
kubectl describe vpa recommendation-vpa

# 输出示例:
# Recommendation:
#   Container Recommendations:
#     Container:  recommendation
#     Lower Bound:
#       Cpu:     150m
#       Memory:  256Mi
#     Upper Bound:
#       Cpu:     750m
#       Memory:  512Mi
#     Target:
#       Cpu:     250m
#       Memory:  400Mi
```

## 六、Cluster Autoscaler — 集群级伸缩

当 HPA 扩容后节点资源不足时，Cluster Autoscaler 会自动添加节点。

```yaml
# cluster-autoscaler deployment 关键参数
command:
  - ./cluster-autoscaler
  - --cloud-provider=aws
  - --nodes=3:20:eks-worker-asg
  - --scale-down-delay-after-add=10m
  - --scale-down-unneeded-time=10m
  - --max-node-provision-time=15m
```

| 参数 | 作用 | 推荐值 |
|------|------|--------|
| scale-down-delay-after-add | 扩容后多久可缩容 | 10m |
| scale-down-unneeded-time | 节点闲置多久算多余 | 10m |
| scale-down-utilization-threshold | 节点利用率低于此值触发缩容 | 0.5 |
| max-node-provision-time | 节点创建超时时间 | 15m |

## 七、生产最佳实践

### 7.1 资源请求与限制建议

```yaml
resources:
  requests:
    cpu: "500m"      # 保证 0.5 核
    memory: "512Mi"  # 保证 512M
  limits:
    cpu: "1"         # 最多用 1 核
    memory: "1Gi"    # 最多用 1G
```

| 服务类型 | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------|------------|-----------|---------------|-------------|
| Java 微服务 | 0.5-1 | 2-4 | 512Mi-1Gi | 1Gi-2Gi |
| Node.js | 0.1-0.5 | 1-2 | 128Mi-256Mi | 512Mi |
| Nginx | 0.1 | 0.5 | 64Mi | 128Mi |
| Redis | 0.5-1 | 2 | 1Gi | 2Gi |

### 7.2 常见调度问题排查

```bash
# 查看 Pod 为何 Pending
kubectl describe pod <pod-name>

# 查看节点资源剩余
kubectl describe node <node-name>

# 查看事件
kubectl get events --sort-by='.lastTimestamp'

# 模拟调度
kubectl plugin sim  # kube-scheduler-simulator
```

### 7.3 调度策略模板

```bash
# 生产环境：高 CPU 服务打散 + 同可用区部署
# 测试环境：尽量复用节点（不浪费资源）
# 批处理：容忍任意节点 + 无反亲和
```

熟练掌握 Kubernetes 调度与自动伸缩，可以极大地提升集群的资源利用率和稳定性。通过 NodeAffinity、Taint/Toleration、PodTopologySpread、HPA、VPA 和 Cluster Autoscaler 的组合使用，可以构建一个高弹性、高可用的生产级集群。
