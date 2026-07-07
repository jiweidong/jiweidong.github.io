---
title: 【Java集合】Java Map 家族冷门成员：WeakHashMap、IdentityHashMap 与 LinkedHashMap 源码级解析
date: 2026-07-07 08:00:00
tags:
  - Java
  - 集合
  - WeakHashMap
  - IdentityHashMap
  - LinkedHashMap
categories:
  - Java
  - 集合框架
author: 东哥
---

# 【Java集合】Java Map 家族冷门成员：WeakHashMap、IdentityHashMap 与 LinkedHashMap 源码级解析

## 不止于 HashMap

HashMap 是 Java 开发中最常用的 Map 实现，但 JDK 还提供了几个"另类"的 Map 实现，它们在特定场景下能发挥意想不到的作用：

- **WeakHashMap**：键是弱引用——当键不再被外部引用时自动被 GC 清除，天然适合缓存场景
- **IdentityHashMap**：使用引用相等（`==`）代替 equals() 比较键，性能更高，适用于特殊比较逻辑
- **LinkedHashMap**：维护插入顺序或访问顺序，是 LRU 缓存的理想基础

这篇文章将深入这三个 Map 的源码实现，剖析核心机制和最佳实践。

---

## 一、WeakHashMap：弱引用键的自动清理

### 1.1 弱引用（WeakReference）基础

在深入 WeakHashMap 之前，需要先理解 Java 的弱引用：

```java
// 强引用：不会被 GC 回收（除非引用变量被置 null）
String strongRef = new String("hello");

// 弱引用：GC 发现即回收
WeakReference<String> weakRef = new WeakReference<>(new String("hello"));
System.gc();  // weakRef.get() 可能返回 null
```

**弱引用的存活周期**：只存活到下一次 GC 之前。GC 线程在扫描时，一旦发现弱引用对象，不管内存是否充足，都会将其回收。

### 1.2 WeakHashMap 的核心设计

`WeakHashMap` 的键使用 `WeakReference` 包装，当键对象不再被外部强引用时，GC 会自动回收键，同时对应的 Entry 被标记为待清理。

关键在于它的**内部数据结构**：

```java
public class WeakHashMap<K, V> extends AbstractMap<K, V> implements Map<K, V> {
    // 底层：也是数组 + 链表（没有红黑树！）
    Entry<K, V>[] table;
    private int size;
    private int modCount;

    // 引用队列：存放被 GC 回收的弱引用
    private final ReferenceQueue<Object> queue = new ReferenceQueue<>();
}
```

**Entry 结构**：
```java
private static class Entry<K, V> extends WeakReference<Object> implements Map.Entry<K, V> {
    // key 继承自 WeakReference，不单独存储
    V value;
    final int hash;
    Entry<K, V> next;

    Entry(Object key, V value, ReferenceQueue<Object> queue, int hash, Entry<K, V> next) {
        super(key, queue);  // 关键：将 key 交给 WeakReference，关联 ReferenceQueue
        this.value = value;
        this.hash  = hash;
        this.next  = next;
    }
}
```

**核心设计要点**：
1. Entry 继承 `WeakReference<Object>`，key 作为弱引用传入父类构造器
2. 每个 Entry 关联同一个 `ReferenceQueue`
3. 当 key 被 GC 回收时，对应的 Entry 被放入 ReferenceQueue
4. 后续操作时，通过 `expungeStaleEntries()` 清理队列中的失效 Entry

### 1.3 惰性清理机制

WeakHashMap 采用**惰性清理**策略——不是在 GC 时立刻清理，而是在每次调用 Map 方法（get、put、size 等）时检查并清理：

```java
private void expungeStaleEntries() {
    for (Object x; (x = queue.poll()) != null; ) {
        synchronized (queue) {
            @SuppressWarnings("unchecked")
            Entry<K, V> e = (Entry<K, V>) x;
            int i = indexFor(e.hash, table.length);

            Entry<K, V> prev = table[i];
            Entry<K, V> p = prev;
            // 遍历链表，删除被回收的 Entry
            while (p != null) {
                Entry<K, V> next = p.next;
                if (p == e) {
                    if (prev == e)
                        table[i] = next;
                    else
                        prev.next = next;
                    e.value = null;  // 帮助 GC 回收 value
                    size--;
                    break;
                }
                prev = p;
                p = next;
            }
        }
    }
}
```

