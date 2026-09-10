---
title: 【Spring 源码】@Configuration 全量与 Lite 模式深度解析：CGLIB 代理、@Bean 方法互调与配置类增强原理
date: 2026-09-10 08:00:00
tags:
  - Spring
  - 源码
  - 面试
categories:
  - Java
  - Spring
author: 东哥
---

# 【Spring 源码】@Configuration 全量与 Lite 模式深度解析：CGLIB 代理、@Bean 方法互调与配置类增强原理

## 面试官：@Configuration 和 @Component 有什么区别？为什么 @Configuration 里的 @Bean 方法互相调用不会创建多个实例？

很多同学写过这样的代码：

```java
@Configuration
public class AppConfig {

    @Bean
    public A a() {
        return new A(b());   // 方法互调，希望复用同一个 B 实例
    }

    @Bean
    public B b() {
        return new B();
    }
}
```

从容器里拿 `a` 和 `b`，二者持有的 `B` 是同一个对象——因为 Spring 对 `@Configuration` 类做了 **CGLIB 代理**，`b()` 方法被拦截后不是真的 new，而是"先查容器，容器没有才创建"。

但如果把 `@Configuration` 换成 `@Component`，同样代码 **B 会被创建两次**。这就是全量模式（Full）与 Lite 模式（Lite）的差别。本文从 `ConfigurationClassPostProcessor` 讲起，把两种模式的判定、增强原理和坑一次说清。

## 一、两种模式的官方定义

Spring 官方文档把配置类分为两类：

| 模式 | 判定条件 | 是否被 CGLIB 增强 | @Bean 方法互调 |
|---|---|---|---|
| Full（全量） | 类上标注 `@Configuration`（且 proxyBeanMethods=true） | 是 | 走容器，单例复用 |
| Lite（轻量） | 标了 `@Component` / `@ComponentScan` / `@Import` / `@ImportResource`，或方法上直接标 `@Bean` 的普通类 | 否 | 直接 new，每次新对象 |

**判定逻辑源码**：`ConfigurationClassUtils.checkConfigurationClassCandidate()` 里有一段非常直白的代码：

```java
// 类上标注了 @Configuration → Full 模式
if (isFullConfigurationCandidate(metadata)) {
    beanDef.setAttribute(CONFIGURATION_CLASS_ATTRIBUTE, CONFIGURATION_CLASS_FULL);
}
// 否则若满足 Lite 条件（@Component/@Import/@Bean 方法等）→ Lite 模式
else if (isLiteConfigurationCandidate(metadata)) {
    beanDef.setAttribute(CONFIGURATION_CLASS_ATTRIBUTE, CONFIGURATION_CLASS_LITE);
}
```

`isFullConfigurationCandidate` 的判断非常简单：`metadata.isAnnotated(Configuration.class.getName())`。

## 二、谁来做增强：ConfigurationClassPostProcessor

`ConfigurationClassPostProcessor` 是一个 **BeanDefinitionRegistryPostProcessor**（容器刷新早期执行），核心流程：

```
1. postProcessBeanDefinitionRegistry()
   └─> 找出所有配置类候选，标记 Full / Lite
2. postProcessBeanFactory()
   └─> 对每个 Full 模式配置类执行 enhanceConfigurationClasses()
```

### 2.1 增强的核心方法

