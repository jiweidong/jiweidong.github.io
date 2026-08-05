---
title: 【设计模式】单例模式深度解析：8 种写法、线程安全与防破坏全攻略
date: 2026-08-05 08:00:00
tags:
  - Java
  - 设计模式
  - 并发
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】单例模式深度解析：8 种写法、线程安全与防破坏全攻略

## 面试官：单例模式你会几种写法？为什么推荐枚举单例？

单例模式（Singleton Pattern）是 GoF 23 种设计模式中最简单、却最容易被问出深度的一种。很多同学能背出"饿汉式、懒汉式、双重检查锁"，但一旦被追问"DCL 为什么要加 volatile？""枚举单例为什么能防反射？""Spring 的单例和单例模式是一回事吗？"就卡壳了。

本文从 8 种写法逐一剖析，把线程安全、性能、防破坏这些坑全部踩一遍，最后给出生产环境的选型建议。

<!-- more -->

## 一、什么是单例模式

**定义**：保证一个类只有一个实例，并提供一个全局访问点。

**适用场景**：

- 无状态的工具类：如 `Runtime`、`System` 中的全局对象
- 需要严格控制资源的对象：线程池、数据库连接池、配置中心客户端
- 全局唯一的协调者：Spring 容器中的单例 Bean、日志 Logger

**三个要点**：

1. 构造器私有化（`private` 构造器，禁止外部 new）
2. 实例唯一（类内部持有自己的实例）
3. 全局访问点（静态方法返回实例）

## 二、8 种写法逐一剖析

### 写法 1：饿汉式（静态常量）

```java
public class Singleton {
    private static final Singleton INSTANCE = new Singleton();

    private Singleton() {}

    public static Singleton getInstance() {
        return INSTANCE;
    }
}
```

**原理**：类加载时（`<clinit>` 阶段）就完成实例化，由 JVM 保证 `static final` 字段初始化只执行一次，天然线程安全。

**优点**：写法最简单，无线程安全问题。

**缺点**：不管用不用都创建实例，如果构造过程很重（如初始化连接池）会造成启动变慢；不能做到懒加载。

### 写法 2：饿汉式（静态代码块）

```java
public class Singleton {
    private static final Singleton INSTANCE;

    static {
        INSTANCE = new Singleton();
    }

    private Singleton() {}

    public static Singleton getInstance() {
        return INSTANCE;
    }
}
```

和写法 1 本质相同，只是把初始化放进静态代码块，适合构造前需要做一些静态配置的场景。

### 写法 3：懒汉式（线程不安全）

```java
public class Singleton {
    private static Singleton instance;

    private Singleton() {}

    public static Singleton getInstance() {
        if (instance == null) {
            instance = new Singleton();  // 多线程下可能创建多个实例
        }
        return instance;
    }
}
```

**问题**：两个线程同时进入 `if (instance == null)`，会各自 new 一个实例，单例被破坏。**仅适合单线程场景，生产环境禁用。**

### 写法 4：懒汉式（同步方法）

```java
public class Singleton {
    private static Singleton instance;

    private Singleton() {}

    public static synchronized Singleton getInstance() {
        if (instance == null) {
            instance = new Singleton();
        }
        return instance;
    }
}
```

给整个方法加 `synchronized`，线程安全了，但**每次调用都要抢锁**，即使实例已经创建。高并发下性能损失严重，不推荐。

### 写法 5：双重检查锁（DCL，Double-Checked Locking）

```java
public class Singleton {
    // volatile 必不可少！
    private static volatile Singleton instance;

    private Singleton() {}

    public static Singleton getInstance() {
        if (instance == null) {                    // 第一次检查：避免无谓加锁
            synchronized (Singleton.class) {
                if (instance == null) {            // 第二次检查：保证只创建一次
                    instance = new Singleton();
                }
            }
        }
        return instance;
    }
}
```

**追问：为什么 DCL 必须加 volatile？**

因为 `instance = new Singleton()` 不是原子操作，在 JVM 层面拆分为三步：

```
1. memory = allocate();      // 分配内存
2. ctorInstance(memory);     // 执行构造器
3. instance = memory;        // 引用指向内存
```

其中 2 和 3 可能被重排序（编译器/CPU 优化），变成先赋值引用、后执行构造器。此时线程 A 执行完 3（构造器还没跑完），线程 B 进来发现 `instance != null`，直接返回一个**半初始化**的对象，使用时就出问题了。

`volatile` 通过**内存屏障**禁止了 2 和 3 的重排序，保证拿到的一定是完整构造的对象。这也是面试中"DCL 为什么必须加 volatile"的标准答案。

### 写法 6：静态内部类（推荐之一）

```java
public class Singleton {

    private Singleton() {}

    private static class Holder {
        private static final Singleton INSTANCE = new Singleton();
    }

    public static Singleton getInstance() {
        return Holder.INSTANCE;
    }
}
```

**原理**：利用 JVM 的**类加载时机**——外部类加载时不会加载内部类 `Holder`，只有第一次调用 `getInstance()` 访问 `Holder.INSTANCE` 时才触发 `Holder` 的类加载和初始化。JVM 保证类的 `<clinit>` 是加锁且只执行一次的，所以：

- ✅ 懒加载：用到才创建
- ✅ 线程安全：JVM 层面保证
- ✅ 无锁开销：性能最好

这是**懒加载 + 线程安全**的最优组合，比 DCL 更简洁、无 volatile 心智负担。

### 写法 7：枚举单例（最推荐）

