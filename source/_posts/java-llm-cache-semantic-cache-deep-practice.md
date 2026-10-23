---
title: 【Java AI】大模型缓存深度实战：精确缓存、语义缓存与命中率治理
date: 2026-10-23 08:30:00
tags:
  - Java
  - AI
  - Spring AI
  - 缓存
  - 成本优化
  - 向量检索
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】大模型缓存深度实战：精确缓存、语义缓存与命中率治理

## 前言

做 AI 应用上线后，第二个账单周期通常会让人清醒一下。

一个中等规模的企业知识库问答：日活 2000，人均 15 次对话，每次对话 2.5 轮，平均输入 1800 token、输出 400 token。按某主流模型每百万 token 输入 2 元、输出 8 元粗算：

```
日 token = 2000 × 15 × 2.5 × (1800 + 400) = 165,000,000
日成本 ≈ 165 × (2 × 0.82 + 8 × 0.18) ≈ 165 × 3.08 ≈ 508 元
月成本 ≈ 1.5 万元
```

而真实流量里，**重复或近似重复的请求占比通常在 25%–60%**：

- 「怎么开发票」被 300 个人问过；
- 「你们的退款政策是什么」被换着花样问了 50 遍；
- 前端在同一秒内对同一个按钮发了两次请求；
- Agent 的同一个子步骤在重试时又算了一遍。

这些流量全都在重复买同样的 token。缓存是 AI 应用里**ROI 最高的一项优化**，没有之一。

但这套缓存和 Redis 缓存商品详情完全不是一回事：**LLM 的输出是非确定性的，输入是自然语言，等价关系是「语义等价」而不是「字节相等」**。这篇文章讲清三层缓存、精确缓存的 key 设计、语义缓存的阈值调优、Spring AI 落地代码，以及命中率治理。

---

## 一、先分层：LLM 缓存有三个完全不同的位置

很多人一上来就写「向量相似度缓存」，其实漏掉了最省钱的那一层。

| 层级 | 位置 | 命中条件 | 节省 | 可控性 |
|---|---|---|---|---|
| L1 Provider Prompt Cache | 模型厂商侧 | 请求**前缀**完全一致 | 输入 token 费用 50%–90% | 低（受厂商策略约束） |
| L2 精确缓存 | 应用侧 | 全量请求参数 hash 相等 | 100%（不调用模型） | 高 |
| L3 语义缓存 | 应用侧 | 语义相似度 ≥ 阈值 | 100%（不调用模型） | 中（有误命中风险） |

### 1.1 L1：Provider 侧前缀缓存

主流厂商都做了「相同前缀复用 KV Cache」的功能：

- 请求的前 N 个 token 与之前某次请求完全一致，就直接复用那段的注意力 KV，跳过重复 prefill；
- 命中部分通常按原价的 10%–50% 计费，且**显著降低首 token 延迟（TTFT）**。

工程上的关键动作只有一条：**把稳定内容放在最前面，把变化内容放在最后**。

```
❌ 差的结构（每次都变，永远命中不了）
[用户问题] + [系统提示词] + [知识库片段]

✅ 好的结构（前缀稳定）
[系统提示词（固定）] + [工具定义（固定）] + [知识库片段（相对稳定）] + [用户问题（变化）]
```

这条规则还有个副作用：**它和「把最相关的上下文放最后」的提示工程技巧是冲突的**。工程上要权衡——如果前缀缓存能省 50% 输入成本，通常值得把检索片段前置、问题后置，再用明确的指令告诉模型「最后一段是用户问题」。

### 1.2 L2/L3：应用侧缓存，才是本文重点

先给结论性的架构：

```
请求
 │
 ├─► L2 精确缓存（Caffeine，key = 规范化参数 hash）
 │      命中 ─► 返回（<1ms）
 │
 ├─► L3 语义缓存（向量检索 + 阈值判定）
 │      命中 ─► 返回（10–50ms）
 │
 └─► 调用 LLM ─► 写回 L2 + L3
```

