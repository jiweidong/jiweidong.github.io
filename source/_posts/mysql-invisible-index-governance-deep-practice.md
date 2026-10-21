---
title: 【MySQL 运维】不可见索引（Invisible Index）与索引治理实战：冗余索引检测、灰度下线与上线前验证
date: 2026-10-21 08:00:00
tags:
  - Java
  - MySQL
  - 索引
  - 性能优化
  - 运维
categories:
  - MySQL
author: 东哥
---

# 【MySQL 运维】不可见索引（Invisible Index）与索引治理实战

## 前言

「索引加得越多，查询越快」——这是我在面试里最常听到、也最想纠正的一句话。

索引不是免费的。每一个二级索引在写入路径上都要付出代价：

- **INSERT**：每多一个索引，就多一次 B+ 树定位插入，多一份 redo/undo；
- **UPDATE**：只要被索引的列发生变化，就要删除旧记录 + 插入新记录（**delete-mark + insert**），而不是原地更新；
- **DELETE**：所有索引都要打删除标记；
- **优化器**：候选索引越多，`range` 评估的组合越多，执行计划越容易走偏；
- **存储**：一个千万级表的二级索引，随随便便几十 GB。

一个跑了三五年的业务库，`SHOW INDEX` 出来十几二十个索引是常态，其中至少三分之一是历史遗留：早期为了某个报表加的、某次慢查询临时加的、开发觉得「加了总没坏处」加的。问题是——**你敢直接 `DROP INDEX` 吗？**

不敢。因为线上没人能保证这个索引真的没人用。白天不敢动，晚上动了出问题没人背。于是索引越堆越多，写入越来越慢，形成死循环。

MySQL 8.0 给的答案叫 **不可见索引（Invisible Index）**：先把索引「逻辑下线」，让优化器看不见它，但数据结构和写入成本还在；观察足够长时间确认无影响，再物理删除。这一篇就把这个能力讲透，并给出一套可落地的**索引治理流水线**（发现 → 评估 → 灰度 → 验证 → 清理），最后用 Java 写一个自动巡检任务。

---

## 一、不可见索引到底是什么

MySQL 8.0.0 引入 `ALTER TABLE ... ALTER INDEX ... [VISIBLE | INVISIBLE]`。

核心语义只有一句话：

> **不可见索引仍然存在、仍然维护、仍然消耗写入成本，但优化器在生成执行计划时默认不考虑它。**

```sql
-- 创建时就设为不可见
ALTER TABLE t_order ADD INDEX idx_user_ctime (user_id, create_time) INVISIBLE;

-- 已存在的索引切成不可见
ALTER TABLE t_order ALTER INDEX idx_user_ctime INVISIBLE;

-- 再切回来
ALTER TABLE t_order ALTER INDEX idx_user_ctime VISIBLE;
```

查看可见性：

```sql
SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX, IS_VISIBLE
FROM information_schema.statistics
WHERE table_schema = 'shop' AND table_name = 't_order';
```

`IS_VISIBLE = NO` 就是不可见。

### 关键点：它和「删掉索引」的差别

| 维度 | 设为 INVISIBLE | DROP INDEX |
|---|---|---|
| 优化器是否使用 | 否（默认） | 否 |
| 是否仍占磁盘 | **是** | 否 |
| 是否仍有写入成本 | **是** | 否 |
| 回滚成本 | `ALTER INDEX ... VISIBLE`，秒级元数据操作 | 需要重建索引，大表几十分钟到几小时 |
| 是否影响唯一性约束 | 仍然生效 | 约束消失 |
| 是否影响外键 | 仍然生效 | 可能报错 |

所以 **INVISIBLE 是「灰度下线」工具，不是「优化手段」**。它的价值在于把「删索引」这个高风险动作拆成两步：先让它不参与执行计划，观察一周到一个月；确认没有慢查询、没有业务报警，再真正 `DROP`。

> 面试里如果被问「不可见索引能提升性能吗」，正确回答是：**不能**。它不减少写入成本，只降低变更风险。真正提升性能的是删除冗余索引。

---

## 二、优化器是怎么「看不见」它的

