---
title: 「Java 反射与动态代理」从字节码操作到 Spring AOP 的底层实现
date: 2026-06-28 08:00:00
tags:
  - Java
  - 反射
  - 动态代理
  - AOP
categories:
  - Java
  - Java基础
author: 东哥
---

# 「Java 反射与动态代理」从字节码操作到 Spring AOP 的底层实现

反射和动态代理是 Java 框架的基石——Spring 的 IoC/AOP、MyBatis 的 Mapper 映射、Hibernate 的懒加载代理、RPC 框架的远程调用，底层都用到了它们。本文从字节码层面剖析反射和动态代理的原理，最后串联到 Spring AOP 的实现。

---

## 一、反射机制——运行时的"自省"

### 1.1 什么是反射？

Java 反射（Reflection）是指在**运行状态**中，对于任意一个类，都能够知道这个类的所有属性和方法；对于任意一个对象，都能够调用它的任意方法和属性。

**简单来说：反射让 Java 具备了动态性。**

### 1.2 反射的核心 API

| 类 | 用途 | 获取方式 |
|----|------|---------|
| Class<?> | 类的元数据 | `对象.getClass()` / `Class.forName()` / `类名.class` |
| Constructor | 构造方法 | `clazz.getConstructor()` / `clazz.getDeclaredConstructors()` |
| Method | 方法 | `clazz.getMethod()` / `clazz.getDeclaredMethods()` |
| Field | 字段 | `clazz.getField()` / `clazz.getDeclaredFields()` |
| Annotation | 注解 | `method.getAnnotation()` / `clazz.getAnnotations()` |

### 1.3 基本使用示例

```java
public class ReflectionDemo {
    
    static class UserService {
        private String name;
        
        public UserService() {}
        
        private UserService(String name) {
            this.name = name;
        }
        
        public String greet(String prefix) {
            return prefix + ": " + name;
        }
    }
    
    public static void main(String[] args) throws Exception {
        // 1. 获取 Class 对象
        Class<?> clazz = Class.forName("com.example.ReflectionDemo$UserService");
        // 或 clazz = UserService.class;
        
        // 2. 调用私有构造方法创建对象
        Constructor<?> constructor = clazz.getDeclaredConstructor(String.class);
        constructor.setAccessible(true);  // 绕过 private
        Object instance = constructor.newInstance("东哥");
        
        // 3. 调用方法
        Method method = clazz.getMethod("greet", String.class);
        Object result = method.invoke(instance, "Hello");
        System.out.println(result);  // Hello: 东哥
        
        // 4. 访问字段
        Field field = clazz.getDeclaredField("name");
        field.setAccessible(true);
        System.out.println(field.get(instance));  // 东哥
    }
}
```

### 1.4 反射的性能问题与优化

#### 为什么反射慢？

```java
// 正常调用：编译期确定方法地址，直接 invokevirtual
userService.greet("Hello");

// 反射调用：运行时动态解析
method.invoke(instance, "Hello");
```

反射的性能开销主要在：

| 开销来源 | 说明 |
|---------|------|
| Class.forName() | 加载类字节码，触发静态初始化 |
| 安全检查 | `setAccessible(true)` 前有大量权限校验 |
| 参数装箱/拆箱 | 基础类型参数需要 Object[] 包装 |
| 方法查找 | 需要遍历类方法列表匹配签名 |
| JIT 无法内联 | 动态调用导致 inline 失效 |
| 堆上分配 | Method 对象分配，参数数组分配 |

**实测**：反射调用约比直接调用慢 50~100 倍（未优化）。

#### 优化技巧

**技巧 1：setAccessible 加速**
```java
method.setAccessible(true);  // 关闭安全检查，提升约 20~30%
```

**技巧 2：缓存 Method/Field 对象**
```java
// 不推荐：每次反射都查找
Method m = clazz.getMethod("greet");
m.invoke(obj);

// 推荐：缓存 Method
private static final Method GREET_METHOD;
static {
    GREET_METHOD = UserService.class.getMethod("greet");
    GREET_METHOD.setAccessible(true);
}
```

**技巧 3：使用 MethodHandle（Java 7+）**
```java
// MethodHandle 比反射快很多（更接近直接调用）
MethodHandles.Lookup lookup = MethodHandles.lookup();
MethodType mt = MethodType.methodType(String.class, String.class);
MethodHandle handle = lookup.findVirtual(UserService.class, "greet", mt);
String result = (String) handle.invoke(instance, "Hello");
```

