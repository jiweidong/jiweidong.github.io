---
title: 【Redis 实战】键空间通知（Keyspace Notifications）深度解析：事件订阅、过期回调与延迟任务实践
date: 2026-09-26 08:00:00
tags:
  - Redis
  - 中间件
  - 延迟任务
  - 面试
categories:
  - Redis
  - 中间件实战
author: 东哥
---

# 【Redis 实战】键空间通知（Keyspace Notifications）深度解析：事件订阅、过期回调与延迟任务实践

## 面试官：订单超时未支付要自动关闭，让你用 Redis 的 key 过期来做，怎么做？

这个问题的标准开场是：

```java
redisTemplate.opsForValue().set("order:close:1001", "1", 30, TimeUnit.MINUTES);
```

然后"监听 key 过期"就自动关单。听起来很美，但如果你只能答到这里，面试官下一句就会问：

> **那 Redis 的过期事件准不准？如果事件丢了怎么办？主从、集群下能收到吗？**

答不上来，说明你只是"用过"，没"懂过"。这篇把键空间通知从原理到生产兜底一次讲透。

## 一、键空间通知是什么

Redis 从 2.8.0 开始支持 **Keyspace Notifications**：当 key 被修改、过期、删除、淘汰时，Redis 会向特定的 **Pub/Sub 频道**发布一条消息。

它**不是**独立的回调机制，本质就是**基于现有的发布订阅（PUBLISH/SUBSCRIBE）能力**，把"键事件"变成一个可以订阅的消息流。所以它继承了 Pub/Sub 的所有优点和缺点：

- 优点：轻量、实时、无需轮询；
- 缺点：**fire-and-forget，不持久化，客户端断线期间的事件永久丢失**。

### 两类频道

| 频道模式 | 示例 | 说明 |
| --- | --- | --- |
| Keyspace 频道 | `__keyspace@0__:order:close:1001` | 关注**某个 key** 上发生了什么 |
| Keyevent 频道 | `__keyevent@0__:expired` | 关注**某类事件**发生在哪些 key 上 |

db 编号嵌在频道名里（`@0` 表示 0 号库）。这意味着**跨库订阅需要分开订阅**，`__keyspace@*__` 这种通配只能靠 `PSUBSCRIBE` 的 glob 模式匹配。

```bash
# 订阅 0 号库所有过期事件
PSUBSCRIBE __keyevent@0__:expired

# 订阅某个具体 key 的所有事件
PSUBSCRIBE __keyspace@0__:order:close:1001
```

## 二、开启配置：notify-keyspace-events

默认是**关闭**的（空字符串），必须显式开启，否则你订阅了也收不到任何消息。

```bash
# 运行时开启（重启失效，除非写进配置文件）
CONFIG SET notify-keyspace-events "KEA"

# 查看当前配置
CONFIG GET notify-keyspace-events
```

### 标志位全解析

字符串由若干标志字符组合而成，分为"事件类型"和"键类型"两组。

**第一组：K / E（决定发到哪类频道）**

| 标志 | 含义 |
| --- | --- |
| `K` | 发布 **keyspace** 事件（`__keyspace@db__:key`） |
| `E` | 发布 **keyevent** 事件（`__keyevent@db__:event`） |

**第二组：键类型（决定哪些数据类型的操作会通知）**

| 标志 | 对应的数据类型/场景 |
| --- | --- |
| `g` | 通用命令（DEL、EXPIRE、RENAME、TYPE 等） |
| `$` | String |
| `l` | List |
| `s` | Set |
| `h` | Hash |
| `z` | Sorted Set |
| `x` | 过期事件（expired） |
| `e` | 淘汰事件（evicted） |
| `t` | Stream |
| `m` | key-miss 事件（访问不存在的 key） |
| `n` | new key 事件 |
| `d` | module key 类型 |
| `A` | **等价于 `g$lshzxetmdn`**（除 m、n 外几乎全部） |

常见的三种配置：

```bash
# 只要过期事件（订单超时场景）
CONFIG SET notify-keyspace-events "Ex"

# 只要键空间事件 + 过期
CONFIG SET notify-keyspace-events "Kx"

# 全都要（调试/治理用，注意开销）
CONFIG SET notify-keyspace-events "KEA"
```

**注意 `A` 不含 `m`（key miss）和 `n`（new key）**，这两个要单独加。key-miss 事件在排查缓存穿透时有奇效，但**开销巨大**（每次 miss 都发消息），生产慎开。

## 三、事件类型速查

