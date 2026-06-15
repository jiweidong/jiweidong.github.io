---
title: 分布式系统 CAP 理论与一致性协议详解
date: 2026-06-15 11:30:00
tags:
  - 分布式
  - CAP
  - 一致性
  - Paxos
  - Raft
categories:
  - 架构
author: 东哥
---

# 分布式系统 CAP 理论与一致性协议详解

> 分布式系统的复杂性和魅力源于一个核心矛盾：网络不可靠。本文从 CAP 定理出发，深入剖析分布式一致性协议（Paxos、Raft、ZAB、Gossip）的核心思想，以及它们在实际系统中的工程实现。

## 一、CAP 定理

### 1.1 什么是 CAP

CAP 定理指出：一个分布式系统最多只能同时满足以下三个特性中的两个：

- **C（Consistency）**：一致性，所有节点在同一时刻看到的数据相同
- **A（Availability）**：可用性，每个请求都能获得一个回应（非错误）
- **P（Partition Tolerance）**：分区容错性，系统能容忍网络分区

```
         一致性
          /\
         /  \
        /    \
       /      \
      /   CP   \
     /    AP    \
    /____________\
 可用性          分区容错
```

### 1.2 网络分区发生时必须做出的选择

当网络分区发生时（P 是必选的分布式场景），只能在 C 和 A 之间二选一：

```
节点A ←→ 节点B  (网络断开)
    │           │
  请求1        请求2

CP 系统（放弃可用性）：
  - 请求1 成功，请求2 返回错误/超时
  - 保证数据一致，但部分节点不可用
  - 例子：ZooKeeper、etcd、HBase

AP 系统（放弃一致性）：
  - 请求1 成功，请求2 也成功（可能读取到旧数据）
  - 保证所有节点可用，但数据可能不一致
  - 例子：Eureka、Cassandra、DNS
```

### 1.3 CAP 的工程实践

```java
// CP 系统：ZooKeeper（强一致性）
// 写操作需要多数节点确认才返回成功
client.setData("/config", data, -1);
// 写成功 = 所有节点都已经更新

// AP 系统：Eureka（最终一致性）
// 写操作只要本地成功就返回
serviceInstance.setStatus("DOWN");
// 写成功 = 本地更新，其他节点通过心跳同步

// 大多数系统选择 AP + 最终一致性
// 因为网络分区是常态，而数据最终会一致
```

## 二、一致性模型

### 2.1 一致性级别

| 模型 | 说明 | 例子 |
|------|------|------|
| 强一致性 | 写后立即能读到最新数据 | 单机数据库 |
| 最终一致性 | 经过一段时间后数据会一致 | DNS、CDN |
| 因果一致性 | 有因果关系的操作有序 | 分布式日志 |
| 读写一致性 | 自己总能读到自己的写 | Session 粘性 |
| 单调读 | 不会读到更旧的数据 | 缓存设计 |
| 单调写 | 写操作有序执行 | 消息队列 |

### 2.2 BASE 理论

BASE 是对 CAP 中 AP 方案的补充：

- **BA**（Basically Available）：基本可用
- **S**（Soft State）：软状态，允许中间状态
- **E**（Eventually Consistent）：最终一致性

```yaml
# BASE 设计思想
1. 允许短暂的不一致
2. 通过补偿机制达到最终一致
3. 优先保证可用性
```

## 三、Paxos 协议

### 3.1 核心思想

Paxos 是 Leslie Lamport 提出的一致性算法，核心思想是"多数派"：

- 一个值只有被多数节点接受后才算最终确定
- 通过两阶段提交（Prepare → Accept）达成共识

### 3.2 角色定义

