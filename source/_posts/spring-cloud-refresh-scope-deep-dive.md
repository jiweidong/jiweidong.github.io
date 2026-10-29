---
title: 【Spring 源码】@RefreshScope 与配置动态刷新深度解析：代理重建、Bean 生命周期与线程安全陷阱
date: 2026-10-29 08:20:00
tags:
  - Java
  - Spring Cloud
  - Nacos
  - 配置中心
  - 源码
categories:
  - Spring
author: 东哥
---

# 【Spring 源码】@RefreshScope 与配置动态刷新深度解析：代理重建、Bean 生命周期与线程安全陷阱

## 前言

配置中心上线之后，团队最常见的三个问题：

1. 改了 Nacos 配置，`@Value` 注进来的值**没变**；
2. 值变了，但**连接池没换**，旧连接还在用旧地址；
3. 值变了、Bean 也重建了，结果**老 Bean 被别处持有**，一部分请求走新配置、一部分走旧配置，出现"半刷新"。

这三个问题的答案都指向同一个类：`org.springframework.cloud.context.scope.refresh.RefreshScope`。它只有两百多行，却是 Spring Cloud 里最容易被误用的机制之一。

本文从源码链路讲清：`@RefreshScope` 为什么必须靠代理、刷新时到底发生了什么、为什么有些 Bean 刷不动、以及生产上该怎么设计"可安全刷新"的 Bean。

## 一、先看它解决什么问题

Spring 的单例 Bean 在容器启动时就完成依赖注入，`@Value("${app.timeout}")` 在那一刻被解析成具体值。之后 `Environment` 变了，单例 Bean 里的字段不会跟着变。

`@RefreshScope` 的思路是：**不要缓存这个 Bean 的实例，每次拿的时候重新创建**。

```
普通单例：  getBean() -> 返回同一个实例（值永远不变）
@RefreshScope：getBean() -> 返回代理 -> 代理每次调用时去 scope 里取（可取到新实例）
```

于是它必须做两件事：

1. 提供一个**自定义 Scope**（`refresh`），把 Bean 的实例缓存起来，但允许整体清空；
2. 提供一个**代理**，让调用方拿到的引用在实例被替换后仍能"转发"到新实例。

## 二、源码链路：一次刷新发生了什么

### 2.1 触发入口

Nacos Config 的长轮询（`LongPollingRunnable`）发现配置变更后，发布 `EnvironmentChangeEvent`，`ContextRefresher` 接手：

```java
// ContextRefresher（简化）
public synchronized Set<String> refresh() {
    Set<String> keys = refreshEnvironment();      // 1. 重新绑定 Environment
    this.scope.refreshAll();                      // 2. 清空 refresh scope
    return keys;
}
```

`refreshEnvironment()` 会重新加载 `PropertySource`，并**重新绑定所有 `@ConfigurationProperties` Bean**（走 `ConfigurationPropertiesRebinder`）。这是很多人以为"`@RefreshScope` 会刷新一切"的误解来源——`@ConfigurationProperties` 其实不依赖 `@RefreshScope`。

### 2.2 `refreshAll()` 做了什么

```java
// RefreshScope
public void refreshAll() {
    super.destroy();                 // 销毁 scope 内所有 Bean 实例
    this.context.publishEvent(new RefreshScopeRefreshedEvent());
}
```

`super.destroy()` 来自 `GenericScope`：

```java
public void destroy() {
    List<Throwable> errors = new ArrayList<>();
    for (String name : this.beans.getBeanNames()) {
        destroy(name);               // 逐个销毁，调用 DisposableBean.destroy()
    }
    // 有异常会聚合成一个异常抛出，但已经销毁的不会回滚
}
```

`destroy(name)` 里做的关键动作：

```java
BeanLifecycleWrapper wrapper = this.beans.remove(name);   // 从缓存移除
if (wrapper != null) {
    wrapper.destroy();                                    // 触发销毁回调
}
```

注意顺序：**先从缓存移除，再销毁**。这意味着在销毁过程中如果还有并发请求进来，会创建新实例，而旧实例正在被销毁——这是"半刷新"的根源之一。

### 2.3 代理是怎么来的

`RefreshScope` 实现了 `Scope`，并注册为 `refresh`。`@RefreshScope` 本身是：

```java
@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Scope("refresh")
public @interface RefreshScope {
    ScopedProxyMode proxyMode() default ScopedProxyMode.TARGET_CLASS;
}
```

