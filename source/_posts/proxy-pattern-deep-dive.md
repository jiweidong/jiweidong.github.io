---
title: 【设计模式】代理模式深度解析：从静态代理到动态代理的框架级应用
date: 2026-08-26 08:00:00
tags:
  - Java
  - 设计模式
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】代理模式深度解析：从静态代理到动态代理的框架级应用

## 面试官：说说什么是代理模式？它在 Spring 里是怎么用的？

代理模式（Proxy Pattern）是 GoF 23 种设计模式中使用频率极高的一种，它属于**结构型模式**。核心思想一句话：**不直接操作目标对象，而是通过一个代理对象间接访问，在代理中增加额外的控制逻辑**。

你想想，Spring AOP、MyBatis 的 Mapper 接口、OpenFeign 的远程调用、RPC 框架的透明调用、Hystrix/Sentinel 的降级……底层全是代理模式。可以说，不懂代理模式，就谈不上理解这些框架。

本文从静态代理讲起，一路深入到 JDK 动态代理、CGLIB 的原理与源码，最后落到框架级应用，看完这一篇，代理模式彻底拿捏。

## 一、代理模式的结构与类型

### 1.1 三个角色

代理模式有三个核心角色：

| 角色 | 说明 | 举例 |
|------|------|------|
| 抽象主题（Subject） | 定义业务方法的接口 | `UserService` |
| 真实主题（RealSubject） | 真正执行业务逻辑的对象 | `UserServiceImpl` |
| 代理（Proxy） | 持有真实主题引用，控制访问并增强逻辑 | `UserServiceProxy` |

### 1.2 两种分类维度

按**创建时机**分：

- **静态代理**：编译期就确定代理类，一个代理类只能代理一个接口，代码是手写的。
- **动态代理**：运行期通过反射/字节码技术动态生成代理类，一套代码代理任意接口。

按**控制目的**分：访问控制代理（权限校验）、远程代理（RPC 本地桩）、虚拟代理（延迟加载）、保护代理（安全检查）、日志代理（增强记录）等。实际开发中最常见的是**增强型代理**（日志、事务、监控）。

## 二、静态代理：最朴素的实现

静态代理就是**手动写一个代理类**，和目标类实现同一个接口，在代理类里持有目标对象引用：

```java
// 抽象主题
public interface UserService {
    void addUser(String name);
}

// 真实主题
public class UserServiceImpl implements UserService {
    @Override
    public void addUser(String name) {
        System.out.println("添加用户: " + name);
        // 模拟业务耗时
        try { Thread.sleep(100); } catch (InterruptedException ignored) {}
    }
}

// 静态代理：增强日志与耗时统计
public class UserServiceProxy implements UserService {
    private final UserService target;

    public UserServiceProxy(UserService target) {
        this.target = target;
    }

    @Override
    public void addUser(String name) {
        long start = System.currentTimeMillis();
        System.out.println("[日志] 开始调用 addUser");
        target.addUser(name);                      // 调用真实业务
        System.out.println("[日志] addUser 耗时 " + (System.currentTimeMillis() - start) + "ms");
    }
}

// 使用
UserService service = new UserServiceProxy(new UserServiceImpl());
service.addUser("东哥");
```

### 静态代理的痛点

1. **类爆炸**：每个接口都要写一个代理类，接口有 100 个方法就要重复写 100 遍样板代码。
2. **侵入性**：新增一个增强逻辑（比如加事务），所有代理类都要改。
3. **只能代理固定接口**：换一个接口，又得重新写。

所以生产环境很少直接手写静态代理，但**静态代理的思想**（组合 + 增强）是一切动态代理的地基。

## 三、JDK 动态代理：反射的艺术

### 3.1 最小实现

JDK 动态代理只需要 `java.lang.reflect.Proxy` 和 `InvocationHandler` 两个类：

```java
public class LogInvocationHandler implements InvocationHandler {
    private final Object target;          // 目标对象

    public LogInvocationHandler(Object target) {
        this.target = target;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        long start = System.currentTimeMillis();
        System.out.println("[日志] 调用方法: " + method.getName());
        Object result = method.invoke(target, args);   // 反射调用目标方法
        System.out.println("[日志] " + method.getName() + " 耗时 " + (System.currentTimeMillis() - start) + "ms");
        return result;
    }
}

// 创建代理对象
UserService proxy = (UserService) Proxy.newProxyInstance(
        UserService.class.getClassLoader(),          // 类加载器
        new Class[]{UserService.class},              // 要代理的接口列表
        new LogInvocationHandler(new UserServiceImpl())  // 增强逻辑
);
proxy.addUser("东哥");
```

一套代码，代理任意接口。这就是动态代理的第一个价值：**通用性**。

### 3.2 源码级原理：代理类是怎么生成的？

`Proxy.newProxyInstance()` 内部做了三件事：

