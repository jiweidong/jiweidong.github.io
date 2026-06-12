---
title: JVM 类加载机制详解
date: 2026-06-13 16:00:00
tags:
  - JVM
  - 类加载
  - 双亲委派
  - ClassLoader
  - 字节码
categories: JVM
---

# JVM 类加载机制详解

## 一、引言

Java 语言之所以能够实现"一次编写，到处运行"（Write Once, Run Anywhere），核心支柱之一就是 JVM 的类加载机制（Class Loading Mechanism）。类加载器（ClassLoader）负责将 `.class` 字节码文件加载到 JVM 内存中，并为之生成对应的 `java.lang.Class` 对象。理解类加载机制，不仅是深入 JVM 的必经之路，更是解决生产环境中各种类冲突、NoClassDefFoundError、ClassNotFoundException 等疑难杂症的关键。

本文将从类加载的生命周期、ClassLoader 层次结构、双亲委派模型、打破双亲委派、自定义 ClassLoader、类卸载等方面，全面深入地剖析 JVM 类加载机制。

---

## 二、类加载的生命周期

一个类从被加载到 JVM 内存中，到最终被卸载，完整经历以下 **七个阶段**：

```
加载 → 验证 → 准备 → 解析 → 初始化 → 使用 → 卸载
├── 链接（Linking）───┤
├────── 类加载过程 ──────┤
```

其中 **验证、准备、解析** 三个阶段统称为 **链接（Linking）**。而 **加载、验证、准备、初始化** 这四个阶段的顺序是固定的，**解析** 阶段在某些情况下可以在初始化之后开始（为了支持 Java 的运行时绑定 / 动态绑定，即晚期绑定）。

### 2.1 加载（Loading）

加载是类加载的**第一个阶段**，JVM 需要完成三件事：

1. 通过类的**全限定名**（Fully Qualified Name）获取定义此类的二进制字节流
2. 将字节流所代表的静态存储结构转化为方法区的运行时数据结构
3. 在内存中生成一个代表该类的 `java.lang.Class` 对象，作为方法区这个类的各种数据的访问入口

> **关键点**：获取二进制字节流的方式非常灵活，不限于从 `.class` 文件读取：
> - 从 ZIP/JAR/WAR 包读取
> - 从网络获取（如 Applet）
> - 运行时动态生成（如动态代理、CGLib、ASM）
> - 由其他文件生成（如 JSP 转 Servlet）
> - 从数据库读取

加载阶段完成后，JVM 外部（即 Java 应用层）可以通过 **自定义 ClassLoader** 参与加载过程。

### 2.2 验证（Verification）

验证是链接阶段的第一步，目的是**确保 Class 文件的字节流中包含的信息符合 JVM 规范**，不会危害 JVM 自身安全。

验证阶段大致分为四个检验动作：

| 验证类型 | 说明 | 示例检查 |
|---------|------|---------|
| 文件格式验证 | 检查字节流是否符合 Class 文件格式规范 | 是否以魔数 `0xCAFEBABE` 开头，主次版本号是否在当前 JVM 可接受范围 |
| 元数据验证 | 对字节码描述的信息进行语义分析 | 该类是否有父类（除 Object 外），是否继承了被 final 修饰的类 |
| 字节码验证 | 通过数据流和控制流分析，确定程序语义合法且符合逻辑 | 保证操作数栈类型与指令序列匹配，保证跳转指令不会跳到方法体外 |
| 符号引用验证 | 对常量池中的符号引用进行匹配性校验 | 通过全限定名是否能找到对应的类、字段、方法 |

> 在生产环境中，可以通过 `-Xverify:none` 或 `-noverify` 参数关闭大部分验证来提高启动速度（JDK 13 已移除该参数）。

### 2.3 准备（Preparation）

准备阶段**正式为类变量（static 修饰的变量）分配内存并设置初始值**。这些变量所使用的内存都在**方法区**中分配。

需要注意的是，这里说的"初始值"是**零值**（Zeros），而不是代码中显式赋的值。例如：

```java
public static int a = 123;
```

在准备阶段，`a` 的值为 `0`，而不是 `123`。将 `a` 赋值为 `123` 的 putstatic 指令会在**初始化阶段**执行。

但也有特殊情况：如果类字段是 `static final` 修饰的**常量**（基本类型或 String 类型），则在准备阶段就会直接赋值为用户指定的值：

```java
public static final int b = 123;  // 准备阶段直接赋值为 123
```

### 2.4 解析（Resolution）

解析阶段是 JVM 将常量池内的**符号引用**（Symbolic Reference）替换为**直接引用**（Direct Reference）的过程。

