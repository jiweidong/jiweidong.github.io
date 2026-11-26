---
title: 【ES 实战】Mapping 膨胀与字段爆炸治理：dynamic mapping、1000 字段上限与 flattened 落地
date: 2026-11-26 08:00:00
tags:
  - Elasticsearch
  - Mapping
  - 搜索引擎
  - 性能优化
  - Java
categories:
  - 中间件
author: 东哥
---

# 【ES 实战】Mapping 膨胀与字段爆炸治理

## 前言

Elasticsearch 的 mapping 一旦膨胀，代价不是「多占一点磁盘」，而是**整个集群一起变慢**：

- 一个多租户 SaaS 的索引，字段数从 300 涨到 3000，`cluster state` 从 2MB 涨到 80MB；
- master 每次 publish 都要把状态推给所有节点，`cluster state update` 耗时从 20ms 涨到 2s；
- 新字段写入触发 mapping update，并发写入时频繁冲突，客户端开始收到 `mapper_parsing_exception`；
- 最后撞上 `index.mapping.total_fields.limit` 的 1000 上限，新租户直接写不进来。

字段爆炸的根源通常是 `dynamic mapping`：JSON 里出现一个新 key，ES 就自动建一个字段。对日志、埋点、用户自定义属性、第三方 webhook 这类「schema 不由自己控制」的数据，这几乎必然发生。

本文从「一个字段到底占多少」讲到四种治理方案，重点讲 `flattened` 的适用边界，最后给出 Java 侧的建模与迁移代码。

> 分工说明：站内已有《Nested 与 Object 类型》《_source、doc_values 与 fielddata》《ES 倒排索引写入》等文章。本篇专攻 **mapping 数量膨胀** 与动态字段治理。

---

## 一、一个字段的真实成本

很多人以为「字段就是 mapping 里一行配置」。实际上，一个 `text` 字段会同时产生：

| 结构 | 是否默认开启 | 作用 |
|---|---|---|
| `_source` | 是 | 原始文档，字段名和值都存一份 |
| 倒排索引 | 是（text） | term → doc id 列表 |
| `doc_values` | 是（除 text） | 列式存储，用于排序/聚合 |
| `norms` | 是（text） | 长度归一化，影响评分 |
| BKD tree | 是（数值/date/geo） | 范围查询 |
| 词典 / FST | 是（text/keyword） | term 前缀查找 |
| mapping 元数据 | 是 | 字段名、类型、参数，进 cluster state |
| fielddata | 否（可开） | text 聚合时堆内正排 |

一个字段在磁盘上可能对应 5~8 份数据。1000 个字段的索引，和 100 个字段的索引，不是 10 倍关系，而是「cluster state 体积、mapping 解析时间、写入路径、恢复时间」的全面放大。

更麻烦的是 **cluster state 是全局的**：每个节点都保存一份完整 mapping。字段越多，master 发布越慢，节点加入/重启时同步越久。

---

## 二、dynamic mapping 的四种策略

| 策略 | 新字段行为 | 能否搜索 | 适用场景 |
|---|---|---|---|
| `true`（默认） | 自动推断类型并加入 mapping | 能 | schema 可控、字段稳定 |
| `runtime` | 加入 mapping 但作为 runtime field，不建索引 | 能（运行时计算，慢） | 字段多但查询少 |
| `false` | 忽略，不进 mapping，值仍在 `_source` | 不能 | 只存不查的透传字段 |
| `strict` | 直接拒绝写入 | — | schema 严格受控 |

设置方式：

```json
PUT /orders/_mapping
{
  "dynamic": "strict"
}
```

或者在索引模板里：

```json
PUT /_index_template/orders_template
{
  "index_patterns": ["orders-*"],
  "template": {
    "mappings": {
      "dynamic": "false",
      "properties": {
        "orderId":   { "type": "keyword" },
        "userId":    { "type": "keyword" },
        "amount":    { "type": "scaled_float", "scaling_factor": 100 },
        "createdAt": { "type": "date" },
        "attrs":     { "type": "flattened" }
      }
    }
  }
}
```

### 2.1 date detection 的暗坑

默认 `date_detection: true`。一个字符串 `"2026-11-26"` 会被推断成 `date`，后续如果同一个字段写入 `"unknown"`，就会报：

