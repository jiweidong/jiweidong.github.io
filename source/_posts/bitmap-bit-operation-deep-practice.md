---
title: 【Java 实战】位图（Bitmap）深度解析：从位运算原理到海量数据去重与统计实战
date: 2026-08-24 08:00:00
tags:
  - Java
  - Redis
  - 算法
  - 面试
categories:
  - Java
author: 东哥
---

# 【Java 实战】位图（Bitmap）深度解析：从位运算原理到海量数据去重与统计实战

## 面试官：10 亿个整数里如何快速判断某个数是否存在？内存只有 1GB，怎么处理？

常规思路（HashSet、HashMap）在这个数据量下直接内存爆掉：10 亿个 int 用 HashSet 存，光数据就 4GB，加上对象头和哈希表结构膨胀，实际占用 20GB+。而用**位图（Bitmap）**，只需要 10 亿 bit = **约 119MB**。这就是位图的威力——**用 1 个 bit 表示一个元素的状态，空间压缩 32 倍以上**。

## 一、位运算基础（先夯实底层）

Java 的位运算操作符：

| 运算符 | 名称 | 示例 | 结果 |
|--------|------|------|------|
| `&` | 按位与 | `5 & 3` | 1（0101 & 0011 = 0001） |
| `\|` | 按位或 | `5 \| 3` | 7（0101 \| 0011 = 0111） |
| `^` | 按位异或 | `5 ^ 3` | 6（0101 ^ 0011 = 0110） |
| `~` | 按位取反 | `~5` | -6 |
| `<<` | 左移 | `1 << 3` | 8 |
| `>>` | 右移（带符号） | `-8 >> 1` | -4 |
| `>>>` | 无符号右移 | `-8 >>> 1` | 2147483644 |

位图的三个核心操作，全部基于下标定位：

```java
// 假设用 long[] 数组存位图，每个 long 有 64 个 bit
long[] bits = new long[(n >> 6) + 1];  // n 为元素最大值

// 1. 设置第 i 位为 1（标记元素存在）
bits[i >> 6] |= (1L << (i & 63));

// 2. 查询第 i 位是否为 1（判断元素是否存在）
boolean exists = (bits[i >> 6] & (1L << (i & 63))) != 0;

// 3. 清除第 i 位（删除元素）
bits[i >> 6] &= ~(1L << (i & 63));
```

这里 `i >> 6` 等价于 `i / 64`（定位到哪个 long），`i & 63` 等价于 `i % 64`（定位到 long 内的哪一位）。**用位运算代替除法和取模，是位图高性能的关键**。

## 二、手写一个高性能 Bitmap

```java
public class Bitmap {
    private final long[] words;
    private final int capacity;  // 能表示的最大值 + 1

    public Bitmap(int capacity) {
        this.capacity = capacity;
        this.words = new long[(capacity + 63) >> 6];
    }

    public void set(int index) {
        check(index);
        words[index >> 6] |= (1L << (index & 63));
    }

    public void clear(int index) {
        check(index);
        words[index >> 6] &= ~(1L << (index & 63));
    }

    public boolean get(int index) {
        check(index);
        return (words[index >> 6] & (1L << (index & 63))) != 0;
    }

    /** 统计 1 的个数（可用于去重计数） */
    public long bitCount() {
        long count = 0;
        for (long word : words) {
            count += Long.bitCount(word);
        }
        return count;
    }

    /** 位图交集（与）：两个集合同时存在的元素 */
    public Bitmap and(Bitmap other) {
        Bitmap result = new Bitmap(Math.max(capacity, other.capacity));
        for (int i = 0; i < words.length && i < other.words.length; i++) {
            result.words[i] = words[i] & other.words[i];
        }
        return result;
    }

    /** 位图并集（或） */
    public Bitmap or(Bitmap other) {
        Bitmap result = new Bitmap(Math.max(capacity, other.capacity));
        for (int i = 0; i < Math.max(words.length, other.words.length); i++) {
            long a = i < words.length ? words[i] : 0L;
            long b = i < other.words.length ? other.words[i] : 0L;
            result.words[i] = a | b;
        }
        return result;
    }

    private void check(int index) {
        if (index < 0 || index >= capacity) {
            throw new IndexOutOfBoundsException("index: " + index);
        }
    }
}
```

