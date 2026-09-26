---
title: 【MySQL 优化】直方图（Histogram）深度解析：优化器基数估算、统计信息与执行计划稳定性
date: 2026-09-26 08:00:00
tags:
  - MySQL
  - 数据库
  - 性能优化
  - 面试
categories:
  - MySQL
  - 数据库优化
author: 东哥
---

# 【MySQL 优化】直方图（Histogram）深度解析：优化器基数估算、统计信息与执行计划稳定性

## 面试官：数据分布倾斜导致选错索引，你有什么办法？

这是 MySQL 优化里一个非常"内行"的问题。很多人第一反应是"加索引""强制索引""改写 SQL"，但真正切入本质的回答是：

> **问题可能不在索引本身，而在于优化器对基数的估算不准。** MySQL 8.0 引入的**直方图统计（Histogram Statistics）**就是专门用来解决"数据分布倾斜导致的估算失真"的。

下面从优化器成本模型讲到直方图的实现细节、使用限制和线上实践。

## 一、先搞懂优化器"选错"的根源

MySQL 的 CBO（Cost-Based Optimizer）在选择执行计划时，核心输入是**每个条件的过滤后行数估算（estimated rows）**。它需要知道：

- 这个表大概有多少行；
- 某个条件能过滤掉多少（选择性 selectivity = 匹配行数 / 总行数）。

而传统 InnoDB 统计信息只有一个 **cardinality（基数，即不同值的数量）**，估算选择性时用的是：

```
selectivity ≈ 1 / cardinality
```

问题来了：**1 / cardinality 是"平均选择性"，它假设所有值是均匀分布的。**

看看真实世界：

- 订单表 `status` 列：99.5% 是 `PAID`，0.4% 是 `PENDING`，0.1% 是 `CANCELLED`；
- 用户表 `city` 列：一线城市占据绝大多数，长尾城市各有几千人；
- 商品表 `category_id`：头部类目 50 万行，长尾类目 3 行。

`cardinality = 3` 的时候，优化器认为每个值各占 1/3。于是：

```sql
-- 实际只匹配 0.4% 的行（约 4000 行，走索引 + 回表很划算）
-- 优化器却以为匹配 1/3（约 330 万行，全表扫描更划算）
SELECT * FROM orders WHERE status = 'PENDING';
```

计划选错，性能差几十倍。**这就是直方图要解决的问题：把"平均值"换成"分布"。**

## 二、InnoDB 统计信息是怎么来的

在讲直方图之前，必须先讲清楚传统统计信息的机制，因为它们是互补关系。

### 2.1 持久化统计信息

```sql
SELECT * FROM mysql.innodb_table_stats WHERE table_name = 'orders'\G
SELECT * FROM mysql.innodb_index_stats WHERE table_name = 'orders'\G
```

关键参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `innodb_stats_persistent` | ON | 是否持久化统计信息（存到 mysql.innodb_*_stats） |
| `innodb_stats_persistent_sample_pages` | 20 | 更新统计信息时采样多少页 |
| `innodb_stats_transient_sample_pages` | 8 | 非持久化模式下的采样页数 |
| `innodb_stats_auto_recalc` | ON | 表变动超过 10% 时自动重算 |
| `innodb_stats_include_delete_marked` | OFF | 是否统计标记删除的记录 |

### 2.2 采样与"索引下潜"（index dive）

对于**等值条件**，如果索引基数不明确，优化器还可以做 **index dive**：直接在 B+ 树上"潜下去"数区间内的记录数。这种方式精确，但代价是每次都要访问索引页。

参数 `eq_range_index_dive_limit`（默认 200）控制这个行为：

- 条件里 **等值区间数 < 200** → 使用 index dive，精确估算；
- **>= 200**（例如 `IN (1000 个值)`）→ 退回用 `cardinality` 估算，精度下降。

这也解释了那个经典现象：**`IN` 列表一长，执行计划突然就"崩"了**——因为估算方式从"精确下潜"切换成了"平均基数"。

### 2.3 传统统计信息的致命空白

