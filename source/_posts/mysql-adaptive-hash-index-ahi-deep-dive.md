---
title: 【MySQL 底层】自适应哈希索引（AHI）深度解析：哈希结构、命中条件与实战调优
date: 2026-09-22 08:00:00
tags:
  - MySQL
  - InnoDB
  - 索引
  - 自适应哈希索引
  - 面试
categories:
  - MySQL
  - 数据库底层
author: 东哥
---

# 【MySQL 底层】自适应哈希索引（AHI）深度解析：哈希结构、命中条件与实战调优

## 面试官：InnoDB 的索引是 B+ 树，为什么点查还是接近 O(1)？

这个问题乍一听有点"反常识"。B+ 树查找的复杂度是树高，一张千万级表通常是 3~4 层，也就是 3~4 次页访问。既然每次都要走这么多层，为什么线上很多等值查询能快到微秒级？

官方答案里藏着一个很多人只知道名字、不清楚细节的机制：**自适应哈希索引（Adaptive Hash Index，AHI）**。

`SHOW ENGINE INNODB STATUS` 里那几行 `Hash table size`、`hash searches/s`、`non-hash searches/s`，说的就是它。这篇文章把它讲透：它长什么样、什么时候建、什么时候失效、什么时候该关掉，以及为什么"凭感觉关掉它"可能是错的。

---

## 一、AHI 是什么

一句话定义：

> **AHI 是 InnoDB 在内存中为"被频繁访问的 B+ 树页"自动建立的一组哈希索引，用来把某些等值查询的直接定位加速到接近 O(1)。**

几个关键定语：

- **内存中**：只存在于 buffer pool 的内存结构里，不落盘，重启即消失；
- **自动 / 自适应**：不需要 DBA 声明，由 InnoDB 根据访问模式自己判断该给哪些页建；
- **为页建**：哈希的目标是**页（page）**，而不是行。也就是说，AHI 帮你快速找到"包含目标记录的页"，页内再用 page directory 二分查找定位记录；
- **只适用于特定访问模式**：不是所有查询都能用。

所以准确地说，AHI 加速的是"**在 B+ 树里定位到叶子页**"这一步，而不是整个查询。

---

## 二、为什么需要它：一次点查的真实路径

先看没有 AHI 时，一次主键点查 `SELECT * FROM t_order WHERE id = 10086` 走什么：

```
1. 在聚簇索引的根页（root）中二分查找 → 定位到下一层的页号
2. 读该页（若不在 buffer pool 则从磁盘读入）
3. 在页内二分查找 → 再定位下一层
4. 重复 2~3，直到叶子页（通常 3~4 层）
5. 在叶子页的 page directory 中用 slot 二分查找，定位到具体记录
```

每一步都是一次（或几次）内存中的二分查找，看起来不慢，但在**高并发的热点等值查询**下，这个固定开销会被放大：

- 每层都要加/释放页的**读写锁（latch）**，锁竞争是并发热点的主要成本；
- 层数越多，latch 次数越多；
- 对于"同一个 id 被查询成千上万次"的场景，每次都重复走这 4 层，纯属浪费。

AHI 的思路很直白：**如果某个查询模式反复出现，就把"键 → 页"的映射直接缓存下来。**

---

## 三、AHI 的内部结构

### 3.1 哈希表的组织

AHI 的哈希表是**按 buffer pool 页划分的**（8.0 之前是一个全局结构，按页号取模分片；8.0 之后支持 `innodb_adaptive_hash_index_parts` 分区）：

```
                 AHI Hash Table
   ┌──────────────────────────────────────────┐
   │  hash(key) ──► bucket ──► 链上的 hash node │
   └──────────────────────────────────────────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
      (搜索键前缀 → 页)              (搜索键前缀 → 页)
```

每个 hash node 记录的核心信息：

