---
title: 【AI Agent】Agent 评测体系深度解析：基准、轨迹判分、LLM-as-Judge 与 CI 回归
date: 2026-10-29 08:40:00
tags:
  - AI
  - Agent
  - 评测
  - LLM-as-Judge
  - Java
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】Agent 评测体系深度解析：基准、轨迹判分、LLM-as-Judge 与 CI 回归

## 前言

Agent 项目有一个非常典型的上线路径：

第 1 周，Demo 跑通，团队兴奋；
第 2 周，加工具、加记忆、加多轮，效果"感觉更好了"；
第 3 周，改 Prompt、换模型、调温度，然后有人问："这次改动到底有没有变好？"

没人答得上来。

这不是工程能力问题，是**评测缺失**。传统后端有单测、集成测试、压测，Agent 却没有对应的基础设施：输出是自然语言、路径不唯一、同一个任务可能三步完成也可能十步完成、甚至"看起来完成了但其实没完成"。

于是团队陷入"凭感觉迭代"：改一个 Prompt，抽几个 case 看看，觉得行就上。上线后用户投诉"昨天还好好的"，回头找不到是哪次改动引入的。

本文讲清楚 Agent 评测的三层结构、主流基准能测什么不能测什么、怎么用 Java 搭一套可进 CI 的评测框架、以及 LLM-as-Judge 怎么校准才可信。

## 一、Agent 评测和 LLM 评测不是一回事

单轮 LLM 评测相对简单：给输入，比输出。要么精确匹配，要么用相似度，要么人工打分。

Agent 多了一个维度：**过程**。

```
任务：查一下我上周的订单，如果还没发货就取消，然后发邮件通知我

Agent 执行轨迹：
  1. search_orders(user_id, last_week)      -> 3 条订单
  2. get_order_detail(order_id=O1001)       -> status=SHIPPED
  3. get_order_detail(order_id=O1002)       -> status=PENDING
  4. cancel_order(order_id=O1002)           -> success
  5. send_email(to=user, subject=..., body=...) -> success
```

最终状态对了（订单取消了、邮件发了），但这条轨迹可能有这些问题：

- 第 3 步查的是 O1002，但用户说的是"上周的订单"，时间过滤对不对？
- 第 5 步邮件内容有没有泄漏其他订单信息？
- 如果 O1001 也是 PENDING，它为什么被跳过？
- 一共 5 步，能不能 3 步完成？多出来的两步是必要的吗？

**只看最终答案，这些问题一个都发现不了。** 所以 Agent 评测必须同时评"结果"和"过程"。

## 二、三层评测结构

| 层级 | 评什么 | 方法 | 频率 | 成本 |
|---|---|---|---|---|
| L1 组件级 | 单次工具调用是否正确、参数是否合法、检索是否命中 | 断言 + 精确匹配 | 每次提交 | 极低 |
| L2 轨迹级 | 步骤是否合理、有无冗余/循环、是否越权、是否符合策略 | 规则 + LLM 判分 | 每次发布 | 中 |
| L3 端到端 | 任务成功率、用户满意度、成本、延迟 | 黄金任务集 + 人工抽检 | 每周/每版本 | 高 |

三层不是替代关系。**L1 挂了，L2/L3 的数字没有意义**；只做 L3，出问题无法定位。

### 2.1 L1：组件级断言（最该先做）

大多数 Agent 的线上事故，根因在 L1：

- 工具参数 schema 改了，模型还在传旧字段；
- 检索 TopK 从 3 调到 10，Prompt 里的上下文超了窗口被截断；
- 工具返回结构变了（`data.items` → `data.list`），模型解析失败；
- 权限校验漏了某个新工具。

这些用普通单测就能覆盖：

