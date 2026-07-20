---
title: Spring @Conditional 条件装配原理与源码深度解析
date: 2026-07-20 08:00:00
tags:
  - Spring Boot
  - 条件注解
  - 自动配置
  - 源码
categories:
  - Spring Boot
  - 原理源码
author: 东哥
---

# Spring @Conditional 条件装配原理与源码深度解析

## 一、从实际问题出发

你有没有想过这样一个问题：为什么在 Spring Boot 应用中，引入 `spring-boot-starter-web` 依赖后，Tomcat 就自动启动了？而引入 `spring-boot-starter-reactor-netty` 后，又自动换成了 Netty WebServer？

这些"智能"的背后，就是 Spring 的条件装配机制在起作用——**@Conditional 注解及其衍生注解**。

## 二、@Conditional 的核心概念

### 2.1 基础用法

`@Conditional` 是 Spring 4.0 引入的核心注解，它的作用很简单：**满足特定条件时才创建 Bean / 加载配置类**。

```java
@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface Conditional {
    Class<? extends Condition>[] value();
}
```

最基础的用法是实现 `Condition` 接口：

```java
public class LinuxCondition implements Condition {
    @Override
    public boolean matches(ConditionContext context, AnnotatedTypeMetadata metadata) {
        return context.getEnvironment().getProperty("os.name").contains("Linux");
    }
}

@Configuration
public class AppConfig {
    @Bean
    @Conditional(LinuxCondition.class)
    public SomeService linuxService() {
        return new LinuxService();
    }
}
```

### 2.2 Spring Boot 的 Condition 体系

Spring Boot 并没有直接使用 Spring Framework 的 `@Conditional` + `Condition` 设计，而是扩展了自己的一套条件机制：

```
Spring Condition（接口）
    ├── SpringBootCondition（抽象基类）
    │   ├── OnClassCondition
    │   ├── OnPropertyCondition
    │   ├── OnWebApplicationCondition
    │   ├── OnBeanCondition
    │   ├── OnResourceCondition
    │   └── OnExpressionCondition
    └── ProfileCondition（用于 @Profile）
```

## 三、Spring Boot 的条件注解全家桶

Spring Boot 在 `spring-boot-autoconfigure` 中预置了大量条件注解：

| 注解 | 作用 | 典型应用 |
|---|---|---|
| `@ConditionalOnClass` | classpath 中存在指定类时 | 检测 `DataSource` 类是否存在 |
| `@ConditionalOnMissingClass` | classpath 中不存在指定类时 | 多数据源场景 |
| `@ConditionalOnBean` | 容器中存在指定 Bean 时 | 已有 `DataSource` 时不再创建新的 |
| `@ConditionalOnMissingBean` | 容器中不存在指定 Bean 时 | 创建默认实现 |
| `@ConditionalOnProperty` | 配置属性匹配时 | 通过配置开关启用/禁用功能 |
| `@ConditionalOnExpression` | SpEL 表达式为 true 时 | 复杂条件判断 |
| `@ConditionalOnResource` | 指定资源存在时 | 检测 `mybatis-config.xml` |
| `@ConditionalOnWebApplication` | 当前是 Web 应用时 | Web 相关配置 |
| `@ConditionalOnNotWebApplication` | 当前不是 Web 应用时 | 非 Web 场景 |
| `@ConditionalOnJndi` | JNDI 资源存在时 | 传统 JEE 部署 |
| `@ConditionalOnJava` | Java 版本满足条件时 | Java 版本特定配置 |
| `@ConditionalOnSingleCandidate` | 指定类型的 Bean 只有一个候选时 | 主候选 Bean |

## 四、源码深度解析：Spring Boot 如何实现条件评估

### 4.1 AutoConfigurationImportFilter 接口

Spring Boot 在自动配置类的加载过程中，通过 `AutoConfigurationImportFilter` 接口实现 **提前过滤**——在加载配置类之前就判断是否满足条件，避免不必要的类加载：

```java
// AutoConfigurationImportFilter 接口
@FunctionalInterface
public interface AutoConfigurationImportFilter {
    boolean[] match(String[] autoConfigurationClasses, 
                    AutoConfigurationMetadata autoConfigurationMetadata);
}
```

