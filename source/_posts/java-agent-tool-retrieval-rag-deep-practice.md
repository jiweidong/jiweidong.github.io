---
title: 【Java AI】Agent 工具检索深度实战：RAG over Tools、动态工具集与 Spring AI/LangChain4j 落地
date: 2026-11-18 08:30:00
tags:
  - Java
  - AI
  - Agent
  - Tool Calling
  - RAG
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Agent 工具检索深度实战

## 前言

给 LLM 接 3 个工具是 demo，接 300 个工具是工程问题。

工具一多，三件事同时崩：

1. **上下文装不下**。一个工具的完整 JSON Schema 平均 150~400 token，300 个工具就是 45k~120k token。还没开始对话，context 就满了。
2. **模型选不准**。学术界和工业界的经验都指向同一个数字：**工具数量超过 20~30 个后，选择准确率明显下降**，超过 100 个基本靠运气。相似的工具名（`get_order` / `query_order` / `fetch_order_detail`）会让模型反复横跳。
3. **成本爆炸**。每次调用都要把全部工具定义塞进 prompt，即使这次只用一个，输入 token 也照付。按 100k 输入 token、每天 10 万次调用算，光工具定义就是几十亿 token/月。

解法不是「让模型更聪明」，而是**不要让模型看到所有工具**。这就是 tool retrieval（RAG over tools）：把工具当成文档来检索，按当前用户意图召回 top-K（通常 5~8 个），只把这几个工具的定义注入 prompt。

听起来简单，做起来全是细节。这篇讲清楚四件事：工具怎么建索引、怎么召回、Java 里怎么动态注册、怎么评测。

---

## 一、RAG over tools 和文档 RAG 的差别

先说清楚它不是「把文档 RAG 换了个数据源」。

| 维度 | 文档 RAG | 工具 RAG |
|---|---|---|
| 检索单元 | chunk（几百字） | tool manifest（结构化的 name/desc/schema） |
| 索引内容 | 正文语义 | **用途 + 何时不用 + 参数语义** |
| 正确性标准 | 内容相关 | **能被正确调用**（参数可填、权限允许） |
| 检索失败后果 | 答非所问 | **调用错误工具，产生副作用** |
| 数量级 | 10⁴~10⁷ | 10²~10³（通常几百） |
| 更新频率 | 低频（文档版本） | 高频（工具上线/下线/改 schema） |
| 关键指标 | recall@k | recall@k **+ 误调用率 + 端到端成功率** |

最关键的差异在「正确性」：文档召回错了只是回答质量下降；工具召回错了可能**扣了用户的钱**。所以工具检索必须叠加**权限过滤**和**副作用分级**，不能只靠向量相似度。

---

## 二、工具清单（Tool Manifest）怎么设计

检索质量的上限由 manifest 决定。工具描述写得烂，再好的向量模型也救不回来。

### 2.1 一个合格的 manifest

```json
{
  "toolId": "order.refund.apply",
  "version": "2.3.0",
  "namespace": "order",
  "resource": "refund",
  "action": "apply",
  "displayName": "申请订单退款",
  "description": "为已支付的订单发起退款申请。仅当用户明确要求退款、且订单状态为 PAID 或 SHIPPED 时使用。不要用于查询退款进度（用 order.refund.query）或取消未支付订单（用 order.cancel）。",
  "whenNotToUse": [
    "订单未支付 → 用 order.cancel",
    "用户只是询问退款政策 → 用 kb.search",
    "退款已被拒绝且用户在申诉 → 用 order.refund.appeal"
  ],
  "synonyms": ["退钱", "退回", "refund", "返款", "撤销订单付款"],
  "sideEffect": "WRITE_IRREVERSIBLE",
  "requiredScopes": ["order:refund:write"],
  "inputSchema": { "...": "..." },
  "examples": [
    {
      "user": "我上周买的耳机不想要了，能退吗",
      "args": { "orderId": "SO20261101001", "reason": "NO_LONGER_NEEDED" }
    }
  ],
  "avgLatencyMs": 320,
  "successRate7d": 0.987
}
```

