---
title: MongoDB 实战：从入门到分片集群
date: 2026-06-16 08:30:00
tags:
  - MongoDB
  - NoSQL
  - 数据库
  - 分片集群
categories: 数据库
updated: 2026-06-16 08:30:00
description: 深入讲解MongoDB核心概念、复制集高可用、分片集群架构、索引优化、聚合管道、备份恢复与监控实战。
---

## 一、MongoDB 核心概念

MongoDB 是最流行的 NoSQL 文档数据库，以 **BSON（Binary JSON）** 格式存储数据。它的数据模型灵活、扩展能力极强，适合快速迭代和高并发场景。

### 1.1 数据模型对比

| 概念 | RDBMS | MongoDB |
|------|-------|---------|
| 数据库 | Database | Database |
| 表 | Table | Collection（集合） |
| 行 | Row | Document（文档） |
| 列 | Column | Field（字段） |
| 索引 | Index | Index |
| 表关联 | JOIN | $lookup / 嵌入式文档 |
| 主键 | Primary Key | `_id`（默认 ObjectId） |
| 分区 | Partition | Shard（分片） |

### 1.2 文档模型设计原则

MongoDB 设计文档模型时，核心是：**根据数据访问模式设计，而非关系范式**。

```
嵌入式文档（推荐，适合一对一的嵌入关系）:
{
  "_id": ObjectId("..."),
  "user": {
    "name": "张三",
    "email": "zhangsan@example.com",
    "address": {
      "city": "北京",
      "district": "海淀"
    }
  },
  "order": {
    "items": [
      { "product": "手机", "price": 3999, "quantity": 1 },
      { "product": "耳机", "price": 299, "quantity": 2 }
    ],
    "total": 4597,
    "status": "shipped"
  }
}

引用方式（适合一对多/多对多关系）:
// 用户集合
{ "_id": ObjectId("user1"), "name": "张三" }

// 订单集合 — 引用用户
{
  "_id": ObjectId("order1"),
  "user_id": ObjectId("user1"),  // 引用
  "items": [...],
  "total": 4597
}
```

| 设计决策 | 优先嵌入 | 优先引用 |
|---------|---------|---------|
| 数据访问 | 子文档总是和父文档一起查 | 子文档单独查询频率高 |
| 关系 | 一对一、少量一对多 | 大量一对多、多对多 |
| 更新频率 | 子文档更新不频繁 | 子文档频繁独立更新 |
| 文档大小 | 总和 < 16MB（MongoDB 文档大小限制） | 超过 16MB |

## 二、复制集（Replica Set）

### 2.1 复制集架构

复制集是 MongoDB 高可用的核心机制，由一组 mongod 进程组成，包含一个 Primary 和多个 Secondary。

```
MongoDB 复制集架构:

                     +----------------+
                     |    Arbiter     |  (选举仲裁者，可选)
                     +-------+--------+
                             |
      +----------------------+------------------------+
      |                      |                        |
+-----+------+       +------+------+       +---------+---+
| Primary    |<------| Secondary 1 |<------| Secondary 2  |
| (读写)     | 复制   | (只读)      | 复制   | (只读)       |
+-----+------+       +------+------+       +------+------+
      |                      |                      |
 mongod:27017        mongod:27017           mongod:27017
      |                      |                      |
  +---+---+             +---+---+              +---+---+
  | oplog |             | oplog |              | oplog |
  +-------+             +-------+              +-------+
```

### 2.2 Primary/Secondary 选举流程