MySQL 8.0 的索引元数据存放在 `dd`（Data Dictionary）表空间的 `indexes` 私有表中，其中有一个 `is_visible` 字段。server 层在打开表时（`open_table` → `open_table_def`）会把索引的可见性加载到 `TABLE_SHARE` 的 `KEY` 结构里。

优化器在 `JOIN::optimize` 阶段构造候选索引时，会跳过 `key_is_visible() == false` 的索引；`test_quick_select` 里的 range 分析同样过滤。

有两个例外必须记住：

1. **唯一约束仍然生效**。哪怕索引不可见，插入重复值依然报 `Duplicate entry`。因为唯一性检查走的是存储引擎层的索引，不经过优化器。
2. **可以被强制使用**。会话级参数 `use_invisible_indexes` 打开后，优化器会把不可见索引当成正常索引：

```sql
SET SESSION optimizer_switch = 'use_invisible_indexes=on';
-- 或者
SET SESSION use_invisible_indexes = ON;
```

这个开关非常有用：**灰度期间如果发现某条 SQL 变慢，不用改 DDL，只要在这个会话里打开开关就能恢复原执行计划**，用来做 A/B 对比极其方便。

还有一个坑：`FORCE INDEX (idx_xxx)` 指定了不可见索引时，MySQL 8.0 会直接报错：

```
ERROR 1176 (42000): Key 'idx_user_ctime' doesn't exist in table 't_order'
```

报错信息说「不存在」，其实是「不可见」。这点在排查时容易误导人，尤其是在 MyBatis-Plus 的 `@TableIndex` 或者手写 `FORCE INDEX` 的项目里。

---

## 三、索引治理流水线：从「不敢删」到「敢删」

我把这套流程固化成 5 步，团队里跑了两年，清理掉了一个 2.3 亿行订单表的 7 个冗余索引，写入 TPS 提升约 18%。

### Step 1：发现——三类候选索引

**（1）从未被使用的索引**

`performance_schema.table_io_waits_summary_by_index_usage` 记录了每个索引的读次数：

```sql
SELECT OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME, COUNT_STAR
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
  AND INDEX_NAME IS NOT NULL
  AND INDEX_NAME <> 'PRIMARY'
  AND COUNT_STAR = 0
ORDER BY OBJECT_SCHEMA, OBJECT_NAME;
```

⚠️ 三个前置条件，缺一不可：

- `performance_schema` 必须开启（`performance_schema=ON`），且 `performance_schema_max_table_instances` 不能太小，否则表被淘汰统计会失真；
- 统计是**自实例启动以来**的累计值，刚重启过的库不要信；
- 统计从 `setup_instruments` 里对应 instrument 打开之后才开始算。默认 `wait/io/table/sql/handler` 是开的，但如果你手动关过，数据就是假的。

**（2）冗余索引**（MySQL 8.0 的 `sys` 库直接给视图）

```sql
SELECT * FROM sys.schema_redundant_indexes;
```

判定逻辑是「前缀覆盖」：

- `idx_a (a)` 与 `idx_ab (a, b)` → 前者冗余（`a` 是后者的最左前缀）；
- `idx_a (a)` 与 `idx_a_id (a, id)` → 前者冗余（二级索引天然带主键）；
- `idx_ab (a, b)` 与 `idx_ba (b, a)` → **不冗余**，是两棵不同的树；
- `UNIQUE (a)` 与 `INDEX (a)` → 前者不能删（约束），后者冗余。

`sys.schema_redundant_indexes` 只做静态结构分析，**不看你实际查询**，所以它给出的是「候选」，不是「结论」。一个被标为冗余的索引，可能因为选择性更好而被优化器优先选择——删之前必须看 `EXPLAIN`。

**（3）低选择性索引**

```sql
SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME, CARDINALITY,
       (SELECT TABLE_ROWS FROM information_schema.tables t
        WHERE t.TABLE_SCHEMA = s.TABLE_SCHEMA AND t.TABLE_NAME = s.TABLE_NAME) AS table_rows,
       ROUND(CARDINALITY / NULLIF((SELECT TABLE_ROWS FROM information_schema.tables t
        WHERE t.TABLE_SCHEMA = s.TABLE_SCHEMA AND t.TABLE_NAME = s.TABLE_NAME), 0), 6) AS selectivity
FROM information_schema.statistics s
WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 't_order'
  AND SEQ_IN_INDEX = 1;
```

