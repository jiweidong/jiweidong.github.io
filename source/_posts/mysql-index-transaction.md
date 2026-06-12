---
title: MySQL 索引与事务详解（面试跳槽篇）
date: 2026-06-13 06:31:00
updated: 2026-06-13 06:31:00
tags:
  - MySQL
  - 索引
  - 事务
  - MVCC
  - 锁
  - 性能优化
categories: 数据库
author: 东哥
toc: true
description: 从索引到事务，从 MVCC 到锁机制，从日志系统到主从架构，一文搞定 MySQL 面试核心知识点。
---

# MySQL 索引与事务详解（面试跳槽篇）

> 本文涵盖了 MySQL 面试中最高频的索引、事务、锁、日志、主从架构等核心知识点，结合大量 SQL 示例和原理图解，帮你从容应对面试。

---

## 一、索引

### 1.1 索引数据结构选型

MySQL InnoDB 选择 **B+Tree** 作为索引的底层数据结构。为什么不是其他结构？

| 数据结构 | 特点 | 为什么不选 |
|---------|------|-----------|
| **二叉查找树** | 每个节点最多两个子节点 | 极端情况下退化为链表，树高太大 |
| **红黑树** | 自平衡二叉树 | 数据量大时树高依然很高（百万数据树高约 20） |
| **B-Tree** | 多路平衡查找树，每个节点存数据 | 查询不稳定，范围查询需中序遍历 |
| **B+Tree** | 非叶子节点只存索引，叶子节点存数据且双向链表连接 | ✅ 查询稳定、范围查询高效、磁盘 I/O 少 |

**B+Tree 的核心优势：**

1. **查询稳定**：所有数据都在叶子节点，查询任何数据都走相同 I/O 次数
2. **范围查询高效**：叶子节点用双向链表连接，直接遍历即可
3. **磁盘 I/O 少**：非叶子节点只存索引（不存数据），能容纳更多 key，树高更矮
4. **排序友好**：叶子节点天然有序

### 1.2 B+Tree 的阶数与存储能力计算

InnoDB 的页大小默认为 **16KB**。

**计算过程：**

假设主键为 BIGINT（8 字节），指针大小为 6 字节（InnoDB 实现）：
- 非叶子节点每个 key+pointer 占用 14 字节
- 每个非叶子节点可存储：`16KB / 14B ≈ 1170` 个 key
- 叶子节点存储数据，假设一行记录约 1KB，每个叶子节点存 16 条记录

**三层 B+Tree 的存储能力：**
- **第一层（根节点）**：1170 个 key
- **第二层（中间节点）**：1170 × 1170 = 1,368,900 个 key
- **第三层（叶子节点）**：1,368,900 × 16 ≈ **2190 万条记录**

> 💡 只需要 3 次磁盘 I/O（3 层树高）就能从 2000 万+ 记录中定位到目标数据，这就是 B+Tree 的威力。

### 1.3 聚簇索引 vs 非聚簇索引

**聚簇索引（Clustered Index）：**
- InnoDB 会自动创建聚簇索引（主键索引）
- **叶子节点直接存储整行数据**
- 一张表**只能有一个**聚簇索引

```sql
-- InnoDB 创建聚簇索引（主键）
CREATE TABLE `user` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(50),
  `age` INT,
  PRIMARY KEY (`id`)  -- 聚簇索引
) ENGINE=InnoDB;
```

如果没有显式主键，InnoDB 会选唯一非空索引；如果也没有，则隐式生成 `DB_ROW_ID`。

**非聚簇索引（Secondary Index / 辅助索引）：**
- 叶子节点**不存数据，存主键值**
- 通过非聚簇索引查询时，需要先找到主键，再回聚簇索引查找完整数据 → **回表查询**

```sql
-- 创建非聚簇索引
CREATE INDEX idx_age ON user(age);

-- 回表查询示例
SELECT * FROM user WHERE age = 25;
-- 步骤：1. 从 idx_age 找到主键 id → 2. 回表到聚簇索引查完整行
```

### 1.4 覆盖索引（Using index）

如果查询的列都包含在索引中，**不需要回表**，这就是覆盖索引。

