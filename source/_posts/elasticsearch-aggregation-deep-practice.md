---
title: 【ES 实战】Elasticsearch 聚合分析深度实战：Metric/Bucket/Pipeline 聚合原理与性能优化
date: 2026-09-08 08:00:00
tags:
  - Elasticsearch
  - 聚合
  - 实战
categories:
  - Java
  - 中间件
author: 东哥
---

# 【ES 实战】Elasticsearch 聚合分析深度实战：Metric/Bucket/Pipeline 聚合原理与性能优化

## 面试官：ES 的聚合查询和 MySQL 的 GROUP BY 有什么区别？

很多人用 ES 只停留在「搜索」层面，一提聚合就只会写个 `terms`。但面试官真正想考察的，是你对聚合分类、底层数据结构（doc_values）、以及那些「反直觉」行为（比如 terms 聚合的 doc_count 不精确）的理解。

Elasticsearch 的聚合（Aggregation）是分析型查询的核心能力，可以把它理解成 **内存/磁盘中的分布式 GROUP BY + 统计函数**，但它的表达能力和灵活性远超 SQL。本文从三类聚合（Metric、Bucket、Pipeline）出发，配合实战案例和性能优化，一次讲透。

---

## 一、聚合的三层结构：桶、指标、管道

聚合查询统一放在 `aggs` 节点下，核心分类如下：

| 聚合类型 | 作用 | 典型例子 | 类比 SQL |
|---------|------|---------|---------|
| Metric 指标聚合 | 对一组文档做数值统计 | avg、sum、max、cardinality、percentiles、stats | AVG/SUM/COUNT(DISTINCT) |
| Bucket 桶聚合 | 把文档分组，每组一个桶 | terms、range、date_histogram、filter、nested | GROUP BY / WHERE 分组 |
| Pipeline 管道聚合 | 对**其他聚合的输出结果**再做聚合 | bucket_script、derivative、cumulative_sum、avg_bucket | 子查询/窗口函数 |

**关键认知**：Metric 聚合是「叶子节点」，产出数值；Bucket 聚合可以嵌套（桶里再分桶，形成多维度下钻）；Pipeline 聚合输入的是桶的统计结果而不是文档，所以它的位置在某个 `aggs` 结果的同级或子级，并且要指明 `buckets_path`。

一个典型的「按天统计订单金额，再算每天的环比增长」：

```json
{
  "size": 0,
  "aggs": {
    "daily": {
      "date_histogram": { "field": "order_time", "calendar_interval": "day" },
      "aggs": {
        "amount": { "sum": { "field": "amount" } },
        "growth": {
          "derivative": { "buckets_path": "amount" }
        }
      }
    }
  }
}
```

这里 `daily` 是 Bucket 聚合，`amount` 是内嵌 Metric 聚合，`growth` 是 Pipeline 聚合（对上一个桶的 `amount` 求差分）。三层结构一目了然。

---

## 二、Metric 聚合：数值统计的真相

### 2.1 常用 Metric 一览

- `avg` / `sum` / `min` / `max` / `value_count`：基础五件套，底层直接读取 doc_values。
- `stats` / `extended_stats`：一次返回 count/min/max/avg/sum，extended 额外返回方差、标准差、百分位区间，用于监控类指标非常方便。
- `cardinality`：近似去重计数（UV 统计），**默认精度 0.4% 误差**，底层是 HyperLogLog++。
- `percentiles` / `percentile_ranks`：百分位统计，底层是 **TDigest**（也是近似算法）。
- `top_hits`：取每个桶内「命中的前 N 条文档」，常用来实现「分组 Top N」。

### 2.2 为什么 cardinality 和 percentiles 是「近似」的？

这是面试高频追问点：

- **cardinality** 用 HyperLogLog：每个分片只维护一个固定大小的寄存器数组（默认 2^14 个寄存器，约 12KB），通过哈希把元素映射到寄存器并记录最大前导零位数，最后合并所有分片的寄存器估算基数。空间占用 O(1)，因此无法精确——**精度与内存是跷跷板**。想要更高精度，调大 `precision_threshold`（代价是内存上升）。
- **percentiles** 用 TDigest：不保留全量数据，而是用「质心（centroid）」近似分布，内存可控地给出分位数估计。100 万条数据的 p99 延迟，靠 TDigest 只需几十 KB 内存。

> 面试加分句：近似聚合换来的收益是「在数据量级增长时内存不随之线性增长」，这是 ES 敢在分布式场景做实时统计的底气。如果业务要求绝对精确（如金额对账），应改用精确聚合或把数据落到数仓。

