---
title: Harbor 企业级镜像仓库搭建与运维实战
date: 2026-06-17 08:00:00
author: 东哥
categories:
  - DevOps
tags:
  - Harbor
  - Container Registry
  - Docker
  - Helm
  - 镜像仓库
  - DevOps
---

## 一、Harbor 简介

Harbor 是由 VMware 开源的企业级容器镜像仓库，现在由 CNCF 孵化管理。它解决了 Docker Registry 原生版本缺少的企业级功能，包括安全扫描、多租户权限管理、跨数据中心复制、Helm Chart 管理等。

### 1.1 Harbor vs 其他 Registry 对比

| 特性 | Docker Registry | Harbor | Quay | Nexus3 |
|------|----------------|--------|------|--------|
| 多租户 | ❌ | ✅ | ✅ | ✅ |
| 安全扫描 | ❌ | ✅ | ✅ | ✅ |
| 镜像复制 | ❌ | ✅ | ✅ | ✅ |
| Helm Chart | ❌ | ✅ | ✅ | ✅ |
| Webhook | ❌ | ✅ | ✅ | ❌ |
| 权限模型 | 简单 | RBAC | RBAC | 角色 |
| 审计日志 | ❌ | ✅ | ✅ | ❌ |
| GC 策略 | 手动 | 可配置 | 自动 | 手动 |
| 部署复杂度 | ★☆☆ | ★★★ | ★★★ | ★★★ |
| 社区活跃度 | 高 | 高 | 中 | 中 |

---

## 二、Harbor 架构设计

### 2.1 核心组件架构

```
┌─────────────────────────────────────────────────────────┐
│                    Harbor 整体架构                        │
├─────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌────────┐  ┌──────────┐  │
│  │  Portal   │  │  Core     │  │ Registry│  │   Job    │  │
│  │ (Web UI)  │  │ (API/UI)  │  │ (Docker │  │ Service  │  │
│  └──────────┘  │  Auth/    │  │  Registry)│  │ (复制/GC) │  │
│                │  Logging   │  └────────┘  └──────────┘  │
│                └──────────┘                              │
│  ┌──────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐  │
│  │  Clair/   │  │ ChartMuseum│ │ Notary  │  │  Exporter │  │
│  │  Trivy    │  │ (Helm    │  │(镜像签名)│  │ (Metrics) │  │
│  │ 扫描器    │  │ 仓库)    │  │         │  │          │  │
│  └──────────┘  └──────────┘  └─────────┘  └──────────┘  │
├─────────────────────────────────────────────────────────┤
│                      数据库 (PostgreSQL)                  │
│                      缓存 (Redis)                        │
│                      存储 (S3/NFS/本地)                   │
└─────────────────────────────────────────────────────────┘
```

### 2.2 各组件功能

| 组件 | 功能说明 | 端口 | 高可用方案 |
|------|----------|------|------------|
| **Portal** | Harbor Web 管理界面 | 443 | 多实例 + LB |
| **Core** | 核心 API、认证、RBAC | 8080 | 多实例 + Redis Session |
| **Registry** | Docker Registry 实现（分发存储） | 5000 | 共享存储 + 多实例 |
| **Job Service** | 异步任务：复制、扫描、GC | 8080 | 多实例 |
| **Trivy/Clair** | 镜像漏洞扫描 | 8080 | 独立部署 |
| **ChartMuseum** | Helm Chart 仓库 | 9999 | 共享存储 + 多实例 |
| **Notary** | 镜像内容签名 | 4443 | 需额外配置 |
| **Exporter** | Prometheus 指标暴露 | 9101 | 随 Core 实例 |

---

## 三、安装部署方案

### 3.1 环境准备

```bash
# 系统要求：Ubuntu 22.04 / CentOS 8+ / Rocky Linux 9
# 最低配置：4C 8G 100GB 磁盘（建议 8C 16G）

# 安装 Docker Engine（需要 20.10+）
curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

# 安装 Docker Compose V2
apt-get install docker-compose-plugin   # Ubuntu
# 或
yum install docker-compose-plugin       # CentOS/Rocky

# 安装 certbot（用于 HTTPS 证书）
apt-get install certbot
```

### 3.2 在线安装

```bash
# 下载离线安装包（建议使用离线包，更稳定）
wget https://github.com/goharbor/harbor/releases/download/v2.12.0/harbor-online-installer-v2.12.0.tgz

# 解压
tar zxf harbor-online-installer-v2.12.0.tgz
cd harbor

# 复制配置文件
cp harbor.yml.tmpl harbor.yml
```