```
failed to parse field [createdAt] of type [date]
```

对来源不可控的数据，建议关掉自动日期识别：

```json
{
  "mappings": {
    "date_detection": false,
    "dynamic_templates": [
      {
        "strings_as_keywords": {
          "match_mapping_type": "string",
          "mapping": { "type": "keyword" }
        }
      }
    ]
  }
}
```

`dynamic_templates` 是控制「新字段怎么建」的关键工具：可以按字段名前缀、后缀、类型批量指定映射，避免默认的 `text + keyword 子字段` 双写。

---

## 三、字段爆炸的连锁反应

### 3.1 写入路径变长

每次写入一个新字段，协调节点要：

1. 解析文档，发现未知字段；
2. 向 master 提交 mapping update；
3. master 更新 cluster state 并 publish；
4. 所有节点应用新 mapping；
5. 写入才继续。

高并发写入时，多个请求同时提交不同字段的 mapping update，会产生版本冲突，客户端看到：

```
MapperParsingException: failed to parse
or
ClusterBlockException / version conflict on mapping update
```

### 3.2 硬上限

| 限制 | 默认值 | 说明 |
|---|---|---|
| `index.mapping.total_fields.limit` | 1000 | 单索引字段总数（含 multi-field） |
| `index.mapping.depth.limit` | 20 | 嵌套深度 |
| `index.mapping.nested_fields.limit` | 50 | nested 类型字段数 |
| `index.mapping.nested_objects.limit` | 10000 | 单文档 nested 对象数 |
| `index.mapping.field_name_length.limit` | 512 | 字段名长度 |

把 `total_fields.limit` 调大是治标：调到 10000 只会让集群更慢，最后在别的地方炸。

### 3.3 恢复与扩容变慢

节点重启时要从磁盘读 mapping、重建数据结构。字段数多的索引，恢复时间可能从秒级变成分钟级。滚动重启时，这会直接拉长发布窗口。

---

## 四、四种治理方案对比

| 方案 | 字段数 | 查询能力 | 写入成本 | 适用 |
|---|---|---|---|---|
| `flattened` | 1 个字段容纳任意 key | term/prefix/range（keyword 语义） | 低 | 标签、metadata、自定义属性 |
| `object` + `enabled:false` | 1 个字段，完全不索引 | 只能从 `_source` 取 | 最低 | 只存不查 |
| `nested` | 每个子字段独立 | 完整 | 高（每个 nested 文档独立 Lucene doc） | 需要独立查询的对象数组 |
| 拆索引 / 拆字段 | 每类字段独立索引 | 完整 | 中 | 字段类别清晰、可枚举 |

### 4.1 flattened 是什么

`flattened` 把一个 JSON 对象整体当成**一个字段**索引：对象里的所有叶子值都被当作 keyword 建索引，字段路径用点号表示。

```json
PUT /products/_mapping
{
  "properties": {
    "specs": { "type": "flattened" }
  }
}
```

写入：

```json
{
  "name": "iPhone",
  "specs": {
    "color": "black",
    "storage": "256GB",
    "weight": 187,
    "tags": ["5G", "OLED"]
  }
}
```

查询：

```json
GET /products/_search
{
  "query": {
    "term": { "specs.color": "black" }
  }
}
```

也可以用 `specs` 整体查：

```json
{
  "query": {
    "match": { "specs": "black" }
  }
}
```

**能力边界**：

- 所有值按 keyword 处理，`weight: 187` 不能做数值范围比较（`range` 是字典序）；
- 不支持聚合到具体子字段（只能对整体做聚合，粒度有限）；
- 不支持 `nested` 语义，数组内的对象关系会丢失；
- 适合「key 不可枚举、查询以精确匹配为主」的场景，不适合「需要数值排序/统计」的场景。

### 4.2 `enabled: false`：彻底不索引

```json
{
  "properties": {
    "rawPayload": { "type": "object", "enabled": false }
  }
}
```

这个对象只存在于 `_source`，不建任何索引，不能搜索，但可以用 `_source` 过滤返回。适合「审计/透传」字段。

### 4.3 `index: false` + `doc_values: false`

对已知但不需要搜索的字段：

```json
{
  "properties": {
    "internalNote": {
      "type": "keyword",
      "index": false,
      "doc_values": false
    }
  }
}
```

