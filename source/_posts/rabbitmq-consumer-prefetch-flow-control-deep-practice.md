---
title: 【RabbitMQ 实战】消费端流控深度实战：prefetch、批量 ACK 与内存告警链路
date: 2026-10-27 08:00:00
tags:
  - RabbitMQ
  - 消息队列
  - 流控
  - Java
categories:
  - 中间件
author: 东哥
---

# 【RabbitMQ 实战】消费端流控深度实战

## 前言

RabbitMQ 的「消息堆积」问题，十次里有七次根因不在消费者代码慢，而在**消费端的流控参数配错了**。

最典型的现象是：队列里堆了 200 万条消息，消费者 8 个线程 CPU 只有 15%，日志显示每条消息处理只要 5ms，但消费速度就是上不去。运维上去一看，`prefetch_count` 配的是默认值 250，而每个消费者的处理耗时波动极大——一个慢请求就把整个 channel 的窗口占满，其余消息全在客户端内存里排队。

这篇把 RabbitMQ 的**四层流控**讲清楚：consumer prefetch、channel 级 credit、connection 级阻塞、Broker 内存/磁盘告警。然后给出可以直接用的 Spring Boot 配置和压测方法。

---

## 一、RabbitMQ 流控的四个层次

很多人以为流控只有 `prefetch`，其实 RabbitMQ 有一套分层机制，从生产者一直管到消费者：

```
Producer
  │  ① Connection 级阻塞（blocked 状态）
  │     触发：Broker 内存/磁盘告警
  ▼
Broker
  │  ② Channel 级 credit flow（内部信用窗口）
  │     触发：队列积压、进程繁忙
  ▼
Queue → Consumer
  │  ③ Consumer prefetch（basic.qos）
  │     触发：unacked 数达到阈值
  ▼
  │  ④ 应用层并发控制（线程池 / 信号量）
  ▼
业务处理
```

这四层是**串联**关系：任何一层卡住，上游都会跟着停。理解这一点，才能定位「为什么生产者发不进去」和「为什么消费者拉不到」。

### 1.1 Connection 级阻塞（最容易被误判）

当 Broker 的内存使用超过 `vm_memory_high_watermark`（默认 0.4，即 40% 物理内存），或者磁盘剩余低于 `disk_free_limit`（默认 50MB），Broker 会：

1. 停止接收新消息（对开启了 `publisher confirms` 的生产者，`confirm` 不再返回）；
2. 在管理界面把该 connection 标记为 `blocked`；
3. 已连接的消费者**仍然可以消费**（这点很重要，说明「阻塞」不是全停）。

排查命令：

```bash
rabbitmqctl status | grep -A5 "Alarms"
rabbitmqctl list_connections name state  | grep blocked
```

如果是内存告警，还要看是谁占的：

```bash
rabbitmqctl list_queues name messages memory --sort-by memory | head -20
```

很多时候是某个队列堆了几十万条大消息，把内存吃满，然后整条链路被阻塞——**这就是「消费慢 → 堆积 → 内存告警 → 生产者被阻塞 → 业务超时」的完整雪崩链**。

### 1.2 Channel 级 credit flow

RabbitMQ 内部对每个 channel 有信用窗口（credit），当 Broker 侧的进程队列积压时，会减少发放给 channel 的 credit，表现为「客户端 send 变慢」。

这一层是自动的，不用配，但要知道它的存在：当你在客户端看到 `send()` 耗时从 0.1ms 涨到 20ms，而网络和 CPU 都正常时，大概率是 credit 被收紧了。

### 1.3 Consumer prefetch（本文重点）

`basic.qos(prefetchCount)` 定义了「一个 channel 上最多允许多少条消息处于已投递但未 ACK 的状态」。

关键在于：**prefetch 是 channel 级别的，不是 consumer 级别的**。一个 channel 上如果有 8 个 consumer，共享这 250 个额度。

而且 RabbitMQ 的投递是「轮询分发」：当窗口满时，Broker 停止给该 channel 投递，**即使某个 consumer 已经空闲**。这就导致经典的「消费者饿死」：

```
channel 上 prefetch=250，2 个 consumer
consumer A 拿到 200 条（其中 1 条卡在 30s 的慢查询上）
consumer B 只拿到 50 条，处理完后无事可做
Broker 认为 channel 窗口已满（250 条 unacked），不再投递
→ CPU 利用率只有 12%，队列却在堆积
```

### 1.4 应用层并发

