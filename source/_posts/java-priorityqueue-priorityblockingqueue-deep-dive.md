---
title: 【Java进阶】PriorityQueue 与 PriorityBlockingQueue 优先队列深度解析：从二叉堆到源码实现
date: 2026-07-06 08:00:00
tags:
  - Java
  - 集合
  - 并发
  - 源码分析
categories:
  - Java
  - Java进阶
author: 东哥
---

# PriorityQueue 与 PriorityBlockingQueue 优先队列深度解析

## 一、引言

优先队列（Priority Queue）是日常开发中非常常用的数据结构。与普通队列的 FIFO（先进先出）不同，**优先队列中的元素按照优先级出队**——优先级最高的元素最先出队。

在 Java 中，`java.util.PriorityQueue` 和 `java.util.concurrent.PriorityBlockingQueue` 是优先队列的两个实现。前者是非线程安全的，后者是线程安全的。两者的底层都基于 **二叉堆（Binary Heap）**，特别是**小顶堆（Min-Heap）**。

本文将深入分析两者的源码实现、扩容机制、迭代器行为，以及 PriorityBlockingQueue 的并发控制策略，最后给出最佳实践和面试要点。

---

## 二、二叉堆基础

在深入源码之前，必须理解二叉堆的数据结构。

### 2.1 什么是二叉堆

二叉堆是一棵**完全二叉树**，满足以下性质：

- **小顶堆**：任意节点的值 ≤ 其子节点的值
- **大顶堆**：任意节点的值 ≥ 其子节点的值

Java 的 `PriorityQueue` 默认使用**小顶堆**，即队首元素始终是最小的元素。

### 2.2 数组表示

二叉堆使用数组存储（而非链表），对于数组中下标为 `k` 的元素：

```
父节点下标： (k - 1) >>> 1
左子节点：   (k << 1) + 1
右子节点：   (k << 1) + 2
```

这种存储方式非常紧凑，不需要额外指针，空间效率高。

### 2.3 核心操作复杂度

| 操作 | 时间复杂度 | 说明 |
|------|-----------|------|
| offer(e) / add(e) | O(log n) | 插入后上浮（siftUp） |
| poll() | O(log n) | 移除堆顶后下沉（siftDown） |
| peek() | O(1) | 直接返回堆顶元素 |
| remove(o) | O(n) | 需要线性查找 + 下沉 |
| contains(o) | O(n) |

---

## 三、PriorityQueue 源码深度分析

### 3.1 类定义与核心字段

```java
public class PriorityQueue<E> extends AbstractQueue<E>
    implements java.io.Serializable {

    // 默认初始容量
    private static final int DEFAULT_INITIAL_CAPACITY = 11;

    // 底层数组，存储堆元素
    transient Object[] queue;

    // 元素个数
    private int size = 0;

    // 比较器，如果为 null 则使用元素的自然顺序
    private final Comparator<? super E> comparator;

    // 结构性修改次数，用于 fail-fast 迭代器
    transient int modCount = 0;
}
```

关键点：
- **queue 数组**不一定是完全填满的，`size` 指示有效元素个数
- 如果未指定 `Comparator`，则元素必须实现 `Comparable` 接口

### 3.2 初始化

```java
public PriorityQueue(int initialCapacity, Comparator<? super E> comparator) {
    if (initialCapacity < 1)
        throw new IllegalArgumentException();
    this.queue = new Object[Math.max(initialCapacity, 1)];
    this.comparator = comparator;
}
```

也可以通过一个已有的 `SortedSet` 或 `PriorityQueue` 初始化，直接复制底层数组。

### 3.3 插入操作：offer()

```java
public boolean offer(E e) {
    if (e == null)
        throw new NullPointerException();  // 不允许 null 元素
    modCount++;
    int i = size;
    if (i >= queue.length)
        grow(i + 1);  // 扩容
    size = i + 1;
    if (i == 0)
        queue[0] = e;  // 第一个元素直接放入堆顶
    else
        siftUp(i, e);  // 从最后一个位置开始上浮
    return true;
}
```

#### siftUp（上浮）的核心逻辑

```java
private void siftUpComparable(int k, E x) {
    Comparable<? super E> key = (Comparable<? super E>) x;
    while (k > 0) {
        int parent = (k - 1) >>> 1;           // 父节点位置
        Object e = queue[parent];
        if (key.compareTo((E) e) >= 0)        // 已经满足堆性质
            break;
        queue[k] = e;                          // 父节点下移
        k = parent;
    }
    queue[k] = key;  // 找到最终位置放入
}
```

**直观理解**：新元素放到数组末尾，然后不断与父节点比较。如果比父节点小，就与父节点交换位置，直到满足堆性质。

### 3.4 移除队首：poll()

