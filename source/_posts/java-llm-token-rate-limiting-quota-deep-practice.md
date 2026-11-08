---
title: 【Java AI】按 Token 计量的 LLM 限流与配额深度实战：RPM/TPM 双维、预扣结算与 429 治理
date: 2026-11-08 08:15:00
tags:
  - Java
  - AI
  - 大模型
  - 限流
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】按 Token 计量的 LLM 限流与配额深度实战：RPM/TPM 双维、预扣结算与 429 治理

## 前言

把 LLM 接进 Java 服务的第一版限流，几乎所有人都会这么写：

```java
@RateLimiter(name = "llm", fallbackMethod = "fallback")   // 每秒 50 次
public String chat(String prompt) { return chatClient.prompt(prompt).call().content(); }
```

然后上线第二天就出事了：

- 有人上传了一份 20 万字的 PDF 做摘要，**一次请求吃掉 30 万 token**，直接把整分钟的 TPM 配额打满；
- 同一时刻，所有正常用户的请求全部 429；
- 重试风暴把 429 放大成 4290；
- 财务在月度账单上看到一个"没人预料到"的数字。

根因很简单：**LLM 的"请求成本"差异是 1000 倍级别的，而 QPS 限流假设每次请求成本相同。**

这篇讲清楚：为什么必须按 token 限流、请求前怎么估、流式响应怎么结算、多租户怎么做到公平、429 怎么治。

---

## 一、QPS 限流为什么必然失效

| 维度 | 传统接口 | LLM 接口 |
|---|---|---|
| 单次成本 | 近似恒定（一次 DB 查询） | 从 50 token 到 300,000 token |
| 耗时 | 10–100ms | 0.5–60s（甚至几分钟） |
| 资源占用 | 瞬时 | 长时间占用连接与上游并发 |
| 计费单位 | 请求数 | **输入 token + 输出 token（单价不同）** |
| 限流维度 | QPS / 并发 | RPM / TPM / 并发 / 每日预算 |

一个算例，说明为什么"RPM 限住了也没用"：

```
配额：RPM = 500，TPM = 200,000
正常请求：平均 400 token → 500 次 = 200,000 token，刚好用满
异常请求：单个 40,000 token 的文档摘要，50 次 = 2,000,000 token，超配额 10 倍
```

50 次请求在 RPM 500 的限流下**完全合法**，但它打满了 10 倍的 TPM。上游给你的是 429，你的用户看到的是"服务不可用"。

所以规则是：**RPM 防"打爆并发"，TPM 防"打爆成本"，两者缺一不可。**

---

## 二、四个配额维度

| 维度 | 单位 | 作用 | 实现难点 |
|---|---|---|---|
| **RPM** | 请求数/分钟 | 保护上游并发、控制 QPS 型滥用 | 简单计数 |
| **TPM** | token/分钟 | 保护成本与上游算力 | 请求前未知 token 数 |
| **并发数** | 在途请求数 | 防止长请求占满连接池 | 需在流式结束时释放 |
| **预算** | 金额/日/月 | 对齐财务，防"月底惊喜" | 需按模型单价换算 |

大厂 API 通常还会给 **RPD / TPD**（每日配额）和 **IPM**（图片/分钟）。多模态接入后，图片按"分辨率 → token"折算，这套维度会更复杂。

工程上建议：**内部统一抽象成"成本单位（cost unit）"**，token 只是其中一种计量方式：

```java
public record Usage(long inputTokens, long outputTokens, long cachedTokens) {
    public long costMicros(ModelPricing p) {   // 微美元，避免浮点
        return inputTokens  * p.inputMicrosPerToken()
             + outputTokens * p.outputMicrosPerToken()
             - cachedTokens * p.cachedDiscountMicros();
    }
}
```

这样换模型（单价差 50 倍）、加缓存折扣、加批处理折扣，都不用改限流逻辑。

---

## 三、核心难点：请求发出前，你不知道要花多少 token

这是 token 限流和 QPS 限流的本质区别。三个事实：

1. **输入 token 可以算，但只能估算**。用同款 tokenizer（Java 侧用 jtokkit 加载 `cl100k_base` / `o200k_base`）能算得比较准，但**工具调用、图片、系统提示的隐藏包装**会让实际值比估算高 5%–20%。
2. **输出 token 完全未知**，只能靠 `max_tokens` 设上限。而上限就是最坏情况。
3. **流式响应下，`usage` 往往在最后一个 chunk 才出现**（OpenAI 需要显式 `stream_options: {"include_usage": true}`；Anthropic 在 `message_delta` 事件里给 `output_tokens`），中途断开就永远拿不到准确值。

由此推出唯一可行的模型：**预扣（reserve）→ 结算（settle）→ 退还（refund）**。

