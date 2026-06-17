---
title: Apache Pulsar 消息队列：架构原理与 Kafka/RabbitMQ 深度对比
date: 2026-06-17 08:30:00
tags:
  - Pulsar
  - 消息队列
  - Kafka
  - RabbitMQ
  - 中间件
categories:
  - 中间件
author: 东哥
---

# Apache Pulsar 消息队列：架构原理与 Kafka/RabbitMQ 深度对比

## 一、消息队列市场格局

消息队列是分布式系统的核心基础设施，当前主流产品各有侧重：

| 中间件 | 设计定位 | 数据模型 | 存储模型 | 适用场景 |
|--------|----------|----------|----------|----------|
| Apache Kafka | 高吞吐流处理 | 分区日志（Topic/Partition） | 磁盘顺序写，本地存储 | 日志收集、流处理、事件溯源 |
| RabbitMQ | 可靠消息路由 | AMQP Exchange/Queue | 内存+磁盘，本地存储 | 微服务异步通信、任务分发 |
| Apache Pulsar | 云原生消息流 | 统一 Producer/Consumer + Reader | 计算存储分离（BookKeeper） | 混合工作负载、多租户海量分区 |
| RocketMQ | 金融级可靠消息 | Topic/Queue | 磁盘顺序写，本地存储 | 电商交易、金融场景 |

Apache Pulsar 是近年来发展最快的消息平台，它以**计算存储分离**的架构，解决了 Kafka 在弹性扩展和高可用方面的短板。

## 二、Pulsar 架构深度解析

### 2.1 计算存储分离架构

```
                         ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐

                         │     Pulsar Broker       │
                         │  (无状态，计算层)        │
                         │                          │
  Producer ────────►     │  ┌─────────────────┐     │
  Producer ────────►     │  │ Managed Ledger   │     │
  Producer ────────►     │  │ Cache, Routing   │     │
                         │  └─────────────────┘     │
                         └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
                                   │
                                   │ write/read
                                   ▼
                         ┌─────────────────────────┐
                         │       Apache             │
                         │       BookKeeper         │
                         │   (有状态，存储层)        │
                         │                          │
                         │  ┌──────┐ ┌──────┐      │
                         │  │ BK 1 │ │ BK 2 │ ...  │
                         │  └──────┘ └──────┘      │
                         └─────────────────────────┘
```

### 2.2 与传统架构对比

```
Kafka 架构（存储耦合）：
┌─────────┐    ┌─────────┐    ┌─────────┐
│ Broker 1│    │ Broker 2│    │ Broker 3│
│ 存储P0   │    │ 存储P1   │    │ 存储P2   │
│ 存储P3   │    │ 存储P4   │    │ 存储P5   │
└─────────┘    └─────────┘    └─────────┘
 扩展/缩容需要 Rebalance，影响可用性

Pulsar 架构（计算存储分离）：
┌─────────┐    ┌─────────┐    ┌─────────┐
│ Broker 1│    │ Broker 2│    │ Broker 3│   ← 无状态，可弹性扩缩
│ (计算)   │    │ (计算)   │    │ (计算)   │
└────┬────┘    └────┬────┘    └────┬────┘
     └──────────────┼──────────────┘
                    │
┌──────────────────────────────────────────┐
│          BookKeeper 集群                  │
│   Bookie1 ─ Bookie2 ─ Bookie3 ─ Bookie4 │  ← 有状态，独立扩展
└──────────────────────────────────────────┘
```

### 2.3 Pulsar 的核心优势

| 特性 | Kafka | RabbitMQ | Pulsar |
|------|-------|----------|--------|
| 存储与计算 | 耦合 | 耦合 | **分离** |
| 分区扩容 | 需要 Rebalance，有停机时间 | 需新建队列 | **动态扩容，无需重平衡** |
| 多租户 | 需单独集群 | 虚拟主机 | **原生支持** |
| 地域复制 | 需要 MirrorMaker | 需要 Federation | **内置跨地域复制** |
| 消息TTL | 基于配置删除 | 基于 Policy | **支持** |
| 延迟消息 | 不支持原生 | 支持（插件） | **原生支持** |
| 消息消费模式 | 流式（分区） | 队列模式 | **统一支持流+队列** |
| Exactly-Once | 幂等 Producer | 不支持 | **支持** |

