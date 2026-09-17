---
title: 【Java 实战】概率数据结构深度解析：HyperLogLog、Count-Min Sketch 与 Cuckoo Filter
date: 2026-09-17 08:00:00
tags:
  - Java
  - 数据结构
  - 算法
categories:
  - Java
  - 架构
author: 东哥
---

# 【Java 实战】概率数据结构深度解析：HyperLogLog、Count-Min Sketch 与 Cuckoo Filter

## 面试官：一亿个 UV 怎么统计？内存只给你 1MB

这道题考的不是"你会不会用 Redis"，而是**你能不能在"内存有限 + 允许误差"的前提下把问题建模掉**。

朴素方案是 `HashSet<Long>` 存所有用户 ID：一亿个 long，加上 HashSet 的负载因子与 Node 对象开销，轻松超过 3GB。但如果你接受 **0.81% 的误差**，答案就变成——**HyperLogLog，12KB**。

类似的"用精度换空间"的题目还有一整套：

- 判断 URL 是否已爬过（不能漏判）→ **Bloom Filter**；
- 统计 Top-K 热词 / 判断是否存在极高流量 → **Count-Min Sketch**；
- 频繁删除元素的集合去重 → **Cuckoo Filter**；
- 统计基数并在集合间求并集 → **HyperLogLog**。

本文把这三个最常用的概率数据结构从原理讲到 Java 实现，再给你一套选型决策树。

## 一、概率数据结构的三条公理

在讲具体结构前，先建立统一的心智模型：

1. **哈希先行**：所有结构都依赖一个（或多个）均匀分布的哈希函数，把元素映射到固定大小的空间。
2. **用"位/计数"代替"元素本身"**：不存元素，只存"痕迹"。所以**只能回答特定问题**（是否存在 / 大约多少 / 大约多少次），不能取回元素。
3. **误差可控但不为零**：误差要么是**假阳性（false positive）**，要么是**估计偏差（bias）**。工程上用"误差上限 + 内存上限"换算参数。

| 结构 | 解决的问题 | 误差类型 | 空间 |
| --- | --- | --- | --- |
| Bloom Filter | 是否存在 | 假阳性（可能误判存在），**无假阴性** | 约 1.2n 字节级 |
| Counting Bloom / Cuckoo Filter | 是否存在 + 可删除 | 假阳性 | 略大于 Bloom |
| Count-Min Sketch | 频率估计 | **只会高估，不会低估** | 与 ε 反比 |
| HyperLogLog | 基数（去重计数） | 相对误差约 1.04/√m | 与精度亚线性 |

## 二、Bloom Filter：为什么"可能"和"一定"要分清

Bloom Filter 是一个 bit 数组 + k 个哈希函数：

```text
插入 x：h1(x)..hk(x) 位置的比特全部置 1
查询 x：只要有一位是 0 → 一定不存在
        全部是 1     → 可能存在（可能是别人置的）
```

这个"**无假阴性**"性质是它最有价值的特性：**说不在就一定不在**。因此它适合做"前置拦截"——数据库查询前先问 Bloom，"不存在的 key 直接返回"，这就是 Redis 缓存穿透防护的经典手段。

### 参数怎么定

在给定误判率 p 和元素数 n 时：

```text
最优哈希个数:  k = (m/n) * ln2
位数组大小:    m = -n * ln p / (ln2)^2
```

举例：n = 1 亿，p = 1%，则 m ≈ 9.6 亿比特 ≈ **114MB**，k = 7。对内存敏感的场景，p 放到 5% 能把空间压到 ~62MB。

### Java 实现（可用 Guava）

```java
// Guava：简单可靠，但 Guava 的 BloomFilter 不支持删除，且不能分布式共享
BloomFilter<String> filter = BloomFilter.create(
        Funnels.stringFunnel(StandardCharsets.UTF_8),
        100_000_000L,      // 预期元素数
        0.01);             // 误判率

filter.put("/article/12345");
boolean maybeExists = filter.mightContain("/article/12345"); // true
```

