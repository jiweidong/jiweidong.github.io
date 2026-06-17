---
title: 缓存淘汰算法深度解析：LRU、LFU 到 TinyLFU 的原理与Java实现
date: 2026-06-17 08:00:00
tags:
  - 缓存
  - 算法
  - LRU
  - LFU
  - Caffeine
  - Java
categories:
  - 架构设计
author: 东哥
---

# 缓存淘汰算法深度解析：LRU、LFU 到 TinyLFU 的原理与Java实现

## 一、引言

缓存是计算机科学中"以空间换时间"的经典思想体现。无论是 CPU 的 L1/L2/L3 Cache、操作系统的页面置换、数据库的 Buffer Pool，还是应用层的 Redis 和本地缓存，核心都面临同一个问题：**当缓存空间满时，应该淘汰哪些数据？**

选择正确的淘汰策略直接决定了缓存的命中率，进而影响系统整体性能。本文将从最基础的 FIFO 开始，逐步深入分析 LRU、LFU、ARC、TinyLFU 等主流淘汰算法的原理、实现与适用场景。

## 二、缓存淘汰算法基础

### 2.1 什么是缓存淘汰

当缓存达到容量上限时，需要按照一定的策略删除部分缓存项，为新数据腾出空间。这个策略就是 **Cache Eviction Policy（缓存淘汰策略）**。

### 2.2 评价指标

| 指标 | 说明 | 重要性 |
|------|------|--------|
| 命中率 | 缓存命中的请求占总请求比例 | 核心指标 |
| 时间复杂度 | 读写操作的时间复杂度 | 影响性能 |
| 空间复杂度 | 额外内存开销 | 影响资源占用 |
| 实现复杂度 | 代码实现与维护难度 | 工程成本 |

## 三、经典淘汰算法详解

### 3.1 FIFO（先进先出）

FIFO 是最简单的淘汰策略，使用队列维护缓存项，淘汰最早进入的数据。

**优点：** 实现简单，时间复杂度 O(1)。

**缺点：** 完全不考虑访问频率和访问时间，可能导致"冷数据"刚被淘汰又被再次载入。

```java
public class FIFOCache<K, V> {
    private final ConcurrentLinkedDeque<K> queue;
    private final Map<K, V> cache;
    private final int maxSize;

    public FIFOCache(int maxSize) {
        this.queue = new ConcurrentLinkedDeque<>();
        this.cache = new HashMap<>();
        this.maxSize = maxSize;
    }

    public synchronized V get(K key) {
        return cache.get(key);
    }

    public synchronized void put(K key, V value) {
        if (cache.containsKey(key)) {
            cache.put(key, value);
            return;
        }
        if (cache.size() >= maxSize) {
            K oldest = queue.pollFirst();
            cache.remove(oldest);
        }
        queue.addLast(key);
        cache.put(key, value);
    }
}
```

### 3.2 LRU（最近最少使用）

LRU（Least Recently Used）淘汰**最长时间未被访问**的数据。核心假设：如果一个数据最近被访问过，那么未来被访问的概率也更高。

#### 3.2.1 基于 LinkedHashMap 的实现

```java
public class LRUCache<K, V> extends LinkedHashMap<K, V> {
    private final int maxSize;

    public LRUCache(int maxSize) {
        super(maxSize, 0.75f, true); // accessOrder=true
        this.maxSize = maxSize;
    }

    @Override
    protected boolean removeEldestEntry(Map.Entry<K, V> eldest) {
        return size() > maxSize;
    }

    public static void main(String[] args) {
        LRUCache<Integer, String> cache = new LRUCache<>(3);
        cache.put(1, "A");
        cache.put(2, "B");
        cache.put(3, "C");
        cache.get(1); // 访问1，提升到最近
        cache.put(4, "D"); // 淘汰最久未使用的2
        System.out.println(cache); // {3=C, 1=A, 4=D}
    }
}
```

#### 3.2.2 手写 LRU（HashMap + 双向链表）

面试高频题，需要手写实现：

