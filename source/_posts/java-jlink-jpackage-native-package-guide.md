---
title: 【Java进阶】jlink + jpackage 构建轻量级可执行 Java 应用：从模块化到原生安装包
date: 2026-07-25 08:00:00
tags:
  - Java
  - jlink
  - jpackage
  - 模块化
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java进阶】jlink + jpackage 构建轻量级可执行 Java 应用：从模块化到原生安装包

## 前言

「你的 Java 程序运行需要安装 JDK 吗？」

这是 Java 桌面应用和 CLI 工具分发时最常被问到的问题。传统的解决方案（exe4j、Launch4j、install4j）要么依赖第三方工具，要么仍然需要用户安装 JRE。

JDK 9 引入的 **jlink** 和 JDK 14 引入的 **jpackage**（孵化至 JDK 16 转正）彻底改变了这一局面——它们让你能 **裁剪最小运行时 + 打包原生安装包**，用户不需要预装任何 JDK/JRE。

> **一句话总结：** jlink 裁出最小 JRE，jpackage 打包成原生安装包（exe/dmg/pkg/deb/rpm）。

---

## 一、先搞懂 Java 模块化（JPMS）

jlink 的前提是 **模块化应用**。你需要先理解 Java Platform Module System（JPMS）。

### 1.1 什么是模块？

模块是比 package 更高一层的封装单位，通过 `module-info.java` 定义：

```java
// module-info.java
module com.example.myapp {
    requires java.sql;          // 依赖模块
    requires java.logging;
    exports com.example.myapp.api;  // 对外暴露的包
}
```

### 1.2 JDK 本身就是模块化的

JDK 9+ 的 rt.jar 被拆分为几十个模块：

```
java.base      — String、集合、I/O 等核心类
java.sql       — JDBC API
java.xml       — DOM、SAX、StAX、XPath
java.desktop   — Swing/AWT
java.logging   — java.util.logging
jdk.unsupported — sun.misc.Unsafe
```

未声明的模块不会链接到你的应用中——这正是 jlink 裁剪的基础。

---

## 二、jlink：裁剪出最小化 JRE

### 2.1 基本概念

jlink 将 **你应用的模块 + 其传递依赖的 JDK 模块** 组装成一个自定义运行时镜像，只包含必需的模块。

```bash
# 传统 JDK 完整大小：约 300-500MB
# jlink 裁剪后：可压缩到 30-50MB
```

### 2.2 实战：构建一个最小 CLI 应用

#### 第一步：创建模块化项目

目录结构：
```
myapp/
├── src/
│   └── com.example.myapp/
│       ├── module-info.java
│       └── com/example/myapp/
│           └── Main.java
```

```java
// module-info.java
module com.example.myapp {
    requires java.logging;
    exports com.example.myapp;
}

// Main.java
package com.example.myapp;

import java.util.logging.Logger;

public class Main {
    private static final Logger LOG = Logger.getLogger(Main.class.getName());

    public static void main(String[] args) {
        LOG.info("Hello from modularized Java app!");
        System.out.println("Java version: " + Runtime.version());
    }
}
```

#### 第二步：编译

```bash
# 编译所有源文件
javac -d out --module-source-path src \
    src/com.example.myapp/module-info.java \
    src/com.example.myapp/com/example/myapp/Main.java
```

#### 第三步：使用 jlink 裁剪运行时

```bash
jlink --module-path out:$JAVA_HOME/jmods \
      --add-modules com.example.myapp \
      --output myapp-runtime \
      --strip-debug \
      --compress=2 \
      --no-header-files \
      --no-man-pages
```

**参数说明：**

| 参数 | 作用 |
|------|------|
| `--module-path` | 指定模块路径（应用类 + JDK jmods） |
| `--add-modules` | 要包含的模块（jlink 会自动推导依赖） |
| `--output` | 输出目录 |
| `--strip-debug` | 去除调试信息，减小体积 |
| `--compress=2` | ZIP 级别压缩（0-2） |
| `--no-header-files` | 不包含 C 头文件 |
| `--no-man-pages` | 不包含 man 手册 |

#### 第四步：运行

```bash
./myapp-runtime/bin/java --module com.example.myapp
# 输出：Hello from modularized Java app!
```

### 2.3 查看裁剪效果

```bash
# 对比大小
du -sh $JAVA_HOME
# 完整 JDK：≈ 350MB

du -sh myapp-runtime
# 裁剪后：≈ 38MB（90% 缩减！）

# 查看包含的模块
./myapp-runtime/bin/java --list-modules
```

### 2.4 高级用法

