---
title: 【MySQL 高可用】MySQL GTID 复制深度解析：从位点同步痛点、GTID 生命周期到并行复制与主从切换实战
date: 2026-09-09 08:00:00
tags:
  - MySQL
  - 主从复制
  - GTID
  - 高可用
categories:
  - MySQL
  - 高可用
author: 东哥
---

# 【MySQL 高可用】MySQL GTID 复制深度解析：从位点同步痛点、GTID 生命周期到并行复制与主从切换实战

## 面试官：你们主从复制用的位点（file+pos）还是 GTID？说说 GTID 解决了什么问题？

很多同学的 MySQL 主从还停留在"看 `SHOW MASTER STATUS` 拿 File 和 Position，然后 `CHANGE MASTER TO` 手动指定"的阶段。这套**位点复制**在单主一从的玩具环境没问题，一旦涉及**主从切换、级联复制、故障恢复**，就会暴露出大量手工操作的痛点。而 **GTID（Global Transaction Identifier，全局事务标识符）** 正是 MySQL 5.6 引入、5.7 成熟、8.0 默认的复制革命。

本文从复制协议的底层痛点讲起，一路深入到 GTID 生命周期、自动定位、并行复制（MTS）与主从切换，面试够用，实战也够用。

## 一、位点复制到底痛在哪？

传统复制中，从库通过 `CHANGE MASTER TO MASTER_LOG_FILE='mysql-bin.000021', MASTER_LOG_POS=154;` 告诉主库"我从哪个文件的哪个偏移量继续要日志"。

三个致命痛点：

1. **位点是"物理坐标"，和事务内容没有绑定关系**。binlog 被 `purge` 或主库切换后，坐标直接失效，从库只能重建。
2. **主从切换必须人工介入**。A 挂掉、B 提升为新主后，C 要重新指向 B，得先找到 B 上"恰好对应"的位点——在多线程复制、事务交错下，这个位点几乎无法手工确定，只能靠 `pt-table-checksum` 等工具反复校对。
3. **无法天然去重**。从库重放时如果中断后从错误位点继续，可能重复执行或漏执行事务，需要 DBA 人工判断。

**GTID 的核心理念：给每个提交的事务一个全局唯一 ID，复制不再关心"文件+偏移量"，只关心"哪些事务我还没有"。** 位置无关、天然幂等、切换自动。

## 二、GTID 长什么样？怎么生成的？

```
3E11FA47-71CA-11E6-9E97-0800278CA2A4:1-23
server_uuid             : 事务序号（从1开始，单调递增）
```

- 前半段是主库的 `server_uuid`（`SHOW VARIABLES LIKE 'server_uuid'`，8.0 里就是 `auto.cnf` 里那个）；
- 后半段是事务序号。**注意**：不是每个语句都分配序号，而是**每个提交的事务**（commit 时）分配一个，未提交/回滚的事务不占号；
- 如果事务内部是多条语句，整个事务共享同一个 GTID，保证"一个事务要么完整执行、要么完全不执行"；
- 一个 GTID 只在**产生它的源库**上生成一次，全局唯一。

开启方式（8.0 默认开启）：

```ini
# my.cnf
gtid_mode = ON
enforce_gtid_consistency = ON
log_bin = ON
log_slave_updates = ON   # 级联复制必须，从库把重放的事务也写进自己的 binlog
```

> `enforce_gtid_consistency` 会禁止 `CREATE TABLE ... SELECT`、事务内 `DROP TEMPORARY TABLE` 等会导致 GTID 与事务无法一一对应的语句。

## 三、GTID 的完整生命周期（面试重点）

以一个事务从主库产生、到从库应用完成为例：

1. **主库提交事务**：分配 GTID `uuid:1`，事务内容连同 `Gtid_log_event` 一起写入主库 binlog；
2. **从库拉取**：IO 线程通过 dump 协议拿到 binlog，写入从库 relay log；
3. **从库应用**：SQL 线程重放前，先检查该 GTID 是否已存在于自己的 `gtid_executed` 集合中：
   - **存在** → 直接跳过（这就是天然防重复执行）；
   - **不存在** → 执行事务，并把 GTID 加入 `gtid_executed`；
4. **持久化**：8.0 中 GTID 会实时写入 `mysql.gtid_executed` 表，不再依赖 binlog 里的历史记录（这也是 8.0 允许 `log_slave_updates=OFF` 且不丢 GTID 信息的原因）。

三个核心变量必须分清：

| 变量 | 含义 | 典型值 |
|---|---|---|
| `gtid_executed` | 本实例**已执行过**的所有事务集合（含自己产生的+从库应用的） | `3E11FA47-...:1-100` |
| `gtid_purged` | 已经从 binlog 中清除、但已计入 executed 的事务集合 | 备份恢复场景必配 |
| `gtid_owned` | 正在执行（未提交完）的事务，一般排查用 | 运行时短暂存在 |

## 四、自动定位：MASTER_AUTO_POSITION 的原理

GTID 复制下，从库不再记位点：

```sql
CHANGE MASTER TO
  MASTER_HOST='192.168.1.10',
  MASTER_USER='repl',
  MASTER_PASSWORD='xxx',
  MASTER_AUTO_POSITION=1;   -- 关键：自动定位
START SLAVE;
```

握手过程：

1. 从库发起 dump 请求时，带上自己的 `gtid_executed` 集合（`COM_BINLOG_DUMP_GTID`）；
2. 主库计算**差集**：`主库 binlog 中的事务集合 − 从库已执行集合`；
3. 主库从差集第一个事务开始推送，从库按 GTID 逐个应用、自动跳过重复项。

