---
title: 【Redis原理】Redis 内存模型与对象编码系统深度解析：从 SDS 到 quicklist 的内部实现
date: 2026-07-27 08:00:00
tags:
  - Redis
  - 内存模型
  - 数据编码
  - SDS
categories:
  - 中间件
  - Redis
author: 东哥
---

# 【Redis原理】Redis 内存模型与对象编码系统深度解析：从 SDS 到 quicklist 的内部实现

## 前言

"Redis 为什么快？"是面试中的经典问题。大多数人都能答出"基于内存、单线程、IO 多路复用"——但很少有人能深入到底层**数据结构和编码方式**。

Redis 的高性能不仅来自"在内存中运行"，更来自**对内存的极致利用**——它针对不同场景设计了多种编码方式，在性能和内存占用之间做精细的取舍。

本文将从源码角度，深入剖析 Redis 的对象系统与底层编码实现。

---

## 一、Redis 对象系统架构

### 1.1 redisObject 结构体

Redis 中的所有键值对，最终都封装在 `redisObject` 中：

```c
// Redis 源码：server.h
typedef struct redisObject {
    unsigned type:4;       // 对象类型：STRING、LIST、HASH、SET、ZSET
    unsigned encoding:4;   // 编码方式：RAW、INT、EMBSTR、HT、LINKEDLIST、ZIPLIST...
    unsigned lru:24;       // LRU 时间戳（用于内存淘汰）
    int refcount;          // 引用计数（用于内存回收）
    void *ptr;             // 指向实际数据的指针
} robj;
```

每个 Redis 键值对都是一次 `redisObject` 的分配，这也是为什么**小对象越多，Redis 内存开销越大**的原因——每个对象有 16 字节的固定头开销。

### 1.2 类型与编码的对应关系

| 对象类型 | 可选编码 | 触发条件 |
|---------|---------|---------|
| STRING | INT / EMBSTR / RAW | 根据值的长度和能否转为整数 |
| LIST | QUICKLIST（3.2+ 替代了 ZIPLIST 和 LINKEDLIST） | 统一使用 QUICKLIST |
| HASH | ZIPLIST / HASHTABLE | field-value 数量 < 512 且每个长度 < 64 字节 |
| SET | INTSET / HASHTABLE | 元素全为整数且数量 < 512 |
| ZSET | ZIPLIST / SKIPLIST | 元素数量 < 128 且每个长度 < 64 字节 |

> 这些阈值可以通过配置修改：`hash-max-ziplist-entries`、`set-max-intset-entries`、`zset-max-ziplist-entries` 等。

---

## 二、STRING 编码详解

### 2.1 INT 编码

```c
// SET key 10086 → 使用 INT 编码
typedef struct redisObject {
    type: REDIS_STRING,
    encoding: REDIS_ENCODING_INT,
    ptr: (void*)(long)10086  // 指针直接存整数，不走 SDS
}
```

当字符串值能被解析为**有符号 64 位整数**（-2^63 ~ 2^63-1）时，Redis 直接将其存储在 `ptr` 指针字段中。**零额外内存分配**，堪称最省内存的编码。

```bash
> SET num 42
> OBJECT ENCODING num
"int"
```

### 2.2 EMBSTR 编码

```bash
> SET name "hello"
> OBJECT ENCODING name
"embstr"
```

EMBSTR 是**嵌入式字符串**的缩写。它的特点是：

- 一次 `malloc` 分配一块连续内存
- `redisObject` 和 `sdshdr` 结构体在同一个内存块中
- 适合长度 **<= 44 字节**的字符串

为什么是 44 字节？因为 Redis 默认内存分配器（jemalloc/tcmalloc）的内存分配单元通常是 64 字节：

```
redisObject (16B) + sdshdr (3B + 数据 + 1B 结束符) <= 64B
```

计算：16 + 3 + data + 1 = 20 + data ≤ 64 → data ≤ 44

### 2.3 RAW 编码

