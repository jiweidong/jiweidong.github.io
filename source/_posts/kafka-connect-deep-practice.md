---
title: Kafka Connect 深度实战：从单机到集群的数据管道与 CDC 实践
date: 2026-08-20 08:00:00
tags:
  - Java
  - Kafka
  - 消息队列
categories:
  - Java
  - 中间件
author: 东哥
---

# Kafka Connect 深度实战：从单机到集群的数据管道与 CDC 实践

## 引言：为什么需要 Kafka Connect？

很多团队接 Kafka 的方式是"写个消费者程序，把数据从 Topic 搬到数据库"。一个系统这么干没问题，当系统多起来：订单数据进 ES、埋点数据进 HDFS、MySQL 变更同步到 Redis……每个需求写一个消费程序，就要重复处理：

- 分区分配与 Rebalance
- 位移提交与 Exactly-Once 语义
- 断线重连、重试、死信
- 连接管理、线程池、资源释放

**Kafka Connect 的价值就是把"搬数据"这件事框架化**：你只需要写（或直接复用现成的）Source/Sink Connector，框架帮你搞定分布式执行、容错、偏移量管理、负载均衡。本文从架构原理到生产落地，带你把 Kafka Connect 用明白。

## 一、核心架构：三个角色 + 两类组件

### 1.1 三个运行时角色

| 角色 | 说明 |
|------|------|
| **Worker** | 运行 Connector 和 Task 的 JVM 进程。分 Standalone（单机）和 Distributed（集群）两种模式 |
| **Connector** | 逻辑定义："把 MySQL 的 binlog 搬到 topic1"，只做配置管理和任务切分 |
| **Task** | 真正干活的最小执行单元，Connector 把工作切成 N 个 Task 并行执行 |

### 1.2 两类 Connector

- **Source Connector**：把外部数据源（MySQL、PostgreSQL、文件、MongoDB）**拉进** Kafka Topic。
- **Sink Connector**：把 Kafka Topic 的数据**推到**外部系统（ES、HDFS、S3、JDBC 数据库）。

### 1.3 分布式模式怎么协作？

Distributed 模式下，Worker 之间通过内部的 `config.storage.topic`、`offset.storage.topic`、`status.storage.topic` 三个内部 Topic 协调：

- **config topic**：保存所有 Connector 配置（谁定义了什么任务）
- **offset topic**：保存各 Task 的消费/采集进度（断点续传）
- **status topic**：保存 Task 运行状态

Leader 选举、任务再分配由 Connect 框架内嵌的协调器完成（原理类似消费者组 Rebalance，基于 `org.apache.kafka.connect.runtime.distributed.DistributedHerder`）。

## 二、单机起步：Standalone 模式 10 分钟上手

### 2.1 下载与配置

```bash
# Kafka 发行版自带 connect 脚本
cd kafka_2.13-3.7.0

# 1. 先起 Kafka 集群（KRaft 模式，一条命令）
bin/kafka-storage.sh random-uuid > /tmp/kraft-id
bin/kafka-storage.sh format -t $(cat /tmp/kraft-id) -c config/kraft/server.properties
bin/kafka-server-start.sh config/kraft/server.properties &

# 2. 启动 standalone worker
bin/connect-standalone.sh config/connect-standalone.properties \
    config/connect-file-source.properties \
    config/connect-file-sink.properties
```

### 2.2 文件源到文件汇

```properties
# connect-file-source.properties
name=local-file-source
connector.class=FileStreamSourceConnector
tasks.max=1
file=/tmp/test.txt
topic=connect-test
```

```properties
# connect-file-sink.properties
name=local-file-sink
connector.class=FileStreamSinkConnector
tasks.max=1
file=/tmp/test-sink.txt
topics=connect-test
```

往 `/tmp/test.txt` 追加内容，`/tmp/test-sink.txt` 会实时出现同样的数据。Standalone 模式所有配置写在文件里，适合开发调试，**生产必须用 Distributed 模式**。

## 三、生产标配：Distributed 模式 + REST API

### 3.1 Worker 配置

```properties
bootstrap.servers=node1:9092,node2:9092,node3:9092
group.id=connect-cluster          # 同一 group 的 Worker 组成一个集群

# 三个内部 topic（生产建议手动创建并配高副本）
config.storage.topic=connect-configs
offset.storage.topic=connect-offsets
status.storage.topic=connect-status

key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
# 生产推荐 Avro/Protobuf，配合 Schema Registry
key.converter.schemas.enable=false
value.converter.schemas.enable=false

# 每个 worker 允许的最大 task 数（按 CPU 核数设置）
tasks.max=8

plugin.path=/opt/connectors   # 第三方 connector 的 jar 目录
```

