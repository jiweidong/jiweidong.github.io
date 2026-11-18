---
title: 【系统设计】Deep Research 智能体架构设计：规划、并行检索、证据管理与引用校验
date: 2026-11-18 08:40:00
tags:
  - AI
  - Agent
  - 系统设计
  - Deep Research
  - Java
categories:
  - AI Agent
author: 东哥
---

# 【系统设计】Deep Research 智能体架构设计

## 前言

Deep Research 是过去一年最明确的 Agent 落地形态：用户给一个开放问题，系统自己去搜、去读、去交叉验证，最后产出一篇带引用的长报告。OpenAI、Google、Perplexity 都做了，国内大厂也都在跟进。

从工程角度看，它和「RAG 问答」完全不是一个东西：

| 维度 | 单轮 RAG 问答 | Deep Research |
|---|---|---|
| 检索次数 | 1 次（top-k） | 10~100+ 次，动态决定 |
| 上下文 | 一次装下 | 装不下，必须外置证据库 |
| 控制流 | 线性 | 规划 → 并行 → 综合 → 校验，带循环 |
| 输出 | 几百字 | 几千到几万字，带引用 |
| 耗时 | 2~5 秒 | 2~20 分钟 |
| 失败模式 | 答错 | 跑偏、循环、烧钱、引用造假 |
| 成本 | 0.01 元级 | 1~50 元级 |

成本差三个数量级，意味着**任何设计缺陷都会被放大**。一个「多搜两轮」的 bug，乘以每天 10 万次调用，就是几十万的账单。

这篇按「一条请求的完整生命周期」拆解架构，重点讲四个最容易做错的地方：规划、证据管理、上下文预算、引用校验。

---

## 一、整体架构

```
                    ┌─────────────────────────────────────────┐
用户问题 ──► 澄清 ──►│  1. Planner（问题分解 → 研究计划 DAG）    │
                    └───────────────┬─────────────────────────┘
                                    │ sub-questions[]
                    ┌───────────────▼─────────────────────────┐
                    │  2. Orchestrator（调度、预算、并发控制）  │
                    └───┬───────────┬───────────┬─────────────┘
                        │           │           │
                  ┌─────▼───┐ ┌─────▼───┐ ┌─────▼───┐
                  │Searcher │ │Searcher │ │Searcher │   ← 并行子代理
                  │  A      │ │  B      │ │  C      │
                  └─────┬───┘ └─────┬───┘ └─────┬───┘
                        │           │           │
                    ┌───▼───────────▼───────────▼─────────┐
                    │  3. Evidence Store（证据库 + 去重 + 打分）│
                    └───────────────┬─────────────────────┘
                                    │ 按章节检索证据
                    ┌───────────────▼─────────────────────────┐
                    │  4. Synthesizer（大纲 → 分节写作 → 合并） │
                    └───────────────┬─────────────────────────┘
                    ┌───────────────▼─────────────────────────┐
                    │  5. Verifier（引用覆盖、断言支撑、事实核查）│
                    └───────────────┬─────────────────────────┘
                                    ▼
                              报告 + 引用列表
```

五个角色，但**不是五个独立服务**——大部分团队用一个进程 + 状态机实现，只有检索和写作会拆成独立部署（因为模型配额不同）。

---

## 二、Planner：问题分解

### 2.1 为什么不能直接让模型「边搜边想」

ReAct 风格的「思考 → 搜索 → 观察 → 再思考」在短任务上很好，但长任务上有两个致命问题：

1. **没有全局视野**：搜到第三个网页时已经忘了最初要回答什么，容易跑偏；
2. **串行太慢**：10 次搜索串行 = 10 × (搜索 1s + 阅读 2s + 思考 1s) = 40 秒起步。

Planner 的作用是**先想清楚要查什么，再并行去查**。

### 2.2 计划的数据结构

不要用纯文本计划，用结构化 DAG：

