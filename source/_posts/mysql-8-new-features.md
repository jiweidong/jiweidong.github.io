---
title: MySQL 8.0 新特性深度详解：从实战出发
date: 2026-06-19 08:00:00
tags:
  - MySQL
  - 数据库
  - 新特性
categories:
  - 数据库
author: 东哥
---

MySQL 8.0 自 2018 年正式发布以来，经历了多个小版本的迭代，已经成为企业级生产环境的主流选择。相比 MySQL 5.7，8.0 在性能、安全、SQL 功能、JSON 支持、InnoDB 存储引擎等方面都有质的飞跃。本文将从实战角度深度剖析 MySQL 8.0 的核心新特性，提供详尽的代码示例。

<!-- more -->

## 一、窗口函数（Window Functions）

窗口函数是 MySQL 8.0 最重磅的 SQL 增强之一。在 5.7 及之前版本中，实现排名、累计求和、移动平均等分析型查询往往需要借助用户变量或子查询，写法复杂且性能差。8.0 引入的窗口函数让这类查询变得简洁优雅。

### 1.1 ROW_NUMBER、RANK、DENSE_RANK

这三个函数用于行号分配和排名，是最常用的窗口函数。它们的区别在于对并列值的处理方式：

```sql
-- 准备示例数据
CREATE TABLE sales (
    id INT AUTO_INCREMENT PRIMARY KEY,
    employee VARCHAR(50),
    department VARCHAR(50),
    amount DECIMAL(10,2),
    sale_date DATE
);

INSERT INTO sales (employee, department, amount, sale_date) VALUES
('张三', '销售一部', 15000, '2026-01-15'),
('李四', '销售一部', 22000, '2026-01-15'),
('王五', '销售二部', 18000, '2026-01-15'),
('赵六', '销售二部', 22000, '2026-01-15'),
('张三', '销售一部', 16000, '2026-02-15'),
('李四', '销售一部', 20000, '2026-02-15'),
('王五', '销售二部', 21000, '2026-02-15'),
('赵六', '销售二部', 19000, '2026-02-15');
```

```sql
-- ROW_NUMBER：为每行分配唯一序号，不会出现并列
-- RANK：并列时占用后续名次（跳跃排名）
-- DENSE_RANK：并列时不占用后续名次（连续排名）
SELECT
    employee,
    department,
    amount,
    ROW_NUMBER() OVER (ORDER BY amount DESC) AS row_num,
    RANK() OVER (ORDER BY amount DESC) AS rk,
    DENSE_RANK() OVER (ORDER BY amount DESC) AS dense_rk
FROM sales;
```

| amount | ROW_NUMBER | RANK | DENSE_RANK |
|--------|-----------|------|-----------|
| 22000  | 1         | 1    | 1         |
| 22000  | 2         | 1    | 1         |
| 21000  | 3         | 3    | 2         |
| 20000  | 4         | 4    | 3         |

**实战场景**：按部门分组内排名：

```sql
SELECT
    employee,
    department,
    amount,
    ROW_NUMBER() OVER (PARTITION BY department ORDER BY amount DESC) AS dept_rank
FROM sales;
```

### 1.2 LAG 和 LEAD

LAG 访问分区中当前行之前的行，LEAD 访问之后的行。非常适合计算环比、同比。

```sql
-- 计算每个员工的上月销售额（环比）
SELECT
    employee,
    sale_date,
    amount,
    LAG(amount, 1, 0) OVER (PARTITION BY employee ORDER BY sale_date) AS prev_amount,
    amount - LAG(amount, 1, 0) OVER (PARTITION BY employee ORDER BY sale_date) AS growth
FROM sales;
```

`LAG(amount, 1, 0)` 表示向前取 1 行，若不存在则返回默认值 0。LEAD 的用法类似：

```sql
SELECT
    employee,
    sale_date,
    amount,
    LEAD(amount, 1, 0) OVER (PARTITION BY employee ORDER BY sale_date) AS next_amount
FROM sales;
```

### 1.3 NTILE

NTILE 将分区内的数据均匀分到指定数量的桶中，常用于百分位分析：

