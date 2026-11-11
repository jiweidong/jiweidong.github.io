---
title: 【Java 底层】Lucene 索引合并策略深度解析：TieredMergePolicy、写入放大与 forceMerge 治理
date: 2026-11-11 08:00:00
tags:
  - Java
  - Lucene
  - Elasticsearch
  - 索引
categories:
  - Java 底层
author: 东哥
---

# 【Java 底层】Lucene 索引合并策略深度解析：TieredMergePolicy、写入放大与 forceMerge 治理

## 前言

线上 ES 集群最常见的一类"玄学问题"：白天写入正常，凌晨却出现查询 P99 翻倍、节点 IO util 打满、`write` 线程池队列堆积；运维看一眼监控说"段合并（merge）在跑，正常现象"，然后就没有然后了。

另一类更危险的操作是：为了让查询"更快"，有人对着线上索引执行 `POST /idx/_forcemerge?max_num_segments=1`。结果磁盘没降、内存 page cache 被大段挤爆、查询反而变慢，甚至触发集群熔断。

这两个现象背后是同一套机制：**Lucene 的段（segment）不可变 + 后台合并（merge）**。合并策略决定了写放大、查询延迟、磁盘占用三者的平衡点。本文从 `IndexWriter` 的 flush/merge 主链路讲到 `TieredMergePolicy` 的打分公式，再给出一套可落地的 forceMerge 治理规范与监控指标。

---

## 一、段、flush 与 merge：先把链路走通

Lucene 索引是"一段一段"写出来的，每段内部不可变：

```
文档写入 → IndexWriter.addDocument
        → DocumentsWriter（内存 buffer + 删除队列）
        → flush（达到 ramBufferSizeMB / maxBufferedDocs）
        → 生成一个新 segment（可搜索，但尚未提交）
        → commit（fsync segments_N，持久化）
后台：MergePolicy.findMerges() → MergeScheduler → 若干段合并成更大的段 → 旧段删除
```

关键点有三个：

1. **flush 产生的段很小**。默认 `ramBufferSizeMB=100`（ES 默认 `indices.memory.index_buffer_size=10%` 堆，按分片均分），一个 30GB 的分片可能被切成几十上百个中小段。
2. **段数直接决定查询成本**。一次查询要对每个段做一次倒排遍历 + 打分 + 归并；段越多，`Term` 字典查找次数越多，`TopK` 归并成本越高，文件句柄与 page cache 压力越大。
3. **合并是"读旧段 + 写新段 + 删旧段"**，IO 是读写双份，属于纯粹的写放大。

合并过程中，被合并的段仍然可搜索（Lucene 用 `SegmentCommitInfo` 的引用计数保证查询不会被"抽掉地板"），所以合并对查询是**软影响**：不是不可用，而是抢 IO、抢 page cache、抢 CPU。

---

## 二、TieredMergePolicy：不是"分层存储"，是"分层段"

`TieredMergePolicy` 是 Lucene 默认（也是 ES 默认）的合并策略。它的核心思想不是把所有段合并成一个，而是维持"**段大小呈指数分层、每层段数不超过 segmentsPerTier**"的结构。

### 2.1 关键参数

| 参数 | ES 配置项 | 默认值 | 含义 |
|---|---|---|---|
| `segmentsPerTier` | `index.merge.policy.segments_per_tier` | 10 | 每层允许的最大段数，超过就触发合并 |
| `maxMergeAtOnce` | `index.merge.policy.max_merge_at_once` | 10 | 单次合并最多合并几段 |
| `maxMergeAtOnceExplicit` | `index.merge.policy.max_merge_at_once_explicit` | 30 | forceMerge 时单次最多合并段数 |
| `maxMergedSegmentMB` | `index.merge.policy.max_merged_segment` | 5GB | 单段大小上限，超过不再参与普通合并 |
| `floorSegmentMB` | `index.merge.policy.floor_segment` | 16MB | 小于该值的段被视为"同一层的最小单位" |
| `deletesPctAllowed` | `index.merge.policy.deletes_pct_allowed` | 33% | 段内删除比例阈值，超过会被优先合并以回收 |
| `expungeDeletesPctAllowed` | `index.merge.policy.expunge_deletes_allowed` | 10% | `expungeDeletes` 时触发回收的删除比例 |
| `reclaimDeletesWeight` | `index.merge.policy.reclaim_deletes_weight` | 2.0 | 删除回收在打分中的权重 |