| 字段 | 作用 |
|---|---|
| 搜索键（search key） | 由**索引前缀**构造，比如 `(index_id, 前缀列值)` |
| 目标页号 | 命中的叶子页 |
| 当前记录 | 该键对应的记录指针（用于判断是否需要更新映射） |
| 链表指针 | 处理哈希冲突（链地址法） |

### 3.2 搜索键是什么

这是理解 AHI 适用范围的**核心**。AHI 的搜索键基于**索引的前缀**，构造规则大致是：

```
search key = (index_id, 前缀列1的值, 前缀列2的值, ...)  + 额外机制
```

由此推出两条重要结论：

1. **等值查询才可能用 AHI**：哈希只能精确匹配，`=` 可以，`>`、`<`、`BETWEEN`、`LIKE '%x'` 不行；
2. **前缀唯一性有影响**：
   - 如果是**唯一索引的完整等值条件**，键直接唯一确定记录，很容易建 AHI；
   - 如果是**非唯一索引**，同一个键对应多行，InnoDB 需要额外处理（记录位置等）来区分；
   - 如果有**范围条件混入**，前缀后面的部分无法用于哈希定页，AHI 可能就不命中或者不建。

### 3.3 覆盖哪些查询

| 查询形态 | 能用 AHI 吗 |
|---|---|
| 主键等值：`WHERE id = 1` | ✅ 最典型 |
| 唯一索引等值：`WHERE uk_col = 'x'` | ✅ |
| 普通索引等值：`WHERE idx_col = 'x'` | ✅（可能有额外处理） |
| 联合索引最左前缀等值：`WHERE a = 1 AND b = 2` | ✅ |
| 范围查询：`WHERE a > 1` | ❌ |
| 前缀模糊：`WHERE name LIKE 'abc%'` | ❌ |
| 无索引条件 | ❌（本来走全表扫描） |
| 全表扫描 / 大范围扫描 | ❌ |

---

## 四、什么时候会被自动建立

AHI 是"自适应"的，触发条件在源码里表现为**对同一页的同一模式访问达到阈值**（大致是同一个搜索模式对同一个页被访问若干次后建立）。工程上可以这样理解：

**必要条件**：

1. 查询能构造出稳定的搜索键（等值 + 索引前缀）；
2. 该搜索键对应的**页被反复访问**（热点页）；
3. `innodb_adaptive_hash_index = ON`（默认开启）。

**加分条件**（更容易被建）：

- 索引前缀的**区分度高**（哈希冲突少，收益明显）；
- 访问**集中在少数页**（热点明显），比如热点商品、热门用户、订单号点查；
- 系统以**读为主**。

### 4.1 一个直观的例子

```sql
-- 假设 t_user 有主键 id，且以下查询被高频执行
SELECT * FROM t_user WHERE id = ?;   -- 每次传不同 id

-- 对于"某些 id 被反复查询"（比如登录用户），
-- 这些 id 对应的叶子页被反复访问 → InnoDB 自动为这些页建立 AHI 条目
-- 之后定位这些页就不再需要走完整 B+ 树

SHOW ENGINE INNODB STATUS\G
-- ...
-- Hash table size 34679, node heap has 12 buffer(s)
-- 0.00 hash searches/s, 12345.67 non-hash searches/s
-- ...
```

---

## 五、性能收益与代价

### 5.1 收益

- **减少 B+ 树层数遍历**：热点等值查询从"3~4 次页定位 + 多次 latch"降到"1 次哈希查找 + 1 次 latch"；
- **减少读锁竞争**：定位路径变短，页 latch 的持有次数下降；
- 对**高并发点查**场景（如用户中心、配置读取、订单详情）收益最明显，官方文档给出的经验数据是**可提升几倍**的查询效率。

### 5.2 代价

AHI 不是免费的：

