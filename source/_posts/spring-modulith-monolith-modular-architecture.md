---
title: 【架构实战】Spring Modulith 单体模块化架构：一种被忽视的优雅架构方案
date: 2026-07-30 08:00:00
tags:
  - Java
  - Spring Modulith
  - 架构
  - 模块化
categories:
  - Java
  - 架构设计
author: 东哥
---

# 【架构实战】Spring Modulith 单体模块化架构：一种被忽视的优雅架构方案

## 前言：微服务不是银弹

你可能听过这样的故事：某个团队把单体应用拆成 50 个微服务，结果运维复杂度爆炸，一个简单的联调要跨 5 个服务，分布式事务堆成山，最后不得不合并回来。

> 面试官：什么时候不应该用微服务？有没有比微服务更好的选择？

**微服务的本质是将复杂度从代码层转移到运维层**。如果你的团队规模小于 20 人，业务边界不清晰，或者对延迟敏感 —— 也许你需要一个折中方案：**模块化单体（Modular Monolith）**。

Spring Modulith 正是 Spring 官方为解决"拆还是不拆"这一世纪难题推出的答案。

## 一、什么是 Spring Modulith

Spring Modulith 是 Spring 团队在 2022 年启动的项目，核心思想是：**在单体应用内部实现模块化，当需要时再平滑拆分微服务**。

### 1.1 核心特性

| 特性 | 说明 |
|------|------|
| 模块化验证 | 编译期/测试期检测模块依赖违规 |
| 模块间事件驱动 | 使用 ApplicationEvent 实现松耦合 |
| 文档生成 | 自动生成 C4 模型模块图 |
| 模块测试 | 支持按模块隔离测试 |
| 演进能力 | 模块可平滑抽取为独立服务 |

### 1.2 传统分层 vs 模块化

**传统分层架构：**
```
controller → service → repository
    ↑           ↑          ↑
order/  → user/  → payment/
（逻辑松散，依赖混乱）
```

**Spring Modulith：**
```
┌──────────────────────┐
│   order-module       │
│  ┌────────────────┐  │
│  │ OrderController│  │
│  │ OrderService   │  │ → → → event bus
│  │ OrderRepository│  │
│  └────────────────┘  │
└──────┬───────────────┘
       │ 仅通过 API 类通信
┌──────▼───────────────┐
│   payment-module      │
│  ┌────────────────┐  │
│  │ PaymentService  │  │
│  │ PaymentRepo    │  │
│  └────────────────┘  │
└──────────────────────┘
```

## 二、快速上手

### 2.1 添加依赖

```xml
<dependency>
    <groupId>org.springframework.modulith</groupId>
    <artifactId>spring-modulith-starter-core</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.modulith</groupId>
    <artifactId>spring-modulith-starter-test</artifactId>
    <scope>test</scope>
</dependency>
```

Spring Boot 3.x + Spring Modulith 1.0+ 配合使用最顺畅。

### 2.2 模块定义

Spring Modulith 通过包结构来定义模块：

```
com.example.app
├── order/
│   ├── internal/
│   │   ├── OrderRepository.java
│   │   └── OrderInternalService.java
│   └── OrderManagement.java         ← 模块 API（公开类）
│
├── payment/
│   ├── internal/
│   │   ├── PaymentGatewayClient.java
│   │   └── PaymentProcessor.java
│   └── PaymentService.java          ← 模块 API
│
└── Application.java
```

**关键约定：**

- 每个模块一个顶级包
- `internal/` 包下的类不对外暴露
- 模块边界外的类仅能访问其他模块的**非 internal 类**
- Application 主类使用 `@EnableModulith` 启用功能

### 2.3 模块间调用

**方式一：直接调用（紧耦合）**
```java
// order 模块中直接调用 payment 模块的 API 类
@Service
public class OrderService {
    private final PaymentService paymentService;
    
    public void placeOrder(Order order) {
        // 直接方法调用
        PaymentResult result = paymentService.charge(order.getAmount());
    }
}
```

**方式二：事件驱动（松耦合，推荐）**
```java
// order 模块发布事件
@Service
public class OrderService {
    private final ApplicationEventPublisher events;
    
    public void placeOrder(Order order) {
        saveOrder(order);
        // 发布事件，payment 模块异步处理
        events.publishEvent(new OrderPlacedEvent(order.getId(), order.getAmount()));
    }
}

// payment 模块监听事件
@Service
public class PaymentEventHandler {
    @Async
    @TransactionalEventListener
    void on(OrderPlacedEvent event) {
        processPayment(event.orderId(), event.amount());
    }
}
```

事件驱动让两个模块只依赖事件结构体，**不依赖对方的具体实现**。

### 2.4 模块化验证

Spring Modulith 可以在测试中自动验证模块边界：

```java
@ApplicationModuleTest
class ApplicationModularityTest {
    
    @Test
    void verifyModularStructure() {
        // 验证模块依赖合规，自动检测违规引用
    }
    
    @Test
    void verifyModuleDependencies(ApplicationModules modules) {
        modules.verify()
              .forEach(System.out::println);
    }
}
```

如果某个类从 `payment.internal` 导入了不应暴露的类，测试会**直接失败**。

## 三、深入原理

### 3.1 模块检测机制

Spring Modulith 使用 **ASM 字节码分析**，而非运行时反射来检测模块依赖：

```
ClassFile → ASM Reader → Method Body → 
找 REF_invokeSpecial/REF_invokeVirtual → 
检查目标类所在包 → 判断是否跨模块访问 internal 类
```

这意味着**编译时就已检测完毕**，无需启动应用。

### 3.2 事件分发机制

