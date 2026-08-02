---
title: 【Java集合】ArrayDeque 源码深度解析：循环数组双端队列的极致性能之道
date: 2026-08-02 08:00:00
tags:
  - Java
  - 集合
  - 源码
  - 面试
categories:
  - Java
  - 集合源码
author: 东哥
---

# 【Java集合】ArrayDeque 源码深度解析：循环数组双端队列的极致性能之道

## 面试官：说说 ArrayDeque 的实现原理？为什么官方推荐用它替代 Stack？

在 Java 集合框架中，`ArrayDeque` 是一个被严重低估的类。它是 `Deque` 接口的数组实现，用**循环数组**（Circular Array）实现了双端队列，两端插入、删除都是 **O(1)** 时间复杂度的极致性能。Java 官方文档甚至明确建议：**"当需要栈（Stack）时，应该优先使用 ArrayDeque 而不是 Stack；当需要队列时，优先使用 ArrayDeque 而不是 LinkedList。"**

本篇文章我们从源码层面彻底解剖 ArrayDeque：循环数组如何工作？扩容如何发生？为什么它比 LinkedList 快？以及它有哪些隐藏的坑。

## 一、ArrayDeque 的类图与继承体系

```java
public class ArrayDeque<E> extends AbstractCollection<E>
                           implements Deque<E>, Cloneable, java.io.Serializable
```

关键点：

- 实现了 `Deque<E>` 接口，因此同时具备**双端队列**、**栈**、**队列**三种语义；
- 底层是 `Object[]` 数组，且**不允许存储 null 元素**（这是与 LinkedList 的重要区别之一）；
- **不是线程安全的**，多线程场景需要外部同步或使用 `ConcurrentLinkedDeque`；
- 不支持按索引随机访问（没有 `get(index)`），迭代时也不保证元素的稳定性（因为扩容会搬移数据）。

## 二、核心数据结构：循环数组

先看字段定义：

```java
transient Object[] elements;  // 存储元素的数组，长度永远是 2 的幂
transient int head;           // 队头索引（指向第一个有效元素）
transient int tail;           // 队尾索引（指向下一个可插入的位置，即"尾后"）
```

这里有两个核心设计：

### 1. 数组长度永远是 2 的幂

```java
private void allocateElements(int numElements) {
    int initialCapacity = 8;
    if (numElements >= initialCapacity) {
        initialCapacity = numElements;
        initialCapacity |= (initialCapacity >>>  1);
        initialCapacity |= (initialCapacity >>>  2);
        initialCapacity |= (initialCapacity >>>  4);
        initialCapacity |= (initialCapacity >>>  8);
        initialCapacity |= (initialCapacity >>> 16);
        initialCapacity++;
    }
    elements = new Object[initialCapacity];
}
```

这段代码通过 5 次无符号右移 + 或运算，把任意容量提升到**最近的 2 的幂**（类似 HashMap 的 `tableSizeFor`）。为什么必须是 2 的幂？因为这样可以用 **`& (length - 1)` 位运算替代 `% length` 取模**，性能更高：

```java
// 队尾入队：tail 后移一位，越界则回绕到 0
elements[tail] = e;
tail = (tail + 1) & (elements.length - 1);
```

当 `tail` 到达数组末尾时，`(tail + 1) & (length - 1)` 会正确回绕到 0，形成逻辑上的"环"。

### 2. 循环数组的判空与判满

- **判空**：`head == tail`（两者相遇即空）；
- **判满**：`(tail + 1) & (length - 1) == head`，即**队尾下一个位置是 head 时**认为已满。

注意：ArrayDeque **故意牺牲一个数组槽位**，用 `tail` 永远指向"下一个空位"来区分空和满，这也是它数组长度总是 `元素个数 + 1` 的原因。我们来看扩容逻辑：

