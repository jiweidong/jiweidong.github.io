---
title: 【AI 体系】上下文工程（Context Engineering）深度解析：从 Prompt 工程到上下文编排系统
date: 2026-10-30 08:40:00
tags:
  - AI
  - Context Engineering
  - Agent
  - RAG
  - 架构设计
categories:
  - AI 工程
author: 东哥
---

# 【AI 体系】上下文工程（Context Engineering）深度解析：从 Prompt 工程到上下文编排系统

## 前言

2023 年大家在聊 Prompt Engineering：怎么措辞、怎么加 "Let's think step by step"、怎么让模型输出 JSON。

2025 年之后，这个词在工程语境里基本被 **Context Engineering（上下文工程）** 取代了。原因很朴素：**模型的推理能力已经足够强，"把话说清楚"不再是瓶颈；真正的瓶颈是"该给它看什么"。**

一个 Agent 的失败，很少是因为 prompt 写得不够漂亮，而是因为：

- 检索回来的 5 个片段里有 3 个是无关的（噪声淹没信号）
- 20 轮对话后，早期关键约束被挤出上下文窗口
- 工具定义有 15 个，模型选错了其中一个
- 上一个 Agent 的输出有错，被当成事实继续往下推
- 上下文里塞了两个互相矛盾的规则

这些问题，没有一个能靠"改写 prompt"解决。它们属于**上下文的采集、筛选、压缩、编排**问题——也就是上下文工程。

这篇文章从概念、预算、四大操作、失效模式一直写到 Java 侧的落地架构，目标是把"凭感觉拼 prompt"变成"可度量、可测试、可迭代的系统"。

<!-- more -->

## 一、边界：它和 Prompt Engineering 到底差在哪

| 维度 | Prompt Engineering | Context Engineering |
|---|---|---|
| 关注对象 | 一段文本的措辞 | 一次推理调用看到的**全部 token** |
| 时间尺度 | 单次请求 | 整个会话 / 整个任务生命周期 |
| 主要手段 | 角色设定、few-shot、CoT、格式约束 | 检索、压缩、记忆、隔离、裁剪、排序 |
| 失败原因 | 指令不清 | 信息缺失 / 过量 / 矛盾 / 过期 |
| 可测性 | 主观（人工看） | 客观（命中率、忠实度、任务成功率） |
| 工程载体 | 字符串模板 | 上下文编排管线（pipeline） |
| 典型角色 | Prompt 工程师 | 后端 / 平台工程师 |

一句话：**Prompt Engineering 是"怎么写这一段"，Context Engineering 是"这一段该由什么内容组成"。**

对 Java 后端来说，这是个好消息——上下文工程的本质是**数据编排 + 资源调度 + 状态管理**，几乎全是后端工程师的舒适区。真正的难点不在模型侧，在于：

1. 怎么在有限的 token 预算下做**优先级分配**
2. 怎么保证**注入的每一条信息都是当前有效且不冲突的**
3. 怎么在**多轮、多 Agent、长时间运行**下维持状态一致

## 二、上下文的四个组成部分

把一次 LLM 调用看到的全部内容拆开，只有四类：

```text
┌──────────────────────────────────────────────────────┐
│ 1. Instructions（指令）                                │
│    系统角色、输出规范、安全约束、当前任务目标            │
├──────────────────────────────────────────────────────┤
│ 2. Knowledge（知识）                                   │
│    RAG 检索片段、文档、数据库查询结果、API 返回          │
├──────────────────────────────────────────────────────┤
│ 3. Tools（工具）                                       │
│    Function Calling schema、MCP 工具描述、返回值格式     │
├──────────────────────────────────────────────────────┤
│ 4. Memory / State（记忆与状态）                        │
│    对话历史、任务进度、中间产物、scratchpad             │
└──────────────────────────────────────────────────────┘
```

这四类的**稳定性、变化频率、失效风险**完全不同，所以管理策略也必须不同：

