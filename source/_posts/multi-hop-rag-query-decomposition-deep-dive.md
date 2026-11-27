---
title: 【RAG 进阶】多跳检索与查询分解深度解析：子问题拆解、证据聚合与充分性判断
date: 2026-11-27 08:20:00
tags:
  - AI
  - RAG
  - 多跳检索
  - 查询分解
  - Spring AI
categories:
  - RAG
author: 东哥
---

# 【RAG 进阶】多跳检索与查询分解深度解析：子问题拆解、证据聚合与充分性判断

## 前言

单跳 RAG 跑通之后，很多团队会撞上同一堵墙：**简单问题答得不错，稍微复杂一点就开始胡说。**

三个真实案例：

- 用户问："我们和竞品 X 的退款政策有什么差异？" —— 单跳检索把"我们"的政策和"竞品 X"的政策各召回一半，模型只答了一边。
- 用户问："上季度营收增长最快的那个事业部的负责人是谁？" —— 需要先查"哪个事业部增长最快"，再查"负责人"，一次检索根本拿不到两个事实。
- 用户问："列出所有同时满足 A 条件、B 条件、C 条件的客户" —— 三个条件分散在三份文档里，top-k=5 只能覆盖其中两个。

这三类问题的共同点是：**答案不在任何一个 chunk 里，而在"多个 chunk 的组合"里。** 这就是多跳（multi-hop）问题。

单跳 RAG 的隐含假设是"答案存在于某个片段"，一旦问题需要串联，这个假设就崩了。本文讲清楚：多跳问题怎么分类、三条技术路线怎么选、Java 侧怎么实现、以及最容易被忽略的"充分性判断"。

---

## 一、先把问题分类：不是所有"难问题"都需要多跳

盲目上多跳的代价很高：一次分解 = 多一次 LLM 调用 + N 次检索，成本翻 3~5 倍，延迟翻倍。所以第一步是**判断这个问题到底属于哪一类**。

| 类型 | 特征 | 例子 | 需要的能力 |
|---|---|---|---|
| 单跳事实 | 一个事实点 | "退款时效是几天？" | 普通 top-k |
| **桥接（bridge）** | A 的答案是指向 B 的线索 | "张三是哪个部门的？他汇报给谁？" | 先查 A，再用 A 的结果查 B |
| **对比（comparison）** | 两个实体、同一维度 | "A 和 B 的定价差异" | 分别检索，对齐维度后比较 |
| **聚合（aggregation）** | 满足多个条件的集合 | "哪些客户同时满足 X 和 Y" | 多条件分别检索 + 集合运算 |
| **时间推理** | 需要按时间线串联 | "在他离职前，最后一个项目是什么" | 实体 + 时间约束联合过滤 |
| 开放式 | 需要多视角综合 | "如何设计一个高可用架构" | 多查询扩展 + 长上下文 |

### 1.1 一个廉价的分类器

不需要微调模型，用一个 Prompt + 规则就能做到 90% 准确率：

```java
public enum QueryType { SINGLE_HOP, BRIDGE, COMPARISON, AGGREGATION, TEMPORAL }

public QueryType classify(String query) {
    // 规则先兜底：零成本、零延迟
    if (containsAny(query, "和", "与", "对比", "差异", "vs", "versus")) {
        return QueryType.COMPARISON;
    }
    if (containsAny(query, "哪些", "列出", "所有", "同时满足")) {
        return QueryType.AGGREGATION;
    }
    if (containsAny(query, "之前", "之后", "期间", "最后")) {
        return QueryType.TEMPORAL;
    }
    // 规则命中不了再走模型（或直接按单跳处理）
    return QueryType.SINGLE_HOP;
}
```

工程上更稳的做法：**先用规则拦掉明显的单跳**，只把 20%~30% 的"疑似多跳"交给 LLM 分类。这样既省成本，又避免了"把所有问题都拆成四个子问题"的过度分解。

---

## 二、三条技术路线

### 2.1 路线一：一次性分解（Query Decomposition）

最直观：让 LLM 把问题拆成若干**自包含**的子问题，并行检索，最后合并证据生成答案。

```
原问题：上季度营收增长最快的那个事业部的负责人是谁？
  ├─ SQ1: 上季度各事业部的营收及增长率是多少？
  ├─ SQ2: 根据 SQ1，哪个事业部增长最快？   (dependsOn: SQ1)
  └─ SQ3: 该事业部的负责人是谁？            (dependsOn: SQ2)
```

