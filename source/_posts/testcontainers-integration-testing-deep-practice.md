---
title: 【测试实战】Testcontainers 深度实战：容器化集成测试、依赖编排与 CI 落地
date: 2026-10-15 08:10:00
tags:
  - Java
  - 测试
  - Testcontainers
  - Docker
  - 集成测试
categories:
  - 工程实战
author: 东哥
---

# 【测试实战】Testcontainers 深度实战：容器化集成测试、依赖编排与 CI 落地

## 前言

Java 后端的集成测试长期活在"自欺欺人"里：

- 用 **H2 模拟 MySQL**，结果 `ON DUPLICATE KEY`、`JSON` 函数、隔离级别、锁行为全对不上，生产一出问题就是"测试明明过了"；
- 用 **Mock 掉 Redis/Kafka**，Mock 的行为是你自己写的，永远测不出真实的序列化、过期、重平衡问题；
- 依赖**团队共享的测试环境**，别人一改配置你的 CI 就红，环境成了公共厕所。

**Testcontainers** 的思路很直接：测试要什么依赖，就用 Docker 在测试进程里**起一个真的**，测完销毁。它把"集成测试环境的获得"从"运维问题"变成了"一行 Java 注解"。

本文覆盖原理、生命周期、Spring Boot 集成、CI 落地与踩坑，目标是让你能把集成测试从"不敢写"变成"随手写"。

## 一、Testcontainers 是什么

一句话：**用 Java 代码管理 Docker 容器生命周期的测试库**。

核心依赖：

```xml
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>junit-jupiter</artifactId>
    <version>1.20.4</version>
    <scope>test</scope>
</dependency>
<!-- 各中间件的模块化封装 -->
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>mysql</artifactId>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>kafka</artifactId>
    <scope>test</scope>
</dependency>
```

它通过 **Docker API**（默认读 `DOCKER_HOST` / `~/.testcontainers.properties`）与本地或远端 Docker 通信，**不依赖 docker-compose**，容器生命周期与测试用例绑定。

> 前置条件：测试机必须能访问 Docker daemon。CI 里通常用 **DinD（Docker-in-Docker）** 或挂载宿主 `/var/run/docker.sock`。

## 二、三分钟上手

```java
@Testcontainers
class UserRepositoryIT {

    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.4")
            .withDatabaseName("shop")
            .withUsername("test")
            .withPassword("test")
            .withInitScript("sql/user-schema.sql"); // 启动后执行初始化脚本

    @Test
    void shouldInsertAndQuery() {
        try (var conn = DriverManager.getConnection(
                mysql.getJdbcUrl(), mysql.getUsername(), mysql.getPassword())) {
            // 用真实 MySQL 跑你的 DAO / MyBatis Mapper
        }
    }
}
```

`@Testcontainers` 负责 start/stop；`@Container` 标记需要管理的容器。跑一次测试，镜像只拉一次，容器秒级启动。

## 三、生命周期：static 还是 instance？

这是**性能与正确性的分水岭**：

| 写法 | 启动时机 | 复用 | 适用 |
|---|---|---|---|
| `static @Container` | 类级，所有方法共享 | ✅ 一个类一次 | **推荐**，集成测试主流 |
| 非 static `@Container` | 每个 `@Test` 一次 | ❌ 每方法重启 | 需要绝对隔离（如破坏性测试） |

更进一步，跨**多个测试类**复用同一个容器，用 **Singleton 模式**：

```java
public abstract class AbstractIntegrationTest {
    static final MySQLContainer<?> MYSQL =
        new MySQLContainer<>("mysql:8.4").withReuse(true);
    static {
        MYSQL.start(); // 只启动一次，JVM 退出由 Ryuk 回收
    }
}
```

注意：**`static` 块启动的容器必须手动 `stop()` 或依赖 `Ryuk`（资源回收容器）清理**。

## 四、常用中间件速查

Testcontainers 为常见中间件提供了封装，直接给出连接信息：

```java
// Redis
GenericContainer<?> redis = new GenericContainer<>("redis:7.4").withExposedPorts(6379);
redis.getHost();                 // localhost
redis.getMappedPort(6379);       // 随机宿主机端口，避免冲突

// Kafka（模块内置了去 ZooKeeper 的 KRaft 支持）
KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.7.0"));
kafka.getBootstrapServers();

// Elasticsearch
ElasticsearchContainer es = new ElasticsearchContainer(
        "docker.elastic.co/elasticsearch/elasticsearch:8.15.0");

// PostgreSQL / MongoDB / RabbitMQ / LocalStack(AWS) / Pulsar ...
```

