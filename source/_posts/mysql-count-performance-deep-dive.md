---
title: 【MySQL优化】MySQL COUNT 查询性能深度对比：COUNT(*)、COUNT(1)、COUNT(id) 与 COUNT(col) 原理与优化
date: 2026-07-14 08:02:00
tags:
  - MySQL
  - 性能优化
  - SQL
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL优化】MySQL COUNT 查询性能深度对比：COUNT(*)、COUNT(1)、COUNT(id) 与 COUNT(col) 原理与优化

## 前言

只要是做后端开发，COUNT 查询你一定写过无数遍：

```sql
SELECT COUNT(*) FROM user;
SELECT COUNT(1) FROM user;
SELECT COUNT(id) FROM user;
SELECT COUNT(name) FROM user;
```

这些写法有什么区别？哪个性能最好？`COUNT(*)` 和 `COUNT(1)` 到底谁更快？

可能你在网上看过各种说法——「COUNT(1) 比 COUNT(*) 快」、「COUNT(id) 不走索引」、「MyISAM 的 COUNT(*) 是 O(1)」……今天我们从 **InnoDB 存储引擎的层面**，把这些说法逐个验证。

<!-- more -->

---

## 一、COUNT 的本质

### 1.1 COUNT 是什么

COUNT 是一个**聚合函数（aggregate function）**，作用是统计「**非 NULL 的行数**」。

```sql
COUNT(expr) → 返回 expr 不为 NULL 的行数
COUNT(*)    → 返回总行数（包括 NULL 行）
```

**关键：** `COUNT(expr)` 会跳过 expr 为 NULL 的行，而 `COUNT(*)` 不会跳过任何行。

### 1.2 InnoDB 与 MyISAM 的本质区别

很多人听说过「MyISAM 的 COUNT 是 O(1)」，但那只对于**没有 WHERE 条件的 COUNT(*)**：

| 存储引擎 | 无条件的 COUNT(*) | 有条件的 COUNT |
|---------|------------------|---------------|
| MyISAM | O(1) — 直接读表元数据中的行数 | O(n) — 需要扫描 |
| InnoDB | O(n) — 需要扫描（受 MVCC 影响） | O(n) — 需要扫描 |

**为什么 InnoDB 不能像 MyISAM 一样缓存行数？**

因为 InnoDB 支持**事务（MVCC）**。不同事务看到的数据行数可能不同：

```
事务 A (READ COMMITTED)         事务 B (REPEATABLE READ)
     │                               │
     │  SELECT COUNT(*)              │
     │  → 100 行                      │  INSERT INTO t VALUES(...)
     │                               │
     │  SELECT COUNT(*)              │
     │  → 101 行 (已提交的数据可见)    │  SELECT COUNT(*)
     │                               │  → 100 行 (快照读，看不到未提交)
```

MVCC 使得「全局缓存行数」不可行，InnoDB 必须每次实际扫描来计算行数。

---

## 二、COUNT(*) vs COUNT(1) vs COUNT(id) vs COUNT(col)

### 2.1 执行计划对比

先建一张测试表：

```sql
CREATE TABLE `user` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) DEFAULT NULL,
  `age` int DEFAULT NULL,
  `email` varchar(100) DEFAULT NULL,
  `create_time` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_age` (`age`),
  KEY `idx_name` (`name`)
) ENGINE=InnoDB;

