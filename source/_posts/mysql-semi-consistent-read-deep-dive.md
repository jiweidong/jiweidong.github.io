---
title: 【MySQL 底层】半一致性读（Semi-Consistent Read）深度解析：UPDATE 锁膨胀、加锁优化与死锁规避
date: 2026-10-03 08:00:01
tags:
  - MySQL
  - InnoDB
  - 锁机制
  - 面试
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 底层】半一致性读（Semi-Consistent Read）深度解析：UPDATE 锁膨胀、加锁优化与死锁规避

## 面试官：一个 UPDATE 语句没走索引，为什么把整张表都锁住了？

这个问题的标准答案往往停在"因为没索引，所以要全表扫描，扫描到的行都要加锁"。但如果你继续追问：

- **为什么在 READ COMMITTED 下，同样没走索引的 UPDATE，锁住的却少了很多？**
- 不匹配 WHERE 条件的行，为什么有时候也加锁，有时候不加？
- 这个机制叫什么？它有什么代价？

能答出"**半一致性读（Semi-Consistent Read）**"的人，就进入了 InnoDB 加锁机制的深水区。这篇文章把它讲透。

---

## 一、先复习：InnoDB 的加锁基本盘

在分析之前，先把两条基准事实钉死：

| 隔离级别 | 普通 SELECT | UPDATE/DELETE 的 WHERE 匹配 |
| --- | --- | --- |
| READ UNCOMMITTED | 不加锁 | 加锁 |
| READ COMMITTED | 快照读（语句级） | 加锁，**逐行**判断并释放不匹配行的锁 |
| REPEATABLE READ | 快照读（事务级） | 加锁，**扫描过的行都保持锁定** |
| SERIALIZABLE | 加锁读 | 加锁 |

关键差异在第三行：**RR 下，扫描路径上遇到的每一行都会加锁，即使 WHERE 条件不匹配；RC 下，不匹配的行可以在加锁后立刻释放。**

这个"立刻释放"的行为，就来自半一致性读。

---

## 二、什么是半一致性读

半一致性读的核心思想一句话概括：

> **在 UPDATE/DELETE 扫描过程中，如果读到的行已经被别的事务加了锁（当前版本不可读），InnoDB 就退回到读取该行最近一次提交的版本；用这个旧版本先判断 WHERE 条件，如果不匹配，就直接跳过并释放锁，根本不去等锁。**

"一致性读"（consistent read）指的是 MVCC 快照读——读的是历史版本；"半"（semi）指的是它**只用于判断 WHERE 匹配与否**，一旦判断匹配，还是会去加锁读最新版本。所以它既不是纯快照读，也不是纯当前读，是两者的混合体。

### 触发条件

半一致性读**只在 READ COMMITTED 隔离级别下默认启用**。

历史背景：

- MySQL 5.6/5.7 时代，还有一个参数 `innodb_locks_unsafe_for_binlog`（默认 OFF），打开后会在 RR 下也启用半一致性读。
- MySQL 8.0 已**彻底移除**该参数；现在想用半一致性读，只能把隔离级别设成 `READ COMMITTED`。

```sql
-- 查看当前隔离级别
SELECT @@transaction_isolation;
-- 会话级切换
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

---

## 三、源码视角：半一致性读发生在哪里

InnoDB 读取单行记录的核心函数是 `row_search_mvcc()`（位于 `row/row0sel.cc`）。简化后的逻辑分支：

```
row_search_mvcc():
  1. 通过 B+ 树定位记录
  2. 尝试对记录加锁（lock_clust_rec_read_check_and_lock）
  3. 如果加锁失败（记录已被其他事务锁定）：
       if (semi-consistent read 模式) {
           // 不回滚，不等待，改为读取该行"最后一次提交的版本"
           // 即通过 undo log 构造一个历史版本
           返回 DB_RECORD_NOT_FOUND 或旧版本记录
       } else {
           进入锁等待队列
       }
  4. 上层 handler（MySQL Server 层）拿到旧版本后
     重新评估 WHERE 条件：
       - 命中  -> 重新走一次加锁读（这一次会老老实实等锁）
       - 不命中 -> 释放该行上的锁，继续扫描下一行
