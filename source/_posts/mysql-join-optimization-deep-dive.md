---
title: 【MySQL优化】MySQL JOIN 底层原理与优化实战：从执行计划到性能调优
date: 2026-07-09 08:00:00
tags:
  - MySQL
  - SQL优化
  - JOIN
  - 性能调优
  - 面试
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL优化】MySQL JOIN 底层原理与优化实战

## 一、先问自己：这个 JOIN 真的需要吗？

很多开发者在写 SQL 时，习惯性地把所有相关表 JOIN 在一起。但 JOIN 的开销往往被低估。

```
面试官：你们项目中 JOIN 多吗？有没有性能问题？
答：分情况。对于 OLTP 系统，尽量少 JOIN（控制在 3 张表以内）；
对于 OLAP 报表场景，适当 JOIN 是合理的。
```

**JOIN 的成本模型：**

MySQL 执行 JOIN 时，需要**对每个驱动表的匹配行去扫描被驱动表**。驱动表的行数 × 被驱动表的扫描次数 = 总开销。

> **一个经验法则：** 驱动表返回 N 行，被驱动表每次扫描 M 行 → 总扫描行数 ≈ N × M

## 二、JOIN 的三种底层算法

### 2.1 Nested Loop Join（NLJ）— 嵌套循环连接

**原理：** 遍历驱动表，对每一行去被驱动表中查找匹配行。

这是 MySQL 最基础的 JOIN 算法，也是**被驱动表有索引时**使用的算法。

```
Table A（驱动表）: 100 行
Table B（被驱动表）: 10,000 行，B.id 有索引

执行过程：
1. 扫描 Table A，取出一行
2. 用 A.id 去 Table B 索引中查找（索引 B+ 树查找，约 1-3 次 IO）
3. 重复 1-2 步，直到 Table A 全部扫描完成

总扫描行数：100（A 全表扫描）+ 100 × 索引查找次数（约 3 次 IO）
≈ 100 + 300 = 400 行数据量
```

```sql
-- 下面的 JOIN，MySQL 会选择使用 NLJ
EXPLAIN SELECT *
FROM orders o
JOIN order_items oi ON o.id = oi.order_id
WHERE o.created_at > '2024-01-01';
```

**NLJ 的特点：**
- 被驱动表必须有高效的索引（通常是主键或唯一索引）
- 驱动表小、被驱动表大且有索引时，性能很好
- 如果被驱动表没有索引，MySQL 会使用 Block Nested Loop Join

### 2.2 Block Nested Loop Join（BNL）— 块嵌套循环连接

**原理：** 当被驱动表没有可用索引时，MySQL 把驱动表的行缓存到 **Join Buffer** 中，一次性批量传给被驱动表进行比较。

```
Table A（驱动表）: 100 行，每行 200 字节
Table B（被驱动表）: 10,000 行，B 表没有可用索引

join_buffer_size = 256KB

执行过程：
1. 扫描 Table A，把 100 行装入 Join Buffer（约 20KB，远小于 256KB）
2. 全表扫描 Table B，拿 B 的每一行和 Buffer 中的所有 A 行对比
3. 匹配的行输出

总扫描行数：100 + 10,000 = 10,100 行
比较次数：100 × 10,000 = 1,000,000 次
```

**关键配置：`join_buffer_size`**

```sql
-- 查看当前大小
SHOW VARIABLES LIKE 'join_buffer_size';
-- 默认 256KB，可适当增大到 1MB-8MB
-- 注意：这是每个线程独享的，不是全局共享
```

**BNL 的特点：**
- 被驱动表无索引时的兜底算法
- Join Buffer 越大，一次能缓存的行越多，扫描被驱动表的次数越少
- 适用于小表 JOIN 大表，且大表无索引的场景

### 2.3 Hash Join — 哈希连接

从 **MySQL 8.0.18** 开始引入，用于替代部分 BNL 场景。

```
Table A（驱动表）: 100 行
Table B（被驱动表）: 10,000 行，无索引

执行过程：
1. 扫描 Table A，构建哈希表（key = 连接字段，value = 行数据）
2. 扫描 Table B，对每一行计算连接字段的哈希值
3. 在哈希表中查找，匹配则输出

总扫描行数：100 + 10,000 = 10,100 行（和 BNL 一样）
但 Hash Join 的匹配速度远快于 BNL（O(1) vs O(n)）
```

