---
title: 【AI Agent】澄清与追问深度解析：什么时候该问用户，什么时候必须猜
date: 2026-11-26 08:00:00
tags:
  - AI
  - Agent
  - 对话系统
  - Prompt
  - Java
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】澄清与追问深度解析

## 前言

做 Agent 的人迟早会碰到这个岔路口：

用户说：「帮我订下周三去上海的机票。」

Agent 面临三个选择：

1. 直接猜：下周三 = 最近的那个周三，上海 = 虹桥或浦东随便，时间 = 上午，舱位 = 经济舱；
2. 问一句：「下周三具体几号？从哪个城市出发？大概几点？」
3. 一边猜一边问：「我先按 12 月 2 日、上午 9 点、经济舱查，如果你要改随时说。」

选 1，可能订错；选 2，用户嫌烦；选 3，体验最好，但实现最难。

更麻烦的是，很多团队把「澄清」做成了无条件追问：每个缺字段都问一遍，用户被连续问五个问题，直接关掉对话框。另一批团队则相反，什么都敢猜，最后把「取消订单」猜成「查询订单」。

**澄清不是「缺什么问什么」，而是一个成本决策问题。** 本文讨论四件事：什么时候该问、问什么、怎么问、问完之后怎么收场。

> 分工说明：站内已有《多轮指代消解与上下文改写》，讲的是「把不完整的 query 补全成可检索的 query」；本篇讲的是「补不全时，是问用户还是带着假设继续」。两者是上下游关系。

---

## 一、先分清三类不确定性

不是所有「不确定」都值得澄清。先分类：

| 类型 | 例子 | 处理方式 |
|---|---|---|
| 槽位缺失 | 订机票没给出发城市 | 可推断则推断，不可推断则问 |
| 指代/语义歧义 | 「那个订单」指哪一个 | 先用上下文消解，消解不了再问 |
| 目标冲突 | 「便宜点但要直飞还要今天到」 | 必须澄清优先级，不能猜 |
| 事实不确定 | 用户说的航班号不存在 | 不要问「你确定吗」，要给出校验结果 |
| 能力边界 | 用户要求改签，但系统只能退票 | 直接说明能力，不是澄清 |

最后一类经常被误做成澄清。用户问「能不能开发票」，Agent 回「请问您要开什么类型的发票」——但系统根本不支持开票。这不是澄清，是**能力告知**。

---

## 二、决策模型：猜还是问

### 2.1 一个简化的期望效用

设：

- `V`：任务成功带来的价值；
- `C_ask`：问一次的成本（一轮交互、用户流失风险、token）；
- `C_wrong`：猜错造成的损失（订错票的改签费、发错邮件的后果）；
- `p`：在当前上下文下，猜对的概率。

两种策略的期望收益：

```
猜：  p × V − (1 − p) × C_wrong
问：  V − C_ask          （假设问了就能得到正确答案）
```

当 `p × V − (1 − p) × C_wrong > V − C_ask` 时，应该猜。整理后：

```
p > 1 − (C_ask + C_wrong) / (V + C_wrong)
```

这个式子不需要精确计算，但它揭示了三个直觉：

1. `C_wrong` 越大，越应该问；
2. `C_ask` 越大（用户越不耐烦、场景越紧急），越应该猜；
3. `V` 越大（任务越重要），越值得问清楚。

### 2.2 代价矩阵

工程上更实用的是把「操作类型 × 可逆性」做成矩阵：

| 操作类型 | 可逆 | 建议 |
|---|---|---|
| 查询、搜索、推荐 | 是 | 直接猜，错了再改，不要问 |
| 生成草稿、总结 | 是 | 直接生成，给出「可编辑」入口 |
| 创建草稿订单、预约 | 是 | 带默认值执行，明确告知假设 |
| 支付、扣款 | 否 | 必须确认金额与对象 |
| 发送邮件/消息给外部 | 否 | 必须确认收件人与内容 |
| 删除、退款、取消 | 否 | 必须确认对象，必要时二次确认 |
| 修改权限、密钥 | 否 | 必须走审批流，不是普通澄清 |

这张表应该写进代码，而不是写在 prompt 里靠模型自觉。

---

## 三、槽位模型：先能推断，再决定问

### 3.1 槽位的四个来源

