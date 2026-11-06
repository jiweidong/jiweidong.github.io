---
title: 【ES 底层】_source、doc_values 与 fielddata 深度解析：Elasticsearch 到底吃内存还是吃磁盘
date: 2026-11-06 08:00:00
tags:
  - Elasticsearch
  - Lucene
  - 中间件
  - 性能优化
  - 面试
categories:
  - 中间件
author: 东哥
---

# 【ES 底层】_source、doc_values 与 fielddata 深度解析

## 前言：一次"堆内存 32G 却天天 OOM"的排查

线上一个 9 节点的 ES 集群，每个节点 `-Xmx31g`（31g 是压缩指针的临界点，这个数字后面还会出现），日均写入 2 亿条日志，某天开始每天下午 OOM 一次，`hot_threads` 显示大量线程卡在 `GlobalOrdinalsStringTermsAggregator`。

排查结果：一个"临时看板"需求给 `message`（text 类型）加了 `terms` 聚合。text 字段默认 `fielddata=false`，那位同学为了"让它能聚合"，直接开了 `"fielddata": true`。于是 ES 把整个字段的所有 term 加载进堆，30 亿个文档的 message 字段，堆瞬间爆了。

这件事的本质，是**没搞清楚一条文档在 ES 里到底被存了几份、每份存在哪、什么时候会被读进堆**。

这篇文章就把这件事拆干净。

---

## 一、一条文档在 Lucene 里被存了几份

假设有这样一个文档：

```json
{"id": 1001, "title": "Elasticsearch 深度解析", "price": 99.5, "created": "2026-11-06T08:00:00Z"}
```

写入 ES 后，它在底层 segment 里会变成 **6~8 份不同的数据结构**：

| # | 结构 | 干什么用 | 存储位置 | 默认开启 |
|---|---|---|---|---|
| 1 | `_source` | 原样返回文档内容、reindex、update | stored fields（磁盘 + page cache） | 是 |
| 2 | 倒排索引 postings | `match`/`term` 全文与精确检索 | 磁盘 + page cache | 是 |
| 3 | terms dictionary (FST) | term → postings 的映射 | **堆内（常驻）** | 是 |
| 4 | `doc_values` | 排序、聚合、脚本访问 | 列存，磁盘 + page cache | 数值/日期/keyword 默认是 |
| 5 | `norms` | 算 `_score`（字段长度归一化） | 每文档 1 byte，磁盘 | text 默认是 |
| 6 | BKD `points` | 数值/日期/IP 的**范围查询** | 磁盘（BKD 树） | 是 |
| 7 | `_field_names` | 判断"字段是否存在"（exists 查询） | 磁盘 | 是 |
| 8 | `term_vectors` | 高亮、more_like_this | 磁盘（很大） | 否 |
| 9 | `_id` 索引 | `_id` 精确查找 | 磁盘 | 是 |

关键认知：**ES 的"内存"主要是 page cache，不是堆。** 堆里真正常驻的是 FST、segment 元数据、fielddata（若开启）、聚合桶、以及各种 buffer。理解这一点，90% 的"ES 吃内存"问题就有了正确方向。

### 1.1 doc_values 是列存

Lucene 本质是倒排（term → doc list）。而聚合/排序需要的是反过来的（doc → value），如果每次都去扫倒排，成本极高。

`doc_values` 就是为此而生的一层**列式存储**：

```
docId:  0   1   2   3   4   5
price: 99.5 12 88 99.5 45 12
```

编码上做了三件事：**按 docId 顺序存**（连续读）、**delta + 位宽压缩**（`price` 只有 6 个值，用 bits-per-value 压缩）、**每 4096 个文档一个 block 建索引**（跳读）。所以 `sort: price` 是顺序扫列，非常快，而且**全部走 page cache，不占堆**。

这就是为什么 ES 官方一直说：能用 `doc_values` 就别用 `fielddata`。

### 1.2 fielddata：把倒排倒过来放进堆

`text` 字段默认 `doc_values: false`——因为 text 分词后 term 数量巨大，给每个 term 维护列存成本不可接受。

但如果你硬要聚合一个 text 字段，Lucene 只能做一件事：**把 postings 读出来，在堆里反转成 "doc → terms"。** 这个结构就是 `fielddata`，也叫 `GlobalOrdinals`（为了跨 segment 聚合，会先把 term 映射成全局序号）。

代价极其可怕。粗算：30 亿文档 × 平均 20 个 term × （4 字节 ord + 4 字节 docId 压缩后）≈ **数百 GB 堆**。而且它是**惰性加载、只进不出**（除非 segment 被 merge 掉或者你手动 `clear cache`）。

