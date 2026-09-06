---
title: 【Java 实战】ByteBuddy 字节码增强深度实战：从动态生成类到 Java Agent 无侵入埋点
date: 2026-09-06 08:00:00
tags:
  - Java
  - 字节码
  - ByteBuddy
  - 进阶
categories:
  - Java
  - JVM 底层
author: 东哥
---

# 【Java 实战】ByteBuddy 字节码增强深度实战：从动态生成类到 Java Agent 无侵入埋点

## 从一个需求说起

老王接了个需求：给公司里一个**第三方闭源 SDK** 的核心方法加上耗时统计和参数日志。翻遍 SDK 的 jar，全是编译好的 class，既没有源码也改不了。上网一搜，方案有三个：

1. **JDK 动态代理**——SDK 的类根本不是接口，代理个寂寞；
2. **CGLIB**——父类被 `final` 修饰，直接拒绝；
3. **ASM 手写**——要懂 ClassFile 规范、visit 方法调用顺序，改一个方法几十行样板代码。

正当一筹莫展时，老同事悠悠地说："用 ByteBuddy 啊，三行代码搞定。"

这就是 ByteBuddy 的价值：**一个让你像写普通 Java 代码一样操作字节码的库**，底层基于 ASM，却把复杂度全部封装掉。本文从 API 入门讲到 Java Agent 无侵入埋点，全程带代码，建议收藏。

## 一、为什么需要字节码增强？

先建立一个共识：**运行时增强类的能力，是几乎所有 Java 框架的根基**。

| 场景 | 典型代表 | 技术 |
|------|---------|------|
| ORM 动态实现接口 | MyBatis Mapper | JDK 动态代理（接口） |
| 方法级 AOP | Spring AOP | JDK Proxy / CGLIB |
| Mock 框架 | Mockito | ByteBuddy / CGLIB |
| 无侵入监控、APM | SkyWalking、Arthas | Java Agent + 字节码插桩 |
| 编译期生成代码 | Lombok | APT（编译期，非运行时） |
| 动态生成实现类 | 各种"懒人框架" | ByteBuddy |

核心矛盾在于：**Java 类一旦加载就无法修改结构**（只能 redefine/retransform 方法体），所以要在"类加载前/加载时"动手脚，或者干脆动态生成一个全新的类。ByteBuddy 把这三条路都做成了傻瓜式 API。

## 二、ByteBuddy 入门：三分钟生成一个类

Maven 依赖（`byte-buddy` 是核心库，`byte-buddy-agent` 用于运行时 attach）：

```xml
<dependency>
    <groupId>net.bytebuddy</groupId>
    <artifactId>byte-buddy</artifactId>
    <version>1.15.11</version>
</dependency>
<dependency>
    <groupId>net.bytebuddy</groupId>
    <artifactId>byte-buddy-agent</artifactId>
    <version>1.15.11</version>
</dependency>
```

### 2.1 动态创建子类并重写方法

需求：给 `OrderService` 的 `createOrder` 方法偷偷加一行日志，不改原类。

```java
public class OrderService {
    public String createOrder(String orderNo) {
        return "订单创建成功: " + orderNo;
    }
}
```

```java
import net.bytebuddy.ByteBuddy;
import net.bytebuddy.implementation.MethodDelegation;
import net.bytebuddy.matcher.ElementMatchers;

public class ByteBuddyDemo1 {
    public static void main(String[] args) throws Exception {
        Class<? extends OrderService> proxyClass = new ByteBuddy()
                // 1. 指定父类
                .subclass(OrderService.class)
                // 2. 匹配要拦截的方法
                .method(ElementMatchers.named("createOrder"))
                // 3. 拦截后委托给 LogInterceptor
                .intercept(MethodDelegation.to(LogInterceptor.class))
                // 4. 生成 Class 对象
                .make()
                // 5. 用 WRAPPER 策略加载（子加载器，父类可见）
                .load(ByteBuddyDemo1.class.getClassLoader(),
                        ClassLoadingStrategy.Default.WRAPPER)
                .getLoaded();

        OrderService service = proxyClass.getDeclaredConstructor().newInstance();
        System.out.println(service.createOrder("NO-20260906-001"));
    }
}
```

拦截器长这样——`@SuperCall` 用来调用原方法，这是 ByteBuddy 最优雅的设计：