```java
private void doubleCapacity() {
    assert head == tail;
    int p = head;
    int n = elements.length;
    int r = n - p; // head 右边元素个数
    int newCapacity = n << 1;
    if (newCapacity < 0)
        throw new IllegalStateException("Sorry, deque too big");
    Object[] a = new Object[newCapacity];
    // 把 [head, n) 的元素拷贝到新数组头部
    System.arraycopy(elements, p, a, 0, r);
    // 把 [0, head) 的元素接在后面
    System.arraycopy(elements, 0, a, r, p);
    elements = a;
    head = 0;
    tail = n;
}
```

扩容时**一次性把环"拉直"**：先拷贝 head 右侧部分，再拷贝 head 左侧部分，最后 `head = 0`、`tail = n`（旧长度），新数组容量翻倍。这个 O(n) 拷贝是 ArrayDeque 唯一的重操作，但均摊下来每次 add 依然是 **O(1)**（均摊分析）。

## 三、核心方法源码剖析

### 1. addFirst / addLast（入队）

```java
public void addFirst(E e) {
    if (e == null)
        throw new NullPointerException();
    elements[head = (head - 1) & (elements.length - 1)] = e;
    if (head == tail)
        doubleCapacity();
}

public void addLast(E e) {
    if (e == null)
        throw new NullPointerException();
    elements[tail] = e;
    tail = (tail + 1) & (elements.length - 1);
    if (head == tail)
        doubleCapacity();
}
```

- `addFirst`：head **先左移一位**（回绕）再写入，然后检查是否与 tail 相遇以决定是否扩容；
- `addLast`：先写入当前 tail 位置，tail 再右移回绕。

两个方法的均摊复杂度都是 O(1)，且**没有数组拷贝**（除非扩容），这正是"两端操作都高效"的秘密。

### 2. pollFirst / pollLast（出队）

```java
public E pollFirst() {
    final Object[] elements = this.elements;
    final int h = head;
    @SuppressWarnings("unchecked")
    E result = (E) elements[h];
    if (result != null) {
        elements[h] = null; // 置空，帮助 GC
        head = (h + 1) & (elements.length - 1);
    }
    return result;
}

public E pollLast() {
    final Object[] elements = this.elements;
    final int t = (tail - 1) & (elements.length - 1);
    @SuppressWarnings("unchecked")
    E result = (E) elements[t];
    if (result != null) {
        elements[t] = null; // 置空，帮助 GC
        tail = t;
    }
    return result;
}
```

出队操作也是纯 O(1)，并且**及时把出队位置置为 null**，避免对象滞留造成内存泄漏。

### 3. 作为栈使用：push / pop

```java
public void push(E e) { addFirst(e); }
public E pop() { return removeFirst(); }
```

`push` 走 `addFirst`、`pop` 走 `removeFirst`，完全复用双端队列能力。这就是官方推荐用 ArrayDeque 替代 Stack 的原因：

| 对比项 | Stack（继承 Vector） | ArrayDeque |
|--------|---------------------|------------|
| 底层结构 | 动态数组，**所有方法带 synchronized** | 循环数组，无锁 |
| 线程安全 | 安全但性能差（全方法加锁） | 不安全（需要时自己加锁） |
| 栈操作复杂度 | O(1)（摊销），但有锁开销 | O(1)（摊销），无锁 |
| 是否允许 null | 允许 | **不允许** |
| 官方态度 | 已过时（legacy） | 明确推荐替代品 |

## 四、ArrayDeque vs LinkedList：为什么 ArrayDeque 更快？

这是面试高频题。两者都实现了 `Deque`，但底层天差地别：

| 维度 | ArrayDeque | LinkedList |
|------|-----------|------------|
| 底层结构 | 循环数组（连续内存） | 双向链表（节点分散） |
| 内存占用 | 数组槽位 + 少量空槽（预留 1 位） | 每个元素额外 24+ 字节（prev/next 指针 + 对象头） |
| 缓存友好性 | **极高**（连续内存，CPU 缓存命中率高） | 差（节点随机散布，频繁 cache miss） |
| 随机访问 | 不支持 | 不支持（get 需 O(n) 遍历） |
| 中间插入/删除 | 不支持（只有两端 O(1)） | O(n) 找到位置后 O(1) 改指针（但查找是 O(n)） |
| 允许 null | 否 | 是 |
| 迭代器 | 快速失败（fail-fast） | 快速失败 |

