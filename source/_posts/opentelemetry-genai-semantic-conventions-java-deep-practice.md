---
title: 【Java AI】OpenTelemetry GenAI 语义约定深度实战：gen_ai.* 属性、Token 指标与 Agent 链路
date: 2026-11-21 08:30:00
tags:
  - Java
  - AI
  - OpenTelemetry
  - 可观测性
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】OpenTelemetry GenAI 语义约定深度实战

## 前言

大模型应用上线后，第一个冒出来的问题通常不是"效果好不好"，而是这三句：

- 这个请求为什么慢了 8 秒，慢在检索、排队、还是模型本身？
- 这个月的 token 账单为什么翻了三倍，是哪个功能、哪个租户、哪个模型烧的？
- Agent 调了 6 次工具才给出答案，中间哪一步跑偏了？

传统 APM 答不了这些。HTTP span 只能告诉你"POST /chat 用了 8 秒"，剩下全是黑盒。所以 OpenTelemetry 社区从 2024 年开始推 **GenAI 语义约定（Semantic Conventions for Generative AI）**，目标是把"模型调用"变成一等公民的遥测对象：统一的 span 名、统一的 `gen_ai.*` 属性、统一的 token 指标。

这东西的价值不在于"多一个监控面板"，而在于**跨厂商可比**：OpenAI、Anthropic、Bedrock、vLLM 自建，只要按同一套约定埋点，Dashboard 和告警就不用改。

这篇文章讲清楚约定长什么样、Java 侧怎么落、以及生产里最容易踩的坑。

## 一、语义约定的骨架：三个概念

### 1.1 Span 的层次结构

一次"用户提问 → Agent 思考 → 调工具 → 再问模型 → 回答"，标准建模是：

```text
invoke_agent research-agent            (INTERNAL)
├── chat gpt-4o-mini                   (CLIENT)
├── execute_tool web_search            (INTERNAL)
│   └── chat gpt-4o-mini               (CLIENT，用于生成检索词)
├── execute_tool fetch_page            (INTERNAL)
└── chat gpt-4o-mini                   (CLIENT，最终回答)
```

三条规则：

1. **模型调用是 `CLIENT` span**，因为它是"我向外部服务发请求"。这样 trace 拓扑里能直接看出对外依赖。
2. **Agent 编排和工具执行是 `INTERNAL`**，它们是进程内逻辑。
3. **span 名是 `{operation} {model}`**，比如 `chat gpt-4o-mini`。这样在 trace 列表里不点开就能看出用的什么模型 —— 这是约定里最实用的一条。

### 1.2 核心属性表

| 属性 | 类型 | 示例 | 说明 |
|---|---|---|---|
| `gen_ai.operation.name` | string | `chat` | 必填，见下表 |
| `gen_ai.provider.name` | string | `openai` | 供应商，替代旧的 `gen_ai.system` |
| `gen_ai.request.model` | string | `gpt-4o-mini` | 请求的模型名 |
| `gen_ai.response.model` | string | `gpt-4o-mini-2024-07-18` | **实际**服务的模型快照 |
| `gen_ai.request.max_tokens` | int | `1024` | 请求参数 |
| `gen_ai.request.temperature` | double | `0.2` | 请求参数 |
| `gen_ai.usage.input_tokens` | int | `1832` | 输入 token |
| `gen_ai.usage.output_tokens` | int | `256` | 输出 token |
| `gen_ai.response.finish_reasons` | string[] | `["stop"]` | 结束原因，数组 |
| `gen_ai.response.id` | string | `chatcmpl-...` | 供应商响应 ID，用于对账 |
| `gen_ai.conversation.id` | string | `conv-9f2a` | 会话 ID，串多轮 |
| `gen_ai.agent.name` | string | `research-agent` | Agent 标识 |
| `gen_ai.tool.name` | string | `web_search` | 工具名 |
| `gen_ai.tool.call.id` | string | `call_abc` | 工具调用 ID，与模型返回对应 |
| `error.type` | string | `RateLimitExceeded` | 失败分类 |

`gen_ai.operation.name` 的取值：

| 值 | 语义 |
|---|---|
| `chat` | 对话补全（含多模态输入） |
| `text_completion` | 传统文本补全 |
| `embeddings` | 向量化 |
| `generate_content` | Gemini 风格的生成 |
| `execute_tool` | 执行一次工具调用 |
| `invoke_agent` | 调用一个 Agent |
| `create_agent` | 创建 Agent（初始化） |

### 1.3 内容捕获是 opt-in

`gen_ai.prompt` / `gen_ai.completion` 这类"把提示词全文塞进 span"的老属性已经被标记为**不推荐**。现在的方式是：

