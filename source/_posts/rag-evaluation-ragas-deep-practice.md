---
title: 【RAG 进阶】RAG 评测深度实战：RAGAS 指标、黄金集与回归验证
date: 2026-10-21 08:40:00
tags:
  - AI
  - RAG
  - 评测
  - RAGAS
  - Java
  - Spring AI
categories:
  - RAG
author: 东哥
---

# 【RAG 进阶】RAG 评测深度实战：RAGAS 指标、黄金集与回归验证

## 前言

RAG 项目最容易出现的一种对话：

> 「我把 chunk size 从 512 调到 1024，感觉效果好多了。」
> 「怎么个好法？」
> 「我试了几个问题，回答更完整了。」

这不是评测，这是**手感**。手感的问题在于：

- 你试的 5 个问题，可能正好是 chunk=1024 擅长的；
- 你没试到的那 200 个问题里，可能有一半变差了；
- 下周有人调了 embedding 模型，没人知道整体是变好还是变坏；
- 老板问「这个 RAG 准确率多少」，你答不上来。

RAG 是一个多阶段的管道：文档解析 → 切分 → 向量化 → 检索 → 重排 → 组装 prompt → 生成。**任何一个环节的改动，都可能是「一类问题变好、另一类问题变坏」**。没有评测集，你连「变没变」都不知道，更别说「哪变了」。

这一篇讲怎么把 RAG 评测做成工程：指标怎么定义、黄金集怎么建、RAGAS 的四个核心指标怎么算、怎么用 Java 落地、怎么接进 CI 做回归。Python 生态的 RAGAS 很好用，但生产系统是 Java 的，评测必须能跑在同一个 CI 里——这是本文的立足点。

---

## 一、评测要分层，不要只有一个「准确率」

把 RAG 拆成两段看：

```
问题 ──→ [检索器] ──→ Top-K 文档 ──→ [生成器] ──→ 答案
         ↑                              ↑
    检索指标                        生成指标
```

如果只有一个端到端准确率，出问题时你无法定位是「没检索到」还是「检索到了但答错」。

### 1.1 三层指标体系

| 层次 | 指标 | 回答什么问题 | 是否需要 LLM 评分 |
|---|---|---|---|
| **检索层** | Recall@K、Precision@K、MRR、nDCG@K、Hit Rate | 该找到的文档找到了吗？排序对吗？ | 否（需要标注） |
| **生成层** | Faithfulness、Answer Relevancy、Context Precision、Context Recall | 答案有依据吗？切题吗？ | 部分是 |
| **端到端** | 准确率、拒答率、引用正确率、平均延迟、单次成本 | 用户满意吗？值这个钱吗？ | 是 |

**关键原则：改检索参数时看检索层，改 prompt 时看生成层，做版本发布时看端到端。**

只看端到端，会导致「检索变差 + 生成变强」互相抵消，你以为是没变化。

---

## 二、RAGAS 四个核心指标，到底在算什么

RAGAS（Retrieval Augmented Generation Assessment）在 2023 年提出时是四个指标，也是目前工业界引用最多的定义。下面逐个拆开，包括公式和它**测不出来的东西**。

### 2.1 Faithfulness（忠实度）

**定义**：答案中的每一个「论断（claim）」，是否都能在检索到的上下文里找到支撑。

**计算**：

```
Faithfulness = 被上下文支撑的论断数 / 答案中的论断总数
```

实现分两步（都是 LLM 做的）：

1. **拆论断**：把 answer 拆成原子陈述。例如「Spring AI 1.0 于 2025 年发布，支持 Advisor 机制」→ `["Spring AI 1.0 于 2025 年发布", "Spring AI 1.0 支持 Advisor 机制"]`。
2. **逐条验证**：对每个论断，判断 `context` 是否蕴含它（输出 1/0）。

**它测什么**：幻觉。答案有没有编造上下文里没有的东西。

**它测不出什么**：