几个刻意的设计：

- **`description` 里写「不要用于什么」**。这是提升选择准确率最有效的一招。模型最容易犯的错不是「不知道用哪个」，而是「用了相似但错误的那个」。负向约束直接把这个坑填掉。
- **`synonyms` 独立字段**。用户说「退钱」，工具名是 `apply_refund`，纯向量检索可能匹配不上口语。同义词表可以直接拼进索引文本，也可以用于 BM25 召回。
- **`sideEffect` 分级**。`READ` / `WRITE_IDEMPOTENT` / `WRITE_IRREVERSIBLE`。检索阶段可以按「当前会话是否已获授权」过滤，执行阶段可以按级别决定是否要人工确认。
- **`requiredScopes`**。权限过滤必须在**召回前**做，不能召回后再过滤——否则 top-5 里有 3 个无权限，实际可用只剩 2 个。
- **`examples`**。既用于 few-shot，也用于索引（把用户原话向量化，能显著提升口语化 query 的召回）。

### 2.2 索引文本怎么拼

不要只索引 `description`。推荐结构：

```
[namespace] order / refund / apply
[name] 申请订单退款 apply_refund
[desc] 为已支付的订单发起退款申请。仅当...
[not] 订单未支付用 order.cancel；查询进度用 order.refund.query
[syn] 退钱 退回 refund 返款
[args] orderId(订单号,必填) reason(退款原因,枚举:NO_LONGER_NEEDED/DAMAGED/WRONG_ITEM) amount(金额,可选)
[ex] 用户:我上周买的耳机不想要了，能退吗
```

理由：

- 结构化前缀让 embedding 模型更容易区分「资源」和「动作」；
- 参数名和枚举值进索引，能召回「按损坏原因退款」这类带参数的意图；
- 用户原话示例能覆盖口语表达。

**不要**把整个 `inputSchema` 的 JSON 原文塞进索引——花括号和引号会稀释语义，且 token 成本高。

---

## 三、检索管线：五步

```
query → ① 意图归一 → ② 硬过滤（权限/租户/开关） → ③ 混合召回（BM25 + kNN）
      → ④ 重排（cross-encoder 或规则） → ⑤ top-K + schema 裁剪
```

### 3.1 第一步：意图归一

用户输入往往是多轮对话的产物。「那帮我退了吧」单独看毫无信息。必须先用**对话历史 + 当前 query** 合成一个 standalone query：

```java
String standalone = chatClient.prompt()
        .system("""
                将用户最后一句话改写为不依赖上下文、包含完整业务对象的检索语句。
                只输出改写结果，不要解释。若最后一句已完整则原样输出。
                """)
        .user(u -> u.text("""
                历史：
                {history}
                最后一句：{query}
                """).param("history", history).param("query", query))
        .call()
        .content();
```

例：`"那帮我退了吧"` + 历史（讨论订单 SO20261101001 的耳机）→ `"为订单 SO20261101001 的耳机申请退款"`。

这一步能把工具召回准确率提升 10~20 个百分点，成本是一次小模型调用（用最便宜的模型即可）。

### 3.2 第二步：硬过滤

在向量检索**之前**做，用结构化条件筛掉不可能的工具：

```java
public List<ToolManifest> hardFilter(String tenantId, Set<String> scopes, String channel) {
    return registry.all().stream()
            .filter(ToolManifest::enabled)
            .filter(t -> t.requiredScopes().stream().allMatch(scopes::contains))
            .filter(t -> t.tenants().isEmpty() || t.tenants().contains(tenantId))
            .filter(t -> t.channels().contains(channel))
            .toList();
}
```

这一步把候选从 300 降到 80，既省检索成本，也避免「召回了但用不了」。