1. `getProxyClass0()` → 通过 `ProxyClassFactory` 在运行时**生成代理类的字节码**（类名形如 `$Proxy0`、`$Proxy1`，从 ClassLoader 缓存或新生成）。
2. 生成的 `$Proxy0` **继承 `Proxy` 类**、**实现你传入的所有接口**。
3. 通过构造器传入 `InvocationHandler`，代理类的所有接口方法调用都被重写为：

```java
// $Proxy0 的 addUser 方法内部（伪代码）
public final void addUser(String name) {
    try {
        super.h.invoke(this, addUserMethod, new Object[]{name});
        // super.h 就是构造器传入的 InvocationHandler
    } catch (RuntimeException | Error e) {
        throw e;
    } catch (Throwable t) {
        throw new UndeclaredThrowableException(t);
    }
}
```

所以整个调用链是：

```
调用方 → $Proxy0.addUser() → InvocationHandler.invoke() → 反射 Method.invoke() → 真实对象
```

### 3.3 JDK 动态代理的致命限制

**JDK 动态代理只能代理接口**！因为生成的 `$Proxy0` 已经继承了 `Proxy` 类，Java 单继承，没法再继承目标类。如果你的目标类没有实现任何接口（只有具体类），JDK 动态代理直接歇菜。

> 面试追问：Spring 里 `@Transactional` 加在类上、且类没实现接口时，事务为什么经常失效？
> 答：因为此时 Spring 只能用 CGLIB 生成代理，而如果你的配置是 `proxy-target-class=false`（JDK 代理模式），代理根本创建不出来，事务自然失效；另一个经典坑是**同类内部方法自调用**（`this.method()`）绕过代理，事务同样失效。

## 四、CGLIB 动态代理：继承的艺术

CGLIB（Code Generation Library）通过**继承目标类生成子类**来代理，所以**不要求目标类实现接口**。

```java
// 目标类：没有接口
public class OrderService {
    public void createOrder(String orderId) {
        System.out.println("创建订单: " + orderId);
    }
}

// 1. 使用 Enhancer + MethodInterceptor（类似 InvocationHandler）
Enhancer enhancer = new Enhancer();
enhancer.setSuperclass(OrderService.class);            // 设置父类（被代理类）
enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) -> {
    System.out.println("[日志] 调用: " + method.getName());
    Object result = proxy.invokeSuper(obj, args);      // 调用父类方法（注意是 invokeSuper）
    System.out.println("[日志] 结束: " + method.getName());
    return result;
});
OrderService proxy = (OrderService) enhancer.create();
proxy.createOrder("20260826001");
```

### CGLIB 的底层原理

1. 运行时用 ASM 字节码框架**生成目标类的子类**（如 `OrderService$$EnhancerByCGLIB$$xxxx`）。
2. 子类**重写目标类的所有非 final、非 private 方法**，在重写方法里回调 `MethodInterceptor.intercept()`。
3. 因为是继承，**final 类、final 方法无法被 CGLIB 代理**——这也是 Spring 文档明确警告「不要在 @Configuration 类上滥用 final」的原因（Spring 5.2+ 的配置类默认 CGLIB 代理，final 方法会导致增强失效）。

> 面试追问：JDK 动态代理和 CGLIB 怎么选？
> ① 目标有接口 → 优先 JDK 动态代理（Spring 默认策略，代理对象更轻、依赖更少）；
> ② 目标无接口 → CGLIB；
> ③ 性能对比：JDK 8+ 反射性能大幅优化，两者差距已很小；CGLIB 创建代理对象更慢（要生成字节码），但调用性能略优（无需反射，直接方法调用）。

## 五、框架级应用：代理模式无处不在

### 5.1 Spring AOP：代理模式的集大成者

Spring AOP 的核心就是**动态代理**：`@Aspect` 切面类的方法会被织入代理对象，`@Before`、`@Around` 等增强逻辑全部通过 `InvocationHandler`/`MethodInterceptor` 回调执行。

- 目标类实现了接口 → 默认 JDK 动态代理（`JdkDynamicAopProxy`）
- 目标类没有接口 → CGLIB 代理（`CglibAopProxy`）

```
调用方 → AOP 代理对象 → 切面增强(@Around/@Before/@After) → 目标方法
```

这也是为什么**同一个类内部方法互相调用不会走 AOP 增强**——内部 `this.method()` 调的是原始对象，不是代理对象。解决：注入自身代理（`@Lazy` 自引用）或拆到另一个 Bean。

### 5.2 MyBatis：Mapper 接口的动态代理

你只写了一个 `UserMapper` 接口，MyBatis 凭什么能执行 SQL？答案是 `MapperProxyFactory` 为每个 Mapper 接口生成了 `MapperProxy`（实现 `InvocationHandler`）：

