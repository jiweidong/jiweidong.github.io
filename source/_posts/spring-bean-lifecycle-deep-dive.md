---
title: 【Spring 核心】Bean 生命周期深度解析：从实例化到销毁的完整旅程（源码级）
date: 2026-08-24 08:00:00
tags:
  - Spring
  - 面试
categories:
  - Spring
author: 东哥
---

# 【Spring 核心】Bean 生命周期深度解析：从实例化到销毁的完整旅程（源码级）

## 面试官：能完整说说 Spring Bean 的生命周期吗？

这是一道 Spring 面试必考题，但很多人只能背出"实例化→初始化→销毁"三个词。本文从源码角度，把 Bean 从"定义"到"销毁"的完整旅程拆开，并回答"每个扩展点是什么时候被调用的、有什么用"。

## 一、先建立整体认知：Bean 的一生

```text
BeanDefinition 解析
      ↓
实例化（构造器 new 对象）
      ↓
属性填充（依赖注入）
      ↓
Aware 回调（BeanNameAware / BeanFactoryAware / ApplicationContextAware）
      ↓
BeanPostProcessor#postProcessBeforeInitialization（初始化前增强）
      ↓
初始化（@PostConstruct → InitializingBean#afterPropertiesSet → init-method）
      ↓
BeanPostProcessor#postProcessAfterInitialization（初始化后增强，AOP 代理在这里生成！）
      ↓
✅ 就绪：放入单例池，供业务使用
      ↓
容器关闭
      ↓
销毁（@PreDestroy → DisposableBean#destroy → destroy-method）
```

## 二、阶段 0：BeanDefinition 的加载

生命周期真正的起点是 **BeanDefinition**。Spring 通过 `BeanDefinitionReader`（XML 的 `XmlBeanDefinitionReader`、注解的 `ClassPathBeanDefinitionScanner`）把配置转换成 BeanDefinition，注册进 `DefaultListableBeanFactory.beanDefinitionMap`。

```java
public class GenericBeanDefinition implements BeanDefinition {
    private volatile Object beanClass;      // 类
    private String scope = "";              // 单例/原型
    private String initMethodName;          // init-method
    private String destroyMethodName;       // destroy-method
    private ConstructorArgumentValues constructorArgumentValues;
    private MutablePropertyValues propertyValues;  // 属性值
}
```

此时**还没有对象**，只是"图纸"。注意：`@Bean`、`<bean>`、`@Component` 最终都会转成 BeanDefinition，统一走后面的流程。

## 三、阶段 1：实例化（new 出对象）

入口是 `AbstractAutowireCapableBeanFactory.createBeanInstance()`。Spring 会依次尝试三种策略：

1. **Supplier 方式**（`beanDefinition.setInstanceSupplier()`，编程式创建）
2. **工厂方法方式**（`@Bean` 的方法本质就是工厂方法，`factory-method`）
3. **构造器自动装配**：先找 `@Autowired` 标注的构造器；没有则用**无参构造器**；有多个构造器且都未标注时，根据参数匹配（`autowireConstructor`），匹配失败抛 `BeanCreationException`

```java
// 简化源码
protected BeanWrapper createBeanInstance(String beanName, RootBeanDefinition mbd, Object[] args) {
    // 1. Supplier
    Supplier<?> instanceSupplier = mbd.getInstanceSupplier();
    if (instanceSupplier != null) return obtainFromSupplier(instanceSupplier, beanName);
    // 2. 工厂方法
    if (mbd.getFactoryMethodName() != null) return instantiateUsingFactoryMethod(...);
    // 3. 构造器推断
    return autowireConstructor(beanName, mbd, ctors, args);  // 或无参构造 instantiateBean
}
```

实例化阶段会解决**构造器循环依赖**（通过提前暴露实例），但更常见的是 setter 循环依赖，见下文第六节。

## 四、阶段 2：属性填充（依赖注入）

入口 `populateBean()`。依次处理：

1. `InstantiationAwareBeanPostProcessor.postProcessAfterInstantiation`（可返回 false 跳过属性填充）
2. `postProcessProperties`（**@Autowired / @Resource / @Value 的注入逻辑就在这里**，由 `AutowiredAnnotationBeanPostProcessor` 处理）
3. `PropertyValues` 中的显式属性赋值（XML 的 `<property>`）

```java
// AutowiredAnnotationBeanPostProcessor 核心逻辑
public PropertyValues postProcessProperties(PropertyValues pvs, Object bean, String beanName) {
    InjectionMetadata metadata = findAutowiringMetadata(beanName, bean.getClass(), pvs);
    metadata.inject(bean, beanName, pvs);   // 遍历 @Autowired 字段/方法，逐个注入
    return pvs;
}
```

