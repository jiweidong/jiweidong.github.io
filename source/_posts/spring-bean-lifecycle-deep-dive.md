---
title: 彻底搞懂 Spring Bean 的生命周期：从加载到销毁全流程解析
date: 2026-06-21 08:00:00
tags:
  - Java
  - Spring
  - 源码分析
categories:
  - Java
  - Spring 原理
author: 东哥
---

# 彻底搞懂 Spring Bean 的生命周期：从加载到销毁全流程解析

## 引言

Spring Bean 的生命周期是 Spring 框架最核心的知识点之一，也是面试中高频出现的题目。很多同学背了一大堆扩展接口名称，但一到真实的源码层面就懵了。

这篇文章带你**一行一行过源码**，彻底搞懂 Bean 从"出生"到"死亡"的全过程。

## 一、宏观概览——Bean 生命周期全流程图

```
BeanDefinition 加载 → 实例化 → 属性填充 → 初始化 → 使用中 → 销毁
  │                    │          │          │          │        │
  ▼                    ▼          ▼          ▼          ▼        ▼
  配置解析         构造函数     设置属性    Aware回调    业务调用   DisposableBean
  @Bean/XML      或工厂方法    populate()  各种Aware    AOP代理     @PreDestroy
  @Component                                        BeanPostProcessor
```

核心流程分为 5 大阶段：
1. **元数据加载阶段**：加载和解析 BeanDefinition
2. **实例化阶段**：通过反射或工厂方法创建实例
3. **属性填充阶段**：完成依赖注入（DI）
4. **初始化阶段**：Aware 回调、BeanPostProcessor 前置处理、init 方法、BeanPostProcessor 后置处理
5. **销毁阶段**：容器关闭时执行销毁逻辑

## 二、从源码角度逐阶段剖析

### 阶段 1：BeanDefinition 加载

Spring 启动时，会通过 `BeanDefinitionReader` 读取配置（XML、注解、Java Config），封装成 `BeanDefinition` 对象。

```java
// BeanDefinition 的核心信息
public interface BeanDefinition {
    String SCOPE_SINGLETON = "singleton";
    String SCOPE_PROTOTYPE = "prototype";
    
    // Bean 的类名
    void setBeanClassName(String beanClassName);
    // 作用域
    void setScope(String scope);
    // 懒加载
    void setLazyInit(boolean lazyInit);
    // 初始化方法名
    void setInitMethodName(String initMethodName);
    // 销毁方法名
    void setDestroyMethodName(String destroyMethodName);
    // 构造参数
    ConstructorArgumentValues getConstructorArgumentValues();
    // 属性值
    MutablePropertyValues getPropertyValues();
}
```

```java
// 以注解配置为例：加载流程
public class AnnotationConfigApplicationContext extends GenericApplicationContext {
    
    public AnnotationConfigApplicationContext(Class<?>... componentClasses) {
        // 1. 创建 BeanDefinition 读取器
        this.reader = new AnnotatedBeanDefinitionReader(this);
        // 2. 创建 ClassPath 扫描器
        this.scanner = new ClassPathBeanDefinitionScanner(this);
        // 3. 注册配置类
        register(componentClasses);
        // 4. 刷新容器（核心入口）
        refresh();
    }
}
```

**关键源码**（AbstractApplicationContext.refresh）：

```java
@Override
public void refresh() throws BeansException, IllegalStateException {
    synchronized (this.startupShutdownMonitor) {
        // 1. 准备刷新上下文
        prepareRefresh();
        
        // 2. 获取 BeanFactory（关键步骤）
        ConfigurableListableBeanFactory beanFactory = obtainFreshBeanFactory();
        
        // 3. 准备 BeanFactory（设置类加载器、后置处理器等）
        prepareBeanFactory(beanFactory);
        
        // 4. 执行 BeanFactoryPostProcessor（修改 BeanDefinition）
        postProcessBeanFactory(beanFactory);
        invokeBeanFactoryPostProcessors(beanFactory);
        
        // 5. 注册 BeanPostProcessor
        registerBeanPostProcessors(beanFactory);
        
        // 6. 初始化消息源
        initMessageSource();
        
        // 7. 初始化事件广播器
        initApplicationEventMulticaster();
        
        // 8. 特殊 Bean 初始化（onRefresh）
        onRefresh();
        
        // 9. 注册监听器
        registerListeners();
        
        // 10. ◆ 实例化所有非懒加载的单例 Bean（核心入口）
        finishBeanFactoryInitialization(beanFactory);
        
        // 11. 完成刷新
        finishRefresh();
    }
}
```

### 阶段 2：实例化（Instantiation）

`finishBeanFactoryInitialization` 中调用 `getBean()` → `doGetBean()` → `createBean()` → `doCreateBean()`：

