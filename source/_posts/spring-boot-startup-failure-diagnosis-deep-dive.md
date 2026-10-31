---
title: 【Spring Boot 实战】启动失败诊断体系深度解析：FailureAnalyzer、条件评估报告与 Bean 冲突排查
date: 2026-10-31 08:00:00
tags:
  - Java
  - Spring Boot
  - 启动诊断
  - FailureAnalyzer
  - 源码
categories:
  - Spring 全家桶
author: 东哥
---

# 【Spring Boot 实战】启动失败诊断体系深度解析

## 前言

线上发布最怕的不是运行期报错，而是**应用起不来**。运行期报错至少有日志、有链路、有监控；启动失败时应用连端口都没监听，流量直接打到剩下的一两台机器上，随后就是雪崩。

更麻烦的是启动失败的**表象极具误导性**：

- 明明只是少配了一个 `spring.datasource.url`，报的却是 `Failed to configure a DataSource: 'url' attribute is not specified`，新手第一反应是"驱动没装"。
- 明明是两个 `@Bean` 重名，报的是 `BeanDefinitionOverrideException` 加一大坨 bean 定义栈。
- 明明是 JDK 升级后模块强封装，报的是 `InaccessibleObjectException: Unable to make field private final ... accessible`。
- 明明是本机 8080 被占，报的却是 `Web server failed to start. Port 8080 was already in use.` 然后容器里一堆 `Application run failed`。

Spring Boot 其实**内置了一整套启动失败诊断体系**，只是大多数人只看到最后那 20 行堆栈就关掉了终端。本文把这条链路拆开：`SpringApplication.run` 的失败处理流程、`FailureAnalyzer` SPI 的扩展点、`ConditionEvaluationReport` 条件评估、Bean 覆盖与循环依赖的默认策略，最后给一张"启动失败速查表"和面试追问。

---

## 一、启动失败的三类根因

把生产事故按根因归类，90% 的启动失败落在这三类：

| 类别 | 典型异常 | 本质 |
|---|---|---|
| **环境/资源类** | `Port 8080 was already in use`、`Communications link failure`、`UnknownHostException`、`NoSuchFileException` | 外部依赖不可达或配置缺失 |
| **装配类** | `NoSuchBeanDefinitionException`、`BeanDefinitionOverrideException`、`BeanCurrentlyInCreationException`、`NoUniqueBeanDefinitionException` | 容器内的对象图不成立 |
| **链接/字节码类** | `NoSuchMethodError`、`NoClassDefFoundError`、`UnsupportedClassVersionError`、`InaccessibleObjectException` | 依赖版本冲突或 JDK 平台约束 |

这三类的排查路径完全不同：环境类看配置与网络，装配类看条件评估报告与 bean 定义，链接类看依赖树与模块封装。**先分类，再动手**，比盲目 `mvn dependency:tree` 高效得多。

---

## 二、Spring Boot 的失败处理主链路

`SpringApplication.run(String... args)` 内部把真正的启动逻辑包在一个 `try-catch` 里：

```java
public ConfigurableApplicationContext run(String... args) {
    // ... 启动计时、Banner、Environment 准备
    try {
        ApplicationArguments applicationArguments = new DefaultApplicationArguments(args);
        ConfigurableEnvironment environment = prepareEnvironment(listeners, bootstrapContext, applicationArguments);
        // ...
        context = createApplicationContext();
        prepareContext(bootstrapContext, context, environment, listeners, applicationArguments, printedBanner);
        refreshContext(context);      // ← 绝大多数启动失败发生在这里
        afterRefresh(context, applicationArguments);
        // ...
        return context;
    }
    catch (Throwable ex) {
        handleRunFailure(context, ex, exceptionReporters, listeners);
        throw new IllegalStateException(ex);
    }
}
```

关键在 `handleRunFailure`：

