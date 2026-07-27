---
title: 【MySQL优化】索引下推（ICP）与索引跳跃扫描（Skip Scan）深度解析：从原理到实战
date: 2026-07-27 08:00:00
tags:
  - MySQL
  - 索引优化
  - ICP
  - Skip Scan
categories:
  - MySQL
  - 数据库优化
author: 东哥
---

# 【MySQL优化】索引下推（ICP）与索引跳跃扫描（Skip Scan）深度解析：从原理到实战

## 前言

在日常 SQL 优化中，索引下推（Index Condition Pushdown，简称 ICP）和索引跳跃扫描（Index Skip Scan）是 MySQL 5.6 / 8.0 引入的两大重要优化特性。很多开发者知道它们的名字，但对其底层原理、适用场景和限制条件却一知半解。

本文将从**执行计划分析 → 源码级原理 → 实战案例**三个维度，彻底搞懂这两个优化特性。

---

## 一、索引下推（ICP）

### 1.1 什么是索引下推？

在没有 ICP 之前，MySQL 在使用**二级索引**进行查询时，存储引擎层（InnoDB）只根据索引列条件来定位记录，然后将完整行记录返回到 Server 层，Server 层再对剩余的 WHERE 条件进行过滤。

有了 ICP 之后，MySQL 将部分 WHERE 条件下推到**存储引擎层**，在读取索引记录时就直接进行条件过滤，减少了回表次数和数据传输量。

{% asset_img icp-architecture.png ICP架构示意图 %}

### 1.2 ICP 的适用条件

| 条件 | 说明 |
|------|------|
| 存储引擎 | InnoDB 和 MyISAM 支持（主要是 InnoDB） |
| 索引类型 | **二级索引**（辅助索引），**聚簇索引无效** |
| WHERE 条件 | 必须能部分用索引过滤，部分不能 |
| 查询类型 | range、ref、eq_ref、ref_or_null 等 |
| 不支持情况 | 子查询条件、非 INNODB 表、全文索引 |
| MySQL版本 | >= 5.6 |

### 1.3 深入原理：ICP 是如何实现的？

假设有如下表和索引：

```sql
CREATE TABLE `employees` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL,
  `age` int NOT NULL,
  `dept` varchar(20) NOT NULL,
  `salary` decimal(10,2) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_name_age` (`name`, `age`)
) ENGINE=InnoDB;
```

执行查询：

```sql
SELECT * FROM employees 
WHERE name LIKE '张%' AND age > 30;
```

**无 ICP 的执行流程（MySQL 5.5）：**

1. 存储引擎使用 idx_name_age 索引找到 name LIKE '张%' 的记录
2. **回表**获取完整行数据
3. 返回 Server 层
4. Server 层对 age > 30 进行过滤
5. 将满足条件的行返回客户端

**有 ICP 的执行流程（MySQL 5.6+）：**

1. 存储引擎使用 idx_name_age 索引找到 name LIKE '张%' 的记录
2. 直接在索引层面判断 age > 30（**索引已包含 age 列**）
3. 只对满足 age > 30 的记录进行回表
4. 回表后直接返回 Server 层，不再额外过滤

**关键差异**：ICP 将过滤从 Server 层下推到存储引擎层，在索引数据上直接做过滤，**减少回表次数**。

### 1.4 ICP 源码层面的实现机制

在 MySQL 源码中（sql/ha_innodb.cc），ICP 通过 `row_search_mvcc()` 函数实现：

```
row_search_mvcc():
  → 遍历 B+ 树索引页
  → 对于每条索引记录，调用 idx_cond_check() 
  → 如果索引条件不满足，直接跳过（无需回表）
  → 只有满足条件的记录才进入回表流程
```

关键接口是 `set_hp_key_equal_filters()` 和 `push_cond_to_handler()`，Server 层将 WHERE 条件下推到 handler 层。

### 1.5 ICP 实战案例分析

```sql
-- ICP 适用场景（使用二级索引且部分条件无法用索引覆盖）
EXPLAIN SELECT * FROM employees 
WHERE name LIKE '张%' AND age > 30 AND salary > 10000;
```

查看执行计划：

```
id | select_type | table     | type | key          | Extra
1  | SIMPLE      | employees | ref  | idx_name_age | Using index condition
```

`Using index condition` 就表示使用了 ICP。

再看一个**不适用**的例子：

```sql
-- 主键查询不会触发 ICP（因为主键就是聚簇索引，不需要回表）
EXPLAIN SELECT * FROM employees WHERE id > 100 AND age > 30;
```

```
id | select_type | table     | type | key  | Extra
1  | SIMPLE      | employees | range| PRIMARY | Using where
```

### 1.6 如何关闭 ICP？

```sql
-- 会话级别关闭
SET optimizer_switch = 'index_condition_pushdown=off';

