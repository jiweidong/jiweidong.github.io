---
title: 【AI 体系】向量量化与索引内存治理：SQ/PQ/BQ 的原理取舍、召回损失评估与 Java 侧落地
date: 2026-11-10 08:20:00
tags:
  - AI
  - 向量检索
  - 量化
  - RAG
  - Java
categories:
  - AI 工程
author: 东哥
---

# 【AI 体系】向量量化与索引内存治理

## 前言

做 RAG 的同学大多经历过这个瞬间：本地 PoC 用 10 万条文档，`dense_vector` 建索引、检索 20ms，一切美好。上线时文档涨到 500 万条，运维找过来说"内存要 40G"，财务找过来说"月账单五位数"。

向量检索的成本结构非常"物理"：**一条 1536 维的 float32 向量就是 6144 字节，一千万条就是 61GB**，跟你的代码优雅程度完全无关。而 HNSW 还要在此之上再叠一层图结构（每个向量几十到上百字节的邻居 id）。

所以真正决定 RAG 能不能规模化落地的，不是 embedding 模型选得多好，而是**你有没有把向量的存储密度做上去**。这就是量化的位置。

这篇讲清楚四件事：

1. 主流量化方法（SQ/PQ/OPQ/BQ）到底在做什么，误差从哪来
2. 内存与召回怎么算、怎么权衡（带算例）
3. Java 侧怎么落地（ES / Qdrant / Milvus / Redis 的 Java 客户端）
4. 评测怎么做，才能证明"量化后召回没塌"

---

## 一、先算清楚基线：float32 到底多贵

统一记法：`N` = 向量条数，`d` = 维度。

```
原始存储 = N × d × 4 字节
```

| 规模 | 1536 维 float32 | 相当于 |
|---|---|---|
| 10 万 | 0.61 GB | 一台小机器够用 |
| 100 万 | 6.14 GB | 单机勉强 |
| 1000 万 | 61.4 GB | 必须分片 + 量化 |
| 1 亿 | 614 GB | 不量化根本做不了 |

HNSW 的额外开销（M = 每层邻居数，level 0 通常 2M）：

```
图结构 ≈ N × 2M × 4 字节（邻居 id 用 int32）
M=16 时 ≈ N × 128 字节
1000 万条 ≈ 1.28 GB
```

看起来图结构还好？但别忘了：**HNSW 的图必须在内存里才能高效随机访问**，而原始向量如果走"磁盘 + mmap"其实可以不全驻内存。真正吃内存的往往是**原始向量 + 图 + 量化副本**三份叠加。

还有一个常被忽略的乘数：**副本数**。ES 索引 1 主 1 副，内存就是 2 倍；3 分片 2 副本，就是 6 份。

---

## 二、四种量化方法：原理与误差来源

### 2.1 SQ（标量量化 / Scalar Quantization）

最直观的一种：**每个维度独立地映射到 8bit 整数**。

对每一维 `j`，在训练集上统计出 `min_j`、`max_j`（或用分位数），然后：

```
q_j = round((x_j - min_j) / (max_j - min_j) × 255)
x̂_j = min_j + q_j / 255 × (max_j - min_j)
```

存储从 4 字节降到 1 字节，**压缩 4 倍，内存直接降到 1/4**。

误差来源：
- **均匀量化假设**。如果某维的分布是长尾（大部分值挤在 0 附近），线性映射会把大量精度浪费在空旷区间。用**分位数裁剪**（如 0.99 分位）能显著改善。
- **离群点**。一个极端值会把 `max_j` 拉得很远，导致其余 99.99% 的点挤在很窄的桶里。所以工业实现基本都用 `[q_low, q_high]` 裁剪。
- **内积/余弦的偏差**。SQ 的误差是有偏的，但在归一化向量上通常可控。

**结论：SQ 是性价比最高的默认选项。** 4× 压缩、召回几乎不掉（正常 recall@10 掉 0.5%~2%）、实现简单、几乎所有向量库都支持。

