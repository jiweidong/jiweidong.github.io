---
title: GitLab CI/CD 流水线设计与最佳实践
date: 2026-06-17 08:00:00
author: 东哥
categories:
  - DevOps
tags:
  - GitLab CI/CD
  - DevOps
  - CI/CD Pipeline
  - 持续集成
  - 持续部署
  - Automation
---

## 一、GitLab CI/CD 架构概述

GitLab CI/CD 是 GitLab 内置的持续集成/持续部署平台，无需额外搭建 Jenkins 等 CI 服务器。其核心架构包含以下关键组件：

| 组件 | 说明 | 作用 |
|------|------|------|
| **GitLab Server** | 代码仓库与 CI/CD 控制面 | 存储代码、触发 Pipeline、管理 Job 状态 |
| **GitLab Runner** | 任务执行器（可分布式部署） | 拉取代码、执行 Job 脚本、上传 Artifacts |
| **Pipeline** | 一次 CI/CD 流程的完整描述 | 由多个 Stage 组成，定义构建→测试→部署全流程 |
| **Job** | Pipeline 中的最小执行单元 | 每个 Job 在一个 Stage 内执行特定任务 |
| **Artifacts** | Job 产出物 | 构建产物、测试报告等，可在 Job 间传递 |

### 1.1 Pipeline 生命周期

```
代码推送 / MR → GitLab Trigger → 创建 Pipeline → 按 Stage 顺序执行
                                        ↓
                                 分配 Runner 执行 Job
                                        ↓
                               收集 Artifacts & 报告
                                        ↓
                                 通知结果（Email/Slack/Webhook）
```

### 1.2 Runner 执行器对比

Runner 是 CI/CD 的实际执行者，支持多种执行器：

| 执行器 | 隔离性 | 启动速度 | 适用场景 | 缺点 |
|--------|--------|----------|----------|------|
| **Shell** | 弱（共享主机） | 极快 | 简单快速验证 | 环境冲突、安全隐患 |
| **Docker** | 强（容器隔离） | 较快 | 通用 CI/CD 场景 | 需处理 Docker 缓存 |
| **Kubernetes** | 强（Pod 隔离） | 中等 | 大型团队、弹性伸缩 | 配置复杂 |
| **Docker Machine** | 强（VM 隔离） | 慢 | 需要完整 OS 环境 | 资源消耗大 |
| **SSH** | 中等 | 快 | 远程服务器执行 | 需维护 SSH 连接 |

**推荐方案：** 团队规模小用 Docker 执行器，规模大用 Kubernetes 执行器。

---

## 二、.gitlab-ci.yml 配置详解

### 2.1 基础结构与关键字

```yaml
# .gitlab-ci.yml

stages:          # 定义流水线阶段
  - build
  - test
  - package
  - deploy

variables:       # 全局变量
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
  DOCKER_IMAGE_TAG: $CI_COMMIT_SHORT_SHA

cache:           # 缓存配置（跨 Pipeline）
  key: ${CI_COMMIT_REF_SLUG}
  paths:
    - .m2/repository/
    - node_modules/

default:         # 默认配置（对所有 Job 生效）
  image: maven:3.9-eclipse-temurin-17
  timeout: 30 minutes
  retry:
    max: 2
    when:
      - runner_system_failure
      - stuck_or_timeout_failure
```

### 2.2 Stage 与 Job 定义

```yaml
maven-build:
  stage: build
  script:
    - mvn clean compile
  artifacts:          # 构建产物传递给后续 Job
    paths:
      - target/classes/
    expire_in: 2 hours

unit-test:
  stage: test
  script:
    - mvn test
  artifacts:
    reports:
      junit: target/surefire-reports/TEST-*.xml
    when: always      # 即使失败也保留报告

build-jar:
  stage: package
  script:
    - mvn package -DskipTests
  artifacts:
    paths:
      - target/*.jar
    expire_in: 1 day
```

### 2.3 条件化 Job（rules）

```yaml
deploy-dev:
  stage: deploy
  script:
    - kubectl apply -f k8s/dev/
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
      when: always
    - when: never   # 其他分支不执行

deploy-prod:
  stage: deploy
  script:
    - kubectl apply -f k8s/prod/
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
      when: manual  # 需手动确认
    - when: never
```

---

## 三、Runner 安装与注册

### 3.1 Docker 执行器 Runner 安装

