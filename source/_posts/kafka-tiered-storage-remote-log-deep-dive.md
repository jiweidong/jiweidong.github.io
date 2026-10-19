---
title: 【Kafka 深挖】分层存储（Tiered Storage）深度解析：KIP-405 架构、远端日志与容量治理
date: 2026-10-19 08:10:00
tags:
  - Kafka
  - 分层存储
  - KIP-405
  - 中间件
  - 架构设计
categories:
  - 中间件
author: 东哥
---

# 【Kafka 深挖】分层存储（Tiered Storage）深度解析：KIP-405 架构、远端日志与容量治理

## 前言

Kafka 的经典架构是**存算一体**：Broker 既负责网络与协议处理，又负责把消息写到本地磁盘。这个设计非常优雅——顺序写、零拷贝、页缓存，让 Kafka 用三块普通磁盘就能扛住百万级 QPS。

但它也带来一个越来越难承受的代价：**想多留几天数据，就必须多加磁盘；加磁盘就必须加 Broker；加了 Broker 又要迁移分区。**

现实中的数据保留需求是这样的：

| 数据类型 | 保留时长 | 访问频率 |
|---|---|---|
| 实时风控/告警 | 7 天 | 极高 |
| 业务解耦 | 3~7 天 | 高 |
| 数据回放/重放 | 30~180 天 | 极低 |
| 审计/合规 | 1~3 年 | 几乎为零 |

用同一套高成本、高 IOPS 的本地 SSD 去存"几乎不会被读"的历史数据，是巨大的浪费。**KIP-405（Tiered Storage，分层存储）** 就是为了解决这个问题：把「热数据」留在 Broker 本地，「冷数据」卸载到廉价的对象存储（S3/OSS/HDFS），而**消费者完全无感知**。

本文从架构、读写路径、配置、运维四个层面把它讲透。

---

## 一、核心思想：日志分段（Log Segment）级别的冷热分离

Kafka 的日志本质是**分段（segment）**结构：

```
topic-partition-0/
  ├── 00000000000000000000.log        <- 基础 offset 0
  ├── 00000000000000000000.index
  ├── 00000000000000000000.timeindex
  ├── 00000000000000368570.log        <- 基础 offset 368570
  ├── 00000000000000368570.index
  └── ...
```

分层存储的最小迁移单位就是 **segment**，而不是单条消息。这一点非常关键：

- **活跃 segment**（正在写的）永远在本地
- **非活跃 segment** 一旦满足条件（超过 `segment.ms` / `segment.bytes` 滚动完成），就可以被上传到远端
- 上传成功后，本地文件**只保留一小段**（`local.retention.ms` / `local.retention.bytes`），其余删除
- 读取时如果本地没有，Broker 自动从远端拉取

所以它的语义是：**"保留策略"和"存储介质"解耦了**。你可以设置 `retention.ms=30 天`，但本地只留 2 小时的数据。

---

## 二、KIP-405 的四个核心组件

分层存储不是简单加个 "上传线程"，它的插件化设计包含四层抽象：

| 组件 | 全称 | 职责 |
|---|---|---|
| `RemoteStorageManager` (RSM) | 远端存储管理器 | 真正读写远端对象（put/get/delete） |
| `RemoteLogMetadataManager` (RLMM) | 远端日志元数据管理器 | 记录"哪个 segment 在远端哪个位置" |
| `RemoteLogManager` (RLM) | 远端日志管理器 | Broker 内部调度器：上传、清理、拉取、复制 |
| `RemoteLogMetadataCache` | 元数据缓存 | 本地缓存 RLMM 元数据，避免每次读都查远端 |

### 2.1 RemoteStorageManager：只关心字节

RSM 的接口极简（简化版）：

```java
public interface RemoteStorageManager extends Configurable, Closeable {
    void copyLogSegmentData(RemoteLogSegmentMetadata metadata,
                            LogSegmentData segmentData) throws IOException;

    InputStream fetchLogSegment(RemoteLogSegmentMetadata metadata,
                               int startPosition) throws IOException;

    Optional<RemoteLogSegmentMetadata> ... // 元数据相关
    void deleteLogSegmentData(RemoteLogSegmentMetadata metadata) throws IOException;
}
```

官方提供了 `kafka-storage-s3`（S3/兼容 S3 的对象存储）实现，社区也有 HDFS、Azure Blob、GCS 的插件。**对象存储的 key 布局**大致是：

```
{topic}/{partition}/{segment-base-offset}-{segment-last-offset}/{uuid}.log
{topic}/{partition}/{...}/index
{topic}/{partition}/{...}/timeindex
```

### 2.2 RemoteLogMetadataManager：一致性是难点

RLMM 要回答一个问题：**"offset 1000~2000 这段数据，现在在远端还是本地？在远端的哪个对象里？"**

两种实现思路：

| 实现 | 存储 | 优点 | 缺点 |
|---|---|---|---|
| `TopicBasedRemoteLogMetadataManager` | 内部 topic（`__remote_log_metadata`） | 复用 Kafka 自身复制机制，强一致 | 增加内部 topic 负载 |
| 自定义（如基于对象存储/DB） | 外部系统 | 不占 Kafka 资源 | 需要自己保证一致性与高可用 |

