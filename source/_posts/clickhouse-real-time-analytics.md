---
title: ClickHouse 实时分析数据库入门与架构实践
date: 2026-06-17 08:00:00
tags:
  - ClickHouse
  - 实时分析
  - OLAP
  - 数据库
  - 大数据
categories:
  - 数据库
author: 东哥
---

# ClickHouse 实时分析数据库入门与架构实践

> ClickHouse 是俄罗斯 Yandex 开源的列式存储数据库，专为**在线分析处理（OLAP）**场景设计。它以其极致的查询性能在海量数据实时分析领域独树一帜——单表查询性能是传统数据库的 100-1000 倍。本文将从架构原理到实战，带你全面掌握 ClickHouse。

## 一、ClickHouse 核心架构

### 1.1 列式存储 vs 行式存储

ClickHouse 最大的特点是**列式存储**，这与 MySQL/PostgreSQL 的行式存储有本质区别：

| 特性 | 列式存储 (ClickHouse) | 行式存储 (MySQL) |
|------|---------------------|-----------------|
| **数据布局** | 按列连续存储 | 按行连续存储 |
| **读取模式** | 只读取需要的列 | 读取整行 |
| **压缩率** | 极高（同类数据聚集） | 较低（混合数据类型） |
| **聚合查询** | 极快 | 慢 |
| **点查询** | 慢 | 极快 |
| **典型场景** | OLAP 分析 | OLTP 事务 |
| **写入方式** | 批量追加 | 随机写入 |

### 1.2 向量化执行引擎

ClickHouse 的另一个核心特点是**向量化执行**（Vectorized Execution）：

```sql
-- 传统逐行处理：一次处理一行
SELECT SUM(price) FROM orders WHERE status = 'completed';

-- ClickHouse 向量化处理：一次处理一批（如 1024 行）数据
-- CPU 利用 SIMD 指令集批量计算，减少循环开销
```

向量化执行的优势：
- **CPU 缓存友好**：批量数据处理提高缓存命中率
- **SIMD 指令优化**：利用 AVX2/SSE 等指令集并行计算
- **减少解释开销**：函数调用次数减少 1000 倍

### 1.3 架构设计

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   ClickHouse  │    │   ClickHouse  │    │   ClickHouse  │
│    Node 1     │    │    Node 2     │    │    Node 3     │
│  ┌──────────┐ │    │  ┌──────────┐ │    │  ┌──────────┐ │
│  │ Shard 1  │ │    │  │ Shard 2  │ │    │  │ Shard 3  │ │
│  │ ┌──────┐ │ │    │  │ ┌──────┐ │ │    │  │ ┌──────┐ │ │
│  │ │Replica│ │ │    │  │ │Replica│ │ │    │  │ │Replica│ │
│  │ └──────┘ │ │    │  │ └──────┘ │ │    │  │ └──────┘ │ │
│  └──────────┘ │    │  └──────────┘ │    │  └──────────┘ │
└──────────────┘    └──────────────┘    └──────────────┘
                          │
                    ┌─────┴─────┐
                    │   ZK/Keeper │
                    └───────────┘
```

## 二、MergeTree 引擎家族

### 2.1 MergeTree 核心原理

ClickHouse 最核心的表引擎是 **MergeTree** 及其变体。它的工作原理是：

1. **数据按主键排序**：生成有序的 `Part`（数据片段）
2. **后台合并**：后台线程将多个小 Part 合并成大 Part
3. **分区裁剪**：查询时跳过不相关的分区
4. **主键索引**：稀疏索引快速定位数据范围

```sql
-- 基础 MergeTree 表
CREATE TABLE orders (
    order_id    UInt64,
    user_id     UInt32,
    product_id  UInt32,
    amount      Decimal(10,2),
    status      String,
    create_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(create_time)
ORDER BY (create_time, order_id)
SETTINGS index_granularity = 8192;
```

### 2.2 引擎家族详解

| 引擎 | 特点 | 适用场景 |
|------|------|---------|
| **MergeTree** | 基础引擎，支持主键排序和分区 | 通用数据存储 |
| **ReplacingMergeTree** | 去重引擎，合并时按排序键去重 | 数据清洗、去重 |
| **SummingMergeTree** | 预聚合引擎，合并时聚合数值列 | 汇总统计、报表 |
| **AggregatingMergeTree** | 聚合状态引擎，存储聚合函数状态 | 物化视图底层 |
| **CollapsingMergeTree** | 折叠引擎，通过 sign 标记删除/更新 | 实时更改数据 |
| **VersionedCollapsingMergeTree** | 带版本的折叠引擎 | 有序版本数据 |
| **GraphiteMergeTree** | 专为 Graphite 监控数据设计 | 监控时序数据 |
| **Distributed** | 分布式引擎（逻辑表层） | 跨分片查询 |

### 2.3 引擎选择策略

```sql
-- ReplacingMergeTree：去重场景
CREATE TABLE user_log_unique (
    user_id     UInt32,
    event_time  DateTime,
    event_type  String,
    page_url    String
) ENGINE = ReplacingMergeTree(event_time)
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id);