```java
private void handleRunFailure(ConfigurableApplicationContext context, Throwable exception,
                              Collection<SpringBootExceptionReporter> exceptionReporters,
                              SpringApplicationRunListeners listeners) {
    try {
        try {
            handleExitCode(context, exception);
            if (listeners != null) {
                listeners.failed(context, exception);
            }
        }
        finally {
            reportFailure(exceptionReporters, exception);   // ← 这里产出那段可读的诊断信息
            if (context != null) {
                context.close();
            }
        }
    }
    // ...
}
```

`reportFailure` 遍历 `SpringBootExceptionReporter`，默认实现是 `FailureAnalyzers`。所以你看到的那段

```
***************************
APPLICATION FAILED TO START
***************************

Description:

Web server failed to start. Port 8080 was already in use.

Action:

Identify and stop the process that's listening on port 8080 or configure this application to listen on another port.
```

**不是异常堆栈，而是 `FailureAnalyzer` 生成的结构化诊断**（Description + Action）。这就是本文的核心：这套诊断是可扩展的。

---

## 三、FailureAnalyzer SPI：把异常翻译成人话

### 3.1 核心接口

```java
@FunctionalInterface
public interface FailureAnalyzer {
    FailureAnalysis analyze(Throwable failure);
}
```

`FailureAnalysis` 只有两个字段：`description`（发生了什么）和 `action`（该怎么办），外加可选的 `cause`。

最常用的是抽象基类 `AbstractFailureAnalyzer<T extends Throwable>`，它按泛型自动过滤异常类型：

```java
public abstract class AbstractFailureAnalyzer<T extends Throwable> implements FailureAnalyzer {

    @Override
    public FailureAnalysis analyze(Throwable failure) {
        T cause = findCause(failure, getCauseType());
        return (cause != null) ? analyze(failure, cause) : null;
    }

    protected abstract Class<T> getCauseType();

    protected abstract FailureAnalysis analyze(Throwable rootFailure, T cause);
}
```

注意 `findCause` 会**沿 cause 链向下钻**，这是关键设计：Spring Boot 启动时的异常经常被包了三四层（`BeanCreationException` → `UnsatisfiedDependencyException` → `BeanInstantiationException` → 真实异常），分析器只要关心最内层的真实原因。

### 3.2 注册方式

`FailureAnalyzer` 通过 `META-INF/spring.factories` 注册（注意：这一条在 Spring Boot 3.x 仍然走 `spring.factories`，不是 `AutoConfiguration.imports`）：

```properties
org.springframework.boot.diagnostics.FailureAnalyzer=\
com.example.diagnostics.PortConflictFailureAnalyzer,\
com.example.diagnostics.RedisHandshakeFailureAnalyzer
```

### 3.3 手写一个分析器

场景：内部框架强制要求所有服务连接公司自研配置中心，连不上时原生异常是 `ConnectException: Connection refused`，翻日志根本不知道是配置中心的问题。我们可以把它翻译成明确诊断：

```java
public class ConfigCenterUnavailableFailureAnalyzer
        extends AbstractFailureAnalyzer<ConnectException> {

    @Override
    protected Class<ConnectException> getCauseType() {
        return ConnectException.class;
    }

    @Override
    protected FailureAnalysis analyze(Throwable rootFailure, ConnectException cause) {
        String stack = Throwables.getStackTraceAsString(rootFailure);
        if (!stack.contains("config-center-client")) {
            return null;   // 不是我们的问题，交还给下一个分析器
        }
        return new FailureAnalysis(
            "无法连接配置中心（" + cause.getMessage() + "）。",
            "1) 检查 config.center.endpoint 是否正确\n" +
            "2) 确认本机到配置中心 8089 端口网络可达：telnet <host> 8089\n" +
            "3) 本地开发可临时设置 config.center.enabled=false 启动",
            cause);
    }
}
```

**返回 `null` 表示"我不认识这个异常"**，`FailureAnalyzers` 会继续问下一个分析器。这个约定让多个分析器可以安全共存，也让第三方 starter 能各自贡献诊断能力。

