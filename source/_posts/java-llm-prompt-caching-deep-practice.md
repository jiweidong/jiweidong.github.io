---
title: 【Java AI】Prompt Caching 深度实战：前缀缓存、命中率治理与 Spring AI/LangChain4j 落地
date: 2026-10-30 08:30:00
tags:
  - Java
  - AI
  - Prompt Caching
  - Spring AI
  - LangChain4j
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Prompt Caching 深度实战：前缀缓存、命中率治理与 Spring AI/LangChain4j 落地

## 前言

做 AI 应用的成本结构，往往和直觉相反：贵的不一定是"生成"，而是"每次都在重复传同一大段输入"。

一个典型的 RAG 问答服务，请求体长这样：

```text
[System Prompt: 角色定义 + 输出规范 + 安全条款]   ~1500 tokens
[工具定义: 12 个 Function Calling schema]          ~2000 tokens
[知识库上下文: top-5 文档片段]                     ~6000 tokens
[对话历史: 最近 6 轮]                              ~2000 tokens
[用户问题]                                         ~50 tokens
```

每次请求，前 9500 个 token 里有 3500 个是**一模一样**的。如果每天 10 万次请求，光这 3500 token 的重复输入就是 3.5 亿 token——按 Claude Sonnet 的 $3/M 算，一天 1000 美元，一年 37 万美元，全部花在"把同样的字再传一遍"上。

**Prompt Caching（提示缓存）** 就是来解决这个的：把稳定前缀在服务端缓存起来，后续请求命中缓存只需付 10% 的价格（各家比例不同）。做得好的话，输入成本能降 70~90%。

但这件事在工程上远不是"打开一个开关"。前缀怎么排布、什么变量会偷偷破坏缓存、命中率怎么度量、多租户怎么隔离——全是坑。本文用 Java 视角把这些讲透。

<!-- more -->

## 一、先看三家厂商的机制差异

| 维度 | Anthropic Claude | OpenAI | Google Gemini | DeepSeek |
|---|---|---|---|---|
| 触发方式 | **显式**：`cache_control` 标记断点 | **自动**：前缀 ≥1024 token 自动缓存 | 隐式 + 显式 `cachedContents` | 自动（磁盘缓存） |
| 最小长度 | 1024 token（Haiku 2048） | 1024 token | 1024~4096（按模型） | 64 token 起 |
| 缓存粒度 | 断点前的完整前缀 | 前缀按 128 token 递增匹配 | 完整内容对象 | 前缀块 |
| 默认 TTL | 5 分钟（可扩到 1 小时） | 5~10 分钟（低峰可到 1 小时） | 显式可配（默认 1 小时） | 数小时~数天 |
| 写入成本 | 1.25× 基础价（5min）/ 2× （1h） | 无额外费用 | 按存储时长计费 | 无额外费用 |
| 读取折扣 | **0.1×（省 90%）** | 0.5×（省 50%） | 0.25×（省 75%） | 约 0.1× |
| 断点数量 | 最多 4 个 | 无（自动） | 多个缓存对象 | 无 |
| 可控性 | **最高**（可精确控制缓存边界） | 低（只能优化前缀） | 中 | 低 |

**结论先行**：Anthropic 的机制最可控（显式断点 + 超低读取价），OpenAI 最省心但折扣小，Gemini 介于两者之间。做架构设计时，**不要假设"缓存一定命中"**，而是把它当成一个"可优化的成本项"，用指标驱动。

## 二、核心原理：为什么必须"前缀完全一致"

所有厂商的 Prompt Caching 本质都是**前缀哈希匹配**。服务端在收到请求时，逐块（通常 1024 token 一块）计算前缀哈希，命中已有缓存就直接复用 KV Cache（注意力机制的 Key/Value 张量），跳过这部分的前向计算。

这带来三条铁律：

1. **顺序决定命运**。稳定内容必须放最前面，易变内容放最后。把 `timestamp` 写在 system prompt 第一行，后面全废。
2. **任何字节变化都会截断匹配**。多一个空格、JSON 字段顺序变了、时间格式差一位，从变化点往后全部失效。
3. **缓存是"前缀树"，不是"键值对"**。多个请求共享同一前缀时才能复用；如果 A 租户和 B 租户的 system prompt 不同，那就各自一份缓存，互不干扰（这其实是好事，见第六节安全部分）。

用一张图表示理想的 Prompt 布局：