- **符号引用**：以一组符号来描述所引用的目标，可以是任何形式的字面量，只要能够无歧义地定位到目标即可。编译时 Java 类并不知道所引用的类的实际地址，因此用符号引用代替。
- **直接引用**：可以直接指向目标的指针、相对偏移量或一个能够间接定位到目标的句柄。直接引用在运行时存在，与 JVM 的内存布局直接相关。

解析动作主要针对以下 7 类符号引用：
- 类或接口（CONSTANT_Class_info）
- 字段（CONSTANT_Fieldref_info）
- 类方法（CONSTANT_Methodref_info）
- 接口方法（CONSTANT_InterfaceMethodref_info）
- 方法类型（CONSTANT_MethodType_info）
- 方法句柄（CONSTANT_MethodHandle_info）
- 调用点限定符（CONSTANT_Dynamic_info / CONSTANT_InvokeDynamic_info）

### 2.5 初始化（Initialization）

初始化是类加载过程的**最后一个步骤**。在此之前，除了加载阶段可以由自定义 ClassLoader 参与外，其余阶段完全由 JVM 主导。到了初始化阶段，才开始真正执行类中定义的 Java 程序代码（即字节码指令）。

初始化阶段会执行 `<clinit>()` 方法，它是编译器自动收集类中所有**类变量的赋值动作**和**静态语句块（static {}）** 合并生成的。

```java
public class InitExample {
    static int a = 10;          // (1)
    static int b;               // (2)
    static {
        b = 20;                 // (3) 静态代码块
    }
}
```

上述代码编译后产生的 `<clinit>()` 方法等价于：

```java
<clinit>() {
    a = 10;
    b = 20;
}
```

**何时触发初始化？** JVM 规范严格规定了 **有且仅有** 以下 6 种情况必须立即对类进行初始化（主动引用）：

1. 遇到 `new`、`getstatic`、`putstatic`、`invokestatic` 字节码指令时
2. 使用 `java.lang.reflect` 包的方法对类进行反射调用时
3. 初始化一个类时，如果其父类还没有初始化，需先触发父类初始化
4. 虚拟机启动时，包含 `main()` 方法的主类
5. `java.lang.invoke.MethodHandle` 解析结果为 `REF_getStatic`、`REF_putStatic`、`REF_invokeStatic` 时
6. 接口中定义了 `default` 方法，如果有该接口的实现类发生了初始化，则该接口需在实现类之前初始化

**不会触发初始化的情况（被动引用）：**

```java
// 示例 1：通过子类引用父类的静态字段，不会导致子类初始化
public class Parent {
    static { System.out.println("Parent init"); }
    static int value = 100;
}
public class Child extends Parent {
    static { System.out.println("Child init"); }
}
// 输出: Parent init （Child 不会初始化）

// 示例 2：通过数组定义引用类，不会触发初始化
Parent[] arr = new Parent[10];  // 不输出 "Parent init"

// 示例 3：引用常量（编译期常量传播优化到调用类的常量池）
public class Const {
    static { System.out.println("Const init"); }
    public static final String HELLO = "hello";
}
// Const.HELLO;  // 不输出 "Const init"，编译期已优化为 "hello"
```

---

## 三、ClassLoader 层次结构

JVM 中内置了三层 ClassLoader，从高到低为：

### 3.1 启动类加载器（Bootstrap ClassLoader）

- **语言实现**：C++ 实现（HotSpot），是 JVM 的一部分
- **加载路径**：`<JAVA_HOME>/lib` 目录下的核心类库（如 `rt.jar`、`resources.jar`、`charsets.jar` 等），或者被 `-Xbootclasspath` 参数指定的路径
- **可见性**：在 Java 代码中引用为 `null`，因为它是 C++ 编写的，没有对应的 Java 对象

```java
// 验证 Bootstrap ClassLoader
URL[] urls = sun.misc.Launcher.getBootstrapClassPath().getURLs();
for (URL url : urls) {
    System.out.println(url.toExternalForm());
}
// 输出: file:/usr/lib/jvm/java-8-openjdk-amd64/jre/lib/rt.jar
//       file:/usr/lib/jvm/java-8-openjdk-amd64/jre/lib/resources.jar ...
```

### 3.2 扩展类加载器（Extension ClassLoader）

- **语言实现**：`sun.misc.Launcher$ExtClassLoader`（Java 实现）
- **加载路径**：`<JAVA_HOME>/lib/ext` 目录，或被 `java.ext.dirs` 系统变量指定的路径
- **父加载器**：Bootstrap ClassLoader（其 parent 字段为 null）

> **JDK 9 后**：扩展类加载器被替换为**平台类加载器（Platform ClassLoader）**，加载目录改为模块化系统控制的区域。`rt.jar` 和 `ext` 目录被移除，取而代之的是模块化运行时镜像。

### 3.3 应用程序类加载器（Application ClassLoader）

