---
title: 【MySQL 底层】InnoDB Purge 机制深度解析：History List、undo 版本回收与长事务拖累
date: 2026-10-29 08:00:00
tags:
  - MySQL
  - InnoDB
  - MVCC
  - undo log
  - 长事务
categories:
  - MySQL
author: 东哥
---

# 【MySQL 底层】InnoDB Purge 机制深度解析：History List、undo 版本回收与长事务拖累

## 前言

先说一个真实场景。

某业务库磁盘告警，`ibdata1` 和 undo 表空间一路涨到 200 多 G，业务写入 TPS 没涨，数据量也没涨。DBA 上去看了一眼：

```sql
SHOW ENGINE INNODB STATUS\G
-- History list length 6842137
```

History List Length（下面简称 HLL）六百多万，purge 完全跟不上。再查 `information_schema.innodb_trx`，发现一个跑了 **9 个小时** 的只读事务——某个报表任务用 `REPEATABLE READ` 开了一个事务，中间在等外部接口，一直没提交。

这一个事务，让 InnoDB 不敢回收它之后产生的所有 undo 版本。写入照常进行，undo 只能一直堆，purge 线程空转，磁盘被慢慢吃光。

这类问题的根因不是"磁盘不够"，而是对 **purge 机制** 没有建立正确的模型。本文把这条链路拆开讲：undo 版本链怎么产生、purge 什么时候能回收、HLL 怎么读、长事务为什么是 purge 的天敌、以及 Java 应用侧怎么把长事务挡在门外。

## 一、purge 到底在清理什么

要理解 purge，先要理解 MVCC 的"版本链"。

InnoDB 的每行记录都有隐藏列：

| 隐藏列 | 含义 |
|---|---|
| `DB_TRX_ID` | 最后修改这行的事务 ID |
| `DB_ROLL_PTR` | 指向 undo log 中上一个版本的回滚指针 |
| `DB_ROW_ID` | 无主键时生成的行 ID（有主键则不生成） |

一次 `UPDATE` 并不是"原地改"，而是：

1. 把旧值写进 undo log，形成一条 undo record；
2. 修改当前行，`DB_TRX_ID` 设为当前事务 ID，`DB_ROLL_PTR` 指向刚写的 undo record。

于是同一行的多个历史版本通过 `DB_ROLL_PTR` 串成一条 **版本链**。快照读（普通 `SELECT`）根据自己的 ReadView 沿版本链往回找"我能看见的那个版本"。

**关键点来了**：只要还有一个活跃 ReadView 可能读到某个旧版本，这个旧版本就不能删。purge 的职责就是：判断哪些 undo record "已经没有任何 ReadView 需要了"，把它们及其对应的索引记录真正删除，然后释放 undo 空间。

> 一句话：**purge 不是在清理日志，而是在回收"再也不会被读到"的历史版本。**

## 二、purge 的线程模型

MySQL 5.7 之后 purge 是"协调者 + 工作者"模型：

```
                      ┌──────────────────────────┐
                      │  purge coordinator thread │
                      │  (srv_purge_coordinator)  │
                      └────────────┬─────────────┘
                                   │ 分配任务（按 undo 表空间/回滚段）
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
  purge worker 0            purge worker 1            purge worker N
  (innodb_purge_threads)    (innodb_purge_threads)    (innodb_purge_threads)
        │                          │                          │
        └──────────► 解析 undo record → 删除标记记录 → 清理二级索引 → 推进 purge view
```

几个必须记住的参数：

| 参数 | 默认值 | 作用 | 调优建议 |
|---|---|---|---|
| `innodb_purge_threads` | 4 | purge worker 数量 | 写密集且 purge lag 高时可到 8，但别超 CPU 核数一半 |
| `innodb_purge_batch_size` | 300 | 每轮处理的 undo 页数 | 影响单轮工作量，不是"越大越好"，过大反而拉长单次持锁 |
| `innodb_max_purge_lag` | 0 | HLL 超过该值时给 DML 加延迟 | 0 表示不限制；线上建议设一个阈值做自我保护 |
| `innodb_max_purge_lag_delay` | 0 | 上述延迟的最大毫秒数 | 与上者配合，避免把写入彻底拖死 |
| `innodb_undo_log_truncate` | ON（8.0） | 允许 truncate undo 表空间 | 必须配合独立 undo 表空间才生效 |

### 2.1 为什么 purge 是"分批"而不是"一次清完"

