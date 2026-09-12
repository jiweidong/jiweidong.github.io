---
title: 【ES 运维】Elasticsearch 分片策略深度解析：分片数量设计、路由、扩容与 reindex 实战
date: 2026-09-12 08:00:00
tags:
  - Elasticsearch
  - 架构设计
  - 运维
categories:
  - Java
  - 中间件
author: 东哥
---

# 【ES 运维】Elasticsearch 分片策略深度解析：分片数量设计、路由、扩容与 reindex 实战

## 面试官：一个索引建几个分片？分片是不是越多越好？

这是 Elasticsearch 面试里出现频率最高、也最容易答错的问题。很多人第一反应是「分片越多，并行度越高，当然越快」—— 这个直觉在 ES 里是**错的**，分片数量配置不当是生产集群性能问题最常见的根源之一。

这篇从分片的本质讲起，把「分片数量怎么定 → 数据怎么路由 → 集群怎么扩容 → 主分片建错了怎么救」这条完整链路讲清楚。

## 一、分片到底是什么

ES 的一个索引（index）在物理上被拆成若干 **主分片（primary shard）**，每个主分片是一个**独立的 Lucene 索引**（拥有自己的倒排索引、段文件、translog）。副本分片（replica shard）是主分片的完整拷贝，负责高可用与分担读请求。

关键事实：

- **主分片数量在索引创建时就固定了，之后不能改**（这是所有扩容问题的根源）；
- 副本数量可以随时调整；
- 一个分片只能分配到一个节点上，**不能被进一步拆分并行**（Lucene 索引内部可以并行搜索，但分片本身是最小分配单位）；
- 所以：**分片 = 并行度单位 = 资源分配单位 = 故障恢复单位**。

## 二、分片数量设计：三个约束条件

### 2.1 单个分片大小：10GB ~ 50GB

这是官方推荐区间，也是实践中最稳的经验值：

- **太小（< 1GB）**：分片数暴涨，元数据、段合并、集群状态开销压过收益；
- **太大（> 50GB）**：单分片恢复慢（一个分片挂了要重放很久）、段合并压力大、查询在单分片内并行度受限。

一个典型业务索引「每天 20GB，保留 30 天」的算法：

```
总分片 ≈ 单日数据量 × 保留天数 ÷ 目标分片大小
     ≈ 20GB × 30 ÷ 30GB ≈ 20 个主分片
```

但注意：**不要一开始就按 30 天的量去建**，更好的做法是**按天/按时间滚动（rollover）**，每个小索引用少量分片。

### 2.2 堆内存与分片比例：每 GB 堆最多 20 个分片

```
节点建议堆内存 ≤ 31GB（压缩指针边界）
20 个分片 / GB 堆 → 30GB 堆 ≈ 600 个分片/节点（上限，不是目标）
```

超过这个量级会出现：

- **集群状态（cluster state）膨胀**：每个分片都会在集群状态里留元数据，分片数上万后，master 更新集群状态变慢，全集群出现「卡顿式」停顿；
- **文件句柄耗尽**：每个分片都有多组文件句柄；
- **段合并线程争抢**：分片多 → 段多 → 合并压力大 → IO 打满。

所以**分片数的第一原则是「在满足单分片大小合理的前提下，尽量少」**。

### 2.3 数据节点数与副本数

- `总分片数（主+副本）` 最好能被 `数据节点数` 整除，这样分片分布均匀，不会出现「某个节点分片特别多」的热点；
- 副本数 ≥ 1 保证高可用；读多写少的场景可以提高副本数以扩展读吞吐，但副本会放大写入（每次写都要同步到所有副本）。

**举例**：3 个数据节点、每节点 1 个副本、想每个节点分 2 个主分片 → 主分片数 = `3 × 2 = 6`，总分片 = 12。

## 三、分片路由：数据到底进哪个分片

### 默认路由

```java
shard = hash(routing) % number_of_primary_shards
```

其中 `routing` 默认是文档 `_id`。

**这里藏着最重要的一条规则**：公式里的 `number_of_primary_shards` 是分母。如果主分片数可以改，那么所有已存文档的路由就全错了。**这正是「主分片数不可变」的根本原因** —— 不是 ES 不想支持，而是路由算法的数学约束。

### 自定义路由

```json
PUT /orders/_doc/1001?routing=user_9527
{
  "user_id": 9527,
  "amount": 199
}
```

```sql
GET /orders/_search
{
  "query": { "match": { "user_id": 9527 } },
  "_source": ["amount"],
  "size": 10
}
-- 查询时指定 routing，可以只广播到一个分片
```

自定义路由的价值：

- **相关数据聚到同一分片**：如按 `user_id` 路由，则「查某个用户的所有订单」只需命中 1 个分片，而不是广播到 N 个分片再合并；
- **降低查询扇出（fan-out）**，显著降低协调节点的合并开销。

代价：

- **数据倾斜风险**：如果按 `tenant_id` 路由，而某个租户数据量占 60%，就会形成热分片（hot shard），负载严重不均；
- 需要业务上保证「查询条件里总能带上 routing 值」，否则优势全无。

