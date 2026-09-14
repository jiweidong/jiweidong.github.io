---
title: 【Kafka 实战】Kafka Broker 端性能调优深度实战：从操作系统、JVM 到副本同步的全链路参数优化
date: 2026-09-14 08:00:00
tags:
  - Kafka
  - 性能调优
  - 消息队列
  - 运维
categories:
  - 消息队列
  - 中间件
author: 东哥
---

# 【Kafka 实战】Kafka Broker 端性能调优深度实战：从操作系统、JVM 到副本同步的全链路参数优化

## 面试官：Kafka 单机吞吐能到多少？如果让你调优一个吞吐上不去的集群，你会从哪几层入手？

「Kafka 很快」这句话人人会说，但**为什么快**、**瓶颈在哪**、**参数怎么调**，能答清楚的人不多。

更实际的问题是：**Kafka 集群上线后吞吐上不去，消息积压，但你不知道是磁盘、网络、JVM、还是参数配置的问题。**

这篇按「操作系统 → JVM → Broker 参数 → 副本与 ISR → 监控与压测」五个层次，给出完整的调优方法论和可直接落地的配置。

---

## 一、先理解 Kafka 为什么快：四个核心机制

调优必须从原理出发，否则就是瞎调参数。

### 1.1 顺序写（Sequential Write）

Kafka 的消息是**追加写**到 partition 对应的 log segment 文件。机械硬盘顺序写可达 300~600 MB/s，随机写只有约 100 IOPS。**顺序写让 Kafka 用廉价硬件就能获得高吞吐。**

关键参数：

- `log.segment.bytes`：单个 segment 大小，默认 1GB。**太小会导致频繁切文件（影响 retention 与索引），太大影响文件删除粒度**
- `log.index.interval.bytes`：索引稀疏度，默认 4KB。越小索引越密、查询越快、索引文件越大

### 1.2 Page Cache（页缓存）

Kafka **不在 JVM 堆里缓存消息**，而是依赖 OS 的 Page Cache：

```
Producer → Broker（写入 Page Cache）→ OS 异步刷盘
Consumer → Broker（从 Page Cache 读）→ 零拷贝发送
```

这就是为什么 Kafka 的 JVM 堆可以很小（通常 6~8GB），**把内存留给 OS Page Cache 才是正解**。消费者如果追上生产者进度（实时消费），读请求几乎全部命中 Page Cache，完全不走磁盘。

**推论**：`-Xmx` 给太大反而有害——堆越大 GC 停顿越长，而且挤占了 Page Cache。

### 1.3 零拷贝（Zero-Copy / sendfile）

传统读取-发送需要 4 次拷贝 + 4 次上下文切换（磁盘→内核缓冲→用户缓冲→Socket 缓冲→网卡）。Kafka 用 `sendfile` 系统调用做到 **2 次拷贝、2 次上下文切换**，数据直接从 Page Cache 到网卡。

**推论**：如果 Broker 与 Consumer 处于同一台机器，Kafka 会退化走普通路径（无法享受 sendfile）；SSL/TLS 加密也会破坏零拷贝（需要用户态加解密）。

### 1.4 批量 + 压缩

Producer 攒批（`batch.size`、`linger.ms`）、Broker 以「日志段 + 索引」为单位存储、Consumer 批量拉取。压缩在 Producer 端做、Broker 原样存储（Broker 不解压）、Consumer 端解压。

**推论**：`compression.type=zstd`/`lz4` 能显著降低网络与磁盘压力，代价是 CPU。**Broker 端不要配置压缩（`compression.type=producer` 让 Producer 决定）**。

---

## 二、第一层：操作系统调优（收益最大，最容易被忽略）

Kafka 官方文档明确说：**大部分调优应在 OS 层完成**。

### 2.1 文件描述符

```bash
# 每个 segment、每个连接都要占 fd。Kafka 很容易达到几万 fd
ulimit -n
# /etc/security/limits.conf
kafka soft nofile 1000000
kafka hard nofile 1000000
# systemd 服务还需
LimitNOFILE=1000000
```

