---
title: Spring 核心 IOC 与 AOP 原理精讲
date: 2026-06-11 17:00:00
tags:
  - Spring
  - IOC
  - AOP
  - 容器
  - 动态代理
categories: 源码分析
---

## 前言

Spring 是 Java 后端开发的事实标准框架。**IOC（控制反转）** 和 **AOP（面向切面编程）** 是其两大核心基石。理解这两个概念，不仅是面试必须，更是看懂 Spring Boot 自动配置、事务管理、安全框架等上层功能的前提。

---

## 一、IOC — 控制反转

### 1.1 什么是 IOC？

传统开发中，对象由自己创建和管理依赖：

```java
public class UserService {
    // 传统方式：自己 new 依赖
    private UserDao userDao = new UserDao();
}
```

**控制反转（IOC）** 将对象的创建和依赖管理交给容器：

```java
public class UserService {
    // IOC 方式：容器注入依赖
    @Autowired
    private UserDao userDao;
}
```

> **IOC 的核心思想：** 别打电话给我，我会打给你（Don't call me, I'll call you）。

### 1.2 DI（依赖注入）与 IOC 的关系

IOC 是一种设计思想，**DI（Dependency Injection，依赖注入）** 是 IOC 的具体实现方式。

常见的 DI 方式有三种：

| 注入方式 | 示例 | 优点 | 缺点 |
|---------|------|------|------|
| **构造器注入** | `@Autowired public UserService(UserDao dao)` | 不可变、明确依赖、便于测试 | 构造函数参数过多时略显臃肿 |
| **Setter 注入** | `@Autowired setUserDao(UserDao dao)` | 可选依赖、可重新赋值 | 依赖不完整时可能 NPE |
| **字段注入** | `@Autowired private UserDao dao` | 代码简洁 | 不可测试、违反单一职责（不推荐） |

> Spring 官方推荐**构造器注入**，特别是在 Spring Boot 中。

---

## 二、Spring 容器与 Bean 生命周期

### 2.1 BeanFactory vs ApplicationContext

| 对比项 | BeanFactory | ApplicationContext |
|-------|------------|------------------|
| 实例化策略 | **懒加载**（用到才创建） | **预加载**（启动就创建） |
| 扩展性 | 基础功能 | 事件发布、国际化、AOP 等 |
| 使用场景 | 嵌入式、资源受限环境 | 绝大多数应用 |
| 典型实现 | `DefaultListableBeanFactory` | `AnnotationConfigApplicationContext` |

### 2.2 Bean 的生命周期（面试必问）

```
实例化 → 属性赋值 → 初始化 → 使用 → 销毁

具体流程：

1️⃣ 实例化（Instantiation）
    ↓
2️⃣ 设置属性（Populate Properties）——— @Autowired、@Value、@Resource
    ↓
3️⃣ 执行 Aware 接口
    - BeanNameAware：注入 Bean 名称
    - BeanFactoryAware：注入 BeanFactory
    - ApplicationContextAware：注入 ApplicationContext
    ↓
4️⃣ BeanPostProcessor#postProcessBeforeInitialization
    ↓
5️⃣ 执行初始化
    - @PostConstruct 方法
    - InitializingBean#afterPropertiesSet()
    - @Bean(initMethod="init") 指定方法
    ↓
6️⃣ BeanPostProcessor#postProcessAfterInitialization  ← AOP 在这里完成
    ↓
7️⃣ Bean 就绪，提供服务
    ↓
8️⃣ 容器关闭时销毁
    - @PreDestroy 方法
    - DisposableBean#destroy()
    - @Bean(destroyMethod="close") 指定方法
```

### 2.3 关键扩展点

```java
@Component
public class MyBeanPostProcessor implements BeanPostProcessor {
    
    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        // 在所有 Bean 初始化之前执行
        if (bean instanceof UserService) {
            System.out.println("UserService 即将初始化");
        }
        return bean;
    }
    
    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        // 在所有 Bean 初始化之后执行 —— AOP 代理就在这里产生
        if (bean instanceof UserService) {
            System.out.println("UserService 初始化完成");
        }
        return bean;
    }
}
```

