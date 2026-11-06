---
title: 【Redis 底层】dict 渐进式 rehash 与 SCAN 遍历语义深度解析：为什么你的 SCAN 会重复返回
date: 2026-11-06 08:00:00
tags:
  - Redis
  - 中间件
  - 数据结构
  - 面试
categories:
  - 中间件
author: 东哥
---

# 【Redis 底层】dict 渐进式 rehash 与 SCAN 遍历语义深度解析

## 前言：一次"清理脚本扫出了三次同一个 key"

线上有个 2 亿 key 的实例，要按前缀清理。写了脚本用 `SCAN cursor MATCH prefix:* COUNT 1000` 遍历，顺手做了个 `SET` 去重，结果发现**同一个 key 被扫到 3 次**，去重集合吃掉了几百 MB 内存。

同事的第一反应是"SCAN 有 bug"，第二反应是"是不是我 cursor 用错了"。

都不是。SCAN 从设计上就**只保证"从头到尾一直存在的元素至少被返回一次"，不保证不重复**。而这个保证的前提，恰恰是它内部那个极其巧妙的 **reverse binary iteration** 算法，用来应对 **dict 渐进式 rehash** 期间哈希桶的搬迁。

这两件事连在一起，构成了 Redis 里最容易被误解的一块底层机制。本文把它们讲透。

---

## 一、dict 的结构：为什么需要两张表

```c
typedef struct dict {
    dictType *type;      // 类型函数（hash/compare/destructor）
    void *privdata;
    dictht ht[2];        // 两张哈希表！
    long rehashidx;      // -1 表示不在 rehash
    int16_t pauserehash;
    unsigned long iterators; // 安全迭代器数量
} dict;

typedef struct dictht {
    dictEntry **table;   // 桶数组
    unsigned long size;  // 桶数量，2 的幂
    unsigned long sizemask; // size - 1
    unsigned long used;  // 已有节点数
} dictht;
```

为什么是 `ht[2]`？因为 rehash 时不能"一次搬完"——2 亿个 key 的 dict 一次搬完，主线程会卡死几百毫秒，Redis 是单线程的，这意味着所有客户端全部超时。

所以它选择了**渐进式**：`ht[0]` 是旧表，`ht[1]` 是新表，一个 `rehashidx` 指针记录"搬到哪个桶了"，每次操作顺手搬一点点。

---

## 二、什么时候扩容、什么时候缩容

```c
// server.c 中的定时检查（_dictExpandIfNeeded）
static int _dictExpandIfNeeded(dict *d) {
    if (dictIsRehashing(d)) return DICT_OK;       // 正在 rehash 就不重复触发
    if (d->ht[0].size == 0) return dictExpand(d, DICT_HT_INITIAL_SIZE); // 首次 4
    if (d->ht[0].used >= d->ht[0].size &&
        (dict_can_resize ||
         d->ht[0].used / d->ht[0].size > dict_force_resize_ratio)) {
        return dictExpand(d, d->ht[0].used * 2);
    }
    return DICT_OK;
}
```

三个关键点：

1. **负载因子 ≥ 1 且 `dict_can_resize` 为真 → 扩容到 `used * 2`**（2 的幂）。
2. **`dict_can_resize` 在 fork 期间被置 0**（RDB 持久化、AOF rewrite、`BGREWRITEAOF`）。原因是 fork 依赖 COW，rehash 会大规模修改内存页，导致 COW 复制量暴涨。此时只有负载因子 **> 5** 才会强行扩容。
3. **缩容**：`ht[0].used / ht[0].size < 0.1` 时触发 `dictResize`，缩到能容纳 `used` 的最小 2 的幂。

第 2 点解释了一个经典现象：**做 RDB 的时候 Redis 内存突然涨、延迟抖动**。一部分是 COW，另一部分是"该扩容了但没扩"，导致哈希冲突链变长，单次查找从 O(1) 退化到 O(n)——因为 `ht[0].size` 只有 4 而塞了 50 个 key 的时候，每个桶平均 12 个节点。

---

## 三、渐进式 rehash 的执行细节

### 3.1 搬迁节奏

