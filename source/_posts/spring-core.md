---
title: Spring 核心原理详解（面试跳槽篇）
date: 2026-06-13 06:31:00
tags:
  - Spring
  - IoC
  - DI
  - AOP
  - Bean生命周期
  - 循环依赖
categories:
  - Spring框架
author: 东哥
---

# Spring 核心原理详解（面试跳槽篇）

## 一、Spring IoC（控制反转）与 DI（依赖注入）

### 1.1 什么是 IoC

**IoC（Inversion of Control，控制反转）** 是 Spring 框架最核心的设计思想，也被称为**好莱坞原则**——"Don't call me, I'll call you"。

传统的 Java 开发中，对象需要自己创建依赖对象，主动权在自己手中。而 IoC 则将**对象的创建权**交给容器，容器负责创建和管理对象之间的依赖关系。

> **一句话总结：** 对象的创建和组装不再由调用者完成，而是交给 IoC 容器管理，这就是"控制反转"。

### 1.2 IoC 容器设计思想

Spring 的 IoC 容器本质上是一个**超级工厂**，核心职责如下：

1. **对象创建**：通过反射机制实例化 Bean
2. **依赖注入**：解析并注入 Bean 之间的依赖关系
3. **生命周期管理**：管理 Bean 从创建到销毁的完整过程
4. **配置管理**：支持 XML、注解、Java Config 等多种配置方式

### 1.3 BeanFactory vs ApplicationContext

| 特性 | BeanFactory | ApplicationContext |
|------|-----------|-------------------|
| 容器类型 | 最基础容器 | 企业级容器（功能更丰富） |
| 加载方式 | **延迟加载**（Lazy） | **预加载**（Eager），也可配置延迟 |
| 扩展功能 | 仅 IoC 基础 | AOP、事件发布、国际化、资源加载 |
| 常见实现 | XmlBeanFactory（已废弃） | ClassPathXmlApplicationContext, AnnotationConfigApplicationContext |
| 使用场景 | 资源受限环境（嵌入式） | 绝大多数项目 |

```java
// ApplicationContext 示例
ApplicationContext ctx = new AnnotationConfigApplicationContext(AppConfig.class);
UserService userService = ctx.getBean(UserService.class);

// BeanFactory 示例（底层使用）
BeanFactory factory = new DefaultListableBeanFactory();
((DefaultListableBeanFactory) factory).registerBeanDefinition("userService", ...);
```

> **核心区别：** ApplicationContext 继承了 BeanFactory，并增加了 AOP、事件、国际化等企业级功能，是实际开发中使用的容器。

### 1.4 三种配置方式

#### XML 配置（传统方式）

```xml
<beans xmlns="http://www.springframework.org/schema/beans"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://www.springframework.org/schema/beans
           http://www.springframework.org/schema/beans/spring-beans.xsd">
    
    <bean id="userDao" class="com.example.dao.UserDao"/>
    <bean id="userService" class="com.example.service.UserService">
        <property name="userDao" ref="userDao"/>
    </bean>
</beans>
```

#### 注解配置（最常用）

```java
@Component
public class UserService {
    @Autowired
    private UserDao userDao;
}

@Component
public class UserDao {
    public void save() {
        System.out.println("保存用户");
    }
}
```

#### Java Config（推荐方式）

```java
@Configuration
@ComponentScan("com.example")
public class AppConfig {
    
    @Bean
    public DataSource dataSource() {
        HikariDataSource ds = new HikariDataSource();
        ds.setJdbcUrl("jdbc:mysql://localhost:3306/test");
        ds.setUsername("root");
        ds.setPassword("123456");
        return ds;
    }
    
    @Bean
    public JdbcTemplate jdbcTemplate(DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}
```

### 1.5 Bean 的实例化方式

#### 构造器实例化（最常用）

```java
@Component
public class UserService {
    // 默认使用无参构造器
}
```

#### 静态工厂方法

```java
public class MyBeanFactory {
    public static UserService createUserService() {
        System.out.println("静态工厂创建...");
        return new UserService();
    }
}

// XML 配置
// <bean id="userService" class="com.example.MyBeanFactory" factory-method="createUserService"/>
```

#### 实例工厂方法

```java
public class MyBeanFactory {
    public UserService createUserService() {
        return new UserService();
    }
}

// XML 配置
// <bean id="myBeanFactory" class="com.example.MyBeanFactory"/>
// <bean id="userService" factory-bean="myBeanFactory" factory-method="createUserService"/>
```

#### FactoryBean（高级用法）

```java
@Component
public class MyFactoryBean implements FactoryBean<UserService> {
    
    @Override
    public UserService getObject() throws Exception {
        // 可以在这里做复杂初始化
        return new UserService();
    }
    
    @Override
    public Class<?> getObjectType() {
        return UserService.class;
    }
    
    @Override
    public boolean isSingleton() {
        return true;
    }
}
```

### 1.6 自动装配模式

| 模式 | 说明 |
|------|------|
| `no` | 不自动装配，手动指定 |
| `byName` | 根据属性名匹配 Bean |
| `byType` | 根据属性类型匹配 Bean（默认） |
| `constructor` | 通过构造器参数自动装配 |