```bash
# 使用 Docker 运行官方 Runner 容器
docker run -d --name gitlab-runner --restart always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /srv/gitlab-runner/config:/etc/gitlab-runner \
  gitlab/gitlab-runner:latest

# 注册 Runner
docker exec -it gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.example.com" \
  --registration-token "YOUR_TOKEN" \
  --executor "docker" \
  --docker-image "alpine:latest" \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
  --description "docker-runner-01" \
  --tag-list "docker,build" \
  --run-untagged="true" \
  --locked="false"
```

### 3.2 Kubernetes 执行器安装

```yaml
# helm install gitlab-runner -f values.yaml gitlab/gitlab-runner
# values.yaml
gitlabUrl: https://gitlab.example.com
runnerRegistrationToken: "YOUR_TOKEN"

rbac:
  create: true

runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "{{.Release.Namespace}}"
        image = "ubuntu:22.04"
        privileged = true
        [runners.kubernetes.pod_security_context]
          run_as_non_root = true
        [runners.kubernetes.volumes]
          [[runners.kubernetes.volumes.host_path]]
            name = "docker-socket"
            mount_path = "/var/run/docker.sock"
            host_path = "/var/run/docker.sock"
```

### 3.3 Runner 执行器对比表

| 特性 | Docker | Kubernetes | Shell |
|------|--------|------------|-------|
| 安装难度 | ★☆☆ | ★★★ | ★☆☆ |
| 资源隔离 | 容器级 | Pod 级 | 无 |
| 弹性伸缩 | 手动 | 自动 | 手动 |
| 缓存持久化 | 需额外配置 | PVC 实现 | 本地目录 |
| 适合团队规模 | 1-50人 | 20人以上 | 1-5人 |
| 网络开销 | 低 | 中 | 无 |

---

## 四、Pipeline 高级特性

### 4.1 parallel — 并行执行

```yaml
test:
  stage: test
  parallel: 4
  script:
    - mvn test -Dtest.suite=suite_${CI_NODE_INDEX}
  artifacts:
    paths:
      - target/surefire-reports/
```

### 4.2 needs — 有向无环图（DAG）Pipeline

```yaml
build-a:
  stage: build
  script: mvn compile -pl module-a -am

build-b:
  stage: build
  script: mvn compile -pl module-b -am

test-a:
  stage: test
  needs: ["build-a"]
  script: mvn test -pl module-a

test-b:
  stage: test
  needs: ["build-b"]
  script: mvn test -pl module-b

deploy:
  stage: deploy
  needs: ["test-a", "test-b"]
  script: mvn package -P production
```

`needs` 允许 Job 跳过未依赖的 Stage，显著提升 Pipeline 执行效率。

### 4.3 trigger — 多项目流水线

```yaml
# 父流水线（parent-pipeline）
build:
  stage: build
  script: mvn package

trigger-frontend:
  stage: deploy
  trigger:
    project: mygroup/frontend-project
    branch: main
    strategy: depend   # 等待子流水线完成

trigger-backend:
  stage: deploy
  trigger:
    project: mygroup/backend-service
    branch: main
    strategy: depend
```

### 4.4 rules — 高级条件控制

```yaml
code-analysis:
  stage: test
  image: sonarsource/sonar-scanner-cli:latest
  script:
    - sonar-scanner
      -Dsonar.projectKey=${CI_PROJECT_ID}
      -Dsonar.sources=src
      -Dsonar.host.url=${SONAR_HOST_URL}
      -Dsonar.login=${SONAR_TOKEN}
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
      when: always
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      when: always
    - when: never
```

---

## 五、多环境部署策略

### 5.1 完整的环境部署配置

