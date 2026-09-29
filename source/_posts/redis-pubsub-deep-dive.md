---
title: 【Redis 原理】发布订阅（Pub/Sub）深度解析：频道与模式订阅、底层结构与 Stream 选型对比
date: 2026-09-29 08:00:00
tags:
  - Redis
  - 中间件
  - 消息
categories:
  - Redis
  - 中间件
author: 东哥
---

# 【Redis 原理】发布订阅（Pub/Sub）深度解析：频道与模式订阅、底层结构与 Stream 选型对比

## 面试官：Redis 的发布订阅用过吗？它和 Kafka 有什么区别？

这个问题看起来在考 API，实际上在考你对**消息模型**的理解：广播 vs 队列、在线 vs 持久、推 vs 拉。

很多人只知道 `SUBSCRIBE` 和 `PUBLISH` 两个命令，被追问「订阅信息存在哪、模式订阅怎么匹配、为什么订阅者掉线消息就丢了、集群里怎么广播的」就答不上来。本文从使用方式一路讲到 Redis 的底层数据结构与集群实现，最后给出与 List / Stream 的选型对比。

## 一、基本模型：频道、模式与消息

Redis 的 Pub/Sub 是典型的**广播模型**：发布者把消息投递到频道，所有订阅该频道的在线客户端都能收到。它不保存消息——**没人订阅，消息就消失**。

```bash
# 订阅一个或多个频道
SUBSCRIBE news.tech news.finance

# 模式订阅：支持 glob 通配符
PSUBSCRIBE news.*

# 发布消息，返回值是「收到消息的订阅者数量」
PUBLISH news.tech "Redis 7.2 released"

# 查看活跃频道与订阅关系
PUBSUB CHANNELS "news.*"
PUBSUB NUMSUB news.tech news.finance
PUBSUB NUMPAT        # 模式订阅的总数
```

订阅者收到的消息是标准的多段（multi-bulk）回复：

```text
1) "message"        # 或 "pmessage"（模式订阅）
2) "news.tech"      # 频道名
3) "Redis 7.2 ..."  # 消息内容
```

模式订阅时多一段原始模式：

```text
1) "pmessage"
2) "news.*"         # 命中的模式
3) "news.tech"      # 实际频道
4) "payload"
```

### 关键特性：订阅后连接进入「受限模式」

一旦客户端执行了 `SUBSCRIBE`/`PSUBSCRIBE`，该连接就**只能执行** `SUBSCRIBE`、`UNSUBSCRIBE`、`PSUBSCRIBE`、`PUNSUBSCRIBE`、`PING`、`QUIT`、`RESET`。这个限制在 RESP2 下是硬性的，**这也是为什么订阅必须用独立连接**。

RESP3（Redis 6+）放开了这个限制：订阅状态下还能执行任意命令，因为它用 push 类型消息与普通回复区分开，不再靠「连接处于订阅态」来解析。

## 二、Java 客户端实践

### Jedis：连接独占，注意用独立连接

```java
try (Jedis subscriber = new Jedis("127.0.0.1", 6379);
     Jedis publisher = new Jedis("127.0.0.1", 6379)) {

    // 必须在独立线程里阻塞接收
    Thread t = new Thread(() -> {
        subscriber.subscribe(new JedisPubSub() {
            @Override
            public void onMessage(String channel, String message) {
                System.out.println("收到 " + channel + " -> " + message);
            }
            @Override
            public void onPMessage(String pattern, String channel, String message) {
                System.out.println("模式命中 " + pattern + " -> " + message);
            }
        }, "news.tech");
    });
    t.setDaemon(true);
    t.start();

    Thread.sleep(200);
    publisher.publish("news.tech", "hello");
}
```

**Jedis 的坑**：订阅用的连接不能复用连接池里的连接，否则会被「借出去就再也还不回来」。实践中要给订阅单独建连接，或者干脆用 Lettuce。

### Lettuce：单连接可多路复用，但订阅要用专用连接

```java
RedisClient client = RedisClient.create("redis://127.0.0.1:6379");

// 订阅：独立的 pub/sub 连接
StatefulRedisPubSubConnection<String, String> sub = client.connectPubSub();
sub.addListener(new RedisPubSubAdapter<>() {
    @Override
    public void message(String channel, String message) {
        System.out.println(channel + " -> " + message);
    }
});
sub.sync().subscribe("news.tech", "news.finance");

// 发布：复用普通命令连接
RedisCommands<String, String> cmd = client.connect().sync();
cmd.publish("news.tech", "hello from lettuce");
```

