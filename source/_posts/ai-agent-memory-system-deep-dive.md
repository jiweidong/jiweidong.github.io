---
title: 【AI Agent】Agent 记忆系统深度解析：短期/长期记忆、向量记忆与总结压缩
date: 2026-10-17 08:20:00
tags:
  - AI
  - Agent
  - 记忆系统
  - 向量检索
  - 大模型
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】Agent 记忆系统深度解析

## 前言

让一个 Agent「像人一样」的关键，不是模型多大，而是它**能不能记住**。没有记忆的 Agent，每次对话都从零开始：用户上一轮说「我住在杭州」，下一轮问「明天出门要带伞吗」，它一脸茫然。

但「记忆」远不止「把历史对话都塞进 Prompt」。真正的工程问题有三层：

1. **放什么**：上下文窗口有限，不能全塞，放多少？放哪些？
2. **怎么取**：长期记忆可能几百万条，怎么在几十毫秒内召回相关片段？
3. **怎么忘/更新**：信息会过期、会被更正、会重复，如何压缩、覆盖、遗忘？

本文从**认知科学的记忆分层**出发，落到 **Agent 记忆系统的工程架构与 Java 实现**，最后给出一套可落地的记忆治理方案。这是「从会调 API 到会做 Agent」的关键跃迁。

---

## 二、记忆的四个层次

借鉴人类认知科学，Agent 记忆通常分成四层：

| 层次 | 类比 | 存储形态 | 生命周期 | 典型内容 |
|---|---|---|---|---|
| **短期记忆（Working Memory）** | 当前对话的「脑内」 | 上下文窗口 / 会话状态 | 单次会话 | 最近几轮对话、当前任务状态 |
| **长期记忆（Long-term）** | 长期知识和经历 | 向量库 / 关系库 / KV | 跨会话、持久 | 用户偏好、事实、历史经验 |
| **情景记忆（Episodic）** | 「那天发生了什么」 | 带时间戳的事件流 | 中期 | 具体交互事件、任务执行记录 |
| **语义记忆（Semantic）** | 「世界是怎样的」 | 知识图谱 / 文档库 | 长期 | 事实、概念、领域知识 |

对工程实现而言，最实用的划分是 **短期（上下文管理）** 和 **长期（外部存储 + 检索）** 两大部分，情景/语义更多是长期记忆的**内容分类**。

---

## 三、短期记忆：上下文窗口的精细管理

短期记忆的本质是**「如何在有限的 token 预算内，塞下最相关的历史」**。

### 3.1 四种经典策略

| 策略 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **全量缓冲** | 所有历史都塞 | 信息完整 | 很快超窗口 / 成本爆炸 |
| **滑动窗口** | 只保留最近 N 轮 | 简单、成本可控 | 丢掉早期重要信息 |
| **摘要压缩** | 把早期对话总结成概要 | 压缩比高 | 摘要可能失真/丢细节 |
| **混合（推荐）** | 最近 N 轮原文 + 更早摘要 | 平衡 | 实现稍复杂 |

### 3.2 Java 实现：滑动窗口 + 摘要压缩

```java
public class ShortTermMemory {
    private final Deque<Message> recent = new ArrayDeque<>();   // 最近 N 轮原文
    private String summary = "";                                // 更早内容的滚动摘要
    private final int maxRecentTurns = 10;
    private final ChatClient llm;                               // Spring AI ChatClient

    /** 写入一轮对话，超出窗口则触发压缩 */
    public synchronized void add(Message msg) {
        recent.addLast(msg);
        if (countTurns(recent) > maxRecentTurns) {
            // 弹出最老的一轮，合并进摘要
            Message oldest = recent.pollFirst();
            this.summary = compress(summary, oldest);
        }
    }

    /** 压缩：把旧摘要 + 新弹出的内容，重新总结 */
    private String compress(String oldSummary, Message evicted) {
        String prompt = """
            你是一个对话摘要器。请把「已有摘要」和「新对话」合并成一段不超过 150 字的摘要，
            保留用户的事实性信息（姓名、偏好、时间、地点、待办），丢弃寒暄。
            已有摘要：%s
            新增对话：用户-%s / 助手-%s
            """.formatted(oldSummary, evicted.userText(), evicted.assistantText());
        return llm.prompt().user(prompt).call().content();
    }

    /** 组装给模型的完整上下文：摘要 + 最近原文 */
    public List<Message> toContext() {
        List<Message> ctx = new ArrayList<>();
        if (!summary.isBlank()) {
            ctx.add(new Message("system", "【历史摘要】" + summary));
        }
        ctx.addAll(recent);
        return ctx;
    }
}
```

**关键点**：
- 摘要**滚动合并**（旧摘要 + 新内容 → 新摘要），避免摘要无限膨胀。
- 摘要**只保留事实**（who/what/when/preference/todo），丢寒暄——用 Prompt 显式约束。
- 最近 N 轮保留**原文**，保证近期细节不丢。

---

## 四、长期记忆：向量记忆的读写生命周期