---

## 三、Bucket 聚合：分组的艺术

### 3.1 terms 聚合与 doc_count 不精确之谜

`terms` 是最常用的分组聚合。但注意这个经典问题：

```json
{
  "size": 0,
  "aggs": {
    "by_category": { "terms": { "field": "category", "size": 10 } }
  }
}
```

返回的 `doc_count` **在跨分片场景下可能不精确**。原因：

1. 每个分片独立统计自己那部分数据的词频（terms 聚合依赖倒排索引的 term 词典 + doc_values）。
2. 协调节点默认只取每个分片的 **top size 个桶**（这里每个分片返回 top 10），再合并——如果一个词在 A 分片排第 11、在 B 分片排第 1，合并后它可能本应进全局 Top 10 却被漏掉了。

解决办法：调大 `shard_size`（默认 `size * 1.5 + 10`），并开启 `show_term_doc_count_error` 查看误差上界：

```json
{
  "aggs": {
    "by_category": {
      "terms": {
        "field": "category",
        "size": 10,
        "shard_size": 1000,
        "show_term_doc_count_error": true
      }
    }
  }
}
```

当 `doc_count_error_upper_bound` 为 0 时说明结果精确。**如果对精确性有硬要求，把 `size` 设得足够大或直接用 composite 聚合做分页式精确聚合。**

### 3.2 常用 Bucket 聚合

| 聚合 | 用途 | 注意点 |
|------|------|--------|
| `terms` | 按字段值分组（类目、状态、用户ID） | keyword 字段走 doc_values；text 字段需 fielddata（默认关闭，几乎永远别开） |
| `date_histogram` | 按时间分桶（天/小时/月） | `calendar_interval`（日历感知，如 1M 是自然月）vs `fixed_interval`（固定 30 天） |
| `range` / `date_range` | 按数值/时间区间分桶 | 区间左闭右开 |
| `filter` / `filters` | 按过滤条件分桶 | 实现「总量 vs 成功量 vs 失败量」一次查完 |
| `histogram` | 数值等宽分桶 | 适合价格区间、耗时区间 |
| `composite` | 分页遍历所有桶 | 解决 terms 聚合 size 过大导致的内存问题 |

### 3.3 date_histogram 的两种 interval，别再搞混

- `calendar_interval: "month"`：按自然月对齐（1 月 30 天、2 月 28/29 天，日历感知）。适合业务报表。
- `fixed_interval: "30d"`：固定 30 天一个桶，从 epoch 对齐。适合监控系统（Prometheus 风格）。

用错会导致时间桶边界和你预期的完全不一样，这是实战中非常隐蔽的坑。

---

## 四、Pipeline 聚合：对结果再加工

Pipeline 聚合分两类：

- **Parent（父级管道）**：输出内嵌到父桶里，如 `derivative`（求导/环比差值）、`cumulative_sum`（累计和）、`moving_avg`（移动平均）、`bucket_script`（桶间脚本计算）。
- **Sibling（同级管道）**：输出与父桶平级，如 `avg_bucket`、`min_bucket`/`max_bucket`、`stats_bucket`、`percentiles_bucket`——用来「找出最大/最小的那个桶」。

经典实战：**按小时统计请求量，并算累计值 + 与上一小时的差值**：

```json
{
  "size": 0,
  "aggs": {
    "per_hour": {
      "date_histogram": { "field": "ts", "fixed_interval": "1h" },
      "aggs": {
        "requests": { "value_count": { "field": "request_id" } },
        "cum_requests": { "cumulative_sum": { "buckets_path": "requests" } },
        "delta": { "derivative": { "buckets_path": "requests" } }
      }
    }
  }
}
```

而「找出请求量最高的那个小时」用 sibling 管道：

```json
{
  "aggs": {
    "per_hour": {
      "date_histogram": { "field": "ts", "fixed_interval": "1h" },
      "aggs": { "requests": { "value_count": { "field": "request_id" } } }
    },
    "max_hour": {
      "max_bucket": { "buckets_path": "per_hour>requests" }
    }
  }
}
```

注意 `buckets_path` 的 `>` 语法表示沿聚合树向下寻址。

---

## 五、实战案例：电商订单多维分析

假设订单索引 `orders`，字段：`order_time`(date)、`amount`(double)、`category`(keyword)、`user_id`(keyword)、`status`(keyword)。

**需求：统计最近 30 天每天各品类的销售额，并输出当天 Top 3 品类。**一次聚合搞定：

