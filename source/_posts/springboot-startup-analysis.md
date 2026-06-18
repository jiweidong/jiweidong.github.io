---
title: Spring Boot 启动流程深度解析
date: 2026-06-18 08:00:00
author: 东哥
categories:
  - Spring框架
tags:
  - Spring
  - SpringBoot
  - 启动流程
  - 源码分析
  - 容器
---

## 前言

Spring Boot 让开发变简单了——一个 `main` 方法就能启动一个完整应用。但 `@SpringBootApplication` 和 `SpringApplication.run()` 背后到底发生了什么？

本文将带你从入口到容器完全初始化，完整走一遍启动流程。

---

## 一、入口：@SpringBootApplication

```java
@SpringBootApplication
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
```

`@SpringBootApplication` 是一个复合注解，包含三个核心注解：

```java
@SpringBootConfiguration   // 本质是 @Configuration
@EnableAutoConfiguration   // 开启自动配置
@ComponentScan             // 组件扫描
```

### 1.1 @SpringBootConfiguration

标记当前类为配置类，实际上是 `@Configuration` 的别名。

### 1.2 @EnableAutoConfiguration

这是 Spring Boot 的灵魂——自动配置的入口。其核心通过 `@Import(AutoConfigurationImportSelector.class)` 来加载所有自动配置类。

### 1.3 @ComponentScan

默认扫描当前主类所在包及其子包。可以通过 `basePackages` 或 `basePackageClasses` 指定扫描范围。

---

## 二、SpringApplication.run() 完整流程

```java
public static ConfigurableApplicationContext run(Class<?> primarySource, String... args) {
    return new SpringApplication(primarySource).run(args);
}
```

分为两个阶段：**构造 SpringApplication** 和 **执行 run 方法**。

### 2.1 构造阶段

`new SpringApplication(primarySource)` 做了这些事：

1. **判断应用类型**（Reactive / Servlet / None）
2. 从 `spring.factories` 加载 **ApplicationContextInitializer**
3. 从 `spring.factories` 加载 **ApplicationListener**
4. **推断主启动类**（通过堆栈找到有 main 方法的类）

```java
public SpringApplication(ResourceLoader resourceLoader, Class<?>... primarySources) {
    // 1. 判断 Web 应用类型
    this.webApplicationType = WebApplicationType.deduceFromClasspath();

    // 2. 加载初始化器
    setInitializers((Collection) getSpringFactoriesInstances(ApplicationContextInitializer.class));

    // 3. 加载监听器
    setListeners((Collection) getSpringFactoriesInstances(ApplicationListener.class));

    // 4. 推断主类
    this.mainApplicationClass = deduceMainApplicationClass();
}
```

### 2.2 run 方法执行阶段

```java
public ConfigurableApplicationContext run(String... args) {
    // 1. 计时器启动
    StopWatch stopWatch = new StopWatch();
    stopWatch.start();

    // 2. 创建引导上下文
    DefaultBootstrapContext bootstrapContext = createBootstrapContext();

    // 3. 配置 headless 属性
    configureHeadlessProperty();

    // 4. 获取并启动 SpringApplicationRunListener
    SpringApplicationRunListeners listeners = getRunListeners(args);
    listeners.starting(bootstrapContext);

    try {
        // 5. 准备环境变量
        ApplicationArguments applicationArguments = new DefaultApplicationArguments(args);
        ConfigurableEnvironment environment = prepareEnvironment(listeners, bootstrapContext, applicationArguments);

        // 6. 打印 Banner
        printBanner(environment);

        // 7. 创建 ApplicationContext
        context = createApplicationContext();

        // 8. 准备上下文（核心阶段）
        prepareContext(bootstrapContext, context, environment, listeners, applicationArguments, printedBanner);

        // 9. 刷新上下文（最核心）
        refreshContext(context);

        // 10. 刷新后回调
        afterRefresh(context, applicationArguments);

        // 11. 计时结束，打印启动时间
        stopWatch.stop();

        // 12. 发出 started 事件
        listeners.started(context);

        // 13. 调用 Runner
        callRunners(context, applicationArguments);

        // 14. 发出 ready 事件
        listeners.ready(context, applicationArguments);

    } catch (Throwable ex) {
        // 异常处理，调用 failed
        handleRunFailure(context, ex, listeners);
        throw new IllegalStateException(ex);
    }

    return context;
}
```

---

## 三、关键阶段深度剖析

### 3.1 准备环境 — prepareEnvironment

此阶段加载配置属性，构建 `ConfigurableEnvironment`：

