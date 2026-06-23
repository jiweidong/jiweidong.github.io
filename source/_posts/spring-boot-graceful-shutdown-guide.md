---
title: Spring Boot 优雅关闭与平滑上线：生产环境必知的最佳实践
date: 2026-06-23 08:02:00
tags:
  - Spring Boot
  - 高可用
  - 运维
categories:
  - Spring
  - DevOps
author: 东哥
---

# Spring Boot 优雅关闭与平滑上线：生产环境必知的最佳实践

## 问题场景

凌晨两点，你收到告警：服务实例正在重启，同时线上出现大量 5xx 错误。用户反馈"页面打不开"。

```
[Pod 删除] → [SIGTERM] → [Spring Boot 关闭] → [K8s 移除 Endpoint]
                                     ↑                              ↑
                              还有请求正在处理                可能有时间差
```

**核心问题：** 关闭时正在处理的请求被强行中断，同时上游负载均衡还没摘除这个实例的新流量。

## 一、Spring Boot 优雅关闭

### 1.1 传统关闭的问题

Spring Boot 2.2 之前，默认的关闭方式是**粗暴切断**：

```
1. 收到 SIGTERM
2. 立即关闭 ApplicationContext
3. 销毁所有 Bean
4. DispatcherServlet 停止服务
   └── 正在处理的请求 → 连接断开 → 502/500
```

这就像在餐厅高峰期直接拉电闸，还在吃饭的客人直接被赶出去。

### 1.2 启用优雅关闭

Spring Boot 2.3+ 内置了 graceful shutdown：

```yaml
# application.yml
server:
  shutdown: graceful   # 开启优雅关闭
  netty:
    shutdown-timeout: 30s  # 最多等 30 秒
```

```yaml
# Tomcat 容器配置
server:
  shutdown: graceful
  tomcat:
    connection-timeout: 5s
    threads:
      max: 200
      min-spare: 10
```

**原理：**

```
SIGTERM 到来
    ↓
Tomcat 停止接收新请求
    ↓
等待已接收请求处理完成（或超时）
    ↓
Spring Context 开始销毁
    ↓
服务完全停止
```

### 1.3 源码分析

```java
// Spring Boot 2.3+ 的 GracefulShutdown 类
class GracefulShutdown {
    private final TomcatWebServer tomcatWebServer;
    private volatile boolean shuttingDown = false;

    public void shutDownGracefully(GracefulShutdownCallback callback) {
        if (this.shuttingDown) {
            return;
        }
        this.shuttingDown = true;
        // 1. 停止连接器接收新请求
        tomcatWebServer.stopConnectors();
        // 2. 等待活跃请求完成
        waitForActiveRequests(GRACEFUL_SHUTDOWN_TIMEOUT);
        // 3. 回调通知关闭完成
        callback.shutdownComplete(GracefulShutdownResult.IMMEDIATE);
    }

    private void waitForActiveRequests(long timeoutMs) {
        while (hasActiveRequests() && timeoutMs > 0) {
            long waitMs = Math.min(100, timeoutMs);
            Thread.sleep(waitMs);
            timeoutMs -= waitMs;
        }
    }
}
```

### 1.4 如何确保 Tomcat 连接器正确关闭

```java
@Configuration
public class GracefulShutdownConfig implements ServletContextInitializer {

    @Bean
    public TomcatConnectorCustomizer connectorCustomizer() {
        return connector -> connector.setProperty(
            "connectionTimeout", "5000"
        );
    }

    @Bean
    public SpringApplicationShutdownHookHandling shutdownHookHandling() {
        return new SpringApplicationShutdownHookHandling();
    }
}
```

## 二、Kubernetes 环境下的优雅关闭

### 2.1 Pod 生命周期和关闭时序

```
kubectl delete pod
    ↓
1. Pod 进入 Terminating 状态
2. PreStop Hook 开始执行（如果有）
3. K8s 从 Service Endpoint 移除该 Pod
4. SIGTERM 发送给进程
5. 等待 terminationGracePeriodSeconds（默认 30s）
6. SIGKILL 强制杀死
```

### 2.2 PreStop Hook 配置

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: my-service
        image: my-service:latest
        lifecycle:
          preStop:
            exec:
              command:
              - /bin/sh
              - -c
              - |
                # 先踢出负载均衡
                curl -X POST http://localhost:8081/actuator/shutdown-pause
                # 等待一段时间，让负载均衡完成更新
                sleep 5
                # 触发 Spring Boot 优雅关闭
                curl -X POST http://localhost:8081/actuator/shutdown
      terminationGracePeriodSeconds: 60
```

### 2.3 微服务注册中心的优雅摘除

#### Nacos

```yaml
spring:
  cloud:
    nacos:
      discovery:
        # 关闭时自动摘除
        ephemeral: true
        # 健康检查间隔
        heart-beat-interval: 5s
```

#### Spring Cloud Gateway 灰度下线

```yaml
management:
  endpoint:
    shutdown-pause:
      enabled: true
  endpoints:
    web:
      exposure:
        include: shutdown-pause, shutdown
```

```java
// 增加一个下线通知接口
@RestController
public class ShutdownController {

