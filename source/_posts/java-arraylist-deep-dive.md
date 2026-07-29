---
title: 【源码深度】Java ArrayList 源码深度解析：从扩容机制到 fail-fast 迭代器
date: 2026-07-29 08:00:00
tags:
  - Java
  - 集合
  - 源码
categories:
  - Java
  - 集合框架
author: 东哥
---

# 【源码深度】Java ArrayList 源码深度解析：从扩容机制到 fail-fast 迭代器

## 前言

ArrayList 是 Java 开发中使用频率最高的集合类之一，但很多人只停留在"底层是数组"这个认知层面。面试中关于 ArrayList 的高频问题包括：扩容机制、fail-fast 原理、与 LinkedList 的取舍、序列化优化等。本文从 JDK 8/17/21 源码出发，彻底解剖 ArrayList 的所有关键实现细节。

## 一、类结构概览

```java
public class ArrayList<E> extends AbstractList<E>
        implements List<E>, RandomAccess, Cloneable, java.io.Serializable
```

- **RandomAccess**：标记接口，支持 O(1) 随机访问
- **Cloneable**：支持克隆（浅拷贝）
- **Serializable**：可序列化，但序列化做了特殊优化

底层核心字段：

```java
// 默认初始容量
private static final int DEFAULT_CAPACITY = 10;
// 用于空实例的空数组
private static final Object[] EMPTY_ELEMENTDATA = {};
// 用于默认大小空实例的空数组（与 EMPTY_ELEMENTDATA 区分，用来确定首次扩容的阈值）
private static final Object[] DEFAULTCAPACITY_EMPTY_ELEMENTDATA = {};
// 实际存储元素的数组
transient Object[] elementData;
// 元素个数
private int size;
```

> 注意：elementData 被 `transient` 修饰！这是 ArrayList 序列化的关键优化点。

## 二、构造方法与初始化策略

### 2.1 无参构造

```java
public ArrayList() {
    this.elementData = DEFAULTCAPACITY_EMPTY_ELEMENTDATA;
}
```

JDK 7 及之前：`new ArrayList()` 会初始化一个容量为 10 的数组。  
**JDK 8+：懒加载，只在首次 add 时扩容到 DEFAULT_CAPACITY（10）。** 这是很重要的内存优化。

### 2.2 指定初始容量

```java
public ArrayList(int initialCapacity) {
    if (initialCapacity > 0) {
        this.elementData = new Object[initialCapacity];
    } else if (initialCapacity == 0) {
        this.elementData = EMPTY_ELEMENTDATA;
    } else {
        throw new IllegalArgumentException("Illegal Capacity: " + initialCapacity);
    }
}
```

指定负数会抛异常。指定 0 与无参构造的区别是：使用 `EMPTY_ELEMENTDATA`，首次 add 时扩容到 1（不是 10）。

### 2.3 从集合构造

```java
public ArrayList(Collection<? extends E> c) {
    Object[] a = c.toArray();
    if ((size = a.length) != 0) {
        if (a.getClass() != Object[].class)
            a = Arrays.copyOf(a, size, Object[].class);
        elementData = a;
    } else {
        elementData = EMPTY_ELEMENTDATA;
    }
}
```

亮点：**这里有一个 Bug 修复** —— `c.toArray()` 不一定返回 `Object[]`，可能是 `String[]` 等类型。所以用 `Arrays.copyOf` 强制转为 `Object[]`。

## 三、扩容机制（核心）

### 3.1 add 流程

```java
public boolean add(E e) {
    modCount++;  // 记录结构性修改次数
    add(e, elementData, size);
    return true;
}

private void add(E e, Object[] elementData, int s) {
    if (s == elementData.length)
        elementData = grow();
    elementData[s] = e;
    size = s + 1;
}
```

### 3.2 grow 扩容方法

```java
private Object[] grow() {
    return grow(size + 1);
}

private Object[] grow(int minCapacity) {
    int oldCapacity = elementData.length;
    if (oldCapacity > 0 || elementData != DEFAULTCAPACITY_EMPTY_ELEMENTDATA) {
        int newCapacity = ArraysSupport.newLength(
            oldCapacity,          // 旧容量
            minCapacity - oldCapacity,  // 最小增长量
            oldCapacity >> 1     // 首选增长量 —— 相当于 oldCapacity * 0.5
        );
        return elementData = Arrays.copyOf(elementData, newCapacity);
    } else {
        // 无参构造的懒加载首次扩容
        return elementData = new Object[Math.max(DEFAULT_CAPACITY, minCapacity)];
    }
}
```