```

这里有个非常重要的细节：**WHERE 条件的判断是分两层的**。

- 能被索引直接判定的条件（如索引列等值查询），在存储引擎层处理；
- 不能被索引判定的条件，必须回表后由 Server 层判断。

半一致性读的价值，恰恰在于**把 Server 层的条件判断"提前"到不等锁的状态下完成**，从而让大量不匹配的行"过而不锁"。

---

## 四、一个具体例子：锁膨胀是怎么被压下去的

建表：

```sql
CREATE TABLE account (
  id        BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id   BIGINT NOT NULL,
  balance   DECIMAL(12,2) NOT NULL,
  status    TINYINT NOT NULL DEFAULT 1,
  KEY idx_user (user_id)
) ENGINE=InnoDB;
```

假设表里有 100 万行，`status = 0` 的行只有 10 行，且 `status` 上没有索引。

执行：

```sql
UPDATE account SET balance = balance - 1 WHERE status = 0;
```

### 在 REPEATABLE READ 下

1. 没有 `status` 索引 → 走全表扫描（或主键聚簇索引扫描）。
2. 扫到的每一行**都要加 X 锁**（因为 Server 层还没判断 `status` 是否等于 0）。
3. 不匹配的行，锁**不释放**，保持到事务结束。
4. 结果：**表里几乎所有行都被锁住**，其他事务的 UPDATE 全部排队。

这就是所谓的"**UPDATE 锁膨胀**"——一个原本只该锁 10 行的语句，锁了 100 万行。

### 在 READ COMMITTED 下

1. 全表扫描，遇到每一行先尝试加锁。
2. 如果该行没被别人锁 → 正常加锁，Server 层判断 `status`，不匹配则**立即释放**锁。
3. 如果该行已被别人锁 → 触发半一致性读，读取最近提交版本，判断 `status`：
   - 不匹配 → **释放锁，跳过，继续下一行**（完全不用等锁！）
   - 匹配 → 回到加锁读，进入等待队列。
4. 结果：只有那 10 行真正匹配的记录会被持续锁定。

对比：

| 维度 | RR + 无索引 UPDATE | RC + 无索引 UPDATE |
| --- | --- | --- |
| 不匹配行是否加锁 | 加锁，且保持 | 加锁后立即释放 |
| 锁等待概率 | 极高（整表） | 低（只锁匹配行） |
| 死锁概率 | 高 | 明显降低 |
| 幻读风险 | 有 Next-Key Lock 保护 | 需要额外处理 |

---

## 五、代价：为什么默认还是 RR？

看到这里你可能想立刻把线上切成 RC。先别急，半一致性读有它的代价：

**1）只对"不匹配"的行生效**

如果 WHERE 条件本身匹配率高（比如 `WHERE status IN (0,1)` 命中 90%），半一致性读几乎帮不上忙，锁范围照样很大。

**2）必须回表判断，CPU 消耗上升**

用旧版本判断条件意味着每行都要构造一次历史版本，高并发下 undo 读取和行评估的开销不可忽略。

**3）RC 下幻读语义变化**

RR 靠 Gap Lock / Next-Key Lock 防幻读；RC 基本不加间隙锁，同一事务内两次执行同一条范围查询，中间可能"多出"新行，业务逻辑必须能容忍。

**4）binlog 格式的依赖**

早期 `innodb_locks_unsafe_for_binlog` 之所以"unsafe"，就是因为它改变了加锁行为，在 STATEMENT 格式下可能导致主从不一致。**现在必须是 ROW 格式**才能安全使用 RC 的这套优化（MySQL 5.7+ 默认就是 ROW，风险已小很多）。

---

## 六、如何观测：确认锁到底加在了哪里

MySQL 8.0 的 `performance_schema` 提供了可观测手段：

```sql
-- 1. 当前活跃事务
SELECT trx_id, trx_state, trx_started, trx_rows_locked, trx_rows_modified, trx_query
FROM information_schema.INNODB_TRX;