- **默认不记录任何内容**，只记元数据（模型、token 数、耗时）。
- 需要时通过**事件（event）**记录，属性名随版本演进（早期 `gen_ai.content.prompt`，新版倾向 `gen_ai.input.messages` / `gen_ai.output.messages`，结构是 JSON 字符串）。

为什么默认关？三个原因：合规（PII）、体积（一条 prompt 几 KB，span 存储成本爆炸）、基数（内容不可聚合）。

## 二、Java 落地：三条路线

### 2.1 路线一：Spring AI 自带 Observation（最省事）

Spring AI 1.x 的 `ChatClient` 已经内置 Micrometer Observation，观测名是 `spring.ai.chat.client`，并且会产出 `gen_ai.*` 低基数属性。

```java
@Configuration
class ObservabilityConfig {
    @Bean
    ObservationRegistry observationRegistry(Tracer tracer, MeterRegistry meters) {
        ObservationRegistry registry = ObservationRegistry.create();
        registry.observationConfig()
                .observationHandler(new DefaultMeterObservationHandler(meters))
                .observationHandler(new TracingObservationHandler(tracer));
        return registry;
    }

    @Bean
    ChatClient chatClient(ChatClient.Builder builder, ObservationRegistry registry) {
        return builder
                .defaultSystem("You are a Java backend expert.")
                .build();
    }
}
```

注意 `ChatClient` 的 observation 需要在 builder 上启用（`observationRegistry`），否则不会产生 span。

配合 `micrometer-tracing-bridge-otel` + `opentelemetry-exporter-otlp`，Micrometer 的 span 会被桥接成 OTel span，属性名被映射成 `gen_ai.*`。**但映射不是 100%**：Spring AI 的约定版本和 OTel semconv 的版本会漂移，升级任一方都要回归验证属性名。

### 2.2 路线二：手写装饰器（可控性最好）

对 LangChain4j、或者裸 OkHttp 调 API 的场景，自己包一层最稳：

```java
public final class GenAiTracingChatModel implements ChatModel {

    private static final AttributeKey<String> OP =
            AttributeKey.stringKey("gen_ai.operation.name");
    private static final AttributeKey<String> PROVIDER =
            AttributeKey.stringKey("gen_ai.provider.name");
    private static final AttributeKey<String> REQ_MODEL =
            AttributeKey.stringKey("gen_ai.request.model");
    private static final AttributeKey<Long> IN_TOKENS =
            AttributeKey.longKey("gen_ai.usage.input_tokens");
    private static final AttributeKey<Long> OUT_TOKENS =
            AttributeKey.longKey("gen_ai.usage.output_tokens");

    private final ChatModel delegate;
    private final Tracer tracer;
    private final DoubleHistogram tokenUsage;   // gen_ai.client.token.usage

    @Override
    public Response<AiMessage> generate(List<ChatMessage> messages) {
        String model = delegate.modelName();
        Span span = tracer.spanBuilder("chat " + model)
                .setSpanKind(SpanKind.CLIENT)
                .setAttribute(OP, "chat")
                .setAttribute(PROVIDER, "openai")
                .setAttribute(REQ_MODEL, model)
                .setAttribute("gen_ai.conversation.id", ConversationContext.currentId())
                .startSpan();

        try (Scope ignored = span.makeCurrent()) {
            Response<AiMessage> resp = delegate.generate(messages);

            Usage usage = resp.tokenUsage();
            if (usage != null) {
                span.setAttribute(IN_TOKENS, (long) usage.inputTokenCount());
                span.setAttribute(OUT_TOKENS, (long) usage.outputTokenCount());
                // 指标必须记全量（不受 trace 采样影响）
                tokenUsage.record(usage.inputTokenCount(),
                        Attributes.of(OP, "chat", REQ_MODEL, model,
                                AttributeKey.stringKey("gen_ai.token.type"), "input"));
                tokenUsage.record(usage.outputTokenCount(),
                        Attributes.of(OP, "chat", REQ_MODEL, model,
                                AttributeKey.stringKey("gen_ai.token.type"), "output"));
            }
            span.setAttribute("gen_ai.response.finish_reasons",
                    List.of(resp.finishReason().name()));
            return resp;

        } catch (RateLimitException e) {
            span.setAttribute("error.type", "RateLimitExceeded");
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } catch (Exception e) {
            span.setAttribute("error.type", e.getClass().getSimpleName());
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }
}
```

**关键设计**：trace 和 metrics 的职责分开。trace 会被采样（生产通常 1%~10%），metrics 必须全量 —— 否则你的 token 账本会少 90%。这是很多人第一次接 GenAI 可观测时踩的坑：拿 trace 里的 token 数做成本报表，然后发现账单对不上。

