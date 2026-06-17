---
title: 配置中心深度实践：Apollo 与 Nacos Config 选型与实战
date: 2026-06-17 08:30:00
tags:
  - 配置中心
  - Apollo
  - Nacos
  - Spring Cloud
categories:
  - 微服务
author: 东哥
---

# 配置中心深度实践：Apollo 与 Nacos Config 选型与实战

## 一、为什么需要配置中心

在单体应用时代，配置通常写在 `application.properties` 文件中，改配置 = 重启应用。到了微服务架构下，一个系统可能有几十甚至上百个服务实例，如果每个实例都修改配置文件再重启，无异于灾难。

配置中心要解决的核心问题有三个：

| 问题 | 传统方案痛点 | 配置中心方案 |
|------|-------------|-------------|
| 配置分散 | 每个服务各自维护，版本混乱 | 配置集中管理，版本控制 |
| 修改生效慢 | 改配置 -> 打包 -> 部署 -> 重启 | 热更新，秒级生效 |
| 环境隔离差 | dev/test/prod 配置容易混淆 | 多环境 namespace 隔离 |

## 二、Apollo 架构深度解析

### 2.1 整体架构

Apollo（携程开源）是目前业界最成熟的配置中心之一，其架构设计极具参考价值：

```
┌───────────────┐       ┌───────────────┐
│  Portal UI    │       │  Admin Service │
│  (Web管理端)   │◄─────►│  (配置管理)   │
└───────┬───────┘       └───────┬───────┘
        │                       │
        │      ┌───────────────▼───────┐
        │      │  Config Service (xN)  │
        │      │  获取配置、长轮询      │
        │      └──┬────────────┬───────┘
        │         │            │
        │   ┌─────▼─────┐ ┌───▼──────┐
        │   │ Eureka    │ │ Meta     │
        │   │ 注册中心   │ │ Server   │
        │   └───────────┘ └──────────┘
        │
   ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
   │ App-1  │  │ App-2  │  │ App-3  │
   │ Client │  │ Client │  │ Client │
   └─────────┘  └─────────┘  └─────────┘
```

架构关键点：
- **Config Service** 和 **Admin Service** 分离，读写隔离
- 客户端通过长轮询（Long Polling）实现配置实时推送
- 数据库存储配置，支持多环境、多集群、多 Namespace

### 2.2 Apollo 配置层级

Apollo 的配置模型分为三层：

```
AppId（应用）
  ├── Env（环境：DEV / FAT / UAT / PRO）
  │   ├── Cluster（集群：default / shanghai / beijing）
  │   │   ├── Namespace（命名空间：application / datasource.yml / ...）
  │   │   │   ├── Key-Value
  │   │   │   └── 配置项
```

这种四层模型（App → Env → Cluster → Namespace）可以灵活地管理不同环境、不同机房的配置。

### 2.3 Spring Boot 集成 Apollo

```xml
<dependency>
    <groupId>com.ctrip.framework.apollo</groupId>
    <artifactId>apollo-client</artifactId>
    <version>2.1.0</version>
</dependency>
```

```yaml
# application.yml
app:
  id: order-service

apollo:
  meta: http://config-meta.xxx.com
  bootstrap:
    enabled: true
    namespaces: application,datasource.yml,redis.yml
    eagerLoad:
      enabled: true
```

Java 代码中使用：

```java
@Configuration
public class ApolloConfig {
    
    // 自动注入 Apollo 配置
    @Value("${order.timeout:5000}")
    private int orderTimeout;
    
    // 监听配置变更
    @ApolloConfigChangeListener("application")
    public void onChange(ConfigChangeEvent changeEvent) {
        for (String key : changeEvent.changedKeys()) {
            ConfigChange change = changeEvent.getChange(key);
            log.info("配置变更: key={}, oldValue={}, newValue={}, type={}",
                key, change.getOldValue(), change.getNewValue(), change.getChangeType());
        }
    }
}
```

### 2.4 Apollo 热更新原理

Apollo 客户端通过长轮询实现热更新：

1. 客户端启动时向 Config Service 发起一次 HTTP 请求获取全量配置
2. 随后发起一个长轮询请求（默认 60s 超时），携带上次获取的 notifications
3. 如果服务端有配置变更，立即返回变更的 namespace
4. 客户端收到变更通知后，重新获取该 namespace 的配置
5. 更新本地缓存，触发 `@ApolloConfigChangeListener`

这种机制保证了**秒级配置生效**，且不会对服务端造成轮询压力。

## 三、Nacos Config 深度解析

Nacos（阿里巴巴开源）不仅是一个配置中心，还是一个服务注册与发现中心。这里我们先聚焦它的配置中心能力。

### 3.1 Nacos 配置模型

Nacos 的配置模型相对简单：

```
Namespace（命名空间）
  ├── Group（分组：DEFAULT_GROUP / PAY_GROUP）
  │   ├── Data ID（dataId：order-service.yml）
  │   │   └── 配置内容
```

### 3.2 Spring Cloud 集成 Nacos

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
    <version>2021.0.5.0</version>
</dependency>
```

```yaml
# bootstrap.yml
spring:
  application:
    name: order-service
  cloud:
    nacos:
      config:
        server-addr: 127.0.0.1:8848
        namespace: 4a5d4d1e-6f5a-4a9b-b3c2-1e2d3f4g5h6i  # 生产环境 namespace
        group: DEFAULT_GROUP
        file-extension: yaml
        refresh-enabled: true
        # 共享配置
        shared-configs:
          - dataId: common-datasource.yaml
            group: COMMON_GROUP
            refresh: true
          - dataId: common-redis.yaml
            group: COMMON_GROUP
            refresh: true
        # 多扩展配置
        extension-configs:
          - dataId: order-service-ext.yml
            group: PAY_GROUP
            refresh: true