每次对 dict 做增删改查时，都会调用 `_dictRehashStep`，**搬 1 个桶**（如果该桶是空链，直接把 `rehashidx` 往后推）：

```c
static void _dictRehashStep(dict *d) {
    if (d->pauserehash == 0) dictRehash(d, 1);
}
```

另外 `serverCron` 里有时间预算版的 `dictRehashMilliseconds(d, 1)`，**最多跑 1 毫秒**，防止长时间占用主线程。

搬一个桶的语义是：把 `ht[0].table[rehashidx]` 整条链上的所有节点重新算 hash、插到 `ht[1]` 对应位置，然后 `rehashidx++`。

### 3.2 期间的读写规则

这是面试高频点，四条规则必须记住：

| 操作 | 行为 |
|---|---|
| 查找 `dictFind` | **先查 `ht[0]`，再查 `ht[1]`** |
| 插入 `dictAdd` | **只插 `ht[1]`**（保证 `ht[0]` 只减不增，一定能搬完） |
| 删除 `dictDelete` | 两张表都尝试删 |
| 遍历 `dictNext` | 两张表都要遍历（先 `ht[1]` 再 `ht[0]`，避免重复） |

"插入只进 `ht[1]`"是整个算法能终止的根本保证：`ht[0].used` 单调递减，`rehashidx` 单调递增，最终必然在 `size` 步内搬完。

### 3.3 完整搬完后

```c
if (d->ht[0].used == 0) {
    zfree(d->ht[0].table);
    d->ht[0] = d->ht[1];
    _dictReset(&d->ht[1]);
    d->rehashidx = -1;
}
```

---

## 四、核心：SCAN 的 reverse binary iteration

现在进入正题。为什么 rehash 会让普通遍历失效？

### 4.1 朴素做法的灾难

假设 `size=4`（mask=0b11），你按 `0,1,2,3` 顺序遍历。走到 `2` 的时候发生了扩容到 `size=8`（mask=0b111）：

- 原本 `bucket[2]` 里的元素，会被重新分到 `bucket[2]`（如果新 hash 的低 3 位还是 010）**或 `bucket[6]`**（低 3 位是 110）。
- 你的游标已经走到 2 了，接下来走 3、4、5、6、7。`bucket[6]` 会被扫到，看起来没事。
- 但如果是**缩容**（8 → 4），原本 `bucket[6]` 的元素会被合并到 `bucket[2]`，而你已经走过 2 了 → **漏掉**。

更糟的是掩码变化时，游标语义完全变了。所以"递增游标"这条路根本走不通。

### 4.2 Redis 的解法：高位进位加法

Redis 的 `dictScan` 用了一个反直觉的技巧：**游标做"高位进位"加法（把二进制反过来，加 1，再反过来）**。

```c
unsigned long dictScan(dict *d, unsigned long v, dictScanFunction *fn, ...) {
    if (!dictIsRehashing(d)) {
        // 单表：正常扫描一个桶
        m0 = t0->sizemask;
        de = t0->table[v & m0];
        while (de) { fn(privdata, de); de = de->next; }
        // 高位进位：v |= ~m0; v = rev(v); v++; v = rev(v);
        v |= ~m0;
        v = rev(v);
        v++;
        v = rev(v);
    } else {
        // 双表：两张表都要扫，且用不同的掩码
        t0 = &d->ht[0]; t1 = &d->ht[1];
        if (t0->size > t1->size) { swap(t0, t1); }  // 保证 t0 是小的
        m0 = t0->sizemask;
        m1 = t1->sizemask;
        // 扫小表的一个桶
        de = t0->table[v & m0];
        while (de) { fn(privdata, de); de = de->next; }
        // 扫大表对应的所有桶（v | m0 但不在 m0 里的那些位）
        do {
            de = t1->table[v & m1];
            while (de) { fn(privdata, de); de = de->next; }
            v |= ~m1;
            v = rev(v); v++; v = rev(v);
        } while (v & (m0 ^ m1));  // 直到低位循环回到起点
    }
    return v;
}
```

`rev()` 是 64 位按位反转。这套操作的效果是：**游标每次在高位 +1，因此遍历顺序是 `0 → 2 → 1 → 3`（size=4 时），而不是 `0 → 1 → 2 → 3`。**