```java
// MapperProxy.invoke() 核心逻辑（MyBatis 源码）
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    if (Object.class.equals(method.getDeclaringClass())) {
        return method.invoke(this, args);      // toString/hashCode 等直接放行
    }
    // 解析方法上的 @Select/@Insert 注解或 XML 中的 SQL，执行并返回结果
    return cachedInvoker(method).invoke(proxy, method, args, sqlSession);
}
```

所以你调 `userMapper.selectById(1)`，实际是代理对象把方法信息映射成 MappedStatement，交给 SqlSession 执行。**MyBatis 的 Mapper 只有接口没有实现类**，全靠代理模式撑起来。

### 5.3 OpenFeign / RPC：远程调用的透明代理

OpenFeign 的 `FeignClientFactoryBean` 为每个 `@FeignClient` 接口生成代理，调用方法时代理内部把参数序列化、发起 HTTP 请求、反序列化返回——**调用方感知不到远程通信**。Dubbo、gRPC 的客户端桩同理，都是代理模式的应用。

### 5.4 Spring 事务：@Transactional 的载体

`@Transactional` 之所以生效，是因为 Spring 为 Bean 创建了事务代理（`TransactionInterceptor` 回调），在方法执行前开启事务、异常时回滚、正常时提交。**代理没了，事务就没了**。

## 六、代理模式 vs 装饰器模式：别搞混了

| 对比维度 | 代理模式 | 装饰器模式 |
|---------|---------|-----------|
| 目的 | **控制访问**，代理决定"能不能调、怎么调" | **增强功能**，动态叠加新行为 |
| 关注点 | 访问控制、延迟加载、日志、安全 | 功能扩展（如 IO 流的缓冲、压缩） |
| 创建者 | 通常由客户端/框架创建，目标类不可见 | 客户端显式层层包装 |
| 生命周期 | 代理对象与目标对象关系固定 | 装饰器可任意组合、层层嵌套 |
| 典型例子 | Spring AOP、MyBatis Mapper、Feign | Java IO：`new BufferedInputStream(new FileInputStream(...))` |

一句话记忆：**代理管"门禁"，装饰器管"加料"**。

## 七、手写一个极简 AOP 框架（10 行核心）

理解了原理，手写一个基于 JDK 动态代理的迷你 AOP 验证一下：

```java
// 1. 定义切面接口
public interface MethodInterceptor {
    Object invoke(MethodInvocation invocation) throws Throwable;
}

// 2. 定义调用链对象
public class MethodInvocation {
    private final Object target;
    private final Method method;
    private final Object[] args;

    public Object proceed() throws Throwable {
        return method.invoke(target, args);
    }
    // 构造器省略
}

// 3. 代理工厂：把拦截器链织入目标对象
public class ProxyFactory {
    public static <T> T create(T target, MethodInterceptor... interceptors) {
        return (T) Proxy.newProxyInstance(
                target.getClass().getClassLoader(),
                target.getClass().getInterfaces(),
                (proxy, method, args) -> {
                    MethodInvocation invocation = new MethodInvocation(target, method, args);
                    // 简单实现：反向执行拦截器链（责任链思想）
                    for (int i = interceptors.length - 1; i >= 0; i--) {
                        MethodInterceptor mi = interceptors[i];
                        MethodInvocation cur = invocation;
                        invocation = new MethodInvocation(mi, MethodInvocation.class.getMethod("proceed"), new Object[]{});
                        // 实际工程会用 LinkedList 维护链，此处示意
                    }
                    return invocation.proceed();
                });
    }
}
```

（真实 AOP 会用责任链模式把多个切面串成拦截器链，和 Spring 的 `MethodInterceptor` 链、Netty 的 `ChannelPipeline` 异曲同工。）

## 八、面试追问汇总

1. **JDK 动态代理为什么只能代理接口？** 生成的代理类已继承 `Proxy`，Java 单继承限制。
2. **CGLIB 能代理 final 类吗？** 不能，子类化方案天然失效。
3. **Spring 默认用哪种代理？** 有接口用 JDK，无接口用 CGLIB（也可强制 `proxy-target-class=true`）；Spring Boot 2.x+ 默认 `proxy-target-class=true`，一律 CGLIB。
4. **为什么自调用不走 AOP？** `this` 是原始对象，不是代理对象。
5. **代理模式和装饰器模式区别？** 控制访问 vs 增强功能（见上表）。
6. **动态代理的性能开销？** 创建时生成字节码/反射有开销，但可缓存；JDK 8+ 调用性能接近直接调用；高频场景可用字节码增强（ASM）或 AOT 消除反射。

## 总结

代理模式是理解 Spring AOP、MyBatis、Feign、RPC 等框架的**钥匙**。核心脉络：静态代理（手写、类爆炸）→ JDK 动态代理（接口、反射、`$Proxy0`）→ CGLIB（继承、ASM 字节码）→ 框架级应用（AOP/MyBatis/Feign/事务）。面试时能把这个链路讲清楚，再手写一个 InvocationHandler，这道题就稳了。
