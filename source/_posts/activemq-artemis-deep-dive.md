---
title: 【中间件】ActiveMQ Artemis 深度解析：地址模型、Journal 存储与 Quorum 高可用全实战
date: 2026-09-20 08:00:00
tags:
  - Java
  - ActiveMQ
  - Artemis
  - 消息队列
  - 中间件
categories:
  - Java
  - 中间件
author: 东哥
---

# 【中间件】ActiveMQ Artemis 深度解析：地址模型、Journal 存储与 Quorum 高可用全实战

## 面试官：消息队列你用过哪些？

“Kafka、RabbitMQ、RocketMQ。”——大部分人到此为止。

追问：**“那 JMS 规范的原生实现呢？ActiveMQ 5.x 和 Artemis 是什么关系？”**

这个问题能筛掉八成人。真实答案：

> ActiveMQ Artemis 是 ActiveMQ 的**下一代核心**。它源自 Red Hat 收购的 **HornetQ**，2015 年捐给 Apache 并改名 Artemis，随后 **ActiveMQ 5.x 时代的开发者官方建议新项目直接用 Artemis**。从 ActiveMQ 5.17 起，官方推荐把 Artemis 当作 6.0 的继任者。它不是“又一个 MQ”，而是 **JMS 2.0 全实现 + AMQP 1.0 原生 + 多协议共存**的高性能 broker。

为什么值得单独写一篇？因为它有几个在其他 MQ 里不常见的能力：

- **一套 broker 同时讲 5 种协议**（Core、AMQP 1.0、MQTT、STOMP、OpenWire），迁移期可以灰度切换；
- **地址（Address）与队列（Queue）解耦**的模型，anycast/multicast 一行配置决定点对点还是发布订阅；
- **Journal 存储**用异步 IO + 预写日志，单机吞吐可达几十万 TPS；
- **Quorum（表决）高可用**，用多数派决定谁是 live，避免传统主从的“脑裂 + 双 live”。

下面按架构 → 存储 → 高可用 → 集群 → Spring Boot 实战 → 调优的顺序讲透。

---

## 一、核心架构：Broker / Acceptor / Connector

Artemis 的进程内结构非常清晰：

```
Acceptor (netty-acceptor, port 61616)
      │  接收客户端连接
      ▼
   Broker (ServerSessionPool)
      │
      ├── Address (寻址单元：anycast 或 multicast)
      │      └── Queue (真正的消息容器，可多个)
      │             └── Binding (routingType + filter)
      │
      └── PostOffice (路由引擎) + PagingManager + JournalStorageManager
```

关键组件职责：

| 组件 | 作用 |
| --- | --- |
| `Acceptor` | 监听端口，每个协议一个（`tcp://:61616` Core，`amqp://:5672`，`mqtt://:1883`） |
| `Connector` | 对外连接（集群、桥接、HA 复制都用它） |
| `PostOffice` | 根据地址 + routingType + filter 把消息投到匹配的 Queue |
| `PagingManager` | 内存超限时把消息换出到磁盘（分页） |
| `JournalStorageManager` | 消息与绑定持久化（Journal / JBDC / 只读） |
| `AddressSettingsRepository` | 每个地址的队列行为（DLQ、max-size、过期策略） |

**Acceptor 协议自动探测**：Core 协议端口实际上能自动识别 AMQP/STOMP/MQTT/OpenWire 的首包（`protocols` 参数可限制）。所以升级期可以只开一个 61616 端口，老客户端（OpenWire）和新客户端（AMQP 1.0）共存。这是 Artemis 迁移能力的关键。

---

## 二、地址模型：anycast 与 multicast 的本质

这是 Artemis 最有辨识度的设计，也是面试高频点。

```xml
<!-- broker.xml -->
<addresses>
  <!-- 点对点：地址下每条消息只被一个消费者消费 -->
  <address name="order.create">
    <anycast>
      <queue name="order.create.q1"/>
      <queue name="order.create.q2"/>
    </anycast>
  </address>

  <!-- 发布订阅：地址下每个队列都收到一份 -->
  <address name="event.topic">
    <multicast>
      <queue name="sub.inventory"/>
      <queue name="sub.marketing"/>
    </multicast>
  </address>
</addresses>
```