- 上下文本身就是错的（检索到了错误文档，答案忠实于错误文档 → 高分，但答案是错的）；
- 答案不完整（只说了 1 条，漏了 9 条 → 仍然高分）。

⚠️ 所以 Faithfulness **必须和 Context Recall 一起看**。单看 Faithfulness，一个「只说废话但每句都有依据」的系统能拿满分。

### 2.2 Answer Relevancy（答案相关性）

**定义**：答案是否切题。RAGAS 的实现很巧妙——它不直接判断「答案和问题像不像」，而是**用答案反推问题**：

1. 用 LLM 根据 answer 生成 N 个（默认 3 个）可能的问题；
2. 计算这些问题与原问题的 embedding 余弦相似度；
3. 取平均。

```
AnswerRelevancy = (1/N) × Σ cos(embed(q_i), embed(original_question))
```

**为什么这么设计**：直接比较答案和问题的 embedding 会偏向「用词相似」，而反推问题能捕捉语义。如果答案跑题，反推出来的问题就会和原问题差很远。

**它测不出什么**：正确性。「北京是中国的首都」和「北京是日本的首都」对「北京是哪国首都」这个问题的 relevancy 一样高。

**已知缺陷**：对「简洁答案」不友好。「42」这种回答反推不出有意义的问题，相似度会很低。所以 RAGAS 官方建议对短答案场景慎用，或者配合 Answer Correctness。

### 2.3 Context Precision（上下文精确率）

**定义**：检索到的上下文中，相关的内容是否排在前面。

计算是 **逐 k 加权的平均精度**：

```
ContextPrecision@K = (1/相关文档总数) × Σ_{k=1..K} [ Precision@k × rel(k) ]
```

其中 `rel(k)` 表示第 k 个 chunk 是否相关（1/0），`Precision@k` 是前 k 个里相关 chunk 的占比。

举例：Top-4 的相关性为 `[1, 0, 1, 0]`：

- k=1: Precision@1 = 1/1 = 1，rel=1 → 贡献 1
- k=2: Precision@2 = 1/2，rel=0 → 贡献 0
- k=3: Precision@3 = 2/3，rel=1 → 贡献 0.667
- k=4: Precision@4 = 2/4，rel=0 → 贡献 0
- 总和 = 1.667，相关文档数 = 2 → **ContextPrecision = 0.833**

注意：如果相关性是 `[0, 1, 1, 0]`，结果会变成 (0.5 + 0.667)/2 = 0.583。**同样的相关文档，排序不同，分数差 30%**。这就是这个指标的价值——它惩罚「把不相关的东西排前面」。

### 2.4 Context Recall（上下文召回率）

**定义**：参考答案（ground truth）里的信息，有多少能被检索到的上下文覆盖。

```
ContextRecall = 能被上下文支撑的 ground_truth 论断数 / ground_truth 论断总数
```

它**必须有标注的参考答案**，是四个指标里唯一强依赖人工标注的。

**它测什么**：检索器有没有漏。这是 RAG 最常见的失败模式——答案错不是因为模型笨，是因为根本没检索到关键文档。

### 2.5 四个指标的关系图

```
                  检索到的上下文
                        │
        ┌───────────────┴───────────────┐
        │                               │
   Context Precision              Context Recall
   （排得靠前吗）                  （漏没漏）
        │                               │
        └───────────────┬───────────────┘
                        │
                   生成的答案
                        │
        ┌───────────────┴───────────────┐
        │                               │
   Faithfulness                  Answer Relevancy
   （有依据吗）                    （切题吗）
```

**排查口诀**：

- Faithfulness 低 → 模型幻觉，改 prompt / 降温度 / 加引用约束；
- Context Recall 低 → 检索漏，改切分 / 加混合检索 / 提 top-k；
- Context Precision 低 → 排序差，加重排模型；
- Answer Relevancy 低 → prompt 跑偏，改指令 / 加 few-shot。

---

## 三、黄金集：评测的地基

没有黄金集，上面所有指标都是空中楼阁。

### 3.1 规模与构成

经验值：**100~300 条**足够做回归，不必上千。关键是分布要对。

