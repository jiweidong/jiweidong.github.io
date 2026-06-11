---
title: Java 集合框架（List 篇）源码深度解析
date: 2026-06-08 23:40:00
tags: [Java, 集合, 源码分析, ArrayList, LinkedList]
categories: 源码分析
---

## 前言

List 是 Java 集合框架中最常用的接口之一。本文从源码层面深入分析 **ArrayList**、**LinkedList**、**Vector**、**CopyOnWriteArrayList** 四大实现类的底层原理。

---

## 一、ArrayList 源码解析

### 1. 底层数据结构

```java
public class ArrayList<E> extends AbstractList<E>
        implements List<E>, RandomAccess, Cloneable, java.io.Serializable {
    
    // 默认初始容量
    private static final int DEFAULT_CAPACITY = 10;
    
    // 空数组（用于空实例）
    private static final Object[] EMPTY_ELEMENTDATA = {};
    
    // 默认大小的空数组
    private static final Object[] DEFAULTCAPACITY_EMPTY_ELEMENTDATA = {};
    
    // 实际存储元素的数组（核心！）
    transient Object[] elementData;
    
    // 列表元素个数
    private int size;
}
```

**核心要点：**
- 底层用 `Object[]` 数组存储
- 默认初始容量 **10**
- 实现了 `RandomAccess` 接口，支持快速随机访问

### 2. 构造方法

```java
// 指定初始容量
public ArrayList(int initialCapacity) {
    if (initialCapacity > 0) {
        this.elementData = new Object[initialCapacity];
    } else if (initialCapacity == 0) {
        this.elementData = EMPTY_ELEMENTDATA;
    } else {
        throw new IllegalArgumentException("Illegal Capacity: " + initialCapacity);
    }
}

// 无参构造：懒加载，首次添加才初始化为10
public ArrayList() {
    this.elementData = DEFAULTCAPACITY_EMPTY_ELEMENTDATA;
}

// 从集合构造
public ArrayList(Collection<? extends E> c) {
    elementData = c.toArray();
    if ((size = elementData.length) != 0) {
        // 防御性复制：防止 c.toArray() 返回的不是 Object[]
        if (elementData.getClass() != Object[].class)
            elementData = Arrays.copyOf(elementData, size, Object[].class);
    } else {
        this.elementData = EMPTY_ELEMENTDATA;
    }
}
```

**源码亮点：** 无参构造不再直接 new Object[10]，而是使用**懒加载**策略，首次 add 时才扩容到 10，节省内存。

### 3. add 方法 —— 核心扩容机制

```java
public boolean add(E e) {
    // 确保内部容量足够，size+1 是所需最小容量
    ensureCapacityInternal(size + 1);
    // 在 size 位置放入元素
    elementData[size++] = e;
    return true;
}

private void ensureCapacityInternal(int minCapacity) {
    // 计算实际需要的容量
    int capacity = calculateCapacity(elementData, minCapacity);
    // 确认是否需要扩容
    ensureExplicitCapacity(capacity);
}

private static int calculateCapacity(Object[] elementData, int minCapacity) {
    // 如果是懒加载的空数组，取默认容量10和minCapacity的最大值
    if (elementData == DEFAULTCAPACITY_EMPTY_ELEMENTDATA) {
        return Math.max(DEFAULT_CAPACITY, minCapacity);
    }
    return minCapacity;
}

private void ensureExplicitCapacity(int minCapacity) {
    modCount++;  // 结构性修改计数器
    if (minCapacity - elementData.length > 0)
        grow(minCapacity);  // 需要扩容
}
```

#### 扩容核心 —— grow 方法

