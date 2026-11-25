---
title: 【Kafka 实战】分区扩容与 Key 倾斜治理：为什么加分区会让订单乱序，以及怎么补救
date: 2026-11-25 08:00:00
tags:
  - Kafka
  - 中间件
  - 消息队列
  - 分区
  - 生产实战
categories:
  - 中间件
author: 东哥
---

# 【Kafka 实战】分区扩容与 Key 倾斜治理

## 前言

Kafka 的分区数是一个「看起来可以改、实际上很难改」的参数。

运维同学在监控上看到某个 topic 的写入打满、消费 lag 堆积，第一反应通常是「加分区」——命令也确实简单，一条 `kafka-topics.sh --alter --partitions 12` 就完事，不需要数据搬迁，不需要重启 broker。但很多人不知道的是：**这一条命令会瞬间改变所有 key 的分区归属**。如果业务依赖 `key` 保证同一订单、同一用户的消息有序，那么扩容那一刻起，同一个 key 的新消息会落到另一个分区，与旧消息彻底失去顺序关系。

我见过一个真实事故：订单状态 topic 从 6 分区扩到 12 分区，当晚出现 300 多笔「已支付」被「待支付」覆盖——因为两条消息进了不同分区，被两个消费者线程并发处理，后写的旧状态把新状态盖掉了。

这篇文章把两件事讲透：

1. **分区扩容的破坏性边界**：为什么加分区会乱序，哪些组件会受影响，有没有安全的扩容姿势；
2. **Key 倾斜的识别与治理**：分区数够但数据全挤在几个分区上，加分区根本没用。

---

## 一、分区数到底决定了什么

先把分区数的六个作用域列清楚，后面所有取舍都围绕这张表：

| 维度 | 分区数增加的影响 | 备注 |
|---|---|---|
| 消费并行度 | 上限 = 分区数 | 一个分区同一时刻只能被消费组内一个消费者持有 |
| 单 topic 写入吞吐 | 近似线性提升 | 受 broker 数、磁盘、副本同步限制 |
| 单分区吞吐 | 不变（约 10~50 MB/s 量级） | 由页缓存、批量、压缩、副本 ACK 决定 |
| 端到端延迟 | 一般不变或略降 | 分区多则批次小，`linger.ms` 攒不满，可能反而变差 |
| Broker 开销 | 线性增加 | 每分区一组 segment 文件、索引、页缓存、控制器元数据 |
| Rebalance 时间 | 明显变长 | 分区分配、offset 拉取、状态恢复都随分区数增长 |

一个常见的容量算式（估算用，不是精确值）：

```
目标分区数 = max(
  峰值写入字节率 / 单分区可持续写入字节率,
  峰值消费字节率 / 单分区可持续消费字节率,
  期望消费并行度
) × 1.5（预留余量）
```

注意最后那个 1.5 的余量：**分区数只应该一次规划到位，而不是靠反复扩容去追业务**。因为每次扩容都要付下面这节讲的代价。

---

## 二、扩容为什么必然破坏 key 有序

### 2.1 默认分区器的映射公式

Kafka 默认分区器（`DefaultPartitioner`，3.x 之后逻辑搬到 `BuiltInPartitioner`）对带 key 的消息做的是：

```java
// 简化后的核心逻辑
int partition = Utils.toPositive(Utils.murmur2(keyBytes)) % numPartitions;
```

关键在于 `% numPartitions`。分区数从 6 变成 12，同一个 key 的取模结果会变。举个具体例子（murmur2 结果取正值后）：

| key | murmur2 正值 | % 6（旧） | % 12（新） | 结果 |
|---|---|---|---|---|
| order-1001 | 12345678 | 0 | 6 | 换分区 |
| order-1002 | 87654321 | 3 | 9 | 换分区 |
| order-1003 | 55555555 | 1 | 7 | 换分区 |
| order-1004 | 24681357 | 3 | 9 | 换分区 |

数学上，从 `n` 扩到 `m`（m > n），只有当 `h % m == h % n` 时才不迁移。这个概率大致是 `n/m`，也就是说**扩到 2 倍时约有一半的 key 会换分区**。这不是「可能有问题」，是「一定有大量 key 换分区」。

### 2.2 换分区之后会发生什么

以「订单状态变更」为例，消费者伪代码如下：

```java
@KafkaListener(topics = "order-status", groupId = "order-state")
public void onMessage(ConsumerRecord<String, String> record) {
    OrderEvent event = parse(record.value());
    // 直接覆盖写：没有任何版本号或状态机校验
    orderMapper.updateStatus(event.orderId(), event.status(), event.version());
}
```