```java
import net.bytebuddy.implementation.bind.annotation.AllArguments;
import net.bytebuddy.implementation.bind.annotation.Origin;
import net.bytebuddy.implementation.bind.annotation.SuperCall;

import java.lang.reflect.Method;
import java.util.concurrent.Callable;

public class LogInterceptor {
    // 方法签名必须匹配：返回 Object，参数要能接住原方法参数
    public static Object log(@Origin Method method,
                             @AllArguments Object[] args,
                             @SuperCall Callable<?> callable) throws Exception {
        long start = System.currentTimeMillis();
        System.out.println("[ByteBuddy] 调用 " + method.getName()
                + "，参数: " + java.util.Arrays.toString(args));
        try {
            return callable.call();          // 调用原方法
        } finally {
            System.out.println("[ByteBuddy] " + method.getName()
                    + " 耗时 " + (System.currentTimeMillis() - start) + " ms");
        }
    }
}
```

输出：

```
[ByteBuddy] 调用 createOrder，参数: [NO-20260906-001]
[ByteBuddy] createOrder 耗时 1 ms
订单创建成功: NO-20260906-001
```

注意几个关键点：

- `MethodDelegation.to()` 把调用**委托给任意类的静态方法或实例方法**，方法匹配靠注解而非方法名，灵活得多；
- `@Origin` 注入被调用的 `Method` 对象；`@AllArguments` 注入全部参数；`@SuperCall` 注入一个 `Callable`，调用它等于调用原方法——**完美解决了"拦截后还要执行原逻辑"的问题**；
- 默认情况下，被拦截的方法参数类型、返回类型要和拦截器方法**兼容**，否则抛 `IllegalArgumentException`。

### 2.2 动态实现一个接口

MyBatis 的 Mapper 就是"接口没有实现类"的典型。ByteBuddy 也能干这事：

```java
public interface UserMapper {
    User findById(Long id);
}

Class<? extends UserMapper> mapperClass = new ByteBuddy()
        .subclass(UserMapper.class)              // 接口也能 subclass
        .method(ElementMatchers.named("findById"))
        .intercept(FixedValue.value(new User(1L, "东哥")))   // 固定返回值
        .make()
        .load(ByteBuddyDemo1.class.getClassLoader(), ClassLoadingStrategy.Default.WRAPPER)
        .getLoaded();

UserMapper mapper = mapperClass.getDeclaredConstructor().newInstance();
System.out.println(mapper.findById(1L));  // User(id=1, name=东哥)
```

`FixedValue` 适合固定返回值；想根据参数动态返回，还是用 `MethodDelegation`。

## 三、无侵入埋点：Java Agent 才是终极形态

子类化方案有个硬伤：**只能增强"还没 new 出来的对象"**。如果 SDK 内部自己 `new` 了核心类（比如 `new KafkaConsumer(...)`），你没法把已存在的实例换成子类。此时必须上 **Java Agent**：在类加载时直接改写字节码，或者对已加载类做 retransform。

### 3.1 premain：应用启动前挂载

打一个 agent jar，`MANIFEST.MF` 里声明：

```
Premain-Class: com.example.agent.TraceAgent
Can-Redefine-Classes: true
Can-Retransform-Classes: true
```

agent 代码用 ByteBuddy 的 `AgentBuilder` 非常简洁：

```java
import net.bytebuddy.agent.builder.AgentBuilder;
import net.bytebuddy.agent.builder.AgentBuilder.RedefinitionStrategy;
import net.bytebuddy.agent.builder.AgentBuilder.Listener;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.dynamic.DynamicType;
import net.bytebuddy.implementation.MethodDelegation;
import net.bytebuddy.utility.JavaModule;

import java.lang.instrument.Instrumentation;

public class TraceAgent {
    public static void premain(String args, Instrumentation inst) {
        new AgentBuilder.Default()
                // 拦截哪个类：包名匹配，避免把自己搞进去
                .type(AgentBuilder.TypeDescriptionMatcher.anyOf(
                        TypeDescription.ForLoadedType.of(com.example.sdk.PaymentClient.class)))
                // 拦截哪些方法
                .transform((builder, typeDescription, classLoader, module, protectionDomain) ->
                        builder.method(ElementMatchers.named("pay"))
                                .intercept(MethodDelegation.to(LogInterceptor.class)))
                // 类已加载时也做 retransform
                .with(RedefinitionStrategy.RETRANSFORMATION)
                .with(Listener.StreamWriting.toSystemOut())   // 打印增强日志，方便排查
                .installOn(inst);
    }
}
```

启动目标应用时带上 `-javaagent:/path/to/trace-agent.jar`，之后 `PaymentClient.pay()` 的每次调用都会被 LogInterceptor 包一层——**源码零改动，这就是 APM 类产品的基本原理**（SkyWalking 的 Java Agent 核心就是 ByteBuddy 驱动的 AgentBuilder 插桩体系）。

### 3.2 attach：运行中动态挂载（不需要重启）

不想重启应用？用 `ByteBuddyAgent`：

```java
import net.bytebuddy.agent.ByteBuddyAgent;

public class AttachDemo {
    public static void main(String[] args) {
        // 拿到运行中 JVM 的 Instrumentation（依赖 jdk.attach 模块）
        Instrumentation inst = ByteBuddyAgent.install();
        // 之后同样走 AgentBuilder.installOn(inst) 即可
    }
}
```

