---
title: 【AI 工程化】在线评测与反馈闭环深度解析：从点赞点踩到可持续的质量飞轮
date: 2026-11-28 08:20:00
tags:
  - AI
  - 评测
  - 工程化
  - 反馈闭环
  - LLM-as-Judge
categories:
  - AI 工程
author: 东哥
---

# 【AI 工程化】在线评测与反馈闭环深度解析

## 前言

离线评测集 92 分，上线一周客诉翻倍。这是 LLM 应用最常见的剧情。

复盘的时候发现，离线集和真实流量根本不是同一个分布：

- 离线集是产品经理写的 200 条「典型问题」，真实流量里有 40% 是多轮追问、带错别字、跨主题混合；
- 离线集假设检索总能召回正确文档，真实环境里 18% 的请求召回为空；
- 离线集只评「答案对不对」，不评「用户有没有照做」，而后者才是业务结果；
- 离线集是静态的，知识库每周更新，三周后一半样本已经过期。

离线评测回答的是「模型在已知分布上表现如何」，在线评测回答的是「产品在真实用户手里有没有用」。前者是必要条件，后者才是最终裁判。

这篇讲在线评测的完整体系：**采集什么信号、怎么建模会话级满意度、怎么做 badcase 归因、怎么把 badcase 变成可回归的评测集**，最后给一套 Java 落地骨架。

> 分工说明：站内已有《Agent 评测体系》（离线基准、轨迹判分、LLM-as-Judge 校准、CI 门禁）、《RAG 评测 RAGAS》（离线指标）、《A/B 实验平台架构》（分桶与显著性）。本篇专攻**线上质量信号的采集、归因与回流闭环**，不重复离线基准与实验平台实现。

---

## 一、离线与在线，评的根本不是一件事

| 维度 | 离线评测 | 在线评测 |
|---|---|---|
| 数据 | 人工构造的固定集 | 真实流量（含长尾、脏输入、多轮） |
| 指标 | 准确性、召回、格式合规 | 任务完成率、采纳率、重问率、转人工率 |
| 反馈周期 | 小时级（跑一次） | 分钟到天级（看指标） |
| 偏差 | 构造者偏差、过拟合风险 | 幸存者偏差、UI 影响、噪声大 |
| 作用 | 上线门禁、版本对比 | 发现真实失效模式、驱动迭代 |

关键认知：**离线指标是「代理指标」，在线指标也是「代理指标」**，只有业务结果（工单是否关闭、订单是否成交、退款是否下降）是真相。三级指标体系必须同时存在，否则一定会出现「指标都很好，业务在骂人」。

---

## 二、在线信号的四层

### L1 隐式行为（覆盖率最高，噪声最大）

| 信号 | 含义 | 陷阱 |
|---|---|---|
| 采纳率（复制/点击「采用」） | 答案有用 | 受 UI 位置影响，移动端复制率天然低 |
| 重生成率 | 答案不满意 | 用户可能只是想看别的说法 |
| 重问率（同 session 相似 query） | 没解决 | 多轮细化也可能是正常对话 |
| 编辑距离 | 答案接近但需修正 | 只对有编辑功能的场景有效 |
| 会话终止（abandon） | 放弃 | 也可能是问题解决了就走了 |
| 停留时长 | 阅读深度 | 长 ≠ 好，可能是看不懂 |

### L2 显式反馈（覆盖低，信噪比高）

点赞/点踩 + **原因标签**（不准确 / 不完整 / 过时 / 答非所问 / 有风险）。原因标签比拇指本身价值高一个数量级 —— 它直接指向归因层。

### L3 业务结果（最终真相，周期最长）

工单是否一次关闭、客服是否转人工、下单转化、退款率、投诉率。这类信号要按「同批次用户」对比，不能看绝对值。

### L4 自动判分（覆盖可调，成本可控）

用 LLM-as-Judge 对**抽样**的真实请求打分（正确性、完整性、引用一致性、安全性）。它填补了 L1/L2 的空白，但必须做校准（与人工标注的一致率 ≥ 80% 才可信）。

四层的组合策略：

```
全量     L1 隐式行为（埋点便宜）
1%~5%    L4 自动判分（抽样，按意图分层）
有反馈   L2 显式反馈（自然采样，不干预）
周/月    L3 业务结果（离线数仓关联）
```

---

## 三、会话级满意度建模