```sql
-- 创建联合索引
CREATE INDEX idx_name_age ON user(name, age);

-- 覆盖索引查询（不需要回表）
EXPLAIN SELECT name, age FROM user WHERE name = '张三';
-- Extra: Using index  ✅

-- 需要回表的查询
EXPLAIN SELECT * FROM user WHERE name = '张三';
-- Extra: NULL（需要回表查其他字段）
```

> ✅ **Extra 显示 `Using index`** 表示已经使用了覆盖索引，性能最佳。

### 1.5 联合索引与最左前缀原则

**联合索引是一个有序的 B+Tree，先按第一个字段排序，相同再按第二个字段排序。**

```sql
-- 创建联合索引 (a, b, c)
CREATE INDEX idx_a_b_c ON t(a, b, c);
```

**最左前缀原则：** 必须从索引的最左列开始匹配。

```sql
-- ✅ 能用到索引
WHERE a = 1
WHERE a = 1 AND b = 2
WHERE a = 1 AND b = 2 AND c = 3
WHERE a = 1 AND c = 3   -- 用到 a，但 c 只能部分
WHERE a LIKE '张%' AND b = 2  -- 前缀匹配可用

-- ❌ 不能用到索引
WHERE b = 2          -- 跳过了 a
WHERE c = 3          -- 跳过了 a、b
WHERE a = 1 AND c > 3 AND b = 2  -- b 的等值顺序不影响
```

### 1.6 索引下推（ICP - Index Condition Pushdown）

MySQL 5.6 引入的优化，**将 WHERE 条件中属于索引列的条件"下推"到存储引擎层过滤**，减少回表次数。

```sql
CREATE INDEX idx_name_age ON user(name, age);

-- 没有 ICP 的情况：
SELECT * FROM user WHERE name LIKE '张%' AND age = 25;
-- 1. 存储引擎返回 name LIKE '张%' 的所有记录到 Server 层（可能很多）
-- 2. Server 层再过滤 age = 25
-- 3. 最终回表

-- 有 ICP 的情况（Using index condition）：
-- 1. 存储引擎在索引上同时过滤 name LIKE '张%' AND age = 25
-- 2. 只返回满足条件的主键
-- 3. 大幅减少回表次数
```

**Extra 显示 `Using index condition`** 说明使用了索引下推。

### 1.7 索引失效场景大全

面试高频题！以下情况会导致索引失效：

#### 1）隐式类型转换

```sql
CREATE INDEX idx_mobile ON user(mobile);  -- mobile 是 VARCHAR

-- ❌ 索引失效：字符串字段用整数查询
SELECT * FROM user WHERE mobile = 13800138000;

-- ✅ 正确写法
SELECT * FROM user WHERE mobile = '13800138000';

-- 原理：MySQL 会将字符串转成数字进行比较，相当于 CAST(mobile AS SIGNED)，函数包裹导致索引失效
```

#### 2）OR 条件

```sql
CREATE INDEX idx_age ON user(age);

-- ❌ 索引失效：OR 两边不一定都有索引
SELECT * FROM user WHERE age = 25 OR name = '张三';

-- ✅ 优化：两边都加索引，或者用 UNION
SELECT * FROM user WHERE age = 25
UNION
SELECT * FROM user WHERE name = '张三';
```

#### 3）LIKE 以 % 开头

```sql
CREATE INDEX idx_name ON user(name);

-- ❌ 索引失效：以 % 开头
SELECT * FROM user WHERE name LIKE '%三';

-- ✅ 前缀模糊查询可用索引
SELECT * FROM user WHERE name LIKE '张%';
```

#### 4）函数包裹

```sql
CREATE INDEX idx_create_time ON order_log(create_time);

-- ❌ 索引失效：函数包裹索引列
SELECT * FROM order_log WHERE YEAR(create_time) = 2024;

-- ✅ 改写为范围查询
SELECT * FROM order_log WHERE create_time >= '2024-01-01' AND create_time < '2025-01-01';
```

#### 5）不等于（!= 或 <>）

```sql
-- ❌ 索引失效：不等于无法走索引
SELECT * FROM user WHERE age != 25;
SELECT * FROM user WHERE age <> 25;

-- ✅ 如果大部分数据满足等于条件，可拆成两条 SQL
```