**选择建议**：只有当「某个维度的数据总是被一起查询」且「该维度分布足够均匀」时，才用自定义路由。否则用默认。

## 四、集群扩容：三种路径

### 4.1 加节点 + 副本重分配（最平滑）

数据量增长但**还没到单分片上限**时，加数据节点即可。ES 会自动触发分片重分配（rebalance），把部分分片搬到新节点。

```json
PUT _cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.enable": "all",
    "cluster.routing.rebalance.enable": "all",
    "indices.recovery.max_bytes_per_sec": "200mb",
    "cluster.routing.allocation.node_concurrent_recoveries": 4
  }
}
```

> 重分配会消耗网络与磁盘 IO。生产上建议：
> ① 手动搬迁热点分片（`POST _cluster/reroute` 的 `move` 指令）而不是全量 rebalance；
> ② 限制 `max_bytes_per_sec`，避免抢走业务 IO；
> ③ 大集群扩容放在低峰期。

### 4.2 主分片不够了：split / shrink

**split** 把主分片数翻倍（3 → 6 → 12），分摊单分片体积；**shrink** 反过来合并分片。两者都是**索引级别**的操作，且要求索引只读（或先设为只读）。

```json
// split 前置：索引必须只读且健康
PUT /orders-2026.09/_settings
{ "settings": { "index.blocks.write": true } }

POST /orders-2026.09/_split/orders-2026.09-split
{
  "settings": { "index.number_of_shards": 6 }
}

// shrink：先迁移到同节点的少量分片
POST /orders-2026.09/_shrink/orders-2026.09-shrink
{
  "settings": {
    "index.number_of_shards": 1,
    "index.routing.allocation.require._name": "node-1"
  }
}
```

### 4.3 主分片严重不足 / 需要改结构：reindex

**reindex** 是通关大招：从源索引用 `_reindex` 把数据搬到目标索引（可以指定目标分片数、副本数、mapping），必要时配合别名原子切换。

```json
POST _reindex?wait_for_completion=false&scroll=5m
{
  "source": {
    "index": "orders-v1",
    "_source": ["user_id", "amount", "created_at"]
  },
  "dest": {
    "index": "orders-v2",
    "routing": "=user_id"
  },
  "conflicts": "proceed"
}
```

```json
// 切换别名：原子操作
POST _aliases
{
  "actions": [
    { "remove": { "index": "orders-v1", "alias": "orders" } },
    { "add":    { "index": "orders-v2", "alias": "orders" } }
  ]
}
```

reindex 的注意事项：

- **不保证实时**：只复制执行时的快照，增量写入需要额外追（双写 / CDC / 滚动推进）；
- **必须设 `wait_for_completion=false`**：否则 HTTP 连接会被大索引拖断；
- **限流**：`"size": 5000`、`"slices"`（切片并行）、`requests_per_second` 控制对生产的影响；
- **版本冲突**：目标已有文档时用 `version_type: external` 或 `conflicts: proceed`；
- **v2 写入双写**：生产切换通常要「双写 → 回填 → 校验 → 切别名 → 停旧写」四步。

### 三种方式对比

| 方式 | 主分片数 | 数据量 | 阻断写入 | 适用场景 |
| --- | --- | --- | --- | --- |
| 加节点 | 不变 | 不变 | 否 | 单分片还小、只是负载高 |
| split | 翻倍 | 不变 | 需只读 | 单分片过大、需提升并行度 |
| shrink | 减少 | 不变 | 需只读 | 小分片碎片过多、需要治理 |
| reindex | 任意 | 重写 | 通常可不停 | 改分片数+改 mapping+换路由 |

## 五、滚动索引与 ILM：从一开始就做对

**分片设计最好的实践不是「算准分片数」，而是「用小索引 + 滚动 + 别名」让分片数不再是难题。**

```json
// 创建带 rollover 别名的初始索引
PUT /orders-000001
{
  "aliases": { "orders": { "is_write_index": true } },
  "settings": { "index.number_of_shards": 3 }
}

// 达到条件自动滚动
POST /orders/_rollover
{
  "conditions": { "max_size": "30gb", "max_age": "7d", "max_docs": 200000000 },
  "settings": { "index.number_of_shards": 3 }
}
```

配合 **ILM（Index Lifecycle Management）** 实现自动化：

- hot：写入，`rollover`；
- warm：不再写，`force_merge` + `shrink`；
- cold：`read_only`，迁到廉价节点；
- delete：到期删除。

这样每个索引永远只有 30GB 左右、分片数恒定，集群规模增长时只需调整 `max_size` 门槛。

## 六、分片分配与磁盘水位线

ES 用磁盘水位线决定是否继续往某节点分配分片：

| 水位线 | 默认值 | 行为 |
| --- | --- | --- |
| `low` | 85% | 不再分配新分片到该节点 |
| `high` | 90% | 开始把分片从该节点迁走 |
| `flood_stage` | 95% | 将索引置为只读（`index.blocks.read_only_allow_delete`） |

