---
title: 【Spring 源码】Spring Bean 生命周期深度解析：从实例化到销毁的完整链路
date: 2026-08-10 08:00:00
tags:
  - Spring
  - 源码
  - 面试
categories:
  - Spring
  - 后端面试
author: 东哥
---

# 【Spring 源码】Spring Bean 生命周期深度解析：从实例化到销毁的完整链路

## 面试官：一个 Spring Bean 从创建到销毁，经历了哪些阶段？

「Bean 生命周期」是 Spring 面试的必考题，也是很多人背了又忘的八股。原因是大家只背结论列表，不理解背后的**执行时机**和**设计意图**。其实 Bean 的生命周期就是一套**模板方法模式**的完美演绎：Spring 定义骨架流程，把扩展点留给开发者。

今天我们从 `BeanFactory` 到 `ApplicationContext` 两条链路，把 Bean 的完整生命周期拆解成 11 个阶段，配合源码定位，让你不仅知道「有哪些阶段」，还知道「为什么有这些阶段」。

## 一、整体流程图

```
Bean 定义加载（BeanDefinition）
        ↓
① 实例化（构造器/new 对象）
② 属性填充（依赖注入 @Autowired/@Resource）
③ Aware 回调（BeanNameAware / BeanFactoryAware / ApplicationContextAware）
④ BeanPostProcessor#postProcessBeforeInitialization（前置处理）
⑤ @PostConstruct（JSR-250 注解初始化）
⑥ InitializingBean#afterPropertiesSet（接口初始化）
⑦ 自定义 init-method（XML/@Bean(initMethod=...)）
⑧ BeanPostProcessor#postProcessAfterInitialization（后置处理 → 生成代理的时机）
        ↓  —— 到这里 Bean 就可以使用了 ——
⑨ 容器关闭：@PreDestroy
⑩ DisposableBean#destroy
⑪ 自定义 destroy-method
```

## 二、三个前置概念

### 2.1 BeanDefinition：Bean 的「出生证明」

Spring 不是直接用 `new` 创建对象，而是先把配置解析成 `BeanDefinition`（bean 的类、作用域、属性、初始化方法等元信息），存进 `BeanDefinitionRegistry`。实例化时根据这份元信息来创建。

### 2.2 两大 IOC 容器差异

- **BeanFactory**：基础容器，Bean 默认**懒加载**（getBean 时才创建）。
- **ApplicationContext**：BeanFactory 的子接口，默认**预实例化**（启动时创建单例 Bean），并额外提供国际化、事件发布、AOP 集成等能力。

### 2.3 扩展点分类

| 类别 | 接口/注解 | 生效时机 |
|------|-----------|----------|
| 感知类 | Aware 系列 | 属性填充后 |
| 初始化类 | @PostConstruct / InitializingBean / init-method | 前置处理之后 |
| 后处理类 | BeanPostProcessor | 初始化前后各一次 |
| 销毁类 | @PreDestroy / DisposableBean / destroy-method | 容器关闭时 |

## 三、逐阶段源码解析

### 阶段 ① 实例化

`AbstractAutowireCapableBeanFactory#createBeanInstance`：根据 BeanDefinition 选择实例化策略——构造器注入、静态工厂、实例工厂。默认用无参构造器反射创建（`instantiateBean`）。**注意：此时对象已存在，但属性还是 null**。

### 阶段 ② 属性填充

`populateBean`：执行依赖注入。Spring 会遍历 `PropertyValues`，处理 `@Autowired`、`@Resource`、`@Value` 等注解（通过 `AutowiredAnnotationBeanPostProcessor` 等后处理器完成），把依赖的 Bean 注入进来。

**此时循环依赖的「提前暴露」也发生在这个阶段**：单例 Bean 通过三级缓存提前暴露半成品，供依赖方引用（这正是三级缓存存在的意义）。

### 阶段 ③ Aware 回调

`invokeAwareMethods`（BeanFactory 容器）或 `ApplicationContextAwareProcessor`（ApplicationContext 容器）回调各种 Aware 接口，让 Bean 感知容器：

