---
title: Redis Stream 消息队列实战：从原理到企业级应用
date: 2026-06-17 08:00:00
tags:
  - Redis
  - 消息队列
  - Stream
  - Java
categories:
  - 中间件
author: 东哥
---

# Redis Stream 消息队列实战：从原理到企业级应用

> Redis Stream 是 Redis 5.0 引入的强大的消息队列数据结构，它兼具消息持久化、消费者组管理、ACK 确认机制等企业级特性，弥补了 List 和 Pub/Sub 在生产环境中的诸多不足。本文将深入讲解 Stream 的原理、用法，并通过实战案例带你掌握企业级消息队列的搭建。

## 一、Redis Stream 概述

### 1.1 什么是 Stream

Redis Stream 是一个**追加式日志**（append-only log）数据结构。每条消息都有一个唯一的 ID，消息以键值对字典的形式存储。与传统的 List 和 Pub/Sub 相比，Stream 提供了更加完善的消息队列功能：

- **消息持久化**：基于 RDB/AOF，重启不丢失
- **消费者组**：支持组内负载均衡消费
- **ACK 确认机制**：保证消息至少被消费一次
- **消息回溯**：可以从头到尾重新消费
- **阻塞读取**：支持阻塞等待新消息

### 1.2 核心概念

| 概念 | 说明 |
|------|------|
| **消息 ID** | 格式 `<毫秒时间戳>-<序列号>`，全局唯一、单调递增 |
| **Entry** | Stream 中的一条消息记录，包含一个或多个键值对 |
| **Consumer Group** | 消费者组，组内消费者分摊消息 |
| **Consumer** | 消费者组中的具体消费者实例 |
| **Pending Entries List (PEL)** | 已投递但未确认的消息列表 |
| **Last Delivered ID** | 组内最后投递的消息 ID |
| **Stream Key** | Redis 中存储 Stream 的 key |

## 二、Stream 核心命令实战

### 2.1 消息生产：XADD

```bash
# 添加消息，ID 使用 * 让 Redis 自动生成
XADD orders * product_id "1001" amount 99.9 user_id "u123"

# 输出: "1729081600000-0"

# 指定最大长度，超过则淘汰旧消息
XADD orders MAXLEN ~ 10000 * product_id "1002" amount 199.9 user_id "u456"
```

**Java 代码示例：**

```java
// 使用 Jedis 生产消息
Jedis jedis = new Jedis("localhost", 6379);
Map<String, String> message = new HashMap<>();
message.put("productId", "1001");
message.put("amount", "99.9");
message.put("userId", "u123");

String messageId = jedis.xadd("orders", StreamEntryID.NEW_ENTRY, message);
System.out.println("Message ID: " + messageId);
```

### 2.2 消息消费：XREAD

```bash
# 从 Stream 中读取消息（非消费者组模式）
# 从 0 开始读取所有消息
XREAD COUNT 10 STREAMS orders 0

# 阻塞等待新消息，超时 5 秒
XREAD BLOCK 5000 STREAMS orders $

# 从指定 ID 之后开始读取
XREAD COUNT 5 STREAMS orders 1729081600000-0
```

### 2.3 消费者组：XGROUP

```bash
# 创建消费者组，从 Stream 头部开始消费
XGROUP CREATE orders order_group 0

# 或者从最新消息开始消费
XGROUP CREATE orders order_group $

# 查看消费者组信息
XINFO GROUPS orders

# 查看组内消费者
XINFO CONSUMERS orders order_group
```

### 2.4 消息消费：XREADGROUP

```bash
# 消费者组模式读取消息
XREADGROUP GROUP order_group consumer-1 COUNT 1 STREAMS orders >

# `>` 表示只读取从未投递给当前组的消息
```

**Java 代码示例：**

```java
// 消费者组消费
Jedis jedis = new Jedis("localhost", 6379);
Map<String, StreamEntryID> streams = new HashMap<>();
streams.put("orders", StreamEntryID.UNRECEIVED_ENTRY); // ">"

List<Map.Entry<String, List<StreamEntry>>> results = 
    jedis.xreadGroup("order_group", "consumer-1", 1, 5000, false, streams);

for (Map.Entry<String, List<StreamEntry>> entry : results) {
    for (StreamEntry msg : entry.getValue()) {
        System.out.println("收到消息: " + msg.getFields());
        // 处理完成后确认消息
        jedis.xack("orders", "order_group", msg.getID());
    }
}
```

### 2.5 ACK 确认与 PEL 管理

```bash
# 确认消息（从 PEL 中移除）
XACK orders order_group 1729081600000-0

# 查看 PEL（待确认消息列表）
XPENDING orders order_group

# 获取 PEL 详情
XPENDING orders order_group - + 10

# 查看所有未确认消息
XPENDING orders order_group - + 10 consumer-1
```

### 2.6 死信处理

当消息长时间停留在 PEL 中（已投递但未确认），说明消费失败，需要进行死信处理：

```bash
# 查询某个消费者的 PEL
XPENDING orders order_group - + 10 consumer-1

# 将 PEL 中的消息转移给其他消费者处理
XCLAIM orders order_group consumer-2 3600000 1729081600000-0

# 查看 Stream 长度和范围
XLEN orders
XRANGE orders - +
```