```sql
-- 将全体销售数据分到 4 个等级
SELECT
    employee,
    amount,
    NTILE(4) OVER (ORDER BY amount DESC) AS quartile
FROM sales;
```

## 二、公用表表达式（CTE）

### 2.1 非递归 CTE

CTE（Common Table Expressions）让复杂查询的层次更清晰，类似编程语言中的变量或临时视图：

```sql
-- 不使用 CTE：需要写子查询
SELECT department, total
FROM (
    SELECT department, SUM(amount) AS total
    FROM sales
    GROUP BY department
) dept_total
WHERE total > 30000;

-- 使用 CTE：可读性大幅提升
WITH dept_total AS (
    SELECT department, SUM(amount) AS total
    FROM sales
    GROUP BY department
)
SELECT department, total
FROM dept_total
WHERE total > 30000;
```

### 2.2 递归 CTE

递归 CTE 是处理树形结构数据的利器，如组织架构、分类层级、斐波那契数列等：

```sql
-- 示例：组织架构树（员工上级关系）
CREATE TABLE employees (
    id INT PRIMARY KEY,
    name VARCHAR(50),
    manager_id INT
);

INSERT INTO employees VALUES
(1, 'CEO', NULL),
(2, 'CTO', 1),
(3, 'CFO', 1),
(4, '技术总监', 2),
(5, '高级开发', 4),
(6, '初级开发', 5),
(7, '财务主管', 3);

-- 递归 CTE：查询 CTO 下属的所有层级
WITH RECURSIVE org_tree AS (
    -- 锚点成员
    SELECT id, name, manager_id, 1 AS level
    FROM employees
    WHERE id = 2

    UNION ALL

    -- 递归成员
    SELECT e.id, e.name, e.manager_id, t.level + 1
    FROM employees e
    INNER JOIN org_tree t ON e.manager_id = t.id
)
SELECT * FROM org_tree;
```

**递归 CTE 的注意事项**：

| 要点 | 说明 |
|------|------|
| 必须包含 UNION ALL | 锚点成员和递归成员通过 UNION ALL 连接 |
| 递归成员必须引用 CTE 自身 | 否则不是递归 CTE |
| 必须有终止条件 | 可以是 WHERE、LIMIT 或自然结束（无更多行匹配） |
| 默认递归深度限制 | `cte_max_recursion_depth` 控制，默认 1000 |

## 三、索引增强：隐式索引与降序索引

### 3.1 隐式索引（Invisible Indexes）

MySQL 8.0 允许将索引设为"不可见"，优化器不会使用它，但索引数据会继续维护。这在索引删除前评估影响时非常有用：

```sql
-- 创建不可见索引
CREATE INDEX idx_amount ON sales(amount) INVISIBLE;

-- 查看索引状态
SHOW INDEX FROM sales;
-- 或者使用信息模式
SELECT INDEX_NAME, VISIBLE FROM information_schema.STATISTICS
WHERE TABLE_NAME = 'sales';

-- 切换可见性
ALTER TABLE sales ALTER INDEX idx_amount VISIBLE;
ALTER TABLE sales ALTER INDEX idx_amount INVISIBLE;
```

**实战场景**：在删除一个旧索引前，先设为 INVISIBLE，运行一段时间确认无性能回退后再 DROP。

### 3.2 降序索引（Descending Indexes）

在 MySQL 5.7 中，虽然可以指定 `ORDER BY DESC` 创建索引，但实际上索引条目仍然是升序存储的。8.0 真正支持了降序索引，对混合排序查询（部分列升序、部分列降序）性能提升显著：

```sql
-- 创建降序索引
-- date 升序、amount 降序的复合索引
CREATE INDEX idx_date_amount ON sales(sale_date ASC, amount DESC);

-- 下面的查询可以利用降序索引避免 filesort
SELECT employee, sale_date, amount
FROM sales
WHERE sale_date >= '2026-01-01'
ORDER BY sale_date ASC, amount DESC;
```

**性能对比**：

| 排序类型 | MySQL 5.7 | MySQL 8.0 |
|---------|-----------|-----------|
| ORDER BY col1 ASC, col2 ASC | 使用正向扫描 | 使用正向扫描 |
| ORDER BY col1 ASC, col2 DESC | 需要 filesort | 扫描降序索引 |
| 多列混合排序场景 | 全表扫描 + filesort | 索引扫描（无需排序） |