```java
public class LRUCacheManual<K, V> {
    private static class Node<K, V> {
        K key;
        V value;
        Node<K, V> prev, next;
        Node(K key, V value) { this.key = key; this.value = value; }
    }

    private final int capacity;
    private final Map<K, Node<K, V>> map = new HashMap<>();
    private final Node<K, V> head = new Node<>(null, null); // 哨兵
    private final Node<K, V> tail = new Node<>(null, null); // 哨兵

    public LRUCacheManual(int capacity) {
        this.capacity = capacity;
        head.next = tail;
        tail.prev = head;
    }

    public V get(K key) {
        Node<K, V> node = map.get(key);
        if (node == null) return null;
        removeNode(node);
        addToHead(node);
        return node.value;
    }

    public void put(K key, V value) {
        Node<K, V> node = map.get(key);
        if (node != null) {
            node.value = value;
            removeNode(node);
            addToHead(node);
        } else {
            if (map.size() >= capacity) {
                Node<K, V> removed = removeTail();
                map.remove(removed.key);
            }
            node = new Node<>(key, value);
            map.put(key, node);
            addToHead(node);
        }
    }

    private void addToHead(Node<K, V> node) {
        node.next = head.next;
        node.prev = head;
        head.next.prev = node;
        head.next = node;
    }

    private void removeNode(Node<K, V> node) {
        node.prev.next = node.next;
        node.next.prev = node.prev;
    }

    private Node<K, V> removeTail() {
        Node<K, V> node = tail.prev;
        removeNode(node);
        return node;
    }
}
```

#### 3.2.3 LRU 的优缺点

| 优点 | 缺点 |
|------|------|
| 实现简单，时间复杂度 O(1) | 对偶发性的扫描操作敏感（比如全表扫描） |
| 适合大多数通用场景 | 不考虑访问频率，一次访问就能把数据提到最前面 |
| 内存开销适中 | 在周期性扫描场景下命中率骤降 |

### 3.3 LFU（最不经常使用）

LFU（Least Frequently Used）淘汰**访问频率最低**的数据。核心假设：访问频率高的数据未来更可能被访问。

#### 3.3.1 标准 LFU 实现

标准 LFU 的最小实现需要维护两个映射：
- `key → (value, frequency)`
- `frequency → LinkedHashSet<key>`（同一频率的 key 集合，按时间排序）

```java
public class LFUCache<K, V> {
    private final int capacity;
    private final Map<K, V> valueMap = new HashMap<>();
    private final Map<K, Integer> freqMap = new HashMap<>();
    private final Map<Integer, LinkedHashSet<K>> freqKeys = new HashMap<>();
    private int minFreq = 0;

    public LFUCache(int capacity) {
        this.capacity = capacity;
    }

    public V get(K key) {
        if (!valueMap.containsKey(key)) return null;
        increaseFreq(key);
        return valueMap.get(key);
    }

    public void put(K key, V value) {
        if (capacity <= 0) return;
        if (valueMap.containsKey(key)) {
            valueMap.put(key, value);
            increaseFreq(key);
            return;
        }
        if (valueMap.size() >= capacity) {
            evict();
        }
        valueMap.put(key, value);
        freqMap.put(key, 1);
        freqKeys.computeIfAbsent(1, k -> new LinkedHashSet<>()).add(key);
        minFreq = 1;
    }

    private void increaseFreq(K key) {
        int oldFreq = freqMap.get(key);
        freqMap.put(key, oldFreq + 1);
        freqKeys.get(oldFreq).remove(key);
        if (freqKeys.get(oldFreq).isEmpty()) {
            freqKeys.remove(oldFreq);
            if (minFreq == oldFreq) minFreq++;
        }
        freqKeys.computeIfAbsent(oldFreq + 1, k -> new LinkedHashSet<>()).add(key);
    }

    private void evict() {
        LinkedHashSet<K> keys = freqKeys.get(minFreq);
        K evictKey = keys.iterator().next();
        keys.remove(evictKey);
        if (keys.isEmpty()) freqKeys.remove(minFreq);
        valueMap.remove(evictKey);
        freqMap.remove(evictKey);
    }
}
```

