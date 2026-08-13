---
title: 【Spring 源码】Spring AOP 源码深度解析：从 @EnableAspectJAutoProxy 到动态代理创建全流程
date: 2026-08-13 08:00:00
tags:
  - Spring
  - AOP
  - 源码
  - 面试
categories:
  - Spring
  - 框架源码
author: 东哥
---

# 【Spring 源码】Spring AOP 源码深度解析：从 @EnableAspectJAutoProxy 到动态代理创建全流程

## 面试官：Spring AOP 是怎么工作的？代理是什么时候、怎么创建出来的？

很多同学背过 AOP 的概念：切面、切点、通知、织入……但一问到「代理是谁创建的？创建流程是什么？JDK 动态代理和 CGLIB 是怎么选的？」就卡壳了。

这篇文章我们就从 `@EnableAspectJAutoProxy` 这个注解出发，沿着源码把 AOP 代理的**完整创建链路**走一遍，最后再回答几个高频面试追问。

## 一、AOP 的核心概念快速回顾

| 概念 | 说明 | 对应 Spring 接口/注解 |
| --- | --- | --- |
| 切面（Aspect） | 横切逻辑 + 切点的集合 | `@Aspect` 标注的类 |
| 切点（Pointcut） | 匹配哪些方法的表达式 | `@Pointcut` / `AspectJExpressionPointcut` |
| 通知（Advice） | 具体增强逻辑 | `@Before` / `@After` / `@Around` 等 |
| 连接点（JoinPoint） | 可以被拦截的方法调用点 | `MethodInvocation` |
| 织入（Weaving） | 把增强逻辑织入目标方法 | 运行时动态代理（Spring 采用） |

Spring AOP 的核心思想一句话：**通过动态代理生成目标 Bean 的代理对象，在代理对象的方法调用前后插入增强逻辑**。

## 二、入口：@EnableAspectJAutoProxy 干了什么

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Import(AspectJAutoProxyRegistrar.class)
public @interface EnableAspectJAutoProxy {
    boolean proxyTargetClass() default false;  // 是否强制使用 CGLIB
    boolean exposeProxy() default false;       // 是否暴露代理对象到 ThreadLocal
}
```

关键在 `@Import(AspectJAutoProxyRegistrar.class)`，它向容器注册了一个 **`AnnotationAwareAspectJAutoProxyCreator`** 的 BeanDefinition：

```java
class AspectJAutoProxyRegistrar implements ImportBeanDefinitionRegistrar {
    @Override
    public void registerBeanDefinitions(...) {
        // 注册 AnnotationAwareAspectJAutoProxyCreator
        AopConfigUtils.registerAspectJAnnotationAutoProxyCreatorIfNecessary(registry);
        // 处理 proxyTargetClass / exposeProxy 属性
        ...
    }
}
```

这个 Creator 是一个 **BeanPostProcessor**（更准确说是 `InstantiationAwareBeanPostProcessor` + `SmartInstantiationAwareBeanPostProcessor`），它会被注册进容器的 `beanPostProcessors` 列表。**每一个 Bean 在创建时都会经过它**——这就是 AOP 能对所有 Bean 生效的根本原因。

## 三、核心类继承体系

```
AnnotationAwareAspectJAutoProxyCreator
  └── AspectJAwareAdvisorAutoProxyCreator
        └── AbstractAdvisorAutoProxyCreator
              └── AbstractAutoProxyCreator        // 核心：wrapIfNecessary、createProxy
                    └── ProxyProcessorSupport
```

记忆技巧：**AspectJ（注解切面支持）→ Advisor（适配器）→ 自动代理（通用代理逻辑）**。

## 四、代理创建主链路：wrapIfNecessary

Bean 创建流程走完属性填充后，会调用初始化后处理器：

```
AbstractAutowireCapableBeanFactory.initializeBean()
  └── applyBeanPostProcessorsAfterInitialization()
        └── AbstractAutoProxyCreator.postProcessAfterInitialization()
              └── wrapIfNecessary(bean, beanName)
                    └── getAdvicesAndAdvisorsForBean()   // ① 找增强器
                    └── createProxy(...)                  // ② 创建代理
