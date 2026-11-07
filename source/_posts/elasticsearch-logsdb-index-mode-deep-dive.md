---
title: 【ES 实战】logsdb 索引模式深度解析：合成 _source、索引排序与日志存储成本腰斩
date: 2026-11-07 08:00:00
tags:
  - Elasticsearch
  - 日志
  - 存储优化
  - 索引设计
  - Java
categories:
  - 中间件
author: 东哥
---

# 【ES 实战】logsdb 索引模式深度解析：合成 _source、索引排序与日志存储成本腰斩

## 前言：日志集群的钱，一半花在 _source 上

先说一个真实账单。我们一套 ELK 集群，日增日志 1.2TB（原始文本 300GB，其余都是索引开销），三副本热节点 12 台 8C32G + 4TB NVMe，一个月云成本接近六位数。做了一轮分析后发现：

- 倒排索引（terms/postings）：约占 22%
- **`_source` 原始 JSON：约占 38%**
- doc_values（数值、keyword、date）：约占 20%
- 其他（stored fields、norms、BKD points、段元数据）：约 20%

也就是说，**接近四成的磁盘是在重复存同一份日志原文**。而日志这种数据有个特点：字段结构固定、几乎不更新、查询以聚合和过滤为主，很少需要拿回完整原文。

Elastic 从 8.17 开始提供 `index.mode: logsdb`（9.0 起 GA），干的就是这件事：**把 `_source` 干掉（合成），按 `host.name` + `@timestamp` 排序，让相同来源的相似日志在物理上连续存放，从而把压缩率拉到极致**。我们在一个 90 天的索引上实测，主分片从 4.1TB 降到 2.3TB，**降幅 44%**，查询 P95 反而略有改善。

这篇就把 logsdb 的机制、限制、迁移路径和踩坑讲清楚。

## 一、logsdb 到底改了什么

### 1.1 合成 `_source`（synthetic `_source`）

普通索引里，`_source` 是写入时原文存一份，取回时直接返回。合成 `_source` 则相反：**不存原文**，取回时从 doc_values 和 stored fields **反向重建** JSON。

```json
PUT logs-app-2026.11.07
{
  "settings": {
    "index.mode": "logsdb",
    "number_of_shards": 3,
    "number_of_replicas": 1
  },
  "mappings": {
    "properties": {
      "@timestamp": { "type": "date" },
      "host.name":  { "type": "keyword" },
      "log.level":  { "type": "keyword" },
      "message":    { "type": "text" },
      "service.name": { "type": "keyword" },
      "http.status_code": { "type": "integer" }
    }
  }
}
```

设置 `index.mode: logsdb` 后，ES 会自动：

- 打开 `index.mapping.synthetic_source: true`
- 设置 `index.sort.field: [host.name, @timestamp]`、`index.sort.order: [asc, desc]`
- 使用压缩友好的编码参数

反序列化时，`_source` 是从各字段的列式存储拼出来的。**数组顺序会丢失**（变成按 doc_values 的顺序），`copy_to`、`runtime` 字段不出现在 `_source` 里，字段名的大小写与点号结构按 mapping 还原。这些限制必须在接入前确认，否则上游解析脚本会莫名其妙拿不到字段。

### 1.2 索引排序（index sorting）

这是 logsdb 压缩率的关键。默认按 `host.name` 升序、`@timestamp` 降序排列文档。物理效果是：

```
host=a, 10:00:05  ┐
host=a, 10:00:04  ├─ 同一个 host 的时间序列连续存放
host=a, 10:00:03  ┘
host=b, 10:00:05  ┐
host=b, 10:00:04  ┘
```

日志的字段值高度重复（同一个 host、同一个 service、同一个 level），连续存放后：

- doc_values 的差值编码（delta）几乎全是 1 或 0，压缩率极高；
- 文本块内相同前缀多，DEFLATE 压缩率提升明显；
- 查询 `host.name = "a"` 时只需扫连续的一段，跳读成本低。

代价是**写入变慢**：文档必须先在内存里按 sort key 排好再 flush。对日志这种"按时间顺序写、乱序度有限"的场景，影响很小；如果你的写入是完全乱序的（比如回灌历史数据），merge 阶段会反复重排，CPU 会明显上升。

### 1.3 更激进的编码

logsdb 会对字段类型做"日志特化"：

