---
title: 【Kafka 原理】Kafka 分区机制与消费组深度解析：从分区策略到 Rebalance 全流程
date: 2026-08-10 08:00:00
tags:
  - Kafka
  - 消息队列
  - 分布式
  - 面试
categories:
  - 中间件
  - 后端面试
author: 东哥
---

# 【Kafka 原理】Kafka 分区机制与消费组深度解析：从分区策略到 Rebalance 全流程

## 面试官：Kafka 一个 Topic 为什么要分成多个分区？消费者组是怎么分配的？

Kafka 高性能的底层秘密就两个字：**分区**。分区让 Kafka 获得了并行度（吞吐量）、有序性（分区内有序）和水平扩展能力。而消费组（Consumer Group）则是 Kafka 与「传统 MQ 广播/点对点」最不一样的地方。

今天我们把两条主线讲透：**消息如何写入分区（分区策略）** 与 **消费者如何分配分区（消费组与 Rebalance）**，中间穿插 Kafka 的位移管理、顺序消费、消息堆积等高频面试点。

## 一、分区（Partition）基础

### 1.1 为什么要有分区

```
Topic: orders
        ├── Partition 0 ──→ 存储于 Broker 1
        ├── Partition 1 ──→ 存储于 Broker 2
        └── Partition 2 ──→ 存储于 Broker 3
```

- **并行度**：分区是 Kafka 并行读写的最小单位。一个 Topic 有 N 个分区，就有 N 个并行的读写通道，吞吐量随分区数线性增长。
- **顺序性**：Kafka 只保证**分区内有序**，不保证 Topic 全局有序。
- **水平扩展**：分区可以分布在不同 Broker 上，配合副本机制实现负载均衡与高可用。
- **存储友好**：每个分区是磁盘上的一个目录（含多个 log segment 文件），便于顺序写、分段清理。

### 1.2 分区数怎么定？多了少了都有问题

| 分区数 | 问题 |
|--------|------|
| 太少 | 吞吐量上不去，消费者并行度受限（消费者数 > 分区数时多余消费者空闲） |
| 太多 | 文件句柄占用多、Leader 选举时间变长、ZooKeeper 元数据压力大、端到端延迟可能升高 |

经验公式：**分区数 ≈ 目标吞吐量 / 单分区吞吐量**，同时考虑消费者数量（分区数 ≥ 消费者数，最好整数倍）。一般单分区吞吐量在 10~100 MB/s 量级（取决于磁盘、副本数、消息大小）。

## 二、消息如何写入分区：分区策略

Producer 发送消息时通过 `Partitioner` 决定写入哪个分区，核心在 `DefaultPartitioner`：

```java
// DefaultPartitioner.partition() 简化逻辑
public int partition(String topic, Object key, byte[] keyBytes, ...) {
    if (keyBytes == null) {
        // 无 key：粘性分区（Sticky Partitioning），先随机选一个分区，凑满 batch 再换
        return stickyPartitionCache.partition(topic);
    } else {
        // 有 key：对 key 做 murmur2 哈希再取模分区数
        return toPositive(Utils.murmur2(keyBytes)) % numPartitions;
    }
}
```

### 2.1 三种分区策略对比

| 策略 | 规则 | 适用场景 |
|------|------|----------|
| 轮询（Round-Robin） | 顺序轮流写入各分区 | 无 key，追求均衡 |
| 粘性分区（Sticky） | 随机选一个分区，攒满 batch 再换（JDK 新版默认） | 无 key，减少请求次数提升吞吐 |
| key 哈希（Hash） | `hash(key) % 分区数`，相同 key 进同一分区 | 需要**分区内有序**（如同一订单 ID 的消息必须有序） |

### 2.2 顺序性保证的代价

「同一 key 进同一分区」保证了该 key 消息的有序，但代价是**分区可能倾斜**（热点 key 都进一个分区）。这也是「Kafka 如何保证消息有序」面试题的答案：**只能保证分区内有序，全局有序只能设 1 个分区（牺牲吞吐）**。