`L2` 挡「完全重复」，`L3` 挡「换个说法」，`LLM` 兜底。下面逐个拆。

---

## 二、L2 精确缓存：key 设计决定成败

### 2.1 一个「少写一个字段」导致的事故

```java
// ❌ 只 hash 了 prompt
String key = DigestUtils.md5Hex(prompt);
```

后果：同一个 prompt 在 `temperature=0` 和 `temperature=1.2` 下命中同一个缓存；切换了 `model` 也命中；不同租户的知识库混在一起。上线第二天就出现了「A 公司看到 B 公司答案」的越权事故。

**正确的 key 必须包含所有影响输出的因素：**

```java
public record LlmCacheKey(
        String tenantId,        // 租户/空间，隔离的第一要素
        String model,           // 模型标识（含版本）
        double temperature,
        double topP,
        int maxTokens,
        String systemPromptHash,
        String userPromptHash,
        String toolsHash,       // 工具定义变了，输出会变
        String contextHash,     // 检索到的知识片段
        String promptVersion    // 提示词模板版本号
) {
    public String fingerprint() {
        String raw = String.join("|",
                tenantId, model,
                String.format("%.2f", temperature), String.format("%.2f", topP),
                String.valueOf(maxTokens),
                systemPromptHash, userPromptHash, toolsHash, contextHash, promptVersion);
        return DigestUtils.sha256Hex(raw);
    }
}
```

### 2.2 哪些字段必须进 key，哪些不能进

| 字段 | 是否入 key | 原因 |
|---|---|---|
| `model` | ✅ | 换模型输出必然不同 |
| `temperature` / `topP` | ✅ | 采样参数不同，分布不同 |
| `maxTokens` | ✅ | 影响截断 |
| `system prompt` | ✅ | 人格与约束变了 |
| `tools` 定义 | ✅ | 工具集变化影响工具调用决策 |
| 检索到的 context | ✅ | 这是 RAG 的核心变量 |
| `tenantId` / `userId` | ✅ | 安全隔离，**必须** |
| 时间戳 / traceId | ❌ | 会击穿缓存 |
| `requestId` | ❌ | 同上 |
| 用户昵称等展示字段 | ❌ | 与语义无关 |

**判据只有一条**：这个字段变了，模型的输出**应该**变吗？会变就入 key，不会变就别入。

### 2.3 prompt 规范化

即便是精确缓存，用户输入也常带噪声：

```java
public static String normalize(String prompt) {
    return prompt
            .strip()                              // 去首尾空白
            .replaceAll("\\s+", " ")              // 压缩连续空白
            .replaceAll("[\\u200B-\\u200D\\uFEFF]", "")  // 去零宽字符
            .toLowerCase(Locale.ROOT);            // 英文大小写归一（中文无影响）
}
```

注意 `toLowerCase` 对某些语言不安全（土耳其语 `I`），中文场景没问题，多语言场景要谨慎或跳过这一步。

### 2.4 Caffeine 落地

```java
@Configuration
public class LlmCacheConfig {

    @Bean
    public Cache<String, LlmResponse> exactLlmCache() {
        return Caffeine.newBuilder()
                .maximumWeight(200_000_000)                    // 约 200MB
                .weigher((String k, LlmResponse v) ->
                        v.content().length() * 2 + k.length() * 2 + 64)
                .expireAfterWrite(Duration.ofHours(6))         // 业务决定的新鲜度
                .expireAfterAccess(Duration.ofHours(2))        // 冷数据先淘汰
                .recordStats()                                 // 必开，用于命中率观测
                .build();
    }
}
```

**为什么用 `maximumWeight` 而不是 `maximumSize`？** 因为 LLM 响应长度差异巨大（100 字到 8000 字），按条数限制会导致内存占用不可预测（取决于命中什么）。按字节权重算才稳。

### 2.5 多实例怎么办

Caffeine 是进程内缓存，10 个 Pod 就有 10 份缓存，命中率被稀释。

