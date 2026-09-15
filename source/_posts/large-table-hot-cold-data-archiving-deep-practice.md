---
title: 【架构实战】大表冷热数据分离与历史归档深度实战：从 8 亿行单表到在线无损迁移
date: 2026-09-15 08:00:00
tags:
  - MySQL
  - 架构设计
  - 数据归档
  - 性能优化
categories:
  - 数据库
  - 系统设计
author: 东哥
---

# 【架构实战】大表冷热数据分离与历史归档深度实战：从 8 亿行单表到在线无损迁移

## 面试官：订单表 8 亿行，最近半年只有 5% 的数据被访问，你怎么处理？

这道题是「数据库架构」面试里最有区分度的一类——**它不是考某个知识点，而是考你有没有真正处理过「数据会一直长」这件事。**

大多数候选人的答案会停在「分库分表」。但分库分表解决的是**写入扩展**和**单表容量**，它不解决「90% 的数据其实没人看」这个根本问题。把 8 亿行均匀拆到 64 张表，每张还有 1250 万行，慢查询依然存在。

真正的答案是：**先把数据按「价值」分层，再对每层用不同的存储与访问策略。**

这篇文章完整讲清：冷热判定 → 分层存储选型 → 在线归档的工程实现 → 路由与查询改造 → 数据校验 → 生产事故复盘。

---

## 一、什么是冷热数据：先定义，再动手

「冷热」不是玄学，它有三个可量化的判定维度。

### 1.1 访问频率维度

这是最本质的维度。典型业务系统的数据访问呈**强幂律分布**：

| 数据年龄 | 占比（行） | 占比（查询量） | 归属 |
| --- | --- | --- | --- |
| 最近 7 天 | 2% | 约 65% | **热** |
| 7~30 天 | 5% | 约 25% | **温** |
| 30 天~6 个月 | 20% | 约 8% | **冷** |
| 6 个月以上 | 73% | 约 2% | **冰** |

**这张表是决策的核心依据**：如果 73% 的数据只贡献 2% 的查询，那它们占据的 Buffer Pool、索引空间、备份时间全都是浪费。

### 1.2 时间维度

时间是最容易落地的切分方式，因为它**单调、可预测、天然分区友好**。

### 1.3 业务状态维度

有些数据「新近产生但已经死亡」，有些「很久以前但仍需频繁访问」：

| 场景 | 状态特征 | 冷热判定 |
| --- | --- | --- |
| 订单 | 已完结 + 超过售后期（如 90 天） | 冷 |
| 订单 | 待支付/待发货/售后中 | **永远热**（无论多久） |
| 日志/埋点 | 按天产生，只用于统计 | 7 天后即冷 |
| 消息/IM | 最近会话热，历史会话按需拉取 | 按会话活跃度 |

**⚠️ 关键提醒**：**不能只按时间切！** 一个 200 天前的「待退款」订单如果被归档到冷库，用户点进去就查不到，直接是生产事故。**冷热判定必须是「时间 + 业务状态」的联合条件。**

---

## 二、方案选型：五种存储分层策略对比

| 方案 | 原理 | 优点 | 缺点 | 适用 |
| --- | --- | --- | --- | --- |
| **MySQL 分区表** | 同一张表按 Range 分区，冷数据在独立分区 | 应用**零改造**、DDL 秒级（DROP PARTITION） | 单机磁盘、分区数上限（8192）、跨分区查询仍扫多分区 | 中小规模、快速见效 |
| **归档表** | `orders_archive_2025` 等历史表，冷数据搬过去 | 实现简单、主表瘦身彻底 | 查询需应用层路由/UNION；归档过程复杂 | 最通用 |
| **分库分表** | 按时间路由到不同库/表 | 扩展性最好 | 改造成本高、跨片查询、事务复杂 | 海量写入 |
| **ES / ClickHouse** | 冷数据同步到搜索引擎/OLAP | 查询极快、支持多维分析 | **不是事务真相源**、同步链路复杂 | 报表、检索 |
| **对象存储（S3/OSS）** | 导出为 Parquet/CSV 冷备 | 成本极低（约为 DB 的 1/50） | 只能离线/按需回灌 | 合规留存、审计 |

### 2.1 组合策略才是生产答案

真实生产环境几乎从不用单一方案，标准组合是：

```text
热数据（7~30 天）   → MySQL 主库（InnoDB）
温数据（30~180 天） → MySQL 分区表的独立分区 / 归档表
冷数据（180 天~2 年）→ 只读实例（MySQL 归档库）
冰数据（2 年以上）   → 对象存储 Parquet + 按需回灌
```