**为什么是惰性清理**？GC 是不可预测的，无法在 GC 时直接回调清理。懒清理避免了在 GC 线程中执行复杂操作，把清理成本摊到后续 Map 操作中。

### 1.4 典型应用场景：本地缓存

```java
// 一个自动清理的缓存：当 key 不再被外部引用时，缓存自动失效
public class SimpleCache<K, V> {
    private final WeakHashMap<K, V> cache = new WeakHashMap<>();

    public V get(K key) {
        return cache.get(key);
    }

    public void put(K key, V value) {
        cache.put(key, value);
    }
}

// 使用示例
SimpleCache<String, ExpensiveObject> cache = new SimpleCache<>();
String key = new String("data-001");  // 强引用
cache.put(key, new ExpensiveObject());

key = null;  // 强引用消失，下次 GC 时缓存自动清理
// WeakHashMap 中的 Entry 在 GC 后被放入 ReferenceQueue
// 下次操作 Map 时自动清理
```

### 1.5 使用陷阱

```java
// 陷阱 1：直接使用字符串字面量作为 key
WeakHashMap<String, String> map = new WeakHashMap<>();
String key1 = "constant";  // 字符串常量在常量池中，永远不会被 GC！
String key2 = new String("constant");  // 堆中的对象，可以被 GC
// 用 key1 作为键时，Entry 永远不会被自动清理

// 陷阱 2：value 被 value 引用导致无法 GC
WeakHashMap<UniqueKey, SomeValue> map = new WeakHashMap<>();
UniqueKey key = new UniqueKey();
map.put(key, new SomeValue());
// 如果 SomeValue 内部持有对 key 的引用，会导致 key 无法被 GC 回收
// 这就是为什么 expungeStaleEntries 中将 e.value 设置为 null 辅助 GC
```

---

## 二、IdentityHashMap：引用相等代替 equals

### 2.1 与 HashMap 的核心区别

| 特性 | HashMap | IdentityHashMap |
|------|---------|-----------------|
| 键比较方式 | `equals()` | `==`（引用相等） |
| 哈希冲突解法 | 链表 + 红黑树 | **开放寻址法**（线性探测） |
| null 键 | 支持 | 支持 |
| 线程安全 | 不支持 | 不支持 |
| 初始容量 | 16 | 21（必须是 2 的幂？不，这里的实现不同） |

### 2.2 开放寻址法的实现

`IdentityHashMap` 使用**开放寻址法（Open Addressing）**中的线性探测（Linear Probing）来解决哈希冲突，而不是 HashMap 的链地址法：

```java
public class IdentityHashMap<K, V> extends AbstractMap<K, V>
    implements Map<K, V>, Serializable, Cloneable {

    // 底层数组：交替存储 key 和 value
    // table[0] = key1, table[1] = value1
    // table[2] = key2, table[3] = value2
    transient Object[] table;

    private int size;
    transient int modCount;
}
```

### 2.3 为什么用数组而不是链表？

**内存局部性**：数组在内存中是连续的，CPU 缓存友好。线性探测只需检查相邻的数组槽位，而链地址法需要跳转访问链表节点，缓存命中率较低。

### 2.4 核心方法源码

**get(Object key)**：
```java
public V get(Object key) {
    Object[] tab = table;
    int len = tab.length;
    // 使用 System.identityHashCode() 而不是 key.hashCode()
    int hash = System.identityHashCode(key);
    int i = hash & (len - 2);  // 为什么减 2？
    // 线性探测
    while (true) {
        Object item = tab[i];
        if (item == key)       // 注意：使用 == 比较！
            return (V) tab[i + 1];
        if (item == null)      // 遇到 null 说明不存在
            return null;
        i = (i + 2) & (len - 2);  // 步进 2（跳过 value 槽位）
    }
}
```

