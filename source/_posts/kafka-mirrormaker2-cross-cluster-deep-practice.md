---
title: 【Kafka 架构】MirrorMaker 2 跨集群复制深度实战：异地容灾、双向同步与偏移量平移
date: 2026-09-16 08:00:00
tags:
  - Kafka
  - MirrorMaker 2
  - 异地容灾
  - 消息队列
categories:
  - 消息队列
  - 架构设计
author: 东哥
---

# 【Kafka 架构】MirrorMaker 2 跨集群复制深度实战：异地容灾、双向同步与偏移量平移

## 面试官：我们做了两地三中心，Kafka 怎么把数据同步过去？如果主集群挂了，下游消费者能无缝切到备用集群吗？

这个问题的"坑"在于最后一句话。

如果面试官只想听"用 MirrorMaker 复制过去"，那这题只有 30 分。真正的考点是：

> **复制了数据 ≠ 能无缝切换。**因为 Kafka 的消费位点（offset）是**集群内自增的**，A 集群的 topic `orders` 的 offset 1,000,000，在 B 集群复制过来后可能对应 offset 800,000。消费者切过去要么重复消费一大批，要么丢数据。

而 **MirrorMaker 2（MM2）** 相比 MM1 最大的价值，恰恰就是**偏移量平移（offset translation）**与**消费组位点同步**。

这篇文章从 MM2 的架构模型、三大 Connector、配置实战，讲到异地容灾切换的完整方案。

---

## 一、MM1 的痛：为什么要有 MM2

MirrorMaker 1 是一个简单的"消费者 + 生产者"循环：

```text
Consumer(源集群) → 过滤(whitelist/blacklist) → Producer(目标集群)
```

它的四个致命缺陷：

| 缺陷 | 后果 |
| --- | --- |
| **无 offset 转换** | 切集群后消费者不知道该从哪继续，只能 `auto.offset.reset` 粗暴处理（丢或重） |
| **无消费组位点同步** | 每个消费组都要手工重建位点 |
| **静态 topic 列表** | `whitelist`/`blacklist` 在启动时确定，新增 topic 必须重启；靠正则勉强解决 |
| **无 topic 配置 / ACL 同步** | 目标集群的 `retention.ms`、分区数、ACL 全靠人工对齐，极易漂移 |
| 无细粒度监控 | 只有一个全局吞吐指标，出问题无法定位到某个 topic |

MM2 是**在 Kafka Connect 框架上重写的复制方案**，把上面五项全部补齐，并且天然支持"每个 topic 独立任务、独立指标、动态发现"。

---

## 二、MM2 架构：三个 Connector 分工

MM2 不是"一个复制程序"，而是**三个协同工作的 Connector**：

| Connector | 职责 | 关键配置前缀 |
| --- | --- | --- |
| `MirrorSourceConnector` | **复制数据**（topic 消息 + 分区 + topic 配置 + ACL） | `<source>-><target>.` |
| `MirrorCheckpointConnector` | **同步消费组位点**、写入 offset 映射（checkpoint） | `emit.checkpoints.`、`sync.group.offsets.` |
| `MirrorHeartbeatConnector` | **心跳**，用于端到端链路延迟监控 | `emit.heartbeats.` |

### 2.1 三个内部 Topic

MM2 自己会产生几个内部 topic，**必须理解它们，否则排障无从下手**：

| 内部 Topic | 写入方 | 作用 |
| --- | --- | --- |
| `heartbeats` | Heartbeat Connector | 每个源集群周期性发心跳，用来算跨集群延迟 |
| `mm2-offset-syncs.<target>.internal` | Source Connector | **offset 映射表**：记录"源集群某 topic 某分区在时刻 T 的 offset" |
| `mm2-checkpoints.<source>.internal` | Checkpoint Connector | 消费组位点的检查点，用于把位点翻译到目标集群 |

> 注意 `offset-syncs` 的位置由 `offset-syncs.topic.location` 决定（默认 `target`）。**所有需要做 offset 转换的客户端，都必须能读到这个 topic。**这是"客户端切集群时该连哪个集群"的关键。