选择性低于 0.001（比如性别、状态位这种只有几个值的列）基本可以判死刑。注意 `CARDINALITY` 是**采样估算值**，InnoDB 的采样页数是 `innodb_stats_persistent_sample_pages`（默认 20），大表上偏差可能很大，必要时 `ANALYZE TABLE` 后再看。

### Step 2：评估——三个必须回答的问题

1. **这条 SQL 走这个索引，性能差多少？** 用 `EXPLAIN ANALYZE`（8.0.18+）看实际耗时，而不是只看 `type`：
   ```sql
   EXPLAIN ANALYZE SELECT * FROM t_order WHERE user_id = 10086 ORDER BY create_time DESC LIMIT 20;
   ```
2. **有没有 `FORCE INDEX` / `USE INDEX` 引用它？** 全库 grep 代码和 SQL 文件：
   ```bash
   grep -rniE "(force|use|ignore)\s+index\s*\(\s*idx_user_ctime" --include="*.xml" --include="*.java" --include="*.sql" .
   ```
3. **是不是唯一索引 / 外键依赖 / 覆盖索引？** 这三个任一命中，直接排除，不做下线。

### Step 3：灰度——先 INVISIBLE，观察一个完整业务周期

```sql
-- 建议在低峰期执行，8.0 的 ALTER INDEX VISIBLE/INVISIBLE 是 INPLACE + instant 级别，几乎瞬间完成
ALTER TABLE t_order ALTER INDEX idx_user_ctime INVISIBLE;
```

观察期建议 **≥ 2 周**，且必须覆盖：

- 一个完整的大促/月末结算周期（业务 SQL 形态最全）；
- 至少一次发版（新代码可能引入新查询）；
- 一次主从切换或备份窗口（备份 SQL 也可能用到索引）。

观察期内盯三个指标：

| 指标 | 采集方式 | 报警阈值 |
|---|---|---|
| 慢查询数量 | `slow_query_log` + `pt-query-digest` | 相对基线 +30% |
| 该表平均响应时间 | APM / `performance_schema.events_statements_summary_by_digest` | P99 +20% |
| InnoDB 行锁等待 | `information_schema.innodb_trx` + `INNODB_LOCK_WAITS` | 出现 > 1s 等待 |
| 全表扫描次数 | `sys.statements_with_full_table_scans` | 涉及该表的新增条目 |

### Step 4：验证——SQL 回归 + 执行计划对比

这一步是很多团队漏掉的。做法是：把该表相关的 Top 50 SQL 抓出来，在 shadow 库上做「可见 vs 不可见」两轮 `EXPLAIN ANALYZE`，输出对比报告。

```sql
-- 会话级强制使用不可见索引，做对照
SET SESSION use_invisible_indexes = ON;
EXPLAIN ANALYZE SELECT ...;
SET SESSION use_invisible_indexes = OFF;
EXPLAIN ANALYZE SELECT ...;
```

如果两轮的实际耗时差异在 10% 以内，或者「不可见」这轮仍然走其他索引且不慢，就可以进入删除。

### Step 5：清理——DROP，但留好回滚脚本

```sql
-- 删除前先记录索引定义，出问题能 30 秒重建
SHOW CREATE TABLE t_order\G
-- 然后
ALTER TABLE t_order DROP INDEX idx_user_ctime, ALGORITHM=INPLACE, LOCK=NONE;
```

大表上 `DROP INDEX` 在 8.0 是 INPLACE 的，但仍需重建 secondary index 的元数据，且会短暂持有 MDL。务必带上 `LOCK=NONE` 让它在拿不到锁时快速失败，而不是排队把整张表堵死（这一点和 MDL 雪崩是同源问题）。

---

## 四、Java 侧：写一个索引治理巡检任务

