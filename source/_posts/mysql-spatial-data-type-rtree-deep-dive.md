---
title: 【MySQL 实战】MySQL 空间数据类型与 SPATIAL 索引深度解析：GIS 存储、R-Tree 与地理查询实战
date: 2026-09-25 08:00:00
tags:
  - MySQL
  - 空间索引
  - GIS
  - 数据库
  - 优化
categories:
  - MySQL
  - 数据库
author: 东哥
---

# 【MySQL 实战】MySQL 空间数据类型与 SPATIAL 索引深度解析：GIS 存储、R-Tree 与地理查询实战

## 场景：一个「附近 3 公里的门店」查询，为什么慢成狗？

表结构是这样的：

```sql
CREATE TABLE shop (
  id   BIGINT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(64),
  lng  DECIMAL(10,7),
  lat  DECIMAL(10,7)
);
```

查询附近门店，最朴素的写法是：

```sql
SELECT id, name, ST_Distance_Sphere(POINT(lng, lat), POINT(116.40, 39.90)) AS d
FROM shop
WHERE ST_Distance_Sphere(POINT(lng, lat), POINT(116.40, 39.90)) < 3000
ORDER BY d LIMIT 20;
```

10 万行数据就跑不动了——因为**两列经纬度上根本没有能用的索引**，这个条件是**函数计算**，只能全表扫描 + 逐行算球面距离。

要解决它，就得用 MySQL 的**空间数据类型 + SPATIAL 索引（R-Tree）**。这篇从类型、坐标系、函数讲到索引原理、SQL 写法与性能坑。

## 一、空间数据类型与坐标系

### 1.1 七种空间类型

MySQL 遵循 OGC（Open Geospatial Consortium）几何模型：

| 类型 | 含义 | 示例 |
| --- | --- | --- |
| `GEOMETRY` | 任意几何体的公共父类型 | 泛用兜底 |
| `POINT` | 点 | 门店、坐标 |
| `LINESTRING` | 线（有序点序列） | 路线、轨迹 |
| `POLYGON` | 多边形（外环 + 内环/洞） | 行政区、配送范围 |
| `MULTIPOINT` | 点集合 | 一批坐标 |
| `MULTILINESTRING` | 线集合 | 多条路线 |
| `MULTIPOLYGON` | 多边形集合 | 多块区域 |
| `GEOMETRYCOLLECTION` | 混合集合 | 混合几何 |

### 1.2 SRID 与坐标系：空间查询最容易踩的坑

**SRID（Spatial Reference System Identifier）** 定义了坐标的参考系：

| SRID | 坐标系 | 单位 | 用途 |
| --- | --- | --- | --- |
| 0 | 未定义 | 无 | 纯笛卡尔计算（默认） |
| 4326 | WGS 84（经纬度） | 度 | GPS、地图经纬度 |
| 3857 | Web 墨卡托 | 米 | 地图瓦片（近似平面） |
| 4490 | CGCS2000 | 度 | 国内测绘标准 |

**MySQL 8.0 的关键变化**：几何列**强制 SRID 一致性**——不同 SRID 的几何值做运算会直接报错：

```sql
-- ERROR 3033: Binary geometry function st_distance_sphere given two geometries of different srids
SELECT ST_Distance_Sphere(g1, g2) ...
```

所以建表时就该声明 SRID，插入时用 `ST_GeomFromText('POINT(lng lat)', 4326)` 显式带上：

```sql
CREATE TABLE shop (
  id    BIGINT PRIMARY KEY AUTO_INCREMENT,
  name  VARCHAR(64),
  location POINT NOT NULL SRID 4326,     -- 8.0 可声明 SRID
  SPATIAL INDEX idx_location (location)
);
```

注意：
- **`POINT` 的 WKT 是「经度在前、纬度在后」**：`POINT(116.40 39.90)`。写反了是最常见的低级 bug。
- MySQL 8.0 前 SRID 必须为 0，8.0 起支持 4326/3857 等，并会做**坐标范围校验**（经纬度超出范围报 `Invalid GIS data`）。

### 1.3 存储格式：WKT / WKB / GeoJSON

| 格式 | 特点 | 示例 |
| --- | --- | --- |
| WKT（文本） | 可读，体积大 | `POINT(116.4 39.9)` |
| WKB（二进制） | 紧凑，网络传输友好 | 十六进制 `0101000000...` |
| GeoJSON | 前端通用 | `{"type":"Point","coordinates":[116.4,39.9]}` |

