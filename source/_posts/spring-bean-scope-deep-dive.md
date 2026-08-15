---
title: 【Spring 核心】Bean 作用域深度解析：singleton、prototype 与 Web 作用域的底层原理
date: 2026-08-14 08:00:00
tags:
  - Spring
  - Bean
  - 源码
categories:
  - Spring
  - 后端面试
author: 东哥
---

# 【Spring 核心】Bean 作用域深度解析：singleton、prototype 与 Web 作用域的底层原理

## 面试官：Spring 的 Bean 默认是什么作用域？prototype 作用域下 Bean 什么时候被创建？

大部分同学能答出"默认 singleton"，但紧接着的三个追问就能筛掉一大半人：

1. singleton 是"单例模式"吗？容器是怎么保证只有一个实例的？
2. prototype 作用域下，Bean 是什么时候创建的？为什么 Spring 官方说"prototype 作用域下容器不负责销毁"？
3. singleton Bean 里注入 prototype Bean，每次拿到的为什么是同一个？怎么解决？

本文从源码层面把 Spring 的六大作用域彻底讲透，附赠面试必考的"循环依赖 + 作用域"坑点。

---

## 一、Spring 的六种作用域

| 作用域 | 说明 | 适用场景 |
|--------|------|----------|
| `singleton`（默认） | 每个容器一个实例 | 无状态服务、DAO、Service |
| `prototype` | 每次获取/注入都新建 | 有状态 Bean、原型对象 |
| `request` | 每个 HTTP 请求一个实例 | Web 请求级状态 |
| `session` | 每个 HTTP Session 一个实例 | 用户会话级状态 |
| `application` | 每个 ServletContext 一个实例 | 应用级共享 |
| `websocket` | 每个 WebSocket 连接一个实例 | 实时通信会话 |

前两种在任意环境可用，后四种需要 Web 环境（`WebApplicationContext` 才注册对应 Scope）。

---

## 二、singleton：默认且最常用

### 2.1 singleton 与单例模式的区别

**这是高频陷阱题。** Spring 的 singleton 是"**每个 IoC 容器中一个实例**"，由容器管理；而 GoF 单例模式是"**每个 JVM 中一个实例**"，通过私有构造器保证。两者完全不同：

```java
// Spring 容器中的两个"单例"：
// 同一个 JVM 里可以有多个 ApplicationContext，各自持有自己的 singleton Bean
ApplicationContext ctx1 = new AnnotationConfigApplicationContext(AppConfig.class);
ApplicationContext ctx2 = new AnnotationConfigApplicationContext(AppConfig.class);

UserService s1 = ctx1.getBean(UserService.class);
UserService s2 = ctx2.getBean(UserService.class);
System.out.println(s1 == s2); // false！两个容器两个实例
```

### 2.2 源码：singleton 如何保证单实例

核心在 `DefaultSingletonBeanRegistry` 的 **三级缓存**（也是解决循环依赖的关键）：

```java
public class DefaultSingletonBeanRegistry {
    // 一级缓存：成品单例
    private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);
    // 二级缓存：早期单例（尚未完成属性填充的"半成品"）
    private final Map<String, Object> earlySingletonObjects = new ConcurrentHashMap<>(16);
    // 三级缓存：单例工厂（用于生成早期引用，解决循环依赖）
    private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);
}
```

获取单例的核心逻辑：

```java
protected Object getSingleton(String beanName, boolean allowEarlyReference) {
    // ① 先从一级缓存拿
    Object singletonObject = this.singletonObjects.get(beanName);
    // ② 拿不到且正在创建中，从二级缓存拿
    if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
        singletonObject = this.earlySingletonObjects.get(beanName);
        // ③ 二级也没有，从三级缓存的工厂拿（允许提前引用时）
        if (singletonObject == null && allowEarlyReference) {
            ObjectFactory<?> singletonFactory = this.singletonFactories.get(beanName);
            if (singletonFactory != null) {
                singletonObject = singletonFactory.getObject();
                // 拿到后升级到二级缓存，删除三级缓存
                this.earlySingletonObjects.put(beanName, singletonObject);
                this.singletonFactories.remove(beanName);
            }
        }
    }
    return singletonObject;
}
```

创建完成后放入一级缓存：

```java
protected void addSingleton(String beanName, Object singletonObject) {
    synchronized (this.singletonObjects) {
        this.singletonObjects.put(beanName, singletonObject);
        this.singletonFactories.remove(beanName);
        this.earlySingletonObjects.remove(beanName);
        this.registeredSingletons.add(beanName);
    }
}
```

**总结**：singleton 靠容器内的 `singletonObjects` Map 保证唯一，创建过程有 `synchronized` + `isSingletonCurrentlyInCreation` 的并发保护（`DefaultSingletonBeanRegistry` 用 `singletonsCurrentlyInCreation` 集合标记正在创建的 Bean）。