```java
private ConfigurableEnvironment prepareEnvironment(
        SpringApplicationRunListeners listeners,
        DefaultBootstrapContext bootstrapContext,
        ApplicationArguments applicationArguments) {

    // 创建环境对象（StandardServletEnvironment）
    ConfigurableEnvironment environment = createEnvironment();

    // 配置 PropertySource 和 Profile
    configureEnvironment(environment, applicationArguments.getSourceArgs());

    // 通知监听器
    listeners.environmentPrepared(bootstrapContext, environment);

    // 将 Spring 属性绑定到环境
    bindToSpringApplication(environment);

    return environment;
}
```

这个过程确保：
- **命令行参数** 优先级最高
- **application.yml/properties** 被正确加载
- **Profile 特定配置** 按激活的 profile 加载
- **OS 环境变量** 也被纳入

### 3.2 准备上下文 — prepareContext

这是连接环境和容器的桥梁：

```java
private void prepareContext(DefaultBootstrapContext bootstrapContext,
        ConfigurableApplicationContext context, ConfigurableEnvironment environment,
        SpringApplicationRunListeners listeners,
        ApplicationArguments applicationArguments, Banner printedBanner) {

    // 设置环境
    context.setEnvironment(environment);

    // Bean 名称生成器
    context.setBeanNameGenerator(getBeanNameGenerator());

    // 应用初始化器
    applyInitializers(context);

    // 通知监听器
    listeners.contextPrepared(context);

    // 注册启动参数 bean
    context.getBeanFactory().registerSingleton("springApplicationArguments", applicationArguments);

    // 注册 Banner
    if (printedBanner != null) {
        context.getBeanFactory().registerSingleton("springBootBanner", printedBanner);
    }

    // 加载启动类作为配置类
    Set<Object> sources = getAllSources();
    load(context, sources.toArray(new Object[0]));

    // 通知监听器
    listeners.contextLoaded(context);
}
```

### 3.3 刷新上下文 — refreshContext（核心中的核心）

这一步实际上调用的是 `AbstractApplicationContext.refresh()`：

```java
@Override
public void refresh() throws BeansException, IllegalStateException {
    synchronized (this.startupShutdownMonitor) {
        // 1. 准备工作：记录状态、检查必要属性
        prepareRefresh();

        // 2. 获取 BeanFactory（Obtain fresh bean factory）
        ConfigurableListableBeanFactory beanFactory = obtainFreshBeanFactory();

        // 3. 准备 BeanFactory：设置类加载器、注册默认后置处理器
        prepareBeanFactory(beanFactory);

        try {
            // 4. 后置处理 BeanFactory（子类扩展点）
            postProcessBeanFactory(beanFactory);

            // 5. ★★★ 执行 BeanFactoryPostProcessor ★★★
            //    这里会调用 ConfigurationClassPostProcessor，
            //    解析 @Configuration，处理 @Import @ComponentScan 等
            invokeBeanFactoryPostProcessors(beanFactory);

            // 6. ★★ 注册 BeanPostProcessor ★★
            registerBeanPostProcessors(beanFactory);

            // 7. 初始化国际化资源
            initMessageSource();

            // 8. 初始化事件多播器
            initApplicationEventMulticaster();

            // 9. 创建特定 web 的 onRefresh（Tomcat 在此启动）
            onRefresh();

            // 10. 注册监听器
            registerListeners();

            // 11. ★★★ 实例化所有非懒加载单例 Bean ★★★
            finishBeanFactoryInitialization(beanFactory);

            // 12. 完成刷新：发布事件、启动 Lifecycle
            finishRefresh();

        } catch (BeansException ex) {
            // 销毁已创建的 bean
            destroyBeans();
            cancelRefresh(ex);
            throw ex;
        } finally {
            // 重置缓存
            resetCommonCaches();
        }
    }
}
```

其中 **第5步** 是最关键的——`invokeBeanFactoryPostProcessors` 在此解析所有 `@Configuration` 类，驱动自动配置加载。

### 3.4 自动配置加载时机

自动配置的核心类是 `AutoConfigurationImportSelector`，它在第5步 `invokeBeanFactoryPostProcessors` 中触发。

```java
public class AutoConfigurationImportSelector implements DeferredImportSelector {
    @Override
    public String[] selectImports(AnnotationMetadata annotationMetadata) {
        // 从 spring.factories 或 META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
        // 读取自动配置类列表
        AutoConfigurationEntry autoConfigurationEntry = getAutoConfigurationEntry(annotationMetadata);
        return StringUtils.toStringArray(autoConfigurationEntry.getConfigurations());
    }
}
```

读取到自动配置类列表后，会经过 **条件过滤**（`@Conditional` 系列注解），只有满足条件的配置类才会生效。

### 3.5 callRunners — 执行 Runner

刷新完成后，会执行两类 Runner：