生产上更常见的是 **Redis 版（RedisBloom 模块）**，好处是分布式共享、支持 `BF.RESERVE` 精确控参：

```text
BF.RESERVE url_seen 0.001 100000000
BF.ADD url_seen https://example.com/a
BF.EXISTS url_seen https://example.com/a
```

> ⚠️ 经典坑：**Bloom Filter 不能删除**。置 1 的位可能被多个元素共享，删一个就会破坏其他元素的判定（产生假阴性——而假阴性是这个结构唯一的"红线"）。需要删除就用 **Counting Bloom Filter**（每位变 4bit 计数器）或 **Cuckoo Filter**。

## 三、Cuckoo Filter：可删除的布隆替代品

Cuckoo Filter 用**布谷鸟哈希**的思路：每个元素存两个候选桶，把"指纹"（fingerprint，比原元素短得多的 hash 片段）存进桶里。插入冲突时**踢出旧元素**，被踢的重新找位置，如此反复（"鸠占鹊巢"）。

关键性质：

- **支持删除**：删除时从两个候选桶里移除对应指纹即可（可能误删同指纹元素，但不会影响其他桶）；
- **空间利用率更高**：在目标误判率下通常比 Bloom 省 20%~40% 空间；
- **查询只看两个桶**，缓存友好，速度稳定。

```java
// 概念性实现：两个桶 + 指纹
public class CuckooFilter {
    private final long[][] buckets;
    private final int bucketSize;
    private final int maxKicks = 500;

    private int fingerprint(long hash) {
        int fp = (int) (hash & 0xFF);
        return fp == 0 ? 1 : fp;   // 0 不能用（表示空槽）
    }

    private int index1(long hash) {
        return (int) ((hash >>> 32) % buckets.length);
    }

    private int index2(int i1, int fp) {
        return (i1 ^ (fp * 0x5bd1e995)) % buckets.length;
    }

    public boolean insert(long hash) {
        int fp = fingerprint(hash);
        int i1 = index1(hash), i2 = index2(i1, fp);
        if (put(i1, fp) || put(i2, fp)) return true;

        // 随机挑一个桶，踢出一个元素，继续重定位
        int i = ThreadLocalRandom.current().nextBoolean() ? i1 : i2;
        for (int n = 0; n < maxKicks; n++) {
            int slot = ThreadLocalRandom.current().nextInt(bucketSize);
            int evicted = buckets[i][slot];
            buckets[i][slot] = fp;
            fp = evicted;
            i = index2(i, fp);
            if (put(i, fp)) return true;
        }
        return false;  // 踢太多次，需要扩容
    }

    public boolean contains(long hash) {
        int fp = fingerprint(hash);
        int i1 = index1(hash);
        return has(i1, fp) || has(index2(i1, fp), fp);
    }
}
```

::: warning 候选桶必须是"对称可推导"的
`index2 = index1 ^ hash(fingerprint)` 这种写法保证：**知道 i1 和 fp 就能算出 i2，反之亦然**。如果 i2 直接由原 hash 决定，删除时只剩指纹就推不出 i2 了。这是 Cuckoo Filter 能"只存指纹"的全部秘密。
:::

## 四、Count-Min Sketch：只会高估的频率估计

场景：统计一小时内每个 URL 的访问量，找出 Top-K，但 URL 种类可能是千万级——精确计数要一个巨大的 `HashMap`。

CMS 的结构是一张 **d 行 × w 列的计数器矩阵**，配 d 个独立哈希函数：

```text
update(x, c): 对每一行 i，counters[i][h_i(x)] += c
query(x):     return min(counters[0][h0(x)], ..., counters[d-1][h_{d-1}(x)])
```

**为什么取 min？** 因为哈希碰撞只会让计数**变大**（别人的计数加到了你的格子），所以取最小值是对真实值最紧的上界。于是 CMS 有一个漂亮的保证：