### 2.3 创建时机：默认懒加载还是饿加载？

**singleton 默认是饿加载（容器启动时创建）**！在 `finishBeanFactoryInitialization()` 中 `preInstantiateSingletons()` 会提前实例化所有非懒加载单例：

```java
@Override
public void preInstantiateSingletons() throws BeansException {
    // 遍历所有 beanName，非 abstract、非 lazy-init、是 singleton 的都提前创建
    for (String beanName : beanNames) {
        RootBeanDefinition bd = getMergedLocalBeanDefinition(beanName);
        if (!bd.isAbstract() && bd.isSingleton() && !bd.isLazyInit()) {
            getBean(beanName);
        }
    }
}
```

如果要懒加载：`@Lazy` 注解或在 XML 配置 `lazy-init="true"`。

**面试考点**：容器启动时创建全部 singleton 的好处是**尽早暴露配置/依赖问题**，坏处是启动变慢。

---

## 三、prototype：每次都是新的

### 3.1 创建时机

prototype Bean **不是在容器启动时创建**，而是每次 `getBean()` 或注入时才创建：

```java
@Component
@Scope(ConfigurableBeanFactory.SCOPE_PROTOTYPE)  // "prototype"
public class TaskExecutor {
    private String taskId;
    // getter/setter...
}
```

```java
// 每次 getBean 都返回新实例
TaskExecutor t1 = ctx.getBean(TaskExecutor.class);
TaskExecutor t2 = ctx.getBean(TaskExecutor.class);
System.out.println(t1 == t2); // false
```

### 3.2 源码：prototype 的创建路径

`AbstractBeanFactory.doGetBean` 中：

```java
// 不是单例也不是 scope 单例 → 走 prototype 分支
else if (mbd.isPrototype()) {
    Object prototypeInstance = null;
    try {
        beforePrototypeCreation(beanName);   // 标记正在创建
        prototypeInstance = createBean(beanName, mbd, args); // 直接创建，不走缓存
    } finally {
        afterPrototypeCreation(beanName);
    }
}
```

关键点：**prototype 不经过三级缓存，也没有"销毁管理"**。

### 3.3 为什么容器不负责销毁 prototype Bean？

源码 `disposableBeans` 的注册逻辑（`DefaultSingletonBeanRegistry.registerDisposableBeanIfNecessary`）：

```java
// 只有 singleton 或自定义 scope 才会注册销毁回调
if (mbd.isSingleton()) {
    registerDisposableBean(beanName, new DisposableBeanAdapter(...));
} else if (ctx.isPrototype()) {
    // prototype：不注册！容器不管理销毁
}
```

因为容器无法追踪 prototype 实例的引用（创建后容器就"放手"了），所以**原型 Bean 的销毁由调用方负责**：

```java
// 正确姿势：手动销毁（如果实现了 DisposableBean）
TaskExecutor t = ctx.getBean(TaskExecutor.class);
try {
    // 使用
} finally {
    if (t instanceof DisposableBean) {
        ((DisposableBean) t).destroy();
    }
}
```

---

## 四、Web 作用域：request / session / application

### 4.1 开启方式

```java
// 方式一：注解
@Component
@Scope(value = WebApplicationContext.SCOPE_REQUEST)  // "request"
public class RequestContext {
}

// 方式二：代理模式声明（重点！）
@Component
@Scope(value = WebApplicationContext.SCOPE_SESSION, proxyMode = ScopedProxyMode.TARGET_CLASS)
public class SessionUser {
}
```

### 4.2 为什么需要代理模式？

**核心坑**：singleton Bean 在容器启动时创建，而 request/session Bean 要等请求来了才有实例。如果直接注入，singleton Bean 创建时根本拿不到 request Bean —— 于是 Spring 用**作用域代理**解决：

`proxyMode = ScopedProxyMode.TARGET_CLASS` 会生成一个代理对象，注入到 singleton Bean 中的是**代理**。每次调用代理方法时，代理会去当前请求上下文中查找真实的 request Bean：

```java
// 注入的是代理，不是真实实例
@Autowired
private SessionUser sessionUser;  // 实际是 SessionUser 的代理

// 调用时代理内部：
// 从 RequestContextHolder 取当前 request → 从 request attribute 拿真实 Bean → 调用其方法
```

不配置 proxyMode 的话，用 `ObjectProvider` 或 `@Lazy` 也能绕开：

```java
@Autowired
private ObjectProvider<SessionUser> sessionUserProvider;

public void doSomething() {
    SessionUser user = sessionUserProvider.getObject(); // 每次调用时才解析
}
```

### 4.3 底层实现

Web 作用域都注册在 `WebApplicationContext` 初始化时（`AbstractRefreshableWebApplicationContext.postProcessBeanFactory`）：