| 类型 | 变化频率 | 是否可缓存 | 主要风险 | 管理手段 |
|---|---|---|---|---|
| Instructions | 极低 | ✅ 高收益 | 多版本混用 | 版本化 + 哈希校验 |
| Tools | 低（随发布变） | ✅ 高收益 | 工具太多导致选错 | 动态工具集（按场景裁剪） |
| Knowledge | 每请求变 | ❌ | 噪声、过期、冲突 | 检索 + 重排 + 去重 |
| Memory | 每轮变 | ❌ | 膨胀、失真、被污染 | 摘要 + 结构化 + 淘汰 |

看清这张表，很多设计决策就自然出来了：**指令和工具放最前面（可缓存），知识按相关度排序，记忆做压缩和结构化**。

## 三、Token 预算：把窗口当成稀缺资源分配

上下文窗口从 8K 涨到 200K、1M，很多人的第一反应是"那就不用管预算了"。这是最危险的错觉。

原因有两个：

**其一，长上下文的注意力是衰减的。** "Lost in the Middle"（Liu et al., 2023）已经证明：把关键信息放在长上下文的中段，模型的召回率显著低于放在开头或结尾。窗口再大，**中段也是"注意力洼地"**。

**其二，成本和延迟是线性甚至超线性增长的。** 100K token 的输入，即使有缓存，首 token 延迟也会明显上升；没有缓存的话，单次调用成本是 10K 的 10 倍。

所以必须做预算分配。一个经过实践检验的分配比例（以 32K 窗口为例）：

| 分区 | 占比 | token 数 | 说明 |
|---|---|---|---|
| System Instructions | 5% | 1,600 | 角色、规范、安全。宁可精简，不要堆砌 |
| Tool Definitions | 10~15% | 3,200~4,800 | 超过 10 个工具就要考虑动态裁剪 |
| Retrieved Knowledge | 35~40% | 11,200~12,800 | top-k 片段，重排后取高位 |
| Conversation History | 20~25% | 6,400~8,000 | 超出则摘要压缩 |
| Working Memory / Scratchpad | 5~10% | 1,600~3,200 | Agent 的中间推理与状态 |
| Output Reserve | 10% | 3,200 | **必须预留**，否则会被截断 |

**Output Reserve 是最容易漏的一项。** 很多人把窗口塞满到 99%，结果模型输出被 `max_tokens` 硬截断，JSON 解析失败，整条链路报错。经验值：预留 10~20%，Agent 场景（输出含工具调用参数）要更多。

Java 侧的预算管理器：

```java
public record TokenBudget(int total, Map<Section, Double> ratios) {

    public enum Section {
        INSTRUCTIONS, TOOLS, KNOWLEDGE, HISTORY, SCRATCHPAD, OUTPUT
    }

    public static TokenBudget of(int contextWindow) {
        return new TokenBudget(contextWindow, Map.of(
                Section.INSTRUCTIONS, 0.05,
                Section.TOOLS,        0.12,
                Section.KNOWLEDGE,    0.38,
                Section.HISTORY,      0.22,
                Section.SCRATCHPAD,   0.08,
                Section.OUTPUT,       0.15
        ));
    }

    public int limitOf(Section s) {
        return (int) Math.floor(total * ratios.getOrDefault(s, 0.0));
    }

    /** 把剩余额度按比例分给"可伸缩"的分区（知识 + 历史） */
    public Map<Section, Integer> allocate(Map<Section, Integer> used) {
        int fixed = used.getOrDefault(Section.INSTRUCTIONS, 0)
                  + used.getOrDefault(Section.TOOLS, 0)
                  + limitOf(Section.OUTPUT)
                  + limitOf(Section.SCRATCHPAD);

        int flexible = Math.max(0, total - fixed);
        double wK = ratios.get(Section.KNOWLEDGE);
        double wH = ratios.get(Section.HISTORY);
        double sum = wK + wH;

        return Map.of(
                Section.KNOWLEDGE, (int) (flexible * wK / sum),
                Section.HISTORY,   (int) (flexible * wH / sum)
        );
    }
}
```

## 四、四大核心操作：写、选、压、隔

