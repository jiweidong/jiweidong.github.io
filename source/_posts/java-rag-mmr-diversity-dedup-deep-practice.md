---
title: 【Java AI】检索结果去重与多样性深度实战：MMR、近重复检测与来源配额
date: 2026-11-28 08:15:00
tags:
  - Java
  - AI
  - RAG
  - 检索
  - MMR
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】检索结果去重与多样性深度实战

## 前言

一个内部制度问答上线两周，用户反馈最多的问题是：「答案翻来覆去就那两句。」

把一次请求的检索结果打出来看：

```
top-10:
1. 【员工手册 v3.2】第 4.2 节 年假规定 ...        score 0.834
2. 【员工手册 v3.2】第 4.2 节 年假规定（续）...    score 0.821
3. 【员工手册 v2.9】第 4.2 节 年假规定 ...        score 0.803
4. 【员工手册 v3.0】第 4.2 节 年假规定 ...        score 0.798
5. 【HR 政策汇编】年假相关条款 ...                score 0.776
...
```

十条里八条在讲同一件事，其中三条是同一份文档的相邻分块，两条是历史版本。模型看到这样的上下文，只能把同一句话说六遍；而真正有用的「年假与调休的抵扣规则」「跨年结转上限」根本没进 top-10。

这不是 embedding 的问题，也不是 reranker 的问题。**这是「集合后处理」缺失**：向量检索天然会返回一堆语义上高度相似的片段，因为相似度高的东西本来就长得像。

这篇讲三层去重（精确 / 近重复 / 语义）和两种多样性控制（MMR / 来源配额），全部给可运行的 Java 实现，并说清楚阈值怎么定、指标怎么评、以及和相邻能力的边界。

> 分工说明：站内已有《混合检索与 RRF 融合》《Reranker 重排》《Query Rewriting / HyDE》《父子分块》。本篇只讲**候选集已经拿到之后**的去重与多样性重排，属于「集合后处理」这一层。

---

## 一、冗余的三种形态

先把问题分类，因为解法完全不同。

| 形态 | 例子 | 检测手段 | 危害 |
|---|---|---|---|
| 段落级近重复 | 同一份 PDF 的相邻 chunk 有 60% 重叠（滑窗造成） | 内容 hash / SimHash / shingle Jaccard | 白占上下文预算 |
| 版本级重复 | v3.2 与 v2.9 的同一章节 | 文档指纹 + 版本元数据 | 给出**过期**答案 |
| 语义级冗余 | 三份文件用不同措辞说同一件事 | 向量余弦 / 聚类 | 稀释证据多样性 |
| 来源偏斜 | 一个大文档占了 top-10 的 8 条 | docId 配额统计 | 引用看起来多、其实单源 |

四种形态里，**版本级重复最危险**，因为它不只是浪费预算，还会让模型把已废止的规定当现行规定答出来。所以元数据过滤必须放在去重之前，不能靠相似度解决。

---

## 二、三层去重

### 第一层：精确去重（零成本）

分块时就应该做：

```java
public record Chunk(String chunkId, String docId, String version,
                    String text, float[] vector) {}

// 内容指纹：归一化后取 SHA-256 前 128 位
static String fingerprint(String text) {
    String norm = text.replaceAll("\\s+", "")
                      .replaceAll("[\\p{Punct}，。；：！？、]", "")
                      .toLowerCase(Locale.ROOT);
    byte[] d = MessageDigest.getInstance("SHA-256").digest(norm.getBytes(UTF_8));
    return HexFormat.of().formatHex(d, 0, 16);
}
```

同时建两个唯一键：

- `(docId, version, chunkIndex)` → 幂等写入
- `fingerprint` → 内容去重（跨文档也能拦）

精确去重能解决滑窗重叠的一部分，但解决不了「改了两个字的同一段」。

### 第二层：近重复（SimHash + 汉明距离）

SimHash 的思路：把文本切成 shingle，每个 shingle 哈希成 64 位，按权重对每一位投票，得到 64 位指纹；**相似文本的指纹汉明距离小**。

```java
public final class SimHash {

    private static final int BITS = 64;

    public static long of(String text, int shingleSize) {
        String[] tokens = tokenize(text);            // 中文按 2-gram，英文按词
        int[] votes = new int[BITS];
        Map<String, Integer> tf = new HashMap<>();
        for (int i = 0; i + shingleSize <= tokens.length; i++) {
            StringBuilder sb = new StringBuilder();
            for (int j = 0; j < shingleSize; j++) sb.append(tokens[i + j]).append('\u0001');
            tf.merge(sb.toString(), 1, Integer::sum);
        }
        for (var e : tf.entrySet()) {
            long h = murmur3_128(e.getKey().getBytes(UTF_8))[0];  // 取低 64 位
            for (int b = 0; b < BITS; b++) {
                votes[b] += ((h >>> b) & 1L) == 1L ? e.getValue() : -e.getValue();
            }
        }
        long fp = 0L;
        for (int b = 0; b < BITS; b++) if (votes[b] > 0) fp |= (1L << b);
        return fp;
    }

    public static int hamming(long a, long b) {
        return Long.bitCount(a ^ b);
    }
}
```