| 扩展点 | 用途 | 经典实现 |
|-------|------|---------|
| `BeanFactoryPostProcessor` | 修改 BeanDefinition | PropertySourcesPlaceholderConfigurer |
| `BeanPostProcessor` | 修改 Bean 实例 | AOP 代理创建 |
| `InitializingBean` | 初始化回调 | @PostConstruct |
| `ApplicationListener` | 监听容器事件 | ContextRefreshedEvent |

---

## 三、Bean 的作用域与循环依赖

### 3.1 作用域

```java
@Component
@Scope("singleton")   // 默认，单例
public class UserService { }

@Component
@Scope("prototype")   // 每次获取创建新实例
public class OrderService { }
```

| 作用域 | 说明 | 使用场景 |
|-------|------|---------|
| **singleton**（默认） | 整个容器一个实例 | 无状态 Bean（Service、DAO） |
| **prototype** | 每次获取新实例 | 有状态 Bean |
| **request** | 每次 HTTP 请求一个实例 | Web MVC Controller |
| **session** | 每个 HTTP Session 一个实例 | 用户登录信息 |
| **application** | ServletContext 粒度 | 全局配置 |

### 3.2 三级缓存与循环依赖

```java
@Service
public class AService {
    @Autowired
    private BService bService;
}

@Service
public class BService {
    @Autowired
    private AService aService;
}
```

Spring 通过**三级缓存**解决 singleton 作用域下的循环依赖：

```java
// DefaultSingletonBeanRegistry.java
public class DefaultSingletonBeanRegistry {
    // 一级缓存：完全创建好的单例 Bean（成品）
    private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);
    
    // 二级缓存：提前暴露的早期 Bean（半成品，还没注入依赖）
    private final Map<String, Object> earlySingletonObjects = new HashMap<>(16);
    
    // 三级缓存：存放 ObjectFactory（lambda 工厂方法，可在此应用 AOP）
    private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);
}
```

**工作流程：**

```
1. A 创建 → A 实例化 → 提前暴露（三级缓存） → 设置属性发现需要 B
2. B 创建 → B 实例化 → 提前暴露 → 设置属性发现需要 A
3. B 从三级缓存获取到 A 的早期引用（可能完成 AOP）
4. B 完成创建 → 放入一级缓存
5. A 从一级缓存获取到 B → 完成 A 的创建
```

⚠️ **注意：** 三级缓存只解决** singleton 作用域 + setter 注入**的循环依赖。**构造器注入**的循环依赖无法解决，会抛出 `BeanCurrentlyInCreationException`。

---

## 四、AOP — 面向切面编程

### 4.1 什么是 AOP？

AOP 将**横切关注点**（日志、事务、权限等）从业务逻辑中抽离出来，降低耦合度。

```
业务代码                              AOP 代理
┌─────────────┐                     ┌─────────────┐
│ 保存用户     │                     │ 保存用户     │
│ ① 记录日志   │   ← 横切关注点       │ ◀── 日志切面 │
│ ② 保存到 DB  │                     │ 保存到 DB    │
│ ③ 权限校验   │   ← 横切关注点       │ ◀── 权限切面 │
│ ④ 发通知     │                     │ 发通知       │
└─────────────┘                     └─────────────┘
```

### 4.2 AOP 核心概念

| 术语 | 含义 | 类比 |
|------|------|------|
| **Join Point** | 程序执行点（方法调用） | 舞台上的每个位置 |
| **Pointcut** | 匹配 Join Point 的表达式 | 切到哪里的"剪刀" |
| **Advice** | 在 Pointcut 处执行的逻辑 | 剪的"动作" |
| **Aspect** | Pointcut + Advice 的组合 | 完整的"剪纸模板" |
| **Weaving** | 将 Aspect 织入目标对象的过程 | 把模板贴上去 |
| **Target** | 被增强的目标对象 | 被剪纸的纸 |

### 4.3 Advice 类型