#### 6）联合索引跳跃中间列

```sql
CREATE INDEX idx_a_b_c ON t(a, b, c);

-- 能走但只能部分用：a 走了，但跳过了 b，c 用不到
WHERE a = 1 AND c = 3;
```

#### 7）NOT IN 和 NOT EXISTS

```sql
-- ❌ NOT IN 通常不走索引
SELECT * FROM user WHERE id NOT IN (1, 2, 3);
-- ✅ 可以用 LEFT JOIN ... IS NULL 或 NOT EXISTS 改写
```

### 1.8 EXPLAIN 执行计划详解

```sql
EXPLAIN SELECT * FROM user WHERE age = 25\G
```

**关键字段详解：**

| 字段 | 含义 | 常见值（按性能从好到差） |
|------|------|------------------------|
| **type** | 访问类型 | `const` > `eq_ref` > `ref` > `range` > `index` > `ALL` |
| **possible_keys** | 可能用的索引 | |
| **key** | 实际用的索引 | |
| **key_len** | 索引使用的字节数 | 越长表示用得越多 |
| **rows** | 预估扫描行数 | 越小越好 |
| **Extra** | 额外信息 | `Using index` ✅ → `Using index condition` → `Using where` → `Using filesort` ❌ → `Using temporary` ❌ |

**type 详解：**

```sql
-- const：主键/唯一索引等值查询（最优）
EXPLAIN SELECT * FROM user WHERE id = 1;   -- type: const

-- ref：普通索引等值查询
EXPLAIN SELECT * FROM user WHERE age = 25;  -- type: ref

-- range：范围查询
EXPLAIN SELECT * FROM user WHERE age > 25;  -- type: range

-- index：扫描整个索引树
EXPLAIN SELECT age FROM user;  -- type: index

-- ALL：全表扫描（最差）
EXPLAIN SELECT * FROM user WHERE name = '张三';  -- type: ALL（无索引）
```

### 1.9 慢 SQL 优化流程

```
发现问题
  ↓
启用慢查询日志（slow_query_log）或性能监控
  ↓
EXPLAIN 分析执行计划
  ↓
确认索引使用情况（type/key/rows/Extra）
  ↓
优化方案：
  ① 添加合适索引（覆盖索引优先）
  ② 改写 SQL（避免索引失效）
  ③ 拆分大查询（分批查询）
  ④ 修改表结构（分表/冗余字段）
  ↓
测试验证，对比优化前后性能
```

### 1.10 创建索引的原则

1. **高频查询字段**加索引
2. **区分度高的列**优先（性别区分度低，不适合单独建索引）
3. **控制索引数量**（不是越多越好，维护索引有开销）
4. **优先使用联合索引**代替多个单列索引
5. **长字段用前缀索引**

```sql
-- 前缀索引：只对前 N 个字符建立索引
CREATE INDEX idx_email_prefix ON user(email(10));
```

6. **不要在频繁更新的列上建索引**
7. **考虑覆盖索引**减少回表

---

## 二、事务

### 2.1 ACID 四大特性

| 特性 | 全称 | 含义 |
|------|------|------|
| **A** | Atomicity（原子性） | 事务要么全部成功，要么全部失败回滚 |
| **C** | Consistency（一致性） | 事务前后数据完整性一致 |
| **I** | Isolation（隔离性） | 并发事务互不干扰 |
| **D** | Durability（持久性） | 提交后数据永久保存 |

### 2.2 事务隔离级别

SQL 标准定义了四种隔离级别：

```sql
-- 查看当前隔离级别
SELECT @@transaction_isolation;

-- 设置隔离级别
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET GLOBAL TRANSACTION ISOLATION LEVEL REPEATABLE READ;
```

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|---------|:---:|:---------:|:---:|
| **READ UNCOMMITTED** | ✅ | ✅ | ✅ |
| **READ COMMITTED（RC）** | ❌ | ✅ | ✅ |
| **REPEATABLE READ（RR）** | ❌ | ❌ | ✅（部分解决） |
| **SERIALIZABLE** | ❌ | ❌ | ❌ |

**MySQL InnoDB 默认隔离级别是 REPEATABLE READ（RR）。**

### 2.3 三种读取问题

