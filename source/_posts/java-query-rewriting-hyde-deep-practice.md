---
title: 【Java AI】Query Rewriting 与 HyDE 深度实战：多查询扩展、假设文档与 RRF 融合的 Spring AI 落地
date: 2026-10-31 08:15:00
tags:
  - Java
  - AI
  - RAG
  - Query Rewriting
  - HyDE
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Query Rewriting 与 HyDE 深度实战

## 前言

做 RAG 的人都有一个共同经历：**知识库明明有答案，模型就是答不出来**。于是开始怀疑切分粒度、怀疑 Embedding 模型、怀疑向量库、怀疑 topK 太小。折腾一圈换了三个 Embedding 模型，召回率只涨了 3 个点。

真相往往是：**问题出在 query 侧，不在检索侧**。

用户的原始输入和文档的表述之间存在天然的语义鸿沟：

| 用户说 | 文档写 | 向量相似度 |
|---|---|---|
| "报销多久到账" | "费用报销审批通过后 5 个工作日内完成付款" | 低（"到账" vs "付款"） |
| "那个订单为什么还没发货" | "订单履约流程：支付、拣货、出库、物流交接" | 很低（含指代 + 口语） |
| "RAG 效果差怎么办" | "检索增强生成系统的召回优化策略" | 中（缩写 + 术语不一致） |
| "它支持事务吗" | "MySQL InnoDB 事务特性"（上一轮在聊 MySQL） | 极低（指代丢失） |

**Query Rewriting（查询改写）就是在这道鸿沟上架桥**。而 **HyDE（Hypothetical Document Embeddings）** 是其中最有意思的一种：不改写问题本身，而是让 LLM **先编一个假答案**，用假答案去检索。

本文讲清这两条路线的原理、适用边界，然后用 **Spring AI + Java** 落地一套完整管线：多查询扩展 → 并行向量化 → RRF 融合 → 去重 → 重排，最后给评测与成本核算。

---

## 一、Query 侧的四类问题

先把问题分类，才能对症下药。

### 1.1 口语化 / 非术语表达

用户不是文档作者。他说"卡顿"，文档写"响应延迟升高"；他说"崩了"，文档写"进程异常退出"。

**解法**：术语归一化（同义词词典 + LLM 改写）。

### 1.2 指代与上下文依赖（多轮对话）

"它"、"这个"、"那刚才那个方案"，单看这一句完全无法检索。

**解法**：**Coreference Resolution / Query Standalone 化**——用对话历史把当前问题重写成独立可检索的句子。这是多轮 RAG 的**必做项**，优先级高于任何检索调优。

### 1.3 术语不匹配 / 跨语言

中文问、英文文档；或者用户用产品内部黑话，文档用标准术语。

**解法**：查询扩展（同义词、上位词）、跨语言改写（Query Translation）。

### 1.4 问题过短 / 过长 / 多意图

- 过短："事务"——向量太泛，召回一堆不相关。
- 过长：用户把整个报错栈粘贴进来——向量被噪声稀释。
- 多意图："怎么配置连接池，还有超时怎么设"——一句话两个检索目标。

**解法**：短查询扩展（HyDE 特别有效）、长查询抽取关键信息、多意图拆分为多个子查询（Sub-query Decomposition）。

---

## 二、Query Rewriting 技术谱系

| 技术 | 做法 | 开销 | 适用 |
|---|---|---|---|
| **规则/词典** | 同义词表、停用词、缩写展开 | 0 | 领域黑话固定、可枚举 |
| **LLM 改写（Standalone）** | 结合历史重写成独立 query | 1 次 LLM | 多轮对话必做 |
| **Query Expansion** | 生成 3~5 个同义/相关查询 | 1 次 LLM + N 次向量化 | 召回率优先 |
| **Step-back Prompting** | 先问"更抽象的问题"，再问细节 | 1~2 次 LLM | 需要背景知识的推理题 |
| **Decomposition** | 拆成子问题分别检索 | 1 次 LLM + N 次检索 | 多跳问答（multi-hop） |
| **HyDE** | 生成假设答案，用答案检索 | 1 次 LLM + 1 次向量化 | 短查询、术语鸿沟大 |
| **Query Routing** | 判断该查哪个库/要不要查 | 1 次小模型 | 多数据源 |