```java
// 注册 request/session/application/websocket 作用域
this.beanFactory.registerScope(WebApplicationContext.SCOPE_REQUEST, new RequestScope());
this.beanFactory.registerScope(WebApplicationContext.SCOPE_SESSION, new SessionScope());
```

`RequestScope.get` 内部从 `RequestContextHolder.currentRequestAttributes()` 拿请求，用 `request.setAttribute` 存储实例，保证同一次请求内多次获取是同一个实例。

**实现机制**：`AbstractRequestAttributesScope` 用 ThreadLocal（`RequestContextHolder`）绑定当前请求，请求结束后清理。

---

## 五、高频坑：singleton 注入 prototype

### 5.1 现象

```java
@Component
public class SingletonService {
    @Autowired
    private PrototypeService prototypeService;  // prototype 作用域

    public void run() {
        System.out.println(prototypeService);   // 每次都打印同一个实例！
    }
}
```

**原因**：singleton Bean 在容器启动时完成属性注入，注入的是当时的 prototype 实例，之后 singleton 一直持有这个旧引用，每次调用都是同一个。

### 5.2 四种解决方案

| 方案 | 写法 | 适用 |
|------|------|------|
| `@Lazy` 注入 | `@Autowired @Lazy private PrototypeService s;` | 简单，注入代理 |
| `ObjectProvider` | `@Autowired ObjectProvider<PrototypeService> p;` 每次 `p.getObject()` | 官方推荐，灵活 |
| `ApplicationContext` | 每次 `ctx.getBean(PrototypeService.class)` | 简单但耦合容器 |
| `ScopedProxyMode` | 给 prototype 配 `proxyMode = TARGET_CLASS` | 透明无感 |

```java
// 官方推荐：ObjectProvider
@Component
public class SingletonService {
    @Autowired
    private ObjectProvider<PrototypeService> prototypeProvider;

    public void run() {
        PrototypeService s = prototypeProvider.getObject(); // 每次都是新实例
    }
}
```

---

## 六、作用域 + 循环依赖的经典坑

**问题**：A（singleton）依赖 B（prototype），B 依赖 A，能启动吗？

**分析**：
- A 是 singleton，创建 A 时通过三级缓存暴露早期引用
- B 是 prototype，创建 B 时**不经过缓存**，直接 `createBean`
- B 创建时需要 A → 从三级缓存拿到 A 的早期引用 → OK

**结论**：能启动，但 B 每次拿到的 A 是同一个早期引用（A 最终还是那个单例）。原型 + 循环依赖虽然能跑，但语义混乱，**不推荐**。

**更常见的坑**：prototype Bean 之间互相依赖没问题（每次新建），但 prototype 依赖 singleton 是完全正常的（注入同一个单例）。

---

## 七、面试官追问环节

### Q1：singleton Bean 线程安全吗？

**容器层面安全（创建过程有锁），业务层面不安全**。singleton 实例被多线程共享，如果 Bean 内有可变状态且无同步，就有并发问题。无状态 Bean（Service/Dao）天然线程安全，有状态 Bean 要么用 prototype，要么自己加锁/用 ThreadLocal。

### Q2：`@Scope("prototype")` 下 `@PostConstruct` 会执行吗？

会。prototype 创建时同样走完整的 Bean 生命周期（`initializeBean` → `@PostConstruct` → `InitializingBean.afterPropertiesSet`），只是**不执行销毁回调**（`@PreDestroy` 不会调用）。

### Q3：request 作用域的 Bean 什么时候销毁？

请求结束时。`RequestScope` 注册了 `requestDestructionCallback`，在 `RequestContextListener`/`DispatcherServlet` 的请求清理阶段执行 `@PreDestroy`。

### Q4：怎么查看容器里所有 singleton Bean？

```java
String[] names = ctx.getBeanDefinitionNames();
for (String name : names) {
    if (ctx.isSingleton(name)) {
        System.out.println(name);
    }
}
```

---

## 八、总结

| 维度 | singleton | prototype | request/session |
|------|-----------|-----------|-----------------|
| 实例数 | 每容器 1 个 | 每次获取 1 个 | 每请求/会话 1 个 |
| 创建时机 | 容器启动（默认饿加载） | 首次 getBean 时 | 首次访问时 |
| 缓存 | 三级缓存（singletonObjects） | 无缓存 | request/session attribute |
| 销毁管理 | 容器负责（@PreDestroy） | 调用方负责 | 请求/会话结束 |
| 注入到 singleton | 直接注入 | 需 @Lazy/ObjectProvider/代理 | 需 ScopedProxyMode |

**面试金句**："singleton 是容器级单例，靠 DefaultSingletonBeanRegistry 的三级缓存保证唯一并解决循环依赖；prototype 每次新建、容器不管理销毁；Web 作用域通过作用域代理解决'创建时机不同步'的问题。"