治理不能靠人肉。下面这个 Spring Boot 定时任务每天凌晨跑一次，输出「疑似冗余 / 从未使用 / 低选择性」三类报告，推送到群里。

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class IndexGovernanceInspector {

    private final JdbcTemplate jdbcTemplate;
    private final AlertNotifier notifier;

    /** 每天 03:10 执行，避开备份窗口 */
    @Scheduled(cron = "0 10 3 * * ?")
    public void inspect() {
        List<IndexIssue> issues = new ArrayList<>();
        issues.addAll(findUnusedIndexes());
        issues.addAll(findRedundantIndexes());
        issues.addAll(findLowSelectivityIndexes());

        if (issues.isEmpty()) {
            log.info("[index-governance] 本次巡检未发现可疑索引");
            return;
        }

        String report = issues.stream()
                .map(IndexIssue::format)
                .collect(Collectors.joining("\n"));
        log.warn("[index-governance] 发现 {} 个可疑索引:\n{}", issues.size(), report);
        notifier.send("MySQL 索引治理巡检", report);
    }

    private List<IndexIssue> findUnusedIndexes() {
        String sql = """
            SELECT OBJECT_SCHEMA AS db, OBJECT_NAME AS tbl, INDEX_NAME AS idx
            FROM performance_schema.table_io_waits_summary_by_index_usage
            WHERE OBJECT_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
              AND INDEX_NAME IS NOT NULL
              AND INDEX_NAME <> 'PRIMARY'
              AND COUNT_STAR = 0
            """;
        return jdbcTemplate.query(sql, (rs, i) -> new IndexIssue(
                rs.getString("db"), rs.getString("tbl"), rs.getString("idx"),
                "UNUSED", "自实例启动以来读次数为 0"));
    }

    private List<IndexIssue> findRedundantIndexes() {
        String sql = """
            SELECT table_schema AS db, table_name AS tbl,
                   redundant_index_name AS idx, dominant_index_name AS covered_by
            FROM sys.schema_redundant_indexes
            """;
        return jdbcTemplate.query(sql, (rs, i) -> new IndexIssue(
                rs.getString("db"), rs.getString("tbl"), rs.getString("idx"),
                "REDUNDANT", "被 " + rs.getString("covered_by") + " 前缀覆盖"));
    }

    private List<IndexIssue> findLowSelectivityIndexes() {
        String sql = """
            SELECT s.TABLE_SCHEMA AS db, s.TABLE_NAME AS tbl, s.INDEX_NAME AS idx,
                   s.CARDINALITY AS card, t.TABLE_ROWS AS rows_cnt
            FROM information_schema.statistics s
            JOIN information_schema.tables t
              ON t.TABLE_SCHEMA = s.TABLE_SCHEMA AND t.TABLE_NAME = s.TABLE_NAME
            WHERE s.SEQ_IN_INDEX = 1
              AND s.TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema')
              AND t.TABLE_ROWS > 100000
              AND s.CARDINALITY / NULLIF(t.TABLE_ROWS, 0) < 0.001
            """;
        return jdbcTemplate.query(sql, (rs, i) -> new IndexIssue(
                rs.getString("db"), rs.getString("tbl"), rs.getString("idx"),
                "LOW_SELECTIVITY",
                "选择性 " + String.format("%.5f", rs.getDouble("card") / rs.getLong("rows_cnt"))
                        + "，表行数 " + rs.getLong("rows_cnt")));
    }

    public record IndexIssue(String db, String table, String index, String type, String reason) {
        String format() {
            return "• [%s] %s.%s.%s — %s".formatted(type, db, table, index, reason);
        }
    }
}
```

配套的 Flyway 迁移脚本模板（保留可回滚性）：

```sql
-- V20261021_01__mark_idx_user_ctime_invisible.sql
-- 灰度下线：先不可见，观察 14 天
ALTER TABLE t_order ALTER INDEX idx_user_ctime INVISIBLE;