- 只记录**不同值个数**，不记录**每个值的频率**；
- 采样的页数是固定的（20 页），大表采样比例极低；
- 对**非索引列**完全没有统计信息（不参与 index dive），只能靠"表行数 × 常量选择性"猜；
- 对倾斜数据无能为力。

**直方图恰好补上"分布"这一块，尤其是非索引列。**

## 三、直方图是什么：两种桶类型

MySQL 8.0.2 引入列统计直方图。官方文档定义的两类直方图：

### 3.1 单值桶（Singleton）

当**不同值的数量 <= 桶数量**时使用。每个桶精确对应一个值，并记录该值的累计占比。

适合：枚举型、状态型、低基数列（status、type、gender、level）。

```
value = 'CANCELLED'  cumulative_frequency = 0.001
value = 'PENDING'    cumulative_frequency = 0.005
value = 'PAID'       cumulative_frequency = 1.0
```

优化器一看就知道 `status = 'PENDING'` 只有约 0.5% 的行，果断走索引。

### 3.2 等高桶（Equi-height）

当**不同值数量 > 桶数量**时使用。把数据按频率累积切成 N 等份（每份占比约 1/N），每个桶记录一个上界值（不含）和累计频率。

适合：高基数列、数值范围列、时间列。

```
{
  "buckets": [
    [0.001, 100, 0.1],
    [0.002, 500, 0.2],
    ...
  ]
}
```

每个 bucket 是三元组：`[累计频率(不含), 值(桶上界，不含), 累计频率(含)]`。优化器通过这些分位点来估算**范围查询**的选择性：

```sql
-- 优化器可以从直方图推断出 price BETWEEN 100 AND 500 大概覆盖多少行
SELECT * FROM products WHERE price BETWEEN 100 AND 500;
```

**这是直方图最有价值的场景之一：无索引的数值区间查询。**

## 四、动手实践：创建、查看、删除

### 4.1 创建直方图

```sql
-- 对单列创建，桶数量 1 ~ 1024
ANALYZE TABLE orders UPDATE HISTOGRAM ON status WITH 32 BUCKETS;

-- 多列（一次语句，多个列各自独立统计）
ANALYZE TABLE orders UPDATE HISTOGRAM ON status, city WITH 64 BUCKETS;
```

输出：

```
+---------------+---------+----------+---------------------------------------------------+
| Table         | Op      | Msg_type | Msg_text                                          |
+---------------+---------+----------+---------------------------------------------------+
| test.orders   | histogram | status | Histogram statistics created for column 'status'. |
+---------------+---------+----------+---------------------------------------------------+
```

要点：

- 桶数量范围 **1 ~ 1024**；
- 语句会**覆盖**已有的直方图（先删后建）；
- 列上已有直方图时不会报错，直接更新。

### 4.2 查看直方图

直方图存储在 `mysql.column_statistics` 表中（JSON 格式），通过信息模式查看：

```sql
SELECT
  SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
  JSON_PRETTY(HISTOGRAM) AS hist
FROM information_schema.COLUMN_STATISTICS
WHERE TABLE_NAME = 'orders' AND COLUMN_NAME = 'status'\G
```

JSON 内容示例：

```json
{
  "buckets": [
    ["CANCELLED", 0.001],
    ["PENDING", 0.005],
    ["PAID", 1.0]
  ],
  "data-type": "string",
  "null-values": 0.0,
  "last-updated": "2026-09-26 08:00:00.000000",
  "sampling-rate": 1.0,
  "histogram-type": "singleton",
  "number-of-buckets-specified": 32
}
```

关键字段解读：

| 字段 | 含义 |
| --- | --- |
| `histogram-type` | `singleton`（单值桶）或 `equi-height`（等高桶） |
| `buckets` | 桶数组，格式随类型变化 |
| `null-values` | NULL 值占比 |
| `sampling-rate` | 实际采样比例，1.0 表示全量统计 |
| `last-updated` | 统计时间，用于判断是否过期 |

### 4.3 删除直方图

```sql
ANALYZE TABLE orders DROP HISTOGRAM ON status;
ANALYZE TABLE orders DROP HISTOGRAM ON status, city;
```

