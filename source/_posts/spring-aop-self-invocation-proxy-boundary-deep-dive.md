---
title: 【Spring 源码】Spring 代理自调用失效深度解析：@Transactional/@Async/@Cacheable/@Validated 的共同根因
date: 2026-10-23 08:20:00
tags:
  - Java
  - Spring
  - AOP
  - 动态代理
  - 事务
  - 面试
categories:
  - Spring 全家桶
author: 东哥
---

# 【Spring 源码】Spring 代理自调用失效深度解析

## 前言

面试里有一个问题，几乎能把候选人的 Spring 水平一刀切开：

> 「`@Transactional` 什么情况下会失效？」

绝大多数人背得出「同类方法内部调用会失效」。但再追一层：

> 「那 `@Async` 呢？`@Cacheable` 呢？`@Validated` 呢？为什么**都一样**失效？」

答不上来说明只是背了结论，没建立模型。这篇文章要做的事，是把这四个注解失效的**同一个根因**讲透，并给出六种可落地的解法与一套自动化检测手段。

---

## 一、一句话根因：注解不生效，因为方法根本没经过代理

先看最经典的代码：

```java
@Service
public class OrderService {

    @Transactional(rollbackFor = Exception.class)
    public void createOrder(OrderDTO dto) {
        orderMapper.insert(dto);
        this.doSomething();          // ❌ this 调用，事务不生效
    }

    @Transactional(rollbackFor = Exception.class)
    public void doSomething() {
        // 一些需要独立事务的逻辑
    }
}
```

为什么 `this.doSomething()` 没有事务？因为**注解不是魔法，它需要一个「拦截器」在方法执行前后插入逻辑**。这个拦截器挂在代理对象上，而不是原始对象上。

调用链对比：

```
外部调用：caller → proxy.createOrder() → TransactionInterceptor → target.createOrder()
内部调用：caller → proxy.createOrder() → TransactionInterceptor → target.createOrder()
                                                                        ↓
                                                              this.doSomething()  ← 直接调 target，绕过 proxy
```

`this` 指向的是被代理的**目标对象（target）**，不是代理对象。所以在 target 内部调用自己的方法，永远不会经过代理，自然也就不会触发任何 `MethodInterceptor`。

**记住这张图，后面所有注解的失效都是它的推论。**

---

## 二、代理是怎么创建出来的

Spring AOP 的入口是 `AbstractAutoProxyCreator#wrapIfNecessary`（`@EnableTransactionManagement` 通过 `InfrastructureAdvisorAutoProxyCreator` 引入，`@EnableAsync` 通过 `AsyncAnnotationBeanPostProcessor` + `AsyncAnnotationAdvisor` 引入，`@EnableCaching` 通过 `ProxyCachingConfiguration` 引入）。

```java
// AbstractAutoProxyCreator 核心逻辑（简化）
protected Object wrapIfNecessary(Object bean, String beanName, Object cacheKey) {
    // 1. 找出所有能应用到该 bean 的 Advisor
    Object[] specificInterceptors = getAdvicesAndAdvisorsForBean(bean.getClass(), beanName, null);
    if (specificInterceptors == null || specificInterceptors.length == 0) {
        return bean;   // 没有匹配的切面，返回原始对象（不代理）
    }
    // 2. 创建代理
    Object proxy = createProxy(bean.getClass(), beanName, specificInterceptors, new SingletonTargetSource(bean));
    return proxy;
}
```

关键点：**Spring 容器里注册的 Bean 是 `proxy`，`target` 被包在 `SingletonTargetSource` 里**。

代理方式二选一：

| 代理方式 | 触发条件 | 限制 |
|---|---|---|
| JDK 动态代理 | 目标类实现了接口（Spring Boot 2.x 默认） | 只能代理接口方法，`@Autowired` 按类型注入接口 |
| CGLIB | 无接口 / `proxyTargetClass=true`（Boot 2.x 起 `spring.aop.proxy-target-class=true` 为默认） | 不能代理 `final` 类、`final`/`private`/`static` 方法 |

Spring Boot 2.x 之后默认 `proxyTargetClass=true`，也就是**默认走 CGLIB**。这解释了很多人的疑惑：「我明明有接口，为什么还能 `@Autowired` 注入实现类？」——因为容器里放的是 CGLIB 子类。

