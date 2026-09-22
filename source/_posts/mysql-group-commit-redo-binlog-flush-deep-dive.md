---
title: 【MySQL 底层】组提交（Group Commit）深度解析：redo/binlog 刷盘与两阶段提交的性能取舍
date: 2026-09-22 08:00:00
tags:
  - MySQL
  - InnoDB
  - 事务
  - 组提交
  - 面试
categories:
  - MySQL
  - 数据库底层
author: 东哥
---

# 【MySQL 底层】组提交（Group Commit）深度解析：redo/binlog 刷盘与两阶段提交的性能取舍

## 面试官：每次事务提交都要 fsync 两次，MySQL 为什么还能跑到几万 TPS？

这个问题几乎是我面试 MySQL 方向必问的一道。候选人一般能答出"有 WAL，先写日志再写数据"，但当我追问下面三个问题时，能答清楚的就不多了：

1. 一次提交到底要落几次盘？分别落的是什么？
2. 如果是"每提交一次就 fsync 一次"，那 QPS 上限就是磁盘 IOPS 上限，几千都到不了，为什么实际能到几万？
3. redo log 和 binlog 是两份日志，怎么保证它们的一致性？

答案的核心是 **两阶段提交（2PC）** 加 **组提交（Group Commit）**。前者解决"两份日志不能写一半"，后者解决"每次提交都 fsync 太慢"。这两件事经常被混在一起讲，其实它们解决的问题完全不同，下面拆开说。

---

## 一、先看清楚一次提交要落几次盘

假设 `innodb_flush_log_at_trx_commit=1`、`sync_binlog=1`（双 1 配置，最常用也最安全的配置），一次普通的事务提交，理想化流程如下：

```
客户端 COMMIT
   │
   ├─ 1. InnoDB 写入 redo log（prepare 状态），并 fsync     ← 第一次落盘
   │
   ├─ 2. 写入 binlog，并 fsync                              ← 第二次落盘
   │
   └─ 3. InnoDB 写入 commit 标记，事务完成                   ← 不再强制 fsync
```

粗算一下：每次提交 2 次 fsync，如果磁盘单次 fsync 耗时 1ms（普通 SSD），那单连接下 TPS 上限只有 500 左右；就算是 NVMe，5 万 IOPS 也只能撑到 2.5 万 TPS，而且随并发上升会断崖式下降。

可是现实中的 MySQL 跑到了几万 TPS。**差距就来自"组提交"：把多个并发事务的 fsync 合并成一次。**

---

## 二、两阶段提交：为什么必须以 prepare → binlog → commit 的顺序

先说清楚"为什么需要两份日志"。

- **redo log** 是 InnoDB 存储引擎层的，负责崩溃后的数据恢复；
- **binlog** 是 MySQL Server 层的，负责主从复制与基于时间点的恢复。

两份日志各自独立，如果没有任何协调，故障时会不一致：

| 场景 | redo 已写 | binlog 已写 | 后果 |
|---|---|---|---|
| A | 是 | 否 | 主库认为提交成功，从库却收不到 → 主从不一致 |
| B | 否 | 是 | 从库重放了变更，主库却没有 → 主从不一致 |

所以必须让"两份日志同时生效或同时不生效"，这就是 2PC：

```
阶段一：Prepare
   InnoDB 写 redo log，标记为 prepare 状态（含事务 XID）

阶段二：提交
   ① 写 binlog（含事务 XID），fsync
   ② InnoDB 把 redo 里的 prepare 改成 commit，事务正式结束
```

**恢复时的一致性判断规则**（这是 DBA 面试的高频点）：

- redo 中事务处于 **prepare** 状态：
  - binlog 里**有**对应 XID 的完整记录 → **提交**该事务；
  - binlog 里**没有**该 XID → **回滚**该事务。
- redo 中已经是 commit 状态 → 无所谓 binlog，直接确认提交。

这个规则把"两份日志谁对谁错"的仲裁权交给了 binlog：**binlog 是最终裁判**。因为 binlog 在从库复制链路中是权威的，主库必须以 binlog 是否完整来决定归档。

---

## 三、组提交：三个阶段与合并 fsync

组提交（Group Commit）的思路是：**不要求每个事务都独立刷盘，而是让一批事务排队，把落盘动作合并成一次。**

MySQL 5.6 之后，组提交被清晰地拆成三个阶段，每个阶段都有一个独立的队列：

```
        事务提交队列
             │
   ┌─────────▼─────────┐
   │  Stage 1: Flush   │  把各个事务的 binlog 从 cache 写到文件（不 fsync）
   └─────────┬─────────┘
   ┌─────────▼─────────┐
   │  Stage 2: Sync    │  对文件做一次 fsync（一次调用覆盖一批事务）★关键
   └─────────┬─────────┘
   ┌─────────▼─────────┐
   │  Stage 3: Commit  │  InnoDB 引擎层提交（把 redo prepare 改成 commit）
   └───────────────────┘
```

