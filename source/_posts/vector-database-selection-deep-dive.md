---
title: 【AI 基础】向量数据库选型深度对比：Milvus、Qdrant、pgvector 与 Elasticsearch（Java 客户端视角）
date: 2026-10-19 08:30:00
tags:
  - AI
  - 向量数据库
  - Milvus
  - Qdrant
  - pgvector
  - Elasticsearch
  - Java
categories:
  - AI 工程
author: 东哥
---

# 【AI 基础】向量数据库选型深度对比：Milvus、Qdrant、pgvector 与 Elasticsearch（Java 客户端视角）

## 前言

做 RAG 或语义检索，绕不开一个问题：**向量存哪儿？**

网上的选型文章大多在比"谁家 benchmark 的 QPS 高"，但真正做工程的人知道，benchmark 里的 1000 万条 768 维向量、单条件过滤、无并发写入，和你线上"每天增量 200 万条、带 5 个元数据过滤条件、还要和业务库事务对齐"完全是两回事。

本文换一个视角：**从 Java 后端的落地成本出发**，对比四类主流方案：

| 方案 | 定位 | 一句话 |
|---|---|---|
| **Milvus** | 专用分布式向量数据库 | 大规模、可水平扩展，运维最重 |
| **Qdrant** | 专用向量数据库（Rust） | 过滤能力强、单机性能好，部署轻 |
| **pgvector** | PostgreSQL 扩展 | 和业务数据同库同事务，最省心 |
| **Elasticsearch** | 搜索引擎 + 向量检索 | 已有 ES 集群时的自然选择，混合检索强 |

先说结论（不想看长文的可以拿走）：

- **数据量 < 500 万、已有 PG** → pgvector，别犹豫
- **已有 ES 且需要 BM25 + 向量混合检索** → Elasticsearch
- **1000 万~10 亿、要独立扩缩容** → Milvus
- **100 万~5000 万、过滤条件复杂、想轻运维** → Qdrant

下面讲为什么。

---

## 一、先搞清楚：向量检索到底在算什么

所有向量数据库的核心都是 **ANN（Approximate Nearest Neighbor）**：在可接受的时间内，找到"足够接近"的 Top-K，而不是精确的最近邻。

三个必须理解的概念：

### 1.1 距离度量

| 度量 | SQL 算子（pgvector） | 适用 |
|---|---|---|
| 余弦相似度 | `<=>` | 文本 Embedding（最常用） |
| 内积 | `<#>` | 已归一化向量，等价余弦 |
| 欧氏距离 (L2) | `<->` | 图像/音频特征 |
| 汉明距离 | `<~>`（bit 类型） | 二值哈希 |

**关键点**：如果用余弦相似度，**入库前一定要归一化**（L2 norm = 1），这样内积就等于余弦，能省一次开方，而且很多索引对内积优化更好。OpenAI、BGE、通义等主流 Embedding 输出都需要你显式归一化。

### 1.2 索引：HNSW 与 IVF 的取舍

| 索引 | 原理 | 查询速度 | 召回率 | 内存 | 构建速度 |
|---|---|---|---|---|---|
| FLAT | 暴力扫描 | 慢 | 100% | 低 | 极快 |
| IVF_FLAT | 聚类分桶 + 桶内扫描 | 中 | 中（依赖 `nprobe`） | 中 | 快 |
| IVF_PQ | 聚类 + 乘积量化压缩 | 快 | 中低 | 很低 | 中 |
| HNSW | 多层可导航小世界图 | 极快 | 高（依赖 `ef`） | **高（1.5~2x 原始向量）** | 慢 |
| DiskANN | 图索引 + SSD | 快 | 高 | 低（内存只需少量） | 中 |

工程结论：**默认选 HNSW**，除非内存真的放不下（> 5000 万向量），再考虑 DiskANN 或 IVF_PQ。

### 1.3 过滤（filter）：真正拉开差距的地方

