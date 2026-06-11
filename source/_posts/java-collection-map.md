---
title: Java 集合框架（Map 篇）源码深度解析
date: 2026-06-08 23:50:00
tags: [Java, 集合, 源码分析, HashMap, ConcurrentHashMap]
categories: 源码分析
---

## 前言

Map 是 Java 中使用频率最高的集合接口之一，也是面试中的绝对重点。本文深入源码剖析 **HashMap**、**LinkedHashMap**、**TreeMap**、**ConcurrentHashMap** 四大核心实现。

---

## 一、HashMap 源码深度解析

### 1. 底层数据结构

```java
public class HashMap<K,V> extends AbstractMap<K,V>
        implements Map<K,V>, Cloneable, Serializable {

    // 默认初始容量 16
    static final int DEFAULT_INITIAL_CAPACITY = 1 << 4; // 16

    // 最大容量 2^30
    static final int MAXIMUM_CAPACITY = 1 << 30;

    // 默认负载因子 0.75
    static final float DEFAULT_LOAD_FACTOR = 0.75f;

    // 树化阈值：链表长度 >= 8 时转红黑树
    static final int TREEIFY_THRESHOLD = 8;

    // 树退化阈值：红黑树节点 <= 6 时退化为链表
    static final int UNTREEIFY_THRESHOLD = 6;

    // 最小树化容量：数组长度 >= 64 才会树化
    static final int MIN_TREEIFY_CAPACITY = 64;

    // 核心数组：Node<K,V>[]
    transient Node<K,V>[] table;

    // 键值对数量
    transient int size;

    // 结构性修改计数器
    transient int modCount;

    // 扩容阈值：capacity * loadFactor
    int threshold;

    // 负载因子
    final float loadFactor;
}
```

JDK 1.8 的 HashMap 采用 **数组 + 链表 + 红黑树** 结构：

```
table:  [ 0 ][ 1 ][ 2 ] ...[ n ]
           |     |
       链表/红黑树  链表/红黑树
```

### 2. Node 内部类

```java
static class Node<K,V> implements Map.Entry<K,V> {
    final int hash;    // key 的哈希值（已扰动处理）
    final K key;       // key
    V value;           // value
    Node<K,V> next;    // 链表指针

    Node(int hash, K key, V value, Node<K,V> next) {
        this.hash = hash;
        this.key = key;
        this.value = value;
        this.next = next;
    }
}
```

### 3. hash 方法 —— 扰动函数

```java
static final int hash(Object key) {
    int h;
    // key 为 null 时放在 0 号桶
    // 否则：h = key.hashCode()，然后高16位与低16位异或
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}
```

**为什么要有扰动函数？**

> `(h = key.hashCode()) ^ (h >>> 16)` — 将 hashCode 的高 16 位与低 16 位异或，让高 16 位也参与寻址计算，降低哈希碰撞概率。

### 4. put 方法 —— 最核心方法

```java
public V put(K key, V value) {
    return putVal(hash(key), key, value, false, true);
}

final V putVal(int hash, K key, V value, boolean onlyIfAbsent,
               boolean evict) {
    Node<K,V>[] tab; Node<K,V> p; int n, i;

    // 1️⃣ 数组为空则初始化（懒加载）
    if ((tab = table) == null || (n = tab.length) == 0)
        n = (tab = resize()).length;

    // 2️⃣ 计算桶位：(n-1) & hash，若为空直接插入
    if ((p = tab[i = (n - 1) & hash]) == null)
        tab[i] = newNode(hash, key, value, null);
    else {
        Node<K,V> e; K k;

        // 3️⃣ 桶首节点 key 相同，直接覆盖
        if (p.hash == hash &&
            ((k = p.key) == key || (key != null && key.equals(k))))
            e = p;

        // 4️⃣ 桶首节点是红黑树节点，走红黑树插入
        else if (p instanceof TreeNode)
            e = ((TreeNode<K,V>)p).putTreeVal(this, tab, hash, key, value);

        // 5️⃣ 桶首节点是链表节点，遍历链表
        else {
            for (int binCount = 0; ; ++binCount) {
                // 5.1 遍历到链表末尾，尾插法插入
                if ((e = p.next) == null) {
                    p.next = newNode(hash, key, value, null);
                    // 如果链表长度 >= 8，执行树化
                    if (binCount >= TREEIFY_THRESHOLD - 1) // -1 for 1st
                        treeifyBin(tab, hash);
                    break;
                }
                // 5.2 找到相同 key，跳出循环准备覆盖
                if (e.hash == hash &&
                    ((k = e.key) == key || (key != null && key.equals(k))))
                    break;
                p = e;
            }
        }

        // 6️⃣ key 已存在，覆盖 value 并返回旧值
        if (e != null) {
            V oldValue = e.value;
            if (!onlyIfAbsent || oldValue == null)
                e.value = value;
            afterNodeAccess(e);
            return oldValue;
        }
    }

    ++modCount;
    // 7️⃣ size 超过阈值，扩容
    if (++size > threshold)
        resize();
    afterNodeInsertion(evict);
    return null;
}
```

