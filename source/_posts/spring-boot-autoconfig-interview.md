---
title: Spring Boot 自动装配原理 — 面试向深度解析
date: 2026-07-27 14:00:00
tags:
  - Spring Boot
  - 自动装配
  - 面试
  - "@EnableAutoConfiguration"
  - Conditional
categories: 源码分析
author: 东哥
---

## 一、什么是自动装配？

先看一段最熟悉的代码：

```java
@SpringBootApplication
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
```

就这一个注解 + 一行 run，Spring Boot 就能帮我们自动配置好内嵌 Tomcat、数据源、事务管理器、Jackson、消息转换器……几十上百个 Bean。

**自动装配（Auto-Configuration）** 就是 Spring Boot 根据**类路径下的 jar 包依赖**、**已有 Bean 的定义**、**配置文件（application.properties/yml）**，自动推断并注册需要的 Bean，大幅减少手写配置的工作量。

> **一句话总结：** 自动装配 = 条件化自动注册 Bean。

---

## 二、核心注解拆解

### 1. `@SpringBootApplication`

这是一个**组合注解**，点进去看：

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@SpringBootConfiguration
@EnableAutoConfiguration    // ← 自动装配的核心入口
@ComponentScan(excludeFilters = { ... })
public @interface SpringBootApplication { ... }
```

真正干活的是 `@EnableAutoConfiguration`。

### 2. `@EnableAutoConfiguration` — 自动装配的总开关

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@AutoConfigurationPackage
@Import(AutoConfigurationImportSelector.class)  // ← 核心！
public @interface EnableAutoConfiguration { ... }
```

关键就是 `@Import(AutoConfigurationImportSelector.class)`，它把 `AutoConfigurationImportSelector` 注入到 Spring 容器中。

### 3. `AutoConfigurationImportSelector` — 真正的执行者

这个类实现了 `DeferredImportSelector`，它的 `selectImports` 方法会**加载所有候选的自动配置类**。

```java
@Override
public String[] selectImports(AnnotationMetadata annotationMetadata) {
    if (!isEnabled(annotationMetadata)) {
        return NO_IMPORTS;
    }
    AutoConfigurationEntry autoConfigurationEntry = getAutoConfigurationEntry(annotationMetadata);
    return StringUtils.toStringArray(autoConfigurationEntry.getConfigurations());
}
```

核心调用链：

```
selectImports()
  → getAutoConfigurationEntry()
    → getCandidateConfigurations()
      → SpringFactoriesLoader.loadFactoryNames()
        → 读取 META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

---

## 三、自动装配的加载流程（面试核心）

用一张图概括流程：

```
@SpringBootApplication
       │
       ▼
@EnableAutoConfiguration
       │
       ▼
@Import(AutoConfigurationImportSelector.class)
       │
       ▼
Spring 容器 refresh → invokeBeanFactoryPostProcessors
       │
       ▼
AutoConfigurationImportSelector.selectImports()
       │
       ▼
getAutoConfigurationEntry()
       │
       ▼
SpringFactoriesLoader.loadFactoryNames()
       │
       ▼
读取 META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
       │
       ▼
拿到所有 XXXAutoConfiguration 类的全限定名（如 DataSourceAutoConfiguration）
       │
       ▼
逐一遍历，用 @Conditional 系列注解判断是否符合条件
       │
       ├── @ConditionalOnClass       → 类路径有没有指定类？
       ├── @ConditionalOnMissingBean → 容器中是否已有此 Bean？
       ├── @ConditionalOnProperty    → 配置项是否设置？
       ├── @ConditionalOnBean        → 容器中是否有指定 Bean？
       └── ...
       │
       ▼
符合条件的配置类 → 注册其 @Bean 方法 → 完成自动装配
```

---

## 四、关键文件在哪里？

不同版本文件路径不同：

### Spring Boot 2.7 之前

```
META-INF/spring.factories
```

内容格式：

```properties
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
org.springframework.boot.autoconfigure.web.servlet.DispatcherServletAutoConfiguration,\
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration,\
...
```

### Spring Boot 2.7+ 之后

```
META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

内容格式（每行一个类全名）：

```
org.springframework.boot.autoconfigure.web.servlet.DispatcherServletAutoConfiguration
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
```

用 `@AutoConfiguration` 替代了旧的方式，更清晰。

---

## 五、条件装配的实战例子

拿 `DataSourceAutoConfiguration` 举例：

```java
@AutoConfiguration
@ConditionalOnClass({ DataSource.class, EmbeddedDatabaseType.class })
@ConditionalOnMissingBean(type = "io.r2dbc.spi.ConnectionFactory")
@EnableConfigurationProperties(DataSourceProperties.class)
@Import({ DataSourcePoolMetadataProvidersConfiguration.class,
          DataSourceInitializationConfiguration.class })
public class DataSourceAutoConfiguration { ... }
```

判断逻辑：

1. **`@ConditionalOnClass`** — 类路径下有 `javax.sql.DataSource` 吗？
   - 如果你的 pom 依赖了 `spring-boot-starter-jdbc` 或 `spring-boot-starter-data-jpa`，就有 → 通过
   - 否则跳过 → 不装配

2. **`@ConditionalOnMissingBean`** — 用户有没有自己定义 DataSource Bean？
   - 没有 → 自动创建 HikariCP/Druid 连接池
   - 有 → 尊重用户定义，不重复注册

