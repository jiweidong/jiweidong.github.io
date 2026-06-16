---
title: MySQL SQL 优化实战：Explain 详解与慢查询调优
date: 2026-06-16 09:20:00
tags:
  - MySQL
  - SQL优化
  - Explain
  - 慢查询
  - 索引优化
categories:
  - 数据库
author: 东哥
---

# MySQL SQL 优化实战：Explain 详解与慢查询调优

## 一、SQL 优化的整体思路

当一个系统变慢时，DBA 或后端开发的第一反应通常是：**查慢查询日志**。优化一条 SQL 不是靠猜，而是靠一套系统化的方法：

```
慢 SQL → 定位问题 → EXPLAIN 分析 → 制定优化方案 → 验证 → 上线
```

### 优化优先级金字塔

```
         ⬆ 收益高                   代码层面
        / \
       /   \                    SQL 改写
      /     \                索引优化
     /       \                   中间件（缓存、读写分离）
    /         \              架构层面（分库分表、多级缓存）
   /___________\              硬件（SSD、内存加大）
```

**80% 的性能问题通过 索引优化 和 SQL 改写 就能解决。**

## 二、慢查询日志配置

```ini
[mysqld]
# 开启慢查询日志
slow_query_log = ON

# 慢查询日志路径
slow_query_log_file = /var/log/mysql/slow.log

# 阈值：超过 1 秒算慢查询
long_query_time = 1

# 记录未使用索引的查询
log_queries_not_using_indexes = ON

# 记录管理语句（ALTER TABLE 等）
log_slow_admin_statements = ON

# 每分钟记录未使用索引的查询数，避免日志爆炸
log_throttle_queries_not_using_indexes = 10
```

```sql
-- 会话级开启（不重启 MySQL）
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;
```

### 分析慢查询日志

```bash
# 使用 mysqldumpslow 分析
mysqldumpslow -s t -t 10 /var/log/mysql/slow.log
# -s t: 按查询时间排序
# -t 10: 取前 10 条

# 使用 pt-query-digest（Percona Toolkit）
pt-query-digest /var/log/mysql/slow.log > digest_report.txt
```

```sql
-- 检查慢查询日志记录条数
SHOW GLOBAL STATUS LIKE 'Slow_queries';

-- 查看最近一条慢查询的时间信息
SELECT * FROM performance_schema.events_statements_history_long
WHERE ROWS_EXAMINED > 10000 ORDER BY TIMER_WAIT DESC LIMIT 10;
```

## 三、Explain 命令详解

`EXPLAIN` 是你优化 SQL 最有力的武器。

```sql
EXPLAIN SELECT * FROM user WHERE age > 18 ORDER BY create_time DESC LIMIT 10;
```

### 3.1 输出字段总览

| 字段 | 含义 | 关键值 |
|------|------|--------|
| id | 执行顺序 | 数字越大优先级越高，相同则从上往下 |
| select_type | 查询类型 | SIMPLE / PRIMARY / SUBQUERY / DERIVED |
| table | 表名 | 别名的表 |
| partitions | 分区匹配 | 未分区则为 NULL |
| **type** | **访问类型** | **system > const > eq_ref > ref > range > index > ALL** |
| possible_keys | 可能用到的索引 | 查询涉及列的索引 |
| **key** | **实际使用的索引** | NULL 表示没用到索引 |
| key_len | 索引长度（字节） | 越精确越好 |
| ref | 参考列 | const / 列名 |
| **rows** | **扫描行数估算** | 越小越好 |
| filtered | 过滤后剩余百分比 | 100% 表示无需额外过滤 |
| **Extra** | **额外信息** | Using index / Using filesort / Using temporary |

### 3.2 type 详解（从好到差）

| type | 含义 | 效率 |
|------|------|------|
| **system** | 只有一条记录的系统表 | 极高 |
| **const** | 主键/唯一索引等值查询 | 极高 |
| **eq_ref** | JOIN 时主键/唯一索引关联 | 高 |
| **ref** | 普通索引等值查询 | 高 |
| **range** | 索引范围查询（>、<、BETWEEN、IN） | 中高 |
| **index** | 索引全扫描 | 中低 |
| **ALL** | **全表扫描** | **极低，必须优化** |

```sql
-- system / const
EXPLAIN SELECT * FROM user WHERE id = 1;          -- const

-- eq_ref
EXPLAIN SELECT * FROM user u JOIN `order` o       -- eq_ref
         ON u.id = o.user_id;

-- ref
EXPLAIN SELECT * FROM user WHERE name = '张三';    -- ref（如果 name 有索引）

-- range
EXPLAIN SELECT * FROM user WHERE age BETWEEN 20 AND 30;  -- range

-- index
EXPLAIN SELECT COUNT(*) FROM user;                 -- index

-- ALL（大忌）
EXPLAIN SELECT * FROM user WHERE mobile = '138xxxx'; -- ALL（无索引）
```