Lettuce 是线程安全、基于 Netty 的，天生适合共享命令连接；Pub/Sub 用 `connectPubSub()` 拿专用连接即可。

### Spring Data Redis：`MessageListener` + 容器

```java
@Configuration
public class PubSubConfig {

    @Bean
    RedisMessageListenerContainer container(RedisConnectionFactory factory,
                                            MessageListenerAdapter adapter) {
        RedisMessageListenerContainer c = new RedisMessageListenerContainer();
        c.setConnectionFactory(factory);
        // 订阅模式：news.*
        c.addMessageListener(adapter, new PatternTopic("news.*"));
        return c;
    }

    @Bean
    MessageListenerAdapter adapter(NewsHandler handler) {
        // 默认调用 handleMessage(String)
        return new MessageListenerAdapter(handler, "onNews");
    }
}

@Component
class NewsHandler {
    public void onNews(String message) {
        System.out.println("处理消息: " + message);
    }
}
```

`RedisMessageListenerContainer` 会维护订阅连接并在断线后自动重连、重新订阅——**这是生产上强烈建议用它而不是手写订阅的原因**。

## 三、底层实现：两张哈希表 + 一个链表

Redis 的 Pub/Sub 在 `server.h` 中由三个结构支撑：

```c
struct redisServer {
    dict *pubsub_channels;   // 频道 -> 订阅该频道的客户端链表
    dict *pubsub_patterns;   // 模式 -> 订阅该模式的客户端链表
    ...
};
```

- **`pubsub_channels`**：key 是频道名，value 是一个 `list`（链表），节点是订阅该频道的 `client`。`SUBSCRIBE` 就是在链表尾插入客户端，`UNSUBSCRIBE` 就是移除。
- **`pubsub_patterns`**：key 是模式字符串（如 `news.*`），value 同样是客户端链表。
- 早期版本还维护过一个 `list *pubsub_patterns`（存 `pubsubPattern` 结构），Redis 7 之后统一为 dict，模式匹配时遍历 dict 的 key 做 glob 匹配。

**发布时的流程**：

1. 在 `pubsub_channels` 里找到频道对应的客户端链表，逐个把消息写进客户端输出缓冲区（**这是同步的、阻塞的**）；
2. 遍历 `pubsub_patterns` 的所有模式，用 `stringmatchlen()` 做 glob 匹配，命中的客户端也投递一条 `pmessage`；
3. 返回投递的客户端数（注意：**这个数字是「订阅数」，不是「成功送达数」**，因为写入输出缓冲区后客户端可能立刻断线）。

**复杂度**：频道订阅的投递是 O(N)（N 为该频道订阅者数），模式订阅的投递是 **O(M)**（M 为所有模式订阅者数）——Redis 没有为模式建索引，每个 `PUBLISH` 都要遍历所有模式。所以**模式订阅数量大是明确的性能隐患**。

## 四、为什么消息会丢？三条丢失路径

Pub/Sub 的「不持久」体现在三个层面：

| 丢失场景 | 原因 | 后果 |
| --- | --- | --- |
| 发布时无人订阅 | 没有订阅者链表，消息直接丢弃 | 消息凭空消失 |
| 订阅者离线 | 客户端不在 `pubsub_channels` 里 | 离线期间消息全丢 |
| 输出缓冲区溢出 | 慢消费者导致 `client-output-buffer-limit pubsub` 超限 | Redis **直接断开该客户端**，消息丢失 |

第三条最值得警惕。`redis.conf` 默认配置是：

```conf
client-output-buffer-limit pubsub 32mb 8mb 60
```

含义是「硬限制 32MB，软限制 8MB 持续 60 秒」——**一旦订阅端消费慢，把缓冲区撑爆，Redis 会强制关闭连接**。这不是「丢几条消息」，而是整个订阅断掉。

所以 Pub/Sub 的正确用法是：**消费者必须足够快，或者把消息转交给一个异步队列**。

## 五、集群模式下的广播：容易被忽略的坑

Redis Cluster 里，`PUBLISH` 命令会**广播到所有节点**。原理是：客户端把 `PUBLISH` 发给任意节点，该节点把消息转发给集群中所有其他节点（通过集群总线），各节点再投递给本地订阅者。

这带来两个后果：

1. **集群规模越大，广播成本越高**，`PUBLISH` 的延迟随节点数上升；
2. **订阅关系是「节点本地」的**——客户端和服务端断连重连后可能落到不同节点，需要客户端库保证重新订阅（Lettuce/Jedis 的 Cluster 连接会处理，但你要确认版本行为）。

