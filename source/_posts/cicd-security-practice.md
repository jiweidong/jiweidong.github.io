---
title: CI/CD 流水线安全实践：SAST/DAST 集成与供应链安全
date: 2026-06-19 09:30:00
tags:
  - CI/CD
  - 安全
  - SAST
  - DevSecOps
categories:
  - DevOps
author: 东哥
---

## 引言

2024 年，Log4j 漏洞影响全球数百万应用；SolarWinds 供应链攻击导致美国政府多个部门数据泄露。这些事件反复提醒我们：**安全不再是"上线前扫一轮"的事，它必须嵌入到 CI/CD 流水线中**。DevSecOps 的核心思想是"安全左移"（Shift Left），即在软件开发的最早期引入安全措施，而非在交付前做"亡羊补牢"式的安全检查。本文将完整介绍一套可落地的 DevSecOps 流水线，涵盖 SAST、DAST、SCA、密钥检测、镜像签名和准入控制。

## 一、DevSecOps 核心理念与"安全左移"

### 1.1 从"安全门"到"安全流水线"

传统安全模式：

```
需求 → 开发 → 测试 → 安全扫描 → 部署上线
                        ↑
                    最后一步做安全检查，发现问题 → 返工 → 延期
```

DevSecOps 安全模式：

```
需求 → (安全评审) → 开发(SAST+密钥检测) → 构建(SCA+镜像扫描) 
    → 测试(DAST) → 部署(签名验证+准入控制) → 运行(持续监控)
        ↑                                        ↑
    每个阶段都有安全卡口                    运行时安全
```

### 1.2 安全左移的价值

| 安全类型 | 发现阶段 | 修复成本 |
|---------|---------|---------|
| SAST 发现 SQL 注入 | 编码阶段 | 1小时 |
| SCA 发现 Log4j 依赖 | CI 构建 | 1小时 |
| DAST 发现 XSS 漏洞 | 测试阶段 | 1天 |
| 渗透测试发现认证绕过 | 预发布 | 1周 |
| 生产环境数据泄露 | 运行阶段 | 百万级损失 |

数据说明：**在编码阶段发现并修复一个漏洞的代价，是生产环境修复的 1/100**。

## 二、SAST 静态扫描集成

### 2.1 SonarQube 配置与规则定制

SonarQube 是目前最主流的代码质量平台，通过检测代码"异味"和已知安全漏洞模式实现 SAST。

**Docker 快速部署：**

```bash
# 启动 SonarQube 服务
docker run -d --name sonarqube \
  -p 9000:9000 \
  -e SONAR_JDBC_URL=jdbc:postgresql://postgres:5432/sonar \
  -e SONAR_JDBC_USERNAME=sonar \
  -e SONAR_JDBC_PASSWORD=sonar \
  sonarqube:community-10.6.0

# 安装中文插件（可选）
# 管理 → 应用市场 → 搜索 Chinese Pack → 安装
```

**Maven 项目集成：**

```xml
<!-- pom.xml -->
<properties>
    <sonar.projectKey>my-java-app</sonar.projectKey>
    <sonar.host.url>https://sonarqube.mycompany.com</sonar.host.url>
    <sonar.login>sqa_xxxxxxxxxxxx</sonar.login>
</properties>

<!-- 执行扫描 -->
<!-- mvn clean verify sonar:sonar -->
```

**自定义安全规则**（Java 示例）：

```java
// 创建自定义规则：禁止使用过时的 MD5 进行密码存储

// SonarQube 规则模板（Java Security 类别）：
// Rule ID: java:S9999
// Rule Name: "MD5 should not be used for password hashing"
// Description: "MD5 is considered cryptographically broken. 
//               Use bcrypt, scrypt, or Argon2 instead."

// 检测的代码模式：
public class PasswordService {
    public String hashPassword(String password) {
        // ❌ 违规：使用 MessageDigest 的 MD5
        MessageDigest md = MessageDigest.getInstance("MD5");  // 告警
        byte[] hash = md.digest(password.getBytes());
        return bytesToHex(hash);
    }
}

// 推荐的修复方案：
public class PasswordService {
    public String hashPassword(String password) {
        // ✅ 正确：使用 bcrypt
        return BCrypt.hashpw(password, BCrypt.gensalt(12));
    }
}
```

### 2.2 Semgrep 自定义规则

Semgrep 是近年来快速崛起的轻量级 SAST 工具，支持自定义规则，语法类似代码本身：

