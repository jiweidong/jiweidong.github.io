---
title: 延迟队列深度解析：五种实现方案对比与订单超时关闭实战
date: 2026-08-16 08:00:00
tags:
  - Java
  - 延迟队列
  - 中间件
  - Redis
  - 消息队列
  - 高并发
categories:
  - Java
  - 中间件
author: 东哥
---

# 延迟队列深度解析：五种实现方案对比与订单超时关闭实战

## 面试官：说说你们是怎么实现订单超时自动关闭的？

这是高并发场景下的经典问题。用户下单后 30 分钟未支付，订单要自动关闭、库存要释放。实现"延迟任务"的方案五花八门，面试官想听的不是某一个方案，而是你**对方案选型的思考**：为什么不用定时任务轮询？为什么用 Redis ZSet？为什么生产环境最终选了 RocketMQ？

本文系统梳理 5 种主流延迟队列实现方案，从原理到代码，从优缺点到选型建议，一文讲透。

## 一、什么是延迟队列？

普通队列：生产者放入消息，消费者**立即**消费。
延迟队列：消息进入队列后，**等待指定时间**才被消费者消费。

核心能力：**"到点了才执行"**。

典型业务场景：

| 场景 | 延迟时间 | 到期动作 |
|------|---------|---------|
| 订单超时未支付 | 30 分钟 | 关闭订单、释放库存 |
| 用户下单未评价 | 7 天 | 发送提醒 |
| 定时发布文章 | 自定义 | 自动上架 |
| 支付成功通知 | 5 秒 | 通知下游 |
| 分布式锁续期 | 30 秒 | 续期/释放 |
| 失败重试 | 递增 | 重新投递 |

## 二、方案一：数据库轮询（最朴素，先被否定）

用定时任务（XXL-Job / Quartz）每 N 秒扫一次表，把 `expire_time < now` 的记录捞出来处理。

```sql
-- 每 10 秒执行一次
SELECT * FROM t_order
WHERE status = 'UNPAID' AND expire_time < NOW()
LIMIT 1000;
```

**致命问题：**

| 问题 | 说明 |
|------|------|
| 延迟不可控 | 轮询间隔 10s，最坏延迟 10s+ |
| 数据库压力大 | 全表扫描 + 频繁查询，量大扛不住 |
| 时间不准 | 到点不执行，永远慢一个间隔 |
| 冷热不均 | 高峰期扫到大量数据，低峰期空转 |

结论：**只适合对延迟不敏感、量小的场景**。面试时先抛出这个方案再否定它，展示思考过程。

## 三、方案二：Java DelayQueue（JDK 自带）

```java
public class OrderTimeoutTask implements Delayed {

    private final long orderId;
    private final long expireTime; // 到期时间戳

    public OrderTimeoutTask(long orderId, long delayMillis) {
        this.orderId = orderId;
        this.expireTime = System.currentTimeMillis() + delayMillis;
    }

    @Override
    public long getDelay(TimeUnit unit) {
        return unit.convert(expireTime - System.currentTimeMillis(), TimeUnit.MILLISECONDS);
    }

    @Override
    public int compareTo(Delayed o) {
        return Long.compare(this.expireTime, ((OrderTimeoutTask) o).expireTime);
    }
}
```

```java
// 消费者线程
DelayQueue<OrderTimeoutTask> queue = new DelayQueue<>();

new Thread(() -> {
    while (true) {
        try {
            OrderTimeoutTask task = queue.take(); // 阻塞直到有任务到期
            closeOrder(task.getOrderId());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            break;
        }
    }
}, "delay-consumer").start();
```

**原理**：DelayQueue 内部是 PriorityQueue（优先队列），按 `compareTo` 排序，`take()` 时用 `getDelay` 判断队头是否到期，未到期就 `await` 精确到纳秒。

**致命缺陷：**

- **内存队列**，重启即丢，订单超时任务丢失 = 资金风险
- **单机**，无法水平扩展，消费者线程挂了任务就卡死
- 任务量大了内存扛不住

结论：**只适合单体应用、可容忍丢失、任务量小的场景**（如本地缓存过期清理）。

## 四、方案三：Redis ZSet（最经典的中间件方案）

利用 ZSet 的 score 特性：**score 存到期时间戳，到期任务 score <= 当前时间**。

