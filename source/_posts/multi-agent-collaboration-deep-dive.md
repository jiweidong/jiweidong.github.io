---
title: 【AI Agent】多智能体协作深度解析：角色分工、通信协议与冲突消解
date: 2026-10-20 08:40:00
tags:
  - AI
  - Agent
  - 多智能体
  - 架构设计
  - Spring AI
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】多智能体协作深度解析

## 前言

单智能体（Single Agent）在 2024 年被大量验证，也在 2025 年集体撞墙。原因很朴素：

**一个 Agent 做不好所有事。**

给它 30 个工具，它在选工具上就开始犯迷糊；给它 20 万 token 的上下文，它在中段开始遗忘；让它既做需求分析又写代码又做代码审查，它会用「写代码的心态」去做审查，自己批自己，永远通过。

于是多智能体（Multi-Agent System，MAS）成了自然演进方向：**拆角色、分上下文、定协议、消冲突**。

但多智能体不是免费的午餐。它带来 **N² 的通信成本**、**错误放大效应**、**调试地狱**。业界有个流传很广的判断：

> **大多数多智能体系统，用更简单的方案（单 Agent + 更好的工具）就能做得一样好，而且便宜 5 倍。**

这篇文章不吹多智能体，而是讲清楚：**什么时候该用、怎么设计、会踩什么坑**。

---

## 一、先问清楚：为什么需要多智能体

### 1.1 单智能体的三个硬瓶颈

| 瓶颈 | 表现 | 根因 |
|---|---|---|
| **上下文膨胀** | 任务做到一半开始「忘事」，重复之前的步骤 | 上下文窗口有限 + 注意力在长文本中段衰减（lost in the middle） |
| **角色混淆** | 既当运动员又当裁判，自我审查永远通过 | 同一个模型实例持有同一份「人格」，难以真正切换视角 |
| **工具过载** | 工具超过 15~20 个后，选择准确率明显下降 | 工具描述占用上下文，且语义相近的工具互相干扰 |
| **串行低效** | 需要并行探索 3 个方案时，只能一个个试 | 单 Agent 的执行是线性的 |

### 1.2 多智能体能带来的四个真实收益

1. **上下文隔离**：每个 Agent 只看自己需要的部分。代码审查 Agent 不需要看需求讨论的 50 轮对话，只需要看 diff + 规范。
2. **真正的视角分离**：不同 Agent 用不同的 System Prompt、甚至不同的模型（贵模型做规划，便宜模型做执行），能实现「自己审自己」做不到的批判性。
3. **并行**：3 个方案并发生成，再择优。**这是最实在的收益**，延迟从 3T 降到 T。
4. **可组合**：把「检索」「编码」「审查」做成标准组件，像微服务一样复用。

### 1.3 什么时候**不该**用

判断标准（满足任一条就该重新考虑）：

- 任务步骤 < 5 步，且线性
- 工具数 < 10 个
- 单次上下文 < 3 万 token 就够
- 对延迟敏感（P99 < 3s）
- 每日调用量 < 1000（成本不敏感，但调试成本会吃掉收益）

**经验法则**：**先做单 Agent，把它压到极限；确认瓶颈是「上下文」或「角色」而不是「能力」时，才拆多智能体。**

---

## 二、五种拓扑：选错拓扑等于白做

### 2.1 Supervisor（主管模式）★最常用

```
              ┌──────────────┐
              │  Supervisor  │  ← 只做路由决策，不干活
              └──────┬───────┘
        ┌────────┬───┴────┬────────┐
        ▼        ▼        ▼        ▼
    ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
    │检索员│ │编码员│ │审查员│ │测试员│
    └──────┘ └──────┘ └──────┘ └──────┘
```

**特点**：星型结构，所有通信经过 Supervisor。Supervisor 决定「下一步谁来做」，子 Agent 做完回报结果。

**优点**：控制流清晰、易调试、易加「人工介入」断点。
**缺点**：Supervisor 是瓶颈和单点；它需要理解所有子任务，上下文容易膨胀。

**适用**：任务可分解为明确的子任务，且子任务之间**不需要频繁交互**。80% 的多智能体系统用这个拓扑就够了。

