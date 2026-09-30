---
title: 【Java 核心】Collections 包装器深度解析：unmodifiable、synchronized、checked 与不可变集合实践
date: 2026-09-30 08:00:00
tags:
  - Java
  - 集合
  - 源码
  - 最佳实践
categories:
  - Java
  - Java基础
author: 东哥
---

# 【Java 核心】Collections 包装器深度解析：unmodifiable、synchronized、checked 与不可变集合实践

## 面试官：`Collections.unmodifiableList()` 和 `List.of()` 有什么区别？

很多人第一次听到这个问题会愣一下——不都是"不可变集合"吗？

往下追几个问题更能筛人：

- `Collections.unmodifiableList(list)` 之后，修改原始的 `list`，视图里的数据会变吗？
- `Collections.synchronizedList()` 包装后的列表，遍历时还需要手动加锁吗？
- `Collections.checkedList()` 到底"检查"什么？加了它是不是就类型安全了？
- 为什么 `Collections.emptyList()` 是"最完美的单例"，而 `new ArrayList<>()` 每次都创建对象？

这些问题的答案都指向同一个被严重低估的工具类：`java.util.Collections` 里那一堆**包装器（Wrapper）**。它们代码极短（`UnmodifiableList` 只有几十行），却是 JDK 里"设计模式 + 编程哲学"的浓缩。本文从源码出发，把它们彻底讲清楚。

## 一、包装器的全景：六类

`Collections` 提供了六类包装方法，返回的都是基于原集合的**视图（View）**，而不是拷贝：

| 类别 | 方法 | 返回类型 | 拦截的操作 |
| --- | --- | --- | --- |
| 不可修改 | `unmodifiableXxx()` | `UnmodifiableXxx` | 所有写操作抛异常 |
| 同步 | `synchronizedXxx()` | `SynchronizedXxx` | 所有操作加 `synchronized` |
| 运行时类型检查 | `checkedXxx()` | `CheckedXxx` | 写入时校验元素类型 |
| 空集合 | `emptyXxx()` | 单例 | 全空，写操作抛异常 |
| 单元素 | `singletonXxx()` | 单例 | 只有一个元素，不可增删 |
| 不可变副本 | `List.copyOf()` 等（JDK 10+） | `ImmutableCollections` | 真正不可变 |

先看清一个核心事实：**包装器不复制数据，它们只是把调用转发给原集合，并在转发前做检查。** 这个设计决定了它们所有优点（零拷贝、低开销）和所有缺点（视图会随原集合变化、并发语义不完整）。

## 二、unmodifiableXxx：只读视图

### 2.1 源码：`UnmodifiableList`

```java
static class UnmodifiableCollection<E> implements Collection<E>, Serializable {
    private static final long serialVersionUID = 1820017752578914078L;

    final Collection<? extends E> c;

    UnmodifiableCollection(Collection<? extends E> c) {
        this.c = c;
    }

    public int size()                { return c.size(); }
    public boolean isEmpty()         { return c.isEmpty(); }
    public boolean contains(Object o){ return c.contains(o); }
    public Iterator<E> iterator()    { return new Iterator<E>() {
        private final Iterator<? extends E> i = c.iterator();
        public boolean hasNext() { return i.hasNext(); }
        public E next()          { return i.next(); }
        public void remove()     { throw new UnsupportedOperationException(); }
        @Override public void forEachRemaining(Consumer<? super E> action) {
            i.forEachRemaining(action);
        }
    }; }

    public boolean add(E e) { throw new UnsupportedOperationException(); }
    public boolean remove(Object o) { throw new UnsupportedOperationException(); }
    // ... 所有写方法全部抛 UnsupportedOperationException
}
```

`UnmodifiableList` 在此基础上多继承了 `UnmodifiableCollection`，并额外拦截 `set`、`add(index, e)`、`remove(index)`、`addAll(index, c)`，且把 `listIterator` 返回的迭代器也包装成只读：

