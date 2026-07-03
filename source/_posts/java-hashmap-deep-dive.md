---
title: 【面试必备】HashMap 底层原理深度解析：从 JDK 7 到 JDK 8 的红黑树演进
date: 2026-07-03 08:00:00
tags:
  - Java
  - 集合
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】HashMap 底层原理深度解析：从 JDK 7 到 JDK 8 的红黑树演进

## 面试官：说说 HashMap 的底层数据结构？

HashMap 是 Java 面试中当之无愧的"题王"，几乎每一场 Java 后端面试都绕不开它。今天我们就从面试官的角度出发，一路深挖 HashMap 的底层原理。

### 一句话概括

HashMap 底层是 **数组 + 链表（JDK 7）+ 红黑树（JDK 8）** 的哈希表实现。它通过 key 的 hashCode 值经过扰动函数处理后定位到数组槽位（bucket），如果发生哈希冲突则用链表（或红黑树）存储多个 Entry/Node。

### JDK 7 与 JDK 8 的数据结构对比

| 维度 | JDK 7 | JDK 8 |
|------|-------|-------|
| 数据结构 | 数组 + 链表 | 数组 + 链表 + 红黑树 |
| 节点类型 | Entry（内部类） | Node（内部类） |
| 链表插入 | 头插法 | 尾插法 |
| 树化阈值 | 无 | 链表长度 >= 8 |
| 扰动函数 | 4次位运算+5次异或 | 1次位运算+1次异或 |
| 扩容机制 | 重新hash | 要么在原来位置，要么在 oldCap + 原位置 |

## JDK 7 实现原理

### 初始化

```java
// 默认容量 16，加载因子 0.75
static final int DEFAULT_INITIAL_CAPACITY = 1 << 4; // 16
static final float DEFAULT_LOAD_FACTOR = 0.75f;

// 容量必须为 2 的幂
public HashMap(int initialCapacity, float loadFactor) {
    int capacity = 1;
    while (capacity < initialCapacity)
        capacity <<= 1; // 找 >= initialCapacity 的最小 2 的幂
    table = new Entry[capacity];
}
```

为什么容量必须是 2 的幂？因为 `hash & (len - 1)` 等效于 `hash % len`，但位运算效率高得多。只有当 len 是 2 的幂时，`len - 1` 的二进制才是全 1，才能保证散列均匀。

### 扰动函数

```java
// JDK 7 - 4次位运算 + 5次异或
final int hash(Object k) {
    int h = hashSeed;
    if (0 != h && k instanceof String) {
        return sun.misc.Hashing.stringHash32((String) k);
    }
    h ^= k.hashCode();
    h ^= (h >>> 20) ^ (h >>> 12);
    return h ^ (h >>> 7) ^ (h >>> 4);
}
```

为什么要这么复杂的扰动？为了让高位也能参与低位运算，减少哈希冲突。如果直接使用 `hashCode()` 的低 4 位做下标，当两个对象的 hashCode 高位不同、低位相同时就会冲突。扰动函数让高位的信息"混入"低位。

### put 方法流程（JDK 7）

```
1. 计算 key 的 hash
2. 通过 hash & (len-1) 计算槽位索引
3. 遍历该槽位的链表，检查是否存在相同 key（hash 相等且 equals 为 true）
   - 存在 → 覆盖旧值，返回旧值
   - 不存在 → 头插法添加新节点
4. 添加前检查是否需要扩容（size >= threshold）
```

```java
// JDK 7 put 方法（简化版）
public V put(K key, V value) {
    if (table == EMPTY_TABLE) {
        inflateTable(threshold);
    }
    if (key == null)
        return putForNullKey(value);
    int hash = hash(key);
    int i = indexFor(hash, table.length);
    for (Entry<K,V> e = table[i]; e != null; e = e.next) {
        Object k;
        if (e.hash == hash && ((k = e.key) == key || key.equals(k))) {
            V oldValue = e.value;
            e.value = value;
            return oldValue;
        }
    }
    addEntry(hash, key, value, i);
    return null;
}

void addEntry(int hash, K key, V value, int bucketIndex) {
    // 扩容检查
    if ((size >= threshold) && (null != table[bucketIndex])) {
        resize(2 * table.length);
        hash = (null != key) ? hash(key) : 0;
        bucketIndex = indexFor(hash, table.length);
    }
    createEntry(hash, key, value, bucketIndex);
}

void createEntry(int hash, K key, V value, int bucketIndex) {
    Entry<K,V> e = table[bucketIndex];
    table[bucketIndex] = new Entry<>(hash, key, value, e); // 头插法！
    size++;
}
```

### 头插法的问题

**头插法在多线程环境下会产生循环链表！**

场景：线程 A 和线程 B 同时执行 resize() 进行扩容。

```java
// transfer 方法 - 将旧数组元素迁移到新数组
void transfer(Entry[] newTable, boolean rehash) {
    int newCapacity = newTable.length;
    for (Entry<K,V> e : table) {
        while(null != e) {
            Entry<K,V> next = e.next;  // ① 记录下一个节点
            if (rehash) e.hash = null == e.key ? 0 : hash(e.key);
            int i = indexFor(e.hash, newCapacity);
            e.next = newTable[i];      // ② 头插到新数组
            newTable[i] = e;           // ③ 新数组指向 e
            e = next;                  // ④ 处理下一个
        }
    }
}
```

