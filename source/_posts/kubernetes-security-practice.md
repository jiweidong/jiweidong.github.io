---
title: Kubernetes 安全最佳实践：从零构建生产级集群安全体系
date: 2026-06-19 08:30:00
tags:
  - Kubernetes
  - 安全
  - RBAC
  - Pod安全
categories:
  - DevOps
author: 东哥
---
## 一、引言

Kubernetes 已经成为容器编排的事实标准，但默认配置下的集群存在大量安全风险。根据 CNCF 2025 年的安全调查报告，超过 60% 的受访组织在生产环境中遇到过 Kubernetes 相关的安全问题。本文将从"集群安全 → Pod 安全 → 容器安全"三层模型出发，系统性地讲解如何构建生产级 Kubernetes 安全体系。

### Kubernetes 安全的三层模型

| 安全层级 | 覆盖范围 | 核心组件 | 主要攻击面 |
|---------|---------|---------|-----------|
| 集群安全 | 控制面、节点、网络 | RBAC、NetworkPolicy、审计日志 | API Server 暴露、权限滥用 |
| Pod 安全 | Pod 工作负载、容器运行时 | Pod Security Standards、Seccomp | 提权、容器逃逸 |
| 容器安全 | 镜像、运行时行为 | Trivy、Falco、只读文件系统 | 镜像漏洞、恶意进程 |

## 二、RBAC 深度解析与实践

### 2.1 RBAC 核心概念

Kubernetes RBAC 基于四个核心资源类型：

| 资源 | 级别 | 作用 |
|------|------|------|
| Role | 命名空间级 | 定义在某个命名空间内的权限集合 |
| ClusterRole | 集群级 | 定义集群范围内的权限集合 |
| RoleBinding | 命名空间级 | 将 Role 绑定到 User/Group/ServiceAccount |
| ClusterRoleBinding | 集群级 | 将 ClusterRole 绑定到集群级主体 |

### 2.2 最小权限原则实践

错误示例：授予 Cluster Admin（完全违背最小权限原则）

```yaml
# ❌ 错误：授予集群管理员权限
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-admin
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

正确实践：按需授予最细粒度权限

```yaml
# ✅ 正确：只读访问 specific namespace 中的 Pod 和 Service
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/status", "services"]
  verbs: ["get", "list", "watch"]
---
# 需要时再绑定
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: production
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### 2.3 ServiceAccount 安全最佳实践

每个 Pod 都应使用专用的 ServiceAccount，而非使用默认的 `default`：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: production
automountServiceAccountToken: false  # 如不需要访问 API Server 则禁用
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      serviceAccountName: my-app-sa
      automountServiceAccountToken: true  # 根据实际需要
      containers:
      - name: app
        image: my-app:latest
```

### 2.4 RBAC 常见权限模型对比

| 模型 | 适合场景 | 优点 | 缺点 |
|------|---------|------|------|
| 单集群管理员 | 小型团队 | 简单 | 权限过大，易误操作 |
| 命名空间隔离 | 多团队共享集群 | 分权清晰，互不干扰 | 需要规范命名空间划分 |
| 基于角色的细粒度 | 中大型企业 | 权限最小化，审计合规 | 配置复杂，需 RBAC 治理工具 |
| Attribute-Based (ABAC) | 特殊合规场景 | 规则灵活 | Kubernetes 官方已不推荐，建议 RBAC |

## 三、Pod Security Standards

### 3.1 从 PSP 到 PSA 的迁移

PodSecurityPolicy (PSP) 在 Kubernetes v1.25 中被移除，由 Pod Security Admission (PSA) 替代。PSA 定义了三个标准策略：

| 策略级别 | 说明 | 安全强度 | 典型场景 |
|---------|------|---------|---------|
| Privileged | 无限制，允许所有权限 | 最低 | 系统组件、网络插件 |
| Baseline | 基本限制，最小化影响 | 中等 | 多数普通应用 |
| Restricted | 严格遵循 Pod 加固最佳实践 | 最高 | 敏感业务、金融应用 |

### 3.2 PSA 配置实践

通过命名空间标签启用 Pod Security Standards：

```yaml
# apply: 强制执行，拒绝不符合的 Pod
# warn: 警告但不拒绝
# audit: 仅审计记录
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: system
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: baseline
```

### 3.3 Restricted 级别的 Pod 配置

以下配置满足 restricted 策略要求：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:  # Pod 级别安全上下文
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: my-app:1.0
    securityContext:  # 容器级别安全上下文
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 1000
      privileged: false
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 128Mi
```

