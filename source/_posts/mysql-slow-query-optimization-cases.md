---
title: 【MySQL 优化】MySQL 慢查询优化实战：10 个真实案例深度解析
date: 2026-07-23 08:00:00
tags:
  - MySQL
  - SQL优化
  - 慢查询
  - 索引
categories:
  - Java
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 优化】MySQL 慢查询优化实战：10 个真实案例深度解析

## 写在前面

慢查询是影响系统性能的头号杀手。很多"系统变慢"的问题，根源往往就是几条慢 SQL。

本文不讲虚的，直接上 10 个真实生产环境中遇到的慢查询案例，每个案例都包含**慢 SQL 原文 → EXPLAIN 分析 → 问题定位 → 优化方案 → 前后效果对比**，希望能帮你建立一套 SQL 优化的实战方法论。

## 环境准备

先开启慢查询日志（生产环境建议长期开启，定期分析）：

```sql
-- 查看是否开启
SHOW VARIABLES LIKE 'slow_query_log';

-- 开启慢查询日志
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 1;  -- 慢查询阈值：1秒
SET GLOBAL log_queries_not_using_indexes = 'ON';
```

## 案例一：隐式类型转换导致索引失效

### 慢 SQL
```sql
SELECT * FROM orders WHERE order_no = 20260723001;
```

### EXPLAIN 分析
```
type=ALL, rows=542310, Extra=Using where
```
全表扫描，没有走索引。

### 问题定位
`order_no` 字段类型是 `varchar(32)`，但查询条件传了数字。MySQL 发生**隐式类型转换**——将 `varchar` 转换为数字比较，导致索引失效。

### 优化方案
```sql
-- 传入字符串类型
SELECT * FROM orders WHERE order_no = '20260723001';
```

### 效果对比
```
优化前：type=ALL, rows=54万, 耗时 2.3s
优化后：type=ref, rows=1,  耗时 8ms
```

### 避坑指南
参数校验时确保类型匹配，MyBatis 中特别注意：
```xml
<if test="orderNo != null and orderNo != ''">
    AND order_no = #{orderNo}  <!-- 不要写成 ${orderNo} -->
</if>
```

## 案例二：LIMIT 深分页性能灾难

### 慢 SQL
```sql
SELECT id, order_no, amount, create_time 
FROM orders 
ORDER BY create_time DESC 
LIMIT 100000, 20;
```

### EXPLAIN 分析
```
type=ALL, rows=100020, Extra=Using filesort
```
MySQL 需要扫描 10 万行后丢弃前 10 万行，取最后 20 行。

### 优化方案（两种）

**方案一：游标分页（推荐）**
```sql
SELECT id, order_no, amount, create_time
FROM orders 
WHERE create_time < '2026-07-23 00:00:00'
ORDER BY create_time DESC 
LIMIT 20;
```
前端传入最后一条记录的 `create_time`，用 `WHERE` 过滤代替 `OFFSET`。

**方案二：子查询优化**
```sql
SELECT o.id, o.order_no, o.amount, o.create_time
FROM orders o
INNER JOIN (
    SELECT id FROM orders 
    ORDER BY create_time DESC 
    LIMIT 100000, 20
) tmp ON o.id = tmp.id;
```
利用覆盖索引（`id` + `create_time` 的索引）先快速定位主键，再回表。

### 效果对比
```
优化前：耗时 3.8s
方案一：耗时 15ms（翻页越深，优势越大）
方案二：耗时 45ms
```

## 案例三：OR 条件导致索引选择错误

### 慢 SQL
```sql
SELECT * FROM orders 
WHERE status = 'PAID' OR user_id = 12345;
```

### EXPLAIN 分析
```
type=ALL, rows=500000+, Extra=Using where
```
即便 `status` 和 `user_id` 都有独立索引，`OR` 条件也可能导致 MySQL 选择全表扫描。

### 优化方案
```sql
-- 方案一：UNION ALL 替代 OR
SELECT * FROM orders WHERE status = 'PAID'
UNION ALL
SELECT * FROM orders WHERE user_id = 12345 AND status != 'PAID';

-- 方案二：合并索引（MySQL 5.0+ 的 Index Merge 优化，但不可靠）
-- 推荐方案一
```

### 原理说明
`OR` 条件下，MySQL 优化器认为分别走索引再合并的代价可能高于全表扫描。用 `UNION ALL` 明确告诉优化器走哪个索引，且排除了重复行。

## 案例四：前缀匹配模糊查询

