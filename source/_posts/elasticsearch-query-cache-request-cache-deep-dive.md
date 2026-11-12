---
title: 【ES 底层】查询缓存与请求缓存深度解析：bitset 过滤、段级失效与缓存友好查询设计
date: 2026-11-12 08:10:00
tags:
  - Elasticsearch
  - 查询缓存
  - 性能优化
  - Java
categories:
  - 中间件
author: 东哥
---

# 【ES 底层】查询缓存与请求缓存深度解析：bitset 过滤、段级失效与缓存友好查询设计

## 前言

"ES 不是有缓存吗？为什么同样的查询第二次还是 200ms？"

这是我被问得最多的问题之一。大多数人对 ES 缓存的理解停留在"文件系统缓存"这一层——只要数据在 page cache 里，查询就快。但真实情况是：**一次查询要走三层缓存，每层的命中条件完全不同，而 90% 的"缓存没生效"是因为查询写法本身不可缓存。**

本文把 ES 的缓存拆开讲清楚：Node Query Cache 缓存什么、Request Cache 为什么只对 `size: 0` 生效、段合并（merge）如何让缓存一夜清零，最后给出 Java 侧的观测代码和一套"缓存友好"的查询设计规范。

---

## 一、四层缓存全景：先搞清楚命中哪一层

| 层次 | 位置 | 缓存内容 | 默认大小 | 生效条件 |
|---|---|---|---|---|
| **Filesystem Cache（page cache）** | 操作系统 | 段文件（.fdt/.dvd/.tim/.doc） | 剩余内存的绝大部分 | 数据被读过一次且未被淘汰 |
| **Node Query Cache** | JVM 堆 | filter 查询的 **bitset**（文档匹配位图） | 堆的 10% | 查询在 filter context 且段足够大 |
| **Request Cache（Shard Request Cache）** | JVM 堆 | 整个分片请求的**结果集** | 堆的 1% | `size: 0` 的聚合/计数请求 |
| **Field Data Cache** | JVM 堆 | 字段值反查结构（仅 text 排序聚合时） | 受 `indices.fielddata.cache.size` 限制 | 对 text 字段做排序/聚合（应避免） |

这四层是**串联**关系，不是并联。一次 `term` 查询的路径是：

```
query → query cache 命中 bitset？(否) → 读倒排(postings) → 构造 bitset 并缓存
      → 取 doc id → 从 page cache 读 _source / doc_values → 返回
```

所以"第二次查询变快"可能只是 page cache 生效，而 query cache 根本没参与——两者的观测指标完全不同。

---

## 二、Node Query Cache：只缓存 filter 的 bitset

### 2.1 它到底缓存了什么

ES 不会缓存"查询结果"，它缓存的是**每个 segment 上一份 `DocIdSet`（通常是 Roaring Bitmap）**。对 1 亿文档的索引，一个高选择性 filter 的 bitset 可能只有几 KB；一个低选择性 filter（比如 `status: 'enabled'` 命中 90%）的 bitset 可能达到 MB 级。

这解释了两个反直觉现象：

1. **filter 不一定更快**。当 filter 命中率极高（>50%）时，构造 bitset + 遍历 bitset 的开销可能超过直接扫 postings。
2. **缓存会被"小而多的段"拖垮**。每个 segment 一份 bitset，500 个小段 = 500 份 bitset 条目，缓存很快被填满，LRU 频繁抖动。

### 2.2 关键配置

```yaml
# elasticsearch.yml
indices.queries.cache.size: 10%          # 默认 10% 堆，可写百分比或 512mb
indices.queries.cache.count: 10000       # 条目数上限（7.x+）
indices.queries.cache.all_segments: false # 是否对 <10000 文档的小段也缓存
```

`indices.queries.cache.all_segments` 是个容易踩的坑：默认 `false` 时，**文档数少于 10000 的段不会被缓存**。小索引（比如配置表、字典表）上做 filter 永远命中不了 query cache，你会误以为"缓存配置没生效"。

单查询级别可以用 `filter` 包裹来强制进入 filter context：

```json
{
  "query": {
    "bool": {
      "filter": [
        { "term": { "tenant_id": 42 } },
        { "range": { "created_at": { "gte": "2026-11-01", "lt": "2026-11-12" } } }
      ]
    }
  }
}
```

⚠️ 注意 `bool.must` 里**不产生打分**的查询也不会自动进 filter context，必须显式写在 `filter` 数组里（或者用 `constant_score`）。

### 2.3 缓存失效：merge 是最大杀手

Query cache 的 key 是 `(segment, query)`。段一旦被合并，旧段的 bitset 全部作废。所以：

