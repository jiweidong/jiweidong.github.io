---
title: 【MySQL 优化】子查询优化深度解析：semi-join、物化与派生表合并的底层原理
date: 2026-09-08 08:00:00
tags:
  - MySQL
  - 优化器
  - SQL优化
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 优化】子查询优化深度解析：semi-join、物化与派生表合并的底层原理

## 面试官：IN 和 EXISTS 到底哪个快？为什么我明明写了子查询，EXPLAIN 里却看不到？

「IN 快还是 EXISTS 快」是 SQL 优化界的经典口水战，而真相是：**在 MySQL 5.6+，优化器会把很多子查询改写成半连接（semi-join），改写之后 IN 和 EXISTS 的执行计划可能一模一样**。面试官真正想听的是：你知道优化器对子查询做了哪些改写吗？什么时候改写失效、退化成逐行执行？

本文从子查询的分类讲起，深入 semi-join、物化（Materialization）、派生表合并（Derived Merge）三大优化手段，配合 EXPLAIN 实战解读。

---

## 一、子查询的分类

先分清三类子查询，优化手段完全不同：

| 类型 | 位置 | 例子 | 主要优化手段 |
|------|------|------|-------------|
| **派生表（Derived Table）** | FROM 子句 | `SELECT * FROM (SELECT ...) t` | 派生表合并 / 物化 |
| **半连接子查询（Semi-join）** | WHERE + IN/EXISTS | `WHERE id IN (SELECT user_id FROM ...)` | semi-join 改写（5.6+） |
| **标量子查询（Scalar）** | SELECT 列 / 条件 | `SELECT (SELECT MAX(x) FROM t2) ...` | 物化或逐行执行（相关子查询最危险） |

另外还有 **anti-join（反连接）**：`NOT IN` / `NOT EXISTS` 在 5.6+ 也会被改写成 anti-join 优化。

---

## 二、半连接（Semi-Join）：IN/EXISTS 的真相

### 2.1 什么是半连接

`SELECT * FROM t1 WHERE id IN (SELECT user_id FROM t2)` 的语义是：**t1 中的每一行，只要能在 t2 中找到匹配就返回，且 t2 的匹配行不参与输出、不产生重复**。

这种「只关心有没有匹配，不关心匹配几次」的查询，本质就是 **semi-join**。MySQL 5.6 开始，优化器会把 IN/EXISTS 子查询改写为 semi-join 执行。

### 2.2 改写后的样子

优化器内部等价改写为（伪代码）：

```sql
SELECT t1.* FROM t1 SEMI JOIN t2 ON t1.id = t2.user_id;
```

EXPLAIN 里可以看到标记：

```
mysql> EXPLAIN SELECT * FROM orders o
       WHERE o.user_id IN (SELECT id FROM users WHERE level > 3)\G
*************************** 1. row ***************************
           id: 1
  select_type: SIMPLE
        table: o
         type: ALL
*************************** 2. row ***************************
           id: 1
  select_type: SIMPLE
        table: users
         type: range
```

**关键特征**：两条记录的 `id` 都是 1、`select_type` 都是 `SIMPLE`——子查询不见了！说明它已经被改写成普通的多表连接。**如果 EXPLAIN 里出现 `select_type: SUBQUERY` 或 `DEPENDENT SUBQUERY`，说明改写失败，子查询在逐行执行，这才是性能杀手。**

### 2.3 semi-join 的四种执行策略

优化器会根据成本选择以下策略之一：

| 策略 | 原理 | 适用场景 |
|------|------|---------|
| **Duplicate Weedout（去重物化）** | 先物化 t2 匹配结果，再去重，避免驱动表重复扫描 | 通用兜底 |
| **FirstMatch（首次匹配）** | 外层表每行只找 t2 的**第一个**匹配就返回，类似 EXISTS 逐行但能利用索引 | t2 连接列有索引、结果集大 |
| **LooseScan（松散扫描）** | 利用 t2 的索引**跳过重复值**扫描 | t2 有索引且重复值多 |
| **Materialization（物化）** | 把 t2 子查询结果物化成临时表并加索引，再与 t1 连接 | t2 子查询本身很重 |

