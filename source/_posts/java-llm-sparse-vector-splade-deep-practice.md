---
title: 【Java AI】稀疏向量检索与 SPLADE 深度实战：学习式稀疏、Impact 打分与 Java 落地
date: 2026-11-09 08:00:00
tags:
  - Java
  - AI
  - RAG
  - SPLADE
  - 稀疏向量
  - Lucene
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】稀疏向量检索与 SPLADE 深度实战

## 前言：向量检索踩的第一个坑，往往是"关键词查不到"

团队做企业知识库，第一版用的是"Dense 向量 + HNSW"，模型选的是当时榜单上很强的中文 Embedding。上线后反馈最多的问题不是"答得不好"，而是**"搜不到"**：

- 用户搜 `ERR_0x80070005`，向量检索返回一堆语义相关但完全不是这个错误码的文档；
- 用户搜 `X200 Pro mini`，返回所有"Pro"系列手机；
- 用户搜 `GB/T 28181-2022`，出来的全是别的国标。

原因很直白：**Dense 向量是把整段文本压成一个语义点，它擅长"意思相近"，天生不擅长"精确匹配"。** 而 Embedding 模型在训练时几乎没见过 `ERR_0x80070005` 这种 token，它的向量表示基本是随机的。

BM25 恰好相反：精确匹配极强，但有词汇鸿沟（用户说"报销流程"，文档写"费用申请审批"）。

**学习式稀疏检索（Learned Sparse Retrieval）就是来缝合这两者的**，代表工作就是 **SPLADE**（SParse Lexical AnD Expansion）。它输出的不是 1024 维稠密浮点，而是**词表维度（3 万+）上的稀疏权重**——形式上像 BM25 的倒排，语义上又带上了 BERT 的扩展能力。

本文讲清四件事：SPLADE 到底算出了什么、为什么它能用倒排索引高效打分、Java（Lucene / Elasticsearch）怎么落地、以及我们上线后踩的六个坑。

## 一、三种检索范式，先摆清楚

| 范式 | 表示 | 匹配方式 | 强项 | 弱项 |
|---|---|---|---|---|
| 稀疏（BM25） | 词 → tf-idf | 倒排精确匹配 | 关键词、编号、稀有词 | 词汇鸿沟、无同义扩展 |
| 稠密（Dense/双塔） | 定长 float 向量 | ANN（HNSW/IVF） | 语义泛化、跨语言 | 精确匹配差、不可解释 |
| **学习式稀疏（SPLADE）** | **词表维度稀疏权重** | **倒排 + impact 打分** | **两者兼得 + 可解释** | 索引膨胀、需模型推理 |

关键差异一句话：**SPLADE 让"倒排索引"这个三十年前的数据结构，重新获得了语义能力。**

## 二、SPLADE 到底算出了什么

### 2.1 计算过程

给定一段文本，SPLADE 的前向过程是：

```
tokens → BERT → MLM head（词表维度 logits，30k+ 维）
      → ReLU（把负分置零 → 稀疏）
      → log(1 + x)（压缩动态范围）
      → 在所有 token 位置上做 max pooling
      → 得到 30k 维的稀疏权重向量 w
```

三个操作各有明确目的：

- **ReLU**：制造稀疏性。词表里绝大多数词直接置零，不参与索引。
- **`log(1+x)`**：抑制"某个词分数特别高"的支配效应。BM25 里 tf 饱和用的是 `tf/(tf+k)`，这里用对数做类似的事——**避免一个高频词把整篇文档的分数吃满**。
- **Max pooling（而不是 sum）**：同一个词在文档多处出现时取最大值，而不是累加。这保证了"词的重要性"由模型判断，而不是由出现次数决定。

### 2.2 它同时做了两件事：加权 + 扩展

这是 SPLADE 最容易被忽略的地方——**它输出的稀疏向量里，包含原文中根本没出现过的词**。

例子：文档写"手机电池不耐用"，SPLADE 可能输出

```
{"手机": 1.82, "电池": 2.41, "不耐用": 1.55, "续航": 1.97, "耗电": 1.63, "发热": 0.72, ...}
```

其中 `续航`、`耗电`、`发热` 是模型**自动扩展**出来的。这就是它跨越词汇鸿沟的机制：**查询侧和文档侧都被扩展，双方在扩展后的词表空间里相遇。**

查询侧的扩展更明显：用户搜"怎么退钱"，查询向量里会出现 `退款`、`退货`、`售后`，于是能命中写"退款流程"的文档。

### 2.3 稀疏度到底有多稀疏

经验数据（中文/英文接近）：

| 指标 | 典型值 |
|---|---|
| 词表大小 | 30k ~ 50k（BERT 词表） |
| 单文档激活词数 | 80 ~ 300 |
| 单查询激活词数 | 20 ~ 80 |
| 激活词占比 | 0.3% ~ 1% |

