---
title: 混沌工程：系统稳定性实验指南
date: 2026-06-18 08:00:00
tags:
  - 混沌工程
  - 稳定性
  - 故障注入
  - Chaos Mesh
categories:
  - 运维
author: 东哥
---

# 混沌工程：系统稳定性实验指南

## 一、混沌工程概述

### 1.1 什么是混沌工程

混沌工程（Chaos Engineering）是一门在分布式系统上进行实验的学科，旨在建立对系统应对混乱和不可预测情况能力的信心。它通过主动注入故障来验证系统的弹性。

### 1.2 核心原则

```
混沌工程的五个原则:
1. 定义稳态 → 系统正常工作时是什么状态？
2. 提出假设 → 系统在故障下仍能维持稳态吗？
3. 引入变量 → 注入故障（延迟、崩溃、网络分区）
4. 验证假设 → 比较实验组和对照组的差异
5. 改进系统 → 修复发现的问题，扩大实验范围
```

### 1.3 与传统测试的区别

| 维度 | 传统测试 | 混沌工程 |
|------|---------|---------|
| 目标 | 验证功能正确 | 验证系统弹性 |
| 方法 | 预定义的测试用例 | 探索性实验 |
| 故障类型 | 单点故障 | 复杂交互故障 |
| 通过标准 | 功能全通过 | 指标在可接受范围内 |
| 执行环境 | 测试环境 | 生产环境（谨慎） |
| 结果类型 | 通过/失败 | 发现盲区 |

### 1.4 Chaos Engineering Maturity Model

| 级别 | 名称 | 特征 | 实施阶段 |
|------|------|------|---------|
| 0 | 被动 | 无主动性实验 | 初始 |
| 1 | 手动 | 手动执行混沌实验 | 定义 |
| 2 | 自动化 | 自动化故障注入 | 管理 |
| 3 | 持续化 | CI/CD 集成混沌实验 | 度量 |
| 4 | 自适应 | 自动修复，系统自愈 | 优化 |

## 二、混沌工程工具选型

### 2.1 主流工具对比

| 工具 | 社区活跃度 | 安装复杂度 | 故障类型 | Kubernetes 支持 | 调度能力 |
|------|-----------|-----------|---------|----------------|---------|
| Chaos Mesh | 高 (CNCF) | 低 (Helm) | Pod/网络/压力/DNS | 原生 | Cron/Workflow |
| LitmusChaos | 高 (CNCF) | 中 (Operator) | Pod/网络/Disk | 原生 | ChaosSchedule |
| ChaosBlade | 中 (阿里) | 低 (二进制) | CPU/内存/网络/磁盘 | 命令行 | 外部调度 |
| Gremlin | 商业 | 低 (Agent) | 丰富 | 支持 | Web控制台 |
| AWS FIS | 中 (AWS) | 低 | 基础设施 | EKS | 模板化 |

### 2.2 Chaos Mesh 安装

```bash
# 使用 Helm 安装 Chaos Mesh
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

# 安装到 chaos-mesh 命名空间
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace=chaos-mesh \
  --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --version 2.7.0

# 验证安装
kubectl get pods -n chaos-mesh
kubectl get crd | grep chaos
```

## 三、核心故障注入实验

### 3.1 Pod 故障

```yaml
# pod-kill.yaml - 随机杀死 Pod
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-kill-example
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one  # 每次杀死一个 Pod
  duration: "60s"
  selector:
    namespaces:
      - production
    labelSelectors:
      app: order-service
  scheduler:
    cron: "@every 5m"  # 每5分钟执行一次
```

```yaml
# pod-failure.yaml - Pod 不可用但 Pod 对象保留
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-failure-example
  namespace: chaos-mesh
spec:
  action: pod-failure
  mode: one
  duration: "120s"
  selector:
    namespaces:
      - production
    labelSelectors:
      app: payment-service
  scheduler:
    cron: "@every 30m"
  gracePeriod: 30  # 优雅终止等待时间
```

### 3.2 网络故障

```yaml
# network-delay.yaml - 注入网络延迟
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: network-delay
  namespace: chaos-mesh
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - production
    labelSelectors:
      app: user-service
  delay:
    latency: "1000ms"
    correlation: "50"
    jitter: "200ms"
  duration: "300s"
  scheduler:
    cron: "@every 2h"
---
# network-partition.yaml - 网络分区
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: network-partition
  namespace: chaos-mesh
spec:
  action: partition
  mode: all
  selector:
    namespaces:
      - production
    labelSelectors:
      app: api-gateway
  direction: to
  target:
    mode: all
    selector:
      namespaces:
        - production
      labelSelectors:
        app: order-service
  duration: "60s"
```