```text
┌─────────────────────────────────────────┐
│ L0: 全局 System Prompt（几乎不变）        │  ← 缓存断点 1
├─────────────────────────────────────────┤
│ L1: 工具定义（随版本变，日内不变）         │  ← 缓存断点 2
├─────────────────────────────────────────┤
│ L2: 租户/角色配置（租户级稳定）            │  ← 缓存断点 3
├─────────────────────────────────────────┤
│ L3: 检索上下文（每请求变）                 │
├─────────────────────────────────────────┤
│ L4: 对话历史（每轮追加）                   │
├─────────────────────────────────────────┤
│ L5: 用户问题（每请求变）                   │
└─────────────────────────────────────────┘
        稳定 ──────────────────► 易变
```

L0~L2 是缓存收益区，L3 之后基本不命中。**如果 L3 的检索上下文也能稳定复用**（比如同一个文档被反复提问），可以在 L3 末尾再加一个断点。

## 三、Anthropic 显式缓存：Java 落地

### 3.1 请求体结构

```json
{
  "model": "claude-sonnet-4-5",
  "system": [
    {
      "type": "text",
      "text": "你是一个严谨的技术文档助手……",
      "cache_control": { "type": "ephemeral" }
    }
  ],
  "tools": [ ... ],
  "messages": [ ... ]
}
```

`cache_control` 可以打在 `system` 块、`tools` 数组最后一项、`messages` 的某个 content block 上。**每个断点标记的是"到这里为止的所有内容"**，所以断点应该打在稳定段的末尾，而不是开头。

### 3.2 用 LangChain4j 直接开

LangChain4j 的 `AnthropicChatModel` 内置了两个开关，这是最省事的方式：

```java
import dev.langchain4j.model.anthropic.AnthropicChatModel;
import dev.langchain4j.model.chat.ChatModel;
import java.time.Duration;

ChatModel model = AnthropicChatModel.builder()
        .apiKey(System.getenv("ANTHROPIC_API_KEY"))
        .modelName("claude-sonnet-4-5")
        .maxTokens(2048)
        .temperature(0.2)
        .timeout(Duration.ofSeconds(60))
        // ★ 关键：缓存 system message 与 tools 定义
        .cacheSystemMessages(true)
        .cacheTools(true)
        .build();
```

这两个参数做的事就是给 system 块和 tools 数组末尾自动加 `cache_control: {"type":"ephemeral"}`。对 90% 的场景够用。

但如果你想**精确控制断点位置**（比如 system 分两段，只缓存第一段），就得走自定义：

```java
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;

public class CachedPromptService {

    private final ChatModel model;

    public CachedPromptService(ChatModel model) {
        this.model = model;
    }

    public String ask(String tenantConfig, String userQuestion) {
        // 稳定段：全局规范（跨租户共享，命中率最高）
        SystemMessage globalRole = SystemMessage.from(GLOBAL_SPEC);
        // 半稳定段：租户配置（租户内共享）
        SystemMessage tenantRole = SystemMessage.from(tenantConfig);

        ChatRequest request = ChatRequest.builder()
                .messages(globalRole, tenantRole, UserMessage.from(userQuestion))
                .build();

        ChatResponse response = model.chat(request);
        logUsage(response);
        return response.aiMessage().text();
    }

    private void logUsage(ChatResponse response) {
        var usage = response.tokenUsage();
        // LangChain4j 会把 Anthropic 的 cache 字段映射到 inputTokenDetails
        log.info("input={} output={} cacheRead={} cacheWrite={}",
                usage.inputTokenCount(),
                usage.outputTokenCount(),
                usage.inputTokenDetails() == null ? 0
                        : usage.inputTokenDetails().cachedTokens(),
                0);
    }

    private static final String GLOBAL_SPEC = """
            你是一名资深 Java 后端技术顾问。
            回答要求：
            1. 先给结论，再给论证；
            2. 代码示例必须是可编译的 Java 17+；
            3. 不确定的内容明确说"不确定"，禁止编造 API；
            4. 输出使用简体中文，术语保留英文原文。
            """;
}
```

### 3.3 Spring AI 侧：用 Advisor 注入 cache_control

截至 Spring AI 1.x，`AnthropicChatOptions` 还没有直接暴露 `cache_control` 字段。生产上两种做法：

**做法 A：自定义 Advisor 改写请求体**（推荐，侵入小）

