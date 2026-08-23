---
title: 【Redis 实战】布隆过滤器原理与实战：从数学推导到海量数据过滤
date: 2026-08-23 08:00:00
tags:
  - Redis
  - 布隆过滤器
  - 缓存
  - 大数据
  - 实战
categories:
  - Redis
  - 中间件实战
author: 东哥
---

# 【Redis 实战】布隆过滤器原理与实战：从数学推导到海量数据过滤

## 面试官：缓存穿透怎么解决？说说布隆过滤器的原理？

> 缓存穿透是 Redis 面试的必考题，布隆过滤器是标准答案之一。但大多数同学只记住了"用布隆过滤器挡一下不存在的 key"，被追问**误判率怎么来的、bit 数组多大合适、为什么不能删除元素**就答不上来了。本文从数学原理到代码实战，把布隆过滤器一次讲透。

## 一、从缓存穿透说起

### 1.1 什么是缓存穿透

查询一个**缓存和数据库都不存在**的数据（比如 id = -1 的用户），请求会穿透缓存打到数据库：

```
请求 → Redis 缓存（miss）→ MySQL（查不到）→ 返回 null
```

恶意攻击者构造大量不存在的 id，数据库压力瞬间打满。**缓存穿透**是三大缓存问题（穿透、击穿、雪崩）里唯一"防不胜防"的——因为缓存永远 miss。

### 1.2 常见解决方案对比

| 方案 | 原理 | 缺点 |
|---|---|---|
| 缓存空值 | 查不到也缓存 null（短 TTL） | 占内存，无法区分"刚写入"和"真不存在" |
| 参数校验 | 拦截非法 id（如负数、超长） | 只能挡明显非法请求 |
| **布隆过滤器** | 预判"可能存在/肯定不存在" | **有误判率**（会把不存在的误判为存在） |
| 数据库兜底限流 | 数据库层限流/熔断 | 治标不治本 |

布隆过滤器的定位：**用极小的内存代价（每个元素 1-2 个字节），把"肯定不存在"的请求挡在数据库之前**。

## 二、布隆过滤器原理

### 2.1 核心思想

布隆过滤器（Bloom Filter）是一个 **bit 数组（位图）+ 多个哈希函数** 的数据结构：

1. **插入元素**：对元素计算 k 个哈希值，把 bit 数组对应位置**置为 1**；
2. **查询元素**：计算 k 个哈希值，检查对应位置**是否全为 1**：
   - 只要有一个位置是 0 → **肯定不存在**（一定正确）；
   - 全部为 1 → **可能存在**（可能误判）。

```
bit 数组（m=16 bit），插入 "abc" 和 "def"，k=3 个哈希函数：

插入 "abc"：h1=1, h2=5, h3=9   →  位 1,5,9 置 1
插入 "def"：h1=3, h2=5, h3=12  →  位 3,5,12 置 1

最终 bit 数组：
索引: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
值:   0 1 0 1 0 1 0 0 0 1 0  0  1  0  0  0

查询 "xyz"：h1=2, h2=5, h3=8 → 位 2=0 → 肯定不存在 ✅
查询 "ghi"：h1=1, h2=5, h3=12 → 全为 1 → 可能存在（可能误判）⚠️
```

### 2.2 误判（False Positive）怎么产生？

两个不同元素可能共享某些哈希位置。当查询一个**从未插入**的元素 x 时，x 的 k 个哈希位置恰好都被其他元素"占满"了 1，就会误判为"存在"。**误判只可能把"不存在"判成"存在"，绝不可能把"存在"判成"不存在"**——这是布隆过滤器最核心的性质。

### 2.3 数学推导：误判率公式

设 bit 数组大小 m，元素个数 n，哈希函数个数 k。

插入 n 个元素后，某一位仍为 0 的概率：

$$P(0) = \left(1 - \frac{1}{m}\right)^{kn} \approx e^{-kn/m}$$

查询一个不存在元素时，k 个位置全为 1（误判）的概率：

$$P_{fp} = \left(1 - e^{-kn/m}\right)^k$$

**最优哈希函数个数**（对 m、n 求导取极值）：

$$k_{opt} = \frac{m}{n} \ln 2 \approx 0.693 \times \frac{m}{n}$$

**给定误判率 p 时，bit 数组大小的经验公式**：

$$m = -\frac{n \ln p}{(\ln 2)^2}$$

常见工程取值（可直接背）：

| 预期元素数 n | 期望误判率 p | bit 数组大小 m | 最优哈希数 k | 每元素内存 |
|---|---|---|---|---|
| 100 万 | 1% | 约 9.6 Mbit ≈ 1.2 MB | 7 | 1.2 字节 |
| 100 万 | 0.1% | 约 14.4 Mbit ≈ 1.8 MB | 10 | 1.8 字节 |
| 1 亿 | 1% | 约 958 Mbit ≈ 114 MB | 7 | 1.2 字节 |
| 1 亿 | 0.01% | 约 1.9 Gbit ≈ 230 MB | 14 | 2.3 字节 |