### 3.4 生产价值

我们把这套机制用在了两个地方，收益很直接：

1. **中间件 SDK 自带分析器**：Redis 认证失败、Kafka `TopicAuthorizationException`、注册中心 401，全部给出中文 Action，值班同学不用再翻 SDK 源码。
2. **配置缺失统一收口**：把 `@ConfigurationProperties` 的必填校验失败（`BindValidationException`）翻译成"缺少哪个 key、在哪份配置里加、示例值是什么"。

顺带一个细节：**分析器里绝对不能做 IO 或远程调用**。它是在启动失败路径上执行的，此时线程池、连接池都可能是坏的，一旦分析器自己抛异常，`FailureAnalyzers` 会吞掉并退化成原始堆栈，你精心写的诊断就白费了。

---

## 四、条件评估报告：装配类失败的照妖镜

`@ConditionalOnClass`、`@ConditionalOnMissingBean`、`@ConditionalOnProperty` 让自动配置"按需生效"，代价是**你不知道为什么某个配置没生效**。

Spring Boot 的答案有两个：

### 4.1 `--debug` / `debug=true`

启动时输出 `CONDITIONS EVALUATION REPORT`，分两块：

```
Positive matches:
-----------------
   DataSourceAutoConfiguration matched:
      - @ConditionalOnClass found required classes 'javax.sql.DataSource', 'org.springframework.jdbc.datasource.embedded.EmbeddedDatabaseType' (OnClassCondition)

Negative matches:
-----------------
   DataSourceAutoConfiguration.JdbcTemplateConfiguration did not match:
      - @ConditionalOnMissingBean (types: org.springframework.jdbc.core.JdbcOperations; SearchStrategy: all) found beans of type 'org.springframework.jdbc.core.JdbcOperations' (OnBeanCondition)
```

- **Positive matches**：生效了，因为满足了哪些条件。
- **Negative matches**：没生效，因为哪个条件不满足。
- **Exclusions**：被 `spring.autoconfigure.exclude` 显式排除。

实战里最常见的两个"负匹配"：

| 现象 | 负匹配原因 | 处理 |
|---|---|---|
| 自己写的 `DataSource` 没被用 | `@ConditionalOnMissingBean` 发现已有 bean | 用 `@Primary` 或排除自动配置 |
| 某个 starter 完全不生效 | `@ConditionalOnClass` 找不到类（依赖被 `provided` 或排除了） | `mvn dependency:tree` 确认坐标 |

### 4.2 Actuator 的 `/actuator/conditions`

生产环境不方便加 `--debug` 重启，用 `management.endpoints.web.exposure.include=conditions` 暴露端点，直接 `curl`：

```bash
curl -s localhost:8080/actuator/conditions | jq '.contexts.application.negativeMatches'
```

**注意安全**：这个端点会暴露完整类名与 bean 名，属于内部信息，必须配合 Spring Security 或内网限制。

### 4.3 源码视角

`ConditionEvaluationReport` 由 `ConditionEvaluationReportLoggingListener` 在 `ApplicationPreparedEvent` 时挂到容器上，`ConfigurationClassParser` 在解析每个 `@Configuration` 时调用 `ConditionEvaluator.shouldSkip`，并把结果记录进 report。所以报告里的顺序就是**配置类解析顺序**，看报告能顺带理解自动配置的加载次序。

---

## 五、Bean 定义冲突：从"能覆盖"到"禁止覆盖"

Spring Boot 2.1 起，**同名 bean 默认不允许覆盖**，抛 `BeanDefinitionOverrideException`。这是把一类静默 bug 提前到启动期，非常值得。

```java
@Configuration
public class AConfig {
    @Bean
    public ObjectMapper objectMapper() { return new ObjectMapper(); }
}

@Configuration
public class BConfig {
    @Bean
    public ObjectMapper objectMapper() {      // 冲突
        ObjectMapper m = new ObjectMapper();
        m.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
        return m;
    }
}
```