```java
class ToolContractTest {

    private final OrderTools tools = new OrderTools(new FakeOrderRepo());

    @Test
    void cancelOrder_shouldRejectShippedOrder() {
        ToolResult r = tools.cancelOrder("O1001");   // O1001 已发货
        assertThat(r.isSuccess()).isFalse();
        assertThat(r.getErrorCode()).isEqualTo("ORDER_ALREADY_SHIPPED");
        // 关键：错误信息要能让模型"读懂并改口"，不是堆栈
        assertThat(r.getMessage()).contains("已发货").doesNotContain("Exception");
    }

    @Test
    void toolSchema_shouldMatchModelVisibleDefinition() throws Exception {
        String json = ToolSchemaExtractor.extract(tools, "cancelOrder");
        // 用 JSON Schema 校验器保证 schema 可被模型正确理解
        assertThat(json).contains("\"order_id\"").doesNotContain("arg0");
    }
}
```

`doesNotContain("arg0")` 这条断言看着奇怪，但它抓过真实 bug：方法参数名被编译丢失后，反射生成的 schema 字段名变成 `arg0`，模型按语义传 `orderId`，永远调不通。

### 2.2 L2：轨迹判分

轨迹是一个结构化事件序列，先把它落成数据：

```java
public record TraceStep(
        int index,
        String type,          // llm / tool / retrieval / final
        String name,
        Map<String, Object> input,
        Object output,
        long latencyMs,
        int promptTokens,
        int completionTokens,
        String error
) {}

public record AgentTrace(
        String taskId,
        String traceId,
        List<TraceStep> steps,
        String finalAnswer,
        boolean success,
        long totalLatencyMs,
        int totalTokens
) {}
```

有了结构化 trace，很多规则可以直接判：

```java
public class TraceRuleChecker {

    public List<Violation> check(AgentTrace trace) {
        List<Violation> out = new ArrayList<>();

        // 1. 步数上限（防死循环）
        if (trace.steps().size() > 15) {
            out.add(new Violation("TOO_MANY_STEPS", trace.steps().size()));
        }

        // 2. 重复调用同一工具 + 同样参数（典型循环）
        Set<String> seen = new HashSet<>();
        for (TraceStep s : trace.steps()) {
            if (!"tool".equals(s.type())) continue;
            String key = s.name() + "|" + canonical(s.input());
            if (!seen.add(key)) {
                out.add(new Violation("DUPLICATE_TOOL_CALL", key));
            }
        }

        // 3. 越权：调用了不在白名单里的工具
        Set<String> allowed = Set.of("search_orders", "get_order_detail",
                                     "cancel_order", "send_email");
        trace.steps().stream()
             .filter(s -> "tool".equals(s.type()) && !allowed.contains(s.name()))
             .forEach(s -> out.add(new Violation("UNAUTHORIZED_TOOL", s.name())));

        // 4. 关键步骤缺失：说要取消却没调 cancel_order
        boolean hasCancel = trace.steps().stream()
                .anyMatch(s -> "cancel_order".equals(s.name()));
        if (trace.taskId().startsWith("cancel_") && !hasCancel) {
            out.add(new Violation("MISSING_REQUIRED_TOOL", "cancel_order"));
        }

        return out;
    }
}
```

规则能覆盖 60%~70% 的明显问题，剩下的"语义合理性"交给 LLM 判分。

### 2.3 L3：端到端

端到端看的是业务结果，通常需要**可判定的环境**：

- 沙箱数据库（任务开始前重置到固定状态）；
- Mock 的外部 API（固定返回，可断言调用）；
- 明确的成功条件（订单状态 = CANCELLED 且邮件表里有 1 条记录）。

没有可判定环境时，就退化为人工/LLM 判分，可靠性下降一个档次。

## 三、主流基准：能测什么，不能测什么

| 基准 | 领域 | 判分方式 | 优点 | 局限 |
|---|---|---|---|---|
| AgentBench | 8 类环境（OS/DB/知识图谱/卡牌游戏等） | 环境状态 | 覆盖面广，可复现 | 任务偏合成，离业务远 |
| τ-bench | 零售/航空客服 | 数据库终态 + 策略约束 | **含"策略遵循"判定**，最接近生产 | 领域窄，需要模拟用户 |
| WebArena | 网页操作 | 页面状态/功能断言 | 真实网站，检验浏览能力 | 环境重、慢、易 flaky |
| SWE-bench | 代码修复 | 单测通过率 | 判分客观、难度高 | 只测编码，不测对话/工具编排 |
| GAIA | 通用助理 | 精确答案 | 人类简单、AI 难，区分度好 | 题目少（466），易过拟合 |
| OSWorld | 桌面操作 | 系统状态 | 多步 GUI 操作 | 环境依赖重 |