### 3.3 压力注入

```yaml
# cpu-stress.yaml - CPU 压力
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: cpu-stress
  namespace: chaos-mesh
spec:
  mode: one
  selector:
    namespaces:
      - production
    labelSelectors:
      app: order-service
  stressors:
    cpu:
      workers: 2
      load: 80
      options: ["--cpu-method all"]
  duration: "180s"
---
# memory-stress.yaml - 内存压力
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: memory-stress
  namespace: chaos-mesh
spec:
  mode: one
  selector:
    namespaces:
      - production
    labelSelectors:
      app: recommendation-service
  stressors:
    memory:
      workers: 4
      size: "512MB"
      options: ["--vm", "1", "--vm-bytes", "512M", "--vm-hang", "0"]
  duration: "120s"
```

### 3.4 DNS 故障

```yaml
# dns-error.yaml - DNS 错误
apiVersion: chaos-mesh.org/v1alpha1
kind: DNSChaos
metadata:
  name: dns-error
  namespace: chaos-mesh
spec:
  action: error
  mode: all
  selector:
    namespaces:
      - production
    labelSelectors:
      app: payment-service
  patterns:
    - "*payments*"  # 只影响 payments 的 DNS 解析
    - "!*production*"  # 排除 production 域名
  duration: "120s"
```

## 四、Java 应用混沌工程 Spring 集成

### 4.1 熔断与重试

```java
@Configuration
public class ChaosReadyConfiguration {
    
    @Bean
    public Customizer<Resilience4JCircuitBreakerFactory> circuitBreakerCustomizer() {
        return factory -> factory.configureDefault(id -> new Resilience4JConfigBuilder(id)
            .circuitBreakerConfig(CircuitBreakerConfig.custom()
                .slidingWindowSize(100)
                .minimumNumberOfCalls(10)
                .failureRateThreshold(50)          // 50% 失败开启熔断
                .waitDurationInOpenState(Duration.ofSeconds(30))
                .permittedNumberOfCallsInHalfOpenState(5)
                .recordExceptions(IOException.class, TimeoutException.class)
                .build())
            .timeLimiterConfig(TimeLimiterConfig.custom()
                .timeoutDuration(Duration.ofSeconds(3))
                .build())
            .build());
    }
    
    @Bean
    public Customizer<Resilience4JRetryFactory> retryCustomizer() {
        return factory -> factory.configureDefault(id -> RetryConfig.custom()
            .maxAttempts(3)
            .waitDuration(Duration.ofMillis(500))
            .retryExceptions(IOException.class, TimeoutException.class)
            .ignoreExceptions(BusinessException.class)
            .build());
    }
}

@Service
public class OrderService {
    
    @CircuitBreaker(name = "paymentService", fallbackMethod = "paymentFallback")
    @Retry(name = "paymentService")
    @Bulkhead(name = "paymentService", type = Bulkhead.Type.THREADPOOL)
    public PaymentResult processPayment(Order order) {
        return paymentClient.charge(order.getUserId(), order.getTotalAmount());
    }
    
    // 熔断降级
    private PaymentResult paymentFallback(Order order, Throwable t) {
        log.warn("支付服务不可用，订单 {} 进入等待队列", order.getOrderId());
        return PaymentResult.deferred(order.getOrderId());
    }
}
```

### 4.2 运行时故障检测

```java
@Component
public class FaultDetectionService {
    
    private final HealthEndpoint healthEndpoint;
    private final MeterRegistry meterRegistry;
    
    // 检测慢调用
    @EventListener
    public void onSlowCallDetected(SlowCallEvent event) {
        log.warn("慢调用检测: service={}, duration={}ms, threshold={}ms",
            event.serviceName(), event.duration(), event.threshold());
        
        // 记录指标
        meterRegistry.counter("fault.slow.calls",
            "service", event.serviceName()).increment();
    }
    
    // 检测连接池耗尽
    @EventListener
    public void onConnectionPoolExhausted(ConnectionPoolExhaustedEvent event) {
        log.error("连接池耗尽: pool={}, active={}, max={}",
            event.poolName(), event.activeCount(), event.maxSize());
        
        // 发送告警
        alertService.sendAlert(Alert.critical("连接池耗尽")
            .withLabel("pool", event.poolName())
            .withAnnotation("active", String.valueOf(event.activeCount()))
            .build());
    }
}
```

## 五、实验设计与执行

### 5.1 实验计划模板

