---
title: 【Redis 原理】跳表与 ZSet 深度解析：从 Skip List 数据结构到有序集合源码
date: 2026-08-08 08:00:00
tags:
  - Redis
  - 跳表
  - ZSet
  - 数据结构
  - 面试
categories:
  - 中间件
  - Redis
author: 东哥
---

# 【Redis 原理】跳表与 ZSet 深度解析：从 Skip List 数据结构到有序集合源码

## 面试官：Redis 的 ZSet 底层为什么用跳表，不用红黑树？

这是 Redis 面试中出现频率极高的追问。很多人能背出"ZSet = 哈希表 + 跳表"，但当面试官继续问"跳表为什么不用红黑树""跳表的层数怎么确定""ZSet 什么时候退化成 ziplist/listpack"时，就开始含糊其辞了。

本文从数据结构本身讲起，再到 Redis 源码（t_zset.c / server.h），彻底拆解跳表与 ZSet。

<!-- more -->

## 一、为什么需要跳表：有序数据结构的进化史

### 1.1 有序集合的基本需求

ZSet 需要支持的操作：

| 操作 | 复杂度要求 |
| --- | --- |
| 按分数插入 / 删除 / 更新 | O(logN) |
| 按分数区间查询（ZRANGEBYSCORE） | O(logN + M) |
| 按排名查询（ZRANK） | O(logN) |
| 取最大值 / 最小值（ZPOPMAX/ZPOPMIN） | O(logN) |

能满足这些需求的候选数据结构有：**平衡二叉树（红黑树）、B+ 树、跳表**。Redis 选择了跳表，主要因为：

1. **实现简单**：红黑树插入后的旋转、变色逻辑极其复杂，而跳表本质是"带索引的有序链表"，几十行就能实现；
2. **区间查询友好**：跳表按序访问时只需沿底层链表顺序遍历，红黑树需要中序遍历（含栈/递归回溯）；
3. **并发友好**：跳表支持高效的局部更新，且更容易实现无锁版本（LevelDB、ConcurrentSkipListMap 都证明了这一点）；
4. **层数随机化**：不需要像红黑树那样做全局平衡调整。

### 1.2 跳表的结构

跳表 = 有序链表 + 多层索引：

```
level 3:  head ────────────────→ 60 ──────────────→ NULL
level 2:  head ───────→ 30 ────→ 60 ──────→ 90 ──→ NULL
level 1:  head ──→ 10 ──→ 30 ──→ 60 ──→ 70 ──→ 90 ──→ NULL
底层:     head → 10 → 20 → 30 → 40 → 60 → 70 → 80 → 90 → NULL
```

查找过程：从最高层开始，向右走直到"下一个节点大于目标"，然后降一层继续。每层跳过一半节点，所以查找复杂度 O(logN)。

## 二、跳表的数学原理：为什么层数是随机的

### 2.1 层数生成：抛硬币

每个新节点插入时，层数通过"抛硬币"决定：初始 1 层，每次有 1/2 概率加一层：

```c
// Redis 源码 t_zset.c 中的 zslRandomLevel
int zslRandomLevel(void) {
    int level = 1;
    // ZSKIPLIST_P = 0.25，即 1/4 概率升层
    while ((random() & 0xFFFF) < (ZSKIPLIST_P * 0xFFFF))
        level += 1;
    return (level < ZSKIPLIST_MAXLEVEL) ? level : ZSKIPLIST_MAXLEVEL;
}
```

Redis 把概率 P 设为 **0.25**（而不是经典的 0.5），层数分布更"瘦高"，在内存和查找效率之间取得平衡：

| 层数 | 概率（P=0.25） |
| --- | --- |
| 1 | 75% |
| 2 | 18.75% |
| 3 | 4.69% |
| ≥ 4 | 1.56% |

### 2.2 为什么随机层数依然能保证 O(logN)？

这是跳表最反直觉的地方：**层数是随机的，但期望复杂度是有保证的**。

- 每个节点出现在第 k 层的概率是 p^(k-1)，所以第 k 层期望节点数为 n·p^(k-1)；
- 从最高层逐层下降，每层期望只需走 O(1/p) 步；
- 总层数期望为 O(log(1/p) N)，因此**期望查找、插入、删除复杂度都是 O(logN)**。