#### 自定义启动命令

```bash
jlink --module-path out:$JAVA_HOME/jmods \
      --add-modules com.example.myapp \
      --output myapp-runtime \
      --launcher myapp=com.example.myapp
```

生成后：

```bash
./myapp-runtime/bin/myapp
# 直接启动，效果等于 java --module com.example.myapp
```

#### 包含更多工具

```bash
jlink --module-path out:$JAVA_HOME/jmods \
      --add-modules com.example.myapp,jdk.management,jdk.jcmd \
      --output myapp-runtime
```

这样镜像中会包含 `jcmd`、`jconsole` 等监控工具。

#### 排除不必要的资源

```bash
jlink ... \
      --strip-java-debug-attributes \
      --vm=server \        # 指定 VM（server/client/minimal）
      --endian little      # 字节序
```

---

## 三、jpackage：打包原生安装包

jlink 把运行时裁剪好了，但用户还是需要解压和配置。jpackage 更进一步——**生成双击即可安装的原生安装包**。

### 3.1 支持的格式

| 平台 | 安装包格式 |
|------|-----------|
| Windows | exe、msi |
| macOS | dmg、pkg |
| Linux | deb、rpm |

### 3.2 基本用法

```bash
# 先编译好模块化应用
javac -d out --module-source-path src -m com.example.myapp

# jpackage 打包
jpackage --module-path out:$JAVA_HOME/jmods \
         --module com.example.myapp \
         --name MyApp \
         --app-version 1.0.0 \
         --vendor "东哥" \
         --output dist
```

对于 Linux：

```bash
# 生成 deb 包
jpackage --module-path out:$JAVA_HOME/jmods \
         --module com.example.myapp \
         --name myapp \
         --app-version 1.0.0 \
         --linux-deb-maintainer "dev@example.com" \
         --linux-shortcut \
         --output dist
```

### 3.3 桌面应用图标

```bash
jpackage ... \
         --icon app-icon.png \
         --resource-dir resources/
```

### 3.4 包含额外的资源文件

```bash
jpackage ... \
         --input extra-files/ \
         --add-modules java.sql \
         --java-options "-Xmx256m -Dconfig=/opt/myapp/config.yml"
```

### 3.5 macOS 专属

```bash
jpackage --module-path out:$JAVA_HOME/jmods \
         --module com.example.myapp \
         --name MyApp \
         --app-version 1.0.0 \
         --icon myapp.icns \
         --mac-sign \
         --mac-signing-key-user-name "Developer ID" \
         --mac-package-identifier com.example.myapp
```

---

## 四、实战：构建一个完整的数据库工具桌面应用

### 4.1 项目结构

```
db-tool/
├── src/
│   └── com.example.dbtool/
│       ├── module-info.java
│       └── com/example/dbtool/
│           ├── Main.java
│           ├── ui/
│           │   └── MainFrame.java
│           └── db/
│               └── DatabaseManager.java
├── icon.png
└── build.sh
```

### 4.2 module-info.java

```java
module com.example.dbtool {
    requires java.sql;                    // JDBC
    requires java.desktop;                // Swing
    requires java.logging;
    requires jdk.crypto.ec;               // 加密模块（MySQL 需要）

    exports com.example.dbtool;
}
```

### 4.3 构建脚本

```bash
#!/bin/bash
set -e

APP_NAME="DBTool"
VERSION="1.0.0"
MODULE="com.example.dbtool"
MAIN_CLASS="com.example.dbtool.Main"

# 清空输出
rm -rf out dist runtime app

# 编译
javac -d out --module-source-path src \
    $(find src -name "*.java")

# jlink 裁剪运行时
jlink --module-path out:$JAVA_HOME/jmods \
      --add-modules $MODULE \
      --output runtime \
      --strip-debug \
      --compress=2 \
      --no-header-files \
      --no-man-pages

echo "Runtime size: $(du -sh runtime | cut -f1)"

# jpackage 打包
jpackage --runtime-image runtime \
         --module $MODULE/$MAIN_CLASS \
         --name $APP_NAME \
         --app-version $VERSION \
         --icon icon.png \
         --vendor "东哥" \
         --linux-shortcut \
         --output dist

echo "Package created: dist/"
ls -lh dist/
```

### 4.4 执行效果

```bash
# 构建
chmod +x build.sh && ./build.sh
# Runtime size: 42M
# Package created: dist/
# -rw-r--r--  dist/DBTool_1.0.0-1_amd64.deb  15M

# 安装
sudo dpkg -i dist/DBTool_1.0.0-1_amd64.deb

# 运行（现在可以在应用菜单中找到 DBTool，或直接命令）
dbtool
```

