---
title: GitHub Actions CI/CD 实战：从入门到生产级流水线
date: 2026-06-17 13:30:00
tags:
  - GitHub Actions
  - CI/CD
  - DevOps
  - 自动化
categories:
  - DevOps
author: 东哥
---

# GitHub Actions CI/CD 实战：从入门到生产级流水线

## 一、GitHub Actions 核心概念

GitHub Actions 是 GitHub 原生的 CI/CD 工具，让代码托管和自动化流水线无缝集成。与其他 CI/CD 工具相比，它的最大优势是**与 GitHub 仓库的深度集成**。

### 1.1 核心组件

| 组件 | 说明 | 类比 |
|------|------|------|
| Workflow | 工作流（.yml 文件） | Jenkins Pipeline |
| Job | 工作单元，可并行/串行 | Jenkins Stage |
| Step | 执行步骤 | 单条命令 |
| Action | 可复用的任务模块 | 插件/插件 |
| Runner | 执行环境 | Jenkins Agent |
| Event | 触发条件 | Webhook |

### 1.2 工作流文件结构

```yaml
name: CI/CD Pipeline              # 工作流名称

on:                               # 触发事件
  push:
    branches: [main, develop]     # 分支过滤
  pull_request:
    branches: [main]
  workflow_dispatch:              # 手动触发

env:                              # 全局环境变量
  JAVA_VERSION: '17'
  REGISTRY: ghcr.io

jobs:                             # 工作单元
  build:
    runs-on: ubuntu-latest        # 运行环境
    timeout-minutes: 30           # 超时时间
    
    services:                     # 辅助服务
      mysql:
        image: mysql:8.0
        env:
          MYSQL_ROOT_PASSWORD: test
        options: >-
          --health-cmd "mysqladmin ping -h localhost"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
      redis:
        image: redis:7-alpine
    
    steps:                        # 执行步骤
      - uses: actions/checkout@v4
      
      - name: Setup JDK
        uses: actions/setup-java@v4
        with:
          java-version: ${{ env.JAVA_VERSION }}
          distribution: 'temurin'
          cache: maven
      
      - name: Build & Test
        run: mvn clean verify -B
      
      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: app-jar
          path: target/*.jar
```

## 二、CI 流水线实战

### 2.1 Java 项目 CI 流水线

```yaml
name: Java CI

on:
  push:
    branches: [develop, feature/**]
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven
      
      - name: Checkstyle
        run: mvn checkstyle:check -B
      
      - name: SpotBugs
        run: mvn spotbugs:check -B
      
      - name: Dependency Check
        run: mvn dependency-check:check -B

  test:
    needs: lint
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: test
          POSTGRES_DB: testdb
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven
      
      - name: Unit Tests
        run: mvn test -B
        
      - name: Integration Tests
        run: mvn verify -Pintegration-test -B
        env:
          SPRING_DATASOURCE_URL: jdbc:postgresql://localhost:5432/testdb
      
      - name: Publish Test Report
        if: always()
        uses: dorny/test-reporter@v1
        with:
          name: Test Results
          path: '**/target/surefire-reports/*.xml'
          reporter: java-junit
      
      - name: JaCoCo Coverage
        uses: codecov/codecov-action@v3
        with:
          files: target/site/jacoco/jacoco.xml
      
      - name: SonarQube Analysis
        uses: sonarsource/sonarqube-scan-action@v1
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}

  build:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven
      
      - name: Build Package
        run: mvn package -DskipTests -B
        
      - name: Build Docker Image
        run: |
          docker build -t ${{ env.REGISTRY }}/${{ github.repository }}:${{ github.sha }} .
          docker tag ${{ env.REGISTRY }}/${{ github.repository }}:${{ github.sha }} \
            ${{ env.REGISTRY }}/${{ github.repository }}:latest
      
      - name: Push to Registry
        run: |
          echo ${{ secrets.GITHUB_TOKEN }} | docker login ghcr.io -u ${{ github.actor }} --password-stdin
          docker push ${{ env.REGISTRY }}/${{ github.repository }}:${{ github.sha }}
          docker push ${{ env.REGISTRY }}/${{ github.repository }}:latest
      
      - name: Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          path: ./target/*.jar
```

## 三、CD 流水线实战

### 3.1 多环境部署