概率保证代替了确定性平衡——这就是跳表"用随机换简单"的精髓。极端情况下（所有节点都只有 1 层）退化成链表 O(N)，但概率无限趋近于 0，实践中完全可接受。

## 三、Redis ZSet 源码级拆解

### 3.1 ZSet 的整体结构

Redis 7.0 之前，ZSet 有两种底层编码：

```c
// server.h
typedef struct zset {
    dict *dict;          // 哈希表：member -> score，用于 O(1) 按成员查分数
    zskiplist *zsl;      // 跳表：按 score 排序，用于区间查询和排名
} zset;
```

- **dict**：解决"按 member 查 score"（ZSCORE）O(1) 的问题；
- **zskiplist**：解决"按分数排序、区间、排名"的问题。

**为什么必须两个结构一起用？** 只有跳表的话，ZSCORE 需要 O(logN)；只有哈希表的话，无法按分数排序。两者组合，各取所长，代价是插入时双写（内存换性能）。

### 3.2 跳表节点结构

```c
typedef struct zskiplistNode {
    sds ele;                    // 成员（member），字符串
    double score;               // 分数
    struct zskiplistNode *backward;  // 后退指针，指向底层前一个节点
    struct zskiplistLevel {
        struct zskiplistNode *forward; // 前进指针
        unsigned long span;            // 跨度：本层跨越多少个节点
    } level[];                  // 柔性数组，每层一个指针+跨度
} zskiplistNode;

typedef struct zskiplist {
    struct zskiplistNode *header, *tail; // 头尾哨兵
    unsigned long length;       // 节点总数
    int level;                  // 当前最大层数
} zskiplist;
```

**span（跨度）字段是关键设计**：`ZRANK`（按成员查排名）和 `ZREVRANK` 之所以是 O(logN)，就是因为查找时沿途累加每层的 span，直接得到排名，而**不需要从头遍历链表**。

### 3.3 插入流程（zslInsert）

```c
zskiplistNode *zslInsert(zskiplist *zsl, double score, sds ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL];  // 每层待更新前驱
    unsigned long rank[ZSKIPLIST_MAXLEVEL];     // 每层前驱的排名
    // 1. 从最高层向下查找插入位置，记录每层前驱和排名
    // 2. 生成随机层数
    int level = zslRandomLevel();
    // 3. 如果新层数超过当前最大层，初始化新层
    // 4. 创建节点，逐层插入，更新 span 和 backward
    // 5. 更新头节点和长度
}
```

排序规则（重要细节）：
1. 先按 **score 升序**；
2. score 相同时按 **member 的字典序（memcmp）** 排序。

这就是为什么 ZRANGE 在分数相同时输出稳定有序。

### 3.4 编码切换：什么时候不用跳表？

| Redis 版本 | 小数据量编码 | 阈值 |
| --- | --- | --- |
| ≤ 7.0 | ziplist（压缩列表） | 元素 ≤ 128 且 每个元素长度 ≤ 64 字节 |
| ≥ 7.0 | listpack（紧凑列表） | 元素 ≤ 128 且 每个元素长度 ≤ 64 字节 |

```c
// t_zset.c
static char *zsetTypeGetEncoding... // 判断逻辑：
// zset_max_listpack_entries = 128
// zset_max_listpack_value = 64
```

当元素数或单元素大小超过阈值，自动转换为 `zset`（dict + 跳表），且**不可逆**（不会转回 listpack）。可以通过配置调整：

```
zset-max-listpack-entries 128
zset-max-listpack-value   64
```

> **面试追问：为什么小数据量不用跳表？** listpack 是连续内存、按序紧凑排列，128 个元素以内线性扫描 O(N) 和跳表 O(logN) 差距可忽略，但内存占用跳表是 listpack 的几倍（每个节点要存多层指针 + span + backward）。空间换时间的工程取舍。

## 四、跳表 vs 红黑树 vs B+ 树：终极对比

| 维度 | 跳表 | 红黑树 | B+ 树 |
| --- | --- | --- | --- |
| 实现复杂度 | 低（~百行） | 高（旋转+变色） | 中（分裂/合并） |
| 查找 | O(logN) 期望 | O(logN) 最坏 | O(logN)，但层高更矮 |
| 区间遍历 | 极好（底层链表） | 差（中序遍历） | 极好（叶节点链表） |
| 范围删除 | 简单（断链） | 复杂（逐个删除） | 简单 |
| 磁盘友好 | 否 | 否 | 是（页节点存储） |
| Redis 用途 | ZSet 排序索引 | 无（Redis 不用红黑树） | 无（MySQL InnoDB 用） |

