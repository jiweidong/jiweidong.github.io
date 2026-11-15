---
title: 【Java AI】向量库批量写入与索引构建调优深度实战：ES bulk、Qdrant、Milvus 与 pgvector 的 Java 落地
date: 2026-11-15 08:40:00
tags:
  - Java
  - AI
  - RAG
  - 向量数据库
  - Elasticsearch
  - 性能调优
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】向量库批量写入与索引构建调优深度实战

## 前言

RAG 项目上线第一个月都很顺：几万条文档，`VectorStore.add()` 几秒钟跑完，检索效果也不错。

第二年开始出事。文档涨到 2000 万 chunk，某次要换 Embedding 模型（维度从 768 变 1024），重灌数据的结果是：

- 写了 14 个小时才灌完；
- 灌完之后检索延迟从 40ms 涨到 300ms；
- 召回率比原来低了 6 个百分点（同一批黄金问题）；
- ES 集群 heap 打到 92%，触发了 circuit breaker，写入被拒。

这四个症状，分别对应四个不同的机制：**写入路径的段合并、索引构建的时机、HNSW 增量插入的图质量、以及内存/背压控制**。

大部分 RAG 文章讲「怎么调 API」，这篇讲「**写入侧工程**」——这是 RAG 系统最不被重视、但最容易翻车的一半。因为检索质量的上限由数据决定，而数据是通过写入路径进去的。

## 一、四种向量库的写入路径差异（决定了一切）

| 维度 | Elasticsearch | Qdrant | Milvus | pgvector |
|---|---|---|---|---|
| 存储单元 | segment（不可变） | segment（不可变，可优化合并） | growing + sealed segment | heap 表 + 索引 |
| 可见性 | `refresh`（默认 1s） | 写入即可见 | 写入即可见（growing） | 事务提交即可见 |
| 持久性 | translog（可配 durability） | WAL | WAL（Pulsar/Woodpecker） | PostgreSQL WAL |
| 向量索引 | HNSW（segment 内独立图） | HNSW（segment 内） | HNSW/IVF（segment 内） | HNSW（全局一个大图） |
| 删除语义 | 标记删除 + merge 时真正移除 | 标记删除 + optimizer 重建 | 标记删除 + compaction | **真删除**（vacuum 回收） |
| 大批量灌数最优解 | 关 refresh、加大 bulk、灌完 forceMerge | 关 indexing、灌完重建 | 关闭 growing 检索、用 bulkInsert | **先灌数据，后建索引** |

最关键的差异在这一行：**ES / Qdrant / Milvus 的 HNSW 是「每个 segment 一张图」，pgvector 是「整表一张图」**。这个差异决定了两种完全不同的灌数策略。

- Segment 型：图小、增量插入便宜，但**查询要扫所有 segment 的图再合并结果**（segment 越多越慢）。
- 全局图型：查询快（一张图），但**每插入一行都要更新全局图**，写入极慢，而且内存要装下整个索引。

## 二、Elasticsearch：bulk 的三个反直觉点

### 2.1 `refresh_interval = -1` 是灌数第一步

```java
// 灌数前：关闭 refresh + 副本置 0
PUT /rag_chunks/_settings
{
  "index": {
    "refresh_interval": "-1",
    "number_of_replicas": 0
  }
}
```

原因：每次 refresh 都会把内存 buffer 刷成一个**新的 segment**，而每个 segment 都要建一张 HNSW 图。2000 万 chunk 如果按 1 秒 refresh，会产出几百个小 segment，每个图的构建开销固定，总开销爆炸。

灌完再改回来：

```java
PUT /rag_chunks/_settings
{ "index": { "refresh_interval": "1s", "number_of_replicas": 1 } }
POST /rag_chunks/_forcemerge?max_num_segments=1
```

注意 `forceMerge` 到 1 个 segment 在 2000 万文档上是**小时级**操作，而且会产生巨大的 IO 峰值。实践建议：`max_num_segments` 取 2~5，或者干脆不 forceMerge，靠 ILM 的 rollover + 定期重建索引。

