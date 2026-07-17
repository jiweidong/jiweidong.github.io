---
title: 【Java 21+】Sequenced Collections 顺序集合深度解析：有序数据结构的统一接口
date: 2026-07-17 08:00:00
tags:
  - Java
  - Java集合
  - Java 21
categories:
  - Java
  - Java基础
author: 东哥
---

# 【Java 21+】Sequenced Collections 顺序集合深度解析：有序数据结构的统一接口

## 引言：为什么需要 Sequenced Collections？

在 Java 21 之前，Java 集合框架对「有序集合」的处理一直是个痛点。如果你曾困惑过：
- `List` 可以通过 `get(0)` 获取第一个元素，`get(list.size()-1)` 获取最后一个——但怎么没有统一的方法？
- `Deque` 有 `getFirst()`/`getLast()`，但 `SortedSet` 是 `first()`/`last()`——命名不统一！
- `LinkedHashSet` 有顺序，但只能遍历，不能直接拿到第一个/最后一个？
- `TreeSet` 想反转遍历？得手动 `descendingIterator()`，但接口上不统一

Java 21 的 **Sequenced Collections**（JEP 431）就是为了解决这些问题。它引入了一套统一的接口体系，让有序集合的操作标准化。

## 一、接口层次体系

Sequenced Collections 新增（或增强）了三个核心接口：

```
Collection (Iterable)
  └── SequencedCollection (新增)
         ├── List (已有，增强)
         ├── Deque (已有，增强)
         └── LinkedHashSet (已有，增强)

Map
  └── SequencedMap (新增)
         ├── TreeMap
         ├── LinkedHashMap
         └── EnumMap
```

### 1.1 SequencedCollection 接口

`SequencedCollection` 继承了 `Collection` 接口，新增了一组"顺序操作"方法：

```java
interface SequencedCollection<E> extends Collection<E> {
    // 新增方法
    SequencedCollection<E> reversed();    // 返回逆序视图
    void addFirst(E e);                   // 在头部添加
    void addLast(E e);                    // 在尾部添加
    E getFirst();                         // 获取第一个元素
    E getLast();                          // 获取最后一个元素
    E removeFirst();                      // 移除并返回第一个
    E removeLast();                       // 移除并返回最后一个
}
```

### 1.2 SequencedMap 接口

对于有序的 Map：

```java
interface SequencedMap<K,V> extends Map<K,V> {
    SequencedMap<K,V> reversed();         // 返回逆序视图
    Entry<K,V> firstEntry();              // 第一个条目
    Entry<K,V> lastEntry();               // 最后一个条目
    Entry<K,V> pollFirstEntry();          // 移除并返回第一个
    Entry<K,V> pollLastEntry();           // 移除并返回最后一个
    K firstKey();                         // 第一个键
    K lastKey();                          // 最后一个键
    SequencedSet<K> sequencedKeySet();    // 有序的KeySet
    SequencedCollection<V> sequencedValues();  // 有序的Values
    SequencedSet<Entry<K,V>> sequencedEntrySet(); // 有序的EntrySet
    void putFirst(K key, V value);        // 插入到最前面
    void putLast(K key, V value);         // 插入到最后面
}
```

## 二、解决了什么痛点？

### 痛点1：获取第一个/最后一个元素的不统一

Java 21 之前：

```java
// List - 通过 index
String first = list.get(0);
String last = list.get(list.size() - 1);  // 啰嗦！
String last = list.get(list.size() - 1);  // 还得保证非空

// Deque - 通过命名不同的方法
String first = deque.getFirst();
String last = deque.getLast();

// SortedSet - 又换了一套命名
String first = sortedSet.first();
String last = sortedSet.last();

// LinkedHashSet - 没有直接的方法！
// 只能通过 iterator()
```

Java 21 之后——统一了！

```java
// 所有有序集合都支持
String first = collection.getFirst();
String last = collection.getLast();
```

### 痛点2：反转视图

以前想反转遍历一个 `List`：

```java
// 方式一：自己创建新集合
List<String> reversed = new ArrayList<>(list);
Collections.reverse(reversed);  // 创建副本，O(n) 空间

// 方式二：使用 ListIterator
ListIterator<String> it = list.listIterator(list.size());
while (it.hasPrevious()) {
    process(it.previous());
}
```

现在简单了：

```java
// 返回的是视图，不复制数据！
for (String s : list.reversed()) {
    process(s);
}
```

`reversed()` 返回逆序视图——这意味着：
- **不创建新集合**，只是反序遍历
- **视图是活的**：原集合变动后，视图自动反映
- 可通过视图继续调用 `reversed()` 回到正序

### 痛点3：LinkedHashSet 缺乏首尾操作

`LinkedHashSet` 保持了插入顺序，但以前无法直接获取/移除首尾元素。Java 21 之后：

```java
LinkedHashSet<String> set = new LinkedHashSet<>();
set.add("A");
set.add("B");
set.add("C");

String first = set.getFirst();  // "A"
String last = set.getLast();    // "C"
set.removeFirst();              // 移除 "A"
```

## 三、源码级原理分析

### 3.1 reversed() 的实现

