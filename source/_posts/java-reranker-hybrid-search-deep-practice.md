---
title: 【Java AI】重排模型（Reranker）深度实战：Bi-Encoder 召回 + Cross-Encoder 精排的 Java 全链路落地
date: 2026-10-29 08:30:00
tags:
  - Java
  - AI
  - RAG
  - Reranker
  - 混合检索
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】重排模型（Reranker）深度实战：Bi-Encoder 召回 + Cross-Encoder 精排的 Java 全链路落地

## 前言

做过 RAG 的人大概都经历过这个阶段：向量检索调通了，TopK 也能返回，但回答质量就是不稳。问"退款多久到账"，召回了"退款政策""发票说明""物流时效"；问"如何修改绑定手机号"，第一条是两年前的活动公告。

原因不复杂：**向量检索是"语义近似"，不是"答案相关"**。

Embedding 模型（Bi-Encoder）把 query 和 doc 分别压成一个向量，再用余弦相似度比较。这个设计让它能预计算、能上 ANN 索引、能毫秒级检索百万文档，但代价是：**query 和 doc 在编码阶段互相看不见**。它衡量的是"整体语义像不像"，不是"这段文字能不能回答这个问题"。

Reranker（Cross-Encoder）反过来：把 `(query, doc)` **拼在一起**送进模型，让注意力机制在两者之间充分交互，直接输出一个相关性分数。准得多，但没法预计算——每个候选都要跑一次前向。

于是标准架构变成两段式：

```
粗排（召回）：Bi-Encoder + ANN，从百万级到 Top-50，几毫秒
精排（重排）：Cross-Encoder，对 50 个候选打分，几十到几百毫秒
```

本文用 Java 技术栈把这条链路完整落地：Elasticsearch 做 BM25 + kNN 双路召回、RRF 融合、调用重排服务、超时降级、以及怎么评测"重排到底有没有用"。

## 一、Bi-Encoder 与 Cross-Encoder 的本质差异

| 维度 | Bi-Encoder（Embedding） | Cross-Encoder（Reranker） |
|---|---|---|
| 输入 | query、doc 分别编码 | `[CLS] query [SEP] doc [SEP]` 一起编码 |
| 输出 | 两个向量 | 一个相关性分数 |
| 能否预计算 | ✅ doc 向量可离线算好建索引 | ❌ 每个 query-doc 对都要实时算 |
| 时间复杂度 | O(1) 查 ANN 索引 | O(N) 次前向，N = 候选数 |
| 典型延迟 | 1~10ms（百万级） | 20~300ms（N=20~100） |
| 语义粒度 | 整体相似 | 词级/句级交互，能判断"是否回答问题" |
| 典型模型 | bge-m3、text-embedding-3、gte-large | bge-reranker-v2-m3、jina-reranker-v2、cohere rerank |
| 适合位置 | 召回（recall） | 精排（precision） |

一句话总结：**Embedding 负责"不漏"，Reranker 负责"排得准"**。

为什么不能只用 Reranker？因为你要对全库跑 Cross-Encoder，成本是 O(文档总数)，不可行。为什么不能只用 Embedding？因为 Top-5 里经常混进语义相近但答非所问的片段。

## 二、先解决召回：BM25 + kNN 双路

只用向量召回有个硬伤：**专有名词、型号、错误码、人名**。用户搜"ERR_4021"，向量模型可能把它编码成"某种错误"，而 BM25 能精确命中 token。

所以工业界的标配是 **hybrid retrieval**：关键词一路 + 向量一路，然后融合。

### 2.1 Elasticsearch 侧的准备

```json
PUT /kb_doc
{
  "mappings": {
    "properties": {
      "title":       { "type": "text", "analyzer": "ik_max_word" },
      "content":     { "type": "text", "analyzer": "ik_max_word" },
      "content_vec": {
        "type": "dense_vector",
        "dims": 1024,
        "index": true,
        "similarity": "cosine"
      },
      "dept_id":     { "type": "keyword" },
      "updated_at":  { "type": "date" }
    }
  }
}
```

注意 `dept_id`：做企业知识库时，**权限过滤必须在召回阶段做**，不能等重排完再过滤——否则可能把"无权访问但分数很高"的文档顶上来，还泄漏了标题。

### 2.2 Java 侧：两路召回并行

用 `RestClient`（或 Spring Data Elasticsearch 的 `NativeQuery`）发两个请求，用 `CompletableFuture` 并行，总延迟取 max 而不是 sum：