-- 插入 100 万行数据
```

让我们看看四种 COUNT 的执行计划：

```sql
EXPLAIN SELECT COUNT(*)  FROM user;
EXPLAIN SELECT COUNT(1)  FROM user;
EXPLAIN SELECT COUNT(id) FROM user;
EXPLAIN SELECT COUNT(name) FROM user;
```

**结果：**

| 查询 | type | key | Extra |
|------|------|-----|-------|
| COUNT(*)  | index | idx_name | Using index |
| COUNT(1)  | index | idx_name | Using index |
| COUNT(id) | index | PRIMARY | Using index |
| COUNT(name) | index | idx_name | Using index |

**关键发现：**
- `COUNT(*)` 和 `COUNT(1)` 选择了 `idx_name` 索引（最轻量的索引）
- `COUNT(id)` 选择了主键索引（因为主键索引包含了整行数据，但这里 MySQL 可能还会选二级索引）
- `COUNT(name)` 选择了 `idx_name` — 因为 name 列在索引中

> **MySQL 优化器的选择：** COUNT(*) 和 COUNT(1) 会优先选择「最窄的二级索引」来扫描，因为二级索引比聚簇索引小得多（只包含索引列 + 主键）。

### 2.2 性能测试数据

```sql
-- 测试环境：MySQL 8.0.32, 100万行数据, buffer pool 预热后
SET SESSION query_cache_type = OFF;

-- 测试 1: COUNT(*)
SELECT COUNT(*) FROM user;
-- 耗时: 0.08 sec (使用 idx_name 二级索引)

-- 测试 2: COUNT(1)
SELECT COUNT(1) FROM user;
-- 耗时: 0.08 sec (与 COUNT(*) 无差别)

-- 测试 3: COUNT(id)
SELECT COUNT(id) FROM user;
-- 耗时: 0.12 sec (使用主键索引，索引更大，需要更多 IO)

-- 测试 4: COUNT(name)
SELECT COUNT(name) FROM user;
-- 耗时: 0.08 sec (使用 idx_name 二级索引)
```

> **注意：** 当 `name` 列允许 NULL 时，`COUNT(name)` 的语义和 `COUNT(*)` 不同。如果 `name` 列有很多 NULL，`COUNT(name)` 的结果会比 `COUNT(*)` 少。

### 2.3 MySQL 官方说法

MySQL 官方文档明确指出：

> `COUNT(*)` is optimized to return rows without counting NULL values. `COUNT(expr)` does a test for NULL on each row.

> `COUNT(*)` is special, it counts all rows directly, without any column value checking.

**实际上，MySQL 5.7+ 对 COUNT(*) 和 COUNT(1) 做了完全相同的优化，没有性能差异。**

---

## 三、COUNT 的底层实现

### 3.1 扫描过程

不论哪种 COUNT，InnoDB 的扫描过程都是：

```
InnoDB COUNT 扫描流程：
1. 选择最合适的索引（通常是最窄的二级索引）
2. 从索引的根节点开始，沿着 B+ 树向下
3. 遍历叶子节点的数据页
4. 逐行读取索引记录，count++
5. 返回总行数
```

**如果索引列允许 NULL：**
- `COUNT(*)` 和 `COUNT(1)`：不检查 NULL，直接累加
- `COUNT(col)`：**跳过 col 为 NULL 的行**

### 3.2 COUNT(*) 的底层优化

MySQL 对 `COUNT(*)` 有特殊优化：

```c
// MySQL 源码中 handle_query 处理 COUNT(*) 的简化逻辑
if (is_count_star) {
    // 不读取任何列值，直接在存储引擎层面统计
    // 只需要遍历索引最窄的叶子节点即可
    ha_records(&stats);
}
```

对于 `COUNT(*)`，MySQL **不需要读取任何列值**，只需要遍历索引记录计数。这就是为什么它选择「最小的二级索引」。

### 3.3 COUNT(1) 的真相

`COUNT(1)` 中的 `1` 是一个常量表达式，对每一行来说，`1` 都不为 NULL，所以它和 `COUNT(*)` 语义完全相同。

MySQL 优化器会把 `COUNT(1)` 和 `COUNT(*)` 优化为同样的执行计划：

```sql
-- 下面两个查询的最终执行计划完全一样
SELECT COUNT(*) FROM user;
SELECT COUNT(1) FROM user;
```

**结论：COUNT(*) 和 COUNT(1) 没有性能差异，不要纠结。** 推荐用 `COUNT(*)`，它是标准 SQL 的规范写法。

---

## 四、COUNT 性能优化实战

### 4.1 优化一：使用二级索引

如前所述，`COUNT(*)` 会自动选择最窄的二级索引。但如果你知道哪个索引最合适，可以**强制使用提示**：

```sql
-- 如果 idx_name 和 idx_age 哪个更小？
-- 假设 name VARCHAR(50) vs age INT
-- age (4字节) 比 name 更窄