> 估计值 ≥ 真实值，且误差以概率 1-δ 不超过 εN。

参数换算：`w = ⌈e/ε⌉`，`d = ⌈ln(1/δ)⌉`。要求 1% 误差、99% 置信度：ε=0.01 → w=272，δ=0.01 → d=5，共 **1360 个计数器**——几 KB 搞定千万级元素。

```java
public class CountMinSketch {
    private final long[][] counters;
    private final int depth;
    private final int width;
    private final int[] seeds;

    public CountMinSketch(double epsilon, double delta) {
        this.width = (int) Math.ceil(Math.E / epsilon);
        this.depth = (int) Math.ceil(Math.log(1 / delta));
        this.counters = new long[depth][width];
        this.seeds = new int[depth];
        for (int i = 0; i < depth; i++) seeds[i] = 0x9E3779B9 * (i + 1);
    }

    private int hash(String key, int seed) {
        int h = MurmurHash3.hash32(key.getBytes(StandardCharsets.UTF_8), seed);
        return Math.abs(h % width);
    }

    public void add(String key, long delta) {
        for (int i = 0; i < depth; i++) {
            counters[i][hash(key, seeds[i])] += delta;
        }
    }

    public long estimate(String key) {
        long min = Long.MAX_VALUE;
        for (int i = 0; i < depth; i++) {
            min = Math.min(min, counters[i][hash(key, seeds[i])]);
        }
        return min;
    }
}
```

**Top-K 怎么找？** CMS 本身不维护顺序，标准组合是 **CMS + 堆**（或 Space-Saving 算法）：

- 用一个大小 K 的**小顶堆**维护候选；
- 每次 `add` 后 `estimate` 当前 key，若大于堆顶则替换；
- 定期清理堆中"实际计数已跌出 Top-K"的元素。

这是流式 Top-K 的标准解，Kafka Streams / Flink 里都能见到类似实现。

## 五、HyperLogLog：12KB 统计任意基数

HLL 的思想极其漂亮，核心是**用"最长前导零"估计基数**：

```text
对每个元素做哈希（64bit），观察二进制串里"从低位开始连续 0 的个数"（或前导零个数）。
这个值的期望是 log2(N)：如果元素有 N 个，哈希值大致均匀分布在 [0, 2^64)，
出现"连续 k 个 0"的概率是 2^-k，因此出现的最大 k 大约就是 log2(N)。
```

单个估计量方差极大，所以 HLL 用**分桶 + 调和平均 + 偏差修正**把误差压下来：

- 把 64 位哈希的前 14 位当**桶号**（2^14 = 16384 个桶）；
- 后 50 位统计前导零个数，每个桶只记录**该桶观察到的最大值**（6bit 足够）；
- 用**调和平均**聚合所有桶（调和平均对离群值不敏感，这正是它比算术平均准的原因）。

```text
空间 = 16384 桶 × 6 bit ≈ 12KB     标准误差 ≈ 1.04 / √16384 ≈ 0.81%
```

```text
// Redis 命令
PFADD uv:20260917 user_1001
PFCOUNT uv:20260917
PFMERGE uv:week uv:20260915 uv:20260916 uv:20260917
```

`PFMERGE` 是 HLL 的杀手锏：**桶的最大值可以合并**，所以多天 UV 并集是一次逐桶取 max，成本极低。这让"任意时间窗口的 UV"变成可预计算的聚合。

### HLL 的三个注意点

1. **不可逆**：拿不到具体是哪些用户，所以不能"查某用户是否在集合里"；
2. **小基数偏差**：基数小于 5×2^b/2 时有系统性高估，标准实现用 **Linear Counting** 修正（Redis 与大多数库都已处理）；
3. **合并的前提是桶数一致**：两个不同 `p` 参数的 HLL 不能 merge。

## 六、选型决策树