```java
public void enhanceConfigurationClasses(ConfigurableListableBeanFactory beanFactory) {
    Map<String, AbstractBeanDefinition> configBeanDefs = new LinkedHashMap<>();
    // 遍历所有 BeanDefinition，只挑 CONFIGURATION_CLASS_ATTRIBUTE == FULL 的
    for (String beanName : beanFactory.getBeanDefinitionNames()) {
        BeanDefinition beanDef = beanFactory.getBeanDefinition(beanName);
        Object configClassAttr = beanDef.getAttribute(CONFIGURATION_CLASS_ATTRIBUTE);
        if (CONFIGURATION_CLASS_FULL.equals(configClassAttr)) {
            configBeanDefs.put(beanName, (AbstractBeanDefinition) beanDef);
        }
    }
    // 用 ConfigurationClassEnhancer 逐个增强
    ConfigurationClassEnhancer enhancer = new ConfigurationClassEnhancer();
    for (Map.Entry<String, AbstractBeanDefinition> entry : configBeanDefs.entrySet()) {
        AbstractBeanDefinition beanDef = entry.getValue();
        Class<?> configClass = beanDef.getBeanClass();
        Class<?> enhancedClass = enhancer.enhance(configClass, this.beanClassLoader);
        beanDef.setBeanClass(enhancedClass);   // 偷梁换柱：beanClass 换成增强后的子类
    }
}
```

注意最后一行：**容器里实际实例化的，是 CGLIB 生成的 @Configuration 子类**。

### 2.2 CGLIB 增强做了什么

`ConfigurationClassEnhancer` 用 CGLIB 生成配置类的子类，并添加三个 `Callback`：

| Callback | 作用 |
|---|---|
| `BeanMethodInterceptor` | 拦截 @Bean 方法：先查容器，没有才创建（保证单例/复用） |
| `BeanFactoryAwareMethodInterceptor` | 拦截 setBeanFactory 方法，注入 BeanFactory |
| `NoOp.INSTANCE` | 兜底，普通方法原样执行 |

`BeanMethodInterceptor.intercept()` 的简化逻辑：

```java
public Object intercept(Object enhancedConfigInstance, Method beanMethod,
                        Object[] beanMethodArgs, MethodProxy cglibMethodProxy) {
    ConfigurableBeanFactory beanFactory = getBeanFactory(enhancedConfigInstance);
    String beanName = BeanAnnotationHelper.determineBeanNameFor(beanMethod);

    // 1. 检查当前是否正处于该 @Bean 方法的创建过程中（防循环）
    if (isCurrentlyInvokedFactoryMethod(beanMethod)) {
        return cglibMethodProxy.invokeSuper(enhancedConfigInstance, beanMethodArgs);
    }

    // 2. 尝试从容器获取（单例 → getSingleton；scoped → 按 scope 获取）
    Object beanInstance = resolveBeanReference(beanMethod, beanMethodArgs, beanFactory, beanName);

    // 3. 取不到才真正调用父类方法 new 一个
    if (beanInstance == null) {
        beanInstance = cglibMethodProxy.invokeSuper(enhancedConfigInstance, beanMethodArgs);
    }
    return beanInstance;
}
```

第 1 步的 `isCurrentlyInvokedFactoryMethod` 是防递归的关键：当容器正在创建 `b` 本身时，`b()` 方法内的调用直接走父类方法（避免无限循环）；当 `a()` 内部调用 `b()` 时，此时创建的是 `a`，`b` 不是当前工厂方法 → 走第 2 步查容器 → 命中单例缓存 → **复用同一个 b**。

## 三、Lite 模式为什么不做增强

`@Component` 类也会被 `ConfigurationClassPostProcessor` 解析（扫描到后作为 Lite 配置处理其中的 @Bean 方法），但 **beanClass 不会被替换成 CGLIB 子类**。

原因：Full 模式的 CGLIB 增强有代价——
1. 启动期多一次 CGLIB 字节码生成；
2. 类不能是 final、方法不能是 static/final/private（否则无法被继承增强）；
3. 增加了调用链深度（每次 @Bean 方法调用都过拦截器）。

Lite 模式把选择权交给开发者：**如果你不需要方法互调的"容器复用"语义，用 Lite 更轻、更可控**。Spring Boot 自动配置类（`@AutoConfiguration`，内部标注 `@Configuration(proxyBeanMethods = false)`）就大量使用 Lite 模式来加速启动。

## 四、proxyBeanMethods=false：显式关掉增强

