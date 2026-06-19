---
title: Apache Flink 流式计算入门与实时处理实践
date: 2026-06-17 10:00:00
tags:
  - Flink
  - 流式计算
  - 实时处理
  - Flink SQL
  - Checkpoint
  - 状态管理
categories:
  - 大数据
author: 东哥
---

# Apache Flink 流式计算入门与实时处理实践

## 一、引言

在大数据时代，数据的价值随着时间递减。传统 Lambda 架构（批处理 + 流处理）面临维护两套代码、数据口径不一致的痛点。Apache Flink 作为新一代流式计算引擎，凭借**真正的流式处理**、**Exactly-Once 语义**和**卓越的容错机制**，已成为实时计算领域的首选。

本文将系统介绍 Flink 的架构设计与核心概念，通过 DataStream API 和 Flink SQL 两种编程模型演示实时处理实战，深入讲解时间语义、状态管理、Checkpoint 机制、Exactly-Once 保证以及与 Kafka 的集成方案。

## 二、Flink 架构与核心概念

### 2.1 Flink 整体架构

```
          Client
            │
            ▼
     ┌──────────────┐
     │  JobManager  │ (Master - 调度、协调)
     └──────┬───────┘
            │
    ┌───────┴───────┐
    │               │
    ▼               ▼
┌────────┐   ┌────────┐
│ TaskMgr│   │ TaskMgr│  ...  (Worker - 执行任务)
│ Slot 1 │   │ Slot 1 │
│ Slot 2 │   │ Slot 2 │
└────────┘   └────────┘
```

| 组件 | 职责 | 高可用方案 |
|------|------|-----------|
| JobManager | 作业调度、Checkpoint 协调、故障恢复 | Active-Standby (ZooKeeper/K8s) |
| TaskManager | 执行作业的任务槽（Slot） | 多个 TaskManager 互为备份 |
| ResourceManager | 管理 Slot 资源分配 | YARN / K8s / Standalone |
| Dispatcher | REST API、Web UI、提交作业 | 可多实例部署 |

### 2.2 核心概念

**DataStream**：Flink 中所有数据都是流（有界流 = 批，无界流 = 实时）。Flink 的统一处理模型是 DataStream API 和 Table API 的基石。

**并行度（Parallelism）**：每个算子可以并行运行在多个 TaskManager 的 Slot 上。

```java
// 设置全局并行度
env.setParallelism(4);

// 设置算子级并行度
dataStream.map(new MyMapper()).setParallelism(2);

// 设置 Sink 并行度
dataStream.addSink(new MySink()).setParallelism(1);
```

**算子链（Operator Chains）**：Flink 默认会将相邻的算子合并到一个线程中执行，减少序列化和网络传输开销。

```java
// 禁用算子链
dataStream.map(new MyMapper()).disableChaining();

// 开启新链
dataStream.map(new MyMapper()).startNewChain();
```

### 2.3 编程模型对比

| 维度 | DataStream API | Flink SQL / Table API |
|------|---------------|----------------------|
| 抽象层级 | 低（算子级） | 高（SQL 声明式） |
| 开发效率 | 低，需手写逻辑 | 高，一行 SQL 解决 |
| 表达能力 | 极强，可自定义算子 | 受 SQL 标准限制 |
| 复杂度 | 高 | 低 |
| 调试难度 | 中 | 低 |
| 适用场景 | 复杂业务逻辑、自定义状态 | 简单 ETL、聚合、Join |
| 社区趋势 | 成熟稳定 | 快速增长 |

**选型建议**：能用 SQL 解决的优先用 SQL，复杂逻辑用 DataStream API 封装成 UDF。

## 三、DataStream API 实战

### 3.1 Maven 依赖

```xml
<properties>
    <flink.version>1.20.0</flink.version>
    <scala.binary.version>2.12</scala.binary.version>
</properties>

<dependencies>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-streaming-java</artifactId>
        <version>${flink.version}</version>
    </dependency>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-clients</artifactId>
        <version>${flink.version}</version>
    </dependency>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-connector-kafka</artifactId>
        <version>${flink.version}</version>
    </dependency>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-json</artifactId>
        <version>${flink.version}</version>
    </dependency>
</dependencies>
```