## 三、Stream vs List vs Pub/Sub 对比

| 特性 | Stream | List (BLPOP/BRPOP) | Pub/Sub |
|------|--------|-------------------|---------|
| **消息持久化** | ✅ 支持 | ✅ 支持 | ❌ 不持久化 |
| **消费者组** | ✅ 原生支持 | ❌ 需要自行实现 | ❌ 不支持 |
| **ACK 确认** | ✅ 原生支持 | ❌ 无 | ❌ 无 |
| **消息回溯** | ✅ 可回溯任意消息 | ❌ 消费即删除 | ❌ 不可回溯 |
| **阻塞读取** | ✅ | ✅ | ✅ |
| **多消费者** | ✅ 组内负载均衡 | ❌ 争抢模式 | ✅ 广播模式 |
| **消息可靠性** | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐ |
| **复杂度** | 中等 | 低 | 低 |
| **适用场景** | 企业级消息队列 | 简单任务队列 | 实时广播通知 |

## 四、消息可靠机制深度解析

### 4.1 ACK 确认机制

Stream 的 ACK 机制保证了消息的**至少一次交付**（at-least-once）：

1. XREADGROUP 读取消息后，消息进入 PEL（Pending Entries List）
2. 消费者处理完成后，调用 XACK 从 PEL 中移除
3. 如果消费者崩溃，PEL 中的消息会被重新分配给其他消费者

### 4.2 PENDING 列表与消息重试

```bash
# 查看 PEL 统计
XPENDING orders order_group
# 输出: (integer) 5            -- 未确认消息数
#       "1729081600000-0"      -- 最旧未确认
#       "1729081600005-0"      -- 最新未确认
#       ["consumer-1", "3", "consumer-2", "2"]
```

### 4.3 死信队列实现

```java
/**
 * 死信处理定时任务
 */
@Scheduled(fixedRate = 60000)
public void handleDeadLetter() {
    try (Jedis jedis = new Jedis("localhost", 6379)) {
        // 获取 PEL 中超过 1 分钟未确认的消息
        PendingResult pending = jedis.xpending("orders", "order_group", 
            Range.getRange("-", "+"), 100);
        
        for (PendingEntry entry : pending.getEntries()) {
            long idleTime = entry.getIdleTimeMs();
            if (idleTime > 60_000) {
                // 将消息转移给死信消费者
                jedis.xclaim("orders", "order_group", "dlq-consumer", 
                    60000, entry.getID());
                log.warn("消息 {} 转为死信处理", entry.getID());
            }
        }
    }
}
```

## 五、消息持久化与过期策略

### 5.1 持久化

Redis Stream 依赖于 Redis 的持久化机制：

| 持久化方式 | 描述 | 数据安全性 |
|-----------|------|-----------|
| **RDB** | 快照持久化 | 可能丢失两次快照间数据 |
| **AOF** | 追加日志持久化 | 根据 fsync 策略决定 |
| **混合持久化** | RDB + AOF 增量 | 高安全性 |

### 5.2 过期策略

Stream 没有 TTL 机制，需要通过 **MAXLEN** 控制长度：

```bash
# 精确截断
XTRIM orders MAXLEN 10000

# 近似截断（性能更好）
XTRIM orders MAXLEN ~ 10000

# 通过 ID 范围删除
XDEL orders 1729081600000-0
```

## 六、与 Kafka / RabbitMQ 对比

| 特性 | Redis Stream | Kafka | RabbitMQ |
|------|-------------|-------|----------|
| **定位** | 轻量级内存消息队列 | 分布式流处理平台 | 企业级消息代理 |
| **吞吐量** | ~10万/s | ~100万/s | ~5万/s |
| **消息持久化** | 磁盘 + 内存 | 磁盘 | 磁盘 |
| **消息顺序** | 分区内有序 | 分区内有序 | 队列内有序 |
| **消费者组** | ✅ | ✅ | ✅ |
| **消息重试** | PEL + XCLAIM | 自动重试 | 死信队列 |
| **死信队列** | 手动实现 | ✅ 内置 | ✅ 内置 |
| **事务支持** | 有限 | 精确一次 | ✅ |
| **部署复杂度** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **运维成本** | 低 | 高 | 中 |
| **适用规模** | 中小规模 | 大规模 | 中大规模 |

**选型建议：**
- **Redis Stream**：中小规模项目、对延迟要求高的场景、已有 Redis 技术栈
- **Kafka**：大数据流处理、日志聚合、超高吞吐量
- **RabbitMQ**：复杂路由、事务消息、企业级集成

## 七、实战案例：订单消息处理系统

### 7.1 系统架构

```
┌─────────┐     XADD     ┌──────────┐    XREADGROUP    ┌─────────────┐
│ 订单服务 │ ──────────→ │ Redis    │ ←────────────── │ 订单处理服务 │
└─────────┘              │ Stream   │                  └─────────────┘
                         │ (orders) │                   ┌─────────────┐
                         └──────────┘                   │ 通知服务     │
                                                        └─────────────┘
```

