---
title: Spring Boot 自动配置原理深度解析
date: 2026-06-11 10:00:00
tags:
  - Spring Boot
  - 自动配置
  - 源码分析
  - "@EnableAutoConfiguration"
categories: 源码分析
---

## 前言

Spring Boot 最令人惊艳的特性之一就是**自动配置（Auto Configuration）**。引入一个 starter 依赖就能开箱即用，背后到底发生了什么？本文将从源码层面深度剖析自动配置的完整工作流程。

---

## 一、入口：@SpringBootApplication

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@SpringBootConfiguration
@EnableAutoConfiguration   // 核心注解
@ComponentScan(excludeFilters = { ... })
public @interface SpringBootApplication {
    // ...
}
```

`@SpringBootApplication` 是一个复合注解，其中最关键的就是 `@EnableAutoConfiguration`。可以说，理解了 `@EnableAutoConfiguration` 就理解了自动配置的入口。

---

## 二、核心：@EnableAutoConfiguration

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@AutoConfigurationPackage
@Import(AutoConfigurationImportSelector.class)  // 关键
public @interface EnableAutoConfiguration {
    String ENABLED_OVERRIDE_PROPERTY = "spring.boot.enableautoconfiguration";
    Class<?>[] exclude() default {};
    String[] excludeName() default {};
}
```

核心机制是通过 `@Import(AutoConfigurationImportSelector.class)` 导入配置类。

---

## 三、AutoConfigurationImportSelector

这是自动配置的大脑。它实现了 `DeferredImportSelector` 接口，在 Spring 容器处理完所有普通配置类之后才执行。

### 3.1 selectImports 方法

```java
public class AutoConfigurationImportSelector
        implements DeferredImportSelector, BeanClassLoaderAware, ... {

    @Override
    public String[] selectImports(AnnotationMetadata annotationMetadata) {
        if (!isEnabled(annotationMetadata)) {
            return NO_IMPORTS;
        }
        // 获取自动配置元数据
        AutoConfigurationEntry autoConfigurationEntry = 
            getAutoConfigurationEntry(annotationMetadata);
        return StringUtils.toStringArray(autoConfigurationEntry.getConfigurations());
    }
}
```

### 3.2 getAutoConfigurationEntry 核心逻辑

```java
protected AutoConfigurationEntry getAutoConfigurationEntry(
        AnnotationMetadata annotationMetadata) {
    if (!isEnabled(annotationMetadata)) {
        return EMPTY_ENTRY;
    }
    AnnotationAttributes attributes = getAttributes(annotationMetadata);
    
    // 1️⃣ 从 spring.factories 获取所有候选配置类
    List<String> configurations = getCandidateConfigurations(annotationMetadata, attributes);
    
    // 2️⃣ 去重
    configurations = removeDuplicates(configurations);
    
    // 3️⃣ 排除指定的配置类
    Set<String> exclusions = getExclusions(annotationMetadata, attributes);
    configurations.removeAll(exclusions);
    
    // 4️⃣ 按 @AutoConfigureOrder / @AutoConfigureAfter / @AutoConfigureBefore 排序
    configurations = getConfigurationClassFilter().filter(configurations);
    
    fireAutoConfigurationImportEvents(configurations, exclusions);
    return new AutoConfigurationEntry(configurations, exclusions);
}
```

---

## 四、从 spring.factories 到自动配置类

### 4.1 Spring Boot 2.7+ 的变化

**Spring Boot 2.7 之前**，自动配置类写在 `META-INF/spring.factories` 中：

```properties
# spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration,\
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration,\
...
```

**Spring Boot 2.7+** 引入了新的 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 文件，不再使用 `spring.factories`：

```properties
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
org.springframework.boot.autoconfigure.orm.jpa.HibernateJpaAutoConfiguration
```

这源于 Spring Framework 6.0 / Spring Boot 3.0 全面拥抱 **AOT（Ahead-of-Time）编译和 GraalVM 原生镜像**，`spring.factories` 不支持原生编译。

### 4.2 Spring Factories Loader

`SpringFactoriesLoader.loadFactoryNames()` 会扫描 classpath 下所有 jar 包中的 `META-INF/spring.factories` 文件：

```java
public static List<String> loadFactoryNames(Class<?> factoryType, @Nullable ClassLoader classLoader) {
    String factoryTypeName = factoryType.getName();
    // 加载所有 META-INF/spring.factories
    Enumeration<URL> urls = (classLoader != null ?
        classLoader.getResources(FACTORIES_RESOURCE_LOCATION) :
        ClassLoader.getSystemResources(FACTORIES_RESOURCE_LOCATION));
    // 解析并返回对应 factoryTypeName 的配置列表
}
```

---

## 五、条件装配 @Conditional

光是扫描到自动配置类还不够，Spring Boot 需要**按条件决定是否启用**某个配置。这就靠 `@Conditional` 注解族。

### 5.1 常用条件注解

| 注解 | 作用 |
|------|------|
| `@ConditionalOnClass` | classpath 中存在指定类时生效 |
| `@ConditionalOnMissingClass` | classpath 中不存在指定类时生效 |
| `@ConditionalOnBean` | 容器中存在指定 Bean 时生效 |
| `@ConditionalOnMissingBean` | 容器中不存在指定 Bean 时生效 |
| `@ConditionalOnProperty` | 配置项匹配时生效 |
| `@ConditionalOnResource` | 资源存在时生效 |
| `@ConditionalOnWebApplication` | Web 环境下生效 |
| `@ConditionalOnNotWebApplication` | 非 Web 环境下生效 |
| `@ConditionalOnExpression` | SpEL 表达式为 true 时生效 |