> **注意：** 用户机器上不需要任何 JDK/JRE！

---

## 五、非模块化应用也能用 jlink/jpackage

如果你的项目还没模块化，可以通过 **`--add-modules ALL-MODULE-PATH`** 或结合第三方工具（如 jdeps）来实现：

```bash
# 用 jdeps 分析依赖
jdeps --module-path lib/*.jar -cp lib/*.jar --list-deps myapp.jar

# 根据分析结果创建自定义模块
jlink --module-path $JAVA_HOME/jmods:custom-modules \
      --add-modules java.base,java.sql,java.logging \
      --output runtime
```

或者直接使用 `jpackage` 的 `--input` + `--main-jar` 方式（非模块化也支持）：

```bash
jpackage --input lib/ \
         --main-jar myapp.jar \
         --main-class com.example.Main \
         --name MyApp \
         --app-version 1.0 \
         --output dist
```

---

## 六、常见问题与避坑

### 6.1 jlink 报 "Module X not found"

```bash
# 错误：Error: Module java.xml not found
# 解决：检查 --module-path 是否包含 $JAVA_HOME/jmods
jlink --module-path out:$JAVA_HOME/jmods ...
```

### 6.2 ClassNotFoundException for JDK 内部类

如果代码直接使用了 `sun.*` 等内部 API：

```bash
# 需要添加 jdk.unsupported 模块
jlink --add-modules jdk.unsupported ...
```

### 6.3 缺少加密模块

```bash
# MySQL 驱动需要
jlink --add-modules jdk.crypto.ec,jdk.crypto.cryptoki ...
```

### 6.4 runtime-image 路径

jpackage 的 `--runtime-image` 必须是 **jlink 生成的完整运行时**，不能直接指向 JDK 目录。

### 6.5 跨平台打包

jpackage **不支持跨平台**——在 Linux 上只能生成 deb/rpm，在 Windows 上生成 exe/msi。

---

## 七、性能与体积对比

| 分发方案 | 体积 | 用户要求 | 构建复杂度 |
|---------|------|---------|-----------|
| 原始 jar + 用户自装 JDK | 1-2MB | 需安装 JDK/JRE | 低 |
| jlink 自定义运行时 | 30-50MB | 无需安装 | 中 |
| jlink + jpackage 安装包 | 15-30MB（压缩） | 无需安装 | 中高 |
| GraalVM Native Image | 5-15MB | 无需安装 | 高（约束多） |
| Docker 容器 | 150-300MB | 需 Docker | 低 |

> **建议：** CLI 工具用 jlink + 压缩分发；桌面应用用 jlink + jpackage；云原生场景用 Docker + jlink 基础镜像。

---

## 八、面试追问

> **Q：jlink 和 Docker 的区别是什么？**
> A：jlink 在编译期裁剪 JDK 模块生成最小运行时，适合桌面/CLI 分发；Docker 是容器化运行环境，适合服务端部署。两者可以结合——用 jlink 制作极简 Docker 镜像。

> **Q：jlink 出来的镜像能跑所有 Java 应用吗？**
> A：不能。jlink 只包含你指定模块及其依赖的模块。如果应用通过反射、SPI 或 Class.forName 动态加载类，需要手动添加对应模块。

> **Q：jpackage 生成的安装包和 exe4j 比怎么样？**
> A：jpackage 是官方工具，免费、开箱即用，但图标定制和高级安装逻辑略逊于商业工具。对于标准桌面应用完全够用。

> **Q：Spring Boot 能用 jlink 吗？**
> A：可以。Spring Boot 3.x 对 JPMS 支持良好，使用 Spring Boot Maven/Gradle 插件 + 自定义模块描述即可。需注意反射和动态代理的模块导出配置。

---

## 总结

| 工具 | 核心能力 | 适用阶段 |
|------|---------|---------|
| **jlink** | 裁剪 JDK 模块，生成最小运行时 | 构建阶段 |
| **jpackage** | 将应用+运行时打包为原生安装包 | 分发阶段 |

两者结合，让你彻底摆脱「Java 应用必须先装 JDK」的尴尬，实现真正的 **一次构建，随处运行（无需预装环境）**。

**最佳实践：**
1. 优先使用模块化设计，明确 module-info.java
2. jlink 时用 `--strip-debug --compress=2 --no-header-files` 最小化体积
3. jpackage 时配置合适的图标和应用信息
4. CI/CD 中为每个平台单独构建

从今天开始，让你的 Java 应用像原生软件一样分发和安装吧！
