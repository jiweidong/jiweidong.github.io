---
title: 【K8s 实战】Kubernetes Ingress Controller 深度实战：从 Nginx Ingress 到生产级流量管理
date: 2026-07-15 08:00:00
tags:
  - Kubernetes
  - Ingress
  - Nginx
  - 网关
categories:
  - Kubernetes
  - 云原生
author: 东哥
---

# 【K8s 实战】Kubernetes Ingress Controller 深度实战：从 Nginx Ingress 到生产级流量管理

## 引言

在 Kubernetes 集群中，Pod 和 Service 是内部网络通信的基础，但如何将集群内部的服务暴露给外部用户呢？很多初学者会想到 NodePort 或 LoadBalancer 类型的 Service。但在生产环境中，这两者都存在明显的局限：

- **NodePort**：端口范围有限（30000-32767），且每个服务占用节点端口，不利于管理
- **LoadBalancer**：每个 Service 都需要一个云负载均衡器，成本高昂

这时候，**Ingress** 就派上了用场。它作为集群的流量入口，提供基于域名和路径的 HTTP/HTTPS 路由能力，是 Kubernetes 中 7 层流量管理的核心抽象。

本文将带你深入理解 Ingress 与 Ingress Controller 的原理，并通过 Nginx Ingress Controller 实战演示生产级配置。

---

## 一、Ingress 与 Ingress Controller 的关系

### 1.1 Ingress 是什么？

Ingress 是 Kubernetes 的一个 API 资源对象，它定义了从集群外部到集群内部服务的 HTTP/HTTPS 路由规则。说白了，它就是一份**路由配置声明**。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
spec:
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 8080
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

这份声明告诉集群：`app.example.com/api` 的请求转发到 `api-service:8080`，而其他请求转发到 `web-service:80`。

### 1.2 Ingress Controller 是什么？

**Ingress 只是一个资源定义，它本身不实现流量转发。** 真正干活的是 **Ingress Controller**——一个运行在集群中的反向代理程序，它负责：

1. **监听 Ingress 资源的变化**：通过 Kubernetes API 监听 Ingress、Service、Endpoint 等资源
2. **动态更新代理配置**：将 Ingress 规则转换为自身的配置（如 Nginx 的 nginx.conf）
3. **承载流量并转发**：作为实际的流量入口，接收外部请求并路由到后端 Pod

Ingress Controller 并不是 Kubernetes 内置组件，而是需要**自行安装**的。社区中最流行的实现包括：

| Ingress Controller | 代理引擎 | 性能 | 扩展性 | 适用场景 |
|---|---|---|---|---|
| **Nginx Ingress** | Nginx | 高 | 好 | 通用场景，社区最成熟 |
| **Kong Ingress** | OpenResty/Lua | 中 | 好 | 网关能力丰富，需插件 |
| **APISIX Ingress** | APISIX | 高 | 极好 | 高性能，丰富的路由能力 |
| **Traefik** | Traefik | 中 | 好 | 自动 HTTPS，服务网格集成 |
| **HAProxy Ingress** | HAProxy | 极高 | 中 | 纯高性能场景 |
| **AWS ALB Ingress** | AWS ALB | 高 | 好 | AWS 原生集成 |
| **Istio Ingress Gateway** | Envoy | 高 | 极好 | 服务网格入口 |

### 1.3 Ingress Controller 的工作原理

以 Nginx Ingress Controller 为例，其核心工作流程如下：

```
外部请求 → [Nginx Ingress Controller: 80/443] → Service → Pod
                     ↑
                 监听 Ingress 资源变化
                     ↑
              Kubernetes API Server
```

详细流程：

1. Nginx Ingress Controller 启动时，通过 Kubernetes API 监听 `Ingress`、`Service`、`Endpoint`、`Secret` 等资源
2. 当 Ingress 资源创建/更新/删除时，控制器将 Ingress 规则生成对应的 **nginx.conf** 配置
3. 配置生效后，Nginx 接收外部流量，根据 Host 头和路径规则路由到后端 Service 对应的 Pod IP
4. 如果 Ingress 中配置了 TLS，控制器会自动关联 Secret 中的证书