```java
public record ResearchPlan(
        String originalQuestion,
        List<SubQuestion> questions,
        List<Dependency> dependencies,
        Budget budget
) {}

public record SubQuestion(
        String id,
        String question,
        SubQuestionType type,        // FACT / COMPARISON / OPINION / DATA / DEFINITION
        List<String> dependsOn,      // 依赖的其他子问题
        List<String> preferredSources, // 官方文档 / 论文 / 新闻 / 社区
        int maxSearches
) {}

public record Budget(
        int maxTotalSearches,     // 硬上限，比如 30
        int maxDepth,             // 最大递归深度，比如 3
        long maxTokens,           // 总 token 预算
        Duration maxWallClock     // 总时长，比如 10 分钟
) {}
```

`type` 字段很关键：不同类型的问题需要不同的检索策略。

| 类型 | 例子 | 检索策略 |
|---|---|---|
| DEFINITION | 「什么是向量数据库」 | 1~2 次搜索，优先百科/官方文档 |
| FACT | 「Kafka 4.0 的发布年份」 | 1 次搜索，需要交叉验证 2 个来源 |
| COMPARISON | 「Milvus vs Qdrant」 | 分别搜 + 搜对比评测，至少 5 次 |
| DATA | 「2025 年中国新能源汽车销量」 | 优先统计局/行业报告，需要时效性过滤 |
| OPINION | 「业界怎么看 RAG 的未来」 | 多来源观点，需要多样性（避免回音室） |

### 2.3 Planner 的 prompt 结构

```java
String plannerPrompt = """
        你是研究规划专家。将用户问题分解为 3~8 个子问题，形成可并行执行的研究计划。

        规则：
        1. 每个子问题必须能通过 1~3 次网络搜索回答，不要设计「分析整个行业」这种无法收敛的问题。
        2. 子问题之间尽量正交，避免重复检索同一信息。
        3. 如果需要对比，拆成「分别调研」+「对比结论」两类子问题。
        4. 明确标注每个子问题的类型：DEFINITION/FACT/COMPARISON/DATA/OPINION。
        5. 总搜索次数不得超过 %d 次。

        输出 JSON，字段：questions[{id, question, type, dependsOn, preferredSources, maxSearches}]
        """.formatted(budget.maxTotalSearches());
```

**关键约束：要求「可收敛」**。模型天生喜欢设计「全面调研 XX 行业」这种无法完成的任务，导致无限循环。用「每个子问题 1~3 次搜索可回答」这个约束把它拉回现实。

### 2.4 澄清步骤不能省

开放式问题必须先澄清。用户问「帮我调研一下 AI 编程助手」，这里有三个未定义变量：

- 调研目的（选型？投资？写文章？）
- 时间范围（最近半年？历史全景？）
- 深度（概览？技术细节？）

不做澄清直接跑，产出的报告 90% 不符合预期，浪费 10 分钟和几块钱。

实现上用一个轻量分类器：如果问题包含明确的**对象 + 目的 + 范围**，直接跑；否则生成 1~2 个澄清问题（用 `interrupt` 挂起，等用户回复后恢复）。

---

## 三、Orchestrator：调度与预算

### 3.1 并行执行 + 依赖

DAG 的执行用「拓扑排序 + 并发度限制」：

```java
public EvidenceStore execute(ResearchPlan plan, Budget budget) throws Exception {
    EvidenceStore store = new EvidenceStore();
    Map<String, CompletableFuture<List<Evidence>>> futures = new HashMap<>();
    Semaphore concurrency = new Semaphore(6);   // 并发子代理数
    AtomicInteger searchCount = new AtomicInteger();

    try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
        for (SubQuestion q : topoSort(plan.questions())) {
            CompletableFuture<List<Evidence>> f = CompletableFuture
                    // 等待依赖完成
                    .allOf(q.dependsOn().stream()
                            .map(futures::get).toArray(CompletableFuture[]::new))
                    .thenApplyAsync(v -> {
                        // 预算检查
                        if (searchCount.get() >= budget.maxTotalSearches()) {
                            return List.<Evidence>of();
                        }
                        concurrency.acquireUninterruptibly();
                        try {
                            return searchAgent.run(q, store,
                                    budget.maxSearches() - searchCount.get());
                        } finally {
                            concurrency.release();
                        }
                    }, executor);

            futures.put(q.id(), f);
        }
        CompletableFuture.allOf(futures.values().toArray(CompletableFuture[]::new))
                .get(budget.maxWallClock().toSeconds(), TimeUnit.SECONDS);
    }
    return store;
}
```

