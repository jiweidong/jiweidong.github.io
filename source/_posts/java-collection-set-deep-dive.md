---
title: 【Java集合】Java Set 集合源码深度解析：HashSet、TreeSet、LinkedHashSet 与 EnumSet 底层原理
date: 2026-07-14 08:00:00
tags:
  - Java
  - 集合框架
  - 源码分析
categories:
  - Java
  - 集合框架
author: 东哥
---

# 【Java集合】Java Set 集合源码深度解析：HashSet、TreeSet、LinkedHashSet 与 EnumSet 底层原理

## 前言

Set 是 Java 集合框架三大支柱之一（List、Set、Map），它的核心特性是**不包含重复元素**。如果说 List 是「有序可重复」，那 Set 就是「不可重复」的代言人。

在日常面试中，ConcurrentHashMap 和 HashMap 被问得最多，但 Set 家族的底层实现同样值得深挖——因为它背后几乎全是 Map！

> 面试官：HashSet 怎么保证元素不重复？
> 你：HashSet 底层是 HashMap，靠 key 的 equals() 和 hashCode() 来判重。

就这么简单？不，今天我们彻底把 Set 家族扒个干净。

<!-- more -->

---

## 一、Set 家族总览

Java 中的 Set 接口继承自 Collection，主要实现类包括：

| 实现类 | 底层数据结构 | 元素顺序 | 允许 null | 线程安全 |
|--------|------------|---------|----------|---------|
| HashSet | HashMap | 无序（哈希排序） | ✅ 允许1个 | ❌ |
| LinkedHashSet | LinkedHashMap | 插入顺序/LRU顺序 | ✅ 允许1个 | ❌ |
| TreeSet | TreeMap（红黑树） | 自然排序/比较器 | ❌ | ❌ |
| EnumSet | 位向量（bit vector） | 枚举定义顺序 | ❌ | ❌ |
| CopyOnWriteArraySet | CopyOnWriteArrayList | 插入顺序 | ✅ | ✅ |

本文将重点剖析前四个最常用的实现。

---

## 二、HashSet 源码深度分析

### 2.1 底层结构：HashMap 的封装

打开 HashSet 的源码，你会发现它简洁得令人惊讶——HashSet 本质上就是对 HashMap 的一层封装：

```java
public class HashSet<E> extends AbstractSet<E>
    implements Set<E>, Cloneable, java.io.Serializable {

    // 底层 HashMap
    private transient HashMap<E, Object> map;

    // 所有 value 都指向这个同一个 dummy 对象
    private static final Object PRESENT = new Object();

    public HashSet() {
        map = new HashMap<>();
    }

    public HashSet(int initialCapacity, float loadFactor) {
        map = new HashMap<>(initialCapacity, loadFactor);
    }

    // 这个构造函数是 package-private 的，供 LinkedHashSet 使用
    HashSet(int initialCapacity, float loadFactor, boolean dummy) {
        map = new LinkedHashMap<>(initialCapacity, loadFactor);
    }
}
```

**核心设计理念：**
- HashSet 的「元素」作为 HashMap 的 key
- 所有 key 共享同一个 `PRESENT` 对象作为 value
- 利用 HashMap key 的唯一性来保证 Set 元素不重复

### 2.2 CRUD 操作源码分析

**add() 方法：**

```java
public boolean add(E e) {
    // 调用 HashMap 的 put()，返回值是旧的 value 或 null
    // 如果 key 不存在，put() 返回 null → add 返回 true（添加成功）
    // 如果 key 已存在，put() 返回 PRESENT → add 返回 false（添加失败）
    return map.put(e, PRESENT) == null;
}
```

**remove() 方法：**

```java
public boolean remove(Object o) {
    // HashMap 的 remove() 返回被移除的 value 或 null
    // 移除成功返回 PRESENT，失败返回 null
    return map.remove(o) == PRESENT;
}
```

**contains() 方法：**

```java
public boolean contains(Object o) {
    return map.containsKey(o);
}
```

**迭代器：**

```java
public Iterator<E> iterator() {
    // 返回 HashMap keySet 的迭代器
    return map.keySet().iterator();
}
```

### 2.3 不重复的保证：equals() + hashCode()