### 3.2 实时订单统计案例

```java
import org.apache.flink.api.common.eventtime.*;
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.api.java.tuple.Tuple3;
import org.apache.flink.streaming.api.TimeCharacteristic;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.windowing.time.Time;
import org.apache.flink.streaming.api.windowing.assigners.TumblingEventTimeWindows;
import org.apache.flink.streaming.connectors.kafka.FlinkKafkaConsumer;
import org.apache.flink.streaming.connectors.elasticsearch7.ElasticsearchSink;
import org.apache.flink.streaming.connectors.kafka.FlinkKafkaProducer;

import java.time.Duration;
import java.util.Properties;

public class RealtimeOrderStatistics {

    public static void main(String[] args) throws Exception {
        // 1. 创建执行环境
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(4);
        env.enableCheckpointing(Duration.ofSeconds(10));
        env.getCheckpointConfig().setCheckpointingMode(CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(Duration.ofSeconds(5));
        env.getCheckpointConfig().setCheckpointTimeout(Duration.ofMinutes(1));

        // 2. Kafka Source
        Properties kafkaProps = new Properties();
        kafkaProps.setProperty("bootstrap.servers", "kafka-01:9092,kafka-02:9092");
        kafkaProps.setProperty("group.id", "flink-order-stat-group");
        kafkaProps.setProperty("auto.offset.reset", "latest");
        kafkaProps.setProperty("enable.auto.commit", "false"); // Flink 自行管理 offset

        DataStream<String> rawStream = env.addSource(new FlinkKafkaConsumer<>(
            "order-events",
            new SimpleStringSchema(),
            kafkaProps
        ));

        // 3. 解析 JSON → Order POJO
        DataStream<Order> orderStream = rawStream
            .map(value -> JsonUtils.parseObject(value, Order.class))
            .name("parse-json")
            .returns(Order.class);

        // 4. 提取事件时间
        DataStream<Order> watermarkedStream = orderStream
            .assignTimestampsAndWatermarks(
                WatermarkStrategy.<Order>forBoundedOutOfOrderness(Duration.ofSeconds(10))
                    .withTimestampAssigner((order, timestamp) -> order.getEventTime())
            );

        // 5. 每 1 分钟滚动窗口统计各品类销售额
        DataStream<CategoryRevenue> categoryRevenue = watermarkedStream
            .keyBy(Order::getCategoryId)
            .window(TumblingEventTimeWindows.of(Time.minutes(1)))
            .aggregate(new RevenueAggregator())
            .name("category-revenue-window");

        // 6. Sink 到 Kafka (结果明细) + Elasticsearch (汇总)
        categoryRevenue.addSink(new FlinkKafkaProducer<>(
            "category-revenue-result",
            new SimpleStringSchema(),
            kafkaProps
        )).name("kafka-sink");

        // Sink 到 ES
        categoryRevenue.addSink(createEsSink()).name("es-sink");

        // 7. 执行
        env.execute("RealtimeOrderStatistics");
    }

    private static ElasticsearchSink<CategoryRevenue> createEsSink() {
        // ES Sink 配置（略）
        return null;
    }
}
```

### 3.3 常用算子分类

| 分类 | 算子 | 说明 |
|------|------|------|
| **输入** | `addSource` | 添加数据源（Kafka、Socket、文件等） |
| **转换** | `map` | 一对一转换 |
| | `flatMap` | 一对多转换（如分词） |
| | `filter` | 过滤 |
| | `keyBy` | 按键分区（等价于 SQL 的 GROUP BY） |
| | `reduce` | 滚动聚合 |
| | `process` | 最灵活的算子，可访问时间和状态 |
| **窗口** | `window` | 分组窗口（Tumbling/Sliding/Session） |
| | `windowAll` | 全局窗口（不分组） |
| | `apply` | 窗口函数 |
| **输出** | `addSink` | 输出到外部系统 |
| | `print` | 控制台打印（调试用） |
| **多流** | `union` | 合并多个同类型流 |
| | `connect` | 连接两个不同类型流 |
| | `coGroup` | cogroup 操作 |
| | `join` | 窗口 Join |
| | `intervalJoin` | 时间区间 Join |