| 方案 | 命中率 | 延迟 | 一致性 | 建议 |
|---|---|---|---|---|
| 纯本地 Caffeine | 低（1/N） | <1ms | 最终（各自淘汰） | 高频热点、允许不一致 |
| 纯 Redis | 高（全局） | 1–3ms | 强 | 默认选择 |
| 本地 + Redis 二级 | 最高 | <1ms（热）/ 2ms（温） | 最终 | **推荐** |
| Redis + 一致性 hash | 高 | 1–2ms | 强 | 大 key 场景 |

二级缓存的写法：

```java
public Optional<LlmResponse> get(String key) {
    LlmResponse local = localCache.getIfPresent(key);
    if (local != null) {
        metrics.counter("llm.cache.hit", "layer", "local").increment();
        return Optional.of(local);
    }
    String json = redis.opsForValue().get("llm:" + key);
    if (json != null) {
        LlmResponse remote = objectMapper.readValue(json, LlmResponse.class);
        localCache.put(key, remote);                       // 回填本地
        metrics.counter("llm.cache.hit", "layer", "redis").increment();
        return Optional.of(remote);
    }
    metrics.counter("llm.cache.miss").increment();
    return Optional.empty();
}
```

---

## 三、L3 语义缓存：真正省钱，也真正危险

精确缓存只能挡「一字不差」的重复。但用户会说：

- 「怎么开发票」
- 「发票怎么开」
- 「我要开票，流程是啥」
- 「invoice 怎么弄」（中英混输）

四条请求，精确缓存命中率 0，语义缓存命中率 100%。

### 3.1 基本流程

```
1. 请求到达 → embedding(userPrompt + context)
2. 在向量库中检索 topK=3 的「历史 (query, answer) 对」
3. 取最高相似度 s：
   - s ≥ highThreshold(0.95)  → 直接返回
   - mediumThreshold(0.88) ≤ s < highThreshold → 二次校验（可选）
   - s < mediumThreshold → 视为未命中，调用 LLM
4. 调用 LLM 后，把 (query, embedding, answer, metadata) 写入向量库
```

### 3.2 阈值是唯一的安全阀，也是最难调的部分

不同 embedding 模型的相似度分布完全不同，**没有通用阈值**。必须用真实数据标定：

| Embedding 模型 | 典型「同义」相似度 | 典型「不同义」相似度 | 建议起始阈值 |
|---|---|---|---|
| text-embedding-3-small | 0.90–0.96 | 0.60–0.85 | 0.93 |
| text-embedding-3-large | 0.88–0.95 | 0.55–0.82 | 0.91 |
| bge-m3 | 0.92–0.98 | 0.65–0.88 | 0.95 |
| 某些中文小模型 | 0.85–0.99 | 0.70–0.95 | **不可用**（分布重叠太严重） |

**标定方法**（务必做，30 分钟就能完成）：

```java
// 用 200 条真实 query 构造成对标注：同义对 100 对，非同义对 100 对
List<Double> posScores = ...;   // 同义对的相似度
List<Double> negScores = ...;   // 非同义对的相似度

// 找使 F1 最大的阈值
double best = 0, bestF1 = 0;
for (double t = 0.80; t <= 0.99; t += 0.005) {
    long tp = posScores.stream().filter(s -> s >= t).count();
    long fp = negScores.stream().filter(s -> s >= t).count();
    double precision = tp / (double) Math.max(1, tp + fp);
    double recall = tp / (double) posScores.size();
    double f1 = 2 * precision * recall / Math.max(1e-9, precision + recall);
    if (f1 > bestF1) { bestF1 = f1; best = t; }
}
log.info("最佳阈值={}, F1={}", best, bestF1);
```

**经验值**：精确率优先于召回率。因为误命中的代价（给用户错误答案、甚至泄露他人数据）远大于未命中的代价（多花一次 token）。所以阈值应该取「高精确率」那一侧，宁可少命中。

