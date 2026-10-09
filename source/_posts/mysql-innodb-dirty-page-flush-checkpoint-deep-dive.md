---
title: 【MySQL 底层】InnoDB 脏页刷盘与 Checkpoint 深度解析：LSN、模糊检查点与 Adaptive Flushing
date: 2026-10-09 08:05:00
tags:
  - Java
  - MySQL
  - InnoDB
  - 数据库
  - 面试
categories:
  - Java
  - MySQL
author: 东哥
---

# 【MySQL 底层】InnoDB 脏页刷盘与 Checkpoint 深度解析：LSN、模糊检查点与 Adaptive Flushing

## 面试官：你说 redo log 保证崩溃恢复，那 redo log 是不是可以无限写？

不会。如果 redo log 能无限写下去，那崩溃恢复时要重放的日志量就是无止境的，恢复时间不可控。

面试官接着问：**那当 redo log 写满的时候会发生什么？脏页是怎么被刷盘的？为什么有时候会突然出现"数据库抖动"，所有更新都卡住？**

答案就落在两个词上：**Checkpoint（检查点）** 和 **脏页刷盘（Flushing）**。这篇文章把 LSN、Checkpoint、Adaptive Flushing、刷脏线程、Doublewrite 的关系一次讲清楚。

## 一、先建立坐标系：LSN 是一切的基础

InnoDB 里所有关于"进度"的话题都围绕 **LSN（Log Sequence Number）**，它是一个**全局单调递增**的 `uint64`，单位是字节。

- 每产生一条 redo 记录，`log_sys->lsn` 就往前推进 `len` 字节。
- redo 文件是**环形**的（`innodb_log_files_in_group` 个文件，总大小 `innodb_log_file_size × 个数`）。
- 页上记录 `FIL_PAGE_LSN`，表示"这页最后一次被修改对应的 LSN"。

关键变量（`log_sys` 中）：

| 变量 | 含义 |
| --- | --- |
| `lsn` | 当前日志写入位置（下一个待写入的偏移） |
| `flushed_to_disk_lsn` | 已经 fsync 到磁盘的日志 LSN |
| `write_lsn` | 已写入 OS page cache 的 LSN |
| `checkpoint_lsn` | 可以被覆盖的日志起点（= 最老的脏页对应的 LSN） |

再看几个常量：

- `innodb_log_file_size`：单个 redo 文件大小。
- **`log_capacity = innodb_log_file_size × innodb_log_files_in_group`**：环形日志总容量。
- `innodb_log_files_in_group`：文件个数（8.0.30+ 之后参数被 `innodb_redo_log_capacity` 取代，自动管理 32 个文件）。

一个核心公式：

```
还能写入的日志空间 = checkpoint_lsn + log_capacity - lsn
```

当剩余空间不足时，**InnoDB 必须推进 checkpoint，而推进 checkpoint 就必须把对应的脏页刷盘**。

## 二、为什么必须有 Checkpoint

redo log 恢复时，InnoDB 只需要重放 `checkpoint_lsn` 之后的日志。所以：

- **checkpoint_lsn 越大，崩溃恢复越快**（要重放的日志越少）。
- **checkpoint_lsn 越小（越老），可复用的日志空间越大**。

这就是矛盾所在：想快速恢复就要勤刷脏页，想减少刷脏就要留着旧日志。

`checkpoint_lsn` 的定义是：**所有脏页中 Page 上 `FIL_PAGE_LSN` 的最小值**。因为比它更老的日志所对应的修改都已经落盘，这些日志就可以被覆盖了。

所以「**推进 checkpoint = 把最老的脏页刷下去 = 释放 redo 空间**」这三件事是同一件事。

## 三、脏页从哪来，又该什么时候刷

脏页（dirty page）指**在 Buffer Pool 中被修改、但还没写回磁盘的页**。

写入路径：

```
UPDATE → 找到页在 Buffer Pool → 修改页内存 → 写 redo（WAL）→ 页变脏
                                              ↑
                                    注意：此时并不写数据文件
```

于是就有了"页比日志慢"的架构：**日志先行（Write-Ahead Logging）**。刷脏页是异步的、批量的事情。

