---
title: Kubernetes Operator 开发实战
date: 2026-06-18 08:00:00
tags:
  - Kubernetes
  - Operator
  - 云原生
  - CRD
categories:
  - 容器化
author: 东哥
---

# Kubernetes Operator 开发实战

## 一、Operator 模式概述

### 1.1 什么是 Operator

Operator 是 Kubernetes 上的应用控制器扩展模式，它将运维人员对特定应用的领域知识编码为软件，让机器自动执行运维任务。Operator 通过自定义资源（CRD）和控制器（Controller）两个核心组件，实现应用的自动化部署、扩缩容、备份恢复、故障处理等运维工作。

### 1.2 适用场景

| 场景 | 说明 | 典型 Operator |
|------|------|--------------|
| 有状态应用 | 数据库、缓存、消息队列 | Operator for MySQL, Redis, Kafka |
| 自动扩缩容 | 根据业务指标自动调整 | KEDA, HPA Operator |
| 备份恢复 | 定时备份、灾难恢复 | Velero, Stash |
| 安全管理 | 证书管理、安全策略 | cert-manager, Vault Operator |
| 监控集成 | Prometheus 集成、告警管理 | Prometheus Operator |
| CI/CD | 自动化部署流水线 | ArgoCD Operator, Tekton |

### 1.3 工作原理

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes API Server                   │
│  ┌──────────────────┐        ┌─────────────────────┐    │
│  │  CRD (自定义资源)  │        │  Other Resources    │    │
│  │  AppCluster       │        │  Deployment, Service │    │
│  └────────┬─────────┘        └────────┬────────────┘    │
└───────────┼───────────────────────────┼─────────────────┘
            │ Watch                     │ Watch
            ▼                           ▼
┌─────────────────────────────────────────────────────────┐
│                    Operator (Controller)                   │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Reconcile Loop (调谐循环)                           │ │
│  │  1. 读取当前状态 (Read Current State)                │ │
│  │  2. 对比期望状态 (Compare with Desired State)        │ │
│  │  3. 执行差异操作 (Execute Reconciliation)             │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## 二、环境准备

### 2.1 开发工具链

```bash
# 1. 安装 Go (1.22+)
wget https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc

# 2. 安装 kubebuilder（Operator 脚手架）
curl -L -o kubebuilder "https://go.kubebuilder.io/dl/latest/$(go env GOOS)/$(go env GOARCH)"
chmod +x kubebuilder && sudo mv kubebuilder /usr/local/bin/

# 3. 安装 controller-gen
go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest

# 4. 安装 kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

# 5. 验证安装
kubebuilder version
controller-gen --version
kustomize version
```

### 2.2 初始化 Operator 项目

```bash
# 创建项目
mkdir -p ~/projects/my-operator
cd ~/projects/my-operator

# 初始化 (group 决定 API 路径, domain 决定 CRD 名称)
kubebuilder init --domain example.com --repo github.com/myuser/my-operator

# 创建 API 和 Controller
kubebuilder create api \
  --group cache \
  --version v1 \
  --kind RedisCluster \
  --resource=true \
  --controller=true

# 项目结构
# tree my-operator/
# ├── api/
# │   └── v1/
# │       ├── rediscluster_types.go    # CRD 类型定义
# │       └── zz_generated.deepcopy.go  # 自动生成的 deepcopy
# ├── config/
# │   ├── crd/                          # CRD YAML
# │   ├── manager/                      # Operator 部署配置
# │   ├── rbac/                         # RBAC 权限
# │   └── samples/                      # 示例资源
# ├── controllers/
# │   └── rediscluster_controller.go    # 控制器逻辑
# ├── main.go                           # 入口
# └── Dockerfile                        # 容器化
```

## 三、CRD 定义

### 3.1 类型定义

