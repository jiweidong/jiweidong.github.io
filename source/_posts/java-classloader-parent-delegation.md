---
title: 【面试必备】Java 类加载机制与双亲委派模型：从源码到打破双亲委派
date: 2026-06-21 08:00:00
tags:
  - Java
  - JVM
  - 类加载
  - 面试
categories:
  - Java
  - JVM底层
author: 东哥
---

# 【面试必备】Java 类加载机制与双亲委派模型：从源码到打破双亲委派

## 面试官：说说 Java 类加载的过程？

Java 类加载是在运行时将 `.class` 文件中的二进制字节流加载到 JVM 内存中，经过**加载 → 验证 → 准备 → 解析 → 初始化**五个阶段，最终成为 JVM 可以直接使用的 Java 类的过程。

### 类加载的 5 个阶段

```
┌─────────────────────────────────────────────────┐
│              类加载生命周期                        │
│                                                    │
│  加载 → 验证 → 准备 → 解析 → 初始化 → 使用 → 卸载   │
│  └──────┬───────┬───────┬───────┘                  │
│         │       │       │                          │
│         │    链接阶段（Linking）                     │
│         │                                         │
│         └── 可以互相交叉（解析可能延迟到初始化后）    │
└─────────────────────────────────────────────────┘
```

### 阶段一：加载（Loading）

加载阶段主要做三件事：

1. **通过类的全限定名获取二进制字节流**（可以从 JAR、WAR、网络、动态代理生成等）
2. **将字节流的静态存储结构转化为方法区的运行时数据结构**
3. **在堆中生成该类的 Class 对象**，作为方法区数据的访问入口

```java
// 触发类加载的几种方式
Class<?> clazz = Class.forName("com.example.User");     // 显式加载（会执行 static 块）
Class<?> clazz = Thread.currentThread().getContextClassLoader().loadClass("com.example.User");  // 只加载，不初始化
User user = new User();  // 隐式加载
```

### 阶段二：验证（Verification）

确保 Class 文件的字节流符合 JVM 规范，防止恶意代码：

| 验证阶段 | 检查内容 |
|---------|---------|
| **文件格式验证** | 是否以 0xCAFEBABE 开头、版本号是否支持 |
| **元数据验证** | 是否有父类、是否继承了 final 类、是否实现了抽象方法 |
| **字节码验证** | 操作数栈类型是否一致、跳转指令是否合法 |
| **符号引用验证** | 引用的类/字段/方法是否存在、访问权限是否正确 |

> **注意**：可以通过 `-Xverify:none` 关闭验证（仅 HotSpot 支持），加速启动。

### 阶段三：准备（Preparation）

为**类的静态变量**分配内存并设置**默认零值**（注意：不是赋初始值！）：

```java
public class Example {
    public static int value = 123;        // 准备阶段 → value = 0
    public static final int CONST = 123;  // 准备阶段 → CONST = 123（final 直接赋值）
}
```

| 类型 | int | long | float | double | boolean | 引用 |
|------|-----|------|-------|--------|---------|------|
| 默认值 | 0 | 0L | 0.0f | 0.0d | false | null |

### 阶段四：解析（Resolution）

将常量池中的**符号引用**替换为**直接引用**：

- **符号引用**：用字面量描述目标，如 `com/example/User.getName:()Ljava/lang/String;`
- **直接引用**：指向目标的指针、偏移量或句柄

解析可以发生在初始化之后（**延迟解析**），JVM 规范没有强制要求解析阶段必须在初始化之前完成。

### 阶段五：初始化（Initialization）

执行 `<clinit>()` 方法，即**收集所有静态变量赋值和静态代码块**：

```java
public class InitExample {
    public static int x = 10;           // 收集
    static {                            // 收集
        x = 20;
    }
    // 生成的 <clinit>() 方法相当于：
    // x = 10; x = 20; → 最终 x = 20
}
```

**不会触发初始化的场景**（被动引用）：

```java
// 1. 通过子类引用父类的静态字段
System.out.println(Child.PARENT_FIELD);  // 只初始化 Parent，不初始化 Child

// 2. 通过数组定义引用类
Parent[] arr = new Parent[10];  // 触发 [Lcom/example/Parent 类的初始化，不是 Parent

// 3. 引用编译期常量
System.out.println(Child.STATIC_FINAL);  // static final 在常量池中，不会触发类加载
```

---

## 二、双亲委派模型（Parent Delegation Model）

### 2.1 什么是双亲委派？

> 当一个类加载器收到类加载请求时，它不会自己先去加载，而是把这个请求委托给父类加载器去执行，只有父类加载器无法完成加载时，子加载器才会尝试自己加载。

```
               ┌─────────────────────┐
               │ Bootstrap ClassLoader│  ← C++ 实现，加载 jre/lib/rt.jar
               └──────────┬──────────┘
                          │ 继承（委派）
               ┌──────────▼──────────┐
               │ Extension ClassLoader│  ← 加载 jre/lib/ext/*.jar
               └──────────┬──────────┘
                          │ 继承（委派）
               ┌──────────▼──────────┐
               │ Application ClassLoader│  ← 加载 classpath 下的类
               └──────────┬──────────┘
                          │ 继承（委派）
               ┌──────────▼──────────┐
               │   自定义 ClassLoader │  ← 用户实现
               └─────────────────────┘
```

### 2.2 源码分析：ClassLoader.loadClass()