阈值经验值（64 位）：

| 汉明距离 | 语义 |
|---|---|
| 0–2 | 几乎逐字相同（滑窗重叠 / 复制粘贴） |
| 3–6 | 高度相似（改了几个词 / 加了标点） |
| 7–12 | 主题相同但内容不同（不应去重） |
| > 12 | 不同内容 |

**建议阈值 3**。设成 6 会误杀「同一主题不同条款」，设成 1 又拦不住改写。

数据量大时不能两两比较（O(n²)），用 **band LSH**：把 64 位切成 b 段，只要有一段完全相同就进同一个桶。b=4、每段 16 位时，距离 ≤3 的碰撞概率约 1-(1-...)，实践中足够。

```java
static Map<Long, List<Chunk>> lshBuckets(List<Chunk> chunks, int bands) {
    int width = 64 / bands;
    Map<Long, List<Chunk>> buckets = new HashMap<>();
    for (Chunk c : chunks) {
        long fp = SimHash.of(c.text(), 2);
        for (int i = 0; i < bands; i++) {
            long key = ((fp >>> (i * width)) & ((1L << width) - 1)) | ((long) i << 56);
            buckets.computeIfAbsent(key, k -> new ArrayList<>()).add(c);
        }
    }
    return buckets;
}
```

### 第三层：语义去重（向量余弦）

对候选集两两算余弦（候选只有 30–100 条，O(n²) 完全可接受），相似度超过阈值就只保留分数最高的代表：

```java
static List<Chunk> semanticDedup(List<Chunk> scored, double threshold, int keep) {
    List<Chunk> out = new ArrayList<>();
    for (Chunk c : scored) {                       // 已按相关性降序
        boolean dup = false;
        for (Chunk kept : out) {
            if (cosine(c.vector(), kept.vector()) >= threshold) { dup = true; break; }
        }
        if (!dup) {
            out.add(c);
            if (out.size() >= keep) break;
        }
    }
    return out;
}
```

阈值怎么定？**不要拍脑袋**。取一份标注集（同一 query 的候选对，人工标「是否重复」），扫 0.85–0.99，画 precision/recall 曲线，取 F1 最优点。经验上中文长文本落在 **0.93–0.96**，短句（<30 字）会低一些但更不稳。

> 关键细节：余弦计算前先做 L2 归一化，之后点积即余弦，用 `jdk.incubator.vector` 的 `FloatVector` 可以再快 3–5 倍；100 维以内的候选集其实没必要优化。

---

## 三、MMR：把「相关性」和「新颖性」放在一起排序

去重是硬删除，MMR 是软权衡：它不删，而是**在每一步选「既相关又不重复」的下一个**。

公式：

```
MMR = argmax_{d ∈ R\S} [ λ · sim(d, q) − (1 − λ) · max_{s ∈ S} sim(d, s) ]
```

- `R`：候选集，`S`：已选集合
- `sim(d, q)`：相关性（检索分或 rerank 分）
- `sim(d, s)`：与已选项的最大相似度（冗余度）
- `λ ∈ [0,1]`：1.0 纯相关性（等于不做事），0.5 平衡，0.3 偏多样性

### Java 实现

```java
public final class MmrSelector {

    public static List<Chunk> select(List<Chunk> candidates, float[] queryVec,
                                     int k, double lambda) {
        int n = candidates.size();
        // 1) 相关性分数归一化到 [0,1]，否则和余弦不在同一量纲
        double[] rel = normalize(candidates.stream().mapToDouble(Chunk::score).toArray());
        // 2) 预先算好候选之间的相似度矩阵（n<=100 时内存可忽略）
        double[][] sim = new double[n][n];
        for (int i = 0; i < n; i++)
            for (int j = i + 1; j < n; j++) {
                double s = cosine(candidates.get(i).vector(), candidates.get(j).vector());
                sim[i][j] = sim[j][i] = s;
            }

        List<Chunk> selected = new ArrayList<>(k);
        boolean[] used = new boolean[n];

        // 第一条取相关性最高的
        int first = argmax(rel, used);
        selected.add(candidates.get(first));
        used[first] = true;

        while (selected.size() < k) {
            int best = -1;
            double bestScore = Double.NEGATIVE_INFINITY;
            for (int i = 0; i < n; i++) {
                if (used[i]) continue;
                double maxSim = 0;
                for (int j = 0; j < n; j++) {
                    if (used[j]) maxSim = Math.max(maxSim, sim[i][j]);
                }
                double mmr = lambda * rel[i] - (1 - lambda) * maxSim;
                if (mmr > bestScore) { bestScore = mmr; best = i; }
            }
            if (best < 0) break;
            selected.add(candidates.get(best));
            used[best] = true;
        }
        return selected;
    }
}
```

