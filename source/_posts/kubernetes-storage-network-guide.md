---
title: Kubernetes 存储与网络原理实战
date: 2026-06-18 08:00:00
tags:
  - Kubernetes
  - 存储
  - 网络
  - 云原生
categories:
  - 容器化
author: 东哥
---

# Kubernetes 存储与网络原理实战

## 一、Kubernetes 存储体系

Kubernetes 的存储体系是容器化应用持久化数据的基石。理解存储抽象层的工作机制，对于构建有状态服务至关重要。

### 1.1 存储架构概览

```
┌─────────────────────────────────────────────────────┐
│                   Pod                               │
│  ┌──────────────┐    ┌──────────────┐               │
│  │  Container   │    │  Container   │               │
│  │  /data       │    │  /config     │               │
│  └──────┬───────┘    └──────┬───────┘               │
│         │                   │                       │
│         ▼                   ▼                       │
│  ┌─────────────────────────────────────────┐       │
│  │           Volume Mounts                  │       │
│  └───────────┬─────────────────────────────┘       │
└──────────────┼─────────────────────────────────────┘
               │
               ▼
┌──────────────────────────────┐
│   PersistentVolumeClaim      │
│   (存储请求)                  │
├──────────────────────────────┤
│   PersistentVolume           │
│   (存储资源)                  │
├──────────────────────────────┤
│   StorageClass               │
│   (存储模板/动态供应)          │
├──────────────────────────────┤
│   CSI Driver (存储插件)       │
│   (AWS/NFS/Ceph/... )        │
└──────────────────────────────┘
```

### 1.2 Volume 类型对比

| Volume 类型 | 生命周期 | 持久性 | 使用场景 | 支持读写模式 |
|------------|---------|--------|---------|------------|
| emptyDir | 与Pod绑定 | 临时 | 临时缓存、共享目录 | RWO |
| hostPath | 与节点绑定 | 节点持久 | 系统组件日志 | RWO |
| configMap/secret | 与Pod绑定 | 临时 | 配置注入 | RO |
| persistentVolumeClaim | 独立于Pod | 持久 | 数据库存储 | RWO/RWX/ROX |
| ephemeral | 与Pod绑定 | 临时 | 高性能临时存储 | RWO |

### 1.3 PV/PVC 使用示例

```yaml
# StorageClass 定义（使用 NFS CSI 驱动为例）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs-server.example.com
  share: /exported/path
reclaimPolicy: Retain
allowVolumeExpansion: true
mountOptions:
  - hard
  - nfsvers=4.1
---
# PersistentVolumeClaim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data
  namespace: production
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 100Gi
---
# 使用 PVC 的 Deployment
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: production
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
              key: root-password
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        - name: config
          mountPath: /etc/mysql/conf.d
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: mysql-data
      - name: config
        configMap:
          name: mysql-config
  # StatefulSet 自动管理的卷声明模板
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: "nfs-csi"
      resources:
        requests:
          storage: 100Gi
```

### 1.4 存储扩容与迁移

```bash
# 在线扩容 PVC（需 StorageClass 支持 allowVolumeExpansion）
kubectl patch pvc mysql-data -n production \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'

# 验证扩容
kubectl get pvc mysql-data -n production

# 手动创建 PV（静态供应）
apiVersion: v1
kind: PersistentVolume
metadata:
  name: manual-pv-001
spec:
  capacity:
    storage: 500Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
    - ReadOnlyMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    path: /data/k8s-volume-001
    server: 192.168.1.100
```

## 二、CSI 存储插件机制

### 2.1 CSI 架构

CSI (Container Storage Interface) 是 Kubernetes 与存储系统之间的标准接口：

```
┌─────────────────┐
│   Kubernetes    │
│   kubelet       │
│   kube-contro-  │
│   ller-manager  │
└────────┬────────┘
         │   gRPC
         ▼
┌──────────────────────────────┐
│  CSI Driver (DaemonSet)      │
│  ┌──────────────────────┐   │
│  │  Identity Service    │   │ ← GetPluginInfo, Probe
│  ├──────────────────────┤   │
│  │  Controller Service  │   │ ← CreateVolume, DeleteVolume
│  ├──────────────────────┤   │
│  │  Node Service        │   │ ← NodePublishVolume, NodeUnpublishVolume
│  └──────────────────────┘   │
└──────────────────────────────┘
         │
         ▼
┌─────────────────┐
│   Storage Backend│
│  (NFS/Ceph/EBS)  │
└─────────────────┘
```

### 2.2 部署 CSI 驱动

```bash
# 以 NFS CSI 驱动为例
# 1. 部署 CSI 驱动组件
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/example/nfs-provisioner.yaml

# 2. 创建 StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi-fast
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs-server.prod.svc.cluster.local
  share: /exports
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - hard
  - nfsvers=4.1
  - noatime
EOF
```