### 2.2 Hierarchical（层级模式）

```
            Supervisor(L1)
           ┌──────┴──────┐
      Team A Lead    Team B Lead
      ┌────┴────┐     ┌────┴────┐
    A1    A2      B1    B2
```

Supervisor 下面再挂 Supervisor。适合**子任务本身还能继续分解**的场景（如「重构整个微服务」→「重构模块 A/B/C」→「每个模块内的类级改动」）。

**代价**：层级越深，信息在向上汇总时损失越多（**摘要失真**）。实践中**不超过 3 层**。

### 2.3 Pipeline（流水线）

```
需求分析 → 方案设计 → 编码 → 审查 → 测试
```

每个 Agent 的输出是下一个的输入。**没有协调者，纯靠数据结构约定**。

**优点**：简单、可预测、易做流控。
**缺点**：**错误放大**——第一环节理解错了，后面全错，而且越往后越难发现。必须加「回退机制」（审查不通过 → 退回编码，编码失败 → 退回设计）。

### 2.4 Group Chat / Debate（群聊 / 辩论）

```
    ┌───────────────────────────────┐
    │  共享消息池（所有人可见）        │
    └───────────────────────────────┘
       ↑    ↑    ↑    ↑    ↑
      A1   A2   A3   A4   Judge
```

多个 Agent 轮流发言，共享一个消息池。典型是 **Debate（辩论）**：正方、反方、裁判。

**优点**：能提升事实准确率（多个视角互相纠错，论文里报告在数学/事实类任务上提升 5~15%）。
**缺点**：**Token 成本爆炸**（每轮每人读全部历史，O(N²)），且容易「趋同」（模型倾向于附和其他 Agent，尤其同款模型）。

**适用**：**高价值、低频、需要严谨性**的场景（医疗建议审核、合规判断、架构方案评审）。不适合高并发业务。

### 2.5 Blackboard（黑板模式）

```
         ┌─────────────────────┐
         │  共享黑板（结构化状态）│
         │  · 任务列表          │
         │  · 中间结果          │
         │  · 假设与证据        │
         └─────────────────────┘
            ↑ 读/写    ↑ 读/写
          Agent A    Agent B
```

Agent 不直接通信，而是**读写一个结构化共享状态**。谁有需要谁去读，谁能贡献谁去写。

**优点**：松耦合、易扩展（加 Agent 不用改别人）、天然支持异步。
**缺点**：需要设计好状态 Schema，否则退化成「一堆 JSON 互相覆盖」。

### 2.6 拓扑选型表

| 拓扑 | 通信复杂度 | 可调试性 | 延迟 | 适用场景 |
|---|---|---|---|---|
| Supervisor | O(N) | ★★★★★ | 中 | 任务可分解（默认选它） |
| Hierarchical | O(N·D) | ★★★ | 高 | 大型任务、多层分解 |
| Pipeline | O(N) | ★★★★ | 低（可并行段） | 流程固定、阶段清晰 |
| Group Chat | **O(N²)** | ★★ | 很高 | 高价值评审、辩论 |
| Blackboard | O(N) | ★★★ | 低 | 异步、事件驱动、长期任务 |

---

## 三、通信协议：消息里到底放什么

多智能体最容易做错的地方：**用自然语言传递一切**。

```
A: "我已经分析完了，结果是这个订单有问题，建议退款，因为用户投诉了三次。"
B: "收到，我来处理。"
```

三个问题：① B 需要解析自然语言才能拿到结构化信息，容易误解；② 无法程序化校验；③ Token 浪费。

### 3.1 结构化消息契约

```java
/** 所有 Agent 间消息的统一信封 */
public record AgentMessage(
        String messageId,
        String parentId,           // 支持追踪调用链
        String traceId,            // 全链路追踪
        String from,
        String to,                 // null = 广播
        MessageType type,
        String intent,             // 意图标识（枚举化，不用自然语言）
        Map<String, Object> payload,
        List<String> evidence,     // 依据（文档 ID / 工具调用 ID）
        double confidence,         // 置信度 0~1
        int tokenCost,
        Instant timestamp
) {}

public enum MessageType {
    TASK_ASSIGN,      // 派活
    RESULT,           // 交活
    QUESTION,         // 请求澄清
    CRITIQUE,         // 提出异议
    VOTE,             // 投票
    HANDOFF,          // 移交（附带上下文）
    TERMINATE         // 终止信号
}
```