三个要点：

1. **虚拟线程**：搜索是纯 IO 等待（HTTP 请求 + LLM 调用），虚拟线程能吃满并发且内存开销极低（每个约 1KB，平台线程是 1MB 栈）。200 个并发搜索用平台线程池会直接 OOM。
2. **信号量限流**：并发不是越高越好。搜索引擎有 QPS 限制，LLM 有 RPM/TPM 限制，并发太高只会拿到一堆 429。
3. **预算硬检查**：在**每个子任务开始前**检查剩余预算，不是结束后统计。否则一个跑飞的任务能把预算吃光。

### 3.2 什么时候停止

这是 Deep Research 最难的部分。没有好的停止条件，系统会一直搜下去。

四类停止信号：

| 信号 | 判断方式 | 说明 |
|---|---|---|
| 预算耗尽 | 搜索次数 / token / 时长到上限 | 硬停止，必须实现 |
| 覆盖度达标 | 每个子问题至少 N 条证据 | 最常见的主信号 |
| 边际收益递减 | 最近 3 次搜索没带来新实体/新事实 | 需要实体抽取对比 |
| 计划完成 | DAG 所有节点状态为 DONE | 正常结束 |

边际收益的实现思路：每次搜索后抽取「新出现的实体/数字/观点」，与已有一对比：

```java
double novelty = newEntities.size() / (double) (newEntities.size() + existingEntities.size());
if (novelty < 0.05) {
    consecutiveLowNovelty++;
    if (consecutiveLowNovelty >= 3) {
        log.info("diminishing returns, stop searching for {}", q.id());
        return;
    }
}
```

这个指标比「搜够 N 次就停」聪明得多——热门话题 3 次就饱和，冷门话题 10 次还有新东西。

### 3.3 成本模型

一次 Deep Research 的成本主要来自三块：

```
成本 = 规划成本 + Σ(搜索成本) + 写作成本 + 校验成本
```

以一个「中等规模」任务为例（6 个子问题、25 次搜索、读 60 个网页、输出 8000 字）：

| 阶段 | 模型 | 输入 token | 输出 token | 单价（示例） | 成本 |
|---|---|---|---|---|---|
| 规划 | 小模型 | 2k | 1k | ¥0.5/M | ¥0.0015 |
| 搜索查询生成 | 小模型 | 25×500 | 25×50 | ¥0.5/M | ¥0.007 |
| 网页摘要/抽取 | 小模型 | 60×3000 | 60×400 | ¥0.5/M | ¥0.10 |
| 大纲生成 | 中模型 | 20k | 2k | ¥2/M | ¥0.044 |
| 分节写作 | 强模型 | 8×10k | 8×1200 | ¥15/M | ¥1.34 |
| 引用校验 | 中模型 | 30k | 3k | ¥2/M | ¥0.066 |
| **合计** | | | | | **≈ ¥1.57** |

关键洞察：**写作阶段占 85% 的成本**。所以优化重点不是「少搜两次」，而是：

- 写作时**只喂该章节相关的证据**，不要把全部证据塞进去；
- 用「强模型写大纲 + 中模型写正文 + 强模型润色关键段落」的级联；
- 缓存系统提示与工具定义（prompt caching 能省 50%~90% 的输入成本）。

---

## 四、Evidence Store：整个系统的核心

如果说 Deep Research 有哪个组件是「必须自己写」的，那就是证据库。它不是向量数据库的包装，而是一个**带溯源的结构化存储**。

### 4.1 数据结构