-- 2. 每张表上等锁的事务（谁在等锁）
SELECT * FROM performance_schema.data_lock_waits;

-- 3. 当前持有的行锁明细
SELECT ENGINE_TRANSACTION_ID, OBJECT_NAME, INDEX_NAME,
       LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks
ORDER BY ENGINE_TRANSACTION_ID;

-- 4. 引擎状态里的锁等待概要
SHOW ENGINE INNODB STATUS\G   -- 看 "LATEST DETECTED DEADLOCK" 段落
```

**关键观察点**：在 RC 下跑同一个 UPDATE，`data_locks` 里的行数应该显著少于 RR；如果没差别，说明匹配率太高，或者有别的锁源（比如外键、唯一键冲突检查）。

---

## 七、一个真实死锁案例

线上两张表，事务 A 先改 `order` 再改 `order_item`，事务 B 先改 `order_item` 再改 `order`——这是**加锁顺序不一致**的经典死锁，半一致性读也救不了。

```
事务 A: UPDATE order ... ;  UPDATE order_item ...
事务 B: UPDATE order_item ... ;  UPDATE order ...
```

而半一致性读能救的是另一类：

```
-- 事务 A
BEGIN;
UPDATE account SET balance = balance - 1 WHERE status = 0;  -- 全表扫，锁很多行

-- 事务 B（并发）
BEGIN;
UPDATE account SET status = 0 WHERE id = 999;               -- 想锁第 999 行
```

RR 下：A 已经把 999 行的锁拿走了，B 只能等；A 又想更新 B 已经持有的行 → 死锁。
RC 下：A 扫描到 999 行时 `status != 0`（旧版本），直接跳过释放锁；B 不必等 → **死锁消失**。

---

## 八、与索引条件下推（ICP）的区别

这两个概念经常被混淆，务必分清：

| 维度 | 索引条件下推（ICP） | 半一致性读 |
| --- | --- | --- |
| 解决的问题 | 减少回表次数 | 减少锁范围与锁等待 |
| 生效位置 | 存储引擎层（索引遍历时过滤） | 存储引擎层（锁冲突时读旧版本） |
| 依赖 | 联合索引 | READ COMMITTED |
| 作用对象 | 所有读取路径 | UPDATE/DELETE（含加锁读） |
| 是否改变锁行为 | 否 | 是，核心目的就是改变锁行为 |

一句话：**ICP 是"少回表"，半一致性读是"少加锁"**。

---

## 八·补：一次可复现的验证实验

理论讲完，我们用一个最小实验亲手验证半一致性读的效果。

```sql
-- 准备数据：10 万行，status=0 的只有 3 行
CREATE TABLE t_demo (
  id     INT PRIMARY KEY AUTO_INCREMENT,
  biz_id INT NOT NULL,
  status TINYINT NOT NULL,
  v      INT NOT NULL,
  KEY idx_biz (biz_id)          -- 注意：status 上没有索引
) ENGINE=InnoDB;

INSERT INTO t_demo (biz_id, status, v)
SELECT n, IF(n IN (50000, 99999, 12345), 0, 1), 0
FROM (
  SELECT @row := @row + 1 AS n
  FROM information_schema.columns a, information_schema.columns b,
       (SELECT @row := 0) r LIMIT 100000
) x;
```

**实验 A：RR 隔离级别**

```sql
-- 会话 1
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
UPDATE t_demo SET v = v + 1 WHERE status = 0;
-- 先不提交

-- 会话 2（另开连接）
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
UPDATE t_demo SET v = v + 1 WHERE id = 1;   -- 期望：被阻塞