```java
import org.springframework.ai.chat.client.ChatClientRequest;
import org.springframework.ai.chat.client.ChatClientResponse;
import org.springframework.ai.chat.client.advisor.api.CallAdvisor;
import org.springframework.ai.chat.client.advisor.api.CallAdvisorChain;
import org.springframework.ai.chat.prompt.Prompt;

/**
 * 在请求发出前，把 system message 标记为可缓存。
 * 通过在 Prompt 的 metadata 打标，交由自定义 ChatModel 实现消费。
 */
public class PromptCacheAdvisor implements CallAdvisor {

    @Override
    public String getName() {
        return "promptCacheAdvisor";
    }

    @Override
    public int getOrder() {
        return 0;   // 最外层，先于其它 Advisor
    }

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain) {
        Prompt prompt = request.prompt();
        var metadata = new HashMap<>(prompt.getOptions().getMetadata());
        metadata.put("anthropic.cacheSystem", true);   // 约定 key
        metadata.put("anthropic.cacheTools", true);

        var newOptions = org.springframework.ai.anthropic.AnthropicChatOptions.builder()
                .model("claude-sonnet-4-5")
                .metadata(metadata)
                .build();

        return chain.nextCall(request.mutate()
                .prompt(prompt.mutate().options(newOptions).build())
                .build());
    }
}
```

**做法 B：直接发 HTTP，完全掌控 body**（最稳）

```java
import org.springframework.web.client.RestClient;
import java.util.List;
import java.util.Map;

public class AnthropicCachedClient {

    private final RestClient http = RestClient.builder()
            .baseUrl("https://api.anthropic.com/v1")
            .defaultHeader("anthropic-version", "2023-06-01")
            .defaultHeader("content-type", "application/json")
            .build();

    @SuppressWarnings("unchecked")
    public Result chat(String apiKey, String globalSpec, String tenantSpec,
                       List<Map<String, Object>> tools, String question) {

        Map<String, Object> body = Map.of(
                "model", "claude-sonnet-4-5",
                "max_tokens", 2048,
                "system", List.of(
                        // 断点 1：全局规范
                        Map.of("type", "text", "text", globalSpec,
                               "cache_control", Map.of("type", "ephemeral")),
                        // 断点 2：租户配置
                        Map.of("type", "text", "text", tenantSpec,
                               "cache_control", Map.of("type", "ephemeral"))
                ),
                "tools", tools,
                "messages", List.of(
                        Map.of("role", "user",
                               "content", List.of(Map.of("type", "text", "text", question)))
                )
        );

        Map<String, Object> resp = http.post()
                .uri("/messages")
                .header("x-api-key", apiKey)
                .body(body)
                .retrieve()
                .body(Map.class);

        Map<String, Object> usage = (Map<String, Object>) resp.get("usage");
        int inputTokens      = (int) usage.getOrDefault("input_tokens", 0);
        int cacheRead        = (int) usage.getOrDefault("cache_read_input_tokens", 0);
        int cacheCreation    = (int) usage.getOrDefault("cache_creation_input_tokens", 0);

        return new Result(extractText(resp), inputTokens, cacheRead, cacheCreation);
    }

    public record Result(String text, int inputTokens, int cacheRead, int cacheCreation) {}
}
```

**注意一个反直觉的点**：`input_tokens` 只统计**未命中缓存**的部分。所以总输入 = `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`。很多人只看 `input_tokens` 算出"成本降了 90%"，其实是漏算了缓存读取的 token。

## 四、OpenAI 自动缓存：只需做对前缀

OpenAI 是自动的，但有两个可以优化的点：

```java
// 1) 用 prompt_cache_key 提升路由命中率（同一会话/同一租户固定 key）
Map<String, Object> body = Map.of(
        "model", "gpt-4.1",
        "prompt_cache_key", "tenant:42:docqa:v3",   // ★ 稳定 key
        "messages", List.of(
                Map.of("role", "system", "content", globalSpec),
                Map.of("role", "system", "content", tenantSpec),
                Map.of("role", "user", "content", question)
        )
);

// 2) 从 usage 里读命中量
// "usage": {
//   "prompt_tokens": 8200,
//   "prompt_tokens_details": { "cached_tokens": 7000 },
//   "completion_tokens": 350
// }
```

Spring AI 的 `OpenAiApi.ChatCompletion.Usage` 里有 `promptTokensDetails().cachedTokens()`，可以直接拿：

```java
ChatResponse response = openAiChatModel.call(prompt);
var usage = response.getMetadata().getUsage();
long cached = usage.getPromptTokensDetails() == null
        ? 0L : usage.getPromptTokensDetails().getCachedTokens();
long total  = usage.getPromptTokens();
double hitRate = total == 0 ? 0 : (double) cached / total;
meterRegistry.gauge("llm.prompt.cache.hit_rate", hitRate);
```

`prompt_cache_key` 的价值在于：OpenAI 的缓存是**按机器分片的**，同一个前缀如果被路由到不同机器就命中不了。给一个稳定的 key，能让相同前缀尽量落到同一台机器上。多租户场景下，key 里带上租户 ID，既提升命中又天然隔离。

