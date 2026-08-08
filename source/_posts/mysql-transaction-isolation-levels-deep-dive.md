---
title: 【MySQL 实战】事务隔离级别深度解析：脏读、不可重复读、幻读与 MVCC 快照读
date: 2026-08-08 08:00:00
tags:
  - MySQL
  - 事务
  - 隔离级别
  - MVCC
  - 面试
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 实战】事务隔离级别深度解析：脏读、不可重复读、幻读与 MVCC 快照读

## 面试官：MySQL 默认隔离级别是什么？为什么它能解决幻读？

"MySQL 默认是 RR（可重复读）"——这句话几乎人人会背，但接下来的追问能刷掉 80% 的人：

- 脏读、不可重复读、幻读到底怎么演示？
- READ COMMITTED 和 REPEATABLE READ 在 MVCC 下有什么区别？
- MySQL 的 RR 为什么能解决幻读，而教科书说 RR 不能？
- 什么时候应该把隔离级别改成 RC？

本文用 SQL 实验 + 原理分析，一次讲透。

<!-- more -->

## 一、三大并发问题：先建立直觉

假设有一张表：`user(id, name, balance)`，初始数据 `id=1, balance=100`。

### 1.1 脏读（Dirty Read）：读到未提交的数据

```
事务 A：UPDATE user SET balance=200 WHERE id=1;   -- 未提交
事务 B：SELECT balance FROM user WHERE id=1;      -- 读到 200 ❌
事务 A：ROLLBACK;                                 -- 200 其实是脏数据
```

**本质**：B 读到了 A **还没提交**的修改。违反隔离性。

### 1.2 不可重复读（Non-Repeatable Read）：同一条记录前后不一致

```
事务 A：SELECT balance FROM user WHERE id=1;      -- 100
事务 B：UPDATE user SET balance=300 WHERE id=1; COMMIT;
事务 A：SELECT balance FROM user WHERE id=1;      -- 300 ❌ 前后不一致
```

**本质**：同一事务内两次读**同一条记录**，结果不同。B 已提交，所以这不是脏读，而是"可重复读"被破坏。

### 1.3 幻读（Phantom Read）：结果集"凭空多出/少掉"行

```
事务 A：SELECT * FROM user WHERE balance > 50;    -- 1 行
事务 B：INSERT INTO user VALUES(2, 'x', 100); COMMIT;
事务 A：SELECT * FROM user WHERE balance > 50;    -- 2 行 ❌ 多了一行"幻影"
```

**本质**：同一事务内两次**范围查询**返回的行数不同。区别不可重复读：**不可重复读是"同一条记录的值变了"，幻读是"记录条数变了"**。

| 问题 | 针对对象 | 表现 |
| --- | --- | --- |
| 脏读 | 未提交数据 | 读到别人回滚前的假数据 |
| 不可重复读 | 已提交记录 | 同一条记录两次读值不同 |
| 幻读 | 已提交记录（集合） | 同一个范围两次读行数不同 |

## 二、四大隔离级别

SQL 标准定义了四个级别，按隔离强度从弱到强：

| 隔离级别 | 脏读 | 不可重复读 | 幻读 | 实现方式 |
| --- | --- | --- | --- | --- |
| READ UNCOMMITTED（读未提交） | 可能 | 可能 | 可能 | 不加锁，直接读最新版本 |
| READ COMMITTED（读已提交） | 不会 | 可能 | 可能 | MVCC：每次 SELECT 生成新 ReadView |
| REPEATABLE READ（可重复读） | 不会 | 不会 | **不会（InnoDB）** | MVCC：事务内 ReadView 复用 + 间隙锁 |
| SERIALIZABLE（串行化） | 不会 | 不会 | 不会 | 全部加锁（含读锁），或 MVCC+锁 |

**注意**：SQL 标准说 RR 仍可能幻读，但 **InnoDB 的 RR 通过 MVCC + 间隙锁彻底解决了幻读**，这也是它敢把 RR 设为默认的原因。

## 三、MVCC 与 ReadView：隔离级别的底层实现

### 3.1 版本链回顾