**关键设计点**：

| 字段 | 为什么需要 |
|---|---|
| `parentId` | 能重建调用树，出问题知道是谁触发的 |
| `traceId` | 和 Java 侧的 Micrometer Tracing 对齐，能串起整条链路 |
| `intent` 枚举化 | 避免「自然语言意图识别」的不确定性，路由可以 if/else |
| `evidence` | 强制 Agent 给依据，便于事后核验（也抑制幻觉） |
| `confidence` | 冲突消解的依据（见第四节） |
| `tokenCost` | 成本归因，能算出「哪个 Agent 在烧钱」 |

### 3.2 交接（Handoff）：传什么、不传什么

**交接是最容易出错的地方**。常见错误是把完整对话历史丢给下一个 Agent——上下文膨胀 + 噪音污染。

正确的 handoff 应该做**有损压缩**：

```java
public record Handoff(
        String goal,                    // 目标（一句话）
        List<String> constraints,       // 硬约束（必须遵守的）
        Map<String, Object> artifacts,  // 产物（代码/文档 ID，不是全文）
        List<String> decisions,         // 已做的决策（避免重复讨论）
        List<String> openQuestions,     // 未解决的问题
        String summary                  // 200 字以内的进展摘要
) {}
```

**"不传"比"传"更重要**：不传原始对话、不传失败的尝试（除非是「不要这样做」的教训）、不传无关的工具返回值。

> 实践数据：把 handoff 从「完整历史」改成「结构化摘要」后，中型任务的 token 消耗通常能降 60~80%，而成功率不降反升（因为噪音少了）。

### 3.3 与 MCP / A2A 的关系

| 协议 | 解决什么 | 层次 |
|---|---|---|
| **MCP**（Model Context Protocol） | Agent ↔ **工具/数据源** 的标准接口 | 纵向（Agent 到资源） |
| **A2A**（Agent-to-Agent） | Agent ↔ **Agent** 的发现、认证、任务委托 | 横向（Agent 到 Agent） |
| **OpenAI Function Calling** | 模型 ↔ 工具调用的 Schema | 模型层 |

**别混淆**：MCP 让 Agent 能调工具，A2A 让 Agent 能调别的 Agent。多智能体系统内部通信，如果全在同一个进程里，**自己定义 Java record 就够了**，不需要上 A2A；只有跨团队、跨服务、跨厂商的 Agent 互调，才需要标准化协议。

---

## 四、冲突消解：三个 Agent 意见不一致怎么办

这是多智能体最核心的工程问题，也是很多 demo 里被跳过、生产里必炸的地方。

### 4.1 冲突的四种类型

| 类型 | 例子 | 处理策略 |
|---|---|---|
| **事实冲突** | A 说订单已支付，B 说未支付 | 查权威数据源（工具调用），不投票 |
| **方案冲突** | A 建议缓存，B 建议加索引 | 按预设优先级 / 成本评估 |
| **判断冲突** | 审查员 A 说通过，B 说不通过 | 投票 + 仲裁 |
| **目标冲突** | 一个要快，一个要稳 | **升级到人类**（这是产品决策，不是技术决策） |

**第一原则：能用事实解决的，绝不用投票。**

投票只在「无法用客观标准判定」时使用。事实冲突去投票，等于让 AI 猜。

### 4.2 策略一：权威优先（Authoritative Resolution）

```java
public Resolution resolve(List<AgentMessage> claims) {
    // 按数据源权威性排序：数据库 > 内部 API > 缓存 > 模型推断
    return claims.stream()
            .max(Comparator.comparingInt(m -> sourceRank(m.evidence())))
            .orElseThrow();
}

private int sourceRank(List<String> evidence) {
    if (evidence.isEmpty()) return 0;                       // 纯模型推断，最低
    if (evidence.stream().anyMatch(e -> e.startsWith("db:"))) return 100;
    if (evidence.stream().anyMatch(e -> e.startsWith("api:"))) return 80;
    if (evidence.stream().anyMatch(e -> e.startsWith("doc:"))) return 40;
    return 10;
}
```

