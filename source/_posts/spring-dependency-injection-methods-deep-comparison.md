---
title: 【Spring 核心】依赖注入方式深度对比：构造器注入 vs Setter 注入 vs 字段注入，附 @Autowired/@Resource/@Inject 区别
date: 2026-08-19 08:00:00
tags:
  - Spring
  - 依赖注入
  - 面试
  - Spring Boot
categories:
  - Spring
  - 后端面试
author: 东哥
---

# 【Spring 核心】依赖注入方式深度对比：构造器注入 vs Setter 注入 vs 字段注入，附 @Autowired/@Resource/@Inject 区别

## 面试官：Spring 的依赖注入有哪几种方式？你平时用哪种？为什么？

Spring 最核心的 IOC 思想就是**依赖注入（DI）**：对象的依赖不由自己 new，而由容器负责装配。但"注入"本身有三种姿势，各有优劣。面试官通常还会追加一句："**Spring 官方推荐哪种？为什么？**"——这一问就能筛掉一大半人。

今天把三种注入方式、三个注入注解，从用法到源码全部讲透。

---

## 一、三种注入方式：用法与对比

### 1.1 构造器注入（Constructor Injection）

```java
@Service
public class OrderService {

    private final OrderMapper orderMapper;
    private final PaymentClient paymentClient;

    // 容器自动找构造器，按参数类型装配
    public OrderService(OrderMapper orderMapper, PaymentClient paymentClient) {
        this.orderMapper = orderMapper;
        this.paymentClient = paymentClient;
    }
}
```

Spring 4.3+ 之后，**单个构造器可以省略 @Autowired**，容器自动使用。多个构造器时需要显式标注。

### 1.2 Setter 注入（Setter Injection）

```java
@Service
public class OrderService {

    private OrderMapper orderMapper;

    @Autowired
    public void setOrderMapper(OrderMapper orderMapper) {
        this.orderMapper = orderMapper;
    }
}
```

### 1.3 字段注入（Field Injection）

```java
@Service
public class OrderService {

    @Autowired
    private OrderMapper orderMapper;   // 最常见但最被诟病的写法
}
```

---

## 二、核心对比：一张表看懂

| 维度 | 构造器注入 | Setter 注入 | 字段注入 |
|---|---|---|---|
| 依赖可见性 | 构造器签名一目了然 | setter 可见 | 字段可见但无约束 |
| 不可变性 | ✅ final 字段，不可变 | ❌ 可被后续修改 | ❌ 可被反射/后续修改 |
| 必填依赖保证 | ✅ 编译期强制 | ⚠️ 不调用 setter 就为 null | ⚠️ 忘记注入就是 null |
| 循环依赖支持 | ❌ 直接报错（BeanCurrentlyInCreationException） | ✅ 可解决（三级缓存） | ✅ 可解决（三级缓存） |
| 可测试性 | ✅ new 出来直接传参 | ✅ 手动 set 即可 | ❌ 必须反射或 Spring 容器 |
| 职责单一 | ✅ 构造时完整初始化 | ⚠️ 可拆多次调用 | ⚠️ 容易堆一堆依赖 |
| 冗余代码 | 略多（但 Lombok @RequiredArgsConstructor 可消除） | setter 方法多 | 最少 |
| Spring 官方态度 | ✅ 首选 | ✅ 可选依赖可用 | ⚠️ 不推荐（官方文档明确） |

### 为什么官方强烈推荐构造器注入？

1. **依赖不可变**：`final` 字段保证依赖在对象生命周期内不会变，杜绝"运行中被偷偷替换"的诡异问题
2. **保证非空**：构造器强制所有必填依赖都传入，**编译期就能发现漏配**；字段注入漏配只有运行到用到时才 NPE
3. **可测试性**：`new OrderService(mapper, client)` 一行搞定，不需要 Spring 容器、不需要反射
4. **尽早失败**：容器启动时构造失败立刻暴露，而不是运行 N 天后才炸
5. **符合单一职责**：构造器参数过多会"闻起来很臭"，逼你重构拆分，字段注入则无声纵容上帝类

---

## 三、三种注入注解：@Autowired vs @Resource vs @Inject