## 四、NetworkPolicy 隔离策略

### 4.1 默认拒绝所有流量

Kubernetes 集群默认允许所有 Pod 间流量。第一步应该启用默认拒绝策略：

```yaml
# 默认拒绝所有入站和出站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}  # 匹配所有 Pod
  policyTypes:
  - Ingress
  - Egress
```

### 4.2 三层隔离模型实战

```yaml
# 第一层：允许前端 Pod 接收来自 Ingress 的流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
      podSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
---
# 第二层：允许前端访问后端 API（仅允许特定端口）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 3000  # 仅暴露业务端口，排除管理端口
---
# 第三层：后端可以访问数据库（限制出口）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-to-database
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

### 4.3 NetworkPolicy 限制与注意事项

| 限制 | 说明 | 替代方案 |
|------|------|---------|
| 不支持 DNS 解析拒绝 | NetworkPolicy 无法过滤 DNS 查询 | 使用 CiliumNetworkPolicy (Cilium) |
| 默认 allow-first | 未匹配策略的流量默认通过 | 先部署 default-deny |
| 不覆盖 HostNetwork | hostNetwork=true 的 Pod 不受控 | 避免使用 hostNetwork |
| 不覆盖 kube-system | 除非显式在 kube-system 部署 | 对系统组件谨慎控制 |

## 五、Secrets 安全管理

### 5.1 etcd 加密配置

Kubernetes 支持在 etcd 层面对 Secrets 进行加密存储：

```yaml
# EncryptionConfiguration
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: xxxx...  # 32 字节 Base64 编码密钥
  - identity: {}  # 兜底，未加密的 secrets 读入后重新加密
```

启用 etcd 加密后，需要在 API Server 启动参数中引用此配置：

```yaml
# kube-apiserver 启动参数
--encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

### 5.2 External Secrets Operator 集成

不再将敏感信息硬编码到 YAML 中：

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "app-reader"
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: production
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: db-credentials  # 生成的 K8s Secret 名称
  data:
  - secretKey: username
    remoteRef:
      key: production/database
      property: username
  - secretKey: password
    remoteRef:
      key: production/database
      property: password
```

### 5.3 Secret 安全最佳实践汇总

| 实践 | 说明 | 推荐级别 |
|------|------|---------|
| etcd 加密 | 防止 etcd 数据泄露 | 必须 |
| 最小化 Secrets 数量 | 不将配置信息混入 Secrets | 推荐 |
| 外部 Secrets 管理 | HashiCorp Vault / AWS Secrets Manager | 推荐 |
| 禁止 Secret 环境变量 | 使用 Volume 挂载代替 | 推荐 |
| 定期轮换 | 默认 30-90 天自动轮换 | 必须 |
| RBAC 限制 Secrets 读写 | 仅授权管理员和特定应用 | 必须 |

## 六、容器运行时安全

### 6.1 镜像安全扫描（Trivy）

集成到 CI/CD 流水线中：

```yaml
# .gitlab-ci.yml 集成 Trivy 扫描
container_scan:
  stage: test
  image: aquasec/trivy:latest
  script:
    - trivy image --severity CRITICAL,HIGH \
      --ignore-unfixed \
      --exit-code 1 \
      my-registry/app:${CI_COMMIT_SHA}
```

Trivy 的 CVE 严重等级与 Kubernetes Pod 安全联动：

| Trivy 严重等级 | 处理策略 | CI 阻断 |
|---------------|---------|--------|
| CRITICAL | 必须修复，阻断部署 | 是 |
| HIGH | 评估影响，尽快修复 | 可选 |
| MEDIUM | 记录，定期批量处理 | 否 |
| LOW | 忽略或记录 | 否 |

### 6.2 Seccomp 与 AppArmor 配置

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
  annotations:
    # AppArmor 配置（需要节点支持）
    container.apparmor.security.beta.kubernetes.io/app: localhost/k8s-apparmor-profile
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: config/seccomp/deny-exec.json
  containers:
  - name: app
    image: my-app:1.0
```