**技巧 4：使用 LambdaMetafactory**
```java
// 将反射调用转换为函数式接口
@FunctionalInterface
interface Greeter {
    String greet(String prefix);
}

MethodHandles.Lookup lookup = MethodHandles.lookup();
MethodType factoryMethodType = MethodType.methodType(Greeter.class);
MethodType functionalInterfaceMethod = MethodType.methodType(String.class, String.class);
MethodHandle target = lookup.findVirtual(UserService.class, "greet", 
    MethodType.methodType(String.class, String.class));

CallSite site = LambdaMetafactory.metafactory(
    lookup, "greet", factoryMethodType,
    functionalInterfaceMethod, target, functionalInterfaceMethod);

Greeter greeter = (Greeter) site.getTarget().invokeExact();
// 调用性能接近直接调用
String result = greeter.greet("Hello");
```

---

## 二、动态代理——运行时生成代理类

### 2.1 什么是动态代理？

**静态代理**：编译时就确定了代理类和目标类的关系。

**动态代理**：在运行时动态生成代理类，实现接口的拦截增强。

Java 提供了两种动态代理方式：

| 方式 | JDK 动态代理 | CGLIB 动态代理 |
|------|-------------|---------------|
| 原理 | 实现接口，生成 Proxy 子类 | 继承目标类，生成子类 |
| 必要条件 | 目标对象必须实现接口 | 目标类不能是 final 的 |
| 生成时机 | 运行时 | 运行时（通过 ASM 字节码） |
| 默认使用 | Spring AOP（接口时） | Spring AOP（非接口时） |

### 2.2 JDK 动态代理

```java
// 定义接口
public interface UserService {
    void save(String name);
    String findById(Long id);
}

// 目标实现
public class UserServiceImpl implements UserService {
    @Override
    public void save(String name) {
        System.out.println("Saving user: " + name);
    }
    
    @Override
    public String findById(Long id) {
        return "User-" + id;
    }
}

// 实现 InvocationHandler
public class LogInvocationHandler implements InvocationHandler {
    
    private final Object target;
    
    public LogInvocationHandler(Object target) {
        this.target = target;
    }
    
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        System.out.println("[LOG] Before: " + method.getName());
        long start = System.nanoTime();
        
        Object result = method.invoke(target, args);
        
        long elapsed = System.nanoTime() - start;
        System.out.println("[LOG] After: " + method.getName() + " took " + elapsed + "ns");
        
        return result;
    }
}

// 使用
public class Main {
    public static void main(String[] args) {
        UserService service = new UserServiceImpl();
        // 生成代理类
        UserService proxy = (UserService) Proxy.newProxyInstance(
            service.getClass().getClassLoader(),
            service.getClass().getInterfaces(),
            new LogInvocationHandler(service)
        );
        proxy.save("东哥");
        // 输出：
        // [LOG] Before: save
        // Saving user: 东哥
        // [LOG] After: save took 12345ns
    }
}
```

### 2.3 JDK 代理源码剖析

```java
// Proxy.newProxyInstance 核心流程
@CallerSensitive
public static Object newProxyInstance(ClassLoader loader,
                                      Class<?>[] interfaces,
                                      InvocationHandler h) {
    Objects.requireNonNull(h);
    final Class<?>[] intfs = interfaces.clone();
    
    // 1. 查找或生成代理类
    Class<?> cl = getProxyClass0(loader, intfs);
    
    // 2. 通过构造方法创建实例
    final Constructor<?> cons = cl.getConstructor(constructorParams);
    final InvocationHandler ih = h;
    return cons.newInstance(new Object[]{h});
}

// 代理类生成的核心
private static Class<?> getProxyClass0(ClassLoader loader, Class<?>... interfaces) {
    // 接口数量不能超过 65535
    if (interfaces.length > 65535) {
        throw new IllegalArgumentException("interface limit exceeded");
    }
    return proxyClassCache.get(loader, interfaces);
}

// 代理类缓存
private static final WeakCache<ClassLoader, Class<?>[], Class<?>> proxyClassCache =
    new WeakCache<>(new ProxyClassFactory());

// ProxyClassFactory 中的字节码生成
private static final class ProxyClassFactory implements BiFunction<ClassLoader, Class<?>[], Class<?>> {
    
    private static final String proxyClassNamePrefix = "$Proxy";
    
    @Override
    public Class<?> apply(ClassLoader loader, Class<?>[] interfaces) {
        // 生成类名：com.sun.proxy.$Proxy0
        String proxyName = proxyPkg + "." + proxyClassNamePrefix + num;
        
        // 通过 ProxyGenerator 生成字节码
        byte[] proxyClassFile = ProxyGenerator.generateProxyClass(
            proxyName, interfaces, accessFlags);
        
        // 使用 native 方法定义类
        return defineClass0(loader, proxyName, proxyClassFile, 0, proxyClassFile.length);
    }
}
```

