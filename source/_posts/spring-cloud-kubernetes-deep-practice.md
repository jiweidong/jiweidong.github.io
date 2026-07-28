---
title: 【云原生实战】Spring Cloud Kubernetes 微服务在 K8s 中的部署与服务治理
date: 2026-07-28 08:00:00
tags:
  - Java
  - Spring Cloud
  - Kubernetes
  - 云原生
categories:
  - Java
  - 微服务
author: 东哥
---

# 【云原生实战】Spring Cloud Kubernetes 微服务在 K8s 中的部署与服务治理

## 一、为什么需要 Spring Cloud Kubernetes？

Spring Cloud 在传统微服务架构中提供了服务发现（Eureka/Nacos）、配置管理（Config Server）、负载均衡（Ribbon/LoadBalancer）等能力。当微服务迁移到 Kubernetes 后，很多基础设施能力 K8s 已经内置：

| 能力 | 传统 Spring Cloud | Kubernetes 原生 | Spring Cloud K8s |
|------|------------------|----------------|-----------------|
| 服务发现 | Eureka / Nacos | Service + DNS | `@K8sServiceDiscovery` |
| 配置管理 | Config Server | ConfigMap / Secret | `@ConfigMapPropertySource` |
| 负载均衡 | Ribbon | Service (RoundRobin) | 内置 K8s Service |
| 健康检查 | Actuator / /health | Liveness / Readiness Probes | Probes 集成 |
| 命名空间 | 手动管理 | Namespace 隔离 | 原生支持 |

**Spring Cloud Kubernetes** 的作用是 **桥接**：让 Spring Cloud 的应用能无缝利用 Kubernetes 原生能力，同时保留 Spring Cloud 编程模型的一致性。

## 二、核心模块解析

### 2.1 服务发现：spring-cloud-starter-kubernetes-client

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-kubernetes-client</artifactId>
</dependency>
```

当 Spring Cloud 应用部署在 K8s Pod 内时，会自动通过 **K8s API Server** 发现服务：

```yaml
spring:
  cloud:
    kubernetes:
      discovery:
        enabled: true
        all-namespaces: false  # 仅当前 Namespace
        filter:
          # 按标签过滤服务
          labels:
            version: stable
        primary-port-name: http  # 主端口名称
```

**工作原理**：
```
Service A → 调用 Service B
  → Spring Cloud LoadBalancer
  → KubernetesClient (Fabric8)
  → K8s API Server 查询 Service B 的 Endpoints
  → 返回 Pod IP:Port 列表
  → 负载均衡选择一个 Pod 发起请求
```

<dependency>Service Discovery 对比：

```yaml
# 传统 Eureka 模式
eureka:
  client:
    serviceUrl:
      defaultZone: http://eureka:8761/eureka/

# K8s 模式 - 不再需要 Eureka Server
spring:
  cloud:
    kubernetes:
      discovery:
        enabled: true
        # Service 名称会自动映射为 Spring Cloud 服务名
```

### 2.2 配置管理：ConfigMap & Secret

Spring Boot 应用可以自动将 K8s ConfigMap 作为 PropertySource：

```yaml
# application.yml
spring:
  cloud:
    kubernetes:
      config:
        enabled: true
        name: myapp-config      # ConfigMap 名称
        namespace: default      # Namespace
        sources:
          - name: myapp-common
          - name: myapp-${spring.profiles.active}
```

创建 ConfigMap：

```yaml
# k8s-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-config
  namespace: default
data:
  application.yaml: |
    server:
      port: 8080
    spring:
      datasource:
        url: jdbc:mysql://mysql-service:3306/db
        username: root
        password: ${DB_PASSWORD}  # Secret 引用
```

Secret 挂载：

```yaml
spring:
  cloud:
    kubernetes:
      secrets:
        enabled: true
        name: myapp-secret
        paths:
          - /etc/secrets/db
```

### 2.3 负载均衡

```java
@RestController
public class OrderController {
    
    @Autowired
    private RestTemplate restTemplate;
    
    @GetMapping("/order/{id}")
    public Order getOrder(@PathVariable Long id) {
        // 服务名直接映射 K8s Service 名称
        String url = "http://user-service/api/user/" + id;
        User user = restTemplate.getForObject(url, User.class);
        return orderService.getOrder(id, user);
    }
}
```

**K8s Service 定义**：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: user-service
  labels:
    app: user-service
spec:
  selector:
    app: user-service
  ports:
    - name: http
      port: 8080
      targetPort: 8080
  type: ClusterIP  # 内部服务
```

## 三、完整实战：部署一个微服务

### 3.1 Spring Boot 应用配置

```java
@SpringBootApplication
@EnableDiscoveryClient  // 启用 K8s 服务发现
public class OrderApplication {
    public static void main(String[] args) {
        SpringApplication.run(OrderApplication.class, args);
    }
}
```

```yaml
# bootstrap.yml（优先加载）
spring:
  application:
    name: order-service
  cloud:
    kubernetes:
      reload:
        enabled: true                # 配置热更新
        monitoring-config-maps: true
        period: 5000                 # 轮询间隔
        mode: event                  # 事件驱动模式
      client:
        namespace: default
```

```yaml
# application-k8s.yml
server:
  port: 8080
spring:
  datasource:
    url: jdbc:mysql://mysql-service:3306/order_db
    hikari:
      maximum-pool-size: 10
logging:
  pattern:
    console: "%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n"
```

### 3.2 Dockerfile 优化

