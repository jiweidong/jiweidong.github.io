---
title: Helm 3 实战：Kubernetes 应用包管理与生产级模板开发
date: 2026-06-17 08:25:00
tags:
  - Kubernetes
  - Helm
  - DevOps
  - 云原生
categories:
  - DevOps
author: 东哥
---

# Helm 3 实战：Kubernetes 应用包管理与生产级模板开发

## 一、为什么需要 Helm

Kubernetes 的 YAML 编排在管理简单应用时还好，但面对微服务架构，问题就暴露了：

| 问题 | 传统 YAML | Helm 方案 |
|------|-----------|-----------|
| 重复配置 | 每套环境（dev/staging/prod）维护一套 YAML | 模板 + Values 注入 |
| 难以复用 | 复制粘贴，容易出错 | Chart 包可复用 |
| 版本管理 | 散落在不同目录，难以追踪 | Helm release 版本化管理 |
| 依赖管理 | 手动部署依赖组件 | Chart 依赖声明自动处理 |
| 回滚困难 | 需要手动回退 YAML | helm rollback 一键回滚 |

Helm 是 Kubernetes 的包管理器，通过 Chart 将一组 K8s 资源打包、版本化、分发和管理。

## 二、Helm 3 核心概念

### 2.1 架构变化

Helm 3 去掉了 Tiller（服务端组件），只保留客户端，大幅简化了安全模型：

```
Helm 2 架构：
┌────────┐    ┌────────┐    ┌──────────┐
│ Helm   │───→│ Tiller │───→│ K8s API  │
│ Client │    │ Server │    │ Server   │
└────────┘    └────────┘    └──────────┘
               ← RBAC + gRPC →

Helm 3 架构（更简单）：
┌────────┐                     ┌──────────┐
│ Helm   │────────────────────│ K8s API  │
│ Client │    kubeconfig/RBAC  │ Server   │
└────────┘                     └──────────┘
```

### 2.2 核心组件

| 组件 | 说明 | 类比 |
|------|------|------|
| Chart | 包含所有 K8s 资源定义和模板的包 | apt 包 / npm 包 |
| Repository | Chart 的存储仓库 | Docker Registry / npm Registry |
| Release | Chart 在集群中的一次部署实例 | 一个运行中的部署 |
| Values | 配置值，注入到模板中 | 环境变量 / 配置文件 |

## 三、Chart 目录结构

```
my-app/
├── Chart.yaml                    # Chart 元信息
├── values.yaml                   # 默认配置值
├── values-dev.yaml               # 开发环境覆盖值
├── values-prod.yaml              # 生产环境覆盖值
├── charts/                       # 子 Chart 依赖
├── templates/                    # 模板文件目录
│   ├── NOTES.txt                 # 安装后的提示信息
│   ├── _helpers.tpl              # 模板辅助函数
│   ├── deployment.yaml           # Deployment 模板
│   ├── service.yaml              # Service 模板
│   ├── ingress.yaml              # Ingress 模板
│   ├── configmap.yaml            # ConfigMap 模板
│   ├── secrets.yaml              # Secret 模板
│   ├── hpa.yaml                  # HPA 模板
│   ├── pvc.yaml                  # PVC 模板
│   ├── serviceaccount.yaml       # ServiceAccount 模板
│   └── tests/                    # 测试模板
│       └── test-connection.yaml
├── .helmignore                   # 打包忽略文件
└── README.md
```

### 3.1 Chart.yaml

```yaml
apiVersion: v2
name: my-app
description: 一个生产级 Spring Boot 应用
type: application
version: 1.2.0           # Chart 版本
appVersion: "2.5.1"     # 应用版本
kubeVersion: ">=1.23.0" # 兼容的 K8s 版本

dependencies:
  - name: mysql
    version: "9.10.0"
    repository: "https://charts.bitnami.com/bitnami"
    condition: mysql.enabled
  - name: redis
    version: "17.15.0"
    repository: "https://charts.bitnami.com/bitnami"
    condition: redis.enabled
```

## 四、模板语法详解