自定义分区器可实现 `Partitioner` 接口，比如按业务维度（用户 ID 取模、地域）分流。

## 三、消费组（Consumer Group）机制

### 3.1 两种消费模型

传统 MQ 的两种模型：

- **点对点（P2P）**：一条消息只能被一个消费者消费（如 RabbitMQ 队列）。
- **发布订阅（Pub/Sub）**：一条消息广播给所有订阅者。

Kafka 用**消费组统一了这两种模型**：

```
Topic 有 4 个分区，消费者组有 2 个消费者：
  Partition 0 ──→ Consumer A
  Partition 1 ──→ Consumer A
  Partition 2 ──→ Consumer B
  Partition 3 ──→ Consumer B

消息模型对比：
- 组内：点对点（每条消息只被组内一个消费者处理）
- 组间：发布订阅（每个组都能消费到全部消息）
```

### 3.2 核心原则：分区是消费的最小分配单位

- **一个分区同一时刻只能被组内的一个消费者消费**（保证组内不重复消费）。
- 一个消费者可以消费多个分区。
- **消费者数 > 分区数**：多余的消费者空闲（浪费）；**消费者数 < 分区数**：一个消费者消费多个分区。
- 理想情况：**消费者数 = 分区数**，每个消费者独占一个分区，并行度最大化。

### 3.3 消费组的状态机

每个消费组在 Broker 端（新版本 Kafka 用内部 Topic `__consumer_offsets` 存位移，`__consumer_offsets` 有 50 个分区）维护状态：

```
Empty → PreparingRebalance → CompletingRebalance → Stable
                          ↑_________________________|
                                    (成员变化时回到 PreparingRebalance)
```

组协调器（Group Coordinator，从 Broker 中选出，负责管理组）通过心跳与消费者保持联系：`session.timeout.ms`（默认 45s）内没收到心跳，判定消费者死亡，触发 Rebalance。

## 四、Rebalance：消费组的「大换血」

### 4.1 触发时机

1. 组内消费者**加入/退出/宕机**（含 `session.timeout.ms` 超时被踢出）；
2. 分区数**变化**（新增分区）；
3. 订阅 Topic **变化**（正则订阅时新增匹配 Topic）；
4. 主动调用 `unsubscribe()`。

### 4.2 两种分配策略（核心面试点）

**Range（范围分配，默认策略之一）**：按 Topic 逐个分配，每个 Topic 的分区按序号连续分配给消费者。

```
Topic T1: 0,1,2,3  Topic T2: 0,1,2,3   消费者 C0, C1

Range 分配 T1：C0 → [0,1]，C1 → [2,3]
Range 分配 T2：C0 → [0,1]，C1 → [2,3]

问题：订阅多个 Topic 时，C0 总是拿到前面的分区 → 消费者不均衡！
```

**RoundRobin（轮询）**：所有 Topic 的所有分区混在一起轮询分配，订阅的 Topic 数相同时能均衡；订阅 Topic 不同时仍可能不均衡。

**Sticky（粘性，新版本默认）**：在**尽量保持上次分配结果**的前提下做均衡，Rebalance 后分区尽量不换消费者，减少不必要的分区移动和重复消费。这是目前最推荐的策略。

### 4.3 Rebalance 的代价

- 期间组内**所有消费者停止消费**（stop-the-world），等分配完成才能继续。
- 每个消费者需要**重新拉取分配到的分区**，可能**重复消费**（已提交位移的分区不受影响，但未提交位移的会重复）。
- 频繁 Rebalance 会严重拉低吞吐——**这是 Kafka 生产事故的高发区**（比如消费者处理太慢触发超时被踢，引发连环 Rebalance）。

### 4.4 减少 Rebalance 影响的实践