- **语言实现**：`sun.misc.Launcher$AppClassLoader`（Java 实现）
- **加载路径**：`classpath` 或 `-classpath`、`-cp` 参数指定的路径
- **父加载器**：Extension ClassLoader
- **默认上下文**：我们写的绝大多数 Java 类都由此加载器加载，也是 `ClassLoader.getSystemClassLoader()` 的返回值

### 3.4 层次关系图

```
┌─────────────────────────────────────────────┐
│         Bootstrap ClassLoader               │ ← C++, null
│          (rt.jar / java.*)                  │
├─────────────────────────────────────────────┤
│         Extension ClassLoader               │ ← ExtClassLoader (Java)
│          (lib/ext/*.jar / javax.*)          │
├─────────────────────────────────────────────┤
│      Application ClassLoader                │ ← AppClassLoader (Java)
│        (classpath / 用户代码)               │
├─────────────────────────────────────────────┤
│      Custom ClassLoader                     │ ← 用户自定义
│        (热部署 / 加密解密 / 网络加载)       │
└─────────────────────────────────────────────┘
```

> 注意：这里的"父子关系"并不是继承关系，而是通过 `parent` 字段实现的组合关系。Extension ClassLoader 的 parent 是 Bootstrap ClassLoader（用 null 表示），Application ClassLoader 的 parent 是 Extension ClassLoader。

---

## 四、双亲委派模型（Parent Delegation Model）

### 4.1 定义

双亲委派模型要求：当一个 ClassLoader 收到类加载请求时，首先**不会自己尝试加载**，而是将请求委派给父加载器去完成，每一层都是如此。只有当父加载器无法完成加载（在其搜索范围内找不到该类）时，子加载器才会尝试自己去加载。

### 4.2 工作流程

```
ClassLoader.loadClass(name)
      │
      ├── 1. 检查该类是否已被加载 (findLoadedClass)
      │
      ├── 2. 如果父加载器存在:
      │        parent.loadClass(name)
      │         └── 递归向上委派
      │    如果父加载器不存在 (即 parent == null):
      │        引导类加载器加载 (Bootstrap ClassLoader)
      │
      └── 3. 如果父加载器抛出 ClassNotFoundException:
             当前 ClassLoader 调用 findClass(name) 自行加载
```

源码核心逻辑（`java.lang.ClassLoader.loadClass()`）：

```java
protected Class<?> loadClass(String name, boolean resolve)
        throws ClassNotFoundException {
    synchronized (getClassLoadingLock(name)) {
        // 1. 先检查是否已经加载
        Class<?> c = findLoadedClass(name);
        if (c == null) {
            try {
                if (parent != null) {
                    // 2. 委派给父加载器
                    c = parent.loadClass(name, false);
                } else {
                    // 3. 无父加载器，交给 Bootstrap ClassLoader
                    c = findBootstrapClassOrNull(name);
                }
            } catch (ClassNotFoundException e) {
                // 4. 父加载器无法加载
            }
            if (c == null) {
                // 5. 自己尝试加载
                c = findClass(name);
            }
        }
        if (resolve) {
            resolveClass(c);
        }
        return c;
    }
}
```

### 4.3 为什么使用双亲委派？

| 优势 | 说明 |
|------|------|
| **安全性** | 避免核心 API 被篡改。比如恶意自定义 `java.lang.String` 类永远不会被加载，因为 Bootstrap ClassLoader 总是优先加载 rt.jar 中的 String |
| **唯一性** | 保证同一个类在全 JVM 中**只会被加载一次**，由同一个 ClassLoader 加载。JVM 中判断两个类是否"相等"的前提是它们由**同一个 ClassLoader 加载** |
| **沙箱安全机制** | 核心类库的权限边界得到天然保护 |

如果没有双亲委派机制，每个 ClassLoader 各自加载自己的 `java.lang.String`，那么就会存在多份互相不兼容的 String 类，整个类型系统的基石就不复存在了。

### 4.4 双亲委派的缺陷

双亲委派并非完美无缺。它有一个**固有的方向性问题**：顶层的 Bootstrap ClassLoader 无法访问到底层 ClassLoader 加载的类。

举个例子：JDBC 的 `DriverManager` 由 Bootstrap ClassLoader 加载（它位于 rt.jar 中），但 JDBC 驱动实现（如 MySQL Driver）由 Application ClassLoader 加载。Bootstrap ClassLoader 无法"反向"委托给 Application ClassLoader 去加载 MySQL Driver。这就引出了**打破双亲委派模型**的需求。

---

## 五、打破双亲委派模型

### 5.1 线程上下文类加载器（Thread Context ClassLoader）

**Thread Context ClassLoader（TCCL）** 是解决上述 JDBC SPI 问题的核心机制。