### 3.3 HTTPS 配置

```yaml
# harbor.yml
hostname: harbor.example.com

# HTTPS 配置方式一：自签名证书
https:
  port: 443
  certificate: /data/cert/harbor.example.com.crt
  private_key: /data/cert/harbor.example.com.key

# HTTPS 配置方式二：Let's Encrypt（推荐）
# 先通过 certbot 获取证书：
# certbot certonly --standalone -d harbor.example.com
```

**生成自签名证书：**

```bash
# 生成 CA 证书
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
  -subj "/C=CN/ST=Beijing/L=Beijing/O=Example/OU=DevOps/CN=harbor.example.com" \
  -key ca.key -out ca.crt

# 生成服务端证书
openssl genrsa -out harbor.example.com.key 4096
openssl req -sha512 -new \
  -subj "/C=CN/ST=Beijing/L=Beijing/O=Example/OU=DevOps/CN=harbor.example.com" \
  -key harbor.example.com.key -out harbor.example.com.csr

# 生成 x509 v3 扩展
cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=harbor.example.com
EOF

# 签署证书
openssl x509 -req -sha512 -days 3650 \
  -extfile v3.ext \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -in harbor.example.com.csr -out harbor.example.com.crt
```

### 3.4 部署 Harbor

```bash
# 执行安装脚本
./install.sh

# 验证安装
docker-compose ps

# 输出类似（共 8+ 个容器）：
#     Name                    Command            State                 Ports
# ------------------------------------------------------------------------------------
# harbor-core              /harbor/harbor_core        Up (healthy)   8080/tcp
# harbor-db                /docker-entrypoint.sh ...  Up (healthy)   5432/tcp
# harbor-jobservice        /harbor/harbor_jobs...     Up (healthy)
# harbor-log               /bin/sh -c ...             Up (healthy)   127.0.0.1:1514->10514/tcp
# harbor-portal            nginx -g daemon off;       Up (healthy)   8080/tcp
# harbor-redis             redis-server /etc/redis... Up (healthy)   6379/tcp
# harbor-registry          /home/harbor/entrypo...    Up (healthy)   5000/tcp
# harbor-registryctl       /home/harbor/start_ve...   Up (healthy)
# nginx                    nginx -g daemon off;       Up (healthy)   0.0.0.0:443->443/tcp
# trivy-adapter            /home/scanner/entryp...    Up (healthy)   8080/tcp
```

### 3.5 离线安装（内网环境）

```bash
# 下载离线安装包（约 800MB）
wget https://github.com/goharbor/harbor/releases/download/v2.12.0/harbor-offline-installer-v2.12.0.tgz

tar zxf harbor-offline-installer-v2.12.0.tgz
cd harbor

# 配置 harbor.yml（同上）
# 预加载镜像
docker load -i harbor-offline-installer-v2.12.0.tgz

# 安装
./install.sh --with-trivy --with-chartmuseum
```

---

## 四、多租户管理

### 4.1 权限模型

Harbor 的权限模型分为三层：

```
系统管理员 (admin) ─────────────── 管理整个 Harbor
        │
        ├─ 项目管理员 ─── 管理单个项目
        │
        ├─ 开发者 ────── 推送/拉取镜像
        │
        └─ 访客 ─────── 只读访问（拉取镜像）
```

### 4.2 项目与用户管理

```bash
# 通过 Harbor API 创建项目
curl -k -X POST "https://harbor.example.com/api/v2.0/projects" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{
    "project_name": "backend-service",
    "public": false,
    "storage_limit": -1
  }'

# 创建用户
curl -k -X POST "https://harbor.example.com/api/v2.0/users" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "dev-zhang",
    "email": "zhang@example.com",
    "password": "Changeme@123",
    "realname": "Zhang San"
  }'

# 添加用户到项目并赋予角色
curl -k -X POST "https://harbor.example.com/api/v2.0/projects/backend-service/members" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{
    "role_id": 2,  # 2=开发者, 3=访客, 1=项目管理员
    "member_user": {
      "username": "dev-zhang"
    }
  }'
```

### 4.3 角色权限矩阵

