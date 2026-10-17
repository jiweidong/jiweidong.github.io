---
title: 【Spring 源码】@Order 与 Ordered 排序体系深度解析：AOP 切面、事件监听、Filter 与 Starter 的顺序治理
date: 2026-10-17 08:05:00
tags:
  - Java
  - Spring
  - 源码
  - AOP
  - 面试
categories:
  - Java 深挖
author: 东哥
---

# 【Spring 源码】@Order 与 Ordered 排序体系深度解析

## 前言

「两个切面都加了 `@Order`，为什么执行顺序和我预期相反？」「`@EventListener` 谁先执行？」「`Filter` 的 `@Order` 到底管不管用？」——这些问题的共同答案，都落在 Spring 的**排序体系**上。

`@Order` 看似简单，实则是 Spring 里**最容易被误用**的注解之一：它对不同组件的效果不一样，有的生效、有的不生效，有的升序、有的降序。本文把 `Ordered` / `@Order` / `OrderComparator` 的机制讲透，并逐一梳理它在 AOP、事件、Filter、拦截器、Bean 依赖等场景里的真实行为。

---

## 一、`Ordered` 与 `@Order` 的基础语义

Spring 定义了两个东西：

```java
public interface Ordered {
    int HIGHEST_PRECEDENCE = Integer.MIN_VALUE;   // 最高优先级 = 最先执行
    int LOWEST_PRECEDENCE  = Integer.MAX_VALUE;
    int getOrder();
}

@Retention(RetentionPolicy.RUNTIME)
@Target({ElementType.TYPE, ElementType.METHOD, ElementType.FIELD})
public @interface Order {
    int value() default Ordered.LOWEST_PRECEDENCE;
}
```

**核心规则**：**数值越小，优先级越高，越先执行**。

- `Ordered.HIGHEST_PRECEDENCE` = `Integer.MIN_VALUE` → 最先。
- `Ordered.LOWEST_PRECEDENCE` = `Integer.MAX_VALUE` → 最后（默认值）。

```java
@Component
@Order(1)
class A {}   // 先

@Component
@Order(10)
class B {}   // 后

@Component           // 不加 @Order = 默认 LOWEST_PRECEDENCE
class C {}           // 最后
```

> ⚠️ 第一个坑：**注解没加 ≠ 等于 0**。不加 `@Order` 的等价于 `LOWEST_PRECEDENCE`（最大值），不是 0。很多人以为「默认 0」结果顺序全乱。

---

## 二、`OrderComparator`：排序是怎么发生的

Spring 的排序逻辑集中在 `OrderComparator`（及其子类 `AnnotationAwareOrderComparator`）：

```java
public class OrderComparator implements Comparator<Object> {
    @Override
    public int compare(Object o1, Object o2) {
        // 大致逻辑：能取到 order 的按 order 比；取不到的按 LOWEST_PRECEDENCE
        int i1 = getOrder(o1);
        int i2 = getOrder(o2);
        return Integer.compare(i1, i2);
    }
}
```

- `OrderComparator`：只认实现了 `Ordered` 接口的对象，或 `PriorityOrdered`。
- `AnnotationAwareOrderComparator`：**额外支持 `@Order` 注解**（从类/方法上反射读取）。这是 `@Order` 生效的关键。

获取顺序时的优先级：**`PriorityOrdered` > `Ordered` > `@Order` > 无**（无则视为最低优先级）。

```java
public interface PriorityOrdered extends Ordered {}
```

`PriorityOrdered` 是「比普通 `Ordered` 还早」的标记，主要给 Spring 内部基础设施用（如某些 `BeanPostProcessor`）。

---

## 三、场景一：AOP 切面的执行顺序

切面顺序是面试重灾区。规则如下：

- 使用 `@Aspect` + `@Order(n)`（或实现 `Ordered`）。
- **`@Order` 值越小，切面优先级越高**。
- 对 `@Around` / `@Before`：**优先级高的先执行**（进入时洋葱模型由外向内）。
- 对 `@After` / `@AfterReturning`：**优先级高的后执行**（退出时由内向外）。

```java
@Aspect
@Component
@Order(1)
class LogAspect {
    @Around("...") Object around(ProceedingJoinPoint pjp) throws Throwable {
        System.out.println("LogAspect before");
        Object r = pjp.proceed();
        System.out.println("LogAspect after");
        return r;
    }
}

@Aspect
@Component
@Order(2)
class TxAspect {
    @Around("...") Object around(ProceedingJoinPoint pjp) throws Throwable {
        System.out.println("TxAspect before");
        Object r = pjp.proceed();
        System.out.println("TxAspect after");
        return r;
    }
}
```