### 3.3 二次校验：用便宜模型守门

高相似度不等于答案可复用。中间地带可以用小模型做一次判定：

```java
private boolean isSameIntent(String q1, String q2) {
    String prompt = """
            判断下面两个用户问题是否在问同一件事，只回答 YES 或 NO。
            问题A：%s
            问题B：%s
            """.formatted(q1, q2);

    String r = chatClient.prompt(prompt)
            .options(ChatOptions.builder().model("small-cheap-model").temperature(0.0).build())
            .call().content();
    return "YES".equalsIgnoreCase(r == null ? "" : r.strip());
}
```

成本对比：小模型判定约 50 token，主模型回答约 2000 token。**用 2.5% 的成本换一次准确率提升，非常划算。**

### 3.4 哪些内容绝对不能进语义缓存

这是很多团队踩过的坑，列成清单：

| 类型 | 原因 |
|---|---|
| 含用户个人数据的回答（订单、账单、病历） | 语义相似 ≠ 同一用户，直接导致数据泄露 |
| 依赖实时状态的回答（库存、余额、股价） | 缓存几秒后就过期，且无法感知变更 |
| 高风险决策（风控、审批、医疗建议） | 误命中的代价不可接受 |
| 多轮对话中的指代性回答（「那它呢？」） | 脱离上下文后语义完全变了 |
| 带时间敏感指令的回答（「今天」「现在」） | 跨天复用会给出过期信息 |

**实践原则：只缓存「知识型、静态、非个性化」的回答。** 在代码里用一个显式的判定函数拦住，而不是靠调用方自觉：

```java
public boolean isCacheable(LlmRequest req) {
    if (req.containsPii()) return false;               // PII 检测
    if (req.isPersonalized()) return false;            // 带 userId 的个性化
    if (req.hasTimeSensitiveWords()) return false;     // 今天/现在/最新
    if (req.temperature() > 0.3) return false;         // 高温度本就要多样性
    return switch (req.scene()) {
        case FAQ, DOC_QA, PRODUCT_SPEC -> true;        // 白名单
        case ORDER, BILLING, RISK, MEDICAL -> false;   // 黑名单
    };
}
```

**白名单比黑名单可靠**。黑名单永远列不全。

---

## 四、Spring AI 落地：一个完整的语义缓存实现

Spring AI 提供了 `VectorStore` 抽象和 `EmbeddingModel`，可以直接拼出语义缓存。

