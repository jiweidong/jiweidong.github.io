---
title: 【分布式数据库】TiDB 架构深度解析：TiKV、Raft、MVCC 与分布式事务的实现原理
date: 2026-09-11 08:40:00
tags:
  - 分布式数据库
  - TiDB
  - 架构设计
  - 面试
categories:
  - 数据库
  - 系统设计
author: 东哥
---

# 【分布式数据库】TiDB 架构深度解析：TiKV、Raft、MVCC 与分布式事务的实现原理

## 面试官：MySQL 单表到几千万行就开始慢，你们怎么解决？

标准答案无非三条路：

1. **加索引 / 优化 SQL**——能顶一阵，但数据量还在涨；
2. **读写分离 + 分库分表（ShardingSphere）**——解决容量，但引入跨库 JOIN、分布式事务、扩容迁移、全局唯一 ID 一堆问题；
3. **换分布式数据库**——用 TiDB / OceanBase 这类"看起来像 MySQL、实际上是分布式 KV 之上做 SQL"的系统。

这里最容易踩的认知误区是：**分库分表是把复杂度从数据库搬到了应用层**（中间件、路由规则、数据迁移、DDL 协调）；而 TiDB 的设计目标是**把复杂度留在数据库内部，对外保持 MySQL 兼容协议**。

本文从分层架构讲到 Region、Raft、MVCC 与 Percolator 事务模型，把 TiDB 的主干串起来。

## 一、分层架构：四个组件各司其职

```
              ┌──────────────────────────────────────┐
   客户端 ────▶│  TiDB Server（无状态 SQL 层）          │
  (MySQL协议) │  SQL 解析 → 逻辑优化 → 物理优化 → 执行  │
              └───────┬──────────────────┬───────────┘
                      │                  │
        ┌─────────────▼──────┐   ┌───────▼─────────┐
        │  PD（调度 + TSO）   │   │ TiFlash（列存）  │
        │  Region 元数据/均衡  │   │ HTAP 分析加速    │
        └─────────────┬──────┘   └───────┬─────────┘
                      │                  │
              ┌───────▼──────────────────▼───────┐
              │        TiKV 集群（行存 KV 引擎）    │
              │  Region 1 (Raft Group)            │
              │  Region 2 (Raft Group) ...        │
              │  底层存储：RocksDB                 │
              └───────────────────────────────────┘
```

| 组件 | 角色 | 关键点 |
| --- | --- | --- |
| **TiDB Server** | SQL 层，无状态 | 可直接水平扩容；负责解析、优化、执行与 KV 编码 |
| **TiKV** | 分布式 KV 存储 | 数据按 Region 分片，每个 Region 是一个 Raft Group，底层 RocksDB |
| **PD** | Placement Driver | 全局元数据、**TSO 授时**、负载均衡与调度、Region 副本管理 |
| **TiFlash** | 列存副本 | 通过 Raft Learner 同步行存数据，提供 MPP 分析能力（HTAP） |

**无状态 TiDB + 有状态 TiKV + 控制面 PD**，这是典型的计算存储分离架构。加 TiDB 节点提升并发 SQL 处理能力；加 TiKV 节点提升容量与吞吐；PD 用 etcd 做高可用（3 或 5 副本）。

## 二、数据模型：表如何映射成 KV

TiKV 只认 KV（`byte[] -> byte[]`，按 key 有序存储），SQL 表结构需要编码。核心规则：

### 1. 表数据（Row Key）

```
key   = t{tableID}_r{rowID}                （rowID 即聚簇索引值 / _tidb_rowid）
value = [col1_value, col2_value, ...]      （按列顺序编码的字段值）
```

- 前缀 `t` 表示"表数据"，`r` 表示"行"
- 因为 key 按 rowID 有序，所以**主键范围扫描 = KV 范围扫描**，天然高效
- `tableID` 集群内唯一，由 TiDB 分配

### 2. 索引数据

