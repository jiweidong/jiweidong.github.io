---
title: 【Kafka 源码】Kafka Consumer 消费流程源码深度解析：从 poll() 到位移提交
date: 2026-08-13 08:00:00
tags:
  - Kafka
  - 源码
  - 面试
categories:
  - 中间件
  - Kafka
  - 消息队列
author: 东哥
---

# 【Kafka 源码】Kafka Consumer 消费流程源码深度解析：从 poll() 到位移提交

## 面试官：Kafka 消费者 poll 一次拉多少数据？offset 是什么时候提交的？重复消费怎么产生的？

生产者端我们聊过 `send()` 的完整链路，今天把**消费端**讲透。消费者看似简单——`while (true) { consumer.poll(1000); }`——但这一行背后藏着：协调器（Coordinator）、分区拉取（Fetcher）、位移管理（Offset）、再平衡（Rebalance）、心跳（Heartbeat）五大模块。

本文从 `KafkaConsumer.poll()` 源码出发，逐层拆解消费全流程。

## 一、消费者核心组件一览

| 组件 | 类 | 职责 |
| --- | --- | --- |
| 消费者门面 | `KafkaConsumer` | 对外 API：poll、commit、subscribe、seek |
| 协调器 | `ConsumerCoordinator` | 与 Broker 端 GroupCoordinator 通信：加入组、心跳、提交位移 |
| 拉取器 | `Fetcher` | 发送 FetchRequest、解析响应、管理拉取缓冲区 |
| 订阅状态 | `SubscriptionState` | 记录订阅分区、拉取位置（position）、暂停/恢复状态 |
| 网络客户端 | `ConsumerNetworkClient` | 异步发送请求、轮询响应（基于 Selector） |
| 序列化 | `Deserializer` | 反序列化 key/value |

## 二、poll() 的主流程

```java
public ConsumerRecords<K, V> poll(Duration timeout) {
    // 1. 先检查并执行 pending 的异步回调
    acquireAndEnsureOpen();
    ...
    // 2. 更新拉取位置（从订阅状态里取，或从 committed offset 恢复）
    updateAssignmentMetadataIfNeeded(timeout);
    // 3. 核心：拉取数据
    do {
        final Map<TopicPartition, List<ConsumerRecord<K, V>>> records = pollForFetches(timeout);
        if (!records.isEmpty()) {
            // 4. 更新拉取位置 position = 最后一条消息 offset + 1
            fetcher.resetOffsetsIfNeeded();
            return ConsumerRecords.of(records);  // 返回本次拉取的消息
        }
    } while (System.currentTimeMillis() < deadline);  // 未拉取到就一直循环到超时
    return ConsumerRecords.empty();
}
```

`poll()` 内部实际做了四件事：

1. **协调（协调器工作）**：确保协调器就绪、加入消费组、处理再平衡；
2. **更新拉取位置**：首次消费时根据 `auto.offset.reset`（earliest/latest）确定起始位置；
3. **拉取数据**：从已完成的分区拉取请求中取结果，没有则发送新请求；
4. **提交位移（如果开启自动提交）**：`enable.auto.commit=true` 时，poll 里会顺带提交上一批已消费的位移。

### 2.1 updateAssignmentMetadataIfNeeded

```java
private void updateAssignmentMetadataIfNeeded(Duration timeout) {
    // 1. 确保与 GroupCoordinator 的连接（找协调器）
    coordinator.ensureCoordinatorReady(timeout);
    // 2. 如果不在组内（未加入/已离开），执行加入组流程
    if (coordinator.rejoinNeededOrPending()) {
        coordinator.ensureActiveGroup(timeout);   // JoinGroup + SyncGroup
    }
    // 3. 拉取位移：从 __consumer_offsets 中获取每个分区的 committed offset
    //    没有 committed 时按 auto.offset.reset 决定
    if (metadata.needOffsetUpdate(...)) {
        fetcher.updateFetchPositions(...);
    }
}
```

> 关键点：**协调工作全部发生在 poll() 内**。如果你把 `poll` 间隔调得很大（如 30 秒），心跳、再平衡检测都会被推迟——这正是 `max.poll.interval.ms` 的由来。

## 三、拉取数据：Fetcher 的工作

### 3.1 pollForFetches 双阶段

```java
private Map<TopicPartition, List<ConsumerRecord<K, V>>> pollForFetches(Duration timeout) {
    // 阶段一：先处理已完成（in-flight 返回）的拉取响应
    final FetchCollector recordCollector = new FetchCollector();
    Map<TopicPartition, List<ConsumerRecord<K, V>>> records = fetcher.fetchedRecords(recordCollector);
    if (!records.isEmpty()) return records;   // 有数据直接返回，不再发新请求

    // 阶段二：发送新的拉取请求（补拉）
    fetcher.sendFetches();
    // 等待响应（最长 timeout）
    client.poll(timeout, () -> !fetcher.hasCompletedFetches());
    return fetcher.fetchedRecords(recordCollector);
}
```

