---
title: 【Spring 源码】Spring 扩展点全景深度解析：BeanPostProcessor、BeanFactoryPostProcessor、Aware 与 InitializingBean 的执行时机
date: 2026-10-09 08:20:00
tags:
  - Java
  - Spring
  - 源码
  - Bean 生命周期
  - 面试
categories:
  - Java
  - Spring 源码
author: 东哥
---

# 【Spring 源码】Spring 扩展点全景深度解析：BeanPostProcessor、BeanFactoryPostProcessor、Aware 与 InitializingBean 的执行时机

## 面试官：如果让你在 Spring 启动时"动点手脚"，你能用哪些扩展点？

大多数人只答得出"`BeanPostProcessor`"，再深问一句就露馅：

- `BeanPostProcessor` 和 `BeanFactoryPostProcessor` 差在哪？
- `@Autowired` 是哪个扩展点干的活？
- `@PostConstruct` 和 `InitializingBean.afterPropertiesSet()` 谁先执行？
- `Aware` 接口为什么能拿到容器对象？
- `BeanPostProcessor` 里的 `postProcessBeforeInitialization` 和 `postProcessAfterInitialization` 分别被谁调用？
- 一个 Bean 的完整生命周期里，扩展点的**精确顺序**是什么？

这篇文章把 Spring 的扩展点体系梳理成一张图，并给出源码级执行顺序。

## 一、先分清两类后置处理器

这是最基础也最容易混的一对：

| 维度 | BeanFactoryPostProcessor (BFPP) | BeanPostProcessor (BPP) |
| --- | --- | --- |
| 作用对象 | **BeanDefinition**（配置元数据） | **Bean 实例** |
| 执行时机 | **所有 Bean 实例化之前** | 每个 Bean 实例化之后 |
| 典型用途 | 修改 Bean 定义、占位符替换 | AOP 代理、属性注入、生命周期回调 |
| 能否拿到实例 | 不能（此时还没有实例） | 能 |
| 典型实现 | `PropertySourcesPlaceholderConfigurer`、`ConfigurationClassPostProcessor` | `AutowiredAnnotationBeanPostProcessor`、`AnnotationAwareAspectJAutoProxyCreator` |

一句话记忆：**BFPP 改"配方"，BPP 改"成品"**。

```java
public interface BeanFactoryPostProcessor {
    void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory) throws BeansException;
}

public interface BeanPostProcessor {
    default Object postProcessBeforeInitialization(Object bean, String beanName) { return bean; }
    default Object postProcessAfterInitialization(Object bean, String beanName) { return bean; }
}
```

还有一个更强的变体 `BeanDefinitionRegistryPostProcessor`（继承 BFPP）：

```java
public interface BeanDefinitionRegistryPostProcessor extends BeanFactoryPostProcessor {
    // 在普通 BFPP 之前执行，可以往容器里注册新的 BeanDefinition
    void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) throws BeansException;
}
```

`ConfigurationClassPostProcessor` 就是它——**扫描 `@Configuration`、`@ComponentScan`、`@Import` 生成 BeanDefinition 全靠它**。这也解释了为什么 `@ComponentScan` 能找到类：它不是 BPP 干的，而是 BFPP 阶段就完成了。

## 二、Aware 接口：让 Bean 感知容器

`Aware` 系列是"让 Bean 拿到容器基础设施"的钩子。它由 `ApplicationContextAwareProcessor`（一个 BPP）在 `postProcessBeforeInitialization` 里调用。

```java
public class MyBean implements BeanNameAware, ApplicationContextAware, EnvironmentAware {
    private String name;
    private ApplicationContext ctx;
    private Environment env;

    @Override public void setBeanName(String name) { this.name = name; }
    @Override public void setApplicationContext(ApplicationContext ctx) { this.ctx = ctx; }
    @Override public void setEnvironment(Environment env) { this.env = env; }
}
```

常见的 Aware 及用途：

| Aware | 拿到什么 |
| --- | --- |
| BeanNameAware | 自己在容器里的名字 |
| BeanClassLoaderAware | 加载该 Bean 的 ClassLoader |
| BeanFactoryAware | 当前的 BeanFactory |
| EnvironmentAware | Environment（属性 + Profile） |
| ResourceLoaderAware | 资源加载器 |
| ApplicationEventPublisherAware | 事件发布器 |
| ApplicationContextAware | 应用上下文 |
| MessageSourceAware | 国际化消息源 |

注意：`ApplicationContextAwareProcessor` 是个 `BeanPostProcessor`，它能拿到 beanFactory 并注入 context——**这也说明 BPP 阶段能做的事比想象的多**。