```
普通索引：key = t{tableID}_i{indexID}_indexedValue_{indexID}_rowID
          value = null
唯一索引：key = t{tableID}_i{indexID}_indexedValue
          value = {rowID}      （唯一索引带 rowID 作 value，用于回表）
```

**为什么普通索引的 key 里要带 rowID？** 因为同一个索引值（比如 `status=1`）可能对应几百万行，必须把 rowID 拼进 key 才能保证唯一，同时实现"索引值相同则按 rowID 排序"。

**为什么唯一索引要把 rowID 放 value？** 唯一索引的 key 里没有 rowID（否则不唯一），但回表需要知道主键，所以 value 存 rowID。

> 与 MySQL 的关键差别：TiDB 的**索引和主键数据不在同一个 LSM 里做聚簇存储**（在 TiKV 视角都是 KV），二级索引回表是一次额外的 RPC（或一次 Coprocessor 调用），所以**索引覆盖（covering index）在 TiDB 里比 MySQL 更重要**——能避免回表就是省一次网络往返。

### 3. 集群内的 ID 分配

`tableID`、`indexID`、`_tidb_rowid`、`auto_increment` 都由 **PD 批量分配**（不是每次申请一个，而是一次要一段，减少 PD 压力）。这也导致一个常见困惑：**TiDB 的 AUTO_INCREMENT 是"唯一但不连续"的**——多个 TiDB 节点各自预取区间，重启/扩容会跳号。如果业务要求严格连续，那不是 TiDB 的目标场景。

## 三、Region 与 Raft：分片、复制与自愈

### 1. Region 是什么

TiKV 把整个 Key 空间按范围切成一段段**Region**，默认单 Region 约 **96MB**（由 `region-split-size` 控制），每个 Region 包含一段连续的 key 区间。

```
Key Space:  [a .................. z]
            [--Region1--][--Region2--][--Region3--]
              [40,60)      [60,75)      [75,90)   (从小到大排列)
```

TiDB 启动时只有一个 Region（覆盖整个 key 空间），随写入自动分裂。

### 2. 每个 Region 是一个 Raft Group

```
        Raft Group (Region 40: [a, c))
     ┌──────────┐  ┌──────────┐  ┌──────────┐
     │  Leader  │  │ Follower │  │ Follower │
     │  TiKV-1  │◀─│  TiKV-2  │  │  TiKV-3  │
     └──────────┘  └──────────┘  └──────────┘
        读写          同步日志        同步日志
```

- **读写都走 Leader**（与 Kafka 的分区类似），Follower 主要做数据冗余与读副本（ReadIndex 可支持 follower read，但默认走 Leader）
- 写入需**多数派确认**（3 副本需 2 个确认）才能返回成功，这就是 TiDB 的强一致来源
- Leader 通过 Raft 心跳超时自动重新选举，实现故障自愈（单节点故障，秒级恢复）

### 3. Region 分裂与调度

| 触发 | 动作 |
| --- | --- |
| Region > `region-split-size`（96MB） | **分裂**成两个 Region，各自复制日志 |
| Region 过大但分裂失败（同 key 写入太多） | 按 `region-split-keys` 兜底分裂 |
| 热点（读写集中在少数 Region） | PD 通过 `hot-region` 统计触发**热点调度**，把 Leader 或整个 Region 迁走 |
| 节点增删/负载不均 | PD 的 balance 调度器搬运副本，保证每个 TiKV 的 Region 数量与容量均衡 |
| 副本数不足 | PD 触发补副本；副本数由 `max-replicas`（默认 3）决定 |

**Region 分裂的本质是 Raft 层的"日志重放"**：分裂后两个新 Region 各自从同一个 Raft 日志起点开始，先并行服务，待两个新 Raft Group 选举完成后再"接管流量"。所以分裂期间不阻塞写入，只是会有一小段性能波动。

### 4. 与分库分表的本质差异