```yaml
# semgrep-rules/java-security.yaml
rules:
  - id: no-unsafe-deserialization
    patterns:
      - pattern: |
          ObjectInputStream $IN = new ObjectInputStream(...);
          ...
          $IN.readObject();
    message: "不安全的 Java 反序列化，可能导致 RCE"
    severity: ERROR
    languages: [java]
    metadata:
      cwe: "CWE-502"
      owasp: "A8:2021 - Software and Data Integrity Failures"
      
  - id: no-hardcoded-jwt-secret
    patterns:
      - pattern-either:
          - pattern: 'String secret = "..."'  # 硬编码密钥
          - pattern: 'byte[] secret = "..."'
    pattern-not: 'String secret = System.getenv("JWT_SECRET")'
    message: "JWT 密钥不应硬编码，应从环境变量读取"
    severity: WARNING
    languages: [java]
    
  - id: sql-injection-mybatis-dynamic
    patterns:
      - pattern: |
          @Select("<... $SINK ...>")
      - metavariable-regex:
          metavariable: $SINK
          regex: '.*\$\{.*\}.*'  # ${} 注入风险
    message: "MyBatis 动态 SQL 注入风险，应使用 #{} 参数化查询"
    severity: ERROR
    languages: [java]
```

运行 Semgrep：

```bash
# 安装
pip install semgrep

# 运行自定义规则
semgrep --config=semgrep-rules/java-security.yaml \
        --json-output=report.json \
        --error \
        ./src

# 使用内置规则集
semgrep --config=p/java \
        --config=p/owasp-top-ten \
        ./src
```

### 2.3 Java 代码安全审查工具链

| 工具 | 定位 | 特点 | 检测重点 |
|------|------|------|---------|
| **Checkstyle** | 代码风格 | 强制定制化风格 | 命名规范、Javadoc、文件头 |
| **PMD** | 代码缺陷 | 分析代码异味 | 空循环、未使用变量、过度复杂 |
| **SpotBugs (FindBugs)** | 字节码分析 | 编译后分析字节码 | 空指针、SQL 注入、死锁 |
| **SonarQube** | 综合平台 | 聚合多种分析器 | 综合质量 + 安全 |

```xml
<!-- Maven 集成全部工具 -->
<build>
    <plugins>
        <!-- Checkstyle -->
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-checkstyle-plugin</artifactId>
            <configuration>
                <configLocation>checkstyle.xml</configLocation>
                <failOnViolation>true</failOnViolation>
                <violationSeverity>warning</violationSeverity>
            </configuration>
        </plugin>
        
        <!-- SpotBugs -->
        <plugin>
            <groupId>com.github.spotbugs</groupId>
            <artifactId>spotbugs-maven-plugin</artifactId>
            <configuration>
                <effort>Max</effort>
                <threshold>Low</threshold>
                <failOnError>true</failOnError>
                <includeFilterFile>spotbugs-security.xml</includeFilterFile>
            </configuration>
        </plugin>
        
        <!-- PMD -->
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-pmd-plugin</artifactId>
            <configuration>
                <rulesets>
                    <ruleset>rulesets/java/quickstart.xml</ruleset>
                    <ruleset>rulesets/java/security.xml</ruleset>
                </rulesets>
                <failOnViolation>true</failOnViolation>
            </configuration>
        </plugin>
    </plugins>
</build>
```

### 2.4 GitHub CodeQL 集成

```yaml
# .github/workflows/codeql-analysis.yml
name: "CodeQL Security Scan"
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  analyze:
    name: CodeQL Analysis
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      actions: read
      contents: read
      
    strategy:
      fail-fast: false
      matrix:
        language: ['java', 'javascript']
        
    steps:
    - name: Checkout
      uses: actions/checkout@v4
      
    - name: Initialize CodeQL
      uses: github/codeql-action/init@v3
      with:
        languages: ${{ matrix.language }}
        queries: security-and-quality
        config-file: .github/codeql/codeql-config.yml
        
    - name: Build Java
      if: matrix.language == 'java'
      run: mvn clean package -DskipTests
      
    - name: Perform CodeQL Analysis
      uses: github/codeql-action/analyze@v3
```

## 三、DAST 动态扫描

### 3.1 OWASP ZAP 配置与 API 扫描

SAST 扫描源码，DAST 扫描运行中的应用，两者互补。

**容器化 ZAP 集成到 CI：**

```bash
# ZAP 全量扫描（API 模式）
docker run --rm \
  -v $(pwd)/zap-reports:/zap/reports \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-api-scan.py \
  -t https://staging.myapp.com/v3/api-docs \
  -f openapi \
  -c zap-config.conf \
  -r /zap/reports/zap-report.html \
  -x /zap/reports/zap-report.xml
```