```java
static class UnmodifiableList<E> extends UnmodifiableCollection<E> implements List<E> {
    @SuppressWarnings("serial")
    final List<? extends E> list;

    public E get(int index) { return list.get(index); }
    public E set(int index, E element) { throw new UnsupportedOperationException(); }
    public void add(int index, E element) { throw new UnsupportedOperationException(); }
    public E remove(int index) { throw new UnsupportedOperationException(); }
    public ListIterator<E> listIterator() { return listIterator(0); }
    public ListIterator<E> listIterator(final int index) {
        return new ListIterator<E>() {
            private final ListIterator<? extends E> i = list.listIterator(index);
            public void set(E e) { throw new UnsupportedOperationException(); }
            public void add(E e) { throw new UnsupportedOperationException(); }
            public void remove() { throw new UnsupportedOperationException(); }
            // ...
        };
    }
    public List<E> subList(int fromIndex, int toIndex) {
        return new UnmodifiableList<>(list.subList(fromIndex, toIndex));
    }
}
```

**关键点：`subList` 也被包装成只读，`listIterator` 也被拦截。** 但注意下面这个陷阱。

### 2.2 陷阱一：它只是"视图"，原集合改了就变

```java
List<String> original = new ArrayList<>(List.of("a", "b", "c"));
List<String> view = Collections.unmodifiableList(original);

System.out.println(view);          // [a, b, c]
original.add("d");                 // 修改原集合，注意：没有任何异常
System.out.println(view);          // [a, b, c, d]  ← 只读视图"偷偷"变了！

view.add("e");                     // 抛 UnsupportedOperationException
```

这是**最容易在生产里翻车的一点**。常见错法：

```java
public class UserService {
    private final List<String> tags = new ArrayList<>();

    // 错误：返回了只读视图，但内部还会修改 tags
    public List<String> getTags() {
        return Collections.unmodifiableList(tags);
    }

    public void addTag(String tag) {
        tags.add(tag);   // 外部持有的"只读"视图跟着变，调用方可能 ConcurrentModificationException
    }
}
```

**结论：`unmodifiable` 只保证"通过这个引用不能改"，不保证"内容不变"。** 要真正不可变，必须做防御性拷贝：

```java
public List<String> getTags() {
    return List.copyOf(tags);   // 真正的快照（JDK 10+）
    // 或者 JDK 8：Collections.unmodifiableList(new ArrayList<>(tags));
}
```

### 2.3 陷阱二：迭代器是"半只读"的

`unmodifiableList(list).iterator()` 返回的 `Iterator` 拦住了 `remove()`，但你**不能**通过它访问底层集合的可变迭代器。看似安全，问题出在别处：

```java
List<String> list = new ArrayList<>(List.of("a", "b"));
Iterator<String> it = Collections.unmodifiableList(list).iterator();
it.next();
it.remove();     // UnsupportedOperationException ✓ 被拦住了
```

看上去挺好。但 `UnmodifiableList` 的 `stream()`、`forEach()`、`spliterator()` 都是直接委托给底层集合的，**不存在写操作，所以没问题**。真正的坑在并发场景（见第四节）。

### 2.4 陷阱三：`toArray()` 是可变的

```java
List<String> view = Collections.unmodifiableList(List.of("a", "b"));
Object[] arr = view.toArray();
arr[0] = "hacked";       // 完全合法！
```

`toArray()` 返回的是新数组，改它当然不违反"集合只读"。但如果你的代码依赖"这个集合的任何派生数据都不可变"，就要注意。

## 三、synchronizedXxx：同步包装

### 3.1 源码：一把锁，粗粒度

```java
static class SynchronizedCollection<E> implements Collection<E>, Serializable {
    final Collection<E> c;      // 底层集合
    final Object mutex;         // 锁对象（默认是 this）

    SynchronizedCollection(Collection<E> c) {
        this.c = Objects.requireNonNull(c);
        mutex = this;
    }
    SynchronizedCollection(Collection<E> c, Object mutex) {
        this.c = Objects.requireNonNull(c);
        this.mutex = Objects.requireNonNull(mutex);
    }

    public int size() {
        synchronized (mutex) { return c.size(); }
    }
    public boolean add(E e) {
        synchronized (mutex) { return c.add(e); }
    }
    public Iterator<E> iterator() {
        return c.iterator();   // ★ 注意：没有加锁！返回的是裸迭代器
    }
    // ...每个方法都 synchronized (mutex)
}
```