字段仍在 mapping 里（占一个名额），但不建索引、不建列存，成本最低。**注意：它仍然计入 1000 上限。**

### 4.4 runtime field：能不建索引就不建

```json
PUT /orders/_mapping
{
  "runtime": {
    "amountWithTax": {
      "type": "double",
      "script": {
        "source": "emit(doc['amount'].value * 1.13)"
      }
    }
  }
}
```

runtime field 不占索引空间，但查询时要实时计算，适合低频查询。字段多、查询少的场景可以用它替代动态字段。

---

## 五、多租户建模：别让一个租户的字段污染所有人

字段爆炸在多租户系统里最常见：每个租户都想加自定义字段。

### 5.1 三种建模方式

| 方式 | 隔离性 | 字段上限 | 运维成本 |
|---|---|---|---|
| 每租户一个索引 | 最强 | 各自 1000 | 索引数爆炸，分片多 |
| 共享索引 + 固定 schema + `flattened` | 中 | 共享 1000 | 低 |
| 共享索引 + 每租户独立字段前缀 | 弱 | 共享 1000，很快耗尽 | 低但不可持续 |

推荐组合：**核心字段固定 schema + 自定义属性统一放 `flattened` 字段 + `dynamic: strict` 兜底**。

```json
{
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "tenantId": { "type": "keyword" },
      "entityId": { "type": "keyword" },
      "entityType": { "type": "keyword" },
      "createdAt": { "type": "date" },
      "core": {
        "properties": {
          "name":  { "type": "text", "fields": { "kw": { "type": "keyword" } } },
          "status": { "type": "keyword" }
        }
      },
      "custom": { "type": "flattened" }
    }
  }
}
```

租户自定义字段全部进 `custom`，查询用 `custom.<key>`，永远不会新增 mapping 字段。

### 5.2 写入前做 key 白名单

即使有 `flattened`，也要限制 key 的数量和长度，防止单文档过大：

```java
public class CustomFieldValidator {

    private static final int MAX_KEYS = 50;
    private static final int MAX_KEY_LENGTH = 64;
    private static final Pattern KEY_PATTERN =
        Pattern.compile("^[a-zA-Z][a-zA-Z0-9_]{0,63}$");

    public void validate(Map<String, Object> custom) {
        if (custom == null) {
            return;
        }
        if (custom.size() > MAX_KEYS) {
            throw new IllegalArgumentException("custom fields exceed " + MAX_KEYS);
        }
        for (Map.Entry<String, Object> e : custom.entrySet()) {
            String key = e.getKey();
            if (!KEY_PATTERN.matcher(key).matches()) {
                throw new IllegalArgumentException("invalid custom key: " + key);
            }
            if (key.length() > MAX_KEY_LENGTH) {
                throw new IllegalArgumentException("custom key too long: " + key);
            }
            if (e.getValue() instanceof Map) {
                throw new IllegalArgumentException("nested custom object not allowed: " + key);
            }
        }
    }
}
```

---

## 六、已经炸了怎么迁移

### 6.1 评估影响面

```bash
GET /_cluster/state/metadata?filter_path=metadata.indices.*.mappings
```

或者用 `_cat/indices` 看大小，再逐个索引查字段数：

```json
GET /orders/_mapping
```

生产上更实用的是用脚本统计：

```bash
for idx in $(curl -s 'localhost:9200/_cat/indices?h=index' | grep '^orders-'); do
  n=$(curl -s "localhost:9200/$idx/_mapping" | jq '[.. | objects | select(has("type"))] | length')
  echo "$idx $n"
done
```

### 6.2 新建索引 + reindex + 别名切换

```json
PUT /orders_v2
{
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "orderId": { "type": "keyword" },
      "custom":  { "type": "flattened" }
    }
  }
}

POST /_reindex?wait_for_completion=false
{
  "source": { "index": "orders_v1" },
  "dest":   { "index": "orders_v2" }
}
```

切换别名：

```json
POST /_aliases
{
  "actions": [
    { "remove": { "index": "orders_v1", "alias": "orders" } },
    { "add":    { "index": "orders_v2", "alias": "orders" } }
  ]
}
```

`_reindex` 是后台任务，要监控：

```json
GET /_tasks?actions=*reindex&detailed=true
```