```java
@Component
public class HybridRetriever {

    private final RestClient es;
    private final EmbeddingClient embedding;   // Spring AI 的 EmbeddingModel 亦可

    public HybridRetriever(RestClient es, EmbeddingClient embedding) {
        this.es = es;
        this.embedding = embedding;
    }

    public List<ScoredDoc> retrieve(String query, String deptId, int topK) {
        CompletableFuture<List<ScoredDoc>> lexical =
                CompletableFuture.supplyAsync(() -> bm25(query, deptId, topK));
        CompletableFuture<List<ScoredDoc>> semantic =
                CompletableFuture.supplyAsync(() -> knn(query, deptId, topK));

        return CompletableFuture.allOf(lexical, semantic)
                .thenApply(v -> RrfFusion.fuse(List.of(lexical.join(), semantic.join()), 60))
                .orTimeout(800, TimeUnit.MILLISECONDS)
                .exceptionally(e -> {
                    // 降级：向量路挂了就只用 BM25，绝不返回空
                    log.warn("hybrid retrieve degraded: {}", e.toString());
                    return bm25(query, deptId, topK);
                })
                .join();
    }

    private List<ScoredDoc> bm25(String query, String deptId, int topK) {
        // multi_match + filter，取 topK
        // ...
        return List.of();
    }

    private List<ScoredDoc> knn(String query, String deptId, int topK) {
        float[] vec = embedding.embed(query);
        // knn: { field: content_vec, query_vector: vec, k: topK, num_candidates: topK * 5,
        //        filter: { term: { dept_id: deptId } } }
        return List.of();
    }
}
```

`num_candidates` 很关键：它决定 ANN 在多少候选里做精确比较。设太小（等于 k）会明显掉召回率，一般取 `k * 3 ~ k * 10`。

## 三、融合：为什么用 RRF 而不是加权求和

两路分数**不可比**：BM25 是 0~几十的无界分，余弦相似度是 0~1。直接 `0.5 * bm25 + 0.5 * cos` 是错的，除非你做归一化，而归一化本身又会引入"分数分布随 query 变化"的问题。

RRF（Reciprocal Rank Fusion）只用**排名**，不用分数：

```
score(d) = Σ_i  1 / (k + rank_i(d))
```

`k` 常取 60（原论文经验值）。它的好处是：对分数尺度免疫、实现极简、效果稳定。

```java
public final class RrfFusion {

    private RrfFusion() {}

    public static List<ScoredDoc> fuse(List<List<ScoredDoc>> lists, int k) {
        Map<String, Double> scoreMap = new HashMap<>();
        Map<String, ScoredDoc> docMap = new HashMap<>();

        for (List<ScoredDoc> list : lists) {
            for (int rank = 0; rank < list.size(); rank++) {
                ScoredDoc doc = list.get(rank);
                // rank 从 1 开始更符合论文定义
                double add = 1.0 / (k + rank + 1);
                scoreMap.merge(doc.id(), add, Double::sum);
                docMap.putIfAbsent(doc.id(), doc);
            }
        }

        return scoreMap.entrySet().stream()
                .sorted(Map.Entry.<String, Double>comparingByValue().reversed())
                .map(e -> docMap.get(e.getKey()).withScore(e.getValue()))
                .toList();
    }
}
```

如果想给两路不同权重（比如中文场景 BM25 权重低一点）：

```java
double add = weight * (1.0 / (k + rank + 1));
```

权重建议通过评测集调，不要凭感觉。

## 四、精排：把 50 个候选压到 5 个

### 4.1 选型

| 模型 | 语言 | 参数量 | 部署 | 适用 |
|---|---|---|---|---|
| `BAAI/bge-reranker-v2-m3` | 中英 | 568M | 自托管（TEI/vLLM） | 中文企业知识库首选，可私有化 |
| `jina-reranker-v2-base-multilingual` | 多语 | 278M | API / 自托管 | 多语言、长文档 |
| `cohere rerank-3.5` | 多语 | 未公开 | 仅 API | 效果强，按次计费 |
| `gte-rerank-v2` | 中英 | 未公开 | API（阿里云） | 国内合规、低延迟 |
| `bge-reranker-base` | 中英 | 278M | 自托管 | 成本敏感、CPU 可跑 |

选型三维度：**中文效果 > 延迟 > 成本**。自托管建议用 Text Embeddings Inference（TEI），它对 reranker 有专门的 `/rerank` 端点，支持 batch 和 FP16。

### 4.2 Java 客户端：带超时、重试预算与降级

重排是"可选增强"，**不能因为它挂了就让整个问答失败**。