```java
@Component
public class SemanticCache {

    private static final Logger log = LoggerFactory.getLogger(SemanticCache.class);

    private final VectorStore vectorStore;
    private final EmbeddingModel embeddingModel;
    private final Cache<String, CachedAnswer> exactCache;   // L2
    private final SemanticCacheProperties props;
    private final MeterRegistry meterRegistry;

    public SemanticCache(VectorStore vectorStore,
                         EmbeddingModel embeddingModel,
                         Cache<String, CachedAnswer> exactCache,
                         SemanticCacheProperties props,
                         MeterRegistry meterRegistry) {
        this.vectorStore = vectorStore;
        this.embeddingModel = embeddingModel;
        this.exactCache = exactCache;
        this.props = props;
        this.meterRegistry = meterRegistry;
    }

    /** 查询：先精确，再语义 */
    public Optional<CachedAnswer> lookup(LlmCacheKey key, String normalizedQuery, String tenantId) {
        // L2
        CachedAnswer local = exactCache.getIfPresent(key.fingerprint());
        if (local != null) {
            meterRegistry.counter("llm.cache.hit", "layer", "exact").increment();
            return Optional.of(local);
        }

        // L3
        SearchRequest req = SearchRequest.builder()
                .query(normalizedQuery)
                .topK(props.getTopK())                       // 3
                .similarityThreshold(props.getThreshold())   // 0.93
                .filterExpression("tenantId == '" + tenantId + "' AND scene == 'FAQ'")
                .build();

        List<Document> hits = vectorStore.similaritySearch(req);
        if (hits == null || hits.isEmpty()) {
            meterRegistry.counter("llm.cache.hit", "layer", "semantic").increment(0);
            return Optional.empty();
        }

        Document best = hits.get(0);
        double score = best.getScore() == null ? 0 : best.getScore();

        // 中间地带：二次校验
        if (score < props.getHighThreshold() && !props.isSkipVerify()) {
            String cachedQuery = best.getMetadata().get("query").toString();
            if (!isSameIntent(normalizedQuery, cachedQuery)) {
                meterRegistry.counter("llm.cache.reject", "reason", "intent_mismatch").increment();
                return Optional.empty();
            }
        }

        CachedAnswer answer = CachedAnswer.builder()
                .content(best.getText())
                .sourceQuery(best.getMetadata().get("query").toString())
                .similarity(score)
                .createdAt(Instant.parse(best.getMetadata().get("createdAt").toString()))
                .build();

        // 校验 TTL（向量库通常不支持 TTL，必须自己判）
        if (answer.createdAt().plus(props.getTtl()).isBefore(Instant.now())) {
            meterRegistry.counter("llm.cache.reject", "reason", "expired").increment();
            return Optional.empty();
        }

        meterRegistry.counter("llm.cache.hit", "layer", "semantic").increment();
        exactCache.put(key.fingerprint(), answer);
        return Optional.of(answer);
    }

    /** 写回：L2 + L3 */
    public void store(LlmCacheKey key, String query, LlmResponse response, String tenantId, String scene) {
        CachedAnswer answer = CachedAnswer.builder()
                .content(response.content())
                .sourceQuery(query)
                .similarity(1.0)
                .createdAt(Instant.now())
                .build();

        exactCache.put(key.fingerprint(), answer);

        Document doc = Document.builder()
                .text(response.content())
                .metadata(Map.of(
                        "query", query,
                        "tenantId", tenantId,
                        "scene", scene,
                        "model", key.model(),
                        "promptVersion", key.promptVersion(),
                        "createdAt", Instant.now().toString()))
                .build();
        vectorStore.add(List.of(doc));
    }
}
```

### 4.1 关键配置

```yaml
llm:
  cache:
    semantic:
      enabled: true
      top-k: 3
      threshold: 0.90          # 进入候选的最低相似度
      high-threshold: 0.95     # 高于此值直接返回，跳过二次校验
      ttl: 24h
      skip-verify: false
      max-entries: 50000       # 向量库条目上限，超了要淘汰
```

### 4.2 向量库条目膨胀怎么办

语义缓存会持续写入向量，一年后可能有几百万条，检索变慢、内存爆掉。三种治理手段：

| 手段 | 做法 | 效果 |
|---|---|---|
| TTL 过滤 | 查询时加 `createdAt > now - 24h` 过滤条件 | 简单有效，但索引仍会增长 |
| 定期清理 | 每日定时任务删除过期条目 | 控制总量 |
| 命中计数淘汰 | metadata 记 `hitCount`，定期删低频条目 | 保留高价值条目 |
| 分片 + 归档 | 按月份分 collection | 降低单集合规模 |

**推荐组合**：TTL 过滤（查询侧） + 每日定时清理（存储侧） + `hitCount` 淘汰（容量侧）。

---

## 五、命中率治理：把它当成一个可运营的指标

缓存上线不是终点，是起点。没有度量就没有优化。

### 5.1 必须埋的指标

| 指标 | 类型 | 用途 |
|---|---|---|
| `llm.cache.hit{layer}` | Counter | 分层命中率 |
| `llm.cache.reject{reason}` | Counter | 未命中原因（intent_mismatch / expired / below_threshold） |
| `llm.cache.similarity` | Histogram | 相似度分布，用于调阈值 |
| `llm.cache.size` | Gauge | 缓存条目数 |
| `llm.cache.cost_saved` | Counter | 估算省下的 token 费用 |
| `llm.cache.false_positive` | Counter | 人工反馈的误命中（关键！） |

