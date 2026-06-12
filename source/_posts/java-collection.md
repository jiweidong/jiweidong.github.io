---
title: Java 集合框架详解（面试跳槽篇）
date: 2026-06-13 06:30:00
tags:
  - Java
  - 集合
  - HashMap
  - ArrayList
  - 源码分析
categories: Java核心
author: 东哥
---

> **面试跳槽季来临，Java 集合框架是必考的重中之重。本文从源码层面深度剖析 ArrayList、HashMap 等核心集合的实现原理、扩容机制、线程安全问题，助你从容应对面试。**

## 一、集合框架概览

Java 集合框架（Java Collections Framework，JCF）是 Java 最核心的基础库之一，位于 `java.util` 包中。它主要分为两大体系：

- **Collection 接口**：存储单元素对象的集合
  - List：有序、可重复（ArrayList、LinkedList、Vector）
  - Set：无序、不可重复（HashSet、TreeSet、LinkedHashSet）
  - Queue：队列（PriorityQueue、ArrayDeque）
- **Map 接口**：存储键值对（HashMap、TreeMap、LinkedHashMap、ConcurrentHashMap）

所有集合类的顶层是 `Iterable` 接口，它定义了 `iterator()` 方法，使得集合可以被 `for-each` 遍历。

```
         Iterable (iterator())
             ↓
         Collection (add, remove, size, contains...)
        /        |        \
     List       Set       Queue
      |         |          |
  ArrayList  HashSet    PriorityQueue
  LinkedList TreeSet    ArrayDeque
   Vector    LinkedHashSet

   Map (put, get, remove, size...)
    |
  HashMap
  TreeMap
  LinkedHashMap
  ConcurrentHashMap
```

Collection 和 Map 并非继承关系，它们从设计之初就是两个独立的接口体系。Collection 存储单列元素，Map 存储双列键值对。但 Map 可以通过 `keySet()`、`values()`、`entrySet()` 返回相应的 Collection 视图。

## 二、List 接口详解

### 1. ArrayList — 动态数组

ArrayList 是日常开发中使用最频繁的集合类之一，底层采用 **Object 数组** 存储元素。

**核心源码片段：**

```java
// ArrayList 核心字段
private static final int DEFAULT_CAPACITY = 10;
private static final Object[] EMPTY_ELEMENTDATA = {};
private static final Object[] DEFAULTCAPACITY_EMPTY_ELEMENTDATA = {};
transient Object[] elementData;  // 存储数据的数组
private int size;                // 实际元素个数
```

**扩容机制（JDK 17 源码）：**

当 `add` 调用时，会先检查容量是否足够，不够则触发 `grow` 方法：

```java
private Object[] grow(int minCapacity) {
    int oldCapacity = elementData.length;
    // 重点：新容量 = 旧容量 + 旧容量 >> 1，即 1.5 倍扩容
    int newCapacity = oldCapacity + (oldCapacity >> 1);
    if (newCapacity - minCapacity < 0)
        newCapacity = minCapacity;
    if (newCapacity - MAX_ARRAY_SIZE > 0)
        newCapacity = hugeCapacity(minCapacity);
    // 使用 Arrays.copyOf 本质是 System.arraycopy 拷贝数组
    return elementData = Arrays.copyOf(elementData, newCapacity);
}
```

关键点：
- **1.5 倍扩容**：`oldCapacity + (oldCapacity >> 1)` 右移一位相当于除以2
- 如果没有指定初始容量，默认大小为 10（懒加载，第一次 add 时才创建）
- `Arrays.copyOf` 底层调用 `System.arraycopy`，是 native 方法，效率高
- 如果在扩容时新容量超过 `MAX_ARRAY_SIZE`（`Integer.MAX_VALUE - 8`），会调用 `hugeCapacity`

**插入与删除性能：**