## 四、JSON 增强

MySQL 8.0 对 JSON 的支持有了质的飞跃，新增了 JSON_TABLE 函数和多值索引，让 JSON 数据像关系表一样灵活查询。

### 4.1 JSON_TABLE 函数

JSON_TABLE 将 JSON 数组展开为关系表，可直接 JOIN：

```sql
-- 示例：存储用户标签数据
CREATE TABLE users (
    id INT PRIMARY KEY,
    name VARCHAR(50),
    tags JSON
);

INSERT INTO users VALUES
(1, '张三', '[{"tag":"VIP","level":3},{"tag":"新用户","level":1}]'),
(2, '李四', '[{"tag":"VIP","level":2},{"tag":"黑名单","level":0}]');

-- JSON_TABLE 展开为关系表
SELECT
    u.id,
    u.name,
    jt.tag,
    jt.level
FROM users u,
JSON_TABLE(u.tags,
    '$[*]' COLUMNS (
        tag VARCHAR(50) PATH '$.tag',
        level INT PATH '$.level'
    )
) AS jt
WHERE jt.level >= 2;
```

### 4.2 多值索引（Multi-Value Index）

传统索引无法索引 JSON 数组中的元素。MySQL 8.0 的多值索引通过在数组上创建索引，大幅加速相关查询：

```sql
-- 创建多值索引
CREATE INDEX idx_tags_level ON users(
    (CAST(JSON_EXTRACT(tags, '$[*].level') AS UNSIGNED ARRAY))
);

-- 查询可以使用多值索引
SELECT * FROM users
WHERE JSON_OVERLAPS(tags, '{"level":3}');
-- 或使用 MEMBER OF
SELECT * FROM users
WHERE 3 MEMBER OF (tags->'$[*].level');
```

## 五、通用表空间（General Tablespaces）

InnoDB 支持创建通用的表空间文件，允许多张表共享同一个 .ibd 文件，方便管理：

```sql
-- 创建通用表空间
CREATE TABLESPACE `ts_project1`
ADD DATAFILE 'ts_project1.ibd'
ENGINE=INNODB;

-- 将表放入通用表空间
CREATE TABLE project1_logs (
    id INT PRIMARY KEY,
    message TEXT,
    created_at DATETIME
) TABLESPACE `ts_project1`;

-- 查看表空间使用情况
SELECT FILE_NAME, TABLESPACE_NAME, ENGINE
FROM information_schema.FILES
WHERE TABLESPACE_NAME = 'ts_project1';
```

**表空间类型对比**：

| 表空间类型 | 特点 | 适用场景 |
|-----------|------|---------|
| 系统表空间 | MySQL 默认，单文件 | 简单测试环境 |
| 独立表空间 | 每表一个 .ibd 文件 | 生产环境默认 |
| 通用表空间 | 多表共享同一 .ibd | 归档、分组存储 |
| 临时表空间 | 用于临时表 | 排序、临时结果 |

## 六、原子 DDL（Atomic DDL）

MySQL 8.0 的 DDL 操作是原子的——要么全部成功，要么全部回滚。这解决了 5.7 中 DDL 中途失败导致数据字典不一致的痛点：

```sql
-- 原子 DDL 效果示例：两条 ALTER 命令封装在一条语句中
-- 如果第二条失败，第一条也会回滚
ALTER TABLE sales
    ADD COLUMN region VARCHAR(20),
    DROP COLUMN non_existent_column;  -- 如果这里失败，region 也不会被添加

-- 查看 DDL 日志（数据字典）
SELECT * FROM mysql.innodb_ddl_log;
```

**原子 DDL 的实现机制**：

1. DDL 开始时在 `mysql.innodb_ddl_log` 中写入日志记录
2. 逐阶段执行 DDL 操作
3. 若成功则清除日志
4. 若失败则根据日志回滚
5. 崩溃恢复时也会读取未完成的 DDL 日志进行回滚

## 七、自增 ID 持久化（Redo Log 支持）