```
复制集选举流程（Primary 宕机）:

    step 1: Primary 宕机，心跳超时
    =================================
    Secondary 1 发现 Primary 无响应 (> electionTimeoutMillis 默认 10s)
    Secondary 2 也发现同样情况

    step 2: 选举发起
    =================================
    Secondary 1: "我发起选举！我的 priority=2, 最新 optime=2026-06-16T08:00:00Z"
    Secondary 2: "... 我 priority=1, 最新 optime=2026-06-16T07:59:55Z"

    step 3: 选票收集
    =================================
    Secondary 1 请求 Secondary 2 投票给自己
    Secondary 2 检查:
      - 自己是否可竞选? YES
      - Secondary 1 的 optime 是否 >= 自己? YES (08:00:00 > 07:59:55)
      - 没给其他人投票? YES
    → 投给 Secondary 1

    step 4: 胜选
    =================================
    Secondary 1 获得多数票（2/3 > 是多数）→ 成为新的 Primary
    通知所有节点更新主库信息

    step 5: 原 Primary 恢复
    =================================
    原 Primary 上线，发现自己已是 Secondary
    与新 Primary 同步数据 → 进入 Secondary 复制状态

    选举条件:
    - 必须有超过半数节点存活 (< 二分之一容错)
    - 选举者必须拥有最新 oplog
    - priority 高的优先被投票
    - 如果 priority=0，永远不能成为 Primary
```

### 2.3 复制集配置

```javascript
// 复制集初始化（在 Primary 上执行）
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongodb-01:27017", priority: 2 },
    { _id: 1, host: "mongodb-02:27017", priority: 1 },
    { _id: 2, host: "mongodb-03:27017", priority: 1 },
    { _id: 3, host: "mongodb-arbiter:27017", arbiterOnly: true }
  ],
  settings: {
    electionTimeoutMillis: 10000,    // 选举超时（默认 10s）
    heartbeatTimeoutSecs: 10,        // 心跳超时
    catchUpTimeoutMillis: 30000,     // 追赶超时
  }
});

// 复制集常见命令
rs.status()              // 查看复制集状态
rs.conf()                // 查看复制集配置
rs.add("mongodb-04:27017")          // 添加节点
rs.addArb("mongodb-arb:27017")      // 添加仲裁节点
rs.remove("mongodb-04:27017")       // 移除节点
rs.stepDown(60)          // 主动降级（60秒不可选为主）
rs.printReplicationInfo() // 查看 oplog 信息
```

## 三、分片集群架构

### 3.1 为什么需要分片

当单机无法满足以下任一条件时，就需要分片：
- **数据量超过单节点存储上限**（TB 级数据）
- **写入吞吐超过单节点 CPU/磁盘极限**
- **工作集远大于内存**导致频繁磁盘 IO

### 3.2 分片集群组件

```
MongoDB 分片集群完整架构:

                          +-------------------+
                          |  应用 / Driver    |
                          +---------+---------+
                                    |
                    mongos 路由层   |
                    +---------------+---------------+
                    |                               |
            +-------+-------+               +-------+-------+
            |   mongos 1    |               |   mongos 2    |
            |   (路由)      |               |   (路由)      |
            +---------------+               +---------------+
                    |                               |
          Config Server (元数据)                     |
          +---------------------------+              |
          |  configsvr 副本集 (rs-cfg)  |<------------+
          |  mongod --configsvr        |
          |  节点1 | 节点2 | 节点3     |
          +---------------------------+
                    |
    +---------------+-------------------------------+
    |               |               |               |
+---+----+   +------+----+   +------+----+   +------+----+
|Shard A  |   | Shard B   |   | Shard C   |   | Shard D   |
|副本集 rs1|   | 副本集 rs2|   | 副本集 rs3|   | 副本集 rs4|
|P---S---S|   |P---S---S |   |P---S---S |   |P---S---S  |
+---------+   +----------+   +----------+   +----------+
```

**组件说明：**

| 组件 | 功能 | 部署要求 |
|------|------|---------|
| **mongos** | 路由层，接收应用请求，转发到对应分片 | 至少 2 个，无状态，可与应用同机部署 |
| **Config Server** | 存储集群元数据（分片键范围、分片映射关系） | 必须 3 节点副本集（PSA 架构），`--configsvr` |
| **Shard** | 实际存储数据的分片，每个分片是一个副本集 | 至少 1 个分片，生产建议 2+ |
| **Mongod** | 每个分片内部的数据库节点 | 根据负载决定节点规格 |

### 3.3 启用分片与分片键选择

