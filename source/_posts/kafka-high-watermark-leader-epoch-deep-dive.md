---
title: 【Kafka 原理】Kafka 高水位与 Leader Epoch 深度解析：HW/LEO 推进机制、副本截断与消息可靠性实战
date: 2026-09-04 08:00:00
tags:
  - Kafka
  - 消息队列
  - 分布式
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Kafka 原理】Kafka 高水位与 Leader Epoch 深度解析：HW/LEO 推进机制、副本截断与消息可靠性实战

## 面试官：Kafka 里 LEO、HW 是什么？消费者为什么只能读到高水位以下的消息？

之前我们讲过 Kafka 的副本机制与 ISR（哪些副本跟得上 Leader）。今天往更底层挖一层：**副本之间是怎么"对齐"进度的？HW（高水位）和 LEO（日志末端偏移）是怎么推进的？为什么说"以 HW 为截断依据会丢数据"，Leader Epoch 又是怎么救场的？** 这几个问题几乎是 Kafka 原理面试的"天王山"，也是排查"消息读不到、副本不一致、重启丢数据"的必备知识。

---

## 一、四个核心概念先立住

以分区（Partition）为单位，每个副本对应一份日志（Log），日志由多个 Segment 组成：

| 概念 | 全称 | 含义 |
|---|---|---|
| LEO | Log End Offset | **日志末端偏移**：该副本下一条待写入消息的偏移量。现有最后一条消息 offset = LEO - 1 |
| HW | High Watermark | **高水位**：消费者**只能读到 HW 之前的消息**（offset < HW）。HW 之后的"未确认"消息对消费者不可见 |
| ISR | In-Sync Replicas | 与 Leader 保持同步的副本集合，只有 ISR 里的副本才有资格竞选 Leader |
| Leader Epoch | 领导者纪元 | 每个 Leader 任期一个递增的版本号，配套记录该任期第一条消息的起始偏移 |

一张图记住关系：

```
Replica 日志（offset 从小到大）:
0   1   2   3   4   5   6   7   8
|———已提交、消费者可见———|           <- HW = 5，消费者只能读到 [0, 5)
                          |————|    <- LEO = 7，下一条写入 offset = 7
```

**关键点：HW ≤ LEO。** HW 是"所有 ISR 副本都有的消息"的分界线，本质是**确认机制**——只有被足够多副本复制成功的消息，才允许消费者消费，防止 Leader 突然宕机后消息丢失导致消费者读到"幽灵数据"。

---

## 二、HW 与 LEO 的推进机制（重点）

副本间通过 **Fetch 请求**互相拉数据。以 Leader 和 Follower 为例，一轮完整的推进分四步：

### 2.1 Follower 侧：更新 LEO，上报

Follower 定期向 Leader 发 `FetchRequest`，里面带上自己当前的 LEO。Follower 收到 Leader 返回的数据后，先把消息写入本地日志，**更新自己的 LEO**。

### 2.2 Leader 侧：更新 Follower 的 LEO 与远程 HW

Leader 收到 FetchRequest 时，从请求里解析出 Follower 的 LEO，更新自己内存中维护的"该 Follower 的远端 LEO"。同时尝试推进 Leader 的 HW：

```
Leader HW = min(Leader LEO, 所有 ISR 副本的远端 LEO 中的最小值)
```

也就是说：**HW 取决于 ISR 里"最慢的那个副本"追到了哪里。**

### 2.3 Leader 侧：把 HW 放进 FetchResponse

Leader 计算完新 HW 后，把它放进 FetchResponse 返回给 Follower。

### 2.4 Follower 侧：更新自己的 HW

Follower 收到响应后，更新本地 HW：

```
Follower HW = min(Follower LEO, 响应里的 Leader HW)
```

注意 **HW 的更新是滞后的**：Follower 只有等下一轮 Fetch 才能拿到 Leader 的最新 HW。这就埋下了后面"HW 机制丢数据"的隐患。

### 2.5 一个完整例子

假设 ISR = {Leader, FollowerA}，初始 LEO 都是 5，HW = 5：

| 步骤 | 事件 | Leader LEO | FollowerA LEO | Leader HW |
|---|---|---|---|---|
| 1 | 生产者写入 offset 5、6 | 7 | 5 | 5 |
| 2 | FollowerA Fetch 拉走 5、6，本地 LEO → 7，上报 LEO=7 | 7 | 7 | **7**（Leader 侧推进） |
| 3 | Leader 把 HW=7 放响应里返回 | 7 | 7 | 7 |
| 4 | FollowerA 收到响应，本地 HW → 7 | 7 | 7 | 7（Follower 侧推进） |

**写总结：消息要经历"Leader 写入 → Follower 拉取并上报 → Leader 推进 HW → 广播 HW"整整两轮网络交互，才会对消费者可见。** 这也是 Kafka 不追求"写后立即读"强一致的原因——它是**最终一致 + 高吞吐**的典型。

