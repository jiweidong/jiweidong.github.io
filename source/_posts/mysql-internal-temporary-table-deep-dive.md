---
title: 【MySQL 原理】内部临时表深度解析：从内存临时表到磁盘落地的完整链路与优化实战
date: 2026-09-15 08:00:00
tags:
  - MySQL
  - 性能优化
  - 执行计划
  - 面试
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 原理】内部临时表深度解析：从内存临时表到磁盘落地的完整链路与优化实战

## 面试官：我这条 SQL 只查了 3 万行，为什么磁盘 IO 打了 800MB？

这是线上非常经典的一幕：一条看起来「不复杂」的 SQL，执行时间 4 秒，`iostat` 显示写盘量飙到几百 MB，而表本身只有几十万行，结果集也不大。

排查到最后，元凶往往是同一个东西：**内部临时表（Internal Temporary Table）落盘**。

这篇文章把内部临时表从「什么时候产生 → 放在哪 → 怎么一步步被逼到磁盘 → 怎么监控 → 怎么根治」整条链路讲透。这部分内容在面试里属于典型的「区分度考点」——能背 `tmp_table_size` 的人很多，能说清 TempTable 引擎、`temptable_max_mmap` 和派生表物化的人很少。

---

## 一、先搞清楚：什么是内部临时表

MySQL 中「临时表」分两种，很多人混着说：

| 类型 | 创建方式 | 生命周期 | 典型用途 |
| --- | --- | --- | --- |
| **用户临时表** | `CREATE TEMPORARY TABLE` | 会话级，`SESSION` 断开即删 | 业务临时存中间结果、复杂报表 |
| **内部临时表** | 优化器/执行器自动创建 | 语句级，语句结束即释放 | 排序、分组、去重、物化、窗口函数 |

内部临时表是**执行引擎自己用的草稿纸**，对用户不可见。它存在的唯一理由是：某些算子在执行时，必须先把中间结果落地，才能继续下一步运算。

关键点：**内部临时表不是「一定会慢」的东西**。它的性能完全取决于一件事——它到底待在**内存**里，还是被**被迫写到了磁盘**。

---

## 二、什么操作会产生内部临时表

这是面试第一个高频问题。按产生频率排序：

### 2.1 GROUP BY（最高频）

MySQL 8.0 之前，`GROUP BY` 的默认实现就是「建临时表 + 排序」。8.0 引入了 `Hash Aggregation`，但**这不代表不再用临时表**：当分组数据超出内存限制时，Hash Agg 依然会 spill 到磁盘上的临时文件。

```sql
-- 典型：分组字段没有可用索引
SELECT user_id, COUNT(*), SUM(amount)
FROM orders
WHERE created_at >= '2026-01-01'
GROUP BY user_id;
```

如果 `user_id` 上没有可用索引（或 `created_at` 过滤后仍需回表），优化器就会走「临时表 + Filesort」。

### 2.2 ORDER BY + Filesort

`ORDER BY` 时如果**无法利用索引天然有序**，就要排序。MySQL 排序有两种：

- **全字段排序**：把 `SELECT` 需要的所有列都放进排序缓冲区（`sort_buffer_size`），够就内存排，不够就**用临时文件做外部归并排序**（这不是内部临时表，但同样落盘，二者常一起出现）。
- **rowid 排序**：当单行长度超过 `max_length_for_sort_data` 时，只排 rowid + 排序字段，然后回表取数据——**会有两次回表**。

### 2.3 DISTINCT

`DISTINCT` 语义上等价于「按全部输出列 GROUP BY」，因此同样可能物化。

### 2.4 UNION / UNION ALL

这是最容易踩坑的一条，值得单独强调：

```sql
SELECT a FROM t1 UNION SELECT a FROM t2;      -- 会产生临时表（需要去重）
SELECT a FROM t1 UNION ALL SELECT a FROM t2;  -- 不会（直接追加）
```

`UNION` 需要去重 → MySQL 会把两个结果集写进一张内部临时表，再去重。**`UNION ALL` 是完全不同的执行路径**，只要业务允许重复，改成 `UNION ALL` 收益立竿见影。

### 2.5 派生表（Derived Table）物化

```sql
SELECT *
FROM (
  SELECT user_id, COUNT(*) AS cnt FROM orders GROUP BY user_id
) AS d
WHERE d.cnt > 10;
```

这个子查询在 `FROM` 中的表叫派生表。优化器有两种处理策略：

1. **派生表合并（Derived Merge）**：把外层条件「下推」进子查询，和普通 JOIN 一样优化。这是 5.7 引入的 `derived_merge` 优化，默认开启。
2. **派生表物化（Materialization）**：如果无法合并（比如子查询里有 `GROUP BY` + `LIMIT`、聚合函数、`UNION`、窗口函数），就把整个子查询结果物化到**内部临时表**里，然后外层再查这张临时表。