```
请求进入
  ↓ 估算 reserve = promptTokens + maxTokens
  ↓ 原子扣减 TPM 桶（Redis Lua）
  ├─ 不足 → 快速失败 429 / 排队 / 降级到小模型
  ↓ 调用模型（流式）
  ↓ 结束（正常 / 异常 / 客户端断开）
  ↓ 结算 actual = usage.totalTokens（拿不到就用估算兜底）
  ↓ 退还 reserve - actual
```

关键设计原则：**预扣按最坏情况，结算按实际值，退还必须有幂等键。** 否则一次重试就会重复退还，把桶"退成负数"，配额永久失真。

---

## 四、Redis Lua：原子预扣

限流桶必须原子操作，否则并发下"检查通过"和"扣减"之间有窗口，超卖是必然的。

```lua
-- KEYS[1] = quota:{tenant}:{model}:tpm:{windowStart}
-- ARGV[1] = limit, ARGV[2] = reserve, ARGV[3] = ttlMs
local limit   = tonumber(ARGV[1])
local reserve = tonumber(ARGV[2])
local ttl     = tonumber(ARGV[3])

local used = tonumber(redis.call('GET', KEYS[1]) or '0')
if used + reserve > limit then
    return {0, limit - used}        -- 拒绝，返回剩余额度
end
local after = redis.call('INCRBY', KEYS[1], reserve)
if after == reserve then
    redis.call('PEXPIRE', KEYS[1], ttl)
end
return {1, limit - after}
```

结算脚本（退还差额，允许负数增量为负但不低于 0）：

```lua
-- KEYS[1] = 同一个桶 key
-- ARGV[1] = reserve, ARGV[2] = actual
local reserve = tonumber(ARGV[1])
local actual  = tonumber(ARGV[2])
local refund  = reserve - actual
if refund <= 0 then return 0 end
local used = tonumber(redis.call('GET', KEYS[1]) or '0')
local newVal = used - refund
if newVal < 0 then newVal = 0 end
redis.call('SET', KEYS[1], newVal, 'KEEPTTL')
return refund
```

⚠️ 三个必须注意的细节：

1. **窗口 key 里带 `windowStart`**（`now / 60000 * 60000`），这样窗口边界天然对齐，不需要额外清理；固定窗口的"边界双倍流量"问题用**双桶（当前窗口 + 上一窗口加权）**缓解，不要上 ZSET 滑动窗口——token 量级下 ZSET 的成员数量会爆炸。
2. **`SET ... KEEPTTL`** 而不是 `SETEX`，否则每次退还会重置 TTL，桶永不过期。
3. **退还必须带幂等键**（`requestId`），用 `SETNX quota:refund:{requestId} 1 EX 3600` 挡重复退还。

---

## 五、Java 落地：一个能上生产的 QuotaService

```java
@Component
public class TokenQuotaService {

    private static final DefaultRedisScript<List> RESERVE = new DefaultRedisScript<>("""
        local limit=tonumber(ARGV[1]); local reserve=tonumber(ARGV[2])
        local used=tonumber(redis.call('GET',KEYS[1]) or '0')
        if used+reserve>limit then return {0, limit-used} end
        local after=redis.call('INCRBY',KEYS[1],reserve)
        if after==reserve then redis.call('PEXPIRE',KEYS[1],ARGV[3]) end
        return {1, limit-after}
        """, List.class);

    private final StringRedisTemplate redis;
    private final TokenEstimator estimator;

    public QuotaDecision tryReserve(QuotaRequest req) {
        long windowStart = System.currentTimeMillis() / 60_000 * 60_000;
        long reserve = estimator.estimatePrompt(req.messages(), req.model())
                     + Math.max(req.maxTokens(), 256);       // 最坏情况

        List<?> r = redis.execute(RESERVE,
                List.of(bucketKey(req.tenantId(), req.model(), windowStart)),
                String.valueOf(req.tpmLimit()),
                String.valueOf(reserve),
                String.valueOf(120_000));                        // 2 分钟 TTL

        boolean ok = ((Long) r.get(0)) == 1L;
        long remaining = (Long) r.get(1);
        return new QuotaDecision(ok, remaining, ok ? 0 : retryAfterMs(windowStart));
    }
}
```

估算器（jtokkit）：

```java
@Component
public class TokenEstimator {
    private final EncodingRegistry registry = Encodings.newLazyEncodingRegistry();

    public long estimatePrompt(List<Message> messages, String model) {
        Encoding enc = registry.getEncodingForModel(model);   // cl100k / o200k
        long total = 0;
        for (Message m : messages) {
            total += enc.countTokens(m.content()) + 4;         // 每条消息约 3-4 token 结构开销
        }
        return (long) Math.ceil(total * 1.15);                 // 15% 安全余量
    }
}
```