### 2.3 路线三：OTel Java Agent 自动埋点

`opentelemetry-javaagent` 对 LLM SDK 的支持还在补齐，覆盖度和 semconv 版本都不稳定。**生产建议**：

- 基础设施层（HTTP、JDBC、Kafka）用 agent 自动埋点。
- 模型调用层用手写装饰器，别指望 agent。

混用的关键是 trace 上下文要连通：agent 已经把 `traceparent` 注入到 OkHttp 请求头，手写 span 只要 `makeCurrent()` 就会自动挂到正确父节点上。

## 三、流式响应的 span 生命周期

流式（SSE）是坑最集中的地方。

### 3.1 结束时机

```java
Span span = tracer.spanBuilder("chat " + model)
        .setSpanKind(SpanKind.CLIENT)
        .setAttribute(OP, "chat")
        .startSpan();

Flux<String> stream = chatClient.prompt(prompt).stream().content()
        .doOnNext(chunk -> { /* 不能每个 chunk 建 span */ })
        .doFinally(signal -> {
            if (signal == SignalType.CANCEL) {
                span.setAttribute("gen_ai.response.finish_reasons", List.of("cancelled"));
            }
            span.end();     // 必须覆盖 onComplete / onError / cancel 三条路径
        });
```

三个必须处理的路径：

| 路径 | 触发 | 处理 |
|---|---|---|
| `onComplete` | 正常结束 | 记录 usage（最后一个 chunk 才带） |
| `onError` | 上游 429/500/超时 | `recordException` + `error.type` |
| `cancel` | 用户关页面、超时取消 | **仍要 `span.end()`**，否则 span 泄漏 |

Reactor 里 context 传播是个额外难点：

```java
// Reactor 3.5+，让 trace context 穿透操作符链
Hooks.enableAutomaticContextPropagation();
```

不开这个，`span.makeCurrent()` 只对当前线程有效，切到 `boundedElastic` 之后新建的 span 会变成孤儿根 span。

### 3.2 不要在 chunk 上打属性

一个 2000 token 的回答可能有 400 个 SSE chunk。如果每个 chunk 都 `span.addEvent(...)`：

- span 的事件数上限默认 128，超出直接丢弃并打警告。
- 后端存储按事件计费，一条请求能顶几十条。

正确做法：chunk 只在内存里累加，结束时记一次 `output_tokens` 和 `finish_reasons`。

## 四、指标：成本与延迟的两个核心视图

语义约定定义了两个核心指标：

| 指标 | 类型 | 单位 | 关键维度 |
|---|---|---|---|
| `gen_ai.client.token.usage` | Histogram | `{token}` | `gen_ai.operation.name`、`gen_ai.request.model`、`gen_ai.token.type` |
| `gen_ai.client.operation.duration` | Histogram | `s` | `gen_ai.operation.name`、`gen_ai.request.model`、`error.type` |

为什么用 Histogram 而不是 Counter？因为需要分位数 —— "P95 单次请求消耗 3800 token" 比 "总共消耗 100 万 token" 有用得多。分位数能直接支撑容量规划。

```java
DoubleHistogram duration = meter.histogramBuilder("gen_ai.client.operation.duration")
        .setUnit("s")
        .setDescription("GenAI operation duration")
        .build();
```

**维度选择是成本控制的关键**。建议至少保留：

- `gen_ai.request.model`（模型级成本）
- `gen_ai.operation.name`（chat vs embeddings）
- 业务侧 `tenant.id`（租户成本分摊）
- `error.type`（失败重试成本）

但**不要**把 `user.id`、`conversation.id`、prompt hash 放进指标维度 —— 基数爆炸，Prometheus 会直接被打爆。

## 五、生产踩坑清单

### 5.1 semconv 还在演进，版本要锁

GenAI semconv 目前处于 `development` 状态，属性改名是常态：`gen_ai.system` → `gen_ai.provider.name`，`gen_ai.usage.prompt_tokens` → `gen_ai.usage.input_tokens`。做法：

- 在 OTel Collector 里用 `transform` processor 做**双写兼容**：同时产出新旧字段，Dashboard 渐进迁移。
- 把 semconv 版本写进 ADR，升级时跑回归用例（断言 span 上有哪些 key）。

### 5.2 内容脱敏必须在采集端做

一旦开了内容捕获，prompt 里的手机号、身份证、内部 URL 全进了 trace 后端。OTel 的 `attributes` processor 可以在 Collector 侧删字段，但**更安全的是在应用侧就不发**：

