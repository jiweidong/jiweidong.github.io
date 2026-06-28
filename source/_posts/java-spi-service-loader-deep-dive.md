---
title: 「Java SPI 机制深度解析」从 ServiceLoader 到 Spring Factories 的扩展之道
date: 2026-06-28 08:00:00
tags:
  - Java
  - SPI
  - 扩展机制
  - 架构
categories:
  - Java
  - Java基础
author: 东哥
---

# 「Java SPI 机制深度解析」从 ServiceLoader 到 Spring Factories 的扩展之道

在开发现代 Java 框架时，我们常常需要一种**插件化**的扩展机制：核心框架不直接依赖具体实现类，而是通过约定让第三方提供实现，框架在运行时动态加载。这就是 **SPI（Service Provider Interface）**。

JDBC 驱动、SLF4J 日志门面、Spring Boot 的自动配置，背后都是 SPI 的思想。本文从 JDK 原生 SPI 讲到 Spring 的扩展，帮你彻底理解这一核心机制。

---

## 一、什么是 SPI？

**SPI** 全称 **Service Provider Interface**，是一种**服务发现机制**。它通过在 classpath 下 `META-INF/services/` 目录中放置配置文件，让框架在运行时动态加载接口的实现类。

### SPI vs API

| 概念 | API（Application Programming Interface） | SPI（Service Provider Interface） |
|------|------------------------------------------|-----------------------------------|
| 视角 | 供给方提供接口和实现 | 供给方提供接口，调用方提供实现 |
| 方向 | 调用方 → 实现方 | 实现方 → 加载方 |
| 典型 | List、Map 等标准 API | JDBC Driver、日志框架 |

通俗地说，API 是你调用别人的代码，SPI 是别人调用你的代码（你实现了别人定义的接口）。

---

## 二、JDK 原生 SPI 实现 - ServiceLoader

### 2.1 使用示例

以 mysql-connector-java 为例，JDBC 驱动就是通过 SPI 机制被加载的：

**Step 1：定义接口**
```java
// 数据源接口
public interface DataSourceProvider {
    Connection getConnection(String url, String username, String password);
    boolean supports(String url);
}
```

**Step 2：提供实现**
```java
public class MysqlDataSourceProvider implements DataSourceProvider {
    @Override
    public Connection getConnection(String url, String username, String password) {
        // MySQL 连接实现
        return DriverManager.getConnection(url, username, password);
    }
    
    @Override
    public boolean supports(String url) {
        return url.startsWith("jdbc:mysql://");
    }
}
```

**Step 3：配置 META-INF/services/ 文件**

创建文件 `META-INF/services/com.example.DataSourceProvider`：
```
com.example.mysql.MysqlDataSourceProvider
```

**Step 4：加载使用**
```java
ServiceLoader<DataSourceProvider> loader = ServiceLoader.load(DataSourceProvider.class);
for (DataSourceProvider provider : loader) {
    if (provider.supports(url)) {
        return provider.getConnection(url, username, password);
    }
}
```

### 2.2 ServiceLoader 源码解析

```java
public final class ServiceLoader<S> implements Iterable<S> {
    
    // 配置文件的固定路径
    private static final String PREFIX = "META-INF/services/";
    
    // 懒加载迭代器
    public Iterator<S> iterator() {
        return new LazyIterator();
    }
    
    private class LazyIterator implements Iterator<S> {
        Class<S> service;
        ClassLoader loader;
        Enumeration<URL> configs = null;
        Iterator<String> pending = null;
        S nextProvider = null;
        
        private boolean hasNextService() {
            if (nextProvider != null) return true;
            if (configs == null) {
                // 加载 META-INF/services/ 下的配置文件
                String fullName = PREFIX + service.getName();
                configs = loader.getResources(fullName);
            }
            // 解析配置文件中的实现类名
            while (pending == null || !pending.hasNext()) {
                if (!configs.hasMoreElements()) return false;
                pending = parse(configs.nextElement());
            }
            return true;
        }
        
        private S nextService() {
            String className = pending.next();
            // 反射加载并实例化
            Class<?> c = Class.forName(className, false, loader);
            return service.cast(c.newInstance());
        }
    }
}
```

**核心设计**：
1. **懒加载**：调用 `iterator()` 时不会立即加载，遍历才会加载
2. **缓存**：每个 `ServiceLoader` 实例会缓存已加载的 provider
3. **classpath 扫描**：通过 `ClassLoader.getResources()` 扫描所有 jar 中的 `META-INF/services/` 文件

### 2.3 JDK SPI 的局限

| 问题 | 说明 | 影响 |
|------|------|------|
| 无优先级 | 加载顺序由文件/迭代器决定，不可控 | 需要时只能自己包装排序 |
| 多线程不安全 | ServiceLoader 内部没有同步 | 并发场景需自行保护 |
| 无法注入 | 只能通过无参构造器实例化 | 不支持依赖注入 |
| 无过滤机制 | 加载所有实现类 | 只需部分实现时浪费 |
| 错误不明确 | 加载失败时只抛 ServiceConfigurationError | 排查困难 |

