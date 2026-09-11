---
title: 【ES 实战】Elasticsearch 地理位置搜索深度实战：geo_point、geo_shape 与距离排序的底层原理
date: 2026-09-11 08:30:00
tags:
  - Elasticsearch
  - 地理搜索
  - 性能优化
categories:
  - Elasticsearch
  - 中间件
author: 东哥
---

# 【ES 实战】Elasticsearch 地理位置搜索深度实战：geo_point、geo_shape 与距离排序的底层原理

## 面试官：做一个"附近的商家"功能，为什么 Elasticsearch 比 MySQL 更合适？

"找出我周围 3 公里内的商家，按距离排序"，如果直接用 MySQL：

```sql
-- 经纬度两个 DOUBLE 列 + 边界框粗筛 + 球面距离精算
SELECT id, name,
       6371 * ACOS(COS(RADIANS(lat)) * COS(RADIANS(:lat)) *
                   COS(RADIANS(:lon) - RADIANS(lng)) +
                   SIN(RADIANS(lat)) * SIN(RADIANS(:lat))) AS distance
FROM shop
WHERE lat BETWEEN :lat - 0.027 AND :lat + 0.027
  AND lng BETWEEN :lng - 0.036 AND :lng + 0.036
HAVING distance < 3
ORDER BY distance
LIMIT 20;
```

问题很现实：**边界框在经纬度上不是矩形（越靠近极点越"胖"）**，二维 B-Tree 索引只能一维前缀匹配粗筛，剩下的全靠回表算球面距离——商家量级到百万就顶不住了。

ES 的做法完全不同：用 **BKD Tree** 把二维/多维坐标编码成一维的莫顿码（Z-order curve）建索引，可以直接在索引上做范围裁剪，同时支持距离排序、多边形过滤、任意几何相交。再加上倒排索引的组合过滤（品类、营业状态、评分），这就是"附近的商家"的标准实现。

## 一、geo_point：点坐标的索引方式

### 定义字段

```json
PUT /shop
{
  "mappings": {
    "properties": {
      "name":       { "type": "text" },
      "category":   { "type": "keyword" },
      "status":     { "type": "keyword" },
      "rating":     { "type": "float" },
      "location":   { "type": "geo_point" },
      "service_area": { "type": "geo_shape" }
    }
  }
}
```

`geo_point` 支持四种写法：

```json
{ "location": "39.9087,116.3975" }                       // 字符串 lat,lon
{ "location": { "lat": 39.9087, "lon": 116.3975 } }       // 对象（推荐，不易混淆）
{ "location": [116.3975, 39.9087] }                       // 数组（注意是 lon,lat！）
{ "location": "u4pruydqqvjp" }                            // geohash 字符串
```

> ⚠️ **最高频的坑**：数组和 geohash 都是 `lon, lat` 顺序，只有字符串和对象是 `lat, lon`。写错一个顺序，商家就跑到南半球去了。生产上建议统一用对象写法。

### 参数

| 参数 | 说明 | 建议 |
| --- | --- | --- |
| `index` | 是否建索引（参与查询） | 需要按位置过滤时 `true`（默认） |
| `doc_values` | 是否建列存（用于排序/聚合） | 需要距离排序时 `true`（默认） |
| `ignore_malformed` | 非法坐标是否忽略 | 采集数据脏时设 `true`，否则整个文档写入失败 |
| `null_value` | 空值替代 | 一般不需要 |

如果只做展示、不参与任何位置查询，设 `"index": false` 可以显著减少索引体积。

### 底层：BKD Tree 与 Morton 编码

Lucene 从 6.0 起用 **BKD Tree（Block K-D Tree）** 存储多维点数据，替代了早期的 geohash 前缀树（trie）。

**为什么不用 geohash trie？**
geohash 把经纬度交替取 bit 编码成字符串（base32），是二维到一维的莫顿编码。它的优点是前缀即区域，但缺点是：