```java
// 在指定位置插入 — O(n)
public void add(int index, E element) {
    // ... 检查 index、ensureCapacity
    System.arraycopy(elementData, index, elementData, index + 1,
                     size - index);  // 需要移动元素
    elementData[index] = element;
    size++;
}

// 删除指定位置 — O(n)
public E remove(int index) {
    // ...
    int numMoved = size - index - 1;
    if (numMoved > 0)
        System.arraycopy(elementData, index + 1, elementData, index,
                         numMoved);  // 需要移动元素
    elementData[--size] = null;  // 让 GC 回收
    return oldValue;
}
```

**批量操作优化：**

```java
// 提前扩容，避免多次扩容导致的性能损失
ArrayList<Object> list = new ArrayList<>();
// 如果能预知数据量，调用 ensureCapacity
list.ensureCapacity(10000);
// 或者直接指定初始容量
ArrayList<Object> list2 = new ArrayList<>(10000);
```

### 2. LinkedList — 双向链表

LinkedList 底层采用 **双向链表** 结构：

```java
// LinkedList 节点内部类
private static class Node<E> {
    E item;
    Node<E> next;
    Node<E> prev;
    
    Node(Node<E> prev, E element, Node<E> next) {
        this.item = element;
        this.next = next;
        this.prev = prev;
    }
}
```

**增删与查找：**

```java
// 头插法 — O(1)
private void linkFirst(E e) {
    final Node<E> f = first;
    final Node<E> newNode = new Node<>(null, e, f);
    first = newNode;
    if (f == null)
        last = newNode;
    else
        f.prev = newNode;
    size++;
}

// 随机访问 — O(n)
public E get(int index) {
    checkElementIndex(index);
    // 二分查找优化：index < size/2 从头遍历，否则从尾遍历
    return node(index).item;  // node 方法内部是折半遍历
}
```

LinkedList 的 `node(int index)` 方法做了一个小优化：如果 index 小于 size/2 则从头遍历，否则从尾遍历，将随机访问的时间优化到 O(n/2)，依然是 O(n) 复杂度。

### 3. ArrayList vs LinkedList — 6 维度对比

| 对比维度 | ArrayList | LinkedList |
|---------|----------|-----------|
| **底层结构** | 动态数组（Object[]） | 双向链表（Node） |
| **随机访问 get/set** | O(1) ✅ | O(n) ❌ |
| **头部插入/删除** | O(n) 需要移动元素 | O(1) 修改指针 |
| **尾部插入/删除** | O(1) 摊销 | O(1) |
| **内存占用** | 较小，仅存数据 | 较大，每个节点需额外存储 prev/next 指针 |
| **CPU缓存友好** | ✅ 连续内存，缓存局部性好 | ❌ 节点分散，缓存命中率低 |

**面试回答要点**：在实际开发中，90% 的场景使用 ArrayList。即使有频繁的插入删除，也要考虑到 ArrayList 的 CPU 缓存友好性。LinkedList 真正的优势场景在于：频繁的头部插入 + 不依赖随机访问的队列/双端队列操作。

### 4. Vector / Stack — 历史遗留

Vector 是 JDK 1.0 就存在的类，与 ArrayList 底层相同，都是数组结构。最大的区别在于 Vector 的几乎所有方法都用 `synchronized` 修饰：

```java
// Vector 所有公开方法都加了 synchronized
public synchronized boolean add(E e) { ... }
public synchronized E get(int index) { ... }
public synchronized E remove(int index) { ... }
```

这种全量同步在单线程下带来不必要的性能开销，因此在 JDK 1.2 引入 ArrayList 作为替代。Stack 继承自 Vector，在 Vector 基础上增加了 push/pop/peek 方法。

**面试常问：为什么不推荐使用 Vector？**
- 全量同步性能差，推荐使用 Collections.synchronizedList 或 CopyOnWriteArrayList
- 扩容策略不同：ArrayList 是 1.5 倍，Vector 是 2 倍
- Stack 把继承当复用，破坏了 Liskov 替换原则

### 5. CopyOnWriteArrayList — 读写分离

CopyOnWriteArrayList 是 `java.util.concurrent` 包下的线程安全 List，采用 **读写分离** 思想：

