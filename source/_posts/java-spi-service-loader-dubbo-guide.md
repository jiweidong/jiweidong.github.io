---
title: Java SPI 机制详解：从 ServiceLoader 到 Dubbo SPI 的进化之路
date: 2026-06-21 08:00:00
tags:
  - Java
  - SPI
  - 源码分析
  - Dubbo
categories:
  - Java
  - Java 基础
author: 东哥
---

# Java SPI 机制详解：从 ServiceLoader 到 Dubbo SPI 的进化之路

## 一、什么是 SPI？

SPI 全称 **Service Provider Interface**（服务提供者接口），是 Java 提供的一种**服务发现机制**。

它的核心思想是：**面向接口编程 + 策略模式 + 配置文件**——在 jar 包的特定位置放一个配置文件，Java 的 ServiceLoader 会扫描所有 jar 包下的配置文件，找到实现类并加载。

### 一个经典场景：JDBC 驱动加载

```java
// JDBC 4.0 之前（手动加载）
Class.forName("com.mysql.cj.jdbc.Driver");
Connection conn = DriverManager.getConnection(url, username, password);

// JDBC 4.0+（SPI 自动加载）
Connection conn = DriverManager.getConnection(url, username, password);
// 不需要 Class.forName！DriverManager 通过 SPI 自动发现驱动
```

JDBC 4.0 之后，MySQL 驱动 jar 包中包含了：

```
META-INF/services/java.sql.Driver
```

文件内容：
```
com.mysql.cj.jdbc.Driver
```

`DriverManager` 启动时会通过 `ServiceLoader` 加载这个配置，自动注册 MySQL 驱动。

## 二、Java SPI 的使用方式

### 步骤一：定义接口

```java
// 支付接口
public interface PaymentService {
    boolean pay(BigDecimal amount);
    String getChannel();
}
```

### 步骤二：实现接口

```java
// 支付宝实现
public class AlipayService implements PaymentService {
    @Override
    public boolean pay(BigDecimal amount) {
        System.out.println("支付宝支付：" + amount);
        return true;
    }
    
    @Override
    public String getChannel() {
        return "alipay";
    }
}

// 微信支付实现
public class WechatPayService implements PaymentService {
    @Override
    public boolean pay(BigDecimal amount) {
        System.out.println("微信支付：" + amount);
        return true;
    }
    
    @Override
    public String getChannel() {
        return "wechat";
    }
}
```

### 步骤三：在 classpath 下创建配置文件

```
resources/
  └── META-INF/
       └── services/
            └── com.example.PaymentService   ← 文件名必须等于接口全限定名
```

文件内容 `META-INF/services/com.example.PaymentService`：
```
com.example.AlipayService
com.example.WechatPayService
```

### 步骤四：通过 ServiceLoader 加载

```java
public class PaymentDemo {
    public static void main(String[] args) {
        ServiceLoader<PaymentService> loader = ServiceLoader.load(PaymentService.class);
        
        for (PaymentService service : loader) {
            System.out.println("支付渠道：" + service.getChannel());
            service.pay(new BigDecimal("100.00"));
        }
    }
}
```

输出：
```
支付渠道：alipay
支付宝支付：100.00
支付渠道：wechat
微信支付：100.00
```

## 三、ServiceLoader 的源码剖析

### 核心流程

```java
public final class ServiceLoader<S> implements Iterable<S> {
    
    // 配置文件的目录（固定路径）
    private static final String PREFIX = "META-INF/services/";
    
    // 懒加载的 LazyIterator
    private LazyIterator lookupIterator;
    
    // 已缓存的提供者
    private LinkedHashMap<String, S> providers = new LinkedHashMap<>();
    
    public static <S> ServiceLoader<S> load(Class<S> service) {
        // 获取当前线程的 ContextClassLoader
        ClassLoader cl = Thread.currentThread().getContextClassLoader();
        return new ServiceLoader<>(service, cl);
    }
    
    // ◆ 遍历时触发真正的加载
    public Iterator<S> iterator() {
        return new Iterator<S>() {
            // 先遍历已缓存的
            Iterator<Map.Entry<String, S>> knownProviders = providers.entrySet().iterator();
            
            public boolean hasNext() {
                if (knownProviders.hasNext()) return true;
                return lookupIterator.hasNext();  // 懒加载
            }
            
            public S next() {
                if (knownProviders.hasNext()) return knownProviders.next().getValue();
                return lookupIterator.next();  // 实际读取并实例化
            }
        };
    }
}
```