保存生成的代理类字节码，可以用 `-Dsun.misc.ProxyGenerator.saveGeneratedFiles=true`，然后反编译：

```java
// 生成的代理类大致结构
public final class $Proxy0 extends Proxy implements UserService {
    
    // 缓存 Method 对象
    private static Method m1 = Class.forName("java.lang.Object").getMethod("equals");
    private static Method m2 = Class.forName("java.lang.Object").getMethod("toString");
    private static Method m3 = Class.forName("com.example.UserService").getMethod("save");
    private static Method m4 = Class.forName("com.example.UserService").getMethod("findById");
    
    public $Proxy0(InvocationHandler h) {
        super(h);
    }
    
    @Override
    public void save(String name) {
        try {
            // 所有方法调用都转给 InvocationHandler
            super.h.invoke(this, m3, new Object[]{name});
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable e) {
            throw new UndeclaredThrowableException(e);
        }
    }
}
```

**关键点**：
- 代理类继承了 `Proxy`，所以只能通过接口代理（Java 不支持多继承）
- 所有方法调用都转发给 `InvocationHandler.invoke()`
- 被代理的接口方法、Object 中的 `equals/toString/hashCode` 都会被拦截

### 2.4 CGLIB 动态代理

当目标类**没有实现接口**时，Spring AOP 会使用 CGLIB。

```java
// 目标类：没有接口
public class UserServiceConcrete {
    public void save(String name) {
        System.out.println("Saving user: " + name);
    }
    
    public final String getInfo() {
        return "User info";
    }
}

// CGLIB 拦截器
public class CglibInterceptor implements MethodInterceptor {
    
    private final Object target;
    
    public CglibInterceptor(Object target) {
        this.target = target;
    }
    
    @Override
    public Object intercept(Object obj, Method method, Object[] args, MethodProxy proxy) 
            throws Throwable {
        System.out.println("[CGLIB] Before: " + method.getName());
        Object result = proxy.invoke(target, args);
        System.out.println("[CGLIB] After: " + method.getName());
        return result;
    }
}

// 使用
public class Main {
    public static void main(String[] args) {
        UserServiceConcrete target = new UserServiceConcrete();
        
        Enhancer enhancer = new Enhancer();
        enhancer.setSuperclass(UserServiceConcrete.class);
        enhancer.setCallback(new CglibInterceptor(target));
        
        UserServiceConcrete proxy = (UserServiceConcrete) enhancer.create();
        proxy.save("东哥");
        // proxy.getInfo();  // ❌ final 方法无法被代理
    }
}
```

**CGLIB 的限制**：
- `final` 类不能被代理
- `final` 方法不能被代理
- `private` 方法不能被代理
- `static` 方法不能被代理

### 2.5 JDK 动态代理 vs CGLIB 对比

| 维度 | JDK 动态代理 | CGLIB |
|------|-------------|-------|
| 生成方式 | 字节码动态生成 | ASM 字节码生成 |
| 必要条件 | 接口 | 非 final 类 |
| 性能（早期） | 创建快，调用慢 | 创建慢，调用快 |
| 性能（现代） | 差距缩小（JIT 优化） | 差距缩小 |
| Spring 默认 | 有接口时默认 | 无接口时默认 |
| Spring Boot 2.x+ | 默认 CGLIB（甚至包括有接口的） | 默认方式 |

> Spring Boot 2.0+ 默认使用 CGLIB 代理：`spring.aop.proxy-target-class=true`

---

## 三、实战：从反射到 Spring AOP 的全链路

### 3.1 手写一个简单的 AOP 框架

