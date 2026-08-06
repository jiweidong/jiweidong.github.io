---
title: 【分布式理论】Raft 一致性算法深度解析：从 Leader 选举到日志复制的完整实现
date: 2026-08-06 08:00:00
tags:
  - Java
  - 分布式
  - 一致性
  - 面试
categories:
  - Java
  - 分布式
author: 东哥
---

# 【分布式理论】Raft 一致性算法深度解析：从 Leader 选举到日志复制的完整实现

## 面试官：讲讲 Raft 算法？它是怎么保证数据一致性的？

Raft 是一种**用于管理复制日志的分布式一致性算法**，由 Diego Ongaro 和 John Ousterhout 于 2014 年提出，设计目标是**比 Paxos 更容易理解和实现**。它解决的问题是：**在多副本组成的集群中，如何保证即使部分节点故障，集群依然能就某个状态达成一致，且数据不丢不错**。

目前业界大量中间件基于 Raft：**etcd、Consul、ZooKeeper（ZAB 类似思想）、Nacos、TiKV、CockroachDB、MongoDB 复制集**。理解了 Raft，就理解了分布式系统一致性的半壁江山。

Raft 把一致性问题拆解为三个相对独立的子问题：

1. **Leader 选举（Leader Election）**：集群中必须有且仅有一个 Leader，负责接收客户端请求。
2. **日志复制（Log Replication）**：Leader 把客户端操作追加到日志，并复制到所有 Follower，保证日志一致。
3. **安全性（Safety）**：选举约束 + 提交约束，保证「已提交的日志永不丢失」。

---

## 一、节点状态机：Leader / Follower / Candidate

Raft 集群中每个节点任意时刻处于三种状态之一：

| 状态 | 职责 | 转换条件 |
|------|------|---------|
| **Follower** | 被动接收 Leader 的日志复制和心跳；不主动发起请求 | 选举超时未收到心跳 → 变 Candidate |
| **Candidate** | 发起选举，拉票 | 获得多数票 → 变 Leader；超时/发现更高任期 → 回 Follower |
| **Leader** | 接收客户端写请求，负责日志复制、提交、心跳 | 发现更高任期 → 自动降级为 Follower |

**任期（Term）** 是 Raft 的灵魂概念：时间被划分为一个个递增的任期编号，每次选举对应一个任期。任期就像「朝代」，**节点之间通过任期号比较判断谁是「合法政权」**——谁的任期号大，谁的命令优先，这从根本上避免了「旧 Leader 复活后发号施令」的脑裂问题。

```
Term 1         Term 2           Term 3
|----选举----|----稳定运行----|----选举----|
Follower→Candidate→Leader   Leader→宕机   Follower→Candidate→Leader
```

### Raft 中的随机超时（选举核心机制）

每个 Follower 有一个随机的选举超时时间（通常 150ms~300ms）：

- Follower 持续收到 Leader 的心跳（心跳间隔通常远小于超时时间，如 50ms），就保持 Follower。
- 如果超时时间内没收到心跳，Follower 认为 Leader 可能挂了，**任期 +1，变成 Candidate，给自己投票并发起选举**。
- 随机超时的意义：**避免多个 Follower 同时超时变成 Candidate，导致选票分裂**。随机化让一个节点大概率先超时，率先拉票成功。

---

## 二、Leader 选举：RequestVote RPC 详解

### 选举流程（五步）

```text
1. Follower 选举超时 → 任期 +1，变为 Candidate
2. Candidate 给自己投票（prevote：先确认自己是合法候选人）
3. 并行向所有其他节点发送 RequestVote RPC（携带任期、候选人的最后日志索引/任期）
4. 收集响应：
   - 收到大多数节点（N/2+1）的投票 → 成为 Leader
   - 收到更高任期的响应 → 降级为 Follower
   - 超时未决出 → 任期 +1 重新选举
5. 成为 Leader 后，立即开始发送心跳（AppendEntries）确立权威
```

### 投票的三大约束（安全性关键）

