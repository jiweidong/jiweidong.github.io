---
title: 【MySQL 8.0】生成列（Generated Column）深度解析：虚拟列、存储列与索引实战
date: 2026-09-18 08:00:00
tags:
  - MySQL
  - 数据库
  - 索引优化
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 8.0】生成列（Generated Column）深度解析：虚拟列、存储列与索引实战

## 面试官：JSON 字段里的属性怎么建索引？

如果你回答「MySQL 8 有函数索引」，面试官通常会追问：**「函数索引底层是怎么实现的？它和生成列是什么关系？」** 这时候能讲清楚「函数索引本质上就是隐藏的虚拟生成列」的人，就明显高出一档。

生成列（Generated Column）是 MySQL 5.7 引入、8.0 大幅增强的能力，但很多人只知道概念不会用。这篇从语法到执行计划、从存储差异到 DDL 成本，把它彻底讲清楚。

---

## 一、什么是生成列

生成列的值 **不由 INSERT / UPDATE 显式指定**，而是由列定义里的表达式计算得出。

```sql
CREATE TABLE t_order (
  id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  order_no    VARCHAR(32) NOT NULL,
  amount      DECIMAL(10,2) NOT NULL,
  tax_rate    DECIMAL(5,4)  NOT NULL DEFAULT 0.1300,
  -- 存储列：计算结果落盘
  tax_amount  DECIMAL(10,2) AS (amount * tax_rate) STORED,
  -- 虚拟列：只存表达式，读取时计算
  amount_cents BIGINT AS (ROUND(amount * 100)) VIRTUAL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

两种类型对比：

| 维度 | VIRTUAL（默认） | STORED |
| --- | --- | --- |
| 是否占磁盘 | 否，只存元数据 | 是，结果真实落盘 |
| 读取成本 | 每次读取时计算 | 直接读 |
| 写入成本 | 低（不算） | 高（要算 + 写） |
| 能否建索引 | **可以**（InnoDB 支持二级索引） | 可以 |
| 能否作为主键 | 不可以 | 不可以 |
| 是否随基表更新 | 自动 | 自动 |
| DDL 成本 | INSTANT / INPLACE 快 | 需要重建表（大多数情况） |

⚠️ 划重点：**虚拟列可以被索引**，InnoDB 会把虚拟列的值物化到二级索引里。这是「虚拟列不占空间」说法的唯一例外——索引本身占空间。

---

## 二、语法与表达式限制

```sql
-- 完整语法（列定义的一部分）
col_name data_type [GENERATED ALWAYS] AS (expression) [VIRTUAL | STORED] [NOT NULL | NULL | UNIQUE | PRIMARY KEY]
```

表达式规则（踩坑重灾区）：

| 限制 | 说明 |
| --- | --- |
| 不能用子查询 | `AS ((SELECT ...))` 直接报错 |
| 不能用非确定性函数 | `NOW()`、`RAND()`、`UUID()`、`CURRENT_USER()` 不允许 |
| 不能引用 AUTO_INCREMENT 列 | 不允许 |
| 不能引用其它生成列？ | 8.0 起 **允许** 引用前面的生成列（有顺序依赖） |
| 不能用存储函数 / 用户变量 | 不允许 |
| 不能用 `DEFAULT` 子句 | 生成列不能有默认值 |
| 不能用 `ON UPDATE` | 不允许 |
| 表达式必须确定 | 同一行数据结果恒定 |

**确定性函数**：`ABS`、`ROUND`、`CONCAT`、`JSON_EXTRACT`、`JSON_UNQUOTE`、`DATE`、`YEAR`、`MONTH`、`UPPER`、`LOWER`、`MD5`、`LEFT`、`SUBSTRING` 等等都允许。

**非确定性**：`NOW()`、`SYSDATE()`、`RAND()`、`UUID()`、`CONNECTION_ID()`、`CURRENT_USER()`、`LOAD_FILE()`。

一个常见错误：

```sql
-- 报错：Expression of generated column 'age' contains a disallowed function: now.
ALTER TABLE t ADD COLUMN age INT AS (TIMESTAMPDIFF(YEAR, birth, NOW())) VIRTUAL;
```

正确做法是把「当前时间」在写入时固化到普通列，或者只在生成列里用 `birth` 本身。

---

## 三、虚拟列 + 索引：解决 JSON 检索的正确姿势

这是生成列最有价值的落地场景。

### 3.1 问题：JSON 直接查无法走索引（8.0.13 之前）

```sql
CREATE TABLE t_user (
  id   BIGINT PRIMARY KEY,
  info JSON
);
-- 无法使用索引，全表扫描
SELECT * FROM t_user WHERE info->>'$.city' = 'Hangzhou';
```

### 3.2 方案一：生成列 + 二级索引（5.7 可用）

```sql
ALTER TABLE t_user
  ADD COLUMN city VARCHAR(32)
    AS (JSON_UNQUOTE(JSON_EXTRACT(info, '$.city'))) VIRTUAL,
  ADD INDEX idx_city (city);