### 4.3 为什么这样就安全

核心性质：**无论表怎么扩缩容，只要掩码是 2 的幂，"高位进位"遍历序列的前缀是稳定的。**

具体说：

- `size=4` 的序列：`0, 2, 1, 3`
- `size=8` 的序列：`0, 4, 2, 6, 1, 5, 3, 7`
- `size=16` 的序列：`0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15`

看出来了吗？**`size=8` 的序列，去掉最后一位后，正好是 `size=4` 的序列的"每个元素拆成两个"。** 也就是说：如果你已经扫完了 `size=4` 序列里的 `0, 2`，那么 `size=8` 序列里的 `0, 4, 2, 6` 覆盖的桶，**恰好是原来 `0` 和 `2` 这两个桶扩容后分裂出的全部子桶**。

所以：

- **扩容**：已扫过的桶分裂成"已扫 + 未扫"两部分，未扫的部分在新的高位上，会被后续游标覆盖。**不漏。**
- **缩容**：多个桶合并，已扫过的桶合并后会被后续游标**再扫一次** → **重复**，但不漏。

这就是 SCAN 那句官方保证的由来：**"A full iteration always retrieves all the elements that were present from the start to the end of a full iteration."** 注意措辞：**从头到尾一直存在的元素**。中途被删除又加回来的不算，中途新增的可能扫不到。

### 4.4 实验验证

用 `redis-cli` 可以直接看到游标序列：

```bash
127.0.0.1:6379> scan 0 count 1
1) "2"
2) (empty array)
127.0.0.1:6379> scan 2 count 1
1) "1"
2) (empty array)
127.0.0.1:6379> scan 1 count 1
1) "3"
```

`0 → 2 → 1 → 3`，正是 4 个桶的"高位进位"序列。如果你之前疑惑过"为什么 SCAN 的游标看起来乱跳"，答案就在这里。

---

## 五、实践中的五个坑

### 5.1 COUNT 是 hint，不是精确条数

`COUNT 1000` 表示"大约扫 1000 个槽位"，实际返回条数可能远小于 1000（大量空桶），也可能大于（桶里链很长）。**永远不要写 `if (result.size() < COUNT) break;` 来判断结束**——判断结束的唯一标准是**游标回到 0**。

```java
// ✅ 正确写法
String cursor = "0";
do {
    ScanResult<String> r = jedis.scan(cursor, new ScanParams().match("prefix:*").count(500));
    cursor = r.getCursor();
    r.getResult().forEach(this::handle);
} while (!"0".equals(cursor));
```

### 5.2 MATCH 是在"返回结果"上过滤，不是扫描时过滤

`MATCH` 只对**已经取出的元素**做 glob 匹配，不影响扫描的桶数量。所以 `MATCH user:*` 在一个有 2 亿 key 的库上，**扫描量依然是全库**，只是返回得少。想减少扫描量，只能靠"分片 + 独立实例"或者用 `key` 前缀做物理隔离（不同 db 或不同实例）。

### 5.3 大 key 会让 SCAN 卡住

扫描到一个 100 万元素的 Hash，`SCAN` 本身是扫 key，不会卡；但如果你在 handler 里对每个 key 做 `HGETALL`，那就卡了。**handler 里禁止对匹配到的 key 做全量操作**，改成 `HSCAN` 分批。

### 5.4 rehash 期间的延迟尖刺

`dictRehashMilliseconds(d, 1)` 每次最多跑 1ms，看起来无害。但如果你的实例 QPS 很高，每秒会触发成百上千次 `_dictRehashStep`（每次操作都搬 1 个桶），叠加起来 CPU 有明显上浮。更麻烦的是**fork 期间不能扩容**，负载因子冲到 5 才强扩，此时冲突链极长，`GET` 的 P99 会从 0.2ms 涨到 2ms。

**对策**：把 RDB/AOF rewrite 安排在低峰；大实例拆成多实例；监控 `latest_fork_usec` 和 `dict` 相关指标。

### 5.5 别用 KEYS

`KEYS` 是一次性全量遍历，O(N) 且**阻塞主线程**。2 亿 key 的库跑 `KEYS *`，Redis 会卡死几十秒，还可能在返回结果时被 OOM Killer 干掉（结果集要一次性构建在内存里）。生产环境应该用 `rename-command KEYS ""` 直接禁掉。

