---
title: 【MySQL 运维】Performance Schema 深度实战：从 SQL 画像、等待事件到 sys 视图的性能诊断体系
date: 2026-09-14 08:00:00
tags:
  - MySQL
  - 性能诊断
  - 运维
  - Performance Schema
categories:
  - MySQL
  - 数据库
author: 东哥
---

# 【MySQL 运维】Performance Schema 深度实战：从 SQL 画像、等待事件到 sys 视图的性能诊断体系

## 面试官：线上数据库突然变慢，你怎么定位是哪条 SQL 干的？

大多数人的回答链路是：**开慢查询日志 → 看 slow.log → 分析**。这个链路有致命缺陷：

- 慢查询日志**有阈值**（`long_query_time`），1 秒以下的 SQL 全部看不到，但 100 条 900ms 的 SQL 足以拖垮整个库
- 慢查询日志**只有执行时间**，没有「等待时间」——锁等待、IO 等待、网络等待全都不体现，而锁等待恰恰是线上慢的头号原因
- 慢查询日志**不聚合**：同一条 SQL 一天执行 100 万次，日志里就是 100 万行

**Performance Schema（PFS）** 解决的正是这些问题：它是一个运行在 MySQL 内部、基于内存的「性能数据采集框架」，能告诉你**每条 SQL（按 digest 聚合）消耗了多少总时间、时间花在哪（等待事件）、锁等了多久、IO 读了多少页**。

这篇从架构到实战，把 PFS 讲透。

---

## 一、PFS 是什么：一张对比表看清楚

| 维度 | 慢查询日志 | `SHOW STATUS` | Performance Schema |
| --- | --- | --- | --- |
| 粒度 | 单次执行 | 全局计数 | 单事件 + 聚合视图 |
| 是否聚合 | 否 | 是（全局） | 是（按 SQL / 表 / 线程 / 阶段） |
| 时间维度 | 仅执行耗时 | 无 | 执行 + 等待 + 阶段 + 锁 + IO |
| 阈值 | 有（漏掉亚阈值） | 无 | 无（全量采样） |
| 实时性 | 延时（刷盘） | 实时 | 实时 |
| 开销 | 极低 | 极低 | 可控（可精确到 instrument） |
| 历史 | 有（文件） | 无（重启归零） | 无（重启归零，可持久化到表） |

一句话：**PFS 是「带时间维度的、可聚合的、在线可查的」性能数据库内部观测器。**

它从 MySQL 5.5 引入（当时很简陋），5.6/5.7 逐步完善，**5.7 开始默认开启**（`performance_schema=ON`），MySQL 8.0 增加了 `data_locks`、`data_lock_waits`、`error_log` 等表，并强化了 `sys` schema。

---

## 二、PFS 内部架构：instruments、consumers、threads

理解这三个概念，才能理解「为什么开了 PFS 却查不到数据」。

```
┌─────────────────────────────────────────────────┐
│  内存表（虚拟表）: events_statements_*, events_waits_* … │
└───────────────▲─────────────────────────────────┘
                │ 数据写入
┌───────────────┴─────────────────────────────────┐
│  consumers（消费者）: 决定「哪些表接收数据」        │
│    events_statements_current / history / history_long  │
└───────────────▲─────────────────────────────────┘
                │ 事件上报
┌───────────────┴─────────────────────────────────┐
│  instruments（仪器）: 决定「采集哪些事件」          │
│    等待事件: wait/io/file/sql/*、wait/lock/table/sql/handler … │
│    阶段事件: stage/sql/executing、stage/sql/optimizing …  │
│    语句事件: statement/sql/select、statement/sql/update … │
└───────────────▲─────────────────────────────────┘
                │ 埋点
         MySQL Server 内核代码
```

**三个层次的开关必须同时打开，数据才会出现**：

1. **编译开关**：`performance_schema=ON`（5.7+ 默认）
2. **instrument 开关**：`UPDATE setup_instruments SET ENABLED='YES' WHERE NAME LIKE 'wait/io/table/%'`（决定「采不采」）
3. **consumer 开关**：`UPDATE setup_consumers SET ENABLED='YES' WHERE NAME='events_statements_history_long'`（决定「存到哪张表」）

相关配置表（都在 `performance_schema` 库）：

| 表 | 作用 |
| --- | --- |
| `setup_instruments` | 所有可采集事件点，控制 ENABLED / TIMED |
| `setup_consumers` | 数据投递目标（current / history / history_long） |
| `setup_threads` | 线程级别的 instrument 开关 |
| `setup_actors` | 按 user/host 过滤（控制哪些连接的线程被采集） |
| `setup_objects` | 按对象类型过滤（表、事件、函数等） |
| `setup_timers` | 计时器类型与精度 |

