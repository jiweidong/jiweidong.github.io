---
title: 【Elasticsearch 进阶】Nested 与 Object 类型深度解析：对象数组扁平化陷阱、nested 查询原理与选型
date: 2026-10-01 08:00:00
tags:
  - Java
  - Elasticsearch
  - 搜索引擎
  - 数据结构
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Elasticsearch 进阶】Nested 与 Object 类型深度解析：对象数组扁平化陷阱、nested 查询原理与选型

## 面试官：ES 里存对象数组，为什么查询结果总是不对？

如果面试官问出这句话，说明他踩过坑。而正确回答这个问题，需要同时理解 **Lucene 的倒排索引本质** 和 **ES 的文档模型**。

先看一个经典反例：

```json
{
  "goods_id": 1001,
  "sku": [
    { "color": "red",  "size": "L" },
    { "color": "blue", "size": "S" }
  ]
}
```

查询"红色且 L 码"：

```json
{
  "query": {
    "bool": {
      "must": [
        { "term": { "sku.color": "red" } },
        { "term": { "sku.size":  "L" } }
      ]
    }
  }
}
```

你期望命中 1 条（red+L 那条）。但如果你用的是默认的 `object` 类型，**结果会命中，然而这不是因为两个条件落在同一个 sku 上** —— 它只是因为文档里同时存在 `red` 和 `L`。如果数据是：

```json
{
  "goods_id": 1002,
  "sku": [
    { "color": "red",  "size": "S" },
    { "color": "blue", "size": "L" }
  ]
}
```

这条**也会被命中**，但它根本没有"红色 L 码"的 SKU。这就是 **对象数组扁平化（flattening）陷阱**。

## 一、根因：Lucene 没有"对象"概念

要理解这个坑，得从底层说起。

Lucene 的基本单位是 **Document**，它由一组 `field` 组成，每个 field 是 `name → value`。而在这个模型里：

- **没有嵌套结构**；
- **没有数组类型** —— 多值只是"同一个 field 名出现多次"；
- 所有 field 都只是 `(name, value)` 的扁平列表。

ES 在把 JSON 文档写入 Lucene 时，会做一次**路径展开（flattening）**：

```json
{
  "sku": [
    { "color": "red",  "size": "S" },
    { "color": "blue", "size": "L" }
  ]
}
```

被展开成：

```
sku.color = ["red", "blue"]
sku.size  = ["S", "L"]
```

**对象边界在这个转换中丢失了。** 于是 `sku.color=red AND sku.size=L` 的判断，实际上变成了"集合包含 `red`" 且 "集合包含 `L`"，两个条件可以来自不同的数组元素。

我们可以用 `_analyze` 或直接 `GET /index/_doc/1002` 观察存储结果，再配合 `explain` 看评分，就能确认它匹配的其实是扁平后的字段。

## 二、`object` 类型详解

### 2.1 声明

```json
PUT /goods
{
  "mappings": {
    "properties": {
      "goods_id": { "type": "keyword" },
      "sku": {
        "type": "object",
        "properties": {
          "color": { "type": "keyword" },
          "size":  { "type": "keyword" },
          "price": { "type": "double" }
        }
      }
    }
  }
}
```

`object` 是**默认类型**，不声明也是它。

### 2.2 点号访问

对象字段可以用 `sku.color` 这种点号路径查询，但**本质上它只是 `sku.color` 这个扁平 field 名**，中间并没有层级。

```json
GET /goods/_search
{
  "query": { "term": { "sku.color": "red" } }
}
```

### 2.3 什么时候 object 够用？

- 对象**不是数组**（单个对象），此时不存在跨元素污染问题；
- 对象是数组，但**查询时不会同时约束多个子字段**；
- 用于**聚合**（聚合 `sku.color` 会把所有元素的值合并统计，恰好是想要的效果）。

## 三、`nested` 类型：保留对象边界

### 3.1 声明

```json
PUT /goods_nested
{
  "mappings": {
    "properties": {
      "goods_id": { "type": "keyword" },
      "sku": {
        "type": "nested",
        "properties": {
          "color": { "type": "keyword" },
          "size":  { "type": "keyword" },
          "price": { "type": "double" }
        }
      }
    }
  }
}
```

### 3.2 存储原理：每个 nested 对象是一个独立 Lucene 文档

这是 `nested` 最关键的设计：

```
主文档 (doc id = 1001)
  ├── goods_id: 1001
  └── _nested 字段指向两个隐藏子文档

隐藏子文档 A (doc id = 1001-a)
  ├── sku.color: red
  ├── sku.size:  L
  └── _nested_path: sku

隐藏子文档 B (doc id = 1001-b)
  ├── sku.color: blue
  ├── sku.size:  S
  └── _nested_path: sku
```

也就是说，**ES 把数组里的每个对象都拆成了一个独立的 Lucene 文档**，通过一个叫 `_nested` 的元数据字段关联回主文档。