**症状**：日志出现 `Too many open files`，或者 `java.io.IOException: Too many open files`。

### 2.2 虚拟内存与脏页

```bash
# 查看当前值（单位：页，1 页通常 4KB）
sysctl -a | grep -E "vm.swappiness|vm.dirty_ratio|vm.dirty_background_ratio"

# 关键调整
vm.swappiness=1                        # 禁止换出，避免 Page Cache 被换到 swap
vm.dirty_background_ratio=5            # 后台刷盘启动阈值（默认 10）
vm.dirty_ratio=80                      # 同步刷盘阻塞阈值（默认 20）
vm.dirty_expire_centisecs=300000       # 5 分钟
vm.dirty_writeback_centisecs=1000
```

**为什么 `dirty_ratio` 要调大？**
Kafka 是顺序写，脏页可以攒很多再一起刷盘，刷盘效率更高。`dirty_ratio=80` 意味着脏页占内存 80% 才阻塞写入。如果保持默认 20%，会出现**「先阻塞、再释放、再阻塞」的锯齿形抖动**，表现为 P99 延迟尖刺。

**为什么 `swappiness=1`？**
Kafka 完全依赖 Page Cache，一旦被换出，读请求全部变成磁盘 IO，吞吐断崖式下跌。

### 2.3 网络

```bash
net.core.wmem_default=212992
net.core.rmem_default=212992
net.core.rmem_max=16777216            # 单 socket 最大接收缓冲 16MB
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 65536 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=100000    # 网卡收包队列
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=32768              # accept 队列
net.ipv4.tcp_wmem / tcp_rmem：socket 缓冲自动调优
net.ipv4.tcp_window_scaling=1         # 大带宽时延积必需
net.ipv4.tcp_slow_start_after_idle=0  # 长连接避免重新慢启动
```

**跨机房复制场景特别注意**：带宽时延积（BDP）= 带宽 × RTT。跨机房 RTT 30ms、带宽 1Gbps → BDP ≈ 3.75MB，socket 缓冲必须大于这个值，否则吞吐被限制。

### 2.4 文件系统与挂载

```bash
# 用 XFS（Kafka 官方推荐），不用 ext4
mkfs.xfs /dev/vdb
mount -o noatime,nodiratime /dev/vdb /data/kafka
```

- **`noatime`**：禁止记录访问时间，减少元数据写
- **避免 RAID 5/6**：写惩罚严重，用 RAID 10 或 JBOD（Kafka 自带副本冗余，JBOD + 副本更划算）
- **不要用 NFS**：Kafka 对 fsync 与延迟敏感

### 2.5 磁盘选择与容量规划

| 磁盘类型 | 顺序写吞吐 | 适用场景 |
| --- | --- | --- |
| 机械盘（HDD） | 100~200 MB/s | 大容量、低吞吐、日志类 |
| SATA SSD | 400~500 MB/s | 通用 |
| NVMe SSD | 1~3 GB/s | 高吞吐、低延迟 |

**容量规划公式**：

```
所需磁盘 = 消息速率(MB/s) × 保留时长(秒) × 副本数 ÷ 压缩比增益
```

例：100 MB/s × 7 天(604800s) × 3 副本 ÷ 1 ≈ **181 TB**（未计压缩）。这就是为什么 Kafka 集群容量规划必须从「保留策略」倒推。

⚠️ **磁盘使用率超过 80% 会显著劣化性能**（尤其 HDD，外圈变内圈）。建议设置告警阈值 70%，并配置 `log.retention.bytes` 做兜底。

---

## 三、第二层：JVM 调优

### 3.1 堆大小：6~8GB 是甜点

```bash
# Kafka 官方推荐（kafka-server-start.sh 中的 KAFKA_HEAP_OPTS）
export KAFKA_HEAP_OPTS="-Xmx8G -Xms8G"
```

**为什么不建议更大？**