> `segmentsPerTier` 与 `maxMergeAtOnce` 官方建议：`maxMergeAtOnce` 不要超过 `segmentsPerTier`，否则一次合并后仍然超层，形成"合并风暴"。

### 2.2 打分公式（合并谁，先合并谁）

`findMerges` 的流程可以简化成三步：

1. **按大小分桶**：把候选段按 `size / floorSegmentMB` 取 log 后分到不同 tier。
2. **找出超额层**：某层段数 > `segmentsPerTier` 就产生一个候选合并组（取该层**最小**的 `maxMergeAtOnce` 个段）。
3. **按 `mergeScore` 排序**：分数越小越优先。

官方实现里 `mergeScore` 近似为：

```
skew        = 较小段总大小 / 较大段总大小        // 越接近 1 越好（避免"小段拖大段"）
mergeScore  = skew × skew × size^mergeFactor     // mergeFactor 默认 1.0（旧版本）
            × (1 + deletesPct^reclaimDeletesWeight)   // 删除比例高的加权
```

工程含义很直白：

- **大小相近的段合并更划算**（skew 小）：合并 10 个 10MB 的段比合并 1 个 5GB + 9 个 1MB 划算得多。
- **删除比例高的段更值得合并**：因为合并会物理丢弃已删除文档，回收磁盘与查询成本。
- **大段阈值是硬保护**：`maxMergedSegmentMB=5GB` 之后不再自动合并，避免单次合并耗时数小时、期间故障恢复代价过高。

### 2.3 另外两个策略

| 策略 | 行为 | 适用场景 |
|---|---|---|
| `LogMergePolicy` / `LogDocMergePolicy` | 按段数（而非字节）分层，相邻段合并 | 段大小均匀的批量建索引场景，Solr 老配置 |
| `NoMergePolicy` | 完全不合并 | 只读一次写入的归档索引、离线批量构建后手动合并 |

在 ES 里这三个策略不能直接切换（`index.merge.policy.type` 不可热改），但理解它们有助于判断"为什么日志索引和业务索引的段形态完全不同"。

---

## 三、写入放大：算一笔真实的账

假设每天新增 100GB 原始文档、单分片 30GB、`floorSegmentMB=16`、层数 K：

```
第 0 层：flush 段约 30MB（受 index buffer 影响），一天产生 ~3400 个
合并到 16MB 层：读 3400×30MB + 写 ~100GB      ≈ 200GB IO
合并到 160MB 层：读 100GB + 写 100GB          ≈ 200GB IO
合并到 1.6GB 层：读 100GB + 写 100GB          ≈ 200GB IO
合并到 5GB 层： 读 100GB + 写 100GB           ≈ 200GB IO
```

**每上一层，就要把整个数据集重写一遍**。10 倍的层级跨度意味着约 4~5 次全量重写，写放大 8~10 倍是常态。这解释了三个现象：

1. 索引的磁盘写入吞吐必须按"业务写入量 × 8"来规划，只按原始量规划必然在合并高峰被打满。
2. 有大量 update/delete 的业务（如订单状态表同步到 ES），实际放大更严重，因为被删除的文档要等到合并才真正消失。
3. 段越"碎"（flush 越频繁），放大越严重 —— 这也是"不要盲目调小 refresh_interval 或加大写入并发"的原因。

---

## 四、代码：用 Lucene API 精确控制合并

ES 用户改配置即可，但自研搜索（Lucene 直用）时必须自己设策略与调度器：

```java
import org.apache.lucene.index.*;
import org.apache.lucene.store.FSDirectory;

import java.nio.file.Paths;

public class IndexWriterTuning {

    public static IndexWriter open(String path) throws Exception {
        IndexWriterConfig cfg = new IndexWriterConfig();

        // 1) 合并策略
        TieredMergePolicy policy = new TieredMergePolicy();
        policy.setSegmentsPerTier(10);          // 每层段数上限
        policy.setMaxMergeAtOnce(10);           // 单次合并段数
        policy.setMaxMergedSegmentMB(5L * 1024); // 单段上限 5GB
        policy.setFloorSegmentMB(16);           // 最小层单位
        policy.setDeletesPctAllowed(33);         // 删除比例阈值
        policy.setReclaimDeletesWeight(2.0);     // 删除回收权重
        cfg.setMergePolicy(policy);

        // 2) 合并调度器：限制并发与 IO 速率（HDD 场景关键）
        ConcurrentMergeScheduler scheduler = new ConcurrentMergeScheduler();
        scheduler.setMaxMergesAndThreads(4, 2);          // 最多 4 个合并、2 线程
        scheduler.setIORateLimitMBPerSec(80.0);          // 合并吞吐上限 80MB/s
        cfg.setMergeScheduler(scheduler);

        // 3) 写缓冲与 flush 频率
        cfg.setRAMBufferSizeMB(256);                      // 单次 flush 段更大 → 段更少
        cfg.setMaxBufferedDocs(IndexWriterConfig.DISABLE_AUTO_FLUSH);
        cfg.setUseCompoundFile(false);                    // SSD 场景可关闭 CFS

        return new IndexWriter(FSDirectory.open(Paths.get(path)), cfg);
    }

    /** 只读索引收尾：合并到 1 段（务必限流 + 低峰执行） */
    public static void forceMergeToOneSegment(IndexWriter writer) throws Exception {
        writer.forceMerge(1, true);   // doWait=true，会阻塞直到完成
        writer.commit();
    }

    /** 只回收删除，不改变段结构（代价远小于 forceMerge(1)） */
    public static void expungeDeletes(IndexWriter writer) throws Exception {
        writer.forceMergeDeletes(true);
    }
}
```