**put 流程总结：**

```
put(key, value)
  │
  ├─ key == null → hash = 0，放在 table[0]
  │
  ├─ table 为空 → resize() 初始化
  │
  ├─ 计算桶位：i = (n-1) & hash
  │
  ├─ table[i] == null → 直接放到该桶
  │
  ├─ table[i].hash == 当前 hash → 覆盖
  │
  ├─ table[i] 是 TreeNode → 红黑树插入
  │
  └─ 遍历链表
       ├─ 找到相同 key → 覆盖
       ├─ 没找到 → 尾插
       └─ 链表 >= 8 → 树化
```

### 5. resize 方法 —— 扩容机制

```java
final Node<K,V>[] resize() {
    Node<K,V>[] oldTab = table;
    int oldCap = (oldTab == null) ? 0 : oldTab.length;
    int oldThr = threshold;
    int newCap, newThr = 0;

    // 计算新容量和新阈值
    if (oldCap > 0) {
        if (oldCap >= MAXIMUM_CAPACITY) {
            threshold = Integer.MAX_VALUE;
            return oldTab;
        }
        // 新容量 = 旧容量 * 2（左移1位）
        else if ((newCap = oldCap << 1) < MAXIMUM_CAPACITY &&
                 oldCap >= DEFAULT_INITIAL_CAPACITY)
            newThr = oldThr << 1;  // 阈值翻倍
    }
    else if (oldThr > 0) // 初始容量在构造时指定
        newCap = oldThr;
    else {               // 默认初始化
        newCap = DEFAULT_INITIAL_CAPACITY;
        newThr = (int)(DEFAULT_LOAD_FACTOR * DEFAULT_INITIAL_CAPACITY);
    }

    // ... 创建新数组
    Node<K,V>[] newTab = (Node<K,V>[])new Node[newCap];
    table = newTab;

    // 核心：数据迁移
    if (oldTab != null) {
        for (int j = 0; j < oldCap; ++j) {
            Node<K,V> e;
            if ((e = oldTab[j]) != null) {
                oldTab[j] = null;
                if (e.next == null)
                    // 单个节点：直接 rehash 到新位置
                    newTab[e.hash & (newCap - 1)] = e;
                else if (e instanceof TreeNode)
                    // 红黑树节点：拆分红黑树
                    ((TreeNode<K,V>)e).split(this, newTab, j, oldCap);
                else {
                    // 链表节点：拆分为两条链表
                    // 利用扩容后高位多一位的特性
                    Node<K,V> loHead = null, loTail = null;
                    Node<K,V> hiHead = null, hiTail = null;
                    Node<K,V> next;
                    do {
                        next = e.next;
                        // e.hash & oldCap == 0 留在原位置
                        if ((e.hash & oldCap) == 0) {
                            if (loTail == null) loHead = e;
                            else loTail.next = e;
                            loTail = e;
                        }
                        // e.hash & oldCap != 0 移到 "原位置 + oldCap"
                        else {
                            if (hiTail == null) hiHead = e;
                            else hiTail.next = e;
                            hiTail = e;
                        }
                        e = next;
                    } while (e != null);
                    // 两条链表
                    if (loTail != null) {
                        loTail.next = null;
                        newTab[j] = loHead;          // 留在原位置
                    }
                    if (hiTail != null) {
                        hiTail.next = null;
                        newTab[j + oldCap] = hiHead; // 移到高位
                    }
                }
            }
        }
    }
    return newTab;
}
```

