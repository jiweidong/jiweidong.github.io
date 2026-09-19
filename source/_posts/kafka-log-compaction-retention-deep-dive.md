---
title: 【Kafka 原理】日志清理与 Log Compaction 深度解析：retention、压实、墓碑消息与状态存储实战
date: 2026-09-19 08:20:00
tags:
  - Kafka
  - 消息队列
  - 存储
  - 面试
categories:
  - Kafka
  - 中间件原理
author: 东哥
---

# 【Kafka 原理】日志清理与 Log Compaction 深度解析：retention、压实、墓碑消息与状态存储实战

## 面试官：Kafka 消息默认存 7 天，那它和"状态"有什么关系？

这是一个能把候选人分成两档的问题。只知道"7 天过期"的，答不出 Kafka Streams 的 `KTable`、`__consumer_offsets` 这些 topic 为什么可以永久保留；能答出 Log Compaction 的，就摸到了 Kafka"既是消息队列，又是分布式存储"的双重身份。

本文从磁盘上的日志目录出发，讲清 Kafka 两种日志清理策略（delete 与 compact）的实现、参数、坑与生产实践。

## 一、日志存储结构：一切都从目录说起

Kafka 的一个 partition 对应磁盘上一个目录：

```
/kafka-logs/orders-0/
├── 00000000000000000000.log          # 日志段（消息本体）
├── 00000000000000000000.index        # 偏移量索引（8 字节：相对 offset + 物理位置）
├── 00000000000000000000.timeindex    # 时间戳索引（12 字节：timestamp + 相对 offset）
├── 00000000000000000000.snapshot     # 幂等/事务生产者去重快照
├── 00000000000000036912.log          # 下一个段：名字 = 段起始 offset
├── 00000000000000036912.index
├── 00000000000000036912.timeindex
├── leader-epoch-checkpoint           # Leader Epoch 与起始 offset 映射
└── partition.metadata
```

四个关键认知：

1. **段（LogSegment）是清理的最小单位之一**。默认 1GB（`log.segment.bytes`）或 7 天（`log.roll.ms`，取先到者）滚动一次。段一旦封口（rolled），才能被清理逻辑处理。
2. **稀疏索引**：`index` 与 `timeindex` 只记录每隔 `log.index.interval.bytes`（默认 4KB）一条，二分查找后顺序扫描，用极小内存换取 O(log n) 定位。
3. **`__consumer_offsets`、`__transaction_state` 这些内部 topic 用的是 compact 策略**——这是理解 Log Compaction 最好的入口。
4. 段名就是 baseOffset，**这决定了"删除"和"压实"都以整段为粒度**，这也是"为什么删了消息磁盘没立刻变小"的直接原因。

## 二、两种清理策略：delete 与 compact

`cleanup.policy` 可取值 `delete`、`compact`、`delete,compact`。

```bash
# topic 级设置
bin/kafka-configs.sh --bootstrap-server localhost:9092 --alter \
  --entity-type topics --entity-name my-topic \
  --add-config cleanup.policy=compact,delete

# broker 默认
log.cleanup.policy=delete
```

| 维度 | delete | compact |
| --- | --- | --- |
| 目标 | 按时间/大小丢弃旧数据 | 保留每个 key 的最新值 |
| 数据量 | 随时间有界下降 | 趋于稳定（key 数量决定） |
| 是否丢消息 | 是（整段） | 否（同 key 旧值被压实） |
| 典型场景 | 业务消息、日志采集 | CDC、状态存储、offset 主题 |
| 最小保留 | 段级别 | 段级别（活动段不压实） |

### delete 策略的完整判定链

```properties
log.retention.hours=168                 # 7 天（log.retention.ms 优先）
log.retention.bytes=-1                 # 按分区大小限制（-1 不限）
log.segment.bytes=1073741824           # 1GB
log.retention.check.interval.ms=300000 # 5 分钟扫描一次
```

判定逻辑（源码 `LogManager.deleteOldSegments`）：

1. **先算时间线**：被删除段中最大时间戳 `lastModified = max(segment.largestTimestamp, segment.lastModified)`，若 `now - lastModified > retentionMs` 则该段可删。
2. **再算大小线**：从最旧的段累加，直到剩余总大小 ≤ `retentionBytes`。
3. **取"最保守但满足两者"的结果**：两个条件都满足才删。
4. **绝不能删活动段**，也不能让 `logStartOffset` 超过消费者已提交的 offset 太多（否则触发 `OffsetOutOfRangeException`）。

**线上常见的"删不掉"三大原因**：

- 小流量 topic 段永远滚不动（1GB 或 7 天未到），最旧的段一直不被删除 → 需要按 `log.roll.ms` 主动滚动；
- `retention.bytes` 小于单段大小；
- 生产端持续写入导致永远有活动段，`retention` 只能作用于封口段。