```java
public enum SlotSource {
    USER_EXPLICIT,   // 用户本轮明确说了
    CONTEXT,         // 对话历史里有
    MEMORY,          // 长期记忆/用户画像
    DEFAULT,         // 业务默认值
    INFERRED         // 模型推断（置信度最低）
}

public record Slot(
        String name,
        Object value,
        SlotSource source,
        double confidence,
        boolean required,
        boolean irreversible) {
}
```

优先级：`USER_EXPLICIT > CONTEXT > MEMORY > DEFAULT > INFERRED`。

同一个槽位有多个来源时，不要简单覆盖，要记录冲突。例如用户画像里是「上海」，本轮说「从杭州出发」，必须以本轮为准，并更新画像。

### 3.2 必填槽位不要全问

假设订机票需要 8 个字段：出发地、目的地、日期、时间、舱位、人数、证件、联系电话。

用户只说「下周三去上海」，真的要问 6 个问题吗？

- 出发地：可以从用户所在城市/常用出发地推断；
- 时间：可以默认「全天」，给出排序；
- 舱位：可以默认经济舱；
- 人数：可以默认 1；
- 证件/电话：可以等到下单前再要，不要在意图阶段就问。

**原则：意图阶段只问「影响搜索结果」的槽位，交易阶段才问「影响下单」的槽位。** 把 8 个问题拆成两批，体验会好很多。

### 3.3 置信度怎么来

置信度不是让模型随口给个 0.8。更可靠的做法是规则 + 模型结合：

```java
public double score(Slot slot, ConversationContext ctx) {
    return switch (slot.source()) {
        case USER_EXPLICIT -> 1.0;
        case CONTEXT -> ctx.hasRecentMention(slot.name()) ? 0.9 : 0.7;
        case MEMORY -> ctx.memoryFreshDays(slot.name()) < 90 ? 0.8 : 0.5;
        case DEFAULT -> 0.6;
        case INFERRED -> 0.4;
    };
}
```

低于阈值的槽位进入「待澄清」集合，高于阈值的直接采用并在回复里说明假设。

---

## 四、澄清问题怎么生成

### 4.1 四条硬规则

1. **一次只问一个**：多个问题合并成一句，用户只会回答最后一个；
2. **能给选项就给选项**：2~4 个，最后一个可以是「其他」；
3. **不要问系统已经知道的**：从上下文/记忆里能拿到的，不要重复问；
4. **说明为什么问**：尤其是敏感信息，「需要手机号才能接收取票通知」比「请输入手机号」更容易被接受。

### 4.2 封闭式 vs 开放式

| 类型 | 例子 | 适用 |
|---|---|---|
| 封闭式 | 「是虹桥还是浦东？」 | 选项可枚举、用户容易判断 |
| 半开放 | 「大概几点出发？上午/下午/晚上都可以」 | 有默认区间 |
| 开放式 | 「你想从哪里出发？」 | 选项太多、无法枚举 |

开放式问题尽量少用。用户面对空白输入框时，流失率明显高于点选项。

### 4.3 带默认值的「确认式澄清」

比「问」更轻的方式是「带假设执行 + 给修正入口」：

> 我先按「12 月 2 日（周三）上午、虹桥出发、经济舱、1 人」帮你查，如果有出入随时告诉我。

这种方式把 `C_ask` 降到接近 0，同时保留了纠正机会。适合可逆、低风险的场景。

### 4.4 不要生成「审问式」问题

反例：

> 请提供：1. 出发城市 2. 到达城市 3. 出发日期 4. 出发时间 5. 舱位 6. 人数

这是表单，不是对话。正确做法是先推断能推断的，只问真正缺失的一两个。

---

## 五、结构化输出：让澄清可编程

不要让模型自由输出一段话，然后你再用正则去猜它是不是在提问。用结构化契约：

```java
public record ClarificationDecision(
        Action action,              // ASK / ASSUME / PROCEED / REFUSE
        String slotName,
        String question,
        List<String> options,
        Object assumedValue,
        double confidence,
        String reason) {

    public enum Action { ASK, ASSUME, PROCEED, REFUSE }
}
```

对应的 JSON Schema 可以这样约束：