```java
private void callRunners(ApplicationContext context, ApplicationArguments args) {
    List<Object> runners = new ArrayList<>();
    // 先执行 ApplicationRunner
    runners.addAll(context.getBeansOfType(ApplicationRunner.class).values());
    // 再执行 CommandLineRunner
    runners.addAll(context.getBeansOfType(CommandLineRunner.class).values());

    // 排序后依次执行
    AnnotationAwareOrderComparator.sort(runners);
    for (Object runner : runners) {
        if (runner instanceof ApplicationRunner) {
            ((ApplicationRunner) runner).run(args);
        }
        if (runner instanceof CommandLineRunner) {
            ((CommandLineRunner) runner).run(args.getArgs());
        }
    }
}
```

---

## 四、启动流程图

```
SpringApplication.run()
    │
    ├─ new SpringApplication() ────────────────────┐
    │    ├─ 推断 Web 应用类型                       │
    │    ├─ 加载 ApplicationContextInitializer     │
    │    ├─ 加载 ApplicationListener              │
    │    └─ 推断主启动类                           │
    │                                              │
    └─ .run() ───────────────────────────────────┘
         │
         ├─ 1. 创建 StopWatch
         ├─ 2. 创建 BootstrapContext
         ├─ 3. 配置 headless
         ├─ 4. 启动 RunListeners
         ├─ 5. 准备 Environment（配置加载）
         ├─ 6. 打印 Banner
         ├─ 7. 创建 ApplicationContext
         ├─ 8. prepareContext ───────────────┐
         │    ├─ 设置 Environment            │
         │    ├─ applyInitializers           │
         │    ├─ 注册启动参数 Bean           │
         │    └─ load 启动类                 │
         │                                   │
         ├─ 9. refreshContext ◄─────────────┘
         │    ├─ prepareRefresh
         │    ├─ obtainFreshBeanFactory
         │    ├─ prepareBeanFactory
         │    ├─ postProcessBeanFactory
         │    ├─ ★ invokeBeanFactoryPostProcessors  ← 自动配置在此加载
         │    ├─ registerBeanPostProcessors
         │    ├─ initMessageSource
         │    ├─ initApplicationEventMulticaster
         │    ├─ ★ onRefresh（嵌入式 Tomcat 启动）
         │    ├─ registerListeners
         │    ├─ ★ finishBeanFactoryInitialization（实例化单例）
         │    └─ ★ finishRefresh（发布事件）
         │
         ├─ 10. afterRefresh
         ├─ 11. 打印启动时间
         ├─ 12. listeners.started
         ├─ 13. callRunners（ApplicationRunner / CommandLineRunner）
         └─ 14. listeners.ready → 应用可用
```

---

## 五、面试核心要点

| 阶段 | 关键类 | 做了什么 |
|------|--------|----------|
| 构造 | `SpringApplication` | 推断类型、加载 SPI |
| 环境准备 | `StandardServletEnvironment` | 加载所有配置源 |
| 上下文准备 | `prepareContext` | 绑定环境、应用初始化器 |
| BeanFactory 后置 | `ConfigurationClassPostProcessor` | 解析配置类、触发自动配置 |
| Bean 实例化 | `DefaultListableBeanFactory` | 创建所有单例 Bean |
| Web 启动 | `ServletWebServerApplicationContext` | 内嵌 Tomcat/Jetty 启动 |
| 就绪 | `callRunners` | 执行自定义启动逻辑 |

---

## 六、常见问题

### 6.1 Spring Boot 启动慢怎么办？

- 懒加载：`spring.main.lazy-initialization=true`
- 排除不必要的自动配置：`@SpringBootApplication(exclude = {...})`
- 减少组件扫描范围、开启并行初始化

### 6.2 WebApplicationType 如何推断？

```java
static WebApplicationType deduceFromClasspath() {
    if (ClassUtils.isPresent("org.springframework.web.reactive.DispatcherHandler", null)
            && !ClassUtils.isPresent("org.springframework.web.servlet.DispatcherServlet", null)) {
        return WebApplicationType.REACTIVE;
    }
    // Servlet 优先
    for (String className : SERVLET_INDICATOR_CLASSES) {
        if (!ClassUtils.isPresent(className, null)) {
            return WebApplicationType.NONE;
        }
    }
    return WebApplicationType.SERVLET;
}
```

### 6.3 BootstrapContext 有什么用？

Spring Cloud 中用于早期配置加载（如配置中心），普通 Spring Boot 应用此处为空。

---

## 总结

Spring Boot 的启动流程虽然步骤多，但主线清晰：

1. **加载配置** → 2. **创建上下文** → 3. **解析配置类/自动配置** → 4. **创建 Bean** → 5. **启动 Web 服务器** → 6. **就绪回调**

理解了这个流程，任何 Spring Boot 启动异常你都能快速定位到问题出在哪个阶段。