```

核心代码（简化）：

```java
protected Object wrapIfNecessary(Object bean, String beanName, Object cacheKey) {
    // 1. 已经处理过 / 无需代理的直接返回
    if (this.targetSourcedBeans.contains(cacheKey)) return bean;
    if (this.advisedBeans.containsKey(cacheKey) && !this.advisedBeans.get(cacheKey)) return bean;

    // 2. 判断是否为基础设施类（Advisor、Advice、AopInfrastructureBean 等）
    if (isInfrastructureClass(bean.getClass()) || shouldSkip(bean.getClass(), beanName)) {
        this.advisedBeans.put(cacheKey, Boolean.FALSE);
        return bean;
    }

    // 3. 核心：找到能匹配这个 Bean 的所有 Advisor（增强器）
    Object[] specificInterceptors = getAdvicesAndAdvisorsForBean(bean.getClass(), beanName, null);

    if (specificInterceptors != DO_NOT_PROXY) {
        this.advisedBeans.put(cacheKey, Boolean.TRUE);
        // 4. 创建代理对象
        Object proxy = createProxy(bean.getClass(), beanName, specificInterceptors, new SingletonTargetSource(bean));
        this.proxyTypes.put(cacheKey, proxy.getClass());
        return proxy;
    }
    this.advisedBeans.put(cacheKey, Boolean.FALSE);
    return bean;  // 没有匹配的增强器，返回原始 Bean
}
```

## 五、第一步：找到增强器（Advisor）

`AbstractAdvisorAutoProxyCreator.getAdvicesAndAdvisorsForBean` 内部调用 `findEligibleAdvisors`：

```java
protected List<Advisor> findEligibleAdvisors(Class<?> beanClass, String beanName) {
    // 1. 找出容器中所有 Advisor（候选增强器）
    List<Advisor> candidateAdvisors = findCandidateAdvisors();
    // 2. 用切点表达式逐个匹配，只保留能命中当前 Bean 的 Advisor
    List<Advisor> eligibleAdvisors = findAdvisorsThatCanApply(candidateAdvisors, beanClass, beanName);
    // 3. 扩展：把 ExposeInvocationInterceptor 加在链首（用于 AopContext.currentProxy()）
    extendAdvisors(eligibleAdvisors);
    ...
}
```

`findCandidateAdvisors` 做了两件事：

1. **从容器中找 Advisor 类型的 Bean**：`BeanFactoryAdvisorRetrievalHelper.findAdvisorBeans()`；
2. **解析所有 @Aspect 注解的类**：`AnnotationAwareAspectJAdvisorBuilder.buildAspectJAdvisors()`，它会把 `@Aspect` 类中的每个通知方法（`@Before`、`@Around` 等）包装成 `InstantiationModelAwarePointcutAdvisor`，并解析 `@Pointcut` 表达式。

注意：`findAdvisorBeans` 是**按 Bean 名排序**的，顺序决定了通知的执行顺序，这也是为什么多个切面之间顺序有讲究。

## 六、切点匹配：AspectJExpressionPointcut

匹配动作发生在 `AopUtils.canApply` / `AspectJExpressionPointcut.matches`：

```java
// 典型切点表达式
@Pointcut("execution(* com.example.service.*.*(..))")
public void serviceLayer() {}
```

`AspectJExpressionPointcut` 内部用 AspectJ 的 `PointcutExpression` 做匹配，匹配目标包括：

- 类级别匹配：`matches(Class<?> targetClass)`；
- 方法级别匹配：`matches(Method method, Class<?> targetClass)`，会先做**快速匹配（快速失败）**，不通过则再走完整 AspectJ 匹配（`maybeGetFallbackPointcutExpression`），最后 `ShadowMatch` 判断。

匹配不中 → 该 Advisor 被丢弃 → 这个 Bean 不生成代理（返回 `DO_NOT_PROXY`）。

## 七、第二步：创建代理对象

```java
protected Object createProxy(Class<?> beanClass, String beanName,
        Object[] specificInterceptors, TargetSource targetSource) {

    ProxyFactory proxyFactory = new ProxyFactory();
    proxyFactory.copyFrom(this);  // 继承全局配置（proxyTargetClass 等）

    // 如果目标类没有实现接口 或 强制 CGLIB，则使用 CGLIB
    if (!proxyFactory.isProxyTargetClass()) {
        if (shouldProxyTargetClass(beanClass, beanName)) {
            proxyFactory.setProxyTargetClass(true);
        } else {
            evaluateProxyInterfaces(beanClass, proxyFactory);  // 收集目标类实现的接口
        }
    }

    // 把 Advisor 数组包装成 Advisor[] 并设置到 ProxyFactory
    Advisor[] advisors = buildAdvisors(beanName, specificInterceptors);
    proxyFactory.addAdvisors(advisors);
    proxyFactory.setTargetSource(targetSource);
    customizeProxyFactory(proxyFactory);

    return proxyFactory.getProxy(classLoader);  // 生成代理
}
```

`ProxyFactory.getProxy` 最终走到 `DefaultAopProxyFactory.createAopProxy`——**JDK 还是 CGLIB 的选择就在这一行**：

```java
public AopProxy createAopProxy(AdvisedSupport config) throws AopConfigException {
    // 满足以下任一条件 → CGLIB：
    // 1. proxyTargetClass == true（强制 CGLIB）
    // 2. 目标类没有实现任何接口
    if (config.isOptimize() || config.isProxyTargetClass() || hasNoUserSuppliedProxyInterfaces(config)) {
        Class<?> targetClass = config.getTargetClass();
        return new CglibProxyFactory(config);
    } else {
        return new JdkDynamicAopProxy(config);  // 默认：JDK 动态代理
    }
}
```

### JDK 动态代理 vs CGLIB

| 维度 | JDK 动态代理 | CGLIB |
| --- | --- | --- |
| 原理 | 基于接口，`Proxy.newProxyInstance` 生成实现类 | 基于继承，ASM 生成目标类的子类 |
| 要求 | 目标必须实现接口 | 目标类不能是 final，方法不能是 final |
| 性能 | 创建快，调用稍慢（反射） | 创建慢（生成字节码），调用快（直接方法调用） |
| Spring Boot 2.x 默认 | — | 默认使用 CGLIB（`spring.aop.proxy-target-class=true`） |

> **Spring Boot 2.x 起默认 `proxyTargetClass=true`**，即默认 CGLIB。原因：很多类没有接口；CGLIB 性能更好；且 Spring 官方推荐。

## 八、代理对象的方法调用：拦截器链

### 8.1 JdkDynamicAopProxy.invoke

```java
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    // 1. equals / hashCode / toString 直接调用（不进拦截器链）
    // 2. 从 AdvisedSupport 中取出拦截器链
    List<Object> chain = this.advised.getInterceptorsAndDynamicInterceptionAdvice(method, targetClass);

    if (chain.isEmpty()) {
        // 无增强，直接反射调用目标方法
        return AopUtils.invokeJoinpointUsingReflection(target, method, args);
    } else {
        // 3. 构造 MethodInvocation（ReflectiveMethodInvocation），链式调用
        invocation = new ReflectiveMethodInvocation(proxy, target, method, args, targetClass, chain);
        return invocation.proceed();
    }
}
```

### 8.2 拦截器链的组成

`DefaultAdvisorAdapterRegistry` 会把各种 Advice 适配成 `MethodInterceptor`：

| 通知类型 | 适配成的拦截器 |
| --- | --- |
| `@Before` | `MethodBeforeAdviceInterceptor` |
| `@AfterReturning` | `AfterReturningAdviceInterceptor` |
| `@AfterThrowing` | `AspectJAfterThrowingAdvice` |
| `@After` | `AspectJAfterAdvice` |
| `@Around` | `AspectJAroundAdvice` |

`ReflectiveMethodInvocation.proceed()` 的核心逻辑：

```java
public Object proceed() throws Throwable {
    if (this.currentInterceptorIndex == this.interceptorsAndDynamicMethodMatchers.size() - 1) {
        // 所有拦截器执行完毕，调用真正的目标方法
        return invokeJoinpoint();
    }
    Object interceptorOrInterceptionAdvice = this.interceptorsAndDynamicMethodMatchers.get(++this.currentInterceptorIndex);
    return ((MethodInterceptor) interceptorOrInterceptionAdvice).invoke(this);
}
```

这就是经典的**责任链模式**：每个拦截器调用 `mi.proceed()` 把调用传递给下一个，直到最后调用目标方法。`@Around` 通知就是在 `proceed()` 前后各写一段逻辑。

### 8.3 通知执行顺序（重要！）

- **正常执行**：`@Around`（前）→ `@Before` → 目标方法 → `@AfterReturning` → `@Around`（后）→ `@After`
- **异常执行**：`@Around`（前）→ `@Before` → 目标方法抛异常 → `@AfterThrowing` → `@After`

其中 `ExposeInvocationInterceptor` 永远在链首，它把当前 `MethodInvocation` 放到 ThreadLocal 中，这是 `AopContext.currentProxy()` 能拿到代理对象的原因。

## 九、实战：一个完整切面的执行过程

写一个实际切面，把上面的源码链路串起来：

```java
@Aspect
@Component
public class LogAspect {

