---
title: 【Java AI】Embedding 与语义检索深度实战：向量化、相似度度量与增量更新
date: 2026-10-24 08:20:00
tags:
  - Java
  - AI
  - Embedding
  - 语义检索
  - Spring AI
  - 向量检索
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Embedding 与语义检索深度实战：向量化、相似度度量与增量更新

## 前言

`LIKE '%退款%'` 这种检索有个致命缺陷：用户问「钱什么时候退回来」，它一条都匹配不上。**语义检索**要解决的正是这个问题——把文本映射到向量空间，用「距离」代替「字面匹配」。

但真正落地时，Embedding 远不是「调个 API 拿个 float 数组」那么简单。你会踩到这些坑：

- 余弦相似度算出 `0.83`，到底算不算「相关」？阈值怎么定？
- 换了 embedding 模型，为什么老数据全部失效、召回暴跌？
- 文档改了一个字，要不要全量重算 200 万条向量？
- 归一化忘了做，内积和余弦算出来的排序完全不同；
- 1024 维向量存 `float[]`，1000 万条吃掉多少内存？

这篇文章用 Java 视角把这条链路讲透：向量化 → 相似度度量 → 索引 → 增量更新 → 评测。代码基于 Spring AI 的 `EmbeddingModel` 抽象，换模型只需改配置。

---

## 一、Embedding 到底在做什么

Embedding 模型是一个函数：

```
f: text → R^d     d ∈ {384, 768, 1024, 1536, 3072}
```

它把语义压缩成一个稠密向量。训练目标决定了它的核心性质：**语义相近的文本，向量夹角小**。

```
"如何申请退款"     → [0.021, -0.113, ...]  ┐
"退款流程是什么"   → [0.019, -0.108, ...]  ├─ 夹角很小，cos ≈ 0.95
"服务器 CPU 过高"  → [-0.204, 0.331, ...]  ┘  夹角很大，cos ≈ 0.12
```

**四个必须记住的性质：**

| 性质 | 含义 | 工程影响 |
|---|---|---|
| 稠密 | 每一维都参与表达，没有「第 3 维 = 退款」这种可解释性 | 不能靠单维解释，只能整体比距离 |
| 定长 | 同一模型的输出维度固定 | 不同维度**不可混存**，换模型必须重建 |
| 上下文相关 | 同一个词在不同句子里向量不同 | 「苹果手机」和「吃苹果」会被正确区分 |
| 模型绑定 | 不同模型的空间**不可比** | A 模型的向量和 B 模型的向量算距离毫无意义 |

最后一条是新手最容易犯的错，后面会专门讲。

---

## 二、模型选型：先定约束，再选模型

| 模型 | 维度 | 中文效果 | 部署 | 成本 | 适用 |
|---|---|---|---|---|---|
| OpenAI `text-embedding-3-small` | 1536（可降维） | 中 | 云 API | 低 | 通用、快速起步 |
| OpenAI `text-embedding-3-large` | 3072（可降维） | 良 | 云 API | 中 | 精度优先 |
| BGE-M3 | 1024 | **优** | 自部署 | 显卡成本 | 中文/多语言、混合检索 |
| BGE-large-zh-v1.5 | 1024 | **优** | 自部署 | 低 | 纯中文、性价比高 |
| Jina embeddings v3 | 1024 | 良 | 云/自部署 | 中 | 长文本（8k） |
| 通义 `text-embedding-v3` | 1024 | **优** | 云 API | 低 | 国内合规场景 |

**选型决策顺序：**

1. **数据能不能出境**？不能 → 排除 OpenAI；
2. **有没有 GPU**？没有 → 优先云 API；
3. **文本多长**？超过 512 token 且不能切 → 选支持长上下文的（Jina / BGE-M3）；
4. **要不要混合检索**？要 → BGE-M3 自带稀疏 + 稠密 + 多向量，一份模型三种检索；
5. **成本敏感度**？100 万条文档 × 500 token ≈ 5 亿 token，云 API 约几百元，自部署要一张卡。

**关键提醒：选型一旦确定，就别轻易换。** 换模型的迁移成本 = 全量重算 + 重建索引 + 重跑评测，不是改一行配置。

---

## 三、相似度度量：三个公式与一个陷阱

### 3.1 三种度量

