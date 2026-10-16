---
title: 【RAG 实战】RAG 全链路深度实战：切分、Embedding、混合检索与重排
date: 2026-10-16 08:10:00
tags:
  - AI
  - RAG
  - 检索增强
  - Embedding
  - 向量检索
categories:
  - AI 工程
author: 东哥
---

# 【RAG 实战】RAG 全链路深度实战：切分、Embedding、混合检索与重排

## 前言

RAG（Retrieval-Augmented Generation，检索增强生成）是当前企业落地大模型**最主流、性价比最高**的范式：不改模型权重，用"外挂知识库"解决幻觉、时效和专业领域问题。

但很多人做出来的 RAG"能跑不能打"：检索召回不到、召回了但不相关、相关了但答非所问。问题几乎都出在**链路的某一环被想当然地跳过了**。本文把 RAG 拆成 **7 个环节**，逐一讲清楚「关键决策 + 参数 + 评估 + 踩坑」，并给出 Java（Spring AI / 向量库）落地要点。

## 一、RAG 全链路总览

```
文档源 → ①解析(Parse) → ②切分(Chunk) → ③向量化(Embed) → ④入库(Index)
                                                            ↓
用户 Query → ⑤查询改写(Rewrite) → ⑥检索(Retrieve: 向量+BM25) → 重排(Rerank,可选)
                                                            ↓
                                      ⑦上下文组装(Prompt) → LLM 生成(带引用)
```

每一环都有"看起来能用"的默认实现，也都有**决定成败的细节**。下面逐个说。

## 二、① 文档解析：脏数据从这里开始

- PDF：`Apache PDFBox` / `poppler`；**扫描件要 OCR**（Tesseract/PaddleOCR），否则拿到空文本。
- Word/Excel：`Apache POI`；表格要**转成 Markdown 或段落**，别丢结构。
- HTML：`jsoup`（清洗正文）；PPT：优先级低但常被忽略。
- **坑**：页眉页脚、页码、重复标题会成为噪声；表格跨页会断裂；解析后务必**清洗**（去空白、去页眉、合并断行）。

## 三、② 切分（Chunking）：RAG 的头号胜负手

**切分本质是在"信息完整度"和"检索精度"之间找平衡**：块太大 → 噪声多、命中不准、token 贵；块太小 → 语义不完整、答不上。

| 策略 | 做法 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| 固定长度 | 按 token/字符切 | 简单可控 | 断句、断语义 | 兜底 |
| 递归切分 | 按 段落→句→词 逐级切 | 尽量不破句 | 仍可能断语义 | **通用首选** |
| 结构化切分 | 按 Markdown 标题/代码块 | 保留结构 | 依赖文档规范 | 技术文档 |
| 语义切分 | 用 Embedding 相似度找断裂点 | 语义完整 | 慢、贵 | 高价值语料 |
| 父子切分 | 小块检索、大块喂 LLM | 检索准 + 上下文全 | 实现复杂 | **推荐进阶** |
| 句子窗口 | 检索单句，回带前后窗口 | 精准命中 | 需存偏移 | 问答密集场景 |

**参数经验**：

- 块大小（chunk size）：**256~512 token** 起步（中文约 200~400 字）；技术文档可到 800~1000。
- 重叠（overlap）：**10%~20%**，防止答案正好被切断。
- **父子切分**：检索用小块（如 128 token）提高精度，喂给 LLM 用其父块（如 1024 token）保证上下文完整——这是目前性价比很高的一招。

```java
// Spring AI TokenTextSplitter 示例
var splitter = new TokenTextSplitter(
        /* defaultChunkSize */ 400,
        /* minChunkSizeChars */ 100,
        /* minChunkLengthToEmbed */ 5,
        /* maxNumChunks */ 10000,
        /* keepSeparator */ true);
List<Document> chunks = splitter.apply(List.of(new Document(rawText)));
```

**坑**：Markdown 表格/代码块被切碎 → 检索到"半个表"；解决办法是**按结构优先，再做长度兜底**。

## 四、③ Embedding 选型：决定召回的"天花板"

| 模型类型 | 代表 | 维度 | 说明 |
|---|---|---|---|
| 通用多语言 | BGE-M3、text-embedding-3-large | 1024~3072 | 中文效果好、支持多语言 |
| 中文优化 | BGE-large-zh、m3e | 768~1024 | 中文检索首选之一 |
| 轻量本地 | all-MiniLM、bge-small | 384 | 可本地跑、省成本 |
| API | OpenAI/通义/智谱 embedding | 1536+ | 免运维、按量付费 |

**关键决策**：

- **维度不是越高越好**：3072 维存储/计算成本翻倍，收益可能只有几个百分点。
- **对称/非对称**：query 和 doc 用**同一模型**；有的模型（如 BGE）建议 query 加指令前缀（"为这个句子生成表示以用于检索相关文章："），不加会掉点。
- **归一化**：用**余弦相似度**（归一化后等价内积），别用欧氏距离，除非模型要求。
- **一致性铁律**：入库和查询**必须同一个模型、同版本**——换模型要**全量重建**索引。

## 五、④ 向量库选型（Java 客户端视角）

