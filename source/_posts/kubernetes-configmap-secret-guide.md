---
title: 【K8s 实战】Kubernetes ConfigMap & Secret 配置管理深度实战
date: 2026-07-04 08:00:00
tags:
  - Kubernetes
  - ConfigMap
  - Secret
  - 配置管理
categories:
  - Kubernetes
author: 东哥
---

# 【K8s 实战】Kubernetes ConfigMap & Secret 配置管理深度实战

## 前言

在传统部署方式中，应用配置通常写在配置文件中，放在代码仓库一起管理或通过环境变量注入。但在 Kubernetes 环境中，容器是动态调度和重启的，配置管理需要一种更**声明式、可追踪、可动态更新**的方式。

Kubernetes 提供了两个核心资源来实现配置管理：

- **ConfigMap**：存储非敏感配置数据（键值对、配置文件）
- **Secret**：存储敏感数据（密码、Token、证书），采用 Base64 编码 + 加密存储

本文将从基础用法到高级实践，全面覆盖 ConfigMap 和 Secret 的创建、注入、更新、设计模式与避坑指南。

---

## 一、ConfigMap 详解

### 1.1 创建 ConfigMap

```yaml
# 方式一：YAML 声明式
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
data:
  # 键值对形式
  APP_ENV: production
  LOG_LEVEL: info
  DB_HOST: mysql-service
  DB_PORT: "3306"
  
  # 多行配置文件
  nginx.conf: |
    server {
        listen 80;
        location / {
            proxy_pass http://backend:8080;
        }
    }
```

```bash
# 方式二：从字面量创建（开发测试用）
kubectl create configmap app-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info

# 方式三：从文件创建
kubectl create configmap app-config \
  --from-file=application.yml \
  --from-file=logback.xml

# 方式四：从目录加载
kubectl create configmap app-config \
  --from-file=./config-dir/

# 查看
kubectl get configmap app-config -o yaml
```

### 1.2 ConfigMap 注入 Pod 的方式

#### 方式 A：环境变量注入

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-pod
spec:
  containers:
  - name: app
    image: myapp:latest
    env:
      # 方式 A1：引用单个 key
      - name: APP_ENV
        valueFrom:
          configMapKeyRef:
            name: app-config
            key: APP_ENV
      - name: DB_PORT
        valueFrom:
          configMapKeyRef:
            name: app-config
            key: DB_PORT
            optional: true   # key 不存在时，Pod 依然可以启动
      
      # 方式 A2：直接将 ConfigMap 所有 key 注入为环境变量
    envFrom:
      - configMapRef:
          name: app-config
        prefix: CFG_          # 环境变量前缀，可选
```

#### 方式 B：Volume 挂载

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-pod-volume
spec:
  containers:
  - name: app
    image: myapp:latest
    volumeMounts:
      - name: config-volume
        mountPath: /etc/config   # 挂载到容器内路径
        readOnly: true
  volumes:
    - name: config-volume
      configMap:
        name: app-config
        # 只挂载特定 key（可选）
        items:
          - key: nginx.conf
            path: nginx/nginx.conf  # → /etc/config/nginx/nginx.conf
          - key: APP_ENV
            path: env/APP_ENV       # → /etc/config/env/APP_ENV
```

**两种注入方式的区别：**

| 特性 | 环境变量 | Volume 挂载 |
|------|---------|------------|
| 更新后自动同步 | ❌（Pod 需重启） | ✅（文件实时更新） |
| 应用热加载配置 | ❌ | ✅（需应用监听文件变化） |
| 大小限制 | 受环境变量总大小限制 | 1MB（ConfigMap 总大小限制） |
| 多 key 注入 | `envFrom` 方便 | `items` 可选择性挂载 |
| 子路径挂载 | 不适用 | ✅ |

---

## 二、Secret 详解

### 2.1 Secret 类型

| 类型 | 用途 | 字段要求 |
|------|------|---------|
| `Opaque` | 通用键值对 | data 或 stringData |
| `kubernetes.io/service-account-token` | 服务账号 Token | 自动生成 |
| `kubernetes.io/dockerconfigjson` | 镜像仓库认证 | `.dockerconfigjson` |
| `kubernetes.io/tls` | TLS 证书 | `tls.crt` + `tls.key` |
| `kubernetes.io/basic-auth` | HTTP 基本认证 | `username` + `password` |

### 2.2 创建 Secret

```yaml
# Opaque Secret
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  # 需要预先 Base64 编码
  DB_USERNAME: cm9vdA==          # "root"
  DB_PASSWORD: cGFzc3dvcmQxMjM=  # "password123"
---
# 使用 stringData（明文，K8s 自动编码 → 推荐开发环境用）
apiVersion: v1
kind: Secret
metadata:
  name: db-secret-plain
type: Opaque
stringData:
  DB_USERNAME: root
  DB_PASSWORD: password123
```

```bash
# 命令行创建
kubectl create secret generic db-secret \
  --from-literal=DB_USERNAME=root \
  --from-literal=DB_PASSWORD=password123

# 从文件创建 Secret
kubectl create secret generic tls-secret \
  --from-file=tls.crt=server.crt \
  --from-file=tls.key=server.key

# TLS 类型
kubectl create secret tls api-tls \
  --cert=api.crt --key=api.key

# Docker 仓库认证
kubectl create secret docker-registry regcred \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=myuser \
  --docker-password=mypass
```