3. **`@EnableConfigurationProperties`** — 绑定 `spring.datasource.*` 配置

---

## 六、面试角度 — 高频问题及答案

### Q1：请说说 Spring Boot 自动装配的原理

**参考回答：**

Spring Boot 自动装配的核心是 `@EnableAutoConfiguration` 注解，该注解通过 `@Import` 引入了 `AutoConfigurationImportSelector`。Spring 容器刷新时，这个 ImportSelector 会调用 `SpringFactoriesLoader` 加载 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`（旧版在 `spring.factories`）文件中声明的所有自动配置类。

拿到这些候选配置类后，Spring Boot 会逐一检查它们上面的 `@Conditional` 系列条件注解（如 `@ConditionalOnClass`、`@ConditionalOnMissingBean`、`@ConditionalOnProperty`），只有满足所有条件的配置类才会被真正注册到 IoC 容器。

这样就实现了"依赖什么 jar，就自动配置什么功能"的效果。

---

### Q2：`@ConditionalOnClass` 是怎么判断类是否存在的？

Spring Boot 内部通过 `ClassNameFilter` 配合 `ClassUtils.isPresent()` 来检查。具体是尝试 `Class.forName(className)`，如果抛出 `ClassNotFoundException` 或不满足指定的访问条件，就判定为不存在。

**关键点：** 这个检查作用在自动配置类的**元数据层面**，并不是真正加载类，而是通过 ASM 或 ClassLoader 检测。所以即便类不存在也不会报 ClassNotFoundException。

---

### Q3：自动装配会不会覆盖用户自定义的 Bean？

**一般不会。**

Spring Boot 的自动配置类上通常会加 `@ConditionalOnMissingBean`，意思是"当容器中不存在这个 Bean 时才创建"。

也就是说：

- 用户自己定义了 `DataSource` → 用用户的
- 用户没定义 → 用自动配置的

但也**不是绝对的**，有些配置类可能使用 `@ConditionalOnBean` 反过来依赖用户 Bean。具体要看每个自动配置类的注解设计。

---

### Q4：怎么关闭某个自动配置？

有三种方式：

**方式一：`@SpringBootApplication` 的 exclude 属性**

```java
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
```

**方式二：配置文件排除**

```properties
spring.autoconfigure.exclude=org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
```

**方式三：`@EnableAutoConfiguration` 的 exclude**

```java
@EnableAutoConfiguration(exclude = DataSourceAutoConfiguration.class)
```

---

### Q5：可以自己写一个自动配置吗？怎么实现？

可以。步骤：

1. **编写配置类**，使用 `@AutoConfiguration`
2. **条件注解**控制生效时机
3. **注册 Bean**
4. **在 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`** 中添加全限定类名

简单示例：

```java
// MyAutoConfiguration.java
@AutoConfiguration
@ConditionalOnClass(MyService.class)
@ConditionalOnMissingBean
public class MyAutoConfiguration {

    @Bean
    @ConditionalOnProperty(name = "my.service.enabled", havingValue = "true", matchIfMissing = true)
    public MyService myService() {
        return new MyService();
    }
}
```

文件 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`：

```
com.example.autoconfigure.MyAutoConfiguration
```

---

### Q6：自动装配和 @ComponentScan 是什么关系？

| 维度 | @ComponentScan | 自动装配 |
|------|---------------|---------|
| 范围 | 扫描**当前项目**包路径下的 `@Component`、`@Service`、`@Controller` 等 | 加载**第三方 jar** 中声明的 `@AutoConfiguration` 类 |
| 触发方式 | 递归扫描指定包 | 读取 `AutoConfiguration.imports` / `spring.factories` |
| 常用场景 | 你自己的业务代码 | 框架集成、starter |

**二者互补，没有替代关系。**

---

### Q7：Spring Boot 2.7 之后自动装配有什么变化？

主要有两点：

1. 配置文件从 `spring.factories` 迁移到 `AutoConfiguration.imports`，写法更简洁（一行一个全限定名）。
2. 引入 `@AutoConfiguration` 注解代替 `@Configuration`，语义更明确。

旧版 `spring.factories` 仍然兼容，但 Spring Boot 3.x 已不再推荐。

---

### Q8：Spring Boot 自动装配在 Spring 容器初始化过程中哪个阶段执行？

在 Spring 容器的 `refresh()` → `invokeBeanFactoryPostProcessors()` 阶段。

具体来说，`AutoConfigurationImportSelector` 实现了 `DeferredImportSelector`，会在所有普通 `@Configuration` 配置类处理完之后才执行，这是为了保证用户自定义的配置（`@ComponentScan` 扫描出来的 Bean、`@Import` 导入的类等）**优先于自动配置**生效。

---

## 七、总结

| 核心要素 | 说明 |
|---------|------|
| 入口 | `@EnableAutoConfiguration` |
| 加载器 | `AutoConfigurationImportSelector` |
| 配置来源 | `AutoConfiguration.imports` / `spring.factories` |
| 过滤机制 | `@ConditionalOnClass`、`@ConditionalOnMissingBean` 等条件注解 |
| 执行时机 | `invokeBeanFactoryPostProcessors` 阶段，晚于用户配置 |
| 设计思想 | 约定大于配置（Convention Over Configuration） |

自动装配就是 Spring Boot **"开箱即用"**的灵魂。理解它，才算真的理解了 Spring Boot。