RAG 场景几乎不会"全库检索"，一定会带过滤：

```sql
-- 典型查询
WHERE tenant_id = 42 AND doc_type = 'policy' AND created_at > '2026-01-01'
ORDER BY embedding <=> :query_vec LIMIT 10
```

过滤和 ANN 的结合方式有三种，性能差异巨大：

| 方式 | 做法 | 问题 |
|---|---|---|
| **后过滤**（post-filter） | 先 ANN 取 Top-1000，再过滤 | 过滤条件苛刻时结果不够 10 条 |
| **先过滤**（pre-filter） | 先过滤出候选集，再暴力算 | 候选集大时退化成全扫描 |
| **图内过滤**（in-graph filtering） | 遍历 HNSW 时跳过不匹配节点 | 实现难，但效果最好 |

- **Qdrant** 在这件事上做得最好：payload 索引 + filterable HNSW，过滤条件直接参与图遍历
- **Milvus** 支持标量字段过滤，2.4+ 有 `filter` 表达式与分区（partition）配合
- **pgvector** 0.8 引入**迭代索引扫描**（iterative index scan），缓解"先过滤导致结果不足"的问题
- **Elasticsearch** 用 Lucene 的 filter + kNN，支持 `filter` 参数做 pre-filter

---

## 二、四个方案逐个拆

### 2.1 pgvector：最被低估的选项

**架构**：PostgreSQL 的一个 extension，向量就是普通列，索引就是普通索引。

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE doc_chunk (
  id          bigserial PRIMARY KEY,
  tenant_id   bigint NOT NULL,
  doc_id      bigint NOT NULL,
  content     text   NOT NULL,
  embedding   vector(1024) NOT NULL,
  created_at  timestamptz DEFAULT now()
);

-- HNSW 索引（余弦）
CREATE INDEX idx_chunk_emb ON doc_chunk
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- 带过滤的检索
SET hnsw.ef_search = 100;
SELECT id, content, 1 - (embedding <=> :q) AS score
FROM doc_chunk
WHERE tenant_id = :tenant AND doc_type = 'policy'
ORDER BY embedding <=> :q
LIMIT 10;
```

**优点**：

- **事务一致**：向量和业务数据同一个事务，删除文档时级联删 chunk，不会出现"文档删了向量还在"
- **运维零新增**：备份、监控、权限、审计全部复用 PG 体系
- **SQL 能力**：JOIN、聚合、窗口函数、RLS 行级安全（多租户隔离直接白送）
- **成本极低**：不需要新组件、新团队

**缺点**：

- 单机上限：HNSW 索引必须放内存，**千万级向量 + 1024 维**就很吃内存
- 写入放大：HNSW 插入较慢，批量导入要关索引后重建
- 水平扩展难：靠 Citus / 分库分表，不是原生能力
- 索引维度限制：`vector` 类型 HNSW 索引最大 2000 维（`halfvec` 可到 4000）

**Java 落地**（Spring JDBC，不需要任何特殊 SDK）：

```java
String sql = """
    SELECT id, content, 1 - (embedding <=> ?::vector) AS score
    FROM doc_chunk
    WHERE tenant_id = ? AND doc_type = ?
    ORDER BY embedding <=> ?::vector
    LIMIT ?
    """;

List<Chunk> hits = jdbc.query(sql, (rs, i) -> new Chunk(
        rs.getLong("id"), rs.getString("content"), rs.getDouble("score")),
    toPgVector(queryVec), tenantId, "policy", toPgVector(queryVec), 10);

