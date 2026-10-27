---
title: 【RAG 进阶】Agentic RAG 深度解析：查询规划、自适应检索与自我纠错
date: 2026-10-27 08:00:00
tags:
  - AI
  - RAG
  - Agent
  - Java
categories:
  - RAG
author: 东哥
---

# 【RAG 进阶】Agentic RAG 深度解析

## 前言

如果你做过企业知识库，一定遇到过这些场景：

- 用户问「我们公司去年 Q3 的差旅报销标准和今年有什么区别」，一次向量检索只召回了今年的文档，模型答非所问；
- 用户问「订单服务超时怎么排查」，检索召回了「订单服务架构」和「超时重试配置」两篇无关文档，模型把两者强行拼在一起，编了个答案；
- 用户问「张三和李四谁的绩效更好」，检索到的文档里根本没有这两个人的对比，但模型依然给了一个看起来很像的结论。

这些问题的共同点是：**问题需要多步推理、需要判断「检索到的内容够不够」、需要在不够时换个问法再查**。而标准 RAG（一次检索 → 一次生成）是一条单行道，没有任何「判断」和「回退」的能力。

Agentic RAG 就是给 RAG 加上「决策循环」：让模型自己决定**查不查、查什么、查几次、查到的东西够不够、不够怎么办**。

这篇文章会讲清楚：标准 RAG 到底断在哪、Agentic RAG 的四种典型架构、用 Java（LangChain4j + Spring AI）怎么落地、以及成本和延迟怎么控住。

---

## 一、标准 RAG 的五个断点

先明确定义。标准 RAG 的流程是：

```
Query → Embedding → 向量检索 Top-K → 拼进 Prompt → LLM 生成
```

它假设了两个前提：**① 问题和文档的语义空间是对齐的；② 一次检索就能召回所有需要的信息。**

现实中这两个前提经常不成立，于是产生五个断点：

| 断点 | 表现 | 根因 |
|---|---|---|
| ① 查询表达偏差 | 用户口语化，文档是书面语，向量距离远 | 单次 Embedding 无法桥接语义鸿沟 |
| ② 多跳问题 | 「A 的上级部门負責的制度是什么」需要先查 A 的部门 | 一次检索无法完成链式推理 |
| ③ 检索结果无关 | 召回了语义相似但不相关的内容 | 相似 ≠ 相关 |
| ④ 上下文不足 | 召回文档只覆盖问题的一部分 | 单次 Top-K 有天花板 |
| ⑤ 幻觉填补 | 资料不足时模型硬编 | 没有「我不知道」的机制 |

Agentic RAG 针对每个断点都有对应解法，而它们的共同基础是：**把「检索」变成一个可以被模型调用的工具，把「生成」变成一个可以被校验和重试的步骤**。

---

## 二、Agentic RAG 的四种模式

### 2.1 模式一：路由（Router）

**解决的问题**：不同问题应该查不同的数据源。

比如企业内部有：产品文档库、工单系统、代码仓库、财务报表。用户问「上周那个支付失败率高的问题解决了吗」，应该查工单系统而不是产品文档。

```
Query → LLM 判断意图 → 选择数据源 → 检索 → 生成
```

实现上就是一个分类 + 路由：

```java
public enum DataSource { DOCS, TICKETS, CODE, FINANCE, NONE }

public DataSource route(String query) {
    String prompt = """
        你是企业知识库路由器。根据用户问题判断应该查询哪个数据源。
        只输出一个词：DOCS / TICKETS / CODE / FINANCE / NONE
        如果问题与公司内部信息无关，输出 NONE。

        用户问题：%s
        """.formatted(query);

    String result = llm.generate(prompt).trim().toUpperCase();
    return DataSource.valueOf(result);
}
```

路由器看起来简单，但它能解决 30% 以上的「答非所问」，成本只有一次小模型调用。**这是投入产出比最高的一步。**

### 2.2 模式二：查询规划（Query Planning）

**解决的问题**：复杂问题需要拆成多个子查询，分别检索后合并。

比如「对比 Spring AI 和 LangChain4j 在 RAG 上的差异」，可以拆成：

1. `Spring AI RAG 能力`
2. `LangChain4j RAG 能力`
3. `Spring AI vs LangChain4j 对比`

三条查询并行检索，结果合并去重后再生成。

