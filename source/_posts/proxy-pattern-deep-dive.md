---
title: 【设计模式】代理模式深度解析：从静态代理到 JDK 动态代理与 CGLIB 的进阶之路
date: 2026-08-31 08:00:00
tags:
  - 设计模式
  - Java
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】代理模式深度解析：从静态代理到 JDK 动态代理与 CGLIB 的进阶之路

## 面试官：代理模式解决了什么问题？JDK 动态代理和 CGLIB 有什么区别？

代理模式是 Spring AOP、MyBatis、RPC 框架的地基，也是面试必考。很多同学能背出「JDK 动态代理基于接口、CGLIB 基于继承」，但一问「为什么 Spring 默认用 JDK 代理」「@Transactional 自调用为什么失效」就懵了。本文从静态代理一路讲到源码级对比。

## 一、代理模式：不改变目标类，却能在调用前后插入逻辑

### 定义

**给目标对象提供一个代理对象，由代理对象控制对目标对象的访问**。调用方只跟代理打交道，代理在转发调用前后可以附加额外逻辑。

### 解决什么问题？

1. **开闭原则**：不改原有类代码，就能扩展功能（日志、鉴权、事务、监控）；
2. **解耦**：把「业务逻辑」和「横切逻辑」分开，横切逻辑收敛到代理里统一处理；
3. **控制访问**：远程调用（RPC）、延迟加载（MyBatis 懒加载）、安全校验。

### 角色

```
Subject（抽象接口）          —— 定义业务方法
RealSubject（目标类）        —— 真正的业务实现
Proxy（代理类）              —— 持有目标引用，转发并增强
```

## 二、静态代理：最简单，但一个代理只能服务一个类

```java
// 1. 抽象接口
public interface UserService {
    void addUser(String name);
}

// 2. 目标类
public class UserServiceImpl implements UserService {
    public void addUser(String name) {
        System.out.println("添加用户: " + name);
    }
}

// 3. 静态代理类：和目标类实现同一接口，持有目标引用
public class UserServiceProxy implements UserService {
    private final UserService target;

    public UserServiceProxy(UserService target) {
        this.target = target;
    }

    public void addUser(String name) {
        System.out.println("[日志] 调用 addUser 开始");
        target.addUser(name);
        System.out.println("[日志] 调用 addUser 结束");
    }
}

// 使用
UserService service = new UserServiceProxy(new UserServiceImpl());
service.addUser("东哥");
```

**缺点**：每个需要增强的类都要手写一个代理类，接口加方法代理也要跟着改 —— 类爆炸、维护成本高。所以有了动态代理。

## 三、JDK 动态代理：运行时生成代理类

JDK 动态代理利用**反射**，在运行时动态生成一个实现指定接口的代理类，不需要手写代理类。

```java
public class LogInvocationHandler implements InvocationHandler {
    private final Object target;

    public LogInvocationHandler(Object target) {
        this.target = target;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        System.out.println("[日志] " + method.getName() + " 调用开始");
        Object result = method.invoke(target, args);
        System.out.println("[日志] " + method.getName() + " 调用结束");
        return result;
    }
}

// 使用
UserService target = new UserServiceImpl();
UserService proxy = (UserService) Proxy.newProxyInstance(
        target.getClass().getClassLoader(),
        target.getClass().getInterfaces(),
        new LogInvocationHandler(target));
proxy.addUser("东哥");
```

### 底层原理

`Proxy.newProxyInstance` 做了三件事：

1. 根据接口**动态生成字节码**，定义代理类 `$Proxy0`，它**实现了传入的所有接口**，并继承 `Proxy`；
2. 生成的代理类把所有接口方法都重写为：调用 `super.h.invoke(this, method, args)`，即转发给 `InvocationHandler.invoke()`；
3. 通过反射实例化代理对象。

```java
// 生成的 $Proxy0 大致长这样（简化）
public final class $Proxy0 extends Proxy implements UserService {
    private static Method m3;
    public final void addUser(String name) throws Throwable {
        super.h.invoke(this, m3, new Object[]{name});  // 转发给 InvocationHandler
    }
}
```

### 关键限制：**必须基于接口**

因为生成的代理类已经继承了 `Proxy`（Java 单继承），只能通过**实现接口**来扩展 —— 这就是「JDK 动态代理只支持接口代理」的根源。目标类没有接口？JDK 动态代理无能为力，轮到 CGLIB 上场。

## 四、CGLIB 动态代理：基于继承的字节码增强

CGLIB（Code Generation Library）通过**生成目标类的子类**来实现代理，不要求目标类实现接口。

```java
// CGLIB 的 MethodInterceptor 相当于 JDK 的 InvocationHandler
public class LogMethodInterceptor implements MethodInterceptor {
    @Override
    public Object intercept(Object obj, Method method, Object[] args, MethodProxy proxy)
            throws Throwable {
        System.out.println("[日志] " + method.getName() + " 调用开始");
        Object result = proxy.invokeSuper(obj, args);  // 调用父类（目标类）方法
        System.out.println("[日志] " + method.getName() + " 调用结束");
        return result;
    }
}

// 使用
Enhancer enhancer = new Enhancer();
enhancer.setSuperclass(UserServiceImpl.class);
enhancer.setCallback(new LogMethodInterceptor());
UserServiceImpl proxy = (UserServiceImpl) enhancer.create();
proxy.addUser("东哥");
```

