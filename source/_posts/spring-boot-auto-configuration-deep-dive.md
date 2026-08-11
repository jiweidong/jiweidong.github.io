---
title: 【Spring Boot 源码】自动装配原理深度解析：从 @SpringBootApplication 到自定义 Starter
date: 2026-08-11 08:00:00
tags:
  - Java
  - Spring Boot
  - 自动装配
  - 源码
categories:
  - Spring
  - Spring Boot 源码
author: 东哥
---

# 【Spring Boot 源码】自动装配原理深度解析：从 @SpringBootApplication 到自定义 Starter

## 面试官：Spring Boot 为什么"开箱即用"？说说自动装配的原理

这是 Spring Boot 面试中出场率最高的题目，没有之一。很多人能背出 `@SpringBootApplication` 由三个注解组成，但被追问到「`AutoConfiguration.imports` 文件是什么时候被加载的」「`@ConditionalOnMissingBean` 的判定时机」时就卡壳了。

本文从源码层面把自动装配这条链路完整走一遍，并手把手写一个自定义 Starter，彻底根治这个面试死角。

<!-- more -->

## 一、自动装配的入口：@SpringBootApplication

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@SpringBootConfiguration   // 本质是 @Configuration
@EnableAutoConfiguration   // 自动装配的核心开关
@ComponentScan(excludeFilters = {
    @Filter(type = FilterType.CUSTOM, classes = TypeExcludeFilter.class),
    @Filter(type = FilterType.CUSTOM, classes = AutoConfigurationExcludeFilter.class)
})
public @interface SpringBootApplication {
}
```

关键点拆解：

| 注解 | 作用 |
| --- | --- |
| `@SpringBootConfiguration` | 标注这是一个配置类，底层是 `@Configuration` |
| `@EnableAutoConfiguration` | **开启自动装配**，是整条链路的核心 |
| `@ComponentScan` | 扫描启动类所在包及其子包的组件，并排除自动配置类（防止被当成普通 Bean 注册） |

注意 `AutoConfigurationExcludeFilter`：它会把 `AutoConfiguration.imports` 中列出的自动配置类从 `@ComponentScan` 的扫描结果中**排除**掉。为什么？因为自动配置类有自己独立的加载机制，如果又被包扫描扫到，就会重复注册，引发 Bean 冲突。

## 二、核心注解 @EnableAutoConfiguration 到底干了什么

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@AutoConfigurationPackage   // 记录启动类所在的包，供后续扫描使用
@Import(AutoConfigurationImportSelector.class)  // 灵魂所在
public @interface EnableAutoConfiguration {
}
```

`@Import` 把 `AutoConfigurationImportSelector` 注册进容器。这个 Selector 实现了 `DeferredImportSelector`，它的 `selectImports()` 方法负责返回所有需要自动装配的配置类全限定名。

### 为什么是 DeferredImportSelector 而不是普通 ImportSelector？

因为它是**延迟执行**的。普通 `@Import` 的配置类会立即处理，而 `DeferredImportSelector` 会等所有 `@Configuration` 类解析完毕后再执行。这样做的好处是：

1. 我们自己在 `@Configuration` 类里定义的 Bean、`@ConditionalOnMissingBean` 需要感知的已有 Bean 都先注册好了；
2. 自动配置类在进行条件判断时，能拿到完整上下文，避免误判。

## 三、自动配置类的来源：从 spring.factories 到 AutoConfiguration.imports

这是自动装配最核心的机制演进，面试官非常爱问。

### Spring Boot 2.7 之前：spring.factories

```properties
# META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration,\
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
```

### Spring Boot 2.7+：AutoConfiguration.imports

为了摆脱"大杂烩"式的 spring.factories 和更好的 IDE 提示，Spring Boot 改为每个自动配置模块独立声明：

```text
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
```

Spring Boot 3.x 已彻底移除 spring.factories 方式。加载逻辑在 `AutoConfigurationImportSelector` 中：