刷脏页的时机主要有：

| 触发方式 | 说明 |
| --- | --- |
| **redo 空间不足** | checkpoint 推进，最紧急，会"卡住"用户线程 |
| **Buffer Pool 不足** | 需要腾出新页，淘汰时若淘汰脏页必须先刷 |
| **LRU 老化** | 从 LRU 老年代淘汰脏页 |
| **异步刷脏线程** | 后台 page cleaner 持续工作 |
| **正常 shutdown** | `innodb_fast_shutdown=0` 会刷完所有脏页 |

## 四、Checkpoint 的两种触发：Sharp 与 Fuzzy

### 4.1 Sharp Checkpoint（锐检查点）

关闭数据库时，把所有脏页全部刷盘，`checkpoint_lsn` 直接推到 `lsn`。代价是大，好处是启动时几乎不需要恢复。对应 `innodb_fast_shutdown=0`。

### 4.2 Fuzzy Checkpoint（模糊检查点）

运行时用的都是 Fuzzy Checkpoint：**不要求所有脏页一次刷完，只推进到"某个安全水位"**。InnoDB 把它拆成几种：

| 类型 | 触发条件 | 特点 |
| --- | --- | --- |
| Sharp | 正常关闭 | 全量刷 |
| Fuzzy | 后台持续 | 按 LSN 分区间逐步推进 |
| Async / Sync | 特定水位 | 异步刷一部分、同步刷一部分 |

InnoDB 内部用 `log_free_check()` 来判定是否需要等待：

```c
// 简化逻辑
void log_free_check() {
    if (log_sys->checkpoint_lsn + LOG_CHECKPOINT_FREE_SPACE >= log_sys->lsn) {
        // 剩余可写空间充足，直接返回
        return;
    }
    // 空间不足，必须由刷脏线程推进 checkpoint
    buf_flush_wait_flushed(log_sys->lsn);   // 用户线程在此等待！
}
```

`buf_flush_wait_flushed` 就是**"抖动"的直接来源**：用户线程在写 redo 时必须等待刷脏推进，表现出来就是 SQL 突然变慢、TPS 断崖。

## 五、刷脏线程：Page Cleaner

MySQL 5.7 把刷脏职责统一收敛到 **page cleaner 线程**（`innodb_page_cleaners`，默认 = `innodb_buffer_pool_instances`，8.0 下可由 `innodb_page_cleaners` 调整）。

它做两件事：

1. **刷新 LRU 列表**（flush LRU list）：按 LRU 顺序找脏页。
2. **刷新脏页列表**（flush flush list）：flush list 是按 `oldest_modification`（最早修改 LSN）排序的脏页链表。

刷脏的"总量目标"由 `innodb_io_capacity` 与 `innodb_io_capacity_max` 控制：

| 参数 | 含义 | 建议 |
| --- | --- | --- |
| `innodb_io_capacity` | 后台刷脏的 IO 基准速率（IOPS） | SSD 建议 2000~4000，NVMe 可上万 |
| `innodb_io_capacity_max` | 压力大时所用上限 | 一般为 io_capacity 的 2 倍 |
| `innodb_flush_neighbors` | 是否刷相邻页（机械盘有效） | SSD 建议 0 |
| `innodb_max_dirty_pages_pct` | 脏页比例上限（触发刷脏） | 默认 90，生产常配 60~75 |
| `innodb_max_dirty_pages_pct_lwm` | 低水位，超过就开始预刷 | 常配 10~20 |
| `innodb_adaptive_flushing` | 自适应刷脏 | 默认 ON，别关 |

## 六、Adaptive Flushing：让刷脏追上 redo 的产生速度

核心矛盾：redo 产生速度是变化的。（谁在写、写多少由业务决定）

- 如果刷脏太慢 → redo 空间被写满 → 用户线程等待 → 抖动。
- 如果刷脏太快 → 无谓的随机 IO → 影响读性能。

**Adaptive Flushing（自适应刷脏）** 的做法是：**根据 redo 产生速度动态计算刷脏速度**。