| 代价 | 说明 |
|---|---|
| 内存占用 | 哈希节点、桶结构都属于 buffer pool 之外的额外内存（不算在 buffer pool 统计里） |
| 维护成本 | 对 AHI 覆盖的页做 DML/LRU 淘汰时，需要同步删除/更新哈希条目，读锁之外还要拿**索引锁（btr_search_latch）** |
| **全局 latch 竞争** | 8.0 之前 AHI 是一个受 `btr_search_latch` 保护的全局结构，高并发下这个 latch 本身会成为瓶颈 |
| 不适用场景负收益 | 写密集、范围查询为主、访问分散时，建了也没用，还白占内存 |

### 5.3 8.0 的关键改进

MySQL 5.7 及之前，AHI 的 `btr_search_latch` 是**全局读写锁**，这是著名的可扩展性瓶颈之一。MySQL 8.0 引入了：

```ini
innodb_adaptive_hash_index_parts = 8   # 默认 8，范围 1~512
```

把 AHI 拆成多个分区，每个分区一把锁，显著降低了高并发下的 latch 竞争。另外 8.0 对 AHI 的淘汰与内存管理也做了优化。

**这带来一个重要结论**：网上那些"高并发一定要关掉 AHI"的经验，很多是 5.6/5.7 时代的产物；在 8.0 + 多分区下，该结论需要重新评估。

---

## 六、监控：怎么判断 AHI 是否有效

### 6.1 `SHOW ENGINE INNODB STATUS`

```
-------------------------------------
INSERT BUFFER AND ADAPTIVE HASH INDEX
-------------------------------------
Ibuf: size 1, free list len 0, seg size 2, 0 merges
merged operations:
 insert 0, delete mark 0, delete 0
discarded operations:
 insert 0, delete mark 0, delete 0
Hash table size 34679, node heap has 0 buffer(s)
Hash table size 34679, node heap has 1 buffer(s)
Hash table size 34679, node heap has 2 buffer(s)
...
0.00 hash searches/s, 458.31 non-hash searches/s
```

解读要点：

| 字段 | 含义 | 关注什么 |
|---|---|---|
| `Hash table size` | 哈希表桶数 | 反映 AHI 规模 |
| `node heap has N buffer(s)` | 各分区占用的内存块数 | 是否为 0（说明完全没建） |
| `hash searches/s` | 每秒命中 AHI 的次数 | **越高越好** |
| `non-hash searches/s` | 每秒未命中 AHI 的次数 | **越低越好** |

**核心判断指标就是那个比值**：

```
AHI 命中率 ≈ hash searches/s / (hash searches/s + non-hash searches/s)
```

- 命中率高（比如 > 80%）→ AHI 有效，保持开启；
- `hash searches/s = 0` 且 `node heap has 0 buffer(s)` → AHI 根本没建起来（可能全是范围查询/无热点），可考虑关闭省内存；
- 命中率低但内存占用高 → 考虑关闭或调小分区。

### 6.2 5.7+ / 8.0 的系统变量

MySQL 5.7 起，`SHOW ENGINE INNODB STATUS` 中的很多计数器在**被读取后会被清零**（因为是"每秒速率"的分子），不便于持续监控。8.0 提供了 `information_schema.innodb_metrics`：

```sql
-- 开启监控采集
SET GLOBAL innodb_monitor_enable = 'adaptive_hash%';
-- 或
UPDATE information_schema.innodb_metrics
   SET STATUS = 'enabled'
 WHERE NAME LIKE 'adaptive_hash%';

SELECT NAME, COUNT, STATUS
FROM information_schema.innodb_metrics
WHERE NAME LIKE 'adaptive_hash%';

-- 典型条目：
-- adaptive_hash_searches              命中次数
-- adaptive_hash_searches_btree        未命中（退化为 B+ 树搜索）次数
-- adaptive_hash_pages_added           新建的哈希条目
-- adaptive_hash_pages_removed         删除的哈希条目
```

**监控建议**：把 `adaptive_hash_searches` 与 `adaptive_hash_searches_btree` 做成长期监控，算命中率和趋势，比每次手动 `SHOW ENGINE INNODB STATUS` 可靠得多。

