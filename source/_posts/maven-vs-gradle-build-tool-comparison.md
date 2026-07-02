---
title: Maven vs Gradle：Java 构建工具深度对比与渐进式迁移实战
date: 2026-07-02 08:00:00
tags:
  - Java
  - Maven
  - Gradle
  - 构建工具
  - 工程化
categories:
  - Java
  - 工程实践
author: 东哥
---

# Maven vs Gradle：Java 构建工具深度对比与渐进式迁移实战

## 引言

在 Java 生态中，构建工具经历了从 **Ant → Maven → Gradle** 的演进。2012 年 Gradle 诞生后，凭借其灵活的 DSL 和增量构建能力迅速崛起，但 Maven 凭借稳定的约定优于配置理念仍是企业主流。

截至 2026 年，**Spring Boot 官方文档** 同时提供了 Maven 和 Gradle 两种构建方式，**Android 默认使用 Gradle**，而 **国内大多数企业仍坚守 Maven**。

本文将深入对比两大构建工具的核心差异，并给出从 Maven 迁移到 Gradle 的实战指南。

## 一、核心哲学对比

| 维度 | Maven | Gradle |
|------|-------|--------|
| **配置文件** | XML (`pom.xml`) | Groovy (`build.gradle`) / Kotlin (`build.gradle.kts`) |
| **设计理念** | 约定优于配置 | 编程式配置 + 约定 |
| **生命周期** | 固定三阶段（clean/default/site）| 灵活的任务图（Task Graph） |
| **依赖管理** | 声明式 | 声明式 + 编程式 |
| **构建性能** | 中等 | 优秀（增量构建 + 构建缓存） |
| **学习曲线** | 低 | 中-高 |

## 二、配置解析：从 pom.xml 到 build.gradle

### 2.1 依赖声明对比

**Maven：**
```xml
<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
        <version>3.3.0</version>
    </dependency>
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <optional>true</optional>
    </dependency>
    <dependency>
        <groupId>org.junit.jupiter</groupId>
        <artifactId>junit-jupiter</artifactId>
        <scope>test</scope>
    </dependency>
</dependencies>
```

**Gradle（Kotlin DSL）：**
```kotlin
dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web:3.3.0")
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")
    testImplementation("org.junit.jupiter:junit-jupiter")
}
```

**对比：** Gradle 的依赖配置更简洁，且 `implementation` / `api` 的分离是 Maven 没有的。

### 2.2 依赖范围对比

| Maven | Gradle | 说明 |
|-------|--------|------|
| compile | api / implementation | api 可传递，implementation 不可传递 |
| provided | compileOnly | 编译期需要，运行期由容器提供 |
| runtime | runtimeOnly | 运行期需要，编译期不需要 |
| test | testImplementation | 测试代码专用 |
| system | — | 已不推荐使用 |
| import | — | Maven BOM 管理 |

### 2.3 Maven 的依赖仲裁 vs Gradle 的模块化依赖

**Maven** 依赖仲裁规则：
1. 按 **最短路径** 选择版本
2. 路径相同时，**先声明者优先**
3. 可显式使用 `<dependencyManagement>` 覆盖

**Gradle** 默认行为（可配置）：
- 取版本冲突中 **最高版本**
- 可通过 `force` / `strictly` / `require` 精细控制

```kotlin
// Gradle 精细控制版本
configurations.all {
    resolutionStrategy {
        force("com.fasterxml.jackson.core:jackson-databind:2.17.0")
        eachDependency {
            if (requested.group == "org.apache.logging.log4j") {
                useVersion("2.23.0")
            }
        }
    }
}
```

## 三、性能对决：为什么 Gradle 更快？

### 3.1 增量构建

**Gradle** 的**任务输入输出追踪**（Up-to-date checks）是其性能杀手锏：

```kotlin
// Gradle 会基于输入输出指纹自动判断是否需要重新执行
tasks.compileJava {
    inputs.dir(layout.projectDirectory.dir("src/main/java"))
    outputs.dir(layout.buildDirectory.dir("classes/java/main"))
}
```

- 源码没变 → `UP-TO-DATE`，跳过编译
- 编译输入没变 → 跳过测试
- **Maven 无法做到这种粒度的增量检查**

### 3.2 构建缓存

```text
# Maven 构建（无缓存，纯串行）
[INFO] --- maven-compiler-plugin:3.11.0:compile (default-compile) ---
[INFO] Compiling 200 source files to target/classes
[INFO] --- maven-compiler-plugin:3.11.0:testCompile (default-testCompile) ---
[INFO] Compiling 80 test source files to target/test-classes
Total time: 45s

# Gradle 构建（增量缓存）
> Task :compileJava UP-TO-DATE
> Task :compileTestJava UP-TO-DATE
> Task :test UP-TO-DATE
> Task :bootJar UP-TO-DATE
BUILD SUCCESSFUL in 3s
```

### 3.3 并行构建

```kotlin
// gradle.properties
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=512m
```