- 优点：结构清晰、可并行、可缓存（子问题级）；
- 缺点：分解质量完全依赖 LLM，一旦拆错，后面全错；
- 适合：桥接、对比、聚合类。

### 2.2 路线二：迭代式（IRCoT / Self-Ask）

边检索边推理：每一步基于"已获得的证据"生成下一个查询。

```
Step 1: 检索"上季度事业部营收" → 得到 A 事业部增长 45%
Step 2: 基于证据问"增长最快的是 A 事业部，它的负责人是谁" → 检索
Step 3: 判断证据是否足够 → 足够则回答
```

- 优点：每一步都有真实证据支撑，比"闭眼分解"更准；
- 缺点：串行，延迟 = 步数 × (检索 + LLM)，成本高；
- 适合：桥接类、需要多轮澄清的问题。

### 2.3 路线三：Agentic RAG

把检索、计算、比对都做成工具，由 Agent 自主决定调用顺序。

- 优点：最灵活，能处理"需要查数据库 + 查文档 + 算数"的混合任务；
- 缺点：不可控、成本最高、评测困难；
- 适合：开放式研究型任务（Deep Research）。

### 2.4 怎么选

| 维度 | 一次性分解 | 迭代式 | Agentic |
|---|---|---|---|
| 延迟 | 低（并行） | 中（串行） | 高 |
| 成本 | 中 | 中高 | 高 |
| 准确率（多跳） | 中 | 高 | 高 |
| 可控性 | 高 | 中 | 低 |
| 实现复杂度 | 低 | 中 | 高 |
| 推荐场景 | 对比/聚合 | 桥接 | 研究型 |

**我的建议：以"一次性分解"为主干，对依赖链上的关键子问题用"迭代式"补一次充分性判断。** 纯 Agentic 留给明确需要它的产品线（如 Deep Research），不要作为默认架构。

---

## 三、Java 实现：从分解到生成

下面用 Spring AI 写一条完整链路。

### 3.1 分解：强类型 + 结构校验

不要让 LLM 输出自由文本，一定要结构化，并且**校验 DAG 合法性**：

```java
public record SubQuery(
    String id,              // sq1, sq2...
    String question,        // 必须自包含（不能有"它/该部门"这类指代）
    List<String> dependsOn, // 依赖的子问题 id
    String retrievalHint    // 检索提示：用哪些关键词/哪些数据源
) {}

public record Decomposition(
    QueryType type,
    List<SubQuery> subQueries,
    boolean needsDecomposition
) {}
```

```java
@Service
public class QueryDecomposer {

    private final ChatClient chatClient;
    private final BeanOutputConverter<Decomposition> converter =
        new BeanOutputConverter<>(Decomposition.class);

    private static final String PROMPT = """
        你是查询规划器。判断用户问题是否需要拆分为多个子问题。

        规则：
        1. 如果一个问题可以在单个文档片段中回答，needsDecomposition=false，subQueries 只含原问题。
        2. 子问题数量最多 4 个，每个必须"自包含"——不能出现"它/该/这个/上述"等指代。
        3. dependsOn 只能引用前面已定义的子问题 id，禁止循环依赖。
        4. retrievalHint 写检索时应该用的关键词（不要写完整句子）。

        用户问题：%s

        输出 JSON，格式：
        {format}
        """;

    public Decomposition decompose(String query, QueryType type) {
        String raw = chatClient.prompt()
            .user(PROMPT.formatted(query, converter.getFormat()))
            .call().content();

        Decomposition d = converter.convert(raw);
        return validate(d, query);
    }

    private Decomposition validate(Decomposition d, String original) {
        if (d == null || d.subQueries() == null) {
            return new Decomposition(QueryType.SINGLE_HOP,
                List.of(new SubQuery("sq1", original, List.of(), original)), false);
        }
        // 1) 数量上限
        List<SubQuery> subs = d.subQueries().stream().limit(4).toList();
        // 2) id 唯一 + 依赖存在 + 无环
        Set<String> ids = subs.stream().map(SubQuery::id).collect(Collectors.toSet());
        if (ids.size() != subs.size()) {
            throw new IllegalStateException("duplicate sub-query id");
        }
        for (SubQuery s : subs) {
            for (String dep : s.dependsOn()) {
                if (!ids.contains(dep)) {
                    throw new IllegalStateException("unknown dependency: " + dep);
                }
            }
        }
        assertAcyclic(subs);
        // 3) 指代检测：含指代词则回退为单跳（宁可不拆，不要拆错）
        boolean hasReference = subs.stream()
            .anyMatch(s -> containsAny(s.question(), "它", "该", "这个", "上述", "其"));
        if (hasReference) {
            return new Decomposition(QueryType.SINGLE_HOP,
                List.of(new SubQuery("sq1", original, List.of(), original)), false);
        }
        return new Decomposition(d.type(), subs, subs.size() > 1);
    }

    private void assertAcyclic(List<SubQuery> subs) {
        Map<String, List<String>> graph = subs.stream()
            .collect(Collectors.toMap(SubQuery::id, SubQuery::dependsOn));
        Set<String> visiting = new HashSet<>(), done = new HashSet<>();
        for (String id : graph.keySet()) dfs(id, graph, visiting, done);
    }

    private void dfs(String id, Map<String, List<String>> g,
                     Set<String> visiting, Set<String> done) {
        if (done.contains(id)) return;
        if (!visiting.add(id)) throw new IllegalStateException("cycle at " + id);
        for (String dep : g.getOrDefault(id, List.of())) dfs(dep, g, visiting, done);
        visiting.remove(id);
        done.add(id);
    }
}
```