1. **GC 停顿**：堆越大，Full GC 停顿越长。Kafka 对延迟敏感，1 秒的 STW 会导致大量请求超时
2. **挤占 Page Cache**：物理内存固定，堆多了 Page Cache 就少了
3. **Kafka 的对象生命周期都很短**（网络缓冲区、请求队列），不需要大堆

**堆小于 6GB 也不建议**：高吞吐下 `kafka-network-thread` 的 send/recv 缓冲区、以及大量分区元数据会吃内存。

### 3.2 GC 选择

JDK 11+ 推荐 G1（Kafka 默认），JDK 8 可用 G1 或 CMS：

```bash
export KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseG1GC \
  -XX:MaxGCPauseMillis=20 \
  -XX:InitiatingHeapOccupancyPercent=35 \
  -XX:G1HeapRegionSize=16M \
  -XX:MetaspaceSize=96m \
  -XX:+ExplicitGCInvokesConcurrent \
  -XX:+ParallelRefProcEnabled"
```

关键参数说明：

| 参数 | 作用 | 建议 |
| --- | --- | --- |
| `MaxGCPauseMillis` | 目标停顿（软目标） | 20ms，Kafka 官方值 |
| `InitiatingHeapOccupancyPercent` | 触发并发标记的堆占用比例 | **35**（默认 45，Kafka 建议提前） |
| `G1HeapRegionSize` | 区域大小 | 16M，减少 Humongous 对象碎片 |
| `ExplicitGCInvokesConcurrent` | `System.gc()` 走并发而非 Full | 防止意外 Full GC |
| `ParallelRefProcEnabled` | 并行处理引用 | 减少 GC 停顿 |

### 3.3 JVM 日志与 OOM

```bash
export KAFKA_HEAP_OPTS="-Xmx8G -Xms8G -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/data/kafka/dumps"
export KAFKA_JVM_PERFORMANCE_OPTS="... -Xlog:gc*:file=/data/kafka/logs/gc.log:time,uptime,level,tags:filecount=10,filesize=50M"
```

**注意**：Kafka 的 JVM 堆里不应该缓存消息。如果发现堆占用持续增长不降，多半是：分区数过多导致元数据膨胀、或者 Producer/Consumer 客户端（同进程）泄漏。

---

## 四、第三层：Broker 核心参数

### 4.1 线程模型参数

```properties
# 网络线程：处理网络 IO（收包、发送、连接管理）
num.network.threads=8

# IO 线程：处理请求（写日志、读日志、副本同步）
num.io.threads=16

# 请求队列
queued.max.requests=500

# Socket 缓冲区
socket.send.buffer.bytes=1048576      # 1MB
socket.receive.buffer.bytes=1048576
socket.request.max.bytes=104857600    # 最大请求 100MB，必须 > message.max.bytes
```

**调优规则**：

- `num.network.threads`：一般等于 CPU 核数（或核数 +1）。**不要设太大**，会有锁竞争与上下文切换开销
- `num.io.threads`：建议 CPU 核数的 2 倍（IO 线程会阻塞在磁盘写入上）。**SSD/NVMe 可以更大，HDD 不宜过大**
- `queued.max.requests`：请求队列长度。**太小 → 请求被拒绝；太大 → 内存堆积**。观察 `RequestQueueSize` 指标

**典型症状与对策**：

| 症状 | 指标 | 对策 |
| --- | --- | --- |
| 网络线程饱和 | `NetworkProcessorAvgIdlePercent` < 0.3 | 增大 `num.network.threads` |
| IO 线程饱和 | `RequestHandlerAvgIdlePercent` < 0.3 | 增大 `num.io.threads` 或换更快的盘 |
| 请求队列堆积 | `RequestQueueSize` 持续 > 0 | 增大 IO 线程数 |
| 请求排队超时 | 客户端 `request.timeout.ms` 报错 | 上游限流或扩容 Broker |

### 4.2 分区与副本