因此集群下用 Pub/Sub 做业务广播要谨慎：**它更适合「配置变更通知」这类低频、可容忍丢失的场景**。

## 六、Keyspace Notification：一个特殊的「内置发布订阅」

Redis 的键空间通知本质上也是走 Pub/Sub 通道，只是发布者是 Redis 自己：

```conf
# 开启过期 + 淘汰事件
notify-keyspace-events Ex
```

```bash
# 订阅所有键的过期事件（__keyevent@<db>__:事件类型）
PSUBSCRIBE __keyevent@0__:expired

# 订阅某个 key 的所有事件
PSUBSCRIBE __keyspace@0__:mykey:*
```

**重要限制**：Redis 的过期是「惰性 + 定期」的，**过期事件在 key 真正被删除时才发布**，因此通知时间可能晚于 TTL 到期时间，甚至在没有访问、定期删除也没扫到时**完全不发布**。所以它不能当作精确的定时器使用。

## 七、Pub/Sub vs List vs Stream：选型对比

这是最能体现深度的一问：

| 维度 | Pub/Sub | List（LPUSH/BRPOP） | Stream |
| --- | --- | --- | --- |
| 模型 | 广播（1:N） | 队列（1:1 竞争消费） | 队列 + 广播（消费组） |
| 持久化 | ❌ 无 | ✅ 有（内存中） | ✅ 有（可 AOF/RDB 持久） |
| 离线消息 | ❌ 丢 | ✅ 保留 | ✅ 保留 |
| 消费确认 | ❌ 无 | ❌ 无 | ✅ XACK + PEL |
| 回溯/重放 | ❌ | ❌ | ✅ XRANGE / XREAD |
| 消费者组 | ❌ | 手动实现 | ✅ XGROUP |
| 阻塞语义 | 天然推送 | BRPOP 阻塞拉 | XREAD BLOCK |
| 适用场景 | 配置推送、事件广播 | 简单任务队列 | 可靠消息、事件溯源 |

选型建议：

- **只要「在线通知」**：Pub/Sub（如网关配置刷新、本地缓存失效广播）；
- **要「可靠投递、必须处理」**：Stream（`XADD` + `XREADGROUP` + `XACK`），或直接用 Kafka/RocketMQ/RabbitMQ；
- **要「延迟任务」**：Redis 的 sorted set + 轮询，或时间轮（RocketMQ 延迟消息）；
- **本地缓存失效广播**：Pub/Sub + 兜底 TTL（因为消息可能丢，必须靠过期时间兜底一致性）。

## 八、面试追问速答

**Q：`PUBLISH` 返回 0 是什么意思？**
当时没有任何订阅者（或模式匹配的订阅者），消息被直接丢弃。它**不代表投递失败**。

**Q：订阅者能收到自己发布的消息吗？**
能，如果它自己订阅了该频道。Redis 不区分「自己」和「别人」。

**Q：`PSUBSCRIBE news.*` 和 `SUBSCRIBE news.a` 会重复收到消息吗？**
会。若一个客户端同时命中频道订阅和模式订阅，会收到两条：一条 `message`，一条 `pmessage`。

**Q：Redis 6 的多线程 IO 会改变 Pub/Sub 的投递吗？**
不会改变模型。命令执行仍是单线程，网卡读写和协议解析可以由 IO 线程并行，投递逻辑（写客户端缓冲区）仍在主线程串行。

**Q：为什么说 Pub/Sub 不能替代 MQ？**
没有持久化、没有 ACK、没有重试、没有消费组、慢消费者会被直接踢掉。它解决的是「实时通知」，不是「可靠消息」。

**Q：`PUBSUB NUMSUB` 和 `PUBSUB NUMPAT` 的区别？**
前者返回指定频道的订阅数（每个频道统计一次，不含模式订阅），后者返回**模式订阅的总订阅者数**（不是模式数）。

## 九、小结

Redis Pub/Sub 是一个「极简广播器」：实现只有两张哈希表，投递是同步的，消息是不落的。它的价值在于**低延迟的在线通知**，而不是消息可靠性。

记住三句话：

1. **订阅必须用独立连接**（RESP2 下的硬约束）；
2. **慢消费者会被 `client-output-buffer-limit` 直接踢掉**——这是丢消息最隐蔽的路径；
3. **要可靠就用 Stream 或专业 MQ，不要把 Pub/Sub 当消息队列用。**