对比 Dense：一条 1024 维 float32 向量固定占 4KB，**无论文档长短**；SPLADE 的存储量与激活词数成正比，短文档（标题）可能只有 60 个词，长文档（说明书切片）可能 300+。

所以"稀疏一定比稠密省空间"是错的。1 万篇短标题：SPLADE 约 60 万 posting，比 dense 省；10 万篇长文档切片：3000 万 posting，反而更占空间。**必须按实际语料算账。**

## 三、倒排索引如何高效处理"带权重的词"

传统倒排的打分是 `score = Σ tf × idf × boost`，权重来自统计。SPLADE 的权重来自模型，是一堆浮点数，怎么在倒排上快速算？

答案是 **Impact Scoring（影响力打分）**——每个 posting 除了 docID，还带一个"impact"值（量化后的权重）。打分时把同一个词的 posting list 按 impact **降序**排列，并建立**跳跃表**（skip list）：

```
term "电池": docA(241) → docC(197) → docB(83) → docD(31) → ...
                                        ↑ 从这里开始，后续 impact 总和已不足以进 top10，直接停止
```

这就是 WAND / Block-Max WAND 算法的基础：**利用"上界"提前终止**，只对可能进入 Top-K 的文档做完整打分。Lucene 9 引入的 `ImpactScore` 与 `MaxScoreAccumulator` 就是这套机制，Elasticsearch 的 `rank_features` 底层也走它。

**结论：SPLADE 不是"把稠密向量硬塞进倒排"，而是正好匹配了倒排索引三十年来演进出的 impact 优化路径。**

## 四、Java 落地路线一：Lucene 内嵌（最可控）

如果检索层本来就是自研 Lucene（或者用 Elasticsearch 但想先在本地验证），直接用 `FeatureField`：

```java
// 写入：一个 Document 里放多个 feature，共享一个字段名
Document doc = new Document();
doc.add(new TextField("title", title, Field.Store.YES));
doc.add(new StoredField("doc_id", docId));

for (Map.Entry<String, Float> e : sparse.entrySet()) {
    doc.add(FeatureField.newFeatureField("splade", e.getKey(), e.getValue()));
}
writer.addDocument(doc);
```

```java
// 查询：每个激活词一个 clause，权重用 newLinearQuery 直接乘上去
BooleanQuery.Builder builder = new BooleanQuery.Builder();
for (Map.Entry<String, Float> e : querySparse.entrySet()) {
    builder.add(
        FeatureField.newLinearQuery("splade", e.getKey(), e.getValue()),
        BooleanClause.Occur.SHOULD
    );
}
TopDocs hits = searcher.search(builder.build(), 50);
```

几个实践要点：

- `FeatureField` 默认的字段配置对稀疏特征已经比较友好，**不要**给它加 `TextField` 的分词器逻辑，特征名是"完整词"不是 token 流。
- 权重建议做**上限截断**（比如 clip 到 10.0），否则个别词会支配整个打分。
- 如果追求更贴近论文效果，用 `FeatureField.newSaturationQuery(field, feature, pivot, exp)`，它对高 impact 做饱和处理，避免"单个词命中即第一"。

## 五、Java 落地路线二：Elasticsearch `rank_features`

已经有 ES 集群的团队，这是成本最低的路。Mapping：

```json
PUT /kb_v3
{
  "mappings": {
    "properties": {
      "title":   { "type": "text", "analyzer": "ik_max_word" },
      "content": { "type": "text", "analyzer": "ik_max_word" },
      "splade":  { "type": "rank_features" },
      "doc_id":  { "type": "keyword" }
    }
  }
}
```

写入（`splade` 是一个 `term → weight` 的对象）：

```json
{
  "title": "手机电池不耐用怎么办",
  "content": "...",
  "doc_id": "d-10086",
  "splade": { "手机": 1.82, "电池": 2.41, "续航": 1.97, "耗电": 1.63, "不耐用": 1.55 }
}
```

查询（每个词一个 `term`，权重放 `boost`）：

```json
{
  "query": {
    "bool": {
      "should": [
        { "term": { "splade.手机": { "value": 1, "boost": 1.82 } } },
        { "term": { "splade.电池": { "value": 1, "boost": 2.41 } } },
        { "term": { "splade.续航": { "value": 1, "boost": 1.97 } } }
      ],
      "minimum_should_match": 1
    }
  }
}
```

Java（ES Java API Client 8.x）批量写入：

```java
public BulkResponse indexAll(ElasticsearchClient client, List<Doc> docs) throws IOException {
    BulkRequest.Builder br = new BulkRequest.Builder();
    for (Doc d : docs) {
        Map<String, Float> sparse = encoder.encode(d.title() + " " + d.content());
        br.operations(op -> op.index(idx -> idx
                .index("kb_v3")
                .id(d.id())
                .document(Map.of(
                        "doc_id", d.id(),
                        "title", d.title(),
                        "content", d.content(),
                        "splade", sparse          // Map<String, Float> → rank_features
                ))));
    }
    return client.bulk(br.build());
}
```

