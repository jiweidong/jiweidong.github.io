---
title: 【Java AI】模型级联与蒸馏降本深度实战：置信度路由、验证器与 Spring AI 落地
date: 2026-11-16 08:30:00
tags:
  - Java
  - AI
  - Spring AI
  - 成本优化
  - 模型级联
  - 蒸馏
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】模型级联与蒸馏降本深度实战

## 一、前言

大模型应用上线三个月，账单往往比预期高一个数量级。原因通常不是单价，而是**所有请求都走了最贵的模型**：分类、抽取、改写、闲聊、复杂推理，全部打给旗舰模型。

真正的降本不是「换个便宜的模型」，而是让**每个请求走它配得上的模型**。这需要三件事：

1. **级联（Cascade）**：小模型先答，答不好再升级；
2. **验证器（Verifier）**：判断「答得好不好」，而不是靠感觉；
3. **蒸馏（Distillation）**：把旗舰模型的能力固化到小模型，减少升级比例。

本文用 Java + Spring AI 实现一套可落地的级联与蒸馏体系，给出成本公式、验证器设计、数据飞轮与踩坑清单。

<!-- more -->

## 二、成本结构：先算清账

### 2.1 单次请求成本

```
cost = input_tokens × price_in + output_tokens × price_out
```

以某旗舰模型与轻量模型为例（数字仅作量级示意）：

| 模型档位 | 输入价（/1M） | 输出价（/1M） | 相对成本 | 典型延迟 |
|---|---|---|---|---|
| 旗舰 | $3.00 | $15.00 | 1.0 | 2~8s |
| 中档 | $0.50 | $1.50 | 0.13 | 0.8~2s |
| 轻量 | $0.05 | $0.15 | 0.015 | 0.2~0.6s |

如果业务中 80% 是简单任务，全部走旗舰，成本是「20% 复杂 × 旗舰 + 80% 简单 × 轻量」的 **6~8 倍**。

### 2.2 级联的期望成本

设小模型单次成本 `Cs`，大模型 `Cb`，升级率 `p`：

```
E[cost] = Cs + p × Cb
```

对比全走大模型 `Cb`，只要 `p < 1 - Cs/Cb`，级联就更便宜。

用上面的数字：`Cs/Cb ≈ 0.015`，只要升级率低于 98.5% 就划算 —— 门槛极低。但**成本不是唯一约束，质量才是**：

```
max E[cost]
s.t. quality(cascade) ≥ quality(big) - ε
```

### 2.3 三个必须一起看的指标

| 指标 | 定义 | 目标 |
|---|---|---|
| 升级率 `p` | 升级到大模型的请求占比 | 越低越好，但要满足质量 |
| 单位成功成本 | 总成本 / 成功解决的任务数 | 主优化目标 |
| 质量损失 | 与全旗舰方案的评测分差 | ≤ 业务容忍度 |

只看「成本降了 70%」没有意义，如果成功率也降了 20%，单位成功成本可能反而更高。

## 三、级联架构

### 3.1 四种路由策略

| 策略 | 依据 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| 静态路由 | 任务类型/租户 | 简单、可预测 | 粒度粗 | 任务边界清晰 |
| 前置分类器 | 小模型/Embedding 判断难度 | 可离线训练、快 | 需要标注数据 | 流量大、模式稳定 |
| 级联 + 验证 | 小模型先答，验证器打分 | 质量有保障 | 多一次调用 | 质量敏感 |
| LLM-as-Router | 大模型判断难度 | 灵活 | 本身要花钱、延迟高 | 低频复杂任务 |

生产上通常是**静态路由打底 + 级联兜底**：先按任务类型分流，剩下的模糊地带走级联。

### 3.2 级联时序

```
请求
 ├─ 前置检查（缓存 / 规则 / 敏感词）
 ├─ 小模型生成
 ├─ 验证器（结构 / 事实 / 一致性 / 置信度）
 │    ├─ 通过 → 返回
 │    └─ 不通过 → 升级大模型（带小模型结果作为提示）
 └─ 后置校验（长度 / 安全 / 引用）
```

关键设计：**升级时要把小模型的输出一起传给大模型**，让它「修正」而不是「重写」。实测能减少 20~30% 的输出 token。

### 3.3 流式场景的特殊约束

流式输出一旦开始推给用户，就**无法回收**。所以：

- 高风险任务（合同、医疗、金融）不要用「流式 + 后验证」，改成「非流式生成 → 验证 → 一次性/分段推送」；
- 低风险任务（闲聊、摘要）可以流式，验证器只做事后审计与告警；
- 折中方案：先推「思考中」占位，验证通过后再开流。

