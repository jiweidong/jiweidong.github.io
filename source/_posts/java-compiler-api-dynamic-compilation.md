---
title: 【Java进阶】Java Compiler API 动态编译深度实战：从 javax.tools 到运行时代码生成
date: 2026-08-02 08:00:00
tags:
  - Java
  - 动态编译
  - JVM
  - 实战
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java进阶】Java Compiler API 动态编译深度实战：从 javax.tools 到运行时代码生成

## 面试官：JSP 第一次被访问时，Tomcat 是怎么把它变成 Servlet 的？运行中的 Java 程序能编译并加载新代码吗？

答案是：**Java 官方提供了完整的 Compiler API（`javax.tools`），允许程序在运行时调用 JDK 内置编译器 javac，把字符串或内存中的 Java 源码编译成字节码，再通过自定义 ClassLoader 加载执行。** JSP 引擎、Groovy 脚本引擎、规则引擎、在线判题系统（OJ）、低代码平台，背后都离不开这套机制。

本篇文章从原理到源码，带你彻底掌握 Java 动态编译的完整链路。

## 一、动态编译的三种方案对比

在深入 Compiler API 之前，先看全景——Java 世界实现"运行时编译并执行"的主流方案：

| 方案 | 原理 | 优点 | 缺点 | 典型场景 |
|------|------|------|------|---------|
| **Compiler API（javax.tools）** | 调用内置 javac 编译源码字符串 | 零第三方依赖、兼容所有 JDK 语法、字节码与 javac 一致 | 编译有开销、需要管理 ClassLoader | JSP、规则引擎、在线判题 |
| **Java 表达式引擎（SpEL / Aviator / QLExpress）** | 解释执行表达式 | 轻量、安全沙箱好做 | 只适合表达式，不适合完整类 | 规则表达式、配置计算 |
| **字节码生成（ASM / Byte Buddy / CGLIB）** | 直接操作字节码 | 性能最高 | 复杂、难维护 | 框架底层（Spring、MyBatis） |

三者的关系：**表达式引擎解决"算"的问题，字节码生成解决"性能极致"的问题，而 Compiler API 解决"让用户写完整 Java 代码"的问题**——它是三者中唯一能编译任意合法 Java 源码的方案。

## 二、Compiler API 核心类解析

`javax.tools` 包下的核心组件：

```
ToolProvider                       — 获取系统 JavaCompiler
    └─ getSystemJavaCompiler()     — 返回 javac 实例（JDK 环境才有）
JavaCompiler                       — 编译器入口接口
    └─ getTask(...)                — 创建编译任务 CompilationTask
JavaCompiler.CompilationTask       — 一次编译任务（可调用多次？不，一次性的）
JavaFileManager                    — 管理源文件/类文件的读写
    └─ StandardJavaFileManager     — 标准文件管理器（操作磁盘文件）
JavaFileObject                     — 源码/字节码的抽象（文件 or 内存）
    └─ SimpleJavaFileObject        — 便捷基类，可包装内存字符串
DiagnosticCollector                — 收集编译错误/警告
```

**关键设计思想**：Compiler API 是"面向文件的抽象"。默认的 `StandardJavaFileManager` 从磁盘读 `.java` 文件、把 `.class` 写到磁盘；但只要实现自定义的 `JavaFileManager` + `JavaFileObject`，就能实现**源码和字节码全部驻留内存**——这正是"动态编译不落盘"的核心技巧。

## 三、入门：编译内存中的源码字符串

### 1. 核心工具类：内存中的 JavaFileObject

```java
import javax.tools.*;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.net.URI;

/**
 * 内存中的 Java 源文件对象：源码以字符串形式提供
 */
public class StringJavaSource extends SimpleJavaFileObject {
    private final String code;

    public StringJavaSource(String className, String code) {
        super(URI.create("string:///" + className.replace('.', '/') + Kind.SOURCE.extension),
              Kind.SOURCE);
        this.code = code;
    }

    @Override
    public CharSequence getCharContent(boolean ignoreEncodingErrors) {
        return code;
    }
}

/**
 * 内存中的 Class 文件对象：编译器把字节码写进这个对象
 */
public class MemoryJavaClass extends SimpleJavaFileObject {
    private final ByteArrayOutputStream bos = new ByteArrayOutputStream();

    public MemoryJavaClass(String className) {
        super(URI.create("string:///" + className.replace('.', '/') + Kind.CLASS.extension),
              Kind.CLASS);
    }

    @Override
    public OutputStream openOutputStream() {
        return bos;
    }

    public byte[] getBytes() {
        return bos.toByteArray();
    }
}
```

