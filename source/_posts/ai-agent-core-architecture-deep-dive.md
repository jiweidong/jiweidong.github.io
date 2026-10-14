---
title: 【AI Agent】Agent 核心架构深度解析：ReAct、Plan-and-Execute 与 Reflection 模式
date: 2026-10-14 08:40:00
tags:
  - AI
  - Agent
  - ReAct
  - 架构
  - 工具调用
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】Agent 核心架构深度解析：ReAct、Plan-and-Execute 与 Reflection

## 前言

2024 年之后，"Agent（智能体）"成了 AI 应用开发的高频词。但很多讨论停留在 Demo：给模型接几个工具，能问答就算 Agent。真正落到生产，会遇到一连串硬问题：

- 模型为什么**反复调用同一个工具**、陷入死循环？
- 为什么 **Plan-and-Execute 规划得漂漂亮亮，执行却一错到底**？
- Reflection（自我反思）到底是真的"变聪明"，还是只是**多烧了几倍 token**？
- 用 Java 落地时，**循环、状态、工具执行**该怎么组织才不失控？

这篇文章不堆概念，而是把 Agent 的**运行时结构**拆开：从最朴素的 `LLM + Tools` 循环，到 **ReAct**、**Plan-and-Execute**、**Reflection** 三种主流模式，逐一讲**原理、代码骨架、适用场景与生产陷阱**，并给出 Java（Spring AI / LangChain4j 视角）的落地建议。这是"Agent 智能体开发"这条路线的第一块硬骨头。

## 一、Agent 的最小定义：一个带记忆和工具的循环

先去掉所有花哨名词。一个 Agent 的最小骨架只有四个部件：

```
Agent = LLM（大脑） + Tools（手脚） + Memory（记忆） + Loop（循环）
```

用一段伪代码表示：

```java
Object run(String userGoal) {
    List<Message> context = new ArrayList<>();
    context.add(systemPrompt());
    context.add(user(userGoal));

    for (int step = 0; step < MAX_STEPS; step++) {          // Loop
        Message reply = llm.chat(context, tools);            // LLM 决策
        context.add(reply);

        if (reply.isFinalAnswer()) {                         // 终止条件
            return reply.content();
        }
        for (ToolCall call : reply.toolCalls()) {            // Tools 执行
            String result = toolExecutor.execute(call);      // 真正干活
            context.add(toolResult(call.id(), result));
        }
    }
    throw new MaxStepsExceededException();
}
```

**所有 Agent 框架（AutoGPT、LangChain、LangGraph、Spring AI、LangChain4j）本质上都是这个循环的变体。** 区别只在于：循环怎么转（ReAct）、什么时候规划（Plan-and-Execute）、循环里加不加自省（Reflection）。

理解这一点，你就不会被"XX 框架"绕晕——**框架只是给这个循环配了更好的状态管理与工具生态。**

## 二、ReAct：思考与行动交织

### 2.1 原理

ReAct = **Reasoning + Acting**，出自 2022 年论文《ReAct: Synergizing Reasoning and Acting in Language Models》。核心是让模型在每一步都输出一个**"思考（Thought）→ 行动（Action）→ 观察（Observation）"**的三元组，循环推进。

```
Thought: 用户想知道北京现在的天气，我需要调用天气工具
Action: getWeather(city="北京")
Observation: 北京 晴，26℃，湿度 40%
Thought: 已经拿到天气，可以直接回答
Action: finish("北京现在晴，26℃，比较舒适")
```

不用 Function Calling 的纯 prompt 版（ReAct 原始形态）：

```
你可以使用以下工具：
- getWeather(city): 查询天气
- calculator(expr): 计算

请严格按格式输出：
Thought: <你的思考>
Action: <工具名>[<参数>]
Observation: <工具返回，由系统填充>
...（重复直到可以回答）
Final Answer: <最终答案>
```

用 Function Calling 时，`Thought` 变成模型内部的推理（或显式的 reasoning 字段），`Action` 变成结构化的 `tool_calls`，`Observation` 变成 `tool` 消息。

### 2.2 Java 落地骨架

```java
public class ReActAgent {
    private final ChatClient llm;          // Spring AI
    private final ToolRegistry tools;
    private static final int MAX_STEPS = 8;

    public String run(String goal) {
        List<Message> history = new ArrayList<>(List.of(
                new SystemMessage(REACT_SYSTEM_PROMPT),
                new UserMessage(goal)));

        for (int i = 0; i < MAX_STEPS; i++) {
            ChatResponse resp = llm.call(history, tools.specs());
            AssistantMessage msg = resp.result().output();
            history.add(msg);

            if (msg.toolCalls().isEmpty()) {
                return msg.text();                 // 没有工具调用 = 最终答案
            }
            for (ToolCall call : msg.toolCalls()) {
                String obs = safeExecute(call);    // 执行 + 异常兜底
                history.add(new ToolResponseMessage(call.id(), call.name(), obs));
            }
        }
        return "抱歉，任务过于复杂，已超出最大步数。";
    }
}
```

### 2.3 适用与陷阱