**默认配置**：语句和阶段事件的 `current` + `history` 开启，`history_long` 默认**关闭**（因为占内存大）。`events_waits_*` 的 history 表默认也是关闭的，所以「查等待事件只有 current 表有数据，history 表是空的」是正常现象。

---

## 三、核心表速览

### 3.1 SQL 画像：events_statements_summary_by_digest（最重要的一张表）

```sql
SELECT
  SCHEMA_NAME,
  DIGEST_TEXT,
  COUNT_STAR                                   AS exec_count,
  ROUND(SUM_TIMER_WAIT / 1e12, 2)              AS total_sec,
  ROUND(AVG_TIMER_WAIT / 1e9, 2)               AS avg_ms,
  ROUND(MAX_TIMER_WAIT / 1e9, 2)               AS max_ms,
  SUM_ROWS_EXAMINED                            AS rows_examined,
  SUM_ROWS_SENT                                AS rows_sent,
  SUM_NO_INDEX_USED                            AS no_index,
  SUM_CREATED_TMP_DISK_TABLES                  AS tmp_disk_tables,
  SUM_SORT_MERGE_PASSES                        AS sort_merge_passes
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

这张表就是「**数据库级 SQL 画像**」，几个字段的实战价值：

- `SUM_TIMER_WAIT`：**总耗时**，这是排序的第一依据。一条 1ms 的 SQL 跑 1 亿次，比一条 5s 的 SQL 危害更大
- `AVG_TIMER_WAIT`：单次平均耗时，用于区分「慢 SQL」与「高频 SQL」
- `SUM_ROWS_EXAMINED / SUM_ROWS_SENT`：**扫描放大比**。比值 > 100 说明索引效率差
- `SUM_NO_INDEX_USED`：**未走索引的次数**，> 0 要立刻查
- `SUM_CREATED_TMP_DISK_TABLES`：**磁盘临时表**，> 0 说明有排序/分组溢出到磁盘
- `SUM_SORT_MERGE_PASSES`：**多趟归并**，> 0 说明 `sort_buffer_size` 可能偏小

> **计时器单位**：PFS 内部用皮秒（picosecond，1e-12 秒）。除以 `1e12` 得到秒，除以 `1e9` 得到毫秒，除以 `1e6` 得到微秒。这是最常见的踩坑点——很多人直接看原始值，误以为单位是纳秒或微秒。

**清空统计**（分析完一个时间段后重置）：

```sql
TRUNCATE TABLE performance_schema.events_statements_summary_by_digest;
```

### 3.2 等待事件：时间到底花在哪

```sql
SELECT
  EVENT_NAME,
  COUNT_STAR                                    AS cnt,
  ROUND(SUM_TIMER_WAIT / 1e12, 2)               AS total_sec,
  ROUND(AVG_TIMER_WAIT / 1e6, 2)                AS avg_us
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

典型输出与含义：

| EVENT_NAME | 含义 |
| --- | --- |
| `wait/io/table/sql/handler` | 表级 IO（含行锁等待！） |
| `wait/io/file/innodb/innodb_data_file` | 数据文件 IO |
| `wait/io/file/innodb/innodb_log_file` | redo log 文件 IO |
| `wait/synch/mutex/innodb/*` | InnoDB 内部互斥量竞争 |
| `wait/synch/rwlock/*` | 读写锁竞争 |
| `wait/io/socket/sql/client_connection` | 客户端/服务端网络等待 |
| `wait/lock/metadata/sql/mdl` | **元数据锁等待**（DDL 阻塞的元凶） |
| `wait/synch/cond/innodb/*` | 条件变量等待 |

**关键认知**：MySQL 层的「慢」，90% 可以归到三类等待——**IO 等待、锁等待、网络等待**。PFS 让这三类第一次变得可量化。

### 3.3 IO 与表热点