```

执行计划立刻变好：

```text
mysql> EXPLAIN SELECT * FROM t_user WHERE info->>'$.city'='Hangzhou'\G
*************************** 1. row ***************************
           id: 1
  select_type: SIMPLE
        table: t_user
         type: ref
possible_keys: idx_city
          key: idx_city
      key_len: 131
          ref: const
         rows: 8
        Extra: Using where
```

### 3.3 方案二：函数索引（8.0.13+，更简洁）

```sql
CREATE INDEX idx_city ON t_user ((CAST(info->>'$.city' AS CHAR(32))));
-- 或者用 JSON_UNQUOTE 写法（必须完全一致才会命中）
CREATE INDEX idx_city2 ON t_user ((JSON_UNQUOTE(JSON_EXTRACT(info, '$.city'))));
```

**函数索引的底层实现就是「隐藏的虚拟生成列 + 索引」**。你可以用 `SHOW CREATE TABLE` 看到痕迹：

```text
KEY `idx_city` (`info`->>'$.city')   -- 显示为表达式
```

而在 `information_schema.INNODB_INDEXES` / MySQL 8 的隐藏列里，它等价于一个虚拟生成列。

### 3.4 两个方案的取舍

| 维度 | 生成列 + 索引 | 函数索引 |
| --- | --- | --- |
| 引入版本 | MySQL 5.7 | MySQL 8.0.13 |
| 可读性 | 列有名字，业务代码可读 | 表达式必须与索引完全一致 |
| 查询写法 | `WHERE city = ?`（推荐） | `WHERE info->>'$.city' = ?`（必须一模一样） |
| 可复用 | 多个索引可以基于同一列 | 每个表达式一个索引 |
| 迁移成本 | 加列需评估 DDL | 加索引同理 |

**实战建议**：优先用「生成列 + 索引」，因为查询条件写 `WHERE city = ?` 更清晰，而且表达式不会因为空格/大小写差异导致索引失效。函数索引最大的坑就是 **SQL 里的表达式与索引定义必须字面一致**：

```sql
-- 索引：((CAST(info->>'$.city' AS CHAR(32))))
SELECT * FROM t_user WHERE info->>'$.city' = 'Hangzhou';  -- ❌ 不命中（类型不匹配）
```

---

## 四、STORED vs VIRTUAL 的性能实测思路

### 4.1 写入场景

```sql
-- 压测 100 万行插入
INSERT INTO t_order(order_no, amount, tax_rate) VALUES (...);
```

- VIRTUAL：插入时不计算？**不完全是**。如果虚拟列上有索引，InnoDB 插入时必须计算该值以维护索引 → 仍有 CPU 成本。
- STORED：每次写入都计算 + 写入数据行 → 额外 IO。

结论：**虚拟列不带索引时最省写入成本；带索引后差距缩小，但仍比 STORED 略优（不用写回主表行）。**

### 4.2 读取场景

```sql
SELECT tax_amount FROM t_order WHERE id = ?;
```

- STORED：直接读，零计算；
- VIRTUAL（无索引覆盖）：需要读基列再计算；
- VIRTUAL（索引覆盖）：从二级索引直接拿到值。

**如果某个生成列在 SQL 里被高频 SELECT 且不建索引，STORED 更划算。**

### 4.3 一句话决策口诀

- **要建索引用 VIRTUAL**（省空间，索引里已物化）；
- **要频繁直接读取用 STORED**；
- **既要索引又要频繁读**：建议 VIRTUAL + 索引（覆盖索引可满足），慎用两者都建。
- **表达式很复杂、CPU 敏感**：用 STORED，把计算成本转移到写入侧。

---

## 五、DDL 成本与在线变更

这是生产落地必须评估的。

| 操作 | Virtual | Stored |
| --- | --- | --- |
| `ADD COLUMN ... AS (...) VIRTUAL` | INSTANT（8.0） | 通常需要 COPY |
| `ADD INDEX` on virtual column | INPLACE（需重建辅助索引） | INPLACE |
| `ALTER` 表达式（先 DROP 再 ADD） | INSTANT + INPLACE | COPY |
| `ADD COLUMN` 后 `UPDATE` 全表 | 无需 | 无需 |

虚拟列的 `ADD COLUMN` 在 MySQL 8.0 是 **ALGORITHM=INSTANT**（只改元数据），这是它相对 STORED 的巨大优势：**大表加虚拟列几乎瞬间完成**。

验证算法：

```sql
ALTER TABLE t_user
  ADD COLUMN city VARCHAR(32) AS (JSON_UNQUOTE(JSON_EXTRACT(info,'$.city'))) VIRTUAL,
  ALGORITHM=INSTANT;

