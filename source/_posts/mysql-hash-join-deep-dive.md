---
title: 【MySQL 原理】MySQL 8.0 Hash Join 深度解析：从 BNL 到 Hash Join 的演进、内存控制与实战调优
date: 2026-09-12 08:00:00
tags:
  - MySQL
  - 执行计划
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 原理】MySQL 8.0 Hash Join 深度解析：从 BNL 到 Hash Join 的演进、内存控制与实战调优

## 面试官：MySQL 8.0 之后，EXPLAIN 里的 Block Nested Loop 去哪了？

如果你从 MySQL 5.7 升级到 8.0，重新看一条两表 JOIN 的执行计划，很可能发现原来熟悉的：

```
Extra: Using where; Using join buffer (Block Nested Loop)
```

变成了：

```
Extra: Using where; Using join buffer (hash join)
```

这不是显示文案的改动，而是执行引擎的实质升级 —— **MySQL 8.0.18 引入了真正的 Hash Join**，用来替代经典的 Block Nested Loop（BNL）作为「被驱动表无索引可用」时的默认方案。

这篇我们从原理、执行流程、内存控制、执行计划解读到调优实战，把 Hash Join 讲透。

## 一、先回顾：没有索引时，JOIN 有多惨

假设：

```sql
SELECT o.id, u.name
FROM t_order o
JOIN t_user u ON o.user_id = u.id
WHERE u.city = 'Hangzhou';
```

如果 `t_user.id` 是主键（必然有索引），`t_order` 按条件筛选后行数不多，那就是标准的 **Nested Loop Join（NLJ）**：对外表的每一行，去内表按索引查一次。

问题出在内表**没有可用索引**的等值 JOIN 上。5.7 时代只能退化为 **BNL（Block Nested Loop Join）**：

1. 把外表的若干行（一个 block）读入 `join_buffer`；
2. 扫描内表，对每一行与 buffer 中的行**逐行逐一比较**；
3. 匹配则输出，扫描完一批再读下一批外表数据。

BNL 的复杂度是 **O(外表行数 × 内表行数)**（比较次数），而且内表要被完整扫描多遍。当两张表都是十万级、百万级时，这个代价是灾难性的 —— 这也是「JOIN 慢」在很多老项目里的真实原因。

## 二、Hash Join 的核心思想

Hash Join 把「暴力两两比较」换成了「哈希查找」：

- **Build 阶段**：选择较小的那张表（构建表 / build input），把它的 join key 取出，在内存里建一张**哈希表**（key → row 的哈希桶链表）；
- **Probe 阶段**：扫描另一张表（探测表 / probe input），对每一行的 join key 做一次哈希计算，去哈希表里 O(1) 查找匹配桶，输出结果。

复杂度从 O(N×M) 降到 **O(N + M)**（哈希冲突极少时）。这是数据库领域几十年的经典算法，MySQL 只是迟到地把它实现了。

### 谁做 build，谁做 probe？

优化器会选择**估算行数更少**的一侧作为 build input（这样哈希表更小、更容易放进内存）。这就是为什么：

```sql
-- 优化器会评估两张表过滤后的行数
EXPLAIN FORMAT=TREE SELECT ...;
```

的输出里会出现：

```
-> Inner hash join (o.user_id = u.id)  (cost=...  rows=...)
    -> Table scan on o  (cost=... rows=...)
    -> Hash
        -> Filter: (u.city = 'Hangzhou')
            -> Table scan on u
```

**缩进在 `Hash` 下面的一侧就是 build input**，另一侧是 probe。

## 三、按版本演进的三个关键节点

| 版本 | 能力 |
| --- | --- |
| 8.0.18 | 引入 Hash Join，支持 **等值条件** 的 INNER JOIN，替代 BNL |
| 8.0.20 | 引入 **Hash Join 落盘（on-disk / in-memory spill）**，并扩展到 **Semi-join、Anti-join、Outer Join（LEFT/RIGHT）** |
| 8.0.27+ | 持续优化 hint、统计与代价模型 |

一个重要认知：**Hash Join 只处理等值条件（equi-join）**。非等值（`<`、`>`、`BETWEEN`）仍然只能走 BNL（8.0.18 后 BNL 依然存在，作为非等值场景的兜底，但使用频率大幅下降）。

## 四、内存控制：join_buffer_size 与落盘

Hash Join 的哈希表建在 `join_buffer_size` 大小的内存里：

```sql
SHOW VARIABLES LIKE 'join_buffer_size';   -- 默认 256K
```

如果 build 侧的数据量超过 `join_buffer_size`，有两种命运：

- **8.0.18 及之前**：无法完成，退化/放弃；
- **8.0.20 之后**：启用 **spill to disk（落盘）** —— 把数据按哈希值分区写到临时文件，逐分区加载处理。落盘能保证正确性，但性能会大幅下降。

所以调优的方向很明确：