**余弦相似度（Cosine Similarity）**——只看方向，忽略长度：

```
cos(a, b) = (a · b) / (‖a‖ × ‖b‖)
```

范围 `[-1, 1]`，越接近 1 越相似。

**内积（Dot Product）**——方向 + 长度：

```
dot(a, b) = Σ aᵢbᵢ
```

范围无界，受向量模长影响。

**欧氏距离（L2）**——空间直线距离：

```
‖a - b‖₂ = √(Σ (aᵢ - bᵢ)²)
```

越小越相似。

### 3.2 那个陷阱：归一化之后，余弦 = 内积

如果所有向量都做了 **L2 归一化**（`‖v‖ = 1`）：

```
cos(a,b) = a·b / (1 × 1) = a·b
‖a-b‖² = ‖a‖² + ‖b‖² - 2a·b = 2 - 2a·b
```

**三个度量在排序上完全等价**。这就是为什么大多数向量库默认用内积（最快，一次点积就够），而文档里又说「用 cosine」——**前提是向量已归一化**。

### 3.3 归一化的两个后果

| 操作 | 后果 |
|---|---|
| 写入时归一化，查询时忘归一化 | 内积排序被长向量主导，**结果错乱** |
| 两边都归一化，但库配置成 `COSINE` | 库内部会再算一次模长，浪费性能（不算错） |
| 不归一化，库配置 `IP` | 长文本天然得分高，**短 query 永远排后面** |

**工程结论：统一在写入和查询两侧都做 L2 归一化，索引配置用内积（IP/DOT）。**

### 3.4 Java 实现

```java
public final class VectorMath {

    private VectorMath() {}

    /** L2 归一化（原地修改，返回同一引用以便链式调用） */
    public static float[] normalize(float[] v) {
        double sum = 0.0;
        for (float x : v) sum += (double) x * x;
        double norm = Math.sqrt(sum);
        if (norm == 0.0) return v;              // 零向量直接返回，避免 NaN
        float inv = (float) (1.0 / norm);
        for (int i = 0; i < v.length; i++) v[i] *= inv;
        return v;
    }

    /** 余弦相似度：兼容未归一化输入 */
    public static double cosine(float[] a, float[] b) {
        if (a.length != b.length) {
            throw new IllegalArgumentException("维度不一致: " + a.length + " vs " + b.length);
        }
        double dot = 0.0, na = 0.0, nb = 0.0;
        for (int i = 0; i < a.length; i++) {
            dot += (double) a[i] * b[i];
            na  += (double) a[i] * a[i];
            nb  += (double) b[i] * b[i];
        }
        if (na == 0.0 || nb == 0.0) return 0.0;
        return dot / (Math.sqrt(na) * Math.sqrt(nb));
    }

    /** 已归一化时用这个，比 cosine 快一倍 */
    public static double dot(float[] a, float[] b) {
        double s = 0.0;
        for (int i = 0; i < a.length; i++) s += (double) a[i] * b[i];
        return s;
    }
}
```

**注意用 `double` 做累加**：1024 维 `float` 累加，`float` 精度损失可能达到 `1e-3` 量级，在阈值边界上会出现「同一对向量两次计算结果不同」的诡异现象。累加器用 `double`，最后再转回 `float`。

### 3.5 用 Vector API 再快 4~8 倍

JDK 16+ 的 `jdk.incubator.vector` 能把点积向量化（SIMD）：

```java
import jdk.incubator.vector.FloatVector;
import jdk.incubator.vector.VectorSpecies;

public final class SimdDot {
    private static final VectorSpecies<Float> SPECIES = FloatVector.SPECIES_PREFERRED;

    public static float dot(float[] a, float[] b) {
        int i = 0;
        FloatVector acc = FloatVector.zero(SPECIES);
        int bound = SPECIES.loopBound(a.length);
        for (; i < bound; i += SPECIES.length()) {
            acc = acc.add(FloatVector.fromArray(SPECIES, a, i)
                                   .mul(FloatVector.fromArray(SPECIES, b, i)));
        }
        float sum = acc.reduceLanes(jdk.incubator.vector.VectorOperators.ADD);
        for (; i < a.length; i++) sum += a[i] * b[i];   // 尾部标量处理
        return sum;
    }
}
```

