---
title: 【Spring 源码】Spring AOP 切点（Pointcut）匹配机制深度解析：从表达式解析到运行时匹配
date: 2026-09-23 08:00:00
tags:
  - Spring
  - AOP
  - 源码
categories:
  - Spring
  - Spring全家桶
author: 东哥
---

# 【Spring 源码】Spring AOP 切点（Pointcut）匹配机制深度解析：从表达式解析到运行时匹配

## 面试官：你写了个 `@Around("execution(* com.foo.service.*.*(..))")`，Spring 是怎么找到该拦截哪些方法的？

绝大多数人答「AOP 就是动态代理」，但这个问题问的不是代理，而是**切点匹配**。Spring AOP 的完整链路是「解析切点表达式 → 为每个 Bean 的每个方法做匹配 → 匹配上的组装成 Advisor → 创建代理」。中间的匹配环节才是性能与正确性的核心。

这篇文章专门讲 Pointcut 的匹配机制，这是 Spring AOP 里最少被讲透的一块。

## 一、Pointcut 的接口契约

Spring AOP 的 `Pointcut` 定义极其简洁（`org.springframework.aop.Pointcut`）：

```java
public interface Pointcut {
    ClassFilter getClassFilter();
    MethodMatcher getMethodMatcher();
    Pointcut TRUE = TruePointcut.INSTANCE;
}
```

**两条信息就够描述一个切点：**

- `ClassFilter`：这个类要不要考虑？
- `MethodMatcher`：这个类里的这个方法要不要拦截？

`MethodMatcher` 才是重头戏：

```java
public interface MethodMatcher {
    boolean matches(Method method, Class<?> targetClass);                    // 静态匹配

    boolean isRuntime();                                                     // 是否需要每次调用都判断

    boolean matches(Method method, Class<?> targetClass, Object... args);    // 动态匹配
}
```

**`isRuntime()` 是理解一切的钥匙。** 它区分了两类切点：

| 类型 | `isRuntime()` | 匹配时机 | 能否缓存 | 典型表达式 |
| --- | --- | --- | --- | --- |
| 静态切点 | `false` | 代理创建时，每个方法**只匹配一次** | ✅ 可缓存 | `execution(...)`、`@annotation(...)` |
| 动态切点 | `true` | **每次方法调用**都要匹配（因为要看实参） | ❌ 不可缓存 | `args(...)` 且绑定参数、`@args(...)` |

性能差距是数量级的：静态切点在 Bean 初始化阶段完成全部匹配，运行期零成本；动态切点在高频调用路径上每次都要跑一遍匹配逻辑。

> **优化经验：能用 `execution` 表达的，绝不用 `args` 绑定。** 如果确实需要参数，优先用 `@Around` 方法签名直接声明参数（`ProceedingJoinPoint.getArgs()`），而不是把它写进切点表达式。

## 二、表达式是怎么解析的：Parser + ShadowMatch

`execution(* com.foo.service.*.*(..))` 这种字符串，Spring 自己**不解析**，而是委托给 AspectJ 的 `PointcutParser`（来自 `aspectjweaver` 依赖）。

```java
public class AspectJExpressionPointcut
        implements Pointcut, ClassFilter, MethodMatcher, IntroductionAwareMethodMatcher {

    private String expression;
    private PointcutExpression pointcutExpression;   // ← AspectJ 的 PointcutExpression
    private ShadowMatch shadowMatch;                 // ← 关键：匹配结果缓存

    @Override
    public boolean matches(Method method, Class<?> targetClass) {
        return matches(method, targetClass, false, null);
    }

    public boolean matches(Method method, Class<?> targetClass,
                           boolean hasIntroductions, Object... args) {
        if (this.pointcutExpression == null) {
            obtainPointcutExpression();      // 懒解析，解析结果缓存在实例字段
        }
        ShadowMatch shadowMatch = getShadowMatch(method, targetClass);
        if (shadowMatch.alwaysMatches()) return true;
        if (shadowMatch.neverMatches()) return false;
        // 走到这里说明是 "maybe"：需要看运行时参数或 introduction
        if (hasIntroductions || !shadowMatch.maybeMatches()) {
            return false;
        }
        // …
    }
}
```

几个关键类：

- **`PointcutParser`**：AspectJ 提供，负责把表达式字符串编译成 `PointcutExpression` 对象。**解析成本很高（涉及完整语法分析），所以必须缓存。**
- **`ShadowMatch`**：AspectJ 对「这个方法是否命中」的判定结果，是一个**三态**：
  - `alwaysMatches()` —— 静态可判定命中
  - `neverMatches()` —— 静态可判定不命中
  - `maybeMatches()` —— 静态无法判定，需要运行时参数（比如 `args(String)`）
- **`ShadowMatch` 缓存在 `AspectJExpressionPointcut.shadowMatchCache` 里**，key 是 `(Method, Class)`，用 `ConcurrentHashMap` 存。这是 Spring AOP 性能的关键缓存。

### 三态判定为什么必要？

看一个动态切点：

```java
@Before("execution(* *(..)) && args(name, ..)")
public void logName(String name) { ... }
```

