---
title: 【面试必备】并发容器全家桶：ConcurrentLinkedQueue、CopyOnWriteArrayList、ConcurrentSkipListMap 源码分析
date: 2026-06-26 08:00:00
tags:
  - Java
  - 并发
  - 集合
  - 源码分析
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【面试必备】并发容器全家桶：ConcurrentLinkedQueue、CopyOnWriteArrayList、ConcurrentSkipListMap 源码分析

## 面试官：除了 ConcurrentHashMap，你还知道哪些并发容器？

很多面试者只知道 ConcurrentHashMap，其实 JUC 包下还有一批高效的并发容器，今天我们来逐一啃掉它们。

## 一、ConcurrentLinkedQueue：无锁并发队列

### 1.1 概述

ConcurrentLinkedQueue 是一个基于**链表**的、**无界**、**线程安全**的队列，采用 **CAS + 自旋** 实现无锁并发。

```java
// 继承关系
public class ConcurrentLinkedQueue<E> extends AbstractQueue<E>
        implements Queue<E>, java.io.Serializable {
    // 内部节点
    private static class Node<E> {
        volatile E item;
        volatile Node<E> next;
    }
    
    private transient volatile Node<E> head;
    private transient volatile Node<E> tail;
}
```

### 1.2 offer() 入队源码分析

```java
public boolean offer(E e) {
    checkNotNull(e);
    final Node<E> newNode = new Node<>(e);
    
    // 自旋 CAS 入队
    for (Node<E> t = tail, p = t;;) {
        Node<E> q = p.next;
        if (q == null) {
            // CASE 1: p 是尾节点
            if (p.casNext(null, newNode)) {
                // CAS 成功
                if (p != t)  // 如果经过至少一个节点才到达尾部
                    casTail(t, newNode);  // 更新 tail（允许失败）
                return true;
            }
            // CAS 失败，重试
        } else if (p == q) {
            // CASE 2: 哨兵节点（自引用的节点，说明被其他线程删除了）
            p = (t != (t = tail)) ? t : head;
        } else {
            // CASE 3: 不是尾节点，向后移动
            p = (p != t && t != (t = tail)) ? t : q;
        }
    }
}
```

**关键设计：**
- tail 不一定是真正的尾节点！Tail 的更新是**懒惰**的
- 通过 `p = (p != t && t != (t = tail)) ? t : q` 这个复杂表达式减少 CAS 次数
- 两个 CAS 节点竞争 tail 更新，偶尔更新一次减少开销

### 1.3 poll() 出队源码

```java
public E poll() {
    restartFromHead:
    for (;;) {
        for (Node<E> h = head, p = h, q;;) {
            E item = p.item;
            
            if (item != null && p.casItem(item, null)) {
                // CAS 将 item 置为 null 成功
                if (p != h) // 更新 head
                    updateHead(h, (q = p.next) != null ? q : p);
                return item;
            } else if ((q = p.next) == null) {
                // 队列为空
                updateHead(h, p);
                return null;
            } else if (p == q) {
                // 哨兵节点
                continue restartFromHead;
            } else {
                p = q;
            }
        }
    }
}
```

### 1.4 哨兵节点（Sentinel Node）

ConcurrentLinkedQueue 中有一个有趣的设计——**哨兵节点**（也叫逻辑删除节点）：

```java
// 当节点被移除时，next 指向自己
Node<E> q = p.next;
if (p == q) {
    // 说明 p 节点已被删除
    // 需要重新从 head 开始遍历
}
```

哨兵节点是并发删除时造成的，它的存在告诉其他线程："这个节点已经没了，请从头找起"。这种设计避免了在无锁数据结构中维护复杂的删除状态。

### 1.5 实战建议

```java
// ✅ 适合场景：高并发下的生产者-消费者队列
ConcurrentLinkedQueue<Task> queue = new ConcurrentLinkedQueue<>();

// 生产者
public void produce(Task task) {
    queue.offer(task);
}

// 消费者（注意：非阻塞，需要自己处理空队列）
public Task consume() {
    Task task = queue.poll();
    if (task == null) {
        // 队列为空，短暂等待或返回 null
    }
    return task;
}
```

| 特性 | ConcurrentLinkedQueue | LinkedBlockingQueue |
|------|----------------------|-------------------|
| **锁** | 无锁（CAS） | ReentrantLock |
| **队列类型** | 无界 | 有界/无界 |
| **阻塞操作** | 不阻塞，返回 null | take() 阻塞 |
| **适合场景** | 高吞吐低延迟 | 需要背压的场景 |

> **面试易错点：** ConcurrentLinkedQueue.size() 是 O(n) 操作！因为每次都要遍历链表统计。高并发场景建议用 ConcurrentLinkedQueue 配合 AtomicInteger 计数。

## 二、CopyOnWriteArrayList：写时复制的并发列表

### 2.1 设计思想

