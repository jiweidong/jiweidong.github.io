---
title: Elasticsearch 集群性能调优实战：索引、查询与集群管理
date: 2026-06-19 09:30:00
tags:
  - Elasticsearch
  - 性能调优
  - 搜索引擎
categories:
  - 数据库
author: 东哥
---
## 一、引言

Elasticsearch 作为一个分布式搜索和分析引擎，广泛应用于日志分析、全文搜索、APM 和安全分析等场景。然而，随着数据量的增长和查询复杂度提升，不经调优的 ES 集群往往会出现查询延迟升高、写入积压、GC 频繁、磁盘 IO 瓶颈等问题。本文将从索引优化、写入优化、查询优化、集群管理、硬件选型五个维度，结合生产实践案例，系统性地讲解 ES 集群的性能调优方法。

## 二、索引优化

### 2.1 Mapping 设计黄金法则

**映射是 ES 使用的基础，一个好的 Mapping 设计可以避免后续 80% 的性能问题。**

#### 字段类型选择

| 需求场景 | 推荐字段类型 | 避免使用 |
|---------|-------------|---------|
| 精确匹配查询 | `keyword` | `text`（会产生分词，性能差） |
| 全文搜索 | `text` + 合适的 analyzer | 对不需要分词的字段使用 text |
| 数值范围查询 | `integer`/`long`/`float`/`double` | `keyword`（范围查询性能差） |
| 日期排序/聚合 | `date` | `text` 或 `keyword` |
| IP 地址查询 | `ip` | `keyword`（但不如 ip 类型高效） |
| 经纬度查询 | `geo_point` | `text` |
| 布尔值 | `boolean` | `integer` (0/1) |
| 对象嵌套查询 | `nested` 或 `join` | 展平为多字段（如果不需要复杂查询） |

#### 实战级 Mapping 示例

```json
PUT /my_index
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1,
    "index.refresh_interval": "30s",
    "translog.durability": "async",
    "translog.sync_interval": "5s"
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "title": {
        "type": "text",
        "analyzer": "ik_smart",
        "fields": {
          "keyword": {
            "type": "keyword",
            "doc_values": false
          }
        }
      },
      "content": {
        "type": "text",
        "analyzer": "ik_max_word",
        "norms": false,
        "index_options": "offsets"
      },
      "user_id": {
        "type": "keyword",
        "doc_values": true
      },
      "order_amount": {
        "type": "scaled_float",
        "scaling_factor": 100,
        "doc_values": true
      },
      "status": {
        "type": "keyword",
        "index": true,
        "doc_values": true
      },
      "created_at": {
        "type": "date",
        "format": "yyyy-MM-dd HH:mm:ss||epoch_millis"
      },
      "tags": {
        "type": "keyword"
      },
      "is_deleted": {
        "type": "boolean"
      },
      "geo_location": {
        "type": "geo_point"
      }
    }
  }
}
```

### 2.2 doc_values 与 norms 的禁用策略

| 字段用途 | doc_values | norms | 说明 |
|---------|-----------|-------|------|
| 全文搜索（text） | 不适用 | 按需 | 不需要评分排序可禁用 norms |
| 精确搜索（keyword） | 保持启用 | 不适用 | 用于排序和聚合 |
| 只索引不聚合 | 可禁用 | 按需 | 节省磁盘空间 |
| 只有 term 查询 | 可禁用 | 禁用 | 不排序不聚合的场景 |

```json
{
  "mappings": {
    "properties": {
      "internal_code": {
        "type": "keyword",
        "doc_values": false,    // 仅用于查询，不用于聚合
        "norms": false          // keyword 类型 norms 无效
      },
      "log_message": {
        "type": "text",
        "norms": false,         // 不需要评分排序
        "index_options": "docs"  // 只需要记录是否包含词条
      }
    }
  }
}
```

### 2.3 Force Merge 分段合并

ES 分段过多会导致：
- 查询时需要搜索更多 segment，增加 IO 和 CPU
- 占用更多文件句柄
- 内存缓存利用率降低