---

## 二、安装 Nginx Ingress Controller

### 2.1 使用 Helm 安装（推荐）

```bash
# 添加 Helm 仓库
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# 安装 nginx-ingress
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/alibaba-cloud-loadbalancer-spec"="slb.s2.small" \
  --set controller.config.use-forwarded-headers="true" \
  --set controller.config.compute-full-forwarded-for="true" \
  --set controller.config.forwarded-for-header="X-Forwarded-For"
```

### 2.2 验证安装

```bash
# 查看 Pod 是否就绪
kubectl get pods -n ingress-nginx
# 输出示例：
# NAME                                            READY   STATUS    RESTARTS   AGE
# ingress-nginx-controller-7c6b8f4d6c-2xj4k      1/1     Running   0          5m
# ingress-nginx-controller-7c6b8f4d6c-m9wrt      1/1     Running   0          5m

# 查看 Service 获取外部 IP
kubectl get svc -n ingress-nginx
# NAME                                 TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
# ingress-nginx-controller             LoadBalancer   10.96.123.45    47.xxx.xxx.1  80:32080/TCP,443:32443/TCP
# ingress-nginx-controller-admission   ClusterIP      10.96.123.46    <none>        443/TCP
```

### 2.3 核心配置说明

安装时的 `--set` 参数可以灵活配置 Ingress Controller：

```yaml
# values-custom.yaml
controller:
  replicaCount: 3                    # 高可用部署
  minAvailable: 1                    # PDB 保证最少可用
  
  service:
    type: LoadBalancer               # 对外暴露方式
    externalTrafficPolicy: Local     # 保留客户端真实 IP
    
  config:
    proxy-body-size: "100m"          # 请求体大小限制
    ssl-redirect: "true"             # HTTP 自动重定向到 HTTPS
    hsts: "true"                     # 启用 HSTS
    use-forwarded-headers: "true"   # 使用代理头部
    enable-real-ip: "true"           # 启用真实 IP
    
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
    
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80
```

---

## 三、Ingress 配置实战

