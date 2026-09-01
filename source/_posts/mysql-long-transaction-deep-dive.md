---
title: 【MySQL 进阶】大事务与长事务深度解析：从锁持有、undo 膨胀到主从延迟的危害与治理实战
date: 2026-09-01 08:00:00
tags:
  - MySQL
  - 事务
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 进阶】大事务与长事务深度解析：从锁持有、undo 膨胀到主从延迟的危害与治理实战

## 面试官：线上 MySQL 突然主从延迟 10 分钟，你怎么排查？

很多人的第一反应是「从库机器不行」或「网络抖动」，但排查到最后，**十有八九是主库跑了一个大事务**——一次 `UPDATE` 扫了几百万行，或者一个业务事务里开了事务却迟迟不提交，把锁、undo log、binlog 全拖垮了。

本文把「大事务」和「长事务」这两个高频事故元凶拆开讲透：它们有什么危害、底层原理是什么、怎么发现、怎么治理。

## 一、先分清两个概念：大事务 vs 长事务

| 维度 | 大事务（Large Transaction） | 长事务（Long Transaction） |
|---|---|---|
| 定义 | 单次事务**处理的数据量/日志量**巨大 | 单次事务**持续时间**很长 |
| 典型表现 | 一次 DML 影响百万行、binlog 几十 GB | 事务开启后几小时不提交 |
| 主要危害 | undo 膨胀、主从延迟、锁范围大 | 锁长期占用、连接耗尽、死锁概率升高 |
| 常见来源 | 批量 UPDATE/DELETE 不带条件、批量导入 | 应用里事务内做 RPC 调用/睡眠/循环 |

两者经常同时出现：一个长事务往往也是大事务（跑了很久，写了很多行）。但治理思路略有区别。

## 二、大事务/长事务的五大危害（原理层面）

### 2.1 危害一：锁持有时间过长，阻塞其他事务

InnoDB 行锁是**在事务提交/回滚时才释放**的（不是语句执行完就释放）。一个事务 `UPDATE` 了 10 万行且不提交，这 10 万行的排他锁就一直挂着：

```sql
-- 事务 A（不提交）
BEGIN;
UPDATE orders SET status = 1 WHERE status = 0;   -- 扫了 200 万行，锁了 200 万行
-- 一直不 COMMIT，去调了个外部接口

-- 事务 B（被阻塞）
UPDATE orders SET status = 2 WHERE id = 100;     -- 等锁，直到超时
```

表现：`SHOW PROCESSLIST` 里大量 `Waiting for lock`，应用侧报 `Lock wait timeout exceeded; try restarting transaction`（默认 50 秒超时）。

### 2.2 危害二：undo log 膨胀，引发版本链过长

每次 `UPDATE`/`DELETE` 都会把旧版本写入 undo log。大事务改得越多，undo 越大：

- **undo 空间撑爆**：`ibdata1`（共享表空间）持续膨胀，除非开启了 `innodb_undo_tablespaces` 独立 undo 表空间且不回收，否则文件只增不减。
- **版本链过长 → 查询变慢**：MVCC 的 `ReadView` 需要沿着 undo 版本链回溯，**长事务存活期间**，所有旧版本都不能被 purge 线程清理。一个跑了几小时的长事务，会让「读已提交/可重复读」下的普通查询被迫遍历超长版本链，CPU 飙升。
- 这是**长事务最隐蔽的杀伤**：它自己不写数据，却让整个库的查询变慢。

### 2.3 危害三：binlog 巨大，主从延迟雪崩

主从复制是**单线程**应用 binlog（8.0 的并行复制也只能按库/按事务组并行）。大事务的 binlog 有几 GB 时：

- 主库：一次事务的 binlog 要写盘 + 传从库，期间其他事务的 binlog 排队；
- 从库：回放这个几 GB 的事务期间，**从库几乎停摆**，延迟从几秒拉到几十分钟；
- 更糟的是**从库延迟又会反过来放大问题**：从库查询读到旧数据、半同步复制卡主库提交……

```sql
-- 排查主从延迟
SHOW SLAVE STATUS\G
-- Seconds_Behind_Master: 654   ← 已经 11 分钟了
```

