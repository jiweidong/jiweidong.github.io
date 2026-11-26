---
title: 【PostgreSQL 深挖】MVCC、VACUUM 与表膨胀治理：从 xmin/xmax 到事务 ID 回卷
date: 2026-11-26 08:00:00
tags:
  - PostgreSQL
  - MVCC
  - VACUUM
  - 数据库
  - Java
categories:
  - 数据库
author: 东哥
---

# 【PostgreSQL 深挖】MVCC、VACUUM 与表膨胀治理

## 前言

MySQL 背景的工程师第一次接手 PostgreSQL，最容易产生一种错觉：SQL 差不多、事务差不多、索引也差不多，应该很快就能上手。

然后线上就会出现这些现象：

- 一张只有 200 万行的表，物理大小 40GB，`SELECT count(*)` 越来越慢；
- 磁盘监控天天告警，`DELETE` 了 80% 的数据，空间一点没释放；
- 某天凌晨数据库突然只能读不能写，日志里出现 `database is not accepting commands to avoid wraparound data loss`；
- `pg_stat_activity` 里一堆 `idle in transaction`，autovacuum 明明在跑，死元组却越积越多。

这些问题的根都在同一个地方：**PostgreSQL 的 MVCC 是「原地写新版本」，旧版本必须靠 VACUUM 回收**。而 MySQL InnoDB 的 MVCC 是「undo 回滚段 + 原地更新」，旧版本由 purge 线程在后台清理。两套机制的运维心智完全不同。

本文从元组结构讲到 autovacuum 调参和事务 ID 回卷，最后落到 Java 应用侧最容易犯的三个错。这是一篇偏运维与底层的文章，但每一节都和「Java 服务为什么把数据库拖死」有关。

---

## 一、两种 MVCC：undo 派与 heap 派的根本差异

先看一张对比表，这是理解后面所有问题的地基。

| 维度 | InnoDB（MySQL） | PostgreSQL |
|---|---|---|
| 更新方式 | 原地更新聚簇索引记录，旧版本写入 undo log | 在堆表写入一条全新元组，旧元组留在原地 |
| 版本存放 | undo 表空间 | 表文件（heap）本身 |
| 读旧版本 | 沿 undo 链回溯 | 沿 `t_ctid` 链找新版本，用快照判断可见性 |
| 回收者 | purge 线程 | vacuum / autovacuum 进程 |
| 回收时机 | 持续后台回收 | 周期性、按阈值触发 |
| 主键索引 | 聚簇索引，二级索引存主键 | 所有索引都存 TID（块号+行号） |
| 典型问题 | undo 膨胀、长事务拖累 purge | 表/索引膨胀、事务 ID 回卷 |

InnoDB 的 `DELETE` 是标记删除，空间留在表里但可复用；PostgreSQL 的 `DELETE` 是给旧元组打上 `xmax`，空间同样留在表里，但**只有 vacuum 才能把它标记为可复用**。

注意这里的差别：InnoDB 的空间复用由后续插入自然完成；PostgreSQL 虽然也能复用，但前提是 vacuum 已经把死元组清理成 free space，而且新元组要能塞进同一个页（page）。这直接引出了后面要讲的 `fillfactor` 和 HOT update。

---

## 二、一条 UPDATE 在 PG 里到底发生了什么

假设有这样一张表：

```sql
CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    user_id     bigint NOT NULL,
    status      text NOT NULL,
    amount      numeric(12,2) NOT NULL,
    updated_at  timestamptz NOT NULL
);
```

执行：

```sql
UPDATE orders SET status = 'PAID', updated_at = now() WHERE id = 1001;
```

PostgreSQL 内部大致做这些事：

1. 通过主键索引找到 TID，例如 `(block 42, offset 7)`；
2. 读取该元组，检查 `xmin` 对当前快照是否可见；
3. 在堆里找空间写入一条新元组，`xmin` 设为当前事务 ID，`xmax` 为 0；
4. 把旧元组的 `xmax` 设为当前事务 ID，`t_ctid` 指向新元组的 TID；
5. 如果更新涉及索引列，为每个索引插入新条目；否则可能走 HOT；
6. 提交后，旧元组变成「死元组」，等待 vacuum。

关键字段：

| 字段 | 含义 |
|---|---|
| `xmin` | 创建该元组的事务 ID |
| `xmax` | 删除/更新该元组的事务 ID，0 表示未删除 |
| `t_ctid` | 指向自身或更新后的新元组，构成版本链 |
| `t_infomask` | 提示位，记录提交/回滚/冻结等状态 |