| 维度 | ShardingSphere 分库分表 | TiDB |
| --- | --- | --- |
| 分片策略 | 应用/中间件按 sharding key 路由 | **数据库内部按 key 范围自动分裂** |
| 扩容 | 需要搬迁数据、停机/双写 | 加 TiKV 节点，PD 自动搬迁 Region |
| 跨分片 JOIN | 中间件归并，限制极多 | TiDB 层做分布式执行计划 |
| 分布式事务 | 需引入 Seata/补偿 | **原生 Percolator 事务** |
| 副本/高可用 | 依赖 MySQL 主从 | Raft 多数派自动选主 |
| 热点 | 需精心设计分片键 | PD 自动热点调度（缓解但无法根治错误的分片键） |

## 四、事务：Percolator 与两阶段提交

TiDB 继承 Google Percolator 模型（也是 TiKV 的原生事务模型）。先理解三个基础：

### 1. TSO：全局单调递增的时间戳

PD 提供 `TSO`（Timestamp Oracle），返回 `(physical_time << 18) | logical_counter`，**全局单调递增**。所有事务的 `start_ts`（读版本）和 `commit_ts`（提交版本）都来自 TSO，这就是分布式 MVCC 与"外部一致性"的来源。

- TSO 是**批量发放**的（一个 TiDB 请求一批，分给多个事务用），所以单点 PD 的 TSO 也能支撑百万级 TPS
- `start_ts` 同时也是**读快照点**：事务开始时快照建立，后续读的都是 `ts <= start_ts` 的版本（Repeatable Read）

### 2. MVCC：多版本如何存

TiKV 里每条数据的 key 实际是：

```
Key   = {user_key}_{commit_ts}
Value = {start_ts, value_type(PUT/DELETE), value}
```

- 写入 = 追加一个新版本（LSM 天然追加友好）
- 读取 = 从最新版本往前找第一个 `commit_ts <= start_ts` 的版本
- 通过 `advise_ts`、`lock` 列（Percolator 的 lock column）标记未提交的写

因为底层 RocksDB 是 LSM Tree，**随机写变成顺序追加**，这是 TiKV 写吞吐高的关键。代价是读放大（要跳过已删除/过期版本），所以需要 GC：`tidb_gc_life_time`（默认 10min）控制可回收的旧版本。

### 3. Percolator 两阶段提交

假设事务要写 A、B 两行：

```
① Prewrite（预写）
   对 A、B 各自写入 {lock, primary_key, start_ts, value} 到 lock 列
   - 检查写写冲突（别人在我读的快照之后改过这行 → 报 Write Conflict，需重试）
   - 选一个作为 Primary（通常是第一行），其余为 Secondary

② 询问 PD 拿 commit_ts

③ Commit（提交）
   先提交 Primary：写 {commit_ts, value} 到数据列，删除 lock
   再异步提交 Secondary：写 commit_ts，删 lock

④ 若此时崩溃 → 其它事务读到 Primary 的 lock：
   - 发现 primary 已 commit → 帮忙提交 secondary（提交状态由 primary 决定）
   - 发现 primary 未 commit / 已超时 → 回滚（清理 lock 与数据）
```

**核心洞察**：Percolator 用"**所有状态的最终判定权都在 Primary**"解决了分布式两阶段提交的原子性问题——只要 Primary 的提交状态确定，整个事务的结果就确定，Secondary 无论何时挂掉都能被恢复。

### 4. 乐观事务与悲观事务

| | 乐观事务（`tidb_txn_mode=optimistic`） | 悲观事务（`pessimistic`，**默认**） |
| --- | --- | --- |
| 加锁时机 | 只在 commit 时检查冲突 | prewrite 前先给受影响的行加锁 |
| 冲突场景 | 高并发写同一行 → 大量 Write Conflict 重试 | 提前串行化，重试少 |
| 吞吐 | 冲突低时更高 | 冲突高时更稳 |
| 死锁 | 无锁，不会死锁，但可能活锁（一直重试） | 可能死锁，TiDB 有死锁检测与超时回滚 |
| 适用 | 读多写少、冲突少 | 有并发更新的业务（余额、库存） |

**生产建议**：默认悲观模式。只有确认是"低频写 + 高冲突少"的场景才考虑乐观模式。