```sql
-- 8.0.18+ 自动使用 Hash Join（无需特殊语法）
EXPLAIN FORMAT=TREE
SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id;
-- 输出: "Inner hash join"
```

| 算法 | 适用条件 | 时间复杂度 | MySQL 版本 |
|------|---------|-----------|-----------|
| NLJ | 被驱动表有索引 | O(N × logM) | 全部版本 |
| BNL | 无索引，Join Buffer | O(N × M) | 全部版本 |
| Hash Join | 无索引，等值连接 | O(N + M) | 8.0.18+ |

> **面试追问：MySQL 为什么之前一直没有 Hash Join？**
>
> 答：MySQL 长期依赖索引来加速 JOIN。在没有索引时用 BNL，用 Join Buffer 来减少被驱动表的扫描次数。Hash Join 需要大量内存构建哈希表，MySQL 早期架构更偏向磁盘优化。8.0 版重新设计了执行引擎，才引入了 Hash Join。

## 三、JOIN 优化核心策略

### 3.1 小表驱动大表

**基本原则：** 选择数据量小的表作为驱动表（外层循环），数据量大的表作为被驱动表（内层循环）。

MySQL 优化器通常会自动选择，但有时需要人工干预：

```sql
-- 添加 STRAIGHT_JOIN 强制指定驱动表顺序
SELECT STRAIGHT_JOIN *
FROM small_table s
JOIN large_table l ON s.id = l.s_id;
```

**如何判断哪张表是驱动表？**

```sql
-- EXPLAIN 中 "id" 列小的先执行，即驱动表
-- 如果没有子查询，id 相同的情况下，出现在前面的表可能是驱动表
EXPLAIN SELECT * 
FROM orders o
JOIN users u ON o.user_id = u.id
WHERE o.status = 'PAID';
```

### 3.2 被驱动表建立高效的索引

**JOIN 的索引优化策略：**

1. **连接字段必须建索引**
```sql
-- 在 user_id 上建索引
ALTER TABLE orders ADD INDEX idx_user_id(user_id);
```

2. **索引覆盖 JOIN 查询（避免回表）**
```sql
-- 联合索引覆盖查询字段
ALTER TABLE orders ADD INDEX idx_user_id_status(user_id, status);
-- 查询可以直接从索引取数据，无需回表
SELECT o.id, o.status FROM orders o JOIN users u ON o.user_id = u.id;
```

3. **复合索引的前缀匹配原则**
```sql
-- 如果 WHERE 条件是 status，JOIN 条件是 user_id
-- 最优索引设计：(status, user_id)
ALTER TABLE orders ADD INDEX idx_status_user_id(status, user_id);
```

### 3.3 减少驱动表的行数

驱动表的行数直接决定了循环次数，**先通过 WHERE 条件过滤**减少数据量：

```sql
-- ❌ 不优化：大表驱动
SELECT * FROM users u
JOIN orders o ON u.id = o.user_id;

-- ✅ 优化：先过滤再 JOIN
SELECT * FROM 
    (SELECT * FROM users WHERE created_at > '2023-01-01') u
JOIN orders o ON u.id = o.user_id;
```

### 3.4 只 SELECT 需要的字段

```sql
-- ❌ 不推荐：SELECT *
SELECT * FROM orders o
JOIN users u ON o.user_id = u.id;

-- ✅ 推荐：只取需要的字段
SELECT o.id, o.order_no, o.amount, u.name, u.phone
FROM orders o
JOIN users u ON o.user_id = u.id;
```

**理由：**
- 减少 Join Buffer 的内存占用
- 减少网络传输
- 可能使用覆盖索引，避免回表

## 四、EXPLAIN 分析 JOIN 查询

```sql
-- 准备测试数据
CREATE TABLE users (
    id INT PRIMARY KEY,
    name VARCHAR(50),
    created_at DATETIME
);

CREATE TABLE orders (
    id INT PRIMARY KEY,
    user_id INT,
    amount DECIMAL(10,2),
    status VARCHAR(20),
    INDEX idx_user_id(user_id)
);

-- 分析 JOIN
EXPLAIN SELECT *
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE u.created_at > '2024-01-01';
```

**EXPLAIN 输出关键列解读：**

