---
title: MySQL 架构设计与 SQL 执行流程详解
date: 2026-06-16 09:00:00
tags:
  - MySQL
  - 架构
  - SQL执行流程
categories:
  - 数据库
author: 东哥
---

# MySQL 架构设计与 SQL 执行流程详解

## 一、引言

很多开发者写 SQL 写了好几年，MySQL 也用了好几年，但你有没有想过：**当你输入 `SELECT * FROM user WHERE id = 1` 敲下回车后，MySQL 内部到底发生了什么？**

今天我们就从 MySQL 的架构入手，把这条 SQL 的"一生"完整剖析一遍。这是 MySQL 学习的第一课，也是理解索引、锁、优化等高阶知识的基石。

## 二、MySQL 整体架构

MySQL 的架构分为三层：

```
+---------------------------------------------------+
|                  连接层（Client）                     |
|   Connectors: JDBC / ODBC / .NET / Python           |
+---------------------------------------------------+
                      |
                      v
+---------------------------------------------------+
|                  服务层（Server）                    |
|  +---------+  +---------+  +---------+             |
|  | 连接器  |  | 查询缓存 |  | 解析器   |             |
|  +---------+  +---------+  +---------+             |
|  +---------+  +---------+  +---------+             |
|  | 优化器  |  | 执行器  |  | 存储引擎 |             |
|  +---------+  +---------+  +---------+             |
+---------------------------------------------------+
                      |
                      v
+---------------------------------------------------+
|                   存储引擎层                         |
|  +----------+  +----------+  +---------+           |
|  |  InnoDB  |  |  MyISAM  |  | Memory  |           |
|  +----------+  +----------+  +---------+           |
+---------------------------------------------------+
                      |
                      v
+---------------------------------------------------+
|                   文件系统                           |
|  +----------+  +----------+  +---------+           |
|  |  ibd文件 |  |  frm文件  |  | 日志文件 |           |
|  +----------+  +----------+  +---------+           |
+---------------------------------------------------+
```

### 2.1 各层职责

| 层次 | 组件 | 职责 |
|------|------|------|
| 连接层 | 连接器 | 管理连接、验证权限 |
| 服务层 | 连接池 | 复用连接，减少线程创建 |
| 服务层 | 查询缓存 | 缓存查询结果（8.0 已移除） |
| 服务层 | 解析器 | 词法/语法分析，生成解析树 |
| 服务层 | 预处理器 | 检查表和列是否存在 |
| 服务层 | 优化器 | 选择执行计划 |
| 服务层 | 执行器 | 调用存储引擎 API 执行 |
| 引擎层 | InnoDB/MyISAM | 真正读写数据 |

## 三、一条 SQL 的执行过程

以最常见的查询为例：

```sql
SELECT u.name, o.amount
FROM `user` u
JOIN `order` o ON u.id = o.user_id
WHERE u.age > 18 AND o.status = 1
ORDER BY o.create_time DESC
LIMIT 10;
```

### 3.1 第一步：连接器 — 建立连接

```bash
# 客户端连接
mysql -h 127.0.0.1 -P 3306 -u root -p
```

连接器做的事情：

1. 校验用户名和密码
2. 从 `mysql.user` 表查询权限并缓存
3. 将连接加入到 `SHOW PROCESSLIST`

```sql
-- 查看当前连接
SHOW PROCESSLIST;
-- 查看连接超时配置
SHOW VARIABLES LIKE 'wait_timeout';
-- 查看最大连接数
SHOW VARIABLES LIKE 'max_connections';
```

**重要配置：**

```ini
[mysqld]
max_connections = 500           # 最大连接数，默认151
wait_timeout = 28800            # 非交互连接超时(秒)
interactive_timeout = 28800     # 交互连接超时(秒)
```

### 3.2 第二步：查询缓存（MySQL 8.0 前）

```sql
-- MySQL 5.7 查看缓存配置
SHOW VARIABLES LIKE 'query_cache%';
```

> **注意：** MySQL 8.0 已彻底移除查询缓存。原因是并发环境下缓存失效太频繁，反而成为性能瓶颈。

### 3.3 第三步：解析器 — 词法和语法分析

解析器做两件事：

**词法分析：** 把 SQL 拆成 token
```
SELECT, u.name, o.amount, FROM, user, u, JOIN, order, o, ON, ...
```

**语法分析：** 根据 MySQL 语法规则生成解析树

```
          SELECT
         /   |   \
     列列表   FROM    WHERE
      /  \    /  \     /  \
   u.name o.amount JOIN  age>18
                   /  \    AND
                 user  order status=1
```

如果语法错误，会收到：
```sql
-- ❌ 语法错误示例
SELECT * FORM user;
ERROR 1064 (42000): You have an error in your SQL syntax; check the manual...
```

### 3.4 第四步：预处理器 — 语义检查

检查表和列是否存在、是否有歧义：

```sql
-- ❌ 表不存在
SELECT * FROM nonexistent;
ERROR 1146 (42S02): Table 'test.nonexistent' doesn't exist

-- ❌ 列不存在
SELECT unknown_column FROM user;
ERROR 1054 (42S22): Unknown column 'unknown_column' in 'field list'
```