```json
{
  "type": "object",
  "required": ["action", "confidence", "reason"],
  "properties": {
    "action":     { "enum": ["ASK", "ASSUME", "PROCEED", "REFUSE"] },
    "slotName":   { "type": "string" },
    "question":   { "type": "string", "maxLength": 120 },
    "options":    { "type": "array", "maxItems": 4, "items": { "type": "string" } },
    "assumedValue": {},
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
    "reason":     { "type": "string", "maxLength": 200 }
  }
}
```

### 5.1 Spring AI 落地

```java
@Service
public class ClarificationService {

    private final ChatClient chatClient;
    private final ObjectMapper objectMapper;

    public ClarificationDecision decide(String userInput, List<Slot> slots) {
        String slotJson = writeJson(slots);

        String raw = chatClient.prompt()
                .system("""
                        你是澄清决策器。根据用户输入与已知槽位，决定下一步动作。
                        规则：
                        1. 可逆且低风险的操作，优先 ASSUME 并给出假设值；
                        2. 不可逆操作（支付/删除/对外发送）缺关键槽位时必须 ASK；
                        3. 一次最多问一个问题，选项不超过 4 个；
                        4. 不要询问已知槽位；
                        5. 无法完成时用 REFUSE 并说明能力边界。
                        只输出 JSON，不要解释。
                        """)
                .user("用户输入：" + userInput + "\n已知槽位：" + slotJson)
                .call()
                .content();

        ClarificationDecision decision = parse(raw);
        validate(decision);
        return decision;
    }

    private void validate(ClarificationDecision d) {
        if (d.action() == ClarificationDecision.Action.ASK) {
            if (d.question() == null || d.question().isBlank()) {
                throw new IllegalStateException("ASK 必须带 question");
            }
            if (d.options() != null && d.options().size() > 4) {
                throw new IllegalStateException("选项过多");
            }
        }
        if (d.action() == ClarificationDecision.Action.ASSUME
                && d.assumedValue() == null) {
            throw new IllegalStateException("ASSUME 必须带 assumedValue");
        }
    }
}
```

解析失败时不要直接把模型输出丢给用户，要降级成「保守追问」：

```java
private ClarificationDecision parse(String raw) {
    try {
        return objectMapper.readValue(stripCodeFence(raw), ClarificationDecision.class);
    } catch (Exception e) {
        return new ClarificationDecision(
                ClarificationDecision.Action.ASK,
                "unknown",
                "我需要再确认一下你的需求，能具体说说吗？",
                List.of(),
                null,
                0.0,
                "fallback: parse failed");
    }
}
```

---

## 六、多轮状态：问完之后怎么收场

### 6.1 持久化待澄清状态

澄清不是「问完就忘」，要有状态机：

```java
public record PendingClarification(
        String conversationId,
        String slotName,
        String question,
        List<String> options,
        Instant askedAt,
        int attempt,
        ClarificationDecision.Action fallbackAction) {
}
```

存 Redis，带 TTL（例如 10 分钟）。用户下一轮输入先和 pending 状态匹配，而不是重新跑一遍完整意图识别。

### 6.2 用户答非所问

用户可能：

- 回答了另一个槽位；
- 说「随便」；
- 直接换话题；
- 情绪化回复。

处理策略：

| 情况 | 处理 |
|---|---|
| 回答了另一个槽位 | 更新该槽位，保留 pending，再问一次 |
| 「随便/都行」 | 采用默认值，PROCEED |
| 换话题 | 放弃 pending，处理新意图 |
| 连续两次未回答 | 采用 fallback 或转人工 |

### 6.3 重问上限

同一个槽位最多问两次。第二次仍不明确，就：

- 可逆操作：采用默认值并明确告知；
- 不可逆操作：拒绝执行并说明原因，或转人工。

无限重问是最容易被用户骂的设计。

### 6.4 超时

pending 超过 TTL 自动失效，下一轮当作新会话处理。不要拿一个 3 天前的「请问您要哪一天？」去问用户。

---

## 七、什么时候不该问

### 7.1 不该问的四种情况

1. **可逆且低成本**：搜索、推荐、草稿，错了再改；
2. **有强默认**：绝大多数用户都会选的选项；
3. **用户明确授权**：「你看着办」「按上次的来」；
4. **能从上下文可靠推断**：上一轮刚说过，不要重复问。

