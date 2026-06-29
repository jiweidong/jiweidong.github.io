---
title: Java 模块化系统（JPMS）从入门到实战：模块化迁移与兼容性指南
date: 2026-06-29 09:30:00
tags:
  - Java
  - 模块化
  - JPMS
  - Java 9
categories:
  - Java
  - Java进阶
author: 东哥
---

# Java 模块化系统（JPMS）从入门到实战：模块化迁移与兼容性指南

## 面试官：Java 9 模块化是什么？解决了什么问题？

**Java 平台模块化系统（JPMS，即 Project Jigsaw）是 Java 9 最大的新特性。** 它引入了一种新的代码组织方式——模块（Module），用于替代传统的 JAR 包模式。

### 为什么需要模块化？

在 Java 9 之前，JAR 包模式存在三大痛点：

1. **类路径地狱（Classpath Hell）**：`NoClassDefFoundError`、`ClassNotFoundException`、版本冲突频发
2. **无封装边界**：`public` 类在整个 JVM 类路径下全局可见，无法控制 API 的暴露范围
3. **JDK 自身臃肿**：`rt.jar` 包含全部 JDK 内部类，无法精简，嵌入式和小型设备不友好

JPMS 引入了模块描述文件 `module-info.java`，精确声明模块的依赖和导出：

```java
// module-info.java
module com.example.myapp {
    requires java.sql;                     // 声明依赖
    requires transitive java.logging;      // 传递性依赖
    exports com.example.myapp.api;         // 导出包（API）
    exports com.example.myapp.dto;
    opens com.example.myapp.internal;      // 开放包（反射用）
    provides com.example.spi.Service with  // 提供服务实现
        com.example.myapp.MyServiceImpl;
    uses com.example.spi.DataSource;       // 声明使用服务
}
```

## 模块化系统核心概念

### 模块描述关键字详解

| 关键字 | 作用 | 说明 |
|--------|------|------|
| `requires` | 声明依赖 | 类似 Maven 的 `<dependency>` |
| `requires transitive` | 传递依赖 | 依赖者自动获得该模块的依赖 |
| `requires static` | 编译期依赖 | 运行时可选 |
| `exports` | 导出包 | 只有导出的包对外可见 |
| `exports ... to` | 限定导出 | 只让指定模块访问 |
| `opens` | 开放包 | 允许运行时反射访问 |
| `opens ... to` | 限定开放 | 只允许指定模块反射 |
| `provides ... with` | 提供服务 | SPI 提供者声明 |
| `uses` | 使用服务 | SPI 消费者声明 |

### 模块的三种类型

```text
┌─────────────────────────────────────────────┐
│           Java 模块体系                      │
│                                             │
│  命名模块（Named Module）                    │
│  ├── 应用模块：module-info.java 声明的模块    │
│  ├── JDK 模块：java.base、java.sql 等        │
│  └── 库模块：Guava、Jackson 等模块化后的 JAR  │
│                                             │
│  未命名模块（Unnamed Module）                 │
│  └── 传统 classpath 上的所有 JAR             │
│                                             │
│  自动模块（Automatic Module）                 │
│  └── module-path 上的传统 JAR（9以降级兼容）   │
└─────────────────────────────────────────────┘
```

### 模块路径 vs 类路径

| 概念 | 类路径（Classpath） | 模块路径（Module Path） |
|------|--------------------|-----------------------|
| **作用域** | 所有类都可见 | 仅导出的包可见 |
| **封装性** | 无 | 有（exports 控制） |
| **启动方式** | `-cp` 或 `-classpath` | `-p` 或 `--module-path` |
| **模块描述** | 不需要 | 需要 module-info.java |
| **版本冲突** | 可能 class 版本冲突 | module-path 不允许同名模块 |

## 实战：将传统项目迁移到模块化

### 步骤一：分析项目依赖

```bash
# 使用 jdeps 分析 JAR 依赖
jdeps -summary --module-path lib/ myapp.jar
jdeps --module-path lib/ -jdkinternals --check com.example.myapp myapp.jar
```

