---
title: 【Kafka 原理】Kafka 副本机制与 ISR 深度解析：从副本同步到 Leader 选举与数据可靠性
date: 2026-08-09 08:00:00
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

# 【Kafka 原理】Kafka 副本机制与 ISR 深度解析：从副本同步到 Leader 选举与数据可靠性

## 面试官：Kafka 的副本是怎么同步的？ISR 是什么？为什么 Kafka 用 ISR 而不用 Raft？

Kafka 高可靠性的基石是**副本机制（Replication）**，而理解副本机制的核心钥匙是 **ISR（In-Sync Replicas，同步副本集合）**。面试中关于「Kafka 为什么不会丢消息」「Leader 挂了怎么办」「acks 参数到底影响什么」的问题，答案全藏在 ISR 里。

今天我们从分区副本的架构讲起，深入 ISR 的判定与收缩扩张机制、HW 与 LEO 的推进逻辑、Leader 选举的细节，最后对比 Raft 选举，把 Kafka 副本机制一网打尽。

## 一、副本机制基础架构

### 1.1 分区与副本的关系

```
Topic: orders（3 个分区 × 3 个副本 = 9 个副本，分布在 3 个 Broker 上）

Broker 1           Broker 2           Broker 3
┌────────────┐    ┌────────────┐    ┌────────────┐
│ Partition 0 │    │ Partition 0 │    │ Partition 0 │
│  (Leader)  │    │ (Follower) │    │ (Follower) │
│ Partition 1 │    │ Partition 1 │    │ Partition 1 │
│ (Follower) │    │  (Leader)  │    │ (Follower) │
│ Partition 2 │    │ Partition 2 │    │ Partition 2 │
│ (Follower) │    │ (Follower) │    │  (Leader)  │
└────────────┘    └────────────┘    └────────────┘
```

核心规则：
- **一个分区只有一个 Leader**：所有读写都走 Leader（0.11 版本后 Follower 可以参与消费，但写入必须 Leader）
- **Follower 只做一件事**：从 Leader 拉取数据，保持同步
- **Leader 挂了，从 ISR 里选新 Leader**

### 1.2 为什么读写都走 Leader？

- **保证一致性**：所有副本都从 Leader 同步，避免脑裂后的数据不一致
- **简化设计**：写入顺序就是 Leader 上的顺序，Follower 按序拉取，天然有序
- 代价：Leader 会成为瓶颈，所以 Kafka 用「分区粒度」分散压力——不同分区的 Leader 分布在不同 Broker 上，实现负载均衡

## 二、ISR：同步副本集合

### 2.1 什么是 ISR？

**ISR（In-Sync Replicas）**：与 Leader 保持「足够同步」的副本集合，由 **Leader 所在 Broker 的副本管理器（ReplicaManager）** 维护，保存在 ZooKeeper（KRaft 模式则保存在元数据日志中）。

```
ISR = {Leader, Follower A, Follower B}   ← 都是同步副本
Follower C 同步太慢 → 被踢出 ISR
```

**关键点**：ISR 是**动态变化**的——同步跟不上的副本会被踢出，追上后又会被加回来。

### 2.2 副本的两种状态

| 状态 | 含义 | 影响 |
|------|------|------|
| 在 ISR 中 | 与 Leader 保持同步（滞后可容忍） | 可以参与 Leader 选举，`acks=all` 时写入成功必须包含它 |
| 不在 ISR 中 | 落后太多或失联 | 不能参与选举，写入不算它，但会继续拉取追赶 |

### 2.3 ISR 的判定：落后多少算「不同步」？

```java
// Kafka 源码：KafkaConfig.scala
// replica.lag.time.max.ms 默认 30000（30 秒）
val ReplicaLagTimeMaxMs = 30000
```

判定规则（0.9 版本之后不再看「落后多少条消息」，只看**时间**）：

> 如果一个 Follower 在 `replica.lag.time.max.ms`（默认 30s）内**没有向 Leader 发起任何 Fetch 请求**（拉取数据），或者 **Fetch 请求没有任何数据返回**（追上了但没新数据也算正常心跳），就会被踢出 ISR。

**为什么看时间不看条数？** 早期版本用「落后条数」判定，在高吞吐下 Leader 堆积快、Follower 偶尔波动就会误踢；用时间判定更鲁棒——只要 Follower 还在持续拉取（哪怕落后），就认为它「活着且在追赶」。

### 2.4 ISR 的收缩与扩张

```java
// 收缩：定时任务检查（kafka-replica-fetcher 线程 + 副本管理器）
// 每 replica.lag.time.max.ms 检查一次
// Follower 长时间没拉取 → 从 ISR 移除 → 记录到 ZooKeeper / KRaft 元数据

// 扩张：Follower 追上 HW（High Watermark，高水位）后
// 重新加入 ISR
```