Spring 的 `SimpleMessageListenerContainer` 用 `concurrency` 控制 consumer 数量、`max-concurrency` 控制弹性上限。这一层和 prefetch 是乘数关系，下面会讲怎么配。

---

## 二、prefetch 怎么取值：一个可计算的公式

网上流传的「prefetch 设 1 最公平」「设 250 是默认值」都是片面的。正确的取值要基于**单个消费者的并发能力 × 处理耗时**。

### 2.1 核心公式

实际并发处理能力：

```
有效并发 ≈ min(prefetch × consumerCount, 线程池大小)
```

而吞吐上限：

```
吞吐(条/秒) = 有效并发 / 平均处理耗时(秒)
```

反过来，给定目标吞吐和平均耗时，可以推出需要的 prefetch：

```
prefetch ≈ 目标并发 / consumerCount
目标并发 = 目标吞吐 × 平均处理耗时
```

举例：目标 2000 条/秒，平均处理耗时 50ms，4 个 consumer：

```
目标并发 = 2000 × 0.05 = 100
prefetch = 100 / 4 = 25
```

### 2.2 但还必须考虑「耗时方差」

上面是平均值。如果 P99 是平均值的 20 倍（很常见：大部分 50ms，少数 1s），那么：

- prefetch 太小（如 1）→ 消费者经常空等网络往返（每次投递要一次 RTT，约 0.5~2ms），吞吐被 RTT 限制；
- prefetch 太大（如 500）→ 一个慢请求会让大量消息在客户端堆着，一旦消费者崩溃，这些消息全部 requeue，造成「重复消费风暴」。

**经验公式（带方差修正）**：

```
prefetch = 目标并发 / consumerCount × (1 + P99/平均耗时 × 0.5)
```

上例中 P99/平均 = 20，则 prefetch ≈ 25 × 11 = 275。这时要再和「内存容忍度」做权衡：每条消息在客户端占用的内存 = 消息体大小 + 对象开销（约 200~500 字节），275 条 × 10KB ≈ 2.75MB，完全可接受。

### 2.3 不同场景的推荐值

| 场景 | prefetch | 理由 |
|---|---|---|
| 消息处理极快（< 1ms，如写缓存） | 100~300 | 让窗口足够大以掩盖 RTT |
| 处理耗时稳定（10~50ms） | 20~50 | 平衡吞吐与故障重投递量 |
| 处理耗时波动大（含外部调用） | 1~5 + 提高 consumer 数 | 避免慢请求拖死整个 channel |
| 强顺序 + 单条确认 | 1 | 保证不并发、不重复 |
| 批量处理（一次拉 N 条） | N 的整数倍 | 避免窗口不足导致批处理断档 |

**最重要的原则：如果处理耗时不可预测（依赖第三方 API、DB 慢查询），prefetch 一定要小，靠增加 consumer 数来扩吞吐。** 因为 prefetch 大 + 耗时方差大 = 内存里堆着一堆「还没开始处理」的消息，这些消息在消费者重启时全部重投，等价于一次流量放大。

---

## 三、批量 ACK：吞吐与可靠性的平衡

### 3.1 三种确认方式

| 方式 | API | 优点 | 风险 |
|---|---|---|---|
| 单条确认 | `basicAck(deliveryTag, false)` | 语义精确，重投递量最小 | 每条一次网络往返，吞吐受限 |
| 批量确认 | `basicAck(tag, true)` | 一次确认多条，吞吐高 | 中间的失败消息也会被一并确认（丢失） |
| 手动不确认 | 不调用 | —— | 消息永不删除，队列撑爆 |

`multiple=true` 的语义是「确认所有 deliveryTag ≤ 该值的消息」。这意味着一批里只要有一条成功，前面的失败消息也会被确认掉。

**正确用法**：批量 ACK 只适用于「整批同质、要么全成要么全败」的场景，且失败时必须先 `basicNack(requeue=true)` 再抛异常，让整批重来。

### 3.2 Spring Boot 的 ACK 模式

```yaml
spring:
  rabbitmq:
    listener:
      simple:
        acknowledge-mode: manual        # NONE / AUTO / MANUAL
        prefetch: 20
        concurrency: 4
        max-concurrency: 16
        batch-size: 50                  # 开启批处理
        receive-timeout: 1000
        default-requeue-rejected: false # 重要：避免死循环重投
```

`acknowledge-mode` 三选一：

- `NONE`：自动确认，消息一投递就删。**只在能容忍丢消息时用**。
- `AUTO`：Spring 在监听方法正常返回后 ack，抛异常则 nack 并 requeue。**大多数场景用这个**。
- `MANUAL`：自己调 `channel.basicAck`。适合需要「处理成功但稍后确认」或批处理场景。