长期记忆的核心是**「写入门控 + 检索召回 + 更新遗忘」**三步。

### 4.1 写入（Memory Write）：不是什么都要记

**最大的坑是「什么都往向量库塞」**——重复、噪声、隐私信息全进去，检索质量断崖式下跌。

写入前必须过一道**「记忆筛选器」**：

```java
public class MemoryWriter {
    private final ChatClient llm;
    private final VectorStore vectorStore;      // Spring AI VectorStore

    public void maybeWrite(String userText, String assistantText) {
        // 1) 让 LLM 判断「是否值得长期记住」+ 抽取结构化事实
        String raw = llm.prompt().user("""
            判断下面这段对话是否包含值得长期记住的用户信息（偏好/事实/长期目标）。
            若是，抽取为条目，JSON 数组返回 [{type, content, importance}]；否则返回 []。
            对话：用户说「%s」，助手答「%s」
            """.formatted(userText, assistantText)).call().content();

        List<MemoryItem> items = Json.parse(raw, new TypeReference<>() {});
        for (MemoryItem item : items) {
            if (item.importance() < 0.5) continue;             // 重要性门控
            if (isDuplicate(item)) { merge(item); continue; } // 去重/合并
            vectorStore.add(List.of(new Document(item.content(),
                    Map.of("type", item.type(), "ts", System.currentTimeMillis()))));
        }
    }
}
```

**写入门控四要素**：
1. **重要性（importance）**：只记重要的（用户偏好 > 闲聊）。
2. **去重（dedup）**：写入前先检索相似记忆，超过阈值则**合并/更新**而非新增。
3. **结构化（type/metadata）**：带上类型（偏好/事实/待办）和时间戳，便于后续过滤。
4. **隐私（PII）**：敏感信息脱敏或拒写。

### 4.2 检索（Memory Read）：混合检索 + 重排

单纯向量检索容易「语义相似但时间不对/类型不对」。生产级记忆检索应做**混合 + 过滤 + 重排**：

```java
public List<Document> retrieve(String query, int topK) {
    // 1) 元数据过滤：只取「偏好」「事实」类，且未过期
    SearchRequest req = SearchRequest.builder()
            .query(query)
            .topK(topK * 3)                       // 先多召回
            .filterExpression("type in ['preference','fact'] and ts > " + (now - TTL))
            .build();

    List<Document> candidates = vectorStore.similaritySearch(req);

    // 2) 混合：向量分数 + 时效性衰减 + 重要性加权，重排
    return candidates.stream()
            .map(d -> new Scored(d,
                    score(d, query)))              // 融合打分
            .sorted(Comparator.comparingDouble(Scored::score).reversed())
            .limit(topK)
            .map(Scored::doc)
            .toList();
}

private double score(Document d, String query) {
    double sim = (double) d.getMetadata().get("similarity");        // 向量相似度
    double recency = decay(System.currentTimeMillis() - (long) d.getMetadata().get("ts"));
    double importance = (double) d.getMetadata().getOrDefault("importance", 0.5);
    return 0.6 * sim + 0.25 * recency + 0.15 * importance;          // 加权融合
}
```

**为什么加时效性衰减？** 用户三个月前说「我在看 Java」，如今可能已经在学 AI——记忆要有**时间衰减**，否则会给出过时建议。

**为什么加重要性？** 用户说「我有花生过敏」的重要性远高于「我喜欢蓝色」；检索时若两者都相似，优先给重要的。

### 4.3 更新与遗忘（Memory Update / Forget）

**记忆更新（冲突消解）**：用户先说「我住杭州」，后说「我搬到上海了」——应**更新**而非并存。

```java
private void merge(MemoryItem item) {
    List<Document> similar = vectorStore.similaritySearch(
            SearchRequest.builder().query(item.content()).topK(1)
                         .similarityThreshold(0.9).build());
    if (!similar.isEmpty()) {
        vectorStore.delete(List.of(similar.get(0).getId()));   // 旧的删掉
    }
    vectorStore.add(List.of(new Document(item.content(), meta(item))));  // 写新的
}
```

**遗忘机制**：
- **TTL 过期**：给记忆加过期时间（情景记忆常用）。
- **容量上限**：每个用户最多 N 条，超出淘汰「低重要性 + 最久未访问」的（LRU + 重要性）。
- **主动删除**：用户说「忘掉我说过的」，支持按内容/时间批量删。

---

## 五、记忆系统的完整架构

把上面拼起来，一个生产级 Agent 记忆系统的分层：