选基准的原则：

1. **先看判分方式是否客观**。环境状态 > 单测 > 精确答案 > LLM 判分 > 人工。
2. **再看领域是否贴近业务**。客服类看 τ-bench，编码类看 SWE-bench，通用助理看 GAIA。
3. **别把公开基准当唯一标准**。公开基准会被针对性优化（甚至污染训练集），它只能证明"不弱"，不能证明"能用"。

真正决定上线的是 **你自己的黄金任务集**，通常 100~300 条，覆盖高频场景 + 边界 + 曾经出过 bug 的 case。

## 四、搭一套能进 CI 的评测框架（Java）

### 4.1 目录结构

```
eval/
├── tasks/
│   ├── cancel_order_001.yaml
│   ├── refund_policy_qa_003.yaml
│   └── ...
├── fixtures/            # 每个任务的初始 DB / mock 数据
├── judges/              # 判分器实现
└── reports/             # 每次运行的结果
```

任务定义用 YAML，让产品/运营也能加 case：

```yaml
id: cancel_order_001
category: order
difficulty: easy
input: "帮我查下上周的订单，没发货的取消掉"
setup:
  fixture: orders_week_42.sql
success:
  assertions:
    - type: db
      sql: "SELECT status FROM orders WHERE id='O1002'"
      expect: "CANCELLED"
    - type: db
      sql: "SELECT COUNT(*) FROM email_outbox WHERE user_id=42"
      expect: 1
constraints:
  max_steps: 8
  allowed_tools: [search_orders, get_order_detail, cancel_order, send_email]
  forbidden_tools: [refund_order, delete_order]
```

### 4.2 执行器

```java
@Service
public class EvalRunner {

    private final Agent agent;
    private final FixtureLoader fixtures;
    private final AssertionEngine assertions;
    private final List<TraceRuleChecker> checkers;

    public EvalReport run(EvalTask task, int repeat) {
        List<TaskResult> results = new ArrayList<>();

        for (int i = 0; i < repeat; i++) {
            fixtures.reset(task.setup());                 // 每个 case 从干净状态开始

            long start = System.currentTimeMillis();
            AgentTrace trace;
            try {
                trace = agent.execute(task.input(), task.constraints());
            } catch (Exception e) {
                results.add(TaskResult.error(task.id(), e));
                continue;
            }
            long cost = System.currentTimeMillis() - start;

            List<Violation> violations = checkers.stream()
                    .flatMap(c -> c.check(trace).stream())
                    .toList();

            boolean passed = violations.isEmpty()
                    && assertions.verify(task.success(), trace);

            results.add(new TaskResult(task.id(), passed, cost,
                    trace.totalTokens(), trace.steps().size(), violations));
        }

        return EvalReport.of(task.id(), results);
    }
}
```

**为什么要 `repeat`？** 因为 LLM 有随机性。同一个 case 跑 3 次，通过 2 次，和通过 3 次，稳定性完全不同。建议核心 case `repeat=3`，用"3 次全过"作为硬门槛，"≥2 次"作为观察项。

### 4.3 汇总指标

```java
public record EvalReport(
        String taskId,
        int runs,
        int passed,
        double passRate,
        double passAt3,          // 3 次全过的比例
        long p50LatencyMs,
        long p95LatencyMs,
        double avgSteps,
        double avgTokens,
        double costPerTask,
        Map<String, Integer> violationCounts
) {}
```

一份可读的报告长这样：

| 指标 | 基线（v1.2） | 候选（v1.3） | 变化 |
|---|---|---|---|
| 任务成功率 | 78.4% | 84.1% | +5.7pt ✅ |
| pass@3（稳定性） | 61.0% | 70.3% | +9.3pt ✅ |
| P95 延迟 | 4.2s | 5.8s | +1.6s ⚠️ |
| 平均步数 | 4.1 | 4.9 | +0.8 ⚠️ |
| 单任务成本 | ¥0.021 | ¥0.034 | +62% ❌ |
| 违反约束次数 | 3 | 11 | +8 ❌ |