**注意**：减 2 是因为数组长度 len 是 2 的幂，len - 2 是一个偶数掩码（与 111...110 按位与），保证索引始终是偶数，即读取 key 槽位（value 在奇数索引）。

### 2.5 System.identityHashCode()

IdentityHashMap 使用 `System.identityHashCode()` 计算哈希码，该方法返回对象的**默认 hashCode**（基于对象内存地址），无论对象是否重写了 `hashCode()`：

```java
String a = new String("hello");
String b = new String("hello");

System.out.println(a.hashCode());                // 99162322（内容相同）
System.out.println(System.identityHashCode(a));  // 12345678（基于内存地址）
System.out.println(System.identityHashCode(b));  // 87654321（不同对象不同）
```

### 2.6 典型应用场景

**场景 1：序列化/深拷贝时跟踪对象引用**：
```java
// 序列化时用 IdentityHashMap 记录已处理的对象，防止循环引用
private IdentityHashMap<Object, Object> visited = new IdentityHashMap<>();

public void serialize(Object obj) {
    if (visited.containsKey(obj)) return;  // 对象引用已处理过
    visited.put(obj, obj);
    // ... 继续序列化
}
```

**场景 2：Spring 的单例注册表**：
Spring 框架内部使用 `IdentityHashMap` 存储单例 Bean 定义，因为同一个 Class 对象（不同加载器加载的）需要用 `==` 区分。

**场景 3：代理对象的去重**：
当同一个对象被不同代理包装时，equals 可能返回 true，但引用不同，此时 IdentityHashMap 的引用比较就能准确区分。

---

## 三、LinkedHashMap：可预测迭代顺序的 HashMap

### 3.1 双向链表维护顺序

`LinkedHashMap` 继承自 `HashMap`，在 HashMap 的基础上维护了一个**双向链表**：

```java
public class LinkedHashMap<K, V> extends HashMap<K, V> implements Map<K, V> {

    // 双向链表的头尾节点
    transient LinkedHashMap.Entry<K, V> head;
    transient LinkedHashMap.Entry<K, V> tail;

    // 排序模式：true = 访问顺序，false = 插入顺序（默认）
    final boolean accessOrder;
}
```

Entry 继承自 HashMap.Node，增加了前后指针：

```java
static class Entry<K, V> extends HashMap.Node<K, V> {
    Entry<K, V> before, after;
    Entry(int hash, K key, V value, Node<K, V> next) {
        super(hash, key, value, next);
    }
}
```

### 3.2 插入顺序 vs 访问顺序

**插入顺序模式（默认）**：
每次 `put` 新键值对时，新节点被添加到链表尾部。迭代顺序 = 插入顺序。

**访问顺序模式**：
每次 `get` 或 `put` 已有键时，节点被移动到链表尾部。最近访问的元素在尾部，最久未访问的在头部。

```java
LinkedHashMap<String, String> map = new LinkedHashMap<>(16, 0.75f, true);  // accessOrder = true
map.put("a", "1");
map.put("b", "2");
map.put("c", "3");
System.out.println(map); // {a=1, b=2, c=3}

map.get("a");            // 访问 a，a 被移动到尾部
System.out.println(map); // {b=2, c=3, a=1}
```

### 3.3 核心钩子方法：afterNodeAccess / afterNodeInsertion

LinkedHashMap 重写了 HashMap 预留的**回调钩子方法**来实现链表维护：

```java
// HashMap 中预留的空实现方法
void afterNodeAccess(Node<K,V> p) { }
void afterNodeInsertion(boolean evict) { }
void afterNodeRemoval(Node<K,V> p) { }
```

**afterNodeAccess**：节点被访问后的处理（移动到尾部）：

```java
void afterNodeAccess(Node<K,V> e) {
    LinkedHashMap.Entry<K,V> last;
    if (accessOrder && (last = tail) != e) {
        LinkedHashMap.Entry<K,V> p =
            (LinkedHashMap.Entry<K,V>)e, b = p.before, a = p.after;
        p.after = null;
        if (b == null)
            head = a;
        else
            b.after = a;
        if (a != null)
            a.before = b;
        else
            last = b;
        if (last == null)
            head = p;
        else {
            p.before = last;
            last.after = p;
        }
        tail = p;
        ++modCount;
    }
}
```

