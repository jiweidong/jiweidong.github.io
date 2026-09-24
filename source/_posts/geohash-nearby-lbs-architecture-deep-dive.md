---
title: 【实战】GeoHash 与「附近的人」深度解析：原理、边界问题与 Redis GEO 架构
date: 2026-09-24 08:30:00
tags:
  - 系统设计
  - Redis
  - 地理位置
categories:
  - 系统设计
  - 高并发
author: 东哥
---

# 【实战】GeoHash 与「附近的人」深度解析：原理、边界问题与 Redis GEO 架构

## 面试官：微信「附近的人」怎么实现？

这道题看似是产品题，实际考的是**空间索引**。面试官期待的追问链是这样的：

1. 经纬度是两个 double，怎么建索引？（单列索引没用）
2. 查"附近 5 公里"要不要全表扫？（显然不能）
3. 网格边界上的点漏了怎么办？（这是最能拉开差距的一问）
4. 千万级在线用户，单机存得下吗？怎么分片？

能把这条链走完，说明你不只是"用过 Redis 的 GEORADIUS"，而是真正理解了空间索引的本质。今天我们从算法一路推到架构。

## 一、为什么不能直接用经纬度算距离？

最朴素的方案：遍历所有用户，用 Haversine 公式算距离，过滤出 5 公里内的。

```java
private static final double EARTH_RADIUS = 6371000;   // 米

public static double haversine(double lat1, double lon1, double lat2, double lon2) {
    double dLat = Math.toRadians(lat2 - lat1);
    double dLon = Math.toRadians(lon2 - lon1);
    double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
             + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
             * Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return 2 * EARTH_RADIUS * Math.asin(Math.sqrt(a));
}
```

复杂度 O(N)，1000 万用户一次查询就是 1000 万次三角函数运算，**单次查询几百毫秒起步**，根本扛不住。

问题在于：**经纬度是二维坐标，而 B+ 树/哈希索引是一维的**。你给 `longitude` 建索引，MySQL 只能按经度范围筛，纬度条件退化成"回表后过滤"，扫描行数依然巨大。

所以核心诉求是：**把二维坐标降维成一维，让一维索引能用上。**

## 二、GeoHash：把二维坐标压成一维字符串

GeoHash 的思想非常优雅：**交替对经度和纬度做二分，把落在左半边记 0、右半边记 1，得到的二进制串再按 base32 编码成字符串。**

编码过程（以北京天安门 116.397, 39.909 为例）：

```
经纬度范围：经度 [-180, 180]，纬度 [-90, 90]

第 1 bit（经度）: 116.397 > 0     → 1    经度区间变为 [0, 180]
第 2 bit（纬度）: 39.909 > 0      → 1    纬度区间变为 [0, 90]
第 3 bit（经度）: 116.397 > 90    → 1    经度区间变为 [90, 180]
第 4 bit（纬度）: 39.909 < 45     → 0    纬度区间变为 [0, 45]
第 5 bit（经度）: 116.397 < 135   → 0    经度区间变为 [90, 135]
...
（交替进行，直到达到目标精度）

最终二进制串按每 5 bit 一组映射到 base32 字母表：
0123456789bcdefghjkmnpqrstuvwxyz
（注意：没有 a、i、l、o，避免和数字 1、0 混淆）
```

就是这么简单，但有几个必须掌握的推论：

**推论 1：字符串前缀相同 = 空间位置相近。**

这是 GeoHash 最有用的性质。前缀越长，共享的格子越小，两个点越近。所以"查询附近"变成了**前缀匹配查询**，可以用 B+ 树的 `LIKE 'prefix%'` 或者有序集合的范围扫描！二维查询降维成了一次范围扫描。

**推论 2：精度由前缀长度决定。**