## 三、初始化回调：@PostConstruct / afterPropertiesSet / init-method

一个 Bean「属性注入完成之后」要经历三个初始化回调，顺序固定：

```
1. @PostConstruct（由 CommonAnnotationBeanPostProcessor 调用）
2. InitializingBean.afterPropertiesSet()
3. 自定义 init-method（@Bean(initMethod = "...") 或 <bean init-method>）
```

源码依据在 `AbstractAutowireCapableBeanFactory#initializeBean`：

```java
protected Object initializeBean(String beanName, Object bean, @Nullable RootBeanDefinition mbd) {
    // 1. Aware 回调
    invokeAwareMethods(beanName, bean);

    Object wrappedBean = bean;
    if (mbd == null || !mbd.isSynthetic()) {
        // 2. BPP 前置
        wrappedBean = applyBeanPostProcessorsBeforeInitialization(wrappedBean, beanName);
    }

    try {
        // 3. 初始化方法（@PostConstruct 在这里由 BPP 触发；afterPropertiesSet、init-method）
        invokeInitMethods(beanName, wrappedBean, mbd);
    } catch (Throwable ex) {
        throw new BeanCreationException(...);
    }

    if (mbd == null || !mbd.isSynthetic()) {
        // 4. BPP 后置（AOP 代理通常在这里生成）
        wrappedBean = applyBeanPostProcessorsAfterInitialization(wrappedBean, beanName);
    }
    return wrappedBean;
}
```

`invokeInitMethods` 的实现：

```java
protected void invokeInitMethods(String beanName, Object bean, @Nullable RootBeanDefinition mbd) throws Throwable {
    boolean isInitializingBean = (bean instanceof InitializingBean);
    if (isInitializingBean && (mbd == null || !mbd.isExternallyManagedInitMethod("afterPropertiesSet"))) {
        ((InitializingBean) bean).afterPropertiesSet();       // 第二步
    }
    if (mbd != null && bean.getClass() != NullBean.class) {
        String initMethodName = mbd.getInitMethodName();
        if (StringUtils.hasLength(initMethodName)
                && (!isInitializingBean || !"afterPropertiesSet".equals(initMethodName))
                && !mbd.isExternallyManagedInitMethod(initMethodName)) {
            invokeCustomInitMethod(beanName, bean, mbd);       // 第三步
        }
    }
}
```

而 `@PostConstruct` 是由 `CommonAnnotationBeanPostProcessor` 在 **beforeInitialization** 阶段执行的：

```java
// InitDestroyAnnotationBeanPostProcessor#postProcessBeforeInitialization
public Object postProcessBeforeInitialization(Object bean, String beanName) {
    LifecycleMetadata metadata = findLifecycleMetadata(bean.getClass());
    metadata.invokeInitMethods(bean, beanName);   // 反射调用 @PostConstruct
    return bean;
}
```

**所以完整顺序是：Aware → BPP.before → @PostConstruct → afterPropertiesSet → init-method → BPP.after。**

## 四、一个 Bean 的完整生命周期（含扩展点）

这是面试必背的"全流程图"：

```
【1】BeanDefinition 加载
      ├─ 扫描 / 解析 XML / @Bean 方法
      └─ BeanFactoryPostProcessor.postProcessBeanFactory      ← 扩展点①
              └─ BeanDefinitionRegistryPostProcessor           ← 扩展点①'

【2】实例化（反射 new / 工厂）
      ├─ InstantiationAwareBeanPostProcessor.postProcessBeforeInstantiation  ← 扩展点②
      ├─ 构造器选择 / 构造器注入
      └─ InstantiationAwareBeanPostProcessor.postProcessAfterInstantiation   ← 扩展点③
      └─ postProcessProperties（@Autowired / @Resource 注入）                 ← 扩展点④

【3】初始化
      ├─ invokeAwareMethods（BeanNameAware / BeanFactoryAware / ...）         ← 扩展点⑤
      ├─ BeanPostProcessor.postProcessBeforeInitialization                    ← 扩展点⑥
      ├─ @PostConstruct
      ├─ InitializingBean.afterPropertiesSet()
      ├─ 自定义 init-method
      └─ BeanPostProcessor.postProcessAfterInitialization（AOP 代理在此生成）   ← 扩展点⑦

【4】使用（被注入到其他 Bean / 被 getBean）

【5】销毁
      ├─ @PreDestroy
      ├─ DisposableBean.destroy()
      └─ 自定义 destroy-method
```