```java
// 核心思想：写时复制
public boolean add(E e) {
    synchronized (lock) {
        Object[] elements = getArray();
        int len = elements.length;
        // 复制出一个新数组（长度+1）
        Object[] newElements = Arrays.copyOf(elements, len + 1);
        newElements[len] = e;
        // 用新数组替换旧数组
        setArray(newElements);
        return true;
    }
}

// 读操作不加锁，直接读数组
public E get(int index) {
    return getArray()[index];  // 不需要同步！
}
```

**适用场景**：读多写少、数据量不大。例如白名单、配置信息缓存。不适合写频繁的场景，因为每次写都会复制整个数组。

## 三、Map 接口详解

### 1. HashMap（核心重点）

HashMap 是面试中**最高频**的考点，没有之一。我们一步步深入源码。

#### 底层数据结构演进

| 版本 | 数据结构 | 解决的问题 |
|-----|---------|----------|
| JDK 1.7 | 数组 + 链表 | 基础哈希表实现 |
| JDK 1.8 | 数组 + 链表 + 红黑树 | 解决链表过长时的性能退化 |

```java
// JDK 1.8+ 核心字段
static final int DEFAULT_INITIAL_CAPACITY = 1 << 4; // 16
static final float DEFAULT_LOAD_FACTOR = 0.75f;
static final int TREEIFY_THRESHOLD = 8;        // 链表转红黑树阈值
static final int UNTREEIFY_THRESHOLD = 6;      // 红黑树转链表阈值
static final int MIN_TREEIFY_CAPACITY = 64;    // 最小树化容量

transient Node<K,V>[] table;  // Node 数组
transient int size;
int threshold;  // 扩容阈值 = capacity * loadFactor
final float loadFactor;
```

#### put 方法完整流程

```java
final V putVal(int hash, K key, V value, boolean onlyIfAbsent, boolean evict) {
    Node<K,V>[] tab; Node<K,V> p; int n, i;
    
    // 1. 数组为空则初始化（resize）
    if ((tab = table) == null || (n = tab.length) == 0)
        n = (tab = resize()).length;
    
    // 2. 计算索引：(n - 1) & hash
    //    如果该位置为空，直接插入
    if ((p = tab[i = (n - 1) & hash]) == null)
        tab[i] = newNode(hash, key, value, null);
    else {
        Node<K,V> e; K k;
        
        // 3. 如果 key 已存在，覆盖
        if (p.hash == hash && ((k = p.key) == key || (key != null && key.equals(k))))
            e = p;
        // 4. 如果是红黑树节点，走红黑树插入
        else if (p instanceof TreeNode)
            e = ((TreeNode<K,V>)p).putTreeVal(this, tab, hash, key, value);
        // 5. 链表插入（尾插法，JDK 7 是头插法）
        else {
            for (int binCount = 0; ; ++binCount) {
                if ((e = p.next) == null) {
                    p.next = newNode(hash, key, value, null);
                    // 链表长度达到 8，转红黑树
                    if (binCount >= TREEIFY_THRESHOLD - 1)
                        treeifyBin(tab, hash);
                    break;
                }
                if (e.hash == hash && ((k = e.key) == key || (key != null && key.equals(k))))
                    break;
                p = e;
            }
        }
        
        // 6. 如果 key 已存在，返回旧值
        if (e != null) {
            V oldValue = e.value;
            if (!onlyIfAbsent || oldValue == null)
                e.value = value;
            return oldValue;
        }
    }
    
    ++modCount;
    // 7. 判断是否需要扩容
    if (++size > threshold)
        resize();
    return null;
}
```

**关键步骤总结：**
1. 计算 hash：`(key.hashCode()) ^ (key.hashCode() >>> 16)` — 扰动函数
2. 计算索引：`(n - 1) & hash` — 替代取模运算
3. 如果桶为空 → 直接放入
4. 如果桶不为空 → 遍历链表/红黑树
5. 链表长度 ≥ 8 且数组长度 ≥ 64 → 转红黑树
6. 如果 key 已存在 → 覆盖 value
7. 如果 size > threshold → resize 扩容

#### 扩容机制（resize 方法）