实测在 1024 维上，单次点积从 ~600ns 降到 ~90ns。但**这只是暴力扫描场景有意义**——如果你用了 HNSW 索引，瓶颈在索引遍历不在距离计算。所以：数据量 < 10 万时可以暴力 + SIMD，超过就上向量索引。

---

## 四、Spring AI 落地：EmbeddingModel

### 4.1 依赖与配置

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-model-openai</artifactId>
</dependency>
```

```yaml
spring:
  ai:
    openai:
      api-key: ${OPENAI_API_KEY}
      embedding:
        options:
          model: text-embedding-3-small
          dimensions: 1024          # 3-small 支持降维，省存储
```

### 4.2 批量向量化 + 缓存

```java
@Service
@RequiredArgsConstructor
public class EmbeddingService {

    private final EmbeddingModel embeddingModel;
    private final EmbeddingCache cache;      // 本地 Caffeine + Redis 二级

    /** 单条 */
    public float[] embed(String text) {
        return embedAll(List.of(text)).get(0);
    }

    /** 批量：一次请求带 64 条，比逐条快 10 倍以上 */
    public List<float[]> embedAll(List<String> texts) {
        List<float[]> result = new ArrayList<>(texts.size());

        // 1. 先查缓存，命中的直接复用
        Map<String, float[]> hit = cache.getAll(texts);
        List<String> miss = new ArrayList<>();
        for (String t : texts) if (!hit.containsKey(t)) miss.add(t);

        // 2. 未命中的批量请求
        if (!miss.isEmpty()) {
            List<float[]> computed = new ArrayList<>(miss.size());
            for (int from = 0; from < miss.size(); from += 64) {
                int to = Math.min(from + 64, miss.size());
                EmbeddingResponse resp = embeddingModel.embedForResponse(miss.subList(from, to));
                for (Embedding e : resp.getResults()) {
                    computed.add(normalize(e.getOutput()));
                }
            }
            for (int i = 0; i < miss.size(); i++) {
                cache.put(miss.get(i), computed.get(i));
            }
            // 3. 组装
            int k = 0;
            for (String t : texts) {
                float[] v = hit.get(t);
                result.add(v != null ? v : computed.get(k++));
            }
        } else {
            for (String t : texts) result.add(hit.get(t));
        }
        return result;
    }

    private float[] normalize(float[] v) {
        return VectorMath.normalize(v);
    }
}
```

**为什么必须缓存**：知识库重建时，90% 的 chunk 内容没变，重复调用 API 纯属浪费。用「**内容 SHA-256 做 key**」，内容不变就命中。

### 4.3 批量大小的权衡

| 批量 | 请求数 | 单请求延迟 | 总耗时 | 备注 |
|---|---|---|---|---|
| 1 | 10000 | 120ms | 20min | 不可接受 |
| 16 | 625 | 200ms | 2min | 保守 |
| 64 | 157 | 450ms | 70s | **推荐** |
| 256 | 40 | 1.8s | 72s | 易触发限流、超时 |
| 2048 | 5 | 12s | 60s | 大概率 429 / 超时 |

**结论：32~64 是甜点区。** 再大就会撞上 provider 的 token 上限和速率限制，重试成本超过收益。

---

## 五、索引：HNSW 的三个参数

暴力扫描 `O(n·d)`，100 万条 × 1024 维 = 每次查询 10 亿次乘加，约 300ms。不可接受。所以需要近似最近邻（ANN）索引，主流是 **HNSW**。

| 参数 | 含义 | 调大 | 调小 |
|---|---|---|---|
| `M` | 每个节点的邻居数 | 召回↑、内存↑、构建慢 | 召回↓、内存↓ |
| `efConstruction` | 构建时的候选队列长度 | 图质量↑、构建慢 | 构建快、质量差 |
| `efSearch` | 查询时的候选队列长度 | 召回↑、延迟↑ | 延迟↓、召回↓ |

**经验值：**

```
M                = 16 ~ 32      (默认 16 够用，高召回场景 32)
efConstruction   = 200 ~ 400
efSearch         = 64 ~ 128     (可运行时调整，这是你的调优旋钮)
```

**`efSearch` 是唯一能在线调的参数**：召回不够就调大，延迟超标就调小。上线后用它做「召回率 vs P99 延迟」的权衡。

**存储估算**（1000 万条 × 1024 维）：

```
原始向量: 10^7 × 1024 × 4B  = 40 GB
HNSW 图:  10^7 × 32 × 2 × 4B ≈ 2.5 GB
元数据:   10^7 × ~200B      ≈ 2 GB
合计:     ≈ 45 GB（单副本）
```

**这就是为什么大模型 embedding 要降维**：3072 → 1024 直接省 2/3 存储，而召回率通常只掉 1~2 个点。

---

## 六、增量更新：全量重算是最贵的错误

### 6.1 问题

知识库 200 万 chunk，每天有 500 篇文档变更。如果每晚全量重算：

- 20 亿 token 的 embedding 成本（约几千元/月）；
- 索引重建期间检索不可用；
- 完全没必要。

### 6.2 增量方案：内容指纹 + 差量同步

```java
public record Chunk(
        String id,           // 稳定 ID：docId + ":" + chunkIndex
        String docId,
        int index,
        String content,
        String contentHash,  // SHA-256(content + 切分策略版本 + 模型版本)
        float[] vector,
        long updatedAt
) {}
```

**关键设计：`contentHash` 要把「模型版本」和「切分策略版本」算进去。**

```java
public String hashOf(String content, String modelVersion, String splitterVersion) {
    String raw = modelVersion + "|" + splitterVersion + "|" + content;
    return DigestUtils.sha256Hex(raw);
}
```

这样当模型升级时，所有 hash 自动变化，增量任务会自然地把全部 chunk 标记为「需要重算」——**不需要单独写一条全量重建的代码路径**。

### 6.3 同步流程

```java
@Service
@RequiredArgsConstructor
public class IndexSyncService {