```java
// 获取当前线程的上下文类加载器
ClassLoader tccl = Thread.currentThread().getContextClassLoader();

// 设置上下文类加载器
Thread.currentThread().setContextClassLoader(指定ClassLoader);
```

**工作原理**：高层（Bootstrap/Extension ClassLoader）在加载 SPI 服务时，不再坚持"上层主动加载下层"，而是通过 TCCL 获取当前线程的类加载器（通常是 Application ClassLoader 或自定义 ClassLoader），然后通过这个加载器去加载 SPI 实现类。

**JDBC 示例（ServiceLoader 模式）：**

```java
// DriverManager 中获取 Driver 驱动的核心逻辑（简化版）
ServiceLoader<Driver> loadedDrivers = ServiceLoader.load(Driver.class);
// ServiceLoader.load() 内部使用了 Thread.currentThread().getContextClassLoader()
```

**Java 中使用 TCCL 的典型场景：**
- JNDI（Java Naming and Directory Interface）
- JDBC（Java Database Connectivity）
- JCE（Java Cryptography Extension）
- JAXP（Java API for XML Processing）
- JBI（Java Business Integration）等所有 SPI 机制

**注意**：JDK 6 引入的 `ServiceLoader` 默认使用 TCCL 来加载服务提供者。

### 5.2 Tomcat 的类加载架构

Tomcat 作为 Web 容器，彻底打破了双亲委派模型，设计了独特的类加载架构：

```
                 Bootstrap ClassLoader
                       │
                Extension ClassLoader
                       │
               Application ClassLoader
                       │
            ┌──────────┼──────────┐
            │          │          │
    Common ClassLoader (共同)
            │
    ┌───────┴───────┐
    │               │
  Catalina       Shared
 ClassLoader    ClassLoader
    │               │
    │        ┌──────┴────┐
    │        │           │
    │    WebApp1      WebApp2
    │    ClassLoader  ClassLoader
    │        │           │
    │   ┌────┴────┐  ┌──┴────┐
    │   │JSP      │  │JSP    │
    │   │Loader   │  │Loader │
    │   └─────────┘  └───────┘
    └─────────────────────────
```

**Tomcat 为什么要打破双亲委派？**

Tomcat 需要做到以下几点，而双亲委派无法满足：

| 需求 | 问题 | Tomcat 解决方案 |
|------|------|----------------|
| **隔离性** | 两个 Web 应用可能依赖同一个 Jar 的**不同版本** | 每个 WebApp 有自己的 ClassLoader，各自加载自己的 Jar |
| **热部署** | 修改 JSP 后需要重新加载而不影响其他应用 | WebApp ClassLoader 替换，每次请求都检查 JSP 更新时间 |
| **优先级** | Web 应用自己的类应优先于容器提供的同路径类 | WebApp ClassLoader **优先加载** `/WEB-INF/classes/` 和 `/WEB-INF/lib/*.jar` 下的类 |

**WebappClassLoader 加载逻辑（简化）：**

```java
protected Class<?> loadClass(String name, boolean resolve)
        throws ClassNotFoundException {
    // 1. 检查是否已经加载
    // 2. 尝试用 Bootstrap ClassLoader 加载（因为 java.* 类不能覆盖）
    // 3. 如果是当前 WebApp 的类（/WEB-INF/classes 或 /WEB-INF/lib/*），
    //    自己优先加载（这一点打破了双亲委派）
    // 4. 委派给 Common ClassLoader（非 Web 应用的公共类共享）
    // 5. 抛出 ClassNotFoundException
}
```

### 5.3 SPI（Service Provider Interface）

SPI 是 Java 提供的一种服务发现机制，允许第三方为某个接口提供实现，通过配置方式动态加载。典型代表：

- `java.sql.Driver` → 由 MySQL/Oracle/PostgreSQL 等提供实现
- `javax.crypto.Cipher` → 由不同安全提供商实现
- `javax.script.ScriptEngineFactory` → 脚本引擎

SPI 的标准实现类 `ServiceLoader` 使用 TCCL 来加载服务提供者，从而绕开了双亲委派的限制。

```java
// 自定义 SPI 使用示例
ServiceLoader<MyService> services = ServiceLoader.load(MyService.class);
for (MyService service : services) {
    service.execute();
}

// 约定的配置文件位置：
// META-INF/services/com.example.MyService
// 文件内容为实现类的全限定名：com.example.impl.MyServiceImpl
```

### 5.4 OSGi 模块化

OSGi（Open Service Gateway Initiative）实现了**基于网络的类加载**，每个 Bundle（模块）有自己的 ClassLoader，Bundle 之间可以互相依赖、甚至可以有多个版本共存。