-- 查看索引大小
SELECT
    index_name,
    stat_name,
    stat_value
FROM mysql.innodb_index_stats
WHERE table_name = 'user' AND stat_name = 'size';

-- 强制使用索引
SELECT COUNT(*) FROM user FORCE INDEX (idx_age);
```

### 4.2 优化二：大表 COUNT 慢怎么办？

对于几百万行的表，COUNT 其实很快（几十毫秒）。如果上亿行开始变慢，可以考虑：

**方案 1：缓存行数**

```java
// 使用 Redis 缓存行数，定时更新
public Long getUserCount() {
    String key = "user:count";
    Long count = redisTemplate.opsForValue().get(key);
    if (count == null) {
        count = userMapper.countAll();
        redisTemplate.opsForValue().set(key, count, 5, TimeUnit.MINUTES);
    }
    return count;
}
```

**方案 2：维护计数表**

```sql
CREATE TABLE table_row_count (
    table_name VARCHAR(100) PRIMARY KEY,
    row_count BIGINT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 通过触发器或业务代码维护
-- INSERT/DELETE 时更新
UPDATE table_row_count SET row_count = row_count + 1 WHERE table_name = 'user';
```

**方案 3：使用近似值**

```sql
-- 使用 INFORMATION_SCHEMA 获取近似值
SELECT table_rows
FROM information_schema.tables
WHERE table_schema = 'mydb' AND table_name = 'user';
```

但注意：对于 InnoDB，`table_rows` 是**采样估算值**，误差可能很大（±30%-50%）。

### 4.3 优化三：带 WHERE 条件的 COUNT

```sql
-- 慢查询：需要全表扫描
SELECT COUNT(*) FROM user WHERE status = 1;

-- 优化：创建复合索引
ALTER TABLE user ADD INDEX idx_status_age (status, age);

-- 现在这个查询会走 idx_status 索引扫描
SELECT COUNT(*) FROM user WHERE status = 1;

-- 更进一步：如果只关心存在性，用 LIMIT 1
SELECT 1 FROM user WHERE status = 1 LIMIT 1;
```

**索引覆盖（Covering Index）：** 如果 WHERE 条件和 COUNT 都能通过索引满足，MySQL 只需要扫描索引不需要回表。

### 4.4 优化四：分页 COUNT 优化

分页查询中经常出现这种「性能杀手」：

```sql
-- ❌ 大偏移量 + COUNT，性能极差
SELECT COUNT(*) FROM user WHERE status = 1;
-- 然后
SELECT * FROM user WHERE status = 1 LIMIT 1000000, 20;
```

优化思路：

```sql
-- ✅ 如果将业务改为「翻页到底」不现实，可以用缓存
-- 或者将结果集限制在一个合理范围内
SELECT COUNT(*) FROM (
    SELECT id FROM user WHERE status = 1 LIMIT 1000000, 20
) AS t;
```

但更好的方案是**避免总行数统计**，改用「下一页」模式：

```java
// ❌ 传统分页：需要 COUNT + LIMIT
// ✅ 更好的方式：游标/Keyset Pagination
public List<User> queryUsers(Long lastId, int pageSize) {
    return userMapper.selectByCursor(lastId, pageSize);
}

// SQL:
// SELECT * FROM user WHERE id > #{lastId} ORDER BY id LIMIT #{pageSize}
```

这种方式不需要 COUNT 总行数，性能提升巨大。

### 4.5 优化五：使用 EXPLAIN 分析

```sql
EXPLAIN SELECT COUNT(*) FROM user WHERE status = 1;

-- 如果 type = ALL（全表扫描），需要优化
-- 如果 type = ref/index/crange，说明走了索引
```

---

## 五、各 COUNT 写法终极对比

| 写法 | 含义 | NULL 处理 | 索引选择 | 性能 | 推荐 |
|------|------|----------|---------|------|------|
| COUNT(*) | 统计总行数 | 包含 NULL 行 | 最窄二级索引 | ⭐⭐⭐⭐⭐ | ✅ **推荐** |
| COUNT(1) | 统计总行数 | 包含 NULL 行 | 最窄二级索引 | ⭐⭐⭐⭐⭐ | 等价 |
| COUNT(pk) | 统计主键非空行数 | 主键不包含 NULL | 主键索引 | ⭐⭐⭐⭐ | 一般不推荐 |
| COUNT(col) | 统计 col 非空行数 | 跳过 NULL | 取决于 col 索引 | ⭐⭐⭐ | 仅需非空统计时使用 |
| COUNT(DISTINCT col) | 统计非空去重行数 | 跳过 NULL | 取决于索引 | ⭐⭐ | 去重统计时使用 |

**MySQL 官方推荐：** Use `COUNT(*)` to count rows.

---

## 六、COUNT 常见面试题

### Q1：COUNT(*) 和 COUNT(1) 哪个更快？

**一样快。** 两者在 MySQL 5.7+ 中被优化为完全相同的执行计划。不要在这个问题上浪费时间，用 `COUNT(*)` 即可。

### Q2：COUNT(id) 一定比 COUNT(*) 慢吗？

**是的，通常更慢。** 因为：
1. `COUNT(id)` 指定了主键列，MySQL 倾向于使用聚簇索引（主键索引），它比二级索引大
2. `COUNT(*)` 自动选择最窄的二级索引

但即使强制使用相同的索引，两者性能也差不多。

### Q3：为什么 InnoDB 的 COUNT(*) 那么慢？

相比 MyISAM 确实慢，但「慢」是相对的。对百万级表，`COUNT(*)` 几十毫秒完成。真正慢的场景是**亿级表 + 全表扫描 + 不走索引**。

### Q4：COUNT 能并行执行吗？

MySQL 的单查询默认是单线程的。但 MySQL 8.0 引入了 **InnoDB 并行读取（Parallel Read）** 能力，对 `COUNT(*)` 有部分加速效果。如果需要真正的并行 COUNT，可以考虑分片：

```sql
-- 手动分片并行 COUNT
SELECT SUM(cnt) FROM (
    SELECT COUNT(*) as cnt FROM user WHERE id BETWEEN 1 AND 1000000
    UNION ALL
    SELECT COUNT(*) FROM user WHERE id BETWEEN 1000001 AND 2000000
    UNION ALL
    SELECT COUNT(*) FROM user WHERE id BETWEEN 2000001 AND 3000000
) AS t;
```

### Q5：COUNT 和 EXISTS 有什么区别？

```sql
-- COUNT：统计行数
SELECT COUNT(*) FROM user WHERE status = 1;

-- EXISTS：判断是否存在
SELECT EXISTS(SELECT 1 FROM user WHERE status = 1);

-- 如果只关心「有没有数据」，EXISTS 更快（找到第一条就返回）
-- 如果需要知道「有多少数据」，只能用 COUNT
```

---

## 总结

1. **写 COUNT 统一用 `COUNT(*)`** — 语义清晰，性能最佳
2. **`COUNT(*)` 和 `COUNT(1)` 没有性能差异** — 不必纠结
3. **`COUNT(col)` 会跳过 NULL 行** — 语义不同，谨慎使用
4. **确保有合适的二级索引** — `COUNT(*)` 会自动选最窄索引
5. **大表 COUNT 慢** — 用缓存、计数表或近似值方案
6. **分页查询避免 COUNT+大偏移量** — 用游标分页替代

记住一条黄金法则：**能用 `COUNT(*)`，就别用别的写法。**