### 2.2 PQ（乘积量化 / Product Quantization）

思路完全不同：**把 d 维切成 m 段，每段独立做 k-means（k=256），用 1 字节存"属于哪个聚类中心"**。

```
d = 1536, m = 96  → 每段 16 维
每段 256 个中心（8bit 索引）
存储 = m 字节 = 96 字节/向量
压缩比 = 6144 / 96 = 64×
```

查询时用 **ADC（Asymmetric Distance Computation）**：

1. 把 query 也切成 m 段
2. 预先算好 query 每一段到该段 256 个中心的距离 → `m × 256` 的距离表
3. 对每个候选向量，把它的 m 个字节索引**查表求和**，得到近似距离

这是 PQ 的精髓：**距离计算从 `d` 次乘加，变成 `m` 次查表加法**。既省内存又加速。

误差来源：
- **段内相关性被丢弃**。把 16 维强行切成独立子空间，如果这 16 维高度相关，信息损失很大。
- **码本表达能力**。256 个中心能不能覆盖该子空间的分布，取决于训练数据是否代表线上分布。
- **m 越小压缩越狠、误差越大**。`m = d/4` 是常见的起点。

**OPQ（Optimized PQ）** 就是来修第一个问题的：在 PQ 之前学一个**正交旋转矩阵 R**，把向量旋转到"各子空间尽量不相关、方差尽量均衡"的坐标系，再做 PQ。代价是多一次矩阵乘（`d × d`），换来明显的召回提升。

### 2.3 BQ（二值量化 / Binary Quantization）

每个维度只剩 1 bit：`x_j > 0 ? 1 : 0`。

```
1536 维 → 192 字节
压缩比 = 32×
距离 = Hamming 距离（用 popcount 硬件指令，极快）
```

优点夸张：**内存 32×、距离计算快一个数量级**（XOR + popcount，一条指令处理 64 位）。

缺点同样夸张：**信息损失巨大**，只保留"方向在哪个半空间"，丢失了所有幅度信息。所以 BQ 几乎**必须配合 rescoring**：

```
第一轮：BQ + Hamming 距离，oversample 取 top 200
第二轮：用原始 float32 向量对这 200 个精确重排，取 top 10
```

这套"粗排 + 精排"的结构让 BQ 在生产上非常能打：内存只有 1/32，延迟反而更低（因为第一轮极快，可以扫更多候选）。

ES 9.x 的 **BBQ（Better Binary Quantization）** 是在这个方向上的工程优化：通过更好的中心化/旋转和逐维优化，让二值化的召回损失显著小于朴素 BQ，同时保留 32× 的压缩。

### 2.4 一张对比表

| 方法 | 压缩比 | 每向量(1536维) | 召回损失 | 计算方式 | 适用 |
|---|---|---|---|---|---|
| float32 | 1× | 6144 B | 0 | 精确 | 小规模、精度敏感 |
| float16/half | 2× | 3072 B | ~0 | 精确 | 通用，几乎无脑选 |
| SQ int8 | 4× | 1536 B | 0.5%~2% | 整数点积 | **默认首选** |
| PQ (m=96) | 64× | 96 B | 3%~8% | 查表 (ADC) | 超大规模、内存极限 |
| OPQ + PQ | 64× | 96 B | 2%~5% | 旋转 + 查表 | PQ 的必选升级 |
| BQ | 32× | 192 B | 10%~25%（rescore 后 2%~5%） | Hamming | 高吞吐、可重排 |
| Matryoshka 截断 | 按比例 | 如 768 维 = 3072 B | 1%~4% | 精确 | 训练时支持的模型 |

> 表中召回损失是"经验区间"，**必须用你自己的数据测**。分布不同，差异能到 5 倍。

---

## 三、关键工程决策：量化 + 重排（rescore）

单用量化召回一定掉，工业界的标准解法是**两级检索**：

