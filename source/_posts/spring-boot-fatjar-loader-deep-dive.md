---
title: Spring Boot 可执行 JAR 加载原理深度解析：FatJar 与 Spring Boot Loader
date: 2026-07-20 08:00:00
tags:
  - Spring Boot
  - JAR
  - 原理
  - 类加载
categories:
  - Spring Boot
  - 原理源码
author: 东哥
---

# Spring Boot 可执行 JAR 加载原理深度解析：FatJar 与 Spring Boot Loader

## 一、引言

用过 Spring Boot 的开发者都知道，只需要执行 `java -jar myapp.jar` 就能启动一个完整的 Web 应用。但这个"神奇的 JAR 包"到底是怎么工作的？为什么普通的 JAR 包不能这样直接运行？Spring Boot 的可执行 JAR 和普通 JAR 有什么区别？

本篇文章将从底层源码深入剖析 Spring Boot FatJar 的打包、加载和启动机制。

## 二、普通 JAR 与 Spring Boot FatJar 的区别

### 2.1 普通 JAR 的结构

一个典型的普通 JAR 包结构如下：

```
myapp.jar
├── META-INF/
│   └── MANIFEST.MF    # 包含 Main-Class 等元信息
├── com/example/
│   └── MyApp.class     # 应用自己的类文件
└── ...
```

普通 JAR 包的特点：
- 只包含应用自身的代码
- 不包含第三方依赖（依赖需通过 classpath 指定）
- 通过 `java -jar` 执行时，JVM 从 Class-Path 指定的位置加载依赖

### 2.2 Spring Boot FatJar 的结构

使用 `spring-boot-maven-plugin` 打包后的 FatJar：

```
myapp.jar
├── META-INF/
│   └── MANIFEST.MF
├── BOOT-INF/
│   ├── classes/              # 应用自身编译后的 class 文件
│   │   └── com/example/...
│   └── lib/                  # 所有第三方依赖 JAR 包
│       ├── spring-core-6.x.jar
│       ├── spring-boot-3.x.jar
│       └── ...
└── org/
    └── springframework/
        └── boot/
            └── loader/       # Spring Boot Loader 类
                ├── JarLauncher.class
                ├── Launcher.class
                └── ...
```

**核心问题**：`BOOT-INF/lib/` 下的 JAR 包被嵌套在 JAR 包内部，标准的 `URLClassLoader` 无法加载嵌套 JAR 中的类！Spring Boot 的解决方案是自定义类加载器 `LaunchedURLClassLoader`。

## 三、MANIFEST.MF 的关键配置

解压 Spring Boot FatJar，查看 `META-INF/MANIFEST.MF`：

```properties
Manifest-Version: 1.0
Main-Class: org.springframework.boot.loader.JarLauncher
Start-Class: com.example.demo.DemoApplication
Spring-Boot-Version: 3.2.0
```

这里有两个关键配置：
- **Main-Class**：JVM 启动入口，指向 Spring Boot Loader 的 `JarLauncher`
- **Start-Class**：应用的真正入口 Main 类

JVM 启动时执行 `JarLauncher.main()`，由它负责加载嵌套 JAR，再反射调用 `Start-Class` 的 `main` 方法。

## 四、Spring Boot Loader 源码分析

### 4.1 Launcher 继承体系

Spring Boot Loader 提供了三种 Launcher：

| Launcher | 适用场景 | 加载路径 |
|---|---|---|
| `JarLauncher` | 标准 JAR 包部署 | `BOOT-INF/lib/` |
| `WarLauncher` | WAR 包部署到外部容器 | `WEB-INF/lib/` 和 `WEB-INF/lib-provided/` |
| `PropertiesLauncher` | 自定义路径加载 | 通过 `loader.path` 环境变量指定 |

### 4.2 JarLauncher 启动流程

```java
// JarLauncher.java (Spring Boot 3.x)
public class JarLauncher extends ExecutableArchiveLauncher {

    static final String BOOT_INF_CLASSES = "BOOT-INF/classes/";
    static final String BOOT_INF_LIB = "BOOT-INF/lib/";

    @Override
    protected boolean isNestedArchive(Archive.Entry entry) {
        return entry.getName().startsWith(BOOT_INF_LIB);
    }

    public static void main(String[] args) throws Exception {
        // 继承自 Launcher 的 launch 方法
        new JarLauncher().launch(args);
    }
}
```