> MySQL 8.0.16+ 还有个 `SEMIJOIN` hint 可以手动指定策略，不过生产上让优化器自己选即可，能看懂 EXPLAIN 就行。

---

## 三、NOT IN / NOT EXISTS → Anti-Join

`NOT IN` 与 `NOT EXISTS` 语义上是「找没有匹配的行」，5.6+ 改写为 **anti-join**（`t1 ANTI JOIN t2`），同样可以走物化/索引优化。

**但有一个巨坑必须记住**：`NOT IN` 的子查询结果如果包含 **NULL**，整个查询结果会**为空**（因为 `x NOT IN (NULL, ...)` 对任何 x 都是 NULL/UNKNOWN，WHERE 不保留）。而 `NOT EXISTS` 没有这个问题。

```sql
-- 如果 t2.ids 里存在 NULL，下面这条永远查不出数据！
SELECT * FROM t1 WHERE id NOT IN (SELECT user_id FROM t2);

-- 安全写法：NOT EXISTS
SELECT * FROM t1 WHERE NOT EXISTS (SELECT 1 FROM t2 WHERE t2.user_id = t1.id);
```

> 面试考点：`NOT IN` 遇到 NULL 的语义陷阱 + 两者都能被改写成 anti-join 的事实。生产规范通常直接禁用 NOT IN。

---

## 四、派生表合并（Derived Merge）与物化

### 4.1 派生表合并（MySQL 5.7+ 默认开启）

`FROM (SELECT ...) AS t` 这类派生表，优化器优先尝试**把派生表 SQL 直接合并进外层查询**，这样能同时利用外层的索引和条件：

```sql
-- 改写前
SELECT * FROM (SELECT * FROM orders WHERE status = 1) t WHERE t.amount > 100;
-- 优化器合并后 ≈
SELECT * FROM orders WHERE status = 1 AND amount > 100;
```

这样 orders 上的索引（比如 (status, amount) 联合索引）就能用上了。

### 4.2 什么时候合并不了？→ 物化

如果派生表包含以下结构，**无法合并**，只能物化成临时表：

- 使用了 `GROUP BY` / `DISTINCT`（聚合后语义无法下推）；
- 使用了 `LIMIT` / `OFFSET`（先取前 N 行再连接，顺序敏感）；
- 使用了聚合函数（MIN/MAX/SUM 等）；
- 使用了窗口函数、UNION、子查询等。

物化时 MySQL **8.0 会自动给物化临时表加索引**（5.7 需要手动 `lateral` 或自求多福），所以：

```sql
-- 8.0 里这样写也能高效执行（物化临时表自动带索引）
SELECT u.name, stats.total
FROM users u
JOIN (SELECT user_id, SUM(amount) AS total
      FROM orders GROUP BY user_id) stats ON stats.user_id = u.id;
```

### 4.3 验证改写

用 `EXPLAIN FORMAT=TREE`（8.0）能直观看到优化器的决策树：

```
mysql> EXPLAIN FORMAT=TREE
       SELECT * FROM orders o
       WHERE o.user_id IN (SELECT id FROM users WHERE level > 3)\G
*************************** 1. row ***************************
EXPLAIN: -> Nested loop inner join  (cost=...)
    -> Filter: (o.user_id is not null)
    -> ...
    -> Index lookup on users using PRIMARY (id=o.user_id)
```

看到 `Nested loop` / `Index lookup` 说明走了 semi-join 加索引，没有 `Materialize` 和逐行 `DEPENDENT SUBQUERY`，就是好计划。

---

## 五、相关子查询：最危险的写法

**相关子查询（Correlated Subquery）**：内层子查询引用了外层表的列，理论上**每处理一行外层数据都要执行一次子查询**——O(N×M) 的噩梦：

```sql
-- 危险写法：每行 orders 都要执行一次子查询（除非被改写成 join）
SELECT o.*, (SELECT name FROM users u WHERE u.id = o.user_id) AS uname
FROM orders o;
```

优化器对 SELECT 子句的标量相关子查询有时无法改写，会退化成**逐行执行**。改写为 JOIN 通常更优：

```sql
SELECT o.*, u.name AS uname
FROM orders o LEFT JOIN users u ON u.id = o.user_id;
```