**afterNodeInsertion**：插入后的处理（实现 LRU 淘汰）：

```java
void afterNodeInsertion(boolean evict) {
    LinkedHashMap.Entry<K,V> first;
    if (evict && head != null && removeEldestEntry(first = head)) {
        K key = first.key;
        removeNode(hash(key), key, null, false, true);
    }
}

// 默认返回 false，需要子类覆盖
protected boolean removeEldestEntry(Map.Entry<K,V> eldest) {
    return false;
}
```

### 3.4 实现 LRU 缓存

覆盖 `removeEldestEntry` 即可实现 LRU 缓存：

```java
public class LRUCache<K, V> extends LinkedHashMap<K, V> {
    private final int maxCapacity;

    public LRUCache(int maxCapacity) {
        super(16, 0.75f, true);  // accessOrder = true
        this.maxCapacity = maxCapacity;
    }

    // 当缓存大小超过最大容量时，移除最久未访问的节点
    @Override
    protected boolean removeEldestEntry(Map.Entry<K, V> eldest) {
        return size() > maxCapacity;
    }

    @Override
    public V getOrDefault(Object key, V defaultValue) {
        V v = super.getOrDefault(key, defaultValue);
        // LinkedHashMap 的 get() 不会更新访问顺序，需要调用 get()
        // 但 getOrDefault 底层调用了 getNode 不会触发 afterNodeAccess
        // 所以需要专门的 get
        return v;
    }
}

// 使用
LRUCache<Integer, String> cache = new LRUCache<>(3);
cache.put(1, "one");
cache.put(2, "two");
cache.put(3, "three");
System.out.println(cache); // {1=one, 2=two, 3=three}

cache.get(1);              // 访问 1
cache.put(4, "four");      // 超出容量，淘汰最久未访问的 2
System.out.println(cache); // {3=three, 1=one, 4=four}
```

**注意**：`LinkedHashMap` 不是线程安全的，生产环境的 LRU 缓存建议配合 `Collections.synchronizedMap` 或直接使用 `Caffeine`。

---

## 四、面试常见追问

### Q1：WeakHashMap 的 value 会被强引用持有导致泄漏吗？
会！如果 value 内部持有 key 的引用，会导致 key 的弱引用无法被 GC 回收。WeakHashMap 在清理时会将 value 置为 null 来打破这个循环。

### Q2：IdentityHashMap 为什么不用链表而用开放寻址？
主要是性能考量：开放寻址法利用数组的内存局部性，CPU 缓存命中率高。IdentityHashMap 的 `System.identityHashCode()` 本身就是基于内存地址的，配合线性探测，访问模式对 CPU 缓存非常友好。

### Q3：LinkedHashMap 的 accessOrder 有什么实际用途？
最经典的用途是实现 LRU 缓存。`accessOrder = true` 结合 `removeEldestEntry` 方法，可以轻松实现一个容量受限、自动淘汰最久未访问元素的缓存。

### Q4：WeakHashMap 和 ConcurrentHashMap 能结合吗？
不能直接结合。WeakHashMap 不是线程安全的，而 ConcurrentHashMap 不支持弱引用键。如果需要一个线程安全的弱引用缓存，可以考虑 `Collections.synchronizedMap(new WeakHashMap<>())`，或者使用 Guava Cache。

---

## 总结

| Map 实现 | 核心特性 | 典型场景 |
|----------|---------|---------|
| WeakHashMap | 弱引用键，自动清理 | 缓存、监听器注册表 |
| IdentityHashMap | 引用比较（==） | 序列化、代理、Spring 单例 |
| LinkedHashMap | 可预测迭代顺序 | LRU 缓存、有序遍历 |

这三个"冷门"Map 在各自适合的场景下，能比 HashMap 做出更优雅、更高效的解决方案。