```properties
num.partitions=6                          # 默认分区数（建 topic 未指定时使用）
default.replication.factor=3              # 生产建议 3
min.insync.replicas=2                     # 与 acks=all 配合，保证不丢数据
auto.create.topics.enable=false           # 生产关闭自动建 topic
```

**`min.insync.replicas` 是数据可靠性的核心参数**：

- `acks=all` + `min.insync.replicas=2` + `replication.factor=3` → 容忍 1 个副本故障不丢数据
- 若 ISR 收缩到 1，写入会直接失败（`NOT_ENOUGH_REPLICAS`），**这是保护而非故障**——宁可拒绝写，也不要静默丢数据

⚠️ **分区数不是越多越好**：

- 每个 partition 对应一组 segment 文件与 fd，占用 Broker 内存（`log.dirs` 下文件数 = 分区数 × 每分区 segment 数）
- 分区越多，Rebalance 越慢，Controller 元数据越大
- 单 Broker 分区数建议控制在 **2000~4000** 以内（Kafka 2.x），KRaft 模式可放宽

### 4.3 日志段与保留

```properties
log.dirs=/data1/kafka-logs,/data2/kafka-logs   # 多磁盘，分散 IO
log.segment.bytes=1073741824                    # 1GB
log.roll.hours=168                              # 7 天强制滚动
log.retention.hours=168                         # 保留 7 天
log.retention.bytes=-1                          # 按大小保留（-1 表示不限）
log.cleanup.policy=delete                      # delete | compact
log.index.interval.bytes=4096
log.index.size.max.bytes=10485760               # 10MB
```

**`log.cleanup.policy=compact`** 用于「键值快照」场景（如 CDC 数据同步、Kafka Streams 状态存储），会保留每个 key 的最新值。**不要对普通消息流用 compact**，会导致文件不断重写。

### 4.4 刷盘策略（重要：不要乱调）

```properties
# 默认值就是最优解，不要改！
log.flush.interval.messages=9223372036854775807      # 不按条数刷
log.flush.interval.ms=null                            # 不按时间刷
log.flush.scheduler.interval.ms=9223372036854775807
```

**为什么默认不主动 fsync？**

Kafka 的可靠性靠**副本机制**，不靠单机 fsync：

- 数据写入 Page Cache 后即对消费者可见
- 副本同步也走 Page Cache（fetch 请求读的是 Page Cache）
- 即使单机断电丢数据，只要 ISR 中有其他副本，数据就不丢

**主动 fsync 会严重降低吞吐**（随机 IO + 阻塞）。**网上很多「优化建议」让你调 `log.flush.interval.messages=10000`，这是错误的**——它会让吞吐掉一个数量级，而可靠性并没有提升。

正确的可靠性配置是：`acks=all` + `replication.factor=3` + `min.insync.replicas=2`。

### 4.5 副本同步参数

```properties
# Follower 落后超过该时间被认为失效并踢出 ISR
replica.lag.time.max.ms=30000         # 默认 30s，建议 10~30s

# Follower fetch 相关
replica.fetch.max.bytes=1048576       # 单次 fetch 最大字节
replica.fetch.wait.max.ms=500         # fetch 等待时间
replica.fetch.min.bytes=1
replica.socket.receive.buffer.bytes=65536
replica.socket.timeout.ms=30000

# 副本拉取的线程数
num.replica.fetchers=4                # 默认 1，跨机房/大分区时增大
```

**关键调优点：`num.replica.fetchers`**

默认只有 1 个线程做副本同步。**分区数多、或跨机房复制时，单线程成为瓶颈**，表现为 Follower 持续落后、ISR 频繁收缩、`UnderReplicatedPartitions > 0`。

建议：

- 同机房：`num.replica.fetchers=2~4`
- 跨机房：`num.replica.fetchers=4~8`，并配合增大 `replica.fetch.max.bytes`

**`replica.lag.time.max.ms` 调小 vs 调大**：

