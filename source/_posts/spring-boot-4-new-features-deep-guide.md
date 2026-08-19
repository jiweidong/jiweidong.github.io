---
title: 【2026 重磅】Spring Boot 4.0 新特性深度解析与迁移实战指南
date: 2026-08-19 08:00:00
tags:
  - Spring Boot
  - Spring Framework
  - 迁移
categories:
  - Java
  - Spring 全家桶
author: 东哥
---

# 【2026 重磅】Spring Boot 4.0 新特性深度解析与迁移实战指南

## 引言：时隔三年的大版本

Spring Boot 4.0 于 2025 年 11 月正式发布（GA），这是自 3.0（2022 年 11 月）以来**时隔三年的大版本升级**。它基于全新的 **Spring Framework 7.0**，是"模块化重构 + 技术栈现代化"的一次深度进化，而不是简单加几个注解的事。

> ⚠️ 本文基于 2026 年 8 月的最新稳定版信息撰写（4.0.x），核心内容同样适用于后续 4.1/4.2 小版本。

先看升级全景：

| 技术点 | Spring Boot 3.x | Spring Boot 4.0 |
|--------|----------------|-----------------|
| 基础框架 | Spring Framework 6.x | **Spring Framework 7.0** |
| Java 基线 | Java 17 | **Java 17+（支持到 Java 25）** |
| Jakarta EE | Jakarta EE 10 | **Jakarta EE 11** |
| Servlet 容器 | Tomcat 10.1 | **Tomcat 11（Servlet 6.1）** |
| Spring Security | 6.x | **7.0** |
| Micrometer | 1.13 | **1.16** |
| 自动配置注册 | AutoConfiguration.imports + spring.factories（遗留） | **仅 AutoConfiguration.imports** |
| 测试注解 | @MockBean / @SpyBean | **@MockitoBean / @MockitoSpyBean** |

---

## 一、七个必须知道的重大变化

### 1.1 模块化重构：从"大而全"到"按需取用"

这是 Boot 4 **架构上最深刻的改变**。以往 `spring-boot-starter-web` 一坨全给你，现在核心模块被拆分：

| 新模块 | 职责 |
|--------|------|
| `spring-boot-http` | 统一的 HTTP 客户端/服务端抽象（不分 WebFlux/MVC 的技术底座） |
| `spring-boot-web-server` | 内嵌 Web 服务器（Tomcat/Jetty/Undertow）的启动与配置 |
| `spring-boot-web-client` | HTTP 客户端（RestClient/RestTemplate/WebClient）的自动配置 |
| `spring-boot-conditions` | 所有 `@ConditionalOn*` 条件注解（从 core 中拆出） |
| `spring-boot-jpa` | JPA 相关自动配置（Hibernate、DataSource 集成） |

`spring-boot-starter-web` 等 starter **仍然保留**（作为聚合入口），但对"只想要 HTTP 客户端"的场景，现在可以只依赖 `spring-boot-web-client`，**依赖体积和启动时间都更小**。

### 1.2 Java 17 基线 + 支持 Java 25

- 最低要求 **Java 17**（与 Boot 3 一致），但官方已在 Java 25（2025 年 9 月发布）上完成完整测试
- Spring Framework 7 利用现代 Java 特性重写了部分核心（更友好的虚拟线程支持、更强的模式匹配应用）
- **虚拟线程（Virtual Threads）在 Boot 4 中成为一等公民**：`spring.threads.virtual.enabled=true` 对 Tomcat、RestClient、JDBC 等全面生效，配合 Java 21+ 可将高 IO 应用吞吐提升数倍

### 1.3 自动配置注册机制收口