### 7.2 必须问的四种情况

1. **不可逆**：支付、删除、退款、取消；
2. **涉及金钱**：金额、优惠、发票；
3. **对外发送**：邮件、短信、公开帖子；
4. **合规/隐私**：收集证件、位置、健康信息。

这四类不要用「带假设执行」，必须显式确认。

### 7.3 一个反例

某客服 Agent 在用户说「我要退款」时，直接调了退款工具，因为「退款」意图很明确。但它没确认退哪一笔订单——用户有三笔未完成订单。结果退错了，金额还不小。

正确做法：意图明确 ≠ 参数明确。**意图置信度高，不代表槽位置信度高**，两者要分开判断。

---

## 八、指标：澄清做得好不好

| 指标 | 定义 | 目标 |
|---|---|---|
| 澄清率 | 触发澄清的会话 / 总会话 | 10%~25%，过高说明槽位设计差 |
| 一次解决率 | 首轮或澄清一轮内完成 / 总会话 | 越高越好 |
| 平均澄清轮次 | 澄清问题数 / 澄清会话 | < 1.5 |
| 放弃率 | 澄清后用户离开 / 澄清会话 | < 15% |
| 误澄清率 | 本可直接执行却追问 / 澄清会话 | < 10% |
| 假设推翻率 | ASSUME 后被用户纠正 / ASSUME 次数 | 越低越好 |
| 澄清后满意度 | 带澄清会话的评分 | 不低于无澄清会话 |

离线评测要构造三类样本：

1. **该问的**：缺关键槽位 + 不可逆操作；
2. **不该问的**：信息齐全或有强默认；
3. **问了也白问的**：系统能力不支持。

分别计算准确率/召回率，避免只优化「该问」而把「不该问」也拉高。

---

## 九、踩坑清单

1. **把能力边界当澄清**：不支持的功能要直接说，不要问细节；
2. **一次问多个问题**：用户只会回答最后一个；
3. **问已知信息**：上下文里刚说过，再问会让用户觉得系统失忆；
4. **没有 pending 状态**：用户回答后重新跑意图识别，答非所问；
5. **无限重问**：同一槽位最多两次；
6. **ASSUME 不告知**：带了假设却不说明，用户以为系统理解对了；
7. **不可逆操作也 ASSUME**：退款、支付必须确认；
8. **澄清问题太长**：超过 120 字，用户不看；
9. **没有 fallback**：模型输出解析失败时直接报错。

---

## 十、面试追问

**Q1：怎么判断该澄清还是该猜？**

看三个变量：猜对的概率、猜错的代价、问的成本。可逆低风险操作直接猜并告知假设；不可逆或涉及金钱/对外发送的必须问。工程上落地为「操作类型 × 可逆性」的代价矩阵，而不是靠 prompt。

**Q2：用户说「随便」，怎么办？**

采用默认值并明确告知，例如「那我按经济舱、上午出发帮你查」。不要继续追问，也不要不说明就执行。

**Q3：澄清状态怎么存？**

Redis + TTL，key 为 conversationId，value 包含槽位名、问题、选项、已问次数、fallback 动作。下一轮先匹配 pending，再走新意图识别。

**Q4：怎么评估澄清策略？**

离线用三类样本（该问/不该问/白问）算准确率与误澄清率；线上看澄清率、一次解决率、平均轮次、放弃率、假设推翻率。单看「任务完成率」会掩盖过度追问的问题。

**Q5：澄清和指代消解是什么关系？**

指代消解是「尽量把 query 补全」，澄清是「补不全时的决策」。先做消解与槽位推断，仍低于置信度阈值才进入澄清。顺序反了会导致大量本可推断的问题被拿去问用户。

---

## 十一、总结

五句话：

1. 澄清是成本决策，不是「缺什么问什么」；
2. 先推断（上下文/记忆/默认），推断不了再问；
3. 可逆低风险带假设执行，不可逆高风险必须确认；
4. 一次只问一个，给选项，说明原因，最多问两次；
5. 用结构化契约 + 持久化状态 + 指标闭环，别让模型自由发挥。

好的澄清让用户觉得「它懂我」；坏的澄清让用户觉得「它在审我」。差别不在模型，而在你有没有把决策逻辑写进系统。