### 2.2 复制策略（ReplicationPolicy）

**这是 MM2 里最重要的概念，没有之一。**

| 策略 | 行为 | 适用场景 |
| --- | --- | --- |
| `DefaultReplicationPolicy`（默认） | 目标集群里的 topic 名变成 **`<源集群别名>.<原topic>`**，如 `primary.orders` | 单向复制、备份、聚合；**能天然避免回环** |
| `IdentityReplicationPolicy` | 目标集群里保持**同名** topic | **双向 active-active**、平滑迁移（客户端改地址即可） |

为什么默认要加前缀？因为**单向复制到"命名空间隔离"的目标**，可以避免与目标集群本地同名 topic 冲突，也让"哪些是复制来的"一目了然。

而双向复制**必须**用 `IdentityReplicationPolicy`：否则 A 的 `orders` 复制到 B 变成 `a.orders`，B 再复制回 A 变成 `b.a.orders`，A 再复制到 B 变成 `a.b.a.orders`……**topic 名无限增长，集群爆炸。**

```properties
replication.policy.class = org.apache.kafka.connect.mirror.IdentityReplicationPolicy
```

> 循环检测：MM2 会在被复制的消息上打标记，下游 MM2 跳过"已由自己复制过"的消息，避免双向场景下的回环。但不同版本实现细节有差异，**双向方案上线前必须做真实压测验证**（尤其是 topic 名与消息标记的交互）。这是我在实践中踩过的坑：单向跑得再好，双向配置一变就可能出现消息风暴。

---

## 三、配置实战：一份可直接上生产的 MM2 配置

MM2 的配置文件是"全局参数 + 链路参数（`<source>-><target>.`）"的混合体。

```properties
# ============ 集群定义 ============
clusters = primary, secondary

primary.bootstrap.servers    = kafka-1:9092,kafka-2:9092,kafka-3:9092
secondary.bootstrap.servers  = kafka-dr-1:9092,kafka-dr-2:9092,kafka-dr-3:9092

# 安全（生产必配）
primary.security.protocol    = SASL_SSL
primary.sasl.mechanism       = SCRAM-SHA-512
primary.sasl.jaas.config     = org.apache.kafka.common.security.scram.ScramLoginModule required \
                               username="mirror" password="${MM2_PASSWORD}";

# ============ 链路：primary -> secondary ============
primary->secondary.enabled = true
primary->secondary.topics  = orders, payments, inventory, user-events
# 或者用正则：primary->secondary.topics = (orders|payments).*
topics.exclude = .*[\-\.]internal, .*\.replica, __consumer_offsets

# ============ 复制参数 ============
replication.factor = 3
refresh.topics.enabled = true
refresh.topics.interval.seconds = 60       # 动态发现新 topic（默认 600s，按需调小）
sync.topic.configs.enabled = true          # 同步 retention/cleanup.policy 等
sync.topic.acls.enabled = true             # 同步 ACL

# ============ 心跳（监控链路延迟） ============
emit.heartbeats.enabled = true
emit.heartbeats.interval.seconds = 1
heartbeats.topic.replication.factor = 3

# ============ Checkpoint（offset 映射 + 位点同步） ============
emit.checkpoints.enabled = true
emit.checkpoints.interval.seconds = 60
checkpoints.topic.replication.factor = 3
offset-syncs.topic.replication.factor = 3
offset-syncs.topic.location = target       # offset 映射表放在目标集群

# 【关键】是否把消费者位点直接同步到目标集群
sync.group.offsets.enabled = true
sync.group.offsets.interval.seconds = 60
refresh.groups.enabled = true
refresh.groups.interval.seconds = 60
groups.exclude = console-consumer-.*, connect-.*

# ============ 首次启动从最早开始（历史数据迁移） ============
primary->secondary.auto.offset.reset = earliest
```

启动：

```bash
bin/connect-mirror-maker.sh config/connect-mirror-maker.properties
```