`META-INF/spring.factories` 中的自动配置声明**被彻底移除**，只认 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`。

- Boot 2.7 起就标记废弃，Boot 4 直接删除
- 对自定义 Starter 作者：检查你的 `spring.factories` 是否残留，**必须迁移到 AutoConfiguration.imports**，否则自定义自动配置静默失效（这是升级后最常见的"隐形故障"）

### 1.4 测试体系重构：@MockBean 退役

- `@MockBean` / `@SpyBean` 被移除，替换为 **`@MockitoBean` / `@MockitoSpyBean`**（3.4 引入的替代品）
- `spring-boot-starter-test` 拆分为两个：
  - `spring-boot-starter-test`：仅 JUnit 5（测试框架）
  - `spring-boot-starter-test-tooling`：Mockito、AssertJ、JSONassert、Awaitility（断言与 mock 工具）
- 影响：升级后 `@MockBean` 相关代码编译直接报错，替换为 `@MockitoBean` 即可；团队可以按需裁剪测试依赖

### 1.5 Spring Security 7：授权 API 全面统一

- `authorizeHttpRequests` DSL 成为唯一授权方式（`authorizeRequests` 早已移除）
- 方法级安全：`@EnableMethodSecurity` 与 URL 授权模型完全对齐，`AuthorizationManager` 统一所有授权决策
- 新增/强化的便捷 API：`securityMatcher` 声明式匹配、更严格的默认会话策略
- 从 6.x 迁移基本是平滑的（主要破坏性变更集中在 5→6 已发生）

### 1.6 可观测性：结构化日志与 OTLP 深化

- **结构化日志（Structured Logging）** 全面可用：`logging.structured.format.ecs` / `logstash` / `gelf`，JSON 格式日志与日志采集管道（ELK/Loki）无缝对接
- Micrometer 1.16 + Micrometer Tracing 1.6：与 OpenTelemetry 的集成更深入，`spring-boot-starter-otel` 类新 starter 让 APM 接入一行配置
- 生产排障体验：结构化日志 + 链路 ID 自动注入，定位问题不再靠 grep 正则

### 1.7 优雅停机成为默认

- 内嵌服务器**默认开启优雅停机（Graceful Shutdown）**，不再需要手动 `server.shutdown=graceful`
- 停机时先停止接收新请求，等待在途请求处理完（可配 `spring.lifecycle.timeout-per-shutdown-phase`），再销毁容器
- 配合 K8s `preStop` + readiness 探针，滚动发布"零抖动"成为标配能力

---

## 二、Spring Framework 7 的底层变化（面试加分项）

Boot 4 的所有变化，底层都来自 Spring Framework 7.0。几个关键点：

### 2.1 Spring MVC 模块拆分

`spring-webmvc` 拆成 `spring-webmvc-core`、`spring-webmvc-view`、`spring-webmvc-websocket`。只做 REST API 的项目可以不引入视图模块，依赖更轻。

### 2.2 大量 API 清理

Framework 7 清除了积压多年的废弃 API（`@Deprecated` 超过 2 个版本的一律删除）：

- `HandlerInterceptorAdapter`、`WebMvcConfigurerAdapter` 等"适配器基类"彻底告别，全部使用接口默认方法
- `RestTemplate` 的旧 API 收敛（新代码推荐 `RestClient`）
- 迁移时编译错误即为"清单"，逐个替换即可，不要用 `-parameters` 之类的方式绕过

### 2.3 HTTP 抽象统一

Framework 7 引入了更统一的 HTTP 客户端/服务端编程模型（`spring-http`），`spring-boot-http` 模块基于它提供自动配置——**未来编写"同时跑在 Servlet 和 Reactive 上的 HTTP 代码"会更容易**。

---

## 三、升级实战：从 3.x 到 4.0 迁移指南

### 3.1 升级清单（按顺序执行）

```bash
# 1. 修改 parent / BOM
# pom.xml: spring-boot-starter-parent 3.x → 4.0.x
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.0.3</version>
</parent>

# 2. JDK：确保构建机与运行时 Java ≥ 17（推荐 21/25）
# 3. 清理 spring.factories → AutoConfiguration.imports
# 4. 替换 @MockBean → @MockitoBean，@SpyBean → @MockitoSpyBean
# 5. 检查 Spring Security 配置（authorizeHttpRequests DSL）
# 6. 全量编译 → 修编译错误 → 跑测试 → 灰度发布
```

### 3.2 自定义 Starter 迁移（最常见的坑）

```java
// ❌ 旧：META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
com.example.starter.ExampleAutoConfiguration

// ✅ 新：META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
com.example.starter.ExampleAutoConfiguration
```

### 3.3 测试代码迁移示例

```java
// ❌ 3.x
@SpringBootTest
class OrderServiceTest {
    @MockBean
    private OrderRepository orderRepository;
}

// ✅ 4.0
@SpringBootTest
class OrderServiceTest {
    @MockitoBean
    private OrderRepository orderRepository;
}
```

### 3.4 升级决策树

- **新项目**：直接 Boot 4.0 + Java 21/25，一步到位
- **3.x 存量项目**：改动可控（编译错误清单化），建议在 **4.1 稳定后**再升，享受新特性
- **2.7 老项目**：先升 3.x 再升 4.0，**两步走**，不要跨大版本硬跳（2.7 的 spring.factories 机制在 4.0 已失效）

---

## 四、新特性实战：虚拟线程 + 结构化日志

### 4.1 一行开启虚拟线程

```yaml
spring:
  threads:
    virtual:
      enabled: true   # Tomcat/WebFlux 请求处理线程切换为虚拟线程
```

```java
@RestController
public class OrderController {