`@Configuration` 从 Spring 5.2 开始支持 `proxyBeanMethods` 属性：

```java
@Configuration(proxyBeanMethods = false)
public class DataSourceConfig { ... }
```

设置后该配置类按 **Lite 模式**处理（不生成 CGLIB 子类）。适用场景：
- 配置类中的 @Bean 方法**不存在互调**，或互调时本来就想拿新实例；
- 追求极致启动速度（Spring Boot 自动配置类标配）；
- 配置类本身是 final 类，无法被 CGLIB 继承。

> 坑提醒：`proxyBeanMethods = false` 时，若 A 的 @Bean 方法里调用 `b()`，得到的 B 是**直接 new 出来的新对象**，与容器中的单例 B 不是同一个！代码审查时看到互调 + proxyBeanMethods=false 的组合要格外警惕。

## 五、Full 模式的典型坑

### 坑 1：@Bean 方法所在类必须是可继承的

```java
@Configuration
public final class BadConfig {   // final → CGLIB 无法继承
    @Bean
    public A a() { return new A(); }
}
```

启动报错：`The bean 'badConfig' could not be registered as a bean definition...` 实际上 ConfigurationClassEnhancer 会抛 `IllegalStateException: @Configuration class ... cannot be enhanced`。解决：去掉 final，或改 `proxyBeanMethods = false`。

### 坑 2：@Bean 方法是 static 时互调语义不同

static @Bean 方法不走实例拦截器，互调 static 方法拿到的永远是 new 的对象。官方建议：static @Bean 方法内不要调用其他 @Bean 方法。

### 坑 3：内部类配置类被独立扫描

配置类里的 `@Configuration` 静态内部类会被当作独立 Full 配置类再次增强，如果它依赖外部类的 @Bean，要小心作用域差异。

## 六、面试追问速查

**Q1：@Configuration 里的 @Bean 方法互调，返回的是同一个实例吗？**
单例 scope 下是同一个。CGLIB 代理拦截方法调用，先查容器单例缓存（此时若正处于自身创建过程则直接走父类），命中即复用。

**Q2：@Component + @Bean 呢？**
Lite 模式无代理，每次互调都是 new，得到不同实例。这是 Full/Lite 最常考的差异点。

**Q3：Spring Boot 自动配置类为什么用 proxyBeanMethods=false？**
启动时有大量自动配置类要处理，省掉每类的 CGLIB 增强能明显缩短启动时间；且自动配置类的 @Bean 方法大多不存在互调依赖，牺牲互调语义换性能是划算的。

**Q4：如何验证一个配置类是 Full 还是 Lite？**
看 Bean 的 Class：Full 模式实例的 `getClass()` 是 `AppConfig$$EnhancerBySpringCGLIB$$...`；Lite 模式就是原类。也可以在 `checkConfigurationClassCandidate` 打断点观察 CONFIGURATION_CLASS_ATTRIBUTE 的值。

**Q5：@Bean 方法上的 @Scope("prototype") 在 Full 模式下互调会怎样？**
拦截器对 prototype 不查单例缓存，每次互调都会创建新实例，符合 prototype 语义。

## 七、总结

- **Full 模式** = 标注 `@Configuration`（默认 proxyBeanMethods=true）→ `ConfigurationClassPostProcessor` 用 CGLIB 生成子类 → @Bean 互调走容器复用；
- **Lite 模式** = @Component/@Import/方法级 @Bean 等 → 不增强 → 互调直接 new；
- 增强时机在 **BeanFactory 后置处理阶段**（refresh 早期），通过替换 beanClass 实现；
- `proxyBeanMethods=false` 是官方给的"性能开关"，代价是失去互调复用语义。

记忆锚点：**Full 是"容器感知"的配置类，Lite 是"普通类 + @Bean 方法"的语法糖**。面试时从 CGLIB 三回调（BeanMethodInterceptor 的"先查容器、防递归、再创建"）讲起，深度立刻拉开差距。
