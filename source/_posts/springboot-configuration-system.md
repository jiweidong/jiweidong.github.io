---
title: Spring Boot 配置体系与加载优先级
date: 2026-06-20 08:00:00
author: 东哥
categories:
  - Spring框架
tags:
  - Spring
  - SpringBoot
  - 配置管理
  - @ConfigurationProperties
  - Profile
---

## 前言

Spring Boot 的配置体系非常强大——支持 properties、YAML、环境变量、命令行参数等多种配置源，且具有明确的优先级规则。

但面对 "配置不生效"、"属性被覆盖" 等问题时，不了解加载顺序就无从下手。本文帮你理清整个配置体系的脉络。

---

## 一、配置源概览

Spring Boot 的配置按优先级从高到低排列：

```
1.  命令行参数（--server.port=8081）
2.  JNDI 属性（java:comp/env）
3.  系统属性（System.getProperties()）
4.  OS 环境变量
5.  随机值属性（random.*）
6.  Profile 特定配置文件（application-{profile}.yml）
7.  应用程序配置文件（application.yml/properties）
8.  @PropertySource 注解
9.  默认属性（SpringApplication.setDefaultProperties）
```

**关键原则**：高优先级的配置会覆盖低优先级的配置。

---

## 二、配置文件加载细节

### 2.1 默认加载位置

Spring Boot 按以下顺序搜索 `application.yml`，找到即停（后面的不再读取）：

```
1. file:./config/          ← 当前目录下的 config 目录
2. file:./config/*/        ← 当前目录下 config 的子目录
3. file:./                 ← 当前目录
4. classpath:/config/      ← classpath 下的 config 目录
5. classpath:/             ← classpath 根目录
```

所以 **外部配置优先于内部配置**，方便部署时覆盖 jar 包内的默认值。

### 2.2 Profile 特定文件

激活特定 profile 时，Spring Boot 会加载 `application-{profile}.yml`，且其优先级 **高于** 默认的 `application.yml`。

```yaml
# application.yml（默认配置）
server:
  port: 8080

# application-dev.yml（开发环境）
server:
  port: 8081

# application-prod.yml（生产环境）
server:
  port: 8080
```

激活方式：

```bash
# 命令行
java -jar app.jar --spring.profiles.active=dev

# 环境变量
export SPRING_PROFILES_ACTIVE=dev

# application.yml 中指定（兜底方案）
spring:
  profiles:
    active: dev
```

### 2.3 YAML 多文档块

一个 YAML 文件内可以用 `---` 分割多个 profile：

```yaml
spring:
  application:
    name: my-app

---
spring:
  config:
    activate:
      on-profile: dev
server:
  port: 8081

---
spring:
  config:
    activate:
      on-profile: prod
server:
  port: 80
```

> **注意**：Spring Boot 2.4+ 推荐 `spring.config.activate.on-profile` 替代 `spring.profiles`。

---

## 三、配置绑定方式

### 3.1 @Value（简单绑定）

```java
@Component
public class AppConfig {
    @Value("${app.name:default-app}")    // 带默认值
    private String appName;

    @Value("#{systemProperties['user.dir']}")  // SpEL 表达式
    private String userDir;

    @Value("${app.timeout:5000}")
    private int timeout;
}
```

**局限**：不支持复杂对象绑定，不适合批量属性。

### 3.2 @ConfigurationProperties（推荐）

```java
@Component
@ConfigurationProperties(prefix = "app.datasource")
public class DatasourceProperties {
    private String url;
    private String username;
    private String password;
    private Pool pool = new Pool();  // 嵌套对象

    // getters / setters ...

    public static class Pool {
        private int maxActive = 10;
        private int minIdle = 2;

        // getters / setters ...
    }
}
```

对应的配置：

```yaml
app:
  datasource:
    url: jdbc:mysql://localhost:3306/db
    username: root
    password: 123456
    pool:
      max-active: 20
      min-idle: 5
```

**启用 ConfigurationProperties 的方式**：

方式 1：`@Component` + `@ConfigurationProperties`（自动注册）

方式 2：`@EnableConfigurationProperties(XXXProperties.class)` 显式注册

方式 3：`@ConfigurationPropertiesScan`（Spring Boot 2.2+）

### 3.3 @ConfigurationProperties 与 @Value 对比

| 特性 | @Value | @ConfigurationProperties |
|------|--------|-------------------------|
| 批量绑定 | 逐字段声明 | 自动批量映射 |
| 复杂对象 | 不支持嵌套对象 | 支持嵌套、List、Map |
| 校验 | 不支持 | 支持 `@Validated` + JSR-303 |
| 松散绑定 | 不支持 | 支持（如 my-prop = myProp） |
| SpEL | 支持 | 不支持 |
| 元数据 | 不支持 | 支持 IDE 自动提示 |

### 3.4 类型安全的校验

```java
@Component
@ConfigurationProperties(prefix = "app.db")
@Validated
public class DatabaseProperties {
    @NotBlank
    private String url;

    @Min(1)
    @Max(65535)
    private int port = 3306;

    @NotNull
    private Credentials credentials;

    // getters / setters ...
}
```

---