### 3.4 ProcessFunction 详解

ProcessFunction 是 DataStream API 中最灵活的算子，可以访问**事件**、**状态**和**定时器**：

```java
public class OrderTimeoutAlertFunction
        extends KeyedProcessFunction<Long, Order, Alert> {

    // 处理中状态
    private ValueState<Boolean> paidState;
    private ValueState<Long> timerState;

    @Override
    public void open(Configuration parameters) {
        paidState = getRuntimeContext().getState(
            new ValueStateDescriptor<>("paidState", Types.BOOLEAN));
        timerState = getRuntimeContext().getState(
            new ValueStateDescriptor<>("timerState", Types.LONG));
    }

    @Override
    public void processElement(
            Order order,
            Context ctx,
            Collector<Alert> out) throws Exception {

        if ("CREATE".equals(order.getStatus())) {
            // 设置 30 分钟超时定时器
            long timeoutTime = ctx.timestamp() + 30 * 60 * 1000L;
            ctx.timerService().registerEventTimeTimer(timeoutTime);
            timerState.update(timeoutTime);

        } else if ("PAID".equals(order.getStatus())) {
            // 已支付，取消定时器
            Long timer = timerState.value();
            if (timer != null) {
                ctx.timerService().deleteEventTimeTimer(timer);
            }
            paidState.update(true);
        }
    }

    @Override
    public void onTimer(
            long timestamp,
            OnTimerContext ctx,
            Collector<Alert> out) throws Exception {

        // 定时器触发 → 订单超时未支付
        Boolean paid = paidState.value();
        if (paid == null || !paid) {
            out.collect(new Alert(
                ctx.getCurrentKey(),
                "订单超时未支付",
                timestamp
            ));
        }
    }
}
```

## 四、Flink SQL 实战

### 4.1 在 DataStream 中执行 Flink SQL

```java
import org.apache.flink.table.api.*;
import org.apache.flink.table.api.bridge.java.StreamTableEnvironment;

public class FlinkSqlExample {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        StreamTableEnvironment tableEnv = StreamTableEnvironment.create(env);

        // 1. 定义 Kafka Source Table（Flink SQL DDL）
        tableEnv.executeSql(
            "CREATE TABLE order_events (" +
            "  order_id BIGINT," +
            "  user_id BIGINT," +
            "  category_id INT," +
            "  amount DECIMAL(10, 2)," +
            "  event_time TIMESTAMP(3) METADATA FROM 'timestamp'," +
            "  WATERMARK FOR event_time AS event_time - INTERVAL '10' SECOND" +
            ") WITH (" +
            "  'connector' = 'kafka'," +
            "  'topic' = 'order-events'," +
            "  'properties.bootstrap.servers' = 'kafka-01:9092'," +
            "  'properties.group.id' = 'flink-sql-group'," +
            "  'scan.startup.mode' = 'latest-offset'," +
            "  'format' = 'json'," +
            "  'json.fail-on-missing-field' = 'true'," +
            "  'json.ignore-parse-errors' = 'false'" +
            ")"
        );

        // 2. 定义 Kafka Sink Table
        tableEnv.executeSql(
            "CREATE TABLE category_revenue (" +
            "  category_id INT," +
            "  window_start TIMESTAMP(3)," +
            "  window_end TIMESTAMP(3)," +
            "  total_amount DECIMAL(12, 2)," +
            "  order_count BIGINT" +
            ") WITH (" +
            "  'connector' = 'kafka'," +
            "  'topic' = 'category-revenue'," +
            "  'properties.bootstrap.servers' = 'kafka-01:9092'," +
            "  'format' = 'json'" +
            ")"
        );

        // 3. Flink SQL 计算 —— 每分钟滚动窗口聚合
        tableEnv.executeSql(
            "INSERT INTO category_revenue " +
            "SELECT " +
            "  category_id," +
            "  TUMBLE_START(event_time, INTERVAL '1' MINUTE) AS window_start," +
            "  TUMBLE_END(event_time, INTERVAL '1' MINUTE) AS window_end," +
            "  SUM(amount) AS total_amount," +
            "  COUNT(*) AS order_count " +
            "FROM order_events " +
            "GROUP BY " +
            "  TUMBLE(event_time, INTERVAL '1' MINUTE)," +
            "  category_id"
        );

        env.execute("FlinkSQL Static Order Statistics");
    }
}
```