**面试常问**：ISR 收缩后会有数据丢失风险吗？
- 如果 Leader 在 ISR 收缩后挂了，新 Leader 从剩余 ISR 中选，**未同步的数据（落后副本独有）会被截断**，这部分消息就「丢了」
- 这是 Kafka 在「可用性」和「一致性」之间的权衡：宁可丢少量消息，也不能让集群不可用

## 三、HW 与 LEO：副本同步的基石

### 3.1 两个核心水位

```
LEO（Log End Offset）：日志末端偏移量，即「下一条要写入的偏移量」
HW（High Watermark）：高水位，即「所有 ISR 副本都已同步到的偏移量」
消费者只能读到 HW 之前的消息！HW 之后的消息视为「未提交」
```

```
Partition 0 的日志（偏移量从 0 开始）：

Leader:   [0][1][2][3][4][5][6]        LEO=7
Follower A: [0][1][2][3][4]            LEO=5
Follower B: [0][1][2][3][4][5][6]      LEO=7

所有 ISR 副本都有的最小偏移 = 5
HW = 5  →  消费者只能读到 offset 4 之前的消息
```

### 3.2 HW 的推进机制

**关键：HW 由 Leader 根据「所有 ISR 副本的 LEO 最小值」计算，但 Follower 的 LEO 只有通过 Fetch 请求才能上报给 Leader。**

```
时间线：
1. Producer 写入消息到 Leader，Leader LEO 增加
2. Follower 发 Fetch 请求拉数据，Leader 返回数据 + 当前 HW
3. Follower 写入本地，更新自己的 LEO
4. Follower 下一次 Fetch 时，Leader 从请求中得知 Follower 的 LEO
5. Leader 取所有 ISR 副本 LEO 的最小值，推进 HW
```

**HW 推进是「两轮 Fetch」延迟的**——这就是 Kafka 副本同步的固有延迟，也是 `acks=all` 写入延迟较高的原因之一。

### 3.3 写入路径：acks 参数与 ISR 的关系

| acks 值 | 行为 | 可靠性 |
|---------|------|--------|
| acks=0 | 发完就返回，不等待确认 | 可能丢消息（最不靠谱） |
| acks=1 | Leader 写入本地就返回 | Leader 挂了可能丢（默认值） |
| acks=all（-1） | **所有 ISR 副本都写入成功**才返回 | 最可靠，但延迟最高 |

```java
// Producer 配置
Properties props = new Properties();
props.put("acks", "all");                        // 最强可靠性
props.put("min.insync.replicas", 2);             // ISR 至少 2 个才允许写入
props.put("retries", Integer.MAX_VALUE);
props.put("enable.idempotence", true);           // 幂等
```

**注意**：`acks=all` 是「所有 **ISR 内** 副本确认」，不是「所有副本确认」。如果 ISR 只剩 Leader 自己，`acks=all` 也等于只等 Leader 确认——所以生产环境必须配 `min.insync.replicas=2` 防止 ISR 收缩到 1 还假装可靠。

**经典面试题**：ISR = {A, B}，acks=all，此时 B 挂了，写请求会怎样？
- 如果 `min.insync.replicas=2`：ISR 收缩后只有 1 个副本 < 2，**写入直接报 NotEnoughReplicasException**，不写入
- 如果没配 `min.insync.replicas`：ISR 收缩到 {A}，写入照常成功（只有 A 确认）——这就是「看起来可靠，实际丢数据」的坑

## 四、Leader 选举：挂了之后怎么办？

### 4.1 选举流程

```
1. Leader 所在 Broker 挂掉（或网络分区）
2. Controller（控制器 Broker）通过 ZooKeeper 监听 /brokers/ids 感知 Broker 下线
3. Controller 为该分区的副本按「优先顺序」选新 Leader：
   - 第一优先：ISR 中存活的副本（按 AR 副本列表顺序）
   - 第二优先：如果 ISR 全挂，选「不在 ISR 但存活」的副本（unclean.leader.election.enable=true 时）
4. 更新 ZooKeeper / KRaft 元数据，通知所有 Broker 新的 Leader 是谁
```

### 4.2 两个关键配置

```java
// broker 配置
unclean.leader.election.enable=false   // 默认 false：不允许非 ISR 副本当选 Leader

// 含义：
// true  → 可用性优先：ISR 全挂时选一个落后的副本当 Leader，接受丢数据
// false → 一致性优先：ISR 全挂时分区不可用（宁可不可用，不丢数据）
```

**生产建议**：金融、订单类必须 `false`；日志、监控类可以 `true`。

### 4.3 选举后的数据截断

```
旧 Leader: [0][1][2][3][4][5][6]   LEO=7
旧 ISR: A[0][1][2][3][4]  B[0][1][2][3][4][5]

A 当选新 Leader（LEO=5）：
B 发现自己 LEO=7 > 新 Leader 的 HW=5
→ B 截断多余的消息 [5][6]，回退到 HW 位置重新同步
```

**这就是「已写入但未过 HW 的消息会丢失」的完整机制**。所以 `acks=all + min.insync.replicas=2` 组合下，只要不出现「两个副本同时挂」的极端情况，消息不会丢。