**这个分层同时解决了四个问题**：

1. 主库体积可控 → Buffer Pool 命中率高、备份快、DDL 快
2. 冷数据仍在 MySQL 里 → 开发习惯不变，SQL 兼容
3. 归档成本低 → 只读实例规格低、对象存储极便宜
4. 合规可留痕 → 数据不删除，只搬走

---

## 三、MySQL 分区表：最快见效的方案

如果你的表还没到「必须拆库」的规模，**分区表是第一选择**——因为它对应用**完全透明**。

### 3.1 按时间 Range 分区

```sql
CREATE TABLE orders (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_no     VARCHAR(32)     NOT NULL,
  user_id      BIGINT UNSIGNED NOT NULL,
  status       TINYINT         NOT NULL COMMENT '0待支付 1已支付 2已完成 3已关闭',
  amount       DECIMAL(12,2)   NOT NULL,
  created_at   DATETIME        NOT NULL,
  finished_at  DATETIME        NULL,
  PRIMARY KEY (id, created_at),          -- ⚠️ 分区键必须包含在主键中
  KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB
PARTITION BY RANGE COLUMNS (created_at) (
  PARTITION p202601 VALUES LESS THAN ('2026-02-01'),
  PARTITION p202602 VALUES LESS THAN ('2026-03-01'),
  PARTITION p202603 VALUES LESS THAN ('2026-04-01'),
  -- ...
  PARTITION pmax VALUES LESS THAN (MAXVALUE)   -- ⚠️ 兜底分区，防止插入失败
);
```

### 3.2 ⚠️ 三条必须记住的分区表限制

**限制一：分区键必须包含在所有唯一索引（含主键）里**

```sql
-- ❌ 错误：主键是 id，分区键是 created_at，建表直接失败
PRIMARY KEY (id)  , PARTITION BY RANGE COLUMNS(created_at)

-- ✅ 正确：主键改为 (id, created_at)
PRIMARY KEY (id, created_at)
```

这是最常见的建表报错来源。**加 `created_at` 进主键的代价**是主键变长（8+5 字节），但换来分区剪枝能力，值得。

**限制二：必须有 `MAXVALUE` 兜底分区**

```sql
PARTITION pmax VALUES LESS THAN (MAXVALUE)
```

如果没有它，一旦有数据超出最后一个分区边界，**`INSERT` 会直接报错 `Table has no partition for value xxx`**——凌晨的写入直接失败。

**限制三：分区数有上限**

MySQL 单表最多 **8192 个分区**（8.0 之前是 1024）。按天分区 → 最多 22 年；按天分区的高频表建议**按周/按月**，避免分区数爆炸。

### 3.3 分区表的真正价值：秒级删除历史数据

这是分区表最爽的地方：

```sql
-- 常规大表删除 1 亿行历史数据
DELETE FROM orders WHERE created_at < '2025-01-01';
-- ⚠️ 会产生巨量 undo/redo、主从延迟、锁竞争，可能跑几十小时

-- 分区表：直接丢弃分区（元数据操作，秒级完成）
ALTER TABLE orders DROP PARTITION p202501;
```

**`DROP PARTITION` 的复杂度是 O(1)**——它只是把分区对应的 `.ibd` 文件从表空间解绑并删除，不逐行删除、不生成 undo。

**但注意**：`DROP PARTITION` 是**不可回滚的 DDL**，一旦执行数据就没了。务必：

1. 先 `SELECT COUNT(*)` 统计，与预期核对
2. 确认没有比该时间更早的「未完结」业务数据（回到第一节的「业务状态」判定）
3. 执行完立即检查 `SELECT COUNT(*) FROM orders PARTITION (pmax)`

---

## 四、在线归档：不锁表地把 5 亿行搬走

分区表能解决「删除」，但**归档（搬运）需要另一套机制**——因为你要把数据**复制**到归档表，而不是删掉。

### 4.1 绝对不能这么干

```sql
-- ❌ 生产事故三重奏
-- 1. 单条 SQL 涉及 5 亿行 → 超大事务 → undo 膨胀 → 主从延迟爆炸
-- 2. 长时间持有大量行锁 → 业务写入阻塞
-- 3. 一旦中断，全部回滚，几小时白干
INSERT INTO orders_archive SELECT * FROM orders WHERE created_at < '2025-01-01';
DELETE FROM orders WHERE created_at < '2025-01-01';
```

### 4.2 正确姿势：分批 + 主键游标 + 幂等