所以正确的姿势永远是：

```json
// ❌ 千万别这么干
"message": { "type": "text", "fielddata": true }

// ✅ 要聚合就加 keyword 子字段
"message": {
  "type": "text",
  "fields": { "keyword": { "type": "keyword", "ignore_above": 256 } }
}
```

业务上用 `message.keyword` 聚合，虽然 `ignore_above` 会丢掉长文本，但长文本本来就不该被全量聚合。

---

## 二、_source 的真实成本

`_source` 是很多人以为"免费"的东西，其实它有三个隐性成本。

### 2.1 写放大

一条 10KB 的文档，`_source` 会完整再存一份（snappy 压缩后约 3~5KB）。加上倒排、doc_values、points，**实际磁盘占用通常是原始 JSON 的 2~4 倍**。

### 2.2 merge 时的额外 IO

segment merge 要把多个小 segment 合成大的，`_source` 必须一起搬。如果你写入量很大而 merge 跟不上，`_source` 会把 IO 打满。

### 2.3 返回时的反序列化

`_source` 返回给客户端时是原始 JSON 字符串，ES 需要把它解析成 `Map` 再序列化。**一次 search 返回 100 条含大字段的文档，反序列化开销可能比查询本身还大。**

三个优化手段：

```json
// 1. 只返回需要的字段（服务端过滤，减少网络和反序列化）
GET /idx/_search
{ "_source": ["id", "title"], "query": { "match_all": {} } }

// 2. 写入时就不存大字段
"mapping": {
  "properties": {
    "raw_html": { "type": "text", "index": false, "store": false, "doc_values": false }
  }
}
// 注意：_source 里仍然会有 raw_html，要彻底不存需要用 _source.excludes

// 3. 索引级排除
PUT /idx/_mapping
{ "_source": { "excludes": ["raw_html", "debug_trace"] } }
```

### 2.4 合成 _source（synthetic source）

ES 8.x 引入了 `synthetic_source`：不存原始 JSON，而是检索时**从 doc_values + stored fields 反向重建** `_source`。

```json
PUT /logs
{
  "settings": { "index.mode": "logsdb" },
  "mappings": { "properties": { "message": { "type": "text" } } }
}
```

`logsdb` 索引模式（8.17 起、9.0 正式推荐）默认开启 synthetic source，磁盘能省 30%~50%。代价：**重建出来的 `_source` 字段顺序会变、数字精度可能变（`99.50` 变成 `99.5`）、无法保存未被索引的字段**。如果你的业务对 `_source` 原样性有强依赖（比如做审计留痕），别开。

---

## 三、norms 与 points：两个被忽视的小东西

### 3.1 norms：每文档每字段 1 byte

`_score` 计算需要"字段长度归一化"，Lucene 用 `norms` 存一个字节的编码长度。10 个 text 字段 × 1 亿文档 = **1GB 磁盘**。对日志场景（从不算相关性）可以关：

```json
"message": { "type": "text", "norms": false }
```

关掉后 `_score` 全部变成 1.0，`match` 查询只做布尔匹配。日志检索场景这是巨大收益。

### 3.2 points：BKD 树

数值范围查询（`price > 100`）不走倒排——倒排对范围查询是灾难（要枚举所有 term）。ES 用 **BKD 树**（一种多维 k-d 树）存数值，支持高效的 range 查询。

一个常见误区：**给数值字段同时设 `index: true` 和 `doc_values: false`，以为省空间。** 实际上 `index: true` 会同时建 points 和倒排（`term` 查询用），关掉 `doc_values` 只影响排序/聚合，省不了多少，还让排序变成全扫。**数值字段老老实实保持默认就好。**

---

## 四、堆内存归因实操

OOM 时按这个顺序查：

```bash
# 1. 看 fielddata 占了多少（最常见元凶）
GET _cat/fielddata?v&h=node,field,size&s=size:desc

# 2. 看各节点堆与 breaker 状态
GET _nodes/stats/jvm,indices?filter_path=**.heap_used_percent,**.fielddata,**.segments,**.query_cache

# 3. 看谁在吃 CPU（是不是聚合）
GET _nodes/hot_threads

# 4. 看 circuit breaker 触发了没
GET _nodes/stats/breaker
```

`breaker` 输出里重点看三个：

| breaker | 默认 limit | 管什么 |
|---|---|---|
| `fielddata` | 40% 堆 | fielddata 加载 |
| `request` | 60% 堆 | 单次请求的聚合桶等中间结果 |
| `in_flight_requests` | 100% 堆 | 请求体在途数据 |