### 2.1 四个注解的拦截器实现

| 注解 | 生效开关 | 拦截器 | 拦截时机 |
|---|---|---|---|
| `@Transactional` | `@EnableTransactionManagement` | `TransactionInterceptor` | 方法前后，开启/提交/回滚事务 |
| `@Async` | `@EnableAsync` | `AsyncExecutionInterceptor` | 方法调用时丢进线程池，立即返回 `Future`/`void` |
| `@Cacheable` | `@EnableCaching` | `CacheInterceptor` | 方法前查缓存，命中直接返回 |
| `@Validated`（方法级） | `MethodValidationPostProcessor` | `MethodValidationInterceptor` | 方法入参校验，失败抛 `ConstraintViolationException` |
| `@Retryable` | `@EnableRetry` | `RetryOperationsInterceptor` | 方法异常时重试 |
| `@PreAuthorize` | `@EnableMethodSecurity` | `AuthorizationManagerBeforeMethodInterceptor` | 方法前鉴权 |

**六者全部走同一条 `MethodInterceptor` 链，因此全部受同一个自调用限制。** 这就是「统一解释」的价值——不用记六条独立结论。

---

## 三、六种解法，逐个说清适用场景

### 解法 1：拆到另一个 Bean（首选）

```java
@Service
public class OrderService {
    private final InventoryService inventoryService;

    public void createOrder(OrderDTO dto) {
        orderMapper.insert(dto);
        inventoryService.deduct(dto);   // ✅ 跨 Bean 调用，走代理
    }
}

@Service
public class InventoryService {
    @Transactional(rollbackFor = Exception.class)
    public void deduct(OrderDTO dto) { /* ... */ }
}
```

**优点**：结构清晰、无魔法、可测试。
**缺点**：如果两个方法业务上确实高度内聚，拆开会让领域模型变碎。
**适用**：绝大多数场景。这是最推荐的做法。

### 解法 2：自注入（Self-Injection）

```java
@Service
public class OrderService {
    @Lazy
    @Autowired
    private OrderService self;      // 注入的是代理对象

    public void createOrder(OrderDTO dto) {
        orderMapper.insert(dto);
        self.doSomething();          // ✅ 通过代理调用
    }
}
```

⚠️ **必须加 `@Lazy`**，否则会形成循环依赖（Spring Boot 2.6+ 默认禁止循环引用，会启动失败）。

**优点**：不用拆类。
**缺点**：`self` 这个字段有点「脏」；在构造器注入场景下要小心。

### 解法 3：`AopContext.currentProxy()`

```java
@EnableAspectJAutoProxy(exposeProxy = true)   // 必须开启
@Service
public class OrderService {
    public void createOrder(OrderDTO dto) {
        ((OrderService) AopContext.currentProxy()).doSomething();  // ✅
    }
}
```

原理：`exposeProxy=true` 时，`CglibAopProxy` 会把代理对象放进 `ThreadLocal`（`AopContext`）。

**优点**：不改类结构。
**缺点**：① 强耦合 Spring API；② `ThreadLocal` 有轻微开销；③ **异步/多线程场景会失效**（子线程拿不到父线程的 `ThreadLocal`，除非用 `TransmittableThreadLocal`）；④ 未被代理时会抛 `IllegalStateException`。

### 解法 4：编程式事务（最可靠）

```java
@Service
public class OrderService {
    private final TransactionTemplate txTemplate;

    public OrderService(PlatformTransactionManager tm) {
        this.txTemplate = new TransactionTemplate(tm);
        this.txTemplate.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    public void createOrder(OrderDTO dto) {
        orderMapper.insert(dto);
        txTemplate.executeWithoutResult(status -> {
            // ✅ 完全掌控事务边界，与代理无关
            doSomething();
        });
    }
}
```

**优点**：不依赖代理、边界显式、可读性强、单测友好。
**缺点**：代码略啰嗦。
**适用**：**任何对事务边界有精确要求的场景**。我个人在生产代码里优先用它，尤其在「主流程 + 独立事务记录日志」这类模式里。