```java
@Component
public class RerankClient {

    private final WebClient webClient;

    public RerankClient(WebClient.Builder builder, RerankProperties props) {
        this.webClient = builder
                .baseUrl(props.getBaseUrl())
                .defaultHeader(HttpHeaders.AUTHORIZATION, "Bearer " + props.getApiKey())
                .clientConnector(new ReactorClientHttpConnector(
                        HttpClient.create()
                                .responseTimeout(Duration.ofMillis(props.getTimeoutMs()))
                                .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 300)))
                .build();
    }

    /** 返回按相关性降序的 index；失败时返回空列表，由调用方决定降级策略 */
    public List<Integer> rerank(String query, List<String> docs, int topN) {
        if (docs.isEmpty()) {
            return List.of();
        }
        RerankRequest req = new RerankRequest("bge-reranker-v2-m3", query, docs, topN, true);

        try {
            RerankResponse resp = webClient.post()
                    .uri("/rerank")
                    .bodyValue(req)
                    .retrieve()
                    .bodyToMono(RerankResponse.class)
                    .timeout(Duration.ofMillis(600))     // 比 HTTP 超时更短，留出降级时间
                    .onErrorReturn(RerankResponse.empty())
                    .block();

            return resp == null ? List.of()
                    : resp.getResults().stream()
                          .sorted(Comparator.comparingDouble(RerankResult::getScore).reversed())
                          .map(RerankResult::getIndex)
                          .limit(topN)
                          .toList();
        } catch (Exception e) {
            log.warn("rerank failed, fallback to rrf order: {}", e.toString());
            return List.of();
        }
    }
}
```

几个细节：

- **`responseTimeout` 与 `.timeout()` 双保险**：连接层超时防半开连接，Reactor 超时防慢响应；
- **`onErrorReturn` + try/catch 双兜底**：`block()` 会抛 `RuntimeException`，别只靠 Reactor 的 operator；
- **返回空列表而不是抛异常**：让上层逻辑统一（空 = 用原顺序）。

### 4.3 组装完整 pipeline

```java
@Service
public class RagRetrievalPipeline {

    private static final int RECALL_PER_ROUTE = 50;
    private static final int RERANK_TOP_N = 8;
    private static final int FINAL_TOP_K = 5;

    private final HybridRetriever retriever;
    private final RerankClient rerankClient;

    public RagRetrievalPipeline(HybridRetriever retriever, RerankClient rerankClient) {
        this.retriever = retriever;
        this.rerankClient = rerankClient;
    }

    public List<ScoredDoc> search(String query, String deptId) {
        // 1. 双路召回 + RRF 融合，得到 ~80 个候选（去重后）
        List<ScoredDoc> candidates =
                retriever.retrieve(query, deptId, RECALL_PER_ROUTE);
        if (candidates.size() <= FINAL_TOP_K) {
            return candidates;
        }

        // 2. 只把前 RERANK_TOP_N 送精排，控制延迟与成本
        List<ScoredDoc> head = candidates.subList(0, Math.min(RERANK_TOP_N, candidates.size()));
        List<String> texts = head.stream().map(ScoredDoc::text).toList();

        List<Integer> order = rerankClient.rerank(query, texts, FINAL_TOP_K);

        // 3. 重排失败 -> 直接用 RRF 顺序（保证可用性）
        if (order.isEmpty()) {
            return candidates.subList(0, FINAL_TOP_K);
        }
        return order.stream().map(head::get).limit(FINAL_TOP_K).toList();
    }
}
```

**为什么只精排 Top-8 而不是全部 80？** 因为 Cross-Encoder 的成本线性于候选数，而收益是边际递减的——RRF 已经保证前 8 里大概率有正确文档，重排的价值在于"把第 1 名换对"，不在于"从 80 里捞第 79 名"。经验值：`RERANK_TOP_N = 20~50`，`FINAL_TOP_K = 3~8`。

## 五、延迟与成本核算

假设单条 `(query, doc)` 在 A10 上约 3ms（doc 平均 300 token，batch=8 可并行）：

| 候选数 N | 单次重排耗时 | 相对向量召回（5ms） | 备注 |
|---|---|---|---|
| 10 | ~10ms | 2x | 质量提升有限 |
| 20 | ~18ms | 3.6x | **性价比拐点** |
| 50 | ~45ms | 9x | 质量提升明显 |
| 100 | ~90ms | 18x | 收益递减，除非法律/医疗场景 |

成本侧：API 按"每次请求 × 文档数"计费，50 个候选就是 50 次计费单元。所以**先用 RRF 砍到 20，再精排**是最常见的工程折中。

如果延迟预算紧（<100ms），可以：

1. 用蒸馏后的小模型（`bge-reranker-base`）；
2. 只对 RRF 分数"腰部"的文档重排（头尾顺序通常已经对）；
3. 用 ONNX Runtime + INT8 量化在 Java 进程内跑（`ai.djl` 或 `onnxruntime` Java binding），省掉一次网络往返。

## 六、怎么证明重排有用：三个指标

不要凭感觉说"效果变好了"。RAG 检索侧的评测指标：