```java
private void grow(int minCapacity) {
    int oldCapacity = elementData.length;
    // 新容量 = 旧容量 + 旧容量 >> 1（即扩容 1.5 倍）
    int newCapacity = oldCapacity + (oldCapacity >> 1);
    
    // 如果 1.5 倍还不够，就用 minCapacity
    if (newCapacity - minCapacity < 0)
        newCapacity = minCapacity;
    
    // 如果新容量超过 MAX_ARRAY_SIZE，调用 hugeCapacity
    if (newCapacity - MAX_ARRAY_SIZE > 0)
        newCapacity = hugeCapacity(minCapacity);
    
    // 最关键的一步：数组复制（浅拷贝）
    elementData = Arrays.copyOf(elementData, newCapacity);
}
```

**扩容流程总结：**

```
add → 计算所需容量 → 判断是否扩容 → 1.5倍扩容 → Arrays.copyOf 创建新数组
```

> **为什么是 1.5 倍？** 太大浪费内存，太小频繁扩容。1.5 倍是经验值，兼顾时间与空间。

### 4. get 方法 —— O(1) 随机访问

```java
public E get(int index) {
    // 检查下标是否越界
    rangeCheck(index);
    // 直接数组下标访问 O(1)
    return elementData(index);
}

E elementData(int index) {
    return (E) elementData[index];
}
```

**ArrayList 的优势就在这里：** 按下标访问就是一次数组寻址，时间复杂度 **O(1)**。

### 5. remove 方法

```java
public E remove(int index) {
    rangeCheck(index);
    modCount++;
    E oldValue = elementData(index);
    
    // 计算需要移动的元素个数
    int numMoved = size - index - 1;
    if (numMoved > 0)
        // 将 index+1 及之后的元素全部前移一位
        System.arraycopy(elementData, index + 1, elementData, index, numMoved);
    
    // 将最后一个元素置 null，帮助 GC
    elementData[--size] = null;
    return oldValue;
}
```

**时间：** O(n) — 删除元素需要移动后续所有元素

### 6. ArrayList 核心特性总结

| 操作 | 时间复杂度 | 说明 |
|------|-----------|------|
| `get(int)` | O(1) | 数组随机访问 |
| `add(E)` | O(1) 均摊 | 尾插，扩容时 O(n) |
| `add(int, E)` | O(n) | 需要移动元素 |
| `remove(int)` | O(n) | 需要移动元素 |
| `indexOf(Object)` | O(n) | 线性扫描 |

---

## 二、LinkedList 源码解析

### 1. 底层数据结构 —— 双向链表

```java
public class LinkedList<E> extends AbstractSequentialList<E>
        implements List<E>, Deque<E>, Cloneable, java.io.Serializable {
    
    // 链表长度
    transient int size = 0;
    
    // 头节点
    transient Node<E> first;
    
    // 尾节点
    transient Node<E> last;
}
```

#### Node 内部类

```java
private static class Node<E> {
    E item;           // 实际数据
    Node<E> next;     // 后继指针
    Node<E> prev;     // 前驱指针

    Node(Node<E> prev, E element, Node<E> next) {
        this.item = element;
        this.next = next;
        this.prev = prev;
    }
}
```

### 2. add 方法 —— 尾插法

```java
public boolean add(E e) {
    linkLast(e);
    return true;
}

void linkLast(E e) {
    final Node<E> l = last;
    final Node<E> newNode = new Node<>(l, e, null);
    last = newNode;
    
    if (l == null)
        first = newNode;  // 链表为空时，新节点也是头节点
    else
        l.next = newNode; // 原尾节点的 next 指向新节点
    
    size++;
    modCount++;
}
```

**时间复杂度 O(1)** — 双向链表持尾节点引用，直接追加。

### 3. get 方法 —— 二分查找优化

```java
public E get(int index) {
    checkElementIndex(index);
    return node(index).item;
}

Node<E> node(int index) {
    // 二分思想：如果 index < size/2，从头遍历；否则从尾遍历
    if (index < (size >> 1)) {
        Node<E> x = first;
        for (int i = 0; i < index; i++)
            x = x.next;
        return x;
    } else {
        Node<E> x = last;
        for (int i = size - 1; i > index; i--)
            x = x.prev;
        return x;
    }
}
```