对照常用的 `InstantiationAwareBeanPostProcessor`：

```java
public interface InstantiationAwareBeanPostProcessor extends BeanPostProcessor {
    // 实例化前：返回非 null 就"抢先"造出对象，跳过常规实例化（AOP 的 TargetSource 会用到）
    default Object postProcessBeforeInstantiation(Class<?> beanClass, String beanName) { return null; }
    // 实例化后、属性注入前
    default boolean postProcessAfterInstantiation(Object bean, String beanName) { return true; }
    // 属性注入（@Autowired 在这里完成）
    default PropertyValues postProcessProperties(PropertyValues pvs, Object bean, String beanName) { return pvs; }
}
```

`@Autowired` 的注入流程就在 `AutowiredAnnotationBeanPostProcessor`（实现 `SmartInstantiationAwareBeanPostProcessor`）的 `postProcessProperties` 里。

## 五、@Configuration 为什么用 CGLIB 代理

顺带说一个必考延伸点：`@Configuration` 里的 `@Bean` 方法互调为什么返回同一个对象？

```java
@Configuration
public class AppConfig {
    @Bean public A a() { return new A(b()); }   // 直接调 b()，不是新对象
    @Bean public B b() { return new B(); }
}
```

因为 `ConfigurationClassPostProcessor` 会把 `@Configuration` 类**注册为 `BeanDefinition` 时标记为 full 模式**，再由 `ConfigurationClassEnhancer` 生成 CGLIB 子类。调用 `b()` 时被 `BeanMethodInterceptor` 拦截，先从容器找 `b` 这个 Bean，找不到才真正调用 `super.b()`。

对比：

| 模式 | 条件 | 是否有 CGLIB 代理 | `@Bean` 方法互调 |
| --- | --- | --- | --- |
| full | 类上有 `@Configuration` | 是 | 返回容器单例 |
| lite | 有 `@Component` 或没有注解 | 否 | 每次调用都新建 |

这就是"`@Configuration` 少了注解会导致多例"的根因。

## 六、实战：用扩展点做无侵入监控

需求：统计每个 Service 方法的执行耗时，不改业务代码。

方案 A：`BeanPostProcessor` + 动态代理

```java
@Component
public class TimingBeanPostProcessor implements BeanPostProcessor {

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        if (!bean.getClass().isAnnotationPresent(Service.class)) {
            return bean;
        }
        return Proxy.newProxyInstance(
                bean.getClass().getClassLoader(),
                bean.getClass().getInterfaces(),
                (proxy, method, args) -> {
                    long start = System.nanoTime();
                    try {
                        return method.invoke(bean, args);
                    } catch (InvocationTargetException e) {
                        throw e.getTargetException();
                    } finally {
                        Metrics.record(beanName, method.getName(), System.nanoTime() - start);
                    }
                });
    }
}
```

⚠️ 坑：JDK 动态代理要求**有接口**；无接口要用 CGLIB；且 BPP 返回的代理对象会影响后续 BPP（多个 BPP 会串行包装）。

方案 B：改 BeanDefinition（BFPP）——注册一个自己的 `BeanPostProcessor`

```java
public class MyBeanDefinitionRegistryPostProcessor implements BeanDefinitionRegistryPostProcessor {
    @Override
    public void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) {
        // 动态注册一个 Bean
        BeanDefinition bd = BeanDefinitionBuilder
                .genericBeanDefinition(MonitorBpp.class)
                .getBeanDefinition();
        registry.registerBeanDefinition("monitorBpp", bd);
    }
    @Override
    public void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory) { }
}
```

方案 C：只做属性注入阶段的加工 —— `InstantiationAwareBeanPostProcessor#postProcessProperties`。

选择原则：

| 目标 | 用哪个扩展点 |
| --- | --- |
| 改配置 / 批量改 Bean 定义 | BFPP / BeanDefinitionRegistryPostProcessor |
| 实例化前替换对象（如 TargetSource） | `postProcessBeforeInstantiation` |
| 自定义属性注入（类 `@Value`） | `postProcessProperties` |
| 初始化前后增强（代理、日志、埋点） | BPP 的 before / after |
| 感知容器、获取上下文 | Aware 接口 |
| 初始化后校验（如必须实现的接口） | `afterPropertiesSet` / `@PostConstruct` |
| 销毁清理 | `@PreDestroy` / `DisposableBean` |

## 七、高频坑