**直观结论**：每个元素只需 **1-2 字节** 内存，就能把误判率压到 1% 以下——这是哈希表（每个元素几十字节起步）完全无法比拟的。

### 2.4 为什么布隆过滤器不能删除元素？

删除元素需要把对应 k 个位置**置 0**，但这些位置可能被**其他元素共享**，置 0 会导致其他元素被误判为"不存在"（假阴性），破坏布隆过滤器的正确性。解决方案：

- **Counting Bloom Filter（计数布隆过滤器）**：每个位置用计数器替代 bit，删除时减一；代价是内存扩大 3-4 倍；
- **布谷鸟过滤器（Cuckoo Filter）**：支持删除，用两个哈希桶 + 踢出重定位，内存效率与布隆相当；
- 业务上更常见的做法：**到期整体重建**（全量数据重新构建过滤器）。

## 三、代码实战

### 3.1 Guava 实现（单机场景）

```xml
<dependency>
    <groupId>com.google.guava</groupId>
    <artifactId>guava</artifactId>
    <version>33.2.1-jre</version>
</dependency>
```

```java
// 预期插入 100 万条数据，误判率 0.01
BloomFilter<String> filter = BloomFilter.create(
        Funnels.stringFunnel(StandardCharsets.UTF_8),
        1_000_000,
        0.01);

// 初始化：全量用户 id 灌入
userService.getAllUserIds().forEach(filter::put);

// 查询
long userId = 123456L;
if (filter.mightContain(String.valueOf(userId))) {
    // 可能存在 → 查缓存/数据库
    User user = cache.get(userId);
    if (user == null) {
        user = userService.getById(userId);  // 极少数误判请求会打到这里
    }
} else {
    // 肯定不存在 → 直接返回，不查数据库
    return null;
}
```

Guava 内部自动根据 `n` 和 `p` 计算最优 `m` 和 `k`，并把 `k` 个哈希函数通过**双哈希（double hashing）**组合实现，避免创建 k 个独立哈希函数的开销。

### 3.2 Redis 实现（分布式场景）

Redis 4.0+ 提供了 **Bloom Filter 模块**（`redisbloom`），或者用 Redisson 客户端封装：

```java
// Redisson 方式
RBloomFilter<String> filter = redisson.getBloomFilter("user:bloom");
filter.tryInit(1_000_000L, 0.01);   // 初始化：容量 + 误判率
filter.add("100001");
filter.contains("100001");  // true
filter.contains("999999");  // false（大概率）
```

Redis 原生命令（装了 redisbloom 模块）：

```bash
BF.RESERVE user:bloom 0.01 1000000   # key, error_rate, capacity
BF.ADD user:bloom 100001
BF.EXISTS user:bloom 100001   # (integer) 1
```

**注意**：Redis 版布隆过滤器底层用了**多层压缩**（每层误判率递减），实际内存比理论值略高，但容量和误判率参数与公式一致。

### 3.3 手写一个简易版（理解本质）

```java
public class SimpleBloomFilter {
    private final BitSet bits;
    private final int k;          // 哈希函数个数
    private final int m;          // bit 数组大小
    private final int seedBase = 31;

    public SimpleBloomFilter(int expectedSize, double fpp) {
        this.m = (int) (-expectedSize * Math.log(fpp) / (Math.log(2) * Math.log(2)));
        this.k = (int) Math.max(1, Math.round((double) m / expectedSize * Math.log(2)));
        this.bits = new BitSet(m);
    }

    private int[] hash(String value) {
        int[] idx = new int[k];
        int h1 = value.hashCode();
        int h2 = (h1 >>> 16) | (h1 << 16);  // 第二个种子
        for (int i = 0; i < k; i++) {
            idx[i] = Math.abs((h1 + i * h2) % m);  // 双哈希组合
        }
        return idx;
    }

    public void add(String value) {
        for (int i : hash(value)) bits.set(i);
    }

    public boolean mightContain(String value) {
        for (int i : hash(value)) {
            if (!bits.get(i)) return false;  // 有 0 → 肯定不存在
        }
        return true;  // 全 1 → 可能存在
    }
}
```

## 四、经典应用场景

| 场景 | 用法 | 收益 |
|---|---|---|
| **缓存穿透防护** | 预热时把全部合法 key 灌入过滤器，查询前先判存在性 | 挡住恶意/非法 key 的数据库压力 |
| **爬虫 URL 去重** | 已抓取的 URL 存入过滤器 | 亿级 URL 去重只需几百 MB 内存 |
| **垃圾邮件/内容过滤** | 黑名单单词、垃圾邮件特征指纹 | 快速粗筛 |
| **数据库查询前置过滤** | 大表查询前先判 id 是否存在 | 避免无效查询（如订单号校验） |
| **推荐系统** | 已推荐内容去重 | 内存占用远小于 Set |
| **HBase/LevelDB/LSM 存储** | SSTable 的 Bloom Filter 布隆块，减少磁盘 IO | 避免读不存在的块 |
| **CDN 缓存** | 判断 URL 是否值得回源 | 降低回源率 |