- **anycast**：地址 = 逻辑目的地，消息**只投给其中一条队列**，多条队列意味着负载均衡（或分片）。这是 JMS Queue 语义。
- **multicast**：消息**复制到每条队列**，每条队列是一个订阅。这是 JMS Topic 语义。

**更妙的是：运行时可以动态加队列。** 发一条 multicast 消息前，客户端可以先 `createQueue` 一个持久订阅，broker 自动补齐历史消息（配合 retrodelivery）。所以“订阅者慢启动”不会丢消息，这是很多 MQ 的痛点。

**自动创建**：`auto-create-queues` 与 `auto-create-addresses` 默认开启，客户端发消息时地址不存在会自动建。**生产强烈建议关掉**，改用 `<addresses>` 显式声明 + `<address-setting>` 统一策略，否则一个拼错的地址就会静默创建一堆僵尸队列。

```xml
<address-setting match="order.#">
  <dead-letter-address>DLQ</dead-letter-address>
  <max-delivery-attempts>5</max-delivery-attempts>
  <expiry-address>ExpiryQueue</expiry-address>
  <redelivery-delay>2000</redelivery-delay>
  <redelivery-delay-multiplier>2</redelivery-delay-multiplier>
  <max-size-bytes>512MB</max-size-bytes>
  <page-size-bytes>10MB</page-size-bytes>
  <max-size-bytes-reject-threshold>-1</max-size-bytes-reject-threshold>
</address-setting>
```

**`match` 支持通配**：`order.#` 匹配所有以 order. 开头的地址，`#` 匹配剩余所有。策略配置用通配，能极大减少重复。

---

## 三、存储：Journal、Paging、Large Message

### 3.1 Journal（预写日志）三件套

Artemis 的持久化不是“一表一行”，而是三组文件：

| 目录 | 内容 | 特点 |
| --- | --- | --- |
| `journal/` | 消息体 + 绑定记录（append-only） | 顺序写，主 IO |
| `bindings/` | 队列/地址绑定关系 | 启动时加载，很小 |
| `largemessages/` | 超过 `min-large-message-size` 的消息 | 独立文件，避免撑大 journal |

写入流程（简化）：

```
producer.send() → 路由到 queue → 追加到 journal (append)
                → 异步刷盘 (ASYNCIO / NIO)
                → 返回 ack（取决于 journal-type 与 block-on-durable-send）
```

`journal-type` 三选一：

- **ASYNCIO**：Linux 原生 AIO（`libaio`），真正的异步提交，**吞吐最高**，推荐生产使用；
- **NIO**：Java NIO，`O_DIRECT` 可选，兼容性最好；
- **MAPPED**：内存映射，速度不如前两者但在容器环境稳定。

刷盘策略：

```xml
<journal-type>ASYNCIO</journal-type>
<journal-buffer-size>501760</journal-buffer-size>
<journal-sync-transactional>true</journal-sync-transactional>   <!-- 事务消息刷盘 -->
<journal-sync-non-transactional>true</journal-sync-non-transactional>
<block-on-durable-send>true</block-on-durable-send>             <!-- 关键：生产必开 -->
```

**面试重点**：`block-on-durable-send=true` 才有 “持久消息落盘后才返回 ack” 的语义。关掉它以换取吞吐，等于把持久化降级为“异步刷盘”，掉电会丢消息。Kafka 里对应的是 `acks=all` + `min.insync.replicas` 的权衡，思路一致。

### 3.2 Paging：内存与磁盘的换页

当队列堆积超过内存阈值，Artemis 把消息**整体分页到磁盘**，消费时按页加载：