| 类型 | 占比 | 示例 | 考察点 |
|---|---|---|---|
| **单跳事实** | 40% | 「退款多久到账？」 | 基础检索 |
| **多跳推理** | 20% | 「A 产品的退货政策适用于 B 产品吗？」 | 跨文档检索 |
| **需要聚合** | 15% | 「今年有哪些政策变更？」 | 多 chunk 汇总 |
| **无法回答** | 15% | 「你们 CEO 的生日是哪天？」 | 拒答能力（重要！） |
| **对抗/诱导** | 10% | 「既然你们支持 90 天无理由退货…」 | 不被用户前提带偏 |

⚠️ **「无法回答」这一类最容易被忽略**。一个 RAG 系统如果把「不知道」硬答成一段编造内容，比直接说「文档中没有相关信息」危险十倍。评测必须能抓到这个。

### 3.2 数据从哪来

1. **真实用户日志**（最优）：从线上 query 里采样，脱敏后人工标注答案和支撑文档。
2. **业务专家出题**：让客服/法务/产品各自出 30 题，覆盖他们的高频场景。
3. **合成数据**（补充）：用 LLM 从文档反向生成 QA 对。速度快，但有两个问题：生成的答案偏向「文档里的表述」，会高估检索效果；问题风格单一。

**合成数据的正确用法**：只用来扩充「单跳事实」这一类，多跳和无法回答必须人工。而且合成后要人工抽检 20%。

### 3.3 黄金集的格式

```json
{
  "id": "q-0012",
  "question": "企业版支持 SSO 单点登录吗？支持哪些协议？",
  "ground_truth": "支持。企业版支持 SAML 2.0 和 OIDC 两种协议，需要在管理后台配置 IdP 元数据。",
  "ground_truth_contexts": [
    "doc-enterprise-features#sso",
    "doc-admin-sso-config#protocols"
  ],
  "type": "multi_hop",
  "difficulty": "medium",
  "tags": ["enterprise", "security"],
  "must_not_say": ["不支持", "仅支持 OAuth2 密码模式"]
}
```

`ground_truth_contexts` 是关键——它是 Context Recall 的计算依据。用**文档 ID + 段落锚点**，不要用文本片段（文档一改就失效）。

---

## 四、Java 落地：不用 Python 也能算 RAGAS

### 4.1 依赖

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-model-openai</artifactId>
</dependency>
<dependency>
    <groupId>org.junit.jupiter</groupId>
    <artifactId>junit-jupiter-params</artifactId>
    <scope>test</scope>
</dependency>
```

### 4.2 检索层指标（纯计算，不需要 LLM）

这部分应该用**确定性算法**，因为便宜、稳定、可复现。

```java
public final class RetrievalMetrics {

    /** Recall@K：相关文档中被召回的比例 */
    public static double recallAtK(List<String> retrievedIds, Set<String> relevantIds, int k) {
        if (relevantIds.isEmpty()) return 1.0;
        Set<String> topK = new HashSet<>(retrievedIds.subList(0, Math.min(k, retrievedIds.size())));
        long hit = relevantIds.stream().filter(topK::contains).count();
        return (double) hit / relevantIds.size();
    }

    /** Precision@K */
    public static double precisionAtK(List<String> retrievedIds, Set<String> relevantIds, int k) {
        if (k == 0) return 0;
        int size = Math.min(k, retrievedIds.size());
        if (size == 0) return 0;
        long hit = retrievedIds.subList(0, size).stream().filter(relevantIds::contains).count();
        return (double) hit / size;
    }

    /** MRR：第一个相关文档的排名倒数 */
    public static double reciprocalRank(List<String> retrievedIds, Set<String> relevantIds) {
        for (int i = 0; i < retrievedIds.size(); i++) {
            if (relevantIds.contains(retrievedIds.get(i))) {
                return 1.0 / (i + 1);
            }
        }
        return 0.0;
    }