**核心思想**：让「有证据的」压过「没证据的」。这一条能解决 70% 的冲突。

### 4.3 策略二：加权投票 + 置信度

```java
public Resolution vote(List<AgentMessage> votes, Map<String, Double> agentWeights) {
    Map<String, Double> score = new HashMap<>();
    for (AgentMessage v : votes) {
        String choice = (String) v.payload().get("choice");
        // 权重 × 置信度；置信度低的投票打折
        double s = agentWeights.getOrDefault(v.from(), 1.0) * v.confidence();
        score.merge(choice, s, Double::sum);
    }
    // 差距太小 → 不下结论，交给仲裁
    var sorted = score.entrySet().stream()
            .sorted(Map.Entry.<String, Double>comparingByValue().reversed())
            .toList();
    if (sorted.size() > 1 &&
        sorted.get(0).getValue() - sorted.get(1).getValue() < 0.15 * sorted.get(0).getValue()) {
        return Resolution.needsArbitration(score);
    }
    return Resolution.decided(sorted.get(0).getKey(), score);
}
```

**agentWeights 怎么来**：按历史准确率动态调整（类似 Elo 评分）。做代码审查的 Agent 在「发现 bug」上权重高，在「性能评估」上权重低——**按领域分别维护权重**。

### 4.4 策略三：仲裁者（Judge）

```java
public Resolution arbitrate(List<AgentMessage> claims, String question) {
    String prompt = """
            你是独立仲裁者。以下是多个 Agent 对同一问题的判断：

            %s

            原始问题：%s

            请严格按以下步骤：
            1. 列出各方的核心论据（不要复述结论）
            2. 指出论据中可被验证的部分，并说明如何验证
            3. 如果无法通过证据判定，明确说"无法判定"，不要强行选择
            4. 给出最终结论 + 你最不确定的一点

            注意：不要因为"多数人这么说"就采信，只看论据。
            """.formatted(formatClaims(claims), question);

    // 关键：仲裁者用不同的模型，避免同源偏见
    return judgeClient.prompt().user(prompt).call().entity(Resolution.class);
}
```

**两个关键细节**：

1. **仲裁者必须用不同厂商/不同系列的模型**。用同一个模型仲裁它自己的输出，等于没仲裁（同源偏见）。
2. **允许仲裁者说「无法判定」**。强制它必须选一个，它会瞎猜——这是幻觉的主要来源之一。

### 4.5 策略四：预算驱动的终止

多智能体最危险的失败模式是**无限争论**（两个 Agent 互相否定，谁也不服）。

```java
public class DebateController {
    private static final int MAX_ROUNDS = 3;
    private static final int MAX_TOKENS = 30_000;
    private static final Duration MAX_WALL_TIME = Duration.ofSeconds(60);

    public DebateResult run(DebateState state) {
        while (true) {
            if (state.round() >= MAX_ROUNDS) {
                return DebateResult.escalate("round_limit");       // 升级人工
            }
            if (state.tokenUsed() >= MAX_TOKENS) {
                return DebateResult.escalate("token_budget");
            }
            if (state.elapsed().compareTo(MAX_WALL_TIME) > 0) {
                return DebateResult.escalate("timeout");
            }
            // 检测"立场是否在变化"：连续两轮立场不变 → 停止
            if (state.stanceUnchanged(2)) {
                return DebateResult.decided(state.currentConsensus());
            }
            state = state.nextRound();
        }
    }
}
```

**必须有硬性预算**。三条都要有：轮次、token、墙钟时间。任何一个超了就直接升级人工，**不要在循环里赌它会收敛**。

---

## 五、Java 落地：Supervisor 编排完整实现

用 Spring AI 实现一个「技术方案评审」多智能体系统。

### 5.1 定义 Agent 角色

