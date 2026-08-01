---
title: 一致性哈希算法原理与 Java 实现：从哈希环到虚拟节点
date: 2026-08-01 08:40:00
tags:
  - 一致性哈希
  - 分布式
  - 算法
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 一致性哈希算法原理与 Java 实现：从哈希环到虚拟节点

"一致性哈希"是分布式系统面试中出镜率最高的算法之一：分布式缓存、负载均衡、分布式存储路由，处处都有它的身影。但很多同学只记住了"哈希环"三个字，被追问到虚拟节点、数据倾斜、增减节点的影响时就卡壳。本文从传统取模的痛点讲起，手写一个生产可用的 Java 实现，最后对比 Redis Cluster 的哈希槽方案。

<!-- more -->

## 一、传统取模哈希的致命缺陷

假设有 3 台缓存服务器，最简单的路由策略是：

```java
int serverIndex = hash(key) % 3;   // 0、1、2
```

问题在**节点增减时暴露无遗**：

| 场景 | 操作 | 缓存命中率 |
|------|------|-----------|
| 3 台 → 4 台（扩容） | `hash % 4` | 约 **25%**（只有 1/4 的 key 落在原节点） |
| 3 台 → 2 台（缩容） | `hash % 2` | 约 **33%** |

扩容一台机器，**75% 的缓存 key 都要重新映射**，相当于缓存整体失效，大量请求直接打到数据库——这在生产上是灾难性的。

**核心矛盾**：取模哈希中，节点数变化会导致映射关系"全面洗牌"。一致性哈希的目标就是：**节点变化时，只有少量 key 需要迁移**。

## 二、一致性哈希原理：哈希环

### 1. 构建哈希环

把哈希函数的输出值域（如 0 ~ 2³²-1）首尾相接，形成一个**环**：

```
        0
    4096   1024
  3072        2048   ← 服务器节点按 hash(IP) 落在这个环上
```

**服务器节点**：对每个节点计算 `hash(node)`（如 `hash("192.168.1.1")`），映射到环上。

**数据 key**：对 key 计算 `hash(key)`，映射到环上，然后**沿环顺时针查找**，遇到的第一个节点就是它的归属节点。

### 2. 节点增减只影响局部

- **增加节点 D**：D 落在 A 与 C 之间，那么原来属于 C、且位于 (A, D] 区间的 key 会迁移到 D，**其他 key 完全不动**
- **删除节点 C**：C 上的 key 全部顺时针交给下一个节点 D，其他节点不受影响

| 方案 | 增加 1 节点时 key 迁移比例 |
|------|---------------------------|
| 取模哈希 | 75%（3→4） |
| 一致性哈希 | 1/N（约 25%→ 但只迁移区间内） |

严格说，一致性哈希增减节点时，迁移比例约为 `1/N`（环上一个区间），远小于取模的 `(N-1)/N`。

### 3. 但朴素实现有一个大问题：数据倾斜

如果节点少（比如只有 3 台），hash 后节点在环上的分布可能很不均匀——两台挤在一起，一台孤零零，导致**某些节点数据多、某些节点压力大**。解决思路就是**虚拟节点**。

## 三、虚拟节点：解决数据倾斜

**思路**：每个物理节点在环上放置多个"虚拟节点"（副本），比如 150 个，每个虚拟节点通过 `hash(ip + "#" + i)` 计算位置。这样：

- 环上的节点数量从 3 变成 450，分布趋于均匀
- 数据倾斜被抹平：每个物理节点承载的区间大致相等
- 一个物理节点挂掉，它的多个虚拟节点由多个不同节点接管，**故障影响被分摊**，不会"独吞"

```java
// 虚拟节点示意：物理节点 192.168.1.1 生成 150 个虚拟节点
for (int i = 0; i < 150; i++) {
    ring.put(hash("192.168.1.1#" + i), "192.168.1.1");
}
```

虚拟节点数量经验值：**每物理节点 100~200 个**，太少不均匀，太多浪费内存（每个虚拟节点是 TreeMap 的一个 Entry）。

## 四、Java 手写实现（可直接用）

核心数据结构：`TreeMap<Long, String>`（红黑树），天然支持"顺时针找第一个 >= key 的节点"。