### 5.2 命中率基准

| 场景 | 合理命中率 | 说明 |
|---|---|---|
| 客服 FAQ | 40%–65% | 问题高度重复 |
| 企业知识库问答 | 25%–45% | 有一定长尾 |
| 代码助手 | 5%–15% | 上下文太独特 |
| Agent 工具调用 | 10%–30% | 子步骤可复用 |
| 创意写作 | <5% | **不建议开缓存** |

**如果你的 FAQ 场景命中率低于 20%**，先别调阈值，去查三件事：① key 里是不是混进了时间戳/requestId；② 租户过滤是不是写错了导致跨租户查不到；③ 写入侧是不是压根没写。

### 5.3 缓存失效的三种触发

| 触发 | 场景 | 实现 |
|---|---|---|
| TTL 到期 | 通用兜底 | `expireAfterWrite` + 向量库时间过滤 |
| 版本号递增 | 提示词/模型/知识库更新 | key 里带 `promptVersion`，版本变了自然全部失效 |
| 主动清除 | 发现错误答案 | 按 `promptVersion` 或 `docId` 批量删除 |

**版本号是最好用的手段**。改提示词时把 `promptVersion` 从 `v3` 提到 `v4`，老缓存自动全部失效，不需要写任何清理逻辑。

### 5.4 灰度策略

新缓存上线不要全量开：

```java
public boolean shouldUseCache(String userId) {
    // 按用户 ID hash 分桶，先放 5% 流量
    int bucket = Math.floorMod(userId.hashCode(), 100);
    return bucket < grayPercent;    // grayPercent 从配置中心动态调整
}
```

同时对比「开缓存组」和「关缓存组」的**用户满意度/点赞率**，而不只是看成本。省了钱但答错了，是负收益。

---

## 六、成本收益测算（给老板看的表）

假设月请求 100 万次，平均输入 1800 token、输出 400 token，单价输入 2 元/M、输出 8 元/M：

| 方案 | 命中率 | 月成本 | 相对节省 | 平均延迟 |
|---|---|---|---|---|
| 无缓存 | 0% | 5,600 元 | — | 2.8s |
| 仅 L1 前缀缓存 | 60% 前缀命中（输入打 3 折） | 3,400 元 | 39% | 2.1s |
| L1 + L2 精确 | L2 25% | 2,550 元 | 54% | 1.6s |
| L1 + L2 + L3 语义 | L2 25% + L3 30% | 1,570 元 | **72%** | 1.1s |
| 上述 + 小模型路由 | 追加 15% 走小模型 | 1,150 元 | **79%** | 0.9s |

（数字为量级示意，实际取决于业务分布。）

注意最后一行的做法：**缓存挡不住的请求，先给便宜模型试，置信度低再升级到大模型**（级联/路由）。这是缓存之外的第二大降本手段。

---

## 七、生产踩坑清单

| 坑 | 现象 | 修复 |
|---|---|---|
| key 少字段 | 换模型/换租户仍命中 | key 覆盖所有影响输出的参数 |
| 缓存 PII 回答 | 用户 A 看到用户 B 的订单 | 场景白名单 + PII 检测 + 租户隔离 |
| 阈值过低 | 答案「差不多但不对」 | 提高阈值 + 二次校验 |
| 阈值过高 | 命中率 <5%，白干 | 用真实数据重新标定 |
| 向量库无限增长 | 检索从 20ms 涨到 800ms | TTL 过滤 + 定时清理 + hitCount 淘汰 |
| 缓存了实时数据 | 库存显示错误 | 实时场景禁用缓存 |
| 无版本号 | 改完提示词，老答案还在 | key 带 `promptVersion` |
| 无命中率监控 | 不知道有没有用 | 埋点 + Dashboard |
| 缓存穿透 | 恶意构造大量近似 query 打满向量库 | 请求侧限流 + query 长度/字符集校验 |
| 缓存投毒 | 攻击者构造 query 让答案被广泛复用 | 写入侧内容审核 + 只缓存审核通过的答案 |