### 3.3 Extra 详解

| Extra | 含义 | 是否需优化 |
|-------|------|-----------|
| **Using index** | **覆盖索引，无需回表** | ✅ 好 |
| **Using where** | 在 Server 层过滤数据 | 正常，但可尝试用索引下推改善 |
| **Using index condition** | 索引下推（ICP） | ✅ 好 |
| **Using filesort** | **文件排序**（内存或磁盘） | ❌ 需优化 |
| **Using temporary** | **使用临时表**（GROUP BY / DISTINCT） | ❌ 需优化 |
| Using join buffer | JOIN 未用索引 | ❌ 需优化 |
| Impossible WHERE | WHERE 永远不成立 | 检查逻辑 |

#### Using filesort 优化

```sql
-- ❌ 文件排序
EXPLAIN SELECT * FROM user WHERE age > 18 ORDER BY create_time;
-- Extra: Using where; Using filesort

-- ✅ 建立联合索引消除排序
CREATE INDEX idx_age_create_time ON user(age, create_time);

-- Extra: Using where; Using index  ✅
```

#### Using temporary 优化

```sql
-- ❌ 产生临时表
EXPLAIN SELECT age, COUNT(*) FROM user GROUP BY age;
-- Extra: Using temporary; Using filesort

-- ✅ 索引优化
CREATE INDEX idx_age ON user(age);
-- Extra: Using index
```

## 四、常见优化场景

### 场景 1：分页偏移大

```sql
-- ❌ 大偏移分页
SELECT * FROM user ORDER BY id LIMIT 100000, 20;
-- 扫描 100020 行后丢弃前 100000 行

-- ✅ 优化：子查询延迟关联
SELECT * FROM user
WHERE id > (
    SELECT id FROM user ORDER BY id LIMIT 100000, 1
)
ORDER BY id LIMIT 20;

-- ✅ 优化：书签分页（需要外部传入上次最后 id）
SELECT * FROM user
WHERE id > 100000
ORDER BY id LIMIT 20;
```

### 场景 2：SELECT * 问题

```sql
-- ❌ 大量无用列传输
SELECT * FROM user WHERE name = '张三';

-- ✅ 只取需要的列，配合覆盖索引
SELECT id, name, age FROM user WHERE name = '张三';
```

### 场景 3：OR 条件改写

```sql
-- ❌ OR 可能导致索引失效
SELECT * FROM user WHERE name = '张三' OR age = 25;

-- ✅ 改为 UNION
SELECT * FROM user WHERE name = '张三'
UNION
SELECT * FROM user WHERE age = 25;

-- ✅ 或者在 MySQL 5.0+ 用 Index Merge 也能优化
-- 需打开 optimizer_switch 的 index_merge 开关
```

### 场景 4：IN + ORDER BY

```sql
-- ❌ IN 会让 ORDER BY 走文件排序
SELECT * FROM user
WHERE age IN (20, 25, 30)
ORDER BY create_time DESC;

-- ✅ 用 UNION ALL 手动排序
(
    SELECT * FROM user WHERE age = 20 ORDER BY create_time DESC LIMIT 10
) UNION ALL (
    SELECT * FROM user WHERE age = 25 ORDER BY create_time DESC LIMIT 10
) UNION ALL (
    SELECT * FROM user WHERE age = 30 ORDER BY create_time DESC LIMIT 10
)
ORDER BY create_time DESC LIMIT 10;
```

### 场景 5：COUNT(*) 优化

```sql
-- InnoDB 中 COUNT(*) 需要遍历，不像 MyISAM 有缓存

-- ✅ 建立二级索引，走索引扫描（比全表扫描小）
-- InnoDB 会选择最小的索引树来 COUNT
SHOW INDEX FROM user;
-- 确保至少有一个很小的二级索引（比如 status 字段）

-- ✅ 估算行数，避免精确 COUNT
EXPLAIN SELECT COUNT(*) FROM user WHERE age > 18;
-- rows 字段就是估算值

-- ✅ 分表后独立计数表
INSERT INTO counter (table_name, count) VALUES ('user', 1)
ON DUPLICATE KEY UPDATE count = count + 1;
```

## 五、Join 优化

### 5.1 Nested Loop Join vs Hash Join

MySQL 8.0.18+ 引入 Hash Join：

```sql
-- MySQL 8.0 之前，无索引的 JOIN 非常慢（BNL）
-- MySQL 8.0 自动使用 Hash Join（无索引时）

EXPLAIN SELECT * FROM t1 JOIN t2 ON t1.id = t2.ref_id;
-- 如果 ref_id 无索引，Extra 显示:
-- Using join buffer (hash join)    ✅ MySQL 8.0

-- 但最好还是给关联字段加索引
ALTER TABLE t2 ADD INDEX idx_ref_id(ref_id);
```

### 5.2 Join 优化原则

