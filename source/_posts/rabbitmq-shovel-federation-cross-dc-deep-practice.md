---
title: 【RabbitMQ 实战】Shovel 与 Federation 深度实战：跨机房消息同步与拓扑治理
date: 2026-10-26 08:10:00
tags:
  - RabbitMQ
  - Shovel
  - Federation
  - 跨机房
  - 消息队列
  - Java
categories:
  - 中间件
author: 东哥
---

# 【RabbitMQ 实战】Shovel 与 Federation 深度实战：跨机房消息同步与拓扑治理

## 前言

单机房 RabbitMQ 玩得很顺，一旦业务要求「双机房/多地部署」，问题立刻变味：

- 两个机房各建一个集群，业务消息怎么互通？
- 跨机房网络 RTT 30ms、偶尔抖动 2 秒，会不会把生产者堵死？
- 同一个队列在两个机房都消费，会不会重复消费、顺序错乱？
- 消费者在 B 机房，生产者只往 A 机房发，怎么让消息「流过去」？

很多人第一反应是「把两个机房组成一个大集群」。这是最危险的做法——RabbitMQ 集群依赖 Erlang 分布式通信，要求低延迟、稳定网络，跨机房组集群会频繁触发网络分区（partition），甚至出现脑裂后队列不可用。

正确姿势是**集群内高可用 + 集群间消息同步**，而 RabbitMQ 官方的两个同步组件就是 Shovel 和 Federation。这篇文章把两者的原理、配置、取舍和生产踩坑讲透。

## 一、先明确边界：什么该跨机房，什么不该

| 场景 | 推荐方案 |
|---|---|
| 同城双活，两个机房都要能读写 | 双集群 + Shovel 双向同步 + 消费端幂等 |
| 异地灾备，主机房挂了备机房接管 | 双集群 + Federation（按需拉取）+ 切换预案 |
| 边缘节点上报数据到中心 | Federation（queue 模式，边缘自治） |
| 单一业务线跨 region 广播 | Federation（exchange 模式） |
| 单纯为了「队列更长」 | ❌ 不要跨机房，正确做法是分区/扩容 |

**核心原则**：跨机房不要共享队列，要让每个机房都有完整的、可独立工作的拓扑。

## 二、Shovel：一条「搬运工」连接

### 2.1 原理

Shovel 是一个内建的 AMQP 客户端：从 **source**（队列）消费消息，再发布到 **destination**（交换机或队列）。它由源集群上的 `rabbitmq_shovel` 插件执行。

```
[机房 A]  queue:order.q  ──Shovel(AMQP client)──▶  [机房 B]  exchange:order.sync ──▶ queue:order.q
```

关键特性：

- **消息级确认**：只有 destination 确认收到（publisher confirm）后，Shovel 才 ack source。所以网络中断不会丢消息。
- **状态在源端**：Shovel 的消费位点由源队列维护，Shovel 进程重启后从队列继续。
- **可配置 prefetch**：控制未确认消息数量，直接影响吞吐和内存。
- **支持静态与动态**：配置文件声明，或运行时通过 `rabbitmqctl set_parameter` 动态创建。

### 2.2 静态配置

```erlang
%% advanced.config 或 rabbitmq.conf 的 shovel 段
%% 方式一：rabbitmq.conf
shovel.orders-to-dr.source = amqp://user:pass@10.0.1.10:5672/%2f
shovel.orders-to-dr.source.queue = order.q
shovel.orders-to-dr.destination = amqp://user:pass@10.0.2.10:5672/%2f
shovel.orders-to-dr.destination.exchange = order.sync
shovel.orders-to-dr.destination.routing-key = order.created
shovel.orders-to-dr.prefetch = 200
shovel.orders-to-dr.ack-mode = on-confirm
shovel.orders-to-dr.reconnect-delay = 5
```

参数说明：

| 参数 | 含义 | 建议 |
|---|---|---|
| `ack-mode` | `on-confirm` / `on-publish` / `no-ack` | 必须 `on-confirm`，否则可能丢 |
| `prefetch` | 未确认消息上限 | 100~500，太大内存涨，太小吞吐低 |
| `reconnect-delay` | 断线重连间隔（秒） | 5~10，避免风暴 |
| `delete-after` | 消息搬完后是否删除 Shovel | 长期同步用 `never` |
| `add-forward-headers` | 是否加 `x-shovelled` 头 | 建议开启，便于排查 |

