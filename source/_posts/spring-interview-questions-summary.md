---
title: 【Java 面试】Spring 高频面试题总结：IoC、AOP、事务、循环依赖与自动配置 40 问
date: 2026-10-16 08:00:00
tags:
  - Java
  - Spring
  - 面试
  - IoC
  - AOP
categories:
  - Java 面试
author: 东哥
---

# 【Java 面试】Spring 高频面试题总结：IoC、AOP、事务、循环依赖与自动配置 40 问

## 前言

Spring 是 Java 后端面试的"必考大题"。它的可怕之处在于**知识点互相咬合**：问你 AOP，会牵扯 Bean 生命周期；问事务失效，背后是 AOP 代理与自调用；问循环依赖，就要讲三级缓存。本文按 **IoC/DI → Bean 生命周期 → AOP → 事务 → Spring Boot 自动配置** 五条主线，把高频问题、标准答案、追问和加分答法一次讲透。

## 一、IoC 与 DI：控制反转到底反了谁

**Q1：什么是 IoC？DI 和 IoC 什么关系？**

IoC 是**设计思想**——把对象创建和依赖装配的控制权从代码交给容器；DI 是 IoC 的**实现方式**——容器把依赖"注入"给对象。Spring 容器主要靠 `BeanFactory`（基础）和 `ApplicationContext`（增强，含事件、国际化、资源加载、BeanPostProcessor 自动注册）。

**Q2：DI 有哪几种方式？推荐哪种？**

| 方式 | 写法 | 优缺点 |
|---|---|---|
| 构造器注入 | 构造方法参数 | **推荐**：依赖不可变、便于测试、强制非空 |
| Setter 注入 | `@Autowired` 在 setter | 可选依赖、可重新注入 |
| 字段注入 | `@Autowired` 在字段 | 简洁但**不推荐**：无法 final、单测难、隐藏依赖 |
| 方法注入 | `@Autowired` 在方法 | 批量注入 |

**加分答法**：Spring 官方推荐构造器注入；Spring 4.3 起**单构造器可省略 `@Autowired`**。

**Q3：`@Autowired` 和 `@Resource` 区别？**

`@Autowired` 是 Spring 的，**按类型**注入，可配 `@Qualifier`；`@Resource` 是 JSR-250，**默认按名称**，找不到名称再按类型。名称默认取字段名。

## 二、Bean 生命周期：一环扣一环

**Q4：Bean 生命周期？**

1. 实例化（构造器）
2. 属性填充（populate）
3. 各种 Aware（BeanNameAware、BeanFactoryAware、ApplicationContextAware）
4. `BeanPostProcessor.postProcessBeforeInitialization`
5. `@PostConstruct` / `InitializingBean.afterPropertiesSet` / `init-method`
6. `BeanPostProcessor.postProcessAfterInitialization` ← **AOP 代理在此生成**
7. 使用
8. `@PreDestroy` / `DisposableBean.destroy` / `destroy-method`

**追问**：AOP 代理哪一步生成？——第 6 步，`AbstractAutoProxyCreator` 在 `postProcessAfterInitialization` 里用 `ProxyFactory` 包装。

**Q5：`@PostConstruct` 和 `afterPropertiesSet` 谁先执行？**

`@PostConstruct` → `afterPropertiesSet` → `init-method`，依次执行。

**Q6：Bean 作用域有哪些？**

`singleton`（默认）、`prototype`、`request`、`session`、`application`、`websocket`。**注意**：单例 Bean 注入原型 Bean 时，原型只有一次生效——要每次拿到新实例需用 `@Lookup` 或 `ObjectProvider`。

## 三、循环依赖：三级缓存是面试"照妖镜"

**Q7：Spring 怎么解决循环依赖？**

A 依赖 B、B 依赖 A，用**三级缓存**：

| 缓存 | 名称 | 存什么 |
|---|---|---|
| 一级 | singletonObjects | 完整的单例 Bean |
| 二级 | earlySingletonObjects | 提前暴露的**半成品**（已实例化、未填充） |
| 三级 | singletonFactories | `ObjectFactory`，用于生成代理 |

流程：A 实例化 → 把 A 的 ObjectFactory 放三级缓存 → 填充 B → B 需要 A → 从三级缓存拿到 A 的早期引用（必要时先生成代理）放入二级 → B 完成 → A 完成并放入一级。

**追问 1**：为什么需要三级而不是两级？**为了 AOP**。如果 A 被代理，B 需要的是代理对象；两级缓存在需要提前引用时才生成代理，会导致"提前引用"和"最终 Bean"不一致。三级缓存里的 ObjectFactory 保证"需要代理时再生成且只生成一次"。

**追问 2**：构造器注入的循环依赖能解决吗？**不能**，直接抛 `BeanCurrentlyInCreationException`——因为对象还没实例化，没法提前暴露。字段/Setter 注入可以。

**追问 3**：多例 Bean 的循环依赖？不能解决。

## 四、AOP：动态代理与失效陷阱