```c
// buf_flush_get_desired_flush_rate() 简化逻辑
static ulint buf_flush_get_desired_flush_rate(void) {
    ulint lsn_advance = log_sys->lsn - log_sys->last_checkpoint_lsn;
    ulint redo_avg = lsn_advance / LOG_LSN_WINDOW;      // 最近的 redo 平均产生速度
    ulint desired = redo_avg * (100 / 100 - max_dirty_pct) /* 余量折算 */;
    return desired;
}
```

直觉理解：

- **redo 写得越快，越要快点刷脏**，否则马上要等；
- **脏页比例越高（接近 `innodb_max_dirty_pages_pct`），刷脏速率越大**。

可以用下面这条 SQL 观察：

```sql
SHOW ENGINE INNODB STATUS\G
-- 关注 Log 段：
-- Log sequence number          1234567890
-- Log flushed up to            1234567000
-- Pages flushed up to          1234500000
-- Last checkpoint at           1234499000
```

其中 `Pages flushed up to` 就是"页刷到哪了"，`Last checkpoint at` 是 checkpoint。

两者相差越大，说明 checkpoint 落后越多，redo 空间越紧张：

```
最坏情况分析：
  若 checkpoint_lsn 长期接近 lsn - log_capacity，
  就说明刷脏速度长期跟不上 redo 生产速度，
  一定会出现周期性抖动，甚至出现"刷脏陷入死循环"。
```

## 七、一个经典事故：redo 太小导致的"周期性卡顿"

配置：

```ini
innodb_log_file_size = 128M
innodb_log_files_in_group = 2      # 总容量 256M
innodb_io_capacity = 200           # 机械盘默认值
innodb_flush_neighbors = 1
```

现象：写入压力上来后，每隔几十秒 TPS 掉到接近 0，持续几秒再恢复。

原因链条：

```
写入量大 → redo 快速增长 → 剩余 redo 空间不足
   → 用户线程调用 log_free_check() 等待刷脏
   → innodb_io_capacity 太低，刷脏慢，刷不动
   → checkpoint 推进缓慢 → 用户线程长时间等待
   → TPS 断崖（抖动）
```

排查手段：

```sql
-- 1. 看 checkpoint 与 lsn 的差距
SHOW ENGINE INNODB STATUS\G

-- 2. 看实时指标判断是不停有 log waits
SHOW GLOBAL STATUS LIKE 'Innodb_log_waits';        -- 应长期为 0
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_dirty';
SHOW GLOBAL STATUS LIKE 'Innodb_pages_flushed';

-- 3. 看刷脏速率是否被限制
SHOW GLOBAL STATUS LIKE 'Innodb_data_fsyncs';
```

修复方案：

1. **放大 redo**：`innodb_log_file_size`（8.0.30+ 用 `innodb_redo_log_capacity`）从 256M 提到 2G~4G，让回旋空间更大。
2. **提高 io_capacity**：SSD 上设 2000+，让刷脏线程有能力追上 redo。
3. **SSD 关闭相邻刷**：`innodb_flush_neighbors=0`。
4. **适当降低 `innodb_max_dirty_pages_pct`**（如 60~70），提前预刷，避免临门一脚。

## 八、刷脏与 Doublewrite 的配合

脏页写回数据文件时，如果写到一半断电，会出现**页断裂（torn page）**。InnoDB 用 **Doublewrite Buffer** 兜底：

```
脏页刷盘路径：
  Buffer Pool 脏页
      ↓ 先写入 doublewrite 区（顺序写，且立即 fsync）
  doublewrite files
      ↓ 再写回真实表空间的数据文件
  数据文件 .ibd
```

崩溃恢复时先读 doublewrite 区获取完整页，再重放 redo。所以**刷脏不是"直接写 .ibd"，而是先 doublewrite**，这也是刷脏有额外写放大的原因。

| 参数 | 说明 |
| --- | --- |
| `innodb_doublewrite` | 是否开启，默认 ON，不建议关 |
| `innodb_doublewrite_dir` | 8.0 可指定独立目录/盘 |
| `innodb_doublewrite_files` | 8.0.20+ 可调数量 |