```java
public record Source(
        String sourceId,          // 规范化 URL 的 hash
        String url,
        String canonicalUrl,      // 去掉 utm 参数、统一协议与大小写
        String title,
        String domain,
        Instant publishedAt,
        Instant fetchedAt,
        SourceTier tier,          // PRIMARY / REPUTABLE / SECONDARY / UNKNOWN
        double qualityScore,      // 0~1，由多维规则算出
        String contentHash        // simhash，用于近重复检测
) {}

public record Evidence(
        String evidenceId,
        String sourceId,
        String subQuestionId,
        String claim,             // 从原文抽取的一句话结论
        String quoteSpan,         // 原文引用片段（必须逐字）
        int charStart, int charEnd,
        List<String> entities,
        Double numericValue,      // 如果是数据类证据
        String unit
) {}
```

两个字段是设计核心：

- **`quoteSpan` + 字符偏移**：这是引用可验证的基础。报告里每个引用都能回溯到原文的**具体位置**，而不是只给一个 URL。
- **`contentHash`（simhash）**：去近重复。同一个新闻被 50 家媒体转载，不去重会导致「50 个来源都这么说」的假象，让模型误以为事实已被交叉验证。

### 4.2 来源分级

```java
public enum SourceTier {
    PRIMARY,      // 官方文档、政府统计、原始论文、公司财报
    REPUTABLE,    // 主流媒体、知名技术博客、行业协会
    SECONDARY,    // 个人博客、聚合站、论坛
    UNKNOWN       // 无法判断
}
```

打分规则（可调）：

```java
double quality = 0.35 * tierScore(tier)
               + 0.20 * recencyScore(publishedAt)     // 越新越高，但有下限
               + 0.15 * authorityScore(domain)        // 白名单
               + 0.15 * contentDepthScore(content)    // 字数、结构、是否有数据
               + 0.15 * citationScore(content)        // 是否引用了原始来源
               - penaltyForAds(content);
```

**报告里必须标注来源等级**。这不是形式主义：一个基于个人博客的结论和一个基于官方文档的结论，可信度天差地别，读者有权知道。

### 4.3 去重的三个层次

1. **URL 规范化**：去掉 `utm_*`、`ref`、`spm` 等追踪参数，统一 http/https、大小写、末尾斜杠。
2. **内容指纹**：simhash（64 位），汉明距离 ≤ 3 视为重复。
3. **断言级去重**：同一句话（claim）来自多个来源时，合并为一条 evidence，`supportingSources` 记录所有来源——这才叫「交叉验证」。

```java
public void add(Evidence e) {
    // 断言级去重：找语义相同的已有 claim
    List<Evidence> similar = index.search(e.claim(), 5, 0.92);
    if (!similar.isEmpty()) {
        similar.get(0).addSupportingSource(e.sourceId());
        return;   // 不新增证据，只增加支撑来源
    }
    index.add(e);
}
```

### 4.4 为什么不能用「把所有网页塞进长上下文」

很多人第一反应是「现在模型支持 1M 上下文，直接全塞进去不就行了」。三个问题：

1. **成本**：100 个网页 × 3000 token = 300k 输入 token，按 ¥15/M 算就是 ¥4.5，而且每次写作都要重付；
2. **注意力稀释**：长上下文里，模型对中间部分的信息利用率显著下降（lost in the middle），引用准确性变差；
3. **无法验证**：没有结构化的 claim-source 映射，你根本不知道报告里哪句话来自哪个网页，谈何引用校验。

证据库的价值就是**把「读」和「写」解耦**：读的时候用便宜模型抽取 claim，写的时候按章节检索相关 evidence。

---

## 五、Synthesizer：分节写作

### 5.1 先大纲后正文

一次性让模型写 8000 字，结果通常是：结构松散、前后重复、后半部分质量骤降。

正确做法：

```
1. 基于 evidence 生成大纲（章节 + 每节要点 + 分配的 evidenceId）
2. 逐节写作（每节独立调用，只喂该节的 evidence）
3. 合并 + 过渡段落生成
4. 全局一致性检查（术语、时态、重复论述）
```

### 5.2 每节的上下文组装

