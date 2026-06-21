---
title: 【面试必备】ConcurrentHashMap 在 JDK 7 和 8 中的演变与对比
date: 2026-06-21 08:00:00
tags:
  - Java
  - 并发
  - 集合
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【面试必备】ConcurrentHashMap 在 JDK 7 和 8 中的演变与对比

## 面试官：说说 ConcurrentHashMap 的实现原理？

ConcurrentHashMap 是 Java 并发包的**王牌成员**，也是面试中**出场率最高**的集合类之一。它的设计经历了 JDK 7 的「分段锁」到 JDK 8 的「CAS + synchronized」的重大演变。

### 数据结构的直观对比

先上结论，再讲细节：

| 对比维度 | JDK 7（1.7及以前） | JDK 8（1.8及以后） |
|---------|-------------------|-------------------|
| **数据结构** | Segment + HashEntry（数组+链表） | Node + 红黑树（数组+链表+红黑树） |
| **锁粒度** | Segment 级别（粗粒度分段锁） | 单个桶的头节点（细粒度） |
| **并发机制** | ReentrantLock（继承自ReentrantLock） | synchronized + CAS |
| **定位元素** | 两次哈希（定位Segment → 定位桶） | 一次哈希 |
| **扩容机制** | 每个Segment单独扩容 | 整体扩容，支持多线程协助 |
| **size() 统计** | 先乐观尝试，失败再锁所有Segment | 使用 baseCount + CounterCell |
| **迭代器** | 弱一致性 | 弱一致性 |

---

## 一、JDK 7 的实现：分段锁（Segment Locking）

### 1.1 数据结构

JDK 7 的 ConcurrentHashMap 包含一个 **Segment 数组**，每个 Segment 继承自 ReentrantLock，内部持有一个 **HashEntry 数组**。

```
ConcurrentHashMap (JDK 7)
┌─────────────────────────────────────────┐
│             Segment[]                    │
│  ┌─────┐  ┌─────┐  ┌─────┐             │
│  │Seg 0│  │Seg 1│  │Seg 2│  ...         │
│  └──┬──┘  └──┬──┘  └──┬──┘             │
│     │        │        │                  │
│  ┌──▼──┐  ┌──▼──┐  ┌──▼──┐             │
│  │HashEntry[]   │  │HashEntry[]          │
│  │(数组)  │  │(数组)  │  │(数组)           │
│  └──────┘  └──────┘  └──────┘           │
└─────────────────────────────────────────┘
```

**核心字段：**

```java
static final class Segment<K,V> extends ReentrantLock {
    transient volatile HashEntry<K,V>[] table;  // 每个Segment自己的哈希表
    transient int count;                        // 元素个数
    transient int modCount;                     // 修改次数
    transient int threshold;                    // 扩容阈值
    final float loadFactor;                     // 负载因子
}
```

默认 **16 个 Segment**（`DEFAULT_CONCURRENCY_LEVEL = 16`），意味着最多同时支持 16 个线程并发写入。

### 1.2 put() 操作流程

```java
// JDK 7 ConcurrentHashMap.put()
public V put(K key, V value) {
    Segment<K,V> s;
    if (value == null) throw new NullPointerException();
    int hash = hash(key);
    // 1. 通过 key 的哈希值定位到 Segment
    int j = (hash >>> segmentShift) & segmentMask;
    s = ensureSegment(j);
    // 2. 调用 Segment 的 put 方法
    return s.put(key, hash, value, false);
}

// Segment.put()
final V put(K key, int hash, V value, boolean onlyIfAbsent) {
    // 3. 尝试获取锁（tryLock 优先，非阻塞）
    HashEntry<K,V> node = tryLock() ? null :
        scanAndLockForPut(key, hash, value);  // 自旋等待锁
    try {
        // 4. 拿到锁后，操作 HashEntry 数组
        HashEntry<K,V>[] tab = table;
        int index = hash & (tab.length - 1);
        HashEntry<K,V> first = tab[index];
        // 链表遍历、插入或替换
        // ... 省略具体逻辑
    } finally {
        unlock();  // ReentrantLock 解锁
    }
}
```

