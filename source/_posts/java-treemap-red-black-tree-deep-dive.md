---
title: 【Java集合】TreeMap 红黑树源码深度解析：从旋转变色到 NavigableMap 区间查询
date: 2026-08-05 08:00:00
tags:
  - Java
  - 集合
  - TreeMap
  - 红黑树
  - 源码
  - 面试
categories:
  - Java
  - Java集合
author: 东哥
---

# 【Java集合】TreeMap 红黑树源码深度解析：从旋转变色到 NavigableMap 区间查询

## 面试官：HashMap 底层是哈希表，那 TreeMap 呢？它为什么能保持有序？

TreeMap 的底层是一棵**红黑树（Red-Black Tree）**，它保证了 `put`、`get`、`remove` 的时间复杂度都是 **O(log n)**，并且 key 天然有序。面试中红黑树是"谈之色变"的高频考点——大部分人都只背结论，不懂旋转和变色。本文从数据结构出发，结合 JDK 8 源码，把红黑树和 TreeMap 彻底讲透。

<!-- more -->

## 一、为什么需要红黑树？

### 1.1 二叉搜索树（BST）的致命缺陷

普通 BST 在数据有序插入时会退化成链表：

```
插入 1,2,3,4,5：          1
                           \
                            2
                             \
                              3
                               \
                                4
                                 \
                                  5
```

此时查找复杂度从 O(log n) 退化为 **O(n)**。

### 1.2 平衡方案对比

| 数据结构 | 平衡方式 | 查找 | 插入/删除 | 实现复杂度 |
|---------|---------|------|----------|-----------|
| AVL 树 | 严格平衡（左右子树高度差 ≤1） | O(log n) | O(log n) | 旋转多，删除更复杂 |
| 红黑树 | 近似平衡（最长路径 ≤ 2×最短路径） | O(log n) | O(log n) | 旋转少，性能稳定 |
| B/B+ 树 | 多路平衡 | O(log n) | O(log n) | 适合磁盘/页存储 |

**为什么 JDK 选红黑树而不是 AVL 树？**

红黑树是"**近似平衡**"，不像 AVL 那么严格，因此插入/删除时**旋转次数更少**。对于频繁写操作的场景（TreeMap、HashMap 冲突链表转树），红黑树的整体性能更优。AVL 查询略快但写操作代价高，适合读多写少。这也是面试常问的对比点。

## 二、红黑树的 5 大性质

```java
// JDK 中节点的颜色常量
static final boolean RED   = false;
static final boolean BLACK = true;
```

1. **每个节点要么是红色，要么是黑色**
2. **根节点必须是黑色**
3. **叶子节点（NIL 空节点）是黑色**
4. **红色节点的两个子节点必须是黑色**（不能出现连续的红色节点）
5. **从任意节点到其每个叶子的所有路径，包含相同数目的黑色节点**（黑色高度一致）

**推论**：性质 4 + 5 保证了"最长路径（红黑交替）最多是最短路径（全黑）的 2 倍"，所以树的高度 ≤ 2log₂(n+1)，查找复杂度稳定在 O(log n)。

## 三、左旋与右旋

旋转是红黑树维持平衡的"手术刀"，TreeMap 的 `rotateLeft` / `rotateRight`：

```java
// JDK 8 TreeMap 左旋：以 p 为轴，把 p 的右孩子提升为父节点
private void rotateLeft(Entry<K,V> p) {
    if (p != null) {
        Entry<K,V> r = p.right;
        p.right = r.left;                  // r 的左子树挂到 p 的右边
        if (r.left != null)
            r.left.parent = p;
        r.parent = p.parent;               // r 提升
        if (p.parent == null)
            root = r;
        else if (p.parent.left == p)
            p.parent.left = r;
        else
            p.parent.right = r;
        r.left = p;                        // p 变成 r 的左孩子
        p.parent = r;
    }
}
```

**记忆口诀**：

- **左旋**：右孩子上位，当前节点变成右孩子的左孩子（"左旋=往左倒"）
- **右旋**：左孩子上位，当前节点变成左孩子的右孩子

旋转只改变指针指向，不破坏二叉搜索树的顺序性（中序遍历不变），同时能调整子树高度。

## 四、TreeMap 的插入与修复（JDK 8 源码）

### 4.1 put 流程

