---
title: 【AI 体系】推理模型与 Test-Time Compute 深度解析：思维链扩展、思考预算与工程取舍
date: 2026-10-31 08:20:00
tags:
  - AI
  - 推理模型
  - Test-Time Compute
  - 思维链
  - LLM
  - Java
categories:
  - AI 工程
author: 东哥
---

# 【AI 体系】推理模型与 Test-Time Compute 深度解析

## 前言

2023 年大家比的是"谁的模型参数多"，2024 年比的是"谁的上下文长"，2025 年之后战场换了一个维度：**模型愿意在回答前"想"多久**。

OpenAI o1/o3、DeepSeek-R1、Gemini Thinking、Claude 的 extended thinking，本质上是同一件事的不同实现：**在推理阶段投入更多计算（test-time compute），换取更强的多步推理能力**。它带来了一条新的 scaling law——不增加训练成本，只增加推理成本，就能在数学、代码、规划类任务上获得数量级提升。

但对工程团队来说，这件事的落地形态和"换个更强的模型"完全不同：

- 它**贵**：思考 token 也计费，且往往比输出还多。
- 它**慢**：P99 延迟可能是普通模型的 5~20 倍。
- 它**不可控**：你无法保证它想 3 步就停，也无法完全预测它会想什么。
- 它**不是万能**：在分类、抽取、改写这类任务上，用推理模型是纯浪费。

本文讲清三件事：**test-time compute 的技术谱系**、**什么任务值得付这个钱**、**Java 侧怎么落地与治理**（预算控制、路由、降级、评测）。

---

## 一、两条 Scaling Law

### 1.1 Train-time compute

传统 scaling：参数 × 数据 × 训练算力 ↑ → loss ↓ → 能力 ↑。这条路的边际收益在放缓（高质量数据见底、单次训练成本上亿美元）。

### 1.2 Test-time compute

同一个模型，给它更多"思考时间"，表现会继续提升。形式化地说，模型输出不再是 `answer = f(question)`，而是：

```
answer = f(question, budget)
```

`budget` 可以是生成的思考 token 数、采样次数、搜索树节点数。**能力变成了一个可以按需购买的量**——这是工程上最重要的变化。

一条被多篇论文验证过的曲线特征：

| 任务类型 | test-time compute 的收益 |
|---|---|
| 数学竞赛题（AIME 级） | 极高，pass@1 可从 15% → 70%+ |
| 代码生成（复杂算法） | 高，但收益集中在"需要多步推导"的题 |
| 事实问答 | 低，甚至为负（想多了会自我怀疑） |
| 文本分类 / 抽取 | 几乎为零 |
| 创意写作 | 低，长思考反而让文风僵硬 |
| 多步 Agent 规划 | 高，尤其是有工具反馈时 |

**结论**：test-time compute 不是"通用增强"，它有一个明确的**收益边界**——**任务必须有可验证的中间步骤**。数学有唯一答案、代码能跑测试、规划能看结果反馈，这些才吃得到红利。

---

## 二、技术谱系

### 2.1 CoT（Chain-of-Thought）

最基础的形态：让模型"一步步想"。Few-shot CoT 或 "Let's think step by step"。

**局限**：单条思维链是**一次采样**，错了就一路错到底。

### 2.2 Self-Consistency

采样 N 条思维链，对最终答案**投票**（majority vote）。

```
question → [CoT₁, CoT₂, ..., CoTₙ] → answers → majority vote → final
```

**代价**：N 倍 token。**收益**：在数学题上稳定提升 5~15 个点，是最"性价比"的 test-time 扩展手段之一。

### 2.3 Tree-of-Thought / Graph-of-Thought

把推理变成**搜索**：每个节点是一个"思考步骤"，用价值函数评估，做 BFS/DFS + 回溯。

**问题**：需要额外的评估模型（value model），工程复杂度高，且评估模型本身会错。生产里少见于通用场景，多见于**特定领域**（如定理证明、复杂 SQL 生成）。

### 2.4 PRM（Process Reward Model）

不评估最终答案，而是评估**每一个中间步骤**的正确性。OpenAI 的 "Let's Verify Step by Step" 是这个方向代表。

**价值**：能在推理中途剪枝，避免"前面错了后面全废"。**代价**：需要**步骤级标注数据**，标注成本极高。

### 2.5 RLVR：可验证奖励的强化学习

