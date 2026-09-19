---
title: 【ES 运维】分片分配与集群规划深度实战：unassigned shard、reroute 与再平衡全解析
date: 2026-09-19 08:30:00
tags:
  - Elasticsearch
  - 分布式
  - 运维
  - 中间件
categories:
  - Elasticsearch
  - 中间件实战
author: 东哥
---

# 【ES 运维】分片分配与集群规划深度实战：unassigned shard、reroute 与再平衡全解析

## 面试官：集群是 yellow 状态，你怎么办？

Yellow 是 Elasticsearch 生产环境最常见的"半故障"：主分片全部就绪，副本分片没能分配。它不阻塞读写，所以很多人选择无视——直到某天一个节点宕机，yellow 变成 red，业务直接不可用。

要真正解决 yellow 和 red，必须理解 ES 的**分片分配（Shard Allocation）**机制：谁在决策、依据什么决策、什么时候会拒绝分配。这篇文章从集群规划讲到故障处置，把分配链路完整拆开。

## 一、先搞清楚：分片分配的决策者是谁

ES 7.x 之后，分配决策由 **Master 节点的 `AllocationService`** 负责，配合三个组件：

| 组件 | 职责 |
| --- | --- |
| `AllocationDeciders` | 一串"是否允许分配"的过滤器（过滤器模式），任何一个否决就跳过 |
| `ShardsAllocator` | 在通过决策器的节点中，选一个"最合适"的（均衡度、磁盘水位） |
| `BalancedShardsAllocator` | 默认实现，用权重公式计算节点"负担"并做最小化收敛 |

`AllocationDeciders` 默认包含 11 个决策器，常见的几个：

- `SameShardAllocationDecider`：同一分片的主副本不能在同一节点；
- `DiskThresholdDecider`：磁盘水位超限就不再分配；
- `AwarenessAllocationDecider`：机架/可用区感知；
- `FilterAllocationDecider`：`index.routing.allocation.*` 与 `cluster.routing.allocation.*` 过滤；
- `MaxRetryAllocationDecider`：超过 `index.allocation.max_retries`（默认 5）不再自动重试。

**排查 yellow 的第一步，永远是查出"哪个决策器否决了"**：

```bash
# ES 7.16+ 内置诊断（最推荐）
GET _cluster/allocation/explain
{
  "index": "orders",
  "shard": 3,
  "primary": false
}

# 不指定分片时，返回第一个未分配分片的解释
GET _cluster/allocation/explain
```

返回体里的关键字段：

```json
{
  "current_state": "unassigned",
  "unassigned_info": {
    "reason": "NODE_LEFT",
    "at": "2026-09-18T22:13:07.881Z",
    "details": "node_left [abc123...]"
  },
  "can_allocate": "no",
  "allocate_explanation": "cannot allocate because allocation is not permitted to any of the nodes",
  "node_allocation_decisions": [
    {
      "node_name": "es-data-2",
      "deciders": [
        { "decider": "disk_threshold", "decision": "NO",
          "explanation": "the node is above the high watermark cluster setting..." }
      ]
    }
  ]
}
```

**`unassigned_info.reason` 是分诊表**：

| reason | 含义 | 处置方向 |
| --- | --- | --- |
| `NODE_LEFT` | 节点离线 | 等节点回来，或强制分配 |
| `NODE_RESTARTING` | 节点重启中 | 等待 `index.unassigned.node_left.delayed_timeout`（默认 1m） |
| `NEW_INDEX_RESTORED` | 快照恢复 | 等恢复完成 |
| `ALLOCATION_FAILED` | 分配尝试失败 | 看失败原因，可能需 `retry_failed=true` |
| `REPLICA_ADDED` | 新增副本 | 磁盘/决策器限制 |
| `CLUSTER_RECOVERED` | 集群重启恢复 | 等待或提高并发恢复 |
| `INDEX_CREATED` | 新建索引 | 通常自动完成 |
| `NO_VALID_SHARD_COPY` | 无有效副本（**red 的典型原因**） | 需从快照恢复或强制分配 |