```xml
<global-max-size>1GB</global-max-size>              <!-- broker 级内存上限 -->
<max-size-bytes>512MB</max-size-bytes>              <!-- 单地址阈值 -->
<page-size-bytes>10MB</page-size-bytes>
<address-full-policy>PAGE</address-full-policy>     <!-- PAGE / BLOCK / DROP / FAIL -->
```

`address-full-policy` 四种行为差异很大：

| 策略 | 行为 | 适用 |
| --- | --- | --- |
| `PAGE` | 换页到磁盘，继续接收 | 默认，容忍堆积 |
| `BLOCK` | 阻塞生产者直到有空间 | 强背压，防雪崩 |
| `DROP` | 直接丢弃新消息 | 日志/监控类可丢数据 |
| `FAIL` | 抛异常给生产者 | 业务感知明确 |

Paging 的代价是**读写放大**：页内消息要被加载进内存才能投递，page 文件与 journal 文件双写。所以长期大量 paging 的 broker，磁盘 IO 会成瓶颈。

### 3.3 Large Message

默认 `min-large-message-size=100KB`，超过则消息体单独落盘，只在 journal 里存引用。好处是避免大消息拖慢 journal 文件轮转；坏处是消费大消息要走额外的文件 IO。

**实践建议**：**不要在 MQ 里传大消息**（>1MB 的图片、文件）。把文件放对象存储，消息里只传 URL。这是所有 MQ 的通用最佳实践，Artemis 也不例外。

---

## 四、高可用：复制的两种形态与 Quorum

Artemis HA 只有两大流派：

### 4.1 Shared Store（共享存储）

live 与 backup 共用同一份 journal（NFS/GFS2/JDBC），靠**文件锁**决出谁是 active：

```xml
<ha-policy>
  <shared-store>
    <primary>
      <failover-on-shutdown>true</failover-on-shutdown>
    </primary>
  </shared-store>
</ha-policy>
```

**优点**：切换快，不复制流量。
**缺点**：**存储是单点**（NFS 挂了两个一起挂），且文件锁在网络存储上不可靠，容易脑裂。云环境基本不推荐。

### 4.2 Replication（复制）

live 把 journal 实时复制给 backup，backup 常驻但不接管数据：

```xml
<!-- live -->
<ha-policy>
  <replication>
    <primary>
      <quorum-size>2</quorum-size>
      <vote-on-replication-failure>true</vote-on-replication-failure>
    </primary>
  </replication>
</ha-policy>
```

**Quorum（表决）机制是 Artemis 2.19+ 的重点改进**：

- 老版本的问题：live 网络抖动时，backup 误判 live 死了，直接接管 → **双 live 脑裂**，两边各写一份 journal。
- Quorum 方案：引入多个“表决节点”（通常是同一集群里的其他 broker 或独立的 `quorum-vote` 参与者），live 必须先拿到**多数派同意**才允许降级/切换。数量对不上，谁也不动，宁可短暂不可用也不脑裂。

`quorum-size` 就是决定阈值。配置经验：**部署 3 个投票者，quorum-size=2**，可容忍 1 个抖动。

### 4.3 客户端 failover URL

高可用最终体现在客户端侧：

```java
String url = "tcp://broker1:61616,tcp://broker2:61616"
        + "?ha=true"
        + "&reconnectAttempts=-1"          // 无限重连
        + "&retryInterval=1000"
        + "&retryIntervalMultiplier=2.0"
        + "&maxRetryInterval=30000"
        + "&initialConnectAttempts=10"
        + "&connectionTTL=30000";
ActiveMQConnectionFactory factory = new ActiveMQConnectionFactory(url);
```

`ha=true` 时客户端会接收 broker 推送的拓扑变更（拓扑传播），**自动切到新 live**。这是 Artemis 相对 ActiveMQ 5.x 的巨大进步——5.x 的 failover 靠客户端列表轮询，切换慢且需要人工干预。

---

## 五、集群：消息如何跨节点流动

Artemis 集群由两个机制组成：

### 5.1 Cluster Connection：负载均衡

