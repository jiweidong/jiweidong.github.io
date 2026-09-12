---
title: 【MySQL 优化】索引合并（Index Merge）深度解析：Intersection、Union 与 Sort-Union 的底层原理与实战
date: 2026-09-12 08:00:00
tags:
  - MySQL
  - 索引优化
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 优化】索引合并（Index Merge）深度解析：Intersection、Union 与 Sort-Union 的底层原理与实战

## 面试官：EXPLAIN 里出现 Using intersect(...) 和 Using union(...) 是什么？

很多人看到 `type` 那一列是 `index_merge` 就懵了 —— 不是说「一个查询只能用一个索引」吗？为什么这里出现了两个索引？

答案是：MySQL 的优化器有一个专门的能力，叫做 **索引合并（Index Merge）**。它允许在**单表查询**中，同时对多个索引进行扫描，然后把各自的结果集在内存里做合并（交集、并集），最终用一个索引扫描的顺序回表。

理解 Index Merge，既能让你在做 SQL 优化时看懂执行计划，也能帮你识别出「看似走了索引、实际上更慢」的陷阱。

## 一、先看一个例子

```sql
CREATE TABLE t_order (
  id          BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id     BIGINT NOT NULL,
  status      TINYINT NOT NULL,
  amount      DECIMAL(10,2),
  created_at  DATETIME,
  KEY idx_user (user_id),
  KEY idx_status (status)
) ENGINE=InnoDB;

EXPLAIN SELECT * FROM t_order WHERE user_id = 100 AND status = 1;
```

如果建的是 `idx_user` 和 `idx_status` 两个**独立单列索引**，在 MySQL 5.6+ 上你很可能看到：

```
+----+-------------+---------+-------------+----------------------------------+
| id | select_type | table   | type        | possible_keys / key / Extra     |
+----+-------------+---------+-------------+----------------------------------+
|  1 | SIMPLE      | t_order | index_merge | idx_user,idx_status; Using intersect(idx_user,idx_status) |
+----+-------------+---------+-------------+----------------------------------+
```

也可以看 `EXPLAIN FORMAT=JSON` 里的 `access_type: "index_merge"` 和 `key_parts`。

而如果是 `OR`：

```sql
EXPLAIN SELECT * FROM t_order WHERE user_id = 100 OR status = 1;
-- Extra: Using union(idx_user,idx_status); Using where
```

这就是 Index Merge 的两种典型形态：**交集（ intersection）** 和 **并集（union）**。

## 二、Index Merge 的本质

先说清楚一个前提：**InnoDB 的二级索引叶子节点上存的是主键值**（如果没有主键就用隐藏的 rowid）。所以「用二级索引查数据」永远分两步：

1. 扫描二级索引 → 拿到一批主键（rowid）；
2. 用主键回表（回聚簇索引）取整行。

Index Merge 做的事情就是：**在步骤 1 阶段，并行/串行地扫描多个二级索引，把各自拿到的 rowid 集合做集合运算，再统一进入步骤 2 回表**。

它的价值在于：

- 对于 `AND` 条件：两个单列索引各自过滤后取交集，能大幅减少回表行数；
- 对于 `OR` 条件：如果不做索引合并，MySQL 只能**全表扫描**（因为「用 A 查出的行」并上「用 B 查出的行」，没有单个索引能同时满足）。索引合并把一个全表扫描变成两次索引范围扫描 + 一次归并，通常快得多。

## 三、三种算法

### 3.1 Intersection（交集）

适用条件：`WHERE` 是 **AND** 连接的多个条件，每个条件都有可用的索引，且**至少有一个索引条件是等值**。

执行逻辑：

1. 分别对 `idx_user`、`idx_status` 做范围扫描，得到两个 rowid 有序集合；
2. 因为扫描时 rowid 是有序的（下标扫描天然按索引顺序），做一次**归并求交**，得到共同 rowid；
3. 按 rowid 回表。

代价点是：如果两个索引扫描出来的 rowid 集合都很大，求交本身也是 O(N)，而且**回表次数取决于交集大小**。

### 3.2 Union（并集）

适用条件：`WHERE` 是 **OR** 连接的条件，每个条件都有可用索引。

执行逻辑：

1. 分别对两个索引做范围扫描，得到两个 rowid 集合；
2. 求并集（去重）；
3. 回表。