以 `ArrayList` 为例看看 `reversed()` 是怎么做到的：

```java
// ArrayList 中的实现
public SequencedCollection<E> reversed() {
    return new ReverseSequencedCollectionView<>(this);
}
```

这个 `ReverseSequencedCollectionView` 是一个**视图类**，它持有原 List 的引用，每次操作都映射到对应的"对称位置"：

```java
static class ReverseSequencedCollectionView<E> 
        implements SequencedCollection<E> {
    final SequencedCollection<E> source;
    
    ReverseSequencedCollectionView(SequencedCollection<E> source) {
        this.source = source;
    }
    
    public Iterator<E> iterator() {
        return source.reversed().iterator();
    }
    
    // 反转操作映射
    public E getFirst() { return source.getLast(); }
    public E getLast() { return source.getFirst(); }
    public void addFirst(E e) { source.addLast(e); }
    public void addLast(E e) { source.addFirst(e); }
    public E removeFirst() { return source.removeLast(); }
    public E removeLast() { return source.removeFirst(); }
    
    // 再调 reversed() 回到源头
    public SequencedCollection<E> reversed() { return source; }
}
```

**关键设计点**：`reversed()` 返回的是视图，O(1) 时间，O(1) 额外空间。每次访问才做计算映射。这借鉴了 Guava 的 `Lists.reverse()` 的设计思路。

### 3.2 LinkedHashMap 的 putFirst/putLast

`LinkedHashMap` 的 `putFirst`/`putLast` 实现使用了内部的双向链表维护能力：

```java
// LinkedHashMap 中的实现（简化）
public void putFirst(K key, V value) {
    if (!containsKey(key)) {
        // 新 key：直接插入到链表头部
        addBefore(head, key, value);
    } else {
        // 已有 key：移动到头部
        removeNode(key);  // 从链表中移除
        addBefore(head, key, value);  // 插入到头部
    }
}

private void addBefore(LinkedHashMap.Entry<K,V> existingEntry, K key, V value) {
    LinkedHashMap.Entry<K,V> newNode = newNode(hash(key), key, value, null);
    // 插入到 existingEntry 之前
    newNode.after = existingEntry;
    newNode.before = existingEntry.before;
    existingEntry.before.after = newNode;
    existingEntry.before = newNode;
}
```

## 四、各集合的 Sequenced 能力对照表

| 集合类 | 接口 | getFirst/Last | addFirst/Last | reversed() | putFirst/Last | 注意点 |
|--------|------|:---:|:---:|:---:|:---:|--------|
| ArrayList | SequencedCollection | ✅ | ✅ | ✅ | N/A | addFirst/Last 会触发数组拷贝 |
| LinkedList | SequencedCollection | ✅ | ✅ O(1) | ✅ | N/A | addFirst/Last 高效 |
| ArrayDeque | SequencedCollection | ✅ | ✅ O(1) | ✅ | N/A | 最佳选择 |
| LinkedHashSet | SequencedCollection | ✅ | ✅ | ✅ | N/A | addFirst/Last 修改插入顺序 |
| TreeSet | SequencedCollection | ✅ | ❌ | ✅ | N/A | 按 Comparator 排序 |
| TreeMap | SequencedMap | ✅ | N/A | ✅ | ✅ | 按 Comparator 排序 |
| LinkedHashMap | SequencedMap | ✅ | N/A | ✅ | ✅ | 可维护插入/访问顺序 |
| EnumMap | SequencedMap | ✅ | N/A | ✅ | ✅ | 按 enum 定义顺序 |
| ConcurrentLinkedDeque | SequencedCollection | ✅ | ✅ | ✅ | N/A | 并发安全 |
| CopyOnWriteArrayList | SequencedCollection | ✅ | ✅ | ✅ | N/A | 写时复制 |

**注意**：
- `TreeSet`/`TreeMap` 的排序由 Comparator 决定，**不支持** `addFirst`/`addLast` 或 `putFirst`/`putLast`——会抛 `UnsupportedOperationException`
- `HashSet`、`HashMap` 不实现 Sequenced 接口（无序）

## 五、实战代码示例

### 5.1 使用 LinkedHashSet 实现 LRU 缓存的最小版

```java
public class SimpleLRUCache<K, V> {
    private final int capacity;
    private final LinkedHashMap<K, V> map;
    
    public SimpleLRUCache(int capacity) {
        this.capacity = capacity;
        // accessOrder = true：访问顺序
        this.map = new LinkedHashMap<K, V>(capacity, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<K, V> eldest) {
                return size() > capacity;
            }
        };
    }
    
    public V get(K key) {
        return map.get(key);  // get 操作会将元素移到尾部
    }
    
    public void put(K key, V value) {
        map.put(key, value);
    }
    
    // 使用新的 SequencedMap API 获取最久未使用的元素
    public Map.Entry<K, V> eldestEntry() {
        return map.firstEntry();  // 最早插入/最近最少使用的
    }
    
    // 移除最近最少使用的元素
    public K evictEldest() {
        Map.Entry<K, V> entry = map.pollFirstEntry();
        return entry != null ? entry.getKey() : null;
    }
}
```