### 2.3 动态配置（推荐）

生产环境用动态参数更灵活，不用改配置文件重启：

```bash
rabbitmqctl set_parameter shovel orders-to-dr \
'{"src-protocol":"amqp091",
  "src-uri":"amqp://user:pass@10.0.1.10:5672/%2f",
  "src-queue":"order.q",
  "dest-protocol":"amqp091",
  "dest-uri":"amqp://user:pass@10.0.2.10:5672/%2f",
  "dest-exchange":"order.sync",
  "dest-exchange-key":"order.created",
  "prefetch-count":200,
  "ack-mode":"on-confirm",
  "reconnect-delay":5,
  "add-forward-headers":true}'
```

查看状态：

```bash
rabbitmqctl list_parameters
rabbitmqctl eval 'rabbit_shovel_status:status().'
# [{shovel,orders-to-dr,{running,[{src_uri,...}]}}]
```

状态只有 `starting` / `running` / `terminated`。**`terminated` 是要报警的**——常见原因是权限不足、队列不存在、目标 exchange 类型不匹配。

## 三、Federation：拓扑感知的「按需同步」

### 3.1 原理

Federation 不是单一搬运工，而是一组 **upstream（上游）** 配置。下游集群按需向上游拉取消息：

- **Exchange Federation**：下游的 exchange 与上游同名 exchange 建立「链接」，上游收到消息后推给所有有链接的下游。
- **Queue Federation**：下游的队列从上游同名队列拉消息。**多个下游可以同时拉，实现「分布式消费」**。

```
[机房 A] exchange:order.fwd ──federation link──▶ [机房 B] exchange:order.fwd
```

### 3.2 Exchange Federation vs Queue Federation

| 维度 | Exchange Federation | Queue Federation |
|---|---|---|
| 同步对象 | 交换机上的消息副本 | 队列中的消息（竞争消费） |
| 消息归属 | 每个下游都收到一份（广播语义） | 一条消息只被一个下游拿到（分摊语义） |
| 上游是否保留 | 是 | 是（直到被 ack） |
| 典型场景 | 配置变更广播、缓存失效通知 | 边缘采集、跨机房消费扩容 |
| 顺序性 | 不保证 | 不保证 |

这是最容易搞混的地方：**如果你要「两个机房都执行」，用 exchange federation；如果要「两个机房分摊消费」，用 queue federation。**

### 3.3 配置

先启用插件：

```bash
rabbitmq-plugins enable rabbitmq_federation
rabbitmq-plugins enable rabbitmq_federation_management
```

定义 upstream（在**下游**集群上配置）：

```bash
rabbitmqctl set_parameter federation-upstream dc-a \
'{"uri":"amqp://user:pass@10.0.1.10:5672/%2f",
  "expires":3600000,
  "ack-mode":"on-confirm",
  "trust-user-id":false,
  "max-hops":1}'
```

定义 policy，指定哪些 exchange/queue 参与联邦：

```bash
# exchange federation
rabbitmqctl set_policy federate-exchanges "^order\." \
'{"federation-upstream-set":"all"}' --apply-to exchanges

# queue federation
rabbitmqctl set_policy federate-queues "^edge\." \
'{"federation-upstream-set":"all"}' --apply-to queues
```

`max-hops` 很重要：它限制联邦链路能跳几级，防止 A→B→C→A 形成环路导致消息无限循环。默认 1，多级拓扑时要显式设置。

## 四、Java 端代码：生产与消费

跨机房方案对业务代码的最大影响是**必须幂等**——任何同步机制都可能重复投递。

### 4.1 生产者：本地优先 + 事务表

