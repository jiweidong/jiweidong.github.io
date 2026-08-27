---
title: 【MySQL 高可用】MySQL 组复制 MGR 深度解析：从 Paxos 到多主写入与单主模式的完整实践
date: 2026-08-27 08:00:00
tags:
  - MySQL
  - 高可用
  - 主从复制
  - 分布式
categories:
  - Java
  - MySQL
author: 东哥
---

# 【MySQL 组复制 MGR 深度解析：从 Paxos 到多主写入与单主模式的完整实践

## 面试官：主从复制挂了怎么办？MySQL 有原生高可用方案吗？

传统的主从复制（异步复制）有一个天然的痛点：**主库挂了，从库可能没收到最新 binlog，数据会丢**，而且故障转移要依赖 MHA、Orchestrator 等外部工具，切换过程复杂、易出错。

MySQL 5.7.17 引入的**组复制（Group Replication，简称 MGR）**改变了这一切——它是 MySQL 官方的原生高可用方案，基于 Paxos 共识协议，支持多主写入、自动故障转移、强一致性（可配置）。今天我们就从 Paxos 原理讲到 MGR 的架构、部署与踩坑。

## 一、MGR 是什么：一句话总结

> MGR 是一个**基于 Paxos 协议的插件**，它把一组 MySQL 实例组成一个复制组，组内所有节点通过**组成员共识**决定事务的提交，从而实现数据一致性、自动选主和故障转移。

它不是一个独立的产品，而是 MySQL Server 内置的插件（`group_replication.so`），和 InnoDB、binlog 深度集成。

## 二、为什么需要 Paxos：从异步复制的缺陷说起

### 2.1 异步复制的三个问题

| 问题 | 说明 |
|------|------|
| 数据丢失 | 主库提交后、从库同步前主库宕机，事务丢失 |
| 脑裂 | 网络分区时，原主和候选主同时对外服务 |
| 人工干预 | 故障转移依赖外部脚本/工具，容易出错 |

### 2.2 Paxos 如何解决

Paxos 的核心思想：**一个值要被多数派（quorum）接受，才算真正提交**。MGR 中：

- 事务在主节点执行后，**广播到组内所有节点**
- 需要**多数派节点（超过半数）确认**，事务才算提交成功
- 任何节点宕机，只要剩余节点仍构成多数派，组就能继续工作

多数派机制同时解决了数据丢失和脑裂：一个事务被多数派确认过，就不会因为单点故障丢失；网络分区时，只有包含多数派的分区能继续提交事务，另一分区自动降级只读。

## 三、MGR 的两种模式

### 3.1 单主模式（Single-Primary）

- 组内只有一个节点可写（primary），其他节点只读
- 写节点由组内自动选举产生，故障时**自动切换**
- 适合大多数业务：读写分离、兼容性最好（没有写冲突）

```
          ┌─────────────┐
          │  Primary(写) │ ← 自动选举
          └──────┬──────┘
     ┌───────────┼───────────┐
  ┌──┴──┐    ┌──┴──┐    ┌──┴──┐
  │ 只读 │    │ 只读 │    │ 只读 │
  └─────┘    └─────┘    └─────┘
   (Secondary 自动故障转移后成为 Primary)
```

### 3.2 多主模式（Multi-Primary）

- 组内**所有节点都可读写**，没有主从之分
- 依靠 Paxos 保证全局事务顺序，但**写冲突需要业务规避**
- 适合读多写少、写入分散到不同分片的场景

**多主模式的冲突处理**：两个节点同时修改同一行时，后提交的事务会被回滚（依赖检测到冲突）。所以多主模式下，业务上最好按维度分片（如用户 ID 哈希），让不同写入落到不同节点。

### 3.3 如何选择

| 对比项 | 单主模式 | 多主模式 |
|--------|---------|---------|
| 写入能力 | 单点写入 | 多点写入 |
| 冲突风险 | 无 | 有，需业务规避 |
| 一致性 | 强（读走主） | 强（需配合 group_replication_consistency） |
| 适用场景 | 大多数业务 | 写入可分片、对延迟敏感 |

## 四、MGR 的核心机制

### 4.1 组成员管理

MGR 的组成员信息通过 **XCom（基于 Paxos 的通信层）** 维护，节点加入/退出都会触发视图变更（View Change），所有节点通过共识确认新的成员列表。

### 4.2 事务提交流程（单主模式）

```
1. 客户端写入 Primary
2. Primary 执行事务，写入 binlog
3. Primary 通过 XCom 广播事务到所有 Secondary
4. 各节点确认（ACK）→ 多数派确认后
5. 各节点并行应用事务（certification）
6. 事务在所有节点提交，Primary 返回客户端成功
```

关键点：**客户端要等多数派确认后才算提交成功**，所以 MGR 的写延迟高于异步复制，但换来的是不丢数据。

### 4.3 冲突检测与认证（Certification）

每个事务在组内有全局顺序号（由 Paxos 分配）。节点收到事务后执行**认证**：检查事务涉及的行是否与其他"更早全局顺序号但尚未应用"的事务冲突。冲突则回滚，不冲突则应用。

### 4.4 自动故障转移

Primary 宕机后，组内通过 Paxos 检测到失联，**剩余节点自动选举新的 Primary**，整个过程无需人工干预，秒级完成。应用层配合连接池探活即可实现无缝切换。

## 五、部署实战：三节点 MGR（单主模式）

### 5.1 环境准备

三台服务器（或容器）：
```
node1: 192.168.1.11
node2: 192.168.1.12
node3: 192.168.1.13
```
MySQL 版本 ≥ 5.7.17（推荐 8.0.x），开启 GTID 模式。