```java
String sectionContext = evidenceStore.bySection(section.id()).stream()
        .sorted(Comparator.comparing(Evidence::qualityScore).reversed())
        .limit(15)                                  // 每节最多 15 条
        .map(e -> """
                [%s] %s
                来源：%s（%s，%s）
                原文：%s
                """.formatted(e.evidenceId(), e.claim(), e.source().title(),
                        e.source().domain(), e.source().tier(), e.quoteSpan()))
        .collect(Collectors.joining("\n---\n"));
```

注意每条 evidence 都带 `evidenceId`，写作时要求模型**在句末标注 `[evidenceId]`**。这样后续可以自动把 id 替换成编号引用，也能做覆盖度检查。

```java
String writerPrompt = """
        基于以下证据写「%s」章节，要求：
        1. 每个事实性陈述后必须标注证据编号，格式 [E12]；无证据支撑的判断不要写。
        2. 不要重复其他章节已讲的内容。
        3. 目标字数 %d，不要用「首先/其次/最后」这类空洞过渡。
        4. 如果证据之间矛盾，明确指出矛盾并说明哪个更可信（依据来源等级与时间）。

        证据：
        %s
        """.formatted(section.title(), section.targetWords(), sectionContext);
```

### 5.3 处理证据冲突

这是 Deep Research 比普通 RAG 更有价值的地方：真实世界的信息经常互相矛盾。

例：A 报告说「2025 年中国新能源汽车销量 1200 万辆」，B 报告说「950 万辆」。差异可能来自统计口径（批发 vs 零售、含出口 vs 不含）。

系统必须能：
1. **检测到冲突**（同实体 + 同指标 + 数值差异 > 阈值）；
2. **分析原因**（口径、时间范围、来源等级）；
3. **在报告中显式说明**，而不是随便选一个。

```java
if (Math.abs(a.numericValue() - b.numericValue()) / a.numericValue() > 0.15) {
    conflicts.add(new Conflict(a, b, "数值差异超过 15%，可能口径不同"));
}
```

---

## 六、Verifier：引用校验

这是最容易被跳过、但决定产品可信度的一步。

### 6.1 三层校验

| 层级 | 检查内容 | 实现 |
|---|---|---|
| L1 结构 | 每个 `[En]` 是否存在、是否被引用、编号是否连续 | 正则 + 集合运算 |
| L2 支撑 | 引用句是否真的被原文支撑 | NLI 模型 / LLM 判定 |
| L3 事实 | 关键数字/日期是否与原文一致 | 数值/日期抽取比对 |

```java
public VerificationReport verify(String report, EvidenceStore store) {
    Set<String> cited = extractCitations(report);       // 正则抽 [E12]
    Set<String> all = store.allIds();

    // L1：未被引用的证据（浪费）& 引用了不存在的 id（幻觉）
    Set<String> phantom = difference(cited, all);       // 必须为 0
    double coverage = cited.size() / (double) store.usedIds().size();

    // L2：逐句校验
    List<ClaimCheck> checks = splitClaims(report).stream()
            .filter(c -> !c.citations().isEmpty())
            .map(c -> nliChecker.check(c.text(), store.quotes(c.citations())))
            .toList();

    double supportRate = checks.stream().filter(ClaimCheck::supported).count()
            / (double) checks.size();

    return new VerificationReport(phantom, coverage, supportRate, checks);
}
```

### 6.2 幻觉引用的三种形态

1. **凭空捏造 URL**：模型编一个看起来很真的链接 → L1 直接用「id 是否存在」拦掉；
2. **引用错位**：URL 真实存在，但内容不支撑该论断 → L2 NLI 拦掉；
3. **过度外推**：原文说「部分场景提升 30%」，报告写成「提升 30%」→ L2 需要严格蕴含判定，不能用宽松的「相关」标准。

实测中，**不加校验的 Deep Research 报告，引用错位率在 10%~25%**。这个数字足以摧毁产品信任。

### 6.3 修复策略

校验发现问题后，不要直接失败，走修复：

```
引用不存在 → 删除该句，或标记为「无来源，待核实」
引用不支撑 → 重新检索该论断，找新证据；找不到则弱化表述（"有观点认为…"）
数值不一致 → 以高等级来源为准，并在脚注说明差异
覆盖率低   → 补充写作（该章节证据没用上，说明写漏了）
```

