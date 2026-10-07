---
title: 【ES 实战】索引别名与零停机重建索引深度实战：Alias、_reindex 与原子切换
date: 2026-10-07 08:30:00
tags:
  - Elasticsearch
  - 中间件
  - 索引
  - 零停机
categories:
  - Java
  - 中间件
author: 东哥
---

# 【ES 实战】索引别名与零停机重建索引深度实战：Alias、_reindex 与原子切换

## 面试官：线上索引要改 mapping，怎么做到不停服？

> "index `order_v1` 里 `remark` 字段是 `text`，现在要做聚合统计需要 `keyword`。数据量 2 亿条，业务 7×24 小时不能停。你怎么改？"

很多人第一反应是"改成 `keyword` 就行"，但 Elasticsearch 的底层是 Lucene，**已写入的段（segment）不可变，mapping 不能直接修改字段类型**（除少数例外，如新增字段、`ignore_above` 等）。

能改的情况极少，绝大多数类型变更只能走同一条路：

> **建一个新索引 → 把数据搬过去 → 用别名原子切换 → 删掉旧索引。**

而这套流程能做到"零停机"的关键，就是 **Index Alias（索引别名）**。这一篇把 Alias + `_reindex` + 原子切换讲成一套可复制的生产方案。

## 一、Alias 是什么，为什么它能实现零停机

别名就是**指向一个或多个索引的"指针"**，应用只认别名，不认真实索引名：

```json
POST /_aliases
{
  "actions": [
    { "add": { "index": "order_v1", "alias": "order" } }
  ]
}
```

之后所有读写都用 `order`：

```java
// 应用代码里永远写别名，不写版本号
GET order/_search
POST order/_doc/123
```

**零停机的本质**：切换别名时，把 `order` 从 `order_v1` 指向 `order_v2`，这是一次**原子操作**——客户端要么全看到旧索引，要么全看到新索引，不存在"一半写旧一半读新"的中间态。

### 别名的两种用法

| 用法 | 说明 | 示例场景 |
| --- | --- | --- |
| 版本切换别名 | 一对一指，用于 mapping 变更、重建 | `order` → `order_v2` |
| 过滤别名（Filtered Alias） | 别名内嵌 query，看到"子集" | 多租户：每租户一个别名 |
| 路由别名（Routing Alias） | 别名带 `routing`，写入时固定分片 | 按用户 ID 路由优化 |
| 写入别名 | 一个别名只允许指向一个索引并可写 | 保证写入唯一目标 |

过滤别名示例（常见于多租户 / 冷热分层）：

```json
POST /_aliases
{
  "actions": [
    {
      "add": {
        "index": "order_v1",
        "alias": "order_tenant_1001",
        "filter": { "term": { "tenantId": 1001 } },
        "routing": "1001"
      }
    }
  ]
}
```

### 关键约束：一个别名指向多个索引时，写入会失败

```json
{ "add": { "index": "order_v1", "alias": "order" } },
{ "add": { "index": "order_v2", "alias": "order" } }
```

这种"一对多"别名只能**读**（搜索会同时查两个索引并合并），**不能写**。所以切换过程中如果需要双写，必须由**应用层分别写两个真实索引**，而不是指望别名帮你双写。

## 二、_reindex：数据搬迁的正确姿势

`_reindex` 是 ES 自带的"读源索引、写目标索引"工具，本质是 scroll + bulk：

```json
POST /_reindex?wait_for_completion=false
{
  "source": {
    "index": "order_v1",
    "size": 2000,
    "query": { "range": { "createTime": { "gte": "now-1d" } } },
    "_source": ["orderId", "userId", "amount", "remark", "createTime"]
  },
  "dest": {
    "index": "order_v2",
    "op_type": "create"
  },
  "conflicts": "proceed",
  "script": {
    "lang": "painless",
    "source": "if (ctx._source.amount == null) { ctx._source.amount = 0L }"
  }
}
```

### 参数逐个说清楚

| 参数 | 作用 | 生产建议 |
| --- | --- | --- |
| `wait_for_completion` | 是否同步等待 | 大数据量一定 `false`，返回 `taskId` 轮询 |
| `source.size` | 每批读取条数 | 1000~5000，太大易触发 `search.max_buckets` / 内存压力 |
| `source._source` | 只搬需要的字段 | ✅ 强烈建议，省带宽省 IO |
| `source.query` | 只搬子集 | 增量迁移、部分重建时用 |
| `dest.op_type` | `index`（覆盖）或 `create`（冲突则报错） | 幂等重跑用 `create` |
| `conflicts` | `proceed`（跳过冲突）或 `abort` | 一般 `proceed` + `version_conflicts` 监控 |
| `slices` | 并行度（分片切片） | 调优关键，见下文 |
| `script` | 转换字段 | 字段改名/类型微调，比 Logstash 轻量 |