```java
@Service
public class OrderService {
    
    // byName：变量名"userDao"匹配容器中名为"userDao"的Bean
    // 实际上@Autowired默认是byType，可以通过@Qualifier指定名称
    @Autowired
    @Qualifier("userDaoImpl")
    private UserDao userDao;
    
    // constructor：构造器注入（推荐方式）
    private final PaymentService paymentService;
    
    public OrderService(PaymentService paymentService) {
        this.paymentService = paymentService;
    }
}
```

### 1.7 @Autowired vs @Resource vs @Inject

| 特性 | @Autowired | @Resource | @Inject |
|------|-----------|-----------|--------|
| 来源 | Spring 框架 | JSR-250 标准 | JSR-330 标准 |
| 匹配方式 | **byType** 优先 | **byName** 优先 | byType 优先 |
| 指定名称 | @Qualifier | name 属性 | @Named |
| 是否必填 | required 属性（默认 true） | 无 | 无 |

```java
public class Example {
    
    // @Autowired：先按类型匹配，若有多个再用@Qualifier
    @Autowired
    @Qualifier("userDaoImpl")
    private UserDao userDao;
    
    // @Resource：先按名称"userDao"匹配，找不到再按类型
    @Resource(name = "userDaoImpl")
    private UserDao userDao2;
    
    // @Inject：与@Autowired类似，需引入javax.inject依赖
    @Inject
    @Named("userDaoImpl")
    private UserDao userDao3;
}
```

---

## 二、Bean 生命周期（面试核心）

### 2.1 完整生命周期 11 步

Bean 的生命周期是 Spring 面试的**必考题**，下面通过流程图和代码一步步拆解。

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Bean 生命周期                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ① 实例化（通过反射创建对象）                                        │
│       ↓                                                             │
│  ② 属性注入（依赖注入）                                              │
│       ↓                                                             │
│  ③ 设置 BeanName（BeanNameAware）                                   │
│       ↓                                                             │
│  ④ 设置 BeanFactory（BeanFactoryAware）                             │
│       ↓                                                             │
│  ⑤ 设置 ApplicationContext（ApplicationContextAware）               │
│       ↓                                                             │
│  ⑥ BeanPostProcessor#postProcessBeforeInitialization（前置处理）    │
│       ↓                                                             │
│  ⑦ InitializingBean#afterPropertiesSet / @PostConstruct / init-method│
│       ↓                                                             │
│  ⑧ BeanPostProcessor#postProcessAfterInitialization（后置处理）     │
│       ↓                                                             │
│  ⑨ Bean 就绪可用（放入 singletonObjects）                           │
│       ↓                                                             │
│  ⑩ 容器关闭时：@PreDestroy / DisposableBean#destroy / destroy-method│
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 代码验证所有生命周期回调

```java
@Component
public class LifecycleBean implements BeanNameAware, BeanFactoryAware,
        ApplicationContextAware, InitializingBean, DisposableBean {
    
    private String name;
    
    // 构造函数
    public LifecycleBean() {
        System.out.println("① 实例化：LifecycleBean 构造器执行");
    }
    
    // 属性注入
    @Autowired
    public void setName(String name) {
        this.name = name;
        System.out.println("② 属性注入：setName = " + name);
    }
    
    // ③ BeanNameAware
    @Override
    public void setBeanName(String name) {
        System.out.println("③ BeanNameAware：beanName = " + name);
    }
    
    // ④ BeanFactoryAware
    @Override
    public void setBeanFactory(BeanFactory beanFactory) {
        System.out.println("④ BeanFactoryAware：获取 BeanFactory");
    }
    
    // ⑤ ApplicationContextAware
    @Override
    public void setApplicationContext(ApplicationContext ctx) {
        System.out.println("⑤ ApplicationContextAware：获取 ApplicationContext");
    }
    
    // ⑥ @PostConstruct（等同于 postProcessBeforeInitialization 效果）
    @PostConstruct
    public void postConstruct() {
        System.out.println("⑥ @PostConstruct：初始化前执行");
    }
    
    // ⑦ InitializingBean
    @Override
    public void afterPropertiesSet() {
        System.out.println("⑦ InitializingBean：afterPropertiesSet 执行");
    }
    
    // 自定义 init-method
    @Bean(initMethod = "customInit")
    public void customInit() {
        System.out.println("⑦ init-method：customInit 执行");
    }
    
    // ⑧ @PreDestroy
    @PreDestroy
    public void preDestroy() {
        System.out.println("⑩ @PreDestroy：销毁前执行");
    }
    
    // ⑧ DisposableBean
    @Override
    public void destroy() {
        System.out.println("⑩ DisposableBean：destroy 执行");
    }
    
    // 自定义 destroy-method
    @Bean(destroyMethod = "customDestroy")
    public void customDestroy() {
        System.out.println("⑩ destroy-method：customDestroy 执行");
    }
}
```

### 2.3 BeanPostProcessor 详解

`BeanPostProcessor` 是 Spring 框架的**核心扩展点**，Spring 的 AOP、注解处理等功能都基于它实现。