```javascript
// 1. 连接到 mongos
mongosh --host mongos-01 --port 27017

// 2. 启用数据库分片
sh.enableSharding("ecommerce")

// 3. 对集合启用分片
// 基于哈希的分片键（推荐，数据分布均匀）
sh.shardCollection("ecommerce.orders", { _id: "hashed" })

// 基于范围的分片键（适合范围查询）
sh.shardCollection("ecommerce.orders", { user_id: 1, created_at: -1 })

// 4. 添加分片
sh.addShard("rs1/mongodb-01:27017,mongodb-02:27017,mongodb-03:27017")
sh.addShard("rs2/mongodb-04:27017,mongodb-05:27017,mongodb-06:27017")
sh.addShard("rs3/mongodb-07:27017,mongodb-08:27017,mongodb-09:27017")
```

#### 分片键选择原则

```javascript
// ✅ 好的分片键
sh.shardCollection("logs.app_logs", { timestamp: 1 }, {
  timeseries: { timeField: "timestamp" }  // 时序数据
})
// - 基数（Cardinality）高
// - 写入分布在所有分片上，无热点
// - 查询包含分片键时可精准路由

// ❌ 差的分片键示例
sh.shardCollection("ecommerce.orders", { status: 1 })
// - status 基数低（只有 pending/shipped/delivered/cancelled）
// - 分片无法均匀分布数据（最多 4 个范围，浪费分片）

// ❌ 单调递增分片键（基于范围分片时）
sh.shardCollection("logs.app_logs", { _id: 1 })
// - ObjectId 单调递增，所有新写入都到一个分片
// - 导致单分片成为写入瓶颈
// - 解决方案：使用 hashed 分片键
```

### 3.4 分片集群平衡器

```javascript
// 查看平衡器状态
sh.getBalancerState()

// 手动控制平衡窗口（推荐在业务低峰期执行）
db.settings.updateOne(
  { _id: "balancer" },
  {
    $set: {
      activeWindow: {
        start: "02:00",  // 凌晨 2 点开始
        stop: "06:00"    // 早上 6 点结束
      }
    }
  },
  { upsert: true }
)

// 查看分片数据分布
db.printShardingStatus()

// 手动迁移数据块（仅在极少数情况下需要）
sh.moveChunk(
  "ecommerce.orders",
  { user_id: MinKey, created_at: MinKey },
  "rs2"
)
```

## 四、索引优化

### 4.1 索引类型

| 索引类型 | 语法 | 适用场景 |
|---------|------|---------|
| 单字段 | `db.col.createIndex({field:1})` | 单字段等值/范围查询 |
| 复合 | `db.col.createIndex({a:1,b:-1})` | 多字段联合查询 |
| 多键 | `db.col.createIndex({tags:1})` | 数组字段查询 |
| 文本 | `db.col.createIndex({desc:"text"})` | 全文搜索 |
| 哈希 | `db.col.createIndex({_id:"hashed"})` | 分片键、散列均匀分布 |
| 地理空间 | `db.col.createIndex({loc:"2dsphere"})` | 地理位置查询 |
| TTL | `db.col.createIndex({created:1},{expireAfterSeconds:86400})` | 自动过期数据 |
| 稀疏 | `db.col.createIndex({optional:1},{sparse:true})` | 字段不完全存在 |
| 部分 | `db.col.createIndex({status:1},{partialFilterExpression:{status:"active"}}) | 仅索引活跃文档 |

### 4.2 复合索引最佳实践

```javascript
// ESR 规则（Equality - Sort - Range）
db.orders.createIndex({ user_id: 1, status: 1, created_at: -1 })
// 1. Equality 字段放前面: { user_id: 1 }
// 2. Sort 字段其次: { status: 1 }
// 3. Range 字段最后: { created_at: -1 }

// 查询:
db.orders.find({ user_id: "u123", status: "shipped" })
         .sort({ created_at: -1 })
// 该查询可以完全走索引，不需要内存排序
```

### 4.3 explain 分析

```javascript
// 检查查询是否使用索引
db.orders.find({ user_id: "u123" }).explain("executionStats")