如果是支持原子写（atomic write）的存储，官方 8.0.20+ 提供了 `innodb_doublewrite=detect_only` 等选项，但生产上除非确认硬件支持，否则保持默认。

## 九、生产配置模板

以下是 SSD（4C8G 以上）常见的一套稳妥配置：

```ini
[mysqld]
# redo 容量：建议能撑住 1~2 小时的写入峰值
innodb_redo_log_capacity = 2G          # MySQL 8.0.30+
# 老版本用下面两项
# innodb_log_file_size = 1G
# innodb_log_files_in_group = 2

# 刷脏速率：让后台有能力追上 redo
innodb_io_capacity = 4000
innodb_io_capacity_max = 8000
innodb_flush_neighbors = 0

# 脏页水位：提前预刷，避免卡顿
innodb_max_dirty_pages_pct = 70
innodb_max_dirty_pages_pct_lwm = 10

# 自适应刷脏保持开启
innodb_adaptive_flushing = ON
innodb_adaptive_flushing_lwm = 10

# 刷脏线程数（8.0）
innodb_page_cleaners = 4
```

再配合监控下列指标，基本能提前发现刷脏瓶颈：

```
Innodb_buffer_pool_pages_dirty / Innodb_buffer_pool_pages_total   → 脏页比例
Innodb_os_log_written / uptime                                     → redo 产生速率
(Innodb_pages_flushed) / uptime                                    → 刷脏速率
Innodb_log_waits                                                   → 是否为 0
Log sequence number - Last checkpoint at                           → checkpoint 落后程度
```

## 十、面试追问

**Q1：redo log 和 binlog 都写满了会怎样？**

redo 满了会触发刷脏、推进 checkpoint，用户线程可能等待；binlog 是追加写、按 `max_binlog_size` 轮转，写满会切新文件并可能触发 `expire_logs_days` 清理，通常不会"卡用户"。真正会卡住的是 redo 空间不足。

**Q2：为什么 checkpoint_lsn 是最老脏页的 LSN，而不是最新的？**

因为日志重放必须从"最早的未落盘修改"开始。比 `checkpoint_lsn` 更老的日志，其对应的页都已经安全落盘，重放不再需要，所以可以覆盖。

**Q3：`innodb_flush_log_at_trx_commit` 和刷脏有关系吗？**

这是**日志刷盘**策略（控制 redo fsync 时机：0=交给后台、1=每次提交、2=每次提交写 OS 缓存），跟**脏页刷盘**是两回事。前者管"崩溃后不丢已提交事务"，后者管"redo 空间能被回收"。一个是 WAL 的持久化，一个是 checkpoint 的推进。

**Q4：为什么刷脏快了反而可能更慢？**

因为脏页在磁盘上不一定相邻，随机刷脏会产生大量随机 IO。`innodb_flush_neighbors` 正是通过"顺带刷相邻页"减少随机 IO，但 SSD 上随机 IO 代价低，反而可能造成无谓写放大，所以 SSD 建议关闭。

**Q5：`innodb_max_dirty_pages_pct` 调低会有什么副作用？**

刷脏更频繁、写放大更大，长期看对 SSD 磨损和 IO 有影响。它是"平滑度 vs 写放大"的权衡，不是越低越好。

## 十一、小结

- **LSN 是全局进度条**，`checkpoint_lsn` 表示"最老脏页对应的日志位置"，它之后才能被覆盖。
- **推进 checkpoint = 刷最老的脏页 = 回收 redo 空间**，三者一体。
- **redo 空间不足会让用户线程等待刷脏**，这就是数据库抖动的根因之一。
- **Adaptive Flushing 按 redo 产生速度动态调节刷脏速率**，是平滑 TPS 的关键。
- 生产调优三板斧：**放大 redo、提高 io_capacity、提前触发刷脏（降低 dirty pct 水位）**。
- 刷脏前要经过 **doublewrite**，这是防页断裂的保险，也带来写放大。

理解这条链路之后，你看到 `SHOW ENGINE INNODB STATUS` 里那几个 LSN，就能直接判断出这套库的写入健康度。