业界（LangChain 在 2025 年的总结）把上下文工程的操作归纳为四类。这个框架非常实用，可以直接对应到代码模块。

### 4.1 Write（写入）：把状态显式化

Agent 做长任务时，最重要的能力不是"记住"，而是"**把想到的写下来**"。

- **Scratchpad（草稿区）**：让模型把中间结论写进上下文，后续步骤引用。这比让它"在脑子里记着"可靠得多。
- **外部记忆**：写进文件 / 数据库 / Redis，需要时再读回来。上下文窗口是"工作内存"，外部存储是"磁盘"。
- **结构化状态**：不要用自然语言描述任务进度，用 JSON：

```json
{
  "task": "为订单服务补全单元测试",
  "done": ["OrderService.create", "OrderService.cancel"],
  "todo": ["OrderService.refund"],
  "blockers": ["缺少 RefundClient 的 mock 定义"],
  "decisions": ["使用 Mockito 而非 Testcontainers，因为退款逻辑无 DB 依赖"]
}
```

结构化状态的好处是**可压缩、可校验、可程序化更新**，而自然语言进度描述会随轮次漂移、失真。

### 4.2 Select（选择）：只给该给的

这是 RAG 的主战场，但选择不只是"向量检索 top-k"：

| 选择维度 | 手段 | 效果 |
|---|---|---|
| 相关性 | 向量检索 + BM25 混合 | 基础召回 |
| 精排 | Cross-encoder / Reranker | 提升前 3 条命中率 |
| 去重 | 相似度阈值 + MMR | 避免 5 条讲同一件事 |
| 时效 | 时间衰减权重 | 避免引用过时文档 |
| 权限 | 元数据过滤（ACL） | 防止越权内容进上下文 |
| 场景 | 按任务类型选不同知识源 | 客服 vs 代码问答走不同索引 |

**最容易被忽略的是"去重"和"场景路由"。** 5 个片段如果都在说同一件事，实际信息量只有 1 个片段，但占用了 5 份预算，还把真正互补的信息挤掉了。

### 4.3 Compress（压缩）：信息密度最大化

压缩有四个层次，从轻到重：

```text
L1 去冗余：删掉重复片段、样板文字、导航栏、页脚        （无损，必做）
L2 结构化：把自然语言表格转成 Markdown 表 / JSON        （近无损，推荐）
L3 摘要：LLM 生成对话摘要、文档摘要                     （有损，慎用）
L4 提炼：只保留与当前问题相关的句子                     （有损，需评测）
```

工程上要遵守一条原则：**能用 L1/L2 解决就不要用 L3/L4**。LLM 摘要会引入幻觉和语义漂移，而且在长任务里误差会累积。

对话历史的压缩策略（生产验证有效）：

```java
public class HistoryCompressor {

    private final ChatModel model;

    /**
     * 滑动窗口 + 分层摘要：
     * - 最近 N 轮：原文保留（保证细节）
     * - 更早的轮次：每 K 轮压成一段摘要
     * - 最早的：只保留"决策与事实"清单
     */
    public List<Message> compress(List<Message> history, int keepRecent, int tokenLimit) {
        if (estimateTokens(history) <= tokenLimit) {
            return history;
        }

        int split = Math.max(0, history.size() - keepRecent);
        List<Message> old = history.subList(0, split);
        List<Message> recent = history.subList(split, history.size());

        // 旧对话压成"事实 + 决策"，不保留寒暄与试错过程
        String summary = model.chat("""
                把下面的对话压缩成要点，只保留：
                1) 用户已确认的事实与约束
                2) 已做出的决策及理由
                3) 未解决的问题
                不要保留寒暄、重复表述、被否决的方案。
                输出 Markdown 列表，不超过 300 字。

                对话：
                %s
                """.formatted(render(old)));

        List<Message> result = new ArrayList<>();
        result.add(SystemMessage.from("【历史摘要】\n" + summary));
        result.addAll(recent);
        return result;
    }

    private int estimateTokens(List<Message> msgs) {
        // 中文约 1.5 字/token，英文约 4 字符/token，混合取 2 字符/token 的保守估计
        return msgs.stream().mapToInt(m -> m.text().length() / 2).sum();
    }

    private String render(List<Message> msgs) {
        return msgs.stream()
                .map(m -> m.type() + ": " + m.text())
                .collect(Collectors.joining("\n"));
    }
}
```

