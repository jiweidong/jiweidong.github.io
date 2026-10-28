---
title: 【RAG 进阶】GraphRAG 深度解析：知识图谱构建、社区摘要与全局问答的 Java 落地
date: 2026-10-28 10:00:00
tags:
  - AI
  - RAG
  - GraphRAG
  - 知识图谱
  - Java
categories:
  - RAG
author: 东哥
---

# 【RAG 进阶】GraphRAG 深度解析：知识图谱构建、社区摘要与全局问答的 Java 落地

## 前言

向量 RAG 有一个绕不过去的天花板：**它只会「找相似的片段」**。

问一个具体问题——「退款时效是几天？」——向量检索很擅长，找到《售后政策》第 3.2 节就完事。但换成这几类问题，向量 RAG 就开始胡说：

- **全局性问题**：「这份 200 页的尽调报告，主要风险有哪些？」——答案分散在几十个段落里，没有任何一个 chunk 包含「整体结论」。
- **多跳问题**：「A 公司的供应商里，哪些也供货给 B 公司？」——需要「A → 供应商 → B」两跳推理，向量相似度帮不上忙。
- **关系性问题**：「张三和李四在项目里是什么关系？」——关系本身就是答案，但它不在任何单段文本里。

GraphRAG 就是为这三类问题生的。它把文档「拆成实体和关系」，建成知识图谱，再用**社区检测 + 社区摘要**回答全局性问题。

但这玩意儿的代价也很真实：**索引成本是向量 RAG 的 10~100 倍**。所以本文除了讲原理，更重要的是讲**什么时候该用、什么时候纯属浪费钱**，以及 Java 侧怎么落地。

## 一、GraphRAG 的核心思想

Microsoft Research 在 2024 年提出的 GraphRAG，流程可以概括成五步：

```
原始文档
  ↓ ① 切分
TextUnit（文本单元，比 chunk 稍大）
  ↓ ② LLM 抽取
实体（Entity）+ 关系（Relationship）+ 声明（Claim）
  ↓ ③ 图构建
知识图谱（节点 + 边，带描述和权重）
  ↓ ④ 社区检测（Leiden 算法，层次化）
社区（Community）+ 每个社区的摘要（LLM 生成）
  ↓ ⑤ 查询
Local Search / Global Search / DRIFT Search
```

关键创新在第 ④ 步：**层次化社区 + 社区摘要**。

想象一份 200 页的报告。向量 RAG 把它切成 800 个 chunk，检索时只能命中其中 3~5 个。而 GraphRAG 会：

1. 抽出 2000 个实体，形成一张图；
2. 用 Leiden 算法把图分成多个层级（L0 最大粒度的几个社区，L1 更细，L2 更细……）；
3. **给每个社区生成一段摘要**（「这个社区讲的是供应链风险，涉及 12 家供应商，主要问题是……」）；
4. 回答全局问题时，**读摘要而不是读原文**。

这就是为什么它能回答「整体风险有哪些」——因为摘要本身就是「整体视角」。

## 二、索引：成本的大头在这里

### 2.1 实体抽取

对每个 TextUnit（通常 300~600 token）调一次 LLM，要求输出结构化 JSON：

```json
{
  "entities": [
    {"name": "宁德时代", "type": "ORGANIZATION",
     "description": "全球领先的动力电池制造商，2025 年装机量第一"},
    {"name": "特斯拉", "type": "ORGANIZATION",
     "description": "美国电动车企业，宁德时代为其供应商"}
  ],
  "relationships": [
    {"source": "宁德时代", "target": "特斯拉",
     "description": "宁德时代为特斯拉供应磷酸铁锂电池", "weight": 8}
  ]
}
```

`description` 非常重要——它不只是给人看的，**后续检索和摘要都依赖这些描述**。所以 Prompt 里要强调「描述要具体，包含时间、数字、结论」。

### 2.2 成本估算（现实很骨感）

假设 200 页报告，约 15 万字，切 300 个 TextUnit：