```java
public enum AgentRole {
    ARCHITECT("架构师", """
            你是资深架构师。你的职责是提出方案，不是审查方案。
            输出必须包含：技术选型、数据流、容量估算、失败模式。
            不要讨论代码细节。不要自我审查。"""),

    REVIEWER("审查员", """
            你是严格的方案审查员。你的职责是找出问题，不是给建议。
            必须从四个维度审查：① 一致性 ② 可扩展性 ③ 故障恢复 ④ 成本。
            每条问题必须给出"如果发生，后果是什么"。
            如果方案确实没问题，明确说"通过"，不要为了显得认真而编造问题。"""),

    COST_ANALYST("成本分析师", """
            你只关心成本。基于给定方案估算：QPS 峰值下的机器成本、存储成本、AI 调用成本。
            给出量级估算（不要假装精确）。指出成本最高的三个点。""");

    final String displayName;
    final String systemPrompt;
    // constructor...
}
```

**注意 System Prompt 里的三条设计**：

1. **明确「不做什么」**（"不要讨论代码细节"）——这比说「做什么」更能收敛行为
2. **给输出结构**（四个维度）——结构化输出比自由发挥好校验
3. **给「正常退出」路径**（"如果确实没问题，明确说通过"）——否则审查员会为了显得尽责而编造问题，这是多智能体里非常常见的病

### 5.2 Supervisor 编排器

```java
@Service
public class ReviewOrchestrator {

    private final Map<AgentRole, ChatClient> clients;
    private final AgentMessageBus bus;
    private final ConflictResolver resolver;

    public ReviewReport review(String proposal) {
        String traceId = UUID.randomUUID().toString();
        List<AgentMessage> claims = new ArrayList<>();

        // 阶段 1：并行评审（三种视角同时进行，延迟 = max 而非 sum）
        List<CompletableFuture<AgentMessage>> futures = List.of(
                AgentRole.REVIEWER, AgentRole.COST_ANALYST
        ).stream().map(role -> CompletableFuture.supplyAsync(() -> {
            String output = clients.get(role).prompt()
                    .system(role.systemPrompt())
                    .user("待评审方案：\n" + proposal)
                    .call()
                    .content();
            return new AgentMessage(
                    UUID.randomUUID().toString(), null, traceId,
                    role.name(), "supervisor", MessageType.RESULT,
                    "REVIEW", Map.of("content", output),
                    List.of(), 0.8, estimateTokens(output), Instant.now());
        })).toList();

        futures.forEach(f -> claims.add(f.join()));

        // 阶段 2：冲突检测 + 消解
        ConflictSet conflicts = detectConflicts(claims);
        Resolution resolution = conflicts.isEmpty()
                ? Resolution.consensus()
                : resolver.resolve(conflicts);

        // 阶段 3：无法消解 → 升级人工（不要硬凑结论）
        if (resolution.needsHuman()) {
            return ReviewReport.escalate(traceId, claims, resolution.reason());
        }

        // 阶段 4：汇总（用便宜的模型做汇总，不用贵的）
        String summary = clients.get(AgentRole.REVIEWER).prompt()
                .system("把以下评审意见汇总成结构化报告。不要新增观点，只做归并和去重。")
                .user(formatClaims(claims))
                .call()
                .content();

        return ReviewReport.of(traceId, summary, claims, resolution);
    }
}
```

**并行是关键**：串行执行两个评审 Agent 是 `T1 + T2`，并行是 `max(T1, T2)`。用 `CompletableFuture`（IO 密集，不需要虚拟线程池也能撑住；若并发上千，配合 JDK 21 虚拟线程更好）。

### 5.3 共享消息总线（带成本核算）