MySQL 提供全套转换函数：`ST_GeomFromText`/`ST_AsText`、`ST_GeomFromWKB`/`ST_AsBinary`、`ST_GeomFromGeoJSON`/`ST_AsGeoJSON`。

```sql
INSERT INTO shop (name, location)
VALUES ('门店A', ST_GeomFromText('POINT(116.404 39.915)', 4326));

SELECT name, ST_AsText(location), ST_AsGeoJSON(location) FROM shop;
```

## 二、空间函数：计算与关系

### 2.1 距离计算

| 函数 | 说明 | 单位 |
| --- | --- | --- |
| `ST_Distance(g1, g2)` | 平面欧氏距离 | 取决于 SRID（4326 下是「度」，基本没用） |
| `ST_Distance_Sphere(g1, g2 [, radius])` | 球面大圆距离，默认地球半径 6370986 米 | **米** |
| `ST_DWithin(g1, g2, d)` | 是否在距离 d 内（8.0.30+，**可用索引**） | 米（SRID 3857） |

**坑**：经纬度直接用 `ST_Distance` 得到的是「度」，1 度 ≈ 111km，但它不随纬度变化修正，跨纬度地区误差大，绝对不要用。测距一律用 `ST_Distance_Sphere`。

### 2.2 关系判定（第二个参数是「度」还是「米」）

| 函数 | 含义 |
| --- | --- |
| `ST_Contains(a, b)` | a 是否完全包含 b |
| `ST_Within(a, b)` | a 是否在 b 内 |
| `ST_Intersects(a, b)` | 是否相交 |
| `ST_Disjoint(a, b)` | 是否不相交 |
| `ST_Touches/Crosses/Overlaps/Equals` | 其他 OGC 关系 |
| `MBRContains(a, b)` / `MBRWithin(a, b)` | 基于**最小外接矩形（MBR）**的快速判定，**可用 SPATIAL 索引** |
| `ST_IsValid(g)` | 几何是否合法 |

**核心区别**：`ST_Contains` 做精确几何运算；`MBRContains` 只比较外接矩形，是**索引可用的粗筛**（会多算一些）。生产查询的标准套路就是「**MBR 粗筛走索引 + ST_ 精筛**」。

### 2.3 构造与变换

```sql
ST_Buffer(g, d)        -- 缓冲区（可为点生成圆/多边形）
ST_Envelope(g)         -- 最小外接矩形
ST_Centroid(g)         -- 质心
ST_Transform(g, srid)  -- 坐标系转换（8.0 支持部分转换）
ST_Simplify(g, tol)    -- 抽稀
ST_Geohash(g)          -- 生成 geohash（8.0）
```

## 三、SPATIAL 索引：为什么是 R-Tree 而不是 B+ 树

### 3.1 B+ 树为什么不行

B+ 树是**一维有序**结构，索引键可比较大小。而二维（甚至多维）空间没有天然的「全序」——你无法把经纬度用单列排序表达「空间邻近」。给 `lng`、`lat` 各建一个 B+ 树也不行：`WHERE lng BETWEEN a AND b AND lat BETWEEN c AND d` 只能利用一个列（或走索引合并），且「矩形范围」和「邻近排序」都难以高效表达。

### 3.2 R-Tree 原理

**R-Tree（R 树）** 是专为多维空间设计的平衡树，核心概念是 **MBR（Minimum Bounding Rectangle，最小外接矩形）**：

- 叶子节点存**实际几何的 MBR**；
- 内部节点存**其所有子节点 MBR 的并集 MBR**；
- 查询时从根开始，**只下探与查询矩形相交的子树**，剪掉不相交的分支。

以「查询矩形内的所有门店」为例，R-Tree 只需要访问 MBR 与查询框相交的少数分支，而不是全表。

R 树的分裂策略（选择分裂轴、最小化面积/周长增量）决定了它的性能，但也会带来**节点重叠**——重叠越多剪枝越差，这是 R-Tree 在高写入、分布极端时性能下降的原因。InnoDB 的 R-Tree 实现会做插入优化，但**聚集特性仍远不如 B+ 树**。

### 3.3 建索引的限制（必考）

```sql
CREATE TABLE shop (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  location POINT NOT NULL SRID 4326,
  SPATIAL INDEX idx_loc (location)
);
```