### 解法 5：`@Async` 场景用独立 Bean 或 `AsyncTaskExecutor`

```java
// ❌ 错误：自调用，仍在调用线程执行
public void submit() {
    this.asyncWork();       // 同步执行！
}

// ✅ 正确：直接操作线程池，语义最清晰
private final AsyncTaskExecutor executor;

public void submit() {
    executor.execute(() -> asyncWork());
}
```

`@Async` 的坑比 `@Transactional` 更隐蔽：**它不报错，只是变成同步执行**，性能问题要等压测才暴露。

### 解法 6：`ObjectProvider` 延迟获取

```java
@Service
public class OrderService {
    private final ObjectProvider<OrderService> selfProvider;

    public void createOrder(OrderDTO dto) {
        selfProvider.getObject().doSomething();  // ✅ 运行期取代理
    }
}
```

**优点**：天然解决循环依赖，不需要 `@Lazy` 注解。
**缺点**：每次 `getObject()` 有轻微开销（单例下就是查 map）。

### 六种解法对比

| 解法 | 侵入性 | 循环依赖风险 | 多线程安全 | 推荐度 |
|---|---|---|---|---|
| 拆 Bean | 中（改结构） | 无 | 安全 | ★★★★★ |
| 自注入 + `@Lazy` | 低 | 有（需 `@Lazy`） | 安全 | ★★★☆ |
| `AopContext.currentProxy()` | 低 | 无 | **不安全** | ★★ |
| `TransactionTemplate` | 低 | 无 | 安全 | ★★★★★ |
| 直接操作线程池 | 低 | 无 | 安全 | ★★★★ |
| `ObjectProvider` | 低 | 无 | 安全 | ★★★★ |

---

## 四、除了自调用，还有 7 个「代理边界」陷阱

自调用只是「绕过代理」的一种。下面这些同样是「方法没经过代理」，症状一模一样：

### 4.1 `private` / `final` / `static` 方法

```java
@Transactional
private void doTx() { }   // ❌ CGLIB 无法重写 private 方法
```

`final` 方法不能被 CGLIB 子类覆盖；`static` 方法属于类不属于实例，代理无法拦截。**`@Transactional` 加在 `private` 方法上，Spring 连警告都不会给**（`@Async` 会给一个 `debug` 日志，`@Cacheable` 静默失败）。

### 4.2 构造器 / `@PostConstruct` 中调用

```java
@PostConstruct
public void init() {
    this.loadCache();       // ❌ 此时代理可能尚未完全初始化
}
```

`@PostConstruct` 执行时，Bean 还在初始化阶段，`BeanPostProcessor` 生成的代理虽已存在，但 `this` 仍是 target。同理，构造器里调用带注解的方法一定失效。

### 4.3 父类方法调用子类重写方法

```java
public abstract class BaseService {
    public void process() {
        this.handle();       // ❌ 即便 handle() 被子类加了注解
    }
    protected abstract void handle();
}

@Service
public class UserService extends BaseService {
    @Transactional
    protected void handle() { }
}
```

`this` 依然是 target，且 `protected` 方法能否被 CGLIB 覆盖取决于包可见性——跨包时 CGLIB 生成的子类无法覆盖，直接失效。

### 4.4 `@Transactional` 的传播行为误解

```java
@Transactional(propagation = Propagation.REQUIRES_NEW)
public void inner() { }

// 调用方
@Transactional
public void outer() {
    this.inner();          // ❌ REQUIRES_NEW 完全没用，因为在同一事务里
}
```

即使解开了自调用，`REQUIRES_NEW` 也要求**经过代理**才会挂起当前事务。自调用时它只是普通方法调用，事务上下文不变。

### 4.5 异常被吞掉导致不回滚

```java
@Transactional(rollbackFor = Exception.class)
public void create() {
    try {
        doSomething();            // 抛异常
    } catch (Exception e) {
        log.error("失败", e);      // ❌ 吞掉了，事务正常提交
    }
}
```

这是**仅次于自调用的第二大失效原因**。要么往外抛，要么手动 `TransactionAspectSupport.currentTransactionStatus().setRollbackOnly()`。

### 4.6 默认只回滚 `RuntimeException`