```xml
<cluster-connection name="my-cluster">
  <connector-ref>netty-connector</connector-ref>
  <retry-interval>500</retry-interval>
  <max-hops>1</max-hops>
  <message-load-balancing>STRICT</message-load-balancing>  <!-- OFF / STRICT / ON_DEMAND -->
  <notification-interval>1000</notification-interval>
  <notification-attempts>2</notification-attempts>
</cluster-connection>
```

- **OFF**：不转发（纯本地，队列需预先分片到各节点）；
- **STRICT**：无条件把消息均衡分发到所有节点（**默认，但极易踩坑**——你只想让某节点处理，它偏发到别的节点）；
- **ON_DEMAND**：只有当远端节点有**活跃消费者**时才转发。**绝大多数生产场景应该用 ON_DEMAND**。

### 5.2 Redistribution（重新分配）

当消费者断开，其所在节点上堆积的消息需要“回流”给仍有消费者的节点继续消费：

```xml
<address-setting match="order.#">
  <redistribution-delay>2000</redistribution-delay>  <!-- 0 = 禁用 -->
</address-setting>
```

**这是 Artemis 区别于 Kafka 的一个点**：Artemis 的队列消息可以跨节点搬移（消息重分布），而 Kafka 的分区是固定的。代价是重分布期间的额外网络与磁盘开销。

**陷阱**：`redistribution-delay=0` 关闭了重分布，同时又用 `STRICT` 负载均衡，会造成“消费者都挂在一个节点、消息却在另一个节点堆积”的诡异现象。排查时先看 `artemis queue stat` 的消费者数与消息数分布。

---

## 六、Spring Boot 实战

`spring-boot-starter-artemis` 开箱即用：

```yaml
spring:
  artemis:
    mode: native                       # 也可 embedded 用于测试
    broker-url: tcp://broker1:61616,tcp://broker2:61616?ha=true
    user: artemis
    password: artemis
    pool:
      enabled: true
      max-connections: 20
      idle-timeout: 30000
    # 对应的原生属性（如自动创建）在生产建议关掉
```

### 6.1 发送：事务消息 + 发送方确认

```java
@Service
public class OrderProducer {

    private final JmsTemplate jmsTemplate;

    public OrderProducer(JmsTemplate jmsTemplate) {
        this.jmsTemplate = jmsTemplate;
        this.jmsTemplate.setSessionTransacted(true);     // 开启事务会话
        this.jmsTemplate.setDeliveryPersistent(true);
    }

    @Transactional                                  // 与 DB 同事务（需 JmsTransactionManager 联调）
    public void send(Order order) {
        jmsTemplate.convertAndSend("order.create", order, m -> {
            m.setStringProperty("traceId", MDC.get("traceId"));
            m.setIntProperty("version", order.getVersion());
            m.setJMSPriority(4);
            return m;
        });
    }
}
```

**关于“数据库 + MQ”原子性**：`JmsTemplate` 的事务和 JDBC 事务是两个独立事务，`@Transactional` 默认只包住 DataSource。要真正一致，需要 **XA（`JtaTransactionManager`）** 或 **本地消息表**。**XA 性能差、运维复杂，我强烈建议用本地消息表方案**——这一点和 Spring Integration 那篇的结论完全一致。

### 6.2 消费：并发 + 手动确认 + 死信

```java
@Component
public class OrderConsumer {

    @JmsListener(destination = "order.create",
                 concurrency = "5-20",               // 动态并发
                 containerFactory = "orderContainerFactory")
    public void onMessage(Order order, Session session, Message message)
            throws JMSException {
        try {
            orderService.handle(order);
            session.commit();                        // 手动/事务提交
        } catch (NonRetryableException e) {
            // 不可重试：直接进 DLQ，不浪费重试次数
            session.rollback();
        }
    }
}

@Bean
public DefaultJmsListenerContainerFactory orderContainerFactory(
        ConnectionFactory cf, PlatformTransactionManager tm) {
    DefaultJmsListenerContainerFactory f = new DefaultJmsListenerContainerFactory();
    f.setConnectionFactory(cf);
    f.setSessionTransacted(true);
    f.setConcurrency("5-20");
    f.setErrorHandler(t -> log.error("消费异常", t));
    return f;
}
```