```java
public enum Singleton {
    INSTANCE;

    public void doSomething() {
        System.out.println("do something...");
    }
}
```

使用方式：`Singleton.INSTANCE.doSomething();`

**为什么枚举单例是最佳实践？** 三个"唯一"：

| 特性 | 普通类单例 | 枚举单例 |
|------|-----------|---------|
| 线程安全 | 需自己保证 | JVM 天然保证（枚举构造天然线程安全） |
| 反序列化 | 需实现 `readResolve()` | 枚举序列化由 JVM 特殊处理，反序列化不会创建新实例 |
| 防反射 | 需加标志位校验 | 反射 `newInstance()` 直接抛 `IllegalArgumentException` |

**反射破坏**：`Constructor.newInstance()` 源码中明确对枚举类型抛异常：

```java
if ((clazz.getModifiers() & Modifier.ENUM) != 0)
    throw new IllegalArgumentException("Cannot reflectively create enum objects");
```

**序列化破坏**：普通单例序列化后反序列化会通过 `ObjectInputStream` 创建新实例（绕过构造器），必须加 `readResolve()` 兜底；而枚举在序列化时只保存枚举名，反序列化时用 `Enum.valueOf()` 拿到**同一个**实例，天然免疫。

**结论**：Effective Java 作者 Joshua Bloch 明确推荐枚举单例。唯一"缺点"是不能懒加载，但枚举本质是常量，初始化成本极低，几乎无感知。

### 写法 8：ThreadLocal 单例（场景特化）

```java
public class Singleton {
    private static final ThreadLocal<Singleton> HOLDER =
        ThreadLocal.withInitial(Singleton::new);

    private Singleton() {}

    public static Singleton getInstance() {
        return HOLDER.get();
    }
}
```

这种写法不是严格意义的单例——它保证的是**每个线程一个实例**（线程内单例），适合数据库连接、事务上下文这类"线程内复用、跨线程隔离"的对象。注意 ThreadLocal 使用后要 `remove()`，防止线程池场景下的内存泄漏。

## 三、破坏单例的 4 种手段与防御

| 破坏手段 | 原理 | 防御方案 |
|---------|------|---------|
| 反射调用私有构造器 | `setAccessible(true)` 后强制 new | 构造器中加标志位：第二次调用抛异常；或直接用枚举 |
| 序列化/反序列化 | `ObjectInputStream` 绕过构造器创建新实例 | 实现 `readResolve()` 返回已有实例；或直接用枚举 |
| 克隆（Cloneable） | `clone()` 不调用构造器 | 重写 `clone()` 抛异常或返回单例本身 |
| 多个类加载器 | 不同 ClassLoader 加载出不同类 | 指定 ClassLoader / 用全局容器管理 |

以反射防御为例：

```java
public class Singleton {
    private static volatile Singleton instance;
    private static boolean created = false;

    private Singleton() {
        synchronized (Singleton.class) {
            if (created) {
                throw new RuntimeException("单例被破坏！禁止反射创建");
            }
            created = true;
        }
    }
    // getInstance() ...
}
```

## 四、框架中的单例模式

### 4.1 JDK 中的应用

- `java.lang.Runtime.getRuntime()`：饿汉式单例，代表 JVM 运行时
- `java.lang.System`：静态字段持有全局对象
- `Desktop.getDesktop()`、`Calendar.getInstance()`（原型模式但缓存了实例）

### 4.2 Spring 中的"单例"与 GoF 单例的区别

**经典面试题：Spring 的单例 Bean 是单例模式吗？**

答案：**不是 GoF 单例模式，但效果上是"单例"（容器级单例）**。

- GoF 单例：类自己控制实例创建，构造器私有
- Spring 单例 Bean：**构造器不私有**，Bean 的实例由 Spring 容器（`singletonObjects` 这个 `ConcurrentHashMap`）持有并缓存，同一容器内每次 `getBean()` 返回同一个实例

```java
// DefaultSingletonBeanRegistry 核心字段
private final Map<String, Object> singletonObjects =
    new ConcurrentHashMap<>(256);
```

所以 Spring 单例是**容器管理的单例**，默认 scope 就是 `singleton`；`prototype` 则每次返回新实例。

## 五、生产环境选型建议

| 场景 | 推荐写法 |
|------|---------|
| 常规场景（99%） | 枚举单例，简单、安全、无懈可击 |
| 需要懒加载且对象创建较重 | 静态内部类（Holder） |
| 需要懒加载 + 代码风格统一 | DCL + volatile |
| 明确不需要懒加载 | 饿汉式（静态常量） |
| 线程内复用 | ThreadLocal 单例 |

## 六、面试追问总结

1. **单例模式有哪些实现方式？** → 8 种（重点讲 5、6、7）
2. **DCL 为什么要 volatile？** → 指令重排序导致半初始化对象
3. **静态内部类为什么线程安全？** → JVM 类加载机制保证 `<clinit>` 唯一执行
4. **为什么推荐枚举单例？** → 防反射、防序列化、天然线程安全
5. **Spring 单例 Bean 是单例模式吗？** → 不是，是容器级单例
6. **单例模式有什么缺点？** → 违背单一职责（既管创建又管业务）、不好扩展、测试不友好、隐藏依赖

## 七、总结

单例模式的核心不是"背 8 种写法"，而是理解三个底层机制：**JVM 类加载的线程安全保证、volatile 的内存语义、枚举的特殊语言支持**。把这三点吃透，无论面试官怎么追问，都能从容应对。生产环境无脑选枚举单例，就是最稳的答案。
