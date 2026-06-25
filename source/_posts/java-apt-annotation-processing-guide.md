---
title: 【面试进阶】Java 注解处理器（APT）原理与实战：从编译期生成代码
date: 2026-06-25 08:00:00
tags:
  - Java
  - APT
  - 注解处理器
  - 编译期
categories:
  - Java
  - Java基础
author: 东哥
---

# 【面试进阶】Java 注解处理器（APT）原理与实战：从编译期生成代码

## 开篇：APT 到底是什么？

> 面试官：你用过 Lombok 吗？知道 `@Data` 是怎么生成 getter/setter 的吗？

Lombok 的核心就是 **APT（Annotation Processing Tool）**——Java 编译期注解处理技术。

APT 是在 **编译期** 扫描和处理注解的机制，可以在 `javac` 编译 Java 源代码的过程中：

- 读取注解信息
- 校验注解合法性
- **生成新的 Java 源文件**（最重要的能力）
- 生成元数据配置文件

```java
// 你写的代码
@Data
public class User {
    private String name;
    private int age;
}

// 编译后实际生成的代码（APT 生成）
public class User {
    private String name;
    private int age;
    
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public int getAge() { return age; }
    public void setAge(int age) { this.age = age; }
    // 还有 toString()、equals()、hashCode()...
}
```

**APT vs 运行时反射**：

| 特性 | APT（编译期） | 运行时反射 |
|------|-------------|-----------|
| 执行时机 | javac 编译时 | JVM 运行时 |
| 性能开销 | 无运行时开销 | 有显著的反射性能损失 |
| 能否生成代码 | 能（生成 .java 文件） | 不能直接生成源代码 |
| 适用场景 | 样板代码生成、校验配置 | 动态调用、AOP、序列化 |

## 一、APT 核心机制

### 1.1 处理流程

```
Java 源文件 → javac 解析 → 生成 AST（抽象语法树）
                              ↓
                     RoundEnvironment（本轮注解处理环境）
                              ↓
                    ┌──────────────────┐
                    │  Annotation       │
                    │  Processor        │————→ 生成新的 .java 文件
                    │  (发现注解 → 处理) │
                    └──────────────────┘
                              ↓
                    如果有新文件生成 → 进入下一轮处理（Round）
                    如果没有 → 编译继续 → 生成 .class
```

APT 是 **多轮（Round）** 的：如果本轮处理生成了新的 Java 源文件，javac 会触发新的一轮处理，让这些新文件中可能存在的注解也能被处理。直到没有新的文件生成为止。

### 1.2 核心接口

实现自定义注解处理器只需要两个步骤：

**步骤 1**：实现 `AbstractProcessor`

```java
@SupportedAnnotationTypes("com.example.Check")  // 要处理的注解全限定名
@SupportedSourceVersion(SourceVersion.RELEASE_17)  // 支持的 JDK 版本
public class CheckProcessor extends AbstractProcessor {

    @Override
    public synchronized void init(ProcessingEnvironment processingEnv) {
        super.init(processingEnv);
        // processingEnv 提供了核心工具：
        //   processingEnv.getFiler()      —— 用于生成新文件
        //   processingEnv.getMessager()   —— 输出日志/错误（编译期报错！）
        //   processingEnv.getElements()   —— 元素工具（TypeElement、ExecutableElement）
        //   processingEnv.getTypes()      —— 类型工具
    }

    @Override
    public boolean process(Set<? extends TypeElement> annotations, 
                           RoundEnvironment roundEnv) {
        // 遍历所有被 @Check 注解的元素
        for (Element element : roundEnv.getElementsAnnotatedWith(Check.class)) {
            // 处理逻辑...
        }
        return true;  // true = 本 processor 已处理这些注解，后续 processor 不再处理
    }
}
```

**步骤 2**：注册 Processor

在 `META-INF/services/javax.annotation.processing.Processor` 文件中写入：

```
com.example.CheckProcessor
```

或者用 Google 的 `@AutoService` 自动生成：

```java
@AutoService(Processor.class)
public class CheckProcessor extends AbstractProcessor { ... }
```

> 用 Maven 构建的话，`@AutoService` 会依赖 `com.google.auto.service:auto-service` 包。

## 二、实战：写一个 Builder 生成器

我们来做一个实用的例子：给类加上 `@MyBuilder` 注解，自动生成 Builder 模式代码。

### 2.1 定义注解

```java
package com.example.annotation;

import java.lang.annotation.*;

@Target(ElementType.TYPE)       // 只能用在类上
@Retention(RetentionPolicy.SOURCE)  // 仅编译期保留，运行时不存在
public @interface MyBuilder {
    // 不需要任何属性
}
```