### 2.1 HOT update：为什么它很重要

如果 UPDATE 没有修改任何被索引的列，并且**当前页还有足够空间**，PostgreSQL 会走 HOT（Heap-Only Tuple）更新：

- 新元组写在同一页；
- 不新增索引条目；
- 索引仍然指向旧的 line pointer，由 line pointer 链到新元组。

HOT 能显著减少索引膨胀和 vacuum 工作量。它的前提是「页里有空间」，所以对更新频繁的表，建表时把 `fillfactor` 调到 80~90 是常见做法：

```sql
CREATE TABLE orders (...) WITH (fillfactor = 85);
```

`fillfactor=100` 意味着页写满，任何更新都只能去新页，HOT 基本失效，索引膨胀会明显加快。

### 2.2 死元组不是「立刻可复用」

即使一条元组已经死亡，只要还有任何快照可能看到它，它就不能被清理。判断标准是：

> 死元组的 `xmax` 小于所有活跃快照中最老的 `xmin`（即 xmin horizon）。

这就是长事务的杀伤力：一个开了 2 小时的事务，会让这两小时内产生的所有死元组都无法回收。MySQL 里长事务拖累的是 purge 和 undo；PostgreSQL 里长事务拖累的是**整张表的空间复用**。

---

## 三、膨胀：怎么判断一张表「虚胖」

### 3.1 先看统计视图

```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / greatest(n_live_tup + n_dead_tup, 1), 2) AS dead_pct,
    last_autovacuum,
    last_vacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

`n_dead_tup` 是估算值，来自统计收集器，不是精确值，但足以判断趋势。

### 3.2 再看真实物理大小

```sql
SELECT
    pg_size_pretty(pg_total_relation_size('orders')) AS total,
    pg_size_pretty(pg_relation_size('orders'))       AS heap,
    pg_size_pretty(pg_indexes_size('orders'))        AS indexes;
```

如果 `heap` 远大于「行数 × 平均行宽」，基本可以判定膨胀。

### 3.3 精确膨胀率：pgstattuple

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT * FROM pgstattuple('orders');
```

关注三个字段：

- `dead_tuple_percent`：死元组占比；
- `free_percent`：页内空闲空间占比；
- `approx_tuple_count`：近似行数。

经验阈值：`dead_tuple_percent > 20%` 且表大于几个 GB，就值得安排一次回收；`free_percent` 很高但 `dead_tuple_percent` 不高，说明是「曾经删过大量数据」，需要 `VACUUM FULL` 或 `pg_repack` 才能真正把空间还给操作系统。

---

## 四、VACUUM 到底做了什么

很多人以为 vacuum 就是「删死元组」，其实它分几件事：

1. **清理死元组**：把 dead tuple 的 line pointer 标记为 unused；
2. **清理索引**：删除指向死元组的索引条目，并合并重复的 line pointer；
3. **更新 visibility map**：把「整页都是活元组」的页标记为 all-visible，供 index-only scan 使用；
4. **冻结**：把足够老的 `xmin` 标记为 frozen，防止事务 ID 回卷；
5. **更新统计信息**：普通 vacuum 不更新统计信息，需要 `ANALYZE`。

### 4.1 autovacuum 的触发公式

autovacuum 不是「定时跑」，而是按死元组数量触发：

```
触发阈值 = autovacuum_vacuum_threshold
         + autovacuum_vacuum_scale_factor × reltuples
```

默认值：

- `autovacuum_vacuum_threshold = 50`
- `autovacuum_vacuum_scale_factor = 0.2`

也就是说，一张 1 亿行的表，需要积累 **2000 万** 个死元组才会触发 autovacuum。这显然太迟了。实践中对大表要单独设置：

```sql
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.01
);
```

调整后，1 亿行的表在 200 万死元组时就会触发，膨胀可控得多。

### 4.2 为什么 autovacuum 跑了但还是膨胀

常见原因有四个：

| 原因 | 表现 | 处理 |
|---|---|---|
| 长事务/长快照 | `backend_xmin` 很老，vacuum 清不掉 | 杀长事务、设 `idle_in_transaction_session_timeout` |
| 复制槽未消费 | `pg_replication_slots.active = false` 且 `xmin` 很老 | 删除或修复 slot |
| vacuum 被限速 | `vacuum_cost_limit` 太低，跑得比产生死元组慢 | 提高 cost limit 或对大表单独调参 |
| 表太大，一轮扫不完 | `last_autovacuum` 有值但 dead 仍高 | 分区、`pg_repack`、`VACUUM FULL` 窗口 |