**性能真相**：即使理论复杂度相同，ArrayDeque 在大量入队出队场景下通常比 LinkedList 快 2~5 倍。原因是**内存局部性**——ArrayDeque 的数组是连续内存，遍历时 CPU 预取（prefetch）友好；而 LinkedList 的每个节点都是独立堆对象，访问时频繁触发缓存未命中（cache miss），还要额外解引用两个指针。在 JMH 基准测试中，`ArrayDeque.addLast + pollFirst` 的吞吐量显著优于 LinkedList。

> 面试加分回答："LinkedList 真正的优势是**在已知节点引用的情况下**做 O(1) 的中间插入/删除（比如迭代器场景），以及作为 List 支持索引遍历；但如果只是做队列/栈，ArrayDeque 在时间、空间、缓存三方面全面碾压。"

## 五、ArrayDeque 的隐藏陷阱

### 陷阱 1：不允许 null

```java
ArrayDeque<String> deque = new ArrayDeque<>();
deque.addLast(null); // 抛出 NullPointerException！
```

原因：源码用 `elements[tail] == null` 判断"该位置无元素"（出队、判空都依赖 null 哨兵），所以 null 会被当作"空槽"处理，直接禁止。

### 陷阱 2：迭代时不保证元素顺序稳定

扩容会搬移元素，如果**在迭代过程中进行 add 操作**（即使没触发扩容），迭代器也可能因为结构变化抛 `ConcurrentModificationException`；而即便不抛异常，扩容后 head 归零，之前拿到的迭代顺序也会变化。**迭代期间不要修改 deque**。

### 陷阱 3：容量上限

扩容用 `n << 1`，当容量超过 `1 << 30` 时可能溢出为负数，抛出 `IllegalStateException("Sorry, deque too big")`。实际业务几乎不可能触达，但要知道有这个边界。

### 陷阱 4：不是线程安全的

单线程下 ArrayDeque 性能极佳；多线程下需要 `ConcurrentLinkedDeque`（无界、无锁）或 `LinkedBlockingDeque`（有界、可阻塞），**不要**自己用 synchronized 包一层 ArrayDeque 做有界队列——有界阻塞队列场景请直接用 `ArrayBlockingQueue`。

## 六、最佳实践与典型应用

### 1. 用 ArrayDeque 实现"滑动窗口"极值

LeetCode 经典题（239. 滑动窗口最大值）的标准解法就是"单调双端队列"：

```java
public int[] maxSlidingWindow(int[] nums, int k) {
    int n = nums.length;
    int[] ans = new int[n - k + 1];
    // 双端队列存下标，队头到队尾单调递减
    ArrayDeque<Integer> deque = new ArrayDeque<>();
    for (int i = 0; i < n; i++) {
        // 1. 队头滑出窗口
        while (!deque.isEmpty() && deque.peekFirst() <= i - k) {
            deque.pollFirst();
        }
        // 2. 保持单调：移除所有比当前元素小的队尾
        while (!deque.isEmpty() && nums[deque.peekLast()] <= nums[i]) {
            deque.pollLast();
        }
        // 3. 入队
        deque.addLast(i);
        // 4. 记录窗口最大值
        if (i >= k - 1) {
            ans[i - k + 1] = nums[deque.peekFirst()];
        }
    }
    return ans;
}
```

每个元素最多入队、出队各一次，整体 **O(n)**，且两端操作全是 O(1)，用 ArrayDeque 是完美匹配。

### 2. 手写一个高性能"最近使用"缓存（LRU 简化版）

