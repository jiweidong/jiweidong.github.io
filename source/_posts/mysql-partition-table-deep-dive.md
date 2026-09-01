---
title: 【MySQL 进阶】MySQL 分区表深度解析：从 Range/List/Hash/Key 分区原理到落地实践与避坑指南
date: 2026-09-01 08:00:00
tags:
  - MySQL
  - 数据库
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 进阶】MySQL 分区表深度解析：从 Range/List/Hash/Key 分区原理到落地实践与避坑指南

## 面试官：你们公司几千万行的表是怎么优化的？你会考虑分区表吗？

很多同学一上来就说「分库分表」，但分库分表带来的分布式事务、跨库 JOIN、全局主键等问题，对于大部分业务来说其实是**过度设计**。在数据量还没到亿级、但单表已经明显变慢的阶段，**MySQL 分区表（Partitioning）** 是一个成本极低、效果直接的方案。

本文从分区表的底层原理讲起，对比四种分区类型，最后给出生产环境的落地实践与避坑指南。

## 一、分区表是什么？它到底解决了什么问题？

### 1.1 逻辑上一张表，物理上是多个文件

分区表在 SQL 层面和普通表**完全一样**，你照样 `SELECT`、`INSERT`、`UPDATE`、`JOIN`，但在存储层面，数据被拆散到多个物理文件中：

```
# 未分区：一个表一个文件（假设 MyISAM/独立表空间）
order.ibd

# 按年份 Range 分区：一个分区一个文件
order#P#p2023.ibd
order#P#p2024.ibd
order#P#p2025.ibd
```

查询时，优化器会做**分区裁剪（Partition Pruning）**：只扫描命中的分区文件，而不是全表扫。

### 1.2 分区解决的核心痛点

| 痛点 | 分区表的作用 |
|---|---|
| 单表数据量太大，查询慢 | 分区裁剪减少扫描数据量 |
| 删除历史数据慢（`DELETE` 上亿行） | `DROP PARTITION` 秒删，不走 binlog 逐行删 |
| 归档数据难维护 | 按时间分区，直接卸掉旧分区文件 |
| 索引膨胀、缓存命中率低 | 每个分区独立 B+ 树，索引更小 |

**注意**：分区表不是万能的。它并不能让单条 SQL 变得更快——如果你的查询条件不带分区键，优化器只能扫描所有分区，性能反而可能更差。

## 二、四种分区类型详解

### 2.1 RANGE 分区（最常用）

按连续区间划分，**业务上 90% 的分区表都是 RANGE 分区**，尤其是按时间：

```sql
CREATE TABLE order_info (
    id BIGINT NOT NULL,
    order_no VARCHAR(32) NOT NULL,
    user_id BIGINT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    create_time DATETIME NOT NULL,
    PRIMARY KEY (id, create_time)   -- 注意：分区键必须包含在主键/唯一键中！
) PARTITION BY RANGE (YEAR(create_time)) (
    PARTITION p2023 VALUES LESS THAN (2024),
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p_future VALUES LESS THAN MAXVALUE   -- 兜底分区
);
```

关键点：

- **`VALUES LESS THAN` 是左闭右开区间**，`LESS THAN (2024)` 包含 2023 年所有数据。
- 插入的数据如果落在任何分区范围之外（且没有 `MAXVALUE` 兜底），会直接报错：
  ```
  ERROR 1526 (HY000): Table has no partition for value ...
  ```
- 分区键必须是**整数**，或者能通过 `YEAR()`、`TO_DAYS()`、`TO_SECONDS()` 等函数转换为整数。
- 查询时带上 `create_time` 条件才能触发分区裁剪。

### 2.2 LIST 分区

按**离散值列表**划分，适合地区、状态、类型这种枚举值：

```sql
CREATE TABLE user_login_log (
    id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    login_region VARCHAR(16) NOT NULL,
    login_time DATETIME NOT NULL,
    PRIMARY KEY (id, login_region)
) PARTITION BY LIST COLUMNS (login_region) (
    PARTITION p_north VALUES IN ('北京','天津','河北'),
    PARTITION p_south VALUES IN ('广东','深圳','海南'),
    PARTITION p_other VALUES IN ('其他')
);
```

`LIST COLUMNS` 是 `LIST` 的增强版，支持字符串、日期、多列，比 `LIST`（仅整数）实用得多。

### 2.3 HASH 分区（含 KEY 分区）

按哈希函数取模均匀分布，适合**没有自然分区键、但想分散 IO** 的场景：

```sql
CREATE TABLE access_log (
    id BIGINT NOT NULL AUTO_INCREMENT,
    app_id INT NOT NULL,
    log_content TEXT,
    create_time DATETIME NOT NULL,
    PRIMARY KEY (id, app_id)
) PARTITION BY HASH (app_id) PARTITIONS 8;
```

- `HASH`：对整数分区键做取模（`MOD(app_id, 8)`）。
- `KEY`：对字符串分区键做 MySQL 内置哈希（`MD5` 类似），**支持字符串、非整数列**，比 `HASH` 更通用：