- **适合**：步骤数不确定、需要边查边想、探索型任务（查资料、多轮检索、客服）。
- **陷阱**：
  - **无终止保护 → 死循环**：模型可能反复调同一个工具。必须设 `MAX_STEPS` + 工具去重（同参数同工具短时间内不再执行）+ 超时。
  - **上下文膨胀**：每一步的 Thought/Observation 都进历史，步数一多 token 爆炸。需要**中间结果摘要 / 截断**。
  - **错误累积**：前一步的 Observation 若含噪声，后续会"将错就错"。

### 2.4 ReAct 的 Java 类比

对 Java 工程师：**ReAct 很像一个"带状态机的 while(true) 事件循环"**——`Thought` 是决策，`Action` 是下发指令，`Observation` 是回调。你在 Netty/状态机里处理过的"事件 → 决策 → 执行 → 新事件"，这里换了个主体。

## 三、Plan-and-Execute：先规划，后执行

### 3.1 原理

ReAct 的问题是"走一步看一步"，短任务灵活，但**长任务容易跑偏、缺乏全局观**。Plan-and-Execute 把它拆成两阶段：

```
阶段一 Planner：LLM 先把任务拆成一个"步骤清单（Plan）"
阶段二 Executor：逐步执行，每步可以是一个 ReAct 子 Agent
（可选）Replanner：执行过程中根据结果动态调整计划
```

```
用户：帮我调研三家竞品 A/B/C 的定价，汇成表格

Plan:
  1. 检索竞品 A 的定价页
  2. 检索竞品 B 的定价页
  3. 检索竞品 C 的定价页
  4. 汇总并生成对比表格

Execute:
  步骤1 → [ReAct 子 Agent: 搜索 → 打开页面 → 抽取价格]
  步骤2 → ...
  步骤4 → 生成表格（可调用代码工具）
```

### 3.2 Java 落地：计划本身就是个 DAG / 状态机

对 Java 后端，Plan-and-Execute 的"计划"天然对应**工作流编排**：

```java
record Step(int id, String description, List<Integer> dependsOn, StepStatus status) {}

public class PlanExecuteAgent {
    public String run(String goal) {
        List<Step> plan = planner.plan(goal);        // LLM 产出 DAG

        // 拓扑排序 + 逐层执行；无依赖的步骤可并行
        for (List<Step> layer : topoLayers(plan)) {
            layer.parallelStream().forEach(step -> {  // 虚拟线程更佳
                String result = executor.execute(step, context); // 内部可再是 ReAct Agent
                context.put(step.id(), result);
                step.markDone();
            });
        }
        return synthesizer.summarize(goal, context);  // 汇总
    }
}
```

这和 **Flowable / 自研工作流引擎**的思想完全一致：**DAG、并行分支、状态流转、失败重试**。你在 Java 侧积累的编排经验，在这里几乎直接复用——**这是 Java 工程师做 Agent 的最大结构性优势。**

### 3.3 适用与陷阱

- **适合**：步骤明确、可预先拆解、长流程任务（调研报告、数据流水线、多步审批）。
- **陷阱**：
  - **计划僵化**：现实执行到第 3 步发现前提错了，静态 Plan 无法调整 → 需要 **Replanner**（每步后让 LLM 决定"是否修订计划"）。
  - **规划质量依赖模型能力**：小模型规划能力弱，往往不如 ReAct 稳。
  - **错误传播**：一步执行错，后续全错 → 需要在步骤间加**校验点（guard）**。

## 四、Reflection：让 Agent 自我批判

### 4.1 原理

Reflection（反思）的核心：**让模型生成结果后，再让（或同一个）模型评审这个结果，根据批评迭代改进。** 典型循环：

```
生成 (Generate) → 批判 (Critique) → 修订 (Revise) → 再批判 → ...
```

代表工作：Reflexion（2023）、Self-Refine（2023）。它不改变工具循环，而是在**输出质量**上加了一层"自我编辑"。

```java
public String withReflection(String task) {
    String draft = generator.generate(task);
    for (int i = 0; i < MAX_REFLECT; i++) {
        Critique c = critic.critique(task, draft);   // LLM 评审：找错、提改进
        if (c.isGoodEnough()) break;                 // 达标即停
        draft = revisor.revise(task, draft, c);      // 根据批评修订
    }
    return draft;
}
```

### 4.2 它真的有用吗？——理性看待

- **有用的场景**：代码生成（编译/测试通过作为客观反馈）、写作润色、SQL 生成（可用执行结果验证）。
- **代价**：每次反思都是一次完整 LLM 调用，**token 与延迟成倍增长**。
- **陷阱**：
  - **无客观反馈时容易"假反思"**：模型可能"假装改进"，甚至越改越差（尤其小模型）。
  - **必须先有"评价标准"**：最好接**外部验证器**（单测、编译、lint、规则引擎），而不是只让模型自评。
  - 要设**最大反思轮数**与**收益递减退出**。

**结论**：Reflection 适合"有客观验证信号"的任务；纯主观任务上的 Reflection，投入产出比要谨慎评估。