```java
// 只在明确开启且通过脱敏器时才附加内容
if (contentCaptureEnabled) {
    String sanitized = piiMasker.mask(prompt);
    span.setAttribute("gen_ai.input.messages", toJson(messages(sanitized)));
}
```

Collector 侧的兜底：

```yaml
processors:
  transform/genai_scrub:
    trace_statements:
      - context: span
        statements:
          - delete_key(attributes, "gen_ai.input.messages")
          - delete_key(attributes, "gen_ai.output.messages")
```

### 5.3 `gen_ai.response.model` 必须记

很多人只记 `gen_ai.request.model`。但供应商会在同名模型下悄悄换快照（`gpt-4o-mini` → `gpt-4o-mini-2024-07-18`），行为和质量会变。**只记请求名，等于放弃了"模型漂移"的可观测性**。这和模型版本治理是同一件事：请求名是逻辑名，响应名才是事实。

### 5.4 流式的 token 数要靠 usage，不要靠估算

自建 vLLM 时 `stream_options: {"include_usage": true}` 才会在最后一个 chunk 返回 usage。不返回时，用字符数/tokenizer 估算误差能到 20%~40%（中文、代码、JSON 差异极大）。估算值可以用来做实时预算拦截，但**账本必须是供应商返回的 usage**。

### 5.5 Baggage 别放敏感信息

用 Baggage 传 `tenant.id`、`conversation.id` 很方便，但它会随 `baggage` header **传播到所有下游**，包括第三方 API。放 token、手机号就是主动泄露。

```java
Baggage baggage = Baggage.builder()
        .put("tenant.id", tenantId)        // 只放非敏感标识
        .build();
```

## 六、一个完整的 Agent trace 长什么样

```text
invoke_agent research-agent                   12.4s  OK
  gen_ai.agent.name=research-agent
  gen_ai.conversation.id=conv-9f2a
├── chat gpt-4o-mini                           1.1s  OK
│   gen_ai.usage.input_tokens=820  output_tokens=64
├── execute_tool web_search                    3.2s  OK
│   gen_ai.tool.name=web_search
│   gen_ai.tool.call.id=call_01
│   └── chat gpt-4o-mini                       0.9s  OK     （生成检索词）
├── execute_tool fetch_page                    2.1s  ERROR
│   error.type=TimeoutException
│   └── （重试一次）
├── execute_tool fetch_page                    2.0s  OK
└── chat gpt-4o-mini                           3.0s  OK
    gen_ai.usage.input_tokens=6120  output_tokens=420
```

从这张图能直接读出三件事：

1. 最后一跳输入 6120 token —— 说明工具结果全量塞进了上下文，有压缩空间。
2. `fetch_page` 失败重试贡献了 2 秒，占总时长 16%。
3. 4 次模型调用，总 token 成本可以按模型单价直接算。

这就是"标准化"的价值：不需要为每个 Agent 写定制的埋点逻辑，Dashboard 天然通用。

## 七、面试追问

**Q：为什么模型调用要用 `CLIENT` span 而不是 `INTERNAL`？**

因为它是一次跨进程的远程调用，和 HTTP client、DB client 同类。用 `CLIENT` 才能让 APM 自动生成"服务依赖图"和"出口延迟分布"。用 `INTERNAL` 就丢掉了这层语义。

**Q：trace 采样 10%，怎么保证 token 账单准确？**

账单类数据必须走 metrics（Histogram/Counter，不采样），trace 只用于排障。两者在同一个请求里各自记录，不要互相推导。这是可观测性的基本原则：**指标回答"多少"，链路回答"为什么"**。

**Q：为什么 `gen_ai.response.finish_reasons` 是数组？**

因为一次请求可能返回多个候选（n>1），每个候选有自己的结束原因；某些 provider 还会同时给出多个原因（比如 `length` + `content_filter`）。

**Q：Agent 的工具调用要不要单独建 span？**

要。工具调用往往是耗时大头，且失败率高。单独建 span 才能算出"工具耗时占比"和"工具失败率"，这两个指标直接决定要不要给工具加缓存或超时。

## 八、落地顺序建议

1. **先接 metrics**（token + duration），成本视图立刻可见，工作量最小。
2. **再接 chat span**，按 `{operation} {model}` 命名，先不记内容。
3. **补 execute_tool / invoke_agent span**，把 Agent 链路串起来。
4. **最后开内容捕获**，且必须配脱敏 + 采样（只对错误请求全量保留）。
5. **Collector 侧做 semconv 兼容层**，避免升级打断 Dashboard。

大模型应用的排障难度比传统服务高一个量级：不确定性输出、多跳调用、外部依赖不稳定。可观测不是"上线后再补"的东西，它是唯一能让你在凌晨三点说清"到底哪一步慢、哪一步贵"的工具。