## 五、工程落地注意事项

1. **容量预估要保守**：`expectedSize` 按业务峰值的 1.5-2 倍设置，插入量超过预估容量后误判率会急剧上升（非线性恶化）；
2. **误判后的兜底**：布隆过滤器只能"拦截"，被放行的误判请求仍要查库——所以它要配合缓存空值或限流使用，形成纵深防御；
3. **数据变更同步**：新增数据要**实时** `add` 到过滤器（写链路里加一步），否则新数据会被误杀——这是落地时最容易踩的坑；
4. **删除/重建策略**：底层数据大范围变化时（如全量重建），用**双缓冲**（新旧两个过滤器，切换期间双写）平滑过渡；
5. **多实例一致性**：分布式部署时用 Redis 集中存储过滤器（`redisbloom`），避免每个实例一份导致的不一致；
6. **监控误判率**：统计"过滤器通过但数据库查不到"的比例，超过阈值预警，说明容量快满了。

### 实战：缓存穿透防护完整代码

```java
@Service
public class UserQueryService {
    @Autowired
    private RBloomFilter<String> userBloomFilter;   // 启动时初始化并预热
    @Autowired
    private StringRedisTemplate redisTemplate;
    @Autowired
    private UserMapper userMapper;

    public User getUser(Long userId) {
        String key = "user:" + userId;
        // 第一道防线：布隆过滤器（挡 99% 的不存在请求）
        if (!userBloomFilter.contains(String.valueOf(userId))) {
            return null;   // 肯定不存在，直接返回
        }
        // 第二道防线：Redis 缓存
        String json = redisTemplate.opsForValue().get(key);
        if (json != null) {
            return JSON.parseObject(json, User.class);
        }
        // 第三道防线：查库（只有真实存在 + 少量误判会到这里）
        User user = userMapper.selectById(userId);
        if (user != null) {
            redisTemplate.opsForValue().set(key, JSON.toJSONString(user), 30, TimeUnit.MINUTES);
        } else {
            // 兜底：缓存空值 + 短 TTL，防止过滤器误判导致反复打库
            redisTemplate.opsForValue().set(key, "", 60, TimeUnit.SECONDS);
        }
        return user;
    }
}
```

## 六、面试常见追问

**Q1：布隆过滤器能不能删除元素？**
不能直接删（位置被共享，置 0 会产生假阴性）。要支持删除用 Counting Bloom Filter 或布谷鸟过滤器，或整体重建。

**Q2：误判率可以做到 0 吗？**
不能。只有把 bit 数组设得无穷大（或等价地，元素个数为 0）才能无误差。工程上 0.1%-1% 已足够。

**Q3：哈希函数用几个？**
最优 $k = \frac{m}{n}\ln 2 \approx 0.693\frac{m}{n}$。太多浪费计算、增加置位冲突；太少误判率上升。

**Q4：Redis 的布隆过滤器和 Guava 的有什么区别？**
Redis 版是分布式的（多实例共享），底层多层压缩结构；Guava 版是单机内存的，启动快、无网络开销。数据量大且多实例部署用 Redis 版。

**Q5：布隆过滤器和 HyperLogLog 有什么区别？**
布隆过滤器判断**元素是否存在**；HyperLogLog 统计**基数（去重数量）**。两者都用位图思想但目的完全不同。

**Q6：为什么布隆过滤器说"可能存在"而不是"一定存在"？**
因为哈希碰撞 + 位共享，从未插入的元素可能撞上全 1 的位置组合。但反过来，"某位是 0 则元素一定不存在"是严格成立的。

## 七、总结

- **本质**：bit 数组 + k 个哈希函数，用 1-2 字节/元素 的代价换"肯定不存在"的判定能力；
- **两个核心性质**：不存在判断零失误（无假阴性）、存在判断有误判（有假阳性）；
- **三个关键参数**：容量 n、误判率 p、哈希数 k，由公式 $k = \frac{m}{n}\ln2$ 和 $m = -\frac{n\ln p}{(\ln2)^2}$ 确定；
- **两大落地姿势**：单机 Guava `BloomFilter`，分布式 Redis `redisbloom`/Redisson；
- **一个铁律**：过滤器只能拦截，误判兜底和容量监控必须跟上。

理解数学公式背后的直觉（每个 bit 是"群体指纹"），面试时从缓存穿透场景切入、手推误判率公式、再讲工程落地的坑，这道题就能答出深度。