---

## 三、日志截断（Truncation）：什么时候会发生？

副本宕机重启后，它的日志可能和 Leader 不一致，需要"回退"到某个一致点再重新同步：

**场景：Follower 落后 → 被踢出 ISR → 重启追数据时发现日志里有 Leader 没有的消息？**

不可能，Follower 只从 Leader 拉数据，日志是 Leader 日志的前缀，不会多出消息。真正需要截断的是另一种情况：

**场景：Follower 曾经是 Leader（或日志领先过），之后被降级。** 比如分区 Leader 在 FollowerA 上时写入了 offset 6、7（FollowerA 本地 LEO=8），随后 Leader 切换回原 Leader（LEO=6）。此时 FollowerA 日志比新 Leader **多**了 6、7 两条——这两条消息在新 Leader 上不存在，属于"孤儿数据"，必须**截断**掉再重新同步。

旧版 Kafka 的截断依据就是 **HW**：副本把自己日志截断到 HW 位置。听起来合理，但这里藏着一个著名的大坑。

---

## 四、经典 Bug：为什么"以 HW 为截断依据"会丢数据？

这是 Kafka 0.11 之前的老问题，也是面试官最爱深挖的点。构造一个丢数据场景：

**初始状态**：ISR = {A(Leader), B}，LEO_A = LEO_B = 10，HW = 10。A 宕机前只把 offset 10 的消息同步给了 B（B 的 LEO = 11），但 **A 还没来得及把 HW 推进并广播给 B**（HW 更新滞后！）。

**故障序列：**

1. A 宕机。此时 A 本地：LEO=11、HW=10（还没推进）。B 本地：LEO=11、HW=10（还没收到新 HW）。
2. B 被选为新 Leader。B 的 HW 还是 10，所以 **B 把本地 LEO=11 截断回 HW=10**，offset 10 那条消息被删掉。
3. 此时若 A 重启并作为 Follower 追 B 的数据——A 发现自己 LEO=11 > B 的 HW=10，**也把日志截断到 10**。
4. 结果：offset 10 的消息**彻底丢失**——它明明已经被写入了两个副本（A 和 B），按理说没丢，却因为"以 HW 为截断基准 + HW 推进滞后"被两边一起删掉了。

**根因**：HW 是"异步推进的、滞后的"水位线，拿一个**可能过期的值**去做**截断这种破坏性操作**的基准，必然存在竞态窗口。更糟的是，B 在截断时以为自己删的是"未确认数据"，实际上那条数据已经满足"写入 ISR 多数副本"的持久性要求了。

---

## 五、Leader Epoch：救火方案

Kafka 0.11 引入 **Leader Epoch** 解决上述问题。核心思想：不再拿"滞后的 HW"当截断基准，而是拿 **"Leader 任期起始偏移"** 当基准。

### 5.1 两个数据结构

每个副本的日志里维护一张 **LeaderEpochCache**（内存 + 定期刷盘），记录：

```
epoch(任期) -> startOffset(该任期第一条消息的 offset)
```

例如：

| Epoch | Start Offset | 说明 |
|---|---|---|
| 0 | 0 | 第一个 Leader（A）任期，从 0 开始 |
| 1 | 10 | A 宕机后 B 当选，B 从 offset 10 开始接收新消息 |

### 5.2 截断流程（新版）

Follower 重启追数据时，不再"截断到 HW"，而是向 Leader 发一个 **OffsetsForLeaderEpochRequest**，带上自己日志里**最新的 epoch**：

1. Follower 说："我日志里最新任期是 epoch 1，它的起始偏移是多少？"
2. Leader 查自己的 LeaderEpochCache，返回该 epoch 对应的 startOffset。
3. Follower 对比：如果自己日志中 epoch 1 的起始偏移 **大于** Leader 返回的值，说明自己多了一段"Leader 都没见过"的消息，**只截断到 Leader 给出的 startOffset**，而不是盲目截到 HW。

回到上面的丢数据场景：

- B 当选新 Leader 后，**先在自己的 LeaderEpochCache 里记录 epoch=1、startOffset=11**（B 的 LEO 是 11，不需要截断！）。旧逻辑里 B 会截断到 HW=10，新逻辑里 **B 不再截断**，offset 10 的消息保住了。
- A 重启后带着最新 epoch 0 来问 B，B 返回"epoch 1 的 startOffset = 11"，A 发现自己没有 epoch 1 的数据，把日志截断到 11 之前与 B 对齐即可，offset 10 仍在。

**Leader Epoch 的本质**：用"Leader 任期切换点"这种**单调递增、不会回退**的元数据，替代"可能滞后回退的 HW"作为截断基准。任期切换点一旦确定就不会变，所以不会出现"两边都截、把数据截没"的竞态。

### 5.3 Leader Epoch 还能防什么？