### 3.1 @Autowired（Spring 提供）

- **按类型（byType）注入**，找不到唯一候选时：
  - 多个同类型 Bean → 按**字段名/参数名**匹配（byName 兜底）
  - 仍匹配不到 → 抛 `NoUniqueBeanDefinitionException`
- `required = false` 可声明非必须：`@Autowired(required = false)`，没有对应 Bean 就注入 null
- 可与 `@Qualifier("beanName")` 组合精确指定

```java
@Autowired
@Qualifier("alipayClient")
private PayClient payClient;
```

### 3.2 @Resource（JSR-250，JDK 自带）

- **先按名称（byName）注入，再按类型（byType）**。`name` 属性指定 Bean 名：

```java
@Resource(name = "alipayClient")
private PayClient payClient;
```

- 由于默认按字段名匹配，**多实现场景下比 @Autowired 更"直白"**，也是很多团队（如阿里规范）推荐用它替代 @Autowired 的原因

### 3.3 @Inject（JSR-330，javax.inject）

- 与 @Autowired 行为基本一致（byType + byName 兜底），**但没有 required 属性**，且需要额外引入 `javax.inject` 依赖
- 优势是**不绑定 Spring**，可移植到 Guice 等其他 DI 容器；代价是失去 Spring 特有功能（如 required=false、@Qualifier 的进阶用法）

### 对比表

| 注解 | 来源 | 默认装配策略 | required=false | 与 Spring 耦合 |
|---|---|---|---|---|
| @Autowired | Spring | byType → byName | ✅ | 强 |
| @Resource | JSR-250 (JDK) | byName → byType | ❌ | 弱 |
| @Inject | JSR-330 | byType → byName | ❌ | 无（需引依赖） |

> **经验法则**：项目里规范统一最重要。要么全 @Autowired + @Qualifier，要么全 @Resource。混用最容易出"为什么这个注入成功了那个报错"的灵异问题。

---

## 四、源码视角：注入是怎么发生的？

### 4.1 核心：AutowiredAnnotationBeanPostProcessor

字段注入和 Setter 注入的装配动作发生在 Bean 实例化后的**属性填充阶段**，由 `AutowiredAnnotationBeanPostProcessor` 这个 `InstantiationAwareBeanPostProcessor` 完成：

```java
// AbstractAutowireCapableBeanFactory.populateBean 大致流程
protected void populateBean(String beanName, RootBeanDefinition mbd, BeanWrapper bw) {
    // 1. 执行 InstantiationAwareBeanPostProcessor#postProcessProperties
    for (InstantiationAwareBeanPostProcessor bp : getBeanPostProcessorCache().instantiationAware) {
        PropertyValues pvsToUse = bp.postProcessProperties(pvs, bw.getWrappedInstance(), beanName);
        ...
    }
}

// AutowiredAnnotationBeanPostProcessor.postProcessProperties
public PropertyValues postProcessProperties(PropertyValues pvs, Object bean, String beanName) {
    // 收集该类所有 @Autowired / @Value / @Inject 标注的字段和方法
    InjectionMetadata metadata = findAutowiringMetadata(beanName, bean.getClass(), pvs);
    metadata.inject(bean, beanName, pvs);   // 逐个执行注入
    return pvs;
}
```

而**构造器注入**发生在更早的 `createBeanInstance` 阶段——容器在实例化对象时就通过构造器把依赖传进去，所以**没有"先 new 再注入"的中间态**，这也是它天然不支持循环依赖（需要先有实例才能注入，而构造器注入在 new 之前就要依赖）的根本原因。

### 4.2 循环依赖与三级缓存的关系

Spring 用**三级缓存**解决单例的循环依赖：

1. **一级缓存** `singletonObjects`：成品 Bean
2. **二级缓存** `earlySingletonObjects`：半成品 Bean（已实例化未完成属性填充）
3. **三级缓存** `singletonFactories`：ObjectFactory，可提前生成代理