## 四、验证器：级联的核心

### 4.1 五类信号

| 信号 | 实现 | 能发现的问题 | 成本 |
|---|---|---|---|
| 结构校验 | JSON Schema / Bean Validation | 格式错、字段缺失 | 极低 |
| 业务规则 | 枚举、范围、跨字段约束 | 非法值、逻辑矛盾 | 极低 |
| 引用校验 | 答案中的引用是否在检索结果里 | 幻觉引用 | 低 |
| 自一致性 | 采样 3 次，答案是否一致 | 不确定、易错 | 中（3 倍 token） |
| 模型打分 | 小模型/奖励模型给分 | 语义质量 | 中 |

### 4.2 组合策略

不要用单一信号。推荐「**硬规则一票否决 + 软信号加权**」：

```java
public record Verdict(boolean pass, double score, String reason) {}

public class CompositeVerifier {

    private final List<HardCheck> hardChecks;      // 任一失败即拒绝
    private final List<SoftScorer> softScorers;    // 加权打分
    private final double threshold;

    public Verdict verify(LlmAnswer answer, VerifyContext ctx) {
        for (HardCheck check : hardChecks) {
            Optional<String> failure = check.check(answer, ctx);
            if (failure.isPresent()) {
                return new Verdict(false, 0, failure.get());
            }
        }
        double score = softScorers.stream()
                .mapToDouble(s -> s.score(answer, ctx) * s.weight())
                .sum();
        return new Verdict(score >= threshold, score, "weighted=" + score);
    }
}
```

硬检查示例：

```java
// JSON 结构 + 业务枚举
HardCheck schemaCheck = (answer, ctx) -> {
    try {
        RiskReport report = objectMapper.readValue(answer.text(), RiskReport.class);
        if (!Set.of("LOW", "MEDIUM", "HIGH").contains(report.level())) {
            return Optional.of("非法风险等级: " + report.level());
        }
        return Optional.empty();
    } catch (JsonProcessingException e) {
        return Optional.of("JSON 解析失败: " + e.getOriginalMessage());
    }
};

// 引用必须来自检索片段
HardCheck citationCheck = (answer, ctx) -> {
    Set<String> allowed = ctx.retrievedDocIds();
    for (String cited : answer.citations()) {
        if (!allowed.contains(cited)) {
            return Optional.of("引用了不存在的文档: " + cited);
        }
    }
    return Optional.empty();
};
```

### 4.3 阈值怎么定

用**代价矩阵**，不要拍脑袋：

| 实际情况 \ 决策 | 通过 | 升级 |
|---|---|---|
| 小模型答案正确 | 0（最优） | 多花 `Cb`（浪费） |
| 小模型答案错误 | 业务损失 `L` | 多花 `Cb`（值得） |

期望损失：

```
E[pass] = (1 - accuracy) × L
E[escalate] = Cb
→ 当 (1 - accuracy) × L > Cb 时，应该升级
```

如果一次错误答案的业务损失是 $1，升级成本是 $0.01，那么只要小模型准确率低于 99%，就应该升级 —— 这解释了为什么金融场景几乎全走大模型。反过来，闲聊场景 `L ≈ 0`，阈值可以放得很低。

## 五、Spring AI 实现

### 5.1 双模型客户端

```java
@Configuration
public class CascadeConfig {

    @Bean("smallChat")
    ChatClient smallChat(ChatModel model) {
        return ChatClient.builder(model)
                .defaultSystem("你是高效助手，回答简洁，不确定时明确说不知道。")
                .defaultOptions(ChatOptions.builder()
                        .model("small-model-snapshot")
                        .temperature(0.2)
                        .maxTokens(512)
                        .build())
                .build();
    }

    @Bean("largeChat")
    ChatClient largeChat(ChatModel model) {
        return ChatClient.builder(model)
                .defaultOptions(ChatOptions.builder()
                        .model("large-model-snapshot")
                        .temperature(0.1)
                        .maxTokens(2048)
                        .build())
                .build();
    }
}
```

注意：**model 必须写快照名，不要写别名**（如 `gpt-4o` 这种会漂移的别名）。别名背后的实际模型可能在你不察觉时被升级，导致评测基线失效。

### 5.2 级联服务