扩容瞬间的时间线：

```
T0  分区 6 中存在 key=order-1001 的历史消息（已消费，offset 落后于新消息）
T1  扩容到 12 分区，order-1001 的哈希取模从 0 变为 6
T2  生产者发出 status=PAID（进分区 6），此前发出的 status=UNPAID 在分区 0
T3  两个消费者线程并行处理，PAID 先到、UNPAID 后到
T4  数据库最终状态 = UNPAID（旧状态覆盖新状态）
```

这里的本质不是 Kafka 丢消息，而是**「同一 key 的顺序保证」这个前提被运维操作悄悄取消了**，而业务代码仍然按「有序」在写。

### 2.3 连带受影响的组件

| 组件/场景 | 影响 |
|---|---|
| 有状态消费者（本地缓存、去重表） | 同一 key 变成两个消费者处理，本地状态分裂 |
| Kafka Streams / ksqlDB | 分区→任务映射变化，state store 需迁移，可能触发全量恢复 |
| 事务型生产者 | 未完成事务涉及的分区集合变化，`transaction.timeout` 内可能失败 |
| 按分区提交位点的自定义 offset 管理 | 历史位点与新分区不对应，需重建 |
| 依赖分区内单调 offset 做幂等的逻辑 | offset 语义被打破 |
| 分区级限流/隔离（大客户独占分区） | 隔离策略失效 |

另外有一条硬限制：**Kafka 不支持减少分区数**。要减只能新建 topic + 迁移数据 + 切流量。

---

## 三、安全的扩容姿势（四种，按代价排序）

### 方案 1：停机窗口内扩容 + 业务侧版本号兜底（最常用）

如果业务本来就有 `version` 或状态机（`UNPAID → PAID → SHIPPED` 单向流转），扩容只会造成短暂乱序，靠版本号丢弃旧事件即可：

```sql
UPDATE orders
SET status = #{status}, version = #{version}
WHERE id = #{orderId} AND version < #{version};
```

这是成本最低的做法，前提是**你必须先确认所有消费链路都有这类幂等/版本保护**，而不是想当然。

### 方案 2：显式路由表（key → partition 由配置决定）

不用默认分区器，自己维护一张映射表：

```java
public class MappedPartitioner implements Partitioner {
    // key 前缀 -> 分区，扩容时只把新增前缀指向新分区，老前缀不动
    private final Map<String, Integer> prefixToPartition = Map.of(
        "order-", 0, "user-", 1, "pay-", 2, "ship-", 3
    );

    @Override
    public int partition(String topic, Object key, byte[] keyBytes,
                         Object value, byte[] valueBytes, Cluster cluster) {
        int total = cluster.partitionCountForTopic(topic);
        String k = String.valueOf(key);
        Integer fixed = prefixToPartition.get(k.substring(0, Math.min(6, k.length())));
        return fixed == null ? Math.floorMod(k.hashCode(), total) : Math.min(fixed, total - 1);
    }
}
```

优点：扩容可控、可回滚；缺点：映射表本身成为配置中心依赖，且**必须保证所有生产者使用同一个分区器版本**，否则同一 key 会被两套规则路由。

### 方案 3：双 topic 影子迁移

新建目标分区数的 topic，双写一段时间，消费端两路都读、按 key 去重，等历史数据追平后切读新 topic，再停旧。代价最大但最安全，适合金融类强顺序场景。

### 方案 4：一开始就把分区数定够

最省事的方案。按 3 年业务峰值规划，分区数宁多勿少（分区多的主要成本是元数据和文件句柄，不是性能）。很多团队踩坑的根因就是「先建 3 个分区跑跑看」。

---

## 四、Key 倾斜：加分区也救不了的另一种病

### 4.1 现象与识别

分区数 12，消费 lag 却只在 2 个分区上堆积；写入 QPS 不高但 broker 磁盘 util 打满。这是典型的 key 倾斜。

识别手段：

```bash
# 1. 看每个分区的日志段大小与位点
kafka-log-dirs.sh --bootstrap-server broker:9092 \
  --describe --topic-list order-status | jq '.brokerList[0].logDirs[0].partitions[] | {partition, size}'

# 2. 看消费组每个分区的 lag
kafka-consumer-groups.sh --bootstrap-server broker:9092 \
  --describe --group order-state

# 3. 看生产端每个分区的字节速率（JMX）
# kafka.producer:type=producer-topic-metrics,client-id=*,topic=order-status
# 逐分区 byte-rate 需要 per-partition 指标或 broker 侧 BrokerTopicMetrics
```