规则：
1. **只能建在空间类型列上**（`GEOMETRY`/`POINT`/...）；
2. **列必须 `NOT NULL`**（8.0 起，旧版本 MyISAM 要求更严）；
3. **InnoDB 与 MyISAM 支持**，Memory 等不支持；MySQL 8.0 的 InnoDB 支持真实 R-Tree（早期只有 MyISAM 有真正的空间索引）；
4. **只对 `MBR*` 系列函数和 `ST_DWithin`（8.0.30+）等索引感知函数生效**——`ST_Contains`、`ST_Distance_Sphere` 本身**不会**走空间索引。

### 3.4 查看是否用到索引

```sql
EXPLAIN SELECT id, name FROM shop
WHERE MBRContains(ST_GeomFromText('POLYGON((...))', 4326), location);
```

看到 `key: idx_loc`、`type: range` 就说明走到了 R-Tree；如果 `type: ALL`，那就是全表。

## 四、实战：附近查询的正确写法

### 4.1 第一步：用「包围盒」粗筛（走索引）

以 `(lng0, lat0)` 为中心、半径 `r = 3000` 米，先算经纬度包围盒：纬度 1 度 ≈ 111320 米；经度 1 度 ≈ 111320 × cos(lat)。

```
deltaLat = r / 111320
deltaLng = r / (111320 * cos(radians(lat0)))
```

```sql
SELECT id, name,
       ST_Distance_Sphere(location, POINT(116.40, 39.90)) AS distance
FROM shop
WHERE MBRContains(
        ST_MakeEnvelope(
          ST_GeomFromText('POINT(116.40 39.90)', 4326),  -- 注意 WKT 经在前纬在后
          ST_GeomFromText('POINT(116.40 39.90)', 4326),
          deltaLng, deltaLat),
        location)
  AND ST_Distance_Sphere(location, POINT(116.40, 39.90)) < 3000   -- 精筛
ORDER BY distance
LIMIT 20;
```

> 8.0 更简洁的替代：直接用 `ST_DWithin`（8.0.30+）或 `ST_Buffer` 生成多边形：
> ```sql
> WHERE ST_Contains(ST_Buffer(ST_GeomFromText('POINT(116.40 39.90)', 4326), 0.03), location)
> ```
> 但 **`ST_Contains` 不走索引**，仍需配合 `MBRContains` 粗筛，或改用 `ST_DWithin`。

### 4.2 第二步：精筛排序

粗筛用 MBR 会**多算**（矩形 vs 圆），所以必须再用 `ST_Distance_Sphere` 精确判定并按距离排序。这样：

- `MBRContains` 把候选集从 10 万降到几百，且走 R-Tree；
- `ST_Distance_Sphere` 只对几百条算，开销可接受。

### 4.3 更现代的方案：SRID 3857 + `ST_DWithin`

MySQL 8.0.30 起支持 `ST_DWithin(g1, g2, distance, [unit])`，且对 SRID 3857（单位米）**可以用空间索引**：

```sql
-- 3857 米制平面，精度在局部范围内足够
SELECT id, name FROM shop_3857
WHERE ST_DWithin(location, ST_GeomFromText('POINT(12957000 4825000)', 3857), 3000);
```

### 4.4 分页的坑

`LIMIT offset, n` 深分页在空间查询里同样糟糕。做法：
- 先按包围盒 + 距离取「上一页最后一个点的距离」作为游标；
- `ORDER BY distance` 时用 `WHERE distance > lastDistance` 续查，避免大 offset。

## 五、性能与常见坑

| 坑 | 现象 | 解决 |
| --- | --- | --- |
| SRID 混用 | `ERROR 3033` 不同 SRID 运算 | 建表声明 SRID，插入/查询统一带 SRID |
| WKT 经纬度写反 | 查到南半球或空结果 | 记住 **经度在前**（x=经度） |
| 用了 `ST_Distance_Sphere` 做过滤 | 全表扫描 | 先 `MBRContains` 粗筛，函数放精筛 |
| 列允许 NULL | 建 SPATIAL 索引失败/数据异常 | `NOT NULL` |
| 列类型是普通 DECIMAL | 无法建空间索引 | 改用 `POINT` 空间类型 |
| 用 `ST_Distance` 算距离 | 单位是「度」，结果离谱 | 用 `ST_Distance_Sphere` |
| R-Tree 写放大 | 高频写入性能差 | 空间索引表尽量「读多写少」，用批量导入 |
| 精度与存储 | 用 `FLOAT` 存经纬度丢精度 | `DECIMAL(10,7)` 或 `POINT`（内部 double） |