### 3.1 三个致命配置项（90% 的线上问题源于此）

**① `sync.group.offsets.enabled` 默认是 `false`！**

这是最容易被忽略的一点。开启 `emit.checkpoints` 只是**写了 offset 映射**，但**不会自动把消费组位点同步到目标集群**。想让"备用集群上的消费者能直接从对应位点继续消费"，必须显式打开它：

```properties
sync.group.offsets.enabled = true
```

**② `offset-syncs.topic.location` 决定客户端连哪边**

- `target`（默认）：映射表在目标集群，客户端切到目标集群时**本地可读**，切换更顺；
- `source`：映射表在源集群，目标集群的消费者要读源集群的 topic（跨集群访问），**一般只在特殊网络拓扑下使用**。

**③ 内部 topic 的副本数必须 ≥ 3**

```properties
heartbeats.topic.replication.factor = 3
checkpoints.topic.replication.factor = 3
offset-syncs.topic.replication.factor = 3
```

**内部 topic 一旦创建就无法改副本数**（只能重建）。默认值在生产多副本集群上如果建在了单副本 broker 上，容灾时这些映射数据先丢——位点平移能力直接失效。**上线前先确认集群副本数配置。**

---

## 四、偏移量平移：让消费者无缝切换

这是 MM2 最核心、也最容易被问倒的能力。

### 4.1 原理

`MirrorSourceConnector` 在复制过程中，会周期性把"源集群某 topic-partition 当时复制到哪个 offset"写进 `mm2-offset-syncs`。于是就有了：

```text
源集群 primary: orders-0  offset 1,000,000
目标集群 secondary: orders-0  offset   800,000
```

有了这条映射，就能把源集群的消费位点"翻译"到目标集群。

### 4.2 用代码做平移（`RemoteClusterUtils`）

```java
Properties props = new Properties();
props.put("bootstrap.servers", "kafka-dr-1:9092,kafka-dr-2:9092"); // 目标集群

// 源集群某消费组在各分区的位点（从源集群 __consumer_offsets 读到）
Map<TopicPartition, Long> sourceOffsets = Map.of(
        new TopicPartition("orders", 0), 1_000_000L,
        new TopicPartition("orders", 1),   950_000L
);

// 翻译成目标集群的位点
Map<TopicPartition, Long> translated = RemoteClusterUtils.translateOffsets(
        props, "primary", "order-service-group", sourceOffsets);

// 在目标集群上 seek 到翻译后的位点继续消费
for (Map.Entry<TopicPartition, Long> e : translated.entrySet()) {
    consumer.seek(e.getKey(), e.getValue());
}
```

### 4.3 位点同步（自动版）

打开 `sync.group.offsets.enabled=true` 后，Checkpoint Connector 会：

1. 读源集群 `__consumer_offsets` 里各消费组的提交位点；
2. 用 offset-syncs 映射把位点翻译成目标集群的位点；
3. **把翻译后的位点直接写进目标集群的 `__consumer_offsets`**。

结果：下游消费者把 bootstrap servers 一改，**无需改代码、无需手工 seek，直接从对应位置继续消费**。

### 4.4 平移的三个限制（面试加分点）

| 限制 | 说明 | 应对 |
| --- | --- | --- |
| **有延迟** | checkpoint 间隔（默认 60s）+ 心跳周期，切换时可能丢/重几百 ms 到几十秒的数据 | 缩短 `emit.checkpoints.interval.seconds`；业务侧幂等兜底 |
| **只对齐到"最近一次映射点"** | 映射点是周期性的，不是精确到每条消息 | 期待"最多重复一小段"，用幂等消费解决 |
| **要求分组标识与顺序** | 分区数必须对齐，否则映射无法一一对应 | 迁移前校验两端 topic 分区数一致 |

> **实践建议：把 offset 平移当作"减少重复量"的手段，而不是"保证 exactly-once"的手段。**容灾切换的最终一致性永远要靠业务幂等。这一点在任何面试里都能拿分。

---

## 五、双向 Active-Active 方案

### 5.1 拓扑