#### 3.3.2 LFU 的问题与优化

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 缓存污染 | 某个数据之前高频访问但不再需要，仍然占据缓存 | 引入衰减机制（时间窗口） |
| 新数据难进入 | 新数据频率为1，无法与高频老数据竞争 | Window TinyLFU |
| 空间开销大 | 需要维护频率计数器 | 使用近似计数（Count-Min Sketch） |

### 3.4 ARC（自适应替换缓存）

ARC（Adaptive Replacement Cache）由 IBM 研究院提出，动态平衡 LRU 和 LFU 的优势。

ARC 维护四个队列：
- **T1**：最近使用的页面
- **T2**：频繁使用的页面（至少被访问过两次）
- **B1**：从 T1 淘汰的页面的"幽灵"条目（仅存储 key，不存 value）
- **B2**：从 T2 淘汰的页面的"幽灵"条目

通过 `p` 参数动态调整 T1/B1 和 T2/B2 的比例，根据数据访问模式自动适应工作负载。

```java
public class ARCCache<K, V> {
    private final int c;           // 总容量
    private int p;                 // 自适应参数 (0 <= p <= c)
    private final LinkedHashSet<K> t1 = new LinkedHashSet<>(); // 最近使用
    private final LinkedHashSet<K> t2 = new LinkedHashSet<>(); // 频繁使用
    private final LinkedHashSet<K> b1 = new LinkedHashSet<>(); // T1的幽灵
    private final LinkedHashSet<K> b2 = new LinkedHashSet<>(); // T2的幽灵
    private final Map<K, V> cache = new HashMap<>();

    public ARCCache(int capacity) {
        this.c = capacity;
        this.p = capacity / 2;
    }

    public V get(K key) {
        if (!cache.containsKey(key)) return null;
        if (t1.contains(key)) {
            t1.remove(key);
            t2.add(key);
        }
        return cache.get(key);
    }

    public void put(K key, V value) {
        if (cache.containsKey(key)) {
            cache.put(key, value);
            if (t1.contains(key)) {
                t1.remove(key);
                t2.add(key);
            }
            return;
        }

        // 幽灵命中 => 增加p值，优先保留更多T1
        if (b1.contains(key)) {
            p = Math.min(c, p + Math.max(1, b2.size() / b1.size()));
            replace(key);
            b1.remove(key);
            t2.add(key);
        } else if (b2.contains(key)) {
            p = Math.max(0, p - Math.max(1, b1.size() / b2.size()));
            replace(key);
            b2.remove(key);
            t2.add(key);
        } else {
            if (t1.size() + b1.size() == c) {
                if (t1.size() < c) {
                    b1.remove(b1.iterator().next());
                    replace(key);
                } else {
                    t1.remove(t1.iterator().next());
                }
            } else if (t1.size() + b1.size() + t2.size() + b2.size() >= c) {
                if (t1.size() + b1.size() + t2.size() + b2.size() >= 2 * c) {
                    b2.remove(b2.iterator().next());
                }
                replace(key);
            }
            t1.add(key);
        }
        cache.put(key, value);
    }

    private void replace(K key) {
        if (t1.size() > 0 && (t1.size() > p || (t2.contains(key)))) {
            K old = t1.iterator().next();
            t1.remove(old);
            b1.add(old);
        } else {
            K old = t2.iterator().next();
            t2.remove(old);
            b2.add(old);
        }
        // 幽灵列表也需要限制大小
        while (b1.size() > c) b1.remove(b1.iterator().next());
        while (b2.size() > c) b2.remove(b2.iterator().next());
    }
}
```

ARC 的性能在多种工作负载下都非常优秀，但实现复杂度过高。

## 四、TinyLFU——现代缓存的答案

### 4.1 设计思想

TinyLFU 是 Caffeine 缓存库使用的核心淘汰算法，由 Gil Einziger 等人提出。它通过**近似计数 + 滑动窗口**的方式，同时解决了：
- LFU 的内存开销问题（使用 Count-Min Sketch 而非精确计数）
- LFU 的时效性问题（使用 Reset 机制衰减旧数据）
- LRU 的扫描敏感性问题（引入准入策略）

### 4.2 核心组成