```java
@Aspect
@Component
public class LogAspect {
    
    // 前置通知：目标方法执行之前
    @Before("execution(* com.example.service.*.*(..))")
    public void beforeAdvice(JoinPoint jp) {
        System.out.println("准备执行: " + jp.getSignature());
    }
    
    // 后置通知：目标方法执行之后（无论是否异常）
    @After("execution(* com.example.service.*.*(..))")
    public void afterAdvice() {
        System.out.println("方法执行完毕");
    }
    
    // 返回通知：目标方法正常返回后
    @AfterReturning(value = "execution(* com.example.service.*.*(..))", 
                    returning = "result")
    public void afterReturning(Object result) {
        System.out.println("返回值: " + result);
    }
    
    // 异常通知：目标方法抛出异常后
    @AfterThrowing(value = "execution(* com.example.service.*.*(..))", 
                   throwing = "ex")
    public void afterThrowing(Exception ex) {
        System.out.println("异常: " + ex.getMessage());
    }
    
    // 环绕通知：完全控制目标方法的执行
    @Around("execution(* com.example.service.*.*(..))")
    public Object aroundAdvice(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        try {
            Object result = pjp.proceed();  // 执行目标方法
            return result;
        } finally {
            long cost = System.currentTimeMillis() - start;
            System.out.println("耗时: " + cost + "ms");
        }
    }
}
```

### 4.4 Pointcut 表达式

```java
// 匹配指定包下所有类的所有方法
@Pointcut("execution(* com.example.service.*.*(..))")

// 匹配指定注解的方法
@Pointcut("@annotation(org.springframework.transaction.annotation.Transactional)")

// 匹配指定注解的类中的所有方法
@Pointcut("@within(org.springframework.stereotype.Service)")

// 匹配指定参数类型的方法
@Pointcut("args(com.example.model.User)")

// 组合：且（&&）、或（||）、非（!）
@Pointcut("execution(* com.example.service.*.*(..)) && !execution(* com.example.service.AdminService.*(..))")
```

---

## 五、AOP 的底层实现

### 5.1 JDK 动态代理

**要求：** 目标类必须实现接口

```java
public class JdkProxyDemo {
    
    public static Object createProxy(Object target) {
        return Proxy.newProxyInstance(
            target.getClass().getClassLoader(),
            target.getClass().getInterfaces(),
            new InvocationHandler() {
                @Override
                public Object invoke(Object proxy, Method method, Object[] args) 
                        throws Throwable {
                    System.out.println("JDK 代理 - 前置处理");
                    Object result = method.invoke(target, args);
                    System.out.println("JDK 代理 - 后置处理");
                    return result;
                }
            }
        );
    }
}
```

**代理类结构：**

```
$Proxy0 extends Proxy implements UserService {
    private InvocationHandler h;
    
    void save(User user) {
        // 调用 InvocationHandler#invoke
        h.invoke(this, saveMethod, new Object[]{user});
    }
}
```

### 5.2 CGLIB 动态代理

**要求：** 不需要接口、类不能是 final、方法不能是 final

```java
public class CglibProxyDemo implements MethodInterceptor {
    
    public Object createProxy(Class<?> targetClass) {
        Enhancer enhancer = new Enhancer();
        enhancer.setSuperclass(targetClass);
        enhancer.setCallback(this);
        return enhancer.create();
    }
    
    @Override
    public Object intercept(Object obj, Method method, Object[] args, 
                            MethodProxy proxy) throws Throwable {
        System.out.println("CGLIB 代理 - 前置处理");
        Object result = proxy.invokeSuper(obj, args);
        System.out.println("CGLIB 代理 - 后置处理");
        return result;
    }
}
```

### 5.3 Spring 如何选择代理方式

```java
// DefaultAopProxyFactory.java
public class DefaultAopProxyFactory implements AopProxyFactory {
    
    @Override
    public AopProxy createAopProxy(AdvisedSupport config) {
        if (config.isOptimize() || 
            config.isProxyTargetClass() || 
            hasNoUserSuppliedProxyInterfaces(config)) {
            Class<?> targetClass = config.getTargetClass();
            // 目标类实现了接口 → JDK 动态代理
            // 否则 → CGLIB
            if (targetClass.isInterface() || Proxy.isProxyClass(targetClass)) {
                return new JdkDynamicAopProxy(config);
            }
            return new ObjenesisCglibAopProxy(config);
        } else {
            return new JdkDynamicAopProxy(config);
        }
    }
}
```

**Spring Boot 2.0+ 默认使用 CGLIB**（`spring.aop.proxy-target-class=true`），因为大多数 Service 都没有显式定义接口。

| 对比项 | JDK 动态代理 | CGLIB |
|-------|------------|-------|
| 原理 | 反射 + 生成接口实现类 | ASM 字节码增强，生成子类 |
| 要求 | 需要接口 | 不需要接口 |
| 性能（1.8+） | 创建快，调用慢 | 创建慢，调用快 |
| 限制 | 无 | final 类/方法无法代理 |

