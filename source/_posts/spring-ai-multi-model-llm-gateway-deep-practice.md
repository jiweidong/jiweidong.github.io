---
title: 【Java AI】Spring AI 多模型接入与 LLM 网关实战：路由、降级与配额
date: 2026-10-22 08:40:00
tags:
  - Java
  - AI
  - Spring AI
  - LLM 网关
  - 多模型
  - 高可用
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Spring AI 多模型接入与 LLM 网关实战：路由、降级与配额

## 前言

只要你把大模型接进生产，三个月内一定会遇到这三个问题：

1. **单一供应商不可靠**——某天 OpenAI 429 限流、Anthropic 区域故障、国产模型突然变慢，你的核心功能直接挂掉；
2. **成本失控**——一个功能用 GPT-4 级别模型跑，账单出来才发现单次调用 0.3 元，日活 1 万就是 3000 块；
3. **无法治理**——哪个业务线用了多少 token？谁在偷偷跑大 prompt？超时率多少？没有任何可观测数据。

解决路径是同一个：**在业务和厂商 SDK 之间加一层 LLM 网关**。它做四件事——**统一抽象、智能路由、故障降级、配额计量**。

本文用 Spring AI 落地这套网关，代码可直接改造进项目。这不是"调通 API"级别的教程，而是生产级治理方案。

---

## 一、为什么 Spring AI 是合适的底座

### 1.1 它已经帮你解决了"统一抽象"

Spring AI 的核心接口只有几个：

```java
public interface ChatModel extends Model<Prompt, ChatResponse>, StreamingChatModel {
    default String call(String message) { ... }
    ChatResponse call(Prompt prompt);
    default Flux<String> stream(String message) { ... }
    Flux<ChatResponse> stream(Prompt prompt);
}
```

- `ChatModel`：同步调用
- `StreamingChatModel`：流式（`Flux<ChatResponse>`）
- `EmbeddingModel`：向量化
- `ImageModel` / `SpeechModel` / `ModerationModel`
- **`ChatClient`**：高层门面，链式 API + Advisor 链（记忆、RAG、日志、护栏都挂在这里）

关键是：**OpenAI、Anthropic、Azure OpenAI、Ollama、DashScope（Spring AI Alibaba）、智谱、DeepSeek 都实现了同一套 `ChatModel`**。这意味着你的路由层可以面向接口编程，不需要为每个厂商写适配器。

### 1.2 依赖

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-openai-spring-boot-starter</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-anthropic-spring-boot-starter</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-ollama-spring-boot-starter</artifactId>
</dependency>
<!-- 国产模型：Spring AI Alibaba（DashScope / 通义千问） -->
<dependency>
    <groupId>com.alibaba.cloud.ai</groupId>
    <artifactId>spring-ai-alibaba-starter</artifactId>
</dependency>
```

> 版本提醒：Spring AI 1.0 GA 之后 `spring-ai-bom` 统一管理版本，务必用 BOM，别逐个指定，否则 `ChatClient` API 会因版本错配编译失败。

### 1.3 多模型 Bean 的注册方式

```yaml
spring:
  ai:
    openai:
      api-key: ${OPENAI_KEY}
      chat:
        options:
          model: gpt-4o-mini
          temperature: 0.3
    anthropic:
      api-key: ${ANTHROPIC_KEY}
      chat:
        options:
          model: claude-3-5-sonnet-latest
          max-tokens: 4096
    ollama:
      base-url: http://localhost:11434
      chat:
        options:
          model: qwen2.5:7b
```

Boot 会为每个 starter 注册一个 `ChatModel` Bean。多 Bean 时注入必须限定名字：

```java
@Service
public class ModelRegistry {

    private final Map<String, ChatModel> models;

    // 按 Bean 名收集，key 即 beanName
    public ModelRegistry(Map<String, ChatModel> models) {
        this.models = models;
    }

    public ChatModel get(String beanName) {
        ChatModel model = models.get(beanName);
        if (model == null) throw new IllegalArgumentException("未注册的模型: " + beanName);
        return model;
    }
}
```

---

## 二、网关核心设计

### 2.1 分层架构

```
业务代码
   ↓ 只依赖 LlmGateway 接口