倾斜度指标建议直接埋进监控：

```java
double skew = (double) maxPartitionBytes / avgPartitionBytes;
// skew > 2.0 告警；> 3.0 视为严重倾斜
```

### 4.2 四类根因

| 根因 | 例子 | 特征 |
|---|---|---|
| key 基数太小 | 按省份（34 个值）、按租户（几个大客户） | 分区数远多于 key 数，天生无法均分 |
| 头部 key 过大 | 某个大客户占 60% 流量 | 单 key 无法拆分，只能拆分「同一 key 的多个维度」 |
| key 含低熵前缀 | `2026-11-25-xxx`、`order-` 统一前缀 | murmur2 分布尚可，但业务上时间局部性导致写入热点 |
| key 为 null 或近似 null | 日志类消息不设 key | 走 sticky 分区，批次内集中，短时倾斜 |

注意：**murmur2 本身的分布是均匀的**，所谓的「哈希不均」绝大多数时候是 key 分布不均，而不是哈希函数的问题。先把 key 的基数与频率分布画出来，再谈治理。

### 4.3 治理手段

**（1）热 key 加盐拆分**

```java
// 生产端：把一个逻辑 key 拆成 N 个物理 key
String physicalKey = logicalKey + "#" + ThreadLocalRandom.current().nextInt(shardCount);
// 消费端：按 logicalKey 聚合，或直接按 shard 并行处理后再归并
```

适用：写入远大于读取、且消费端能接受「同一逻辑 key 的消息并行处理」（例如计数、日志、埋点）。**不适用**于状态机类消息——拆分会直接破坏顺序。

**（2）大客户独立 topic**

把占 60% 流量的租户单独拉一个 topic（分区数按它自己的峰值定），主 topic 只服务长尾。这是最干净的做法，代价是消费端要同时订阅两个 topic 并合并处理。

**（3）二级分片键**

```java
// tenantId + 业务子维度，避免单一租户打满一个分区
String key = tenantId + ":" + (orderId.hashCode() & 0x7fffffff) % 8;
```

注意这样会牺牲「同租户全局有序」，只保留「同租户同子片有序」。

**（4）提高单分区吞吐，而不是继续加分区**

很多「倾斜」其实是「分区能力不够」的误判。先确认这些参数：

```properties
# 生产端
batch.size=131072          # 128KB，别用默认 16KB
linger.ms=10               # 允许攒批
compression.type=lz4       # 压缩换吞吐
max.in.flight.requests.per.connection=5

# broker 侧
num.io.threads=16          # 通常为磁盘数
num.network.threads=8
log.flush.interval.messages=10000
```

一个 128KB 批次 + lz4 的分区，持续写入能力通常能到 30~50 MB/s，很多业务场景根本不需要 12 个分区。

---

## 五、Java AdminClient 扩容实操

生产上扩容不要手敲命令，用代码固化「评估 → 执行 → 校验」三步，避免不同人操作不一致。

```java
public class TopicExpander {

    public static void expand(String topic, int targetPartitions) throws Exception {
        Properties props = new Properties();
        props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092,broker2:9092");
        props.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, "30000");

        try (Admin admin = Admin.create(props)) {
            // 1. 现状校验
            TopicDescription desc = admin.describeTopics(List.of(topic))
                    .allTopicNames().get(30, TimeUnit.SECONDS).get(topic);
            int current = desc.partitions().size();
            if (targetPartitions <= current) {
                throw new IllegalArgumentException(
                        "Kafka 不支持减少分区: current=" + current + ", target=" + targetPartitions);
            }

            // 2. 逐级扩容（先 +50%，观察 24h 再决定是否继续）
            int step = Math.min(targetPartitions, current + Math.max(1, current / 2));
            NewPartitions newPartitions = NewPartitions.increaseTo(step);

            admin.createPartitions(Map.of(topic, newPartitions),
                            new CreatePartitionsOptions().retryOnQuotaViolation(true))
                    .all().get(60, TimeUnit.SECONDS);

            System.out.printf("expanded %s: %d -> %d%n", topic, current, step);

            // 3. 校验：新分区 leader 分布是否均衡
            TopicDescription after = admin.describeTopics(List.of(topic))
                    .allTopicNames().get(30, TimeUnit.SECONDS).get(topic);
            Map<Integer, Long> perBroker = after.partitions().stream()
                    .collect(Collectors.groupingBy(
                            p -> p.leader().id(), Collectors.counting()));
            System.out.println("leader distribution: " + perBroker);
        }
    }
}
```

