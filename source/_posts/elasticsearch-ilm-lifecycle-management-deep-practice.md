---
title: 【ES 运维】索引生命周期管理（ILM）深度实战：热温冷分层、rollover 与自动归档
date: 2026-09-16 08:00:00
tags:
  - Elasticsearch
  - ILM
  - 索引管理
  - 运维
categories:
  - 中间件
  - Elasticsearch
author: 东哥
---

# 【ES 运维】索引生命周期管理（ILM）深度实战：热温冷分层、rollover 与自动归档

## 面试官：日志平台每天写入 500GB，一年就是 180TB。你们的索引是怎么管理的？总不能一直堆在一个索引里吧？

这个问题背后其实有三层追问：

1. **写入侧**：单个索引无限增长会怎样？——分片数不能动态改、段文件越来越多、查询越来越慢、forcemerge 越来越不可行。
2. **存储侧**：冷数据占着高性能 SSD 是不是浪费？——数据"热度"随时间单调衰减，但硬件成本是常数。
3. **运维侧**：谁来每天手动 rollover、手动改副本、手动删过期索引？——靠人肉脚本，迟早出事故。

Elasticsearch 给出的标准答案是 **ILM（Index Lifecycle Management，索引生命周期管理）**：用声明式的策略，把"索引从生到死"的全过程自动化。

这篇文章从 Phase/Action 模型讲到冷热分层架构，再到生产级 policy 实战与踩坑清单。

---

## 一、ILM 的核心模型：Phase 与 Action

ILM 把索引的一生划分为 **5 个阶段（Phase）**，每个阶段可以挂 **若干动作（Action）**。

| Phase | 语义 | 典型动作 |
| --- | --- | --- |
| `hot` | 正在被高频写入/查询 | `rollover`、`set_priority` |
| `warm` | 不再写入，仍会被查询 | `allocate`、`forcemerge`、`shrink`、`readonly`、`set_priority` |
| `cold` | 很少查询，允许更高延迟 | `allocate`、`searchable_snapshot`、`set_priority` |
| `frozen` | 几乎不查，只做合规留存 | `searchable_snapshot` |
| `delete` | 到期删除 | `delete`、`wait_for_snapshot` |

**关键设计点：Phase 是"单向流动"的。**索引只会 hot → warm → cold → frozen → delete，不能回退（除非用 `_ilm/move` 手动干预）。这个约束保证了生命周期的确定性。

### 1.1 Action 清单

| Action | 作用 | 主要参数 | 注意 |
| --- | --- | --- | --- |
| `rollover` | 达到阈值时切新建索引 | `max_primary_shard_size`、`max_age`、`max_docs` | 索引名必须以数字结尾，且要有 write alias |
| `set_priority` | 设置恢复优先级 | `priority`（默认 hot=100、warm=50、cold=0） | 越高越先恢复 |
| `allocate` | 调整副本数 / 迁移到指定节点 | `number_of_replicas`、`require`/`include`/`exclude`、`total_shards_per_node` | 8.x 的 `migrate` 动作已移除，迁移由它直接完成 |
| `forcemerge` | 合并段，减少段数 | `max_num_segments` | **只在 warm 做一次**，是 IO 密集型操作 |
| `shrink` | 减少主分片数 | `number_of_shards` | 需先只读；数据流底层索引不支持 |
| `readonly` | 置为只读 | — | 阻止写入，避免误改 |
| `searchable_snapshot` | 转成"可搜索快照" | `snapshot_repository`、`storage`（`shared_cache`/`full_copy`） | 需先有快照仓库；frozen 必须用它 |
| `delete` | 删除索引 | `delete_searchable_snapshot` | 建议配合 `wait_for_snapshot` |
| `wait_for_snapshot` | 等待快照完成 | `policy` | 保证"先备份再删" |

> 版本提示：`freeze` 动作（旧版冻结索引）和 `migrate` 动作在 8.x 已被移除。冻结索引的能力由"可搜索快照"取代，节点迁移由 `allocate` 完成。

### 1.2 `min_age` 到底从什么时候算？

这是**最容易理解错的一个点**。

> `min_age` 的基准是**索引自身的创建时间**（不是"进入上一个阶段的时刻"，也不是"策略创建时间"）。

举例：policy 里 warm 阶段 `min_age: 3d`，意思是"这个索引从被创建算起满 3 天后进入 warm"。

在线环境里判断某个索引为什么还卡在某个阶段，**不要靠猜，用 `_ilm/explain` 看真实状态**：

```bash
GET logs-app-000042/_ilm/explain
```

返回里的关键字段：