```
Stage 1（粗排）：量化索引，oversample = topK × 2~10
Stage 2（精排）：用原始向量（或更高精度副本）重算精确相似度，取 topK
```

三个必须一起考虑的参数：

| 参数 | 作用 | 典型值 |
|---|---|---|
| `oversample_factor` | 粗排取多少倍候选 | 2~4（SQ）、5~10（BQ） |
| 原始向量存哪 | 重排需要 float32 | 磁盘/mmap（ES 的 `bbq_disk` 就是这套） |
| 重排批量 | 一次算多少条 | 受 CPU cache 影响，64~256 |

**成本模型**：

```
总延迟 ≈ BQ/SQ 粗排(扫 N 条) + 精确重排(扫 topK×factor 条)
总内存 ≈ 量化索引(N × bytes) + 图(N × 128B)
```

这就是为什么 `int8 + rescore` 往往是**最优解**：粗排扫全量很快，重排只扫几百条，整体比"纯 float32 + HNSW"更快还更省。

---

## 四、Java 侧落地

### 4.1 Elasticsearch：`int8_hnsw` + rescore

ES 的 `dense_vector` 通过 `index_options.type` 选择量化方式：

```json
PUT /kb_chunk_v3
{
  "mappings": {
    "properties": {
      "tenant_id": { "type": "keyword" },
      "content":   { "type": "text" },
      "embedding": {
        "type": "dense_vector",
        "dims": 1536,
        "index": true,
        "similarity": "cosine",
        "index_options": {
          "type": "int8_hnsw",
          "m": 16,
          "ef_construction": 100
        }
      }
    }
  }
}
```

查询时通过 `rescore_vector` 做二次精排（ES 8.x+）：

```json
POST /kb_chunk_v3/_search
{
  "size": 5,
  "query": {
    "knn": {
      "field": "embedding",
      "query_vector_builder": { "text_embedding": { "model_id": "bge-m3", "model_text": "退款多久到账" } },
      "k": 50,
      "num_candidates": 200,
      "filter": { "term": { "tenant_id": "t-1024" } }
    }
  },
  "rescore": {
    "window_size": 50,
    "query": { "rescore_query": { "script_score": { "query": { "match_all": {} } } } }
  }
}
```

Java 侧（`elasticsearch-java` 客户端）：

```java
DenseVectorIndexOptions indexOptions = DenseVectorIndexOptions.of(b -> b
        .type(DenseVectorIndexOptionsType.INT8_HNSW)
        .m(16)
        .efConstruction(100));

Property embedding = Property.of(p -> p
        .denseVector(dv -> dv
                .dims(1536)
                .index(true)
                .similarity(DenseVectorSimilarity.COSINE)
                .indexOptions(indexOptions)));

client.indices().create(c -> c
        .index("kb_chunk_v3")
        .mappings(m -> m.properties("embedding", embedding)
                .properties("tenant_id", Property.of(p -> p.keyword(k -> k)))));
```

**关键点**：ES 的 `int8_hnsw` 会在写入时自动做量化（内部保留 float32 用于 rescore，或按配置只留量化值），**不需要你自己写量化代码**。你要做的是选对 `m`、`ef_construction` 和候选数。

> ES 9.x 增加了 `bbq_hnsw` / `bbq_disk`。`bbq_disk` 把原始向量放磁盘、只在内存留二值索引，适合"内存极紧 + 可接受重排 IO"的场景。选它之前一定要压测 P99，因为重排会触发磁盘读。

### 4.2 Qdrant：显式配置 scalar / binary quantization

Qdrant 的量化是**集合级配置**，可以显式指定 `always_ram`（量化副本常驻内存）：