```java
public class RedisDelayQueue {

    private static final String KEY = "delay:order:close";

    @Autowired
    private StringRedisTemplate redis;

    /** 添加延迟任务 */
    public void addOrder(long orderId, long delaySeconds) {
        long expireScore = System.currentTimeMillis() / 1000 + delaySeconds;
        redis.opsForZSet().add(KEY, String.valueOf(orderId), expireScore);
    }

    /** 拉取到期任务 */
    public List<String> pollExpired(int batchSize) {
        long now = System.currentTimeMillis() / 1000;
        Set<String> expired = redis.opsForZSet().rangeByScore(KEY, 0, now, 0, batchSize);
        if (expired == null || expired.isEmpty()) {
            return Collections.emptyList();
        }
        // 批量移除，防止重复消费
        redis.opsForZSet().remove(KEY, expired.toArray());
        return new ArrayList<>(expired);
    }
}
```

```java
// 消费者：定时拉取到期任务
@Scheduled(fixedDelay = 1000)
public void consume() {
    List<String> orderIds = delayQueue.pollExpired(500);
    for (String orderId : orderIds) {
        // 注意：先查订单状态再关闭，幂等处理
        closeOrderIfUnpaid(Long.parseLong(orderId));
    }
}
```

**要点：**

1. **先 range 再 remove**，中间有并发窗口，所以消费者必须**幂等**
2. 可以用 Lua 脚本把"取+删"原子化：

```lua
-- lua 脚本：原子取出并删除到期元素
local list = redis.call('ZRANGEBYSCORE', KEYS[1], 0, ARGV[1], 'LIMIT', 0, ARGV[2])
if #list > 0 then
    redis.call('ZREM', KEYS[1], unpack(list))
end
return list
```

**优缺点：**

| 优点 | 缺点 |
|------|------|
| Redis 持久化（AOF/RDB），比内存队列可靠 | 需要自研轮询逻辑，没有 ACK 机制 |
| 天然支持分布式，多消费者抢任务 | 消费者挂了任务没人拉取（无自动重投） |
| 实现简单，依赖少 | 大量任务积压时 ZSet 内存占用高 |

结论：**中小团队最常用的方案，够用且可控**。

## 五、方案四：RabbitMQ TTL + 死信队列

RabbitMQ 官方没有延迟队列，但可以用两个特性组合出来：

1. **TTL**（消息过期时间）
2. **死信队列**（消息过期 → 转发到 DLX 绑定的队列）

```
生产者 → 延迟交换机 → 延迟队列(ttl=30min) --过期--> 死信交换机 → 实际消费队列 → 消费者
```

```java
// 1. 声明死信队列（真正的消费队列）
@Bean
public Queue realQueue() {
    return QueueBuilder.durable("order.close.queue").build();
}

@Bean
public DirectExchange deadLetterExchange() {
    return new DirectExchange("dlx.order.exchange");
}

@Bean
public Binding deadLetterBinding() {
    return BindingBuilder.bind(realQueue()).to(deadLetterExchange()).with("order.close");
}

// 2. 声明延迟队列（消息过期后进死信）
@Bean
public Queue delayQueue() {
    return QueueBuilder.durable("order.delay.queue")
            .ttl(30 * 60 * 1000) // 消息 30 分钟过期
            .deadLetterExchange("dlx.order.exchange")   // 死信去向
            .deadLetterRoutingKey("order.close")        // 死信路由键
            .build();
}

// 3. 发送延迟消息
rabbitTemplate.convertAndSend("order.exchange", "order.delay", orderMessage);
```

**坑点（面试加分）：**

- **队列级 TTL**：队列里所有消息统一过期时间，先到的消息会被后面更短 TTL 的消息"插队"（RabbitMQ 只检查队头），导致延迟不准
- 解决方案：用**消息级 TTL**，或**每个延迟级别建一个队列**（如 30s、1min、30min 各一个）
- 死信消息会重新入队消费，消费失败要处理好重试，防止死信死循环

结论：**适合已用 RabbitMQ 的团队**，但 TTL 语义有坑，延迟级别多时不优雅。

## 六、方案五：RocketMQ 延迟消息（生产环境首选）

RocketMQ 原生支持延迟消息：发送时指定延迟级别，Broker 到期后才投递给消费者。

```java
Message msg = new Message("ORDER_TOPIC", "close", orderId.getBytes());
// 延迟级别：1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h
msg.setDelayTimeLevel(16); // 16 = 30 分钟，正好对应订单超时
producer.send(msg);
```

消费者无感知，到期自动收到消息：