### 4.2 Flink SQL 常用语法

```sql
-- 1. 创建源表
CREATE TABLE page_views (
    user_id BIGINT,
    page_url STRING,
    view_time TIMESTAMP(3),
    duration INT,
    WATERMARK FOR view_time AS view_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'page-views',
    'properties.bootstrap.servers' = 'localhost:9092',
    'properties.group.id' = 'test-group',
    'format' = 'json'
);

-- 2. 创建结果表（MySQL）
CREATE TABLE user_stats (
    user_id BIGINT PRIMARY KEY NOT ENFORCED,
    page_count BIGINT,
    sum_duration BIGINT,
    last_view TIMESTAMP(3)
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://localhost:3306/flink',
    'table-name' = 'user_page_stats',
    'username' = 'root',
    'password' = 'password'
);

-- 3. 滚动窗口聚合
INSERT INTO user_stats
SELECT
    user_id,
    COUNT(*) AS page_count,
    SUM(duration) AS sum_duration,
    TUMBLE_END(view_time, INTERVAL '1' MINUTE) AS last_view
FROM page_views
GROUP BY user_id, TUMBLE(view_time, INTERVAL '1' MINUTE);

-- 4. 滑动窗口
SELECT
    user_id,
    COUNT(*) AS page_count
FROM page_views
GROUP BY
    user_id,
    HOP(view_time, INTERVAL '1' MINUTE, INTERVAL '10' MINUTE);

-- 5. 会话窗口
SELECT
    user_id,
    COUNT(*) AS page_count
FROM page_views
GROUP BY
    user_id,
    SESSION(view_time, INTERVAL '5' MINUTE);

-- 6. Over 窗口（累计值）
SELECT
    page_url,
    view_time,
    COUNT(*) OVER (
        PARTITION BY page_url
        ORDER BY view_time
        RANGE BETWEEN INTERVAL '1' HOUR PRECEDING AND CURRENT ROW
    ) AS hourly_views
FROM page_views;

-- 7. 关联 Dimension 表
SELECT
    o.*,
    u.user_name,
    u.city
FROM order_events AS o
LEFT JOIN users FOR SYSTEM_TIME AS OF o.proc_time AS u
ON o.user_id = u.user_id;
```

### 4.3 Flink SQL 与 DataStream API 的融合

```java
// Table → DataStream
Table resultTable = tableEnv.sqlQuery("SELECT user_id, COUNT(*) AS cnt FROM page_views GROUP BY user_id");

// 转成 ChangeLogStream（需要外部处理撤回事件）
DataStream<Row> resultStream = tableEnv.toChangelogStream(resultTable);

// 转成 Retract 流
DataStream<Tuple2<Boolean, Row>> retractStream = tableEnv.toRetractStream(resultTable, Row.class);

// DataStream → Table
DataStream<Order> orderStream = env.addSource(kafkaSource);
Table orderTable = tableEnv.fromDataStream(orderStream, Schema.newBuilder()
    .columnByExpression("proctime", "PROCTIME()")
    .columnByExpression("rowtime", "CAST(event_time AS TIMESTAMP(3))")
    .watermark("rowtime", "rowtime - INTERVAL '10' SECOND")
    .build());
tableEnv.createTemporaryView("orders", orderTable);
```

## 五、时间语义与 Watermark

### 5.1 三种时间语义

| 时间类型 | 含义 | 特点 | 用例 |
|----------|------|------|------|
| Event Time | 事件实际发生时间 | 准确、受乱序影响 | 金融交易、订单统计 |
| Ingestion Time | 进入 Flink 的时间 | 介于两者之间 | 常规日志处理 |
| Processing Time | 算子处理时间 | 最快但不准确 | 实时监控报警 |