正因为这些局限，Spring 等框架选择**自己实现 SPI** 机制。

---

## 三、Spring SPI 机制：SpringFactoriesLoader

### 3.1 从 spring.factories 说起

Spring Boot 的自动配置就是靠 `META-INF/spring.factories` 文件实现的。比如：

```properties
# META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
com.example.MyAutoConfiguration,\
com.example.OtherAutoConfiguration

org.springframework.context.ApplicationListener=\
com.example.MyApplicationListener
```

### 3.2 SpringFactoriesLoader 源码

```java
public abstract class SpringFactoriesLoader {
    
    // 支持多个配置文件路径
    public static final String FACTORIES_RESOURCE_LOCATION = "META-INF/spring.factories";
    
    public static List<String> loadFactoryNames(Class<?> factoryType, @Nullable ClassLoader classLoader) {
        ClassLoader classLoaderToUse = classLoader;
        if (classLoaderToUse == null) {
            classLoaderToUse = SpringFactoriesLoader.class.getClassLoader();
        }
        
        String factoryTypeName = factoryType.getName();
        return loadSpringFactories(classLoaderToUse).getOrDefault(factoryTypeName, Collections.emptyList());
    }
    
    private static Map<String, List<String>> loadSpringFactories(ClassLoader classLoader) {
        // 从缓存中取
        Map<String, List<String>> result = cache.get(classLoader);
        if (result != null) return result;
        
        result = new HashMap<>();
        try {
            // 扫描所有 jar 中的 spring.factories
            Enumeration<URL> urls = classLoader.getResources(FACTORIES_RESOURCE_LOCATION);
            while (urls.hasMoreElements()) {
                URL url = urls.nextElement();
                UrlResource resource = new UrlResource(url);
                Properties properties = PropertiesLoaderUtils.loadProperties(resource);
                for (Map.Entry<?, ?> entry : properties.entrySet()) {
                    String factoryTypeName = ((String) entry.getKey()).trim();
                    String[] factoryImplNames = ((String) entry.getValue()).split(",");
                    for (String implName : factoryImplNames) {
                        result.computeIfAbsent(factoryTypeName, k -> new ArrayList<>()).add(implName.trim());
                    }
                }
            }
            // 添加缓存
            cache.put(classLoader, result);
        } catch (IOException ex) {
            throw new IllegalArgumentException("Unable to load factories...", ex);
        }
        return result;
    }
}
```

### 3.3 Spring SPI 相比 JDK SPI 的改进

| 特性 | JDK ServiceLoader | SpringFactoriesLoader |
|------|------------------|---------------------|
| 配置格式 | 每个接口一个文件 | 一个文件集中配置所有接口 |
| 配置文件 | META-INF/services/ 下多个文件 | 单个 META-INF/spring.factories |
| 批量加载 | 需逐个遍历 | 一次加载全部 |
| 优先级 | 不支持 | 可通过 `@Order` / `Ordered` 接口排序 |
| 缓存 | 每个 ServiceLoader 实例缓存 | 全局缓存 |
| 错误处理 | ServiceConfigurationError | 合并所有异常 |

---

## 四、Spring Boot 自动配置中的 SPI 应用

Spring Boot 3.x 引入了新的自动配置机制，用 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 替代了传统的 `spring.factories`。

```properties
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
com.example.config.RedisAutoConfiguration
com.example.config.MyBatisAutoConfiguration
com.example.config.SentinelAutoConfiguration
```

Spring Boot 启动时，`AutoConfigurationImportSelector` 会加载这些配置类：

```java
// 简化版实现
public class AutoConfigurationImportSelector implements DeferredImportSelector {
    
    @Override
    public String[] selectImports(AnnotationMetadata annotationMetadata) {
        AutoConfigurationEntry autoConfigurationEntry = getAutoConfigurationEntry(annotationMetadata);
        return StringUtils.toStringArray(autoConfigurationEntry.getConfigurations());
    }
    
    protected AutoConfigurationEntry getAutoConfigurationEntry(AnnotationMetadata annotationMetadata) {
        // 1. 获取所有自动配置类
        List<String> configurations = getCandidateConfigurations(annotationMetadata, attributes);
        // 2. 移除重复
        configurations = removeDuplicates(configurations);
        // 3. 根据 @Conditional 条件过滤
        configurations = filter(configurations, autoConfigurationMetadata);
        // 4. 排序（@AutoConfigureOrder, @AutoConfigureAfter, @AutoConfigureBefore）
        configurations = sort(configurations);
        return new AutoConfigurationEntry(configurations, exclusions);
    }
    
    protected List<String> getCandidateConfigurations(AnnotationMetadata metadata, AnnotationAttributes attributes) {
        List<String> configurations = SpringFactoriesLoader.loadFactoryNames(
            getSpringFactoriesLoaderFactoryClass(), getBeanClassLoader());
        Assert.notEmpty(configurations, "No auto configuration classes found");
        return configurations;
    }
}
```

