---
title: MySQL 索引原理与优化实战
date: 2026-06-11 11:00:00
tags: [MySQL, 索引, 性能优化, B+树, 慢查询]
categories: 数据库
---

## 前言

索引是数据库性能调优中最基础也最核心的手段。一条 SQL 走不走索引、走什么索引，执行时间可能相差几个数量级。本文从底层存储结构讲起，结合实际案例，带你彻底掌握 MySQL 索引优化。

---

## 一、索引的底层数据结构

### 1.1 为什么选择 B+ 树？

MySQL InnoDB 存储引擎使用 **B+ 树**作为索引结构。对比其他数据结构：

| 数据结构 | 磁盘 I/O | 范围查询 | 有序性 | 适用场景 |
|---------|---------|---------|-------|---------|
| 哈希表 | O(1) | ❌ 不支持 | ❌ | 等值查询 |
| 二叉树 | O(log n) | ✅ | ✅ | 内存中 |
| B 树 | O(log n) | ❌ 较差 | ✅ | 磁盘存储 |
| **B+ 树** | **O(log n)** | **✅ 优秀** | **✅** | **磁盘存储（最优）** |

### 1.2 B+ 树的核心特征

```
                  [50]
                ↙     ↘
           [20, 30]    [70, 90]
         ↙   ↓   ↘    ↓    ↓    ↘
      [10,15][25][35] [60] [80] [95,100]
        ↑  ↑   ↑   ↑   ↑    ↑     ↑
        └─── 数据页链表 ────────────┘
```

1. **非叶子节点只存索引键**，不存数据 —— 一层可以存更多索引
2. **叶子节点存完整数据（聚簇索引）或主键值（二级索引）**
3. **叶子节点之间有双向指针** —— 范围查询极其高效
4. **高度通常 3~4 层** —— 百万级数据只需 3~4 次 I/O

> InnoDB 一个数据页默认 **16KB**。假设索引键 8B，指针 6B，一个节点可存约 1170 个键。三层 B+ 树可存约 `1170 × 1170 × 16 ≈ 2100 万` 条记录。

---

## 二、聚簇索引 vs 二级索引

### 2.1 聚簇索引（Clustered Index）

InnoDB 中，**表就是聚簇索引**。数据按主键顺序物理存储。

```sql
CREATE TABLE `user` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) DEFAULT NULL,
  `age` int DEFAULT NULL,
  `email` varchar(100) DEFAULT NULL,
  PRIMARY KEY (`id`)  -- 聚簇索引
) ENGINE=InnoDB;
```

**特点：**
- 叶子节点存放**完整的行数据**
- 一张表**只有一个**聚簇索引
- 默认按主键建立；无主键时选唯一键；都没有则隐式生成 `ROW_ID`

### 2.2 二级索引（Secondary Index / 辅助索引）

```sql
CREATE INDEX idx_name ON user(name);
```

**特点：**
- 叶子节点存放**主键值**，而不是完整数据
- 通过二级索引查询时，先找到主键 ID，再回聚簇索引查完整数据（**回表**）
- 一张表可以有多个二级索引

### 2.3 覆盖索引（Covering Index）

如果要查的字段**都在索引中**，就不需要回表。这叫覆盖索引。

```sql
-- idx_name 只包含 name 字段
SELECT name FROM user WHERE name = '张三';  -- 覆盖索引，无需回表

SELECT * FROM user WHERE name = '张三';    -- 需要回表查完整数据
```

创建**联合索引**时，可以将高频查询字段全部包含进去，避免回表。

---

## 三、最左匹配原则

### 3.1 什么是联合索引？

```sql
CREATE INDEX idx_name_age_email ON user(name, age, email);
```

联合索引 `(name, age, email)` 的存储结构是：

```
("张", 20, "a@b.com")  →  id=1
("张", 25, "b@c.com")  →  id=5
("张", 25, "c@d.com")  →  id=8
("李", 22, "d@e.com")  →  id=3
("李", 30, "e@f.com")  →  id=7
```

**先按第一个字段排序，相同再按第二个字段，以此类推。**

### 3.2 哪些查询能用到索引？

| 查询 | 用到索引 | 说明 |
|------|---------|------|
| `WHERE name = '张'` | ✅ | 匹配第一列 |
| `WHERE name = '张' AND age = 25` | ✅ | 匹配前两列 |
| `WHERE name = '张' AND age = 25 AND email = 'a@b.com'` | ✅ | 全部匹配 |
| `WHERE name = '张' AND email = 'a@b.com'` | ⚠️ 部分 | 只用 name 列索引，email 走不到（跳过了 age） |
| `WHERE age = 25` | ❌ | 没有从第一列开始 |
| `WHERE email = 'a@b.com'` | ❌ | 没有从第一列开始 |

### 3.3 索引下推（ICP）

MySQL 5.6 引入了**索引下推（Index Condition Pushdown）**：

```sql
-- idx_name_age_email (name, age, email)
SELECT * FROM user WHERE name LIKE '张%' AND age = 25;
```

没有 ICP 时：先按 `name LIKE '张%'` 找到主键 ID，回表后再过滤 `age = 25`。

有 ICP 时：在索引遍历过程中，直接判断 `age = 25`，过滤掉不符合的行，**减少回表次数**。

---

## 四、常见索引失效场景

### 4.1 对索引列使用了函数或计算