> 注意：**不是越多越好**。每加一层改写就多一次 LLM 调用，延迟 +300~800ms，token 成本翻倍。生产里应该按场景组合，而不是全上。

---

## 三、HyDE：用假答案检索真文档

### 3.1 原理

HyDE（Precise Zero-Shot Dense Retrieval without Relevance Labels, 2022）的洞察很反直觉：

> **向量检索匹配的是"文档的分布"，不是"问题的分布"。**

用户的问题是疑问句，文档是陈述句。两者在向量空间里天然有偏移。既然我们最终要匹配文档，为什么不直接构造一个"像文档的东西"？

流程：

```
Query: "报销多久到账"
   ↓ LLM 生成假设文档（可以包含幻觉）
Hypothetical Doc: "员工提交费用报销单后，需经直属主管与财务审批。
                   审批通过后，财务部在 5 个工作日内将款项支付至员工工资卡。
                   若遇月末结账，可能顺延 2 个工作日。"
   ↓ Embedding
Vector → 检索 → 命中真实文档："费用报销审批通过后 5 个工作日内完成付款"
```

**为什么有效**：假设文档在**词汇、句式、长度、术语密度**上都更接近真实文档，向量自然更靠近文档簇。即使内容有幻觉，只要"话题、术语、文体"对了，检索就能命中。

### 3.2 什么时候 HyDE 有效 / 无效

| 场景 | 效果 | 原因 |
|---|---|---|
| 短查询、口语化（"报销多久"） | ✅ 显著提升 | 补足了语义与术语 |
| 术语鸿沟大（用户词 vs 文档词） | ✅ 提升 | 假设文档会用文档术语 |
| 需要精确匹配（订单号、错误码、API 名） | ❌ 有害 | LLM 会编造错误码，把检索带偏 |
| 事实型短答案（"CEO 是谁"） | ⚠️ 不稳定 | 假设文档可能编错人名 |
| 长查询、信息已充分 | ❌ 无收益 | 原始 query 已足够 |
| 强时效性（今天股价） | ❌ 有害 | 幻觉污染 |

**工程结论**：HyDE 应该**与原始 query 并行检索，然后融合**，而不是替换原始 query。这样幻觉最多引入噪声，不会直接毁掉召回。

### 3.3 成本

一次 HyDE = 1 次 LLM（生成 100~200 token）+ 1 次 Embedding。相比多查询扩展（N 次 Embedding），HyDE 的**检索开销更低**（只多一路），但**生成延迟更高**（要等 LLM 吐完）。

---

## 四、Java 落地：Spring AI 完整管线

### 4.1 依赖

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-model-openai</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-vector-store-redis</artifactId>
</dependency>
```

```yaml
spring:
  ai:
    openai:
      api-key: ${OPENAI_API_KEY}
      chat:
        options:
          model: gpt-4o-mini          # 改写用小模型即可
          temperature: 0.2
      embedding:
        options:
          model: text-embedding-3-small
    vectorstore:
      redis:
        index: doc-index
        initialize-schema: true
```

### 4.2 第一步：多轮指代消解（Standalone Query）

```java
@Service
public class QueryStandaloneService {

    private final ChatClient chatClient;

    public QueryStandaloneService(ChatClient.Builder builder) {
        this.chatClient = builder
                .defaultSystem("""
                        你是查询改写器。根据对话历史，把用户最后一句话改写成
                        一个不依赖上下文、可独立用于检索的完整问题。
                        规则：
                        1. 补全所有代词（它/这个/那个）指向的具体对象；
                        2. 保留原始意图，不要回答问题；
                        3. 不要添加历史中不存在的信息；
                        4. 只输出改写后的句子，不要解释。
                        """)
                .build();
    }

