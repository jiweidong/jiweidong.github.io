---
title: 【Java AI】RAG 父子块与句子窗口检索深度实战：Small-to-Big、上下文预算与召回评测
date: 2026-11-23 09:00:00
tags:
  - Java
  - AI
  - RAG
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】RAG 父子块与句子窗口检索深度实战

## 面试官：你的 RAG 切块多大？为什么？

如果回答"512 token，大家都这么切"，基本会被追问三连：

- 切大了，向量被稀释，检索精度下降，怎么办？
- 切小了，命中的片段只有半句话，模型答不全，怎么办？
- 上下文只能放 8K，命中 10 个块塞不进去，怎么办？

这三个问题指向同一个工程矛盾：**检索单元和生成单元的最优粒度不一样**。检索要"短而准"，生成要"长而全"。Small-to-Big（小块检索、大块返回）就是解这个矛盾的标准手法，落地形态主要有三种：Parent-Child、Sentence Window、Auto-merging。

本文用 Java + Spring AI 的视角把它讲透，包括数据结构、检索链路、token 预算和评测方法。

## 一、三种 Small-to-Big 策略对比

| 策略 | 索引什么 | 返回什么 | 优点 | 代价 |
|---|---|---|---|---|
| Parent-Child | 子块（200~300 token） | 子块所属父块（800~1500 token） | 检索准、上下文完整 | 需存两层结构与映射 |
| Sentence Window | 单句 / 短句组 | 命中句 ± N 句窗口 | 引用极精确、可定位到句 | 短句向量语义弱 |
| Auto-merging | 层级块（段→节→文档） | 命中数达阈值则向上合并 | 自适应，无固定窗口 | 实现复杂，合并策略难调 |

选择建议：

- 文档结构清晰（手册、规范、合同）→ **Parent-Child**，父块按章节，子块按段落。
- 问答型、需要精确引用（客服、法务）→ **Sentence Window**，答案必须能指到原句。
- 长文档摘要型 → **Auto-merging**，命中同一节多个子块时合并成节。

下面重点讲前两种，因为它们能用一套"两级结构"统一实现。

## 二、数据结构：一次切分，两层产出

核心是给每个子块打上"父块指针 + 位置信息"：

```java
public record Chunk(
    String id,            // child: docId#p3#c2
    String docId,
    String parentId,      // docId#p3
    String text,
    int startOffset,      // 原文偏移，用于引用溯源
    int endOffset,
    int order,            // 子块在父块内的序号
    Map<String, Object> metadata
) {}
```

写入向量库时：

- **只对子块做 embedding**，`parentId` 作为 payload/metadata 字段（可过滤、可回查）。
- 父块原文存两份：一份在 ES/MySQL 的文档表（按 `parentId` 主键），一份可选地冗余在子块 metadata 里（省一次查询，但放大存储）。
- `startOffset/endOffset` 是引用溯源的关键，别省。

Spring AI 的 `Document` 可以直接承载这些：

```java
Document child = new Document(
    childId,
    childText,
    Map.of(
        "docId", docId,
        "parentId", parentId,
        "order", order,
        "startOffset", start,
        "endOffset", end,
        "title", title
    )
);
vectorStore.add(List.of(child));
```

注意 Spring AI 的 `Document.getId()` 在部分实现里会被向量库重写，**业务 id 要放在 metadata 里**，不要只依赖 `getId()`。

## 三、Parent-Child 检索链路

```
query
  → embed
  → 子块 kNN topK=20
  → 按 parentId 分组去重（保留组内最高分）
  → 取 topN 个父块（N < K）
  → token 预算裁剪
  → 组装 prompt
```

四个实现要点：

**1. 去重必须按父块做，分数取组内最大值。** 同一个父块下 3 个子块都命中，只应返回一次父块；用最高分子块的分数代表父块相关性，比平均分更稳（平均会被不相关子块拉低）。

**2. 父块数量由 token 预算决定，不由 topK 决定。** 8K 上下文里，system prompt + 历史 + 问题占掉 2K，剩下 6K；父块平均 1000 token，最多 6 个。**先算预算，再定 N**，否则会出现"检索到 8 个父块，截断后只剩 3 个"的浪费。

**3. 子块命中位置要保留。** 返回父块时，把"命中的子块"标出来（例如在父块文本中高亮或单独列出），模型更容易定位答案，也方便前端做"跳转到该段"。

**4. 多跳问题需要跨父块。** 如果答案需要两个章节拼起来，Parent-Child 会失效——它假设答案在单个父块内。这类问题要靠 Query 改写拆成子问题，或者用 Auto-merging / GraphRAG。