```go
// api/v1/rediscluster_types.go

package v1

import (
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// RedisClusterSpec 定义期望状态
type RedisClusterSpec struct {
    // 副本数
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=100
    Replicas int32 `json:"replicas"`
    
    // 镜像
    // +kubebuilder:default="redis:7-alpine"
    Image string `json:"image,omitempty"`
    
    // 端口
    // +kubebuilder:validation:Minimum=1024
    // +kubebuilder:default=6379
    Port int32 `json:"port,omitempty"`
    
    // 资源限制
    Resources corev1.ResourceRequirements `json:"resources,omitempty"`
    
    // 持久化配置
    // +optional
    Storage *StorageConfig `json:"storage,omitempty"`
    
    // 密码引用（Secret）
    // +optional
    PasswordSecret *corev1.SecretKeySelector `json:"passwordSecret,omitempty"`
    
    // 配置覆盖
    // +optional
    Config map[string]string `json:"config,omitempty"`
}

type StorageConfig struct {
    // 存储大小
    // +kubebuilder:validation:Pattern="^([1-9][0-9]*)(Mi|Gi|Ti)$"
    Size string `json:"size"`
    
    // 存储类
    // +optional
    StorageClassName string `json:"storageClassName,omitempty"`
}

// RedisClusterStatus 定义观测状态
type RedisClusterStatus struct {
    // 就绪副本数
    ReadyReplicas int32 `json:"readyReplicas,omitempty"`
    
    // 状态 (Creating/Running/Upgrading/Error)
    Phase string `json:"phase,omitempty"`
    
    // 集群连接端点
    Endpoint string `json:"endpoint,omitempty"`
    
    // 节点列表
    Nodes []string `json:"nodes,omitempty"`
    
    // 最后更新的时间
    LastUpdated metav1.Time `json:"lastUpdated,omitempty"`
    
    // 条件列表
    Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase"
// +kubebuilder:printcolumn:name="Ready",type="integer",JSONPath=".status.readyReplicas"
// +kubebuilder:printcolumn:name="Replicas",type="integer",JSONPath=".spec.replicas"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"
type RedisCluster struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`
    
    Spec   RedisClusterSpec   `json:"spec,omitempty"`
    Status RedisClusterStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type RedisClusterList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []RedisCluster `json:"items"`
}

func init() {
    SchemeBuilder.Register(&RedisCluster{}, &RedisClusterList{})
}
```

### 3.2 生成 CRD YAML

```bash
# 生成 CRD 和 RBAC YAML
make generate  # 生成 deepcopy
make manifests # 生成 CRD YAML

# 查看生成的 CRD
cat config/crd/bases/cache.example.com_redisclusters.yaml

# 部署 CRD 到集群
kubectl apply -f config/crd/
```

## 四、控制器实现

### 4.1 调谐循环

```go
// controllers/rediscluster_controller.go

package controllers

import (
    "context"
    "fmt"
    appsv1 "k8s.io/api/apps/v1"
    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/api/errors"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/types"
    "k8s.io/apimachinery/pkg/util/intstr"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log"
    
    cachev1 "my-operator/api/v1"
)

// RedisClusterReconciler 调谐器
type RedisClusterReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=cache.example.com,resources=redisclusters,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=cache.example.com,resources=redisclusters/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=cache.example.com,resources=redisclusters/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services;configmaps;secrets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=events,verbs=create;patch

func (r *RedisClusterReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    logger := log.FromContext(ctx)
    
    // 1. 获取 RedisCluster 资源
    redisCluster := &cachev1.RedisCluster{}
    if err := r.Get(ctx, req.NamespacedName, redisCluster); err != nil {
        if errors.IsNotFound(err) {
            return ctrl.Result{}, nil
        }
        return ctrl.Result{}, err
    }
    
    logger.Info("开始调谐", "name", redisCluster.Name, "replicas", redisCluster.Spec.Replicas)
    
    // 2. 设置默认值
    r.setDefaults(redisCluster)
    
    // 3. 确保 Service 存在
    if err := r.ensureService(ctx, redisCluster); err != nil {
        return ctrl.Result{}, err
    }
    
    // 4. 确保 ConfigMap 存在
    if err := r.ensureConfigMap(ctx, redisCluster); err != nil {
        return ctrl.Result{}, err
    }
    
    // 5. 确保 StatefulSet 存在
    if err := r.ensureStatefulSet(ctx, redisCluster); err != nil {
        return ctrl.Result{}, err
    }
    
    // 6. 更新状态
    if err := r.updateStatus(ctx, redisCluster); err != nil {
        return ctrl.Result{}, err
    }
    
    return ctrl.Result{}, nil
}