```java
// DefaultSingletonBeanRegistry.getSingleton 核心逻辑
protected Object getSingleton(String beanName, boolean allowEarlyReference) {
    Object singletonObject = this.singletonObjects.get(beanName);   // 一级
    if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
        singletonObject = this.earlySingletonObjects.get(beanName); // 二级
        if (singletonObject == null && allowEarlyReference) {
            // 三级：执行 ObjectFactory，生成提前暴露的引用（可能含代理）
            singletonObject = singletonFactory.getObject();
            this.earlySingletonObjects.put(beanName, singletonObject);
        }
    }
    return singletonObject;
}
```

- **字段注入 / Setter 注入**：A 实例化后先放入三级缓存，填充属性时发现需要 B，B 填充时发现需要 A，直接从缓存拿到 A 的**半成品引用**——循环被打破 ✅
- **构造器注入**：A 的实例化本身就需要 B，B 又需要 A，此时 A **还没进三级缓存**，直接抛 `BeanCurrentlyInCreationException` ❌

所以**构造器注入无法解决循环依赖**。反过来这也是面试官爱问的点：**"你项目里有循环依赖吗？怎么解决的？"** —— 正确答案是：先通过重构消除循环依赖，而不是依赖三级缓存兜底（Spring 官方明确表示：循环依赖应该被避免，三级缓存只是兜底机制）。

---

## 五、实战选型建议（团队规范）

1. **必填依赖 → 构造器注入**，配合 Lombok 消除样板代码：

```java
@Service
@RequiredArgsConstructor   // 为 final 字段生成构造器
public class OrderService {
    private final OrderMapper orderMapper;
    private final PaymentClient paymentClient;
}
```

2. **可选依赖 → Setter 注入 + @Autowired(required = false)**（如非必选的告警客户端）
3. **字段注入**：仅限测试代码、配置类等非核心 Bean；业务 Bean 一律不用
4. **多实现**：@Autowired + @Qualifier，或 @Resource(name = "...")，二选一并写进团队规范
5. **禁止循环依赖**：出现 `BeanCurrentlyInCreationException` 先重构，而不是改成字段注入"绕过"

---

## 面试官常见追问

**Q：构造器注入遇到循环依赖怎么办？**
A：循环依赖本身是设计问题。优先重构（提取第三方依赖、用事件解耦、调整依赖方向）；Spring 的三级缓存只能兜住"先实例化后注入"的字段/Setter 场景。如果确实绕不开，可对其中一个 Bean 用 @Lazy 延迟注入，打破初始化期依赖。

**Q：@Autowired 和 @Resource 都能注入，区别是什么？**
A：@Autowired 是 Spring 注解，byType 优先、字段名兜底，支持 required=false 和 @Qualifier；@Resource 是 JSR-250 标准，byName 优先、byType 兜底，不依赖 Spring。多实现场景 @Resource(name=...) 更直观，且符合"弱耦合"规范。

**Q：为什么字段注入不推荐？明明代码最少。**
A：代码少但代价大：① 依赖不可见，类到底依赖什么要翻字段；② 非 final 可被篡改；③ 单元测试必须起容器或反射；④ 漏注入运行期才 NPE；⑤ 纵容类塞入过多依赖，违背单一职责。

**Q：一个类有多个构造器，Spring 怎么选？**
A：优先找标注 @Autowired 的构造器；没有标注且只有一个构造器时自动使用；有多个构造器且都没标注时，会尝试默认无参构造器，否则抛异常。所以多构造器场景务必显式 @Autowired 标注目标构造器。

**Q：setter 注入和字段注入在循环依赖上有什么本质区别？**
A：没有本质区别，两者都发生在实例化之后的属性填充阶段，都能借助三级缓存拿到半成品引用。区别只在可测试性和依赖可见性上，循环依赖的破局逻辑完全相同。

---

## 总结

- **注入方式**：必填用构造器（final + 编译期保证），可选用 Setter，字段注入只在测试/配置类中用
- **注入注解**：@Autowired（Spring 生态 byType）、@Resource（JSR 标准 byName）、@Inject（可移植 byType），团队内统一规范
- **底层**：字段/Setter 注入走 `AutowiredAnnotationBeanPostProcessor` 在 populateBean 阶段装配；构造器注入在 createBeanInstance 阶段完成，因此不支持循环依赖

掌握这一篇，Spring 依赖注入相关的面试题基本没有死角。