### 3.1 基本域名路由

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: basic-routing
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: blog.example.com
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: blog-api
            port:
              number: 8080
      - path: /(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: blog-web
            port:
              number: 80
```

### 3.2 HTTPS 配置（SSL/TLS）

```bash
# 创建 TLS Secret
kubectl create secret tls example-tls \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n production
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-ingress
  namespace: production
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    secretName: example-tls
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-service
            port:
              number: 80
```

### 3.3 Let's Encrypt 自动 HTTPS（cert-manager）

```bash
# 安装 cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
```

```yaml
# ClusterIssuer — 集群级别的颁发者
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: auto-tls-ingress
  namespace: production
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - secure-app.example.com
    secretName: secure-app-tls
  rules:
  - host: secure-app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-service
            port:
              number: 80
```

---

## 四、高级配置与最佳实践

### 4.1 蓝绿发布与金丝雀发布

Nginx Ingress Controller 原生支持流量切分：

```yaml
# 稳定版 Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-stable
  namespace: production
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-stable
            port:
              number: 80
---
# 金丝雀版本 Ingress（流量切分 10%）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-canary
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-canary
            port:
              number: 80
```

金丝雀策略支持多种方式：

| 策略 | 注解 | 说明 |
|---|---|---|
| 权重 | `canary-weight: "10"` | 10% 流量到新版本 |
| Header | `canary-by-header: X-Canary` | 带特定 Header 的请求走新版本 |
| Cookie | `canary-by-cookie: canary_token` | 带特定 Cookie 的请求走新版本 |
| IP | `canary-by-header-value: dev-team` | Header 匹配特定值 |

### 4.2 跨域 CORS 配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cors-ingress
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://admin.example.com"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-headers: "Authorization, Content-Type"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
    nginx.ingress.kubernetes.io/cors-max-age: "86400"
spec: ...
```

### 4.3 速率限制（Rate Limiting）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ratelimit-ingress
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "100"
    nginx.ingress.kubernetes.io/limit-rpm: "5000"
    nginx.ingress.kubernetes.io/limit-connections: "50"
    nginx.ingress.kubernetes.io/error-log-level: "warn"
    # 限制按 IP (默认)
    nginx.ingress.kubernetes.io/limit-rate-after: "10m"
    nginx.ingress.kubernetes.io/limit-rate: "500k"
spec: ...
```

### 4.4 白名单 IP 访问控制

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: restricted-ingress
  namespace: internal
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
    nginx.ingress.kubernetes.io/server-snippet: |
      if ($http_x_forwarded_for !~ "^10\.") {
        return 403;
      }
spec:
  rules:
  - host: internal-admin.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: admin-ui
            port:
              number: 80
```

### 4.5 自定义 Nginx 配置（Server Snippet 和 Configuration Snippet）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: custom-ingress
  annotations:
    nginx.ingress.kubernetes.io/server-snippet: |
      location /healthz {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
      }
    nginx.ingress.kubernetes.io/configuration-snippet: |
      if ($request_uri ~* "\.(bak|old|swp)$") {
        return 403;
      }
      proxy_set_header X-Request-ID $request_id;
spec: ...
```

---

## 五、生产级部署架构

### 5.1 高可用部署方案

```
                         Internet
                            |
                    [全局负载均衡 DNS]
                            |
              +--------------+--------------+
              |                             |
     [公网 LB: 阿里云 SLB]         [公网 LB: 腾讯云 CLB]
              |                             |
    +---------+----------+       +---------+----------+
    |                    |       |                    |
[Node A: nginx-ingress] [Node B: nginx-ingress] [Node C: nginx-ingress]
    |                    |       |                    |
    +---------+----------+       +---------+----------+
              |                             |
       [K8s Service & Pods]          [K8s Service & Pods]
```

关键配置点：

```yaml
controller:
  replicaCount: 3
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
            - key: app.kubernetes.io/name
              operator: In
              values:
              - ingress-nginx
          topologyKey: kubernetes.io/hostname

  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
```

### 5.2 监控与日志

```yaml
# 启用 Prometheus 指标
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      namespace: ingress-nginx

  # 审计日志
  extraArgs:
    v: "2"                          # 日志级别
  config:
    log-format-upstream: |
      {"time": "$time_iso8601",
      "remote_addr": "$remote_addr",
      "x-forward-for": "$http_x_forwarded_for",
      "request_id": "$req_id",
      "remote_user": "$remote_user",
      "bytes_sent": $bytes_sent,
      "request_time": $request_time,
      "status": $status,
      "vhost": "$host",
      "request_proto": "$server_protocol",
      "path": "$uri",
      "request_query": "$args",
      "request_length": $request_length,
      "duration": $request_time,
      "method": "$request_method",
      "http_referrer": "$http_referer",
      "http_user_agent": "$http_user_agent",
      "upstream_addr": "$upstream_addr",
      "upstream_status": "$upstream_status",
      "upstream_response_time": "$upstream_response_time"}
```

### 5.3 性能调优关键参数

```yaml
controller:
  config:
    # 连接池
    keep-alive: "300"
    keep-alive-requests: "10000"
    
    # Worker 进程
    worker-processes: "auto"
    worker-connections: "65536"
    
    # 代理缓冲区
    proxy-buffer-size: "8k"
    proxy-buffers: "8 8k"
    proxy-busy-buffers-size: "16k"
    
    # 超时设置
    proxy-connect-timeout: "10"
    proxy-read-timeout: "60"
    proxy-send-timeout: "60"
    
    # SSL 优化
    ssl-protocols: "TLSv1.2 TLSv1.3"
    ssl-ciphers: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"
    ssl-session-cache: "true"
    ssl-session-cache-size: "10m"
    ssl-session-timeout: "10m"
    ssl-buffer-size: "4k"
```

---

## 六、常见故障排查

### 6.1 404 Not Found

```bash
# 检查 Ingress 配置
kubectl describe ingress <name> -n <namespace>

# 检查后端 Service 的 Endpoint 是否有 Pod
kubectl get endpoints <service-name> -n <namespace>

# 查看 Ingress Controller 日志
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller

# 检查 nginx 配置是否正确
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf
```

### 6.2 证书问题

```bash
# 检查 Secret 是否存在
kubectl get secret <cert-secret> -n <namespace>

# 验证证书内容
kubectl get secret <cert-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

### 6.3 502 Bad Gateway

常见原因及排查：

```bash
# 1. 检查 Pod 是否正常
kubectl get pods -n <ns> -o wide

# 2. 检查 Pod 端口
kubectl describe pod <pod-name> -n <ns>

# 3. 确认 Service 端口匹配
kubectl get svc <svc-name> -n <ns>

# 4. 从 Ingress Controller 网络空间测试连通性
kubectl exec -it -n ingress-nginx deploy/ingress-nginx-controller -- curl -v http://<svc-name>.<ns>.svc.cluster.local:8080/health
```

### 6.4 客户端真实 IP 丢失

```yaml
# 关键配置：保留客户端源 IP
controller:
  service:
    externalTrafficPolicy: Local
    
  config:
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"
    forwarded-for-header: "X-Forwarded-For"
    enable-real-ip: "true"
    real-ip-header: "X-Forwarded-For"
    proxy-real-ip-cidr: "0.0.0.0/0"
```

---

## 七、Ingress 与其他流量入口方案的对比

| 方案 | 层级 | 协议支持 | 成本 | 配置复杂度 | 适用场景 |
|---|---|---|---|---|---|
| **NodePort** | L4 | TCP/UDP | 低 | 简单 | 开发测试 |
| **LoadBalancer** | L4 | TCP/UDP | 高（每个服务一个 LB） | 简单 | 单个服务暴露 |
| **Ingress** | L7 | HTTP/HTTPS/gRPC | 中（共享 LB） | 中 | 多服务域名路由 |
| **Service Mesh Gateway** | L7 | HTTP/HTTPS/gRPC/TCP | 中高 | 高 | 服务网格场景 |
| **API Gateway** | L7 | HTTP/HTTPS | 高 | 中高 | 全功能网关 |

**面试官追问：Ingress 和 API Gateway 的区别？**

答：Ingress 专注于 Kubernetes 集群内部服务的流量路由，而 API Gateway（如 Kong、APISIX）则提供了更丰富的功能，包括身份认证、限流、熔断、服务编排、协议转换等。在实际架构中，两者可以共存：API Gateway 作为全局入口，Ingress 作为 K8s 集群内部的路由层。

---

## 八、总结

本文从 Ingress 的核心概念出发，深入讲解了 Ingress Controller 的工作原理，并通过大量实战配置展示了 Nginx Ingress Controller 的生产级用法。关键要点：

1. **Ingress 是声明式路由规则**，Ingress Controller 才是真正干活的反向代理
2. **Nginx Ingress Controller** 是最成熟、使用最广泛的实现
3. **生产部署要关注**：高可用（多副本+反亲和）、HTTPS（cert-manager 自动管理）、监控（Prometheus 指标）
4. **高级功能**：金丝雀发布、CORS、限流、IP 白名单、自定义配置片段
5. **故障排查**：多用 `kubectl describe` 和 `kubectl exec` 从 Ingress Controller 内部探测

掌握了 Ingress，你的 K8s 集群就拥有了一个灵活、强大的流量入口，是迈向生产级云原生架构的关键一步。