Spring Modulith 在标准 `ApplicationEventPublisher` 之上增加了事件路由和持久化能力：

```java
// 启用事件持久化
@EnableModulith(eventPublishingMode = EventPublishingMode.PERSISTED)
```

持久化模式下，事件先写入数据库，再由后台任务投递：

```
发布方 → 数据库(events) → 后台任务投递 → 消费者
```

这带来了三个好处：
1. **事务完整**：事件写入与业务操作在同一事务中
2. **可靠投递**：消费者失败后可重试
3. **消息追踪**：方便排查问题

### 3.3 文档生成

```java
@ApplicationModuleTest
class DocumentationTest {
    
    @Test
    void generateModuleDocumentation(ApplicationModules modules) {
        // 生成 C4 模型模块图
        new Documenter(modules)
            .writeDocumentation(Paths.get("target/modulith-docs"));
    }
}
```

生成的结果包含：

- 模块依赖图（PlantUML）
- 各模块公开 API 列表
- 模块间事件流图
- 包结构 PDF 报告

## 四、与微服务的对比

### 4.1 决策矩阵

| 维度 | 模块化单体 | 微服务 |
|------|-----------|--------|
| 代码复杂度 | 中等 | 高（跨服务调用） |
| 运维复杂度 | 低（1个应用） | 高（N个应用） |
| 部署粒度 | 整体部署 | 独立部署 |
| 团队自治 | 弱（共享仓库） | 强（独立仓库） |
| 分布式事务 | 不需要 | 需要 |
| 调试体验 | 好 | 差（跨服务链路） |
| 性能 | 优（本地调用） | 中（网络开销） |
| 独立扩缩容 | 不能 | 能 |

### 4.2 演进路径

Spring Modulith 设计上直接支持从单体到微服务的**增量演进**：

```
阶段一：混乱单体
→ 重新组织包结构，定义模块边界
   ↓
阶段二：模块化单体（Spring Modulith）
→ 模块间改为事件通信，引入事件持久化
   ↓
阶段三：提取独立服务
→ Order模块 → 独立的 order-service.jar
→ 事件通信降级为 Kafka/RabbitMQ 消息
   ↓
阶段四：分布式微服务
→ 完全解耦，独立部署
```

```java
// 阶段二 → 阶段三 的转换示例
// 原来的事件监听器（同进程）
@Component
class PaymentHandler {
    @TransactionalEventListener
    void on(OrderPlacedEvent event) { ... }
}

// 提取为独立服务后，改为消息队列监听器
@Component
class PaymentHandler {
    @KafkaListener(topics = "order-events")
    void on(OrderPlacedEvent event) { ... }
}
```

**实际上只需修改监听器实现**，事件结构体和业务逻辑完全复用。

## 五、最佳实践

### 5.1 模块划分原则

1. **高内聚低耦合**：一个模块应该包含完整的业务能力
2. **按业务能力划分**：不要按技术分层分模块
   ✅ `order`、`payment`、`inventory`、`notification`
   ❌ `controller`、`service`、`repository`
3. **模块大小适中**：5~15 个类为一个模块，太大需要拆分，太小没意义
4. **禁止循环依赖**：A 依赖 B，B 绝不能依赖 A
5. **API 最小化**：公开类越少越好，默认都 internal

### 5.2 依赖方向规则

```
依赖方向：业务上层 → 基础能力

order → payment
order → inventory
payment → notification
notification → （无下层依赖）
```

如果发现双向依赖，通常意味着需要引入中间事件。

### 5.3 测试策略

```java
// 1. 模块隔离测试 - 只加载当前模块的 Bean
@ModuleTest(OrderModule.class)
class OrderModuleTest {
    
    @Autowired
    OrderManagement orders;
    
    @Test
    void shouldPlaceOrder() {
        // 只测试 order 模块逻辑
    }
}

// 2. 事件行为测试
@ModuleTest(modules = {OrderModule.class, PaymentModule.class})
class OrderPaymentIntegrationTest {
    
    @Test
    void shouldProcessPaymentOnOrder() {
        orders.placeOrder(...);
        // 验证 payment 模块被正确触发
    }
}
```

### 5.4 生产配置

```yaml
spring:
  modulith:
    events:
      # 启用事件持久化
      persistence:
        enabled: true
      # 事件清理（31天后清理已完成的事件）
      cleanup:
        completed-events-older-than: 31d
```

## 六、常见问题

### Q1: Spring Modulith 和微服务怎么选？

> 团队小、业务边界不清晰、对延迟敏感 → 选 Modulith。团队大（>20人/服务）、需要独立部署扩缩容 → 选微服务。**大多数项目从 Modulith 开始是最稳妥的**。

### Q2: 我可以用 Modulith 实现 DDD 吗？

> 完全可以！Modulith 的模块天然对应 DDD 的 Bounded Context（限界上下文）。每个模块就是一个 BC，模块 API 对应 Aggregate 的对外访问点。事件驱动对应 Domain Event。

### Q3: Modulith 事件持久化会不会有性能问题？

> 对于大多数业务系统，数据库写入事件的额外开销在 **1-3ms**，完全可以忽略。如果对延迟极度敏感（如高频交易），可以使用内存模式。

## 总结

Spring Modulith 不是"反对微服务"，而是**反对盲目微服务**。它提供了一条务实的技术路线：

```
混乱单体 → 模块化单体 → 有选择的微服务
```

对于绝大多数 Java 后端团队来说，**模块化单体才是最优起点**——它让你在享受单体优势的同时，保留了未来拆分微服务的灵活性。从这个角度看，Spring Modulith 可能是 2024-2026 年间被严重低估的 Spring 项目。
