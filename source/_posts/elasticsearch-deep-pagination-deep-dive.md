---
title: 【ES 实战】Elasticsearch 深度分页深度解析：from+size、Scroll 与 search_after 原理对比与生产选型
date: 2026-08-26 08:00:00
tags:
  - Java
  - Elasticsearch
  - 面试
  - 实战
categories:
  - Java
  - 中间件
  - Elasticsearch
author: 东哥
---

# 【ES 实战】Elasticsearch 深度分页深度解析：from+size、Scroll 与 search_after 原理对比与生产选型

## 面试官：ES 里为什么「深分页」性能差？from+size、scroll、search_after 有什么区别？

很多人在 ES 里翻到第 10000 条就报错，或者直接用 scroll 做普通分页导致内存爆炸。深分页是 ES 面试和实战的高频痛点，本文从**分布式查询原理**出发，把三种分页方案的机制、代价和选型讲清楚。

## 一、先理解 ES 查询的分布式本质

ES 的一个索引分布在多个分片（shard）上。执行一次搜索，流程是：

1. **协调节点（Coordinating Node）** 接收查询请求；
2. 把请求**广播到所有分片**（主分片或副本）；
3. 每个分片**本地排序**后返回**前 size 条**（以及聚合信息）；
4. 协调节点**归并排序**所有分片的结果，取全局前 size 条返回。

**关键结论：ES 的排序是「先分片排序、再全局归并」**，不是全局一次性排序。这直接决定了深分页的代价。

## 二、from + size：最直观但最贵

```json
GET /order/_search
{
  "from": 10000,
  "size": 10,
  "sort": [{ "create_time": "desc" }]
}
```

### 2.1 代价分析

`from=10000, size=10` 时，**每个分片都要先取出前 10010 条**，协调节点收到 `分片数 × (from + size)` 条数据再归并，最后只返回 10 条：

```
协调节点需要处理的数据量 = 分片数 × (from + size)
3 个分片 → 3 × 10010 = 30030 条被排序，最终只返回 10 条
```

**数据被「捞起来排序后又扔掉」**，from 越大浪费越严重：

- **CPU**：每个分片都要执行 O(from+size) 的排序；
- **内存**：协调节点要缓冲全部分片结果（`search.max_buckets` 管聚合，分页则受 `index.max_result_window` 限制）；
- **网络**：传输大量无用数据。

### 2.2 硬限制：max_result_window

```json
// 默认限制 from + size ≤ 10000
// 超过会报错：
{
  "error": {
    "reason": "Result window is too large, from + size must be less than or equal to: [10000] ..."
  }
}
```

这个限制可以调大：

```json
PUT /order/_settings
{
  "index.max_result_window": 100000
}
```

**但调大不等于免费**——它只是把「内存爆炸」的阈值推后，深分页的 O(N) 代价依然存在。**业务上正确做法是换方案，而不是调参**。

### 2.3 适用场景

- 页码跳转的**浅分页**（前几百页以内）；
- 数据量小、用户不深翻的场景；
- 需要「跳转到任意页」的交互（如后台管理列表）。

## 三、Scroll：快照式游标（适合大数据量全量拉取）

```java
// 1. 初始化 scroll，返回 scrollId（快照在服务端保留 1 分钟）
POST /order/_search?scroll=1m
{
  "size": 1000,
  "query": { "match_all": {} }
}

// 2. 用 scrollId 翻页
POST /_search/scroll
{
  "scroll": "1m",
  "scroll_id": "DXF1ZXJ5QW5kRmV0Y2gB..."
}
```

### 3.1 工作原理

- 第一次请求时，ES 为查询**生成一份一致性快照**（基于 segment），返回 `_scroll_id`；
- 后续翻页**只依赖 scrollId**，不再带查询条件，按 `size` 一批批取；
- 快照在**服务端存活**（默认 1 分钟，每次续期），取完后需要**显式清理**：