┌──────────────────────────────────────────┐
│ LlmGateway                               │
│  ├─ QuotaGuard      配额 / 预算校验       │
│  ├─ Router          模型选择（策略链）     │
│  ├─ Retry/Fallback  重试 + 降级            │
│  ├─ RateLimiter     限流（Resilience4j）   │
│  ├─ Metrics/Trace   token 记账 + 链路       │
│  └─ Guardrail       输入输出护栏            │
└──────────────────────────────────────────┘
   ↓ 面向 ChatModel 接口
ChatModel(openai) │ ChatModel(anthropic) │ ChatModel(ollama)
```

### 2.2 模型元数据：路由的决策依据

路由不能靠 if-else 堆砌，要先把模型"能力/成本/延迟"数据化：

```java
public record ModelSpec(
        String name,              // 逻辑名，如 "fast"、"smart"、"local"
        String provider,          // openai / anthropic / ollama
        String beanName,          // Spring Bean 名
        int contextWindow,        // 上下文窗口
        BigDecimal inputPrice,    // 元 / 1K tokens
        BigDecimal outputPrice,
        Set<Capability> caps,     // CHAT, VISION, TOOL, JSON_MODE, LONG_CONTEXT
        int tier                  // 1=便宜快, 2=均衡, 3=最强
) {
    public enum Capability { CHAT, VISION, TOOL_CALLING, JSON_MODE, LONG_CONTEXT, REASONING }
}
```

```java
@Configuration
public class ModelSpecConfig {

    @Bean
    public Map<String, ModelSpec> modelSpecs() {
        return Map.of(
            "fast", new ModelSpec("fast", "openai", "openAiChatModel", 128_000,
                    new BigDecimal("0.001"), new BigDecimal("0.004"),
                    Set.of(CHAT, TOOL_CALLING, JSON_MODE), 1),
            "smart", new ModelSpec("smart", "anthropic", "anthropicChatModel", 200_000,
                    new BigDecimal("0.021"), new BigDecimal("0.105"),
                    Set.of(CHAT, VISION, TOOL_CALLING, LONG_CONTEXT), 3),
            "local", new ModelSpec("local", "ollama", "ollamaChatModel", 32_000,
                    BigDecimal.ZERO, BigDecimal.ZERO,
                    Set.of(CHAT), 0)
        );
    }
}
```

价格用 `BigDecimal`，**绝不要用 double 算钱**——浮点误差在千万次累加后会出现分位偏差，对账时说不清。

### 2.3 路由策略：策略链 + 场景标签

业务侧不该关心具体模型，只声明"我要什么"：

```java
public enum Scenario {
    CHAT_FAST,        // 客服问答、意图识别 → 便宜快
    REASONING,        // 复杂推理、代码生成 → 最强
    LONG_DOC,         // 长文档摘要 → 大上下文
    OFFLINE_BATCH,    // 离线批处理 → 本地模型
    SENSITIVE         // 敏感数据 → 必须走私有部署
}
```

```java
public interface RoutingStrategy {
    Optional<ModelSpec> select(RouteContext ctx);
    int order();
}

@Component
@Order(1)
public class SensitiveDataStrategy implements RoutingStrategy {
    @Override
    public Optional<ModelSpec> select(RouteContext ctx) {
        // 命中敏感数据 → 强制本地模型，优先级最高
        return ctx.sensitive() ? Optional.of(ctx.spec("local")) : Optional.empty();
    }
    @Override public int order() { return 1; }
}

@Component
@Order(2)
public class CapabilityStrategy implements RoutingStrategy {
    @Override
    public Optional<ModelSpec> select(RouteContext ctx) {
        // 必需能力不满足的直接排除
        return ctx.candidates().stream()
                .filter(s -> s.caps().containsAll(ctx.requiredCaps()))
                .filter(s -> s.contextWindow() >= ctx.estimatedTokens())
                .min(Comparator.comparingInt(ModelSpec::tier));
    }
    @Override public int order() { return 2; }
}