用 `Long.bitCount()` 做人口统计（popcount），比逐位循环快一个量级，因为 JDK 内部用了 SWAR 算法（分治加法）或者 CPU 的 popcnt 指令。

## 三、海量数据去重：经典面试题实战

### 题目：100 亿个 URL 中，统计不重复的 URL 数量，内存限制 1GB

**方案**：布隆过滤器（Bloom Filter）思想 + Bitmap。

先用哈希函数把 URL 映射到 bit 位。因为 URL 字符串不能直接当下标，需要先 hash：

```java
public class BloomFilter {
    private final Bitmap bits;
    private final int hashFunctions;  // 哈希函数个数 k

    public BloomFilter(int capacity, int hashFunctions) {
        this.bits = new Bitmap(capacity);
        this.hashFunctions = hashFunctions;
    }

    public void add(String value) {
        for (int i = 0; i < hashFunctions; i++) {
            bits.set(hash(value, i));
        }
    }

    public boolean mightContain(String value) {
        for (int i = 0; i < hashFunctions; i++) {
            if (!bits.get(hash(value, i))) return false;  // 有一位为 0 → 必然不存在
        }
        return true;  // 全为 1 → 可能存在（有误判率）
    }

    private int hash(String value, int seed) {
        // 双重哈希：用两个基础哈希组合出 k 个独立哈希
        int h1 = value.hashCode();
        int h2 = (h1 >>> 16) ^ (h1 * 0x45d9f3b);
        return Math.abs((h1 + seed * h2) % bits.capacity());
    }
}
```

**布隆过滤器要点**（面试必问）：

- **误判率**：不存在可能被判成存在（false positive），但存在绝不会被判成不存在。误判率 p 与位数组大小 m、元素数 n、哈希函数数 k 的关系：`p ≈ (1 - e^(-kn/m))^k`，最优 k = `(m/n) * ln2 ≈ 0.7 * (m/n)`
- **不能删除**：因为一个 bit 可能被多个元素共享，清掉会导致误判其他元素（除非用 Counting Bloom Filter）
- **内存对比**：1 亿个元素，误判率 1% 时约需 114MB；误判率 0.1% 约 172MB

## 四、位图的实际业务场景

### 场景 1：用户签到统计（Redis Bitmap 经典案例）

```bash
# 用户 id=10086，2026 年 8 月的签到记录（key: sign:202608:10086）
SETBIT sign:202608:10086 0 1     # 8月1日签到
SETBIT sign:202608:10086 2 1     # 8月3日签到
GETBIT sign:202608:10086 0       # 1
BITCOUNT sign:202608:10086       # 2（本月签到天数）
```

Java 侧（Spring Data Redis）：

```java
stringRedisTemplate.opsForValue().setBit("sign:202608:10086", 0, true);
boolean signed = stringRedisTemplate.opsForValue().getBit("sign:202608:10086", 0);
Long days = stringRedisTemplate.execute(
    connection -> connection.bitCount("sign:202608:10086".getBytes()));
```

**连续签到天数**：从今天往前数 1 的个数，配合 `BITFIELD` 命令一次取出整月数据：

```bash
BITFIELD sign:202608:10086 GET u31 0   # 一次取 31 位
```

一个用户一年只占 365 bit ≈ 46 字节，**1000 万用户全年签到只需约 435MB**。

### 场景 2：在线用户状态

```bash
SETBIT online_users 10086 1    # 用户上线
SETBIT online_users 10086 0    # 用户下线
BITCOUNT online_users          # 当前在线人数
```

### 场景 3：集合运算（推荐系统 / 标签系统）

```bash
# 用户 A 的标签位图、用户 B 的标签位图
BITOP AND result userA:tags userB:tags   # 共同标签
BITOP OR  union userA:tags userB:tags    # 全部标签
BITOP XOR diff userA:tags userB:tags     # 差异标签
```

`BITOP` 的 O(N) 复杂度按字节计算，百万级位图毫秒级完成，比数据库 JOIN 高效得多。

### 场景 4：海量整数去重（如用户 ID 白名单）