核心实现类：`OnClassCondition` 实现了此接口：

```java
// OnClassCondition 部分源码
public class OnClassCondition extends SpringBootCondition
        implements AutoConfigurationImportFilter {

    @Override
    public boolean[] match(String[] autoConfigurationClasses,
                           AutoConfigurationMetadata autoConfigurationMetadata) {
        // 创建一个评估器
        ConditionOutcome[] outcomes = evaluateOutcomes(autoConfigurationClasses,
                autoConfigurationMetadata);
        
        boolean[] matches = new boolean[outcomes.length];
        for (int i = 0; i < outcomes.length; i++) {
            matches[i] = outcomes[i] != null && outcomes[i].isMatch();
        }
        return matches;
    }

    private ConditionOutcome[] evaluateOutcomes(
            String[] autoConfigurationClasses,
            AutoConfigurationMetadata autoConfigurationMetadata) {
        // 使用多线程并行评估条件，提升启动速度
        ...
    }
}
```

**关键优化**：Spring Boot 2.x+ 在评估 `@ConditionalOnClass` 时，通过 `ClassNameFilter` 使用 **并行** 方式检查 classpath 中的类是否存在，大幅提升启动速度。

### 4.2 ConditionEvaluator 的核心逻辑

`ConditionEvaluator` 是 Spring 框架内部评估 `@Conditional` 的核心类：

```java
// ConditionEvaluator 核心逻辑（位于 spring-context 中）
class ConditionEvaluator {

    public boolean shouldSkip(AnnotatedTypeMetadata metadata, ConfigurationPhase phase) {
        // 1. 检查是否有 @Conditional 注解
        if (!hasConditionAnnotation(metadata)) {
            return false; // 没有 @Conditional，不跳过
        }

        // 2. 获取所有 Condition 实现类
        List<Condition> conditions = getConditions(metadata);

        // 3. 按照优先级排序
        AnnotationAwareOrderComparator.sort(conditions);

        // 4. 逐个评估
        for (Condition condition : conditions) {
            ConfigurationPhase requiredPhase = getRequiredPhase(condition);
            if (requiredPhase != null && requiredPhase != phase) {
                continue;
            }
            if (!condition.matches(this.context, metadata)) {
                return true; // 条件不满足，跳过
            }
        }
        return false; // 所有条件满足，不跳过
    }
}
```

### 4.3 ConfigurationPhase 两阶段评估

Spring 把条件评估分为两个阶段：

```
PARSE_CONFIGURATION（解析阶段）
    ↓
    @Conditional 在此阶段评估
    ↓ 条件不满足 → 跳过整个配置类
    ↓
REGISTER_BEAN（注册阶段）
    ↓
    @Bean / @Component 级别的 @Conditional 在此阶段评估
    ↓ 条件不满足 → 跳过该 Bean 注册
```

**为什么需要两阶段？** 因为某些条件依赖其他 Bean 的存在，必须等到配置类解析完毕后才能在 BeanFactory 中查到。

### 4.4 SpringBootCondition 的模板方法模式

`SpringBootCondition` 是 Spring Boot 条件注解的基类，使用了 **模板方法模式**：

```java
public abstract class SpringBootCondition extends Condition
        implements AutoConfigurationImportFilter {

    @Override
    public final boolean matches(ConditionContext context, 
                                  AnnotatedTypeMetadata metadata) {
        String classOrMethodName = getClassName(metadata);
        try {
            // 模板方法：子类实现 getMatchOutcome()
            ConditionOutcome outcome = getMatchOutcome(context, metadata);
            logOutcome(classOrMethodName, outcome);
            recordEvaluation(classOrMethodName, outcome);
            return outcome.isMatch();
        } catch (Exception ex) {
            throw new ConditionEvaluationException(...);
        }
    }

    // 由子类实现具体的匹配逻辑
    protected abstract ConditionOutcome getMatchOutcome(
            ConditionContext context, AnnotatedTypeMetadata metadata);
}
```

## 五、源码实战：@ConditionalOnClass 的底层实现

以 `@ConditionalOnClass` 为例，看看 Spring Boot 如何判断一个类是否存在：

