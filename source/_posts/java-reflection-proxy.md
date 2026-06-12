---
title: Java 反射与动态代理详解
date: 2026-06-13 14:00:00
tags:
  - Java
  - 反射
  - 动态代理
  - JDK Proxy
  - CGLib
categories: Java基础
---

# Java 反射与动态代理详解

## 一、引言

Java 反射（Reflection）和动态代理（Dynamic Proxy）是 Java 语言中两大重量级特性，它们是框架设计的基石，贯穿于 Spring、MyBatis、Hibernate、Dubbo 等主流框架的底层实现。深入理解这两者，不仅有助于我们看懂框架源码，更能帮助我们在日常开发中写出更灵活、更通用的代码。

本文将带你从零开始，系统性地掌握 Java 反射与动态代理的核心原理、API 用法、性能陷阱以及实际应用场景。

<!-- more -->

## 二、Java 反射机制

### 2.1 什么是反射

反射（Reflection）是指程序在运行期间能够获取自身的任何信息，并且能够直接操作任意对象的内部属性及方法的能力。简单来说，**反射让 Java 代码在运行时拥有了"自省"的能力**。

正常情况下，我们通过 `new` 关键字创建对象、通过 `.` 运算符调用方法——这些都是在编译期就确定好的。而反射允许我们在运行时动态加载类、创建对象、调用方法、访问字段，甚至在运行时修改私有成员的值。

### 2.2 获取 Class 对象的四种方式

Java 中一切反射操作的起点都是 `java.lang.Class` 对象。获取 `Class` 对象有以下四种方式：

```java
// 方式一：通过 Class.forName()——最常用，尤其是框架中通过类全限定名加载
Class<?> clazz1 = Class.forName("com.example.User");

// 方式二：通过类名.class——编译期确定，不会触发静态代码块
Class<?> clazz2 = User.class;

// 方式三：通过实例对象.getClass()——需要已有实例
User user = new User();
Class<?> clazz3 = user.getClass();

// 方式四：通过类加载器——最底层，通常不直接使用
Class<?> clazz4 = ClassLoader.getSystemClassLoader().loadClass("com.example.User");
```

**注意事项**：
- `Class.forName()` 默认会执行类的静态代码块（`static` 块），而 `ClassLoader.loadClass()` 不会立即执行。
- 在 JDBC 4.0 之前，`Class.forName("com.mysql.cj.jdbc.Driver")` 就是利用这个特性注册驱动的。

### 2.3 反射操作构造方法（Constructor）

```java
public class User {
    private String name;
    private int age;

    public User() {}
    public User(String name) { this.name = name; }
    private User(String name, int age) {
        this.name = name;
        this.age = age;
    }
    // getters & setters...
}

// 反射获取构造方法
Class<?> clazz = User.class;

// 获取所有 public 构造方法
Constructor<?>[] publicConstructors = clazz.getConstructors();

// 获取全部构造方法（含 private）
Constructor<?>[] allConstructors = clazz.getDeclaredConstructors();

// 调用无参构造创建实例
User user1 = (User) clazz.getDeclaredConstructor().newInstance();

// 调用有参构造
Constructor<?> constructor = clazz.getDeclaredConstructor(String.class);
User user2 = (User) constructor.newInstance("东哥");

// 调用私有构造方法
Constructor<?> privateConstructor = clazz.getDeclaredConstructor(String.class, int.class);
privateConstructor.setAccessible(true);  // 暴力反射：绕过 Java 访问检查
User user3 = (User) privateConstructor.newInstance("东哥", 18);
```

### 2.4 反射操作方法（Method）

```java
// 获取本类所有 public 方法（含从父类继承的 public 方法）
Method[] methods = clazz.getMethods();

// 获取本类自行声明的所有方法（含 private，不含继承的）
Method[] declaredMethods = clazz.getDeclaredMethods();

// 获取特定方法
Method setNameMethod = clazz.getMethod("setName", String.class);
Method privateMethod = clazz.getDeclaredMethod("privateMethod");

// 调用方法
User user = new User();
setNameMethod.invoke(user, "东哥");

// 调用私有方法
privateMethod.setAccessible(true);
privateMethod.invoke(user);

// 调用静态方法
Method staticMethod = clazz.getMethod("staticMethod");
staticMethod.invoke(null);  // 静态方法不需要实例
```