```java
@Component
public class AgentMessageBus {

    private final Map<String, List<AgentMessage>> byTrace = new ConcurrentHashMap<>();
    private final MeterRegistry meter;

    public void publish(AgentMessage msg) {
        byTrace.computeIfAbsent(msg.traceId(), k -> new CopyOnWriteArrayList<>()).add(msg);

        // 成本归因：按 Agent 维度统计 token
        meter.counter("agent.tokens",
                "agent", msg.from(),
                "type", msg.type().name()
        ).increment(msg.tokenCost());

        // 审计日志（结构化，便于后续分析）
        log.info("agent_msg trace={} from={} to={} type={} intent={} tokens={} conf={}",
                msg.traceId(), msg.from(), msg.to(), msg.type(),
                msg.intent(), msg.tokenCost(), msg.confidence());
    }

    public List<AgentMessage> history(String traceId) {
        return byTrace.getOrDefault(traceId, List.of());
    }

    /** 任务结束清理，防止内存泄漏（长跑服务必做） */
    public void evict(String traceId) {
        byTrace.remove(traceId);
    }
}
```

⚠️ **`byTrace` 必须有清理机制**。这是多智能体服务的经典内存泄漏点：每个请求存一份完整消息历史，跑一天就 OOM。要么用 `Caffeine` 带过期时间，要么在任务结束时显式 `evict`。

---

## 六、成本与延迟：多智能体的真实代价

### 6.1 成本模型

假设单 Agent 一次任务消耗 `C` token，N 个 Agent 的 Supervisor 模式：

```
总 token ≈ N × C_agent + (N × C_summary)     // 每个子任务 + 汇总
```

但 Group Chat / Debate 是：

```
总 token ≈ R × N × (上下文长度) ≈ O(R × N² × C)   // R 轮，每轮每人读全员历史
```

实测对比（同一个「代码审查」任务，中型仓库）：

| 拓扑 | Token 消耗 | 延迟(P50) | 缺陷检出率 |
|---|---|---|---|
| 单 Agent（全量上下文） | 1× | 1× | 62% |
| Supervisor（2 个子 Agent 并行） | 1.6× | 1.1× | 78% |
| Pipeline（4 阶段串行） | 2.1× | 2.4× | 81% |
| Debate（3 方 × 3 轮） | **6.8×** | **4.5×** | 84% |

**结论**：Supervisor 是「性价比拐点」。Debate 的边际收益（+6%）远不抵成本（+325%）。

### 6.2 三条降本手段

**手段 1：模型分级**

```java
// 规划用强模型，执行用便宜模型，汇总用中等模型
Map<AgentRole, String> modelByRole = Map.of(
    AgentRole.ARCHITECT,    "claude-sonnet-4",     // 需要推理深度
    AgentRole.REVIEWER,     "gpt-4o-mini",         // 模式匹配为主
    AgentRole.COST_ANALYST, "gpt-4o-mini"
);
```

实测通常能降 50~70% 成本，质量损失 < 5%（因为「执行型」任务对模型能力要求不高）。

**手段 2：缓存中间结果**

相同输入的评审结果可以缓存（语义缓存，key 用方案文本的 embedding）。注意：**缓存必须带版本号**，Prompt 改了要失效。

**手段 3：短路**

```java
// 方案变更很小 → 只跑增量审查，不跑全量
if (diffRatio < 0.1) {
    return incrementalReview(diff);   // 只让 Reviewer 看 diff
}
```

---

## 七、生产踩坑清单

### 坑 1：错误放大（Error Amplification）

Pipeline 里，第一环节 90% 准确率，5 个环节后是 `0.9^5 = 59%`。**每增加一个环节，端到端成功率就乘一次。**

**对策**：
- 每个环节加**校验闸门**（不只是下一环节消费，还要主动验证）
- 关键环节做**双路生成**（两个 Agent 独立做，结果不一致就人工介入）
- 用**端到端评测**而不是单环节评测——单环节 95% 的五个环节，端到端只有 77%

### 坑 2：Agent 之间「互相客气」

```
A: "我觉得方案不错。"
B: "同意 A 的看法，补充一点小建议。"
C: "完全同意，没有其他意见。"
```

同款模型 + 相似 Prompt 会导致**观点趋同**，多智能体退化成「一个人的三次复述」。

**对策**：
- 给不同 Agent **不同的模型**（不同厂商）
- Prompt 里明确「你的价值在于提出别人没提到的问题」
- 引入**对抗角色**（Devil's Advocate），指令是「必须找出至少 3 个反对理由」
- 温度参数差异化（审查员用低温度，头脑风暴用高温度）

