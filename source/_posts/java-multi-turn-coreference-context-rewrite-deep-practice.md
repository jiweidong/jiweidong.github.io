---
title: 【Java AI】多轮对话指代消解与上下文改写深度实战：把「那它呢」变成一个能检索的问题
date: 2026-11-25 08:00:00
tags:
  - Java
  - AI
  - RAG
  - 多轮对话
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】多轮对话指代消解与上下文改写深度实战

## 前言

做 RAG 和 Agent 的人都会经历这个阶段：单轮效果很好，一上多轮就崩。

用户问：「帮我看看订单 A123 的物流。」
系统答：「已发货，预计 11 月 27 日送达。」
用户接着问：「那它支持退货吗？」

第二条 query 只有 8 个字，里面有一个「它」。你把它原样丢进向量库，检索到的是「退货政策总则」，而不是「A123 所属品类（生鲜）不支持七天无理由退货」。答案听起来对，实际是错的。

这不是检索模型的问题，是**输入本身就是残缺的**。在多轮场景里，用户说的话只是「增量信息」，完整意图必须结合对话状态才能还原。

本文讲清楚三件事：

1. 多轮对话里到底有哪几类「不完整 query」，各自该怎么还原；
2. 什么条件下才值得多花一次 LLM 调用去做改写（成本与收益的边界）；
3. 用 Spring AI / LangChain4j 在 Java 里落地的完整代码，以及评测与踩坑。

---

## 一、四类「不完整」，对应四种还原策略

很多人把多轮改写等同于「把历史拼进 prompt 让模型自己理解」。这在小模型或长对话下极不稳定。更工程化的做法是先分类，再分别处理：

| 类型 | 例子 | 还原方式 | 关键风险 |
|---|---|---|---|
| 指代（anaphora） | 「它支持退货吗」「这个多少钱」 | 用对话槽位里的实体替换代词 | 多个候选实体时选错 |
| 省略（ellipsis） | 「还有呢」「换成红色的」 | 从上一轮意图模板补全谓词与宾语 | 补全出用户没说的意图 |
| 纠错/话题切换 | 「不对，我说的是 B 方案」 | 丢弃被否定的分支，重建意图 | 把旧约束当成仍然有效 |
| 相对时间/指称 | 「上周的」「最近一次」 | 锚定到会话开始时的绝对时间 | 用当前时间锚定，跨天错位 |

### 1.1 指代消解的真相：不是「理解语言」，是「选槽位」

「它」指什么，本质上是一个**在候选集合上做选择**的问题。候选来自：

- 会话槽位（session slots）：用户明确提到的实体，如 `orderId=A123`、`sku=SKU-88`；
- 上一轮的工具调用结果（如物流查询返回的 `carrier=顺丰`）；
- 上一轮助手回答中出现的实体（**最危险**，模型可能编造过实体）。

所以正确顺序是：**先维护结构化槽位，再做指代绑定，最后才渲染成自然语言 query**。把「改写」当成「文本游戏」是绝大多数错误改写的来源。

### 1.2 一个反例

```
用户：A123 到哪了？
助手：已到达杭州转运中心。
用户：那 B456 呢？
```

如果改写器只做「代词替换」，可能输出「B456 到哪了」——正确。但如果它把上一轮的「杭州转运中心」也带进去，变成「B456 是否到达杭州转运中心」，就凭空增加了约束，检索与工具调用都会跑偏。

**规则：改写只允许引入槽位中存在的实体与用户本轮明确表达的约束，不允许引入上一轮的「结论」。**

---

## 二、要不要每轮都改写？先算一笔账

每轮多一次 LLM 调用，成本与延迟都会上升。以常见的 2000 token 输入、150 token 输出、单轮 40 万次调用/天估算：

| 策略 | 额外调用占比 | 额外成本（相对） | P95 延迟增加 |
|---|---|---|---|
| 每轮改写 | 100% | +35%~45% | +300~600ms |
| 条件触发（启发式） | 25%~40% | +10%~15% | +80~250ms |
| 从改写（只在小模型低置信时） | 10%~20% | +5%~8% | +50~150ms |
| 不改写（把历史直接拼进检索 query） | 0 | 0 | 0，但召回显著下降 |

结论很明确：**默认走条件触发**，把「每轮改写」留给高价值场景（客服工单、医疗、金融）。

### 2.1 触发条件（可组合，命中任一即改写）