### 2.5 反射操作字段（Field）

```java
// 获取 public 字段
Field[] fields = clazz.getFields();       // 只能获取 public 字段
Field[] declaredFields = clazz.getDeclaredFields();  // 获取所有字段

// 获取特定字段
Field nameField = clazz.getDeclaredField("name");
nameField.setAccessible(true);

// 读写字段值
User user = new User();
nameField.set(user, "东哥");
String name = (String) nameField.get(user);

// 读写静态字段
Field staticField = clazz.getDeclaredField("STATIC_VALUE");
staticField.setAccessible(true);
staticField.set(null, "newValue");  // 静态字段第一个参数传 null
```

### 2.6 反射的性能考量与优化

反射虽然强大，但性能相比直接调用有明显差距。原因主要有三点：

1. **类型校验**：每次调用 `invoke()`、`get()`、`set()` 时，JVM 需要做动态类型检查。
2. **装箱拆箱**：反射 API 返回值均为 `Object` 类型，基本类型需要装箱/拆箱。
3. **安全检查**：每次调用都会进行访问权限检查（`AccessibleObject` 的可访问性检查）。

**性能优化策略**：

```java
// 1. 缓存 Method/Field/Constructor 对象——避免重复查找
private static final Map<String, Method> METHOD_CACHE = new ConcurrentHashMap<>();

public static Method getCachedMethod(Class<?> clazz, String name, Class<?>... paramTypes) {
    String key = clazz.getName() + "#" + name;
    return METHOD_CACHE.computeIfAbsent(key, k -> {
        try {
            Method m = clazz.getDeclaredMethod(name, paramTypes);
            m.setAccessible(true);
            return m;
        } catch (NoSuchMethodException e) {
            throw new RuntimeException(e);
        }
    });
}

// 2. 设置 setAccessible(true) —— 关闭访问检查
//    实测在 JDK 8 中可带来 30%-50% 的性能提升
method.setAccessible(true);

// 3. 避免在热点路径中使用反射
//    如果必须用，考虑使用 MethodHandle（JDK 7+）或 LambdaMetafactory 生成调用点

// 4. 使用 MethodHandle（JDK 7 引入，比传统反射更快）
MethodHandles.Lookup lookup = MethodHandles.lookup();
MethodType mt = MethodType.methodType(void.class, String.class);
MethodHandle mh = lookup.findVirtual(User.class, "setName", mt);
mh.invoke(user, "东哥");  // 性能接近直接调用
```

**JDK 版本演进对反射性能的影响**：

- **JDK 7**：引入 `MethodHandle`，性能优于传统反射。
- **JDK 8**：反射内部优化（`sun.reflect.inflationThreshold` 机制），多次调用后会生成字节码委派（`GeneratedMethodAccessor`），性能大幅提升。
- **JDK 9+**：模块化系统增加了模块边界检查；`setAccessible` 在模块未导出时可能抛出 `InaccessibleObjectException`。
- **JDK 16+**：加强封装，默认禁止通过反射访问私有成员（可通过 `--add-opens` JVM 参数绕过）。

### 2.7 setAccessible 深入分析

`setAccessible(true)` 俗称"暴力反射"，它的作用并非修改 Java 语言本身的访问控制，而是**抑制反射 API 的访问检查**。

```java
public final class AccessibleObject {
    // 是否抑制访问检查
    boolean override;

    public void setAccessible(boolean flag) throws SecurityException {
        // 实际上调用的是静态方法 setAccessible0
        setAccessible0(this, flag);
    }
}
```