```java
public List<String> planQueries(String query) {
    String prompt = """
        将下面的复杂问题拆解为 1-3 个独立的检索子查询。
        要求：
        - 每个子查询都应该是自包含的（不依赖上下文代词）
        - 子查询之间不要重复
        - 用 JSON 数组输出，例如 ["查询1","查询2"]

        问题：%s
        """.formatted(query);

    String json = llm.generate(prompt);
    return objectMapper.readValue(json, new TypeReference<List<String>>() {});
}
```

**多跳（Multi-hop）** 是查询规划的进阶版：第二步的查询依赖第一步的答案。

```
Q: 张三是哪个部门的？那个部门的负责人是谁？
Step 1: 查「张三 部门」→ 研发部
Step 2: 查「研发部 负责人」→ 李四
```

多跳不能用并行，必须串行，且要有「终止条件」（最多 N 跳，避免死循环）。

### 2.3 模式三：自我纠错（Self-RAG / Corrective RAG）

**解决的问题**：检索到的内容不相关或不足时，主动纠正。

这是 Agentic RAG 最有价值的部分。核心是三个判断节点：

```
1. 检索前：这个问题需要检索吗？（闲聊不需要）
2. 检索后：召回的文档相关吗？（不相关 → 改写查询重查）
3. 生成后：答案有文档支撑吗？（没支撑 → 重新生成或拒答）
```

**节点 1：是否需要检索**

不是所有问题都需要查知识库。「你好」「谢谢」这类直接回答，查了反而可能引入无关内容。

**节点 2：相关性评估**

对每条召回文档打分（0~1），低于阈值就丢弃。如果全部低于阈值，说明「查询没写对」，改写后重查。

```java
public record GradedDoc(String content, double score, String source) {}

public List<GradedDoc> gradeAndFilter(String query, List<GradedDoc> docs) {
    List<GradedDoc> kept = new ArrayList<>();
    for (GradedDoc d : docs) {
        String prompt = """
            判断下面这段文档是否包含回答问题的必要信息。
            只输出 yes 或 no。

            问题：%s
            文档：%s
            """.formatted(query, truncate(d.content(), 1500));

        if ("yes".equalsIgnoreCase(llm.generate(prompt).trim())) {
            kept.add(d);
        }
    }
    return kept;
}
```

> 性能提醒：逐条打分等于 N 次 LLM 调用，成本很高。生产上应该用**小模型 + 批量打分**（一次 prompt 里塞 5 条，让模型输出 `[yes,no,yes,...]`），或者用 Cross-Encoder 重排模型（如 `bge-reranker`）代替 LLM 打分——后者便宜 100 倍且效果往往更好。

**节点 3：答案忠实度检查**

生成后用「是否每个论断都能在文档中找到依据」来校验，不通过则重生成或降级为「未找到相关信息」。

### 2.4 模式四：迭代检索（Iterative Retrieval）

把上面的能力串成一个循环：

```
while (未达到终止条件) {
    检索 → 评估 → 如果足够就生成；不够就改写查询 / 补充检索
}
```

终止条件必须显式定义，否则会无限循环烧钱：

- 最大迭代次数（通常 3~5）；
- 已收集的文档数超过阈值；
- 模型判断「信息已充分」；
- 总 token 消耗超过预算。

---

## 三、Java 落地：LangChain4j 的 AiServices

LangChain4j 提供了 `AiServices` 抽象，可以用注解声明「工具」，让模型自己决定调用。

### 3.1 定义检索工具

```java
import dev.langchain4j.agent.tool.Tool;
import dev.langchain4j.rag.content.Content;
import dev.langchain4j.rag.content.retriever.ContentRetriever;
import dev.langchain4j.rag.query.Query;

public class KnowledgeBaseTools {

    private final ContentRetriever retriever;

    public KnowledgeBaseTools(ContentRetriever retriever) {
        this.retriever = retriever;
    }

    @Tool("""
        在内部产品文档库中检索。当用户询问产品功能、配置、使用方法时调用。
        输入应该是一个完整的、自包含的检索语句。
        """)
    public String searchDocs(String query) {
        List<Content> contents = retriever.retrieve(Query.from(query));
        return contents.stream()
            .limit(5)
            .map(c -> "【来源：" + c.textSegment().metadata().getString("source")
                      + "】\n" + c.textSegment().text())
            .collect(Collectors.joining("\n\n---\n\n"));
    }

    @Tool("""
        在历史工单库中检索。当用户询问故障、报错、线上问题时调用。
        """)
    public String searchTickets(String query) {
        // 同上，换 retriever
        return "";
    }

    @Tool("""
        用不同的关键词重新检索。当第一次检索结果不相关时调用。
        输入应该是改写后的查询，避免使用原问题的口语化表达。
        """)
    public String searchWithRewrite(String rewrittenQuery) {
        return searchDocs(rewrittenQuery);
    }
}
```