### 2.2 `translog.durability` 的取舍

```json
{ "index": { "translog": { "durability": "async", "sync_interval": "5s" } } }
```

默认 `request`（每次 bulk 都 fsync translog）。灌 2000 万条数据时，这个 fsync 会成为主要瓶颈（参考上一篇：单次 fsync 在云盘上是 1~5ms）。

改成 `async` 后，**最多丢 5 秒数据**。灌数场景可以接受（灌完会校验数量），但**线上增量写入不能改**——那 5 秒可能是用户刚上传的合同。

### 2.3 bulk 大小不是越大越好

| bulk 条数 | 单条 1024 维 float | 请求体大小 | 问题 |
|---|---|---|---|
| 100 | 4KB | 400KB | 请求数太多，协调节点成瓶颈 |
| 500 | 4KB | 2MB | 较均衡 |
| 1000 | 4KB | 4MB | 推荐上限 |
| 5000 | 4KB | 20MB | 单个 bulk 处理时间长，容易超时；内存峰值高 |

**判断标准不是条数，是字节数**：单次 bulk 控制在 **5~15MB**，且单次处理时间 < `bulk` 请求超时（默认 60s）。

更重要的参数是 **`indexing_pressure`**（ES 8.x 的写入限流）：当节点写入内存超过 `total_shard_size / 512` 时会拒绝新写入（返回 `es_rejected_execution_exception`）。这不是 bug，是你灌太快了——**必须处理这个异常并退避重试**。

### 2.4 Java 侧实现：带背压与逐条错误检查的 BulkProcessor

```java
public class EsVectorIngestor implements Closeable {

    private final RestClient restClient;
    private final Semaphore inflight;          // 控制并发 bulk 数
    private final ExecutorService pool;

    public EsVectorIngestor(RestClient client, int maxInflight) {
        this.restClient = client;
        this.inflight = new Semaphore(maxInflight);
        this.pool = Executors.newFixedThreadPool(maxInflight);
    }

    /** 分批灌入；每批必须有独立的重试与错误检查 */
    public void ingest(String index, List<Chunk> chunks, int batchSize) {
        for (int i = 0; i < chunks.size(); i += batchSize) {
            List<Chunk> batch = chunks.subList(i, Math.min(i + batchSize, chunks.size()));
            submitBatch(index, batch);
        }
    }

    private void submitBatch(String index, List<Chunk> batch) {
        try {
            inflight.acquire();                // 背压：并发满了就阻塞生产者
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(e);
        }
        pool.submit(() -> {
            try {
                doBulkWithRetry(index, batch, 0);
            } finally {
                inflight.release();
            }
        });
    }

    private void doBulkWithRetry(String index, List<Chunk> batch, int attempt) {
        StringBuilder ndjson = new StringBuilder(batch.size() * 4600);
        for (Chunk c : batch) {
            // _id 用确定性 ID：重复灌入是覆盖而非重复
            ndjson.append("{\"index\":{\"_index\":\"").append(index)
                  .append("\",\"_id\":\"").append(c.docId()).append("\"}}\n");
            ndjson.append("{\"doc_id\":\"").append(c.docId())
                  .append("\",\"tenant\":\"").append(c.tenant())
                  .append("\",\"text\":").append(jsonEscape(c.text()))
                  .append(",\"embedding\":").append(toJsonArray(c.vector()))
                  .append("}\n");
        }

        try {
            Request req = new Request("POST", "/_bulk");
            req.setEntity(new NStringEntity(ndjson.toString(), ContentType.APPLICATION_NDJSON));
            Response resp = restClient.performRequest(req);
            JsonNode root = MAPPER.readTree(resp.getEntity().getContent());

            if (root.path("errors").asBoolean(false)) {
                // 关键：bulk 返回 200，但 items 里可能有失败的
                Retryable retry = new Retryable();
                for (JsonNode item : root.path("items")) {
                    JsonNode idx = item.path("index");
                    int status = idx.path("status").asInt();
                    if (status >= 200 && status < 300) continue;
                    if (status == 429 || status == 503) {
                        retry.add(idx.path("_id").asText());   // 限流类：重试
                    } else {
                        // 4xx 类（mapping 冲突、维度不匹配）：重试无用，必须暴露
                        log.error("permanent failure id={} status={} err={}",
                                idx.path("_id").asText(), status, idx.path("error"));
                    }
                }
                if (!retry.isEmpty() && attempt < 5) {
                    sleepBackoff(attempt);
                    doBulkRetry(index, batch, retry.ids(), attempt + 1);
                }
            }
        } catch (IOException e) {
            if (attempt < 5) { sleepBackoff(attempt); doBulkWithRetry(index, batch, attempt + 1); }
            else throw new UncheckedIOException(e);
        }
    }
    // ... 省略 toJsonArray / jsonEscape / doBulkRetry 等
}
```