```

### 3.3 Nacos 动态刷新

```java
@Component
@RefreshScope  // 关键注解：标记需要动态刷新的 Bean
public class DynamicConfigBean {
    
    @Value("${order.auto.cancel.minutes:30}")
    private int autoCancelMinutes;
    
    @Value("${order.max.daily.limit:100}")
    private int maxDailyLimit;
    
    public int getAutoCancelMinutes() {
        return autoCancelMinutes;
    }
    
    public int getMaxDailyLimit() {
        return maxDailyLimit;
    }
}
```

Nacos 还支持通过 `@NacosValue` 实现属性级别的自动更新：

```java
@Component
public class NacosConfigBean {
    
    @NacosValue(value = "${order.payment.timeout:30}", autoRefreshed = true)
    private int paymentTimeout;
}
```

## 四、Apollo vs Nacos Config 全面对比

| 维度 | Apollo | Nacos Config |
|------|--------|-------------|
| **开源方** | 携程 | 阿里巴巴 |
| **学习曲线** | 较陡（组件多） | 较平缓 |
| **部署复杂度** | 需要 Eureka、4个模块 | 单 Jar 包启动 |
| **配置格式** | Properties / XML / YAML / JSON / 自定义 | Properties / YAML / XML / JSON / TEXT |
| **热更新机制** | 长轮询（秒级） | 长轮询（秒级） |
| **配置版本管理** | 支持（发布历史、回滚） | 支持（发布历史、回滚） |
| **多环境支持** | 四层模型（原生支持） | Namespace 隔离（需手动配置） |
| **权限管理** | 支持（角色/用户/部门） | 支持（RBAC） |
| **配置监听** | @ApolloConfigChangeListener | @NacosValue(autoRefreshed) + @RefreshScope |
| **灰度发布** | 支持（标签灰度） | 支持（Beta 发布） |
| **配置加密** | 内置（需配置密钥） | 需集成 jasypt |
| **运维界面** | 功能丰富，UI 完善 | 简洁够用 |
| **社区活跃度** | 高 | 更高（Spring Cloud Alibaba 生态） |

## 五、生产环境部署实践

### 5.1 Apollo 生产部署

```yaml
# docker-compose-apollo.yml
version: '3.8'
services:
  apollo-configservice:
    image: apolloconfig/apollo-configservice:2.1.0
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://db:3306/ApolloConfigDB?characterEncoding=utf8
      - SPRING_DATASOURCE_USERNAME=apollo
      - SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
    ports:
      - "8080:8080"

  apollo-adminservice:
    image: apolloconfig/apollo-adminservice:2.1.0
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://db:3306/ApolloConfigDB?characterEncoding=utf8
      - SPRING_DATASOURCE_USERNAME=apollo
      - SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
    depends_on:
      - apollo-configservice

  apollo-portal:
    image: apolloconfig/apollo-portal:2.1.0
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://db:3306/ApolloPortalDB?characterEncoding=utf8
      - SPRING_DATASOURCE_USERNAME=apollo
      - SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
      - APOLLO_PORTAL_ENVS=dev,prod
      - DEV_META=http://apollo-configservice:8080
      - PROD_META=http://apollo-configservice:8080
    ports:
      - "8070:8070"
```

### 5.2 Nacos 生产部署

```yaml
# docker-compose-nacos.yml
version: '3.8'
services:
  nacos-mysql:
    image: mysql:8.0
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_PASSWORD}
      - MYSQL_DATABASE=nacos_config
    volumes:
      - ./mysql/init.sql:/docker-entrypoint-initdb.d/init.sql
      - nacos-mysql-data:/var/lib/mysql

  nacos:
    image: nacos/nacos-server:2.3.0
    environment:
      - MODE=cluster
      - NACOS_SERVERS=nacos-1:8848 nacos-2:8848 nacos-3:8848
      - MYSQL_SERVICE_HOST=nacos-mysql
      - MYSQL_SERVICE_DB_NAME=nacos_config
      - MYSQL_SERVICE_USER=root
      - MYSQL_SERVICE_PASSWORD=${DB_PASSWORD}
      - JVM_XMS=2g
      - JVM_XMX=2g
    ports:
      - "8848:8848"
    depends_on:
      - nacos-mysql
```

### 5.3 配置安全实践

配置中心中存储的数据库密码、API 密钥是敏感信息，必须加密：

```yaml
# Apollo 加密配置
apollo:
  property:
    # 加密密钥，32位
    encrypt.secret: xxxxxx

# Nacos 集成 jasypt 加密
jasypt:
  encryptor:
    password: ${JASYPT_SECRET}
    algorithm: PBEWithMD5AndDES
```

使用加密插件后，配置中存储的是加密后的密文：
```yaml
datasource:
  password: ENC(7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d)
```

## 六、选型建议

| 场景 | 推荐方案 | 理由 |
|------|---------|------|
| 纯配置中心需求 | Apollo | 功能更全、运维更成熟 |
| 已有 Spring Cloud Alibaba 生态 | Nacos Config | 统一技术栈、减少组件 |
| 小型团队、快速迭代 | Nacos Config | 部署简单、学习成本低 |
| 大型企业、复杂权限管理 | Apollo | 权限体系完善、多环境模型清晰 |
| 需要配置灰度发布 | Apollo 或 Nacos | 两者都支持 |

无论选择哪种方案，配置中心都是微服务架构中不可或缺的一环。它让配置管理从"改代码重启"的原始方式，进化到"实时生效、版本可控、集中管理"的现代化治理模式。