| GeoHash 长度 | 单元格大小（约） | 常见用途 |
| --- | --- | --- |
| 1 | 5000km × 5000km | 洲际 |
| 2 | 1250km × 625km | 国家 |
| 3 | 156km × 156km | 省级 |
| 4 | 39km × 19.5km | 城市 |
| 5 | 4.9km × 4.9km | 城区（"附近的人"常用） |
| 6 | 1.2km × 0.61km | 街道 |
| 7 | 153m × 153m | 楼栋 |
| 8 | 38m × 19m | 门口 |
| 9 | 4.8m × 4.8m | 精确定位 |

**推论 3：这是"有损降维"，边界处会出错。**

这就是那道关键追问——

## 三、边界问题：为什么必须查"九宫格"

考虑一个经典场景：你在格子 A 的最右边缘，目标点在格子 B 的最左边缘，两者实际只差 10 米，但 **GeoHash 前缀完全不同**。

```
┌─────────┬─────────┐
│    A    │    B    │
│        ●│●        │   ● 与 ● 相距 10 米
│         │         │   但 GeoHash 前缀完全不同
└─────────┴─────────┘
```

如果只按 `prefix = A` 查询，就会漏掉 B 里的点。解决方案是**取当前格子 + 周围 8 个邻居格子，一共 9 个格子一起查**（九宫格）。

用 Redis 的 `GEOSEARCH` 底层也是这样处理的——它内部会计算一个覆盖圆形区域所需的所有 GeoHash 块。

**另一个坑是"赤道/极地附近的格子变形"**。经度 1 度对应的实际距离随纬度变化：赤道约 111km，纬度 60° 处只有约 55.5km。所以用固定长度的 GeoHash 前缀做距离过滤时，**高纬度地区的误差会放大**。工程上通常的做法是：

1. 先用 GeoHash 粗筛（拿到候选集）；
2. 再用 Haversine 精确算距离做二次过滤和排序。

**粗筛 + 精筛**这个模式，是所有地理检索系统的标准做法。

## 四、Redis GEO：本质是 ZSet + GeoHash

Redis 从 3.2 开始提供 GEO 命令，底层实现特别巧妙——**它把 GeoHash 编码后的 52 位整数当作 ZSet 的 score**，用一个 `zset` 存储。

```bash
# 添加地理位置（经纬度 + 成员名）
GEOADD drivers 116.397128 39.916527 "driver:1001"
GEOADD drivers 116.407128 39.916527 "driver:1002"

# 查询：以某点为中心 5 公里内的成员（带距离）
GEOSEARCH drivers FROMLONLAT 116.40 39.91 BYRADIUS 5 km ASC WITHDIST COUNT 10

# 老的写法（Redis 6.2 之前）
GEORADIUS drivers 116.40 39.91 5 km WITHDIST ASC
```

底层数据结构：

```
ZSet
  score  = GeoHash 的 52 位整数（不是字符串！）
  member = "driver:1001"
```

**为什么是 52 位而不是完整的 base32 字符串？**

Redis 把经纬度分别按 26 位交替编码，得到 52 位整数，范围正好落在 double 能**精确表示**的整数区间内（2^52 < 2^53，double 的尾数有 52 位 + 隐含 1 位）。这样 score 存 double 不会有精度损失，同时这个 52 位整数**保持了空间邻近性**（相邻的 GeoHash 块在数值上也接近），可以被 ZSet 的跳表高效范围查询。

查询流程（简化）：

```
1. 计算中心点的 GeoHash（52 位精度 26 级）
2. 根据半径和精度，算出需要覆盖的 9 个（或更多）GeoHash 区间的 score 范围
3. 对每个区间在 ZSet 上做 ZRANGEBYSCORE（跳表范围扫描）
4. 归并结果，用 Haversine 精确计算距离过滤，按距离排序
```

关键结论：**Redis GEO 的快，不是因为"存得聪明"，而是因为复用了 ZSet 跳表的范围查询能力**。这也是为什么 GEO 的成员数受限于单机内存（ZSet 本身是内存结构）。

## 五、Java 实现：GeoHash 编码 + 距离计算