```json
{
  "indices": {
    "logs-app-000042": {
      "index": "logs-app-000042",
      "managed": true,
      "policy": "logs-policy",
      "phase": "warm",
      "action": "forcemerge",
      "step": "forcemerge",
      "age": "5.2d",                       // 索引当前年龄
      "phase_time": "2026-09-11T02:00:00Z",
      "step_info": { "max_num_segments": 1 }
    }
  }
}
```

还有一个补数据的场景：如果是**回灌历史数据**，索引创建时间是"现在"，会导致它立刻被判成"很新"。这时用：

```json
"settings": {
  "index.lifecycle.parse_origination_date": true
}
```

让 ILM 从索引名里的日期（如 `logs-app-2025.01.15-000001`）解析真实起点。

---

## 二、Rollover：ILM 的发动机

没有 rollover，生命周期根本无从谈起——因为"一个新索引"是阶段推进的载体。

### 2.1 Rollover 的触发条件

```json
"rollover": {
  "max_primary_shard_size": "50gb",
  "max_age": "1d",
  "max_docs": 100000000
}
```

| 条件 | 建议 | 理由 |
| --- | --- | --- |
| `max_primary_shard_size` | 30~50GB | **首选**，直接控制单分片大小，避免"大分片难恢复" |
| `max_age` | 1d | 保证时间边界清晰，便于按天排查/归档 |
| `max_docs` | 1亿 | 文档体积差异大时才用 |

**只要满足任意一个条件就触发**（OR 语义）。

> 注意：`max_size` 是按"所有主分片总量"还是"单分片"？现代最佳实践一律用 **`max_primary_shard_size`（单主分片）**，因为分片数一旦确定就不能改，按总量控制会导致分片越切越大。

### 2.2 Rollover 的前置条件（经典索引）

```json
// 1) 创建 bootstrap 索引 + write alias（别名指向唯一写索引）
PUT logs-app-000001
{
  "aliases": {
    "logs-app": { "is_write_index": true }
  },
  "settings": {
    "index.lifecycle.name": "logs-policy",
    "index.lifecycle.rollover_alias": "logs-app",
    "number_of_shards": 3,
    "number_of_replicas": 1
  }
}
```

三个硬性要求：

1. 索引名必须**以数字结尾**（`-000001`），rollover 时递增；
2. 必须配置 `index.lifecycle.rollover_alias`；
3. 该别名必须**指向这个索引**，且只有它被标记为 `is_write_index: true`。

最常见的报错就是：

```text
illegal_argument_exception: index.lifecycle.rollover_alias [logs-app] does not point to index [logs-app-000002]
```

含义：rollover 想切新索引，但别名还指向旧的那个。通常是**手工改过别名**或**多个索引争抢同一个别名**导致的。

### 2.3 Data Stream：让 rollover 自动发生

新版最佳实践是**用 Data Stream 替代手工 alias**。Data Stream 天然是"只追加 + 自动 rollover"的：

```json
PUT _index_template/logs-template
{
  "index_patterns": ["logs-app-*"],
  "data_stream": {},
  "template": {
    "settings": {
      "index.lifecycle.name": "logs-policy",
      "number_of_shards": 3,
      "number_of_replicas": 1
    }
  }
}
```

写入时直接用 `logs-app` 这个名字，ES 会自动创建第一个底层索引（`.ds-logs-app-2026.09.16-000001`），并在 rollover 时自动递增。**使用者完全不用管别名与索引名。**

对比一下：

| 维度 | 经典索引 + alias | Data Stream |
| --- | --- | --- |
| 手动创建 bootstrap | 需要 | 不需要 |
| rollover 后别名维护 | ILM 维护，易出错 | 自动 |
| 能否删除单条文档 | 可以 | **不可以**（append-only） |
| 是否需要 `@timestamp` | 否 | **必须** |
| 能否 update | 可以 | 不能（只能 `_update_by_query` 也受限） |
| 推荐度 | 兼容存量 | **新项目首选** |

---

## 三、冷热分层架构怎么落地

ILM 只负责"什么时候做什么"，**具体落到哪台机器上，靠节点属性 + `allocate` 动作**。

### 3.1 两种节点划分方式

**方式一：节点角色（ES 7.10+，推荐）**

```yaml
# hot 节点
node.roles: [ data_hot, ingest ]
# warm 节点
node.roles: [ data_warm ]
# cold 节点
node.roles: [ data_cold ]
# frozen 节点
node.roles: [ data_frozen, search ]
```

`data_hot`/`data_warm`/`data_cold`/`data_frozen` 是**内置角色**，ILM 的 `allocate` 可以直接基于角色过滤，语义清晰。

**方式二：自定义节点属性（经典做法，更灵活）**