**推荐**：业务场景一律使用 Event Time + Watermark，保证结果准确性。

### 5.2 Watermark 机制

Watermark 是解决乱序问题的核心机制，表示"这个时间戳之前的数据已经到齐"。

```
事件时间轴（带乱序）：
[10:00:01] [10:00:02] [10:00:00 ←乱序] [10:00:04] [10:00:05]

Watermark 推进：
10:00:01 → WM=09:59:51 (BoundedOutOfOrderness=10s)
10:00:02 → WM=09:59:52
10:00:00 → WM=09:59:52 (收到但已落后)
10:00:04 → WM=09:59:54
10:00:05 → WM=09:59:55

WM = max(event_time) - maxOutOfOrderness
```

```java
// 三种 Watermark 生成策略

// 1. 固定延迟
WatermarkStrategy.forBoundedOutOfOrderness(Duration.ofSeconds(10));

// 2. 单调递增（无乱序）
WatermarkStrategy.forMonotonousTimestamps();

// 3. 自定义
WatermarkStrategy.<Order>forGenerator((ctx) -> new WatermarkGenerator<Order>() {
    private long maxTimestamp = Long.MIN_VALUE;
    private final long maxDelay = 10000L; // 10秒

    @Override
    public void onEvent(Order event, long eventTimestamp, WatermarkOutput output) {
        maxTimestamp = Math.max(maxTimestamp, eventTimestamp);
    }

    @Override
    public void onPeriodicEmit(WatermarkOutput output) {
        output.emitWatermark(new Watermark(maxTimestamp - maxDelay));
    }
}).withTimestampAssigner((order, timestamp) -> order.getEventTime());
```

### 5.3 迟到数据处理策略

```java
// 迟到数据三种处理方式

// 1. 默认丢弃（窗口关闭后迟到的数据直接丢弃）
DataStream<Order> mainStream = watermarkedStream
    .keyBy(Order::getCategoryId)
    .window(TumblingEventTimeWindows.of(Time.minutes(1)))
    .aggregate(new RevenueAggregator());

// 2. 侧输出（允许迟到 1 分钟，超出的进侧输出）
OutputTag<Order> lateTag = new OutputTag<Order>("late-orders") {};

DataStream<CategoryRevenue> result = watermarkedStream
    .keyBy(Order::getCategoryId)
    .window(TumblingEventTimeWindows.of(Time.minutes(1)))
    .allowedLateness(Time.minutes(1))       // 允许 1 分钟迟到
    .sideOutputLateData(lateTag)            // 超出允许时间的进侧输出
    .aggregate(new RevenueAggregator());

DataStream<Order> lateStream = result.getSideOutput(lateTag);
// 可以将迟到数据写入延迟队列单独处理

// 3. 不等待就触发（watermark 策略 + allowedLateness 配合使用）
```

## 六、状态管理与 Checkpoint

### 6.1 状态类型

Flink 的状态分为两大类：

| 状态类型 | 描述 | 适用场景 |
|----------|------|----------|
| **Operator State** | 算子级别的状态，每个并行实例共享 | Kafka offset、Source/Sink 状态 |
| **Keyed State** | 每个 key 独立的状态，需 keyBy | 聚合、窗口 |

Keyed State 的 5 种原始状态：

| 状态基元 | 接口 | 说明 |
|----------|------|------|
| ValueState | 单值 | 存储一个值（如当前累加值） |
| ListState | 列表 | 有序列表（如 TopN 排序） |
| MapState | 映射 | KV 对（如计数 map） |
| ReducingState | 归约 | 存储聚合中间结果 |
| AggregatingState | 聚合 | 自定义累加器 |