### 2.2 实现 Processor

```java
package com.example.processor;

import com.example.annotation.MyBuilder;
import javax.annotation.processing.*;
import javax.lang.model.SourceVersion;
import javax.lang.model.element.*;
import javax.lang.model.type.TypeMirror;
import javax.tools.Diagnostic;
import javax.tools.JavaFileObject;
import java.io.PrintWriter;
import java.io.Writer;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

@SupportedAnnotationTypes("com.example.annotation.MyBuilder")
@SupportedSourceVersion(SourceVersion.RELEASE_17)
public class MyBuilderProcessor extends AbstractProcessor {

    @Override
    public boolean process(Set<? extends TypeElement> annotations, 
                           RoundEnvironment roundEnv) {
        // 遍历被 @MyBuilder 注解的类
        for (Element element : roundEnv.getElementsAnnotatedWith(MyBuilder.class)) {
            if (element.getKind() != ElementKind.CLASS) {
                processingEnv.getMessager().printMessage(
                    Diagnostic.Kind.ERROR, "@MyBuilder 只能用于类", element);
                continue;
            }
            
            TypeElement typeElement = (TypeElement) element;
            generateBuilder(typeElement);
        }
        return true;
    }

    private void generateBuilder(TypeElement typeElement) {
        // 原类名和包名
        String className = typeElement.getSimpleName().toString();
        String packageName = processingEnv.getElementUtils()
            .getPackageOf(typeElement).getQualifiedName().toString();
        String builderClassName = className + "Builder";

        // 获取所有字段（实例变量）
        List<VariableElement> fields = typeElement.getEnclosedElements().stream()
            .filter(e -> e.getKind() == ElementKind.FIELD)
            .map(e -> (VariableElement) e)
            .filter(e -> !e.getModifiers().contains(Modifier.STATIC))
            .collect(Collectors.toList());

        try {
            // 通过 Filer 生成新的 .java 文件
            JavaFileObject builderFile = processingEnv.getFiler()
                .createSourceFile(packageName + "." + builderClassName);
            
            try (PrintWriter out = new PrintWriter(builderFile.openWriter())) {
                // 写入包名
                if (!packageName.isEmpty()) {
                    out.println("package " + packageName + ";");
                    out.println();
                }

                // 导入原类
                out.println("import " + packageName + "." + className + ";");
                out.println();

                // 生成 Builder 类
                out.println("public class " + builderClassName + " {");
                out.println();

                // 字段
                for (VariableElement field : fields) {
                    out.println("    private " + field.asType() + " " 
                        + field.getSimpleName() + ";");
                }
                out.println();

                // setter 方法（返回 Builder 本身）
                for (VariableElement field : fields) {
                    String fieldName = field.getSimpleName().toString();
                    out.println("    public " + builderClassName + " " 
                        + fieldName + "(" + field.asType() + " " + fieldName + ") {");
                    out.println("        this." + fieldName + " = " + fieldName + ";");
                    out.println("        return this;");
                    out.println("    }");
                    out.println();
                }

                // build() 方法
                out.println("    public " + className + " build() {");
                out.println("        " + className + " instance = new " + className + "();");

                // 为每个字段生成 setter 调用
                for (VariableElement field : fields) {
                    String fieldName = field.getSimpleName().toString();
                    out.println("        instance.set" 
                        + capitalize(fieldName) + "(" + "this." + fieldName + ");");
                }

                out.println("        return instance;");
                out.println("    }");
                out.println("}");
            }
        } catch (Exception e) {
            processingEnv.getMessager().printMessage(Diagnostic.Kind.ERROR,
                "生成 Builder 失败: " + e.getMessage());
        }
    }

    private String capitalize(String str) {
        return Character.toUpperCase(str.charAt(0)) + str.substring(1);
    }
}
```

### 2.3 使用效果

```java
// 原代码
@MyBuilder
public class User {
    private String name;
    private int age;
    private String email;
    
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    // ... getter/setter ...
}

// APT 编译后自动生成的 UserBuilder.java
/* 
public class UserBuilder {
    private String name;
    private int age;
    private String email;
    
    public UserBuilder name(String name) { this.name = name; return this; }
    public UserBuilder age(int age) { this.age = age; return this; }
    public UserBuilder email(String email) { this.email = email; return this; }
    
    public User build() {
        User instance = new User();
        instance.setName(this.name);
        instance.setAge(this.age);
        instance.setEmail(this.email);
        return instance;
    }
}
*/

// 使用
User user = new UserBuilder()
    .name("张三")
    .age(25)
    .email("zhangsan@example.com")
    .build();
```

## 三、APT 在实际框架中的应用

### 3.1 Lombok