```java
public boolean shouldRewrite(String query, SessionState state) {
    if (query.length() <= 12) return true;                       // 短 query 大概率不完整
    if (CONTAINS_ANAPHORA.matcher(query).find()) return true;    // 它/这个/上面/那个/该
    if (query.startsWith("那") || query.startsWith("还有") || query.startsWith("换成")) return true;
    if (!state.hasAnyEntity() && !containsEntity(query)) return true;  // 没有任何实体
    if (state.lastRetrievalScore() < 0.45) return true;          // 上一轮检索就不好
    if (state.turnCount() == 1) return false;                    // 首轮不需要改写
    return false;
}
```

注意最后一条：**首轮永远不要改写**，没有历史可依据，只会增加延迟与幻觉。

---

## 三、改写的输出契约：结构化，而不是一段文本

最糟糕的设计是让模型「把问题改写得更完整」，然后直接拿返回的字符串去检索。无法校验、无法回退、无法评测。

正确做法是让模型输出结构化对象，由 Java 侧做校验与决策：

```java
public record RewriteResult(
        String standaloneQuery,        // 用于检索/工具调用的完整问句
        List<String> resolvedEntities, // 被消解的实体（带类型）
        String intent,                 // 归一化意图：order_logistics / return_policy / ...
        List<String> carriedConstraints, // 从历史继承且仍然有效的约束
        boolean needsClarification,    // 是否需要反问
        String clarificationQuestion,  // 反问话术
        double confidence,             // 0~1
        String reason                  // 改写依据，便于审计
) {}
```

关键字段的作用：

- `resolvedEntities`：让检索层可以做 **metadata 过滤**（例如 `category=生鲜`），比纯语义检索准得多。
- `carriedConstraints`：显式列出「哪些历史约束被继承」，便于发现「用户已经否定的约束又被带回来」。
- `needsClarification` + `confidence`：**低置信时反问，而不是猜**。这是多轮体验的分水岭。
- `reason`：线上出问题时能解释「为什么改成了这样」，也是评测语料的来源。

### 3.1 判定阈值：用代价矩阵而不是拍脑袋

| 情况 | 猜错的代价 | 反问的代价 | 选择 |
|---|---|---|---|
| 查询类（无副作用） | 答非所问，用户再问一次 | 多一轮交互 | 置信度 > 0.5 就猜 |
| 写操作类（退款、改地址） | 造成资损 | 多一轮交互 | 置信度 > 0.85 才执行，否则必须反问 |
| 涉及金额/时间 | 纠纷 | 多一轮交互 | 必须反问 |

---

## 四、Spring AI 落地代码

### 4.1 系统提示词（固定前缀，利于 prompt cache）

```java
private static final String REWRITE_SYSTEM = """
        你是多轮对话的查询改写器。任务：把用户最新一句话改写成一个不依赖上下文的独立问句。

        规则：
        1. 只允许使用【会话槽位】中的实体，禁止编造实体或属性。
        2. 只允许继承【有效约束】，已被用户否定的约束必须丢弃。
        3. 不要把上一轮助手的结论当作事实塞进新问句。
        4. 若存在多个候选实体且无法确定，needsClarification=true，并给出一个简短的澄清问题。
        5. standaloneQuery 必须是用户视角的自然问句，不要包含"根据对话"等元描述。
        6. 相对时间（上周/昨天/最近）必须结合【会话开始时间】转成绝对日期。

        只输出 JSON，不要输出任何解释。
        """;

private static final String REWRITE_USER_TEMPLATE = """
        【会话开始时间】%s
        【会话槽位】%s
        【有效约束】%s
        【最近 3 轮对话】
        %s
        【用户最新输入】%s
        """;
```

### 4.2 调用与校验