@Component
@Order(3)
public class CostCapStrategy implements RoutingStrategy {
    @Override
    public Optional<ModelSpec> select(RouteContext ctx) {
        // 预算吃紧时降级到 tier 最低的可用模型
        return ctx.budgetRemainingRatio() < 0.2
                ? ctx.candidates().stream().min(Comparator.comparingInt(ModelSpec::tier))
                : Optional.empty();
    }
    @Override public int order() { return 3; }
}
```

这种"策略链"的好处是：**新增策略不改老代码**，且优先级一目了然（`@Order` 越小越先）。比一个 500 行的 `route()` 方法可维护性高一个数量级。

### 2.4 网关主流程

```java
@Slf4j
@Service
public class LlmGateway {

    private final ModelRegistry registry;
    private final List<RoutingStrategy> strategies;
    private final QuotaService quota;
    private final TokenMeter meter;
    private final RateLimiter rateLimiter;     // Resilience4j

    public LlmGateway(ModelRegistry registry,
                      List<RoutingStrategy> strategies,
                      QuotaService quota,
                      TokenMeter meter,
                      @Qualifier("llmRateLimiter") RateLimiter rateLimiter) {
        this.registry = registry;
        this.strategies = strategies;
        this.quota = quota;
        this.meter = meter;
        this.rateLimiter = rateLimiter;
    }

    public LlmResult chat(LlmRequest request) {
        String traceId = TraceContext.currentId();

        // 1) 配额校验（先拦，别等烧完钱再报错）
        quota.assertQuota(request.tenantId(), request.estimatedTokens());

        // 2) 路由
        RouteContext ctx = RouteContext.of(request, registry.all());
        ModelSpec primary = strategies.stream()
                .map(s -> s.select(ctx))
                .flatMap(Optional::stream)
                .findFirst()
                .orElseThrow(() -> new NoAvailableModelException(request.scenario()));

        // 3) 按候选链依次尝试（主 → 备 → 兜底）
        List<ModelSpec> chain = buildFallbackChain(primary, ctx);
        RuntimeException last = null;
        for (ModelSpec spec : chain) {
            try {
                return invoke(spec, request, traceId);
            } catch (Exception e) {
                last = new IllegalStateException("模型 " + spec.name() + " 调用失败", e);
                log.warn("[{}] 模型降级: {} -> 下一个, cause={}", traceId, spec.name(), e.toString());
                meter.recordFailure(spec, e);
            }
        }
        throw last;
    }

    private LlmResult invoke(ModelSpec spec, LlmRequest req, String traceId) {
        // 4) 限流（按 provider 维度，避免把单一供应商打爆）
        RateLimiter limiter = rateLimiter; // 生产按 provider 分桶
        Supplier<LlmResult> decorated = RateLimiter.decorateSupplier(limiter,
                () -> doInvoke(spec, req, traceId));
        return Try.ofSupplier(decorated)
                .recover(throwable -> { throw new LlmUnavailableException(throwable); })
                .get();
    }