**改写原则**（面试答法）：

1. WHERE 里的相关子查询（EXISTS）→ 优化器大概率改写成 semi-join/anti-join，可以放心写；
2. SELECT 列里的标量相关子查询 → 尽量手动改 JOIN；
3. 写完后**必查 EXPLAIN**：出现 `DEPENDENT SUBQUERY` 且扫描行数巨大，就是没优化好。

---

## 六、实战案例对比

### 案例 1：查「下过单的用户信息」

```sql
-- 写法 A：IN 子查询
SELECT * FROM users
WHERE id IN (SELECT DISTINCT user_id FROM orders);

-- 写法 B：EXISTS 相关子查询
SELECT * FROM users u
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- 写法 C：JOIN + DISTINCT
SELECT DISTINCT u.* FROM users u JOIN orders o ON o.user_id = u.id;
```

执行计划验证结果：A 和 B 都会被改写成 **semi-join**，最终执行计划一致；C 的 DISTINCT 需要额外去重排序。**所以「IN 快还是 EXISTS 快」在 5.6+ 基本是个伪命题——看改写后的执行计划，而不是看写法。**

### 案例 2：查「从未下单的用户」（反连接）

```sql
-- 推荐：NOT EXISTS（天然免疫 NULL 陷阱）
SELECT * FROM users u
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- 避免：NOT IN（子查询含 NULL 会全表空结果）
SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM orders);
```

### 案例 3：班级平均分以上的学生（派生表）

```sql
SELECT s.name, s.score
FROM students s
JOIN (SELECT class_id, AVG(score) AS avg_score
      FROM students GROUP BY class_id) c
  ON s.class_id = c.class_id
WHERE s.score > c.avg_score;
```

派生表含 GROUP BY 无法合并 → 物化；8.0 自动为物化表加索引，效率可控。5.7 及以下建议改写为窗口函数（8.0）或两次扫描对比。

---

## 七、面试常见追问

**Q1：IN 和 EXISTS 到底哪个快？**
5.6+ 优化器会把 IN/EXISTS 改写成 semi-join，改写成功后执行计划相同，性能无差异。真正的差异来自：子查询能否被改写（有没有索引、是不是相关子查询）、子查询结果集大小（物化成本）。与其背口诀，不如看 EXPLAIN。

**Q2：怎么判断子查询有没有被优化？**
看 EXPLAIN：改写成功时子查询消失（id 相同、select_type 为 SIMPLE/PRIMARY）；出现 `SUBQUERY`/`DEPENDENT SUBQUERY` 且内层表 type=ALL 就是逐行扫描，需要改写 SQL 或加索引。

**Q3：派生表什么时候能合并、什么时候物化？**
没有 GROUP BY/DISTINCT/聚合/LIMIT/窗口函数等「破坏语义下推」的结构时优先合并；有则物化。物化在 8.0 会自动加索引，5.7 及更早版本性能较差，要谨慎。

**Q4：为什么我加了索引，子查询还是慢？**
可能子查询没被改写（如 SELECT 列表的标量相关子查询），也可能改写成物化后临时表在 5.7 没有索引导致连接退化。用 `EXPLAIN FORMAT=TREE` / `EXPLAIN ANALYZE`（8.0.18+，可看实际执行时间和扫描行数）定位瓶颈，再决定改写 JOIN 还是调整索引。

**Q5：EXPLAIN ANALYZE 和 EXPLAIN 有什么区别？**
EXPLAIN 只给优化器估算的执行计划；EXPLAIN ANALYZE 会**真实执行** SQL 并输出每步的实际耗时、扫描行数、循环次数，是排查子查询「看着计划挺好但就是慢」的终极工具（生产大表慎用，会真实跑查询）。

---

## 总结

子查询优化的本质是「**让优化器把嵌套查询拍平成连接**」：WHERE 里的 IN/EXISTS 改写成 semi-join，NOT IN/NOT EXISTS 改写成 anti-join，FROM 里的派生表能合并就合并、不能合并就物化加索引。判断标准只有一条——**打开 EXPLAIN，看子查询还在不在**。掌握了改写规则和 EXPLAIN 解读，IN vs EXISTS 这种口水题就能给出让面试官点头的答案。