```java
protected List<String> getCandidateConfigurations(AnnotationMetadata metadata,
        AnnotationAttributes attributes) {
    List<String> configurations = ImportCandidates.load(
            AutoConfiguration.class, getBeanClassLoader())
            .getCandidates();
    // 从 META-INF/spring/...AutoConfiguration.imports 读取候选配置类
    return configurations;
}
```

`ImportCandidates.load` 会遍历 classpath 下所有 jar 包中的 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 文件，把所有自动配置类汇总起来——这就是为什么你引入 `spring-boot-starter-web` 后，Tomcat、DispatcherServlet 就自动生效了：Starter 的 jar 里带着这个 imports 文件。

## 四、条件装配：@Conditional 系列注解

自动配置类不可能无脑加载，必须「按需装配」。条件注解就是过滤器，常见的如下：

| 注解 | 判定条件 | 典型用途 |
| --- | --- | --- |
| `@ConditionalOnClass` / `@ConditionalOnMissingClass` | classpath 是否存在指定类 | 有 `HikariDataSource` 才配置连接池 |
| `@ConditionalOnBean` / `@ConditionalOnMissingBean` | 容器中是否已有指定 Bean | 用户自定义了 `DataSource` 就不覆盖 |
| `@ConditionalOnProperty` | 配置项是否满足条件 | `spring.xxx.enabled=true` 才生效 |
| `@ConditionalOnWebApplication` | 是否 Web 应用 | Web 相关自动配置 |
| `@ConditionalOnExpression` | SpEL 表达式结果 | 复杂组合条件 |

以 `DataSourceAutoConfiguration` 为例（Spring Boot 2.x 时代）：

```java
@AutoConfiguration(before = SqlInitializationAutoConfiguration.class)
@ConditionalOnClass({ DataSource.class, EmbeddedDatabaseType.class })
@ConditionalOnMissingBean(type = "io.r2dbc.spi.ConnectionFactory")
@EnableConfigurationProperties(DataSourceProperties.class)
@Import({ DataSourcePoolMetadataProvidersConfiguration.class,
        DataSourceCheckpointRestoreConfiguration.class })
public class DataSourceAutoConfiguration {
    @Configuration(proxyBeanMethods = false)
    @Conditional(EmbeddedDatabaseCondition.class)
    @ConditionalOnMissingBean({ DataSource.class, XADataSource.class })
    @Import(EmbeddedDataSourceConfiguration.class)
    protected static class EmbeddedDatabaseConfiguration {
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnMissingBean({ DataSource.class, XADataSource.class })
    protected static class PooledDataSourceConfiguration {
        @Bean
        @ConditionalOnMissingBean
        public DataSource dataSource(DataSourceProperties properties) {
            // 按优先级创建 Hikari / Tomcat / DBCP 连接池
        }
    }
}
```

### 优先级问题：多个连接池都在 classpath 时选谁？

`DataSourceConfiguration` 内部按 `@ConditionalOnClass` 匹配 Hikari → Tomcat → DBCP2 的顺序，用 `@ConditionalOnMissingBean(DataSource.class)` 保证只有一个生效。用户一旦自定义 `DataSource` Bean，所有自动配置的连接池全部失效——这就是"约定优于配置"在代码层面的落地。

## 五、自动装配的完整执行链路

把上面串起来，一次启动的装配流程：

1. 主类标注 `@SpringBootApplication` → 触发 `@EnableAutoConfiguration`；
2. `AutoConfigurationImportSelector` 作为 `DeferredImportSelector` 延迟执行；
3. `ImportCandidates.load` 读取 classpath 所有 jar 中的 `AutoConfiguration.imports`；
4. 通过 `@ConditionalOnXxx` 过滤：类存在性、Bean 存在性、配置属性、应用类型；
5. 符合条件的自动配置类被 `@Import` 注册，内部的 `@Bean` 方法开始创建组件；
6. `@EnableConfigurationProperties` 将 `application.yml` 前缀配置绑定到 Properties 类；
7. Bean 进入容器，完成装配。