**注意**：属性填充发生在 Aware 回调**之前**？严格来说，`populateBean` 在 `initializeBean` 之前，而 Aware 回调在 `initializeBean` 内部，所以顺序是：**属性填充 → Aware → 初始化**。

## 五、阶段 3~5：Aware 回调与初始化（核心中的核心）

入口 `initializeBean()`：

```java
protected Object initializeBean(String beanName, Object bean, RootBeanDefinition mbd) {
    // ① Aware 回调
    invokeAwareMethods(beanName, bean);   // BeanNameAware, BeanClassLoaderAware, BeanFactoryAware
    // ② 初始化前增强
    Object wrappedBean = applyBeanPostProcessorsBeforeInitialization(bean, beanName);
    // ③ 初始化
    invokeInitMethods(beanName, wrappedBean, mbd);  // InitializingBean + init-method
    // ④ 初始化后增强（AOP 代理在这里）
    wrappedBean = applyBeanPostProcessorsAfterInitialization(wrappedBean, beanName);
    return wrappedBean;
}
```

### 1. Aware 回调（按接口分两批）

- **第一批（内置，直接强转调用）**：`BeanNameAware`、`BeanClassLoaderAware`、`BeanFactoryAware`
- **第二批（通过 ApplicationContextAwareProcessor 处理）**：`ApplicationContextAware`、`EnvironmentAware`、`ResourceLoaderAware`、`ApplicationEventPublisherAware`、`MessageSourceAware` 等

只有 `ApplicationContext` 容器才有第二批；`BeanFactory` 裸容器没有。

### 2. 初始化前：postProcessBeforeInitialization

`BeanPostProcessor` 接口的两个方法是最强扩展点，AOP、代理、注解处理全都挂在上面：

```java
public interface BeanPostProcessor {
    default Object postProcessBeforeInitialization(Object bean, String beanName) { return bean; }
    default Object postProcessAfterInitialization(Object bean, String beanName) { return bean; }
}
```

### 3. 初始化三件套的执行顺序（面试高频考点！）

```java
// AbstractAutowireCapableBeanFactory.invokeInitMethods
protected void invokeInitMethods(String beanName, Object bean, RootBeanDefinition mbd) {
    // 顺序 1：InitializingBean.afterPropertiesSet()
    if (bean instanceof InitializingBean ib) {
        ib.afterPropertiesSet();
    }
    // 顺序 2：init-method（@Bean(initMethod=...) / <bean init-method="...">）
    if (mbd.getInitMethodName() != null) {
        invokeCustomInitMethod(beanName, bean, mbd);
    }
}
```

而 `@PostConstruct` 呢？它由 `CommonAnnotationBeanPostProcessor` 处理，其 `postProcessBeforeInitialization` 中会调用 `@PostConstruct` 方法——所以真实顺序是：

| 顺序 | 机制 | 由谁执行 |
|------|------|---------|
| 1 | `@PostConstruct` | CommonAnnotationBeanPostProcessor（在 BeforeInitialization 中） |
| 2 | `InitializingBean.afterPropertiesSet()` | 容器直接调用 |
| 3 | `init-method` | 容器反射调用 |

**@PostConstruct 为什么在最前面？** 因为它挂在 postProcessBeforeInitialization 里，而后者先于 invokeInitMethods 执行。这道题的答案必须精确到这个顺序，才能体现源码功底。

### 4. 初始化后：postProcessAfterInitialization（AOP 的诞生地）

```java
// AbstractAutoProxyCreator（AOP 核心）重写了该方法
public Object postProcessAfterInitialization(Object bean, String beanName) {
    if (bean != null) {
        Object cacheKey = getCacheKey(bean.getClass(), beanName);
        if (this.earlyProxyReferences.remove(cacheKey) != bean) {
            return wrapIfNecessary(bean, beanName, cacheKey);  // 生成代理！
        }
    }
    return bean;
}
```

**关键结论：Spring AOP 的代理对象是在 Bean 初始化完成后才生成的**。所以：
- 在 `postProcessBeforeInitialization` 里拿到的 bean 还是原始对象
- 在 `postProcessAfterInitialization` 里拿到的可能是代理对象
- 这也解释了为什么 `@Transactional`、`@Async` 的**自调用（this.method()）会失效**——因为代理是在外层，内部 `this` 调用走不到代理

### 5. 单例注册

初始化完成后，单例 bean 会被放入 `singletonObjects`（一级缓存）。**注意：真正放入一级缓存是在 `getSingleton` 返回时由 `addSingleton` 完成的**，而不是 doCreateBean 内部。

## 六、循环依赖：为什么三级缓存能解决 setter 注入？

顺带回答必考连环问。三级缓存：

