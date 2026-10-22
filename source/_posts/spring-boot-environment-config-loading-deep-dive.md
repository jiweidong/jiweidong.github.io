---
title: 【Spring Boot 源码】配置加载机制深度解析：Environment、PropertySource 顺序与多环境治理
date: 2026-10-22 08:20:00
tags:
  - Java
  - Spring Boot
  - Environment
  - 配置中心
  - 源码
categories:
  - Java 深挖
author: 东哥
---

# 【Spring Boot 源码】配置加载机制深度解析：Environment、PropertySource 顺序与多环境治理

## 前言

"配置为什么不生效？"——这是 Spring Boot 项目里最高频的求助之一。典型版本有：

- `application.yml` 里写了 `server.port=8080`，命令行 `--server.port=9090` 却没覆盖成功；
- 配置中心下发了新值，本地 `application.properties` 把它盖掉了；
- `@Value("${xxx:default}")` 拿到了默认值，但配置明明存在；
- 测试环境正常、生产环境取到 `null`，两边配置文件 diff 完全一样；
- `@ConfigurationProperties` 校验不通过，报错信息却指不到是哪个源。

这些问题的根因都指向同一件事：**你不清楚 Spring 的配置是"多源叠加 + 有序覆盖"的，也不清楚覆盖规则由谁决定**。

本文从 `Environment` 抽象讲到 `ConfigDataEnvironmentPostProcessor` 的加载流程，再落到多环境治理与配置中心的工程实践。看完你应该能一眼定位"配置不生效"的根因。

---

## 一、核心抽象：`Environment` 与 `PropertySource`

### 1.1 三层结构

```
Environment（接口）
 └─ ConfigurableEnvironment
     ├─ MutablePropertySources   ← 有序的 PropertySource 列表（顺序即优先级）
     │    ├─ commandLineArgs        (最高)
     │    ├─ systemProperties
     │    ├─ systemEnvironment
     │    ├─ random
     │    ├─ applicationConfig: [classpath:/application.yml]
     │    ├─ applicationConfig: [file:./config/application.yml]
     │    └─ defaultProperties      (最低)
     └─ profiles（激活的 profile 集合）
```

**关键认知：`MutablePropertySources` 是一个 `List`，不是 `Map`。** 查询时从头到尾遍历，**第一个命中的值就返回**——所以"谁在前面谁赢"。这和很多人直觉里"多文件合并成一个 Map"完全不同。

### 1.2 `PropertySource` 有"来源类型"之分

Spring Boot 2.4 引入了 `PropertySource` 的 `origin` 概念（`OriginLookup`），让你能追溯"这个值到底来自哪个文件的第几行"：

```java
@Autowired
private ConfigurableEnvironment env;

public void trace(String key) {
    PropertySource<?> ps = env.getPropertySources().stream()
        .filter(p -> p.containsProperty(key))
        .findFirst()
        .orElse(null);
    System.out.println("命中源: " + (ps == null ? "none" : ps.getName()));
    if (ps instanceof OriginLookup<?> lookup) {
        System.out.println("来源: " + lookup.getOrigin(key)); // 文件:行号 或 URL
    }
}
```

这个能力在生产排障时价值极高——线上有个 `/actuator/env` 端点（需显式开启 `management.endpoint.env.show-values`），能看到每个 key 的命中源与覆盖链。

### 1.3 `@Value` vs `@ConfigurationProperties` vs `Environment#getProperty`

| 方式 | 类型安全 | 松散绑定 | 校验 | 动态刷新 | 适用 |
|---|---|---|---|---|---|
| `@Value("${a.b}")` | 否 | 不支持 | 否 | 需 `@RefreshScope` | 零散单个值 |
| `@ConfigurationProperties` | 是 | 支持（kebab/camel） | `@Validated` | 需 `@RefreshScope` / 重建 | **结构化配置（推荐）** |
| `env.getProperty(k)` | 否 | 不支持 | 否 | 天然支持 | 动态 key、兜底逻辑 |

```java
@ConfigurationProperties(prefix = "app.llm")
@Validated
public record LlmProperties(
    @NotBlank String baseUrl,
    @NotBlank String apiKey,
    @Min(1) @Max(128) int maxConcurrency,
    Duration timeout,
    Map<String, ModelConfig> models
) {
    public record ModelConfig(String model, @Min(1) int maxTokens) { }
}
```

---

## 二、加载流程：`ConfigDataEnvironmentPostProcessor`

Spring Boot 2.4 重写了配置加载（`ConfigData` API），2.4 之前是 `ConfigFileApplicationListener`。现在的主线是：