DeepSeek-R1 路线的核心：用**规则可验证的奖励**（数学答案对不对、代码过不过测试）做 RL，让模型**自发学会**长思维链、自我检查、回溯。

关键洞察：**不需要人工标注思维链**，只需要一个"答案对不对"的验证器。这让推理能力的训练成本大幅下降，也是 2025 年后开源推理模型爆发的直接原因。

对应算法：GRPO（Group Relative Policy Optimization）——对同一问题采样一组答案，用组内相对优势做梯度，省掉了 value model。

### 2.6 蒸馏：把"想得久"变成"想得快"

用大推理模型生成**带思维链的数据**，蒸馏到小模型（R1-Distill-Qwen-7B 等）。

效果：小模型获得"结构化推理"的能力，但**思考长度显著缩短**，成本下降一个数量级。

> 工程含义：如果你的场景固定（比如只做 SQL 生成），**蒸馏一个 7B 专用模型**往往比每次调大推理模型便宜 50 倍，且延迟可控。这是 2026 年企业落地的主流选择。

---

## 三、推理模型的三个价格

### 3.1 Token 价格：思考也计费

一次推理请求的 token 结构：

```
输入 (prompt) → 思考 (reasoning tokens，计费但通常不回传) → 输出 (answer)
```

实测比例（复杂代码任务）：

| 部分 | 占比 |
|---|---|
| 输入 | 5% |
| 思考 | **70%~85%** |
| 输出 | 10%~25% |

也就是说，**你以为在买答案，其实主要在买思考过程**。一个 500 token 的答案，账单可能是 6000 token。

### 3.2 延迟价格：串行生成，无法并行

思考 token 是**自回归串行生成**的，想 5000 token 就是 5000 次前向。哪怕用了各种优化，P99 延迟也很难压到 10s 以内。

对交互式产品（客服、Copilot 补全），这是**致命约束**；对异步任务（夜间批处理、报告生成），则完全可接受。

### 3.3 不可控价格：无法保证"想够就停"

- **Overthinking**：简单问题想 3000 token，自我怀疑、反复推翻。
- **Underthinking**：复杂问题早早给答案。
- **CoT 泄露**：部分模型的思考内容可被提取，可能包含系统提示、内部规则、甚至用户隐私。

OpenAI 明确建议**不要向终端用户展示原始 CoT**，只展示摘要（summary）。这既是安全考虑，也是产品体验考虑——用户不想看 5000 字草稿。

---

## 四、决策：什么时候该用推理模型

### 4.1 一张决策表

| 任务 | 用推理模型？ | 理由 |
|---|---|---|
| 数学/逻辑题求解 | ✅ 强推 | test-time compute 收益最大 |
| 复杂代码生成 / 重构 | ✅ 强推 | 多步推导 + 可测试验证 |
| 多步 Agent 规划（含工具） | ✅ 推荐 | 需要分解与自我纠错 |
| SQL / 正则 / 复杂 DSL 生成 | ✅ 推荐 | 语法约束强，验证成本低 |
| 合同/条款的多步推理比对 | ✅ 推荐 | 需要严格逻辑链 |
| 文档问答（RAG） | ⚠️ 视情况 | 若需跨文档推理则用，单跳检索不用 |
| 文本分类 / 情感分析 | ❌ 不用 | 小模型 + few-shot 足够 |
| 信息抽取（NER/字段抽取） | ❌ 不用 | 结构化输出 + 小模型更稳 |
| 摘要 / 改写 / 翻译 | ❌ 不用 | 推理无增益，只增延迟 |
| 闲聊 / 客服 FAQ | ❌ 不用 | 延迟是第一杀手 |
| 实时补全（IDE 行内） | ❌ 绝对不用 | 200ms 预算内不可能 |

### 4.2 架构模式：不要全量切换

生产里最贵也最常见的错误是"把默认模型换成推理模型"。正确形态是**路由 + 级联**：

```
                    ┌─────────────────┐
   request ────────▶│  Task Classifier │  (规则/小模型，<10ms)
                    └────────┬────────┘
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐   ┌──────────┐   ┌────────────┐
        │ 小模型    │   │ 标准模型  │   │ 推理模型    │
        │ 8B/4o-mini│   │ 4o/Sonnet│   │ o-series/R1│
        └────┬─────┘   └────┬─────┘   └─────┬──────┘
             │              │               │
             └──────────────┴───────────────┘
                            ▼
                   ┌─────────────────┐
                   │ 置信度校验/验证器 │──失败──▶ 升级到更强模型（级联）
                   └─────────────────┘
```