## 五、ISR vs Raft：Kafka 为什么不用 Raft 选举？

这是高阶面试题，能答好直接拉开差距。

| 对比维度 | Kafka ISR 机制 | Raft 选举 |
|----------|---------------|-----------|
| 选举范围 | 分区粒度，ISR 内按顺序选 | 整个集群/组选一个 Leader |
| 多数派要求 | 不需要多数派（只要 ISR 非空） | 需要多数派（过半）才可选举 |
| 同步策略 | 异步拉取（Follower 主动 Fetch），允许落后 | 强同步（Leader 主导复制，必须过半数确认） |
| 数据一致性 | 允许少量丢失（ISR 外数据截断） | 强一致（多数派确认即提交） |
| 可用性 | 高（ISR 非空就能继续服务） | 需要多数派存活 |
| 适用场景 | 消息队列（吞吐优先，容忍少量丢） | 一致性状态机（一致性优先） |

**为什么 Kafka 不用 Raft？**
1. **吞吐优先**：Raft 的多数派确认意味着每次写入要等多数副本，延迟和吞吐都受影响；Kafka 的 ISR 允许 Follower 异步追赶，Leader 写入本地即可（acks=1）或等 ISR 全部确认（acks=all），比多数派更灵活
2. **可用性更强**：Raft 要求多数派存活，2 副本集群挂 1 个就不可用；Kafka 只要 ISR 里有副本活着就能继续服务
3. **设计目标不同**：Kafka 是消息中间件，允许「至少一次/可能丢失」语义 + 幂等补偿；Raft 服务（etcd、ZooKeeper）必须强一致

**注意**：Kafka 的 **KRaft 模式（KIP-500）** 用 Raft 来管理元数据（Controller 选举），但**分区副本的数据同步仍然是 ISR 机制**——两者并存，别搞混。

## 六、生产实践：副本相关的调优与排障

### 6.1 关键参数速查

| 参数 | 默认值 | 说明 |
|------|--------|------|
| replication.factor | 1 | 副本数，生产建议 3 |
| min.insync.replicas | 1 | 最小同步副本数，生产建议 2 |
| replica.lag.time.max.ms | 30000 | ISR 判定超时 |
| unclean.leader.election.enable | false | 是否允许非 ISR 当选 |
| acks | 1 | Producer 确认级别 |

### 6.2 常见问题排查

**问题 1：UnderReplicatedPartitions（副本不足）告警**

```bash
# 查看分区副本状态
kafka-topics.sh --describe --bootstrap-server localhost:9092 --topic orders

# 输出中关注：
#   Replicas: 0,1,2      ← 期望的副本分布
#   Isr: 0,1             ← 当前 ISR（2 号副本掉了）
```

排查方向：Broker 2 磁盘满？网络抖动？Follower 拉取线程异常？

**问题 2：ISR 频繁收缩扩张**

- Follower 所在 Broker CPU/IO 高，拉取跟不上 → 扩容或优化磁盘
- 网络带宽不足 → 检查跨机房复制带宽
- `replica.lag.time.max.ms` 太小 → 适当调大（一般不建议动）

**问题 3：acks=all 写入超时**

- ISR 收缩导致等待超时 → 先解决副本同步问题
- `max.in.flight.requests.per.connection` 与重试配合检查

### 6.3 可靠性配置清单（金融级）

```
# Broker 侧
replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false

# Producer 侧
acks=all
retries=Integer.MAX_VALUE
enable.idempotence=true
max.in.flight.requests.per.connection=5   # 幂等开启后可大于 1

# Consumer 侧
enable.auto.commit=false                   # 手动提交
```

## 七、总结

| 要点 | 结论 |
|------|------|
| 副本架构 | 一 Leader 多 Follower，读写走 Leader |
| ISR 本质 | 与 Leader 保持同步的副本集合，动态收缩/扩张 |
| ISR 判定 | `replica.lag.time.max.ms`（默认 30s）内持续拉取 |
| HW/LEO | HW 是所有 ISR 副本 LEO 最小值，消费者只能读到 HW 前 |
| 可靠性组合 | acks=all + min.insync.replicas=2 + 幂等 |
| 选举规则 | 优先 ISR 内副本，unclean 选举默认关闭 |
| 与 Raft 区别 | ISR 不要求多数派，吞吐/可用性优先；KRaft 元数据用 Raft |

**面试万能答案**：「Kafka 副本机制的核心是 ISR——Leader 根据副本拉取活跃度维护同步副本集合，HW 取 ISR 最小 LEO，消费者只能消费 HW 之前的消息；Leader 挂了从 ISR 选新 Leader，ISR 全挂时默认拒绝选举（unclean 关闭）保证不丢数据；可靠性靠 acks=all + min.insync.replicas 组合保证；Kafka 不用 Raft 是因为 ISR 不需要多数派，吞吐和可用性更优，而 KRaft 用 Raft 管理元数据是另一回事。」从机制到配置到对比，面试官想不点头都难。