> 版本提示：ES 从 8.15 起开始提供原生的 `sparse_vector` 字段类型（走倒排 + impact，不需要每词一个 `term` clause），9.x 进一步成熟。**如果你在 8.15+ / 9.x，优先用原生 `sparse_vector`**，它把"逐词 bool"的查询膨胀问题在内核层解决了；老版本用 `rank_features` 完全够用。上线前务必按自己集群的版本文档核对字段与查询语法。

### 5.1 逐词 clause 的隐患

`rank_features` 方案最大的问题是**查询 DSL 会膨胀**：一个 60 词的查询变成 60 个 `bool.should` clause，而且每个都要走一次 term 查询 + 打分。ES 的 `bool` 有 `max_clause_count`（默认 1024）限制，还好；但 `_score` 计算的 CPU 开销是实打实的。

缓解手段：

1. **查询侧截断**：只取权重 Top-30 的词（长尾词的贡献本来就小）；
2. **权重取整**：`Math.round(w * 100)` 后再除以 100，减少 cache miss（浮点分布更集中）；
3. **两段式**：先用 BM25 召回 200 条，再用 SPLADE 重排这 200 条——把 N 从全库降到 200，代价是召回率受 BM25 限制。

## 六、混合检索：三路召回 + RRF 融合

SPLADE 最实用的定位不是"替代 BM25"或"替代 Dense"，而是**作为第三路召回**：

```
            ┌──────────────┐
Query ──────┤ BM25 召回     │→ top 100 ─┐
            ├──────────────┤           │
            ├─ Dense kNN   │→ top 100 ─┼→ RRF 融合 → Reranker → top 10
            ├──────────────┤           │
            └─ SPLADE      │→ top 100 ─┘
```

RRF（Reciprocal Rank Fusion）的 Java 实现，十几行：

```java
public static List<String> rrf(List<List<String>> rankedLists, int k, int topN) {
    Map<String, Double> score = new HashMap<>();
    for (List<String> list : rankedLists) {
        for (int i = 0; i < list.size(); i++) {
            // k 通常取 60；分母加 1 防止 rank=1 时分母为 0 之外的极端值
            score.merge(list.get(i), 1.0 / (k + i + 1), Double::sum);
        }
    }
    return score.entrySet().stream()
            .sorted(Map.Entry.<String, Double>comparingByValue().reversed())
            .limit(topN)
            .map(Map.Entry::getKey)
            .toList();
}
```

RRF 的好处是**不需要归一化**——BM25 分数可能是 12.7，dense 是 0.83，SPLADE 是 34.2，量纲完全不同，但 RRF 只用排名。这比"调权重把三路分数加起来"稳健得多。

什么时候该用哪一路（我们用 A/B 测试得出的经验）：

| 查询类型 | 最有效的一路 | 说明 |
|---|---|---|
| 错误码、型号、国标编号 | BM25（配合 keyword 精确匹配） | 任何模型都别指望 |
| 口语化问题（"钱怎么退"） | Dense | 语义泛化 |
| 术语不一致（"报销" vs "费用申请"） | **SPLADE** | 学习式扩展的核心场景 |
| 长文档细节检索 | SPLADE + Reranker | 关键词命中率高 |

## 七、评测：别用"感觉"判断 SPLADE 有没有用

上线前必须建评测集，至少 200 条查询 + 人工标注的相关文档。指标：

| 指标 | 含义 | 目标 |
|---|---|---|
| Recall@100 | 召回层天花板 | > 0.90 |
| MRR@10 | 第一个正确结果的排名 | 越高越好 |
| NDCG@10 | 排序质量（含多级相关性） | 相对基线 +5% 才上线 |
| 精确匹配子集 NDCG | 编号/型号类查询 | **不能下降**，这是红线 |

**必须分桶评测**：把查询分成"精确匹配型 / 口语型 / 术语不一致型 / 长尾型"，分别看指标。我们第一版整体 NDCG 只涨了 2.1%，看起来鸡肋；分桶后发现术语不一致型涨了 18%，精确匹配型跌了 3%——加上 BM25 兜底后，整体涨到 11%。

## 八、六个生产踩坑

**坑 1：模型升级导致全量权重漂移。**
换了 SPLADE 模型版本（或者只是换了 tokenizer），权重分布就变了，新旧文档向量不在同一个空间里，检索结果会诡异地下滑。**必须索引版本化**：`kb_v3` / `kb_v4` + 别名切换，绝不能混写同一个索引。