**注意事项**：
- 在 SecurityManager 启用的情况下，`setAccessible(true)` 可能会抛出 `SecurityException`。
- JDK 17+ 默认启用了强封装（`--illegal-access=deny`），`setAccessible` 对模块内的私有成员依然有效，但跨模块的私有成员会失败。
- 建议在框架实现中通过 `--add-opens` 配置需要反射访问的模块。

---

## 三、Java 动态代理

### 3.1 什么是代理模式

代理模式（Proxy Pattern）是 GoF 23 种设计模式之一。其核心思想是为目标对象提供一个代理对象，由代理对象控制对目标对象的访问，从而在不修改目标对象代码的前提下，增加额外的功能逻辑。

**静态代理 vs 动态代理**：

- **静态代理**：在编译期就确定了代理类和目标类的对应关系，每个目标类需要手动编写一个代理类。代码冗余严重。
- **动态代理**：在运行期动态生成代理类，无需为每个目标类编写单独的代理类。灵活性大大提升。

### 3.2 JDK 动态代理

JDK 动态代理是 Java 原生支持的代理机制，核心是 `java.lang.reflect.Proxy` 类和 `java.lang.reflect.InvocationHandler` 接口。

**使用要求**：**目标对象必须实现一个或多个接口**。

#### 3.2.1 基础实现

```java
// 1. 定义接口
public interface UserService {
    void addUser(String name);
    String getUser(Long id);
}

// 2. 目标实现类
public class UserServiceImpl implements UserService {
    @Override
    public void addUser(String name) {
        System.out.println("添加用户：" + name);
    }

    @Override
    public String getUser(Long id) {
        System.out.println("查询用户 ID：" + id);
        return "用户-" + id;
    }
}

// 3. 实现 InvocationHandler
public class LogInvocationHandler implements InvocationHandler {
    private final Object target;

    public LogInvocationHandler(Object target) {
        this.target = target;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        System.out.println("[前置日志] 调用方法：" + method.getName());
        long start = System.nanoTime();

        // 调用目标方法
        Object result = method.invoke(target, args);

        long elapsed = System.nanoTime() - start;
        System.out.println("[后置日志] 方法 " + method.getName()
                + " 执行耗时：" + elapsed / 1_000_000 + " ms");
        return result;
    }
}

// 4. 创建代理并使用
public class Main {
    public static void main(String[] args) {
        // 保存生成的代理类字节码到磁盘（便于调试）
        System.getProperties().put("sun.misc.ProxyGenerator.saveGeneratedFiles", "true");

        UserService target = new UserServiceImpl();
        InvocationHandler handler = new LogInvocationHandler(target);

        UserService proxy = (UserService) Proxy.newProxyInstance(
                target.getClass().getClassLoader(),
                target.getClass().getInterfaces(),
                handler
        );

        proxy.addUser("东哥");
        String user = proxy.getUser(1L);
    }
}
```

#### 3.2.2 JDK 动态代理的原理

当我们调用 `Proxy.newProxyInstance()` 时，JDK 在运行期做了以下几件事：

1. **生成代理类的字节码**：根据传入的接口列表，动态生成一个继承自 `java.lang.reflect.Proxy` 的类。
2. **加载代理类**：使用指定的 `ClassLoader` 将生成的字节码加载到 JVM 中。
3. **创建代理实例**：通过反射调用代理类的构造方法（参数为 `InvocationHandler`），创建代理对象。

生成的代理类结构大致如下（伪代码）：

```java
// 这是 JDK 为我们动态生成的类
public final class $Proxy0 extends Proxy implements UserService {
    private static Method m1;  // equals
    private static Method m2;  // toString
    private static Method m3;  // addUser
    private static Method m4;  // getUser
    private static Method m0;  // hashCode

    public $Proxy0(InvocationHandler h) {
        super(h);
    }

    @Override
    public void addUser(String name) {
        try {
            super.h.invoke(this, m3, new Object[]{name});
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable e) {
            throw new UndeclaredThrowableException(e);
        }
    }

    @Override
    public String getUser(Long id) {
        try {
            return (String) super.h.invoke(this, m4, new Object[]{id});
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable e) {
            throw new UndeclaredThrowableException(e);
        }
    }
}
```