```java
final Node<K,V>[] resize() {
    Node<K,V>[] oldTab = table;
    int oldCap = (oldTab == null) ? 0 : oldTab.length;
    int oldThr = threshold;
    int newCap, newThr = 0;
    
    // 1. 计算新容量和新阈值（2 倍扩容）
    if (oldCap > 0) {
        if (oldCap >= MAXIMUM_CAPACITY) {
            threshold = Integer.MAX_VALUE;
            return oldTab;
        }
        // 重点：新容量 = 旧容量 << 1，即 2 倍
        newCap = oldCap << 1;
        newThr = oldThr << 1;
    } else if (oldThr > 0) {
        newCap = oldThr;
    } else {
        newCap = DEFAULT_INITIAL_CAPACITY;  // 16
        newThr = (int)(DEFAULT_LOAD_FACTOR * DEFAULT_INITIAL_CAPACITY);  // 12
    }
    
    // 2. 创建新数组
    Node<K,V>[] newTab = (Node<K,V>[])new Node[newCap];
    table = newTab;
    
    // 3. 数据迁移（rehash）
    if (oldTab != null) {
        for (int j = 0; j < oldCap; ++j) {
            Node<K,V> e;
            if ((e = oldTab[j]) != null) {
                oldTab[j] = null;
                // 单个节点直接迁移
                if (e.next == null)
                    newTab[e.hash & (newCap - 1)] = e;
                // 红黑树节点特殊处理
                else if (e instanceof TreeNode)
                    ((TreeNode<K,V>)e).split(this, newTab, j, oldCap);
                // 链表：拆分为两个链表（精华优化）
                else {
                    // lo 链表：索引不变
                    // hi 链表：索引 = 原索引 + oldCap
                    Node<K,V> loHead = null, loTail = null;
                    Node<K,V> hiHead = null, hiTail = null;
                    Node<K,V> next;
                    do {
                        next = e.next;
                        // 判断关键：e.hash & oldCap == 0 ?
                        if ((e.hash & oldCap) == 0) {
                            if (loTail == null)
                                loHead = e;
                            else
                                loTail.next = e;
                            loTail = e;
                        } else {
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
                        newTab[j] = loHead;           // 原索引
                    }
                    if (hiTail != null) {
                        hiTail.next = null;
                        newTab[j + oldCap] = hiHead;  // 原索引 + oldCap
                    }
                }
            }
        }
    }
    return newTab;
}
```

**rehash 优化**：JDK 8 采用 `e.hash & oldCap == 0` 来判断元素在新数组中的位置。因为容量是 2 的幂次，扩容一倍后元素的索引要么不变，要么为原索引 + oldCap。这个优化避免了 JDK 7 中每个元素都要重新计算 hash。

#### 为什么引入红黑树？

```java
// 链表长度达到 8 时触发树化
static final int TREEIFY_THRESHOLD = 8;
```

**原因**：防止哈希碰撞攻击。如果恶意构造大量 hash 值相同的 key，会导致链表极长，put/get 退化为 O(n)。引入红黑树后，最坏情况从 O(n) 降到 O(log n)。

红黑树特性：
- 平衡二叉搜索树
- 自平衡（旋转 + 变色）
- 插入/删除/查找 O(log n)

**树化条件**：链表长度 ≥ 8 **并且** 数组长度 ≥ 64。如果数组长度 < 64，即使链表长度 ≥ 8，也只会触发扩容而非树化。

#### 为什么负载因子是 0.75？

这是时间和空间成本的权衡：
- **负载因子 = 1**：空间利用率更高，但冲突增加，查询性能下降
- **负载因子 = 0.5**：冲突少，但空间浪费严重，频繁扩容
- **0.75**：Poisson 分布证明，当负载因子为 0.75 时，链表长度达到 8 的概率极低（小于千万分之一），是空间与时间的平衡点

#### 为什么容量是 2 的幂次？

```java
// 取模优化：用位运算替代取模，效率高 10 倍
// hash % n 等价于 hash & (n - 1) —— n 必须是 2 的幂次
index = (n - 1) & hash;
```

两个原因：
1. **位运算替代取模**：`(n - 1) & hash` 比 `hash % n` 快得多
2. **均匀分布**：2 的幂次 - 1 的二进制全为 1，能最大限度保证 hash 均匀分布

