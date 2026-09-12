---
title: 【分布式理论】Paxos 算法深度解析：从 Basic Paxos 到 Multi-Paxos 与工程落地
date: 2026-09-12 08:00:00
tags:
  - 分布式
  - 共识算法
  - 面试
categories:
  - Java
  - 分布式
author: 东哥
---

# 【分布式理论】Paxos 算法深度解析：从 Basic Paxos 到 Multi-Paxos 与工程落地

## 面试官：Raft 你讲得挺清楚，那 Paxos 呢？Paxos 和 Raft 什么关系？

这是分布式面试的一道分水岭。Raft 因为「可理解性优先」的设计，资料多、好讲；而 Paxos 因为论文过于抽象，很多人只能背出「两阶段、Proposer、Acceptor」几个名词。

但只要你能说清 Paxos 要解决什么问题、两阶段到底在防什么、以及它和 Raft 的本质差异，这道题就是加分项。这篇我们从问题出发，把 Basic Paxos、Multi-Paxos 和工程落地一次讲透。

## 一、Paxos 要解决什么问题

分布式系统里有一个基本需求：**让多个节点对某个值达成一致（consensus），即使有节点宕机、网络分区、消息延迟或重复。**

约束条件是：

- 节点可能崩溃（**非拜占庭**：节点不会撒谎，只会沉默）；
- 消息可能丢失、延迟、重复，但不会被篡改；
- 网络是异步的（没有可靠的超时上界）。

理论上有个著名的结论 —— **FLP 不可能定理**：在完全异步的网络中，只要有一个节点可能崩溃，就不存在**既保证安全性又保证活性**的确定性共识算法。

Paxos 的应对方式是：**放弃「一定能在有限时间内达成共识」的强保证，但保证「绝不产生错误结果（安全）」，并通过随机化/超时重试在实践中逼近活性。**

想清楚这一点，就理解了 Paxos 的设计哲学：**Safety first，Liveness best-effort。**

## 二、三个角色

Paxos 把参与者抽象成三个角色（同一个节点可以同时扮演多个角色）：

| 角色 | 职责 |
| --- | --- |
| **Proposer** | 提出提案（proposal，形如 `<编号 n, 值 v>`），推动达成共识 |
| **Acceptor** | 对提案投票（accept/reject），是共识的**核心存储者** |
| **Learner** | 学习已达成共识的值，对外提供查询 |

关键点：**共识只由 Acceptor 的多数派（quorum）决定**。通常取 `⌊N/2⌋ + 1`。任意两个多数派必然相交，这是 Paxos 安全性的数学基础。

## 三、Basic Paxos：两阶段

Basic Paxos 解决的是「对**单个**值达成共识」。它有两个阶段、四个动作。

### 阶段一：Prepare / Promise

1. **Proposer** 选择一个全局唯一且递增的提案编号 `n`，向所有 Acceptor 发送 `Prepare(n)`。
2. **Acceptor** 收到 `Prepare(n)` 后：
   - 如果 `n` 大于它已响应过的任何 Prepare 编号 → **承诺（Promise）**：不再接受编号 `< n` 的提案，并返回**已经接受过的最大编号提案**（如果有）；
   - 否则 → 拒绝（或忽略）。
3. **Proposer** 收到**多数派**的 Promise 后，进入阶段二。

### 阶段二：Accept / Accepted

4. **Proposer** 决定要提案的值 `v`：
   - 如果所有 Promise 中**没有**任何已接受的提案 → 可以自由选择 `v`（用自己想提的值）；
   - 如果有 → **必须选择其中编号最大的那个已接受提案的值**（这条规则是 Paxos 安全性的灵魂）。
5. **Proposer** 发送 `Accept(n, v)` 给所有 Acceptor。
6. **Acceptor** 收到 `Accept(n, v)` 后：
   - 如果它**没有承诺过更大的编号** → 接受该提案，持久化 `(n, v)`，返回 Accepted；
   - 否则拒绝。
7. **Proposer** 收到多数派 Accepted → **共识达成**，值 `v` 被选定。它通知所有 Learner。

