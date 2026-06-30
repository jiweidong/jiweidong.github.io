---
title: 【Redis进阶】Redis 高级数据结构实战：Geo、HyperLogLog、BloomFilter 与 Bitmaps 原理与最佳实践
date: 2026-06-30 08:10:00
tags:
  - Redis
  - 数据结构
  - 高性能
categories:
  - Redis
  - 中间件
author: 东哥
---

# 【Redis进阶】Redis 高级数据结构实战：Geo、HyperLogLog、BloomFilter 与 Bitmaps 原理与最佳实践

## 前言

大多数 Java 开发者对 Redis 的认知停留在 String、Hash、List、Set、Sorted Set 这五种基础数据结构上。然而 Redis 还提供了 **Geo（地理位置）、HyperLogLog（基数统计）、Bitmaps（位图）** 等高级数据结构，以及通过 Module 加载的 **BloomFilter（布隆过滤器）**，它们在特定场景下能发挥巨大威力。

本文将从原理、Redis 命令、Java 实战、性能对比四个维度深度剖析这些"隐藏神器"。

---

## 一、Redis Geo：地理空间索引

### 1.1 应用场景

- 附近的人 / 附近的商家
- 网约车距离匹配
- 外卖配送范围判断

### 1.2 原理：GeoHash 算法

Redis Geo 底层使用 **GeoHash** 算法实现：

1. 将经纬度二维坐标通过**二分法编码**为一维字符串
2. 字符串前缀匹配越多，表示两个点距离越近
3. 底层使用 **Sorted Set（zset）** 存储，GeoHash 值作为 score

```
北京天安门（116.397, 39.908）
     ↓ GeoHash 编码
"wx4g0f6k3v0"（base32 表示）
     ↓ 作为 zset 的 member
天安门的 score ≈ 4069874023442668
```

GeoHash 的特点是**递归分区**：

| 编码长度 | 网格大小（约） |
|---------|--------------|
| 1位 | 5000km × 5000km |
| 2位 | 1250km × 1250km |
| 3位 | 156km × 156km |
| 4位 | 39km × 19.5km |
| 5位 | 4.9km × 4.9km |
| 6位 | 1.2km × 609m |
| 7位 | 152m × 152m |
| 8位 | 38m × 19m |

### 1.3 Redis 命令实战

```bash
# 添加地理位置
GEOADD locations 116.397 39.908 "天安门" 121.473 31.230 "外滩"

# 计算两个地点距离（单位：m/km/mi/ft）
GEODIST locations "天安门" "外滩" km  # 结果：1067.5998km

# 查询某个位置的经纬度
GEOPOS locations "天安门"

# 查询附近的商家（半径10km内的POI）
GEORADIUS locations 116.40 39.90 10 km WITHDIST WITHCOORD COUNT 10

# 查询某个位置附近的POI
GEORADIUSBYMEMBER locations "天安门" 5 km WITHDIST

# GeoHash 编码（返回11位字符串）
GEOHASH locations "天安门"
```

### 1.4 Spring Boot + Redis Geo 实战

```java
@Service
public class NearbyService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    private static final String GEO_KEY = "shop:locations";
    
    // 批量添加商铺位置
    public void addShops(List<Shop> shops) {
        Map<String, Point> locationMap = shops.stream()
            .collect(Collectors.toMap(Shop::getId, 
                s -> new Point(s.getLongitude(), s.getLatitude())));
        redisTemplate.opsForGeo().add(GEO_KEY, locationMap);
    }
    
    // 搜索附近商铺（带距离排序）
    public List<NearbyShopVO> findNearby(double lng, double lat, double radiusKm) {
        Circle circle = new Circle(new Point(lng, lat), 
                                   new Distance(radiusKm, RedisGeoCommands.DistanceUnit.KILOMETERS));
        
        GeoResults<RedisGeoCommands.GeoLocation<String>> results = 
            redisTemplate.opsForGeo().radius(GEO_KEY, circle, 
                RedisGeoCommands.GeoRadiusCommandArgs.newGeoRadiusArgs()
                    .includeDistance()
                    .includeCoordinates()
                    .sortAscending()
                    .limit(20));
        
        return results.getContent().stream().map(result -> {
            RedisGeoCommands.GeoLocation<String> loc = result.getContent();
            return NearbyShopVO.builder()
                .shopId(loc.getName())
                .distance(result.getDistance().getValue())
                .lng(loc.getPoint().getX())
                .lat(loc.getPoint().getY())
                .build();
        }).collect(Collectors.toList());
    }
}
```