关键点：
- 代理类 `$Proxy0` **继承**了 `Proxy`，由于 Java 是单继承，所以 JDK 动态代理**只能代理接口**。
- 所有对代理对象的方法调用都会委派给 `InvocationHandler.invoke()` 方法。
- `Method` 对象是静态缓存的，避免每次调用都重新查找。

### 3.3 CGLib 动态代理

CGLib（Code Generation Library）是一个字节码生成库，它通过**继承**目标类来生成子类作为代理，因此**不需要目标类实现接口**。

```xml
<!-- Maven 依赖 -->
<dependency>
    <groupId>cglib</groupId>
    <artifactId>cglib</artifactId>
    <version>3.3.0</version>
</dependency>
```

```java
// 1. 目标类——不需要实现接口
public class UserService {
    public void addUser(String name) {
        System.out.println("添加用户：" + name);
    }

    public final String getUser(Long id) {  // final 方法不能被代理
        return "用户-" + id;
    }
}

// 2. 实现 MethodInterceptor
public class LogMethodInterceptor implements MethodInterceptor {
    @Override
    public Object intercept(Object obj, Method method, Object[] args,
                            MethodProxy proxy) throws Throwable {
        System.out.println("[CGLib 前置] 调用方法：" + method.getName());
        long start = System.nanoTime();

        // 注意：这里调用 proxy.invokeSuper() 而不是 method.invoke()
        Object result = proxy.invokeSuper(obj, args);

        long elapsed = System.nanoTime() - start;
        System.out.println("[CGLib 后置] 耗时：" + elapsed / 1_000_000 + " ms");
        return result;
    }
}

// 3. 创建并使用代理
public class Main {
    public static void main(String[] args) {
        Enhancer enhancer = new Enhancer();
        enhancer.setSuperclass(UserService.class);
        enhancer.setCallback(new LogMethodInterceptor());

        UserService proxy = (UserService) enhancer.create();
        proxy.addUser("东哥");

        // final 方法不会被代理——直接调用目标方法
        String user = proxy.getUser(1L);
    }
}
```

**CGLib 的原理**：

1. `Enhancer` 使用 ASM 字节码框架动态生成目标类的子类。
2. 子类重写所有非 `final`、非 `static` 的方法。
3. 在重写的方法中，调用 `MethodInterceptor.intercept()`。
4. `MethodProxy.invokeSuper()` 通过 FastClass 机制直接调用父类方法，绕过了反射，性能更优。

**CGLib 的限制**：
- `final` 类和方法不能被代理。
- `private` 和 `static` 方法不会被拦截（子类无法重写）。
- 在 JDK 9+ 模块化环境下，需要额外配置。

### 3.4 JDK 动态代理 vs CGLib 对比

| 维度 | JDK 动态代理 | CGLib 动态代理 |
|------|-------------|---------------|
| 代理方式 | 基于接口（Proxy + InvocationHandler） | 基于继承（Enhancer + MethodInterceptor） |
| 目标要求 | 必须实现接口 | 无接口要求（但不能是 final 类） |
| 性能（创建阶段） | 较快 | 较慢（需 ASM 生成字节码） |
| 性能（调用阶段） | JDK 8+ 优化后接近 CGLib | 较快（FastClass 机制） |
| final 方法 | 不受影响（接口方法不能是 final） | 无法代理 |
| 是否依赖第三方 | 否，JDK 原生 | 是，需要 cglib 和 asm 依赖 |
| 适用场景 | 目标有接口 | 目标无接口或需要代理类本身 |

**实际选择建议**：
- Spring 5.x / Boot 2.x 起，优先使用 JDK 动态代理（默认），仅当目标 Bean 没有实现接口时才回退到 CGLib。
- 可以通过 `spring.aop.proxy-target-class=true` 强制使用 CGLib。

