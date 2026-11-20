---
title: 【AI Agent】Agent 失败分类与重试预算深度解析：可重试性矩阵、预算代数与降级链
date: 2026-11-20 08:40:00
tags:
  - AI
  - Agent
  - 工程化
  - 可靠性
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】Agent 失败分类与重试预算深度解析

## 前言

给 Agent 加"重试"几乎是所有人的第一反应。但 Agent 的重试和 HTTP 的重试完全不是一回事：

- HTTP 重试是 **幂等的、廉价的、成功率单调上升**的；
- Agent 重试是 **有状态的、昂贵的、可能越试越错**的。

一个典型事故：工具超时 → 重试 → 工具其实执行成功了 → 重复退款；或者模型输出 JSON 不合法 → 原样重试 3 次 → 三次都错（因为温度低、prompt 没变，失败是确定性的）→ 白烧 3 倍 token，最后还是失败。

这篇文章做两件事：把 Agent 的失败**分类到可操作**，把重试**预算化到可计算**。

## 一、失败分类：先分清"谁的错"

不分类型的重试，等于把所有病都当感冒治。Agent 的失败至少有八类，处置手段完全不同：

| # | 类型 | 典型症状 | 谁来修 | 可重试 |
|---|---|---|---|---|
| 1 | 输出格式错 | JSON 不合法、缺必填字段 | 模型 | ✅ 带修复提示 |
| 2 | 参数语义错 | 工具 400、字段类型对但值非法 | 模型 | ✅ 回灌错误信息 |
| 3 | 工具瞬时故障 | 5xx、连接超时、连接池耗尽 | 基础设施 | ✅ 退避重试 |
| 4 | 工具限流 | 429、配额超限 | 平台 | ✅ 按 Retry-After |
| 5 | 工具永久错 | 404、无权限、资源不存在 | 人/配置 | ❌ 重试无意义 |
| 6 | 上下文超限 | 400 context_length_exceeded | 编排 | ❌ 要压缩，不是重试 |
| 7 | 检索空/低相关 | 召回 0 条、分数全低 | 数据/检索 | ⚠️ 改写查询后可重试 |
| 8 | 语义失败 | 接口 200，但答案错了/任务没完成 | 模型+验证器 | ⚠️ 需 replan，不是 retry |

第 7、8 类是最容易被忽略的——**没有异常抛出的失败**。监控上一切正常（成功率 100%），但用户满意度在跌。这类必须靠**验证器（verifier）**主动判定，而不是等报错。

### 1.1 语义失败怎么判定

三种低成本验证器，按可靠性排序：

1. **硬规则校验**：金额是否等于订单金额、日期是否在区间内、ID 是否存在。一票否决，最可靠。
2. **结构校验**：输出必须能映射到预定义 schema，且字段间满足约束（比如 `total = sum(items)`）。
3. **模型校验**：用另一个（便宜的）模型判断"这个回答是否解决了用户问题"。有噪声，只用于打分排序，不做硬门禁。

```java
public interface Verifier {
    Verdict verify(AgentResult result, TaskSpec spec);
}

public record Verdict(boolean pass, String reason, Severity severity) {}

// 组合：硬规则一票否决，模型评分只做参考
public Verdict verifyAll(AgentResult r, TaskSpec spec) {
    for (Verifier hard : hardRules) {
        Verdict v = hard.verify(r, spec);
        if (!v.pass()) return v;              // 直接失败
    }
    double score = judge.score(r, spec);      // 0~1
    return new Verdict(score >= 0.7, "judge=" + score, Severity.SOFT);
}
```

## 二、可重试性矩阵：写进代码，而不是写在文档里

"这个能重试吗"必须是**代码里的判定**，不能靠工程师记忆。尤其危险的是非幂等写操作。

```java
public enum Retryability {
    SAFE,          // 纯读，随便重试
    IDEMPOTENT,    // 有幂等键，可重试
    CONDITIONAL,   // 需检查状态后才能重试
    NEVER          // 绝不自动重试
}
```

工具清单示例：

| 工具 | 读/写 | 幂等键 | 策略 |
|---|---|---|---|
| `search_docs` | 读 | — | SAFE，重试 3 次 |
| `get_order` | 读 | — | SAFE |
| `create_ticket` | 写 | `requestId` | IDEMPOTENT |
| `refund` | 写 | `refundNo`（业务生成） | IDEMPOTENT，但**必须**先查状态 |
| `send_email` | 写 | 无 | CONDITIONAL（查发件箱） |
| `delete_account` | 写 | — | NEVER（人工） |

**幂等键的生成位置很关键**：必须在**第一次调用前**生成并持久化，重试时复用。如果在重试时重新生成，服务端看到的是两个不同的请求，幂等完全失效。