当两个线程同时执行 transfer，可能出现 `e.next = next` 的循环引用，导致 get 时死循环 CPU 100%。**这是 JDK 7 HashMap 在高并发下的致命缺陷。**

## JDK 8 改进与实现原理

### 数据结构演进

JDK 8 的 HashMap 引入了红黑树来优化链表过长的问题。

```java
// 关键常量
static final int TREEIFY_THRESHOLD = 8;     // 链表转红黑树阈值
static final int UNTREEIFY_THRESHOLD = 6;   // 红黑树退化为链表阈值
static final int MIN_TREEIFY_CAPACITY = 64; // 树化最小数组容量
```

**为什么树化阈值是 8？**

根据泊松分布，在加载因子 0.75 的情况下，链表长度达到 8 的概率约为 0.00000006（六亿分之一）。选择 8 是一个时空权衡——当链表长度如此之大时，说明 hash 函数遇到了极端情况，用红黑树换时间。

### hashCode 的扰动函数优化

```java
// JDK 8 - 只用 1 次位运算 + 1 次异或
static final int hash(Object key) {
    int h;
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}
```

相比 JDK 7 的 9 次运算，JDK 8 只用了 2 次。因为引入了红黑树后，即使冲突较多也能保证 O(log n) 的查找性能，不需要在扰动函数上过度优化。

### put 方法流程（JDK 8）

```java
final V putVal(int hash, K key, V value, boolean onlyIfAbsent, boolean evict) {
    Node<K,V>[] tab; Node<K,V> p; int n, i;
    // 1. 懒初始化 - 第一次 put 才创建数组
    if ((tab = table) == null || (n = tab.length) == 0)
        n = (tab = resize()).length;
    // 2. 槽位为空，直接放
    if ((p = tab[i = (n - 1) & hash]) == null)
        tab[i] = newNode(hash, key, value, null);
    else {
        Node<K,V> e; K k;
        // 3. key 相同，准备覆盖
        if (p.hash == hash && ((k = p.key) == key || (key != null && key.equals(k))))
            e = p;
        // 4. 红黑树节点
        else if (p instanceof TreeNode)
            e = ((TreeNode<K,V>)p).putTreeVal(this, tab, hash, key, value);
        // 5. 链表遍历
        else {
            for (int binCount = 0; ; ++binCount) {
                if ((e = p.next) == null) {
                    p.next = newNode(hash, key, value, null); // 尾插法
                    if (binCount >= TREEIFY_THRESHOLD - 1) // -1 因为当前是第 0 个
                        treeifyBin(tab, hash); // 链表转红黑树
                    break;
                }
                if (e.hash == hash && ((k = e.key) == key || (key != null && key.equals(k))))
                    break;
                p = e;
            }
        }
        // 6. 覆盖旧值
        if (e != null) {
            V oldValue = e.value;
            if (!onlyIfAbsent || oldValue == null)
                e.value = value;
            afterNodeAccess(e);
            return oldValue;
        }
    }
    ++modCount;
    if (++size > threshold)
        resize();
    afterNodeInsertion(evict);
    return null;
}
```

### JDK 8 扩容机制优化

JDK 7 的扩容需要重新计算每个元素的 hash，性能较差。JDK 8 利用了一个巧妙特性：

```java
// 扩容后，元素在新数组中的位置只有两种可能：
// 1. 原位置（当新增的 bit 位为 0）
// 2. 原位置 + 旧容量（当新增的 bit 位为 1）
if ((e.hash & oldCap) == 0) {
    // 放到原位置
} else {
    // 放到 原位置 + oldCap
}
```

这是因为容量为 2 的幂，扩容后长度翻倍，`hash & (newCap - 1)` 只比原来多了一个 bit 位参与运算。通过检查新增 bit 位是 0 还是 1，就能确定元素的新位置。

### resize 源码解析