**级联（cascade）** 的关键：先让小模型试，用**可验证的信号**（JSON 是否合法、单测是否通过、答案是否能被检索证据支撑）判断成败，失败再升级。这样 80% 的请求走便宜路径，只有 20% 付推理模型的钱。

---

## 五、Java 落地

### 5.1 依赖与配置

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-model-openai</artifactId>
</dependency>
```

```yaml
spring:
  ai:
    openai:
      api-key: ${OPENAI_API_KEY}
      chat:
        options:
          model: gpt-4o-mini          # 默认走小模型
```

### 5.2 按任务选择推理强度

不同厂商的参数名不同，但语义一致：**思考预算 / 推理强度**。

| 厂商 | 参数 | 取值 |
|---|---|---|
| OpenAI（o 系列） | `reasoning_effort` | `low` / `medium` / `high` |
| Anthropic | `thinking.budget_tokens` | 具体 token 数 |
| Google Gemini | `thinkingBudget` | token 数 / 动态 |
| DeepSeek（R1） | 无显式预算，靠 `max_tokens` 间接约束 | — |

Spring AI 里对 OpenAI 兼容模型可以直接设：

```java
@Service
public class ReasoningService {

    private final ChatClient reasoningClient;
    private final ChatClient fastClient;

    public ReasoningService(ChatClient.Builder builder) {
        this.reasoningClient = builder.clone()
                .defaultOptions(OpenAiChatOptions.builder()
                        .model("o4-mini")
                        .reasoningEffort("medium")   // low / medium / high
                        .build())
                .build();

        this.fastClient = builder.clone()
                .defaultOptions(OpenAiChatOptions.builder()
                        .model("gpt-4o-mini")
                        .temperature(0.2)
                        .build())
                .build();
    }
}
```

> 注意：`reasoning_effort` 与 `temperature`、`max_tokens` 在 o 系列上往往**不兼容**（部分模型只接受默认 temperature，且 `max_completion_tokens` 包含思考 token）。参数冲突时优先相信厂商文档，不要凭经验套。

### 5.3 任务路由

```java
public enum ReasoningLevel { NONE, LOW, MEDIUM, HIGH }

@Component
public class TaskRouter {

    private static final Set<String> REASONING_TASKS = Set.of(
            "math", "code_gen", "sql_gen", "planning", "complex_qa", "contract_diff");

    // 简单的规则 + 关键词路由；生产可换成小分类模型
    public ReasoningLevel route(String taskType, String question) {
        if (REASONING_TASKS.contains(taskType)) {
            return question.length() > 400 ? ReasoningLevel.HIGH : ReasoningLevel.MEDIUM;
        }
        if (taskType.startsWith("extract") || taskType.startsWith("classify")) {
            return ReasoningLevel.NONE;
        }
        return ReasoningLevel.LOW;
    }
}
```

**为什么要 `taskType` 而不是让模型自己判断？** 因为"要不要深度思考"这个决策本身如果交给模型，就又变成一次不可控的推理。**用确定性规则做路由，是工程上唯一可审计的做法**。

### 5.4 成本守卫：调用前先算账

```java
@Component
public class CostGuard {

    // 每百万 token 价格（示例值，按实际厂商更新）
    private static final Map<String, double[]> PRICE = Map.of(
            "gpt-4o-mini",  new double[]{0.15, 0.60},
            "o4-mini",      new double[]{1.10, 4.40}
    );

    private final MeterRegistry meterRegistry;