- 一个矩形查询要展开成多个 geohash 前缀（边界上产生大量"碎片"）；
- 高精度 geohash 前缀数量爆炸，查询要枚举很多 cell；
- 更新时树结构不稳（早期采用按 cell 数量拆分的 trie）。

**BKD Tree 的思路**：把点集合按某一维递归二分，切分时选**方差最大（分布最散）的维度**，叶节点存放最多 512 个点（`maxPointsInLeafNode`），内部节点记录该维度的切分值与子树包围盒。查询时按包围盒与查询区域相交判断是否下探，天然支持任意 K 维范围查询，裁剪效率远超前缀枚举。

对 `geo_point` 这种 2 维数据，BKD 让"矩形/圆/多边形范围查询"都能高效下推。**同一套结构还支撑了 ES 的数值/日期范围查询**——这也是为什么数值类型不叫"B-Tree 索引"而叫 points。

## 二、geo_shape：任意几何形状

`geo_point` 只能表示一个点。如果要表达"配送范围""行政区划""电子围栏"，就用 `geo_shape`。

```json
PUT /shop/_doc/1
{
  "name": "东哥烧烤",
  "location": { "lat": 39.9087, "lon": 116.3975 },
  "service_area": {
    "type": "polygon",
    "coordinates": [[
      [116.3800, 39.9000],
      [116.4100, 39.9000],
      [116.4100, 39.9200],
      [116.3800, 39.9200],
      [116.3800, 39.9000]
    ]]
  }
}
```

支持的几何类型（GeoJSON 语义）：

| 类型 | 说明 |
| --- | --- |
| `point` | 单点 |
| `linestring` | 线 |
| `polygon` | 多边形（可带洞） |
| `multipoint` / `multilinestring` / `multipolygon` | 多值版本 |
| `envelope` | 矩形（对角两点，ES 特有，最省空间） |
| `circle` | 圆（圆心 + 半径 + 距离单位，ES 特有） |
| `geometrycollection` | 混合集合 |

`geo_shape` 的关键参数：

```json
"service_area": {
  "type": "geo_shape",
  "tree": "quadtree",          // geohash | quadtree（默认）
  "precision": "1km",          // tree=geohash 时用；quadtree 用 tree_levels
  "tree_levels": "8",
  "orientation": "ccw",        // 多边形顶点方向，影响"内部"判定
  "strategy": "recursive"      // recursive | term（term 用于大量小多边形）
}
```

> **`orientation` 是个隐藏地雷**：GeoJSON 规范要求外环逆时针（ccw），但很多工具导出的是顺时针，会让"多边形内部"翻转成"整个地球除了这块"。排查手法：看 `within` 查询结果是不是"全中"或"全不中"。

## 三、核心查询

### 1. geo_distance：圆形范围 + 距离计算

```json
GET /shop/_search
{
  "query": {
    "bool": {
      "filter": [
        { "term":  { "status": "OPEN" } },
        { "range": { "rating": { "gte": 4.0 } } },
        {
          "geo_distance": {
            "distance": "3km",
            "location": { "lat": 39.9087, "lon": 116.3975 },
            "distance_type": "arc",
            "validation_method": "STRICT"
          }
        }
      ]
    }
  },
  "sort": [
    {
      "_geo_distance": {
        "location": { "lat": 39.9087, "lon": 116.3975 },
        "order": "asc",
        "unit": "m",
        "mode": "min",
        "distance_type": "arc",
        "ignore_unmapped": false
      }
    },
    { "rating": "desc" }
  ],
  "size": 20
}
```

要点：

- **`distance_type`**：`arc`（默认，按球面 haversine 计算，准确）与 `plane`（平面快速计算，误差随距离增大）。`plane` 更快，可用于粗筛或小范围（< 50km）场景。
- **`mode`**：文档有多个坐标（比如连锁店有多个门店）时，`min`（最近的那个）、`max`、`avg` 决定排序依据。
- **放到 `filter` 而不是 `must`**：filter 不计算相关性得分，还能走查询缓存。
- **`size` 必须限制**：距离排序是"找出最近的 N 个"，不需要跑全量。