**源码亮点：** LinkedList 的 `node()` 方法做了**二分查找优化**，根据 index 在链表前半段还是后半段，选择从头或从尾遍历，平均性能比单向遍历好一倍。

### 4. remove 方法

```java
public boolean remove(Object o) {
    if (o == null) {
        for (Node<E> x = first; x != null; x = x.next) {
            if (x.item == null) {
                unlink(x);
                return true;
            }
        }
    } else {
        for (Node<E> x = first; x != null; x = x.next) {
            if (o.equals(x.item)) {
                unlink(x);  // 真正删除节点
                return true;
            }
        }
    }
    return false;
}

E unlink(Node<E> x) {
    final E element = x.item;
    final Node<E> next = x.next;
    final Node<E> prev = x.prev;

    // 断开前驱
    if (prev == null) {
        first = next;
    } else {
        prev.next = next;
        x.prev = null;
    }

    // 断开后继
    if (next == null) {
        last = prev;
    } else {
        next.prev = prev;
        x.next = null;
    }

    x.item = null;  // help GC
    size--;
    modCount++;
    return element;
}
```

**注意：** 虽然是链表删除，但查找元素需要 O(n) 遍历。真正的删除操作 `unlink()` 是 O(1)。

### 5. LinkedList 核心特性总结

| 操作 | 时间复杂度 | 说明 |
|------|-----------|------|
| `get(int)` | O(n) | 需要遍历（有二分优化） |
| `add(E)` | O(1) | 尾插 |
| `add(int, E)` | O(n) | 查找位置 O(n) + 插入 O(1) |
| `remove(Object)` | O(n) | 查找 O(n) + 删除 O(1) |
| `remove(int)` | O(n) | 查找 O(n) + 删除 O(1) |
| 内存 | 较大 | 每个节点额外存储两个指针 |

---

## 三、Vector 源码解析

### 1. 与 ArrayList 的区别

```java
public class Vector<E> extends AbstractList<E>
        implements List<E>, RandomAccess, Cloneable, java.io.Serializable {

    protected Object[] elementData;  // 和 ArrayList 一样用数组
    protected int elementCount;      // 元素个数
    protected int capacityIncrement; // 扩容增量
}
```

**核心区别：**

```java
// Vector 的 add 方法加了 synchronized
public synchronized boolean add(E e) {
    modCount++;
    ensureCapacityHelper(elementCount + 1);
    elementData[elementCount++] = e;
    return true;
}

// 其他方法同理
public synchronized E get(int index) {
    if (index >= elementCount)
        throw new ArrayIndexOutOfBoundsException(index);
    return elementData(index);
}
```

### 2. Vector 扩容策略

```java
private void grow(int minCapacity) {
    int oldCapacity = elementData.length;
    // 如果指定了 capacityIncrement 则按增量扩容，否则翻倍
    int newCapacity = oldCapacity + ((capacityIncrement > 0) ?
                                     capacityIncrement : oldCapacity);
    if (newCapacity - minCapacity < 0)
        newCapacity = minCapacity;
    if (newCapacity - MAX_ARRAY_SIZE > 0)
        newCapacity = hugeCapacity(minCapacity);
    elementData = Arrays.copyOf(elementData, newCapacity);
}
```

**扩容对比：**

| 特性 | ArrayList | Vector |
|------|-----------|--------|
| 线程安全 | 否 | 是（synchronized） |
| 扩容倍数 | 1.5 倍 | **2 倍**（或按 capacityIncrement） |
| 默认容量 | 10 | 10 |
| 性能 | 高 | 较低（全同步） |
| 出现时间 | JDK 1.2 | JDK 1.0（遗留类） |

> **是否应该使用 Vector？** 不建议。Vector 的同步粒度太粗，全方法同步。需要线程安全时，用 `Collections.synchronizedList()` 或 `CopyOnWriteArrayList` 替代。