mysql> SHOW CREATE TABLE t_user\G   -- 确认列已加入
```

如果 `INSTANT` 不支持会直接报错，不会静默降级，所以可以放心用 `ALGORITHM=INSTANT` 探测。

**注意大表加索引本身仍然要重建索引**（`INPLACE`），这个成本绕不开，建议用 `pt-online-schema-change` / `gh-ost` 或低峰期操作。

---

## 六、实战案例集

### 6.1 大小写不敏感的唯一索引

MySQL 默认 collation（如 `utf8mb4_0900_ai_ci`）本身就是大小写不敏感的。但如果列是 `utf8mb4_bin`（大小写敏感），想实现「不区分大小写的唯一约束」：

```sql
CREATE TABLE t_account (
  id       BIGINT PRIMARY KEY,
  username VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  username_ci VARCHAR(64) AS (LOWER(username)) STORED,
  UNIQUE KEY uk_username_ci (username_ci)
);
```

### 6.2 日期字段的月份统计

```sql
ALTER TABLE t_order
  ADD COLUMN stat_month CHAR(7) AS (DATE_FORMAT(created_at, '%Y-%m')) STORED,
  ADD INDEX idx_month (stat_month);
```

按月聚合的报表 SQL 变成走索引的等值查询，而不是对 `created_at` 做 `DATE_FORMAT` 全表扫描。

⚠️ 注意：MySQL 8.0.13+ 也可以直接建函数索引：

```sql
CREATE INDEX idx_month ON t_order ((DATE_FORMAT(created_at, '%Y-%m')));
```

### 6.3 稀疏字段的过滤索引

```sql
ALTER TABLE t_task
  ADD COLUMN is_failed TINYINT AS (IF(status = 'FAILED', 1, NULL)) VIRTUAL,
  ADD INDEX idx_failed (is_failed);