**注意：`ANALYZE TABLE orders;`（不带 UPDATE HISTOGRAM）不会更新直方图。** 直方图必须显式维护。

## 五、确认优化器到底有没有用直方图

用 optimizer trace 是最直接的手段：

```sql
SET SESSION optimizer_trace = 'enabled=on';
SET SESSION optimizer_trace_max_mem_size = 1048576;

SELECT * FROM orders WHERE status = 'PENDING';

SELECT TRACE FROM information_schema.OPTIMIZER_TRACE\G
```

在 trace 里搜索 `histograms`，能看到类似结构：

```json
"histograms": [
  {
    "database": "test",
    "table": "orders",
    "column": "status",
    "histogram_type": "singleton",
    "buckets": [ ... ],
    "selectivity": 0.0045
  }
]
```

`selectivity: 0.0045` 就是优化器最终采用的过滤比例。对比创建直方图前后的 trace，可以量化收益。

另外用 `EXPLAIN FORMAT=JSON` 看估算行数：

```sql
EXPLAIN FORMAT=JSON
SELECT * FROM orders WHERE status = 'PENDING';
```

关注 `"rows_examined_per_scan"` 与 `"filtered"`。直方图生效后，`filtered` 会从"平均 33.33%"变成更贴近真实的数值。

如果想看真实执行情况：

```sql
EXPLAIN ANALYZE SELECT * FROM orders WHERE status = 'PENDING';
```

它会给出 `actual rows` 与 `estimated rows` 的对比——**估算误差大就是直方图/统计信息的用武之地**。

## 六、使用限制与坑（面试重点）

认真整理一下直方图的限制，这些都是面试官爱追问的点：

| 限制 | 说明 |
| --- | --- |
| 必须显式维护 | 不会随 DML 自动更新，需要 `ANALYZE TABLE ... UPDATE HISTOGRAM` |
| 桶数量上限 1024 | 高基数列精度有限 |
| 只支持列级 | 不能对表达式、函数结果建直方图 |
| 采样受内存限制 | `histogram_generation_max_mem_size` 控制采样规模 |
| 对索引列收益有限 | 索引列还能靠 index dive，直方图主要救"非索引列"和"长 IN 列表" |
| 统计存储为 JSON | 体积随列数与桶数增加，注意 mysql 库的元数据量 |
| 不适用于视图/临时表等对象 | 只针对真实基表列 |

### 6.1 `histogram_generation_max_mem_size`

默认 **20000000 字节（约 20MB）**。如果待统计的列数据超过这个内存额度，MySQL 会改为**采样**，并在 JSON 里反映为 `sampling-rate < 1.0`。

```sql
SHOW VARIABLES LIKE 'histogram_generation_max_mem_size';
```

大表上想拿到全量精度，可以临时调大（注意内存成本）：

```sql
SET SESSION histogram_generation_max_mem_size = 268435456; -- 256MB
ANALYZE TABLE big_table UPDATE HISTOGRAM ON skewed_col WITH 256 BUCKETS;
```

### 6.2 直方图 ≠ 索引

直方图只影响**估算**，不改变**访问方式**。它能让优化器知道"这个条件只过滤出 0.5% 的数据"，但如果那一列上根本没有索引，最终还是要全表扫描。

> **直方图 + 合适的索引 = 1 + 1 > 2；只有直方图没有索引 ≈ 只是让估算更诚实。**

## 七、真实案例：状态列倾斜导致的"错误 JOIN 顺序"

场景：订单表 800 万行，`status` 有 5 个值，其中 `PENDING` 只有 3 万行（0.4%）。另一个 `order_item` 表 4000 万行。

```sql
SELECT o.id, o.amount, i.product_id
FROM orders o
JOIN order_item i ON i.order_id = o.id
WHERE o.status = 'PENDING';
```

**没有直方图时**：优化器认为 `status='PENDING'` 过滤掉 4/5（估算 160 万行），于是选择从 `orders` 先扫 160 万行驱动 `order_item`，或者干脆用 `order_item` 做驱动表。