```java
@RocketMQMessageListener(topic = "ORDER_TOPIC", consumerGroup = "order-close-group")
@Component
public class OrderCloseConsumer implements RocketMQListener<OrderCloseMessage> {

    @Override
    public void onMessage(OrderCloseMessage message) {
        // 幂等：根据订单号查状态，只有 UNPAID 才关闭
        Order order = orderMapper.selectById(message.getOrderId());
        if (order != null && order.getStatus() == OrderStatus.UNPAID) {
            orderService.closeOrder(order.getId());
        }
    }
}
```

**原理**：RocketMQ 把延迟消息先投递到 `SCHEDULE_TOPIC_XXXX`（按延迟级别分 18 个队列），由**定时线程**扫描到期的消息，再转发到真正的 Topic。

**注意**：默认只有 **18 个固定延迟级别**，不能自定义任意秒数。要任意延迟时间，需要改造（如按时间戳做消息存储 + 定时扫描），或升级 RocketMQ 5.x 使用**定时消息**（精确到秒/毫秒）。

| 特性 | RocketMQ 延迟消息 |
|------|-----------------|
| 延迟精度 | 18 个固定级别（5.x 支持任意时间） |
| 可靠性 | 消息持久化，重启不丢 |
| ACK 机制 | 消费失败自动重试（16 次） |
| 积压能力 | 亿级消息毫无压力 |
| 运维成本 | 需部署 RocketMQ 集群 |

## 七、五种方案终极对比

| 方案 | 延迟精度 | 可靠性 | 分布式 | 复杂度 | 适用场景 |
|------|---------|--------|--------|--------|---------|
| 数据库轮询 | 秒~分钟级 | 高 | 支持 | 低 | 对延迟不敏感的小任务 |
| Java DelayQueue | 毫秒级 | 低（重启即丢） | 不支持 | 最低 | 单机内存任务 |
| Redis ZSet | 秒级 | 中（靠持久化） | 支持 | 低 | 中小团队订单超时 |
| RabbitMQ TTL+DLX | 秒级，有坑 | 高 | 支持 | 中 | 已用 RabbitMQ 的团队 |
| RocketMQ 延迟消息 | 级别/秒级 | 高 | 支持 | 中 | 大流量生产环境首选 |

**补充**：Kafka 原生**不支持**延迟队列，需要自研（用时间轮 + 延迟主题），复杂度高，一般不建议。

## 八、生产实践清单（直接背）

1. **消费必须幂等**：无论哪种方案，都可能重复消费，关闭订单前先查状态
2. **状态机兜底**：延迟队列只是"加速器"，数据库任务表 + 定时对账扫尾是最后防线
3. **监控告警**：监控延迟队列积压量、消费延迟时间，超过阈值告警
4. **延迟级别设计**：先梳理业务需要的延迟档位（10s/30s/1m/30m/1h...），再选方案
5. **降级方案**：MQ 挂了，降级到 Redis ZSet；Redis 也挂，降级到数据库轮询

## 九、面试高频追问

**Q1：Redis ZSet 方案，消费者重启期间到期的任务会丢失吗？**
不会。任务在 Redis 里，消费者重启只是停止拉取，重启后会一次性拉到所有到期任务（可能瞬间积压，注意批量拉取的 limit）。

**Q2：ZSet 方案怎么保证任务只被消费一次？**
取和删不是原子的（除非 Lua），两个消费者可能同时 range 到同一个任务。解决方案：Lua 原子化；或者消费者收到后先执行"标记任务为处理中"（如 Redis SETNX 锁），处理完再删。

**Q3：RabbitMQ 队列级 TTL 的坑怎么解释？**
RabbitMQ 惰性检查队头消息：如果队头是 30 分钟过期的消息，后面来了一个 5 秒过期的，必须等队头到期才会检查后面的，导致 5 秒的任务实际延迟 30 分钟。所以延迟级别多时要按级别分队列或用消息级 TTL。

**Q4：为什么不用 Kafka 做延迟队列？**
Kafka 设计目标是高吞吐日志流，没有延迟消息语义，也没有死信和延迟级别的内置支持，自研成本高。延迟队列是 RocketMQ/RabbitMQ 的强项。

**Q5：如果延迟时间要精确到秒且任意指定，选什么？**
RocketMQ 5.x 定时消息（任意时间戳），或者自研：Redis ZSet + 时间轮扫描（参考 Kafka 的时间轮思想），精度可以做到毫秒级。

## 总结

延迟队列的选型本质是**在可靠性、精度、复杂度之间做权衡**：

- 面试先讲需求场景，再讲数据库轮询 → DelayQueue 的局限
- 重点展开 Redis ZSet（最通用）和 RocketMQ（最可靠）两个方案
- 最后补充幂等、对账、监控这三个生产级细节，就是满分回答