> 内部实际上是操作 Sorted Set，可以用 `ZREM` 删除某个店铺，用 `ZRANGE` 遍历所有店铺。

---

## 二、HyperLogLog：海量数据 UV 统计

### 2.1 场景与痛点

统计一个页面的**独立访客（UV）**，如果用 Set 存储每个用户 ID：

```
PV 场景 → 每天 1000万 访问，Set 会膨胀到几 GB
```

而 HyperLogLog 的**优势**：

| 方案 | 内存占用 | 误差 | 存储规模 |
|------|---------|------|---------|
| Set 去重 | 大（≈ 用户数 × ID大小） | 0 | 几 GB/天 |
| Bitmaps | 中等（≈ 用户ID范围/8） | 0 | ID连续时可用 |
| **HyperLogLog** | **≈ 12KB** | **≈ 0.81%** | **千万到亿级别** |

### 2.2 原理：概率算法

HyperLogLog 基于**伯努利试验**和**极大似然估计**：

```
核心思想：每个元素通过哈希函数得到一串二进制位
→ 记录这串二进制位最前面连续0的个数（k）
→ 用所有元素中最大的 k 值估算基数

优化：16384个桶取平均，将误差控制在 0.81%
```

### 2.3 Redis 命令实战

```bash
# 添加元素
PFADD uv:page:home "user_10001" "user_10002" "user_10001"

# 查询基数（去重后的数量）
PFCOUNT uv:page:home  # 结果：2

# 合并多个 HyperLogLog
PFMERGE uv:page:all uv:page:home uv:page:detail uv:page:cart
PFCOUNT uv:page:all
```

### 2.4 Java 实战

```java
@Service
public class UVService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    private static final String UV_KEY_PREFIX = "uv:page:";
    
    // 记录用户访问
    public void recordVisit(String pageId, String userId) {
        String key = UV_KEY_PREFIX + pageId + ":" + 
                     LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMMdd"));
        redisTemplate.opsForHyperLogLog().add(key, userId);
    }
    
    // 获取当天UV
    public long getDailyUV(String pageId) {
        String key = UV_KEY_PREFIX + pageId + ":" + 
                     LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMMdd"));
        return redisTemplate.opsForHyperLogLog().size(key);
    }
    
    // 获取月度UV（合并所有天的数据）
    public long getMonthlyUV(String pageId, YearMonth month) {
        String pattern = UV_KEY_PREFIX + pageId + ":" + 
                         month.format(DateTimeFormatter.ofPattern("yyyyMM")) + "*";
        Set<String> keys = redisTemplate.keys(pattern);
        if (keys == null || keys.isEmpty()) return 0;
        
        String destKey = "uv:monthly:" + pageId + ":" + month;
        Long result = redisTemplate.opsForHyperLogLog().union(destKey, keys.toArray(new String[0]));
        return result != null ? result : 0;
    }
}
```

> ⚠️ **注意**：HyperLogLog 适合**不要求精确统计**的场景（如 UV、搜索词近似统计）。如果要求精确去重，请使用 Set 或 Bitmaps。

---

## 三、BloomFilter：千万级数据快速判存在

### 3.1 应用场景

- **缓存穿透防护**：BloomFilter 存储所有存在的主键，查询前先判断
- **防止重复爬取**：爬虫判断 URL 是否已抓取
- **邮箱/用户名查重**：注册时快速判断用户名是否已存在
- **推荐系统去重**：已推荐的内容不再展示