### 为什么必须「选择编号最大的已接受值」？

这是 Paxos 最反直觉、也最精妙的地方。假设没有这条规则：

- 提案 `(1, X)` 已在部分 Acceptor 上被接受，但没达成多数派；
- 另一个 Proposer 用编号 `2` 提出值 `Y`，被选定了；
- 此时值 `X` 的痕迹还在某些 Acceptor 上 —— 一旦网络恢复、有人再用 `(3, X)` 推进，就可能出现「已经选定的值被改写」。

「选择编号最大的已接受值」这条规则保证了：**一旦某个值在任何 Acceptor 上被接受过，后续所有更高编号的提案都必须携带同一个值**，于是已选定的值不可能被覆盖。这就是 Paxos 安全性的完整证明思路。

### 活锁问题

考虑两个 Proposer 交替用更高编号抢占：

- P1 提 `Prepare(1)`，P2 提 `Prepare(2)`，P1 的 Accept 被拒；
- P1 提 `Prepare(3)`，P2 的 Accept 被拒，P2 提 `Prepare(4)` ……

**永远无法达成共识**。解决方案：**随机化退避**（每个 Proposer 随机等待一段时间再重试），以及**选出一个 Leader 串行提案**（这就是 Multi-Paxos 的核心思想）。

## 四、Multi-Paxos：从「一个值」到「一串值」

Basic Paxos 只能对一个值达成共识，但真实系统需要的是**一份持续增长的日志（log）**：每个日志槽位（slot / index）都要确定一个值。

最简单的做法：**对每一个日志项都跑一遍完整的 Basic Paxos**。问题显而易见 —— 每写一条日志要 2 次 RPC 往返，性能无法忍受。

Multi-Paxos 的优化：

1. **选出一个 Leader（稳定的 Proposer）**。Leader 通过一次 Basic Paxos（或 Raft 风格的选举）产生；
2. Leader 对后续所有日志项**复用阶段一**：一次 `Prepare` 拿到多数派的 Promise 后，**不再需要重复 Prepare**，直接对每条日志发 `Accept(n, i, v)`（`i` 是日志索引）；
3. Acceptor 只需保证「不再接受更高编号的 Prepare」，从而对 Leader 的 Accept 一路放行。

于是每条日志的提交从「2 次往返」降到 **1 次往返**（批量提交还能进一步摊薄），这就是 Multi-Paxos 在生产中可用的关键。

### 日志空洞（Gap）问题

Multi-Paxos 允许并发提交多条日志，于是可能产生「第 3 条已提交、第 2 条还没定」的**空洞**。解决方案有：

- **限制 Leader 串行提交**（简单但吞吐低）；
- **允许空洞，由 Leader 填补**（需要额外的「填洞」机制，Chubby 就是这种模式）；
- 让日志按索引顺序提交（Raft 的做法，用严格顺序规避了空洞问题）。

## 五、Paxos vs Raft：一张表说清

| 维度 | Paxos / Multi-Paxos | Raft |
| --- | --- | --- |
| 设计目标 | 通用共识问题，理论最优 | 可理解性优先 |
| 日志连续性 | 允许空洞，需要额外机制 | **强 Leader + 日志连续**，不允许空洞 |
| Leader 选举 | 无规定，由实现自行决定（常复用 Paxos） | 明确写进算法（任期 + 多数票） |
| 提案编号 | 全局递增编号 | 任期号（term） |
| 成员变更 | 论文未定义，实现各异 | 单节点变更，规则明确 |
| 状态机复制 | 需要自己拼装 | 论文直接给出完整方案 |
| 论文难度 | 极高（Lamport 的希腊神话） | 低（大量图示与步骤） |
| 典型实现 | Chubby、ZooKeeper（ZAB 是其变体）、Spanner | etcd、Consul、TiKV、Kafka KRaft |
| 关系 | Raft 可视为 「Multi-Paxos 的一个工程化特化」 | —— |

