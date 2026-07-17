---
title: 【Spring Boot 3.x】Docker Compose 开发集成实战：从本地开发到 CI 环境
date: 2026-07-17 08:00:00
tags:
  - Spring Boot
  - Docker Compose
  - 开发环境
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 3.x】Docker Compose 开发集成实战：从本地开发到 CI 环境

## 引言

每个 Java 后端开发者都经历过这个痛苦场景：

> "代码写完了，本地跑一下……嗯？MySQL 没启动？Redis 没装？Kafka 呢？"

传统方式要么手动启动各种服务，要么写一长串 docker-compose.yml 手动管理。Spring Boot 3.1 引入的 **Docker Compose 集成** 彻底改变了这一局面——应用启动时自动拉起依赖的服务，应用关闭时自动清理。

本文围绕 Spring Boot + Docker Compose 集成，从入门到生产，讲透这个省力利器。

> **前提**：Spring Boot 3.1+，Docker 环境已安装。

## 一、为什么需要 Docker Compose 集成？

| 场景 | 传统做法 | Spring Boot 集成后 |
|------|---------|-------------------|
| 本地开发 | 手动 docker-compose up -d | 启动项目时自动拉取 |
| 切换项目 | 手动停掉上一组的容器 | 只启动当前项目需要的 |
| 多人协作 | 每人要装各种中间件 | Docker 镜像拉取即可 |
| 重置数据 | 手动 docker-compose down -v | 应用关闭自动清理 |
| CI 环境 | 额外脚本启动服务 | Spring Boot 自动管理 |

## 二、快速上手：5 分钟集成

### 2.1 添加依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-docker-compose</artifactId>
    <optional>true</optional>
</dependency>
```

### 2.2 创建 docker-compose.yml

在项目根目录（或 `src/main/resources/` 下）创建：

```yaml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: root123
      MYSQL_DATABASE: myapp
    ports:
      - "3306:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 3s
      retries: 10

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

### 2.3 启动应用

```bash
# 就这么简单！
mvn spring-boot:run

# 或
java -jar myapp.jar
```

结果：
1. Spring Boot 自动发现 `docker-compose.yml`
2. 自动执行 `docker compose up -d` 启动 MySQL + Redis
3. 等待 MySQL 和 Redis 健康检查通过
4. 应用启动，自动连接 MySQL（`localhost:3306`）和 Redis（`localhost:6379`）
5. 应用关闭时，自动执行 `docker compose down`

**完全零配置连接**：Spring Boot 会自动为 Docker 容器创建动态属性！

## 三、工作原理源码分析

### 3.1 自动发现机制

`spring-boot-docker-compose` 模块启动时的核心流程：

```
Application Started
  ↓
DockerComposeAutoConfiguration 检查条件
  ↓（classpath 有 DockerComposeFileDetector）
DockerComposeFileDetector.detect()
  ↓ 按顺序查找
1. 项目根目录 docker-compose.yml
2. 项目根目录 docker-compose.yaml
3. classpath:docker-compose.yml
4. classpath:docker-compose.yaml
  ↓
DockerComposeLifecycleManager.start()
  ↓
docker compose up -d --wait
  ↓
ConnectionDetailsFactory 创建连接详情
  ↓
动态注册 DataSourceConnectionDetails、RedisConnectionDetails 等 Bean
```

### 3.2 关键源码片段

```java
// DockerComposeLifecycleManager 的核心逻辑
public void start() {
    // 1. 读取 Compose 文件
    DockerComposeFile composeFile = loadComposeFile();
    
    // 2. 启动容器
    DockerCli dockerCli = new DockerCli(composeFile.getWorkingDirectory());
    dockerCli.up();
    
    // 3. 等待服务就绪（健康检查）
    dockerCli.waitForServices(composeFile.getServices());
    
    // 4. 创建 ConnectionDetails
    List<ConnectionDetails> details = createConnectionDetails(dockerCli);
    
    // 5. 注册到 Spring 容器
    registerBeans(details);
}
```

### 3.3 ConnectionDetails 的妙用

Spring Boot 3.1 引入了一套新的 **ConnectionDetails** 接口体系：

```java
// DataSource 的连接详情
public interface DataSourceConnectionDetails extends ConnectionDetails {
    String getUrl();
    String getUsername();
    String getPassword();
    String getDriverClassName();
}

// Redis 的连接详情
public interface RedisConnectionDetails extends ConnectionDetails {
    String getHost();
    int getPort();
    String getPassword();
}

// 支持的中间件：
// - DataSourceConnectionDetails (MySQL, PostgreSQL, MariaDB)
// - RedisConnectionDetails
// - MongoConnectionDetails
// - CassandraConnectionDetails
// - KafkaConnectionDetails
// - ElasticsearchConnectionDetails
// - RabbitMQConnectionDetails
// - ZipkinConnectionDetails
// - ServiceConnectionDetails (自定义)
```