OSGi 的类加载不再是严格的树形结构，而是形成了一个**有向图网络**，打破了双亲委派的树形结构。这种方式更加灵活，但也更加复杂。

### 5.5 热部署与热替换

热部署（Hot Deployment）和热替换（Hot Swap）是打破双亲委派的经典应用场景。

```java
// 热替换的核心思路：用一个新的 ClassLoader 重新加载类
// 旧 ClassLoader 创建的实例全部丢弃，新实例由新 ClassLoader 创建

public class HotSwapClassLoader extends ClassLoader {
    public HotSwapClassLoader(ClassLoader parent) {
        super(parent);
    }
    
    public Class<?> loadBytes(byte[] classBytes) {
        return defineClass(null, classBytes, 0, classBytes.length);
    }
}
```

---

## 六、自定义 ClassLoader

### 6.1 核心方法

自定义 ClassLoader 只需继承 `java.lang.ClassLoader` 并重写以下方法：

| 方法 | 说明 | 推荐覆盖方式 |
|------|------|-------------|
| `loadClass()` | 加载类的入口，实现双亲委派逻辑 | **不覆盖**（保持双亲委派） |
| `findClass()` | 被 `loadClass()` 回调，执行真正的类查找 | **覆盖**，在其中调用 `defineClass()` |
| `defineClass()` | 将字节数组转换为 Class 对象 | 直接调用，一般不改写 |
| `resolveClass()` | 链接指定的 Class | 可选调用 |

### 6.2 完整示例：网络类加载器

```java
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;

public class NetworkClassLoader extends ClassLoader {
    
    private String baseUrl;
    
    public NetworkClassLoader(String baseUrl) {
        // 默认父加载器为 AppClassLoader
        this.baseUrl = baseUrl;
    }
    
    public NetworkClassLoader(String baseUrl, ClassLoader parent) {
        super(parent);
        this.baseUrl = baseUrl;
    }
    
    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        byte[] classBytes = loadClassFromNetwork(name);
        if (classBytes == null || classBytes.length == 0) {
            throw new ClassNotFoundException("Cannot load class: " + name);
        }
        // 将字节码转换为 Class 对象
        return defineClass(name, classBytes, 0, classBytes.length);
    }
    
    private byte[] loadClassFromNetwork(String className) {
        String path = className.replace('.', '/') + ".class";
        String urlStr = baseUrl + "/" + path;
        try (InputStream is = new URL(urlStr).openStream();
             ByteArrayOutputStream baos = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int bytesRead;
            while ((bytesRead = is.read(buffer)) != -1) {
                baos.write(buffer, 0, bytesRead);
            }
            return baos.toByteArray();
        } catch (Exception e) {
            return null;
        }
    }
}
```

### 6.3 完整示例：加密类加载器

```java
import java.security.MessageDigest;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

public class DecryptClassLoader extends ClassLoader {
    
    private static final String ENCRYPTION_KEY = "MySecretKey12345";
    private String classPath;
    
    public DecryptClassLoader(String classPath, ClassLoader parent) {
        super(parent);
        this.classPath = classPath;
    }
    
    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        try {
            byte[] encryptedBytes = loadEncryptedFile(name);
            byte[] decryptedBytes = decrypt(encryptedBytes);
            return defineClass(name, decryptedBytes, 0, decryptedBytes.length);
        } catch (Exception e) {
            throw new ClassNotFoundException("Failed to load class: " + name, e);
        }
    }
    
    private byte[] decrypt(byte[] data) throws Exception {
        SecretKeySpec key = new SecretKeySpec(
            ENCRYPTION_KEY.getBytes("UTF-8"), "AES");
        Cipher cipher = Cipher.getInstance("AES/ECB/PKCS5Padding");
        cipher.init(Cipher.DECRYPT_MODE, key);
        return cipher.doFinal(data);
    }
    
    private byte[] loadEncryptedFile(String className) {
        // 从混淆后的路径读取加密字节码
        // ...
        return null;
    }
}
```

### 6.4 自定义 ClassLoader 的应用场景

| 场景 | 说明 |
|------|------|
| **加密保护** | 对 class 文件加密，在加载时解密，防止反编译 |
| **热部署** | 监控 class 文件变化，用新 ClassLoader 重新加载，实现不停机更新 |
| **从非标准源加载** | 从数据库、网络、内存中获取字节码 |
| **代码沙箱** | 为不同来源的代码提供不同权限控制 |
| **模块隔离** | OSGi、微内核架构等场景 |

---

## 七、类卸载（Class Unloading）

### 7.1 类卸载的条件

JVM 中的类在满足以下**三个条件**时才会被卸载：

1. **该类所有的实例都已被 GC**（包括间接引用，即该类实例派生的其他对象）
2. **加载该类的 ClassLoader 已被 GC**
3. **该类对应的 `java.lang.Class` 对象没有在任何地方被引用**