```java
@Service
public class OrderEventPublisher {

    private final RabbitTemplate rabbitTemplate;
    private final OutboxRepository outboxRepository;

    @Transactional
    public void publishOrderCreated(Order order) {
        // 1. 业务写入 + outbox 同一本地事务，保证「业务成功则消息一定可发」
        outboxRepository.save(OutboxEvent.of("order.created", order.getId(), toJson(order)));
    }

    /** 定时任务扫描 outbox，发送成功后标记 */
    @Scheduled(fixedDelay = 1000)
    public void flush() {
        for (OutboxEvent e : outboxRepository.findPending(200)) {
            try {
                rabbitTemplate.convertAndSend("order.sync", e.routingKey(), e.payload(),
                    m -> {
                        m.getMessageProperties().setMessageId(e.eventId());
                        m.getMessageProperties().setHeader("x-source-dc", "dc-a");
                        return m;
                    });
                outboxRepository.markSent(e.id());
            } catch (AmqpException ex) {
                // 不标记，下轮重试；配合退避避免打爆
                break;
            }
        }
    }
}
```

`setMessageId` 是消费端去重的依据，必须在**生产端**生成并固定（不能用发送时随机 UUID，否则重试会变）。

### 4.2 消费者：幂等 + 手动 ack

```java
@Component
public class OrderSyncConsumer {

    private final IdempotentStore idempotentStore;

    @RabbitListener(queues = "order.q", concurrency = "4-16")
    public void onMessage(OrderCreatedEvent event, Message message, Channel channel) throws IOException {
        String msgId = message.getMessageProperties().getMessageId();
        long tag = message.getMessageProperties().getDeliveryTag();
        try {
            // 幂等：SETNX 成功才处理；失败直接 ack
            if (!idempotentStore.tryLock(msgId, Duration.ofHours(24))) {
                channel.basicAck(tag, false);
                return;
            }
            handle(event);
            channel.basicAck(tag, false);
        } catch (BusinessIgnoreException ex) {
            channel.basicAck(tag, false);          // 业务上不可重试，丢弃并记录
        } catch (Exception ex) {
            // requeue=false，进死信，避免毒消息打转
            channel.basicNack(tag, false, false);
        }
    }
}
```

三个要点：

1. **手动 ack**，不要用 `AUTO`。跨机房场景下自动 ack 在消费失败时会丢消息。
2. **`requeue=false`**。反复 requeue 会形成毒消息死循环，把队列打满。失败进 DLX，人工/定时补偿。
3. **幂等键用 messageId**，不要用业务字段拼（业务字段可能合法重复）。

## 五、可靠性设计：跨机房到底能保证什么

| 环节 | 风险 | 对策 |
|---|---|---|
| 生产 → 本机房 | Broker 挂了 | publisher confirm + 本地 outbox + 重试 |
| 本机房队列 | 节点故障 | Quorum Queue（Raft 多数派） |
| Shovel/Federation 链路 | 网络抖动、长时间中断 | `on-confirm` + 断线重连 + 积压监控 |
| 目标机房写入 | 目标不可用 | 源端堆积（要有磁盘水位告警） |
| 消费 | 重复投递 | 幂等表 / 去重键 |
| 双向同步 | 消息回环 | `max-hops`、来源标记 + 过滤、避免 A→B→A |

**不要承诺 exactly-once**。跨机房链路 + 消费重试，工程上只能做到「至少一次 + 幂等消费 = 效果上的恰好一次」。

### 5.1 双向同步的回环问题

如果 A、B 机房互相同步，A 的消息到 B 后，B 的 Shovel 又把它搬回 A，形成死循环。

三种解法：

1. **单向 + 反向独立拓扑**：不同业务走不同方向，不共用 exchange。
2. **加来源头 + 消费端过滤**：`x-source-dc: dc-a`，目标端 `x-match: any` 的 headers exchange 过滤掉回源消息。
3. **`max-hops` 限制**：联邦链路层兜底。

推荐 1 + 2 组合，简单可控。

## 六、监控指标：没有这些就是在裸奔

| 指标 | 采集方式 | 告警阈值 |
|---|---|---|
| Shovel 状态 | `rabbit_shovel_status:status()` | 非 `running` 立即告警 |
| 同步延迟 | 源队列 `messages_ready` 持续增长 | 5 分钟增长 > 1 万 |
| 链路吞吐 | 管理 API `/api/shovels` | 突降 50% |
| 未确认消息 | `messages_unacknowledged` | 持续接近 prefetch 上限 |
| 目标交换机写入失败 | 日志 `connection_closed` | 出现即告警 |
| 磁盘水位 | `disk_free_limit` | 低于 2 倍限值 |

