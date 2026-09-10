---
title: 【ES 原理】Elasticsearch 相关性评分深度解析：从 TF-IDF 到 BM25 与 Function Score 排序实战
date: 2026-09-10 08:00:00
tags:
  - Elasticsearch
  - 搜索引擎
  - BM25
  - 原理
categories:
  - 中间件
  - 搜索引擎
author: 东哥
---

# 【ES 原理】Elasticsearch 相关性评分深度解析：从 TF-IDF 到 BM25 与 Function Score 排序实战

## 面试官：ES 默认按什么排序？"相关度"到底是怎么算出来的？

用 ES 做搜索，`match` 查询不指定 `sort` 时，结果按 `_score` 降序返回。这个 `_score` 就是**相关性评分**。面试官一旦问"ES 为什么相关、怎么算分、能不能干预排序"，背后就是一套完整的**检索模型**知识：TF-IDF → BM25 → 查询时加权（boosting）→ Function Score。

本文从 Lucene 经典 TF-IDF 讲起，拆解 ES 5.0+ 默认的 **BM25 算法公式**，再给出生产中干预排序的完整实战。

## 一、先理解三个核心概念

| 概念 | 含义 | 直觉 |
|---|---|---|
| TF（词频） | 词在文档中出现次数 | 出现越多越相关 |
| IDF（逆文档频率） | 词在多少文档中出现 | 越稀有的词越有区分度 |
| 文档长度归一化 | 文档越长，相同词频"含金量"越低 | 短文档命中更难得 |

任何现代相关性算法，本质都是在平衡这三者，再叠加**字段权重**与**查询权重**。

## 二、Lucene 的经典 TF-IDF（ES 5.0 之前）

ES 早期版本（2.x 及之前）沿用 Lucene 的 classic 相似度，公式核心为：

```
score(doc, term) = tf * idf² * fieldNorm
```

其中：
- `tf = sqrt(termFreq)`：对词频开根号，抑制"堆词"带来的线性增长；
- `idf = 1 + log(numDocs / (docFreq + 1))`：文档频率越低，权重越高；
- `fieldNorm`：与字段长度成反比，长字段降权。

经典 TF-IDF 的问题很明显：**词频对分数的贡献没有上界**。一篇文章把"手机"重复 100 次，评分会高到失真，且对停用词、长文档的处理都不够平滑。这也是 Lucene 后来换掉它的原因。

## 三、BM25：ES 5.0+ 的默认相似度

### 3.1 公式拆解

BM25（Best Matching 25）对一篇文档 d 中所有命中词项 t 求和：

```
score(d, q) = Σ [ IDF(t) × f(t,d) × (k1 + 1) / ( f(t,d) + k1 × (1 - b + b × |d|/avgdl) ) ]
```

各参数含义：

| 符号 | 含义 | ES 默认值 | 作用 |
|---|---|---|---|
| f(t,d) | 词项 t 在文档 d 中的词频 | — | 词频越高分越高 |
| IDF(t) | 逆文档频率 | — | 稀有词权重高 |
| k1 | 词频饱和因子 | 1.2 | 控制词频增长的"天花板"速度 |
| b | 长度归一化强度 | 0.75 | 0=完全不管长度，1=完全按长度归一 |
| \|d\| / avgdl | 文档长度与平均长度之比 | — | 长文档惩罚项 |

### 3.2 为什么 BM25 更优

把词频部分单独拎出来看：

```
f(t,d) × (k1 + 1)
────────────────────────────
f(t,d) + k1 × (1 - b + b × |d|/avgdl)
```

当词频 f 趋于无穷时，这个分式趋于 `k1 + 1`，也就是说 **词频对分数的贡献存在渐近上界**——重复 100 次和重复 200 次带来的收益差异极小。这就是 BM25 的"饱和"特性，比经典 TF-IDF 的线性增长合理得多。

ES 中查看文档如何被分词打分，可以用 `explain`：

```json
GET /products/_search
{
  "explain": true,
  "query": {
    "match": { "title": "无线 鼠标" }
  }
}
```

返回里能看到逐项拆解：

```
weight(title:无线 in 3) [PerFieldSimilarity]: 0.6931471
  tf: freq=1.0, higher is better
  docFreq: 12, maxDocs: 1000
  fieldLength: 8, avgFieldLength: 6.5
```

其中 `docFreq` 对应 IDF 的计算输入，`fieldLength` 对应长度归一化。

## 四、多字段与多词项的总分构成

真实查询往往跨多个字段（`multi_match`），总分的计算方式需要弄清：

```
queryNorm（查询归一化，对单次查询所有文档是常量，不影响排序）
  ×
coord（协调因子：命中的查询子句越多分越高，ES 5.0 后默认关闭）
  ×
Σ 每个字段的 boost（字段权重）
  ×
Σ 每个词项在命中字段上的 BM25 分
```

因此 **`_score` 是各词项、各字段分数加权求和**，而不是取最大。常见的调权手段：