    public void check(String model, int estimatedPromptTokens, int maxReasoningTokens, int maxOutputTokens) {
        double[] p = PRICE.getOrDefault(model, new double[]{1.0, 4.0});
        double cost = (estimatedPromptTokens * p[0]
                     + (maxReasoningTokens + maxOutputTokens) * p[1]) / 1_000_000.0;

        meterRegistry.counter("llm.cost.estimated.usd", "model", model)
                     .increment(cost);

        if (cost > 0.05) {   // 单次请求超过 5 美分，告警/降级
            meterRegistry.counter("llm.cost.over_threshold", "model", model).increment();
            throw new CostLimitExceededException(model, cost);
        }
    }
}
```

**关键点**：`maxReasoningTokens` 必须设上限。没有上限的推理模型调用，等于给账单开了个无底洞——尤其当 prompt 被注入攻击者控制时。

### 5.5 超时与降级

```java
public String answerWithFallback(String question, ReasoningLevel level) {
    if (level == ReasoningLevel.NONE) {
        return fastClient.prompt().user(question).call().content();
    }
    try {
        return CompletableFuture
                .supplyAsync(() -> reasoningClient.prompt()
                        .user(question)
                        .options(OpenAiChatOptions.builder()
                                .reasoningEffort(level.name().toLowerCase())
                                .maxCompletionTokens(4000)   // 含思考 token
                                .build())
                        .call()
                        .content(), reasoningPool)
                .orTimeout(25, TimeUnit.SECONDS)
                .exceptionally(e -> {
                    log.warn("reasoning timeout, fallback to fast model: {}", e.toString());
                    return fastAnswer(question);
                })
                .join();
    } catch (Exception e) {
        return fastAnswer(question);
    }
}
```

**降级策略要分级**：

| 情况 | 动作 |
|---|---|
| 超时 | 降级到标准模型，标注"简化回答" |
| 限流（429） | 重试一次 + 指数退避，仍失败则降级 |
| 成本超阈值 | 拒绝或降级，并记录业务 ID 用于追责 |
| 输出解析失败 | 用结构化输出重试一次，再失败走兜底文案 |

### 5.6 处理"思考内容"（如果有）

部分模型/网关会在响应里带 `reasoning_content`（DeepSeek 风格）。Spring AI 中它可能出现在 `ChatResponse` 的 metadata 里，取法要防御性写：

```java
ChatResponse response = reasoningClient.prompt().user(q).call().chatResponse();
String answer = response.getResult().getOutput().getText();