```java
QdrantClient client = new QdrantClient(
        QdrantGrpcClient.newBuilder("localhost", 6334, false).build());

// 1) 建集合：原始向量放磁盘，量化副本常驻内存
client.createCollectionAsync("kb_chunk",
        Collections.CreateCollection.newBuilder()
                .setVectorsConfig(VectorsConfig.newBuilder().setParams(
                        VectorParams.newBuilder()
                                .setSize(1536)
                                .setDistance(Distance.Cosine)
                                .setOnDisk(true)                       // 原始向量落盘
                                .setHnswConfig(HnswConfigDiff.newBuilder()
                                        .setM(16).setEfConstruct(100).build())
                                .build()))
                .build()).get();

// 2) 开启标量量化（int8）
client.updateCollectionAsync("kb_chunk",
        Collections.UpdateCollection.newBuilder()
                .setQuantizationConfig(QuantizationConfig.newBuilder()
                        .setScalar(ScalarQuantization.newBuilder()
                                .setType(QuantizationType.Int8)
                                .setQuantile(0.99f)                    // 分位裁剪，抗离群点
                                .setAlwaysRam(true)                    // 量化副本常驻内存 → 快
                                .build())
                        .build())
                .build()).get();

// 3) 检索：oversample + rescore
List<ScoredPoint> hits = client.queryAsync(
        QueryPoints.newBuilder()
                .setCollectionName("kb_chunk")
                .setQuery(Query.newBuilder().setNearest(
                        Query.newBuilder().getNearestBuilder()
                                .setVectors(vectorInput(embedding))))
                .setLimit(10)
                .setParams(SearchParams.newBuilder()
                        .setQuantization(QuantizationSearchParams.newBuilder()
                                .setIgnore(false)       // 使用量化索引
                                .setRescore(true)       // 用原始向量重排
                                .setOversampling(2.0)   // 取 topK×2 候选
                                .build())
                        .build())
                .build()).get();
```

`quantile(0.99)` 这个参数很关键：它把 `[0.5%, 99.5%]` 之外的值裁掉，避免一个离群点毁掉整维的精度。**这是 SQ 最重要的调参项**，比选 int8 还是 int4 影响还大。

### 4.3 Milvus：IVF_PQ / IVF_SQ8

```java
// Milvus Java SDK：索引类型决定量化方式
CreateIndexParam param = CreateIndexParam.newBuilder()
        .withCollectionName("kb_chunk")
        .withFieldName("embedding")
        .withIndexType(IndexType.IVF_PQ)      // 或 IVF_SQ8
        .withMetricType(MetricType.COSINE)
        .withExtraParam("{\"nlist\":4096,\"m\":96,\"nbits\":8}")
        .build();
client.createIndex(param);
```

`nlist` 是聚类簇数（经验值 `4×sqrt(N)`），`m` 是子空间数，`nbits=8` 就是每段 1 字节。**`m` 越大精度越高、内存越大**，`m = d/4` 起步。

### 4.4 Redis Vector Set / pgvector

- **Redis 8 Vector Set**：`VADD` 内置 int8 量化，无需配置，适合"已经在用 Redis、要低延迟"的场景，但不支持自定义 PQ。
- **pgvector**：`halfvec`（2 字节/维）、`bit`（1 bit/维）、`sparsevec`。它的优势是"和业务数据同库、事务一致"，代价是 HNSW 构建慢、内存控制粗。

---

## 五、怎么证明"量化后召回没塌"

这是最容易被跳过、也最容易出事的一步。上了 int8 之后你觉得"看起来还行"，直到某天用户投诉"搜不到我们的产品"。

### 5.1 建黄金集

```java
public record GoldenCase(String query, Set<String> relevantDocIds) {}

// 200~500 条，覆盖：常见 query、长尾 query、多语言、含专有名词、含错别字
List<GoldenCase> golden = loadGoldenSet();
```

标注方式：人工标 + 用 float32 精确检索的 top 50 做候选池（省力且不会漏太多）。

### 5.2 算指标