```java
public V put(K key, V value) {
    Entry<K,V> t = root;
    // 1. 空树：直接作为根节点
    if (t == null) {
        // compare 检查 key 是否可比较（内部会抛 NPE/ClassCastException）
        compare(key, key);
        root = new Entry<>(key, value, null);
        size = 1;
        return null;
    }
    // 2. 按比较器从根节点向下查找插入位置
    int cmp;
    Entry<K,V> parent;
    Comparator<? super K> cpr = comparator;
    if (cpr != null) {
        do {
            parent = t;
            cmp = cpr.compare(key, t.key);
            if (cmp < 0)      t = t.left;
            else if (cmp > 0) t = t.right;
            else              return t.setValue(value);  // key 已存在，覆盖值
        } while (t != null);
    } else {
        // 自然排序（Comparable）分支，逻辑相同
        // ...
    }
    // 3. 创建新节点（默认红色），挂到父节点下
    Entry<K,V> e = new Entry<>(key, value, parent);
    if (cmp < 0) parent.left = e;
    else         parent.right = e;
    // 4. 红黑树修复（关键！）
    fixAfterInsertion(e);
    size++;
    modCount++;
    return null;
}
```

### 4.2 fixAfterInsertion：插入修复的 3 种情况

**约定**：新节点 x 为红色。若父节点是黑色，直接结束（性质 4 未被破坏）；若父节点是红色，则必须修复。设 x 的父节点为 p，祖父为 g，叔叔为 u：

```java
private void fixAfterInsertion(Entry<K,V> x) {
    x.color = RED;   // 新节点染红
    while (x != null && x != root && x.parent.color == RED) {
        if (parentOf(x) == leftOf(parentOf(parentOf(x)))) {
            // 情况A：父节点是祖父的左孩子
            Entry<K,V> y = rightOf(parentOf(parentOf(x)));  // 叔叔
            if (colorOf(y) == RED) {
                // 情况1：叔叔是红色 → 变色（父、叔变黑，祖父变红，x 上移到祖父）
                setColor(parentOf(x), BLACK);
                setColor(y, BLACK);
                setColor(parentOf(parentOf(x)), RED);
                x = parentOf(parentOf(x));
            } else {
                if (x == rightOf(parentOf(x))) {
                    // 情况2：叔叔是黑，且 x 是右孩子 → 左旋父节点，转为情况3
                    x = parentOf(x);
                    rotateLeft(x);
                }
                // 情况3：叔叔是黑，且 x 是左孩子 → 父变黑、祖父变红、右旋祖父
                setColor(parentOf(x), BLACK);
                setColor(parentOf(parentOf(x)), RED);
                rotateRight(parentOf(parentOf(x)));
            }
        } else {
            // 情况B：父节点是祖父的右孩子（对称处理）
            // ...镜像逻辑
        }
    }
    root.color = BLACK;   // 最后强制根为黑
}
```

**插入修复记忆表**：

| 场景 | 处理 |
|------|------|
| 父黑 | 无需修复 |
| 父红 + 叔红 | 变色：父、叔变黑，祖父变红，继续向上检查 |
| 父红 + 叔黑 + 自己是右孩子 | 先左旋变"左孩子"形态 |
| 父红 + 叔黑 + 自己是左孩子 | 父变黑、祖父变红、右旋 |

**本质**：插入最多 2 次旋转就能完成修复，这就是红黑树插入高效的秘密。

## 五、删除与后继节点

删除比插入更复杂。核心步骤：

1. **找后继**：若删除节点有两个孩子，用**中序后继**（右子树最小节点）替换值，再删除后继节点（后继最多只有一个孩子）
2. **删除节点**：如果删除的是红色节点，直接删（不破坏性质）；删除黑色节点则破坏性质 5，需要 `fixAfterDeletion` 修复
3. **删除修复**：循环处理 4 种情况（兄弟为红 / 兄弟为黑且兄弟孩子全黑 / 兄弟为黑且兄弟左孩子红右孩子黑 / 兄弟为黑且兄弟右孩子红），核心手段依然是**变色 + 旋转**

```java
// 中序后继：右子树中最小的节点
static <K,V> TreeMap.Entry<K,V> successor(Entry<K,V> t) {
    if (t == null) return null;
    else if (t.right != null) {
        Entry<K,V> p = t.right;
        while (p.left != null) p = p.left;   // 一路向左
        return p;
    } else {
        // 没有右孩子：向上找第一个"作为左孩子"的祖先
        Entry<K,V> p = t.parent;
        Entry<K,V> ch = t;
        while (p != null && ch == p.right) {
            ch = p;
            p = p.parent;
        }
        return p;
    }
}
```

**面试高频题：HashMap 的"链表转红黑树"和 TreeMap 的红黑树是同一套吗？**

不是同一份代码，但**数据结构本质相同**。HashMap 内部有独立的 `TreeNode`（红黑树节点）实现，包含自己的 `rotateLeft`/`rotateRight`/`balanceInsertion`；TreeMap 的 `Entry` 是自己的实现。两者都满足红黑树 5 大性质，只是代码组织不同。