---

## 七、Java 工程实现要点

### 7.1 状态机 + 断点续跑

Deep Research 跑 10 分钟，中途失败（模型 429、网络抖动）不能从头再来。

```java
public enum Phase { CREATED, CLARIFYING, PLANNING, RESEARCHING, SYNTHESIZING, VERIFYING, DONE, FAILED }

public record ResearchJob(
        String jobId, String userId, String question,
        Phase phase,
        ResearchPlan plan,
        Map<String, SubQuestionState> subStates,   // 每个子问题的进度
        Budget budget, Budget consumed,
        String draftReport,
        Instant createdAt, Instant updatedAt
) {}
```

每个阶段结束都持久化（MySQL/Redis），恢复时从 `phase` 继续。子问题级别的状态让「已完成的搜索」不会重跑。

### 7.2 流式进度推送

用户等 10 分钟，必须有进度反馈。用 SSE 推事件：

```java
@GetMapping(value = "/research/{jobId}/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public SseEmitter stream(@PathVariable String jobId) {
    SseEmitter emitter = new SseEmitter(30 * 60 * 1000L);
    jobEventBus.subscribe(jobId, event -> {
        try {
            emitter.send(SseEmitter.event()
                    .name(event.type())            // phase / subquestion / token / done
                    .data(event.payload()));
        } catch (IOException e) {
            emitter.completeWithError(e);
        }
    });
    return emitter;
}
```

事件设计：

```
event: phase        data: {"phase":"RESEARCHING","total":6,"done":2}
event: finding      data: {"subQuestion":"q3","summary":"找到 4 条证据..."}
event: token        data: {"section":"市场格局","text":"2025 年..."}
event: done         data: {"reportId":"r-123","citationCount":42}
```

**注意**：SSE 连接会被 LB 空闲超时切断（见本博客另一篇 gRPC/HTTP2 的讨论），必须每 15~30 秒发一次心跳注释行（`: ping\n\n`）。

### 7.3 限流与配额

Deep Research 是最容易被滥用的功能：一次调用几块钱，恶意用户能刷爆账单。

```java
// 三层配额
1. 用户级：每天 N 次，每月 M 次
2. 租户级：并发任务数上限（比如 5），防止一个人占满队列
3. 全局级：同时在跑的任务总数 + 每分钟搜索调用数
```

超限时不要静默排队（用户等 20 分钟会疯），直接返回「当前排队 X 人，预计 Y 分钟」并给「降级为快速模式」的选项（少搜、用便宜模型、输出短报告）。

### 7.4 缓存

两层缓存能省很多钱：

| 缓存 | key | TTL | 命中率（经验） |
|---|---|---|---|
| 搜索结果 | query 规范化 hash | 24h | 20%~35% |
| 网页正文 | canonicalUrl | 7d | 40%~60% |
| 报告 | question + 参数 hash | 1h | 5%~15%（热门问题） |

搜索结果缓存要注意**时效性**：新闻类 query 的 TTL 要短（1h），技术文档类可以长（7d）。用 query 里的时间词（"最新"、"2026"）做动态 TTL。

---

## 八、评测

Deep Research 的评测不能只看「报告写得好不好」。

| 指标 | 定义 | 目标 |
|---|---|---|
| 引用精确率 | 引用确实支撑论断的比例 | > 90% |
| 引用覆盖率 | 有引用支撑的论断占比 | > 80% |
| 事实准确率 | 人工核查的关键事实正确比例 | > 95% |
| 子问题覆盖率 | 计划中的子问题被回答的比例 | > 85% |
| 来源多样性 | 不同域名数 / 总来源数 | > 0.5 |
| 平均成本 | 每份报告成本 | 按业务定 |
| P90 耗时 | 端到端时间 | < 8 分钟 |
| 人工评分 | 1~5 分（结构/深度/可读性） | > 3.8 |

**黄金集怎么建**：选 50~100 个真实问题，覆盖不同领域与类型（事实型、对比型、观点型、数据型），人工写好「参考答案要点」（不是标准答案全文，而是必须覆盖的事实点）。评测时检查报告是否覆盖这些要点，以及引用是否支撑。