Java 侧检索代码（伪代码，Spring AI 1.x 风格）：

```java
@Service
public class ParentChildRetriever {

    private final VectorStore vectorStore;
    private final ParentChunkRepository parentRepo;   // ES / MySQL
    private final TokenBudgeter budgeter;

    public List<ParentChunk> retrieve(String query, int maxTokens) {
        SearchRequest req = SearchRequest.builder()
            .query(query)
            .topK(20)
            .similarityThreshold(0.65)
            .build();

        List<Document> children = vectorStore.similaritySearch(req);

        // 1) 按 parentId 聚合，取最高分
        Map<String, Double> bestScore = new LinkedHashMap<>();
        Map<String, List<Document>> hitsByParent = new HashMap<>();
        for (Document c : children) {
            String pid = (String) c.getMetadata().get("parentId");
            double score = (double) c.getMetadata().getOrDefault("distance", 0.0);
            bestScore.merge(pid, score, Math::max);
            hitsByParent.computeIfAbsent(pid, k -> new ArrayList<>()).add(c);
        }

        // 2) 按分数排序父块
        List<String> ranked = bestScore.entrySet().stream()
            .sorted(Map.Entry.<String, Double>comparingByValue().reversed())
            .map(Map.Entry::getKey)
            .toList();

        // 3) 按 token 预算贪心装入
        List<ParentChunk> selected = new ArrayList<>();
        int used = 0;
        for (String pid : ranked) {
            ParentChunk p = parentRepo.find(pid);
            int cost = budgeter.count(p.text());
            if (used + cost > maxTokens) {
                if (selected.isEmpty()) {          // 至少给一个，必要时截断
                    selected.add(p.truncateTo(maxTokens));
                }
                break;
            }
            selected.add(p.withHighlights(hitsByParent.get(pid)));
            used += cost;
        }
        return selected;
    }
}
```

这里有个容易漏的点：**`similarityThreshold` 在父块聚合后要重新评估**。子块 0.7 分不代表父块 0.7 分；如果阈值设太高，可能整组被过滤，导致"明明有答案却召回 0 条"。建议阈值只用于子块粗筛，父块层用相对排序（topN）而不是绝对阈值。

## 四、Sentence Window 的实现细节

句子窗口是 Parent-Child 的极端形态：父块 = 命中句 ± N 句。

```java
public List<Chunk> sentenceWindows(String docId, int centerIdx, int radius) {
    List<Sentence> sentences = sentenceRepo.findByDoc(docId);  // 已按 order 排序
    int from = Math.max(0, centerIdx - radius);
    int to = Math.min(sentences.size() - 1, centerIdx + radius);

    StringBuilder sb = new StringBuilder();
    for (int i = from; i <= to; i++) {
        sb.append(sentences.get(i).text()).append(' ');
    }
    return List.of(new Chunk(
        docId + "#s" + centerIdx,
        docId,
        docId + "#win" + centerIdx,
        sb.toString().trim(),
        sentences.get(from).start(),
        sentences.get(to).end(),
        centerIdx,
        Map.of("centerSentence", sentences.get(centerIdx).text())
    ));
}
```

四个坑：

**1. 短句向量语义不足。** 单句往往只有 10~20 字，embedding 质量差，尤其是指代句（"它的返回值是…"）。解法：索引时给句子加**文档标题 + 章节标题前缀**：

```java
String indexText = title + " > " + sectionTitle + " > " + sentence;
```

检索时用同样的前缀拼 query 没有必要，但索引侧加前缀能显著提升短句的可检索性。

**2. 窗口重叠导致重复。** 相邻句子的窗口会大量重叠。检索后要按 `(docId, centerIdx)` 去重，或者合并相邻窗口。

**3. 引用要指到"中心句"，不是整个窗口。** 返回给用户时高亮 `centerSentence`，窗口只作为模型上下文。否则用户会觉得"引用了一大段，没重点"。

**4. 句子切分要按语言处理。** 中文按 `。！？；` 切，英文按 `.?!` 且要避开 `Mr.`、`e.g.` 这类缩写。用简单的正则会在小数点、版本号上切错——建议用成熟的句子切分库（如 ICU4J 的 `BreakIterator`）。

```java
BreakIterator it = BreakIterator.getSentenceInstance(Locale.CHINA);
it.setText(text);
for (int start = it.first(), end = it.next();
     end != BreakIterator.DONE;
     start = end, end = it.next()) {
    sentences.add(text.substring(start, end).trim());
}
```

ICU4J 比正则可靠，但也要过滤过短句（< 8 字）并合并到相邻句，避免产生大量无意义向量。