Java 9+ 模块化后，attach 到自己 JVM 需要 `--add-opens` 或 JDK 内部模块开放（ByteBuddyAgent 会自动处理一部分），这也是 Arthas 这类工具的原理。

## 四、ByteBuddy 与 JDK Proxy / CGLIB / ASM 的对比

| 维度 | JDK 动态代理 | CGLIB | ASM | ByteBuddy |
|------|-------------|-------|-----|-----------|
| 底层 | 反射 + Proxy | ASM | 字节码操作 | **ASM 封装** |
| 增强对象 | **仅接口** | 类（final 不行） | 任意类 | 任意类（含 Agent 改已加载类） |
| 易用性 | 简单 | 中等 | 极难 | **简单** |
| 性能 | 反射调用较慢 | 生成子类，较快 | 最高（裸字节码） | 接近 ASM（生成后无反射损耗） |
| 代码量 | 少 | 中 | 巨大 | 少 |
| 典型场景 | Spring AOP 默认 | 无接口 Bean | 框架作者 | Mockito、Agent 插桩 |

一句话总结：**JDK Proxy 限制多，CGLIB 正在被 ByteBuddy 取代（Spring Boot 3 / Mockito 5 都已转向 ByteBuddy），ASM 是底层但不适合业务开发，ByteBuddy 是工程最优解**。

## 五、面试官追问

**Q1：ByteBuddy 和 ASM 是什么关系？**
ByteBuddy 底层就是 ASM，它把 ClassVisitor 那套访问者模式的繁琐调用封装成了流式 API。你写 `new ByteBuddy().subclass(...)` 时，它内部会生成一个 ClassWriter 去产出字节码。

**Q2：`@SuperCall` 是怎么实现的？为什么没有死循环？**
ByteBuddy 在生成子类时，会为被拦截方法创建一个**别名方法**（super 调用），`@SuperCall` 注入的 `Callable` 内部调用的其实是这个别名方法，直接走 `invokespecial` 调父类实现，不再经过拦截逻辑，所以不会递归。

**Q3：`ClassLoadingStrategy.Default` 的 WRAPPER / CHILD_FIRST / INJECTION 有什么区别？**
- `WRAPPER`：创建一个**新的子加载器**，父加载器是传入的加载器，动态类对原代码不可见（隔离，最常用）；
- `CHILD_FIRST`：子加载器优先加载自己定义的类，用于解决依赖冲突（比如给应用塞一个不同版本的库）；
- `INJECTION`：用反射把类**注入到目标加载器**（需要目标加载器开放 defineClass），适合需要和父类同加载器的场景（Spring 场景常用）。

**Q4：用 Agent 增强已经加载的类，会有什么坑？**
第一，只能改方法体，不能增删字段/方法/修改继承关系（redefine 的限制）；第二，热替换时若新字节码引用了不存在的类会抛 `NoClassDefFoundError`；第三，被增强类如果正在执行，retransform 后旧栈帧仍是旧字节码，可能行为不一致；第四，别增强 JDK 自带的类，Java 9+ 强封装下容易踩模块边界。

**Q5：ByteBuddy 动态生成的类存在哪里？会不会内存泄漏？**
生成的类存在**元空间（Metaspace）**，由对应的 ClassLoader 管理——`WRAPPER` 策略每次都会 new 一个加载器，如果循环生成类且持有 Class 引用，会导致 Metaspace 撑爆。所以**能复用就复用，别在热路径上反复 make()**。

## 六、生产实践建议

1. **优先选"创建时增强"，而不是"全局 Agent"**：Agent 影响面大、排障难，能通过工厂方法返回增强子类解决就别上 Agent；
2. **拦截器里别抛受检异常**，ByteBuddy 对签名有严格要求，出错时先看 `IllegalArgumentException` 的详细 message；
3. **Agent 插桩一定要加 Listener 打日志**，否则"静默没生效"比"报错"更难查；
4. 增强第三方类时，用 `ElementMatchers` 精确匹配（类名 + 方法名 + 参数类型），宁可漏不可误伤；
5. 关注 `AgentBuilder.RedefinitionStrategy` 与 `TypeStrategy` 的配合，复杂场景直接抄 SkyWalking 的开源配置思路。

ByteBuddy 是那种"会了之后写工具效率翻倍"的库：动态 Mock、接口快速实现、无侵入监控、热修复，甚至你每天用的 Lombok 替代品（编译期）和 Mockito（运行时）都在用它。建议动手跑一遍文中的 Demo，把 `@SuperCall`、`AgentBuilder` 这两个核心点吃透，面试和实战都能用上。