当字符串长度超过 44 字节时，Redis 使用 RAW 编码：

```c
// RAW 编码需要两次 malloc：
// 1. 分配 redisObject
// 2. 分配 SDS 结构
// 两个内存块不连续
```

```bash
> SET long_str "这是一段超过44字节的字符串内容，需要使用RAW编码来存储..."
> OBJECT ENCODING long_str
"raw"
```

### 2.4 SDS（Simple Dynamic String）结构

SDS 是 Redis 自建的字符串实现，相比 C 字符串做了大量优化。

**SDS 结构（Redis 3.2+ 分为 5 种类型）：**

```c
// 以 sdshdr8 为例
struct __attribute__ ((__packed__)) sdshdr8 {
    uint8_t len;       // 已使用长度
    uint8_t alloc;     // 分配的总长度（不含头和空结束符）
    unsigned char flags; // 低3位表示类型，高5位保留
    char buf[];        // 实际数据
};
```

**SDS 对比 C 字符串的优势：**

| 特性 | C 字符串 | SDS |
|------|---------|-----|
| 获取长度 | O(n)，需遍历 | O(1)，直接读 len 字段 |
| 二进制安全 | 否，以 '\0' 结束 | 是，以 len 为准 |
| 缓冲区溢出 | 可能，不检查边界 | 自动扩容，预分配 |
| 修改时重分配 | 每次修改都需要 | 预分配策略减少重分配次数 |
| 兼容 C 函数 | 是 | 是（buf 数组后有空结束符） |

**预分配策略**：当 SDS 扩容时，如果新长度小于 1MB，分配 `2 × 新长度` 的空间；如果大于 1MB，分配 `新长度 + 1MB`。这种**空间换时间**的策略显著减少了字符串修改时的内存重分配次数。

---

## 三、LIST 编码：QUICKLIST

Redis 3.2 之后，LIST 统一使用 **quicklist** 编码，取代了之前的 ziplist 和 linkedlist。

### 3.1 quicklist 结构

```c
typedef struct quicklist {
    quicklistNode *head;    // 头节点
    quicklistNode *tail;    // 尾节点
    unsigned long count;    // 所有 ziplist 中的元素总数
    unsigned long len;      // quicklistNode 数量
    int fill : 16;          // 单个节点允许的 ziplist 大小
    unsigned int compress : 16; // 压缩深度（两端不压缩）
} quicklist;
```

每个 quicklistNode 包含一个 **ziplist**（压缩列表）：

```c
typedef struct quicklistNode {
    struct quicklistNode *prev;  // 前驱指针
    struct quicklistNode *next;  // 后继指针
    unsigned char *zl;           // 指向 ziplist
    unsigned int sz;             // ziplist 字节数
    unsigned int count : 16;     // ziplist 中元素数
    unsigned int encoding : 2;   // RAW=1, LZF=2
    unsigned int container : 2;  // NONE=1, ZIPLIST=2
    unsigned int recompress : 1; // 重新压缩标记（用于中间节点）
    unsigned int attempted_compress : 1;
    unsigned int extra : 10;
} quicklistNode;
```

### 3.2 quicklist 设计哲学

quicklist 是**链表 + 压缩列表的混合体**：

- 每个节点内部是一个 ziplist（紧凑内存）
- 节点之间通过双向指针链接（支持两端高效操作）
- 可配置每个 ziplist 的大小（`list-max-ziplist-size`）
- 可以对中间节点进行 LZF 压缩（`list-compress-depth`）

这样既获得了链表的 O(1) 两端操作，又获得了 ziplist 的高内存利用率，是"既要又要"的典范。

```bash
> LPUSH mylist a b c d e f
> OBJECT ENCODING mylist
"quicklist"

# 查看 quicklist 统计信息
> DEBUG QUICKLIST mylist
```

---

## 四、HASH 编码：ZIPLIST vs HASHTABLE

### 4.1 ZIPLIST 编码

当 HASH 的 field-value 数量小于 512 且每个 field/value 长度小于 64 字节时，使用 ziplist 编码。