**扩容公式**：
- 默认增长量 = `oldCapacity >> 1`（即 **50%**）
- `ArraysSupport.newLength` 会选择 `minGrowth` 和 `prefGrowth` 中较大的那个
- 最终容量 ≈ oldCapacity + max(1, oldCapacity >> 1) = **1.5 倍**

具体 `newLength` 的计算逻辑：

```java
public static int newLength(int oldLength, int minGrowth, int prefGrowth) {
    int prefLength = oldLength + Math.max(minGrowth, prefGrowth);
    if (0 < prefLength && prefLength <= SOFT_MAX_ARRAY_LENGTH) {
        return prefLength;
    } else {
        return hugeLength(oldLength, minGrowth);
    }
}
```

`SOFT_MAX_ARRAY_LENGTH = Integer.MAX_VALUE - 8`（减 8 是因为某些 JVM 需要在数组头部存储对象头）。

### 3.3 扩容示例

```
默认无参构造 → elementData = DEFAULTCAPACITY_EMPTY_ELEMENTDATA
第 1 次 add  → 扩容到 10
第 11 次 add → 扩容到 15  (10 + 10>>1 = 15)
第 16 次 add → 扩容到 22  (15 + 15>>1 = 22)
第 23 次 add → 扩容到 33
...
```

**关键结论**：扩容涉及 `Arrays.copyOf`，即**创建新数组 + 拷贝旧数据**，时间复杂度 O(n)。如果能够预估算量，**指定初始容量**可大幅减少扩容次数。

## 四、add 在指定位置的性能分析

```java
public void add(int index, E element) {
    rangeCheckForAdd(index);  // 越界检查
    modCount++;
    final int s = size;
    Object[] elementData = this.elementData;
    if (s == elementData.length)
        elementData = grow();
    System.arraycopy(elementData, index,
                     elementData, index + 1, s - index);
    elementData[index] = element;
    size = s + 1;
}
```

**核心操作**：`System.arraycopy` 将 index 之后的元素全部后移一位。  
**时间复杂度 O(n)** —— 这是 ArrayList 在中间插入性能差的根源。

## 五、remove 方法源码

### 5.1 按索引删除

```java
public E remove(int index) {
    Objects.checkIndex(index, size);
    modCount++;
    E oldValue = elementData(index);
    int numMoved = size - index - 1;
    if (numMoved > 0)
        System.arraycopy(elementData, index + 1,
                         elementData, index, numMoved);
    elementData[--size] = null;  // 将末尾置 null，帮助 GC
    return oldValue;
}
```

亮点：**`elementData[--size] = null`** —— 如果不置 null，对象无法被 GC 回收，可能导致内存泄漏。

### 5.2 按对象删除

```java
public boolean remove(Object o) {
    final Object[] es = elementData;
    final int size = this.size;
    int i = 0;
    found: {
        if (o == null) {
            for (; i < size; i++)
                if (es[i] == null)
                    break found;
        } else {
            for (; i < size; i++)
                if (o.equals(es[i]))
                    break found;
        }
        return false;
    }
    fastRemove(es, i);
    return true;
}
```

注意：**只删除第一个匹配的元素**。如果要删除所有，需使用 `removeAll` 或 `removeIf`。

## 六、fail-fast 机制详解

### 6.1 什么是 fail-fast？

当多个线程并发修改 ArrayList 时，或者单线程在迭代过程中通过 `list.remove()` 等非迭代器方法修改结构，迭代器会立即抛出 `ConcurrentModificationException`。

### 6.2 实现原理

```java
// AbstractList 中的核心字段
protected transient int modCount = 0;
```

每次结构性修改（add、remove、clear 等），`modCount` 都会自增。

```java
// ArrayList 的迭代器
private class Itr implements Iterator<E> {
    int cursor;          // 下一个要返回的元素索引
    int lastRet = -1;    // 上一个返回的索引，-1 表示没有
    int expectedModCount = modCount;  // 期望的 modCount

    public E next() {
        checkForComodification();  // 检查是否被并发修改
        int i = cursor;
        if (i >= size)
            throw new NoSuchElementException();
        Object[] elementData = ArrayList.this.elementData;
        if (i >= elementData.length)
            throw new ConcurrentModificationException();
        cursor = i + 1;
        return (E) elementData[lastRet = i];
    }

    final void checkForComodification() {
        if (modCount != expectedModCount)
            throw new ConcurrentModificationException();
    }
}
```

**关键**：迭代器创建时保存 `expectedModCount = modCount`。每次 `next()` 或 `remove()` 都会对比，不相等就抛异常。

### 6.3 正确的删除方式