- 写入量大 → 频繁 refresh 产生小段 → 频繁 merge → 缓存命中率长期低于 20%。
- 读多写少的索引（配置、商品、知识库）才是 query cache 的主战场。

生产经验：**每秒写入超过 1000 条的索引，不要指望 query cache**，优化方向应该是减少段数（`index.refresh_interval: 30s`）+ 用 doc_values 做聚合。

---

## 三、Request Cache：为什么只对 `size: 0` 生效

Request Cache 缓存的是**分片级请求的完整结果**，包括 `hits.total`、聚合桶、`_suggest`。它有两个硬性限制：

1. **`size` 必须为 0**。因为一旦返回文档，结果就与 `_source`、排序、fetch 阶段耦合，缓存体积不可控。
2. **只缓存"可确定"的请求**。凡是包含 `now()`、`Math.random()`、脚本、`preference` 随机分片的请求，都不会命中。

```json
// 会命中 request cache
GET orders/_search?request_cache=true
{
  "size": 0,
  "query": { "range": { "created_at": { "gte": "2026-11-01", "lt": "2026-11-12" } } },
  "aggs": { "by_status": { "terms": { "field": "status" } } }
}
```

注意这里的 `now` 被换成了**绝对时间字符串**。用 `now-7d` 写法的聚合，每次请求的 key 都不同，缓存命中率为 0——这是线上最常见的"聚合明明很慢却没缓存"的原因。

### 3.1 失效时机

Request cache 的失效粒度同样是 **segment 级**：只要分片发生 refresh 且产生了新段，该分片的 request cache 就整体失效。所以：

| 场景 | 建议 |
|---|---|
| 实时性要求 < 1s 的看板 | 关闭 request cache，直接查 |
| 分钟级/小时级报表 | 开启 + `refresh_interval: 60s` |
| 大促实时 GMV | 走独立的 rollup 索引或预聚合物化视图 |

### 3.2 配置

```yaml
indices.requests.cache.size: 1%   # 默认 1%，报表集群建议 3%~5%
```

---

## 四、缓存友好的查询设计规范

把上面的机制翻译成可执行的设计规则：

1. **filter 前移**：把"结构化、低基数、范围明确"的条件全部放 `bool.filter`，只把真正需要相关性打分的放 `must`。
2. **时间范围用绝对时间**：应用层算出 `[start, end)` 再传给 ES；不要依赖 `now-1d`。
3. **拆分高低选择性条件**：`tenant_id`（低基数）+ `order_no`（高基数）分别放 filter，让高选择性条件先缩小 bitset。
4. **避免 `script` 与 `wildcard` 前缀扫描**：`wildcard` 走 FST 前缀优化还能接受，`script` 直接放弃缓存。
5. **聚合优先走 `doc_values`**：数值/日期/keyword 的 `doc_values` 是列存，比 fielddata 快一个量级且不吃堆。
6. **控制段数量**：单分片段数稳定在 20~50，靠 `forceMerge`（只对只读索引）或合理的 `refresh_interval` 控制。

---

## 五、Java 侧观测：把缓存指标接进 Micrometer

光看"查询变快了"没用，要能证明是**哪一层**变快。下面的代码通过 `_nodes/stats` 拉取 query cache 与 request cache 的命中情况：

```java
public record CacheStats(long queryHit, long queryMiss, long queryEvictions,
                         long requestHit, long requestMiss) {}

@Component
public class EsCacheMetrics {

    private final RestClient restClient;
    private final MeterRegistry registry;

    public EsCacheMetrics(RestClient restClient, MeterRegistry registry) {
        this.restClient = restClient;
        this.registry = registry;
    }

    @Scheduled(fixedDelay = 30_000)
    public void collect() throws IOException {
        Request req = new Request("GET", "/_nodes/stats/indices/query_cache,request_cache");
        Response resp = restClient.performRequest(req);
        JsonNode root = new ObjectMapper().readTree(resp.getEntity().getContent());

        root.path("nodes").fields().forEachRemaining(e -> {
            String node = e.getKey();
            JsonNode qc = e.getValue().path("indices").path("query_cache");
            JsonNode rc = e.getValue().path("indices").path("request_cache");

            registry.gauge("es.query_cache.hit_ratio", Tags.of("node", node),
                    qc.path("hit_count").asLong() + qc.path("miss_count").asLong() == 0 ? 0
                            : (double) qc.path("hit_count").asLong()
                              / (qc.path("hit_count").asLong() + qc.path("miss_count").asLong()));
            registry.counter("es.query_cache.evictions", Tags.of("node", node))
                    .increment(qc.path("evictions").asLong());
            registry.counter("es.request_cache.miss", Tags.of("node", node))
                    .increment(rc.path("miss_count").asLong() - lastRequestMiss.getOrDefault(node, 0L));
            lastRequestMiss.put(node, rc.path("miss_count").asLong());
        });
    }

    private final Map<String, Long> lastRequestMiss = new ConcurrentHashMap<>();
}
```