## 二、磁盘水位：90% 的 yellow/red 都由它引起

ES 用三个水位线控制分配，默认值如下：

```yaml
cluster.routing.allocation.disk.threshold_enabled: true
cluster.routing.allocation.disk.watermark.low: 85%
cluster.routing.allocation.disk.watermark.high: 90%
cluster.routing.allocation.disk.watermark.flood_stage: 95%
```

行为差异非常关键：

| 水位 | 行为 |
| --- | --- |
| low (85%) | **不再向该节点分配新分片**（已有分片不受影响） |
| high (90%) | **主动把分片迁走**（rebalance/relocate） |
| flood_stage (95%) | 索引被置为 **read-only**（`index.blocks.read_only_allow_delete=true`），写入报错 |

这解释了最典型的线上事故链：**磁盘涨到 90% → 分片迁移把其他节点磁盘也推高 → 连锁突破 95% → 全集群写入失败**。

### 磁盘涨了，如何正确止血

```bash
# 1) 找占空间最大的索引（注意：这是"逻辑"大小）
GET _cat/indices?v&s=store.size:desc&h=index,pri,rep,store.size,docs.count

# 2) 应急：临时放宽水位（不要关掉，只调高）
PUT _cluster/settings
{
  "transient": {
    "cluster.routing.allocation.disk.watermark.low": "92%",
    "cluster.routing.allocation.disk.watermark.high": "95%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "97%"
  }
}

# 3) 若已 read-only，先解锁再清理
PUT */_settings
{ "index.blocks.read_only_allow_delete": null }

# 4) 真正清理：删除/归档历史索引（按 ILM 或手动）
DELETE /logs-2026.08.*

# 5) 强制段合并释放已删除文档空间（开销大，低峰执行）
POST /logs-2026.09.01/_forcemerge?only_expunge_deletes=true&max_num_segments=1
```

**删除文档不等于释放磁盘**：Lucene 是段（segment）结构，`DELETE` 只是标记，段合并时才真正回收。这就是 `_forcemerge?only_expunge_deletes=true` 的用途。

另外一个反直觉点：**`_cat/indices` 的 `store.size` 不包含 translog、未合并段的冗余**。真实占用要用 `_cat/allocation?v` 看节点的 `disk.used_percent`。

## 三、分片规划：数量错了后面全是坑

分片不是越多越好。分片是 Lucene 实例，每个都要消耗：堆内存（segment 元数据、field data 结构）、文件句柄、集群状态条目、查询时的 gather 阶段线程。

**经验公式**：

1. **单分片大小控制在 10-50GB**（日志类可放宽到 50GB，搜索类建议 20-30GB）；
2. **分片总数（主+副本）控制在 `节点数 * 20` 以内**，堆 30GB 以内节点建议每 1GB 堆对应 ≤ 20 个分片；
3. **索引数量不要爆炸**：日建索引要配合 ILM，避免几万个小索引拖垮集群状态。

```bash
# 评估：数据量 / 目标单分片大小 = 主分片数
# 例：每天 100GB 日志，单分片 30GB → 4 个主分片（取整并按节点数调整）
PUT _index_template/logs-template
{
  "index_patterns": ["logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 4,
      "number_of_replicas": 1,
      "refresh_interval": "30s",
      "translog": { "durability": "async", "sync_interval": "30s" }
    },
    "mappings": {
      "dynamic": false,
      "properties": {
        "@timestamp": { "type": "date" },
        "level": { "type": "keyword" },
        "service": { "type": "keyword" },
        "message": { "type": "text" }
      }
    }
  }
}
```

**重大提醒**：主分片数**创建后不可修改**（ES 6.x 之后 `_shrink`/`_split` 需要满足 `_block.write` + 只读等条件）。规划时一定要用"当前数据量 + 12 个月增长率"估算，而不是按当前数据量。

## 四、分配过滤：把分片放到该去的地方