看到 `tripped > 0` 就说明某个请求把预算打穿了，配合慢日志定位到具体查询。

### 4.1 一个常被忽略的点：31GB 不是玄学

```yaml
# jvm.options
-Xms31g
-Xmx31g
```

`-Xmx` 超过约 32GB 后，JVM 关闭**压缩对象指针**（Compressed Oops），对象引用从 4 字节变 8 字节，**同样多的对象要多占近一倍堆**，实际可用容量反而下降。所以 ES 官方推荐的堆上限是 31g，而不是"机器内存一半"。

顺带说：ES 的堆和 page cache 是抢内存的。堆给太大，page cache 就少，磁盘读放大；堆太小，聚合和 FST 装不下。**搜索密集型节点堆给 16~24g，日志写入型节点堆给 8~16g，剩下的全留给 page cache**，通常是最稳的分配。

---

## 五、dense_vector 的 HNSW 存在哪

现在很多团队用 ES 做向量检索，这块内存模型完全不同，必须单独说：

```json
"embedding": {
  "type": "dense_vector",
  "dims": 768,
  "index": true,
  "similarity": "cosine",
  "index_options": { "type": "int8_hnsw", "m": 16, "ef_construction": 100 }
}
```

- **HNSW 图结构存在磁盘上，通过 mmap 读取，不占堆**（`off-heap`）。
- 但 mmap 的页会被算进 page cache，**节点 RSS 会显著上涨**，容器里容易被 OOM Killer 干掉（不是 JVM OOM，是 cgroup OOM）。
- 1000 万 × 768 维 float32 = 约 30GB 原始向量；用 `int8_hnsw` 量化后约 7.6GB。这是选型时必须算的账。

所以：**向量检索的容量规划看的是磁盘 + page cache + cgroup limit，不是 JVM 堆。** 很多"ES 向量检索一上就 OOM"的案例，其实是容器内存 limit 给太小。

---

## 六、面试常见追问

**Q1：text 和 keyword 的本质区别？**

`text` 会分词，建倒排用于全文检索，**不建 doc_values**；`keyword` 不分词，整串作为一个 term，**建 doc_values**，可用于排序聚合。给 text 加 `fielddata: true` 是拿堆换功能，生产禁止。

**Q2：为什么 `_source` 不能关？**

技术上能关（`"_source": {"enabled": false}`），但关了之后：无法 `update`（局部更新依赖读旧 `_source`）、无法 `reindex`、无法高亮原文、无法 `recovery` 之外的重建路径。除非你只用 `store: true` 的 stored fields 且完全不需要原文，否则不要关。

**Q3：聚合为什么会 OOM？**

两个地方：一是 fielddata 加载（text 字段），二是 `terms` 聚合的桶数量。后者可以用 `"size": 100` 限制返回桶数，但**注意 `size` 只影响返回，不影响内部构建**——真正治本的是加 `shard_size` 控制，或者改写查询（用 `composite` 聚合分页）。

**Q4：`doc_values: false` 能省多少？**

数值字段的 doc_values 通常是原始数据的 10%~30%（位宽压缩后），keyword 取决于基数。省下的空间可观，但代价是**该字段彻底不能排序/聚合/脚本访问**。只对"只做 term 查询"的字段关。

**Q5：ES 和 MySQL 的内存模型根本区别？**

MySQL 的 Buffer Pool 是**堆外（C 层 malloc）**，缓存的是 16KB 数据页；ES 的 page cache 是**操作系统缓存**，缓存的是 Lucene 文件（`.fdt`/`.dvd`/`.tim`）。两者都遵循"给 OS 留够内存"的原则，但 ES 的堆里还有 FST 这类**必须常驻**的结构，所以 ES 对堆的分配比 MySQL 敏感得多。

---

## 七、落地清单

1. **text 字段永远不开 fielddata**，需要聚合就加 keyword 子字段。
2. 日志场景给 text 关 `norms`，`_score` 用不上。
3. 大字段用 `_source.excludes` 排掉，别只靠 `index: false`。
4. 堆 ≤ 31g，搜索节点 16~24g，写入节点 8~16g，剩下留给 page cache。
5. 上向量检索前先算 "向量数 × 维度 × 4 字节 × 副本数"，再决定 cgroup limit。
6. OOM 排查固定顺序：`_cat/fielddata` → `breaker` → `hot_threads` → 慢日志。

ES 的性能问题，八成不是"ES 不行"，而是"我们把该放磁盘的东西塞进了堆"。把这几份数据结构的边界搞清楚，剩下的就是调参数了。