特别注意 `default-requeue-rejected: false`：默认值是 `true`，意味着业务异常导致的消息会被**无限重投**，形成「毒消息死循环」，CPU 打满、日志刷爆。生产上必须配成 `false`，配合死信队列兜底。

### 3.3 完整的手动 ACK 示例

```java
import com.rabbitmq.client.Channel;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Component
public class OrderMessageConsumer {

    @RabbitListener(
        queues = "order.queue",
        concurrency = "4",
        ackMode = "MANUAL"
    )
    public void onMessage(Message message, Channel channel) throws Exception {
        long tag = message.getMessageProperties().getDeliveryTag();
        String body = new String(message.getBody());
        try {
            process(body);
            // 单条确认：multiple=false
            channel.basicAck(tag, false);
        } catch (BusinessRejectException e) {
            // 业务明确拒绝：不重回队列，走死信
            log.warn("reject message, tag={}, reason={}", tag, e.getMessage());
            channel.basicReject(tag, false);
        } catch (Exception e) {
            // 系统异常：重回队列，但要靠 x-delivery-count 限制次数
            log.error("process failed, tag={}", tag, e);
            channel.basicNack(tag, false, true);
        }
    }

    private void process(String body) {
        // 业务逻辑
    }
}
```

> 注意：`basicNack(tag, false, true)` 会把消息放回队列**头部**（RabbitMQ 的 requeue 是重新入队到原位置附近），如果失败是确定性的，就会立刻再次投递，形成热循环。必须配合 `x-delivery-count`（Quorum 队列自带）或自己记录重试次数。

---

## 四、消费者扩容的正确姿势

### 4.1 先看是不是「假性瓶颈」

在加机器之前，先确认瓶颈在哪一层：

```bash
# 1. 队列积压与消费者数量
rabbitmqctl list_queues name messages messages_unacknowledged consumers

# 2. 消费者详情（含 prefetch）
rabbitmqctl list_consumers queue_name channel_pid prefetch_count ack_required

# 3. 全局吞吐
rabbitmqctl list_queues name message_stats.publish_details.rate \
                        message_stats.deliver_get_details.rate
```

诊断逻辑：

- `consumers = 0` → 消费者掉线，不是性能问题；
- `messages_unacknowledged` 持续接近 `prefetch × consumers` → 窗口打满，要么处理慢，要么 prefetch 太小；
- `messages_unacknowledged` 远小于窗口 → 消费者在等消息，瓶颈在上游或队列本身；
- 两者都低但队列在涨 → 检查 connection 是否 blocked、是否有内存告警。

### 4.2 队列是瓶颈：单队列无法水平扩展

这是 RabbitMQ 与 Kafka 最大的架构差异：**一个队列的消息只能被一个 consumer 顺序投递（除非用 quorum queue 的多个 consumer，但仍然是同一队列）**。所以：

- 单队列的吞吐上限 ≈ 单消费者吞吐 × consumer 数，但受 Broker 单队列进程的调度能力限制；
- 要真正水平扩展，必须**分片**：按业务 key 拆成 `order.queue.0 ~ order.queue.7`，或者用一致性哈希交换机。

分片带来的问题是「顺序性」和「消费端复杂度」。如果业务需要按 `orderId` 有序，就用 `orderId.hashCode() % N` 路由到固定队列——这跟 Kafka 的分区语义是一致的。

### 4.3 弹性扩缩容的坑

Spring 的 `max-concurrency` 看起来能自动扩容，但它的扩容触发条件是「有消息积压」，缩容是「空闲」。问题是：

- 扩容时新建的 consumer 需要重新建立 channel，有 100~500ms 的冷启动；
- 缩容时如果还有 unacked 消息，会触发 requeue，造成重复消费。

所以自动扩缩容要配合**幂等消费**，否则宁可固定 `concurrency`，用 K8s HPA 按队列长度扩 Pod（Pod 级别扩容更干净）。

---

## 五、生产者侧的配合：publisher confirms 与批量

消费端调优的同时，别忘了生产端：

```yaml
spring:
  rabbitmq:
    publisher-confirm-type: correlated   # 异步 confirm，带 correlationData
    publisher-returns: true
    template:
      mandatory: true
```