输出：

```
LogAspect before        // Order(1) 先进入
TxAspect before         // Order(2) 后进入
TxAspect after          // Order(2) 先退出
LogAspect after         // Order(1) 后退出
```

**洋葱模型**：进入顺序 = order 升序，退出顺序 = order 降序。这是最容易记混的点。

> ⚠️ 第二个坑：如果切面**没有实现 `Ordered` 也没加 `@Order`**，它们之间的顺序是**不确定的**（取决于 Bean 注册顺序），不要依赖这种偶然顺序。

**排序依赖 `AspectJAwareAdvisorAutoProxyCreator` / `AnnotationAwareAspectJAutoProxyCreator`** 对 advisor 的排序。同一个切面内多个 `@Before` 的先后，则由默认的「方法名无关」规则处理，也建议通过拆分为多个切面 + `@Order` 来显式控制。

---

## 四、场景二：`@EventListener` 的监听顺序

```java
@Component
class Listener1 {
    @Order(1)
    @EventListener
    public void on(OrderCreatedEvent e) { System.out.println("L1"); }
}

@Component
class Listener2 {
    @Order(2)
    @EventListener
    public void on(OrderCreatedEvent e) { System.out.println("L2"); }
}
```

- 对**同步**事件（`ApplicationEventMulticaster` 默认同步），`@Order` 生效，值小者先执行。
- 每个监听器抛异常默认会中断后续监听器（同步场景），需要 `@EventListener` 的 `@Async` 或 errorHandler 隔离。
- 对**异步**监听（`@Async` + `@EventListener`），`@Order` 只决定**提交顺序**，实际执行顺序受线程池调度影响，**不再保证**。

> ⚠️ 第三个坑：`@Async` 监听器之间不要依赖 `@Order` 保证执行顺序。

---

## 五、场景三：Filter 与拦截器

这里 `@Order` 的效力差别最大，必须分清：

| 组件 | `@Order` 是否生效 | 方向 |
|---|---|---|
| `Filter`（Servlet Filter，注册为 Bean） | **生效** | 值小者先执行（先进入，后退出） |
| `HandlerInterceptor` | **不生效** | 由 `WebMvcConfigurer.addInterceptors` 的**注册顺序**决定 |
| Spring Security Filter | 生效（通过 `SecurityFilterChain` 的 `addFilterBefore/After`，非 `@Order`） | 见下 |
| `ServletContextInitializer` | 生效 | |

**Servlet Filter**（Spring Boot 里注册为 Bean 时）：

```java
@Component
@Order(1)
class AuthFilter implements Filter {
    @Override public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        // 先执行
        chain.doFilter(req, res);
    }
}
```

> 注意：如果用 `FilterRegistrationBean` 显式注册，`@Order` 会被 `registrationBean.setOrder()` 覆盖/或另行处理，两者不要混用。

**`HandlerInterceptor`**：`@Order` **无效**，顺序由注册先后决定：

```java
@Configuration
class WebConfig implements WebMvcConfigurer {
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(new AInterceptor());  // 先注册 → 先执行
        registry.addInterceptor(new BInterceptor());  // 后注册 → 后执行
    }
}
```

**Spring Security 过滤器**：用的是 `HttpSecurity.addFilterBefore/After` 的**位置语义**，而不是 `@Order`。自定义 `Filter` Bean 若同时被 Servlet 容器和 Security 链拾取，可能出现「执行两次」，需要用 `FilterRegistrationBean` 关闭自动注册（`setEnabled(false)`）。

---

## 六、场景四：Bean 依赖顺序与 `Ordered`

`@Order` **不会**影响 Bean 的实例化顺序。要控制初始化顺序，应该用：

- `@DependsOn("otherBean")`：显式声明依赖，保证先初始化。
- `@AutoConfigureOrder` / `@AutoConfigureBefore` / `@AutoConfigureAfter`：**自动配置类**之间的顺序（Spring Boot）。

```java
@AutoConfiguration
@AutoConfigureAfter(DataSourceAutoConfiguration.class)
class MyAutoConfiguration {}
```

> ⚠️ 第四个坑：`@Order` 管的是「同一批集合/数组注入后的排列顺序」和「处理器链顺序」，**不是 Bean 创建顺序**。