**ZAP 配置示例 `zap-config.conf`：**

```ini
# 基准扫描上下文
context_name=MyAppCTX
context_in_scope=true
context_reg_ex=^https://staging\.myapp\.com.*

# 排除安全的 URL 路径
exclude=^https://staging\.myapp\.com/health$
exclude=^https://staging\.myapp\.com/metrics$
exclude=^https://staging\.myapp\.com/actuator*

# 认证配置（基于 Token）
authentication_form_method=POST
authentication_form_login_url=https://staging.myapp.com/api/login
authentication_form_username_field=username
authentication_form_password_field=password
```

### 3.2 流水线自动阻断

在 CI/CD pipeline 中，ZAP 报告的漏洞等级达到 CRITICAL 或 HIGH 时应自动阻断：

```bash
#!/bin/bash
# zap-gate.sh - 检查 ZAP 报告并决定是否阻断

ZAP_REPORT="zap-reports/zap-report.xml"

# 解析 XML 报告中的告警等级
CRITICAL=$(grep -c 'alert="High"' $ZAP_REPORT)
HIGH=$(grep -c 'alert="Medium"' $ZAP_REPORT)

echo "DAST 扫描结果:"
echo "  严重漏洞: $CRITICAL"
echo "  高危漏洞: $HIGH"

if [ "$CRITICAL" -gt 0 ]; then
    echo "❌ 发现严重漏洞，阻断流水线！"
    exit 1
elif [ "$HIGH" -gt 5 ]; then
    echo "❌ 高危漏洞超过阈值(5)，阻断流水线！"
    exit 1
else
    echo "✅ DAST 扫描通过"
    exit 0
fi
```

## 四、软件供应链安全

### 4.1 SBOM 生成（CycloneDX / SPDX）

SBOM（Software Bill of Materials，软件物料清单）记录了一个应用的所有依赖组件信息。

```xml
<!-- Maven 生成 CycloneDX SBOM -->
<plugin>
    <groupId>org.cyclonedx</groupId>
    <artifactId>cyclonedx-maven-plugin</artifactId>
    <version>2.8.0</version>
    <executions>
        <execution>
            <phase>package</phase>
            <goals>
                <goal>makeAggregateBom</goal>
            </goals>
        </execution>
    </executions>
    <configuration>
        <projectType>application</projectType>
        <schemaVersion>1.5</schemaVersion>
        <includeBomSerialNumber>true</includeBomSerialNumber>
        <includeCompileScope>true</includeCompileScope>
        <includeProvidedScope>true</includeProvidedScope>
        <includeRuntimeScope>true</includeRuntimeScope>
        <includeSystemScope>false</includeSystemScope>
        <includeTestScope>false</includeTestScope>
        <outputFormat>json</outputFormat>
    </configuration>
</plugin>
```

**生成的 SBOM 示例（片段）：**

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:3e671687-395b-41f5-a30f-a58921a69b79",
  "version": 1,
  "metadata": {
    "component": {
      "name": "my-payment-app",
      "version": "1.2.0-SNAPSHOT",
      "type": "application"
    }
  },
  "components": [
    {
      "type": "library",
      "name": "log4j-core",
      "version": "2.17.1",
      "purl": "pkg:maven/org.apache.logging.log4j/log4j-core@2.17.1",
      "licenses": [{"license": {"id": "Apache-2.0"}}]
    },
    {
      "type": "library",
      "name": "commons-compress",
      "version": "1.21",
      "purl": "pkg:maven/org.apache.commons/commons-compress@1.21",
      "licenses": [{"license": {"id": "Apache-2.0"}}]
    }
  ],
  "dependencies": [...]
}
```

SBOM 的意义在于：当新的 CVE 公布时，可以快速检索哪些应用受影响。

### 4.2 Docker 镜像扫描（Trivy / Grype）

```bash
# Trivy 扫描镜像
# 安装
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity CRITICAL,HIGH \
  --format json --output trivy-report.json \
  myapp:latest