**扩容优化（JDK 1.8）：**

JDK 1.7 及之前：rehash 需要每个元素重新计算 hash 取模
JDK 1.8：利用 `e.hash & oldCap` 判断——结果是 0 留在原地，非 0 则移动到 `原位置 + oldCap`

> 因为扩容是翻倍，n-1 高位多了一个 1，相当于 hash 在新增的高位上是 0 还是 1。

### 6. get 方法

```java
public V get(Object key) {
    Node<K,V> e;
    return (e = getNode(hash(key), key)) == null ? null : e.value;
}

final Node<K,V> getNode(int hash, Object key) {
    Node<K,V>[] tab; Node<K,V> first, e; int n; K k;

    if ((tab = table) != null && (n = tab.length) > 0 &&
        (first = tab[(n - 1) & hash]) != null) {
        // 1. 检查桶首节点
        if (first.hash == hash &&
            ((k = first.key) == key || (key != null && key.equals(k))))
            return first;
        // 2. 链表或红黑树遍历
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

### 7. 树化与退化

```java
final void treeifyBin(Node<K,V>[] tab, int hash) {
    int n, index; Node<K,V> e;
    // 如果数组长度 < 64，先扩容而不是树化
    if (tab == null || (n = tab.length) < MIN_TREEIFY_CAPACITY)
        resize();
    // 真正执行树化
    else if ((e = tab[index = (n - 1) & hash]) != null) {
        // ... 链表转为红黑树
        TreeNode<K,V> hd = null, tl = null;
        do {
            TreeNode<K,V> p = replacementTreeNode(e, null);
            if (tl == null) hd = p;
            else { p.prev = tl; tl.next = p; }
            tl = p;
        } while ((e = e.next) != null);
        if ((tab[index] = hd) != null)
            hd.treeify(tab);
    }
}
```

**树化条件：** 链表长度 >= **8** **且** 数组长度 >= **64**
**退化条件：** 红黑树节点 <= **6** 时退化回链表

> **为什么链表阈值是 8？** 基于泊松分布，负载因子 0.75 时，链表长度到 8 的概率已经小于千万分之一。8 是时间和空间的平衡点。

### 8. 为什么容量是 2 的幂

因为计算桶位用 `(n - 1) & hash` 而不是 `hash % n`。位运算比取模快得多，但前提是 n 是 2 的幂，此时 `(n-1) & hash` 等价于 `hash % n`。

```java
// n=16:  (n-1)=1111
// hash & 1111 = 取 hash 的低 4 位 = hash % 16
// n=32:  (n-1)=11111
// 扩容后定位：
//   e.hash & oldCap == 0 → 原位
//   e.hash & oldCap != 0 → 原位 + oldCap
```

---

## 二、LinkedHashMap 源码解析

### 1. 继承结构

```java
public class LinkedHashMap<K,V> extends HashMap<K,V>
        implements Map<K,V> {
    
    // 双向链表的头尾节点
    transient LinkedHashMap.Entry<K,V> head;
    transient LinkedHashMap.Entry<K,V> tail;
    
    // 迭代顺序：false=插入顺序，true=访问顺序
    final boolean accessOrder;
}
```

LinkedHashMap 继承自 HashMap，在 HashMap 的基础上维护了一个**双向链表**来保证迭代顺序。

### 2. Entry 节点

```java
static class Entry<K,V> extends HashMap.Node<K,V> {
    Entry<K,V> before, after;  // 双向链表前驱后继
    Entry(int hash, K key, V value, Node<K,V> next) {
        super(hash, key, value, next);
    }
}
```

### 3. afterNodeAccess —— 访问顺序

```java
// 每次 get 或 put 覆盖时调用
void afterNodeAccess(Node<K,V> e) {
    LinkedHashMap.Entry<K,V> last;
    if (accessOrder && (last = tail) != e) {
        // 将 e 移动到链表尾部（表示最近访问）
        LinkedHashMap.Entry<K,V> p =
            (LinkedHashMap.Entry<K,V>)e, b = p.before, a = p.after;
        p.after = null;
        if (b == null) head = a;
        else b.after = a;
        if (a != null) a.before = b;
        else last = b;
        if (last == null) head = p;
        else {
            p.before = last;
            last.after = p;
        }
        tail = p;
        ++modCount;
    }
}
```

### 4. removeEldestEntry —— LRU 缓存

```java
protected boolean removeEldestEntry(Map.Entry<K,V> eldest) {
    return false;  // 默认不删除
}
```

通过重写这个方法可以实现 LRU 缓存：

```java
class LRUCache<K,V> extends LinkedHashMap<K,V> {
    private final int maxCapacity;
    