- `keyword` 字段默认不建 norms（日志不需要算分）；
- `text` 字段如果没显式指定，倾向于用 `match_only_text` 语义（不做 norms、不存 positions，只存 docs），省掉大量 postings；
- 数值字段优先用 `doc_values` + 位宽压缩（`index.mapping.number` 相关设置）。

这几项加在一起，才是我看到的 40%+ 降幅来源——**光去掉 `_source` 大概只有 30%，排序 + 编码再贡献 10~15%**。

## 二、代价：哪些查询会变慢

天下没有白拿的压缩。logsdb 的代价集中在三类查询上：

| 查询类型 | 影响 | 原因 |
|---|---|---|
| `_id` 直接 get | 变慢 | 没有独立的 `_id` 索引，需要扫 |
| 全文检索（match 短语） | 变慢 | `match_only_text` 没有 positions，短语查询退化为 term 匹配 |
| `_source` 全量取回 | 变慢 | 需要从列存重建，字段多时开销明显 |
| 聚合（terms/date_histogram） | 变快 | 列存 + 排序，缓存局部性好 |
| 范围过滤（时间/主机） | 变快 | 排序后连续段跳读 |

我们线上最明显的体感：**Kibana Discover 打开 500 条日志的耗时从 380ms 涨到 520ms**（重建 `_source` 的代价），但**聚合面板整体快了 15%**。这个交换对日志场景是划算的。

## 三、Java 客户端落地

用 `elasticsearch-java` 8.x/9.x 创建 logsdb 索引：

```java
ElasticsearchClient client = new ElasticsearchClient(transport);

Map<String, Object> props = Map.of(
    "@timestamp", Map.of("type", "date"),
    "host.name", Map.of("type", "keyword"),
    "message", Map.of("type", "match_only_text"),
    "http.status_code", Map.of("type", "integer"),
    "service.name", Map.of("type", "keyword")
);

client.indices().create(c -> c
    .index("logs-app-2026.11.07")
    .settings(s -> s
        .mode("logsdb")                 // 关键开关
        .numberOfShards(3)
        .numberOfReplicas(1)
        .refreshInterval(t -> t.time("10s")))
    .mappings(m -> m.properties(props))
);
```

写入侧和普通索引完全一致，`IndexRequest` 不需要任何改动。**但要注意：日志最好带 `data_stream` 语义**，用 `<type>-<dataset>-<namespace>` 命名，配合 ILM 做滚动，否则单索引会无限长大。

按天滚动的索引模板：

```json
PUT _index_template/logs-app-template
{
  "index_patterns": ["logs-app-*"],
  "data_stream": {},
  "template": {
    "settings": {
      "index.mode": "logsdb",
      "number_of_shards": 3,
      "number_of_replicas": 1
    }
  },
  "priority": 200
}
```

## 四、迁移路径：不能原地改

**`index.mode` 只能在创建索引时指定，不能对已有索引修改。** 所以迁移只有一条路：新建索引 → 双写/回灌 → 切读 → 删旧。

### 4.1 评估

先跑一个 dry run，确认所有字段都能合成：

```json
GET logs-app-2026.11.06/_mapping
```

重点检查：

1. 有没有 `copy_to`（不支持）；
2. 有没有 `text` 字段依赖短语查询（`match_phrase`）；
3. 有没有字段需要 `store: true` 但类型不支持；
4. 有没有依赖 `_source` 顺序的解析逻辑。

### 4.2 reindex

```json
POST _reindex?wait_for_completion=false&slices=auto
{
  "source": { "index": "logs-app-2026.11.06" },
  "dest":   { "index": "logs-app-2026.11.06-logsdb" },
  "script": {
    "source": "ctx._source.remove('unused_field')"
  }
}
```

`reindex` 会按目标索引的 sort 重新排列，所以耗时比普通 reindex 长 20~40%。建议在低峰期做，且 `slices` 不要太大（排序本身吃 CPU，和切片抢资源）。

### 4.3 切流

用别名原子切换：

```json
POST _aliases
{
  "actions": [
    { "add":    { "index": "logs-app-2026.11.06-logsdb", "alias": "logs-app-read" } },
    { "remove": { "index": "logs-app-2026.11.06",        "alias": "logs-app-read" } }
  ]
}
```

观察 24 小时，确认没有解析报错和查询超时，再删旧索引。

## 五、踩坑清单

**坑 1：数组顺序丢失导致解析错乱。** 我们有个 `tags` 字段，上游按"第一个 tag 是主标签"的约定解析，切到 logsdb 后顺序变成字典序，业务逻辑全错。**凡是依赖数组顺序的地方都要改成显式字段。**