// float[] -> "[0.12,0.34,...]"
static String toPgVector(float[] v) {
    StringBuilder sb = new StringBuilder("[");
    for (int i = 0; i < v.length; i++) {
        if (i > 0) sb.append(',');
        sb.append(v[i]);
    }
    return sb.append(']').toString();
}
```

> 性能提示：批量写入用 `COPY`，并在导入前 `DROP INDEX`、导入后 `CREATE INDEX`，比逐条 INSERT 快一个数量级。

### 2.2 Qdrant：单机性能与过滤之王

**架构**：Rust 实现，单二进制/单容器，Raft 做分布式（3 节点起）。核心概念是 **collection + point(id, vector, payload)**。

**优点**：

- **过滤能力最强**：payload 字段可建索引，支持 `must/should/must_not` 嵌套、范围、geo、全文
- **量化省内存**：scalar（int8，省 4 倍）、binary（省 32 倍）、product quantization
- **多向量**：一个 point 可以有多个命名向量（如标题向量 + 正文向量），支持 hybrid
- **稀疏向量**：原生支持 SPLADE / BM25 稀疏向量，混合检索不用外挂
- **部署极轻**：一个容器搞定，本地开发体验最好

**缺点**：

- 生态比 Milvus 小，社区插件少
- 分布式能力相对年轻（分片 + 副本 + Raft），超大规模案例不如 Milvus 多
- 内存主要吃向量，量化是必需技能而非可选项

**Java 落地**：

```java
QdrantClient client = new QdrantClient(
        new QdrantGrpcClient(new QdrantGrpcClient.Builder("localhost", 6334)));

client.upsertAsync("doc_chunks", List.of(
    PointStruct.newBuilder()
        .setId(id(1))
        .setVectors(vectors(VectorFactory.vector("content", embedding)))
        .putPayload("tenant_id", value(42))
        .putPayload("doc_type", value("policy"))
        .build()));

QueryResponse resp = client.queryAsync(QueryPoints.newBuilder()
    .setCollectionName("doc_chunks")
    .setQuery(QueryFactory.nearest(embedding))
    .setFilter(Filter.newBuilder()
        .addMust(matchKeyword("tenant_id", 42))
        .addMust(matchKeyword("doc_type", "policy")))
    .setLimit(10)
    .setWithPayload(enable(true))
    .build()).get();
```

注意 `setFilter` 是**服务端过滤**（in-graph），不是拉回来再过滤——这正是 Qdrant 的核心优势。

### 2.3 Milvus：为规模而生

**架构**（2.x 存算分离）：

```
接入层：Proxy（无状态，可扩）
协调层：RootCoord / QueryCoord / DataCoord / IndexCoord
计算层：Query Node（查询）/ Data Node（写入）/ Index Node（建索引）
存储层：etcd（元数据）+ Object Storage（MinIO/S3，日志与索引）+ MQ（Pulsar/Kafka，日志流）
```

这是标准的"云原生分布式数据库"架构。好处是每一层都能独立扩缩容；坏处是**依赖组件多，运维复杂度最高**（生产至少 7~10 个 Pod）。

**优点**：

- **规模上限最高**：十亿级向量、水平扩展有大量公开案例
- **索引最全**：FLAT / IVF 系列 / HNSW / DiskANN / GPU_CAGRA / 稀疏索引 / 二值索引
- **分区（partition）+ 分区键**：多租户按 tenant 分区，物理隔离
- **一致性级别可调**：Strong / Bounded / Eventually / Session
- **Milvus Lite / Standalone / Cluster** 三种形态，开发到生产平滑过渡

**缺点**：

- 运维重（etcd + 对象存储 + MQ 都要管）
- 小规模（< 100 万）用它属于"杀鸡用牛刀"，成本不划算
- 版本升级偶有兼容坑，要跟 LTS

**Java 落地**：

```java
try (MilvusServiceClient client = new MilvusServiceClient(
        ConnectParam.newBuilder().withUri("http://localhost:19530").build())) {

    // 建集合（简化）
    client.createCollection(CreateCollectionParam.newBuilder()
        .withCollectionName("doc_chunks")
        .withSchema(new CollectionSchema()
            .addField(new FieldType().withName("id").withDataType(DataType.Int64)
                .withIsPrimaryKey(true).withAutoID(true))
            .addField(new FieldType().withName("tenant_id").withDataType(DataType.Int64))
            .addField(new FieldType().withName("embedding")
                .withDataType(DataType.FloatVector).withDimension(1024)))
        .build());

    // 检索
    SearchResults resp = client.search(SearchParam.newBuilder()
        .withCollectionName("doc_chunks")
        .withMetricType(MetricType.COSINE)
        .withOutFields(List.of("content"))
        .withExpr("tenant_id == 42")
        .withVectors(List.of(embedding))
        .withTopK(10)
        .withParams("{\"ef\":128}")
        .build());
}
```

**索引选择经验**：

- < 100 万：HNSW（`M=16, efConstruction=200`）
- 100 万 ~ 5000 万：HNSW 或 IVF_PQ（内存吃紧时）
- > 5000 万：DiskANN（SSD 存储，内存只需索引的 1/10）
- 需要 GPU：GPU_CAGRA（吞吐爆炸，但成本也爆炸）

### 2.4 Elasticsearch：已有 ES 时的最优解

**原理**：Lucene 9 引入 `KnnFloatVectorField`，HNSW 图存在 Lucene segment 里，和倒排索引共享同一套 segment / merge / 副本机制。

```java
ElasticsearchClient es = new ElasticsearchClient(transport);