```sql
-- 按表看 IO（读了多少、写了多少、耗时多久）
SELECT
  OBJECT_SCHEMA, OBJECT_NAME,
  COUNT_READ, COUNT_WRITE,
  ROUND(SUM_TIMER_READ / 1e12, 2)  AS read_sec,
  ROUND(SUM_TIMER_WRITE / 1e12, 2) AS write_sec
FROM performance_schema.table_io_waits_summary_by_table
ORDER BY SUM_TIMER_READ + SUM_TIMER_WRITE DESC
LIMIT 20;

-- 按索引看使用次数（找出「建了没用」的索引）
SELECT
  OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
  COUNT_STAR AS used,
  COUNT_READ
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE INDEX_NAME IS NOT NULL
ORDER BY COUNT_STAR ASC        -- 升序：最没用
LIMIT 30;

-- 按文件看 IO
SELECT FILE_NAME, COUNT_READ, COUNT_WRITE,
       ROUND(SUM_TIMER_READ / 1e12, 2) AS read_sec
FROM performance_schema.file_summary_by_instance
ORDER BY SUM_TIMER_READ DESC
LIMIT 10;
```

`table_io_waits_summary_by_index_usage` 是**索引治理的神器**：`COUNT_STAR = 0` 的索引意味着从 PFS 启动至今从未被使用过。结合业务高峰期采集，可以作为「删冗余索引」的硬证据（注意：唯一索引、外键所需索引、以及仅被 `MIN/MAX` 用到的索引要谨慎）。

### 3.4 锁与事务（MySQL 8.0）

MySQL 8.0 把锁信息从 `information_schema.INNODB_LOCKS` 迁移到了 PFS：

```sql
-- 当前持有的锁
SELECT * FROM performance_schema.data_locks\G

-- 谁在等谁的锁（阻塞关系，直接给出 BLOCKING_ENGINE_TRANSACTION_ID）
SELECT * FROM performance_schema.data_lock_waits\G

-- 正在运行的事务
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS running_sec,
       trx_rows_locked, trx_rows_modified, trx_isolation_level, trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started ASC;
```

`data_lock_waits` 直接给出阻塞链，配合 `sys.innodb_lock_waits` 更直观：

```sql
SELECT
  waiting_pid, waiting_query, waiting_lock_type,
  blocking_pid, blocking_query, blocking_lock_type,
  wait_age, locked_table, locked_index
FROM sys.innodb_lock_waits;
```

### 3.5 阶段事件：SQL 在哪个阶段慢

如果一条 SQL 既没有大量 IO 等待、也没有锁等待，但仍慢，那就要看阶段：

```sql
SELECT EVENT_NAME, COUNT_STAR,
       ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_sec
FROM performance_schema.events_stages_summary_global_by_event_name
WHERE COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 15;
```

关键阶段：

| 阶段 | 含义 | 慢的常见原因 |
| --- | --- | --- |
| `stage/sql/executing` | 执行 | IO/锁等待 |
| `stage/sql/optimizing` | 优化器决策 | 表太多、JOIN 顺序枚举爆炸 |
| `stage/sql/statistics` | 统计信息读取 | 表多、统计信息陈旧 |
| `stage/sql/preparing` | 预处理 | 解析开销 |
| `stage/sql/Sending data` | 发送数据 | 结果集太大、网络慢 |
| `stage/sql/Opening tables` | 打开表 | `table_open_cache` 太小 |
| `stage/sql/Creating sort index` | 排序 | 文件排序 |
| `stage/sql/end` | 清理 | 临时表清理 |

**`stage/sql/Sending data` 占比高**是个经典误判点：它其实常常包含「读取数据」的时间，不只是网络传输。

---

## 四、sys schema：把 PFS 翻译成人话

`performance_schema` 的原始表字段名晦涩、单位是皮秒、需要大量 JOIN。**`sys` schema 是官方提供的「视图层」，把 PFS 翻译成可读性更好的结果。**

最常用的几个视图：

```sql
-- 1. 按总耗时排的 SQL（自动格式化时间单位，秒/毫秒）
SELECT * FROM sys.statement_analysis
ORDER BY total_latency DESC LIMIT 20;

-- 2. 执行次数最多的 SQL
SELECT * FROM sys.statement_analysis
ORDER BY exec_count DESC LIMIT 20;

-- 3. 全表扫描最多的表
SELECT * FROM sys.schema_tables_with_full_table_scans
ORDER BY rows_full_scanned DESC LIMIT 20;

-- 4. 冗余索引（可删除的重复索引）
SELECT * FROM sys.schema_redundant_indexes;

-- 5. 未使用的索引
SELECT * FROM sys.schema_unused_indexes;

-- 6. IO 热点表
SELECT * FROM sys.io_global_by_file_by_bytes
ORDER BY total DESC LIMIT 10;

-- 7. 当前锁等待
SELECT * FROM sys.innodb_lock_waits;

-- 8. 按主机/用户/库看资源消耗
SELECT * FROM sys.host_summary;
SELECT * FROM sys.user_summary;
SELECT * FROM sys.io_by_thread_by_latency;

-- 9. 内存占用分片
SELECT * FROM sys.memory_global_by_current_bytes LIMIT 20;

-- 10. 等待事件总览（带人类可读单位）
SELECT * FROM sys.waits_global_by_latency LIMIT 20;
```