### 3.2 REST API 管理 Connector（这才是生产姿势）

```bash
# 创建 connector（POST 配置即创建）
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d '{
  "name": "mysql-orders-source",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "db01",
    "database.port": "3306",
    "database.user": "connect",
    "database.password": "******",
    "database.server.id": "5400",
    "database.include.list": "shop",
    "table.include.list": "shop.t_orders",
    "database.history.kafka.bootstrap.servers": "node1:9092,node2:9092",
    "database.history.kafka.topic": "schema-changes.shop",
    "topic.prefix": "cdc"
  }
}'

# 查看状态
curl http://localhost:8083/connectors/mysql-orders-source/status

# 暂停 / 恢复 / 删除
curl -X PUT  http://localhost:8083/connectors/mysql-orders-source/pause
curl -X PUT  http://localhost:8083/connectors/mysql-orders-source/resume
curl -X DELETE http://localhost:8083/connectors/mysql-orders-source
```

常用接口还有 `GET /connector-plugins`（列出已加载的插件）、`GET /connectors/{name}/tasks`（查看任务分布）、`GET /connectors/{name}/config`（查看生效配置）。

## 四、手写一个 Source Connector（附核心源码思路）

框架的价值在于扩展。很多场景没有现成 Connector，需要自己写。核心就两个类：

```java
public class MySqlSourceConnector extends SourceConnector {
    @Override
    public void start(Map<String, String> props) {
        // 1. 解析并校验配置
        config = new Config(props);
    }

    @Override
    public Class<? extends Task> taskClass() {
        return MySqlSourceTask.class;   // 告诉框架用哪个 Task
    }

    @Override
    public List<Map<String, String>> taskConfigs(int maxTasks) {
        // 2. 任务切分：比如按表分片，返回 maxTasks 份配置
        List<Map<String, String>> configs = new ArrayList<>();
        for (String table : config.getTables()) {
            Map<String, String> taskConfig = new HashMap<>(config.originalsStrings());
            taskConfig.put("table", table);
            configs.add(taskConfig);
        }
        return configs;
    }

    @Override
    public void stop() { }
}

public class MySqlSourceTask extends SourceTask {
    @Override
    public void start(Map<String, String> props) {
        // 打开数据源连接，从 context.offsetStorageReader() 恢复上次进度
        Map<String, Object> offset = context.offsetStorageReader()
            .offset(Map.of("table", props.get("table")));
        long lastId = offset == null ? 0L : (long) offset.get("lastId");
    }

    @Override
    public List<SourceRecord> poll() throws InterruptedException {
        // 3. 拉一批增量数据，封装成 SourceRecord（框架负责提交 offset）
        List<SourceRecord> records = new ArrayList<>();
        List<Row> rows = fetchIncrement(lastId, BATCH_SIZE);
        for (Row row : rows) {
            records.add(new SourceRecord(
                Map.of("table", table),                    // sourcePartition
                Map.of("lastId", row.getId()),             // sourceOffset（断点）
                "cdc." + table,                            // topic
                Schema.STRING_SCHEMA, JsonUtil.toJson(row) // value
            ));
        }
        return records.isEmpty() ? null : records;  // 返回 null 表示暂时没数据
    }

    @Override
    public void stop() { }
}
```

三个关键点：

1. **offset 管理**：SourceRecord 里的 `sourceOffset` 会被框架自动提交到 offset topic，崩溃恢复后通过 `offsetStorageReader` 续传——这是"只处理一次增量"的基础。
2. **poll() 返回 null 表示无数据**，框架会退避等待；返回空 List 会被视为错误，注意区分。
3. **任务切分**：`taskConfigs(maxTasks)` 决定并行度，按表/按分片切分才能水平扩展。

## 五、生产落地：必须处理的 8 个问题

### 5.1 Schema 管理
生产强烈建议用 **Avro + Schema Registry**（参考之前写的 Kafka Schema Registry 文章），避免 JSON 无 Schema 导致的字段漂移。配置：

```properties
key.converter=io.confluent.connect.avro.AvroConverter
key.converter.schema.registry.url=http://schema-registry:8081
```