```java
@Service
public class CascadeService {

    private final ChatClient small;
    private final ChatClient large;
    private final CompositeVerifier verifier;
    private final MeterRegistry meters;

    public CascadeResult answer(Query query) {
        long start = System.nanoTime();

        LlmAnswer draft = call(small, query, null);
        Verdict verdict = verifier.verify(draft, query.context());

        meters.counter("llm.cascade.draft",
                "model", "small", "pass", String.valueOf(verdict.pass())).increment();

        if (verdict.pass()) {
            return new CascadeResult(draft, false, elapsed(start));
        }

        // 升级：把草稿作为上下文，要求修正而非重写
        LlmAnswer refined = call(large, query, draft);
        meters.counter("llm.cascade.escalated").increment();
        return new CascadeResult(refined, true, elapsed(start));
    }

    private LlmAnswer call(ChatClient client, Query q, LlmAnswer draft) {
        String user = draft == null
                ? q.text()
                : """
                  原始问题：%s

                  初稿（可能有误）：
                  %s

                  请核对初稿，只输出修正后的最终答案。若初稿正确，原样返回。
                  """.formatted(q.text(), draft.text());

        ChatResponse resp = client.prompt().user(user).call().chatResponse();
        return new LlmAnswer(resp.getResult().getOutput().getText(),
                             extractCitations(resp),
                             resp.getMetadata().getUsage());
    }
}
```

### 5.3 预算守卫

级联必须防止「无限升级」和「单请求成本失控」：

```java
public class BudgetGuard {

    private final long dailyBudgetMicros;
    private final AtomicLong spentMicros = new AtomicLong();

    public boolean tryReserve(long estimatedMicros) {
        long now = spentMicros.get();
        if (now + estimatedMicros > dailyBudgetMicros) return false;
        return spentMicros.compareAndSet(now, now + estimatedMicros);
    }

    public void settle(long estimated, long actual) {
        spentMicros.addAndGet(actual - estimated);
    }
}
```

更细的做法是按租户/用户做两级桶，避免单租户打爆全局预算（参见按 Token 计量限流的文章，两者可以叠加）。

### 5.4 指标

```java
// 升级率
Gauge.builder("llm.cascade.escalation.ratio",
        () -> escalated.get() / (double) Math.max(1, total.get()))
     .register(registry);

// 单位成功成本
Counter success = Counter.builder("llm.task.success").register(registry);
Counter costMicros = Counter.builder("llm.cost.micros").register(registry);

// 成本/成功 = costMicros.count() / success.count()
```

必须按 `task_type`、`tenant`、`model_snapshot` 三个维度打标签，否则无法定位「哪个任务把升级率拉高了」。

## 六、蒸馏：把大模型能力固化

级联的天花板是「小模型不够好 → 升级率高 → 省不下来」。蒸馏就是提高小模型的上限。

### 6.1 三个层次

| 层次 | 做法 | 成本 | 效果 |
|---|---|---|---|
| 输出蒸馏 | 用教师模型的回答做 SFT 数据 | 中 | 显著 |
| 推理蒸馏 | 让教师输出推理过程，学生学过程 | 中高 | 复杂任务更好 |
| 偏好蒸馏 | 用偏好对做 DPO/KTO | 高 | 对齐风格与判断 |

大多数 Java 团队只需要做**输出蒸馏 + LoRA**。

### 6.2 数据飞轮

```
线上请求
 ├─ 教师模型（旗舰）生成高质量答案
 ├─ 验证器过滤（只留通过硬校验 + 高分的样本）
 ├─ 去重 / 脱敏 / 配比
 ├─ 构造 SFT 数据（instruction / input / output）
 ├─ LoRA 微调小模型
 ├─ 离线评测（金标集 + 对抗集）
 └─ 灰度上线 → 回流入库
```

关键：**训练数据必须来自你自己的业务分布**。用公开数据集微调，效果往往不如直接调 prompt。

### 6.3 数据构造的 Java 实现

```java
public record SftSample(String instruction, String input, String output, Map<String, Object> meta) {}

public class DatasetBuilder {

    public List<SftSample> build(List<TraceRecord> traces, CompositeVerifier verifier) {
        Map<String, SftSample> dedup = new LinkedHashMap<>();

        for (TraceRecord t : traces) {
            if (t.escalated()) continue;                 // 只用小模型一次答对的
            if (t.userFeedback() == Feedback.NEGATIVE) continue;
            if (t.answer().length() > 4000) continue;    // 过滤超长

            Verdict v = verifier.verify(t.answer(), t.context());
            if (!v.pass() || v.score() < 0.85) continue;

            String key = normalize(t.query()) + "|" + t.taskType();
            dedup.putIfAbsent(key, new SftSample(
                    systemPromptFor(t.taskType()),
                    t.query(),
                    t.answer().text(),
                    Map.of("task", t.taskType(), "model", t.teacherModel())));
        }
        return new ArrayList<>(dedup.values());
    }
}
```