### 5.2 经典案例：DataSourceAutoConfiguration

```java
@AutoConfiguration
@ConditionalOnClass({ DataSource.class, EmbeddedDatabaseType.class })
@EnableConfigurationProperties(DataSourceProperties.class)
@Import({ DataSourcePoolMetadataProvidersConfiguration.class, 
          DataSourceInitializationConfiguration.class })
public class DataSourceAutoConfiguration {

    // 只有当容器中不存在自定义 DataSource Bean 时才生效
    @ConditionalOnMissingBean
    @Bean
    public DataSource dataSource() {
        // 根据 classpath 中的连接池自动创建
        return createEmbeddedDataSource();
    }
}
```

这意味着：
1. 如果 classpath 中**没有** `DataSource.class` → `DataSourceAutoConfiguration` 不生效
2. 如果你**自己定义**了一个 `DataSource Bean` → 默认的 `dataSource()` 不生效

> **用户自定义优先于自动配置**，这就是"约定优于配置"的精髓。

---

## 六、自动配置的排序

多个自动配置类之间有依赖关系，通过以下注解控制排序：

```java
// 在 RedisAutoConfiguration 之后执行
@AutoConfigureAfter(RedisAutoConfiguration.class)
public class RedisReactiveAutoConfiguration { ... }

// 在 DataSourceAutoConfiguration 之前执行
@AutoConfigureBefore(DataSourceAutoConfiguration.class)
public class XADataSourceAutoConfiguration { ... }

// 指定顺序（数值越小优先级越高）
@AutoConfigureOrder(Ordered.HIGHEST_PRECEDENCE + 5)
public class SomeAutoConfiguration { ... }
```

排序逻辑由 `AutoConfigurationSorter` 实现，本质是一个**拓扑排序**，解决自动配置类之间的依赖关系。

---

## 七、自定义 Starter 实战

理解了原理，我们来手写一个简单的 Starter。

### 7.1 项目结构

```
my-starter/
├── pom.xml
├── src/
│   └── main/
│       ├── java/
│       │   └── com/example/starter/
│       │       ├── HelloService.java
│       │       └── HelloAutoConfiguration.java
│       └── resources/
│           └── META-INF/
│               └── spring/
│                   └── org.springframework.boot.autoconfigure
│                       .AutoConfiguration.imports
```

### 7.2 自动配置类

```java
@AutoConfiguration
@ConditionalOnClass(HelloService.class)
@EnableConfigurationProperties(HelloProperties.class)
public class HelloAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public HelloService helloService(HelloProperties properties) {
        HelloService service = new HelloService();
        service.setPrefix(properties.getPrefix());
        service.setSuffix(properties.getSuffix());
        return service;
    }
}
```

### 7.3 配置属性

```java
@ConfigurationProperties(prefix = "my.hello")
public class HelloProperties {
    private String prefix = "Hello";
    private String suffix = "!";
    // getters & setters
}
```

### 7.4 AutoConfiguration.imports

```
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
com.example.starter.HelloAutoConfiguration
```

### 7.5 使用

```yaml
# application.yml
my:
  hello:
    prefix: "你好"
    suffix: "！"
```

```java
@Autowired
private HelloService helloService;

helloService.sayHello("世界"); // 输出：你好，世界！
```

---

## 八、调试技巧

### 8.1 查看生效的自动配置

启动时加 `--debug` 参数：

```bash
java -jar myapp.jar --debug
```

控制台会输出：
```
============================
CONDITIONS EVALUATION REPORT
============================
Positive matches:
-----------------
   DataSourceAutoConfiguration matched:
      - @ConditionalOnClass found required class 'javax.sql.DataSource'
      
Negative matches:
-----------------
   ActiveMQAutoConfiguration:
      - @ConditionalOnClass did not find required class 'javax.jms.ConnectionFactory'
```

### 8.2 Actuator 端点

```yaml
management:
  endpoints:
    web:
      exposure:
        include: conditions
```

访问 `/actuator/conditions` 即可查看条件评估报告。

---

## 九、总结

Spring Boot 自动配置的完整流程可以概括为：

```
@SpringBootApplication
        ↓
@EnableAutoConfiguration
        ↓
@Import(AutoConfigurationImportSelector.class)
        ↓
selectImports() → getAutoConfigurationEntry()
        ↓
SpringFactoriesLoader 加载 spring.factories 或 AutoConfiguration.imports
        ↓
排除指定配置 → 去重 → 排序（拓扑排序）
        ↓
每个自动配置类按 @Conditional 条件判断是否生效
        ↓
生效的配置注册 Bean → 应用启动完成
```

核心设计思想：
1. **约定优于配置** —— 框架自动推断所需配置
2. **条件装配** —— 按需加载，避免不必要的 Bean
3. **用户优先** —— 用户自定义的 Bean 优先级高于自动配置
4. **可扩展** —— 自定义 Starter 让三方库也能享受自动配置

理解自动配置原理，不仅仅是应付面试，更是解决实际问题的基础——当自动配置不生效或者配置冲突时，你能快速定位问题根因。