```java
public class TopNFunction extends KeyedProcessFunction<Long, Order, String> {
    // MapState: category → List<Order amount>
    private MapState<String, ListState<Double>> categoryAmountMap;
    private ValueState<Long> countState;

    @Override
    public void open(Configuration parameters) {
        categoryAmountMap = getRuntimeContext().getMapState(
            new MapStateDescriptor<>("categoryMap", Types.STRING, Types.LIST(Types.DOUBLE))
        );
        countState = getRuntimeContext().getState(
            new ValueStateDescriptor<>("count", Types.LONG)
        );
    }

    @Override
    public void processElement(Order order, Context ctx, Collector<String> out) throws Exception {
        ListState<Double> amoutList = categoryAmountMap.get(order.getCategoryName());
        if (amoutList == null) {
            amoutList = getRuntimeContext().getListState(
                new ListStateDescriptor<>("tmp", Types.DOUBLE)
            );
        }
        amoutList.add(order.getAmount());
        categoryAmountMap.put(order.getCategoryName(), amoutList);
        countState.update(countState.value() == null ? 1L : countState.value() + 1L);
    }
}
```

### 6.2 状态后端对比

| 状态后端 | 存储位置 | 适用场景 | 性能 |
|----------|----------|----------|------|
| HashMapStateBackend | TaskManager JVM Heap | 小状态（< 10GB） | 极快 |
| EmbeddedRocksDBStateBackend | RocksDB (本地磁盘) | 大状态（100GB+） | 较慢但稳定 |

```java
// HashMap 后端（默认）
env.setStateBackend(new HashMapStateBackend());
env.getCheckpointConfig().setCheckpointStorage("hdfs:///flink/checkpoints");

// RocksDB 后端（大状态推荐）
env.setStateBackend(new EmbeddedRocksDBStateBackend());
env.getCheckpointConfig().setCheckpointStorage("s3://flink-checkpoints/");
```

**选型建议：**

| 条件 | 推荐后端 |
|------|----------|
| 状态 < 10GB | HashMapStateBackend |
| 状态 10GB - 1TB | RocksDBStateBackend |
| 状态 > 1TB | RocksDB + 增量 Checkpoint |
| 需要超低延迟 | HashMapStateBackend |
| 需要大窗口 | RocksDBStateBackend |

### 6.3 Checkpoint 配置

```java
CheckpointConfig cpConfig = env.getCheckpointConfig();

// 基础配置
cpConfig.setCheckpointingMode(CheckpointingMode.EXACTLY_ONCE);
cpConfig.setCheckpointInterval(Duration.ofSeconds(60));
cpConfig.setCheckpointTimeout(Duration.ofMinutes(10));
cpConfig.setMinPauseBetweenCheckpoints(Duration.ofSeconds(30));

// 并发检查点（默认 1）
cpConfig.setMaxConcurrentCheckpoints(1);

// 检查点之间最小间隔
cpConfig.setMinPauseBetweenCheckpoints(Duration.ofMillis(500));

// 持久化存储
cpConfig.setCheckpointStorage("hdfs://nameservice/flink/checkpoints");

// 外部检查点（作业停止后保留）
cpConfig.enableExternalizedCheckpoints(
    ExternalizedCheckpointCleanup.RETAIN_ON_CANCELLATION);

// 容错选项
cpConfig.setTolerableCheckpointFailureNumber(3);

// 非对齐检查点（超大规模状态优化）
cpConfig.enableUnalignedCheckpoints();
```

### 6.4 从 Savepoint 恢复

```bash
# 触发 Savepoint
flink savepoint <jobId> hdfs:///flink/savepoints

# 从 Savepoint 启动
flink run -s hdfs:///flink/savepoints/savepoint-xxx-xxxxxx \
    -c com.example.RealtimeOrderStatistics \
    flink-app.jar

# 取消并保留外部检查点
curl -X POST "http://jobmanager:8081/jobs/<jobId>/stop" \
    -d '{"drain": false}' \
    -H "Content-Type: application/json"
```

## 七、Exactly-Once 语义保证

### 7.1 Exactly-Once 的两个层面

```
Flink 内部 (端到端)
         │
    ┌────┴────┐
    │ 内部    │ ← Checkpoint + 两阶段提交保证
    └────┬────┘
         │
    ┌────┴────┐
    │ 外部    │ ← 需要 Source/Sink 配合
    └─────────┘
```

### 7.2 端到端 Exactly-Once 的实现