| 操作 | 访客 | 开发者 | 项目管理员 | 系统管理员 |
|------|------|--------|------------|------------|
| 查看镜像 | ✅ | ✅ | ✅ | ✅ |
| 拉取镜像 | ✅ | ✅ | ✅ | ✅ |
| 推送镜像 | ❌ | ✅ | ✅ | ✅ |
| 删除镜像 | ❌ | ❌ | ✅ | ✅ |
| 配置 Webhook | ❌ | ❌ | ✅ | ✅ |
| 配置复制规则 | ❌ | ❌ | ❌ | ✅ |
| 创建项目 | ❌ | ❌ | ❌ | ✅ |
| 管理用户 | ❌ | ❌ | ❌ | ✅ |
| 系统配置 | ❌ | ❌ | ❌ | ✅ |

---

## 五、镜像复制策略

### 5.1 复制模式对比

| 模式 | 方向 | 适用场景 | 延迟 |
|------|------|----------|------|
| **推模式** | 中心 → 边缘 | 总部推送镜像到分支机构 | 分钟级 |
| **拉模式** | 边缘 → 中心 | 边缘主动从中心拉取 | 分钟级 |
| **P2P** | 对等复制 | 灾备多活数据中心 | 秒级 |

### 5.2 配置复制规则

```bash
# 通过 API 创建复制规则（中心 → 边缘）
curl -k -X POST "https://harbor.example.com/api/v2.0/replication/policies" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sync-to-beijing",
    "description": "同步到北京数据中心",
    "src_registry": {"id": 1},
    "dest_registry": {
      "type": "harbor",
      "name": "Beijing Harbor",
      "endpoint_url": "https://harbor-beijing.example.com",
      "credential": {
        "access_key": "robot$sync-account",
        "access_secret": "xxxxxx"
      },
      "insecure": false
    },
    "filters": [
      {"type": "name", "value": "backend/**"},
      {"type": "tag", "value": "v*"},
      {"type": "resource", "value": "image"}
    ],
    "trigger": {
      "type": "event_based"
    },
    "enabled": true
  }'
```

### 5.3 多数据中心同步拓扑

```
                   ┌──────────────────┐
                   │  上海（主）Harbor  │
                   │   harbor-sh.cn    │
                   └────────┬─────────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ 北京 Harbor   │ │ 深圳 Harbor   │ │ 新加坡 Harbor │
    │ harbor-bj.cn  │ │ harbor-sz.cn  │ │ harbor-sg.cn  │
    └──────────────┘ └──────────────┘ └──────────────┘
            │               │               │
            ▼               ▼               ▼
        Kubernetes       Kubernetes      Kubernetes
        集群 A            集群 B           集群 C
```

---

## 六、镜像安全扫描

### 6.1 扫描策略配置

```bash
# 配置自动扫描（所有推送的镜像自动扫描）
# 在 Harbor UI → Configuration → Scanner → 开启 "Automatically scan images on push"

# 手动触发扫描
curl -k -X POST "https://harbor.example.com/api/v2.0/projects/backend-service/repositories/nginx/artifacts/latest/scan" \
  -u "admin:password"

# 获取扫描结果
curl -k "https://harbor.example.com/api/v2.0/projects/backend-service/repositories/nginx/artifacts/latest" \
  -u "admin:password" | jq '.scan_overview'
```

### 6.2 Trivy 扫描器配置

```yaml
# harbor.yml 中配置 Trivy
trivy:
  # 自动更新漏洞数据库
  skip_update: false
  # 使用离线漏洞数据库
  offline_scan: false
  # 安全级别设置
  severity: UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL
  # 同时扫描数量
  concurrent: 5
  # 漏洞数据库更新间隔（小时）
  refresh_interval: 24
```

### 6.3 安全策略

```bash
# 创建安全策略：阻止高危镜像部署
curl -k -X POST "https://harbor.example.com/api/v2.0/projects/backend-service/immutabletagrules" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{
    "priority": 0,
    "disabled": false,
    "action": "block_vulnerability",
    "template": "severity >= HIGH,fix_version != empty"
  }'
```

**扫描策略建议：**

| 漏洞等级 | 数量阈值 | 处理方式 |
|----------|----------|----------|
| Critical | 任意 | 阻断推送，立即修复 |
| High | > 3 个 | 告警，限期 24h 修复 |
| Medium | > 10 个 | 告警，限期 7 天修复 |
| Low | 不限 | 记录，持续跟踪 |

---

## 七、镜像清理与 GC 策略

### 7.1 自动清理策略