## 五、命中率治理：从"能不能"到"有多高"

只开开关是不够的，必须有指标闭环。

### 5.1 四个核心指标

| 指标 | 计算 | 目标 | 异常含义 |
|---|---|---|---|
| 缓存命中率 | `cache_read / (cache_read + cache_creation + input)` | > 70% | 前缀被污染 |
| 缓存写入比 | `cache_creation / total_input` | < 10% | 缓存频繁重建（TTL 太短或前缀抖动） |
| 单次省费 | `cache_read * (base - cache_read_price)` | 持续为正 | 写入成本超过收益 |
| 首 token 延迟 | 命中 vs 未命中对比 | 命中快 20~40% | 服务端缓存未生效 |

### 5.2 Micrometer 埋点

```java
@Component
public class LlmCostMetrics {

    private final Counter cacheRead;
    private final Counter cacheWrite;
    private final Counter uncached;
    private final DistributionSummary costSaved;

    public LlmCostMetrics(MeterRegistry registry) {
        this.cacheRead = Counter.builder("llm.tokens").tag("type", "cache_read").register(registry);
        this.cacheWrite = Counter.builder("llm.tokens").tag("type", "cache_write").register(registry);
        this.uncached = Counter.builder("llm.tokens").tag("type", "uncached").register(registry);
        this.costSaved = DistributionSummary.builder("llm.cost.saved.usd")
                .baseUnit("usd").register(registry);
    }

    /** Claude Sonnet 定价（示例，按官方价格表替换） */
    private static final double BASE_IN   = 3.0 / 1_000_000;
    private static final double CACHE_READ = 0.3 / 1_000_000;
    private static final double CACHE_WRITE = 3.75 / 1_000_000;

    public void record(String model, int input, int read, int write) {
        uncached.increment(input);
        cacheRead.increment(read);
        cacheWrite.increment(write);

        double saved = read * (BASE_IN - CACHE_READ)
                     - write * (CACHE_WRITE - BASE_IN);
        costSaved.record(saved);
    }
}
```

配一条告警：`hit_rate < 0.5` 持续 15 分钟就报警。命中率突然掉，通常意味着有人改了 system prompt 或者工具定义顺序。

## 六、六个真实的踩坑

**坑 1：JSON 序列化顺序不稳定。**

```java
// 灾难写法：HashMap 不保证顺序
Map<String, Object> toolSchema = new HashMap<>();   // ← 每次序列化字段顺序可能不同
```

工具定义的 schema 用 `HashMap` 组装，Jackson 序列化出来的字段顺序可能随 JVM 版本/hash 种子变化，**前缀哈希就变了，缓存全部失效**。必须用 `LinkedHashMap` 或 `@JsonPropertyOrder` 固定顺序。

**坑 2：system prompt 里塞了时间戳。**

```java
// 100% 破坏缓存
String system = "当前时间：" + LocalDateTime.now() + "\n你是一个助手……";
```

需要时间就把时间放到 **user message** 里，或者用"当前日期（精确到天）"且只在跨天时重建。

**坑 3：多轮对话把历史拼在 system 前面。**

有些实现把"对话摘要"插到 system 末尾。摘要每轮都变 → system 前缀每轮都变 → 缓存永远打不中。正确做法是摘要放 messages 里，system 保持纯静态。

**坑 4：Locale / 时区影响格式化输出。**

```java
String spec = String.format("金额单位：%,.2f 元", 1000.0);
// 不同 Locale 输出 "1,000.00" vs "1.000,00"，字节就不同了
```

生成 prompt 的代码要显式指定 `Locale.ROOT`，否则同一个应用在不同环境下前缀不一致。

**坑 5：把缓存当"跨请求共享内存"用。**

Prompt Caching 缓存的是**计算结果**，不是你的业务数据。它不保证命中，也不保证隔离级别。**不能**把用户 A 的隐私数据放在可缓存前缀里，指望"只有 A 能读到"——虽然实际上前缀不同就不会共享，但这是实现细节，不是安全契约。多租户必须在前缀里显式带租户标识。

**坑 6：以为"缓存永久有效"。**

5 分钟 TTL 意味着低 QPS 的服务根本吃不到缓存红利。日均 100 次请求的服务，两次请求间隔可能就超过 5 分钟了，写入成本反而亏。**先算 QPS 再决定要不要开**：

```text
收益 = (BASE_IN - CACHE_READ) * read_tokens
     - (CACHE_WRITE - BASE_IN) * write_tokens

若每分钟请求数 < 1/5min * 稳定前缀长度占比，则可能负收益
```

