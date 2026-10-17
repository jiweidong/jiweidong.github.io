---
title: 【Java 深挖】集合选型决策树：List/Set/Map/Queue 的性能、内存与线程安全全景
date: 2026-10-17 08:10:00
tags:
  - Java
  - 集合
  - 数据结构
  - 性能优化
  - 面试
categories:
  - Java 深挖
author: 东哥
---

# 【Java 深挖】集合选型决策树：List/Set/Map/Queue 的性能、内存与线程安全全景

## 前言

写 Java 的人每天都用集合，但**「这个场景该用哪个集合」**答得清楚的人不多。多数人习惯性 `new ArrayList<>()` / `new HashMap<>()`，直到某天：一个 `List.contains()` 放在循环里跑成 O(n²)、一个 `HashMap` 被并发写坏成死循环（JDK 7）、一个 `ArrayList` 在中间插入导致大量数组拷贝。

集合选型不是背 API，而是**在「操作模式 + 数据规模 + 并发要求 + 内存预算」四个维度上做取舍**。本文给出一棵可落地的决策树，配上复杂度对比表、内存开销分析和并发场景避坑。

---

## 一、决策树：先问自己四个问题

```
需要键值对吗？
├─ 是 → Map
│   ├─ 需要排序？ → TreeMap（键有序）/ LinkedHashMap（插入序）
│   ├─ 高并发？   → ConcurrentHashMap
│   └─ 否则       → HashMap
└─ 否 → 需要去重吗？
    ├─ 是 → Set
    │   ├─ 需要排序？ → TreeSet
    │   ├─ 需要插入序？→ LinkedHashSet
    │   └─ 否则 → HashSet
    └─ 否 → 需要按索引随机访问吗？
        ├─ 是 → List
        │   ├─ 读多写少、尾部追加 → ArrayList
        │   ├─ 频繁头插/头删（当队列用）→ ArrayDeque
        │   └─ 频繁中间插入删除（且有迭代器定位）→ LinkedList（慎用）
        └─ 否 → 队列/栈
            ├─ FIFO → ArrayDeque（首选）/ LinkedList
            └─ 优先级 → PriorityQueue
```

**一句话原则**：**默认用 `ArrayList` + `HashMap` + `HashSet` + `ArrayDeque`**，只有明确证据表明需要其他特性时才换。

---

## 二、复杂度与特性对比表

| 集合 | 随机访问 | 尾部插入 | 中间插删 | 查找 | 去重 | 有序 | 线程安全 |
|---|---|---|---|---|---|---|---|
| `ArrayList` | O(1) | 摊销 O(1) | O(n) | O(n) | 否 | 插入序 | 否 |
| `LinkedList` | O(n) | O(1) | O(1)* | O(n) | 否 | 插入序 | 否 |
| `ArrayDeque` | O(n) | 摊销 O(1) | — | O(n) | 否 | 插入序 | 否 |
| `HashSet` | — | 摊销 O(1) | — | O(1) | 是 | 无序 | 否 |
| `LinkedHashSet` | — | 摊销 O(1) | — | O(1) | 是 | 插入序 | 否 |
| `TreeSet` | — | O(log n) | O(log n) | O(log n) | 是 | 排序 | 否 |
| `HashMap` | — | 摊销 O(1) | — | O(1) | 键唯一 | 无序 | 否 |
| `TreeMap` | — | O(log n) | O(log n) | O(log n) | 键唯一 | 键排序 | 否 |
| `ConcurrentHashMap` | — | 摊销 O(1) | — | O(1) | 键唯一 | 无序 | 是 |
| `CopyOnWriteArrayList` | O(1) | O(n)（复制） | O(n) | O(n) | 否 | 插入序 | 是（读无锁） |
| `PriorityQueue` | — | O(log n) | — | O(n) 查顶 O(1) | 否 | 堆序 | 否 |

\* `LinkedList` 中间插删「O(1)」的**前提是你已经持有目标节点（迭代器位置）**；若靠索引定位，定位本身是 O(n)。

---

## 三、List 的真相：`LinkedList` 几乎总是错的

很多人以为「链表中间插入快，所以用 `LinkedList`」。**在生产里这个结论基本不成立**，原因：

1. **CPU 缓存不友好**：`ArrayList` 内存连续，遍历/访问命中缓存行；`LinkedList` 每个节点都是独立对象，指针跳转 cache miss 严重。
2. **每节点开销大**：`LinkedList.Node` 含 `prev`/`next` 两个引用（各 8 字节 + 对象头），一个元素内存开销 ≈ **40 字节**，而 `ArrayList` 里一个引用仅 8 字节（默认压缩指针）。
3. **中间插删通常要自带定位**：业务里常见的是「按索引删除」，此时先 O(n) 定位，优势全无。

实测（百万级元素，频繁随机读 + 尾部追加）：`ArrayList` 往往比 `LinkedList` 快**数倍到数十倍**。

```java
// ❌ 反模式：用 LinkedList 当「中间插入快」的借口
List<Integer> list = new LinkedList<>();  // 大多数场景应换成 ArrayList

// ✅ 需要当作栈/双端队列时，用 ArrayDeque
Deque<Integer> stack = new ArrayDeque<>();
```