    private final ChunkRepository chunkRepo;        // DB：当前期望状态
    private final VectorStore vectorStore;          // 向量库：当前实际状态

    @Transactional
    public SyncReport syncDocument(String docId, String newContent) {
        List<Chunk> desired = splitter.split(docId, newContent);   // 新切分结果

        Map<String, Chunk> existing = vectorStore.listByDocId(docId).stream()
                .collect(Collectors.toMap(Chunk::id, c -> c));

        List<Chunk> toUpsert = new ArrayList<>();
        for (Chunk c : desired) {
            Chunk old = existing.get(c.id());
            // 内容/模型/切分策略变化 → 需要重新向量化
            if (old == null || !old.contentHash().equals(c.contentHash())) {
                toUpsert.add(c.withVector(embeddingService.embed(c.content())));
            }
        }

        // 已被删除的 chunk（文档变短，或切分点变化）
        Set<String> desiredIds = desired.stream().map(Chunk::id).collect(Collectors.toSet());
        List<String> toDelete = existing.keySet().stream()
                .filter(id -> !desiredIds.contains(id))
                .toList();

        // 先写后删：保证任何时刻检索都能命中（可用性优先）
        vectorStore.upsert(toUpsert);
        vectorStore.deleteByIds(toDelete);
        chunkRepo.replaceAll(docId, desired);

        return new SyncReport(docId, toUpsert.size(), toDelete.size());
    }
}
```

**为什么「先写后删」**：如果先删后写，中间有几百毫秒窗口期，用户查这个文档会「查不到」。反之则最多查到一点旧内容，用户体验更好。

### 6.4 文档级「软删除」与一致性

向量库和业务库是两个系统，没有分布式事务。用「**版本号 + 软删除**」兜底：

```sql
-- 业务库
UPDATE t_document SET status = 'DELETED', version = version + 1 WHERE id = ?;
```

```java
// 向量库：不物理删，打标记；检索时用 filter 过滤
vectorStore.deleteByFilter("docId == '" + docId + "' && version < " + newVersion);
```

检索侧加过滤条件，即使删除消息丢了，也不会召回已删文档。**物理删除交给定时的 GC 任务**。

### 6.5 变更捕获：别用定时全表扫描

| 方案 | 延迟 | 侵入性 | 适用 |
|---|---|---|---|
| 定时全表 diff | 分钟~小时 | 低 | 小数据量 |
| 业务双写（更新 DB 后发 MQ） | 秒 | 中 | 主流方案 |
| CDC（Debezium / Canal 订阅 binlog） | 亚秒 | **零侵入** | 大数据量、多消费方 |

**推荐 CDC**：文档变更本来就在 binlog 里，用 Canal/Debezium 抽出来投到 Kafka，消费端做「防抖合并」（同一文档 5 秒内多次变更只处理最后一次），避免一篇文章保存 10 次就触发 10 次向量化。

---

## 七、评测：阈值不是拍脑袋定的

「相似度 0.8 以上算相关」——这句话没有任何依据。**阈值必须从数据里算出来。**

### 7.1 构造黄金集

```java
public record GoldenCase(String query, Set<String> relevantChunkIds) {}
```

准备 200~500 条真实用户 query，人工标注「哪些 chunk 是相关的」。这是整个 RAG 系统最值钱的资产。

### 7.2 三个指标

```java
public record EvalResult(double recallAt10, double mrr, double ndcgAt10) {}

