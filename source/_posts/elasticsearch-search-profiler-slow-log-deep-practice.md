---
title: 【ES 底层】Elasticsearch Profile API 与慢查询日志深度实战：把「查询慢」拆到每个 Lucene 方法
date: 2026-11-19 08:10:00
tags:
  - Java
  - Elasticsearch
  - 性能优化
  - Lucene
  - 搜索引擎
categories:
  - 中间件
author: 东哥
---

# 【ES 底层】Elasticsearch Profile API 与慢查询日志深度实战

## 前言

线上一个商品搜索接口 P99 从 80ms 涨到 600ms。你打开 Kibana，看到 `took` 是 580，于是开始猜：

- 是不是分片太多？
- 是不是 `wildcard` 太慢？
- 是不是该加缓存？

猜错三次之后，你开始怀疑人生。问题在于：**`took` 只是一个总数，它不告诉你钱花在哪儿了。**

Elasticsearch 其实给了两把手术刀：

1. **Profile API**：把一次查询在每个分片上的执行树展开，精确到 `next_doc`、`advance`、`build_scorer` 这些 Lucene 方法级的纳秒耗时；
2. **慢查询日志（slow log）**：在生产环境低成本采样，回答「哪些查询慢、慢在 query 还是 fetch」。

这两者配合，才能把「查询慢」从一句抱怨变成一张可执行的账单。本文按「耗时口径 → Profile 用法 → breakdown 读法 → 慢日志 → 常见形态 → Java 落地」讲完。

---

## 一、先对齐口径：`took` 到底统计了什么

一次 `_search` 的耗时至少有四个层次：

| 层次 | 指标 | 包含什么 | 不包含什么 |
|---|---|---|---|
| 客户端 | 应用侧 RT | 网络 + 排队 + 序列化 + 服务端 | —— |
| 协调节点 | `took` | query + fetch 的协调处理 | 网络传输、客户端反序列化、HTTP 排队 |
| 分片 | `_shards.total` / profile `time_in_nanos` | 单个分片内的 Lucene 调用 | 跨分片合并、协调开销 |
| Lucene 方法 | profile `breakdown` | `next_doc`/`advance`/`score` 等 | JVM 安全点、GC、页缓存缺失 |

所以下面这些「对不上」都是正常的：

- `took=580`，但所有分片 profile 加起来只有 200ms：差额在协调、合并、序列化；
- 单分片 profile 的 `time_in_nanos` 之和远大于 `took`：分片是并行执行的，不能直接相加；
- profile 显示 query 只要 20ms，但接口 600ms：慢在 fetch、聚合或网络。

**第一条实践原则：先确定慢在哪一层，再决定用哪个工具。** query 慢看 profile，fetch 慢看慢日志的 fetch 段，聚合慢既不看 profile 也不看 `took` 的 query 部分。

---

## 二、Profile API：开启方式与返回结构

```http
GET /products/_search
{
  "profile": true,
  "human": true,
  "size": 20,
  "query": {
    "bool": {
      "must": [
        { "match": { "title": "蓝牙耳机" } }
      ],
      "filter": [
        { "term": { "status": "on_sale" } },
        { "range": { "price": { "gte": 100, "lte": 500 } } }
      ]
    }
  }
}
```

`human: true` 会把纳秒转成 `"1.2ms"` 这种可读格式；程序解析时关掉它，用原始数字。

返回结构（省略无关字段）：

```json
{
  "took": 42,
  "timed_out": false,
  "profile": {
    "shards": [
      {
        "id": "[node-1][products][2]",
        "searches": [
          {
            "query": [
              {
                "type": "BooleanQuery",
                "description": "+title:蓝牙 +title:耳机 #status:on_sale #price:[100 TO 500]",
                "time_in_nanos": 8123456,
                "breakdown": {
                  "create_weight": 12000,
                  "build_scorer": 305000,
                  "next_doc": 6800000,
                  "advance": 0,
                  "score": 780000,
                  "match": 0,
                  "compute_max_score": 0,
                  "shallow_advance": 0,
                  "set_min_competitive_score": 0
                },
                "children": [
                  { "type": "TermQuery", "description": "title:蓝牙", "time_in_nanos": 900000, "...": "..." }
                ]
              }
            ],
            "rewrite_time": 45000,
            "collector": [
              {
                "name": "SimpleTopScoreDocCollector",
                "reason": "search_top_hits",
                "time_in_nanos": 2100000
              }
            ]
          }
        ],
        "aggregations": []
      }
    ]
  }
}
```

四个必须会读的字段：

