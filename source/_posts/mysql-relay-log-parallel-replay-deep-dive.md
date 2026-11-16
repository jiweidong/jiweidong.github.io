---
title: 【MySQL 底层】中继日志与并行回放深度解析：MTS、WRITESET 与复制延迟治理
date: 2026-11-16 08:10:00
tags:
  - Java
  - MySQL
  - 复制
  - 主从延迟
  - MTS
  - relay log
categories:
  - 数据库
author: 东哥
---

# 【MySQL 底层】中继日志与并行回放深度解析

## 一、前言

主从延迟是 Java 后端最熟悉的故障之一：下单成功、立刻查订单查不到；缓存刚删、从库又读回旧值。大多数人第一反应是「加 `replica_parallel_workers`」，但调完发现延迟没降，甚至更严重——因为没搞清**并行回放的边界在哪**。

`replica_parallel_workers=8` 不等于 8 倍吞吐。能不能并行，取决于主库写 binlog 时有没有把「事务之间的依赖关系」标出来；从库只是按标记执行。而 relay log 的落盘、coordinator 的分发、worker 的提交顺序，又各自有独立的瓶颈。

本文按「主库怎么标 → 从库怎么落 → coordinator 怎么分 → worker 怎么放」这条链路拆开讲，最后给出延迟归因方法与 Java 侧治理代码。

<!-- more -->

## 二、复制链路全景

```
主库
  ├─ 事务提交 → binlog（含 last_committed / sequence_number）
  └─ dump thread ──网络──▶ 从库
                              ├─ IO thread：写 relay log（顺序追加，几乎不耗时）
                              ├─ coordinator：读 relay log，按依赖关系分发
                              └─ worker × N：并行 apply，最后按序提交
```

### 2.1 relay log 是什么

relay log 与 binlog **格式完全相同**，只是「来源不同」。主库的 binlog 事件被 IO 线程原样写入 relay log，文件名 `relay-bin.000001`，配套 `relay-bin.index`。

它的作用是把「网络传输」和「SQL 回放」解耦：网络抖动时 IO 线程可以先攒一段，回放线程按自己的节奏消费。所以 `Seconds_Behind_Source` 的本质是 **relay log 里还有多少没消费**。

### 2.2 三个位点

```sql
SHOW REPLICA STATUS\G
-- Retrieved_Gtid_Set: 3e11...:1-98123     IO 线程已拉到
-- Executed_Gtid_Set:  3e11...:1-97800     SQL 线程已回放
-- Relay_Log_File: relay-bin.000042
-- Relay_Log_Pos: 8123456
-- Exec_Source_Log_Pos: 7999999
-- Auto_Position: 1
```

- `Retrieved - Executed` 的差集 = **待回放事务数**，比 `Seconds_Behind_Source` 可靠得多；
- `Seconds_Behind_Source` 只看「最后回放事件的时间戳」，大事务回放时它会长时间显示 0（因为还没回放到新事件），然后突然跳到几千秒；
- GTID 模式下必须比对 GTID 集合，不要看 `Read_Master_Log_Pos` 这类文件位点。

### 2.3 崩溃安全：relay log info 去哪了

MySQL 8.0 起，复制元数据默认存** InnoDB 表** `mysql.slave_relay_log_info`（`slave` 在新版本已改名为 `replica`，旧表名做兼容视图），不再依赖 `relay-log.info` 文件。

这带来两件事：

1. relay log 位点与事务提交在**同一个事务**里更新，崩溃后不会出现「事务已提交但位点没推进」的重复回放；
2. `relay_log_recovery=ON` 时，从库启动会**丢弃所有未回放的 relay log**，重新从主库按 GTID 拉取。所以 relay log 不是备份，别指望它做点对点恢复。

## 三、并行回放的原理：依赖标记

### 3.1 last_committed 与 sequence_number

MySQL 5.7 引入的逻辑时钟方案：每个事务在 binlog 里带两个数字。

| 字段 | 含义 |
|---|---|
| `sequence_number` | 事务在 binlog 中的单调递增编号 |
| `last_committed` | 该事务开始前，最后一个已提交事务的 `sequence_number` |

规则：**`last_committed` 相同的事务可以并行**，因为它们在主库上就是「同时处于执行中、互不冲突」的。