```java
final Node<K,V>[] resize() {
    Node<K,V>[] oldTab = table;
    int oldCap = (oldTab == null) ? 0 : oldTab.length;
    int oldThr = threshold;
    int newCap, newThr = 0;
    
    if (oldCap > 0) {
        // 已达最大容量，无法扩容
        if (oldCap >= MAXIMUM_CAPACITY) {
            threshold = Integer.MAX_VALUE;
            return oldTab;
        }
        // 容量翻倍，阈值翻倍
        else if ((newCap = oldCap << 1) < MAXIMUM_CAPACITY &&
                 oldCap >= DEFAULT_INITIAL_CAPACITY)
            newThr = oldThr << 1;
    }
    // ... 处理 initial capacity 和 threshold
    
    // 创建新数组
    Node<K,V>[] newTab = (Node<K,V>[])new Node[newCap];
    table = newTab;
    
    // 迁移数据
    if (oldTab != null) {
        for (int j = 0; j < oldCap; ++j) {
            Node<K,V> e;
            if ((e = oldTab[j]) != null) {
                oldTab[j] = null;
                if (e.next == null)
                    // 只有一个节点，直接插入
                    newTab[e.hash & (newCap - 1)] = e;
                else if (e instanceof TreeNode)
                    // 红黑树拆分
                    ((TreeNode<K,V>)e).split(this, newTab, j, oldCap);
                else {
                    // 链表拆分：低位链 + 高位链
                    Node<K,V> loHead = null, loTail = null;
                    Node<K,V> hiHead = null, hiTail = null;
                    Node<K,V> next;
                    do {
                        next = e.next;
                        if ((e.hash & oldCap) == 0) {
                            // 低位链（原位置）
                            if (loTail == null)
                                loHead = e;
                            else
                                loTail.next = e;
                            loTail = e;
                        } else {
                            // 高位链（原位置 + oldCap）
                            if (hiTail == null)
                                hiHead = e;
                            else
                                hiTail.next = e;
                            hiTail = e;
                        }
                        e = next;
                    } while (e != null);
                    if (loTail != null) {
                        loTail.next = null;
                        newTab[j] = loHead;
                    }
                    if (hiTail != null) {
                        hiTail.next = null;
                        newTab[j + oldCap] = hiHead;
                    }
                }
            }
        }
    }
    return newTab;
}
```

## JDK 8 的 get 方法

```java
final Node<K,V> getNode(int hash, Object key) {
    Node<K,V>[] tab; Node<K,V> first, e; int n; K k;
    if ((tab = table) != null && (n = tab.length) > 0 &&
        (first = tab[(n - 1) & hash]) != null) {
        // 检查第一个节点
        if (first.hash == hash &&
            ((k = first.key) == key || (key != null && key.equals(k))))
            return first;
        // 后续节点
        if ((e = first.next) != null) {
            if (first instanceof TreeNode)
                return ((TreeNode<K,V>)first).getTreeNode(hash, key);
            do {
                if (e.hash == hash &&
                    ((k = e.key) == key || (key != null && key.equals(k))))
                    return e;
            } while ((e = e.next) != null);
        }
    }
    return null;
}
```

## 常见面试追问

### Q1：为什么负载因子默认是 0.75？

这是时间和空间的权衡：
- 负载因子越大（如 1.0），空间利用率高，但哈希冲突概率增大，链表变长，查询效率降低
- 负载因子越小（如 0.5），冲突减少，查询快，但浪费大量空间
- 0.75 是 JDK 源码中经过大量测试后的经验值

### Q2：HashMap 保证容量为 2 的幂有什么用？

核心原因：`hash & (len - 1)` 代替取模运算，而且只有 len 是 2 的幂时，`len - 1` 的二进制才会是全 1，才能保证 hash 值的所有低位都参与散列。

### Q3：为什么 HashMap 线程不安全？

1. **JDK 7 头插法**：扩容时会产生循环链表，导致死循环
2. **JDK 7/8 数据覆盖**：多线程 put 时可能发生数据丢失
3. **JDK 8 size 计数**：`++size` 不是原子操作，多个线程同时 put 可能导致 size 不准确

### Q4：如何让 HashMap 线程安全？

推荐方案（按优先级）：
1. `ConcurrentHashMap` — 分段锁 / CAS，性能最好
2. `Collections.synchronizedMap(new HashMap<>())` — 全表锁，性能较差
3. `HashTable` — 已淘汰，全表锁，性能最差

### Q5：Object.hashCode() 和 equals() 的约定？

- 两个对象 equals 相等，hashCode 必须相等
- 两个对象 hashCode 相等，equals 不一定相等（哈希冲突）
- **HashMap 中作为 key 的对象必须同时重写 hashCode 和 equals**

## 性能对比总结

| 场景 | JDK 7 | JDK 8 |
|------|-------|-------|
| 最坏情况查找 | O(n) — 链表遍历 | O(log n) — 红黑树 |
| 平均查找 | O(1) | O(1) |
| 哈希冲突严重时 | 性能急剧下降 | 红黑树保障稳定 |
| 扩容吞吐 | 低（重新hash全部key） | 高（高低位判断） |
| 内存占用 | 略少 | 略多（红黑树节点更大） |

## 最佳实践

```java
// 1. 预估初始容量，避免频繁扩容
Map<String, Object> map = new HashMap<>(expectedSize / 0.75f + 1);

// 2. 自定义对象做 key 必须重写 hashCode 和 equals
public class UserKey {
    private Long id;
    private String name;
    
    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        UserKey userKey = (UserKey) o;
        return Objects.equals(id, userKey.id) && Objects.equals(name, userKey.name);
    }
    
    @Override
    public int hashCode() {
        return Objects.hash(id, name);
    }
}

// 3. 多线程环境使用 ConcurrentHashMap
Map<String, Object> safeMap = new ConcurrentHashMap<>();
```

## 小结

HashMap 从 JDK 7 到 JDK 8 的演进，本质上是**用空间换时间、用更复杂的数据结构保障极端场景下的性能稳定**。理解 HashMap 的底层原理不仅是面试的需要，更是日常开发中写出健壮代码的基础。