HashSet 判断元素重复完全依赖 HashMap 的逻辑：

1. 先计算 `hashCode()`，找到对应的桶（bucket）
2. 如果桶为空 → 元素不重复，直接插入
3. 如果桶不为空 → 遍历桶内元素，用 `equals()` 逐个比较
4. 找到相等的 → 不插入；没找到 → 插入

```java
// HashMap.putVal() 核心判断逻辑（简化）
final V putVal(int hash, K key, V value, boolean onlyIfAbsent, boolean evict) {
    Node<K,V>[] tab; Node<K,V> p; int n, i;
    if ((tab = table) == null || (n = tab.length) == 0)
        n = (tab = resize()).length;
    if ((p = tab[i = (n - 1) & hash]) == null)
        // 桶为空，直接创建新节点
        tab[i] = newNode(hash, key, value, null);
    else {
        Node<K,V> e; K k;
        if (p.hash == hash &&
            ((k = p.key) == key || (key != null && key.equals(k))))
            // hash 和 equals 都相等 → 找到了相同 key
            e = p;
        else if (p instanceof TreeNode)
            // 红黑树查找
            e = ((TreeNode<K,V>)p).putTreeVal(this, tab, hash, key, value);
        else {
            // 链表遍历
            for (int binCount = 0; ; ++binCount) {
                if ((e = p.next) == null) {
                    // 没找到相同 key，追加到链表尾部
                    p.next = newNode(hash, key, value, null);
                    break;
                }
                if (e.hash == hash &&
                    ((k = e.key) == key || (key != null && key.equals(k))))
                    break; // 找到了
                p = e;
            }
        }
        if (e != null) { // 找到了相同 key
            V oldValue = e.value;
            if (!onlyIfAbsent || oldValue == null)
                e.value = value; // 更新 value（但 PRESENT 都是一样的）
            return oldValue; // 返回旧 value，表示 key 已存在
        }
    }
    return null; // 新插入，返回 null
}
```

### 2.4 HashSet 的自定义对象陷阱

```java
class Person {
    String name;
    int age;

    // ❌ 没有重写 hashCode() 和 equals()
}

HashSet<Person> set = new HashSet<>();
set.add(new Person("Alice", 25));
set.add(new Person("Alice", 25));
System.out.println(set.size()); // 输出 2！因为 equals 比较的是对象引用
```

**修复方式：** 必须同时重写 `equals()` 和 `hashCode()`：

```java
class Person {
    String name;
    int age;

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        Person person = (Person) o;
        return age == person.age && Objects.equals(name, person.name);
    }

    @Override
    public int hashCode() {
        return Objects.hash(name, age);
    }
}
```

> **面试高频：** 为什么重写 equals 必须重写 hashCode？
>
> 因为 HashMap（HashSet 底层）先比较 hashCode 定位桶，再比较 equals。如果两个对象 equals 相等但 hashCode 不同，它们会进入不同的桶，导致 Set 中「同时存在两个相等的元素」，违反了 Set 的语义。

---

## 三、LinkedHashSet 源码分析

### 3.1 与 HashSet 的关系

LinkedHashSet 继承自 HashSet，但底层用的是 LinkedHashMap：

```java
public class LinkedHashSet<E> extends HashSet<E>
    implements Set<E>, Cloneable, java.io.Serializable {

    public LinkedHashSet() {
        // 调用 HashSet 的 package-private 构造，创建 LinkedHashMap
        super(16, .75f, true);
    }

    public LinkedHashSet(int initialCapacity, float loadFactor) {
        super(initialCapacity, loadFactor, true);
    }
}
```

还记得 HashSet 那个包私有构造吗？

```java
HashSet(int initialCapacity, float loadFactor, boolean dummy) {
    map = new LinkedHashMap<>(initialCapacity, loadFactor);
}
```

这个 `dummy` 参数就是为了区分「创建 HashSet」还是「为 LinkedHashSet 创建底层 Map」。

### 3.2 双向链表保证顺序

LinkedHashMap 在 HashMap 的基础上，增加了**双向链表**来维护元素的插入顺序（或访问顺序）：