```java
public E poll() {
    if (size == 0)
        return null;
    int s = --size;
    modCount++;
    E result = (E) queue[0];        // 取出堆顶
    E x = (E) queue[s];             // 最后一个元素
    queue[s] = null;                // 置空
    if (s != 0)
        siftDown(0, x);             // 从堆顶开始下沉
    return result;
}
```

#### siftDown（下沉）的核心逻辑

```java
private void siftDownComparable(int k, E x) {
    Comparable<? super E> key = (Comparable<? super E>)x;
    int half = size >>> 1;  // 叶子节点的起始位置
    while (k < half) {
        int child = (k << 1) + 1;     // 左子节点
        Object c = queue[child];
        int right = child + 1;
        // 找出左右子节点中较小的那个
        if (right < size &&
            ((Comparable<? super E>) c).compareTo((E) queue[right]) > 0)
            c = queue[child = right];
        if (key.compareTo((E) c) <= 0)  // 已满足堆性质
            break;
        queue[k] = c;  // 子节点上移
        k = child;
    }
    queue[k] = key;
}
```

**直观理解**：把最后一个元素放到堆顶，然后与两个子节点中较小的那个交换，不断下沉到合适位置。

### 3.5 扩容机制

```java
private void grow(int minCapacity) {
    int oldCapacity = queue.length;
    // 如果 oldCapacity < 64，双倍扩容；否则 50% 扩容
    int newCapacity = oldCapacity + ((oldCapacity < 64) ?
                                     (oldCapacity + 2) :
                                     (oldCapacity >> 1));
    // 检查是否溢出
    if (newCapacity - MAX_ARRAY_SIZE > 0)
        newCapacity = hugeCapacity(minCapacity);
    queue = Arrays.copyOf(queue, newCapacity);
}
```

这个扩容策略借鉴了 `ArrayList` 的思路——小容量时激进扩容减少扩容次数，大容量时保守扩容节省内存。

### 3.6 删除任意元素：remove()

```java
private E removeAt(int i) {
    modCount++;
    int s = --size;
    if (s == i)
        queue[i] = null;  // 删除的是最后一个元素
    else {
        E moved = (E) queue[s];
        queue[s] = null;
        siftDown(i, moved);  // 先尝试下沉
        if (queue[i] == moved) {  // 如果没有下沉
            siftUp(i, moved);     // 尝试上浮
        }
    }
}
```

注意这里的特殊处理：将尾部元素移到删除位置后，**先下沉，如果没有下沉再上浮**。这是因为尾部元素可能比子节点大（下沉），也可能比父节点小（上浮），所以需要双向调整。

### 3.7 建堆过程：heapify()

```java
private void heapify() {
    // 从最后一个非叶子节点开始，逐个下沉
    for (int i = (size >>> 1) - 1; i >= 0; i--)
        siftDown(i, (E) queue[i]);
}
```

当从一个普通集合构建 PriorityQueue 时（如 `new PriorityQueue<>(collection)`），调用 `initFromCollection()` 后执行 `heapify()`。时间复杂度为 **O(n)**，而非 O(n log n)。这用的是 Floyd 建堆算法，效率更高。

---

## 四、PriorityBlockingQueue 源码分析

### 4.1 线程安全版本

```java
public class PriorityBlockingQueue<E> extends AbstractQueue<E>
    implements BlockingQueue<E>, java.io.Serializable {

    // 使用同一个数据结构
    private transient Object[] queue;

    // 使用 ReentrantLock 保证线程安全
    private final ReentrantLock lock = new ReentrantLock();

    // 条件变量：队列非空时通知
    private final Condition notEmpty = lock.newCondition();

    // 自旋锁，用于扩容时的并发控制
    private transient volatile int allocationSpinLock;
}
```

### 4.2 无界队列特性

`PriorityBlockingQueue` 是**无界队列**，理论上可以无限添加元素。因此：

- **put() 不会阻塞**，始终返回 true
- **offer(e, timeout, unit) 超时参数被忽略**

这一点与 `ArrayBlockingQueue` 和 `LinkedBlockingQueue` 不同。

### 4.3 插入操作

```java
public boolean offer(E e) {
    if (e == null)
        throw new NullPointerException();
    final ReentrantLock lock = this.lock;
    lock.lock();
    int n, cap;
    Object[] array;
    while ((n = size) >= (cap = (array = queue).length))
        tryGrow(array, cap);  // 扩容
    try {
        Comparator<? super E> cmp = comparator;
        if (cmp == null)
            siftUpComparable(n, e, array);
        else
            siftUpUsingComparator(n, e, array, cmp);
        size = n + 1;
        notEmpty.signal();  // 通知等待获取的线程
    } finally {
        lock.unlock();
    }
    return true;
}
```

### 4.4 扩容与自旋锁