在 MySQL 5.7 及之前版本中，自增计数器保存在内存中，服务器重启后使用 `SELECT MAX(id)` 恢复。这可能导致已回滚事务的 ID 被重用，或主从切换后 ID 冲突。8.0 将自增计数器写入 redo log：

```sql
-- 自增计数器状态查看
SHOW CREATE TABLE sales;
-- 输出中可以看到 AUTO_INCREMENT 值

-- 重启后，计数器从持久化的值恢复
-- 而不是像 5.7 那样从 MAX(id) + 1 恢复
```

**重启后的行为对比**：

| 版本 | 重启后自增ID恢复策略 | 潜在问题 |
|-----|-------------------|---------|
| MySQL 5.7 | SELECT MAX(id)+1 | 已回滚事务的ID可能被重用 |
| MySQL 8.0 | 从 redo log 持久化恢复 | 即使有回滚事务，ID也不会被重用 |

## 八、安全增强

### 8.1 caching_sha2_password（默认认证插件）

MySQL 8.0 的默认认证插件从 `mysql_native_password` 变更为 `caching_sha2_password`，提供更安全的 SHA-256 哈希加密，并引入了缓存机制减少握手时的计算开销：

```sql
-- 查看当前认证插件
SHOW VARIABLES LIKE 'default_authentication_plugin';

-- 创建用户时指定认证插件
CREATE USER 'dev_user'@'%'
IDENTIFIED WITH caching_sha2_password BY 'strong_password';

-- 如果需要兼容旧客户端，可以显式使用 mysql_native_password
CREATE USER 'legacy_user'@'%'
IDENTIFIED WITH mysql_native_password BY 'password';
```

### 8.2 角色管理（Role-Based Access Control）

MySQL 8.0 引入了角色的概念，可以创建角色、授予权限，再将角色分配给用户，极大简化了权限管理：

```sql
-- 创建角色
CREATE ROLE 'read_only', 'read_write', 'db_admin';

-- 为角色授权
GRANT SELECT ON mydb.* TO 'read_only';
GRANT SELECT, INSERT, UPDATE, DELETE ON mydb.* TO 'read_write';
GRANT ALL PRIVILEGES ON mydb.* TO 'db_admin' WITH GRANT OPTION;

-- 将角色分配给用户
CREATE USER 'analyst'@'%' IDENTIFIED BY 'password';
CREATE USER 'developer'@'%' IDENTIFIED BY 'password';
CREATE USER 'dba'@'%' IDENTIFIED BY 'password';

GRANT 'read_only' TO 'analyst'@'%';
GRANT 'read_write' TO 'developer'@'%';
GRANT 'db_admin' TO 'dba'@'%';

-- 设置默认角色（用户登录时自动激活）
SET DEFAULT ROLE 'read_only' TO 'analyst'@'%';

-- 动态激活角色
SET ROLE 'read_write';
SET ROLE ALL;  -- 激活所有已授权角色
SET ROLE NONE; -- 停用所有角色

-- 查看当前用户的角色
SELECT CURRENT_ROLE();
```

## 九、并行查询（Parallel Execution）

MySQL 8.0.14 引入了 InnoDB 并行查询特性，主要指 `innodb_parallel_read_threads` 参数控制索引扫描时使用的并行线程数：

```sql
-- 查看并行度配置
SHOW VARIABLES LIKE 'innodb_parallel_read_threads';

-- 设置并行读线程数（动态生效）
SET GLOBAL innodb_parallel_read_threads = 4;

-- 验证并行查询效果（EXPLAIN 会显示是否使用了并行读）
EXPLAIN FORMAT=TREE
SELECT COUNT(*) FROM sales;
```

**适用场景与限制**：

| 场景 | 是否支持并行 | 说明 |
|-----|------------|------|
| 全表/全索引扫描 | ✅ | 并行度受参数控制 |
| WHERE 过滤 | ✅ | 仅限聚簇索引扫描 |
| JOIN | ❌ | 尚不支持 |
| GROUP BY | ❌ | 尚不支持 |
| ORDER BY | ❌ | 排序仍需串行 |

## 十、直方图（Histograms）

