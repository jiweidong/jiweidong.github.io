---
title: 【JVM 实战】Java 热部署与类加载器隔离深度解析：从 Tomcat 到 JRebel 与 Arthas redefine
date: 2026-08-21 08:00:00
tags:
  - Java
  - JVM
  - 类加载
categories:
  - Java
  - JVM 原理
author: 东哥
---

# 【JVM 实战】Java 热部署与类加载器隔离深度解析：从 Tomcat 到 JRebel 与 Arthas redefine

## 面试官：改了代码不重启，Java 是怎么做到的？

"热部署"是每个 Java 开发都离不开的日常：改一行代码，保存，页面刷新就生效了。但你真的想过它背后的机制吗？要回答这个问题，先得明白一个 JVM 铁律：**一个类只能被同一个类加载器加载一次，且 JVM 不会自动重新加载已加载的类**。

所以热部署的本质只有两条路：

1. **换类加载器**：用一个新的 ClassLoader 重新加载修改后的类，让新对象用新版本
2. **改字节码**：通过 JVMTI 的 `redefineClasses` / `retransformClasses` 直接在内存中替换已加载类的字节码

今天我们就从这两条路出发，把 Tomcat、Spring Boot DevTools、JRebel、Arthas 的热部署原理一次讲透。

## 一、先复习：类加载器与双亲委派

JVM 内置三个类加载器：

| 类加载器 | 加载范围 |
|---------|---------|
| Bootstrap（启动类加载器） | `rt.jar`、JDK 核心类，C++ 实现 |
| Extension/Platform（扩展类加载器） | `jre/lib/ext`，JDK 9+ 改为 Platform |
| Application（应用类加载器） | classpath 下的用户类 |

**双亲委派**：加载一个类时先交给父加载器，父加载器找不到才自己加载。它保证了核心类不被篡改、类只被加载一次。

但双亲委派有一个"副作用"：**同一个类名 + 同一个类加载器 = 唯一**。反过来，只要换一个类加载器，同一个全限定名的类就能以"新版本"的身份存在——这就是热部署的第一原理。

```java
// 自定义类加载器：打破双亲委派，自己加载指定目录的类
public class HotDeployClassLoader extends ClassLoader {
    private final String baseDir;

    public HotDeployClassLoader(String baseDir, ClassLoader parent) {
        super(parent);           // 保持双亲委派：先让父加载器尝试
        this.baseDir = baseDir;
    }

    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        String path = baseDir + "/" + name.replace('.', '/') + ".class";
        try {
            byte[] bytes = Files.readAllBytes(Paths.get(path));
            return defineClass(name, bytes, 0, bytes.length);
        } catch (IOException e) {
            throw new ClassNotFoundException(name, e);
        }
    }
}
```

注意 `findClass` 是"兜底"方法：父加载器先找，找不到才轮到它。这样 JDK 类永远不会被热替换，只有业务类走新版本。

## 二、Tomcat 的类加载器隔离体系

Tomcat 之所以能部署多个应用互不干扰，靠的就是一套"树形"类加载器结构：

```
Bootstrap
 └── System（应用类加载器）
      └── Common（公共类：Servlet API 等，Tomcat 与所有应用共享）
           ├── Catalina（Tomcat 自身）
           ├── Shared（所有 Web 应用共享）
           │    ├── Webapp1（应用1的 /WEB-INF/classes 和 /WEB-INF/lib）
           │    └── Webapp2（应用2的 /WEB-INF/classes 和 /WEB-INF/lib）
```

**关键点**：每个 WebappClassLoader 独立加载各自应用的类，应用 A 的 `com.demo.User` 和应用 B 的 `com.demo.User` 是两个完全不同的类（即使字节码相同，`Class` 对象不同，`==` 比较为 false，强转会抛 ClassCastException）。这也解释了为什么两个应用同名类不会冲突。

Tomcat 还**打破**了双亲委派的一处：Webapp 类加载器会**优先自己加载** `/WEB-INF/classes` 和 `/WEB-INF/lib` 里的类，而不是先交给父加载器——否则应用自己打的 jar 可能被父加载器里同名类"截胡"。这叫"先子后父"的局部打破。

**而 Tomcat 的 reload 热部署**（改 JSP/class 自动重载）原理就是：监听文件变化 → 丢弃旧的 WebappClassLoader → 新建一个重新加载整个应用。

## 三、Spring Boot DevTools：两套类加载器的重启术

Spring Boot DevTools 的"自动重启"比 Tomcat 轻量得多，它把类分成两组：

- **基础类**（依赖 jar、第三方库）→ 由 `BaseClassLoader` 加载，**只加载一次**
- **应用类**（你自己写的代码）→ 由 `RestartClassLoader` 加载

当源码变化触发重启时，DevTools **只丢弃并重建 RestartClassLoader**，基础类原样保留。这样重启开销远小于全量启动——这就是 DevTools 重启"快"的秘密。它也不是真正的热替换，而是"轻量重启"，应用上下文（Spring 容器）会重新 refresh 一遍。

限制也很明确：静态字段会被重置（新类加载器 = 新 static 状态）、已持有旧类引用的对象不会自动切换、依赖注入的 Bean 需要容器重建才能拿到新类。