三个必须记住的点：

1. **bulk 的 HTTP 200 不代表写入成功**，必须解析 `items[].status`；
2. **`_id` 用确定性 ID**（如 `docId`），重试天然幂等；
3. **`es_rejected_execution_exception`（429）要退避重试**，`mapper_parsing_exception`（400）要立即失败并告警——混在一起重试会掩盖真实问题。

## 三、Qdrant：`indexing_threshold` 是关键开关

Qdrant 在 collection 里维护 segment，新写入的数据先进入「未建索引的 segment」（可暴力扫描），累计到阈值后由 optimizer 后台建 HNSW 图。

```java
// 灌数前：把阈值调到极大，等于「先不建图」
client.getCollections();
client.updateCollection(UpdateCollection.newBuilder()
        .collectionName("rag_chunks")
        // 优化器阈值：字节数或点数，两者取先到
        .optimizersConfigDiff(OptimizersConfigDiff.newBuilder()
                .indexingThreshold(100_000_000L)     // 1 亿 KB，实际等于关闭
                .memmapThreshold(50_000_000L)
                .build())
        .build());
```

灌完后恢复：

```java
client.updateCollection(UpdateCollection.newBuilder()
        .collectionName("rag_chunks")
        .optimizersConfigDiff(OptimizersConfigDiff.newBuilder()
                .indexingThreshold(20_000L)          // 2 万点开始建图
                .build())
        .build());
```

**为什么有效**：HNSW 的插入是「边插边连边」，每次插入要搜索候选邻居（O(log n) 次距离计算）。批量灌数时如果边灌边建图，总共要做 N 次图插入；先灌后建图，Qdrant 可以用更高效的批量构建路径（一次构建一张图）。

代价：**建图期间查询会变慢**（未建索引的 segment 要暴力扫描）。所以这个策略只适合「停机灌数」或者「灌到新 collection 再切流量」。

### 3.1 幂等与 payload 索引

```java
// 1. 用确定性 ID：Qdrant 的 upsert 语义是「同 ID 覆盖」
PointStruct point = PointStruct.newBuilder()
        .setId(PointId.newBuilder().setUuid(chunk.docId()).build())
        .setVectors(Vectors.newBuilder().setVector(
                Vector.newBuilder().addAllData(toFloatList(chunk.vector()))))
        .putAllPayload(Map.of(
                "doc_id", chunk.docId(),
                "tenant", chunk.tenant(),
                "text", chunk.text(),
                "version", chunk.docVersion()))
        .build();

// 2. 过滤字段必须建 payload index，否则 filter 会退化成全量扫描
client.createPayloadIndex(CreateFieldIndexCollection.newBuilder()
        .collectionName("rag_chunks")
        .fieldName("tenant")
        .fieldType(PayloadSchemaType.KEYWORD)
        .build());
```

**没建 payload index 的 `tenant` 过滤，是 Qdrant 上最常见的「检索慢 100 倍」原因**。这一点和 ES 的 keyword mapping 一样，属于「不建也能跑，但一跑就废」。

## 四、Milvus：bulkInsert 与 growing segment

Milvus 的写入路径是「客户端 → proxy → msg stream → datanode → growing segment → sealed segment → compaction」。对 Java 用户来说，关键有两点：