**重点关注** `scanAndLockForPut()` 方法，它体现了**自旋优化**思想：
1. 先尝试自旋获取锁（最多 64 次）
2. 自旋期间还会预创建 HashEntry 节点（减少锁内操作时间）
3. 如果自旋失败则挂起线程（阻塞等待）

### 1.3 get() 操作——无锁读

```java
// JDK 7 ConcurrentHashMap.get()
public V get(Object key) {
    Segment<K,V> s;
    HashEntry<K,V>[] tab;
    int h = hash(key);
    long u = (((h >>> segmentShift) & segmentMask) << SSHIFT) + SBASE;
    if ((s = (Segment<K,V>)UNSAFE.getObjectVolatile(segments, u)) != null &&
        (tab = s.table) != null) {
        // 遍历链表，无需加锁
        for (HashEntry<K,V> e = (HashEntry<K,V>) UNSAFE.getObjectVolatile
                 (tab, ((long)(((tab.length - 1) & h)) << TSHIFT) + TBASE);
             e != null; e = e.next) {
            K k;
            if ((k = e.key) == key || (e.hash == h && key.equals(k)))
                return e.value;
        }
    }
    return null;
}
```

**⚠️ 注意**：get 操作全程无锁，依赖 `volatile` 保证可见性！HashEntry 的 `value` 和 `next` 都是 volatile 修饰的。

---

## 二、JDK 8 的实现：CAS + synchronized

### 2.1 数据结构

JDK 8 彻底重构了 ConcurrentHashMap：
- **去掉了 Segment**，回归到类似 HashMap 的结构
- 采用 **Node 数组 + 链表/红黑树**
- 使用 **synchronized + CAS** 替代 ReentrantLock

```
ConcurrentHashMap (JDK 8)
┌──────────────────────────────────────────┐
│              Node[] table                 │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐        │
│  │null │ │Node │ │null │ │Node │ ...     │
│  └─────┘ └──┬──┘ └─────┘ └──┬──┘        │
│              │               │            │
│          链表/红黑树      链表/红黑树       │
│              │               │            │
│      Node → Node → ...  Node → Node       │
└──────────────────────────────────────────┘
```

### 2.2 put() 操作——精细化的 CAS + synchronized

```java
// JDK 8 ConcurrentHashMap.putVal() 简化版
final V putVal(K key, V value, boolean onlyIfAbsent) {
    if (key == null || value == null) throw new NullPointerException();
    int hash = spread(key.hashCode());
    int binCount = 0;
    for (Node<K,V>[] tab = table;;) {
        Node<K,V> f; int n, i, fh;
        if (tab == null || (n = tab.length) == 0)
            tab = initTable();                    // 懒加载，CAS 初始化
        else if ((f = tabAt(tab, i = (n - 1) & hash)) == null) {
            // 1. 桶为空 → CAS 无锁插入
            if (casTabAt(tab, i, null, new Node<K,V>(hash, key, value, null)))
                break;
        }
        else if ((fh = f.hash) == MOVED)
            tab = helpTransfer(tab, f);           // 2. 正在进行扩容，协助迁移
        else {
            V oldVal = null;
            synchronized (f) {                    // 3. 桶非空 → 锁头节点
                if (tabAt(tab, i) == f) {         // double-check
                    if (fh >= 0) {                // 链表情况
                        binCount = 1;
                        for (Node<K,V> e = f;; ++binCount) {
                            // 链表遍历，查找或追加
                        }
                    } else if (f instanceof TreeBin) {  // 红黑树情况
                        // 树节点插入
                    }
                }
            }
            if (binCount >= TREEIFY_THRESHOLD)    // 4. 链表长度 ≥ 8 → 树化
                treeifyBin(tab, i);
        }
    }
    addCount(1L, binCount);                       // 5. 统计元素数量，触发扩容检查
    return null;
}
```