```java
// LinkedHashMap.Entry 继承自 HashMap.Node
static class Entry<K,V> extends HashMap.Node<K,V> {
    Entry<K,V> before, after;  // 双向链表前后指针

    Entry(int hash, K key, V value, Node<K,V> next) {
        super(hash, key, value, next);
    }
}
```

**LinkedHashSet 的优势：**
- 迭代顺序 = 元素插入顺序（可预测）
- 遍历性能略低于 HashSet（需要维护链表指针）
- 提供了 `accessOrder` 模式（LinkedHashMap 特性），可以用作 LRU 缓存

### 3.3 性能对比

```java
// 测试迭代顺序
HashSet<String> hashSet = new HashSet<>();
LinkedHashSet<String> linkedSet = new LinkedHashSet<>();

List<String> input = List.of("C", "A", "B", "D");
for (String s : input) {
    hashSet.add(s);
    linkedSet.add(s);
}

System.out.println("HashSet:     " + hashSet);     // 无序，取决于 hash 值
System.out.println("LinkedHashSet: " + linkedSet);  // [C, A, B, D] 保持插入顺序
```

---

## 四、TreeSet 源码深度解析

### 4.1 底层结构：NavigableMap（TreeMap）

TreeSet 的底层是 TreeMap（红黑树）：

```java
public class TreeSet<E> extends AbstractSet<E>
    implements NavigableSet<E>, Cloneable, java.io.Serializable {

    // 底层 NavigableMap，实际是 TreeMap
    private transient NavigableMap<E, Object> m;

    // 同样使用 PRESENT 作为 value
    private static final Object PRESENT = new Object();

    TreeSet(NavigableMap<E, Object> m) {
        this.m = m;
    }

    public TreeSet() {
        this(new TreeMap<>());
    }

    public TreeSet(Comparator<? super E> comparator) {
        this(new TreeMap<>(comparator));
    }
}
```

### 4.2 NavigableSet 丰富接口

TreeSet 实现了 NavigableSet 接口，提供了强大的范围查询：

```java
TreeSet<Integer> set = new TreeSet<>(List.of(1, 3, 5, 7, 9, 11));

// 导航方法
set.first();                // 1 - 最小元素
set.last();                 // 11 - 最大元素
set.lower(7);               // 5 - 小于 7 的最大元素
set.floor(7);               // 7 - 小于等于 7 的最大元素
set.higher(7);              // 9 - 大于 7 的最小元素
set.ceiling(8);             // 9 - 大于等于 8 的最小元素

// 子集视图
set.subSet(3, 9);           // [3, 5, 7] - [3, 9) 范围
set.subSet(3, true, 9, true); // [3, 5, 7, 9] - 包含边界
set.headSet(5);             // [1, 3] - 小于 5
set.tailSet(5);             // [5, 7, 9, 11] - 大于等于 5

// 逆序视图
set.descendingSet();        // [11, 9, 7, 5, 3, 1]

// 移除并返回
set.pollFirst();            // 移除并返回最小值
set.pollLast();             // 移除并返回最大值
```

### 4.3 红黑树的平衡机制

TreeSet 的排序和存储依赖 TreeMap 的红黑树，核心特性：

1. **每个节点是红色或黑色**
2. **根节点是黑色**
3. **叶子节点（NIL）是黑色**
4. **红色节点的子节点必须是黑色**（不能有连续的红色节点）
5. **从任一节点到其每个叶子的所有简单路径都包含相同数目的黑色节点**

```java
// TreeMap 红黑树节点
static final class Entry<K,V> implements Map.Entry<K,V> {
    K key;
    V value;
    Entry<K,V> left;   // 左子节点
    Entry<K,V> right;  // 右子节点
    Entry<K,V> parent; // 父节点
    boolean color = BLACK; // 红色或黑色
}
```

TreeSet 的 add 操作时间复杂度为 **O(log n)**，因为红黑树的插入和查询都是对数级别。

### 4.4 自定义排序

TreeSet 支持两种排序方式：

```java
// 方式一：元素实现 Comparable
public class User implements Comparable<User> {
    String name;
    int age;

    @Override
    public int compareTo(User o) {
        return Integer.compare(this.age, o.age);
    }
}

// 方式二：传入 Comparator
TreeSet<String> set = new TreeSet<>(Comparator
    .comparingInt(String::length)
    .thenComparing(Comparator.naturalOrder()));
set.addAll(List.of("Java", "C", "Python", "Rust"));
System.out.println(set); // [C, Java, Rust, Python] 先按长度，再按字母
```