### 加速利器：并行 reindex（Sliced Reindex）

单线程 reindex 在亿级数据下会慢到无法接受。`slices=auto` 或指定数字开启并行：

```json
POST /_reindex?slices=auto&wait_for_completion=false
{
  "source": { "index": "order_v1", "size": 2000 },
  "dest":   { "index": "order_v2" }
}
```

底层是把源索引用 `_slice` 切成多份，每份跑一个 scroll。**注意**：`slices` 不是越大越好，通常设为**源索引主分片数**（或 2~4 倍），否则协调节点压力过大反而变慢。

### 两个必须提前压平的大坑

1. **目标索引的副本数先设 0**：reindex 期间副本的写入放大极其耗资源，搬完再设回来。
2. **调大 `refresh_interval`**：从 1s 调到 `-1` 或 `60s`，让段合并更充分，吞吐能提升数倍。

```json
PUT /order_v2/_settings
{ "index": { "number_of_replicas": 0, "refresh_interval": "-1" } }

// 搬完再恢复
PUT /order_v2/_settings
{ "index": { "number_of_replicas": 1, "refresh_interval": "1s" } }
```

### 监控进度

```json
// 看 reindex 任务进度
GET /_tasks/<taskId>
// 或者由任务 API 列出所有 reindex
GET /_tasks?actions=*reindex&detailed=true

// 直接对比文档数（最直观）
GET order_v1/_count
GET order_v2/_count
```

## 三、原子切换：一次请求完成"摘旧挂新"

这是核心步骤。`POST /_aliases` 支持在**同一个请求**里做多个 actions，并且是**原子生效**的：

```json
POST /_aliases
{
  "actions": [
    { "remove": { "index": "order_v1", "alias": "order" } },
    { "add":    { "index": "order_v2", "alias": "order" } }
  ]
}
```

**绝对不要写成两条独立请求**：

```bash
# ❌ 中间有窗口期：别名要么不存在（写入报错），要么一子指向两个索引（写入失败）
curl -X POST '/_aliases' -d '{"actions":[{"remove":{"index":"order_v1","alias":"order"}}]}'
curl -X POST '/_aliases' -d '{"actions":[{"add":{"index":"order_v2","alias":"order"}}]}'
```

分开写会产生一个**短暂的"别名不存在"或"双指"窗口**，前者导致写入落到自动创建的索引上（灾难），后者导致写入直接失败（`illegal_argument_exception: write index is not specified`）。批量 actions 才是不停机方案的命门。

### 完整切换脚本（含校验，可回滚）

```bash
#!/usr/bin/env bash
set -euo pipefail

ES="${ES:-http://localhost:9200}"
OLD="order_v1"
NEW="order_v2"
ALIAS="order"

echo "== 1. 校验目标索引文档数 =="
OLD_COUNT=$(curl -s "$ES/$OLD/_count" | grep -o '"count":[0-9]*' | cut -d: -f2)
NEW_COUNT=$(curl -s "$ES/$NEW/_count" | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "old=$OLD_COUNT new=$NEW_COUNT"

if [ "$NEW_COUNT" -lt "$OLD_COUNT" ]; then
  echo "❌ 新索引数据不完整，中止切换"
  exit 1
fi

echo "== 2. 恢复新索引设置（副本 + refresh） =="
curl -s -X PUT "$ES/$NEW/_settings" -H 'Content-Type: application/json' -d '{
  "index": { "number_of_replicas": 1, "refresh_interval": "1s" }
}'

echo "== 3. 原子切换别名 =="
curl -s -X POST "$ES/_aliases" -H 'Content-Type: application/json' -d "{
  \"actions\": [
    { \"remove\": { \"index\": \"$OLD\", \"alias\": \"$ALIAS\" } },
    { \"add\":    { \"index\": \"$NEW\", \"alias\": \"$ALIAS\" } }
  ]
}"

echo "== 4. 验证 =="
curl -s "$ES/_cat/aliases/$ALIAS?v"

echo "✅ 切换完成。观察 30 分钟无异常后，再删除 $OLD"
```

### 回滚：把 actions 反过来即可

```bash
curl -s -X POST "$ES/_aliases" -H 'Content-Type: application/json' -d '{
  "actions": [
    { "remove": { "index": "order_v2", "alias": "order" } },
    { "add":    { "index": "order_v1", "alias": "order" } }
  ]
}'
```

