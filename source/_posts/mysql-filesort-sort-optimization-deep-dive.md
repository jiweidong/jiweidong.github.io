---
title: 【MySQL 优化】MySQL 排序优化深度解析：Using filesort 与索引排序的底层原理
date: 2026-08-21 08:00:00
tags:
  - MySQL
  - SQL优化
  - 索引
categories:
  - 数据库
  - MySQL 优化
author: 东哥
---

# 【MySQL 优化】MySQL 排序优化深度解析：Using filesort 与索引排序的底层原理

## 面试官：EXPLAIN 里出现 Using filesort，到底是不是"用到了磁盘文件"？

先破除一个流传最广的误解：**Using filesort 不等于"在磁盘文件上排序"**。filesort 的意思是"MySQL 自己额外做了一次排序"（区别于直接利用索引的有序性），至于排序发生在内存还是磁盘，取决于排序数据量是否超过 `sort_buffer_size`。绝大多数情况下，filesort 在内存中就完成了。

那优化方向就很明确了：**让 MySQL 别自己排序——直接用索引的有序性**。这就是今天要讲的核心。

## 一、ORDER BY 的两种执行路径

MySQL 处理 `ORDER BY` 只有两条路：

**路径一：利用索引有序性（最优，无 filesort）**

B+ 树索引本身就是有序的，如果 ORDER BY 的字段恰好是索引列（且满足最左前缀、方向一致），MySQL 顺着索引扫描就能拿到有序结果，Extra 显示 `Using index` 或什么都不显示，零额外排序成本。

```sql
-- 联合索引 (city, age)
SELECT * FROM user WHERE city = '杭州' ORDER BY age;
-- age 是索引第二列，且 city 等值匹配满足最左前缀，索引天然有序 → 无 filesort

SELECT * FROM user ORDER BY city, age;  -- 索引顺序 = 排序顺序，无 filesort
SELECT * FROM user ORDER BY city DESC, age DESC;  -- 方向一致，仍可走索引
```

**路径二：filesort（兜底）**

排序字段无法完全由索引提供时，MySQL 取出数据自己排。EXPLAIN 的 Extra 列出现 `Using filesort`。

典型触发场景：

| 场景 | 原因 |
|------|------|
| `ORDER BY name`（无索引） | 没有可用索引 |
| `ORDER BY age`（联合索引 (city,age) 但没带 city） | 不满足最左前缀 |
| `ORDER BY city ASC, age DESC`（方向不一致） | 索引升序无法直接倒序输出 |
| `ORDER BY 表达式/函数`，如 `ORDER BY YEAR(create_time)` | 索引存储的是原值，无法匹配函数结果 |

## 二、filesort 内部到底怎么排？

### 1. 两个阶段：内存排序 + 归并排序

MySQL 先把要排序的数据读进 `sort_buffer`（内存），若数据量超过 `sort_buffer_size`（默认 256KB，8.0.12+ 可动态调整），就把排好序的"块"写到磁盘临时文件，最后做多路归并。所以 filesort 的磁盘 IO 只发生在**超大数据量**时。

### 2. 单路排序 vs 双路排序（旧版本概念，但要懂）

| 模式 | 行为 | 触发条件 | 优缺点 |
|------|------|---------|--------|
| 双路排序（两次扫描） | 只把**排序列 + 主键**放进 sort_buffer，排完后**回表**取完整行 | 行宽超过 `max_length_for_sort_data`（5.7 默认 1024 字节，8.0 已移除该参数） | 省内存，但回表多一次随机 IO |
| 单路排序（一次扫描） | 把**排序列 + 查询的所有列**放进 sort_buffer，直接产出结果 | 行宽小于阈值 | 不回表，但 sort_buffer 容易装不下，触发磁盘归并 |

8.0 移除 `max_length_for_sort_data` 后，统一按"能放就尽量放全字段"的策略，内存够用就单路，装不下就自动走归并。所以 **8.0 下优化重心从"调参数"变成了"让数据量变小"**（比如只 SELECT 需要的列）。

### 3. 一个关键优化：limit 时的堆排序

MySQL 5.6+ 针对 `ORDER BY ... LIMIT N` 做了特殊优化：**不再全量排序，而是用大小为 N 的优先队列（堆）**，扫描一遍只保留前 N 个最小值/最大值，复杂度从 O(n log n) 降到 O(n log N)。所以深分页那种 `LIMIT 100000, 20` 依然要排全量（因为需要前 100020 个），这也是深分页慢的元凶之一。

```sql
-- 这条会被堆排序优化：只需保留最小的 10 个
SELECT * FROM t ORDER BY score LIMIT 10;

-- 这条排全量：必须知道第 100000 名是谁
SELECT * FROM t ORDER BY score LIMIT 100000, 10;
```