```sql
-- 初始数据：user(id=1, name='张三', balance=100)

-- Session A                     | Session B
-- 开启事务                        | 开启事务
UPDATE user SET balance=200 WHER id=1;
                                | SELECT balance FROM user WHERE id=1;
                                | -- RU: 200（脏读！未提交的数据）
-- 回滚                           |
```

**不可重复读（两次读取同一条数据不一样）：**

```sql
-- Session A                     | Session B
BEGIN;                           | BEGIN;
SELECT balance FROM user WHERE id=1; -- 100
                                 | UPDATE user SET balance=200 WHERE id=1;
                                 | COMMIT;
SELECT balance FROM user WHERE id=1;
-- RC: 200（不可重复读！同事务两次读不一样）
-- RR: 100（MVCC 保证可重复读）
COMMIT;
```

**幻读（两次范围查询结果集不一样）：**

```sql
-- Session A                     | Session B
BEGIN;                           | BEGIN;
SELECT * FROM user WHERE age > 20; -- 3 rows
                                 | INSERT INTO user(name, age) VALUES('李四', 25);
                                 | COMMIT;
SELECT * FROM user WHERE age > 20;
-- RC: 4 rows（幻读！出现新行）
-- RR: 3 rows（MVCC 快照读看不到新行）
-- 但如果：UPDATE user SET name='xxx' WHERE age > 20;
-- 再查：4 rows（当前读触发了 next-key lock，但 RR 下也可能出现幻读）
COMMIT;
```

### 2.4 MySQL RR 级别解决了幻读吗？

**部分解决。** InnoDB 通过 MVCC + Next-Key Lock：

- **快照读（普通 SELECT）**：MVCC 保证 RR 级别无幻读
- **当前读（SELECT ... FOR UPDATE / UPDATE / DELETE）**：通过 **Next-Key Lock** 锁住记录和间隙，防止其他事务插入

```sql
-- 当前读使用 Next-Key Lock 防止幻读
BEGIN;
SELECT * FROM user WHERE age > 20 FOR UPDATE;
-- 锁住了 age > 20 的所有记录和间隙
-- 其他事务 INSERT age=25 会被阻塞
COMMIT;
```

### 2.5 MVCC 原理详解

MVCC（Multi-Version Concurrency Control，多版本并发控制）是 InnoDB 实现**一致性非锁定读**的核心机制。

#### 隐藏字段

InnoDB 的聚簇索引中每一行包含三个隐藏字段：

| 字段 | 含义 |
|------|------|
| `DB_TRX_ID` | 最近修改该行的事务 ID |
| `DB_ROLL_PTR` | 回滚指针，指向 Undo Log 中该行的前一个版本 |
| `DB_ROW_ID` | 隐式自增 ID（无主键时使用） |

#### Undo Log 版本链

```
事务 100 插入：DB_TRX_ID=100, data=(1, '张三', 100)
                   ↑
事务 200 更新：DB_TRX_ID=200, data=(1, '张三', 200)
                   ↑
事务 300 更新：DB_TRX_ID=300, data=(1, '张三', 300)
                   ↑
                最新数据（聚簇索引中）
```

每个修改产生一个新版本，通过回滚指针 `DB_ROLL_PTR` 连接成版本链。

#### ReadView 的生成

**ReadView 核心字段：**

| 字段 | 含义 |
|------|------|
| `m_ids` | 当前活跃（未提交）的事务 ID 列表 |
| `min_trx_id` | 活跃事务中的最小 ID |
| `max_trx_id` | 下一个要分配的事务 ID |
| `creator_trx_id` | 创建该 ReadView 的事务 ID |

**可见性判断规则：**

```python
if trx_id == creator_trx_id:
    return 可见（自己修改的）
if trx_id < min_trx_id:
    return 可见（已提交的旧事务）
if trx_id >= max_trx_id:
    return 不可见（事务还没开始）
if trx_id in m_ids:
    return 不可见（活跃未提交）
else:
    return 可见（已提交的旧事务）
```

**RC vs RR 的 ReadView 区别：**