启动报：

```
Invalid bean definition with name 'objectMapper' defined in class path resource [BConfig.class]:
Cannot register bean definition [...] since there is already [...] bound.
```

三种处理方式，优先级从高到低：

1. **消除重复定义**（首选）：把公共 `ObjectMapper` 收口到一个 `@Configuration`，其他模块注入而不是重新定义。
2. **改名**：`@Bean("bizObjectMapper")`，用 `@Qualifier` 注入。
3. **打开覆盖开关**（最后手段）：
   ```yaml
   spring:
     main:
       allow-bean-definition-overriding: true
   ```
   覆盖顺序取决于配置类解析顺序，**不确定即不可靠**。开了这个开关的项目，半年后一定会出现"某个 bean 被莫名替换"的诡异问题。

> 顺带提醒：`@ComponentScan` 扫到两个同简单类名的类（不同包）也会冲突，bean 名默认是**首字母小写的简单类名**，例如 `com.a.UserService` 和 `com.b.UserService` 都会注册为 `userService`。这类冲突在多模块合并时很常见。

---

## 六、循环依赖：Boot 2.6 起默认禁止

`spring.main.allow-circular-references` 自 2.6 起默认 `false`，报 `BeanCurrentlyInCreationException` / `Relying upon circular references is discouraged`。

业务代码里的循环依赖几乎总是**职责划分错误**的信号，而不是"加个 `@Lazy` 就好"：

```java
@Service
public class OrderService {
    @Autowired private PayService payService;     // Order → Pay
}

@Service
public class PayService {
    @Autowired private OrderService orderService; // Pay → Order
}
```

三种正确修法：

| 方案 | 适用 | 副作用 |
|---|---|---|
| 抽第三方法服务（`OrderPayFacade`） | 双向调用是业务真需求 | 无，最推荐 |
| 事件解耦（`ApplicationEventPublisher`） | 一方只是"通知"另一方 | 变为最终一致 |
| `@Lazy` 注入代理 | 紧急止血 | 掩盖设计问题，首次调用才报错 |

**面试高频追问**：Spring 用三级缓存解决 setter/field 注入的循环依赖，为什么构造器注入的循环依赖解决不了？

答：构造器注入时，对象实例还没创建出来（连 `earlySingletonObjects` 都放不进去），拿不到引用就无法完成构造，只能提前暴露 `ObjectFactory`——而工厂本身也要等构造完成才能产出实例，形成死结。所以 Boot 2.6 之后官方态度很明确：**构造器注入 + 禁止循环依赖**，让问题在编译/启动期暴露。

---

## 七、启动失败速查表

这张表建议贴到值班手册里：

| 异常关键字 | 根因 | 快速定位 |
|---|---|---|
| `Port X was already in use` | 端口占用/上次进程未退出 | `ss -lntp \| grep X`、`lsof -i:X` |
| `Failed to configure a DataSource` | 缺 url 或驱动不在 classpath | 检查 `spring.datasource.*`、`dependency:tree` |
| `BeanDefinitionOverrideException` | 同名 bean | 搜索 bean 名，见第五节 |
| `BeanCurrentlyInCreationException` | 循环依赖 | 看异常里的依赖链，抽第三方服务 |
| `NoSuchMethodError` / `NoClassDefFoundError` | 依赖版本冲突（常见于 `spring-boot-dependencies` 被覆盖） | `mvn dependency:tree -Dverbose` 找双版本 |
| `UnsupportedClassVersionError` | 编译 JDK 高于运行 JDK | 对齐 `<java.version>` 与基础镜像 |
| `InaccessibleObjectException` | JDK 强封装 | 加最小化 `--add-opens`，或升级依赖 |
| `Unable to start ServletWebServerApplicationContext due to missing ServletWebServerFactory bean` | 缺 `spring-boot-starter-web` 或被 `@SpringBootApplication` 放错包 | 检查依赖与包扫描路径 |
| `Could not resolve placeholder` | 配置项缺失/占位符拼错 | `--debug` 看 Environment、检查 profile |
| `Flyway migration failed` / `Schema-validation: missing table` | 脚本与实体不一致 | 本地跑一遍迁移、检查 `ddl-auto` |