**为什么要做这些校验？** 因为 LLM 输出的 DAG 有 5%~15% 的概率不合法（循环依赖、引用不存在的 id、子问题含指代）。线上如果没有校验，一次非法输出就会让整个请求 500，或者更糟——静默地检索了错误的内容。

### 3.2 调度：按层并行

依赖关系天然是一个 DAG，按拓扑层调度：同层并行，跨层串行。

```java
@Service
public class MultiHopRetriever {

    private final ChatClient chatClient;
    private final VectorStore vectorStore;
    private final Semaphore retrievalPermits = new Semaphore(16);

    public MultiHopResult retrieve(Decomposition d, String originalQuery) {
        Map<String, List<Document>> evidence = new ConcurrentHashMap<>();
        Map<String, String> answers = new ConcurrentHashMap<>();

        for (List<SubQuery> layer : topologicalLayers(d.subQueries())) {
            try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
                for (SubQuery sq : layer) {
                    scope.fork(() -> {
                        String enriched = enrichWithDependencies(sq, answers);
                        List<Document> docs = searchWithPermit(enriched, sq.retrievalHint());
                        evidence.put(sq.id(), docs);
                        // 桥接类：先用证据回答子问题，作为下一层的输入
                        if (needsIntermediateAnswer(sq, d.type())) {
                            answers.put(sq.id(), answerSubQuestion(sq, docs));
                        }
                        return null;
                    });
                }
                scope.join();
                scope.throwIfFailed();
            } catch (Exception e) {
                // 单层失败不整体失败：降级为单跳
                return fallbackSingleHop(originalQuery);
            }
        }
        return new MultiHopResult(d, evidence, answers);
    }

    private List<Document> searchWithPermit(String query, String hint) throws Exception {
        if (!retrievalPermits.tryAcquire(500, TimeUnit.MILLISECONDS)) {
            throw new RejectedExecutionException("retrieval queue full");
        }
        try {
            SearchRequest req = SearchRequest.builder()
                .query(hint == null || hint.isBlank() ? query : hint)
                .topK(6)
                .similarityThreshold(0.35)
                .build();
            return vectorStore.similaritySearch(req);
        } finally {
            retrievalPermits.release();
        }
    }
}
```

三个关键点：

1. **`StructuredTaskScope`**（Java 21 预览 / 后续版本转正）让"同层并行 + 任一失败即取消"变得非常简单；如果用 Java 17，换成 `CompletableFuture.allOf` + 手动取消；
2. **信号量保护向量库**：4 个子问题 × 每租户并发 = 向量库被打爆，这是多跳 RAG 最常见的容量事故；
3. **单层失败降级为单跳**，而不是整个请求失败——多跳是"增强"，不是"必需"。

### 3.3 证据聚合：按子问题分组，别一锅炖

最容易被忽略的一步。把 N 个子问题的检索结果直接拼成一个长上下文，会有两个问题：

- 模型不知道哪段证据对应哪个子问题，容易张冠李戴；
- 某个子问题召回 6 段、另一个只有 1 段，上下文预算被前一个吃掉。

正确做法是**按子问题分组 + 配额 + 组内重排**：