### 慢 SQL
```sql
SELECT * FROM products 
WHERE product_name LIKE '%手机%';
```

### EXPLAIN 分析
```
type=ALL, rows=120000, Extra=Using where
```
左模糊匹配无法使用 B+Tree 索引。

### 优化方案
**场景一：必须模糊搜索 → Elasticsearch**
```sql
-- 业务层让位给 ES
POST /products/_search
{
  "query": { "match": { "product_name": "手机" } }
}
```

**场景二：非左模糊 → 改为右模糊**
```sql
-- 可以使用索引
SELECT * FROM products 
WHERE product_name LIKE '华为手机%';
```

**场景三：MySQL 8.0 全文索引**
```sql
ALTER TABLE products ADD FULLTEXT INDEX ft_product_name(product_name);

SELECT * FROM products 
WHERE MATCH(product_name) AGAINST('手机' IN NATURAL LANGUAGE MODE);
```

## 案例五：ORDER BY + LIMIT 的 filesort 陷阱

### 慢 SQL
```sql
SELECT user_id, amount, create_time
FROM orders 
WHERE status = 'PAID' 
ORDER BY create_time DESC 
LIMIT 100;
```

### EXPLAIN 分析
```
type=ref, key=idx_status, rows=32000, Extra=Using filesort
```
虽然走了 `status` 索引过滤，但 `create_time` 排序走了文件排序（filesort）。

### 优化方案
**创建联合索引（最左前缀 + 排序字段）**
```sql
ALTER TABLE orders ADD INDEX idx_status_time (status, create_time);
```

### 效果对比
```
优化前：type=ref, rows=3.2万,  Using filesort, 耗时 340ms
优化后：type=ref, rows=100,   Using index,     耗时 3ms
```
联合索引的叶子节点已经按 `(status, create_time)` 排序，查询直接取前 100 条，无需额外排序。

## 案例六：NOT IN 与 NULL 值陷阱

### 慢 SQL
```sql
SELECT * FROM users 
WHERE id NOT IN (
    SELECT user_id FROM orders WHERE create_time > '2026-01-01'
);
```

### EXPLAIN 分析
```
type=ALL, rows=50000, Extra=Using where
```
子查询很慢，外层也全表扫描。

### 问题定位
`NOT IN` 相关子查询中如果返回了 `NULL`，整个条件变为 `UNKNOWN`，结果集为空。更重要的是，`NOT IN` 通常无法利用索引优化。

### 优化方案
```sql
-- NOT EXISTS 替代 NOT IN
SELECT * FROM users u 
WHERE NOT EXISTS (
    SELECT 1 FROM orders o 
    WHERE o.user_id = u.id 
    AND o.create_time > '2026-01-01'
);
```

### 效果对比
```
优化前：耗时 4.5s
优化后：耗时 0.8s（走了关联子查询索引）
```

## 案例七：函数计算导致索引失效

### 慢 SQL
```sql
SELECT * FROM orders 
WHERE DATE(create_time) = '2026-07-23';
```

### EXPLAIN
```
type=ALL, rows=50万, Extra=Using where
```
`DATE()` 函数包裹了 `create_time` 列，使索引失去作用。

### 优化方案
```sql
-- 改为范围查询
SELECT * FROM orders 
WHERE create_time >= '2026-07-23 00:00:00' 
  AND create_time < '2026-07-24 00:00:00';
```

### 常见函数陷阱汇总
| 错误写法 | 正确写法 |
|---------|---------|
| `WHERE DATE(col) = '2026-07-23'` | `WHERE col >= ... AND col < ...` |
| `WHERE YEAR(col) = 2026` | `WHERE col >= '2026-01-01' AND col < '2027-01-01'` |
| `WHERE SUBSTR(phone,1,3) = '138'` | `WHERE phone LIKE '138%'` |
| `WHERE LENGTH(name) = 5` | 需冗余字段或全文索引 |

## 案例八：多表 JOIN 的驱动表选择错误

### 慢 SQL
```sql
SELECT o.order_no, u.name, p.product_name
FROM orders o
LEFT JOIN users u ON o.user_id = u.id
LEFT JOIN products p ON o.product_id = p.id
WHERE u.level = 'VIP'
ORDER BY o.create_time DESC;
```

### EXPLAIN
```
orders 全表 50万行，驱动表选择错误
```

