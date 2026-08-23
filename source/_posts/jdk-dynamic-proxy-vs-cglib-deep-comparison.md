---
title: 【面试必备】JDK 动态代理 vs CGLIB 深度对比：原理、源码与选型
date: 2026-08-23 08:00:00
tags:
  - Java
  - 动态代理
  - CGLIB
  - Spring AOP
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】JDK 动态代理 vs CGLIB 深度对比：原理、源码与选型

## 面试官：说说 JDK 动态代理和 CGLIB 的区别？

> 这是 Spring AOP、MyBatis 插件、Feign 等框架面试中必问的高频题。很多同学能背出"JDK 动态代理要求目标类实现接口，CGLIB 通过继承实现"这两句话，但被追问到底层原理就卡壳了。本文从字节码层面把两种代理彻底讲透。

## 一、代理模式回顾：静态代理的痛点

在讲动态代理之前，先看静态代理的局限。假设有一个 `UserService` 接口：

```java
public interface UserService {
    User getUserById(Long id);
}

public class UserServiceImpl implements UserService {
    @Override
    public User getUserById(Long id) {
        // 模拟数据库查询
        return new User(id, "东哥");
    }
}
```

如果要在方法调用前后打印日志，静态代理需要手写一个代理类：

```java
public class UserServiceLogProxy implements UserService {
    private final UserService target;

    public UserServiceLogProxy(UserService target) {
        this.target = target;
    }

    @Override
    public User getUserById(Long id) {
        System.out.println("before: 查询用户 " + id);
        User user = target.getUserById(id);
        System.out.println("after: 查询完成");
        return user;
    }
}
```

**静态代理的痛点**：每个接口都要写一个代理类，接口新增方法代理类也要同步改，代码爆炸。**动态代理**的核心价值就是：在**运行时**动态生成代理类，一个代理工厂搞定所有接口。

## 二、JDK 动态代理：基于接口的运行时代理

### 2.1 基本用法

```java
// 1. 实现 InvocationHandler
public class LogInvocationHandler implements InvocationHandler {
    private final Object target;

    public LogInvocationHandler(Object target) {
        this.target = target;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        System.out.println("before: " + method.getName());
        Object result = method.invoke(target, args);
        System.out.println("after: " + method.getName());
        return result;
    }
}

// 2. 通过 Proxy.newProxyInstance 生成代理对象
UserService proxy = (UserService) Proxy.newProxyInstance(
        UserService.class.getClassLoader(),
        new Class[]{UserService.class},
        new LogInvocationHandler(new UserServiceImpl())
);
proxy.getUserById(1L);
```

### 2.2 底层原理：运行时生成字节码

`Proxy.newProxyInstance` 的核心逻辑（JDK 8+ 源码）：

```java
public static Object newProxyInstance(ClassLoader loader,
                                      Class<?>[] interfaces,
                                      InvocationHandler h) {
    // 1. 校验 InvocationHandler 非空
    Objects.requireNonNull(h);
    // 2. 拷贝接口数组并做安全检查
    final Class<?>[] intfs = interfaces.clone();
    // 3. 查找或生成代理类（关键）
    Class<?> cl = getProxyClass0(loader, intfs);
    // 4. 通过反射拿到带 InvocationHandler 参数的构造器
    final Constructor<?> cons = cl.getConstructor(constructorParams);
    // 5. 实例化代理对象
    return cons.newInstance(new Object[]{h});
}
```

`getProxyClass0` 内部先从缓存查找，没有则调用 `ProxyClassFactory.apply()` 生成：

```java
byte[] proxyClassFile = ProxyGenerator.generateProxyClass(
        proxyName, interfaces, accessFlags);  // 生成字节码
return defineClass0(loader, proxyName, proxyClassFile, 0, proxyClassFile.length);  // 本地方法加载类
```

**生成的代理类长什么样？** 用 `ProxyGenerator` 或直接反编译生成的 `$Proxy0` 类，可以看到：

```java
public final class $Proxy0 extends Proxy implements UserService {
    private static Method m3;  // getUserById

    static {
        m3 = Class.forName("UserService").getMethod("getUserById", Long.class);
    }

    public $Proxy0(InvocationHandler h) {
        super(h);  // 调用 Proxy 的构造器保存 h
    }

    @Override
    public final User getUserById(Long id) {
        try {
            return (User) super.h.invoke(this, m3, new Object[]{id});
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable t) {
            throw new UndeclaredThrowableException(t);
        }
    }
}
```

关键点：

| 特征 | 说明 |
|---|---|
| 继承关系 | `extends Proxy`，所以**只能代理接口**（Java 单继承，不能再继承目标类） |
| 方法调用 | 所有方法都转发给 `InvocationHandler.invoke()` |
| 方法信息 | 通过 `Method` 对象传递，反射调用目标方法 |
| 生成时机 | 运行时首次使用时生成，有缓存（WeakCache） |

