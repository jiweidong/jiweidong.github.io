---
title: 【中间件】Java MQTT 深度实战：从 QoS 等级、会话保持到 Eclipse Paho 物联网海量连接架构
date: 2026-09-28 08:15:00
tags:
  - Java
  - MQTT
  - 中间件
  - 物联网
  - 面试
categories:
  - Java
  - 中间件
author: 东哥
---

# 【中间件】Java MQTT 深度实战：从 QoS 等级、会话保持到 Eclipse Paho 物联网海量连接架构

## 面试官：公司要接 100 万台设备，每台设备状态每秒上报一次，你会用什么协议？

"用 Kafka"是常见的错误答案。Kafka 是**面向大数据吞吐的日志型消息队列**，它的设计前提是消费者数量有限、消息可堆积可回放；而物联网场景的特点是：**连接数极多（百万级）、单连接流量极小（几十字节）、设备网络不稳定、需要"最后一条状态"的语义**。这时候正确的主角是 **MQTT**。

本文从协议原理讲到 Java 落地，把 QoS、会话、遗嘱、保留消息、共享订阅、海量连接架构一次性梳理清楚。

---

## 一、MQTT 是什么

**MQTT（Message Queuing Telemetry Transport）** 是一种基于 **发布/订阅** 模型的轻量级消息传输协议，1999 年由 IBM 为卫星遥测场景设计，现为 OASIS 标准，是物联网事实上的应用层协议。

它的设计目标就四个字：**轻、省、稳**。

| 特性 | 说明 |
|---|---|
| 传输层 | 基于 TCP（MQTT over TLS 用于加密），5.0 另有 MQTT over WebSocket |
| 报文头 | 固定头最小仅 **2 字节** |
| 模型 | 发布/订阅，通过 Broker 解耦 |
| 报文类型 | CONNECT/CONNACK、PUBLISH、SUBSCRIBE/SUBACK、PINGREQ/PINGRESP、DISCONNECT 等 14 种 |
| 版本 | 3.1.1（最广泛）、5.0（新特性：原因码、共享订阅、Topic Alias、消息过期等） |

**核心角色只有三个**：Publisher（发布者）、Subscriber（订阅者）、Broker（代理，如 EMQX、Mosquitto、HiveMQ、VerneMQ）。

---

## 二、Topic：分层命名与通配符

MQTT 的 Topic 是**用 `/` 分隔的层级字符串**，例如：

```
device/1001/telemetry/temperature
factory/shanghai/line2/machine7/status
```

订阅时支持两种通配符：

| 通配符 | 含义 | 示例 |
|---|---|---|
| `+` | 匹配**单层** | `device/+/telemetry` 匹配 `device/1001/telemetry`，不匹配 `device/1001/a/telemetry` |
| `#` | 匹配**多层（含零层）**，只能放末尾 | `device/#` 匹配 `device/1001/telemetry/temperature` |

设计要点：

1. **以 `/` 开头的 Topic 会产生一个空层级**（`/a` 与 `a` 是不同 Topic），要避免；
2. **不要用 `#` 做生产订阅**，性能差且容易误收；
3. **Topic 是"数据模型"**，设计好坏直接决定扩容方式——把设备 ID 放在**第二层**（`device/{id}/...`）方便按 ID 做分片路由；
4. 单条 Topic 长度建议 < 64 字节，避免过大报文头。

---

## 三、QoS：三种投递语义与交互流程

QoS 是 MQTT 最核心的面试点，也是**"消息不丢不重"**的钥匙。

| QoS | 名称 | 语义 | 交互次数 | 典型场景 |
|---|---|---|---|---|
| 0 | At most once | 最多一次，可能丢 | 1（PUBLISH） | 高频遥测、丢一条无所谓 |
| 1 | At least once | 至少一次，可能重复 | 2（PUBLISH→PUBACK） | 指令下发、告警（消费端需幂等） |
| 2 | Exactly once | 恰好一次，不丢不重 | 4（PUBLISH→PUBREC→PUBREL→PUBCOMP） | 计费、扣款、关键指令 |

**QoS 1 流程**：

```
Publisher ──PUBLISH(packetId=1)──▶ Broker ──PUBLISH(packetId=7)──▶ Subscriber
Publisher ◀────PUBACK(1)────────── Broker ◀────PUBACK(7)────────── Subscriber
```

发布端收到 PUBACK 前会**重发**（所以可能重复），`packetId` 用于去重。

**QoS 2 流程（四次握手）**：