---

## 六、Spring 声明式事务原理

声明式事务是 AOP 最经典的应用。

```java
@Service
public class OrderService {
    
    @Transactional
    public void createOrder(Order order) {
        // 1. 扣库存
        stockService.deduct(order.getProductId());
        // 2. 创建订单
        orderMapper.insert(order);
        // 3. 发消息
        messageService.send(order);
    }
}
```

**@Transactional 背后发生了什么？**

```
调用 createOrder()
    ↓
TransactionInterceptor#invoke()   ← AOP 环绕通知
    ↓
事务开启（connection.setAutoCommit(false)）
    ↓
目标方法执行
    ↓
成功？→ 提交事务（connection.commit()）
失败？→ 回滚事务（connection.rollback()）
    ↓
关闭连接
```

**事务失效的常见场景：**

```java
@Service
public class OrderService {
    
    // 1️⃣ 同一个类内方法自调用 → 事务失效
    public void parentMethod() {
        this.childMethod();  // 直接调用，不走代理
    }
    
    @Transactional
    public void childMethod() { ... }
    
    // ✅ 正确做法：注入自身代理
    @Autowired
    private OrderService self;  // 或使用 AopContext.currentProxy()
    
    public void parentMethod() {
        self.childMethod();  // 走代理，事务生效
    }
    
    // 2️⃣ 事务方法被 final 修饰
    @Transactional
    public final void someMethod() { ... }  // CGLIB 无法重写 final 方法
    
    // 3️⃣ 异常被 try-catch 吃了
    @Transactional
    public void execute() {
        try {
            // 业务代码
        } catch (Exception e) {
            // ❌ catch 了异常，事务不会回滚
            log.error("异常", e);
        }
    }
    
    // 4️⃣ 非 public 方法
    @Transactional
    protected void protectedMethod() { ... }  // 事务不生效
    
    // 5️⃣ 传播行为不正确
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void innerMethod() { ... }
}
```

---

## 七、面试高频问题

**Q1：Spring IOC 容器启动流程是怎样的？**

> 1. 加载配置（XML / 注解 / Java Config）
> 2. 扫描并注册 BeanDefinition
> 3. 调用 BeanFactoryPostProcessor 修改 BeanDefinition
> 4. 实例化 Bean（通过反射或工厂方法）
> 5. 属性注入（填充依赖）
> 6. 执行各种 Aware 接口
> 7. 执行 BeanPostProcessor#postProcessBeforeInitialization
> 8. 执行初始化方法（@PostConstruct、InitializingBean）
> 9. 执行 BeanPostProcessor#postProcessAfterInitialization（AOP 在此创建代理）
> 10. Bean 就绪，提供服务

**Q2：三级缓存如何解决循环依赖？**

> 一级缓存存成品 Bean，二级缓存存半成品 Bean，三级缓存存 ObjectFactory。A 创建时提前暴露 ObjectFactory 到三级缓存，B 注入 A 时通过工厂获取早期引用，完成后 A 再获取 B，最终都放入一级缓存。

**Q3：JDK 动态代理和 CGLIB 优先用哪种？**

> Spring Boot 2.0+ 默认 CGLIB。如果不需要接口，用 CGLIB 性能更好；如需基于接口编程（如配合 RPC 框架）可用 JDK 代理。

**Q4：@Transactional 为什么在同一个类里调用会失效？**

> 因为 AOP 代理机制。自调用 `this.method()` 不经过代理对象，而是直接调用目标对象的方法。需要用 `(XxxService) AopContext.currentProxy()` 或注入自身代理来解决。

---

## 八、总结

1. **IOC** 把对象的创建和依赖管理交给容器，核心是 DI
2. **Bean 生命周期**分 ==实例化 → 属性注入 → 初始化 → 使用 → 销毁== 五步
3. **三级缓存**解决 singleton 循环依赖，但构造器注入不行
4. **AOP** 底层是 JDK 动态代理（接口）和 CGLIB（子类）
5. **声明式事务**本质是 AOP 环绕通知，多个场景会导致事务失效
6. **BeanPostProcessor** 是 IOC 和 AOP 的桥梁，AOP 代理在初始化完成后创建