```text
问题里有"是否存在"吗？
├── 是 → 允许假阳性吗？
│    ├── 允许，且不需要删除 → Bloom Filter（最省心）
│    └── 允许，且需要删除   → Cuckoo Filter / Counting Bloom
└── 否 → 是"多少种不同元素"（基数）吗？
     ├── 是 → HyperLogLog
     └── 否 → 是"某个元素出现多少次"（频率）吗？
          ├── 是 → Count-Min Sketch（+ 堆做 Top-K）
          └── 否 → 老实上精确结构（HashMap/DB）
```

在 Java 生态里的落地选择：

| 需求 | 推荐 |
| --- | --- |
| 本地布隆 | Guava `BloomFilter` |
| 分布式布隆/计数 | RedisBloom（`BF.*`、`CF.*`、`CMS.*`、`PF*`） |
| 高吞吐本地 HLL | `stream-lib` / `HLL` (aggregateknowledge) |
| 海量去重 + 分布式 | Redis `PFADD` + 定期 `PFMERGE` 到汇总 key |
| 流式 Top-K | CMS + 小顶堆，或 Flink `TopN` 内置算子 |

## 七、生产踩坑清单

1. **别把 Bloom 当"精确集合"用**。它"说不存在一定不存在"，但"说存在"只能当线索，最终仍要回源校验。
2. **误判率是概率，不是上限**。p=1% 是期望值，实际会有波动，容量规划留 20% 余量。
3. **Redis Bloom/HLL 都是大 key 风险点**。1 亿容量 Bloom ≈ 114MB，属于典型大 key，要注意分片（按前缀 hash 到多个 key）与迁移阻塞。
4. **HLL 的 `p` 参数决定了误差与内存，重建成本高**，上线前想清楚精度要求。
5. **CMS 会一直高估**，做限流/风控时要把"高估"作为安全假设（宁可错杀）。
6. **参数与数据规模强绑定**：n 增长 10 倍不扩容，误判率会显著劣化。监控误判率（用真实数据抽样校验）比监控内存更重要。

## 面试追问连击

**追问 1：Bloom Filter 为什么不能删除？**
因为一个 bit 可能被多个元素共同置位，清除它会让其他元素的查询返回"不存在"——产生**假阴性**，而假阴性是 Bloom 唯一不允许的错误类型。要删除就换 Counting Bloom 或 Cuckoo Filter。

**追问 2：HLL 为什么用调和平均？**
单个桶的估计值分布是重尾的（可能极大），算术平均会被极端值拉高；调和平均对极端值抑制强，能把相对误差压到 1.04/√m 的水平，这是 HLL 精度分析的核心结论。

**追问 3：CMS 为什么取 min 而不是平均？**
哈希碰撞只会**叠加**别人的计数，因此每个格子的值都是真实值的上界；取 d 个格子中的最小值，就得到最紧的上界。平均会把偏差也平均进去，反而更不准。

**追问 4：一亿 UV，内存 1MB 怎么选？**
HLL：p=14 时 12KB，误差 0.81%，绰绰有余。1MB 可以开 p=16（65536 桶，约 48KB，误差 0.4%）。Bloom 解决不了"去重计数"问题（它只回答存在性），所以这里没得选。

**追问 5：这些结构能替代精确统计吗？**
不能，要看业务容忍度。UV 统计能接受 1% 误差，但**订单金额、库存、支付计数绝对不能**——金融场景的误差等于事故。判断标准是：**这个数字错了 1%，会不会有人来找你赔钱？**

## 小结

- 概率数据结构的本质是"用可控误差换数量级的内存节省"。
- Bloom：存在性判断、无假阴性、不可删除 → 缓存穿透防护。
- Cuckoo：可删除、更省空间 → 爬虫去重、可回收的集合。
- CMS：频率估计、只高估 → 热点检测、流式 Top-K。
- HLL：基数统计、可合并、12KB → UV/去重计数。

面试里遇到"内存不够怎么办"的题，先别急着优化 SQL 或加机器——**先问一句"精度要求是多少"**。问出这句话，你已经比大多数人更接近正确答案了。