**坑 2：中文分词与词表不匹配。**
BERT 词表里中文是**字级/子词级**，而你想索引的是"续航"这种词。直接拿子词当特征名，会导致 `续`、`航` 分别成特征，语义全丢。解决方案：① 用中文 SPLADE 模型（基于中文 BERT）；② 或者把子词权重聚合到词级（按分词结果求和/取最大）。

**坑 3：长文档不切片。**
一篇 8000 字的手册直接编码，max pooling 后大量词被压平，细节全丢。必须按 300~500 字切片，且**切片之间保留 50 字重叠**，否则边界处的句子检索不到。

**坑 4：以为 SPLADE 能替代精确过滤。**
`ERR_0x80070005` 这类字符串，SPLADE 依然可能扩展出无关的词。**精确匹配类字段必须用 `keyword` + `term` 查询硬过滤/加权，不要交给模型。**

**坑 5：索引体积估算错误导致磁盘打满。**
100 万条切片 × 平均 180 个激活词 ≈ 1.8 亿 posting，加上 term dictionary，实测索引体积约为原始文本的 **1.5~3 倍**。上线前用 10 万条样本实测外推，别拍脑袋。

**坑 6：编码服务成为瓶颈。**
SPLADE 编码比双塔 Embedding 慢（要做 MLM head + pooling），单条 20~50ms（GPU）或 200ms+（CPU）。批量写入 100 万文档时，必须做**批量推理 + 异步流水线**，否则索引重建要跑一整天。Java 侧用虚拟线程并发调用推理服务，配合背压（Semaphore 限并发），比固定线程池更省资源。

## 九、面试追问

**Q1：SPLADE 和 BM25 的本质区别是什么？**
BM25 的权重来自**统计**（tf、idf、文档长度归一），只对"出现过的词"赋权；SPLADE 的权重来自**模型**（BERT 语义 + 词表投影），并且可以对"没出现过的词"赋权（扩展）。前者是词袋统计，后者是学习到的稀疏表示。形式上都是倒排，语义能力不同。

**Q2：为什么用 `log(1+relu(x))` 而不是直接 relu？**
`relu` 之后的值域可能非常大（几十甚至上百），少数词会支配整个打分，且影响量化精度。`log(1+x)` 压缩动态范围，让权重分布更平滑，同时保持单调性（不改变词的重要性排序）。这与 BM25 的 tf 饱和是同一类思想。

**Q3：为什么 max pooling 而不是 sum pooling？**
sum 会让"重复出现的词"占据主导（比如模板化文档里"本公司"出现 50 次），而 max 表达的是"这个 token 位置上对某个词的最大置信度"。max 也更符合"词是否重要"的语义，且对文档长度更鲁棒。

**Q4：稀疏向量在倒排上怎么打分？为什么比暴力扫描快？**
posting list 按 impact 降序 + 跳表，配合 WAND/Block-Max WAND 的上界剪枝：如果当前词剩余 posting 的最大可能贡献加上已有分数都进不了 Top-K，直接跳过整段。这让打分复杂度从 O(匹配文档数) 降到接近 O(Top-K × 词数)。

**Q5：SPLADE 能替代 Dense 吗？**
在 BEIR 等基准上，SPLADE 系列已经接近甚至超过同规模 Dense 模型，尤其在零样本领域外表现更稳。但工程上：① 它依赖词表，跨语言能力弱于多语言 Dense；② 索引比 Dense 大（激活词多时）；③ 不能像 Dense 那样做"图文跨模态"。**结论是互补，不是替代。**

**Q6：如果只能在 BM25 和 SPLADE 里选一个，怎么选？**
看查询分布。如果 80% 是精确匹配（编号、SKU、错误码），BM25 + 精确字段更强且零成本；如果大量是口语化、术语不一致的自然语言问题，SPLADE 收益明显。**真实系统里最优解通常是 BM25 + SPLADE + Dense 三路 + RRF，成本允许的话别做二选一。**

## 十、总结

SPLADE 是近几年 RAG 检索层最值得投入的技术之一，它的价值在于**用倒排索引的成本，拿到了接近稠密向量的语义能力**：

1. **原理**：MLM logits → ReLU → log(1+x) → max pooling，得到词表维度的稀疏权重，同时完成加权与扩展；
2. **打分**：依靠 impact scoring + 跳表剪枝，倒排索引天然适配；
3. **Java 落地**：内嵌 Lucene 用 `FeatureField`，ES 用 `rank_features`（新版本用原生 `sparse_vector`）；
4. **定位**：作为 BM25 / Dense 之外的**第三路召回**，用 RRF 融合，别做单点替代；
5. **上线门槛**：分桶评测 + 索引版本化 + 精确匹配兜底，三者缺一不可。

如果你现在正被"向量检索搜不到关键词"折磨，SPLADE 大概率就是那个补丁——而且它不需要你推翻现有的倒排基础设施。