| 手段 | 写法 | 效果 |
|---|---|---|
| 字段 boost | `multi_match` 中 `"fields": ["title^3", "content"]` | 标题命中权重是正文 3 倍 |
| 查询 boost | `"match": {"title": {"query": "手机", "boost": 2}}` | 提升某个查询子句 |
| 常数分 | `constant_score` | 完全忽略 BM25，只按 filter 逻辑筛 |
| Function Score | 见下文 | 叠加业务分（销量、时间衰减等） |

## 五、实战一：Function Score 叠加业务因子

纯文本相关度不够，电商搜索要"销量高的排前面"，资讯搜索要"新的排前面"。用 `function_score` 把业务分数乘进 `_score`：

```json
GET /products/_search
{
  "query": {
    "function_score": {
      "query": { "match": { "title": "无线鼠标" } },
      "functions": [
        {
          "field_value_factor": {
            "field": "sales_count",
            "factor": 1,
            "modifier": "log1p"
          }
        },
        {
          "gauss": {
            "create_time": {
              "origin": "2026-09-10",
              "scale": "30d",
              "decay": 0.5
            }
          }
        }
      ],
      "boost_mode": "multiply",
      "score_mode": "sum",
      "max_boost": 100
    }
  }
}
```

要点：
- `field_value_factor` 把业务字段变成分数，`modifier: log1p` 防止销量数量级碾压文本分；
- `gauss` 高斯衰减函数：离 `origin`（今天）越近分越高，适合"时效性衰减"；
- `boost_mode` 决定业务分如何与 BM25 分结合：`multiply`（相乘）/ `sum`（相加）/ `replace`（覆盖）；
- `score_mode` 决定多个 function 之间如何合并：`sum` / `max` / `avg`。

## 六、实战二：让某个词"必须相关"——minimum_should_match 与 should

`match` 默认 `operator: or`，多词查询只要命中一个词就返回，相关度低的结果会拉低体验。生产中常用：

```json
GET /articles/_search
{
  "query": {
    "match": {
      "content": {
        "query": "分布式 事务 最终一致性",
        "minimum_should_match": "2<75%"
      }
    }
  }
}
```

`"2<75%"` 表示：当查询词 ≤ 2 个时全部命中；超过 2 个时至少命中 75%。这比单纯调 boost 更能从根上过滤"弱相关"文档。

## 七、排错与调优：从 explain 到 profile

### 7.1 用 explain 排查"为什么它排第一"

线上发现排序不符合预期，先定位是哪部分分数异常：

```json
GET /products/_search
{
  "explain": true,
  "query": { ... }
}
```

看 `_explanation` 树：如果 BM25 的 IDF 部分异常高，可能是该词文档频率极低（数据稀疏）；如果 field_value_factor 贡献过高，检查 modifier 是否缺失。

### 7.2 用 profile 排查性能

`"profile": true` 会给出每个子查询的耗时，定位慢在 `match` 还是 `function_score` 的 script 上。**Function Score 里写 painless script 遍历大文档集是性能杀手**，能用 `field_value_factor` 就别用 script。

### 7.3 一致性提醒：评分与数据分布强相关

BM25 的 IDF 依赖 `docFreq`（全局文档频率），**索引数据量变化、分片间文档分布不均都会影响评分**。搜索集群中若分片数过多而文档很少，会出现"同样查询在不同分片算出的分不同"的现象——小数据量测试环境尤其明显，压测和验收要在接近生产的规模上进行。

## 八、高频面试追问

**Q1：ES 5.0 为什么从 TF-IDF 换成 BM25？**
经典 TF-IDF 词频无上界，长文档惩罚粗糙；BM25 引入 k1（词频饱和）与 b（长度归一化强度）两个可调参数，配合 Lucene 6 的规范化改进，排序质量与可解释性更好。

**Q2：k1 和 b 怎么调？**
- 文本很短、关键词型（标题/标签）：调大 b（0.8~1.0）惩罚长文档；
- 长文本正文：调小 b（0.5 左右）避免过度惩罚；
- 某个词大量重复导致分数失真：调小 k1（如 1.0 以下）让饱和更早出现。
调参在索引的 `settings` 里通过 `similarity` 自定义，改完需要重建索引。

**Q3：_score 能跨索引比较吗？**
不能。不同索引的 `avgdl`、`docFreq` 不同，BM25 参数也可能不同，`_score` 只在同一次查询内部有意义。跨索引混排要用 `sort` 或业务字段。

**Q4：constant_score 查询还有相关性吗？**
没有。`constant_score` 里的 filter 只做匹配不做评分，所有命中文档 `_score` 相同（等于 boost），顺序取决于 `sort` 或内部顺序。适合"纯过滤 + 业务排序"场景，还能吃到 filter 缓存，性能更好。

## 九、总结

一条链路记住 ES 的排序本质：

```
相关性 = 检索模型(BM25) × 字段/查询权重(boost) × 业务因子(function_score)
```

- BM25 是 ES 5.0+ 默认相似度，核心是**词频饱和（k1）+ 长度归一化（b）**；
- 干预排序优先用 `multi_match` 字段 boost + `function_score`，少用 script；
- `explain` 看分数构成，`profile` 看性能，两者是排错双剑；
- `_score` 仅在同一次查询内有意义，跨索引比较必须显式 sort。

搜索排序没有银弹，理解评分公式后，你才能针对业务"调得动、调得准"。