    private LlmResult doInvoke(ModelSpec spec, LlmRequest req, String traceId) {
        ChatModel model = registry.get(spec.beanName());

        ChatClient client = ChatClient.builder(model)
                .defaultSystem(req.systemPrompt())
                .build();

        long start = System.nanoTime();
        ChatResponse response = client.prompt()
                .user(req.userPrompt())
                .options(ChatOptions.builder()
                        .model(spec.name())                 // 逻辑模型名，实际由 provider 映射
                        .temperature(req.temperature())
                        .maxTokens(req.maxTokens())
                        .build())
                .call()
                .chatResponse();

        long costNs = System.nanoTime() - start;
        Usage usage = response.getMetadata().getUsage();

        // 5) 记账：token + 金额 + 延迟
        LlmResult result = new LlmResult(
                response.getResult().getOutput().getText(),
                spec.name(),
                usage.getPromptTokens(),
                usage.getCompletionTokens(),
                spec);
        meter.record(result, costNs, traceId);
        quota.consume(req.tenantId(), usage.getTotalTokens());
        return result;
    }
}
```

---

## 三、降级链设计：不是"随便换个模型"

### 3.1 降级必须在"能力等价"范围内

很多人第一版是"主模型挂了就换任意一个"，结果出现了：需要 `tool_calling` 的请求降级到不支持的本地小模型 → 工具调用静默丢失 → Agent 循环 3 次后返回错误答案。**这比直接报错更糟**。

正确的降级链构造：

```java
private List<ModelSpec> buildFallbackChain(ModelSpec primary, RouteContext ctx) {
    List<ModelSpec> chain = new ArrayList<>();
    chain.add(primary);
    // 同 tier 或更高 tier，且满足必需能力，才可作为备份
    ctx.candidates().stream()
            .filter(s -> !s.name().equals(primary.name()))
            .filter(s -> s.caps().containsAll(ctx.requiredCaps()))   // 能力必须覆盖
            .filter(s -> s.contextWindow() >= ctx.estimatedTokens())
            .sorted(Comparator.comparingInt(ModelSpec::tier))
            .forEach(chain::add);
    return chain;
}
```

### 3.2 哪些错误该降级，哪些不该

| 错误 | 是否降级 | 原因 |
|---|---|---|
| 429 限流 | ✅ 立刻降级 | 主模型短期不可用 |
| 5xx / 连接超时 | ✅ 降级 | 供应商故障 |
| `context_length_exceeded` | ✅ 降级到更大窗口 | 换成窗口更大的模型 |
| 401 / 403 鉴权失败 | ❌ 不降级，告警 | 配置错误，换模型只是掩盖问题 |
| 400 参数非法 | ❌ 不降级 | 你的代码有 bug |
| 内容审核拒绝（`content_filter`） | ❌ 不降级 | 换模型绕过审核是**合规风险** |
| 空响应 / 解析失败 | ⚠️ 重试 1 次后降级 | 可能是模型偶发抽风 |

最后一条尤其重要：**不要用降级来绕过内容安全策略**，这是审计红线。

### 3.3 超时与重试参数

```java
@Bean
public Retry llmRetry() {
    return Retry.custom()
            .maxAttempts(2)
            .waitDuration(Duration.ofMillis(300))
            .retryExceptions(TimeoutException.class, WebClientRequestException.class)
            .ignoreExceptions(AuthenticationException.class, IllegalArgumentException.class)
            .build();
}

@Bean
public TimeLimiter llmTimeLimiter() {
    return TimeLimiter.of(Duration.ofSeconds(30));  // 非流式
}
```

**流式的超时策略完全不同**：首 token 超时（TTFT）和整体超时是两回事。SSE 场景应该用 `Flux.timeout(Duration, item -> ...)` 控制**相邻 token 间隔**，而不是整体超时——否则一个长回答必然超时。

```java
public Flux<String> stream(LlmRequest req) {
    return client.prompt().user(req.userPrompt()).stream().content()
            .timeout(Duration.ofSeconds(15), Flux.error(new LlmTimeoutException("token 间隔超时")))
            .onErrorResume(e -> Flux.just("（生成中断，请重试）"));
}
```

---

## 四、配额与成本治理

### 4.1 三级配额模型

| 层级 | 维度 | 实现 | 作用 |
|---|---|---|---|
| L1 租户日配额 | 租户/天 | Redis `INCRBY` + TTL 到次日 0 点 | 防单租户刷爆 |
| L2 接口级限流 | 接口/QPS | Resilience4j `RateLimiter` | 防热点接口打爆供应商 |
| L3 全局预算熔断 | 总金额/天 | Redis 金额计数 + 阈值告警 | 最后一道闸门 |

```java
@Service
public class QuotaService {

    private final StringRedisTemplate redis;