Object reasoning = response.getResult().getMetadata().get("reasoning_content");
if (reasoning != null) {
    // ⚠️ 只用于内部调试/审计，不要返回给终端用户
    log.debug("reasoning trace length={}", reasoning.toString().length());
    auditStore.saveTrace(requestId, reasoning.toString());
}
```

**三条铁律**：

1. **不落盘明文 CoT 到业务库**（可能含用户隐私、系统提示）。
2. **不返回给终端用户**（安全 + 体验）。
3. **审计日志要脱敏 + 保留期限**。

---

## 六、评测：pass@1 不够，要看"每次解决的成本"

### 6.1 指标

| 指标 | 含义 | 用途 |
|---|---|---|
| pass@1 | 一次通过率 | 用户体验基线 |
| pass@k | k 次采样内通过率 | 衡量"多试几次"的潜力 |
| **cost per solved task** | 总成本 / 解决任务数 | **决策核心指标** |
| P95 延迟 | 端到端 | 交互式产品生死线 |
| thinking tokens / task | 思考 token 均值 | 预算合理性 |

### 6.2 一个真实的对比（示例数据）

同一批 300 道内部代码题：

| 方案 | pass@1 | 平均延迟 | 平均 token | 每解决一题成本 |
|---|---|---|---|---|
| 4o-mini | 41% | 1.2s | 900 | \$0.0011 |
| 4o | 63% | 2.8s | 1400 | \$0.0084 |
| o4-mini (medium) | 78% | 12s | 5200 | \$0.0286 |
| o4-mini (high) | 81% | 26s | 11000 | \$0.0605 |
| 4o-mini × 5 采样投票 | 58% | 6s | 4500 | \$0.0055 |

**这张表最重要的结论**：从 medium 到 high，pass@1 只涨 3 个点，成本翻倍——**high 在这批任务上不划算**。而"小模型多次采样投票"用 1/5 的成本拿到了 medium 78% 中的 58%，对成本敏感场景是更优解。

**没有 cost per solved task 的评测，都是耍流氓。**

### 6.3 评测集设计

- **必须分桶**：数学/代码/抽取/规划/多跳，各桶单独看。总体平均会把"推理模型在抽取任务上更差"这个事实掩盖掉。
- **必须包含"不该用推理模型"的任务**，验证路由规则没有误伤。
- **必须测 P99 延迟**，不只看均值。推理模型的延迟分布长尾极重。

---

## 七、局限与安全

### 7.1 Overthinking

简单问题触发长思考，是当前推理模型的通病。缓解：

- 显式设 `reasoning_effort=low` 或 `thinking budget` 上限。
- Prompt 里加"如果问题简单，直接回答"（效果有限，但有用）。
- **路由层拦截**：能确定是简单任务，就不进推理模型。

### 7.2 不可解释 ≠ 可审计

"模型思考了 8000 token"不等于"过程可信"。CoT 可能是**事后合理化**，与真实决策路径不一致。**不要把 CoT 当作审计证据**。

真正的审计靠：输入输出留存、工具调用轨迹、外部验证器（单测、SQL 执行结果、检索证据）。

### 7.3 CoT 带来的新攻击面

- **提示注入放大**：恶意文档让模型"思考"出越权操作步骤。推理模型更容易被多步诱导。
- **CoT 泄露**：思考内容可能带出系统提示、内部规则、其他用户数据。
- **资源耗尽**：攻击者构造难题，让每次请求都想满 token 上限 → 成本攻击。

**防护**：思考预算硬上限 + 单用户配额 + 输入长度限制 + 输出不含 CoT。

---

## 八、面试追问

**Q1：什么是 test-time compute？它和训练时 scaling 有什么区别？**

test-time compute 指在**推理阶段**投入更多计算（更长思维链、多次采样、树搜索）来提升效果；train-time scaling 是增加参数/数据/训练算力。前者把"能力"变成**可按请求购买**的资源，代价是延迟与单次成本；后者是一次性投入、边际收益在放缓。

**Q2：Self-Consistency 为什么有效？什么时候没用？**

它对**多条独立推理路径**做投票，用"路径多样性"抵消单条链的随机错误，前提是**错误是独立的**且**答案是离散可投票的**。对开放式生成（写作、摘要）无法投票，对系统性偏差（模型整体理解错）也无能为力。

**Q3：推理模型的成本为什么这么高？**

思考 token 占 70%~85%，且自回归串行生成导致延迟线性增长。计费按 token，延迟按串行步数，两者都随"想多久"线性上升，所以成本模型与普通模型完全不同。

**Q4：你怎么决定一个任务该用推理模型？**

三个判据：① 任务有**可验证的中间步骤**（数学、代码、SQL、规划）；② 错误代价**高于**延迟/成本代价；③ 离线或可接受长延迟。三者同时满足才用。分类/抽取/改写/闲聊一律不用。

**Q5：级联（cascade）怎么设计验证器？**

优先用**确定性验证**：JSON schema 校验、单元测试执行、SQL 语法/EXPLAIN 校验、检索证据覆盖率。没有确定性验证器时，才用 LLM-as-Judge，并且要**校准**（与人工标注对齐）后再上线。

**Q6：CoT 能直接展示给用户吗？**

不建议。原因有三：安全（可能泄露系统提示/隐私）、体验（用户不想读草稿）、正确性（CoT 可能是事后合理化）。应该展示**结构化摘要**，原始 CoT 只进脱敏审计日志。

---

## 九、总结

1. **Test-time compute 是新维度的 scaling**：能力从"模型固有"变成"按需购买"，`answer = f(question, budget)`。
2. **技术谱系**：CoT → Self-Consistency → ToT → PRM → RLVR（GRPO）→ 蒸馏。RLVR 是开源推理模型爆发的关键（只需可验证奖励，不需标注思维链）。
3. **三个价格**：思考 token（占 70%~85%）、串行延迟（P99 极长）、不可控性（overthinking / CoT 泄露）。
4. **收益边界**：只有**有可验证中间步骤**的任务吃得到红利——数学、代码、SQL、规划；分类/抽取/改写/闲聊一律不用。
5. **工程形态是路由 + 级联，不是全量切换**：规则路由（可审计）→ 小模型先试 → 确定性验证器 → 失败升级。
6. **评测核心指标是 cost per solved task**，不是 pass@1；必须分桶、必须看 P99。
7. **安全**：思考预算硬上限、CoT 不返用户不落明文、提示注入与成本攻击防护。

推理模型不是"更聪明的模型"，而是"愿意花更多时间思考的模型"。工程上的全部功夫，在于**判断哪些问题值得等它想**——这个判断做对了，成本和体验双赢；做错了，你只是用 20 倍的钱买了一个更慢的系统。