**启动步骤**：

```
1. 创建 JarLauncher 实例
   ↓
2. 构造 Archive 对象（封装 JAR 文件结构）
   ↓
3. 创建 LaunchedURLClassLoader（负责加载 BOOT-INF/lib/ 和 BOOT-INF/classes/）
   ↓
4. 通过反射调用 Start-Class 的 main 方法
```

### 4.3 核心：LaunchedURLClassLoader

`LaunchedURLClassLoader` 继承自 `java.net.URLClassLoader`，重写了 `loadClass` 方法：

```java
// LaunchedURLClassLoader 简化源码
public class LaunchedURLClassLoader extends URLClassLoader {

    private final ClassLoader rootClassLoader;

    public LaunchedURLClassLoader(URL[] urls, ClassLoader parent) {
        super(urls, parent);
        this.rootClassLoader = findRootClassLoader();
    }

    @Override
    protected Class<?> loadClass(String name, boolean resolve)
            throws ClassNotFoundException {
        Handler.setUseFastConnectionExceptions(true);
        try {
            // 1. 尝试从已加载类中查找
            Class<?> loadedClass = findLoadedClass(name);
            if (loadedClass != null) return loadedClass;

            // 2. 尝试自己加载（优先从 BOOT-INF/classes 和 BOOT-INF/lib 加载）
            try {
                loadedClass = findClass(name);
                if (loadedClass != null) return loadedClass;
            } catch (ClassNotFoundException ex) {
                // ignore
            }

            // 3. 委托给 parent ClassLoader
            return super.loadClass(name, resolve);
        } finally {
            Handler.setUseFastConnectionExceptions(false);
        }
    }
}
```

**关键差异**：与 JDK 默认的双亲委派模型不同，`LaunchedURLClassLoader` **先尝试自己加载，再委托给父加载器**。这是为了解决嵌套 JAR 的加载问题——如果先委托给父加载器（AppClassLoader），父加载器无法识别 `jar:file://...!/BOOT-INF/lib/xxx.jar!/` 这种嵌套路径。

### 4.4 嵌套 JAR URL 协议：`org.springframework.boot.loader.jar.Handler`

Spring Boot 自定义了 `URL` 协议处理类 `Handler`，支持 `jar:file:///app.jar!/BOOT-INF/lib/spring-core.jar!/` 这种嵌套 JAR 的 URL 访问。

```java
// org.springframework.boot.loader.jar.Handler
public class Handler extends URLStreamHandler {

    @Override
    protected URLConnection openConnection(URL url) throws IOException {
        // 解析嵌套 JAR 的 URL，返回 JarURLConnection
        return new JarURLConnection(url, ...);
    }

    @Override
    protected void parseURL(URL url, String spec, int start, int limit) {
        // 处理 "!/" 分隔符，逐层解析嵌套 JAR
    }
}
```

**URL 协议注册**：在 `JarLauncher` 初始化时，通过以下方式注册 Handler：

```java
// 注册 URL 协议处理器
String handlerPackage = "org.springframework.boot.loader";
URL.setURLStreamHandlerFactory(protocol -> {
    if ("jar".equals(protocol)) {
        return new Handler();
    }
    return null;
});
```

## 五、Spring Boot 3.x 的优化

Spring Boot 3.x 对 Loader 进行了重大重构：

### 5.1 不再默认打包 Loader 类

Spring Boot 3.x 引入了 **精简 JAR**（Layered JAR）支持，Loader 类不再默认嵌入到 FatJar 中，而是通过 `spring-boot-loader` 模块独立提供：

```
# build.gradle 或 pom.xml 中声明
implementation 'org.springframework.boot:spring-boot-loader'
```

### 5.2 支持索引文件加速

Spring Boot 3.x 支持在 JAR 包中包含 `BOOT-INF/classpath.idx` 索引文件，加速类路径加载：

```
- "BOOT-INF/lib/spring-core-6.0.0.jar"
- "BOOT-INF/lib/spring-context-6.0.0.jar"
- "BOOT-INF/lib/spring-beans-6.0.0.jar"
- "BOOT-INF/lib/spring-boot-3.2.0.jar"
...
```