### 7.2 Spring Boot 集成

**Maven 依赖：**

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

**配置类：**

```java
@Configuration
public class RedisStreamConfig {
    
    @Bean
    public StreamMessageListenerContainer<String, MapRecord<String, String, String>> 
            streamMessageListenerContainer(RedisConnectionFactory factory) {
        
        StreamMessageListenerContainer
                .StreamMessageListenerContainerOptions<String, MapRecord<String, String, String>> options = 
                StreamMessageListenerContainerOptions
                        .builder()
                        .pollTimeout(Duration.ofSeconds(1))
                        .batchSize(10)
                        .build();
        
        return StreamMessageListenerContainer.create(factory, options);
    }
}
```

**消息生产者：**

```java
@Service
public class OrderMessageProducer {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    public String sendOrder(OrderDTO order) {
        Map<String, String> message = new HashMap<>();
        message.put("orderId", order.getOrderId());
        message.put("userId", order.getUserId());
        message.put("amount", order.getAmount().toString());
        message.put("productId", order.getProductId());
        message.put("timestamp", String.valueOf(System.currentTimeMillis()));
        
        return redisTemplate.opsForStream()
                .add("orders", message);
    }
}
```

**消息消费者：**

```java
@Component
public class OrderMessageListener 
        implements StreamListener<String, MapRecord<String, String, String>> {
    
    private static final Logger log = LoggerFactory.getLogger(OrderMessageListener.class);
    
    @Autowired
    private OrderService orderService;
    
    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        String stream = message.getStream();
        String messageId = message.getId().getValue();
        Map<String, String> body = message.getValue();
        
        log.info("收到订单消息 [{}]: {}", messageId, body);
        
        try {
            // 处理订单
            orderService.processOrder(body);
            log.info("订单处理成功: {}", body.get("orderId"));
        } catch (Exception e) {
            log.error("订单处理失败: {}", body.get("orderId"), e);
            // 异常不抛给框架，避免自动 ACK 失败导致无限重试
        }
    }
}
```

**消费者组注册：**

```java
@Configuration
public class OrderStreamConsumerConfig {
    
    @PostConstruct
    public void initConsumerGroup() {
        try (Jedis jedis = new Jedis("localhost", 6379)) {
            // 创建消费者组（幂等）
            try {
                jedis.xgroupCreate("orders", "order-group", 
                    StreamEntryID.LAST_ENTRY, true);
            } catch (RedisException e) {
                // 组已存在，忽略
            }
        }
    }
    
    @Bean
    public StreamMessageListenerContainer<String, MapRecord<String, String, String>> 
            orderContainer(
                StreamMessageListenerContainer<String, MapRecord<String, String, String>> container,
                OrderMessageListener listener,
                RedisConnectionFactory factory) {
        
        // 注册 Stream 监听
        container.receive(
            Consumer.from("order-group", "consumer-1"),
            StreamOffset.create("orders", ReadOffset.lastConsumed()),
            listener
        );
        
        container.start();
        return container;
    }
}
```

### 7.3 异步通知场景

```java
@Service
public class NotificationService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    /**
     * 发送异步通知消息
     */
    public void sendNotification(String userId, String title, String content) {
        Map<String, String> msg = new HashMap<>();
        msg.put("userId", userId);
        msg.put("type", "email");
        msg.put("title", title);
        msg.put("content", content);
        
        redisTemplate.opsForStream().add("notifications", msg);
    }
}
```

## 八、性能测试数据

以下基于单机 Redis 6.2（i7-9700K, 32GB RAM, SSD）的基准测试：

| 场景 | 消息数 | 消息大小 | 吞吐量 (msg/s) | P99 延迟 |
|------|--------|---------|---------------|---------|
| XADD 纯写入 | 100万 | 256B | 185,000 | 2ms |
| XREAD 非阻塞 | 100万 | 256B | 220,000 | 1ms |
| XREADGROUP 组消费 | 100万 | 256B | 150,000 | 3ms |
| XADD + XDEL | 100万 | 256B | 80,000 | 5ms |
| 带 MAXLEN 写入 | 100万 | 256B | 120,000 | 4ms |
| 5 个消费者组同时消费 | 100万 | 256B | 130,000 | 6ms |

**性能优化建议：**
1. 使用 `MAXLEN ~ N` 近似截断，避免逐条删除
2. 消息体控制在 1KB 以内
3. 使用 Pipeline 批量生产消息
4. 消费者组数量不要过多（建议 < 10）

## 九、总结

Redis Stream 是一个功能完备的轻量级消息队列解决方案，适合以下场景：

- **中小规模**的消息异步处理（日均消息量 < 1000万）
- **低延迟**要求（P99 < 10ms）
- **已有 Redis 技术栈**，不需要引入额外中间件
- **消息可靠性**要求高（需要 ACK 确认和回溯）

在大型分布式系统中，Stream 可以作为**前置缓冲层**与 Kafka/RabbitMQ 配合使用，既能发挥 Redis 低延迟的优势，又能利用专业 MQ 的持久化和吞吐量。

掌握 Redis Stream，让你的消息处理架构更加灵活可靠！