    public LRUCache(int maxCapacity) {
        super(maxCapacity, 0.75f, true);  // accessOrder=true
        this.maxCapacity = maxCapacity;
    }
    
    @Override
    protected boolean removeEldestEntry(Map.Entry<K,V> eldest) {
        return size() > maxCapacity;  // 超过容量删除最久未访问的
    }
}
```

> **LinkedHashMap 核心用途：** ① 保持插入顺序的 HashMap ② 实现 LRU 缓存

---

## 三、TreeMap 源码解析

### 1. 数据结构 —— 红黑树

```java
public class TreeMap<K,V> extends AbstractMap<K,V>
        implements NavigableMap<K,V>, Cloneable, java.io.Serializable {
    
    // 比较器（支持自定义排序）
    private final Comparator<? super K> comparator;
    
    // 红黑树根节点
    private transient Entry<K,V> root;
    
    // 节点数量
    private transient int size = 0;
}
```

### 2. Entry 节点

```java
static final class Entry<K,V> implements Map.Entry<K,V> {
    K key;
    V value;
    Entry<K,V> left;   // 左子节点
    Entry<K,V> right;  // 右子节点
    Entry<K,V> parent; // 父节点
    boolean color = BLACK;  // 节点颜色：RED 或 BLACK
}
```

### 3. put 方法 —— 红黑树插入

```java
public V put(K key, V value) {
    Entry<K,V> t = root;
    
    // 树为空
    if (t == null) {
        compare(key, key); // type check
        root = new Entry<>(key, value, null);
        size = 1;
        modCount++;
        return null;
    }
    
    // 二分查找插入位置
    int cmp;
    Entry<K,V> parent;
    Comparator<? super K> cpr = comparator;
    if (cpr != null) {
        do {
            parent = t;
            cmp = cpr.compare(key, t.key);
            if (cmp < 0)      t = t.left;
            else if (cmp > 0) t = t.right;
            else              return t.setValue(value); // key 已存在
        } while (t != null);
    } else {
        // 使用 Comparable 比较
        @SuppressWarnings("unchecked")
        Comparable<? super K> k = (Comparable<? super K>) key;
        do {
            parent = t;
            cmp = k.compareTo(t.key);
            if (cmp < 0)      t = t.left;
            else if (cmp > 0) t = t.right;
            else              return t.setValue(value);
        } while (t != null);
    }
    
    // 插入新节点
    Entry<K,V> e = new Entry<>(key, value, parent);
    if (cmp < 0) parent.left = e;
    else         parent.right = e;
    
    // 红黑树自平衡（颜色翻转、旋转）
    fixAfterInsertion(e);
    size++;
    modCount++;
    return null;
}
```

### 4. 红黑树五大性质

1. **每个节点要么红色要么黑色**
2. **根节点是黑色**
3. **叶节点（NIL）是黑色**
4. **红色节点的子节点必须是黑色**（不能有连续红色）
5. **从任意节点到叶子节点，黑色节点数相同**

### 5. TreeMap 特色功能

```java
TreeMap<Integer, String> map = new TreeMap<>();
map.put(1, "a"); map.put(3, "c"); map.put(5, "e");

