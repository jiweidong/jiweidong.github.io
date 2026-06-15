---
title: Kubernetes（K8s）核心技术与集群实战
date: 2026-06-15 08:30:00
tags:
  - Kubernetes
  - K8s
  - 容器编排
  - DevOps
categories:
  - DevOps
author: 东哥
---

# Kubernetes（K8s）核心技术与集群实战

> Kubernetes（简称 K8s）是当今最流行的容器编排平台。本文从基础概念到集群搭建，再到生产运维，带你全面掌握 K8s。

## 一、Kubernetes 核心概念

### 1.1 架构总览

Kubernetes 采用 Master-Worker 架构：

```
┌─────────────────────────────────────┐
│         Master 节点                  │
│  ┌────────┐ ┌───────┐ ┌─────────┐  │
│  │API Server││Scheduler││Controller│  │
│  └────────┘ └───────┘ └─────────┘  │
│  ┌──────────────────────────────┐   │
│  │        etcd (分布式存储)       │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
              │
    ┌─────────┼──────────────┐
    │         │              │
┌──────┐ ┌──────┐     ┌──────┐
│Node-1│ │Node-2│ ... │Node-N│
│ Kubelet│ │ Kubelet│   │ Kubelet│
│ Pod   │ │ Pod   │   │ Pod   │
└──────┘ └──────┘     └──────┘
```

### 1.2 核心组件

**Master 组件：**
- **kube-apiserver**：集群的入口，所有操作都通过 API
- **kube-scheduler**：调度 Pod 到合适的节点
- **kube-controller-manager**：运行各种控制器（Deployment、DaemonSet 等）
- **etcd**：分布式键值存储，保存集群所有数据

**Node 组件：**
- **kubelet**：管理 Pod 生命周期
- **kube-proxy**：负责网络代理和负载均衡
- **容器运行时**（containerd / Docker）

### 1.3 核心资源对象

| 资源 | 缩写 | 说明 |
|------|------|------|
| Pod | po | 最小的调度单元，包含一个或多个容器 |
| Deployment | deploy | 声明式管理无状态应用 |
| Service | svc | 提供稳定的网络访问入口 |
| ConfigMap | cm | 配置管理 |
| Secret | - | 敏感信息管理 |
| Namespace | ns | 资源隔离 |
| Ingress | ing | 七层负载均衡 |
| PersistentVolume | pv | 持久化存储 |
| DaemonSet | ds | 每个节点运行一个 Pod |

## 二、Kubernetes 安装与集群搭建

### 2.1 使用 kubeadm 搭建集群

```bash
# 1. 所有节点安装容器运行时（containerd）
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 2. 安装 kubeadm、kubelet、kubectl
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 3. 初始化 Master 节点
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.100

# 4. 配置 kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 5. 安装网络插件（Flannel）
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 6. Worker 节点加入集群
kubeadm join 192.168.1.100:6443 --token xxxxx --discovery-token-ca-cert-hash sha256:xxxxx
```

### 2.2 验证集群状态

```bash
# 查看节点状态
kubectl get nodes

# 查看系统 Pod 运行状态
kubectl get pods -n kube-system

# 查看集群信息
kubectl cluster-info
```

## 三、Pod 与 Workload 资源

### 3.1 Pod —— 最小的调度单元

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
  labels:
    app: my-app
spec:
  containers:
  - name: nginx
    image: nginx:latest
    ports:
    - containerPort: 80
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
```

### 3.2 Deployment —— 无状态应用管理

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-app
  labels:
    app: spring-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: spring-app
  template:
    metadata:
      labels:
        app: spring-app
    spec:
      containers:
      - name: app
        image: my-registry/spring-app:v1
        ports:
        - containerPort: 8080
        livenessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

### 3.3 DaemonSet —— 守护进程

适用于日志收集、监控代理等场景：

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
spec:
  selector:
    matchLabels:
      name: fluentd
  template:
    metadata:
      labels:
        name: fluentd
    spec:
      containers:
      - name: fluentd
        image: fluent/fluentd:v1.16
        volumeMounts:
        - name: varlog
          mountPath: /var/log
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
```

### 3.4 StatefulSet —— 有状态应用

适用于数据库、消息队列等：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: password
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
```

## 四、服务发现与负载均衡

### 4.1 Service 类型

```yaml
# ClusterIP（默认，集群内访问）
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080

---
# NodePort（暴露到宿主机端口）
apiVersion: v1
kind: Service
metadata:
  name: my-service-nodeport
spec:
  type: NodePort
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080

---
# LoadBalancer（云厂商LB）
apiVersion: v1
kind: Service
metadata:
  name: my-service-lb
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

### 4.2 Ingress —— 七层路由

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /users
        pathType: Prefix
        backend:
          service:
            name: user-service
            port:
              number: 8080
      - path: /orders
        pathType: Prefix
        backend:
          service:
            name: order-service
            port:
              number: 8080
```

## 五、配置与密钥管理

### 5.1 ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  application.yml: |
    server:
      port: 8080
    spring:
      datasource:
        url: jdbc:mysql://mysql-service:3306/myapp
---
apiVersion: v1
kind: Pod
metadata:
  name: configmap-demo
spec:
  containers:
  - name: app
    image: my-app
    volumeMounts:
    - name: config
      mountPath: /app/config
  volumes:
  - name: config
    configMap:
      name: app-config
```

### 5.2 Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  username: cm9vdA==   # base64 编码
  password: cGFzc3dvcmQxMjM=
---
apiVersion: v1
kind: Pod
metadata:
  name: secret-demo
spec:
  containers:
  - name: app
    image: my-app
    env:
    - name: DB_USERNAME
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: username
```

## 六、存储与持久化

### 6.1 PV & PVC

```yaml
# 持久卷
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /data/pv

---
# 持久卷声明
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
```

### 6.2 StorageClass（动态供给）

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
```

## 七、集群运维常用命令

```bash
# 查看资源
kubectl get pods -n default
kubectl get deployment
kubectl get svc
kubectl get nodes -o wide

# 查看详情
kubectl describe pod my-pod
kubectl describe node node-1

# 日志
kubectl logs -f deployment/my-app
kubectl logs --tail=100 pod/my-pod

# 资源伸缩
kubectl scale deployment spring-app --replicas=5
kubectl autoscale deployment spring-app --min=2 --max=10 --cpu-percent=80

# 滚动更新
kubectl set image deployment/spring-app app=my-registry/spring-app:v2
kubectl rollout status deployment/spring-app
kubectl rollout undo deployment/spring-app

# 端口转发
kubectl port-forward pod/my-pod 8080:8080
```

## 八、生产环境最佳实践

### 8.1 资源限制与请求

```yaml
resources:
  requests:    # 调度保证
    memory: "256Mi"
    cpu: "0.5"
  limits:      # 上限
    memory: "512Mi"
    cpu: "1"
```

### 8.2 Pod 生命周期管理

```yaml
spec:
  terminationGracePeriodSeconds: 30  # 优雅关闭时间
  containers:
  - name: app
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 10"]  # 等待请求处理完毕
```

### 8.3 亲和性和反亲和性

```yaml
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values:
              - spring-app
          topologyKey: kubernetes.io/hostname
```

### 8.4 命名空间资源配额

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
```

## 九、总结

Kubernetes 的学习曲线确实陡峭，但一旦掌握，你将拥有管理大规模容器集群的能力。从 Pod 到 Deployment，从 Service 到 Ingress，每个概念都是经过精心设计的。建议动手实操，在本地用 minikube 或 kind 搭建集群练习。

记住：Kubernetes 不只是一种工具，更是一种声明式运维的思维方式。