```
┌─────────────────────────────────────────────┐
│              TinyLFU Architecture            │
├─────────────────────────────────────────────┤
│                                             │
│   ┌───────────────────┐    ┌──────────────┐ │
│   │   Main Cache      │    │ Window Cache  │ │
│   │   (SLRU, ~99%)    │    │   (LRU, ~1%) │ │
│   └───────────────────┘    └──────────────┘ │
│             ▲                      ▲         │
│             │                      │         │
│   ┌─────────┴──────────────────────┴──────┐  │
│   │        Admission Policy               │  │
│   │  (TinyLFU Frequency Sketch Decides)   │  │
│   └───────────────────────────────────────┘  │
│                                             │
│   ┌──────────────────────────────────────┐  │
│   │   Frequency Sketch (Count-Min Sketch)│  │
│   │   + Reset Mechanism (half-period)    │  │
│   └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### 4.3 Count-Min Sketch 实现

Count-Min Sketch 是一种概率性数据结构，用很小的空间近似统计频次：

```java
public class CountMinSketch {
    private final int width;
    private final int depth;
    private final long[][] table;
    private final int[] seeds;
    private static final long RESET_MASK = 0xFFFF_FFFFL;

    public CountMinSketch(int width, int depth) {
        this.width = width;
        this.depth = depth;
        this.table = new long[depth][width];
        this.seeds = new int[depth];
        Random rnd = new Random();
        for (int i = 0; i < depth; i++) {
            seeds[i] = rnd.nextInt(Integer.MAX_VALUE);
        }
    }

    private int hash(long item, int seed) {
        // MurmurHash 风格的混合
        long h = seed;
        h ^= item;
        h *= 0x9e3779b97f4a7c15L;
        return (int)((h >>> 32) ^ h) & (width - 1);
    }

    public void increment(long item) {
        for (int i = 0; i < depth; i++) {
            int idx = hash(item, seeds[i]);
            long val = table[i][idx];
            if (val < RESET_MASK) {
                table[i][idx] = val + 1;
            }
        }
    }

    public long frequency(long item) {
        long min = Long.MAX_VALUE;
        for (int i = 0; i < depth; i++) {
            int idx = hash(item, seeds[i]);
            min = Math.min(min, table[i][idx]);
        }
        return min;
    }

    /**
     * Reset 操作：将所有计数减半，模拟时间衰减
     */
    public void reset() {
        for (int i = 0; i < depth; i++) {
            for (int j = 0; j < width; j++) {
                table[i][j] = table[i][j] >>> 1;
            }
        }
    }
}
```

### 4.4 Window-TinyLFU 准入策略

当新数据要进入缓存时，TinyLFU 会比较新数据与将被淘汰数据的频率：

```java
public class WindowTinyLFU<K, V> {
    private final CountMinSketch sketch = new CountMinSketch(512, 4);
    private final LruCache<K, V> window;            // ~1% 容量
    private final SlruCache<K, V> mainProbation;    // ~20% 容量
    private final SlruCache<K, V> mainProtected;    // ~80% 容量
    private final int maxSize;
    private long sampleCount = 0;
    private static final long RESET_INTERVAL = 1000;

    // ...
    
    public void put(K key, V value) {
        sampleCount++;
        // 周期性 Reset，确保近期数据权重更高
        if (sampleCount >= RESET_INTERVAL) {
            sketch.reset();
            sampleCount = 0;
        }
        
        // 新数据先进入 Window Cache
        if (window.contains(key) || mainProbation.contains(key) || mainProtected.contains(key)) {
            // 更新但不淘汰
            raiseToProtected(key);
            return;
        }
        
        window.put(key, value);
        sketch.increment(key.hashCode());
        
        // 如果 Window 满了，将候选者移入主缓存
        if (window.size() > maxSize * 0.01) {
            K candidate = window.evictOne();
            admitToMainCache(candidate);
        }
    }
    
