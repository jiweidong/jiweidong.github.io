---
title: 【Java 集合】Iterator 迭代器深度解析：从 for-each 语法糖到 fail-fast/fail-safe 机制源码级剖析
date: 2026-08-26 08:00:00
tags:
  - Java
  - 集合
  - 源码
  - 面试
categories:
  - Java
  - 集合框架
author: 东哥
---

# 【Java 集合】Iterator 迭代器深度解析：从 for-each 语法糖到 fail-fast/fail-safe 机制源码级剖析

## 面试官：for-each 遍历集合时为什么不能删除元素？ConcurrentModificationException 是怎么抛出来的？

几乎每个 Java 开发都被 `ConcurrentModificationException` 坑过，但能说清它底层机制的人不多。这道题考察的是：**for-each 的本质、Iterator 设计模式、fail-fast 与 fail-safe 机制**。本文从字节码层面一路挖到 ArrayList、HashMap 源码。

## 一、for-each 只是语法糖：反编译看真相

先看一段最简单的代码：

```java
List<String> list = new ArrayList<>();
list.add("A");
list.add("B");
for (String s : list) {
    System.out.println(s);
}
```

用 `javap -c` 反编译后，字节码核心如下：

```java
// 编译后的真实逻辑（等价代码）
Iterator<String> it = list.iterator();   // 1. 调用 iterator()
while (it.hasNext()) {                    // 2. 循环条件 hasNext()
    String s = it.next();                 // 3. 取元素 next()
    System.out.println(s);
}
```

**结论：for-each 是 `Iterator` 的语法糖**，编译器自动帮你创建迭代器并调用 `hasNext()`/`next()`。数组的 for-each 则是普通索引遍历（`i < arr.length; i++`），两者完全不同——所以「为什么不能在 for-each 里删除元素」的本质是「为什么不能在迭代过程中修改集合结构」。

## 二、Iterator 设计模式：统一遍历接口

### 2.1 接口体系

```java
// 迭代器接口（java.util）
public interface Iterator<E> {
    boolean hasNext();          // 是否还有下一个
    E next();                   // 返回下一个元素
    default void remove() { throw new UnsupportedOperationException(); }
    default void forEachRemaining(Consumer<? super E> action) { ... }
}

// 集合要提供迭代器，实现 Iterable
public interface Iterable<T> {
    Iterator<T> iterator();
    default void forEach(Consumer<? super T> action) { ... }  // JDK 8+
}

// 列表专属：ListIterator 支持双向遍历、索引操作
public interface ListIterator<E> extends Iterator<E> {
    boolean hasPrevious();
    E previous();
    int nextIndex();
    int previousIndex();
    void set(E e);      // 替换当前元素
    void add(E e);      // 在当前位置插入
}
```

### 2.2 为什么需要 Iterator？

- **解耦遍历逻辑与集合实现**：客户端只依赖 `Iterator` 接口，不知道底层是数组还是链表；
- **统一遍历方式**：`for-each` 能同时作用于 `ArrayList`、`HashSet`、`LinkedList`、`TreeMap` 等一切 `Iterable`；
- **遍历中安全操作**：`Iterator.remove()` 是唯一能在遍历中安全删除元素的方式（后面解释）。

## 三、fail-fast：ArrayList 的迭代器源码

### 3.1 modCount：结构修改计数器

`AbstractList` 中维护了一个字段：

```java
// AbstractList.java
protected transient int modCount = 0;   // 结构修改次数
```

**凡是改变集合「结构」的操作（add、remove、clear）都会 `modCount++`**；而 `set` 修改元素值不算结构修改，不会自增。

### 3.2 Itr 内部类：核心校验逻辑

```java
// ArrayList.java —— Itr 内部类（精简）
private class Itr implements Iterator<E> {
    int cursor;              // 下一个元素的下标
    int lastRet = -1;        // 上一次返回的下标，-1 表示无
    int expectedModCount = modCount;   // ★ 迭代器创建时快照

    public boolean hasNext() { return cursor != size; }

    public E next() {
        checkForComodification();          // ★ 每次 next 都检查
        int i = cursor;
        Object[] elementData = ArrayList.this.elementData;
        if (i >= elementData.length) throw new ConcurrentModificationException();
        cursor = i + 1;
        return (E) elementData[lastRet = i];
    }

    public void remove() {
        if (lastRet < 0) throw new IllegalStateException();
        checkForComodification();
        try {
            ArrayList.this.remove(lastRet);          // 调用外部 remove
            cursor = lastRet;
            lastRet = -1;
            expectedModCount = modCount;             // ★ 同步快照
        } catch (IndexOutOfBoundsException ex) {
            throw new ConcurrentModificationException();
        }
    }

    final void checkForComodification() {
        if (modCount != expectedModCount)            // ★ 快照不一致 → 抛异常
            throw new ConcurrentModificationException();
    }
}
```