```java
// AbstractAutowireCapableBeanFactory
protected Object doCreateBean(String beanName, RootBeanDefinition mbd, @Nullable Object[] args) {
    BeanWrapper instanceWrapper = null;
    if (mbd.isSingleton()) {
        // 从 FactoryBean 缓存中移除
        instanceWrapper = this.factoryBeanInstanceCache.remove(beanName);
    }
    if (instanceWrapper == null) {
        // ◆ 关键：创建 Bean 实例
        instanceWrapper = createBeanInstance(beanName, mbd, args);
    }
    // ...
}
```

**实例化策略**（`createBeanInstance`）：

```java
protected BeanWrapper createBeanInstance(String beanName, RootBeanDefinition mbd, @Nullable Object[] args) {
    // 1. 检查是否有 Supplier
    // 2. 检查是否有工厂方法
    // 3. 解析构造参数（有参数时根据参数自动匹配）
    // 4. 无参构造：通过反射实例化
    return instantiateBean(beanName, mbd);
}

protected BeanWrapper instantiateBean(String beanName, RootBeanDefinition mbd) {
    // 使用构造函数创建实例
    return BeanUtils.instantiateClass(constructorToUse);
}
```

这个阶段 bean 刚创建出来，**还是一个"毛胚房"**——属性都是 null，没有依赖注入。

### 阶段 3：属性填充（Populate Bean）

实例化完成后，Spring 进行属性填充（依赖注入）：

```java
// AbstractAutowireCapableBeanFactory
protected void populateBean(String beanName, RootBeanDefinition mbd, @Nullable BeanWrapper bw) {
    // 1. 执行 InstantiationAwareBeanPostProcessor 的前置处理
    //    如果返回 false，跳过后续属性填充
    if (!mbd.isSynthetic() && hasInstantiationAwareBeanPostProcessors()) {
        for (BeanPostProcessor bp : getBeanPostProcessors()) {
            if (bp instanceof InstantiationAwareBeanPostProcessor) {
                InstantiationAwareBeanPostProcessor ibp = (InstantiationAwareBeanPostProcessor) bp;
                if (!ibp.postProcessAfterInstantiation(bw.getWrappedInstance(), beanName)) {
                    return;
                }
            }
        }
    }
    
    // 2. 获取属性值（从 BeanDefinition 中）
    PropertyValues pvs = (mbd.hasPropertyValues() ? mbd.getPropertyValues() : null);
    
    // 3. 按注入类型处理
    if (mbd.getResolvedAutowireMode() == AUTOWIRE_BY_NAME
            || mbd.getResolvedAutowireMode() == AUTOWIRE_BY_TYPE) {
        // 自动装配
        autowireByName(beanName, mbd, bw, newPvs);
        autowireByType(beanName, mbd, bw, newPvs);
    }
    
    // 4. 检查是否有依赖检查
    // 5. ◆ 应用属性值（注入实际值）
    applyPropertyValues(beanName, mbd, bw, pvs);
}
```

**依赖注入方式对比：**

| 注入方式 | 实现方式 | 优缺点 |
|----------|----------|--------|
| field 注入 | `@Autowired` 直接加字段上 | 简洁，但无法被 final 修饰，不利于测试 |
| setter 注入 | `@Autowired` 加 setter | 可选依赖，支持重新注入 |
| 构造器注入 | 构造函数参数 + `@Autowired`（Spring 4.3+可省略） | **推荐**：不可变、不为 null、利于测试 |

```java
@Component
public class UserService {
    
    // 方式一：字段注入（不推荐）
    @Autowired
    private UserRepository userRepository;
    
    // 方式二：构造器注入（推荐）
    private final UserRepository userRepository;
    
    // Spring 4.3+ 单个构造器时 @Autowired 可省略
    public UserService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }
}
```

### 阶段 4：初始化（Initialization）

属性填充完成后，Bean 进入初始化阶段。这是**扩展点最多**的阶段：

```java
// AbstractAutowireCapableBeanFactory
protected Object initializeBean(String beanName, Object bean, @Nullable RootBeanDefinition mbd) {
    // ◆ 第一步：Aware 接口回调
    invokeAwareMethods(beanName, bean);
    
    // ◆ 第二步：BeanPostProcessor 前置处理（初始化前）
    Object wrappedBean = applyBeanPostProcessorsBeforeInitialization(bean, beanName);
    
    // ◆ 第三步：执行初始化方法
    invokeInitMethods(beanName, wrappedBean, mbd);
    
    // ◆ 第四步：BeanPostProcessor 后置处理（初始化后，AOP 就在这里）
    wrappedBean = applyBeanPostProcessorsAfterInitialization(wrappedBean, beanName);
    
    return wrappedBean;
}
```