| 向量库 | Java 客户端 | 特点 | 适用 |
|---|---|---|---|
| pgvector | JDBC | 复用 PG、运维简单 | 中小规模、已用 PG |
| Elasticsearch kNN | RestClient | 全文+向量一体、生态强 | 混合检索首选 |
| Milvus | milvus-sdk-java | 性能强、分布式 | 亿级向量 |
| Qdrant | qdrant-java-client | 过滤强、易用 | 中大规模 |
| Redis Vector | Jedis/Lettuce | 内存、低延迟 | 小规模、实时 |
| 内存 | SimpleVectorStore | 零依赖 | 原型/测试 |

**选型心法**：**先看"能不能做混合检索（向量+关键词）"和"过滤能力（metadata filter）"**，这两点比裸性能更重要——因为纯向量检索在企业里几乎不够用，权限隔离、多租户全靠 metadata filter。

## 六、⑤ 查询改写 + ⑥ 检索 + 重排：召回质量的放大器

**查询改写**：用户问题往往口语化、缺上下文。手段：

- **多查询（Multi-Query）**：让 LLM 生成 3~5 个同义/不同角度的问题，分别检索再合并。
- **HyDE**：先让 LLM 生成一个"假想答案"，用假想答案去检索（答案和文档更同分布）。
- **对话改写**：多轮对话里把"它多少钱"改写成"iPhone 16 Pro 多少钱"，否则检索必然跑偏。

**混合检索（Hybrid）**：向量检索擅长语义，BM25 擅长关键词/专有名词/代码。用 **RRF（Reciprocal Rank Fusion）** 融合：

```
RRF_score(d) = Σ 1 / (k + rank_i(d))     // k 常取 60
```

**重排（Rerank）**：检索是"粗排"（快、但准度有限），用 **Cross-Encoder Reranker**（bge-reranker、Cohere Rerank）对候选做精排——它同时看 query 和 doc，准度远高于向量内积。

```java
// 伪代码：两阶段检索
var candidates = hybridSearch(query, topK = 50);   // 向量 top20 + BM25 top20，RRF 融合
var reranked   = reranker.rerank(query, candidates, topN = 5); // 精排取前 5
String context = reranked.stream().map(Document::getText)
                        .collect(Collectors.joining("\n---\n"));
```

**经验结论**：加 Reranker 通常是**性价比最高的一次改造**，能让"召回里没答案"变成"答案稳定进 top3"。

## 七、⑦ 上下文组装与生成：别让 LLM 自由发挥

Prompt 模板要素：

```
你是一个严谨的问答助手。只能依据【参考资料】回答。
若资料中没有答案，请回答"资料中未提及"，禁止编造。
引用时标注 [序号]。

【参考资料】
[1] ...
[2] ...

【用户问题】...
```

- **强制引用 + 拒答**：这是抑制幻觉的关键，也是"可溯源"的基础。
- **排序**：把**最相关的放最前或最后**（LLM 有"中间遗忘"）。
- **去重**：检索多个视角会带回重复块，先按内容 hash 去重再拼。
- **长度控制**：控制总 token（见上一篇 Token 管理），超了先砍低分块。

## 八、RAG 评估：怎么知道你做得好不好

没有评估的 RAG 就是玄学。核心指标（RAGAS 体系）：

| 指标 | 含义 |
|---|---|
| Context Recall | 检索到的上下文是否覆盖了标准答案所需信息 |
| Context Precision | 检索结果里相关块的排序质量 |
| Faithfulness | 生成答案是否忠于上下文（防幻觉） |
| Answer Relevancy | 答案是否切题 |

**做法**：建 **50~200 条黄金问答集**（问题 + 标准答案 + 标注来源），每次改动跑一遍回归，盯这四个指标 + 成本 + 延迟。**没有黄金集的优化就是瞎调参**。

## 九、常见踩坑清单

1. **切分太碎**导致"检索到半句" → 用父子切分/加大 overlap。
2. **只做向量检索**，专有名词/编号召回差 → 上混合检索。
3. **没做查询改写**，多轮对话检索跑偏 → 加对话改写。
4. **换了 Embedding 模型但没重建索引** → 新旧向量空间不匹配，召回崩。
5. **chunk 里没存 metadata**（来源、页号、权限）→ 无法引用溯源、无法做权限隔离。
6. **把 RAG 当万能**：需要"推理/计算/多步"的问题 RAG 解决不了 → 该上 Agent 工具调用。
7. **没评估**：改了切分参数全凭感觉。

## 总结

RAG 的七环里，**切分与检索（含重排）决定 80% 的效果**，Embedding 选型决定天花板，Prompt 与拒答决定幻觉是否可控。落地顺序建议：**先做基线（递归切分 + 单向量检索） → 建黄金集评估 → 加混合检索 + Reranker → 加查询改写 → 考虑父子切分/GraphRAG**。

RAG 是 Java 后端转型 AI 应用开发**最容易上手、最容易出成果**的方向——因为它本质上还是"存储 + 检索 + 编排"的工程问题，正是 Java 工程师的主场。后续会继续写 **RAG 评测（RAGAS）**、**Agentic RAG / GraphRAG**，欢迎关注。