**`LinkedList` 真正合适的场景**：实现 `Deque`/`Queue` 且不需要随机访问时——但 `ArrayDeque` 通常更快，所以 `LinkedList` 的生存空间被进一步挤压。**JDK 官方注释都建议优先用 `ArrayDeque`。**

**`ArrayList` 扩容**：默认容量 10，扩容为 `oldCap + (oldCap >> 1)`（1.5 倍）。已知大小时**务必指定初始容量**：

```java
// 已知要放 10000 个元素
List<X> list = new ArrayList<>(10000);   // 避免多次扩容 + 数组拷贝
```

---

## 四、Set 的选型：去重 + 顺带排序需求

- **只去重**：`HashSet`。
- **去重 + 保留插入顺序**：`LinkedHashSet`（内部是 `LinkedHashMap`，多维护一条双向链表，内存开销略大）。
- **去重 + 排序**：`TreeSet`（基于红黑树，增删查 O(log n)）。

**`HashSet` 去重依赖 `equals`/`hashCode`**：自定义对象忘了重写这两个方法，去重直接失效（两个「相等」对象被当成不同元素）。

```java
// 去重场景的经典坑
class User { String id; /* 忘了 equals/hashCode */ }
Set<User> set = new HashSet<>();
set.add(new User("1"));
set.add(new User("1"));   // 结果 size = 2，去重失败
```

> 用 `record`（JDK 16+）或 Lombok `@EqualsAndHashCode` 自动生成，是最省心的做法。

---

## 五、Map 的选型：从 `HashMap` 到并发

### 5.1 `HashMap` 关键点

- 默认容量 16，负载因子 0.75。
- JDK 8 起：拉链 + 红黑树（单桶链表长度 ≥ 8 且容量 ≥ 64 时树化），把最坏查找从 O(n) 降到 O(log n)。
- **扩容是 2 倍**，rehash 时 JDK 8 用高低位拆分避免 JDK 7 的并发死循环问题。

**指定初始容量**（避免扩容）：

```java
// 预计放 1000 个，按 0.75 负载算 → 1000 / 0.75 ≈ 1334，向上取 2 的幂 = 2048
Map<String, X> map = new HashMap<>(2048);
```

> 严格公式：`initialCapacity = (int)(expectedSize / 0.75f) + 1`，`HashMap` 内部会再取 2 的幂。

### 5.2 并发场景：`ConcurrentHashMap` 是唯一正解

```java
// ❌ 各种错误做法
Map<String, X> bad1 = new HashMap<>();               // 并发写 → 数据丢失/结构损坏
Map<String, X> bad2 = Collections.synchronizedMap(new HashMap<>());  // 全局锁，性能差

// ✅
Map<String, X> good = new ConcurrentHashMap<>();
```

`ConcurrentHashMap` 演进：
- JDK 7：**分段锁**（Segment，默认 16 段），并发度 16。
- JDK 8：**CAS + synchronized 锁单个桶**，并发度更高，扩容也支持多线程协助。

**注意 `ConcurrentHashMap` 的复合操作不是原子的**：

```java
// ❌ 非原子：check-then-act
if (!map.containsKey(k)) map.put(k, v);

// ✅ JDK 8+ 原子 API
map.computeIfAbsent(k, key -> createValue(key));
map.merge(k, 1, Integer::sum);          // 计数
map.compute(k, (key, old) -> old == null ? v : old + v);
```

### 5.3 插入顺序 / 访问顺序：`LinkedHashMap`

```java
// 插入顺序
Map<String, X> m1 = new LinkedHashMap<>();

// 访问顺序 + LRU（accessOrder = true）
Map<String, X> lru = new LinkedHashMap<>(16, 0.75f, true) {
    @Override
    protected boolean removeEldestEntry(Map.Entry<String, X> eldest) {
        return size() > 1000;   // 超 1000 淘汰最久未访问
    }
};
```

### 5.4 排序 Map：`TreeMap`

- 键有序，支持范围查询：`firstKey`、`lastKey`、`subMap`、`headMap`、`tailMap`、`floorKey`、`ceilingKey`。
- 典型场景：**按时间窗口聚合**、排行榜、区间统计。

```java
TreeMap<Long, Integer> byTime = new TreeMap<>();
byTime.subMap(startTs, true, endTs, true)   // 取时间区间
      .values().stream().mapToInt(Integer::intValue).sum();
```

---

## 六、Queue：`ArrayDeque` 优先

| 需求 | 首选 | 说明 |
|---|---|---|
| 普通 FIFO 队列（单线程） | `ArrayDeque` | 数组实现，比 `LinkedList` 快 |
| 栈（LIFO） | `ArrayDeque` | 官方推荐替代 `Stack` |
| 优先级队列 | `PriorityQueue` | 二叉堆，取顶 O(1) |
| 阻塞队列（生产消费） | `ArrayBlockingQueue` / `LinkedBlockingQueue` | 线程池/生产者消费者 |
| 延迟队列 | `DelayQueue` | 元素到期才可取 |
| 高并发无锁 | `ConcurrentLinkedQueue` | CAS 无锁 |

