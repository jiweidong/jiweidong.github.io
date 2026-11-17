---
title: 【MySQL 优化】EXPLAIN ANALYZE 与执行计划偏差归因：估算 1 行、实际 80 万行的真相
date: 2026-11-17 08:10:00
tags:
  - Java
  - MySQL
  - 索引
  - 执行计划
  - 性能优化
categories:
  - MySQL
author: 东哥
---

# 【MySQL 优化】EXPLAIN ANALYZE 与执行计划偏差归因

## 前言

一个真实工单：

> 一条按时间范围查订单的 SQL，`EXPLAIN` 显示 `type=range`、`rows=1`、`Extra=Using index condition`，看起来完美。但接口 P99 3.2s，慢日志里这条 SQL 每次扫描行数 80 万。

问题不在索引，也不在 SQL 写法，而在**优化器估错了行数**：它以为只有 1 行，实际有 80 万行，于是选了一个"对 1 行最优、对 80 万行灾难"的执行计划。

`EXPLAIN` 给你的永远是**估算值**；`EXPLAIN ANALYZE` 给你的才是**实测值**。把两者放在一起看，偏差出现在哪个节点，问题就出在哪里。

本文讲三件事：怎么读 `EXPLAIN ANALYZE`、估算为什么会错、以及怎么把"让计划稳定"工程化。

---

## 一、EXPLAIN 的三种形态

| 形态 | 命令 | 是否执行 SQL | 输出内容 | 适用场景 |
|---|---|---|---|---|
| 传统格式 | `EXPLAIN SELECT ...` | 否 | 表、type、key、rows（估算）、Extra | 日常快速看索引 |
| 树形格式 | `EXPLAIN FORMAT=TREE SELECT ...` | 否 | 迭代器树 + 估算成本 | 看 join 顺序与成本 |
| 实测格式 | `EXPLAIN ANALYZE SELECT ...` | **是** | 每个节点的估算 vs 实测 | 定位偏差根因 |

`EXPLAIN ANALYZE` 从 MySQL 8.0.18 开始提供，输出长这样：

```text
-> Nested loop inner join  (cost=2481.55 rows=1) (actual time=0.097..3120.441 rows=803214 loops=1)
    -> Filter: (o.status = 3)  (cost=1200.10 rows=1) (actual time=0.061..2841.772 rows=803214 loops=1)
        -> Index range scan on o using idx_create_time  (cost=1200.10 rows=1) (actual time=0.052..2201.339 rows=803214 loops=1)
    -> Single-row index lookup on u using PRIMARY (id=o.user_id)  (cost=0.25 rows=1) (actual time=0.003..0.003 rows=1 loops=803214)
```

### 1.1 字段怎么读

- `cost`：优化器**估算**的成本（单位是"随机读页"的抽象值），只用于比较，不是毫秒；
- `rows`：优化器**估算**的行数（在 `actual` 前面）或**实测**的平均每轮行数（在 `actual` 后面）；
- `actual time=A..B`：该节点第一行返回时间..最后一行返回时间（毫秒）；
- `loops=N`：该节点被执行了多少次。

### 1.2 最容易读错的两件事

**第一，`actual rows` 是"每轮平均值"，要乘 `loops`：**

```text
-> Single-row index lookup ... (actual time=0.003..0.003 rows=1 loops=803214)
```

这个节点总执行行数 = `1 × 803214 = 803214`，总耗时约 `0.003 × 803214 ≈ 2409ms`。只看 `rows=1` 会以为它很轻。

**第二，`actual time` 是"包含子节点"的累计时间**（在树形输出里父节点的 A..B 覆盖子节点）。所以定位瓶颈要看"**自身耗时 = 本节点 B - 子节点 B**"，或者直接找"rows 偏差最大的那个节点"。

---

## 二、执行计划是怎么被选出来的

优化器做三件事：

```text
1. 枚举访问路径：全表扫描 / 各索引的 range、ref、eq_ref / index merge
2. 估算每个路径的行数：依赖统计信息（索引基数、直方图、采样）
3. 用成本模型比较：server_cost（CPU）+ engine_cost（IO），选总成本最低的
```

关键认知：**优化器不追求"正确"，只追求"按它以为的代价最小"**。所以当输入（统计信息）错了，输出（计划）必然错，而且错得自洽——`EXPLAIN` 看起来毫无破绽。

成本常数：

```sql
SELECT * FROM mysql.server_cost;
SELECT * FROM mysql.engine_cost;
```

在 SSD 上，默认的 `io_block_read_cost=1.0` 可能严重高估随机 IO 代价，导致优化器过度偏好"小索引范围扫描"，这也是很多"看起来很怪"的计划的来源之一。修改成本常数是**全局影响**，生产上务必谨慎评估。