### 2.3 为什么 JDK 代理要求目标必须实现接口？

因为生成的 `$Proxy0` 已经继承了 `Proxy`，Java 是单继承，无法再继承目标类。唯一的"契约"通道就是接口。所以**代理的是接口，而不是实现类**——调用 `proxy.getClass()` 得到的是 `$Proxy0`，不是 `UserServiceImpl`。

## 三、CGLIB：基于继承的字节码增强

### 3.1 基本用法

CGLIB（Code Generation Library）不依赖接口，通过**继承目标类**并**重写方法**实现代理：

```java
// 1. 实现 MethodInterceptor
public class LogMethodInterceptor implements MethodInterceptor {
    @Override
    public Object intercept(Object obj, Method method, Object[] args, MethodProxy proxy) throws Throwable {
        System.out.println("before: " + method.getName());
        Object result = proxy.invokeSuper(obj, args);  // 注意：调用父类方法
        System.out.println("after: " + method.getName());
        return result;
    }
}

// 2. 通过 Enhancer 创建代理
Enhancer enhancer = new Enhancer();
enhancer.setSuperclass(UserServiceImpl.class);  // 设置父类
enhancer.setCallback(new LogMethodInterceptor());
UserServiceImpl proxy = (UserServiceImpl) enhancer.create();
proxy.getUserById(1L);
```

### 3.2 底层原理：ASM 生成子类

CGLIB 底层使用 **ASM** 直接操作字节码，生成目标类的子类。核心流程：

```java
// Enhancer.create() 的核心调用链
create() -> createHelper() -> AbstractClassGenerator.create()
  -> 通过 KeyFactory 生成缓存 key
  -> 缓存未命中则调用 generate() 生成字节码
  -> DefaultGeneratorStrategy.generate() 使用 ClassEmitter/ASM 写字节码
```

生成的代理类结构（简化示意）：

```java
public class UserServiceImpl$$EnhancerByCGLIB$$abcdef extends UserServiceImpl {
    private MethodInterceptor CGLIB$CALLBACK_0;
    private static Method CGLIB$getUserById$0$Method;
    private static MethodProxy CGLIB$getUserById$0$Proxy;

    // 重写父类方法
    public final User getUserById(Long id) {
        MethodInterceptor interceptor = CGLIB$CALLBACK_0;
        if (interceptor == null) {
            // 快速路径：没有拦截器直接调用父类
            return super.getUserById(id);
        }
        return (User) interceptor.intercept(this,
                CGLIB$getUserById$0$Method,
                new Object[]{id},
                CGLIB$getUserById$0$Proxy);
    }
}
```

**MethodProxy 的威力**：`proxy.invokeSuper(obj, args)` 不是反射调用，而是直接生成 `FastClass` 索引调用父类方法，**避免了反射开销**。CGLIB 为每个类额外生成一个 `FastClass`（`UserServiceImpl$$EnhancerByCGLIB$$xxx$$FastClass`），通过方法索引 `getIndex()` 直接定位方法，比 JDK 代理的 `Method.invoke()` 反射快得多。

### 3.3 CGLIB 的两个致命限制

1. **不能代理 final 类**：无法继承 final 类；
2. **不能代理 final 方法**：final 方法无法被重写，代理不生效（会直接调用原方法）；
3. **不能代理 private/static 方法**：这些方法不属于子类可重写范围（static 方法通过 FastClass 可以拦截调用，但 Spring AOP 默认不代理 static）。

```java
public final class OrderService {  // ❌ final 类无法被 CGLIB 代理
    public void createOrder() {}
}

public class PayService {
    public final void pay() {}  // ❌ final 方法无法被增强
}
```

## 四、核心对比：一张表看懂

| 对比维度 | JDK 动态代理 | CGLIB |
|---|---|---|
| 代理方式 | 基于**接口**，生成 `$Proxy0` | 基于**继承**，生成目标类子类 |
| 依赖 | JDK 内置（`java.lang.reflect.Proxy`） | 第三方库（Spring 内置了 repackaged 版本） |
| 目标要求 | 必须有接口 | 类不能是 final，方法不能是 final |
| 方法调用 | 反射 `Method.invoke()` | `MethodProxy` + FastClass 索引，**无反射** |
| 性能（创建） | 快（字节码简单） | 慢（需要生成子类 + FastClass） |
| 性能（调用） | 慢（反射） | 快（索引直调） |
| 版本要求 | 无 | JDK 9+ 需要额外模块（Spring 5.3+ 内置支持） |
| Spring 默认策略 | 目标实现了接口 → JDK 代理 | 目标没实现接口 → CGLIB |