InnoDB 每行数据有隐藏列：
- `DB_TRX_ID`：最近一次修改该行的事务 ID；
- `DB_ROLL_PTR`：回滚指针，指向 undo log 中的旧版本。

一行数据在 undo log 中形成**版本链**：

```
balance=300 (trx_id=103) ← balance=200 (trx_id=102) ← balance=100 (trx_id=101)
```

### 3.2 ReadView：事务的"时间快照"

**ReadView** 是 MVCC 的核心，包含四个关键字段：

| 字段 | 含义 |
| --- | --- |
| `m_ids` | 生成 ReadView 时**活跃（未提交）**的事务 ID 列表 |
| `min_trx_id` | 活跃事务中最小的 ID |
| `max_trx_id` | 下一个将要分配的事务 ID（已分配的最大 ID + 1） |
| `creator_trx_id` | 创建 ReadView 的事务自己的 ID |

**可见性判断规则**：读某行版本时，取该版本的 `trx_id`：

```
trx_id < min_trx_id         → 已提交，可见 ✅
trx_id >= max_trx_id        → 未来事务，不可见 ❌
min_trx_id <= trx_id < max  → 若在 m_ids 中（活跃）→ 不可见 ❌；否则可见 ✅
```

不可见时，沿 `DB_ROLL_PTR` 继续找上一个版本，直到可见或到达版本链头部。

### 3.3 RC vs RR：唯一区别就在 ReadView 的生成时机

| 隔离级别 | ReadView 生成时机 | 效果 |
| --- | --- | --- |
| **READ COMMITTED** | **每次 SELECT 都生成新的 ReadView** | 能看到其他事务已提交的最新修改 → 不可重复读 |
| **REPEATABLE READ** | **事务内第一次 SELECT 生成，之后复用** | 整个事务读的是同一快照 → 可重复读 |

```sql
-- 实验验证（两个会话）
-- 会话A：SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
-- 会话B：SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
-- 两会话同时 BEGIN 后：
-- 1. A 查 balance → 100；B 查 balance → 100
-- 2. 另起事务把 balance 改成 300 并 COMMIT
-- 3. A 再查 → 100（RR，快照复用）；B 再查 → 300（RC，新快照）
```

这就是两个级别最本质的差别——**一个"快照用到底"，一个"每次读都换新快照"**。

## 四、幻读的两种解法：快照读与当前读

MySQL 的读分两种：

### 4.1 快照读（普通 SELECT）→ 靠 MVCC

```sql
SELECT * FROM user WHERE balance > 50;  -- 普通 SELECT = 快照读
```

RR 下快照读复用同一个 ReadView，即使别的事务插入了新行，版本链上对当前事务"可见的新版本"不存在（新行 trx_id 在 m_ids 中或大于 max），所以**读不到幻影行**。

### 4.2 当前读（加锁的读）→ 靠间隙锁

```sql
SELECT * FROM user WHERE balance > 50 FOR UPDATE;  -- 当前读
UPDATE user SET ...;  DELETE FROM ...;             -- 也是当前读
```

当前读必须读到**最新已提交**的数据并加锁，此时 MVCC 失效，靠 **Record Lock（记录锁）+ Gap Lock（间隙锁）+ Next-Key Lock（临键锁）** 防止幻读：

- **Record Lock**：锁住索引记录本身；
- **Gap Lock**：锁住记录之间的**间隙**，禁止其他事务在该间隙插入；
- **Next-Key Lock**：记录锁 + 前间隙锁的组合，**左开右闭**区间。

```
索引值:  10    20    30    40
间隙:  (-∞,10) (10,20) (20,30) (30,40) (40,+∞)
```

`WHERE balance > 50 FOR UPDATE` 会锁住 (50, +∞) 的所有记录和间隙，其他事务往这个范围 INSERT 会被阻塞，从而**防止当前读场景下的幻读**。

> **面试追问：什么情况下 RR 下还会出现"幻觉"？** 混用快照读与当前读时。例如先快照读得到 1 行，再执行当前读（FOR UPDATE），两者结果可能不一致——因为当前读读到的是最新数据。这不算幻读（定义上是两个快照读不一致才算），但业务上要留意。

## 五、实战演示：用 SQL 复现三大问题