| 列名 | 示例值 | 说明 |
|------|-------|------|
| id | 1 | 查询序号，id 相等从上往下执行 |
| select_type | SIMPLE | 简单查询，无子查询 |
| table | u | 正在访问的表 |
| type | ALL / ref | ALL=全表扫描（驱动表），ref=索引查找（被驱动表） |
| possible_keys | PRIMARY | 可能使用的索引 |
| key | PRIMARY | 实际使用的索引 |
| rows | 100 | 预估扫描行数 |
| Extra | Using index | 使用了覆盖索引 |

**关键信号：**
- `type=ALL` + `Extra=Using join buffer (Block Nested Loop)` → 被驱动表无索引，需要建索引
- `type=index` → 索引全扫描，通常需要优化
- `rows` 值很大 → 需要增加过滤条件或索引

## 五、典型 JOIN 优化案例

### 案例 1：慢 JOIN 变慢查询

```sql
-- 原始 SQL：执行时间 5.2s
SELECT o.*, u.name, u.phone
FROM orders o
LEFT JOIN users u ON o.user_id = u.id
WHERE o.created_at > '2023-01-01'
  AND o.status = 'PAID'
ORDER BY o.created_at DESC
LIMIT 20;
```

**分析：**
```sql
EXPLAIN SELECT ...\G
-- id: 1
-- table: o
-- type: ALL         ← orders 全表扫描
-- rows: 500000
-- Extra: Using where; Using filesort
-- 
-- table: u
-- type: ALL         ← users 全表扫描！
-- rows: 100000
-- Extra: Using where; Using join buffer (Block Nested Loop)
```

**优化：**
```sql
-- 1️⃣ users 表 user_id 建索引（其实已经有了，但需要确认）
-- 2️⃣ orders 表建复合索引（status + created_at）
ALTER TABLE orders ADD INDEX idx_status_created_at(status, created_at);
-- 3️⃣ 只 SELECT 需要的字段，用覆盖索引
```

优化后执行时间：**0.02s**，提升 260 倍。

### 案例 2：三表 JOIN 循环优化

```sql
-- 原始 SQL：执行时间 12s
SELECT *
FROM orders o
JOIN order_items oi ON o.id = oi.order_id
JOIN products p ON oi.product_id = p.id
WHERE o.status = 'PAID';
```

**优化前分析：** orders 10000 行 → order_items 每单 3 行（索引查找）→ products（全表扫描 20000 次）

**优化：**
```sql
-- order_items 的 product_id 建索引
ALTER TABLE order_items ADD INDEX idx_product_id(product_id);
```

**关键教训：** 每个被驱动表都必须有高效索引，三层 JOIN 中任何一层缺乏索引，都会导致性能灾难。

## 六、JOIN 常见陷阱

### 6.1 隐式类型转换

```sql
-- user_id 是 VARCHAR 类型
-- ❌ 隐式类型转换导致索引失效
SELECT * FROM orders o JOIN users u ON o.user_id = u.id
WHERE o.user_id = 100;  -- 数字类型，触发隐式转换

-- ✅ 正确写法
SELECT * FROM orders o JOIN users u ON o.user_id = u.id
WHERE o.user_id = '100';  -- 字符串类型
```

### 6.2 使用函数在连接字段上

```sql
-- ❌ 函数导致索引失效
SELECT * FROM orders o JOIN users u ON DATE(o.created_at) = u.reg_date;

-- ✅ 改为范围查询
SELECT * FROM orders o JOIN users u 
ON o.created_at >= '2024-01-01' AND o.created_at < '2024-01-02';
```

### 6.3 NOT IN / NOT EXISTS 优化

```sql
-- ❌ 慢查询：NOT IN 子查询
SELECT * FROM users 
WHERE id NOT IN (SELECT user_id FROM orders);

-- ✅ 优化：NOT EXISTS 或 LEFT JOIN
SELECT * FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE o.id IS NULL;
```

## 七、总结

| 优化要点 | 具体策略 |
|---------|---------|
| 选择算法 | 被驱动表有索引用 NLJ，无索引用 Hash Join |
| 驱动表选择 | 小表驱动大表，优化器通常自动选择 |
| 索引策略 | 连接字段建立索引，尽量覆盖索引 |
| 数据过滤 | 先 WHERE 过滤，再 JOIN |
| 查询字段 | 只选需要的，少用 SELECT * |
| 配置优化 | join_buffer_size 适当增大 |

**一句话总结 JOIN 优化：** 好的索引 + 小的驱动表 + 少的字段 = 快的 JOIN