```java
// DefaultSingletonBeanRegistry
private final Map<String, Object> singletonObjects;     // 一级：成品单例
private final Map<String, Object> earlySingletonObjects; // 二级：半成品（已实例化未初始化）
private final Map<String, ObjectFactory<?>> singletonFactories; // 三级：提前暴露的工厂
```

流程（A 依赖 B，B 依赖 A）：

1. A 实例化后，把 `ObjectFactory` 放入三级缓存（`addSingletonFactory`）
2. A 属性填充时发现需要 B，去创建 B
3. B 实例化后同样放入三级缓存，属性填充时发现需要 A
4. B 从三级缓存拿到 A 的工厂，调用 `getEarlyBeanReference` 得到 A 的**提前引用**（此时 A 未初始化，如果是代理场景会先创建代理），放入二级缓存
5. B 完成初始化，B 成为成品
6. A 拿到 B，完成属性填充和初始化，A 成为成品

**为什么是三级而不是二级？** 二级缓存也能解决循环依赖，但无法处理"循环依赖 + AOP"：如果提前把原始对象放进二级缓存，后续 AOP 代理生成时，其他 bean 持有的还是原始对象引用。三级缓存用 `ObjectFactory` 延迟到"有人需要"时才创建代理，保证**所有引用都拿到代理**。

**哪些循环依赖解决不了？**
- 构造器注入循环依赖（实例化阶段就互相需要，无从提前暴露）→ 抛 `BeanCurrentlyInCreationException`
- 原型（prototype）作用域的循环依赖 → 无法解决
- `@Async` 循环依赖（代理提前生成复杂）→ Spring Boot 2.6 起默认**禁止循环依赖**

## 七、阶段 6：销毁

容器关闭（`AbstractApplicationContext.close()` → `doClose` → `destroyBeans`）时：

| 顺序 | 机制 | 由谁执行 |
|------|------|---------|
| 1 | `@PreDestroy` | CommonAnnotationBeanPostProcessor（postProcessBeforeDestruction） |
| 2 | `DisposableBean.destroy()` | 容器直接调用 |
| 3 | `destroy-method` | 容器反射调用 |

和初始化三件套**顺序完全对应**：注解 → 接口 → XML/配置。

## 八、完整生命周期全景图（带扩展点）

```text
BeanDefinition 注册
  → 实例化 (构造器/工厂方法/Supplier)
  → InstantiationAwareBeanPostProcessor.postProcessBeforeInstantiation（可返回代理提前短路）
  → 构造器推断 & new 对象
  → InstantiationAwareBeanPostProcessor.postProcessAfterInstantiation
  → 属性填充 populateBean（@Autowired/@Value 注入）
  → BeanNameAware / BeanClassLoaderAware / BeanFactoryAware
  → ApplicationContextAware 等（仅容器存在时）
  → BeanPostProcessor.postProcessBeforeInitialization（@PostConstruct 在此触发）
  → InitializingBean.afterPropertiesSet
  → init-method
  → BeanPostProcessor.postProcessAfterInitialization（AOP 代理在此生成）
  → 放入单例池 ✅ 使用中
  → 容器关闭
  → @PreDestroy（postProcessBeforeDestruction）
  → DisposableBean.destroy
  → destroy-method
```

## 九、面试高频追问

**Q1：@PostConstruct、InitializingBean、init-method 的执行顺序？**
@PostConstruct → afterPropertiesSet → init-method。前者在 BeanPostProcessor 的 before 阶段执行，后两者在 invokeInitMethods 中按序执行。

**Q2：BeanPostProcessor 和 BeanFactoryPostProcessor 的区别？**
前者作用在 **Bean 实例**上（实例化后、初始化前后），后者作用在 **BeanDefinition** 上（所有 Bean 实例化之前），如 `PropertySourcesPlaceholderConfigurer` 处理 `${...}` 占位符。

**Q3：AOP 代理在生命周期的哪个环节生成？**
`postProcessAfterInitialization`，即初始化完成之后。因此自调用不走代理，@Transactional 自调用失效。

**Q4：原型 Bean 走完整生命周期吗？**
原型 Bean 会走实例化、属性填充、初始化，但**没有销毁回调**（容器不管理原型 Bean 的生命周期），每次 getBean 都新建。

**Q5：在哪里能拿到代理对象而不是原始对象？**
在 `postProcessAfterInitialization` 及其之后的任何地方（注入到其他 Bean 的属性、Aware 回调之后）。在 `postProcessBeforeInitialization` 里拿到的是原始对象。

## 总结

Bean 生命周期 = **定义加载 → 实例化 → 属性填充 → Aware → 初始化前增强 → 初始化（注解/接口/XML 三件套）→ 初始化后增强（AOP）→ 单例池 → 销毁三件套**。面试时先画时间线，再答每个扩展点"什么时候调用、用来干什么"，最后用循环依赖和 AOP 两个案例展示源码深度，就是满分回答。