SearchResponse<Doc> resp = es.search(s -> s
    .index("doc_chunks")
    .knn(k -> k
        .field("embedding")
        .queryVector(toList(queryVec))
        .k(10)
        .numCandidates(100)
        .filter(f -> f.bool(b -> b
            .must(m -> m.term(t -> t.field("tenant_id").value(42)))
            .must(m -> m.term(t -> t.field("doc_type").value("policy"))))))
, Doc.class);
```

**混合检索**是它的杀手锏（8.8+ 支持 RRF）：

```json
POST /doc_chunks/_search
{
  "retriever": {
    "rrf": {
      "retrievers": [
        { "standard": { "query": { "match": { "content": "退款政策" } } } },
        { "knn": { "field": "embedding", "query_vector": [...], "k": 50, "num_candidates": 200 } }
      ],
      "rank_window_size": 50,
      "rank_constant": 60
    }
  }
}
```

**优点**：

- **BM25 + 向量天然融合**，不用自己拼两套结果
- 生态成熟：Kibana、ILM、快照、权限、审计全都有
- 运维团队通常已经熟悉
- 8.16+/9.x 支持 **int8 / BBQ 量化**，内存大幅下降

**缺点**：

- 向量只是"附加能力"，超大向量规模（亿级）不是它的主场
- 写入成本高（refresh/merge/translog），不适合高频更新向量
- 内存要求高（堆 + 页缓存），JVM 调优是老话题

---

## 三、横向对比表

| 维度 | pgvector | Qdrant | Milvus | Elasticsearch |
|---|---|---|---|---|
| 语言/架构 | C（PG 扩展） | Rust | Go/C++ 分布式 | Java（Lucene） |
| 部署复杂度 | ★（复用 PG） | ★★ | ★★★★ | ★★★ |
| 规模上限 | 千万级 | 千万~亿级 | 十亿级 | 亿级（勉强） |
| 过滤能力 | 强（SQL） | 极强（payload 索引） | 强（表达式/分区） | 强（filter + query） |
| 混合检索 | 手写 SQL 融合 | 稀疏+稠密原生 | 支持（需配置） | **最强（RRF 内置）** |
| 事务一致性 | **强（同库）** | 最终一致 | 可调一致性 | 近实时（1s refresh） |
| 内存效率 | 中 | 高（量化） | 高（DiskANN） | 中（量化后改善） |
| Java 生态 | JDBC/MyBatis/JPA | 官方 Java client | 官方 Java SDK | 官方 Java client |
| 运维成本 | 极低 | 低 | 高 | 中 |
| 最适合 | 业务库旁挂 | 中型 RAG | 大规模平台 | 已有 ES 的搜索场景 |

---

## 四、Spring AI 抽象层：能不能屏蔽差异？

Spring AI 提供了统一的 `VectorStore` 接口：

```java
public interface VectorStore extends DocumentWriter, DocumentReader {
    void add(List<Document> documents);
    void delete(List<String> idList);
    void delete(Filter.Expression filterExpression);
    List<Document> similaritySearch(SearchRequest request);
}
```

各实现：`PgVectorStore`、`MilvusVectorStore`、`QdrantVectorStore`、`ElasticsearchVectorStore`、`RedisVectorStore`。

```java
@Bean
VectorStore vectorStore(EmbeddingModel embeddingModel, JdbcTemplate jdbc) {
    return PgVectorStore.builder(jdbc, embeddingModel)
            .dimensions(1024)
            .distanceType(COSINE_DISTANCE)
            .indexType(HNSW)
            .initializeSchema(true)
            .build();
}