几个容易忽略的点：

- `setRAMBufferSizeMB` 调大能显著减少段数，但会让单次 flush 更久、`refresh` 更抖，且崩溃时需重放的 translog 更多。
- `setIORateLimitMBPerSec` 只对 `ConcurrentMergeScheduler` 生效，是**限流而非降级**：合并变慢意味着小段存活更久，查询成本上升，属于拿查询换写入稳定的取舍。
- `forceMerge(1, true)` 会阻塞调用线程直到合并完成，在 ES 里对应 `_forcemerge?wait_for_completion=true`，超时时间默认为 30s（HTTP 层），极易"看起来成功、实际还在跑"。

---

## 五、forceMerge 治理：什么时候该做，什么时候是自杀

先纠正三个误区：

**误区一：forceMerge 能省磁盘。** 只有段内存在大量删除文档时才有明显收益（`expungeDeletes` 更对症）。纯合并只是把 N 个段拼成 1 个，字节数几乎不变，还会额外产生一份临时副本。

**误区二：段越少查询越快。** 单段确实减少归并，但当单段超过 page cache 容量后，每次查询的随机读会显著增加。经验上单段 1~5GB 是甜点区，超过 10GB 的段在机械盘上往往是负优化。

**误区三：forceMerge 是"只读操作"。** 它会占用 merge 线程池与 IO 带宽，期间新写入的 flush 与合并被挤占，表现为写入延迟上升、refresh 变慢。

### 5.1 正确的执行规范

| 场景 | 是否 forceMerge | 做法 |
|---|---|---|
| 日志/时序索引，按 ILM 滚动 | ❌ 不要 | 依赖自动合并；冷阶段用 `shrink` + `read_only` 更划算 |
| 只读的维表/字典索引（每天全量重建） | ✅ 建议 | 重建后 `_forcemerge?max_num_segments=1`，再 `read_only_allow_delete` |
| 大量 update/delete 的业务索引 | ⚠️ 谨慎 | 先看 `deleted_docs` 比例，>33% 时用 `_forcemerge?only_expunge_deletes=true` |
| 搜索 QPS 高、写入也高的热索引 | ❌ 禁止 | 改为调大 `max_merged_segment` 或 `segments_per_tier` |
| 历史归档索引 | ✅ 可以 | 单段 + 只读 + 冷节点 |

### 5.2 一个安全的执行模板

```bash
# 1. 先看删除比例与段数
curl -s "http://es:9200/my-index/_stats/segments?level=shards" | jq \
  '.indices[].shards[][] | {shard: .routing.shard, segs: .segments.count, del: .segments.deleted_docs // 0}'

# 2. 只回收删除（低风险），限速执行
curl -XPOST "http://es:9200/my-index/_forcemerge?only_expunge_deletes=true&max_num_segments=1"

# 3. 真正的单段合并：先降副本、再执行、再恢复
curl -XPUT "http://es:9200/my-index/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0,"refresh_interval":"-1"}}'
curl -XPOST "http://es:9200/my-index/_forcemerge?max_num_segments=1&wait_for_completion=false"
# 轮询 _tasks 直到完成
curl -s "http://es:9200/_tasks?actions=*forcemerge" | jq '.nodes[].tasks'
curl -XPUT "http://es:9200/my-index/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":1,"refresh_interval":"1s"}}'
```