MySQL 8.0 引入了直方图统计信息，帮助优化器在数据分布不均匀时做出更好的执行计划选择：

```sql
-- 为表的某列创建直方图
ANALYZE TABLE sales UPDATE HISTOGRAM ON amount WITH 100 BUCKETS;

-- 查看直方图信息
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    HISTOGRAM -> '$.buckets' AS buckets,
    HISTOGRAM -> '$.sampling-rate' AS sampling_rate
FROM information_schema.COLUMN_STATISTICS
WHERE TABLE_NAME = 'sales';

-- 删除直方图
ANALYZE TABLE sales DROP HISTOGRAM ON amount;
```

**直方图对优化器的影响**：

```sql
-- 创建测试数据（数据分布不均匀）
CREATE TABLE uneven_data (
    id INT PRIMARY KEY,
    category VARCHAR(10),
    value INT
);

-- 插入数据：A 占 90%，B 和 C 各占 5%
INSERT INTO uneven_data
SELECT seq, CASE WHEN seq <= 900 THEN 'A' WHEN seq <= 950 THEN 'B' ELSE 'C' END, seq
FROM seq_1_to_1000;

-- 没有直方图时，优化器认为三种分类各占约 1/3
-- 有直方图后，优化器知道 A 占绝大多数

EXPLAIN SELECT * FROM uneven_data WHERE category = 'C';
```

## 十一、资源组管理（Resource Groups）

MySQL 8.0 允许将线程映射到可管理的资源组，限制 CPU 使用和资源消耗：

```sql
-- 创建资源组，绑定到指定 CPU
CREATE RESOURCE GROUP report_group
TYPE = USER
VCPU = 0-1  -- 绑定到 CPU 0 和 CPU 1
THREAD_PRIORITY = 5;

-- 修改资源组
ALTER RESOURCE GROUP report_group
VCPU = 0-3
THREAD_PRIORITY = 10;

-- 查询时使用指定的资源组
SELECT /*+ RESOURCE_GROUP(report_group) */
    department, SUM(amount) AS total
FROM sales
GROUP BY department;

-- 查看资源组状态
SELECT * FROM information_schema.RESOURCE_GROUPS;
```

**资源组管理的实用价值**：

- 将昂贵的分析查询隔离到特定 CPU 核心，避免干扰 OLTP 业务
- 为批处理任务分配较低优先级，确保实时交易优先
- 可以动态调整资源组配置，无需重启 MySQL

## 总结

MySQL 8.0 的上述新特性涵盖了 SQL 功能、性能优化、存储引擎、安全管理和可管理性等各个方面。下表总结了各特性的适用版本和推荐场景：

| 特性 | 最小版本 | 推荐场景 |
|-----|---------|---------|
| 窗口函数 | 8.0.0 | 排名、移动平均、累计计算 |
| CTE / 递归 CTE | 8.0.0 | 树形查询、分层数据、递归遍历 |
| 隐式索引 | 8.0.0 | 安全删除索引前验证 |
| 降序索引 | 8.0.0 | 混合排序查询优化 |
| JSON_TABLE | 8.0.4 | JSON 数据关系化查询 |
| 多值索引 | 8.0.17 | JSON 数组条件的索引加速 |
| 通用表空间 | 8.0.0 | 文件分组管理 |
| 原子 DDL | 8.0.0 | 保证 DDL 数据一致性 |
| 自增 ID 持久化 | 8.0.0 | 主从切换场景下避免 ID 冲突 |
| caching_sha2_password | 8.0.0 | 更安全的身份认证 |
| 角色管理 | 8.0.0 | 企业级权限分层管理 |
| 并行查询 | 8.0.14 | 大表全扫描分析 |
| 直方图 | 8.0.0 | 数据分布不均时的查询优化 |
| 资源组管理 | 8.0.0 | CPU 隔离、混合负载管理 |

如果你还在使用 MySQL 5.7，强烈建议规划升级到 8.0。不仅仅是新功能，8.0 在性能基准测试中对比 5.7 也有 20%~50% 的综合提升。下一篇文章我们将介绍 MySQL 8.0 的高可用架构与性能调优实践，敬请期待。