结论会非常清晰：**效果涨了，但成本和约束违规也涨了**，这时候要问的是"多花的 62% 值不值"，而不是"效果变好了可以上线"。

## 五、LLM-as-Judge：能用，但要校准

### 5.1 什么该让 Judge 判

| 适合 | 不适合 |
|---|---|
| 回答是否切题、是否引用了给定材料 | 事实正确性（Judge 也会幻觉） |
| 语气/格式是否符合要求 | 需要精确计算的结果 |
| 轨迹是否"合理解释了用户意图" | 需要外部状态的判定（用 DB 断言） |
| 两个答案的相对优劣（pairwise） | 绝对分数（校准差） |

### 5.2 三种判分模式

```
pointwise：给单个答案打 1~5 分
  -> 简单，但分数漂移严重，不同批次不可比

pairwise：给 A/B 两个答案选更好的
  -> 最稳，适合 A/B 实验，但 O(n) 次调用

listwise：给多个答案排序
  -> 效率高，但位置偏差明显（偏爱靠前/靠后）
```

生产建议：**A/B 实验用 pairwise，日常回归用 pointwise + 固定 rubric**。

### 5.3 校准三件事

**（1）位置偏差**：把 A/B 顺序对调再问一次，两次结论不一致就判定"不确定"，不计入胜负。

```java
public JudgeVerdict judgePairwise(String question, String a, String b) {
    JudgeVerdict v1 = ask(question, a, b);        // A 在前
    JudgeVerdict v2 = ask(question, b, a);        // B 在前，注意映射回来
    JudgeVerdict normalized = v2.flip();          // B,A -> A,B
    if (v1.winner() != normalized.winner()) {
        return JudgeVerdict.tie("position_bias");
    }
    return v1;
}
```

**（2）与人工对齐**：抽 50~100 条人工标注，算 Judge 与人的一致率（Cohen's kappa）。低于 0.6 就别用这个 Judge，或者重写 rubric。

**（3）固定 Judge 版本**：Judge 模型升级会改变所有历史分数。**把 Judge 的模型名 + 版本写进报告**，否则跨周对比毫无意义。

### 5.4 一个可用的 rubric

```text
你是客服 Agent 的质量评审。给定用户问题、Agent 的最终回答、以及可用的事实材料，
判断回答是否合格。只输出 JSON：{"score": 1-5, "reason": "..."}

评分标准：
5 = 完全回答了问题，且所有事实陈述都能在材料中找到依据
4 = 回答了问题，有轻微冗余但不影响
3 = 部分回答，缺少关键信息，或有一个不准确表述
2 = 明显偏离问题，或包含材料中没有的事实
1 = 答非所问 / 拒答 / 幻觉严重

注意：
- 不要因为回答"更长"就给高分
- 材料里没有的信息，即使你认为正确，也算幻觉
- 如果材料为空，允许回答"暂无相关信息"并给 4 分
```

关键点：**要求输出结构化 JSON**、**明确"材料外即幻觉"**、**显式对抗长度偏好**。

## 六、把评测接进 CI

```yaml
# .github/workflows/agent-eval.yml
name: agent-eval
on:
  pull_request:
    paths: ["src/main/**", "prompts/**", "eval/**"]

jobs:
  eval:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run smoke eval (60 cases)
        run: ./gradlew evalSmoke -Peval.repeat=1
      - name: Compare with baseline
        run: ./gradlew evalCompare -Pbaseline=eval/baseline.json
      - name: Fail on regression
        run: |
          # 成功率下降 > 2pt 或 出现新的约束违规 -> 失败
          ./gradlew evalGate -PmaxDrop=0.02
```

门禁规则建议分层：

| 变更类型 | 跑多少 case | 门槛 |
|---|---|---|
| 改 Prompt 文案 | 全量 | 成功率不降，成本涨幅 < 10% |
| 换模型 | 全量 + 双跑对比 | 成功率 +3pt 以上才允许换 |
| 加工具 | 相关子集 + 全量 | 无新增越权，成功率不降 |
| 改检索参数 | 检索子集 | Recall@5 不降 |
| 纯重构 | smoke 60 条 | 成功率波动 < 2pt |