**核心思想：把大事务切成小事务，用主键做断点，用 `INSERT IGNORE`/`REPLACE` 保证幂等，可以随时中断随时续跑。**

```java
/**
 * 在线归档核心逻辑
 * 特点：分批、可中断、可续跑、幂等
 */
@Component
@Slf4j
public class OrderArchiver {

    private static final int BATCH_SIZE = 1000;
    private static final Duration SLEEP_BETWEEN_BATCH = Duration.ofMillis(50);

    @Autowired
    private OrderMapper orderMapper;

    @Autowired
    @Qualifier("archiveJdbcTemplate")
    private JdbcTemplate archiveJdbc;

    /**
     * 按主键范围归档
     * @param minId      起始主键（断点续传的起点）
     * @param beforeTime 归档边界时间
     */
    public ArchiveResult archive(long minId, LocalDateTime beforeTime) {
        long cursor = minId;
        long archived = 0;
        long lastId = orderMapper.selectMaxId();   // 一次查出当前最大 ID，作为终点
        long startedAt = System.currentTimeMillis();

        while (true) {
            // 1. 分批捞取（主键游标，绝不 OFFSET）
            List<Order> batch = orderMapper.selectBatchBeforeTime(cursor, beforeTime, BATCH_SIZE);
            if (batch.isEmpty()) {
                log.info("archive finished, cursor={}, total={}", cursor, archived);
                break;
            }

            // 2. 写入归档表（幂等：唯一键冲突忽略）
            int written;
            try {
                written = archiveJdbc.batchUpdate(INSERT_IGNORE_SQL, toArgs(batch));
            } catch (Exception e) {
                log.error("write archive failed at cursor={}", cursor, e);
                // 不推进 cursor，下次从同一位置重试
                throw e;
            }

            // 3. 主动删除主表数据（同一事务边界内独立提交）
            //    注意：先写归档、再删主表，失败时最多重复，不会丢
            int deleted = orderMapper.deleteByIds(batch.stream()
                    .map(Order::getId).toList());

            // 4. 推进游标
            cursor = batch.get(batch.size() - 1).getId();
            archived += batch.size();

            log.info("archived batch: cursor={}, size={}, written={}, deleted={}, elapsed={}ms",
                    cursor, batch.size(), written, deleted,
                    System.currentTimeMillis() - startedAt);

            // 5. 限速：给主从复制、业务写入留出余量
            sleepSafely(SLEEP_BETWEEN_BATCH);
        }

        return new ArchiveResult(cursor, archived);
    }

    private void sleepSafely(Duration d) {
        try {
            Thread.sleep(d.toMillis());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
```

对应的 Mapper SQL：

```xml
<!-- 主键游标 + 时间条件，走 (id) 主键索引，范围扫描 -->
<select id="selectBatchBeforeTime" resultType="Order">
    SELECT * FROM orders
    WHERE id &gt; #{cursor}
      AND created_at &lt; #{beforeTime}
      AND status IN (2, 3)          <!-- ⚠️ 只归档已完结/已关闭，业务状态过滤 -->
    ORDER BY id
    LIMIT #{batchSize}
</select>

<!-- 幂等删除 -->
<delete id="deleteByIds">
    DELETE FROM orders WHERE id IN
    <foreach collection="ids" item="id" open="(" separator="," close=")">
        #{id}
    </foreach>
</delete>
```

### 4.3 六个工程细节，每个都对应过线上事故

**细节一：为什么用主键游标不用 `OFFSET`？**

```sql
-- ❌ OFFSET 深分页：每批都要扫描并丢弃前面所有行，复杂度 O(n²)
SELECT * FROM orders WHERE created_at < ? ORDER BY id LIMIT 100000, 1000;

-- ✅ 主键游标：每次都是索引范围扫描，复杂度 O(n)
SELECT * FROM orders WHERE id > ? AND created_at < ? ORDER BY id LIMIT 1000;
```

**细节二：为什么要 `ORDER BY id`？**

不加 `ORDER BY` 时，`LIMIT` 返回的行在理论上是**无序**的，游标推进可能**漏掉或重复**数据。**必须显式按游标列排序。**

**细节三：为什么先写归档再删主表？**

顺序决定了故障后果：

- **先写后删**：中间崩溃 → 归档表有、主表也有 → 下次重跑幂等跳过 → **只重复，不丢失** ✅
- **先删后写**：中间崩溃 → 主表没了、归档也没写 → **数据永久丢失** ❌

