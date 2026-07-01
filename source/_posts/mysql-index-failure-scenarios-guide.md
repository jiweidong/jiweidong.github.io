---
title: 【MySQL优化】索引失效场景全总结与优化实战：从 EXPLAIN 到 SQL 优化
date: 2026-07-01 08:00:00
tags:
  - MySQL
  - 索引
  - 性能优化
  - SQL
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL优化】索引失效场景全总结与优化实战：从 EXPLAIN 到 SQL 优化

## 前言

在工作中，我们经常会遇到这样的问题：明明建了索引，SQL 查询却依然慢如蜗牛。很大可能性是——**索引失效了**。

索引失效是 MySQL 性能优化中最常见的坑。本文将总结 12 种常见的索引失效场景，并为每种场景提供 SQL 示例和 EXPLAIN 分析，帮你彻底掌握索引优化的精髓。

---

## 一、准备工作

先建一张示例表：

```sql
CREATE TABLE `employee` (
  `id` INT PRIMARY KEY AUTO_INCREMENT,
  `name` VARCHAR(50) NOT NULL,
  `phone` VARCHAR(20) DEFAULT NULL,
  `age` INT DEFAULT NULL,
  `status` TINYINT DEFAULT NULL,
  `department` VARCHAR(50) DEFAULT NULL,
  `create_time` DATETIME DEFAULT NULL,
  KEY `idx_name` (`name`),
  KEY `idx_phone` (`phone`),
  KEY `idx_department_age` (`department`, `age`),
  KEY `idx_create_time` (`create_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

> 说明：`idx_department_age` 是联合索引，列顺序为 `(department, age)`。

---

## 二、12 种索引失效场景（含 EXPLAIN 分析）

### ❌ 场景 1：隐式类型转换

```sql
-- phone 字段是 VARCHAR 类型，传入整型会导致隐式类型转换
EXPLAIN SELECT * FROM employee WHERE phone = 13800138000;
```

**结果**：`type = ALL`，全表扫描。MySQL 会将 `phone` 字段转换为整型比较，相当于对索引列使用了函数操作，索引失效。

**解法**：参数类型与字段类型保持一致。

```sql
-- 正确写法
EXPLAIN SELECT * FROM employee WHERE phone = '13800138000';  -- ref
```

### ❌ 场景 2：对索引列使用函数

```sql
EXPLAIN SELECT * FROM employee WHERE LEFT(name, 2) = '张';    -- ALL
EXPLAIN SELECT * FROM employee WHERE DATE(create_time) = '2026-07-01';  -- ALL
```

**解法**：用等值范围查询代替函数操作。

```sql
-- 改为范围查询
EXPLAIN SELECT * FROM employee WHERE create_time >= '2026-07-01 00:00:00'
    AND create_time < '2026-07-02 00:00:00';  -- range
```

### ❌ 场景 3：联合索引违反最左前缀原则

```sql
-- 联合索引 idx_department_age(department, age)
-- 跳过了 department，直接查 age
EXPLAIN SELECT * FROM employee WHERE age = 25;  -- ALL
```

**解法**：查询条件必须包含最左列。

```sql
EXPLAIN SELECT * FROM employee WHERE department = '技术部' AND age = 25;  -- ref
EXPLAIN SELECT * FROM employee WHERE department = '技术部';  -- ref（仅使用 part of index）
```

### ❌ 场景 4：LIKE 以通配符开头

```sql
EXPLAIN SELECT * FROM employee WHERE name LIKE '%东%';  -- ALL
EXPLAIN SELECT * FROM employee WHERE name LIKE '%东';    -- ALL
```

**解法**：
- 尽量避免左模糊，改为右模糊 `'东%'`（走 range 扫描）
- 改不了就用 **覆盖索引** 或 **全文索引（FULLTEXT）**

```sql
EXPLAIN SELECT * FROM employee WHERE name LIKE '东%';  -- range
```

### ❌ 场景 5：OR 条件中有非索引列

```sql
-- name 有索引，status 没有索引
EXPLAIN SELECT * FROM employee WHERE name = '张三' OR status = 1;  -- ALL
```

**解法**：
- 给 status 也加上索引
- 或改用 UNION 拆分

```sql
EXPLAIN SELECT * FROM employee WHERE name = '张三'
UNION
SELECT * FROM employee WHERE status = 1;
```

### ❌ 场景 6：NOT IN / NOT EXISTS

```sql
EXPLAIN SELECT * FROM employee WHERE department NOT IN ('技术部', '产品部');  -- ALL
```

**解法**：除非子查询结果集很小，否则 NOT IN 很难走索引。可以考虑改用 LEFT JOIN + IS NULL 或 EXISTS 改写。

```sql
-- 如果能确保排除列表很小，IN 可以走索引
EXPLAIN SELECT * FROM employee WHERE department IN ('技术部', '产品部');  -- ref
```