```
-- RC（READ COMMITTED）
-- 每次 SELECT 都生成新的 ReadView
SELECT ① → 生成 ReadView_1
SELECT ② → 生成 ReadView_2（能看到其他事务提交的变更）
          → 导致不可重复读

-- RR（REPEATABLE READ）
-- 事务第一次 SELECT 生成 ReadView，之后复用
SELECT ① → 生成 ReadView（记录当前活跃事务）
SELECT ② → 复用同一个 ReadView（看不到其他事务的新提交）
          → 实现可重复读
```

#### MVCC + 快照读 = 一致性非锁定读

```sql
-- 典型的 MVCC 读取过程
BEGIN;
-- 第一次 SELECT 生成 ReadView（记录所有活跃事务）
SELECT * FROM user WHERE id = 1;
-- 沿着 Undo Log 版本链查找，找到第一个对当前 ReadView 可见的版本
-- 这个过程中不需要加锁！
COMMIT;
```

> **快照读**：普通 SELECT，不加锁，通过 MVCC 实现一致性读取。
> **当前读**：SELECT ... FOR UPDATE / LOCK IN SHARE MODE / UPDATE / DELETE，读取最新提交版本，需要加锁。

---

## 三、锁机制

### 3.1 锁的分类

| 锁类型 | 作用范围 | 说明 |
|--------|---------|------|
| **全局锁** | 整个数据库 | `FLUSH TABLES WITH READ LOCK`，用于全库备份 |
| **表锁** | 整张表 | `LOCK TABLES t READ/WRITE`，InnoDB 基本不用 |
| **行锁** | 单行记录 | InnoDB 默认，对索引加锁 |
| **间隙锁（Gap Lock）** | 记录之间的间隙 | 防止幻读，**RR 级别下才有** |
| **Next-Key Lock** | 记录 + 间隙 | Gap Lock + Record Lock 的组合 |

### 3.2 Record Lock / Gap Lock / Next-Key Lock

```sql
-- 假设 user 表 age 列有索引，数据：{10, 20, 30, 40}

-- Record Lock：锁住现有的记录
SELECT * FROM user WHERE age = 20 FOR UPDATE;
-- 锁住 age=20 的这条记录

-- Gap Lock：锁住间隙，防止插入
SELECT * FROM user WHERE age > 20 AND age < 30 FOR UPDATE;
-- 锁住 (20, 30) 间隙，其他事务不能插入 age=25

-- Next-Key Lock：锁住记录 + 前面间隙
SELECT * FROM user WHERE age > 20 AND age <= 30 FOR UPDATE;
-- 锁住 (20, 30] 即间隙 + 记录
```

**实际锁范围示例：**

```sql
-- 数据：[10, 20, 30, 40]，起止间隙 (-∞,10), (10,20), (20,30), (30,40), (40,+∞)

-- 1. 唯一索引等值查询（命中）
SELECT * FROM user WHERE id = 20 FOR UPDATE;
-- 锁：id=20 的 Record Lock 一个锁

-- 2. 唯一索引等值查询（未命中）
SELECT * FROM user WHERE id = 25 FOR UPDATE;
-- 锁：(20, 30) 的 Gap Lock

-- 3. 普通索引范围查询
SELECT * FROM user WHERE age >= 20 AND age < 30 FOR UPDATE;
-- 锁：age=20 Record Lock + (20,30) Gap Lock
-- 锁：(20,30) Next-Key Lock
```

### 3.3 两阶段锁协议

InnoDB 采用**两阶段锁协议（2PL）**：

1. **扩展阶段**：事务执行过程中持续获取锁
2. **收缩阶段**：事务提交或回滚时释放所有锁

```sql
BEGIN;

-- 逐行获取锁（扩展阶段）
UPDATE user SET balance=balance-100 WHERE id=1;  -- 获取 id=1 的行锁
UPDATE user SET balance=balance+100 WHERE id=2;  -- 获取 id=2 的行锁

-- COMMIT 时统一释放（收缩阶段）
COMMIT;
```

> **优化技巧**：将最可能产生锁冲突的操作放在事务最后执行，减少锁持有时间。

### 3.4 死锁检测与处理

**死锁示例：**