降副本再 forceMerge 的收益是：合并期间只剩一份数据在写，IO 与磁盘峰值减半；代价是这段时间无冗余，务必在低峰且确认节点健康时做。

---

## 六、监控：把"玄学"变成指标

| 指标 | 来源 | 阈值建议 |
|---|---|---|
| 段数量 | `_stats/segments` → `segments.count` | 单分片 > 100 需关注 |
| 删除文档占比 | `segments.deleted_docs / docs.count` | > 30% 触发 expunge |
| 合并线程占用 | `_nodes/stats` → `merges.current` | 持续 > 0 且队列不为空 |
| 合并累计耗时 | `merges.total_time_in_millis` | 环比突增 2 倍告警 |
| 合并限流次数 | `merges.total_stopped_time_in_millis` | > 0 说明 IO 已成瓶颈 |
| 写入拒绝 | `thread_pool.write.rejected` | > 0 立即告警 |
| 段大小分布 | `segments.memory_in_bytes` / segment size | 单段 > 10GB 检查 `max_merged_segment` |

Prometheus 侧（elasticsearch_exporter）对应 `elasticsearch_index_segments_count`、`elasticsearch_index_merges_total_time_seconds`、`elasticsearch_index_segments_deleted_docs`。把这几个指标和 `node_disk_io_time_seconds_total` 放在同一张图上，凌晨 IO 打满是否由 merge 引起一目了然。

---

## 七、生产踩坑清单

1. **merge 与 refresh 打架**：合并大段时会持有更多文件句柄，`ulimit -n` 不足会报 `Too many open files`，表现为索引突然变红。
2. **合并期间磁盘峰值**：合并需要"新段写完才删旧段"，磁盘水位要留出至少一个最大段的空间，否则 `disk watermark` 触发只读。
3. **`max_merged_segment` 调太大**：单次合并可能跑几小时，节点重启后从头再来，故障恢复窗口被拉长。
4. **只用 `_forcemerge` 不 `_flush`**：forceMerge 完成后段文件仍在 page cache，`_flush` 才会 fsync，掉电窗口依然存在。
5. **副本为 0 时 forceMerge**：忘了恢复副本，后续节点故障直接丢数据。
6. **把 Lucene 的 `segmentsPerTier` 当成 ES 的"分片数"**：两者完全无关，改错参数只会让合并更频繁。

---

## 八、面试常见追问

**Q1：为什么 ES 不默认 forceMerge 到 1 段？**
因为合并是 O(数据量) 的重写操作，热索引持续写入会不断产生新段，forceMerge 完了又碎，纯属浪费 IO；而且单段过大后 page cache 命中率下降、故障恢复变慢。所以官方只建议对**只读索引**做。

**Q2：`deletesPctAllowed` 为什么默认是 33%？**
这是"回收收益 vs 合并成本"的平衡点。低于 33% 时合并重写整个段的成本高于回收的收益；高于 33% 时，段内 1/3 以上是垃圾，重写明显划算。它不是一个精确的最优值，而是经验常数。

**Q3：合并期间被合并的段还能查吗？**
能。查询持有段的引用（`SegmentReader` 引用计数），合并完成后旧段只在引用归零时删除。所以合并对查询是延迟与 IO 影响，不是可用性影响。

**Q4：写入放大怎么估算？**
按"每跨一个 tier 就全量重写一次"估算：`log(总数据量 / floorSegmentMB) / log(segmentsPerTier)` 次全量重写。30GB 分片、16MB 底层的量级是 4~5 次，即 8~10 倍放大。

**Q5：为什么日志索引不适合 forceMerge？**
日志索引按时间滚动，热数据持续写入，冷数据会被 ILM 删除。forceMerge 的收益期还没到，索引就被删了；而 `shrink` 用硬链接合并分片，成本低得多。

---

## 九、小结

- 段不可变 + 后台合并是 Lucene 的根基设计，合并策略本质是**写放大、查询延迟、磁盘占用**的三角权衡。
- `TieredMergePolicy` 靠"分层 + 打分"维持段结构，`segmentsPerTier` 控制层内段数，`maxMergedSegmentMB` 是硬保护，`deletesPctAllowed` 决定删除回收时机。
- 写放大要按 8~10 倍估算 IO 容量，只按原始写入量规划一定会在合并高峰翻车。
- forceMerge 只对**只读索引**有意义，执行前降副本、关 refresh、低峰限速，执行后补 flush、恢复副本。
- 监控段数、删除占比、合并耗时、合并限流四个指标，能把"凌晨 IO 玄学"变成可归因的工程问题。