**事务大小限制（非常重要的坑）**：

- 单个事务大小默认 `txn-total-size-limit = 100MB`（早期版本 100MB）
- 单个 KV entry 大小限制（`raft-entry-max-size`，默认 8MB）
- 所以 `UPDATE t SET ... ` 一次性更新几十万行必然失败，必须**分批（限流 + 循环 + `ORDER BY` 主键）**

```sql
-- 分批更新的标准写法（应用层循环）
UPDATE t_order SET status = 2
WHERE status = 1 AND id > ? AND id <= ?
LIMIT 1000;
-- 每次提交一个事务，避免超过 txn-total-size-limit
```

## 五、SQL 执行：Coprocessor 与下推

TiDB 把一个 SQL 拆成多个执行片段：

```
TiDB Server:  Parse → Resolve → Logical Plan → 优化（RBO/CBO）→ Physical Plan
                                            │
                                            ▼  分发到各 Region
TiKV Coprocessor:  谓词下推(Selection) → 聚合下推(Aggregation) → TopN → Limit
                                            │
                                            ▼  返回部分结果
TiDB Server:  归并（Merge/Join/聚合）→ 返回客户端
```

- **Coprocessor** 就是 TiKV 上的"执行器"，接收 TiDB 下发的 DAG 请求，在 Region 本地完成过滤和部分聚合，只把结果回传
- **下推能省网络**：`SELECT COUNT(*)` 每台 TiKV 本地算完再汇总，而不是把全表数据拉回 TiDB
- **TiFlash** 通过 MPP 模式做多节点并行 JOIN/聚合，适合大宽表分析；TiDB 的 CBO 会根据统计信息自动选择行存还是列存路径（`tidb_isolation_read_engines`）

**常见性能问题**：`EXPLAIN ANALYZE` 里出现大量 `cop task` 但 `actRows` 与 `estRows` 差异巨大 → 统计信息过期，`ANALYZE TABLE` 或开启自动统计（`tidb_auto_analyze_*`）。若 Region 数极多导致 Coprocessor 请求数爆炸（一次查询打到上万个 Region），要考虑**是否缺少合适的索引前缀**（导致无法裁剪 key range）。

## 六、与 MySQL 的兼容性与差异清单

| 项 | MySQL | TiDB |
| --- | --- | --- |
| 协议/语法 | — | 高度兼容（MySQL 8.0 协议），大部分客户端驱动可直接连 |
| 自增 ID | 连续（单机） | **唯一但不连续**（PD 批量分配） |
| 事务大小 | 受 undo/redo 影响 | 有明确 `txn-total-size-limit`（100MB） |
| 外键 | 支持 | **5.0 之前不支持**（可用应用层保证）；后续版本支持但仍不推荐大规模使用 |
| 存储过程/触发器/事件 | 支持 | 支持有限，不建议依赖 |
| DDL | 在线 DDL（8.0 有 instant/INPLACE） | 在线 DDL，异步 schema 变更，支持 `ADMIN SHOW DDL JOBS` |
| 隔离级别 | RR 默认 | **快照隔离（SI）**，等价于 RR 的读行为；不支持 `SERIALIZABLE` 语义完全等价 |
| 大事务/长事务 | 有隐患 | 隐患更严重（MVCC 版本堆积、GC 无法回收） |
| 自增主键热点 | 无 | **单调递增主键会产生写热点**！ |

**最经典的 TiDB 坑：自增主键写热点。**
因为数据按 key 范围分布，`AUTO_INCREMENT` 主键永远写在 key 空间的"最右边"，所有写入都落到最后一个 Region → 单 Region 成为瓶颈。
解决方案：

- 用 `AUTO_RANDOM`（TiDB 特有，主键加随机位打散）
- 或使用业务上天然分散的主键（如 `user_id`）
- 或 `SHARD_ROW_ID_BITS` 配合 `_tidb_rowid`

```sql
CREATE TABLE t_order (
  id BIGINT PRIMARY KEY AUTO_RANDOM,
  ...
);
```