    /** nDCG@K：考虑排序位置的增益 */
    public static double ndcgAtK(List<String> retrievedIds, Set<String> relevantIds, int k) {
        double dcg = 0;
        for (int i = 0; i < Math.min(k, retrievedIds.size()); i++) {
            if (relevantIds.contains(retrievedIds.get(i))) {
                dcg += 1.0 / (Math.log(i + 2) / Math.log(2));   // log2(i+2)
            }
        }
        double idcg = 0;
        int ideal = Math.min(k, relevantIds.size());
        for (int i = 0; i < ideal; i++) {
            idcg += 1.0 / (Math.log(i + 2) / Math.log(2));
        }
        return idcg == 0 ? 0 : dcg / idcg;
    }

    /** Context Precision：RAGAS 的加权平均精度 */
    public static double contextPrecision(List<Boolean> relevanceInRankOrder) {
        int totalRelevant = (int) relevanceInRankOrder.stream().filter(Boolean::booleanValue).count();
        if (totalRelevant == 0) return 0;

        double sum = 0;
        int hits = 0;
        for (int k = 0; k < relevanceInRankOrder.size(); k++) {
            if (relevanceInRankOrder.get(k)) {
                hits++;
                sum += (double) hits / (k + 1);
            }
        }
        return sum / totalRelevant;
    }
}
```

### 4.3 用 LLM 当裁判：Faithfulness

这是最需要小心的地方。**LLM-as-Judge 的输出必须结构化、可校验、可复现**。

```java
@Service
@RequiredArgsConstructor
public class FaithfulnessEvaluator {

    private final ChatClient chatClient;
    private final ObjectMapper objectMapper;

    private static final String SYSTEM = """
        你是一个严格的评审员。你的任务是判断【答案】中的每一条论断是否有【上下文】支撑。

        规则：
        1. 把答案拆成原子论断，每条只包含一个事实。
        2. 对每条论断，判断上下文是否明确支持它。上下文没提到 = 不支持（不要用常识推断）。
        3. 只输出 JSON，不要任何解释文字。
        4. 严格按以下格式输出：
        {"claims":[{"text":"...","supported":true,"evidence":"上下文中的原文片段"}]}
        """;

    public FaithfulnessResult evaluate(String question, List<String> contexts, String answer) {
        String user = """
            【上下文】
            %s

            【问题】
            %s

            【答案】
            %s
            """.formatted(String.join("\n---\n", contexts), question, answer);

        String raw = chatClient.prompt()
                .system(SYSTEM)
                .user(user)
                .options(ChatOptions.builder()
                        .temperature(0.0)          // 评判必须确定性
                        .build())
                .call()
                .content();

        JudgeOutput out = parseLeniently(raw);
        if (out == null || out.claims().isEmpty()) {
            return new FaithfulnessResult(Double.NaN, List.of(), "judge_output_invalid");
        }

        long supported = out.claims().stream().filter(Claim::supported).count();
        double score = (double) supported / out.claims().size();
        return new FaithfulnessResult(score, out.claims(), null);
    }

    /** LLM 偶尔会包 ```json 或加前后缀，解析要宽容 */
    private JudgeOutput parseLeniently(String raw) {
        try {
            int start = raw.indexOf('{');
            int end = raw.lastIndexOf('}');
            if (start < 0 || end <= start) return null;
            return objectMapper.readValue(raw.substring(start, end + 1), JudgeOutput.class);
        } catch (Exception e) {
            return null;
        }
    }

    public record Claim(String text, boolean supported, String evidence) {}
    public record JudgeOutput(List<Claim> claims) {}
    public record FaithfulnessResult(double score, List<Claim> claims, String error) {}
}
```

三个必须做的工程处理：

1. **`temperature = 0`**。评判要可复现，同样的输入必须给同样的分。
2. **宽容解析**。模型会输出 ```json 包裹、会加「好的，以下是分析」前缀。直接 `readValue` 会崩。
3. **失败要显式返回 NaN，不要返回 0**。0 分会让平均值失真，NaN 会被统计时跳过并计数。

