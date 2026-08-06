---
title: 【设计模式】工厂模式深度解析：从简单工厂到抽象工厂，再到 Spring BeanFactory 源码
date: 2026-08-06 08:00:00
tags:
  - Java
  - 设计模式
  - Spring
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】工厂模式深度解析：从简单工厂到抽象工厂，再到 Spring BeanFactory 源码

## 面试官：说说工厂模式有哪几种？它们之间有什么区别？

工厂模式（Factory Pattern）是 Java 开发中使用频率最高的创建型设计模式，核心思想是：**将对象的创建和使用分离，由「工厂」负责创建对象，调用方只关心「要什么」，不关心「怎么造」**。

工厂模式家族一共三个成员，面试时最容易混淆，先用一张表分清：

| 类型 | 核心思想 | 创建方式 | 扩展点 | 典型场景 |
|------|---------|---------|--------|---------|
| 简单工厂（非 GoF 23 种） | 一个工厂类，根据参数 switch 创建不同产品 | 静态方法 + if/switch | 新增产品要改工厂类，违反开闭 | 工具类、类型简单时 |
| 工厂方法 | 每个产品对应一个工厂类，工厂接口 + 具体工厂 | 子类工厂覆盖工厂方法 | 新增产品只需新增工厂类，符合开闭 | 框架扩展点，如 JDBC DriverManager、MyBatis SqlSessionFactory |
| 抽象工厂 | 工厂接口定义一组产品族，一个工厂创建一族产品 | 工厂接口 + 多产品接口 | 新增产品族方便，新增产品难 | 跨平台 UI 组件、数据库连接族 |

一句话记忆：**简单工厂管「一个工厂造所有」，工厂方法管「一个工厂造一种」，抽象工厂管「一个工厂造一族」**。

---

## 一、简单工厂：最朴素，也最容易被问「为什么不好」

```java
public class ShapeFactory {
    public static Shape create(String type) {
        switch (type) {
            case "circle": return new Circle();
            case "rect":   return new Rect();
            default: throw new IllegalArgumentException("未知类型：" + type);
        }
    }
}
```

**优点**：调用方与具体类解耦，代码简单。
**缺点**：新增 `Triangle` 必须修改 `ShapeFactory`，**违反开闭原则**；工厂类职责过重，逻辑全堆在一个方法里。

面试官常问：**「简单工厂算不算设计模式？」** 严格来说它不是 GoF 23 种设计模式之一，只是一个编程习惯/约定，但它是最容易理解工厂思想的入门形态。

---

## 二、工厂方法：把「创建」延迟到子类

工厂方法模式定义：**定义一个创建对象的接口，让子类决定实例化哪个类。工厂方法使一个类的实例化延迟到其子类**。

```java
// 产品接口
public interface Logger {
    void log(String msg);
}

// 具体产品
public class FileLogger implements Logger {
    public void log(String msg) { /* 写文件 */ }
}
public class ConsoleLogger implements Logger {
    public void log(String msg) { /* 写控制台 */ }
}

// 工厂接口：声明工厂方法
public interface LoggerFactory {
    Logger createLogger();
}

// 具体工厂：每个工厂只造一种产品
public class FileLoggerFactory implements LoggerFactory {
    public Logger createLogger() { return new FileLogger(); }
}
public class ConsoleLoggerFactory implements LoggerFactory {
    public Logger createLogger() { return new ConsoleLogger(); }
}

// 使用：面向工厂接口编程，替换实现零成本
LoggerFactory factory = new FileLoggerFactory();
Logger logger = factory.createLogger();
```

**开闭原则体现**：新增 `DbLogger`，只需要新增 `DbLogger` + `DbLoggerFactory`，**不用改任何已有代码**。

### JDK 中的工厂方法

- `Iterator` 接口：`ArrayList.iterator()`、`HashMap.keySet().iterator()`，每个集合用自己的工厂方法返回自己的迭代器。
- `java.util.concurrent.ThreadFactory`：`newThread(Runnable)` 由线程池工厂统一创建线程，方便设置线程名、优先级、守护线程。
- **Spring 的 FactoryBean**：`getObject()` 就是工厂方法，让 Bean 的创建过程可以自定义（比如创建代理对象、从远程获取对象）。

```java
// Spring 中自定义 FactoryBean 的经典写法
@Component
public class MyFactoryBean implements FactoryBean<ComplexService> {
    @Override
    public ComplexService getObject() {
        return new ComplexService("由 FactoryBean 定制创建");
    }
    @Override
    public Class<?> getObjectType() { return ComplexService.class; }
    @Override
    public boolean isSingleton() { return true; }
}
```

注意区分：`BeanFactory`（容器本身）vs `FactoryBean`（创建 Bean 的工厂 Bean）——**BeanFactory 是容器，FactoryBean 是特殊的 Bean**，这是 Spring 面试经典易混点。

---

## 三、抽象工厂：产品族的概念

抽象工厂模式定义：**提供一个创建一系列相关或相互依赖对象的接口，而无需指定它们具体的类**。

核心是「产品族」：比如一套 UI 主题，包含按钮、输入框、对话框；每个主题工厂能产出「整套」组件，保证风格统一。