## 七、选型：什么时候用 TiDB

| 场景 | 建议 |
| --- | --- |
| 单表 > 5000 万行、持续增长、有跨分片查询需求 | ✅ TiDB |
| 需要水平扩容、不想在应用层维护分片逻辑 | ✅ TiDB |
| OLTP + 实时 OLAP 混合（HTAP，加 TiFlash） | ✅ TiDB |
| 云原生部署、K8s 上弹性扩缩 | ✅ TiDB（Operator） |
| 数据量 < 千万，单机 MySQL 完全扛得住 | ❌ 别为分布式付运维成本 |
| 强依赖存储过程、触发器、外键约束 | ❌ 慎选 |
| 需要超大规模大事务（一次性更新百万行） | ❌ 需要应用层拆分 |
| 极致单机读性能、低延迟（<1ms） | ❌ 分布式必然有网络往返 |

一句话：**TiDB 解决的是"容量与扩展性"问题，不是"单机性能"问题。**

## 面试官追问

**Q1：TiDB 怎么保证跨节点事务的 ACID？**
靠 Percolator 两阶段提交 + TSO 全局时间戳。Prewrite 阶段写入带锁的未提交版本，Commit 阶段先提交 Primary（决定事务最终状态）再提交 Secondary；任何时刻崩溃，其它事务都能依据 Primary 的状态帮助恢复（提交或回滚），从而保证原子性。隔离性由 MVCC 快照读提供，持久性由 Raft 多数派落盘保证。

**Q2：TSO 是单点，会不会成为瓶颈？**
TSO 由 PD Leader 提供，是纯内存的原子自增 + 批量发放（一次给一个 TiDB Server 一批时间戳），实测可支撑百万级 TPS 的事务。PD 通过 etcd 做高可用，Leader 挂掉后在秒级内由其它 PD 接管，TiDB 会重试获取时间戳。

**Q3：Region 分裂会不会阻塞读写？**
不会长时间阻塞。分裂是把一个 Raft Group 拆成两个，两边先各自按同一份日志独立服务，待新 Leader 选举完成后接管。期间有短暂的状态转换窗口，表现为延迟尖刺，但不会丢数据。分裂阈值（96MB）是为了平衡"Region 太小元数据膨胀"与"太大导致恢复慢"。

**Q4：TiDB 的 GC 为什么重要？**
MVCC 会保留历史版本，不清理会导致存储无限膨胀、读放大加剧。GC 按 `tidb_gc_life_time`（默认 10 分钟）保留窗口清理旧版本。**长事务/大事务会卡住 GC**（因为它引用的 `start_ts` 太老，之后的所有版本都不能删），进而导致存储暴涨——所以线上必须监控长事务并把 `tidb_gc_life_time` 与最长事务时间对齐。

**Q5：为什么 TiDB 不推荐大事务？**
三层原因：① 单个事务超过 `txn-total-size-limit` 直接报错；② 大事务在提交时要一次性做大量 prewrite/commit，会造成写放大与锁冲突；③ 长事务让 GC 无法回收，存储与读性能双降。所以工程上必须**分批提交**。

## 总结

把 TiDB 的主干用一句话串起来：

> **TiDB Server 把 SQL 翻译成有序 KV，TiKV 把 KV 按 Region 切分并用 Raft 复制，PD 负责授时与调度，跨 Region 的原子写靠 Percolator 两阶段提交 + TSO 时间戳，隔离性靠 RocksDB 上的 MVCC 多版本。**

工程落地的四个关键点：

1. **主键设计避热点**：`AUTO_RANDOM` 或业务分散键，别用单调递增；
2. **事务要小**：分批提交，监控长事务，别阻塞 GC；
3. **索引尽量覆盖**：TiDB 的回表是跨节点 RPC，覆盖索引收益比 MySQL 更大；
4. **统计信息要新**：CBO 依赖统计，`ANALYZE` 与自动统计必须开着，用 `EXPLAIN ANALYZE` 对比 `estRows` 与 `actRows` 找问题。