### 6.3 双写过渡

reindex 期间的新数据要双写，否则会丢：

```java
public void save(OrderDocument doc) {
    // 新索引为主
    orderV2Repository.save(doc);
    // 过渡期双写旧索引，保证回滚可用
    if (dualWriteEnabled) {
        orderV1Repository.save(doc);
    }
}
```

切换完成后先停双写，观察一个发布周期，再删除旧索引。不要当天删。

### 6.4 Java 侧用 RestClient 做迁移校验

```java
public boolean mappingCompatible(String index) throws IOException {
    Request req = new Request("GET", "/" + index + "/_mapping");
    Response resp = restClient.performRequest(req);
    JsonNode root = objectMapper.readTree(resp.getEntity().getContent());

    JsonNode props = root.path(index).path("mappings").path("properties");
    int fieldCount = countFields(props);
    if (fieldCount > 900) {
        log.warn("index {} has {} fields, approaching limit", index, fieldCount);
        return false;
    }
    return true;
}

private int countFields(JsonNode props) {
    int count = 0;
    Iterator<Map.Entry<String, JsonNode>> it = props.fields();
    while (it.hasNext()) {
        Map.Entry<String, JsonNode> e = it.next();
        count++;
        JsonNode sub = e.getValue().path("properties");
        if (sub.isObject()) {
            count += countFields(sub);
        }
    }
    return count;
}
```

把这个检查接进 CI 或定时任务，字段数超过 900 就告警。

---

## 七、监控指标

| 指标 | 采集方式 | 告警阈值 |
|---|---|---|
| 单索引字段数 | `_mapping` 统计 | > 800 警告，> 950 严重 |
| cluster state 大小 | `_nodes/stats` → `indices.cluster_state` | 持续增长 |
| mapping update 失败率 | 应用侧日志 | > 0.1% |
| `mapper_parsing_exception` | 应用侧日志 | 出现即告警 |
| 单文档 `_source` 大小 | 写入前校验 | > 1MB 拒绝 |
| `flattened` 字段 key 数 | 应用侧校验 | > 50 拒绝 |

---

## 八、面试追问

**Q1：`dynamic: false` 和 `dynamic: strict` 有什么区别？**

`false` 忽略未知字段，不加入 mapping，但值仍写入 `_source`，可以取回但不能搜索；`strict` 直接拒绝包含未知字段的文档，写入失败。前者适合「透传但不查」，后者适合「schema 必须严格」。

**Q2：`flattened` 能替代 `nested` 吗？**

不能。`flattened` 丢失对象数组的内部关系，所有值平铺成 keyword；`nested` 为每个子对象建独立 Lucene 文档，能保持对象内字段的关联。需要「同一个对象内 A 和 B 同时满足」的查询，必须用 `nested`。

**Q3：为什么字段多了 cluster state 会变大？**

mapping 是 cluster state 的一部分，每个字段的类型、参数、子字段都序列化在里面。cluster state 要广播到所有节点并持久化，体积越大，publish 越慢，节点加入/恢复越慢。

**Q4：`index.mapping.total_fields.limit` 调大行不行？**

短期能解燃眉之急，但会放大 cluster state、mapping 解析和恢复成本。正确做法是治理字段来源，用 `flattened`、`enabled:false`、runtime field 或拆索引，而不是无限调大上限。

**Q5：动态模板能解决字段爆炸吗？**

能缓解，不能根治。它控制「新字段建成什么类型」，但不会阻止新字段产生。要根治必须限制 key 的枚举范围（白名单）或把它们收进 `flattened`。

---

## 九、总结

五句话：

1. 一个字段不只是 mapping 一行，而是 5~8 份存储结构 + cluster state 体积；
2. `dynamic mapping` 是字段爆炸的源头，来源不可控的数据必须显式设 `dynamic`；
3. 治理优先级：`flattened` > `enabled:false` > `index:false` > 调大上限；
4. 多租户用「固定核心 schema + 自定义属性 flattened + 写入白名单」；
5. 已经爆炸的索引用「新索引 + reindex + 别名切换 + 双写过渡」迁移，别原地改 mapping。

Mapping 是 ES 的 schema，schema 失控，集群一定失控。把字段数当成一个一级监控指标，比出事后再扩容划算得多。