### 4.4 Isolate（隔离）：把复杂任务拆开

当一个任务需要的上下文超过窗口，或者不同子任务需要的知识源互相干扰时，**拆成多个上下文**比"塞进一个超大窗口"更有效。

| 隔离方式 | 做法 | 适用 |
|---|---|---|
| 子 Agent | 主 Agent 派生子任务，子 Agent 有独立上下文，只回传结论 | 调研、多文档分析 |
| 分阶段 | 阶段 1 只看需求，阶段 2 只看代码，阶段 3 只看测试 | 代码生成 |
| 工具隔离 | 不同阶段挂不同工具集 | 减少工具误选 |
| 角色隔离 | 生成者 / 评审者分离 | 提升质量（Reflection） |

隔离的本质是**用"上下文切换成本"换"上下文纯净度"**。代价是信息在传递时会丢失（子 Agent 只能回传摘要），所以关键约束必须显式传递。

## 五、四类失效模式（这是排查清单）

当 Agent 表现异常时，先按这四类对号入座，比盲目改 prompt 高效十倍。

| 失效模式 | 表现 | 根因 | 修复 |
|---|---|---|---|
| **Context Poisoning（污染）** | 错误信息被反复引用、越滚越错 | 某轮幻觉/错误输出进入了上下文并被当作事实 | 标注信息来源与置信度；关键事实做校验；错误进入后显式纠正 |
| **Context Distraction（分心）** | 模型忽略核心任务，纠结细节 | 上下文过长，无关内容占比过高 | 压缩 + 提高信噪比 + 任务目标前置且重复 |
| **Context Confusion（混淆）** | 用错工具、答非所问 | 工具太多、定义重叠、指令冲突 | 动态工具集、精简描述、明确 "when to use / when not to use" |
| **Context Clash（冲突）** | 前后矛盾、摇摆不定 | 多来源信息冲突（旧文档 vs 新文档、两个 Agent 结论不同） | 显式冲突消解规则、时间戳优先级、单一事实源 |

### 5.1 污染是怎么发生的

一个真实链路：

```text
轮次 1：用户问"订单 123 的退款政策"
        模型检索到一篇 2023 年的旧政策文档 -> 答"7 天无理由"
轮次 2：用户问"那生鲜类呢"
        模型基于轮次 1 的错误前提继续推理 -> 答"同样 7 天"
轮次 3：用户说"不对吧，我记得是 48 小时"
        模型为了自洽，开始编造"7 天内 48 小时"的奇怪规则
```

到轮次 3，上下文里已经有三条互相矛盾的"事实"。**这不是模型变笨了，是上下文被污染了。**

修复手段：
1. 检索结果带 `effective_date` 和 `source`，让模型能判断新旧
2. 关键结论要求模型标注引用来源，无来源的结论标记为"推测"
3. 用户纠错时，显式写入一条 `【更正】之前关于 X 的回答有误，正确为 Y`，而不是让旧内容继续留在上下文里
4. 定期"上下文重开"：把已确认的事实提炼成结构化状态，丢弃原始对话

### 5.2 冲突消解规则要写进 system prompt

```text
当上下文中出现互相矛盾的信息时，按以下优先级取信：
1. 用户当前轮次明确说明的内容（最高）
2. 带最新 effective_date 的官方文档
3. 结构化数据库查询结果
4. 更早轮次的对话内容（最低）
若仍无法判断，明确回答"存在信息冲突，请确认"，禁止自行选择。
```

这段规则比任何"请准确回答"都有用。

## 六、Java 落地：上下文编排管线

把上面的理念落成代码，核心是一个**有序的责任链**：每个环节处理一类上下文，可增删、可测试、可观测。