**有直方图后**：优化器知道 `status='PENDING'` 只有 0.4%，选择 `orders` 走 `idx_status` 取 3 万行再回 `order_item` 关联，成本模型彻底改变。

验证方式：

```sql
EXPLAIN ANALYZE
SELECT ... ;
-- 对比 actual rows vs estimated rows 的差距
```

## 八、维护策略：什么时候该建直方图

不是所有列都值得建。判断标准：

**值得建：**

1. **严重倾斜**且经常出现在 `WHERE` 中的列（status、type、level、region、is_deleted）；
2. **非索引列**上的等值/范围查询；
3. 参与 `JOIN` 的**非索引连接列**（影响驱动表选择）；
4. `IN` 列表很长（超过 `eq_range_index_dive_limit`）的场景；
5. 执行计划不稳定的历史"坏表"。

**不值得建：**

1. 均匀分布、基数很高的列（如自增主键、UUID）——直方图帮不上忙；
2. 极度倾斜但**从不查询**的列——纯浪费元数据；
3. 已有完善索引且 index dive 足够精确的列。

### 自动化维护建议

直方图没有自动重算机制，所以需要纳管：

```sql
-- 每周低峰期重建关键列的直方图
ANALYZE TABLE orders UPDATE HISTOGRAM ON status, city, channel WITH 128 BUCKETS;
```

工程上建议：

1. 把直方图维护写进**发布流程/定时任务**（避免人工遗忘）；
2. 用 `information_schema.COLUMN_STATISTICS` 的 `last-updated` 做**时效告警**；
3. 结合 `performance_schema` 找出高代价 SQL，再定位相关列；
4. 在上线前用 `EXPLAIN ANALYZE` 做 **估算偏差回归**，把"估算误差 > 10 倍"的 SQL 纳入治理清单。

## 九、面试高频追问速查

**Q1：直方图和索引统计信息是什么关系？**
互补。索引统计信息记录基数（不同值数量），直方图记录**分布**（每个值/区间的频率）。前者回答"有多少种值"，后者回答"每种值占多少"。

**Q2：有索引还需要直方图吗？**
需要看情况。索引列的等值查询通常有 index dive 兜底，直方图收益有限；但**非索引列**、**长 IN 列表**（触发 dive 限制）、**多列组合估算**场景下直方图价值明显。

**Q3：为什么我的直方图建了但执行计划没变？**
常见原因：① 直方图已过期（数据变了但没重建）；② 该列本来就能靠 index dive 精确估算，直方图不是瓶颈；③ 优化器在其他地方估算错误（JOIN 基数、临时表）；④ 直方图只改了估算，访问方式仍受限（没有可用索引）。

**Q4：singleton 和 equi-height 怎么选？**
不是"选"，是优化器根据**不同值数量与桶数量**自动决定：不同值数 <= 桶数 → singleton；否则 equi-height。所以给低基数列设置足够桶数，才能拿到 singleton 的精确单值频率。

**Q5：直方图会自动更新吗？**
不会。`ANALYZE TABLE`（不带 `UPDATE HISTOGRAM`）不更新直方图，必须显式执行 `ANALYZE TABLE ... UPDATE HISTOGRAM ...`。

**Q6：直方图和 `innodb_stats_auto_recalc` 有关系吗？**
没有直接关系。后者只影响 InnoDB 持久化统计信息的自动重算，不触发直方图更新。

## 总结

- 优化器选错计划的根本原因之一，是**用平均选择性替代了真实分布**；
- 直方图（MySQL 8.0.2+）通过 **singleton / equi-height** 两种桶把列的真实频率分布告诉优化器；
- 建设方式：`ANALYZE TABLE ... UPDATE HISTOGRAM ON col WITH N BUCKETS`，查看用 `information_schema.COLUMN_STATISTICS`，验证用 optimizer trace 和 `EXPLAIN ANALYZE`；
- 它**只影响估算、不改变访问路径**，要配合索引使用；
- 最大坑是**不会自动更新**，必须纳入运维与发布流程；
- 面试加分点：能讲清 "cardinality vs histogram""index dive vs eq_range_index_dive_limit""估算偏差回归"这三个关键词的内在联系。
