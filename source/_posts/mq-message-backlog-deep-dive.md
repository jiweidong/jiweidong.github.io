---
title: 消息积压排查与治理实战：从消费能力分析到削峰填谷
date: 2026-08-16 08:00:00
tags:
  - Java
  - Kafka
  - RocketMQ
  - 消息队列
  - 高并发
  - 面试
categories:
  - Java
  - 中间件
author: 东哥
---

# 消息积压排查与治理实战：从消费能力分析到削峰填谷

## 面试官：线上消息堆积了几百万条，你怎么办？

这是消息队列方向最高频的面试题，也是生产环境最让人头秃的故障之一。消息积压意味着**业务处理严重滞后**：订单状态不更新、通知发不出去、数据对不上账。

面试官想听的绝不是"重启消费者"这种话，而是完整的思路：**发现问题 → 定位原因 → 应急止血 → 根治方案**。

## 一、什么是消息积压？危害有多大？

**积压定义**：生产者生产消息的速度 > 消费者消费的速度，消息在 Broker 中越堆越多。

衡量指标：

| 指标 | 含义 | Kafka | RocketMQ |
|------|------|-------|----------|
| Consumer Lag | 消费者落后生产者的消息数 | 每个分区有 Lag | 消费进度落后位点 |
| 积压消息数 | 队列中待消费消息总量 | sum(分区Lag) | sum(队列Lag) |
| 消费延迟 | 最新消息到被消费的时间差 | 秒~小时级 | 秒~小时级 |

**危害：**

1. **业务延迟**：订单 30 分钟不发货、优惠券核销不及时，直接损失营收
2. **消息过期**：RocketMQ/Kafka 有消息保留期，积压太久消息被清理 = **数据丢失**
3. **下游连锁反应**：消费慢 → 下游系统被打爆 → 雪崩
4. **磁盘爆满**：Broker 存储膨胀，影响集群稳定性

## 二、如何快速发现积压？

### 2.1 Kafka 命令行

```bash
# 查看消费组 lag
kafka-consumer-groups.sh --bootstrap-server kafka:9092 \
  --describe --group order-group

# 输出示例：LAG 列就是积压量
GROUP         TOPIC          PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
order-group   ORDER_TOPIC    0          123456          523456          400000
order-group   ORDER_TOPIC    1          234567          534567          300000
```

### 2.2 监控告警（生产必备）

- Prometheus + Grafana：监控 `kafka_consumergroup_lag`、RocketMQ 的 `ConsumerLag` 指标
- **阈值告警**：Lag 超过 1 万告警，超过 10 万 P0 报警
- 告警要按消费组维度，避免全局指标掩盖单个消费组的问题

## 三、定位：为什么消费不动了？

积压的原因基本就四类，按概率排序：

### 3.1 消费者代码 Bug（最常见）

```java
// 典型反面教材：消费逻辑里有慢查询 + 锁等待
@KafkaListener(topics = "ORDER_TOPIC")
public void consume(OrderMessage msg) {
    // ① 同步调第三方接口，超时 30s 不熔断
    String result = thirdPartyService.call(msg.getOrderId());
    // ② 慢 SQL，没索引，一次 2 秒
    orderMapper.updateStatus(msg.getOrderId());
    // ③ 一把锁锁住所有消费线程
    synchronized (this) { doSomething(); }
}
```

**排查手段**：

- 看消费者日志：是否有大量超时、重试、异常
- Arthas 看线程栈：`thread -n 3` 看消费线程卡在哪
- 慢 SQL 日志：是否命中索引

### 3.2 消费能力不足

| 瓶颈 | 表现 | 解法 |
|------|------|------|
| 分区数 < 消费者数 | 有消费者空闲 | 增加分区（Kafka） |
| 单条消息处理慢 | 吞吐上不去 | 批量处理、异步化 |
| 下游接口慢 | 消费线程阻塞在 RPC | 优化下游、超时熔断 |
| 消费线程数太少 | CPU 没打满 | 调大并发线程 |

### 3.3 生产端瞬时洪峰

大促、秒杀、活动开始瞬间，消息量暴涨 10 倍，消费端一时消化不了。**这是正常现象，重点是削峰**。

### 3.4 Broker 故障

分区 Leader 迁移、磁盘 IO 打满、网络抖动，导致消费拉取变慢。

## 四、应急止血：先恢复业务，再谈优化

**原则：先扩容，先保证消息不丢，再定位根因。**

### 4.1 最快手段：扩容消费者

```yaml
# Kafka：水平扩容
# 前提：分区数 >= 消费者实例数，否则新实例空闲
# 1. 增加分区（预先做好分区规划，生产环境分区数要留余量）
bin/kafka-topics.sh --alter --bootstrap-server kafka:9092 \
  --topic ORDER_TOPIC --partitions 24

# 2. 直接扩容消费者实例（K8s 下 scale deployment）
kubectl scale deployment order-consumer --replicas=12
```

```yaml
# RocketMQ：调大消费线程数 + 批量消费
rocketmq:
  consumer:
    group: order-group
    listeners:
      order-consumer:
        consume-thread-min: 32   # 默认 20
        consume-thread-max: 64
        consume-message-batch-max-size: 32  # 批量拉取
```

**注意**：Kafka 扩容消费者只对"分区数 > 消费者数"有效，所以**分区规划要留余量**（一般 8~16 个分区起步，大流量 32~64）。

### 4.2 清理无效消息（谨慎使用）

```java
// 如果积压的消息大部分已过期（如已支付订单的"待支付提醒"）
// 消费时直接跳过，只更新 offset
@KafkaListener(topics = "ORDER_TOPIC")
public void consume(OrderMessage msg) {
    Order order = orderMapper.selectById(msg.getOrderId());
    if (order == null || order.getStatus() != OrderStatus.UNPAID) {
        return; // 消息已无意义，直接跳过，快速推进 offset
    }
    handle(msg);
}
```