```
P ──PUBLISH(id)──▶ B ──PUBLISH(id')──▶ S
P ◀──PUBREC(id)── B ◀──PUBREC(id')── S
P ──PUBREL(id)──▶ B ──PUBREL(id')──▶ S
P ◀─PUBCOMP(id)── B ◀─PUBCOMP(id')── S
```

`PUBREC` 表示"我已收到"，`PUBREL` 表示"可以释放了"，`PUBCOMP` 表示"双向确认完成"。Broker 会暂存消息直到 `PUBCOMP`。

**关键结论（面试必背）**：

> **QoS 是"端到端中每一跳各自协商"的，最终语义由最短的那一跳决定。** 即发布 QoS=2、订阅 QoS=0，实际投递语义是 0。想保证端到端 exactly-once，必须**发布和订阅都用 QoS 2**。

QoS 越高，开销越大（握手次数、Broker 内存、packetId 管理）。生产上**"遥测用 0/1、指令用 1、计费用 2"**是常见策略。

---

## 四、会话保持：Clean Session / Session Expiry

MQTT 的连接是有"状态"的，这是它区别于 HTTP 的重要特点。

| 配置 | 含义 |
|---|---|
| `CleanSession=true`（3.1.1）/ `Clean Start`（5.0） | 每次连接都新建会话，断线后 Broker **立即丢弃**订阅关系与未投递消息 |
| `CleanSession=false` | Broker **持久化会话**：保留订阅关系、离线期间 QoS≥1 的消息（受配额限制），重连后补发 |
| `Session Expiry Interval`（5.0） | 精确指定会话过期时间，0 表示立即过期 |

这对**弱网设备**极其重要：

```
设备断网 5 分钟 → 期间下发了 3 条控制指令(QoS1)
→ CleanSession=false 时，设备重连后自动收到这 3 条
→ CleanSession=true 时，这 3 条永远丢失
```

代价是 Broker 要为每个持久会话占用存储与内存，百万设备时是笔不小的开销，需要配合配额（如 EMQX 的 `max_mqueue_len`、`max_inflight`）控制。

---

## 五、遗嘱（LWT）与保留消息（Retained）

### 5.1 遗嘱消息 Last Will and Testament

设备在 CONNECT 时预先登记一条"遗嘱"。**当 Broker 检测到该设备异常断开（未发 DISCONNECT）时，自动代为发布这条消息**——这是"设备离线感知"的标准做法：

```java
options.setWill("device/1001/status", "offline".getBytes(), 1, true);
```

四个参数：Topic、Payload、QoS、Retain。

### 5.2 保留消息 Retained

普通消息只有**在线订阅者**能收到。若一条消息发布时带 `retain=true`，Broker 会**为该 Topic 保存最后一条**，任何**后订阅**该 Topic 的客户端都会**立即收到这条保留消息**。

典型用法：设备状态、配置下发、版本号……

```
保留: device/1001/status = online
→ 新上线的监控端一订阅 device/1001/status，立刻拿到 "online"，不用等下一次上报
```

**清理保留消息**：向同一 Topic 发送**空 payload + retain=true**。

> 坑：保留消息会随 Topic 数量线性增长，海量 Topic 场景下必须控制保留消息的数量与生命周期，否则 Broker 内存被吃光。

---

## 六、Keep Alive 与心跳

MQTT 依靠 `Keep Alive` 参数（秒）判断连接存活：

- 客户端承诺在 `Keep Alive` 间隔内**至少发一次报文**；
- 若无业务报文，就发 **PINGREQ**，Broker 回 **PINGRESP**；
- Broker 若在 **1.5 × Keep Alive** 内没收到任何报文，判定客户端离线，触发遗嘱。

实战取值：**Keep Alive = 60~120s**。太小会导致海量 PING 报文压垮 Broker；太大则离线感知迟钝（最坏 1.5 倍延迟）。5.0 里可用 `Server Keep Alive` 由服务端覆盖。

---

## 七、Java 实战：Eclipse Paho 完整示例

### 7.1 依赖

```xml
<dependency>
    <groupId>org.eclipse.paho</groupId>
    <artifactId>org.eclipse.paho.client.mqttv3</artifactId>
    <version>1.2.5</version>
</dependency>
```

### 7.2 发布端（自动重连 + 遗嘱 + QoS1）