```java
// 正确：幂等键在任务开始时就固化
String refundNo = task.id() + ":" + step.index();   // 确定性派生，天然可复用
ToolCall call = ToolCall.of("refund", args, refundNo);
```

## 三、预算代数：为什么"重试 3 次"是个危险配置

### 3.1 成本放大

设单次尝试成本 `C`（token + 工具 + 延迟），失败概率 `p`，最多尝试 `n` 次。期望尝试次数：

```text
E[attempts] = 1 + p + p² + ... + p^(n-1) = (1 - p^n) / (1 - p)
```

| p | n=2 | n=3 | n=5 | n=∞ |
|---|---|---|---|---|
| 0.1 | 1.10 | 1.11 | 1.11 | 1.11 |
| 0.3 | 1.30 | 1.39 | 1.43 | 1.43 |
| 0.5 | 1.50 | 1.75 | 1.94 | 2.00 |
| 0.8 | 1.80 | 2.44 | 3.36 | 5.00 |

看起来还好？真正的杀伤在**成功率的错觉**上。`p=0.3` 时重试 3 次成功率是 `1-0.3³=97.3%`，账面上很漂亮。但这个公式假设**每次失败独立**。

LLM 的失败恰恰是**强相关**的：同样的 prompt、同样的温度、同样的工具返回值，第二次大概率还是错。真实模型更像 `p_2 ≈ p_1`，此时重试 3 次成功率还是 30%，成本却是 3 倍。

**结论：Agent 的重试必须"改变输入"，否则就是纯粹的浪费。**

### 3.2 三种"改变输入"的重试

| 策略 | 做法 | 适用 |
|---|---|---|
| 修复式重试 | 把校验错误回灌给模型："字段 `amount` 必须是数字，你给了 `¥100`" | 格式错、参数错 |
| 升级式重试 | 换更强的模型 / 更多推理预算 | 语义失败、复杂规划 |
| 改写式重试 | 改写查询、换检索策略、换工具 | 检索空、工具不适用 |

```java
public AgentResult retryWithRepair(TaskSpec spec, Attempt failed) {
    String repairPrompt = """
            上一次输出未通过校验，原因：%s
            请只修正该问题，其余内容保持不变，重新输出完整结果。
            """.formatted(failed.verdict().reason());

    return llm.call(spec.withExtraSystem(repairPrompt)
                        .withTemperature(0.0));   // 修复阶段用确定性输出
}
```

## 四、预算：从"次数"升级到"资源"

只限次数是不够的。一个 Agent 循环可能"每次尝试都合法"，但总消耗失控。要按**四个维度**设预算：

```java
public record Budget(
        int maxSteps,           // 循环步数
        long maxTokens,         // 总 token
        long maxToolCalls,      // 工具调用次数
        Duration maxWallClock,  // 墙钟时间
        BigDecimal maxCost      // 金额（按模型单价折算）
) {}
```

```java
public final class BudgetGuard {
    private final Budget budget;
    private int steps, toolCalls;
    private long tokens;
    private BigDecimal cost = BigDecimal.ZERO;
    private final long deadlineNanos;

    public BudgetGuard(Budget b) {
        this.budget = b;
        this.deadlineNanos = System.nanoTime() + b.maxWallClock().toNanos();
    }

    /** 每步开始前调用；返回 false 表示必须停止 */
    public boolean tryAcquire(int estimatedTokens) {
        if (steps >= budget.maxSteps()) return false;
        if (tokens + estimatedTokens > budget.maxTokens()) return false;
        if (cost.compareTo(budget.maxCost()) >= 0) return false;
        if (System.nanoTime() > deadlineNanos) return false;
        steps++;
        tokens += estimatedTokens;
        return true;
    }

    public void recordToolCall(BigDecimal unitCost) {
        toolCalls++;
        cost = cost.add(unitCost);
        if (toolCalls > budget.maxToolCalls()) {
            throw new BudgetExhaustedException("tool calls");
        }
    }
}
```

**预算耗尽的处置**比预算本身更重要。不要直接抛 500，而是走降级链：

```text
预算耗尽
  → 用当前已有信息生成"部分结果 + 明确说明缺什么"
  → 或者升级为异步任务（告诉用户"稍后通知"）
  → 或者转人工
```

对用户来说，"我查到了 80%，剩下 20% 因为额度限制没查"远好于"系统错误"。

## 五、重试预算（Retry Budget）：防止重试风暴

这是 gRPC 体系里的成熟概念，Agent 场景同样适用：**限制"重试次数 / 总请求数"的比例**，而不是只限单请求次数。

原因：下游故障时，每个请求都重试 3 次，等于把流量放大 3 倍打到已经挂掉的服务上，雪崩。