```java
@Component
public class MyBeanPostProcessor implements BeanPostProcessor {
    
    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        if (bean instanceof UserService) {
            System.out.println("⑥ 前置处理：" + beanName);
        }
        return bean; // 可以返回包装后的代理对象
    }
    
    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        if (bean instanceof UserService) {
            System.out.println("⑧ 后置处理：" + beanName);
            // 可以在这里返回代理对象（AOP 就是在这步创建的）
        }
        return bean;
    }
}
```

### 2.4 BeanPostProcessor vs InstantiationAwareBeanPostProcessor

| 接口 | 作用 | 调用时机 |
|------|------|---------|
| BeanPostProcessor | 初始化前后的拦截 | 初始化前后 |
| InstantiationAwareBeanPostProcessor | 实例化前后的拦截 | 更早，在 new 对象之前和之后 |

```java
@Component
public class CustomInstantiationProcessor implements InstantiationAwareBeanPostProcessor {
    
    @Override
    public Object postProcessBeforeInstantiation(Class<?> beanClass, String beanName) {
        // 可以在实例化之前返回代理对象，完全跳过 Spring 的实例化流程
        if (beanClass == UserService.class) {
            return Proxy.newProxyInstance(...); // 返回代理
        }
        return null; // null 表示继续走 Spring 正常实例化流程
    }
    
    @Override
    public boolean postProcessAfterInstantiation(Object bean, String beanName) {
        // 实例化之后，属性注入之前返回 false 可以阻止属性注入
        return true; // true 表示继续注入属性
    }
    
    @Override
    public PropertyValues postProcessProperties(PropertyValues pvs, Object bean, String beanName) {
        // 可以修改注入的属性值
        return pvs;
    }
}
```

### 2.5 常用 Aware 接口

```java
@Component
public class AwareDemo implements BeanNameAware, BeanFactoryAware,
        ApplicationContextAware, EnvironmentAware, ResourceLoaderAware {
    
    @Override
    public void setBeanName(String name) {
        System.out.println("获取 Bean 名称：" + name);
    }
    
    @Override
    public void setBeanFactory(BeanFactory beanFactory) {
        System.out.println("获取 BeanFactory：" + beanFactory);
    }
    
    @Override
    public void setApplicationContext(ApplicationContext ctx) {
        System.out.println("获取 ApplicationContext：" + ctx);
    }
    
    @Override
    public void setEnvironment(Environment environment) {
        System.out.println("获取 Environment：" + environment.getProperty("spring.profiles.active"));
    }
    
    @Override
    public void setResourceLoader(ResourceLoader resourceLoader) {
        System.out.println("获取 ResourceLoader");
    }
}
```

---

## 三、循环依赖（面试超高频）

### 3.1 什么是循环依赖

循环依赖是指两个或多个 Bean 之间相互引用，形成闭环：

```java
@Component
public class AService {
    @Autowired
    private BService bService;
}

@Component
public class BService {
    @Autowired
    private AService aService;
}
```

### 3.2 构造器循环依赖 vs Setter 循环依赖

```java
// ❌ 构造器循环依赖——无法解决！
@Component
public class AService {
    private BService bService;
    public AService(BService bService) {
        this.bService = bService;
    }
}

@Component
public class BService {
    private AService aService;
    public BService(AService aService) {
        this.aService = aService;
    }
}

// ✅ Setter 循环依赖——可以通过三级缓存解决！
@Component
public class AService {
    private BService bService;
    @Autowired
    public void setBService(BService bService) {
        this.bService = bService;
    }
}

@Component
public class BService {
    private AService aService;
    @Autowired
    public void setAService(AService aService) {
        this.aService = aService;
    }
}
```

### 3.3 三级缓存机制

Spring 通过**三级缓存**解决 Setter 注入的循环依赖：

```java
public class DefaultSingletonBeanRegistry {

    /** 一级缓存：成品 Bean（完全初始化好了） */
    private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);
    
    /** 二级缓存：半成品 Bean（已实例化，未完成属性注入） */
    private final Map<String, Object> earlySingletonObjects = new ConcurrentHashMap<>(16);
    
    /** 三级缓存：ObjectFactory（提前暴露的工厂） */
    private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);
}
```

**三级缓存工作原理（以 A→B→A 为例）：**

```
1. getBean("a") → 创建 A
2. A 实例化完成，放入三级缓存 singletonFactories
3. 开始为 A 注入属性 bService
4. getBean("b") → 创建 B
5. B 实例化完成，放入三级缓存
6. 开始为 B 注入属性 aService
7. getSingleton("a") → 从三级缓存找到 A 的 ObjectFactory
8. 执行 ObjectFactory.getObject() → 获取 A 的早期引用
   （如果有 AOP，此时会生成 A 的代理对象）
9. 将 A 的早期引用放入二级缓存（移除三级缓存）
10. B 注入完成，放入一级缓存
11. B 返回，A 注入 bService 完成
12. A 执行初始化方法
13. A 放入一级缓存
```

### 3.4 为什么需要三级缓存？为什么二级不够？

