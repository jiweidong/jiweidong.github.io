---
title: 【MySQL 底层】binlog 事务压缩深度解析：Transaction_payload 事件、压缩比与 CDC 断链风险
date: 2026-11-20 08:00:00
tags:
  - MySQL
  - binlog
  - 复制
  - 性能优化
categories:
  - MySQL
author: 东哥
---

# 【MySQL 底层】binlog 事务压缩深度解析

## 前言

MySQL 8.0.20 引入了一个很容易被忽略、但在大规模写入场景下收益极高的特性：**binary log transaction compression（二进制日志事务压缩）**。

它解决的是一个非常具体的问题：一条 `UPDATE` 改 1 万行，binlog 里就要写 1 万个 row event；一个大事务动辄几百 MB。这些字节要落盘、要跨机房传输、要被从库重放、要被 CDC 消费。压缩能把这部分成本直接砍掉一半以上。

但它的代价也很实在：CPU 要压缩和解压、CDC 工具可能直接读不懂、大事务在复制链路上会变成一个"黑盒事件"。这篇文章从事件结构讲到生产落地，最后给出 Java 侧的观测和验证代码。

## 一、压缩到底压的是什么

### 1.1 压缩单位是「事务」，不是「事件」

这一点是理解全部行为的前提。开启 `binlog_transaction_compression=ON` 之后，MySQL 在事务提交、把 binlog cache 写入 binlog 文件时，会把这个事务内**除 GTID 之外**的绝大多数事件打包、压缩，然后写成一个单独的 `Transaction_payload` 事件：

```text
[GTID event]                 ← 仍然独立，复制位点依赖它
[Transaction_payload event]  ← 里面是压缩后的：Query/Table_map/Write_rows/Update_rows/Xid...
```

也就是说，从库和 CDC 看到的不再是"一堆 row event"，而是"一个 payload + 一段字节流"。`Transaction_payload` 的头部会记录 `payload_size`（压缩后大小）和 `compression_type`（当前只有 ZSTD）。

相关参数只有两个：

```sql
-- 开启压缩（默认 OFF）
binlog_transaction_compression = ON

-- ZSTD 压缩级别 1~22，默认 3
binlog_transaction_compression_level_zstd = 3
```

级别选择要克制。ZSTD 的曲线在 1~6 区间很陡，6 之后边际收益快速下降，而 CPU 成本接近线性。生产上先用 3，压不动再往 6 试，**不要碰 15 以上**——那是归档场景的甜点，不是在线事务的。

### 1.2 为什么压缩比能到 3~10 倍

ROW 格式的 row event 有两个天然高压缩特征：

1. **同一事务内的行结构高度重复**。`Table_map` 只出现一次，之后每行的列布局、类型、长度前缀完全一致，ZSTD 的字典很快就能命中。
2. **值域重复**。批量插入的场景里，`status`、`type`、`tenant_id` 这类低基数字段反复出现。

实测经验值（单事务 5000 行、20 列、含 3 个 varchar）：

| 场景 | 原始 binlog | 压缩后 | 压缩比 | 说明 |
|---|---|---|---|---|
| 批量 INSERT 宽表 | 42 MB | 4.1 MB | ~10x | 重复度最高 |
| 批量 UPDATE 少量列 | 38 MB | 7.6 MB | ~5x | 只有 before/after image |
| 单行高频小事务 | 300 B/事务 | 约 200 B/事务 | ~1.5x | **压缩头开销吃掉收益** |
| 含 BLOB/JSON 大字段 | 60 MB | 26 MB | ~2.3x | 已是压缩态，压不动 |

结论很直接：**压缩只对大事务有意义**。单行小事务开了压缩，反而可能因为 payload 头、事件包装而略微变大，同时白付 CPU。所以真实的生产策略不是"全局开"，而是"评估事务大小分布后再决定"。

## 二、收益账：省的不只是磁盘

很多人只算磁盘，实际上有四个地方同时受益：

| 维度 | 影响 | 量级 |
|---|---|---|
| binlog 磁盘占用 | 直接下降 | 与压缩比同阶（2~10x） |
| 跨机房复制带宽 | 直接下降 | 同上，这是最大的钱 |
| 从库 IO / relay log 落盘 | 下降 | 同上 |
| 备份体积与恢复时间 | 下降 | 略小于压缩比（解压耗时） |
| 主库 CPU | **上升** | 压缩开销，实测 3~12% |
| 从库 CPU | **上升** | 解压 + SQL 线程应用 |
| CDC 兼容性 | **风险** | 必须验证 |