### 6.3 用 performance_schema 看 latch 等待

AHI 真正的隐藏成本在 latch 竞争上：

```sql
SELECT EVENT_NAME, COUNT_STAR, SUM_TIMER_WAIT/1e9 AS total_ms
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE EVENT_NAME LIKE '%btr_search%'          -- 8.0 之前
   OR EVENT_NAME LIKE '%latch%'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

如果 AHI 相关 latch 的累计等待时间很高，说明它已经从"加速器"变成了"竞争点"——这才是关闭 AHI 的真正依据。

---

## 七、到底要不要开：分场景给结论

不要凭一句"听说高并发要关"就改配置。按下面的决策树走：

```
你的负载以什么为主？
│
├─ 高并发「等值点查」为主（用户中心/商品详情/订单详情）
│   └─ 保持 innodb_adaptive_hash_index = ON
│      原因：AHI 正是为这类场景设计的，
│            8.0 多分区已大幅缓解 latch 竞争
│
├─ 「范围查询 / 全表扫描 / 大报表」为主
│   └─ 可以考虑关闭，AHI 基本建不起来（看 hash searches/s ≈ 0）
│      省下内存与维护开销
│
├─ 「写密集」（大量 INSERT/UPDATE/DELETE，如日志、埋点表）
│   └─ 倾向关闭
│      原因：写会让 AHI 条目频繁失效，维护成本 > 收益
│
└─ 高并发 + 出现明显 latch 竞争（performance_schema 佐证）
    └─ 优先调大 innodb_adaptive_hash_index_parts（8.0）
       仍无改善再评估关闭
```

### 7.1 动态开关与热关闭

```sql
-- AHI 支持动态开关，无需重启
SET GLOBAL innodb_adaptive_hash_index = OFF;   -- 关闭
SET GLOBAL innodb_adaptive_hash_index = ON;    -- 开启

-- 关闭时 InnoDB 会清空整个哈希表并释放内存
-- 开启后会根据后续访问重新逐步建立
```

**一个重要提醒**：`SET GLOBAL innodb_adaptive_hash_index = OFF` 在 8.0 中，如果 AHI 正在被使用，这个过程可能需要等待一些时间（要清理已有条目）。线上操作建议在低峰期做，并观察是否出现短时抖动。

### 7.2 一个真实案例

某用户中心实例，8 核 16G，QPS 约 1.2 万，几乎全是 `WHERE user_id = ?` 的点查。

```
调优前：
  hash searches/s ≈ 0
  non-hash searches/s ≈ 11000
  node heap has 0 buffer(s)

排查发现：应用连接使用了新版本的 8.0.x，且 buffer pool 较小（2G），
热数据不断被换出，AHI 条目频繁失效，几乎建不起来。

调整：
  innodb_buffer_pool_size 从 2G 提到 8G（先让热页稳定常驻）
  innodb_adaptive_hash_index_parts 保持默认 8

调优后：
  hash searches/s ≈ 9000+
  non-hash searches/s ≈ 1500
  P99 从 12ms 降到 5ms 左右