**归档场景必须选择「宁可重复，不可丢失」。**

**细节四：为什么每批 sleep 50ms？**

这是**给主从复制留余量**。归档是写放大 2 倍的操作（写归档 + 删主表），如果全速跑，从库延迟会直接飙到几分钟甚至小时级。50ms × 1000 行/批 ≈ 2 万行/秒，是个平衡点。

更讲究的做法是**动态限速**：读 `SHOW SLAVE STATUS` 的 `Seconds_Behind_Master`，超过阈值就加大 sleep。

```java
private long adaptSleep() {
    Long lag = jdbc.queryForObject(
        "SELECT Seconds_Behind_Master FROM performance_schema.replication_applier_status_by_worker LIMIT 1",
        Long.class);
    if (lag == null || lag < 5)  return 20;
    if (lag < 30)                return 200;
    if (lag < 120)               return 1000;
    return 5000;   // 严重延迟，几乎暂停
}
```

**细节五：为什么需要 `SELECT MAX(id)` 作为终点？**

因为归档期间业务还在写入！如果只用「`created_at < beforeTime`」作为终止条件，而新写入的数据恰好 `created_at` 也满足（例如归档边界是「今天 0 点」但归档跑到了第二天），就会**边归档边追新数据，永远跑不完**（类似「影子的尾巴」问题）。

**用固定的 `maxId` 快照做边界，保证归档的是一个「有界集合」。** 边界之外的新数据由下一次归档处理。

**细节六：为什么删除要分批小事务？**

单批 1000 行的 `DELETE`，事务小、锁持有时间短（毫秒级）、undo 可控。**这是「不锁表」的关键。**

### 4.4 现成工具：pt-archiver

Percona Toolkit 的 `pt-archiver` 把上面这些事情做成了命令行工具：

```bash
pt-archiver \
  --source h=127.0.0.1,D=order_db,t=orders \
  --dest   h=127.0.0.1,D=order_archive,t=orders \
  --where "created_at < '2025-01-01' AND status IN (2,3)" \
  --limit 1000 \
  --commit-each \
  --purge \
  --sleep 0.05 \
  --max-lag 5 \
  --check-slave-lag h=127.0.0.1 \
  --statistics \
  --progress 10000
```

关键参数说明：

| 参数 | 作用 |
| --- | --- |
| `--limit 1000` | 每批行数 |
| `--commit-each` | 每批独立提交 **（必须加，否则回退到单大事务）** |
| `--purge` | 归档后从源表删除 |
| `--max-lag 5` | **从库延迟 > 5 秒就暂停**（最关键的参数） |
| `--check-slave-lag` | 指定要检查延迟的从库 |
| `--replace` / `--ignore` | 冲突处理，保证幂等 |

**但 `pt-archiver` 有两个坑**：

1. **`--where` 里的 `status` 过滤是「一次性」的**——它修改源表数据后，不满足条件的行不会被再次扫描，可能导致「归档不彻底」
2. 它默认按主键推进，如果表没有主键会失败

自研脚本（前面的 Java 版）在「可观测性、异常续跑、业务语义过滤、分库分表支持」上更可控，**规模化场景我倾向于自研。**

---

## 五、归档后的查询改造：应用层路由

数据搬走了，**查询怎么找到它**？这是比归档本身更难的部分。

### 5.1 方案一：双查 + 时间路由（推荐）

因为冷热边界是**时间**，路由逻辑可以极其简单：

```java
@Repository
public class OrderQueryRepository {

    private static final LocalDateTime HOT_COLD_BOUNDARY = ...;  // 或配置化

    @Autowired private OrderMapper hotMapper;
    @Autowired private OrderArchiveMapper coldMapper;

    public Order findByOrderNo(String orderNo, LocalDateTime createdAt) {
        if (createdAt.isAfter(HOT_COLD_BOUNDARY)) {
            Order o = hotMapper.findByOrderNo(orderNo);
            if (o != null) return o;
        }
        // 冷库兜底（可能是历史数据，也可能是边界配置漂移）
        return coldMapper.findByOrderNo(orderNo);
    }
}
```

**要点：调用方必须能拿到 `createdAt`。** 如果只有 `order_no`，走不到时间路由——所以**订单号最好内嵌时间信息**（如「yyyyMMdd + 序列」格式），或者维护一张 `order_no → created_date` 的轻量映射表。

### 5.2 方案二：ShardingSphere 自定义分片算法

如果冷热库是同一套逻辑表，可以用 ShardingSphere 把路由下沉：