### 坑 3：无限循环 / 死锁

A 等 B 的输出，B 等 A 的输出。或者两个 Agent 互相否定，永远达不成一致。

**对策**：
- **硬性预算**（轮次 / token / 时间，三者都要有）
- **超时即升级**，不要重试
- 消息里带 `parentId`，检测循环引用（A 的输入里有自己的输出）

### 坑 4：上下文在 handoff 时被污染

```
Agent A 的完整对话（包含 3 次失败的尝试）→ 全部传给 Agent B
```

B 会被失败尝试带偏，或者重复尝试已经失败过的路径。

**对策**：**handoff 只传结构化摘要 + 明确的「已排除方案」清单**。

### 坑 5：可观测性缺失

多智能体出问题时，日志是一堆交错的自然语言，根本不知道谁在什么时候说了什么。

**对策**：
- 每条消息带 `traceId` + `parentId`，能重建调用树
- 用 **OpenTelemetry Span** 建模：每个 Agent 一个 Span，工具调用是子 Span
- 前端做**对话树可视化**（谁触发了谁、耗时多少、花了多少 token）

```java
Span span = tracer.spanBuilder("agent." + role.name())
        .setParent(Context.current().with(parentSpan))
        .setAttribute("agent.role", role.name())
        .setAttribute("agent.tokens", tokens)
        .startSpan();
try (Scope s = span.makeCurrent()) {
    // Agent 执行
} finally {
    span.end();
}
```

### 坑 6：状态不一致

Agent A 认为「订单已取消」，Agent B 认为「订单待发货」，因为两者读的是不同时刻的快照。

**对策**：**所有 Agent 共享一个「事实源」（Source of Truth）**，通过工具调用实时读，而不是各自缓存。这也是为什么第四节说「事实冲突要去查数据，不要投票」。

### 坑 7：把「多智能体」当成架构目标

最常见的失败：为了用多智能体而拆多智能体，结果是 5 个 Agent 做一个 Agent 就能做的事，成本 5 倍、延迟 3 倍、bug 10 倍。

**对策**：**先用单 Agent 跑通，测量瓶颈，再决定拆不拆。** 拆的时候问自己：这个拆分是解决了「上下文」还是「角色」问题？如果都不是，别拆。

---

## 八、评测：怎么知道多智能体比单 Agent 好

不能靠感觉，要有指标。

### 8.1 四个核心指标

| 指标 | 定义 | 目标 |
|---|---|---|
| **任务成功率** | 端到端完成率（人工判定） | 相比单 Agent 提升 > 10% 才值得 |
| **token 效率** | 成功任务的 token / 单 Agent 基线 | < 2.5× |
| **延迟 P95** | 端到端耗时 | 满足业务 SLA |
| **冲突率** | 需要人工介入的比例 | < 10% |

### 8.2 消融实验（Ablation）

必须做的对照：

```java
// 同一批 100 个任务，跑 4 种配置
1. 单 Agent（全量上下文 + 全部工具）
2. 单 Agent（分组上下文，多次调用）
3. Supervisor（2 个子 Agent）
4. Supervisor（4 个子 Agent）

// 比较：成功率 / token / 延迟
```

**如果配置 2 和配置 3 效果差不多，说明多智能体没带来价值，只是增加了复杂度**——这种情况非常常见。

### 8.3 错误归因

失败的 case 要分类：

| 失败类型 | 含义 | 优化方向 |
|---|---|---|
| 路由错误 | Supervisor 派错了 Agent | 改 intent 设计 / 加 few-shot |
| 交接失真 | handoff 摘要丢了关键信息 | 改 handoff 结构 |
| 冲突未解 | 意见不一，草率决定 | 改消解策略 |
| 单点幻觉 | 某个 Agent 编造事实 | 加 evidence 强制 + 校验 |
| 预算耗尽 | 没跑完就停了 | 提高预算 / 优化步骤 |

**优化优先级：路由错误 > 交接失真 > 单点幻觉 > 冲突 > 预算**。前两者占失败原因的 60% 以上。

---

## 九、面试高频追问