```java
// 布隆过滤器做"黑名单预判"：先过滤掉绝大多数合法请求
if (!bloomFilter.mightContain(ip)) {
    return; // 一定不在黑名单，直接放行
}
// 只有"可能存在"的才去查真正的黑名单库（Redis Set / DB）
```

## 五、位图 vs 其他数据结构对比

| 维度 | Bitmap | HashSet | 布隆过滤器 |
|------|--------|---------|-----------|
| 空间 | 极小（1 bit/元素） | 大（对象头+哈希表） | 小（1 bit/元素，可调） |
| 查询 | O(1) | O(1) | O(k)，k 为哈希次数 |
| 误判 | 无 | 无 | 有（可调） |
| 删除 | 支持 | 支持 | 不支持 |
| 范围/集合运算 | 极快（位运算） | 慢（遍历） | 快 |
| 适用 | 密集整数域 | 通用 | 海量数据存在性判断 |

**选型建议**：
- 元素是**连续的整数 ID**（用户 ID、签到天数）→ 原生 Bitmap，无误判
- 元素是**字符串/哈希值**且海量（URL、IP）→ 布隆过滤器，接受可控误判
- 需要**精确去重 + 通用** → HashSet（数据量小时）或 HyperLogLog（只需要基数时）

## 六、Java 生态中的现成实现

```java
// 1. JDK 自带：BitSet（生产可用，内部 long[]，支持逻辑运算）
BitSet bs = new BitSet(1_000_000);
bs.set(10086);
boolean b = bs.get(10086);
BitSet other = new BitSet();
other.set(10000);
bs.and(other);  // 交集

// 2. Guava：BloomFilter（生产级布隆过滤器）
BloomFilter<String> filter = BloomFilter.create(
    Funnels.stringFunnel(StandardCharsets.UTF_8),  // 漏斗
    10_000_000,   // 预计元素量
    0.01);        // 期望误判率 1%
filter.put("https://example.com");
boolean might = filter.mightContain("https://example.com");

// 3. Redis Bitmap（跨服务共享）
```

注意：`BitSet` 是线程不安全的，多线程场景需要外部加锁或用 `Collections.synchronizedSet` 包装。

## 七、面试高频追问

**Q1：BitMap 和布隆过滤器是什么关系？**
布隆过滤器 = Bitmap + 多个哈希函数。Bitmap 本身无误差，布隆过滤器用多个哈希位"投票"，用可接受的误判率换来了对任意类型（字符串）的支持。

**Q2：10 亿个整数找重复元素，怎么做？**
① 1 亿以内可直接 Bitmap 两遍扫描（第一遍标记，第二遍查重）；② 数据范围大或非整数 → 分治（哈希分桶到多个文件）后桶内 Bitmap。时间复杂度 O(n)，空间可控。

**Q3：布隆过滤器的误判率怎么计算和调优？**
`p ≈ (1 - e^(-kn/m))^k`。给定期望 p 和元素量 n，最优位数组大小 `m = -n·ln(p) / (ln2)²`，最优哈希函数数 `k = m·ln2 / n ≈ 0.7·m/n`。实际用 Guava 的 `BloomFilter.create` 会自动算好。

**Q4：为什么 Redis 的 SETBIT 能处理超大偏移？**
Redis 的字符串最大 512MB，即最大支持 `2^32` 个 bit（约 42 亿位）。位图超过单 key 上限时需分片（按用户 ID 取模分 key）。

**Q5：位图的缺点是什么？**
① 稀疏场景浪费空间（只有 2 个元素却要分配最大值范围的位数组）；② 无法直接存"值"本身，只能存"是否存在"；③ 布隆过滤器不能删除。稀疏场景可用 RoaringBitmap（压缩位图）替代。

## 总结

位图的核心是**用位下标编码元素、用位运算替代遍历**，在"海量数据存在性判断、去重、集合运算、统计"场景下空间和时间双优。掌握手写 Bitmap、布隆过滤器原理（误判率公式）、Redis 的 SETBIT/BITCOUNT/BITOP 三大命令，再加两个业务场景（签到、在线状态），面试就能从"知道"进阶到"会做"。