---

## 三、六类偏差根因

### 3.1 数据倾斜

```sql
-- status: 1 占 99.2%，3 占 0.3%
SELECT * FROM orders WHERE status = 3 AND create_time > '2026-11-01';
```

优化器按"平均选择性"估算 `status=3` 命中 0.3%，但如果你把 `status` 放在联合索引第一列，它可能认为"这个条件过滤性很好"，实际却要扫大量数据。**倾斜字段 + 联合索引顺序错误**是最常见的组合。

### 3.2 多列相关性

优化器假设列与列**独立**：

```sql
SELECT * FROM users WHERE province = '浙江' AND city = '杭州';
```

它会算 `P(浙江) × P(杭州)`，但杭州必然在浙江，实际选择率远高于估算值 → 低估行数 → 选错 join 顺序。

### 3.3 表达式与函数

```sql
-- 索引失效 + 估算失真
SELECT * FROM orders WHERE DATE(create_time) = '2026-11-17';
-- 应改为
SELECT * FROM orders WHERE create_time >= '2026-11-17' AND create_time < '2026-11-18';
```

函数作用于列时，优化器无法使用索引统计，只能退回默认选择率（常见 10% 或更粗的猜测）。

### 3.4 前缀索引与模糊匹配

`LIKE '%keyword%'` 无法用 B+ 树定位，优化器对这类条件的选择率估计非常粗，容易低估或高估。

### 3.5 统计信息过期或采样偏差

InnoDB 默认 `innodb_stats_persistent=ON`，每张表采样 `innodb_stats_persistent_sample_pages=20` 个页。对于十亿行的大表，20 个页的样本很容易错过倾斜数据。

```sql
-- 看统计信息
SELECT * FROM mysql.innodb_table_stats WHERE table_name = 'orders';
SELECT * FROM mysql.innodb_index_stats WHERE table_name = 'orders';
SHOW INDEX FROM orders;
```

### 3.6 隐式转换与字符集不一致

```sql
-- user_id 是 varchar，传了数字 → 全表转换，索引失效
SELECT * FROM users WHERE user_id = 123456;
```

这类问题在 `EXPLAIN` 里会表现为 `type=ALL` 或 `key=NULL`，相对好发现；但如果发生在 join 的驱动条件上，就会变成"估算 1 行实际百万行"。

---

## 四、五步归因流程

### 第一步：从 digest 找到"最贵的 SQL"

```sql
SELECT DIGEST_TEXT,
       COUNT_STAR,
       ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_sec,
       ROUND(AVG_TIMER_WAIT / 1e9, 2)  AS avg_ms,
       SUM_ROWS_EXAMINED,
       SUM_ROWS_SENT
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

重点看 `SUM_ROWS_EXAMINED / SUM_ROWS_SENT` 的比值。比值 > 100 基本可以确定"扫了很多但没用到"。

### 第二步：看估算

```sql
EXPLAIN FORMAT=TREE SELECT ...;
```

先看 join 顺序是否符合直觉：驱动表应该是**过滤后结果集最小**的那张。

### 第三步：看实测，找第一个偏差节点

```sql
EXPLAIN ANALYZE SELECT ...;
```

判断标准：

- `actual rows × loops` 与估算 `rows` 相差 **10 倍以上** → 该节点统计信息有问题；
- 父节点的 `actual rows` 远大于子节点 → 说明过滤条件没生效（函数、隐式转换、类型不匹配）；
- 某个节点 `actual time` 自身占比 > 50% → 瓶颈在这里。

### 第四步：验证统计信息

```sql
-- 采样更充分（大表慎用，会加锁/耗 IO）
ANALYZE TABLE orders UPDATE HISTOGRAM ON status, province WITH 1024 BUCKETS;

-- 看直方图
SELECT * FROM information_schema.COLUMN_STATISTICS
WHERE TABLE_NAME = 'orders';
```

直方图对**倾斜字段的等值/范围查询**最有效；对高基数列（如 id）意义不大。

### 第五步：必要时看 optimizer trace

```sql
SET optimizer_trace = 'enabled=on';
SELECT ...;
SELECT TRACE FROM information_schema.OPTIMIZER_TRACE;
SET optimizer_trace = 'enabled=off';
```

Trace 输出很大（几百 KB 到几 MB），只在"实在想不通为什么选这个索引"时用，且**不要在生产高频 SQL 上长期开启**。

---

## 五、三个典型案例

### 案例一：范围估算 1 行，实际 80 万

```sql
SELECT * FROM orders
WHERE create_time >= '2026-11-01' AND create_time < '2026-12-01'
  AND status = 3;