**为什么留 15% 余量**：中文在 BPE 里平均 0.6–1 token/字（取决于模型与文本），英文约 0.25 token/字符；再加上角色标记、工具 schema、图片占位符。实测偏差通常在 5%–20%，留 15% 能把"结算超扣"控制在可接受范围。

⚠️ 别用"字符数 / 2"这类土办法——它在纯英文场景会低估 4 倍，在代码场景会低估更多（一个 `{` 就是一个 token）。

### 5.1 流式响应怎么结算

```java
Flux<String> stream = chatClient.prompt(req.toPrompt())
        .stream()
        .content();

AtomicLong emitted = new AtomicLong();
return stream
    .doOnNext(chunk -> emitted.addAndGet(estimator.estimateChunk(chunk)))
    .doFinally(signal -> {
        long actual = lastUsage.get() != null ? lastUsage.get().totalTokens()
                                              : emitted.get() + estimatePrompt;
        quotaService.settle(req.requestId(), req.reserve(), actual);   // 幂等
    });
```

`doFinally` 的三种信号（`onComplete` / `onError` / `cancel`）都要走结算——**尤其是 `cancel`**：用户关掉页面的那一刻，你的上游可能还在生成（有些 SDK 不会立刻断开），这笔钱已经花了，必须按实际计入，而不是全额退还。

### 5.2 与 Sentinel / Resilience4j 的分工

| 组件 | 适合做什么 | 不适合 |
|---|---|---|
| Sentinel `ParamFlowSlot` | 按 `tenantId` 做**请求数**热点限流 | token 计量（它按次数计数） |
| Resilience4j `RateLimiter` | 进程内 QPS 保护、熔断 | 分布式配额（无共享状态） |
| 自研 TokenQuotaService | TPM / 预算 / 多租户配额 | 高 QPS 下的纯计数场景（不如本地限流便宜） |

生产上三层叠加：**进程内 Resilience4j（挡住突发）→ 网关 Sentinel（按租户/接口）→ TokenQuotaService（按成本）**。

---

## 六、多租户公平性：两级桶

单桶会导致"一个大客户打满全局桶，所有客户一起 429"。标准解法是**两级桶 + 固定顺序**：

```
先扣租户桶（tenant:tpm），成功后扣全局桶（global:tpm）
全局桶失败 → 退还租户桶（补偿）
```

```java
public QuotaDecision tryReserve(Tenant t, long reserve) {
    var tenantDecision = reserve(t.tenantId(), t.tpmLimit(), reserve);
    if (!tenantDecision.allowed()) return tenantDecision;      // 租户自己超了
    var globalDecision = reserve("__global__", GLOBAL_TPM, reserve);
    if (!globalDecision.allowed()) {
        refund(t.tenantId(), reserve);                          // 必须补偿
        return globalDecision;
    }
    return tenantDecision;
}
```

**顺序不能反**：先全局后租户，会导致"全局扣了但租户失败"，补偿路径更复杂，且高并发下全局桶被大量无效占用。

公平性还可以再加一层**加权**：

| 租户等级 | 权重 | 效果 |
|---|---|---|
| 内部/免费 | 1 | 全局紧张时最先被限 |
| 标准付费 | 4 | 保证基本可用 |
| 企业/SLA | 16 | 预留容量 |

实现上用"每租户独立桶 + 各自配额按权重分配全局容量"，比在单个桶里做加权公平队列简单得多（真正严格公平需要 WFQ/DRR，工程收益不值得）。

---

## 七、429 治理：比限流更重要的是"不放大"

上游 429 的响应头通常带 `Retry-After`（秒）或 `x-ratelimit-reset-tokens`（如 `1.2s`、`6m0s`）。三条铁律：

1. **尊重 `Retry-After`，不要用自己的固定退避**。上游说 6 分钟，你 500ms 重试 100 次，只会把自己送进更长的封禁。
2. **加 jitter**。`sleep = base * 2^attempt + random(0, base)`，否则所有实例在同一毫秒重试，形成同步波峰。
3. **网关重试 + SDK 重试必须收敛为一处**。Spring AI / 官方 SDK 内置重试，网关再包一层，实际重试次数是乘积（3 × 3 = 9 倍放大）。

```java
RetryBackoffSpec backoff = Retry.backoff(3, Duration.ofMillis(500))
        .maxBackoff(Duration.ofSeconds(8))
        .jitter(0.5)
        .filter(e -> e instanceof WebClientResponseException.TooManyRequests)
        .onRetryExhaustedThrow((spec, sig) ->
                new LlmQuotaExceededException("upstream 429 after retries", sig.failure()));
```

再叠加一个**熔断**：连续 429 超过阈值时直接短路，返回降级结果（缓存答案 / 小模型 / 友好提示），给上游恢复时间。这里要区分两种"失败"：