注意最后两行。从库不是"白拿"：它必须先把 payload 解压回事件流才能应用。所以**从库规格不能明显弱于主库**，否则你会看到 `Relay_Log_Space` 变小了，但 `Seconds_Behind_Source` 反而变大——CPU 成了新瓶颈。

还有一个隐藏成本：SQL 线程解压需要内存。一个 500 MB 的未压缩事务，解压时是实打实要吃内存的，这会把 `replica_parallel_workers` 的并发能力压下来。

## 三、CDC 断链：最容易踩的坑

这是上线前必须过的关。Canal、Debezium、Maxwell、Flink CDC 这些工具，本质都是"解析 binlog 事件流"。它们面对 `Transaction_payload` 有三种反应：

1. **认识这个事件**：解压后继续按原逻辑处理 —— 正常。
2. **不认识、跳过**：**最危险**。任务不报错、延迟正常、但数据静默丢失。等你发现时已经丢了几天的增量。
3. **不认识、报错**：反而是好事，至少立刻暴露。

所以验证不能只看"任务有没有红色报错"，必须做**行数与内容对账**：

```sql
-- 源库
SELECT COUNT(*), MAX(update_time) FROM orders WHERE update_time >= '2026-11-20 00:00:00';

-- 目标端（数仓 / ES / 下游库）
SELECT COUNT(*), MAX(update_time) FROM orders WHERE update_time >= '2026-11-20 00:00:00';
```

上线顺序建议：

```text
1. 先在预发打开压缩，用一个中等规模事务（10~50MB）跑通
2. CDC 任务开启 debug 日志，确认能看到 Transaction_payload 并被解压
3. 双跑 24 小时，做小时级 COUNT + 主键集合差集对账
4. 灰度：按实例/按库逐步开启，保留回滚开关
```

回滚开关很简单——`SET GLOBAL binlog_transaction_compression=OFF`，**只影响之后的新事务**，已写入的压缩事务仍然需要能被解析。所以回滚不能解决"CDC 读不懂历史 binlog"的问题，这一点必须在灰度前想清楚。

## 四、Java 侧：压缩比观测与事务拆分

### 4.1 用 JDBC 采集 binlog 体积序列

没有现成的"压缩比"指标，需要自己算：按时间窗口采样 `SHOW BINARY LOGS` 的总字节数，除以同一窗口内写入的行数/事务数，得到"每事务平均字节"。

```java
@Component
public class BinlogSizeCollector {

    private final JdbcTemplate jdbc;
    private final MeterRegistry meter;

    public BinlogSizeCollector(JdbcTemplate jdbc, MeterRegistry meter) {
        this.jdbc = jdbc;
        this.meter = meter;
    }

    /** 每 60s 采一次，输出 binlog 总量与增量速率 */
    @Scheduled(fixedDelay = 60_000)
    public void collect() {
        List<Map<String, Object>> rows =
                jdbc.queryForList("SHOW BINARY LOGS");   // File | Position | Encrypted

        long total = 0L;
        for (Map<String, Object> r : rows) {
            Object size = r.get("File_size");
            if (size instanceof Number n) {
                total += n.longValue();
            }
        }
        meter.gauge("mysql.binlog.total.bytes", total);

        // 增量速率：与上次采样做差，交给 Micrometer 的 counter 语义
        meter.counter("mysql.binlog.growth.bytes").increment(
                Math.max(0, total - lastTotal));
        lastTotal = total;
    }

    private volatile long lastTotal = 0L;
}
```

配套再采两个业务侧计数，就能算"每万行写入产生多少 binlog"：

```sql
SHOW GLOBAL STATUS LIKE 'Com_insert';
SHOW GLOBAL STATUS LIKE 'Com_update';
SHOW GLOBAL STATUS LIKE 'Com_delete';
SHOW GLOBAL STATUS LIKE 'Innodb_rows_inserted';
```

```java
public double bytesPerThousandRows(long binlogDelta, long rowsDelta) {
    if (rowsDelta <= 0) return 0;
    return binlogDelta * 1000.0 / rowsDelta;
}
```