### 3.5 ByteBuddy——新一代字节码增强库

ByteBuddy 是现代 Java 字节码操作的首选库，比 CGLib 更强大、更易用且性能更好。Spring Boot 3.x / Spring Framework 6.x 已经全面转向 ByteBuddy。

```xml
<dependency>
    <groupId>net.bytebuddy</groupId>
    <artifactId>byte-buddy</artifactId>
    <version>1.14.9</version>
</dependency>
```

```java
// 使用 ByteBuddy 创建动态代理
public class LogInterceptor implements MethodDelegation {

    @Override
    public Object intercept(Object obj, Method method, Object[] args,
                            MethodProxy proxy) throws Throwable {
        // ByteBuddy 的 @SuperCall 注解方式
        return proxy.invoke(obj, args);
    }
}

// 更简洁的方式——直接委托给拦截器
UserService proxy = new ByteBuddy()
        .subclass(UserService.class)
        .method(ElementMatchers.any())
        .intercept(MethodDelegation.to(new Object() {
            @RuntimeType
            public Object intercept(@AllArguments Object[] args,
                                    @Origin Method method,
                                    @SuperCall Callable<?> callable) throws Exception {
                System.out.println("ByteBuddy 前置：" + method.getName());
                Object result = callable.call();
                System.out.println("ByteBuddy 后置");
                return result;
            }
        }))
        .make()
        .load(UserService.class.getClassLoader())
        .getLoaded()
        .getDeclaredConstructor()
        .newInstance();

proxy.addUser("东哥");
```

ByteBuddy 的优势在于其纯正的 API 设计、无反射调用链路、以及对 Java 模块系统的良好支持。

---

## 四、代理在 Spring AOP 中的应用

Spring AOP（面向切面编程）是动态代理最经典的应用场景。

### 4.1 Spring AOP 的代理选择策略

```java
// Spring AOP 核心代理决策逻辑（简化版）
public class DefaultAopProxyFactory implements AopProxyFactory {

    @Override
    public AopProxy createAopProxy(AdvisedSupport config) {
        if (config.isOptimize() || config.isProxyTargetClass()
                || hasNoUserSuppliedProxyInterfaces(config)) {
            Class<?> targetClass = config.getTargetClass();
            if (targetClass.isInterface()) {
                return new JdkDynamicAopProxy(config);  // JDK 代理
            }
            return new ObjenesisCglibAopProxy(config);  // CGLib 代理 (Spring 封装)
        } else {
            return new JdkDynamicAopProxy(config);
        }
    }

    private boolean hasNoUserSuppliedProxyInterfaces(AdvisedSupport config) {
        // 如果目标类没有自定义接口，则使用 CGLib
        Class<?>[] interfaces = config.getProxiedInterfaces();
        return interfaces.length == 0;
    }
}
```

### 4.2 AOP 通知的执行链路

当我们在 Service 方法上添加 `@Transactional` 或 `@Cacheable` 注解时，Spring 是如何工作的？

```java
@Service
public class OrderService {

    @Transactional
    public void createOrder(Order order) {
        // 实际业务逻辑
    }
}

// 容器启动时，Spring 会创建代理对象，调用链路如下：
// 1. 调用方调用 proxy.createOrder(order)
// 2. -> JdkDynamicAopProxy.invoke() 或 CglibAopProxy.intercept()
// 3. -> 获取匹配的拦截器链（多个 Advice 组成）
// 4. -> 递归执行拦截器链
//     -> @Before 前置通知
//     -> 事务开启
//     -> @Around 环绕通知
//     -> 目标方法执行
//     -> 事务提交/回滚
//     -> @AfterReturning/@AfterThrowing 后置通知
// 5. -> 返回结果给调用方
```

### 4.3 自调用问题（Self-Invocation）

AOP 最常见的陷阱之一：

```java
@Service
public class OrderService {

    @Transactional
    public void createOrder(Order order) {
        saveOrder(order);
        updateInventory(order);
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void saveOrder(Order order) {
        // ... 期望在新事务中执行
    }
}
```