### 3.1 为什么分三个阶段就能合并

关键在于**让事务在队列里"等一等"**。当一批事务进入 Flush 阶段时：

1. 领队线程（leader）负责把队列中所有事务的 binlog 一次性写出并 fsync；
2. 其余线程（follower）等到 leader 完成 sync 后一起进入 Commit 阶段；
3. 这样，**N 个事务只用了 1 次 fsync**，而不是 N 次。

并发越高，排队积起来的事务越多，合并收益越大——这也是为什么组提交在**高并发**下效果特别明显，而单连接压测时几乎看不到收益。

### 3.2 redo 那一侧呢

InnoDB 的 redo 本身也有类似的组提交机制（`innodb_flush_log_at_trx_commit` 相关）。当设置为 1 时，I/O 线程会把多个事务的 redo 刷新请求合并，用一次 fsync 覆盖；设置 2 时，事务提交只把 redo 写到 OS page cache，由 OS 决定何时真正落盘（性能好，但崩溃时可能丢最近 1 秒的提交）。

两种日志的组提交是**协同**工作的：真正让整个过程变快的，是**两边的 fsync 都被合批了**。

---

## 四、可控的"等一等"：让组提交合并更多事务

既然组提交的本质是"让事务多等一会儿，攒成更大的批"，MySQL 就提供了参数让你主动控制这个"等"，用来在**延迟**和**吞吐**之间做权衡：

```ini
[mysqld]
# binlog 组提交延迟：leader 在 fsync 前主动等待的时间（微秒），默认 0
binlog_group_commit_sync_delay = 0

# 攒够多少个事务就立即 fsync，不再等满延迟时间，默认 0（不限制）
binlog_group_commit_sync_no_delay_count = 0

# 是否保证组内事务的 binlog 顺序与提交顺序一致（默认 ON）
binlog_order_commits = ON
```

### 4.1 怎么理解这两个参数

- `binlog_group_commit_sync_delay = N`（单位 **微秒**）：leader 会最多等 N 微秒再 fsync。等的时间越长，能攒进同一批的事务越多，吞吐越高，但**每个事务的提交延迟最多增加 N 微秒**。
- `binlog_group_commit_sync_no_delay_count = M`：即使延迟时间没到，只要已经攒够 M 个事务就立刻 fsync。这是给延迟设的"上限兜底"，避免低峰期少量事务白等。

### 4.2 一个实际调优的例子

某订单库写压力大，单实例峰值 TPS 3 万，`sync_binlog=1`，P99 提交延迟约 2ms。

```sql
-- 调优前
SET GLOBAL binlog_group_commit_sync_delay = 0;
SET GLOBAL binlog_group_commit_sync_no_delay_count = 0;
```

调整为：

```sql
SET GLOBAL binlog_group_commit_sync_delay = 1000;        -- 最多等 1ms
SET GLOBAL binlog_group_commit_sync_no_delay_count = 100; -- 攒够 100 个立即刷
```

效果：fsync 次数大幅下降，TPS 上升约 30%~50%，P99 提交延迟从 2ms 提到约 3ms 左右。**账要算清楚：用 1ms 的延迟换吞吐，业务能接受就做。**

注意 `sync_binlog` 的值也直接影响这个策略：

- `sync_binlog = 1`：每次（每组）提交都 fsync，安全性最高；
- `sync_binlog = 0`：交给 OS 刷，最不安全（崩溃丢 binlog）；
- `sync_binlog = N`：每 N 次提交 fsync 一次（实践中基本不用，除非明确知道可丢）。

**组提交是在 `sync_binlog=1` 前提下提高吞吐的核心手段**；而降低 `sync_binlog` 是牺牲安全换性能，两者的取舍哲学完全不同，面试时一定要区分开。

---

## 五、验证：怎么看到组提交在生效

### 5.1 观察 binlog 组提交统计

```sql
-- binlog 组提交相关状态（8.0 提供）
SHOW GLOBAL STATUS LIKE 'Binlog_%';
```

比较有用的几个：

| 状态变量 | 含义 |
|---|---|
| `Binlog_commits` | 提交次数 |
| `Binlog_group_commits` | 组提交的批次数 |
| `Binlog_group_commit_trigger_count` | 因攒够 no_delay_count 触发 |
| `Binlog_group_commit_trigger_timeout` | 因延迟超时触发 |
| `Binlog_group_commit_trigger_lock_wait` | 因锁等待触发 |

**判断依据**：如果 `Binlog_commits` 远大于 `Binlog_group_commits`，说明组提交合并效果明显（平均每批合并了多个事务）。

```sql
-- 计算平均每批合并的事务数
SELECT
  VARIABLE_VALUE AS commits FROM performance_schema.global_status
   WHERE VARIABLE_NAME='Binlog_commits';
```