```text
        ┌──────────── 双向复制 ────────────┐
        ▼                                 │
  [Cluster A]  ──MM2(Identity)──▶  [Cluster B]
        ▲                                 │
        └──────MM2(Identity)──────────────┘
```

配置要点：

```properties
clusters = A, B
replication.policy.class = org.apache.kafka.connect.mirror.IdentityReplicationPolicy

A->B.enabled = true
B->A.enabled = true
# 双方必须使用一致的 topic 集合与 exclude 规则，否则会出现"单向可见"
topics.exclude = .*[\-\.]internal, .*\.replica, __consumer_offsets, mm2-.*
```

### 5.2 双向方案的四个难点

1. **回环**：见上文，靠消息标记 + 版本行为，**必须实测**。
2. **命名冲突**：同名 topic 在两端各自被本地写入，语义上变成"两个独立 topic 的数据混合在一起"，业务必须能接受（通常靠分区按 key 隔离）。
3. **配置冲突**：两端 topic 配置（如 `retention.ms`）不一致时，MM2 的 sync 会来回覆盖，形成"配置抖动"。建议**关掉** `sync.topic.configs.enabled`，改由配置管理统一管控。
4. **消费位点语义混乱**：同一消费组在两端都有位点，`sync.group.offsets` 双向开启会互相覆盖。**双向场景一般关闭位点同步**，由业务层设计"就近读写"。

> 我的建议：**除非业务真的需要双写，否则优先选"单向复制 + 容灾切换"**。Active-Active 的复杂度不是配置问题，而是数据冲突与业务语义问题，成本往往被严重低估。

---

## 六、监控与运维

### 6.1 必看指标

| 指标 | 含义 | 告警建议 |
| --- | --- | --- |
| `replication-latency-ms` | 数据从源写入到目标可见的延迟 | > 业务容忍值告警 |
| `checkpoint-latency-ms` | 消费组位点同步延迟 | > 5min 告警（影响切换精度） |
| `record-age-ms` | 复制记录的平均年龄 | 持续增长 = 复制落后 |
| `record-error-rate` | 复制失败率 | > 0 立即排查（序列化/权限/配额） |
| `byte-rate` / `record-count` | 吞吐 | 突降 = 链路异常或源无数据 |
| `mm2-offset-syncs` / `mm2-checkpoints` 的 LEO 增长 | 映射是否在推进 | 停止增长 = 平移能力失效 |

### 6.2 常见故障排查表

| 现象 | 可能原因 | 定位方式 |
| --- | --- | --- |
| 新 topic 没被复制 | `refresh.topics.interval.seconds` 未到 / 被 `topics.exclude` 命中 | 查 Connect 任务日志；`topics.exclude` 正则是否误伤 |
| 复制延迟持续增长 | 网络带宽、目标集群写入配额、分区数不足（并发受限） | 看 `byte-rate`、目标集群 `throttle-time` |
| 位点同步失效 | `sync.group.offsets.enabled=false` / 组名被 `groups.exclude` 命中 | `ACL`/日志 + 检查 `mm2-checkpoints` |
| 任务反复重启 | 序列化不兼容、topic 被删、内部 topic 副本不足 | Connect worker 日志里的 stack trace |
| 双向出现消息风暴 | 回环未被正确检测 | 立刻停一侧 MM2，比对 topic 名与消息标记 |
| 目标集群磁盘爆 | retention 配置未同步 / 同步被覆盖 | 对比两端 topic 配置 |

### 6.3 上线与演练清单

```text
1. 两端 topic 分区数一致（否则无法平移）
2. 内部 topic 副本数 ≥ 3，且建在多副本 broker 上
3. 首次启动观察全量同步进度（auto.offset.reset=earliest 会全量拉历史）
4. 压测链路带宽：源集群出流量 = 复制流量，别忽略限流与配额
5. 演练切换：停源集群写入 → 等 replication-latency 收敛 → 客户端改 bootstrap → 验证重复/丢失区间
6. 演练回切：确认回切时的位点平移方向
7. 监控接告警：延迟、错误率、映射推进
```