### ❌ 场景 7：!= 或 <> 操作符

```sql
EXPLAIN SELECT * FROM employee WHERE department <> '技术部';  -- ALL
```

**注意**：MySQL 认为 `!=` / `<>` 扫描范围太大，通常选择全表扫描而非索引扫描。对于区分度高的字段（如主键），依然可能走索引。

### ❌ 场景 8：IS NULL / IS NOT NULL 优化器判断

```sql
-- 如果表中有大量 NULL，IS NULL 可能不走索引
EXPLAIN SELECT * FROM employee WHERE phone IS NULL;
```

**注意**：MySQL 优化器会基于统计信息判断，如果 NULL 值的比例过高，优化器会选择全表扫描。

### ❌ 场景 9：类型比较中的字符集不一致

如果两张表的连接字段字符集不同（如一张 utf8mb4、一张 utf8），会导致索引失效。这在多表 JOIN 时尤为常见。

```sql
-- 如果 department 列在两表中字符集不同
SELECT * FROM employee e JOIN dept d ON e.department = d.name;  -- 可能导致索引失效
```

**解法**：统一维护字符集，或使用 CAST 转换（但 CAST 本身也可能导致索引失效，需注意）。

### ❌ 场景 10：ORDER BY 与 GROUP BY 未遵循索引顺序

```sql
-- 联合索引 idx_department_age(department, age)
EXPLAIN SELECT department, age FROM employee ORDER BY age;  -- Using filesort
EXPLAIN SELECT department, age FROM employee ORDER BY department, age;  -- Using index
```

### ❌ 场景 11：数据量太小或索引区分度太低

当 MySQL 优化器判断 **全表扫描比走索引 + 回表更快** 时，会选择不走索引。

**原因**：
- 数据量小（如几百行），全表扫描的 IO 成本反而更低
- 索引区分度低（如 gender 字段只有男女），回表开销大

### ❌ 场景 12：最左列使用范围查询导致后续列索引失效

```sql
-- 联合索引 idx_department_age(department, age)
-- department 使用范围查询，age 列索引失效
EXPLAIN SELECT * FROM employee WHERE department > '技术部' AND age = 25;  -- age 索引失效
```

**注意**：MySQL 在联合索引中，一旦某列使用了范围查询（>、<、BETWEEN），其后的列就无法使用索引了。

---

## 三、索引失效场景速查表

| 序号 | 场景 | 索引状态 | 推荐解法 |
|:---:|------|:-------:|---------|
| 1 | 隐式类型转换 | ❌ | 参数类型与字段类型一致 |
| 2 | 索引列使用函数 | ❌ | 改成范围查询 |
| 3 | 违反最左前缀 | ❌ | 包含最左列条件 |
| 4 | LIKE 左模糊 `%xxx` | ❌ | 改为右模糊或全文索引 |
| 5 | OR 含非索引列 | ❌ | 全部加索引或用 UNION |
| 6 | NOT IN / NOT EXISTS | ❌ | 改为 LEFT JOIN |
| 7 | `!=` / `<>` | ❌ | 业务逻辑规避 |
| 8 | IS NULL 比例过高 | ⚠️ | 添加 NOT NULL 默认值 |
| 9 | 字符集不一致 | ❌ | 统一字符集 |
| 10 | ORDER BY 不符合索引 | ⚠️ | 按索引顺序排序 |
| 11 | 区分度低/数据量少 | ⚠️ | 覆盖索引、SQL Hint |
| 12 | 范围查询后列 | ❌ | 调整索引顺序 |

---

## 四、如何快速定位索引失效？

**Step 1**：给慢查询 SQL 加 `EXPLAIN` 前缀。

**Step 2** 关键字段解读：

| 字段 | 好（走索引） | 坏（索引失效） |
|:----:|:----------:|:------------:|
| `type` | const/eq_ref/ref/range | ALL（全表扫描）或 index（全索引扫描） |
| `key` | 显示实际使用的索引名 | NULL |
| `rows` | 越小越好 | 过大说明扫描了很多行 |
| `Extra` | Using index（覆盖索引） | Using filesort、Using temporary |

**Step 3**：关注 `rows` 和 `Extra`，如果 rows 接近表总行数且 type = ALL，大概率索引失效了。

---

## 总结

索引失效并不可怕，**可怕的是一遍遍被同一个坑绊倒**。记住这 12 种场景——基本覆盖了工作中 90% 以上的索引失效问题。

用一个口诀收尾：

> **函数计算与隐转，最左前缀不能反。左模 or 链非索引，not in 不等难上难。范围查询后列废，区分度低表不干。一一排查用 Explain，索引优化心里安。**

希望这篇文章能帮你少踩一些 MySQL 的坑 🙌