-- 查询当前状态
SHOW VARIABLES LIKE 'optimizer_switch';
```

---

## 二、索引跳跃扫描（Index Skip Scan）

### 2.1 什么是 Skip Scan？

Skip Scan 是 MySQL 8.0.13 引入的优化特性。它允许 MySQL 在**复合索引的非最左前缀列**上进行范围扫描，而不需要 WHERE 条件必须包含索引的最左列。

传统认知中，复合索引`(a, b, c)`遵循**最左前缀原则**——如果 WHERE 条件没有用到 a，则无法使用该索引。Skip Scan 改变了这一点。

### 2.2 Skip Scan 的底层原理

Skip Scan 的核心思想是：**将复合索引的前缀列的所有不重复值枚举出来，然后对每个值执行一次 range 扫描**。

以索引 `(a, b)` 为例，执行 `WHERE b > 10`：

1. **获取 distinct a 值**：扫描索引，找出 a 列的所有不重复值（如 a=1, a=2, a=3）
2. **对每个 a 值进行 range 扫描**：分别执行 `WHERE a=1 AND b>10`、`WHERE a=2 AND b>10`、`WHERE a=3 AND b>10`
3. **合并结果**：将各次扫描结果合并返回

### 2.3 Skip Scan 的工作流程

```sql
CREATE TABLE `orders` (
  `id` int NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `status` tinyint NOT NULL,
  `create_time` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_user_status` (`user_id`, `status`, `create_time`)
) ENGINE=InnoDB;
```

执行查询：

```sql
SELECT * FROM orders 
WHERE status = 1 AND create_time > '2026-01-01';
```

传统上，缺少 `user_id` 条件无法使用 `idx_user_status` 索引，只能全表扫描。但有了 Skip Scan：

```
id | select_type | table  | type  | key              | Extra
1  | SIMPLE      | orders | range | idx_user_status  | Using index for skip scan
```

`Using index for skip scan` 就是 Skip Scan 的标志。

### 2.4 Skip Scan 的执行计划分析

```sql
-- 查看 Skip Scan 的执行计划细节
EXPLAIN FORMAT=TREE
SELECT * FROM orders 
WHERE status = 1 AND create_time > '2026-01-01';
```

输出示例：

```
-> Filter: ((orders.status = 1) and (orders.create_time > TIMESTAMP'2026-01-01 00:00:00'))  (cost=12.35 rows=68)
    -> Index skip scan on orders using idx_user_status, with index condition: ((orders.status = 1) and (orders.create_time > TIMESTAMP'2026-01-01 00:00:00'))  (cost=12.35 rows=68)
```

### 2.5 Skip Scan 与全表扫描的性能对比

| 场景 | 全表扫描 | Skip Scan |
|------|---------|-----------|
| 数据量 100 万，user_id 分布均匀（1000个不同值） | 扫描 100 万行 | 扫描 1000 × (每个user_id下约5条) = 5000 行 |
| 需要回表？ | 不涉及索引 | 需要针对每个匹配行回表 |
| 适用场景 | 小表 | 大表 + 前缀列基数不高 |

**核心要点**：Skip Scan 适合**前缀列（user_id）的基数（distinct 值）不太大**的场景。如果 user_id 有 10 万个不同值，那就要做 10 万次 range 扫描，反而比全表扫描更慢。

### 2.6 Skip Scan 的限制条件

```sql
-- ❌ 不支持：查询条件无法形成完整的 range 扫描
SELECT * FROM orders WHERE status IN (1, 2, 3);  -- 可能不会触发

-- ❌ 不支持：前缀列使用了范围条件
SELECT * FROM orders WHERE user_id > 100 AND status = 1; -- 前缀列已经是范围

-- ❌ 不支持：表太小，优化器认为全表扫描更优

-- ❌ 不支持：前缀列是唯一索引的一部分
```

**官方文档**中 Skip Scan 的要求：

1. 表必须至少有一个**复合索引**
2. 查询条件中**不能**包含索引的最左前缀列
3. 查询必须能分解成多次范围扫描
4. 聚合函数 `MIN()` / `MAX()` 也可触发 Skip Scan

### 2.7 Skip Scan 实战：何时该用何时不该用

**✅ 推荐使用：**

```sql
-- user_id 只有几十个不同值，但表有几百万行
-- 直接全表扫描太慢，Skip Scan 效果显著
SELECT * FROM orders 
WHERE status = 2 AND create_time BETWEEN '2026-06-01' AND '2026-06-30';
```

**❌ 不推荐：**

```sql
-- user_id 有百万个不同值（几乎唯一），Skip Scan 要做百万次 range 扫描
-- 此时加一个 (status, create_time) 的联合索引更好
SELECT * FROM orders 
WHERE status = 1 AND create_time > '2026-01-01';
```

### 2.8 如何控制 Skip Scan？

```sql
-- 关闭 Skip Scan
SET optimizer_switch = 'skip_scan=off';

-- 强制使用索引（可避免优化器选择 Skip Scan）
SELECT * FROM orders FORCE INDEX (idx_user_status)
WHERE status = 1 AND create_time > '2026-01-01';

-- 忽略索引（强制全表扫描）
SELECT * FROM orders IGNORE INDEX (idx_user_status)
WHERE status = 1 AND create_time > '2026-01-01';
```

---

## 三、ICP 与 Skip Scan 对比总结

| 对比维度 | ICP | Skip Scan |
|---------|-----|-----------|
| 引入版本 | MySQL 5.6 | MySQL 8.0.13 |
| 核心作用 | 减少回表次数 | 跳过最左前缀限制 |
| 执行计划标记 | `Using index condition` | `Using index for skip scan` |
| 底层机制 | 条件下推到引擎层 | 枚举前缀列值做多次range扫描 |
| 适用索引 | 二级索引 | 复合索引（缺最左列） |
| 性能提升点 | 减少回表 IO | 避免全表扫描 |
| 不支持场景 | 聚簇索引、子查询条件 | 前缀列基数高、前缀列有范围条件 |

---

## 四、面试高频问题

### Q1：如何判断一条 SQL 是否使用了 ICP？

看 EXPLAIN 的 Extra 列是否显示 `Using index condition`。

### Q2：ICP 对覆盖索引有效吗？

如果查询已经是覆盖索引（Extra 显示 `Using index`），那 ICP 没有额外收益——因为本来就不需要回表，ICP 减少回表的前提不存在。

但如果是 `Using index; Using index condition` 共存的情况，说明部分数据从索引覆盖，部分需要回表，ICP 仍有作用。

### Q3：Skip Scan 一定能提升性能吗？

不一定。如果前缀列的 distinct 值太多（如 UUID 类型的前缀列），Skip Scan 会退化。它最适用于**前缀列基数低、表数据量大**的场景。

### Q4：如何查看 ICP 和 Skip Scan 的实际执行次数？

```sql
-- ICP
SHOW STATUS LIKE 'Handler_icp_attempts';
SHOW STATUS LIKE 'Handler_icp_match';

-- Skip Scan（暂无精确计数器，通过性能对比衡量）
SHOW STATUS LIKE 'Handler_read%';
```

---

## 五、总结

- **ICP** — 将索引条件下的过滤从 Server 层下推到存储引擎层，减少回表次数。适合二级索引 + 部分条件可用索引过滤的场景
- **Skip Scan** — 突破最左前缀限制，通过枚举前缀列不同值来实现对非最左列的索引使用。适合前缀列基数不高的场景

两个特性都是 MySQL 优化器的**零成本优化**——不需要改 SQL、不需要加索引，升级到 MySQL 5.6+ / 8.0.13+ 就能自动受益。理解它们的原理，能让你在面对执行计划时更快定位问题，写出更高效的 SQL。

建议开发者在日常工作中多关注 EXPLAIN 输出的 Extra 列，这两个特性在日常 OLTP 查询优化中非常实用。