```
SpringApplication.run()
 └─ prepareEnvironment()
     ├─ 创建/获取 Environment（ApplicationEnvironment）
     ├─ 配置 propertySources（defaultProperties、commandLineArgs…）
     ├─ 触发 ApplicationEnvironmentPreparedEvent
     │    └─ EnvironmentPostProcessorApplicationListener
     │         └─ ConfigDataEnvironmentPostProcessor.postProcessEnvironment()
     │              ├─ 解析 config data 位置（classpath:/, file:./, file:./config/…）
     │              ├─ 加载 application.yml / application-{profile}.yml
     │              ├─ 处理 spring.config.import（配置中心入口）
     │              └─ 绑定 + 校验 profile
     └─ 绑定 ConfigurationProperties
```

### 2.1 默认搜索位置与优先级

Spring Boot 默认按**从低到高**的顺序加载（后来者覆盖前者）：

| 顺序（低→高） | 位置 | 说明 |
|---|---|---|
| 1 | `classpath:/application.yml` | jar 内默认配置 |
| 2 | `classpath:/config/application.yml` | jar 内 config 目录 |
| 3 | `file:./application.yml` | 工作目录 |
| 4 | `file:./config/application.yml` | 工作目录 config |
| 5 | `file:./config/*/application.yml` | config 子目录（2.4+） |

同一位置下 `.properties` 优先于 `.yml`（准确说是**后加载者优先**，properties 在 yml 之后加载）。但**profile 文件永远优先于非 profile 文件**：`application-prod.yml` 覆盖 `application.yml`。

### 2.2 完整优先级链（低 → 高）

这是必须背下来的表，面试和排障都用得上：

| 优先级 | 来源 |
|---|---|
| 最低 | `SpringApplication.setDefaultProperties()` |
| ↓ | `@PropertySource` 注解（注意：**在 refresh 阶段才加入，且优先级低于 config data**） |
| ↓ | `application.yml` / `application-{profile}.yml`（按上文位置顺序） |
| ↓ | `RandomValuePropertySource`（`random.*`） |
| ↓ | 操作系统环境变量 |
| ↓ | Java System Properties（`-Dkey=value`） |
| ↓ | JNDI |
| ↓ | `ServletContext` init params / `ServletConfig` init params |
| ↓ | `SPRING_APPLICATION_JSON` |
| ↓ | 命令行参数 `--key=value` |
| ↓ | 测试中的 `@TestPropertySource` / `@SpringBootTest(properties=…)` |
| ↓ | `@DynamicPropertySource`（Testcontainers 场景） |
| 最高 | DevTools 全局设置（`~/.config/spring-boot/spring-boot-devtools.properties`） |

> ⚠️ 一个高频误区：**`@PropertySource` 的优先级比 `application.yml` 低**。所以你在 `@PropertySource("custom.properties")` 里写的 `server.port`，会被 `application.yml` 覆盖。要让它生效，必须用 `PropertySourceFactory` 手动插到前面：

```java
@Configuration
public class HighPriorityConfig implements EnvironmentPostProcessor, Ordered {

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment env, SpringApplication app) {
        Map<String, Object> map = Map.of("custom.flag", "true");
        env.getPropertySources().addFirst(new MapPropertySource("customHigh", map));
    }

    @Override
    public int getOrder() { return Ordered.HIGHEST_PRECEDENCE + 10; }
}
```

并在 `META-INF/spring.factories`（Boot 3 改用 `META-INF/spring/org.springframework.boot.env.EnvironmentPostProcessor.imports`）中注册。

### 2.3 占位符解析：`${}` 的坑

```yaml
app:
  host: api.example.com
  url: https://${app.host}/v1
  url2: https://${app.host:localhost}/v1   # 带默认值
  url3: https://${UNKNOWN_KEY:${app.host}}/v1  # 嵌套默认值
```

`PropertySourcesPlaceholderConfigurer`（或 Boot 的 `PropertySourcesPlaceholdersResolver`）在**绑定阶段**做解析。两个经典陷阱：

1. **占位符不能跨源引用比自己优先级高的值**，也**不能自引用**（同一个 key 引用自己会死循环或返回原串）。
2. **`@Value` 上占位符解析失败会启动失败**，但 `@ConfigurationProperties` 里如果是 `String` 类型会保留原串 `${...}`（不报错），排查更难。

### 2.4 Profile 的正确用法

```yaml
# application.yml
spring:
  profiles:
    active: ${DEPLOY_ENV:dev}
  config:
    import:
      - optional:classpath:common.yml
      - optional:nacos:${spring.application.name}.yaml
---
spring:
  config:
    activate:
      on-profile: dev
logging:
  level:
    root: info
---
spring:
  config:
    activate:
      on-profile: prod
logging:
  level:
    root: warn
```