```java
// 三级缓存存的是 ObjectFactory，而不是直接存半成品对象
// 核心原因：AOP 代理！
// 
// 如果只有二级缓存：
// 没有 AOP 的场景 → 直接存早期对象，没问题 ✅
// 有 AOP 的场景 → 需要的是代理对象，而不是原始对象 ❌
//
// 三级缓存的 ObjectFactory 可以延迟执行：
// (以下代码来自 Spring 源码中的 getEarlyBeanReference 方法)
protected Object getEarlyBeanReference(String beanName, RootBeanDefinition mbd, Object bean) {
    Object exposedObject = bean;
    if (!mbd.isSynthetic() && hasInstantiationAwareBeanPostProcessors()) {
        for (SmartInstantiationAwareBeanPostProcessor bp : getBeanPostProcessors()) {
            exposedObject = bp.getEarlyBeanReference(exposedObject, mbd.getBeanClassName());
        }
    }
    return exposedObject;
}
```

> **一句话总结：** 三级缓存是为了在循环依赖发生时，能够创建出正确的 **AOP 代理对象**（或通过后置处理器包装过的对象）。如果只有二级缓存，只能拿原始对象，后续无法再生成代理。

### 3.5 构造器循环依赖为什么无法解决？

```java
// 构造器注入时，实例化方法 new AService(BService) 就需要 BService
// 而此时 A 还处于构造阶段，根本还没创建出来
// 无法提前暴露半成品 → 三级缓存帮不上忙 → BeanCurrentlyInCreationException
//
// Spring 的判断机制：
// 每个 Bean 创建时会在 singletonCurrentlyInCreation 中标记
// 如果构造器中引用了另一个也在创建中的 Bean → 抛异常

@Component
public class AService {
    private final BService bService;
    
    public AService(BService bService) {  // ← 此时 A 还没创建出来
        this.bService = bService;
    }
}
// 报错：Requested bean is currently in creation: Is there an unresolvable circular reference?
```

### 3.6 源码流程分析

```java
// 简化版源码分析
public class AbstractBeanFactory {
    
    protected <T> T doGetBean(String name, ...) {
        // 1. 先从缓存中获取
        Object sharedInstance = getSingleton(beanName);
        if (sharedInstance != null) {
            // 缓存命中，直接返回
            return (T) sharedInstance;
        }
        
        // 2. 准备创建 Bean
        // ...
        
        // 3. 如果是单例，调用 getSingleton 方法创建
        if (mbd.isSingleton()) {
            sharedInstance = getSingleton(beanName, () -> createBean(beanName, mbd, args));
        }
        
        return (T) sharedInstance; java
    }
    
    public Object getSingleton(String beanName, ObjectFactory<?> singletonFactory) {
        // 标记当前 Bean 正在创建中
        beforeSingletonCreation(beanName);
        
        try {
            singletonObject = singletonFactory.getObject();
        } finally {
            afterSingletonCreation(beanName);
        }
        
        addSingleton(beanName, singletonObject);
        return singletonObject;
    }
    
    // getSingleton 从三级缓存获取
    protected Object getSingleton(String beanName, boolean allowEarlyReference) {
        Object singletonObject = this.singletonObjects.get(beanName);
        if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
            // 二级缓存查找
            singletonObject = this.earlySingletonObjects.get(beanName);
            if (singletonObject == null && allowEarlyReference) {
                // 三级缓存查找
                ObjectFactory<?> singletonFactory = this.singletonFactories.get(beanName);
                if (singletonFactory != null) {
                    // 执行 ObjectFactory 获取早期引用
                    singletonObject = singletonFactory.getObject();
                    // 放入二级缓存，移除三级缓存
                    this.earlySingletonObjects.put(beanName, singletonObject);
                    this.singletonFactories.remove(beanName);
                }
            }
        }
        return singletonObject;
    }
    
    // 创建 Bean 时，实例化后会放入三级缓存
    protected Object doCreateBean(String beanName, RootBeanDefinition mbd, Object[] args) {
        // 实例化
        BeanWrapper instanceWrapper = createBeanInstance(beanName, mbd, args);
        
        // 提前暴露：放入三级缓存
        addSingletonFactory(beanName, () -> getEarlyBeanReference(beanName, mbd, bean));
        
        // 属性注入
        populateBean(beanName, mbd, instanceWrapper);
        
        // 初始化
        exposedObject = initializeBean(beanName, exposedObject, mbd);
        
        return exposedObject;
    }
}
```

---

## 四、Spring AOP 原理

### 4.1 AOP 核心概念

| 概念 | 说明 | 类比 |
|------|------|------|
| **JoinPoint**（连接点） | 方法执行的点 | 所有方法都是候选 |
| **Pointcut**（切点） | 哪些方法需要增强 | 筛选条件 |
| **Advice**（通知） | 增强的逻辑 | 具体做什么 |
| **Aspect**（切面） | Pointcut + Advice | 完整切面定义 |
| **Weaving**（织入） | 把切面应用到目标对象 | 组合过程 |

### 4.2 JDK 动态代理 vs CGLib 代理