| 步骤 | LLM 调用次数 | 单次 token（入/出） | 总 token |
|---|---|---|---|
| 实体抽取 | 300 | 600 / 800 | 42 万 |
| 社区摘要（L0~L2） | 约 80 | 3000 / 600 | 29 万 |
| 实体描述合并去重 | 约 200 组 | 400 / 300 | 14 万 |
| **合计** | **约 580 次** | — | **约 85 万 token** |

按 GPT-4o 价格（$2.5/M 入、$10/M 出）粗算，**一份 200 页报告索引成本约 4~6 美元**。听起来不多？乘以 1 万份文档就是 5 万美元，而且每次文档更新都要重跑。

对比向量 RAG：同样的文档，Embedding 成本不到 0.05 美元。

**所以第一原则：GraphRAG 不是「更高级的 RAG」，是「更贵的 RAG」，只在全局性/关系性问题占比高时才划算。**

### 2.3 降低成本的四招

1. **用便宜模型做抽取**：抽取是「信息抽取」任务，Qwen-Plus / GPT-4o-mini 就够，效果损失很小，成本降 20 倍。
2. **域适配的 schema**：不要让它自由发挥实体类型，预先定义 10~15 个类型（组织/人物/产品/风险/条款/金额/日期…），抽取更稳定也更短。
3. **增量索引**：只对新文档做抽取，社区摘要按「受影响社区」局部重算，而不是全量重建。
4. **分层策略**：只对「核心文档」（制度、报告、合同）建图，普通 FAQ 走向量 RAG。

## 三、社区检测：Leiden 算法

社区检测的作用是「把图分成若干簇」，簇内节点连接紧密，簇间连接稀疏。

为什么用 Leiden 而不是 Louvain？因为 Louvain 有一个著名缺陷：**可能产生「内部不连通」的社区**。Leiden 加了「细化（refinement）」阶段，保证每个社区内部连通，且能产生真正的层次结构。

层次结构对 GraphRAG 至关重要：

```
L0: [整个报告 = 1 个社区]
L1: [市场风险] [供应链风险] [财务风险] [合规风险]
L2: [供应链风险-上游原材料] [供应链风险-物流] [供应链风险-单一供应商依赖]
```

回答「整体风险」时读 L1 摘要，回答「原材料风险」时读 L2——**粒度可调**。

Java 侧实现选择：

| 方案 | 优点 | 缺点 |
|---|---|---|
| JGraphT（Louvain） | 纯 Java，无外部依赖 | 没有 Leiden，层次结构要自己迭代 |
| leiden-java / 自研 | 完全对齐 GraphRAG | 实现成本高 |
| 调 Python 服务（graspologic/igraph） | 现成、准确 | 多一个服务，运维成本 |

**务实建议**：中小规模（<10 万节点）用 JGraphT 反复跑 Louvain + 逐层合并，效果够用；规模大或要求严格对齐官方实现，就在 Python 侧算好社区 ID，写回图数据库，Java 只负责查询和摘要。

JGraphT 示例：

```java
// 依赖：org.jgrapht:jgrapht-core
public Map<String, Integer> detectCommunities(Graph<String, DefaultWeightedEdge> graph) {
    // 1. 第一层社区
    LouvainCommunityDetector<String, DefaultWeightedEdge> louvain =
            new LouvainCommunityDetector<>(graph);
    CommunityDivision<String, DefaultWeightedEdge> division = louvain.execute();

    Map<String, Integer> communityOf = new HashMap<>();
    division.getCommunities().forEach((communityId, vertices) ->
            vertices.forEach(v -> communityOf.put(v, communityId)));

    // 2. 把社区当节点，构建上一层图，递归（这里省略，按需迭代 2~3 层）
    return communityOf;
}
```

**注意：社区检测必须在「无向加权图」上做。** 原始图是有向的（A 供应给 B），要先把边合并成无向权重（`weight = f(边数, 描述长度, LLM 给的 weight)`），否则社区划分会很碎。

## 四、查询：三种模式

### 4.1 Global Search（全局问答）

流程是标准的 **map-reduce**：

```
问题：「这份报告的主要风险是什么？」
  ↓ 取 L1 层所有社区摘要（比如 12 个）
  ↓ map：每个摘要 + 问题 → LLM 生成「部分答案 + 重要度打分」
  ↓ reduce：按重要度排序，合并成最终答案，附引用
```