### 2. 自定义 JavaFileManager：编译产物不落盘

```java
import javax.tools.*;
import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class MemoryFileManager extends ForwardingJavaFileManager<StandardJavaFileManager> {

    /** className -> 字节码 */
    private final Map<String, MemoryJavaClass> classes = new ConcurrentHashMap<>();

    public MemoryFileManager(StandardJavaFileManager standardManager) {
        super(standardManager);
    }

    @Override
    public JavaFileObject getJavaFileForOutput(JavaFileManager.Location location,
                                               String className,
                                               JavaFileObject.Kind kind,
                                               FileObject sibling) {
        MemoryJavaClass memClass = new MemoryJavaClass(className);
        classes.put(className, memClass);
        return memClass;
    }

    public Map<String, byte[]> getAllClasses() {
        Map<String, byte[]> result = new ConcurrentHashMap<>();
        classes.forEach((name, obj) -> result.put(name, obj.getBytes()));
        return result;
    }
}
```

### 3. 动态编译 + 加载 + 执行全流程

```java
import javax.tools.*;
import java.lang.reflect.Method;
import java.util.*;

public class DynamicCompiler {

    public static Class<?> compileAndLoad(String className, String sourceCode) throws Exception {
        // 1. 获取系统编译器（必须是 JDK 环境，JRE 没有）
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            throw new IllegalStateException("当前环境不是 JDK，无法获取 javac");
        }

        // 2. 构建编译任务
        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        try (StandardJavaFileManager stdManager = compiler.getStandardFileManager(diagnostics, null, null);
             MemoryFileManager fileManager = new MemoryFileManager(stdManager)) {

            JavaFileObject source = new StringJavaSource(className, sourceCode);
            JavaCompiler.CompilationTask task =
                    compiler.getTask(null, fileManager, diagnostics, null, null, List.of(source));

            // 3. 执行编译
            Boolean success = task.call();
            if (!success) {
                // 收集并打印所有编译错误
                StringBuilder sb = new StringBuilder("编译失败：\n");
                for (Diagnostic<? extends JavaFileObject> d : diagnostics.getDiagnostics()) {
                    sb.append(d.getKind()).append(": line ").append(d.getLineNumber())
                      .append(" -> ").append(d.getMessage(null)).append('\n');
                }
                throw new IllegalArgumentException(sb.toString());
            }

            // 4. 用自定义 ClassLoader 加载字节码
            Map<String, byte[]> classes = fileManager.getAllClasses();
            return new MemoryClassLoader(classes).loadClass(className);
        }
    }

    /** 从内存字节码加载类的 ClassLoader */
    static class MemoryClassLoader extends ClassLoader {
        private final Map<String, byte[]> classes;

        MemoryClassLoader(Map<String, byte[]> classes) {
            super(Thread.currentThread().getContextClassLoader());
            this.classes = classes;
        }

        @Override
        protected Class<?> findClass(String name) throws ClassNotFoundException {
            byte[] bytes = classes.get(name);
            if (bytes == null) {
                throw new ClassNotFoundException(name);
            }
            return defineClass(name, bytes, 0, bytes.length);
        }
    }

    public static void main(String[] args) throws Exception {
        String source = """
                package demo;
                public class HelloDynamic {
                    public static String greet(String name) {
                        return "Hello, " + name + "! 动态编译成功。";
                    }
                }
                """;

        Class<?> clazz = compileAndLoad("demo.HelloDynamic", source);
        Method greet = clazz.getMethod("greet", String.class);
        System.out.println(greet.invoke(null, "东哥"));
        // 输出: Hello, 东哥! 动态编译成功。
    }
}
```

**整个流程四步走**：取编译器 → 建任务（内存文件管理器接管输入输出）→ 编译（诊断收集器捕获错误）→ 自定义 ClassLoader 加载字节码。全程**不产生任何磁盘文件**。

## 四、进阶实战：动态编译"运行时代码生成"

### 场景：低代码平台动态生成 DTO

假设低代码平台允许用户拖拽配置字段，运行时自动生成并编译一个 Java Bean：