```

`EXPLAIN` 显示 `rows=1`，因为统计信息里这个时间段的基数被严重低估（订单表按天分区写入，统计信息停在月初）。

**修复**：

```sql
ANALYZE TABLE orders UPDATE HISTOGRAM ON status WITH 256 BUCKETS;
-- 或调整索引顺序：让高选择性的 status 参与索引
ALTER TABLE orders ADD INDEX idx_status_time (status, create_time);
```

修复后 `actual rows` 与估算接近，计划从"扫 80 万行再过滤"变成"扫 2.4 万行"。

### 案例二：join 顺序反了

```text
-> Nested loop inner join (actual rows=1 loops=1)
    -> Table scan on small_table (actual rows=200000 loops=1)   ← 驱动表选错
    -> Index lookup on big_table (actual rows=1 loops=200000)
```

优化器以为 `small_table` 只有 10 行，实际 20 万行，于是把它当驱动表，导致 20 万次回表。

**验证**：用 `STRAIGHT_JOIN` 强制顺序，如果变快，说明就是估算问题。

**修复**：更新统计信息 / 加直方图 / 必要时用 `/*+ JOIN_ORDER(...) */` 固定，但要写注释说明原因。

### 案例三：ORDER BY LIMIT 选错索引

```sql
SELECT * FROM orders WHERE user_id = 123 ORDER BY create_time DESC LIMIT 20;
```

优化器可能选 `idx_create_time`（以为能直接取前 20 行），实际要扫描大量行再过滤 `user_id`。

**修复**：建 `(user_id, create_time)` 联合索引，让"过滤 + 排序"在同一个索引里完成。

---

## 六、修复手段对比

| 手段 | 适用场景 | 生效速度 | 风险 |
|---|---|---|---|
| `ANALYZE TABLE` | 统计信息过期 | 快 | 大表采样耗 IO；会短暂影响计划 |
| 直方图 | 倾斜字段的等值/范围查询 | 快 | 只对部分谓词有效；需维护 |
| 调整索引 | 索引顺序/覆盖不匹配 | 需 DDL | 8.0 可用 ONLINE DDL，仍有负载 |
| 改写 SQL | 函数、隐式转换、OR | 快 | 需回归测试 |
| Optimizer Hint | 临时止血 | 快 | 硬编码计划，版本升级可能失效 |
| `STRAIGHT_JOIN` | join 顺序错误 | 快 | 强耦合表顺序，维护成本高 |
| 拆查询/汇总表 | 复杂聚合、报表 | 慢 | 增加数据一致性成本 |

**原则**：能用"统计信息 + 索引"解决的，不要用 hint；hint 是止痛药，不是治疗方案。每条 hint 都必须配注释和到期复查时间。

---

## 七、Java 侧工程化：把 EXPLAIN ANALYZE 变成巡检

### 7.1 MyBatis 慢 SQL 拦截器

```java
@Intercepts({
    @Signature(type = Executor.class, method = "query",
        args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class})
})
public class SlowSqlInterceptor implements Interceptor {

    private static final Logger log = LoggerFactory.getLogger(SlowSqlInterceptor.class);
    private static final long THRESHOLD_MS = 500;

    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        long start = System.nanoTime();
        try {
            return invocation.proceed();
        } finally {
            long costMs = (System.nanoTime() - start) / 1_000_000;
            if (costMs > THRESHOLD_MS) {
                MappedStatement ms = (MappedStatement) invocation.getArgs()[0];
                log.warn("slow sql id={} cost={}ms params={}",
                        ms.getId(), costMs, safeParams(invocation.getArgs()[1]));
            }
        }
    }

    private String safeParams(Object param) {
        // 生产上必须脱敏：手机号、身份证、地址
        return String.valueOf(param).replaceAll("1\\d{10}", "1**********");
    }
}
```

### 7.2 定时巡检（只读、限流、采样）

```java
@Component
public class PlanHealthChecker {

    private final JdbcTemplate jdbcTemplate;
    private final MeterRegistry registry;