# 或直接使用 CLI
trivy image --severity CRITICAL,HIGH --exit-code 1 myapp:latest
```

```bash
# Grype（Anchore 出品）
grype myapp:latest --only-fixed --fail-on high
```

**扫描结果对比：**

| 特性 | Trivy | Grype |
|------|-------|-------|
| **漏洞数据库** | NVD + GitHub + RedHat + Alpine | NVD + RedHat + Ubuntu + Alpine |
| **性能** | 快（多线程扫描） | 中等 |
| **SBOM 支持** | CycloneDX + SPDX | CycloneDX + SPDX |
| **Config 扫描** | ✅（Misconfig 规则） | ❌ |
| **Secret 扫描** | ✅ | ⭐（需额外插件） |
| **导出格式** | JSON / SARIF / HTML | JSON / SARIF / template |

### 4.3 依赖漏洞检查（OWASP Dependency-Check）

```xml
<!-- Maven 插件 -->
<plugin>
    <groupId>org.owasp</groupId>
    <artifactId>dependency-check-maven</artifactId>
    <version>10.0.4</version>
    <configuration>
        <failBuildOnCVSS>7</failBuildOnCVSS>    <!-- CVSS ≥7 时构建失败 -->
        <formats>
            <format>HTML</format>
            <format>JSON</format>
        </formats>
        <nvdApiKey>${NVD_API_KEY}</nvdApiKey>
        <suppressionFiles>
            <suppressionFile>dependency-suppression.xml</suppressionFile>
        </suppressionFiles>
    </configuration>
    <executions>
        <execution>
            <goals>
                <goal>check</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

**npm/pip 安全审计：**

```bash
# npm 审计
npm audit --audit-level=high

# pip 审计（使用 pip-audit）
pip install pip-audit
pip-audit --desc -r requirements.txt 2>&1 | tee pip-audit.log
```

### 4.4 密钥泄露检测

**GitLeaks：**
```bash
# 安装
wget https://github.com/gitleaks/gitleaks/releases/download/v8.18.0/gitleaks_8.18.0_linux_x64.tar.gz
tar xzf gitleaks_8.18.0_linux_x64.tar.gz

# 扫描代码库
./gitleaks detect -s . -v

# 自定义规则
cat > .gitleaks.toml << 'EOF'
title = "MyApp Security Rules"
[[rules]]
description = "GitHub Token"
regex = '''ghp_[0-9a-zA-Z]{36}'''
tags = ["github", "token"]
[[rules]]
description = "AWS Access Key"
regex = '''AKIA[0-9A-Z]{16}'''
tags = ["aws"]
EOF
```

**TruffleHog：**
```bash
# 安装
pip install truffleHog

# 扫描 Git 历史
trufflehog --regex --entropy=True https://github.com/org/my-repo.git

# 扫描目录
trufflehog filesystem --directory=./ 
```

## 五、容器镜像签名

### 5.1 Cosign 签名与验证

使用 Sigstore 生态的 Cosign 对容器镜像进行签名和验证：

```bash
# 生成密钥对
cosign generate-key-pair

# 对镜像签名
cosign sign --key cosign.key \
  registry.mycompany.com/myapp:latest

# 验证镜像签名（在生产部署前执行）
cosign verify --key cosign.pub \
  registry.mycompany.com/myapp:latest
```

### 5.2 与 Notary 集成

```yaml
# 在 Kubernetes 中强制使用签名验证
# 安装 cosign policy agent
kubectl apply -f https://raw.githubusercontent.com/sigstore/cosign/main/examples/k8s/webhook/deployment.yaml

# 创建准入策略
cat <<EOF | kubectl apply -f -
apiVersion: cosign.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: enforce-signed-images
spec:
  images:
    - glob: "registry.mycompany.com/*"
  authorities:
    - key:
        data: |
          -----BEGIN PUBLIC KEY-----
          ...（cosign.pub 内容）
          -----END PUBLIC KEY-----
EOF
```

## 六、完整 GitHub Actions DevSecOps 流水线