#### 多线程死循环问题（JDK 7）

JDK 7 的 HashMap 采用 **头插法** 解决哈希冲突，在多线程并发扩容时会出现 **环形链表**，导致 get 操作死循环。

```java
// JDK 7 扩容时的 transfer 方法（简化）
void transfer(Entry[] newTable) {
    Entry[] src = table;
    for (int j = 0; j < src.length; j++) {
        Entry e = src[j];
        if (e != null) {
            src[j] = null;
            do {
                Entry next = e.next;
                // 头插法：新元素插入到链表头部
                e.next = newTable[j];
                newTable[j] = e;
                e = next;
            } while (e != null);
        }
    }
}
```

多线程环境下，两个线程同时扩容，头插法会导致 prev-next 引用关系颠倒形成环。JDK 8 改为 **尾插法** 解决了这个问题，但 HashMap 本身不保证线程安全，多线程场景请使用 ConcurrentHashMap。

### 2. LinkedHashMap

LinkedHashMap 继承自 HashMap，在节点中增加了 before/after 指针维护双向链表，支持两种遍历顺序：

```java
// LinkedHashMap 节点
static class Entry<K,V> extends HashMap.Node<K,V> {
    Entry<K,V> before, after;  // 双向链表指针
}
```

- **插入顺序**（默认）：按插入顺序遍历，可用来实现 FIFO 缓存
- **访问顺序**（accessOrder = true）：按访问顺序排序，可用来实现 **LRU 缓存**（最近最少使用）

```java
// LRU 缓存实现
class LRUCache<K,V> extends LinkedHashMap<K,V> {
    private final int capacity;
    
    public LRUCache(int capacity) {
        super(capacity, 0.75f, true);  // accessOrder = true
        this.capacity = capacity;
    }
    
    // 超过容量时删除最旧的元素
    @Override
    protected boolean removeEldestEntry(Map.Entry<K,V> eldest) {
        return size() > capacity;
    }
}
```

### 3. TreeMap

TreeMap 基于 **红黑树（Red-Black Tree）** 实现，元素按照 key 的自然顺序或 Comparator 排序：

```java
// 自然排序（key 必须实现 Comparable）
TreeMap<Integer, String> treeMap = new TreeMap<>();

// 自定义排序
TreeMap<Integer, String> treeMap = new TreeMap<>((a, b) -> b - a); // 降序

// 常用方法
treeMap.firstKey();        // 最小 key
treeMap.lastKey();         // 最大 key
treeMap.lowerKey(5);       // 小于 5 的最大 key
treeMap.higherKey(5);      // 大于 5 的最小 key
treeMap.subMap(3, 8);      // [3, 8) 的子视图
```

### 4. Hashtable

Hashtable 是 JDK 1.0 的遗留类：
- 所有方法用 `synchronized` 修饰（线程安全但性能差）
- **不允许 null key 和 null value**
- 同 Vector 一样，已经不推荐使用

### 5. ConcurrentHashMap

ConcurrentHashMap 是 HashMap 的线程安全版本，是面试高频考点。

#### JDK 7：Segment 分段锁

```java
// 分段锁结构
static final class Segment<K,V> extends ReentrantLock {
    transient volatile HashEntry<K,V>[] table;
}
```

- 将数据分为 16 个 Segment（默认并发级别）
- 每个 Segment 独立加锁，降低锁竞争
- put 只需要锁一个 Segment，理论上支持 16 个线程并发写
- 缺点：Segments 数量固定，扩容复杂

#### JDK 8：synchronized + CAS

JDK 8 彻底重构了 ConcurrentHashMap，放弃了 Segment：