## 三、核心概念详解

### 3.1 Topic 模型

Pulsar 提供两种 Topic 类型：

```
1. 持久化 Topic（默认）——所有数据写入 BookKeeper
   persistent://tenant/namespace/topic-name

2. 非持久化 Topic——数据仅存于内存，用于高吞吐低延迟场景
   non-persistent://tenant/namespace/topic-name
```

### 3.2 订阅模式

Pulsar 支持四种订阅类型，这是它区别于其他消息系统的关键能力：

| 订阅类型 | 图示 | 行为 | 适用场景 |
|----------|------|------|----------|
| Exclusive | 1个Consumer独占 | 一个订阅中只有一个 Consumer 消费 | 严格的顺序消费 |
| Shared | 多个Consumer共享 | 消息轮询分配给订阅中的 Consumer | 高吞吐并行消费 |
| Failover | 1主+多备 | 主 Consumer 消费，备机 standby | 高可用场景 |
| Key_Shared | 同Key路由到同Consumer | 相同 Key 的消息路由到固定 Consumer | 有序+并行 |

```java
// Exclusive 订阅（默认）
Consumer<byte[]> consumer = client.newConsumer()
    .topic("persistent://my-tenant/ns1/my-topic")
    .subscriptionName("my-subscription")
    .subscriptionType(SubscriptionType.Exclusive)
    .subscribe();

// Shared 订阅
Consumer<byte[]> consumer = client.newConsumer()
    .topic("persistent://my-tenant/ns1/my-topic")
    .subscriptionName("my-shared-sub")
    .subscriptionType(SubscriptionType.Shared)
    .subscribe();

// Key_Shared 订阅（保证同 key 的顺序）
Consumer<byte[]> consumer = client.newConsumer()
    .topic("persistent://my-tenant/ns1/orders")
    .subscriptionName("order-processors")
    .subscriptionType(SubscriptionType.Key_Shared)
    .subscribe();
```

## 四、生产部署实践

### 4.1 Docker Compose 部署

```yaml
version: '3.8'

services:
  # ZooKeeper（Pulsar 依赖）
  zookeeper:
    image: apachepulsar/pulsar:3.2
    command: bin/pulsar zookeeper
    environment:
      - ZK_PORT=2181
    ports:
      - "2181:2181"

  # BookKeeper（存储层）
  bookie:
    image: apachepulsar/pulsar:3.2
    command: bin/pulsar bookie
    ports:
      - "3181:3181"
    depends_on:
      - zookeeper
    environment:
      - BOOKIE_MEM=-Xms2g -Xmx2g -XX:+UseG1GC

  # Broker（计算层）
  broker:
    image: apachepulsar/pulsar:3.2
    command: bin/pulsar broker
    ports:
      - "6650:6650"   # Pulsar 协议
      - "8080:8080"   # HTTP API
    depends_on:
      - zookeeper
      - bookie
    environment:
      - BOOKIE_MEM=-Xms2g -Xmx2g

  # Pulsar Manager (Web UI)
  manager:
    image: apachepulsar/pulsar-manager:v0.4.0
    ports:
      - "9527:9527"
    depends_on:
      - broker
```

### 4.2 Spring Boot Pulsar 实战

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-pulsar</artifactId>
</dependency>
```

```yaml
# application.yml
spring:
  pulsar:
    client:
      service-url: pulsar://localhost:6650
    producer:
      topic-name: persistent://public/default/orders
    consumer:
      subscription-name: order-processor
      topic-names:
        - persistent://public/default/orders
      subscription-type: shared
```

```java
// 消息生产者
@Component
public class OrderProducer {

    @Autowired
    private PulsarTemplate<Order> pulsarTemplate;

    public void sendOrder(Order order) {
        pulsarTemplate.sendAsync("persistent://public/default/orders", order)
            .thenAccept(messageId ->
                log.info("订单消息已发送, orderId={}, messageId={}",
                    order.getId(), messageId));
    }

    // 带延迟的消息
    public void sendDelayedCancel(OrderCancel cancel) {
        pulsarTemplate.newMessage(cancel)
            .withTopic("persistent://public/default/order-cancel")
            .withDeliverAfter(30, TimeUnit.MINUTES)  // 30分钟后投递
            .send();
    }
}