三种过滤维度，优先级从高到低：

```bash
# 1) 索引级过滤（最高优先级）
PUT /orders/_settings
{
  "index.routing.allocation.require.tier": "hot",
  "index.routing.allocation.include.zone": "az-1,az-2",
  "index.routing.allocation.exclude._name": "es-data-3"
}

# 2) 集群级过滤（全局默认）
PUT _cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.exclude._ip": "10.0.0.13",
    "cluster.routing.allocation.awareness.attributes": "zone",
    "cluster.routing.allocation.awareness.force.zone.values": "az-1,az-2"
  }
}
```

三种语义要分清：

| 关键字 | 语义 |
| --- | --- |
| `require` | 必须匹配（AND，硬约束） |
| `include` | 至少匹配其一（OR） |
| `exclude` | 排除（优先级高于 include/require？实际是 exclude 直接否决） |

**`awareness` 是集群容灾的基石**：设置 `awareness.attributes: zone` 后，同一分片的主副本会被强制打散到不同 zone；再加 `force.zone.values` 保证每个 zone 都有一份（否则副本数不足时会 yellow）。

## 五、再平衡：什么时候动，动多少

再平衡由 `cluster.routing.allocation.balance.*` 权重控制：

```yaml
cluster.routing.allocation.balance.shard: 0.45     # 分片数量均衡权重
cluster.routing.allocation.balance.index: 0.55    # 同索引分片分散权重
cluster.routing.allocation.balance.threshold: 1.0 # 触发阈值，越大越不敏感
cluster.routing.rebalance.enable: all             # all/primaries/replicas/none
```

**生产上两个必须调整的场景**：

1. **节点扩容时**：新节点加入会触发大规模搬迁，把 IO 打满。正确做法是**分级限流**：

```bash
PUT _cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.node_concurrent_recoveries": 2,
    "cluster.routing.allocation.node_initial_primaries_recoveries": 4,
    "indices.recovery.max_bytes_per_sec": "80mb",
    "cluster.routing.allocation.cluster_concurrent_rebalance": 2
  }
}
```

`cluster_concurrent_rebalance` 默认 2、`node_concurrent_recoveries` 默认 2 都偏大，在机械盘或小集群上会引发 `recovery` 风暴与查询超时。**先限速，再让迁移慢慢完成**。

2. **滚动重启时**：关掉 rebalance，避免重启期间无意义搬迁。

```bash
PUT _cluster/settings
{ "persistent": { "cluster.routing.rebalance.enable": "none" } }
# ...重启节点...
PUT _cluster/settings
{ "persistent": { "cluster.routing.rebalance.enable": null } }
```

### 手动 reroute：最后的武器，也是最大的坑

```bash
# 1) 把未分配副本分配到指定节点
POST _cluster/reroute
{
  "commands": [
    { "allocate_replica": { "index": "orders", "shard": 2, "node": "es-data-3" } }
  ]
}

# 2) 分片迁移（move）
POST _cluster/reroute
{
  "commands": [
    { "move": { "index": "orders", "shard": 0, "from_node": "es-data-1", "to_node": "es-data-4" } }
  ]
}

# 3) 主分片丢失时的强制分配（危险！）
POST _cluster/reroute?dry_run=true
{
  "commands": [
    { "allocate_stale_primary": { "index": "orders", "shard": 2, "node": "es-data-3", "accept_data_loss": true } }
  ]
}
```

**`allocate_stale_primary` 会丢数据**，只在以下情况使用：确认原主分片所在节点永久不可用、且已无副本、且该索引数据可从其他数据源重建（如日志）。务必先 `dry_run=true`，再摘掉 `/dev/null` 式的盲目操作。

## 六、Red 状态的完整处置流程

Red = 至少一个主分片未分配。SOP 如下：