| 事件 | 触发时机 | 典型用途 |
| --- | --- | --- |
| `expired` | key 因过期被删除 | 延迟任务、订单超时 |
| `evicted` | key 因内存淘汰被删除 | 内存治理、告警 |
| `del` | 显式删除 | 缓存失效联动 |
| `set` / `setex` | 设置值 | 变更广播 |
| `incrby` / `decrby` | 计数变化 | 库存、限流监控 |
| `hset` / `hdel` | Hash 变更 | 本地缓存刷新 |
| `lpush` / `rpush` | List 写入 | 队列监控 |
| `expire` | 设置过期时间 | 审计 |
| `rename_from` / `rename_to` | 重命名 | - |
| `new` | 新 key 创建 | 冷启动、监控（需 n） |
| `keymiss` | 访问不存在的 key | 穿透排查（需 m，开销大） |

## 四、Java 客户端实战

### 4.1 Spring Data Redis（推荐）

Spring Data Redis 内置了 **RedisKeyExpiredEvent** 与监听容器，最省事：

```java
@Configuration
public class RedisKeyspaceConfig {

    @Bean
    RedisMessageListenerContainer keyspaceContainer(RedisConnectionFactory factory) {
        RedisMessageListenerContainer container = new RedisMessageListenerContainer();
        container.setConnectionFactory(factory);
        // 订阅所有库的过期事件
        container.addMessageListener(
            (message, pattern) -> {
                String channel = new String(message.getChannel(), StandardCharsets.UTF_8);
                String body    = new String(message.getBody(), StandardCharsets.UTF_8);
                // channel: __keyevent@0__:expired
                // body   : order:close:1001
                handleExpired(body);
            },
            new PatternTopic("__keyevent@*__:expired")
        );
        return container;
    }

    private void handleExpired(String key) {
        if (key.startsWith("order:close:")) {
            Long orderId = Long.parseLong(key.substring("order:close:".length()));
            // 注意：这里要做幂等 + 状态校验，不能无脑关单
            orderService.closeIfStillUnpaid(orderId);
        }
    }
}
```

也可以只订阅自己关心的 key，减少无关消息：

```java
container.addMessageListener(listener, new PatternTopic("__keyspace@0__:order:close:*"));
```

Spring Boot 还提供了 `KeyExpirationEventMessageListener`，配置键空间事件通道后自动接管：

```yaml
spring:
  redis:
    # 需要自己保证 notify-keyspace-events 已开启
    host: 127.0.0.1
    port: 6379
```

### 4.2 Jedis 原生订阅

```java
try (Jedis jedis = pool.getResource()) {
    jedis.psubscribe(new JedisPubSub() {
        @Override
        public void onPMessage(String pattern, String channel, String message) {
            System.out.println("channel=" + channel + ", key=" + message);
        }
    }, "__keyevent@0__:expired");
}
```

### 4.3 Lettuce

```java
RedisClient client = RedisClient.create("redis://127.0.0.1:6379");
StatefulRedisPubSubConnection<String, String> conn = client.connectPubSub();
conn.addListener(new RedisPubSubAdapter<>() {
    @Override
    public void message(String channel, String message) {
        // 处理
    }
});
conn.async().psubscribe("__keyevent@0__:expired");
```

> 在 Spring Data Redis 里，Lettuce 是默认客户端，但**订阅用的连接是独立连接**，不要和普通命令混用同一个连接（订阅模式下连接不能执行普通命令）。

## 五、核心痛点：过期事件为什么"不准时"

这是面试最容易被追问的地方，也是线上事故的高发区。

### 5.1 Redis 的过期删除策略决定了事件的时机

Redis 删过期 key 有两条路：

| 策略 | 机制 | 是否发过期事件 |
| --- | --- | --- |
| 惰性删除（lazy） | 访问 key 时检查是否过期，过期则删 | 发（在被访问时） |
| 定期删除（active expire cycle） | 每 100ms 随机抽查 20 个设置了 TTL 的 key，删掉过期的 | 发（在抽查到时） |

**这意味着：**

- key 到点了但没人访问，就要等定期删除"抽"到它；
- 抽查是**随机采样**，过期 key 越多、越分散，延迟越大；
- 高负载时定期删除的时间片用完就退出，极端情况下延迟可达**分钟级**；
- 主动过期周期 `hz`（默认 10，即 100ms 一轮）越大越及时，但 CPU 消耗越高。

> **结论：过期事件只能保证"最终会到"，不能保证"准时到"。把精确到秒的定时任务建在它上面，一定会出事。**

### 5.2 另一个坑：事件是"物理删除"时才发