    @Pointcut("execution(* com.example.service.UserService.*(..))")
    public void userServicePointcut() {}

    @Before("userServicePointcut()")
    public void before(JoinPoint joinPoint) {
        System.out.println("[before] 方法：" + joinPoint.getSignature().getName());
    }

    @Around("userServicePointcut()")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        Object result = pjp.proceed();   // 调用链继续往下走
        System.out.println("[around] 耗时：" + (System.currentTimeMillis() - start) + "ms");
        return result;
    }

    @AfterReturning(pointcut = "userServicePointcut()", returning = "result")
    public void afterReturning(Object result) {
        System.out.println("[afterReturning] 结果：" + result);
    }

    @AfterThrowing(pointcut = "userServicePointcut()", throwing = "ex")
    public void afterThrowing(Throwable ex) {
        System.out.println("[afterThrowing] 异常：" + ex.getMessage());
    }
}
```

调用 `userService.getById(1L)` 时，实际执行顺序：

```
ExposeInvocationInterceptor.proceed()
  → MethodBeforeAdviceInterceptor（@Before 输出 [before]）
  → AspectJAroundAdvice（@Around 进入，记录开始时间）
  → 目标方法 getById() 真正执行（JDK 反射 / CGLIB 直接调用）
  → AfterReturningAdviceInterceptor（@AfterReturning 输出结果）
  → @Around 收尾（输出耗时）