---

## 七、和替代方案比一比

| 方案 | 原理 | 优点 | 缺点 |
| --- | --- | --- | --- |
| **MM2** | Connect 应用层复制 + offset 映射 | 开源、活跃、可定制、支持动态发现与 ACL/配置同步 | 需做 offset 平移；有延迟；双向复杂 |
| MM1 | 消费-生产循环 | 简单 | 无平移、无位点同步、无动态发现 |
| Confluent Replicator / Cluster Linking | broker 层字节级复制，**offset 完全一致** | 无需平移、延迟极低、切换天然无缝 | 商业版特性，成本高 |
| 自研双写 | 业务代码同时写两个集群 | 可控 | 侵入大、一致性难保证、维护成本高 |
| 应用级消息表 + 补偿 | 事务消息/本地表 + 定时补偿 | 强一致可控 | 延迟高、实现复杂 |

**选型结论**：

- 预算有限、需要开源方案 → **MM2**（配合业务幂等做容灾切换）；
- 追求"切换零改造、offset 一致" → 上商业版 Cluster Linking；
- 只做数据备份/入湖，不涉及消费切换 → MM2 单向复制就够了。

---

## 八、面试常见追问

**Q1：为什么 MM2 复制过来的 offset 和源集群不一样？**

Kafka 的 offset 是**分区内自增的物理位置**，由目标集群的分区写入顺序决定。复制是"重新生产"消息，因此起点不同。MM2 通过 `mm2-offset-syncs` 记录映射来解决"位点对齐"问题。

**Q2：`emit.checkpoints` 和 `sync.group.offsets` 的区别？**

前者是"**写 offset 映射**"（让客户端能自己翻译），后者是"**把翻译后的位点写进目标集群**"（让客户端无需改代码）。只开前者不解决问题，这是最经典的配置误区。

**Q3：双向复制为什么要用 `IdentityReplicationPolicy`？**

因为默认策略会给 topic 名加源集群前缀，双向场景下前缀会反复叠加（`a.b.a.orders`），导致 topic 数量与名字无限膨胀，最终拖垮集群。

**Q4：MM2 能保证 exactly-once 吗？**

不能严格保证端到端 exactly-once。MM2 的复制本质是 at-least-once（配合 offset 平移后表现为"可能重复"），端到端一致性依赖**消费者幂等**。Kafka 事务能保证单个集群内的 EOS，跨集群复制要另行设计。

**Q5：切换时怎么把"丢/重"控制到最小？**

三点：① 缩短 `emit.checkpoints.interval.seconds`；② 切换前**停写源集群**（冻结流量）并等待复制延迟收敛到 0；③ 消费端做幂等 + 记录切换水位线，便于事后对账。

---

## 九、小结

| 要点 | 结论 |
| --- | --- |
| 定位 | Kafka Connect 之上的官方跨集群复制方案，三个 Connector 分工 |
| 核心价值 | **offset 映射 + 消费组位点同步**，实现客户端无缝切换 |
| 关键配置 | `sync.group.offsets.enabled=true`（默认 false！）、`offset-syncs.topic.location`、内部 topic 副本数 |
| 单双向差异 | 单向用 `DefaultReplicationPolicy`（加前缀）；双向必须 `IdentityReplicationPolicy` |
| 位点平移 | `RemoteClusterUtils.translateOffsets`，有延迟，**不能替代幂等** |
| 必看指标 | `replication-latency-ms`、`checkpoint-latency-ms`、`record-error-rate` |
| 演练铁律 | 先在预发做完整切换/回切演练，别把它当"配好就完事"的组件 |
| 选型 | 开源首选 MM2；要"零改造切换"看 Cluster Linking；只做备份则单向即可 |

MirrorMaker 2 真正解决的问题不是"把数据搬过去"——那是最简单的一半。它解决的是**"搬过去之后，消费者还能接着原来的位置继续干活"**。理解到这一层，才算真正理解了跨集群复制的工程本质。