> **别写死端口**：容器端口映射到宿主机随机端口，一律用 `getMappedPort()`，否则并行测试必冲突。

### 等待策略（Wait Strategy）

容器"启动"不等于"就绪"。Testcontainers 内置多种策略：

```java
new GenericContainer<>("myapp:1.0")
    .withExposedPorts(8080)
    .waitingFor(Wait.forHttp("/actuator/health").forStatusCode(200))
    .withStartupTimeout(Duration.ofMinutes(2));
```

常用：`Wait.forListeningPort()`、`forHttp(...)`、`forLogMessage(".*Started.*")`、`forHealthcheck()`。**没有等待策略的容器化测试是 flaky 的头号来源。**

## 五、与 Spring Boot 集成

### 5.1 老办法：@DynamicPropertySource

```java
@SpringBootTest
@Testcontainers
class OrderServiceIT {
    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.4");

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("spring.datasource.url", mysql::getJdbcUrl);
        r.add("spring.datasource.username", mysql::getUsername);
        r.add("spring.datasource.password", mysql::getPassword);
    }
}
```

### 5.2 新办法：@ServiceConnection（Spring Boot 3.1+）

Spring Boot 3.1 起内置 **ConnectionDetails** 自动装配，**不再手写 url/username/password**：

```java
@SpringBootTest
@Testcontainers
class OrderServiceIT {
    @Container
    @ServiceConnection           // 自动把 MySQL 连接信息注入 DataSource
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.4");
}
```

支持 MySQL/PostgreSQL/Redis/Kafka/RabbitMQ/MongoDB/Elasticsearch 等几十种，是当前**最推荐**的写法。

```xml
<!-- 需要 spring-boot-testcontainers 提供 @ServiceConnection 的自动配置支持 -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-testcontainers</artifactId>
  <scope>test</scope>
</dependency>
```

## 六、CI 落地

### 6.1 GitHub Actions

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '21' }
      # GitHub runner 自带 Docker，无需 DinD
      - run: ./mvnw -B verify