### 3.2 原理

BloomFilter 的核心是一个**位数组** + **多个哈希函数**：

```
添加元素 "user_10001"：
  hash1("user_10001") % m → 位1 置为 1
  hash2("user_10001") % m → 位2 置为 1
  hash3("user_10001") % m → 位3 置为 1

查询元素 "user_10002"：
  计算三个哈希位置 → 检查是否都为 1
  - 有一个为 0 → 一定不存在
  - 全部为 1 → 可能存在（有可能误判）
```

**特点**：

| 特性 | 说明 |
|------|------|
| 空间效率 | 极低内存消耗，1亿条数据约 120MB |
| 查询效率 | O(k)，k 为哈希函数个数 |
| 误判率 | 可配置，通常控制在 0.01%~1% |
| 无法删除 | 标准的 BloomFilter 不支持删除 |

### 3.3 使用 Redis Module（Redisson 实现）

Redis 原生不支持 BloomFilter，但可以通过 **Redisson** 客户端使用：

```java
<dependency>
    <groupId>org.redisson</groupId>
    <artifactId>redisson-spring-boot-starter</artifactId>
    <version>3.27.0</version>
</dependency>
```

```java
@Service
public class IdFilterService {
    
    private final RBloomFilter<String> bloomFilter;
    
    public IdFilterService(RedissonClient redissonClient) {
        // expectedInsertions：期望插入量，falseProbability：误判率
        this.bloomFilter = redissonClient.getBloomFilter("id:bloom");
        this.bloomFilter.tryInit(10000000L, 0.01);  // 1000万数据，1%误判率
    }
    
    // 初始化加载所有已有 ID
    @PostConstruct
    public void init() {
        if (!bloomFilter.isExists()) {
            List<Long> allIds = idMapper.selectAllIds();
            allIds.forEach(id -> bloomFilter.add(String.valueOf(id)));
            log.info("布隆过滤器初始化完成，加载 {} 个 ID", allIds.size());
        }
    }
    
    // 判断ID是否可能存在
    public boolean mightContain(String id) {
        return bloomFilter.contains(id);
    }
}
```

### 3.4 缓存穿透防护实战

```java
@Service
public class UserService {
    
    @Autowired
    private RBloomFilter<String> bloomFilter;
    @Autowired
    private StringRedisTemplate redisTemplate;
    @Autowired
    private UserMapper userMapper;
    
    public User getUserById(Long id) {
        String key = "user:" + id;
        
        // 第一步：布隆过滤器拦截
        if (!bloomFilter.contains(String.valueOf(id))) {
            log.warn("请求不存在的用户ID: {}", id);
            return null;  // 直接返回，避免穿透到 DB
        }
        
        // 第二步：查缓存
        String json = redisTemplate.opsForValue().get(key);
        if (json != null) {
            return JSON.parseObject(json, User.class);
        }
        
        // 第三步：查数据库（布隆过滤器说了"可能存在"，才查 DB）
        User user = userMapper.selectById(id);
        if (user != null) {
            redisTemplate.opsForValue().set(key, JSON.toJSONString(user), 1, TimeUnit.HOURS);
        }
        return user;
    }
}
```

---

## 四、Bitmaps：超大规模状态标记

### 4.1 原理

Bitmaps 本质上是一个**字符串（byte array）**，用**位（bit）**来标记状态。每个位只有 0 或 1 两种状态，适合**存量大、状态简单**的场景。

**内存计算：**
```
10亿用户 = 1,000,000,000 bit = 125 MB
```

### 4.2 核心场景

| 场景 | 实现 |
|------|------|
| 每日签到 | 365位 = 46 字节/人/年 |
| 用户在线状态 | 1位/人 |
| 布隆过滤器替代方案 | 定长位数组 |
| 日活统计 | 1位/用户/天 |

### 4.3 Redis 命令