-- SummingMergeTree：自动汇总
CREATE TABLE daily_sales (
    date        Date,
    product_id  UInt32,
    sales_count UInt32,
    sales_amount Decimal(12,2)
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, product_id);

-- CollapsingMergeTree：更新删除场景
CREATE TABLE user_points (
    user_id     UInt32,
    points      Int32,
    sign        Int8  -- 1=新增, -1=取消
) ENGINE = CollapsingMergeTree(sign)
ORDER BY (user_id);
```

## 三、分区、分片与副本

### 3.1 分区配置

分区是 ClickHouse 提升查询性能的关键手段：

```sql
-- 按天分区
CREATE TABLE events (
    event_id    UInt64,
    event_time  DateTime,
    event_data  String
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)  -- 每天一个分区
ORDER BY (event_time);

-- 按月分区
CREATE TABLE metrics (
    metric_name String,
    metric_time DateTime,
    metric_value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(metric_time)
ORDER BY (metric_name, metric_time);
```

### 3.2 副本配置

副本保证高可用，依赖 ZooKeeper 或 ClickHouse Keeper：

```sql
-- 创建带副本的表（需要配置 clickhouse_remote_servers）
CREATE TABLE orders_replicated ON CLUSTER cluster_3shards_2replicas (
    order_id   UInt64,
    amount     Decimal(10,2),
    create_time DateTime
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/orders',
    '{replica}'
)
PARTITION BY toYYYYMM(create_time)
ORDER BY (create_time);
```

### 3.3 分片配置

分片实现水平扩展，需要在配置文件中设置：

```xml
<!-- config.xml 分片配置 -->
<remote_servers>
    <cluster_3shards_2replicas>
        <shard>
            <replica>
                <host>clickhouse-01</host>
                <port>9000</port>
            </replica>
            <replica>
                <host>clickhouse-02</host>
                <port>9000</port>
            </replica>
        </shard>
        <shard>
            <replica>
                <host>clickhouse-03</host>
                <port>9000</port>
            </replica>
            <replica>
                <host>clickhouse-04</host>
                <port>9000</port>
            </replica>
        </shard>
    </cluster_3shards_2replicas>
</remote_servers>
```

```sql
-- 创建分布式表
CREATE TABLE orders_distributed ON CLUSTER cluster_3shards_2replicas
AS orders_local
ENGINE = Distributed(
    'cluster_3shards_2replicas',
    'default',
    'orders_local',
    rand()
);
```

## 四、数据导入方式

### 4.1 批量导入

```bash
# 从 CSV 文件导入
clickhouse-client --query "
    INSERT INTO orders FORMAT CSV
" < orders_data.csv

# 使用 HTTP 接口
curl -X POST 'http://localhost:8123/?query=INSERT+INTO+orders+FORMAT+CSV' \
    --data-binary @orders_data.csv
```

**Java 批量导入：**

```java
// 使用 JDBC 批量导入
try (Connection conn = DriverManager.getConnection(
        "jdbc:clickhouse://localhost:8123/default")) {
    
    String sql = "INSERT INTO orders (order_id, user_id, amount, status, create_time) VALUES (?, ?, ?, ?, ?)";
    
    PreparedStatement stmt = conn.prepareStatement(sql);
    
    // 批量提交 1000 条
    for (Order order : orders) {
        stmt.setLong(1, order.getOrderId());
        stmt.setInt(2, order.getUserId());
        stmt.setBigDecimal(3, order.getAmount());
        stmt.setString(4, order.getStatus());
        stmt.setString(5, order.getCreateTime());
        stmt.addBatch();
    }
    
    stmt.executeBatch();
}
```

### 4.2 Kafka 引擎表（实时写入）

```sql
-- 创建 Kafka 引擎表（消费 Kafka 消息）
CREATE TABLE orders_kafka (
    order_id    UInt64,
    user_id     UInt32,
    amount      Decimal(10,2),
    status      String,
    create_time DateTime
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka:9092',
    kafka_topic_list = 'orders',
    kafka_group_name = 'clickhouse_orders',
    kafka_format = 'JSONEachRow';

-- 创建物化视图，将 Kafka 数据写入 MergeTree
CREATE MATERIALIZED VIEW orders_consumer TO orders AS
SELECT * FROM orders_kafka;
```

### 4.3 实时写入优化

```sql
-- 异步批量写入配置
SETTINGS
    min_insert_block_size_rows = 1000000,     -- 最小写入块大小
    max_insert_block_size = 1000000,           -- 最大写入块大小
    async_insert = 1,                          -- 启用异步插入
    async_insert_threads = 4,                  -- 异步插入线程数
    async_insert_busy_timeout_ms = 200,        -- 等待时间
    async_insert_max_data_size = 10485760;     -- 最大缓冲大小 10MB
```

## 五、SQL 语法特色与优化技巧

### 5.1 特色函数

```sql
-- 数组函数
SELECT arrayJoin(['a', 'b', 'c']) AS item;

-- 聚合函数
SELECT 
    uniq(user_id) AS unique_users,          -- 近似去重
    uniqExact(user_id) AS exact_users,      -- 精确去重
    quantile(0.99)(amount) AS p99_amount,   -- P99 分位数
    avg(amount) AS avg_amount,
    topK(10)(product_id) AS top_products    -- Top K
FROM orders;

-- 时序分析
SELECT 
    neighbor(amount, -1) AS prev_amount,    -- 上一行
    runningDifference(amount) AS diff,      -- 差值
    cumulativeSum(amount) AS running_total  -- 累计和
FROM orders ORDER BY create_time;
```

### 5.2 查询优化技巧

```sql
-- 1️⃣ 预过滤条件，先筛选再 JOIN
SELECT *
FROM orders
WHERE create_time >= '2026-06-01'
  AND create_time < '2026-06-02'
  AND amount > 100;

-- 2️⃣ 使用 PREWHERE 提前过滤
SELECT *
FROM orders
PREWHERE status = 'completed'
WHERE create_time >= '2026-06-01';

-- 3️⃣ 避免 SELECT *，只取需要的列
SELECT order_id, amount FROM orders;

-- 4️⃣ 用 if/transform 替代 case when
SELECT 
    transform(status,
        ['pending','processing','completed','cancelled'],
        ['待付款','处理中','已完成','已取消'],
        '未知') AS status_cn
FROM orders;

-- 5️⃣ 用 groupBitmap 加速精确去重
SELECT 
    groupBitmap(user_id) AS exact_uv
FROM orders;
```

## 六、物化视图实战

### 6.1 基本物化视图

```sql
-- 创建物化视图：按天汇总销售额
CREATE MATERIALIZED VIEW daily_sales_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(stat_date)
ORDER BY (stat_date, product_id)
AS SELECT
    toDate(create_time) AS stat_date,
    product_id,
    count() AS order_count,
    sum(amount) AS total_amount,
    uniqExact(user_id) AS user_count
FROM orders
GROUP BY stat_date, product_id;
```

### 6.2 物化视图的增量更新

```sql
-- 创建物化视图：实时计算用户行为漏斗
CREATE MATERIALIZED VIEW funnel_analysis_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_step)
AS SELECT
    toDate(event_time) AS event_date,
    event_type AS event_step,
    uniqState(user_id) AS user_set,
    countState() AS event_count
FROM user_events
GROUP BY event_date, event_step;

-- 查询漏斗数据
SELECT
    event_date,
    event_step,
    uniqMerge(user_set) AS unique_users,
    countMerge(event_count) AS total_events
FROM funnel_analysis_mv
GROUP BY event_date, event_step
ORDER BY event_date, event_step;
```

### 6.3 物化视图 vs 直接查询

| 对比维度 | 物化视图 | 直接查询 |
|---------|---------|---------|
| **查询速度** | ⚡ 毫秒级 | 🐢 秒级到分钟级 |
| **数据实时性** | 秒级延迟 | 实时 |
| **存储开销** | 额外占用 20-50% 空间 | 无额外开销 |
| **维护成本** | 需关注视图状态 | 无 |
| **灵活性** | 固定聚合维度 | 自由查询 |
| **推荐场景** | 固定报表、Dashboard | 临时分析、Ad-hoc 查询 |

## 七、性能调优

### 7.1 索引优化

```sql
-- 跳数索引（Skip Index）
CREATE TABLE events_optimized (
    event_id   UInt64,
    event_time DateTime,
    user_id    UInt32,
    event_data String,
    INDEX idx_user_id (user_id) TYPE minmax GRANULARITY 4,
    INDEX idx_event_time (toDate(event_time)) TYPE minmax GRANULARITY 4,
    INDEX idx_event_data (event_data) TYPE tokenbf_v1(256, 2, 0) GRANULARITY 1
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)
SETTINGS index_granularity = 8192;
```

| 索引类型 | 适用场景 | 说明 |
|---------|---------|------|
| **minmax** | 范围查询 | 记录粒度组内的最大最小值 |
| **set** | 枚举值过滤 | 记录粒度组内的唯一值集合 |
| **ngrambf_v1** | 模糊搜索 | n-gram 布隆过滤器 |
| **tokenbf_v1** | 分词搜索 | 分词布隆过滤器 |
| **bloom_filter** | 任意等值判断 | 通用布隆过滤器 |

### 7.2 TTL 配置

```sql
-- 设置 TTL：数据过期自动删除
CREATE TABLE logs_ttl (
    log_time   DateTime,
    level      String,
    message    String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(log_time)
ORDER BY (log_time)
TTL log_time + INTERVAL 30 DAY DELETE;

-- TTL：数据冷热分层
ALTER TABLE logs_ttl
MODIFY TTL 
    log_time + INTERVAL 7 DAY TO VOLUME 'cold_storage',
    log_time + INTERVAL 30 DAY DELETE;
```

### 7.3 压缩配置

```sql
-- 列级压缩策略
CREATE TABLE logs_compressed (
    log_time   DateTime CODEC(DoubleDelta, LZ4),
    level      LowCardinality(String) CODEC(ZSTD(3)),
    user_id    UInt32 CODEC(LZ4HC(9)),
    message    String CODEC(ZSTD(1))
) ENGINE = MergeTree()
ORDER BY (log_time);
```

| 压缩算法 | 压缩比 | 压缩速度 | 解压速度 | 推荐场景 |
|---------|-------|---------|---------|---------|
| **LZ4** | 2-3x | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | 日志数据、时序数据 |
| **ZSTD** | 3-5x | ⭐⭐⭐ | ⭐⭐⭐⭐ | 文本数据、IL数据 |
| **LZ4HC** | 3-4x | ⭐⭐ | ⭐⭐⭐⭐⭐ | 冷数据、不频繁写入列 |
| **DoubleDelta** | 3-6x | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | 时序数值列 |

## 八、与 MySQL / Elasticsearch 对比

| 特性 | ClickHouse | MySQL | Elasticsearch |
|------|-----------|-------|---------------|
| **存储模型** | 列式 | 行式 | 倒排索引 |
| **查询类型** | OLAP 聚合分析 | OLTP 事务处理 | 全文搜索 |
| **单表 10 亿行聚合** | 毫秒~秒级 | 分钟~小时级 | 秒~十秒级 |
| **写入吞吐** | 50-200MB/s | 1-5MB/s | 10-30MB/s |
| **压缩率** | 5-10x | 2-3x | 1-2x |
| **事务支持** | ❌ 不支持 | ✅ 完整 ACID | ❌ 不支持 |
| **JOIN 能力** | 弱（大表不宜 JOIN） | 强 | 弱 |
| **全文搜索** | 弱 | 中等 | 极强 |
| **运维复杂度** | 中等 | 低 | 高 |
| **典型场景** | BI 报表、日志分析、实时大屏 | 业务系统、交易记录 | 站内搜索、日志搜索 |

**选型建议：**
- **需要实时 OLAP 分析** → ClickHouse
- **需要事务处理** → MySQL
- **需要全文搜索** → Elasticsearch
- **日志分析 + 搜索** → ClickHouse + ES 组合

## 九、Spring Boot 集成 ClickHouse

### 9.1 依赖配置

```xml
<dependency>
    <groupId>com.clickhouse</groupId>
    <artifactId>clickhouse-jdbc</artifactId>
    <version>0.4.6</version>
</dependency>
```

```yaml
# application.yml
spring:
  datasource:
    clickhouse:
      jdbc-url: jdbc:clickhouse://localhost:8123/default
      driver-class-name: com.clickhouse.jdbc.ClickHouseDriver
      username: default
      password:
```

### 9.2 数据源配置

```java
@Configuration
public class ClickHouseConfig {
    
    @Bean
    @ConfigurationProperties(prefix = "spring.datasource.clickhouse")
    public DataSource clickhouseDataSource() {
        return DataSourceBuilder.create().build();
    }
    
    @Bean
    public JdbcTemplate clickhouseJdbcTemplate(DataSource clickhouseDataSource) {
        return new JdbcTemplate(clickhouseDataSource);
    }
}
```

### 9.3 DAO 层实现

```java
@Repository
public class OrderAnalysisDao {
    
    @Autowired
    @Qualifier("clickhouseJdbcTemplate")
    private JdbcTemplate clickhouseTemplate;
    
    /**
     * 查询最近7天每日销售额
     */
    public List<DailySalesDTO> getDailySales(LocalDate startDate, LocalDate endDate) {
        String sql = """
            SELECT 
                toDate(create_time) AS stat_date,
                count() AS order_count,
                sum(amount) AS total_amount,
                uniqExact(user_id) AS user_count
            FROM orders
            WHERE create_time >= ? AND create_time < ?
            GROUP BY stat_date
            ORDER BY stat_date
        """;
        
        return clickhouseTemplate.query(sql,
            new BeanPropertyRowMapper<>(DailySalesDTO.class),
            startDate, endDate.plusDays(1));
    }
    
    /**
     * 实时销售大屏数据
     */
    public RealtimeDashboardDTO getRealtimeDashboard() {
        String sql = """
            SELECT
                count() AS total_orders,
                sum(amount) AS total_amount,
                uniqExact(user_id) AS total_users,
                countIf(status = 'pending') AS pending_orders,
                countIf(status = 'completed') AS completed_orders
            FROM orders
            WHERE create_time >= now() - INTERVAL 5 MINUTE
        """;
        
        return clickhouseTemplate.queryForObject(sql,
            new BeanPropertyRowMapper<>(RealtimeDashboardDTO.class));
    }
}
```

### 9.4 批量写入优化

```java
@Service
public class ClickHouseBatchService {
    
    @Autowired
    @Qualifier("clickhouseDataSource")
    private DataSource clickhouseDataSource;
    
    private static final int BATCH_SIZE = 50000;
    
    /**
     * 批量写入订单数据（推荐使用原生格式写入）
     */
    public void batchInsertOrders(List<Order> orders) {
        try (Connection conn = clickhouseDataSource.getConnection()) {
            String sql = "INSERT INTO orders (order_id, user_id, amount, status, create_time) VALUES (?, ?, ?, ?, ?)";
            
            try (PreparedStatement stmt = conn.prepareStatement(sql)) {
                int count = 0;
                for (Order order : orders) {
                    stmt.setLong(1, order.getOrderId());
                    stmt.setInt(2, order.getUserId());
                    stmt.setBigDecimal(3, order.getAmount());
                    stmt.setString(4, order.getStatus());
                    stmt.setObject(5, order.getCreateTime());
                    stmt.addBatch();
                    
                    if (++count % BATCH_SIZE == 0) {
                        stmt.executeBatch();
                        log.info("已写入 {} 条订单数据", count);
                    }
                }
                stmt.executeBatch(); // 写入剩余数据
            }
        } catch (SQLException e) {
            log.error("批量写入 ClickHouse 失败", e);
            throw new RuntimeException(e);
        }
    }
}
```

## 十、总结

ClickHouse 作为一款顶级的 OLAP 数据库，在以下场景中表现尤为出色：

1. **实时大屏**：秒级刷新海量数据聚合
2. **BI 报表**：千亿级数据秒级查询
3. **日志分析**：高效存储和检索结构化和半结构化日志
4. **用户行为分析**：精准用户画像和漏斗分析
5. **监控指标**：Prometheus 长期存储替代方案

但也要注意它不适合的场景：事务处理、单行点查、高频小批量更新。

掌握 ClickHouse，就是掌握大数据实时分析的核心能力。建议从 MergeTree 引擎入手，结合物化视图和分区策略，逐步构建你的实时分析平台。