不完全依赖 Redis 时，也可以自己在 Java 里实现 GeoHash（比如做分库分表的路由键）。

```java
public final class GeoHashKit {
    private static final char[] BASE32 =
            "0123456789bcdefghjkmnpqrstuvwxyz".toCharArray();
    // 经纬度各用 26 位，共 52 位
    private static final int[] BITS = {16, 8, 4, 2, 1};

    /** 将经纬度编码为 GeoHash 字符串，precision 为字符数（1~12） */
    public static String encode(double lat, double lon, int precision) {
        double[] latRange = {-90.0, 90.0};
        double[] lonRange = {-180.0, 180.0};
        StringBuilder sb = new StringBuilder();
        boolean even = true;   // 偶数位编码经度，奇数位编码纬度
        int bit = 0, ch = 0;

        while (sb.length() < precision) {
            double[] range = even ? lonRange : latRange;
            double v = even ? lon : lat;
            double mid = (range[0] + range[1]) / 2;

            if (v >= mid) {
                ch |= BITS[bit];
                range[0] = mid;
            } else {
                range[1] = mid;
            }

            even = !even;
            if (bit < 4) {
                bit++;
            } else {
                sb.append(BASE32[ch]);
                bit = 0;
                ch = 0;
            }
        }
        return sb.toString();
    }
}
```

计算某格子的相邻格子（九宫格的核心）：对二进制串做"加一/减一"再解码，得到相邻格子的中心点。

```java
/** 求某 GeoHash 的 8 个邻居（简化版：用解码后的中心点做偏移） */
public static List<String> neighbors(double lat, double lon, int precision) {
    double cellWidth = 360.0 / Math.pow(2, Math.ceil(precision * 5 / 2.0));   // 精度对应的经度跨度
    double cellHeight = 180.0 / Math.pow(2, Math.floor(precision * 5 / 2.0));
    List<String> result = new ArrayList<>(8);
    for (int dLat = -1; dLat <= 1; dLat++) {
        for (int dLon = -1; dLon <= 1; dLon++) {
            if (dLat == 0 && dLon == 0) continue;
            double nLat = lat + dLat * cellHeight;
            double nLon = lon + dLon * cellWidth;
            if (nLat > 90 || nLat < -90) continue;                 // 跨极点丢弃
            if (nLon > 180) nLon -= 360;
            if (nLon < -180) nLon += 360;
            result.add(encode(nLat, nLon, precision));
        }
    }
    return result;
}
```

**注意精度和半径的匹配**：查 5km 半径，用 4 位（39km 格子）覆盖足够但候选集偏大（要算更多 Haversine）；用 6 位（1.2km）候选集小但需要查询 9 个格子甚至更多层。经验做法是**取比半径略大的格子边长**，用九宫格覆盖。

## 六、千万级用户的架构设计

Redis GEO 单机能存多少？假设一条记录（member + score）约 80 字节，1000 万条约 800MB，一台 16GB 的 Redis 能扛住，但**热点和不均匀分布**会出问题（比如所有骑手都挤在一个商业区）。

### 方案一：Redis Cluster + 按 GEO 分区

把用户按城市/地理区域分到不同 Redis 实例，查询时先定位区域再查询。问题是跨区域的"边界用户"需要查多个实例。

### 方案二：自建"网格索引 + 倒排"（大厂常用）

```
1. 把地球切成一二级网格（如 S2 / 四叉树 / GeoHash 5 位格）
2. 维护 网格ID -> 用户集合 的映射（Redis Set 或本地缓存）
3. 查询：取中心格子 + 8 邻格 → 拿到候选用户 ID 集合 → 读用户位置 → Haversine 精筛
4. 位置更新：只更新网格映射（O(1)），不需要全量重算
```

这个方案的好处是**更新极其廉价**（用户移动只改一个 Set 的成员），缺点是要自己维护网格和用户位置的二级存储。

### 方案三：分层 + 冷热分离