配比经验：

- 简单任务 : 困难任务 ≈ 7 : 3，避免模型只会答简单题；
- 每个任务类型至少 500 条，少于这个量级 LoRA 容易过拟合；
- 保留 10% 的「拒绝回答」样本，教模型说「不知道」。

### 6.4 蒸馏后的收益测算

假设：

- 日均 100 万次请求；
- 级联前升级率 35%，旗舰单次 $0.012；
- 蒸馏后升级率降到 12%；
- 小模型单次 $0.0004。

```
优化前：1M × (0.65 × 0.0004 + 0.35 × 0.012) = $4460/天
优化后：1M × (0.88 × 0.0004 + 0.12 × 0.012) = $1792/天
节省：约 60%，年化 ~$97 万
```

再叠加缓存、批处理，降本空间更大。但**必须先确认质量没掉**：用小模型替换后，金标集通过率、人工抽检、线上负反馈率三个指标都要看。

## 七、踩坑清单

1. **升级 ≠ 更好**。大模型在小模型已经答对的题上也可能答错（尤其是格式约束强的任务）。升级请求要带上草稿，并要求「只修正错误」。
2. **双倍延迟**。级联最坏情况是「小模型超时 + 大模型再算一遍」。给每一级设独立超时，小模型超时直接跳大模型，不要重试。
3. **验证器本身会漂移**。用 LLM 做裁判时，裁判模型也会升级。裁判的 prompt 与模型都要锁版本。
4. **缓存污染**。如果按 prompt 做精确缓存，小模型和大模型的结果会混在一起。缓存 key 必须包含 `model_snapshot` 与 `prompt_version`。
5. **Token 计量口径不一**。不同厂商对 system prompt、工具定义、图片的计费方式不同，成本报表要对齐到「账单口径」，否则优化是自嗨。
6. **蒸馏数据含 PII**。训练前必须脱敏，且要确认厂商的微调数据保留政策。
7. **忽略输出长度**。输出 token 通常比输入贵 3~5 倍，`maxTokens` 不设限是隐形账单杀手。
8. **只优化平均成本**。P99 请求往往是长上下文 + 多轮工具调用，成本可能是均值的 50 倍。要按分位数做预算。

## 八、面试高频追问

**Q1：级联和路由的区别？**
路由是「事前决定用哪个模型」，级联是「事后根据结果决定是否升级」。路由成本低但可能误判，级联质量稳但最坏情况延迟翻倍。生产上常组合使用。

**Q2：怎么判断小模型的答案不可靠？**
结构校验、业务规则、引用溯源、自一致性、模型打分。硬规则一票否决，软信号加权。阈值用代价矩阵推，不要拍脑袋。

**Q3：蒸馏和微调是什么关系？**
蒸馏是目标（把教师能力迁移给学生），微调是手段（SFT/LoRA/DPO）。也可以用蒸馏 + 提示词、蒸馏 + 检索，不一定非要微调。

**Q4：为什么蒸馏数据要用自己的业务数据？**
模型的错误分布与业务强相关。公开数据训练出的学生，在你的长尾场景上仍然会错；而教师在你业务数据上的输出，天然覆盖了你的分布。

**Q5：级联会不会让延迟不可接受？**
会。要给每级设超时与预算，并在网关层做「总时限控制」。对延迟敏感的场景，用前置分类器替代级联，或直接走中档模型。

**Q6：怎么证明降本没有牺牲质量？**
三件事：离线金标集（分层抽样、置信区间）、线上影子流量（新老策略并行对比）、业务指标（成功率、负反馈率、人工抽检）。三者都过才放量。

## 九、小结

1. 降本的第一步是算账：单次成本、升级率、单位成功成本，三个指标一起看。
2. 级联的核心不是「小模型」，是**验证器**。没有可靠验证器的级联是在赌运气。
3. 升级时带上草稿，让大模型修正而非重写，能省 20~30% 输出 token。
4. 流式场景无法回收输出，高风险任务不要用「流式 + 后验证」。
5. 蒸馏的数据必须来自自己的业务分布，并且经过验证器过滤与脱敏。
6. 所有模型引用都写**快照名**，别名漂移会让你的评测与成本模型同时失效。

成本优化不是把模型换小，而是把「每个请求配得上多少智能」这件事工程化。级联负责分配，验证器负责兜底，蒸馏负责提高下限 —— 三者闭环，账单和质量才能同时守住。