```yaml
node.attr.box_type: warm
```

```json
"allocate": {
  "number_of_replicas": 1,
  "require": { "box_type": "warm" }
}
```

优点是可以自定义维度（比如按机房 `node.attr.zone: b`、按磁盘类型 `node.attr.disk: ssd`），实现"同城双可用区"的精细编排。

### 3.2 完整生产级 Policy

```json
PUT _ilm/policy/logs-policy
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "1d"
          },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "3d",
        "actions": {
          "allocate": {
            "number_of_replicas": 1,
            "require": { "data": "warm" }
          },
          "forcemerge": { "max_num_segments": 1 },
          "set_priority": { "priority": 50 }
        }
      },
      "cold": {
        "min_age": "15d",
        "actions": {
          "allocate": {
            "number_of_replicas": 1,
            "require": { "data": "cold" }
          },
          "set_priority": { "priority": 0 }
        }
      },
      "frozen": {
        "min_age": "60d",
        "actions": {
          "searchable_snapshot": {
            "snapshot_repository": "backup-repo",
            "storage": "shared_cache"
          }
        }
      },
      "delete": {
        "min_age": "180d",
        "actions": {
          "wait_for_snapshot": { "policy": "backup-policy" },
          "delete": {}
        }
      }
    }
  }
}
```

几个设计取舍值得说明：

- **hot 阶段 `min_age: 0ms` + rollover 按 `max_age: 1d`**：让"天级索引"成为基本单位，运维视角最直观。
- **warm 才 forcemerge**：hot 阶段还在写，合并出来的段很快又会被写碎，纯属浪费 IO。
- **cold 不再 forcemerge**：已经合并过，反复合并没有收益。
- **frozen 用 `shared_cache`**：只把"实际被查询命中的部分"从快照拉到本地缓存，磁盘占用接近 0，代价是首次查询慢。
- **delete 前 `wait_for_snapshot`**：确保删掉的索引在快照仓库里有副本，合规与误删兜底。

### 3.3 可搜索快照（Searchable Snapshot）的前置条件

`searchable_snapshot` 是 cold/frozen 的杀手锏，但它**不是开箱即用的**：

```json
// 1) 先注册快照仓库（S3/MinIO/GCS/共享文件系统均可）
PUT _snapshot/backup-repo
{
  "type": "s3",
  "settings": {
    "bucket": "es-snapshots",
    "region": "cn-north-1",
    "base_path": "cluster-a"
  }
}

// 2) 配置 SLM（快照生命周期管理），保证有持续可用的快照
PUT _slm/policy/backup-policy
{
  "schedule": "0 30 1 * * ?",
  "name": "<daily-snap-{now/d}>",
  "repository": "backup-repo",
  "config": { "indices": ["logs-app-*"], "include_global_state": false },
  "retention": {
    "expire_after": "30d",
    "min_count": 5,
    "max_count": 50
  }
}
```

没有仓库、没有快照，frozen 阶段会一直卡在 `waiting`（`explain` 里能看到原因）。**这是冷热分层上线时最常踩的第一个坑。**

> 补充：快照应至少保留"比最长 ILM 留存期更长"的周期，否则"可搜索快照"一旦对应快照被 SLM 清理，索引就废了。

---

## 四、运维 API 与状态机操作

```bash
# 查看所有策略 / 单个策略
GET _ilm/policy
GET _ilm/policy/logs-policy

# 查看索引的 ILM 执行详情（排障第一命令）
GET logs-app-*/_ilm/explain

# ILM 服务整体状态
GET _ilm/status

# 出错后修复完，重试该索引
POST logs-app-000042/_ilm/retry

# 手动推进阶段（比如紧急把某索引直接推进 delete）
POST _ilm/move/logs-app-000042
{
  "current_step": { "phase": "hot", "action": "complete", "name": "complete" },
  "next_step":    { "phase": "delete", "action": "delete", "name": "delete" }
}

# 暂停/恢复 ILM 服务（大变更期间用，慎用）
POST _ilm/stop
POST _ilm/start
```

**ILM 的调度不是实时的**：ES 有一个轮询间隔 `indices.lifecycle.poll_interval`（默认 **10 分钟**）。所以"到点后延迟十几分钟才动"是正常的。测试环境为了观察方便可以调小：

```json
PUT _cluster/settings
{
  "transient": { "indices.lifecycle.poll_interval": "10s" }
}
```

> 生产环境不要随意调小：每次轮询都要遍历所有受管索引，索引数量上万时轮询本身就会成为负载。

---

## 五、监控与踩坑清单

### 5.1 该监控什么

