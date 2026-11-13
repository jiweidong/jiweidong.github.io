---
title: 【ES 底层】translog、refresh 与 flush 深度解析：写入可见性、持久性与数据丢失窗口
date: 2026-11-13 08:20:00
tags:
  - Elasticsearch
  - Lucene
  - 持久化
  - 中间件
  - 数据可靠性
categories:
  - Elasticsearch
author: 东哥
---

# 【ES 底层】translog、refresh 与 flush 深度解析：写入可见性、持久性与数据丢失窗口

## 前言

「文档写进 ES 了，为什么搜不到？」「明明返回 200 了，机器掉电后数据怎么丢了？」「集群重启要 40 分钟，卡在 translog recovery 上。」

这三个问题指向同一个子系统：**Lucene 的不可变段模型 + Elasticsearch 的三层持久化机制**。很多人能背出「refresh 是 1 秒、flush 是刷盘」，但说不清三件事的边界：

1. **可见性**（能搜到）和**持久性**（掉电不丢）是两件完全不同的事；
2. `refresh` 只解决前者，`translog` 才解决后者；
3. `durability=request` 保证的是「fsync 完成后才 ack」，代价是每请求一次 fsync。

这篇文章从 Lucene 的写入模型讲起，把 translog 文件结构、generation 递增、commit point、崩溃恢复、`flush_threshold_size` 与恢复时间的关系全部拆开，最后给出 Java 客户端侧的批量写入模板和一份面试追问清单。

## 一、先理解 Lucene 为什么「写入不能立刻搜」

Lucene 的索引是**不可变段（immutable segment）**的集合。这个设计带来极高的查询性能（无锁、可缓存、可并发），代价是**写入路径被拉长**：

```
文档写入
  │
  ├─ 1. 写 translog（append，durability=request 时 fsync）
  │
  ├─ 2. 写入内存 buffer（IndexWriter 的 RAM buffer，默认 10% 堆 / 或 index_buffer_size）
  │
  ├─ 3. refresh：buffer → 新段（segment）→ 打开 reader → 可被搜索
  │        新段先写到文件系统缓存，不一定 fsync
  │
  ├─ 4. flush：Lucene commit（fsync 段文件 + 写 segments_N）→ translog 截断
  │
  └─ 5. merge：多个小段合并成大段（后台，产生写放大）
```

三个动作的职责必须分清：

| 动作 | 解决什么 | 是否 fsync | 默认触发 |
|---|---|---|---|
| `refresh` | **可见性**：让新写入能被搜索到 | 否（只到 page cache） | 每 1s（`refresh_interval`） |
| `flush` | **可恢复性**：生成新的 commit point，清空 translog | 是 | translog 达 `flush_threshold_size`（512MB）或显式调用 |
| translog fsync | **持久性**：保证已 ack 的写不丢 | 是 | `durability=request` 每请求 |

一句话总结：**refresh 让你看得见，translog 让你不丢，flush 让你重启快。**

## 二、translog 到底存了什么

每个分片一个 translog 目录：

```
$ tree data/nodes/0/indices/<indexUUID>/0/translog/
translog/
├── translog-3.tlog
├── translog-4.tlog
└── translog.ckp        # checkpoint：记录已 fsync 的偏移
```

文件内容是一条条的 operation：

```
[header]  version, uuid, primaryTerm
[op]      Index / Delete / NoOp
          _id, routing, source(可选), version, seqNo, primaryTerm
[footer]  CRC32 校验
```

关键设计：

- **`seqNo` + `primaryTerm`** 是复制的基石。副本按 `seqNo` 请求补齐，主分片按 `seqNo` 判断「这条操作我处理过没有」（幂等）。
- **`translog.ckp`** 记录「已 fsync 到哪里」。崩溃恢复时从 checkpoint 之后开始重放，前面的跳过。
- **translog 里存不存 `_source`** 取决于操作类型：`index` 操作带 source（用于重放），`delete` 不带。
- **generation 递增**：每次 flush 后新的 translog 文件 generation +1，旧的在所有分片确认后删除。

`generation` 与 `commit point` 的关系是恢复逻辑的核心：

```
segments_5 (commit point) 声明：段 A, B, C 有效，translog generation = 4
translog-4.tlog            该 commit 之后的所有操作
```

崩溃后恢复流程：