### 3.2 拉取请求的组装

```java
// Fetcher.sendFetches 内部
Map<Node, FetchSessionHandler.FetchRequestData> fetchable = fetchablePartitions();  // 可拉取的分区
for (Map.Entry<Node, FetchSessionHandler.FetchRequestData> entry : fetchable.entrySet()) {
    // 按 Broker 节点分组发送 FetchRequest
    FetchRequest.Builder request = FetchRequest.Builder
        .forConsumer(this.maxWaitMs, this.minBytes, fetchData);  // fetch.max.wait.ms / fetch.min.bytes
    ...
}
```

**关键参数**（都在这里生效）：

| 参数 | 默认值 | 作用 |
| --- | --- | --- |
| `max.partition.fetch.bytes` | 1MB | 单分区单次拉取的最大字节数 |
| `fetch.min.bytes` | 1 | 至少积累多少字节才返回（1 表示有数据就返回） |
| `fetch.max.wait.ms` | 500 | 数据不足 fetch.min.bytes 时最多等待多久 |
| `max.poll.records` | 500 | 单次 poll 返回的最大消息条数 |
| `fetch.max.bytes` | 50MB | 单次拉取所有分区的总字节上限 |

> 调优口诀：**要吞吐就调大 fetch.min.bytes / fetch.max.wait.ms（攒批）；要低延迟就调小等待**。`max.poll.records` 控制单次 poll 的条数，也间接影响 `max.poll.interval.ms` 是否超时。

### 3.3 拉取缓冲与返回

- Broker 返回的数据按分区放入 `Fetcher` 的 `completedFetches` 队列；
- `fetchedRecords` 从队列取出 `CompletedFetch`，逐条反序列化（`Deserializer`），并**把每条消息的位移递增更新到 position**；
- 返回给调用者的同时，`SubscriptionState.position(tp)` 已经推进到「最后一条已返回消息 offset + 1」。

## 四、位移管理（Offset）

### 4.1 位移存储位置

- **旧版（0.8 之前）**：存 ZooKeeper；
- **现代（0.9+）**：存内部主题 `__consumer_offsets`（50 个分区，按 `group + topic + partition` 哈希取模定位）。

### 4.2 提交时机与方式

```java
// 自动提交（默认 enable.auto.commit=true）
// 时机：每次 poll() 返回前，提交"上一次 poll 返回的消息"的位移
// 注意：是"上一次"！本次 poll 拉到的消息还没被业务处理完，位移不会立即提交
props.put("enable.auto.commit", "true");
props.put("auto.commit.interval.ms", "5000");  // 默认 5 秒

// 手动提交
props.put("enable.auto.commit", "false");
consumer.commitSync();    // 同步提交：阻塞直到 Broker 确认，失败抛异常可重试
consumer.commitAsync(...); // 异步提交：不阻塞，回调处理结果，注意与 commitSync 的配合
```

**自动提交的经典坑**：`poll()` 拉取 500 条 → 业务处理耗时很长 → 还没处理完，下一次 poll 触发提交（提交的是上次的位移）——如果此时进程崩溃，**已处理但未提交**的消息就会重复消费。

### 4.3 重复消费与消息丢失

| 问题 | 产生原因 | 解决方案 |
| --- | --- | --- |
| 重复消费 | 处理完未提交位移就宕机 / 再平衡 | 业务幂等（唯一键/去重表）；手动提交放处理成功后 |
| 消息丢失 | 自动提交且处理失败未重试 / `acks=0` 生产者 | 关闭自动提交，手动确认；消费失败重试或进死信 |
| 位移回退 | 手动 `seek()` / 重置 | 按业务场景谨慎使用 |

### 4.4 位移提交的源码位置

`ConsumerCoordinator.commitOffsetsSync` / `commitOffsetsAsync` 会构造 `OffsetCommitRequest` 发送给 GroupCoordinator，Broker 端写入 `__consumer_offsets`。提交的分区集合是 `SubscriptionState.allConsumed()` 中「已分配且 position 有效」的分区。

## 五、协调器与再平衡（Rebalance）

### 5.1 消费组状态机

Broker 端 GroupCoordinator 维护组的状态：

```
Empty → PreparingRebalance → CompletingRebalance → Stable → (回到 PreparingRebalance)
```

触发再平衡的条件：

- 新消费者加入 / 消费者离开（超时/崩溃）；
- 订阅主题变化（`subscribe` 新主题）；
- 分区数变化（`NewPartitions`）；
- `max.poll.interval.ms` 超时（消费者处理太慢被判定失联）。