```yaml
# Harbor UI → 项目 → 配置 → 清理策略
# 配置定期清理规则：

# 规则示例：保留最近 10 个版本，删除其他
- 保留最近推送的镜像数: 10
- 删除超过 30 天的镜像
- 排除标签模式: latest, v*
- 排除带有签名或扫描结果的镜像
- 运行频率: 每天凌晨 2:00 (cron: 0 2 * * *)
```

### 7.2 手动 GC 清理

```bash
# 查看磁盘占用
du -sh /data/registry/docker/registry/v2/

# 手动触发 GC（需要先停止 Registry 写入）：
# 方式一：通过 Harbor API
curl -k -X POST "https://harbor.example.com/api/v2.0/system/gc/schedule" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{"schedule": {"type": "Manual", "offtime": true}}'

# 方式二：直接执行 GC
# 注意：会重启 Registry 服务
docker-compose stop registry
docker run -it --rm \
  -v /data/registry:/registry \
  registry:2 bash -c '
  /bin/registry garbage-collect /etc/docker/registry/config.yml
  '
docker-compose start registry

# 查看 GC 历史记录
curl -k "https://harbor.example.com/api/v2.0/system/gc" \
  -u "admin:password" | jq
```

### 7.3 存储优化对比

| 策略 | 节省空间 | 风险 | 推荐场景 |
|------|----------|------|----------|
| 按版本数清理 | 中等 | 低 | 日常开发环境 |
| 按时间清理 | 中等 | 低 | 测试/预发环境 |
| 定期 GC | 高 | 中（短暂停服） | 所有环境 |
| 设置存储配额 | 预防性 | 低 | 公用 Harbor |
| Blob 去重（Registry 天然支持） | 高 | 无 | 所有环境 |

---

## 八、Robot Account 自动化集成

### 8.1 创建 Robot Account

```bash
# 创建 Harbor 级别的 Robot Account（可跨项目）
curl -k -X POST "https://harbor.example.com/api/v2.0/robots" \
  -u "admin:password" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "gitlab-ci-robot",
    "description": "GitLab CI/CD 集成账户",
    "duration": -1,
    "level": "system",
    "permissions": [
      {
        "kind": "project",
        "namespace": "backend-service",
        "access": [
          {"resource": "repository", "action": "push"},
          {"resource": "repository", "action": "pull"},
          {"resource": "artifact", "action": "delete"},
          {"resource": "scanner", "action": "create"}
        ]
      }
    ],
    "disable": false
  }'
```

### 8.2 在 CI/CD 中集成

```yaml
# GitLab CI 集成 Robot Account
docker-login:
  stage: pre-build
  script:
    - docker login harbor.example.com \
        -u "robot$gitlab-ci-robot" \
        -p "$HARBOR_ROBOT_TOKEN"

docker-build:
  stage: build
  script:
    - docker build -t harbor.example.com/backend-service/app:$CI_COMMIT_SHORT_SHA .
    - docker push harbor.example.com/backend-service/app:$CI_COMMIT_SHORT_SHA
```

### 8.3 Kubernetes 拉取镜像

```yaml
# 创建 docker-registry Secret
apiVersion: v1
kind: Secret
metadata:
  name: harbor-regcred
  namespace: production
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {{ printf '{"auths":{"harbor.example.com":{"username":"robot$k8s-pull","password":"%s"}}}' .Values.harborRobotToken | b64enc }}

---
# 在 Deployment 中使用
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      imagePullSecrets:
        - name: harbor-regcred
      containers:
        - name: app
          image: harbor.example.com/backend-service/app:v1.2.3
```

---

## 九、Helm Chart 仓库管理

### 9.1 启用 ChartMuseum

```bash
# 安装时启用 ChartMuseum
./install.sh --with-chartmuseum

# 验证 ChartMuseum 是否运行
curl -k https://harbor.example.com/chartrepo/health
```

### 9.2 推送 Helm Chart

```bash
# 安装 Helm 推送插件
helm plugin install https://github.com/chartmuseum/helm-push

# 登录 Harbor Chart 仓库
helm repo add harbor --username admin --password password \
  https://harbor.example.com/chartrepo

# 推送 Chart
helm push myapp-1.0.0.tgz harbor

# 添加项目级的 Chart 仓库
helm repo add harbor-backend --username admin --password password \
  https://harbor.example.com/chartrepo/backend-service

helm push myapp-1.0.0.tgz harbor-backend
```

### 9.3 在 Kubernetes 中使用