这样做的好处：**对象边界被保留了**，每个子文档内部的字段是"同一个逻辑对象"的。

### 3.3 查询：`nested` query

要查询 nested 字段，**必须**用 `nested` query 包裹：

```json
GET /goods_nested/_search
{
  "query": {
    "nested": {
      "path": "sku",
      "query": {
        "bool": {
          "must": [
            { "term": { "sku.color": "red" } },
            { "term": { "sku.size":  "L" } }
          ]
        }
      },
      "score_mode": "avg"
    }
  }
}
```

现在，两个 `term` 是在**同一个嵌套文档**内匹配的，语义正确了。上面那条"red+S / blue+L"的文档不会再被误命中。

关键参数：

| 参数 | 说明 |
| --- | --- |
| `path` | 嵌套路径，必填 |
| `query` | 作用于单个嵌套文档的查询 |
| `score_mode` | 多个匹配嵌套文档如何合成父文档得分：`avg` / `max` / `min` / `sum` / `none` |
| `ignore_unmapped` | 路径不存在时是否忽略而不报错 |
| `inner_hits` | 返回**具体命中了哪些嵌套文档** |

### 3.4 `inner_hits`：只看命中的那个对象

```json
{
  "query": {
    "nested": {
      "path": "sku",
      "query": { "range": { "sku.price": { "lte": 100 } } },
      "inner_hits": {
        "size": 3,
        "sort": [ { "sku.price": "asc" } ]
      }
    }
  }
}
```

响应里会多出 `inner_hits.sku.hits.hits`，只包含满足条件的嵌套对象。**前端展示"命中的那个 SKU"就靠它**，否则拿到的是整个数组，无法区分。

## 四、nested 的代价

### 4.1 查询性能

`nested` query 的执行是**两阶段**的：

```
阶段1：在嵌套文档空间内匹配，找出所有满足条件的子文档
阶段2：把子文档映射回父文档（通过 _nested 关联），再去重
```

因此比普通 term 查询慢，且**父文档得分需要聚合**（`score_mode`）。当嵌套文档数量很大时，隐式的 join 成本不可忽视。

### 4.2 写入放大

每个数组元素都是一个独立 Lucene 文档，因此：

- **文档数膨胀**：1 个 ES 文档 = 1 + N 个 Lucene 文档；
- **`_nested` 元数据开销**；
- **段合并（merge）压力增大**。

索引 100 万商品、每个 50 个 SKU，实际 Lucene 文档数接近 5100 万。

### 4.3 更新代价

ES 文档更新是**整文档替换**。改一个 SKU，整个商品文档（含所有嵌套子文档）都要重建。**nested 数组越大，更新越贵**。

### 4.4 查询限制

- **不能对 nested 字段直接排序**（排序发生在父文档层面）；
- **聚合 nested 字段必须用 `nested` aggregation**；
- **不能跨嵌套层级做常规 join**。

## 五、聚合 nested 字段

普通聚合在 nested 字段上会**丢失对象边界**（和查询同样的问题）：

```json
GET /goods_nested/_search
{
  "size": 0,
  "aggs": {
    "sku_aggs": {
      "nested": { "path": "sku" },
      "aggs": {
        "colors": { "terms": { "field": "sku.color" } },
        "avg_price": { "avg": { "field": "sku.price" } }
      }
    }
  }
}
```

`nested` aggregation 会切换到嵌套文档空间，其**子聚合作用于每个嵌套文档**。如果想回到父文档维度做其他聚合，需要 `reverse_nested`：

```json
{
  "aggs": {
    "sku": {
      "nested": { "path": "sku" },
      "aggs": {
        "colors": { "terms": { "field": "sku.color" } },
        "parent_count": {
          "reverse_nested": {},
          "aggs": { "brands": { "terms": { "field": "brand" } } }
        }
      }
    }
  }
}
```

## 六、`flattened` 类型：另一个选项

ES 7.3 引入了 `flattened` 类型，把整个对象当作**单一字段**处理：

```json
{
  "mappings": {
    "properties": {
      "sku": { "type": "flattened" }
    }
  }
}
```

特点：

- 所有叶子值**作为 keyword 索引**，不做分词、不做数值类型；
- 不能做 `range` 查询、不能排序、聚合能力有限；
- **文档数不膨胀**，写入成本远低于 nested；
- 适合"字段数量不固定、只需精确匹配"的场景（如动态标签、配置快照）。

| 类型 | 边界保留 | 写入成本 | 查询能力 | 典型场景 |
| --- | --- | --- | --- | --- |
| object | ❌ | 低 | 完整 | 单对象、无需交叉约束 |
| nested | ✅ | 高 | 完整（需 nested query） | 对象数组 + 交叉条件查询 |
| flattened | 部分（只有叶子） | 低 | 有限（无 range/排序） | 动态 key、只需精确匹配 |
| join（父子） | ✅（跨文档） | 中 | 需 has_child/has_parent | 一对多、更新频繁 |

## 七、`join` 类型：nested 的替代方案

