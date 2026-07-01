---
title: 【Spring 源码】Spring Boot 容器刷新源码解析：从 run() 到 refresh() 全流程
date: 2026-07-01 08:00:00
tags:
  - Spring Boot
  - 源码
  - IoC
  - 面试
categories:
  - Spring
  - 框架源码
author: 东哥
---

# 【Spring 源码】Spring Boot 容器刷新源码解析：从 run() 到 refresh() 全流程

## 前言

「Spring Boot 启动时发生了什么？」——这是面试中最高频的问题之一。很多人的回答止步于「@SpringBootApplication 和自动配置」。但实际上，Spring Boot 的启动流程远不止这些，它的核心是 **ApplicationContext 的刷新（refresh）过程**。

本文将从 `SpringApplication.run()` 入口出发，逐层解剖到 `AbstractApplicationContext.refresh()`，带你走完 Spring Boot 启动的全流程。

---

## 一、入口：SpringApplication.run()

```java
@SpringBootApplication
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
```

这个看似简单的入口，内部执行了以下步骤：

```java
// SpringApplication.run() 核心逻辑
public ConfigurableApplicationContext run(String... args) {
    StopWatch stopWatch = new StopWatch();
    stopWatch.start();
    
    // 1. 启动计时器
    // 2. 配置 Headless 模式
    // 3. 启动事件监听器（SpringApplicationRunListeners）
    
    // 4. 准备环境（Environment）
    ConfigurableEnvironment environment = prepareEnvironment(listeners, applicationArguments);
    
    // 5. 创建 ApplicationContext
    context = createApplicationContext();
    
    // 6. 刷新容器（核心！）
    refreshContext(context);
    
    // 7. 刷新后的回调
    afterRefresh(context, applicationArguments);
    
    stopWatch.stop();
    return context;
}
```

我们今天的主角就是 **第 6 步 —— refreshContext**，它最终调用 `AbstractApplicationContext.refresh()`。

---

## 二、refresh() 方法的 12 个步骤

`refresh()` 定义在 `AbstractApplicationContext` 中，是整个 IoC 容器初始化的核心。我们逐行解析：

```java
@Override
public void refresh() throws BeansException, IllegalStateException {
    synchronized (this.startupShutdownMonitor) {
        // 1. 容器刷新前的准备工作
        prepareRefresh();

        // 2. 获取 BeanFactory（在子类中创建）
        ConfigurableListableBeanFactory beanFactory = obtainFreshBeanFactory();

        // 3. 为 BeanFactory 配置标准特性
        prepareBeanFactory(beanFactory);

        // 4. 允许子类在 BeanFactory 构建完成后做额外处理
        postProcessBeanFactory(beanFactory);

        // 5. 调用 BeanFactoryPostProcessor（核心！）
        invokeBeanFactoryPostProcessors(beanFactory);

        // 6. 注册 BeanPostProcessor
        registerBeanPostProcessors(beanFactory);

        // 7. 初始化 MessageSource（国际化）
        initMessageSource();

        // 8. 初始化事件广播器
        initApplicationEventMulticaster();

        // 9. 初始化特殊 Bean（模板方法，子类实现）
        onRefresh();

        // 10. 注册事件监听器
        registerListeners();

        // 11. 实例化所有非懒加载的单例 Bean（最关键的步骤！）
        finishBeanFactoryInitialization(beanFactory);

        // 12. 完成刷新，发布事件
        finishRefresh();
    }
}
```

### 步骤详解

#### ① prepareRefresh() — 刷新准备

- 设置容器启动时间
- 设置活跃状态标志
- 初始化属性源（PropertySource）
- 准备监听器和相关事件

#### ② obtainFreshBeanFactory() — 获取 BeanFactory

对于 `AnnotationConfigServletWebServerApplicationContext`（Spring Boot 默认上下文）：

- 创建一个 `DefaultListableBeanFactory`
- 读取配置类（主启动类上的注解）

#### ③ prepareBeanFactory(beanFactory) — 配置 BeanFactory

关键操作：