```java
@Transactional                       // 默认 rollbackFor = RuntimeException + Error
public void create() throws IOException {
    throw new IOException("IO 失败"); // ❌ 受检异常不回滚！
}

@Transactional(rollbackFor = Exception.class)   // ✅ 显式声明
public void create2() throws IOException { throw new IOException(); }
```

`rollbackFor = Exception.class` 应该成为团队规范，写死在代码规范检查里。

### 4.7 多数据源 / 事务管理器不匹配

```java
@Transactional("orderTxManager")   // 必须指定正确的事务管理器
public void create() { }
```

多数据源下不指定 `transactionManager`，会用默认的，可能操作的是另一个库的事务——表现为「回滚了但数据还在」。

---

## 五、如何在 CI 阶段自动发现这些坑

靠 code review 抓不住，必须工具化。

### 5.1 启动期自检：扫描自调用

```java
@Component
public class SelfInvocationDetector implements SmartInitializingSingleton {

    private final ApplicationContext ctx;

    public SelfInvocationDetector(ApplicationContext ctx) { this.ctx = ctx; }

    @Override
    public void afterSingletonsInstantiated() {
        for (String name : ctx.getBeanDefinitionNames()) {
            Class<?> type = ctx.getType(name);
            if (type == null || AopUtils.isAopProxy(type)) continue;

            for (Method m : type.getDeclaredMethods()) {
                if (!hasProxyAnnotation(m)) continue;
                // 找到同类中调用了该方法的地方（简化示意，生产用 ASM 扫描字节码）
                if (isInvokedInternally(type, m)) {
                    log.warn("[AOP 自调用风险] {}.{} 带 {} 注解，但存在同类内部调用",
                            type.getSimpleName(), m.getName(), annotationNames(m));
                }
            }
        }
    }
}
```

生产级实现建议用 **ASM 或 ByteBuddy 扫描 `target/classes`**，检测 `INVOKEVIRTUAL` 指令的目标方法是否是 `this` 且带 AOP 注解。

### 5.2 ArchUnit 规则

```java
@ArchTest
static final ArchRule no_private_transactional =
    methods().that().areAnnotatedWith(Transactional.class)
             .should().notBePrivate()
             .because("@Transactional 在 private 方法上不生效");

@ArchTest
static final ArchRule transactional_must_specify_rollback =
    methods().that().areAnnotatedWith(Transactional.class)
             .should().beAnnotatedWith(Transactional.class)
             .because("必须显式 rollbackFor = Exception.class");
```

第二条规则在纯 ArchUnit 里表达不了，实际要用自定义 `ArchCondition`：

```java
@ArchTest
static final ArchRule rollback_for_check = methods()
    .that().areAnnotatedWith(Transactional.class)
    .should(new ArchCondition<>("声明 rollbackFor = Exception.class") {
        @Override
        public void check(JavaMethod m, ConditionEvents events) {
            Transactional t = m.getAnnotationOfType(Transactional.class);
            boolean ok = Arrays.asList(t.rollbackFor()).contains(Exception.class);
            if (!ok) {
                events.add(SimpleConditionEvent.violated(m,
                        m.getFullName() + " 未声明 rollbackFor = Exception.class"));
            }
        }
    });
```

### 5.3 SonarQube 自定义规则

SonarJava 自带 `S2222`（锁）、`S1220` 等，但没有自调用检测。可以用 **SonarQube 自定义规则 + Java 语义分析 API**，或者更轻量地用 **ErrorProne 插件**在编译期拦截。

---

## 六、面试高频追问

**Q1：为什么 `@Transactional` 加在 `private` 方法上不生效，Spring 会报错吗？**
答：不生效，且**默认不报错**。`AbstractFallbackTransactionAttributeSource#computeTransactionAttribute` 会判断方法是否 `public`，非 `public` 直接返回 `null`（不参与事务），只有开启 `TRACE` 日志才能看到 `Skipping the method ... is not public`。这正是它危险的地方——静默失效。

**Q2：`AopContext.currentProxy()` 在 `@Async` 方法里为什么可能拿不到？**
答：`AopContext` 基于 `ThreadLocal`。`@Async` 会把方法体提交到线程池，子线程的 `ThreadLocal` 是空的，`currentProxy()` 抛 `IllegalStateException: Cannot find current proxy`。跨线程传递上下文要用 `TransmittableThreadLocal`（TTL）或 `TaskDecorator` 显式传递。