### 3.2 致命坑点：迭代必须自己加锁

`iterator()` **返回的是底层集合的裸迭代器，没有加锁**。所以下面这段代码是**线程不安全**的：

```java
List<String> syncList = Collections.synchronizedList(new ArrayList<>());

// 错误！ ConcurrentModificationException 高发
for (String s : syncList) {
    System.out.println(s);
}
```

正确做法（JDK 官方 Javadoc 明确写了）：

```java
List<String> syncList = Collections.synchronizedList(new ArrayList<>());

synchronized (syncList) {           // 必须用包装对象本身作为锁
    for (String s : syncList) {
        System.out.println(s);
    }
}
```

**为什么必须锁 `syncList` 而不是别的对象？** 因为 `SynchronizedList` 的 `mutex` 默认是 `this`（即包装对象本身）。当你用 `synchronized (syncList)` 时，锁的正是那个 mutex。

用流式操作同样要小心：

```java
// 错误：内部迭代没有持锁
syncList.stream().filter(s -> s.startsWith("a")).count();

// 正确
long count;
synchronized (syncList) {
    count = syncList.stream().filter(s -> s.startsWith("a")).count();
}
```

### 3.3 为什么"复合操作"依然不安全

单个方法加锁 ≠ 复合操作原子。这是并发编程的通用规律，同步包装也不例外：

```java
List<String> syncList = Collections.synchronizedList(new ArrayList<>());

// 典型的 check-then-act 竞态
if (!syncList.contains("x")) {     // 线程 A 检查通过
    // ← 线程 B 在这里也检查通过并 add 了 "x"
    syncList.add("x");             // 现在出现两个 "x"
}
```

正确做法是自己用同一把锁把复合操作包起来：

```java
synchronized (syncList) {
    if (!syncList.contains("x")) {
        syncList.add("x");
    }
}
```

**这也是为什么应该优先用 `java.util.concurrent` 里的集合**：`ConcurrentHashMap` 的 `putIfAbsent`、`computeIfAbsent`，`CopyOnWriteArrayList` 的迭代快照，`ConcurrentLinkedQueue` 的无锁算法，都是为"复合操作原子性"设计的，性能和正确性都远好于同步包装。

### 3.4 选型建议

| 需求 | 推荐 |
| --- | --- |
| 高并发读写 Map | `ConcurrentHashMap` |
| 读多写少的 List | `CopyOnWriteArrayList` |
| 高并发队列 | `ConcurrentLinkedQueue` / `LinkedBlockingQueue` |
| 高并发 Set | `ConcurrentHashMap.newKeySet()` |
| 只是偶尔并发访问、方法调用本身安全 | `Collections.synchronizedXxx()`（可接受） |

**经验法则：`synchronizedXxx` 是"应急方案"而不是"默认方案"。** 它每次操作都抢同一把锁，多核下争抢严重；而且它不解决迭代和复合操作问题，容易给人虚假的安全感。

## 四、checkedXxx：运行时类型检查

### 4.1 它解决什么问题

泛型是**编译期**的，擦除之后运行时 `List` 里什么都可能装进去。最常见的翻车方式是"原始类型穿透"：

```java
List<String> strings = new ArrayList<>();
List raw = strings;         // 原始类型引用，编译器只给 warning
raw.add(123);               // 编译通过、运行通过！
String s = strings.get(0);  // ClassCastException ← 炸在这里
```

`checkedList` 让你**在写入时就炸**，而不是在读取时：

```java
List<String> checked = Collections.checkedList(new ArrayList<>(), String.class);

List raw = checked;
raw.add(123);
// java.lang.ClassCastException:
// Attempt to insert class java.lang.Integer element into collection
// with element type class java.lang.String
```

报错位置从 `get()` 提前到了 `add()`，**定位成本大幅降低**（写入点通常离 bug 更近）。

### 4.2 源码实现