```java
public class HotColdShardingAlgorithm implements StandardShardingAlgorithm<LocalDateTime> {

    private LocalDateTime boundary;

    @Override
    public String doSharding(Collection<String> availableTargetNames,
                             PreciseShardingValue<LocalDateTime> shardingValue) {
        LocalDateTime value = shardingValue.getValue();
        boolean isHot = value.isAfter(boundary);
        String suffix = isHot ? "hot" : "cold";
        return availableTargetNames.stream()
                .filter(name -> name.endsWith(suffix))
                .findFirst()
                .orElseThrow(() -> new IllegalStateException("no target for " + value));
    }
}
```

**优势**：SQL 层完全无感知，`SELECT * FROM orders WHERE created_at > ?` 自动路由。
**风险**：**边界值配置错误会导致「查错库、查不到」**——这类问题极难排查（因为 SQL 语法完全正确）。

### 5.3 方案三：不路由，直接 UNION / 联邦查询

只在**低频的管理后台、报表**场景用：

```sql
SELECT * FROM (
  SELECT order_no, user_id, amount, created_at FROM orders WHERE user_id = ?
  UNION ALL
  SELECT order_no, user_id, amount, created_at FROM orders_archive WHERE user_id = ?
) t ORDER BY created_at DESC LIMIT 20;
```

**成本**：两次查询 + 一次归并。**收益**：实现零改造。
**前提**：两张表都必须在 `(user_id, created_at)` 上有索引，否则归档库会全表扫。

**⚠️ 大忌**：**绝不要在交易链路上用 UNION 查冷库。** 冷库往往是低配只读实例，一次慢查询可能拖垮整个冷库，影响所有历史数据查询。

---

## 六、数据校验：怎么证明「一条没丢」

归档完成后必须校验，否则没人敢删原表。三层校验：

### 6.1 第一层：行数与主键集合

```sql
-- 归档前记录
SELECT COUNT(*), SUM(CRC32(CONCAT(id, '-', order_no, '-', amount))), MIN(id), MAX(id)
FROM orders WHERE created_at < '2025-01-01';

-- 归档后对归档表执行同样查询，逐项对比
SELECT COUNT(*), SUM(CRC32(CONCAT(id, '-', order_no, '-', amount))), MIN(id), MAX(id)
FROM orders_archive WHERE created_at < '2025-01-01';
```

**三个都要对**：行数、校验和、主键范围。只看行数会漏掉「A 记录重复、B 记录丢失」这种行数恰好相等的情况。

### 6.2 第二层：主键差集校验（最可靠）

```sql
-- 归档表里应该有的，源表里不应再有
SELECT COUNT(*) FROM orders o
LEFT JOIN orders_archive a ON a.id = o.id
WHERE o.created_at < '2025-01-01'
  AND o.status IN (2,3)
  AND a.id IS NULL;
-- 期望结果：0
```

这个查询依赖 `id` 上有索引，但在**只读从库**上跑没有任何风险。

### 6.3 第三层：抽样业务核对

随机抽 100 条归档记录，用业务接口（订单详情页）实际查询一遍，确认：

- 能查到
- 字段完整（金额、状态、时间）
- **关联数据也能查到**（订单明细、支付流水是否也一起归档了？）

**⚠️ 第三条最容易翻车**：主表归档了，但子表（`order_items`）没归档 → 用户点开历史订单发现「订单存在但明细为空」。**归档必须以「业务聚合根」为单位，而不是单表。**

### 6.4 校验不通过怎么办

**绝不删原表数据。** 归档脚本的设计原则是「先写归档，校验通过，再删原表」——上面代码里虽然把删除放在同批，但**生产环境更稳妥的做法是分两阶段**：

```text
阶段一：只归档，不删除（archive-only 模式）
   → 校验：行数、CRC、差集，全部通过
阶段二：开启删除（purge 模式），从断点继续
   → 删除前再次抽查
```

**代价是双写期间存储翻倍、写入放大，但这是「可回滚」的必要成本。**

---

## 七、一个真实事故的复盘

**背景**：某电商归档订单，脚本按「`created_at < 180 天前`」归档，跑了一晚上，归档 3.2 亿行。

**事故**：第二天客服爆量——用户查不到「去年买的、还在退款中的订单」。

**根因**：归档条件只有时间，**没有过滤业务状态**。那些「已完结但仍在售后」「已完成但有待处理工单」的订单被一起搬走了，而应用的查询路由只按 `created_at` 定位冷库——**偏偏冷库当时还没上索引**（归档表只建了主键），查询超时。