- **热数据**（活跃骑手、在店商家）：放 Redis GEO，毫秒级；
- **温数据**（离线用户、历史位置）：放 Elasticsearch 的 `geo_point` 或 PostGIS，支持复杂空间查询；
- **冷数据**：落 HBase/对象存储，只做离线分析。

### 工程细节清单

| 问题 | 方案 |
| --- | --- |
| 位置更新频繁（每 3~5 秒上报） | 合并写入（本地聚合 + 批量 GEOADD），或降频 |
| 查询半径大（如 50km） | 退化成 ES/离线索引，或分层返回 |
| 网格边界漏点 | 九宫格（或更大范围） |
| 返回结果要过滤（在线、接单中） | 位图/布隆过滤器预筛，或把状态打进 member 命名 |
| 排序要综合距离和评分 | 先取 TOP N（按距离），再在应用层重排 |
| 高并发 | Redis 读写分离 + 本地缓存 + 限流 |

## 七、面试常见追问

**Q1：为什么 GeoHash 用 52 位而不是 64 位？**

因为 Redis 用 ZSet 的 score（double）存，double 只有 53 位有效精度（1 位符号 + 52 位尾数）。用 52 位可以保证整数精确存储，同时在 0.6m 左右的分辨率已经远超 GPS 精度需求。再多位不仅无意义，还会破坏存储的精确性。

**Q2：GeoHash 和四叉树/S2/Google H3 的区别？**

| 方案 | 特点 | 适用 |
| --- | --- | --- |
| GeoHash | 实现最简单，字符串前缀可索引，**格子有变形**（面积不等） | 通用 LBS、Redis GEO |
| 四叉树 | 自适应细分（密处更细） | 内存索引、碰撞检测 |
| Google S2 | 基于球面，格子面积近似相等，支持层级和区域覆盖 | 大厂 LBS、地图 |
| Uber H3 | 六边形网格，邻接关系均匀（6 邻居），距离误差小 | 网格聚合、派单 |

如果面试官问"为什么 Uber 用六边形"，答案是：**六边形每个格子只有 6 个等距邻居，而方形网格有 4 等距 + 4 对角（距离更远）**，做区域聚合和邻域查询时误差更小、扩展更均匀。

**Q3：Haversine 和 Vincenty 公式怎么选？**

Haversine 把地球当正球体，误差约 0.3%，计算快，**够用于"附近的人"这种场景**。Vincenty 考虑椭球体（WGS-84），精度高但迭代计算慢，适合测绘级应用。工程上绝大多数场景用 Haversine 就够，还可以用等距圆柱投影做近似加速。

**Q4：为什么查询要先粗筛再精筛？**

粗筛（GeoHash/网格）把候选集从千万级降到几十个，但**有边界误差和格子变形误差**，可能包含超出半径的点。精筛（Haversine）保证结果准确并按距离排序。两级过滤把"高复杂度运算"限制在极小集合上，这是空间检索的通用优化范式。

## 八、总结

核心链路一张图：

```
需求：附近 5 公里的人
  ↓
痛点：二维坐标无法用一维索引，全表扫描 O(N)
  ↓
方案：GeoHash 降维（交替二分 + base32）→ 前缀相同即空间相近
  ↓
坑 1：格子边界漏点 → 九宫格（中心 + 8 邻居）
  ↓
坑 2：格子变形（高纬度）+ 粗筛误差 → Haversine 精筛
  ↓
Redis GEO：52 位 GeoHash 整数做 ZSet score → 复用跳表范围查询
  ↓
规模化：Redis Cluster / 网格倒排索引 / 冷热分层 + 高频更新合并
```

记住三个数字和一个套路：

- **52 位**（Redis GEO 的编码长度，受 double 精度约束）；
- **九宫格**（解决边界漏点的最小代价方案）；
- **粗筛 → 精筛**（空间检索永远的两级过滤）。

「附近的人」看着简单，实则把**降维、索引、边界处理、分层架构**四件事串在一起。能把边界问题答清楚，这道题就赢了。