**坐标精度参考**：`DECIMAL(10,7)` ≈ 1.1cm 精度，足够；纬度范围 `[-90, 90]`、经度 `[-180, 180]`，注意 MySQL 8.0 会做范围校验。

## 六、横向对比：MySQL 空间索引 vs 其他方案

| 方案 | 原理 | 优点 | 缺点 | 适用 |
| --- | --- | --- | --- | --- |
| MySQL SPATIAL（R-Tree） | 二维 R 树 | 与业务数据同库同事务、无额外组件 | 写放大、功能有限、跨库查询难 | 中小规模、强一致 |
| **GeoHash + 普通 B+ 索引** | 二维→一维编码，前缀匹配 | 兼容老版本、可用字符串索引、实现简单 | 边界问题、精度随纬度变化、需多格查询 | 兼容性要求高、简单场景 |
| Redis GEO | ZSet + GeoHash | 内存级延迟、支持半径排序 | 不持久（需 AOF）、数据量受内存限制 | 高并发、可容忍弱一致 |
| Elasticsearch geo | Lucene 空间索引（BKD/quadtree） | 支持复杂聚合、量级大、geo_shape | 需维护 ES、近实时 | 大规模、复杂地理分析 |
| 专业 GIS（PostGIS） | GiST R 树 | 功能最全（投影、拓扑、栅格） | 学习成本、独立数据库 | 专业地理计算 |

**GeoHash 的边界问题**（面试常考）：相邻两点可能被分到不同格子，导致漏查。解法是查询时同时搜索中心格及其**8 个邻格**——这正是 Redis GEO 内部的做法。

## 七、面试追问合集

**Q1：MySQL 空间索引为什么用 R-Tree 不用 B+ 树？**
B+ 树要求一维全序，而二维空间没有保序的单值映射（任何降维都会破坏部分邻近关系）；R-Tree 用 MBR 组织空间对象，能按「相交」剪枝，适合范围与邻近查询。

**Q2：为什么 `ST_Distance_Sphere < 3000` 用不上索引？**
它是函数计算，索引必须作用在**列本身**上。只有 `MBRContains`、`MBRWithin`、`ST_DWithin` 等「索引感知」函数才能在 R-Tree 上做范围剪枝。

**Q3：MBR 粗筛会不会漏数据？**
不会漏，只会多。MBR 是几何的外接矩形，任何与几何相交的查询区域都必然与 MBR 相交（超集），所以粗筛是**安全的上界**，之后再精筛即可。

**Q4：SRID 到底影响什么？**
影响两件事：一是**计算的单位与语义**（4326 是度，3857 是米，直接影响距离结果）；二是**校验与兼容**（8.0 强制同 SRID 运算）。生产建议：存储用 4326（标准经纬度），需要米制距离时用 `ST_Distance_Sphere` 或转 3857 用 `ST_DWithin`。

**Q5：GeoHash 和空间索引能叠加用吗？**
能。可以在 `geohash` 列（`VARCHAR(12)`）上建普通 B+ 索引做粗筛（前缀 LIKE 'wx4g%'），再 `MBRContains` 精筛。也可直接用 MySQL 8.0 的 `ST_Geohash` 生成。但只用 GeoHash 会有边界漏查，务必 9 格查询。

**Q6：空间索引在分库分表后怎么办？**
R-Tree 无法跨分片。常见做法：按城市/区域分片（查询天然带区域维度），或把地理检索下沉到 ES/Redis GEO，MySQL 只存业务明细。这也解释了为什么大厂「附近」功能往往不在 MySQL 里做。

## 八、总结

- 空间查询的核心是**用空间类型 + SPATIAL 索引（R-Tree）**把「函数过滤」变成「索引范围扫描」。
- 标准套路：**`MBRContains` 包围盒粗筛（走 R-Tree）→ `ST_Distance_Sphere` 精筛排序**。
- 牢记三大坑：**经纬度顺序（经在前）**、**SRID 必须统一**、**只有 MBR/ST_DWithin 能用索引**。
- 8.0.30+ 的 `ST_DWithin` + SRID 3857 是更优雅的写法；深分页用游标法。
- 数据规模再大，就把地理检索交给 Redis GEO / Elasticsearch，MySQL 退回业务存储。

下一篇继续 MySQL 的「偏门但高频」话题：**MySQL 8.0 的不可见索引（Invisible Index）与索引跳跃扫描**在生产变更中的实战用法。
