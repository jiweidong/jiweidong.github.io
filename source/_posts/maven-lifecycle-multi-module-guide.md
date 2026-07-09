---
title: 【工程实战】Maven 生命周期与多模块项目构建实战：从 POM 到 CI/CD 全解析
date: 2026-07-09 08:00:00
tags:
  - Maven
  - 构建工具
  - 项目管理
  - 多模块
  - 面试
categories:
  - Java
  - 工程实践
author: 东哥
---

# 【工程实战】Maven 生命周期与多模块项目构建实战

## 一、Maven 三套生命周期

很多 Java 开发天天用 `mvn clean install`，但不知道它到底干了什么。Maven 有三套相互独立的生命周期：

| 生命周期 | 用途 | 包含阶段 |
|---------|------|---------|
| **clean** | 清理项目 | pre-clean → clean → post-clean |
| **default** | 构建项目 | validate → compile → test → package → verify → install → deploy |
| **site** | 生成项目报告 | pre-site → site → post-site → site-deploy |

> **面试官：`mvn clean install` 执行了哪些阶段？**
>
> 答：先执行 clean 生命周期的 `clean` 阶段（清理 target/ 目录），然后执行 default 生命周期的所有阶段直到 `install`（validate → compile → test → package → install）。注意三套生命周期相互独立，`clean` 不会影响 `install` 的执行顺序。

### 1.1 default 生命周期详解（15个阶段）

```
validate          ← 验证项目结构是否正确
initialize        ← 初始化构建状态
generate-sources  ← 生成源代码
process-sources   ← 处理源代码
generate-resources ← 生成资源文件
process-resources ← 复制资源到目标目录
compile           ← 编译源代码
process-classes   ← 处理编译后的文件
generate-test-sources ← 生成测试代码
process-test-sources  ← 处理测试代码
generate-test-resources ← 生成测试资源
process-test-resources  ← 复制测试资源
test-compile      ← 编译测试代码
process-test-classes   ← 处理测试编译文件
test              ← 执行测试
prepare-package   ← 打包前的准备工作
package           ← 打包（JAR/WAR）
pre-integration-test  ← 集成测试前
integration-test      ← 集成测试
post-integration-test ← 集成测试后
verify            ← 验证包是否合规
install           ← 安装到本地仓库
deploy            ← 部署到远程仓库
```

**每个阶段都绑定了一个或多个插件目标（Plugin Goal）：**
```xml
<!-- compile 阶段默认绑定：maven-compiler-plugin:compile -->
<!-- test 阶段默认绑定：maven-surefire-plugin:test -->
<!-- package 阶段默认绑定：maven-jar-plugin:jar -->
<!-- install 阶段默认绑定：maven-install-plugin:install -->
```

### 1.2 阶段绑定原理

```xml
<!-- 自定义插件绑定到特定阶段 -->
<build>
    <plugins>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-source-plugin</artifactId>
            <version>3.2.1</version>
            <executions>
                <execution>
                    <id>attach-sources</id>
                    <!-- 绑定到 package 阶段之后执行 -->
                    <phase>package</phase>
                    <goals>
                        <goal>jar-no-fork</goal>
                    </goals>
                </execution>
            </executions>
        </plugin>
    </plugins>
</build>
```

## 二、多模块项目最佳实践

### 2.1 项目结构设计

```
my-project/
├── pom.xml                          ← 父 POM（聚合 + 继承）
├── my-project-common/               ← 公共工具模块
│   └── pom.xml
├── my-project-dal/                  ← 数据访问模块
│   └── pom.xml
├── my-project-service/              ← 业务逻辑模块
│   └── pom.xml
├── my-project-web/                  ← Web 接口模块
│   └── pom.xml
└── my-project-api/                  ← API 接口定义
    └── pom.xml
```