```java
static class CheckedCollection<E> implements Collection<E>, Serializable {
    final Collection<E> c;
    final Class<E> type;        // 期望的元素类型

    @SuppressWarnings("unchecked")
    E typeCheck(Object o) {
        if (o != null && !type.isInstance(o))
            throw new ClassCastException(badElementMsg(o));
        return (E) o;
    }

    private String badElementMsg(Object o) {
        return "Attempt to insert " + o.getClass() +
               " element into collection with element type " + type;
    }

    public boolean add(E e)      { return c.add(typeCheck(e)); }
    public boolean addAll(Collection<? extends E> coll) {
        // 先全部检查，再整体加入（避免部分成功）
        for (E e : coll) { typeCheck(e); }
        return c.addAll(coll);
    }
    public Object[] toArray() {
        return c.toArray(new Object[0]);     // 不返回泛型数组，避免 ArrayStoreException 泄漏
    }
}
```

注意 `addAll` 的实现：**先全部校验再统一添加**，避免"前 3 个加进去了，第 4 个类型不对抛异常"造成的部分写入。

### 4.3 它能替代泛型吗

不能。`checkedXxx` 是"运行时兜底"，不能替代编译期泛型：

- 它检查的是**元素类型**，不检查泛型嵌套（`List<List<String>>` 只认最外层）；
- 它无法检查 `null`（`null` 永远通过）；
- 每次写入都有 `isInstance()` 开销。

**使用场景**：作为公共 API 的返回值，防止调用方用原始类型破坏你的集合契约。

```java
public List<String> getNames() {
    return Collections.checkedList(names, String.class);   // 防原始类型穿透
}
```

## 五、emptyXxx / singletonXxx：单例的极致优化

### 5.1 `EMPTY_LIST` 等常量

```java
// Collections 中定义
@SuppressWarnings("rawtypes")
public static final List EMPTY_LIST = new EmptyList<>();
public static final Map  EMPTY_MAP  = new EmptyMap<>();
public static final Set  EMPTY_SET  = new EmptySet<>();

public static final <T> List<T> emptyList() {
    return (List<T>) EMPTY_LIST;      // 直接返回全局单例
}
```

`EmptyList` 的实现非常"懒"：

```java
private static class EmptyList<E> extends AbstractList<E>
        implements RandomAccess, Serializable {
    public Iterator<E> iterator() { return emptyIterator(); }
    public int size() { return 0; }
    public boolean isEmpty() { return true; }
    public boolean contains(Object obj) { return false; }
    public E get(int index) { throw new IndexOutOfBoundsException("Index: "+index); }
}
```

要点：

1. **全局单例**：`Collections.emptyList()` 每次返回同一个对象，零分配；
2. **`emptyIterator()` 也是单例**：`EMPTY_ITERATOR` 全局共享，`hasNext()` 恒 false；
3. **必须用 `emptyList()` 而不是 `new ArrayList<>()`**：后者每次分配对象 + 底层数组（虽然 JDK 8 的 `ArrayList` 默认用共享的 `DEFAULTCAPACITY_EMPTY_ELEMENTDATA`，但对象头本身还是要分配）。

**为什么说 `Collections.emptyList()` 是"最完美的单例"？** 因为它无状态、不可变、无参构造、可以被任意多线程安全共享，而且泛型通过 `@SuppressWarnings("unchecked")` 一次性转换。**这是 JDK 里"零成本抽象"的教科书案例。**

### 5.2 singletonXxx

```java
Set<String> single = Collections.singleton("only-one");
// 底层是 SingletonSet：内部只有一个元素字段，iterator/contains 都是特化实现
```

它的 `iterator()` 是 `Collections.singletonIterator(element)`，同样是**无状态可共享**的实现。适合"返回唯一的默认配置项"这类场景。

## 六、真正的不可变：`List.of()` 与 `ImmutableCollections`

JDK 9 引入了 `List.of()`、`Set.of()`、`Map.of()`，底层是 `java.util.ImmutableCollections`，这是和 `unmodifiableXxx` **本质不同**的设计。

### 6.1 三个关键区别