### 三个容易做错的地方

1. **量纲不统一**。检索分可能是 BM25（0–30）、cosine（0–1）、rerank logit（-10–10）。直接代入公式，`λ` 就失去意义。必须先归一化（min-max 或 RRF 排名分）。
2. **`maxSim` 的初始值**。第一条之后 `S` 非空，`maxSim` 从 0 起是对的（余弦可能为负，负相似度不该被当成「更不多样」）。若要处理负相关，用 `Math.max(maxSim, sim)` 且初值设 `-1`。
3. **λ 不是越小越好**。λ=0.3 时排序几乎只看多样性，会把「勉强相关但角度不同」的段落排到前面，反而丢掉关键证据。制度类问答建议 **0.6–0.75**，探索型问答（头脑风暴、方案对比）可以到 0.4。

### λ 怎么调

用一个小的 golden set（50–100 条 query + 标注的标准答案所在 chunk）：

| 指标 | 说明 |
|---|---|
| Recall@k（gold chunk 是否在结果里） | 保底线，λ 降低时最先恶化 |
| 覆盖率（答案要点被覆盖的比例） | 多样性的收益 |
| distinct-source@k（不同 docId 数量） | 来源多样性 |
| 平均答案正确率（LLM-as-Judge） | 最终指标 |

做法：λ ∈ {0.4, 0.5, 0.6, 0.7, 0.8, 0.9} 各跑一遍，选「Recall 不低于基线 2 个点、覆盖率最高」的那个。**不要只优化覆盖率**，那是拿准确性换花哨。

---

## 四、来源配额：硬约束比软偏好更可靠

MMR 是软偏好，遇到「一个大文档里有 30 个高相关片段」时，它仍然可能选出 6 条同源。有些场景需要硬约束：

```java
public static List<Chunk> quotaSelect(List<Chunk> scored, int k,
                                      int perDocMax, int perSourceMax) {
    List<Chunk> out = new ArrayList<>(k);
    Map<String, Integer> byDoc = new HashMap<>();
    Map<String, Integer> bySource = new HashMap<>();
    Deque<Chunk> overflow = new ArrayDeque<>();

    for (Chunk c : scored) {
        int dc = byDoc.getOrDefault(c.docId(), 0);
        int sc = bySource.getOrDefault(c.source(), 0);
        if (dc < perDocMax && sc < perSourceMax) {
            out.add(c);
            byDoc.merge(c.docId(), 1, Integer::sum);
            bySource.merge(c.source(), 1, Integer::sum);
            if (out.size() == k) return out;
        } else {
            overflow.add(c);          // 先存着，用于回填
        }
    }
    // 去重/配额导致不足 k 条时，用溢出队列回填，保证不饿死
    while (out.size() < k && !overflow.isEmpty()) out.add(overflow.poll());
    return out;
}
```

配额取值建议：

- `perDocMax = 2~3`：同一文档最多两三条，避免单文档垄断。
- `perSourceMax = 4~6`：同一来源（部门/站点）最多几条。
- **必须回填**：否则在「知识库只有一份相关文档」的场景下会返回 2 条就结束，召回直接崩掉。

配额和 MMR 的顺序：**先去重 → 再配额 → 最后 MMR**。反过来的话，MMR 选出来的集合会破坏配额约束。

---

## 五、工程链路应该长什么样

```
向量召回 (k'=3k) ──┐
BM25 召回 (k'=3k) ─┼─> RRF 融合 ─> 精确/近重复去重 ─> rerank(top 50)
                   │                                              │
                   └──────────────────────────────────────────────┘
                                                                  ↓
                                              语义去重 ─> 来源配额 ─> MMR ─> top-k
```

几个关键决策：

1. **召回要放大**。去重和配额都会减量，`k' = 3k` 起步；重排模型贵的话，先去重再 rerank，能省 30%–50% 的 rerank 调用。
2. **去重放在 rerank 之前**，是为了省钱；**语义去重放在 rerank 之后**，是因为 rerank 分数更可靠，保留代表项时应该留 rerank 分最高的那条。
3. **MMR 放最后**，因为它是「选取」而不是「过滤」，需要完整的候选集。
4. **向量相似度矩阵可以缓存**：同一 query 的多轮对话里，候选集往往高度重叠，按 `(queryHash, chunkId)` 缓存能省掉重复计算。