**注意"评测本身的成本"**：全量 300 case × 3 次 × 每任务 5 次 LLM 调用 = 4500 次调用。按 ¥0.02/次算约 ¥90/次运行。所以要区分 smoke（每次 PR）与 full（每日/发布前）。

## 七、线上也要评：影子与抽检

离线评测集永远覆盖不了真实分布。线上补两个机制：

1. **影子运行**：把新版本在 1% 流量上跑，不返回给用户，只记录轨迹与结果，和线上版本对比。重点看"新版本是否走了不同工具路径"。
2. **自动抽检**：每天随机抽 200 条真实会话，用 Judge 打质量分，低于阈值的人工复核。这能抓到"离线集里没有的新问法"。

线上指标要和离线对齐：

| 线上指标 | 对应离线指标 |
|---|---|
| 任务完成率（用户确认） | 成功率 |
| 平均轮次 | 平均步数 |
| 工具错误率 | L1 断言通过率 |
| P95 首字延迟 | P95 延迟 |
| 单会话 token | 单任务 token |
| 用户"重问"率 | pass@3（稳定性代理指标） |

## 八、五个常见误区

**误区 1：用 GPT-4 当 Judge 就万事大吉**
Judge 有系统性偏差（偏爱长答案、偏爱 Markdown、偏爱自己的风格）。必须校准，且必须固定版本。

**误区 2：只测成功案例**
评测集的价值在"边界与失败"。建议配比：正常 60%、边界 25%、历史 bug 15%。

**误区 3：追求单一总分**
"综合分 87.3"没有行动意义。要看分维度（工具正确率 / 答案质量 / 成本 / 延迟），才知道下一步改哪里。

**误区 4：忽略方差**
同一个 case 跑一次通过就认为"修好了"。LLM 的随机性会让单次结果毫无统计意义，至少 3 次。

**误区 5：评测集写完就不动**
线上出现新问题，必须回填成 case。评测集应该是**活的资产**，每次线上事故都让它变强一点。

## 九、面试常见追问

**Q1：Agent 评测和传统软件测试最大的区别？**
输出不确定 + 路径不唯一。传统测试是"输入→确定输出"的断言；Agent 需要概率化指标（pass@k）、过程检查（轨迹）和语义判分（LLM-as-Judge），并且要接受"没有 100% 通过"。

**Q2：怎么判断一次改动是真的变好还是随机波动？**
固定评测集 + 多次运行 + 看置信区间。简单做法：同一 case 跑 3 次，比较 pass@3 而不是单次通过率；样本量小时用配对比较（同 case 同顺序）而不是总体均值。

**Q3：τ-bench 的"策略遵循"为什么重要？**
因为真实业务里"结果对"不等于"过程合规"。客服给用户退了款（结果对），但违反了"超过 500 元需主管审批"的策略（过程错）。这类问题只有轨迹判分能抓。

**Q4：LLM-as-Judge 的分数能跨版本比较吗？**
只有在 Judge 模型、Prompt、温度、rubric 全部固定时才可以。任何一项变化都要重跑基线，否则历史数据不可比。

**Q5：没有标注数据怎么起步？**
三步：① 从线上日志抽 100 条真实请求；② 人工只标"通过/不通过"（二分类，成本最低）；③ 用规则 + Judge 逼近人工结论，算一致率，一致率够高后再扩大规模。

## 十、总结

1. **Agent 评测必须评过程**，只看最终答案会漏掉越权、冗余、循环、策略违规。
2. **三层结构**：L1 组件断言（最便宜、最该先做）、L2 轨迹判分（规则 + Judge）、L3 端到端（黄金任务集 + 可判定环境）。
3. **公开基准证明"不弱"，自建评测集证明"能用"**，后者才是上线依据。
4. **LLM-as-Judge 要校准**：位置偏差、人工对齐、版本固定，三件事缺一不可。
5. **评测要进 CI**，并且按变更类型分层设置门槛，否则要么拖慢发布，要么形同虚设。

Agent 的迭代速度取决于反馈回路的速度。没有评测，反馈回路就是"用户的抱怨"——那是最慢、最贵、也最伤信任的一种。