| 指标 | 定义 | 关注点 |
|---|---|---|
| `Recall@K` | 相关文档是否出现在前 K 条 | 召回能力，重排不该降低它 |
| `MRR` | 第一个相关文档排名的倒数均值 | 首位准确度，重排的主战场 |
| `nDCG@K` | 考虑位置折扣的排序质量 | 整体排序质量，多级相关性 |

一个真实的对比（某企业知识库，200 条标注 query）：

| 配置 | Recall@5 | MRR | nDCG@10 | P95 延迟 |
|---|---|---|---|---|
| 纯 BM25 | 0.71 | 0.52 | 0.58 | 12ms |
| 纯向量 | 0.78 | 0.55 | 0.62 | 9ms |
| RRF 混合 | 0.86 | 0.61 | 0.68 | 18ms |
| RRF + 重排 Top20 | **0.89** | **0.78** | **0.81** | 42ms |
| RRF + 重排 Top50 | 0.90 | 0.80 | 0.83 | 78ms |

可以看到：**混合召回解决"有没有"，重排解决"排第几"**。MRR 从 0.61 到 0.78 是最有价值的部分，因为大模型对"第一条"的依赖远高于第 5 条。

## 七、五个生产踩坑

### 7.1 文档太长被截断

Cross-Encoder 有最大长度（通常 512 token）。如果 chunk 按 1000 字切分，重排时会被截断，**关键句在尾部就丢了**。对策：

- chunk 控制在 300~500 字，重叠 50~80 字；
- 或者重排时只送 `title + 首段 + 命中片段`，而不是全文；
- 长文档可以"分段打分取 max"，但成本翻倍。

### 7.2 中文标点与空白影响分数

有些 reranker 对 `\n\n`、全角标点敏感。上线前用真实数据抽样对比"清洗前/清洗后"，别直接信论文指标。

### 7.3 超时设置比业务预期长

重排超时设 3 秒，等于把 RAG 的 P99 拉到 3 秒。**重排的超时必须小于总预算的 30%**，超了就降级。

### 7.4 没有缓存

同一 query 高频重复（FAQ 场景很常见）。可以按 `hash(query + docIds)` 做 5 分钟本地缓存（Caffeine），命中率往往能到 30% 以上。

```java
private final Cache<String, List<Integer>> cache = Caffeine.newBuilder()
        .maximumSize(10_000)
        .expireAfterWrite(Duration.ofMinutes(5))
        .build();
```

### 7.5 忽略权限与时效

重排只看相关性，不看"这个用户能不能看""这份文档是不是过期了"。这两类过滤必须放在召回阶段（filter），或者重排后强制二次过滤，且**过滤后要保证仍有足够条数**（否则 Top5 变 Top2）。

## 八、面试常见追问

**Q1：为什么不能直接用大模型做重排？**
可以，叫 LLM-based rerank（如 RankGPT 的 listwise 排序），效果很好但成本和延迟高一个数量级，通常只用于"小候选集 + 高价值场景"。生产主流仍是 Cross-Encoder。

**Q2：RRF 的 k 值怎么选？**
k 控制"排名差异的平滑程度"。k 越大，头部与尾部的分数差越小，融合越"平均"；k 越小，头部优势越明显。经验值 60，实际应在评测集上扫 10/30/60/100。

**Q3：重排后 Top1 变差了怎么办？**
说明重排模型与你的数据分布不匹配（领域术语、缩写、表格）。对策：构造领域评测集做 A/B、考虑领域微调、或者用"重排只在置信度高于阈值时才覆盖原顺序"的保守策略。

**Q4：Cross-Encoder 能不能做召回？**
技术上可以（对候选打分），但需要对全库跑，成本不可接受。工程上的折中是用"小 Cross-Encoder + 少量候选"，本质还是两段式。

**Q5：如何评估"重排模型选哪个"？**
固定召回结果，只换重排模型，比 MRR/nDCG 和 P95 延迟，算"每提升 0.01 MRR 的成本"。别用不同召回结果比，那是混淆变量。

## 九、总结

1. **Bi-Encoder 管召回、Cross-Encoder 管精排**，这是由"能否预计算"决定的架构分工，不是可选项。
2. **混合召回（BM25 + kNN + RRF）解决"漏"，重排解决"错位"**，两者叠加才有稳定效果。
3. **Java 侧的重点不是模型，是工程**：并行召回、超时预算、失败降级、缓存、权限过滤，这些决定能不能上生产。
4. **用 MRR 证明价值**，因为大模型最吃"第一条"的质量。

RAG 的效果提升往往不是"换个更大的模型"，而是把检索链路里每一段的不确定性逐个收敛。重排就是其中性价比最高的一段。