| 坑 | 说明 | 规避 |
| --- | --- | --- |
| BFPP 里注入其他 Bean | BFPP 实例化早，此时 BPP 还没注册，注入可能为 null | 用 `@Bean static` 方法声明，或延迟到 BPP |
| BPP 里注入业务 Bean | BPP 对**所有** Bean 生效，包括它自己依赖的 Bean，容易循环/警告 | 不要依赖业务 Bean；需要时用 ObjectProvider 延迟获取 |
| BPP 返回的代理被多次包装 | 多个 BPP 顺序执行，`postProcessAfterInitialization` 会层层代理 | 用 `AopUtils` 判断是否已是代理 |
| `@PostConstruct` 执行时属性为 null | 如果调用了父类/未注入的字段 | 确认注入已完成（BPP before 阶段属性已注入） |
| BPP 中 `bean.getClass()` 不是原始类 | 已是代理类 | 用 `AopProxyUtils.ultimateTargetClass` |
| `@Configuration` 写成 `@Component` | lite 模式，`@Bean` 互调产生多例 | 保持 `@Configuration` |
| `ApplicationContextAware` 拿不到 context | 手动 new 出来的 Bean 不走容器 | 交给容器管理 |

一个特别值得说：**BPP 本身也必须由容器创建，且它的实例化早于普通 Bean**。Spring 会先把所有 BPP 注册好（`registerBeanPostProcessors`），再逐个创建业务 Bean。所以 BPP 内部**不能依赖普通业务 Bean**，否则会因为顺序问题拿不到。

```java
// 错误示范
@Component
public class BadBpp implements BeanPostProcessor {
    @Autowired private UserService userService;   // 可能为 null / 报错
}

// 正确做法：延迟获取
@Component
public class GoodBpp implements BeanPostProcessor {
    @Autowired private ObjectProvider<UserService> userServiceProvider;
    // 真正使用时再 getObject()
}
```

## 八、面试追问

**Q1：`BeanPostProcessor` 和 `BeanFactoryPostProcessor` 谁先执行？**

BFPP 先。执行顺序是：`BeanDefinitionRegistryPostProcessor` → `BeanFactoryPostProcessor` → 注册 `BeanPostProcessor` → 实例化普通 Bean（期间执行 BPP）。

**Q2：`@PostConstruct` 是 Spring 实现的还是 JDK 的？**

注解来自 `jakarta.annotation`（旧版 `javax.annotation`），但**调用者是 Spring**——`CommonAnnotationBeanPostProcessor` 在 `postProcessBeforeInitialization` 里通过反射调用。JDK 9+ 移除了 `javax.annotation`，所以要显式引入依赖。

**Q3：AOP 代理是什么时候生成的？**

在 BPP 的 `postProcessAfterInitialization` 阶段，由 `AbstractAutoProxyCreator`（`AnnotationAwareAspectJAutoProxyCreator`）生成。这也意味着：**代理对象是在初始化完成后才替换掉的**，所以 `@PostConstruct` 里 `this` 还不是代理。

**Q4：能不能让 BPP 只对特定 Bean 生效？**

能，但要注意 BPP 的 `postProcess*` 会收到所有 Bean。做法是在方法里判断 `beanName` 或注解，不满足就原样返回。若确定只对某些 Bean 生效，也可实现 `beanClassLoader` / 判断条件提前 return。

**Q5：`SmartInitializingSingleton` 和 `afterPropertiesSet` 区别？**

`afterPropertiesSet` 是**每个 Bean 自己**初始化完就调用（单 Bean 粒度）；`SmartInitializingSingleton.afterSingletonsInstantiated()` 是**所有单例都实例化完之后**由容器统一回调（全局粒度）。做"全局校验/预热"用后者，做"单个 Bean 自身初始化"用前者。

## 九、小结

- **BFPP 改 BeanDefinition（配方），BPP 改 Bean 实例（成品）**；`BeanDefinitionRegistryPostProcessor` 是 BFPP 的增强版，负责扫描注册。
- **一个 Bean 的初始化顺序**：Aware → `BPP.before` → `@PostConstruct` → `afterPropertiesSet` → `init-method` → `BPP.after`。
- **`@Autowired` 在 `postProcessProperties` 完成，AOP 代理在 `postProcessAfterInitialization` 生成**。
- **`@Configuration` 用 CGLIB 代理实现 `@Bean` 互调返回单例**，这是 full/lite 的本质区别。
- **BPP 不要依赖业务 Bean**，否则顺序问题会咬你一口。
- 按"要改配方还是改成品、要增强哪个阶段"来选择扩展点，才不会用错。

扩展点是 Spring "可扩展性"的设计精髓。记住每个扩展点的**精确时机**，比记住它的名字重要得多。