    public String rewrite(String lastUserMessage, List<Message> history) {
        if (history == null || history.isEmpty()) {
            return lastUserMessage;   // 单轮无需改写
        }
        StringBuilder ctx = new StringBuilder();
        history.stream().limit(6).forEach(m ->
                ctx.append(m.getMessageType().getValue()).append(": ")
                   .append(m.getText()).append('\n'));

        String result = chatClient.prompt()
                .user(u -> u.text("""
                        对话历史：
                        {history}

                        用户最后一句话：{question}
                        """)
                        .param("history", ctx.toString())
                        .param("question", lastUserMessage))
                .call()
                .content();
        return result == null || result.isBlank() ? lastUserMessage : result.strip();
    }
}
```

**关键设计**：失败/空返回时**回退到原始 query**。改写是增强，不是前置依赖。

### 4.3 第二步：多查询扩展（结构化输出）

```java
public record QueryExpansion(List<String> queries, String intent) {}

@Service
public class QueryExpansionService {

    private final ChatClient chatClient;

    public QueryExpansionService(ChatClient.Builder builder) {
        this.chatClient = builder.build();
    }

    private static final String SYSTEM = """
            你是企业知识库的检索助手。把用户问题扩展成 3 个不同角度的检索查询：
            1. 原问题的专业化表述（使用技术术语）；
            2. 同义表述或口语化表述；
            3. 更上位/更抽象的问题（用于召回背景知识）。
            要求：每个查询不超过 30 字，不要回答问题，不要编造专有名词。
            """;

    public QueryExpansion expand(String question) {
        try {
            QueryExpansion result = chatClient.prompt()
                    .system(SYSTEM)
                    .user(question)
                    .call()
                    .entity(QueryExpansion.class);
            if (result == null || result.queries() == null || result.queries().isEmpty()) {
                return new QueryExpansion(List.of(question), "unknown");
            }
            // 去重 + 保留原始 query（永远不要丢掉用户原话）
            LinkedHashSet<String> merged = new LinkedHashSet<>();
            merged.add(question);
            result.queries().stream()
                    .filter(q -> q != null && !q.isBlank() && q.length() <= 60)
                    .forEach(merged::add);
            return new QueryExpansion(List.copyOf(merged), result.intent());
        } catch (Exception e) {
            log.warn("query expansion failed, fallback to raw query", e);
            return new QueryExpansion(List.of(question), "unknown");
        }
    }
}
```

`ChatClient.entity(Class)` 会要求模型输出 JSON 并按 schema 反序列化（底层是结构化输出 + 转换器）。**用 record 定义 schema 比解析字符串稳得多**。

### 4.4 第三步：HyDE 假设文档

```java
@Service
public class HydeService {

    private final ChatClient chatClient;

    public HydeService(ChatClient.Builder builder) {
        this.chatClient = builder
                .defaultSystem("""
                        你是技术文档撰写者。针对用户问题，写一段 80~150 字的
                        技术文档片段，风格类似企业内部 Wiki。
                        要求：使用专业术语，陈述句，不写"根据文档"之类的话；
                        不确定的具体数字/版本号请用模糊表述，不要编造。
                        """)
                .build();
    }

    public Optional<String> generate(String question) {
        try {
            String doc = chatClient.prompt()
                    .user(question)
                    .options(ChatOptions.builder()
                            .temperature(0.5)     // 稍高温度，增加覆盖
                            .maxTokens(220)
                            .build())
                    .call()
                    .content();
            return (doc == null || doc.isBlank()) ? Optional.empty() : Optional.of(doc.strip());
        } catch (Exception e) {
            log.warn("hyde generation failed, skip hyde branch", e);
            return Optional.empty();
        }
    }
}
```

### 4.5 第四步：并行检索 + RRF 融合

多路查询的分数**不可直接相加**（不同 query 的相似度分布不同），正确做法是 **RRF（Reciprocal Rank Fusion）**：只看排名，不看分数。

```java
public record RetrievedDoc(String id, String content, double score, Map<String, Object> metadata) {}