### 3.3 第三步：混合召回

单靠向量不够：工具名、参数名这类**精确 token**（`orderId`、`SKU`、`refund`）用 BM25 更准；语义意图（「我不想要了」）用向量更准。

```java
public List<ScoredTool> recall(String query, List<ToolManifest> candidates, int topN) {
    // 向量召回
    float[] qv = embeddingModel.embed(query);
    List<ScoredTool> vectorHits = candidates.stream()
            .map(t -> new ScoredTool(t, cosine(qv, t.embedding())))
            .sorted(Comparator.comparingDouble(ScoredTool::score).reversed())
            .limit(topN * 2)
            .toList();

    // 关键词召回（BM25，用 Lucene 或自己实现）
    List<ScoredTool> bm25Hits = bm25Index.search(query, topN * 2);

    // RRF 融合：score = Σ 1/(k + rank)，k 取 60
    return rrfFuse(vectorHits, bm25Hits, 60).stream().limit(topN).toList();
}
```

RRF（Reciprocal Rank Fusion）的好处是**不需要分数归一化**，两路打分尺度不同也能融合：

```
RRF(d) = Σ_i 1 / (k + rank_i(d))     k = 60
```

### 3.4 第四步：重排

top-20 用 cross-encoder 重排（比如 bge-reranker），把「query + 工具描述」成对打分。这一步能把 top-5 的准确率再提 5~10 个点，代价是 20 次模型推理（本地小模型约 5~15ms）。

如果不想引入 reranker，可以用**规则加分**兜底：

```java
double boost = 0.0;
if (query.contains(t.namespace())) boost += 0.15;
if (query.matches(".*(退|取消|撤销).*") && t.action().equals("cancel")) boost += 0.2;
if (recentTools.contains(t.toolId())) boost += 0.1;   // 会话内已用过，继续用概率高
```

### 3.5 第五步：schema 裁剪

召回到 5 个工具后，还要再瘦身：

- **去掉可选参数**：只保留 required 字段 + 与当前 query 相关的可选字段（用 query 里的实体匹配参数名/描述）；
- **枚举值截断**：超过 20 个枚举值只保留前 20 + `"..."`（模型只需要知道是枚举，具体值可以在调用失败后回查）；
- **去掉 `examples`**：索引时需要，注入 prompt 时不需要（除非做 few-shot）。

实测：一个平均 300 token 的工具，裁剪后约 120~150 token。5 个工具从 1500 token 降到 700 token，省一半。

---

## 四、Java 落地：动态工具注册

### 4.1 Spring AI：自定义 `ToolCallbackResolver`

Spring AI 的 `ChatClient` 通过 `ToolCallbackResolver` 解析工具名。默认实现从 `@Tool` 注解的方法里找。我们可以实现一个**由检索结果驱动**的 resolver：

```java
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.resolution.ToolCallbackResolver;
import org.springframework.ai.tool.method.MethodToolCallback;
import org.springframework.ai.tool.definition.ToolDefinition;

@Component
public class RetrievingToolCallbackResolver implements ToolCallbackResolver {

    private final ToolRegistry registry;
    private final ToolRetriever retriever;
    private final Object toolBean;   // 实际执行方法的 Bean

    public RetrievingToolCallbackResolver(ToolRegistry registry,
                                          ToolRetriever retriever,
                                          OrderTools toolBean) {
        this.registry = registry;
        this.retriever = retriever;
        this.toolBean = toolBean;
    }

    @Override
    public ToolCallback resolve(String toolName) {
        ToolManifest m = registry.get(toolName);
        if (m == null) return null;

        Method method = ReflectionUtils.findMethod(
                toolBean.getClass(), m.methodName(), m.paramTypes());

        return MethodToolCallback.builder()
                .toolDefinition(ToolDefinition.builder()
                        .name(m.toolId())
                        .description(m.promptDescription())   // 已裁剪的描述
                        .inputSchema(m.prunedSchema())
                        .build())
                .toolMethod(method)
                .toolObject(toolBean)
                .build();
    }
}
```