Seccomp 配置文件示例（拒绝 exec 系统调用）：

```json
{
    "defaultAction": "SCMP_ACT_ALLOW",
    "architectures": ["SCMP_ARCH_X86_64"],
    "syscalls": [
        {
            "names": ["execve", "execveat", "fork", "vfork", "clone"],
            "action": "SCMP_ACT_ERRNO",
            "args": [],
            "comment": "Block process creation syscalls"
        }
    ]
}
```

### 6.3 只读根文件系统

通过配置 readOnlyRootFilesystem，防止容器运行时写入恶意文件：

```yaml
spec:
  containers:
  - name: app
    securityContext:
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: logs
      mountPath: /var/log/app
  volumes:
  - name: tmp
    emptyDir: {}
  - name: logs
    emptyDir: {}
```

## 七、运行时安全监控

### 7.1 Falco 异常检测

Falco 是 CNCF 孵化的运行时安全项目，通过 eBPF/Custom Kernel Module 监控系统调用。关键检测规则：

```yaml
# falco_rules.yaml
- rule: Terminal shell in container
  desc: Detect shell spawned in container (not from kubectl exec)
  condition: >
    spawned_process and container
    and shell_procs
    and not proc.name in (bash, zsh, sh, dash)
    and not user.uid == 0
  output: >
    Shell spawned in container (user=%user.name container=%container.name
    image=%container.image proc=%proc.name)
  priority: WARNING
  tags: [container, shell]

- rule: Write below /etc
  desc: Detect write to /etc directory
  condition: >
    evt.type = open or evt.type = openat
    and evt.dir = <
    and container
    and fd.name startswith /etc/
    and not fd.name startswith /etc/passwd
  output: >
    File below /etc opened for writing (user=%user.name
    command=%proc.cmdline file=%fd.name)
  priority: ERROR
  tags: [filesystem, container]
```

### 7.2 Kubernetes 审计日志

```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# 记录所有 Secrets 相关操作
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets"]

# 记录 Pod exec 操作
- level: Request
  verbs: ["create"]
  resources:
  - group: ""
    resources: ["pods/exec", "pods/attach", "pods/portforward"]

# 记录配置变更
- level: Metadata
  verbs: ["create", "update", "delete", "patch"]
  omitStages:
  - "RequestReceived"

# 默认不记录只读元数据操作
- level: None
  userGroups: ["system:authenticated"]
  verbs: ["get", "list", "watch"]
```

## 八、安全基准检查（kube-bench）

kube-bench 基于 CIS Kubernetes Benchmark 标准进行自动化检查：

```bash
# 运行 kube-bench
kube-bench run --targets master,node --config-dir /etc/kube-bench/cfg

# 检查结果示例
# [PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive (Automated)
# [FAIL] 1.2.2 Ensure that the --etcd-cafile argument is set as appropriate (Automated)
```

CIS Benchmark 核心检查项：

| 检查类别 | 检查项数 | 关键检查点 |
|---------|---------|-----------|
| Master 节点 | 22 项 | API Server 参数安全、etcd TLS、RBAC 启用 |
| Worker 节点 | 10 项 | Kubelet TLS、匿名认证禁用 |
| 控制平面 | 30 项 | Pod 安全策略、网络默认拒绝 |
| 策略 | 15 项 | Secret 加密、审计日志启用 |

## 九、总结

生产级 Kubernetes 安全体系需要从集群基础设施到容器运行时的全方位防护。关键要点总结如下：

1. **RBAC 是第一道防线**：遵循最小权限原则，每个 ServiceAccount 只授予必要的权限
2. **Pod Security Standards**：使用 PSA 替代已移除的 PSP，生产环境建议使用 restricted 级别
3. **网络隔离**：默认拒绝所有流量，按需开放白名单策略
4. **Secret 安全**：启用 etcd 加密，集成外部 Secret 管理工具
5. **容器加固**：只读根文件系统、禁用特权提升、Seccomp 限制系统调用
6. **运行时监控**：部署 Falco 检测异常行为，启用审计日志记录敏感操作
7. **持续合规**：通过 kube-bench 定期巡检基准合规

安全不是一次性任务，而是持续的过程。建议将安全检查集成到 CI/CD 流水线中，并结合镜像扫描、策略即代码（Policy-as-Code）实现安全的自动化和左移。