```java
// 产品接口：按钮、输入框
public interface Button { void render(); }
public interface Input { void render(); }

// 产品族 A：深色主题
public class DarkButton implements Button { public void render() { /* 深色按钮 */ } }
public class DarkInput implements Input { public void render() { /* 深色输入框 */ } }

// 产品族 B：浅色主题
public class LightButton implements Button { public void render() { /* 浅色按钮 */ } }
public class LightInput implements Input { public void render() { /* 浅色输入框 */ } }

// 抽象工厂：定义一族产品
public interface ThemeFactory {
    Button createButton();
    Input createInput();
}

// 具体工厂：一个工厂造一族
public class DarkThemeFactory implements ThemeFactory {
    public Button createButton() { return new DarkButton(); }
    public Input createInput() { return new DarkInput(); }
}
public class LightThemeFactory implements ThemeFactory {
    public Button createButton() { return new LightButton(); }
    public Input createInput() { return new LightInput(); }
}

// 使用：切换主题只改一行
ThemeFactory factory = new DarkThemeFactory();
Button btn = factory.createButton();   // 保证整套都是深色
Input input = factory.createInput();
```

**抽象工厂的痛点**：新增一种产品（如 `Checkbox`），所有具体工厂都要加方法——**新增产品族容易，新增产品难**，这就是「开闭原则的倾斜性」。

### 实际中的抽象工厂：java.sql

`Connection` 接口可以 `createStatement()`、`prepareStatement()`、`createCallableStatement()`——它就是一个抽象工厂，一次创建一族 SQL 执行对象；MySQL 驱动和 Oracle 驱动分别实现了自己的 Connection，**换驱动不用改业务代码**，这就是抽象工厂在 JDBC 中的经典落地。

---

## 四、Spring BeanFactory：工厂模式的集大成者

Spring 的 `BeanFactory` 是工厂方法 + 抽象思想在框架级的极致体现：

```java
public interface BeanFactory {
    Object getBean(String name) throws BeansException;
    <T> T getBean(String name, Class<T> requiredType) throws BeansException;
    boolean containsBean(String name);
    boolean isSingleton(String name);
    // ...
}
```

### BeanFactory 创建 Bean 的核心流程（简化版）

1. **解析 BeanDefinition**：读取 XML/注解/配置类，把 Bean 的元信息（类名、作用域、依赖、初始化方法）封装成 `BeanDefinition`。
2. **实例化**：通过反射 `Class.forName + newInstance` 或工厂方法创建原始对象。
3. **属性填充（依赖注入）**：通过 `AutowiredAnnotationBeanPostProcessor` 等后置处理器注入 `@Autowired` 依赖。
4. **初始化**：执行 `InitializingBean.afterPropertiesSet()`、`@PostConstruct`、`init-method`。
5. **返回就绪 Bean**：默认单例会缓存到 `singletonObjects`。

```java
// 简化版：BeanFactory 核心创建逻辑（伪代码）
public Object getBean(String name) {
    Object bean = singletonObjects.get(name);      // 1. 单例缓存
    if (bean != null) return bean;
    BeanDefinition bd = beanDefinitionMap.get(name); // 2. 获取元信息
    Object instance = createBeanInstance(bd);        // 3. 反射实例化
    applyPropertyValues(instance, bd);               // 4. 属性填充
    initializeBean(instance, bd);                    // 5. 初始化回调
    return instance;
}
```

### BeanFactory vs ApplicationContext

| 对比项 | BeanFactory | ApplicationContext |
|--------|-------------|-------------------|
| 定位 | 最底层的 IoC 容器 | BeanFactory 的增强版 |
| 扩展功能 | 只有 Bean 管理 | + 事件、国际化、资源加载、AOP 集成 |
| 加载时机 | 懒加载（getBean 时才创建） | 预加载（启动时创建单例） |
| 实际使用 | 框架内部 | 日常开发用这个 |

**一句话**：`ApplicationContext` 是「BeanFactory + 企业级增强」，开发中用 `ApplicationContext`，研究源码从 `BeanFactory` 入手。

---

## 五、工厂模式与 Spring 面试高频追问

1. **Spring 是怎么用工厂模式创建 Bean 的？** → 反射实例化 + BeanFactory 统一管理；`FactoryBean` 定制创建；`@Bean` 方法本质上也是工厂方法。
2. **简单工厂、工厂方法、抽象工厂如何选择？** → 产品类型单一用简单工厂；产品按类型扩展用工厂方法；需要成套产品（产品族）用抽象工厂。
3. **工厂模式和策略模式的区别？** → 工厂是创建型（管「造对象」），策略是行为型（管「换算法」）；但工厂常和策略配合：用工厂创建策略对象。
4. **如何用工厂模式干掉 if-else？** → 把每个分支封装成策略 + 用工厂根据类型获取对应实现，配合 Spring 的 `Map<String, Strategy>` 注入，代码即优雅又符合开闭原则。
5. **静态工厂方法 vs 构造器？** → 静态工厂可以起语义化名字（`of`、`from`、`valueOf`）、可返回子类/缓存实例、可控制实例数量（单例）——Effective Java 第一条建议优先用静态工厂。

**工厂模式本质**：把「new」从业务代码中剥离，统一交给工厂管理。它解决的是创建逻辑复用与解耦问题，是 Spring 整个 IoC 容器的设计基石。面试时能把「工厂模式 → BeanFactory → Bean 生命周期」这条线串起来讲，基本就稳了。
