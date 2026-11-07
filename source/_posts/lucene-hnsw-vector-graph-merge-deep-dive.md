---
title: 【Java 底层】Lucene HNSW 向量图构建与 Merge 深度解析：邻居选择、分层图与增量合并
date: 2026-11-07 08:00:00
tags:
  - Java
  - Lucene
  - HNSW
  - 向量检索
  - 搜索引擎
categories:
  - Java 深挖
author: 东哥
---

# 【Java 底层】Lucene HNSW 向量图构建与 Merge 深度解析

## 前言：向量检索的"最后一公里"其实在段合并

大多数人聊向量检索，聊的是 Embedding 模型、距离度量、Milvus/Qdrant 选型。这些当然重要，但如果你用的是 Elasticsearch、OpenSearch，或者直接在 JVM 里用 Lucene，那么决定**召回质量与查询延迟**的，往往是另一件事：**HNSW 图是怎么被构建、又是怎么在段合并（merge）时被重建的**。

我遇到过一个很典型的问题：同一批 200 万条向量，写入 ES 后 `knn` 查询召回率只有 0.82，而用 hnswlib 离线建库能到 0.95。索引参数看着一模一样（m=16, ef_construction=100）。最后定位到两个原因：

1. **段太多**：每个段各自建一张小图，查询时要跨段合并 top-k，小图的连通性差，召回自然下降；
2. **merge 策略没调**：默认 TieredMergePolicy 频繁合并，每次合并都把 HNSW 图**重建**一遍，CPU 飙到 100%，写入被拖死。

这篇就把 Lucene 的 HNSW 实现从"图怎么建"讲到"merge 怎么合"，最后给一份可运行的 Java 代码和调优清单。

## 一、Lucene 的向量索引长什么样

### 1.1 文件结构

Lucene 9 之后向量索引由 `KnnVectorsFormat` 负责，默认实现是 `Lucene99HnswVectorsFormat`（后续版本有 `Lucene101/102/103` 的迭代优化）。每个段生成两类文件：

- `.vec`：元数据 + 原始向量 + HNSW 图
- `.vex` / `.vem`：向量的索引/元数据辅助文件（不同版本略有差异）

`.vec` 内部的布局大致是：

```
[Header]
[Vector data]     // float32 或 int8，按 docId 连续存放
[Graph data]      // 按层存放：level 0 全部节点，level 1 部分节点 ...
[Footer]
```

关键点：**图里的节点编号不是 docId，而是"层内序号"**。level 0 包含所有文档，序号即 docId 的压缩排列；level 1 只包含被随机抽中的那部分节点，序号重新从 0 开始。这带来一个后果——**删除文档后，图不会立刻变化**，只是查询时用 liveDocs 过滤，被删节点仍然占着邻居槽位。

### 1.2 每个节点的邻居怎么存

每个节点的邻居列表用 `int` 块存：

```
[count][neighbor0][neighbor1]...[padding]
```

按 4 个 int 对齐，不足补 `-1`（`HnswGraph.NodesIterator` / `NeighborArray` 读写时按 `Integer.BYTES * 4` 对齐）。这么设计是为了随机访问时一次读一个 cache line 的整数倍。

## 二、图是怎么建出来的

### 2.1 插入流程

`HnswGraphBuilder.add(List<float[]> vectors)` 的核心逻辑：

```java
// 简化后的伪代码（对应 Lucene 9.x HnswGraphBuilder）
for (float[] vector : vectors) {
  int node = graph.addNode();                  // 分配层内序号
  int level = randomLevel();                   // 几何分布，默认 mL = 1/ln(M)
  graph.setNewEntryNode(node, level);          // 若更高层，更新入口点

  // 1) 从当前入口点开始，逐层贪心下降
  float[] eps = new float[]{entryPoint};
  for (int lc = maxLevel; lc > level; lc--) {
    eps = searchLayer(vector, eps, 1, lc);     // ef=1 的贪心
  }

  // 2) 在 level ~ 0 每一层做 efConstruction 的 beam search，并连边
  for (int lc = Math.min(level, maxLevel); lc >= 0; lc--) {
    NeighborArray neighbors = searchLayer(vector, eps, efConstruction, lc);
    connectNode(lc, node, neighbors);           // 双向连边 + 裁剪
    eps = neighbors.nodes();                    // 下一层的入口候选
  }
}
```

三个细节值得展开：

**（1）层数分布不是均匀随机。** HNSW 用 `level = floor(-ln(uniform) * mL)`，`mL = 1/ln(M)`。M=16 时约 93% 的节点只在 level 0，6.7% 在 level 1，逐层指数衰减。这决定了上层图非常小，搜索时"上层导航 + 下层精搜"的成本才可控。

**（2）`efConstruction` 不是越大越好。** 它决定建图时每层保留多少候选。100 是经验值；调到 200 召回能再涨 1~2 个点，但建库时间几乎翻倍。对离线一次性建库，200 可以接受；对实时写入，100 甚至 64 更现实。

**（3）连边时用的是"多样性启发式"（diversity heuristic），不是简单取 top-M。**

