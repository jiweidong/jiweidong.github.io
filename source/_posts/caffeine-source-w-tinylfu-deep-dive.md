---
title: 【缓存源码】Caffeine 源码级深度解析：W-TinyLFU 淘汰算法与高性能本地缓存架构
date: 2026-09-09 08:00:00
tags:
  - Java
  - Caffeine
  - 缓存
  - 源码
categories:
  - Java
  - 中间件
author: 东哥
---

# 【缓存源码】Caffeine 源码级深度解析：W-TinyLFU 淘汰算法与高性能本地缓存架构

## 面试官：本地缓存你用过 Caffeine 吗？它比手写 LRU 强在哪？W-TinyLFU 是什么？

背过八股的同学都能说出"Caffeine 是 Guava Cache 的继任者，基于 W-TinyLFU 淘汰算法，性能吊打 LRU"。但再追问一句 **"W-TinyLFU 的 FrequencySketch 为什么用 4 bit 计数？Window 区和 Main 区怎么协作？Caffeine 为什么读写那么快？"** 很多人就卡壳了。

本文直接扒 Caffeine 源码（基于 3.x），把**淘汰算法、存储结构、读写路径**三大块讲透。

## 一、Caffeine 的设计目标与整体架构

Caffeine 是一个**进程内缓存**，对标 Guava Cache 但性能全面领先（官方 benchmark 在读写混合场景下吞吐是 Guava 的 6~10 倍）。它要同时解决三个问题：

1. **淘汰要"聪明"**：LRU 只认最近访问，扛不住"周期性热点"（如每天 9 点批量访问的报表数据）；LFU 又无法适应访问模式变化；
2. **读写要快**：本地缓存是超高频率访问，任何加锁都会成为瓶颈；
3. **维护要异步**：过期扫描、淘汰、监听器回调不能阻塞读线程。

Caffeine 的答案：**W-TinyLFU 淘汰策略 + 无锁读 + 读写缓冲 + 单线程异步维护**。

```
BoundedLocalCache（核心实现）
├── Node 数组（哈希表，存 key-value 与访问元数据）
├── 淘汰策略（W-TinyLFU）：
│   ├── FrequencySketch（频率估计器）
│   ├── Window LRU 队列（占 1%）
│   └── Main 区（占 99%）：
│       ├── 保护段 Probation（80%）
│       └── 试用段 Protected（20%）
├── 写缓冲 WriteBuffer（RingBuffer，MPSC）
└── 读缓冲 ReadBuffer（RingBuffer）
    └── 维护线程（单线程 Drainer，定期/按需执行）
```

## 二、W-TinyLFU：比 LRU/LFU 聪明在哪？

### 2.1 TinyLFU 的频率估计：FrequencySketch

真正的 LFU 要为每个 key 维护精确访问次数，内存不可接受。TinyLFU 的思路是**用近似计数 + 概率老化**：

- 每个 key 通过**多次哈希**映射到一张计数表（`FrequencySketch` 内部是一个 `long[]`，每个 long 拆成 16 个 4-bit 槽位）；
- 访问时对 key 做 4 个哈希，命中哪几个槽就给哪几个槽 +1（4 bit 最大计 15，溢出封顶）；
- **4 bit 计数的两个意义**：省内存（一个 key 只占 4 个 4-bit 槽 ≈ 2 字节）；计数溢出封顶，避免老数据频率无限增长、新数据永远进不来——这就是 LFU 的"冷启动/模式漂移"问题的对策之一。

### 2.2 概率老化（reset）：让计数"遗忘"旧热点

只靠封顶还不够：长期运行的缓存里，老热点计数普遍偏高，新晋热点依然比不过。TinyLFU 的做法是**周期性地把所有计数减半（reset）**：

```java
// FrequencySketch#reset 的核心逻辑（源码简化）
void reset() {
  int count = 0;
  for (int i = 0; i < table.length; i++) {
    count += Long.bitCount(table[i] & ONE_MASK);   // ONE_MASK = 0x1111111111111111
  }
  // 当总计数达到采样阈值（size 的 10 倍），把所有计数右移 1 位（整体减半）
  if (count >= size * 10) {
    for (int i = 0; i < table.length; i++) {
      table[i] = (table[i] >>> 1) & RESET_MASK;
    }
  }
}
```

`>>>1` 一下，所有频率减半——**近期热点受影响小（减半后仍高），远古热点迅速归零**，缓存就能持续"追踪"访问模式变化。

### 2.3 W-TinyLFU 的三段式结构

TinyLFU 的问题：**新数据刚进缓存时频率为 0，永远竞争不过老数据，导致缓存无法吸收突发流量**。W-TinyLFU 加了 **Window 区** 解决：

- **Window LRU 区**（默认占总容量 **1%**）：新数据先进这里，按 LRU 淘汰，给新数据一个"试用期"；
- Window 区被淘汰的 key 进入 **Main 区**，与 Main 区"试用段（Probation）"的 victim **b竞争**：
  - 谁的**估算频率高**谁留下；
  - 如果新来的频率 ≥ victim，则 victim 被淘汰、新 key 进入 Main 区保护段；
  - 如果新来的频率低，直接被淘汰（admission 拒绝）；
- **Main 区内部**：试用段（Probation，80%）里的 key 再次被访问就晋升到保护段（Protected，20%）；保护段满了再把最老的降级回试用段——这层设计保证**高频率 key 留在缓存里，低频率 key 在试用段内互相淘汰**。