Java 实现（虚拟线程并行 map）：

```java
public String globalSearch(String question, int level, int topK) {
    List<CommunitySummary> summaries = communityRepo.findByLevel(level);

    try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
        List<Future<PartialAnswer>> futures = summaries.stream()
                .map(s -> executor.submit(() -> mapAnswer(question, s)))
                .toList();

        List<PartialAnswer> partials = futures.stream()
                .map(f -> {
                    try { return f.get(120, TimeUnit.SECONDS); }
                    catch (Exception e) { return PartialAnswer.empty(); }
                })
                .filter(PartialAnswer::hasContent)
                .sorted(Comparator.comparingDouble(PartialAnswer::score).reversed())
                .limit(topK)
                .toList();

        return reduceAnswer(question, partials);
    }
}

private PartialAnswer mapAnswer(String question, CommunitySummary s) {
    String prompt = """
            以下是一个文档社区的摘要。请判断它是否包含与问题相关的信息。
            如果有，输出 JSON：{"score": 0~10, "points": ["要点1", "要点2"]}
            如果没有，输出 {"score": 0, "points": []}
            不要编造摘要里没有的内容。

            问题：%s
            摘要：%s
            """.formatted(question, s.text());

    return parse(objectMapper, chatClient.prompt().user(prompt).call().content());
}
```

**关键点：`score` 让 LLM 自己打分，而不是把所有摘要都塞进最终上下文。** 否则 12 个摘要 × 3000 token = 3.6 万 token，成本和延迟都失控。

### 4.2 Local Search（局部问答）

针对具体实体的问题，从实体出发做邻域扩展：

```cypher
// Neo4j：以「宁德时代」为中心，取 2 跳邻域
MATCH (e:Entity {name: $name})
CALL apoc.path.subgraphAll(e, {
  maxLevel: 2,
  relationshipFilter: "RELATED_TO>|<RELATED_TO",
  limit: 200
})
YIELD nodes, relationships
RETURN nodes, relationships
```

然后把「实体描述 + 关系描述 + 关联的原文片段」拼成上下文，交给 LLM。

这本质上是**结构化的多跳检索**：向量检索只能找「和问题相似」的 chunk，而图检索能沿关系走两跳，把「A 的供应商的客户」这种链路捞出来。

### 4.3 DRIFT Search

DRIFT = Dynamic Reasoning and Inference with Flexible Traversal。它把 Global 和 Local 结合：

1. 先用社区摘要做一个「全局定位」，找到相关领域；
2. 再从该领域内的实体出发做局部扩展；
3. 迭代追问（follow-up questions），直到信息足够。

这是目前效果最好的模式，但实现复杂度也最高。**建议先做 Local + Global，跑通了再考虑 DRIFT。**

## 五、Java 落地架构

一个可落地的分层架构：

```
┌─────────────────────────────────────────────┐
│  查询层：Local / Global / Hybrid Router      │
├─────────────────────────────────────────────┤
│  检索层：向量检索 + 图邻域扩展 + 摘要检索      │
├─────────────────────────────────────────────┤
│  存储层：Neo4j（图） + ES/pgvector（向量）     │
├─────────────────────────────────────────────┤
│  索引层：抽取 → 去重合并 → 建图 → 社区 → 摘要  │
├─────────────────────────────────────────────┤
│  接入层：文档解析（PDF/Word/HTML）             │
└─────────────────────────────────────────────┘
```

### 5.1 图数据模型

```cypher
// 实体
(:Entity {
  id: "ent_001",
  name: "宁德时代",
  type: "ORGANIZATION",
  description: "全球领先的动力电池制造商...",
  embedding: [0.12, -0.34, ...],   // 实体名+描述的向量，用于实体链接
  docId: "report_2026",
  communityL0: 3, communityL1: 12
})

// 关系
(:Entity)-[:RELATED_TO {
  description: "为特斯拉供应磷酸铁锂电池",
  weight: 8,
  sourceDoc: "report_2026",
  sourceChunk: "chunk_045"
}]->(:Entity)

// 社区摘要
(:Community {
  id: "com_L1_12",
  level: 1,
  title: "供应链风险",
  summary: "...",
  entityCount: 34
})
(:Entity)-[:BELONGS_TO]->(:Community)
```