**面试标准答案**：二者解决同一个问题（非拜占庭环境下的共识/状态机复制），安全性等价；Raft 通过强制 Leader 唯一性、日志连续、任期号、明确成员变更规则，把 Paxos 中「留给实现自由发挥」的部分全部规定下来，从而更易理解、更易工程实现。**可以认为 Raft 是 Multi-Paxos 的一种简化与形式化。**

## 六、工程落地：谁在用 Paxos

| 系统 | 算法 | 说明 |
| --- | --- | --- |
| Google Chubby | Multi-Paxos | 粗粒度分布式锁服务，内部维护日志 + 快照 |
| ZooKeeper | ZAB | Zab 是 Paxos 家族成员，专为「主备 + 广播」设计 |
| Spanner | Multi-Paxos + TrueTime | Paxos 组管理数据分片，TrueTime 解决全局时钟 |
| MySQL MGR | Paxos 变体 | 组复制用 Paxos 保证事务日志在多数派上一致 |
| etcd / TiKV | Raft | 选择了 Raft 路线 |
| Kafka KRaft | Raft 变体 | 元数据管理从 ZooKeeper 迁到内置 Raft |

可以看到一个现实规律：**理论优越的 Paxos 在落地数量上输给了 Raft** —— 因为工程复杂度才是真正的成本。

## 七、Paxos 的变体家族

- **Multi-Paxos**：批量日志，生产标配；
- **Fast Paxos**：跳过阶段一，由 Acceptor 直接发起 Accept，把延迟从 2 轮降到 1 轮，但需要更多 Acceptor（quorum 变大），只在特定场景可用；
- **Cheap Paxos**：减少所需节点数，用「替补 Acceptor」补足 quorum；
- **EPaxos (Egalitarian Paxos)**：无 Leader，任何节点可提案，适合多地域低延迟场景，但冲突调和复杂；
- **Flexible Paxos**：放宽「阶段一与阶段二必须用同一 quorum」的约束，提升可用性；
- **ZAB / Raft**：Paxos 的工程特化变体。

## 八、用 Java 理解核心逻辑（极简伪代码）

下面这段代码不可用于生产，但能帮你把两阶段的判断条件具象化：

```java
public class Acceptor {
    private long promisedId = -1;        // 已承诺过的最大提案编号
    private long acceptedId = -1;        // 已接受的最大提案编号
    private Object acceptedValue = null; // 已接受的值

    // 阶段一：Prepare
    public synchronized PromiseInfo prepare(long proposalId) {
        if (proposalId <= promisedId) {
            return PromiseInfo.reject(promisedId);   // 已有更大的承诺
        }
        promisedId = proposalId;                     // 承诺不再接受更小编号
        // 必须返回已接受的最大编号提案，供 Proposer 复用其值
        return PromiseInfo.promise(acceptedId, acceptedValue);
    }

    // 阶段二：Accept
    public synchronized boolean accept(long proposalId, Object value) {
        if (proposalId < promisedId) {
            return false;                            // 违反承诺，拒绝
        }
        promisedId = proposalId;
        acceptedId = proposalId;
        acceptedValue = value;                       // 关键：持久化！
        return true;
    }
}

public class Proposer {
    private final List<Acceptor> acceptors;

    public Object propose(Object myValue) {
        long n = nextUniqueIncreasingId();           // 全局唯一且递增
        int quorum = acceptors.size() / 2 + 1;

        // 阶段一：收集 Promise
        List<PromiseInfo> promises = new ArrayList<>();
        for (Acceptor a : acceptors) {
            PromiseInfo p = a.prepare(n);
            if (p.isPromised()) promises.add(p);
        }
        if (promises.size() < quorum) {
            return null;                             // 未达多数派，退避重试（随机化！）
        }

        // 关键规则：若已有被接受的值，必须选编号最大的那个
        Object value = myValue;
        long maxAcceptedId = -1;
        for (PromiseInfo p : promises) {
            if (p.getAcceptedId() > maxAcceptedId) {
                maxAcceptedId = p.getAcceptedId();
                value = p.getAcceptedValue();
            }
        }

        // 阶段二：收集 Accept
        int accepted = 0;
        for (Acceptor a : acceptors) {
            if (a.accept(n, value)) accepted++;
        }
        return accepted >= quorum ? value : null;    // 达成共识
    }
}
```