### 2. geo_bounding_box：矩形范围（最快）

```json
{
  "query": {
    "geo_bounding_box": {
      "location": {
        "top_left":     { "lat": 39.92, "lon": 116.38 },
        "bottom_right": { "lat": 39.90, "lon": 116.41 }
      }
    }
  }
}
```

"地图拖动加载"场景就先用 bounding box 粗筛（视觉范围内），再在客户端做精细距离排序。这是**性能最优**的打法，因为 BKD 对矩形裁剪极其高效。

### 3. geo_polygon：多边形内

```json
{
  "query": {
    "geo_polygon": {
      "location": {
        "points": [
          { "lat": 39.90, "lon": 116.38 },
          { "lat": 39.90, "lon": 116.41 },
          { "lat": 39.92, "lon": 116.41 }
        ]
      }
    }
  }
}
```

### 4. geo_shape：形状相交（围栏、配送范围）

```json
{
  "query": {
    "geo_shape": {
      "service_area": {
        "shape": {
          "type": "circle",
          "radius": "2km",
          "coordinates": { "lat": 39.9087, "lon": 116.3975 }
        },
        "relation": "intersects"     // intersects | disjoint | within | contains
      }
    }
  }
}
```

### 5. distance_feature：把"距离近"变成相关性得分

产品和搜索结合时，往往希望"距离越近、评分越高，但不要硬过滤"：

```json
{
  "query": {
    "bool": {
      "must": [ { "match": { "name": "烧烤" } } ],
      "should": [
        {
          "distance_feature": {
            "field": "location",
            "pivot": "1km",
            "origin": { "lat": 39.9087, "lon": 116.3975 },
            "boost": 2.0
          }
        }
      ]
    }
  }
}
```

`distance_feature` 的得分曲线是"距离 ≤ pivot 给满分，之后快速衰减"，比手工用 `function_score` + `gauss` 更简单也更快（内部用 BKD 加速）。

## 四、性能优化清单

| 优化点 | 做法 | 收益 |
| --- | --- | --- |
| 粗筛 + 精算 | bounding box 过滤 + 客户端/脚本精算距离 | 避免大量球面计算 |
| `distance_type: plane` | 小范围用平面近似 | 排序快 2~5 倍 |
| 限制 `size` | 只取最近 20~50 条 | 避免深度排序 |
| filter 上下文 | 位置/状态过滤放 `filter` | 命中查询缓存 |
| 减少多值坐标 | 一个文档一个主坐标，连锁店拆文档 | 排序更稳、更省空间 |
| `index: false` 用于仅展示 | 不参与查询的坐标字段 | 索引体积下降 |
| 避免深分页 | 用 `search_after` | 防止堆排序爆炸 |
| 精度按需 | `geo_shape` 的 `precision` 别设过高 | 索引体积与查询耗时 |
| 冷热分层 | 历史门店数据放冷节点 | 降低热节点压力 |

**关于精度选择的经验**：`geo_shape` 的 `precision: 1km` 意味着多边形边界被量化到 1 公里的网格，**会出现"多边形外一点点被算作内部"的误差**。电子围栏类业务（比如"是否进入园区"）如果要求米级精度，要么提高 precision（索引变大），要么先 ES 粗筛再在应用层用 JTS/Turf 精算。

## 五、与 Redis GEO、PostGIS 的对比

| 维度 | ES geo_point / geo_shape | Redis GEO | PostGIS |
| --- | --- | --- | --- |
| 索引结构 | BKD Tree（多维点） | ZSet + 52bit geohash | GiST / SP-GiST |
| 查询能力 | 点、矩形、圆、多边形、任意几何相交 | **仅圆形半径查询**（GEORADIUS/BYBOX） | 完整的空间函数（交集、缓冲区、投影） |
| 排序/聚合 | 距离排序 + 相关性融合 + 复杂聚合 | 距离排序；聚合弱 | 完全 SQL 能力 |
| 数据规模 | 亿级 | 百万级内存受限 | 千万级（受单机限制） |
| 适合场景 | 搜索 + 位置组合（"附近的烧烤，评分 4.5+"） | 高频低延迟的"附近的人"（纯位置） | GIS 分析、复杂几何运算 |
| 一致性 | 近实时（默认 1s refresh） | 强一致（内存） | 强一致（事务） |