---

## 六、评测：多样性必须被度量，否则一定会退化

只看 Recall/准确性，去重和多样性永远会被当成「没用的额外步骤」而被关掉。必须补两个维度：

| 类别 | 指标 | 计算 |
|---|---|---|
| 相关性 | Recall@k、nDCG@k | 标准做法 |
| 多样性 | distinct-doc@k | 结果里不同 docId 数 / k |
| 多样性 | α-nDCG | 对重复子主题做惩罚的 nDCG 变体 |
| 冗余 | redundancy@k | 两两余弦 > 阈值 的比例 |
| 成本 | token 消耗 / 上下文利用率 | 去重后同样 k 条的有效信息量 |

在线侧再加两个业务指标：

- **答案重复率**：同一回答里重复句子占比（可用 n-gram 重叠近似）。
- **引用覆盖数**：回答里引用的不同来源数量。制度类问题理想值是 2–4，低于 2 说明单源偏斜没治好。

---

## 七、六个踩坑

1. **把「否定版本」当重复去掉**。v3.2 写「年假 10 天」，v2.9 写「年假 7 天」，语义相似度 0.97，但它们**结论相反**。必须在去重前按 `version` 元数据过滤（只留最新有效版本），相似度不能解决版本问题。
2. **SimHash 用在短文本上**。<50 字时 shingle 数量太少，指纹不稳定，汉明距离随机性大。短文本改用「归一化后精确匹配 + 向量余弦」。
3. **去重后不足 k 条直接返回**。用户看到 3 条结果，以为知识库没有资料，实际是被去重吃掉了。必须回填。
4. **MMR 用未归一化的分数**。BM25 分数 20 和 cosine 0.9 混在一起，λ 完全失效。
5. **引用编号错位**。去重/重排后 chunk 顺序变了，但 prompt 里的 `[1][2]` 还是旧顺序，答案引用全错。**引用编号必须在最终集合确定之后统一分配**，并保留 `chunkId → 编号` 的映射用于溯源。
6. **忽略「同一文档不同章节」的价值**。同一份规范的第 3 章和第 7 章可能都相关，`perDocMax=1` 会砍掉关键条款。按 `docId + section` 做配额粒度更合理。

---

## 八、面试追问

**Q1：为什么向量检索会返回大量重复内容？**
因为 embedding 是「语义相似」的度量，同一段话的不同版本、相邻分块、不同措辞，在向量空间里本来就非常接近。相似度高 ≠ 信息增量高。

**Q2：MMR 和 reranker 有什么区别？**
Reranker 只看「query 与文档的相关性」，是 pointwise/pairwise 打分；MMR 看「文档集合内部的关系」，是 listwise 的选择策略。两者互补，通常 rerank 在前、MMR 在后。

**Q3：去重阈值怎么定？**
用标注集扫阈值取 F1 最优点，不要用经验值上线。不同语料（法律条文 vs 聊天记录）最优阈值差很远。

**Q4：MMR 的时间复杂度？**
朴素实现 O(k·n²)（每轮对每个候选算与已选集合的最大相似度）。n=100、k=10 时约 10 万次余弦，可忽略；n 到几千时要用「预计算相似度矩阵 + 增量维护 maxSim」降到 O(k·n)。

**Q5：为什么来源配额要放在 MMR 之前？**
配额是硬约束，MMR 是软偏好。先配额保证「不偏斜」，再 MMR 保证「不冗余」，顺序反了会导致 MMR 选出同源集合、配额再砍掉一半、结果不足 k 条。

---

## 小结

- 冗余有四种形态，**版本级重复最危险**，必须用元数据解决，不能靠相似度；
- 三层去重各司其职：精确 hash（零成本）、SimHash（近重复，阈值 3）、向量余弦（语义，0.93–0.96）；
- MMR 是「相关性 vs 新颖性」的软权衡，**前提是分数归一化**，λ 用 golden set 调；
- 来源配额是硬约束，能治单源偏斜，但**必须回填**；
- 链路顺序：召回放大 → 融合 → 去重 → rerank → 语义去重 → 配额 → MMR；
- 多样性必须被度量（distinct-doc、α-nDCG、答案重复率），否则它一定会在某次「简化」中被删掉。

RAG 的上半场是「能不能召回到」，下半场是「召回来的东西值不值得占上下文」。去重和多样性，就是下半场的基本功。