1. **让 build 侧尽量小**（优化器会自动选小表，但如果统计信息失准，可能选错）；
2. **适当增大 `join_buffer_size`**，但绝不能盲目调大 —— 它是**每个 JOIN 每个会话**的分配。线上 500 并发 × 4 个 JOIN × 8MB = 16GB，直接 OOM。

经验值：

```sql
-- 会话级/全局，参考值，按机器内存与并发量评估
SET GLOBAL join_buffer_size = 4 * 1024 * 1024;  -- 4MB
```

判断是否落盘，可以看：

```sql
SHOW STATUS LIKE 'Created_tmp_disk_tables';
SHOW STATUS LIKE 'Created_tmp_files';
```

以及 `EXPLAIN ANALYZE` 输出中是否出现 `spill` 相关信息。

## 五、与 BNL 的对比

| 维度 | Block Nested Loop | Hash Join |
| --- | --- | --- |
| 适用条件 | 等值/非等值 | 等值 |
| 算法 | 逐行比较 | 哈希查找 |
| 复杂度 | O(N×M) | O(N+M) |
| 内表扫描次数 | 多遍 | 一遍（probe） |
| 内存 | join_buffer 存外表 block | join_buffer 存 build 侧哈希表 |
| 内存不足 | 外外表分批循环 | 8.0.20+ 落盘 |
| 执行计划标识 | `Using join buffer (Block Nested Loop)` | `Using join buffer (hash join)` |
| 支持的 JOIN 类型 | 基础 | INNER / SEMI / ANTI / OUTER（8.0.20+） |

一个直觉理解：BNL 是「拿一批外表行去闯内表」，Hash Join 是「把小表做成字典，再用大表去查字典」。

## 六、执行计划解读与 Hint

### EXPLAIN FORMAT=TREE

```sql
EXPLAIN FORMAT=TREE
SELECT o.id, u.name FROM t_order o JOIN t_user u ON o.user_id = u.id;

-> Inner hash join (o.user_id = u.id)  (cost=12406 rows=9980)
    -> Table scan on o  (cost=0.85 rows=9980)
    -> Hash
        -> Table scan on u  (cost=... rows=1000)
```

读法：`Inner hash join` 说明用的是哈希连接；`Hash` 子树是 build 侧；另一侧是 probe 侧。

### EXPLAIN ANALYZE（8.0.18+）

```sql
EXPLAIN ANALYZE SELECT ...;

-> Inner hash join (o.user_id = u.id)  (actual time=... rows=... loops=1)
    -> Table scan on o  (actual time=... rows=9980 loops=1)
    -> Hash
        -> Table scan on u  (actual time=... rows=1000 loops=1)
```

**这是排查 Hash Join 性能的最佳工具**：它给出真实的 `rows` 和 `time`，一旦发现 `actual rows` 与 `estimated rows` 差一个数量级，就说明统计信息有问题，优化器选错了 build/probe 顺序。

### Hint

```sql
SELECT /*+ HASH_JOIN(o, u) */ ... ;   -- 强制走 hash join
SELECT /*+ NO_HASH_JOIN(o, u) */ ...; -- 禁止 hash join（退回 BNL / NLJ）
```

`HASH_JOIN` / `NO_HASH_JOIN` 在 MySQL 8.0.18+ 可用。生产上通常**不建议长期依赖 hint**，它只适合「已验证优化器选错、且暂时无法通过索引或统计信息解决」的过渡场景。

## 七、什么时候 Hash Join 会赢，什么时候还是会输

**Hash Join 的优势场景：**

1. 两表 JOIN 的**内表没有可用索引**，且过滤后行数较可观；
2. 等值 JOIN，且 build 侧能装进内存；
3. 大表 × 大表，且两边的 join key 选择性都不算极端。

**Hash Join 会输/不该用的场景：**

1. **内表有高选择性索引**：此时 NLJ 每次探测只回表很少几行，O(1) 索引查找往往比「全表 build + 全表 probe」更快。优化器也基本不会选 Hash Join。
2. **build 侧装不下且频繁落盘**：性能可能比 BNL 还差，尤其磁盘随机 IO 贵。
3. **结果集很小**：小数量级的 JOIN，建哈希表的固定开销不划算。
4. **非等值 JOIN**：Hash Join 根本不适用。

## 八、实战调优案例

**场景**：`t_order`（800 万行）JOIN `t_user`（200 万行），`ON o.user_id = u.id`，`t_user` 上 `id` 是主键但 `t_order.user_id` 无索引。`WHERE u.status = 1` 过滤后 `t_user` 只剩 3 万行。

**第一版执行计划：**

```sql
EXPLAIN ANALYZE
SELECT o.id, u.name FROM t_order o JOIN t_user u ON o.user_id = u.id WHERE u.status = 1;

-> Inner hash join (o.user_id = u.id) (cost=...) (actual time=9821ms rows=...)
    -> Table scan on o (actual rows=8000000)
    -> Hash
        -> Filter: (u.status = 1) (actual rows=30000)
            -> Table scan on u (actual rows=2000000)
```