上面这个例子就属于第 2 种——**内层有 `GROUP BY` 且外层条件作用在聚合结果 `cnt` 上，无法下推**，于是必然物化。数据量大时直接落盘。

### 2.6 半连接与子查询物化

`IN`、`EXISTS` 类子查询，优化器可能选择 `Materialization` 策略：把子查询结果物化到临时表并加索引（这是内部临时表**唯一会自动建索引**的场景，叫 auto-generated index），再与外层表做 JOIN。

### 2.7 窗口函数

`ROW_NUMBER()`、`RANK()`、`SUM() OVER()` 等窗口函数，本质是「分组内排序 + 累计计算」，8.0 的实现强依赖内部临时表来缓存窗口帧。

### 2.8 其他

- `INSERT ... SELECT`（当 binlog 为 `STATEMENT` 格式时，MySQL 强制物化以保证主从一致）
- 多表 `UPDATE` / `DELETE`
- `SELECT ... FOR UPDATE` 中涉及排序的场景
- `information_schema` 查询（`SHOW` 类语句几乎必然物化）

---

## 三、内存临时表：从 MEMORY 引擎到 TempTable

### 3.1 5.7 时代：MEMORY 引擎

MySQL 5.7 的内部临时表默认使用 **MEMORY 存储引擎**，特点：

- 数据全在内存，**哈希索引**（不支持 B+ 树，不支持 `TEXT`/`BLOB`）
- 一旦包含 `TEXT`/`BLOB` 列，**立刻退化为磁盘临时表**（InnoDB 或 MyISAM）

这就是那个经典结论的来源：**`SELECT` 里带了 `TEXT` 字段，临时表必落盘。**

判断内存临时表容量的参数：

```sql
SHOW VARIABLES LIKE 'tmp_table_size';         -- 默认 16MB
SHOW VARIABLES LIKE 'max_heap_table_size';    -- 默认 16MB
```

**生效上限取两者较小值**：

```c
/* 伪代码：实际生效的内存临时表上限 */
effective_limit = MIN(tmp_table_size, max_heap_table_size);
```

超过上限 → `Created_tmp_disk_tables` +1，数据转存磁盘。

### 3.2 8.0 时代：TempTable 存储引擎

8.0 引入了一个全新的内部临时表引擎叫 **TempTable**，替代 MEMORY 引擎作为内存临时表的默认实现。核心改进：

- 支持变长列（`VARCHAR`/`TEXT` 不再强制落盘）
- 用 **lock-free 的 concurrent hash / 树**结构，高并发下比 MEMORY 引擎的页级锁好得多
- 内存分配用 **内存块池**，避免频繁 malloc/free
- 支持 **溢出到 mmap 文件**（不是普通磁盘文件，走 page cache），比直接写盘轻得多

相关参数：

```sql
SHOW VARIABLES LIKE 'internal_tmp_mem_storage_engine'; -- TempTable（默认）或 MEMORY
SHOW VARIABLES LIKE 'temptable_max_ram';               -- 默认 1GB，TempTable 可用 RAM 上限
SHOW VARIABLES LIKE 'temptable_max_mmap';              -- 默认 1GB，溢出可用 mmap 上限
SHOW VARIABLES LIKE 'temptable_use_mmap';              -- 8.0.26+ 默认 OFF（用磁盘文件）
```

**8.0 的落盘路径变成了三级**：

```
TempTable 内存块（temptable_max_ram）
    ↓ 超限
mmap 匿名映射文件（temptable_max_mmap，若 temptable_use_mmap=ON）
    ↓ 超限
InnoDB 磁盘临时表（ibtmp1 表空间）
```

这一点非常关键：**很多资料还在说「超过 tmp_table_size 就写磁盘」，那是 5.7 的知识。** 在 8.0 里，`tmp_table_size` 对 TempTable 引擎**已经不生效**了，真正管事的是 `temptable_max_ram`。

### 3.3 磁盘临时表又分两种

当内存扛不住：

| 磁盘临时表 | 存储位置 | 是否共享 | 备注 |
| --- | --- | --- | --- |
| **InnoDB 临时表** | 全局 `ibtmp1` 文件 | 所有连接共享同一文件 | 8.0 默认；每次重启重建，**不会被持久化** |
| **MyISAM 临时表** | 独立 `.MYD`/`.MYI` 文件 | 每连接独立 | 老版本遗留 |