func (r *RedisClusterReconciler) setDefaults(redisCluster *cachev1.RedisCluster) {
    if redisCluster.Spec.Image == "" {
        redisCluster.Spec.Image = "redis:7-alpine"
    }
    if redisCluster.Spec.Port == 0 {
        redisCluster.Spec.Port = 6379
    }
}
```

### 4.2 子资源管理

```go
// 创建/更新 Service
func (r *RedisClusterReconciler) ensureService(
    ctx context.Context, 
    redisCluster *cachev1.RedisCluster,
) error {
    svc := &corev1.Service{}
    svc.Name = redisCluster.Name
    svc.Namespace = redisCluster.Namespace
    
    if err := r.Get(ctx, types.NamespacedName{
        Name: svc.Name, Namespace: svc.Namespace,
    }, svc); err != nil {
        if !errors.IsNotFound(err) {
            return err
        }
        
        // 创建 Service
        svc = r.buildService(redisCluster)
        if err := r.Create(ctx, svc); err != nil {
            return err
        }
        log.FromContext(ctx).Info("Service 已创建", "name", svc.Name)
    }
    
    return nil
}

func (r *RedisClusterReconciler) buildService(
    redisCluster *cachev1.RedisCluster,
) *corev1.Service {
    labels := map[string]string{
        "app": "redis-cluster",
        "redis_cluster": redisCluster.Name,
    }
    
    return &corev1.Service{
        ObjectMeta: metav1.ObjectMeta{
            Name:      redisCluster.Name,
            Namespace: redisCluster.Namespace,
            Labels:    labels,
        },
        Spec: corev1.ServiceSpec{
            Ports: []corev1.ServicePort{
                {
                    Name:       "redis",
                    Port:       redisCluster.Spec.Port,
                    TargetPort: intstr.FromInt(int(redisCluster.Spec.Port)),
                },
            },
            Selector: labels,
            Type:     corev1.ServiceTypeClusterIP,
        },
    }
}

// 创建/更新 StatefulSet
func (r *RedisClusterReconciler) ensureStatefulSet(
    ctx context.Context,
    redisCluster *cachev1.RedisCluster,
) error {
    sts := &appsv1.StatefulSet{}
    sts.Name = redisCluster.Name
    sts.Namespace = redisCluster.Namespace
    
    desiredSts := r.buildStatefulSet(redisCluster)
    
    if err := r.Get(ctx, types.NamespacedName{
        Name: sts.Name, Namespace: sts.Namespace,
    }, sts); err != nil {
        if !errors.IsNotFound(err) {
            return err
        }
        
        // 设置 OwnerReference（级联删除）
        if err := ctrl.SetControllerReference(
            redisCluster, desiredSts, r.Scheme); err != nil {
            return err
        }
        
        return r.Create(ctx, desiredSts)
    }
    
    // 更新现有 StatefulSet（只更新需要的字段）
    sts.Spec.Replicas = desiredSts.Spec.Replicas
    sts.Spec.Template.Spec.Containers[0].Image = 
        desiredSts.Spec.Template.Spec.Containers[0].Image
    sts.Spec.Template.Spec.Containers[0].Resources = 
        desiredSts.Spec.Template.Spec.Containers[0].Resources
    
    return r.Update(ctx, sts)
}