CopyOnWriteArrayList 的核心理念是：**读操作无锁，写操作复制一份新数组**。适用于**读多写极少**的场景。

```java
public class CopyOnWriteArrayList<E>
    implements List<E>, RandomAccess, Cloneable, java.io.Serializable {
    
    // 唯一的可变状态：volatile 修饰的数组
    private transient volatile Object[] array;
    
    final Object[] getArray() { return array; }
    final void setArray(Object[] a) { array = a; }
}
```

### 2.2 add() 源码分析

```java
public boolean add(E e) {
    final ReentrantLock lock = this.lock;
    lock.lock();  // 写操作加锁
    try {
        Object[] elements = getArray();
        int len = elements.length;
        // 复制一份新数组，长度+1
        Object[] newElements = Arrays.copyOf(elements, len + 1);
        newElements[len] = e;
        setArray(newElements);  // 替换引用
        return true;
    } finally {
        lock.unlock();
    }
}
```

### 2.3 get() 源码分析

```java
public E get(int index) {
    return get(getArray(), index);  // 无锁读取
}

private E get(Object[] a, int index) {
    return (E) a[index];  // 直接从数组取
}
```

读操作完全不加锁！因为 array 是 volatile 引用，而数组一旦发布就不可变。

### 2.4 弱一致性迭代器

```java
CopyOnWriteArrayList<String> list = new CopyOnWriteArrayList<>();
list.add("A");
list.add("B");

Iterator<String> it = list.iterator(); // 此时 snapshot = ["A", "B"]
list.add("C");  // 生成新数组 ["A", "B", "C"]

// 迭代器看到的仍然是旧数组 ["A", "B"]
while (it.hasNext()) {
    System.out.println(it.next()); // A, B（看不到C）
}
```

**原因：** `iterator()` 返回的 COWIterator 持有创建时的数组快照：

```java
public Iterator<E> iterator() {
    return new COWIterator<E>(getArray(), 0);
}

static final class COWIterator<E> implements ListIterator<E> {
    private final Object[] snapshot; // 创建时的数组快照
    private int cursor;
    
    public boolean hasNext() { return cursor < snapshot.length; }
}
```

### 2.5 适用场景与性能对比

| 操作 | CopyOnWriteArrayList | Collections.synchronizedList |
|-----|---------------------|---------------------------|
| 读（100万次） | ~5ms（无锁） | ~80ms（全加锁） |
| 写（1万次） | ~500ms（复制数组） | ~20ms（仅加锁） |

**✅ 最佳使用场景：**
- 白名单/黑名单配置（极少修改，频繁读取）
- 事件监听器列表（注册一次，反复通知）
- 缓存不可变数据

**❌ 避免使用场景：**
- 频繁写入（每次写都是 O(n) 复制）
- 数据量大（每次复制代价高）
- 要求强一致性的迭代

```java
// ✅ 典型应用：Spring 事件监听器使用 CopyOnWriteArrayList 存储
// 监听器注册后几乎不变，但事件触发时频繁遍历通知
private final CopyOnWriteArraySet<ApplicationListener<?>> applicationListeners;
```

> **面试追问：** CopyOnWriteArraySet 怎么实现的？
> 答：底层使用 CopyOnWriteArrayList，通过 addIfAbsent() 确保元素唯一，但每次 add 都要遍历数组，性能比 HashSet 差很多。

## 三、ConcurrentSkipListMap：跳表实现的并发有序 Map

### 3.1 什么是跳表？

跳表是一种**基于概率**的有序数据结构，由 William Pugh 在 1989 年提出。它通过多级索引实现 O(log n) 的查找效率。

```
Level 3:  1 -----------------------------> 9
Level 2:  1 --------> 5 ---------> 7 ----> 9
Level 1:  1 --> 3 --> 5 --> 6 --> 7 --> 8 --> 9
Level 0:  1->2->3->4->5->6->7->8->9
```

**跳表 vs 红黑树：**

| 特性 | ConcurrentSkipListMap | TreeMap/TreeSet |
|------|---------------------|----------------|
| 并发性 | CAS 无锁 | 需外部同步 |
| 实现难度 | 相对简单 | 复杂 |
| 范围查询 | 优秀 | 优秀 |
| 内存占用 | 较高（多级索引） | 较低 |

### 3.2 数据结构

```java
public class ConcurrentSkipListMap<K,V> extends AbstractMap<K,V>
    implements ConcurrentNavigableMap<K,V>, Cloneable, Serializable {
    
    // 头节点（不存储 key）
    private transient HeadIndex<K,V> head;
    
    // Node：真正的数据节点
    static final class Node<K,V> {
        final K key;
        volatile Object value;  // value 为 null 表示逻辑删除
        volatile Node<K,V> next;
    }
    
    // Index：索引节点
    static class Index<K,V> {
        final Node<K,V> node;     // 指向的数据节点
        final Index<K,V> down;    // 下层索引
        volatile Index<K,V> right; // 同层下一索引
    }
    
    // HeadIndex：头索引节点（包含当前层级数）
    static final class HeadIndex<K,V> extends Index<K,V> {
        final int level;  // 当前层级
    }
}
```