**前提是旧索引还没删**。所以生产节奏应该是：**切换 → 观察 30 分钟以上 → 灰度确认 → 删除旧索引**。删早了就没有回滚路径了。

## 四、切换期间的增量数据怎么办？

这是最容易被漏掉的一环：**reindex 是有耗时的，期间新写入的数据不会自动进新索引**。三种处理方式：

| 方案 | 做法 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 双写 | 应用同时写 v1 和 v2 | 简单，切换后数据无缝 | 应用改造成本，写放大 |
| 先写 v1 再增量补 | 切换前对 v2 做一次窗口内 reindex | 应用零改造 | 需要精确的时间窗口，易漏 |
| 停写窗口 | 短暂停写 + 切换 | 数据最干净 | 有停机，与题目矛盾 |
| CDC / Logstash | binlog 同步到 v2 | 对应用透明 | 需额外组件（Canal + Logstash） |

**最常用的混合方案**（推荐）：

```
1. 建 v2，开始全量 reindex（后台，slices=auto）
2. 全量完成，记录 checkpoint 时间 T1
3. 对 [T1 - 5min, now] 做一次增量 reindex（覆盖旧数据，用 op_type=index 幂等）
4. 原子切换别名
5. 应用改为双写（或直接关闭 v1 写入），观察 30 分钟
6. 删除 v1
```

第 3 步的"**时间回退 5 分钟**"是为了覆盖"全量扫描 `_count` 那一刻之后、但 reindex 尚未扫到"的边界数据。配合 `_source` 里的 `updateTime` 字段做范围查询即可。

## 五、生产避坑清单

| 坑 | 现象 | 规避 |
| --- | --- | --- |
| 别名双指后写入失败 | `write index is not specified` | 用单次 `_aliases` 批量 actions |
| 删了旧索引无回滚 | 切换出问题无法退回 | 观察期后再删，先 `_close` 也可以 |
| reindex 打满集群 | 搜索 RT 飙升、节点 CPU 100% | 限速：`slices` 适量 + 低峰执行 + 目标副本先设 0 |
| 副本先建了 | reindex 慢几倍 | 目标索引先 `number_of_replicas=0` |
| 忘了 refresh | 切换后搜不到新数据 | 恢复 `refresh_interval=1s` 并手动 `POST /order_v2/_refresh` |
| 应用硬编码索引名 | 切换后应用仍读写旧索引 | 代码里统一走别名字符串常量 |
| 别名权限没配 | 运维切了别名，应用无权限 | RBAC 里把别名索引权限一起授予 |
| 只改 mapping 不想重建 | 发现改不了 | 记牢：**Lucene 段不可变，类型变更必须重建** |

## 六、面试追问速查

| 追问 | 回答要点 |
| --- | --- |
| 为什么 mapping 不能直接改？ | Lucene 倒排索引与 doc_values 已按旧类型物理写入，段不可变，改类型只能重写数据 |
| 别名能实现"写一个、读多个"吗？ | 不能，写入别名必须唯一；读时一对多会合并结果 |
| `_reindex` 的限速方式？ | 调小 `size`、减少 `slices`、开 `requests_per_second`（新版支持限速） |
| 怎么保证 reindex 幂等可重跑？ | `op_type=create` + `conflicts=proceed`，用 `version_conflicts` 数判断是否重复 |
| 切换后如何确认生效？ | `GET /_cat/aliases/order?v`，并校验 `_cat/indices` 的 docs.count，再跑一次典型查询回归 |
| 2 亿数据要多久？ | 取决于磁盘与分片数，通常低于 2000 条/s/分片；用 `slices=主分片数` 并行可线性加速 |
| 不想重建还有别的办法吗？ | 可以：新增字段（如 `remark.keyword` 子字段）不需要重建；仅从 `text` 改 `keyword` 这类才必须重建 |

## 小结

零停机重建索引的完整闭环：

1. **建新索引**，mapping 目标结构，副本设 0、refresh 调大；
2. **`_reindex` 搬数据**（`slices` 并行 + `wait_for_completion=false` + 任务轮询）；
3. **补增量**（时间窗口回退 5 分钟或双写）；
4. **原子切换别名**（单次 `_aliases` 请求，remove + add 一起提交）；
5. **校验 + 观察 + 回滚预案**，稳定后再删旧索引。

核心就一句话：**应用永远只认别名，索引版本号只是运维细节**。把这条纪律落到代码里，ES 的索引演进从此就是常规操作，而不是凌晨的惊魂时刻。