`sourceChunk` 是**引用溯源的生命线**——用户点「查看原文」时，靠它定位到具体段落。

### 5.2 批量写入

逐条 `CREATE` 会很慢。用 `UNWIND` 批量：

```java
public void batchUpsert(List<Entity> entities, List<Relation> relations) {
    String entityCypher = """
            UNWIND $rows AS row
            MERGE (e:Entity {name: row.name})
            ON CREATE SET e.id = row.id, e.type = row.type,
                          e.description = row.description
            ON MATCH SET  e.description =
                CASE WHEN size(row.description) > size(e.description)
                     THEN row.description ELSE e.description END
            SET e.communityL0 = row.communityL0, e.communityL1 = row.communityL1
            """;

    try (Session session = driver.session()) {
        session.executeWrite(tx -> {
            tx.run(entityCypher, Map.of("rows", entities));
            return null;
        });
    }
}
```

注意 `ON MATCH` 里的逻辑：**实体描述取「更长的那条」**。因为同一实体在多处出现，描述详略不同，取最长的通常信息最全（也可以用 LLM 合并，但成本高）。

### 5.3 混合检索（Hybrid）

生产上很少「纯图」或「纯向量」，通常是：

```java
public RagContext retrieve(String question) {
    // 1. 向量检索拿原文片段（保底，防止图里没抽到）
    List<Chunk> chunks = vectorStore.similaritySearch(question, 8);

    // 2. 从问题里识别实体（NER 或 LLM），做图扩展
    List<String> entities = entityLinker.link(question);
    List<GraphFact> facts = entities.isEmpty()
            ? List.of()
            : graphRepo.neighborhood(entities, 2, 50);

    // 3. 判断问题类型，决定是否走 Global
    if (isGlobalQuestion(question)) {
        return RagContext.of(chunks, facts, globalSummaries(question));
    }
    return RagContext.of(chunks, facts, List.of());
}
```

`isGlobalQuestion` 可以用一个小的分类 Prompt（「这个问题需要综合全文，还是查具体事实？」），成本很低但效果好。

## 六、GraphRAG vs 向量 RAG：怎么选

| 维度 | 向量 RAG | GraphRAG |
|---|---|---|
| 索引成本 | 低（Embedding） | 高（LLM 抽取 + 摘要） |
| 索引耗时 | 分钟级 | 小时级 |
| 单点事实问答 | 好 | 好（但更贵） |
| 全局总结 | 差 | 好 |
| 多跳推理 | 差 | 好 |
| 关系查询 | 差 | 好 |
| 增量更新 | 简单（加 chunk） | 复杂（影响社区结构） |
| 可解释性 | 中（相似度） | 高（路径 + 摘要） |
| 运维复杂度 | 低 | 高（图库 + 社区计算） |
| 适合规模 | 百万级 chunk | 万级文档（再大成本失控） |

**决策树：**

```
问题里「整体/主要/趋势/对比/关系」占比 > 30%？
  ├─ 否 → 向量 RAG + 重排，够用
  └─ 是 → 文档量 < 1 万份？
            ├─ 是 → GraphRAG 值得做
            └─ 否 → 分层：核心文档建图，其余走向量
```

## 七、评测：怎么证明它真的更好

GraphRAG 的评测不能只看「回答像不像」。三个维度：

1. **Comprehensiveness（全面性）**：答案覆盖了多少「应该提到的点」。用 LLM-as-judge，给出参考答案的要点清单，算覆盖率。
2. **Diversity（多样性）**：答案涉及多少个不同视角/实体。全局问题最怕「只挑一个角度说」。
3. **Empowerment（有用性）**：答案是否帮助用户做出判断（这个只能人工评）。

实现上，构造 50~100 条「全局型问题」的黄金集，分别跑向量 RAG 和 GraphRAG，用同一个 judge prompt 打分，做**盲评**（不告诉 judge 哪个是哪个）。