public EvalResult evaluate(List<GoldenCase> cases, int k) {
    double recallSum = 0, mrrSum = 0;
    for (GoldenCase c : cases) {
        List<String> hits = vectorStore.similaritySearch(c.query(), k)
                .stream().map(Document::getId).toList();

        long matched = hits.stream().filter(c.relevantChunkIds()::contains).count();
        recallSum += (double) matched / c.relevantChunkIds().size();

        for (int i = 0; i < hits.size(); i++) {
            if (c.relevantChunkIds().contains(hits.get(i))) {
                mrrSum += 1.0 / (i + 1);
                break;
            }
        }
    }
    return new EvalResult(recallSum / cases.size(), mrrSum / cases.size(), 0);
}
```

| 指标 | 含义 | 目标 |
|---|---|---|
| **Recall@10** | 前 10 条里覆盖了多少相关文档 | > 0.85 |
| **MRR** | 第一个相关结果排多靠前 | > 0.7 |
| **NDCG@10** | 考虑排序位置的整体质量 | > 0.75 |

### 7.3 用评测定阈值

把黄金集的所有 (query, 相关/不相关 chunk) 相似度画成分布，找 **F1 最大的分界点**：

```java
double bestThreshold = 0, bestF1 = 0;
for (double t = 0.50; t <= 0.95; t += 0.01) {
    int tp = 0, fp = 0, fn = 0;
    for (GoldenCase c : cases) {
        for (Document d : vectorStore.similaritySearch(c.query(), 50)) {
            boolean predicted = d.getScore() >= t;
            boolean actual = c.relevantChunkIds().contains(d.getId());
            if (predicted && actual) tp++;
            else if (predicted) fp++;
            else if (actual) fn++;
        }
    }
    double f1 = tp == 0 ? 0 : 2.0 * tp / (2.0 * tp + fp + fn);
    if (f1 > bestF1) { bestF1 = f1; bestThreshold = t; }
}
```

**经验数据**：中文 BGE 系列在通用问答上，`0.6~0.7` 往往是 F1 峰值；OpenAI small 在 `0.75~0.82`。差异很大，**必须自己测**。

---

## 八、八个生产踩坑

### 坑 1：换模型后老向量没重算

新 query 用 B 模型编码，库里是 A 模型的向量。余弦相似度还能算出来（维度一样），但**排序完全是噪声**。

表现：召回率从 0.85 掉到 0.15，日志里一切正常。

**防线**：向量记录里存 `model_version`，检索时用 filter 限定，或者直接按版本建两个索引做灰度对比。

### 坑 2：归一化不一致

写入归一化了，查询没归一化。内积检索时，长 query 的模长大，得分被放大，短 query 永远排后面。

**防线**：把归一化封在 `EmbeddingService` 里，**对外只暴露已归一化的向量**，杜绝「有人忘了调」。

### 坑 3：不同维度混存

`text-embedding-3-small` 支持 `dimensions=512/1024/1536`。有人写 512 有人写 1536，同一个索引里混着存，直接报错或静默截断。

**防线**：维度写进索引元数据，启动时校验。

### 坑 4：超长文本被静默截断

模型有 token 上限（通常 512 或 8192）。一段 3000 字的文档直接丢进去，**后半段完全没进向量**，检索时永远召回不到。

**防线**：切分时按 token 计数（不是字符数），并且 `chunkSize < maxTokens × 0.8`。

### 坑 5：只做向量检索，丢掉关键词

用户搜「错误码 E1024」，向量模型可能把它和「E1025」编码得很近，但精确匹配只有关键词检索能做到。

**防线**：混合检索（BM25 + 向量），用 RRF（Reciprocal Rank Fusion）融合：

```java
// RRF: score = Σ 1 / (k + rank_i)，k 通常取 60
Map<String, Double> fused = new HashMap<>();
for (int i = 0; i < vectorHits.size(); i++)
    fused.merge(vectorHits.get(i).id(), 1.0 / (60 + i + 1), Double::sum);