```yaml
stages:
  - build
  - test
  - docker-build
  - deploy-dev
  - deploy-staging
  - deploy-prod

variables:
  REGISTRY: harbor.example.com
  APP_NAME: spring-boot-app

docker-build:
  stage: docker-build
  image: docker:24.0-cli
  services:
    - docker:24.0-dind
  script:
    - docker build -t ${REGISTRY}/${APP_NAME}:${CI_COMMIT_SHORT_SHA} .
    - docker tag ${REGISTRY}/${APP_NAME}:${CI_COMMIT_SHORT_SHA} ${REGISTRY}/${APP_NAME}:latest
    - docker push ${REGISTRY}/${APP_NAME}:${CI_COMMIT_SHORT_SHA}
    - docker push ${REGISTRY}/${APP_NAME}:latest
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop" || $CI_COMMIT_BRANCH == "main"'

.deploy-template: &deploy-template
  image: bitnami/kubectl:latest
  script:
    - sed -i "s/__IMAGE_TAG__/${CI_COMMIT_SHORT_SHA}/g" k8s/deployment.yaml
    - kubectl apply -f k8s/deployment.yaml
    - kubectl rollout status deployment/${APP_NAME} -n ${NAMESPACE}

deploy-dev:
  <<: *deploy-template
  stage: deploy-dev
  variables:
    NAMESPACE: dev
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
  environment:
    name: dev
    url: https://dev.example.com

deploy-staging:
  <<: *deploy-template
  stage: deploy-staging
  variables:
    NAMESPACE: staging
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment:
    name: staging
    url: https://staging.example.com

deploy-prod:
  <<: *deploy-template
  stage: deploy-prod
  variables:
    NAMESPACE: prod
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  when: manual
  environment:
    name: production
    url: https://example.com
```

### 5.2 环境策略对比

| 环境 | 触发条件 | 是否自动 | 审批 | 用途 |
|------|----------|----------|------|------|
| dev | develop 分支推送 | 自动 | 无 | 开发自测 |
| staging | main 分支合并 | 自动 | 无 | 集成验证 |
| production | 打 Tag（v*） | 手动 | 需要审批 | 生产发布 |

---

## 六、DIND（Docker in Docker）构建方案

### 6.1 DIND 工作原理

```yaml
docker-build-dind:
  stage: build
  image: docker:24.0-cli
  services:
    - name: docker:24.0-dind
      alias: docker
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
    DOCKER_DRIVER: overlay2
  script:
    - docker info                    # 验证 Docker 守护进程
    - docker build -t myapp:$CI_COMMIT_SHORT_SHA .
    - docker tag myapp:$CI_COMMIT_SHORT_SHA registry.example.com/myapp:$CI_COMMIT_SHORT_SHA
    - docker push registry.example.com/myapp:$CI_COMMIT_SHORT_SHA
```

### 6.2 使用 Kaniko（无特权模式，更安全）

```yaml
docker-build-kaniko:
  stage: build
  image: gcr.io/kaniko-project/executor:debug
  script:
    - /kaniko/executor
      --context=${CI_PROJECT_DIR}
      --dockerfile=${CI_PROJECT_DIR}/Dockerfile
      --destination=harbor.example.com/myapp:${CI_COMMIT_SHORT_SHA}
      --cache=true
      --cache-ttl=24h
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop" || $CI_COMMIT_BRANCH == "main"'
```

**DIND vs Kaniko 对比：**

| 特性 | DIND | Kaniko |
|------|------|--------|
| 特权模式 | 需要 | 不需要 |
| 安全性 | 低 | 高 |
| 构建速度 | 快（利用缓存） | 中等 |
| 兼容性 | 完全兼容 Dockerfile | 大部分兼容 |
| 镜像层缓存 | 自动 | 需配置 cache |

---

## 七、CI/CD 安全实践

### 7.1 敏感变量管理

在 GitLab UI 中设置 CI/CD Variables：

| 变量名 | 类型 | 说明 |
|--------|------|------|
| `SONAR_TOKEN` | Masked | SonarQube 认证令牌 |
| `DOCKER_REGISTRY_PASS` | Masked | 镜像仓库密码 |
| `KUBECONFIG_DEV` | File | 开发环境 kubeconfig |
| `KUBECONFIG_PROD` | File + Protected | 生产环境 kubeconfig |

Protected 变量仅在受保护的分支（如 main）或 Tag 上可用。

### 7.2 密钥轮换与安全策略

```yaml
# 使用 GitLab 提供的 CI_JOB_TOKEN 替代明文密码
harbor-login:
  stage: pre-build
  script:
    # 使用 CI_JOB_TOKEN 通过 GitLab Container Registry
    - docker login -u gitlab-ci-token -p $CI_JOB_TOKEN $CI_REGISTRY
```

**安全建议：**
1. **最小权限原则** — Runner Token 按项目隔离
2. **变量不可在日志中输出** — 设置 Masked 防止泄露
3. **受保护分支** — main 分支要求 MR + 审批
4. **Job Token Scope** — 限制 CI_JOB_TOKEN 可访问的项目范围
5. **定期轮换** — 每 90 天轮换一次 Secret

---

## 八、集成代码质量扫描（SonarQube）

### 8.1 流水线集成