```json
// 强制合并到指定分段数（建议在写入低峰期执行）
POST /my_index/_forcemerge?max_num_segments=1

// 完成合并后检查分段数
GET /my_index/_segments
```

**force_merge 最佳实践：**

| 场景 | 建议 |
|------|------|
| 日志类时序索引 | 写入完成后只读 -> force merge 到 1 段 |
| 持续写入的索引 | 不执行 force merge（分段会重新生成） |
| 合并时机 | 索引写入低峰期，预留足够的 IO 带宽 |
| 大索引 | 分段合并到 3-5 段即可，合并到 1 段耗时过长 |
| 在线服务索引 | force merge 期间可能会增加查询延迟 |

### 2.4 Index Lifecycle Management (ILM)

```json
PUT _ilm/policy/logs_policy
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_size": "50GB",
            "max_age": "1d"
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "warm": {
        "min_age": "3d",
        "actions": {
          "shrink": {
            "number_of_shards": 1
          },
          "forcemerge": {
            "max_num_segments": 1
          },
          "allocate": {
            "require": {
              "data_tier": "data_warm"
            }
          }
        }
      },
      "cold": {
        "min_age": "30d",
        "actions": {
          "allocate": {
            "require": {
              "data_tier": "data_cold"
            }
          }
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

| ILM 阶段 | 数据状态 | 节点角色 | 典型配置 |
|---------|---------|---------|---------|
| hot | 频繁写入 | data_hot | 多分片、SSD、高 refresh 频率 |
| warm | 只读查询 | data_warm | 减少分片、force merge、HDD |
| cold | 偶尔查询 | data_cold | 单个分片、极低频查询、大容量 HDD |
| frozen | 归档 | data_frozen | 搜索快照、S3/COS 对象存储 |
| delete | 清理 | - | 自动删除过期索引 |

## 三、写入优化

### 3.1 Bulk API 最佳实践

```json
POST /_bulk
{ "index": { "_index": "my_index", "_id": "1" } }
{ "title": "first doc", "content": "hello world" }
{ "index": { "_index": "my_index", "_id": "2" } }
{ "title": "second doc", "content": "foo bar" }
```

**Bulk 配置关键参数对比：**

| 参数 | 推荐值 | 过大的后果 | 过小的后果 |
|------|--------|-----------|-----------|
| 每批文档数 | 1000-5000 | 堆内存压力大、GC 频繁 | 网络开销大、吞吐降低 |
| 每批数据量 | 5-15 MB | 请求超时、OOM | 网络时延占比高 |
| 并发线程数 | CPU 核数 x 2 | 线程竞争、GC 压力 | IO 利用率不足 |

### 3.2 refresh_interval 调整时机

```json
// 写入高峰期：降低 refresh 频率，减少分段数
PUT /my_index/_settings
{
  "index": {
    "refresh_interval": "60s"
  }
}

// 批量导入期间：完全禁用 refresh
PUT /my_index/_settings
{
  "index": {
    "refresh_interval": "-1"
  }
}

// 导入完成后恢复
PUT /my_index/_settings
{
  "index": {
    "refresh_interval": "30s"
  }
}
```

### 3.3 Translog 异步刷盘

```json
PUT /my_index/_settings
{
  "index": {
    "translog": {
      "durability": "async",
      "sync_interval": "5s",
      "flush_threshold_size": "512mb"
    }
  }
}
```

| translog.durability | 说明 | 写性能 | 数据安全性 |
|--------------------|------|--------|-----------|
| `request` (默认) | 每次写入后 fsync | 低（约 50% 下降） | 最高（不丢数据） |
| `async` | 定期异步 fsync | 高（推荐用于批量导入） | 可能丢失 sync_interval 内的数据 |

### 3.4 写线程池调优

```json
// 查看线程池状态
GET /_cat/thread_pool?v

// 返回示例
node_name    name                active queue  rejected
node-1       write               12     45     0
node-2       write               10     38     0
```

| 线程池 | 用途 | 默认队列大小 | 建议 |
|--------|------|-------------|------|
| write | 文档索引/更新/删除 | 10000 | 如果写队列持续积压，应增加节点或优化写入 |
| search | 搜索查询 | 1000 | 查询积压说明节点资源不足 |
| get | Get 请求 | 1000 | 一般无需调整 |
| bulk | 批量写入 | 200 | 积压时需要检查写入瓶颈 |

**线程池队列积压排查步骤：**

```bash
# 1. 查看拒绝率
GET /_nodes/stats/thread_pool?human