```

### 多个切面时如何控制顺序？

Spring 中切面默认无序，需要时用两种方式控制：

1. **`@Order(n)` 注解**：数字越小优先级越高，`@Around` 前置逻辑先执行；
2. **`Ordered` 接口**：实现 `getOrder()` 返回顺序值。

> 注意：`@Order` 值越小，`@Before` 越先执行，但 `@After` 是**后进先出**（栈式），所以顺序号小的切面的 `@After` 最后执行——类似拦截器链的洋葱模型。

### AOP 与 @Transactional / @Async 的关系

`@Transactional`、`@Async` 底层也是通过 AOP（各自的 Advisor）实现的：

- `@Transactional` → `BeanFactoryTransactionAttributeSourceAdvisor` → `TransactionInterceptor`（增强器链中的一环）；
- `@Async` → `AsyncAnnotationBeanPostProcessor` 生成代理。

所以它们是**叠加在同一代理对象上的多条拦截器链**，顺序由各自 Advisor 的 order 决定（事务默认 `Ordered.LOWEST_PRECEDENCE` 附近，`@Async` 也是低优先级）。这也是为什么「事务方法内部调用另一个 @Transactional 方法」不会开启新事务——自调用根本没经过代理。

## 十、面试高频追问

### 追问 1：为什么 Spring 自调用（this.xxx()）AOP 会失效？

因为代理对象只拦截**通过代理对象发起**的调用。类内部 `this.method()` 直接调用的是原始对象的方法，根本没走代理。`@Transactional`、`@Async` 失效的经典原因之一。

**解决方案：**

```java
// 方案一：注入自身
@Autowired
private UserService self;   // 注入的是代理对象
self.update();

// 方案二：使用 AopContext（需要 exposeProxy = true）
((UserService) AopContext.currentProxy()).update();

// 方案三：把增强逻辑拆到另一个 Bean 中调用（最推荐）
```

### 追问 2：AOP 与循环依赖有什么关系？

循环依赖 + AOP 时，三级缓存里存的是**工厂对象（ObjectFactory）**，通过它提前拿到的是**经过 AOP 的早期代理引用**，保证最终注入的代理对象是同一个。所以：

- 构造器注入的循环依赖无法解决（对象都没创建出来）；
- 而 setter/字段注入的循环依赖，配合三级缓存 + AOP 可以解决，且拿到的是代理对象。

### 追问 3：Spring AOP 与 AspectJ 的区别？

| 维度 | Spring AOP | AspectJ |
| --- | --- | --- |
| 织入方式 | 运行时动态代理 | 编译期/加载期织入（字节码增强） |
| 连接点 | 仅支持方法执行 | 支持构造器、字段、方法等 |
| 性能 | 有代理调用开销 | 无运行时开销 |
| 使用成本 | 与 Spring 无缝集成 | 需要额外编译插件 |

Spring 只是**借用了 AspectJ 的注解和切点表达式语法**，底层实现完全不同。

### 追问 4：代理对象和原始对象在容器里是什么关系？

容器中存的是代理对象（替换了原 Bean）。`getBean()` 返回代理；`targetClass` 通过 `TargetSource` 持有原始对象。这也是为什么 `@Autowired` 注入时类型不匹配偶尔会报错——按接口注入一般没问题，按具体类注入时要小心 CGLIB 子类。

## 十一、总结

```
@EnableAspectJAutoProxy
   → 注册 AnnotationAwareAspectJAutoProxyCreator（BeanPostProcessor）
   → 每个 Bean 初始化后走 wrapIfNecessary
        → findCandidateAdvisors（容器 Advisor + @Aspect 解析）
        → 切点匹配（AspectJExpressionPointcut）
        → createProxy（JDK 动态代理 / CGLIB）
   → 代理对象方法调用走拦截器链（责任链模式）
        → 各种 Advice 适配为 MethodInterceptor
        → proceed() 直到调用真实目标方法
```

记住这条主链路，AOP 面试基本就稳了。再配合 JDK vs CGLIB 选型、自调用失效、循环依赖三个追问，就是完整的 AOP 知识体系。