关键点：`union` 要求**所有分支的取值范围都能用索引**。只要有一个 OR 分支没有索引可用，整个条件就退化为全表扫描，`Extra` 里会出现 `Using where` 而非 `Using union`。

### 3.3 Sort-Union（排序后并集）

`union` 有一个额外要求：各个分支扫描出来的 rowid **本身就是有序的**、可以直接做归并去重。但有些索引扫描出来的 rowid 不一定全局有序，于是 MySQL 提供了 `Sort-Union`：

1. 各分支先拿到 rowid 集合；
2. **显式排序**（filesort 对 rowid 排序）；
3. 再去重合并；
4. 回表。

`Sort-Union` 的代价明显更高（多了一次排序），所以优化器通常只有在无法使用 `union` 时才退而求其次。

## 四、优化器的成本决策

Index Merge 并不是「有多索引就一定用」。优化器会拿它和以下方案比成本：

- 用其中**最优的一个索引**（`Using index condition` 或普通 range）；
- 全表扫描；
- 走复合索引（如果存在）。

决策受几个开关/因素影响：

```sql
SHOW VARIABLES LIKE 'optimizer_switch'\G
-- index_merge=on
-- index_merge_intersection=on
-- index_merge_union=on
-- index_merge_sort_union=on
```

也可以临时关闭做对比实验：

```sql
SET SESSION optimizer_switch = 'index_merge_intersection=off';
EXPLAIN SELECT ... ;
```

成本模型的大致判断（简化）：

| 方案 | 扫描代价 | 回表次数 | 优化器偏好 |
| --- | --- | --- | --- |
| 单索引 range | 一次索引扫描 | 由该索引选择性决定 | 选择性高时最优 |
| Index Merge Intersection | 两次索引扫描 + 求交 | 交集大小 | 两索引选择性都高时更优 |
| Index Merge Union | 两次索引扫描 + 求并 | 并集大小 | OR 场景下远优于全表扫描 |
| 全表扫描 | 聚簇索引顺序扫 | 无额外回表 | 选择性差时反而最优 |

**统计信息在这里非常关键。** 如果 `ANALYZE TABLE` 之后基数估算严重偏差，优化器很可能选错 —— 这也是为什么「执行计划突然变了」往往能追溯到统计信息过期。

## 五、限制与触发条件（容易踩的坑）

1. **只支持 AND / OR，且每个分支必须是索引可用的简单条件。** 嵌套括号、函数包列、隐式类型转换都可能让索引合并失效。
2. **不支持全文索引（FULLTEXT）参与合并。**
3. **不支持空间索引（SPATIAL）参与合并。**
4. **复合索引与单列索引混用**：如果条件已经在某个复合索引（如 `idx_a_b (a,b)`）里满足，优化器可能选择复合索引而非合并。
5. **Intersection 要求至少一个条件是等值匹配**，否则优化器通常更倾向单索引 + ICP。
6. **回表放大风险**：交集/并集后的 rowid 如果很多，回表就是「随机 IO 风暴」，此时全表扫描（顺序 IO）可能更快。这也是很多「走了索引反而慢」的根源。
7. **锁的范围变大**：在 RR 隔离级别下，优化器为了在 UNION 后仍能按索引顺序回表，可能需要对所有参与扫描的索引加范围锁（而非仅仅 index-only 的 next-key lock），死锁概率上升。这个问题在 `index_merge` + 高并发写时非常真实。

## 六、实战：一次“索引合并反而慢”的排查

**现象**：订单列表查询 P99 从 40ms 涨到 800ms；`EXPLAIN` 显示从 `range` 变成了 `index_merge + Using intersect`。

**排查步骤**：

```sql
-- 1. 看真实执行计划与估算行数
EXPLAIN ANALYZE
SELECT * FROM t_order
WHERE user_id = 100 AND status = 1 AND created_at >= '2026-09-01';
```

`EXPLAIN ANALYZE` 会给出每个算子的**实际耗时与行数**（MySQL 8.0.18+）。如果看到 `Index range scan on t_order using intersect` 的 `actual rows` 远大于 `estimated rows`，基本可以确认统计信息失真导致选错。

```sql
-- 2. 看优化器为什么这么选
SET optimizer_trace = 'enabled=on';
SELECT * FROM t_order WHERE user_id = 100 AND status = 1;
SELECT TRACE FROM information_schema.OPTIMIZER_TRACE\G
SET optimizer_trace = 'enabled=off';
```