**问题**：当 `createOrder()` 调用 `saveOrder()` 时，是在目标对象内部直接调用的，而不是通过代理对象，因此 `@Transactional` 注解完全失效。

**解决方案**：

```java
// 方案一：注入自身代理（三级缓存解决循环依赖）
@Service
public class OrderService {
    @Autowired
    private OrderService self;  // 注意：这是代理对象

    public void createOrder(Order order) {
        self.saveOrder(order);  // 通过代理调用，AOP 生效
    }
}

// 方案二：使用 AopContext.currentProxy()
@Service
public class OrderService {
    @Transactional
    public void createOrder(Order order) {
        ((OrderService) AopContext.currentProxy()).saveOrder(order);
    }
}

// 方案三：提取到另一个 Service Bean（推荐——职责单一）
```

---

## 五、动态代理的实际应用场景

### 5.1 ORM 框架中的懒加载

MyBatis 和 Hibernate 使用动态代理实现延迟加载。

```java
// MyBatis Mapper 接口——动态代理的核心应用
public interface UserMapper {
    @Select("SELECT * FROM user WHERE id = #{id}")
    User selectUser(Long id);
}

// MyBatis 在运行期为 UserMapper 生成代理对象
// 当调用 selectUser 时，代理拦截调用，执行 SQL，返回结果
SqlSession sqlSession = sqlSessionFactory.openSession();
UserMapper mapper = sqlSession.getMapper(UserMapper.class);
// mapper 实际是 JDK 动态代理对象
User user = mapper.selectUser(1L);
```

### 5.2 RPC 框架中的远程调用

Dubbo、gRPC 等 RPC 框架的客户端通过动态代理屏蔽网络通信细节：

```java
// Dubbo 的服务引用——动态代理实现远程调用透明化
// 消费者引用远程服务
@DubboReference
private UserService userService;

// 调用本地方法，实际是远程调用
// Dubbo 在运行期为 UserService 创建代理对象
// 代理的 InvocationHandler 负责：
// 1. 序列化方法名和参数
// 2. 通过网络发送到服务提供方
// 3. 等待响应并反序列化返回结果
User user = userService.getUser(1L);
```

### 5.3 声明式事务与缓存

```java
@Service
public class PaymentService {

    @Transactional
    @Cacheable(value = "payments", key = "#orderId")
    public PaymentResult processPayment(String orderId, BigDecimal amount) {
        // Spring 通过 AOP 代理动态添加事务管理和缓存逻辑
        // 代理的拦截器链：
        //   1. CacheInterceptor —— 先查缓存
        //   2. TransactionInterceptor —— 开启事务
        //   3. 目标方法执行
        //   4. TransactionInterceptor —— 提交/回滚
        //   5. CacheInterceptor —— 写入缓存
        return paymentGateway.charge(orderId, amount);
    }
}
```

### 5.4 参数校验与日志审计

```java
// 使用动态代理实现统一参数校验
public class ValidationProxy {

    @SuppressWarnings("unchecked")
    public static <T> T createValidatedProxy(T target) {
        return (T) Proxy.newProxyInstance(
                target.getClass().getClassLoader(),
                target.getClass().getInterfaces(),
                (proxy, method, args) -> {
                    // 获取方法上的 @NotNull 注解
                    Annotation[][] paramAnns = method.getParameterAnnotations();
                    for (int i = 0; i < paramAnns.length; i++) {
                        for (Annotation ann : paramAnns[i]) {
                            if (ann instanceof NotNull && args[i] == null) {
                                throw new IllegalArgumentException(
                                        "参数 " + method.getParameters()[i].getName() + " 不能为空");
                            }
                        }
                    }
                    return method.invoke(target, args);
                }
        );
    }
}
```

---

## 六、反射与动态代理的性能基准测试