```java
import java.util.SortedMap;
import java.util.TreeMap;

/**
 * 一致性哈希（带虚拟节点）
 */
public class ConsistentHash<T> {

    private final TreeMap<Long, T> ring = new TreeMap<>();   // 哈希环
    private final int virtualNodes;                          // 每节点虚拟节点数
    private final HashFunction hashFunc;

    public ConsistentHash(Collection<T> nodes, int virtualNodes, HashFunction hashFunc) {
        this.virtualNodes = virtualNodes;
        this.hashFunc = hashFunc;
        for (T node : nodes) {
            addNode(node);
        }
    }

    /** 添加节点：为它生成 virtualNodes 个虚拟节点 */
    public void addNode(T node) {
        for (int i = 0; i < virtualNodes; i++) {
            long h = hashFunc.hash(node.toString() + "#" + i);
            ring.put(h, node);
        }
    }

    /** 删除节点：移除它的所有虚拟节点 */
    public void removeNode(T node) {
        for (int i = 0; i < virtualNodes; i++) {
            long h = hashFunc.hash(node.toString() + "#" + i);
            ring.remove(h);
        }
    }

    /** 路由：找到 key 顺时针遇到的第一个节点 */
    public T getNode(String key) {
        if (ring.isEmpty()) {
            return null;
        }
        long h = hashFunc.hash(key);
        SortedMap<Long, T> tailMap = ring.tailMap(h);   // 大于等于 h 的子环
        Long nodeHash = tailMap.isEmpty() ? ring.firstKey() : tailMap.firstKey();
        return ring.get(nodeHash);
    }

    @FunctionalInterface
    public interface HashFunction {
        long hash(String key);
    }

    // 推荐使用 MurmurHash（分布均匀），别用 String.hashCode
    public static HashFunction murmur3() {
        // 示例：可用 Guava 的 Hashing.murmur3_32()
        return key -> Hashing.murmur3_32().hashString(key, StandardCharsets.UTF_8).asInt() & 0xFFFFFFFFL;
    }
}
```

使用示例：

```java
List<String> servers = List.of("192.168.1.1:6379", "192.168.1.2:6379", "192.168.1.3:6379");
ConsistentHash<String> ch = new ConsistentHash<>(servers, 150, ConsistentHash.murmur3());

String server = ch.getNode("user:10001");   // 路由到具体缓存节点
```

### 为什么不用 String.hashCode()？

Java 的 `String.hashCode()` 分布质量差（尤其短字符串），会导致哈希环上节点聚集，加剧倾斜。生产上优先用 **MurmurHash**（Guava 提供）或 FNV、MD5 截断。

## 五、应用场景盘点

| 场景 | 如何用 |
|------|--------|
| 分布式缓存路由 | 客户端一致性哈希选 Redis/ Memcached 节点，扩容只迁移 1/N 数据 |
| 负载均衡 | 按用户 ID 哈希到固定后端，**同一用户粘性路由**（session 保持） |
| 分布式存储 | Cassandra 的 vnode、一致性哈希的典型应用；HDFS 副本放置策略也有其思想 |
| 分库分表 | 按取模分表扩容痛苦，可结合一致性哈希做平滑扩容（配合迁移工具） |
| CDN 边缘节点 | 请求按内容哈希路由到就近节点 |

## 六、一致性哈希 vs Redis Cluster 哈希槽

面试高频对比题：

| 维度 | 一致性哈希 | Redis Cluster 哈希槽 |
|------|-----------|---------------------|
| 基本思想 | 环形空间，顺时针查找 | 固定 16384 个槽，key 映射到槽，槽分配给节点 |
| 数据迁移 | 节点增减时迁移区间内数据 | 槽的批量迁移（MIGRATE），粒度更细 |
| 虚拟节点 | 用虚拟节点解决倾斜 | 槽本身天然均匀，无需虚拟节点 |
| 客户端复杂度 | 客户端实现路由逻辑 | 客户端借助 cluster 协议，节点间互相感知 |
| 适用场景 | 通用分布式路由 | 专为 Redis 设计 |

哈希槽本质是"**把一致性哈希的环离散化成固定 16384 个点**"，槽的数量固定，节点增减只是槽的重新分配，迁移粒度是"槽"而不是"任意区间"，实现和运维都更可控。

## 七、面试官追问

**Q1：一致性哈希为什么能做到只迁移少量数据？**
答：因为 key 到节点的映射不再依赖节点总数取模，而是依赖"key 在环上的位置 + 顺时针第一个节点"。节点增减只改变环上局部区间的归属，只有落在这个区间的 key 才受影响，其他 key 的最近节点不变。

**Q2：虚拟节点解决了什么问题？还有别的作用吗？**
答：主要是解决节点少时的数据倾斜；另外还能让故障影响均匀分摊（一个物理节点挂了，它的虚拟节点分散在环上，由多个节点接管，而不是某一个节点突然吃下全部流量）。

**Q3：如果节点不均匀，如何评估？**
答：可以统计每个物理节点负责的区间长度/key 数量，计算标准差。标准差大说明倾斜严重，可增加虚拟节点数量或引入"加权虚拟节点"（性能强的机器放更多虚拟节点，实现异构权重）。

**Q4：一致性哈希的缺陷有哪些？**
答：① 数据倾斜仍需虚拟节点缓解，无法完全消除；② 节点增减瞬间存在部分 key 路由到新节点但数据未迁移完成的问题，需要配合缓存双写/兜底；③ 哈希环上的"哈希碰撞"理论存在但概率极低；④ 相比哈希槽，迁移粒度较粗，运维可控性略差。

## 总结

一致性哈希是分布式路由的基石算法：**环形空间 + 顺时针查找 + 虚拟节点**三大要素缺一不可。面试时建议主动画出环、讲清节点增减的影响范围，再对比哈希槽方案——能讲透这几点，基本就稳了。文中实现的 ConsistentHash 类可以直接抄进项目，记得用 MurmurHash。