两个判读经验：

- `query_cache.evictions` 持续增长而 `hit_count` 不涨 → 缓存太小或段太多，先治段。
- `request_cache.miss` 恒定且等于 QPS → 请求里有 `now()` 或 `size > 0`，回去改查询。

---

## 六、六个"缓存不生效"的真实原因

| 现象 | 根因 | 修复 |
|---|---|---|
| 小索引 filter 永不命中 | 段 < 10000 文档被跳过 | `indices.queries.cache.all_segments: true` |
| 聚合每次都很慢 | 用了 `now-7d` | 应用层传绝对时间 |
| 昨天很快今天很慢 | 夜间批量写入触发 merge | 调整 refresh / 用只读别名 |
| 加了 filter 反而更慢 | 过滤条件命中率 > 50% | 改用 `must` 打分或去掉该 filter |
| 第二次查询没变快 | 只是 page cache 生效 | 检查 query cache 指标而非响应时间 |
| text 字段聚合把堆打满 | fielddata 加载 | 用 `keyword` 子字段或 `doc_values` |

---

## 七、分片设计：缓存友好度的隐藏变量

同样的数据量，分片数不同，缓存效率可能差 3 倍。原因还是"段"：

| 分片数 | 单分片文档数 | 单分片段数 | query cache 条目数 | 命中率 |
|---|---|---|---|---|
| 5 | 2000 万 | 40 | 5 × 40 = 200 | 高 |
| 20 | 500 万 | 40 | 20 × 40 = 800 | 中 |
| 60 | 170 万 | 40 | 60 × 40 = 2400 | 低（且大量段 < 1 万文档被跳过） |

三条经验：

1. **单分片 2000 万~5000 万文档**是缓存效率的甜点区，别为了"并行度"把分片切碎。
2. **段数与分片数相乘才是缓存条目总数**，缓存是按条目 LRU 淘汰的，条目多 = 单条命中概率低。
3. **只读索引可以 forceMerge 到 1 段**，此时 query cache 的条目数直接降到"分片数"，命中率能到 90% 以上（副作用是 merge 期间 IO 打满，务必在低峰做）。

还有一个容易忽略的点：带 `preference` 的请求（比如 `preference=_local` 或自定义字符串）会改变分片路由，但**不会**改变 query cache 的 key（key 是 segment + query），所以它影响的是 page cache 的局部性，而不是 query cache。真正影响缓存 key 的是查询 DSL 本身——`boost` 值、字段顺序、`minimum_should_match` 的细微差异都会生成不同的 key。这也是为什么"同一个业务查询拼出来的 DSL 必须逐字节稳定"，动态拼接参数（尤其是把 `now` 或随机 seed 拼进去）等于自废缓存。

## 八、面试追问

**Q1：query cache 和 request cache 的区别？**
query cache 缓存的是"某个 segment 上某个 filter 命中的文档位图"，粒度是 filter 条件，所有查询共享；request cache 缓存的是"整个分片请求的响应"，粒度是完整请求（含聚合），只有 `size: 0` 才生效。前者省的是"算 bitset"的时间，后者省的是"算聚合"的时间。

**Q2：为什么 filter 查询比 must 查询快？**
filter context 不算分（跳过 `_score` 计算与 `collector` 的打分路径），且结果可以 bitset 化并被 query cache 复用；must 需要 BM25 打分，不能走 bitset 缓存。

**Q3：段合并对性能的影响？**
合并期间磁盘 IO 与 CPU 升高，合并后旧段的 query cache / request cache 全部失效，同时 filesystem cache 需要重新预热。所以大索引要避免"白天持续小批量写入"，尽量批量导入 + 强制 merge。

---

## 九、总结

- ES 的缓存是**四层串联**：page cache → query cache（filter bitset）→ request cache（size:0 聚合）→ fielddata（应尽量避免）。
- 两条硬规则：**filter 才能进 query cache**，**`size: 0` 才能进 request cache**。
- 段是缓存的基本单位，**merge 是缓存的天敌**；治缓存之前先治段。
- 时间条件一律用绝对时间，别让 `now()` 把缓存 key 打得粉碎。

最后提醒一句：真正决定缓存能不能稳住的，是**索引写入链路**（refresh 频率、translog 与段合并）——缓存调优的上游永远是"少产生段"。