purge 在清理时需要在 B+ 树里定位并删除记录，会持有短期 latches，也可能产生 redo。如果一次清太多：

- 单次持有 latch 时间变长 → 其他 DML 排队；
- 一个巨大的 purge 批次可能造成 IO 尖峰；
- 崩溃恢复时间变长。

所以设计成"每轮 300 个 undo 页，处理完让出"，用 `innodb_purge_batch_size` 控制节奏。这也解释了为什么 HLL 高位时 purge 需要"慢慢追"——它是被刻意限速的。

## 三、History List Length 怎么读

HLL 是 `trx_sys->rseg_history_len`，表示 **history list 上未被 purge 的 undo record 数量**。查看方式：

```sql
-- 方式 1：引擎状态（最常用）
SHOW ENGINE INNODB STATUS\G
-- 输出中：History list length 1234

-- 方式 2：metrics 表（8.0，更细）
SELECT NAME, COUNT
FROM information_schema.innodb_metrics
WHERE NAME IN ('trx_rseg_history_len',
               'trx_undo_recs_purged',
               'purge_undo_batch_rounds');

-- 方式 3：Prometheus（mysqld_exporter）
-- mysql_innodb_trx_rseg_history_len
```

### 3.1 判读标准（经验值）

| HLL 区间 | 判读 | 动作 |
|---|---|---|
| < 1 万 | 健康 | 无需关注 |
| 1 万 ~ 10 万 | 轻度积压 | 看是否有慢事务；观察趋势 |
| 10 万 ~ 100 万 | 明显积压 | 立即查长事务、检查 purge 是否被阻塞 |
| > 100 万 | 严重 | undo 空间会快速膨胀，写入性能开始受影响，必须处置 |

重点不是瞬时值，而是 **斜率和持续性**。业务高峰期 HLL 冲到 5 万然后回落是正常的；一直单调上涨就是病。

一个非常实用的监控表达式：

```promql
# HLL 10 分钟内涨幅，> 1000/s 说明 purge 明显跟不上
increase(mysql_innodb_trx_rseg_history_len[10m]) / 600
```

## 四、purge 被什么卡住

这是本文的核心。purge 推进的边界由 **最老的活跃 ReadView** 决定。而 ReadView 由活跃事务持有。所以：

> **purge 的上限 = min(所有活跃事务中最老的 ReadView)**

四种典型的"卡住"来源：

### 4.1 长事务（read view 长期不释放）

`REPEATABLE READ` 下，事务里第一条快照读就会创建 ReadView，直到事务结束才释放。中间哪怕一直在 sleep，purge 也过不去。

```sql
-- 找出运行超过 60 秒的事务
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS secs,
       trx_mysql_thread_id AS conn_id,
       trx_rows_modified, trx_isolation_level
FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60
ORDER BY trx_started;
```

### 4.2 备份 / 从库延迟

逻辑备份工具（`mysqldump --single-transaction`、`mydumper`）会用一致性快照，备份跑多久，ReadView 就活多久。物理备份（XtraBackup）不持有长 ReadView，影响小得多。

从库如果 `STOP SLAVE SQL_THREAD` 或严重延迟，主库上的 purge 不受影响，但**从库自己**的 HLL 会疯涨——因为从库回放时也在生成 undo，而它的 purge 需要等 SQL 线程推进。

### 4.3 purge 自身被 latch 或 IO 阻塞

如果 `innodb_purge_threads` 太少、单轮批次太大、或者磁盘 IO 打满，purge worker 会卡在 IO 上，表现为：

- `trx_undo_recs_purged` 增长缓慢；
- `SHOW ENGINE INNODB STATUS` 里 purge 相关等待（`innodb_purge_...`）;
- `innodb_metrics` 中 `purge_del_mark_records` 停滞。

### 4.4 大事务造成的"瞬间巨量待清理"

一次 `DELETE FROM t WHERE create_time < '2025-01-01'` 删掉 2000 万行，会产生巨量 delete-mark 记录和 undo。即使事务立刻提交，purge 也要花很长时间消化——期间二级索引里全是"标记删除但未物理删除"的记录，查询会变慢（扫描到大量死记录）。

## 五、把长事务挡在 Java 应用侧

DBA 能 kill 事务，但根因通常在应用代码。三个层面治理：

### 5.1 事务边界审计：MyBatis 拦截器打印慢事务