```
trx A: sequence=100, last_committed=98
trx B: sequence=101, last_committed=98   ← 与 A 同组，可并行
trx C: sequence=102, last_committed=100  ← 必须等 A 提交后才能开始
```

从库的 coordinator 维护一个「当前可并行的最大序号」，把 `last_committed <= 已分发最大序号` 的事务丢进 worker 队列。这就是 `LOGICAL_CLOCK`。

### 3.2 组提交是并行的前提

主库的组提交（binlog group commit）会把同一批 flush 的事务标成同一个 `last_committed`。所以**主库并发越高、组提交越有效，从库越容易并行**。

反过来，如果主库是单线程压测（`sysbench --threads=1`），所有事务 `last_committed` 串成一条链，从库给 16 个 worker 也只能串行回放。这是「压测环境怎么调都快、生产怎么调都慢」的常见原因。

### 3.3 WRITESET：按行冲突检测

`LOGICAL_CLOCK` 只看提交时序，粒度粗。MySQL 5.7.22 引入 `WRITESET`：对事务修改的每一行算一个 hash（库名+表名+主键/唯一键），写入 binlog 的 `transaction_write_set`。

coordinator 用「已分发事务写过的行 hash 集合」做冲突检测：**没有行冲突就并行**，比 `last_committed` 精确得多。

```sql
-- 查看当前依赖跟踪模式
SHOW VARIABLES LIKE 'binlog_transaction_dependency_tracking';
-- COMMIT_ORDER | WRITESET | WRITESET_SESSION

SHOW VARIABLES LIKE 'transaction_write_set_extraction';
-- XXHASH64（默认）
```

三种模式对比：

| 模式 | 依据 | 并行度 | 额外开销 | 适用 |
|---|---|---|---|---|
| `COMMIT_ORDER` | 组提交顺序 | 低 | 无 | 兼容旧版本 |
| `WRITESET` | 行级 hash 冲突 | 高 | 主库算 hash（约 3~8% CPU） | 大多数 OLTP |
| `WRITESET_SESSION` | 行 hash + 同会话串行 | 中高 | 同上 | 有会话内顺序依赖时 |

`WRITESET` 的两个坑：

1. **无主键表**退化为表级 hash，几乎无法并行；
2. 大事务（一次改 10 万行）会生成巨大的 write set，增加 binlog 体积与内存开销。`binlog_row_image=MINIMAL` 也救不了，因为主键仍要算。

### 3.4 提交顺序：replica_preserve_commit_order

并行 apply 之后，从库的**提交顺序可能与主库不同**。如果从库还要继续做级联复制、或者有依赖 binlog 的 CDC，顺序错乱会出事。

```sql
replica_preserve_commit_order = ON   -- 8.0 默认 ON（开启 MTS 时）
```

开启后 worker 提交要等「前面所有事务都提交」，会损失一点吞吐，但保证 binlog 顺序一致。**级联复制场景不要关。**

## 四、参数配置与容量估算

```ini
[mysqld]
replica_parallel_workers = 8
replica_parallel_type = LOGICAL_CLOCK
replica_preserve_commit_order = ON
replica_pending_jobs_size_max = 256M   # 单 worker 队列上限，大事务要调
slave_rows_search_algorithms = INDEX_SCAN,HASH_SCAN
```

### 4.1 worker 数量怎么定

经验公式：

```
workers ≈ min(主库写入并发度, 从库可用核数 × 0.75, 8~16)
```

- 从库还要承担读流量，worker 抢 CPU 会拖慢查询；
- `WRITESET` 下超过 16 个 worker 收益递减，因为 coordinator 的冲突检测是单线程；
- 云上小规格（4C）从库给 4 个 worker 就够，给 16 个只会加剧上下文切换。

### 4.2 内存账

每个 worker 有自己的：
- `replica_pending_jobs_size_max` 上限的队列（默认 128M，8 个 worker 最坏 1GB）；
- binlog cache / 事务缓存；
- InnoDB 的 undo/redo 开销。

所以「加 worker」在内存紧张的实例上会直接触发 swap 或 OOM。8C16G 的从库，8 worker + 256M 队列已经是上限。

## 五、延迟归因：五类瓶颈