```java
public class Publisher {
    public static void main(String[] args) throws Exception {
        String broker = "tcp://emqx.example.com:1883";
        String clientId = "pub-" + UUID.randomUUID();
        MqttClient client = new MqttClient(broker, clientId, new MemoryPersistence());

        MqttConnectOptions opts = new MqttConnectOptions();
        opts.setUserName("device");
        opts.setPassword("secret".toCharArray());
        opts.setCleanSession(false);           // 保留会话，离线消息可补发
        opts.setAutomaticReconnect(true);       // 断线自动重连
        opts.setKeepAliveInterval(60);
        opts.setConnectionTimeout(10);
        opts.setMaxInflight(100);               // 在途消息上限，防内存暴涨
        opts.setWill("device/1001/status", "offline".getBytes(), 1, true);

        client.connect(opts);

        MqttMessage msg = new MqttMessage("{\"temp\":26.5}".getBytes(StandardCharsets.UTF_8));
        msg.setQos(1);
        msg.setRetained(false);
        client.publish("device/1001/telemetry/temperature", msg);

        client.disconnect();
        client.close();
    }
}
```

### 7.3 订阅端（手动 ack 保证不丢）

```java
MqttClient client = new MqttClient(broker, "sub-" + UUID.randomUUID(), new MemoryPersistence());

MqttConnectOptions opts = new MqttConnectOptions();
opts.setCleanSession(false);
opts.setAutomaticReconnect(true);
client.setManualAcks(true);   // 关键：手动确认，确保业务处理成功后再 ack
client.connect(opts);

client.subscribe("device/+/telemetry/#", 1, (topic, message) -> {
    try {
        // 1. 先落库/投递到内部队列（保证可靠）
        kafkaTemplate.send("iot-telemetry", topic, message.getPayload());
        // 2. 业务成功后再 ack，否则 Broker 会重投
        client.messageArrivedComplete(message.getId(), 1);
    } catch (Exception e) {
        log.error("处理失败，不 ack，等待重投", e);
        // 也可 messageArrivedComplete 后投递死信，视语义而定
    }
});
```

**`setManualAcks(true)` 是"至少一次"落地的核心**：如果自动 ack，消息一收到就确认，业务处理失败就永久丢失；手动 ack 可以做到"处理成功才确认"。

---

## 八、海量连接架构：百万设备怎么扛

单机 MQTT Broker 的瓶颈在**连接数**（百万长连接 ≈ 每连接几 KB 内核 + 应用内存）与**报文转发**。生产方案通常是 **EMQX 集群 + 自研网关**。

### 8.1 集群架构

```
                     ┌── EMQX Node 1 ──┐
100w devices ── LB ──┼── EMQX Node 2 ──┼── Kafka ── 业务系统
   (MQTT/TLS)        └── EMQX Node N ──┘
```

关键点：

1. **负载均衡必须用 L4**（TCP，七层会破坏长连接语义），且要支持**连接保持**；
2. **客户端 ClientId 唯一**，EMQX 会据此做节点路由（`clientId` 相同会互踢）；
3. **集群发现**：EMQX 5 用 `ekka` 自组网；
4. **落库走 Kafka 解耦**，不要让 MQTT 直连 MySQL，否则突发流量打挂数据库。

### 8.2 共享订阅（Shared Subscription）

多个后端消费者要**分摊**同一 Topic 的消息时，用共享订阅（避免每个节点都收到全量）：

```
主题: $share/group1/device/+/telemetry
```

`$share/{group}/{topic}` 让同一个 group 内只有一个消费者收到某条消息，天然实现**水平扩容 + 负载均衡**。这是替代"Kafka 中转"的轻量方案。

### 8.3 关键调优项

| 项 | 建议 |
|---|---|
| 内核参数 | `net.core.somaxconn`、`net.ipv4.tcp_max_syn_backlog`、`fs.file-max`、`ulimit -n` 调大 |
| TCP 参数 | 关闭 Nagle（`TCP_NODELAY`）、启用 `TCP_FASTOPEN`、合理 `TCP_KEEPALIVE` |
| 会话容量 | `max_mqueue_len`、`max_inflight`、`session_expiry_interval` 严格限额 |
| 报文大小 | 限制 `max_packet_size`，防大报文打爆内存 |
| TLS | 百万连接下 TLS 握手是 CPU 大头，考虑 **session resumption** 与硬件加速 |
| 慢设备 | 启用 **flapping detection**，踢掉反复重连的设备，防止连接风暴 |

### 8.4 设备侧注意事项

- **退避重连**：指数退避 + 抖动，否则断网恢复瞬间百万设备同时重连，直接打垮 Broker；
- **本地缓存**：弱网下本地落盘排队，恢复后补传（QoS1/2 + CleanSession=false）；
- **不要用 QoS2 传遥测**：四次握手在海量场景下开销巨大。

---

## 九、MQTT vs Kafka vs AMQP vs WebSocket