**集合注入排序**：

```java
// 注入 List 时，Spring 会用 OrderComparator 排序，@Order 生效
public MyService(List<Handler> handlers) {}   // handlers 已按 @Order 升序排列
```

这也是 `@Order` 最常见的生产用法：**策略模式里让 `List<Strategy>` 按优先级排列**。

---

## 七、`@AutoConfigureOrder` vs `@Order` vs `@Priority`

三个东西经常被混淆：

| 注解 | 作用域 | 数值方向 | 说明 |
|---|---|---|---|
| `@Order` | Spring 组件/切面/监听器/集合注入 | 小 → 优先 | Spring 自有 |
| `@AutoConfigureOrder` | 自动配置类 | 小 → 优先 | 只影响自动配置排序 |
| `@Priority` | JSR-250 / 通用 | 小 → 优先 | 标准注解，Spring 部分场景支持 |

`@Priority` 与 `@Order` 在语义上一致（都是小值优先），但 Spring 在多数场景优先识别 `Ordered`/`@Order`。混用时以 `AnnotationAwareOrderComparator` 的解析为准：**`Ordered` 接口 > `@Order` > `@Priority`**（近似）。

---

## 八、生产踩坑清单

1. **忘记 `@Order` 默认是最低优先级**：以为默认 0，导致自定义切面排在 Spring 事务切面（`Ordered.LOWEST_PRECEDENCE` 之前其实事务默认值较高）之外。
2. **`@Async` 监听器依赖顺序**：异步后 `@Order` 不再保证执行顺序。
3. **Filter 与 Security Filter 重复执行**：同一 `Filter` Bean 被两条链拾取。
4. **`HandlerInterceptor` 用 `@Order`**：无效，必须靠注册顺序。
5. **切面顺序与事务切面冲突**：自定义切面若 `order` 小于事务切面，会在**事务之外**执行，可能导致「日志打印了但事务回滚了数据没落库」的错觉。要让自定义逻辑进事务，`@Order` 值需大于事务切面默认顺序（`Ordered.LOWEST_PRECEDENCE` 附近，其实事务拦截器默认在很后面）。

> 事务切面默认 `order` 是 `Ordered.LOWEST_PRECEDENCE`（可通过 `@EnableTransactionManagement(order=...)` 改）。所以自定义切面默认 order（也是最小值？注意——不加 `@Order` 时是**默认最低优先级**，会排在事务外面还是里面取决于具体实现），**稳妥做法是显式指定 order，并压测验证顺序**。

---

## 九、面试高频追问

**Q1：`@Order` 数值越小越先还是越后？**
越小越先执行（优先级越高）。`HIGHEST_PRECEDENCE = Integer.MIN_VALUE`，`LOWEST_PRECEDENCE = Integer.MAX_VALUE`。

**Q2：两个切面都加了 `@Before`，执行顺序如何确定？**
看各自 `@Order`：值小的先执行 `@Before`，对应的 `@After` 则值小的后执行（洋葱模型）。没指定 order 的切面顺序不确定。

**Q3：`@Order` 能控制 Bean 的初始化顺序吗？**
不能。Bean 初始化顺序由依赖关系（`@DependsOn`/构造注入）决定。`@Order` 影响的是集合注入排序、切面/处理器链顺序、事件监听顺序。

**Q4：`HandlerInterceptor` 的 `@Order` 为什么不起作用？**
因为拦截器的执行顺序由 `InterceptorRegistry` 的注册顺序决定，`DispatcherServlet` 按注册列表顺序执行，不经过 `OrderComparator`。

**Q5：怎么让自定义切面在事务提交之后执行？**
要么把 `@Order` 设得比事务切面大（在事务内层之后），要么用 `TransactionSynchronization`/`@TransactionalEventListener(phase = AFTER_COMMIT)` 在事务提交后执行副作用。

---

## 结语

`@Order` 不是「万能排序开关」。它背后是 `Ordered` 接口 + `OrderComparator` + `AnnotationAwareOrderComparator` 一整套机制，**在不同的 Spring 组件上效力天差地别**：AOP 切面、事件监听、Filter、集合注入生效；Bean 初始化、拦截器不生效；异步监听不保证。把这些边界记清楚，你在排查「顺序诡异」的线上问题时，就能一眼看出是排序机制没生效，还是用错了地方。下一篇继续盘 Spring 源码里的高频考点。