### LazyIterator——真正的加载逻辑

```java
private class LazyIterator implements Iterator<S> {
    Class<S> service;
    ClassLoader loader;
    Enumeration<URL> configs;
    Iterator<String> pending;
    String nextName;
    
    private boolean hasNextService() {
        if (configs == null) {
            // ◆ 扫描所有 jar 包下的配置文件
            String fullName = PREFIX + service.getName();
            // 通过 ClassLoader 扫描所有匹配的文件
            configs = loader.getResources(fullName);
        }
        
        while ((pending == null) || !pending.hasNext()) {
            if (!configs.hasMoreElements()) return false;
            // 解析配置文件
            pending = parse(configs.nextElement());
        }
        nextName = pending.next();
        return true;
    }
    
    @SuppressWarnings("unchecked")
    private S nextService() {
        String cn = nextName;
        nextName = null;
        // ◆ 反射加载并实例化
        Class<?> c = Class.forName(cn, false, loader);
        // 确保类型正确
        if (!service.isAssignableFrom(c)) {
            throw new ServiceConfigurationError("...");
        }
        S p = service.cast(c.newInstance());  // 调用无参构造器
        providers.put(cn, p);                 // 放入缓存
        return p;
    }
}
```

### ServiceLoader 核心流程总结

```
ServiceLoader.load(PaymentService.class)
    │
    ▼
new ServiceLoader<>(service, classLoader)
    │  创建 LazyIterator（懒加载，还没读配置文件）
    ▼
iterator.hasNext() / next()
    │
    ▼
hasNextService()
    │  classLoader.getResources("META-INF/services/com.example.PaymentService")
    │  扫描 classpath 下所有 jar 包中的匹配文件
    ▼
parse() → 读取文件中的全限定类名
    │
    ▼
nextService()
    │  Class.forName() + newInstance()
    ▼
返回实例并缓存到 providers 中
```

## 四、Java SPI 的优缺点

### 优点

1. **解耦**：调用方和实现方完全解耦，通过配置文件连接
2. **可插拔**：增加新实现只需加 jar 包，无需修改代码
3. **Java 原生支持**：无需引入第三方依赖

### 缺点

| 问题 | 说明 |
|------|------|
| 一次性加载所有 | 全部实例化，不管用不用，浪费资源 |
| 没有按需加载 | 不能根据条件选择具体实现 |
| 线程不安全 | ServiceLoader 不是线程安全的 |
| 没有 AOP 支持 | 不能对实现类进行包装、增强 |
| 异常不友好 | 加载失败信息不够清晰 |
| 无 IOC 支持 | 实现类不能有构造依赖 |

这些缺点在 Dubbo SPI 中得到了完美解决。

## 五、Dubbo SPI——增强版 SPI

Dubbo 没有直接用 Java SPI，而是自己实现了一套更强大的 SPI 机制。

### 核心接口 @SPI

```java
@Documented
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface SPI {
    String value() default "";  // 默认实现名
}
```

### 使用方式

```java
// 1. 接口标注 @SPI
@SPI("dubbo")
public interface Protocol {
    void export(Invoker invoker);
    Invoker refer(URL url);
}

// 2. 实现类
public class DubboProtocol implements Protocol {
    @Override
    public void export(Invoker invoker) { /* ... */ }
    @Override
    public Invoker refer(URL url) { /* ... */ }
}

public class HttpProtocol implements Protocol {
    @Override
    public void export(Invoker invoker) { /* ... */ }
    @Override
    public Invoker refer(URL url) { /* ... */ }
}

// 3. 配置文件（目录不同！）
// META-INF/dubbo/com.example.Protocol
// 内容：
dubbo=com.example.DubboProtocol
http=com.example.HttpProtocol

// 4. 使用
Protocol protocol = ExtensionLoader.getExtensionLoader(Protocol.class)
    .getExtension("dubbo");
protocol.export(invoker);
```

### Dubbo SPI vs Java SPI 配置文件对比

| 对比项 | Java SPI | Dubbo SPI |
|--------|----------|-----------|
| 配置文件路径 | META-INF/services/ | META-INF/services/、META-INF/dubbo/、META-INF/dubbo/internal/ |
| 配置格式 | com.example.Impl（一行一个） | key=com.example.Impl（支持别名） |
| 加载方式 | 全量加载 | 按需加载 |
| 缓存机制 | 全量缓存 | 按需缓存 |
| 依赖注入 | 不支持 | 支持 IOC |
| AOP 支持 | 不支持 | 支持（Wrapper 类） |
| 自适应扩展 | 不支持 | 支持 @Adaptive |
| 激活条件 | 不支持 | 支持 @Activate |