```yaml
实验计划: 数据库连接故障对订单服务的影响

实验编号: CE-2026-001
负责人: 架构组
目标系统: order-service v2.1
实验窗口: 2026-06-18 14:00-15:00 (低峰期)

稳态指标:
  - 订单成功率 > 99.5%
  - P95 延迟 < 500ms
  - 错误率 < 0.5%

故障注入:
  - MySQL 连接池限制到 5（模拟连接耗尽）
  - 持续 5 分钟
  - 注入比例: 30% 的 Pod

预期行为:
  - 连接池耗尽时请求应排队等待
  - 超过超时的请求应优雅降级
  - 连接恢复后自动恢复正常

回滚计划:
  - 自动: 实验结束后自动恢复
  - 手动: kubectl delete chaos mysql-connection-exhaust
```

### 5.2 Chaos Mesh Workflow

```yaml
# 复杂的工作流实验
apiVersion: chaos-mesh.org/v1alpha1
kind: Workflow
metadata:
  name: order-service-resilience-test
  namespace: chaos-mesh
spec:
  entry: serial-flow
  templates:
  - name: serial-flow
    templateType: Serial
    children:
      - baseline-check
      - chaos-inject
      - recovery-check
  
  - name: baseline-check
    templateType: Task
    task:
      container:
        container: busybox
        command:
          - sh
          - -c
          - |
            # 检查基线指标
            echo "检查稳态"
            for i in 1 2 3; do
              curl -s http://prometheus:9090/api/v1/query \
                --data-urlencode 'query=rate(http_requests_total{job="order-service",status="5xx"}[1m])'
              sleep 5
            done
      duration: "30s"
  
  - name: chaos-inject
    templateType: Parallel
    children:
      - pod-kill
      - network-delay
      - cpu-stress
  
  - name: pod-kill
    templateType: PodChaos
    podChaos:
      action: pod-kill
      mode: one
      selector:
        namespaces:
          - production
        labelSelectors:
          app: order-service
      duration: "180s"
  
  - name: network-delay
    templateType: NetworkChaos
    networkChaos:
      action: delay
      mode: one
      selector:
        namespaces:
          - production
        labelSelectors:
          app: order-service
      delay:
        latency: "500ms"
      duration: "180s"
  
  - name: cpu-stress
    templateType: StressChaos
    stressChaos:
      mode: one
      selector:
        namespaces:
          - production
        labelSelectors:
          app: order-service
      stressors:
        cpu:
          workers: 1
          load: 70
      duration: "180s"
  
  - name: recovery-check
    templateType: Task
    task:
      container:
        container: busybox
        command:
          - sh
          - -c
          - |
            # 验证恢复后指标是否回到基线
            echo "验证恢复..."
            curl -s http://prometheus:9090/api/v1/query \
              --data-urlencode 'query=rate(http_requests_total{job="order-service",status="5xx"}[1m])'
      duration: "60s"
```

### 5.3 监控与告警

```yaml
# Chaos 实验的 Prometheus 告警
groups:
- name: chaos-experiment
  rules:
  - alert: ChaosExperimentFailure
    expr: increase(chaos_mesh_experiment_failed_count[5m]) > 0
    for: 1m
    labels:
      severity: warning
      team: sre
    annotations:
      summary: "混沌实验失败: {{ $labels.name }}"
      description: "实验 {{ $labels.name }} 在 {{ $labels.namespace }} 命名空间执行失败"
  
  - alert: ChaosExperimentRunningTooLong
    expr: chaos_mesh_experiment_duration_seconds{status="running"} > 3600
    labels:
      severity: warning
    annotations:
      summary: "实验运行超过1小时"
```

## 六、成熟度与最佳实践

### 6.1 实验成熟度等级

| 等级 | 实验范围 | 频率 | 自动化 | 反馈机制 |
|------|---------|------|--------|---------|
| L1 | 单组件 | 每周 | 手动 | 人工查看 |
| L2 | 多组件 | 每天 | 定时 | 自动告警 |
| L3 | 全链路 | 每部署 | CI/CD 集成 | Dashboard |
| L4 | 生产环境 | 持续 | 游戏日 | 自动回滚 |

### 6.2 游戏日（Game Day）实践

```yaml
# Game Day 工作流
GameDay: "2026年存储器故障演练"

参与人员:
  - SRE 团队 (执行)
  - 开发团队 (观察)
  - 产品经理 (观察)

时间线:
  14:00 - 场景介绍
  14:15 - 注入故障: 数据库主库宕机
  14:20 - 预期: 应用自动切换到只读副本
  14:25 - 注入故障: 所有 Redis 节点不可用
  14:30 - 预期: 降级到数据库直查
  14:35 - 注入故障: 网络延迟 1000ms
  14:40 - 预期: 熔断器打开，部分请求降级
  14:45 - 恢复所有故障
  14:50 - 复盘总结

判定标准:
  - 核心流程: 订单创建成功率 > 95%
  - 非核心流程: 个性化推荐降级
  - 数据一致性: 最终一致
```