### 5.2 用 performance_schema 看落盘等待

```sql
-- 看事务提交相关等待
SELECT EVENT_NAME, COUNT_STAR, AVG_TIMER_WAIT/1e9 AS avg_us
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE EVENT_NAME LIKE '%sync%' OR EVENT_NAME LIKE '%binlog%'
ORDER BY COUNT_STAR DESC LIMIT 10;
```

### 5.3 看 redo 的刷盘压力

```sql
SHOW GLOBAL STATUS LIKE 'Innodb_log_waits';        -- 等待 redo 空间释放
SHOW GLOBAL STATUS LIKE 'Innodb_os_log_%';         -- redo 的物理 I/O 次数
```

`Innodb_os_log_fsyncs` 的增长速度，能直接反映 redo 侧 fsync 的真实频率。

---

## 六、几个容易踩的坑

### 6.1 组提交不保证 binlog 与提交顺序一致？其实默认是保证的

`binlog_order_commits=ON` 时，引擎层的提交顺序与 binlog 写入顺序一致，这让**并行复制**（从库按组并行回放）更容易判断事务依赖。关掉它可以减少锁竞争，但会破坏顺序性，通常不建议。

### 6.2 主从延迟与组提交的关系

组提交让主库的 binlog 里可能出现"大批同组事务"。从库的并行复制（`slave_parallel_type=LOGICAL_CLOCK`）正是利用 binlog 中的 `last_committed` / `sequence_number` 信息来判断哪些事务可以并行回放。**主库组提交合得越好，从库并行度越高，主从延迟越低**——这是面试里一个很漂亮的加分点。

### 6.3 组提交带来的延迟抖动

`binlog_group_commit_sync_delay` 会让低峰期的事务无谓多等。经验做法是配合 `no_delay_count`，或在高并发时段才动态调大：

```sql
-- 大促期间临时提高合并度
SET GLOBAL binlog_group_commit_sync_delay = 2000;
SET GLOBAL binlog_group_commit_sync_no_delay_count = 200;

-- 大促结束恢复
SET GLOBAL binlog_group_commit_sync_delay = 0;
SET GLOBAL binlog_group_commit_sync_no_delay_count = 0;
```

### 6.4 只改 `sync_binlog` 是危险的

有人为了提吞吐把 `sync_binlog=0`，结果崩溃后 binlog 缺失，主从直接不一致。**优先用组提交来提性能，而不是降低持久化等级。**

---

## 七、面试常见追问

**Q1：组提交会不会导致事务提交后还没落盘，别的事务就读到了？**

不会。组提交只做"批量化 fsync"，事务的可见性由锁和 MVCC 控制，与落盘时机无关。提交后的可见性与其他事务读到的新旧版本，是两套机制。

**Q2：`innodb_flush_log_at_trx_commit=1` 和 `sync_binlog=1`，能不能只靠组提交保证一致？**

组提交是性能手段，不负责一致性。一致性由 2PC 的 prepare/binlog/commit 顺序保证。两者缺一不可：没有 2PC 会主从不一致，没有组提交会慢到不可用。

**Q3：为什么 binlog group commit 的 leader 必须串行？**

因为 fsync 本身是串行资源，leader 负责本组的 fsync，follower 只等待。如果让每个事务各自 fsync，那就退化成最初的方案了。串行化 leader 恰恰是合并的前提。

**Q4：从库上的组提交？**

从库回放时也涉及提交和刷盘，组提交机制同样生效。另外，如果从库开启了并行复制，多个 worker 线程的提交也可以被组提交合并。

**Q5：如何判断当前实例是否"卡在 fsync"？**

用 `performance_schema` 的等待事件看 `wait/io/file/innodb/innodb_log_file` 和 binlog 文件相关的等待；再用 `iostat -x 1` 看 `fdatasync`/`fsync` 的 `await`。如果单次 fsync 耗时飙到毫秒级以上，说明存储已经是瓶颈。

---

## 八、总结

- **2PC** 解决 redo 与 binlog 的原子性：prepare → binlog → commit，恢复时以 binlog 是否含 XID 为准。
- **组提交** 解决"每次提交都要 fsync"的性能问题：三个阶段 Flush / Sync / Commit，把一批事务的 fsync 合并成一次。
- **调优手段**：`binlog_group_commit_sync_delay` + `binlog_group_commit_sync_no_delay_count`，用可控延迟换吞吐；**不要**通过降低 `sync_binlog` 来换性能。
- **验证手段**：`Binlog_commits` vs `Binlog_group_commits` 的比值、`Innodb_os_log_fsyncs` 的增速、`performance_schema` 的等待事件。
- **连带收益**：组提交生成的 binlog 顺序信息，是主库 → 从库并行复制的关键输入，直接影响主从延迟。

一句话记住：**2PC 保证"不写半截"，组提交保证"别写那么多次"。**