### 3.2 组装 Agent

```java
import dev.langchain4j.service.SystemMessage;
import dev.langchain4j.service.UserMessage;
import dev.langchain4j.service.V;

public interface RagAgent {

    @SystemMessage("""
        你是企业内部知识助手。请严格遵循以下规则：

        1. 先判断问题是否需要查知识库。闲聊、通用常识、与公司无关的问题，
           直接回答，不要调用工具。
        2. 需要查资料时，先调用 searchDocs 或 searchTickets。
        3. 如果检索结果与问题不相关（例如文档讲的是另一个产品），
           必须调用 searchWithRewrite 换关键词重试，最多重试 2 次。
        4. 如果重试后仍然找不到依据，必须明确回答
           「根据现有资料无法确认」，禁止编造。
        5. 回答时必须标注引用来源，格式：[来源: 文件名]。
        6. 涉及多个子问题时，可以多次调用检索工具，分别取证。
        """)
    String chat(@V("question") String question);
}
```

```java
RagAgent agent = AiServices.builder(RagAgent.class)
    .chatLanguageModel(chatModel)          // 支持 Function Calling 的模型
    .tools(new KnowledgeBaseTools(retriever))
    .chatMemory(MessageWindowChatMemory.withMaxMessages(20))
    .build();

String answer = agent.chat("去年 Q3 的差旅报销标准和今年有什么区别？");
```

这段代码的价值在于：**「什么时候查、查几次、要不要改写」这些决策，从硬编码变成了模型的推理**。你不再需要写 `if (docs.isEmpty()) retry()` 这种脆弱的规则。

### 3.3 用 Spring AI 实现同样的循环

Spring AI 的思路是「显式编排」，控制力更强（适合需要严格约束的生产场景）：

```java
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.stereotype.Service;

@Service
public class AgenticRagService {

    private final ChatModel chatModel;
    private final VectorStore vectorStore;
    private final ChatClient planner;

    public AgenticRagService(ChatModel chatModel, VectorStore vectorStore) {
        this.chatModel = chatModel;
        this.vectorStore = vectorStore;
        this.planner = ChatClient.builder(chatModel).build();
    }

    public String answer(String question) {
        List<String> queries = plan(question);
        List<String> docs = new ArrayList<>();

        for (String q : queries) {
            List<Document> hits = vectorStore.similaritySearch(
                SearchRequest.builder().query(q).topK(5).build());
            docs.addAll(hits.stream().map(Document::getText).toList());
        }

        List<String> relevant = grade(question, docs);
        if (relevant.isEmpty()) {
            // 一次纠正：改写查询后重试
            String rewritten = rewrite(question);
            relevant = vectorStore.similaritySearch(
                    SearchRequest.builder().query(rewritten).topK(5).build())
                .stream().map(Document::getText).toList();
        }

        if (relevant.isEmpty()) {
            return "根据现有资料无法确认该问题。";
        }
        return generate(question, relevant);
    }

    private List<String> plan(String q) {
        String out = planner.prompt()
            .user("把问题拆成 1-3 个自包含的检索查询，输出 JSON 数组：\n" + q)
            .call().content();
        try {
            return new ObjectMapper().readValue(out, new TypeReference<>() {});
        } catch (Exception e) {
            return List.of(q);   // 规划失败就退化为单查询
        }
    }

    private List<String> grade(String q, List<String> docs) {
        if (docs.isEmpty()) return List.of();
        // 批量打分：一次 prompt 评 5 条
        String joined = IntStream.range(0, Math.min(docs.size(), 10))
            .mapToObj(i -> "[" + i + "] " + truncate(docs.get(i), 800))
            .collect(Collectors.joining("\n"));
        String verdict = planner.prompt()
            .user("""
                判断下列文档是否与问题相关，逐条输出 yes/no，用逗号分隔，只输出判定结果。
                问题：%s
                文档：
                %s
                """.formatted(q, joined))
            .call().content();

        String[] flags = verdict.split(",");
        List<String> kept = new ArrayList<>();
        for (int i = 0; i < Math.min(flags.length, docs.size()); i++) {
            if (flags[i].trim().toLowerCase().startsWith("y")) {
                kept.add(docs.get(i));
            }
        }
        return kept;
    }
}
```