1. `shards[].id`：`[节点][索引][分片号]`，用来定位热点分片；
2. `query[]`：一棵树，父子关系就是 Lucene 的 `Weight → Scorer → TwoPhaseIterator` 结构；
3. `rewrite_time`：查询重写耗时，`wildcard`/`prefix`/`regexp` 的重写经常在这里爆炸；
4. `collector[]`：收集器耗时，深分页、聚合、排序都体现在这里。

> 注意 `aggregations` 永远是空数组。**Profile API 只分析 query 阶段，不分析聚合。** 聚合慢要用 `_nodes/hot_threads`、`_nodes/stats/indices/search` 和慢日志，别在 profile 里找答案。

---

## 三、breakdown 十个字段，其实只有四类含义

| 字段 | 触发阶段 | 高了说明什么 |
|---|---|---|
| `create_weight` | 每次查询构造 Weight | 查询对象构造/缓存未命中，通常很小 |
| `build_scorer` | 构造 Scorer，准备迭代器 | 脚本、`function_score`、复杂的 `nested` 准备成本高 |
| `next_doc` | 顺序推进文档 | **最常见的耗时项**，倒排扫描本身慢 |
| `advance` | 跳转（多用于交集/过滤） | 跳表效率、稀疏 posting list |
| `score` | 计算相关性分数 | 打分公式复杂、脚本打分、`boost` 多 |
| `match` | 两阶段迭代器的确认 | phrase、`span_near`、位置校验 |
| `compute_max_score` | WAND/Block-Max 上界计算 | 通常很小，除非打分器很多 |
| `shallow_advance` | 浅层跳转 | 大量 `term` 交集 |
| `set_min_competitive_score` | Top-K 剪枝 | 竞争激烈时会有，正常 |
| `rewrite_time`（同级） | 查询重写 | `wildcard`/`prefix`/`regexp` 展开成海量 term |

### 3.1 读法：先看叶子，再看父节点

父节点的 `time_in_nanos` 包含子节点，直接看根节点只会得到「都很慢」。正确顺序：

1. 找到 `time_in_nanos` 最大的**叶子**；
2. 看它的类型：`TermQuery` / `PointRangeQuery` / `WildcardQuery` / `ScriptScoreQuery`；
3. 看它的 `next_doc` 与 `advance` 比例：顺序扫描多还是跳转多；
4. 再看父级 `BooleanQuery` 的 `build_scorer`，判断是不是 clause 太多。

### 3.2 一个真实例子

某商品搜索的 profile 片段：

```
BooleanQuery  time=210ms
├── WildcardQuery title=*耳机*   time=180ms   next_doc=175ms
├── TermQuery status=on_sale     time=2ms
└── PointRangeQuery price         time=5ms
rewrite_time = 92ms
```

`rewrite_time=92ms` 说明通配符被重写成大量 term；`next_doc=175ms` 说明重写后的 term 集合在逐篇扫描。两个数字合起来就是结论：**前导通配符（leading wildcard）无法利用词典前缀，必须全量展开 + 逐文档验证**。

修复不是「加机器」，而是换索引结构：`ngram` 分词或 `search_as_you_type` 字段。改完后同一个查询 `next_doc` 降到 4ms。

---

## 四、慢查询日志：生产环境的低成本采样

Profile 开销很大（要额外统计每个方法），只能在排障时对单条查询开。生产环境常驻的是慢日志。

### 4.1 索引级动态配置

```http
PUT /products/_settings
{
  "index.search.slowlog.threshold.query.warn":  "1s",
  "index.search.slowlog.threshold.query.info":  "500ms",
  "index.search.slowlog.threshold.query.debug": "200ms",
  "index.search.slowlog.threshold.query.trace": "50ms",
  "index.search.slowlog.threshold.fetch.warn":  "500ms",
  "index.search.slowlog.threshold.fetch.info":  "200ms",
  "index.search.slowlog.level": "info"
}
```

日志按天滚动，输出到 `logs/<cluster>.index_search_slowlog.log`。一条典型记录：

```
[2026-11-19T09:12:33,451][INFO ][index.search.slowlog.query]
[node-1] [products][2] took[612.4ms], took_millis[612],
total_hits[18342], types[], stats[],
search_type[QUERY_THEN_FETCH], total_shards[6],
source[{"query":{"wildcard":{"title":"*耳机*"}},"size":20}],
extra_source[]
```

### 4.2 query 慢还是 fetch 慢，是两类问题