```

- **Linux runner**：官方 runner 自带可用 Docker daemon，直接跑。
- **使用 DinD 时**：需要设置 `DOCKER_HOST` 与 `TESTCONTAINERS_HOST_OVERRIDE`，并给 privileged 权限。
- **Testcontainers Cloud / 远端 Docker**：把容器跑在专用机，CI 只连 API，适合镜像重、并发高的场景。

### 6.2 性能优化清单

1. **复用容器**：`withReuse(true)` + `~/.testcontainers.properties` 里 `testcontainers.reuse.enable=true`（本地开发神器，CI 不建议开，会污染）。
2. **单例基类**：跨测试类共享一个 DB 容器，靠**每个测试独立 schema**或事务回滚隔离数据。
3. **镜像预热**：CI 里 `docker pull` 关键镜像，或把镜像打进自定义 runner。
4. **并行执行**：JUnit 5 并行 + 每类独立容器，注意端口映射已随机化，不会冲突。
5. **只在需要时跑**：用 Maven Failsafe 分离 `*Test`（单测，快）与 `*IT`（集成测试，慢），CI 分阶段。

```xml
<plugin>
  <artifactId>maven-failsafe-plugin</artifactId>
  <configuration>
    <includes><include>**/*IT.java</include></includes>
  </configuration>
</plugin>
```

## 七、进阶用法

### 7.1 自定义 GenericContainer 与 Dockerfile

中间件之外的"你的服务"也能容器化测试：

```java
GenericContainer<?> api = new GenericContainer<>(
        new ImageFromDockerfile()
                .withDockerfile(Path.of("src/test/resources/Dockerfile")))
        .withExposedPorts(8080)
        .withEnv("SPRING_PROFILES_ACTIVE", "test")
        .waitingFor(Wait.forHttp("/actuator/health").forStatusCode(200));
```

`ImageFromDockerfile` 让 Testcontainers 现场构建镜像，特别适合"契约测试 / 端到端联调"。

### 7.2 在容器里执行命令

```java
Container.ExecResult r = mysql.execInContainer("mysql", "-uroot", "-psecret",
        "-e", "select count(*) from t_user");
System.out.println(r.getStdout());
```

用于验证初始化脚本、造数、查看容器内日志（`getLogs()`）。

### 7.3 容器间网络

当被测服务要访问数据库容器时，把两者放进同一网络：

```java
Network net = Network.newNetwork();
GenericContainer<?> db = new GenericContainer<>("postgres:16")
        .withNetwork(net).withNetworkAliases("db");
GenericContainer<?> app = new GenericContainer<>("myapp:test")
        .withNetwork(net)
        .withEnv("DB_HOST", "db");   // 容器内用别名访问，而不是 localhost
```

### 7.4 故障注入

验证"依赖挂了系统怎么表现"，以前几乎无法稳定复现，现在可以：

```java
redis.stop();                                 // 测试中途停掉 Redis
assertThat(service.getWithFallback("k")).isEqualTo("default");
redis.start();                                // 或留给下一个测试重建
```

这对**熔断、降级、重试**逻辑的验证极其有价值。

## 八、与 Flyway / Liquibase 集成

集成测试也要跑数据库迁移，才能保证"迁移脚本 + 代码"一起正确：

```java
static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.4")
        .withInitScript("sql/schema.sql");

@DynamicPropertySource
static void props(DynamicPropertyRegistry r) {
    r.add("spring.flyway.enabled", () -> true);
    r.add("spring.flyway.locations", () -> "classpath:db/migration");
}
```

Spring Boot 会在容器起来的库上自动执行 Flyway，**测试用的就是和生产同一套迁移脚本**，避免"生产迁移炸了测试却没发现"。

## 九、踩坑与最佳实践

1. **Ryuk 清理容器**：Testcontainers 默认启动 `testcontainers/ryuk` 容器，在 JVM 崩溃时回收资源。**某些受限网络/CI 会拉不到镜像或连不上 Ryuk**，表现为测试挂起——可用 `TESTCONTAINERS_RYUK_DISABLED=true` 应急（但要自己保证清理）。
2. **`localhost` 陷阱**：容器内网络与宿主机不同。容器 A 要访问容器 B，应放在**同一 Network**（`Network.newNetwork()`）并互用**别名**，而非 `localhost`。
3. **数据隔离**：容器复用后，测试间数据会串。推荐「每个测试类独立 database/schema」或用 `@Transactional` 回滚。
4. **别拿它做单元测试**：集成测试慢是正常的，它测的是**真实协作**。真正的逻辑单测仍应纯内存、毫秒级。
5. **Docker Desktop 许可**：企业规模使用需留意 Docker 商业授权，Testcontainers 本身是 MIT。
6. **Apple Silicon**：注意 `DockerImageName.parse("mysql:8.4").asCompatibleSubstituteFor("mysql")`，避免架构不匹配。

## 十、测试分层：别让 Testcontainers 变成新的"慢"

引入容器后最大的风险是**测试整体变慢，开发者开始跳过它**。健康的金字塔是：

| 层 | 依赖 | 工具 | 数量 | 速度 |
|---|---|---|---|---|
| 单元测试 | 无 | JUnit5 + Mockito | 多 | 毫秒 |
| 切片测试 | 部分 | `@WebMvcTest` / `@DataJpaTest` | 中 | 秒 |
| 集成测试 | 真实中间件 | **Testcontainers** | 少而精 | 十秒级 |
| 端到端 | 全链路 | 容器化服务 + 契约测试 | 极少 | 分钟级 |

**Testcontainers 用在这一层的正确姿势是"少而精"**：核心链路（下单、支付、消息投递）必须有；边缘分支交给单测覆盖。这样既拿到"真实依赖"的确定性，又不会让 CI 从 3 分钟变成 30 分钟。

> 一条经验：**每个集成测试都问自己"这个 bug 只有真实中间件才能暴露吗？"** 如果 Mock 能覆盖，就退回单测。

## 十一、总结

| 维度 | 传统方案 | Testcontainers |
|---|---|---|
| 依赖真实性 | H2/Mock 假象 | ✅ 真实中间件 |
| 环境一致性 | 共享环境易漂移 | ✅ 每次干净重建 |
| 本地可跑 | 需手工搭环境 | ✅ 有 Docker 即可 |
| 启动成本 | 低 | 中（可复用优化） |
| 适用范围 | 单测 | **集成测试 / DAO / 消息链路** |

**集成测试的价值不在覆盖率，而在"敢不敢改"**。当你敢大改 MyBatis Mapper、敢升级中间件版本，因为有一条用真实依赖跑过的测试兜底——Testcontainers 就已经回本了。