map.firstKey();        // 1 — 最小的 key
map.lastKey();         // 5 — 最大的 key
map.lowerKey(3);       // 1 — 小于 3 的最大 key
map.higherKey(3);      // 5 — 大于 3 的最小 key
map.subMap(1, true, 3, true);  // {1=a, 3=c} — 范围查询
```

---

## 四、ConcurrentHashMap 源码解析

### 1. JDK 1.7 vs JDK 1.8

| 版本 | 并发机制 | 数据结构 |
|------|---------|---------|
| JDK 1.7 | Segment + ReentrantLock（分段锁） | 数组 + 链表 |
| **JDK 1.8** | **CAS + synchronized** | **数组 + 链表 + 红黑树** |

### 2. JDK 1.8 核心数据结构

```java
public class ConcurrentHashMap<K,V> extends AbstractMap<K,V>
        implements ConcurrentMap<K,V>, Serializable {

    // 最大容量
    private static final int MAXIMUM_CAPACITY = 1 << 30;

    // 默认初始容量
    private static final int DEFAULT_CAPACITY = 16;

    // 并发级别（JDK 1.7 遗留，不再使用）
    private static final int DEFAULT_CONCURRENCY_LEVEL = 16;

    // 负载因子
    private static final float LOAD_FACTOR = 0.75f;

    // 树化阈值（同 HashMap）
    static final int TREEIFY_THRESHOLD = 8;

    // 核心数组
    transient volatile Node<K,V>[] table;

    // 扩容时使用的新数组
    private transient volatile Node<K,V>[] nextTable;

    // 扩容进度标记
    private transient volatile int sizeCtl;
}
```

### 3. put 方法 —— CAS + synchronized

```java
final V putVal(K key, V value, boolean onlyIfAbsent) {
    if (key == null || value == null) throw new NullPointerException();
    int hash = spread(key.hashCode());  // 扰动函数
    int binCount = 0;

    for (Node<K,V>[] tab = table;;) {
        Node<K,V> f; int n, i, fh;

        // 1️⃣ 数组为空，初始化（CAS 保证线程安全）
        if (tab == null || (n = tab.length) == 0)
            tab = initTable();

        // 2️⃣ 桶为空，CAS 插入
        else if ((f = tabAt(tab, i = (n - 1) & hash)) == null) {
            // 使用 CAS 将节点放入该桶
            if (casTabAt(tab, i, null,
                         new Node<K,V>(hash, key, value, null)))
                break;
        }

        // 3️⃣ 正在扩容，协助迁移
        else if ((fh = f.hash) == MOVED)
            tab = helpTransfer(tab, f);

        // 4️⃣ 桶不为空，synchronized 锁住桶头节点
        else {
            V oldVal = null;
            synchronized (f) {  // 锁粒度：桶
                if (tabAt(tab, i) == f) {
                    if (fh >= 0) {
                        // 链表遍历
                        binCount = 1;
                        for (Node<K,V> e = f;; ++binCount) {
                            // ... 同 HashMap 逻辑
                        }
                    } else if (f instanceof TreeBin) {
                        // 红黑树插入
                    }
                }
            }
            if (binCount != 0) {
                if (binCount >= TREEIFY_THRESHOLD)
                    treeifyBin(tab, i);
                if (oldVal != null)
                    return oldVal;
                break;
            }
        }
    }
    addCount(1L, binCount);  // 更新 size（使用 CounterCell）
    return null;
}
```

**加锁策略：** 桶为空 → CAS；桶不为空 → 对**桶首节点**加 synchronized

### 4. get 方法 —— 完全无锁

```java
public V get(Object key) {
    Node<K,V>[] tab; Node<K,V> e, p; int n, eh; K ek;
    int h = spread(key.hashCode());

    if ((tab = table) != null && (n = tab.length) > 0 &&
        (e = tabAt(tab, (n - 1) & h)) != null) {
        // 检查桶首
        if ((eh = e.hash) == h) {
            if ((ek = e.key) == key || (ek != null && key.equals(ek)))
                return e.val;
        }
        // 扩容中或红黑树
        else if (eh < 0)
            return (p = e.find(h, key)) != null ? p.val : null;
        // 链表遍历
        while ((e = e.next) != null) {
            if (e.hash == h &&
                ((ek = e.key) == key || (ek != null && key.equals(ek))))
                return e.val;
        }
    }
    return null;
}
```

> **get 全程无锁**，靠 volatile 保证可见性，这是 ConcurrentHashMap 高性能的关键。

### 5. size 统计 —— CounterCell

```java
// 使用 CounterCell 数组分散计数，降低竞争
private transient volatile CounterCell[] counterCells;