```java
@Target({ ElementType.TYPE, ElementType.METHOD })
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Conditional(OnClassCondition.class)
public @interface ConditionalOnClass {
    Class<?>[] value() default {};  // 指定 Class 对象
    String[] name() default {};     // 指定全限定类名
}
```

`OnClassCondition.getMatchOutcome()` 方法：

```java
@Override
public ConditionOutcome getMatchOutcome(ConditionContext context,
                                         AnnotatedTypeMetadata metadata) {
    // 从注解中提取 value 和 name 属性
    MultiValueMap<String, Object> attributes = 
            metadata.getAllAnnotationAttributes(ConditionalOnClass.class.getName(), true);
    
    List<String> classNames = new ArrayList<>();
    
    // 1. 处理 Class<?>[] value()
    List<Object> value = attributes.get("value");
    if (value != null) {
        for (Object v : value) {
            if (v instanceof Class) {
                classNames.add(((Class<?>) v).getName());
            }
        }
    }
    
    // 2. 处理 String[] name()
    List<Object> name = attributes.get("name");
    if (name != null) {
        for (Object n : name) {
            classNames.add((String) n);
        }
    }
    
    // 3. 使用 ClassNameFilter 检查类是否存在
    List<ClassNameFilter.Missing> missing = filter(classNames, ClassNameFilter.MISSING);
    
    if (missing.isEmpty()) {
        return ConditionOutcome.match("All classes found");
    }
    return ConditionOutcome.noMatch("Missing: " + missing);
}
```

## 六、实战案例：自定义 @Conditional

### 6.1 场景：根据地区加载不同的 Bean

```java
// 自定义条件注解
@Target({ ElementType.TYPE, ElementType.METHOD })
@Retention(RetentionPolicy.RUNTIME)
@Conditional(OnRegionCondition.class)
public @interface ConditionalOnRegion {
    Region value();
    
    enum Region {
        CHINA, OVERSEAS
    }
}

// Condition 实现
public class OnRegionCondition implements Condition {
    @Override
    public boolean matches(ConditionContext context, 
                           AnnotatedTypeMetadata metadata) {
        // 获取注解参数
        Map<String, Object> attributes = metadata.getAnnotationAttributes(
                ConditionalOnRegion.class.getName());
        ConditionalOnRegion.Region region = 
                (ConditionalOnRegion.Region) attributes.get("value");
        
        String regionConfig = context.getEnvironment()
                .getProperty("app.region", "china");
        
        return switch (region) {
            case CHINA -> "china".equalsIgnoreCase(regionConfig);
            case OVERSEAS -> "overseas".equalsIgnoreCase(regionConfig);
        };
    }
}

// 使用
@Configuration
public class PaymentConfig {
    
    @Bean
    @ConditionalOnRegion(ConditionalOnRegion.Region.CHINA)
    public PaymentService alipayPayment() {
        return new AlipayPaymentService();
    }
    
    @Bean
    @ConditionalOnRegion(ConditionalOnRegion.Region.OVERSEAS)
    public PaymentService stripePayment() {
        return new StripePaymentService();
    }
}
```

### 6.2 场景：版本控制的 API 适配

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Conditional(OnApiVersionCondition.class)
public @interface ConditionalOnApiVersion {
    int minVersion() default 1;
}

public class OnApiVersionCondition implements Condition {
    @Override
    public boolean matches(ConditionContext context, 
                           AnnotatedTypeMetadata metadata) {
        int minVersion = (int) metadata.getAnnotationAttributes(
                ConditionalOnApiVersion.class.getName()).get("minVersion");
        int currentVersion = Integer.parseInt(
                context.getEnvironment().getProperty("api.version", "1"));
        return currentVersion >= minVersion;
    }
}
```

## 七、条件注解的常见陷阱

### 7.1 @ConditionalOnClass 的字符串方式与 Class 方式的区别

```java
// 推荐：使用字符串方式（不会触发类加载）
@ConditionalOnClass(name = "com.mysql.cj.jdbc.Driver")

