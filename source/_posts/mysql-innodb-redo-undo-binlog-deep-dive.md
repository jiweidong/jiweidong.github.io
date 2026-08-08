---
title: 【MySQL 底层】InnoDB 三大日志深度解析：redo log、undo log 与 binlog 的协作与恢复
date: 2026-08-08 08:00:00
tags:
  - MySQL
  - InnoDB
  - redo log
  - undo log
  - binlog
  - 面试
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 底层】InnoDB 三大日志深度解析：redo log、undo log 与 binlog 的协作与恢复

## 面试官：一条 UPDATE 语句在 InnoDB 里是怎么执行的？宕机了数据怎么不丢？

这是 MySQL 面试的"必考压轴题"。要答好它，必须吃透 InnoDB 的**三大日志**：redo log（重做日志）、undo log（回滚日志）和 binlog（归档日志）。它们分别解决了崩溃恢复、事务回滚、主从复制三个核心问题。

本文从一条 UPDATE 的执行链路讲起，深入源码与磁盘结构，最后用"两阶段提交"串起整个故事。

<!-- more -->

## 一、先看全局：一条 UPDATE 的执行链路

```sql
UPDATE user SET age = 30 WHERE id = 1;
```

这条语句在 InnoDB 中的完整执行流程：

```
1. 连接器：校验权限
2. 分析器：词法/语法解析
3. 优化器：选择索引，生成执行计划
4. 执行器：调用 InnoDB 引擎接口
   │
   ├─ ① 从 Buffer Pool 读取 id=1 的页（若不在则从磁盘加载）
   ├─ ② 在 undo log 中写入"修改前的旧值"（记录反向操作）
   ├─ ③ 在 Buffer Pool 中修改 age=30（脏页，内存中）
   ├─ ④ 写 redo log（记录"页 xxx 的偏移 xxx 被改为 30"）— prepare 阶段
   ├─ ⑤ 写 binlog（记录这条 SQL 的逻辑变更）— commit 阶段
   ├─ ⑥ redo log 标记 commit，事务提交完成
   └─ ⑦ 后台线程择机把脏页刷盘（不是提交时刷！）
```

**关键结论：提交事务时只保证"日志落盘"，不保证"数据页落盘"。** 数据页是后台异步刷的，这就是 redo log 存在的根本原因。

## 二、redo log：崩溃恢复的保障

### 2.1 为什么需要 redo log？

InnoDB 的数据以 **页（Page，默认 16KB）** 为单位存放在磁盘。如果每次修改都同步刷盘：
- 随机 IO 性能极差（页是 16KB，但只改其中几个字节）；
- 无法承受每次提交都 fsync 的延迟。

于是 InnoDB 采用 **WAL（Write-Ahead Logging，预写日志）** 策略：**先写日志，再写数据**。事务提交时只需要把很小的 redo log 刷盘（顺序 IO），数据页留在 Buffer Pool 里慢慢刷。宕机后，用 redo log 重放未落盘的修改。

### 2.2 redo log 的物理特性

| 特性 | 说明 |
| --- | --- |
| 记录内容 | 物理日志：`页号 + 页内偏移 + 修改后的值` |
| 所属层级 | InnoDB 引擎层 |
| 存储位置 | `ib_logfile0`、`ib_logfile1`（默认 48MB × 2，可配置） |
| 写入方式 | 顺序追加写，环形复用 |
| 刷盘时机 | 事务提交时（innodb_flush_log_at_trx_commit=1） |

### 2.3 环形结构与 checkpoint

redo log 是**环形**的：`write pos` 是当前写入位置，`checkpoint` 是已刷盘数据对应的日志位置：

```
|←—— 可覆盖区域 ——→|←———— 待刷盘区域（redo） ————→|
checkpoint          write pos
```

- `write pos` 追上 `checkpoint` 时，说明 redo log 写满，必须强制把 Buffer Pool 中的脏页刷盘，推进 checkpoint；
- 所以 **redo log 大小要够大**，否则频繁触发刷盘，性能骤降（生产中常见 1GB~4GB 一组）。

### 2.4 刷盘策略对比