```java
// JDK 动态代理：要求目标实现接口
public interface UserService {
    void save();
}

@Service
public class UserServiceImpl implements UserService {
    @Override
    public void save() {
        System.out.println("保存用户");
    }
}

// 底层生成的代理对象：
// $Proxy0 implements UserService {
//     void save() {
//         // AOP 增强逻辑
//         methodInterceptor.invoke(...);
//     }
// }

// CGLib 代理：通过继承目标类生成子类
@Service
public class UserService {
    public void save() {
        System.out.println("保存用户");
    }
}

// 底层生成的代理对象：
// UserService$$EnhancerByCGLIB extends UserService {
//     void save() {
//         // AOP 增强逻辑
//         methodInterceptor.intercept(...);
//     }
// }
```

**选择规则（Spring 源码）：**

```java
// 来自 DefaultAopProxyFactory
public AopProxy createAopProxy(AdvisedSupport config) {
    if (config.isOptimize() || config.isProxyTargetClass() || 
        hasNoUserSuppliedProxyInterfaces(config)) {
        Class<?> targetClass = config.getTargetClass();
        if (targetClass.isInterface() || Proxy.isProxyClass(targetClass)) {
            return new JdkDynamicAopProxy(config);  // JDK 代理
        }
        return new ObjenesisCglibAopProxy(config);   // CGLib 代理
    } else {
        return new JdkDynamicAopProxy(config);
    }
}
```

> **经验之谈：** Spring Boot 2.0+ 默认使用 CGLib 代理（spring.aop.proxy-target-class=true）。

### 4.3 @EnableAspectJAutoProxy

```java
@Configuration
@EnableAspectJAutoProxy // 开启 AspectJ 注解支持
public class AopConfig {
}

// 底层导入 AnnotationAwareAspectJAutoProxyCreator
// → 实现了 SmartInstantiationAwareBeanPostProcessor
// → 在 Bean 初始化后（postProcessAfterInitialization）检查是否需要创建代理
```

### 4.4 五类通知执行顺序

```java
@Aspect
@Component
public class LogAspect {
    
    // 切入点
    @Pointcut("execution(* com.example.service.*.*(..))")
    public void pointcut() {}
    
    @Before("pointcut()")
    public void before() {
        System.out.println("【@Before】方法执行前");
    }
    
    @Around("pointcut()")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        System.out.println("【@Around】前置通知");
        Object result = pjp.proceed(); // 执行目标方法
        System.out.println("【@Around】后置通知");
        return result;
    }
    
    @After("pointcut()")
    public void after() {
        System.out.println("【@After】方法执行后（无论是否异常）");
    }
    
    @AfterReturning("pointcut()")
    public void afterReturning() {
        System.out.println("【@AfterReturning】方法正常返回后");
    }
    
    @AfterThrowing("pointcut()")
    public void afterThrowing() {
        System.out.println("【@AfterThrowing】方法抛出异常后");
    }
}
```

**执行顺序（正常情况）：**

```
1️⃣ @Around 前置通知
2️⃣ @Before
3️⃣ 目标方法执行
4️⃣ @Around 后置通知
5️⃣ @After
6️⃣ @AfterReturning
```

**执行顺序（异常情况）：**

```
1️⃣ @Around 前置通知
2️⃣ @Before
3️⃣ 目标方法执行（抛出异常）
4️⃣ @After
5️⃣ @AfterThrowing
```

---

## 五、Spring 事务

### 5.1 @Transactional 底层原理

```java
// @Transactional 基于 AOP + TransactionInterceptor

// 简化流程：
// 1. AOP 代理拦截带 @Transactional 的方法
// 2. TransactionInterceptor.invoke() 被调用
// 3. 获取事务属性（传播行为、隔离级别等）
// 4. 调用 PlatformTransactionManager.getTransaction()
// 5. 执行业务方法
// 6. 成功 → commit() / 失败 → rollback()
// 7. 清理事务资源

@Transactional
public void transferMoney(String from, String to, BigDecimal amount) {
    // Spring 代理会做：
    // try {
    //     TransactionManager.begin();
    //     this.doSomething();      // 真正的业务逻辑
    //     TransactionManager.commit();
    // } catch (Exception e) {
    //     TransactionManager.rollback();
    //     throw e;
    // }
}
```

### 5.2 七种事务传播行为

```java
@Service
public class TransactionService {
    
    // 1. REQUIRED（默认）：有事务用现有，没有则新建
    @Transactional(propagation = Propagation.REQUIRED)
    public void methodA() {}
    
    // 2. REQUIRES_NEW：无论有没有事务，都新建事务（挂起当前事务）
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void methodB() {}
    
    // 3. NESTED：嵌套事务（Savepoint，JDBC 特性，需 JDBC 3.0+）
    //    内部事务回滚不影响外部事务
    @Transactional(propagation = Propagation.NESTED)
    public void methodC() {}
    
    // 4. SUPPORTS：有事务就加入，没有就不开
    @Transactional(propagation = Propagation.SUPPORTS)
    public void methodD() {}
    
    // 5. NOT_SUPPORTED：以非事务方式执行，挂起当前事务
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    public void methodE() {}
    
    // 6. MANDATORY：必须在事务中执行，没有事务抛异常
    @Transactional(propagation = Propagation.MANDATORY)
    public void methodF() {}
    
    // 7. NEVER：必须在非事务中执行，有事务抛异常
    @Transactional(propagation = Propagation.NEVER)
    public void methodG() {}
}
```