`TARGET_CLASS` 表示用 CGLIB 生成子类代理。为什么必须是代理，而不能像普通 scope 那样直接返回实例？

因为**注入发生在容器启动时**。`@Autowired` 注入的是代理对象，代理持有 `BeanFactory` 和 bean name，每次方法调用时执行：

```java
// GenericScope.LockedScopedProxyFactoryBean 的核心逻辑（简化）
public Object invoke(MethodInvocation invocation) {
    BeanLifecycleWrapper wrapper = getBean(name);   // 从 scope 缓存取
    Object target = wrapper.getBean();
    return invocation.getMethod().invoke(target, invocation.getArguments());
}
```

所以刷新后，代理仍指向同一个 bean name，但 `getBean(name)` 会拿到新实例。**调用方持有的引用不需要变，行为却变了。**

### 2.4 为什么 `@Value` 字段能刷新，注入的 `DataSource` 不能

`@Value` 字段是在**实例创建时**由 `AutowiredAnnotationBeanPostProcessor` 注入的。Bean 被重建 → 字段被重新解析 → 值更新。这依赖"重建"这个动作。

而如果你把 `DataSource` 作为构造参数注入到另一个单例 Bean：

```java
@Service
public class OrderService {
    private final DataSource dataSource;   // 单例，注入时拿的是代理吗？
    public OrderService(DataSource ds) { this.dataSource = ds; }
}
```

如果 `DataSource` 上有 `@RefreshScope`，`ds` 是代理，调用 `ds.getConnection()` 会转发到新实例 —— 看起来没问题。但：

- 如果 `OrderService` 缓存了 `ds.getConnection()` 得到的 `Connection`，那连接不会变；
- 如果 `OrderService` 自己不是 refresh scope，它不会被重建，构造期读到的其他配置也不会变。

## 三、五类"刷不动"的 Bean

### 3.1 缺少代理：同类内部调用

```java
@Service
@RefreshScope
public class ConfigHolder {
    @Value("${app.limit}")
    private int limit;

    public int getLimit() { return limit; }

    public boolean overLimit(int n) {
        return n > getLimit();     // ✅ 走代理，能取到新值
    }

    public boolean overLimit2(int n) {
        return n > limit;          // ✅ 也是在代理方法内执行，字段是新的
    }
}
```

这里其实没问题，因为整个方法体在代理转发后的目标实例里执行。真正的问题出在**外部缓存了值**：

```java
@Service
public class LimitService {
    @Autowired private ConfigHolder holder;
    private int cachedLimit;                 // ❌ 自己缓存了
    @PostConstruct void init() { cachedLimit = holder.getLimit(); }
}
```

### 3.2 线程池、连接池、`@Scheduled` 不会被重建

`ThreadPoolExecutor` 创建后核心参数不可变；`HikariDataSource` 关闭再重建才能换地址；`@Scheduled` 的 cron 表达式在注册时就固化了。

这些都需要**显式的 destroy/init 逻辑**：

```java
@Component
@RefreshScope
public class DynamicExecutor {
    @Value("${app.pool.core:8}")
    private int core;
    @Value("${app.pool.max:32}")
    private int max;
    private ThreadPoolExecutor executor;

    @PostConstruct
    public void init() {
        executor = new ThreadPoolExecutor(core, max, 60, TimeUnit.SECONDS,
                new LinkedBlockingQueue<>(2000),
                new ThreadPoolExecutor.CallerRunsPolicy());
    }

    @PreDestroy
    public void shutdown() {
        executor.shutdown();
        try {
            if (!executor.awaitTermination(5, TimeUnit.SECONDS)) {
                executor.shutdownNow();
            }
        } catch (InterruptedException e) {
            executor.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }

    public <T> Future<T> submit(Callable<T> task) {
        return executor.submit(task);
    }
}
```

⚠️ 注意：`@RefreshScope` + `@PreDestroy` 的销毁是同步的。如果池里有长任务，`awaitTermination` 会把刷新线程卡住；刷新线程是**单线程串行**的，卡住会导致后续所有 Bean 都刷不了。所以超时要短，或者改成"优雅移交"。

### 3.3 静态字段、常量、`final` 字段

```java
@RefreshScope
@Component
public class Bad {
    private static int LIMIT;                 // ❌ 静态字段不随实例重建
    private final int limit;                  // ⚠️ final 字段可以被重新注入吗？不行
}
```