如果在 key 到期前被**显式删除**（`DEL`）或被覆盖（`SET` 无 TTL），就不会有 `expired` 事件，只有 `del` / `set` 事件。业务如果只监听 `expired`，就会漏掉"提前结束"的分支。

### 5.3 主从/集群下的分布问题

| 场景 | 行为 |
| --- | --- |
| 主从复制 | 只有**主节点**触发过期删除并发布事件；从节点删除是主节点同步过来的（逻辑删除），**不重复发事件** |
| Sentinel | 故障转移后，事件由新的主节点发布；客户端需要重连并重新订阅 |
| Cluster | 每个分片（master）独立发布自己的事件；**客户端必须订阅所有分片**才能收全 |

**集群下的正确做法：** 对每个节点建立订阅连接。

```java
for (String node : clusterNodes) { // 每个 master 的地址
    RedisClient client = RedisClient.create("redis://" + node);
    StatefulRedisPubSubConnection<String, String> conn = client.connectPubSub();
    conn.addListener(listener);
    conn.async().psubscribe("__keyevent@0__:expired");
}
```

**这是超高频面试考点**：只连一个节点，你会漏掉大部分事件，而且现象是"偶尔生效、偶尔不生效"，极其难排查。

### 5.4 Pub/Sub 不持久化

Redis Pub/Sub 的语义是 **at-most-once**：

- 消费者离线期间的消息**直接丢弃**；
- 没有 ack、没有重投、没有消费位点；
- 订阅者处理慢会导致消息在客户端接收缓冲区中堆积（`client-output-buffer-limit pubsub`），超限直接被 **踢连接**。

```bash
config set client-output-buffer-limit "pubsub 32mb 8mb 60"
```

被踢 = 断线 = 事件丢失。所以**任何依赖键空间通知做核心业务的系统，都必须有兜底机制**。

## 六、生产级方案：事件通知 + 兜底扫描

正确的架构不是"只靠事件"，而是**事件做实时触发，兜底做最终保证**。

### 6.1 推荐架构

```
写入侧：
  1) 业务数据写 MySQL（订单状态 = PENDING，同时写入 deadline）
  2) 写入 Redis ZSet（按到期时间排序） + 设置 TTL（触发事件）

事件侧（实时，低延迟）：
  3) 订阅 __keyevent@0__:expired
  4) 收到事件 → 校验订单状态 → 若仍未支付则关单（幂等）

兜底侧（可靠，最终一致）：
  5) 定时任务（每分钟）ZRANGEBYSCORE 扫描到期但未处理的记录
  6) 处理前用 SETNX 幂等锁去重，避免与事件侧重复处理
```

### 6.2 兜底扫描代码

```java
@Scheduled(fixedDelay = 60_000)
public void compensateExpiredOrders() {
    long now = System.currentTimeMillis();
    // 取 100 条到期的
    Set<String> due = redis.opsForZSet()
            .rangeByScore("order:delay:zset", 0, now, 0, 100);
    if (due == null || due.isEmpty()) return;

    for (String orderId : due) {
        // 幂等锁：谁先抢到谁处理
        Boolean locked = redis.opsForValue()
                .setIfAbsent("order:closing:" + orderId, "1", 60, TimeUnit.SECONDS);
        if (!Boolean.TRUE.equals(locked)) continue;

        try {
            orderService.closeIfStillUnpaid(Long.valueOf(orderId));
        } finally {
            redis.opsForZSet().remove("order:delay:zset", orderId);
            redis.delete("order:closing:" + orderId);
        }
    }
}
```

### 6.3 幂等是被低估的重点

事件侧和兜底侧可能**同时**处理同一个订单；事件也可能因网络重连等原因重复投递（虽然 Pub/Sub 是 at-most-once，但客户端重连 + 业务重试会造成重复）。所以无论哪条路径，业务处理必须：

1. **状态机校验**：只有 `PENDING` 才能关闭，`PAID`/`CANCELLED` 直接跳过；
2. **数据库乐观锁/条件更新**：

```sql
UPDATE orders
SET status = 'CANCELLED', close_time = NOW()
WHERE id = ? AND status = 'PENDING';
-- 影响行数为 0 表示已被处理，安全跳过
```

3. **分布式锁**去重（如上 `SETNX`）。

## 七、方案对比：延迟任务到底该选谁