```java
public class RuntimeClassGenerator {

    public static String generateDto(String className, Map<String, String> fields) {
        StringBuilder sb = new StringBuilder();
        sb.append("package generated;\n\n");
        sb.append("public class ").append(className).append(" {\n");
        for (Map.Entry<String, String> e : fields.entrySet()) {
            sb.append("    private ").append(e.getValue()).append(' ')
              .append(e.getKey()).append(";\n");
        }
        sb.append("    public ").append(className).append("() {}\n\n");
        for (Map.Entry<String, String> e : fields.entrySet()) {
            String f = e.getKey();
            String type = e.getValue();
            String cap = Character.toUpperCase(f.charAt(0)) + f.substring(1);
            sb.append("    public ").append(type).append(" get").append(cap)
              .append("() { return ").append(f).append("; }\n");
            sb.append("    public void set").append(cap).append('(')
              .append(type).append(' ').append(f)
              .append(") { this.").append(f).append(" = ").append(f).append("; }\n");
        }
        sb.append("}\n");
        return sb.toString();
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("id", "Long");
        fields.put("orderNo", "String");
        fields.put("amount", "java.math.BigDecimal");

        String code = generateDto("OrderDTO", fields);
        Class<?> clazz = DynamicCompiler.compileAndLoad("generated.OrderDTO", code);
        Object dto = clazz.getDeclaredConstructor().newInstance();
        System.out.println("生成并加载成功: " + clazz.getName());
        System.out.println("字段数量: " + clazz.getDeclaredFields().length);
    }
}
```

### 注意事项：ClassLoader 与类隔离

这是动态编译最容易踩的坑：

1. **每次编译新代码必须用新的 ClassLoader**，否则 `defineClass` 会抛 `LinkageError`（同名类已加载）；
2. **父子 ClassLoader 委托**：`MemoryClassLoader` 的 parent 应设为当前线程的 ContextClassLoader，保证动态类能访问业务代码；反之，要让动态代码**隔离**（如插件系统），则 parent 要精心设计，甚至实现"先自己找、找不到再委托"的破坏双亲委派；
3. **缓存管理**：动态类持有静态状态时会阻止类卸载，插件热更新场景需要定期替换 ClassLoader 并配合 `-XX:+UnlockDiagnosticVMOptions -XX:+LogUnloading` 观察卸载。

## 五、编译选项与错误诊断

### 常用编译选项（options 参数）

```java
List<String> options = Arrays.asList(
    "-encoding", "UTF-8",          // 源码编码
    "-source", "17",               // 源码版本
    "-target", "17",               // 目标字节码版本
    "-classpath", System.getProperty("java.class.path"),
    "-Xlint:all"                   // 打开全部警告
);
```

### 错误诊断的完整用法

```java
DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
// ... 执行编译后
for (Diagnostic<? extends JavaFileObject> d : diagnostics.getDiagnostics()) {
    System.out.printf("%s at line %d, column %d: %s%n",
            d.getKind(),              // ERROR / WARNING / MANDATORY_WARNING
            d.getLineNumber(),
            d.getColumnNumber(),
            d.getMessage(Locale.CHINA)); // 本地化错误消息
}
```

注意：`javac` 是**整类编译**的，一个类的语法错误会导致整次 `task.call()` 返回 false，所以诊断收集器必须完整展示所有错误给用户。

## 六、性能优化：复用编译器与并行编译

### 1. 复用 JavaCompiler 实例

`ToolProvider.getSystemJavaCompiler()` 每次调用开销不小。编译器实例是**线程安全可复用**的，建议单例持有：

```java
public enum CompilerHolder {
    INSTANCE;
    private final JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();

    public JavaCompiler get() { return compiler; }
}
```

### 2. 编译开销到底多大？

一次简单类（几十行）的编译 + 加载，实测大约 **5~30ms**（取决于机器与类复杂度）。这比反射调用慢 2~3 个数量级，所以：

- **绝不能在热路径上逐次编译**（如每次 HTTP 请求都编译）；
- 正确姿势是**编译一次、缓存 Class**，key 可以是源码的 hash（SHA-256）；
- 大批量编译时可用 `Executors.newFixedThreadPool` + 每个线程独立的内存文件管理器并行编译，但要小心共享 `-classpath` 的并发读（只读安全）。

### 3. 源码 hash 缓存示例