-- V20261021_02__drop_idx_user_ctime.sql（观察期结束后再执行）
-- ALTER TABLE t_order DROP INDEX idx_user_ctime, ALGORITHM=INPLACE, LOCK=NONE;
```

> 用 Flyway/Liquibase 管索引变更，比手工执行强的地方在于：**变更有版本、有审计、能回滚、能在预发先跑一遍**。生产环境的 DDL 一定要走这条路径。

---

## 五、五个真实踩过的坑

**坑 1：以为不可见 = 不占资源。**
一个同事把 5 个索引设成 INVISIBLE，然后说「写入应该快了吧」，结果 TPS 一点没变。因为写入路径完全没变。**INVISIBLE 只影响优化器。**

**坑 2：唯一索引设成不可见，线上插入开始报重复。**
这是预期行为，但很多人不知道。唯一性校验不走优化器，走的是存储引擎的唯一性检查。**唯一索引不要拿来做灰度。**

**坑 3：灰度期间 DBA 用 `FORCE INDEX` 的手工 SQL 全部报错。**
报错信息是 "Key doesn't exist"，排查了半天才发现是 INVISIBLE。**灰度前必须 grep 全量 SQL 脚本。**

**坑 4：观察期太短，大促当天翻车。**
某次把一个 `(shop_id, status)` 索引下线，观察了 5 天没事。大促当天订单状态查询量涨了 20 倍，优化器退化成全表扫描，直接把从库打满。**观察期必须覆盖业务峰值。**

**坑 5：`DROP INDEX` 没加 `LOCK=NONE`，MDL 排队堵死全表。**
`ALTER TABLE` 拿不到 MDL 会排队，而排队会阻塞后续所有对该表的请求，形成雪崩。加 `LOCK=NONE` 让它快速失败，再用 `pt-online-schema-change` 或业务低峰重试。

---

## 六、面试高频追问

**Q1：不可见索引和 `IGNORE INDEX` 有什么区别？**
`IGNORE INDEX` 是**语句级提示**，只对当前这条 SQL 生效，且优化器可以不完全遵守；不可见索引是**元数据级**的，对所有 SQL 默认生效，且持久化在数据字典里。前者用于临时规避，后者用于治理。

**Q2：为什么 MySQL 不直接提供一个「删除索引前的 dry-run」？**
INVISIBLE 就是这个 dry-run。它的设计取舍是：宁可多占一点空间和写入成本，也要保证回滚是 O(1) 的元数据操作。这是一个典型的「用空间换变更安全」的工程决策。

**Q3：`sys.schema_unused_indexes` 和 `performance_schema` 的统计，哪个更可信？**
`sys.schema_unused_indexes` 本身就是对 `table_io_waits_summary_by_index_usage` 的封装，二者同源。真正影响可信度的是**统计起点**和**表实例是否被淘汰**。生产上我会额外开启 `innodb_monitor` 或直接用 APM 的 SQL 采样做交叉验证。

**Q4：一个索引从来没被 `performance_schema` 记录，但业务说「肯定在用」，怎么判断？**
三种可能：(1) 那条 SQL 走的是覆盖索引但被记录到了别的索引；(2) 统计被重置过；(3) 业务用的是 `FORCE INDEX`。用 `EXPLAIN` + 慢查询日志交叉验证，别只信一个数据源。

**Q5：大表删索引，怎么做到业务无感？**
`ALGORITHM=INPLACE, LOCK=NONE` + 低峰执行 + 先 INVISIBLE 灰度 + 准备好重建脚本。四件套缺一不可。

---

## 七、总结

- **不可见索引不是性能优化手段，是变更风险管理手段**。它把「删索引」从一次性高风险动作，变成「灰度 → 观察 → 验证 → 删除」的可控流程。
- 索引治理的核心不是技术，是**流程**：有巡检、有指标、有观察期、有回滚脚本。
- 三个数据源要交叉验证：`performance_schema`（使用情况）、`sys.schema_redundant_indexes`（结构冗余）、`information_schema.statistics`（选择性）。
- 唯一索引、外键依赖索引、被 `FORCE INDEX` 引用的索引，**不进灰度名单**。
- 大表 DDL 永远带 `LOCK=NONE`，永远走 Flyway 这类版本化工具。

索引治理是个「做了没人夸，不做迟早炸」的活。但一个 2 亿行的表少 5 个冗余索引，写入延迟降 20%，这种收益是实打实落在每个用户身上的。
