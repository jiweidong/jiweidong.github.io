---
title: 【MySQL 底层】InnoDB 表空间体系深度解析：系统表空间、独立表空间、undo 与临时表空间的完整物理布局
date: 2026-09-19 08:00:00
tags:
  - MySQL
  - InnoDB
  - 存储引擎
  - 面试
categories:
  - MySQL
  - 数据库底层
author: 东哥
---

# 【MySQL 底层】InnoDB 表空间体系深度解析：系统表空间、独立表空间、undo 与临时表空间的完整物理布局

## 面试官：删了 2000 万行数据，为什么磁盘文件一点都没变小？

这是我被问过最多次的问题之一。候选人通常答"因为 InnoDB 是页管理的，删除只是打标记"。这个答案对了一半，但要真正说清楚，必须把 InnoDB 的**表空间（Tablespace）体系**讲透：数据到底存在哪个文件里、页怎么分配、空闲空间为什么不还给操作系统、`ibdata1` 为什么越涨越大。

表空间是 InnoDB 存储引擎的逻辑-物理映射层。它向上承接表、索引这些逻辑对象，向下管理文件、区、页这些物理单位。这篇文章从磁盘文件一路拆到页，把 InnoDB 的表空间体系完整梳理一遍。

## 一、先建立坐标系：从文件到行记录的六层结构

InnoDB 的数据组织是一条自顶向下的链路，理解这条链路，后面所有概念都能挂上去：

| 层级 | 名称 | 典型大小 | 说明 |
| --- | --- | --- | --- |
| 1 | 表空间 Tablespace | 文件级别 | 逻辑上可包含多张表，物理上对应一个或多个 `.ibd` 文件 |
| 2 | 段 Segment | 逻辑概念 | 一个索引对应两个段：叶子节点段 + 非叶子节点段 |
| 3 | 区 Extent | 1MB（64 个页） | 连续分配的页，减少随机 IO |
| 4 | 页 Page | 16KB（默认） | InnoDB 的最小 IO 单位 |
| 5 | 记录行 Row | 变长 | 按行格式（Compact/Dynamic）组织 |
| 6 | 字段 Column | 变长 | 大字段可能溢出到溢出页 |

关键点：**"段"不是物理文件，而是按区分配的连续空间集合**。所以一张表的 `orders.ibd` 文件里，数据页是"按区断续分布"的，不是全连续。

## 二、表空间家族的五个成员

### 1. 系统表空间（ibdata1）

由 `innodb_data_file_path` 控制，默认是 `ibdata1:12M:autoextend`。它承载：

- **数据字典**（MySQL 8.0 之前）：`SYS_TABLES`、`SYS_COLUMNS`、`SYS_INDEXES` 等，以 InnoDB 内部表形式存放。这也是"8.0 之前删表后 ibdata1 不缩小"的罪魁祸首——数据字典里留下了大量空洞。
- **双写缓冲（Doublewrite Buffer）**：默认仍在系统表空间（8.0.20+ 可独立为 `#ib_16384_N.dblwr` 文件）。页刷盘前先写到 doublewrite 区，防止页断裂（torn page）。
- **Change Buffer**（持久化部分，旧称 Insert Buffer）。
- **回滚段（Rollback Segment）**：当 `innodb_rollback_segments` 使用系统 undo 表空间时。

MySQL 8.0 起数据字典改为独立的 `mysql.ibd`，这是 8.0 最重要的存储层改动之一：不再需要 `frm` 文件，DDL 变成原子操作，`ibdata1` 也就不再随表数量线性膨胀。

```sql
-- 查看系统表空间配置
SHOW VARIABLES LIKE 'innodb_data_file_path';
-- 查看双写文件位置（8.0.20+）
SHOW VARIABLES LIKE 'innodb_doublewrite_dir';
SELECT * FROM information_schema.innodb_tablespaces;
```

### 2. 独立表空间（file-per-table）

`innodb_file_per_table=ON`（5.6.6 之后默认开启）时，每张表一个 `表名.ibd`，它包含：**该表的聚簇索引（即表数据）+ 所有二级索引 + 可选的溢出页**。

为什么强烈建议开启？三个理由：

1. `TRUNCATE TABLE` / `DROP TABLE` 可以直接删除文件，空间立刻归还操作系统；独立表空间下"删数据文件不缩小"的困扰轻很多。
2. 单表损坏只影响单表，恢复粒度小。
3. 支持 `OPTIMIZE TABLE` 真正重建文件来整理碎片。

```sql
-- 查表空间文件与占用
SELECT TABLE_NAME, ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS MB
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'shop' ORDER BY MB DESC LIMIT 10;

-- 真实物理文件大小（独立表空间）
-- ls -lh /var/lib/mysql/shop/orders.ibd
```

### 3. 通用表空间（General Tablespace）

8.0 引入的 `CREATE TABLESPACE`，一张表空间可以装多张表，且**支持多表共享物理文件**：