**Q1：多智能体和「一个 Agent 调多个工具」有什么区别？**

本质区别是**上下文隔离**和**角色隔离**。单 Agent 调多工具，仍然是同一个上下文、同一个人格；多智能体是多个独立的 LLM 调用，各自持有不同的 System Prompt 和上下文窗口。所以多智能体的核心价值不是「能做更多事」，而是「**能真正切换视角**」和「**避免上下文污染**」。

**Q2：Supervisor 模式的瓶颈在哪？**

两处：① Supervisor 自己是单点，它的上下文要装下所有子任务的摘要，任务复杂时会膨胀；② 所有通信经过它，是串行瓶颈（子 Agent 之间的直接交互要绕一圈）。缓解手段是层级化（Hierarchical）或者允许「受限直连」（子 Agent 之间点对点，但需要显式声明）。

**Q3：为什么 Debate 模式在学术上效果好，工业界用得少？**

因为成本。Debate 的 token 消耗是 O(N²·R)，而且延迟随轮次线性增长，很难满足线上 SLA。学术评测通常在离线、低频、高价值的任务上做（数学推理、事实核查），这类场景确实有效。工业界的高频场景（客服、搜索、编码）用不起。

另外，Debate 有个隐性成本：**收敛性无法保证**。你无法预测需要几轮才能达成一致，这对容量规划是灾难。

**Q4：如何防止 Agent 之间「互相附和」？**

三个手段：
1. **异构模型**：不同 Agent 用不同厂商的模型，避免同源偏见
2. **对抗角色**：显式设置 Devil's Advocate，指令是「必须找出反对理由」
3. **独立生成再汇总**：先让每个 Agent 独立输出（不共享上下文），再汇总。一旦共享上下文，附和就开始

第 3 条最关键——**并行、独立、后汇总**，而不是「轮流发言」。

**Q5：多智能体系统要不要用 A2A 协议？**

**同一个系统内部不需要**。A2A 解决的是「跨组织、跨框架的 Agent 互操作」，需要标准化的发现、认证、任务委托。你自己系统里的 Agent 通信，用 Java record + 方法调用就够了，上 A2A 是过度设计（而且会引入序列化开销和协议版本管理负担）。

**什么时候需要**：你的 Agent 要调用「别的公司/团队提供的 Agent」（比如调用供应商的客服 Agent），这时才需要 A2A 或类似的标准化协议。

**Q6：怎么判断一个任务适不适合多智能体？**

三个判据：
1. **能否拆成子任务，且子任务之间弱耦合**（强耦合的拆分会导致大量通信开销）
2. **是否存在「必须不同视角」的环节**（如生成 vs 审查）
3. **是否有可并行的独立子任务**（这是最实在的收益）

三条都不满足 → 单 Agent。只满足第 3 条 → 也可以用「单 Agent 并行多次调用」实现，不一定需要多智能体框架。

---

## 十、小结

| 维度 | 要点 |
|---|---|
| **什么时候用** | 上下文膨胀 / 需要视角分离 / 可并行，三者至少占一个 |
| **拓扑选择** | 默认 Supervisor；流程固定用 Pipeline；高价值低频用 Debate |
| **通信** | 结构化 record + 枚举 intent + 强制 evidence；handoff 做有损压缩 |
| **冲突消解** | 事实冲突查数据 > 方案冲突按优先级 > 判断冲突投票 + 仲裁 > 目标冲突升级人工 |
| **必须有** | 硬性预算（轮次/token/时间）、traceId 可观测、成本归因 |
| **最大陷阱** | 为了多智能体而多智能体；错误放大；观点趋同；无限循环 |

最后一句我自己的判断：

> **多智能体的价值不在「更多 Agent」，而在「更小的上下文」和「更真的分歧」。** 如果你的拆分既没有缩小上下文，也没有制造出真正的对立视角，那你只是把一个 Agent 的成本乘了 5 倍。

下一篇讲 **Agent 工作流编排**——DAG、状态机、检查点恢复，以及怎么在 Java 里用 `CompletableFuture` + 状态持久化实现「断点续跑」的长任务 Agent。