| 组件 | 实现方式 | 配置 |
|------|----------|------|
| **Source** (Kafka) | 将 offset 写入 Checkpoint | `setStartFromLatest()` + Checkpoint |
| **Flink 内部** | Chandy-Lamport 分布式快照 | `CheckpointingMode.EXACTLY_ONCE` |
| **Sink** (Kafka) | 两阶段提交事务 | `FlinkKafkaProducer.Semantic.EXACTLY_ONCE` |
| **Sink** (MySQL) | 幂等写入 + UPSERT | `REPLACE INTO` / `ON DUPLICATE KEY UPDATE` |

```java
// Kafka Sink 开启 Exactly-Once
Properties producerProps = new Properties();
producerProps.setProperty("bootstrap.servers", "kafka:9092");
producerProps.setProperty("transaction.timeout.ms", "600000");

DataStream<String> result = ...;

result.addSink(new FlinkKafkaProducer<String>(
    "output-topic",
    new SimpleStringSchema(),
    producerProps,
    FlinkKafkaProducer.Semantic.EXACTLY_ONCE
));
```

## 八、CEP 复杂事件处理

### 8.1 CEP 模式定义

Flink CEP（Complex Event Processing）用于在事件流中识别模式序列。

```xml
<dependency>
    <groupId>org.apache.flink</groupId>
    <artifactId>flink-cep</artifactId>
    <version>${flink.version}</version>
</dependency>
```

### 8.2 支付欺诈检测案例

```java
import org.apache.flink.cep.CEP;
import org.apache.flink.cep.PatternSelectFunction;
import org.apache.flink.cep.PatternStream;
import org.apache.flink.cep.pattern.Pattern;
import org.apache.flink.cep.pattern.conditions.SimpleCondition;

public class FraudDetection {

    // 模式：同一用户 5 分钟内快速连续交易 ≥ 3 笔，且单笔金额 > 10000
    public static Pattern<Transaction, ?> fraudPattern =
        Pattern.<Transaction>begin("first")
            .where(new SimpleCondition<Transaction>() {
                @Override
                public boolean filter(Transaction t) {
                    return t.getAmount() > 10000;
                }
            })
            .next("second")
            .where(new SimpleCondition<Transaction>() {
                @Override
                public boolean filter(Transaction t) {
                    return t.getAmount() > 10000;
                }
            })
            .next("third")
            .where(new SimpleCondition<Transaction>() {
                @Override
                public boolean filter(Transaction t) {
                    return t.getAmount() > 10000;
                }
            })
            .within(Time.minutes(5));  // 5 分钟内

    public static void detectFraud(DataStream<Transaction> source) {
        PatternStream<Transaction> patternStream = CEP.pattern(
            source.keyBy(Transaction::getUserId),
            fraudPattern
        );

        DataStream<Alert> alerts = patternStream.select(
            new PatternSelectFunction<Transaction, Alert>() {
                @Override
                public Alert select(Map<String, List<Transaction>> pattern) {
                    Transaction first = pattern.get("first").get(0);
                    Transaction second = pattern.get("second").get(0);
                    Transaction third = pattern.get("third").get(0);
                    return new Alert(
                        first.getUserId(),
                        String.format(
                            "5分钟内连续大额交易: %.2f, %.2f, %.2f",
                            first.getAmount(),
                            second.getAmount(),
                            third.getAmount()
                        )
                    );
                }
            }
        );

        alerts.addSink(new AlertSink());
    }
}
```

### 8.3 CEP 模式匹配常用 API

| API | 说明 |
|-----|------|
| `begin("name")` | 模式开始 |
| `next("name")` | 严格连续（中间不能有其他事件） |
| `followedBy("name")` | 非严格连续（允许跳过不匹配事件） |
| `followedByAny("name")` | 非确定性松散连续 |
| `notNext()` / `notFollowedBy()` | 否定模式 |
| `oneOrMore()` | 一次或多次 |
| `times(n)` | 精确 n 次 |
| `times(n, m)` | n 到 m 次 |
| `optional()` | 可选 |
| `greedy()` | 贪婪匹配 |
| `within(Time)` | 时间窗口内 |
| `until()` | 直到某个条件成立 |

## 九、Kafka 集成实战

### 9.1 版本兼容性