输出示例：
```
myapp.jar -> java.base
myapp.jar -> java.sql
myapp.jar -> java.logging
myapp.jar -> javax.annotation (JDK internal API, deprecated)
```

### 步骤二：添加 module-info.java

```java
// 原始项目结构
// src/main/java/com/example/myapp/...
// 添加模块描述文件
// src/main/java/module-info.java

module com.example.myapp {
    requires java.sql;
    requires java.logging;
    requires com.fasterxml.jackson.databind;       // Jackson 自动模块
    requires static lombok;                        // Lombok 编译期依赖
    
    exports com.example.myapp.api;
    exports com.example.myapp.dto;
    
    opens com.example.myapp.controller to 
        com.fasterxml.jackson.databind;            // Jackson 反射需要
    
    opens com.example.myapp.entity to 
        org.hibernate.orm.core;                    // Hibernate 反射需要
}
```

### 步骤三：Maven 多模块配置

```xml
<!-- pom.xml -->
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-compiler-plugin</artifactId>
    <configuration>
        <source>17</source>
        <target>17</target>
        <!-- 模块化编译 -->
        <compilerArgs>
            <arg>--module-path</arg>
            <arg>${project.build.directory}/modules</arg>
        </compilerArgs>
    </configuration>
</plugin>
```

### 步骤四：处理常见兼容问题

#### 常见问题 1：反射访问被拒绝

```bash
# 错误信息
Unable to make field private final java.util.Map java.util.Collections$EmptyMap.m
accessible: module java.base does not "opens java.util" to unnamed module

# 解决方案（三种）
# 1. 在 module-info.java 中 opens
opens com.example.model;

# 2. JVM 参数
--add-opens java.base/java.util=ALL-UNNAMED

# 3. 使用 --illegal-access=permit（JDK 9-16，JDK 17+ 被禁用）
```

#### 常见问题 2：JAR 未模块化

```bash
# 传统 JAR 放在 module-path 上时被视为"自动模块"
# 自动模块名称来自 JAR 的 Automatic-Module-Name
# 或者在 MANIFEST.MF 中指定

# JVM 参数：将所有 classpath JAR 视为自动模块
--add-modules ALL-MODULE-PATH
```

#### 常见问题 3：Java EE / CORBA 模块被移除

```java
// javax.annotation 在 JDK 11+ 被移除
// 需手动添加 Maven 依赖
<dependency>
    <groupId>jakarta.annotation</groupId>
    <artifactId>jakarta.annotation-api</artifactId>
    <version>2.1.1</version>
</dependency>
```

## Spring Boot 与 JPMS

从 Spring Boot 3.0 开始（基于 JDK 17），对 JPMS 有了初步支持：

```java
// Spring Boot + JPMS
module com.example.demo {
    requires spring.boot;
    requires spring.boot.autoconfigure;
    requires spring.web;
    
    opens com.example.demo to 
        spring.core,           // Spring 需要反射
        spring.beans;          // Spring 需要反射
}
```

### Spring Boot 模块化注意事项

```java
// 1. @SpringBootApplication 扫描
// 模块化的包扫描有限制，需要用 @ComponentScan 显式指定
@SpringBootApplication
@ComponentScan(basePackages = {"com.example.demo"})
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}

// 2. 配置类代理
// Spring 的 @Configuration 使用 CGLIB 代理，需要 open 包
opens com.example.demo.config to 
    spring.aop, spring.cglib;
```

## JDK 内部 API 封装

JDK 9 开始，大量内部 API 被封装或移除：