1. 读最新的 `segments_N`，加载声明的段。
2. 找到对应的 translog generation（N-1 及更早的可以忽略）。
3. 从 `translog.ckp` 记录的偏移开始重放，重建内存 buffer。
4. 重放完成后再 refresh，然后 flush 出新的 commit point。

所以：**translog 越大，恢复越慢**。一个 20GB translog 的索引，重启时单分片重放可能要几分钟。

## 三、durability：request 与 async 的真实代价

```json
PUT /orders/_settings
{
  "index.translog.durability": "request",
  "index.translog.sync_interval": "5s",
  "index.translog.flush_threshold_size": "512mb",
  "index.translog.retention.size": "1gb",
  "index.translog.retention.age": "12h"
}
```

### 3.1 `request`（默认）

每个 index/bulk/delete 请求，**在主分片完成 translog fsync 后才返回 200**。

代价量化（这是很多人没算过的账）：

- 一块普通云盘 SSD 的 fsync 延迟约 0.5~2ms（有电池保护的 RAID 卡更快）。
- 单分片串行 fsync → 单分片写入上限约 **500~2000 次/秒**。
- 一个 bulk 请求包含 5000 条文档，只 fsync 一次 → 摊薄后成本可忽略。
- 一个 bulk 请求只包含 1 条文档 → 每条一次 fsync，吞吐直接掉到几百 TPS。

**结论：`durability=request` 的性能完全取决于「单次请求装了多少条文档」。** 这解释了为什么「小批量高频写」的 ES 集群 CPU 不高但写入上不去——瓶颈在 fsync 的 IOPS 和延迟上。

### 3.2 `async`

每 `sync_interval`（默认 5s）fsync 一次，请求立即返回。

| 模式 | 数据丢失窗口 | 适用场景 |
|---|---|---|
| `request` | 0（已 ack 的不丢） | 订单、支付、账务 |
| `async` + 5s | 最多 5s | 日志、指标、可重放数据 |

注意一个常见误解：**`async` 不等于「不持久」**。操作系统崩溃（进程被杀、JVM OOM）不会丢——page cache 还在；只有**机器掉电/内核 panic**才会丢。所以 `async` 的风险等级是「宿主机级故障」，不是「进程级故障」。

### 3.3 副本能不能兜底？

不能这么算。写请求的 ack 条件是「主分片成功 + 活跃副本数达到 `wait_for_active_shards`」，但**副本的 translog 落盘时机与主分片不保证同步**。把可靠性寄托在「副本总有一个活着」上，在整机架掉电、存储网络抖动时会被打脸。

正确做法：**按数据价值选 durability，而不是按「反正有副本」选**。

## 四、refresh：可见性的代价被严重低估

`refresh_interval=1s` 意味着每秒为每个分片生成一个新段。一个 30 分片、日增 100GB 的索引，一天产生：

```
30 分片 × 86400 秒 = 259 万个段（理论值）
```

实际上 Lucene 的 `IndexWriter` 有 `RAM buffer` 与 merge 策略兜底，不会真的产生 259 万个段，但**短时间内的段数量爆炸**是真实存在的，后果是：

1. 每次搜索要遍历所有段 → 查询变慢。
2. 段越多，merge 越频繁 → 写放大 8~10 倍。
3. 文件句柄与内存（每个段有独立的 terms dict、doc values）暴涨。

三个必须知道的配置：

```json
// 批量导入：关掉自动刷新，导入后手动 refresh
PUT /orders/_settings { "index.refresh_interval": "-1" }
POST /orders/_refresh
PUT /orders/_settings { "index.refresh_interval": "1s" }

// bulk 请求里不要带 refresh=true（每条都刷，等于灾难）
POST /_bulk?refresh=false

// 写入后需要立刻可见：一次 refresh 覆盖整批
POST /_bulk
{"index":{"_index":"orders","_id":"1"}}
{...}
POST /orders/_refresh
```

`refresh=true` 与 `refresh=wait_for` 的区别：

| 参数 | 语义 | 延迟 |
|---|---|---|
| `refresh=true` | 立即强制刷新所有相关分片 | 高（可能几百 ms） |
| `refresh=wait_for` | 等下一次自然刷新完成再返回 | 最多 1 个 refresh_interval |

`wait_for` 是「读己之写」场景的正确选择，它把刷新成本摊到自然周期上。

## 五、flush 触发条件与「重启为什么慢」

flush 由四个条件触发：