```sql
-- Session A                          | Session B
BEGIN;                                | BEGIN;
UPDATE user SET balance=0 WHERE id=1; | UPDATE user SET balance=0 WHERE id=2;
                                      | 
UPDATE user SET balance=0 WHERE id=2; | UPDATE user SET balance=0 WHERE id=1;
-- 等待 B 释放 id=2                   | 等待 A 释放 id=1
-- ❌ 死锁！A 等 B，B 等 A            |
```

**InnoDB 的处理：**
- **死锁检测**：通过等待图（Wait-For Graph）检测死锁
- **回滚策略**：回滚持有最少行锁的事务（代价最小）
- **死锁日志**：`SHOW ENGINE INNODB STATUS\G` 查看

```sql
-- 查看最近的死锁信息
SHOW ENGINE INNODB STATUS\G
```

**死锁预防：**
1. 保持事务**短小精悍**，尽快提交
2. **统一访问顺序**（都先 id=1 再 id=2）
3. 降低隔离级别（RR 变 RC 可减少 Gap Lock）
4. 合理创建索引（避免大范围锁）

---

## 四、日志系统

### 4.1 Redo Log（重做日志）

**作用：** 保证事务的 **持久性（Durability）** 和 **crash-safe** 能力。

**WAL（Write-Ahead Logging）机制：**
```
事务提交时：
  1. 写 Redo Log（顺序 I/O，磁盘写）
  2. 更新内存中的 Buffer Pool
  3. 返回事务提交成功（Redo Log 落盘）
  4. 后台时机将脏页刷入磁盘（随机 I/O，延迟写）
```

**特点：**
- **物理日志**：记录"在某个页做了什么修改"，而不是 SQL 语句
- **环形写入**：固定大小的文件（ib_logfile0, ib_logfile1），写满后覆盖旧日志
- **刷盘策略**：`innodb_flush_log_at_trx_commit` 控制：

| 值 | 行为 | 安全性 |
|:--:|------|:-----:|
| 1（默认） | 每次事务提交都刷盘 | 最安全 |
| 0 | 每秒刷盘 | 丢 1 秒数据 |
| 2 | 写入 OS Cache，每秒刷盘 | 丢 1 秒数据（MySQL 挂不丢，OS 挂丢） |

```sql
-- 查看 Redo Log 配置
SHOW VARIABLES LIKE 'innodb_log_file_size';  -- 默认 48MB
SHOW VARIABLES LIKE 'innodb_log_files_in_group';  -- 默认 2 个文件
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';  -- 默认 1
```

### 4.2 Binlog（二进制日志）

**作用：** 主从复制、数据恢复。**MySQL Server 层**的日志，所有存储引擎共用。

**三种格式对比：**

| 格式 | 说明 | 优点 | 缺点 |
|------|------|------|------|
| **STATEMENT** | 记录原始 SQL | 日志小 | 不安全的 SQL 会导致主从不一致 |
| **ROW（推荐）** | 记录每行变更 | 最安全，一致性好 | 日志量大 |
| **MIXED** | 自动在两者间切换 | 兼顾 | 较复杂 |

```sql
-- 查看 Binlog 格式
SHOW VARIABLES LIKE 'binlog_format';
-- 生产环境推荐 ROW 格式

-- 查看 Binlog
SHOW BINARY LOGS;
SHOW BINLOG EVENTS IN 'mysql-bin.000001';
```

### 4.3 Undo Log（回滚日志）

**作用：** 实现事务的**原子性（Atomicity）** 和 **MVCC**。

- **逻辑日志**：记录相反的操作（INSERT → DELETE，UPDATE → 前镜像）
- **版本链**：为 MVCC 提供多版本数据
- **回滚**：事务回滚时用 Undo Log 恢复到修改前状态
- **清理**：系统自动清理不再需要的 Undo Log

### 4.4 Redo Log 的两阶段提交

**为什么需要两阶段提交？** Redo Log（InnoDB 层）和 Binlog（Server 层）必须保持一致。

**两阶段提交流程：**

```
事务提交过程：
  1. 写 Redo Log（prepare 阶段）
  2. 写 Binlog
  3. 写 Redo Log（commit 阶段）
  
崩溃恢复：
  场景 A：写完 prepare，没写 binlog → 事务回滚
  场景 B：写完 binlog，没写 commit → 事务提交（一致）
```