# 2. 查看写线程池队列积压
GET /_cat/thread_pool/write?v&h=node_name,active,queue,rejected

# 3. 如果 queue 持续增长或出现 rejected
#    不应直接调大队列，而是排查根因：
#    - 磁盘 IO 是否打满？
#    - GC 是否频繁？
#    - 是否需要增加节点或分片？
```

## 四、查询优化

### 4.1 filter vs query：性能差距的关键

| 对比维度 | filter | query | 
|---------|--------|-------|
| 缓存 | 自动缓存结果集 | 不缓存（评分动态计算） |
| 评分 | 不计分（constant_score） | 计算 _score |
| 性能 | 更快 | 较慢（需计算相关度） |
| IDF/TF 计算 | 不需要 | 需要扫描倒排索引统计 |

```json
// ✅ 推荐：将精确条件放入 filter
GET /my_index/_search
{
  "query": {
    "bool": {
      "must": [
        { "match": { "title": "keyword" } }  // 需要评分
      ],
      "filter": [
        { "term": { "status": "active" } },    // 精确过滤
        { "term": { "is_deleted": false } },
        { "range": { "created_at": { "gte": "now-7d" } } }
      ]
    }
  }
}
```

### 4.2 深分页优化 —— Search After vs Scroll

| 分页方式 | 适用场景 | 优点 | 缺点 |
|---------|---------|------|------|
| `from + size` | 前 10000 条内翻页 | 简单直接 | 深翻页性能差（需要内存中排序全部结果） |
| `scroll` | 批量导出/全量扫描 | 快照一致的批量读取 | 不能做实时搜索，保持上下文占用内存 |
| `search_after` | 实时深分页 | 无深度限制，无上下文开销 | 不能随机跳页，只能逐页下翻 |
| `Point-in-Time` | ES 7.10+ 实时深分页 | 替代 scroll，更轻量 | 相对较新，API 稍复杂 |

#### Search After 实现示例

```json
// 第一页查询（获取排序值）
GET /my_index/_search
{
  "size": 10,
  "sort": [
    { "created_at": "desc" },
    { "_id": "asc" }  // 用于打破平局
  ],
  "query": {
    "bool": {
      "filter": [
        { "term": { "status": "active" } }
      ]
    }
  }
}

// 第二页：使用上一页最后一个文档的 sort 值
GET /my_index/_search
{
  "size": 10,
  "search_after": ["2026-06-19 08:00:00", "doc_100"],
  "sort": [
    { "created_at": "desc" },
    { "_id": "asc" }
  ],
  "query": { ... }
}
```

### 4.3 聚合优化

```json
// 聚合优化配置
GET /my_index/_search
{
  "size": 0,
  "aggs": {
    "by_status": {
      "terms": {
        "field": "status",
        "size": 10,
        "execution_hint": "map"  // 对 low-cardinality 字段使用 map 模式
      }
    },
    "date_histogram": {
      "date_histogram": {
        "field": "created_at",
        "calendar_interval": "hour"
      }
    }
  }
}
```

**聚合性能优化要点：**

| 优化手段 | 说明 | 效果 |
|---------|------|------|
| `execution_hint: map` | 低基数（<10万）字段使用 Map，省内存 | 显著提升 |
| `size` 不要太大 | terms 聚合默认 10，一般不超过 1000 | 避免内存耗尽 |
| 禁用 `_count` 排序 | 精度要求可降低时使用 `shard_size` | 减少协调节点计算 |
| 先 filter 再 aggs | 减少聚合的文档基数 | 大幅提升 |
| 启用 `doc_values` | 聚合操作依赖 doc_values | 必须开启 |

## 五、集群维度调优

### 5.1 节点角色规划

| 节点角色 | 建议数量 | CPU/内存 | 磁盘 | 核心职责 |
|---------|---------|---------|------|---------|
| Master | 3（奇数） | 4C 8G | 普通 | 集群管理、元数据维护 |
| Data Hot | 按数据量 | 16C 64G | SSD | 写入 + 热数据查询 |
| Data Warm | 按数据量 | 8C 32G | HDD | 温数据查询 |
| Ingest | 按吞吐量 | 8C 16G | 普通 | 数据预处理 Pipeline |
| Coordinating | 2-4 | 8C 32G | 普通 | 请求路由、聚合合并 |

### 5.2 分片数量规划

```json
// 推荐公式
// 单分片大小 = 20-50GB
// 总分片数 = 节点数 x (1~3)   // 每个节点 1-3 个分片