// 关键指标解读:
{
  "executionStats": {
    "totalDocsExamined": 1000,      // 扫描的文档数
    "totalKeysExamined": 1000,      // 扫描的索引条目数
    "nReturned": 500,               // 返回的结果数
    "executionTimeMillis": 10,      // 执行时间
    "executionStages": {
      "stage": "IXSCAN",            // COLLSCAN = 全表扫描, IXSCAN = 索引扫描
      "nReturned": 1000,
      "totalDocsExamined": 1000,
      "inputStage": {
        "stage": "FETCH",           // 回表读取文档
        "docsExamined": 1000
      }
    }
  }
}

// 理想情况: totalDocsExamined ≈ nReturned
// 警告信号:
// - COLLSCAN 出现: 全表扫描，需要加索引
// - totalDocsExamined >> nReturned: 索引选择性差
// - SORT 阶段出现在内存: 索引未覆盖排序字段
// - executionTimeMillis 持续上升: 数据量增长，索引或查询需要优化
```

## 五、聚合管道

### 5.1 典型聚合管道示例

```javascript
// 场景：统计每个商品类目最近 30 天的销售情况
db.orders.aggregate([
  // Stage 1: 过滤—缩小数据范围
  { $match: { created_at: { $gte: new Date("2026-05-17") } } },

  // Stage 2: 关联商品信息
  { $lookup: {
      from: "products",
      localField: "product_id",
      foreignField: "_id",
      as: "product"
  }},
  { $unwind: "$product" },

  // Stage 3: 分组—按类目聚合统计
  { $group: {
      _id: "$product.category",
      order_count: { $sum: 1 },
      total_revenue: { $sum: { $multiply: ["$price", "$quantity"] } },
      avg_price: { $avg: "$price" },
      unique_users: { $addToSet: "$user_id" },
      top_products: {
        $push: {
          name: "$product.name",
          sales: { $sum: "$quantity" }
        }
      }
  }},

  // Stage 4: 添加计算字段
  { $addFields: {
      avg_order_value: { $divide: ["$total_revenue", "$order_count"] },
      unique_user_count: { $size: "$unique_users" }
  }},

  // Stage 5: 过滤—只保留销售额 > 10000 的类目
  { $match: { total_revenue: { $gt: 10000 } } },

  // Stage 6: 排序
  { $sort: { total_revenue: -1 } },

  // Stage 7: 限制结果数
  { $limit: 20 },

  // Stage 8: 最终输出格式
  { $project: {
      _id: 0,
      category: "$_id",
      order_count: 1,
      total_revenue: 1,
      avg_order_value: 1,
      unique_user_count: 1,
      top_products: { $slice: ["$top_products", 5] }  // top 5
  }}
]);
```

### 5.2 聚合管道优化原则

```
聚合管道执行流程与优化:
+----------+     +----------+     +---------+     +--------+
| $match   | --> | $sort    | --> | $group  | --> | $limit |
+----------+     +----------+     +---------+     +--------+
     |                |               |               |
  尽可能早地       排序字段要        分组字段上         尽早使用
  做 $match       创建索引          有索引支持         $limit
```

1. **尽早使用 $match 过滤**：减少后续阶段的文档数
2. **$match + $sort 利用索引**：如果前面的 $match 能匹配索引字段，$sort 也能利用该索引
3. **$lookup 构建索引**：`foreignField` 字段在 from 集合上必须有索引
4. **使用 $project 减少字段**：前序阶段去掉不需要的字段
5. **$bucket/$bucketAuto 替代 $group**：对大量数据进行预分组时更高效
6. **启用 allowDiskUse**：超过 100MB 内存限制时启用

```javascript
// 大结果集聚合启用磁盘
db.collection.aggregate(pipeline, { allowDiskUse: true })
```

## 六、备份恢复

### 6.1 逻辑备份与恢复

```bash
# mongodump：备份整个数据库
mongodump --host localhost --port 27017 \
  --db ecommerce --out /backup/mongodb/20260616

# 备份单个集合
mongodump --collection orders --db ecommerce --out /backup/orders_backup

# 带认证的备份
mongodump --uri "mongodb://admin:pass@localhost:27017/ecommerce?authSource=admin"

# mongorestore：恢复
mongorestore --drop /backup/mongodb/20260616