## 六、NavigableMap：TreeMap 的灵魂 API

TreeMap 实现 `NavigableMap`，提供了大量"找最近邻"和"区间视图"的方法，底层都是 O(log n) 的树查找：

```java
TreeMap<Integer, String> map = new TreeMap<>();
map.put(1, "a"); map.put(3, "c"); map.put(5, "e"); map.put(7, "g");

// 精确导航
map.firstKey();        // 1
map.lastKey();         // 7
map.lowerKey(5);       // 3   - 严格小于 5 的最大 key
map.floorKey(5);       // 5   - 小于等于 5 的最大 key
map.higherKey(5);      // 7   - 严格大于 5 的最小 key
map.ceilingKey(5);     // 5   - 大于等于 5 的最小 key

// 区间视图（返回原 map 的视图，修改会同步）
map.subMap(1, true, 5, false);   // [1, 5)  → {1=a, 3=c}
map.headMap(5);                  // <5      → {1=a, 3=c}
map.tailMap(3);                  // >=3     → {3=c, 5=e, 7=g}
map.descendingMap();             // 逆序视图

// 实际应用：找出"最近的上一个/下一个"
map.lowerKey(5);   // 数据库分页中"基于游标取上一页"
map.higherKey(5);  // 取下一页
```

**实现原理**：`subMap` 等返回的是 `NavigableSubMap` 内部类，它持有原 map 的引用和上下界，`get/put` 时先检查边界再委托给原 map——这就是**视图模式**（和 `List.subList` 同款思想）。

## 七、TreeMap  vs  HashMap  vs LinkedHashMap

| 对比项 | HashMap | LinkedHashMap | TreeMap |
|--------|---------|---------------|---------|
| 底层结构 | 数组 + 链表/红黑树 | 数组 + 链表/红黑树 + 双向链表 | 红黑树 |
| 时间复杂度 | O(1) | O(1) | O(log n) |
| 顺序 | 无序 | 插入序 / 访问序 | key 排序（自然序/比较器） |
| key 要求 | hashCode + equals | hashCode + equals | Comparable / Comparator |
| 是否允许 null key | 允许（1 个） | 允许（1 个） | **不允许**（compare 会 NPE） |
| 典型场景 | 通用查找 | LRU 缓存 | 区间查询、排序、一致性哈希 |

**为什么 TreeMap 不允许 null key？** 因为红黑树必须通过比较器决定节点去向，`null` 无法比较，`compare()` 会抛 NPE。

**经典应用**：一致性哈希算法中，用 `TreeMap` 的 `tailMap(hash)` + `firstKey()` 找到哈希环上最近的节点——比遍历数组高效得多。

## 八、TreeMap 的线程安全

TreeMap **不是线程安全的**。多线程场景三种方案：

1. `Collections.synchronizedSortedMap(new TreeMap<>())`：粗粒度加锁
2. `ConcurrentSkipListMap`：跳表实现的有序并发 Map，无锁，推荐
3. 外部自行加锁

```java
SortedMap<Integer, String> safeMap =
    Collections.synchronizedSortedMap(new TreeMap<>());

// 高并发有序场景，用跳表
ConcurrentSkipListMap<Integer, String> skipListMap =
    new ConcurrentSkipListMap<>();
```

**追问：为什么有序并发容器用跳表而不是红黑树？** 跳表实现简单（多级链表），无锁并发（CAS）容易实现；红黑树的旋转在并发下加锁代价高。

## 九、面试追问总结

1. **TreeMap 底层是什么？** → 红黑树，O(log n)，key 有序
2. **红黑树的 5 大性质？** → 节点红黑、根黑、叶黑、红不连、黑高一致
3. **为什么选红黑树不选 AVL？** → 近似平衡，旋转少，写操作性能好
4. **插入修复的几种情况？** → 父黑不动；叔红变色；叔黑先旋再变色+旋
5. **TreeMap 和 HashMap 怎么选？** → 需要有序/区间查询用 TreeMap，否则 HashMap
6. **TreeMap 线程安全吗？** → 不安全，有序并发用 ConcurrentSkipListMap
7. **为什么不能有 null key？** → 比较器无法比较 null

## 十、总结

红黑树没有想象中那么可怕——抓住"**变色 + 旋转**"两个手段，理解"插入看叔叔、删除看兄弟"的修复口诀，源码就通了。TreeMap 的价值不只是"有序"，更是 `NavigableMap` 那套强大的区间查询 API，在排序、TopK、一致性哈希、基于游标的分页中都是利器。背会结论不算会，能画出一次左旋右旋、讲清插入 3 种情况，面试官才会给你加分。