配合 `ChatClient` 使用：

```java
// 1. 按用户意图检索出本次要暴露的工具
List<ToolManifest> tools = retriever.retrieve(query, tenantId, scopes, 6);

// 2. 只把 toolId 传给模型（Spring AI 通过 resolver 解析成完整定义）
ChatResponse resp = chatClient.prompt()
        .system(systemPrompt)
        .user(query)
        .toolNames(tools.stream().map(ToolManifest::toolId).toArray(String[]::new))
        .call()
        .chatResponse();
```

这里有个**关键取舍**：`toolNames()` 只接受名字，Spring AI 内部仍会调用 resolver 拿完整定义。所以我们能在 resolver 里做二次裁剪（比如根据会话状态动态去掉某些参数），而不用改 prompt。

### 4.2 LangChain4j：动态 `ToolProvider`

LangChain4j 的 `ToolProvider` 接口更直接：

```java
import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.service.tool.ToolExecutor;
import dev.langchain4j.service.tool.ToolProvider;
import dev.langchain4j.service.tool.ToolProviderResult;

public class RetrievingToolProvider implements ToolProvider {

    private final ToolRegistry registry;
    private final ToolRetriever retriever;

    @Override
    public ToolProviderResult provideTools(ToolProviderRequest request) {
        String query = request.userMessage().singleText();
        List<ToolManifest> selected = retriever.retrieve(query, 6);

        ToolProviderResult.Builder builder = ToolProviderResult.builder();
        for (ToolManifest m : selected) {
            ToolSpecification spec = ToolSpecification.builder()
                    .name(m.toolId())
                    .description(m.promptDescription())
                    .parameters(JsonSchemaMapper.toSpec(m.prunedSchema()))
                    .build();

            ToolExecutor executor = (toolExecutionRequest, memoryId) -> {
                // 统一入口：鉴权、审计、限流、超时、结果截断
                return toolGateway.invoke(m, toolExecutionRequest.arguments());
            };
            builder.add(spec, executor);
        }
        return builder.build();
    }
}
```

`retrieve()` 每次请求都会跑一遍，所以**必须有缓存**：同一个 `(tenantId, queryHash)` 在 5 分钟内复用检索结果。

### 4.3 统一工具网关：别让工具直接执行业务方法

无论用哪个框架，都建议在工具和业务之间加一层 `ToolGateway`，做五件事：

```java
public String invoke(ToolManifest m, String rawArgs) {
    // 1. 参数校验（JSON Schema + 业务规则）
    JsonNode args = schemaValidator.validate(m.inputSchema(), rawArgs);

    // 2. 幂等（写操作必须有幂等键）
    String idemKey = m.toolId() + ":" + args.path("idempotencyKey").asText();
    if (m.sideEffect() != READ && !idempotency.tryAcquire(idemKey)) {
        return "DUPLICATE_REQUEST";
    }

    // 3. 超时 + 熔断
    return circuitBreaker.executeSupplier(() ->
            TimeLimiter.callWithTimeout(() -> doInvoke(m, args), m.timeoutMs()));

    // 4. 结果截断（防止 10 万字符的 JSON 直接进上下文）
    // 5. 审计日志（谁、在哪个会话、调了什么、结果多大）
}
```

**结果截断非常关键**。工具返回一个 500 行的 JSON，直接塞进 context 会瞬间吃掉几万 token，还可能导致后续推理质量下降。推荐：结构化结果保留前 N 条 + 总数 + 「已截断」标记；或让模型用分页参数再取。

---

## 五、别破坏 Prompt Cache

这一点很多人踩坑。主流模型厂商的 prompt caching 是**按前缀精确匹配**的。工具定义通常在 system prompt 里，如果每次请求的工具集不同（顺序不同、内容不同），**缓存全部失效**，成本直接翻倍。

