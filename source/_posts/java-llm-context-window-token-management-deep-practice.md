---
title: 【Java AI】上下文窗口与 Token 管理深度实战：截断、摘要压缩与 Token 计费核算
date: 2026-10-16 08:05:00
tags:
  - Java
  - AI
  - 大模型
  - Token
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】上下文窗口与 Token 管理深度实战：截断、摘要压缩与 Token 计费核算

## 前言

做 AI 应用，最容易被低估、又最先把人搞崩溃的，就是 **Token 与上下文窗口管理**。典型事故：多轮对话跑到第 20 轮突然 400 `context_length_exceeded`；RAG 塞了 30 个文档片段，成本一夜翻 5 倍；批量任务提示词把输入 token 撑爆，钱花了效果还差。

这篇文章用 **Java 视角**把这件事讲透：Token 到底怎么算、上下文窗口怎么逼近、五种压缩策略怎么选、Token 成本怎么在代码里核算，最后给一个可复用的 `ContextWindowManager`。

## 一、先搞懂 Token：它不是字符，也不是单词

大模型按 **BPE（Byte Pair Encoding）** 切词，Token 是最小的计费与上下文单位。

**经验估算（不同模型分词器不同，仅用于兜底）**：

| 语言 | 大约多少个 token |
|---|---|
| 英文 | 1 token ≈ 0.75 个单词 ≈ 4 个字符 |
| 中文 | 1 token ≈ 0.6~1.7 个汉字（常见 1 汉字 ≈ 1~2 token） |
| 代码 | 1 token ≈ 3~4 个字符（符号多，token 密度更高） |

```java
// 中文比英文"贵"得多：一段 1000 字中文可能 1500+ token
// 而 1000 个英文字符只有 ~250 token
```

**Java 精确计数**：用 `jtokkit`（OpenAI tiktoken 的 Java 实现）或 `com.knuddels:jtokkit`：

```java
import com.knuddels.jtokkit.Encodings;
import com.knuddels.jtokkit.api.*;

public class TokenCounter {
    private static final Encoding ENC =
        Encodings.newDefaultEncodingRegistry()
                 .getEncodingForModel(ModelType.GPT_4O);

    public static int count(String text) {
        return text == null ? 0 : ENC.countTokens(text);
    }

    public static int countMessages(List<ChatMessage> msgs) {
        // 官方公式含每条消息固定开销（约 3~4 token）+ 回复预留
        int total = 0;
        for (ChatMessage m : msgs) {
            total += count(m.getContent()) + 4;
        }
        return total + 2;
    }
}
```

> Spring AI 提供了 `TokenCountEstimator` 抽象，`OpenAiTokenCountEstimator` 内部就是 jtokkit；自研 Agent 时建议把它抽成独立组件，别到处 `length()/4`。

## 二、上下文窗口：三条会把你"撑爆"的线

| 概念 | 含义 | 超了会怎样 |
|---|---|---|
| 模型上下文窗口（Context Window） | 输入 + 输出总 token 上限 | 400 报错 / 截断 |
| 输入上限 | 有的模型输入单独限制 | 同上 |
| 单次输出上限（max_tokens） | 生成的最大长度 | 回答被截断（finish_reason=length） |

常见窗口：GPT-4o 128K、Claude 200K、DeepSeek 64K~128K、Qwen 长上下文 32K~1M。

**关键公式**：

```
可用输入预算 = 上下文窗口 - max_tokens(输出预留) - 安全余量(10%)
```

很多人只盯"窗口 128K 很大"，却忘了 **每轮都把历史全带上**——第 N 轮输入 ≈ 前 N-1 轮全部内容。**上下文是 O(n²) 增长的**，这才是成本与超限的根源。

## 三、五种上下文压缩策略（附选型表）

| 策略 | 做法 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| 直接截断 | 丢弃最旧消息 | 简单 | 丢信息、可能丢 system 约束 | 短对话兜底 |
| 滑动窗口 | 保留最近 K 轮 | 保留新鲜度 | 丢长期事实 | 闲聊、日志分析 |
| 摘要压缩 | 老消息 → LLM 摘要 | 保留语义、省 token | 多一次调用、有损 | 长对话、客服 |
| 关键信息抽取 | 抽实体/决策存结构化 | 精确、可检索 | 需要 schema | 任务型 Agent |
| 分层记忆/向量召回 | 需历史时按需检索 | 近乎无限记忆 | 架构复杂 | 长期 Agent（见记忆系统篇） |

**实践组合拳**（推荐默认）：**System/约束永远保留 → 保留最近 N 轮 → 更早的滚动摘要 → 必要时向量检索补充**。

### 3.1 截断策略实现

```java
public List<ChatMessage> truncate(List<ChatMessage> history, int budget) {
    List<ChatMessage> system = history.stream()
            .filter(m -> m.getRole() == Role.SYSTEM).toList();
    Deque<ChatMessage> recent = new ArrayDeque<>();
    int used = system.stream().mapToInt(m -> TokenCounter.countMessages(List.of(m))).sum();

    // 从最新往回装，装不下就停
    for (int i = history.size() - 1; i >= 0; i--) {
        ChatMessage m = history.get(i);
        if (m.getRole() == Role.SYSTEM) continue;
        int cost = TokenCounter.countMessages(List.of(m));
        if (used + cost > budget) break;
        recent.addFirst(m);
        used += cost;
    }
    List<ChatMessage> result = new ArrayList<>(system);
    result.addAll(recent);
    return result;
}
```

### 3.2 滚动摘要压缩

核心思想：**当 token 逼近阈值时，把"最老的一段对话"交给模型总结成一段，替换原文**。