`ibtmp1` 有一个致命特性：**它只增不减**。大量内部临时表跑过之后，`ibtmp1` 会涨到几个 GB 并且不自动收缩，磁盘空间就这么被吃掉了。相关参数：

```sql
SHOW VARIABLES LIKE 'innodb_temp_data_file_path';
-- 默认 ibtmp1:12M:autoextend
```

如果需要收缩，只能重启实例（或用 `innodb_temp_tablespaces_dir` 下的会话级临时表空间配合）。

---

## 四、怎么确认「我的 SQL 用了临时表」

### 4.1 执行计划里看

```sql
EXPLAIN SELECT ...;
```

关注 `Extra` 列：

| Extra 输出 | 含义 |
| --- | --- |
| `Using temporary` | **产生了内部临时表** |
| `Using filesort` | 需要额外排序（可能伴随临时文件） |
| `Using index; Using temporary` | 已用覆盖索引，但分组/去重仍需物化 |
| `Using temporary; Using filesort` | 最糟：物化 + 排序 |

`Using temporary` 出现的位置很关键：它在**派生表那一行**出现，说明是派生表物化；在最外层出现，说明是 `GROUP BY`/`DISTINCT`/`UNION` 物化。

### 4.2 全局状态计数器

```sql
SHOW GLOBAL STATUS LIKE 'Created_tmp%';

-- Created_tmp_tables       本次启动以来创建过的临时表总数（含内存）
-- Created_tmp_disk_tables  其中落盘的数量
-- Created_tmp_files        临时文件数量
```

**经验阈值**：`Created_tmp_disk_tables / Created_tmp_tables > 25%` 就要开始查了。

### 4.3 定位到具体 SQL

```sql
-- 从 performance_schema 看每条语句的临时表情况
SELECT
  DIGEST_TEXT,
  SUM_CREATED_TMP_TABLES,
  SUM_CREATED_TMP_DISK_TABLES,
  SUM_SORT_MERGE_PASSES,
  SUM_NO_INDEX_USED
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC
LIMIT 10;

-- 或在会话里直接查
SELECT * FROM performance_schema.session_status
WHERE VARIABLE_NAME LIKE 'Created_tmp%';
```

这一步是**线上排查的关键**：不要猜，直接按 `SUM_CREATED_TMP_DISK_TABLES` 排序，Top N 就是元凶。

---

## 五、五个实战优化套路

### 5.1 用索引消灭 GROUP BY 临时表

```sql
-- 优化前：Using temporary; Using filesort
SELECT user_id, COUNT(*) FROM orders WHERE status = 1 GROUP BY user_id;

-- 建立联合索引后，使用松散索引扫描 / 有序分组
ALTER TABLE orders ADD INDEX idx_status_user (status, user_id);
-- 优化后：Using index（可能利用 Loose Index Scan，直接跳过临时表）
```

**核心思路**：如果 `GROUP BY` 的列是某索引的**最左前缀**，且索引有序，优化器有机会直接利用索引顺序做分组，不再物化。

### 5.2 避免大字段进入临时表

```sql
-- 差：content 是 TEXT，临时表必落盘
SELECT DISTINCT id, content FROM articles WHERE tag = 'java';

-- 好：先在「窄表」里去重，再回表取内容
SELECT a.id, a.content
FROM articles a
JOIN (SELECT DISTINCT id FROM articles WHERE tag = 'java') AS t ON t.id = a.id;
```

8.0 的 TempTable 引擎虽然支持变长列，但大字段仍会迅速吃满 `temptable_max_ram`。**「先去重，再取宽字段」是通用套路。**

### 5.3 UNION → UNION ALL

```sql
-- 优化前：物化 + 去重
SELECT id FROM t1 UNION SELECT id FROM t2;

-- 优化后：若业务可接受重复（或后续会再聚合）
SELECT id FROM t1 UNION ALL SELECT id FROM t2;
```

如果业务必须去重，也可以考虑把去重交给**唯一索引/临时结果表 + INSERT IGNORE**，让 InnoDB 来干这件事，通常比内存临时表哈希去重更省内存。

### 5.4 派生表改写为 JOIN

```sql
-- 优化前：派生表物化
SELECT * FROM (
  SELECT user_id, SUM(amount) AS total FROM orders GROUP BY user_id
) d WHERE d.total > 1000;

-- 优化后：用 HAVING 下推条件
SELECT user_id, SUM(amount) AS total
FROM orders
GROUP BY user_id
HAVING total > 1000;
```

**这不是等价改写**：`HAVING` 在分组过程中就过滤，优化的本质是让「过滤」提前发生，减少需要物化的行数。8.0 还有 `derived_condition_pushdown`（默认 ON），会把外层条件下推到派生表内部，进一步减少物化数据量。