**ziplist 的内存布局：**

```
<zlbytes><zltail><zllen><entry1><entry2>...<entryN><zlend>
```

每个 entry 的编码方式：

```
<prevlen><encoding><data>
```

- **prevlen**：前一个 entry 的长度（1 或 5 字节），用于反向遍历
- **encoding**：数据的编码类型（整数或字符串及其长度）
- **data**：实际数据

ziplist 将 HASH 的 field 和 value **交替存储**在一个连续内存块中：

```
[zlbytes][zltail][zllen]["name"]["东哥"]["age"]["28"]["dept"]["技术"]
```

**优点**：极省内存，缓存的局部性好
**缺点**：修改操作可能导致连锁更新（因为 prevlen 变化引起后续所有 entry 的 prevlen 调整）

### 4.2 HASHTABLE 编码

当 HASH 超过 ziplist 的限制后，自动转换为 hashtable：

```c
typedef struct dict {
    dictType *type;      // 类型特定函数
    void *privdata;      // 私有数据
    dictht ht[2];       // 两个哈希表（用于渐进式 rehash）
    long rehashidx;      // rehash 进度，-1 表示未进行
    int16_t pauserehash; // rehash 是否暂停
} dict;
```

**渐进式 rehash**：Redis 的 rehash 不是一次性完成的，而是**分批进行**：

```
rehash 过程：
1. 为 ht[1] 分配 ht[0] 两倍大小的空间
2. 设置 rehashidx = 0
3. 每次对 dict 执行增删改查时，顺带将 ht[0] 在 rehashidx 位置上的
   所有 entry 迁移到 ht[1]，然后 rehashidx++
4. 全部迁移完成，rehashidx = -1，ht[0] = ht[1]，ht[1] 清空
```

这种设计避免了**一次 rehash 导致的服务停顿**，适合 Redis 的单线程模型。

```bash
> HSET user name "东哥" age "28" dept "技术"
> OBJECT ENCODING user
"ziplist"

# 添加大量字段触发编码转换
> HSET user f1 v1 f2 v2 ... f513 v513
> OBJECT ENCODING user
"hashtable"
```

---

## 五、SET 编码：INTSET vs HASHTABLE

### 5.1 INTSET 编码

当 SET 中所有元素都是整数且数量不超过 512 时，使用 intset：

```c
typedef struct intset {
    uint32_t encoding;  // 编码：INTSET_ENC_INT16/INT32/INT64
    uint32_t length;    // 元素数量
    int8_t contents[];  // 元素数组（按 encoding 升序排列）
} intset;
```

intset 的特点：

- **有序排列**，支持二分查找（O(log n)）
- **自动升级**编码：如果所有元素都在 int16 范围内用 2 字节存，加入 int32 值后升级为 4 字节
- **不支持降级**：一旦升级，删除所有大整数也不会降回来

```bash
> SADD myset 1 2 3 100
> OBJECT ENCODING myset
"intset"

> SADD myset 100000  # 还在 int16 范围内吗？否，将升级为 int32
> OBJECT ENCODING myset
"intset"             # 编码类型不变，但内部的 encoding 升级了

> SADD myset "hello" # 加入字符串，超出 intset 范围
> OBJECT ENCODING myset
"hashtable"          # 转化为 hashtable
```

---

## 六、ZSET 编码：ZIPLIST vs SKIPLIST

### 6.1 SKIPLIST 编码

跳表是 ZSET 的核心数据结构（当数量超过 128 或元素长度超过 64 字节时使用）：

```c
typedef struct zskiplistNode {
    sds ele;                    // 成员对象（字符串）
    double score;               // 分值
    struct zskiplistNode *backward; // 后退指针
    struct zskiplistLevel {
        struct zskiplistNode *forward; // 前进指针
        unsigned long span;     // 跨度
    } level[];                  // 层级数组
} zskiplistNode;

typedef struct zskiplist {
    struct zskiplistNode *header, *tail; // 头尾指针
    unsigned long length;       // 节点数量
    int level;                  // 最大层数
} zskiplist;
```