```java
@Service
public class RollingSummarizer {
    private final ChatClient chat;             // Spring AI ChatClient
    private final int trigger;                 // 例如 6000
    private String summary = "";               // 累积摘要

    public String maybeCompress(List<ChatMessage> history) {
        int tokens = TokenCounter.countMessages(history);
        if (tokens < trigger) return summary;

        // 取最老的 1/2（保留最近一半原文）
        int cut = history.size() / 2;
        String old = history.subList(0, cut).stream()
                .map(m -> m.getRole() + ": " + m.getContent())
                .collect(Collectors.joining("\n"));

        String prompt = """
            请把以下对话压缩成不超过 200 字的要点摘要，保留：
            用户目标、关键结论、待办事项、偏好与约束。已有的历史摘要如下：
            【已有摘要】%s
            【新增对话】%s
            """.formatted(summary, old);

        this.summary = chat.prompt(prompt).call().content();
        return summary;
    }
}
```

**踩坑**：摘要必须**幂等可控**，把"已有摘要 + 新增"一起喂，否则每轮重摘会漂移、越摘越丢。摘要长度设硬上限（如 200 字），不然摘要本身会膨胀。

### 3.3 关键信息抽取（结构化记忆）

```java
// 用结构化输出把"事实"抽成 schema，永久保存，按需拼回 prompt
record Memory(String userGoal,
              List<String> constraints,
              List<String> todoItems,
              Map<String,String> preferences) {}
```

这样上下文里永远只带**浓缩事实**，而不是十几轮寒暄。

## 四、Token 计费核算：把成本写进代码

**计费公式**：

```
成本 = 输入token × 输入单价 + 输出token × 输出单价
（缓存命中部分用更低的缓存价；部分模型区分缓存写/读价）
```

**关键认知**：

1. **输出比输入贵 3~4 倍**，所以 `max_tokens` 要收敛，别不管。
2. **Prompt Caching**（Anthropic / DeepSeek / OpenAI）能大幅降低"固定前缀"成本——把 system + few-shot + 长文档放在**前缀**，命中缓存后单价可降到 1/10。
3. **多轮对话成本是 O(n²)**：第 n 轮把前面全带上，总成本随轮数平方增长。摘要/检索是唯一能打破平方的手段。

```java
public record Usage(long promptTokens, long completionTokens, long cachedTokens) {}

public BigDecimal cost(Usage u, BigDecimal inPrice, BigDecimal outPrice, BigDecimal cachePrice) {
    BigDecimal in  = BigDecimal.valueOf(u.promptTokens() - u.cachedTokens()).multiply(inPrice);
    BigDecimal c   = BigDecimal.valueOf(u.cachedTokens()).multiply(cachePrice);
    BigDecimal out = BigDecimal.valueOf(u.completionTokens()).multiply(outPrice);
    return in.add(c).add(out);
}
```

**生产建议**：把 `Usage` 每次调用都落库（traceId + userId + model + tokens），做**Token 账本**，按租户/接口/模型出报表，并设预算告警——否则月底账单会让你怀疑人生。

## 五、一个可复用的 ContextWindowManager

```java
@Component
public class ContextWindowManager {
    private final int window;      // 模型窗口
    private final int maxOutput;   // 输出预留
    private final double safety = 0.1;

    public int inputBudget() {
        return (int) ((window - maxOutput) * (1 - safety));
    }

    /** 组装最终 messages：system + 摘要 + 近期 + 当前问题 */
    public List<ChatMessage> build(List<ChatMessage> history,
                                   String rollingSummary,
                                   String current) {
        int budget = inputBudget();
        List<ChatMessage> msgs = new ArrayList<>();
        history.stream().filter(m -> m.getRole() == Role.SYSTEM).forEach(msgs::add);
        if (!rollingSummary.isBlank()) {
            msgs.add(new SystemMessage("【历史摘要】" + rollingSummary));
        }
        msgs.addAll(truncate(nonSystem(history), budget - reserve(msgs)));
        msgs.add(new UserMessage(current));

        int used = TokenCounter.countMessages(msgs);
        if (used > budget) {
            throw new IllegalStateException("上下文仍超预算: " + used + " > " + budget);
        }
        return msgs;
    }
}
```

## 六、面试/生产常见追问

- **窗口 128K，为什么还要压缩？** 成本（输入按量计费）＋ 长上下文"中间遗忘"（lost in the middle，有效信息集中在头尾）＋ 延迟（输入越长首 token 越慢）。
- **截断会不会破坏 tool call 配对？** 会！截断时不能把 `assistant(tool_calls)` 和 `tool` 结果拆开，否则报 schema 错——按"对话轮"而非"单条消息"裁剪。
- **摘要用什么模型？** 用便宜的小模型（如 flash 系列）即可，摘要不需要强推理。
- **怎么评估"压得好不好"？** 建黄金集，对比压缩前后的回答准确率 & token 消耗，算"每元有效回答数"。
- **缓存为什么能省钱？** 前缀稳定 → 命中 KV Cache，厂商按缓存价（常 1/10）计费；所以**把不变的东西放最前**。

## 总结

Token 与上下文管理是 AI 工程的"内存管理"：**截断是 GC，摘要是压缩，账本是可观测性**。落地三句话——**永远预留输出额度、用摘要打破 O(n²)、把 Token 账本落库**。把 `ContextWindowManager` 嵌进你的 Spring AI 项目，配合可观测性（下一篇会讲 Trace 与成本治理），你的 Agent 才能既跑得久又不烧钱。

延伸阅读：本系列 `java-llm-streaming-sse-webflux-deep-practice`（流式输出）、`spring-ai-rag-vectorstore-deep-practice`（RAG 检索）。