| JDK 内部 API | JDK 8 | JDK 9+ | 替代方案 |
|-------------|-------|--------|---------|
| `sun.misc.Unsafe` | 可访问 | 仍可用但标记 deprecate | VarHandle (JDK 9+) |
| `sun.misc.BASE64Encoder` | 常用 | 已移除 | `java.util.Base64` |
| `sun.reflect.Reflection` | 常用 | 已封装 | `java.lang.StackWalker` |
| `com.sun.*` | 可访问 | 模块化封装 | 标准 API |
| `javax.xml.bind.*` (JAXB) | JDK 内置 | JDK 11 已移除 | Jakarta XML Binding |

**核心规则**：JDK 17+ 严格封装内部 API。如果想临时放宽：

```bash
# 不推荐，仅迁移过渡期使用
--add-opens java.base/java.lang=ALL-UNNAMED
--add-exports java.base/sun.security.provider=ALL-UNNAMED
```

## 面试官追问

### Q1: 未命名模块和自动模块的区别？

> **未命名模块（Unnamed Module）**：所有在 classpath 上的类属于同一个未命名模块。它可以看到所有已导出的 JDK 模块，但其他命名模块看不到它。
>
> **自动模块（Automatic Module）**：放在 module-path 上的传统 JAR。它可以从其 MANIFEST.MF 的 `Automatic-Module-Name` 获取模块名（没有就根据 JAR 文件名推断）。自动模块可以读取所有其他模块，并且所有其包都被视为已导出和已开放的。

### Q2: requires transitive 有什么用？

```java
module java.sql {
    requires transitive java.logging;
    exports java.sql;
}
// 当 module A requires java.sql 时，module A 自动获得 java.logging
// 不需要显式 requires java.logging
```

适用于：**一个模块的公开 API 使用了另一个模块的类型**。比如 `java.sql` 的 API 中抛出了 `java.logging.Logger`，那么依赖 `java.sql` 的模块自然也需要 `java.logging`。

### Q3: 版本管理：JPMS 为什么不处理版本？

> JPMS 关注的是**接口封装和依赖关系**，版本管理是**构建工具（Maven/Gradle）和容器（OSGi）的职责**。
>
> 如果两个不同版本的模块在 module-path 上，JVM 会报错。所以版本管理必须在 build 阶段就解决。

### Q4: 迁移到 JPMS 的推荐步骤？

```
1. jdeps 分析依赖 → 识别 JDK 内部 API 使用
2. 升级库版本 → 替换已移除的 JDK API
3. 应用 --add-opens / --add-exports → 兼容旧 JAR
4. 为启动模块添加 module-info.java
5. 逐步为依赖库添加 module-info.java
6. 移除 --add-opens 参数 → 全模块化
```

### Q5: JPMS 和 OSGi 的异同？

| 维度 | JPMS | OSGi |
|------|------|------|
| 标准 | Java 语言内置 | 独立规范（Eclipse） |
| 粒度 | package 级别 | class 级别 |
| 动态性 | 不支持热插拔 | 支持动态部署 |
| 版本管理 | 不支持 | 内建版本支持 |
| 学习成本 | 低（语言特性） | 高（独立框架） |
| 适用场景 | 代码组织封装 | 插件化动态系统 |

## 实战：验证模块封装性

```java
// 验证模块化的封装
public class ModuleTest {
    public static void main(String[] args) {
        // 1. 查看 JDK 模块
        ModuleLayer.boot().modules().forEach(module -> {
            System.out.println(module.getName() + " -> " 
                + module.getDescriptor().exports());
        });
        
        // 2. 查看当前模块
        Module myModule = ModuleTest.class.getModule();
        System.out.println("当前模块: " + myModule.getName());
        System.out.println("是否命名模块: " + myModule.isNamed());
        
        // 3. 检查包可访问性
        Module javaBase = Object.class.getModule();
        System.out.println("java.base是否导出sun.misc: " 
            + javaBase.isExported("sun.misc")); // false
    }
}
```

JPMS 是 Java 平台演进的关键一步。虽然迁移有阵痛，但理解模块化系统对写出结构清晰、封装良好的 Java 代码至关重要。面试时如果能从"为什么要模块化"到"如何迁移"讲得通透，会让面试官刮目相看。