**关键作用**：当 `DockerComposeLifecycleManager` 启动容器后，会查询容器的端口映射，动态创建对应的 `ConnectionDetails` Bean。这些 Bean 的优先级高于 `application.yml` 中的 `spring.datasource.url` 等配置，实现**自动覆盖**。

## 四、高级配置

### 4.1 自定义 Compose 文件路径

```yaml
spring:
  docker:
    compose:
      file: docker/mysql-redis-compose.yml  # 自定义路径
      enabled: true                         # 默认 true
      lifecycle-management: start_only      # 容器生命周期管理
```

### 4.2 生命周期管理策略

```yaml
spring:
  docker:
    compose:
      lifecycle-management:  # 可选值：
        - none               # 不管理容器（手动 docker-compose up）
        - start_only         # 只启动，不关闭（重启启动时不会重新创建）
        - start_and_stop     # 启动 + 关闭（默认）
```

### 4.3 跳过 Docker 检查

在没有 Docker 的环境（如某些 CI 构建阶段）：

```yaml
spring:
  docker:
    compose:
      skip:
        check: true   # 跳过 Docker 可用性检查
```

### 4.4 与 Testcontainers 配合

```yaml
spring:
  docker:
    compose:
      lifecycle-management: start_and_stop
      # 测试时配合 Testcontainers 使用
      # compose 中的服务名与 Testcontainers 中的服务名应保持一致
      
  # 测试环境覆盖配置
  datasource:
    url: jdbc:tc:mysql:8.0:///testdb  # Testcontainers JDBC URL
```

### 4.5 自定义 ConnectionDetails

如果你的中间件不在 Spring Boot 内置支持列表中，可以实现自己的 `ConnectionDetails`：

```java
// 1. 定义 ConnectionDetails
public class MinioConnectionDetails implements ConnectionDetails {
    private final String endpoint;
    private final String accessKey;
    private final String secretKey;
    
    // constructor, getters...
}

// 2. 注册工厂
@Component
class MinioConnectionDetailsFactory implements ConnectionDetailsFactory<MinioConnectionDetails> {
    
    @Override
    public MinioConnectionDetails get(DockerComposeContainer container) {
        ContainerService minio = container.getService("minio");
        int port = container.getServicePort("minio", 9000);
        return new MinioConnectionDetails(
            "http://localhost:" + port,
            "minioadmin",
            "minioadmin"
        );
    }
    
    @Override
    public boolean supports(String serviceName) {
        return "minio".equals(serviceName);
    }
}
```

## 五、实战：完整微服务环境

### 5.1 docker-compose.yml

```yaml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: root123
      MYSQL_DATABASE: order_db
    ports:
      - "3306:3306"
    volumes:
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 3s
      retries: 10

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

  kafka:
    image: confluentinc/cp-kafka:7.5.0
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1

  zookeeper:
    image: confluentinc/cp-zookeeper:7.5.0
    ports:
      - "2181:2181"
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
```

### 5.2 application.yml 配置

```yaml
spring:
  docker:
    compose:
      enabled: true
      lifecycle-management: start_and_stop
      startup:
        timeout: 120s  # 等待容器启动的超时时间

  # 这些配置可以被 Docker Compose ConnectionDetails 覆盖
  datasource:
    url: jdbc:mysql://localhost:3306/order_db
    username: root
    password: root123
  
  kafka:
    bootstrap-servers: localhost:9092
```

### 5.3 启动效果

```bash
# 启动应用（自动拉起 mysql/redis/kafka/zookeeper）
java -jar order-service.jar

# 控制台输出：
# 2026-07-17 08:00:00.123  INFO : Docker Compose file found: docker-compose.yml
# 2026-07-17 08:00:00.456  INFO : Executing: docker compose up -d --wait
# 2026-07-17 08:00:15.789  INFO : Container mysql is ready
# 2026-07-17 08:00:15.790  INFO : Container redis is ready
# 2026-07-17 08:00:20.123  INFO : Container kafka is ready
# 2026-07-17 08:00:20.124  INFO : Registering DataSourceConnectionDetails
# 2026-07-17 08:00:20.125  INFO : Registering RedisConnectionDetails
# 2026-07-17 08:00:20.126  INFO : Registering KafkaConnectionDetails
# 2026-07-17 08:00:20.500  INFO : Started OrderServiceApplication in 25.3 seconds
```

## 六、多环境配置策略

### 6.1 开发环境（启用 Compose）

```yaml
# application-dev.yml
spring:
  docker:
    compose:
      enabled: true
      lifecycle-management: start_and_stop
```

### 6.2 测试环境（复用 Compose）

```yaml
# application-test.yml
spring:
  docker:
    compose:
      enabled: true
      lifecycle-management: start_only  # 多个测试类共享容器
```