## 四、JRebel：字节码重定义的真正"热替换"

JRebel 走的是完全不同的路线——**不重启，不改类加载器**，而是用 JVM 的 Instrumentation 机制在运行时**重定义**已加载的类。

它通过 `-javaagent:jrebel.jar` 以 Agent 方式挂载进 JVM，核心调用：

```java
// JVMTI 提供的重定义接口（Instrumentation 封装）
instrumentation.redefineClasses(
    new ClassDefinition(targetClass, newBytecode)
);
```

`redefineClasses` 的限制：不能增删字段、不能增删方法签名（只能改方法体），否则抛 `UnsupportedOperationException`。所以 JRebel 修改方法体（最常见场景）没问题，但如果改了类结构（加了字段/方法），它内部会"作弊"——用字节码生成框架（ASM/Javassist）把新旧结构差异通过生成辅助类来弥合。

实现层面，JRebel 会在类加载时**改写字节码**：把字段访问、方法调用插入一层间接层（类似 AOP 的拦截），这样类被 redefine 后，所有引用点都能自动拿到新版本，连 Spring 容器里已存在的 Bean 也"活"过来了。

对比一下两种技术路线：

| 维度 | 换类加载器（Tomcat/DevTools） | 字节码重定义（JRebel/Arthas） |
|------|------------------------------|------------------------------|
| 是否重启 | 部分重启（轻量重启） | 完全不重启 |
| 修改方法体 | 支持 | 支持 |
| 增删字段/方法 | 支持 | 不支持（redefine 限制） |
| static 状态 | 丢失 | 保留 |
| 已存在对象 | 不切换（除非容器重建） | 自动生效（JRebel 有间接层） |
| 生产环境使用 | 常用于灰度发布 | Arthas redefine 应急热修 |

## 五、Arthas redefine：生产环境应急热修

线上出了 bug，不能重启（Session 会断、流量会丢），可以用 Arthas 的 `redefine` 命令应急：

```
# 1. 用 javac 编译修复后的类（指定 -classpath 保证能找到依赖）
javac -cp /path/to/app/lib/* -d /tmp/fix com/demo/OrderService.java

# 2. 进入 Arthas，attach 到目标 JVM
java -jar arthas-boot.jar

# 3. 热替换
redefine /tmp/fix/com/demo/OrderService.class
```

底层同样是 `Instrumentation.redefineClasses`。注意几个实战要点：

1. **只能改方法体**，不能改字段/方法签名，否则报错
2. redefine 后 **static 变量、已创建对象的旧引用**不会自动更新，只对新调用生效——所以更适合修"方法内部逻辑"
3. 配合 `watch` / `trace` 命令先定位问题，再决定要不要热修
4. 热修是**临时方案**，必须尽快发正式版本，并在文档中记录

## 六、手写一个最简热部署 Demo

把前面两节串起来，一个 50 行的热部署骨架：

```java
public class HotDeployDemo {
    public static void main(String[] args) throws Exception {
        String dir = "/tmp/hotdeploy";
        while (true) {
            // 每次循环新建类加载器 → 模拟"版本升级"
            HotDeployClassLoader loader = new HotDeployClassLoader(dir, HotDeployDemo.class.getClassLoader());
            Class<?> clazz = loader.loadClass("com.demo.Greeter");
            Object obj = clazz.getDeclaredConstructor().newInstance();
            Method m = clazz.getMethod("hello");
            m.invoke(obj);            // 输出 Hello v1 / v2 ...
            Thread.sleep(3000);
        }
    }
}
```

运行后，直接替换 `/tmp/hotdeploy/com/demo/Greeter.class`，下一个循环就会输出新版本——因为新类加载器会重新读字节码。注意：**这里必须用反射调用**，不能强转成接口编译期引用，否则 JVM 拿到的还是旧类的字节码形态（编译期绑定），这也是热部署框架普遍用反射/动态代理的原因。

## 七、热部署的坑，一个都别踩

1. **类加载器泄漏**：旧的 ClassLoader 被长期引用（比如 static 持有旧对象、ThreadLocal 存了旧类实例），导致类卸载不了 → 频繁热部署引发 Metaspace OOM。DevTools 重启几百次后 Metaspace 暴涨就是典型症状
2. **static 状态丢失**：换类加载器后 static 变量重新初始化，缓存、连接池全没了
3. **类型不一致**：新旧类加载器加载的"同名类"不兼容，传递引用会 ClassCastException
4. **redefine 结构限制**：改字段/方法签名会直接失败，生产热修前先在测试环境验证
5. **双亲委派被过度打破**：如果自定义类加载器把 JDK 类也抢来加载，直接 `SecurityException`

## 总结

热部署的两条技术路线：**换类加载器**（Tomcat reload、DevTools 轻量重启，实现简单、支持结构变更、代价是状态丢失和轻量重启）与**字节码重定义**（JRebel、Arthas redefine，基于 JVMTI Instrumentation，不重启但只能改方法体）。理解类加载器的唯一性规则、双亲委派与隔离体系，是理解所有热部署方案的钥匙。下次面试被问"热部署原理"，从这两条路答起，再补上各自代表框架和坑点，就是一份满分级答案。