### 3.3 put() 源码分析

```java
public V put(K key, V value) {
    if (value == null) throw new NullPointerException();
    return doPut(key, value, false);
}

private V doPut(K key, V value, boolean onlyIfAbsent) {
    Node<K,V> z;
    final Node<K,V> b = findPredecessor(key, cmp);  // 找前驱节点
    
    // CAS 插入到底层链表中
    // ... 插入成功后，通过随机数决定是否创建索引层级
    int rnd = ThreadLocalRandom.nextSecondarySeed();
    if ((rnd & 0x80000001) == 0) { // 概率约 1/4
        int level = 1;
        while (((rnd >>>= 1) & 1) != 0)  // 计算索引层数
            level++;
        // ... 从下往上建立索引链
    }
}
```

### 3.4 查找过程

```java
// findPredecessor：从最高层开始向右向下查找
private Node<K,V> findPredecessor(Object key, Comparator<? super K> cmp) {
    Index<K,V> q = head;
    Index<K,V> r = q.right;
    
    for (;;) {
        if (r != null) {
            Node<K,V> n = r.node;
            K k = n.key;
            if (n.value == null) {
                // 节点已删除，CAS 跳过
                if (!q.casRight(r, r.right))
                    continue;
                r = q.right;
                continue;
            }
            if (cpr(cmp, key, k) > 0) { // key > k，向右
                q = r;
                r = r.right;
                continue;
            }
        }
        // 向右到头了，向下
        if ((d = q.down) != null) {
            q = d;
            r = d.right;
        } else {
            return n;  // 到底层了
        }
    }
}
```

**查找路径示例：** 查找 key=7
1. Level 2: head → 1 (比较 7 > 1) → 9 (比较 7 < 9，下)
2. Level 1: 1 → 5 (比较 7 > 5) → 7 (找到了)

### 3.5 并发安全保证

ConcurrentSkipListMap 的并发安全通过以下方式保证：
- **CAS 操作**：更新节点 next 引用、索引的 right 引用
- **标记节点（Marker Node）**：删除时先标记再删除，保证并发安全
- **不可变 key**：key 一旦插入不可修改

```java
// 删除节点中的标记机制
// 删除过程为：找到节点 n → 在 n 后面插入 Marker → CAS 删除 n
// Marker 节点确保其他线程不会在 n 后面继续插入
```

### 3.6 核心方法复杂度

| 方法 | 时间复杂度 | 说明 |
|------|-----------|------|
| get(key) | O(log n) | 从上到下遍历索引 |
| put(key, value) | O(log n) | 查找 + CAS 插入 |
| remove(key) | O(log n) | 标记 + 删除 |
| subMap() | O(log n) | 返回视图，迭代 O(k) |
| firstKey()/lastKey() | O(log n) | 沿最左/最右路径 |

## 四、实战对比：如何选择合适的并发容器？

| 需求 | 推荐容器 | 理由 |
|------|---------|------|
| 高并发 Queue（无阻塞） | ConcurrentLinkedQueue | CAS 无锁，吞吐量最高 |
| 高并发 Queue（需阻塞） | LinkedBlockingQueue | 支持 take() 阻塞等待 |
| 读多写极少（List） | CopyOnWriteArrayList | 读无锁，适合缓存 |
| 读多写极少（Set） | CopyOnWriteArraySet | 基于 COWArrayList |
| 有序并发 Map | ConcurrentSkipListMap | 唯一有序并发 Map |
| 无序并发 Map | ConcurrentHashMap | 哈希表，性能最好 |
| 并发 NavigableSet | ConcurrentSkipListSet | 基于 SkipListMap |

## 五、面试追问清单

1. **ConcurrentLinkedQueue 的 tail 一定指向尾节点吗？** → 不一定，是懒惰更新
2. **CopyOnWriteArrayList 保证数据最终一致性还是强一致性？** → 最终一致性（弱一致迭代器）
3. **跳表的时间复杂度为什么是 O(log n)？** → 多级索引，每层跳过多余元素
4. **ConcurrentSkipListMap 和 ConcurrentHashMap 如何选择？** → 需要排序用 SkipListMap，否则用 CHM
5. **CopyOnWriteArrayList 的 remove 怎么实现？** → 复制除目标元素外的所有元素到新数组
6. **ConcurrentLinkedQueue 的 size() 为什么不准？** → 遍历过程中可能被修改，且是 O(n) 操作

以上就是并发容器全家桶的源码级剖析。从无锁队列到写时复制，再到跳表实现的有序并发 Map，这些东西能帮你在面试中脱颖而出，也能让你在实际选型时更有底气。