```java
@Service
public class QueryRewriteService {

    private final ChatClient chatClient;
    private final ObjectMapper objectMapper = new ObjectMapper();

    public QueryRewriteService(ChatClient.Builder builder) {
        this.chatClient = builder
                .defaultSystem(REWRITE_SYSTEM)
                .build();
    }

    public RewriteResult rewrite(String userInput, SessionState state) {
        if (!shouldRewrite(userInput, state)) {
            return RewriteResult.passthrough(userInput);
        }

        String history = state.recentTurns(3).stream()
                .map(t -> t.role() + ": " + t.content())
                .collect(Collectors.joining("\n"));

        String user = REWRITE_USER_TEMPLATE.formatted(
                state.startedAt(),
                objectMapper.writeValueAsString(state.slots()),
                objectMapper.writeValueAsString(state.activeConstraints()),
                history,
                userInput);

        String raw = chatClient.prompt().user(user).call().content();

        RewriteResult result = parseSafely(raw, userInput);
        return guard(result, userInput, state);
    }

    private RewriteResult parseSafely(String raw, String fallbackQuery) {
        try {
            String json = extractJsonBlock(raw);   // 去掉 ```json 包裹
            return objectMapper.readValue(json, RewriteResult.class);
        } catch (Exception e) {
            log.warn("rewrite parse failed, fallback to raw query. raw={}", raw);
            return RewriteResult.passthrough(fallbackQuery);
        }
    }
}
```

### 4.3 三道护栏（比 prompt 更可靠）

```java
private RewriteResult guard(RewriteResult r, String original, SessionState state) {
    // 1. 实体白名单：改写结果里出现的实体必须在槽位或本轮输入中
    Set<String> allowed = new HashSet<>(state.allEntityValues());
    allowed.addAll(extractEntities(original));
    for (String e : r.resolvedEntities()) {
        String value = e.contains(":") ? e.substring(e.indexOf(':') + 1) : e;
        if (!allowed.contains(value)) {
            log.warn("rewrite invented entity: {}, fallback", e);
            return RewriteResult.passthrough(original);
        }
    }

    // 2. 长度护栏：改写后不应比原文长 3 倍（通常是模型开始"解释"了）
    if (r.standaloneQuery().length() > original.length() * 3 + 40) {
        return RewriteResult.passthrough(original);
    }

    // 3. 否定一致性：用户本轮说"不要/不是"，改写结果不能包含该约束
    if (original.contains("不要") || original.contains("不是")) {
        for (String c : r.carriedConstraints()) {
            if (original.contains(c)) {
                return RewriteResult.passthrough(original);
            }
        }
    }
    return r;
}
```

这三条护栏挡掉了线上大部分「改写反而变差」的 case。**prompt 是概率性的，代码护栏是确定性的**，两者必须配合。

### 4.4 检索与工具调用如何使用改写结果

```java
public Answer handle(String userInput, SessionState state) {
    RewriteResult r = rewriteService.rewrite(userInput, state);

    if (r.needsClarification() && r.confidence() < 0.6) {
        return Answer.clarify(r.clarificationQuestion());
    }

    // 1. 语义检索用 standaloneQuery
    SearchRequest req = SearchRequest.builder()
            .query(r.standaloneQuery())
            .topK(20)
            // 2. 结构化实体转 metadata filter，提升精确率
            .filter(buildFilter(r.resolvedEntities()))
            .build();

    List<Document> docs = vectorStore.similaritySearch(req);

    // 3. 原始 query 一并传给生成模型，保留用户语气与细节
    return generator.answer(r.standaloneQuery(), userInput, docs, state);
}
```

注意第 3 步：**改写结果用于「检索」，原始输入用于「生成」**。只把改写后的 query 传给生成模型，会丢掉用户的原话细节（尤其是抱怨、限定词），回答会变得生硬。

### 4.5 LangChain4j 版本的差异

LangChain4j 的 `ChatMemory` + `AiServices` 更偏向「把历史自动带进 prompt」，适合简单场景。要做严格改写，建议：

- 用 `@UserMessage` 手工拼装（不要依赖自动记忆注入），保证槽位与历史分离；
- 用 `OutputParser` 或 `PojoOutputParser` 做结构化映射；
- 用 `ContentRetriever` 包装检索，在 `retrieve(Query)` 里替换 `query.text()`，避免污染其他链路。

---

## 五、会话状态：改写的地基

改写质量的上限由状态质量决定。最小可用的状态模型：

```java
public record SessionState(
        String sessionId,
        Instant startedAt,
        Map<String, Object> slots,          // orderId, skuId, category, addressId...
        List<Constraint> constraints,       // 有效约束，含 status=ACTIVE|REVOKED
        List<Turn> recentTurns,
        double lastRetrievalScore,
        int turnCount
) {}
```

四个设计要点：

1. **槽位有类型、有来源**：`{type: ORDER_ID, value: "A123", source: "user_turn_1"}`。来源决定了可信度，来自模型推断的实体不能直接用于写操作。
2. **约束有状态**：用户说「不要红色的」时，把 `color=red` 标为 `REVOKED` 而不是删除，便于审计与回滚。
3. **时间锚定在会话开始**：「上周」在跨天会话里必须能还原成具体日期，不能每次用 `now()`。
4. **不存原始长文本**：只存最近 N 轮 + 摘要，避免 prompt 膨胀（这也和「上下文工程」里的压缩策略一致）。

---

## 六、评测：怎么证明改写真的有用

不要只看「感觉变好了」。四个可量化指标：

| 指标 | 定义 | 采集方式 |
|---|---|---|
| 指代消解准确率 | 人工标注 200 条多轮样本，改写后实体是否正确 | 离线标注集，人工/规则判定 |
| 端到端 Recall@5 | 同一条多轮样本，改写前后检索命中率 | 黄金集（问题 + 正确文档 id） |
| 误改写率 | 原文已完整，改写后反而变差的比例 | 用「完整 query 集」跑改写，比较相似度与召回 |
| 澄清命中率 | 应该反问的场景中，实际反问的比例 | 规则构造的对抗集 |

一个实测的参考区间（内部业务，供对照）：条件触发改写后，多轮场景 Recall@5 从 0.52 提升到 0.78，误改写率 4.2%，额外成本 +12%。

**误改写率是最容易被忽略的指标**。很多方案在多轮上提升明显，但把单轮完整 query 改坏了，整体收益被抵消。

---

## 七、踩坑清单

| 坑 | 现象 | 修法 |
|---|---|---|
| 把助手回答当事实来源 | 用户问「那个多少钱」，改写塞入了助手编造的价格 | 只允许槽位 + 用户输入作为实体来源 |
| 多意图合并 | 「查下物流，顺便看看能不能退货」被改写成单一问题 | 检测 `，/并且/顺便` 时拆分意图，走并行检索 |
| 专有名词被翻译/缩写 | 「SKU-88」变成「商品 88」 | 实体白名单 + 改写后做实体回填校验 |
| 历史含错误信息被固化 | 上一轮答错了，本轮改写继续沿用错误实体 | 槽位带 `confidence` 与 `source`，低置信不参与消解 |
| 相对时间用当前时间锚定 | 跨天会话「昨天」变成错误的日期 | 锚定 `session.startedAt`，并显式写入 prompt |
| 改写后 query 太长 | 检索被无关约束淹没 | 长度护栏 + 只保留最多 2 个约束 |
| 每次都改写导致延迟翻倍 | P95 从 1.2s 涨到 2.1s | 条件触发 + 小模型改写（8B 级足够） |
| 改写与检索用了不同的语言 | 用户中文提问，改写输出英文 | prompt 里固定输出语言 = 用户输入语言 |

---

## 八、面试追问

**Q1：为什么不能用「把历史对话拼进检索 query」代替改写？**
拼接会让检索 query 变成「多个意图的混合体」，向量相似度被稀释；同时历史里的无关内容会引入噪声。更致命的是无法做 metadata 过滤，也无法做置信度判断与反问。

**Q2：改写用大模型还是小模型？**
改写是「结构化信息重组」，不需要强推理。8B~14B 级别模型 + few-shot + JSON Schema 约束通常够用，成本是大模型的 1/10。只有在涉及复杂指代链（跨 5 轮以上）时才升级。

**Q3：如何避免改写引入幻觉？**
三层：prompt 禁止编造 + 实体白名单校验 + 解析失败/校验失败回退原 query。回退必须是「静默降级」，不能让用户看到错误。

**Q4：多轮场景下 RAG 的召回率为什么天然更低？**
因为 query 更短、信息更少、指代更多。除了改写，还可以：把上一轮的高分文档作为「上下文文档」一起送入生成；用混合检索（BM25 补关键词）；对短 query 降低相似度阈值并扩大 topK。

**Q5：这个话题和 Query Rewriting / HyDE 有什么区别？**
HyDE 解决的是「query 与文档语义空间不匹配」（生成假设答案再检索），属于**检索侧增强**；本文的指代消解解决的是「query 本身不完整」，属于**输入侧补全**。两者可以叠加：先补全，再 HyDE 扩展。

---

## 总结

- 多轮对话的核心问题不是模型不够强，而是**输入残缺**；先分类（指代/省略/纠错/时间），再分别还原。
- 指代消解本质是「在结构化槽位上做选择」，不是文本替换；槽位质量决定改写上限。
- 默认走**条件触发改写**，用代价矩阵决定「猜」还是「反问」，把成本花在真正需要的地方。
- 输出必须是结构化对象（含实体、意图、置信度、是否需要澄清），再由 Java 侧三道护栏做确定性校验。
- 改写结果用于**检索**，原始输入用于**生成**；两者不能互相替代。
- 评测必须包含**误改写率**，否则很容易做出「多轮变好、单轮变差」的负收益方案。

对 Java 团队来说，这件事的技术门槛不在模型，而在状态管理与工程护栏——恰好是后端工程师最擅长的部分。把这两块做扎实，多轮体验的提升会比换更强的模型更明显。