| 指标 | 说明 |
| --- | --- |
| ILM 错误索引数 | `GET _ilm/status` + 遍历 explain，`step: ERROR` 的必须告警 |
| 索引总数 / 分片总数 | 分片数暴涨会拖垮集群元数据 |
| 各阶段索引数量与体积 | 判断冷热分层是否按预期收敛 |
| `frozen` 卡住数量 | 通常是快照仓库或 SLM 出问题 |
| forcemerge 并发 | 大量 warm 索引同时 forcemerge 会打满 IO |
| ILM 历史记录 | `ilm-history-*` 数据流可回溯每次阶段变化 |

### 5.2 高频坑

1. **`rollover_alias` 报错** —— 别名没指向索引，或 `is_write_index` 缺失 / 多索引争抢别名。
2. **`min_age` 理解错** —— 以为从"进入上一阶段"起算，结果发现索引该进 warm 了却没动。用 `explain` 的 `age` 字段对齐认知。
3. **forcemerge 放在 hot 阶段** —— 与写入打架，IO 飙升，得不偿失。
4. **frozen 阶段没配快照仓库** —— 永远停在 waiting。
5. **delete 阶段没配 `wait_for_snapshot`** —— SLM 与 ILM 节奏不一致时，可能删掉还没备份的数据。
6. **`shrink` 用在 data stream 底层索引上** —— 不支持。要减分片请在建模板时就规划好。
7. **回灌历史数据不设 `parse_origination_date`** —— 老数据被当成新数据，全部堆在 hot。
8. **索引模板匹配优先级** —— 多个模板匹配同一 pattern 时，后者覆盖前者且**组件模板（component template）顺序决定合并结果**，容易出现"策略没挂上"。
9. **副本数与节点角色冲突** —— `require: {data: cold}` 但 cold 节点只有一个，副本数还配 2，就会一直 `unassigned`。

---

## 六、面试常见追问

**Q1：ILM 和 SLM 什么关系？**

ILM 管**索引的生命周期**（阶段、rollover、删除），SLM 管**快照的生命周期**（多久打一次、保留多久）。两者配合点在于：frozen 阶段的可搜索快照依赖仓库里的快照，delete 前用 `wait_for_snapshot` 保证备份。

**Q2：为什么建议 `max_primary_shard_size` 而不是 `max_size`？**

分片数在索引创建时固定，按总量 rollover 会导致分片随数据增长而变大（"大分片"恢复慢、查询慢、单分片故障影响大）。按单分片大小控制，才能让每个分片都保持在健康区间。

**Q3：`searchable_snapshot` 之后还能改索引吗？**

不能。它本质是把索引数据放进快照仓库、只在本地缓存查询命中的部分，索引变为只读。要改只能重新从快照恢复成普通索引。

**Q4：Data Stream 和 ILM 谁管 rollover？**

Data Stream 自己会在"满足 ILM rollover 条件"时创建新的底层索引，索引命名与别名维护全部自动。对比经典索引，你要少维护一个 bootstrap 索引和 write alias，也因此少一类故障。

**Q5：如果业务希望"7 天内可查、30 天后删除"，怎么设计？**

典型三段式：hot（0~1d，rollover 50GB/1d）→ warm（1~7d，forcemerge + 降副本）→ delete（30d）。"可查"和"可写"是两件事，全部数据 7 天都在 warm/cold 上可查，不需要一直占 hot 节点。

---

## 七、小结

| 要点 | 结论 |
| --- | --- |
| 模型 | 5 Phase（hot/warm/cold/frozen/delete）+ 声明式 Action |
| 发动机 | rollover（`max_primary_shard_size` 优先 + `max_age` 兜底） |
| `min_age` 基准 | 索引自身创建时间；回灌历史数据用 `parse_origination_date` |
| 分层手段 | 节点角色（`data_hot/warm/cold/frozen`）或自定义节点属性 + `allocate` |
| 省钱关键 | cold/frozen 用 `searchable_snapshot`（`shared_cache`），依赖快照仓库 + SLM |
| 排障命令 | `GET <index>/_ilm/explain`、`GET _ilm/status`、`POST <index>/_ilm/retry` |
| 调度粒度 | `indices.lifecycle.poll_interval` 默认 10m，非实时 |
| 新项目选择 | **Data Stream + ILM**，不要再手写 alias 与 rollover 脚本 |

ILM 的价值不只是"自动删除过期索引省磁盘"。它真正解决的是**索引治理的可预测性**：写入形态（分片大小）可控、查询成本（段数/分层）可控、存储成本（冷热分层）可控、留存策略（合规删除）可控。对一个每天 500GB 的日志平台来说，这四项可控，才是从"能跑"到"能运营"的分水岭。