```java
@Bean
public RabbitTemplate rabbitTemplate(ConnectionFactory cf) {
    RabbitTemplate t = new RabbitTemplate(cf);
    t.setConfirmCallback((correlation, ack, cause) -> {
        if (!ack) {
            log.error("publish nack, cause={}", cause);
            // 落库补偿或重投
        }
    });
    t.setReturnsCallback(returned ->
        log.error("message returned: {}", returned.getReplyText()));
    return t;
}
```

注意 `publisher-confirm-type: correlated` 与 `simple` 的区别：`simple` 是同步等待，会严重拖慢发送；`correlated` 是异步回调，生产必须用这个。

---

## 六、五个高频踩坑

### 坑 1：`prefetch` 配了但没生效

原因通常是：① 用的是 `DIRECT` 容器而不是 `SIMPLE`；② 多个 `@RabbitListener` 共用 channel（不会，Spring 每个 listener 独立 channel）；③ 配在了错误的层级（`spring.rabbitmq.listener.direct.prefetch` vs `simple.prefetch`）。

验证方法：`rabbitmqctl list_consumers` 看 `prefetch_count` 是否是你要的值。

### 坑 2：消费线程池被耗尽

`concurrency=4` 只代表 4 个 consumer，但如果业务方法内部用了 `@Async` 或自定义线程池，实际并发会翻倍。要注意 `SimpleMessageListenerContainer` 的线程是**专用的**，不要在里面做阻塞 30s 的调用。

### 坑 3：`requeue=true` 导致 CPU 100%

毒消息无限重投。解决：`default-requeue-rejected: false` + 死信队列 + 重试次数上限（用 Quorum 队列的 `x-delivery-limit`）。

### 坑 4：内存告警导致生产者全阻塞

根本解法是给队列设 `x-max-length` 或 `x-max-length-bytes`，溢出时走死信或直接丢弃（看业务）。同时监控 `rabbitmq_alarms_memory_used_watermark`。

### 坑 5：消费者重启后消息「消失」

如果用了 `acknowledge-mode: none`，消息在投递瞬间就被删除，消费者崩溃就丢了。这不是 RabbitMQ 的 bug，是配置语义。

---

## 七、面试追问

**Q1：prefetch 是 consumer 级还是 channel 级？**

channel 级。`basic.qos` 作用于 channel，多个 consumer 共享同一 channel 的额度。Spring 默认为每个 `@RabbitListener` 创建独立 channel，所以看起来像 consumer 级，但底层语义是 channel。

**Q2：prefetch 设 1 有什么优缺点？**

优点：负载最均匀（每个 consumer 一次只拿一条，处理完才拿下一条），故障时重投递量最小。缺点：吞吐受网络 RTT 限制，每条消息都要一次往返，在高吞吐场景下会浪费大量时间在等待上。适合「处理慢且耗时方差大」的场景。

**Q3：RabbitMQ 能保证消息不丢吗？**

需要三处配合：① 生产者 `publisher-confirm` + `publisher-returns`；② 队列和消息持久化（`durable=true` + `delivery_mode=2`）；③ 消费者手动 ACK 且处理成功后才确认。三者缺一不可。注意：即使全开，在「ACK 已发出但 Broker 未落盘」的瞬间崩溃仍可能丢，需要业务侧对账兜底。

**Q4：Quorum 队列和经典队列在流控上有什么区别？**

Quorum 队列基于 Raft，写入需要多数派确认，天然支持 `x-delivery-limit`（投递次数上限）和更好的消息安全性，但吞吐低于经典队列（约 30%~50%）。RabbitMQ 3.13 起官方推荐新业务一律用 Quorum 队列。

**Q5：为什么我的消费者 CPU 很低但消费很慢？**

先查三个地方：① `messages_unacknowledged` 是否打满 prefetch；② connection 是否 blocked（内存/磁盘告警）；③ 是否有大量 `basicNack(requeue=true)` 造成的重投循环。三者都不是，再看是不是单队列调度瓶颈——此时需要分片。

---

## 八、总结

RabbitMQ 消费端流控的核心可以浓缩成四句话：

1. **prefetch 不是越大越好，也不是越小越好**，它应该由「目标并发 ÷ consumer 数 × 方差修正」推出。
2. **耗时方差大就把 prefetch 调小、consumer 调多**，别让一个慢请求拖死整个 channel。
3. **`default-requeue-rejected` 必须设 false**，配合死信队列，否则毒消息会打死消费者。
4. **单队列有吞吐上限**，真正要水平扩展必须分片，而分片要处理顺序性问题。

把这四点配好，同样的机器通常能把消费吞吐提升 2~3 倍，同时把「消息堆积」的告警频率降一个数量级。