**Q8：AOP 底层靠什么？**

**JDK 动态代理**（目标实现接口，基于接口）或 **CGLIB**（无接口，继承子类）。Spring Boot 2.x 起 `proxyTargetClass` 默认 true，**统一用 CGLIB**。

**Q9：为什么 JDK 代理要求接口，CGLIB 不能代理 final 类？**

JDK 代理基于 `Proxy` + `InvocationHandler`，生成的代理类实现了目标接口，因此必须有接口；CGLIB 通过 ASM 生成**目标类的子类**并重写方法，所以 `final` 类/`final` 方法无法被继承/重写，代理失效。

**Q10：`@Transactional` 为什么自调用会失效？**

因为事务是 AOP 代理增强的，**自调用走的是 `this`，没经过代理对象**。

```java
@Service
public class OrderService {
    public void outer() {
        inner();          // ❌ 走 this，事务失效
    }
    @Transactional
    public void inner() { /* ... */ }
}
```

**解决**：注入自身 `AopContext.currentProxy()`（需 `@EnableAspectJAutoProxy(exposeProxy = true)`）、拆到另一个 Bean、或用 `TransactionTemplate` 编程式事务。

**Q11：还有哪些事务失效场景？**

方法非 `public`、异常被 catch 吞掉（默认只回滚 `RuntimeException`/`Error`）、rollbackFor 未配、多线程调用、数据库引擎不支持事务（MyISAM）、传播行为配置错误。

## 五、事务传播：一张表说清楚

**Q12：7 种传播行为？**

| 传播行为 | 含义 |
|---|---|
| REQUIRED（默认） | 有则加入，无则新建 |
| REQUIRES_NEW | 挂起当前，**始终新建** |
| SUPPORTS | 有则加入，无则非事务运行 |
| NOT_SUPPORTED | 挂起当前，非事务运行 |
| MANDATORY | 有则加入，无则抛异常 |
| NEVER | 有则抛异常 |
| NESTED | 有则建**保存点（savepoint）**，可部分回滚 |

**追问**：REQUIRES_NEW 和 NESTED 区别？REQUIRES_NEW 是**两个独立事务**（需两个连接，外层回滚不影响内层）；NESTED 是**同一事务的保存点**，外层回滚会连带内层回滚。内层异常被外层捕获时，NESTED 可只回滚到保存点。

## 六、Spring Boot 自动配置：从"魔法"到原理

**Q13：自动配置原理？**

`@SpringBootApplication` = `@SpringBootConfiguration` + `@EnableAutoConfiguration` + `@ComponentScan`。`@EnableAutoConfiguration` 通过 `@Import(AutoConfigurationImportSelector.class)` 读取 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`（2.7 前是 `spring.factories`）里的候选配置类，再经 `@Conditional` 系列按需生效。

**Q14：常用条件注解？**

`@ConditionalOnClass`、`@ConditionalOnMissingBean`、`@ConditionalOnProperty`、`@ConditionalOnWebApplication`。这正是"引入 starter 就自动生效、你自定义了就不覆盖"的机制——**用户 Bean 优先**。

**Q15：`@Configuration` 和 `@Component` 区别？**

`@Configuration` 被 CGLIB 增强（`proxyBeanMethods = true`），保证 `@Bean` 方法内部相互调用返回**同一个单例**；`@Component` 不会，方法调用就是普通 Java 调用，会产生多个实例。`@Configuration(proxyBeanMethods = false)` 可关闭代理提升启动性能（Spring Boot 2.2+ 的 `@AutoConfiguration` 就是 false）。

## 七、高频追问速查

- **BeanFactory 和 FactoryBean？** 前者是容器，后者是"生产 Bean 的 Bean"（如 `MyBatis` 的 `MapperFactoryBean`）。
- **`@Bean` 和 `@Component`？** 前者用于第三方类（方法级），后者用于自己写的类（类级，需被扫描）。
- **Spring 事件机制？** `ApplicationEvent` + `ApplicationListener`，`@EventListener` 简化；默认同步，`@Async` 可异步。
- **`@Async` 失效？** 同样是自调用问题，且需 `@EnableAsync`、被代理的 public 方法。
- **启动慢怎么优化？** 减少扫描范围、`lazy-init`、关闭 `proxyBeanMethods`、升级 Spring Boot 3 + 延迟初始化 `spring.main.lazy-initialization=true`（注意首次请求变慢）。

## 总结

Spring 面试的答题心法：**任何"失效/不生效"问题的第一反应都是"有没有走代理"**，第二反应是"作用域/线程/传播对不对"。把 Bean 生命周期背成一条时间线，把三级缓存讲成"AOP 一致性"的解法，再把自动配置落到 `AutoConfiguration.imports` + `@Conditional`，你就从"会用 Spring"升级到"懂 Spring"了。

配合上一篇 **JVM 高频面试题总结** 和下一篇 **MySQL 高频面试题总结**，Java 后端三座大山就凑齐了。