#### 第一步：Aware 接口回调

```java
private void invokeAwareMethods(String beanName, Object bean) {
    if (bean instanceof Aware) {
        if (bean instanceof BeanNameAware) {
            ((BeanNameAware) bean).setBeanName(beanName);
        }
        if (bean instanceof BeanClassLoaderAware) {
            ((BeanClassLoaderAware) bean).setBeanClassLoader(getBeanClassLoader());
        }
        if (bean instanceof BeanFactoryAware) {
            ((BeanFactoryAware) bean).setBeanFactory(AbstractAutowireCapableBeanFactory.this);
        }
    }
}
```

注意：`ApplicationContextAware`、`EnvironmentAware` 等是通过 `ApplicationContextAwareProcessor`（一个 BeanPostProcessor）来注入的，在下一步执行。

**常见 Aware 接口及用途：**

| Aware 接口 | 注入对象 |
|------------|----------|
| BeanNameAware | 当前 Bean 的名称 |
| BeanFactoryAware | 当前的 BeanFactory 容器 |
| ApplicationContextAware | 当前的 ApplicationContext（ApplicationContextAwareProcessor 注入） |
| EnvironmentAware | 当前的环境配置信息 |
| ResourceLoaderAware | 资源加载器 |
| MessageSourceAware | 国际化消息源 |

#### 第二步：BeanPostProcessor 前置处理

```java
@Override
public Object applyBeanPostProcessorsBeforeInitialization(Object existingBean, String beanName) {
    Object result = existingBean;
    for (BeanPostProcessor processor : getBeanPostProcessors()) {
        Object current = processor.postProcessBeforeInitialization(result, beanName);
        if (current == null) {
            return result;
        }
        result = current;
    }
    return result;
}
```

常见的前置处理器：
- `ApplicationContextAwareProcessor`：注入 ApplicationContextAware 等
- `InitDestroyAnnotationBeanPostProcessor`：处理 @PostConstruct（扫描标记方法，为后续执行做准备）

#### 第三步：执行初始化方法

```java
protected void invokeInitMethods(String beanName, Object bean, @Nullable RootBeanDefinition mbd) {
    // 如果 bean 实现了 InitializingBean，调用 afterPropertiesSet()
    if (bean instanceof InitializingBean) {
        ((InitializingBean) bean).afterPropertiesSet();
    }
    
    // 如果指定了自定义 init-method，通过反射调用
    if (mbd != null && mbd.getInitMethodName() != null) {
        invokeCustomInitMethod(beanName, bean, mbd);
    }
}
```

**初始化方法执行顺序：**
1. `@PostConstruct` 标注的方法（在 InitDestroyAnnotationBeanPostProcessor 中执行）
2. `InitializingBean.afterPropertiesSet()`
3. 自定义 `@Bean(initMethod = "init")` 或 XML `init-method`

#### 第四步：BeanPostProcessor 后置处理

```java
@Override
public Object applyBeanPostProcessorsAfterInitialization(Object existingBean, String beanName) {
    Object result = existingBean;
    for (BeanPostProcessor processor : getBeanPostProcessors()) {
        Object current = processor.postProcessAfterInitialization(result, beanName);
        if (current == null) {
            return result;
        }
        result = current;
    }
    return result;
}
```

**最关键的后置处理器**：`AbstractAutoProxyCreator`（AOP 的入口）

```java
// AbstractAutoProxyCreator.postProcessAfterInitialization()
@Override
public Object postProcessAfterInitialization(@Nullable Object bean, String beanName) {
    if (bean != null) {
        // 检查是否需要被代理（是否有 @Transactional、@Aspect 等）
        Object cacheKey = getCacheKey(bean.getClass(), beanName);
        if (this.earlyProxyReferences.remove(cacheKey) != bean) {
            // ◆ 核心：创建 AOP 代理
            return wrapIfNecessary(bean, beanName, cacheKey);
        }
    }
    return bean;
}
```

**AOP 代理在这里创建**：如果当前 Bean 需要被增强（事务、缓存、切面等），这里会返回一个 JDK 动态代理或 CGLIB 代理对象。

### 阶段 5：销毁（Destruction）

容器关闭时，调用 `doClose()` → `destroyBeans()`：

```java
// DefaultSingletonBeanRegistry
public void destroySingletons() {
    // 处理 DisposableBean
    for (String beanName : disposableBeanNames) {
        DisposableBean disposableBean = this.disposableBeans.remove(beanName);
        if (disposableBean != null) {
            disposableBean.destroy();
        }
    }
}
```