1. **一个任期一个节点只能投一票**：防止同一任期选出两个 Leader。
2. **候选人的日志必须「足够新」才能获得投票**（投票者会比较候选人与自己的日志）：`lastLogTerm` 更大者更新；若任期相同，`lastLogIndex` 更大者更新。**这保证新 Leader 一定拥有所有已提交的日志**——已提交的数据不会丢。
3. **多数派投票**：Candidate 必须获得超过半数的投票才能当选。任意两个多数派必有交集，因此**不可能同时存在两个合法 Leader**，从根上杜绝脑裂。

### 为什么说「多数派」是 Raft 一致性的根基？

假设 5 节点集群，任一时刻最多只有一个节点故障（5 个中至少 3 个存活）。多数派 = 3。任何两个多数派集合的交集 ≥ 1 个节点：

- 选举时的多数派与上一任 Leader 提交时的多数派**必有交集**。
- 交集中的节点一定带有已提交日志，且新 Leader 日志足够新 → **已提交的日志一定在新 Leader 上**。

这就是 Raft 安全性证明的核心：**多数派交集 + 日志新旧比较**。

---

## 三、日志复制：AppendEntries RPC 详解

### 日志结构

Raft 把客户端操作包装成**日志条目（Log Entry）**，每条包含：

- **index**：日志索引（单调递增）
- **term**：条目创建时的任期
- **command**：客户端操作（如 `set key=value`）

```
     index:   1        2        3        4
            +--------+--------+--------+--------+
            | term 1 | term 1 | term 2 | term 2 |
            | cmd A  | cmd B  | cmd C  | cmd D  |
            +--------+--------+--------+--------+
```

### 复制流程（三步）

```text
1. 客户端写请求发给 Leader
2. Leader 追加日志到本地，然后并行向所有 Follower 发送 AppendEntries RPC
3. 当 Leader 确认「大多数节点已持久化该日志」→ 该日志被标记为已提交（committed）
4. Leader 将提交结果返回客户端，并在下次心跳中通知 Follower 提交
```

### 日志一致性检查（Raft 的精妙之处）

Leader 在 AppendEntries RPC 中携带 **prevLogIndex 和 prevLogTerm**（前一条日志的索引和任期）：

- Follower 检查自己 `prevLogIndex` 位置的日志是否与 `prevLogTerm` 匹配。
- **匹配** → 追加新日志，返回成功。
- **不匹配** → 拒绝该 RPC，返回失败。Leader 将 `prevLogIndex` 向前递减重试，直到找到双方一致的日志位置，然后**删除 Follower 上冲突的日志，用 Leader 的日志覆盖**。

```java
// 简化版：Leader 处理日志不一致（伪代码）
int nextIndex = followerNextIndex[followerId];  // 每个 Follower 维护的期望索引
while (true) {
    AppendEntries args = new AppendEntries(
        prevLogIndex = nextIndex - 1,
        prevLogTerm  = log[nextIndex - 1].term,
        entries      = log[nextIndex..]);
    if (follower.appendEntries(args)) {
        followerNextIndex[followerId] = nextIndex + entries.size();
        break;
    }
    nextIndex--;  // 不匹配则回退，继续尝试
}
```

**关键结论**：Raft 的日志一致性规则是「**以 Leader 的日志为准**」，Follower 的日志会被 Leader 强制覆盖对齐。这也是 Raft 比 Paxos 易于实现的重要原因——冲突处理策略简单粗暴且正确。

---

## 四、脑裂场景推演：Raft 如何兜底

场景：5 节点集群（A、B、C、D、E），网络分区为 {A, B} 和 {C, D, E}。

1. 原 Leader A 被孤立在 {A, B} 分区，收不到多数派（需要 3 票），**无法提交新日志**，客户端写入失败——保证一致性优先于可用性。
2. 大分区 {C, D, E} 有 3 个节点（多数派），C 当选新 Leader，任期 +1，正常处理写入。
3. 网络恢复后：**旧 Leader A 发现新 Leader 的任期更大，自动降级为 Follower**，并同步新 Leader 的日志，丢弃自己未提交的日志。