**为什么切换变得简单了？** 因为新主只需要知道"从库还缺哪些事务"，而 GTID 集合是全局一致的账本，不依赖任何物理坐标。切换脚本里只需要把 `MASTER_HOST` 指向新主，`MASTER_AUTO_POSITION=1` 一开，剩下的交给协议本身。

## 五、并行复制（MTS）：从库追上主库的关键

### 5.1 为什么从库会延迟？

老版本从库只有一个 SQL 线程**串行**重放 relay log。主库是并发提交的（5.7+ 组提交让主库写入 binlog 都能并行），从库却单线程应用——**写入放大+串行化**，这就是复制延迟的根源。

### 5.2 并行策略演进

```ini
# 从库配置
slave_parallel_type = LOGICAL_CLOCK   # 8.0 已废弃该参数，默认按提交顺序
slave_parallel_workers = 8            # 并行 SQL 线程数，建议 <= 主库并发写入线程数
```

- **DATABASE 策略（5.6）**：不同库的事务并行。局限性大——单库多表写入（绝大多数业务）完全无法并行；
- **LOGICAL_CLOCK 策略（5.7）**：基于**组提交**。主库上同一组提交的事务（`binlog_group_commit_sync_delay` 窗口内、由 `last_committed` 标记为同一组）在从库上可以安全并行——因为它们在主库上就是"同时提交"的，彼此没有锁冲突；
- **8.0 演进**：引入 `binlog_transaction_dependency_tracking`，可基于 `COMMIT_ORDER`（默认）、`WRITESET` 或 `WRITESET_SESSION` 决定依赖关系。`WRITESET` 模式下，只要**写的数据行集合（writeset）没有交集**，即使不是同一组提交也能并行——把并行度从"秒级窗口"提升到"行级无冲突"，对高并发无热点业务提升巨大。

### 5.3 并行复制的顺序保证

并行≠乱序。从库通过 **`last_committed`/`sequence_number`** 维护事务间的依赖边：只有某事务依赖的所有事务都应用完，它才会被调度执行（类似拓扑排序）。因此最终数据一致性有保证，只是同一时刻多个无依赖事务在并发应用。

## 六、GTID 下的主从切换实战

```
拓扑：A(主) ── B(从) ── C(从)
场景：A 宕机，提升 B 为新主
```

步骤（伪代码级）：

```bash
# 1. 在 B、C 上确认与 A 已同步（可选：等 retried_transactions 归零）
# 2. B 上：停止复制并清空旧主信息
STOP SLAVE;
RESET SLAVE ALL;          # 清掉旧的 master 信息（不会清数据）
# 3. B 提升为主：确保只读关闭、开启 binlog
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;
# 4. C 重新指向 B，自动定位
CHANGE MASTER TO MASTER_HOST='B', MASTER_AUTO_POSITION=1;
START SLAVE;
# 5. 应用层把写流量切到 B
```

切换后 C 的 `gtid_executed` 包含 A 的全部历史事务，B 也包含，因此差集为空或极小，C 无需重建即可追平——这就是 GTID 相对位点复制"切换零人工校对"的核心价值。

## 七、常见坑与面试追问

**坑 1：跳过某个出错事务**。位点时代用 `SET GLOBAL sql_slave_skip_counter=1`，GTID 时代会报错，正确姿势是**注入空事务**占掉 GTID：

```sql
STOP SLAVE;
SET GTID_NEXT='3E11FA47-71CA-11E6-9E97-0800278CA2A4:105'; -- 报错的那个事务
BEGIN; COMMIT;              -- 空事务，标记为已执行
SET GTID_NEXT='AUTOMATIC';
START SLAVE;
```

**坑 2：备份恢复要配 `gtid_purged`**。用 xtrabackup 恢复出的实例，其 `gtid_executed` 只到备份点；作为新从库接入时，需设置 `SET GLOBAL gtid_purged='旧主:1-100'` 告诉它"这些我虽然没有 binlog，但已经有了"，否则会从 1 开始重复拉取。

**坑 3：大事务放大延迟**。GTID 是事务级，一个大事务（如一次删 500 万行）在从库上仍是一个整体，无法拆分并行。

**面试追问清单**：

- GTID 由哪两部分组成？事务序号何时分配？（提交时，回滚不占号）
- `enforce_gtid_consistency=ON` 限制了哪些语句？为什么？
- 从库如何做到不重复执行同一事务？（gtid_executed 集合比对）
- LOGICAL_CLOCK 并行复制的依据是什么？WRITESET 为什么能进一步提高并行度？
- 位点复制 vs GTID 复制，切换时差在哪？
- GTID 模式下怎么跳过坏事务？

## 八、总结对比表

| 维度 | 位点复制 | GTID 复制 |
|---|---|---|
| 定位方式 | binlog 文件+偏移量 | 全局事务 ID 集合 |
| 从库去重 | 无（靠人工保证） | 天然跳过已执行 GTID |
| 主从切换 | 人工找位点，易出错 | AUTO_POSITION 自动对齐 |
| 级联复制 | 可配但管理复杂 | 集合传播，清晰 |
| 跳过坏事务 | `sql_slave_skip_counter` | 注入空事务 |
| 并行复制 | 均可配合 MTS | 与组提交/GTID 天然契合 |

一句话总结：**GTID 把复制从"物理坐标时代"带进了"逻辑账本时代"，配合组提交与 WRITESET 并行复制，是现代 MySQL 高可用架构（MHA、Orchestrator、MGR）的地基**。面试答到"事务级全局唯一 ID + 集合差集同步 + 组提交并行"，基本就过关了。