- 调小（如 10s）：ISR 收缩更敏感，数据可靠性提高，但网络抖动时容易频繁进出 ISR，导致写入失败（`NOT_ENOUGH_REPLICAS`）
- 调大（如 60s）：容错更好，但「僵尸副本」可能被误认为存活，增加数据丢失风险

**推荐：同机房 10s，跨机房 30s。**

### 4.6 其他重要参数

```properties
# 数据目录均衡
log.dirs 多盘时，Kafka 会自动在目录间分配新分区（旧分区不会自动迁移）

# 消息大小
message.max.bytes=1048588              # 默认约 1MB
replica.fetch.max.bytes 必须 > message.max.bytes

# 组协调
offsets.topic.replication.factor=3      # __consumer_offsets 的副本数，**必须 >= 3**
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
group.min.session.timeout.ms=6000
group.max.session.timeout.ms=1800000

# Leader 均衡
auto.leader.rebalance.enable=true      # 自动把分区 leader 均衡到各 Broker
leader.imbalance.check.interval.seconds=300
leader.imbalance.per.broker.percentage=10

# 元数据（KRaft）
controller.quorum.voters=...            # KRaft 集群必须配置
```

**`offsets.topic.replication.factor` 极易踩坑**：如果建集群时只有一个 Broker，这个 topic 会以副本数 1 创建，之后加 Broker 也不会自动增加副本。**集群扩容后必须手动检查并重分配**：

```bash
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic __consumer_offsets | head -5
# 若 ReplicationFactor 为 1，需要重新分配
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassign.json --execute
```

---

## 五、第四层：副本、ISR 与容量治理

### 5.1 ISR 频繁收缩的排查路径

**现象**：`UnderReplicatedPartitions > 0` 持续波动，日志频繁出现 `Shrinking ISR`。

排查顺序：

1. **看 Follower 是否在同步**：

   ```bash
   kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic mytopic
   # 关注 Isr 列与 Replicas 列
   ```

   ```bash
   # 看副本 lag（Kafka 自带工具）
   kafka-replica-verification.sh --broker-list localhost:9092 --topic-white-list 'mytopic'
   ```

2. **看 Follower 所在 Broker 的 IO 与网络**：`iostat -x 1`、`sar -n DEV 1`
3. **看 fetch 线程是否饱和**：增大 `num.replica.fetchers`
4. **看磁盘是否接近满**（> 80% 时 IO 性能骤降）
5. **看 GC 是否频繁**（Follower 的 fetch 线程被 GC 停顿阻塞）
6. **看是否单分区过大**：单分区吞吐超过单盘能力，考虑拆分分区

### 5.2 分区与 Leader 均衡

**分区重分配工具**是运维必备：

```bash
# 1. 生成重分配方案（把分区从旧 Broker 迁到新 Broker）
cat > topics.json <<'EOF'
{"topics":[{"topic":"mytopic"}],"version":1}
EOF

kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --topics-to-move-json-file topics.json \
  --broker-list "1,2,3,4,5,6" --generate

# 2. 执行（务必加 --throttle 限速，否则打满网络）
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file plan.json --execute \
  --throttle 104857600   # 100 MB/s

# 3. 验证 / 完成
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file plan.json --verify
```

⚠️ **重分配必须限速**：不限速会打满网络与磁盘，导致正常读写超时。完成后记得 `--verify`，并注意 Kafka 不会自动取消限速（需要显式 `--throttle 0` 或等 `replica.fetch` throttle 自动清除）。

### 5.3 容量与保留策略组合

推荐三层防护：

```properties
log.retention.hours=168          # 时间维度：7 天
log.retention.bytes=1099511627776 # 大小维度：单分区 1TB 兜底
# 加上磁盘监控告警 70%
```

**只配时间不配大小**，遇到流量突增会导致磁盘打满，Kafka 直接停止接受写入（且清理可能来不及）。**只配大小不配时间**，低流量时数据可能保留过久。

---

## 六、第五层：压测与监控