**1. 大批量用 `bulkInsert`（走文件），不要用 `insert` 循环。**
`bulkInsert` 把数据写成 Parquet/Numpy 文件，由 datanode 批量导入，省掉了逐条走消息队列的开销。代价是数据要先落对象存储。

**2. `growing segment` 上的检索是暴力扫描。**
刚灌进去的数据在 growing segment 里没有索引，查询会退化为暴力扫描。灌数期间如果同时有查询，延迟会飙。解决办法是灌完等 compaction 完成（`getCompactionState`），或者灌到新 collection 再切换 alias。

## 五、pgvector：唯一的正确姿势是「先灌数据，后建索引」

pgvector 的 HNSW 是**整表一张图**。这意味着：

- 有索引时插入一行，要更新全局图（`ef_construction` 次距离计算 + 邻居重连），单行插入可能 1~5ms；
- 2000 万行边灌边建索引，等于 2000 万次图更新，写入吞吐会掉到几百行/秒。

正确顺序：

```sql
-- 1. 建表，不建向量索引
CREATE TABLE rag_chunks (
  id          text PRIMARY KEY,
  doc_id      text NOT NULL,
  tenant      text NOT NULL,
  chunk_no    int  NOT NULL,
  content     text NOT NULL,
  embedding   vector(1024) NOT NULL
);

-- 2. COPY 灌数（比 INSERT 快一个数量级）
\copy rag_chunks FROM 'chunks.csv' WITH (FORMAT csv, HEADER true)

-- 3. 灌完再建索引（并行 + 大内存）
SET maintenance_work_mem = '8GB';
SET max_parallel_maintenance_workers = 4;
CREATE INDEX CONCURRENTLY idx_rag_hnsw ON rag_chunks
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 200);

-- 4. 检索侧设置 ef_search（会话级）
SET hnsw.ef_search = 100;
```

三个坑：

1. **`CREATE INDEX CONCURRENTLY` 和 HNSW 不兼容**（pgvector 的 HNSW 建索引需要 `ShareLock`），必须用普通 `CREATE INDEX`，建索引期间写入被阻塞。所以一定要在低峰做，或者用「新表 + 切换」。
2. **`maintenance_work_mem` 不够会退化成磁盘排序**，建索引时间从 20 分钟变成 3 小时。经验值：每 100 万行 1024 维约需 4~6GB。
3. **增量插入仍会很慢**。pgvector 0.7+ 有 `hnsw.insert` 的优化，但本质仍是全局图更新。**高频增量场景不要选 pgvector**，或者把增量写入攒批（每 5 分钟一批，用 `INSERT ... SELECT` 批量进）。

## 六、HNSW 增量插入的隐藏问题：图质量会漂移

这是最少人提、但影响最大的问题。

HNSW 的图是**插入顺序敏感**的：每个新节点连到「当前已有的最近邻」。如果数据分布随时间变化（比如新上线的产品文档主题完全不同），后插入的节点会连接到「当时最近的」节点上，而这些节点可能不是全局最优邻居。

后果：

| 现象 | 原因 |
|---|---|
| 召回率随数据增长缓慢下降 | 新节点邻居选择偏差累积 |
| 删除后再插入，效果更差 | 删除只是标记，图的连通性被破坏 |
| 同一批数据「重建索引」后召回率提升 3~8% | 重建时是批量构建，图质量更好 |
| `ef_search` 调大也救不回来 | 是图结构问题，不是搜索预算问题 |

**工程结论**：

1. **定期重建**。按「数据量增长 50%」或「季度」触发一次全量重建（灌到新索引 → 建图 → alias 切换 → 删旧）。
2. **删除后不依赖标记删除**。Qdrant/Milvus 的 optimizer/compaction 会重建 segment，ES 的 forceMerge 会重写 segment —— 这些都是「间接重建」的机会，要主动触发。
3. **每次重建后跑黄金集评测**。不要假设「同样的参数 = 同样的效果」。

## 七、灌数作业的标准时间线