## 三、Kubernetes 网络模型

### 3.1 网络通信模型

Kubernetes 网络模型基于三个核心桶原则：

1. **Pod 间通信**：任意 Pod 可与任意其他 Pod 直接通信（无需 NAT）
2. **节点到 Pod**：节点上的代理可直接访问 Pod
3. **Pod 内容器**：同一 Pod 内容器共享网络命名空间

```
┌────────── Node 1 ──────────┐
│  ┌─ eth0: 10.0.1.2 ──────┐│
│  │  ┌── Pod ──┐ ┌── Pod──┐ ││
│  │  │ 10.1.1.2│ │10.1.1.3│ ││
│  │  │ ┌──────┐│ │┌──────┐│ ││
│  │  │ │ctn A ││ ││ctn B ││ ││
│  │  │ │(port)││ ││(port)││ ││
│  │  │ └──────┘│ │└──────┘│ ││
│  │  └────────┘ └───────┘  ││
│  └────────────────────────┘│
├────────── Node 2 ──────────┤
│  ┌─ eth0: 10.0.1.3 ──────┐│
│  │  ┌── Pod ──┐          ││
│  │  │ 10.1.2.2│          ││
│  │  │ ┌──────┐│          ││
│  │  │ │ctn C ││          ││
│  │  │ └──────┘│          ││
│  │  └────────┘           ││
│  └───────────────────────┘│
└───────────────────────────┘
```

### 3.2 CNI 插件对比

| CNI 插件 | 网络模式 | 封装开销 | 性能 | 特性 |
|---------|---------|---------|------|------|
| Flannel | VXLAN/Host-GW | VXLAN: 50字节 | 中 | 简单易用 |
| Calico | BGP/IPIP | IPIP: 20字节 | 高 | 网络策略丰富 |
| Cilium | eBPF | 无（原生） | 极高 | L7策略、可观测性 |
| Weave | VXLAN/FastDP | VXLAN: 50字节 | 中 | 加密、DNS |
| Antrea | OpenFlow/OVS | VXLAN/Geneve | 中高 | VMware集成 |

### 3.3 Service 与网络代理

```yaml
# ClusterIP Service（默认）
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
  - protocol: TCP
    port: 80        # Service 端口
    targetPort: 8080 # 容器端口
---
# NodePort Service
apiVersion: v1
kind: Service
metadata:
  name: my-app-nodeport
spec:
  type: NodePort
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080  # 节点端口（30000-32767）
---
# LoadBalancer Service
apiVersion: v1
kind: Service
metadata:
  name: my-app-lb
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 443
    targetPort: 8443
  externalTrafficPolicy: Local  # 保留客户端源IP
```

### 3.4 Ingress 控制器

```yaml
# Ingress 资源
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - api.example.com
    secretName: api-tls-secret
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /v1
        pathType: Prefix
        backend:
          service:
            name: api-v1-service
            port:
              number: 80
      - path: /v2
        pathType: Prefix
        backend:
          service:
            name: api-v2-service
            port:
              number: 80
```

## 四、网络策略 (NetworkPolicy)

### 4.1 网络策略基础

```yaml
# 拒绝所有入站流量（白名单模式）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
# 允许特定服务访问 API Pod
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-specific
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: gateway
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
    ports:
    - protocol: TCP
      port: 8080
---
# 允许访问外部特定 IP
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-database
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 10.0.0.0/24
        except:
        - 10.0.0.0/28  # 排除部分网段
    ports:
    - protocol: TCP
      port: 3306
```

## 五、Service Mesh 与服务通信

### 5.1 Istio 流量管理

```yaml
# 虚拟服务（路由规则）
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    route:
    - destination:
        host: reviews
        subset: v2
  - route:
    - destination:
        host: reviews
        subset: v1
---
# 目标规则（负载均衡和连接池）
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 10
        maxRequestsPerConnection: 10
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
    trafficPolicy:
      loadBalancer:
        simple: RANDOM
```

### 5.2 可观测性集成

```yaml
# Istio 指标的 Prometheus 配置
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: custom-metrics
spec:
  metrics:
  - providers:
    - name: prometheus
    overrides:
    - match:
        mode: SERVER
      metrics:
      - name: request_duration_milliseconds
        tagOverrides:
          destination_cluster:
            value: "cluster-a"
```

## 六、存储与网络性能优化

### 6.1 存储性能调优

| 优化方向 | 方案 | 预期效果 |
|---------|------|---------|
| I/O 调度 | 使用 noop 或 none 调度器 | 减少 10-15% 延迟 |
| 文件系统 | XFS over ext4 | 大文件性能提升 20% |
| 挂载参数 | noatime,nodiratime | 减少元数据写入 |
| 本地存储 | Local PV + 节点选择 | 延迟降低 80% |
| 缓存策略 | PVC + emptyDir 混合使用 | 读写分离优化 |