```java
protected void prepareBeanFactory(ConfigurableListableBeanFactory beanFactory) {
    // 设置 ClassLoader
    beanFactory.setBeanClassLoader(getClassLoader());
    // 注册默认的 BeanPostProcessor
    beanFactory.addBeanPostProcessor(new ApplicationContextAwareProcessor(this));
    // 注册特殊的 Aware 接口——自动注入
    beanFactory.registerResolvableDependency(BeanFactory.class, beanFactory);
    beanFactory.registerResolvableDependency(ResourceLoader.class, this);
    beanFactory.registerResolvableDependency(ApplicationEventPublisher.class, this);
    beanFactory.registerResolvableDependency(ApplicationContext.class, this);
    // 注册内置 Bean
    beanFactory.registerSingleton(ENVIRONMENT_BEAN_NAME, getEnvironment());
    // ... 其他配置
}
```

**重点**：`ApplicationContextAwareProcessor` 负责处理所有 `XxxAware` 接口回调（`ApplicationContextAware`、`EnvironmentAware` 等）。

#### ④ postProcessBeanFactory(beanFactory) — 子类扩展

`AnnotationConfigServletWebServerApplicationContext` 在这里注册与 **Servlet Web 容器** 相关的配置。

#### ⑤ invokeBeanFactoryPostProcessors(beanFactory) — BeanFactory 后置处理器 【核心】

这是 **Spring Boot 自动配置的核心环节**。会按优先级执行各种 `BeanDefinitionRegistryPostProcessor` 和 `BeanFactoryPostProcessor`：

```java
// 流程：
// 1. 处理 BeanDefinitionRegistryPostProcessor（可注册新的 BeanDefinition）
//    重要实现：ConfigurationClassPostProcessor
//    它解析 @Configuration 类，扫描 @ComponentScan、@Import、@Bean 等注解
//    这也是自动配置 @EnableAutoConfiguration 被处理的时刻！
//
// 2. 处理 BeanFactoryPostProcessor（可修改 BeanDefinition 属性）
```

**ConfigurationClassPostProcessor 自动配置加载流程**：

```
@SpringBootApplication
  → @EnableAutoConfiguration
    → @Import(AutoConfigurationImportSelector.class)
      → 读取 META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
        → 加载 130+ auto-configuration 类（条件化加载 @ConditionalOnXxx）
```

#### ⑥ registerBeanPostProcessors(beanFactory) — 注册 BeanPostProcessor

注册所有 `BeanPostProcessor`，分为四类按优先级排序：

```java
// 优先级：MERGED_BEAN_DEFINITION_PRIORITY（ProrityOrdered > Ordered > 普通）
// 关键实现：
// AutowiredAnnotationBeanPostProcessor → 处理 @Autowired、@Value
// CommonAnnotationBeanPostProcessor → 处理 @Resource、@PostConstruct
// AbstractAutoProxyCreator → AOP 代理创建的核心
```

#### ⑦ ⑧ initMessageSource / initApplicationEventMulticaster

- `initMessageSource()`：初始化国际化资源处理器
- `initApplicationEventMulticaster()`：初始化事件广播器（`SimpleApplicationEventMulticaster`）

#### ⑨ onRefresh() — 子类定制刷新

对于 Spring Boot Web 应用，这里会 **创建内嵌的 Web 服务器**（Tomcat / Jetty / Undertow）：

```java
// ServletWebServerApplicationContext.onRefresh()
protected void onRefresh() {
    super.onRefresh();
    try {
        createWebServer(); // 创建内嵌 Web 容器
    } catch (Throwable ex) {
        throw new ApplicationContextException("Unable to start web server", ex);
    }
}
```

这意味着 **内嵌 Tomcat 在 Bean 实例化之前就已经创建**。

#### ⑩ registerListeners() — 注册事件监听器

将所有实现了 `ApplicationListener` 接口的 Bean 注册到事件广播器中。

#### ⑪ finishBeanFactoryInitialization(beanFactory) — 实例化所有非懒加载单例 Bean 【最关键】

```java
protected void finishBeanFactoryInitialization(ConfigurableListableBeanFactory beanFactory) {
    // 实例化所有非懒加载的单例 Bean
    beanFactory.preInstantiateSingletons();
}
```

