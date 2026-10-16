---
title: 【Java AI】Spring AI RAG 深度实战：VectorStore、ETL Pipeline 与检索增强落地
date: 2026-10-15 08:20:00
tags:
  - Java
  - AI
  - Spring AI
  - RAG
  - VectorStore
  - 检索增强
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Spring AI RAG 深度实战：VectorStore、ETL Pipeline 与检索增强落地

## 前言

用 Java 落地 RAG，2024 年之前基本等于"自己拼装"：调 Embedding API、算余弦相似度、手撸召回逻辑。**Spring AI 的价值在于，它把 RAG 拆成了几个可插拔的抽象**——`VectorStore`、`EmbeddingModel`、`DocumentReader/Transformer/Writer`、`Advisor`——让 Java 工程师用 Spring 的惯用方式（依赖注入、自动配置、Advisor 链）把 RAG 拼起来。

本文是「Java × AI 工程落地」系列的一篇，聚焦三件事：

1. **`VectorStore` 抽象**：接口契约、检索参数（topK / threshold / filter）与后端选型；
2. **ETL Pipeline**：文档读取、切分、元数据增强、入库；
3. **Advisor 与检索增强**：从 `QuestionAnswerAdvisor` 到模块化的 `RetrievalAugmentationAdvisor`。

> 前置：本文假设你已了解 RAG 的通用链路（切分、Embedding、向量检索、重排）。如不熟悉，先看本站《RAG 全链路深度实战》。

## 一、Spring AI 的 RAG 组件全景

```
┌──────────────────────────── Spring AI ────────────────────────────┐
│  ChatClient  ──(Advisor)──►  QuestionAnswerAdvisor / RAG Advisor │
│       ▲                                    │                     │
│  ChatModel (OpenAI/Ollama/...)             ▼                     │
│                                       VectorStore                │
│                                      ▲         ▲                 │
│                          EmbeddingModel    (filter / topK)       │
│                                                                   │
│  ETL: DocumentReader ─► DocumentTransformer ─► DocumentWriter ─► VectorStore
└───────────────────────────────────────────────────────────────────┘
```

- **`EmbeddingModel`**：把文本转向量（OpenAI、Ollama、千问、智谱…）；
- **`VectorStore`**：向量的增删查；实现有 `SimpleVectorStore`（内存，演示用）、`PgVectorStore`、`RedisVectorStore`、`ElasticsearchVectorStore`、`MilvusVectorStore`、`ChromaVectorStore`、`QdrantVectorStore` 等；
- **ETL Pipeline**：`DocumentReader` → `DocumentTransformer`（切分/增强）→ `DocumentWriter`；
- **`Advisor`**：Spring AI 1.0 的拦截器抽象，RAG 作为其中一个 Advisor 挂到 `ChatClient` 上。

## 二、VectorStore：RAG 的核心抽象

### 2.1 接口契约

```java
public interface VectorStore extends DocumentWriter {
    void add(List<Document> documents);
    void delete(List<String> idList);
    void delete(Filter.Expression filterExpression);

    // 默认相似度检索
    List<Document> similaritySearch(String query);

    // 显式检索请求
    List<Document> similaritySearch(SearchRequest request);

    default <T> Optional<T> getNativeClient() { return Optional.empty(); }
}
```

`Document` 是统一载体：`id` + `content`（文本）+ `metadata`（Map）+ `embedding`（可选，写回时）。

### 2.2 SearchRequest：检索参数

```java
SearchRequest request = SearchRequest.builder()
        .query("Spring AI 怎么接 PgVector？")
        .topK(5)                                        // 召回条数
        .similarityThreshold(0.7)                       // 相似度阈值（不同实现范围不同）
        .filterExpression("tenant == 'acme' && status == 'PUBLISHED'") // 元数据过滤
        .build();
List<Document> docs = vectorStore.similaritySearch(request);
```

**三个参数是 RAG 效果的主要旋钮**：

| 参数 | 作用 | 调参经验 |
|---|---|---|
| `topK` | 召回数量 | 太小漏，太大噪声多；通常先 4~8，配合重排 |
| `similarityThreshold` | 过滤低分 | 太低引入噪声，太高召回为空；不同后端尺度不同，要实测 |
| `filterExpression` | 元数据过滤 | **多租户/权限隔离的关键**，见下文 |

### 2.3 后端选型

