---
title: MySQL MVCC 与 InnoDB 锁机制深度解析
date: 2026-06-16 09:30:00
tags:
  - MySQL
  - MVCC
  - 锁
  - 事务隔离
  - 死锁
categories:
  - 数据库
author: 东哥
---

# MySQL MVCC 与 InnoDB 锁机制深度解析

## 一、并发控制的基本问题

数据库并发操作时，会遇到三大问题：

| 问题 | 说明 | 影响 |
|------|------|------|
| 脏读 | 读到其他事务未提交的数据 | 读到最终可能不存在的"假数据" |
| 不可重复读 | 同一事务内两次读同一行，结果不同 | 数据不一致 |
| 幻读 | 同一事务内两次查询，行数不同 | 数据量不一致 |

### 事务隔离级别

```sql
-- 查看当前隔离级别
SELECT @@transaction_isolation;
-- MySQL 8.0: REPEATABLE-READ（默认）

-- 设置隔离级别
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET GLOBAL TRANSACTION ISOLATION LEVEL REPEATABLE READ;
```

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|----------|------|-----------|------|
| READ UNCOMMITTED | ✅ 可能 | ✅ 可能 | ✅ 可能 |
| **READ COMMITTED** | ❌ | ✅ 可能 | ✅ 可能 |
| **REPEATABLE READ** | ❌ | ❌ | ✅ 可能（InnoDB 通过 Gap Lock 解决） |
| SERIALIZABLE | ❌ | ❌ | ❌ |

> 注意：MySQL 的 **REPEATABLE READ** 因为间隙锁（Gap Lock）的支持，实际上能解决大多数幻读问题。

## 二、MVCC 原理（多版本并发控制）

MVCC 是 **InnoDB 实现高并发读的核心机制**，读不加锁，写不阻塞读。

### 2.1 核心组件

MVCC 依赖三个关键组件：

```
1. 隐藏字段（每行记录自动添加）
   ┌──────────────┬──────────────┬────────────────┐
   │ DB_TRX_ID    │ DB_ROLL_PTR  │ DB_ROW_ID      │
   ├──────────────┼──────────────┼────────────────┤
   │ 操作该行的   │ 指向 Undo    │ 隐藏自增主键   │
   │ 事务 ID      │ Log 回滚段   │（无主键时使用）│
   └──────────────┴──────────────┴────────────────┘

2. Undo Log（回滚日志）
   记录行的旧版本，形成版本链

3. Read View（读视图）
   判断当前事务能看到哪个版本
```

### 2.2 Undo Log 版本链

```
事务 100 插入:  name='张三', age=25
  DB_TRX_ID=100, DB_ROLL_PTR=NULL
              ↓
事务 200 更新:  name='张三', age=30
  当前记录:     DB_TRX_ID=200, DB_ROLL_PTR → 旧版本
              ↓
  Undo Log:   (name='张三', age=25, DB_TRX_ID=100, DB_ROLL_PTR=NULL)
              ↓
事务 300 更新:  name='李四', age=30
  当前记录:     DB_TRX_ID=300, DB_ROLL_PTR → 旧版本
              ↓
  Undo Log:   (name='张三', age=30, DB_TRX_ID=200) → (name='张三', age=25, DB_TRX_ID=100)
```

### 2.3 Read View（读视图）

Read View 的核心判断逻辑：

```java
class ReadView {
    long[] m_ids;           // 当前活跃的事务 ID 列表
    long m_low_limit_id;    // 最大事务 ID + 1
    long m_up_limit_id;     // 活跃事务最小 ID
    long m_creator_trx_id;  // 创建 Read View 的事务 ID

    boolean isVisible(long trxId) {
        if (trxId < m_up_limit_id) {
            // 事务比所有活跃事务都早 → 可见
            return true;
        }
        if (trxId >= m_low_limit_id) {
            // 事务在 Read View 之后创建 → 不可见
            return false;
        }
        if (m_ids.contains(trxId)) {
            // 事务在 Read View 创建时还活跃 → 不可见
            return false;
        }
        // 事务已提交 → 可见
        return true;
    }
}
```

### 2.4 RC vs RR 的 Read View 创建时机

```sql
-- READ COMMITTED: 每次 SELECT 创建新的 Read View
-- REPEATABLE READ: 事务的第一次 SELECT 创建 Read View，后续复用

-- 事务 A
START TRANSACTION;
SELECT * FROM user WHERE id = 1;  -- RC & RR 同时创建 Read View
                                   -- 假设：m_ids = [100]（事务 B 活跃中）

-- 事务 B
UPDATE user SET name = '新的名字' WHERE id = 1;
COMMIT;                          -- B 提交

-- 事务 A 再次查询
SELECT * FROM user WHERE id = 1;
-- RC 模式：重新创建 Read View，发现 B 已提交 → 读到新数据
-- RR 模式：复用第一次的 Read View，m_ids=[100] 仍然认为 B 活跃 → 读旧数据
```