1. translog 大小超过 `index.translog.flush_threshold_size`（默认 512MB）。
2. 显式 `POST /<index>/_flush`。
3. 分片迁走前（recovery 需要干净的 commit point）。
4. 定期（`index.translog.flush_threshold_period`，默认 30min，防止小索引永远不 flush）。

flush 做了什么：

```
1. refresh（把 buffer 落成段）
2. fsync 所有段文件
3. 写新的 segments_N（commit point）并 fsync 目录
4. 新建 generation+1 的 translog
5. 删除旧 generation 的 translog（等所有相关分片确认）
```

所以**恢复时间 ≈ 最后一个 commit point 之后累积的 translog 大小 / 重放速度**。控制手段：

```json
{
  "index.translog.flush_threshold_size": "256mb",   // 调小 → 恢复快，但 flush 更频繁
  "index.translog.retention.size": "512mb",          // 保留上限，超出强制 flush
  "index.translog.retention.age": "12h"
}
```

生产经验值：

| 数据量级 | flush_threshold_size | 恢复时间量级 |
|---|---|---|
| < 10GB/分片 | 512mb（默认） | 秒级~1 分钟 |
| 10~50GB/分片 | 256mb | 1~3 分钟 |
| > 50GB/分片 | 128~256mb + 控制分片大小 ≤ 50GB | 3~10 分钟 |

**分片大小比 flush 参数更重要**。一个 200GB 的分片，恢复时要重放巨量 translog、重建巨量段元数据，怎么调都慢。

## 六、Java 客户端：一份能打的批量写入模板

```java
@Configuration
public class EsBulkConfig {

    @Bean(destroyMethod = "close")
    public RestClient restClient() {
        return RestClient.builder(HttpHost.create("http://es-node:9200"))
                .setRequestConfigCallback(c -> c
                        .setConnectTimeout(2_000)
                        .setSocketTimeout(30_000)
                        .setConnectionRequestTimeout(1_000))
                .setHttpClientConfigCallback(c -> c
                        .setMaxConnTotal(100)
                        .setMaxConnPerRoute(50)
                        .setKeepAliveStrategy((resp, ctx) -> 30_000))
                .build();
    }
}

@Service
public class OrderIndexWriter {

    private final RestClient client;
    private final ObjectMapper mapper = new ObjectMapper();

    /** 按 5MB / 2000 条双阈值切批：单请求 fsync 摊薄，又不至于请求体过大 */
    public void bulkIndex(List<OrderDoc> docs) {
        int batchSize = 2000;
        for (int i = 0; i < docs.size(); i += batchSize) {
            List<OrderDoc> batch = docs.subList(i, Math.min(i + batchSize, docs.size()));
            String body = buildNdjson(batch);
            client.performRequest(new Request("POST", "/orders/_bulk?refresh=false",
                    Map.of("Content-Type", "application/x-ndjson"),
                    new StringEntity(body, ContentType.APPLICATION_NDJSON)));
        }
    }

    private String buildNdjson(List<OrderDoc> batch) {
        StringBuilder sb = new StringBuilder(batch.size() * 256);
        for (OrderDoc d : batch) {
            sb.append("{\"index\":{\"_id\":\"").append(d.id()).append("\"}}\n");
            try {
                sb.append(mapper.writeValueAsString(d)).append('\n');
            } catch (JsonProcessingException e) {
                throw new IllegalArgumentException("serialize failed: " + d.id(), e);
            }
        }
        return sb.toString();
    }
}
```

### 6.1 必须处理 `items[].error`

`_bulk` 的整体 HTTP 状态码经常是 200，但**单条可能失败**（mapping 冲突、`version_conflict`、`rejected`）。不检查 `items` 等于埋雷：

```java
JsonNode resp = mapper.readTree(entity.getContent());
boolean hasFailure = false;
for (JsonNode item : resp.path("items")) {
    JsonNode result = item.elements().next();
    if (result.has("error")) {
        hasFailure = true;
        String id = result.path("_id").asText();
        String type = result.path("error").path("type").asText();
        // 只重试可恢复的：es_rejected_execution_exception / 429 / 503
        if (type.contains("rejected") || type.contains("unavailable")) {
            retryQueue.add(id);
        } else {
            deadLetter.add(id);   // mapping 冲突等不可恢复错误
        }
    }
}
```

### 6.2 背压与重试