**`sys.schema_unused_indexes` + `sys.schema_redundant_indexes` 是索引治理的标准工具**，但注意 `sys.schema_index_statistics` 依赖 `table_io_waits_summary_by_index_usage`，PFS 重启或 `TRUNCATE` 后会从零开始统计，至少积累一个完整业务周期（含月末、大促）再下结论。

---

## 五、实战：三个真实排查场景

### 场景 1：接口 P99 从 200ms 涨到 2s，DB CPU 只有 30%

**思路**：CPU 不高但慢 → 大概率在等。

```sql
-- 先看等待事件排行榜
SELECT EVENT_NAME, ROUND(SUM_TIMER_WAIT/1e12,2) AS total_sec
FROM performance_schema.events_waits_summary_global_by_event_name
ORDER BY SUM_TIMER_WAIT DESC LIMIT 5;
```

假设发现 `wait/lock/metadata/sql/mdl` 高居榜首 → **MDL 等待**。

```sql
-- 确认锁等待链
SELECT * FROM sys.schema_table_lock_waits\G
```

结果发现某张表上有长时间未提交的事务持有 `SHARED_READ`，导致后续 DDL 拿不到 `EXCLUSIVE` 而排队，**DDL 又阻塞了所有后续读写**。这就是典型的「DDL 阻塞雪崩」。

**结论**：根因不是慢 SQL，而是一个忘了提交的 `SELECT ... FOR UPDATE` 事务 + 一次在线 DDL。

### 场景 2：某接口偶发超时，但慢日志里只有零星几条

**思路**：慢日志有阈值，先看 PFS 的 digest 聚合。

```sql
SELECT DIGEST_TEXT,
       COUNT_STAR,
       ROUND(AVG_TIMER_WAIT/1e9,2) AS avg_ms,
       ROUND(MAX_TIMER_WAIT/1e9,2) AS max_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%order%'
ORDER BY COUNT_STAR DESC LIMIT 10;
```

发现某条 SQL `exec_count=800万`、`avg_ms=90ms`、`max_ms=3000ms`。**总耗时 = 720,000 秒**，是真正的资源黑洞，而它从没进过慢查询日志（平均 90ms < 阈值 1s）。

**结论**：优化目标不是「最慢的 SQL」，而是「总耗时最高的 SQL」。这是 PFS 相对慢日志最大的价值。

### 场景 3：磁盘 IO 打满，不知道读写在哪张表

```sql
SELECT OBJECT_SCHEMA, OBJECT_NAME,
       ROUND(SUM_TIMER_READ/1e12,2) AS read_sec,
       ROUND(SUM_TIMER_WRITE/1e12,2) AS write_sec,
       COUNT_READ, COUNT_WRITE
FROM performance_schema.table_io_waits_summary_by_table
ORDER BY SUM_TIMER_READ DESC LIMIT 10;
```

再下钻到索引级：

```sql
SELECT INDEX_NAME, COUNT_READ, ROUND(SUM_TIMER_READ/1e12,2) AS read_sec
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA='order_db' AND OBJECT_NAME='t_order'
ORDER BY SUM_TIMER_READ DESC;
```

如果发现是**二级索引**贡献了大部分读，说明存在大量回表；如果是 `PRIMARY` 贡献大，说明主键范围扫描过多。据此决定：加覆盖索引、还是调整主键设计。

---

## 六、PFS 的性能开销与生产配置

PFS 的开销来自「埋点 + 内存写入」，**默认配置下约 5%~10% 的性能损失**（官方口径与实测差异较大，取决于 instruments 开启量）。生产建议：

### 6.1 生产推荐配置（my.cnf）

```ini
[mysqld]
performance_schema = ON
performance_schema_consumer_events_statements_history_long = OFF  # 默认关，别乱开
performance_schema_max_digest_length = 4096                       # 默认 1024，长 SQL 会被截断
performance_schema_max_sql_text_length = 4096
performance_schema_digests_size = 10000                           # 默认 5000，SQL 种类多时增大
performance_schema_events_statements_history_size = 20
performance_schema_max_memory_classes = 400
```

### 6.2 按需开启高开销 instrument