```java
// 核心 put 流程
final V putVal(K key, V value, boolean onlyIfAbsent) {
    // ...
    for (Node<K,V>[] tab = table;;) {
        Node<K,V> f; int n, i, fh;
        if (tab == null || (n = tab.length) == 0)
            tab = initTable();      // CAS 初始化
        else if ((f = tabAt(tab, i = (n - 1) & hash)) == null) {
            // 桶为空，CAS 无锁插入
            if (casTabAt(tab, i, null, new Node<K,V>(hash, key, value)))
                break;
        } else if ((fh = f.hash) == MOVED)
            tab = helpTransfer(tab, f);  // 协助扩容
        else {
            // 桶不为空，对链表/红黑树头节点加锁
            synchronized (f) {
                // 写入链表或红黑树
            }
        }
    }
}
```

**JDK 8 改进**：
- 锁粒度：从 Segment 级别细化为桶级别（每个数组元素一把锁）
- 使用 synchronized 替代 ReentrantLock（synchronized 在 JDK 6 后性能已大幅优化）
- put 流程大量使用 CAS 操作（乐观锁），只在碰撞时使用 synchronized
- 并发扩容：多个线程可以协同完成扩容（`helpTransfer`）

## 四、Set 接口详解

Set 接口本质上是对 Map 的封装：

| Set 实现 | 底层 Map | 特点 |
|---------|---------|------|
| HashSet | HashMap | 无序，O(1) 增删查 |
| TreeSet | TreeMap（NavigableMap） | 排序，O(log n) 增删查 |
| LinkedHashSet | LinkedHashMap | 维持插入顺序 |

**HashSet 源码极其简单：**

```java
public class HashSet<E> {
    private transient HashMap<E,Object> map;
    private static final Object PRESENT = new Object(); // 占位 value
    
    public boolean add(E e) {
        return map.put(e, PRESENT) == null;
    }
}
```

**去重原理**：Set 的去重依赖于 `equals()` 和 `hashCode()` 约定：
1. 先比较 hashCode（快速判断）
2. 如果 hashCode 相同，再比较 equals（精细判断）
3. 两个对象 equals 相等，hashCode 必须相等（否则会导致数据不一致）

```java
// 正确实现自定义对象去重
public class User {
    private String name;
    private int age;
    
    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        User user = (User) o;
        return age == user.age && Objects.equals(name, user.name);
    }
    
    @Override
    public int hashCode() {
        return Objects.hash(name, age);
    }
}
```

## 五、Queue 与 Deque

### PriorityQueue

基于 **小顶堆（Min Heap）** 实现的优先队列：

```java
// 默认小顶堆
PriorityQueue<Integer> pq = new PriorityQueue<>();
pq.offer(5);  // 入队

// 大顶堆
PriorityQueue<Integer> pq = new PriorityQueue<>((a, b) -> b - a);
```

### ArrayDeque

基于 **循环数组** 实现的双端队列：

```java
ArrayDeque<String> deque = new ArrayDeque<>();
deque.addFirst("头");
deque.addLast("尾");
deque.removeFirst();
```

比 LinkedList 作为队列时性能更好（更少的内存碎片和更好的缓存局部性）。

### BlockingQueue 系列

`java.util.concurrent.BlockingQueue` 是线程安全的阻塞队列，常用于生产者-消费者模式：

| 实现 | 特点 |
|-----|------|
| ArrayBlockingQueue | 有界数组阻塞队列，先进先出 |
| LinkedBlockingQueue | 可选有界的链表阻塞队列 |
| PriorityBlockingQueue | 支持优先级的无界阻塞队列 |
| SynchronousQueue | 不存储元素，每个 put 必须等待一个 take |
| DelayQueue | 延迟队列，元素到期才能取出 |

## 六、面试高频题总结

### 1. fail-fast vs fail-safe

- **fail-fast（快速失败）**：遍历时检测到结构修改，立即抛出 `ConcurrentModificationException`
  - 如 HashMap、ArrayList 等非并发集合
  - 通过 `modCount` 字段实现
- **fail-safe（安全失败）**：遍历时操作的是集合的副本，不会抛出异常
  - 如 ConcurrentHashMap、CopyOnWriteArrayList
  - 代价是遍历的是快照，不保证读到最新数据

### 2. modCount 的作用

```java
// AbstractList 中的 modCount
protected transient int modCount = 0;
```