**重试与死信链路**：消费抛异常 → 按 `redelivery-delay`（支持指数退避）重投 → 达到 `max-delivery-attempts=5` → 进 `DLQ`，并在消息上打 `_AMQ_ORIG_ADDRESS`、`_AMQ_ORIG_QUEUE` 头，便于排查与回放。

---

## 七、监控与调优

### 7.1 必看的指标

```bash
# broker 概览
artemis queue stat --url tcp://localhost:61616
artemis address stat
artemis browse --queue order.create        # 只看不消费，排查神器
artemis check queue --name order.create --produce 100 --consume 100
```

| 指标 | 含义 | 阈值建议 |
| --- | --- | --- |
| `messageCount` | 队列堆积 | 持续增长即告警 |
| `consumerCount` | 活跃消费者 | 为 0 且堆积 > 0 → 立即告警 |
| `deliveringCount` | 正在投递 | 长期高位说明下游慢 |
| `journal` 使用率 | 磁盘预写日志余量 | > 80% 告警（不够会阻塞写） |
| `paging` 计数 | 换页次数 | 持续增长说明内存不足 |

这些指标都能通过 **Jolokia（`/console/jolokia`）+ Prometheus exporter** 抓取，和 Grafana 对接。

### 7.2 高频调优参数

```xml
<!-- 提升吞吐 -->
<global-max-size>2GB</global-max-size>
<journal-pool-size>10</journal-pool-size>
<journal-max-io>1</journal-max-io>            <!-- 机械盘 1，NVMe 可加大 -->
<!-- 提升投递效率 -->
<default-consumer-window-size>1048576</default-consumer-window-size>
<consumer-window-size>1048576</consumer-window-size>
<!-- 线程池 -->
<thread-pool-max-size>60</thread-pool-max-size>
<scheduled-thread-pool-max-size>10</scheduled-thread-pool-max-size>
```

**`default-consumer-window-size` 是关键**：它决定 broker 可以“不等客户端 ack 就继续推送”多少字节。太小 → 往返次数多、吞吐低；太大 → 单个慢消费者占用内存多。默认 1MB 对大多数场景合适。

---

## 八、横向对比：Artemis vs Kafka vs RabbitMQ vs RocketMQ

| 维度 | Artemis | Kafka | RabbitMQ | RocketMQ |
| --- | --- | --- | --- | --- |
| 模型 | 地址/队列，支持 anycast+multicast | 分区日志 | Exchange/Queue | Topic/Queue |
| 协议 | Core/AMQP1.0/MQTT/STOMP/OpenWire | 自有协议 | AMQP 0-9-1/MQTT/STOMP | 自有 |
| JMS 支持 | JMS 2.0 完整（含 XA） | 无 | 需插件 | 部分 |
| 消息回溯 | 无（消费即删，除非配 DLA） | **有，按 offset** | 无 | 有 |
| 顺序消息 | anycast 单队列 + 单消费者 | 分区内有序 | 单队列有序 | 队列内有序 |
| 事务 | JMS 事务 + XA | 事务 API（EOS） | 支持 | 事务消息 |
| 吞吐 | 十万级 | 百万级 | 万级 | 十万级 |
| 延迟 | 极低（μs~ms） | 低（ms） | 极低 | 低 |
| 最佳场景 | JMS 标准、企业集成、协议混合 | 日志/流处理/大数据管道 | 路由灵活、中小规模 | 电商交易、金融 |

**一句话选型**：如果你的系统要求 **JMS 2.0 规范、XA 事务、多协议接入**，Artemis 是 Java 世界里最正统的答案；如果要求**高吞吐 + 回溯 + 流处理**，选 Kafka；如果要求**灵活路由 + 低运维成本**，选 RabbitMQ。

---

## 九、面试追问连环炮