```dockerfile
# 多阶段构建
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn clean package -DskipTests

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar

# K8s 健康检查端点
EXPOSE 8080

ENTRYPOINT ["java", \
    "-jar", "app.jar", \
    "--spring.profiles.active=k8s"]
```

### 3.3 K8s 部署清单

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: default
  labels:
    app: order-service
    version: v1
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
        version: v1
    spec:
      serviceAccountName: spring-cloud-k8s  # 需要 RBAC 权限
      containers:
        - name: order-service
          image: registry.example.com/order-service:${BUILD_TAG}
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-secret
                  key: password
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 5
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: order-service
spec:
  selector:
    app: order-service
  ports:
    - name: http
      port: 8080
      targetPort: 8080
  type: ClusterIP
```

### 3.4 RBAC 权限配置

Spring Cloud Kubernetes 需要调用 K8s API Server，必须配置 ServiceAccount：

```yaml
# rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spring-cloud-k8s
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spring-cloud-k8s
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints", "configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spring-cloud-k8s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spring-cloud-k8s
subjects:
  - kind: ServiceAccount
    name: spring-cloud-k8s
    namespace: default
```

## 四、高级实践

### 4.1 配置热更新

Spring Cloud Kubernetes 支持 ConfigMap 变更后自动刷新 Bean：

```java
@Component
@RefreshScope  // 关键注解
public class AppConfig {
    
    @Value("${app.feature.new-checkout:false}")
    private boolean newCheckoutEnabled;
    
    public boolean isNewCheckoutEnabled() {
        return newCheckoutEnabled;
    }
}
```

配置热更新有三种模式：

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| `event` | K8s API Watch 事件驱动 | 推荐，实时性最好 |
| `polling` | 定时轮询 ConfigMap | 对 API 压力小，延迟大 |
| `webhook` | K8s Admission Webhook | 企业级，需要额外组件 |

### 4.2 Istio 集成

Spring Cloud Kubernetes 天然兼容 Istio：

```yaml
spring:
  cloud:
    kubernetes:
      discovery:
        # 当 Istio 启用时，可以关闭 Ribbon 负载均衡
        # 因为流量由 Istio Sidecar 接管
        enabled: false
```

```yaml
# Istio VirtualService 配置
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: order-service
spec:
  hosts:
    - order-service
  http:
    - match:
        - headers:
            version:
              exact: v2
      route:
        - destination:
            host: order-service
            subset: v2
    - route:
        - destination:
            host: order-service
            subset: v1
```

## 五、生产实践与踩坑

### 5.1 常见问题

**问题1：Pod 启动报 403 Forbidden**

```bash
# 错误：无法访问 API Server
# 原因：缺少 RBAC 权限
# 解决：检查 ServiceAccount + ClusterRole 配置
kubectl get clusterrolebinding spring-cloud-k8s
kubectl auth can-i list pods --as=system:serviceaccount:default:spring-cloud-k8s
```

**问题2：服务发现延迟**

```yaml
# 优化：配置缓存刷新
spring:
  cloud:
    kubernetes:
      discovery:
        cache:
          enabled: false  # 关闭缓存，实时查询
        # 或缩短缓存时间
        # cache:
        #   timeout: 5s
```

**问题3：配置热更新不生效**

```java
// 检查点：
// 1. @RefreshScope 是否加在正确的 Bean 上
// 2. ConfigMap 标签是否正确
// 3. bootstrap.yml 配置正确
// 4. 确认 ConfigMap 的 data 字段中包含 application.yaml 或 application-{profile}.yaml
```

### 5.2 性能优化

```yaml
# 减少 API Server 调用
spring:
  cloud:
    kubernetes:
      discovery:
        # 使用 K8s DNS 解析代替 API Server 查询
        use-dns: true
        # DNS 缓存 TTL
        dns-ttl-seconds: 30
      config:
        # 减少 ConfigMap Watch 连接数
        enabled: false  # 不需要配置热更新可禁用
```

## 六、面试常见追问

**Q：Spring Cloud Kubernetes 和 Spring Cloud Netflix/Eureka 可以混用吗？**

A：可以但不推荐。理论上两者可以共存，但会增加复杂度。迁移策略通常是：先在 K8s 上部署 Eureka Server，再逐步迁移到原生 K8s 服务发现。最终目标是完全移除 Eureka，减少基础设施依赖。

**Q：如果 Pod 重启导致 ConfigMap 配置丢失，如何处理？**

A：ConfigMap 是独立资源，不随 Pod 生命周期变化。但如果应用需要持久化状态，应使用 StatefulSet 配合 PVC。配置热更新推荐使用事件模式而非轮询模式，减少 API Server 压力。

**Q：K8s 环境下 @RefreshScope 和 Spring Cloud Bus 如何选择？**

A：在 K8s 环境中，@RefreshScope + ConfigMap Watch 已经足够应对大部分配置更新场景。Spring Cloud Bus 适用于需要广播刷新事件到所有实例的场景（如 Config Server + Bus）。如果已经使用 K8s ConfigMap，推荐优先使用原生方案。

## 总结

Spring Cloud Kubernetes 让传统 Spring Cloud 微服务能够平滑迁移到 K8s 平台，同时保留一致的编程体验。通过桥接 K8s 原生能力（Service、ConfigMap、Secret），减少了外部基础设施依赖（Eureka、Config Server），是实现「云原生微服务」的关键组件。掌握其原理和最佳实践，是 Java 开发者迈向云原生时代的必修课。