// 消息消费者
@Component
@PulsarListener(
    subscriptionName = "order-processor",
    topics = "persistent://public/default/orders",
    subscriptionType = SubscriptionType.Shared
)
public class OrderConsumer {

    @Autowired
    private OrderService orderService;

    @PulsarListener(subscriptionName = "order-processor",
                    topics = "persistent://public/default/orders",
                    subscriptionType = SubscriptionType.Shared)
    public void onOrderReceived(Order order) {
        log.info("收到订单消息: {}", order.getId());
        try {
            orderService.process(order);
        } catch (Exception e) {
            log.error("订单处理失败, orderId={}", order.getId(), e);
            throw e; // 自动 NACK，消息重新投递
        }
    }
}
```

## 五、Kafka 与 Pulsar 对比

### 5.1 架构对比

| 方面 | Kafka | Pulsar |
|------|-------|--------|
| 存储层 | 每个 Broker 自带存储（分段日志） | 独立 BookKeeper 集群存储 |
| 计算层 | Broker 处理请求+存储 | 无状态 Broker，只做分发 |
| 扩容方式 | 增加 Partition + Rebalance | 无需 Rebalance，直接加 Broker |
| 存储扩容 | 扩容需要数据迁移 | 无状态 Broker 不变，Bookie 独立扩容 |
| 节点故障 | ISR 复制，重新选举 | 自动切片修复，秒级恢复 |
| 分区上限 | 建议每个 Broker < 4000 分区 | **支持数十万分区** |

### 5.2 性能对比

| 场景 | Kafka (3节点) | Pulsar (3 Broker + 3 Bookie) |
|------|---------------|-------------------------------|
| 吞吐量（单 Partition 写入） | ~800 MB/s | ~700 MB/s |
| 吞吐量（100分区写入） | ~1.2 GB/s（性能下降明显） | ~1.5 GB/s |
| 延迟 P99（1KB message） | 5-15ms | 3-8ms |
| 分区数扩展（0→1000） | ~20分钟（Rebalance） | ~5秒（无 Rebalance） |
| 节点宕机恢复时间 | 秒~分钟级（选举+同步） | 亚秒级（自动切片） |

## 六、选择建议

### 6.1 选型决策树

```
业务场景是什么？
│
├── 需要海量分区（万级）？──► Pulsar（独占优势）
│
├── 数据流处理（Kafka Streams）？──► Kafka
│
├── 金融级可靠消息？──► RocketMQ 或 Pulsar
│
├── 轻量级微服务通信？──► RabbitMQ
│
├── 统一流+队列的混合负载？──► Pulsar
│
└── 简单的事件总线？──► 三者都可以
```

### 6.2 适用场景矩阵

| 场景 | 推荐中间件 | 原因 |
|------|-----------|------|
| 日志采集、埋点数据 | Kafka | 高吞吐、顺序写、生态成熟 |
| 微服务异步RPC | RabbitMQ / Pulsar | 灵活路由、多种订阅模式 |
| 金融交易、订单处理 | RocketMQ / Pulsar | 事务消息、Exactly-Once |
| IoT 海量设备数据 | Pulsar | 海量分区支持、多租户隔离 |
| CDC 事件流（Debezium） | Kafka | 生态完善、Kafka Connect |
| 跨数据中心复制 | Pulsar | 内置跨地域复制 |

### 6.3 迁移成本

Pulsar 可以兼容 Kafka 协议：

```java
// 使用 Kafka 协议连接 Pulsar（无需修改代码）
Properties props = new Properties();
props.put("bootstrap.servers", "pulsar-cluster:9092"); // Kafka 协议端口
props.put("key.deserializer", StringDeserializer.class);
props.put("value.deserializer", StringDeserializer.class);

KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
// 直接消费 Pulsar 中的消息
```

**总结：** Apache Pulsar 以计算存储分离架构解决了消息系统弹性扩展的核心难题。如果你的场景需要**海量分区、多租户、跨地域复制**或**统一流+队列模型**，Pulsar 是非常值得关注的技术选型。而 Kafka 在流处理生态和 Streams API 上仍然不可替代，RabbitMQ 在轻量级场景下依然是最简单的选择。选型时应该综合团队技术栈、运维能力和业务需求做决定。