| innodb_flush_log_at_trx_commit | 行为 | 安全性 | 性能 |
| --- | --- | --- | --- |
| 0 | 每秒刷一次，提交不刷 | 最差：宕机丢 1 秒数据 | 最快 |
| 1 | 每次提交都刷盘 | 最好：不丢已提交事务 | 最慢（默认值） |
| 2 | 提交时写入 OS 缓存，每秒刷盘 | 中：OS 宕机丢 1 秒，MySQL 宕机不丢 | 较快 |

## 三、undo log：回滚与 MVCC 的基石

### 3.1 undo log 是什么

undo log 记录的是**逻辑日志（反向操作）**：

| 操作 | undo 记录 |
| --- | --- |
| INSERT | 记录主键，回滚时 DELETE 该行 |
| UPDATE | 记录修改前的旧值，回滚时恢复旧值 |
| DELETE | 记录删除前的完整行，回滚时重新插入 |

### 3.2 两个核心作用

**作用一：事务回滚（ROLLBACK）**

```sql
BEGIN;
UPDATE user SET age = 30 WHERE id = 1;  -- undo: age 旧值 20
INSERT INTO order VALUES(...);          -- undo: 主键 xxx 的插入
ROLLBACK;  -- 按 undo log 逆序执行反向操作
```

**作用二：MVCC 多版本控制（重点！）**

undo log 还承担了 MVCC 的版本链：每一行数据都有一个隐藏列 `DB_ROLL_PTR`（回滚指针），指向该行在 undo log 中的旧版本。同一行的多个版本通过 undo log 串成一条**版本链**：

```
age=30 (当前值)  ←DB_ROLL_PTR—  age=20  ←DB_ROLL_PTR—  age=10 (最初)
   (trx_id=102)               (trx_id=101)             (trx_id=100)
```

读操作根据 `ReadView`（活跃事务列表）沿版本链找到**对当前事务可见的版本**，实现：

- **快照读**（普通 SELECT）：不加锁，读历史版本 → RR 下可重复读；
- **当前读**（SELECT ... FOR UPDATE / UPDATE / DELETE）：读最新版本并加锁。

> **面试追问：为什么 RR 隔离级别下，快照读不会出现幻读？** 因为快照读基于 ReadView + 版本链，整个事务内 ReadView 不变，读到的始终是事务开始时的快照；而当前读靠**间隙锁**（Gap Lock）防止幻读。两种机制配合，RR 才彻底解决了幻读。

### 3.3 undo log 的清理与回滚段

- undo log 存放在 **回滚段（Rollback Segment）** 中，对应 `ibdata1` 或独立的 undo 表空间；
- 事务提交后，undo log 不会立即删除——要等**没有事务的 ReadView 再引用它**时，由 purge 线程清理；
- 长事务是 undo log 膨胀的元凶（也是大事务拖垮磁盘空间和查询性能的原因）。

## 四、binlog：归档与复制的担当

### 4.1 binlog 与 redo log 的区别

| 维度 | redo log | binlog |
| --- | --- | --- |
| 所属层级 | InnoDB 引擎层 | MySQL Server 层 |
| 记录内容 | 物理日志（页+偏移+值） | 逻辑日志（SQL 语句或行变更） |
| 记录范围 | 仅 InnoDB 表的修改 | 所有引擎、所有 DDL/DML |
| 写入方式 | 环形覆盖 | 追加写，全量保留 |
| 用途 | 崩溃恢复 | 主从复制、数据恢复、审计 |

**binlog 的三种格式：**

| 格式 | 内容 | 优点 | 缺点 |
| --- | --- | --- | --- |
| STATEMENT | 原始 SQL | 日志小 | 非确定性函数（NOW()）导致主从不一致 |
| ROW（默认） | 行变更前后值 | 最精确，主从一致 | 日志大 |
| MIXED | 自动切换 | 折中 | 复杂场景仍需注意 |

### 4.2 两阶段提交：为什么必须有？

redo log 和 binlog 是**两个独立的日志**，如果不做协调，宕机会导致主从不一致：

**场景**：先写 redo log 后写 binlog，写 binlog 前宕机 → 主库恢复了修改，从库没收到 → 主从不一致。

解决方式：**两阶段提交（2PC）**

