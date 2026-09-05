---
title: 【Kafka 原理】Kafka 3.x KRaft 模式深度解析：从 ZooKeeper 依赖到自我管理的元数据架构与迁移实战
date: 2026-09-05 08:00:00
tags:
  - Kafka
  - 消息队列
  - 架构
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Kafka 原理】Kafka 3.x KRaft 模式深度解析：从 ZooKeeper 依赖到自我管理的元数据架构与迁移实战

## 面试官：Kafka 的控制器（Controller）是干什么的？它现在还依赖 ZooKeeper 吗？

如果你还在回答"Kafka 用 ZooKeeper 做 Broker 注册、Topic 元数据存储、Controller 选举……"，那只能算答对了一半——**那是 2.x 时代的答案**。Kafka 3.3+ 已经支持 KRaft 模式（KIP-500），3.5 起 ZooKeeper 被标记为弃用，**Kafka 4.0（2025 年发布）已经彻底移除 ZooKeeper**。这个变化是 Kafka 近十年最大的一次架构革命，面试官现在最爱追问的就是它。

今天把 KRaft 一次讲透：为什么要去 ZooKeeper、KRaft 架构长什么样、元数据怎么同步、怎么部署和迁移、踩坑清单，一条龙。

## 一、为什么要干掉 ZooKeeper？先看 ZooKeeper 时代的痛点

### 1.1 传统架构：Broker + ZooKeeper 双组件

```
        ┌───────────────────────────────────┐
        │           ZooKeeper 集群           │
        │  /brokers/ids       Broker 注册    │
        │  /brokers/topics    Topic 元数据    │
        │  /controller        Controller 选举 │
        │  /isr_change_notification          │
        └──────▲───────────────▲────────────┘
               │               │
        ┌──────┴─────┐   ┌────┴──────┐
        │ Controller │   │  Broker   │
        │  (某个 Broker 兼任) │
        └────────────┘   └───────────┘
```

Controller（控制器）是 Kafka 集群的"大脑"，职责包括：分区 leader 选举、分区副本分配、ISR 变更通知、Broker 上下线处理等。传统架构里，Controller 本身是某个 Broker 兼任的，Controller 选举、元数据存储都依赖 ZooKeeper。

### 1.2 ZooKeeper 时代的四个核心痛点（面试要能说出来）

| 痛点 | 说明 |
|------|------|
| 运维两套系统 | 部署 Kafka 要额外部署和运维 ZK 集群，版本还得兼容（ZK 3.5+ 才能跑新 Kafka），故障域翻倍 |
| 元数据同步慢 | 所有元数据变更先写 ZK 再异步通知 Broker，**通知链路长、时序难保证**，分区多时 controller 容易成为瓶颈 |
| 脑裂与一致性风险 | ZK 本身的会话超时、旧 Controller 与新 Controller 的"僵尸"问题（fencing 机制复杂） |
| 扩展性受限 | 元数据全量放 ZK 节点，集群规模（几十万分区）时 ZK 成为天花板；ZK 不适合存大量频繁变更的数据 |

简单说：**Kafka 自己就是一个分布式系统，却把"大脑"外包给了另一个分布式系统**——两套一致性协议（Kafka 的 ISR + ZK 的 ZAB）、两套故障域、两套运维成本。

## 二、KRaft 架构：Kafka 自己管自己

KIP-500 的核心理念：**用 Kafka 自己的日志复制能力（基于 Raft 的 quorum 机制）来存储和同步元数据**，去掉 ZooKeeper。

### 2.1 角色划分：Controller 与 Broker 分离

KRaft 模式下节点分成两类角色：

```
              ┌────────────────────────────┐
              │   Controller Quorum (奇数)  │
              │  controller1 (leader)       │
              │  controller2 (follower)     │
              │  controller3 (follower)     │
              └──────────┬─────────────────┘
                         │ 元数据变更（Raft 复制）
        ┌────────────────┼────────────────┐
        │                │                │
   ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
   │ Broker1 │      │ Broker2 │      │ Broker3 │
   │ (active)│      │ (active)│      │ (active)│
   └─────────┘      └─────────┘      └─────────┘
```