```java
public interface ContextStage {
    /** 顺序，越小越先执行 */
    int order();
    /** 是否可以处理当前请求 */
    boolean supports(ContextRequest req);
    /** 处理：读取/写入上下文 */
    void apply(ContextRequest req, ContextBuffer buf);
}
```

```java
/** 上下文缓冲区：统一管理 token 预算与分区 */
public class ContextBuffer {

    private final TokenBudget budget;
    private final Map<TokenBudget.Section, List<String>> sections = new EnumMap<>(TokenBudget.Section.class);
    private final Map<TokenBudget.Section, Integer> used = new EnumMap<>(TokenBudget.Section.class);

    public boolean tryAppend(TokenBudget.Section section, String content, int priority) {
        int tokens = estimate(content);
        int limit = budget.limitOf(section);
        int current = used.getOrDefault(section, 0);
        if (current + tokens > limit) {
            return false;                 // 预算不足，由上层决定是否压缩
        }
        sections.computeIfAbsent(section, k -> new ArrayList<>()).add(content);
        used.put(section, current + tokens);
        return true;
    }

    public String render() {
        // 固定顺序渲染，保证前缀稳定（配合 Prompt Caching）
        return Arrays.stream(TokenBudget.Section.values())
                .filter(sections::containsKey)
                .map(s -> header(s) + String.join("\n", sections.get(s)))
                .collect(Collectors.joining("\n\n"));
    }

    private int estimate(String s) {
        return Math.max(1, s.length() / 2);
    }
}
```

具体环节：

```java
/** 1. 系统指令：版本化 + 哈希，便于排查"是哪个版本出的问题" */
@Component
public class InstructionStage implements ContextStage {
    private final PromptRegistry registry;

    public int order() { return 10; }
    public boolean supports(ContextRequest r) { return true; }

    public void apply(ContextRequest req, ContextBuffer buf) {
        var tpl = registry.get(req.promptVersion());
        buf.tryAppend(TokenBudget.Section.INSTRUCTIONS,
                tpl.render(req.variables()), 100);
        req.tag("prompt.hash", tpl.hash());   // 埋点：出问题时能定位版本
    }
}

/** 2. 工具裁剪：按场景只挂必要工具，减少误选 */
@Component
public class ToolSelectionStage implements ContextStage {
    private final ToolRegistry tools;

    public int order() { return 20; }
    public boolean supports(ContextRequest r) { return !r.toolGroups().isEmpty(); }

    public void apply(ContextRequest req, ContextBuffer buf) {
        List<ToolSpec> selected = tools.byGroups(req.toolGroups());
        // 上限保护：超过 10 个工具，误选概率显著上升
        if (selected.size() > 10) {
            selected = selected.subList(0, 10);
        }
        buf.tryAppend(TokenBudget.Section.TOOLS, serializeStable(selected), 90);
    }

    /** 稳定序列化：字段顺序固定，避免破坏 prompt cache */
    private String serializeStable(List<ToolSpec> specs) {
        return specs.stream()
                .sorted(Comparator.comparing(ToolSpec::name))
                .map(ToolSpec::toJson)   // 内部用 LinkedHashMap
                .collect(Collectors.joining(",\n"));
    }
}

/** 3. 知识注入：检索 + 重排 + 去重 + 按相关度填预算 */
@Component
public class KnowledgeStage implements ContextStage {
    private final HybridRetriever retriever;
    private final Reranker reranker;

    public int order() { return 30; }
    public boolean supports(ContextRequest r) { return r.needsKnowledge(); }

    public void apply(ContextRequest req, ContextBuffer buf) {
        List<Chunk> candidates = retriever.search(req.query(), 20);   // 宽召回
        List<Chunk> ranked = reranker.rerank(req.query(), candidates); // 精排
        List<Chunk> deduped = mmr(ranked, 0.7, 5);                     // 去重

        for (Chunk c : deduped) {
            String block = format(c);   // 带 source / effective_date / 标题
            if (!buf.tryAppend(TokenBudget.Section.KNOWLEDGE, block, 80)) {
                break;                  // 预算耗尽，后续片段丢弃
            }
        }
        req.tag("knowledge.chunks", deduped.size());
    }

    private String format(Chunk c) {
        return """
                <doc source="%s" date="%s" score="%.3f">
                %s
                </doc>
                """.formatted(c.source(), c.effectiveDate(), c.score(), c.text());
    }
}

/** 4. 记忆压缩：超预算时把早期对话压成要点 */
@Component
public class HistoryStage implements ContextStage {
    private final HistoryCompressor compressor;

    public int order() { return 40; }
    public boolean supports(ContextRequest r) { return !r.history().isEmpty(); }

    public void apply(ContextRequest req, ContextBuffer buf) {
        int limit = buf.limitOf(TokenBudget.Section.HISTORY);
        List<Message> msgs = compressor.compress(req.history(), 6, limit);
        for (Message m : msgs) {
            buf.tryAppend(TokenBudget.Section.HISTORY, render(m), 70);
        }
    }
}
```

