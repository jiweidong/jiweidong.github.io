---
title: 【MySQL 面试】MySQL 高频面试题总结：索引、事务、锁、日志与主从复制 40 问
date: 2026-10-16 08:00:00
tags:
  - MySQL
  - 面试
  - 索引
  - 事务
  - MVCC
categories:
  - Java 面试
author: 东哥
---

# 【MySQL 面试】MySQL 高频面试题总结：索引、事务、锁、日志与主从复制 40 问

## 前言

MySQL 面试基本围绕一张 InnoDB 的图展开：**B+ 树索引 → 事务与 MVCC → 锁 → redo/undo/binlog → 主从复制与高可用**。很多人能背出"最左前缀"，却说不清"为什么会回表""为什么 RR 下也有幻读"。本文按这条主线把高频题串起来，每题都给**追问 + 加分答法 + 可验证的实验**。

## 一、索引：从 B+ 树到能落地的最优化

**Q1：为什么用 B+ 树而不是 B 树 / 哈希 / 红黑树？**

- 相比 B 树：B+ 树**非叶子节点只存 key**，同样大小的页能容纳更多 key，树更矮，磁盘 IO 更少；且叶子节点用**双向链表**串起来，天然支持范围查询。
- 相比哈希：哈希不支持范围、排序，且哈希冲突。
- 相比红黑树：红黑树是二叉的，高度大，磁盘 IO 次数多。

**Q2：聚簇索引和二级索引？回表是什么？**

InnoDB 主键索引是**聚簇索引**，叶子节点直接存整行数据；二级索引叶子存的是**主键值**。用二级索引查非索引列时需要**先拿到主键再回主键索引查**——这就是**回表**。

```sql
-- idx_name(name)，查 age 需要回表
EXPLAIN SELECT age FROM user WHERE name = 'tom';
```

**Q3：覆盖索引怎么优化？**

让查询列都在索引里，避免回表：

```sql
ALTER TABLE user ADD INDEX idx_name_age(name, age); -- 覆盖索引
SELECT name, age FROM user WHERE name = 'tom';       -- Extra: Using index
```

**Q4：最左前缀原则？**

联合索引 `(a,b,c)` 能命中 `a`、`a,b`、`a,b,c`；跳过 `a` 直接查 `b` 无法命中。但有**索引下推（ICP）**优化：MySQL 5.6+ 把 where 条件下推到存储引擎层，在索引里先过滤，减少回表。

**Q5：什么情况索引失效？**

| 场景 | 例子 |
|---|---|
| 函数/运算 | `WHERE YEAR(dt)=2026` |
| 隐式类型转换 | 字符串列传数字 `WHERE phone = 138...` |
| 前导模糊 | `LIKE '%abc'` |
| OR 连接非索引列 | `WHERE a=1 OR b=2`（b 无索引） |
| `!=` / `NOT IN`（可能） | 优化器判断全表更快 |
| 违反最左前缀 | 联合索引跳过首列 |

**加分答法**：用 `EXPLAIN` 看 `type`（至少 `range`，最好 `ref/const`）、`key`（实际用的索引）、`rows`（预估行数）、`Extra`（`Using index` 覆盖、`Using filesort` 要优化、`Using temporary` 要警惕）。

**Q6：深分页怎么优化？**

```sql
-- 慢：扫描并丢弃前 100 万行
SELECT * FROM t ORDER BY id LIMIT 1000000, 20;
-- 快：记住上次最大 id（游标法），或延迟关联
SELECT * FROM t WHERE id > 1000000 ORDER BY id LIMIT 20;
SELECT t.* FROM t JOIN (SELECT id FROM t ORDER BY id LIMIT 1000000,20) x USING(id);
```

## 二、事务与 MVCC：RR 下到底有没有幻读

**Q7：ACID 靠什么保证？**

- 原子性 A：**undo log**（回滚）
- 持久性 D：**redo log**（崩溃恢复，WAL）
- 隔离性 I：**锁 + MVCC**
- 一致性 C：以上共同保证

**Q8：四种隔离级别？**

| 级别 | 脏读 | 不可重复读 | 幻读 |
|---|---|---|---|
| 读未提交 RU | ✓ | ✓ | ✓ |
| 读已提交 RC | ✗ | ✓ | ✓ |
| 可重复读 RR（默认） | ✗ | ✗ | ✗（InnoDB 基本避免） |
| 串行化 | ✗ | ✗ | ✗ |

**Q9：MVCC 怎么实现的？**

- 隐藏列：`DB_TRX_ID`（最近修改事务）、`DB_ROLL_PTR`（回滚指针，指向 undo log）。
- **ReadView**：记录当前活跃事务 id 列表。判断某版本是否可见：若 `trx_id < min_trx_id` 可见；`> max_trx_id` 不可见；在中间则看是否在活跃列表中。
- RC 每条 SELECT 生成新 ReadView；RR **复用第一次 SELECT 的 ReadView**（这就是 RR 可重复读的根源）。

**Q10：RR 下幻读怎么解决？**

