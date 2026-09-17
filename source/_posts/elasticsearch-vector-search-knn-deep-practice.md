---
title: 【ES 实战】Elasticsearch 向量检索深度实战：dense_vector、HNSW 与混合检索
date: 2026-09-17 08:00:00
tags:
  - Elasticsearch
  - 向量检索
  - 检索推荐
categories:
  - 中间件
  - 搜索
author: 东哥
---

# 【ES 实战】Elasticsearch 向量检索深度实战：dense_vector、HNSW 与混合检索

## 面试官：你们的语义搜索为什么不用向量数据库，而是塞进 ES？

这是一个很真实的追问。2023 年之后，"向量检索"几乎成了搜索系统的标配能力：商品以图搜图、工单语义去重、知识库 RAG 召回，都需要"相似度"而不是"关键词命中"。很多团队第一反应是引入 Milvus / Qdrant 这类专用向量库，但真实工程里往往会出现第三个选项：**把向量存进已有的 Elasticsearch**。

原因不复杂：

- 业务数据的主存储本来就在 ES（商品、文章、日志），再搭一套向量库意味着**双写 + 双查 + 数据一致性治理**；
- 大部分场景是"过滤 + 排序"的组合（先按类目、状态、时间过滤，再按相似度排序），向量库的过滤能力反而弱；
- 运维成本：多一个集群就多一套监控、备份、扩容、故障预案。

所以本文不讨论"要不要用向量库"，而是把 ES 的向量检索讲透：`dense_vector` 字段类型、HNSW 图索引、打分函数、`knn` 检索 API 与 filter 前置、以及**混合检索（BM25 + kNN）** 的工程落地。

## 一、dense_vector 字段与索引选项

ES 7.0 引入了 `dense_vector`，但直到 **8.0** 才真正可用——因为 8.0 才支持 `index: true`（HNSW 近似最近邻索引）。7.x 时代只能做脚本打分的暴力精确检索（script_score + cosineSimilarity），数据量一过十万就崩。

```json
PUT products
{
  "mappings": {
    "properties": {
      "title":      { "type": "text" },
      "category":   { "type": "keyword" },
      "price":      { "type": "scaled_float", "scaling_factor": 100 },
      "updated_at": { "type": "date" },
      "title_vec": {
        "type": "dense_vector",
        "dims": 768,
        "index": true,
        "similarity": "cosine",
        "index_options": {
          "type": "hnsw",
          "m": 16,
          "ef_construction": 200
        }
      }
    }
  }
}
```

关键参数逐个拆：

| 参数 | 含义 | 调优建议 |
| --- | --- | --- |
| `dims` | 向量维度，必须固定 | 与 embedding 模型强绑定，改模型就得重建索引 |
| `index` | 是否建 HNSW 索引 | 只在需要 ANN 时开启；纯 script_score 场景可关 |
| `similarity` | `cosine` / `dot_product` / `l2_norm` | 文本 embedding 基本都是 cosine；已归一化可用 dot_product（更快） |
| `m` | 每个节点连边数 | 越大召回率越高、内存越大；默认 16，一般 16~48 |
| `ef_construction` | 建图时的候选队列长度 | 越大图质量越好、建索引越慢；默认 100，数据大用 200~500 |
| `ef_search` | 查询时候选队列长度 | **运行时可调**，是召回率/延迟的旋钮 |

> 经验值：`cosine` 相似度下，向量会被 ES 自动归一化存储，因此 `m=16, ef_construction=200` 是绝大多数业务的起点；真正要调的是查询期的 `ef_search`。

## 二、HNSW 到底在做什么

HNSW（Hierarchical Navigable Small World）不是"扫全量算距离"，而是一张**分层可导航图**：

- **底层（layer 0）** 包含所有向量节点；
- 上层是逐渐稀疏的"高速公路"，用于快速跳转到目标区域；
- 查询时自顶向下贪心搜索：上层大步跳，下层小步收敛；
- 每个节点的出边数受 `m` 限制，层高服从指数分布（近似跳表的思想）。

它把复杂度从精确检索的 O(N·d) 降到 **约 O(log N·d)**，代价是**近似**——可能漏掉真正的最近邻（recall < 100%）。

::: warning 内存账要先算清楚
HNSW 图索引全部驻留堆外（JVM heap 之外）。粗算：`dims × 4B × N × (1 + 图开销)`。768 维、100 万条 ≈ 3GB 向量本体，加上图结构通常要到 4~5GB。**ES 堆内存只放元数据，向量和向量索引吃的是 off-heap**，所以节点规格要按"向量数据量 × 1.6"预估内存。
:::