# 恢复指定数据库到不同的目标数据库名
mongorestore --nsFrom "ecommerce.*" --nsTo "ecommerce_restore.*" /backup/...
```

### 6.2 物理备份（文件系统快照）

```bash
# 适用于大型数据库，速度远快于 mongodump
# 在复制集或分片集群中，对每个副本集节点的 Secondary 执行

# 1. 在 Secondary 上锁住写入（短暂）
db.fsyncLock()

# 2. 创建文件系统快照
# LVM 快照:
lvcreate -L 50G -s -n mongodb_snap /dev/vg/mongodb
# 或直接复制数据文件:
cp -r /var/lib/mongodb /backup/physical_20260616

# 3. 解锁
db.fsyncUnlock()
```

### 6.3 复制集备份策略

```javascript
// 最佳实践：在隐藏节点（hidden: true）上备份，不影响主库

// 添加隐藏备份节点
rs.add({
  _id: 3,
  host: "mongodb-backup:27017",
  hidden: true,
  priority: 0,
  votes: 0,        // 不参与选举
  buildIndexes: false  // 可选：不维护索引以节省空间
});

// 对隐藏节点执行 mongodump，不影响生产
```

## 七、监控与运维

### 7.1 关键监控指标

```javascript
// 服务器状态
db.serverStatus()
// 关键字段:
// - connections.current / available: 连接数
// - opcounters: 操作计数器（insert/query/update/delete）
// - wiredTiger.cache: WiredTiger 缓存命中率（目标 > 95%）
// - wiredTiger.concurrentTransactions: 并发事务

// 数据库统计
db.stats()
// - dataSize: 实际数据大小
// - indexSize: 索引大小
// - avgObjSize: 平均文档大小

// 慢查询分析
db.setProfilingLevel(1, { slowms: 100 })
db.system.profile.find({ millis: { $gt: 500 } }).sort({ ts: -1 }).limit(20)

// 操作级统计
db.currentOp({
  $or: [
    { op: "query", secs_running: { $gt: 10 } },
    { op: "command", secs_running: { $gt: 30 } }
  ]
})
// 杀死长时间运行的查询（谨慎使用！）
// db.killOp(opid)
```

### 7.2 健康检查清单

| 检查项 | 正常值 | 告警阈值 | 操作建议 |
|--------|--------|---------|---------|
| Cache 命中率 | > 95% | < 90% | 扩容内存或优化查询 |
| 连接数 | < 80% max | > 90% max | 检查连接池配置或扩容 |
| 复制延迟 | < 2s | > 10s | 检查网络、从库负载 |
| Oplog 窗口 | > 24h | < 12h | 增大 oplogSize |
| 磁盘使用率 | < 70% | > 85% | 清理数据或扩容 |
| Page Faults | < 100/s | > 1000/s | 工作集超出内存 |
| 索引命中率 | > 95% | < 80% | 检查查询计划 |

### 7.3 推荐监控工具

- **MongoDB Atlas (Cloud)**：自带监控告警
- **Percona Monitoring and Management (PMM)**：免费开源
- **Prometheus + mongodb_exporter**：自建监控首选
- **Ops Manager (免费版)**：官方企业级监控
- **MongoDB Compass**：图形化查询分析工具

## 八、总结

| 模块 | 核心要点 |
|------|---------|
| 文档建模 | 按访问模式设计，优先嵌入，避免深度嵌套 |
| 复制集 | 3 节点 PSA 最小配置，priority 控制选举 |
| 分片集群 | Config Server 必用 3 节点副本集，分片键选高基数字段 |
| 索引 | ESR 规则确定复合索引字段顺序，定期分析慢查询 |
| 聚合管道 | $match 尽早，索引覆盖，allowDiskUse 处理大数据 |
| 备份 | 逻辑(每日)+物理(周)双保险，定期验证恢复流程 |
| 监控 | Cache 命中率、复制延迟、磁盘空间为核心指标 |

> **一句话总结：** MongoDB 的灵活性和扩展性让开发者可以快速迭代，但要驾驭大规模生产环境，必须深刻理解文档建模、复制集、分片和索引这四大基石。