### 2.2 父 POM 配置

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    
    <!-- 父 POM 的坐标 -->
    <groupId>com.example</groupId>
    <artifactId>my-project</artifactId>
    <version>1.0.0-SNAPSHOT</version>
    <packaging>pom</packaging>  <!-- 父 POM 必须是 pom 类型 -->
    
    <!-- 聚合子模块 -->
    <modules>
        <module>my-project-common</module>
        <module>my-project-dal</module>
        <module>my-project-service</module>
        <module>my-project-api</module>
        <module>my-project-web</module>
    </modules>
    
    <!-- 统一版本管理 -->
    <properties>
        <java.version>17</java.version>
        <spring-boot.version>3.2.0</spring-boot.version>
        <spring-cloud.version>2023.0.0</spring-cloud.version>
        <maven.compiler.source>${java.version}</maven.compiler.source>
        <maven.compiler.target>${java.version}</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>
    
    <!-- 统一的依赖版本管理（只声明版本，不引入依赖） -->
    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-dependencies</artifactId>
                <version>${spring-boot.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
            <!-- 内部模块版本管理 -->
            <dependency>
                <groupId>com.example</groupId>
                <artifactId>my-project-common</artifactId>
                <version>${project.version}</version>
            </dependency>
            <dependency>
                <groupId>com.example</groupId>
                <artifactId>my-project-dal</artifactId>
                <version>${project.version}</version>
            </dependency>
        </dependencies>
    </dependencyManagement>
    
    <!-- 所有子模块共用的依赖 -->
    <dependencies>
        <!-- 所有子模块默认引入 Lombok -->
        <dependency>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <optional>true</optional>
        </dependency>
        <!-- 所有子模块默认引入测试 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

### 2.3 子模块 POM 配置

```xml
<!-- my-project-service/pom.xml -->
<project>
    <parent>
        <groupId>com.example</groupId>
        <artifactId>my-project</artifactId>
        <version>1.0.0-SNAPSHOT</version>
        <relativePath>../pom.xml</relativePath>  <!-- 父 POM 路径 -->
    </parent>
    
    <artifactId>my-project-service</artifactId>
    <packaging>jar</packaging>
    
    <dependencies>
        <!-- 引用内部模块（版本由父 POM 管理） -->
        <dependency>
            <groupId>com.example</groupId>
            <artifactId>my-project-dal</artifactId>
        </dependency>
        <dependency>
            <groupId>com.example</groupId>
            <artifactId>my-project-common</artifactId>
        </dependency>
        <!-- 第三方依赖（版本由 spring-boot-dependencies 管理） -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
    </dependencies>
</project>
```

> **面试追问：`dependencyManagement` 和 `dependencies` 有什么区别？**
>
> 答：`dependencyManagement` 只声明依赖的版本信息，子模块按需引入且无需指定版本；`dependencies` 是直接引入依赖。父 POM 的 `dependencyManagement` 不会被子模块继承依赖，但子模块在引入同名依赖时自动继承版本号。

## 三、Maven 依赖冲突与解决

### 3.1 依赖传递与冲突规则

```
my-project-web
    ↓
spring-boot-starter-web
    ↓                    ↓
spring-boot-starter    spring-boot-starter-json
    ↓                    ↓
spring-core 6.0.0     jackson-databind 2.15.0
                       ↓
                    jackson-core 2.15.0
    ↓
my-project-service
    ↓
my-project-dal
    ↓
mysql-connector-j 8.0.33
```

**Maven 解决冲突的两大原则：**

1️⃣ **最短路径优先**：路径最短的依赖优先
```
A → B → C → D 2.0   (深度 3)
A → E → D 1.0       (深度 2) — 选中 D 1.0！
```

2️⃣ **最先声明优先**：路径相同时，先声明的优先

### 3.2 查看依赖树

```bash
# 查看完整依赖树
mvn dependency:tree

# 查看特定依赖的传递关系
mvn dependency:tree -Dincludes=com.fasterxml.jackson

# 输出示例
[INFO] com.example:my-project-web:jar:1.0.0-SNAPSHOT
[INFO] +- org.springframework.boot:spring-boot-starter-web:jar:3.2.0:compile
[INFO] |  +- org.springframework.boot:spring-boot-starter:jar:3.2.0:compile
[INFO] |  |  +- org.springframework.boot:spring-boot:jar:3.2.0:compile
[INFO] |  |  \- org.springframework:spring-core:jar:6.0.14:compile
[INFO] |  \- com.fasterxml.jackson.core:jackson-databind:jar:2.15.3:compile
```

### 3.3 排除冲突依赖

```xml
<!-- 方式一：exclusions 排除传递依赖 -->
<dependency>
    <groupId>com.example</groupId>
    <artifactId>some-library</artifactId>
    <exclusions>
        <exclusion>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </exclusion>
    </exclusions>
</dependency>

<!-- 方式二：直接声明想要的版本（最短路径优先） -->
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
    <version>2.16.0</version>
</dependency>
```

## 四、Maven 构建优化

### 4.1 并行构建

```bash
# 多模块并行构建
mvn clean install -T 4           # 4 个线程
mvn clean install -T 1.5C        # CPU 核心数的 1.5 倍
mvn clean install -T 4 -o        # -o 离线模式，避免每次检查远程仓库
```

### 4.2 增量构建与跳过测试

```bash
# 跳过测试（但建议只在开发时使用）
mvn clean install -DskipTests        # 跳过测试编译和执行
mvn clean install -Dmaven.test.skip=true  # 彻底跳过测试

# 只构建指定模块及依赖
mvn clean install -pl my-project-web -am
# -pl: 指定构建模块
# -am: also-make，同时构建依赖模块

# 恢复构建（从上次失败的模块继续）
mvn clean install -rf my-project-dal
# -rf: resume-from，从指定模块恢复构建
```

### 4.3 Profile 环境配置

```xml
<!-- 多环境配置 -->
<profiles>
    <!-- 开发环境 -->
    <profile>
        <id>dev</id>
        <activation>
            <activeByDefault>true</activeByDefault>
        </activation>
        <properties>
            <env>dev</env>
            <db.url>jdbc:mysql://localhost:3306/dev_db</db.url>
        </properties>
    </profile>
    
    <!-- 生产环境 -->
    <profile>
        <id>prod</id>
        <properties>
            <env>prod</env>
            <db.url>jdbc:mysql://prod-db:3306/prod_db</db.url>
        </properties>
    </profile>
    
    <!-- 启用代码检查 -->
    <profile>
        <id>strict</id>
        <build>
            <plugins>
                <plugin>
                    <groupId>org.apache.maven.plugins</groupId>
                    <artifactId>maven-checkstyle-plugin</artifactId>
                    <executions>
                        <execution>
                            <phase>verify</phase>
                            <goals><goal>check</goal></goals>
                        </execution>
                    </executions>
                </plugin>
            </plugins>
        </build>
    </profile>
</profiles>
```

```bash
# 使用指定 profile 构建
mvn clean package -P prod
mvn clean install -P dev,strict  # 多 profile 用逗号分隔
```

## 五、Maven CI/CD 集成

### 5.1 GitHub Actions 中的 Maven 构建

```yaml
name: Java CI with Maven
on:
  push:
    branches: [ main, develop ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven  # 缓存 Maven 依赖
      
      - name: Build with Maven
        run: |
          mvn clean verify -B \
            -DskipITs=false \
            -P strict \
            --no-transfer-progress
      
      - name: Upload Build Artifacts
        uses: actions/upload-artifact@v3
        with:
          name: build-artifacts
          path: |
            **/target/*.jar
            !**/target/*-sources.jar
```

### 5.2 settings.xml 安全配置

```xml
<!-- ~/.m2/settings.xml -->
<settings>
    <!-- 私有仓库镜像 -->
    <mirrors>
        <mirror>
            <id>nexus</id>
            <mirrorOf>central</mirrorOf>
            <url>https://nexus.internal.com/repository/maven-public/</url>
        </mirror>
    </mirrors>
    
    <!-- 部署仓库认证（密码建议加密） -->
    <servers>
        <server>
            <id>nexus-releases</id>
            <username>${env.NEXUS_USER}</username>
            <password>${env.NEXUS_PASS}</password>
        </server>
    </servers>
    
    <!-- JDK 版本 -->
    <profiles>
        <profile>
            <id>jdk-17</id>
            <activation>
                <activeByDefault>true</activeByDefault>
            </activation>
            <properties>
                <maven.compiler.source>17</maven.compiler.source>
                <maven.compiler.target>17</maven.compiler.target>
            </properties>
        </profile>
    </profiles>
</settings>
```

## 六、常见问题排查

| 问题 | 原因 | 排查命令 | 解决方案 |
|------|------|---------|---------|
| 找不到符号 | 依赖版本冲突 | `mvn dependency:tree` | 排除冲突依赖 |
| 包不存在 | 子模块未编译 | `mvn clean install -pl module -am` | 先编译依赖模块 |
| 编译版本错误 | Java 版本不匹配 | `mvn -version` | 设置 `maven.compiler.source` |
| 构建太慢 | 未启用并行 | — | `-T 4`，加 `-o` 离线模式 |
| 重复类 | 多个 jar 包含相同类 | `mvn dependency:tree` | exclusions 排除 |

## 七、总结

**Maven 的核心三要素：**

1. **生命周期** — 定义了构建的各个阶段和顺序
2. **多模块管理** — 聚合（`<modules>`）+ 继承（`<parent>`）+ 依赖管理（`<dependencyManagement>`）
3. **依赖机制** — 传递依赖 + 最短路径优先规则

**生产级 Maven 最佳实践清单：**
- ✅ 使用 `dependencyManagement` 统一管理版本
- ✅ 子模块不要声明版本，由父 POM 统一管控
- ✅ 多模块项目使用 `mvn clean install -T 4 -o` 加速
- ✅ CI 中启用 `-B`（批处理模式，去掉下载进度条）
- ✅ 使用 `settings.xml` 管理安全敏感信息
- ❌ 不要手动修改 `target/` 目录
- ❌ 不要在 `pom.xml` 中硬编码密码