## 五、三种模式对比与组合

| 维度 | ReAct | Plan-and-Execute | Reflection |
|---|---|---|---|
| 核心 | 边想边做 | 先规划后执行 | 生成后自省修订 |
| 适合任务 | 探索型、短流程 | 长流程、可拆解 | 输出质量敏感 |
| 全局观 | 弱 | 强 | 不涉及 |
| Token 成本 | 中 | 中高 | 高（多次调用） |
| 主要风险 | 死循环、上下文膨胀 | 计划僵化、错误传播 | 假反思、成本失控 |
| Java 类比 | while + 状态机 | 工作流 / DAG 编排 | 生成-评审-修订流水线 |

**生产里往往是组合使用**：

```
外层：Plan-and-Execute（把大任务拆成 DAG）
  └─ 每个执行节点：ReAct 子 Agent（带工具的循环）
        └─ 关键输出：Reflection 精修（如生成 SQL/代码）
```

现代框架（LangGraph、Spring AI Alibaba 的 Graph、LangChain4j 的 Agent）都在往**"可编排的图（Graph）"**方向走——这恰好是 Java 工程师最熟悉的那套：**把 Agent 当有状态的服务编排来设计**。

## 六、生产级必须解决的问题

### 6.1 终止条件与资源上限

- **最大步数** `MAX_STEPS`：防死循环。
- **总超时**：整条链路的时间预算。
- **token 预算**：防成本失控。
- **工具去重**：同参数同工具在短时间内不重复执行。

### 6.2 记忆管理

- **短期**：本次任务的消息历史（注意截断/摘要）。
- **长期**：跨会话，通常落**向量库**做语义检索（记忆系统是另一个大话题）。
- **压缩**：历史过长时，用 LLM 摘要旧消息（**会丢细节，需权衡**）。

### 6.3 可观测

Agent 比普通应用难调试十倍，因为"决策过程"不透明。至少记录：

- 每一步的 Thought / Action / Observation；
- 工具调用的参数、耗时、结果状态；
- token 消耗与费用；
- 失败步骤与重试轨迹。

接 **OpenTelemetry / Micrometer**，把一次 Agent 运行当成一个 Trace，每步一个 Span。

### 6.4 安全与权限

- 工具最小权限；高危操作 human-in-the-loop；
- 防 **Prompt 注入**（工具返回的内容可能被注入恶意指令，回填上下文前要隔离/清洗）；
- 沙箱执行模型生成的代码（如果开了代码工具）。

## 七、面试高频追问

**Q1：Agent 和"调用工具的 Chatbot"有什么区别？**
关键在**自主循环**。Chatbot 是"一次问答，最多一次工具调用"；Agent 是"模型自主决定调用哪些工具、调用几轮、何时结束"的**闭环**，并有记忆与规划能力。

**Q2：ReAct 为什么会死循环？怎么防？**
模型可能重复选择同一个行动，或"行动-观察"无法收敛。防护：最大步数、工具调用去重、超时、给模型明确终止指令、检测重复 Observation。

**Q3：Plan-and-Execute 和 ReAct 怎么选？**
任务**能预先拆解、流程长** → Plan-and-Execute；任务**探索性强、依赖中间结果** → ReAct。实际常用"Planner + 每步 ReAct Executor"的混合。

**Q4：Reflection 一定会提升效果吗？**
不一定。它依赖**是否有客观评价信号**。有（编译/测试/规则校验）通常有效；纯主观任务上可能收益很小甚至为负，且成本成倍。要设轮数上限与收益退出。

**Q5：Agent 的记忆和 RAG 有什么区别？**
RAG 是**从外部知识库检索**相关信息注入上下文；记忆是 Agent **自己经历**的积累（历史对话、之前任务的结论）。长期记忆通常也用**向量检索**实现，所以技术上重叠，但语义不同（外部知识 vs 自身经验）。

**Q6：为什么说 Java 工程师做 Agent 有优势？**
Agent 的难点不在模型，而在**编排、状态、并发、幂等、可观测、安全**——这些正是 Java 后端的核心能力。把 Agent 当成"一个调用外部不确定服务的有状态工作流"，Java 的工程手段（线程池/虚拟线程、状态机、重试、熔断、Trace）几乎直接可用。

## 八、小结

- Agent 的最小骨架 = **LLM + Tools + Memory + Loop**，所有框架都是它的变体。
- **ReAct** 边想边做，灵活但怕死循环与上下文膨胀；
- **Plan-and-Execute** 先规划后执行，适合长流程，但需 Replanner 应对变化；
- **Reflection** 生成后自省，适合有客观反馈的场景，但要警惕成本与"假反思"。
- 生产落地真正的门槛是**终止控制、记忆管理、可观测、安全**，而这些恰好是 Java 后端的强项。
- 对转型中的 Java 工程师：**别把 Agent 当玄学，把它当"调用不确定外部服务的有状态编排"来设计**，你的既有经验就是最大的杠杆。

下一篇将深入 **Agent 记忆系统**：短期/长期记忆、向量记忆与总结压缩的实现与取舍。