### 5.2 Exactly-Once / At-Least-Once
Connector 默认 At-Least-Once（可能重复）。Sink 端要做幂等（目标表加唯一键，靠 INSERT ... ON DUPLICATE KEY 或 UPSERT 去重）。Connect 3.x 支持 EOS 模式（`exactly.once.support=preparing`），但依赖事务性 sink，配置复杂，绝大多数场景"幂等 + At-Least-Once"够用。

### 5.3 单条消息过大
默认 `message.max.bytes=1MB`，大 JSON 会被 Producer 拒收。需要联动调整 broker 的 `message.max.bytes`、topic 的 `max.message.bytes`、以及 Connect 的 `producer.override.message.max.bytes`。

### 5.4 任务重平衡风暴
一个 Connector 故障会触发整个集群 Rebalance，期间所有任务短暂停摆。缓解手段：

- Connector 之间做**故障隔离**：用 `connector.client.config.override.policy=All` 为不同 Connector 指定独立 producer/consumer 配置
- 调大 `rebalance.timeout.ms`，避免慢任务被频繁踢出
- 任务数不宜过多（每个 Task 一个线程，注意 Worker 的 tasks.max 上限）

### 5.5 监控告警
JMX 指标非常关键：`kafka.connect:type=connect-worker-metrics`（任务数、连接数）、`connect-task-error-metrics`（错误率）。配合 Prometheus JMX Exporter + Grafana 建立看板，重点盯：

- 各 Connector 的 **Error 计数**
- Source 端 `source-record-poll-rate` 是否归零（数据停了）
- Sink 端 `sink-record-send-rate` 与 lag

### 5.6 日志里常见的坑
- `Offset commit failed`：sink 写入慢导致提交超时（默认 60s），检查目标库慢 SQL
- `Connector is not assigned`：任务在 Rebalance 中，等 30s 再看
- `Topic ... not present in metadata after 60000ms`：topic 不存在或 ACL 未授权

### 5.7 容量规划
经验值：单个 Worker 承载 10~20 个轻量 Connector 或 5~8 个重负载 Connector；每个 Task 预留 1~2 核 CPU、1~2GB 堆内存。瓶颈通常不在 Connect 本身，而在两端系统（源库、目标库）。

### 5.8 与 Debezium 的关系
Debezium 是一套**基于 Kafka Connect 框架**实现的 CDC 连接器集合（MySQL/PostgreSQL/MongoDB/Oracle 等）。它复用了 Connect 的分布式执行、offset 管理，同时自己实现了 binlog 解析、快照、Schema 演进。所以"Kafka Connect"是底座，"Debezium"是跑在底座上的高质量应用。上一篇文章《Debezium + Kafka 实时数据同步架构实战》讲的是 CDC 场景，本文则聚焦 Connect 框架本身——包括自己写 Connector 的能力。

## 六、面试追问环节

**Q1：Connect 集群怎么保证任务不重复执行？**
答：分布式协调器保证每个 Task 同一时刻只有一个 Worker 执行（类似消费者组的分区独占）；offset 由框架统一提交到内部 topic，故障后从提交的 offset 恢复。但"不重复执行"不等于"不重复输出"，端到端仍可能因提交时序产生重复，需要 Sink 幂等兜底。

**Q2：Standalone 和 Distributed 怎么选？**
答：Standalone 单进程、配置本地化、无故障转移，只适合开发测试；生产必须 Distributed，多个 Worker 组成集群，任务自动均衡、Worker 宕机自动转移。

**Q3：一个 Connector 的 tasks.max 设多少合适？**
答：取决于数据源可切分性。MySQL 单连接器可按表分 task；切分粒度越细并行度越高，但任务越多 Rebalance 越频繁、协调开销越大。一般从 1 开始，观测吞吐瓶颈再逐步调大。

**Q4：为什么说"不要用普通消费者程序替代 Kafka Connect"？**
答：Connect 把位移管理、任务切分、容错、配置热更新、REST 管理、监控指标全部框架化，且天然支持"一个 pipeline 多种连接器"的生态组合。自己写消费者搬运数据，上述每一样都要重复造轮子，还容易在 Rebalance、位移提交上踩坑。

## 总结

Kafka Connect 是 Kafka 生态里"数据进出"的标准答案：Source 负责进，Sink 负责出，分布式协调保证高可用，offset topic 保证断点续传，REST API 让运维可以动态管理 pipeline。掌握它的架构模型 + 一个自研 Connector 的编写范式 + 生产问题清单，你就能在团队里撑起整套数据管道建设。