第二点特别隐蔽：一个废弃的逻辑复制槽会永久持有老的 `xmin`，导致全库 vacuum 失效。排查 SQL：

```sql
SELECT slot_name, active, xmin, catalog_xmin,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

如果 `active = false` 且 `retained_wal` 持续增长，这个槽就是罪魁祸首。

---

## 五、事务 ID 回卷：PG 最著名的「定时炸弹」

PostgreSQL 的事务 ID 是 32 位无符号整数，空间约 42 亿。为了判断可见性，它采用的是「模 2^32 环形比较」：一半是过去，一半是未来。当老事务 ID 和新事务 ID 相差超过 2^31 时，可见性判断就会出错。

解决办法是 **冻结（freeze）**：把足够老的元组 `xmin` 标记为 `FrozenXID`，表示「比所有事务都老，永远可见」。

监控 SQL：

```sql
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    2147483647 - age(datfrozenxid) AS xids_remaining
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
```

关键参数：

| 参数 | 默认值 | 作用 |
|---|---|---|
| `autovacuum_freeze_max_age` | 2 亿 | 超过后强制触发 aggressive vacuum |
| `vacuum_freeze_table_age` | 1.5 亿 | 普通 vacuum 触发全表冻结扫描 |
| `vacuum_freeze_min_age` | 5000 万 | 小于该年龄的元组不冻结 |

当 `xids_remaining` 降到几千万，日志会开始告警；降到约 100 万时，数据库会拒绝新的写事务，进入保护模式。这时候只能停业务、做冻结，代价极大。

**结论：不要等告警。把 `age(datfrozenxid)` 纳入日常监控，超过 10 亿就开始排查为什么 aggressive vacuum 跑不动。**

---

## 六、Java 应用侧：三个把 PG 拖死的习惯

### 6.1 长事务：`@Transactional` 包住了远程调用

```java
@Transactional
public void pay(Long orderId) {
    Order order = orderMapper.selectById(orderId);
    // 调支付网关，平均 800ms，最慢 30s
    PaymentResult result = paymentClient.pay(order);
    orderMapper.updateStatus(orderId, result.isSuccess() ? "PAID" : "FAILED");
}
```

这个事务持有了数据库连接和快照，支付网关一慢，`xmin horizon` 就被钉住，vacuum 全面受阻。

正确做法是把远程调用移出事务：

```java
public void pay(Long orderId) {
    Order order = orderMapper.selectById(orderId);
    PaymentResult result = paymentClient.pay(order);   // 事务外
    transactionTemplate.executeWithoutResult(status ->
        orderMapper.updateStatus(orderId, result.isSuccess() ? "PAID" : "FAILED"));
}
```

### 6.2 连接池里的 `idle in transaction`

HikariCP 默认 `autoCommit=true`，本身不会制造长事务。但以下情况会：

- 手动 `connection.setAutoCommit(false)` 后忘了 commit/rollback；
- MyBatis `SqlSession` 未关闭；
- `@Transactional` 方法里有死循环或长时间 `sleep`；
- 用了 `UserTransaction` 但异常路径没回滚。

防护配置：

```yaml
spring:
  datasource:
    hikari:
      auto-commit: true
      transaction-isolation: TRANSACTION_READ_COMMITTED
      maximum-pool-size: 20
      leak-detection-threshold: 20000   # 20s 未归还就告警
```

同时在数据库侧兜底：

```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
ALTER SYSTEM SET statement_timeout = '30s';
ALTER SYSTEM SET lock_timeout = '5s';
```

注意：`idle_in_transaction_session_timeout` 会直接杀掉连接，所以应用侧必须有重连与重试，否则会把「慢」变成「报错」。

### 6.3 监控：把数据库健康度接进 Java 服务

用 `JdbcTemplate` 定时采集，暴露到 Micrometer：

```java
@Component
public class PgHealthMetrics {

    private final JdbcTemplate jdbc;
    private final MeterRegistry registry;

    public PgHealthMetrics(JdbcTemplate jdbc, MeterRegistry registry) {
        this.jdbc = jdbc;
        this.registry = registry;
    }