几个必须注意的点：

1. **`increaseTo` 是绝对值，不是增量**。传错会把 12 分区「扩」成 6 然后报错。
2. **`retryOnQuotaViolation(true)`**：如果配了 `leader.replication.throttled.rate`，扩容触发的副本迁移会被限流，需要重试。
3. **新分区没有历史数据**，如果消费端做了「按分区均匀假设」的批处理（例如按分区预分配线程与队列），需要重启或动态感知 `partitionsFor` 变化。
4. **扩容不会自动触发副本重分配**，新分区只在 leader 所在 broker 上创建，需配合 `kafka-reassign-partitions.sh` 做均衡：

```bash
# 生成迁移计划（限流 50MB/s，避免打满网卡）
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --reassignment-json-file plan.json \
  --throttle 50000000 --execute

# 校验
kafka-reassign-partitions.sh --bootstrap-server broker:9092 \
  --reassignment-json-file plan.json --verify
```

---

## 六、监控与告警清单

| 指标 | 采集位置 | 阈值建议 |
|---|---|---|
| 分区字节速率 skew | broker JMX / 自建埋点 | `max/avg > 2` 告警 |
| 分区 lag 分布 | `kafka-consumer-groups --describe` | 单分区 lag 占比 > 50% 告警 |
| 生产端 record-queue-time | producer JMX | P99 > 100ms 说明分区不够或 broker 慢 |
| `failed-reassignment` 数 | broker 日志 / JMX | > 0 立即处理 |
| 分区数 / broker 数 比值 | 自建 | 单 broker > 200 分区要评估 |
| 副本 ISR 收缩次数 | `IsrShrinksPerSec` | 扩容期间必须为 0 |

---

## 七、面试追问与踩坑清单

**Q1：Kafka 能不能减少分区？**
不能。只能新建 topic 迁移。这也是「分区数要一次规划到位」的根本原因。

**Q2：扩容后如何保证同一 key 有序？**
三条路：业务侧版本号/状态机兜底（最实用）、显式路由表（key 不迁移）、双 topic 影子迁移（最稳但最重）。单纯「先停消费再扩容再启动」并不能解决问题，因为历史消息与新消息仍在不同分区。

**Q3：为什么 key 为 null 的消息也能均匀分布，但业务 key 却倾斜？**
null key 走 sticky partitioner，按批次轮转，分布取决于批次而非 key；业务 key 倾斜说明 key 本身的频率分布不均（少数 key 承载大部分消息），哈希函数无能为力。

**Q4：分区越多越好吗？**
不是。分区多会放大：文件句柄、页缓存占用、控制器元数据、rebalance 时长、端到端延迟（批次变小）。经验值：单 broker 200 分区以内比较稳，超过要评估。

**踩坑 1**：扩容后忘记同步修改消费端的线程池大小假设，导致一半线程空闲。
**踩坑 2**：只扩容没做副本重分配，新分区全在原来那台 broker 上，倾斜更严重。
**踩坑 3**：扩容与 broker 滚动重启同时进行，触发大量 leader 选举 + ISR 收缩。
**踩坑 4**：用 `hashCode()` 而不是 murmur2 自定义分区器，Java 的 `String.hashCode` 分布差且不稳定。
**踩坑 5**：把「分区数」当成「消费并行度」的唯一手段，忽略了单条消息处理才是瓶颈（IO 密集场景应上调并发或改批量）。

---

## 总结

- 分区扩容不是「加机器」式的无痛操作，它会**重写 key→partition 的映射**，从而取消掉「同 key 有序」这个隐含契约。
- 扩容前必须先回答：消费链路有没有版本号/幂等保护？有没有有状态消费者？Kafka Streams 的 state store 能不能恢复？
- Key 倾斜和分区数不足是两种病：前者要拆 key/拆租户，后者才加分区。混淆两者只会让集群越来越重。
- 分区数的最佳实践是**一次规划到位，宁多勿少**；真要扩容，用「逐级扩容 + 副本重分配限流 + 监控 skew」的组合拳。

对 Java 后端来说，这道题几乎是消息队列面试的必问项，也是线上最容易出事故的运维动作之一。把「有序性依赖」写进架构文档，比任何监控都管用。