### 2.2 邻居选择：为什么不能只取最近的 M 个

假设节点 q 有 30 个候选邻居，按距离排序后前 16 个全在同一个方向上。如果直接取 top-16，q 的邻居全部"挤"在一侧，图在另一侧就断了，搜索从那个方向进来必然走不到 q。

Lucene 的做法（`HnswGraphBuilder.selectAndLinkDiverse`）是：

```java
// 对候选按距离升序，逐个尝试加入结果集
for (Neighbor candidate : sortedCandidates) {
  boolean good = true;
  for (Neighbor selected : results) {
    // 如果 candidate 到某个已选邻居的距离 比 candidate 到 q 的距离更近，
    // 说明 candidate 已被 selected "覆盖"，没必要成为 q 的直接邻居
    if (distance(candidate, selected) < candidate.distanceToQuery) {
      good = false;
      break;
    }
  }
  if (good) results.add(candidate);
  if (results.size() >= M) break;
}
```

这就是所谓的 RNG（Relative Neighborhood Graph）近似。它牺牲了一点"最近邻精度"（可能把真正的最近邻挤掉），换来图的连通性和长距离跳跃能力，整体召回反而更高。

这也解释了一个常见困惑：**为什么 Lucene 的 HNSW 召回率用 `knn` 查出来和 hnswlib 不一样？** 因为两者的邻居裁剪策略、是否保留"被覆盖"候选、以及段划分方式都不同。

### 2.3 图不是"一次成型"的

Lucene 的向量是跟着段走的。一次 bulk 写入可能产生几十个段，每个段独立建图。查询时 `KnnFloatVectorQuery` 会对**每个段**并行做一次 HNSW 搜索，再归并 top-k。

这意味着：

- 段越多，单段图越小，入口点质量越差，**召回率越低**；
- 段越多，查询要扫的图越多，**延迟越高**；
- 每次 merge 都要**重建**目标段的图（Lucene 9.7+ 之后是增量合并，见下节）。

我在生产上的经验值：**单段向量数低于 1 万时，HNSW 的召回会明显劣化**。所以向量索引应当尽量让段大一些，或者干脆用 `forceMerge(1)` 固化（只读场景）。

## 三、Merge：增量合并才是重点

### 3.1 早期实现：重建

Lucene 9.0~9.6 的 merge 逻辑很朴素：把待合并段里所有存活的向量读出来，重新 `add()` 一遍，建一张全新的图。200 万条 × 多轮 merge，CPU 直接打满——这也是很多人抱怨"ES 写向量比写文本慢十倍"的真实原因。

### 3.2 Lucene 9.7+ 的增量合并

`HnswGraphMerger` 的出现改变了这一点。合并时不再重建，而是：

1. 以第一个段（或最大的段）的图为**基底**；
2. 依次把后续段的节点 `addGraphNode()` 到已有图上；
3. 每个新节点只做"局部连边"——从基底图的入口点下降，找到候选邻居，双向连边并裁剪；
4. 被删除的文档通过 liveDocs 在写入时过滤，**图结构保留但节点不再被访问**。

伪代码：

```java
HnswGraphMerger merger = new HnswGraphMerger(
    similarityFunction, M, beamWidth, null);
for (LeafReader reader : mergingReaders) {
  merger.addReader(reader);      // 记录每段的图与向量
}
OnHeapHnswGraph merged = merger.merge(
    knnVectorValues,              // 合并后的向量视图
    mergedVectorValues,           // 目标段
    null);
```

增量合并把 merge 成本从 `O(N × efConstruction × log N)` 降到近似 `O(N_added × efConstruction × log N)`，**当一个大段合并若干小段时，收益非常明显**。

但它有代价：**图的质量略低于全量重建**。因为老节点不会因为新节点加入而重新选邻居。所以如果你追求极致召回，在数据不再变更后跑一次 `forceMerge(1)` 让图彻底重建，是值得的。

### 3.3 量化：用精度换内存

`Lucene99ScalarQuantizedVectorsFormat` 把 float32 压成 int8（或 7-bit），每个维度省 75% 内存。查询时先用量化向量做粗排，再用原始向量（可选 `rescore`）精排。

```java
// 7-bit 量化，confidenceInterval 0.99
KnnVectorsFormat format = new Lucene99ScalarQuantizedVectorsFormat(
    16, 100, (byte) 7, 0.99f, false);
IndexWriterConfig iwc = new IndexWriterConfig()
    .setCodec(new Lucene99Codec() {
      @Override
      public KnnVectorsFormat getKnnVectorsFormatForField(String field) {
        return format;
      }
    });
```

注意 `confidenceInterval` 的作用：它决定量化时故意"裁掉"多少极端值，越小压缩越狠但召回越差。0.99 是 Elasticsearch 的默认档位，实践中召回损失通常在 1% 以内。

## 四、一份可运行的 Java 示例