最后两条尤其重要：**语义缓存是一个「放大器」**。好的答案被放大是好事，错的答案（甚至是注入的恶意内容）被放大就是事故。写入前必须过内容安全审核。

---

## 八、面试高频追问

**Q1：语义缓存的相似度阈值怎么定？**
答：不能用默认值，必须用真实 query 做标注集（同义对/非同义对各 100+ 条），扫描阈值区间算 P/R/F1，取精确率优先的工作点。不同 embedding 模型的分布不同，同一个阈值换模型就失效。工程上取「高精确率」侧，误命中代价远大于未命中。

**Q2：为什么语义缓存不能缓存所有回答？**
答：语义相似不等于答案可复用。含个人数据、实时状态、高风险决策、指代性多轮回答的场景，误命中会造成数据泄露或错误决策。工程上用「场景白名单」而非黑名单来控制。

**Q3：精确缓存的 key 里为什么要放 tools 定义？**
答：Function Calling 场景下，工具集决定了模型能做什么。同一个用户问题，工具集从 3 个变成 10 个，模型的选择和输出结构都会变。所以 tools 的 schema 必须参与 key 计算。

**Q4：多实例部署下本地缓存命中率被稀释，怎么解决？**
答：三种方案——① 只用 Redis（全局命中但延迟 1–3ms）；② 本地 Caffeine + Redis 二级（热数据本地、温数据 Redis，推荐）；③ 按 key 做一致性 hash 路由到固定实例（命中率高但扩缩容时要迁移）。选型取决于 QPS 与延迟预算。

**Q5：Provider 侧前缀缓存和应用侧缓存冲突吗？**
答：不冲突，是互补的。Provider 缓存省的是「同一前缀的 prefill 计算」，仍然要付部分 token 费用并产生输出；应用侧缓存直接不调用模型，成本为 0。两者叠加效果最好，但要注意前缀缓存要求「稳定内容前置」，而应用侧 key 要求「全量 hash」，二者不矛盾。

**Q6：缓存会不会导致模型「永远学不到新东西」？**
答：会，所以才需要 TTL + 版本号 + 主动清除三件套。提示词迭代、知识库更新、模型升级都必须触发缓存失效。没有失效机制的缓存不是优化，是技术债。

**Q7：为什么不用 Redis 的 `EXPIRE` 就完事了？**
答：Redis 可以用 TTL，但向量库（Milvus/Qdrant/pgvector）通常不支持按条 TTL。语义缓存的过期必须在应用层判断（metadata 里的 `createdAt`），并配合定时清理任务。这是两套不同的机制，不能混。

---

## 九、总结

| 层次 | 解决什么 | 关键动作 |
|---|---|---|
| L1 Provider 前缀缓存 | 重复 prefill | 稳定内容前置，变化内容后置 |
| L2 精确缓存 | 完全重复请求 | key 覆盖所有影响输出的参数 + 规范化 + 多级缓存 |
| L3 语义缓存 | 换个说法的重复 | 阈值标定 + 二次校验 + 场景白名单 |
| 治理 | 让它持续有效 | 命中率埋点 + 版本号失效 + 向量库清理 |

三句话收尾：

1. **缓存的收益不在「省了几次调用」，而在「省了多少钱、快了多少毫秒」，必须量化。**
2. **语义缓存的安全边界比性能更重要**——误命中一个回答，可能毁掉整个产品的信任。
3. **先把 key 设计对，再谈语义缓存。** 我见过太多团队，精确缓存的 key 里混着 `requestId`，命中率 0.3%，然后花两周调向量阈值。

对 Java 团队来说，好消息是这套东西完全可以用熟悉的技术栈落地：Caffeine 做 L1、Redis 做 L2、Spring AI 的 `VectorStore` 做 L3、Micrometer 做观测。不需要引入 Python 生态，也不需要重写技术栈。