**三个错误叠加**：

1. 归档条件缺少业务状态过滤（设计错误）
2. 归档表缺少 `(user_id, created_at)` 索引（准备不足，见 5.3）
3. 没有分阶段（没做 archive-only 验证就删了源数据）

**修复**：

```sql
-- 1. 立即从备份把被误归档的未完结订单捞回来
INSERT INTO orders
SELECT * FROM orders_archive
WHERE status NOT IN (2, 3)
  AND created_at < '2025-01-01';
-- 配合唯一键冲突忽略，幂等恢复

-- 2. 补索引
ALTER TABLE orders_archive ADD INDEX idx_user_created (user_id, created_at);

-- 3. 归档条件加业务状态（永久修复）
-- WHERE created_at < ? AND status IN (2, 3) AND (finished_at IS NULL OR finished_at < ?)
```

**教训一句话**：**「时间」决定数据的冷热，「业务状态」决定数据的生死。归档条件必须同时满足两者。**

---

## 八、面试常见追问

**Q1：分区表和分库分表怎么选？**

先问三个问题：

1. 单表数据量是否超过 2 亿？（超过则分区表的单机磁盘/Buffer Pool 会先扛不住）
2. 写入 QPS 是否需要水平扩展？（分区表**不提升写入能力**，仍在单实例）
3. 是否已经需要跨库事务/多租户隔离？

**结论**：数据「大但访问集中」→ 分区表；「写入压力大」→ 分库分表；两者都需要 → 先分库分表，再在每片内部分区。

**Q2：`DROP PARTITION` 和 `DELETE` 的本质区别？**

- `DROP PARTITION` 是 **DDL**：操作元数据 + 删物理文件，**不写 undo/redo 行日志**，秒级完成，**不可回滚**
- `DELETE` 是 **DML**：逐行写 undo/redo，可回滚，但开销与行数线性相关

所以「按月分区 + 定期 DROP 老分区」是**日志类大表的最优删除方案**。

**Q3：归档期间业务还在写这些数据怎么办？**

三个手段配合：

1. **归档边界用固定快照**（`maxId`），不追逐新数据
2. **删除时加状态条件**：`DELETE ... WHERE id = ? AND status IN (2,3)`，如果业务把订单状态改成了「售后中」，删除就不会命中，**数据留在主表**
3. **归档后重扫**：下一轮归档前重新检查边界内是否还有未归档数据

**最关键的还是「业务状态过滤」——归档的判定条件必须是「数据已经不再变化」，而不只是「时间够久」。**

**Q4：冷库查询慢了怎么办？**

三层优化：

1. **索引**：冷库的索引策略和主库不同——**冷库查询模式是「按用户/订单号精确查」，不是「按时间范围扫」**，所以索引要围绕用户维度建
2. **只读实例扩容**：冷库是读多写零，可以挂多个只读副本做负载均衡
3. **降级**：冷数据查询允许更长的超时、允许走异步（「正在加载历史数据，请稍候」），甚至可以预热缓存

**Q5：为什么不用 ES 直接替代冷库？**

因为 **ES 不是真相源（Source of Truth）**。它没有事务、没有强一致、写入可能丢（refresh 前的数据不可见）。ES 适合做「检索和分析」，不适合做「唯一可查询的历史账本」。

**正确用法**：MySQL 冷库存真相，通过 Canal/Debezium 把冷数据同步到 ES 做**全文检索和多维分析**，两者职责分离。

**Q6：归档后如何保证冷数据的备份恢复？**

冷数据的备份策略应该和热数据**不同**：

- 热数据：物理备份 + binlog 增量，RPO 秒级
- 冷数据：**已完成归档 + 校验的数据是「稳定态」**，可以做低频全量备份（如每月一次），不需要 binlog 增量
- 冰数据（对象存储）：依赖对象存储的版本控制和跨区域复制

**核心逻辑：冷数据变更频率极低，因此备份成本可以大幅降低——这也是「分层」的价值体现。**

---

## 九、一句话总结

> 冷热分离的本质是**「按价值的存储分层」**，不是「把老数据删掉」。
>
> 落地顺序是：**先用「时间 + 业务状态」定义冷热边界 → 分区表最快见效 → 在线归档必须「主键游标 + 分批提交 + 先写后删 + 幂等续跑」 → 查询路由要按时间下沉 → 三层校验（行数/差集/抽样）通过才敢删**。
>
> 最重要的一条红线：**归档条件里没有业务状态过滤，就是给未来的自己埋事故。**