```sql
-- ❌ 索引失效
SELECT * FROM user WHERE LEFT(name, 1) = '张';

-- ✅ 改用范围查询
SELECT * FROM user WHERE name LIKE '张%';
```

### 4.2 隐式类型转换

```sql
-- name 字段是 VARCHAR
-- ❌ 索引失效（字符串与数字比较，发生类型转换）
SELECT * FROM user WHERE name = 123;

-- ✅ 保持类型一致
SELECT * FROM user WHERE name = '123';
```

### 4.3 LIKE 以 % 开头

```sql
-- ❌ 索引失效
SELECT * FROM user WHERE name LIKE '%张%';

-- ✅ 前缀模糊匹配可以用索引
SELECT * FROM user WHERE name LIKE '张%';
```

### 4.4 联合索引未使用第一列

```sql
-- idx_name_age_email
-- ❌ 索引失效
SELECT * FROM user WHERE age = 25;
```

### 4.5 OR 条件

```sql
-- idx_name 索引
-- ❌ 如果 email 没有索引，整个查询不走索引
SELECT * FROM user WHERE name = '张' OR email = 'a@b.com';

-- ✅ 拆分或用 UNION
SELECT * FROM user WHERE name = '张'
UNION
SELECT * FROM user WHERE email = 'a@b.com';
```

---

## 五、实战优化案例

### 案例 1：分页查询优化

```sql
-- ❌ 越往后越慢（offset 越大，需要扫描的行越多）
SELECT * FROM `order` ORDER BY id LIMIT 100000, 20;
```

**优化方案：**

方案一：**延迟关联**——先快速定位 ID，再 JOIN 查完整数据

```sql
SELECT o.* FROM `order` o
INNER JOIN (
    SELECT id FROM `order`
    ORDER BY id
    LIMIT 100000, 20
) tmp ON o.id = tmp.id;
```

方案二：**游标分页**（推荐）

```sql
-- 记录上一页最后一条的 id
SELECT * FROM `order`
WHERE id > last_max_id   -- 传入上一页最后一条的 id
ORDER BY id
LIMIT 20;
```

### 案例 2：排序优化

```sql
-- ❌ using filesort（额外排序）
SELECT * FROM user WHERE name = '张' ORDER BY age;

-- ✅ 联合索引天然排序（name, age）
-- idx_name_age(name, age) 即可避免排序
```

### 案例 3：大字段查询

```sql
-- ❌ 数据量大时回表代价高
SELECT name, content FROM article WHERE status = 1;

-- ✅ 用覆盖索引避免回表
CREATE INDEX idx_status_name ON article(status, name);
-- 再查询如果只查 status 和 name，走覆盖索引不用回表
```

---

## 六、慢查询定位与 explain

### 6.1 开启慢查询日志

```sql
-- 查询配置
SHOW VARIABLES LIKE 'slow_query%';
SHOW VARIABLES LIKE 'long_query_time';

-- 设置（临时生效）
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;  -- 超过 1 秒的 SQL
```

### 6.2 explain 解读

```sql
EXPLAIN SELECT * FROM user WHERE name = '张'\G
```

输出关键字段：

| 字段 | 说明 | 好 | 差 |
|------|------|-----|----|
| `type` | 访问类型 | `const`, `ref`, `range` | `ALL`（全表扫描） |
| `key` | 用到的索引 | 有索引名 | `NULL` |
| `rows` | 预估扫描行数 | 小 | 大 |
| `Extra` | 额外信息 | `Using index`（覆盖索引） | `Using filesort`, `Using temporary` |

**type 性能排序：**

```
system > const > eq_ref > ref > range > index > ALL
```

理想情况下至少要达到 `ref` 或 `range`，`ALL` 全表扫描通常是优化的重点。

---

## 七、索引设计的通用原则

### ✅ 适合创建索引的列
- **WHERE 条件**中频繁使用的列
- **JOIN** 的连接列
- **ORDER BY** 排序列（避免文件排序）
- **GROUP BY** 分组列
- 区分度高的列（选择性强）

### ❌ 不适合创建索引的列
- 频繁更新的列（维护索引代价高）
- 区分度低的列（如性别：男/女，过滤效果差）
- 数据量很小的表（全表扫描反而更高效）
- 很少出现在查询条件中的列

### 联合索引设计口诀

> **等值列放前面，排序列靠中间，范围列放最后。**

```sql
-- 查询中最频繁的写法
SELECT * FROM user WHERE status = 1 AND age > 18 ORDER BY create_time;

-- 最优索引：idx_status_age_time(status, create_time, age)
-- 注意：age 是范围查询，放在最后；create_time 排序紧接 status 之后
```

---

## 八、总结

1. **B+ 树**是 InnoDB 索引的基石，理解它的结构才能理解索引行为
2. **聚簇索引**存数据，**二级索引**存主键，**覆盖索引**避免回表
3. **最左匹配原则**是联合索引的核心，建索引时顺序至关重要
4. **索引失效**的常见坑：函数运算、类型转换、前模糊匹配、OR 条件
5. **EXPLAIN** 是优化利器，`type`、`key`、`rows`、`Extra` 四个字段重点看
6. **延迟关联 + 游标分页**是大数据量分页的解决方案

用好索引，SQL 性能从秒级降到毫秒级并不难。真正的难点在于理解业务数据分布和查询模式，设计出最匹配的索引组合。
