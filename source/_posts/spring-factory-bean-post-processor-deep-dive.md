---
title: 【Spring 核心】Spring FactoryBean 与 BeanPostProcessor 扩展接口源码深度解析
date: 2026-07-29 08:00:00
tags:
  - Spring
  - IOC
  - 源码
categories:
  - Spring
  - IOC 容器
author: 东哥
---

# 【Spring 核心】Spring FactoryBean 与 BeanPostProcessor 扩展接口源码深度解析

## 前言

Spring IOC 容器之所以能成为 Java 生态的事实标准，很大程度上是因为它提供了丰富的**扩展接口**。从 `BeanPostProcessor` 到 `FactoryBean`，这些看似简单的接口背后支撑着 AOP、事务、MyBatis-Spring 集成等所有高级特性。

面试高频题：
- FactoryBean 和 BeanFactory 有什么区别？
- BeanPostProcessor 在 Spring Bean 生命周期中的执行时机？
- 如何在所有 Bean 初始化完成后执行自定义逻辑？

本文将源码级解析这两大扩展体系。

## 一、FactoryBean 原理

### 1.1 什么是 FactoryBean？

`FactoryBean` 是一种 **工厂 Bean 接口**，允许你自定义 Bean 的创建逻辑。Spring 容器在管理 FactoryBean 时，默认返回的是 `getObject()` 方法创建的对象，而不是 FactoryBean 本身。

```java
public interface FactoryBean<T> {
    // 返回由 FactoryBean 创建的对象
    @Nullable
    T getObject() throws Exception;

    // 返回创建对象的类型
    @Nullable
    Class<?> getObjectType();

    // 是否为单例
    default boolean isSingleton() {
        return true;
    }
}
```

### 1.2 经典应用场景

| 应用 | FactoryBean 实现 | 作用 |
|-----|-----------------|------|
| MyBatis-Spring | `SqlSessionFactoryBean` | 创建 SqlSessionFactory |
| Spring AOP | `ProxyFactoryBean` | 创建 AOP 代理对象 |
| Spring 事务 | `TransactionProxyFactoryBean` | 创建事务代理 |
| JNDI | `JndiObjectFactoryBean` | 从 JNDI 获取对象 |
| RMI | `RmiProxyFactoryBean` | 创建 RMI 代理 |

**示例：自定义 FactoryBean**

```java
@Component
public class CustomServiceFactoryBean implements FactoryBean<CustomService> {
    @Override
    public CustomService getObject() {
        CustomService service = new CustomService();
        service.setName("customized");
        service.init();  // 自定义初始化
        return service;
    }

    @Override
    public Class<?> getObjectType() {
        return CustomService.class;
    }

    @Override
    public boolean isSingleton() {
        return true;
    }
}
```

### 1.3 BeanFactory 与 FactoryBean 的区分

这个问题面试出现率极高：

| | BeanFactory | FactoryBean |
|---|------------|-------------|
| 本质 | IOC 容器的顶层接口 | 一种特殊的 Bean |
| 功能 | 管理 Bean 的创建、依赖注入 | 自定义某个 Bean 的创建逻辑 |
| 获取本身 | N/A | 在 beanName 前加 `&` 前缀 |

```java
// 获取 FactoryBean 创建的对象
Object service = context.getBean("customServiceFactoryBean");
// 获取 FactoryBean 本身
FactoryBean<?> factory = (FactoryBean<?>) context.getBean("&customServiceFactoryBean");
```

### 1.4 FactoryBean 的获取源码

```java
// AbstractBeanFactory.java
protected <T> T doGetBean(String name, @Nullable Class<T> requiredType,
        @Nullable Object[] args, boolean typeCheckOnly) {

    String beanName = transformedBeanName(name);
    // 检查是否以 & 开头
    boolean isFactoryBean = BeanFactoryUtils.isFactoryDereference(name);
    
    Object sharedInstance = getSingleton(beanName);

    if (sharedInstance != null && args == null) {
        if (isSingletonCurrentlyInCreation(beanName)) {
            // ...
        }
        // 关键：如果是 FactoryBean，获取 getObject() 返回的对象
        beanInstance = getObjectForBeanInstance(sharedInstance, name, beanName, null);
    }
    // ...
}
```

**核心方法 `getObjectForBeanInstance`**：

```java
protected Object getObjectForBeanInstance(Object beanInstance, String name, 
        String beanName, @Nullable RootBeanDefinition mbd) {

    // 如果 name 以 & 开头，直接返回 FactoryBean 本身
    if (BeanFactoryUtils.isFactoryDereference(name)) {
        if (beanInstance instanceof NullBean) return beanInstance;
        if (!(beanInstance instanceof FactoryBean)) {
            throw new BeanIsNotAFactoryException(beanName, beanInstance.getClass());
        }
        return beanInstance;
    }

    // 普通 Bean，直接返回
    if (!(beanInstance instanceof FactoryBean)) {
        return beanInstance;
    }

    // 从缓存中获取 FactoryBean.getObject() 的结果
    Object object = getCachedObjectForFactoryBean(beanName);
    if (object == null) {
        FactoryBean<?> factory = (FactoryBean<?>) beanInstance;
        object = getObjectFromFactoryBean(factory, beanName, !mbd.isSingleton());
    }
    return object;
}
```