问题分析：

- probe 侧是 `t_order`，**全表 800 万行扫描**且每行都要算哈希、探测；
- build 侧只有 3 万行，哈希表很小，其实资源利用并不均衡；
- 总耗时 9.8s，主要花在 `t_order` 的扫描与哈希计算上。

**优化方案一：在 probe 侧加索引。** 如果业务上还有别的过滤条件，能让 `t_order` 先过滤一部分；或者优化器改用 `u` 作为外表、`o.user_id` 作为驱动索引。

**优化方案二（最有效）：给 `t_order.user_id` 建索引。**

```sql
ALTER TABLE t_order ADD INDEX idx_user_id (user_id);
```

此时优化器大概率放弃 Hash Join，改走 NLJ：`t_user`（3 万行）作外表，每行去 `t_order` 按 `idx_user_id` 精确查找，回表行数与 `t_order` 中该用户的订单数成正比，通常远小于 800 万。

**优化方案三：正确刷新统计信息。** 如果是统计信息过期导致优化器把 800 万行估成 800 行，`ANALYZE TABLE t_order;` 后计划可能立刻回归。

**结论**：Hash Join 是「没索引可用时的最优解」，但它**永远不是你放弃建索引的理由**。能靠索引解决的 JOIN，绝不要指望 Hash Join 兜底。

## 九、常见误区

**误区一：Hash Join 一定比 BNL 快。**
不一定。当 build 侧远超内存、频繁落盘时，Hash Join 可能比 BNL 更慢。永远以 `EXPLAIN ANALYZE` 的实测为准。

**误区二：Hash Join 支持所有 JOIN 类型。**
8.0.18 只支持等值 INNER JOIN；Semi/Anti/Outer 是 8.0.20 才补齐的；非等值永远不支持。

**误区三：看到 `hash join` 就说明没索引。**
也可能是有索引但优化器估算后认为 Hash Join 更便宜（比如内表虽然索引可用，但命中行数极多、回表代价高）。判断依据是 `EXPLAIN` 里的 `possible_keys/key` 以及实际 rows。

**误区四：`join_buffer_size` 越大越好。**
它是 per-session、per-join 分配，盲目调大是典型的 OOM 隐患。

## 十、面试常见追问

**Q1：Hash Join 的 build 侧怎么选？**
优化器按统计信息估算两侧参与 JOIN 后的行数，选择**估算行数更少**的一侧做 build。若统计信息失真，可能选反，导致哈希表落盘、性能骤降 —— 这也是「为什么重启/ANALYZE 之后 SQL 突然变快」的常见解释之一。

**Q2：Hash Join 是内存中一次完成吗？**
不是。内存装得下就一次完成；装不下时 8.0.20+ 会按哈希值分区落盘（grace hash join 思路），分区逐个加载处理，代价显著上升。

**Q3：Hash Join 和 Nested Loop 谁更快？**
取决于索引。内表有高选择性索引时 NLJ 更快（避免构建哈希表、避免全表扫描）；内表无用索引或需大范围扫描时 Hash Join 更快。**没有绝对答案，看优化器成本模型和实测。**

**Q4：为什么 MySQL 直到 8.0.18 才有 Hash Join？**
历史原因是 MySQL 的 JOIN 实现长期围绕 Nested Loop + join buffer 演进，且要保证与「按索引回表」语义、锁语义（RR 下的加锁范围）兼容，工程复杂度高。8.0 重构了执行器并引入迭代器模型（volcano-like），才让 Hash Join 的落地变得可行。

**Q5：Hash Join 对锁有什么影响？**
Hash Join 需要扫描内表（probe/build 全表），在 RR 隔离级别下扫描过程中可能加大量记录锁/间隙锁，锁范围远大于索引驱动的高并发 JOIN。因此 OLTP 热路径上，**能用索引驱动就不要用 Hash Join**。

## 十一、小结

| 要点 | 结论 |
| --- | --- |
| 引入版本 | 8.0.18（等值 INNER JOIN），8.0.20 补齐类型与落盘 |
| 算法 | build 哈希表 + probe 查找，O(N+M) |
| 内存 | 受 `join_buffer_size` 约束，不足则落盘 |
| 标识 | `Using join buffer (hash join)` / TREE 计划里的 `Inner hash join` |
| 最佳实践 | 优先补索引；调大 buffer 要评估并发；用 `EXPLAIN ANALYZE` 验证 |
| 主要风险 | 统计信息失准导致 build 选反、内存不足落盘、RR 下锁范围扩大 |

Hash Join 的加入让 MySQL 在没有索引可用时的 JOIN 从「性能灾难」变成「可接受的兜底」。但请记住它解决的问题是「无索引」，而不是「让你不用建索引」。