    // 每 10 分钟抽查一条最贵的 digest，最多 1 条，避免给数据库添负担
    @Scheduled(fixedDelay = 600_000)
    public void checkTopDigest() {
        List<String> digests = jdbcTemplate.queryForList("""
            SELECT DIGEST_TEXT FROM performance_schema.events_statements_summary_by_digest
            WHERE SCHEMA_NAME = DATABASE() AND DIGEST_TEXT LIKE 'SELECT%'
            ORDER BY SUM_TIMER_WAIT DESC LIMIT 5
            """, String.class);

        for (String digest : digests) {
            try {
                String plan = jdbcTemplate.queryForObject("EXPLAIN ANALYZE " + digest, String.class);
                if (plan != null && plan.contains("rows=")) {
                    registry.counter("mysql.plan.checked").increment();
                }
            } catch (Exception e) {
                // digest 里的 ? 占位符不能直接执行，这里仅作示意：
                // 生产实现应基于 SQL 模板 + 采样参数，且限制在只读从库
                registry.counter("mysql.plan.check.failed").increment();
            }
        }
    }
}
```

这段代码有两个必须说明的工程约束：

1. **`DIGEST_TEXT` 里的 `?` 不能直接执行**，需要配套"参数采样表"（从慢日志里取真实参数）；
2. 必须跑在**只读从库**，且并发限制为 1，否则巡检本身会成为故障源。

### 7.3 CI 里做计划回归

```java
@Test
void orderQueryShouldNotFullScan() {
    String plan = jdbcTemplate.queryForObject(
        "EXPLAIN SELECT * FROM orders WHERE user_id = ? ORDER BY create_time DESC LIMIT 20",
        String.class, 1L);

    assertThat(plan).doesNotContain("type: ALL");
    assertThat(plan).containsIgnoringCase("idx_user_time");
}
```

在测试库上用**接近生产的数据分布**（至少百万行 + 倾斜数据）跑这类断言，可以拦住"某次加索引/改 SQL 导致计划退化"的回归。

---

## 八、踩坑清单

1. **`EXPLAIN ANALYZE` 会真实执行 SQL**。`UPDATE/DELETE` 千万别直接跑；对 `SELECT` 也要注意它可能扫全表，生产上先加 `LIMIT` 或放到从库。
2. **`LIMIT` 不一定能提前终止**。某些执行路径下 `EXPLAIN ANALYZE` 仍会算完整个结果集，别以为加了 `LIMIT 10` 就没开销。
3. **`ANALYZE TABLE` 会让计划短暂抖动**。刚分析完的几分钟内，缓存中的执行计划可能被重建，高峰期慎用。
4. **直方图不是万能的**。它只影响"选择率估算"，不改变索引可用性；对 `LIKE '%x%'` 依然无能为力。
5. **主从统计信息不一致**。从库的 `innodb_stats_persistent` 采样可能落后，导致"主库快、从库慢"。读写分离场景要单独验证从库计划。
6. **优化器 hint 的版本兼容性**。MySQL 8.0 的 hint 语法与 5.7 不同，升级大版本时务必回归所有 hint。

---

## 九、面试追问

**Q1：`EXPLAIN` 的 `rows` 和 `filtered` 是什么关系？**

`rows` 是该访问路径预估需要读取的行数，`filtered` 是这些行中满足剩余条件的百分比。两者相乘 ≈ 传给下一节点的行数。join 时优化器就是用这个乘积估算中间结果集大小。

**Q2：为什么 MySQL 会选错索引？**

本质是"成本估算错误"，来源有三类：统计信息不准（采样、过期）、成本模型失真（IO 代价常数与实际存储不匹配）、选择率假设错误（列独立、无直方图）。解决顺序是"先修数据统计，再改索引，最后才用 hint"。

**Q3：怎么判断一个执行计划"稳定"？**

看三点：`EXPLAIN` 的 `key` 在数据量增长后是否漂移；`actual rows` 与估算是否长期保持同一量级；是否有 `Using filesort`/`Using temporary` 随数据增长而出现。工程上用 CI 断言 + 慢日志回归来保障。

**Q4：索引下推（ICP）在 EXPLAIN 里怎么看？**

`Extra` 列出现 `Using index condition`。它表示 WHERE 中部分条件下推到存储引擎层过滤，减少回表次数。`EXPLAIN ANALYZE` 里可以看到 `Index range scan` 节点的 `actual rows` 明显小于扫描的索引条目数。

**Q5：为什么 `EXPLAIN ANALYZE` 显示的时间加起来和总耗时对不上？**

因为 `actual time` 是累计值且各节点有重叠（父节点包含子节点），同时不包括客户端网络传输、结果集序列化、以及 SQL 解析/优化阶段的时间。它衡量的是**执行器内部耗时**，不是端到端 RT。

---

## 总结

`EXPLAIN` 是"优化器以为的世界"，`EXPLAIN ANALYZE` 是"真实发生的事"。两者的差距，就是性能问题的藏身之处。

一套可复用的方法论：

1. 用 `performance_schema` 找最贵的 digest；
2. 用 `EXPLAIN FORMAT=TREE` 看估算与 join 顺序；
3. 用 `EXPLAIN ANALYZE` 找第一个 rows 偏差 > 10 倍的节点；
4. 用统计信息/直方图/索引修复根因；
5. 用 CI 断言 + 慢 SQL 巡检防回归。

把这五步固化成团队流程，比记住一百条"索引优化技巧"更有用。