- **`es_rejected_execution_exception`** 是写队列满，必须退避（指数 + 抖动），不能立刻重试。
- **`version_conflict_engine_exception`** 是并发写同一条，业务侧要么重读改，要么用 `_update` 脚本。
- **超时重试必须幂等**：用业务主键做 `_id`，重试就是覆盖，天然幂等；用 ES 自动生成 `_id` 会写重。

## 七、观测：四个必须看的指标

```bash
# 1. translog 大小与操作数（判断 flush 是否及时）
GET /orders/_stats/translog?human
#   translog.size_in_bytes / operations / uncommitted_operations

# 2. refresh 开销
GET /orders/_stats/refresh?human
#   total_time_in_millis 持续上涨 → 段爆炸

# 3. flush 次数与耗时
GET /orders/_stats/flush

# 4. 段数量（核心健康指标）
GET /orders/_stats/segments
#   count 长期 > 100/分片 → 需要 force merge 或调 refresh_interval
```

线上阈值参考：

| 指标 | 健康 | 告警 |
|---|---|---|
| `segments.count / 分片` | < 50 | > 150 |
| `translog.size_in_bytes` | < 512MB | > 2GB（恢复会很慢） |
| `refresh.total_time / 分钟` | 稳定 | 持续上升 |
| `flush.periodic` | 正常触发 | 从不触发（说明 translog 一直没清） |

## 八、五个真实踩坑

**坑 1：`refresh_interval=-1` 之后忘了改回来。** 批量导入脚本异常退出，索引永久不可搜，第二天业务方来问「数据怎么没了」。

**坑 2：bulk 里每条都带 `refresh=true`。** 每秒几千个小段，merge 打满磁盘，整集群写入雪崩。

**坑 3：把 `durability=async` 当成「性能优化」全局打开。** 订单数据在机房掉电时丢了 5 秒，对账时才发现。

**坑 4：分片设计成 200GB。** 重启恢复 40 分钟，主从切换期间整个索引不可用。

**坑 5：以为返回 200 就是落盘了。** `durability=async` 下 200 只代表「写进 translog 的 page cache」，掉电就丢。

## 九、面试常见追问

**Q1：refresh 和 flush 的区别？**

refresh 把内存 buffer 变成可搜索的新段（不保证落盘），解决「可见性」；flush 触发 Lucene commit（fsync 段 + 写 segments_N）并清空 translog，解决「可恢复性」。flush 内部会先做一次 refresh。

**Q2：为什么 ES 是「近实时」而不是实时？**

因为写入先落在 buffer 和 translog，需要 refresh 才能被搜索，默认 1 秒一次。这是为了批量攒段、避免小段爆炸而做的吞吐权衡。

**Q3：`durability=request` 就绝对不会丢数据吗？**

在「已返回 200」的前提下，主分片 translog 已 fsync，单机掉电不丢。但如果整个机房掉电且副本也没落盘，仍可能丢。另外 `wait_for_active_shards=1` 时副本没写成功也返回 200，此时副本落后。

**Q4：translog 会不会无限增长？**

不会。三个闸门：`flush_threshold_size`（默认 512MB 触发 flush）、`retention.size`、`retention.age`。但 `refresh_interval=-1` + 低写入量时，可能长时间不触发 flush，靠 `flush_threshold_period`（30min）兜底。

**Q5：集群重启慢，怎么优化？**

① 控制分片大小 ≤ 50GB；② 调小 `flush_threshold_size` 减少单次重放量；③ 避免大量小分片（每个分片恢复都有固定开销）；④ 用 `index.recovery.type` 与 `cluster.routing.allocation.node_concurrent_recoveries` 控制并发恢复的带宽，避免恢复把集群打挂；⑤ 冷数据用可搜索快照而不是常驻分片。

## 十、总结

- ES 写入是「translog（持久）+ buffer（内存）+ 段（可搜）」三件套，**可见性靠 refresh，持久性靠 translog fsync，恢复速度靠 flush**。
- `durability=request` 的性能取决于「单请求多少条文档」，小批量高频写会被 fsync 卡死。
- `durability=async` 的丢失窗口是 `sync_interval`，只适合可重放数据。
- 段数量是核心健康指标，`refresh_interval` 与 bulk 的 `refresh` 参数是最常见的两个误用点。
- 重启慢的根因通常不是 translog 参数，而是**分片太大 + 小分片太多**。

把这套机制搞清楚，你就能在「写入 200 但搜不到」「掉电丢数据」「重启一小时」这三类问题上，第一句话就说中根因。
