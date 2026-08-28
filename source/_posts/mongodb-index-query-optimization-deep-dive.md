---
title: 【MongoDB 实战】MongoDB 索引与查询性能优化深度实战：从 explain 到聚合管道调优
date: 2026-08-28 08:00:00
tags:
  - Java
  - MongoDB
  - 数据库
  - 实战
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MongoDB 实战】MongoDB 索引与查询性能优化深度实战：从 explain 到聚合管道调优

## 面试官：MongoDB 的索引和 MySQL 的 B+ 树索引有什么区别？

MongoDB 是文档型数据库的标杆，Java 后端用它存订单、日志、用户画像、爬虫数据非常普遍。但很多人只会 `find()`，一遇到慢查询就懵。本文从**索引底层结构**讲起，覆盖索引设计、explain 分析、聚合管道优化、慢查询治理四个层面，全部带实战命令。

## 一、MongoDB 索引的底层：B 树 vs B+ 树

这是面试高频题。MySQL InnoDB 用 **B+ 树**（非叶子节点不存数据，叶子节点链表相连），MongoDB 用的是 **B 树变体（WiredTiger 引擎）**，每个节点既存键也存值：

| 维度 | MySQL InnoDB（B+树） | MongoDB WiredTiger（B树） |
|------|---------------------|--------------------------|
| 数据存放 | 只在叶子节点 | 每个节点都可能带值（doc 指针） |
| 范围扫描 | 叶子链表，高效 | 中序遍历，稍慢 |
| 随机点查 | O(log n) 多一次叶子寻址 | O(log n) 更扁平 |
| 适用负载 | 复杂范围查询、关联 | 文档点查、写入密集 |

**结论**：MongoDB 的索引设计目标不是"复杂 SQL 优化"，而是**为文档点查和高并发写入服务**。所以 MongoDB 里没有 join，靠的是**嵌套文档 + 冗余字段 + 聚合管道**。

索引类型一览：

| 索引类型 | 说明 | 典型场景 |
|----------|------|----------|
| 单字段索引 | `{userId: 1}` | 按用户查 |
| 复合索引 | `{userId: 1, createTime: -1}` | 用户+时间排序 |
| 多键索引 | `{tags: 1}`（数组字段） | 标签查询 |
| 地理索引（2dsphere） | 经纬度 | 附近的人 |
| 文本索引 | 全文检索 | 搜索 |
| TTL 索引 | 过期自动删除 | 会话、日志清理 |
| 哈希索引 | 分片键等值查询 | 分片集群 |

## 二、复合索引设计：ESR 原则

复合索引字段顺序怎么定？MongoDB 官方给出了 **ESR 原则**：

1. **E（Equality）等值查询字段放最前**：`{status: "PAID"}`
2. **S（Sort）排序字段次之**：`{createTime: -1}`
3. **R（Range）范围查询字段最后**：`{amount: {$gte: 100}}`

```javascript
// 查询：status 等值 + createTime 排序 + amount 范围
// 索引设计应为：
db.orders.createIndex({ status: 1, createTime: -1, amount: 1 })

db.orders.find({
  status: "PAID",
  amount: { $gte: 100 }
}).sort({ createTime: -1 })
```

为什么等值在前？因为索引扫描时，等值条件能**精确锁定索引段**；排序字段紧跟着能让结果**天然有序**，省掉内存排序（否则触发 32MB 内存排序限制或需要 allowDiskUse）；范围字段放最后是因为它只能锁定一个区间。

**反面教材**：`{amount: 1, status: 1, createTime: -1}`——范围字段在前，等值条件无法利用索引定位，退化成索引扫描。

## 三、explain：读懂执行计划

慢查询第一件事就是 `explain()`。三种模式：

| 模式 | 说明 |
|------|------|
| `queryPlanner` | 只生成执行计划（默认） |
| `executionStats` | 执行并返回统计（最常用） |
| `allPlansExecution` | 所有候选计划都执行，最详细 |

```javascript
db.orders.find({ status: "PAID", userId: "u10086" })
  .sort({ createTime: -1 })
  .explain("executionStats")
```

关键字段解读：

```
"winningPlan": {
  "stage": "FETCH",          // 先从索引取 doc，再回表取文档
  "inputStage": {
    "stage": "IXSCAN",       // 走了索引！关键标志
    "indexName": "status_1_createTime_-1_amount_1",
    "direction": "backward"  // 索引倒序扫描，配合 -1 排序
  }
},
"executionStats": {
  "nReturned": 100,           // 实际返回条数
  "totalDocsExamined": 100,   // 扫描文档数
  "totalKeysExamined": 100,   // 扫描索引条目数
  "executionTimeMillis": 12
}
```

**判断标准**：

- `IXSCAN` + `totalDocsExamined == nReturned` → 完美，索引全覆盖。
- `COLLSCAN`（全表扫描）→ 没走索引，赶紧建。
- `totalDocsExamined` 远大于 `nReturned` → 索引选择性差或字段顺序不对。
- `SORT` stage 出现 → 排序没走索引，产生内存排序。

## 四、聚合管道（Aggregation）优化

