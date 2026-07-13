---
title: 【Spring Boot 实战】Spring Boot Admin 服务监控与管理平台深度实战
date: 2026-07-13 08:00:00
tags:
  - Java
  - Spring Boot
  - 监控
  - SBA
categories:
  - Spring Boot
  - 运维监控
author: 东哥
---

# 【Spring Boot 实战】Spring Boot Admin 服务监控与管理平台深度实战

## 一、为什么需要 Spring Boot Admin？

Spring Boot Actuator 为我们暴露了大量端点（/health、/metrics、/info、/env 等），但有一个现实问题：**当你有十几个甚至几十个微服务时，难道一个个手动访问它们的 Actuator 端点吗？**

这就是 Spring Boot Admin（以下简称 SBA）的用武之地——它把散落在各个微服务实例中的 Actuator 端点统一聚合到一个管理控制台，并提供可视化界面、告警通知、日志查看等功能。

### 管理数十个微服务的痛点

| 痛点 | 传统方案 | SBA 方案 |
|------|---------|---------|
| 查看服务在线状态 | SSH 到服务器 curl 每个实例 | 一目了然的状态面板 |
| 检查健康情况 | 逐个访问 /actuator/health | 汇总展示，异常标红 |
| 查看 JVM 指标 | 构建监控大屏（Prometheus+Grafana） | 开箱即用的 JVM 图表 |
| 动态调整日志级别 | 修改配置后重启服务 | 在线修改，实时生效 |
| 查看环境配置 | 访问 /actuator/env 逐个翻 | 集中查看和搜索 |

## 二、架构设计

SBA 采用 **C/S 架构**：

- **SBA Server**：一个独立的 Spring Boot 应用，聚合展示所有注册客户端的监控信息
- **SBA Client**：在每个微服务中引入依赖，注册到 SBA Server

注册方式有两种：

| 方式 | 说明 | 适用场景 |
|------|------|---------|
| **HTTP 注册** | Client 启动时向 Server 的 /api/applications 发送注册请求 | 非 Spring Cloud 项目、简单部署 |
| **服务发现注册** | 通过 Eureka/Nacos/Consul 等服务发现组件自动发现 | Spring Cloud 微服务架构 |

## 三、Server 端搭建

### 3.1 创建 SBA Server 项目

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.0</version>
</parent>

<dependencies>
    <dependency>
        <groupId>de.codecentric</groupId>
        <artifactId>spring-boot-admin-starter-server</artifactId>
        <version>3.3.3</version>
    </dependency>
    <!-- Web 依赖 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <!-- 安全认证 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-security</artifactId>
    </dependency>
</dependencies>
```

### 3.2 启动类与配置

```java
@SpringBootApplication
@EnableAdminServer
public class AdminServerApplication {
    public static void main(String[] args) {
        SpringApplication.run(AdminServerApplication.class, args);
    }
}
```

```yaml
# application.yml
server:
  port: 9090

spring:
  application:
    name: admin-server
  security:
    user:
      name: admin
      password: admin123
  boot:
    admin:
      # 通知配置（后面会详细讲）
      notify:
        mail:
          enabled: true
          to: ops@example.com
          from: admin@example.com