经过排序和条件过滤后，Spring Boot 最终确定哪些自动配置类需要生效。

---

## 五、Dubbo 的 SPI 扩展

Dubbo 没有直接用 JDK SPI，而是自己实现了一套**增强 SPI**——Dubbo SPI。

### 5.1 为什么需要增强 SPI？

Dubbo 的扩展点（协议、序列化、负载均衡等）需要：
1. **按需加载**：不是一次性加载所有实现
2. **IOC 和 AOP**：扩展点之间可以互相注入
3. **自适应扩展**：根据运行时参数动态选择实现
4. **激活条件**：只有满足条件才激活

### 5.2 使用方式

```java
@SPI("dubbo")  // 默认实现为 dubbo
public interface Protocol {
    <T> Exporter<T> export(Invoker<T> invoker);
    <T> Invoker<T> refer(Class<T> type, URL url);
}
```

配置文件 `META-INF/dubbo/com.apache.dubbo.rpc.Protocol`：
```
dubbo=com.apache.dubbo.rpc.protocol.dubbo.DubboProtocol
http=com.apache.dubbo.rpc.protocol.http.HttpProtocol
```

### 5.3 自适应扩展（@Adaptive）

```java
@Adaptive
public Protocol getProtocol(URL url) {
    // 根据 URL 中的 protocol 参数动态选择
    String extName = url.getProtocol();
    ExtensionLoader<Protocol> loader = ExtensionLoader.getExtensionLoader(Protocol.class);
    return loader.getExtension(extName);
}
```

Dubbo 会动态生成自适应扩展类的字节码，在运行时根据参数动态转发到具体的实现。

---

## 六、手写一个简单的 SPI 框架

理解了原理后，我们手写一个简单的 SPI 框架：

```java
public class SimpleSpiLoader<T> {
    
    private static final String PREFIX = "META-INF/services/";
    private final Class<T> serviceType;
    private final ClassLoader classLoader;
    
    public SimpleSpiLoader(Class<T> serviceType) {
        this(serviceType, Thread.currentThread().getContextClassLoader());
    }
    
    public SimpleSpiLoader(Class<T> serviceType, ClassLoader classLoader) {
        this.serviceType = serviceType;
        this.classLoader = classLoader;
    }
    
    @SuppressWarnings("unchecked")
    public List<T> loadAll() {
        List<T> providers = new ArrayList<>();
        try {
            String fullName = PREFIX + serviceType.getName();
            Enumeration<URL> configs = classLoader.getResources(fullName);
            
            while (configs.hasMoreElements()) {
                URL url = configs.nextElement();
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(url.openStream(), StandardCharsets.UTF_8))) {
                    
                    String line;
                    while ((line = reader.readLine()) != null) {
                        line = line.trim();
                        // 跳过注释和空行
                        if (line.isEmpty() || line.startsWith("#")) continue;
                        
                        try {
                            Class<?> implClass = Class.forName(line, false, classLoader);
                            if (serviceType.isAssignableFrom(implClass)) {
                                T instance = (T) implClass.getDeclaredConstructor().newInstance();
                                providers.add(instance);
                            }
                        } catch (Exception e) {
                            System.err.println("Failed to load SPI impl: " + line);
                            e.printStackTrace();
                        }
                    }
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("Failed to load SPI config", e);
        }
        return providers;
    }
    
    // 支持 @Order 注解排序
    public List<T> loadOrdered() {
        List<T> providers = loadAll();
        providers.sort(Comparator.comparingInt(p -> {
            Order order = p.getClass().getAnnotation(Order.class);
            return order != null ? order.value() : Integer.MAX_VALUE;
        }));
        return providers;
    }
}
```

---

## 七、总结与对比

| 维度 | JDK SPI | Spring SPI | Dubbo SPI |
|------|---------|-----------|-----------|
| 配置位置 | META-INF/services/ | META-INF/spring.factories | META-INF/dubbo/ |
| 配置格式 | 每接口一个文件 | 属性文件多接口合一 | 属性文件多接口合一 |
| 懒加载 | 是 | 是 | 是 |
| 依赖注入 | 否 | 否（配合IoC容器） | 是（IOC + AOP） |
| 自适应扩展 | 否 | 否 | 是（@Adaptive） |
| 激活条件 | 否 | 是（@Conditional） | 是（@Activate） |
| 缓存 | 实例级 | 类级全局 | 类级全局 |

SPI 机制的核心思想就是**面向接口编程 + 配置驱动 + 运行时加载**。理解了 SPI，你就理解了现代 Java 框架"可插拔"设计的底层逻辑——无论是 JDBC 驱动的自动发现、SLF4J 日志门面的动态绑定，还是 Spring Boot 的自动配置，背后都是这个模式。