| 日志类型 | 含义 | 常见原因 |
|---|---|---|
| `slowlog.query` | 查询+收集阶段 | 通配符、脚本、巨量 `terms`、`nested`、打分复杂 |
| `slowlog.fetch` | 取回 `_source` 阶段 | 深分页、单文档巨大、`_source` 未裁剪、跨机房取数 |

`fetch` 慢非常容易被误判成 query 慢。典型症状：query 阶段 20ms，fetch 阶段 800ms，`size=1000`，每条文档 `_source` 有 200KB。解法是 `_source: ["id","title","price"]` 裁剪字段，或者用 `fields` + `doc_values` 只取需要的列。

### 4.3 日志采样与成本

慢日志本身有序列化成本。全量 trace 级别在高 QPS 下会拖慢集群。建议：

- `warn` 阈值设成业务 P99 的 2 倍，只抓真正的异常；
- `info` 用于日常分析，保留 3~7 天；
- 不要在全部索引上开 `trace`；
- 用 ILM 管理慢日志索引（如果走 Filebeat 采集）。

---

## 五、`timeout` 参数：它不会救你

很多人以为加了 `"timeout": "50ms"` 就能防止慢查询拖垮集群：

```json
{ "timeout": "50ms", "query": { "wildcard": { "title": "*耳机*" } } }
```

实际行为：

- 超时后返回**部分结果**，`timed_out: true`；
- Lucene 只在**每批文档/每个段**检查一次超时，单条 `next_doc` 内部的耗时无法中断；
- 协调节点仍要等待所有分片返回（或超时），线程和队列照占；
- 分页结果不保证完整，业务侧如果不检查 `timed_out` 会静默丢数据。

所以 `timeout` 是「保护客户端 RT」的兜底，不是「保护集群」的手段。真正保护集群的是：限制 `max_concurrent_shard_requests`、搜索线程池队列、以及把慢查询本身修好。

---

## 六、六种高频慢查询形态与 profile 特征

| 形态 | profile 特征 | 根因 | 修复 |
|---|---|---|---|
| 前导通配符 `*x*` | `rewrite_time` 高 + 叶子 `next_doc` 高 | 无法走词典前缀，全量展开 | ngram / `search_as_you_type` |
| 巨量 `terms` | `BooleanQuery` 子节点成百上千，`build_scorer` 高 | clause 爆炸 | `terms` lookup、预聚合、拆查询 |
| 脚本打分 | `score` 占比 > 50% | 每文档执行脚本 | 预计算字段、`runtime_field` 谨慎用 |
| 深分页 | `collector` 时间高，`from+size` 大 | 每分片都要取 `from+size` 条 | `search_after` + PIT |
| `nested` 查询 | `build_scorer` + `advance` 高 | nested 文档需 join | 反范式化、`nested` 层级收敛 |
| 多字段 `multi_match` | 多个 `TermQuery` 叶子，`score` 高 | 字段多、boost 多 | `copy_to` 合并字段、减少字段数 |

一个容易忽略的点：**filter 里的 `term` 不会打分，但会参与 `advance`**。把能过滤的条件全放进 `filter`，不仅省 `score`，还能让 Lucene 用跳表快速缩小候选集。

---

## 七、Java 侧：把 profile 变成可回归的基线

排障时手工点 Kibana 可以，但真正有价值的是**把 profile 变成 CI 里的性能回归门禁**：固定数据集、固定分片数、固定查询，比较关键叶子节点的耗时。

```java
public record ProfileNode(String type, String description, long timeInNanos,
                          Map<String, Long> breakdown, List<ProfileNode> children) {}

public List<ProfileNode> profile(ElasticsearchClient client, String index, Query query) throws IOException {
    SearchResponse<Void> resp = client.search(s -> s
            .index(index)
            .size(0)
            .profile(true)
            .query(query), Void.class);

    List<ProfileNode> roots = new ArrayList<>();
    for (var shard : resp.profile().shards()) {
        for (var search : shard.searches()) {
            for (var q : search.query()) {
                roots.add(convert(q));
            }
        }
    }
    return roots;
}

private ProfileNode convert(QueryProfile q) {
    Map<String, Long> bd = new LinkedHashMap<>();
    var b = q.breakdown();
    bd.put("create_weight", b.createWeight());
    bd.put("build_scorer", b.buildScorer());
    bd.put("next_doc", b.nextDoc());
    bd.put("advance", b.advance());
    bd.put("score", b.score());
    bd.put("match", b.match());
    List<ProfileNode> children = q.children().stream().map(this::convert).toList();
    return new ProfileNode(q.type(), q.description(), q.timeInNanos(), bd, children);
}

// 找出最慢的 5 个叶子节点
public List<ProfileNode> slowestLeaves(List<ProfileNode> roots, int topN) {
    List<ProfileNode> leaves = new ArrayList<>();
    Deque<ProfileNode> stack = new ArrayDeque<>(roots);
    while (!stack.isEmpty()) {
        ProfileNode n = stack.pop();
        if (n.children().isEmpty()) leaves.add(n);
        else stack.addAll(n.children());
    }
    leaves.sort(Comparator.comparingLong(ProfileNode::timeInNanos).reversed());
    return leaves.subList(0, Math.min(topN, leaves.size()));
}
```