一个实用脚本（管理 API）：

```bash
curl -s -u user:pass http://10.0.1.10:15672/api/shovels | jq '.[] | {name, state, src_uri, dest_uri}'
```

## 七、踩坑清单

| 坑 | 现象 | 根因 | 解决 |
|---|---|---|---|
| 跨机房组集群 | 队列不可用、频繁 partition | Erlang 分布式要求低延迟 | 拆成独立集群 + Shovel |
| `ack-mode: no-ack` | 断网丢消息 | 未等目标确认 | 改 `on-confirm` |
| prefetch 设 5000 | 内存暴涨、GC 频繁 | 未确认消息堆积在客户端 | 降到 100~500 |
| 目标 exchange 类型不符 | Shovel `terminated` | 声明为 direct 实际发 topic | 统一拓扑声明 |
| 只用 queue federation 做广播 | 只有部分机房收到 | 竞争消费语义 | 改用 exchange federation |
| 双向同步未防回环 | 消息量指数增长 | 无 hops/来源过滤 | `max-hops` + headers 过滤 |
| 消费端 `AUTO ack` | 异常时消息丢失 | 容器先 ack 后处理 | 改手动 ack |
| 失败 `requeue=true` | 队列被打满 | 毒消息无限重投 | `requeue=false` + DLX |
| 无幂等 | 重复扣款/重复发货 | 至少一次投递 | messageId + 幂等表 |
| Shovel 与业务队列抢资源 | 业务延迟上升 | 同步占用连接/IO | 独立 vhost 或限流 |

## 八、面试常见追问

**Q1：Shovel 和 Federation 的本质区别？**
Shovel 是「点对点的消息搬运进程」，从一个队列搬到另一个 exchange/queue，语义明确、配置简单，适合固定的两地同步；Federation 是「拓扑感知的按需拉取」，基于 upstream 集合动态建立链路，支持多下游、多级拓扑，适合星型/网状多地部署。Shovel 更可控，Federation 更灵活。

**Q2：跨机房为什么不能组一个 RabbitMQ 集群？**
RabbitMQ 集群靠 Erlang 分布式协议同步元数据与队列状态，Quorum Queue 还依赖 Raft。跨机房 RTT 高、抖动大时，心跳超时会被判定节点失联，触发网络分区；分区期间队列可能不可用，恢复时需要人工介入。即使勉强跑起来，写延迟也被 RTT 放大。

**Q3：怎么保证跨机房不丢消息？**
四段保证：生产端 publisher confirm + 本地 outbox（业务与消息同事务）；本机房 Quorum Queue 持久化；同步链路 `ack-mode=on-confirm`；消费端手动 ack + 幂等。缺任何一段都会在对应环节丢。

**Q4：跨机房消息顺序怎么保证？**
严格全局顺序做不到。能做的是「同一业务键的顺序」：生产端按业务键哈希到固定队列（单消费者），同步链路单 Shovel 单线程搬运，消费端单并发消费。跨机房网络重连仍可能乱序，所以业务上要能容忍或做版本号/状态机校验。

**Q5：Federation 的 `max-hops` 是干什么的？**
限制联邦链路的最大跳数，防止消息在多级拓扑里被反复转发形成环路。默认 1，表示只从直接 upstream 拉取，不再转发给其他 downstream 的 upstream。

## 总结

跨机房 RabbitMQ 的正确姿势可以浓缩成一句话：**集群内用 Quorum Queue 保高可用，集群间用 Shovel/Federation 做同步，业务层用 outbox + 幂等兜底。**

- 要「点对点、可控、固定两地」→ Shovel。
- 要「多地下游、按需拉取、星型拓扑」→ Federation。
- 要「两个机房都执行」→ exchange federation；要「分摊消费」→ queue federation。
- 任何方案都必须配幂等，因为跨机房只能做到至少一次。

把这套组合用对，跨机房消息就不是「玄学可靠性」，而是可度量、可告警、可回滚的工程问题。