**异常抛出链路**：`next()` → `checkForComodification()` → 比较 `modCount` 与 `expectedModCount`，不一致就抛 `ConcurrentModificationException`。

### 3.3 经典场景还原

```java
List<String> list = new ArrayList<>(List.of("A", "B", "C"));

// ❌ 错误 1：for-each 里 list.remove()
for (String s : list) {
    if ("A".equals(s)) {
        list.remove(s);      // modCount++，迭代器快照没更新
    }
    // 下一次 next() → checkForComodification() → 抛异常！
}

// ❌ 错误 2：两个迭代器互相干扰
Iterator<String> it1 = list.iterator();
Iterator<String> it2 = list.iterator();
it1.next();
it2.remove();     // modCount++，it1 的 expectedModCount 过期
it1.next();       // 抛 ConcurrentModificationException

// ✅ 正确：用迭代器自身的 remove()
Iterator<String> it = list.iterator();
while (it.hasNext()) {
    String s = it.next();
    if ("A".equals(s)) {
        it.remove();   // 内部同步了 expectedModCount，安全
    }
}

// ✅ 或 JDK 8+：removeIf（底层就是迭代器 remove）
list.removeIf("A"::equals);
```

注意一个细节：**删除「倒数第二个」元素有时不报错**——因为 `hasNext()` 只看 `cursor != size`，恰好删完就结束、不再调用 `next()`，检查就来不及触发。这是 fail-fast 的「尽力而为」特性，**不能依赖它判断是否出错**。

## 四、fail-fast vs fail-safe 全面对比

| 维度 | fail-fast（快速失败） | fail-safe（安全失败） |
|------|---------------------|---------------------|
| 代表集合 | ArrayList、HashMap、HashSet 等 java.util 集合 | CopyOnWriteArrayList、ConcurrentHashMap 等 java.util.concurrent 集合 |
| 机制 | 遍历时检查 modCount，变化即抛异常 | 遍历的是**快照/副本**，不抛异常 |
| 一致性 | 弱一致性？不，是**强一致但会失败** | 弱一致性：可能看不到遍历期间的新增 |
| 性能 | 无额外拷贝开销 | 写时复制/遍历副本，有开销 |
| 适用场景 | 单线程或读多写少 | 高并发读写 |

### 4.1 ConcurrentHashMap：遍历时为什么安全？

`ConcurrentHashMap` 的迭代器基于 **弱一致性（weakly consistent）** 设计：

- 迭代器创建时记录当前 `Table` 数组引用与遍历位置；
- 遍历过程中**允许其他线程修改**，迭代器看到的是「某一时刻起的快照演进」，不会抛异常；
- 不保证看到遍历期间新增的元素，但保证**已遍历过的元素不会被重复或遗漏**（在正常扩容语义下）。

### 4.2 CopyOnWriteArrayList：写时复制

```java
// 每次写操作都复制底层数组
public boolean add(E e) {
    synchronized (lock) {
        Object[] elements = getArray();
        int len = elements.length;
        Object[] newElements = Arrays.copyOf(elements, len + 1);  // 全量复制
        newElements[len] = e;
        setArray(newElements);
        return true;
    }
}
// 迭代器直接遍历当前数组引用（COWIterator），永远不抛异常
```

**代价**：每次写都是 O(n) 复制，适合「读多写极少」场景（如监听器列表、配置缓存）。

## 五、HashMap 的迭代器：HashIterator 源码

`HashMap` 的迭代器遍历的是 **table 数组 + 链表/红黑树**，与 ArrayList 的连续数组不同：