| 维度 | `Collections.unmodifiableList(list)` | `List.of(...)` |
| --- | --- | --- |
| 是否拷贝 | 否，是视图 | **是，构造时拷贝/持有独立数据** |
| 原集合变化影响 | 会变（视图） | 不受影响 |
| 允许 null | 允许（取决于底层） | **禁止，抛 NPE** |
| `set` 等写操作 | `UnsupportedOperationException` | `UnsupportedOperationException` |
| 是否 Serializable | 是（包装类实现了） | **否**（反序列化后拿到的是新的不可变实例） |
| `subList`/`stream` | 委托 | 特化实现 |

```java
String[] arr = {"a", "b"};
List<String> immutable = List.of(arr);
arr[0] = "changed";
System.out.println(immutable);    // [a, b]  ← 不受影响！（List.of 做了拷贝）

List<String> view = Collections.unmodifiableList(Arrays.asList(arr));
arr[0] = "changed2";
System.out.println(view);         // [changed2, b]  ← 视图跟着变
```

### 6.2 `List.of()` 的分段实现

`ImmutableCollections.ListN` 最多支持 10 个元素（`List12` 是 1~2 个元素的特化），超过 10 个用 `ListN` 数组：

```java
// JDK 源码（简化）
static <E> List<E> listOf(E... elements) {
    switch (elements.length) {
        case 0: return ImmutableCollections.emptyList();
        case 1: return new ImmutableCollections.List12<>(elements[0]);
        case 2: return new ImmutableCollections.List12<>(elements[0], elements[1]);
        default: return new ImmutableCollections.ListN<>(elements);
    }
}
```

`List12` 用两个独立字段 `e0`/`e1` 存储，**没有数组开销**，`get(0)` 直接返回 `e0`。这种"按规模特化"的手法在 JDK 里反复出现（`Arrays.asList`、`Map.of` 的 `Map1`~`MapN`），是饿汉式性能优化。

### 6.3 `List.of()` 的坑

```java
List<String> list = List.of("a", "b");
list.add("c");                 // UnsupportedOperationException
List.of("a", null);            // NullPointerException（立即）
Set.of("a", "a");              // IllegalArgumentException（重复元素）
```

**`Set.of` / `Map.of` 遇到重复元素直接抛 `IllegalArgumentException`**，这一点和 `new HashSet<>(list)`（静默去重）完全不同，很多人第一次用会懵。

另外，`List.of()` 的 `contains(null)` 会抛 NPE：

```java
List.of("a").contains(null);   // NullPointerException!
```

`Arrays.asList` 则返回 false。这是设计取舍——**最快的 null 检查就是不做检查**。

### 6.4 不可变集合的三种创建方式对比

```java
// 1. JDK 9+：最优
List<String> a = List.of("x", "y");

// 2. JDK 8 兼容：视图 + 拷贝
List<String> b = Collections.unmodifiableList(new ArrayList<>(list));

// 3. Guava：老项目常见
List<String> c = ImmutableList.copyOf(list);
```

| 方案 | 拷贝 | null | 序列化 | 性能 |
| --- | --- | --- | --- | --- |
| `List.of` | ✓ | 禁止 | 通过写代理实现 | 最优（特化） |
| `unmodifiableList(new ArrayList<>(...))` | ✓ | 允许 | ✓ | 两次分配 |
| Guava `ImmutableList` | ✓ | 禁止 | ✓ | 优良，额外依赖 |

## 七、实战：如何正确地暴露集合

一个典型的服务层设计，把上面的知识全用上：

```java
public class OrderService {
    // 内部用可变集合
    private final Map<Long, List<String>> orderTags = new ConcurrentHashMap<>();

    public void addTag(Long orderId, String tag) {
        // 复合操作使用 ConcurrentHashMap 的原子方法
        orderTags.computeIfAbsent(orderId, k -> new CopyOnWriteArrayList<>()).add(tag);
    }

    /**
     * 对外暴露：
     * 1. unmodifiableMap 防止调用方直接改 Map 结构
     * 2. 内层 List 也包装成 unmodifiable，防止改元素
     * 3. 返回的是视图，但内层用了 CopyOnWriteArrayList（迭代安全），所以并发安全
     */
    public Map<Long, List<String>> allTags() {
        Map<Long, List<String>> copy = new LinkedHashMap<>();
        orderTags.forEach((k, v) ->
            copy.put(k, Collections.unmodifiableList(new ArrayList<>(v))));
        return Collections.unmodifiableMap(copy);   // 顶层只读
    }

    public List<String> tagsOf(Long orderId) {
        List<String> tags = orderTags.get(orderId);
        return tags == null ? Collections.emptyList() : List.copyOf(tags);
    }
}
```