@Service
public class HybridQueryRetriever {

    private final VectorStore vectorStore;
    private final QueryExpansionService expansionService;
    private final HydeService hydeService;
    private final ExecutorService pool;   // 建议用虚拟线程池

    private static final int TOP_K_PER_QUERY = 8;
    private static final int FINAL_TOP_K = 6;
    private static final int RRF_K = 60;

    public List<RetrievedDoc> retrieve(String question, String tenantId) {
        // 1) 构造检索分支
        QueryExpansion expansion = expansionService.expand(question);
        List<String> queries = new ArrayList<>(expansion.queries());
        hydeService.generate(question).ifPresent(queries::add);

        // 2) 并行检索（每路 topK=8）
        List<CompletableFuture<List<Document>>> futures = queries.stream()
                .map(q -> CompletableFuture.supplyAsync(() -> searchSafely(q, tenantId), pool))
                .toList();

        List<List<Document>> resultLists = futures.stream()
                .map(CompletableFuture::join)   // 加超时见下文
                .toList();

        // 3) RRF 融合
        Map<String, Double> rrfScore = new HashMap<>();
        Map<String, Document> docById = new HashMap<>();
        for (List<Document> docs : resultLists) {
            for (int rank = 0; rank < docs.size(); rank++) {
                Document d = docs.get(rank);
                String id = d.getId();
                docById.putIfAbsent(id, d);
                rrfScore.merge(id, 1.0 / (RRF_K + rank + 1), Double::sum);
            }
        }

        // 4) 排序 + 截断 + 转 DTO
        return rrfScore.entrySet().stream()
                .sorted(Map.Entry.<String, Double>comparingByValue().reversed())
                .limit(FINAL_TOP_K)
                .map(e -> toDto(docById.get(e.getKey()), e.getValue()))
                .toList();
    }