```yaml
name: DevSecOps Pipeline
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  # ===== 阶段 1：SAST + 密钥检测 + 依赖检查 =====
  security-scan:
    name: Security Analysis
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0

    # 1.1 密钥泄露检测
    - name: Secret Scanning (Gitleaks)
      uses: gitleaks/gitleaks-action@v2
      continue-on-error: false

    # 1.2 SAST - Semgrep
    - name: SAST - Semgrep
      uses: returntocorp/semgrep-action@v2
      with:
        config: >-
          p/java
          p/owasp-top-ten
          r/semgrep-rules/java-security.yaml
        publishToken: ${{ secrets.SEMGREP_APP_TOKEN }}
      continue-on-error: false

    # 1.3 SCA - OWASP Dependency-Check
    - name: SCA - Dependency Check
      run: |
        mvn dependency-check:check
      env:
        NVD_API_KEY: ${{ secrets.NVD_API_KEY }}
      continue-on-error: false

    # 1.4 SAST - SonarQube
    - name: SAST - SonarQube
      uses: sonarsource/sonarqube-quality-gate-action@v1.1.1
      env:
        SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
        SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}

  # ===== 阶段 2：构建 + SBOM + 镜像扫描 + 签名 =====
  build-and-sign:
    name: Build and Sign
    needs: security-scan
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Set up JDK 21
      uses: actions/setup-java@v4
      with:
        distribution: 'temurin'
        java-version: '21'

    - name: Build Application
      run: mvn clean package -DskipTests

    - name: Generate SBOM (CycloneDX)
      run: |
        mvn org.cyclonedx:cyclonedx-maven-plugin:makeAggregateBom
        cat target/classes/META-INF/sbom.json

    - name: Build Docker Image
      run: docker build -t registry.mycompany.com/myapp:${{ github.sha }} .

    - name: Docker Image Scan (Trivy)
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: registry.mycompany.com/myapp:${{ github.sha }}
        format: "sarif"
        output: "trivy-results.sarif"
        severity: "CRITICAL,HIGH"
        exit-code: 1

    - name: Cosign Image Signature
      run: |
        cosign sign --key env://COSIGN_PRIVATE_KEY \
          registry.mycompany.com/myapp:${{ github.sha }}
      env:
        COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
        COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}

    - name: Push Image
      run: docker push registry.mycompany.com/myapp:${{ github.sha }}

  # ===== 阶段 3：部署 + DAST =====
  deploy-and-dast:
    name: Deploy & DAST
    needs: build-and-sign
    runs-on: ubuntu-latest
    environment: staging
    steps:
    - name: Deploy to Staging
      run: |
        kubectl set image deployment/myapp \
          myapp=registry.mycompany.com/myapp:${{ github.sha }}
        kubectl rollout status deployment/myapp --timeout=300s

    # 等待服务就绪
    - name: Health Check
      run: |
        for i in {1..30}; do
          STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://staging.myapp.com/health)
          if [ "$STATUS" == "200" ]; then
            echo "✅ Service is healthy"
            exit 0
          fi
          sleep 5
        done
        echo "❌ Service failed to start"
        exit 1

    - name: DAST - OWASP ZAP
      uses: zaproxy/action-full-scan@v0.11.0
      with:
        target: "https://staging.myapp.com"
        rules_file_name: "zap-config.conf"
        allow_issue_writing: true
        artifact_name: "zap-report"

  # ===== 阶段 4：生产部署（手动审批） =====
  deploy-production:
    name: Deploy to Production
    needs: deploy-and-dast
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://myapp.com
    steps:
    - name: Verify Image Signature
      run: |
        cosign verify --key cosign.pub \
          registry.mycompany.com/myapp:${{ github.sha }}

    - name: Deploy to Production
      run: |
        # 渐进式部署（Canary）
        kubectl set image deployment/myapp-prod \
          myapp=registry.mycompany.com/myapp:${{ github.sha }} \
          --record
        kubectl rollout status deployment/myapp-prod --timeout=600s
```

## 七、流水线安全策略总结

| 安全策略 | 实现方式 | 价值 |
|---------|---------|------|
| **准入控制门禁** | CodeQL / Semgrep 阻断 + SonarQube Quality Gate | 防止包含漏洞的代码进入主分支 |
| **审批机制** | GitHub Environments + Required Reviewers | 生产部署必须有安全负责人审批 |
| **最小凭证原则** | OIDC Workload Identity / Secretless CI | 避免静态 CI 密钥泄露 |
| **镜像不可变** | 每次构建生成新版本标签 + 签名 | 防止镜像被篡改 |
| **依赖锁定** | package-lock.json / pom.xml.lock | 防止依赖混淆攻击 |

## 八、总结

DevSecOps 不是一次性配置，而是一套持续演进的安全文化。本文从 SAST、DAST、SCA 到镜像签名，构筑了完整的流水线安全防线。值得记住的几个原则：

1. **安全左移**：越早发现、成本越低
2. **自动化阻断**：人工依赖不可靠，让流水线替你做安全审查
3. **分层防御**：SAST 防源码漏洞、SCA 防依赖漏洞、DAST 防运行时漏洞、签名防镜像篡改
4. **持续改进**：定期更新规则库、漏洞数据库，追踪新出现的攻击手法

完整的 DevSecOps 实践需要一个过程的沉淀，但一旦建立起来，它将从"拖慢开发速度的瓶颈"转变为"让团队安心的基础设施"。