**关键设计**：FactoryBean 的产品对象也有缓存（单例模式），复用 `getObject()` 结果。

## 二、BeanPostProcessor 机制

### 2.1 接口定义

```java
public interface BeanPostProcessor {
    // Bean 初始化方法执行前的回调
    @Nullable
    default Object postProcessBeforeInitialization(Object bean, String beanName) throws BeansException {
        return bean;
    }

    // Bean 初始化方法执行后的回调
    @Nullable
    default Object postProcessAfterInitialization(Object bean, String beanName) throws BeansException {
        return bean;
    }
}
```

### 2.2 经典实现

| 实现类 | 作用 | 执行时机 |
|-------|------|---------|
| `AutowiredAnnotationBeanPostProcessor` | 处理 @Autowired/@Value | before |
| `CommonAnnotationBeanPostProcessor` | 处理 @Resource/@PostConstruct | before |
| `ApplicationContextAwareProcessor` | 注入 Aware 接口回调 | before |
| `InitDestroyAnnotationBeanPostProcessor` | 处理 @PostConstruct/@PreDestroy | before |
| `AbstractAutoProxyCreator` (AOP) | 创建 AOP 代理 | after |

### 2.3 在 Bean 生命周期中的位置

```
实例化（反射）
    ↓
属性注入（populateBean）
    ↓
postProcessBeforeInitialization ← 各种注入、Aware 回调
    ↓
InitializingBean.afterPropertiesSet() / @PostConstruct
    ↓
init-method（自定义初始化方法）
    ↓
postProcessAfterInitialization ← AOP 代理创建在这里！
    ↓
Bean 就绪，放入容器
```

### 2.4 源码执行流程

```java
// AbstractAutowireCapableBeanFactory.java
protected Object doCreateBean(String beanName, RootBeanDefinition mbd, @Nullable Object[] args) {

    // 1. 实例化 Bean（反射构造）
    BeanWrapper instanceWrapper = createBeanInstance(beanName, mbd, args);
    Object bean = instanceWrapper.getWrappedInstance();

    // 2. 提前暴露（解决循环依赖）
    // ...

    // 3. 属性注入
    populateBean(beanName, mbd, instanceWrapper);

    // 4. 初始化 + BeanPostProcessor
    exposedObject = initializeBean(beanName, exposedObject, mbd);

    return exposedObject;
}

protected Object initializeBean(String beanName, Object bean, @Nullable RootBeanDefinition mbd) {
    // 调用 Aware 方法（BeanNameAware、BeanFactoryAware 等）
    invokeAwareMethods(beanName, bean);

    // ★ postProcessBeforeInitialization
    Object wrappedBean = bean;
    wrappedBean = applyBeanPostProcessorsBeforeInitialization(wrappedBean, beanName);

    // 调用 init 方法（@PostConstruct → InitializingBean → init-method）
    invokeInitMethods(beanName, wrappedBean, mbd);

    // ★ postProcessAfterInitialization
    wrappedBean = applyBeanPostProcessorsAfterInitialization(wrappedBean, beanName);

    return wrappedBean;
}
```

### 2.5 AOP 代理的创建时机

Spring AOP 创建代理就在 `postProcessAfterInitialization` 中：

```java
// AbstractAutoProxyCreator.java
public Object postProcessAfterInitialization(@Nullable Object bean, String beanName) {
    if (bean != null) {
        Object cacheKey = getCacheKey(bean.getClass(), beanName);
        if (this.earlyProxyReferences.remove(cacheKey) != bean) {
            // 创建 AOP 代理
            return wrapIfNecessary(bean, beanName, cacheKey);
        }
    }
    return bean;
}
```

**关键结论**：AOP 代理在 Bean 初始化**之后**创建。所以：
- 在 `postProcessBeforeInitialization` 中拿到的还是原始 Bean
- 在 Bean 内部 `this` 引用也是原始 Bean（自调用 AOP 不生效的根本原因）

## 三、BeanFactoryPostProcessor —— 容器的扩展

与 `BeanPostProcessor` 作用于**Bean 实例**不同，`BeanFactoryPostProcessor` 作用于 **BeanDefinition（Bean 定义元数据）**：

```java
@FunctionalInterface
public interface BeanFactoryPostProcessor {
    void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory);
}
```

**执行时机**：所有 BeanDefinition 加载完成后，Bean 实例化之前。

**经典实现**：
- `PropertySourcesPlaceholderConfigurer`：解析 `${...}` 占位符
- `CustomEditorConfigurer`：注册自定义属性编辑器

### 对比总结

| | BeanPostProcessor | BeanFactoryPostProcessor |
|---|------------------|------------------------|
| 操作对象 | Bean 实例 | BeanDefinition |
| 执行时机 | Bean 初始化前后 | Bean 实例化之前 |
| 典型用途 | 注入依赖、代理包装 | 配置属性替换、BeanDef 修改 |
| AOP 代理 | ✅ after 阶段创建 | ❌ 不适用 |