// 查看分片大小
GET /_cat/shards?v&h=index,shard,prirep,store

// 手动分片分配
PUT /my_index/_settings
{
  "index": {
    "routing.allocation.total_shards_per_node": 3,
    "routing.allocation.awareness.attributes": "rack",
    "routing.allocation.awareness.force.rack.values": ["rack1", "rack2"]
  }
}
```

| 分片大小 | 影响力 | 问题 |
|---------|--------|------|
| < 5GB | 分片过多 | 文件句柄开销大、查询广播成本高 |
| 20-50GB | 最佳 | 平衡查询性能和恢复速度 |
| > 100GB | 大分片 | 恢复慢、再平衡困难 |

### 5.3 JVM 堆内存配置

```bash
# /etc/elasticsearch/jvm.options
# 堆内存：不超过物理内存的 50%，最大值 31GB（对象指针压缩）

-Xms16g
-Xmx16g

# GC 配置（ES 7.x+ 默认使用 G1GC）
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:G1HeapRegionSize=4m
-XX:InitiatingHeapOccupancyPercent=30
-XX:G1ReservePercent=15
-XX:+ParallelRefProcEnabled
-XX:+DisableExplicitGC
```

**JVM 内存分配参考：**

| 物理内存 | 堆内存（Xms=Xmx） | [剩余给 Lucene] | 节点类型 |
|---------|------------------|----------------|---------|
| 16 GB | 8 GB | 8 GB | Master / Coords |
| 32 GB | 16 GB | 16 GB | Data Hot |
| 64 GB | 31 GB (最大压缩指针) | 33 GB | Data Warm |
| 128 GB | 31 GB | 97 GB | 超大容量数据节点 |

### 5.4 磁盘均衡

```bash
# 查看磁盘使用率
GET /_cat/allocation?v

# 手动均衡分片
POST /_cluster/reroute
{
  "commands": [
    {
      "move": {
        "index": "my_index",
        "shard": 0,
        "from_node": "hot-1",
        "to_node": "hot-2"
      }
    }
  ]
}

# 设置磁盘水位线
PUT /_cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.disk.watermark.low": "85%",
    "cluster.routing.allocation.disk.watermark.high": "90%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "95%",
    "cluster.info.update.interval": "30s"
  }
}
```

## 六、硬件选型建议

### 6.1 SSD vs HDD

| 对比维度 | SSD (NVMe) | SATA SSD | HDD |
|---------|-----------|---------|-----|
| 顺序读取 | 3000-7000 MB/s | 500-550 MB/s | 150-200 MB/s |
| 随机 IOPS | 500K-1M | 50K-100K | 100-200 |
| 写入延迟 (fsync) | < 1ms | 1-3ms | 5-15ms |
| 适用场景 | Hot 节点（写入+热查询） | Warm 节点 | Cold 节点（归档） |
| 每 GB 成本 | 高 | 中 | 低 |

### 6.2 内存与 CPU 比例

| 场景 | 内存:CPU 比 | 说明 |
|------|-----------|------|
| 日志写入密集型 | 2:1 (64G:32核) | 堆内需求稳定，堆外用于缓存写入 |
| 搜索查询密集型 | 4:1 (64G:16核) | 大量查询缓存消耗堆外内存 |
| 聚合分析密集型 | 4:1 (128G:32核) | 聚合操作需要大量内存存储中间结果 |
| 通用场景 | 3:1 (48G:16核) | 平衡写入和查询需求 |

## 七、监控指标

### 7.1 核心监控指标

| 指标类别 | 指标名称 | 告警阈值 | 说明 |
|---------|---------|---------|------|
| **集群健康** | cluster_status | != green | 存在未分配分片 |
| **写入性能** | indexing_latency_p99 | > 200ms | 写入延迟过高 |
| **查询性能** | search_latency_p99 | > 500ms | 查询延迟过高 |
| **GC** | young_gc_count | 突增 > 20次/分钟 | 对象创建过快 |
| **GC** | old_gc_time | > 5s/次 | Full GC 预示着内存问题 |
| **线程池** | write_queue | > 1000 | 写入积压 |
| **线程池** | search_queue | > 100 | 查询积压 |
| **磁盘** | disk_usage | > 85% | 即将触发分片分配 |
| **JVM** | heap_usage | > 85% | 堆内存压力大 |
| **CPU** | cpu_usage_avg(5m) | > 80% | CPU 饱和 |

### 7.2 快速诊断命令

```bash
# 集群状态
GET /_cluster/health?pretty