```java
// AbstractAutowireCapableBeanFactory#invokeAwareMethods
if (bean instanceof BeanNameAware) {
    ((BeanNameAware) bean).setBeanName(beanName);
}
if (bean instanceof BeanClassLoaderAware) {
    ((BeanClassLoaderAware) bean).setBeanClassLoader(bcl);
}
if (bean instanceof BeanFactoryAware) {
    ((BeanFactoryAware) bean).setBeanFactory(this);
}
```

ApplicationContext 容器额外支持 `ApplicationContextAware`、`EnvironmentAware`、`ApplicationEventPublisherAware` 等（由 `ApplicationContextAwareProcessor` 回调）。

### 阶段 ④ ~ ⑧ 初始化链路

`initializeBean` 方法串联了核心逻辑：

```java
protected Object initializeBean(String beanName, Object bean, RootBeanDefinition mbd) {
    // 阶段③：Aware 回调
    invokeAwareMethods(beanName, bean);

    // 阶段④：前置处理 —— 所有 BeanPostProcessor 的 before 方法
    Object wrappedBean = applyBeanPostProcessorsBeforeInitialization(wrappedBean, beanName);

    // 阶段⑤⑥⑦：执行初始化
    invokeInitMethods(beanName, wrappedBean, mbd);

    // 阶段⑧：后置处理 —— 所有 BeanPostProcessor 的 after 方法
    wrappedBean = applyBeanPostProcessorsAfterInitialization(wrappedBean, beanName);
    return wrappedBean;
}

protected void invokeInitMethods(String beanName, Object bean, RootBeanDefinition mbd) {
    // 阶段⑥：InitializingBean 接口
    boolean isInitializingBean = (bean instanceof InitializingBean);
    if (isInitializingBean) {
        ((InitializingBean) bean).afterPropertiesSet();
    }
    // 阶段⑦：自定义 init-method
    if (mbd != null && bean.getClass() != NullBean.class) {
        String initMethodName = mbd.getInitMethodName();
        if (initMethodName != null && !(isInitializingBean && "afterPropertiesSet".equals(initMethodName))) {
            invokeCustomInitMethod(beanName, bean, mbd);
        }
    }
}
```

那 `@PostConstruct` 在哪执行？它由 `CommonAnnotationBeanPostProcessor` 处理，这个处理器就是注册在 BeanPostProcessor 链上的——**在 `postProcessBeforeInitialization` 阶段调用 `@PostConstruct` 方法**。所以顺序是：④`@PostConstruct`（before 处理器内）→ ⑥`afterPropertiesSet` → ⑦`init-method`。

**执行顺序记忆口诀：注解（@PostConstruct）→ 接口（InitializingBean）→ 配置（init-method）**。

### 阶段 ⑧ 为什么是 AOP 代理的时机？

`AbstractAutoProxyCreator`（AOP 自动代理的后处理器）在 `postProcessAfterInitialization` 中判断 Bean 是否需要代理，需要就返回代理对象。**所以 AOP 代理在初始化之后才生成**，这也是为什么 Spring 代理对象调用内部方法（this 调用）不生效——因为目标方法调用发生在代理内部，绕过了代理逻辑。

### 阶段 ⑨ ~ ⑪ 销毁链路

容器关闭（`close()` / `ContextClosedEvent`）时，`doClose` → `destroyBeans`：

```java
// DisposableBeanAdapter 顺序：先 @PreDestroy，再 DisposableBean.destroy，再 destroy-method
// 与初始化顺序相反：配置（destroy-method）在最外，注解在最先执行
```

**销毁顺序与初始化相反**：`@PreDestroy` → `destroy()` → `destroy-method`。为什么相反？依赖关系：被依赖者后销毁（先销毁依赖者，再销毁被依赖者，保证不引用已销毁的 Bean）。

## 四、完整代码演示