### 2.5 一致性非锁定读（Consistent Nonlocking Read）

这是 InnoDB 默认的读取方式：

```sql
-- 普通的 SELECT 不加任何锁
SELECT * FROM user WHERE id = 1;
-- ↑ 这就是快照读（SnapShot Read）
-- 利用 MVCC 读取历史版本，完全不阻塞写操作
```

## 三、InnoDB 锁机制

### 3.1 锁的分类

```
InnoDB 锁
 ├── 行级锁 (Record Lock)
 │    ├── 共享锁 (S Lock) — 读锁
 │    └── 排他锁 (X Lock) — 写锁
 ├── 间隙锁 (Gap Lock)       — 锁定范围，防止幻读
 ├── 临键锁 (Next-Key Lock)  — 行锁 + 间隙锁的组合
 ├── 意向锁 (Intention Lock)
 │    ├── 意向共享锁 (IS)
 │    └── 意向排他锁 (IX)
 └── 表级锁 (Table Lock)
      ├── 自增锁 (AUTO-INC Lock)
      └── 元数据锁 (MDL)
```

### 3.2 行锁兼容矩阵

```
         X         S         IX        IS
X       ❌       ❌       ❌       ❌
S       ❌       ✅       ❌       ✅
IX      ❌       ❌       ✅       ✅
IS      ❌       ✅       ✅       ✅
```

### 3.3 行锁的加锁方式

```sql
-- 共享锁（S Lock）
SELECT * FROM user WHERE id = 1 LOCK IN SHARE MODE;
-- MySQL 8.0 语法
SELECT * FROM user WHERE id = 1 FOR SHARE;

-- 排他锁（X Lock）
SELECT * FROM user WHERE id = 1 FOR UPDATE;

-- UPDATE / DELETE / INSERT 自动加 X 锁
UPDATE user SET name = 'new' WHERE id = 1;
DELETE FROM user WHERE id = 1;
INSERT INTO user VALUES (1, 'new');
```

### 3.4 间隙锁（Gap Lock）

间隙锁锁住的是**记录之间的间隙**，而不是记录本身：

```
+------+-----------+
|  id  |   name    |
+------+-----------+
|  1   |  Alice    |
|          ← 间隙锁 (1, 5)
|  5   |  Bob      |
|          ← 间隙锁 (5, 10)
|  10  |  Charlie  |
|          ← 间隙锁 (10, +∞)
+------+-----------+
```

```sql
-- 间隙锁生效场景
-- 事务 A
START TRANSACTION;
SELECT * FROM user WHERE id BETWEEN 3 AND 7 FOR UPDATE;
-- 锁定范围：(1, 5] + (5, 10] → (1, 10)，防止插入 id=2,3,4,5,6,7,8,9

-- 事务 B（阻塞等待）
INSERT INTO user(id, name) VALUES (6, 'New'); -- ❌ 被 Gap Lock 阻塞
```

### 3.5 临键锁（Next-Key Lock）

Next-Key Lock = Record Lock + Gap Lock，它是 InnoDB RR 级别下**默认的行锁算法**：

```sql
-- 锁定记录及前面的间隙
SELECT * FROM user WHERE id >= 3 AND id <= 7 FOR UPDATE;
-- 实际加锁范围：(1, 5] + (5, 10] = (1, 10)
```

加锁规则（简化版，参考 MySQL 官方的加锁规则）：

```
规则 1：等值查询时，唯一索引命中 → Record Lock
规则 2：等值查询时，唯一索引未命中 → Gap Lock
规则 3：范围查询时 → Next-Key Lock
规则 4：普通索引 → Next-Key Lock（间隙锁一直向右延伸）
```

### 3.6 插入意向锁（Insert Intention Lock）

这是一种特殊的 Gap Lock。多个事务插入同一个间隙的不同位置时，**互不阻塞**：

```sql
-- 事务 A
INSERT INTO user(id, name) VALUES (3, 'C');
-- 在 (1, 5) 间隙上加插入意向锁

-- 事务 B
INSERT INTO user(id, name) VALUES (4, 'D');
-- 也在 (1, 5) 间隙上加插入意向锁
-- ✅ 不冲突，因为插在不同的位置
```

### 3.7 自增锁（AUTO-INC Lock）

```sql
-- 查看自增锁模式
SHOW VARIABLES LIKE 'innodb_autoinc_lock_mode';
-- 0: 传统模式（表级锁，INSERT 完后才释放）
-- 1: 连续模式（预分配批量值，默认）
-- 2: 交错模式（最高并发，binlog 需 row 模式）
```

## 四、死锁分析

### 4.1 经典死锁案例