### 2.3 Secret 注入 Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-secret
spec:
  containers:
  - name: app
    image: myapp:latest
    env:
      - name: DB_USERNAME
        valueFrom:
          secretKeyRef:
            name: db-secret
            key: DB_USERNAME
    envFrom:
      - secretRef:
          name: db-secret
    volumeMounts:
      - name: secret-volume
        mountPath: /etc/secret
        readOnly: true
  volumes:
    - name: secret-volume
      secret:
        secretName: db-secret
        defaultMode: 0400   # 只读权限（安全）
  # 使用私有镜像仓库时
  imagePullSecrets:
    - name: regcred
```

---

## 三、高级用法

### 3.1 ConfigMap/Secret 热更新

**场景：** 修改配置后，不重启 Pod 就能生效。

```bash
# 更新 ConfigMap
kubectl edit configmap app-config

# 或者 apply 新的 YAML
kubectl apply -f updated-configmap.yaml
```

**Volume 挂载方式：** 文件会自动更新（几秒内同步）
**环境变量方式：** 不会自动更新，必须重启 Pod

```bash
# 滚动重启 Deployment，使新配置生效（环境变量方式）
kubectl rollout restart deployment app-deployment

# 如果使用 Volume 挂载，应用需要监听文件变化
# 示例：使用 Spring Cloud Kubernetes 自动感知
dependencies {
    implementation 'org.springframework.cloud:spring-cloud-starter-kubernetes'
}
```

### 3.2 不可变 ConfigMap/Secret

Kubernetes 1.21+ 支持将 ConfigMap/Secret 标记为不可变（immutable）：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-immutable
data:
  APP_ENV: production
immutable: true  # 🤚 创建后不可修改，只能删除重建
```

**优势：**
- 减少 API Server 的 watch 负载
- 提高集群性能
- 避免热更新导致的不一致问题

**适用场景：** 几乎不会改动的配置（如数据库表结构配置、基础参数）

### 3.3 多环境配置管理

```yaml
# 推荐命名规范
configmap-app-dev.yaml      # 开发环境
configmap-app-staging.yaml   # 预发布
configmap-app-prod.yaml      # 生产
```

**不推荐**将多个环境的配置放在同一个 ConfigMap 中通过 key 区分：

```yaml
# ❌ 反面案例：不要这样做
data:
  config-dev.yaml: |
    log.level: DEBUG
  config-prod.yaml: |
    log.level: WARN
```

**推荐的做法：** 不同环境用不同的 Kustomize overlay 或 Helm values：

```yaml
# kustomization.yaml
configMapGenerator:
- name: app-config
  files:
  - configs/application.yaml
  literals:
  - APP_ENV=production

# 不同环境 overlay
# overlays/production/kustomization.yaml
bases:
- ../../base
patchesStrategicMerge:
- config-patch.yaml
```

### 3.4 Secret 加密（KMS 集成）

默认情况下，Secret 数据仅 Base64 编码，不是真正的加密。任何人只要有 etcd 的访问权限就能读取。生产环境需要开启 **静态加密（Encryption at Rest）**：

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml 中配置
# 先创建加密配置文件
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}  # 兜底：未加密的按原样存储
```

```bash
# 开启加密后，旧的 Secret 并未被加密，需重新创建：
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

---

## 四、避坑指南

### 坑 1：ConfigMap/Secret 大小限制

Kubernetes 默认限制 ConfigMap/Secret 大小为 **1MB**。超过会报错。

**应对方案：**
- 配置文件的二进制文件请用 PVC 或对象存储
- Spring Boot 等框架使用外部配置中心（Apollo/Nacos）

### 坑 2：Secret 数据泄露

Secret 的 data 内容即使通过 `kubectl get secret -o yaml` 也能看到：

```bash
# 安全查看（不显示值）
kubectl get secret db-secret -o jsonpath='{.data}'

# 审计：检查哪些用户访问了 Secret
# RBAC 控制是关键！
```

**安全建议：**
1. 开启静态加密（KMS）+ RBAC 严格控制 Secret 的 get/list 权限
2. 使用 External Secrets Operator 从外部 Vault 同步
3. 不用将 Secret 提交到 Git 仓库（使用 Sealed Secrets 或 Helm Secrets）

### 坑 3：ConfigMap 未更新导致 Pod 使用旧配置

Volume 挂载的 ConfigMap 更新后，文件会更新，但**应用不一定自动感知**：

```java
// Spring Boot 方案：开启配置刷新
@RefreshScope
@Configuration
@ConfigurationProperties(prefix = "app")
public class AppConfig {
    private String env;
    // getter/setter...
}
```

### 坑 4：Pod 启动时 ConfigMap/Secret 不存在

```yaml
# 如果 ConfigMap 不存在，Pod 会处于 Pending 状态
# 解决方案：标记为 optional
env:
  - name: APP_ENV
    valueFrom:
      configMapKeyRef:
        name: non-existent-config
        key: APP_ENV
        optional: true  # ✅
```

---

## 五、总结：选择决策表

| 场景 | 推荐方案 |
|------|---------|
| 环境变量（非敏感） | ConfigMap envFrom |
| 环境变量（敏感） | Secret envFrom |
| 配置文件（少量，<1MB） | ConfigMap Volume 挂载 |
| 配置文件（需热加载） | ConfigMap Volume 挂载 + Watch 机制 |
| TLS 证书 | Secret type: tls |
| 镜像仓库认证 | Secret type: docker-registry |
| 密码/Token/API Key | Secret type: Opaque |
| 配置加密存储 | 开启 KMS EncryptionConfig |
| 多环境差异化 | Kustomize overlay / Helm values |
| 配置外部化（企业级） | Apollo / Nacos / Vault |

ConfigMap 和 Secret 是 Kubernetes 配置管理的核心，掌握它们不仅能让你在 K8s 中更好地管理应用配置，也是理解云原生 12-Factor App 中"配置与代码分离"理念的关键一步。