// 业务代码完全与具体库解耦
vectorStore.add(List.of(new Document("1", "退款政策...", Map.of("tenant_id", 42))));
List<Document> docs = vectorStore.similaritySearch(
        SearchRequest.builder()
                .query("退款多久到账")
                .topK(5)
                .filterExpression("tenant_id == 42")
                .build());
```

**但要清醒**：抽象层只能统一 80% 的通用能力。这些一定绕不开具体实现：

- 索引参数调优（`m` / `ef_construction` / `nlist`）
- 混合检索 / 稀疏向量
- 分区、副本、一致性级别
- 批量导入与索引重建

所以**选型时不要指望"以后换库很容易"**。抽象层降低的是迁移成本，不是零成本。

---

## 五、容量与成本估算（选型必备）

### 5.1 内存估算公式

```
原始向量内存 = N × D × 4 bytes          (float32)
HNSW 额外开销 ≈ 原始 × (0.3 ~ 1.0)      (图结构，M 越大越高)
元数据/ID/payload ≈ N × 100~500 bytes
```

举例：**1000 万条 × 1024 维**

```
原始 = 1e7 × 1024 × 4 ≈ 41 GB
HNSW = 41 × 0.5 ≈ 20 GB
总   ≈ 60~70 GB（不含副本）
```

这个量级下：

- pgvector：单机 128G 内存勉强，且业务库也在这台机器上 → 危险
- Qdrant：int8 量化后 ≈ 17 GB，很轻松
- Milvus：3 个 query node 各 32G，轻松
- ES：需要 64G+ 堆外页缓存，成本较高

**结论**：**千万级是分水岭**。低于它，pgvector/Qdrant 足够；高于它，认真考虑 Milvus。

### 5.2 别忘了这些隐性成本

| 成本项 | 说明 |
|---|---|
| 副本 | 生产至少 2 副本，内存 ×2 |
| Embedding 重算 | 换模型 = 全量重嵌入，可能几天 |
| 索引重建 | 大批量导入后重建，需要额外磁盘与时间 |
| 冷启动 | HNSW 加载进内存需要时间，扩缩容有延迟 |
| 监控 | 需要单独的 QPS/延迟/召回率监控体系 |

---

## 六、选型决策树

```
已有 Elasticsearch 集群？
├─ 是 → 数据量 < 1 亿 且 需要 BM25 混合 → Elasticsearch
└─ 否
   ├─ 已有 PostgreSQL 且 向量 < 500 万？
   │   └─ 是 → pgvector（首选，省一个新组件）
   └─ 否
      ├─ 向量 > 5000 万 或 需要独立扩缩容？
      │   └─ 是 → Milvus
      └─ 否 → Qdrant（过滤强、运维轻、量化省内存）
