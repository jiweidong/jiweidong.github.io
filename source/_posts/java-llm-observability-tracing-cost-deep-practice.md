---
title: 【Java AI】大模型可观测性与成本治理深度实战：Trace、Token 账本与告警
date: 2026-10-21 08:30:00
tags:
  - Java
  - AI
  - 可观测性
  - Token 成本
  - Spring AI
  - OpenTelemetry
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】大模型可观测性与成本治理深度实战

## 前言

传统后端服务的可观测性，我们花了十年才做明白：Metrics 看趋势、Logs 看细节、Traces 看链路。但把大模型接进系统之后，这三件套突然不够用了。

先看一个真实的排查场景。某天客服机器人的 P99 从 3 秒涨到 11 秒，报警响了。你打开 APM，看到一个 `POST /api/chat` 的 span，耗时 11 秒，状态 200。然后呢？**没有然后了。**

你不知道：

- 是检索慢，还是模型慢？
- 模型慢是因为输入变长了（context 从 2k 涨到 12k），还是供应商在降速？
- 这一轮调了几次工具？每次工具调用花了多久？
- 这 11 秒的请求，花了多少钱？是哪个租户、哪个功能花的？
- 是不是触发了重试，导致同一个问题被计费两次？

传统 APM 只能告诉你「这个 HTTP 接口慢」，它不知道 HTTP 里面还套着一个「LLM 调用」这个耗时又花钱的黑盒。

这一篇讲的就是怎么把大模型应用从黑盒变成白盒：**指标体系怎么定、Trace 怎么埋、Token 账本怎么记、成本怎么降、告警怎么配**。代码全部基于 Java / Spring AI / Micrometer / OpenTelemetry。

---

## 一、LLM 可观测性的四层模型

不要一上来就埋点，先把「要观测什么」分层。

| 层次 | 关注点 | 典型指标 | 主要消费者 |
|---|---|---|---|
| **L1 请求层** | 单次调用快不快 | TTFT、TPOT、E2E 延迟、错误码 | SRE / 值班 |
| **L2 链路层** | 一次业务请求经过了什么 | span 树、工具调用次数、检索命中 | 后端开发 |
| **L3 模型层** | 模型表现好不好 | token 用量、finish_reason、截断率、拒答率 | 算法 / 产品 |
| **L4 业务层** | 值不值这个钱 | 单请求成本、租户成本、缓存命中率、转化率 | 老板 / 财务 |

大多数团队只做了 L1（因为 APM 自带），L3/L4 完全空白——而这恰恰是大模型应用区别于普通服务的部分。

### 1.1 必须定义的 9 个核心指标

| 指标 | 定义 | 为什么要看 |
|---|---|---|
| **TTFT**（Time To First Token） | 请求发出 → 第一个 token 返回 | 流式体验的核心，用户感知的「快」 |
| **TPOT**（Time Per Output Token） | 首 token 之后每个 token 的平均间隔 | 反映模型吞吐，定位「越说越慢」 |
| **E2E Latency** | 请求发出 → 最后一个 token | 与 TTFT 分离，避免被长回答污染 |
| **input_tokens / output_tokens** | 输入/输出 token 数 | 成本计算的基础 |
| **cost_per_request** | 按模型单价折算的费用 | 直接对应钱 |
| **tool_call_count** | 单次请求的工具调用次数 | Agent 死循环的第一信号 |
| **finish_reason** | stop / length / tool_calls / content_filter | `length` 高 = 截断，`content_filter` 高 = 安全问题 |
| **cache_hit_rate** | 语义缓存/前缀缓存命中率 | 成本优化的直接杠杆 |
| **error_rate by code** | 429 / 5xx / 超时 / 内容审核拒绝 | 区分「供应商问题」和「我们的问题」 |

⚠️ **TTFT 和 E2E 一定要分开。** 如果只看 E2E，一个「输出 3000 字」的请求会把 P99 拉爆，掩盖真正的问题。而用户对「多久看到第一个字」的容忍度，远低于「多久看完」。

---