### 6.1 官方压测工具

```bash
# 生产压测：单分区 ~ 200万条/秒（视硬件）
kafka-producer-perf-test.sh --topic perf-test \
  --num-records 10000000 --record-size 1024 \
  --throughput -1 --producer-props \
  bootstrap.servers=localhost:9092 acks=1 batch.size=65536 linger.ms=5 \
  compression.type=lz4

# 消费压测
kafka-consumer-perf-test.sh --topic perf-test \
  --bootstrap-server localhost:9092 --messages 10000000 --threads 4
```

**测试方法论**：

1. **先测单 Broker 基线**：单分区、单 Producer、单 Consumer
2. **逐步加压**：从 50% 目标吞吐开始，每次 +25%，记录延迟
3. **找到拐点**：延迟曲线从平缓突然上升的点就是瓶颈点
4. **定位瓶颈层**：看 `sar`（CPU/网络）、`iostat`（磁盘）、`ss`（网络队列）、GC 日志

### 6.2 必看监控指标

| 指标 | 含义 | 告警建议 |
| --- | --- | --- |
| `BytesInPerSec` / `BytesOutPerSec` | 吞吐 | 趋势判断 |
| `MessagesInPerSec` | 消息速率 | 突降说明生产端问题 |
| `UnderReplicatedPartitions` | **副本不足分区数** | **> 0 立即告警，最核心指标** |
| `OfflinePartitionsCount` | 离线分区数 | **> 0 严重告警** |
| `IsrShrinksPerSec` / `IsrExpandsPerSec` | ISR 抖动 | 持续 > 0 需排查 |
| `ActiveControllerCount` | 活跃 Controller 数 | **整个集群必须恒为 1** |
| `RequestHandlerAvgIdlePercent` | IO 线程空闲率 | < 0.3 需要加线程 |
| `NetworkProcessorAvgIdlePercent` | 网络线程空闲率 | < 0.3 需要加线程 |
| `RequestQueueSize` | 请求队列长度 | 持续 > 0 说明处理不过来 |
| `LeaderCount` / `PartitionCount` | Leader/分区分布 | 不均衡需重分配 |
| `UncleanLeaderElectionsPerSec` | 脏选举次数 | **> 0 说明可能丢数据** |
| `LogFlushRateAndTimeMs` | 刷盘统计 | 异常升高说明 Page Cache 压力大 |
| 磁盘使用率 / inode | 磁盘水位 | 70% 告警 |
| 消费者 `records-lag-max` | 消费滞后 | 业务级告警 |

`ActiveControllerCount` 恒为 1 是个容易被忽略但极其重要的指标——**出现 2 说明脑裂，出现 0 说明没有 Controller（无法处理元数据变更）**。

---

## 七、调优 Checklist（上线前过一遍）

### 操作系统

- [ ] `ulimit -n` ≥ 100000
- [ ] `vm.swappiness=1`
- [ ] `vm.dirty_background_ratio=5`、`vm.dirty_ratio=80`
- [ ] socket 缓冲与 `netdev_max_backlog` 调大
- [ ] XFS + `noatime`，不用 NFS
- [ ] 磁盘使用率告警 70%

### JVM

- [ ] `-Xmx8G -Xms8G`（不要更大）
- [ ] G1 + `MaxGCPauseMillis=20` + `InitiatingHeapOccupancyPercent=35`
- [ ] GC 日志落文件 + 轮转 + `HeapDumpOnOutOfMemoryError`

### Broker

- [ ] `num.network.threads` ≈ CPU 核数
- [ ] `num.io.threads` = 2 × CPU 核数（SSD 可更多）
- [ ] `default.replication.factor=3`、`min.insync.replicas=2`
- [ ] `offsets.topic.replication.factor=3`
- [ ] `auto.create.topics.enable=false`
- [ ] `num.replica.fetchers` 按跨机房需求调到 2~8
- [ ] `log.flush.*` **保持默认，不要主动 fsync**
- [ ] `replica.lag.time.max.ms`：同机房 10s，跨机房 30s
- [ ] `log.dirs` 多盘分散