```java
public class QuantizationEvaluator {

    public static double recallAtK(List<String> expected, List<String> actual, int k) {
        Set<String> top = new HashSet<>(actual.subList(0, Math.min(k, actual.size())));
        long hit = expected.stream().filter(top::contains).count();
        return expected.isEmpty() ? 0 : (double) hit / expected.size();
    }

    public static double mrr(List<String> expected, List<String> actual) {
        for (int i = 0; i < actual.size(); i++) {
            if (expected.contains(actual.get(i))) {
                return 1.0 / (i + 1);
            }
        }
        return 0;
    }

    /** 对照实验：同一批 query，分别打 float32 索引和量化索引 */
    public Report compare(VectorIndex exact, VectorIndex quantized, List<GoldenCase> golden) {
        double r10 = 0, r50 = 0, mrr = 0;
        for (GoldenCase c : golden) {
            List<String> a = exact.search(c.query(), 50);
            List<String> b = quantized.search(c.query(), 50);
            r10 += recallAtK(a.subList(0, 10), b.subList(0, 10), 10);  // 以精确 top10 为基准
            r50 += recallAtK(a, b, 50);
            mrr += mrr(a, b);
        }
        int n = golden.size();
        return new Report(r10 / n, r50 / n, mrr / n);
    }
}
```

**判读标准**（经验值，按业务调）：

| 指标 | 可接受 | 需要调参 | 不可上线 |
|---|---|---|---|
| recall@10 相对损失 | < 2% | 2%~5% | > 5% |
| recall@50 相对损失 | < 1% | 1%~3% | > 3% |
| MRR 相对损失 | < 3% | 3%~8% | > 8% |
| P99 延迟 | 不升反降（加分） | +20% 内 | +50% 以上 |

**注意**：这里的 recall 是"量化索引 vs 精确索引"的**一致性**，不是业务准确率。业务侧还要看端到端（检索 + 重排 + LLM 回答）的效果，但那是另一层评测。

### 5.3 一个必须做的对照

**同一条 query，同时打两套索引，把 top 10 并排打出来人工看。** 数字会骗人（比如黄金集太"常见"，量化对常见 query 几乎无损，但对长尾 query 损失巨大）。人工看 30 条长尾 query 的差异，比算 500 条的平均值更能发现问题。

---

## 六、五个生产踩坑

**① 归一化之后再 SQ，和先 SQ 再归一化，结果差很多**
余弦相似度场景下，向量必须**先归一化再量化**。否则 SQ 的线性映射会把"长度差异"和"方向差异"混在一起，量化误差被放大。这条几乎没人写在文档里，但踩了就是 5% 的召回损失。

**② int8 点击和会溢出**
`int8 × int8` 的累加在 1536 维下能到 `255×255×1536 ≈ 10^8`，超过 int32 上限（2.1×10^9）虽然没到，但中间实现如果用 int16 就炸了。**自己写量化检索时，累加器必须用 int32 或 float**。

**③ BQ 只适合"第一轮粗排"**
别指望 BQ 单独给出最终 top 10。它的召回曲线在 top 50 之后才接近饱和，所以 `oversample` 必须给足（5~10 倍），且必须重排。

**④ 码本会"过期"**
PQ 的 k-means 码本是用训练集学的。如果线上 embedding 模型换了（哪怕只是升级小版本），或者数据分布漂移（比如新增了一个语种的文档），码本就不再匹配，召回悄悄下降。**换 embedding 模型必须重建索引**，没有例外。

**⑤ 量化省的是内存，不是构建时间**
建 PQ 索引要先跑 k-means（`nlist` 个簇 × `m` 段），1000 万条数据可能要几十分钟到几小时。而且 `ef_construction` 越大建得越慢。**上线窗口要按"重建全量索引"来排，而不是"增量更新"**。

---

## 七、决策树：我该选哪种