```java
public class CompileCache {
    private static final Map<String, Class<?>> CACHE = new ConcurrentHashMap<>();

    public static Class<?> compile(String className, String source) throws Exception {
        String key = className + "#" + sha256(source);
        Class<?> cached = CACHE.get(key);
        if (cached != null) return cached;
        Class<?> clazz = DynamicCompiler.compileAndLoad(className, source);
        CACHE.put(key, clazz);          // 注意：相同源码产生新 Class 时用新 ClassLoader
        return clazz;
    }

    private static String sha256(String s) throws Exception {
        var md = java.security.MessageDigest.getInstance("SHA-256");
        return java.util.HexFormat.of().formatHex(md.digest(s.getBytes()));
    }
}
```

> 坑提醒：源码不变但想**重新加载**（比如"重置"场景）时，缓存反而有害——此时要绕过缓存强制新建 ClassLoader。

## 七、真实世界中的应用

| 应用 | 如何使用 Compiler API |
|------|----------------------|
| **JSP 引擎（Tomcat）** | JSP 第一次请求时被翻译成 Servlet 源码，用 javac 编译成 class 后加载，之后复用（这就是 JSP 首访慢的原因） |
| **Groovy / Kotlin 脚本** | 脚本引擎底层是各自编译器，原理与 Compiler API 一致 |
| **在线判题系统（OJ）** | 用户提交 Java 源码 → 沙箱内编译 → 运行比对输出 |
| **规则引擎** | 把规则编译成 Java 类，比解释执行快一个数量级 |
| **低代码平台** | 拖拽配置生成实体/DTO/服务类，运行时编译加载 |
| **MyBatis 等框架** | 虽用字节码库为主，但部分 SQL 拼接场景也采用动态编译思路 |

## 八、面试官追问环节

**Q1：Compiler API 和反射、字节码生成（ASM）有什么区别？**
答：反射操作的是**已加载的类**；ASM/Byte Buddy 操作的是**字节码二进制**，性能最高但门槛高；Compiler API 输入的是**Java 源码字符串**，能编译任何合法 Java 语法（包括 lambda、record、switch 表达式等新语法），对使用者最友好，代价是编译耗时。三者是不同抽象层级：源码 → 字节码 → 运行时对象。

**Q2：为什么 JRE 环境下 ToolProvider.getSystemJavaCompiler() 返回 null？**
答：因为 javac 实现在 JDK 的 `jdk.compiler` 模块中，JRE（不含编译器）没有这个模块。所以**使用 Compiler API 的应用必须运行在完整 JDK 上**，或者把 `jdk.compiler` 模块打进运行时镜像（jlink）。这也是很多容器镜像用 JRE 导致动态编译报 NPE 的原因——排查方向先看基础镜像是不是 full JDK。

**Q3：动态编译的类如何实现热更新？**
答：核心是**类卸载依赖 ClassLoader 回收**。每次新版本用新的 ClassLoader 加载，旧的 ClassLoader 在无引用后被 GC 回收，其加载的类才能被卸载。前提是旧类没有静态字段强引用、没有线程持有其 Class 引用。生产上可配合版本号管理 ClassLoader 池，并监控 Metaspace 是否持续增长。

**Q4：动态编译有什么安全风险？**
答：让用户提交源码等于让用户执行任意代码（RCE）。生产环境必须：① 在隔离沙箱（如独立的受限进程、容器、SecurityManager 替代方案）中编译运行；② 对源码做静态扫描（禁用 `System`、`Runtime`、反射逃逸等危险 API）；③ 限制编译产物大小、超时与资源配额。**永远不要在生产主进程里编译执行不可信源码。**

## 九、总结

- Compiler API 让你在运行时获得**完整 javac 能力**，输入源码字符串、输出内存字节码；
- 核心四件套：`ToolProvider`（取编译器）、`CompilationTask`（编译任务）、`JavaFileManager`（接管输入输出）、`DiagnosticCollector`（错误收集）；
- 加载动态类必须配合**自定义 ClassLoader**，热更新 = 换 ClassLoader；
- 性能上**编译一次、缓存复用**，编译器实例可单例共享；
- 安全上对不可信源码必须沙箱隔离。

掌握了动态编译，你就理解了 JSP、脚本引擎、低代码平台这些"运行时代码生成"技术的共同底座——这也是高级 Java 工程师区分度很高的一个知识点。