```yaml
sonarqube-analysis:
  stage: test
  image: sonarsource/sonar-scanner-cli:5
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: "0"
  script:
    - sonar-scanner
      -Dsonar.projectKey=${CI_PROJECT_ID}
      -Dsonar.sources=src
      -Dsonar.java.binaries=target/classes
      -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
      -Dsonar.qualitygate.wait=true
      -Dsonar.host.url=${SONAR_HOST_URL}
      -Dsonar.login=${SONAR_TOKEN}
  cache:
    key: "${CI_JOB_NAME}"
    paths:
      - .sonar/cache
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'

sonarqube-quality-gate:
  stage: .post
  image: alpine/curl:8.10
  script:
    - apk add --no-cache jq
    - |
      STATUS=$(curl -s -u ${SONAR_TOKEN}: "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${CI_PROJECT_ID}" | jq -r '.projectStatus.status')
      if [ "$STATUS" != "OK" ]; then
        echo "❌ Quality Gate 未通过：$STATUS"
        exit 1
      fi
      echo "✅ Quality Gate 通过"
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

### 8.2 质量门禁策略

| 指标 | 阈值 | 操作 |
|------|------|------|
| 代码覆盖率 | < 80% | Warning |
| 代码重复率 | > 5% | Warning |
| 严重 Bug | > 0 | Block Pipeline |
| 安全漏洞（Critical） | > 0 | Block Pipeline |
| 技术债务 | > 1天 | Warning |

---

## 九、缓存与制品管理最佳实践

### 9.1 Maven 依赖缓存

```yaml
cache:
  key: ${CI_COMMIT_REF_SLUG}
  paths:
    - .m2/repository/
  policy: pull-push  # 首次 Job push，后续 Job pull

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository -Dmaven.artifact.threads=4"
  MAVEN_CLI_OPTS: "--batch-mode --errors --fail-at-end --show-version"