**两种风格的取舍**：

| 维度 | LangChain4j AiServices | Spring AI 显式编排 |
|---|---|---|
| 开发速度 | 快（声明式） | 慢（要写流程） |
| 可控性 | 中（依赖模型判断） | 高（每步都可干预） |
| 成本 | 不可预测（模型可能多调） | 可精确预算 |
| 调试难度 | 高（决策在模型内部） | 低（每步有日志） |
| 适合 | POC、内部工具 | 生产、有 SLA 要求的系统 |

**生产建议：用显式编排为主，在「查询改写」这种模糊环节用模型决策。** 全交给模型，成本和延迟都不可控。

---

## 四、成本与延迟：Agentic RAG 最大的敌人

标准 RAG 是 1 次检索 + 1 次生成，约 1~3 秒、几千 token。Agentic RAG 如果不加约束，很容易变成 8 次调用、20 秒、5 万 token。

### 4.1 三层控制

**第一层：模型分级**

| 环节 | 用什么模型 | 理由 |
|---|---|---|
| 路由 / 相关性打分 / 查询改写 | 小模型（7B 本地 / gpt-4o-mini） | 简单判断，不需要强推理 |
| 最终生成 | 大模型 | 质量决定用户体验 |
| 忠实度校验 | 小模型 | 只需判断「有无支撑」 |

这一层通常能省 60% 的成本。

**第二层：检索缓存**

- **查询缓存**：相同 query 的检索结果缓存 5~30 分钟；
- **语义缓存**：相似 query（cosine > 0.95）复用结果，注意要设较高的阈值，否则会答错；
- **文档缓存**：文档内容进 Redis，避免每次都从向量库拉全文。

**第三层：并行化**

多个子查询之间没有依赖时，必须并行。Java 里用虚拟线程最简单：

```java
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    List<Future<List<Document>>> futures = queries.stream()
        .map(q -> executor.submit(() -> vectorStore.similaritySearch(q)))
        .toList();

    List<Document> all = new ArrayList<>();
    for (var f : futures) {
        all.addAll(f.get(10, TimeUnit.SECONDS));   // 单个子查询超时就放弃
    }
}
```

注意 `f.get()` 要带超时，否则一个慢查询会拖死整个请求。

### 4.2 延迟预算表

| 环节 | 目标耗时 | 超时策略 |
|---|---|---|
| 路由 | 200ms | 失败默认查全部 |
| 查询规划 | 800ms | 失败退化为原查询 |
| 向量检索（每条） | 100ms | 并行，总超时 1s |
| 重排 | 300ms | 跳过，用原始排序 |
| 相关性打分 | 500ms | 降级为「全保留」 |
| 生成（首 token） | 1.5s | 超时提示重试 |
| 生成（完整） | 8s | 截断输出 |

总预算控制在 12 秒内，超出就降级为标准 RAG。

---

## 五、评测：怎么证明 Agentic 比标准 RAG 好

不能靠感觉。至少要有三组指标：

| 指标类别 | 具体指标 | 衡量什么 |
|---|---|---|
| 检索质量 | Recall@K、MRR、上下文精确率 | 该找到的找到了吗 |
| 生成质量 | 忠实度（Faithfulness）、答案相关性 | 有没有编，答没答到点上 |
| 系统指标 | P50/P99 延迟、平均 token 消耗、单次成本 | 值不值得 |

做法：

1. 构建 100~300 条**黄金集**（问题 + 标准答案 + 出处文档）；
2. 同时跑「标准 RAG」和「Agentic RAG」两条链路；
3. 用 LLM-as-Judge 打分（同一模型、同一 prompt、打乱顺序避免位置偏好）；
4. 人工抽检 20% 校准 Judge 的可靠性。

经验数据（企业内部文档库，300 条黄金集）：

| 方案 | 答案准确率 | 幻觉率 | P99 延迟 | 平均 token |
|---|---|---|---|---|
| 标准 RAG（Top-5） | 61% | 18% | 2.8s | 3.2K |
| + 查询改写 | 68% | 14% | 3.6s | 4.1K |
| + 相关性过滤 | 73% | 8% | 5.2s | 5.8K |
| + 查询规划（Agentic） | **81%** | **4%** | 9.7s | 11.4K |

结论很清晰：**准确率提升 20 个百分点，代价是延迟 3.5 倍、token 3.5 倍**。所以要不要上 Agentic，取决于业务对准确率的敏感度——客服场景 61% 不可接受，内部搜索 73% 也许够了。