-- 观察会话 1 持有的行锁数量
SELECT COUNT(*) FROM performance_schema.data_locks WHERE OBJECT_NAME = 't_demo';
-- 结果：锁数量接近 10 万（几乎全表）
```

**实验 B：RC 隔离级别**（重复上述步骤，只改隔离级别）

```sql
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN;
UPDATE t_demo SET v = v + 1 WHERE status = 0;

SELECT COUNT(*) FROM performance_schema.data_locks WHERE OBJECT_NAME = 't_demo';
-- 结果：只剩个位数～几十个锁（仅匹配行 + 少量临时锁）
```

**结论**：同样的 SQL、同样的数据、同样的执行计划，**仅隔离级别不同，锁数量差了 4 个数量级**。这就是半一致性读的威力——它不改变扫描行数，只改变"不匹配行要不要一直持有锁"。

> 小提示：如果 `data_locks` 连接不上，请确认 `performance_schema = ON`（MySQL 8.0 默认开启），并且当前用户有 `PROCESS` 权限。

---

## 九、最佳实践清单

1. **给 WHERE 条件加索引**——这是根治手段，任何锁优化都不如让 SQL 走索引。上面那个例子，加 `KEY idx_status (status)` 后，锁范围直接收敛到 10 行。
2. **缩短事务**——锁的持有时间与事务时长正相关，把远程调用、文件 IO 挪出事务。
3. **RC 是可选优化**——大多数互联网业务（尤其是靠 ROW binlog 的主从架构）切 RC 是安全的，但要评估幻读语义变化。
4. **统一加锁顺序**——按主键/固定字段排序后再批量更新，避免循环死锁。
5. **监控 `data_locks` 与 `INNODB_TRX`**——把"锁等待时长""行锁数量"做成告警指标。
6. **慎用无索引的 UPDATE/DELETE**——这是锁膨胀的头号来源，DDL 评审时直接拦下来。

---

## 十、面试常见追问

**Q1：半一致性读是"读旧版本"，那不是脏读吗？**
不是。它读的是**已提交的历史版本**（MVCC 可见版本），只是不保证是最新版本。而且它仅用于**判断 WHERE 是否命中**，命中后仍会加锁读最新版，所以不会基于旧值做修改。

**Q2：RR 下能手动开启半一致性读吗？**
MySQL 8.0 没有开关。`innodb_locks_unsafe_for_binlog` 已被移除，唯一途径是切到 READ COMMITTED。

**Q3：半一致性读会不会导致主从不一致？**
在 ROW 格式 binlog 下不会，因为 binlog 记录的是行的最终变更结果而非 SQL。但在 STATEMENT 格式下有风险，这也是历史上该特性被标为 "unsafe" 的原因。

**Q4：`SELECT ... FOR UPDATE` 会走半一致性读吗？**
不会。它是显式的当前读 + 加锁读，锁冲突时直接等待，不走半一致性读的"读旧版本"捷径。

**Q5：为什么 RC 下还要加间隙锁以外的锁？**
RC 不加间隙锁（除唯一键/外键等特殊场景），但**记录锁（Record Lock）仍然要加**，否则无法保证并发更新的正确性。半一致性读优化的是"不匹配行的锁"，不是"匹配行的锁"。

---

## 十一、总结

- **半一致性读**：UPDATE/DELETE 扫描时遇到已锁定行，改为读取最近提交版本判断 WHERE；不匹配则释放锁跳过，匹配则重新加锁读。
- **触发条件**：READ COMMITTED（8.0 起唯一途径）。
- **收益**：大幅缩小锁范围、降低锁等待与死锁概率，是无索引 UPDATE 的"急救包"。
- **代价**：回表/undo 读取开销、RC 的幻读语义变化、依赖 ROW binlog。
- **根治**：加索引 + 缩短事务 + 统一加锁顺序。

记住一句话：**半一致性读是"少加锁"，不是"不加锁"；它是优化，不是正确性的替代品。**