# 节点热力图
GET /_cat/nodes?v&h=name,node.role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent

# 慢查询（设置慢查询日志阈值）
PUT /my_index/_settings
{
  "index.search.slowlog.threshold.query.warn": "5s",
  "index.search.slowlog.threshold.query.info": "1s",
  "index.indexing.slowlog.threshold.index.warn": "10s",
  "index.indexing.slowlog.threshold.index.info": "5s"
}

# 热点线程
GET /_nodes/hot_threads

# 查看段内存
GET /_nodes/stats/indices/segments?human
```

## 八、实战案例

### 案例：日志集群查询延迟从 3s 优化到 200ms

**问题**：某日志集群单索引 5TB，平均查询延迟 3000ms，P99 超过 10s。

**诊断与分析**：

| 检查项 | 现象 | 根因 |
|-------|------|------|
| 分片分布 | 5 个节点共 30 个分片 | 分片过多且分布不均 |
| 索引设计 | 单索引 5TB | 无 ILM 策略，没有滚动索引 |
| Mapping | 所有字段都用了 text | 大量不需要分词的字段浪费资源 |
| 查询方式 | 客户端使用 scroll 翻页 | scroll 慢且占内存 |
| Refresh | refresh_interval 未设置（默认 1s） | 分段过多 |

**优化措施**：

1. **ILM 配置**：每天一个索引，30天后删除
2. **Mapping 重构**：不需要分析的字段改用 keyword，禁用 norms
3. **查询改造**：即时页面使用 search_after，批量导出使用 Point-in-Time
4. **分片调整**：每个索引 3 个分片，每个节点 1 副本
5. **Refresh 调整**：写入高峰 refresh_interval 调整到 30s

**优化前后对比**：

| 指标 | 优化前 | 优化后 | 提升幅度 |
|------|--------|--------|---------|
| 平均查询延迟 | 3000 ms | 180 ms | 93% ↓ |
| P99 查询延迟 | 10s+ | 650 ms | 93% ↓ |
| 写入吞吐 | 5000 docs/s | 25000 docs/s | 400% ↑ |
| GC 暂停次数 | 50次/分钟 | 5次/分钟 | 90% ↓ |
| 磁盘使用量 | 5TB | 3.2TB | 36% ↓ |
| JVM 堆使用率 | 92% | 45% | 51% ↓ |

## 九、总结

Elasticsearch 性能调优是一项系统工程，需要从索引设计、写入策略、查询优化、集群管理、硬件配置等多维度综合考虑。核心原则是：

1. **设计先行**：80% 的性能问题源于不良的 Mapping 设计和索引策略
2. **监控驱动**：通过指标发现瓶颈，针对性优化而非盲目调参
3. **分层存储**：利用 ILM 实现热点/温冷数据分离，最大化资源效率
4. **写查分离**：写入阶段优先吞吐，查询阶段优先缓存和响应速度

调优是一个持续的过程，建议每次变更后记录指标变化，形成可复用的优化方法论。