    private void admitToMainCache(K candidate) {
        K victim = mainProbation.peekVictim();
        if (victim == null) {
            mainProbation.put(candidate);
            return;
        }
        
        long candidateFreq = sketch.frequency(candidate.hashCode());
        long victimFreq = sketch.frequency(victim.hashCode());
        
        // 仅当新数据的频率高于淘汰候选项时才准入
        if (candidateFreq > victimFreq) {
            mainProbation.put(candidate);
            mainProbation.remove(victim); // 淘汰 victim
            sketch.increment(candidate.hashCode());
        } else {
            // 拒绝新数据，允许 victim 保留
            sketch.increment(victim.hashCode());
        }
    }
}
```

## 五、主流缓存库的淘汰算法对比

| 属性 | Guava Cache | Caffeine | Ehcache 3 | Redis |
|------|-------------|----------|-----------|-------|
| 淘汰算法 | ConcurrentLinkedHashMap + LRU | Window-TinyLFU | LRU + LFU + Clock | 近似LRU（采样淘汰） |
| 准入策略 | 无 | TinyLFU | 无 | 无 |
| 时间复杂度 | O(1) | O(1) | O(1) | O(n) 采样 |
| 空间效率 | 高 | 极高（近似计数） | 中 | 低（精确全量） |
| 缓存命中率 | 高 | 极高 | 高 | 中 |
| 内存开销 | 中 | 低 | 中 | 高（全量内存） |
| 并发度 | 分段锁 | Striped | JSR-107 | 单线程 |

## 六、各算法性能对比测试

| 测试场景 | FIFO | LRU | LFU | ARC | TinyLFU |
|----------|------|-----|-----|-----|---------|
| 热点数据（80/20分布） | 78% | 95% | 96% | 96% | 97% |
| 周期性扫描 | 82% | 45% | 92% | 88% | 95% |
| 突发流量 | 70% | 88% | 82% | 89% | 93% |
| 数据循环访问 | 65% | 60% | 85% | 80% | 91% |
| 混合工作负载 | 72% | 80% | 83% | 89% | 94% |

> 测试数据基于 Caffeine 官方 Benchmark，模拟不同访问模式下的命中率。

## 七、工程实践建议

### 7.1 如何选择合适的淘汰算法

| 场景 | 推荐算法 | 理由 |
|------|----------|------|
| 通用本地缓存 | Window-TinyLFU（Caffeine） | 综合命中率最高，性能出色 |
| Redis 缓存 | 近似 LRU（默认）/ LFU（volatile-lfu） | 内置支持，足够大多数场景 |
| CPU Cache | LRU（近似实现） | 硬件友好，实现成本低 |
| 数据库 Buffer Pool | ARC / LRU | MySQL InnoDB 改良版 LRU |
| 内容分发网络（CDN） | LFU + 时间衰减 | 内容访问频率特征明显 |
| 嵌入式设备 | Clock（近似LRU） | 内存极小，实现简单 |

### 7.2 生产环境配置示例

```java
// Caffeine 推荐配置
Cache<String, User> cache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(1, TimeUnit.HOURS)
    .recordStats()          // 开启命中率统计
    .build();

// 运行后查看命中率
CacheStats stats = cache.stats();
System.out.printf("命中率: %.2f%%%n", stats.hitRate() * 100);
System.out.printf("加载耗时: %dms%n", stats.totalLoadTime() / 1_000_000);
```

```yaml
# Redis 缓存策略配置
maxmemory 512mb
# allkeys-lfu: 对所有key使用LFU淘汰
# volatile-lru: 仅在设置了TTL的key上使用LRU
maxmemory-policy allkeys-lfu
lfu-log-factor 10
lfu-decay-time 1
```

## 八、总结

缓存淘汰算法经历了从简单到复杂的演进过程：

1. **FIFO** 实现最简单但命中率最差
2. **LRU** 适合大多数场景，但被扫描操作"污染"
3. **LFU** 考虑频率但实现复杂、有缓存污染问题
4. **ARC** 自适应平衡LRU和LFU，性能优秀但实现复杂
5. **TinyLFU** 通过概率计数和滑动窗口，在命中率、性能和内存开销之间取得最佳平衡

**选型建议：** Java 应用首选 **Caffeine**（TinyLFU），Redis 场景根据访问模式选择 **allkeys-lfu** 或 **allkeys-lru**，MySQL Buffer Pool 使用 InnoDB 自带的改良 LRU 即可。

缓存没有银弹，理解每个算法的优缺点，结合自己的业务访问模式做选型，才是最佳实践。