    public void assertQuota(String tenantId, int estimatedTokens) {
        // 提前预占，避免并发超发
        String key = "llm:quota:" + tenantId + ":" + LocalDate.now();
        Long used = redis.opsForValue().increment(key, estimatedTokens);
        if (used != null && used == estimatedTokens) {
            redis.expire(key, Duration.ofDays(1));
        }
        long limit = tenantLimit(tenantId);
        if (used != null && used > limit) {
            // 超了要回滚预占，否则会持续累加导致永远超限
            redis.opsForValue().decrement(key, estimatedTokens);
            throw new QuotaExceededException(tenantId, used, limit);
        }
    }

    public void consume(String tenantId, int actualTokens) {
        // 预占 vs 实际 的差额修正
        String key = "llm:quota:" + tenantId + ":" + LocalDate.now();
        long delta = (long) actualTokens - estimateOf(actualTokens);
        if (delta != 0) redis.opsForValue().increment(key, delta);
    }
}
```

> 这里有个必须处理的细节：**预占 + 实际结算的差额修正**。很多实现只做"预占"，导致预估值偏大时配额被白白吃掉；只做"事后记账"则挡不住并发超发。

### 4.2 Token 估算：不调 API 也能算个大概

在调模型前就要估算 token（用于配额和路由），常用经验值：

- 英文：约 **1 token ≈ 4 字符**
- 中文：约 **1 token ≈ 1.5 个汉字**（不同 tokenizer 差异较大）
- 代码：比自然语言更"碎"，约 **1 token ≈ 3 字符**

生产建议直接用 tokenizer 库（`jtokkit` 是纯 Java 实现，支持 cl100k_base / o200k_base），误差可控制在 2% 内：

```java
EncodingRegistry registry = Encodings.newDefaultEncodingRegistry();
Encoding enc = registry.getEncoding(EncodingType.CL100K_BASE);
int tokens = enc.countTokens(text);
```

### 4.3 成本归因：让账单能拆到业务线

```java
public void record(LlmResult r, long costNs, String traceId) {
    BigDecimal cost = r.spec().inputPrice()
            .multiply(BigDecimal.valueOf(r.promptTokens()))
            .add(r.spec().outputPrice().multiply(BigDecimal.valueOf(r.completionTokens())))
            .divide(BigDecimal.valueOf(1000), 6, RoundingMode.HALF_UP);

    // Micrometer 打点，维度不要太多（高基数会打爆 Prometheus）
    Counter.builder("llm.tokens")
            .tag("model", r.model())
            .tag("type", "prompt")
            .register(meterRegistry).increment(r.promptTokens());
    DistributionSummary.builder("llm.cost.micros")
            .tag("model", r.model())
            .register(meterRegistry).record(cost.movePointRight(6).longValue());
    Timer.builder("llm.latency").tag("model", r.model())
            .register(meterRegistry).record(costNs, TimeUnit.NANOSECONDS);
}
```

**高基数陷阱**：别把 `tenantId`、`userId`、`traceId` 做成 metric tag，几万个租户直接把 Prometheus 内存打爆。这些维度应该进**日志/链路追踪**，指标只保留 `model`、`scenario`、`status` 这类低基数标签。

---

## 五、踩坑清单

**坑 1：`ChatClient` 每次都 new。**
`ChatClient.builder(model).build()` 有构建开销，且每次新建 Advisor 链会导致记忆/缓存失效。正确做法：**启动时为每个模型预构建单例 `ChatClient`**，通过 `client.mutate()` 派生带不同 system prompt 的实例。

**坑 2：流式 + 降级 = 用户看到两段回答。**
一旦开始向客户端推送 token，就不能再降级（HTTP 200 已发出）。流式场景的降级必须发生在**首 token 之前**：先探测（短超时拿第一个 token），拿到后再持续推流。

**坑 3：`temperature` 之类参数被 provider 静默忽略。**
不同厂商对 `top_p`、`presence_penalty`、`seed` 的支持差异很大，有些直接忽略不报错。跨模型路由时，**只依赖所有 provider 都支持的公共参数**（`temperature`、`max_tokens`），其余用厂商标配。

**坑 4：重试导致重复计费。**
429 后重试是正常策略，但注意：**请求已经到达供应商并被计费、只是响应超时**的情况，重试会双倍扣费。对成本敏感的场景，重试要配合幂等键（部分厂商支持 `idempotency-key`）。

**坑 5：`model` 参数与 Bean 的模型不一致。**
`ChatOptions.builder().model("gpt-4o")` 是**请求级覆盖**，但 Bean 是用 `gpt-4o-mini` 初始化的（部分 starter 会复用一个 HttpClient 和 endpoint 配置）。混用会出现"以为在用 A，实际在按 B 的 endpoint 请求"的诡异 404。规范做法：**一个逻辑模型对应一个 Bean**，请求级不覆盖 `model`。

**坑 6：本地模型（Ollama）拖垮网关。**
7B 模型在 8C16G 上单请求可能跑 3~10 秒，如果没有独立线程池，会把整个网关的 Tomcat 线程占满。**必须给本地模型单独的信号量限流**（并发 2~4），并用虚拟线程或独立 `ExecutorService` 隔离。

```java
@Bean("localModelSemaphore")
public Semaphore localModelSemaphore() {
    return new Semaphore(2);  // 本地模型并发硬上限
}
```

---

## 六、面试高频追问

**Q1：多模型网关的核心价值是什么？**

三点：① **可用性**——单供应商故障不影响业务；② **成本**——按场景选模型，简单任务不用贵模型；③ **治理**——统一配额、计量、审计、合规出口。技术价值反而是最低的那个（统一抽象只是手段）。

**Q2：路由怎么做才不是"硬编码"？**

把模型能力数据化（`ModelSpec`），把选择逻辑抽象成策略链（`RoutingStrategy` + `@Order`），业务只声明 `Scenario`。这样新增模型/新增策略都不改调用方，符合开闭原则。

**Q3：流式场景如何做降级？**

只能在**首 token 之前**降级。做法：给首个元素设置较短超时（如 8s），超时则切换到备模型重新发起；一旦开始推流，中断只能提示"生成中断"并允许用户重试。

**Q4：如何保证不同模型输出格式一致？**

三层：① 用 `JSON Schema` 强约束（Spring AI 的 `BeanOutputConverter` 或 `responseFormat`）；② 输出后做结构校验，失败重试并降级；③ 关键字段做兜底解析（正则提取 + 默认值），别让下游拿到 `null`。

**Q5：怎么防止 prompt 把上下文窗口撑爆？**

调用前估算 token（`jtokkit`），超限时按策略处理：截断历史（保留 system + 最近 N 轮）、摘要压缩早期对话、RAG 检索只取 top-k 片段。**绝不把超长 prompt 直接发出去**——`context_length_exceeded` 是 400 错误，重试无意义。

**Q6：为什么不能用 double 算成本？**

浮点二进制无法精确表示 0.001 这类十进制小数，千万次累加后误差可达数元，对账时会出现"账单和流水差几毛钱"却查不出原因。金额一律 `BigDecimal`，且明确 `scale` 与 `RoundingMode`。

---

## 七、总结

把 LLM 网关浓缩成一张设计卡：

| 能力 | 实现要点 | 关键坑 |
|---|---|---|
| 统一抽象 | Spring AI `ChatModel` / `ChatClient` | 预构建单例，别每次 new |
| 路由 | `ModelSpec` 数据化 + 策略链 | 能力必须覆盖，本地模型要隔离 |
| 降级 | 按错误类型分级 + 能力等价链 | 流式只能在首 token 前降级 |
| 限流 | Resilience4j + provider 分桶 | 本地模型单独信号量 |
| 配额 | 预占 + 结算差额修正 | 并发超发、预占不回滚 |
| 计量 | tokenizer 估算 + 实际 usage 记账 | 高基数标签打爆 Prometheus |
| 安全 | 内容审核不降级、敏感数据走私有 | 别用降级绕过审核 |

最后一句：**网关的复杂度不在"调用哪个模型"，而在"出错时怎么办"**。把降级边界、配额修正、流式中断这三件事想清楚，你的 AI 应用才算能上生产。剩下的，交给 Spring AI 就好。