当嵌套数据**更新频繁或数量极大**时，`join` 字段（父子文档）更合适：

```json
PUT /goods_join
{
  "mappings": {
    "properties": {
      "goods_id": { "type": "keyword" },
      "relation": {
        "type": "join",
        "relations": { "goods": "sku" }
      },
      "color": { "type": "keyword" },
      "size":  { "type": "keyword" }
    }
  }
}
```

父文档：

```json
PUT /goods_join/_doc/1001?refresh
{ "goods_id": "1001", "relation": { "name": "goods" } }
```

子文档：

```json
PUT /goods_join/_doc/1001-red-L?routing=1001&refresh
{
  "color": "red",
  "size": "L",
  "relation": { "name": "sku", "parent": "1001" }
}
```

查询"红色且 L 码的商品"：

```json
{
  "query": {
    "has_child": {
      "type": "sku",
      "query": {
        "bool": {
          "must": [
            { "term": { "color": "red" } },
            { "term": { "size":  "L" } }
          ]
        }
      },
      "score_mode": "max"
    }
  }
}
```

优点：

- 子文档独立更新，**不必重建整个父文档**；
- 不受 nest 深度限制（实际限制是每 shard 文档数）；
- 子文档可以独立查询。

缺点：

- **父子文档必须位于同一 shard**（用 `routing` 保证），存在数据倾斜风险；
- join 查询比 nested **更慢**（需要按 `_id` 关联，还要加载全局序号）；
- 每个索引**只能有一个 join 字段**。

## 八、选型决策树

```
需要"对象数组 + 多字段同时约束"查询？
├── 否 → 用 object（最简单、最省资源）
└── 是
    ├── 数组长度小（< 几十），查询频繁，写入不频繁
    │     → 用 nested
    ├── 数组长度大 / 更新频繁 / 子对象需要独立检索
    │     → 用 join（父子文档）
    └── 只需精确匹配，不需要 range/排序/复杂聚合
          → 用 flattened
```

补充经验：

- **nested 数组建议控制在 20~50 个元素以内**，超了考虑拆成子文档或单独索引；
- **能用 keyword + 冗余字段解决的，不要上 nested**。比如"红-L"合成一个 `sku_attr = "red|L"` 字段，精确匹配直接用 term，性能最好——这是很多大厂的实际做法。
- 如果嵌套只是用来"展示"，查询从不交叉，**坚持用 object**，省下的资源很可观。

## 九、面试高频追问

**Q1：为什么 ES 的 object 数组无法区分元素边界？**

因为底层 Lucene 的文档模型只有"扁平的多值字段"，没有嵌套结构。ES 写入时会把对象数组展开成多个同名字段，对象边界在展开过程中丢失。

**Q2：nested 是怎么实现"保留边界"的？**

每个嵌套对象被**索引成一个独立的隐藏 Lucene 文档**，并通过 `_nested` 元数据关联回父文档。查询时先匹配子文档，再映射回父文档去重。

**Q3：nested 查询为什么慢？**

两阶段执行：子文档匹配 + 父文档映射去重；且父文档得分需要按 `score_mode` 聚合。嵌套文档数量越多，隐式 join 成本越高。

**Q4：nested 字段怎么排序？**

不能按 nested 字段排序（排序只能基于父文档的字段）。变通方案：在父文档上冗余一个"最低价"字段并在写入时维护。

**Q5：nested 聚合和普通聚合有什么区别？**

普通聚合在 nested 字段上会丢失对象边界。必须用 `nested` aggregation 进入嵌套空间；需要回到父文档维度时用 `reverse_nested`。

**Q6：nested 和 join 怎么选？**

更新频繁、子对象数量大、子对象需要独立检索 → join；查询频繁、数组小、更新少 → nested。nested 查询更快，join 更新更便宜。

**Q7：有没有比 nested 更省资源的方案？**

有。把多字段组合成一个复合 keyword（如 `color|size`）做精确匹配，或用 `flattened`。前提是查询模式允许——不需要 range、复合排序时最划算。

## 十、总结

对象数组扁平化不是 ES 的 bug，而是 **Lucene 文档模型的必然结果**。理解这一点，才能正确选择类型：

| 结论 | 说明 |
| --- | --- |
| object 会丢边界 | 交叉条件查询会误命中 |
| nested 保边界但贵 | 写入膨胀、查询两阶段、更新重建 |
| flattened 便宜但能力弱 | 无 range、无排序 |
| join 适合频繁更新 | 但 join 查询更慢、有 routing 约束 |
| 最优解常常是"避开嵌套" | 复合 keyword 冗余字段 |

最后一句话：**看到"对象数组 + 多条件同时匹配"，第一反应应该是嵌套语义问题，而不是先去调 `boost`。** 类型选错，调什么参数都是徒劳。

---

**参考**

- Elasticsearch 官方文档：Nested field type / Join field type / Flattened field type
- Elasticsearch 官方文档：Nested query / Nested aggregation / Reverse nested aggregation