一句话：**Window 区解决"新数据进得来"，频率计数解决"热点留得住"，概率老化解决"热点会过时"**——这就是 W-TinyLFU 完胜纯 LRU 的核心。

## 三、性能为什么快？读写路径源码剖析

### 3.1 读路径：无锁 + 缓冲

```java
// BoundedLocalCache#get 的快速路径（源码简化）
@Nullable
V get(K key) {
  Node<K, V> node = data.get(key);   // ConcurrentHashMap 式无锁读
  if (node == null) return null;
  // 命中后不直接做 LRU 调整！只把访问事件丢进读缓冲
  readBuffer.offer(node);
  ...
  return node.getValue();
}
```

关键设计：

1. **哈希表本身无锁读**（读 ConcurrentHashMap 的桶），读操作几乎没有竞争；
2. **读不直接改链表**！访问频率计数、LRU 顺序调整都通过 `readBuffer.offer()` 异步完成——读线程只做一个 `offer`（MPSC RingBuffer 的无锁入队），真正的维护由 Drainer 线程批量处理。

### 3.2 写路径与异步维护

写操作（put）进入 `writeBuffer`，同样先快速入队；随后由**单线程 Drainer** 统一执行：

- 处理读/写缓冲里积压的访问记录 → 更新 FrequencySketch 与三段链表；
- 执行淘汰：超过 `maximumSize` 时从 Window/Probation 里挑 victim 淘汰；
- 执行过期清理与 `RemovalListener` 回调（回调也是异步的，不阻塞调用线程）；
- 通过 `scheduleDrainBuffers()` 在写入后**按需唤醒**，而不是起一个常驻线程空转（空闲时零开销）。

这就是 Caffeine 高性能的完整链路：**无锁读 + 无锁入队 + 单线程批量维护**，把"读多写多"的竞争全部摊平。

### 3.3 过期策略：惰性 + 定期清扫

- `expireAfterWrite` / `expireAfterAccess`：节点上记录过期时间戳；**读时惰性检查** + Drainer 定期（约 1 秒）扫描**按时间有序的淘汰队列**（`TimerWheel`，Caffeine 用层级时间轮组织，复杂度 O(1) 均摊）清理到期节点；
- `refreshAfterWrite`：到期后不阻塞删除，而是**异步 reload**（旧值继续可用），适合"读多、允许短暂旧值"的场景——注意 refresh 需要配 `CacheLoader`。

## 四、手写 LRU vs Caffeine：差距在哪？

| 维度 | 手写 LinkedHashMap LRU | Caffeine |
|---|---|---|
| 淘汰质量 | 只认最近访问，热点漂移适应差 | W-TinyLFU，抗扫描、跟热点 |
| 并发 | 全局锁或分段锁 | 无锁读 + 缓冲批量维护 |
| 过期 | 无/需自己实现 | 惰性+时间轮定期清理 |
| 监听器/统计 | 无 | RemovalListener、命中率统计内置 |
| 异步加载 | 无 | refreshAfterWrite + async loader |

## 五、生产配置实战

```java
Cache<String, Product> cache = Caffeine.newBuilder()
        .maximumSize(10_000)                          // 容量上限
        .expireAfterWrite(Duration.ofMinutes(30))     // 写后过期
        .refreshAfterWrite(Duration.ofMinutes(5))     // 5 分钟异步刷新（需 loader）
        .recordStats()                                // 开启命中率统计
        .removalListener((key, value, cause) ->
                log.info("evict {} cause={}", key, cause))  // 淘汰监听
        .build(key -> loadFromDb(key));               // CacheLoader

// Spring Boot 集成：CacheManager 指定 Caffeine 即可，@Cacheable 直接可用
```

**最佳实践**：

1. 本地缓存是**堆内存缓存**，容量要按 JVM 堆预算，配 `maximumSize` 或 `maximumWeight`，别不设上限；
2. **多级缓存**：Caffeine（毫秒级）→ Redis（分布式）→ DB，注意 Caffeine 里只放"热点中的热点"，并设置较短 TTL 减少不一致窗口；
3. 缓存值尽量**不可变**，避免外部修改污染缓存；
4. 监控 `stats().hitRate()`，命中率长期过低说明容量配置不合理或淘汰策略不适配。

## 六、面试高频追问

- W-TinyLFU 三个区各解决什么问题？→ Window 吸收新数据、Main 保热点、频率计数抗扫描
- FrequencySketch 为什么用 4 bit？→ 省内存 + 计数封顶防老热点垄断
- 计数减半（reset）什么时候触发？→ 总计数超过容量 10 倍时，整体 >>>1
- Caffeine 为什么读快？→ 无锁哈希读 + 读缓冲异步维护，读路径零竞争
- 维护线程是常驻的吗？→ 不是，写后按需唤醒（scheduleDrainBuffers）
- Guava Cache 和 Caffeine 怎么选？→ 新项目无脑 Caffeine，淘汰算法和并发模型全面领先

**一句话总结：Caffeine 的强不是某一个点，而是"W-TinyLFU 聪明的淘汰 + 无锁读 + 缓冲异步维护"的组合拳。理解这三层，本地缓存面试题基本通杀，也为你看其他高性能组件（Netty、Disruptor）打下了方法论基础。**