```java
// HashMap.java —— HashIterator（精简）
abstract class HashIterator {
    Node<K,V> next;      // 下一个节点
    Node<K,V> current;
    int expectedModCount = modCount;   // 同样的快照机制
    int index;           // 当前桶位

    final Node<K,V> nextNode() {
        Node<K,V>[] t;
        Node<K,V> e = next;
        if (modCount != expectedModCount)   // ★ 同样的 fail-fast 检查
            throw new ConcurrentModificationException();
        ...
        // 当前链表走完，跳到下一个非空桶
        if (e == null && (t = table) != null) {
            do { } while (index < t.length && (e = t[index++]) == null);
        }
        ...
    }
}
```

**面试常考延伸**：HashMap 的迭代顺序是无序的（与插入顺序无关），`LinkedHashMap` 通过双向链表保证插入/访问顺序，`TreeMap` 按 key 排序——它们的迭代器都基于各自的数据结构实现，但 fail-fast 机制一脉相承。

## 六、Spliterator：并行流背后的迭代器

JDK 8 引入了 `Spliterator`（可分割迭代器），是 `Stream` 并行计算的基石：

```java
public interface Spliterator<T> {
    boolean tryAdvance(Consumer<? super T> action);  // 单元素推进
    Spliterator<T> trySplit();                       // ★ 分割出子任务
    long estimateSize();
    int characteristics();   // ORDERED / DISTINCT / SORTED / SIZED 等特性位
}
```

```java
// 手写一个简单 Spliterator 示例
List<Integer> list = IntStream.rangeClosed(1, 100).boxed().collect(Collectors.toList());
Spliterator<Integer> sp = list.spliterator();
Spliterator<Integer> half = sp.trySplit();   // 拆成两半，交给不同线程
```

`parallelStream()` 就是不断 `trySplit()` 把任务切分到线程池（ForkJoinPool）执行的。`characteristics()` 的特性位则决定了流框架能否做优化（如 `SIZED` 允许精确拆分、`ORDERED` 保证 encounter order）。

## 七、面试官追问环节

**Q1：Iterator 和 ListIterator 的区别？**
`ListIterator` 是 `Iterator` 的子接口，仅 List 可用：支持**双向遍历**（`previous()`）、**索引操作**（`nextIndex()`/`previousIndex()`）、**修改**（`set()`/`add()`）；`Iterator` 只能单向 + `remove()`。

**Q2：为什么用迭代器 remove() 就安全，list.remove() 就不安全？**
`Iterator.remove()` 在删除后会**同步更新 `expectedModCount = modCount`**，快照保持一致；而外部 `list.remove()` 只改 `modCount`，迭代器快照过期，下次检查就抛异常。

**Q3：fail-fast 是「快速失败」指什么？**
指**一旦检测到并发修改就立即抛异常终止遍历**，而不是继续用不确定的状态跑下去。它是一种防御性机制：宁可报错，也不给脏数据。注意它并**不保证一定能检测到**（如前面说的删倒数第二个的边界情况），所以不能依赖它做并发控制。

**Q4：有哪些方式能安全地边遍历边删除？**
1. `Iterator.remove()`；2. JDK 8 `removeIf()`；3. 收集到新列表再统一 `removeAll()`；4. `CopyOnWriteArrayList`（快照迭代器）；5. 反向 for 循环按索引删（仅 List）。

**Q5：ConcurrentHashMap 的迭代器为什么是弱一致的？**
因为它基于**遍历开始时的快照 + 分段遍历**，不持有全局锁。这样既保证了高并发吞吐，又避免了 fail-fast 的误报——代价是看不到遍历期间的更新，适合读多写少场景。

## 八、总结

- **for-each = Iterator 语法糖**，数组除外；
- **fail-fast**：`modCount` 快照比对，遍历中结构被改就抛 `ConcurrentModificationException`，`java.util` 集合标配；
- **fail-safe**：快照/副本遍历，不抛异常但弱一致，`java.util.concurrent` 集合标配；
- **安全删除**：用 `Iterator.remove()` / `removeIf()`，别在 for-each 里调 `list.remove()`；
- **Spliterator** 是 Stream 并行流的底层，`trySplit()` 负责任务切分。

理解 fail-fast 不是背结论，而是理解「**结构修改计数 + 快照校验**」这个朴素而优雅的设计——它用最小的代价，把并发修改的脏数据风险挡在了异常之外。