```sql
-- Redo Log prepare 阶段
-- (Redo Log flushed, status=prepare)

-- Binlog 写入
-- (Binlog written to disk)

-- Redo Log commit 阶段
-- (Redo Log status=commit)

-- 崩溃后检查：如果 Binlog 存在就提交，否则回滚
```

> 两阶段提交保证了 Redo Log 和 Binlog 的**一致性**，是 crash-safe 的关键。

---

## 五、主从架构

### 5.1 复制类型

| 类型 | 链路图 | 说明 |
|------|--------|------|
| **异步复制** | 主 → 从（单向） | MySQL 默认，主库不等待从库确认。性能最好，但主库挂了可能有数据丢失 |
| **半同步复制** | 主 → 从 → 确认 | 主库等待至少一个从库收到 Binlog 后才提交。推荐生产使用 |
| **同步复制** | 主 → 所有从 → 确认 | 主库等待所有从库确认。一致性最好但性能最差，几乎不用 |

```sql
-- 查看半同步复制状态
SHOW VARIABLES LIKE 'rpl_semi_sync%';

-- 安装半同步插件（主库）
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
SET GLOBAL rpl_semi_sync_master_enabled = 1;

-- 安装半同步插件（从库）
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';
SET GLOBAL rpl_semi_sync_slave_enabled = 1;
```

### 5.2 主从延迟原因与解决方案

**延迟原因：**

1. **从库单线程回放**（传统复制）：主库写入速度快，从库单线程跟不上
2. **大事务**：一个大事务在主库执行 1 秒，从库可能回放 10 秒
3. **从库硬件差**：磁盘 I/O、CPU 不如主库
4. **锁冲突**：从库上其他查询与回放冲突

**解决方案：**

| 方案 | 说明 |
|------|------|
| 升级到 **MySQL 5.7+ 并行复制**（slave_parallel_workers） | 多线程回放 |
| 拆**大事务**为小事务分批提交 | 减少单次回放压力 |
| 主从硬件**同配置** | 避免性能瓶颈 |
| **读写分离**做好兜底（延迟查询走主库） | 业务层面解决一致性问题 |

```sql
-- 查看主从延迟
SHOW SLAVE STATUS\G
-- Seconds_Behind_Master：从库落后主库的秒数
-- 如果持续增长，说明有延迟问题
```

### 5.3 读写分离

```sql
-- 业务层面，将读和写分离到不同数据库

-- 写操作走主库
INSERT INTO user(name, age) VALUES('张三', 25);  -- → Master

-- 对实时性要求高的读操作走主库
SELECT * FROM user WHERE id = 1;  -- 刚写入，走 Master

-- 对实时性要求不高的读操作走从库
SELECT * FROM user WHERE age = 25;  -- 可接受延迟，走 Slave
```

**常见读写分离中间件：**
- **ProxySQL**：功能强大的 MySQL 中间件
- **MyCat**：分库分表 + 读写分离
- **ShardingSphere**：JDBC 层和 Proxy 层双方案

---

## 六、面试高频题

### 6.1 count(*) 性能差异

```sql
-- MyISAM：快速返回，有计数器
-- InnoDB：需要扫描索引（无计数器）

-- 性能对比（InnoDB）：
COUNT(*)    ≈ COUNT(1)   ≈ COUNT(id)  > COUNT(字段)
-- 原因是 COUNT(*) 和 COUNT(1) 会选最短的索引统计

-- 优化 COUNT 的常用方法：
-- 1. 用覆盖索引
-- 2. 用计数表单独维护
-- 3. Redis 缓存计数（注意一致性问题）
```

### 6.2 VARCHAR 与 CHAR 选择

| 类型 | 特点 | 适用场景 |
|------|------|---------|
| **VARCHAR** | 变长，1~2 字节额外存储长度 | 长度变化大（如 name, email） |
| **CHAR** | 定长，自动补空格 | 长度固定（如手机号、身份证号） |

```sql
-- VARCHAR(100) vs CHAR(10)

-- VARCHAR(100)：实际存储 'abc' 时占用 3+1=4 字节（长度+数据）
-- CHAR(10)：存储 'abc' 时补到 10 字节，补空格

-- 常见场景
CREATE TABLE user (
  name VARCHAR(50),        -- ✅ 名字长度变化大
  phone CHAR(11),           -- ✅ 手机号固定 11 位
  email VARCHAR(100)        -- ✅ 邮箱长度不一
);
```