- **Controller（控制器节点）**：专门负责集群管理——处理 Broker 注册、Topic 创建/删除、分区 leader 选举、ISR 管理等。Controller 之间组成一个 **quorum（法定人数）**，用 **Raft 协议**选出一个 Active Controller（leader），其余是备用（follower/standby）。
- **Broker（数据节点）**：只负责读写数据。每个 Broker 会从 Controller 拉取元数据并**缓存到本地**，客户端请求 Broker 时 Broker 直接用本地缓存应答，不再像以前那样间接依赖 ZK。

关键点：**Controller 和 Broker 可以是同一批进程**（combined 模式，小集群常见），也可以分开部署（专用 Controller 节点，大集群推荐）。

### 2.2 元数据到底存哪？——__cluster_metadata 主题

KRaft 把元数据当成**一个内部主题 `__cluster_metadata`（单分区、高副本）**来存储！所有元数据变更（Broker 上下线、Topic 增删、分区分配、配置变更、配额变更…）都是一条条**追加日志记录**，在 Controller quorum 之间通过 Raft 复制。

```
__cluster_metadata 主题（单分区）
┌─────────────────────────────────────────┐
│ Record 1: RegisterBroker(broker-1)      │
│ Record 2: CreateTopic(topic-a, 3 分区)   │
│ Record 3: PartitionLeaderChange(...)     │
│ Record 4: UpdateConfig(log.retention)    │
│ ...                                      │
└─────────────────────────────────────────┘
```

**为什么用"日志"而不是"数据库"存元数据？** 因为日志天然具备：
1. **顺序追加、高性能**：元数据变更本身就是个只追加序列；
2. **天然支持复制**：Raft 就是复制的日志，Kafka 自己的强项；
3. **支持时间旅行**：新节点可以从头回放日志重建完整元数据状态；
4. **统一技术栈**：元数据存储/复制/高可用全用 Kafka 自家能力，不再维护两套。

### 2.3 元数据是怎么在 Controller 和 Broker 之间流动的？

```
  AdminClient / 客户端
       │  CreateTopic 请求
       ▼
Active Controller ──► 元数据日志追加（Raft 复制到 quorum）
       │
       │  ① 元数据版本变化（通过 MetadataVersion 广播）
       ▼
  各 Broker ──► 收到变更通知 ──► 拉取最新元数据 ──► 更新本地缓存
       │
       ▼
  客户端请求（Metadata API 直接打 Broker，返回本地缓存）
```

**关键设计：变更推送 + 拉取结合**。Controller 不把每条元数据都推给所有 Broker（那样 Controller 会成为瓶颈），而是广播"版本更新了"，Broker 自己来拉取增量。客户端（Producer/Consumer）也不用每次连 Controller 问元数据——直接问任意 Broker，Broker 用本地缓存回答。这就把 ZooKeeper 时代"客户端→ZK→Broker"的元数据链路彻底缩短了。

### 2.4 Controller 选举与高可用

- Controller quorum 必须部署**奇数个**（推荐 3 或 5），Raft 要求多数派存活才能选出 leader（3 个挂 1 个没事，挂 2 个就不可用了）；
- Active Controller 挂了，备用 Controller 通过 Raft 选举自动顶上，**元数据日志不丢**（选举出的新 leader 会回放日志到最新）；
- 旧 leader 恢复后只能当 follower，Raft 的 term 机制天然防脑裂——**不再有 ZK 时代"僵尸 Controller"的复杂 fencing 逻辑**。

## 三、KRaft 相比 ZooKeeper 模式，到底赢在哪？