## 六、实战：手写一个自定义 Starter

懂了原理，写 Starter 就是水到渠成。目标：做一个「邮件发送」Starter，`application.yml` 配好账号就能注入 `MailSender`。

### 1. 项目结构（Maven 多模块）

```
mail-starter/
├── mail-spring-boot-autoconfigure/   # 自动配置模块（starter 的核心）
└── mail-spring-boot-starter/         # 空壳模块，仅依赖 autoconfigure
```

### 2. 配置属性类

```java
@ConfigurationProperties(prefix = "demo.mail")
public class MailProperties {
    private String host = "smtp.example.com";
    private int port = 465;
    private String username;
    private String password;
    // getter / setter 省略
}
```

### 3. 自动配置类

```java
@AutoConfiguration
@EnableConfigurationProperties(MailProperties.class)
@ConditionalOnClass(MailSender.class)          // classpath 有发送器类才装配
@ConditionalOnProperty(prefix = "demo.mail", name = "enabled", havingValue = "true", matchIfMissing = true)
public class MailAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean   // 用户自定义 MailSender 时自动退让
    public MailSender mailSender(MailProperties props) {
        MailSender sender = new MailSender();
        sender.setHost(props.getHost());
        sender.setPort(props.getPort());
        sender.setUsername(props.getUsername());
        sender.setPassword(props.getPassword());
        return sender;
    }
}
```

### 4. 声明 imports 文件

在 autoconfigure 模块的 `src/main/resources/META-INF/spring/` 下创建：

```text
# org.springframework.boot.autoconfigure.AutoConfiguration.imports
com.demo.mail.MailAutoConfiguration
```

### 5. 使用方

```yaml
demo:
  mail:
    enabled: true
    host: smtp.qq.com
    port: 465
    username: xxx@qq.com
    password: xxxxx
```

```java
@Service
public class OrderService {
    private final MailSender mailSender;  // 自动注入，无需任何配置
    public OrderService(MailSender mailSender) { this.mailSender = mailSender; }
}
```

Starter 命名规范：官方 starter 叫 `spring-boot-starter-xxx`；自定义的用 `xxx-spring-boot-starter`，避免和官方冲突。

## 七、面试常见追问

**Q1：自动配置类和普通 @Configuration 类冲突怎么办？**
自动配置类绝大多数带 `@ConditionalOnMissingBean`，用户自定义 Bean 优先。而且 `@AutoConfiguration` 类的解析顺序靠后（DeferredImportSelector），天然给用户 Bean 让路。

**Q2：如何调试自动配置是否生效？**
启动时加 `--debug`，或在 `application.yml` 配置 `debug: true`，控制台会输出 Positive matches / Negative matches / Exclusions 报告，一目了然。

**Q3：`@AutoConfiguration(before/after = ...)` 有什么用？**
控制多个自动配置类的加载顺序，例如 `DataSourceAutoConfiguration` 必须在 `MybatisAutoConfiguration` 之前。

**Q4：Spring Boot 3 相比 2.x 在自动装配上有哪些变化？**
- `AutoConfiguration.imports` 取代 spring.factories；
- 自动配置类必须标注 `@AutoConfiguration`（替代 `@Configuration` + 单独维护 EnableAutoConfiguration 列表）；
- 大量 `@ConditionalOnXxx` 条件注解底层重构为 `AutoConfiguration` 专属，性能更好。

## 总结

自动装配的本质是：**通过 @Import 机制引入一个 Selector，在启动时扫描 classpath 上的自动配置候选类，再用条件注解按需装配，最后通过配置属性绑定完成定制**。把这四步讲清楚，再配合手写 Starter 的实战经验，这道面试题就是送分题。