```sql
-- 默认关闭「等待事件」的 history，排查时临时打开
UPDATE performance_schema.setup_consumers
SET ENABLED = 'YES'
WHERE NAME LIKE 'events_waits%';

-- 只采集语句级 + 表级 IO（开销可控）
UPDATE performance_schema.setup_instruments
SET ENABLED='YES', TIMED='YES'
WHERE NAME IN ('statement/sql/select','statement/sql/update',
               'statement/sql/delete','statement/sql/insert',
               'wait/io/table/sql/handler');
```

**排查完记得关掉高开销的 instrument**。

### 6.3 按用户/库过滤，降低采集面

```sql
-- 只采集业务账号的线程，忽略监控账号
UPDATE performance_schema.setup_actors
SET ENABLED='NO'
WHERE USER='monitor_user' AND HOST='%';

-- 忽略系统库
UPDATE performance_schema.setup_objects
SET ENABLED='NO'
WHERE OBJECT_SCHEMA IN ('mysql','sys','information_schema');
```

### 6.4 常见坑

1. **`performance_schema` 表查询很慢**：这些是内存表，全表扫描没有索引，`ORDER BY` 会扫全表。**限制 WHERE 条件 + LIMIT**，不要在大实例上无脑 `SELECT *`。
2. **统计不跨重启**：PFS 数据在内存，重启即清零。需要长期趋势请用 Prometheus `mysqld_exporter` 或定期快照落库。
3. **`DIGEST_TEXT` 为 NULL**：超过 `max_digest_length` 的 SQL 无法归一化，会归到 `NULL` digest 桶。调大该参数（需重启）。
4. **`events_statements_history_long` 慎开**：默认 10000 行 × 每行完整 SQL 文本，内存占用可观，且写入有额外开销。
5. **主从环境要分别采集**：从库的读热点与主库完全不同，别只盯主库。
6. **MySQL 8.0 移除了部分列**：升级时注意 `events_statements_summary_by_digest` 的列变化（如 `SUM_NO_GOOD_INDEX_USED` 在 8.0 被移除）。

---

## 七、面试追问连环炮

**Q1：PFS 和慢查询日志怎么选？**
两者互补。慢日志用于「事后取证」（完整 SQL 原文、时间点、执行用户，可离线分析）；PFS 用于「在线诊断与聚合排名」（总耗时、等待事件、锁等待、IO 分布）。生产的标准做法：**慢日志常开（阈值可设 0.5s）+ PFS 默认开启 + sys 视图做日常巡检**。

**Q2：PFS 里时间单位是什么？**
皮秒（1e-12 秒）。字段后缀 `_TIMER_WAIT` 都是皮秒；`_TIME` / `_LATENCY` 在 `sys` 视图里已被格式化为人类可读。

**Q3：为什么开了 PFS 还是查不到等待事件的历史？**
`events_waits_*` 的 history consumer 默认关闭，只有 `_current` 表有数据。需要 `UPDATE setup_consumers SET ENABLED='YES'`。

**Q4：怎么找「建了但没用过」的索引？**
`performance_schema.table_io_waits_summary_by_index_usage` 中 `COUNT_STAR=0` 的二级索引（排除唯一索引与外键索引），或用 `sys.schema_unused_indexes`。

**Q5：`SUM_ROWS_EXAMINED / SUM_ROWS_SENT` 这个比值有什么用？**
衡量索引精准度。比值接近 1 说明索引定位精准；比值成百上千说明扫了大量行只返回少量数据，考虑加更合适的联合索引或覆盖索引。

**Q6：PFS 对性能影响多大？**
默认配置约 5%~10%。可通过 `setup_instruments` 精细控制采集面降低开销。排查完成后关闭临时开启的 instrument。

---

## 八、总结

- **PFS 三大概念**：instrument（采什么）→ consumer（存到哪）→ 内存表（怎么查），三层都要开才有数据
- **最重要的一张表**：`events_statements_summary_by_digest`，按 digest 聚合，用 `SUM_TIMER_WAIT` 找总耗时黑洞
- **时间单位是皮秒**，`/1e12` 得秒、`/1e9` 得毫秒
- **等待事件排行榜**是定位「CPU 不高但慢」的第一入口：IO、MDL、锁、网络
- **索引治理**用 `table_io_waits_summary_by_index_usage` + `sys.schema_unused_indexes`
- **锁排查**用 `data_lock_waits` + `sys.innodb_lock_waits`（MySQL 8.0）
- **生产建议**：默认开启 + 精细控制 instrument + 限制查询范围 + 长期趋势交给 Prometheus

从「看慢日志」升级到「用 PFS 做全量画像」，是数据库运维能力的一次质变。