**一句话总结**：内存场景选跳表（简单+区间友好），磁盘场景选 B+ 树（页大小 IO 友好），需要严格最坏复杂度保证的场景选红黑树。

## 五、实战：用 Java 手写一个迷你跳表

理解源码最好的方式是手写。下面实现一个支持插入、查找、删除的简单跳表：

```java
public class SkipList {
    private static final int MAX_LEVEL = 32;
    private static final double P = 0.25;
    private final Node head = new Node(Integer.MIN_VALUE, MAX_LEVEL);
    private int level = 1;

    static class Node {
        int val;
        Node[] next;   // 每层下一个节点
        Node(int val, int level) {
            this.val = val;
            this.next = new Node[level];
        }
    }

    private int randomLevel() {
        int lv = 1;
        while (Math.random() < P && lv < MAX_LEVEL) lv++;
        return lv;
    }

    public void insert(int val) {
        Node[] update = new Node[MAX_LEVEL];
        Node cur = head;
        for (int i = level - 1; i >= 0; i--) {
            while (cur.next[i] != null && cur.next[i].val < val) {
                cur = cur.next[i];
            }
            update[i] = cur;   // 记录每层待插入位置
        }
        int newLevel = randomLevel();
        if (newLevel > level) {
            for (int i = level; i < newLevel; i++) update[i] = head;
            level = newLevel;
        }
        Node node = new Node(val, newLevel);
        for (int i = 0; i < newLevel; i++) {
            node.next[i] = update[i].next[i];
            update[i].next[i] = node;
        }
    }

    public boolean search(int val) {
        Node cur = head;
        for (int i = level - 1; i >= 0; i--) {
            while (cur.next[i] != null && cur.next[i].val < val) {
                cur = cur.next[i];
            }
        }
        cur = cur.next[0];
        return cur != null && cur.val == val;
    }

    public boolean delete(int val) {
        Node[] update = new Node[MAX_LEVEL];
        Node cur = head;
        for (int i = level - 1; i >= 0; i--) {
            while (cur.next[i] != null && cur.next[i].val < val) {
                cur = cur.next[i];
            }
            update[i] = cur;
        }
        cur = cur.next[0];
        if (cur == null || cur.val != val) return false;
        for (int i = 0; i < level; i++) {
            if (update[i].next[i] == cur) update[i].next[i] = cur.next[i];
        }
        while (level > 1 && head.next[level - 1] == null) level--;
        return true;
    }
}
```

这段代码与 Redis 的 `zslInsert` / `zslDelete` 逻辑同构：从高层向下找位置、记录每层前驱、更新指针。能独立写出来，说明你真的懂了。

## 六、ZSet 经典使用场景

| 场景 | 命令设计 |
| --- | --- |
| 排行榜（日榜/周榜/总榜） | `ZADD rank:total 100 user:1`，`ZREVRANGE rank:total 0 9 WITHSCORES` |
| 延迟队列 | score 存执行时间戳，`ZRANGEBYSCORE` 取到期任务 |
| 滑动窗口限流 | score 存时间戳，配合 `ZREMRANGEBYSCORE` 清理过期窗口 |
| 商品销量排序 | score 存销量，销量变化 `ZINCRBY` |
| 在线用户心跳 | score 存最后活跃时间，定期 `ZREMRANGEBYSCORE` 清理超时用户 |

## 七、总结

- **跳表 = 有序链表 + 随机多层索引**，用随机化换取 O(logN) 期望复杂度和极简实现；
- **ZSet = dict + 跳表**，dict 负责 O(1) 查分，跳表负责有序区间与排名；
- **span 跨度**让 ZRANK 达到 O(logN)；
- **小数据用 listpack，大数据转跳表**，阈值 128 元素 / 64 字节；
- 面试对比结论：**内存选跳表、磁盘选 B+ 树、最坏复杂度敏感选红黑树**。

下次面试官再问"ZSet 为什么用跳表"，你可以从实现复杂度、区间查询、并发扩展、内存模型四个维度展开，最后补一句："其实 MySQL 的 InnoDB 不用跳表而用 B+ 树，是因为磁盘顺序 IO 和页大小的原因"——这一句话，就能让面试官知道你不仅懂 Redis，还懂数据库。