### 一个真实案例

某次发布，应用在 K8s 里反复 `CrashLoopBackOff`，日志只有一行 `Application run failed` 加 `Caused by: java.net.UnknownHostException: mysql-prod`。看似 DNS 问题，实际是 **`spring.profiles.active` 通过环境变量注入时被覆盖成了 `local`**，连到了本地 profile 里的 `mysql-prod`（一个早已下线的内网域名）。

定位手段：`/actuator/env` 不可用（应用没起来），最后是在启动脚本里 `--debug` 打出 `Environment` 的 `propertySources`，才发现 `SPRING_PROFILES_ACTIVE` 在两个 ConfigMap 里各定义了一次，后加载的胜出。

**教训**：启动失败排查的第一步永远是**确认应用到底加载了哪份配置**。Spring Boot 2.4 之后配置加载模型改成 `ConfigData`，`spring.config.import`、多文档 `---`、profile 特定文件（`application-prod.yml`）优先级链路变复杂了，`--debug` 输出的 `propertySources` 顺序就是最终答案。

---

## 八、面试追问

**Q1：Spring Boot 启动失败时那段 Description/Action 是怎么来的？**

`SpringApplication.run` 捕获 `Throwable` 后调用 `handleRunFailure` → `reportFailure` → `FailureAnalyzers`（`SpringBootExceptionReporter` 的默认实现）→ 遍历所有注册的 `FailureAnalyzer`，第一个返回非 null 的 `FailureAnalysis` 胜出，格式化输出 Description 与 Action。分析器通过 `META-INF/spring.factories` 注册，可自定义。

**Q2：自动配置没生效，你怎么查？**

三条路：`--debug` 看 `CONDITIONS EVALUATION REPORT` 的 Negative matches；`/actuator/conditions` 在线看；直接读 `AutoConfiguration.imports` + 条件注解推演。核心是确认**是哪个条件不满足**（类缺失、bean 已存在、属性不匹配）。

**Q3：为什么 Spring Boot 默认禁止 bean 覆盖和循环依赖？**

两者都是"能跑但不可预期"的隐患。bean 覆盖的结果依赖配置类解析顺序，循环依赖依赖代理与提前暴露，都会让对象图变得难以推理。Boot 的选择是**把不确定性提前成启动期硬失败**，代价是升级时要清理历史债。

**Q4：`--add-opens`（见另一篇）和启动失败有什么关系？**

JDK 16 起默认强封装，框架通过反射访问 JDK 内部 API（如 `java.lang` 的私有字段）会抛 `InaccessibleObjectException`，表现就是启动直接失败。这是"链接类"启动失败的典型代表。

---

## 九、总结

1. 启动失败先分类：**环境/资源、装配、链接/字节码**，三类排查路径完全不同。
2. Spring Boot 的诊断输出不是堆栈，是 `FailureAnalyzer` 生成的结构化 `Description + Action`，可通过 `spring.factories` 扩展，**返回 null 表示不认领**。
3. 装配类问题的核心工具是 `ConditionEvaluationReport`（`--debug` 或 `/actuator/conditions`），看 Negative matches 找不满足的条件。
4. bean 覆盖与循环依赖自 Boot 2.1/2.6 起默认禁止，**这是设计约束而不是配置麻烦**，修法优先"抽第三方/事件解耦"，慎用 `allow-*` 开关。
5. 排查第一步永远是**确认加载了哪份配置**，`--debug` 的 `propertySources` 比猜 profile 靠谱。

启动期是系统最脆弱的时刻，也是**信息最全的时刻**——所有 bean 都还在内存里，所有条件评估结果都可查。把诊断体系用起来，比事后加十个监控告警都值。