```
状态规模？
├─ < 100 万 → float16 或 SQ int8，别折腾 PQ
├─ 100 万 ~ 1000 万
│   ├─ 内存充足(≥ 32G/节点) → SQ int8 + rescore
│   └─ 内存紧张 → OPQ + PQ 或 BQ + rescore
└─ > 1000 万
    ├─ 延迟敏感(QPS 高) → BQ + oversample + rescore（或 ES bbq_disk）
    └─ 精度敏感 → OPQ + PQ + 原始向量落盘重排
```

再加三条通用建议：

1. **先上 float16**。大部分场景 2× 免费压缩、零召回损失，很多人直接跳过这一步去搞 PQ，属于过度工程。
2. **能用向量库内置的就别自己写**。ES/Qdrant/Milvus 的量化实现都经过大规模验证，自己写 int8 点积很容易在边界上出错。
3. **永远保留一份 float32 原件**（磁盘/mmap 都行）。没有原件就无法重排、无法重建索引、无法做 A/B。

---

## 八、面试常见追问

**Q1：PQ 为什么能同时省内存和加速？**
A：省内存是因为每个向量只存 `m` 字节的簇索引（码本本身只有 `m × 256 × (d/m) × 4` 字节，与 N 无关）。加速是因为距离计算从"`d` 次乘加"变成"`m` 次查表加法"——query 到 256 个中心的距离可以预计算成表，之后每个候选只是 `m` 次内存查表 + 整数加法。这是典型的"用空间换时间"的对称设计。

**Q2：SQ 的 `quantile` 参数为什么重要？**
A：SQ 是逐维线性映射，`min/max` 决定了映射区间。如果某一维有一个极端离群值，`max` 会被拉得很远，其余 99.99% 的值就被压缩到很窄的量化桶里，精度暴跌。用 0.99 分位裁剪，牺牲 1% 的极端值精度，换取 99% 数据的精度——这是标准的鲁棒性取舍。

**Q3：BQ 召回那么差，为什么生产上还在用？**
A：因为它把"扫描成本"降了一个数量级。Hamming 距离用 popcount 一条指令算 64 维，比 float32 点积快 10 倍以上，内存只有 1/32。所以你可以用 BQ 扫**更多**候选（oversample 10 倍），再用原始向量精排，端到端效果往往优于"float32 只扫少量候选"。**它不是"更差的索引"，而是"不同阶段的索引"**。

**Q4：换了 embedding 模型，索引必须重建吗？**
A：必须。不同模型的向量空间不可比（维度可能相同但语义坐标完全不同），而且 PQ 的码本、SQ 的 min/max 都是基于旧分布学的。混用会导致"看起来能搜，但结果莫名其妙"。重建时要双写过渡：新索引建好 → 影子流量比对 → 切流 → 保留旧索引一周。

**Q5：量化会不会影响 RAG 的最终答案质量？**
A：会，但传导是非线性的。召回损失 2% 时答案质量几乎无感；召回损失 8% 时，你会发现"偶尔答非所问"，而且**很难归因**（用户以为模型不行，其实是没检索到）。所以量化上线必须配**检索层监控**：top1 分数分布、召回文档数、空结果率、以及定期的黄金集回归。只看 LLM 侧指标是查不出来的。

---

## 九、总结

- 向量成本是物理问题：`N × d × 4` 字节，一千万条 1536 维就是 61GB，不量化做不了。
- **SQ int8 是默认答案**（4×、召回损失 1% 级），先上它，别一上来就 PQ。
- PQ 省到 64×，代价是段内相关性丢失，必须配 OPQ；BQ 省到 32×，但必须配 oversample + rescore。
- 生产标配是"**量化粗排 + 原始向量精排**"，两者缺一不可。
- 上量化前必须建黄金集做 A/B，看 recall@10/@50 与 MRR 的相对损失，并人工抽查长尾 query。
- 归一化顺序、int8 累加溢出、码本过期、重建时间这四件事，是最常见的翻车点。

一句话：**量化的本质不是"压缩数据"，是"用可控的精度损失换可规模化的成本曲线"。** 你必须在做之前就知道自己愿意损失多少、怎么验证损失没超。