```java
// 简单基准测试（JMH 宏基准）
@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.MILLIONS)  // 百万次/秒
@State(Scope.Thread)
public class ReflectionBenchmark {

    private UserService target;
    private UserService jdkProxy;
    private UserService cglibProxy;
    private Method method;
    private UserService byteBuddyProxy;

    @Setup
    public void setup() throws Exception {
        target = new UserServiceImpl();

        // JDK 代理
        jdkProxy = (UserService) Proxy.newProxyInstance(
                target.getClass().getClassLoader(),
                target.getClass().getInterfaces(),
                (p, m, a) -> m.invoke(target, a));

        // CGLib 代理
        Enhancer enhancer = new Enhancer();
        enhancer.setSuperclass(UserServiceImpl.class);
        enhancer.setCallback((MethodInterceptor) (o, m, a, mp) -> mp.invokeSuper(o, a));
        cglibProxy = (UserService) enhancer.create();

        // 缓存 Method 用于反射直接调用
        method = UserService.class.getMethod("addUser", String.class);

        // ByteBuddy 代理（略）
    }

    @Benchmark
    public void directCall() {
        target.addUser("test");
    }

    @Benchmark
    public void jdkProxy() {
        jdkProxy.addUser("test");
    }

    @Benchmark
    public void cglibProxy() {
        cglibProxy.addUser("test");
    }

    @Benchmark
    public void cachedReflection() throws Exception {
        method.invoke(target, "test");
    }
}
```

**典型结果（JDK 17, 仅供参考）**：

| 调用方式 | 吞吐量（百万次/秒） | 相对耗时 |
|---------|-------------------|---------|
| 直接调用 | ≈ 180 | 1x |
| JDK 动态代理 | ≈ 120 | 1.5x |
| CGLib 动态代理 | ≈ 140 | 1.3x |
| 缓存反射方法 | ≈ 95 | 1.9x |
| 未缓存反射 | ≈ 30 | 6x |

> **结论**：JDK 动态代理在 JDK 8+ 中的性能已经非常接近 CGLib。日常开发中优先使用 JDK 动态代理，只有在目标没有接口时才回退到 CGLib 或 ByteBuddy。

---

## 七、总结与最佳实践

### 7.1 反射的最佳实践

1. **缓存 Method/Field/Constructor**：避免重复查找带来的性能损耗。
2. **及时调用 setAccessible(true)**：抑制访问检查，可显著提升性能。
3. **避免在热点路径中使用反射**：如果必须使用，考虑用 `MethodHandle` 或 `LambdaMetafactory` 替代。
4. **注意 JDK 版本差异**：JDK 17+ 需要配置 `--add-opens` 来允许跨模块反射。
5. **对反射操作做单元测试**：反射调用在编译期无法检查，运行时容易抛出异常。

### 7.2 动态代理的最佳实践

1. **接口优先原则**：设计 API 时尽量使用接口，便于使用 JDK 动态代理。
2. **理解自调用问题**：类内部方法调用不会经过代理，AOP 注解会失效。
3. **关注创建性能**：CGLib 代理对象创建较慢，如果代理对象被频繁创建，建议使用对象池或提前创建。
4. **避免过长的拦截器链**：AOP 拦截器链每增加一层都会增加调用开销。
5. **注意 final 方法**：CGLib 无法代理 final 方法，`@Transactional` 标记在 final 方法上无效。

### 7.3 框架选型时间线

```
Spring 2.x 及之前： 默认 CGLib
Spring 3.x - 4.x： 默认 JDK 动态代理，可选 CGLib
Spring 5.x / Boot 2.x：    默认 JDK 动态代理，无接口时自动回退 CGLib
Spring 6.x / Boot 3.x：    全面使用 ByteBuddy（CGLib 被废弃）
```

### 7.4 一句话总结

**反射给了 Java 在运行期自省的能力，动态代理则让这种能力服务于横切关注点的统一管理**。两者相辅相成，构成了 Java 生态中框架设计的脊梁。理解它们的原理，不仅有助于写出更高质量的代码，更能让你在面对各种框架时游刃有余。