## 三、knn 检索 API：从暴力到 ANN

### 3.1 精确检索（小数据量 / 需要 100% 召回）

```json
POST products/_search
{
  "size": 10,
  "query": {
    "script_score": {
      "query": { "match_all": {} },
      "script": {
        "source": "cosineSimilarity(params.qv, 'title_vec') + 1.0",
        "params": { "qv": [0.12, -0.33, 0.88] }
      }
    }
  }
}
```

注意 `+ 1.0`：ES 的打分不能为负，而 cosine 值域是 [-1, 1]，必须整体平移。这种写法会**遍历所有文档**，只适合万级以内数据或离线校验 HNSW 的召回率。

### 3.2 近似检索（生产主用法）

```json
POST products/_search
{
  "size": 10,
  "knn": {
    "field": "title_vec",
    "query_vector": [0.12, -0.33, 0.88],
    "k": 50,
    "num_candidates": 500,
    "filter": {
      "bool": {
        "filter": [
          { "term": { "category": "phone" } },
          { "range": { "price": { "gte": 1000, "lte": 5000 } } }
        ]
      }
    }
  },
  "_source": ["title", "category", "price"]
}
```

两个数字必须分清：

- **`k`**：最终参与排序/返回的候选数（近似 top-k 的 k）；
- **`num_candidates`**：每个分片在 HNSW 图上实际取出的候选数。

```text
num_candidates 越大 → 召回率越高 → 延迟越高
经验公式：num_candidates ≈ max(1.5 * k, 100)，高召回场景放到 20 * k
```

### 3.3 filter 前置：性能分水岭

ES 8.x 的 `knn.filter` 支持**前置过滤（filtered HNSW search）**：在图上遍历时就判断文档是否满足过滤条件，而不是"先 ANN 取 top-k 再过滤"。后者的致命问题是——过滤条件如果很窄（比如只剩 1% 的文档），top-100 里可能一条都不满足，结果为空。

所以：

- 过滤条件选择性高（命中比例 < 20%）：用 `knn.filter`；
- 过滤条件很宽（命中 > 80%）：用 `post_filter` 或外层 `bool.filter` 也能接受；
- **绝对不要**把过滤写在 `bool.must` 里的 `script_score` 旁边还指望它走 ANN。

## 四、混合检索：BM25 + kNN 融合排序

纯向量检索的短板是**精确匹配失忆**：搜"iPhone 15 Pro 256G 蓝色"时，向量可能召回一堆"手机壳"。纯 BM25 的短板是**语义泛化差**：搜"怎么给笔记本降温"，匹配不到"散热底座推荐"。

生产方案是两条召回并列 + 分数融合。

### 4.1 用 RRF（Reciprocal Rank Fusion）融合

ES 8.8+ 提供了内置的 `rrf`：

```json
POST products/_search
{
  "size": 10,
  "retriever": {
    "rrf": {
      "retrievers": [
        {
          "standard": {
            "query": {
              "multi_match": {
                "query": "iPhone 15 Pro 蓝色",
                "fields": ["title^3", "desc"]
              }
            }
          }
        },
        {
          "knn": {
            "field": "title_vec",
            "query_vector": [0.12, -0.33, 0.88],
            "k": 50,
            "num_candidates": 500
          }
        }
      ],
      "rank_window_size": 50,
      "rank_constant": 60
    }
  }
}
```

RRF 的公式很朴素，这也是它鲁棒的原因：

```text
score = Σ over retrievers: 1 / (rank_constant + rank_i)
```

它**只用排名不用原始分**，因此天然规避了"BM25 分数 0.3~30 与 cosine 0~1 量纲不可比"的经典难题。`rank_constant` 默认 60，越小则头部文档权重越集中。

### 4.2 Java 客户端写法

```java
public List<ProductDoc> hybridSearch(String keyword, float[] queryVector, int size) {
    Query textQuery = MultiMatchQuery.of(m -> m
            .query(keyword)
            .fields("title^3", "desc"))._toQuery();

    KnnQuery knnQuery = KnnQuery.of(k -> k
            .field("title_vec")
            .queryVector(queryVector)
            .k(50L)
            .numCandidates(500L));

    SearchResponse<ProductDoc> resp = client.search(s -> s
            .index("products")
            .size(size)
            .retriever(r -> r.rrf(rrf -> rrf
                    .retrievers(
                            Retriever.of(r1 -> r1.standard(st -> st.query(textQuery))),
                            Retriever.of(r2 -> r2.knn(knnQuery)))
                    .rankWindowSize(50L)
                    .rankConstant(60L))),
            ProductDoc.class);

    return Arrays.stream(resp.hits().hits())
            .map(Hit::source)
            .filter(Objects::nonNull)
            .toList();
}
```