## 三、实战：从 EXPLAIN 到改写

建表：

```sql
CREATE TABLE `user` (
  `id` INT PRIMARY KEY AUTO_INCREMENT,
  `city` VARCHAR(32) NOT NULL,
  `name` VARCHAR(32) NOT NULL,
  `age` INT NOT NULL,
  `create_time` DATETIME NOT NULL,
  KEY `idx_city_age` (`city`, `age`),
  KEY `idx_create_time` (`create_time`)
) ENGINE=InnoDB;
```

**案例 1：满足最左前缀 → 索引排序**

```sql
EXPLAIN SELECT id, name FROM user WHERE city = '杭州' ORDER BY age;
-- Extra: 无 filesort（Using index condition 或 Using where）
```

**案例 2：不满足最左前缀 → filesort**

```sql
EXPLAIN SELECT id, name FROM user WHERE city = '杭州' ORDER BY name;
-- Extra: Using filesort（name 不在索引 idx_city_age 中）
```

**优化思路**：把 (city, age) 索引改成 (city, name, age)，或新建 (city, name) 索引，让 ORDER BY 吃上索引。

**案例 3：覆盖索引消除回表**

```sql
-- 只查 id、name，而 idx_city_age 里没有 name → 排序后还要回表取 name
EXPLAIN SELECT name FROM user ORDER BY age LIMIT 10;
-- Extra: Using index condition; Using filesort

-- 改成覆盖索引 (city, age, name) 后：
-- Extra: Using index（全程索引覆盖，无需回表，filesort 消失或成本大降）
```

**案例 4：函数排序导致索引失效**

```sql
EXPLAIN SELECT * FROM user ORDER BY YEAR(create_time) DESC;
-- Extra: Using filesort（函数包裹索引列，索引序失效）

-- 改写：等值范围 + 索引排序
EXPLAIN SELECT * FROM user 
WHERE create_time >= '2026-01-01' AND create_time < '2027-01-01' 
ORDER BY create_time DESC;
-- Extra: Using index condition（无 filesort）
```

**案例 5：深分页优化（延迟关联）**

```sql
-- 慢：先排全量再丢弃前 100000 行
SELECT * FROM user ORDER BY age LIMIT 100000, 20;

-- 快：先用覆盖索引排序定位主键，再回表取 20 行
SELECT u.* FROM user u
JOIN (SELECT id FROM user ORDER BY age LIMIT 100000, 20) tmp
  ON u.id = tmp.id
ORDER BY u.age;
```

## 四、filesort 的调优参数清单

| 参数 | 默认值 | 作用 | 建议 |
|------|--------|------|------|
| `sort_buffer_size` | 256KB | 排序缓冲区大小 | 不要盲目调大（按连接分配），4MB~8MB 对大多数场景足够 |
| `max_sort_length` | 1024 | 排序时每行取多少字节 | 一般不动 |
| `max_length_for_sort_data` | 已移除（8.0） | 单路/双路切换阈值 | 8.0 不用管，靠内存自适应 |
| `innodb_buffer_pool_size` | 128MB | 回表读的缓存 | 回表热点数据尽量进 buffer pool |

**核心心法：优先"消灭"filesort，其次才是"加速"filesort。** 因为再快的 filesort 也快不过索引天然有序。

## 五、面试追问串讲

**Q：什么情况下 filesort 一定无法避免？**
A：排序字段无法被任何索引完整覆盖且方向一致时。比如 `ORDER BY RAND()`、多表 JOIN 后按非驱动表无索引字段排序、`GROUP BY ... ORDER BY` 混合复杂场景。

**Q：filesort 一定比索引排序慢吗？**
A：不一定。数据量很小时（几百行），filesort 在内存里极快，索引排序还要额外维护索引 IO；但数据量大时索引排序完胜。优化时以 EXPLAIN 实测为准。

**Q：为什么 ORDER BY 和 WHERE 条件要一起看？**
A：单独看 ORDER BY 字段有没有索引没意义，必须看 WHERE 是否满足联合索引的最左前缀。索引的排序能力是"从匹配位置开始才有序"，这就是 `(city, age)` 在 `WHERE city='杭州' ORDER BY age` 下生效、在单独 `ORDER BY age` 下失效的原因。

## 总结

`Using filesort` 是 MySQL 排序的兜底路径：内存（sort_buffer）排序 + 超限归并，5.6+ 对 LIMIT 有堆排序优化，8.0 简化了单路/双路参数。优化优先级：**建对联合索引（覆盖 ORDER BY + WHERE）→ 覆盖索引消除回表 → 避免函数包裹排序列 → 深分页用延迟关联 → 最后才调 sort_buffer_size**。面试答出"filesort 不等于磁盘排序 + 最左前缀决定索引排序是否可用 + 堆排序优化 LIMIT"三点，就是满分。