```java
// java.lang.ClassLoader.loadClass() — JDK 8 实现
protected Class<?> loadClass(String name, boolean resolve)
    throws ClassNotFoundException
{
    synchronized (getClassLoadingLock(name)) {
        // 1. 检查类是否已被加载
        Class<?> c = findLoadedClass(name);
        if (c == null) {
            try {
                if (parent != null) {
                    // 2. 父加载器不为 null → 委派给父加载器
                    c = parent.loadClass(name, false);
                } else {
                    // 3. 父加载器为 null → 由 Bootstrap ClassLoader 加载
                    c = findBootstrapClassOrNull(name);
                }
            } catch (ClassNotFoundException e) {
                // 4. 父加载器无法加载 → 抛出异常
            }
            
            if (c == null) {
                // 5. 父加载器加载失败 → 自己尝试
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

**核心逻辑**：递归委派，逐层向上。父加载器能加载就父加载器加载，父加载器不能加载才自己尝试。

### 2.3 双亲委派的好处

1. **安全**：防止核心 API 被篡改。比如自己写一个 `java.lang.String` 类，由于双亲委派，它会被 Bootstrap ClassLoader 加载的 rt.jar 中的 String 覆盖，你自己的 String 永远不会被加载（实际上是没机会用）。

2. **避免重复加载**：父加载器已经加载过的类，子加载器不需要重复加载。

3. **保证类的唯一性**：同一个类（全限定名相同）由同一个类加载器加载，保证 JVM 中只有一份 Class 对象。

---

## 三、打破双亲委派模型的场景

### 3.1 SPI 机制（Service Provider Interface）

JDBC 4.0 的 SPI 机制是典型的打破双亲委派的例子：

```java
// DriverManager.getConnection() 内部实现
ServiceLoader<Driver> loadedDrivers = ServiceLoader.load(Driver.class);
// ServiceLoader.load() 使用线程上下文类加载器（TCCL）
```

**问题**：
- `DriverManager` 在 `rt.jar` 中，由 Bootstrap ClassLoader 加载
- 具体的数据库驱动实现（如 `com.mysql.cj.jdbc.Driver`）在 classpath 上，由 Application ClassLoader 加载
- 按照双亲委派，Bootstrap 不可能加载到 Application 路径下的类！

**解决方案**：**线程上下文类加载器（Thread Context ClassLoader）**

```java
public static <S> ServiceLoader<S> load(Class<S> service) {
    // 获取当前线程的 ContextClassLoader
    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    return ServiceLoader.load(service, cl);
}
```

**TCCL 破坏了双亲委派**：Bootstrap ClassLoader 通过 TCCL「逆向」委托给 Application ClassLoader 来加载 SPI 实现类。

### 3.2 Tomcat 的类加载架构

Tomcat 为了隔离不同 web 应用，实现了更复杂的类加载机制：

```
               Bootstrap ClassLoader
                       │
               Extension ClassLoader
                       │
               Application ClassLoader
                       │
          ┌────────────┼────────────┐
          │            │            │
    Common ClassLoader            │
          │            │            │
    ┌─────┴────┐   WebApp1    WebApp2
    │Catalina  │   ClassLoader ClassLoader
    │ClassLoader│   (隔离)      (隔离)
    └──────────┘
```

**Tomcat 打破了双亲委派**：WebApp ClassLoader 会优先加载自己 WEB-INF/classes 和 WEB-INF/lib 下的类，而不是先委托给父加载器。这样不同应用可以使用不同版本的 Spring、不同版本的第三方库。

### 3.3 热部署/热替换

```java
// 自定义 ClassLoader 实现热替换
public class HotSwapClassLoader extends URLClassLoader {
    private String className;
    
    public HotSwapClassLoader(URL[] urls) {
        super(urls, null);  // 父加载器置 null
    }
    
    @Override
    public Class<?> loadClass(String name) throws ClassNotFoundException {
        // 只加载自己关心的类（每次重新加载）
        if (name.startsWith("com.example.hotswap.")) {
            return findClass(name);  // 不委派，自己加载
        }
        return super.loadClass(name);  // 其他类正常委派
    }
}
```

原理：创建新的 ClassLoader 实例，加载修改后的类文件。由于不同的 ClassLoader 实例加载的类在 JVM 中被视为不同的类，旧类和新类可以共存。

---

## 四、常见面试追问

| 问题 | 答案 |
|------|------|
| 什么是类加载器的命名空间？ | 不同类加载器加载的同一全限定名的类，在 JVM 中被视为不同的类，通过 instanceof 判断为 false |
| 如何判断两个类相等？ | 全限定名相同 + 类加载器相同，缺一不可 |
| 为什么不能自己写 java.lang.String？ | 双亲委派保证核心类由 Bootstrap ClassLoader 加载，即使你写了一个 String，你写的永远不会被加载（沙箱安全机制） |
| 如何强制加载自己的 java.lang.String？ | 技术上可以自定义 ClassLoader 并设置父加载器为 null，但不推荐，会破坏 Java 类型体系 |
| OSGi 中的类加载有什么特点？ | OSGi 使用「网状」而不是「树状」的类加载结构，支持模块间的依赖和版本管理 |
| Java 9 的模块化对类加载有什么影响？ | 模块化后，Extension ClassLoader 被移除（合并到 Platform ClassLoader），类加载器不再是树状，支持模块间的显式依赖和导出控制 |

---

## 五、总结

类加载机制和双亲委派模型是 Java 的**安全基石**和**模块化基础**：

| 概念 | 一句话总结 |
|------|-----------|
| 类加载 5 阶段 | 加载 → 验证 → 准备 → 解析 → 初始化 |
| 双亲委派 | 先委派父加载器，父加载器不行再自己加载 |
| 打破双亲委派 | SPI（TCCL）、Tomcat（隔离应用）、热部署（新建 ClassLoader） |
| 核心目的 | 安全（防止核心类篡改）、避免重复加载、保证类唯一性 |

理解类加载机制不仅能帮你通过面试，更是排查 `ClassNotFoundException`、`NoClassDefFoundError`、`ClassCastException` 等问题的基本功。