## 五、上下文预算：别让"更多块"变成"更差答案"

Small-to-Big 最容易犯的错是"既然父块更全，那就多塞几个"。结果是：

- 关键信息被埋在中间（Lost in the Middle），模型反而漏读。
- token 成本线性上涨，延迟上升。
- 噪声块引入矛盾事实，模型开始编。

一个可用的预算公式：

```
可用上下文 = 模型窗口 - system - 历史 - 输出预留 - 安全余量
父块数 N  = floor(可用上下文 / 父块平均 token)
最终 N    = min(N, 6)      // 经验上限，超过 6 个父块的边际收益很低
```

如果命中父块普遍很大（>1500 token），优先做**父块内二次裁剪**：只保留"命中子块 ± 1 段"，而不是整个父块。这相当于 Parent-Child 和 Sentence Window 的混合。

另外一个技巧：**把多个父块按文档顺序重排**，而不是按相关度顺序。模型读连续文本的效果通常好于跳读，且引用编号更自然。

## 六、评测：怎么证明"父子块"真的有用

不要用"感觉答案变好了"来验收。至少跑三组指标：

| 指标 | 测什么 | 目标 |
|---|---|---|
| Recall@5（块级） | 正确父块是否进 top5 | 相比单层切块 +10% 以上 |
| Context Precision | 返回的父块里有多少是相关的 | 不低于单层基线 |
| Faithfulness | 答案是否被上下文支持 | 不低于基线（防"上下文变多反而编"） |
| 平均上下文 token | 成本 | 上涨不超过 40% |
| TTFT / 总延迟 | 体验 | P95 上涨不超过 300ms |

黄金集构造建议 50~100 条，每条标注：问题、答案要点、**证据所在父块 id**、证据句 offset。有了 offset 才能算"引用命中率"。

一个容易忽略的对照组：**同 token 预算下，单层大块 vs 父子块**。很多人只对比"父子块 vs 小块"，忽略了"我把同样的 token 预算给大块，效果是不是差不多"。这个对照才能证明结构本身的价值。

## 七、踩坑清单

| 坑 | 表现 | 处理 |
|---|---|---|
| 文档更新只重写子块 | 父块还是旧内容 | 以 `docId` 为单位先删后插，事务化 |
| 删除文档漏删父块 | 孤儿父块占存储 | 级联删除 + 定期对账 |
| 父块跨章节 | 上下文包含无关内容 | 切分时以标题为硬边界 |
| 子块太小（<100 token） | 向量语义弱，召不回 | 设最小块长，短段合并 |
| 阈值过滤掉整组 | 召回 0 但文档里明明有 | 子块粗筛 + 父块相对排序 |
| 高亮位置错乱 | 引用指向错误段落 | 用 offset 而非字符串匹配 |
| 窗口无限重叠 | 重复内容浪费 token | 相邻窗口去重/合并 |

## 八、面试追问

**Q：父子块和"重排（Rerank）"是什么关系？**
互补。父子块解决"检索粒度 vs 生成粒度"，Rerank 解决"召回排序不准"。常见组合是：子块 kNN 召回 → Rerank 精排子块 → 聚合父块。重排放在子块层比父块层便宜且准。

**Q：父块太大，模型上下文放不下怎么办？**
两级裁剪：先按命中子块定位父块内的相关段，只送"命中段 ± 1 段"；仍超预算就降 N。永远不要截断父块的尾部了事——答案常在尾部。

**Q：如何避免父子块导致的"答案张冠李戴"？**
严格以 `docId` 隔离，metadata 里带版本号；父块查询用 `parentId` 精确匹配而不是全文检索；引用输出必须带 `docId + offset`，前端可回链原文。

**Q：Sentence Window 的 N 取多少？**
经验值 2~4。N 太小答案不完整，太大退化成段落检索。用黄金集扫 N ∈ {1,2,3,4,5}，看 Faithfulness 与 token 成本的拐点。

**Q：这套结构对多模态文档（PDF 表格）适用吗？**
部分适用。表格要作为整体块（不能按句切），父块 = 表格 + 表题 + 上下文说明；图片走单独的图文对齐索引，不要混进句子窗口。

## 小结

Small-to-Big 的本质是**把"检索单元"和"生成单元"解耦**：子块负责被找到，父块负责被理解。落地时真正决定效果的不是切块参数，而是三件事——父块边界的语义完整性、按 token 预算而非 topK 组装上下文、以及用黄金集证明"结构带来的收益大于成本"。这三点讲清楚，才算真正做过 RAG。