func (r *RedisClusterReconciler) buildStatefulSet(
    redisCluster *cachev1.RedisCluster,
) *appsv1.StatefulSet {
    labels := map[string]string{
        "app": "redis-cluster",
        "redis_cluster": redisCluster.Name,
    }
    
    sts := &appsv1.StatefulSet{
        ObjectMeta: metav1.ObjectMeta{
            Name:      redisCluster.Name,
            Namespace: redisCluster.Namespace,
            Labels:    labels,
        },
        Spec: appsv1.StatefulSetSpec{
            Replicas: &redisCluster.Spec.Replicas,
            ServiceName: redisCluster.Name,
            Selector: &metav1.LabelSelector{
                MatchLabels: labels,
            },
            Template: corev1.PodTemplateSpec{
                ObjectMeta: metav1.ObjectMeta{
                    Labels: labels,
                },
                Spec: corev1.PodSpec{
                    Containers: []corev1.Container{
                        {
                            Name:  "redis",
                            Image: redisCluster.Spec.Image,
                            Ports: []corev1.ContainerPort{
                                {
                                    ContainerPort: redisCluster.Spec.Port,
                                    Name:          "redis",
                                },
                            },
                            Resources: redisCluster.Spec.Resources,
                        },
                    },
                },
            },
        },
    }
    
    // 添加存储卷
    if redisCluster.Spec.Storage != nil {
        sts.Spec.VolumeClaimTemplates = []corev1.PersistentVolumeClaim{
            {
                ObjectMeta: metav1.ObjectMeta{
                    Name: "data",
                },
                Spec: corev1.PersistentVolumeClaimSpec{
                    AccessModes: []corev1.PersistentVolumeAccessMode{
                        corev1.ReadWriteOnce,
                    },
                    Resources: corev1.VolumeResourceRequirements{
                        Requests: corev1.ResourceList{
                            corev1.ResourceStorage: 
                                resource.MustParse(redisCluster.Spec.Storage.Size),
                        },
                    },
                },
            },
        }
        
        sts.Spec.Template.Spec.Containers[0].VolumeMounts = []corev1.VolumeMount{
            {
                Name:      "data",
                MountPath: "/data",
            },
        }
    }
    
    return sts
}
```

### 4.3 状态更新

```go
func (r *RedisClusterReconciler) updateStatus(
    ctx context.Context,
    redisCluster *cachev1.RedisCluster,
) error {
    sts := &appsv1.StatefulSet{}
    err := r.Get(ctx, types.NamespacedName{
        Name: redisCluster.Name,
        Namespace: redisCluster.Namespace,
    }, sts)
    
    if err != nil {
        redisCluster.Status.Phase = "Error"
    } else {
        redisCluster.Status.ReadyReplicas = sts.Status.ReadyReplicas
        redisCluster.Status.Endpoint = fmt.Sprintf(
            "%s.%s.svc.cluster.local:%d",
            redisCluster.Name,
            redisCluster.Namespace,
            redisCluster.Spec.Port,
        )
        
        // 根据就绪状态设置阶段
        if sts.Status.ReadyReplicas == 0 {
            redisCluster.Status.Phase = "Creating"
        } else if sts.Status.ReadyReplicas < redisCluster.Spec.Replicas {
            redisCluster.Status.Phase = "Scaling"
        } else {
            redisCluster.Status.Phase = "Running"
        }
        
        // 获取 Pod 列表
        podList := &corev1.PodList{}
        r.List(ctx, podList, client.MatchingLabels{
            "redis_cluster": redisCluster.Name,
        })
        
        var nodes []string
        for _, pod := range podList.Items {
            nodes = append(nodes, pod.Name)
        }
        redisCluster.Status.Nodes = nodes
    }
    
    redisCluster.Status.LastUpdated = metav1.Now()
    redisCluster.Status.Conditions = append(redisCluster.Status.Conditions, metav1.Condition{
        Type:               "Ready",
        Status:             metav1.ConditionTrue,
        LastTransitionTime: metav1.Now(),
        Reason:             "Reconciled",
        Message:            "调谐完成",
    })
    
    return r.Status().Update(ctx, redisCluster)
}
```

## 五、部署与测试

### 5.1 本地测试

```bash
# 运行控制器（本地，连远端集群）
make install  # 安装 CRD
make run      # 本地运行控制器

# 应用示例资源
kubectl apply -f config/samples/cache_v1_rediscluster.yaml

# 查看资源状态
kubectl get redisclusters
kubectl describe rediscluster rediscluster-sample
kubectl get pods -l app=redis-cluster
kubectl logs -l app=redis-cluster