```
┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐
│Proposer│  │Proposer│  │Acceptor│  │Acceptor│
│ (提议者)│  │ (提议者)│  │ (接受者)│  │ (接受者)│
└───┬──┘  └───┬──┘  └───┬──┘  └───┬──┘
    │          │          │          │
    │  Phase 1: Prepare   │          │
    ├───────────────────────────────┤
    │  Prepare(n)          │        │
    ├─────────────────────────────────┤
    │          │  Promise(n, v) │    │
    │          │                     │
    │  Phase 2: Accept                │
    ├─────────────────────────────────┤
    │  Accept(n, v)          │        │
    └───────────────────────────────────┘
```

**详细过程：**

```
Phase 1: Prepare
  1. Proposer 选择一个提案编号 n
  2. 向所有 Acceptor 发送 Prepare(n) 请求
  3. Acceptor 收到 Prepare(n)：
     - 如果 n > 已经承诺的最大编号，返回 Promise
     - 同时返回已经接受的最大编号的提案值（如果有）
     
Phase 2: Accept
  1. Proposer 收到多数 Acceptor 的 Promise 后
  2. 从响应中选择编号最大的提案值 v（否则使用自己的值）
  3. 向所有 Acceptor 发送 Accept(n, v)
  4. Acceptor 收到 Accept(n, v)：
     - 如果没有承诺过更大的编号，接受该提案
```

### 3.3 Multi-Paxos

Basic Paxos 每次共识需要两轮 RTT，效率较低。Multi-Paxos 通过选出一个 Leader 来优化：

```
1. 选出一个稳定的 Leader
2. 只有 Leader 可以发起提案
3. Leader 跳过 Prepare 阶段，直接 Accept
4. 将共识过程简化为 Log Replication

这样，正常运行时只需一轮 RTT 就能达成共识
```

## 四、Raft 协议

### 4.1 Raft 的设计目标

Raft 是更易于理解的一致性算法，将问题拆解为三个子问题：

```
1. Leader Election（领导选举）
2. Log Replication（日志复制）
3. Safety（安全性）
```

### 4.2 节点状态

```
┌──────────────┐
│   Follower    │   ← 超时触发选举
│  (从节点)    │
└──────┬───────┘
       │
       │ 收到多数投票
       ▼
┌──────────────┐
│   Candidate   │   ← 成为 Leader
│  (候选者)    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│    Leader    │
│  (领导者)    │
└──────┬───────┘
       │
       │ 发现更高 term
       ▼
┌──────────────┐
│   Follower    │
│  (从节点)    │
└──────────────┘
```

### 4.3 领导选举

```text
选举过程：
1. Follower 在选举超时内未收到心跳
   （随机 150-300ms，避免同时发起选举）
2. Follower 变为 Candidate
3. Candidate：
   - term +1
   - 投票给自己
   - 向其他节点发起 RequestVote RPC
4. 收到多数投票 → 成为 Leader
5. 开始发送心跳（AppendEntries）维持领导地位

任期（Term）：
- 每个 term 最多有一个 Leader
- term 是单调递增的逻辑时钟
- 用于检测过期的 Leader
```

### 4.4 日志复制

```text
Leader 接收客户端请求时的过程：

1. Leader 追加日志到本地
2. 并行向所有 Follower 发送 AppendEntries RPC
3. 等待多数节点确认写入
4. 确认后提交（commit），应用到状态机
5. 通知 Follower 该日志已提交

日志条目结构：
┌──────┬──────┬──────┬──────┬──────┐
│term:1│term:1│term:2│term:3│term:3│
│op:x  │op:y  │op:z  │op:w  │op:q  │  ← 已提交
└──────┴──────┴──────┴──────┴──────┘
                 ↑
            commitIndex
```

### 4.5 Raft 安全性保证

```
五大安全保证：
1. 选举安全：一个 term 内最多一个 Leader
2. Leader Append-Only：Leader 不删除自己的日志
3. Log Matching：两个日志相同 index 和 term → 内容相同
4. Leader Completeness：已提交的日志必定在 next Leader 中
5. State Machine Safety：状态机按序应用日志
```

## 五、ZAB 协议（ZooKeeper）

### 5.1 ZAB 设计目标