| 类型 | 特征 | 判断方法 | 处理 |
|---|---|---|---|
| IO 线程慢 | `Retrieved` 不前进 | 网络 RTT、主库 binlog dump 阻塞 | 加带宽、开压缩 `replica_compressed_protocol` |
| coordinator 慢 | relay log 堆积但 worker 空闲 | `performance_schema.replication_applier_status_by_coordinator` | 检查大事务、write set 膨胀 |
| worker 不足 | worker 全忙、`last_committed` 分组小 | `replication_applier_status_by_worker` | 提高主库并发、开 WRITESET |
| 单事务过大 | 一个 worker 长时间 BUSY | `SHOW PROCESSLIST` 看 `Waiting for ...` | 拆大事务、分批 DML |
| 从库资源争抢 | apply 与查询抢锁/IO | `iostat`、`innodb_row_lock_waits` | 读写分离、降读流量、独立盘 |

### 5.1 用 performance_schema 精确观测

```sql
-- 每个 worker 正在干什么
SELECT WORKER_ID, SERVICE_STATE, LAST_ERROR_MESSAGE,
       APPLYING_TRANSACTION, APPLYING_TRANSACTION_ORIGINAL_COMMIT_TIMESTAMP
FROM performance_schema.replication_applier_status_by_worker;

--  coordinator 视角：队列里堆了多少
SELECT * FROM performance_schema.replication_applier_status_by_coordinator\G
```

`APPLYING_TRANSACTION_ORIGINAL_COMMIT_TIMESTAMP` 与当前时间差，就是**该 worker 卡了多久**，比全局 `Seconds_Behind_Source` 精确到事务级。

### 5.2 一个真实的「越加 worker 越慢」

某业务从库 8C32G，延迟 30 分钟。运维把 `replica_parallel_workers` 从 4 调到 16，延迟涨到 50 分钟。

排查发现：

1. 主库写入是**单线程定时任务**批量更新，所有事务 `last_committed` 相同（都在一个大组里）——理论上能并行；
2. 但事务都是「按主键区间更新 5 万行」，`WRITESET` 下每个事务的 write set 有 5 万个 hash，coordinator 做冲突检测的 CPU 直接打满；
3. worker 增多后，每个 worker 拿到的都是大事务，undo 膨胀、redo 刷盘竞争、`purge` 跟不上，`History list length` 涨到 200 万。

真正的解法不是加 worker，而是：把定时任务拆成 1000 行一批、开 `WRITESET`、从库 `innodb_flush_log_at_trx_commit=2`（可容忍崩溃丢 1 秒）、`sync_binlog=0`（从库不写 binlog 时）。延迟回到 20 秒内。

## 六、Java 侧治理

### 6.1 延迟感知的读写路由

不要在从库延迟时还把读流量打过去。用 GTID 差集做判断，比 `Seconds_Behind_Source` 准确：

```java
public class ReplicaLagMonitor {

    private final DataSource replicaDs;
    private volatile long lagTxCount = Long.MAX_VALUE;
    private volatile long lastCheck = 0;

    public boolean isHealthy(long maxLagTx) {
        refreshIfNeeded();
        return lagTxCount <= maxLagTx;
    }

    private void refreshIfNeeded() {
        if (System.currentTimeMillis() - lastCheck < 1000) return;
        try (Connection c = replicaDs.getConnection();
             Statement st = c.createStatement();
             ResultSet rs = st.executeQuery("SHOW REPLICA STATUS")) {
            if (rs.next()) {
                String retrieved = rs.getString("Retrieved_Gtid_Set");
                String executed = rs.getString("Executed_Gtid_Set");
                lagTxCount = GtidSet.diffCount(retrieved, executed); // 自行实现集合差
                lastCheck = System.currentTimeMillis();
            }
        } catch (SQLException e) {
            lagTxCount = Long.MAX_VALUE;   // 查不到就当不健康，fail-safe
        }
    }
}
```

路由层用 Spring 的 `AbstractRoutingDataSource`：

```java
public class LagAwareRoutingDataSource extends AbstractRoutingDataSource {
    private final ReplicaLagMonitor monitor;

    @Override
    protected Object determineCurrentLookupKey() {
        boolean forceMaster = ReadAfterWriteContext.inWriteWindow();
        return (forceMaster || !monitor.isHealthy(1000)) ? "master" : "replica";
    }
}
```