三个要点：

- **`spring.config.import` 是配置中心的官方入口**（Boot 2.4+），`optional:` 前缀表示"不存在也不报错"——不加 `optional:` 时配置拉不到会**直接启动失败**，这反而是生产上想要的行为。
- **多文档块（`---`）里 `on-profile` 才生效**，别在老式 `spring.profiles` 里写多个值（Boot 2.4+ 已废弃该写法）。
- **profile 可以叠加**：`spring.profiles.active=prod,metrics`，后激活的优先级更高（同名 key 后者胜）。

---

## 三、工程实践：配置治理四件事

### 3.1 配置分层：让"环境差异"最小化

反面教材：每个环境一份完整配置，diff 出来几百行，改一个数据库地址要同步 3 个文件。

推荐分层：

```
application.yml            # 与环境无关的默认值（连接池大小、超时、业务开关默认值）
application-dev.yml        # 只写 dev 差异（本地地址、debug 日志）
application-test.yml
application-prod.yml       # 只写 prod 差异（集群地址、连接池放大）
```

原则：**能进默认值的都进 `application.yml`，profile 文件只放"确实不同"的项**。这样新增配置项时只改一处。

### 3.2 配置校验：启动即失败，别带病上线

```java
@ConfigurationProperties(prefix = "app.payment")
@Validated
public class PaymentProperties {

    @NotBlank(message = "支付网关地址不能为空")
    @Pattern(regexp = "^https?://.+", message = "支付网关必须是 http(s) URL")
    private String gateway;

    @NotNull
    @Positive
    private Duration timeout = Duration.ofSeconds(3);

    @Min(1) @Max(100)
    private int maxRetry = 3;

    @AssertTrue(message = "生产环境禁止开启 mock 模式")
    public boolean isMockAllowed() {
        return !"prod".equals(System.getProperty("deploy.env")) || !mock;
    }
    // getters/setters...
}
```

配 `@AssertTrue` 做**跨字段校验**（如"启用 A 时必须配置 B"），这是 `@NotNull` 做不到的。校验失败时 Boot 抛出 `BindValidationException`，启动直接失败——比运行到支付环节才发现配置错了强一百倍。

### 3.3 敏感配置：不要明文进 Git

三层防护：

1. **加密存储**：Jasypt 或配置中心自带加密（Nacos AES、Apollo 加密）；
2. **环境变量注入**：`SPRING_DATASOURCE_PASSWORD` 天然优先级高于配置文件；
3. **K8s Secret 挂载**：`spring.config.import=optional:configtree:/etc/app/secrets/`。

```yaml
spring:
  config:
    import: optional:configtree:/etc/app/secrets/
  datasource:
    password: ${db-password}   # 对应 /etc/app/secrets/db-password 文件内容
```

`configtree` 这个特性用的人不多但极其实用：目录下每个文件名就是 key，文件内容就是 value，配合 K8s Secret volume 天然适配，不用手动拼环境变量。

### 3.4 动态刷新：`@RefreshScope` 的边界

配置中心推送后，配置能刷新的前提是 **Bean 能被重建或字段能被重绑**。

```java
@RestController
@RefreshScope   // 刷新时销毁并重建该 Bean
public class FeatureController {
    @Value("${app.feature.new-ui:false}")
    private boolean newUi;
}
```

坑点清单：

| 坑 | 说明 | 解法 |
|---|---|---|
| `@ConfigurationProperties` 不自动刷新 | 除非配了 `@RefreshScope` 或用了 `ConfigurationPropertiesRebinder` | 加 `@RefreshScope` 或用 `Environment` 直读 |
| `@RefreshScope` 与单例依赖冲突 | 刷新后注入方仍持有旧引用 | 用 `ObjectProvider` 延迟获取 |
| 连接池/线程池参数不生效 | 已创建的连接不会因配置变化重建 | 需要自定义 `@EventListener(EnvironmentChangeEvent)` 重建 |
| 刷新时序 | 多个 Bean 刷新非原子，可能读到半新半旧 | 关键配置放同一前缀，一次性刷新 |

```java
@Component
@Slf4j
public class PoolRebuilder {

    @EventListener
    public void onEnvChange(EnvironmentChangeEvent event) {
        if (event.getKeys().stream().anyMatch(k -> k.startsWith("app.pool."))) {
            log.warn("连接池配置变更，开始重建: {}", event.getKeys());
            dataSourceRebuilder.rebuild();
        }
    }
}
```

---

## 四、排查手册：配置不生效的 6 个根因

按命中率排序：

**① 优先级更高的源覆盖了它。**
排查：`curl /actuator/env/app.foo`，看 `propertySources` 数组里谁在最前、`value` 是多少。