```java
// 1. 定义切面注解
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface Loggable {
    String value() default "";
}

// 2. 定义切面处理
public class LogAspect {
    public void before(Method method, Object[] args) {
        System.out.println("[AOP] Before: " + method.getName() +
            ", args: " + Arrays.toString(args));
    }
    
    public void after(Method method, Object result) {
        System.out.println("[AOP] After: " + method.getName() +
            ", result: " + result);
    }
}

// 3. 代理工厂
public class SimpleAopFactory {
    
    @SuppressWarnings("unchecked")
    public static <T> T createProxy(T target) {
        Class<?> targetClass = target.getClass();
        LogAspect aspect = new LogAspect();
        
        // 优先用 JDK 动态代理
        if (targetClass.getInterfaces().length > 0) {
            return (T) Proxy.newProxyInstance(
                targetClass.getClassLoader(),
                targetClass.getInterfaces(),
                (proxy, method, args) -> {
                    Method targetMethod = targetClass.getMethod(method.getName(),
                        method.getParameterTypes());
                    if (targetMethod.isAnnotationPresent(Loggable.class)) {
                        aspect.before(method, args);
                        Object result = method.invoke(target, args);
                        aspect.after(method, result);
                        return result;
                    }
                    return method.invoke(target, args);
                }
            );
        }
        
        // 没有接口，用 CGLIB
        Enhancer enhancer = new Enhancer();
        enhancer.setSuperclass(targetClass);
        enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) -> {
            if (method.isAnnotationPresent(Loggable.class)) {
                aspect.before(method, args);
                Object result = proxy.invoke(target, args);
                aspect.after(method, result);
                return result;
            }
            return proxy.invoke(target, args);
        });
        return (T) enhancer.create();
    }
}

// 4. 使用
public class App {
    @Loggable("saveUser")
    public void save(String name) { ... }
    
    public static void main(String[] args) {
        App app = SimpleAopFactory.createProxy(new App());
        app.save("东哥");  // 自动增强
    }
}
```

### 3.2 Spring AOP 内部实现

Spring AOP 代理的核心入口是 `AbstractAutoProxyCreator`：

```java
// 简化流程
public abstract class AbstractAutoProxyCreator extends ProxyProcessorSupport
        implements SmartInstantiationAwareBeanPostProcessor, BeanFactoryAware {
    
    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        if (bean instanceof AopInfrastructureBean) return bean;
        
        // 1. 查找该 bean 匹配的切面（Advisor）
        TargetSource targetSource = getCustomTargetSource(bean, beanName);
        Object[] specificInterceptors = getAdvicesAndAdvisorsForBean(bean.getClass(), beanName, targetSource);
        
        if (specificInterceptors != DO_NOT_PROXY) {
            // 2. 创建代理
            return createProxy(bean.getClass(), beanName, specificInterceptors, targetSource);
        }
        return bean;
    }
    
    protected Object createProxy(Class<?> beanClass, String beanName,
                                  Object[] specificInterceptors, TargetSource targetSource) {
        ProxyFactory proxyFactory = new ProxyFactory();
        proxyFactory.setTargetSource(targetSource);
        proxyFactory.addAdvisors(specificInterceptors);
        
        // 3. 决定用 JDK Proxy 还是 CGLIB
        proxyFactory.setProxyTargetClass(proxyTargetClass);
        // 如果设置了 proxy-target-class=true 或 bean 没有接口 → 用 CGLIB
        // 否则用 JDK Proxy
        
        return proxyFactory.getProxy(getProxyClassLoader());
    }
}
```

### 3.3 限流注解实战

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface RateLimit {
    int value() default 100;  // 每秒限制请求数
}

public class RateLimitAspect {
    private final LoadingCache<String, RateLimiter> limiterCache = Caffeine.newBuilder()
        .expireAfterWrite(1, TimeUnit.HOURS)
        .build(key -> RateLimiter.create(100));
    
    @Around("@annotation(rateLimit)")
    public Object around(ProceedingJoinPoint pjp, RateLimit rateLimit) throws Throwable {
        String key = pjp.getSignature().toShortString();
        RateLimiter limiter = limiterCache.get(key);
        limiter.setRate(rateLimit.value());
        
        if (!limiter.tryAcquire()) {
            throw new RuntimeException("Too many requests for: " + key);
        }
        return pjp.proceed();
    }
}
```

---

## 四、总结

反射和动态代理是 Java 运行时动态能力的核心支柱：

**反射**提供了运行时探查和调用类的能力，让框架可以解耦具体实现类。虽然性能不如直接调用，但通过缓存、MethodHandle、LambdaMetafactory 等方式可以大幅优化。

**动态代理**在反射之上提供了方法拦截能力。JDK 动态代理基于接口、生成 Proxy 子类；CGLIB 基于类继承、通过 ASM 生成字节码。两者结合，加上 AspectJ 编译时织入，构成了 Spring AOP 的完整生态。

理解它们的原理，你就能看清 Spring 的 `@Transactional`、`@Cacheable`、`@Async` 等注解的底层——本质上都是：**反射获取元数据 + 动态代理生成拦截器 + 递归调用链**。