## 二、Trace：用 OpenTelemetry GenAI 语义约定

### 2.1 span 结构设计

一次 RAG 请求的 span 树应该是这样的：

```
POST /api/chat                          [http.server]  11.2s
├── retriever.vector_search             [db]            320ms
│   └── embedding.create                [gen_ai]         80ms
├── gen_ai.chat gpt-4o-mini             [gen_ai]        9.8s
│   ├── gen_ai.tool_call search_orders  [gen_ai]        1.1s
│   └── gen_ai.chat gpt-4o-mini (retry) [gen_ai]        2.3s  ← 重试也要可见
└── guardrail.output_check              [internal]       45ms
```

OpenTelemetry 在 2024 年发布了 **GenAI semantic conventions**，核心属性名如下（v1.27+）：

| 属性 | 示例值 |
|---|---|
| `gen_ai.system` | `openai` / `anthropic` / `dashscope` |
| `gen_ai.operation.name` | `chat` / `embeddings` / `text_completion` |
| `gen_ai.request.model` | `gpt-4o-mini` |
| `gen_ai.response.model` | `gpt-4o-mini-2024-07-18` |
| `gen_ai.usage.input_tokens` | `1523` |
| `gen_ai.usage.output_tokens` | `486` |
| `gen_ai.response.finish_reasons` | `["stop"]` |
| `gen_ai.request.temperature` | `0.7` |
| `gen_ai.request.max_tokens` | `2048` |

**不要自定义 `llm.model` 这种属性名。** 用标准语义约定的好处是：Grafana 的 GenAI 面板、Langfuse、Phoenix 这些工具可以直接消费你的 trace，不用写适配层。

⚠️ 安全红线：**prompt 和 completion 的原文默认不要进 trace**。用户输入里可能有手机号、身份证、地址。需要排查时用采样 + 脱敏 + 短期存储（比如只存 1% 采样、保留 7 天），而不是全量落盘。

### 2.2 Spring AI 的 Observation 能力

Spring AI 1.0 内置了基于 Micrometer Observation 的埋点，只要容器里有 `ObservationRegistry`，`ChatClient` 调用就会自动产生 span 和指标：

```java
@Configuration
public class ObservabilityConfig {

    @Bean
    public ObservationRegistry observationRegistry() {
        ObservationRegistry registry = ObservationRegistry.create();
        registry.observationConfig()
                .observationHandler(new DefaultMeterObservationHandler(Metrics.globalRegistry));
        return registry;
    }
}
```

```yaml
spring:
  ai:
    chat:
      client:
        observations:
          log-prompt: false          # 生产必须关，避免 PII 落日志
          log-completion: false
```

但自动埋点只覆盖「调模型」这一层，agent 的工具调用、检索、重试都需要自己埋。

### 2.3 手写一个 Token 计量 Advisor