**put 流程总结**：

```
put(key, value)
  │
  ├─ tab == null → initTable()  【CAS 初始化】
  │
  ├─ 桶为空 → casTabAt() 插入  【CAS，无锁】
  │
  ├─ f.hash == MOVED → helpTransfer()  【协助扩容】
  │
  └─ 桶非空 → synchronized(f)  【锁头节点】
       ├─ 链表 → 遍历插入或替换
       └─ 红黑树 → TreeBin 插入
```

### 为什么 JDK 8 用 synchronized 而不是 ReentrantLock？

这是一个经典面试题。原因如下：

1. **synchronized 已经优化**：JDK 8 中的 synchronized 引入了**偏向锁 → 轻量级锁 → 重量级锁**的升级过程，在低竞争场景下性能不输 ReentrantLock
2. **代码更简洁**：synchronized 不需要手动释放锁，代码更清晰
3. **锁粒度更细**：synchronized 锁的是单个桶的头节点，而 JDK 7 锁的是整个Segment，JDK 8 的并发度更高
4. **JVM 可以进一步优化**：synchronized 是 JVM 内置特性，JIT 编译器可以做更多优化

---

## 三、扩容机制对比

### JDK 7：Segments 内部独立扩容

```java
// Segment.rehash() 简化版
private void rehash(HashEntry<K,V> node) {
    HashEntry<K,V>[] oldTable = table;
    int oldCapacity = oldTable.length;
    int newCapacity = oldCapacity << 1;     // 翻倍
    threshold = (int)(newCapacity * loadFactor);
    HashEntry<K,V>[] newTable = HashEntry.newArray(newCapacity);
    // 遍历 oldTable，重新哈希
    for (int i = 0; i < oldCapacity; i++) {
        // 链表反转（JDK 7 头插法），同样是分段独立扩容
    }
    table = newTable;
}
```

- 每个 Segment 独立判断是否扩容
- 扩容时只锁当前 Segment，不影响其他 Segment
- 但不会多线程协作扩容

### JDK 8：多线程协助扩容

```java
// JDK 8 扩容核心逻辑
final Node<K,V>[] helpTransfer(Node<K,V>[] tab, Node<K,V> f) {
    Node<K,V>[] nextTab; int sc;
    // 检查是否处于扩容状态，是则协助
    if (tab != null && (f instanceof ForwardingNode) &&
        (nextTab = ((ForwardingNode<K,V>)f).nextTable) != null) {
        int rs = resizeStamp(tab.length);
        while (nextTab == nextTable && table == tab &&
               (sc = sizeCtl) < 0) {
            if (sc == rs + MAX_RESIZERS || sc == rs + 1 ||
                transferIndex <= 0)
                break;
            if (U.compareAndSwapInt(this, SIZECTL, sc, sc + 1)) {
                transfer(tab, nextTab);  // 参与扩容
                break;
            }
        }
        return nextTab;
    }
    return table;
}
```

**JDK 8 扩容的特点**：
1. **整体扩容**：整个 table 一起扩容，不再分段
2. **多线程并行**：通过 `sizeCtl` 协调，多个线程可以同时迁移不同的桶
3. **ForwardingNode 标记**：已迁移的桶放一个 ForwardingNode，遇到它就去新表查找
4. **迁移完一个桶就结束**：每个线程领取一段区间（stride），迁移完后检查是否全部完成

---

## 四、size() 统计方式的进化

### JDK 7：尝试锁住所有 Segment