### 4.5 与 hashCode 无关的判重

> **重要区别：** TreeSet 不依赖 `hashCode()` 和 `equals()` 来判重，而是依赖 `Comparable.compareTo()` 或 `Comparator.compare()`。

```java
class Item implements Comparable<Item> {
    int id;
    String name;

    public Item(int id, String name) {
        this.id = id;
        this.name = name;
    }

    @Override
    public int compareTo(Item o) {
        return Integer.compare(this.id, o.id);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        Item item = (Item) o;
        return id == item.id && Objects.equals(name, item.name);
    }
}

TreeSet<Item> treeSet = new TreeSet<>();
treeSet.add(new Item(1, "A"));
treeSet.add(new Item(1, "B"));  // compareTo 返回 0，认为是重复元素！
System.out.println(treeSet.size()); // 1

HashSet<Item> hashSet = new HashSet<>();
hashSet.add(new Item(1, "A"));
hashSet.add(new Item(1, "B"));  // hashCode/equals 不同，不重复
System.out.println(hashSet.size()); // 2
```

> **坑点：** TreeSet 的 `compareTo` 返回 0 即视为重复，与 equals 无关。这可能导致「equals 不等但被去重」或「equals 相等但没被去重」的问题。**务必保证 compareTo 与 equals 一致**（即 `compareTo == 0` 当且仅当 `equals == true`）。

---

## 五、EnumSet：最高效的 Set 实现

### 5.1 位向量存储原理

EnumSet 是所有 Set 实现中**性能最高**的，专门为枚举类型设计。它的底层不是 Map，而是**位向量（bit vector）**：

```java
public abstract class EnumSet<E extends Enum<E>> extends AbstractSet<E>
    implements Cloneable, java.io.Serializable {

    final Class<E> elementType;
    final Enum<?>[] universe; // 所有枚举常量

    // 两个子类：
    // RegularEnumSet - 枚举常量的 ordinal < 64 时使用
    // JumboEnumSet   - 枚举常量的 ordinal >= 64 时使用
}
```

**RegularEnumSet 的核心实现：**

```java
class RegularEnumSet<E extends Enum<E>> extends EnumSet<E> {
    private long elements = 0L; // 64位的位向量

    void add(E e) {
        // 按位或：将枚举 ordinal 对应的位设为 1
        elements |= (1L << e.ordinal());
    }

    boolean contains(Object e) {
        if (e == null) return false;
        // 按位与：检查该位是否为 1
        return (elements & (1L << ((Enum<?>)e).ordinal())) != 0;
    }

    void remove(E e) {
        // 按位与非：将该位设为 0
        elements &= ~(1L << e.ordinal());
    }
}
```

### 5.2 性能数据

| 操作 | HashSet | EnumSet |
|------|---------|---------|
| add | O(1) | O(1) — 一次位运算 |
| contains | O(1) — 需处理哈希冲突 | O(1) — 一次位运算 |
| remove | O(1) | O(1) — 一次位运算 |
| 迭代 | 需遍历桶数组 | 在 long 上循环位扫描 |
| 内存 | 每个元素 ≈ 对象头 + 引用 | 仅一个 long (64位) |

### 5.3 使用示例

```java
enum Status {
    PENDING, PROCESSING, COMPLETED, FAILED, CANCELLED
}

// 创建 EnumSet
EnumSet<Status> all = EnumSet.allOf(Status.class);
EnumSet<Status> none = EnumSet.noneOf(Status.class);
EnumSet<Status> active = EnumSet.of(Status.PENDING, Status.PROCESSING);
EnumSet<Status> range = EnumSet.range(Status.PENDING, Status.COMPLETED);
EnumSet<Status> complement = EnumSet.complementOf(active);

// 批量操作（位运算，O(1)）
all.addAll(active);    // 位或
all.retainAll(active); // 位与
all.removeAll(active); // 位与非
```

### 5.4 集合运算的位操作