Spring AI 1.0 的 Advisor 机制是横切关注点的最佳落点。下面这个 `TokenUsageAdvisor` 做四件事：记录 token、算成本、打租户标签、异步写账本。

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class TokenUsageAdvisor implements CallAdvisor, StreamAdvisor {

    private final MeterRegistry meterRegistry;
    private final TokenLedgerService ledgerService;
    private final ModelPriceTable priceTable;

    @Override
    public String getName() {
        return "tokenUsageAdvisor";
    }

    @Override
    public int getOrder() {
        return Ordered.LOWEST_PRECEDENCE - 100;   // 尽量靠近模型调用
    }

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain) {
        long start = System.nanoTime();
        String model = resolveModel(request);
        String tenant = TenantContext.current();

        try {
            ChatClientResponse response = chain.nextCall(request);
            record(model, tenant, response.chatResponse(), System.nanoTime() - start, null);
            return response;
        } catch (RuntimeException e) {
            record(model, tenant, null, System.nanoTime() - start, e);
            throw e;
        }
    }

    @Override
    public Flux<ChatClientResponse> adviseStream(ChatClientRequest request, StreamAdvisorChain chain) {
        long start = System.nanoTime();
        String model = resolveModel(request);
        String tenant = TenantContext.current();
        AtomicLong firstTokenAt = new AtomicLong(0);

        return chain.nextStream(request)
                .doOnNext(resp -> {
                    firstTokenAt.compareAndSet(0, System.nanoTime());
                    // 流式场景下 usage 通常在最后一个 chunk 才返回
                    if (hasUsage(resp)) {
                        record(model, tenant, resp.chatResponse(), System.nanoTime() - start, null);
                        recordTtft(model, firstTokenAt.get() - start);
                    }
                })
                .doOnError(e -> record(model, tenant, null, System.nanoTime() - start, e));
    }

    private void record(String model, String tenant, ChatResponse resp,
                        long elapsedNanos, Throwable error) {
        double seconds = elapsedNanos / 1_000_000_000.0;

        if (error != null) {
            meterRegistry.counter("gen_ai.client.errors",
                    "model", model, "error_type", error.getClass().getSimpleName()).increment();
            return;
        }

        Usage usage = resp != null && resp.getMetadata() != null
                ? resp.getMetadata().getUsage() : null;

        long in = usage != null && usage.getPromptTokens() != null ? usage.getPromptTokens() : 0;
        long out = usage != null && usage.getCompletionTokens() != null ? usage.getCompletionTokens() : 0;
        double cost = priceTable.costOf(model, in, out);

        meterRegistry.timer("gen_ai.client.latency", "model", model).record(Duration.ofNanos(elapsedNanos));
        meterRegistry.counter("gen_ai.client.tokens", "model", model, "type", "input").increment(in);
        meterRegistry.counter("gen_ai.client.tokens", "model", model, "type", "output").increment(out);
        meterRegistry.counter("gen_ai.client.cost", "model", model, "tenant", tenant).increment(cost);

        // 账本异步落库，不能阻塞主链路
        ledgerService.recordAsync(TokenRecord.builder()
                .tenant(tenant)
                .model(model)
                .inputTokens(in)
                .outputTokens(out)
                .cost(cost)
                .latencyMs((long) (seconds * 1000))
                .finishReason(finishReason(resp))
                .build());
    }

    private void recordTtft(String model, long ttftNanos) {
        if (ttftNanos > 0) {
            meterRegistry.timer("gen_ai.client.ttft", "model", model)
                    .record(Duration.ofNanos(ttftNanos));
        }
    }

    private String finishReason(ChatResponse resp) {
        if (resp == null || resp.getResults().isEmpty()) return "unknown";
        return resp.getResults().get(0).getMetadata().getFinishReason();
    }

    private boolean hasUsage(ChatClientResponse resp) {
        return resp.chatResponse() != null
                && resp.chatResponse().getMetadata() != null
                && resp.chatResponse().getMetadata().getUsage() != null;
    }

    private String resolveModel(ChatClientRequest request) {
        Object m = request.context().get(ChatClientAttributes.MODEL.getKey());
        return m != null ? m.toString() : "unknown";
    }
}
```

注册到 `ChatClient`：

```java
@Bean
public ChatClient chatClient(ChatClient.Builder builder, TokenUsageAdvisor advisor) {
    return builder
            .defaultAdvisors(advisor, new MessageChatMemoryAdvisor(chatMemory))
            .build();
}
```

> 版本提示：Spring AI 1.0 的 Advisor SPI 在 M5 → 1.0 之间有过调整（`CallAroundAdvisor` 改名 `CallAdvisor`、`ChatClientResponse` 包装等）。如果你用的是 0.8.x，接口名是 `CallAroundAdvisor` / `StreamAroundAdvisor`，方法签名也不同。升级时这块要重点看 release notes。

---

## 三、Token 账本：钱要能算到人头上

指标是给运维看的，账本是给财务和老板看的。两者的粒度完全不同。

### 3.1 账本的数据模型

```sql
CREATE TABLE llm_token_ledger (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    tenant_id     VARCHAR(64)  NOT NULL,
    user_id       VARCHAR(64),
    feature       VARCHAR(64)  NOT NULL COMMENT '功能位：chat/rag/summarize/agent',
    trace_id      VARCHAR(64),
    model         VARCHAR(64)  NOT NULL,
    input_tokens  INT          NOT NULL DEFAULT 0,
    output_tokens INT          NOT NULL DEFAULT 0,
    cost_micro    BIGINT       NOT NULL DEFAULT 0 COMMENT '成本，单位：1e-6 元，避免浮点',
    latency_ms    INT,
    finish_reason VARCHAR(32),
    created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_tenant_time (tenant_id, created_at),
    KEY idx_feature_time (feature, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

⚠️ **金额用整数存**（`BIGINT` 存微元），不要用 `DECIMAL` 累加几百万行再四舍五入。浮点误差在账单上是灾难。

### 3.2 批量写入，别一条一条 insert

LLM 调用 QPS 可能不高，但账本写入是「每次调用一行」，量大且不能拖慢主链路。

```java
@Service
@RequiredArgsConstructor
public class TokenLedgerService {

    private final JdbcTemplate jdbcTemplate;
    private final BlockingQueue<TokenRecord> queue = new LinkedBlockingQueue<>(100_000);

    @PostConstruct
    void start() {
        Thread.ofVirtual().name("token-ledger-writer").start(this::loop);
    }

    public void recordAsync(TokenRecord record) {
        if (!queue.offer(record)) {
            // 队列满：丢弃并计数，绝不阻塞业务线程
            Metrics.globalRegistry.counter("llm.ledger.dropped").increment();
        }
    }

    private void loop() {
        List<TokenRecord> batch = new ArrayList<>(500);
        while (true) {
            try {
                TokenRecord first = queue.take();
                batch.add(first);
                queue.drainTo(batch, 499);
                flush(batch);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception e) {
                log.error("flush token ledger failed, size={}", batch.size(), e);
            } finally {
                batch.clear();
            }
        }
    }

    private void flush(List<TokenRecord> batch) {
        jdbcTemplate.batchUpdate("""
            INSERT INTO llm_token_ledger
              (tenant_id, user_id, feature, trace_id, model,
               input_tokens, output_tokens, cost_micro, latency_ms, finish_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, batch, 200, (ps, r) -> {
                ps.setString(1, r.tenantId());
                ps.setString(2, r.userId());
                ps.setString(3, r.feature());
                ps.setString(4, r.traceId());
                ps.setString(5, r.model());
                ps.setInt(6, r.inputTokens());
                ps.setInt(7, r.outputTokens());
                ps.setLong(8, Math.round(r.cost() * 1_000_000));
                ps.setInt(9, r.latencyMs());
                ps.setString(10, r.finishReason());
            });
    }
}
```

### 3.3 配额与预算：在调用之前拦住

账本是事后统计，配额是事前拦截。用 Redis 做滑动窗口计数：

```java
@Component
@RequiredArgsConstructor
public class QuotaGuard {

    private final StringRedisTemplate redis;

    /**
     * @return true 表示放行
     */
    public boolean tryAcquire(String tenantId, long estimatedTokens) {
        String dayKey = "llm:quota:" + tenantId + ":" + LocalDate.now();
        Long used = redis.opsForValue().increment(dayKey, estimatedTokens);
        if (used != null && used == estimatedTokens) {
            redis.expire(dayKey, Duration.ofDays(2));
        }
        long limit = quotaOf(tenantId);
        if (used != null && used > limit) {
            // 超限：降级到小模型，而不是直接拒绝
            degradeToSmallModel(tenantId);
            return used <= limit * 2;   // 最多允许 2 倍，防止误伤
        }
        return true;
    }

    private long quotaOf(String tenantId) {
        return 5_000_000L;   // 应按租户配置读取
    }

    private void degradeToSmallModel(String tenantId) { /* 打标，供路由层读取 */ }
}
```

⚠️ 配额要用**预估 token**（prompt 长度 × 1.2 + max_tokens），不能等调用完再算——那时候钱已经花了。

---

## 四、成本优化的 7 个杠杆

按 ROI 从高到低排：

| 杠杆 | 典型降幅 | 实现成本 | 风险 |
|---|---|---|---|
| **1. 语义缓存** | 20%~40% | 中 | 缓存误命中导致答非所问 |
| **2. 模型路由（大小模型分级）** | 30%~50% | 中 | 小模型质量下降 |
| **3. Prompt 压缩 / 上下文裁剪** | 15%~30% | 低 | 丢关键信息 |
| **4. 前缀缓存（Prompt Caching）** | 10%~25% | 低 | 需供应商支持 |
| **5. 限制 `max_tokens`** | 5%~15% | 极低 | 回答被截断 |
| **6. 批处理（Batch API）** | 50%（离线场景） | 低 | 延迟高 |
| **7. 减少重试（结构化输出 + 校验前置）** | 5%~20% | 中 | 需要好的 schema 设计 |

### 4.1 语义缓存的关键：阈值不能拍脑袋

```java
public Optional<String> lookup(String prompt) {
    float[] embedding = embeddingModel.embed(prompt);
    List<VectorMatch> matches = vectorStore.search(embedding, 1);
    if (matches.isEmpty()) return Optional.empty();

    VectorMatch m = matches.get(0);
    // 阈值必须用业务数据标定，不能默认 0.8
    if (m.similarity() >= thresholdFor(currentFeature())) {
        Metrics.globalRegistry.counter("llm.cache.hit", "feature", currentFeature()).increment();
        return Optional.of(m.content());
    }
    return Optional.empty();
}
```

标定方法：取 500 条真实 query，人工标注哪些「语义等价」，画出相似度分布，取 **precision ≥ 0.95 对应的最小阈值**。客服场景通常 0.92~0.95，代码问答场景 0.96+（差一个参数就是错答案）。

### 4.2 模型路由：先规则，后模型

```java
public String route(RouteContext ctx) {
    // 规则优先，别一上来就用分类模型（多花一次钱）
    if (ctx.inputTokens() > 20_000)        return "long-context-model";
    if (ctx.needsToolCalling())            return "tool-capable-model";
    if (ctx.feature().equals("intent_classify")) return "small-model";
    if (ctx.userTier() == Tier.FREE)       return "small-model";
    return "default-model";
}
```

规则能覆盖 80% 的场景，剩下 20% 再用小模型做分类。**用大模型来决定用哪个大模型，是很常见的反模式。**

---

## 五、告警规则怎么配

大模型应用的告警，不能照搬传统服务。以下是我在几个项目里验证过的规则：

| 告警 | 表达式（PromQL 风格） | 阈值 | 级别 |
|---|---|---|---|
| 错误率突增 | `rate(gen_ai_client_errors_total[5m]) / rate(http_server_requests_total[5m])` | > 5% 持续 3m | P1 |
| 429 限流 | `rate(gen_ai_client_errors_total{error_type="RateLimit"}[5m])` | > 1/s | P2 |
| TTFT 恶化 | `histogram_quantile(0.95, gen_ai_client_ttft_seconds_bucket)` | > 2s 持续 5m | P2 |
| Token 用量异常 | `increase(gen_ai_client_tokens_total[1h])` | > 3× 7 天同期均值 | P2 |
| 单请求成本异常 | `gen_ai_client_cost_total / http_server_requests_total` | > 3× 基线 | P2 |
| 每日预算 | `sum(increase(gen_ai_client_cost_total[24h])) by (tenant)` | > 80% 预算 | P3 |
| 工具调用死循环 | `gen_ai_client_tool_calls_total / requests` | > 10 次/请求 | P1 |
| 截断率高 | `finish_reason="length"` 占比 | > 15% | P3 |

**两条经验**：

1. **成本告警要按租户维度**。总量超了往往已经晚了，单个租户暴涨才是可干预的。
2. **`finish_reason=length` 的占比是被严重低估的指标**。它高说明 `max_tokens` 设小了或者 prompt 让模型话太多，用户看到的是「回答到一半断了」。

---

## 六、五个真实踩过的坑

**坑 1：流式响应拿不到 usage。**
OpenAI 兼容接口默认不在流式 chunk 里返回 usage，必须显式传 `stream_options: {"include_usage": true}`。不传的话，你的 token 统计会全是 0，账本直接失效。Spring AI 里对应 `OpenAiChatOptions.builder().streamUsage(true)`。

**坑 2：重试导致重复计费。**
一次 429 后的重试，供应商可能已经计费（尤其是流式已经开始输出）。账本要记录**每次物理调用**，而不是每次业务请求，否则成本统计会少 30%。

**坑 3：Embedding 成本被完全忽略。**
RAG 系统里 embedding 调用量是 chat 的几十倍（每次入库、每次查询）。很多团队只统计 chat，结果账本对不上账单。**Embedding 必须单独一个 feature 维度。**

**坑 4：Trace 采样把贵的请求采丢了。**
默认 1% 采样，长尾慢请求大概率采不到。正确做法是**尾部采样（tail sampling）**：错误请求 100% 保留、P99 以上的请求 50% 保留、其余 1%。OpenTelemetry Collector 的 `tail_sampling` processor 支持。

**坑 5：把 prompt 原文打到日志里。**
`log-prompt: true` 在开发环境很方便，上线忘了关，等于把用户隐私明文写进日志文件，还可能被同步到日志平台。**这个开关必须和 `spring.profiles.active` 绑定，生产 profile 强制 false。**

---

## 七、面试高频追问

**Q1：LLM 应用的 P99 延迟很高，怎么定位？**
先拆 TTFT 和 TPOT。TTFT 高说明排队或输入太长（看 input_tokens）；TPOT 高说明输出阶段被限速（看供应商状态）。再看 span 树里检索、工具调用、重试各占多少。最后区分「我们的链路慢」和「供应商慢」——后者只能靠多供应商路由解决。

**Q2：怎么统计一次请求的成本？**
`cost = input_tokens × input_price + output_tokens × output_price`。注意三点：不同模型单价不同；缓存命中的 input token 通常打折（如 50%）；embedding 和 rerank 要单独算。金额用整数微元存储。

**Q3：Token 计数和供应商账单对不上，可能是什么原因？**
(1) 流式没开 `include_usage`；(2) 重试的请求没记账；(3) 系统 prompt / 工具定义也计费但没算进去；(4) 供应商的 tokenizer 和你本地的不一致（用 tiktoken 估算会有 5%~15% 偏差）；(5) 缓存折扣没扣。

**Q4：为什么建议用 OpenTelemetry 语义约定，而不是自定义字段？**
因为生态。Grafana、Langfuse、Arize Phoenix、Datadog 都按这套约定做解析。自定义字段意味着你要自己写 dashboard、自己做跨系统关联，而且换工具时要重做一遍。

**Q5：怎么在不影响质量的前提下把成本降一半？**
优先级：语义缓存（重复问题最多）→ 模型分级路由（80% 的请求不需要大模型）→ prompt 压缩（去掉冗余 few-shot）→ 前缀缓存。前两个通常就能到 40%~50%，且质量损失可用评测集量化。

---

## 八、总结

- 大模型的可观测性 = **传统三件套 + LLM 专属语义**。TTFT/TPOT、token、finish_reason、工具调用次数是必须有的。
- Trace 用 OpenTelemetry GenAI 语义约定，span 要覆盖检索、模型、工具、重试四段。
- 账本记录「每次物理调用」，金额用整数，异步批量落库，按租户/功能维度聚合。
- 配额要在调用前用预估值拦截，超限优先降级而不是直接拒绝。
- 成本优化的顺序是：缓存 → 路由 → 压缩 → 前缀缓存，每一步都要用评测集验证质量。
- 最容易被忽略的三个指标：`finish_reason=length` 占比、embedding 成本、重试导致的重复计费。

把大模型接进生产，真正的难点从来不是「怎么调通 API」，而是「怎么在它变慢、变贵、变傻的时候第一时间知道，并且知道是哪里出的问题」。这套东西搭起来之后，你才敢让它承接真实流量。