```java
public final class RetryBudget {
    private final double ratio;             // 例如 0.1 = 10%
    private double tokens;
    private final double maxTokens;

    public RetryBudget(double ratio, int windowSize) {
        this.ratio = ratio;
        this.maxTokens = windowSize * ratio;
        this.tokens = maxTokens;
    }

    /** 每个正常请求归还一个 token，形成"成功越多、可重试越多"的正循环 */
    public synchronized void onSuccess() {
        tokens = Math.min(maxTokens, tokens + 1);
    }

    /** 重试消耗一个 token；没有就不许重试 */
    public synchronized boolean tryRetry() {
        if (tokens < 1) return false;
        tokens -= 1;
        return true;
    }
}
```

效果：下游整体健康时，重试预算充足；一旦失败率飙升，预算迅速耗尽，**重试被自动抑制**，保护下游。这正是我们要的——重试是"锦上添花"，不是"雪中送炭"。

## 六、熔断与降级链

### 6.1 按工具熔断

不要按"整个 Agent"熔断，粒度太粗。按工具熔断，因为工具是独立的故障域：

```java
CircuitBreaker refundCb = CircuitBreaker.of("tool.refund",
        CircuitBreakerConfig.custom()
                .slidingWindowSize(20)
                .failureRateThreshold(50)
                .waitDurationInOpenState(Duration.ofSeconds(30))
                .permittedNumberOfCallsInHalfOpenState(3)
                .build());
```

半开状态只放 3 个探测请求——这个数字要小，否则恢复瞬间又是一波压力。

### 6.2 四级降级链

```text
L1 同模型修复式重试（成本 +30%）
L2 换备用模型 / 备用 region（成本 +0~50%，延迟可能变差）
L3 缩小任务范围：只做能确定的部分，其余明确告知
L4 转人工 / 转异步（成本最高，但用户体验可接受）
```

每一级都要有**明确的进入条件**和**退出条件**，而不是"出错了就往下掉"。比如 L2 的进入条件是"主模型连续 3 次 5xx 或 P99 超阈值"，而不是"任意一次失败"。

## 七、观测：五个必须有的指标

| 指标 | 定义 | 用途 |
|---|---|---|
| `agent.success.rate{class}` | 按失败类型分组的最终成功率 | 定位主要矛盾 |
| `agent.attempts.per.task` | 每任务尝试次数分布（p50/p95） | 发现"隐性重试" |
| `agent.budget.exhausted.rate` | 预算耗尽比例 | 预算是否设得太紧 |
| `agent.cost.per.success` | 总成本 / 成功任务数 | **唯一真实的成本指标** |
| `agent.retry.budget.rejected` | 被预算拒绝的重试次数 | 下游是否在恶化 |

`agent.cost.per.success` 特别值得强调：很多人只看"每千 token 单价"，但重试率上升会让真实成本翻倍。这个指标把"重试浪费"直接暴露在账单视角下。

## 八、面试追问

**Q1：LLM 调用超时了，能直接重试吗？**

取决于这次调用有没有副作用。纯生成（无工具）可以重试，但要注意**计费**——第一次超时的那次可能已经产生了 token 费用。带工具调用的话，必须看工具的可重试性：读操作可以，写操作必须靠幂等键。最危险的是"工具执行成功但响应超时"，此时盲目重试会造成重复副作用。

**Q2：为什么说"重试 3 次"在 Agent 里是不可靠的经验值？**

因为 Agent 失败强相关。HTTP 的失败多来自瞬时网络抖动，独立同分布，重试有效；LLM 的格式错误往往源于 prompt 或 schema 设计，同样输入大概率同样输出。不做"改变输入"的重试，只是把同样的错误付三遍钱。

**Q3：预算和超时有什么区别？为什么两个都要？**

超时是**单次调用的上界**，预算是**整个任务的资源上界**。只有超时，Agent 可以无限步地"每步都不超时"地烧钱；只有预算，单次调用可能卡住 10 分钟。两者是不同维度的护栏，缺一不可。

**Q4：重试预算会不会导致"该重试的没重试"？**

会，这是有意的取舍。重试预算的设计前提是"保护下游优先于单请求成功"。如果业务上某些请求必须成功（比如支付确认），那它不应该走"自动重试"，而应该走"幂等 + 补偿任务 + 人工兜底"这条更可靠的链路。用对的机制解决对的问题。

## 总结

- 失败必须先分类：八类失败对应完全不同的处置，格式错要修复、限流要退避、永久错要放弃、语义失败要 replan。
- 可重试性写进代码（`SAFE/IDEMPOTENT/CONDITIONAL/NEVER`），幂等键在**首次调用前**固化。
- 重试必须改变输入，否则成功率不会提升，成本却按 `(1-p^n)/(1-p)` 放大。
- 预算要四维：步数、token、工具调用、墙钟 + 金额；耗尽后走降级链而不是抛错。
- 用 **Retry Budget**（重试/请求比例）防重试风暴，用按工具熔断隔离故障域。
- 盯 `agent.cost.per.success`——它比任何单价指标都诚实。