**结论**：Raft 通过「任期号比较 + 多数派选举」，保证网络分区时**最多只有一个分区能形成合法 Leader**，且旧 Leader 复活后自动臣服——脑裂被从算法层面杜绝。

---

## 五、Raft 的工程化细节（进阶加分项）

### 1. Pre-Vote（预投票）

真实场景中，网络分区恢复后，被孤立节点任期号可能膨胀得很大（不断超时+1），回归集群时会把集群任期「污染」到高任期导致 Leader 下台。**Pre-Vote** 机制：Candidate 先发起一轮「预投票」，只有获得多数派认可才真正进入选举，避免任期异常膨胀。

### 2. 日志压缩（Snapshot）

日志无限增长会撑爆磁盘，Raft 支持**快照（Snapshot）**：把某个时刻的状态打快照，丢弃之前日志。Follower 落后太多时，Leader 直接发快照让它快速追赶，而不是逐条补日志。

### 3. 集群成员变更（Joint Consensus）

动态增删节点时，直接切换配置可能导致双 Leader（旧配置多数派 vs 新配置多数派无交集）。Raft 采用**联合共识（Joint Consensus）**：过渡期同时按新旧配置双多数派提交，安全完成成员变更。

### 4. 读请求优化

- **线性一致读（强一致）**：读也走 Leader，且 Leader 需确认自己仍是 Leader（发心跳验证），保证读到已提交的最新数据。
- **ReadIndex**：Leader 记录当前 commitIndex，发心跳确认权威后，等本地应用到该索引再返回——比日志复制读快。
- **Lease Read（租约读）**：Leader 在租约期内（约等于心跳间隔）默认自己仍是 Leader，直接本地读，延迟最低（etcd 默认启用）。

---

## 六、Raft vs Paxos vs ZAB

| 对比项 | Paxos | Raft | ZAB |
|--------|-------|------|-----|
| 核心思想 | Multi-Paxos 松散定义，无强 Leader 概念 | 强 Leader + 任期 + 日志复制 | 类似 Raft，强 Leader + 事务编号（zxid） |
| 易理解性 | 难（论文晦涩） | 易（为教学而生） | 中 |
| 日志顺序 | 不严格保证 | 严格按 index 顺序 | 全局严格顺序（zxid 单调） |
| 代表实现 | Google Chubby | etcd、Consul、Nacos | ZooKeeper |
| 适用 | 理论研究、老系统 | 现代新系统首选 | ZooKeeper 生态 |

**面试回答模板**：「Raft 通过三个子问题解决一致性：随机超时 + 多数派选举选出唯一 Leader；Leader 以自身日志为准强制复制对齐；任期机制 + 日志新旧比较保证已提交日志永不丢失。核心安全性依赖多数派交集定理，因此集群节点数必须是奇数，且容忍故障数为 (N-1)/2。」

---

## 面试追问清单

1. **Raft 选举为什么要随机超时？** → 避免选票分裂，保证快速收敛。
2. **为什么集群建议奇数个节点？** → 多数派 = N/2+1，5 节点容忍 2 故障，4 节点也只容忍 1 故障，偶数节点浪费资源。
3. **旧 Leader 网络恢复后会怎样？** → 发现更高任期 → 自动降级 Follower → 以新 Leader 日志为准同步。
4. **Raft 能保证线性一致性吗？** → 可以（读写都走 Leader + ReadIndex/Lease），etcd 默认提供线性一致读。
5. **Raft 与分布式事务有什么关系？** → Raft 解决的是副本间一致（状态机复制），分布式事务（2PC/Seata）解决的是多资源原子提交，两者层级不同、常配合使用。

Raft 是现代分布式系统的「基础设施级」算法，面试中几乎是分布式方向的必考点。掌握选举、日志复制、安全性三条主线，再结合 etcd/Nacos 的实际使用场景，就能从「背概念」升级到「讲原理」。