**REQUIRES_NEW 与 NESTED 的区别：**

```java
// 场景：A 调 B，B 失败
// 
// REQUIRES_NEW：B 回滚不影响 A 提交 ✅
// NESTED：B 回滚不影响 A 提交 ✅
//
// 区别：
// REQUIRES_NEW → 两个完全独立的事务（连接可能不同）
// NESTED → 一个事务中的保存点（同一个连接）
// 
// REQUIRES_NEW：外部事务等待内部事务完成（挂起/恢复）
// NESTED：外部事务锁不会被内部释放
//
// 数据可见性：
// REQUIRES_NEW：内部事务提交后，外部事务立刻可见（但未提交）
// NESTED：内部回滚到保存点，外部可以继续提交
```

### 5.3 事务隔离级别

```java
@Transactional(isolation = Isolation.READ_COMMITTED)
public void queryData() {}

// Isolation.DEFAULT：使用数据库默认隔离级别（MySQL → REPEATABLE_READ）
// Isolation.READ_UNCOMMITTED：读未提交（脏读、不可重复读、幻读）
// Isolation.READ_COMMITTED：读已提交（不可重复读、幻读）★ 推荐
// Isolation.REPEATABLE_READ：可重复读（幻读）
// Isolation.SERIALIZABLE：串行化（全解决，但性能最低）
```

### 5.4 同一个类中方法调用事务失效

```java
@Service
public class OrderService {
    
    @Transactional
    public void methodA() {
        // 调用同类方法 methodB
        methodB(); // ❌ 事务失效！
    }
    
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void methodB() {
        // B 的更新操作不在事务中
        // 也没有 REQUIRES_NEW 效果
    }
}

// ⚠️ 原因：
// methodA() 通过代理对象调用 → 有事务
// methodB() 被 this.methodB() 调用 → 直接调用目标对象的方法
// → 绕过了代理！没有事务增强！
```

**解决方案：**

```java
// 方案一：注入自身代理（构造器注入）
@Service
public class OrderService {
    @Autowired
    private OrderService self; // 注入代理对象
    
    @Transactional
    public void methodA() {
        self.methodB(); // ✅ 通过代理调用
    }
}

// 方案二：使用 AopContext.currentProxy()
@Service
@EnableAspectJAutoProxy(exposeProxy = true) // 暴露代理
public class OrderService {
    
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void methodB() {}
    
    @Transactional
    public void methodA() {
        ((OrderService) AopContext.currentProxy()).methodB(); // ✅
    }
}
```

### 5.5 事务失效场景大全

| 场景 | 原因 | 解决方案 |
|------|------|---------|
| `@Transactional` 放在 private 方法上 | CGLib/JDK 代理无法拦截 private 方法 | 改为 public |
| 同类方法调用 | this 调用绕过代理 | 注入自身或 AopContext |
| 不是 Spring 管理的 Bean | 事务由 AOP 代理管理 | 用 @Component/@Service |
| 方法被 final 修饰 | CGLib 无法重写 final 方法 | 去掉 final |
| 数据库不支持事务 | 如 MySQL MyISAM 引擎 | 改用 InnoDB |
| 异常被 catch 吃掉 | 事务拦截器没看到异常 | 不要吞异常或手动回滚 |
| 异常类型不对 | 默认只回滚 RuntimeException 和 Error | rollbackFor = Exception.class |
| 多线程调用 | 事务与线程绑定（ThreadLocal） | 自行控制事务边界 |
| propagation 设置不当 | SUPPORTS 等不会创建新事务 | 设置合适的传播行为 |

---

## 六、Spring Boot 自动配置原理

### 6.1 @SpringBootApplication 组合注解

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@SpringBootConfiguration          // 继承 @Configuration
@EnableAutoConfiguration           // ⭐ 核心：开启自动配置
@ComponentScan(excludeFilters = {  // 组件扫描
    @Filter(type = FilterType.CUSTOM, classes = TypeExcludeFilter.class),
    @Filter(type = FilterType.CUSTOM, classes = AutoConfigurationExcludeFilter.class) })
public @interface SpringBootApplication {
}
```

### 6.2 @EnableAutoConfiguration 原理

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@AutoConfigurationPackage           // 注册当前包名
@Import(AutoConfigurationImportSelector.class) // ⭐ 核心！
public @interface EnableAutoConfiguration {
}

// AutoConfigurationImportSelector 的 selectImports 方法
public String[] selectImports(AnnotationMetadata annotationMetadata) {
    // 获取所有候选自动配置类
    AutoConfigurationEntry autoConfigurationEntry = 
        getAutoConfigurationEntry(annotationMetadata);
    return StringUtils.toStringArray(autoConfigurationEntry.getConfigurations());
}

protected List<String> getCandidateConfigurations(AnnotationMetadata metadata, 
        AnnotationAttributes attributes) {
    // 从 META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports 加载
    List<String> configurations = SpringFactoriesLoader.loadFactoryNames(
        getSpringFactoriesLoaderFactoryClass(), getBeanClassLoader());
    Assert.notEmpty(configurations, "No auto configuration classes found");
    return configurations;
}
```