`args(name, ..)` 意味着「第一个参数必须是 String」。**光看方法签名定不了**——方法可能是 `void f(Object o)`，实际传进来的是 String 才该被拦。所以 `ShadowMatch` 返回 `maybeMatches()`，运行时必须拿真实参数再匹配一次。

而 `execution(* com.foo.service.*.*(..))` 只看「声明类型 + 方法名 + 参数个数」，编译期信息就够，所以是 `alwaysMatches()`。

## 三、Advisor 的组装：从注解到可执行切面

切点只是「哪里拦」，真正执行逻辑的是 `Advisor`。完整链路：

```
@EnableAspectJAutoProxy
  → 注册 AnnotationAwareAspectJAutoProxyCreator（一个 BeanPostProcessor）
  → 每个 Bean 初始化后，postProcessAfterInitialization 触发
  → AnnotationAwareAspectJAutoProxyCreator.findCandidateAdvisors()
      → BeanFactoryAspectJAdvisorsBuilder.buildAspectJAdvisors()
          → 扫描所有 @Aspect Bean
          → ReflectiveAspectJAdvisorFactory.getAdvisors(aspectInstanceFactory)
              → 逐个方法找 @Around/@Before/@After/@AfterReturning/@AfterThrowing
              → getPointcut(method)  ← 解析 @Pointcut/@Around 里的表达式
              → new InstantiationModelAwarePointcutAdvisorImpl(...)
  → findAdvisorsThatCanApply(candidateAdvisors, beanClass, beanName)
      → AopUtils.canApply(advisor, targetClass)
          → advisor.getPointcut().getClassFilter().matches(targetClass)
          → 遍历 targetClass 所有方法，pointcut.getMethodMatcher().matches(...)
  → 匹配到 → ProxyFactory 创建代理
```

注意最后一步：`AopUtils.canApply()` 会**遍历目标类的所有方法**（包括父类方法，`ClassUtils.getAllDeclaredMethods`）逐个匹配。这是 Bean 初始化阶段的主要开销来源，也是「切点表达式写得太宽会拖慢启动」的原因。

### 缓存三层结构

| 缓存 | 位置 | 粒度 |
| --- | --- | --- |
| `shadowMatchCache` | `AspectJExpressionPointcut` | `(Method, Class)` → ShadowMatch |
| `advisorsCache` | `BeanFactoryAspectJAdvisorsBuilder` | `@Aspect` Bean 名 → `List<Advisor>` |
| `advisorCache` | `AnnotationAwareAspectJAutoProxyCreator` | 已被 `AspectJAdvisorFactory` 内部使用 |

理解这三层缓存，就能解释很多「为什么重启后第一批请求慢、后面就快了」的现象——预热而已。

## 四、各种 Pointcut 实现对比

Spring AOP 内置了大量 Pointcut 实现，选型时别只知道 `execution`：

| 实现类 | 匹配依据 | 静态/动态 |
| --- | --- | --- |
| `AspectJExpressionPointcut` | AspectJ 表达式 | 视表达式而定 |
| `AnnotationMatchingPointcut` | 类/方法上是否有某注解 | 静态 |
| `AnnotationClassFilter` / `AnnotationMethodMatcher` | 注解检查（可配 checkInherited） | 静态 |
| `NameMatchMethodPointcut` | 方法名匹配（支持 `*` 通配） | 静态 |
| `MethodNameMatchPointcut` | 方法名集合精确匹配 | 静态 |
| `JdkRegexpMethodPointcut` | 正则匹配方法全名 | 静态 |
| `ComposablePointcut` | 多个切点的 `union`/`intersection` | 视组合而定 |
| `ControlFlowPointcut` | 是否由某个类/方法调用而来 | **动态（极慢，仅调试用）** |
| `TruePointcut` | 匹配所有 | 静态 |

`ControlFlowPointcut` 特别值得一提：

```java
Pointcut pc = new ControlFlowPointcut(Caller.class, "invoke");
```

它通过**遍历当前线程栈**判断调用来自哪里——每次调用都要遍历调用栈，性能极差。Spring 官方文档明确说它「主要用于调试」。**面试里提到这个，能体现你读过源码而不是只背结论。**

## 五、`bean()` 表达式与自定义 PointcutSource

Spring 相对 AspectJ 扩展了一个特有指示符 `bean()`，只能用于 `@Aspect` 里（因为需要 `BeanFactory` 上下文）：

```java
@Around("bean(userService) && execution(* *(..))")
public Object around(ProceedingJoinPoint pjp) throws Throwable { ... }
```

实现类是 `BeanFactoryAspectJExpressionPointcut`，它把 `bean(...)` 转成基于 Bean 名的匹配。局限是**不支持 `&&`/`||` 组合里的部分场景**，且 `bean()` 只对 Spring 管理的 Bean 生效（代理过的对象名可能与原始 bean name 不同）。

如果内置的实现都不够用，可以自己实现 `Pointcut`：