```java
private void tryGrow(Object[] array, int oldCap) {
    lock.unlock();  // 释放锁，让其他线程可以继续读
    Object[] newArray = null;
    if (allocationSpinLock == 0 &&
        UNSAFE.compareAndSwapInt(this, allocationSpinLockOffset,
                                 0, 1)) {  // CAS 获取扩容权
        try {
            int newCap = oldCap + ((oldCap < 64) ?
                                   (oldCap + 2) :
                                   (oldCap >> 1));
            if (newCap - MAX_ARRAY_SIZE > 0) {
                int minCap = oldCap + 1;
                if (minCap < 0 || minCap > MAX_ARRAY_SIZE)
                    throw new OutOfMemoryError();
                newCap = MAX_ARRAY_SIZE;
            }
            if (newCap > oldCap && queue == array)
                newArray = new Object[newCap];
        } finally {
            allocationSpinLock = 0;
        }
    }
    if (newArray == null)  // 其他线程正在扩容，让出 CPU
        Thread.yield();
    lock.lock();  // 重新加锁
    if (newArray != null && queue == array) {
        queue = newArray;
        System.arraycopy(array, 0, newArray, 0, oldCap);
    }
}
```

这个设计非常精巧：
1. **扩容时不持有锁**，让其他线程可以继续 peek() 和 poll()
2. 使用 **CAS + allocationSpinLock** 保证只有一个线程进行扩容
3. 扩容失败的线程通过 `Thread.yield()` 自旋等待
4. 扩容完成后重新加锁，拷贝数据

这种 **"读锁分离"** 的设计思路值得借鉴。

### 4.5 取出操作：take()

```java
public E take() throws InterruptedException {
    final ReentrantLock lock = this.lock;
    lock.lockInterruptibly();
    E result;
    try {
        while ((result = extract()) == null)
            notEmpty.await();  // 队列为空时阻塞等待
    } finally {
        lock.unlock();
    }
    return result;
}

public E poll() {
    final ReentrantLock lock = this.lock;
    lock.lock();
    try {
        return extract();
    } finally {
        lock.unlock();
    }
}
```

`take()` 会在队列为空时阻塞，直到有元素被插入并调用 `notEmpty.signal()`。

### 4.6 drainTo() 批量取出

```java
public int drainTo(Collection<? super E> c, int maxElements) {
    if (c == null)
        throw new NullPointerException();
    if (c == this)
        throw new IllegalArgumentException();
    if (maxElements <= 0)
        return 0;
    final ReentrantLock lock = this.lock;
    lock.lock();
    try {
        int n = Math.min(size, maxElements);
        for (int i = 0; i < n; i++) {
            c.add((E) queue[0]);   // 添加到目标集合
            removeAt(0);           // 移除堆顶
        }
        return n;
    } finally {
        lock.unlock();
    }
}
```

**注意**：`drainTo()` 提取的元素是无序的！因为每次取出堆顶后堆结构会变化，以取出顺序并非按优先级排列。如果需要有序提取，应该单次逐个 poll()。

---

## 五、迭代器与遍历

### 5.1 PriorityQueue 的迭代器

```java
private final class Itr implements Iterator<E> {
    private int cursor;           // 下一个返回元素的下标
    private int lastRet = -1;     // 上一个返回元素的下标
    private int expectedModCount = modCount;
    
    // forEachRemaining 优化：使用临时数组快照
    public void forEachRemaining(Consumer<? super E> action) {
        // 直接将 queue 数组中的元素（0..size-1）遍历
        // 注意：遍历顺序是数组顺序，不是优先级顺序！
    }
}
```

**重要：** `PriorityQueue` 的迭代器遍历顺序**不是优先级顺序**，而是底层数组的存放顺序。如果需要按优先级遍历，应该循环使用 `poll()`。

### 5.2 为什么迭代器不保证有序？

因为迭代器遍历的是底层数组 `queue[0..size-1]`。二叉堆的数组存储虽然满足堆性质，但同一层级的元素之间没有顺序关系，所以数组顺序并非完全有序。

```java
PriorityQueue<Integer> pq = new PriorityQueue<>();
pq.addAll(Arrays.asList(3, 1, 4, 1, 5, 9, 2, 6));

// 遍历结果可能是 [1, 1, 2, 3, 5, 9, 4, 6] —— 不是完全有序的！
for (int x : pq) {
    System.out.print(x + " ");
}
// 正确获取有序元素的方式：
while (!pq.isEmpty()) {
    System.out.print(pq.poll() + " ");  // 输出: 1 1 2 3 4 5 6 9
}
```

---

## 六、实际使用场景

### 6.1 定时任务调度