- 调大 `session.timeout.ms`，让偶发的 GC 停顿不触发踢出；
- 调小 `max.poll.interval.ms` 与处理时间的矛盾——用 `max.poll.records` 控制单次拉取条数，避免处理超时；
- 使用 `StickyAssignor` 减少分配变动；
- 使用 Kafka 2.4+ 的**增量协同 Rebalance**（Cooperative Sticky），支持分区级增量调整，不再全组停摆。

## 五、位移（Offset）管理

### 5.1 提交方式

- **自动提交**：`enable.auto.commit=true`（默认），每 `auto.commit.interval.ms`（默认 5s）提交已拉取消息的位移。**可能重复消费**（提交前崩溃）或**丢消息**（拉取后未处理就提交，处理时崩溃）。
- **手动提交**：`enable.auto.commit=false`，处理完业务后 `commitSync()`（同步，失败重试）或 `commitAsync()`（异步，不阻塞但可能丢失提交，需回调处理）。

### 5.2 消费语义（面试高频）

| 语义 | 实现要点 | 风险 |
|------|----------|------|
| At-most-once | 先提交位移，再处理消息 | 可能丢消息 |
| At-least-once | 先处理消息，再提交位移 | 可能重复消费，需业务幂等 |
| Exactly-once | 事务 + 幂等 + 位移与业务原子提交（Kafka 事务 API） | 复杂，仅特定场景 |

生产推荐：**At-least-once + 业务幂等**（消费端去重），这也是最现实的方案。

## 六、面试常见追问

**Q1：Kafka 为什么能那么快？和分区有什么关系？**
顺序写磁盘 + 页缓存（Page Cache）+ 零拷贝（sendfile）+ **分区带来的并行度**。分区让多个消费者并行、多 Broker 分摊负载，这是吞吐的架构基础。

**Q2：如何保证消息有序？**
分区内有序。按 key 哈希保证相同 key 进同一分区；要全局有序只能单分区（吞吐受限）。生产上通常按业务 key（订单 ID、用户 ID）保证**业务维度有序**。

**Q3：消费者宕机后，它的分区怎么处理？**
协调器检测到心跳超时（session.timeout.ms）后把消费者踢出组，触发 Rebalance，它的分区重新分配给其他消费者，从上次提交的位移继续消费（可能少量重复，需幂等）。

**Q4：消费组数量变化会影响其他组吗？**
不会。每个组独立管理位移和 Rebalance，组与组之间互不影响（组间是发布订阅模型）。

**Q5：分区数可以动态增加，为什么不能减少？**
可以增加（`kafka-topics --alter --partitions`），但不能减少——减少分区会导致已有分区数据无法映射（哈希取模对不上），且 Kafka 不支持分区合并。所以**分区数要提前规划好**（考虑未来 2~3 年数据量）。

**Q6：一个消费者能消费多个分区，那能多线程消费一个分区吗？**
不能并行消费同一分区（位移提交会乱）。一个分区同一时刻只能被一个消费者消费，消费者内部可以用多线程处理消息，但位移管理要自己控制（或用 `KafkaConsumer` 的 `pause/resume` 配合）。

## 七、总结

| 维度 | 要点 |
|------|------|
| 分区作用 | 并行度、分区内有序、水平扩展 |
| 分区策略 | 粘性（默认）、key 哈希、轮询、自定义 |
| 消费组 | 组内点对点、组间发布订阅 |
| 分配策略 | Range / RoundRobin / Sticky（推荐） |
| Rebalance | 成员/分区/Topic 变化触发，代价是停摆+重复消费 |
| 位移管理 | 自动 vs 手动提交，At-least-once + 幂等是生产标配 |

最后记住一个思考框架：**Kafka 的一切设计都在围绕「并行」与「顺序」的权衡**——分区给了并行，也限定了顺序（分区内）；消费组给了水平扩展，也带来了 Rebalance 的代价。把这两条主线讲清楚，Kafka 面试就成功了一大半。