三条规则：

1. **工具定义按 `toolId` 字典序排列**，不要按检索分数排。分数每次不同，顺序一变缓存就废。
2. **工具集要稳定**。检索结果在 top-5 边界上抖动（第 5 名和第 6 名分数接近）会导致工具集频繁变化。加一个「分数差阈值」：如果第 5 和第 6 的分差 < 0.02，取更常用的那个（按 7 日调用量）。
3. **工具定义放在 system prompt 最前面**，业务 prompt 放后面。缓存按前缀匹配，稳定的部分要放前面。

```java
// 稳定的序列化：按 toolId 排序 + 固定字段顺序
String toolBlock = selected.stream()
        .sorted(Comparator.comparing(ToolManifest::toolId))
        .map(this::toStableJson)
        .collect(Collectors.joining("\n"));
```

---

## 六、评测：怎么知道检索好不好

工具检索的评测分三层，缺一层就会「上线才知道错」。

### 6.1 检索层：recall@k

构造黄金集：`(query, 正确 toolId)`。指标：

```
recall@5 = top-5 中包含正确工具的比例
MRR      = 1/rank(正确工具) 的均值
```

黄金集怎么来：从线上真实会话里采样 500~1000 条，人工标注。**必须包含「不该调用任何工具」的样本**（纯闲聊、知识问答），否则会训练出一个「什么都要调工具」的 Agent。

### 6.2 调用层：参数正确率

召回了正确工具，不代表能正确调用。参数错误率往往比工具选择错误率更高：

| 错误类型 | 例子 | 检测方式 |
|---|---|---|
| 必填参数缺失 | 没传 `orderId` | Schema 校验 |
| 枚举值瞎编 | `reason: "不想要了"` 而枚举是 `NO_LONGER_NEEDED` | Schema 校验 |
| 类型错误 | 金额传了字符串 | Schema 校验 |
| 实体错误 | orderId 用了别的订单号 | 与对话历史比对 |

前三种可以在 `ToolGateway` 里拦截并**把错误信息回灌给模型重试**（通常 1 次重试能修复 80%）。第四种只能靠端到端评测发现。

### 6.3 端到端：任务成功率

最终指标只有一个：**用户的任务完成了吗**。

```
任务成功率 = 成功完成的任务数 / 总任务数
误调用率   = 调用了错误工具的任务数 / 总任务数
平均轮次   = 完成任务所需对话轮数（越少越好）
单任务成本 = 总 token 成本 / 任务数
```

做 A/B 时，工具检索的收益要在这三个指标上体现，而不是只看 recall@5。见过太多「recall 提升 15%，但任务成功率没变」的案例——因为瓶颈根本不在检索，而在工具本身设计得烂。

---

## 七、五个生产级踩坑

**坑 1：相似工具互相抢**

`order.query`（查订单列表）和 `order.detail`（查订单详情）描述都写「查询订单」，向量几乎一样。模型随机选，选错就返回结构不对。

解法：在 description 里写清**输入差异**。「查列表：按用户/时间范围，返回摘要；查详情：必须传 orderId，返回完整字段」。必要时直接合并成一个工具，用参数区分。

**坑 2：工具集漂移导致多轮对话崩**

第一轮召回了 `refund.apply`，第二轮用户说「确认」，检索结果里没了这个工具，模型就不知道该调什么。

解法：**会话级工具集固定**。首轮检索出工具集后缓存到 session（TTL 30 分钟），后续轮次只做增量补充（允许新增，不允许删除）。除非用户明确切换话题。

**坑 3：召回全是无权限工具**

权限过滤放在召回后，top-5 里有 4 个没权限，实际只暴露 1 个，模型没有选择空间。