ZAB（ZooKeeper Atomic Broadcast）是 ZooKeeper 使用的一致性协议：

```
核心流程：
1. 发现（Leader Election）
   - 选出新的 Leader
   - 同步未提交的事务
   
2. 同步（Recovery）
   - Leader 和 Follower 同步数据
   - 保证所有节点的数据一致
   
3. 广播（Atomic Broadcast）
   - Leader 处理写请求
   - 通过两阶段提交广播到所有节点
```

### 5.2 写流程

```text
Client → 任一 Server
   ↓ (非Leader则转发)
Leader Server
   ↓ (Proposal)
所有 Follower
   ↓ (ACK)
Leader 收到多数 ACK
   ↓ (Commit)
所有节点提交事务
   ↓
返回客户端成功
```

## 六、Gossip 协议

### 6.1 核心思想

Gossip 协议用于最终一致性系统，像病毒传播一样扩散信息：

```text
每个周期：
  1. 节点A 随机选择 B
  2. 交换彼此的数据（状态信息）
  3. 合并更新

三种传播模式：
- Push: A 把数据推给 B
- Pull: A 从 B 拉取数据
- Push-Pull: 双向交换（最常用）
```

### 6.2 应用场景

```java
// Gossip 在 Cassandra 中的应用
// 每个节点每秒和 1-3 个节点交换信息

// 节点状态信息
class NodeState {
    String nodeId;
    long heartbeat;      // 心跳计数
    String status;       // UP/DOWN
    // map<nodeId, (heartbeat, version)>
    Map<String, VersionedValue> states;
}

// Gossip 交换
void doGossip() {
    Node target = pickRandomNode();
    // Push: 发送自己的状态
    target.receiveState(myState);
    // Pull: 接收对方的状态
    Map<String, VersionedValue> remote = target.sendState();
    // 合并
    merge(remote);
}
```

**特性：**
- 最终收敛：经过 O(logN) 轮后所有节点状态一致
- 容错性高：部分节点失败不影响整体
- 去中心化：没有单点瓶颈
- 带宽友好：每个节点只和少数节点通信

## 七、工程实践对比

### 7.1 一致性协议对比

| 协议 | 一致性 | 性能 | 复杂度 | 实现系统 |
|------|--------|------|--------|----------|
| 2PC | 强一致 | 低 | 低 | 分布式事务 |
| 3PC | 强一致 | 低 | 中 | 较少使用 |
| Paxos | 强一致 | 中 | 极高 | Chubby |
| Raft | 强一致 | 中 | 中等 | etcd、Kudu |
| ZAB | 强一致 | 中 | 中等 | ZooKeeper |
| Gossip | 最终一致 | 高 | 低 | Cassandra、Consul |

### 7.2 分布式系统选型建议

| 场景 | 推荐系统 | 理由 |
|------|----------|------|
| 配置中心、服务发现 | etcd / ZooKeeper | 强一致，CP |
| 服务注册（高可用优先） | Eureka / Consul | AP，容忍分区 |
| 消息队列 | Kafka / Pulsar | 分区有序，高吞吐 |
| 数据库 | TiDB / CockroachDB | 分布式 SQL，强一致 |
| KV 存储 | Redis Cluster / etcd | 低延迟，高可用 |
| 对象存储 | MinIO / Ceph | 高容量，扩展性好 |

## 八、总结

分布式一致性是分布式系统中最核心也最困难的部分：

1. **CAP 定理**是分布式系统无法回避的约束，理解它是理解分布式系统的起点
2. **Raft 是学习一致性算法的最佳入口**，比 Paxos 更易于理解和实现
3. **实际系统根据场景选择一致性级别**，不需要所有操作都做强一致
4. **没有银弹**，每种协议都有其适用场景和权衡

学习建议：先理解 Raft 协议（MIT 6.824 课程非常好），再深入 Paxos。在实际工作中，多数时候你不需要实现一致性算法，但理解它们能帮你更好地使用 etcd、ZooKeeper 等基础设施。