- **配额型 429**（你的 TPM 超了）→ 重试无意义，应快速失败 + 排队；
- **拥塞型 429/503**（上游过载）→ 退避重试有效。

区分方法：看响应体错误码（`rate_limit_exceeded` vs `server_overloaded`）与 `Retry-After` 的大小。工程上做一个 `LlmErrorClassifier`，把上游五花八门的错误映射成三类：`RETRYABLE` / `QUOTA` / `FATAL`。

---

## 八、容量规划：算清楚你到底需要多少 TPM

```
需要的 TPM = 峰值 QPS × 平均 (输入 token + 输出 token) × 1.3（安全系数）
需要的并发 = 峰值 QPS × 平均响应时长(s)
```

举例：50 QPS、平均 1,200 token、平均响应 4 秒：

```
TPM  = 50 × 60 × 1200 × 1.3 ≈ 4,680,000
并发 = 50 × 4 = 200 个在途请求
```

注意**并发往往先成为瓶颈**：200 个在途 SSE 连接对应 200 个 Tomcat 线程（或 WebFlux 的 200 个事件循环任务），再加上重试与超时未释放的连接，容器很快打满。这也是为什么流式接口 + 虚拟线程/WebFlux 是天然组合。

---

## 九、面试高频追问

**Q1：为什么 LLM 网关不能只用 QPS 限流？**

因为请求成本方差极大（几十 token 到几十万 token），QPS 无法反映真实资源消耗与成本。必须叠加 TPM（token/分钟）与预算维度，否则少数大请求就能打满上游配额，导致全局 429。

**Q2：请求前不知道输出 token 数，怎么限流？**

预扣-结算模型：按 `promptTokens + maxTokens` 预扣最坏情况，请求结束后按实际 `usage` 结算并退还差额；流式场景在 `doFinally` 统一结算（含取消），并用幂等键防重复退还。

**Q3：流式响应中途断开，token 怎么算？**

按已生成内容估算 + 已收到的 `usage` 为准，不能全额退还。因为上游通常已经消耗了算力并计费，全额退还会让配额失真、被恶意刷。

**Q4：多租户配额怎么防"一户打满全局"？**

两级桶：先租户桶后全局桶，全局失败要补偿退还租户桶。顺序固定可避免死锁与无效占用。再加租户等级权重，给高 SLA 客户预留容量。

**Q5：收到 429 应该怎么办？**

先分类：配额型直接失败/排队，拥塞型按 `Retry-After` 退避 + jitter 重试；同时确保网关与 SDK 只有一层重试，避免乘积放大；连续 429 触发熔断并降级。

**Q6：token 估算误差怎么控制？**

用与目标模型一致的 tokenizer（Java 侧 jtokkit），按消息结构加固定开销，整体上浮 15%；同时把 `max_tokens` 作为硬上限纳入预扣，并且在结算时以服务端返回的 `usage` 为唯一真相。

---

## 十、踩坑清单

1. **只限 RPM 不限 TPM**——最典型，见开头。
2. **预扣用 `max_tokens` 但没设上限**——`max_tokens=null` 时按模型最大输出（可能 8K/16K）预扣，桶被瞬间吃光，要强制设默认上限。
3. **退还无幂等**——重试/超时补偿导致重复退还，配额越用越多。
4. **`SETEX` 重置 TTL**——桶永不过期，跨窗口累积。
5. **流式 `cancel` 不结算**——用户关页面就"免费"，被羊毛党利用。
6. **tokenizer 与模型不匹配**——用 `cl100k_base` 算 `o200k_base` 模型的 token，误差可达 30%。
7. **网关和 SDK 双重试**——429 放大 9 倍，直接把软限流打成硬故障。
8. **配额维度没带模型**——不同模型单价差几十倍，混在一个桶里，成本核算完全失真。
9. **没做"估算 vs 实际"的监控**——这是唯一能发现估算器漂移的手段，建议按模型打点 `actual/estimated` 比值分布。
10. **忘记图片/工具调用的 token**——多模态和 Function Calling 会让实际 token 远超文本估算。

---

## 十一、总结

LLM 限流的本质，是**在"不知道要花多少"的前提下做资源预留**。它和数据库连接池、线程池是同一类问题，只是计量单位从"个"变成了"token"。

三句话记住设计要点：

1. **双维限流**：RPM 管并发，TPM 管成本，预算管财务。
2. **预扣-结算-退还**：预扣按最坏情况，结算按服务端 `usage`，退还带幂等键。
3. **429 要分类**：配额型快速失败，拥塞型退避重试，重试只留一层。

做到这三点，你的 LLM 网关才算从"能跑"走到了"能扛"。