### 2.4 危害四：死锁概率飙升

长事务持有大量锁不释放，其他事务排队等锁，一旦形成**循环等待**就死锁：

```sql
-- 事务 A 持锁 row1，等 row2；事务 B 持锁 row2，等 row1 → Deadlock
```

死锁本身 MySQL 会自动回滚一方（`Deadlock found when trying to get lock`），但被回滚的事务如果是个大事务，回滚也要重放 undo，又是一次性能灾难。

### 2.5 危害五：连接池被占满，服务雪崩

长事务占着连接不释放。连接池默认 20~50 个连接，**20 个长事务就能把连接池打满**，后续所有请求全部 `Connection is not available, request timed out`，服务直接雪崩。

## 三、怎么发现大事务和长事务？

### 3.1 用 information_schema 查长事务

```sql
-- 找出所有运行超过 60 秒的事务
SELECT
    trx_id,
    trx_state,
    trx_started,
    TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS running_seconds,
    trx_rows_locked,          -- 锁定的行数（大事务信号）
    trx_rows_modified,        -- 修改的行数（大事务信号）
    trx_mysql_thread_id
FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60
ORDER BY running_seconds DESC;
```

再结合 `performance_schema` 找到具体 SQL：

```sql
SELECT * FROM performance_schema.events_statements_current
WHERE thread_id = (SELECT trx_mysql_thread_id FROM information_schema.innodb_trx ORDER BY trx_started LIMIT 1);
```

### 3.2 监控指标：undo 与 binlog 增速

- `SHOW ENGINE INNODB STATUS\G` 看 `History list length`（history list 越长，说明可清理的旧版本越多，purge 跟不上，背后通常有长事务）。
- 监控 `SHOW MASTER STATUS` 的 binlog 位点增长速度，判断单事务 binlog 大小。
- 用 `pt-query-digest` 分析慢日志，找 `Rows_examined` 与 `Rows_affected` 巨大的语句。

### 3.3 大事务的典型 SQL 长相

```sql
-- ① 全表/大范围更新
UPDATE orders SET discount = 0.9;                     -- 没 where，几百万行
DELETE FROM logs WHERE create_time < NOW();          -- 一次删一年数据

-- ② 循环里逐条写，但整个循环包在一个事务里
BEGIN;
for (int i = 0; i < 100000; i++) {
    jdbcTemplate.update("INSERT INTO t ...", ...);   -- 10 万条 insert 一个事务
}
COMMIT;
```

## 四、治理方案：从根上消灭大事务

### 4.1 应用层：控制事务边界（最重要）

```java
// ❌ 错误：事务里做 RPC、睡大觉
@Transactional
public void process(Order order) {
    orderService.update(order);          // 数据库操作
    Thread.sleep(2000);                  // 模拟外部调用
    rpcClient.notifyWarehouse(order);    // RPC 调用——锁被白白持有 2 秒+
}

// ✅ 正确：数据库操作最小化，外部调用移出事务
public void process(Order order) {
    orderService.update(order);          // 事务只覆盖这一步（方法内部单独开事务）
    rpcClient.notifyWarehouse(order);    // 在事务外
}
```

**铁律**：事务内只做数据库操作；RPC、HTTP、MQ、睡眠、文件 IO、循环计算全部挪到事务外。事务的「开」和「提交」之间要尽量短。

### 4.2 批量操作拆分：分页提交

```sql
-- 一次性删除 1000 万行（大事务）→ 改成循环分批
DELETE FROM orders WHERE status = 4 LIMIT 1000;   -- 每批 1000 行，循环执行
```

每批之间 sleep 一小段时间，既避免大事务，也避免主从延迟。注意：`LIMIT` 删除要配合索引，否则每批都是全表扫。

### 4.3 循环插入用批量 + 分批提交

```java
// 10 万条数据：每 500 条一批，批内 batch insert，批间提交
int batchSize = 500;
for (int i = 0; i < list.size(); i += batchSize) {
    List<Order> sub = list.subList(i, Math.min(i + batchSize, list.size()));
    jdbcTemplate.batchUpdate("INSERT INTO orders ...", sub);   // 批内一个事务
    // 每批自动提交，单事务最大 500 行
}
```