```sql
CREATE TABLESPACE ts_small ADD DATAFILE 'ts_small.ibd' ENGINE=InnoDB;
CREATE TABLE t_small (id INT PRIMARY KEY, v VARCHAR(32)) TABLESPACE ts_small;
```

适用场景：小表特别多（几万个配置表），file-per-table 会产生大量 `.ibd` 文件，`open_files_limit`、备份工具元数据管理都会成为瓶颈。通用表空间把它们打包进少量文件。

代价：`DROP TABLE` 只能回收表内空间给表空间复用，文件本身不缩小。另外通用表空间不支持 `ALTER TABLE ... DISCARD TABLESPACE`。

### 4. Undo 表空间

8.0 默认 `innodb_undo_tablespaces=2`，对应 `undo_001`、`undo_002` 两个文件。它存储 undo 日志，承担两个职责：

- **事务回滚**：把记录恢复到修改前版本。
- **MVCC 快照读**：为其他事务提供历史版本（配合 Read View）。

Undo 空间的膨胀是线上最常见的问题。长事务（哪怕只读、只是 `SELECT`）会让 purge 线程无法回收 undo，导致 undo 文件持续增长。

```sql
-- 查看 undo 表空间
SELECT * FROM information_schema.innodb_tablespaces WHERE name LIKE 'innodb_undo%';

-- 定位长事务（8.0 的 performance_schema 更精确）
SELECT trx_id, trx_state, trx_started, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS secs,
       trx_mysql_thread_id, trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started ASC;
```

线上治理要点：设置 `innodb_max_undo_log_size`、`innodb_undo_log_truncate=ON`，并在业务侧严格控制事务边界，杜绝"事务里调 RPC"。

### 5. 临时表空间

- **会话临时表空间** `ibtmp1`：`innodb_temp_data_file_path`，存用户临时表（`CREATE TEMPORARY TABLE`）。
- **共享临时表空间**：8.0 引入 `innodb_temp_tablespaces_dir`，存内部临时表（排序、`GROUP BY`、`UNION`、派生表物化）。之前我写过内部临时表的文章，这里只强调：它**只增不减**，实例重启才会释放。

```sql
SELECT * FROM information_schema.INNODB_SESSION_TEMP_TABLESPACES;
SHOW VARIABLES LIKE 'innodb_temp%';
```

## 三、区、页与"碎片"的真相

理解三件事，就能解释 90% 的"空间没释放"疑惑：

**第一，页内删除不打标记回收。** `DELETE` 只把记录置为删除并加入页内空闲链表（`PAGE_FREE`），页整体仍属于该索引。

**第二，空页不归还。** 当页全部删空，InnoDB 会把它从索引的段上"摘除"，放到表空间的 **FREE 链表**里，供本表空间后续插入复用。文件大小不变——因为文件是按需扩展的，InnoDB 不会自动收缩。

**第三，碎片分三类。**

| 碎片类型 | 成因 | 观测手段 | 治理 |
| --- | --- | --- | --- |
| 页内碎片 | 频繁删除导致的页内空洞 | `DATA_FREE` 偏大 | `OPTIMIZE TABLE` 重建 |
| 页间碎片 | 主键无序插入导致页分裂、页填充率低 | `INNODB_INDEX_STATS` | 改用有序主键 |
| 文件碎片 | 文件系统层面不连续 | `filefrag -v xxx.ibd` | 重建表 / 迁移 |

```sql
-- DATA_FREE 是表空间内空闲字节数，最能反映"可回收空间"
SELECT TABLE_NAME, DATA_FREE / 1024 / 1024 AS free_mb,
       ROUND(DATA_FREE / (DATA_LENGTH + INDEX_LENGTH + 1), 2) AS free_ratio
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'shop' AND DATA_FREE > 100 * 1024 * 1024;
```

当 `free_ratio > 0.5` 且确认无长事务、无活跃查询时，可以低峰期执行：

```sql
-- 8.0 的 OPTIMIZE TABLE 走 Online DDL，支持并发 DML（占用额外空间）
ALTER TABLE orders ENGINE=InnoDB, ALGORITHM=INPLACE, LOCK=NONE;
-- 或使用 gh-ost / pt-osc 在线重建，避免元数据锁风险
```

## 四、元数据与监控：常用 SQL 清单

```sql
-- 1. 所有表空间及其大小
SELECT name, space_type, row_format, ROUND(file_size/1024/1024,2) AS mb
FROM information_schema.INNODB_TABLESPACES ORDER BY file_size DESC;

-- 2. 表 ↔ 表空间 ↔ 文件映射
SELECT ts.name AS tablespace, tf.file_name, tf.total_extents,
       ROUND(tf.total_extents * 1024 * 1024 / 1024 / 1024, 2) AS size_mb
FROM information_schema.INNODB_TABLESPACES ts
JOIN information_schema.INNODB_DATAFILES tf ON ts.space = tf.space;

-- 3. 索引段/区信息
SELECT * FROM information_schema.INNODB_INDEXES WHERE name = 'orders';
-- 4. 每张表的压缩与行格式
SELECT table_name, row_format, create_options FROM information_schema.TABLES
WHERE table_schema='shop' LIMIT 10;
```