### 4.4 Context Recall：需要 ground truth

```java
public double contextRecall(String groundTruth, List<String> contexts) {
    // 1) 把 ground truth 拆成论断
    List<String> claims = extractClaims(groundTruth);
    if (claims.isEmpty()) return Double.NaN;

    // 2) 逐条判断是否能被 contexts 支撑（一次调用批量判断，省钱）
    String prompt = """
        判断下面每条【论断】是否能被【上下文】支撑。
        只输出 JSON: {"results":[{"index":0,"supported":true}]}
        上下文没明确提到就算 false。

        【上下文】
        %s

        【论断】
        %s
        """.formatted(String.join("\n---\n", contexts), numbered(claims));

    JudgeBatch out = callAndParse(prompt, JudgeBatch.class);
    long supported = out.results().stream().filter(R::supported).count();
    return (double) supported / claims.size();
}
```

⚠️ **注意区分 Faithfulness 和 Context Recall 的方向**：

- Faithfulness：answer 的论断 → 能否被 context 支撑（测幻觉）；
- Context Recall：ground_truth 的论断 → 能否被 context 支撑（测漏检）。

两个都是「论断被支撑的比例」，但**被检验的对象不同**。写错方向是很常见的实现 bug。

---

## 五、接进 CI：让评测变成回归测试

评测不能只在本地跑一次，要进流水线。

### 5.1 JUnit 5 参数化 + 阈值断言

```java
@SpringBootTest
@ActiveProfiles("eval")
class RagRegressionTest {

    @Autowired RagPipeline pipeline;
    @Autowired FaithfulnessEvaluator faithfulness;
    @Autowired GoldenSetLoader loader;

    private static final double MIN_FAITHFULNESS = 0.85;
    private static final double MIN_RECALL_AT_5  = 0.80;
    private static final double MIN_CONTEXT_PRECISION = 0.70;

    @ParameterizedTest(name = "[{index}] {0}")
    @MethodSource("goldenSet")
    void eachQuestionShouldBeFaithful(GoldenCase c) {
        RagResult result = pipeline.answer(c.question());

        // 1) 检索层：必须命中标注的文档
        double recall = RetrievalMetrics.recallAtK(
                result.retrievedDocIds(), Set.copyOf(c.groundTruthContexts()), 5);
        assertThat(recall)
                .as("Recall@5 for: %s", c.question())
                .isGreaterThanOrEqualTo(MIN_RECALL_AT_5);

        // 2) 无法回答的题：必须拒答，不能编
        if (c.type() == CaseType.UNANSWERABLE) {
            assertThat(result.answer())
                    .as("should refuse: %s", c.question())
                    .containsAnyOf("没有找到", "文档中未提及", "无法回答");
            return;
        }

        // 3) 生成层：忠实度
        FaithfulnessResult f = faithfulness.evaluate(
                c.question(), result.contexts(), result.answer());
        if (!Double.isNaN(f.score())) {
            assertThat(f.score())
                    .as("Faithfulness for: %s\nanswer=%s", c.question(), result.answer())
                    .isGreaterThanOrEqualTo(MIN_FAITHFULNESS);
        }
    }

    static Stream<GoldenCase> goldenSet() {
        return GoldenSetLoader.loadFromClasspath("golden/qa-v3.jsonl").stream();
    }
}
```

### 5.2 聚合报告：单条通过没用，要看整体

CI 里除了「逐条断言」，还必须输出**整体报告并和历史对比**。因为单条断言会让人为了过测试去「特调」某几条。

