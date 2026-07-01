---
title: 彻底搞懂 Spring 循环依赖：三级缓存原理与源码解析
date: 2026-07-01 08:00:00
tags:
  - Spring
  - Spring Boot
  - 源码
  - 面试
categories:
  - Spring
  - 框架源码
author: 东哥
---

# 彻底搞懂 Spring 循环依赖：三级缓存原理与源码解析

## 前言

Spring 面试中有一个 **高频必问题**：Spring 是如何解决循环依赖的？

> **面试官：** 有两个 Bean A 和 B，A 依赖 B，B 又依赖 A，Spring 是怎么完成初始化的？

本文将带你从「是什么→为什么→怎么做」三层递进，彻底搞懂 Spring 的循环依赖机制。

---

## 一、什么是循环依赖？

循环依赖是指两个或多个 Bean 之间相互依赖，形成闭环。

```
A → B → C → A （三个 Bean 形成闭环）
A → B → A     （两个 Bean 相互依赖）
```

```java
@Component
public class A {
    @Autowired
    private B b;
}

@Component
public class B {
    @Autowired
    private A a;
}
```

### 哪些循环依赖 Spring 能解决？

| 依赖注入方式 | 能否解决 | 原因 |
|:----------:|:-------:|------|
| Setter 注入（@Autowired） | ✅ 可以 | 通过三级缓存暴露早期引用 |
| 字段注入（@Autowired） | ✅ 可以 | 本质也是属性注入 |
| 构造器注入 | ❌ 不能 | 构造器在实例化时就需要传入依赖，但此时 Bean 尚未创建 |
| prototype scope | ❌ 不能 | Spring 不缓存 prototype Bean，无法暴露早期引用 |

---

## 二、三级缓存的结构

Spring 使用 **三级缓存** 来解决 Setter/字段注入的循环依赖。定义在 `DefaultSingletonBeanRegistry` 中：

```java
// 一级缓存：完整可用的单例 Bean（已完成所有初始化）
private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);

// 二级缓存：提前暴露的半成品 Bean（已实例化，未完成属性注入）
private final Map<String, Object> earlySingletonObjects = new ConcurrentHashMap<>(16);

// 三级缓存：存储 ObjectFactory，用于生成早期引用（可进行 AOP 代理）
private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);
```

| 缓存级别 | 名称 | 存储内容 |
|:-------:|:---:|---------|
| 一级缓存 | `singletonObjects` | 完全初始化好的 Bean（成品） |
| 二级缓存 | `earlySingletonObjects` | 实例化但未完成属性注入的 Bean（半成品） |
| 三级缓存 | `singletonFactories` | ObjectFactory 工厂（生成提前暴露的代理对象） |

---

## 三、解决流程深度解析

以 A 和 B 循环依赖为例，模拟完整流程：

### Step 1：创建 A

Spring 开始创建 A 的实例，调用 `createBeanInstance()` 通过无参构造器创建 A 的 **原始对象**（此时只是一个空壳，属性都没赋值）。

### Step 2：A 提前暴露

A 的原始对象创建完成后，会调用 `addSingletonFactory()` 将 A 放入 **三级缓存**：

```java
// AbstractAutowireCapableBeanFactory.doCreateBean()
protected void addSingletonFactory(String beanName, ObjectFactory<?> singletonFactory) {
    synchronized (this.singletonObjects) {
        if (!this.singletonObjects.containsKey(beanName)) {
            // 放入三级缓存
            this.singletonFactories.put(beanName, singletonFactory);
            // 从二级缓存移除（保证一致性）
            this.earlySingletonObjects.remove(beanName);
            this.registeredSingletons.add(beanName);
        }
    }
}
```

这里的 `ObjectFactory` 是核心——它负责将原始 Bean 包装一层，如果是 AOP 代理对象，就在这里生成代理。

### Step 3：A 填充属性，发现依赖 B

A 进行属性注入时，发现需要 B，于是去容器中获取 B。

### Step 4：创建 B

容器发现 B 还没有创建，开始创建 B 的实例。同样的流程：实例化 B → B 放入三级缓存 → 属性注入。

### Step 5：B 填充属性发现依赖 A

B 进行属性注入时，发现需要 A。

### Step 6：从缓存获取 A 的早期引用

```java
// DefaultSingletonBeanRegistry.getSingleton()
protected Object getSingleton(String beanName, boolean allowEarlyReference) {
    // 第一步：查一级缓存（成品）
    Object singletonObject = this.singletonObjects.get(beanName);
    if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
        // 第二步：查二级缓存（半成品）
        singletonObject = this.earlySingletonObjects.get(beanName);
        if (singletonObject == null && allowEarlyReference) {
            synchronized (this.singletonObjects) {
                singletonObject = this.singletonObjects.get(beanName);
                if (singletonObject == null) {
                    singletonObject = this.earlySingletonObjects.get(beanName);
                    if (singletonObject == null) {
                        // 第三步：从三级缓存获取 ObjectFactory，生产早期引用
                        ObjectFactory<?> singletonFactory = this.singletonFactories.get(beanName);
                        if (singletonFactory != null) {
                            // 执行 getObject() — 可能产生 AOP 代理对象
                            singletonObject = singletonFactory.getObject();
                            // 提升到二级缓存
                            this.earlySingletonObjects.put(beanName, singletonObject);
                            // 移除三级缓存
                            this.singletonFactories.remove(beanName);
                        }
                    }
                }
            }
        }
    }
    return singletonObject;
}
```