**Q3：CGLIB 代理为什么不能代理 `final` 类？**
答：CGLIB 通过继承生成子类并重写方法来织入拦截逻辑。`final` 类不可继承、`final` 方法不可重写，因此无法生成有效的代理。Spring 5.2+ 遇到 `final` 类会直接抛 `IllegalArgumentException`，而不是静默降级。

**Q4：JDK 动态代理和 CGLIB 在自调用问题上有区别吗？**
答：没有区别。两者都是「代理对象包住 target」，`this` 都指向 target。区别只在「能代理什么」（接口 vs 类）和「性能特征」（JDK 反射调用 vs CGLIB 直接调用，JDK 8 之后差距很小）。

**Q5：`@Transactional` 和 `synchronized` 一起用有什么问题？**
答：执行顺序是 `synchronized` 在方法内部，事务拦截器在方法外部——**锁在事务内部**，意味着「事务提交」发生在「释放锁」之后。两个线程可能出现：线程 A 释放锁但事务未提交 → 线程 B 拿到锁读到旧数据。正确做法是用数据库行锁（`select ... for update`）或分布式锁，并把锁加在事务外层。

**Q6：`@Async` 方法返回 `void` 时抛异常会怎样？**
答：异常会被 `AsyncUncaughtExceptionHandler` 捕获（默认是 `SimpleAsyncUncaughtExceptionHandler`，只打日志），**调用方完全感知不到**。生产上要么返回 `CompletableFuture`，要么自定义 `AsyncConfigurer#getAsyncUncaughtExceptionHandler` 做告警。

**Q7：为什么 Spring Boot 2.6 之后自注入会启动失败？**
答：2.6 起 `spring.main.allow-circular-references` 默认 `false`。自注入形成 `A → A` 的循环引用，直接启动报错。解法是加 `@Lazy`（注入代理，延迟解析）或用 `ObjectProvider`。

---

## 七、团队规范建议（可直接抄）

| 规范 | 目的 |
|---|---|
| `@Transactional` 一律写 `rollbackFor = Exception.class` | 避免受检异常不回滚 |
| 禁止在 `private`/`final`/`static` 方法上加 AOP 注解 | ArchUnit 强制 |
| 事务方法内需要「独立事务」时，拆 Bean 或用 `TransactionTemplate` | 杜绝自调用 + `REQUIRES_NEW` 误解 |
| `@Async` 方法返回 `CompletableFuture`，禁止裸 `void` | 异常可感知 |
| 禁止 `catch` 后只打日志不回滚 | 统一抛 `BusinessException` |
| 禁止 `@Transactional` + `synchronized` 组合 | 用 DB 行锁替代 |
| 多数据源必须显式 `@Transactional("xxxTxManager")` | 避免事务错库 |

---

## 八、总结

用一张图收尾：

```
        调用方
          │
          ▼
    ┌─────────────┐        ┌──────────────────────────┐
    │   Proxy     │  ────► │ Interceptor Chain        │
    │ (CGLIB/JDK) │        │ Transaction / Async /    │
    └─────────────┘        │ Cache / Validation       │
          │                └──────────────────────────┘
          ▼
    ┌─────────────┐
    │   Target    │ ──── this.xxx() ────┐  ← 断链！
    └─────────────┘                      │
          ▲                              │
          └──────────────────────────────┘
```

记住一句话：**Spring AOP 的所有「注解失效」，本质都是「调用没有经过代理」。** 自调用、`private` 方法、构造器调用、父类调用，全部是这一个模型的不同表现。理解了这个模型，`@Transactional`、`@Async`、`@Cacheable`、`@Validated`、`@Retryable`、`@PreAuthorize` 就不再是六个需要分别记忆的知识点，而是同一个原理的六个实例。

至于解法，我的排序是：**能拆 Bean 就拆 Bean，不能拆就上 `TransactionTemplate`，实在不行再自注入加 `@Lazy`，`AopContext` 只当最后手段。** 前两种方案不会在半年后变成别人眼里的「魔法代码」。