编排执行器：

```java
@Service
public class ContextPipeline {

    private final List<ContextStage> stages;
    private final TokenBudget budget;

    public ContextPipeline(List<ContextStage> stages) {
        this.stages = stages.stream()
                .sorted(Comparator.comparingInt(ContextStage::order))
                .toList();
        this.budget = TokenBudget.of(32_000);
    }

    public AssembledContext build(ContextRequest req) {
        ContextBuffer buf = new ContextBuffer(budget);
        for (ContextStage stage : stages) {
            if (!stage.supports(req)) continue;
            long start = System.nanoTime();
            try {
                stage.apply(req, buf);
            } catch (Exception e) {
                // 单个环节失败降级，不拖垮整条链路
                log.warn("context stage {} failed, degrade", stage.getClass().getSimpleName(), e);
                req.tag("stage.failed", stage.getClass().getSimpleName());
            } finally {
                meterRegistry.timer("context.stage.duration",
                        "stage", stage.getClass().getSimpleName())
                        .record(System.nanoTime() - start, TimeUnit.NANOSECONDS);
            }
        }
        return new AssembledContext(buf.render(), req.tags());
    }
}
```

这套结构的价值在于：**每个环节独立可测**。你可以单测 `KnowledgeStage` 在给定 query 下注入了哪几个片段、占了多少 token；可以灰度调整 `TokenBudget` 比例看任务成功率；可以在 trace 里看到"这次为什么没检索到内容"。

## 七、怎么评测上下文质量

这是最容易被跳过的一步。三个层次的评测：

### 7.1 组件级：检索质量

| 指标 | 含义 | 目标 |
|---|---|---|
| Recall@K | 前 K 条里包含正确答案的比例 | > 0.85 |
| Precision@K | 前 K 条里相关片段的比例 | > 0.6 |
| 冗余率 | 相似度 >0.9 的片段对占比 | < 0.2 |
| 覆盖率 | 答案所需信息被覆盖的比例 | > 0.9 |

### 7.2 链路级：上下文消融实验

这是判断"某类上下文到底有没有用"的最直接方法：

```text
基线      ：instructions + tools + knowledge + history
消融 A    ：去掉 knowledge        -> 看准确率掉多少（衡量知识价值）
消融 B    ：去掉 history          -> 看多轮一致性掉多少
消融 C    ：history 从 10 轮减到 3 轮 -> 看是否无损
消融 D    ：knowledge 从 5 条减到 3 条 -> 找"够用"的 k
```

**如果消融某一块指标不降，说明这块是纯浪费预算**——直接砍掉，成本立降。

经验数据：多数 RAG 系统把 top-5 减到 top-3，准确率只掉 1~2 个点，但 token 省 40%。

### 7.3 系统级：Needle in a Haystack

在长上下文的随机位置埋一个关键事实，测试模型能否找到。它衡量的是"**在给定上下文长度下，模型的注意力覆盖是否完整**"。

对上下文工程的指导意义：如果你的关键信息总是落在中段（比如把最新检索结果拼在历史后面），命中率会明显低于理论值。解法是**把最关键的内容放在开头或结尾**——这就是所谓"首尾优先"排布。