```json
PUT _cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.disk.watermark.low": "85%",
    "cluster.routing.allocation.disk.watermark.high": "90%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "95%"
  }
}
```

**flood_stage 是生产事故高发区**：一旦触发，所有写入失败，报 `FORBIDDEN/12/index read-only`。处理步骤：

```json
// 1. 清理磁盘后解除只读
PUT _all/_settings
{ "index.blocks.read_only_allow_delete": null }
```

## 七、常见分片陷阱

**陷阱一：分片数拍脑袋定 5 或 10。**
没有依据，一年后单分片 200GB，查询慢、恢复更慢，只能 reindex。

**陷阱二：分片数远超节点数，且没有副本。**
单节点故障 = 大量未分配分片，集群进入 yellow/red，恢复窗口极长。

**陷阱三：小索引建了 12 个分片。**
例如每个用户一个索引、每个索引 12 分片 —— 分片数瞬间上万，master 压力爆炸。**小索引就该用 1 个分片。**

**陷阱四：热分片。**
自定义 routing 不均、或时间序列数据按 `_id` 随机路由而查询总按时间范围 —— 结果是查询广播到所有分片，只有部分分片有数据却都要扫描。时间序列索引应按 `_routing` 或干脆按天建索引。

**陷阱五：随时扩主分片数。**
做不到。主分片数在创建时固定，唯一出路是 split / shrink / reindex。

## 八、监控与排查命令

```bash
# 分片分布与大小
GET _cat/shards/orders?v&s=store:desc

# 未分配分片及其原因
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason

# 集群健康与分片统计
GET _cluster/health?level=indices

# 单节点分片数（找热点节点）
GET _cat/allocation?v

# 分片级别的索引大小/文档数
GET _cat/indices?v&s=store.size:desc
```

判断「分片是否合适」的经验指标：

- 单分片 > 50GB → 考虑 split 或滚动；
- 单节点分片数 > 20 × 堆GB → 需要治理；
- 未分配分片持续存在 → 检查水位线、节点状态、`allocation.explain`。

```json
GET /_cluster/allocation/explain
{
  "index": "orders-2026.09",
  "shard": 0,
  "primary": true
}
```

这个 API 会直接告诉你「为什么这个分片分配不出去」，是排查 unassigned shard 的第一工具。

## 九、面试常见追问

**Q1：为什么主分片数不能改？**
因为路由公式 `hash(routing) % number_of_primary_shards` 用主分片数做模。一旦改变分母，已有文档按新公式计算出的目标分片与它实际所在的分片不一致，会导致**数据大量「丢失」**（其实还在旧分片，但查询按新路由找不到）。所以只能通过 split/shrink/reindex 重建。

**Q2：分片越多查询越快吗？**
不是。分片带来并行度，但也带来：① 每个分片独立的段与查询开销；② 协调节点需要合并更多分片的结果（merge overhead）；③ 集群状态与元数据膨胀。存在一个最优区间，超过后**性能反而下降**。对小数据集，1 个分片往往是最快的。

**Q3：副本能提升写入性能吗？**
不能，反而降低。每次写入要同步到所有副本（分布式一致性要求），副本越多写入放大越严重。副本提升的是**读吞吐**和**可用性**。

**Q4：集群扩容后旧数据没有分布到新节点怎么办？**
分片重分配（rebalance）是自动的，但受 `cluster.routing.rebalance.enable`、水位线、`max_bytes_per_sec` 影响。也可以用 `POST _cluster/reroute` 手动 move 指定的热点分片。若要真正重排数据布局，仍推荐「滚动新索引 + 逐步切别名」的路线，而不是搬迁旧分片。

**Q5：如何为时间序列数据设计分片？**
按时间滚动建索引（如 `logs-2026.09.12`），每个索引分片数少（1~3），用别名统一查询，用 ILM 管理生命周期。查询时用时间范围过滤 + 别名，ES 会自动跳过不相关的索引（索引裁剪），比「一个大索引 + 多分片」高效得多。

## 十、小结

| 主题 | 关键结论 |
| --- | --- |
| 分片大小 | 单分片 10~50GB 为宜 |
| 分片数量 | 在满足大小前提下尽量少；单节点 ≤ 20×堆GB |
| 主分片数 | 创建时固定，靠 split/shrink/reindex 变更 |
| 路由 | 默认 `hash(_id) % 主分片数`；可按需自定义 routing |
| 扩容 | 加节点 → split/shrink → reindex，能力依次递增 |
| 最佳实践 | 小索引 + rollover + 别名 + ILM，让分片数不再是问题 |
| 排查 | `_cat/shards`、`_cluster/allocation/explain`、水位线设置 |

分片设计的核心心法只有一句：**把「分片数量」当成一个架构决策，而不是一个可以随便填的配置项。** 想清楚数据量、增长曲线、查询模式和扩容路径之后再按下创建键，能省掉未来无数次痛苦的 reindex。