**回归测试**：模型升级、prompt 改动、检索策略调整，都必须跑一遍黄金集。Deep Research 的输出方差很大，单次对比没有意义，至少要跑 3 次取均值。

---

## 九、六类典型故障

| 故障 | 现象 | 根因 | 修复 |
|---|---|---|---|
| 跑偏 | 报告答非所问 | Planner 分解偏离原问题 | 强约束「每个子问题必须服务于原问题」，加一轮 self-check |
| 死循环 | 一直搜不停 | 没有边际收益检测 | 加 novelty 阈值 + 硬预算 |
| 引用造假 | 报告引用不存在的 URL | 模型自由生成引用 | 强制用 evidenceId，禁止生成 URL |
| 来源单一 | 全是同一家媒体 | 检索 query 同质化 | 强制来源多样性（每域名最多 3 条） |
| 前半好后半烂 | 后几节质量骤降 | 上下文累积太长 | 分节独立调用，每节重建上下文 |
| 账单爆炸 | 单次成本超预期 10 倍 | 无预算硬限制 | 在每个 LLM 调用前检查 token 预算 |

---

## 十、面试追问

**Q1：Deep Research 和 Agentic RAG 的区别？**

Agentic RAG 是「让 Agent 决定检索什么」，通常还是为了回答一个问题，输出较短。Deep Research 多了**显式的多子问题规划**、**长时程执行**、**结构化证据库**、**长文综合与引用校验**。可以说 Deep Research 是 Agentic RAG 在「深度」和「长度」两个维度上的特化。

**Q2：为什么一定要有证据库，不能直接让模型读网页？**

三个原因：上下文装不下（几十万字）、成本（每次重读都付 token）、可验证性（没有 claim-source 映射就无法校验引用）。证据库把「读」的产物（claim + 原文片段）固化下来，写作阶段按需检索。

**Q3：如何保证引用不是编的？**

不允许模型生成 URL。写作时只允许引用 `evidenceId`，系统在渲染时把 id 替换成真实 URL。同时用 NLI 模型校验「引用句是否被原文支撑」。两道关下来，幻觉引用率能压到 5% 以下。

**Q4：并发搜索怎么控制？**

虚拟线程 + 信号量。虚拟线程解决「大量 IO 等待不占平台线程」的问题，信号量解决「下游 QPS 限制」的问题。两者缺一不可——只用虚拟线程会把搜索引擎打挂，只用线程池会在 200 并发时 OOM。

**Q5：成本怎么压？**

四个手段：模型级联（规划/抽取用小模型，写作/校验用强模型）、证据按章节裁剪（不喂全量）、搜索结果与网页正文缓存、prompt caching（系统提示固定前缀）。实测能压到 naive 实现的 1/5~1/3。

**Q6：报告质量怎么评测？**

三层：引用层（精确率、覆盖率）、事实层（关键事实人工核查）、体验层（人工评分 + 用户满意度）。必须建黄金集 + 回归测试，否则模型一升级就不知道是变好还是变坏。

---

## 十一、小结

- Deep Research 的复杂度不在「调模型」，而在**规划、证据管理、预算控制、引用校验**这四个工程问题。
- Planner 要输出**结构化 DAG**，并要求每个子问题「可收敛」；不做澄清直接跑，返工率极高。
- 证据库是核心资产：`quoteSpan` 保证可溯源，simhash 去重防「假交叉验证」，来源分级决定可信度。
- 上下文预算决定成本：分节写作 + 按节检索证据，比「全量塞进长上下文」便宜一个数量级。
- 引用校验三层（结构/支撑/事实）缺一不可，不做校验的引用错位率能到 20%。
- 停止条件要多元：预算 + 覆盖度 + 边际收益，只靠「搜够 N 次」要么浪费要么不够。

这个方向的产品形态还在快速演化，但底层工程约束是稳定的：**长时程、多来源、可验证**。把这三点做扎实，换什么模型都能跑。