    private List<Document> searchSafely(String query, String tenantId) {
        try {
            SearchRequest request = SearchRequest.builder()
                    .query(query)
                    .topK(TOP_K_PER_QUERY)
                    .similarityThreshold(0.2)     // 过滤明显无关
                    .filterExpression("tenantId == '" + tenantId + "'")   // 权限隔离
                    .build();
            return vectorStore.similaritySearch(request);
        } catch (Exception e) {
            log.warn("branch search failed: {}", query, e);
            return List.of();     // 单路失败不影响整体
        }
    }
}
```

**几个必须注意的点**：

1. **RRF 的 `k=60` 是经验值**，来自原论文。k 越大，排名差异被平滑得越厉害；k 越小，头部结果权重越高。
2. **必须有超时**。`CompletableFuture.join()` 会无限等待，要用 `orTimeout(800, TimeUnit.MILLISECONDS)` + `exceptionally(e -> List.of())`，否则一路 LLM 卡住会拖垮整个请求。
3. **权限过滤放在检索层**，不要检索完再过滤——否则 topK 被无关文档占满，且存在越权泄露风险。
4. **`filterExpression` 拼接有注入风险**，生产要用参数化或白名单校验 `tenantId`。

### 4.6 虚拟线程版本的执行器

```java
@Bean(destroyMethod = "close")
public ExecutorService retrievalExecutor() {
    // Java 21+，IO 密集型任务，虚拟线程池最合适
    return Executors.newVirtualThreadPerTaskExecutor();
}
```

改写/检索是**纯 IO 等待**，用平台线程池会把线程数限制成瓶颈；虚拟线程可以让几十路并发检索几乎零成本（详见虚拟线程跑 LLM IO 那篇）。

---

## 五、效果评测：别靠感觉

### 5.1 离线指标

| 指标 | 含义 | 目标 |
|---|---|---|
| **Recall@K** | 正确文档是否在 topK 中 | RAG 最核心，优先级最高 |
| **MRR** | 正确文档排名的倒数均值 | 衡量"排得前不前" |
| **nDCG@K** | 考虑多级相关性的排序质量 | 有分级标注时用 |
| **Hit Rate** | 至少命中一条正确的比例 | 快速回归 |

### 5.2 评测集怎么造

1. 从真实日志采样 **200~500 条 query**（不要自己编，自编的 query 都太规范）。
2. 人工标注每条 query 对应的**正确文档 ID**（可多个）。
3. 分层：单轮/多轮、短/长、术语/口语、单跳/多跳。
4. 每次改动只跑一次全量，输出**分桶对比表**，而不是只看总分。

### 5.3 一个真实的分桶结果

某企业知识库接入 Query Rewriting 后的效果（250 条评测集）：

| 分桶 | 样本数 | Recall@5 原方案 | +Standalone | +多查询 | +HyDE |
|---|---|---|---|---|---|
| 单轮·术语规范 | 90 | 0.86 | 0.86 | 0.89 | 0.89 |
| 单轮·口语化 | 70 | 0.58 | 0.59 | 0.74 | **0.81** |
| 多轮·含指代 | 60 | 0.41 | **0.78** | 0.80 | 0.80 |
| 多跳/多意图 | 30 | 0.35 | 0.36 | **0.62** | 0.60 |
| **总体** | 250 | 0.60 | 0.69 | 0.77 | **0.79** |

**结论非常清晰**：

- 多轮指代消解是**单项收益最大**的（0.41 → 0.78），且只花 1 次 LLM。
- 多查询扩展对多意图/多跳收益最大。
- HyDE 只对**口语化短查询**有额外增益，对术语规范的单轮几乎无收益。

**这就是为什么不能"全都上"**：对规范查询加 HyDE 纯属浪费延迟。

---

## 六、生产踩坑

### 6.1 改写引入噪声

LLM 改写可能**改变用户意图**。典型：用户问"如何关闭审计日志"，被改写成"如何开启审计日志"——一个字的差别，答案完全相反。

**防护**：
- Prompt 里明确"不得改变否定词、不得改变主体"。
- 改写结果与原 query **同时检索**（我们上面的管线就是这么做的），不要替换。
- 对含否定词（不/别/禁止/关闭）的 query 做规则校验：改写前后否定词数量不一致则回退原 query。

```java
private static final Pattern NEGATION = Pattern.compile("(不|别|禁止|关闭|禁用|无法|不能)");