```bash
# 手动滚动段（立即让数据可被清理）
bin/kafka-topics.sh --bootstrap-server localhost:9092 --alter \
  --topic my-topic --config segment.bytes=104857600
# 或直接调小 retention 加速清理
bin/kafka-configs.sh --bootstrap-server localhost:9092 --alter \
  --entity-type topics --entity-name my-topic --add-config retention.ms=3600000
```

## 三、Log Compaction 的实现机制

Log Compaction 的核心承诺是：**对于每个 key，保留最后一个值；但保留多少历史由压实时机决定**。它不是数据库的"更新"，而是"后台异步的重写"。

### 压实过程：线程模型与四个阶段

Kafka 由 `log.cleaner.threads`（默认 1）个清理线程 + 一个 `CleanerManager` 协作完成：

```
[Log Cleaner Thread]
   │
   ├─ 1. 选择待压实分区：dirty ratio > min.cleanable.dirty.ratio
   ├─ 2. 构建 Offset Map（first dirty offset → 每个 key 的最新 offset）
   │      └─ 用固定内存 log.cleaner.dedupe.buffer.size（默认 128MB）
   │         装不下时，按 key hash 分多轮（dirtyRatio 提前结束）
   ├─ 3. 重写：把"最新值"段 + 未压实段合并成新段（.clean）
   └─ 4. 原子替换：rename 新段，更新 logStartOffset，删除旧段
```

关键参数：

```properties
log.cleanup.policy=compact
log.cleaner.enable=true                    # broker 级，必须开
log.cleaner.threads=2                      # 与大分区数/高 TPS 匹配
log.cleaner.dedupe.buffer.size=134217728   # 128MB，压实内存
log.cleaner.io.max.bytes.per.second=unlimited
log.cleaner.min.cleanable.ratio=0.5        # 脏数据占比阈值
log.cleaner.min.compaction.lag.ms=0        # 消息最短不被压实时间（防止频繁重写）
log.cleaner.max.compaction.lag.ms=9223372036854775807  # 最长时间（保证冷 key 也会被压实）
min.cleanable.dirty.ratio=0.5              # 老版本用这个参数名
```

**`min.compaction.lag.ms` 是生产上很重要的旋钮**：设为 1 小时，能避免"热点 key 刚写入就被压实、消费者读不到"的时序问题。

### 差量压实的两个"未清理区"

压实是增量的，段状态有三种：

- **clean**：压实完成；
- **dirty**：有未压实数据；
- **cleanable**：可回收（`firstDirtyOffset` 之前的段）。

`dirty ratio = (dirty bytes) / (total bytes)`。只有当脏段占比超过 `min.cleanable.dirty.ratio` 才触发。这是为什么"写了新值，旧值还在"——它只是**可能**还在，不保证立刻消失。

### 墓碑消息（Tombstone）

删除一个 key 的方式是**写一条 value 为 null 的消息**：

```java
// 删除 key
producer.send(new ProducerRecord<>("user-state", "u1001", null));
```

规则：

1. 墓碑消息会保留 `delete.retention.ms`（默认 24 小时）——给消费者足够时间读到"删除事件"；
2. 墓碑之上若还有同 key 数据，墓碑会被清理；
3. **`delete.retention.ms` 太短会导致"迟到的消费者读到已删除数据"**；
4. 消费端务必判空，否则 NPE：

```java
ConsumerRecord<String, byte[]> rec = ...;
if (rec.value() == null) {
    // 删除语义：从本地状态中移除该 key
    localState.remove(rec.key());
    return;
}
```

### 与事务/幂等的关系

`__consumer_offsets` 与 `__transaction_state` 使用 compact。事务标记消息（`control batch`）不会被压实掉，因为它们是事务边界的锚点。`leader-epoch-checkpoint` 与 `.snapshot` 文件也为幂等生产者服务——这解释了为什么"compact topic 的消息数不等于 key 数"。

## 四、Log Compaction 的语义边界（面试高频）

**Q：压实后还能按 offset 顺序消费到所有原始消息吗？**
不能。压实会**删除中间版本的记录**，并且重写后 offset 不再连续（存在"空洞"），但**剩余消息的 offset 顺序保持不变**。所以压缩 topic 适合"最终状态"，不适合"全量事件流"（后者应用 delete 策略）。

**Q：同 key 的消息，能保证消费到最新值吗？**
能保证最新值一定存在（除非它还是墓碑被删）。但如果你从头消费，可能读到旧值→新值的序列（取决于压实进度），也可能直接读到新值。**要严格顺序，请用 delete 策略 + 单分区有序**。

**Q：为什么 `log.cleaner.threads` 不能随便调大？**
压实是磁盘 IO 密集型（读旧段、写新段），线程过大会与生产者/消费者争抢 IO，导致 `p99` 抖动。应按磁盘类型和分区数评估，SSD 上 2-4 个较为稳妥。