```java
public String assembleContext(MultiHopResult result, int totalTokenBudget) {
    int perSubQuery = totalTokenBudget / result.decomposition().subQueries().size();

    StringBuilder sb = new StringBuilder();
    for (SubQuery sq : result.decomposition().subQueries()) {
        List<Document> docs = dedup(result.evidence().get(sq.id()));

        sb.append("\n### 子问题 ").append(sq.id()).append("：")
          .append(sq.question()).append("\n");

        int used = 0;
        int rank = 0;
        for (Document doc : docs) {
            int tokens = estimateTokens(doc.getText());
            if (used + tokens > perSubQuery) break;
            used += tokens;
            // 证据编号带子问题前缀，生成时可精确引用
            sb.append("[S").append(sq.id()).append("-").append(++rank).append("] ")
              .append(doc.getText()).append("\n");
        }
    }
    return sb.toString();
}
```

生成 Prompt 里加一条硬约束：

```
只能使用标注了编号的证据作答，每个结论后面必须紧跟引用编号，如 [Ssq2-1]。
如果某个子问题没有找到证据，明确说"未找到关于 X 的信息"，禁止推测。
```

### 3.4 充分性判断：别让模型"证据不足硬答"

多跳最容易出的错不是"检索不到"，而是"检索到一半就作答"。加一个轻量的充分性检查：

```java
public record Sufficiency(boolean enough, List<String> missing, String nextQuery) {}

public Sufficiency check(String question, String context) {
    String raw = chatClient.prompt()
        .system("""
            判断给定证据是否足以回答用户问题。
            - 若足够：enough=true。
            - 若不足：enough=false，并指出缺失的信息点（missing），
              以及下一步应该检索什么（nextQuery，必须是自包含的查询）。
            不要评价答案质量，只判断证据覆盖度。
            """)
        .user("问题：" + question + "\n证据：\n" + context)
        .call().content();
    return converter.convert(raw);
}
```

执行策略：

```
生成前检查 → 不足 → 补检索（最多 1~2 轮）→ 仍不足 → 分级弃答
```

分级弃答比"硬答"体验好得多：

| 情况 | 回复策略 |
|---|---|
| 部分子问题有证据 | 回答有证据的部分，明确标注"关于 X 未找到信息" |
| 全部无证据 | "知识库中没有找到相关内容，建议补充 XXX 文档或联系 XXX" |
| 证据冲突 | 列出两种说法及来源，提示人工确认 |

---

## 四、五个高频坑

### 4.1 过度分解

**现象**：单跳问题被拆成 4 个子问题，成本 ×4，准确率反而下降（噪声变多）。

**根因**：分解 Prompt 没有"不分解"的出口，模型倾向于"表现得很努力"。

**解法**：
- Prompt 里明确 `needsDecomposition=false` 是合法且常见的选择；
- 用规则先拦掉 70% 的简单问题；
- 加一个"分解收益评估"：如果子问题之间没有依赖、且都能被原问题直接检索到，就不拆。

### 4.2 子问题不自包含

**现象**：SQ2 写成"该部门的负责人是谁"，检索时"该部门"没有指代对象，召回了所有部门的负责人。

**解法**：分解前先做一次 **standalone 改写**（把多轮对话中的指代补全），分解时强校验指代词；发现指代就回退单跳，而不是硬拆。

### 4.3 融合丢归属

**现象**：用 RRF 把所有子问题的结果混成一个列表，生成时模型不知道哪段支持哪个子问题，引用错乱。

**解法**：**组内融合，组间隔离**。RRF 只在同一个子问题的多路召回之间做，不要跨子问题混。

### 4.4 上下文顺序

**现象**：关键证据放在中间，模型"看不见"（Lost in the Middle）。

**解法**：
- 每个子问题内，最高分的证据放最前；
- 整体上，把"最可能包含答案"的子问题组放首尾；
- 总上下文控制在模型窗口的 50%~60%，别塞满。

### 4.5 并行打爆向量库

**现象**：上线后向量库 P99 从 30ms 涨到 2s，触发限流。

**根因**：单请求 4 路并行 × QPS 50 = 200 并发检索，而原来只有 50。

**解法**：
- 全局限流（信号量/令牌桶），按租户配额；
- 子问题级缓存（归一化后 hash），热点问题命中率能到 30%~50%；
- 向量库侧扩容 + 副本读。

---

## 五、评测：多跳必须单独评

用单跳的评测集评多跳，等于没评。需要三组指标：

### 5.1 端到端质量

| 指标 | 说明 |
|---|---|
| Answer EM / F1 | 与标准答案比对（适合事实型） |
| 人工/LLM-as-Judge 正确率 | 开放式问题必需，需校准 kappa ≥ 0.6 |
| 引用正确率 | 引用的证据是否真的支持该结论 |
| 弃答准确率 | 该弃答时弃答、不该弃答时不弃 |