### 4.1 基础模板语法

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "my-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "my-app.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "my-app.serviceAccountName" . }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.port }}
              protocol: TCP
          env:
            {{- toYaml .Values.env | nindent 12 }}
          envFrom:
            - configMapRef:
                name: {{ include "my-app.fullname" . }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          volumeMounts:
            {{- toYaml .Values.volumeMounts | nindent 12 }}
      volumes:
        {{- toYaml .Values.volumes | nindent 8 }}
```

### 4.2 辅助模板（_helpers.tpl）

```yaml
{{- /* 生成完整应用名称 */ -}}
{{- define "my-app.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- $name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /* 生成公共 labels */ -}}
{{- define "my-app.labels" -}}
helm.sh/chart: {{ include "my-app.chart" . }}
{{ include "my-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* 生成选择器 labels */ -}}
{{- define "my-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "my-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /* 生成 Chart 版本标签 */ -}}
{{- define "my-app.chart" -}}
{{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}
```

### 4.3 内建对象

| 对象 | 说明 | 示例 |
|------|------|------|
| `.Release.Name` | Release 名称 | `my-app-prod` |
| `.Release.Namespace` | Release 所在的命名空间 | `production` |
| `.Release.Service` | Helm 服务名称 | `Helm` |
| `.Release.Revision` | Release 的修订号 | `3` |
| `.Chart.Name` | Chart 名称 | `my-app` |
| `.Chart.Version` | Chart 版本 | `1.2.0` |
| `.Chart.AppVersion` | 应用版本 | `2.5.1` |
| `.Files.Get` | 获取文件内容 | `.Files.Get "config/application.yml"` |
| `.Capabilities.APIVersions` | 集群支持的 API 版本集合 | 用于条件判断 |

### 4.4 流程控制

```yaml
# 条件判断
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "my-app.fullname" . }}
  annotations:
    {{- toYaml .Values.ingress.annotations | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ include "my-app.fullname" $ }}
                port:
                  number: {{ $.Values.service.port }}
          {{- end }}
    {{- end }}
{{- end }}

# 循环迭代
{{- range $key, $value := .Values.configMap }}
{{ $key }}: {{ $value | quote }}
{{- end }}

# 变量作用域
{{- $globalVar := .Values.global.replicaCount }}
{{- range .Values.services }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
spec:
  replicas: {{ $globalVar }}   # 使用外部变量
{{- end }}
```

### 4.5 管道和函数

```yaml
# 字符串函数
{{ .Values.name | upper | quote }}        # 转大写并加引号
{{ .Values.name | default "default-name" }} # 设置默认值
{{ .Values.name | trimSuffix "-app" }}     # 去掉后缀
{{ .Values.name | trunc 63 }}              # 截断到 63 字符

# 缩进处理
{{ include "my-app.labels" . | indent 4 }}  # 4 空格缩进
{{ include "my-app.labels" . | nindent 4 }} # 换行 + 4 空格缩进

# 类型转换
{{ .Values.replicaCount | int }}             # 转整型
{{ .Values.debug | default false | bool }}   # 转布尔值
{{ .Values.cpuLimit | toString }}            # 转字符串

# JSON/YAML 输出
{{ .Values.nodeSelector | toJson }}          # JSON 格式
{{ .Values.nodeSelector | toYaml }}          # YAML 格式
```

## 五、多环境配置管理

### 5.1 values.yaml（默认值）

```yaml
# values.yaml — 通用默认值
replicaCount: 1

image:
  repository: myregistry.com/my-app
  tag: ""
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts: []

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80

env: []
  # - name: SPRING_PROFILES_ACTIVE
  #   value: "dev"
```

### 5.2 环境特定 values

```yaml
# values-dev.yaml
replicaCount: 1
image:
  tag: "latest"
  pullPolicy: Always
resources:
  requests:
    cpu: 200m
    memory: 256Mi
ingress:
  enabled: true
  hosts:
    - host: dev.myapp.com
      paths:
        - path: /
          pathType: Prefix
env:
  - name: SPRING_PROFILES_ACTIVE
    value: "dev"
  - name: LOG_LEVEL
    value: "DEBUG"
```

```yaml
# values-prod.yaml
replicaCount: 3
image:
  tag: "2.5.1"
  pullPolicy: IfNotPresent
service:
  type: ClusterIP
resources:
  requests:
    cpu: 1000m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 2Gi
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
  hosts:
    - host: api.myapp.com
      paths:
        - path: /
          pathType: Prefix
    - host: www.myapp.com
      paths:
        - path: /api
          pathType: Prefix
env:
  - name: SPRING_PROFILES_ACTIVE
    value: "prod"
  - name: LOG_LEVEL
    value: "WARN"
  - name: JAVA_OPTS
    value: "-Xms2g -Xmx2g -XX:+UseG1GC"
```

### 5.3 部署命令

```bash
# 部署到开发环境
helm upgrade --install my-app ./my-app \
  --namespace dev \
  --create-namespace \
  -f values.yaml \
  -f values-dev.yaml \
  --set image.tag=latest

# 部署到生产环境
helm upgrade --install my-app ./my-app \
  --namespace production \
  --create-namespace \
  -f values.yaml \
  -f values-prod.yaml \
  --atomic \              # 失败时自动回滚
  --wait \                # 等待所有 Pod 就绪
  --timeout 5m            # 超时 5 分钟

# 生产回滚
helm rollback my-app 2    # 回滚到 revision 2
helm history my-app        # 查看发布历史
```

## 六、生产级 Chart 开发实践

### 6.1 编写可测试的 Chart

```yaml
# templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "my-app.fullname" . }}-test-connection"
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['{{ include "my-app.fullname" . }}:{{ .Values.service.port }}']
  restartPolicy: Never
```

```bash
# 运行测试
helm test my-app

# 模板渲染检查
helm template my-app ./my-app -f values-prod.yaml

# 语法检查
helm lint ./my-app

# 安装前模拟执行
helm install --dry-run --debug my-app ./my-app -f values-dev.yaml
```

### 6.2 打包和发布

```bash
# 打包 Chart
helm package ./my-app -d ./docs
# 生成 my-app-1.2.0.tgz

# 使用 GitHub Pages 做 Chart 仓库
mkdir -p docs
mv my-app-1.2.0.tgz docs/
helm repo index docs --url https://yourdomain.github.io/helm-charts

# 添加到仓库
helm repo add my-repo https://yourdomain.github.io/helm-charts
helm repo update
helm install my-app my-repo/my-app
```

### 6.3 复杂依赖管理

```yaml
# Chart.yaml 依赖声明
dependencies:
  - name: postgresql
    version: "12.x"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
    tags:
      - database
  - name: redis
    version: "17.x"
    repository: "https://charts.bitnami.com/bitnami"
    tags:
      - cache
```

```bash
# 依赖操作
helm dependency list      # 查看依赖
helm dependency update    # 更新依赖
helm dependency build     # 重建锁文件
```

## 七、CI/CD 集成

```yaml
# .github/workflows/helm-deploy.yml
name: Helm Deploy

on:
  push:
    branches: [main]
    paths:
      - 'helm/**'
      - '!helm/**.md'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Helm Lint
        run: helm lint ./helm/my-app

      - name: Helm Template Check
        run: helm template my-app ./helm/my-app -f ./helm/my-app/values-prod.yaml

      - name: Deploy to K8s
        run: |
          helm upgrade --install my-app ./helm/my-app \
            --namespace production \
            -f ./helm/my-app/values-prod.yaml \
            --set image.tag=${{ github.sha }} \
            --atomic \
            --wait \
            --timeout 5m
```

## 八、生产运维命令集

```bash
# == 日常运维 ==
# 查看已安装的 Release
helm list -A

# 查看 Release 状态
helm status my-app -n production

# 查看 Release 的 values
helm get values my-app -n production

# 查看 Release 的 manifest
helm get manifest my-app -n production

# 查看 Release 的 notes
helm get notes my-app -n production

# == 升级与回滚 ==
# 升级到指定版本
helm upgrade my-app ./my-app --set image.tag=3.0.0

# 回滚到之前的版本
helm rollback my-app 1

# 查看版本历史
helm history my-app

# == 清理 ==
# 卸载 Release（保留历史）
helm uninstall my-app --keep-history

# 清理 Release 历史
helm history my-app --max=10

# 删除旧版本 Release 数据
helm delete my-app --purge
```

Helm 是现代 Kubernetes 工作流中不可或缺的工具。一个好的 Helm Chart 能让应用部署从手工作坊升级到工业化流水线。关键在于：充分利用模板化能力、做好多环境配置分离、与 CI/CD 深度集成，这样才能真正发挥 Helm 的价值。