| 维度 | ZooKeeper 模式（2.x/3.0-3.4） | KRaft 模式（3.3+，4.0 起唯一） |
|------|------------------------------|------------------------------|
| 组件 | Kafka + ZooKeeper 两套集群 | 只有 Kafka，Controller 内嵌 |
| 元数据存储 | ZK 节点 | `__cluster_metadata` 内部主题（Raft 日志） |
| Controller 选举 | ZK 临时节点争抢 + fencing | Raft 协议选举，term 防脑裂 |
| 元数据下发 | ZK watch 通知，链路长 | 版本广播 + Broker 主动拉取 |
| 分区规模 | 受 ZK 限制，几万分区已吃力 | 官方目标支持百万级分区 |
| 故障恢复 | Controller 故障要重新从 ZK 加载全量元数据，慢 | 新 Controller 回放日志即可，快 |
| 运维复杂度 | 高（两套集群、版本兼容、ZK 调优） | 低（一套集群） |
| 安全 | 支持 | 支持（SASL/TLS/ACL 全部可用） |

**启动速度也是质的飞跃**：ZK 模式下集群重启，Controller 要从 ZK 拉全量元数据再逐条处理，几十万分区可能要好几分钟；KRaft 模式回放本地日志，秒级到十秒级。

## 四、KRaft 实战：部署与迁移

### 4.1 版本与角色配置

Kafka 3.3+ 生产可用（3.3 起 `metadata.version` 支持，3.5 标记 ZK 弃用，4.0 移除 ZK）。**节点角色**通过 `process.roles` 配置：

```properties
# 专用 Controller 节点
process.roles=controller
node.id=1
controller.quorum.voters=1@kafka-c1:9093,2@kafka-c2:9093,3@kafka-c3:9093
listeners=CONTROLLER://kafka-c1:9093
controller.listener.names=CONTROLLER
log.dirs=/data/kraft-controller

# 纯 Broker 节点
process.roles=broker
node.id=11
controller.quorum.voters=1@kafka-c1:9093,2@kafka-c2:9093,3@kafka-c3:9093
listeners=PLAINTEXT://kafka-b1:9092
advertised.listeners=PLAINTEXT://kafka-b1:9092
log.dirs=/data/kafka-logs

# 小集群：角色合一（combined）
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093
```

关键配置解读：
- `process.roles`：节点承担的角色，`controller` / `broker` / 两者都写；
- `node.id`：全局唯一 ID（取代了 ZK 时代的 broker.id 语义，现在 controller 也有 id）；
- `controller.quorum.voters`：**必须列出所有 controller 的 id@host:port**，格式固定，这就是 quorum 的成员清单；
- `controller.listener.names`：controller 间通信用 listener，**不能用** `PLAINTEXT` 之外与 broker 混用的默认值，建议独立端口（9093）。

### 4.2 格式化存储目录（Kafka 3.x 需要）

KRaft 集群首次启动前，要先给每个节点生成集群 ID 并格式化：

```bash
# 先生成集群 ID
kafka-storage.sh random-uuid
# 输出例如：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# 在 controller 和 broker 节点上分别格式化（每个节点执行一次）
kafka-storage.sh format -t <集群ID> -c /etc/kafka/kraft/server.properties
```

> ⚠️ **format 会清空 log.dirs**，生产环境**绝不能对已有数据的目录执行 format**！只有全新节点/全新集群才需要。这步是 KRaft 部署最常见的翻车点。

启动：

```bash
kafka-server-start.sh /etc/kafka/kraft/server.properties
```

验证集群状态：

```bash
# 查看集群元数据（替代原来的 zookeeper-shell）
kafka-metadata-quorum.sh --bootstrap-server kafka-b1:9092 describe --status
# 输出 ClusterId、LeaderId、Voters、复制的 logEndOffset 等

kafka-topics.sh --bootstrap-server kafka-b1:9092 --list   # 正常列 topic
```

### 4.3 从 ZooKeeper 模式迁移到 KRaft（3.x 支持在线迁移）