---

## 六、五个生产踩坑

### 坑 1：模型不会主动调用工具

小模型（7B 以下）的 Function Calling 能力很弱，经常「自己编一个答案」而不去检索。解决：① 换支持工具调用的模型（Qwen2.5-7B-Instruct 以上）；② 在 system prompt 里用强约束（「必须先调用工具」）；③ 用「强制工具调用」参数（OpenAI 的 `tool_choice="required"`）。

### 坑 2：无限循环

模型反复改写查询、反复检索，token 烧光。必须有**硬性迭代上限**（代码层 `for (int i = 0; i < 3; i++)`），不能只依赖 prompt 里的「最多重试 2 次」。

### 坑 3：上下文爆炸

3 次检索 × 5 条 × 2000 字 = 3 万字，超过模型上下文。必须做**去重 + 截断 + 按相关度排序后只取前 N 条**。

```java
List<Document> deduped = docs.stream()
    .collect(Collectors.toMap(
        d -> d.getText().substring(0, Math.min(100, d.getText().length())),
        d -> d, (a, b) -> a))
    .values().stream().toList();
```

### 坑 4：打分模型和生成模型「串味」

用同一个模型既打分又生成，它会倾向于「给自己检索的内容打高分」。解决：打分用小模型或 Cross-Encoder，与生成模型解耦。

### 坑 5：引用溯源对不上

模型标注了 `[来源: 文档A]`，但内容其实来自文档 B。这是 Agentic RAG 最尴尬的问题——**越是多步检索，越难对齐引用**。

解决：检索时给每条文档编号（`[1] [2] [3]`），要求模型只用编号引用，生成后再用编号反查真实来源。不要相信模型自己写的文件名。

---

## 七、面试追问

**Q1：Agentic RAG 和「RAG + 重排」有什么区别？**

重排（Rerank）是在**同一次检索**里优化排序，属于「单轮内的优化」；Agentic RAG 是**多轮决策**，模型可以决定「再查一次」「换个问法」「不查了」。前者是 pipeline 优化，后者是 control flow 的改变。

**Q2：什么时候不该用 Agentic RAG？**

① 问题简单直接（FAQ 类），标准 RAG 准确率已经 > 85%；② 延迟敏感（< 3s）；③ 成本敏感（高频调用）；④ 团队没有能力做评测体系——没有评测就无法证明它更好，也无法发现回归。

**Q3：怎么防止 Agent 编造？**

三件事：① 检索结果为空或全部不相关时，强制返回固定话术；② 生成后做忠实度校验（NLI 模型或 LLM 判断「答案是否被文档支撑」）；③ 引用必须用编号而非模型自述的文件名。

**Q4：多跳检索怎么做终止判断？**

三种信号：① 硬性跳数上限；② 模型自评「信息是否充分」（输出 `SUFFICIENT` / `INSUFFICIENT`）；③ 新增文档的信息增益低于阈值（新检索的文档与已有文档的相似度 > 0.9，说明没带来新信息）。

**Q5：Agentic RAG 的 token 成本怎么优化？**

分级模型（小模型做判断）、检索缓存（查询级 + 语义级）、上下文压缩（只保留相关段落而非整篇）、并行化（降低延迟不降成本）、以及**只在必要时才走 Agentic 链路**（先用低成本分类器判断问题复杂度）。

---

## 八、总结

Agentic RAG 不是「换个更花哨的框架」，而是把 RAG 从**固定管道**升级成**带反馈的控制系统**。它的四个核心能力：

1. **路由**：知道该查哪个库（投入产出比最高）；
2. **规划**：把复杂问题拆成可检索的子问题；
3. **纠错**：判断检索质量，不行就改写重查；
4. **收敛**：有明确的终止条件和降级路径。

落地时的三条铁律：

- **用显式编排做主流程**，只在模糊环节交给模型决策；
- **必须有硬性迭代上限和超时**，否则成本和延迟会失控；
- **先建评测集再上 Agentic**，否则你无法知道它到底变好了还是变贵了。

对于 Java 工程师来说，这块的技术栈已经成熟：LangChain4j 做工具编排、Spring AI 做工程化、虚拟线程做并发、Micrometer 做可观测。把这套跑通，你就从「会调 API」进阶到了「会设计 AI 系统」——这是 AI 应用开发岗面试里最能拉开差距的部分。