### 5.2 检索质量（按跳拆开）

| 指标 | 说明 |
|---|---|
| Recall@k per hop | 第 N 跳是否召回了关键证据 |
| 子问题覆盖率 | 分解出的子问题是否覆盖了回答问题所需的全部信息 |
| 桥接准确率 | 桥接实体是否被正确识别并传递 |

### 5.3 成本与延迟

| 指标 | 单跳基线 | 多跳 |
|---|---|---|
| LLM 调用次数 | 1 | 2~3（分解 + 生成 + 可选充分性） |
| 检索次数 | 1 | 2~4 |
| P50 延迟 | 800ms | 1.8s |
| 单次成本 | 1× | 3~5× |

### 5.4 公开数据集

- **HotpotQA**：经典多跳桥接数据集；
- **2WikiMultiHopQA**：带证据句标注，适合评"支撑事实召回"；
- **MuSiQue**：多跳组合，抗"捷径"（防止模型靠单跳猜对）；
- 中文场景建议自建 100~300 条业务问题，标注"所需证据 + 跳数"，比公开集更有说服力。

**关键**：一定要有**单跳基线**。如果多跳只比单跳高 2 个点，成本却翻 4 倍，那就不该上。

---

## 六、成本优化：把多跳做成"按需"

多跳的成本结构决定了它必须是**分级策略**，而不是默认路径：

```
Level 0：缓存命中 → 直接返回（成本 0）
Level 1：单跳检索 + 生成（1×）
Level 2：分类器判断需要多跳 → 分解 + 并行检索（3×）
Level 3：充分性不足 → 补检索一轮（4×）
Level 4：仍不足 → 降级/弃答/转人工（不增加 LLM 成本）
```

四个降本手段：

1. **子问题缓存**：子问题归一化后做 hash，相同子问题直接复用证据（多跳场景命中率很高，因为桥接实体是收敛的）；
2. **小模型做分解**：分解是"规划"任务，不需要最强模型，用小模型可省 60%~80% 的分解成本；
3. **检索结果缓存**：同一租户 + 同一知识库版本 + 同一 query，TTL 5~10 分钟；
4. **提前退出**：如果第一个子问题就没检索到，直接弃答，不要继续跑后面三跳。

---

## 七、面试高频追问

**Q1：多跳 RAG 和 Agentic RAG 的区别？**
多跳 RAG 是"预先规划好子问题再检索"（计划驱动），路径在生成前确定；Agentic RAG 是"由 Agent 根据中间结果自主决定下一步动作"（反应驱动）。前者可控、可并行、成本可预测；后者灵活但难评测、成本高。

**Q2：怎么判断一个问题需要多跳？**
看答案是否需要"多个事实的组合"。工程上用规则 + 小模型分类：对比/聚合/桥接词触发，其余按单跳处理。核心是保留"不分解"的出口，避免过度分解。

**Q3：子问题之间怎么保证顺序？**
用 DAG 表达依赖，按拓扑层调度：同层并行、跨层串行。每层结束后把上游的中间答案注入下游子问题的检索 query，实现"桥接"。

**Q4：分解出来的子问题检索不到怎么办？**
先做充分性判断，不足则用改写后的 nextQuery 补检索一轮；仍不足则分级弃答（部分回答 + 明确缺失项），绝不硬答。同时记录"缺失信息点"，反哺知识库建设。

**Q5：多跳的效果怎么评？**
三层：端到端（EM/F1/Judge/引用正确率）、检索（每跳 Recall@k、子问题覆盖率）、成本（调用次数/延迟）。必须有单跳基线做对照，否则无法证明多跳的收益。

---

## 八、总结

多跳 RAG 的本质不是"多检索几次"，而是**把一个问题拆成一组可验证的子问题，并保证每一步都有证据支撑**。

四条落地原则：

1. **先分类再分解**——70% 的问题不需要多跳，别让成本默认翻四倍；
2. **分解必须结构化 + 校验**——DAG 无环、子问题自包含、数量上限，缺一不可；
3. **证据按子问题分组**——组内融合、组间隔离，生成时才能精确引用；
4. **充分性判断 + 分级弃答**——"没找到"是合格答案，"编一个"不是。

最后一句：单跳 RAG 拼的是检索质量，多跳 RAG 拼的是**编排质量**。前者靠好的 embedding 和切分，后者靠好的 DAG、预算和降级策略。