```bash
# 添加仓库
helm repo add myrepo https://harbor.example.com/chartrepo/backend-service \
  --username robot$helm-pull \
  --password $ROBOT_TOKEN

helm repo update

# 安装 Chart
helm install myapp myrepo/myapp --version 1.0.0

# 升级
helm upgrade myapp myrepo/myapp --version 1.1.0
```

---

## 十、备份与灾难恢复

### 10.1 备份策略

```bash
#!/bin/bash
# backup-harbor.sh - Harbor 数据备份脚本

BACKUP_DIR="/backup/harbor/$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR

# 1. 备份数据库
echo "📦 备份 PostgreSQL..."
docker exec harbor-db pg_dump -U postgres harbor > $BACKUP_DIR/harbor.sql

# 2. 备份 Redis 数据
echo "💾 备份 Redis..."
docker exec harbor-redis redis-cli SAVE
docker cp harbor-redis:/data/dump.rdb $BACKUP_DIR/redis.rdb

# 3. 备份配置文件
echo "📝 备份配置..."
cp -r /opt/harbor/harbor.yml $BACKUP_DIR/
cp -r /opt/harbor/common/ $BACKUP_DIR/common/

# 4. 备份证书
echo "🔐 备份证书..."
cp -r /data/cert/ $BACKUP_DIR/cert/

# 5. 备份镜像元数据（不备份镜像 blob，仅备份数据库已足够）
# 镜像 blob 可通过同步重新获取

# 6. 打包压缩
cd /backup/harbor
tar czf harbor-backup-$(date +%Y%m%d).tar.gz $(date +%Y%m%d_%H%M%S)

# 7. 清理旧备份（保留 7 天）
find /backup/harbor -name "harbor-backup-*.tar.gz" -mtime +7 -delete

echo "✅ 备份完成: /backup/harbor/harbor-backup-$(date +%Y%m%d).tar.gz"
```

### 10.2 恢复步骤

```bash
#!/bin/bash
# restore-harbor.sh - Harbor 恢复脚本

BACKUP_FILE=$1

if [ -z "$BACKUP_FILE" ]; then
  echo "用法: $0 <备份文件路径>"
  exit 1
fi

# 1. 停止 Harbor 服务
cd /opt/harbor
docker-compose down

# 2. 解压备份
TEMP_DIR=$(mktemp -d)
tar zxf $BACKUP_FILE -C $TEMP_DIR

# 3. 恢复配置文件
cp $TEMP_DIR/harbor.yml /opt/harbor/
cp -r $TEMP_DIR/common/ /opt/harbor/

# 4. 恢复证书
cp -r $TEMP_DIR/cert/* /data/cert/

# 5. 启动数据库和 Redis
docker-compose up -d harbor-db harbor-redis
sleep 10

# 6. 恢复数据库
docker exec -i harbor-db psql -U postgres harbor < $TEMP_DIR/harbor.sql

# 7. 恢复 Redis
docker cp $TEMP_DIR/redis.rdb harbor-redis:/data/dump.rdb
docker-compose restart harbor-redis

# 8. 启动所有服务
docker-compose up -d

# 9. 健康检查
sleep 20
curl -k https://harbor.example.com/api/v2.0/ping

echo "✅ 恢复完成！"

# 清理临时目录
rm -rf $TEMP_DIR
```

---

## 十一、与 Kubernetes 集成最佳实践

### 11.1 ImagePullSecrets 自动注入

```yaml
# 方案一：手动创建 Secret（简单但维护成本高）
kubectl create secret docker-registry harbor-cred \
  --docker-server=harbor.example.com \
  --docker-username='robot$k8s' \
  --docker-password='YOUR_TOKEN' \
  --namespace production

# 方案二：使用 Reloader 自动轮换 Secret
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-auth-config
data:
  config.json: |-
    {
      "auths": {
        "harbor.example.com": {
          "username": "robot$k8s",
          "password": "ROBOT_TOKEN_PLACEHOLDER"
        }
      }
    }
```

### 11.2 镜像拉取优化

```yaml
# 配置 kubelet 镜像拉取速度
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serializeImagePulls: false  # 并行拉取镜像
registryPullQPS: 10        # 镜像拉取 QPS 限制
registryBurst: 20           # 突发拉取数量
```

### 11.3 使用 Harbor 作为 K8s 镜像代理缓存