```java
// 判断子集
boolean isSubset = active.containsAll(EnumSet.of(Status.PENDING));
// 内部： (active.elements & pendingSet.elements) == pendingSet.elements

// 求交集
EnumSet<Status> common = EnumSet.copyOf(all);
common.retainAll(active);
// 内部： all.elements &= active.elements
```

---

## 六、Set 性能对比与选型指南

### 6.1 时间复杂度

| 操作 | HashSet | LinkedHashSet | TreeSet | EnumSet |
|------|---------|---------------|---------|---------|
| add | O(1)* | O(1)* | O(log n) | O(1) |
| contains | O(1)* | O(1)* | O(log n) | O(1) |
| remove | O(1)* | O(1)* | O(log n) | O(1) |
| 迭代 | O(capacity) | O(n) | O(n) | O(n) |
| 排序操作 | ❌ | ❌ | ✅ | ❌ |

*注：假设哈希均匀分布，最坏情况 O(n)

### 6.2 选型决策树

```
需要有序？
├── 需要排序（自然或比较器） → TreeSet
├── 需要保持插入顺序 → LinkedHashSet
└── 无序即可 → HashSet（默认选择）

元素类型是枚举？ → EnumSet（永远优先选择）

需要线程安全？
├── 读多写少 → Collections.synchronizedSet()
├── 写操作频繁 → CopyOnWriteArraySet（慎用）
└── 并发高 → ConcurrentHashMap.newKeySet()
```

### 6.3 ConcurrentHashMap.newKeySet()：并发场景的最佳选择

```java
// 创建一个并发安全的 Set
Set<String> concurrentSet = ConcurrentHashMap.newKeySet();
concurrentSet.add("Java");
concurrentSet.add("Python");
// 底层：ConcurrentHashMap 的 keySet view
```

这在**高并发场景**下比 Collections.synchronizedSet() 性能好得多，是并发场景的首选。

---

## 七、常见面试题

### Q1: HashSet 和 TreeSet 有什么区别？

| 对比维度 | HashSet | TreeSet |
|---------|---------|---------|
| 底层结构 | HashMap | TreeMap（红黑树） |
| 元素顺序 | 无序（hash 决定的顺序） | 排序（自然排序或 Comparator） |
| 时间复杂度 | O(1) | O(log n) |
| 判重依据 | hashCode() + equals() | compareTo() / compare() |
| null 值 | 允许一个 null | 不允许 null |
| 额外功能 | 无 | 范围查询、导航方法 |

### Q2: 为什么 HashSet 查找比 TreeSet 快？

HashSet 基于哈希表，理论上 O(1)；TreeSet 基于红黑树，O(log n)。但要注意 HashSet 的 O(1) 是建立在哈希函数均匀分布的前提下，且需要额外的内存空间（负载因子 0.75 意味着浪费 25% 的空间）。

### Q3: LinkedHashSet 比 HashSet 慢吗？

**添加/删除**：几乎一样，O(1)*，只是需要额外维护链表指针。
**迭代**：LinkedHashSet 更快！因为迭代只需要遍历双向链表（n 步），而 HashSet 需要遍历整个桶数组（capacity 步，可能远大于 n）。

### Q4: EnumSet 能用于非枚举类型吗？

不能。EnumSet 的构造函数检查 elementType，非枚举类型直接抛 ClassCastException。但你可以把其他类型转换为枚举包装。

---

## 总结

| 实现类 | 一句话总结 | 适用场景 |
|--------|-----------|---------|
| HashSet | HashMap 的 key 封装，最快通用 Set | 默认选择，不需要有序的场景 |
| LinkedHashSet | 可预测迭代顺序的 HashSet | 需要保持插入顺序的场景 |
| TreeSet | 红黑树支撑的有序 Set | 需要排序或范围查询的场景 |
| EnumSet | 位向量实现的极致性能 Set | 枚举类型的存储和集合运算 |
| ConcurrentHashMap.newKeySet() | 并发安全的 Set | 多线程环境下的集合操作 |

**记住一个核心：Set 不重复的保证，取决于底层数据结构的判重逻辑。** 理解了这个，你就掌握了 Set 家族的精髓。

选择 Set 的时候，从需求出发：要排序？要顺序？Enum？还是默认 HashSet？选对了，你的代码会更好用、更高效。