**Q：compact topic 的 `log.retention.ms` 还有效吗？**
如果 `cleanup.policy=delete,compact`，两者同时生效：超过 retention 的段照样删（这会造成数据丢失，慎用组合）；只写 `compact` 时 retention 不生效。

## 五、生产实践：把 CDC 场景跑稳

以"MySQL binlog → Kafka compact topic → 下游重建缓存"为例，完整配置：

```bash
# 1) 建 compact topic，注意分区数一旦定下不可减
bin/kafka-topics.sh --create --topic db-user-state \
  --partitions 12 --replication-factor 3 \
  --config cleanup.policy=compact \
  --config min.cleanable.dirty.ratio=0.3 \
  --config delete.retention.ms=86400000 \
  --config min.compaction.lag.ms=3600000 \
  --config segment.ms=3600000 \
  --config max.message.bytes=10485760
```

注意点：

1. **key 必须稳定**：用主键（如 `user:1001`），不要用 UUID，否则压实完全失效（每个 key 只出现一次）。
2. **`segment.ms` 调小**（如 1 小时）：低频 key 的段也能滚起来被压实，否则脏段永远是活动段。
3. **分区数 = 压实并行度的上限**：一个分区同一时刻只会被一个清理线程处理。
4. **监控 `kafka.log:type=LogCleanerManager`**：`max-dirty-percent`、`uncleanable-partitions-count`。后者长期 > 0 说明有分区无法压实（通常是 `min.cleanable.dirty.ratio` + 单段过大的组合）。
5. **磁盘规划**：压实时需要额外空间容纳 `.clean` 新段，预留 20%-30% 余量。

### 消费端重建状态的正确姿势

```java
Properties props = new Properties();
props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "kafka:9092");
props.put(ConsumerConfig.GROUP_ID_CONFIG, "state-rebuilder");
// 关键：首次/重置时才用 earliest，常态必须关掉自动提交并手工控制
props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");

KafkaConsumer<String, byte[]> consumer = new KafkaConsumer<>(props);
consumer.subscribe(Collections.singletonList("db-user-state"));
// 用 store 恢复完成后，再切到最新位点进入增量模式
```

**冷启动重建的坑**：从头消费一个 compact topic 只能拿到"部分历史"，无法重建完整状态。正确做法是**先用数据库全量快照初始化，再用 compact topic 追增量**（这也是 Debezium + KTable 的标准姿势）。

## 六、delete 与 compact 选型决策表

| 需求 | 选 delete | 选 compact |
| --- | --- | --- |
| 事件流、日志、埋点 | ✅ | ❌（会丢中间事件） |
| CDC 变更、缓存重建 | ❌ | ✅ |
| 消费者 offset 存储 | — | ✅（内部实现） |
| 需要永久保留最新状态 | ❌ | ✅ |
| 需要严格按序回放全部事件 | ✅ | ❌ |
| 数据无限增长不可接受 | ⚠️（需压缩/分层） | ✅（有界） |

## 七、面试追问速答

**Q1：Kafka 为什么不用"随机写 + B+ 树"而是顺序 append？**
顺序写 + 段文件 + 稀疏索引，把磁盘顺序 IO 的性能压榨到极致；配合页缓存（`sendfile` 零拷贝）实现高吞吐。代价就是"更新/删除"只能靠压实重写来变相实现。

**Q2：压实过程中会阻塞读写吗？**
不阻塞。压实写的是新段文件，替换时通过 rename 原子完成，读写仍在旧段上进行。

**Q3：`log.cleaner.io.buffer.size` 有什么用？**
压实过程的读写缓冲区总大小（默认 512KB），影响压实 IO 的吞吐与内存占用。

**Q4：为什么活动段不参与压实？**
活动段还在被写入，重写会与写入冲突。所以 `segment.ms`/`segment.bytes` 决定了"压实延迟的下限"。

**Q5：如何判断某个 compact topic 会不会无限增长？**
看 key 的基数（cardinality）。key 空间有界（用户数、订单数）则数据量趋于有界；key 无界（含时间戳、UUID）则压实无效，数据无限增长——这是设计阶段就必须拦住的错误。

## 八、总结

- Kafka 的日志清理有两条路：**delete 管"时间/大小"**，**compact 管"最新状态"**；两者都以**段**为操作粒度。
- Compaction 本质是"后台异步重写 + offset 保留空洞"，因此它保证"每个 key 至少有一个最新值"，但**不保证全量历史、不及时、不保证无重复读取**。
- **墓碑消息 + `delete.retention.ms`** 是删除语义的关键，消费端必须判 null。
- 生产要盯的三个指标：`uncleanable-partitions-count`、`max-dirty-percent`、磁盘余量。
- 选型的唯一标准是：**你要"事件流"还是"最终状态"**。

把 Log Compaction 讲明白，Kafka 就从"消息队列"升级成了"分布式 commit log"——这正是它区别于 RabbitMQ 的本质，也是 Kafka Streams 状态存储能落地的前提。