### 5.5 谨慎用 `SQL_BIG_RESULT` / `SQL_SMALL_RESULT`

```sql
SELECT SQL_BIG_RESULT user_id, COUNT(*) FROM orders GROUP BY user_id;
```

- `SQL_SMALL_RESULT`：告诉优化器结果集小，用内存临时表 + 哈希索引即可
- `SQL_BIG_RESULT`：告诉优化器结果集大，**直接用磁盘临时表 + 排序**，跳过内存哈希

这两个提示是「用确定性换取可控性」，在明确知道数据规模时有用，但滥用会适得其反。日常优先改写 SQL 而不是加 hint。

---

## 六、一个完整的线上排查案例

**现象**：报表接口 P99 从 800ms 涨到 4.2s，`iostat` 显示 `vda` 写 IOPS 从 200 飙到 3000+。

**第一步：确认是不是临时表**

```sql
SHOW GLOBAL STATUS LIKE 'Created_tmp_disk_tables';
-- 比昨天基准值高出 40 倍 → 基本确认
```

**第二步：定位 SQL**

```sql
SELECT DIGEST_TEXT, SUM_CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC LIMIT 5;
```

定位到一条报表 SQL，结构正是：

```sql
SELECT * FROM (
  SELECT shop_id, channel, SUM(amount) total, COUNT(DISTINCT buyer_id) uv
  FROM orders
  WHERE created_at BETWEEN ? AND ?
  GROUP BY shop_id, channel
) d ORDER BY d.total DESC LIMIT 20;
```

**第三步：分析原因**

- 派生表含 `GROUP BY` + 聚合 → **无法合并，必须物化**
- `SELECT *` 把宽字段全带进临时表
- `COUNT(DISTINCT)` 在 8.0 中会额外触发一次「按 `(shop_id, channel, buyer_id)` 去重」的物化
- 时间范围从 7 天扩大到 90 天 → 中间结果从 5 万行涨到 300 万行 → 直接突破 `temptable_max_ram`

**第四步：解决方案**

1. 短期：把 `COUNT(DISTINCT)` 拆成独立子查询并加 `(created_at, shop_id, channel, buyer_id)` 复合索引
2. 中期：`SELECT *` 改为只选必要列，把宽字段（备注、JSON）移出派生表
3. 长期：报表改走 **预聚合 + 冷热分层**（按天写汇总表，查询命中打好的宽表）

**结果**：`Created_tmp_disk_tables` 回落到基线，P99 回到 900ms 以内。

---

## 七、面试常见追问

**Q1：`tmp_table_size` 和 `max_heap_table_size` 到底谁生效？**

取**较小值**。而且这两个参数在 8.0 + TempTable 引擎下**已经不管内部临时表了**（只对 MEMORY 引擎的临时表和用户建的内存表生效），8.0 要看 `temptable_max_ram`。这是最能筛人的一问。

**Q2：为什么 `ibtmp1` 越来越大，删数据也没用？**

`ibtmp1` 是**所有会话共享的 InnoDB 临时表空间**，内部临时表释放后它只做空闲标记、不归还磁盘，`autoextend` 只增不减。解决只能靠控制单次临时表规模（配合 `innodb_temp_data_file_path` 设置上限），或者重启（会重建）。

**Q3：`Using temporary` 一定是坏事吗？**

不一定。如果临时表很小且全程在内存（TempTable 内存块），成本可以忽略。**真正要警惕的是 `Using temporary` 与 `Created_tmp_disk_tables` 同时增长**。把「有没有用临时表」当成问题、而不是「临时表有没有落盘」，是典型的新手误区。

**Q4：如何彻底避免内部临时表？**

不可能也不需要。`DISTINCT`、`UNION`、窗口函数在语义上就要求中间结果，**只能优化规模、不能消除机制**。要消除的是「大」临时表，而不是「有」临时表。

**Q5：派生表合并失败的条件有哪些？**

常见有：子查询含聚合函数（`SUM`/`COUNT`/`GROUP BY`）、`LIMIT`、`UNION`、窗口函数、`DISTINCT`（部分场景）、用户变量赋值。可以用 `EXPLAIN FORMAT=JSON` 看 `materialized_from_subquery` 字段确认走了物化。

---

## 八、一句话总结

> 内部临时表是优化器的草稿纸。**内存里的是同事，磁盘上的是事故。**
>
> 排查靠 `Created_tmp_disk_tables` + `performance_schema`，优化靠「索引消除分组 → 窄表去重 → UNION ALL → HAVING 下推」这套组合拳，8.0 请盯住 `temptable_max_ram` 而不是 `tmp_table_size`。