### 优化方案
```sql
-- 小表驱动大表，先过滤再关联
SELECT o.order_no, u.name, p.product_name
FROM (
    SELECT * FROM users WHERE level = 'VIP'
) u
INNER JOIN orders o ON o.user_id = u.id
LEFT JOIN products p ON o.product_id = p.id
ORDER BY o.create_time DESC;
```

**优化要点：**
1. `INNER JOIN` 替代 `LEFT JOIN`（不影响结果时），让优化器选择更优执行计划
2. 先过滤再 JOIN，减少关联行数
3. 确保 JOIN ON 字段都有索引

## 案例九：长事务导致的锁等待和慢查询

### 现象
某个 UPDATE 慢查询等锁等待了 30 秒，实际执行只要 5ms。

### 慢 SQL
```sql
UPDATE orders SET status = 'SHIPPED' WHERE id = 12345;
```

### 问题定位
```sql
-- 查看当前锁等待
SELECT * FROM information_schema.innodb_lock_waits;

-- 查看长事务
SELECT * FROM information_schema.innodb_trx 
WHERE trx_started < NOW() - INTERVAL 5 MINUTE;
```
发现一个事务已经开启了 15 分钟未提交（事务中混合了多个 SELECT + UPDATE）。

### 优化方案
```sql
-- 1. 杀死长事务
KILL 12345;

-- 2. 代码中确保事务快速提交
@Transactional
public void updateStatus(Long orderId) {
    // 事务中只做必要的操作
    orderDao.updateStatus(orderId, "SHIPPED");
    // 不要在这里执行远程调用或长时间等待
}
```

**最佳实践：**
- 事务中不要包含 RPC 调用、文件上传等慢操作
- `@Transactional` 不要加在 Controller 方法上
- 设置合理的 `innodb_lock_wait_timeout`（默认 50s，建议 5-10s）

## 案例十：数据倾斜导致的分页异常

### 慢 SQL
```sql
SELECT * FROM account_logs 
WHERE user_id = 999 
ORDER BY create_time DESC 
LIMIT 20, 10;
```

### 问题定位
`user_id = 999` 的用户有 200 万条日志数据（刷单/大客户），其他用户平均只有几十条。虽然 `(user_id, create_time)` 联合索引存在，但深分页仍然很慢。

### 优化方案
```sql
-- 对"大用户"特殊处理：游标分页
SELECT * FROM account_logs 
WHERE user_id = 999 
  AND create_time < '2026-07-20 00:00:00'
ORDER BY create_time DESC 
LIMIT 10;

-- 或者对超大数据量的用户做导出/归档，避免在线查询
```

## 慢查询优化方法论总结

诊断一条慢 SQL 的系统性步骤：

```
① 慢查询日志 → 抓到慢 SQL
② EXPLAIN → 看 type/key/rows/Extra
③ SHOW PROFILE → 看具体耗时分布
④ OPTIMIZER TRACE → 看优化器决策过程
⑤ 对症下药 → 加索引 / 改写 SQL / 改表结构
```

**各瓶颈对号入座：**

| EXPLAIN 特征 | 典型问题 | 优化方向 |
|:---|:---|:---|
| type=ALL | 全表扫描 | 加索引 / 检查索引失效原因 |
| Extra=Using filesort | 文件排序 | 建联合索引覆盖排序 |
| Extra=Using temporary | 临时表 | 优化 GROUP BY / DISTINCT |
| rows 很大 | 扫描行数过多 | 增加过滤条件 / 分页优化 |
| key_len 过大 | 索引前缀太长 | 建前缀索引 |
| filtered 很低 | 过滤后数据很少 | 复合索引最左前缀 |

## 面试常见追问

**Q：MySQL 什么时候会选择全表扫描而不走索引？**
A：当优化器评估走索引 + 回表的代价高于全表扫描时。常见情况：① 数据量很小，全表扫描更快；② 查询的数据量超过表的 20-30%（回表代价高）；③ 索引统计信息过旧；④ 隐式类型转换或函数导致索引失效。

**Q：怎么发现慢查询？线上怎么看最慢的前 10 条 SQL？**
A：`mysqldumpslow -s t -t 10 /var/lib/mysql/slow.log` 可以按时间排序取 top 10。或者用 `pt-query-digest`（Percona Toolkit）做更详细的报告分析。

---

以上就是 10 个真实慢查询案例。SQL 优化没有银弹，关键是建立"先 EXPLAIN，再优化，再 EXPLAIN 验证"的习惯。你在生产中还遇到过哪些奇葩慢查询？欢迎交流讨论。