### 监控

- [ ] `UnderReplicatedPartitions` = 0
- [ ] `OfflinePartitionsCount` = 0
- [ ] `ActiveControllerCount` = 1
- [ ] 线程空闲率 > 0.3
- [ ] 消费者 lag 业务级监控

---

## 八、面试追问连环炮

**Q1：Kafka 为什么快？**
四个机制：① 顺序读写（Append-only log）；② Page Cache（不依赖 JVM 堆）；③ 零拷贝 `sendfile`；④ 批量 + 压缩。这四点合起来让 Kafka 用普通硬件达到高吞吐。

**Q2：为什么 Kafka 的 JVM 堆只要 6~8GB？**
消息缓存在 OS Page Cache 而非 JVM 堆。堆太大既增加 GC 停顿，又挤占 Page Cache。Kafka 的对象生命周期短，大堆无收益。

**Q3：`min.insync.replicas=2` 的作用？**
配合 `acks=all`，要求至少 2 个副本确认写入。ISR 收缩到 1 时写入直接失败，属于**保护机制**——宁可拒绝写也不静默丢数据。若设 1，则 acks=all 退化为只等 Leader，与 acks=1 无区别。

**Q4：为什么不建议调 `log.flush.interval.messages`？**
Kafka 可靠性靠副本而非单机 fsync。主动 fsync 带来随机 IO 与阻塞，吞吐掉一个数量级，而可靠性没有提升（数据早已被 ISR 中其他副本同步）。正确做法是 `acks=all` + 3 副本 + `min.insync.replicas=2`。

**Q5：ISR 频繁收缩怎么排查？**
① 看 Follower 所在 Broker 的磁盘 IO 与网络；② 增大 `num.replica.fetchers`；③ 检查磁盘水位（> 80%）；④ 看 GC 停顿；⑤ 看是否存在单分区吞吐超单盘能力的「超大分区」；⑥ 跨机房场景检查带宽时延积与 socket 缓冲。

**Q6：分区数怎么定？**
按目标吞吐 / 单分区吞吐估算，再考虑消费并行度。经验值：单分区 10~50 MB/s（HDD 到 NVMe）。但要控制上限——单 Broker 2000~4000 分区（传统）以内，否则元数据与 fd 压力大，Rebalance 慢。

**Q7：`auto.leader.rebalance.enable` 有什么风险？**
它会把 leader 迁移到 preferred replica，可能触发客户端元数据刷新与短暂不可用。生产可设为 `true` 但配合 `leader.imbalance.check.interval.seconds` 与百分比阈值，让倾斜不严重时不动作。

**Q8：跨机房复制吞吐上不去，怎么调？**
① 增大 `num.replica.fetchers`（4~8）；② 增大 socket 缓冲（BDP 必须满足）；③ 增大 `replica.fetch.max.bytes`；④ 开启压缩（`compression.type=zstd/lz4`）；⑤ 检查 `replica.lag.time.max.ms` 是否过小导致频繁 ISR 收缩，反过来拖慢同步。

---

## 九、总结

Kafka Broker 调优的五个层次，按收益排序：

1. **操作系统**（收益最大）：fd、swappiness、脏页、网络缓冲、XFS、磁盘水位
2. **JVM**：堆 6~8GB、G1、提前并发标记、GC 日志
3. **Broker 参数**：线程数、副本因子、`min.insync.replicas`、`num.replica.fetchers`、**`log.flush.*` 保持默认**
4. **副本与容量**：ISR 治理、分区重分配（必须限速）、保留策略三重防护
5. **压测与监控**：`kafka-producer-perf-test` 找拐点；`UnderReplicatedPartitions`、`ActiveControllerCount` 等核心指标告警

记住三条最反直觉的结论：**堆不要大、不要主动 fsync、分区不是越多越好**。把这三条理解透，Kafka 调优就入门了。