执行流程：
1. 遍历所有 BeanDefinition
2. 过滤出非抽象、单例、非懒加载的 Bean
3. 调用 `getBean()` → `doGetBean()` → `createBean()` → `doCreateBean()`
4. 经过三级缓存处理循环依赖
5. 执行 `BeanPostProcessor` 的前后处理 → 包括 AOP 代理生成

#### ⑫ finishRefresh() — 完成刷新

- 清除上下文资源缓存
- 初始化 `LifecycleProcessor`
- 调用生命周期回调
- 发布 `ContextRefreshedEvent`

---

## 三、整体流程时间线

```
时间线 →
┌─────────────────────────────────────────────────────┐
│ SpringApplication.run()                              │
│  ├─ prepareEnvironment()      ← 加载外部配置          │
│  ├─ createApplicationContext() ← 创建上下文           │
│  └─ refreshContext()          ← 刷新容器（核心）      │
│       └─ AbstractApplicationContext.refresh()        │
│           ├─ prepareRefresh()                        │
│           ├─ obtainFreshBeanFactory()  ← 创建 BeanFactory│
│           ├─ prepareBeanFactory()   ← 配置 BeanFactory│
│           ├─ postProcessBeanFactory() ← Web 容器初始化│
│           ├─ invokeBeanFactoryPostProcessors() ← 自动配置│
│           ├─ registerBeanPostProcessors()  ← AOP准备  │
│           ├─ initMessageSource()  ← 国际化             │
│           ├─ initApplicationEventMulticaster() ← 事件   │
│           ├─ onRefresh()  ← 创建 Tomcat（Web应用）      │
│           ├─ registerListeners() ← 注册监听器          │
│           ├─ finishBeanFactoryInitialization() ← 实例化全部 Bean
│           └─ finishRefresh() ← 完成并发布事件           │
└─────────────────────────────────────────────────────┘
```

---

## 四、面试官追问清单

**Q1：自动配置的加载发生在哪个步骤？**

`invokeBeanFactoryPostProcessors()` 中的 `ConfigurationClassPostProcessor` 负责解析 `@EnableAutoConfiguration`，加载 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 中的自动配置类。

**Q2：Bean 的实例化发生在哪一步？**

`finishBeanFactoryInitialization()`。之前都只是注册 BeanDefinition（配置元数据），真正的创建 Bean 对象在此步骤完成。

**Q3：内嵌 Tomcat 是在什么时候启动的？**

`onRefresh()` 步骤。在 Bean 实例化之前就已经创建了内嵌 Web 容器。这样设计的原因是让 Tomcat 在 Bean 实例化期间就能提供服务。

**Q4：有哪些方式可以在容器刷新过程中插入自定义逻辑？**

| 扩展点 | 对应步骤 | 典型用途 |
|:-----:|:-------:|---------|
| `ApplicationContextInitializer` | run() 前期 | 修改 Environment |
| `BeanFactoryPostProcessor` | step ⑤ | 修改 BeanDefinition |
| `BeanPostProcessor` | step ⑥ + ⑪ | 修改 Bean 实例（AOP） |
| `ApplicationListener` | step ⑩ | 监听容器事件 |
| `SmartLifecycle` | step ⑫ | 启动后执行业务逻辑 |

---

## 总结

Spring Boot 的启动流程，核心可以概括为 **三个环节**：

1. **准备阶段**（run 的前半段）：加载配置、创建上下文
2. **配置阶段**（refresh 的前半段）：解析注解、加载自动配置、为容器注入组件定义
3. **实例化阶段**（refresh 的后半段）：创建 Bean 对象、启动 Web 容器、发布启动事件

理解了这个流程，你就会明白为什么 Spring Boot 能「开箱即用」——因为 `invokeBeanFactoryPostProcessors` 在 Bean 实例化之前就已经把所有配置类的定义加载好了。剩下的就是按图索骥，把一个个 Bean 造出来。

> 读源码不是为了背步骤，而是理解背后的设计思想——模板方法模式贯穿了整个 refresh()，每一处模板方法都是留给扩展点的。这就是 Spring 的优雅所在。