```sql
-- 准备
CREATE TABLE user (
  id INT PRIMARY KEY,
  name VARCHAR(20),
  balance INT
);
INSERT INTO user VALUES (1, 'a', 100);

-- ===== 演示脏读（READ UNCOMMITTED）=====
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
BEGIN;
-- 会话B：UPDATE user SET balance=200 WHERE id=1;（不提交）
SELECT balance FROM user WHERE id=1;  -- 会话A读到 200（脏数据）
-- 会话B：ROLLBACK;

-- ===== 演示不可重复读（READ COMMITTED）=====
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN;
SELECT balance FROM user WHERE id=1;  -- 100
-- 会话B：UPDATE ... SET balance=300; COMMIT;
SELECT balance FROM user WHERE id=1;  -- 300（两次不一致）
COMMIT;

-- ===== 演示幻读被 RR 阻止 =====
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
SELECT COUNT(*) FROM user WHERE balance > 50;  -- 1
-- 会话B：INSERT INTO user VALUES(2,'b',100); COMMIT;
SELECT COUNT(*) FROM user WHERE balance > 50;  -- 仍为 1（快照读）
-- 若此时执行：SELECT * FROM user WHERE balance>50 FOR UPDATE;
-- 则会被间隙锁保护，或读到最新（当前读语义）
COMMIT;
```

## 六、生产环境怎么选隔离级别？

### 6.1 大厂的默认选择

- **阿里 MySQL 规范**：推荐使用 **READ COMMITTED**；
- **MySQL 官方默认**：REPEATABLE READ（历史兼容原因，binlog 从 STATEMENT 格式时代继承下来）。

### 6.2 为什么很多场景推荐 RC？

| 维度 | RC 的优势 |
| --- | --- |
| 锁竞争 | 只有记录锁，**没有间隙锁**，插入并发更高 |
| 死锁概率 | 间隙锁少了，死锁场景大幅减少 |
| 主从复制 | ROW 格式下 RC 完全够用，无幻读风险场景可接受 |
| 语义直观 | 读到的都是已提交数据，符合业务直觉 |

**什么时候必须用 RR？** 业务强依赖"事务内多次查询结果一致"（如统计报表快照、对账），或存在"先查询后按结果插入"且不能加锁的业务（靠快照读防幻读）时，RR 是刚需。

> **面试追问：RC 也有 ReadView，为什么不能防幻读？** 因为 RC 每次 SELECT 都新建 ReadView，其他事务提交的新行在新 ReadView 中变为可见，所以范围查询结果会变——幻读自然挡不住。防幻读的本质是"快照固定"，只有 RR 的复用机制能做到。

### 6.3 查询与设置

```sql
-- 查看全局/会话隔离级别
SELECT @@global.transaction_isolation, @@session.transaction_isolation;
-- 设置
SET GLOBAL transaction_isolation = 'READ-COMMITTED';
SET SESSION transaction_isolation = 'READ-COMMITTED';
```

## 七、总结：一张表记住全部

| 问题 | 脏读 | 不可重复读 | 幻读 |
| --- | --- | --- | --- |
| 针对 | 未提交数据 | 已提交的同一条记录 | 已提交的记录集合 |
| RU | 可能 | 可能 | 可能 |
| RC | 不会 | 可能 | 可能 |
| RR（InnoDB） | 不会 | 不会 | 不会（MVCC + 间隙锁） |
| SERIALIZABLE | 不会 | 不会 | 不会 |

**核心记忆点**：

1. **隔离级别 = 对"读"的约束强度**，InnoDB 用 MVCC + 锁实现；
2. **MVCC 快照读**：RC 每次读换新快照（会不可重复读），RR 快照复用（可重复读）；
3. **当前读**：靠 Record Lock / Gap Lock / Next-Key Lock 防幻读；
4. **默认 RR 且能防幻读，是 InnoDB 与标准 SQL 最大的不同**；
5. **生产选型**：高并发写入场景倾向 RC（无间隙锁），强一致性快照场景用 RR。

最后送上一句面试金句："MySQL 的 RR 之所以能解决幻读，是因为它用 MVCC 管住了快照读、用间隙锁管住了当前读，两条路都堵死了。"