思路：在 `Executor` 层记录事务开始时间，`commit/rollback` 时打印耗时与 SQL 数量。轻量、无侵入、能定位到具体 Mapper 方法。

```java
@Intercepts({
    @Signature(type = Executor.class, method = "update",
               args = {MappedStatement.class, Object.class}),
    @Signature(type = Executor.class, method = "query",
               args = {MappedStatement.class, Object.class, RowBounds.class,
                       ResultHandler.class})
})
public class SlowTransactionInterceptor implements Interceptor {

    private static final Logger log = LoggerFactory.getLogger(SlowTransactionInterceptor.class);
    private static final long THRESHOLD_MS = 1000L;

    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        MappedStatement ms = (MappedStatement) invocation.getArgs()[0];
        long start = System.nanoTime();
        try {
            return invocation.proceed();
        } finally {
            long costMs = (System.nanoTime() - start) / 1_000_000;
            if (costMs > THRESHOLD_MS) {
                // 注意：这是单条 SQL 慢，不是事务慢，两者要分开看
                log.warn("slow-sql cost={}ms id={} sql={}",
                        costMs, ms.getId(), ms.getBoundSql(invocation.getArgs()[1]).getSql());
            }
        }
    }
}
```

单条 SQL 慢和事务长是两件事。真正抓"事务级"长事务，要在 `DataSourceTransactionManager` 外包一层：

```java
public class TransactionDurationAspect {

    @Around("@annotation(org.springframework.transaction.annotation.Transactional)")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        String method = pjp.getSignature().toShortString();
        try {
            return pjp.proceed();
        } finally {
            long cost = System.currentTimeMillis() - start;
            if (cost > 3000) {
                log.error("LONG_TRANSACTION method={} cost={}ms thread={}",
                        method, cost, Thread.currentThread().getName());
                // 打点上报，接入 Prometheus Counter，配合告警
            }
        }
    }
}
```

### 5.2 事务里绝对不要做远程调用

以下操作必须移出事务：

- HTTP / RPC 调用（第三方接口、微服务）；
- 发 MQ 消息（应该用本地消息表 + 事务外投递，或事务消息）；
- 文件上传/下载、OSS 操作；
- 大批量循环里的 `selectOne`（N+1，事务时长线性放大）；
- `Thread.sleep` / 锁等待 / 分布式锁续期。

一个很常见的错误写法：

```java
@Transactional
public void createOrder(OrderCmd cmd) {
    orderMapper.insert(cmd.toOrder());
    // ❌ 事务内调用风控 RPC，超时 3 秒 → 事务至少 3 秒
    RiskResult r = riskClient.check(cmd.getUserId(), cmd.getAmount());
    if (!r.isPass()) {
        throw new BizException("风控拒绝");
    }
    // ❌ 事务内发 MQ，Broker 抖动直接拖长事务
    mqProducer.send(new Message("order-created", cmd.getOrderId()));
}
```

正确做法：先远程校验 → 再开短事务写库 → 事务提交后再发消息（或落本地消息表由后台投递）。

### 5.3 拆大事务：批处理 + 分片

```java
public void archiveOldOrders(LocalDate before, int batchSize) {
    while (true) {
        // 每批独立短事务，批间 sleep 让 purge 追上
        int deleted = txTemplate.execute(status ->
                orderMapper.deleteBatch(before, batchSize));
        if (deleted < batchSize) {
            break;
        }
        try {
            Thread.sleep(50);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            break;
        }
    }
}
```

注意：`DELETE ... LIMIT` 每批也要走索引，别写成全表扫描；`archiveOldOrders` 应在低峰执行，并观察 HLL 变化，如果 HLL 涨得太快就加大 sleep。

## 六、事后急救与空间回收

### 6.1 急救顺序

1. **先查再杀**：确认是哪个连接、哪个业务、能否沟通；`KILL <thread_id>` 前先 `SHOW PROCESSLIST` 看状态。
2. **观察 HLL 拐点**：kill 后 HLL 不会立刻下降（purge 有延迟），看 `trx_undo_recs_purged` 是否开始增长。
3. **临时加大 purge 能力**：`SET GLOBAL innodb_purge_threads = 8;`（8.0 支持动态调整）。
4. **必要时加保护**：`SET GLOBAL innodb_max_purge_lag = 1000000;` 让 DML 主动让路，避免 undo 无限膨胀。

### 6.2 真正把磁盘还回去