## 四、@PostConstruct 初始化顺序源码

通过 `CommonAnnotationBeanPostProcessor` 实现：

```java
// InitDestroyAnnotationBeanPostProcessor (父类)
public Object postProcessBeforeInitialization(Object bean, String beanName) {
    LifecycleMetadata metadata = findLifecycleMetadata(bean.getClass());
    if (metadata != null) {
        // 执行 @PostConstruct 标注的方法
        metadata.invokeInitMethods(bean, beanName);
    }
    return bean;
}
```

**完整的初始化顺序**：
1. `BeanNameAware.setBeanName()`
2. `BeanClassLoaderAware.setBeanClassLoader()`
3. `BeanFactoryAware.setBeanFactory()`
4. 其他 Aware 回调（ApplicationContextAware 等）
5. **@PostConstruct**
6. **InitializingBean.afterPropertiesSet()**
7. **@Bean(initMethod="xxx")**

面试中经常被问到这个顺序。

## 五、与 SmartInitializingSingleton

如果想在所有 Bean 初始化完成后（包括所有 BeanPostProcessor 处理完）执行逻辑，可以使用 `SmartInitializingSingleton`：

```java
@Component
public class MyInitializer implements SmartInitializingSingleton {
    @Override
    public void afterSingletonsInstantiated() {
        // 所有单例 Bean 初始化完成后执行
        System.out.println("所有 Bean 已就绪！");
    }
}
```

**执行时机**：容器调用 `finishBeanFactoryInitialization()` 完成所有非懒加载单例 Bean 的初始化后。

源码位置：
```java
// DefaultListableBeanFactory.java
public void preInstantiateSingletons() throws BeansException {
    // 实例化所有非懒加载单例 Bean...
    
    // 触发 SmartInitializingSingleton 回调
    for (String beanName : beanNames) {
        Object singletonInstance = getSingleton(beanName);
        if (singletonInstance instanceof SmartInitializingSingleton) {
            SmartInitializingSingleton smartSingleton = (SmartInitializingSingleton) singletonInstance;
            smartSingleton.afterSingletonsInstantiated();
        }
    }
}
```

## 六、自定义扩展实战

### 6.1 记录 Bean 创建耗时

```java
@Component
public class BeanTimingPostProcessor implements BeanPostProcessor {
    private final Map<String, Long> startTimes = new ConcurrentHashMap<>();

    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        startTimes.put(beanName, System.nanoTime());
        return bean;
    }

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        Long start = startTimes.remove(beanName);
        if (start != null) {
            long ms = (System.nanoTime() - start) / 1_000_000;
            if (ms > 100) {  // 超过 100ms 打印警告
                System.out.printf("[WARN] Bean '%s' 初始化耗时 %dms%n", beanName, ms);
            }
        }
        return bean;
    }
}
```

### 6.2 动态修改 BeanDefinition

```java
@Component
public class MyBeanFactoryPostProcessor implements BeanFactoryPostProcessor {
    @Override
    public void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory) {
        BeanDefinition bd = beanFactory.getBeanDefinition("someBean");
        // 动态修改 Bean 的作用域
        bd.setScope(ConfigurableBeanFactory.SCOPE_PROTOTYPE);
        // 添加属性值
        MutablePropertyValues pv = bd.getPropertyValues();
        pv.add("timeout", 5000);
    }
}
```

## 七、常见面试题

### Q1: BeanPostProcessor 和 BeanFactoryPostProcessor 哪个先执行？

**BeanFactoryPostProcessor 先执行**。因为需要在 BeanDefinition 准备好之后（修改完配置后），才开始实例化 Bean 并应用 BeanPostProcessor。

### Q2: 自定义的 BeanPostProcessor 能否被其他 BeanPostProcessor 处理？

**不能**。BeanPostProcessor 在容器启动早期就被实例化并注册了。其他普通 Bean 的 BeanPostProcessor 不会作用在同样实现了 BeanPostProcessor 的 Bean 上。

### Q3: FactoryBean 创建的对象能否享受 BeanPostProcessor？

**能**。`getObjectFromFactoryBean()` 源码中，产品对象返回前会调用 `postProcessObjectFromFactoryBean()`，这个方法是给 BeanPostProcessor 机会处理 FactoryBean 的产品的。

## 八、总结

Spring 的扩展接口体系可以分为三层：

```
BeanFactoryPostProcessor — 修改 BeanDefinition（实例化前）
                    ↓
         Bean 实例化 + 属性注入
                    ↓
   BeanPostProcessor.before — Aware 回调、@Autowired、@PostConstruct
                    ↓
          InitializingBean / init-method
                    ↓
   BeanPostProcessor.after — AOP 代理创建！
                    ↓
        SmartInitializingSingleton — 所有 Bean 就绪
```

掌握这些扩展接口，不仅能应对面试，更重要的是能深入理解 MyBatis-Spring、Spring Security 等框架的集成原理，以及在自己的 Starter 中灵活使用这些扩展点。