**核心条件**：只有自定义 ClassLoader 加载的类才有可能被卸载。由 Bootstrap、Extension、Application ClassLoader 加载的类会**永久存在**（因为这三者本身不会被 GC）。

### 7.2 类卸载的触发时机

- 类卸载发生在 JVM 的 **GC 过程中**，尤其在 CMS、G1 等收集器的**并发标记阶段**
- JVM 参数 `-XX:+TraceClassUnloading` 可以打印类卸载信息
- JVM 参数 `-XX:+TraceClassLoading` 可以打印类加载信息（两者常一起使用）

```bash
# 观察类加载和卸载
java -XX:+TraceClassLoading -XX:+TraceClassUnloading MyApp
```

### 7.3 Metaspace 与类卸载

JDK 8 以后，永久代（PermGen）被移除，取而代之的是**元空间（Metaspace）**。

| 对比项 | 永久代（JDK ≤ 7） | 元空间（JDK ≥ 8） |
|--------|------------------|------------------|
| 存储位置 | JVM 堆内存中 | 本地内存（Native Memory） |
| 默认大小限制 | 受限（-XX:MaxPermSize） | 几乎无限（受系统内存限制） |
| 类卸载 | 更加困难，容易 OOM | 更灵活，但也需要合理触发 FGC |
| 元数据溢出异常 | `java.lang.OutOfMemoryError: PermGen space` | `java.lang.OutOfMemoryError: Metaspace` |

元空间使用本地内存后，类加载和卸载的灵活性更高，但如果频繁自定义 ClassLoader 加载和丢弃（如 Tomcat 热部署、JSP 编译），仍然会出现 Metaspace OOM。

### 7.4 类卸载示例

```java
public class ClassUnloadDemo {
    public static void main(String[] args) throws Exception {
        // 第一次加载
        ClassLoader cl1 = new MyClassLoader();
        Class<?> clazz1 = cl1.loadClass("com.example.MyClass");
        Object obj1 = clazz1.getDeclaredConstructor().newInstance();
        System.out.println("Object: " + obj1);
        
        // 去掉引用
        cl1 = null;
        clazz1 = null;
        obj1 = null;
        
        // 触发 GC（注意：-XX:+TraceClassUnloading 需要加参数）
        System.gc();
        
        // 再次加载——如果类已卸载，会生成新的 Class 对象
        ClassLoader cl2 = new MyClassLoader();
        Class<?> clazz2 = cl2.loadClass("com.example.MyClass");
        // clazz1 != clazz2，因为旧的 Class 已被卸载
        System.out.println("Same class? " + (clazz1 == clazz2));  // 如果卸载成功，返回 false
    }
}
```

### 7.5 常见类卸载场景

- **Tomcat 热部署**：重新部署 Web 应用时，旧的 WebappClassLoader 和它加载的所有类被回收
- **OSGi Bundle 更新**：旧 Bundle 的 ClassLoader 被丢弃，新 Bundle 的 ClassLoader 重新加载
- **实时编译（JIT）卸载**：JIT 编译的代码可以被卸载回解释模式（罕见，主要受 CodeCache 影响）

---

## 八、常见异常与排查

### 8.1 ClassNotFoundException

**发生时机**：类加载时，调用 `Class.forName()`、`ClassLoader.loadClass()`、`ClassLoader.findSystemClass()` 等显式的类加载方法时，在类路径中找不到对应的类定义。

```java
// 典型触发场景
Class.forName("com.example.SomeClass");        // 找不到 → ClassNotFoundException
classLoader.loadClass("com.example.SomeClass"); // 找不到 → ClassNotFoundException
```

**常见原因**：
| 原因 | 排查方法 |
|------|---------|
| 缺少依赖 Jar | 检查 classpath 或 Maven/Gradle 依赖 |
| 类名拼写错误 | 检查全限定名是否正确 |
| 类路径配置错误 | 运行时的 classpath 与编译时不一致 |
| 编译版本不一致 | 高版本 JDK 编译的 class 在低版本 JVM 运行 |

### 8.2 NoClassDefFoundError

**发生时机**：JVM 或 ClassLoader 实例在尝试加载一个在编译期存在、但在运行时无法找到的类时抛出。与 ClassNotFoundException 的关键区别：**它发生在链接（resolve）阶段**，而 ClassNotFoundException 发生在主动加载时。

```java
// 典型场景：编译期通过，运行期缺失
// Test.class 中引用了 Helper.class，运行时 Helper.class 不存在
public class Test {
    public static void main(String[] args) {
        Helper h = new Helper();  // 编译通过，运行抛出 NoClassDefFoundError
    }
}
```