只 purge 不 truncate，undo 表空间文件不会变小（`innodb_undo_log_truncate` 只截断到初始大小附近）。步骤：

```sql
-- 1. 确认有独立 undo 表空间（8.0 默认有 2 个）
SELECT SPACE_NAME, FILE_NAME, SIZE, STATE
FROM information_schema.innodb_tablespaces
WHERE SPACE_TYPE = 'Undo';

-- 2. 确认 truncate 开启
SHOW VARIABLES LIKE 'innodb_undo_log_truncate';   -- ON
SHOW VARIABLES LIKE 'innodb_purge_rseg_truncate_frequency'; -- 默认 128

-- 3. 等到 undo 表空间进入 inactive 才会截断，靠 purge 推进
-- 观察：
SELECT NAME, COUNT FROM information_schema.innodb_metrics
WHERE NAME = 'trx_rseg_history_len';
```

想立刻回收磁盘，只能停机 + 重建 undo 表空间（`innodb_undo_tablespaces` 变更属于初始化参数，8.0 需 `--initialize` 或 `ALTER UNDO TABLESPACE ... SET INACTIVE` 后删除文件），生产上通常选择"先让 HLL 降下来，让 truncate 自然生效"。

## 七、一张表串起来

| 现象 | 可能原因 | 定位手段 | 处置 |
|---|---|---|---|
| HLL 单调上涨 | 长事务 / 备份快照 | `innodb_trx` 看 `trx_started` | kill 或改代码 |
| HLL 高但 purge 在涨 | 历史欠账太多 | `trx_undo_recs_purged` 斜率 | 加大 purge_threads，等它追 |
| HLL 低但 undo 文件大 | 未 truncate | `innodb_tablespaces` | 开 truncate，等 inactive |
| 删除后查询变慢 | delete-mark 未清理 | `EXPLAIN` 看扫描行数 / `innodb_metrics` | 等 purge，避免大事务 DELETE |
| 从库 HLL 暴涨 | SQL 线程停/延迟 | `SHOW SLAVE STATUS` | 恢复回放，检查大事务 |

## 八、面试常见追问

**Q1：purge 和 MVCC 是什么关系？**
purge 是 MVCC 的"回收器"。MVCC 靠 undo 版本链实现快照读，purge 负责在确认没有 ReadView 需要旧版本后删除它们。没有 purge，undo 会无限增长；purge 太激进，会破坏正在读的一致性视图。

**Q2：为什么 RR 隔离级别下长事务危害更大？**
RR 的 ReadView 在事务第一次快照读时创建，并且**整个事务期间复用**，所以它"钉住"的版本边界是事务开始时刻。RC 每条语句新建 ReadView，边界可以往前推，长事务的危害相对小（但仍有 undo 与锁的问题）。

**Q3：`innodb_max_purge_lag` 调大是不是能解决问题？**
不能。它只是"当积压严重时让 DML 变慢"，属于保护机制，不是清理机制。真正的解法是消除长事务 + 提升 purge 吞吐。而且它限制的是延迟，如果 `innodb_max_purge_lag_delay` 没配，延迟计算可能把写入拖到不可用。

**Q4：`DELETE` 和 `TRUNCATE` 对 purge 的影响？**
`DELETE` 是逐行标记删除，产生 undo 与 delete-mark，需要 purge 清理；`TRUNCATE` 是重建表空间，几乎不产生 undo，HLL 不受影响。所以清理大表历史数据，优先考虑分区表 `DROP PARTITION`，其次 `TRUNCATE` 整表，最后才是分批 `DELETE`。

**Q5：从库的 purge 和主库有关系吗？**
没有直接关系。从库回放 binlog 时自己生成 undo，自己 purge。但主库的大事务会在从库产生同样大的 undo 峰值，且从库回放常是单线程（或有限并行），更容易积压。

## 九、总结

把 purge 这件事压缩成三句话：

1. **undo 版本能不能删，取决于最老的活跃 ReadView**——所以长事务是 purge 的天敌，不是"慢 SQL"的问题。
2. **HLL 是唯一需要长期盯的指标**，看斜率不看瞬时值；配合 `trx_undo_recs_purged` 判断是"欠账多"还是"被卡住"。
3. **治理在应用侧**：短事务、远程调用出事务、大操作拆批、删历史数据用分区，这四件事做到，purge 基本不会成为问题。

磁盘告警往往只是最后一张多米诺骨牌。真正该看的是那块倒下的第一张：一个忘了提交的事务。