```
┌─────────────────────────────────────────────────────┐
│                      Agent 推理层                     │
│   (Prompt 组装：系统提示 + 检索到的记忆 + 最近对话 + 工具)  │
└─────────────────────────────────────────────────────┘
        ▲                                    │
        │ 读取                                │ 写入
┌───────┴──────────────┐         ┌───────────┴────────────┐
│   短期记忆 (Working)   │         │   长期记忆 (Long-term)    │
│  滑动窗口 + 摘要压缩    │         │  ┌──────────────────┐  │
│  (会话级, 内存/Redis)  │         │  │ 语义记忆: 向量库    │  │
└──────────────────────┘         │  ├──────────────────┤  │
                                  │  │ 情景记忆: 事件流    │  │
                                  │  ├──────────────────┤  │
                                  │  │ 事实/偏好: KV/关系库 │  │
                                  │  └──────────────────┘  │
                                  └──────────────────────┘
                                          ▲
                                  ┌───────┴────────┐
                                  │  记忆管理器      │
                                  │ 写入门控/去重/合并 │
                                  │ 检索融合/重排      │
                                  │ TTL/淘汰/遗忘     │
                                  └────────────────┘
```

**两种流派**：
- **向量记忆为主**：把记忆条目 embedding 后存向量库（Milvus/Qdrant/pgvector），检索靠相似度。简单、通用。
- **图记忆（GraphRAG/知识图谱）**：把实体和关系建成图，支持多跳推理（「A 的导师的朋友」）。更强但更重。

生产建议：**先用向量记忆跑通闭环，遇到多跳/关系推理需求再上图记忆**。

---

## 六、工程实现：Java 技术栈选型

| 能力 | Java 方案 |
|---|---|
| 短期记忆存储 | 内存 `ConcurrentHashMap` / Redis（分布式会话） |
| 向量记忆 | Spring AI `VectorStore`（对接 Milvus/Qdrant/pgvector/ES） |
| 嵌入模型 | Spring AI `EmbeddingModel`（OpenAI/通义/本地 BGE） |
| 摘要压缩 | `ChatClient` 调小模型（省钱，如 gpt-4o-mini） |
| 事实/偏好 KV | Redis / MySQL |
| 事件流（情景） | Kafka + 时序库 |
| 重排 | 调用 Reranker API 或本地模型 |

**用便宜模型做摘要**是重要的成本优化——摘要/抽取这类任务不需要最强模型。

---

## 七、生产踩坑清单

1. **什么都往记忆里塞** → 检索噪声大、召回不准、成本高。**必须门控。**
2. **没有时间衰减** → 过时记忆误导模型（用户换城市/换技术栈）。
3. **记忆无限增长** → 存储和检索成本线性上升。**必须有 TTL 和容量上限。**
4. **写入不检查重复** → 同一条事实存了几十遍，占满召回位。
5. **检索只做向量、不加元数据过滤** → 「偏好类」和「闲聊」混在一起。
6. **隐私泄漏** → 记忆里存了手机号/身份证/密码。**写入前脱敏。**
7. **记忆与 RAG 不分** → RAG 是「读别人的知识」，记忆是「记自己的经历」，元数据和生命周期不同，建议分开存储、分开检索，再在 Prompt 层融合。
8. **多租户串记忆** → 一定要用 `user_id` 做元数据隔离，否则 A 用户的记忆被 B 召回（严重事故）。

---

## 八、面试高频追问

**Q1：Agent 的记忆系统包含哪些部分？**
短期记忆（上下文窗口管理：滑动窗口/摘要压缩）、长期记忆（向量库/知识图谱，含语义记忆、情景记忆、偏好事实）、以及记忆管理器（写入门控、去重合并、检索融合重排、TTL 淘汰遗忘）。

**Q2：上下文窗口塞不下历史对话怎么办？**
用「滑窗 + 滚动摘要」混合策略：最近 N 轮保留原文，更早内容滚动总结为摘要，摘要只保留事实性信息。更精细的可以按重要性/相关性对历史做检索式召回。

**Q3：长期记忆怎么防止「记了一堆没用的」？**
写入前做门控：LLM 判断重要性、抽取结构化条目、相似度去重合并、PII 脱敏；检索时用「向量相似度 + 时效衰减 + 重要性」加权融合，并加元数据过滤。

**Q4：用户信息变了（比如搬家），记忆怎么处理？**
记忆更新（冲突消解）：新信息检索到高度相似的旧记忆时，删除/覆盖旧的，而非并存。配合时间戳和语义去重。

**Q5：记忆和 RAG 有什么区别？**
RAG 检索的是「外部知识/文档」（别人的知识，生命周期长、变更少）；记忆是「Agent 与用户交互产生的经历」（自己的经历，更新频繁、带用户隔离、需要遗忘机制）。工程上建议分开存储与检索，Prompt 层融合。

**Q6：怎么控制记忆的存储与检索成本？**
摘要用便宜小模型；写入门控减少条目数；TTL + 容量上限控制规模；检索先多召回再重排，避免把全量记忆塞进 Prompt。

---

## 结语

Agent 的记忆系统，是「把上下文窗口变成会呼吸的活体」的工程：**短期靠滑窗 + 摘要压缩，长期靠向量/图存储 + 混合检索**，中间用**记忆管理器**做写入门控、去重合并、时效衰减、TTL 淘汰。它不是把对话 dump 进数据库那么简单，而是一整套「记什么、怎么取、何时忘」的策略。把记忆做扎实，你的 Agent 才真正从「无状态问答」进化成「有连续性的智能体」。下一篇继续盘多智能体协作与工作流编排。