### 6.3 自动配置配置文件

**Spring Boot 2.7+ 使用新的配置方式：**

```properties
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
# 每行一个自动配置类全限定名
com.example.autoconfigure.MyAutoConfiguration
```

**Spring Boot 2.7 之前使用 spring.factories：**

```properties
# META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
com.example.autoconfigure.MyAutoConfiguration
```

### 6.4 条件装配 @Conditional 系列

```java
@Configuration
@ConditionalOnClass(DataSource.class)   // DataSource 在类路径上才生效
@ConditionalOnMissingBean(DataSource.class) // 没有自定义 DataSource 才生效
@EnableConfigurationProperties(DataSourceProperties.class)
public class DataSourceAutoConfiguration {
    
    @Bean
    @ConditionalOnMissingBean
    public DataSource dataSource(DataSourceProperties properties) {
        HikariDataSource ds = new HikariDataSource();
        ds.setJdbcUrl(properties.getUrl());
        ds.setUsername(properties.getUsername());
        ds.setPassword(properties.getPassword());
        return ds;
    }
}
```

**常用 @Conditional 注解：**

```java
@ConditionalOnClass          // 类路径存在指定类
@ConditionalOnMissingClass   // 类路径不存在指定类
@ConditionalOnBean           // 容器中存在指定 Bean
@ConditionalOnMissingBean    // 容器中不存在指定 Bean
@ConditionalOnProperty       // 配置文件有指定属性
@ConditionalOnExpression     // SpEL 表达式
@ConditionalOnResource       // 存在指定资源
@ConditionalOnWebApplication // 是 Web 应用
@ConditionalOnCloudPlatform  // 指定云平台
```

**自定义条件：**

```java
public class OnMacCondition implements Condition {
    @Override
    public boolean matches(ConditionContext context, AnnotatedTypeMetadata metadata) {
        return System.getProperty("os.name").contains("Mac");
    }
}

@Configuration
@Conditional(OnMacCondition.class)
public class MacConfig {
    @Bean
    public String macGreeting() {
        return "Hello Mac!";
    }
}
```

---

## 七、面试高频题

### 7.1 Spring 中设计模式运用

| 设计模式 | 应用 | 说明 |
|---------|------|------|
| **工厂模式** | BeanFactory | 创建和管理 Bean 实例 |
| **单例模式** | Bean 默认 Scope | 默认所有 Bean 为单例 |
| **代理模式** | AOP 实现 | JDK 动态代理 / CGLib 代理 |
| **模板方法** | JdbcTemplate、RestTemplate | 固定流程 + 子类/回调定制 |
| **观察者模式** | ApplicationListener | 事件驱动模型 |
| **策略模式** | Resource 加载 | 根据 URL 前缀选择不同 Resource 实现 |
| **适配器模式** | AdvisorAdapter | 将 Advice 适配为 MethodInterceptor |
| **装饰器模式** | BeanWrapper | 包装 Bean 实例 |
| **委派模式** | DispatcherServlet | 委派给 HandlerMapping、HandlerAdapter |
| **责任链模式** | HandlerExecutionChain | 拦截器链式调用 |

### 7.2 @Configuration 与 @Component 的区别

```java
// @Configuration（Full 模式）：被 CGLib 代理
@Configuration
public class AppConfig {
    
    @Bean
    public A a() {
        return new A(b()); // 调用 @Bean 方法
    }
    
    @Bean
    public B b() {
        return new B();
    }
}
// 结果：a() 和 b() 中的 B 是同一个实例 ✅
// 原因：CGLib 代理拦截了 b() 调用，从容器获取

// @Component（Lite 模式）：不代理
@Component
public class AppConfig {
    
    @Bean
    public A a() {
        return new A(b());
    }
    
    @Bean
    public B b() {
        return new B();
    }
}
// 结果：a() 中的 b() 调用是普通方法调用，B 不是从容器获取 ❌
// 每次调用 b() 都会创建新的 B，不经过单例检查
```

> **一句话总结：** @Configuration 用 CGLib 代理保证 @Bean 方法调用的单例，@Component 没有。

### 7.3 @Lazy 延迟加载原理

```java
@Component
@Lazy
public class LazyBean {
    public LazyBean() {
        System.out.println("LazyBean 初始化...");
    }
}

// 原理：
// 1. 容器启动时不会立即创建 LazyBean
// 2. 生成一个懒加载代理对象占位
// 3. 第一次使用时，代理对象触发真实 Bean 的创建
// 
// 源码：ContextAnnotationAutowireCandidateResolver 中判断
// if (lazy) {
//     return new LazyResolutionProxyFactoryBean(...);
// }
```

### 7.4 ApplicationListener / @EventListener 事件驱动