    @PostMapping("/offline")
    public Result<Void> offline() {
        // 1. 从 Nacos/Eureka 摘除
        registration.deregister();
        // 2. 标记服务为不可用
        HealthStatusManager.setStatus(Status.DOWN);
        // 3. 等待 10s 让负载均衡感知
        Thread.sleep(10000);
        // 4. 触发优雅关闭
        SpringApplication.exit(applicationContext);
        return Result.success();
    }
}
```

## 三、平滑上线（预热 + 慢启动）

### 3.1 应用预热问题

刚启动的应用 JIT 缓存没预热，第一次并发请求性能极差：

```
新 Pod 启动 → 请求涌入 → CPU 100% (JIT 编译) → 超时/失败
```

### 3.2 K8s Readiness + Liveness 探针

```java
@Configuration
public class StartupHealthConfig {

    // 应用启动后的预热延迟
    @Bean
    public HealthIndicator warmupHealthIndicator() {
        return () -> {
            long uptime = ManagementFactory.getRuntimeMXBean().getUptime();
            if (uptime < 30_000) { // 前 30 秒
                return Health.down()
                    .withDetail("warming", true)
                    .withDetail("uptime", uptime + "ms")
                    .build();
            }
            return Health.up().build();
        };
    }
}
```

### 3.3 K8s 配置

```yaml
spec:
  template:
    spec:
      containers:
      - name: my-service
        # ... 镜像配置 ...
        startupProbe:          # 启动探针
          httpGet:
            path: /actuator/health/liveness
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 30 # 最多等 150 秒
        readinessProbe:        # 就绪探针
          httpGet:
            path: /actuator/health/readiness
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:         # 存活探针
          httpGet:
            path: /actuator/health/liveness
            port: 8080
          periodSeconds: 10
          failureThreshold: 3
```

### 3.4 Spring Boot 各阶段的探针设计

```
[启动中]                                  [正常运行]            [关闭中]
    |          30s 预热           |           ...             |   graceful 30s
    |  Liveness: UP              |  Liveness: UP             |  Liveness: DOWN
    |  Readiness: DOWN           |  Readiness: UP            |  Readiness: DOWN
    |  (不接收流量)               |  (正常接收)               |  (已摘除)
```

### 3.5 负载均衡的慢启动

#### Nginx

```nginx
upstream my_service {
    server 10.0.0.1:8080 weight=5 slow_start=30s;
    server 10.0.0.2:8080 weight=5 slow_start=30s;
}
```

#### Spring Cloud LoadBalancer

```yaml
spring:
  cloud:
    loadbalancer:
      retry:
        enabled: true
      # 自定义响应式客户端
      clients:
        - name: my-service
          configuration:
            # 连接超时
            connect-timeout: 2000
            # 响应超时  
            read-timeout: 5000
```

## 四、实战案例：0 宕机滚动更新

### 4.1 Deployment 策略

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # 最多多启动 1 个新 Pod
      maxUnavailable: 0    # 不允许不可用 Pod
  template:
    spec:
      terminationGracePeriodSeconds: 60
      containers:
      - name: app
        lifecycle:
          preStop:
            exec:
              command:
              - sh
              - -c
              - |
                sleep 10
                curl -sf -XPOST localhost:8080/actuator/shutdown-pause || true
```

### 4.2 完整关闭时序

```
1. K8s 启动新 Pod 1
2. 新 Pod 1 通过 startupProbe，readinessProbe 开始返回 UP
3. K8s 将新 Pod 1 加入 Service Endpoint（开始接收流量）
4. K8s 准备关闭老的 Pod 3
5. PreStop 执行（sleep 5）
6. K8s 从 Service Endpoint 移除 Pod 3
7. SIGTERM → graceful shutdown → 等待活跃请求完成
8. Pod 3 完全停止
9. 重复直到全部更新完毕 ✓
```

## 五、常见问题排查

| 现象 | 原因 | 解决方案 |
|------|------|----------|
| 关闭时仍有 502 | PreStop 没执行 / graceful 关闭没配 | 启用 server.shutdown=graceful |
| 新 Pod 被大量请求冲垮 | 没有预热 / readinessProbe 太快 | readiness 延迟 30s |
| 滚动更新有毛刺 | maxUnavailable 没设 0 | 设置为 0 |
| 关闭时间不够 | 长事务/长连接处理慢 | 增加 terminationGracePeriodSeconds |
| 注册中心摘除慢 | Nacos 心跳间隔长 | 减小心跳间隔，显式调用 deregister |

## 六、面试追问

> **Q：server.shutdown=graceful 和 K8s PreStop 什么关系？**
> A：PreStop 在前，graceful shutdown 在后。PreStop 负责摘除流量，graceful shutdown 负责处理完已有请求。两者配合使用。

> **Q：如果请求超过 graceful timeout 会怎样？**
> A：超时未完成的请求会被强制终止。解决方案：增加 timeout，或在业务层做异步处理、响应缓存。

> **Q：长连接（WebSocket）怎么优雅关闭？**
> A：关闭前发送一个关闭帧通知客户端重连，然后等待一段时间再正式关闭。

---

**总结：** 优雅关闭 + 健康检查 + 滚动更新 = 零宕机发布。这三者缺一不可，任何一个环节出问题都会导致现网故障。