```java
public class LuceneHnswDemo {
  public static void main(String[] args) throws Exception {
    Path dir = Files.createTempDirectory("hnsw-demo");
    IndexWriterConfig iwc = new IndexWriterConfig()
        .setCodec(new Lucene99Codec() {
          @Override
          public KnnVectorsFormat getKnnVectorsFormatForField(String field) {
            return new Lucene99HnswVectorsFormat(16, 100);
          }
        })
        .setMergePolicy(new TieredMergePolicy()
            .setSegmentsPerTier(4)
            .setMaxMergeAtOnce(8)
            .setFloorSegmentMB(512));   // 关键：让小段尽快长大

    try (IndexWriter writer = new IndexWriter(FSDirectory.open(dir), iwc)) {
      for (int i = 0; i < 100_000; i++) {
        Document doc = new Document();
        doc.add(new KnnFloatVectorField("emb", randomVector(768)));
        doc.add(new StringField("tenant", "t" + (i % 10), Field.Store.YES));
        writer.addDocument(doc);
      }
      writer.forceMerge(1);             // 只读场景：合并成单段，图重建
    }

    try (DirectoryReader reader = DirectoryReader.open(FSDirectory.open(dir))) {
      IndexSearcher searcher = new IndexSearcher(reader);
      Query knn = new KnnFloatVectorQuery("emb", randomVector(768), 10);
      // 带过滤的 kNN：先过滤再搜索，避免"过滤后召回不足"
      Query filtered = new BooleanQuery.Builder()
          .add(knn, BooleanClause.Occur.MUST)
          .add(new TermQuery(new Term("tenant", "t3")), BooleanClause.Occur.FILTER)
          .build();
      TopDocs td = searcher.search(filtered, 10);
      System.out.println("hits=" + td.totalHits.value());
    }
  }

  private static float[] randomVector(int dim) {
    float[] v = new float[dim];
    Random r = new Random();
    for (int i = 0; i < dim; i++) v[i] = r.nextFloat() * 2 - 1;
    return v;   // 生产上必须做 L2 归一化，配合 COSINE
  }
}
```

## 五、调优清单与踩坑

| 参数 | 建议值 | 说明 |
|---|---|---|
| `m` | 16（通用）/ 32（高召回） | 每层邻居上限，内存≈`m × 2 × 4B × N` |
| `ef_construction` | 100（在线）/ 200（离线） | 建图质量，直接决定建库耗时 |
| `beamWidth`（查询） | 100~200 | 等价 HNSW 的 `ef`，查询时可覆盖 |
| `numCandidates`（ES） | `k × 10` 起 | 太小召回崩，太大延迟崩 |
| 段大小 | > 1 万向量/段 | 小段召回差，尽量少 refresh |
| `forceMerge` | 只读场景执行 | 写完再合并，别边写边合 |

**踩坑 1：边写边 forceMerge。** 有人在数据持续写入时定时 `forceMerge(1)`，结果每次都重建整张图，写入吞吐直接掉到 1/10。forceMerge 只适合"数据不再变"的场景。

**踩坑 2：过滤查询的召回塌陷。** 先 kNN 再过滤（post-filter）会导致"取 10 个结果全被过滤掉"。Lucene 的 `KnnFloatVectorQuery` 支持 filter-aware 搜索，但内部仍然是在图上搜索时跳过不匹配节点，**如果过滤性极强（<1%），需要提高 `numCandidates` 或改用先过滤再精确算距离**。

**踩坑 3：维度不一致。** 同一个字段的向量维度在段内固定，跨段也必须一致。改 Embedding 模型（比如 768 → 1024）必须**新建索引重建**，不能原地改 mapping。

**踩坑 4：归一化。** 用 `COSINE` 相似度时，Lucene 内部会做归一化；用 `DOT_PRODUCT` 时不会。混用两种相似度会导致排序完全错乱。

## 六、面试追问

**Q：HNSW 为什么比 IVF 快？**
A：IVF 需要先聚类再倒排，查询时要扫多个簇；HNSW 是图结构，从入口点贪心下降，每次只访问 `ef` 个候选，复杂度近似 `O(log N)`。代价是内存占用高（要存所有邻居）且不支持高效删除。

**Q：删除向量后图会怎样？**
A：Lucene 只是标记删除，图结构不变，查询时用 liveDocs 过滤。被删节点的邻居槽位仍占内存，所以大量删除后需要 `forceMerge` 重写段。

**Q：为什么我的 ES kNN 查询比暴力检索还慢？**
A：大概率是段太多 + `numCandidates` 设置过大 + 没有走 filter-aware 路径。先看 `_segments` 数量，再看 `profile` 里的 `knn` 耗时分解。

**Q：增量合并会不会让召回越来越差？**
A：会缓慢劣化，因为老节点不重新选邻居。实践上控制在"大段 + 少量增量"的结构，并在数据稳定后重建一次，就能把损失压到 1% 以内。

## 结语

向量检索不是"调个 API 就完事"。当你把 Lucene 的 HNSW 拆开看，会发现里面全是工程取舍：多样性启发式牺牲精度换连通性，增量合并牺牲质量换写入吞吐，量化牺牲召回换内存。理解这些取舍，才能在"召回 0.82 还是 0.95"的问题面前，知道该动哪个旋钮。