快照读靠 MVCC 避免大部分幻读；当前读（`SELECT ... FOR UPDATE`、`UPDATE`）靠 **Next-Key Lock（记录锁 + 间隙锁）** 防止其他事务在区间插入。

**追问**：RR 下还有幻读吗？**有**——当你在同一个事务里先快照读、再当前读（或是先提交了别的事务的插入后自己又 UPDATE），可能看到"多出来的行"。所以准确说法是"InnoDB 的 RR 通过 MVCC + 间隙锁**基本避免了**幻读"。

## 三、锁：行锁、间隙锁与死锁

**Q11：InnoDB 有哪些锁？**

- 按粒度：表锁、行锁。
- 行锁：**记录锁（Record）**、**间隙锁（Gap）**、**临键锁（Next-Key = Record + Gap）**。
- 按模式：共享锁 S、排他锁 X；意向锁 IS/IX（表级，快速判断表内有无行锁）。

**Q12：什么时候加间隙锁？**

在 **RR** 隔离级别下，当前读会在区间上加 Gap/Next-Key，防止其他事务插入。RC 级别下**不加间隙锁**，所以并发更高但可能幻读。

**Q13：死锁怎么排查？**

```sql
SHOW ENGINE INNODB STATUS\G   -- LATEST DETECTED DEADLOCK 段
```

**避免**：加锁顺序一致（按主键排序更新）、缩短事务、用 `SELECT ... FOR UPDATE` 一次锁定、降低隔离级别到 RC、给唯一索引字段加索引减少锁范围。

**Q14：乐观锁和悲观锁？**

悲观锁 `SELECT ... FOR UPDATE`（数据库保证）；乐观锁用版本号/CAS：

```sql
UPDATE account SET balance = balance - 100, version = version + 1
WHERE id = 1 AND version = 5;
```

## 四、日志系统：redo/undo/binlog 各司其职

**Q15：redo log 和 binlog 区别？**

| 维度 | redo log | binlog |
|---|---|---|
| 层级 | InnoDB 引擎层 | Server 层 |
| 内容 | 物理日志（页的修改） | 逻辑日志（SQL/行变更） |
| 写方式 | 循环写 | 追加写 |
| 用途 | 崩溃恢复 | 主从复制、数据恢复 |

**Q16：两阶段提交？**

更新时先写 redo log（prepare）→ 写 binlog → 提交 redo log（commit）。保证 redo 和 binlog 一致，崩溃恢复时用于判断是否补提交。这就是**组提交**与 `sync_binlog`、`innodb_flush_log_at_trx_commit` 调优的基础。

**Q17：WAL 是什么？**

Write-Ahead Logging：先写日志再刷盘。因为顺序写 redo log 比随机写数据页快得多，用日志换随机 IO，既快又能保证持久性。

## 五、主从复制与高可用

**Q18：主从复制流程？**

主库写 binlog → 从库 IO 线程拉取写入 relay log → 从库 SQL 线程重放 relay log。

**Q19：主从延迟怎么解决？**

- **并行复制**（`slave_parallel_workers` + `LOGICAL_CLOCK`/`WRITESET`）；
- 大事务拆小；
- 从库加硬件、减少索引维护；
- 读一致性要求高的走主库（**读写分离 + 强制走主库**策略）。

**Q20：怎么保证主从一致不丢数据？**

半同步复制（`rpl_semi_sync_master`）：主库等至少一个从库 ACK 才返回，牺牲一点延迟换可靠性；再配合 `MGR`（MySQL Group Replication）做强一致集群。

## 六、高频追问速查

- **char 和 varchar？** char 定长（可能浪费），varchar 变长；varchar 长度是字符数，实际存字节。
- **为什么建议用自增主键？** 顺序插入减少页分裂，聚簇索引紧凑；UUID 随机插入会造成页分裂和碎片。
- **`count(*)`、`count(1)`、`count(col)`？** `count(*)` 和 `count(1)` 基本一样（InnoDB 会选最小索引），`count(col)` 不统计 NULL。
- **慢查询怎么定位？** 开 `slow_query_log` + `long_query_time`，用 `pt-query-digest` 聚合，再 `EXPLAIN`/`EXPLAIN ANALYZE`。
- **`truncate` vs `delete`？** truncate 是 DDL、不可回滚、重置自增、不写 undo、更快。
- **一条 SQL 的执行流程？** 连接器 → 缓存（8.0 已移除）→ 分析器 → 优化器 → 执行器 → 存储引擎。

## 总结

MySQL 面试的答题骨架：**索引决定"查得快不快"，事务/MVCC 决定"读得对不对"，锁决定"并发行不行"，日志决定"丢了能不能救"**。把每一块都落到一个具体实验或案例上（比如用 `EXPLAIN` 展示回表、用 `SHOW ENGINE INNODB STATUS` 展示死锁），比背概念有力得多。

至此，"Java 后端面试三座大山"——**JVM、Spring、MySQL**——连续三篇总结完毕，建议搭配实战专题（`mysql-innodb-storage-engine`、`mysql-mvcc-lock-mechanism`）交叉复习。