| 方案 | 精度 | 可靠性 | 复杂度 | 适用场景 |
| --- | --- | --- | --- | --- |
| Redis 键空间通知 | 秒~分钟级（不保证） | 低（事件可能丢） | 低 | 非核心的过期提醒、缓存联动 |
| Redis ZSet 轮询 | 秒级（取决于轮询间隔） | 中高（可补偿） | 中 | 中小规模延迟任务（推荐） |
| Redis Stream + 消费者组 | 秒级 | 高（持久化 + ack） | 中高 | 需要可靠投递的延迟任务 |
| 时间轮（Netty/Kafka 内部） | 毫秒级 | 单机内存态 | 高 | 框架内部定时、连接管理 |
| MQ 延迟消息（RocketMQ） | 精确（支持固定延迟级别） | 高 | 低 | 订单超时、通知（生产首选） |
| RabbitMQ 延迟队列（TTL+DLX） | 秒级 | 高 | 中 | 中小规模、已有 RabbitMQ |
| XXL-Job 定时扫描 | 分钟级 | 高 | 低 | 兜底补偿、批量对账 |
| RabbitMQ delayed-message 插件 | 毫秒级 | 高 | 低 | 需要精确延迟 |

**选型建议：**

- **核心资金/订单**：RocketMQ 延迟消息 或 时间轮 + 可靠存储，Redis 过期通知只做"加速"；
- **中小规模、非核心**：Redis ZSet 轮询足够，简单可靠；
- **只想省事**：XXL-Job 每分钟扫一次（延迟容忍度高时最稳）。

## 八、性能与运维注意事项

| 注意点 | 建议 |
| --- | --- |
| 事件量 | 大量 TTL key 会产生大量 pub/sub 消息，影响网络与客户端 CPU |
| 键空间事件开销 | 开启后每次操作都要生成事件，`KEA` 全开有明显开销，生产按需开 |
| 大 key/热 key | 热 key 过期会瞬间产生大量订阅消息 |
| 订阅连接数 | 单客户端订阅连接不宜过多；集群下每个 master 一条 |
| 输出缓冲区 | 注意 `client-output-buffer-limit pubsub`，避免被踢 |
| 网络分区 | 断线重连后必须重新订阅 |
| 监控 | 监控 pubsub 连接数、`pubsub_channels`、事件处理延迟 |

```bash
# 查看当前订阅关系与频道
PUBSUB CHANNELS
PUBSUB NUMSUB __keyevent@0__:expired
INFO clients
```

## 九、面试高频追问速查

**Q1：为什么我的过期事件没触发？**
按概率排查：① `notify-keyspace-events` 没开（最常见）；② 事件类型标志位不对（比如只开了 `g` 没开 `x`）；③ key 被显式 `DEL`/覆盖，只有 `del` 事件没有 `expired`；④ 集群下只订阅了一个节点；⑤ 连接断过且没重订阅；⑥ key 根本没写成功（序列化/前缀问题导致 key 名不匹配）。

**Q2：事件会延迟多久？**
无法保证。取决于定期删除的抽查时机、实例负载、TTL key 数量。可以认为"通常秒级到十秒级，极端情况分钟级"。**需要精确时间的场景不要用它。**

**Q3：主从环境下从库会发过期事件吗？**
不会。从库的 key 过期由主节点 DEL 命令同步，从节点不主动过期（读时可能返回空但仍不发事件），事件只在主节点产生。

**Q4：怎么保证不丢事件？**
做不到。Pub/Sub 是 at-most-once。正确做法是**事件 + 兜底扫描**双保险，并用幂等保证重复无害。

**Q5：Cluster 下怎么订阅？**
订阅**所有 master 节点**，各自建立独立连接。因为事件按分片在本地发布，不做跨节点转发。

**Q6：能不能用键空间通知做本地缓存的失效广播？**
可以，但要清楚"可能丢消息"这个前提。更可靠的是用 Redis 6.0 的 **Client-side Caching（RESP3 + tracking）**，由 Redis 主动推送失效通知，语义比手写 pub/sub 更规范。

## 总结

- 键空间通知 = **过期/变更事件 → Pub/Sub 频道**，本质是发布订阅，不是可靠回调；
- 两套频道：`__keyspace@db__:key`（按 key 看）与 `__keyevent@db__:event`（按事件看）；
- 开启靠 `notify-keyspace-events`，常用 `Ex`（过期）或 `KEA`（全开，注意开销）；
- 三大深坑：**事件不准时（惰性+定期删除）、事件可能丢（Pub/Sub 不持久化）、集群必须订阅所有 master**；
- 生产正解：**事件做加速 + ZSet/定时任务做兜底 + 业务幂等**；
- 面试加分点：能讲清 `hz` 与定期删除的关系、`client-output-buffer-limit pubsub` 踢连接、以及为什么核心业务应该优先选 RocketMQ 延迟消息。