### 3.5 第五步：优化器 — 选择最佳执行计划

这是最核心的环节。优化器会考虑多种执行方式并选择成本最低的：

```sql
-- 查看执行计划
EXPLAIN SELECT u.name, o.amount
FROM user u
JOIN `order` o ON u.id = o.user_id
WHERE u.age > 18 AND o.status = 1;

-- 查看优化器成本
SHOW STATUS LIKE 'last_query_cost';
```

优化器决策内容：

| 决策 | 可能的选项 | 判断依据 |
|------|-----------|---------|
| 驱动表选择 | user 驱动 / order 驱动 | 索引、行数估算 |
| 索引选择 | 走索引 / 全表扫描 | 区分度、基数 |
| JOIN 算法 | Nested Loop / Hash Join | 表大小、索引 |
| ORDER BY | 文件排序 / 索引排序 | 索引覆盖情况 |

**优化器可能"选错"的原因：**

```sql
-- 1. 统计信息过期
ANALYZE TABLE user;           -- 重新统计
SHOW TABLE STATUS LIKE 'user'; -- 查看统计信息

-- 2. 使用 FORCE INDEX 强制指定索引
SELECT * FROM user FORCE INDEX(idx_age) WHERE age > 18;
```

### 3.6 第六步：执行器 — 执行计划

执行器根据优化器的计划，调用存储引擎的 API 逐条执行：

```java
// 伪代码：执行器的 Nested Loop Join 过程
ResultSet executeQuery(QueryPlan plan) {
    // 1. 打开驱动表（outer table）
    Cursor outer = storageEngine.open(plan.outerTable, plan.outerCondition);
    
    // 2. 逐行遍历
    ResultSet result = new ArrayList<>();
    while (outer.next()) {
        Row outerRow = outer.getRow();
        
        // 3. 对每一行查找匹配的内表行（inner table）
        Cursor inner = storageEngine.open(
            plan.innerTable, 
            plan.buildInnerCondition(outerRow)
        );
        
        while (inner.next()) {
            Row innerRow = inner.getRow();
            result.add(joinRows(outerRow, innerRow));
        }
    }
    
    // 4. 排序 + LIMIT
    sort(result, plan.orderBy);
    return result.limit(plan.limit);
}
```

### 3.7 关于数据行变化对已有结果集的影响

如果已经提取了一批结果行到 `net_buffer`，此时另一事务提交了一条新数据，该新数据**不会**再返回给当前查询——这保证了 **快照读一致性（MVCC 快照）**。

## 四、MySQL 的客户端/服务器协议

```
客户端                     MySQL 服务器
  |                            |
  |--- [握手] TCP Connect ---->|
  |<-- 欢迎 + 服务器版本 ------|
  |--- 认证(账号+密码) ------->|
  |<-- OK / Error -------------|
  |--- COM_QUERY(SQL) -------->|
  |<-- 列数 + 列描述 ---------|
  |<-- 行数据 × N ------------|
  |<-- EOF / OK(影响行数) -----|
  |--- COM_QUIT -------------->|
  |                            |
```

**长连接优化：**

```sql
-- 定期重连或执行重置
mysql_reset_connection();  -- JDBC 5.1.23+

-- 配置连接池
spring.datasource.hikari.maximum-pool-size=10
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.max-lifetime=1800000  -- 30分钟
spring.datasource.hikari.connection-timeout=30000
```

## 五、实战：定位一条慢 SQL

```sql
-- 1. 开启慢查询日志
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;   -- 超过1秒记录
SET GLOBAL log_queries_not_using_indexes = ON;

-- 2. 分析慢查询日志
mysqldumpslow -s t -t 10 /var/lib/mysql/slow.log

-- 3. 用 EXPLAIN 看执行计划
EXPLAIN FORMAT=JSON SELECT ... \G

-- 4. 跟踪优化器决策
SET optimizer_trace="enabled=on";
SELECT ...;  -- 执行你的 SQL
SELECT * FROM information_schema.OPTIMIZER_TRACE \G
```

## 六、MySQL 逻辑架构总结

| 阶段 | 工作 | 耗时占比 | 优化方向 |
|------|------|---------|---------|
| 网络/连接 | TCP 握手、权限检查 | 5% | 连接池、长连接 |
| 解析 | 词法/语法分析 | 2% | 预编译 PreparedStatement |
| 优化 | 生成执行计划 | 3% | 合理索引、Analyze Table |
| **执行** | **读取数据** | **80%** | **索引优化、减少回表** |
| 排序 | ORDER BY / GROUP BY | 10% | 索引排序、覆盖索引 |

## 七、总结

理解 MySQL 的架构是深入数据库的起点。总结三个重点：

1. **架构分层**：连接层 → 服务层 → 引擎层 → 文件层，各层各司其职
2. **执行流程**：连接 → 解析 → 优化 → 执行，每一步都有优化空间
3. **优化器不完美**：必要时通过 `FORCE INDEX`、`ANALYZE TABLE`、`optimizer_trace` 干预
