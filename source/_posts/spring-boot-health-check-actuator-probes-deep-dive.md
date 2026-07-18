---
title: Spring Boot 健康检查机制深度实战：Actuator + Kubernetes 探针
date: 2026-07-18 08:00:00
tags:
  - Spring Boot
  - Actuator
  - 健康检查
  - Kubernetes
categories:
  - Spring Boot
  - 微服务架构
author: 东哥
---

# Spring Boot 健康检查机制深度实战：Actuator + Kubernetes 探针

## 一、为什么需要健康检查？

在单体应用中，服务挂了就挂了，运维上去重启即可。但在微服务和云原生时代，一个服务可能运行在几十个 Pod 上，每分钟都在发生扩缩容和滚动更新。**健康检查** 是基础设施自动运维的基础：

- **Load Balancer**：只把流量路由到健康的实例
- **Kubernetes**：自动重启不健康的 Pod，滚动更新时判断新版是否就绪
- **服务治理**：注册中心根据健康状态摘除/恢复实例
- **流量调度**：蓝绿部署、灰度发布依赖健康检查做切换决策

> **面试官**：/actuator/health 不就一个 UP/DOWN 吗？这有什么好深入的？

好问题。健康检查远不止 UP/DOWN 两个状态——它是一条**连接应用和基础设施的生命线**。

---

## 二、Spring Boot Actuator 健康检查体系

### 2.1 基础概念

`/actuator/health` 端点返回的是**聚合健康状态**，由多个 **HealthIndicator** 组合而成。

```json
{
  "status": "UP",
  "components": {
    "db": {
      "status": "UP"
    },
    "redis": {
      "status": "UP"
    },
    "discoveryComposite": {
      "status": "UP"
    },
    "diskSpace": {
      "status": "UP",
      "details": {
        "total": 536870912000,
        "free": 322122547200,
        "threshold": 10485760
      }
    },
    "ping": {
      "status": "UP"
    }
  }
}
```

### 2.2 状态聚合规则

所有 HealthIndicator 的状态通过 **HealthAggregator** 策略合并：

```java
public enum Status {
    DOWN,       // ❌ 最严重
    OUT_OF_SERVICE,  // ❌
    UNKNOWN,    // ⚠️
    UP          // ✅
}
```

**聚合逻辑**（基于排序）：

```java
// OrderedHealthAggregator 默认聚合逻辑：
// 1. 所有组件的状态按严重程度排序
// 2. 取最严重的那个作为整体状态
// 3. 如果没有任何组件，返回 UNKNOWN

// 自定义聚合顺序：
management.endpoint.health.status.order=DOWN,OUT_OF_SERVICE,UNKNOWN,UP
```

### 2.3 内置 HealthIndicator

| HealthIndicator | 自动配置条件 | 检测内容 |
|----------------|-------------|---------|
| `DataSourceHealthIndicator` | 有 DataSource Bean | 执行 `SELECT 1` 或 `SELECT 1 FROM DUAL` |
| `RedisHealthIndicator` | 有 RedisConnectionFactory | 执行 `PING` |
| `MongoHealthIndicator` | 有 MongoTemplate | 执行 `ping` 命令 |
| `ElasticsearchHealthIndicator` | 有 ElasticsearchClient/RestClient | 检查集群健康状态 |
| `RabbitHealthIndicator` | 有 ConnectionFactory | 获取 RabbitMQ 连接 |
| `KafkaHealthIndicator` | 有 KafkaTemplate/ConsumerFactory | 检查 Kafka 连接 |
| `DiskSpaceHealthIndicator` | 自动 | 检查磁盘剩余空间是否高于阈值 |
| `PingHealthIndicator` | 自动 | 始终返回 UP |
| `MailHealthIndicator` | 有 JavaMailSender | 发送测试邮件 |
| `RedisReactiveHealthIndicator` | 有 ReactiveRedisConnectionFactory | 执行 PING |