官方默认是 **topic-based**：把 segment 元数据写到内部 compact topic，天然具备分区级顺序 + 副本容错。代价是**每个 partition 的元数据变更都会产生一次内部 topic 写入**，量大时要单独评估。

### 2.3 元数据的状态机

一个 segment 在生命周期里会经历：

```
LOCAL_ONLY → COPY_SEGMENT_STARTED → COPY_SEGMENT_FINISHED → DELETE_SEGMENT_STARTED → DELETE_SEGMENT_FINISHED
```

任何一步失败都会重试，且**上传是幂等的**（同一个 segment 用同一个 UUID，重传覆盖）。这保证了 Broker 崩溃重启后能继续未完成的工作。

---

## 三、写路径：上传是怎么发生的

```
1. 活跃 segment 达到 segment.ms / segment.bytes → 滚动为新 segment
2. 旧 segment 变成"非活跃"，进入 RemoteLogManager 的待上传队列
3. RLM 的复制线程读取本地 .log/.index/.timeindex
4. 调用 RSM.copyLogSegmentData() 上传到对象存储（可并发、可分片）
5. 上传成功后更新 RLMM 元数据（COPY_SEGMENT_FINISHED）
6. 本地按 local.retention.ms 延迟删除
```

关键设计点：

- **上传不阻塞写入**：写请求只碰活跃 segment，上传是纯后台任务
- **上传有配额**：`remote.log.manager.task.interval.ms`、复制线程数、带宽限制，防止打满网卡
- **本地延迟删除**：即使上传成功，本地也保留一段时间（`local.retention.ms` 默认跟 `retention.ms` 走，需要显式调小），给"刚上传就要读"的场景兜底

---

## 四、读路径：消费者完全无感知

这是分层存储最漂亮的地方。消费者发 `Fetch(offset=1500000)`：

```
1. Broker 查本地日志，发现该 offset 所在 segment 已被删除
2. 查 RemoteLogMetadataCache，找到对应的 RemoteLogSegmentMetadata
3. 通过 RSM.fetchLogSegment() 从对象存储流式读取
4. 解析后按正常 Fetch 响应返回
```

对客户端来说，**协议、offset、消费位点语义完全不变**。几个重要细节：

- **一次 Fetch 可能跨越本地段和远端段**，Broker 会拼接返回
- **远端读取有单独的线程池**（`remote.log.reader.threads`），避免拖慢本地读
- **有超时与降级**：远端读超时（`remote.log.fetch.timeout.ms`）会返回错误，客户端重试
- **首次读远端有冷启动延迟**（几十到几百毫秒），所以**不要在分层存储上跑低延迟实时消费**

> 生产经验：把"实时业务消费"和"历史回溯消费"用**不同的 consumer group + 不同的 topic 副本**分开，或者干脆用 MirrorMaker 把实时链路单独导一份，避免历史回溯把对象存储的延迟带进主链路。

---

## 五、关键配置与容量计算

### 5.1 Broker 侧配置

```properties
# 开启分层存储（Broker 级）
remote.log.storage.system.enable=true

# 插件类
remote.log.storage.manager.class.name=org.apache.kafka.server.log.remote.storage.S3RemoteStorageManager
remote.log.metadata.manager.class.name=org.apache.kafka.server.log.remote.metadata.storage.TopicBasedRemoteLogMetadataManager

# 本地保留（核心！不设等于没省空间）
local.retention.ms=7200000          # 本地只留 2 小时
local.retention.bytes=-1

# 上传调度
remote.log.manager.task.interval.ms=30000
remote.log.manager.thread.pool.size=10
remote.log.reader.threads=8
remote.log.fetch.timeout.ms=15000

# 上传限流（按 Broker 出口带宽的 30% 估算）
remote.log.upload.throughput.limit=104857600   # 100MB/s
```

### 5.2 Topic 侧配置

```bash
kafka-configs.sh --bootstrap-server localhost:9092 --alter \
  --entity-type topics --entity-name order-events \
  --add-config 'remote.storage.enable=true,retention.ms=2592000000,local.retention.ms=3600000'
```

注意：**`remote.storage.enable` 只能在 topic 创建时开启或从 false→true 变更，一旦开启不能关闭**（Kafka 的限制）。所以灰度时务必选对 topic。

### 5.3 容量估算

假设：

- 峰值写入 200 MB/s，平均 80 MB/s
- 保留 30 天
- 副本数 3

本地磁盘需求（分层后）：

```
本地 = 平均写入 × local.retention × 副本数 × 1.3(峰值缓冲)
     = 80MB/s × 3600s × 3 × 1.3 ≈ 1.1 TB
```

不分层时：

```
本地 = 80MB/s × 86400 × 30 × 3 × 1.3 ≈ 810 TB
```