```java
// ❌ 老 API，遗留类，内部 synchronized，性能差
Stack<Integer> s = new Stack<>();
// ✅
Deque<Integer> s2 = new ArrayDeque<>();
s2.push(1); s2.pop(); s2.peek();
```

**阻塞队列选型**：

```java
// 有界、数组实现：吞吐低一点但内存可控，适合线程池
BlockingQueue<Runnable> q1 = new ArrayBlockingQueue<>(1000);
// 可选有界、链表实现：吞吐高，默认无界（无界有 OOM 风险！）
BlockingQueue<Runnable> q2 = new LinkedBlockingQueue<>(1000);
```

> ⚠️ `LinkedBlockingQueue` **默认容量是 `Integer.MAX_VALUE`（无界）**，`Executors.newFixedThreadPool` 正是因此藏着 OOM 隐患——生产建议显式传容量，或直接用 `ThreadPoolExecutor` 自定义。

---

## 七、内存开销对比（估算，压缩指针下）

| 集合 | 每元素额外开销 | 说明 |
|---|---|---|
| `ArrayList` | ~8 字节/引用（+ 预留空槽） | 最省 |
| `LinkedList` | ~40 字节/元素 | 每个 Node 对象头 + 两引用 |
| `HashMap` | ~32-48 字节/entry | Node 对象 + table 槽 |
| `LinkedHashMap` | 比 HashMap 多 ~16 字节/entry | 多两条链指针 |
| `HashSet` | 等于内部 HashMap 的 entry 开销 | 只有 key，无 value |
| `TreeMap` | ~40 字节/entry | 红黑树节点 + 颜色 |

**结论**：海量数据放内存时，`ArrayList`/基本类型数组最省；`LinkedList`、`TreeMap` 一定慎用；能用 `int[]`/`long[]`（或 `fastutil`/Eclipse Collections 的原始类型集合）就别用 `List<Integer>`——**`List<Integer>` 每元素装箱一个对象，内存放大好几倍**。

```java
// 1 亿个 int：
int[] a = new int[100_000_000];        // ~400MB
List<Integer> b = new ArrayList<>();   // 每个 Integer 对象 + 引用，轻松 >2GB
```

---

## 八、常见反模式清单

1. **`List.contains()` 进循环** → O(n²)。改用 `HashSet` 判定存在性。
2. **`List.remove(int)` vs `remove(Object)` 重载陷阱** → `List<Integer>.remove(1)` 删的是**下标 1**，不是值 1；要删值 1 用 `remove(Integer.valueOf(1))`。
3. **在 `for-each` 里 `list.remove`** → `ConcurrentModificationException`（fail-fast）。用 `Iterator.remove()` 或 `removeIf`。
4. **`HashMap` 做并发写** → 数据不一致。
5. **`Arrays.asList` 返回定长列表** → `add`/`remove` 抛 `UnsupportedOperationException`。
6. **`List.of()` / `Map.of()` 不可变** → 同上，写入抛异常；且**不允许 null**。
7. **`subList` 返回的是视图** → 对原列表结构修改会导致 `subList` 失效或抛异常。
8. **`TreeMap` 的 key 依赖 `Comparable` 或 `Comparator`** → 否则 `ClassCastException`。

---

## 九、面试高频追问

**Q1：`ArrayList` 和 `LinkedList` 怎么选？**
99% 场景选 `ArrayList`（缓存友好、内存省、随机访问 O(1)）。`LinkedList` 只在「频繁用迭代器在中部插删且不随机访问」时有理论优势，实际因缓存不友好常被 `ArrayList` 反超；作队列用 `ArrayDeque`。

**Q2：`HashMap` 为什么容量是 2 的幂？**
为了让 `(n - 1) & hash` 等价于 `hash % n`（位运算更快），且扩容时元素要么留在原位、要么移动 `oldCap`，无需重新计算 hash，提升 rehash 效率。

**Q3：`ConcurrentHashMap` 怎么保证线程安全？**
JDK 8 用 `CAS`（空桶插入/扩容协助）+ `synchronized`（锁首个节点）保证单桶操作原子，读操作 `volatile` 保证可见性，整体并发度远高于 JDK 7 的分段锁。

**Q4：`HashMap` 线程不安全体现在哪？**
并发 put 可能覆盖彼此、丢数据；JDK 7 扩容时头插法可能形成环形链表导致 `get` 死循环（CPU 100%）。JDK 8 改尾插后死循环消失，但仍会丢数据。

**Q5：`HashSet` 如何实现去重？**
底层是 `HashMap`，元素作 key，value 是共享的占位对象 `PRESENT`；去重依赖 `hashCode` 定位桶 + `equals` 判定相等。

---

## 结语

集合选型的本质是**用对数据结构的复杂度与内存特性**：默认 `ArrayList`/`HashMap`/`HashSet`/`ArrayDeque`；需要顺序就 `Linked*`，需要排序就 `Tree*`，需要并发就 `Concurrent*`；海量数据警惕装箱与链表内存放大；循环里查存在性永远先想到 `Set`。把这棵树背下来，面试和线上性能问题都能少踩一半坑。