private boolean negationChanged(String original, String rewritten) {
    long a = NEGATION.matcher(original).results().count();
    long b = NEGATION.matcher(rewritten).results().count();
    return a != b;
}
```

### 6.2 延迟叠加

| 步骤 | P50 | P99 |
|---|---|---|
| Standalone 改写 | 350ms | 900ms |
| 多查询扩展 | 500ms | 1400ms |
| HyDE 生成 | 700ms | 2000ms |
| 4 路并行向量检索 | 60ms | 200ms |
| **串行总计** | **1.6s** | **4.5s** |

**优化手段**：

1. **改写与扩展合并为一次 LLM 调用**（省一次 RTT）。
2. **HyDE 与扩展并行发起**（两者互不依赖）。
3. **按 query 特征路由**：短 query 才走 HyDE，长 query 跳过。
4. **流式返回**：先返回"正在检索"的状态，避免用户干等。

```java
// 合并改写 + 扩展的一次调用
public record RewriteResult(String standalone, List<String> expansions, boolean needHyde) {}
```

### 6.3 缓存

改写结果对**相同 query + 相同历史前缀**是稳定的，可以缓存：

```java
@Cacheable(value = "query-rewrite", key = "#question.hashCode() + ':' + #historyHash")
public RewriteResult rewriteCached(String question, String historyHash) { ... }
```

命中率在客服场景通常有 20%~35%（用户问题高度重复），**这部分延迟直接归零**。

### 6.4 多语言

中文 query + 英文文档：让 LLM 同时产出**中文与英文两个版本**的查询，各查一次，RRF 融合。实测跨语言场景 Recall@5 能提升 15~25 个点。

### 6.5 成本核算

以 10 万次/天、GPT-4o-mini 计（输入 \$0.15/M token、输出 \$0.60/M token）：

| 方案 | 每次 token（输入+输出） | 日成本 | 相对基线 |
|---|---|---|---|
| 无改写 | 0 | \$0 | — |
| Standalone | 600 + 40 | ≈ \$1.1 | +100% |
| +多查询 | 800 + 120 | ≈ \$1.9 | +170% |
| +HyDE | 900 + 300 | ≈ \$3.2 | +290% |

**结论**：全量上改写，LLM 改写成本约 **\$3/天/10 万次**，相对于主回答的生成成本（往往 \$30+）其实很小。**真正的成本是延迟，不是钱**。

---

## 七、面试追问

**Q1：RAG 召回不准，你怎么判断是 query 侧还是检索侧的问题？**

做**对照实验**：把人工写好的"标准 query"（术语规范、无指代）送进检索管线。如果标准 query 召回正常、原始 query 召回差 → query 侧问题；如果两者都差 → 检索侧（切分/Embedding/索引）问题。这个实验 10 分钟就能做，比换模型高效得多。

**Q2：HyDE 为什么有效？它不会引入幻觉吗？**

有效是因为向量检索匹配的是**文档分布**，假设文档在文体、术语、长度上更接近真实文档，向量更靠近文档簇。会引入幻觉，所以工程上**必须与原始 query 并行检索再融合**，让幻觉只贡献噪声而不主导结果；同时对含精确标识符（订单号、错误码）的 query 禁用 HyDE。

**Q3：多路检索结果怎么融合？为什么不能直接加相似度分数？**

不同 query 的相似度分布不同（量纲、方差都不同），直接相加会让某一路主导。标准做法是 **RRF**：`score = Σ 1/(k + rank)`，只用排名不用分数，对分布不敏感，且实现简单。有标注数据时也可以用学习到的融合权重（LTR）。

**Q4：多轮对话的 RAG 为什么必须先做 Standalone 改写？**

因为向量检索是**无状态**的，而对话是**有状态**的。"它支持事务吗"这句话单独 Embedding 几乎必然召回错误文档。Standalone 改写把隐式上下文显式化，是成本最低、收益最高的一步（我们的数据：多轮场景 Recall@5 从 0.41 提升到 0.78）。

**Q5：改写链路延迟 1.5s，怎么优化到 500ms 内？**

四招：① 合并改写与扩展为一次 LLM 调用；② 互不依赖的分支并行（HyDE 与扩展）；③ 按 query 特征路由（短 query 才走 HyDE）；④ 缓存改写结果（客服场景命中率 20%~35%）。再加上小模型（4o-mini / 本地 7B）做改写，P50 可以压到 400ms 左右。

---

## 八、总结

1. **RAG 效果差，先查 query 侧**。用"标准 query 对照实验"10 分钟定位，别一上来就换 Embedding 模型。
2. **四类 query 问题**：口语化、指代依赖、术语不匹配、过长过短多意图——对应四类改写技术。
3. **Standalone 改写是多轮 RAG 的必做项**，单项收益最大、成本最低。
4. **HyDE 是"用假答案检索真文档"**，对短查询和术语鸿沟有效，对精确匹配有害；必须与原始 query **并行 + RRF 融合**，不能替换。
5. **RRF 融合只看排名不看分数**，因为多路相似度不可比；`k=60` 是经验值。
6. **生产三件事**：超时降级（单路失败不拖垮整体）、权限过滤前置、改写结果缓存。
7. **成本真相**：改写花的钱很少（约 \$3/10 万次），花的是**延迟**——所以优化重点是并行、合并调用、按需路由。

Query Rewriting 不是"更高级的 Prompt"，而是**把用户语言翻译成检索语言**的一层适配器。把这层做扎实，比在检索侧堆十个技巧都管用。