## 八、和 RAG、Agent 的关系

一句话厘清三者：

```text
RAG          = 上下文工程里 "Select" 操作的一种实现（外部知识检索）
Agent        = 让模型自己决定"下一步需要什么上下文"的机制
Context Eng. = 决定"这次调用看到什么"的全部工程实践
```

所以：

- 做 RAG 做得好 ≠ 上下文工程做得好（还有工具、记忆、压缩、隔离）
- 做 Agent 一定会遇到上下文工程问题（工具集膨胀、记忆膨胀、污染）
- 上下文工程是**底座**，RAG 和 Agent 是**上层应用**

对 Java 团队来说，最实际的落地顺序是：

1. 先把 **Instructions 版本化**（消灭"线上跑的是哪版 prompt"的扯皮）
2. 再把 **Knowledge 的选择链路做扎实**（混合检索 + 重排 + 去重 + 预算）
3. 然后做 **History 压缩**（长会话的成本和稳定性）
4. 最后做 **Tool 动态裁剪**（Agent 场景）

前两步能解决 80% 的"效果不好"问题。

## 九、面试常见追问

**Q1：上下文工程和 Prompt 工程的区别？**

Prompt 工程优化的是"指令文本"，关注措辞、示例、格式。上下文工程优化的是"进入模型的全部 token"，关注检索、压缩、记忆、隔离、预算分配。前者是文本技巧，后者是系统工程。上下文工程包含 Prompt 工程，但范围大得多。

**Q2：窗口都 1M 了，为什么还要做上下文管理？**

三个原因：一是注意力在中段会衰减（Lost in the Middle），塞得越多不代表用得越好；二是成本和延迟随输入线性增长；三是长上下文里噪声和冲突的概率大幅上升，反而降低准确率。窗口大是"容量"，上下文工程解决的是"信号质量"。

**Q3：怎么判断某段上下文该不该保留？**

做消融实验：去掉它，看指标是否下降。不降就是纯成本。生产中可以把"每条注入内容"打上 tag，跑 A/B 对比任务成功率和 token 消耗，形成"单位 token 收益"的排序，长期优化就有了依据。

**Q4：多 Agent 场景下上下文怎么隔离？**

子 Agent 只接收"完成任务所必需的最小上下文"，回传时只回结论 + 置信度 + 引用，不回传完整推理过程。主 Agent 维护全局状态（结构化 JSON），子 Agent 不直接读写全局上下文，避免污染扩散。

**Q5：上下文被污染了怎么恢复？**

三步：一是显式插入更正声明（不要只删旧内容，模型可能已经引用过）；二是把已确认事实提炼成结构化状态，重开上下文；三是给关键结论加"来源 + 时间"标注，让模型能判断优先级。根治手段是在 system prompt 里写清冲突消解规则。

## 十、总结

| 要点 | 结论 |
|---|---|
| 定义 | 决定"一次 LLM 调用看到哪些 token"的系统工程 |
| 四类内容 | 指令 / 知识 / 工具 / 记忆，稳定性与策略各不同 |
| 核心操作 | Write（写状态）、Select（选内容）、Compress（提密度）、Isolate（拆上下文） |
| 四类失效 | 污染 / 分心 / 混淆 / 冲突，可作为排查清单 |
| 工程载体 | 有序责任链 + Token 预算 + 结构化状态 + 全链路埋点 |
| 评测 | 检索指标 + 消融实验 + Needle-in-Haystack |
| 最大误区 | 以为"窗口够大就不用管理" |

从"会写 prompt"到"会做上下文工程"，本质上是从**内容创作**转向**系统设计**。这件事恰好是 Java 后端工程师最擅长的部分：预算分配、优先级队列、状态机、责任链、可观测性——这些词在上下文工程里一个都不陌生。

模型会持续变强，窗口会持续变大，但"在有限资源下给出最相关信息"这个问题不会消失。它只是从"塞进 prompt"变成了"编排好上下文"。