    // 高 IO 场景（查库、调远程）下虚拟线程收益最大
    @GetMapping("/orders/{id}")
    public Order getOrder(@PathVariable Long id) {
        return orderService.findById(id);   // 内部多次 IO 阻塞不再浪费平台线程
    }
}
```

实测经验（生产环境）：**IO 密集型服务**（网关、BFF、聚合查询）吞吐提升 2~5 倍；**CPU 密集型**（加解密、复杂计算）无收益甚至略降，谨慎开启。

### 4.2 结构化日志一行配置

```yaml
logging:
  structured:
    format:
      ecs: true    # Elastic Common Schema，ELK 直接解析
```

输出示例：

```json
{"@timestamp":"2026-08-19T08:00:00.123Z","log.level":"INFO","message":"订单创建成功","order.id":"10086","service.name":"order-app","trace.id":"abc123..."}
```

配合 `logging.pattern.level` 中的 `traceId/spanId` 占位符，日志→链路→指标全打通。

---

## 五、迁移常见问题排查（FAQ）

**Q1：升级后自定义自动配置全部失效？**
检查 `META-INF/spring.factories`——Boot 4 只读 `AutoConfiguration.imports`，迁移文件即可。同时确认 `@AutoConfiguration` 注解（替代 `@Configuration`）用法正确。

**Q2：@MockBean 编译报错？**
Boot 4 已移除，统一替换为 `@MockitoBean`（功能等价），并确保依赖 `spring-boot-starter-test-tooling` 或 `spring-boot-starter-test`（聚合）。

**Q3：Security 配置起不来？**
`authorizeRequests()` 已被 `authorizeHttpRequests()` 取代（5.x 起就废弃）；`WebSecurityConfigurerAdapter` 早已删除，改用 `SecurityFilterChain` Bean 声明式配置。

**Q4：Tomcat 11 / Servlet 6.1 有兼容问题吗？**
大部分三方库已适配 Jakarta EE 11；极少数老库（如旧的 JSP 标签库、老版 Shiro）可能不兼容，升级前用依赖树检查 `jakarta.servlet` 传递依赖版本。

**Q5：优雅停机默认开启，会影响发布速度吗？**
会略微延长停机窗口（默认等待在途请求完成，超时可配 `spring.lifecycle.timeout-per-shutdown-phase`），但换来零中断发布。K8s 场景务必配合 `terminationGracePeriodSeconds` 调大。

---

## 六、面试高频追问

**Q1：Spring Boot 4 最大的架构变化是什么？**
模块化重构：核心能力拆分为 `spring-boot-http`、`spring-boot-web-server`、`spring-boot-conditions`、`spring-boot-jpa` 等独立模块，starter 变成聚合入口，按需依赖、更轻更快。同时基于 Spring Framework 7，Java 基线 17、支持 25，Jakarta EE 11。

**Q2：@MockBean 为什么被移除？**
它深度耦合 Spring 测试上下文，且与 Mockito 新特性（严格存根等）配合不好。`@MockitoBean` 由 spring-boot-test-mockito 提供，行为等价但实现更干净，且让"测试工具依赖"可裁剪。

**Q3：从 3.x 升 4.0 的破坏性变更主要有哪些？**
① spring.factories 自动配置注册移除；② @MockBean/@SpyBean 移除；③ Spring Security 7 授权 API 收口；④ 测试 starter 拆分；⑤ Framework 7 清理废弃 API（适配器类等）。整体"编译错误清单化"，可控。

**Q4：Spring Boot 4 对虚拟线程的支持有什么变化？**
虚拟线程成为一等公民：`spring.threads.virtual.enabled` 可作用于 Web 容器、HTTP 客户端、JDBC 等全链路；配合 Java 21+ 的 IO 密集型服务吞吐显著提升。要注意 CPU 密集型任务不要开。

**Q5：现在（2026 年）新项目应该用 Boot 4 吗？**
建议用。4.0 已发布 9 个月，4.1/4.2 迭代稳定，生态（Spring Cloud 2025.x、Spring AI 等）已全面跟进。新项目直接 Boot 4 + Java 21（LTS），存量 3.x 项目评估后择机迁移。

---

## 七、总结

Spring Boot 4.0 是一次"**现代化重构**"而非"加功能"的版本：

- **对开发者**：模块化让依赖更精准，虚拟线程 + 结构化日志让性能和可观测性上一个台阶
- **对架构师**：统一 HTTP 抽象、授权 API 收口，为未来演进铺路
- **对运维**：优雅停机默认开启、OTLP 深度集成，云原生部署更顺滑

升级成本被控制在"编译错误清单"级别，但收益是长期的架构清爽。如果你还在 2.7/3.x 观望，2026 年的今天，是时候把升级提上日程了——**技术债越早还，利息越低**。