### 4.4 数据库层：设置红线参数

```sql
-- ① 事务锁等待超时：默认 50s 太久，生产通常调到 5~10s，快速失败
SET GLOBAL innodb_lock_wait_timeout = 10;

-- ② 单事务 binlog 上限（8.0 支持）：超过直接报错，拦下大事务
SET GLOBAL binlog_transaction_dependency_tracking = COMMIT_ORDER;  -- 只是并行复制配置
-- 大事务保护可以用：max_binlog_cache_size + 监控告警
```

更实用的是**监控告警**：

- 长事务 > 30s → 告警；
- `innodb_trx` 中 `trx_rows_modified > 10000` → 告警；
- `Seconds_Behind_Master > 60s` → 告警。

### 4.5 历史数据清理：分片 + 归档工具

清理历史数据不要裸写 DELETE：

- 优先**分区表 + DROP PARTITION**（参考上一篇文章）；
- 或用 `pt-archiver` 工具，它自带分批、限速、暂停功能，对主从最友好。

## 五、已经出现大事务/长事务了，怎么止血？

### 5.1 找到线程并 kill

```sql
-- 找到长事务对应的连接
SELECT trx_mysql_thread_id, trx_started FROM information_schema.innodb_trx
ORDER BY trx_started LIMIT 5;

-- 从应用层 kill（不要直接 kill 数据库线程，先让应用感知）
KILL 12345;   -- 回滚该事务（大事务回滚也要时间，但比挂着强）
```

注意：`KILL` 大事务后，**回滚过程同样耗时**（要重放 undo），期间锁依然持有。所以止血要快，但不要以为 kill 了就立刻恢复。

### 5.2 从库延迟的临时缓解

- 如果延迟来自某个大事务，等它回放完自然会追平（期间可以临时把读流量切到其他从库或主库）；
- 从库开启并行复制（`slave_parallel_workers`、`slave_parallel_type=LOGICAL_CLOCK`）——但**并行复制救不了单个大事务**，治本还是消灭大事务。

## 六、面试连环追问

**Q1：为什么长事务会让「别人」的查询变慢？**
长事务的 ReadView 会一直保留，导致它开启之后的所有旧版本 undo 都不能被 purge；其他查询在 MVCC 回溯版本链时被迫遍历更长的历史，尤其二级索引回表场景，慢查询明显增多。这也是「一个不干活的长事务拖垮全库」的原理。

**Q2：`UPDATE` 语句执行完但事务没提交，锁会释放吗？**
不会。InnoDB 的锁在事务结束时统一释放（提交或回滚）。语句执行完只是数据修改完成，锁要等 `COMMIT`/`ROLLBACK`。

**Q3：大事务导致主从延迟，为什么并行复制也救不了？**
并行复制的最小并行单元是「事务」，一个超大事务在从库必须**串行**回放（它内部的变更存在依赖），无法拆开并行。所以只要主库还在产生大事务，从库延迟就是必然的。

**Q4：`@Transactional` 注解加在 public 方法上，方法内部调自己类的另一个方法，事务会生效吗？**
不会（经典 Spring 坑）。自调用不走代理，`this.method()` 直接调用原始对象，事务注解失效——方法内所有操作变成一个隐式大事务的一部分，更容易踩长事务的坑。要用 AOP 代理注入自己（`AopContext.currentProxy()`）或拆到别的 Bean。

**Q5：如何从源头防止大事务上线？**
代码评审盯事务边界 + SQL 评审盯大范围 DML + 测试环境造数据跑 `EXPLAIN` 看影响行数 + 生产监控 `innodb_trx` 和主从延迟 + 慢日志告警。**预防成本远低于止血成本**。

## 总结

大事务和长事务是 MySQL 生产事故的「隐形炸弹」：一个不提交的长事务能拖慢全库查询，一个大事务能让主从延迟雪崩。治理的核心就一句话——**事务要短、要小、边界要清晰**：数据库操作最小化、外部调用移出事务、批量操作分批提交、监控红线兜底。面试时能把「锁持有、undo 版本链、binlog 单线程回放」这三条原理链路讲清楚，就已经赢过大部分人。