### 5.3 Layered JAR（分层JAR）

Spring Boot 3.x 通过 Docker 分层构建实现更高效的镜像缓存：

| 层 | 内容 | 缓存特性 |
|---|---|---|
| `dependencies` | 未变更的第三方依赖 | 极少变化，可长期缓存 |
| `spring-boot-loader` | Spring Boot Loader 类 | 版本升级时变化 |
| `snapshot-dependencies` | SNAPSHOT 依赖 | 频繁变化 |
| `application` | 应用自身代码和配置 | 每次构建变化 |

通过分层，Docker 构建时可以复用缓存层，加速 CI/CD：

```dockerfile
# 分层 Dockerfile
FROM eclipse-temurin:21-jre
ARG JAR_FILE=target/*.jar
COPY ${JAR_FILE} app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
```

## 六、FatJar 打成过程（简要）

`spring-boot-maven-plugin` 的 `repackage` 目标执行过程：

```
1. 先用 maven-jar-plugin 打包普通 JAR（含编译后的 classes）
2. 解压原始 JAR
3. 将 BOOT-INF/classes/ 和 BOOT-INF/lib/ 重新打包
4. 将 Spring Boot Loader 类写入 org/springframework/boot/loader/
5. 生成 MANIFEST.MF（Main-Class 指向 JarLauncher）
6. 合并成一个 FatJar
```

```xml
<!-- pom.xml -->
<plugin>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-maven-plugin</artifactId>
    <configuration>
        <mainClass>com.example.demo.DemoApplication</mainClass>
        <layers>
            <enabled>true</enabled> <!-- 启用分层打包 -->
        </layers>
    </configuration>
</plugin>
```

## 七、常见面试追问

### Q1：FatJar 中的依赖冲突怎么处理？

Spring Boot Starter 通过 **版本管控**（`spring-boot-dependencies` BOM）来统一管理依赖版本，大幅减少冲突。如果仍然有冲突，可通过 `maven-enforcer-plugin` 检查或使用 `maven-shade-plugin` 的 `relocation` 功能。

### Q2：能不能用原生 `java -jar` 执行普通 Spring Boot 项目？

可以，但需要手动指定 classpath：
```bash
java -cp "target/classes:target/dependency/*" com.example.demo.DemoApplication
```

### Q3：Spring Boot 3.x 启动变快的原因之一？

除了 GraalVM Native Image，Spring Boot 3.x 在 Loader 层面引入了 **并行类加载** 和 **索引文件**，减少 IO 开销。同时 `@SpringBootApplication` 的自动配置也做了惰性初始化优化。

### Q4：Docker 部署时用 FatJar 好还是解压后运行好？

解压后运行更好，可以实现：
- **镜像分层缓存**：只有应用层变化时只需推送一层
- **启动更快**：无需从嵌套 JAR 中读取类文件

```dockerfile
# 推荐的生产 Dockerfile
FROM eclipse-temurin:21-jre
WORKDIR /app
ARG APP_VERSION=1.0.0
COPY target/${APP_VERSION}/dependencies/ ./
COPY target/${APP_VERSION}/spring-boot-loader/ ./
COPY target/${APP_VERSION}/snapshot-dependencies/ ./
COPY target/${APP_VERSION}/application/ ./
ENTRYPOINT ["java", "org.springframework.boot.loader.JarLauncher"]
```

## 八、总结

| 维度 | 要点 |
|---|---|
| **核心原理** | 通过自定义 `LaunchedURLClassLoader` 和嵌套 JAR URL 协议处理器，让 JVM 可以加载 FatJar 内部嵌套的第三方 JAR |
| **启动流程** | JVM → JarLauncher.main() → 构造Archive → 创建自定义ClassLoader → 反射调用 Start-Class.main() |
| **类加载顺序** | 先自己加载（findClass），再委托给父加载器（与双亲委派相反） |
| **3.x 优化** | 分层打包、索引文件加速、Loader 独立模块 |
| **生产部署** | 推荐解压分层部署 + Docker 分层构建 |

理解 Spring Boot FatJar 的工作原理，不仅有助于排查启动异常问题，还能帮你在构建、部署和 DevOps 流程中做出更优的技术决策。