    @Scheduled(fixedDelay = 60_000)
    public void collect() {
        Long xidAge = jdbc.queryForObject(
            "SELECT max(age(datfrozenxid)) FROM pg_database", Long.class);
        registry.gauge("pg.xid.age", xidAge == null ? 0 : xidAge);

        Long deadTuples = jdbc.queryForObject(
            "SELECT coalesce(sum(n_dead_tup),0) FROM pg_stat_user_tables", Long.class);
        registry.gauge("pg.dead.tuples", deadTuples == null ? 0 : deadTuples);

        Long longTx = jdbc.queryForObject("""
            SELECT count(*) FROM pg_stat_activity
            WHERE state = 'idle in transaction'
              AND now() - state_change > interval '30 seconds'
            """, Long.class);
        registry.gauge("pg.long.idle.tx", longTx == null ? 0 : longTx);
    }
}
```

告警建议：

- `pg.xid.age > 1_000_000_000`：警告；
- `pg.xid.age > 1_500_000_000`：严重；
- `pg.long.idle.tx > 0` 持续 5 分钟：警告；
- 单表 `dead_pct > 30%` 且大小 > 10GB：安排回收。

---

## 七、回收方案怎么选

| 方案 | 锁 | 是否归还 OS 空间 | 适用场景 |
|---|---|---|---|
| `VACUUM` | 弱锁，不阻塞读写 | 否，只标记可复用 | 日常回收 |
| `VACUUM FULL` | AccessExclusiveLock，全程阻塞 | 是 | 小表、维护窗口 |
| `pg_repack` | 短暂锁，在线重建 | 是 | 大表在线瘦身 |
| 分区表 + `DROP PARTITION` | 短锁 | 是 | 时间序列、可分区数据 |
| `CLUSTER` | AccessExclusiveLock | 是（重写） | 顺带按索引重排 |

生产上的常规组合是：

1. 日常靠调过参的 autovacuum；
2. 大表按时间分区，历史数据直接 `DROP PARTITION`；
3. 无法分区的膨胀表用 `pg_repack` 在低峰期在线重建；
4. `VACUUM FULL` 只用于小表或停机窗口。

---

## 八、面试追问

**Q1：PostgreSQL 为什么不像 MySQL 那样用 undo？**

因为 PG 的设计目标是「堆表 + 多版本元组」，更新不覆盖原记录，读旧版本不需要 undo 重建，崩溃恢复也更简单。代价是表膨胀和 vacuum 成本。MySQL 的聚簇索引更新更紧凑，但需要 undo 和 purge 线程配合。

**Q2：`DELETE` 全表后，为什么表还是很大？**

`DELETE` 只是给元组打 `xmax`，空间仍在 heap 里。要归还操作系统，必须 `VACUUM FULL` 或 `pg_repack` 重写表。普通 `VACUUM` 只能让空间在表内复用。

**Q3：autovacuum 会不会锁表？**

普通 autovacuum 拿的是 `ShareUpdateExclusiveLock`，不阻塞读写，但会阻塞 DDL 和 `VACUUM FULL`。aggressive vacuum（防回卷）也是同样的锁级别，但扫描范围更大、更耗时。

**Q4：逻辑复制槽为什么会拖垮 vacuum？**

复制槽需要保留从 `restart_lsn` 开始的所有 WAL，同时也钉住了对应的 `catalog_xmin`。如果消费者长期不在线，这个 `xmin` 就永远不会推进，死元组无法清理，最终导致全库膨胀甚至回卷风险。

**Q5：`fillfactor` 调低有什么代价？**

页内预留空间变多，同样行数占用更多页，顺序扫描的 IO 增加。它适合更新频繁、能走 HOT 的表；只读或追加型表保持 100 即可。

---

## 九、总结

把这篇的要点压缩成五句话：

1. PostgreSQL 的 MVCC 是堆内多版本，旧版本靠 vacuum 回收，不是「删了就没了」；
2. 长事务、长快照、废弃复制槽会钉住 `xmin horizon`，让 vacuum 白跑；
3. autovacuum 的默认阈值对大表太宽松，必须按表调 `scale_factor`；
4. 事务 ID 是 32 位环形空间，`age(datfrozenxid)` 必须进监控；
5. Java 侧最大的杀手是「事务包远程调用」和「连接泄漏成 idle in transaction」。

MySQL 的运维经验不能直接平移。把这三件事——膨胀监控、xmin 监控、长事务治理——做成常态，PostgreSQL 其实非常稳。