`ReadAfterWriteContext` 解决「写后立即读」：写入成功后 500ms 内的读强制走主库。这是业务侧最便宜的一致性补丁。

### 6.2 大事务拆分

延迟的头号杀手是大事务。Java 侧批量更新要分片：

```java
public void batchUpdate(List<Order> orders) {
    final int BATCH = 500;
    for (int i = 0; i < orders.size(); i += BATCH) {
        List<Order> slice = orders.subList(i, Math.min(i + BATCH, orders.size()));
        transactionTemplate.executeWithoutResult(status -> {
            for (Order o : slice) orderMapper.updateById(o);
        });
        // 批间让出，避免长时间持有行锁并给复制留出并行空间
        LockSupport.parkNanos(Duration.ofMillis(20).toNanos());
    }
}
```

注意：拆事务会牺牲原子性。要么业务上可接受「部分成功 + 补偿」，要么用状态机 + 幂等重试，不要为了复制性能偷偷破坏一致性。

### 6.3 监控指标

必须打出来的几个：

| 指标 | 来源 | 告警阈值 |
|---|---|---|
| `retrieved-executed` 事务差 | `SHOW REPLICA STATUS` | > 5000 持续 1min |
| 单 worker 卡顿时长 | `replication_applier_status_by_worker` | > 60s |
| `Relay_Log_Space` | `SHOW REPLICA STATUS` | > 10GB |
| `History list length` | `SHOW ENGINE INNODB STATUS` | > 100 万 |
| `replica_pending_jobs_size_max` 触顶 | `performance_schema` | 出现即告警 |

## 七、面试高频追问

**Q1：`Seconds_Behind_Source` 为什么不准？**
它等于「当前时间 - 正在回放事件的原始时间戳」。大事务回放期间时间戳不前进，指标显示 0；网络断了 IO 线程停了，它也会停在旧值。要用 `Retrieved_Gtid_Set` 与 `Executed_Gtid_Set` 的差集。

**Q2：MTS 一定能降低延迟吗？**
不一定。并行度受主库事务依赖关系限制：单线程写入、大事务、无主键表都会让并行退化。而且 coordinator 是单线程，冲突检测本身可能成为瓶颈。

**Q3：`LOGICAL_CLOCK` 和 `WRITESET` 区别？**
前者按提交时序分组（`last_committed` 相同即可并行），后者按行级 hash 做冲突检测，粒度更细、并行度更高，代价是主库算 hash 与 binlog 体积增加。

**Q4：从库崩溃后 relay log 会重放吗？**
`relay_log_recovery=ON` 会丢弃未回放的 relay log，按 GTID 重新从主库拉。位点信息存在 InnoDB 表里，与事务提交原子，所以不会重复回放已提交事务。

**Q5：为什么从库要开 `replica_preserve_commit_order`？**
并行 apply 会打乱提交顺序，级联复制和 CDC 依赖 binlog 顺序。开了之后 worker 要等前序事务提交，牺牲少量吞吐换顺序一致。

**Q6：`slave_rows_search_algorithms` 有什么用？**
worker 回放行事件时要先在从库定位行。没有主键或二级索引时，默认全表扫描，单行更新可能扫几百万行。`INDEX_SCAN,HASH_SCAN` 让它在内存里建 hash 定位，能救「无索引表」的延迟，但治标不治本——加主键才是正解。

## 八、小结

1. relay log 只是缓冲，延迟的本质是「消费速度 < 生产速度」。
2. 并行回放的前提是主库把依赖关系标出来：组提交质量 + `WRITESET` 决定上限。
3. `replica_parallel_workers` 不是越大越好，coordinator 单线程、内存队列、undo 膨胀都会反噬。
4. 归因要用 `Retrieved/Executed` GTID 差集 + `replication_applier_status_by_worker`，不要只看 `Seconds_Behind_Source`。
5. Java 侧最有效的三件事：延迟感知路由、写后读走主、大事务拆分。
6. 无主键表是复制延迟的隐形炸弹，建表规范比任何参数都重要。

复制不是「配好就忘」的基础设施。把依赖标记、并行边界、提交顺序三件事想清楚，延迟才能从「玄学调参」变成「可算的容量问题」。