```

利用 **NULL 不进入索引** 的特性实现「稀疏索引」，只索引失败任务，索引体积缩小几个数量级。这种技巧在任务表、订单异常表里非常好用。

### 6.4 生成列不能当主键 / 外键

```sql
-- 报错
CREATE TABLE t (a INT, b INT AS (a*2) STORED PRIMARY KEY);
ERROR 3106 (HY000): 'Stored generated column' is not supported for primary key
```

同时，**生成列也不能作为外键的引用列**（引用别的表或被别的表引用都有限制）。

---

## 七、常见坑与排查

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `ERROR 3105: The value specified for generated column is not allowed` | INSERT 里显式给了生成列的值 | 从 INSERT 语句里去掉；用 `DEFAULT` 关键字可绕过（8.0） |
| JSON 索引不命中 | SQL 表达式与索引定义不一致（空格、类型转换、`->>` vs `JSON_UNQUOTE`） | 用生成列查询；`EXPLAIN` 验证 |
| 生成列值查出来是 NULL | 基列 NULL 导致表达式返回 NULL | 表达式里用 `COALESCE` / `IFNULL` |
| 从库回放延迟 | STORED 生成列在 ROW 格式下按值复制，不重算 | 正常现象，注意 binlog 行大小 |
| `ERROR 1215` 加外键失败 | 生成列参与外键 | 用普通列替代 |
| `ALTER` 生成列表达式 | 不支持直接改表达式 | `DROP COLUMN` 再 `ADD COLUMN` |

关于 binlog：**STORED 生成列的值会写入 binlog 行事件，VIRTUAL 不会**。这会影响主从数据一致性推导——不过 MySQL 保证从库执行后结果一致，因为从库也定义了同样的生成列定义。

Dump / 迁移时注意：`mysqldump` 会导出生成列定义，但 **不会导出生成列的值**（STORED 也会重新计算），所以导入时耗时会略高。

---

## 八、面试追问合集

**Q1：生成列能更新吗？**
不能直接 `UPDATE col = ?`。但可以 `UPDATE t SET base_col = ?` 间接改变它。MySQL 8.0 允许 `UPDATE t SET gen_col = DEFAULT`（在 `INSERT ... ON DUPLICATE KEY UPDATE` 场景有用）。

**Q2：虚拟列在磁盘上真的不占空间吗？**
数据行不占。如果建了索引，**索引键里会物化虚拟列的值**，所以索引占空间。可以理解为「虚拟列的价值就是把计算转移到索引里」。

**Q3：函数索引和生成列索引哪个性能好？**
完全相同。函数索引在实现层就是隐藏虚拟生成列 + 索引，优化器在 `EXPLAIN` 里看到的是同一个索引。

**Q4：为什么虚拟列上不能建全文索引？**
MySQL 不支持在虚拟生成列上建 `FULLTEXT` 索引（`ERROR 3106`），只能用 STORED 列。

**Q5：生成列能做分区键吗？**
MySQL 8.0 起，`STORED` 生成列可以作为分区键（早期版本有诸多限制），虚拟列不建议。实践中分区键更推荐用普通列。

**Q6：表达式计算会拖慢查询吗？**
虚拟列在无索引时每次读取都要计算，如果表达式涉及 `JSON_EXTRACT` + `CAST`，在百万行扫描时会明显放大 CPU。这也是「虚拟列 + 索引」组合的价值所在。

---

## 九、小结

| 场景 | 推荐方案 |
| --- | --- |
| JSON 属性检索 | VIRTUAL 生成列 + 索引（或函数索引） |
| 频繁读取的计算值 | STORED 生成列 |
| 稀疏过滤 | `AS (IF(cond, 1, NULL))` VIRTUAL + 索引 |
| 大小写/格式规范化唯一约束 | `AS (LOWER(col))` STORED + UNIQUE |
| 大表快速加列 | 必须用 VIRTUAL（ALGORITHM=INSTANT） |

记住三条铁律：

1. **虚拟列的索引会物化值**，所以「虚拟列不占空间」只对数据行成立；
2. **函数索引 = 隐藏虚拟生成列**，表达式的字面一致性决定索引是否命中；
3. **大表加虚拟列是 INSTANT，加 STORED 列是 COPY**，这个差异直接决定你能不能在生产做变更。