`OPTIMIZER_TRACE` 里会列出 `analyzing_range_alternatives`、`index_merge`、`considered_execution_plans` 等候选方案及其成本估算，能直接看到优化器的心路历程。

**根因**：`status` 只有 3 个取值（1/2/3），选择性极差，但统计信息把它估成了 2% 的选择性，于是优化器认为「交集能砍掉 98% 的回表」，实际上交集只砍掉 50%，并且多了一次全索引扫描。

**解决方案**：

1. **建复合索引**，让一个索引吃下多个条件：

```sql
ALTER TABLE t_order ADD INDEX idx_user_status_created (user_id, status, created_at);
-- 之后 EXPLAIN 变为: ref on idx_user_status_created，Extra 为空或 Using index condition
```

2. 如果查询需要回表字段多、且热点明显，进一步做**覆盖索引**：

```sql
ALTER TABLE t_order ADD INDEX idx_user_status_created_cover
    (user_id, status, created_at, amount, id);
-- Extra: Using index（索引覆盖，零回表）
```

3. 临时手段（不推荐长期）：`ANALYZE TABLE` 刷新统计信息，或按业务临时关闭 `index_merge_intersection`。

> 结论：**Index Merge 是优化器的兜底策略，不是你的目标。** 目标永远是「用一个结构正确的复合索引解决问题」。当你在生产里看到 `index_merge`，第一反应应该是「这里是不是缺一个复合索引」。

## 七、Index Merge vs ICP vs Skip Scan

三个概念经常被混在一起，用一张表区分：

| 特性 | 原理 | 适用条件 | 是否回表前过滤 |
| --- | --- | --- | --- |
| Index Merge | 多索引扫描 + 集合运算 | AND/OR 多条件，各自有索引 | 合并后再回表 |
| ICP（索引下推） | 在索引层就对索引列条件过滤 | 复合索引前缀匹配 + 后续列条件 | 是的，减少回表 |
| Skip Scan（8.0.13+） | 复合索引跳过前导列，对后续列做范围扫描 | 前导列基数极低，后续列有索引 | 单索引内 |

**取舍**：如果 `(a, b)` 上已有复合索引，ICP 能让 `a=? AND b=?` 只回表真正命中的行；而 Index Merge 是在**两个独立索引**之间的补丁。有复合索引时，几乎总是复合索引更优。

## 八、面试常见追问

**Q1：为什么 MySQL 一个查询通常只能用一个索引？**
因为回表的顺序取决于索引扫描顺序，多个索引的 rowid 顺序不一致时，无法「边合并边回表」。Index Merge 正是先**把所有 rowid 收齐、在内存里做集合运算并排序**，才解决了这个问题 —— 代价是内存与排序开销。

**Q2：Index Merge 的 rowid 集合放哪里？**
放在 `range` 优化阶段的临时结构里（内存中的有序 rowid 列表/唯一键去重结构），受 `range_optimizer_max_mem_size` 等参数约束。rowid 集合过大时会退化或放弃该方案。

**Q3：为什么 `OR` 条件不建索引会全表扫描？**
`WHERE a=1 OR b=2` 要求返回「满足任一条件」的行。单个索引只能保证其中一个条件有序，无法同时覆盖另一个条件的检索，所以除索引合并外只能全表扫描。

**Q4：什么情况下应该主动避免 Index Merge？**
① 两张单列索引的选择性都不高（如状态、性别）；② 回表行数巨大且表是热表（随机 IO + 加锁范围大）；③ 已存在更合适的复合索引。此时应通过 `optimizer_switch` 或改写 SQL / 建复合索引来避免。

## 九、小结

- Index Merge 是优化器在**无复合索引可用**时，对多个单列索引做交集/并集的兜底优化，分为 `intersect`、`union`、`sort_union` 三类；
- 它解决了「AND 多条件」和「OR 无法走单索引」两个场景，但代价是多次索引扫描、内存集合运算以及潜在的回表放大；
- 生产上看到 `index_merge`，**优先考虑补复合索引（甚至覆盖索引）**，而不是依赖它；
- 排查工具：`EXPLAIN FORMAT=JSON`、`EXPLAIN ANALYZE`、`optimizer_trace`、`optimizer_switch` 开关对照实验。

理解了 Index Merge，你对「MySQL 为什么选了这个执行计划」的理解就又多了一块拼图。