```java
// ✅ 使用迭代器的 remove
Iterator<String> it = list.iterator();
while (it.hasNext()) {
    String s = it.next();
    if (s.equals("xxx")) {
        it.remove();  // 内部会更新 expectedModCount
    }
}

// ✅ Java 8+ 使用 removeIf
list.removeIf(s -> s.equals("xxx"));

// ❌ 错误方式
for (String s : list) {  // 语法糖本质是迭代器
    if (s.equals("xxx")) {
        list.remove(s);  // 触发 modCount 变化，下次 next() 抛出异常
    }
}
```

## 七、序列化优化 —— 为什么用 transient

ArrayList 实现了 `Serializable`，但 `elementData` 被 `transient` 修饰。原因：

1. **数组容量通常大于实际元素个数**。`elementData.length >= size`，直接序列化会多出 null 元素，浪费带宽。
2. **自定义序列化**：只序列化 `size` 个实际元素。

```java
private void writeObject(java.io.ObjectOutputStream s) throws IOException {
    int expectedModCount = modCount;
    s.defaultWriteObject();          // 写非 transient 字段（size）
    s.writeInt(size);                // 写元素个数

    for (int i = 0; i < size; i++) {
        s.writeObject(elementData[i]);  // 只写实际元素
    }

    if (modCount != expectedModCount) {
        throw new ConcurrentModificationException();
    }
}

private void readObject(java.io.ObjectInputStream s) throws IOException, ClassNotFoundException {
    s.defaultReadObject();
    s.readInt();  // 读 size

    if (size > 0) {
        Object[] elements = new Object[size];
        for (int i = 0; i < size; i++) {
            elements[i] = s.readObject();
        }
        elementData = elements;
    }
}
```

序列化/反序列化时也会做 fail-fast 检查！

## 八、ArrayList 面试高频题

### Q1: ArrayList 和 LinkedList 怎么选？

| 维度 | ArrayList | LinkedList |
|------|-----------|------------|
| 底层结构 | 动态数组 | 双向链表 |
| 随机访问 get(i) | O(1) | O(n) |
| 尾部插入 | 均摊 O(1) | O(1) |
| 中间插入/删除 | O(n) 数组拷贝 | O(1) 改指针 |
| 内存占用 | 紧凑，只存数据 | 每个节点额外存前后指针 |
| 内存连续性 | 连续内存 | 非连续 |

**结论**：绝大多数场景选 ArrayList。LinkedList 的"中间插入快"优势在 CPU 缓存不命中面前通常不成立。

### Q2: 初始化 ArrayList 时指定容量有什么好处？

避免频繁扩容导致的数组拷贝。已知数据量时指定容量可提升性能 50%+。

```java
// 优化前：扩容 7 次（10→15→22→33→49→73→109）
List<String> list = new ArrayList<>();
for (int i = 0; i < 100; i++) {
    list.add("item-" + i);
}

// 优化后：0 次扩容
List<String> list = new ArrayList<>(100);
for (int i = 0; i < 100; i++) {
    list.add("item-" + i);
}
```

### Q3: ArrayList 的 subList 有什么坑？

`subList(fromIndex, toIndex)` 返回的是**内部类 SubList 的视图（view）**，不是快照。对 subList 的修改会直接影响原 list。

```java
List<String> list = new ArrayList<>(Arrays.asList("A", "B", "C", "D"));
List<String> sub = list.subList(1, 3); // [B, C]
sub.set(0, "X");                       // list 变成 [A, X, C, D]
```

**大坑**：对原 list 做结构性修改后，subList 再操作会抛 `ConcurrentModificationException`。

## 九、JDK 17/21 中的改进

JDK 17+ 中，ArrayList 没有大的结构性变化，但有一些优化：

1. **更安全的数组边界检查**：JDK 17 使用了 `Objects.checkIndex()` 统一检查（JDK 8 中用的是 `rangeCheck()` 私有方法）
2. **新增 `grow()` 重载**：JDK 17 将扩容逻辑提取到单独的 `grow()` 方法，让 `add()` 更清晰
3. **新增 `addAll` 重载优化**：`addAll(int, Collection)` 在 JDK 17 中优化了对随机访问集合的批量复制

## 十、总结

| 特性 | 说明 |
|------|------|
| 底层 | Object[] 动态数组 |
| 默认容量 | 10（JDK 8+ 懒加载） |
| 扩容倍率 | 约 1.5 倍 |
| 扩容成本 | O(n) 数组复制 |
| 随机访问 | O(1) |
| 中部插入/删除 | O(n) |
| 线程安全 | 否（可用 Collections.synchronizedList 或 CopyOnWriteArrayList） |
| fail-fast | 通过 modCount 实现 |

理解 ArrayList 源码不仅是面试需要，更是写出高性能 Java 代码的基础。知道扩容机制，就知道为什么要指定初始容量；知道 fail-fast 原理，就不会写出隐性 BUG 的迭代删除代码。