解法：过滤前置（见 3.2），并且如果过滤后候选 < 5 个，**补充「通用工具」**（`kb.search`、`human.handoff`）保证有兜底。

**坑 4：工具描述里塞了内部实现细节**

写「调用 order-service 的 /api/v2/refund 接口，需要传 X-Internal-Token」。模型会把内部信息复述给用户，还可能编造 token。

解法：description 只写「做什么、什么时候用、参数含义」，不写实现。内部细节放 `whenNotToUse` 之外的元数据字段，不注入 prompt。

**坑 5：检索服务挂了，整个 Agent 挂**

embedding 服务超时 → 检索返回空 → 模型没有任何工具 → 答非所问。

解法：**降级到关键词检索**（BM25 索引在本地，不依赖外部服务），再降级到「固定高频工具集」（按 7 日调用量 top-20）。三层降级保证可用性。

```java
public List<ToolManifest> retrieveWithFallback(String q, int k) {
    try {
        return hybridRetrieve(q, k);
    } catch (Exception e) {
        log.warn("vector retrieve failed, fallback to bm25", e);
        try {
            return bm25Retrieve(q, k);
        } catch (Exception e2) {
            log.error("bm25 failed, fallback to hot tools", e2);
            return registry.hotTools(k);
        }
    }
}
```

---

## 八、面试追问

**Q1：为什么不直接把所有工具都给模型，让它自己选？**

三个硬约束：context 长度（300 工具 ≈ 100k token）、选择准确率（>30 个工具显著下降）、成本（每次调用都付工具定义的输入 token）。工具检索本质是**用一次便宜的检索换掉昂贵的全量注入**，同时提升准确率。

**Q2：工具检索用向量还是 BM25？**

都要。工具名/参数名是精确 token，BM25 强；用户口语意图是语义，向量强。用 RRF 融合，不需要调权重。实测混合比单路 recall@5 高 10~15 个点。

**Q3：怎么防止模型调用有副作用的工具？**

三层：检索时按 `sideEffect` 和权限过滤；执行前要求显式确认（`WRITE_IRREVERSIBLE` 级别必须人工确认）；执行时用幂等键防重复。不能只靠 prompt 里写「不要随便退款」——模型不会遵守。

**Q4：工具数量增长到几千个怎么办？**

两级索引：先按 `namespace` 做粗分类（order/user/payment/kb），用一个小分类模型或规则把 query 路由到 1~2 个 namespace，再在 namespace 内做细粒度检索。避免在几千个工具上做全量 kNN（延迟和噪声都不可接受）。

**Q5：怎么评估「不该调用工具」的场景？**

黄金集里必须有 20%~30% 的 negative 样本（纯知识问答、闲聊、超出能力范围的请求）。指标用**误调用率**（不该调用却调用了）。很多 Agent 上线后疯狂调工具、把简单问题搞复杂，就是没做这项评测。

---

## 九、小结

- 工具超过 20~30 个，就必须做检索。全量注入是 demo 做法，生产会同时撞上 context、准确率、成本三堵墙。
- manifest 是检索质量的上限。`description` 要写「何时不用」，要有 `synonyms`，要有 `sideEffect` 和 `requiredScopes`。
- 管线五步：意图归一 → 硬过滤 → 混合召回（BM25 + kNN + RRF）→ 重排 → schema 裁剪。每一步都有明确的收益，别跳。
- Java 落地用 `ToolCallbackResolver`（Spring AI）或 `ToolProvider`（LangChain4j），外面套一层 `ToolGateway` 做鉴权、幂等、超时、截断、审计。
- 工具集要**稳定且有序**，否则 prompt cache 全废，成本翻倍。
- 评测三层：recall@k、参数正确率、端到端任务成功率。只看第一层会自欺欺人。

工具检索是 Agent 从「能演示」到「能上生产」的分水岭。做完这一步，你才会真正理解为什么工业界的 Agent 平台都在强调「工具治理」而不是「工具数量」。