**流程**：
- 先查一级缓存（没有，A 还没初始化完）
- 再查二级缓存（没有，还没放进去）
- 从三级缓存获取 A 的 `ObjectFactory`，调用 `getObject()` 拿到 A 的 **早期引用**
- 将早期引用 **提升到二级缓存**，移除三级缓存
- 返回 A 的早期引用给 B

B 拿着 A 的早期引用（可能是原始对象，也可能是 AOP 代理对象）完成属性注入。

### Step 7：B 完成初始化

B 属性注入完了，继续执行剩余的初始化流程（`init-method`、`afterPropertiesSet` 等），然后放入 **一级缓存**（成品）。

### Step 8：A 继续完成初始化

B 已经放入一级缓存了，A 重新回到自己的属性注入流程，从一级缓存获取到完整的 B。然后 A 完成剩余初始化，放入一级缓存。

---

## 四、为什么需要三级缓存？

这是一个经典追问：「为什么是三级缓存，不是两级？」

核心原因：**AOP 代理**。

如果不需要 AOP，二级缓存就够了（一级存成品、二级存半成品）。但 Spring 的 AOP 是在 **初始化后** 通过 `BeanPostProcessor` 生成代理对象的。

试想以下场景：

1. A 需要被 AOP 代理。
2. 如果只有二级缓存，B 从缓存拿到的是 **A 的原始对象**。
3. 但最终 A 的代理对象与原始对象不是同一个。
4. B 持有的还是原始对象 → **不是同一个 Bean，出错！**

三级缓存的 `ObjectFactory` 解决了这个问题：

```java
// AbstractAutoProxyCreator 在 postProcessAfterInitialization 之前，
// 就已经通过 SmartInstantiationAwareBeanPostProcessor.getEarlyBeanReference()
// 把代理逻辑注入了 ObjectFactory，保证早期引用就是代理对象
```

**一句话总结**：三级缓存保证了 **无论 Bean 被提前引用的时间点如何，拿到的都是最终的那个代理对象**。

---

## 五、无法解决的循环依赖

### 构造器注入

```java
@Component
public class A {
    private B b;
    
    public A(B b) { this.b = b; } // ❌ 构造器需要 B
}

@Component
public class B {
    private A a;
    
    public B(A a) { this.a = a; } // ❌ 构造器需要 A
}
```

报错：`BeanCurrentlyInCreationException`。

**解法**：
- 改用 Setter/字段注入
- 使用 `@Lazy` 延迟代理

```java
public A(@Lazy B b) { this.b = b; }
```

### prototype 作用域

Spring 不缓存 prototype Bean，因此即使有三级缓存也无法解决。

---

## 六、面试官追问清单

**Q1：为什么 Spring 不用二级缓存而是三级？**

如果不需要 AOP 代理，两级缓存就够了。但需要 AOP 时，三级缓存的 ObjectFactory 可以保证提前引用的对象就是最终的代理对象。二级缓存无法做到，因为它只能存储原始对象。

**Q2：三级缓存中的 ObjectFactory 什么时候会被调用？**

当其他 Bean 尝试获取当前正在创建的 Bean 的早期引用时（即循环依赖触发点），`getSingleton()` 会从三级缓存取出 ObjectFactory，调用 `getObject()` 获取早期引用。

**Q3：如果把三级缓存改为两级，AOP 循环依赖会怎样？**

B 拿到的是 A 的原始对象，但最终容器中存的是 A 的代理对象，B 持有的引用不一致，会导致功能异常（AOP 增强不生效或 NPE）。

**Q4：哪些扩展点参与了三级缓存机制？**

`SmartInstantiationAwareBeanPostProcessor.getEarlyBeanReference()` 是三级缓存的扩展入口。`AbstractAutoProxyCreator` 实现了该方法，在早期引用时就注入 AOP 代理逻辑。

---

## 总结

Spring 的三级缓存机制是 IoC 容器的精妙设计：

- **一级缓存** → 成品（完整可用的 Bean）
- **二级缓存** → 半成品（提前暴露的引用）
- **三级缓存** → 工厂（生成代理，解决 AOP 问题）

记住一个比喻：**一级是商店货架上的商品，二级是仓库里的半成品，三级是生产车间的流水线**。三级缓存本质上是在「Bean 还没造好」和「别人先要用了」之间搭了一座桥，而第三层的 ObjectFactory 就是这座桥的设计图纸，确保桥的形状（代理与否）由一人统一规划。