单轮信号不可直接用：一次 5 轮的会话，前 4 轮都点踩、最后解决了，会话级体验其实是正的；反过来，一次 1 轮就结束、但用户没再来的会话，可能是失望离开。

### 一个可落地的打分模型

```
sessionScore = Σ (w_i · signal_i · decay(turn_i)) / Σ w_i
```

- `signal_i`：该轮的归一化信号（采纳 +1、点踩 -1、重生成 -0.5、重问 -0.5）
- `decay(turn_i)`：时间衰减，越靠后的轮次权重越高（用户最终是否满意更重要）
- 缺失信号按 0 处理，**不要用均值填充**（会制造虚假中性）

更稳的做法是**弱标签 + 分类器**：用「是否转人工 / 是否 24h 内重复提问 / 是否有负向反馈」构造标签，训练一个轻量模型（LR/GBDT）输出会话满意度概率。特征包括轮次数、平均时延、重问次数、检索命中数、工具失败数、答案长度。

### 守护指标与实验指标要分开

| 类型 | 例子 | 阈值行为 |
|---|---|---|
| 守护指标（guardrail） | 安全违规率、P99 延迟、成本/会话、空召回率 | 越线**立即回滚**，不等显著性 |
| 实验指标 | 任务完成率、采纳率、满意度 | 需要统计显著才决策 |

混淆这两类是常见事故来源：有人用「满意度还没显著下降」为理由，放过了安全违规率翻倍。

---

## 四、badcase 归因：从「不好」到「哪一层不好」

这一步是闭环的核心。没有归因，badcase 只会变成一堆「答得不好」的截图。

### 五层归因模型

| 层 | 判定信号 | 典型修复 |
|---|---|---|
| 检索层 | gold 文档不在 context 里；空召回；top-k 全是同源 | 分块、embedding、混合检索、query 改写 |
| 上下文层 | gold 在 context 里但被截断/排在末尾 | 上下文压缩、重排、Lost in the Middle 治理 |
| 生成层 | 有证据但答案错/编造/格式坏 | Prompt、结构化输出、few-shot、换模型 |
| 工具层 | 工具报错、参数错、超时、结果被截断 | schema 收紧、超时与重试、结果摘要 |
| 系统层 | 限流降级、网关超时、模型 5xx | 容量、熔断、降级策略 |

### 自动归因的实现思路

关键在于一个判据：**「正确证据是否在上下文里」**。

```java
public enum FailureLayer { RETRIEVAL, CONTEXT, GENERATION, TOOL, SYSTEM }

public FailureLayer attribute(Trace trace, JudgeResult judge) {
    if (trace.hasSystemError()) return FailureLayer.SYSTEM;
    if (trace.toolCalls().stream().anyMatch(ToolCall::failed)) return FailureLayer.TOOL;

    boolean goldInContext = trace.retrievedChunks().stream()
            .anyMatch(c -> goldMatcher.matches(c, judge.goldDocIds()));

    if (!goldInContext) return FailureLayer.RETRIEVAL;

    boolean goldTruncated = trace.contextStats().truncatedChunkIds()
            .stream().anyMatch(judge.goldDocIds()::contains);
    if (goldTruncated || trace.contextStats().goldPositionRatio() > 0.7) {
        return FailureLayer.CONTEXT;      // 有证据但被裁掉或埋在末尾
    }

    return judge.answerCorrect() ? null : FailureLayer.GENERATION;
}
```

这个判据的价值：**它把「模型不行」和「检索不行」分开了**。实践中，很多团队一口咬定「模型太笨」，归因之后发现 60% 的失败是检索层 —— 换更大的模型只会让成本翻倍，问题依旧。

`goldMatcher` 可以用三种方式：标注的 gold chunkId（最准，样本少）、embedding 相似度（自动，需校准阈值）、judge 直接判断「context 是否包含回答问题所需信息」（成本低，推荐）。

---

## 五、数据飞轮：让 badcase 变成资产

```
线上流量 ──> 采样 ──> 归因 ──> 标注 ──> 评测集(v+1) ──> 回归门禁 ──> 发布
   ↑                                                                    │
   └──────────────────── 灰度放量 <── 通过 ◄────────────────────────────┘
```

### 采样策略

不要随机采样，要**分层 + 主动**：