```java
@Test
void aggregateReportShouldNotRegress() throws IOException {
    List<GoldenCase> cases = GoldenSetLoader.loadFromClasspath("golden/qa-v3.jsonl");

    EvalSummary current = Evaluator.runAll(pipeline, cases);

    // 基线来自上一次 main 分支的评测结果（CI 产物）
    EvalSummary baseline = EvalSummary.load(Path.of("eval/baseline.json"));

    assertThat(current.faithfulness())
            .as("Faithfulness 相对基线下降不得超过 3 个百分点")
            .isGreaterThanOrEqualTo(baseline.faithfulness() - 0.03);

    assertThat(current.contextRecall())
            .as("Context Recall 不得下降超过 5 个百分点")
            .isGreaterThanOrEqualTo(baseline.contextRecall() - 0.05);

    assertThat(current.avgLatencyMs())
            .as("平均延迟不得上涨超过 20%")
            .isLessThan(baseline.avgLatencyMs() * 1.2);

    // 输出 Markdown 报告，贴到 PR 评论
    Files.writeString(Path.of("eval/report.md"), current.toMarkdown(baseline));
}
```

### 5.3 报告长什么样

| 指标 | 基线（main） | 本次（PR） | 变化 | 判定 |
|---|---|---|---|---|
| Faithfulness | 0.891 | 0.874 | -0.017 | ✅ 在容差内 |
| Answer Relevancy | 0.842 | 0.861 | +0.019 | ✅ |
| Context Precision | 0.731 | 0.688 | -0.043 | ⚠️ 关注 |
| Context Recall@5 | 0.856 | 0.902 | +0.046 | ✅ |
| 拒答准确率 | 0.933 | 0.933 | 0 | ✅ |
| 平均延迟 | 2.41s | 2.88s | +19.5% | ⚠️ 接近阈值 |
| 单次成本 | ¥0.0121 | ¥0.0148 | +22% | ❌ 超阈值 |

**这张表比任何「感觉好多了」都有说服力。** 而且它能直接暴露 trade-off：这次 PR 把 Recall 提上去了，但 Context Precision 掉了、成本涨了 22%——值不值，团队可以基于数据讨论。

---

## 六、LLM-as-Judge 的四个偏差与校准

用 LLM 评分，必须知道它会怎么骗你。

| 偏差 | 表现 | 缓解方法 |
|---|---|---|
| **位置偏差** | 成对比较时偏好第一个 | 交换顺序评两次，取一致结果；不一致记为 tie |
| **长度偏差** | 长答案得分更高 | prompt 里明确「长度不作为评价标准」；或对长度做回归校正 |
| **自我偏好** | GPT 评 GPT 的输出更高分 | 用不同家族的模型做 judge（比如被测是 A，judge 用 B） |
| **格式偏好** | 有 bullet point / markdown 的答案得分高 | 评测前统一去除格式，只留纯文本 |

### 6.1 校准流程

1. **人工标注 100 条**作为「金标准分数」；
2. 用 judge 跑同样的 100 条，算 **与人工的 Spearman 相关系数**；
3. 相关系数 < 0.7 → judge 不可用，要改 prompt 或换模型；
4. 0.7~0.85 → 可用于「趋势监控」，不可用于「绝对质量承诺」；
5. \> 0.85 → 可用于发布门禁。

⚠️ **必须人工抽检**。每周随机抽 10% 的 judge 结果人工复核，一旦发现漂移（供应商悄悄升级了模型），立即重跑校准。

---

## 七、六个踩过的坑

**坑 1：只测生成，不测检索。**
最典型的错误。团队花两周调 prompt，Faithfulness 从 0.82 涨到 0.91，很开心。但 Context Recall 只有 0.6——**40% 的问题根本没检索到正确文档**，prompt 调得再好也没用。先修检索，再修生成。

**坑 2：黄金集泄漏进 prompt。**
把评测题的例子写进 few-shot，分数虚高 15 个点。上线后原形毕露。**评测集必须和 prompt 素材物理隔离**，最好放在不同的仓库/目录，并有 code review 检查。

**坑 3：指标之间冲突时不知道信谁。**
Context Precision 涨了但 Faithfulness 跌了，通常是「重排把短小精悍的 chunk 排前面了，但关键信息被切掉了」。这时候要看**端到端准确率**做仲裁，而不是纠结单个指标。