### 2.4 显示详细信息的配置

```yaml
# 默认只显示 UP/DOWN，不暴露 details
management:
  endpoint:
    health:
      show-details: always           # always | never | when-authorized
      show-components: always         # 只显示组件名和状态（Spring Boot 2.3+）
      
  # 安全控制：哪些角色可以看详情
  endpoints:
    web:
      exposure:
        include: health,info,metrics  # 暴露端点
```

---

## 三、自定义 HealthIndicator

### 3.1 最简单的自定义

```java
@Component
public class CustomServiceHealthIndicator implements HealthIndicator {
    
    @Override
    public Health health() {
        // 检查某个外部服务的连通性
        boolean isHealthy = checkExternalService();
        
        if (isHealthy) {
            return Health.up()
                    .withDetail("service", "custom-api")
                    .withDetail("latency", "15ms")
                    .build();
        }
        return Health.down()
                .withDetail("service", "custom-api")
                .withDetail("error", "Connection refused")
                .build();
    }
    
    private boolean checkExternalService() {
        // 实现具体的健康检查逻辑
        try {
            // 例如：发送 HTTP 请求
            // 或检查数据库连接池状态
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
```

### 3.2 带状态码的自定义 HealthIndicator

有时候单纯的 UP/DOWN 不够用，可以引入更多状态：

```java
@Component
public class DatabasePoolHealthIndicator implements HealthIndicator {
    
    @Autowired
    private DataSource dataSource;
    
    @Override
    public Health health() {
        if (dataSource instanceof HikariDataSource) {
            HikariDataSource hikari = (HikariDataSource) dataSource;
            int active = hikari.getHikariPoolMXBean().getActiveConnections();
            int idle = hikari.getHikariPoolMXBean().getIdleConnections();
            int total = hikari.getMaximumPoolSize();
            
            // 根据连接池使用率判定健康状态
            if ((double) active / total > 0.9) {
                return Health.status("WARN")
                        .withDetail("active", active)
                        .withDetail("idle", idle)
                        .withDetail("total", total)
                        .withDetail("message", "连接池使用率超过 90%")
                        .build();
            }
            
            return Health.up()
                    .withDetail("active", active)
                    .withDetail("idle", idle)
                    .withDetail("total", total)
                    .build();
        }
        return Health.up().build();
    }
}
```

### 3.3 自定义 Status 类型

```java
// 1. 定义新状态
public class CustomStatus extends Status {
    public static final Status WARN = new Status("WARN", 300);
    public static final Status DEGRADED = new Status("DEGRADED", 250);
    
    private CustomStatus(String code, int severity) {
        super(code, String.valueOf(severity));
    }
}

// 2. 在配置中注册优先级
public class CustomHealthAggregator extends OrderedHealthAggregator {
    public CustomHealthAggregator() {
        // 数字越小越严重
        setStatusOrder(
            Status.DOWN,
            CustomStatus.DEGRADED,
            CustomStatus.WARN,
            Status.OUT_OF_SERVICE,
            Status.UNKNOWN,
            Status.UP
        );
    }
}
```

---

## 四、Kubernetes 探针集成

这是云原生场景下最实用的技能。

### 4.1 K8s 三种探针

| 探针 | 用途 | 失败后果 |
|------|------|---------|
| **Liveness Probe** | 检查进程是否存活 | 杀死容器，重启 |
| **Readiness Probe** | 检查服务是否就绪 | 从 Service Endpoint 摘除 |
| **Startup Probe** | 检查应用是否启动完成 | 延时 Liveness 检查（K8s 1.18+） |

### 4.2 Spring Boot 为 K8s 探针提供的端点

从 Spring Boot 2.3 开始，新增了专用于 K8s 探针的端点：

```yaml
# 启用 K8s 探针端点
management:
  endpoint:
    health:
      probes:
        enabled: true   # 开启 /actuator/health/liveness 和 /actuator/health/readiness
  health:
    livenessstate:
      enabled: true
    readinessstate:
      enabled: true
```