### Dubbo SPI 的 IOC（依赖注入）

```java
public class DubboProtocol implements Protocol {
    // Dubbo SPI 发现 Protocol 接口有 setProxyFactory 方法，
    // 会自动从 ExtensionLoader 中获取 ProxyFactory 的实现并注入
    public void setProxyFactory(ProxyFactory proxyFactory) {
        this.proxyFactory = proxyFactory;
    }
}
```

ExtensionLoader 中的依赖注入逻辑：

```java
// ExtensionLoader.injectExtension()
private void injectExtension(T instance) {
    // 遍历所有 setter 方法
    for (Method method : instance.getClass().getMethods()) {
        if (!method.getName().startsWith("set") || method.getParameterTypes().length != 1)
            continue;
        
        Class<?> pt = method.getParameterTypes()[0];
        // 如果参数类型也是 @SPI 接口，从 ExtensionLoader 获取
        if (pt.isInterface() && pt.isAnnotationPresent(SPI.class)) {
            String property = method.getName().substring(3, 4).toLowerCase() + method.getName().substring(4);
            Object extension = getExtensionLoader(pt).getExtension(getDefaultName());
            method.invoke(instance, extension);
        }
    }
}
```

### Dubbo SPI 的 AOP（Wrapper 类）

```java
// 当 Protocol 的实现类有一个带 Protocol 类型参数的构造器，
// Dubbo 会将其视为 Wrapper（装饰器）
public class ProtocolFilterWrapper implements Protocol {
    private final Protocol protocol;
    
    // ◆ 有这个构造器 → Dubbo 将其识别为 Wrapper
    public ProtocolFilterWrapper(Protocol protocol) {
        this.protocol = protocol;
    }
    
    @Override
    public void export(Invoker invoker) {
        // 在原有 export 前后增加过滤逻辑
        protocol.export(buildInvokerChain(invoker));
    }
    
    @Override
    public Invoker refer(URL url) {
        return protocol.refer(url);
    }
}
```

Wrapper 的作用：**在不修改原始实现的情况下，对其进行增强**——这就是 AOP 的思想。

### @Adaptive——自适应扩展

```java
@SPI("dubbo")
public interface Protocol {
    @Adaptive
    void export(Invoker invoker);
}

// 调用时
Protocol protocol = ExtensionLoader.getExtensionLoader(Protocol.class)
    .getAdaptiveExtension();
// protocol 会根据 URL 参数中的 protocol 值动态选择实现
protocol.export(invoker);
```

@Adaptive 会在运行时动态生成适配器类，根据参数值选择具体实现。

### @Activate——条件激活

```java
@Activate(group = "provider", order = 100)
public class AccessLogFilter implements Filter {
    @Override
    public Result invoke(Invoker<?> invoker, Invocation invocation) {
        // provider 端的访问日志过滤器
        return invoker.invoke(invocation);
    }
}
```

@Activate 可以根据条件自动激活某些扩展。

## 六、Dubbo ExtensionLoader 源码核心

### getExtensionLoader——获取扩展加载器

```java
public static <T> ExtensionLoader<T> getExtensionLoader(Class<T> type) {
    // 检查：必须是接口
    // 检查：必须有 @SPI 注解
    // 检查：必须是 public
    
    // ◆ 从缓存中获取 ExtensionLoader
    ExtensionLoader<T> loader = (ExtensionLoader<T>) EXTENSION_LOADERS.get(type);
    if (loader == null) {
        EXTENSION_LOADERS.putIfAbsent(type, new ExtensionLoader<>(type));
        loader = EXTENSION_LOADERS.get(type);
    }
    return loader;
}
```

### getExtension——按名称获取

```java
public T getExtension(String name) {
    if (name == null || name.length() == 0)
        throw new IllegalArgumentException("Extension name == null");
    
    // ◆ 从缓存获取
    Holder<Object> holder = getOrCreateHolder(name);
    Object instance = holder.get();
    if (instance == null) {
        synchronized (holder) {
            instance = holder.get();
            if (instance == null) {
                // 创建扩展
                instance = createExtension(name);
                holder.set(instance);
            }
        }
    }
    return (T) instance;
}

@SuppressWarnings("unchecked")
private T createExtension(String name) {
    // 1. 加载所有扩展类（从配置文件读取）
    Class<?> clazz = getExtensionClasses().get(name);
    
    // 2. 反射实例化
    T instance = (T) clazz.newInstance();
    
    // 3. 依赖注入（IOC）
    injectExtension(instance);
    
    // 4. 包装（AOP/Wrapper）
    Set<Class<?>> wrapperClasses = cachedWrapperClasses;
    if (wrapperClasses != null && !wrapperClasses.isEmpty()) {
        for (Class<?> wrapperClass : wrapperClasses) {
            instance = (T) wrapperClass.getConstructor(clazz).newInstance(instance);
        }
    }
    
    return instance;
}
```