**销毁方法执行顺序：**
1. `@PreDestroy` 标注的方法
2. `DisposableBean.destroy()`
3. 自定义 `@Bean(destroyMethod = "close")` 或 XML `destroy-method`

## 三、Spring 关键扩展点总结

整个生命周期中的**扩展接口**按执行顺序：

```
                  BeanFactoryPostProcessor
                  ────────────────────────
                  在 Bean 实例化之前修改 BeanDefinition
                         │
                         ▼
                  BeanPostProcessor#postProcessBeforeInitialization
                  ────────────────────────────────────────────────
                  Aware 回调、@PostConstruct（在对应的 processor 中）
                         │
                         ▼
                ┌────────┴────────┐
                │  InitializingBean│── @PostConstruct → afterPropertiesSet → init-method
                │  @PostConstruct  │
                │  @Bean(init)     │
                └────────┬────────┘
                         │
                         ▼
                  BeanPostProcessor#postProcessAfterInitialization
                  ────────────────────────────────────────────────
                  AOP 代理创建入口
                         │
                         ▼
                    DisposableBean
                    @PreDestroy
                    @Bean(destroyMethod)
```

## 四、经典面试题

### Q1：Spring 如何解决循环依赖？

利用**三级缓存** + **提前暴露对象的 ObjectFactory**：

```java
public class DefaultSingletonBeanRegistry {
    // 一级缓存：完整的单例 Bean
    private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);
    // 二级缓存：提前暴露的早期对象（还没完成属性填充）
    private final Map<String, Object> earlySingletonObjects = new ConcurrentHashMap<>(16);
    // 三级缓存：ObjectFactory 工厂
    private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);
}
```

```java
// 从三级缓存获取早期引用
protected Object getSingleton(String beanName, boolean allowEarlyReference) {
    Object singletonObject = this.singletonObjects.get(beanName);
    if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
        singletonObject = this.earlySingletonObjects.get(beanName);
        if (singletonObject == null && allowEarlyReference) {
            // 从三级缓存中获取 ObjectFactory 并创建早期引用
            ObjectFactory<?> singletonFactory = this.singletonFactories.get(beanName);
            if (singletonFactory != null) {
                singletonObject = singletonFactory.getObject();
                this.earlySingletonObjects.put(beanName, singletonObject);
                this.singletonFactories.remove(beanName);
            }
        }
    }
    return singletonObject;
}
```

三级缓存解决的问题：A 依赖 B，B 依赖 A。A 创建时提前暴露给 B，B 通过三级缓存拿到 A 的早期引用完成自身创建，然后 A 再完成属性填充。

**注意**：三级缓存只能解决 **setter 注入** 的循环依赖，**构造器注入**不行（构造时对象还没创建出来，没有早期引用可暴露）。

### Q2：BeanPostProcessor 和 BeanFactoryPostProcessor 的区别？

| 区别 | BeanFactoryPostProcessor | BeanPostProcessor |
|------|------------------------|-------------------|
| 执行时机 | Bean **实例化之前** | Bean 初始化前后 |
| 操作对象 | BeanDefinition（元数据） | Bean 实例本身 |
| 典型场景 | 修改属性值、注册特殊 Bean | 代理、包装、监控 |
| 执行顺序 | 更早 | 更晚 |

```java
// 自定义 BeanFactoryPostProcessor
@Component
public class MyBeanFactoryPostProcessor implements BeanFactoryPostProcessor {
    @Override
    public void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory) {
        // 获取 BeanDefinition 并修改属性
        BeanDefinition bd = beanFactory.getBeanDefinition("userService");
        bd.getPropertyValues().add("timeout", 5000);
    }
}
```

### Q3：@PostConstruct、afterPropertiesSet、init-method 的执行顺序？

```
1. @PostConstruct（注解方式，在 InitDestroyAnnotationBeanPostProcessor 中执行）
2. InitializingBean#afterPropertiesSet（接口方式）
3. @Bean(initMethod = "xxx") 或 XML init-method（反射方式）
```

**官方推荐**：用 `@PostConstruct` 最方便；用 `InitializingBean` 可以和 Spring 解耦（但不是完全解耦）；自定义 `init-method` 适用于 XML 配置的第三方 Bean。

## 总结

Spring Bean 生命周期看似复杂，但本质上就一句话：

> **先找到定义（BeanDefinition）→ 建房子（实例化）→ 装修（属性填充）→ 通水电（初始化回调）→ 住进去（使用）→ 拆房子（销毁）**

每个阶段都预留了扩展点，让开发者可以"插一脚"干点私活——这就是 Spring 框架"开闭原则"的体现。

掌握了 Bean 生命周期，你就掌握了 Spring 的"骨架"。无论是面试还是日常开发排查问题，都会游刃有余。