**为什么用跳表而不是平衡树？**

| 对比维度 | SkipList | 平衡树（AVL/红黑树） |
|---------|----------|-------------------|
| 范围查询 | 沿链表遍历即可 | 需要中序遍历 |
| 插入/删除 | 不需要 rebalance | 需要旋转维持平衡 |
| 实现复杂度 | 简单 | 复杂 |
| 内存 | 平均 O(1.5n) 指针 | 左右子节点指针 |
| 查找 | O(log n) | O(log n) |

跳表在实现简单的同时，提供了不亚于平衡树的性能，而且范围查询更高效——这让它成为 ZSET 的理想选择。

### 6.2 ZSET 同时使用跳表和哈希表

ZSET 实际上**同时使用跳表和哈希表**：

```c
typedef struct zset {
    dict *dict;         // 成员→分值的映射（O(1) 查分）
    zskiplist *zsl;     // 分值和成员的排序结构（范围操作）
} zset;
```

这种双结构设计让 ZSET 既能 O(1) 查询某个成员的分数，又能高效执行范围查询（ZRANGEBYSCORE）。

---

## 七、内存优化实战建议

### 7.1 选择合适的编码

```bash
# 合理配置编码阈值
config set hash-max-ziplist-entries 1024  # 可根据实际场景调整
config set set-max-intset-entries 1024
config set zset-max-ziplist-entries 256
```

### 7.2 避免大对象

```bash
# 一个 10MB 的字符串是危险的
# - 读写阻塞时间长
# - 内存碎片增加
# - 主从同步带宽压力大

# 建议拆分为多个小 key，或使用 hash 分片
```

### 7.3 内存分析命令

```bash
# 查看 key 的内存占用
> MEMORY USAGE mykey

# 查看 key 的编码
> OBJECT ENCODING mykey

# 查看 key 的空闲时间
> OBJECT IDLETIME mykey

# 查看所有 key 的内存统计
> MEMORY STATS

# 诊断内存问题
> MEMORY DOCTOR
```

---

## 八、面试追问

**问：为什么 EMBSTR 最大长度是 44 字节？**

因为 redisObject 占 16 字节，sdshdr8 头占 3 字节，加上空结束符 1 字节，jemalloc 的 64 字节分配单元下：64 - 16 - 3 - 1 = 44。

**问：ziplist 的连锁更新是什么？如何避免？**

当 ziplist 中某个 entry 被修改，导致其长度从 <254 变为 >=254 时，prevlen 字段从 1 字节变为 5 字节，引起后续所有 entry 的 prevlen 字段连锁调整。避免方式是控制每个 ziplist 的大小，或使用 quicklist 限制单个 ziplist 的 entry 数量。

**问：渐进式 rehash 有什么缺点？**

1. 需要维护两个哈希表，**内存峰值**是平时的两倍
2. 每次操作都有少量额外开销（判断 rehash 状态并迁移一个 bucket）
3. 如果写入量小，rehash 可能长时间无法完成

**问：为什么 ZSET 用跳表而不是红黑树？**

因为跳表的范围查询可以沿 level[0] 的 forward 指针顺序遍历，而红黑树需要栈或递归进行中序遍历。此外跳表的并发实现也更简单。

---

## 总结

Redis 的内存模型是它的"第二层血液"——第一层是"在内存中运行"，第二层就是"怎么高效地使用内存"。从 SDS 到 quicklist，从 ziplist 到跳表，每种编码都是在特定场景下的最优解。

理解这些底层实现，不仅有助于面试通关，更重要的是能让生产环境中做出更合理的 Redis 数据建模决策：
- 小 HASH 用 ziplist 编码省内存
- 小 SET 用 intset 编码
- 合理配置编码阈值
- 避免大 key 引发延迟毛刺

这才是"Redis 为什么快"的真正答案。