```java
@Component
public class LifecycleDemo implements InitializingBean, DisposableBean, BeanNameAware {

    private String beanName;

    @Override
    public void setBeanName(String name) {   // 阶段③
        this.beanName = name;
        System.out.println("3. setBeanName: " + name);
    }

    @PostConstruct                              // 阶段⑤
    public void postConstruct() {
        System.out.println("5. @PostConstruct");
    }

    @Override
    public void afterPropertiesSet() {          // 阶段⑥
        System.out.println("6. afterPropertiesSet");
    }

    @Bean(initMethod = "customInit", destroyMethod = "customDestroy")  // 或 XML 配置
    // 阶段⑦ customInit / 阶段⑪ customDestroy
    public void customInit() {
        System.out.println("7. customInit");
    }

    @PreDestroy                                 // 阶段⑨
    public void preDestroy() {
        System.out.println("9. @PreDestroy");
    }

    @Override
    public void destroy() {                     // 阶段⑩
        System.out.println("10. destroy");
    }

    public void customDestroy() {               // 阶段⑪
        System.out.println("11. customDestroy");
    }
}
```

再注册一个 BeanPostProcessor 观察④⑧：

```java
@Component
public class LogBeanPostProcessor implements BeanPostProcessor {
    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        System.out.println("4. beforeInit: " + beanName);
        return bean;
    }
    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        System.out.println("8. afterInit: " + beanName);
        return bean;
    }
}
```

启动容器，输出顺序完全对应 ①~⑪ 的流程图。

## 五、几个高频追问

**Q1：BeanPostProcessor 和 BeanFactoryPostProcessor 的区别？**
前者作用于 **Bean 实例**（对象创建后，可修改/包装 Bean）；后者作用于 **BeanDefinition**（容器启动早期，Bean 还没实例化时，可修改 Bean 的元信息）。典型如 `PropertySourcesPlaceholderConfigurer` 解析 `${...}` 占位符——它必须在 Bean 实例化前把占位符替换掉。

**Q2：为什么 @PostConstruct 一定在 afterPropertiesSet 之前？**
`@PostConstruct` 由 `CommonAnnotationBeanPostProcessor` 的 before 方法调用，而 `afterPropertiesSet` 在 `invokeInitMethods` 中调用，前者天然排在链路前面。面试可以答「一个是后处理器 before 阶段，一个是初始化阶段，顺序由模板方法固定」。

**Q3：原型（Prototype）Bean 的生命周期有什么不同？**
**初始化阶段完全一样**，但 Spring **不管理原型 Bean 的销毁**——没有回调 destroy 方法的机会（`DisposableBean` 不生效，除非手动调用 `beanFactory.destroyBean()`）。因为容器不知道原型 Bean 创建了多少个、该销毁哪个。

**Q4：循环依赖时 Bean 的生命周期会被打断吗？**
会。A 依赖 B、B 依赖 A 时，A 在**属性填充阶段**发现依赖 B，转而创建 B；B 填充时发现依赖 A，从**三级缓存**拿到 A 的提前暴露引用（此时 A 还没执行初始化）。所以循环依赖下，A 的初始化被延后到 B 创建完成之后。

**Q5：init-method 和 InitializingBean 同时配了会执行几次？**
两次，但 Spring 做了去重：若 init-method 名恰好是 `afterPropertiesSet`，则只执行一次（源码里 `!(isInitializingBean && "afterPropertiesSet".equals(initMethodName))` 的判断）。

## 六、总结

| 阶段 | 扩展点 | 一句话记忆 |
|------|--------|-----------|
| 实例化 | 构造器 | 对象诞生，属性为空 |
| 属性填充 | DI | 依赖注入完成 |
| Aware | Aware 接口 | 感知容器 |
| before | BeanPostProcessor | 前置处理（含 @PostConstruct） |
| init | InitializingBean / init-method | 初始化回调 |
| after | BeanPostProcessor | 后置处理（AOP 代理在此） |
| destroy | @PreDestroy / destroy / destroy-method | 容器关闭，反向销毁 |

Bean 生命周期本质是**模板方法模式 + 观察者模式（后处理器链）**的结合：Spring 定好骨架，扩展点全开，开发者按需插入逻辑。理解了这个设计，你就从「背八股」进阶到「懂设计」了。