## 七、成本模型：一个真实算例

场景：RAG 问答，system 1500 + tools 2000 = 3500 token 稳定前缀，其余 5000 token 易变，日请求 10 万次，模型 Claude Sonnet（输入 $3/M）。

**不开缓存**：

```text
日输入 = 100,000 × 8,500 = 850M tokens
成本   = 850 × $3 = $2,550/天
```

**开缓存（假设命中率 85%，每 5 分钟重建一次 → 288 次/天）**：

| 项目 | Token 量 | 单价 | 成本 |
|---|---|---|---|
| 缓存写入 | 288 × 3,500 = 1.0M | $3.75/M | $3.8 |
| 缓存读取 | 850M × 85% × 41% ≈ 296M | $0.30/M | $88.8 |
| 未命中输入 | 850M - 296M - 1M ≈ 553M | $3.00/M | $1,659 |
| **合计** | | | **$1,751/天** |

省了 $799/天，约 **31%**。看起来不如宣传的 90%，原因很直白：**稳定前缀只占总输入的 41%**，剩下 59% 是每请求都变的检索上下文。

想进一步提上去，只有两条路：
1. **压缩易变部分**（RAG 片段去重、摘要、按需加载）——把 5000 降到 2500，整体成本再降 20%
2. **让检索上下文也可缓存**（同一文档被反复问时，把文档片段也纳入稳定前缀）——提升稳定占比到 70%+，成本再降 40%

这就是为什么"**Prompt Caching 的优化重点是 prompt 结构，不是 API 参数**"。

## 八、面试常见追问

**Q1：Prompt Caching 缓存的是什么？**

缓存的是 Transformer 前向计算中每一层的 Key/Value 张量（KV Cache），按 token 前缀分块存储。命中后这段前缀不再做前向计算，直接复用张量。所以它省的是**计算 + 输入计费**，输出部分完全不受影响。

**Q2：为什么必须有最小 token 长度？**

KV Cache 存储有固定开销（索引、对齐、元数据），太短的前缀存下来不划算，命中收益覆盖不了存储成本。各家把门槛定在 1024 token 左右就是这个原因。

**Q3：缓存会不会导致不同用户数据串味？**

不会。缓存 key 是前缀内容的哈希，前缀不同就不可能命中。但**不能把安全依赖在这个机制上**——正确做法是租户隔离做在前缀里（显式带 tenantId），或者用不同的 API key / 项目隔离。

**Q4：写入成本 1.25 倍，什么情况下会亏？**

当前缀被复用次数少时。盈亏平衡点是：`复用次数 × (BASE - READ) > (WRITE - BASE)`，即 `n × 2.7 > 0.75`，n ≥ 1 次左右就有微利（以 Claude 价格算）。但考虑到 5 分钟 TTL，如果两次请求间隔经常超过 5 分钟，缓存会反复重建，写入成本就白花了。

**Q5：怎么在 Java 层保证前缀稳定？**

三个手段：一是把 prompt 模板固化成常量类（编译期确定），二是用 `LinkedHashMap`/`@JsonPropertyOrder` 固定序列化顺序，三是禁止模板里出现 `now()`、`UUID.randomUUID()`、`System.identityHashCode()` 这类不确定值。再加一条 CI 检查：对同一模板连续渲染两次，比对字节是否完全一致。

## 九、总结

| 要点 | 结论 |
|---|---|
| 本质 | 前缀 KV Cache 复用，省计算也省输入计费 |
| 前提 | 前缀**字节级**完全一致，稳定内容必须前置 |
| 收益上限 | Claude 读取 0.1×（省 90%），OpenAI 0.5×（省 50%） |
| 真实收益 | 取决于"稳定前缀占总输入的比例"，通常 30~60% |
| Java 落地 | LangChain4j `cacheSystemMessages/cacheTools` 最省事；Spring AI 用 Advisor 或直发 HTTP |
| 度量 | `cache_read / total_input`，配 Micrometer + 告警 |
| 最容易踩 | JSON 字段顺序、时间戳入 prompt、Locale 差异、TTL 太短 |

Prompt Caching 是当前 AI 应用里"投入产出比最高"的优化之一：不改模型、不改业务逻辑，只调整 prompt 的拼装顺序，成本就能降三到五成。但它同时也是一面照妖镜——**能做好 Prompt Caching 的团队，说明它对 prompt 结构、序列化稳定性、成本度量都有清晰掌控**，这恰恰是从"能跑通 Demo"到"能上生产"的分水岭。