### 6.3 int(11) 的含义

```sql
CREATE TABLE t (id INT(11));
```

**int(11) 中的 11 不是存储大小！**

- INT 永远占 **4 字节**，范围：`-2147483648 ~ 2147483647`
- (11) 表示**显示宽度**，搭配 `ZEROFILL` 才有效

```sql
-- INT(4) ZEROFILL：显示 0001，实际存储还是 4 字节
CREATE TABLE t2 (id INT(4) ZEROFILL);
INSERT INTO t2 VALUES(1);
SELECT * FROM t2;  -- 0001
```

**各整数类型对比：**

| 类型 | 占用 | 有符号范围 | 无符号范围 |
|------|:----:|-----------|-----------|
| TINYINT | 1B | -128 ~ 127 | 0 ~ 255 |
| SMALLINT | 2B | -32768 ~ 32767 | 0 ~ 65535 |
| INT | 4B | -21亿 ~ 21亿 | 0 ~ 42亿 |
| BIGINT | 8B | ±922亿亿 | 0 ~ 1844亿亿 |

### 6.4 分库分表策略

**垂直分表（拆分字段）：**

```sql
-- 原表：user(id, name, age, avatar_url, bio, created_at)

-- 拆成主表 + 扩展表
CREATE TABLE user_main (
  id BIGINT, name VARCHAR(50), age INT, created_at DATETIME
);

CREATE TABLE user_ext (
  id BIGINT, avatar_url VARCHAR(500), bio TEXT
);

-- 按字段访问频率拆分，高频放主表
```

**水平分表（拆分数据行）：**

```sql
-- 按 user_id 取模分表 user_0, user_1, user_2, user_3
-- 分区键：user_id % 4

-- 查询时必须带分区键
SELECT * FROM user_0 WHERE user_id = 100;  -- 100 % 4 = 0 → user_0

-- 不带分区键的查询就需要遍历所有分表
SELECT * FROM user_1 WHERE name = '张三';  -- 确定在 user_1
```

**常见分片算法：**
1. **取模/哈希**：`user_id % 分片数`
2. **范围分片**：`时间范围` 或 `ID 范围`
3. **一致性哈希**：减少扩容时的数据迁移

### 6.5 limit 深分页优化

```sql
-- ❌ 传统深分页：MySQL 会扫描 10000 行然后丢弃 9990 行
SELECT * FROM user ORDER BY id LIMIT 9990, 10;

-- ✅ 优化方案一：子查询 + 覆盖索引 + 延迟关联
SELECT * FROM user
JOIN (SELECT id FROM user ORDER BY id LIMIT 9990, 10) AS tmp
ON user.id = tmp.id;

-- ✅ 优化方案二：记录上次位置（游标分页）
SELECT * FROM user WHERE id > 9990 ORDER BY id LIMIT 10;

-- ✅ 优化方案三：范围条件 + 排序（适合时间序列场景）
SELECT * FROM user
WHERE created_at > '2024-01-01' AND created_at < '2024-01-02'
ORDER BY created_at LIMIT 10;
```

> **核心思路**：不要让数据库扫描大量无用行。利用覆盖索引减少 I/O，或用游标代替偏移量。

---

## 总结

MySQL 面试中，**索引**和**事务**是绝对的核心，两者紧密相连：

- **B+Tree** 是索引的基石 → 聚簇/非聚簇索引 → 回表/覆盖索引 → 联合索引 → 最左前缀
- **MVCC** + Undo Log 版本链 → 一致性非锁定读 → RC 和 RR 的实现区别
- **锁** + 隔离级别 → 行锁/间隙锁/Next-Key Lock → 死锁处理
- **Redo Log + Binlog 两阶段提交** → crash-safe → 主从复制
- **慢 SQL 优化** → Explain + 索引 + 改写 SQL

把这些知识点串联起来理解，面试中不仅能回答"是什么"，更能讲清楚"为什么"和"怎么用"，这就是拉开差距的关键。祝大家面试顺利！🚀