```bash
# 1) 定位 red 索引与分片
GET _cat/indices?v&health=red
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason&s=state

# 2) 逐个查原因
GET _cluster/allocation/explain

# 3) 按 reason 处置
#    NODE_LEFT + 节点会回来 → 等待（可临时调大 delayed_timeout）
PUT /orders/_settings
{ "index.unassigned.node_left.delayed_timeout": "10m" }

#    磁盘水位 → 清盘 + 解锁 read_only
#    决策器否决 → 修正过滤规则
#    分配失败已超重试 → 重试
POST _cluster/reroute?retry_failed=true
```

**最坏情况（无有效副本）**：从快照恢复，或接受数据丢失后 `allocate_stale_primary` + `allocate_empty_primary`（后者直接创建空分片，数据全丢）。

```bash
# 放弃该分片数据，创建空主分片（最后手段）
POST _cluster/reroute
{
  "commands": [
    { "allocate_empty_primary": {
        "index": "orders", "shard": 2, "node": "es-data-3",
        "accept_data_loss": true } }
  ]
}
```

## 七、集群规划的最佳实践

1. **专有角色分离**：`master`、`data_hot/warm/cold`、`ingest`、`coordinating` 分开部署。Master 节点用低配多副本（3 个专职），绝不承载 data 角色。
2. **Master 数量 = 3 或 5**，`discovery.seed_hosts` + `cluster.initial_master_nodes` 一次性配好，避免脑裂。
3. **堆大小 ≤ 31GB**（压缩指针生效上限），且不超过物理内存的 50%（剩下一半留给 Lucene 的文件缓存）。
4. **`bootstrap.memory_lock: true`** 锁定堆内存，避免 swap 导致查询停顿。
5. **多可用区部署 + awareness 强制分散**，把"节点故障"降级为"性能下降"。
6. **ILM 全生命周期管理**：热→温→冷→删除，rollover 用 `max_primary_shard_size: 30gb` 而非按天滚动。
7. **容量监控四件套**：`disk.used_percent`、`unassigned_shards`、`pending_tasks`、`thread_pool.write.queue`。
8. **定期演练**：随机 kill 一个 data 节点，验证副本能在几分钟内补齐、查询不受影响。

## 八、面试追问

**Q1：yellow 会不会导致数据丢失？**
不会。副本缺失只降低冗余度；一旦承载唯一副本的节点宕机，才会变 red（数据不可用）。

**Q2：为什么节点离开后要等 1 分钟才开始分配副本？**
`index.unassigned.node_left.delayed_timeout` 默认 60s，用于避免短暂重启引发的无意义分片重分配（重分配开销远大于等待）。

**Q3：`_cluster/reroute` 的 `move` 会不会丢数据？**
正常 `move` 先复制分片到目标节点，成功后才删除源分片，不丢数据（Lucene 快照 + 增量同步保证一致性）。

**Q4：分片数是不是越多，写入吞吐越高？**
不是。分片过多会带来 cluster state 膨胀、gather 阶段开销、segment 合并压力。经验上，单节点每 1GB 堆对应 20 个分片是上限。

**Q5：如何判断该加节点还是该减分片？**
看 `_cat/allocation` 每节点分片数与磁盘使用率是否均衡；若磁盘均衡但 CPU 打满，说明是查询/写入负载问题，加节点收益有限，应先优化 mapping 与查询。

## 九、总结

ES 的分片分配是一套**决策器过滤 + 均衡器打分**的机制：

- 遇到 yellow/red，**第一动作是 `_cluster/allocation/explain`**，不要瞎 `reroute`；
- **磁盘水位是头号元凶**，止血顺序是"临时放宽 → 解锁 read-only → 清理/归档 → forcemerge"；
- **分片规划要前置**，主分片数不可改，按"数据量 ÷ 20-30GB"估算并留增长余量；
- **再平衡要限速**，扩容与滚动重启期间主动 `rebalance.enable=none`；
- **`allocate_stale_primary` / `allocate_empty_primary` 是丢数据的操作**，只在数据可重建时使用。

把这些机制弄明白，yellow/red 就不再是"玄学状态"，而是可解释、可干预、可预防的确定性系统行为。