**坑 2：`match_phrase` 静默降级。** `match_only_text` 没有 positions，短语查询会变成"所有词都出现即可"，召回变宽但精确度下降。日志里如果有关键词精确匹配需求，把字段显式映射成 `text` 并设 `index_options: positions`。

**坑 3：排序字段基数太高。** 如果 `host.name` 有几百万个不同值，排序几乎不起作用，反而增加写入开销。这种情况建议换成低基数的 `service.name` 或 `k8s.namespace` 做第一排序键。

**坑 4：`_source` 取回成本被低估。** 有些团队在应用侧把整条日志 `_source` 拉回来做二次解析，切 logsdb 后 QPS 掉了一半。要么只取需要的字段（`_source_includes`），要么把解析逻辑前移到采集端。

**坑 5：副本数与压缩率。** logsdb 压缩率高，但副本仍然全量复制。如果成本压力大，冷层可以用 `number_of_replicas: 0` + 快照兜底，比继续堆压缩参数有效得多。

## 六、收益测算表

以我们一个 90 天、日增 300GB 原文的索引为例：

| 项目 | 普通索引 | logsdb | 变化 |
|---|---|---|---|
| 主分片大小 | 4.1 TB | 2.3 TB | -44% |
| 分片数（含副本） | 24 | 24 | — |
| 写入吞吐 | 42k docs/s | 35k docs/s | -17% |
| 聚合查询 P95 | 820 ms | 690 ms | -16% |
| Discover 取 500 条 | 380 ms | 520 ms | +37% |
| 月存储成本 | 100% | 56% | -44% |

结论很清楚：**如果你的日志以聚合/过滤为主、很少取原文，logsdb 基本是稳赚**；如果业务严重依赖原文取回和短语检索，先做小范围灰度再决定。

## 七、分片与生命周期：logsdb 该怎么配

logsdb 压缩率高了，很容易让人误以为"一个索引可以吃得更大"。恰恰相反，**排序字段决定了一次查询要扫哪一段连续数据，分片太大反而会放大单分片的排序开销**。

我的经验配置：

| 日均原文量 | 主分片数 | 单分片目标大小 | 滚动周期 |
|---|---|---|---|
| < 50 GB | 1 | 30~50 GB | 7 天 |
| 50~200 GB | 2~3 | 30~50 GB | 7 天 |
| 200~500 GB | 4~6 | 40~60 GB | 1 天 |
| > 500 GB | 6~12 | 50 GB | 1 天（按 dataset 再拆） |

配合 ILM：热层保留 7 天（副本 1），温层 30 天（副本 1，forcemerge 到 1 段），冷层 90 天（副本 0，可搜索快照）。**冷层用可搜索快照比继续压副本划算得多**——对象存储的成本大约是本地 SSD 的 1/10。

还有一个容易忽略的点：logsdb 的排序让 `forcemerge` 的收益变大了。因为文档已经按 `host.name` 聚集，forcemerge 后同 host 的数据落在连续的 segment 里，查询时的跳读次数显著减少。我们在温层做 `forcemerge?max_num_segments=1` 后，聚合 P95 又降了 12%。

## 八、面试追问

**Q：合成 `_source` 是怎么实现的？**
A：写入时不存原文，只存列式数据（doc_values / stored fields）。取回时遍历 mapping，按字段类型从列存反序列化并拼成 JSON。所以要求字段都能从列存还原，`copy_to` 和 runtime 字段天然不满足。

**Q：为什么索引排序能提升压缩率？**
A：排序让相同值在物理上连续，doc_values 的 delta 编码和块压缩的字典命中率都大幅提升；倒排的 docID 也变得连续，postings 压缩更高效。

**Q：logsdb 适合业务数据吗？**
A：不适合。它假设数据是"只追加、不更新、按来源和时间聚集"的日志。业务数据基数高、更新频繁、需要精确取回原文，用 logsdb 会同时损失写入性能和查询灵活性。

**Q：如果我要保留原文怎么办？**
A：把需要原文的字段显式 `store: true`（会占空间），或者把原文丢到对象存储（S3/OSS），ES 里只留索引和指针。后者是更彻底的冷热分离方案。

## 九、结语

logsdb 不是一个"打开就变快"的开关，而是一整套针对日志场景的存储取舍：用 `_source` 的可读性、短语检索的精度、写入的吞吐，换 40% 的磁盘。理解了这三笔交易，你才知道该不该按下去。