聚合是 MongoDB 的性能重灾区。管道是**顺序执行**的，所以**尽早过滤、缩小数据量**是铁律：

```javascript
// 反例：先 unwind 再 match，大集合直接爆炸
db.orders.aggregate([
  { $unwind: "$items" },          // 每条订单膨胀成 N 条
  { $match: { "items.sku": "A001" } }  // 过滤放太晚了！
])

// 正例：先 match 缩小范围
db.orders.aggregate([
  { $match: { "items.sku": "A001", status: "PAID" } },  // 用上索引
  { $unwind: "$items" },
  { $group: { _id: "$userId", total: { $sum: "$items.price" } } },
  { $sort: { total: -1 } },
  { $limit: 10 }
])
```

优化要点：

1. **$match 前置**，且 $match 条件要能用索引（对管道第一个 $match 建索引）。
2. **$project 尽早裁剪字段**，减少管道内文档体积。
3. **$unwind 后跟 $match 用 `$elemMatch` 或数组索引替代**：如果只是过滤数组元素，用 `find({items: {$elemMatch: {sku: "A001"}}})` 配合多键索引，比 unwind 快一个数量级。
4. **$lookup 不是 join 的免费午餐**：它在管道内逐文档执行，右表字段要建索引，且尽量让左表先被过滤到最小。
5. 大排序/分组超过 100MB 内存时加 `{ allowDiskUse: true }`，但这是兜底不是优化。

## 五、慢查询治理：从发现到解决

### 第一步：开启慢查询日志

```javascript
// 超过 200ms 的查询记录到 system.profile
db.setProfilingLevel(1, { slowms: 200 })
// 查看慢查询
db.system.profile.find({ millis: { $gt: 200 } })
  .sort({ ts: -1 }).limit(20)
```

生产环境建议用 **Database Profiler 或 Prometheus + mongodb_exporter** 持续监控，而不是事后查。

### 第二步：常见慢查询根因

| 根因 | 特征 | 解法 |
|------|------|------|
| 无索引 | explain 显示 COLLSCAN | 按 ESR 建复合索引 |
| 索引选择性差 | IXSCAN 但扫描量大 | 换高基数字段做前缀 |
| 内存排序 | 出现 SORT stage | 排序字段纳入复合索引 |
| 大文档读取 | FETCH 回表 IO 大 | $project 裁剪字段 |
| 正则查询 | `$regex` 无前缀锚定 | 用文本索引或前缀正则 `^abc` |
| 深翻页 | skip 巨大 | 改用 `_id` 游标或范围查询 |
| 写放大 | 频繁 update 大文档 | 拆文档、用 $set 局部更新 |

### 第三步：Java 侧配合

```java
// Spring Data MongoDB：用 Query 指定 hint 强制索引
Query query = new Query(
    Criteria.where("status").is("PAID")
            .and("userId").is("u10086")
);
query.with(Sort.by(Direction.DESC, "createTime"));
query.withHint("status_1_createTime_-1_amount_1");  // 强制走索引
List<Order> list = mongoTemplate.find(query, Order.class);
```

## 六、索引管理的最佳实践

1. **索引不是越多越好**：每个索引都拖慢写入（WiredTiger 写索引也是 B 树插入），写多读少的集合保持 3-5 个索引。
2. **后台建索引**：大集合建索引用 `createIndex({...}, {background: true})`，避免阻塞读写。
3. **TTL 索引清理日志**：`createIndex({createAt: 1}, {expireAfterSeconds: 604800})` 7 天自动过期，比定时任务删数据优雅得多。
4. **索引大小要能进内存**：索引常驻内存才有性能，索引总大小超过内存就会出现磁盘抖动。用 `db.collection.stats()` 看 `totalIndexSize`。

## 七、面试追问汇总

**Q1：MongoDB 为什么不用 B+ 树？**
答：MongoDB 面向文档读写，点查为主、范围查询为辅，B 树每个节点带值让点查路径更短（层数少）；MySQL 面向复杂 SQL 和范围扫描，B+ 树叶子链表让范围遍历更高效。两者都是为各自负载优化的选择。

**Q2：复合索引字段顺序怎么定？**
答：ESR 原则——等值字段在前、排序字段次之、范围字段最后；另外要考虑字段基数（区分度），高基数字段放前面通常选择性更好。

**Q3：聚合管道慢，第一步查什么？**
答：看执行计划（explain 支持 aggregate），确认第一个 $match 是否走索引、数据是否在管道早期被充分过滤；其次看有没有 $unwind 膨胀和内存排序。

**Q4：分片集群下索引要注意什么？**
答：分片键必须是所有查询的前缀才能路由到单个分片（否则广播查询）；分片键本身要有索引；片内索引按普通规则设计。分片键选不好（低基数/单调递增）会导致数据倾斜。

## 总结

MongoDB 性能优化的心法一句话：**让查询能用上索引，让管道尽早过滤**。建索引用 ESR 原则，慢查询用 explain 看 stage，聚合管道把 $match 前置，配合 Java 侧 hint 和 profiler 监控，一套组合拳下来，绝大多数慢查询都能在十分钟内定位解决。