选型口诀：**搜索维度多 → ES；纯位置、极致低延迟 → Redis GEO；复杂几何分析 → PostGIS**。真实的"附近商家"业务往往是 **Redis GEO 做首屏高频召回 + ES 做带筛选条件的搜索结果**。

## 六、生产踩坑清单

1. **经纬度顺序搞反**（`lat,lon` vs `lon,lat`），坐标跑到南极/太平洋。
2. **`distance_type` 默认 arc 却以为很快**，大范围排序时 CPU 飙高；小范围改成 `plane`。
3. **geo_shape 的 orientation 反了**，`within` 结果全错。
4. **precision 过低导致围栏误判**，把 500 米外的订单算进配送范围。
5. **距离排序不做 size 限制 + 深分页**，导致堆排序 OOM 或超时。
6. **多值坐标不指定 `mode`**，排序结果与预期不符。
7. **刷新延迟**：写入后立刻查可能查不到（默认 1s refresh），需要 `?refresh=wait_for`（性能代价大，仅测试用）。
8. **时区/单位**：`distance: "3km"` 支持 `m/km/mi/ft` 等单位，别把 `mi` 写成 `km`。

## 面试官追问

**Q1：ES 为什么用 BKD Tree 而不是 geohash 前缀树？**
geohash 前缀树在矩形查询时会产生大量边界碎片、需要枚举多个前缀，且高精度下 cell 数量爆炸，树结构维护成本高。BKD Tree 通过按维度二分 + 包围盒裁剪，支持任意多维范围查询，裁剪更精准、更新更稳定，还能统一支撑数值和日期类型。

**Q2：`geo_distance` 的 `arc` 和 `plane` 具体差多少？**
`arc` 用 haversine 球面公式，结果准确；`plane` 把经纬度当作平面坐标（纬度差 × 111km），在 10~50km 内误差通常 < 1%，超过百公里误差迅速放大，跨半球完全不可用。所以"同城附近"可以用 plane，"跨省检索"必须 arc。

**Q3：距离排序能走索引吗？**
能"半走"。BKD 负责快速裁剪出候选集（尤其是配合 bounding box），但精确的全局排序仍然需要对候选集计算距离并排序，所以**限制候选集大小**（先 box 过滤再距离排序）才是性能关键。

**Q4：怎么实现"搜索半径内最近 10 个，但不足 10 个就自动扩大范围"？**
两种实现：① 应用层循环（3km 查到 10 条就返回，否则 5km → 10km），代价是多次查询；② 用 `distance_feature` + `track_total_hits` 一次查询，按得分衰减自然实现"优先近的，没有就放宽"，再用 `min_score` 控制下限。生产上更推荐 ①，因为可控且能用 filter 缓存。

**Q5：geo_shape 数据量很大时怎么优化？**
减少多边形顶点数（用 Douglas-Peucker 简化）、调低 `precision`/`tree_levels`、用 `envelope` 代替多边形做粗筛、把大围栏拆成网格化的 `term` 索引（`strategy: term`）、冷热分层。

## 总结

1. **`geo_point` 走 BKD Tree**：多维点索引，支撑圆形、矩形、多边形与距离排序，是"附近的 X"的基础。
2. **`geo_shape` 走 Quadtree/geohash**：表达任意几何，适合配送范围、电子围栏，注意 `orientation` 与 `precision`。
3. **性能核心是"粗筛 + 精算 + 限制候选集"**：bounding box 先裁剪，`size` 限制结果，小范围用 `plane`，位置过滤放 `filter` 上下文。
4. **选型看查询维度**：纯位置召回用 Redis GEO，带多维筛选的搜索用 ES，复杂 GIS 运算用 PostGIS。