### 4.3 消费者逻辑降级

临时关掉消费逻辑里的非核心步骤（发短信、发推送、调用非关键下游），只保留核心落库逻辑，先把 Lag 消化掉。

### 4.4 死信消息处理

```java
// 消费失败进入重试，重试耗尽进死信队列
// 死信队列单独消费，人工/脚本处理，不阻塞主链路
@RocketMQMessageListener(topic = "ORDER_TOPIC_DLQ", consumerGroup = "dlq-handler")
@Component
public class DlqHandler implements RocketMQListener<MessageExt> {
    @Override
    public void onMessage(MessageExt msg) {
        log.error("死信消息: msgId={}, keys={}, body={}",
                msg.getMsgId(), msg.getKeys(), new String(msg.getBody()));
        // 告警 + 入库待人工处理
    }
}
```

## 五、根治：从架构上消灭积压

应急只是止血，下面这些才是长期方案：

### 5.1 批量消费，减少网络和 IO 开销

```yaml
# Kafka：一次拉取批量处理
spring:
  kafka:
    consumer:
      max-poll-records: 500      # 一次 poll 拉 500 条
      fetch-min-size: 1048576    # 1MB 才返回，减少网络往返
```

```java
@KafkaListener(topics = "ORDER_TOPIC")
public void batchConsume(List<OrderMessage> messages) {
    // 批量落库：一条 INSERT ... VALUES 多条，吞吐提升 5~10 倍
    orderBatchMapper.insertBatch(messages);
}
```

### 5.2 消费逻辑异步化

```java
// 消费线程只做：接消息 → 提交本地任务池 → 立即返回
// 用独立线程池处理耗时逻辑，消费线程永不阻塞
@KafkaListener(topics = "ORDER_TOPIC")
public void consume(OrderMessage msg) {
    bizExecutor.submit(() -> {
        try {
            orderService.handle(msg);
        } catch (Exception e) {
            // 失败进本地重试表，异步补偿
            retryService.save(msg, e);
        }
    });
}
```

**注意**：异步化后要自己保证"消费完成"语义（手动 ack / 本地重试），不能盲目 `enable.auto.commit=true`。

### 5.3 削峰填谷

| 手段 | 说明 | 场景 |
|------|------|------|
| 生产者限流 | 入口限流（Sentinel），超阈值拒绝/排队 | 秒杀 |
| 消费端削峰 | 消息本身就是削峰工具：先收进 MQ，再匀速消费 | 所有场景 |
| 延迟消费 | 非核心消息延迟处理，避开高峰 | 通知类 |
| 分级 Topic | 核心/非核心消息分 Topic，核心优先消费 | 大促 |

### 5.4 消费能力容量规划

```
吞吐公式：单消费者 TPS × 消费者数 = 消费能力
要求：消费能力 ≥ 峰值生产速度 × 1.5（安全系数）
```

- 大促前压测：模拟峰值消息量，验证消费能力
- 按峰值预留消费者副本数，而不是平均值

## 六、面试高频追问

**Q1：Kafka 积压了，直接加消费者实例就行吗？**
不一定。Kafka 一个分区同时只能被一个消费者实例消费（同一消费组内），**消费者数超过分区数时，多出来的消费者是空闲的**。所以要么先加分区（需要预先留余量），要么提升单消费者吞吐。

**Q2：为什么消费端会有"消息重复消费"和积压同时出现？**
消费超时（如处理超过 max.poll.interval.ms）会触发 Rebalance，未提交 offset 的消息会被重新消费，造成重复；同时处理慢又加剧积压。根因都是**单条消息处理时间过长**，解法是异步化 + 合理配置 poll 间隔和批量大小。

**Q3：RocketMQ 消息积压怎么快速处理？**
先看是哪个消费组积压、积压在哪个 Queue。应急：扩容消费者（RocketMQ 一个 Queue 也可以被同组多实例分摊？不能——一个 Queue 同时只能被一个消费者消费，所以扩容前要确认 Queue 数）。RocketMQ 的 Queue 数一般不用预先留太多，因为支持动态扩 Queue，但要消息先发到新 Queue 才有效。

**Q4：消息过期被清理了，数据丢了怎么办？**
积压太久的消息会被 Broker 按保留期删除，无法恢复。所以**监控 Lag 是底线**，告警后必须 30 分钟内介入。生产经验：核心 Topic 保留期调长（如 7 天），并开启消息轨迹追踪，便于排查。

**Q5：怎么设计才能让系统"永远不会积压"？**
没有永不积压的系统，只有"积压可接受、可恢复"的设计：① 消费能力按峰值 × 1.5 预留；② Lag 监控告警 + 自动扩容（K8s HPA 按 Lag 扩缩容）；③ 消费逻辑异步化、批量化的标准规范；④ 大促前压测演练。

## 总结

消息积压的处理框架，面试直接背：

1. **发现**：Lag 监控 + 阈值告警（Lag > 1万 告警，> 10万 P0）
2. **定位**：消费者代码 Bug（慢 SQL/超时/锁）> 消费能力不足 > 瞬时洪峰 > Broker 故障
3. **止血**：扩容消费者（注意分区/Queue 上限）→ 跳过无效消息 → 降级非核心逻辑 → 死信隔离
4. **根治**：批量消费 + 异步化 + 削峰填谷 + 容量规划 + 自动扩缩容
5. **兜底**：消息轨迹 + 对账 + 人工处理流程

记住这句话：**积压不可怕，可怕的是没有监控、没有预案**。