```java
class DelayedTask implements Delayed {
    private final String name;
    private final long executeTime;
    
    public DelayedTask(String name, long delay, TimeUnit unit) {
        this.name = name;
        this.executeTime = System.currentTimeMillis() + unit.toMillis(delay);
    }
    
    @Override
    public long getDelay(TimeUnit unit) {
        return unit.convert(executeTime - System.currentTimeMillis(), TimeUnit.MILLISECONDS);
    }
    
    @Override
    public int compareTo(Delayed o) {
        return Long.compare(this.executeTime, ((DelayedTask) o).executeTime);
    }
}
```

虽然 Java 提供了 `DelayQueue` 专门做这件事，但理解其底层依赖于 `PriorityQueue` 更为关键。

### 6.2 海量数据 Top-K

```java
// 求 10 亿个数字中最大的 100 个
public List<Integer> topK(int[] nums, int k) {
    // 使用最小堆，堆顶就是当前第 K 大的元素
    PriorityQueue<Integer> minHeap = new PriorityQueue<>(k);
    
    for (int num : nums) {
        if (minHeap.size() < k) {
            minHeap.offer(num);
        } else if (num > minHeap.peek()) {
            minHeap.poll();
            minHeap.offer(num);
        }
    }
    
    return new ArrayList<>(minHeap);
}
```

时间复杂度 O(n log k)，空间复杂度 O(k)，适合海量数据场景。

### 6.3 合并 K 个有序链表

```java
public ListNode mergeKLists(ListNode[] lists) {
    PriorityQueue<ListNode> pq = new PriorityQueue<>(
        (a, b) -> a.val - b.val  // 按节点值排序
    );
    
    for (ListNode node : lists) {
        if (node != null) pq.offer(node);
    }
    
    ListNode dummy = new ListNode(0);
    ListNode cur = dummy;
    
    while (!pq.isEmpty()) {
        ListNode node = pq.poll();
        cur.next = node;
        cur = cur.next;
        if (node.next != null) {
            pq.offer(node.next);
        }
    }
    
    return dummy.next;
}
```

这是面试高频题，利用优先队列可以将时间复杂度控制在 O(n log k)。

---

## 七、面试常见问题

### Q1：PriorityQueue 是有序的吗？

**答**：内部不是完全有序的，只有堆顶是最大/最小元素。但通过反复 poll() 可以得到有序序列（堆排序）。

### Q2：PriorityQueue 如何保证线程安全？

**答**：本身非线程安全。线程安全版本使用 `PriorityBlockingQueue`，通过 `ReentrantLock` + `Condition` 实现并发控制。

### Q3：PriorityBlockingQueue 的 put() 会阻塞吗？

**答**：不会。`PriorityBlockingQueue` 是无界队列，`put()` 内部调用了 `offer()`，始终返回 true。

### Q4：PriorityQueue 允许 null 吗？

**答**：不允许。null 无法进行比较，插入 null 会抛出 NullPointerException。

### Q5：PriorityQueue 扩容策略是什么？

**答**：容量 < 64 时双倍扩容，≥ 64 时扩容 50%（与 ArrayList 类似）。

### Q6：PriorityBlockingQueue 扩容时如何保证并发安全？

**答**：使用自旋锁 + CAS 控制只让一个线程扩容，扩容期间释放主锁，其他线程可以继续读操作。

### Q7：PriorityQueue 的迭代器保证有序吗？

**答**：不保证。迭代器按底层数组顺序遍历，不是优先级顺序。

### Q8：建堆的时间复杂度是多少？

**答**：通过 `heapify()` 建堆是 O(n)，调用 n 次 `offer()` 建堆是 O(n log n)。

---

## 八、性能对比总结

| 特性 | PriorityQueue | PriorityBlockingQueue |
|------|:------------:|:--------------------:|
| 线程安全 | ❌ | ✅ |
| 允许 null | ❌ | ❌ |
| 有界/无界 | 有界（可扩容） | 无界 |
| put() 阻塞 | — | 不会阻塞 |
| take() 阻塞 | — | 队列空时阻塞 |
| 底层数据结构 | 二叉堆 Object[] | 二叉堆 Object[] |
| 迭代器 fail-fast | ✅ | ✅（快照方式） |
| 扩容策略 | 双倍→50% | 双倍→50% |
| 扩容时并发 | 无需考虑 | CAS + 自旋锁 |

---

## 九、总结

PriorityQueue 和 PriorityBlockingQueue 是 Java 集合框架中基于堆结构的高效实现。理解它们的核心要点：

1. **底层是二叉堆（小顶堆）**，使用数组存储
2. **siftUp（上浮）和 siftDown（下沉）** 是核心操作
3. **扩容机制**借鉴 ArrayList
4. **PriorityBlockingQueue 的并发控制**采用 ReentrantLock + CAS 分离扩容与读操作
5. **迭代器不保证有序**，需用 poll() 获取有序元素

掌握这些原理，无论是应付面试还是实际开发中做选型和排坑，都会有帮助。