```java
public class SimpleLRUCache<K, V> {
    private final int capacity;
    private final ArrayDeque<K> order = new ArrayDeque<>();
    private final Map<K, V> map = new HashMap<>();

    public SimpleLRUCache(int capacity) { this.capacity = capacity; }

    public synchronized V get(K key) {
        V v = map.get(key);
        if (v != null) {
            order.remove(key);        // 注意：remove 是 O(n)，生产请用 LinkedHashMap
            order.addFirst(key);
        }
        return v;
    }

    public synchronized void put(K key, V value) {
        if (map.containsKey(key)) {
            order.remove(key);
        } else if (map.size() >= capacity) {
            K oldest = order.pollLast();
            if (oldest != null) map.remove(oldest);
        }
        map.put(key, value);
        order.addFirst(key);
    }
}
```

> 提示：这里 `order.remove(key)` 是 O(n)，只是演示 ArrayDeque 的栈/队列语义。生产环境实现 LRU 请直接用 `LinkedHashMap` 的 `accessOrder` 模式或 Caffeine。

### 3. 回溯算法 / DFS 的非递归改写

用 ArrayDeque 作为显式栈实现树的先序遍历，避免递归爆栈：

```java
public List<Integer> preorder(TreeNode root) {
    List<Integer> res = new ArrayList<>();
    ArrayDeque<TreeNode> stack = new ArrayDeque<>();
    if (root != null) stack.push(root);
    while (!stack.isEmpty()) {
        TreeNode node = stack.pop();
        res.add(node.val);
        if (node.right != null) stack.push(node.right);
        if (node.left != null) stack.push(node.left);
    }
    return res;
}
```

## 七、面试官追问环节

**Q1：ArrayDeque 为什么容量必须是 2 的幂？**
答：为了用 `& (length - 1)` 位运算替代 `% length` 取模做索引回绕。位运算比取模快一个数量级，且 `(tail + 1) & (length - 1)` 在 tail 到达末尾时天然回绕到 0，不需要 if 判断。这是循环数组实现的标准优化手法。

**Q2：ArrayDeque 扩容后元素顺序会变吗？为什么？**
答：会变。扩容时先把 head 右侧的元素拷到新数组头部，再把 head 左侧的接在后面，然后 head 归零。**逻辑顺序（队头到队尾）不变**，但物理下标全部重排了。这也是迭代器在扩容后失效、且扩容前获取的迭代器顺序可能不一致的原因。

**Q3：为什么 ArrayDeque 不允许存 null？**
答：因为内部用 null 作为"空槽位"哨兵。判空条件是 `head == tail`，而出队、入队依赖检查 `elements[head] == null` 判断位置是否有元素。如果允许存 null，就无法区分"空槽"和"真实 null 元素"。

**Q4：ArrayDeque 和 LinkedList 都用 Deque 接口，什么时候用 LinkedList？**
答：需要**在链表中间插入/删除**且持有节点引用时（如 LRU 的手写实现、某些图算法）；需要同时作为 List 使用时；或者需要允许 null 时。其余队列/栈场景一律 ArrayDeque。

**Q5：ArrayDeque 是线程安全的吗？如何实现线程安全的双端队列？**
答：不是。线程安全的选择：`ConcurrentLinkedDeque`（无界无锁，基于 CAS）、`LinkedBlockingDeque`（有界可阻塞），或者 `Collections.synchronizedDeque(new ArrayDeque<>())` 包一层（简单但并发度低）。

## 八、总结

ArrayDeque 是 Java 集合框架中被低估的"性能之王"：

- **循环数组 + 2 的幂容量 + 位运算回绕**，两端操作均摊 O(1)；
- **连续内存**带来极佳的 CPU 缓存友好性，实际性能碾压 LinkedList；
- 一个类同时提供**栈、队列、双端队列**三种语义，是官方钦定的 Stack/LinkedList 替代品；
- 使用时注意：不允许 null、非线程安全、迭代中不可修改。

理解了循环数组的精妙设计，你不仅掌握了 ArrayDeque，更理解了"以空间换时间、位运算优化、均摊分析"这些贯穿 Java 集合源码的设计思想——这正是面试官想听到的深度。