```
写入 redo log（prepare 状态）──→ 写入 binlog ──→ 提交事务（redo log 标记 commit）
```

1. **prepare**：redo log 写入并刷盘，状态为 prepare；
2. **写 binlog**：binlog 写入并刷盘；
3. **commit**：redo log 标记为 commit。

**崩溃恢复时的判断规则**（关键）：

| 崩溃位置 | 判断依据 | 处理 |
| --- | --- | --- |
| prepare 后、binlog 前 | redo 是 prepare，binlog 无记录 | 回滚事务 |
| binlog 写完后 | redo 是 prepare，但 binlog 有完整记录 | **提交事务**（保证主从不丢） |

也就是说：**binlog 写完了就一定要提交**，这样从库能重放、主库也提交，两边一致。这也是为什么 binlog 必须在 redo prepare 之后、commit 之前写入。

## 五、宕机恢复流程（Crash Recovery）完整梳理

MySQL 宕机重启后，InnoDB 的恢复步骤：

```
1. 扫描 redo log，从 checkpoint 位置开始重放：
   - redo 状态为 commit 的事务 → 直接重放完成
   - redo 状态为 prepare 的事务 → 查 binlog：
       · binlog 完整 → 提交（重放）
       · binlog 缺失 → 回滚（用 undo log 恢复旧值）
2. undo log 中未提交事务的反向操作被执行，回滚
3. Buffer Pool 中的脏页按 LSN 与磁盘页比对，决定刷盘还是重放
```

整个恢复过程对业务**完全透明**，这就是 WAL + 两阶段提交带来的可靠性。

## 六、生产实践与排查

### 6.1 参数建议

```ini
# 每次提交都刷 redo，绝不丢已提交事务
innodb_flush_log_at_trx_commit = 1
# 每次提交都刷 binlog（与上一条配合，才能保证主从不丢）
sync_binlog = 1
# redo log 大小：写入量大的库建议 1G~4G，避免频繁 checkpoint
innodb_log_file_size = 1G
```

> **注意**：`innodb_flush_log_at_trx_commit=1` 与 `sync_binlog=1` 同时开启会显著降低写入吞吐（每次提交两次 fsync），但这是"不丢数据"的底线配置。可接受少量丢失的场景（如日志库）可以适当放宽。

### 6.2 日志相关排查命令

```sql
-- 查看 redo log 配置
SHOW VARIABLES LIKE 'innodb_log%';
-- 查看 binlog 配置
SHOW VARIABLES LIKE 'log_bin%';
SHOW BINARY LOGS;                    -- 列出 binlog 文件
SHOW MASTER STATUS;                  -- 当前 binlog 位置（主从定位用）
-- 用 mysqlbinlog 解析 binlog（恢复误删数据）
mysqlbinlog --start-datetime="2026-08-08 00:00:00" binlog.000012
```

### 6.3 经典故障：误删数据恢复思路

1. 找到误操作前的 binlog 文件与 position；
2. 用 `mysqlbinlog` 导出该时间段日志，**剔除**误操作的 SQL；
3. 将剩余 SQL 重放到一个临时实例；
4. 从临时实例导出受影响的数据，导回生产。

## 七、总结：一张图记住三大日志

| 日志 | 一句话职责 | 写什么 | 什么时候写 |
| --- | --- | --- | --- |
| **redo log** | 崩溃恢复，防"数据没刷盘就宕机" | 物理变更（页+偏移+值） | 事务提交前（WAL） |
| **undo log** | 回滚 + MVCC 版本链 | 逻辑反向操作（旧值） | 数据修改前 |
| **binlog** | 主从复制 + 归档恢复 | 逻辑变更（SQL/行） | 事务提交时（2PC 中） |

**终极面试回答模板**：一条 UPDATE 的执行，先写 undo 记录旧值，再改 Buffer Pool，事务提交时按 WAL 先刷 redo（prepare），再写 binlog，最后 redo 标记 commit（两阶段提交保证主从不一致时能正确裁决）；数据页由后台线程异步刷盘，宕机时靠 redo 重放 + undo 回滚完成恢复。三大日志各司其职：redo 保"持久性"，undo 保"原子性 + 隔离性"，binlog 保"复制与归档"。