### 5.2 加入组流程（ensureActiveGroup）

```
消费者 → JoinGroupRequest（含订阅信息、分配策略）
  Broker 选出 Leader（第一个加入的消费者）
  Leader → 执行分区分配策略（RangeAssignor / RoundRobinAssignor / StickyAssignor）
  Leader → SyncGroupRequest（把分配结果发给协调器）
  所有成员 → SyncGroupResponse（拿到各自的分区分配）
```

### 5.3 两种再平衡协议

| 协议 | 特点 | 问题 |
| --- | --- | --- |
| Eager（旧默认） | 先撤销全部分区，再重新分配 | 再平衡期间**完全停止消费**，STW 式停顿 |
| Cooperative（粘性增量） | 只撤销需要变更的分区，增量协商 | 可能经历多次小规模再平衡，但消费基本不中断 |

> `partition.assignment.strategy` 配置分配器：`RangeAssignor`（按主题连续区间，可能不均）、`RoundRobinAssignor`（轮询，较均匀）、`StickyAssignor`（粘性，尽量保留原分配）。生产推荐 Cooperative + Sticky 组合。

### 5.4 心跳机制

- 消费者通过 `ConsumerCoordinator` 定时发送心跳（`heartbeat.interval.ms`，默认 3s）；
- `session.timeout.ms`（默认 45s）超时未心跳 → 协调器判定消费者死亡 → 触发再平衡；
- `max.poll.interval.ms`（默认 5min）超时未 poll → 消费者主动触发 rejoin（即使心跳正常）。

**注意**：心跳是在 poll 内部发送的。所以**处理消息的耗时**要控制在 `max.poll.interval.ms` 以内，否则即使进程活着也会被踢出消费组。解法：调大 `max.poll.interval.ms`、调小 `max.poll.records`、或把耗时的处理逻辑异步化。

## 六、面试高频追问

### 追问 1：poll(1000) 里的 1000 是什么意思？

不是「每 1000ms 拉一次」，而是「**本次 poll 最多阻塞 1000ms**」。如果拉取请求很快返回了数据，poll 立即返回；只有没数据时才阻塞等待，直到超时返回空集合。

### 追问 2：消费位移存在哪？offset 会无限增长吗？

存在 Broker 的 `__consumer_offsets` 内部主题。`log.retention.hours` 默认 7 天保留；位移主题本身默认 `offsets.retention.minutes`（默认 7 天，与 `offsets.retention.check.interval.ms` 配合清理）——**消费组 7 天不活跃，位移会被删除**，重新消费时按 `auto.offset.reset` 决定起点。

### 追问 3：为什么说 Kafka 只保证分区内有序？

因为分区是 Kafka 并行的最小单位：同一分区内消息追加写入、顺序消费；不同分区之间天然无序。要全局有序只能单分区（牺牲并行度）。生产上按 key 哈希保证同一业务 key 进入同一分区即可。

### 追问 4：消费太慢怎么办？

1. 调大 `max.poll.records` + 调大 `max.poll.interval.ms`；
2. 增加消费者实例（不超过分区数，否则有消费者空转）；
3. 增加分区数（注意：分区只能增不能减，且会影响 key 哈希分布）；
4. 消费逻辑异步化、批量处理、幂等去重。

### 追问 5：手动提交时 commitAsync 和 commitSync 怎么配合？

- `commitAsync` 不阻塞、吞吐高，但失败时回调里的异常通常被忽略，可能丢位移；
- 正确姿势：**常规提交用 commitAsync，关闭/重平衡前用 commitSync 兜底一次**，确保最后一批位移落盘；或在回调里记录失败，关闭时同步重试。

## 七、总结

```
KafkaConsumer.poll(timeout)
  ├─ 协调：ensureCoordinatorReady → ensureActiveGroup（JoinGroup+SyncGroup，处理再平衡）
  ├─ 位移：updateFetchPositions（按 committed / auto.offset.reset 初始化）
  ├─ 拉取：Fetcher.fetchedRecords（取已完成响应）→ sendFetches（按节点发 FetchRequest）
  │        → client.poll 等待 → 反序列化 → 推进 position
  └─ 提交：enable.auto.commit 时提交"上一批"位移
```

面试答题框架：**poll 触发协调 → 拉取 → 推进位移 → 异步/自动提交**，再展开协调器、Fetcher、位移三张图，配合参数与重复消费的坑，就能从「会用 API」升级到「懂原理」。

配套阅读：[Kafka Producer 发送流程源码深度解析](https://jiweidong.github.io/) 中的生产者链路，生产 + 消费两条线合起来就是 Kafka 的完整数据通路。