| 策略 | 规则 |
|---|---|
| 失败信号优先 | 点踩、重生成、转人工、judge 低分的样本 100% 入池 |
| 意图分层 | 按意图分布配额，避免长尾意图被高频意图淹没 |
| 分歧采样 | judge 与规则引擎结论不一致的样本优先 |
| 低置信采样 | 检索分低、答案短、引用数 0 的样本 |
| 随机对照 | 保留 5% 纯随机，用于估计整体分布 |

### 标注

三件必需品：标注手册（含正例/反例/边界例）、双人标注 + 一致性检验（Cohen's κ ≥ 0.7）、仲裁机制。**没有手册的标注等于制造噪声**，同一个「不准确」三个人能标出三种含义。

### 回流到评测集

四条规则：

1. **版本化**：评测集本身有版本号，每次新增记 changelog。
2. **去重**：新样本先与已有集合做语义去重（余弦 > 0.95 视为重复），否则集合会膨胀到跑不动。
3. **分层配额**：每个意图/失败层保持最低样本数，避免某一类被稀释。
4. **过期淘汰**：知识库变更后，标注「过时」的样本要下线或重标，否则会持续误报。

### 三个反模式

- **只加不删**：评测集从 200 涨到 5000，跑一次 40 分钟，最后没人跑。
- **拿线上样本训练**：把评测集里的样本用于 few-shot 或微调，等于考试泄题，指标虚高。
- **用同一批样本既调 Prompt 又做门禁**：调完必然通过，门禁失去意义。**调参集与门禁集必须物理隔离**。

---

## 六、在线 A/B：LLM 场景的特殊性

普通 A/B 的假设在这里会失效：

| 问题 | LLM 场景的表现 | 应对 |
|---|---|---|
| 方差大 | 同一输入输出不同，指标天然抖动 | 提高样本量、用会话级聚合而非单轮 |
| 成本方差大 | 长回答成本是短回答的 10 倍 | 成本作为协变量或分层 |
| 延迟长尾 | P99 受模型队列影响，与版本无关 | 用分位数 + 同期对照，不看均值 |
| 学习效应 | 用户会适应新 UI/新语气 | 洗牌期单独分析 |
| 溢出效应 | 同一用户被分到两组 | 按 userId 做确定性分桶 |

指标上建议：主指标用「任务完成率」（judge + 业务结果联合判定），护栏用「安全违规率 / P99 延迟 / 单会话成本」，显著性用序贯检验（避免固定样本量导致提前偷看偏差）。

---

## 七、Java 落地骨架

### 事件模型

一条事件要能支撑「归因 + 复现 + 回归」，所以字段必须自包含：

```java
public record InteractionEvent(
        String eventId,          // 幂等键
        String traceId,
        String sessionId,
        int turnIndex,
        String tenantId,
        String userId,
        String intent,           // 分类器输出
        String query,
        String answer,
        List<String> retrievedChunkIds,
        List<Integer> contextOrder,
        String model,
        String promptVersion,
        int promptTokens,
        int completionTokens,
        long ttfbMs,
        long totalMs,
        String toolErrors,       // JSON
        String feedback,         // THUMB_UP / THUMB_DOWN / null
        String feedbackReason,
        long occurredAt
) {}
```

### 异步上报（不阻塞主链路）

```java
@Component
public class FeedbackCollector {

    private final KafkaTemplate<String, String> kafka;
    private final ObjectMapper mapper;
    private final Sampler sampler;

    @EventListener
    public void onInteraction(InteractionCompleted e) {
        if (!sampler.shouldSample(e.intent())) return;   // 分层采样
        try {
            kafka.send("llm.interactions", e.sessionId(),
                    mapper.writeValueAsString(e.toEvent()));
        } catch (Exception ex) {
            // 埋点失败绝不影响业务
            log.warn("feedback enqueue failed traceId={}", e.traceId(), ex);
        }
    }
}
```

三个原则：**不阻塞**（异步 + 超时）、**不失败**（埋点异常吞掉并打日志）、**可去重**（`eventId` 幂等，Kafka 至少一次投递 + 消费端按 eventId 去重）。

### 判分 worker 的幂等与配额