| 后端 | 起步成本 | 适用 | 备注 |
|---|---|---|---|
| `SimpleVectorStore` | 极低 | 演示 / 小数据 | 内存，重启丢失，纯余弦暴力检索 |
| **PgVector** | 低 | 已有 PostgreSQL | 一条 SQL 搞定向量 + 关系过滤，性价比之王 |
| `Elasticsearch` | 中 | 已有 ES / 要混合检索 | BM25 + kNN 混合，中文 IK |
| `Redis` | 低 | 已有 Redis / 低延迟 | 内存快，规模受限 |
| `Milvus` | 高 | 亿级向量 | 专业向量库，运维成本高 |
| `Qdrant` / `Chroma` | 中 | 云原生 / 本地 | 生态活跃 |

**Java 后端最常见的起手式**：已经在用 PostgreSQL 就直接上 PgVector，省一个中间件。

```java
@Bean
VectorStore vectorStore(EmbeddingModel embeddingModel, JdbcTemplate jdbc) {
    return PgVectorStore.builder(jdbc, embeddingModel)
            .dimensions(1536)                 // 必须与 embedding 模型维度一致！
            .distanceType(PgVectorStore.PgDistanceType.COSINE_DISTANCE)
            .indexType(PgVectorStore.PgIndexType.HNSW)
            .initializeSchema(true)
            .build();
}
```

> ⚠️ **最常见的坑：维度不一致**。换 Embedding 模型（如 1536 → 1024）必须重建表与全量重向量化，否则写入报错或召回错乱。

## 三、EmbeddingModel

```java
@Bean
EmbeddingModel embeddingModel() {
    return new OpenAiEmbeddingModel(OpenAiApi.builder().apiKey(key).build());
}

// 批量向量化（ETL 里由 VectorStore 内部调用）
float[] v = embeddingModel.embed("被检索的文本");
```

要点：

- **查询与文档必须用同一个模型**（否则向量空间不对齐）；
- 优先用**批量接口**降低 RT 与费用；
- 记录**模型版本**，做版本化重建（见生产小节）。

## 四、ETL Pipeline：把文档喂进 VectorStore

Spring AI 把 ETL 拆成三段，像管道一样组合：

### 4.1 Reader（读）

```java
DocumentReader reader = new TextReader(resource);        // 纯文本
DocumentReader pdf    = new PagePdfDocumentReader(pdfRes); // PDF 分页
DocumentReader json   = new JsonReader(resource);         // JSON（JsonKeys 定位）
DocumentReader tika   = new TikaDocumentReader(resource); // 万能（docx/pptx…）
List<Document> docs = reader.get();
```

### 4.2 Transformer（切分 + 增强）

```java
List<Document> chunks = new TokenTextSplitter(800, 350, 5, 10000, true)
        .apply(docs);
// 参数：目标 token 数、重叠 token、最小块字符数、最大块字符数、
//      是否剔除空白/仅保留文本
```

切分是 RAG 质量的第一道关：**chunk 要"语义完整"**。对结构化文档（Markdown、代码），更推荐按标题/代码块切分，或先做 `KeywordMetadataEnricher`、`SummaryMetadataEnricher` 给 chunk 补元数据：

```java
new KeywordMetadataEnricher(chatModel, 5).apply(chunks);  // 给每块打 5 个关键词
new SummaryMetadataEnricher(chatModel, List.of(SUMMARY)).apply(chunks);
```

### 4.3 Writer（写）

```java
vectorStore.add(chunks);   // VectorStore 本身就是 DocumentWriter
```

**完整入库流水线：**

```java
@PostConstruct
void ingest() {
    List<Document> docs = new TikaDocumentReader(resource).get();
    List<Document> chunks = new TokenTextSplitter().apply(docs);
    // 关键：给每块补上 tenant / source 元数据，供检索时过滤
    chunks.forEach(d -> {
        d.getMetadata().put("tenant", currentTenant);
        d.getMetadata().put("source", fileName);
    });
    vectorStore.add(chunks);
}
```

## 五、把 RAG 挂上 ChatClient：Advisor

### 5.1 简单版：QuestionAnswerAdvisor

```java
ChatClient chatClient = ChatClient.builder(chatModel)
        .defaultAdvisors(QuestionAnswerAdvisor.builder(vectorStore)
                .searchRequest(SearchRequest.builder().topK(4).build())
                .build())
        .build();

String answer = chatClient.prompt()
        .user("公司年假怎么算？")
        .call().content();
```

它做的事：**用户问题 → 向量检索 → 把命中片段拼进 Prompt → 呼叫模型**。契约是"检索到的上下文放在 user/system 消息里，让模型基于它回答"。

### 5.2 进阶版：RetrievalAugmentationAdvisor（模块化 RAG）