**差了 700 多倍。** 对象存储按 0.12 元/GB/月算，810TB ≈ 9.7 万/月；分层后本地 1TB SSD + 远端 810TB 对象存储 ≈ 10 万/月 + 少量 SSD 成本……这里的账要按实际单价算，但结论一致：**冷数据放对象存储，单位成本能降一个数量级**。

> 别忘了算**网络出口费**和**读放大**：历史回溯消费如果很频繁，对象存储的 GET 费用和延迟都会成为新问题。

---

## 六、分层存储 vs 其他方案

| 方案 | 本地磁盘 | 保留时长 | 读延迟 | 运维复杂度 | 适用 |
|---|---|---|---|---|---|
| 纯本地（默认） | 大 | 受磁盘限制 | 极低 | 低 | 7 天内短期保留 |
| 分层存储（KIP-405） | 小 | 可达数年 | 冷读 50~500ms | 中 | 需要长保留 + 可接受冷读 |
| 多集群 + MirrorMaker | 中 | 受目标集群限制 | 低 | 高 | 跨地域容灾 |
| 落湖（Kafka → 对象存储/湖表） | 小 | 无限 | 高（需查询引擎） | 中高 | 分析型回放 |
| 降副本 + 加盘 | 大 | 中 | 低 | 低 | 预算充足、不想改造 |

**选型建议**：

- 只是"想省钱、数据 7 天内"→ 别上分层，先做压缩（`compression.type=zstd`）和降副本
- "要留 30~180 天做回放/审计"→ 分层存储是最匹配的
- "要 SQL 查询/联邦分析"→ 直接落湖（Iceberg/Hudi），Kafka 只做管道

---

## 七、生产落地踩坑

1. **忘了设 `local.retention.ms`**
   很多人开了 `remote.storage.enable=true` 就以为省空间了，结果本地保留策略还是 `retention.ms=30天`，磁盘一点没降。**必须显式把 local 保留调小。**

2. **活跃 segment 永远不上传**
   如果 topic 写入量很小，segment 一直不滚动（未达到 `segment.ms`），数据就一直留在本地。解决：把 `segment.ms` 调到 1 小时级别。

3. **压缩 topic（compact）的边界**
   分层存储对 compact topic 的支持有额外约束（需要保证 key 的最新值不被错误清理）。生产上建议**只对普通 delete 策略的 topic 开启**，compact topic 谨慎评估。

4. **对象存储的"最终一致"陷阱**
   部分 S3 兼容存储（尤其自建 MinIO 的早期版本）在 list/head 上有延迟，导致上传成功但读不到。解决：优先用支持强一致的存储，或调大重试窗口。

5. **元数据 topic 成为瓶颈**
   `__remote_log_metadata` 的分区数默认较小，Topic 数量多、segment 滚动频繁时会出现写入排队。解决：提前扩容该 topic 分区（`remote.log.metadata.manager.topic.partitions`），并监控其 lag。

6. **冷读打爆对象存储 QPS**
   历史回溯消费突然拉起几百个 consumer，每个都从远端拉，对象存储 QPS 打满。解决：远端读限流 + 回溯专用集群 + 客户端侧缓存。

7. **监控盲区**
   必须监控：`RemoteLogManager` 上传失败数、上传延迟、本地待删除 segment 数、远端读超时率、对象存储 4xx/5xx。**没有这些指标，分层存储就是黑盒。**

---

## 八、面试常见追问

**Q1：分层存储会影响消息顺序性吗？**
不会。segment 迁移是按 offset 连续段整体搬移，消费仍按 offset 顺序读；Broker 会保证跨本地/远端的读取拼接是连续的。

**Q2：为什么以 segment 为单位而不是单条消息？**
对象存储适合大对象批量写，单条消息上传会产生海量小对象和元数据，成本与延迟都不可接受。segment 天然是"批量 + 不可变"，完美匹配对象存储。

**Q3：Broker 挂了，远端数据会丢吗？**
不会。远端数据本身有多副本（对象存储），元数据在内部 topic 有多副本。Broker 恢复后通过 RLMM 重建本地索引即可。

**Q4：分层存储能替代灾备吗？**
不能。它解决的是**存储成本与保留时长**，不是**可用性**。跨 AZ/跨地域容灾仍然需要多副本、MirrorMaker 或双集群。

**Q5：怎么评估要不要上？**
三个数：① 冷数据占比（保留时长内，超过 7 天的数据量占比）；② 冷读频率（历史回溯 QPS）；③ 本地磁盘成本 / 对象存储成本比。冷数据占比 > 60% 且冷读低，就值得上。

---

## 九、总结

分层存储的本质是**把 Kafka 从"存算一体"推进到"存算分离"的第一步**：

- **segment 级迁移**，客户端协议零改动
- **RSM + RLMM + RLM** 三层插件化，可对接任意对象存储
- **本地保留与远端保留解耦**，这是省钱的关键开关
- 代价是**冷读延迟**和**新的运维复杂度**，必须配套监控与限流

如果你的 Kafka 集群磁盘天天告警、又不敢删数据，分层存储几乎是唯一优雅的解法；但如果只是短期保留 + 高实时性，别为了架构而架构。