---

## 六、顺带说：dict 家族的其他成员

Redis 里几乎所有"大集合"都用 dict：

| 场景 | 结构 | 编码转换阈值（redis.conf） |
|---|---|---|
| Hash | listpack → dict | `hash-max-listpack-entries 128`、`hash-max-listpack-value 64` |
| Set（整数） | intset → dict | `set-max-intset-entries 512` |
| Set（字符串） | listpack → dict | `set-max-listpack-entries 128` |
| ZSet | listpack → skiplist + dict | `zset-max-listpack-entries 128` |
| 过期字典 | 全局 dict | — |

注意 **ZSet 是"skiplist + dict"双结构**：dict 提供 O(1) 的 `ZSCORE`，skiplist 提供 O(log N) 的 `ZRANGE`。这也是为什么 ZSet 内存占用高——同样的元素存了两份。

还有一个细节：**过期字典（`expires`）也是 dict**，它和主 dict 共享 key 对象（不复制字符串，只加指针），所以 `EXPIRE` 不会让内存翻倍。但 `DBSIZE` 和 `INFO keyspace` 报的 `expires` 数量就是这张表的大小。

---

## 七、面试常见追问

**Q1：Redis 为什么不用一致性哈希或者红黑树做 dict？**

一致性哈希解决的是"节点增减时数据迁移"，Redis 单机 dict 不需要；红黑树是 O(log N) 且缓存不友好，哈希表 O(1) 且内存更省。Redis 选择"哈希表 + 链地址法 + 渐进式 rehash"，是在**单线程、低延迟、内存敏感**三个约束下的最优解。

**Q2：为什么扩容是 2 倍，而不是 1.5 倍（像 HashMap）？**

因为 SCAN 的 reverse binary iteration **依赖 `size` 是 2 的幂且扩容严格翻倍**。如果 1.5 倍扩容，掩码不再是"多一位 1"，高位进位的遍历序列就不再具有前缀稳定性，SCAN 的保证直接崩塌。这是 Redis 里"一个算法约束了整个数据结构设计"的典型案例。

**Q3：渐进式 rehash 期间，`DBSIZE` 准吗？**

准。`DBSIZE` 返回 `ht[0].used + ht[1].used`。同理 `dictSize` 也是两者相加。但 `INFO memory` 的 `used_memory` 在 rehash 期间会**上涨**，因为两张表同时存在。

**Q4：能不能强制立刻 rehash 完？**

没有官方命令。`DEBUG HTSTATS` / `DEBUG HTSTATS-KEY` 可以看 rehash 进度。想加速只能靠"多访问"（每次操作搬 1 桶）或者重启（重启后重新构建，无 rehash）。

**Q5：Redis 7 的 listpack 和 ziplist 什么关系？**

`listpack` 是 `ziplist` 的替代品，解决了 ziplist 的**连锁更新（cascade update）**问题——ziplist 每个 entry 存前一个 entry 的长度，改一个可能引发后续全部重写；listpack 改成只存自己的长度，彻底避免了这个问题。Redis 7.0 起 Hash/Set/ZSet 的小集合编码全部换成 listpack。

---

## 八、落地清单

1. **SCAN 永远用"游标回到 0"判断结束**，不要用返回条数。
2. 遍历时做**客户端去重**（Bloom filter 或 Set，注意内存成本），或者设计**幂等**的处理逻辑。
3. 生产禁用 `KEYS`，用 `rename-command` 加锁。
4. RDB/AOF rewrite 安排在低峰，避免"该扩容没扩"导致的延迟尖刺。
5. 大 key 用 `HSCAN`/`SSCAN`/`ZSCAN` 分批，不要在主循环里 `HGETALL`。
6. 监控 `used_memory` 与 `mem_fragmentation_ratio`，rehash 期间的翻倍是正常的。

Redis 的优雅之处就在于这类地方：为了一个"遍历不漏"的保证，它把一个看起来随便的哈希表设计得极其克制——扩容必须翻倍、掩码必须是 2 的幂、游标必须高位进位。理解了约束，你就理解了设计。