```yaml
# 配置 Harbor 代理缓存项目（Pull Through Proxy）
# Harbor UI → 新建项目 → 选择 "Proxy Cache"
# 上游 Registry 设置为 Docker Hub 或 gcr.io

# Deployment 中使用代理缓存
image: harbor.example.com/docker-proxy/library/nginx:1.27
image: harbor.example.com/gcr-proxy/google-samples/microservices-demo:v0.3.5
```

---

## 十二、性能调优与高可用部署

### 12.1 性能调优参数

```yaml
# harbor.yml 性能调优

# Registry 配置
registry:
  # Worker 数量（默认 10，建议 CPU 核数 * 2）
  worker_pool: 20
  # 上传并发数
  upload_purging_delay: 168h
  # Redis 缓存
  redis:
    addr: redis:6379
    read_timeout: 10s
    write_timeout: 10s

# 数据库连接池
database:
  max_idle_conns: 100
  max_open_conns: 200
  conn_max_lifetime: 5m

# 存储后端（推荐 S3 兼容存储）
storage_service:
  ca_bundle: ""
  # S3 配置
  s3:
    region: ap-east-1
    bucket: harbor-registry
    accesskey: AKIDxxxx
    secretkey: xxxxxx
    rootdirectory: /harbor
    regionendpoint: https://s3.example.com
    secure: true
    v4auth: true
    chunksize: "5242880"  # 5MB 分片
    multipartchunksize: "15728640"  # 15MB 多部分上传分片
    enableaccelerate: false
```

### 12.2 Docker Compose 资源限制

```yaml
# docker-compose.yml 资源限制示例
services:
  core:
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G

  registry:
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G

  jobservice:
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
```

### 12.3 性能对比基准

| 配置 | 同时推送 | 同时拉取 | 扫描吞吐 | 延迟 |
|------|----------|----------|----------|------|
| 4C 8G 本地存储 | 5个并发 | 50个并发 | 5个/min | 低 |
| 8C 16G S3 存储 | 20个并发 | 200个并发 | 15个/min | 中 |
| 16C 32G 分布式存储 | 50个并发 | 500个并发 | 30个/min | 低 |
| 高可用 3×16C 32G | 100个并发 | 1000+个并发 | 60个/min | 极低 |

---

## 十三、运维监控

### 13.1 Prometheus 集成

```yaml
# harbor.yml 启用指标
metrics:
  enabled: true
  port: 9101
  path: /metrics
```

采集的 Prometheus 指标示例：

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'harbor'
    scrape_interval: 15s
    static_configs:
      - targets:
          - 'harbor.example.com:9101'  # Exporter
          - 'harbor.example.com:5000'  # Registry 指标
    metrics_path: /metrics
```

### 13.2 关键告警规则

```yaml
# prometheus-rules.yml
groups:
  - name: harbor
    rules:
      - alert: HarborDiskUsageHigh
        expr: (1 - (node_filesystem_avail_bytes{mountpoint="/data"} / node_filesystem_size_bytes{mountpoint="/data"})) * 100 > 85
        for: 5m
        annotations:
          summary: "Harbor 磁盘使用率超过 85% (当前 {{ $value | humanizePercentage }})"

      - alert: HarborServiceDown
        expr: up{job="harbor"} == 0
        for: 1m
        annotations:
          summary: "Harbor {{ $labels.instance }} 服务不可用"

      - alert: HarborImagePullFailing
        expr: rate(harbor_registry_requests_duration_seconds_count{code=~"5.."}[5m]) > 0.1
        for: 5m
        annotations:
          summary: "Harbor 镜像拉取错误率过高"
```

---

## 十四、总结

Harbor 作为 CNCF 毕业项目，已经成为企业容器化转型中不可或缺的镜像仓库基础设施。本文从架构设计到生产运维，全面覆盖了 Harbor 的核心功能：

1. **安装部署** — 支持在线/离线安装，HTTPS 安全配置
2. **多租户管理** — 完善的 RBAC 权限模型
3. **镜像复制** — 支持推/拉/P2P 多种复制模式
4. **安全扫描** — 集成 Trivy/Clair，自动漏洞检测
5. **自动化集成** — Robot Account 无缝对接 CI/CD
6. **高可用方案** — 共享存储 + 多实例部署

**推荐的学习路线：** 先在小团队中使用单机版 Harbor，熟悉操作流程 → 再引入 Trivy 安全扫描 → 配置跨集群复制 → 最后实现高可用架构。逐步演进，避免一步到位带来的复杂度。