Gradle 默认支持**并行项目编译**和**并行测试执行**，Maven 需要显式配置 `-T` 参数。

### 3.4 性能基准（中型项目，200+ 模块）

| 场景 | Maven | Gradle | 提升 |
|------|-------|--------|------|
| 全量编译 | 4分30秒 | 2分15秒 | **50%** |
| 修改1个文件后编译 | 2分10秒 | 12秒 | **90%** |
| 运行全部单测 | 8分钟 | 4分钟 | **50%** |
| CI 零变更缓存命中 | 2分钟 | 5秒 | **95%** |

## 四、从 Maven 到 Gradle：渐进式迁移指南

### 4.1 第一步：搭建 Gradle Wrapper

```bash
# 在项目根目录初始化
gradle wrapper --gradle-version=8.7
```

这将生成 `gradlew` / `gradlew.bat` / `gradle/wrapper/` 目录，实现与 CI 环境的版本一致。

### 4.2 第二步：自动转换

```bash
# Gradle 内置 init 脚本可自动解析 pom.xml
cd project-root
gradle init --type pom --dsl kotlin
```

这会生成 `build.gradle.kts`、`settings.gradle.kts`，但可能需要手动调整：
- Maven profiles → Kotlin 条件逻辑
- 插件配置 → Gradle plugin API

### 4.3 第三步：关键配置对照表

| Maven | Gradle |
|-------|--------|
| `<repositories>` | `repositories { mavenCentral() }` |
| `<properties>` | `val junitVersion by extra("5.10.0")` |
| `<plugin>` | `plugins { id("...") version "..." }` |
| `<profiles>` | `if (project.hasProperty("prod")) { ... }` |
| `<multimodule>` | settings.gradle.kts 声明 `include` |

### 4.4 多模块项目转化示例

**Maven 父 POM：**
```xml
<modules>
    <module>common</module>
    <module>service</module>
    <module>web</module>
</modules>
```

**Gradle settings.gradle.kts：**
```kotlin
rootProject.name = "my-project"
include("common", "service", "web")
```

### 4.5 常见坑点

1. **资源过滤**：Maven 的 `<filtering>true</filtering>` 需用 Gradle 的 `processResources` 配置
2. **生成的代码**：如 MapStruct、QueryDSL，需明确配置注释处理器
3. **War 部署**：需配置 `war` 插件而非 `application` 插件
4. **CI 镜像缓存**：.gradle/caches 目录要合理缓存

```kotlin
// Gradle 资源过滤等价配置
tasks.processResources {
    filesMatching("application.yml") {
        expand(project.properties)
    }
}
```

## 五、面试高频追问

### Q1：为什么 Spring Boot 同时支持 Maven 和 Gradle，但官方教程更多用 Maven？
**A：** Maven 的市场占有率仍然最高（约 60%+），且 XML 配置对 Java 开发者更「安全」——IDE 支持完善、文档丰富。但 Spring Initializr 同样支持 Gradle，两者官方地位平等。

### Q2：Gradle 的 implementation 和 api 有什么区别？为什么 Maven 没有？
**Maven** 的 compile 都是 `api` 语义——依赖会被传递。**Gradle** 引入 `implementation`（不传递）来减少编译类路径污染：

```kotlin
// Module A: build.gradle.kts
dependencies {
    api("com.google.guava:guava:33.0.0")    // 传递
    implementation("com.google.code.gson:gson:2.10.1")  // 不传递
}
```

这意味着依赖 A 的模块 B 能访问 Guava 但不能访问 Gson，**减少了不必要的重建**。

### Q3：Gradle 的构建缓存（Build Cache）怎么用？
**A：** 本地缓存在 `~/.gradle/caches/`，远程缓存需配置：
```kotlin
// settings.gradle.kts
buildCache {
    remote<HttpBuildCache> {
        url = uri("https://cache.company.com/")
        isPush = true
    }
}
```
CI 的构建结果可被本地开发者复用，节省大量时间。

### Q4：Maven 会不会被 Gradle 完全取代？
**A：** 短期内不会。Maven 的优势在于：① 极度稳定，十年兼容；② IDE 支持完善；③ 企业内部存量项目巨大；④ 学习成本极低。但新项目尤其是大型多模块项目，强烈推荐 Gradle。

## 六、总结与建议

```text
个人/小团队新项目      → Gradle（性能好，配置灵活）
企业既有 Maven 项目    → 保持 Maven（迁移成本高）
Android 开发            → Gradle（唯一选择）
大厂中间件项目          → Gradle（增量构建收益大）
标准 Spring Boot 项目   → 两者皆可，按团队习惯
```

**最终结论：Maven 是稳妥的选择，Gradle 是更好的选择。** 如果你正在从 Maven 迁移到 Gradle，务必充分测试 CI/CD 流程，特别是构建缓存和并行编译配置。善用 Gradle Wrapper 确保团队成员版本一致，是成功迁移的关键第一步。