CI 断言不要卡绝对耗时（机器抖动大），而是卡**结构比例**：

```java
// 断言：wildcard 类查询的 next_doc 不得超过总耗时的 60%
double ratio = (double) leaf.breakdown().get("next_doc") / leaf.timeInNanos();
assertThat(ratio).isLessThan(0.6);
```

结构比例对机器性能不敏感，能稳定捕获「有人把 `term` 改成了 `wildcard`」这类回归。

### 7.1 采样策略

- 线上：对 1% 的慢请求开 profile，异步写分析表；
- 预发：全量开，跑基准查询集；
- 本地：单测里用 `@Testcontainers` 起单节点，固定 1 分片，结果可比。

---

## 八、一个完整案例：从 580ms 到 45ms

**背景**：商品搜索，6 分片，1200 万文档，查询是 `bool(must: match(title), filter: term(status), range(price))`，P99 580ms。

**Step 1：慢日志定位**

```
slowlog.query took[520ms] total_hits[18342]
source: {"query":{"bool":{"must":[{"wildcard":{"title":"*耳机*"}}]...}}}
```

发现线上实际用的是 `wildcard`，不是设计文档里的 `match`。

**Step 2：profile 拆解**

```
WildcardQuery title=*耳机*   time=470ms  next_doc=455ms
rewrite_time=88ms
BooleanQuery 父节点           build_scorer=12ms
```

**Step 3：修复**

新增 `title.ngram` 字段（`ngram` 2~3，`search_analyzer=standard`），写入时双写，查询改 `match(title.ngram, "耳机")` + 原字段 `match` 做精排。

**Step 4：验证**

```
TermQuery title.ngram:耳机  time=9ms  next_doc=7ms
took 从 580ms → 45ms
```

**Step 5：加门禁**

把这条查询加入预发基准集，断言 `next_doc_ratio < 0.5` 且 `rewrite_time < 10ms`，防止有人改回通配符。

---

## 九、面试追问

**Q1：`took` 和 profile 的 `time_in_nanos` 为什么对不上？**

`took` 是协调节点视角的 query+fetch 总时间，包含跨分片合并、序列化等；profile 是分片内 Lucene 调用耗时，分片并行执行不能直接相加，也不包含协调开销和网络。

**Q2：Profile API 能分析聚合吗？**

不能。它只 profile query 阶段，`aggregations` 数组恒为空。聚合慢要看 hot_threads、节点 stats 和慢日志。

**Q3：慢日志里 query 和 fetch 分别代表什么？**

query 是查询与收集（打分、排序、取 Top-K），fetch 是按 docId 取回 `_source`。query 慢通常是检索结构问题，fetch 慢通常是深分页或单文档过大。

**Q4：`timeout` 参数能防止慢查询打挂集群吗？**

不能。它只在段/批次边界检查，无法中断单次 `next_doc`，协调节点仍要等分片返回，只是让客户端早点拿到部分结果。

**Q5：为什么 `filter` 里的条件更快？**

不参与打分（跳过 `score`），且 Lucene 可以对 filter 子句使用跳表 `advance` 快速求交集，还能被 query cache 缓存为 bitset。

---

## 十、总结

- **先分层定位**：应用 RT / `took` / 分片 profile / Lucene 方法，四层口径不同，别混着看；
- **Profile 看叶子**：`rewrite_time` 抓重写，`next_doc` 抓扫描，`build_scorer` 抓构造，`score` 抓打分；
- **慢日志抓常态**：query 与 fetch 分开看，阈值按 P99 设，别全量 trace；
- **`timeout` 不是保护伞**：它救客户端，不救集群；
- **把 profile 变成门禁**：结构比例断言比绝对耗时稳定得多。

查询优化最怕「凭感觉调参」。Profile 的价值不是告诉你一个数字，而是告诉你**这 580ms 里，有 455ms 花在了逐篇扫描重写后产生的四万个 term 上**。看到这句话，方案自然就有了。