Spring AI 1.0 引入了模块化 RAG，把"检索前处理 / 检索 / 检索后处理"拆成可替换组件：

```java
Advisor ragAdvisor = RetrievalAugmentationAdvisor.builder()
        .queryTransformers(RewriteQueryTransformer.builder()
                .chatClientBuilder(ChatClient.builder(chatModel)).build())
        .documentRetriever(VectorStoreDocumentRetriever.builder()
                .vectorStore(vectorStore)
                .similarityThreshold(0.6)
                .topK(5)
                .filterExpression(filterFrom(currentUser))
                .build())
        .build();

ChatClient client = ChatClient.builder(chatModel)
        .defaultAdvisors(ragAdvisor).build();
```

- **`QueryTransformer`**：Query 改写/扩写（如 `RewriteQueryTransformer`、`TranslationQueryTransformer`、`CompressionQueryTransformer`）；
- **`DocumentRetriever`**：`VectorStoreDocumentRetriever`，可加过滤、阈值；
- **`DocumentPostProcessor`**：重排（Rerank）、去重、压缩。

这套设计与 LangChain/LlamaIndex 的"模块化 RAG"思路一致，但完全用 Java/Spring 表达。

## 六、检索增强进阶（生产必备）

1. **元数据过滤做权限隔离**：多租户系统里，`filterExpression` 里**必须**带 `tenant == 'xxx'`，否则会跨租户泄露数据——这是 RAG 最危险的生产事故来源之一。
2. **混合检索**：ES 场景用 BM25（关键词）+ kNN（语义）融合，中文配合 IK 分词；纯向量库可用"稀疏向量"或外挂倒排。
3. **重排（Rerank）**：先粗召回 topK=20，用 rerank 模型（如 bge-reranker）精排取 top5，显著提升相关性。
4. **多查询扩展**：让 LLM 把一个问题改写成 3 个不同表述，分别检索后合并去重，对抗"提问措辞"偏差。
5. **引用溯源**：把 `source` 元数据回传给前端，让答案可点击回到原文——企业场景的信任基础。

## 七、生产注意事项

- **增量更新**：入库时用稳定 `id`（如 `file#chunkIndex`），更新文档时先 `delete(filter)` 再 `add`，避免旧块残留；
- **成本**：Embedding 按 token 计费，全量重向量化要预算；模型版本升级要版本化重建（可加 `embedding_model_version` 元数据 + 双写过渡）；
- **可观测**：记录每次检索的 query、命中 id、分数、延迟，用于离线评测（Recall@K、MRR）；
- **缓存**：对高频 query 做语义缓存（见本站《大模型缓存深度实战》）。

## 八、常见报错与排错

| 现象 | 常见原因 | 处理 |
|---|---|---|
| 写入报 `dimension mismatch` | Embedding 维度与建表维度不一致 | 核对 `dimensions` 并重建表 |
| `similaritySearch` 恒为空 | 阈值过高 / 检索与入库用了不同模型 | 下调阈值、统一模型 |
| 答案不引用知识库 | 检索无命中 / Prompt 未强约束 | 检查召回、加"仅依据上下文回答"约束 |
| 上下文超限 | topK 太大 / chunk 太大 | 降 topK、缩小 chunk、摘要压缩 |
| 检索串出别的租户数据 | `filterExpression` 漏了租户条件 | 在底层封装强制附加 tenant 过滤 |

排错的核心方法：**把"检索结果"单独打日志**——先确认"召回对不对"，再怀疑"生成好不好"。90% 的 RAG 问题都出在检索侧。

## 九、Spring AI vs LangChain4j

| 维度 | Spring AI | LangChain4j |
|---|---|---|
| 生态 | Spring 全家桶 / 自动配置 | 独立库，框架无关 |
| RAG 抽象 | VectorStore + Advisor | EmbeddingStore + ContentRetriever |
| 模块化 RAG | RetrievalAugmentationAdvisor | DefaultRetrievalAugmentor |
| Agent/工具 | `@Tool` + Function Calling | `@Tool` + AiServices |
| 适合 | Spring Boot 项目 | 任意 Java 项目 |

两者概念高度对应，选哪个往往取决于**项目是否已是 Spring Boot**。

## 十、总结

Spring AI 把 RAG 从"手撸链路"变成了"装配 Bean"：`VectorStore` 管存储与检索、ETL Pipeline 管入库、Advisor 管编排。落地时真正决定效果的，仍然是**切分质量、检索参数、元数据过滤与重排**这些"老问题"。框架给你的是工程效率，**RAG 效果的上限，永远是你的数据工程能力**。