// 不推荐：使用 Class 方式（条件不满足时也会尝试加载类，可能导致 ClassNotFoundException）
@ConditionalOnClass(com.mysql.cj.jdbc.Driver.class)
```

**为什么？** Spring Boot 在评估条件时，如果使用 `class` 属性，JVM 会先尝试加载这个类，如果类不存在就直接报 `NoClassDefFoundError`，条件评估都没机会执行。

### 7.2 多个条件注解的与/或关系

```java
// 多个 @ConditionalOnClass → AND 关系（所有条件都满足）
@ConditionalOnClass({RedisTemplate.class, JedisConnectionFactory.class})

// 多层注解 → 也是 AND 关系
@ConditionalOnClass(RedisTemplate.class)
@ConditionalOnProperty(name = "redis.enabled", havingValue = "true")

// 如何实现 OR 关系？需要自定义 Condition
public class RedisOrJedisCondition implements Condition {
    @Override
    public boolean matches(ConditionContext context, AnnotatedTypeMetadata metadata) {
        ClassLoader loader = context.getClassLoader();
        try {
            Class.forName("org.springframework.data.redis.core.RedisTemplate", false, loader);
            return true;
        } catch (ClassNotFoundException e) {
            // fall through
        }
        try {
            Class.forName("redis.clients.jedis.Jedis", false, loader);
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }
}
```

### 7.3 自动配置的条件冲突

Spring Boot 通过 `@AutoConfigureBefore`、`@AutoConfigureAfter`、`@AutoConfigureOrder` 控制自动配置类的执行顺序。如果配置 A 需要 `DataSource` Bean，但配置 B 的 `DataSource` 创建条件不满足，就可能导致 NPE。

**解决方案**：使用 `@ConditionalOnSingleCandidate` 而不是 `@ConditionalOnBean`，确保只有一个候选 Bean。

## 八、性能影响

Spring Boot 2.3+ 引入了 **自动配置的惰性初始化**，可以通过以下方式减少条件评估的开销：

```yaml
spring:
  main:
    lazy-initialization: true  # 全局惰性初始化
```

Spring Boot 3.x 更进一步，通过 **AOT 编译** 在构建期就完成条件评估优化：

```xml
<plugin>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-maven-plugin</artifactId>
    <configuration>
        <excludes>
            <exclude>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-configuration-processor</artifactId>
            </exclude>
        </excludes>
    </configuration>
    <executions>
        <execution>
            <id>process-aot</id>
            <goals>
                <goal>process-aot</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

## 九、面试高频追问

### Q1：@Conditional 和 @Profile 有什么区别和联系？

`@Profile` 是 `@Conditional` 的特例实现，底层通过 `ProfileCondition` 实现。`@Profile("dev")` 等价于 `@Conditional(ProfileCondition.class)` 配合环境判断。

### Q2：自定义 @Conditional 需要注意什么？

1. 实现 `Condition` 接口的 `matches` 方法
2. 善用 `ConditionContext` 获取 Environment、ClassLoader、BeanFactory 等
3. 避免在 `matches` 方法中做耗时操作（如数据库查询）
4. 考虑使用 `@Order` 控制多个条件的执行顺序

### Q3：Spring Boot 自动配置中的 @ConditionalOnMissingBean 和 @ConditionalOnBean 有什么区别？

`@ConditionalOnMissingBean`：**推荐使用**，允许用户自定义 Bean 覆盖默认配置；`@ConditionalOnBean`：在某些场景下可能导致循环依赖问题，因为它在 Bean 注册阶段才评估，但引用的 Bean 可能还没注册。

## 十、总结

| 知识维度 | 关键点 |
|---|---|
| **核心思想** | 通过条件评估决定是否创建 Bean / 加载配置类 |
| **执行阶段** | 解析阶段（PARSE_CONFIGURATION）→ 注册阶段（REGISTER_BEAN）|
| **Spring Boot 扩展** | SpringBootCondition + AutoConfigurationImportFilter 实现自动配置过滤 |
| **条件注解种类** | OnClass、OnProperty、OnBean、OnResource、OnWebApplication 等 |
| **性能优化** | 并行评估、惰性初始化、AOT 编译期处理 |

理解 `@Conditional` 的工作原理，是深入理解 Spring Boot 自动配置机制的第一步。当你遇到某个 Bean 没有按预期创建时，可以通过 `spring-boot-autoconfigure` 的日志级别调整为 DEBUG 来查看条件评估结果，快速定位问题所在。