| 维度 | MQTT | Kafka | AMQP(RabbitMQ) | WebSocket |
|---|---|---|---|---|
| 定位 | 物联网设备接入 | 高吞吐日志流 | 企业消息队列 | 全双工实时通道 |
| 连接数 | **百万级** | 有限消费者 | 万级 | 百万级（但需自建协议） |
| 消息模型 | 发布订阅 + Topic 树 | Topic/Partition 日志 | Exchange/Queue 路由 | 自定义 |
| 消息持久化 | 会话级（有限） | **强持久化 + 回放** | 持久化 | 无 |
| 报文开销 | **极小（2B 头）** | 中等 | 较大 | 帧头小但协议自定义 |
| QoS 语义 | 原生 0/1/2 | at-least-once/幂等 | 手动 ack | 无 |
| 离线消息 | 会话级支持 | 靠 offset | 队列堆积 | 无 |
| 典型用途 | 设备遥测/指令 | 数据管道/流处理 | 业务解耦 | 浏览器推送 |

**组合拳**：设备 → MQTT(EMQX) → Kafka → 业务/数仓。**MQTT 负责百万连接与协议适配，Kafka 负责吞吐与回放**，各司其职。

---

## 十、高频踩坑清单

1. **QoS 混用导致消息丢失**：发布 QoS2 订阅 QoS0，端到端就是 QoS0。同一条链路的 QoS 要统一。
2. **ClientId 重复互相踢下线**：动态 ClientId 建议 "业务前缀 + 设备 ID + 随机后缀"。
3. **CleanSession=false + 无限配额**：断线设备会持续堆积离线消息，务必设置 `max_mqueue_len`，否则 Broker OOM。
4. **保留消息不清理**：状态类 Topic 用 retain 很方便，但设备下线时记得发空 payload 清掉。
5. **自动 ack 丢消息**：消费端一定开 `manualAcks`，落库/入队成功后再 ack。
6. **重连风暴**：设备端必须指数退避；Broker 端开 flapping detection。
7. **L4 负载均衡缺失**：用 Nginx 七层代理 MQTT 会直接失败，必须用 TCP 四层。
8. **Topic 设计不当导致订阅爆炸**：`#` 全量订阅 + 百万 Topic = 路由表爆炸。

---

## 十一、面试追问连环炮

**Q：MQTT 为什么比 HTTP 适合物联网？**
A：HTTP 是请求-响应、无状态、报文头大（几百字节起）、每次要建连；MQTT 是长连接、发布订阅、报文头最小 2 字节、有 QoS/遗嘱/保留消息等设备友好语义。设备侧频繁轮询 HTTP 会造成巨大浪费。

**Q：QoS2 真的能保证"恰好一次"吗？**
A：协议层面能保证**在一跳内不重不丢**（通过四次握手 + packetId 去重）。但"恰好一次投递到业务系统"仍依赖业务侧幂等——如果业务处理完但 ack 失败，Broker 会重投。所以**QoS2 ≠ 业务幂等，业务侧仍建议做去重**。

**Q：Broker 怎么知道设备离线？**
A：两种途径：一是收到 DISCONNECT 报文（正常离线）；二是超过 `1.5 × KeepAlive` 没收到任何报文（异常离线），此时触发遗嘱消息并清理/保留会话。

**Q：共享订阅和普通订阅有什么区别？**
A：普通订阅是"广播"，同 group 内每个订阅者都收到全量；共享订阅 `$share/{group}/{topic}` 是"竞争消费"，group 内一条消息只投给一个订阅者，用于后端水平扩容。

**Q：5.0 相比 3.1.1 有哪些关键增强？**
A：原因码（更细的错误反馈）、共享订阅标准化、Topic Alias（压缩报文头）、消息过期（`Message Expiry Interval`）、请求/响应模式（`Response Topic` + `Correlation Data`）、用户属性（自定义元数据）、更好的会话过期控制。

---

## 十二、总结

MQTT 的价值可以浓缩成三句话：

1. **协议轻**：2 字节头 + 长连接，专为海量弱网设备设计；
2. **语义全**：QoS 0/1/2 + 会话保持 + 遗嘱 + 保留消息，覆盖物联网的可靠性诉求；
3. **架构可扩**：共享订阅 + L4 集群 + Kafka 解耦，把"百万连接"变成可运维的工程问题。

下次面试遇到"设备接入""实时推送""百万长连接"，别再条件反射答 Kafka——先把 MQTT 这套讲出来，再补一句"后端吞吐用 Kafka 承接"，层次立刻不一样。