for (int i = 0; i < keywordHits.size(); i++)
    fused.merge(keywordHits.get(i).id(), 1.0 / (60 + i + 1), Double::sum);
```

### 坑 6：增量更新漏了「切分点漂移」

文档中间插入一段，后面的 chunk 索引全变了，但 `id` 如果只用 `docId + index`，会导致**内容错位复用**（旧 chunk 的向量被当成新内容的）。

**防线**：`id` 用 `docId + hash(content)` 或者「先删后写整个文档的所有 chunk」。前者更省，后者更稳。

### 坑 7：删除没有传播到向量库

DB 里删了，向量库还留着。用户问到了已删除的文档，直接是**数据泄露**级别的 bug。

**防线**：检索侧永远带 `status = 'ACTIVE'` 的 filter，物理删除靠 GC。这是最后一道防线。

### 坑 8：拿相似度当「置信度」

`0.85` 不代表「85% 确信」。向量相似度和事实正确性之间没有标定（calibration）关系。用相似度做「要不要回答」的门槛，必须配合**生成侧的引用校验**（回答里的每个断言都能在检索片段中找到依据）。

---

## 九、面试常见追问

**Q1：为什么 embedding 要做归一化？**

因为归一化后余弦相似度等价于内积，向量库可以用更快的点积计算；同时消除文本长度对得分的影响（长文本的向量模长往往更大），让不同长度的片段可比。

**Q2：余弦相似度和欧氏距离什么时候不等价？**

只有在向量都已归一化时才等价（单调对应）。未归一化时，模长差异会让两种度量的排序不同。

**Q3：为什么要用 double 累加？**

1024 维 `float` 逐项累加，舍入误差会累积。理论上误差约 `n·ε·Σ|aᵢbᵢ|`，在阈值附近足以改变判定结果。用 `double` 累加成本可忽略，收益是结果稳定可复现。

**Q4：HNSW 的 `efSearch` 和 `M` 有什么区别？**

`M` 是图的度数（构建时定，影响内存和图质量）；`efSearch` 是查询时的候选队列长度（运行时可调，直接影响召回与延迟）。调优先动 `efSearch`，因为不用重建索引。

**Q5：换 embedding 模型要做什么？**

四步：全量重算向量、重建索引、重跑黄金集评测、灰度对比召回率。**没有捷径**，因为不同模型的空间不可比。

**Q6：增量更新怎么保证不漏？**

三层：CDC 保证变更捕获、内容指纹保证「该更新的都更新」、定时全量对账（每周一次，比对 chunk 数量和 hash）兜底。前两层是常态，第三层是保险。

**Q7：1000 万文档怎么选向量库？**

看四个维度：过滤能力（权限场景必备）、混合检索、运维成本、水平扩展。具体选型对比见本站《向量数据库选型深度对比》一文，这里只强调一点：**权限过滤必须在检索时下推，不能查完再过滤**。

---

## 十、总结

Embedding 与语义检索的链路，可以压缩成六个决策点：

| 决策 | 关键结论 |
|---|---|
| 选模型 | 先看数据出境、GPU、文本长度，再谈精度 |
| 度量 | 统一 L2 归一化 + 内积，累加用 `double` |
| 索引 | HNSW 起步，`M=16/32`、`efSearch=64~128` 在线调 |
| 批量 | 32~64 条一批，配内容哈希缓存 |
| 更新 | 内容指纹 + 差量 upsert + 先写后删 + 软删除兜底 |
| 评测 | 黄金集 + Recall/MRR，用 F1 定阈值，别拍脑袋 |

最后一句最重要的话：**Embedding 不是「调个 API」，而是一次「模型选择 + 索引设计 + 数据治理」的长期承诺。** 模型版本要写进数据里，切分策略要版本化，增量更新要能自证没漏。把这些基础设施做扎实，后面的 RAG、Agent 检索、推荐才有地基。