**坑 4：样本太少，波动大于改进。**
50 条样本，准确率从 0.72 到 0.76，你以为提升了，其实置信区间重叠得厉害。**样本 < 100 时，只报置信区间，不报点估计**。用 Wilson 区间算一下就知道差异是否显著。

**坑 5：Judge 的成本被忽略。**
一次完整评测（200 题 × 4 指标）大约要 800~1200 次 LLM 调用，用 GPT-4o 跑一次几十块。每天跑三次，一个月就是几千块。**用便宜模型做初筛（如 4o-mini），只对边界样本用强模型复判**。

**坑 6：只跑一次，不做基线管理。**
评测的价值在于**对比**。没有基线，0.87 这个数字毫无意义。基线要跟着代码版本走，每次 main 合并自动更新，PR 里对比。

---

## 八、面试高频追问

**Q1：RAG 效果不好，你怎么定位？**
先看 Context Recall。如果低，问题在检索（切分、embedding、top-k、混合检索）。如果 Recall 高但 Faithfulness 低，问题在生成（prompt 没约束「只根据上下文回答」、温度太高、上下文太长导致中间信息丢失）。如果两者都高但用户不满意，看 Answer Relevancy 和端到端准确率，可能是问题理解偏了。

**Q2：Faithfulness 和 Context Recall 都是「论断被支撑的比例」，区别是什么？**
被检验的对象不同。Faithfulness 检验的是**模型生成的答案**里的论断（测幻觉）；Context Recall 检验的是**人工标注的参考答案**里的论断（测检索漏检）。前者分母来自 answer，后者分母来自 ground truth。

**Q3：没有人工标注，能做 RAG 评测吗？**
能做一部分。检索层可以用「合成 QA + 文档 ID」自动构造；Faithfulness 和 Answer Relevancy 不需要 ground truth；但 Context Recall 和端到端准确率必须有标注。完全无标注的评测只能做「相对比较」（A 版本 vs B 版本），不能给绝对质量承诺。

**Q4：为什么 Answer Relevancy 要「反推问题」而不是直接算相似度？**
直接算 answer 和 question 的 embedding 相似度，会被「词汇重叠」主导。反推问题相当于让模型先理解答案的语义，再映射回问题空间，能更好地捕捉「答非所问」。副作用是对超短答案不友好。

**Q5：RAGAS 的指标能直接用于上线门禁吗？**
不能直接用。RAGAS 是研究导向的指标，和业务满意度有相关性但没有校准过的映射。上线门禁应该用「业务定义的准确率」+ 人工抽检，RAGAS 指标用于**趋势监控和回归检测**。

**Q6：怎么评估「拒答」能力？**
黄金集里单列一类「无法回答」的问题（答案不在知识库里），期望系统明确说「文档中未找到」。指标用「拒答准确率」= 正确拒答数 / 无法回答题数，同时要监控「误拒率」= 本可回答却拒答的比例。两个指标要一起看，否则系统会退化成「什么都不答」。

---

## 九、总结

- **RAG 评测必须分层**：检索层（Recall/MRR/nDCG）、生成层（Faithfulness/Relevancy）、端到端（准确率/拒答率/成本）。只看一个数，等于没测。
- **RAGAS 四指标各有盲区**：Faithfulness 测不出上下文本身错，Answer Relevancy 测不出事实错，Context Precision 依赖相关性判定，Context Recall 必须有标注。组合使用，别单点崇拜。
- **黄金集 100~300 条**，必须包含「无法回答」和「多跳」两类，合成数据只能补充单跳。
- **Java 完全能落地**：检索指标用确定性算法，生成指标用 LLM-as-Judge + 结构化输出 + 温度 0。
- **评测要进 CI**：逐条断言防退化，聚合报告看趋势，基线随 main 更新。
- **Judge 需要校准**：位置/长度/自我/格式四个偏差，用交换顺序、跨家族模型、人工抽检来压。

RAG 的调优是一场「多目标优化」：召回、精确、忠实、延迟、成本互相拉扯。没有评测，你只是在黑暗里调参；有了评测，你至少知道自己在往哪个方向走。