| 对比项 | ClassNotFoundException | NoClassDefFoundError |
|--------|----------------------|---------------------|
| 类型 | Exception（受检） | Error（非受检） |
| 阶段 | 显式类加载阶段 | 隐式类链接/解析阶段 |
| 原因 | 主动加载时找不到 | 编译存在，运行缺失 |
| 典型场景 | `Class.forName()` | 静态块失败导致类初始化异常 |

### 8.3 UnsupportedClassVersionError

当 JVM 尝试加载一个由**更高版本 JDK 编译**的 class 文件时抛出。

```bash
# 编译版本与运行版本不匹配
$ java MyClass
Error: JVMCFRE152: Unsupported class version: 61.0 (JDK 17) 
       JVM supports class version: 55.0 (JDK 11)
```

**Class 文件版本映射**：
| JDK 版本 | Class 文件版本号 |
|---------|----------------|
| JDK 8 | 52.0 |
| JDK 11 | 55.0 |
| JDK 17 | 61.0 |
| JDK 21 | 65.0 |

### 8.4 LinkageError

**`LinkageError`** 是类加载相关 Error 的顶层父类，其常见子类包括：

| 子类 | 触发场景 |
|------|---------|
| `NoClassDefFoundError` | 编译时存在但运行时丢失的类 |
| `UnsatisfiedLinkError` | 无法解析 native 方法（找不到 native 库） |
| `VerifyError` | 字节码验证失败 |
| `ClassFormatError` | Class 文件格式错误 |
| `AbstractMethodError` | 调用了抽象方法（通常发生在接口与实现版本不一致时） |
| `IncompatibleClassChangeError` | 类定义发生了不兼容的改变 |

### 8.5 ConcurrentModification 与类加载冲突

```java
// 典型的多线程类加载问题
// 类 A 的 <clinit> 中创建类 B 的实例
// 类 B 的 <clinit> 中访问类 A 的静态字段
// → 形成死锁或循环初始化，导致 StackOverflowError
```

### 8.6 排查工具与技巧

```bash
# 1. 打印类加载详情
-XX:+TraceClassLoading
-XX:+TraceClassUnloading
-verbose:class

# 2. 查看类来自哪个 Jar
-Xbootclasspath/a:<path>    # 追加到 Bootstrap Classpath
java -cp ... -verbose:class

# 3. 查看运行时 ClassLoader 层级
ClassLoader cl = MyClass.class.getClassLoader();
while (cl != null) {
    System.out.println(cl);
    cl = cl.getParent();
}
// 输出示例：
// sun.misc.Launcher$AppClassLoader@73d16e93
// sun.misc.Launcher$ExtClassLoader@15db9742

# 4. 检查类与 Jar 的对应关系
jar -tf some.jar | grep MyClass

# 5. 使用 jmap 查看加载的类
jmap -clstats <pid>          # 查看 ClassLoader 统计信息
jcmd <pid> GC.class_stats    # 类的详细元数据统计
```

---

## 九、深入理解：类与 ClassLoader 的关系

### 9.1 类的全局唯一性

在 JVM 中，一个类的**全限定名 + ClassLoader 实例**共同决定了其在运行时的唯一性。也就是说，同一个类文件，由两个不同的 ClassLoader 实例加载，在 JVM 中会被认为是**两个不同的类**。

```java
public class ClassIdentityDemo {
    public static void main(String[] args) throws Exception {
        ClassLoader loader1 = new URLClassLoader(new URL[]{
            new URL("file:/path/to/classes/")});
        ClassLoader loader2 = new URLClassLoader(new URL[]{
            new URL("file:/path/to/classes/")});
        
        Class<?> class1 = loader1.loadClass("com.example.Hello");
        Class<?> class2 = loader2.loadClass("com.example.Hello");
        
        System.out.println("class1 == class2: " + (class1 == class2));  // false
        System.out.println("class1.equals(class2): " + class1.equals(class2));  // false
        
        Object obj1 = class1.getDeclaredConstructor().newInstance();
        // obj2 与 obj1 类型不同，不能直接赋值
        // Object obj2 = class2.getDeclaredConstructor().newInstance();
        
        // instanceof 检查
        System.out.println("obj1 instanceof com.example.Hello: " 
            + (obj1 instanceof com.example.Hello));  // false!
        // 注意：这里的 com.example.Hello 是 AppClassLoader 加载的，
        // 而 obj1 是 loader1 加载的，类型不同
    }
}
```

### 9.2 父子 ClassLoader 的可见性

- 子 ClassLoader 可以访问父 ClassLoader 加载的类（向上可见）
- 父 ClassLoader 无法访问子 ClassLoader 加载的类（向下不可见）