```

### 9.2 制品生命周期管理

```yaml
# 不同制品设置不同的保留策略
maven-build:
  artifacts:
    paths:
      - target/*.jar
    expire_in: 1 day     # 临时构建产物过期时间短

release-package:
  stage: release
  artifacts:
    paths:
      - target/*.jar
    expire_in: never     # 正式发布产物永久保留
```

**最佳实践：**
- 临时构建产物：保留 1-2 小时
- 测试报告：保留 7 天
- 发布包：永久保留

---

## 十、实际案例：Java Spring Boot 项目完整 CI/CD 流水线

### 10.1 完整 .gitlab-ci.yml

```yaml
image: maven:3.9-eclipse-temurin-17

stages:
  - validate
  - test
  - build
  - docker
  - deploy-dev
  - deploy-prod

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository -Dfile.encoding=UTF-8"
  MAVEN_CLI_OPTS: "--batch-mode --errors --fail-at-end"
  DOCKER_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  NAMESPACE_DEV: dev
  NAMESPACE_PROD: prod

cache:
  key: ${CI_COMMIT_REF_SLUG}
  paths:
    - .m2/repository/
  policy: pull-push

# ========== Stage 1: Validate ==========
code-style-check:
  stage: validate
  script:
    - mvn $MAVEN_CLI_OPTS checkstyle:check
  allow_failure: true   # 代码风格问题不阻断

# ========== Stage 2: Test ==========
unit-test:
  stage: test
  script:
    - mvn $MAVEN_CLI_OPTS test
  artifacts:
    reports:
      junit:
        - target/surefire-reports/TEST-*.xml
        - target/failsafe-reports/TEST-*.xml
    when: always

integration-test:
  stage: test
  script:
    - mvn $MAVEN_CLI_OPTS verify -P integration-test
  services:
    - name: mysql:8.0
      alias: mysql
    - name: redis:7-alpine
      alias: redis
  variables:
    SPRING_DATASOURCE_URL: jdbc:mysql://mysql:3306/testdb
    SPRING_REDIS_HOST: redis

sonar-analysis:
  stage: test
  image: sonarsource/sonar-scanner-cli:5
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: 0
  script:
    - sonar-scanner
      -Dsonar.projectKey=${CI_PROJECT_ID}
      -Dsonar.sources=src
      -Dsonar.java.binaries=target/classes
      -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
      -Dsonar.host.url=${SONAR_HOST_URL}
      -Dsonar.login=${SONAR_TOKEN}
  cache:
    key: "${CI_JOB_NAME}"
    paths:
      - .sonar/cache
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop" || $CI_COMMIT_BRANCH == "main"'

# ========== Stage 3: Build ==========
maven-package:
  stage: build
  script:
    - mvn $MAVEN_CLI_OPTS package -DskipTests
  artifacts:
    paths:
      - target/*.jar
    expire_in: 2 hours

# ========== Stage 4: Docker Build ==========
docker-build:
  stage: docker
  image: docker:24.0-cli
  services:
    - docker:24.0-dind
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build -t $DOCKER_IMAGE .
    - docker tag $DOCKER_IMAGE $CI_REGISTRY_IMAGE:latest
    - docker push $DOCKER_IMAGE
    - docker push $CI_REGISTRY_IMAGE:latest
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop" || $CI_COMMIT_BRANCH == "main"'
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'

# ========== Stage 5: Deploy ==========
.deploy:
  image: bitnami/kubectl:latest
  script:
    - kubectl config use-context $KUBE_CONTEXT
    - sed -i "s|__IMAGE_TAG__|${CI_COMMIT_SHORT_SHA}|g" k8s/deployment.yaml
    - kubectl apply -f k8s/deployment.yaml -n $NAMESPACE
    - kubectl rollout status deployment/spring-boot-app -n $NAMESPACE --timeout=5m
    - kubectl get pods -n $NAMESPACE -l app=spring-boot-app

deploy-dev:
  extends: .deploy
  stage: deploy-dev
  variables:
    KUBE_CONTEXT: dev-cluster
    NAMESPACE: ${NAMESPACE_DEV}
  environment:
    name: dev
    url: https://dev.example.com
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'

deploy-prod:
  extends: .deploy
  stage: deploy-prod
  variables:
    KUBE_CONTEXT: prod-cluster
    NAMESPACE: ${NAMESPACE_PROD}
  environment:
    name: production
    url: https://example.com
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  when: manual
```

### 10.2 Dockerfile

```dockerfile
# Dockerfile
FROM eclipse-temurin:17-jre-alpine AS base
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn package -DskipTests -q

FROM base AS final
COPY --from=build /build/target/*.jar app.jar
RUN chown -R appuser:appgroup /app
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

## 十一、常见问题排查与优化

### 11.1 常见问题排查

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| Runner 离线 | Runner 进程挂了或网络不通 | `gitlab-runner verify` 检查状态；重启 Runner 服务 |
| Job 卡住 | 没有可用 Runner | 检查 Runner 并发数、Tag 匹配 |
| DIND 构建失败 | Docker 守护进程未就绪 | 增加 `--wait` 或重试策略 |
| Maven 构建慢 | 依赖下载缓慢 | 配置 Maven 镜像（阿里云/华为云）、优化缓存策略 |
| Kubernetes 部署失败 | kubeconfig 过期或权限不足 | 检查证书有效期，使用 Service Account |
| 缓存不命中 | cache key 不合理 | 使用 `${CI_COMMIT_REF_SLUG}` 按分支缓存 |
| Artifact 过大 | 构建产物包含无用文件 | 精确指定 artifacts.paths，使用 expire_in |

### 11.2 性能优化

```yaml
# 优化后的缓存策略（按分支 + 按 Job 类型分层）
cache:
  - key: ${CI_COMMIT_REF_SLUG}
    paths:
      - .m2/repository/
    policy: pull-push
  - key: ${CI_JOB_NAME}-${CI_COMMIT_REF_SLUG}
    paths:
      - .sonar/cache/
    policy: pull-push

# 使用轻量基础镜像
default:
  image: maven:3.9-eclipse-temurin-17-alpine   # Alpine 版本更小

# 合理设置超时和重试
test:
  timeout: 15 minutes
  retry:
    max: 1
    when:
      - runner_system_failure
```

---

## 十二、总结

GitLab CI/CD 提供了一套完整、强大的 CI/CD 解决方案。通过本文介绍的最佳实践，你可以：

1. **搭建高效的流水线** — 合理利用 parallel、needs 等高级特性
2. **保障安全性** — 使用 Protected 变量、CI_JOB_TOKEN 和 RBAC
3. **提升构建效率** — 优化缓存策略、选择合适执行器
4. **实现多环境部署** — 通过 rules + environment 自动化部署流程
5. **集成质量保障** — 嵌入 SonarQube 代码扫描和单元测试

**关键建议：** 从小做起，从简单的流水线开始，逐步引入高级特性。持续改进流水线本身，就像改进应用代码一样。