> **Spring Boot 2.x 起默认使用 CGLIB**（`spring.aop.proxy-target-class=true` 成为默认），因为现在绝大多数业务类都直接 `@Service` + `@Transactional`，没有接口。

## 五、源码级验证：Spring AOP 怎么选代理方式？

`DefaultAopProxyFactory.createAopProxy()` 源码：

```java
public AopProxy createAopProxy(AdvisedSupport config) {
    if (config.isOptimize() || config.isProxyTargetClass() || hasNoUserSuppliedProxyInterfaces(config)) {
        Class<?> targetClass = config.getTargetClass();
        if (targetClass.isInterface() || Proxy.isProxyClass(targetClass)) {
            // 目标是接口 → JDK 动态代理
            return new JdkDynamicAopProxy(config);
        }
        // 目标不是接口 → CGLIB
        return new ObjenesisCglibAopProxy(config);
    } else {
        // 提供了自定义代理接口 → JDK 动态代理
        return new JdkDynamicAopProxy(config);
    }
}
```

判断逻辑一目了然：**目标类是接口就用 JDK 代理，否则用 CGLIB**。

## 六、性能实测与选型建议

用一个简单的 JMH 基准测试（1000 万次调用）大致量级如下：

| 代理类型 | 代理对象创建耗时 | 单次方法调用耗时 |
|---|---|---|
| 无代理 | — | ~1ns |
| JDK 动态代理 | ~0.5ms | ~30-60ns（反射） |
| CGLIB | ~2-5ms | ~10-20ns（FastClass） |

**结论**：
- **调用性能**：CGLIB 快（无反射），JDK 代理在 JDK 8 之后反射优化（`MethodHandle` + 内联缓存）后差距缩小到 2-3 倍以内；
- **创建性能**：JDK 代理快，适合代理对象频繁创建的场景；
- **现代 JDK（17+）**：JDK 代理性能已大幅提升，Spring 官方推荐优先接口设计 + JDK 代理，架构更干净。

**选型建议**：
1. 设计上优先面向接口编程 → 天然适合 JDK 动态代理；
2. 第三方类（没接口）需要增强 → 只能 CGLIB；
3. 追求极致调用性能且代理对象复用 → CGLIB；
4. 代理对象频繁创建销毁 → JDK 动态代理。

## 七、常见面试追问

**Q1：Spring AOP 默认用哪种代理？**
Spring Boot 2.x+ 默认 CGLIB（`proxyTargetClass=true`）。Spring Framework 5.x 以前默认 JDK 代理（有接口时）。

**Q2：CGLIB 代理的对象能否强转成目标类？能转成接口吗？**
能转成目标类（它继承了目标类）。不能转成目标类没实现的接口。

**Q3：JDK 动态代理生成的代理类调用 `proxy instanceof UserService` 返回什么？**
`true`。`$Proxy0` 实现了 `UserService` 接口，但 `proxy instanceof UserServiceImpl` 是 `false`。

**Q4：为什么 MyBatis 的 Mapper 只能用 JDK 动态代理？**
因为 Mapper 是纯接口（`@Mapper` 注解的接口），没有实现类，CGLIB 无法继承。MyBatis 用 `MapperProxy` 实现 `InvocationHandler`，把每个方法调用映射为一条 SQL 执行。

**Q5：动态代理和字节码增强（ASM/ByteBuddy）什么关系？**
JDK 代理和 CGLIB 都是"字节码增强"的上层封装：JDK 用 `ProxyGenerator` 生成字节码，CGLIB 用 ASM 生成字节码。ByteBuddy 是更灵活的底层库（Mockito 用它）。

**Q6：`proxy.getClass()` 和 `target.getClass()` 一样吗？**
不一样。`proxy.getClass()` 返回 `com.sun.proxy.$Proxy0` 或 `UserServiceImpl$$EnhancerByCGLIB$$xxx`，`target.getClass()` 返回 `UserServiceImpl`。这也解释了为什么 `@Transactional` 自调用（`this.method()`）不生效——`this` 是原始对象，没走代理。

## 八、总结

| 一句话 | JDK 动态代理 | CGLIB |
|---|---|---|
| 本质 | 接口 + `InvocationHandler` 转发 | 继承 + 方法重写 + 拦截器 |
| 原理 | 运行时生成实现接口的 `$Proxy0` | ASM 生成子类 + FastClass |
| 适用 | 目标有接口 | 目标无接口 / 非 final |
| 面试金句 | "面向接口编程，JDK 代理是运行时生成的接口实现类，方法调用经 InvocationHandler 反射转发" | "CGLIB 通过生成目标类子类并重写非 final 方法实现增强，用 MethodProxy 免反射调用" |

理解两者的本质差异，面试时从"接口 vs 继承"这个根上讲起，再延伸到字节码、FastClass、Spring 源码选型逻辑，就能把这个问题答得又深又全。