经验数据（我们内部测试，仅供参考）：全局问题上 GraphRAG 的全面性比向量 RAG 高 30~50%，但在单点事实上**没有优势甚至略差**（因为抽取过程会丢细节）。所以千万别「一刀切替换」。

## 八、踩坑清单

**1. 实体没对齐（Entity Resolution）**
「宁德时代」「CATL」「宁德时代新能源科技股份有限公司」是同一个实体，但抽取出来是三个节点。图会被撕碎，社区检测也失效。
解决：抽取后做**实体链接**（embedding 相似度 + 别名表 + LLM 判定），把 `name` 归一化到 `canonicalName`。

**2. 社区摘要「一本正经地胡说」**
摘要由 LLM 生成，会加入原文没有的推断。必须约束：「只基于给定实体和关系描述，不要引入外部知识」，并在摘要里保留实体列表供核对。

**3. 增量更新导致社区漂移**
新增一批文档后重跑社区检测，社区 ID 全变了，之前的摘要缓存全失效。解决：固定社区 ID 的映射规则，或者只对「受影响子图」局部重算。

**4. 图查询性能**
2 跳邻域在高连接度节点上会爆炸（一个「中国」节点可能连 10 万条边）。必须限制 `maxLevel`、`limit`，并对高中心度节点做特殊处理（不展开，只取摘要）。

**5. 抽取的一致性**
同一个实体在不同 chunk 里的 `type` 可能不同（ORGANIZATION / COMPANY / 企业）。必须用枚举约束，并在 Prompt 里给 few-shot。

**6. 中文实体边界**
「上海市第一人民医院」被切成「上海市」+「第一人民医院」。中文 NER 比英文难，建议先用领域词典做词典匹配，再让 LLM 补充。

## 九、面试追问

**Q1：GraphRAG 和「知识图谱 + 向量检索」有什么区别？**

传统 KG 是人工/规则构建的，schema 固定，追求准确；GraphRAG 是 LLM 自动抽取的，schema 宽松，追求覆盖。最大区别是**社区摘要**——传统 KG 没有「层次化摘要」这一层，所以回答不了全局问题。

**Q2：为什么用 Leiden 不用 Louvain？**

Louvain 可能产生内部不连通的社区（节点之间没有路径），且层次结构不稳定。Leiden 通过 refinement 阶段保证连通性，并给出更清晰的层次划分。GraphRAG 需要层次结构做「粒度可调查询」，所以必须用 Leiden。

**Q3：GraphRAG 能替代向量 RAG 吗？**

不能。两者互补：向量 RAG 擅长「找相似片段」（细节、原文引用），GraphRAG 擅长「全局总结和多跳关系」。生产上应该是 Hybrid：先用图定位领域，再用向量捞细节。

**Q4：索引成本怎么降？**

四招：便宜模型做抽取、固定 schema 减少输出 token、增量索引只重算受影响社区、分层建图（只对核心文档建图）。最狠的一招是「先用向量 RAG 跑三个月，统计全局问题的占比，再决定要不要上 GraphRAG」。

**Q5：GraphRAG 的「幻觉」比向量 RAG 少吗？**

全局问题上更少（因为有摘要作为事实基础，且要求引用社区 ID）；单点事实上可能更多（抽取过程会丢失上下文）。整体上不是「更少幻觉」，而是「幻觉的类型变了」。

## 结语

GraphRAG 解决的是向量 RAG 的结构性缺陷：**相似度检索天生无法回答「整体」和「关系」**。

但它的成本是真实的：一份文档几美元、一次全量重建几小时、一套图数据库要运维。所以正确的姿势不是「上 GraphRAG」，而是：

1. 先量化「全局型问题」在你业务里的占比；
2. 占比低 → 向量 RAG + 重排 + query 改写，性价比最高；
3. 占比高 → 核心文档建图，其余走向量，做 Hybrid；
4. 无论哪种，**引用溯源和评测集**都是底线。

技术选型的本质不是「哪个更先进」，而是「哪个的边际收益大于边际成本」。GraphRAG 尤其如此。