```json
{
  "size": 0,
  "query": { "range": { "order_time": { "gte": "now-30d/d" } } },
  "aggs": {
    "daily": {
      "date_histogram": { "field": "order_time", "calendar_interval": "day" },
      "aggs": {
        "by_category": {
          "terms": { "field": "category", "size": 3, "shard_size": 100 },
          "aggs": {
            "sales": { "sum": { "field": "amount" } },
            "top_orders": {
              "top_hits": { "size": 1, "_source": ["order_id", "amount"] }
            }
          }
        }
      }
    }
  }
}
```

**需求：独立访客数（UV）与老客占比**：

```json
{
  "aggs": {
    "uv": { "cardinality": { "field": "user_id", "precision_threshold": 40000 } },
    "total": { "value_count": { "field": "user_id" } }
  }
}
```

`precision_threshold` 默认 3000：基数低于该值时精确，高于后误差逐渐增大（上限 0.4%）。把它调大到 40000 意味着 4 万以内的 UV 精确，但每个分片内存从约 2KB 涨到约 24KB。

---

## 六、聚合性能优化：八条军规

1. **`size: 0` 永远带上**。只要不需要返回文档，就让协调节点别拉取命中明细，只回聚合结果——很多新手漏掉这个，白白多传几十 MB。
2. **字段必须开启 doc_values**（keyword/数值/日期默认开启）。聚合读的是列式存储 doc_values，不是倒排索引；对 text 字段做 terms 聚合需要 fielddata，**内存杀手，一律别开**，正确做法是用 keyword 子字段。
3. **date_histogram 优先于大量 range 桶**。时间序列场景用 date_histogram 加 fixed_interval，比手动拼几十个 range 快得多。
4. **terms 聚合的 size 别贪大**。size 越大，每个分片需要保留的候选桶越多，内存越高。真要遍历全部桶，用 `composite` 聚合 + after 游标分页。
5. **减少聚合嵌套层级**。桶套桶是乘法级开销：10 天 × 100 品类 = 1000 个桶的计算。能用 filter 聚合分流的，别层层嵌套。
6. **先过滤再聚合**。聚合前先用 query 缩小数据范围，聚合只对命中文档执行。
7. **分片数不是越多越好**。聚合需要把每个分片的部分结果汇总到协调节点，分片过多（如单索引几十个分片）会放大归并开销。控制单分片大小在 30-50GB 左右。
8. **`search_type` 与 `batched_reduce_size`**。超大规模聚合时协调节点分批归并（默认 512 个分片结果一批），可适当调大减少往返。

---

## 七、面试常见追问

**Q1：terms 聚合的 doc_count 一定准吗？**
不一定。默认每个分片只贡献 top `shard_size` 个桶，跨分片合并时可能漏掉「局部低频、全局高频」的词。调大 shard_size 或 show_term_doc_count_error 可以观察误差；要绝对精确需用 composite 聚合。

**Q2：cardinality 聚合的原理是什么？为什么不用精确 Set？**
基于 HyperLogLog++ 近似算法，每个分片用固定大小寄存器记录哈希信息，空间占用与基数无关，所以能在大数据量下实时算 UV。代价是近似（默认误差 0.4% 以内）。如果数据量小（如百万内）且对准确性敏感，可以调高 precision_threshold。

**Q3：对 text 字段做聚合报错 fielddata is disabled，怎么办？**
在 mapping 里给 text 字段加 `fields: { keyword: ... }` 子字段，对 keyword 子字段做聚合。开启 fielddata 是下策，会把倒排索引词项全部加载进堆内存，容易 OOM。

**Q4：聚合很慢，如何定位瓶颈？**
先看 `_cat/nodes` 确认 CPU/堆内存；用 `profile: true` 查看聚合各阶段耗时；检查是否误用了 fielddata；看协调节点是否成为瓶颈（大量分片归并）；最后考虑用异步搜索 `_async_search` 或把聚合结果预计算落地（如每日定时任务写统计索引）。

---

## 总结

ES 聚合是「搜索 + 分析」一体化的核心能力：Metric 聚合负责算，Bucket 聚合负责分，Pipeline 聚合负责对结果再加工。理解 doc_values 的列式存储、近似聚合的算法取舍、terms 跨分片归并的误差来源，是写出又快又准的聚合查询的关键。面试时能把「doc_count 为什么不精确」和「cardinality 为什么是近似的」讲透，就已经超过了绝大多数候选人。