### 5.2 配置文件（三节点相同，仅 server_id 不同）

```ini
[mysqld]
server_id = 1                # 每台不同：1/2/3
gtid_mode = ON
enforce_gtid_consistency = ON
binlog_format = ROW
binlog_checksum = NONE       # MGR 要求关闭 binlog 校验和
master_info_repository = TABLE
relay_log_info_repository = TABLE
log_slave_updates = ON
log_bin = mysql-bin
relay_log = relay-log

# 组复制配置
transaction_write_set_extraction = XXHASH64
loose-group_replication_group_name = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
loose-group_replication_start_on_boot = OFF
loose-group_replication_local_address = "192.168.1.11:33061"   # 每台不同
loose-group_replication_group_seeds = "192.168.1.11:33061,192.168.1.12:33061,192.168.1.13:33061"
loose-group_replication_bootstrap_group = OFF
loose-group_replication_single_primary_mode = ON
loose-group_replication_enforce_update_everywhere_checks = OFF
```

> 注意：`group_replication_group_name` 必须是合法的 UUID 格式，可以用 `SELECT UUID()` 生成。

### 5.3 初始化第一个节点（引导组）

```sql
-- node1 上执行
SET GLOBAL group_replication_bootstrap_group = ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = OFF;
```

### 5.4 加入其他节点

```sql
-- node2/node3 上执行
CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='repl_pass'
  FOR CHANNEL 'group_replication_recovery';
START GROUP_REPLICATION;
```

### 5.5 验证

```sql
-- 任一节点
SELECT * FROM performance_schema.replication_group_members;
-- 期望看到 3 个 ONLINE 成员，单主模式下一个是 PRIMARY
```

## 六、生产实践要点与常见坑

### 6.1 关键参数

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| group_replication_consistency | AFTER (8.0.14+) | 读也等待多数派确认，更强一致 |
| group_replication_member_expel_timeout | 5~15 | 节点失联驱逐超时（秒），默认 5 |
| group_replication_communication_max_message_size | 10M | 大事务拆分包大小 |
| loose-group_replication_flow_control_mode | DISABLED/QUOTA | 流控，防止慢节点拖垮组 |

### 6.2 常见坑

**坑 1：大事务拖垮整个组**
MGR 是"木桶效应"：一个事务要在所有节点应用，慢节点会拖慢全组。大事务（如一次删百万行）会长时间占用复制通道。**解法**：拆分事务、控制单事务大小、开启流控。

**坑 2：DDL 与 DML 冲突**
DDL 在组内执行时，其后的 DML 可能被阻塞（等待认证）。**解法**：低峰期执行 DDL，或先评估影响。

**坑 3：网络抖动导致频繁驱逐**
成员被误判失联会被驱逐（expel），重新加回需要时间。**解法**：调大 `group_replication_member_expel_timeout`，保证网络稳定（同一机房/可用区部署）。

**坑 4：读写分离的读延迟**
单主模式下 Secondary 是异步应用（虽然提交是同步确认，但读请求可能读到稍旧数据）。**解法**：对一致性要求高的读走 Primary，或开启 `AFTER` 一致性级别。

**坑 5：写入全组广播的网络开销**
MGR 每个事务都要广播，节点间网络带宽成为瓶颈。**解法**：同机房低延迟网络部署，评估写入 QPS 上限（一般单主模式写 TPS 是单机的 50%~70%）。

### 6.3 MGR vs 传统主从 + MHA

| 对比项 | 异步复制 + MHA | MGR |
|--------|---------------|-----|
| 数据一致性 | 可能丢数据 | 多数派确认，不丢已确认事务 |
| 故障转移 | 外部脚本，分钟级 | 自动选举，秒级 |
| 脑裂防护 | 无 | Paxos 天然防脑裂 |
| 多写支持 | 不支持 | 多主模式支持 |
| 运维复杂度 | 需部署额外组件 | MySQL 内置插件 |
| 写性能 | 高（异步） | 略低（同步确认） |

## 七、面试高频追问

**Q1：MGR 和半同步复制有什么区别？**
A：半同步复制只保证"至少一个从库收到 binlog"，且主从角色固定、从库不参与决策；MGR 基于 Paxos，所有节点通过共识参与事务决策，支持自动选主和多主写入。

**Q2：MGR 最多支持多少节点？**
A：官方支持最多 9 个节点。因为 Paxos 需要 2N+1 容忍 N 个故障，节点越多通信成本越高，9 个是官方建议上限。

**Q3：MGR 能容忍几个节点宕机？**
A：3 节点组容忍 1 个，5 节点组容忍 2 个。少于多数派时组进入只读/不可用状态（防脑裂）。

**Q4：MGR 是强一致的吗？**
A：写路径是强一致的（多数派确认）；读路径默认可能是最终一致，可通过 `group_replication_consistency=AFTER` 提升为强一致（代价是读延迟增加）。

**Q5：MGR 和 Galera/Percona XtraDB Cluster 有什么区别？**
A：Galera 基于认证复制（certification-based），也是同步多主方案，但用自定义的 wsrep 协议；MGR 是 MySQL 官方基于 Paxos 的实现，与官方版本同步迭代，生态和兼容性更好。

## 总结

MGR 是 MySQL 原生高可用的里程碑：用 Paxos 共识解决了异步复制的数据丢失与脑裂问题，单主模式适合大多数业务，多主模式适合可分片的写入场景。它把故障转移从"外部工具 + 人工脚本"升级为"组内自动选举"，是生产环境替代传统 MHA 方案的现代选择。理解 Paxos 多数派、事务广播确认、冲突认证这条链路，无论是架构选型还是面试，你都能游刃有余。