### 6.2 eBPF 与 Cilium 网络优化

```bash
# Cilium 网络策略示例（L7 感知）
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-allow-http
spec:
  endpointSelector:
    matchLabels:
      app: api-server
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/api/v1/orders/.*"
EOF
```

### 6.3 多网卡与 DPDK 方案

对于高性能场景（如 NFV、实时数据处理），可以使用多网卡绑定和 DPDK：

```yaml
# Multus CNI 多网卡配置
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: sriov-net
  namespace: production
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "sriov-net",
      "type": "sriov",
      "vlan": 100,
      "ipam": {
        "type": "whereabouts",
        "range": "10.100.0.0/16"
      }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: sriov-net
spec:
  containers:
  - name: dpdk-app
    image: dpdk-app:latest
    securityContext:
      capabilities:
        add: ["IPC_LOCK", "NET_ADMIN", "SYS_NICE", "SYS_ADMIN"]
```

## 七、故障排查与诊断

### 7.1 网络排查工具箱

```bash
# 1. 创建诊断 Pod
kubectl run netshoot --image=nicolaka/netshoot -it --rm -- bash

# 2. DNS 排查
nslookup kubernetes.default.svc.cluster.local
dig kubernetes.default.svc.cluster.local

# 3. 网络路径追踪
ping <pod-ip>
traceroute <pod-ip>
mtr <service-name>

# 4. 连接测试
nc -zv <service-name> 8080
curl -v http://service-name:8080/health

# 5. 抓包分析
kubectl debug -n production pod/api-server-xxx --image=nicolaka/netshoot
tcpdump -i eth0 -n port 3306
```

### 7.2 存储问题诊断

```bash
# 检查 PVC 状态
kubectl describe pvc mysql-data -n production

# 查看 PV 详情
kubectl get pv
kubectl describe pv pvc-xxxxx

# 存储挂载验证
kubectl exec -it mysql-0 -n production -- df -h
kubectl exec -it mysql-0 -n production -- mount | grep mysql

# CSI 驱动日志
kubectl logs -n kube-system daemonset/csi-nfs-node -c csi-driver

# 性能测试
kubectl run fio-test --image=openebs/tests-fio -it --rm -- \
  fio --name=test --ioengine=libaio --rw=randrw --bs=4k \
      --size=1G --numjobs=4 --runtime=30 --iodepth=32
```

### 7.3 常见问题对照表

| 症状 | 可能原因 | 排查命令 | 解决方案 |
|------|---------|---------|---------|
| Pod Pending | PVC 未绑定 | kubectl describe pod/pvc | 检查 StorageClass 和 CSI 驱动 |
| 跨节点 Pod 不通 | CNI 配置问题 | kubectl exec -it pod1 -- ping pod2-ip | 检查 CNI DaemonSet 日志 |
| Service 连接超时 | 端点未就绪 | kubectl get endpoints | 检查 Pod label 匹配 |
| DNS 解析失败 | CoreDNS 异常 | kubectl logs -n kube-system coredns | 重启 CoreDNS |
| 存储性能差 | 后端网络瓶颈 | iostat -xz 1 | 切换 Local PV 或升级存储后端 |
| 网络延迟高 | eBPF 程序冲突 | bpftool prog list | 检查 Cilium 版本兼容性 |

## 八、生产最佳实践

### 8.1 存储最佳实践

1. **有状态应用使用 StatefulSet**：保证 Pod 标识和存储的稳定性
2. **合理规划 ReclaimPolicy**：生产环境建议 Retain，开发环境 Delete
3. **设置资源配额**：限制 PVC 数量和总容量
4. **存储分层**：热数据用 SSD，冷数据用 HDD

```yaml
# 资源配额示例
apiVersion: v1
kind: ResourceQuota
metadata:
  name: storage-quota
  namespace: production
spec:
  hard:
    persistentvolumeclaims: "50"
    requests.storage: "2Ti"
    ssd.storageclass.storage.k8s.io/requests.storage: "500Gi"
```

### 8.2 网络最佳实践

1. **使用 NetworkPolicy**：默认拒绝 + 白名单策略
2. **外部服务通过 Ingress/Egress**：统一入口出口控制
3. **监控网络指标**：带宽、延迟、丢包率
4. **服务网格选择**：Istio 适合复杂流量管理，Linkerd 适合轻量场景

## 总结

Kubernetes 的存储和网络体系是云原生基础设施的基石。存储方面，PV/PVC/StorageClass 三层抽象提供了灵活的数据持久化方案；网络方面，CNI 插件配合 Service/Ingress 构建了完整的容器网络栈。在生产环境中，合理选择存储后端、网络插件和 Service Mesh 方案，配合完善的监控和诊断工具，能有效保障集群的稳定性和性能。