**磁盘水位告警**建议再加一层 OS 侧监控：`ibdata1`、`ibtmp1`、`undo_*`、`mysql.ibd` 单独观测。`ibtmp1` 突然暴涨通常是某个大查询把内部临时表落盘了——这是典型的"SQL 惹的祸，DBA 背的锅"。

## 五、常见事故场景复盘

**场景一：ibdata1 涨到 200GB 且无法回收。** 原因几乎总是：5.6/5.7 时代的数据字典 + 未开启 file-per-table + 长事务堆积。处置：`mysqldump` 逻辑重建（`innodb_data_file_path` 无法在线收缩），别无他法。这也是升级到 8.0 最强的动力。

**场景二：undo 表空间撑爆磁盘。** 现象是 `undo_001` > 100GB，根因是夜间跑批事务未提交或常驻 `SELECT` 未结束。处置：`innodb_undo_log_truncate` + 强杀长事务 + 事务边界重构。

**场景三：`ibtmp1` 膨胀到 500GB。** 某条 `GROUP BY` 大表查询无索引，内部临时表落盘。处置：重启释放（或 `RESET` 临时表空间），并从 SQL 层加索引/改写。

**场景四：磁盘满导致实例挂起。** `innodb_fatal_semaphore_wait_timeout` 触发、写操作全部 `ER_DISK_FULL`。止血手段：挑大表 `TRUNCATE`/删历史分区，把水位先降到 80% 以下。

## 六、面试常见追问

**Q1：为什么 InnoDB 页大小是 16KB？**
折中结果：太小则 B+ 树层数多、IO 次数多；太大则页内修改的写放大严重、缓冲池管理粒度粗。16KB 配合一个区 64 页 = 1MB，与文件系统预读策略配合良好。

**Q2：一个区为什么是 64 个页？**
1MB 的连续空间在机械盘上读取消代价低，同时又能让 B+ 树叶子节点尽量连续。InnoDB 对小于 1MB 的表还有"碎片区"（fragment extent）优化，按页而非按区分配，避免小表浪费 1MB。

**Q3：`innodb_file_per_table=ON` 后，`ibdata1` 还有用吗？**
有。双写缓冲、Change Buffer、回滚段（若未独立）仍在里面，只是不再随表数量增长。所以它应该稳定在一个合理区间（通常几 GB 以内）。

**Q4：`DELETE` 全表和 `TRUNCATE` 的区别（存储层面）？**
`DELETE` 逐行删、产生 undo/binlog、留下空洞，文件不变小；`TRUNCATE` 是 DDL，直接重建空表空间文件，秒级完成且立刻释放磁盘，但不可回滚、不触发触发器。

**Q5：主键为什么推荐自增/有序？**
乱序主键（UUID）会让插入随机落在 B+ 树不同叶子页上，触发大量页分裂，页填充率降到 ~50%，表空间里全是"页间碎片"。有序主键永远追加在最右叶子，页分裂极少。这是**存储层**对主键设计最硬的约束。

**Q6：通用表空间和独立表空间怎么选？**
默认独立表空间。小表数量 > 1 万、备份工具被文件数拖累时，才把一批小表收进通用表空间统一管理。

## 七、生产环境的最佳实践清单

1. **必须开启** `innodb_file_per_table=ON`，这是空间可治理的前提。
2. MySQL **8.0 是底线**，数据字典独立后，DDL 原子性与 `ibdata1` 膨胀问题从根上缓解。
3. **独立 undo 表空间** + `innodb_undo_log_truncate=ON`，并监控 `History list length`。
4. **事务边界要短**：禁止在事务中做远程调用、批量循环提交要改成分批。
5. 对 `DATA_FREE` 和四类表空间文件做**容量水位告警**，别等磁盘满。
6. 大表重建用 `gh-ost` / `pt-osc`，避免 `ALTER` 引发的元数据锁雪崩。
7. 定期做**表空间体检**：单表超过 500GB 就要考虑冷热分离或归档（我之前写过冷热分离方案，可以配合使用）。

## 总结

InnoDB 的表空间体系是"逻辑对象 → 段 → 区 → 页 → 行"这条链路的物理落点：

- **系统表空间**承载双写、Change Buffer 与回滚段，8.0 后不再装数据字典；
- **独立表空间**是默认形态，让 `DROP`/`TRUNCATE` 能真正释放空间；
- **通用表空间**解决小表文件数爆炸；
- **undo 表空间**是 MVCC 与回滚的基石，也是长事务的"罪证记录仪"；
- **临时表空间**只增不减，是最容易被忽视的磁盘黑洞。

"删了数据磁盘不变小"的本质是：**删除只回收页内空间到表空间内部的 FREE 链表，文件不会自动收缩**。要走 "重建文件" 的路子才能把空间还给操作系统——而在动手之前，先确认没有长事务和活跃查询，否则只会把一次空间问题升级成一次锁事故。