| Flink 版本 | 推荐 Kafka 客户端版本 | connector 模块 |
|------------|----------------------|----------------|
| 1.14 - 1.15 | 2.4.1 - 3.0.0 | `flink-connector-kafka_2.12` |
| 1.16 - 1.17 | 3.2.0+ | `flink-connector-kafka` |
| 1.18 - 1.20 | 3.6.0+ | `flink-connector-kafka` |

### 9.2 高级 Kafka Consumer 配置

```java
Properties props = new Properties();
props.setProperty("bootstrap.servers", "kafka-01:9092,kafka-02:9092,kafka-03:9092");
props.setProperty("group.id", "flink-consumer-group");
props.setProperty("auto.offset.reset", "earliest");

// 不自动提交 offset（Flink 接管）
props.setProperty("enable.auto.commit", "false");

// 拉取配置
props.setProperty("fetch.min.bytes", "1024");
props.setProperty("fetch.max.wait.ms", "1000");
props.setProperty("max.partition.fetch.bytes", "5242880"); // 5MB

// 动态分区发现（每 10 秒检测新分区）
props.setProperty("flink.partition-discovery.interval-millis", "10000");

DataStream<String> stream = env.addSource(
    new FlinkKafkaConsumer<String>("order-events,payment-events,refund-events",
        new SimpleStringSchema(), props)
        .setStartFromLatest()
        .setCommitOffsetsOnCheckpoints(true)
);
```

### 9.3 Kafka Sink 的三种语义

```java
// AT_LEAST_ONCE（默认，吞吐最高）
FlinkKafkaProducer<String> producer1 = new FlinkKafkaProducer<>(
    "output-topic", new SimpleStringSchema(), props);
producer1.setSemantic(FlinkKafkaProducer.Semantic.AT_LEAST_ONCE);

// EXACTLY_ONCE（需 Kafka 事务支持）
FlinkKafkaProducer<String> producer2 = new FlinkKafkaProducer<>(
    "output-topic", new SimpleStringSchema(), props);
producer2.setSemantic(FlinkKafkaProducer.Semantic.EXACTLY_ONCE);

// NONE（不保证，仅适用于非关键数据）
FlinkKafkaProducer<String> producer3 = new FlinkKafkaProducer<>(
    "output-topic", new SimpleStringSchema(), props);
producer3.setSemantic(FlinkKafkaProducer.Semantic.NONE);
```

## 十、生产最佳实践

- ✅ 生产环境必须开启 Checkpoint（`setCheckpointingMode(EOS)`、`setCheckpointInterval`）
- ✅ 状态后端使用 RocksDB 并开启增量 Checkpoint（大状态场景）
- ✅ 设置合理的并行度（`parallelism = min(partition_count, target_slots * utilization_factor)`）
- ✅ 使用 Event Time + BoundedOutOfOrderness Watermark
- ✅ 设置 allowedLateness 并配合侧输出（sideOutputLateData）处理迟到数据
- ✅ 禁止使用 `print()` 或 `collect()` 在生产环境
- ✅ 使用 Savepoint 而不是停止+重启来做作业升级
- ✅ 设置任务失败重试策略（`env.setRestartStrategy(RestartStrategies.fixedDelayRestart(3, 10000))`）
- ✅ 大状态作业开启非对齐 Checkpoint（`enableUnalignedCheckpoints()`）
- ✅ 监控 Flink 指标：`flink_jobmanager_job_numberOfFailedCheckpoints`、`flink_taskmanager_job_task_busyTimeMsPerSecond`

## 十一、结语

Apache Flink 以其统一的批流一体架构、丰富的 API 生态和强大的容错机制，为实时计算提供了端到端的解决方案。从简单的 ETL 到复杂的 CEP 模式匹配，从毫秒级延迟到 Exactly-Once 语义，Flink 都能胜任。

在实际项目中，建议采用 Flink SQL 处理大部分简单场景，DataStream API 处理复杂逻辑，并配合状态后端的合理选择、Checkpoint 的精细化配置以及上下游连接器的 Exactly-Once 保障，构建稳定高效的实时计算体系。