```java
// JDK 7 ConcurrentHashMap.size()
public int size() {
    final Segment<K,V>[] segments = this.segments;
    long sum = 0;
    long check = 0;
    int[] mc = new int[segments.length];
    // 先乐观尝试，不锁
    for (int k = 0; k < RETRIES_BEFORE_LOCK; ++k) {
        check = 0;
        sum = 0;
        int mcsum = 0;
        for (int i = 0; i < segments.length; ++i) {
            sum += segments[i].count;
            mcsum += (mc[i] = segments[i].modCount);
        }
        if (mcsum != 0) {
            // 验证 modCount 是否一致
            for (int i = 0; i < segments.length; ++i) {
                check += segments[i].count;
                if (mc[i] != segments[i].modCount) {
                    check = -1;  // 不一致，重试
                    break;
                }
            }
        }
        if (check == sum) break;  // 一致则返回
    }
    // 重试失败 → 锁住所有 Segment 再统计
    if (check != sum) {
        for (int i = 0; i < segments.length; ++i)
            segments[i].lock();
        // ... 统计
        for (int i = 0; i < segments.length; ++i)
            segments[i].unlock();
    }
    return (int) Math.min(sum, Integer.MAX_VALUE);
}
```

### JDK 8：baseCount + CounterCell

```java
// JDK 8 使用 LongAdder 的思路
private transient volatile long baseCount;       // 基础计数器
private transient volatile CounterCell[] counterCells;  // 辅助计数数组

// addCount 方法
private final void addCount(long x, int check) {
    CounterCell[] as; long b, s;
    if ((as = counterCells) != null ||
        !U.compareAndSwapLong(this, BASECOUNT, b = baseCount, s = b + x)) {
        // CAS 失败或 counterCells 已存在 → 使用 CounterCell 分散计数
        CounterCell a; long v; int m;
        boolean uncontended = true;
        if (as == null || (m = as.length - 1) < 0 ||
            (a = as[ThreadLocalRandom.getProbe() & m]) == null ||
            !(uncontended = U.compareAndSwapLong(a, CELLVALUE, v = a.value, v + x))) {
            fullAddCount(x, uncontended);  // 完整计数逻辑
            return;
        }
        // ...
    }
    // ...
}
```

**核心思想**：借鉴 `LongAdder` 的**分段计数**思想，减少 CAS 竞争，高并发场景下性能远超 JDK 7 的全量锁定统计。

---

## 五、总结：面试回答要点

### 核心对比速记表

| 维度 | JDK 7 | JDK 8 |
|------|-------|-------|
| 锁 | ReentrantLock + 分段锁 | synchronized + CAS |
| 数据结构 | Segment + HashEntry | Node + TreeNode + TreeBin |
| 并发级别 | 默认 16 | 数组长度（更细粒度） |
| 哈希 | 两次哈希 | 一次哈希 |
| 扩容 | 分段独立 | 全局 + 多线程协作 |
| size() | 先乐观后锁所有 | baseCount + CounterCell |

### 面试追问总结

**Q：ConcurrentHashMap 的迭代器是强一致性还是弱一致性？**
A：**弱一致性**。迭代器遍历的是底层数组的**快照**，遍历过程中发生的修改不会反映到迭代器中，也不会抛出 ConcurrentModificationException。

**Q：ConcurrentHashMap 的 key 和 value 为什么不能为 null？**
A：因为设计者 Doug Lea 认为，如果允许 null，在 `get()` 返回 null 时无法区分是「key 不存在」还是「value 就是 null」。相比之下 HashMap 允许多次 `containsKey()` 检查，但并发环境下 containsKey 和 get 之间可能有其他线程修改。

**Q：JDK 8 中什么情况下链表会转红黑树？**
A：链表长度 ≥ 8 且数组长度 ≥ 64 时会树化；如果数组长度 < 64，会先扩容而不是树化。当红黑树节点数量 ≤ 6 时，会退化为链表。

### 性能选型建议

- **读多写少的简单场景**：Collections.synchronizedMap() 就够用
- **高并发读写**：ConcurrentHashMap（JDK 8 版本）
- **需要统计元素个数**：ConcurrentHashMap 的 mappingCount() 返回 long 类型，更准确
- **需要线程安全的有序性**：ConcurrentSkipListMap（跳表实现，有序）