```sql
-- 事务 A
START TRANSACTION;
UPDATE user SET name = 'A1' WHERE id = 1;  -- 锁 id=1
UPDATE user SET name = 'A2' WHERE id = 2;  -- 等待事务 B 释放 id=2

-- 事务 B（在另一个连接）
START TRANSACTION;
UPDATE user SET name = 'B2' WHERE id = 2;  -- 锁 id=2
UPDATE user SET name = 'B1' WHERE id = 1;  -- 等待事务 A 释放 id=1

-- 死锁发生！MySQL 自动回滚其中一个事务
```

### 4.2 查看死锁信息

```sql
-- 查看最近一次死锁
SHOW ENGINE INNODB STATUS \G

-- 关键信息：
------------------------
LATEST DETECTED DEADLOCK
------------------------
*** (1) TRANSACTION:
TRANSACTION 12345, ACTIVE 10 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 2 lock struct(s)
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 2 page no 4 n bits 72 index PRIMARY of table `test`.`user`
*** (2) TRANSACTION:
TRANSACTION 12346, ACTIVE 5 sec
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 2 page no 4 n bits 72 index PRIMARY of table `test`.`user`
*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 2 page no 4 n bits 72 index PRIMARY of table `test`.`user`
```

### 4.3 死锁预防策略

```sql
-- 策略 1：按相同顺序访问资源
-- ❌ 事务 A: UPDATE user WHERE id=1 → UPDATE user WHERE id=2
-- ❌ 事务 B: UPDATE user WHERE id=2 → UPDATE user WHERE id=1
-- ✅ 都按 id 从小到大顺序

-- 策略 2：减少锁范围，尽量走索引
EXPLAIN UPDATE user SET name='X' WHERE age > 18;
-- 如果 age 没有索引 → 行锁升级为表锁！

-- 策略 3：使用 READ COMMITTED 隔离级别
SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;
-- RC 模式下没有 Gap Lock，死锁概率大幅降低

-- 策略 4：设置死锁超时
SHOW VARIABLES LIKE 'innodb_lock_wait_timeout';  -- 默认 50s
SET innodb_lock_wait_timeout = 5;  -- 快速回滚
```

## 五、实战排查锁问题

```sql
-- 1. 查看当前锁等待
SELECT * FROM performance_schema.data_lock_waits \G

-- 2. 查看事务信息
SELECT * FROM information_schema.INNODB_TRX \G

-- 3. 查看锁信息
SELECT * FROM performance_schema.data_locks \G

-- 4. 查看进程列表
SHOW PROCESSLIST;

-- 5. 强制杀掉阻塞事务
KILL 1234;  -- 1234 是阻塞事务的线程 ID
```

**实战排查 SQL：**

```sql
-- 查找谁锁了谁
SELECT
    waiting_trx_id,
    waiting_thread,
    waiting_query,
    blocking_trx_id,
    blocking_thread,
    blocking_query
FROM sys.innodb_lock_waits;

-- 如果 sys 库不可用
SELECT
    r.trx_id AS waiting_trx_id,
    r.trx_mysql_thread_id AS waiting_thread,
    r.trx_query AS waiting_query,
    b.trx_id AS blocking_trx_id,
    b.trx_mysql_thread_id AS blocking_thread,
    b.trx_query AS blocking_query
FROM information_schema.innodb_lock_waits w
JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id;
```

## 六、MVCC 与锁的关系总结

| 场景 | 使用机制 | 是否阻塞 |
|------|---------|---------|
| 普通 SELECT（快照读） | MVCC Read View | ❌ 不阻塞，不加锁 |
| SELECT ... FOR UPDATE | 行锁（Next-Key Lock） | ✅ 阻塞 |
| SELECT ... FOR SHARE | 共享锁 | ✅ 阻塞写 |
| UPDATE / DELETE | 先快照读找到行，再加 X 锁 | ✅ 阻塞 |
| INSERT | 隐式锁（Implicit Lock） | ✅ 阻塞 |

## 七、常见面试问答

### Q1: RR 级别怎么解决幻读？

```text
MySQL RR + InnoDB 通过 Next-Key Lock 解决幻读：

例：SELECT * FROM user WHERE age > 20 FOR UPDATE;
加锁范围：(20, max] 的所有间隙和记录
即使其他事务 INSERT 一条 age=25 的数据，也会被 Gap Lock 阻塞
```

### Q2: 如果事务 A 更新了一行但未提交，事务 B 能读到吗？

```text
不能。MVCC 通过 Undo Log 版本链保证：
- 事务 B 的 Read View 看不到未提交事务的修改
- 如果隔离级别是 RC，事务 B 的后续查询会读到（B 提交后）
- 如果隔离级别是 RR，事务 B 整个期间都读不到
```

### Q3: UPDATE 语句没有走索引会怎样？

```text
如果没有索引：
1. InnoDB 需要对全表加 Next-Key Lock
2. 由于是全表扫描，实际上锁住了整个表
3. 其他事务的 INSERT/UPDATE/DELETE 全部被阻塞

解决方法：确保 WHERE 条件有合适的索引
```