Lombok 是 APT 最著名的应用。但它的实现方式并不是通过标准的 `AbstractProcessor` 生成源文件，而是直接 **修改 AST（抽象语法树）**：

```text
标准 APT:    读注解 → 生成新 .java 文件
Lombok:      读注解 → 直接修改当前类的 AST 树 → 插入新的 tree node
```

这就是为什么 Lombok 能做到：在同一个类中插入新方法，而标准 APT 只能生成其他新类。

Lombok 通过自定义 `javac` 的 **Plugin**（`javac -Xplugin: LombokPlugin`）来实现在编译期修改 AST。

### 3.2 MapStruct

```java
@Mapper
public interface UserMapper {
    UserMapper INSTANCE = Mappers.getMapper(UserMapper.class);
    
    UserDTO toDTO(User user);
    User toEntity(UserDTO dto);
}

// APT 编译后自动生成 UserMapperImpl
/*
public class UserMapperImpl implements UserMapper {
    @Override
    public UserDTO toDTO(User user) {
        UserDTO dto = new UserDTO();
        dto.setId(user.getId());
        dto.setName(user.getName());
        // ... 字段映射 ...
        return dto;
    }
}
*/
```

MapStruct 使用标准 APT，在编译期分析 `@Mapper` 接口，读取字段映射关系，生成高性能的实现类（比 BeanUtils 反射快 10-100 倍）。

### 3.3 Android Room / Hilt / Dagger

- **Room**：通过 APT 生成 DAO 实现和数据库版本管理的代码
- **Dagger / Hilt**：通过 APT 在编译期生成依赖注入的代码（Dagger 最著名的是"慢编译但快运行"）

### 3.4 Spring 中的 APT

```xml
<!-- spring-boot-configuration-processor -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-configuration-processor</artifactId>
    <optional>true</optional>
</dependency>
```

当你写 `@ConfigurationProperties` 时，这个 processor 会在编译期生成 `spring-configuration-metadata.json`，为 IDE 提供属性自动补全和文档提示。

## 四、Maven 配置

```xml
<dependencies>
    <!-- 编译期依赖，运行时不需要 -->
    <dependency>
        <groupId>com.google.auto.service</groupId>
        <artifactId>auto-service</artifactId>
        <version>1.1.1</version>
        <optional>true</optional>
    </dependency>
</dependencies>

<build>
    <plugins>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-compiler-plugin</artifactId>
            <configuration>
                <source>17</source>
                <target>17</target>
                <annotationProcessorPaths>
                    <!-- 指定 annotation processor -->
                    <path>
                        <groupId>com.example</groupId>
                        <artifactId>my-processor</artifactId>
                        <version>1.0.0</version>
                    </path>
                </annotationProcessorPaths>
            </configuration>
        </plugin>
    </plugins>
</build>
```

## 五、常见面试题

| 问题 | 答案要点 |
|------|---------|
| APT 和反射有什么区别？ | APT 编译期，反射运行时；APT 生成代码无性能损失 |
| Processor 能修改现有类的代码吗？ | 标准 APT 不能，Lombok 通过修改 AST 可以实现 |
| @Retention 不同策略对 APT 有影响吗？ | `SOURCE` 和 `CLASS` 都行，`RUNTIME` 当然也行但没必要 |
| 生成的代码在哪个阶段生效？ | 生成的代码在本轮处理后的编译中生效 |
| 为什么有些框架用 APT 而不是反射？ | 性能更好，编译期发现错误，生成的代码更直观 |
| Lombok 和标准 APT 有什么区别？ | Lombok 修改 AST，标准 APT 只能生成新文件 |
| Filer.createSourceFile 和 Filer.createClassFile 区别？ | 前者生成 .java，后者生成 .class |
| 怎么在编译期报错？ | `processingEnv.getMessager().printMessage(Kind.ERROR, msg)` |

## 六、APT 的局限性

1. **无法修改现有类**：标准 APT 只能生成新类，不能给已有类添加方法（Lombok 除外）
2. **代码生成仅在编译期**：无法在运行期动态生成
3. **调试困难**：生成的代码是运行期才体现出来的，不像手写代码那样直观
4. **IDE 支持不一**：有些 IDE 需要额外配置才能识别 APT 生成的代码

## 总结

APT 是 Java 编译期编程的核心技术。它让"写更少的代码"成为可能——从 Lombok 到 MapStruct、从 Dagger 到 Room，大量框架依赖 APT 在编译期解放你的双手。

掌握 APT，不仅能让你理解这些框架的底层原理，还能在遇到重复的样板代码时，自己动手写出一个 Processor 来彻底消灭它。面试时聊到 APT，说明你对 Java 的理解已经从"使用"上升到"创造"的层面了。