```

**三条反直觉建议**：

1. **先别上向量数据库**。100 万以内、QPS 不高，pgvector + HNSW 完全够，多一个组件就是多一份故障源。
2. **过滤条件比 QPS 更重要**。你的真实查询 90% 带 tenant/doc_type 过滤，先验证候选库的"带过滤召回率"，而不是看裸 ANN 的 QPS。
3. **留好换模型的余地**。Embedding 模型半年一换，**向量表要能整体重建**（双写 + 别名切换），这比选哪个库更影响长期成本。

---

## 七、生产踩坑清单

1. **没归一化就用余弦**：某些库的 `COSINE` 会自动归一化，某些不会，跨库迁移时分数不可比。统一在应用层归一化。
2. **维度不一致**：换 Embedding 模型（768 → 1024）忘了重建集合，写入直接报错。**把模型名和维度写进集合元数据**。
3. **过滤后结果不足 K 条**：post-filter 的经典坑。用 pre-filter 或调大 `num_candidates` / `ef`。
4. **批量导入慢**：逐条 upsert。改成 batch（500~1000 条/批）+ 导入期间关闭索引 / 提高 `refresh_interval`。
5. **删除不彻底**：文档删除只删了业务表，向量还在，RAG 检索出"幽灵内容"。用同库事务（pgvector）或 CDC 同步删除。
6. **多租户串数据**：忘了加 `tenant_id` 过滤，A 公司检索到 B 公司文档——这是**安全事故**，不是 bug。用 RLS 或强制在 DAO 层注入过滤条件。
7. **只看平均延迟**：P99 才是用户感知。HNSW 的 P99 可能是 P50 的 5~10 倍。

---

## 八、面试常见追问

**Q1：为什么不直接用 FAISS？**
FAISS 是**库**不是**服务**：没有持久化、没有并发写入、没有副本、没有过滤、没有权限。它适合离线批量实验，不适合线上多租户服务。要落地必须自己包一层服务化，那还不如用成熟产品。

**Q2：HNSW 的 `M` 和 `ef` 怎么调？**
`M`（每个节点的邻居数）决定图连通性：越大召回越高、内存越多，常用 16~64。`ef_construction` 影响建索引质量（常用 100~200），`ef_search` 影响查询召回（常用 64~256，可运行时调）。**调优顺序：先定内存预算 → 定 M → 用黄金集调 ef 到目标召回率**。

**Q3：向量库怎么保证和业务数据一致？**
三条路：① 同库同事务（pgvector 唯一能做到强一致）；② 事务后发消息 + 消费端幂等写入（最终一致）；③ CDC 订阅 binlog 同步（解耦但延迟）。**删除场景最容易出问题**，必须显式设计。

**Q4：十亿向量怎么存？**
单机不可能。方案：Milvus 集群 + DiskANN（SSD）+ 分区键按租户/时间分片 + 冷热分层（近期数据 HNSW 在内存，历史数据 DiskANN）。同时用**二值量化/IVF_PQ** 把内存压到 1/8~1/32。

**Q5：怎么评估检索质量？**
构造黄金集（query + 正确文档 id），算 Recall@K、MRR、nDCG；再往上评估"端到端答案质量"（RAGAS 的 faithfulness / answer relevancy）。**只看延迟不看召回，是最常见的错误。**

---

## 九、总结

向量数据库选型不是"选最强的"，而是"选最匹配当前阶段的"：

- **pgvector** 赢在"不需要新组件"和事务一致性，是 80% 团队的正确答案
- **Qdrant** 赢在过滤能力和运维轻量，是中型 RAG 的甜点区
- **Milvus** 赢在规模上限和索引丰富度，代价是运维复杂度
- **Elasticsearch** 赢在混合检索和现有生态，向量只是它的加分项

对 Java 团队来说，还有一层现实考量：**Spring AI 的 `VectorStore` 抽象让切换成本可控，但索引调优和混合检索仍然绑定具体实现**。所以第一版选型时，把"数据量增长曲线"和"过滤条件复杂度"想清楚，比对比 benchmark 数字有用得多。