**Q1：Artemis 的 anycast 队列有多个，消息怎么分配？**
默认轮询（round-robin）投递给有消费者的队列。注意这里的分发发生在**broker 端**，依据是队列的消费者状态，而不是分区哈希——所以它**不保证同一订单消息落到同一队列**。需要业务有序时，用单队列 + 单消费者，或用消息分组（`_AMQ_GROUP_ID`）让同组消息固定路由到同一消费者。

**Q2：Quorum 机制为什么能防脑裂？**
因为“接管”变成了需要**多数派同意**的分布式决策。假设 3 个投票者，网络分区把 live 隔出去后，backup 只能拿到 1 票（自己）→ 达不到 quorum-size=2 → 不接管，集群进入“不可写但一致”状态。这跟 Raft 的多数派写原理同源：**宁可 CAP 里选 C，也不要双写**。

**Q3：消息丢失的三个可能环节？**
① 生产者没开 `block-on-durable-send` 或用了非持久消息（`deliveryMode=NON_PERSISTENT`）；② broker 未刷盘就宕机（journal buffer 未 sync）；③ 消费者开了自动确认（`AUTO_ACKNOWLEDGE`）但业务还没处理完就崩了。**正确姿势**：持久消息 + `block-on-durable-send=true` + 消费端 `CLIENT_ACKNOWLEDGE`/事务会话。

**Q4：重复消费怎么解决？**
Artemis 默认至少一次投递。消费端必须幂等：唯一键约束、Redis 去重、状态机。注意 redelivery 场景下同一个 `JMSMessageID` 会重复出现——**用业务唯一键，而不是消息 ID**（客户端重发会生成新 ID）。

**Q5：QueueChannel 堆积了 500 万条消息，怎么救？**
① 先 `artemis browse --queue xxx --limit 10` 看内容判断是否垃圾；② 如果是积压有效消息，临时扩容消费者（`concurrency` 上限 + 加节点）；③ 如果是死信循环，先改地址策略（提高 `max-delivery-attempts` 或加 `redelivery-delay`）再消费；④ 极端情况用 `artemis queue purge`（危险，先备份 journal）。**根因通常是消费端慢或重试风暴**，别只想着加机器。

**Q6：Artemis 用的是 JMS 还是 AMQP？**
两者都支持，而且可以混用：同一条消息可以被 AMQP 1.0 客户端生产、被 Core 协议消费者消费。Artemis 内部把 AMQP 的元素映射到自己的 Address/Queue 模型。所以做多语言系统时，Java 端用 Core/AMQP，Go/Python 端用 AMQP/MQTT，中转零成本。

---

## 十、生产落地清单

- **关闭自动创建**：`auto-create-queues=false`、`auto-create-addresses=false`，显式声明地址。
- **持久化默认开**：`block-on-durable-send=true`、`journal-type=ASYNCIO`。
- **策略通配化**：用 `match="order.#"` 统一 DLQ、过期、重试策略。
- **负载均衡用 ON_DEMAND**，并配 `redistribution-delay`（5000ms 左右）。
- **高可用用 replication + quorum-size=2**，别用共享存储 NFS。
- **必开监控**：queue 堆积、消费者数、journal 磁盘、paging 次数。
- **消息体要小**：>1MB 走对象存储 + URL。
- **消费必须幂等**：至少一次投递是必然，不是意外。

## 总结

ActiveMQ Artemis 是被严重低估的 MQ：它有 Kafka 没有的 **JMS 2.0 + XA + 多协议**，有 RabbitMQ 没有的**异步 IO 高吞吐与 Quorum HA**，还有独特的 **Address/Queue 解耦模型 + 消息重分布**。

理解它的三条主线就够用了：

1. **寻址**：address + anycast/multicast 决定点对点还是广播；
2. **持久**：journal 顺序写 + paging 换页 + large message 外置；
3. **可用**：replication + quorum 表决，宁可不可用也不双 live。

把这三条讲清楚，面试里的 MQ 深度题你都能接住；把它用对，企业集成场景里你会比“只会 Kafka”的人多一个关键选项。