final long sumCount() {
    CounterCell[] cs = counterCells;
    long sum = baseCount;
    if (cs != null) {
        for (CounterCell c : cs)
            if (c != null)
                sum += c.value;
    }
    return sum;
}
```

### 6. ConcurrentHashMap 安全机制总结

| 场景 | 机制 |
|------|------|
| 数组初始化 | CAS + volatile sizeCtl |
| 空桶插入 | **CAS**（无锁） |
| 非空桶插入 | **synchronized**（桶级别锁） |
| 读取 | **volatile** 保证可见性 |
| 计数 | CounterCell 分散竞争 |
| 扩容 | 多线程协助迁移 |

---

## 五、四大 Map 实现对比

| 特性 | HashMap | LinkedHashMap | TreeMap | ConcurrentHashMap |
|------|---------|--------------|---------|------------------|
| 顺序 | 无序 | **插入/访问顺序** | **自然/自定义排序** | 无序 |
| 底层 | 数组+链表+红黑树 | HashMap + 双向链表 | **红黑树** | CAS + 数组+链表+红黑树 |
| 线程安全 | ❌ | ❌ | ❌ | **✅** |
| key 要求 | equals+hashCode | equals+hashCode | **Comparable/Comparator** | equals+hashCode |
| 性能 | 极高 | 略低于 HashMap | O(log n) | 极高（读无锁） |
| null key | ✅ **允许** | ✅ 允许 | ❌ **不允许** | ❌ **不允许** |
| null value | ✅ 允许 | ✅ 允许 | ✅ 允许 | ❌ **不允许** |

---

## 六、高频面试题

### 1. HashMap 为什么线程不安全？

- **JDK 1.7**：扩容时头插法可能导致**死循环**（链表成环）
- **JDK 1.8**：尾插法解决了死循环，但 put 和 get 无同步，会导致**数据覆盖**（丢失更新）

### 2. 为什么 ConcurrentHashMap 不允许 null？

因为无法区分"key 不存在"和"key 映射为 null"，在并发环境下会有歧义。HashMap 是单线程的，`get()` 返回 null 可以通过 `containsKey()` 确认。

### 3. 为什么 HashMap 的容量是 2 的幂？

- 位运算 `(n-1) & hash` 替代取模，效率更高
- 扩容后元素要么在**原位**，要么在**原位置+旧容量**，方便迁移

### 4. 负载因子 0.75 的意义？

时间和空间的权衡：
- **太大**（如 1）：空间利用率高，但哈希碰撞概率大，查询慢
- **太小**（如 0.5）：查询快，但频繁扩容浪费空间
- **0.75**：泊松分布下链表长度超过 8 的概率 < 千万分之一

---

## 总结

- **HashMap**：日常首选，Hash 表之王
- **LinkedHashMap**：需要保持顺序时使用，LRU 缓存利器
- **TreeMap**：需要排序/范围查询时使用，红黑树实现
- **ConcurrentHashMap**：并发场景首选，CAS + synchronized + volatile 三重保障

理解 Map 源码的关键是理解设计的**权衡**：时间 vs 空间、读 vs 写、锁粒度 vs 并发度。掌握了这些，面试和实战都不慌。