- **防止 Follower 截断过度**（上面的丢数据场景）；
- **防止"僵尸 Leader"复活后写入脏数据**：旧 Leader 网络分区后以为自己还是 Leader，继续接收写入；恢复后通过 epoch 对比发现自己的任期已过期，会截断掉分区期间写入的"伪 Leader 数据"再以 Follower 身份回归——这就是 **fencing（栅栏）机制**，类似分布式锁里的 fencing token。

---

## 六、HW 与可靠性参数的关系

| 参数 | 作用 | 与 HW 的关系 |
|---|---|---|
| `acks=0` | 发完即走 | 不等待任何确认，可能丢消息 |
| `acks=1` | Leader 写入成功即返回 | **Leader 还没把 HW 推给 Follower 就可能宕机**，消息可能丢失（HW 滞后窗口内） |
| `acks=all`（配合 `min.insync.replicas`） | ISR 全部（或至少 N 个）写入成功才返回 | 消息已进多个副本，但**消费者可见性仍要等 HW 推进**；宕机丢消息窗口大幅缩小 |
| `min.insync.replicas=2` | ISR 少于 2 时拒绝写入 | 保证"至少 2 个副本有数据"，是 acks=all 的黄金搭档 |
| `unclean.leader.election.enable=false` | 禁止非 ISR 副本竞选 Leader | 防止"落后太多的副本当选导致大量数据截断丢失" |

**面试追问：acks=all 是不是就绝对不丢消息了？**
不是。acks=all 只保证"消息写入了所有 ISR 副本"，但：① HW 推进滞后窗口内 Leader 宕机，极端场景仍可能丢（已由 Leader Epoch 大幅缓解）；② 若 ISR 只剩 Leader 一个副本（其他副本都挂了），acks=all 实际退化为 acks=1；③ 生产环境必须配 `min.insync.replicas` 防止 ISR 收缩到 1。**没有绝对的"不丢"，只有把丢失概率压到可接受范围。**

---

## 七、实战排查：怎么看 HW 是否异常？

### 7.1 用 kafka-log-dirs 工具看副本 LEO/HW

```bash
# 查看所有副本的 LEO 与 HW（新版命令）
kafka-log-dirs.sh --bootstrap-server broker:9092 \
  --topic-list my-topic --describe
```

关注点：某个副本的 LEO 长期落后于 Leader → 大概率被踢出 ISR，检查网络/磁盘/GC。

### 7.2 消费者 Lag 与 HW 的关系

消费者 Lag = **消费者当前 offset 与 HW（不是 LEO！）的差值**（旧版计算口径）。如果发现"生产端明明写入了，消费者就是读不到"，先查 **HW 是否没有推进**——常见原因：

- Follower 副本卡住（磁盘满、Full GC、网络分区），ISR 里最慢副本拖住 HW；
- 只有一个副本且写入量巨大，HW 推进依赖刷盘与 checkpoint 周期；
- 消费者使用 `read_uncommitted` 之外还有事务隔离问题（较少见）。

### 7.3 监控指标

| 指标 | 含义 |
|---|---|
| `KafkaServer:BrokerTopicMetrics:...` | 分区读写速率 |
| `kafka.log.Log:...:LogEndOffset` | 各副本 LEO |
| `kafka.server:ReplicaManager:...` | HW 相关指标 |
| ISR 收缩/扩张次数 | `IsrShrinksPerSec` / `IsrExpandsPerSec`，抖动说明副本不稳定 |

---

## 八、总结：面试速记卡

**Q1：LEO 和 HW 是什么？**
LEO 是副本日志末端偏移（下一条消息写哪）；HW 是"ISR 全员确认"的水位线，消费者只能读到 HW 以下。HW ≤ LEO，HW = min(Leader LEO, ISR 各副本远端 LEO)。

**Q2：HW 怎么推进？**
Follower 拉数据 → 更新本地 LEO → 上报给 Leader → Leader 取 ISR 最小 LEO 推进 HW → 随 FetchResponse 广播 → Follower 更新本地 HW。**两轮交互，天然滞后。**

**Q3：为什么旧版 HW 截断会丢数据？**
HW 滞后，宕机窗口内"已写入多副本但未推进 HW"的消息，会因新旧 Leader 都按过期 HW 截断而被双方删除。

**Q4：Leader Epoch 怎么解决？**
用"任期 → 起始偏移"的单调递增元数据当截断基准，Follower 通过 OffsetsForLeaderEpoch 请求对齐到 Leader 的任期起点，避免过度截断；同时 fencing 僵尸 Leader。

**Q5：生产如何配置可靠性？**
`acks=all` + `min.insync.replicas=2` + 关闭 unclean 选举 + 监控 ISR 抖动与 HW 推进。

一句话总结：**HW 是"确认线"（消费者可见性），LEO 是"进度线"（副本写入进度），Leader Epoch 是"任期保险丝"（截断与防僵尸 Leader 的安全基准）——三条线共同决定了 Kafka 分区副本的数据可靠性与一致性表现。**