```

### 3.3 安全配置

```java
@Configuration
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/**", "/instances/**", "/api/**").authenticated()
                .anyRequest().authenticated()
            )
            .formLogin(login -> login.loginPage("/login").permitAll())
            .logout(logout -> logout.permitAll())
            .httpBasic(withDefaults())  // Client 注册用 Basic Auth
            .csrf(csrf -> csrf.disable());  // 简化开发
        return http.build();
    }
}
```

## 四、Client 端集成

### 4.1 引入依赖

```xml
<dependency>
    <groupId>de.codecentric</groupId>
    <artifactId>spring-boot-admin-starter-client</artifactId>
    <version>3.3.3</version>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

### 4.2 客户端配置

```yaml
spring:
  application:
    name: user-service
  boot:
    admin:
      client:
        url: http://admin-server:9090  # SBA Server 地址
        username: admin                # Server 访问凭据
        password: admin123
        instance:
          # 客户端自己的地址（用于 Server 反向调用客户端 Actuator）
          service-host-type: IP
          prefer-ip: true

# 暴露所有 Actuator 端点供 SBA 采集
management:
  endpoints:
    web:
      exposure:
        include: "*"
  endpoint:
    health:
      show-details: always
    env:
      show-values: always  # Spring Boot 3.x 需要显式开启
```

### 4.3 自定义健康指示器

SBA 的健康面板会汇总所有 HealthIndicator 的信息。自定义指示器非常简单：

```java
@Component
public class DatabaseHealthIndicator implements HealthIndicator {

    @Override
    public Health health() {
        // 模拟检查数据库连接
        boolean dbAlive = checkDatabaseConnection();
        if (dbAlive) {
            return Health.up()
                .withDetail("database", "MySQL 8.0")
                .withDetail("connectionPool", "active: 5, idle: 3")
                .withDetail("latency", "3ms")
                .build();
        }
        return Health.down()
            .withDetail("error", "Cannot connect to database")
            .build();
    }

    private boolean checkDatabaseConnection() {
        // 实际检查逻辑...
        return true;
    }
}
```

## 五、核心功能详解

### 5.1 服务状态监控

SBA 控制台对每个注册的服务实例展示：

- **状态**：UP / DOWN / OFFLINE / UNKNOWN，颜色区分（绿/红/灰/黄）
- **元数据**：服务名、IP 地址、端口号、启动时间
- **健康详情**：各维度健康指标（磁盘、数据库、内存等）
- **JVM 信息**：堆内存、非堆内存、GC 频率、线程数、类加载数
- **HTTP 跟踪**：最近请求的 Trace 信息

### 5.2 日志级别在线调整

这是 SBA 最实用的功能之一——不需要修改配置文件、不需要重启服务，直接在生产环境动态调整日志级别：

![日志级别管理](https://via.placeholder.com/800x400?text=Log-Level-Management)

操作路径：选择服务实例 → Loggers → 搜索包名 → 修改日志级别（TRACE / DEBUG / INFO / WARN / ERROR）

**底层原理**：SBA 调用客户端 `/actuator/loggers/{packageName}` 端点的 POST 方法，设置 `configuredLevel` 字段。Spring Boot 的 LoggingSystem 会立即应用新级别。

```java
// 后台等价操作（Spring 源码层面）
@RestController
@RequestMapping("/actuator")
public class LoggersEndpoint {
    @PostMapping("/loggers/{name}")
    public void configureLogLevel(@PathVariable String name,
            @RequestBody LogLevelConfig config) {
        LoggingSystem loggingSystem = LoggingSystem.get(classLoader);
        loggingSystem.setLogLevel(name, config.getConfiguredLevel());
    }
}
```

> ⚠️ **生产注意事项**：调整 DEBUG 级别可能产生大量日志，操作后记得恢复。建议结合告警通知，长期开启 DEBUG 的实例需要人工确认。

### 5.3 环境属性查看

可以在 SBA 界面直接搜索和查看所有 `application.yml` 中的配置项及其来源（哪些被覆盖了、哪些来自远程配置中心）。典型的调试场景：

- 确认某个配置项是否生效
- 对比不同实例的配置差异
- 检查配置来源优先级（命令行 > 环境变量 > 外部配置 > application.yml）

### 5.4 堆转储（Heap Dump）在线下载

当服务出现 OOM 或内存异常时，可以直接从 SBA 界面下载 Heap Dump：

- 选择实例 → Heap Dump → 触发下载
- 生成的 .hprof 文件可以用 MAT、VisualVM 分析
- **注意**：触发 Heap Dump 时应用会暂停（Stop-The-World），大堆（>8GB）可能暂停几十秒

### 5.5 线程转储（Thread Dump）在线查看

在线查看所有线程状态，快速定位死锁、死循环、线程阻塞问题：

```
"http-nio-8080-exec-7" #26 daemon prio=5 os_prio=0 cpu=12.34ms
   java.lang.Thread.State: BLOCKED
        at com.example.service.OrderService.createOrder(OrderService.java:45)
        - waiting to lock <0x000000076b5a3a30> (a java.util.concurrent.locks.ReentrantLock$NonfairSync)
        at com.example.controller.OrderController.createOrder(OrderController.java:22)
```

上面的信息一目了然：某个线程在等待 ReentrantLock，附近很可能有锁竞争或死锁问题。

## 六、告警通知配置

SBA 支持丰富的告警通知渠道，当一个服务状态从 UP 变为 DOWN（或反之），可以自动通知：

### 6.1 邮件通知

```yaml
spring:
  boot:
    admin:
      notify:
        mail:
          enabled: true
          to: ops@example.com
          cc: dev-lead@example.com
          from: sba@example.com
          # 自定义触发条件
          on-status-change: true
          on-registered: false
          on-unregistered: true
          ignore-changes: ["UNKNOWN:UP"]  # 忽略某些状态变更

spring:
  mail:
    host: smtp.example.com
    port: 587
    username: sba@example.com
    password: email-password
    properties:
      mail.smtp.auth: true
      mail.smtp.starttls.enable: true
```

### 6.2 钉钉/企业微信通知（自定义通知实现）

```java
@Component
public class DingTalkNotifier extends AbstractStatusChangeNotifier {

    private final RestClient restClient;

    public DingTalkNotifier(RestClient.Builder builder) {
        this.restClient = builder.build();
    }

    @Override
    protected Mono<Void> doNotify(ClientApplicationEvent event) {
        String text = String.format(
            "🔥 服务告警\n服务：%s\n实例：%s:%s\n状态变更：%s → %s\n时间：%s",
            event.getApplication().getName(),
            event.getInstance().getRegistration().getHost(),
            event.getInstance().getRegistration().getPort(),
            event.getFrom(), event.getTo(),
            event.getTimestamp()
        );

        return Mono.fromRunnable(() -> {
            Map<String, Object> body = new HashMap<>();
            body.put("msgtype", "text");
            body.put("text", Map.of("content", text));

            restClient.post()
                .uri("https://oapi.dingtalk.com/robot/send?access_token=xxx")
                .body(body)
                .retrieve()
                .toBodilessEntity()
                .block();
        });
    }
}
```

### 6.3 通知去重与抑制

```yaml
spring:
  boot:
    admin:
      notify:
        reminder:
          enabled: true
          period: PT10m  # 服务持续异常时，每10分钟重发一次告警
        filter:
          enabled: true
          durability: 10000  # 抑制10秒内的重复通知
```

## 七、SBA 与 Spring Cloud 集成

### 7.1 通过 Nacos 服务发现自动注册

如果项目使用了 Spring Cloud Alibaba Nacos，可以让 SBA 通过 Nacos 自动发现所有微服务：

```xml
<!-- SBA Server 额外依赖 -->
<dependency>
    <groupId>de.codecentric</groupId>
    <artifactId>spring-boot-admin-starter-server</artifactId>
</dependency>
<!-- 服务发现支持 -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

```yaml
spring:
  cloud:
    nacos:
      discovery:
        server-addr: nacos:8848
  boot:
    admin:
      discovery:
        enabled: true
        # 只扫描包含以下元数据的服务
        filter:
          - metadata.sba-enabled=true
        # 忽略一些基础设施服务
        ignored-services: admin-server,nacos,gateway
```

此时，Client 端只需要注册到 Nacos，不需要在配置中写 SBA Server 地址。

### 7.2 通过 Eureka 自动发现

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-netflix-eureka-client</artifactId>
</dependency>
```

```yaml
spring:
  boot:
    admin:
      discovery:
        enabled: true
        # Eureka 下的路径转换
        converter:
          management-context-path: /actuator  # 指定 Actuator 路径
```

## 八、生产环境最佳实践

### 8.1 SBA Server 的持久化

SBA Server 的内存中保存了所有实例的快照，重启会丢失历史状态。生产环境中建议启用存储后端：

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
</dependency>
<dependency>
    <groupId>com.mysql</groupId>
    <artifactId>mysql-connector-j</artifactId>
</dependency>
```

```yaml
spring:
  datasource:
    url: jdbc:mysql://mysql-host:3306/admin_server?useSSL=false
    username: root
    password: password
  jpa:
    hibernate:
      ddl-auto: update
```

### 8.2 安全加固

| 风险 | 加固措施 |
|------|---------|
| 未授权访问 | 集成 Spring Security + 强密码 / OAuth2 |
| 敏感信息泄露 | 禁用 /actuator/env 或使用 `show-values: never` |
| 日志泄露 | 控制暴露的敏感字段，日志脱敏 |
| 内网穿透 | SBA 不应暴露到公网，通过 VPN 访问 |

### 8.3 性能考虑

- SBA Server 建议独立部署，不和业务服务混部
- 单个 SBA Server 可管理 100-200 个实例，超出建议分环境部署
- 采集指标间隔可调整：

```yaml
spring:
  boot:
    admin:
      monitor:
        # 默认 10s 检查一次心跳，生产可调大到 30s
        period: 30000
        status-lifetime: 30000  # 状态缓存时间
        read-timeout: 10000
```

## 九、与 Prometheus + Grafana 的定位差异

| 维度 | SBA | Prometheus + Grafana |
|------|-----|---------------------|
| **定位** | Spring Boot 应用级管理 | 基础设施 + 应用级监控 |
| **易用性** | 开箱即用，零配置面板 | 需要手动配置面板 |
| **告警** | 内置通知能力 | 需要 AlertManager |
| **存储** | 无长期存储（仅当前状态） | 支持长期趋势存储 |
| **管理功能** | 日志级别、Heap Dump 等 | 无管理功能 |
| **数据粒度** | 单实例维度 | 聚合 + 维度下钻 |
| **适用场景** | 开发/测试环境、小规模集群 | 大规模生产环境、长期趋势分析 |

**最佳实践**：SBA 用作**日常运维管理平台**，Prometheus + Grafana 用作**长期监控告警体系**，两者互补，不冲突。

## 十、面试常见追问

### Q1：SBA 如何获取客户端的指标数据？

SBA Server 通过 HTTP 轮询方式访问客户端的 Actuator 端点：
- `/actuator/health`：获取健康状态
- `/actuator/metrics`：获取 JVM 指标
- `/actuator/loggers`：获取日志级别
- `/actuator/heapdump`：获取堆转储

这些调用是 Server 主动发起的，不是 Client 推送的。

### Q2：SBA 发现客户端状态变更的时效性如何？

默认每 10 秒检查一次客户端健康状态。如果有服务挂掉，最差情况延迟 10 秒才能感知到。如果服务正常启动并注册，SBA 会在下一个检查周期发现。

### Q3：SBA 能否监控非 Spring Boot 应用？

不能直接监控非 Spring Boot 应用。但可以通过暴露自定义 HTTP Endpoint（仿照 Actuator 格式）来间接实现，或者通过 Sidecar 模式。

---

SBA 是一个非常实用的 Spring Boot 生态组件，尤其适合中小团队——不需要搭一整套 Prometheus 体系就能获得可视化的监控面板。当你面对十几个微服务焦头烂额地 SSH 登录一台台服务器检查状态时，花半天时间搭一个 SBA 将是今年最有价值的投入。