# 删除资源
kubectl delete rediscluster rediscluster-sample
```

### 5.2 容器化部署

```dockerfile
# Dockerfile
FROM golang:1.22 AS builder
WORKDIR /workspace
COPY go.mod go.mod
COPY go.sum go.sum
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -o manager main.go

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /workspace/manager .
USER 65532:65532
ENTRYPOINT ["/manager"]
```

```bash
# 构建和推送镜像
make docker-build docker-push IMG=myregistry/my-operator:v1.0.0

# 部署到集群
make deploy IMG=myregistry/my-operator:v1.0.0

# 查看 Operator Pod
kubectl get pods -n my-operator-system

# 查看 Operator 日志
kubectl logs deployment/my-operator-controller-manager -n my-operator-system
kubectl logs -n my-operator-system -l control-plane=controller-manager
```

### 5.3 测试示例

```yaml
# config/samples/cache_v1_rediscluster.yaml
apiVersion: cache.example.com/v1
kind: RedisCluster
metadata:
  name: redis-cluster-prod
spec:
  replicas: 3
  image: redis:7-alpine
  port: 6379
  resources:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      cpu: "1"
      memory: "1Gi"
  storage:
    size: 10Gi
    storageClassName: standard
  config:
    maxmemory: "512mb"
    maxmemory-policy: "allkeys-lru"
    save: "900 1 300 10 60 10000"
```

## 六、高级特性

### 6.1 Finalizer（终结器）

```go
const redisFinalizer = "finalizer.cache.example.com"

func (r *RedisClusterReconciler) reconcileFinalizers(
    ctx context.Context,
    redisCluster *cachev1.RedisCluster,
) (ctrl.Result, error) {
    // 检查是否正在删除
    if redisCluster.DeletionTimestamp.IsZero() {
        // 未删除，确保 finalizer 存在
        if !controllerutil.ContainsFinalizer(redisCluster, redisFinalizer) {
            controllerutil.AddFinalizer(redisCluster, redisFinalizer)
            if err := r.Update(ctx, redisCluster); err != nil {
                return ctrl.Result{}, err
            }
        }
    } else {
        // 正在删除，执行清理
        if controllerutil.ContainsFinalizer(redisCluster, redisFinalizer) {
            if err := r.cleanup(ctx, redisCluster); err != nil {
                return ctrl.Result{}, err
            }
            
            controllerutil.RemoveFinalizer(redisCluster, redisFinalizer)
            if err := r.Update(ctx, redisCluster); err != nil {
                return ctrl.Result{}, err
            }
        }
    }
    
    return ctrl.Result{}, nil
}

func (r *RedisClusterReconciler) cleanup(
    ctx context.Context,
    redisCluster *cachev1.RedisCluster,
) error {
    // 执行清理操作
    // 例如：备份数据、通知外部系统、释放云资源等
    log.FromContext(ctx).Info("清理资源", "name", redisCluster.Name)
    return nil
}
```

### 6.2 状态条件

```go
// 统一的条件管理
func (r *RedisClusterReconciler) setCondition(
    redisCluster *cachev1.RedisCluster,
    conditionType string,
    status metav1.ConditionStatus,
    reason, message string,
) {
    now := metav1.Now()
    for i, c := range redisCluster.Status.Conditions {
        if c.Type == conditionType {
            if c.Status != status {
                redisCluster.Status.Conditions[i].Status = status
                redisCluster.Status.Conditions[i].LastTransitionTime = now
            }
            redisCluster.Status.Conditions[i].Reason = reason
            redisCluster.Status.Conditions[i].Message = message
            redisCluster.Status.Conditions[i].ObservedGeneration = 
                redisCluster.Generation
            return
        }
    }
    
    redisCluster.Status.Conditions = append(
        redisCluster.Status.Conditions,
        metav1.Condition{
            Type:               conditionType,
            Status:             status,
            LastTransitionTime: now,
            Reason:             reason,
            Message:            message,
            ObservedGeneration: redisCluster.Generation,
        },
    )
}
```

### 6.3 Webhook 验证

```go
// api/v1/rediscluster_webhook.go

package v1