```yaml
name: Deploy

on:
  workflow_run:
    workflows: ["Java CI"]
    branches: [main]
    types:
      - completed

jobs:
  deploy-staging:
    name: Deploy to Staging
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    environment:
      name: staging
      url: https://staging.example.com
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-1
      
      - name: Update ECS Service
        run: |
          aws ecs update-service \
            --cluster staging-cluster \
            --service order-service \
            --force-new-deployment \
            --region ap-northeast-1
      
      - name: Health Check
        run: |
          for i in {1..30}; do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
              https://staging.example.com/actuator/health)
            if [ "$STATUS" = "200" ]; then
              echo "Deploy success!"
              exit 0
            fi
            sleep 10
          done
          echo "Health check failed"
          exit 1
      
      - name: Run Smoke Tests
        run: |
          curl -f https://staging.example.com/api/orders/health
          curl -f https://staging.example.com/api/products/1

  deploy-production:
    name: Deploy to Production
    if: github.ref == 'refs/heads/main'
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://app.example.com
    
    # 人工审批
    # 在 GitHub 页面 -> Environments -> production -> Required reviewers
    # 设置审批人
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Blue-Green Deploy
        run: |
          # 假设 K8s 环境
          kubectl set image deployment/order-service \
            order-service=${{ env.REGISTRY }}/${{ github.repository }}:${{ github.sha }} \
            --record
          
          # 检查 rollout 状态
          kubectl rollout status deployment/order-service --timeout=5m
      
      - name: Canary Verification
        run: |
          # 验证金丝雀版本
          CANARY_STATUS=$(curl -s https://api.example.com/actuator/health \
            -H "X-Canary: true")
          echo $CANARY_STATUS | jq '.status == "UP"'
      
      - name: Notify
        uses: slackapi/slack-github-action@v1
        with:
          payload: |
            {
              "text": "✅ 生产环境部署成功: ${{ github.repository }}@${{ github.sha }}",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "✅ *生产环境部署完成*\n仓库: ${{ github.repository }}\n版本: ${{ github.sha }}\n部署人: ${{ github.actor }}"
                  }
                }
              ]
            }
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

## 四、高级技巧与最佳实践

### 4.1 Matrix 构建

```yaml
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
        java: [17, 21]
        spring-boot: [3.0.x, 3.1.x, 3.2.x]
      fail-fast: false           # 一个失败不影响其他
    
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: ${{ matrix.java }}
      
      - name: Test with Spring Boot ${{ matrix.spring-boot }}
        run: mvn test -Dspring-boot.version=${{ matrix.spring-boot }}
```

### 4.2 缓存策略

```yaml
- name: Cache Maven Dependencies
  uses: actions/cache@v4
  with:
    path: |
      ~/.m2/repository
      !~/.m2/repository/com/example
    key: ${{ runner.os }}-maven-${{ hashFiles('**/pom.xml') }}
    restore-keys: |
      ${{ runner.os }}-maven-

- name: Cache Maven Wrapper
  uses: actions/cache@v4
  with:
    path: .mvn/wrapper
    key: ${{ runner.os }}-mvn-wrapper-${{ hashFiles('.mvn/wrapper/maven-wrapper.properties') }}
```

### 4.3 安全扫描

```yaml
- name: Secret Scanning
  uses: trufflesecurity/trufflehog@v3
  with:
    path: ./
    base: ${{ github.event.before }}
    head: ${{ github.sha }}

- name: Docker Image Scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.REGISTRY }}/${{ github.repository }}:${{ github.sha }}
    format: 'sarif'
    output: 'trivy-results.sarif'
    severity: 'CRITICAL,HIGH'

- name: Upload Trivy Results
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: 'trivy-results.sarif'
```

## 五、GitHub Actions vs 其他 CI/CD

| 特性 | GitHub Actions | Jenkins | GitLab CI | CircleCI |
|------|---------------|---------|-----------|----------|
| 托管方式 | 云原生 + 自托管 | 自托管 | 云 + 自托管 | 云 + 自托管 |
| 配置方式 | YAML | Groovy/UI | YAML | YAML |
| Marketplace | 丰富 (20k+) | 丰富 | 有限 | 有限 |
| 免费额度 | 2000 min/月 | 无 | 400 min/月 | 6000 min/月 |
| Linux/Mac/Windows | 全部支持 | 全部支持 | Linux为主 | 全部支持 |
| 缓存 | 手动配置 | 配置复杂 | 自动缓存 | 自动缓存 |

### 5.1 什么时候用自托管 Runner

```yaml
# 自托管 Runner
jobs:
  deploy:
    runs-on: [self-hosted, linux, x64, gpu]
    
    # 或使用标签
    # runs-on: self-hosted
    
    steps:
      - name: Check Runner
        run: |
          echo "Hostname: $(hostname)"
          echo "CPU: $(nproc)"
          echo "Memory: $(free -h | grep Mem)"
```

需要自托管 Runner 的场景：
- 需要访问内网资源（数据库、K8s 集群）
- 需要 GPU 或特定硬件
- Maven/NPM 缓存放在内网
- 免费额度不够用

## 六、生产级流水线模板

### 6.1 可复用的 Workflow

```yaml
# .github/workflows/deploy.yml
name: Build & Deploy

on:
  push:
    branches: [main, develop]
    paths-ignore:
      - 'README.md'
      - 'docs/**'
      - '*.md'

jobs:
  quality:
    uses: ./.github/workflows/quality-check.yml
    secrets: inherit

  deploy:
    needs: quality
    uses: ./.github/workflows/deploy-template.yml
    with:
      environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'staging' }}
      image-tag: ${{ github.sha }}
    secrets: inherit
```

### 6.2 推荐目录结构

```
.github/
  workflows/
    ci.yml              # CI 流水线
    cd.yml              # CD 流水线
    codeql.yml          # 代码安全扫描
    release.yml         # 版本发布
    renovate.yml        # 依赖更新

  actions/
    build-java/         # 自定义 Action
      action.yml
    deploy-k8s/
      action.yml
```

GitHub Actions 让 CI/CD 真正变成了"配置即代码"，它与 GitHub 生态的无缝集成，使得代码提交、构建、测试、部署可以在一个平台上完成闭环。对于中小团队来说，它是目前最简单高效的 CI/CD 方案。