## 五、写入链路：embedding 从哪来

ES 8.x 支持 **ingest pipeline 内置推理**，把 embedding 生成下沉到写入阶段，业务只写文本：

```json
PUT _ingest/pipeline/product-embedding
{
  "processors": [
    {
      "inference": {
        "model_id": "bge-large-zh",
        "input_output": [
          { "input_field": "title", "output_field": "title_vec" }
        ]
      }
    }
  ]
}
```

自建模型则用文本相似度/外部服务 + 批量回填：

- **增量写入**：业务侧调 embedding 服务，随文档一起写 ES；
- **存量回填**：`_update_by_query` 走 pipeline，注意加 `?wait_for_completion=false` 并用 `_tasks` 轮询，避免长事务式阻塞；
- **模型升级**：dims 变了必须重建索引，用 alias 切换（`products_v1` → `products_v2` → `products`），不要原地 reindex。

## 六、生产踩坑清单

1. **召回率不是 100%**。上线前必须用精确检索（script_score）做一次 ground truth，测 recall@10。低于 0.9 就调 `ef_search` / `num_candidates`。
2. **`ef_search` 要在搜索请求里传**，不是 mapping 里配：

   ```json
   { "knn": { "field": "title_vec", "query_vector": [...], "k": 10, "num_candidates": 300 } }
   ```

   8.x 中可通过索引级 `index.knn` 与查询参数联动，或用 `_search` 的 `knn` 参数覆盖。

3. **分片数决定 ANN 上限**。kNN 是分片内并行后归并，分片过多会导致每个分片候选太少、召回下降；向量索引建议**单分片 100 万~500 万向量**。
4. **冷热分层**。向量索引加载慢（重启后要读图），把大索引放在专用 data tier，别和日志索引混部。
5. **不要用 `dense_vector` 存"要做聚合"的数据**，它只能排序不能聚合。
6. **模型维度与归一化**：`cosine` 会归一化，若你自己做了 L2 归一化，直接用 `dot_product`，省一次计算且误差更小。

## 面试追问连击

**追问 1：HNSW 和 IVF 有什么区别？**
HNSW 是图索引，查询靠贪心游走，召回率高、延迟低、内存大、构建慢；IVF（倒排文件）是聚类分桶，先找最近的 nprobe 个簇再桶内暴力，内存小、构建快，但边界效应会导致召回不稳。ES 只提供 HNSW，IVF/PQ 要去 Milvus/Faiss。

**追问 2：为什么向量检索不能加 `sort`？**
kNN 的语义就是"按相似度排序"，`_score` 已由距离决定。你要的"按价格再排"其实是**过滤后二次排序**，正确做法是 `knn.filter` 收窄候选 + `_source` 回业务层/或 `script_score` 里做加权组合，而不是用 `sort` 覆盖。

**追问 3：`num_candidates` 和 `k` 谁影响延迟？**
`num_candidates` 决定图上要访问多少节点，是**延迟的主要来源**；`k` 只影响归并排序与返回体大小。调优顺序永远是先定 `k`，再用 `num_candidates` 找召回/延迟的甜点。

**追问 4：混合检索为什么选 RRF 不选加权求和？**
加权求和需要归一化两种分数量纲，且权重随 query 类型漂移，线上极难调稳；RRF 只用排名，冷启动就能用，且对异常分数天然免疫。只有在你能拿到稳定的相关性标注、做离线学习排序时，加权或 LambdaMART 才值得上。

## 小结

- ES 的向量检索从 8.0 起才真正可生产：`dense_vector` + `index: true` + HNSW。
- 三个旋钮：`m`/`ef_construction` 决定图质量（写入期），`num_candidates` 决定召回率（查询期）。
- `knn.filter` 前置过滤是性能分水岭，窄条件必须用它。
- 生产几乎一定是混合检索，RRF 是性价比最高的融合方式。
- 别忘了算 off-heap 内存账，向量索引不吃 JVM 堆。

把这套链路跑通，你会发现"要不要上向量数据库"这个问题，答案取决于**过滤复杂度**和**召回规模**，而不是"向量"两个字本身。