**四条实践准则：**

1. **返回空集合而不是 null**：`Collections.emptyList()` / `List.of()`；
2. **对外返回值统一不可变**：`List.copyOf` / `unmodifiableXxx`（并注意视图语义）；
3. **并发场景优先用 `java.util.concurrent`**，`synchronizedXxx` 只作应急；
4. **需要真正不可变时用 `List.of`/`copyOf`**，不要用 `unmodifiableList(new ArrayList<>(...))` 之外的裸视图。

## 八、面试常见追问

**Q1：`Arrays.asList()` 的坑是什么？**

三点：(1) 返回的是**固定长度**视图，`add`/`remove` 抛 `UnsupportedOperationException`，但 `set` 可以；(2) 它**直接引用原数组**，改数组会改 List；(3) 不支持基本类型数组（`int[]` 会被当成一个元素）。要可变必须 `new ArrayList<>(Arrays.asList(arr))`。

**Q2：`unmodifiableList` 和 `List.of` 都能防修改，怎么选？**

需要"实时视图"（跟随原集合变化）用 `unmodifiableList`；需要"独立快照 + 严格不可变 + 禁止 null"用 `List.of`/`copyOf`。**业务代码 99% 的场景应该用 `List.of`/`copyOf`**，视图语义只在特殊场景（如框架内部）才需要。

**Q3：`Collections.synchronizedMap` 和 `ConcurrentHashMap` 差别在哪？**

(1) 锁粒度：前者全局单锁，后者分段/CAS；(2) 迭代：前者需手动加锁，后者弱一致且有原子复合方法；(3) null：`ConcurrentHashMap` 不允许 null key/value；(4) 性能：高并发下 `ConcurrentHashMap` 可高一个数量级。**能用 CHM 就不要用 synchronizedMap。**

**Q4：`Collections.checkedList` 能防住所有类型污染吗？**

不能。它只检查 `add`/`addAll`/`set` 等写入路径，且 `null` 永远通过；如果不是通过包装后的引用写入（例如直接操作底层集合），一样能绕过。它的定位是"提高报错位置的可读性"，不是安全边界。

**Q5：为什么 `Collections.unmodifiableList` 的 `iterator().remove()` 会抛异常，但 `for-each` 循环删除还是报 `ConcurrentModificationException`？**

`for-each` 编译后调用的是迭代器的 `remove`（如果写 `it.remove()`），在只读视图上会抛 `UnsupportedOperationException`；而 `ConcurrentModificationException` 来自**底层集合的 `modCount` 校验**——如果你在遍历时通过原集合（不是视图）修改，视图的迭代器会检测到 `modCount` 变化而报错。两个异常来源不同，要分清。

**Q6：JDK 里为什么不用不可变集合一律替代？**

因为不可变集合的场景是大容器 + 少数修改时都不划算，写操作需要整体拷贝。JDK 的选择是"按需提供工具"，让开发者在性能与安全间权衡，而不是强制。这也是 `List.copyOf` 只做浅拷贝的原因——深拷贝成本不可控。

## 九、总结

回到开头那道题：

> `Collections.unmodifiableList()` 和 `List.of()` 的区别

一句话答案：**前者是"只读视图"，不拷贝、原集合变化会透传、允许 null；后者是"不可变快照"，构造时持有独立数据、完全隔离、禁止 null、性能更好。需要快照语义就选 `List.of`/`List.copyOf`。**

再补一条工程结论：**JDK 的包装器是"薄薄的转发层 + 一层检查"，理解了这个本质，就理解了它们全部的行为边界**——`unmodifiable` 是"引用级只读"，`synchronized` 是"方法级加锁"，`checked` 是"写入时类型校验"，`empty/singleton` 是"单例优化"。它们都不是万能的并发/不可变方案，真正的并发安全要交给 `java.util.concurrent`，真正的不可变要交给 `List.of` 与防御性拷贝。