```bash
# 用户10001在第100天签到
SETBIT user:sign:2026:10001 99 1

# 查询用户10001第100天是否签到
GETBIT user:sign:2026:10001 99

# 统计用户10001全年签到天数
BITCOUNT user:sign:2026:10001

# 统计今天哪些用户签到了（位运算：多个用户做 OR）
# 注意：BITOP 在大数据量下耗时较长，建议在从节点执行
```

### 4.4 Java 签到系统实战

```java
@Service
public class SignInService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    private static final long DAYS_OF_YEAR = 366L;
    
    // 用户签到
    public boolean signIn(Long userId, LocalDate date) {
        String key = buildSignKey(userId, date.getYear());
        int offset = date.getDayOfYear() - 1;  // 第0位对应1月1日
        return Boolean.TRUE.equals(
            redisTemplate.opsForValue()
                .setBit(key, offset, true));
    }
    
    // 查询用户某天是否签到
    public boolean isSignedIn(Long userId, LocalDate date) {
        String key = buildSignKey(userId, date.getYear());
        int offset = date.getDayOfYear() - 1;
        return Boolean.TRUE.equals(
            redisTemplate.opsForValue().getBit(key, offset));
    }
    
    // 统计用户当月签到天数
    public long monthSignCount(Long userId, YearMonth month) {
        String key = buildSignKey(userId, month.getYear());
        LocalDate firstDay = month.atDay(1);
        LocalDate lastDay = month.atEndOfMonth();
        
        int startOffset = firstDay.getDayOfYear() - 1;
        int endOffset = lastDay.getDayOfYear() - 1;
        int len = endOffset - startOffset + 1;
        
        // BITFIELD 对指定位范围计数
        List<Long> result = redisTemplate.opsForValue()
            .bitField(key, BitFieldSubCommands.create()
                .get(BitFieldSubCommands.BitFieldType.unsigned(len))
                .valueAt(startOffset));
        
        return result.isEmpty() ? 0 : Long.bitCount(result.get(0));
    }
    
    private String buildSignKey(Long userId, int year) {
        return "sign:" + userId + ":" + year;
    }
}
```

---

## 五、性能对比与选型指南

### 5.1 数据结构对比总结

| 数据结构 | 内存消耗 | 精度 | 写入速度 | 读取速度 | 适用场景 |
|---------|---------|------|---------|---------|---------|
| Geo | 中 | 精确（米级） | 中 | 中 | 位置服务 |
| HyperLogLog | 极低（12KB） | 约 0.81% 误差 | 极快 | 极快 | UV统计、去重估算 |
| BloomFilter | 极低（可配置） | 有误判率 | 快 | 快 | 快速判存在、防缓存穿透 |
| Bitmaps | 极低（1位/元素） | 精确 | 极快 | 极快 | 签到、状态标记 |

### 5.2 选型决策树

```
需要精确判断一个值是否存在？
├─ 是 → 数据量小 → Set
├─ 是 → 数据量大/连续 → Bitmaps
└─ 否 → 允许一定误差 → BloomFilter

需要统计唯一值？
├─ 要求精确 → Set（小规模）或 Bitmaps（ID连续）
└─ 允许误差（UV）→ HyperLogLog

需要搜索附近的点？
└─ 用 Geo（依赖 Sorted Set 实现）
```

---

## 六、总结

Redis 的这四种高级数据结构各有所长：

1. **Geo**：基于 GeoHash + Sorted Set，是"附近的人"功能的标准答案
2. **HyperLogLog**：12KB 内存即可统计亿级 UV，误差稳定在 0.81%
3. **BloomFilter**：空间高效的判存在工具，防缓存穿透的首选方案
4. **Bitmaps**：位级别操作，适合签到、状态标记等大规模二值统计

> 掌握这些数据结构的原理和使用场景，能帮你用更低的内存成本解决更复杂的业务问题。面试中能深入讲清楚 GeoHash 编码和 HyperLogLog 的基数估计原理，会让面试官眼前一亮。