```sql
) PARTITION BY KEY (user_id) PARTITIONS 16;
```

HASH/KEY 分区的特点：

- 数据均匀分布，**但没有分区裁剪的价值**——查单条数据时要先算出它在哪个分区，等于全分区找一遍，IO 反而可能更多。
- 适合「均匀写入、随机读取」的场景（如日志表按 ID 分散）。
- 分区数建议取 **2 的幂**（2、4、8、16），数据分布更均匀。

### 2.4 分区类型对比表

| 分区类型 | 分区键要求 | 数据分布 | 典型场景 | 分区裁剪效果 |
|---|---|---|---|---|
| RANGE | 整数或可转整数 | 按区间 | 时间、金额区间 | ⭐⭐⭐ 极好 |
| RANGE COLUMNS | 字符串/日期/多列 | 按区间 | 按时间字符串分区 | ⭐⭐⭐ 极好 |
| LIST | 整数 | 按枚举值 | 地区、状态 | ⭐⭐ 好 |
| LIST COLUMNS | 字符串/多列 | 按枚举值 | 地区（中文） | ⭐⭐ 好 |
| HASH | 整数 | 均匀 | 日志、随机读写 | ⭐ 无裁剪价值 |
| KEY | 任意类型 | 均匀 | 字符串 ID 分散 | ⭐ 无裁剪价值 |

## 三、分区裁剪（Partition Pruning）的底层原理

这是分区表性能的核心。看一条查询：

```sql
EXPLAIN SELECT * FROM order_info WHERE create_time >= '2024-01-01' AND create_time < '2025-01-01';
```

在未分区表上，`EXPLAIN` 的 `rows` 是几千万；在分区表上，`EXPLAIN` 会显示：

```
+----+-------------+-------------+-------------+------+---------------+
| id | select_type | table      | partitions | type | rows          |
+----+-------------+-------------+-------------+------+---------------+
|  1 | SIMPLE      | order_info | p2024      | ALL  | 1250000       |
```

`partitions` 列只显示了 `p2024`——这就是**裁剪生效**了，扫描量从 5000 万行降到 125 万行。

### 3.1 哪些写法能触发裁剪？

```sql
-- ✅ 可以：分区键直接比较
WHERE create_time >= '2024-01-01'
WHERE create_time BETWEEN '2024-01-01' AND '2024-12-31'
WHERE YEAR(create_time) = 2024          -- 分区键套函数但能被优化

-- ❌ 不行：分区键被函数包裹（无法反推区间）
WHERE YEAR(create_time) + 1 = 2025
WHERE create_time - INTERVAL 1 DAY >= '2024-01-01'

-- ❌ 不行：条件里没有分区键
WHERE order_no = 'SN20240101001'
```

**经验法则**：分区键上不要做「不可逆」的运算。`YEAR()`、`TO_DAYS()` 这类单调函数 MySQL 能识别，但 `+ 1`、`- INTERVAL` 这种就识别不了。

### 3.2 分区键必须包含在主键/唯一键中！

这是新手最容易踩的坑：

```sql
-- ❌ 报错：A PRIMARY KEY must include all columns in the table's partitioning function
CREATE TABLE t (id BIGINT PRIMARY KEY, create_time DATETIME)
PARTITION BY RANGE (YEAR(create_time)) (...);

-- ✅ 正确：主键改成 (id, create_time) 联合主键
CREATE TABLE t (id BIGINT, create_time DATETIME, PRIMARY KEY (id, create_time))
PARTITION BY RANGE (YEAR(create_time)) (...);
```

原因：**InnoDB 二级索引必须包含主键列**，而分区键需要能被唯一索引唯一定位到某个分区，否则无法保证唯一性。

**生产建议**：如果你的业务主键是 `id` 且不想改，可以考虑「分区键不进主键」的替代方案——把分区键作为普通索引列，用 `id` 做自增主键 + 分区键做普通索引。但注意：**只要分区键不在主键里，你就无法用主键做唯一约束**……实际上这是不允许的，上面说了必须包含。所以要么改联合主键，要么放弃分区。

## 四、分区表的运维实战

### 4.1 按年/月维护分区（生产常用套路）

用存储过程或定时任务自动加分区：

```sql
-- 每月 1 号执行：提前建好下个月的分区
ALTER TABLE order_info
    ADD PARTITION (
        PARTITION p202606 VALUES LESS THAN (2026-06-01)  -- 伪代码，实际用 TO_DAYS
    );
```

更稳妥的做法是维护一个「未来 N 个月分区 + 兜底 MAXVALUE」的结构，兜底分区保证数据不会写不进去，定时任务负责把兜底分区拆细。

### 4.2 秒删历史数据：DROP PARTITION

```sql
-- 删除 2023 年的所有数据：不产生海量 binlog，不锁长事务
ALTER TABLE order_info DROP PARTITION p2023;
```

对比 `DELETE FROM order_info WHERE create_time < '2024-01-01'`：