### 6.3 常见陷阱

| 陷阱 | 表现 | 解决方案 |
|------|------|---------|
| 实验盲区 | 只测试已知弱点 | 随机故障注入，扩大覆盖面 |
| 实验疲劳 | 告警太多被忽略 | 设置合理的告警阈值 |
| 爆炸半径过大 | 影响太多用户 | 从一小部分实例开始（one模式） |
| 未定义稳态 | 不知道正常状态 | 提前建立基线指标 |
| 缺乏回滚 | 故障无法快速恢复 | 设置 duration + 手动终止通道 |
| 只做不分析 | 实验后没有改进 | 实验后必须复盘和改进 |

## 七、生产环境注意事项

### 7.1 安全准则

```yaml
# 生产环境安全配置
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: production-safe-kill
spec:
  action: pod-kill
  mode: fixed-percent
  value: "10"    # 最多杀死 10% 的 Pod
  selector:
    namespaces:
      - production
    labelSelectors:
      app: order-service
  duration: "30s"
  # 安全配置
  scheduler:
    cron: "@every 6h"
    # 避开高峰时段
    excludingTimes:
      - weekdays: ["mon-fri"]
        hours: [10-12, 14-16]
```

### 7.2 CI/CD 集成

```yaml
# GitHub Actions 集成混沌测试
name: Chaost Test Pipeline
on:
  deployment:
    environments: staging

jobs:
  resilience-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Deploy to Staging
        run: |
          kubectl apply -f k8s/staging
          kubectl rollout status deployment/order-service -n staging
      
      - name: Run Baseline Check
        run: |
          echo "执行基线检查..."
          curl -s http://prometheus-staging:9090/api/v1/query \
            --data-urlencode 'query=up{job="order-service"}'
      
      - name: Inject Chaos
        run: |
          kubectl apply -f chaos/network-delay-staging.yaml
          kubectl apply -f chaos/pod-kill-staging.yaml
      
      - name: Verify Resilience
        run: |
          echo "验证弹性..."
          ./scripts/verify-resilience.sh
      
      - name: Cleanup
        if: always()
        run: |
          kubectl delete chaos --all -n staging
      
      - name: Publish Report
        if: always()
        run: |
          ./scripts/publish-chaos-report.sh
```

## 八、案例：电商系统混沌实验

### 8.1 系统架构

```
用户 → [API Gateway] → [Order Service] → [Payment Service]
                 ↓                    ↓
          [User Service]        [Inventory Service]
                 ↓                    ↓
            [MySQL/RDS]         [Redis Cache]
```

### 8.2 实验场景

| 场景 | 注入故障 | 预期行为 | 真实表现 | 改进项 |
|------|---------|---------|---------|-------|
| 订单服务 Pod 宕机 | kill 50% Pod | 95% 请求成功 | 98% 成功 | 无 |
| 支付服务延迟 | 注入 2s 延迟 | 熔断降级 | 熔断开启但恢复慢 | 调整熔断参数 |
| Redis 缓存崩溃 | 删除所有 Redis | 降级到数据库 | 数据库压力突增 3倍 | 添加连接池限制 |
| 网络分区 | 订单服务断网 | 请求排队 | 大量超时 | 添加重试+指数退避 |

### 8.3 实验结果分析

```yaml
实验报告 CE-2026-001

实验结果:
  - 订单服务 Pod 宕机: ✅ 通过 (成功率 98%)
  - 支付服务延迟: ⚠️ 有风险 (熔断恢复需要90s，太长)
  - Redis 缓存崩溃: ✅ 通过 (降级正常，有压力但可控)
  - 网络分区: ❌ 失败 (重试风暴导致依赖服务过载)

改进项:
  1. 支付服务熔断器 WaitDurationInOpenState 从 60s 改为 30s
  2. 订单服务添加 semaphore-isolation 隔离网络调用
  3. 所有远程调用添加 exponentialBackoff 策略
  4. 添加分布式重试限流，防止重试风暴
```

## 总结

混沌工程不是制造混乱，而是通过受控实验主动发现系统弱点，从而建立对生产系统弹性的信心。从简单的 Pod 杀死开始，逐步扩展到网络故障、压力测试、DNS 故障等更复杂的场景，结合熔断、限流、降级等弹性模式，最终构建一个能够从容应对各种故障的弹性系统。

**实施建议**：从非生产环境的自动化测试开始，逐步过渡到生产环境的游戏日演练。不要一次性注入太多故障，保持小步快跑，每次实验都能带来确定的改进价值。混沌工程的最终目标是让故障成为预期而非意外。