```sql
-- 原则 1：小表驱动大表
-- optimizer 会自动选择，但要确保统计信息准确
ANALYZE TABLE orders;

-- 原则 2：关联字段必须有索引
ALTER TABLE orders ADD INDEX idx_user_id(user_id);

-- 原则 3：只取需要的列
-- ❌
SELECT * FROM user u JOIN orders o ON u.id = o.user_id;
-- ✅
SELECT u.name, o.order_no, o.amount
FROM user u JOIN orders o ON u.id = o.user_id;
```

## 六、实战案例调优

### 案例：电商订单列表优化

**原始 SQL：**
```sql
SELECT o.id, o.order_no, o.amount, o.status, o.create_time,
       u.name AS user_name, u.mobile
FROM orders o
LEFT JOIN user u ON o.user_id = u.id
WHERE o.create_time >= '2026-01-01'
ORDER BY o.create_time DESC
LIMIT 20;
```

**Explain 分析：**
```
id  select_type  table  type    key                rows  Extra
1   SIMPLE       o      range   idx_create_time    500K  Using filesort
1   SIMPLE       u      eq_ref  PRIMARY            1
```

**问题：** 扫描 50 万行，还有文件排序

**优化 1：减少扫描范围**
```sql
-- 先只查 id，再关联
SELECT o.id, o.order_no, o.amount, o.status, o.create_time,
       u.name AS user_name, u.mobile
FROM (
    SELECT id, order_no, amount, status, create_time, user_id
    FROM orders
    WHERE create_time >= '2026-01-01'
    ORDER BY create_time DESC
    LIMIT 20
) o
LEFT JOIN user u ON o.user_id = u.id;
```

**优化 2：复合索引覆盖排序和过滤**
```sql
CREATE INDEX idx_create_time_user_id ON orders(create_time, user_id);
```

**优化后 Explain：**
```
id  select_type  table   type    key                     rows  Extra
1   PRIMARY      <derived> ALL                            20  
1   PRIMARY      u       eq_ref  PRIMARY                  1    Using index
2   DERIVED      o       range   idx_create_time_user_id  20   Using index
```

扫描从 50 万降到 20 行。

## 七、优化器 Trace 工具

当 Explain 不够时，可以打开优化器追踪：

```sql
-- 开启追踪
SET optimizer_trace="enabled=on";

-- 执行 SQL
SELECT * FROM user WHERE age > 18 ORDER BY create_time LIMIT 10;

-- 查看优化器决策
SELECT * FROM information_schema.OPTIMIZER_TRACE \G

-- 关闭追踪
SET optimizer_trace="enabled=off";
```

输出包含：
```
{
  "steps": [
    {
      "join_preparation": { ... },  -- 预处理
      "condition_processing": { ... },  -- 条件处理
      "table_dependencies": { ... },  -- 表依赖
      "ref_optimizer_key_uses": { ... },  -- 索引考量
      "rows_estimation": { ... },  -- 行数估算
      "considered_execution_plans": [  -- 选择的执行计划
        {
          "plan_prefix": [],
          "table": "`user`",
          "best_access_path": { ... },
          "cost_for_plan": 1847,
          "rows_for_plan": 719,
          "cost_for_plan": 3198,
          "chosen": false,
          "cause": "cost"
        },
        ...
      ]
    }
  ]
}
```

## 八、SQL 优化 CheckList

| 检查项 | 操作 | 优先级 |
|--------|------|--------|
| type 是否为 ALL 或 index | 加索引 | ⭐⭐⭐⭐⭐ |
| Extra 是否有 Using filesort | 索引排序 | ⭐⭐⭐⭐⭐ |
| Extra 是否有 Using temporary | 索引优化 GROUP BY | ⭐⭐⭐⭐ |
| key_len 是否合理 | 尽量用前缀索引 | ⭐⭐⭐⭐ |
| rows 是否过大 | 增加过滤条件 | ⭐⭐⭐⭐ |
| 是否 SELECT * | 明确列名 | ⭐⭐⭐ |
| 是否覆盖索引 | 索引包含查询列 | ⭐⭐⭐ |
| 分页偏移是否过大 | 子查询或书签分页 | ⭐⭐⭐ |
| JOIN 关联列是否有索引 | 加索引 | ⭐⭐⭐⭐⭐ |
| 是否可以用 UNION 替代 OR | 改写 SQL | ⭐⭐ |

## 九、总结

SQL 优化的核心方法论可以概括为 **"减少 MySQL 做不必要的工作"**：

1. **减少扫描行数**：用索引，不要全表扫描
2. **减少回表次数**：用覆盖索引，索引下推
3. **减少排序开销**：用索引排序消除 filesort
4. **减少数据传输**：用 LIMIT、明确列名
5. **减少临时表**：优化 GROUP BY、DISTINCT

记住：**慢 SQL 优化，90% 靠索引，10% 靠改写 SQL。**