## 七、Spring 也有自己的 SPI——Spring SPI

Spring 通过 `SpringFactoriesLoader` 实现自己的 SPI 机制：

```java
// 配置路径：META-INF/spring.factories（较老版本）
// 配置路径：META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports（新版本）

// SpringFactoriesLoader 核心
public static List<String> loadFactoryNames(Class<?> factoryType, @Nullable ClassLoader classLoader) {
    ClassLoader classLoaderToUse = classLoader;
    if (classLoaderToUse == null) {
        classLoaderToUse = SpringFactoriesLoader.class.getClassLoader();
    }
    
    String factoryTypeName = factoryType.getName();
    // 加载 META-INF/spring.factories 文件
    return loadSpringFactories(classLoaderToUse).getOrDefault(factoryTypeName, Collections.emptyList());
}
```

典型应用：
```java
// Spring Boot 自动配置
// @EnableAutoConfiguration 通过 SpringFactoriesLoader 加载所有 AutoConfiguration
```

## 八、三种 SPI 对比总结

| 特性 | Java SPI | Dubbo SPI | Spring SPI |
|------|----------|-----------|------------|
| 配置文件位置 | META-INF/services/ | META-INF/dubbo/ + services/ | META-INF/spring.factories |
| 配置格式 | 全限定类名 | key=class | 全限定类名 |
| 按需加载 | ❌ 全量 | ✅ | ✅ |
| IOC 依赖注入 | ❌ | ✅ | ✅ |
| AOP 包装 | ❌ | ✅（Wrapper） | ❌ |
| 自适应扩展 | ❌ | ✅（@Adaptive） | ❌ |
| 条件激活 | ❌ | ✅（@Activate） | ✅（@Conditional） |
| 缓存机制 | ✅ | ✅ | ✅ |

## 九、面试常见追问

### Q1：为什么 JDBC 要用 SPI？

JDBC 的设计原则是**接口由 Java 定义，实现由数据库厂商提供**。如果没有 SPI，就需要手动 `Class.forName` 加载驱动。SPI 让驱动的发现变成了自动化的过程——**接口不变，实现可插拔**。

### Q2：Dubbo 为什么不用 Java SPI 而自己实现？

因为 Java SPI 有这些问题：
1. 全量加载——启动慢，浪费资源
2. 没有名字——无法按名称获取特定实现
3. 没有 IOC——实现类的依赖需要自己注入
4. 没有 AOP——无法对扩展进行包装增强
5. 没有自适应——无法根据运行时参数动态选择实现

### Q3：说说 SPI 和 API 的区别？

```
API（Application Programming Interface）
调用方 ←——— 实现方（调用方依赖实现方）

SPI（Service Provider Interface）
实现方 ———→ 调用方（实现方依赖调用方定义的接口）
```

简单说：API 是你调用别人的代码，SPI 是别人调用你写的实现。

## 十、实际项目中的 SPI 应用

### 业务场景：多支付渠道

```java
// 定义 SPI 接口
@SPI("wechat")
public interface PaymentService {
    boolean pay(PayRequest request);
}

// 动态选择支付方式
PaymentService paymentService = ExtensionLoader.getExtensionLoader(PaymentService.class)
    .getExtension(order.getChannel());
paymentService.pay(request);
```

### 业务场景：日志框架

```java
// SLF4J 使用 SPI 加载具体的日志实现
LoggerFactory.getLogger(xxx.class);
// 在 classpath 中放 logback、log4j 等实现
```

## 总结

SPI 是 Java 生态中最重要但最容易被忽视的设计之一。理解了 SPI，你就理解了 JDBC 驱动的自动加载、Dubbo 的扩展机制、Spring Boot 的自动配置——它们本质上都是"插拔式"设计哲学的体现。

从 Java SPI → Spring SPI → Dubbo SPI 的演进，可以看到一个良好的扩展机制应该具备的特性：**按需加载、依赖注入、包装增强、自适应选择**。这就是 Dubbo 能够成为微服务框架核心的原因之一。