`final` 字段在构造后不可变，Spring 的字段注入不会覆盖它（会报错或静默失败，取决于注入方式）。要刷新就把 `final` 去掉。

### 3.4 被其他框架缓存的引用

- MyBatis 的 `SqlSessionFactory` 持有 `Environment` 与 `DataSource`；
- Feign 的 `Client` 在启动时构建；
- Netty 的 `EventLoopGroup`、`Bootstrap`；
- 缓存客户端（Redisson、Jedis Pool）的连接。

这些对象通常在第三方 starter 里创建，没有 `@RefreshScope`，也不会响应 `RefreshScopeRefreshedEvent`。要么使用 starter 自带的刷新支持（如 `spring-cloud-starter-loadbalancer` 的动态服务列表），要么自己监听事件重建。

### 3.5 事件监听器的顺序问题

```java
@Component
public class MyRefreshListener {
    @EventListener(RefreshScopeRefreshedEvent.class)
    public void onRefresh() {
        // 此时 refresh scope 已经清空，但新 Bean 还没创建
        // 如果这里去 getBean，会创建新实例（正常）
        // 但如果这里依赖"旧实例已完成清理"，不一定成立
    }
}
```

`RefreshScopeRefreshedEvent` 在 `destroy()` **之后**发布，语义是"旧实例已销毁"。但注意销毁是逐个进行的，如果某个 Bean 销毁抛异常，`destroy()` 会继续销毁其余 Bean 然后抛异常 —— 也就是说事件可能不会发出（异常在 `refreshAll` 里向上抛），而部分 Bean 已经被销毁。这是生产上"刷新后一半 Bean 是新的、一半是旧的"的另一种成因。

## 四、更安全的动态配置方案

### 4.1 方案对比

| 方案 | 刷新粒度 | 是否重建 Bean | 适用场景 | 风险 |
|---|---|---|---|---|
| `@RefreshScope` | Bean 级 | 是 | 简单配置项、无状态组件 | 重建副作用、半刷新 |
| `@ConfigurationProperties` + `@RefreshScope` | 属性级 | 是 | 一组相关配置 | 同上 |
| `Environment` 直接读 | 字段级 | 否 | 高频读取、要求零抖动 | 每次读有开销，需缓存 |
| 自定义 `AtomicReference` 持有配置 | 字段级 | 否 | 连接池参数、限流阈值 | 需自己做校验与生效 |
| 监听 `EnvironmentChangeEvent` 手动处理 | 精确 | 否 | 框架级对象（线程池、客户端） | 代码量大 |

### 4.2 推荐：不可变配置对象 + 原子替换

对于"读多写少、要求零抖动"的参数，这个模式比 `@RefreshScope` 稳得多：

```java
@ConfigurationProperties(prefix = "app.ratelimit")
@Validated
public class RateLimitProperties {
    @Min(1) private int qps = 100;
    @Min(1) private int burst = 200;
    // getter / setter ...
}

@Component
public class RateLimitConfigHolder implements ApplicationListener<EnvironmentChangeEvent> {

    private final AtomicReference<RateLimitProperties> ref = new AtomicReference<>();
    private final RateLimitProperties binderSource;

    public RateLimitConfigHolder(RateLimitProperties binderSource) {
        this.binderSource = binderSource;
        this.ref.set(copyOf(binderSource));
    }

    /** 每次读取都是 O(1)，且读到的一定是同一个快照 */
    public RateLimitProperties current() {
        return ref.get();
    }

    @Override
    public void onApplicationEvent(EnvironmentChangeEvent event) {
        if (event.getKeys().stream().noneMatch(k -> k.startsWith("app.ratelimit"))) {
            return;
        }
        RateLimitProperties fresh = copyOf(binderSource);
        // 校验失败就保留旧值，绝不把坏配置推上去
        ref.set(fresh);
        log.info("ratelimit refreshed: qps={} burst={}", fresh.getQps(), fresh.getBurst());
    }

    private RateLimitProperties copyOf(RateLimitProperties src) {
        RateLimitProperties p = new RateLimitProperties();
        p.setQps(src.getQps());
        p.setBurst(src.getBurst());
        return p;
    }
}
```

要点：

- **快照不可变**：读方拿到的对象不会被并发修改；
- **原子替换**：`AtomicReference.set` 保证所有线程看到同一个版本，不会"半刷新"；
- **先校验后生效**：坏配置不覆盖好配置，这是 `@RefreshScope` 做不到的（它会无条件重建）。