```java
DELETE /_search/scroll
{
  "scroll_id": ["DXF1ZXJ5QW5kRmV0Y2gB..."]
}
```

### 3.2 优缺点

| 优点 | 缺点 |
|------|------|
| 大数据量全量导出稳定（10 万、百万级） | 快照占用服务端资源（segment 不能被合并回收） |
| 一致性视图：遍历期间数据不变 | 是**顺序游标**，不能随机跳页 |
| 性能比 from+size 深翻好 | 游标过期后需要重来 |
| | 不适合用户实时交互（数据是旧的） |

### 3.3 适用场景

- **数据导出**（导出到 Excel、同步到数仓/其他系统）；
- 全量数据扫描（reindex、数据迁移）；
- 后台批量任务（滚动处理全量数据）。

⚠️ 常见误区：**不要用 scroll 做用户界面的分页**——快照是「旧数据」，且服务端资源会累积。这也是官方明确建议的：scroll 用于处理大量文档，不是实时搜索。

## 四、search_after：实时游标分页（生产首选）

```java
// 第一页：正常查询，记住最后一条的 sort 值
GET /order/_search
{
  "size": 10,
  "sort": [
    { "create_time": "desc" },
    { "_id": "desc" }     // ★ 必须加一个唯一值兜底，保证排序稳定
  ],
  "query": { "match_all": {} }
}

// 第二页：把上一页最后一条的 sort 值传进来
GET /order/_search
{
  "size": 10,
  "search_after": [1724659200000, "order_12345"],
  "sort": [
    { "create_time": "desc" },
    { "_id": "desc" }
  ]
}
```

### 4.1 工作原理

`search_after` 的思路是：**「从这条记录之后继续找」**——协调节点把 `search_after` 的排序值下发给每个分片，分片从**对应位置之后**开始取，而不是从头排序取前 N 条：

- 每个分片只需返回 size 条「游标之后」的数据；
- 协调节点归并后同样返回 size 条；
- **代价与页数无关**，稳定在 O(size × 分片数) 级别。

### 4.2 使用铁律

1. **排序字段必须唯一确定顺序**：`sort` 里除了业务字段，**必须带 `_id` 或 `_uid` 等唯一值兜底**，否则排序值相同的文档会重复/遗漏（排序不稳定）；
2. **不能用 search_after 向前翻页**：它只能向后，回到上一页需要重新从第一页走（通常前端缓存已加载的数据）；
3. **参数格式**：`search_after` 的值是**上一页最后一条文档的 sort 数组值**（含格式化后的时间戳）；
4. **不要配 from**：`search_after` 与 `from` 互斥（同时用会报错）。

### 4.3 适用场景

- **实时列表的「加载更多」**（下拉刷新、无限滚动）；
- 需要**看到最新数据**的深翻场景（快照无关）；
- 日志检索、订单列表等生产系统的主流深分页方案。

## 五、三种方案核心对比表

| 维度 | from + size | scroll | search_after |
|------|------------|--------|--------------|
| 本质 | 全局偏移量 | 服务端一致性快照 | 游标定位（排序值） |
| 代价 | O(from × 分片数)，深翻爆炸 | 快照占用服务端资源 | 每页固定 O(size)，与深度无关 |
| 实时性 | ✅ 实时 | ❌ 快照（旧数据） | ✅ 实时 |
| 随机跳页 | ✅ 支持 | ❌ 顺序 | ❌ 只能向后 |
| 硬限制 | 默认 from+size ≤ 10000 | 无（但资源有上限） | 无（受 size 限制） |
| 数据一致性 | 翻页期间可能重复/遗漏 | 强一致（快照） | 翻页期间可能重复/遗漏 |
| 典型场景 | 浅分页、后台列表跳页 | 全量导出、reindex | 实时深翻、「加载更多」 |

## 六、生产实践：Java 代码示例（RestHighLevelClient → ES 8 新客户端）