import (
    "context"
    "fmt"
    apierrors "k8s.io/apimachinery/pkg/api/errors"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/util/validation/field"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/webhook"
)

func (r *RedisCluster) SetupWebhookWithManager(mgr ctrl.Manager) error {
    return ctrl.NewWebhookManagedBy(mgr).
        For(r).
        Complete()
}

// 创建校验
func (r *RedisCluster) ValidateCreate(ctx context.Context, 
    obj runtime.Object) error {
    cluster := obj.(*RedisCluster)
    var allErrs field.ErrorList
    
    if cluster.Spec.Replicas < 1 || cluster.Spec.Replicas > 100 {
        allErrs = append(allErrs, field.Invalid(
            field.NewPath("spec.replicas"),
            cluster.Spec.Replicas,
            "副本数必须在 1-100 之间",
        ))
    }
    
    if len(allErrs) == 0 {
        return nil
    }
    
    return apierrors.NewInvalid(
        GroupVersion.WithKind("RedisCluster").GroupKind(),
        cluster.Name, allErrs)
}
```

## 七、生产化考虑

### 7.1 可观测性

| 组件 | 指标 | 暴露端口 | 采集方式 |
|------|------|---------|---------|
| Controller | Reconcile 次数/耗时 | :8080/metrics | Prometheus |
| Cache | 请求延迟/错误率 | 应用指标 | Prometheus |
| 事件 | 操作事件 | 写入 K8s Events | 日志采集 |
| 日志 | 结构化日志 | stdout | Loki |

### 7.2 性能优化

```go
// 1. 使用缓存
func (r *RedisClusterReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // Informer 已提供缓存，不需要重复 Get
    // 对于热点资源，可以添加内存缓存
    
    // 2. 减少 API 调用 - 使用 Patch 而不是 Update
    patch := client.MergeFrom(redisCluster.DeepCopy())
    redisCluster.Status.Phase = "Running"
    if err := r.Status().Patch(ctx, redisCluster, patch); err != nil {
        return ctrl.Result{}, err
    }
    
    // 3. 批量处理
    return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// 4. 并发控制 - 使用 MaxConcurrentReconciles
func SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&cachev1.RedisCluster{}).
        WithOptions(controller.Options{
            MaxConcurrentReconciles: 10,
        }).
        Complete(r)
}
```

### 7.3 更新策略

```yaml
# config/manager/manager.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: controller-manager
  namespace: my-operator-system
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    spec:
      containers:
      - command:
        - /manager
        args:
        - --leader-elect=true      # 启用选举防止多实例冲突
        - --health-probe-bind-address=:8081
        - --metrics-bind-address=:8080
        ports:
        - containerPort: 9443      # Webhook 端口
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
```

## 八、Operator SDK 选择

| SDK | 语言 | 学习曲线 | 功能 | 成熟度 |
|-----|------|---------|------|-------|
| kubebuilder | Go | 中 | 完整 | 高 (CNCF) |
| Operator SDK | Go/Ansible/Helm | 低-高 | 完整 | 高 |
| Kopf | Python | 低 | 基本 | 中 |
| Java Operator SDK | Java | 中 | 完整 | 中 |
| Chalk | Rust | 高 | 基本 | 低 |
| Shell Operator | Shell | 低 | 基本 | 低 |

推荐：新项目优先选择 kubebuilder（Go 实现），它是目前最活跃和维护最好的 Operator 框架。

## 总结

Kubernetes Operator 通过 CRD + Controller 的模式，将运维知识代码化，实现了应用的自动化管理。开发一个完整的 Operator 需要掌握 CRD 定义、调谐循环设计、子资源管理、状态更新、Webhook 验证、Finalizer 清理等核心概念。

**实施建议：**
1. 从简单的无状态应用开始，逐步过渡到有状态应用
2. 充分利用 kubebuilder 脚手架，减少样板代码
3. 设计清晰的 CRD API，考虑版本兼容性
4. 添加完善的 Webhook 验证，防止错误配置
5. 关注可观测性，确保 Operator 自身的监控和告警完善
6. 使用 Leader Election 保证高可用