上线压缩前后各跑一个完整业务周期（含大促峰值），把 `bytesPerThousandRows` 画在同一张图上，压缩收益一目了然——比看单次 `ls -lh` 靠谱得多。

### 4.2 大事务拆分：比压缩更根本的优化

压缩是"把大事务变小"，拆分是"不要产生大事务"。后者收益更高，因为大事务本身还会带来：长事务阻塞 purge、从库延迟尖刺、锁持有时间过长、回滚代价高。

```java
public void batchUpdate(List<Order> orders, int batchSize) {
    for (int i = 0; i < orders.size(); i += batchSize) {
        List<Order> slice = orders.subList(i, Math.min(i + batchSize, orders.size()));
        // 每个 slice 一个独立事务：REQUIRES_NEW 保证不受外层事务牵连
        transactionTemplate.executeWithoutResult(status -> {
            for (Order o : slice) {
                orderMapper.updateStatus(o.getId(), o.getStatus());
            }
        });
        // 批间让出，避免长时间占住 redo / undo
        LockSupport.parkNanos(Duration.ofMillis(20).toNanos());
    }
}
```

`batchSize` 的经验值：单事务 binlog 控制在 **8~32 MB**。太小则事务开销占比高，太大则压缩收益递减且延迟尖刺明显。

## 五、什么时候不该开

四条红线，命中任意一条就先别开：

1. **CDC 链路老旧且无法升级**。这是最常见的否决项。
2. **事务以单行小事务为主**（比如按主键逐条更新的业务）。压缩比不到 2 倍，纯亏 CPU。
3. **从库规格明显弱于主库**。解压成本会把复制延迟放大。
4. **需要人工用 `mysqlbinlog` 逐事件排查**。压缩后事件被包在 payload 里，虽然新版本工具能解开，但排障体验会变差。

反过来说，以下场景收益最大：批量导入、批量状态流转、数据回填、日志类宽表写入、跨机房单向复制。

## 六、面试追问

**Q1：binlog 事务压缩和 InnoDB 页压缩、表压缩有什么区别？**

三层完全不同：InnoDB 页压缩作用在**存储引擎的页**上（buffer pool ↔ 磁盘）；表压缩是更激进的页格式；binlog 事务压缩作用在**复制日志**上（binlog cache ↔ binlog 文件 ↔ 网络）。三者互不替代，可以同时开，也可以只开其中一个。binlog 压缩不影响 InnoDB 数据文件大小。

**Q2：开了压缩，从库还需要 `log_replica_updates` 吗？**

需要。`log_replica_updates=ON` 时从库要把收到的事件再写进自己的 binlog（级联复制、PITR 依赖它）。开了压缩后，从库写自己 binlog 时**会重新压缩**，也就是解压一次、再压一次，CPU 成本翻倍。级联层级越深，这个成本越明显。

**Q3：压缩后 `Seconds_Behind_Source` 变小了，是不是就说明复制更快了？**

不一定。这个指标衡量的是"SQL 线程追上 relay log 的时间差"，不包含网络传输与 IO 等待的全部。压缩后网络更快、relay log 更小，指标可能变好看；但如果从库 CPU 被解压吃满，真实端到端延迟可能是变大的。要看 `Replica_running` 之外的：`performance_schema.replication_applier_status_by_worker` 的 `APPLYING_TRANSACTION` 与 worker 忙碌度，以及从库 CPU steal/load。

**Q4：为什么 GTID 事件不被压缩进 payload？**

因为 GTID 是复制协议的定位锚点。从库在**解压之前**就要知道"这个事务的 GTID 是多少"，才能判断是否跳过（`gtid_executed` 已包含）、才能更新 `Retrieved_Gtid_Set`。如果把 GTID 压进去，就得先解压才能定位，形成循环依赖，也让过滤和跳过变得昂贵。

## 总结

- 压缩单位是**事务**，产物是单个 `Transaction_payload`（ZSTD），GTID 独立在外。
- 收益集中在**大事务**：磁盘、跨机房带宽、备份体积；成本是主从双侧 CPU 与内存。
- 最大风险不是性能，而是 **CDC 静默丢数据**——必须做行级对账，不能只看任务是否报错。
- 上线前先看事务大小分布；单行小事务为主的库，开了是负收益。
- 比压缩更根本的是**拆分大事务**，把单事务 binlog 控制在 8~32 MB。