```java
// ES 8.x 官方客户端 search_after 分页
SearchRequest request = new SearchRequest("order");
SearchSourceBuilder source = new SearchSourceBuilder()
        .size(10)
        .query(QueryBuilders.matchAllQuery())
        .sort("create_time", SortOrder.DESC)
        .sort("_id", SortOrder.DESC);   // 唯一值兜底

Object[] searchAfter = null;
for (int page = 0; page < 100; page++) {
    if (searchAfter != null) {
        source.searchAfter(searchAfter);   // 传上一页游标
    }
    SearchResponse response = client.search(request, RequestOptions.DEFAULT);
    SearchHit[] hits = response.getHits().getHits();
    if (hits.length == 0) break;

    // 处理本页数据 ...

    // 记录游标：最后一条的排序值
    searchAfter = hits[hits.length - 1].getSortValues();
}
```

**导出场景的 scroll 写法（ES 8 客户端）**：

```java
SearchRequest request = new SearchRequest("order");
SearchSourceBuilder source = new SearchSourceBuilder().size(1000).query(QueryBuilders.matchAllQuery());
request.source(source);
request.scroll(TimeValue.timeValueMinutes(1));

SearchResponse response = client.search(request, RequestOptions.DEFAULT);
String scrollId = response.getScrollId();
while (response.getHits().getHits().length > 0) {
    // 处理本批 ...
    SearchScrollRequest scrollRequest = new SearchScrollRequest(scrollId)
            .scroll(TimeValue.timeValueMinutes(1));
    response = client.scroll(scrollRequest, RequestOptions.DEFAULT);
    scrollId = response.getScrollId();
}
// 记得清理游标
ClearScrollRequest clear = new ClearScrollRequest();
clear.addScrollId(scrollId);
client.clearScroll(clear, RequestOptions.DEFAULT);
```

## 七、面试官追问环节

**Q1：为什么 from+size 深分页慢？**
ES 是分布式架构，`from + size` 意味着**每个分片都要取出并排序前 from+size 条**，协调节点归并的数据量 = 分片数 × (from+size)，绝大多数数据被排序后又丢弃。翻得越深，浪费越严重。

**Q2：max_result_window 调大可以吗？**
可以调，但只是把内存风险推后，深分页的 O(N) 开销还在，且可能 OOM。正确姿势是换 search_after。

**Q3：scroll 和 search_after 都能深翻，怎么选？**
看数据一致性需求：scroll 是**快照**，适合导出/迁移（数据要稳定）；search_after 是**实时**，适合用户交互（能看到最新数据）。再看资源：scroll 占用服务端快照资源，不适合长期挂着的用户会话。

**Q4：search_after 为什么必须加 _id 排序？**
分页的稳定性要求「全局顺序唯一」。如果只按 create_time 排序，相同时间的文档顺序不确定，翻页时会**重复或漏掉**数据。`_id` 全局唯一，作为第二排序字段保证顺序确定。

**Q5：SQL 里的 LIMIT 深分页和 ES 有什么异同？**
同：都是「捞起来再丢」的偏移量模式；异：ES 是**分布式多分片**，每个分片都要执行偏移，代价是「分片数 × 偏移量」，比单机数据库的深分页更早遇到瓶颈。

**Q6：还有没有别的方案？**
有：**PIT（Point In Time）**——search_after 的官方推荐组合，先创建 PIT 固定查询上下文，再配合 search_after 翻页，既避免 scroll 的资源占用，又能保证翻页过程中索引状态稳定。ES 7.10+ 推荐 `PIT + search_after` 替代 scroll。

## 八、总结

| 场景 | 方案 |
|------|------|
| 用户浅分页（<10000，可跳页） | from + size |
| 深翻页、「加载更多」（实时） | search_after（+ 可选 PIT） |
| 全量导出、reindex | scroll |
| 翻页中数据必须稳定 | scroll（快照）或 PIT |

记住一句话：**ES 的分页难点不在语法，而在分布式代价模型**——任何方案都要回答「每个分片要付出多少成本」。把这一点讲透，深分页这道题就是送分题。