> 三个必须记住的要点：
> ① `promisedId` 与 `acceptedId/value` **必须持久化到磁盘**（否则崩溃重启后可能违反承诺 → 破坏安全性）；
> ② 阶段一返回已被接受的值，阶段二**必须**沿用编号最大的那个值；
> ③ 失败要**随机化退避**，否则会活锁。

## 九、常见误区

**误区一：Paxos 保证一定能达成共识。**
不保证（FLP + 活锁）。Paxos 保证的是**安全性**，活性依赖随机化、超时和稳定的 Leader。

**误区二：Acceptor 接受提案就等于共识达成。**
不是。必须**多数派**接受才算选定。少数派接受的值随时可能被覆盖。

**误区三：Basic Paxos 足够用来做状态机复制。**
不够。状态机复制需要一串有序日志，必须用 Multi-Paxos 并解决空洞与 Leader 问题。

**误区四：Paxos 和 Raft 是两个不相关的东西。**
它们解决同一个问题、安全性等价，Raft 是 Paxos 的「可理解性特化」。面试时把关系讲清楚，比分别背两套名词更有说服力。

## 十、面试常见追问

**Q1：为什么 quorum 必须是多数派？**
因为任意两个多数派必有交集。如果两个提案分别被两个不相交的集合「选定」，就会出现两个不同的值同时被选定 —— 破坏唯一性。多数派交集正是 Paxos 安全证明的基石。

**Q2：Paxos 中的提案编号（proposal id）有什么要求？**
必须**全局唯一且全局递增**（实践常用「时间戳 + 节点 ID」或「任期号 + 计数器」）。它决定了「谁的话语权更大」，同时也是 Acceptor 拒绝旧提案的依据。

**Q3：Paxos 能容忍多少个节点故障？**
`2f + 1` 个节点可容忍 `f` 个故障。5 节点可容忍 2 个故障。这和非拜占庭容错的通用结论一致。

**Q4：Paxos 能防住恶意节点吗？**
不能。Paxos 假设非拜占庭（节点只会宕机不会撒谎）。防恶意节点需要 PBFT、PoW/PoS 等拜占庭容错算法。

**Q5：为什么 Kafka、etcd 都选了 Raft 而不是 Paxos？**
工程成本。Raft 有明确的状态机、任期、日志匹配性质、成员变更规则，实现和调试都简单得多；Multi-Paxos 的「空洞填补」「Leader 选举」「成员变更」都需要实现者自己设计，正确性验证成本极高。**在工程世界里，「能正确实现」比「理论最优」重要得多。**

**Q6：ZooKeeper 的 ZAB 和 Paxos 什么关系？**
ZAB 是 Paxos 家族的一个变体，专门为「主备模式 + 顺序广播（原子广播）」设计，增加了 `zxid`（事务 ID）保证顺序性，可以视为「为 ZooKeeper 场景定制过的 Multi-Paxos」。

## 十一、小结

| 要点 | 结论 |
| --- | --- |
| 解决的问题 | 非拜占庭环境下对单个值 / 日志序列达成共识 |
| 角色 | Proposer / Acceptor / Learner |
| Basic Paxos | 两阶段：Prepare-Promise + Accept-Accepted |
| 安全核心 | 多数派交集 + 「选编号最大的已接受值」 |
| 活性 | 靠随机化退避与稳定 Leader（无强保证） |
| 工程化 | Multi-Paxos（Leader 复用阶段一 + 日志 + 批量） |
| 与 Raft | 同问题、安全性等价，Raft 是工程特化 |
| 现实选择 | 理论研究多用 Paxos，工程落地多选 Raft |

一句话总结：**Paxos 是共识问题的最优解，Raft 是共识问题的最优工程实现。** 理解 Paxos 的价值不在于背下两阶段，而在于理解「多数派 + 编号约束」如何在没有全局时钟的分布式世界里，硬生生构造出一个不矛盾的一致性结论 —— 这份思想，才是它值得被记住的理由。