以 2000 万 chunk、1024 维、单机 ES 3 节点为例：

| 阶段 | 耗时 | 关键动作 |
|---|---|---|
| 0. 准备 | 10 min | 新索引 + mapping（`dense_vector` dims/相似度必须一开始就定对）+ 副本 0 + refresh -1 |
| 1. 灌数 | 3~6 h | bulk 8MB/批，并发 4~8，`translog.durability=async`，处理 429 退避 |
| 2. 校验 | 20 min | `_count` 对账 + 抽样 1000 条做「向量自身余弦=1」自检 + 黄金集召回 |
| 3. 建图/合并 | 1~3 h | `forceMerge(max_num_segments=3)` 或等 optimizer；监控 IO 与 heap |
| 4. 恢复配置 | 5 min | refresh 1s、副本 1、translog 恢复 `request` |
| 5. 切流量 | 5 min | alias 切换（**不要改客户端代码**） |
| 6. 观察 | 24 h | 检索 P99、召回率、拒绝率 |

**alias 切换是这套流程的灵魂**：所有读写都走 alias（`rag_chunks` → 实际索引 `rag_chunks_v7`），重建时只是把 alias 指过去，回滚也是指回去。这比任何「原地重建」的方案都安全。

## 八、观测指标（灌数期间必须盯的六个）

| 指标 | 来源 | 阈值 |
|---|---|---|
| bulk 拒绝率 | ES `es_rejected_execution` / Qdrant `429` | > 1% 就降并发 |
| segment 数 | `_cat/indices?v&h=index,segments.count` | > 50 说明 refresh 没关 |
| heap 使用 | `_nodes/stats/jvm` | > 85% 停止灌数 |
| merge 压力 | `_nodes/stats/indices/merge` 的 `current_size` | 持续增长说明写入过快 |
| 磁盘剩余 | `df` | < 20% 停（merge 需要额外空间，约 1.2 倍） |
| 检索 P99 | 业务侧 | 灌数期间允许劣化，但要能区分 |

## 九、面试追问

**Q1：为什么灌数时要关 refresh？**
每次 refresh 会把内存 buffer 变成一个不可变 segment，而向量索引是 segment 级的。refresh 越频繁，segment 越多，HNSW 图的构建次数越多，总开销成倍上升；同时查询要合并更多 segment 的结果，延迟上升。

**Q2：bulk 返回 200 但数据没进去，可能吗？**
会。`_bulk` 是「部分成功」语义，HTTP 200 只代表请求被处理，每条结果在 `items[]` 里。必须检查 `errors` 字段和每条 `status`，并对 429/503 做退避重试。

**Q3：pgvector 为什么不适合高频增量写入？**
HNSW 是整表一张图，每插入一行都要更新全局图（候选邻居搜索 + 重连）。数据量大后单行插入代价从微秒级升到毫秒级，写入吞吐被图更新锁死。

**Q4：怎么保证重灌数据后检索效果不退化？**
三件事：确定性 `_id`（幂等）、黄金集回归（召回率/NDCG 与基线对比，允许 ±2%）、全量重建 HNSW（避免增量插入的图质量漂移）。参数相同不等于效果相同。

## 总结

- 写入路径决定了检索质量的上限：**segment 型**库怕 segment 太多，**全局图型**库怕增量插入。
- ES：关 refresh、副本 0、bulk 按字节控制、`items[].status` 必须检查、429 退避。
- Qdrant：灌数前把 `indexing_threshold` 拉高（等于先不建图），灌完恢复；`payload index` 不建就等着慢 100 倍。
- Milvus：大批量走 `bulkInsert`，growing segment 是暴力扫描，等 compaction。
- pgvector：先灌后建索引，`maintenance_work_mem` 给足，别用 `CONCURRENTLY`。
- 通用：**确定性 ID + alias 切换 + 黄金集回归**，这是重灌数据的三件套。

RAG 的「检索效果不好」，十个里有三个是 Embedding 模型问题，七个是写入与索引工程问题。先把写入侧做对，再谈模型选型。