| 方式 | 耗时（1 亿行） | 对主从的影响 | binlog 大小 |
|---|---|---|---|
| DELETE 逐行删 | 数小时 | 主从延迟巨大 | 几十 GB |
| DROP PARTITION | 秒级 | 几乎无感 | 几乎为 0 |

这就是归档系统最爱分区表的原因：**删除=卸载文件**。

### 4.3 分区表 + 冷热数据分离

配合「旧分区只读」的思路：

```sql
-- 把旧分区移到归档表（重建表结构但只保留旧分区）
CREATE TABLE order_info_archive LIKE order_info;
ALTER TABLE order_info_archive REMOVE PARTITIONING;   -- 归档表可以不用分区
INSERT INTO order_info_archive SELECT * FROM order_info PARTITION (p2023);
```

## 五、分区表的坑（血泪总结）

### 坑 1：分区数量上限

MySQL 单表最多 **8192 个分区**（8.0 之前是 1024）。按天分区一年就 365 个，三年就超了。**生产建议按月分区**，而不是按天。

### 坑 2：分区键上的索引使用受限

- 每个分区都是独立的 B+ 树，**二级索引是「本地索引」**——跨分区查询唯一索引时，要在每个分区各查一遍。
- 如果查询条件没有分区键，等于把一张大表拆成 N 张小表各扫一遍，`type` 可能从 `ref` 退化成 `ALL`，性能反而更差。

### 坑 3：DDL 操作会锁全表（8.0 的优化也有限）

对分区表执行 `ALTER TABLE ... ADD COLUMN` 之类的 DDL，**即使是 8.0 的 instant DDL，也未必能对所有分区生效**。生产环境改分区表结构，建议用 `pt-online-schema-change` 或 gh-ost。

### 坑 4：分区键不能更新

`UPDATE` 语句**不允许修改分区键的值**，否则报错：

```sql
-- ❌ ERROR 1563: Partition column cannot be updated
UPDATE order_info SET create_time = '2025-01-01' WHERE id = 100;
```

### 坑 5：自增主键 + 分区键的组合

上面说了分区键必须进主键，但如果你的主键是自增 `id`，改成 `(id, create_time)` 联合主键后，**自增列必须是最左前缀**，否则 `AUTO_INCREMENT` 不生效（报 `Incorrect table definition`）。

### 坑 6：NULL 值的处理

- RANGE 分区：`NULL` 会被放进**最小的分区**。
- LIST 分区：`NULL` 只有在列表里显式包含时才允许。
- HASH/KEY：`NULL` 按 0 处理。

业务上如果分区键允许 `NULL`，记得用 `NOT NULL` 约束兜底。

## 六、分区表 vs 分库分表，怎么选？

| 维度 | 分区表 | 分库分表（ShardingSphere 等） |
|---|---|---|
| 改造难度 | SQL 无感知，仅 DDL 改造 | 需要改代码、改 SQL、改主键策略 |
| 单表数据量上限 | 受 8192 分区限制，单分区建议 <2000 万行 | 理论无上限 |
| 跨分区查询 | 自动聚合，但慢 | 需要中间件聚合，且不支持跨库事务 |
| 分布式事务 | 不需要 | 需要 TCC/SAGA/柔性事务 |
| 运维复杂度 | 低（一个实例） | 高（多实例、数据迁移、扩容） |
| 适用数据量 | 千万 ~ 亿级 | 亿级 ~ 百亿级 |

**结论**：数据量在千万到 1~2 亿、且查询基本都带时间/地区等分区键的，**优先分区表**；到了「单表拆了也扛不住写入 QPS」「需要跨实例扩展」的阶段，再上分库分表。

## 七、面试连环追问

**Q1：分区表能让单条查询一定变快吗？**
不能。只有命中分区裁剪才快；不带分区键的查询反而更慢（多分区扫描 + 本地索引失效）。

**Q2：为什么分区键必须在主键里？**
InnoDB 二级索引叶子节点存主键值，唯一性校验需要先定位分区；分区键不在唯一索引里就无法保证「唯一」的语义，所以强制要求分区键包含在所有唯一键中。

**Q3：分区和分表的本质区别？**
分区是**单实例内的物理存储拆分**，数据还在同一台机器；分表（分库分表）是**跨实例的逻辑拆分**，数据分布到不同机器。分区解决「表太大」的问题，分表解决「单机扛不住」的问题。

**Q4：日增量 100 万行、保留 3 年，分区表怎么设计？**
按月 RANGE 分区（`TO_DAYS(create_time)` 或 `YEAR`），共 36 个分区 + 1 个 MAXVALUE 兜底；定时任务每月提前建未来 1~2 个分区；归档时 `DROP PARTITION` 或搬到归档表。单分区数据量约 3000 万行，在 InnoDB 合理范围内。

## 总结

分区表是 MySQL 给的「低成本高性能」方案：**RANGE 按时间裁剪查询、DROP PARTITION 秒删历史、物理文件分离便于归档**。但它有严格约束（分区键进主键、不能更新分区键、8192 分区上限），用之前一定要想清楚查询模式是否带分区键。记住一句话：**分区表是给「查询模式稳定」的表用的，不是给「什么都查」的表用的**。