## 四、配置的松散绑定（Relaxed Binding）

Spring Boot 对 `@ConfigurationProperties` 的 key 和 environment property 之间做了宽松匹配，以下写法等价：

| Property | 环境变量 | 说明 |
|----------|---------|------|
| `app.my-prop` | `APP_MY_PROP` | 连字符 = 下划线 |
| `app.myProp` | `APP_MY_PROP` | 驼峰 = 下划线 |
| `app.my_prop` | `APP_MY_PROP` | 下划线 = 下划线 |
| `APP_MYPROP` | 同上 | 不分大小写 |

**注意**：`@Value` 不支持松散绑定，key 必须精确匹配。

---

## 五、外部化配置实践

### 5.1 随机属性

```yaml
my:
  secret: ${random.value}           # 随机字符串
  number: ${random.int}             # 随机 int
  big-number: ${random.long}        # 随机 long
  uuid: ${random.uuid}              # 随机 UUID
  range: ${random.int[1,100]}       # 1~100 随机整数
```

### 5.2 占位符引用

```yaml
app:
  name: MyApp
  description: ${app.name} is a Spring Boot application
```

### 5.3 多环境配置策略

**推荐方案**：一个 `application.yml` + 各 profile 覆盖特定属性

```yaml
# application.yml — 公共配置
spring:
  application:
    name: order-service

server:
  port: 8080

logging:
  level:
    root: INFO

---
spring:
  config:
    activate:
      on-profile: dev

server:
  port: 8081

logging:
  level:
    root: DEBUG
```

也可以保持独立文件 `application-dev.yml`、`application-prod.yml`。

---

## 六、配置优先级常见陷阱

### 6.1 命令行参数 vs 配置文件

```bash
java -jar app.jar --server.port=8081
```

命令行参数优先级 **最高**，会覆盖 application.yml 中的配置。

### 6.2 环境变量的优先级

环境变量名需要大写 + 下划线格式：

```bash
export SERVER_PORT=8082
export SPRING_DATASOURCE_URL=jdbc:mysql://...
```

环境变量优先级仅次于系统属性和命令行参数。

### 6.3 @PropertySource 的局限性

```java
@Configuration
@PropertySource("classpath:custom.properties")
public class CustomConfig {
    // ...
}
```

`@PropertySource` 加载的配置优先级 **低于** application.yml，且 **不能** 与 `@ConfigurationProperties` 配合用于松散绑定。

如果需要自定义配置源且优先级更高，可通过 `EnvironmentPostProcessor` 实现。

### 6.4 List 和 Map 的覆盖行为

```yaml
# application.yml
app:
  hosts:
    - host1.com
    - host2.com
```

```yaml
# application-prod.yml
app:
  hosts:
    - prod1.com
```

**注意**：prod profile 中 hosts 会 **完全替换** 默认配置，而不是追加。这是一种 "对象级别" 的覆盖。

---

## 七、配置加载过程源码简述

`Environment` 的加载在 `prepareEnvironment` 阶段完成。关键流程：

```java
// 1. 创建 StandardServletEnvironment
ConfigurableEnvironment environment = createEnvironment();

// 2. 添加配置源配置器
configureEnvironment(environment, applicationArguments.getSourceArgs());

// 3. 应用 PropertySource 顺序（逆行）
//    确保命令行参数等优先级正确
//    通过 MutablePropertySources 的 addFirst/addLast 控制
environment.getPropertySources()
    .addFirst(new CommandLinePropertySource<>(args));
```

`MutablePropertySources` 是一个有序列表，越靠前的优先级越高。

```java
// MutablePropertySources 内部结构（从高到低）
[
  commandLineArgs,          // 命令行参数
  servletConfigInitParams,  // ServletConfig 参数
  servletContextInitParams, // ServletContext 参数
  systemProperties,         // JVM 系统属性
  systemEnvironment,        // OS 环境变量
  random,                   // random.* 值
  application-prod.yml,     // Profile 特定配置
  application.yml,          // 主配置文件
  ...
]
```

---

## 八、最佳实践总结

### 推荐的做法

1. **优先使用 `@ConfigurationProperties`**，而不是 @Value，便于维护和校验
2. **使用 `application.yml` 收集公共配置**，profile 文件只放差异项
3. **外部配置优于内部打包**：使用 `--spring.config.additional-location` 扩展配置目录
4. **敏感信息绝不写死在代码里**：结合 Vault / 配置中心 / K8s Secret 做外部化
5. **为自定义属性生成元数据**：添加 `spring-configuration-metadata.json`，IDE 会自动提示

### 不推荐的做法

- 一个配置类塞太多属性（按业务拆分）
- 在代码里 hardcode 环境判断（用 profile 替代）
- 不同环境使用不同配置格式（统一用 YAML）
- 配置文件里写逻辑（YAML 不是编程语言）

---

## 总结

配置是应用的骨架，理解 Spring Boot 的配置体系相当于掌握了应用的"变形能力"：

- **开发环境** → 覆盖成 dev 配置
- **生产部署** → 通过环境变量/命令行调整
- **临时调试** → 改配置文件即刻生效

优先级规则记清楚，绝大多数配置问题都能一眼定位。