```java
public class AuditPointcut extends StaticMethodMatcherPointcut {
    private final Set<String> auditedMethods;

    public AuditPointcut(Set<String> methods) { this.auditedMethods = methods; }

    @Override
    public boolean matches(Method method, Class<?> targetClass) {
        // 只匹配 @Auditable 注解的方法（含继承的注解）
        return AnnotatedElementUtils.hasAnnotation(method, Auditable.class)
                || auditedMethods.contains(method.getName());
    }

    @Override
    public ClassFilter getClassFilter() {
        return clazz -> !clazz.isInterface() && clazz.getName().startsWith("com.foo");
    }
}
```

注意继承 `StaticMethodMatcherPointcut`（而不是自己实现 `MethodMatcher`），它会自动把 `isRuntime()` 实现为 `false`，省掉动态匹配开销。

## 六、性能与踩坑清单

**坑 1：表达式过宽导致启动变慢 + 代理膨胀。**
`execution(* *(..))` 会匹配**所有 Bean 的所有方法**，包括 `toString`、Controller、甚至 Spring 自己的基础设施 Bean。后果：大量 Bean 被代理（额外的 `$Proxy` 类生成、内存占用）、启动时间显著增加、某些 `final` 方法报错。

```java
// ❌ 
@Around("execution(* *(..))")
// ✅ 收窄到包 + 注解
@Around("execution(* com.foo.service..*(..)) && @annotation(com.foo.Trace)")
```

**坑 2：`@annotation` 用在接口方法上匹配不到。**
如果注解标注在实现类方法上，接口方法匹配不到（因为代理按接口匹配）。用 `@within` + 类级注解，或者确保注解在接口上。

**坑 3：动态切点在高 QPS 下的隐藏开销。**
`args(...)` 绑定的切点每次调用都要匹配 + 参数装箱。**用 Arthas `trace` 或 JFR 采样时会看到 `AspectJExpressionPointcut.matches` 占据可观 CPU。** 解决办法是改成静态切点，参数从 `ProceedingJoinPoint` 取。

**坑 4：同类内部方法调用不走代理。**
`this.foo()` 调用的是原始对象，不经过代理链，切点自然不生效。这也是 `@Transactional` 失效的同一个根因。解决：注入自身代理、`AopContext.currentProxy()`、或拆类。

**坑 5：`static`/`final` 方法无法被 CGLIB 代理。**
`final` 方法不能覆写，CGLIB 直接放弃；`static` 方法本来就不参与动态分派。这类方法上的切点会被静默忽略——**如果切面「没有生效」，先检查是不是 `final`。**

## 七、面试常见追问

**追问 1：Spring AOP 和 AspectJ 编译期织入的区别？**
Spring AOP 是**运行时代理**，只能拦截 Spring 容器管理的 Bean 的**方法调用**（不能拦字段访问、构造器、同类内部调用、private 方法）；AspectJ 是**字节码织入**（编译期/编译后/加载期），能力完整、无代理开销，但需要特殊编译插件或 JVM agent，接入成本高。现代 Spring Boot 里如果需要 AspectJ，可以通过 `spring-boot-starter-aop` + `@EnableLoadTimeWeaving` 或 `-javaagent:aspectjweaver.jar` 实现。

**追问 2：多个切面的执行顺序怎么控制？**
实现 `Ordered` 接口或加 `@Order`。默认顺序是**未指定的**，不要依赖声明顺序。`@Around` 是「外层先入后出」（洋葱模型），`@Before` 在 `@Around` 之前或之后取决于 Order。

**追问 3：为什么 `@Around` 不调用 `proceed()` 会阻断目标方法？**
因为代理链的后续环节（包括目标方法调用）都在 `proceed()` 里。不调 `proceed()` 就等于短路了整条链。这也是「缓存切面」能返回缓存值而不执行原方法的原理。

**追问 4：`ShadowMatch` 缓存会不会导致内存泄漏？**
理论上会（key 持有 `Class` 和 `Method` 引用）。但 `AspectJExpressionPointcut` 的生命周期与 `@Aspect` Bean 绑定，而 Bean 本身持有目标类的引用，所以不构成额外的泄漏源。真正需要注意的是**热部署场景**：老的应用类加载器无法回收，会导致 Metaspace 泄漏——这是另一个话题了。

**追问 5：怎么判断一个 Bean 被哪些切面代理了？**
打开 `logging.level.org.springframework.aop=DEBUG`，日志里会输出每个 Bean 的适用 Advisor 列表。或者用 Arthas 看 Bean 的实际类型（`$Proxy` / `$$EnhancerBySpringCGLIB`）。最实用的还是 `AopUtils.canApply` 的逻辑自己复现一遍。

## 八、小结

Spring AOP 切点匹配的核心就三句话：

1. **Pointcut = ClassFilter + MethodMatcher**，`isRuntime()` 决定静态还是动态匹配
2. **表达式交给 AspectJ 解析，结果用 `ShadowMatch` 三态 + 多层缓存兜住性能**
3. **静态切点（`execution`/`@annotation`）优先，动态切点（`args` 绑定）慎用**

把这三句讲清楚，再补上「同类调用不生效」「`final` 方法不生效」「表达式过宽拖慢启动」三个坑，Spring AOP 这块就没有死角了。