```java
// 定义事件
public class OrderCreatedEvent extends ApplicationEvent {
    private final Long orderId;
    
    public OrderCreatedEvent(Object source, Long orderId) {
        super(source);
        this.orderId = orderId;
    }
    public Long getOrderId() { return orderId; }
}

// 方式一：实现 ApplicationListener
@Component
public class OrderEventListener implements ApplicationListener<OrderCreatedEvent> {
    @Override
    public void onApplicationEvent(OrderCreatedEvent event) {
        System.out.println("收到订单创建事件：" + event.getOrderId());
    }
}

// 方式二：@EventListener 注解（推荐）
@Component
public class OrderEventListener {
    
    @EventListener
    public void handleOrderCreated(OrderCreatedEvent event) {
        System.out.println("收到订单创建事件：" + event.getOrderId());
    }
    
    @EventListener
    @Async // 异步处理
    public void sendSms(OrderCreatedEvent event) {
        System.out.println("发送短信通知：" + event.getOrderId());
    }
    
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void afterCommit(OrderCreatedEvent event) {
        System.out.println("事务提交后执行：" + event.getOrderId());
    }
}

// 发布事件
@Service
public class OrderService {
    @Autowired
    private ApplicationEventPublisher publisher;
    
    public void createOrder() {
        // 业务逻辑...
        publisher.publishEvent(new OrderCreatedEvent(this, 1001L));
    }
}
```

### 7.5 Spring 启动流程简说

```
Spring 启动流程（简化版）：

1. Web 容器（Tomcat）启动
2. 调用 SpringApplication.run()
3. 创建 ApplicationContext
   └─› AnnotationConfigServletWebServerApplicationContext
4. 调用 AbstractApplicationContext.refresh()
   ├─› prepareRefresh()          // 准备刷新环境
   ├─› obtainFreshBeanFactory()   // 获取 BeanFactory
   ├─› prepareBeanFactory()       // 准备 BeanFactory（注册特殊 Bean）
   ├─› postProcessBeanFactory()   // 子类扩展
   ├─› invokeBeanFactoryPostProcessors()   // ⭐ 执行 BeanFactoryPostProcessor
   │   └─› ConfigurationClassPostProcessor → 解析 @Configuration
   │   └─› 扫描 @ComponentScan 包 → 注册 BeanDefinition
   │   └─› 处理 @Import → AutoConfigurationImportSelector → 自动配置
   ├─› registerBeanPostProcessors()        // 注册 BeanPostProcessor
   ├─› initMessageSource()        // 国际化
   ├─› initApplicationEventMulticaster()   // 事件广播器
   ├─› onRefresh()                // 初始化 Web 服务器（Tomcat）
   ├─› registerListeners()        // 注册监听器
   ├─› finishBeanFactoryInitialization()   // ⭐ 初始化所有单例 Bean
   │   └─› preInstantiateSingletons()
   │       └─› 逐个 getBean() → doGetBean → createBean → doCreateBean
   ├─› finishRefresh()            // 完成刷新，发布 ContextRefreshedEvent
   └─› 启动完成 ✅
```

### 7.6 附加高频面试题

**Q：Spring 中的 Bean 是线程安全的吗？**

A：Spring 默认单例 Bean **不保证线程安全**。如果 Bean 有可变状态（实例变量），需要自行处理并发问题。解决方案：
- 使用无状态 Bean（推荐，大部分 Service 无状态）
- 使用 ThreadLocal（如 RequestContextHolder）
- 改为 prototype scope
- 加同步锁

**Q：Spring 如何处理循环依赖的 AOP 问题？**

A：循环依赖场景下，如果 A 需要 AOP 增强，通过三级缓存中的 `ObjectFactory` 提前执行 `getEarlyBeanReference()` 生成代理对象存入二级缓存，后续其他 Bean 拿到的就是 AOP 代理，而不是原始对象。

**Q：Spring 事务在什么情况下会回滚？**

A：
1. 抛出 `RuntimeException` 或 `Error`（默认）
2. 抛出的异常在 `rollbackFor` 指定范围内
3. 事务方法被代理调用
4. 数据库支持事务（InnoDB）且连接正常

**Q：@Transactional 注解能不能加在 private 方法上？**

A：不能。AOP 代理（无论是 JDK 动态代理还是 CGLib）都无法拦截 private 方法，因为子类/代理类无法重写 private 方法。`@Transactional` 只对 public 方法生效。

---

## 总结

本文从面试跳槽的角度，系统梳理了 Spring 框架的核心原理：

1. **IoC/DI**：控制反转思想、三种配置方式、自动装配模式
2. **Bean 生命周期**：11 步流程，BeanPostProcessor 扩展点
3. **循环依赖**：三级缓存机制，为什么构造器循环依赖无法解决
4. **AOP 原理**：JDK vs CGLib、通知执行顺序
5. **事务**：传播行为、隔离级别、失效场景、同类调用问题
6. **自动配置**：@SpringBootApplication、AutoConfigurationImportSelector、@Conditional
7. **高频面试题**：设计模式、@Configuration vs @Component、事件驱动、启动流程

掌握这些原理，面试中碰到 Spring 相关问题就能游刃有余。面试官问到的每一个点背后都有对应的源码支撑，建议结合 Spring Framework 源码深入理解。

> **写在最后：** 原理懂了，源码看了，剩下的就是多总结、多练习。Spring 框架本身就是在不断演进的，保持学习和关注最新版本的变化，也是技术成长的一部分。

加油，Offer 在路上！🚀