### 5.2 翻页场景：获取最新/最旧记录

假设有一个按时间顺序存储的日志集合：

```java
// 用 LinkedHashSet 维护按时间插入的有序集合
SequencedCollection<LogEntry> logs = new LinkedHashSet<>();

logs.add(new LogEntry("2026-07-17 08:00:00", "系统启动"));
logs.add(new LogEntry("2026-07-17 08:05:00", "用户登录"));
logs.add(new LogEntry("2026-07-17 08:10:00", "查询操作"));

// 获取最新日志
LogEntry latest = logs.getLast();

// 获取最旧日志
LogEntry oldest = logs.getFirst();

// 逆序遍历（最新的在前）
for (LogEntry entry : logs.reversed()) {
    System.out.println(entry);
}

// 取最后5条（最新5条）
logs.reversed().stream()
    .limit(5)
    .forEach(System.out::println);
```

### 5.3 用 LinkedHashMap 维护配置优先级

```java
public class ConfigManager {
    private final SequencedMap<String, String> configs = new LinkedHashMap<>();
    
    // 将配置插入到最前面（最高优先级）
    public void addOverrideConfig(String key, String value) {
        configs.putFirst(key, value);  // 新方法！
    }
    
    // 追加到末尾（低优先级）
    public void addDefaultConfig(String key, String value) {
        configs.putLast(key, value);   // 新方法！
    }
    
    public String getConfig(String key) {
        // 先找到的（靠前的）就是最高优先级的配置
        return configs.get(key);
    }
    
    // 获取最高优先级的配置项
    public Map.Entry<String, String> highestPriority() {
        return configs.firstEntry();
    }
}
```

## 六、与 Guava/Lombok 等第三方库的对比

| 能力 | Java 21+ (Java SE) | Guava | Apache Commons |
|------|:---:|:---:|:---:|
| 获取首尾元素 | `getFirst()`/`getLast()` | `Iterables.getFirst/last` | `CollectionUtils.get` |
| 逆序视图 | `reversed()` | `Lists.reverse()` (仅 List) | 无 |
| 从 Set 获取首尾 | 原生支持 `LinkedHashSet` | `Sets` 无此功能 | 无 |
| Map 首尾元素 | `firstEntry()`/`lastEntry()` | 无 | 无 |
| Map 插入到指定位置 | `putFirst()`/`putLast()` | `Maps.newLinkedHashMap` 无此操作 | 无 |

**结论**：Java 21+ 的 Sequenced Collections 在**标准 API** 层面统一覆盖了大部分有序集合操作场景。

## 七、面试常见追问

**Q1：`reversed()` 返回的视图支持修改吗？**

A：支持。因为它是视图，对它的修改会直接映射到原集合。比如 `view.removeFirst()` 等价于原集合的 `removeLast()`。

**Q2：`ArrayList` 的 `addFirst()` 性能如何？**

A：O(n)。`ArrayList` 底层是数组，每次 `addFirst` 都需要将所有已有元素后移一位。如果频繁在头部插入，建议用 `ArrayDeque` 或 `LinkedList`。

**Q3：`LinkedHashSet` 和 `TreeSet` 在 Sequenced 方面有何区别？**

A：`LinkedHashSet` 支持 `addFirst`/`addLast`（修改插入顺序），而 `TreeSet` 不支持——因为它的顺序由 `Comparator` 决定，不能人为干预。`TreeSet` 调用 `addFirst` 会抛 `UnsupportedOperationException`。

**Q4：Sequenced Collections 与 Stream API 的兼容性如何？**

A：完全兼容。`SequencedCollection` 继承了 `Collection`，所以 `stream()`、`spliterator()` 等都能正常使用。`reversed()` 返回的视图也支持流式操作。

**Q5：并发集合中哪些支持 Sequenced？**

A：`ConcurrentLinkedDeque` 支持（双端队列，原生有序），`ConcurrentLinkedQueue` 也支持。但 `ConcurrentHashMap` 不支持（无序）。`CopyOnWriteArrayList` 支持但不推荐在头部频繁操作（每次 addFirst 都会复制整个数组）。

## 八、总结

Sequenced Collections（JEP 431）是 Java 集合框架的一次重要增强，虽然看起来改动不大，但它在 API 层面的统一性大大提升了开发体验：

1. **统一了有序集合的操作标准**——不再需要在 List、Deque、SortedSet 之间猜测不同的方法名
2. **引入了高效的逆序视图**——`reversed()` 返回 O(1) 的活跃视图，不复制数据
3. **增强了对 LinkedHashSet/LinkedHashMap 的首尾操作能力**——以前只能遍历，现在可以直接访问
4. **向下兼容**——所有已有的集合实现都无缝增强

对于日常开发，建议：
- 推荐用 `ArrayDeque` 替代 `LinkedList` 做栈/队列操作
- `LinkedHashMap.putFirst/putLast` 在需要控制插入位置的场景非常有用
- 遍历时需逆序？直接 `collection.reversed().forEach(...)` 即可

这是 Java 集合框架迈向更简洁、更统一设计的重要一步。