### 底层原理

`Enhancer.create()` 动态生成 `UserServiceImpl` 的**子类**（如 `UserServiceImpl$$EnhancerByCGLIB$$xxx`），重写目标方法：方法体里调用 `MethodInterceptor.intercept()`，再由 `proxy.invokeSuper()` 通过 **FastClass 机制**（直接方法索引调用，避免反射）回调目标方法。

### CGLIB 的两个致命限制

1. **final 类无法被代理**（没法生成子类）；
2. **final/private/static 方法无法被增强**（子类无法重写）。

## 五、JDK 动态代理 vs CGLIB 全面对比

| 维度 | JDK 动态代理 | CGLIB |
|------|-------------|-------|
| 实现方式 | 运行时生成**实现接口**的代理类 | 运行时生成**继承目标类**的子类 |
| 前提条件 | 目标必须有接口 | 目标类不能是 final，方法不能是 final |
| 调用方式 | 反射 `Method.invoke()` | FastClass 索引直接调用（更快） |
| 性能 | JDK 8+ 反射优化后两者差距很小 | 生成代理类时较慢，调用略快 |
| 额外依赖 | JDK 自带 | 需要 cglib 依赖（Spring 已内置） |
| 典型应用 | Spring AOP（目标有接口时默认）、MyBatis Mapper、RPC 动态代理 | Spring AOP（目标无接口时）、Hibernate 懒加载 |

> 结论：**优先 JDK 动态代理**（无第三方依赖、更规范），目标没有接口时才用 CGLIB。

## 六、Spring AOP 怎么选代理？

Spring AOP 的选择逻辑（`DefaultAopProxyFactory`）：

```java
public AopProxy createAopProxy(AdvisedSupport config) {
    if (config.isOptimize() || config.isProxyTargetClass() ||
            hasNoUserSuppliedProxyInterfaces(config)) {
        // 目标类没有实现任何接口 → 用 CGLIB
        return new ObjenesisCglibAopProxy(config);
    }
    // 目标有接口 → 用 JDK 动态代理
    return new JdkDynamicAopProxy(config);
}
```

Spring Boot 2.x 之后默认 `spring.aop.proxy-target-class=true`，**一律使用 CGLIB**（因为很多 Service 没接口，统一行为更省心）。

### 经典面试题：为什么 @Transactional 自调用不生效？

```java
@Service
public class OrderService {
    @Transactional
    public void createOrder() { ... }

    public void createOrderAndPay() {
        this.createOrder();   // 自调用：this 是原始对象，不是代理对象！
    }
}
```

Spring 事务基于 AOP 代理：`createOrderAndPay()` 调用 `this.createOrder()` 时，`this` 指向**原始对象**，绕过了代理，`@Transactional` 的增强逻辑（开启事务）根本没执行。

**解法**：

1. 注入自身代理：`@Autowired private OrderService self;`（或 `@Lazy` 注入避免循环依赖）；
2. 用 `AopContext.currentProxy()`（需开启 `@EnableAspectJAutoProxy(exposeProxy = true)`）；
3. 拆到另一个 Bean 里调用（最推荐，职责也更清晰）。

## 七、代理模式在框架中的经典应用

| 框架 | 代理应用 |
|------|---------|
| Spring AOP | 事务、日志、权限、性能监控的横切增强 |
| MyBatis | Mapper 接口通过 JDK 动态代理生成实现，拦截 SQL 执行 |
| Spring Cloud OpenFeign | 接口方法通过动态代理转发为 HTTP 请求 |
| Dubbo/RPC | 消费端接口代理 → 网络调用；服务端代理 → 暴露服务 |
| MyBatis 插件 | 对 Executor/StatementHandler 做 JDK 动态代理实现拦截 |
| Hibernate | 实体懒加载用 CGLIB 生成子类代理 |

## 八、代理模式 vs 装饰器模式：别傻傻分不清

| 维度 | 代理模式 | 装饰器模式 |
|------|---------|-----------|
| 目的 | **控制访问**（鉴权、远程、懒加载） | **增强功能**（动态添加职责） |
| 关系 | 代理和目标解耦，代理可独立存在 | 装饰器和被装饰者都是同一家族，层层包装 |
| 创建 | 通常由框架/客户端创建，目标对调用方透明 | 由客户端显式层层包装 |
| 典型 | Spring AOP、RPC | Java IO 流 `BufferedInputStream` 包 `FileInputStream` |

一句话：**代理管「让不让你调」，装饰器管「调的时候多做点事」**。

## 面试高频追问清单

1. 静态代理有什么缺点？动态代理解决了什么？
2. 为什么 JDK 动态代理只能代理接口？
3. CGLIB 代理的类有什么限制？为什么 final 方法不能增强？
4. JDK 动态代理和 CGLIB 谁快？Spring 怎么选？
5. @Transactional 自调用为什么失效？怎么解决？
6. 代理模式和装饰器模式有什么区别？
7. MyBatis 的 Mapper 是怎么被代理的？

## 小结

代理模式的核心价值是**在不侵入目标类的前提下实现横切增强和控制访问**。从静态代理到 JDK 动态代理再到 CGLIB，是「消除重复、突破限制」的演进过程。把三种实现写一遍、把 Spring AOP 的选择逻辑和自调用失效讲清楚，这道设计模式题就满分了。