```java
@Component
public class JudgeWorker {

    public void judge(String eventId) {
        // 1) 幂等：Redis SETNX，24h 过期
        Boolean first = redis.opsForValue()
                .setIfAbsent("judge:" + eventId, "1", Duration.ofHours(24));
        if (!Boolean.TRUE.equals(first)) return;

        // 2) 分级：规则先过，能判定的不进模型
        RuleVerdict rule = ruleEngine.check(event);
        if (rule.isDecisive()) { save(eventId, rule.toScore()); return; }

        // 3) 预算：按租户分配 judge 配额，超限降级为抽样跳过
        if (!budget.tryAcquire(event.tenantId())) { metrics.increment("judge.skipped"); return; }

        JudgeResult r = judgeClient.evaluate(event);   // 带超时与重试
        save(eventId, r);
    }
}
```

### 指标聚合

- 实时：Flink / Kafka Streams 算 1min/5min 窗口的采纳率、重问率、空召回率（守护指标必须实时）。
- 离线：数仓按天算会话满意度、归因分布、成本/会话。
- 对齐：实时与离线口径必须一致，**同一指标两个数**是最消耗信任的事故。

---

## 八、成本与隐私

**成本**：judge 是主要开销。四个手段：抽样率按意图分层（高风险意图全量、闲聊 1%）、级联（规则 → 小模型 → 大模型）、结果缓存（相同 query+answer 指纹）、答案截断（judge 不需要全文）。

**隐私**：用户内容进评测系统前必须脱敏（手机号、身份证、地址、订单号），按租户隔离存储，设定留存期（如 90 天），评测集对外分享时二次脱敏。**评测数据往往比生产库更容易泄露**，因为它被复制到了分析环境。

---

## 九、90 天落地路线

| 阶段 | 目标 | 交付 |
|---|---|---|
| 第 1–2 周 | 埋点与事件模型 | `InteractionEvent` 全链路打通，能按 traceId 还原一次请求 |
| 第 3–4 周 | 基础指标 | 采纳率、重问率、空召回率、P99 延迟、成本/会话看板 |
| 第 5–6 周 | 归因 | 五层归因 + 每周 badcase 复盘会 |
| 第 7–8 周 | 判分 | judge 上线，与人工标注对齐 ≥80% |
| 第 9–10 周 | 回流 | badcase → 评测集 v1 增量，纳入 CI 门禁 |
| 第 11–12 周 | 闭环 | 灰度 + 护栏自动回滚，周迭代节奏稳定 |

---

## 十、面试追问

**Q1：离线评测 90 分，上线为什么还是被骂？**
分布不一致（长尾、多轮、脏输入）、链路不一致（离线假设检索成功）、目标不一致（离线评答案，业务评任务完成）。离线集只能证明「在这批样本上可以」，不能证明「在真实分布上可以」。

**Q2：点赞率能当质量指标吗？**
只能当辅助。它受 UI 显著影响、覆盖率低（通常 <2%）、且存在沉默大多数偏差。必须与隐式行为、judge 判分、业务结果交叉验证。

**Q3：怎么判断是模型问题还是检索问题？**
看正确证据是否在 context 里。不在 → 检索层；在但被截断/排太后 → 上下文层；在且位置正常但答案错 → 生成层。

**Q4：badcase 直接拿来当评测样本有什么问题？**
会过拟合：模型/Prompt 针对这些样本调优后指标虚高，但分布外表现不变。必须保留独立的门禁集，并持续补充新分布样本。

**Q5：在线 A/B 样本量要多大？**
取决于基线指标方差与最小可检测效应。LLM 场景方差大，通常需要比传统 A/B 多 3–5 倍样本；建议用序贯检验 + 会话级聚合降低方差。

---

## 小结

- 离线评测是门禁，在线评测是裁判，业务结果是真相，三者缺一不可；
- 信号分四层：隐式行为（覆盖高）、显式反馈（信噪比高）、业务结果（真相）、自动判分（可调覆盖）；
- 会话级满意度要做衰减加权，守护指标与实验指标必须分开；
- 归因的核心判据是「正确证据是否在上下文中」，它把「模型不行」和「检索不行」分开；
- 数据飞轮的关键不是采集量，而是**采样策略、标注质量、评测集版本化与防泄漏**；
- 没有自动回滚的灰度不是灰度，没有归因的 badcase 不是资产。

在线评测体系建好之后，团队讨论问题的方式会变：从「我觉得这个回答不好」，变成「这一类意图的检索层失败率从 12% 涨到 19%，因为上周加了分块重叠参数」。这才是工程化的开始。