`modCount` 记录集合结构性修改的次数（add、remove、clear 等）。每次迭代器创建时都会保存 `expectedModCount = modCount`。迭代过程中，如果 `modCount != expectedModCount`，说明有其他线程修改了集合，立即抛出 ConcurrentModificationException。

```java
// Iterator 中的 checkForComodification
final void checkForComodification() {
    if (modCount != expectedModCount)
        throw new ConcurrentModificationException();
}
```

### 3. 如何选择集合实现

```java
// 需要存储单个元素
// └─ 需要有序：
//    ├─ 需要随机访问频繁：ArrayList
//    ├─ 需要频繁头尾增删：LinkedList
//    └─ 多线程读多写少：CopyOnWriteArrayList
// └─ 不需要有序 → 需要去重：HashSet
// └─ 需要排序：TreeSet
// └─ FIFO 队列：ArrayDeque

// 需要存储键值对
// └─ 需要排序：
//    ├─ 业务排序：TreeMap
//    └─ 保持插入顺序：LinkedHashMap
// └─ 不需要排序：
//    ├─ 单线程：HashMap
//    └─ 多线程：ConcurrentHashMap
```

### 4. 最常问的 10 个集合面试题

1. ✅ **HashMap 的 put 方法流程是什么？** 
2. ✅ **HashMap 扩容机制是怎样的？** 
3. ✅ **为什么 HashMap 的容量是 2 的幂次？** 
4. ✅ **负载因子为什么是 0.75？** 
5. ✅ **红黑树引入的原因和树化阈值为什么是 8？** 
6. ✅ **HashMap 线程安全问题（JDK 7 死循环 + JDK 8 数据覆盖）** 
7. ✅ **ConcurrentHashMap JDK 7 分段锁 vs JDK 8 CAS+synchronized** 
8. ✅ **ArrayList 扩容机制和与 LinkedList 的选择** 
9. ✅ **fail-fast 机制原理** 
10. ✅ **equals 和 hashCode 约定及其在 HashSet 中的作用**

## 七、性能对比总结表

### List 实现对比

| 操作 | ArrayList | LinkedList | CopyOnWriteArrayList |
|-----|----------|-----------|-------------------|
| get(int) | O(1) ✅ | O(n) ❌ | O(1) |
| add(E) | O(1) 摊销 ✅ | O(1) ✅ | O(n) |
| add(index, E) | O(n) | O(n) | O(n) |
| remove(index) | O(n) | O(n) | O(n) |
| 线程安全 | ❌ | ❌ | ✅（写复制） |
| 迭代性能 | 极快 | 较慢（节点分散） | 快（快照迭代） |

### Map 实现对比

| 操作 | HashMap | LinkedHashMap | TreeMap | ConcurrentHashMap |
|-----|--------|-------------|---------|-----------------|
| put/get | O(1) | O(1) | O(log n) | O(1) |
| 顺序 | 无序 | 插入/访问顺序 | 排序 | 无序 |
| 允许 null key | ✅ 一个 | ✅ 一个 | ❌（Comparable 会 NPE） | ❌ |
| 线程安全 | ❌ | ❌ | ❌ | ✅ |
| 迭代一致性 | 弱（可能有 modCount） | 弱 | 弱 | 弱（弱一致性） |
| 实现 | 数组+链表+红黑树 | HashMap + 双向链表 | 红黑树 | JDK 8: CAS + synchronized |

### Set 实现对比

| 操作 | HashSet | TreeSet | LinkedHashSet |
|-----|--------|---------|-------------|
| add/remove/contains | O(1) | O(log n) | O(1) |
| 顺序 | 无序 | 排序 | 插入顺序 |
| 底层 | HashMap | TreeMap | LinkedHashMap |

---

> **总结**：掌握 Java 集合框架，核心在于理解数据结构和算法。ArrayList 的动态数组扩容、HashMap 的哈希表 + 红黑树、ConcurrentHashMap 的锁优化，这些都是面试必考点。建议大家在准备面试时，多读源码、多画图、多总结对比表，做到知其然更知其所以然。

**如果本文对你有帮助，欢迎点赞收藏，祝大家面试顺利！🚀**