```
示例：
Bootstrap ClassLoader 加载: java.lang.String, java.util.HashMap
Extension ClassLoader 加载: javax.crypto.Cipher
App ClassLoader 加载: com.example.MyApp

可见性:
com.example.MyApp 可以访问 String, HashMap, Cipher  ✓
javax.crypto.Cipher 可以访问 String, HashMap ✓ (通过父加载器)
javax.crypto.Cipher 不能访问 com.example.MyApp ✗
```

---

## 十、JDK 9+ 模块化对类加载的影响

JDK 9 引入的 **Project Jigsaw（模块化系统）** 对类加载机制产生了重大影响：

### 10.1 类加载器层次的变化

| JDK ≤ 8 | JDK 9+ |
|---------|--------|
| Bootstrap ClassLoader | Bootstrap ClassLoader（加载基础模块） |
| Extension ClassLoader | **Platform ClassLoader**（平台类加载器） |
| Application ClassLoader | Application ClassLoader（应用类加载器） |

### 10.2 关键变化

1. **取消 rt.jar 和 ext 目录**：核心类库以模块形式存在于 `jmods` 目录
2. **Extension ClassLoader 被 Platform ClassLoader 替代**
3. **Platform ClassLoader 的 parent 不再是 null**：其 parent 也是 Bootstrap ClassLoader
4. **模块可见性**：不仅依赖类加载器的父子关系，还受模块导出和开放的约束
5. **`-Xbootclasspath/p` 和 `-Xbootclasspath/a` 被废弃**：取而代之的是 `--patch-module`

```bash
# JDK 9+ 查看模块
java --list-modules

# 添加引导模块补丁
java --patch-module java.base=/path/to/override ...
```

### 10.3 模块化对 SPI 的影响

JDK 9+ 中，`ServiceLoader` 不仅支持传统的 `META-INF/services` 方式，还新增了**模块声明中的 `provides` 用法**：

```java
// module-info.java
module com.example.myapp {
    uses com.example.spi.MyService;
}

module com.example.impl {
    provides com.example.spi.MyService 
        with com.example.impl.MyServiceImpl;
}
```

---

## 十一、总结与最佳实践

### 11.1 核心知识点回顾

| 知识点 | 要点 |
|--------|------|
| 类加载 7 阶段 | 加载 → 验证 → 准备 → 解析 → 初始化 → 使用 → 卸载 |
| 初始化触发 6 种 | new、反射、父类未初始化、main 方法、MethodHandle、default 接口方法 |
| 双亲委派 | 先父后子，保证核心库安全和类唯一性 |
| 打破双亲委派 | TCCL（SPI）、Tomcat WebappClassLoader、OSGi |
| 类卸载条件 | 所有实例 GC + ClassLoader GC + Class 对象无引用 |
| 类唯一性 | 全限定名 + ClassLoader 实例共同决定 |

### 11.2 最佳实践

1. **不要覆盖 loadClass()**：除非明确要打破双亲委派，否则只覆盖 `findClass()`
2. **注意 ClassLoader 泄漏**：在 Web 容器中，不要在全局静态变量中持有由 WebApp ClassLoader 加载的类或实例引用，否则会导致类加载器泄漏（ClassLoader Leak），严重时会 OOM
3. **第三方库和版本冲突**：使用 Maven `mvn dependency:tree` 分析依赖树，利用 `shade` 插件或 `-Xbootclasspath/p` 解决冲突
4. **模块化迁移**：JDK 9+ 需注意 `--add-opens`、`--add-exports` 参数处理反射访问
5. **监控类加载**：生产环境慎用 `-verbose:class`，会显著影响性能。建议使用 `jcmd` 或 `jmap` 按需查看

### 11.3 排查 Checklist

当遇到类加载相关问题时，可以按以下清单排查：

```
□ 确认类是否在 classpath 中（jar -tf / find . -name "*.class"）
□ 确认 class 文件版本与 JVM 版本匹配（javap -verbose）
□ 确认不存在同名类冲突（mvn dependency:tree）
□ 确认 ClassLoader 层级是否正确（System.out.println(cl)）
□ 确认是否有静态初始化死锁（线程 dump 分析）
□ 确认 TCCL 是否被正确设置（SPI 场景）
□ 确认是否正在使用 Tomcat/OSGi 等特殊类加载架构
□ 确认 JDK 版本迁移后的模块可见性（JDK 9+）
□ 确认是否存在类加载器泄漏（jmap -clstats <pid> 观察 ClassLoader 数量持续增长）
```

---

## 参考资源

- 《深入理解 Java 虚拟机》（第 3 版）——周志明
- JVM® Specification, Java SE 17 Edition
- OpenJDK HotSpot 源码
- Apache Tomcat 9 Architecture Documentation
- JDK 9 Release Notes: Class-Loading Changes