---

## 四、CopyOnWriteArrayList 源码解析

### 1. 设计思想

```java
public class CopyOnWriteArrayList<E>
        implements List<E>, RandomAccess, Cloneable, java.io.Serializable {
    
    // 使用 ReentrantLock 保证并发安全
    final transient ReentrantLock lock = new ReentrantLock();
    
    // volatile 数组保证可见性
    private transient volatile Object[] array;
}
```

**核心思想：** 写时复制（Copy-On-Write）

- **读操作：** 不加锁，直接读
- **写操作：** 先加锁，复制一份新数组，在新数组上修改，然后将新数组赋值给 array 引用

### 2. add 方法

```java
public boolean add(E e) {
    final ReentrantLock lock = this.lock;
    lock.lock();  // 写操作加锁
    try {
        Object[] elements = getArray();
        int len = elements.length;
        // 复制出一份新数组（长度+1）
        Object[] newElements = Arrays.copyOf(elements, len + 1);
        newElements[len] = e;  // 在新数组上添加
        setArray(newElements); // 将新数组赋值给 volatile array
        return true;
    } finally {
        lock.unlock();
    }
}
```

### 3. get 方法

```java
public E get(int index) {
    return get(getArray(), index);  // 无需加锁
}

private E get(Object[] a, int index) {
    return (E) a[index];
}
```

读操作不加锁，因为 array 是 `volatile` 的，保证了可见性。

### 4. 注意事项

**优点：**
- 读操作性能极高（无锁，无阻塞）
- 适合**读多写少**的场景

**缺点：**
- 内存占用大：每次写都复制整个数组
- 数据最终一致性：读操作可能读不到最新的写（但 array 是 volatile，实际大部分场景是强一致的）

---

## 五、四大 List 实现对比

| 特性 | ArrayList | LinkedList | Vector | CopyOnWriteArrayList |
|------|-----------|------------|--------|---------------------|
| 底层结构 | 动态数组 | 双向链表 | 动态数组 | 动态数组 + COW |
| 线程安全 | ❌ | ❌ | ✅（synchronized） | ✅（ReentrantLock） |
| 随机访问 | O(1) | O(n) | O(1) | O(1) |
| 尾部插入 | O(1) 均摊 | O(1) | O(1) 均摊 | O(n) |
| 中间插入 | O(n) | O(n) | O(n) | O(n) + 数组复制 |
| 删除 | O(n) | O(n) | O(n) | O(n) + 数组复制 |
| 内存占用 | 较少 | 较大（双指针） | 较少 | 较大（写时复制） |
| 适用场景 | 随机访问多 | 频繁插入/删除 | 遗留系统 | 读多写少 |

---

## 六、阿里开发手册中的 List 规范

1. **ArrayList 的 subList 不可强转**：subList 返回的是内部类 SubList，强转 ArrayList 会抛 ClassCastException
2. **不要在 foreach 中 remove**：会抛 ConcurrentModificationException。使用 Iterator.remove() 或 Collectors.filter()
3. **指定初始容量**：如果已知数据量，指定初始容量避免频繁扩容
4. **LinkedList 慎用**：数据量大时随机访问性能差，除非确定需要频繁的头尾操作
5. **Collections.emptyList() 不可修改**：返回的不可变集合，不可 add/remove

## 总结

- **ArrayList**：日常最常用，随机访问之王，尾部插入性能优异
- **LinkedList**：双端操作场景（队列/栈），随机访问是短板
- **Vector**：历史遗留，已被 ArrayList 取代，别用了
- **CopyOnWriteArrayList**：并发读多写少的场景，但要承受写时复制开销

理解源码不是死记硬背，而是明白每个设计决策背后的**权衡**。ArrayList 用 1.5 倍扩容、LinkedList 用双向链表做二分查找、CopyOnWriteArrayList 用空间换时间——这些都是优秀的设计哲学。