开启后，会得到两个专用端点：

```json
// GET /actuator/health/liveness
{
  "status": "UP"
}

// GET /actuator/health/readiness
{
  "status": "UP"
}
```

### 4.3 Liveness 与 Readiness 的分离逻辑

```
┌─────────────────────────────────────────────┐
│  /actuator/health/liveness                   │
│  = LivenessStateHealthIndicator              │
│  检测范围：应用内部状态                      │
│  - Redis/MQ 连接是否正常？                   │
│  - 数据库连接是否正常？                      │
│  - 配置中心是否可用？                        │
│  如果失败：K8s 会重启容器                    │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│  /actuator/health/readiness                  │
│  = ReadinessStateHealthIndicator             │
│  检测范围：服务对外能力                      │
│  - 缓存预热是否完成？                        │
│  - 线程池是否就绪？                          │
│  - 初始数据是否加载完成？                    │
│  如果失败：K8s 从 Service 摘除，但不重启     │
└─────────────────────────────────────────────┘
```

### 4.4 自定义 Liveness/Readiness 健康指标

```java
@Component
public class CacheWarmupHealthIndicator 
        implements ReadinessHealthIndicator {  // 只影响 Readiness，不影响 Liveness
    
    private boolean warmupComplete = false;
    
    @Override
    public Health health() {
        if (warmupComplete) {
            return Health.up().withDetail("cache", "warmup_complete").build();
        }
        return Health.down().withDetail("cache", "warming_up").build();
    }
    
    public void markWarmupComplete() {
        this.warmupComplete = true;
    }
}
```

```java
@Component
public class DatabaseConnectivityHealthIndicator 
        implements LivenessHealthIndicator {  // 只影响 Liveness
    
    @Override
    public Health health() {
        // 如果数据库连不上，Liveness 返回 DOWN → K8s 重启 Pod
        // 这比 Readiness 更激进，适合核心依赖不可恢复的场景
        return dataSourceHealthIndicator.health();
    }
}
```

### 4.5 K8s 部署配置

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: order-service
        image: order-service:latest
        ports:
        - containerPort: 8080
        
        # Startup Probe：启动时给应用足够的时间
        startupProbe:
          httpGet:
            path: /actuator/health/liveness
            port: 8080
          initialDelaySeconds: 10    # 等 10 秒再开始探测
          periodSeconds: 5           # 每 5 秒探测一次
          failureThreshold: 30       # 允许 30 次失败（最多等 150 秒）
        
        # Liveness Probe：运行时检查存活
        livenessProbe:
          httpGet:
            path: /actuator/health/liveness
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3        # 连续 3 次失败 → 重启
        
        # Readiness Probe：检查服务是否就绪
        readinessProbe:
          httpGet:
            path: /actuator/health/readiness
            port: 8080
          initialDelaySeconds: 20
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2        # 连续 2 次失败 → 摘除流量
```

---

## 五、高级健康检查场景

### 5.1 延迟初始化 + 健康检查

对于启动较慢的应用（加载大量缓存、连接数据库），配合 **StartupProbe** + Spring Boot 启动流程：

```java
@Component
public class DataLoader {
    
    @EventListener(ApplicationReadyEvent.class)
    public void loadData() {
        // 应用启动完成后，加载大量数据到缓存
        // 此时 Readiness 探针应该返回 DOWN（还没准备好）
        // 加载完成后更新 Readiness 状态
        cacheWarmupIndicator.markWarmupComplete();
    }
}
```

### 5.2 优雅关闭 + 健康检查

Spring Boot 2.3 引入优雅关闭，配合 Readiness 可以实现**零停机更新**：

```yaml
server:
  shutdown: graceful    # 优雅关闭（默认 immediate）

spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s  # 最多等待 30 秒
```

**关闭时序**：

```
K8s 发起滚动更新
    │
    ├─▶ 发送 SIGTERM
    │
    ├─▶ Spring Boot 将 /actuator/health/readiness 返回 DOWN
    │   （Service 摘除此 Pod，不再有新流量）
    │
    ├─▶ 等待正在处理的请求完成
    │   （最多 30 秒）
    │
    ├─▶ 关闭线程池、销毁 Bean
    │
    └─▶ 进程退出
```

### 5.3 依赖级联健康检查

当服务 A 依赖服务 B，B 又依赖 C 时，健康检查应该体现这种级联：

```java
@Component
public class DownstreamServiceHealthIndicator implements HealthIndicator {
    
    @Override
    public Health health() {
        // 检查下游依赖的健康状态
        Health downstreamHealth = checkDownstreamService();
        
        if (downstreamHealth.getStatus() == Status.DOWN) {
            // 下游挂了 → 本服务降级但不标记 DOWN
            return Health.status("DEGRADED")
                    .withDetail("downstream", downstreamHealth)
                    .build();
        }
        
        return Health.up()
                .withDetail("downstream", downstreamHealth)
                .build();
    }
}
```

---

## 六、生产配置模板

```yaml
server:
  port: 8080
  shutdown: graceful

spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s

management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
      base-path: /internal        # 隐藏端口，不对外暴露
  endpoint:
    health:
      show-details: when-authorized
      show-components: always
      probes:
        enabled: true
      group:
        # 自定义健康检查组
        readiness:
          include: db,redis,rabbit,custom
        liveness:
          include: ping,diskSpace
  health:
    readinessstate:
      enabled: true
    livenessstate:
      enabled: true
    # 磁盘空间阈值
    diskspace:
      threshold: 10GB
```

---

## 七、面试高频追问

**Q1：/actuator/health/liveness 和 /actuator/health/readiness 的区别是什么？**

> Liveness 表示进程健康，失败后 K8s 会重启 Pod。Readiness 表示服务就绪，失败后 K8s 从 Service 摘除但不重启。Liveness 不应该依赖外部组件（否则网络抖动会导致 Pod 反复重启），Readiness 可以包含对外部依赖的检查。

**Q2：Startup Probe 有什么用？**

> 防止启动慢的应用在 Liveness 检查时间窗内被错误杀死。例如一个需要加载 2 分钟缓存的应用，如果没有 Startup Probe，Liveness Probe 可能在启动 30 秒后认为它卡死了。Startup Probe 给了应用一个更宽的启动时间窗口，一旦成功就交给 Liveness 接管。

**Q3：健康检查在灰度发布中如何发挥作用？**

> 新版本部署时，K8s 先创建新 Pod → Readiness Probe 检查通过 → Service 注入新 Pod → 同时逐步摘除旧 Pod。如果新 Pod 的 Readiness 一直不通过，则不会接收流量，滚动更新自动暂停，不会影响现有服务。

**Q4：健康检查和生产故障排查有什么关系？**

> 健康检查暴露的是**症状**，故障排查要找**病因**。比如 DB HealthIndicator 显示 DOWN，你知道了"数据库有问题"，但真正的原因可能是连接池耗尽、网络超时、磁盘满、主从切换等。健康检查信号 + 详细指标（Metrics）才能定位问题。

---

## 八、总结

Spring Boot 的健康检查机制远不止一个 UP/DOWN 端点：

1. **自动装配**了数据库、Redis、MQ 等主流组件的 HealthIndicator
2. **自定义扩展**：实现 HealthIndicator 接口即可添加任意组件的健康检查
3. **K8s 原生集成**：Liveness/Readiness/Startup 三探针 + Spring Boot 优雅关闭 = 零停机
4. **状态聚合**：多组件健康状态按优先级聚合，支持自定义状态类型
5. **安全控制**：可细粒度控制哪些角色能看到详细信息

**一句话总结**：健康检查是一切自动化运维的基础，把它做深了，整个部署流水线和自愈机制才有底气。