### 6.3 生产环境（禁用 Compose）

```yaml
# application-prod.yml
spring:
  docker:
    compose:
      enabled: false

  # 生产使用外部数据库
  datasource:
    url: jdbc:mysql://prod-db.example.com:3306/mydb
    username: ${DB_USER}
    password: ${DB_PASS}
```

### 6.4 启动时指定环境

```bash
# 开发
mvn spring-boot:run -Dspring-boot.run.profiles=dev

# 构建 JAR 后
java -jar app.jar --spring.profiles.active=dev
```

## 七、常见问题与解决方案

### 7.1 端口冲突

```bash
Error: Port 3306 is already in use
```

**解决方法**：
```yaml
# 方式1：修改映射端口
ports:
  - "3307:3306"   # 宿主机 3307 映射到容器的 3306

# 方式2：随机端口（Spring Boot 会自动检测）
ports:
  - "3306"  # 不指定宿主机端口，由 Docker 分配
```

### 7.2 容器启动太慢

```yaml
spring:
  docker:
    compose:
      startup:
        timeout: 180s      # 增加超时时间
        log-level: info    # 打印容器启动日志
```

### 7.3 数据持久化问题

默认 `docker compose down` 会销毁容器和卷。如果想保留数据：

```yaml
# 方案1：使用 named volumes
volumes:
  mysql-data:

services:
  mysql:
    volumes:
      - mysql-data:/var/lib/mysql

# 方案2：使用 bind mount
  mysql:
    volumes:
      - ./data/mysql:/var/lib/mysql

# 方案3：lifecycle-management: start_only（不执行 docker-compose down）
spring:
  docker:
    compose:
      lifecycle-management: start_only
```

### 7.4 多模块项目

```yaml
# 在根项目 docker-compose.yml 中定义所有服务
# 每个子模块只需启动其需要的服务

spring:
  docker:
    compose:
      file: ../docker-compose.yml  # 引用父目录的 compose 文件
```

## 八、与 Testcontainers 对比

| 特性 | Spring Boot Docker Compose | Testcontainers |
|------|:---:|:---:|
| 定位 | 开发环境依赖管理 | 集成测试容器管理 |
| 适用阶段 | 本地开发 | 测试 |
| 生命周期 | 应用级 | 测试类级 |
| 自动配置 | ✅ 自动注入 ConnectionDetails | ✅ 通过 @DynamicPropertySource |
| CI 支持 | 一般（需 Docker 环境） | ✅ 原生支持 |
| 数据库初始化 | compose 中的 init SQL | @Sql 注解 或 flyway |
| 多容器编排 | ✅ compose 文件定义 | ✅ 代码组合 |

**最佳实践**：开发用 `spring-boot-docker-compose`，测试用 `Testcontainers`，各司其职。

## 九、面试常见问答

**Q1：ConnectionDetails 的原理是什么？**

A：ConnectionDetails 是 Spring Boot 3.1 引入的接口体系，用于描述到某个外部服务的连接参数（URL、端口、认证信息等）。Docker Compose 集成模块在启动容器后，通过解析容器端口映射创建对应的 ConnectionDetails Bean，并注册到 Spring 环境中。由于这些 Bean 的 `@Primary` 优先级高于 application.yml 中的配置，所以能自动覆盖——开发者不需要手动修改配置。

**Q2：这个功能能在生产环境用吗？**

A：不可以！`spring-boot-docker-compose` 专为**开发环境**设计。生产环境应使用外部托管的数据库/缓存/消息队列，或通过 Kubernetes 等容器编排平台管理。生产环境应设置 `spring.docker.compose.enabled=false`。

**Q3：与已有 docker-compose.yml 项目兼容吗？**

A：完全兼容。`spring-boot-docker-compose` 读取标准的 docker-compose.yml 文件，没有任何自定义扩展字段。已有的 Compose 文件可以无缝使用。

**Q4：同时启动多个 Spring Boot 项目时端口冲突怎么办？**

A：Docker Compose 集成支持随机端口分配。建议在开发环境下使用随机端口（services > ports 只写容器端口），Spring Boot 会自动检测实际映射端口并注入到 ConnectionDetails 中。

## 十、总结

Spring Boot 3.x 的 Docker Compose 集成是一个"润物细无声"的好功能：

1. **零配置启动开发环境**——写一个 compose 文件，所有依赖自动拉起
2. **智能连接**——ConnectionDetails 自动注入，无需手动改配置
3. **环境隔离**——profile 控制不同环境的行为
4. **轻量级**——比本地安装所有中间件更轻，比测试容器更快

建议：所有 Spring Boot 3.1+ 的项目都应该在开发环境启用这个特性。把 docker-compose.yml 提交到仓库，新同事 clone 项目后直接 `mvn spring-boot:run` 就能跑起来，这才是理想的开箱即用体验。