**② 环境变量名转换规则搞错了。**
`app.llm.api-key` 对应的环境变量是 `APP_LLM_APIKEY`（**不是** `APP_LLM_API_KEY`）。规则：转大写 + `.` 和 `-` 都删掉。这个坑在 Docker/K8s 里极其常见。

```bash
# 验证
SPRING_APPLICATION_JSON='{"app":{"llm":{"api-key":"x"}}}' java -jar app.jar
```

**③ profile 没激活，读的是默认文件。**
排查：启动日志搜 `The following 1 profile is active`，或 `/actuator/env` 看 `activeProfiles`。

**④ `@PropertySource` 加载的文件被 config data 覆盖。**
见 2.2 的说明，改用 `EnvironmentPostProcessor`。

**⑤ 占位符拼写/嵌套错误。**
`${app.host}` 写成 `${app_host}`，或者写成 `$app.host`（少了大括号），后者不会被解析，原样输出。

**⑥ 配置文件根本没被加载到。**
`spring.config.location` 一旦显式指定，**默认位置全部失效**（不是追加）。要追加必须用 `spring.config.additional-location`。这个区别踩过的人非常多。

```bash
# 只读这个目录，classpath 下的 application.yml 不再加载
java -jar app.jar --spring.config.location=file:/etc/app/
# 额外追加，默认位置仍生效
java -jar app.jar --spring.config.additional-location=file:/etc/app/
```

---

## 五、面试高频追问

**Q1：`application.yml` 和 `bootstrap.yml` 有什么区别？**

`bootstrap.yml` 是 Spring Cloud 早期（`bootstrap` 上下文）的机制，用于在**主上下文创建前**加载配置中心信息（因为连 Nacos 需要先知道地址）。Boot 2.4+ 和 Spring Cloud 2020+ 已废弃 bootstrap 上下文，改用 `spring.config.import=nacos:...`。新项目不要再引入 `spring-cloud-starter-bootstrap`。

**Q2：`Environment` 和 `@Value` 的关系？**

`@Value` 的解析由 `AutowiredAnnotationBeanPostProcessor` 配合 `PropertySourcesPlaceholderConfigurer` 完成，最终查的就是 `Environment` 里的 `PropertySources`。所以 `Environment` 是数据源，`@Value` 只是语法糖。

**Q3：为什么 `@ConfigurationProperties` 支持松散绑定而 `@Value` 不支持？**

`@ConfigurationProperties` 走 `Binder`，内部用 `ConfigurationPropertyName` 做规范化（忽略大小写、`-`、`_`），所以 `app.llm.api-key`、`app.llm.apiKey`、`APP_LLM_APIKEY` 都能绑。`@Value` 是纯字符串占位符解析，必须精确匹配 key。

**Q4：配置能注入到静态字段吗？**

不能。静态字段在类初始化时赋值，早于 Spring 的依赖注入。常见变通：`@PostConstruct` 里赋值给静态变量，或用 setter 注入，或干脆改成实例字段。

**Q5：多模块项目里，子模块的 `application.yml` 会被加载吗？**

不会。只有 **classpath 根目录 / config 目录**下的 `application.yml` 会被加载。多个 jar 都有 `application.yml` 时，**只有一个会生效**（取决于 classpath 顺序，通常是先加载的胜出/或者报错）。正确做法：子模块用 `@PropertySource` 或独立的 `xxx.properties` + `spring.config.import`。

**Q6：如何在不重启的情况下验证配置是否被正确读取？**

Spring Boot 3 可以开 `management.endpoint.env.show-values=always`（2.x 是 `management.endpoint.env.enabled=true`），然后 `GET /actuator/env/{key}` 拿到命中源和覆盖链；或者写一个 `ApplicationRunner` 启动时打印关键配置的 `OriginLookup` 结果。

---

## 六、总结

一句话记住 Spring Boot 配置的本质：**有序的 `PropertySource` 列表 + 第一个命中即返回**。

三个必须内化的结论：

1. **优先级不是"配置文件 > 代码"，而是"外部化 > 内部"**。命令行、环境变量、配置中心永远赢过打死的 jar 内配置——这正是云原生"同一镜像多环境部署"的基础。
2. **`@PropertySource` 优先级低于 config data**，需要高优先级必须用 `EnvironmentPostProcessor`。
3. **配置要校验、要能追溯、要能刷新**。生产的配置治理水平，直接决定了故障的平均恢复时间。

配置问题之所以难查，是因为它是"静默失败"——不报错、不告警，只是行为不对。把这张优先级表背下来、把 `/actuator/env` 用熟，你就能把这类问题的定位时间从两小时压到两分钟。