```

**教训**：AHI 的前提是"热页稳定"。如果 buffer pool 太小导致页频繁换出，AHI 根本建不起来，这时候该调的是 `innodb_buffer_pool_size`，而不是去折腾 AHI 开关。

---

## 八、AHI 在 InnoDB 加速体系中的位置

把 AHI 和其他几个常被混淆的机制放在一起看：

| 机制 | 加速对象 | 适用查询 | 是否持久化 |
|---|---|---|---|
| **自适应哈希索引 AHI** | 定位到**页**（等值） | 等值查询、热点页 | 否（内存） |
| **Change Buffer** | 非唯一二级索引的**写** | INSERT/UPDATE/DELETE | 否（内存，刷盘到表空间） |
| **Buffer Pool** | **页的读写**（减少磁盘 IO） | 所有 | 否（内存） |
| **B+ 树本身** | 数据定位 | 等值 + 范围 | 是（磁盘） |
| **索引下推 ICP** | 减少回表/读取行数 | 联合索引 + 条件过滤 | 是（执行优化） |

一个容易混的点：**AHI 与 Change Buffer 都挂在 buffer pool 的页上，但前者服务于读，后者服务于写。** 面试时能把这张表说清楚，说明你对 InnoDB 内存体系有整体认识。

---

## 九、面试常见追问

**Q1：AHI 是索引吗？会落盘吗？**

它是内存中的哈希结构，不落盘、重启即消失，也不算严格意义上的"索引"。它是 B+ 树索引的**缓存/加速层**。

**Q2：AHI 命中后还需要回表吗？**

需要区分：AHI 只帮你快速定位到**叶子页**。如果是二级索引查询，仍然要拿主键回表（如果需要的列不在索引里）。AHI 省的是"在 B+ 树里找页"的过程，不改变索引本身的性质。

**Q3：为什么范围查询用不了 AHI？**

哈希的本质是精确映射，`>`、`<`、`BETWEEN` 这些条件无法构造出确定的哈希键。范围查询只能靠 B+ 树的有序性做区间扫描。

**Q4：AHI 会不会和 buffer pool 抢内存？**

AHI 的结构内存**独立于 buffer pool**（不计入 `innodb_buffer_pool_size`），由 InnoDB 额外分配。这也是为什么"建了很多 AHI 条目"会推高整体内存使用。8.0 里可通过 `node heap buffer(s)` 观察其规模。

**Q5：为什么有时 `hash searches/s` 一直是 0？**

常见原因：① 负载是范围查询/全表扫描；② 热页不稳定（buffer pool 太小，页被频繁换出，条目频繁失效）；③ 查询条件的前缀无法构成有效搜索键（比如索引列上用了函数、隐式类型转换导致条件不是纯等值）；④ AHI 被关闭了。

**Q6：`innodb_adaptive_hash_index_parts` 调大有什么代价？**

分区越多，每个分区越小，锁竞争越小；但内存开销略增（每个分区有独立的桶和堆），且条目分布可能不均。默认 8 对多数场景够用，极端热点再考虑调大（如 16/32），不建议盲目设到 512。

**Q7：AHI 和"查询缓存（Query Cache）"是一回事吗？**

完全不是。Query Cache 缓存的是 **SQL 文本 → 结果集**，对任何写操作都会导致相关表缓存全部失效，MySQL 8.0 已彻底移除。AHI 缓存的是 **索引键 → 页位置**，粒度更细、失效成本更低、也不依赖 SQL 文本。把这两个混为一谈是经典错误。

---

## 十、总结

- **AHI 是 InnoDB 自动维护的内存哈希结构**，把"热点等值查询在 B+ 树中定位页"的过程加速到接近 O(1)，不落盘、重启即失效。
- **只适用于等值 + 索引前缀** 的查询，范围查询、模糊查询、无索引扫描都用不上。
- **收益**：热点点查更快、页 latch 更少；**代价**：额外内存 + 维护成本 + 潜在的 latch 竞争。
- **监控指标**：`hash searches/s` vs `non-hash searches/s` 的命中率，配合 8.0 的 `information_schema.innodb_metrics` 里 `adaptive_hash_*` 做长期观察；latch 竞争用 `performance_schema` 佐证。
- **开不开**：高并发等值点查 → 开（8.0 多分区已缓解瓶颈）；范围查询/写密集/访问分散 → 可关；热页不稳时，先调大 buffer pool 而不是关 AHI。
- **别和 Query Cache 混淆**：前者缓存"键 → 页"，后者缓存"SQL → 结果"，后者已在 8.0 移除。

一句话记住：**AHI 是"读路径上的热页近路"，短路的是 B+ 树的下降过程，代价是内存和一把（曾经全局的）锁。**