### 4.3 限流器的"平滑切换"

替换配置 ≠ 立即生效。令牌桶的容量变化如果处理不当，会出现"瞬间放量"或"瞬间归零"：

```java
public class SwitchableRateLimiter {
    private volatile RateLimiter delegate;

    public SwitchableRateLimiter(RateLimitProperties p) {
        this.delegate = build(p);
    }

    public boolean tryAcquire() {
        return delegate.tryAcquire();
    }

    /** 新桶预热：按新速率生成，但不继承旧桶的令牌，避免突刺 */
    public synchronized void switchTo(RateLimitProperties p) {
        RateLimiter next = build(p);
        RateLimiter old = this.delegate;
        this.delegate = next;
        // 旧桶自然过期即可，无需显式关闭
    }

    private RateLimiter build(RateLimitProperties p) {
        return RateLimiter.create(p.getQps());   // Guava
    }
}
```

## 五、上线检查清单

| 检查项 | 说明 |
|---|---|
| 是否有 `@RefreshScope` 用在有状态组件上 | 连接池、线程池、Netty bootstrap 都不该直接刷 |
| 刷新期间是否有并发流量 | 需要"新旧并存 + 原子切换"，不是"先销毁再创建" |
| 配置是否有校验 | 用 `@Validated` + 手工校验，坏配置要拒绝 |
| 刷新是否可回滚 | 保留上一版本，出问题能一键回退 |
| 是否有刷新审计日志 | 记录 key、旧值、新值、操作人、时间 |
| 刷新耗时是否可控 | 超过 3 秒要考虑异步化或拆分 scope |
| 监控是否覆盖 | 刷新次数、失败次数、刷新耗时、配置版本号 |

## 六、面试常见追问

**Q1：`@RefreshScope` 的 Bean 是单例吗？**
从调用方看是"逻辑单例"（同一个代理对象），但底层实例可以被销毁重建，所以生命周期不是标准 singleton。准确说它属于自定义 scope `refresh`，缓存由 `GenericScope` 管理。

**Q2：为什么必须用 CGLIB 代理，JDK 动态代理不行吗？**
类没有实现接口时 JDK 代理无法生成；Spring 默认 `TARGET_CLASS` 就是为了兼容无接口的类。你也可以显式指定 `proxyMode = ScopedProxyMode.INTERFACES`，但要求 Bean 必须实现接口。

**Q3：`@ConfigurationProperties` 需要加 `@RefreshScope` 吗？**
不需要。`ContextRefresher.refreshEnvironment()` 会调用 `ConfigurationPropertiesRebinder` 重新绑定，`@ConfigurationProperties` Bean 会被 rebind（本质是 destroy + 重新 initialize）。加了 `@RefreshScope` 反而可能因为代理与 rebind 的顺序产生意外。

**Q4：刷新会导致 `@PostConstruct` 重复执行吗？**
会。Bean 重建时完整的生命周期会再走一遍：构造 → 属性注入 → `@PostConstruct` → `InitializingBean.afterPropertiesSet`。所以初始化逻辑必须**幂等**，且要能承受重复执行。

**Q5：多个实例同时收到配置变更，会不会不一致？**
会有短暂窗口。Nacos 的推送是逐实例的，各实例刷新时间不同，可能出现"实例 A 已用新值、实例 B 还在旧值"。对强一致要求的开关，应加版本号校验或走"配置灰度 + 双读比对"。

## 七、总结

1. `@RefreshScope` 的本质是 **代理 + 可清空的 scope 缓存**，它刷新的是"Bean 实例"，不是"字段"。
2. 刷新链路是 `EnvironmentChangeEvent → ContextRefresher → refreshEnvironment() → scope.refreshAll() → destroy() → 重建`，其中 `@ConfigurationProperties` 走的是 rebind，不依赖 refresh scope。
3. **重建有副作用**：`@PostConstruct` 重跑、线程池重建、连接中断、刷新期间的并发请求可能读到新旧混合状态。
4. 生产上优先用"**不可变快照 + 原子替换 + 校验**"，把 `@RefreshScope` 留给真正无状态、重建代价低的组件。

配置动态化不是"加个注解"就完事，它本质上是在运行时修改一个正在运行的系统。想清楚"谁持有引用、重建时旧对象怎么办、坏配置怎么回滚"，比记住注解的名字重要得多。