Kafka 3.x 提供了 `kafka-storage.sh` 的迁移工具（KRaft 迁移，KIP-866 增强后支持滚动迁移）：

```bash
# 1. 先用 kafka-storage.sh 生成迁移用的 metadata 版本并格式化新目录
# 2. 节点上配置 metadata.version 与迁移相关参数
# 3. 逐个节点滚动重启，从"ZK 模式"切到"迁移模式"
# 4. 全部切完后执行最终确认，完成迁移，ZK 节点可下线
```

迁移注意事项：
- 迁移**不可逆**（切到 KRaft 后不能回退 ZK 模式），生产环境务必先在测试集群完整演练；
- 迁移期间不要做集群级变更（建 topic、扩分区等）；
- 3.x 的迁移工具还比较"新"，**4.0 起是全新 KRaft 集群，不再提供 ZK 迁移路径**——如果你还在用老版本 ZK 集群且要升 4.0，官方建议先升到 3.x 完成 KRaft 迁移，再升 4.0。

## 五、KRaft 实战避坑清单

| 坑 | 正确姿势 |
|----|---------|
| controller.quorum.voters 写错 | 必须与所有节点配置完全一致，且用 `node.id@host:9093` 格式；host 要能互通 |
| 对已有数据目录执行 format | 数据全没！只有全新集群才 format |
| quorum 是偶数个 | Raft 需要多数派，务必奇数（3 或 5），挂一半就不可用 |
| controller 和 broker 共用 listener 端口 | 分开：controller 用 9093，broker 用 9092 |
| 迁移前不备份 | 迁移不可逆，先全量备份 + 测试集群演练 |
| 忘记配置 log.dirs 权限 | KRaft 目录权限不对启动直接失败，检查属主 |
| 客户端还走 ZK | 客户端一直走 bootstrap-server，不受影响；但老管理脚本（zookeeper-shell）要换成 kafka-metadata-quorum.sh |
| 监控还盯 ZK 指标 | 新指标：kafka.controller.quorum.*、kafka.server:metadata.* 等 |

**监控要点**：`kafka.controller:type=KafkaController`（ActiveControllerCount 应为 1）、`kafka.controller.quorum` 相关指标（leader 状态、日志复制延迟）、Broker 侧 `MetadataLoadErrorCount`、`MetadataLeaderChangeCount`。

## 六、总结：面试怎么答？

**一句话版本**：KRaft 是 Kafka 基于 KIP-500 的元数据架构革命——用内嵌的 Controller 节点组成 Raft quorum，把集群元数据存进 `__cluster_metadata` 内部主题，通过日志复制保证一致性和高可用，彻底去掉了 ZooKeeper 依赖；Kafka 3.3 起可用，3.5 弃用 ZK，4.0 起 ZK 被完全移除。

**展开版本（按面试官追问节奏）**：
1. **为什么去 ZK**：运维双组件、元数据链路长、分区规模受限、两套一致性协议；
2. **KRaft 架构**：Controller 角色独立 + Raft quorum 选举 + `__cluster_metadata` 日志存储 + Broker 本地缓存元数据；
3. **元数据同步**：变更写日志→Raft 复制→版本广播→Broker 拉取增量→本地缓存服务客户端；
4. **优势**：百万分区扩展目标、秒级故障恢复、启动快、单集群运维；
5. **部署要点**：process.roles / node.id / controller.quorum.voters / 独立 controller listener / 首次 format；
6. **迁移**：3.x 支持 ZK→KRaft 滚动迁移，不可逆，先演练再上生产。

如果面试官再问"那 KRaft 的 Controller 和旧 Controller 选举有什么区别"，你就答：旧的是 ZK 临时节点抢主 + 复杂的 fencing 防僵尸；新的是标准 Raft 选举，term 递增天然防脑裂，新 leader 回放元数据日志追平即可——**一致性从"外包"变成了"内建"**，这就是 Kafka 4.0 的底气。
