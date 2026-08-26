---
title: 【Java 基础】Java 数组深度解析：从内存布局到 Arrays 工具类的排序与二分源码
date: 2026-08-26 08:00:00
tags:
  - Java
  - 基础
  - 源码
  - 面试
categories:
  - Java
  - Java 基础
author: 东哥
---

# 【Java 基础】Java 数组深度解析：从内存布局到 Arrays 工具类的排序与二分源码

## 面试官：数组是对象吗？为什么数组打印出来是地址？Arrays.sort 底层用的什么排序算法？

数组是 Java 里最「古老」也最容易被忽视的数据结构——人人都会用，但问到内存布局、协变特性、`Arrays.sort` 的双轴快排，很多人就卡壳了。本文把数组从底层到工具类一次讲透。

## 一、数组的本质：一个特殊的对象

### 1.1 数组是对象，但和普通对象不一样

```java
int[] arr = new int[10];
System.out.println(arr.getClass());         // class [I
System.out.println(arr.getClass().getSuperclass());  // class java.lang.Object

String[] strs = new String[3];
System.out.println(strs.getClass());        // class [Ljava.lang.String;
```

- **数组的运行时类型**由 JVM 动态生成，类名规则：`[` + 元素类型描述符（`[I` 表示 int[]，`[[I` 表示 int[][]）；
- **数组的父类是 Object**，但**不继承 Object 的 `equals()`/`hashCode()`**——这两个方法数组没有重写，所以：
  - `arr1.equals(arr2)` 比较的是**引用**（不是内容！）；
  - `System.out.println(arr)` 打印的是 `[I@1b6d3586`（类型 + 哈希）；
  - 比较内容必须用 `Arrays.equals()` / `Arrays.deepEquals()`。

### 1.2 数组的内存布局

数组对象在堆中的布局（以 `int[5]` 为例）：

```
+----------------+----------------+--------+--------+--------+--------+--------+
| 对象头(MarkWord+Klass) | 长度 length(4字节) | data[0] | data[1] | data[2] | data[3] | data[4] |
+----------------+----------------+--------+--------+--------+--------+--------+
```

- **对象头**：Mark Word + 类型指针（开启压缩指针后共 12 字节）；
- **length 字段**：数组长度存在对象头之后，所以 `arr.length` 是 O(1) 的字段读取，不是方法调用；
- **连续内存**：元素紧密排列，**CPU 缓存友好**（cache line 预取），这是数组比链表快的最重要原因；
- **引用数组**（`Object[]`）：元素存的是引用（4/8 字节），对象本身散落在堆中。

**性能启示**：遍历数组是顺序内存访问，`for` 循环访问 `arr[i]` 时 JIT 能自动做边界检查消除（range check elimination），性能接近 C 语言裸数组。

## 二、数组的三大特性

### 2.1 长度固定

创建后长度不可变。「动态扩容数组」的本质是**新建更大数组 + `System.arraycopy()` 拷贝**——这就是 ArrayList 扩容的底层：

```java
// ArrayList.grow() 最终调用
System.arraycopy(elementData, 0, newElementData, 0, size);
```

`System.arraycopy` 是 native 方法，可能走 `memmove`，**比 for 循环拷贝快一个数量级**。

### 2.2 类型安全 & 协变（covariance）

Java 数组是**协变**的：`String[]` 是 `Object[]` 的子类型。但元素类型在运行时是「具体化」（reified）的——JVM 在**每次赋值时做运行时类型检查**：

```java
String[] strs = new String[3];
Object[] objs = strs;        // 协变：编译通过
objs[0] = 1;                 // 编译通过，但运行时抛 ArrayStoreException！
```

这就是著名的**数组协变陷阱**：编译期检查被推迟到运行期。对比泛型是「不变」且类型擦除的——**数组持有运行时类型信息，泛型不持有**，这也是两者不能混用（`new T[]` 非法）的根源。

### 2.3 初始化默认值

| 类型 | 默认值 |
|------|--------|
| int/short/byte/long | 0 |
| float/double | 0.0 |
| boolean | false |
| char | '\u0000' |
| 引用类型 | null |

```java
int[] a = new int[3];      // [0, 0, 0]
Integer[] b = new Integer[3];  // [null, null, null]
```

## 三、数组常用操作盘点

```java
// 创建 & 初始化
int[] a = {1, 2, 3};
int[] b = new int[]{1, 2, 3};
int[][] matrix = new int[3][4];   // 二维数组 = 数组的数组（不规则数组也可以）

// 拷贝
int[] copy = Arrays.copyOf(a, a.length);        // 截断或补默认值
int[] part = Arrays.copyOfRange(a, 1, 3);       // 拷贝区间 [1,3)

// 比较 & 填充
Arrays.equals(a, b);         // 一维内容比较
Arrays.deepEquals(a2d, b2d); // 多维内容比较
Arrays.fill(a, 0);           // 全部填充

// 转字符串
System.out.println(Arrays.toString(a));   // [1, 2, 3]
System.out.println(Arrays.deepToString(a2d));  // [[1, 2], [3, 4]]

// 转 List（注意：是固定大小的视图，不能 add/remove）
List<Integer> list = Arrays.asList(1, 2, 3);
```

**经典坑**：`Arrays.asList()` 返回的是 `Arrays$ArrayList`（内部类），`add()` 会抛 `UnsupportedOperationException`；且 `int[]` 转 List 时会被当成**一个元素**，必须用 `Integer[]` 或流式装箱。

## 四、Arrays.sort 源码解析：它到底用了什么排序？

`Arrays.sort` 会根据**类型和规模**选择不同算法，这是它「快」的关键：

### 4.1 基本类型数组（int[]、long[] 等）：DualPivotQuicksort

```java
// Arrays.java
public static void sort(int[] a) {
    DualPivotQuicksort.sort(a, 0, a.length - 1, null, 0, 0);
}
```

JDK 7 引入的**双轴快排**（Dual-Pivot Quicksort，作者 Vladimir Yaroslavskiy）在内部做了精细分级：

| 数组长度 | 算法 |
|---------|------|
| < 47 | 插入排序（简单场景常数最优） |
| < 286 | 双轴快排（两个 pivot 分三段，减少递归深度） |
| ≥ 286 且近乎有序 | 归并排序（检测到有序结构，规避快排最坏 O(n²)） |
| ≥ 286 且杂乱 | 双轴快排 |

```java
// DualPivotQuicksort 中的长度判断（真实源码逻辑）
if (length < INSERTION_SORT_THRESHOLD) {          // 47
    // 插入排序
} else if (length < QUICKSORT_THRESHOLD) {        // 286
    // 双轴快排
} else {
    // 先检测是否近乎有序，决定走归并还是快排
}
```

**为什么基本类型用快排不用归并？** 因为基本类型没有稳定性要求（值相等不可区分），而快排**额外内存 O(log n)**、缓存更友好；**为什么对象类型用归并？** 见下。

### 4.2 对象数组：TimSort（稳定排序）

```java
public static <T> void sort(T[] a, Comparator<? super T> c) {
    // 走 TimSort（旧版本是归并排序）
    TimSort.sort(a, 0, a.length, c, null, 0, 0);
}
```

对象排序必须**稳定**（相等元素保持原相对顺序，业务上经常需要），所以用基于归并思想的 TimSort——它检测「天然有序」的 run 片段直接合并，对**近乎有序的数据接近 O(n)**，是 Python、Java、Android 的通用选择。代价是需要 O(n) 辅助空间。

### 4.3 并行排序：parallelSort

```java
Arrays.parallelSort(arr);   // JDK 8+，大数组自动拆分成子任务并行排序
```

底层用 ForkJoinPool，数组长度小于阈值（`ForkJoinPool.getCommonPoolParallelism()` 相关）时退化为普通 `sort`。**小数组不要用**，拆分开销反而更大。

## 五、Arrays.binarySearch：二分查找的边界

```java
int idx = Arrays.binarySearch(arr, key);
// 找到：返回下标；没找到：返回 -(插入点) - 1
```

**返回值的数学含义**：`-(insertionPoint) - 1`。比如 `[1, 3, 5]` 中查 `4`，插入点是 2，返回 `-3`。通过 `idx >= 0` 判断是否存在，通过 `-(idx + 1)` 反推插入位置——这是实现「有序插入」的惯用技巧：

```java
int[] sorted = {1, 3, 5};
int idx = Arrays.binarySearch(sorted, 4);
if (idx < 0) {
    int insertAt = -idx - 1;   // 2
    // 扩容并插入
}
```

⚠️ **铁律：binarySearch 前数组必须已排序**，否则结果是未定义的（可能找不到，也可能返回错误位置）。

## 六、ArrayList vs 数组：什么时候用谁？

| 维度 | 数组 | ArrayList |
|------|------|-----------|
| 长度 | 固定 | 动态扩容（1.5 倍） |
| 性能 | 最快，无装箱（基本类型） | 有装箱开销（除非用 primitive 集合库） |
| 功能 | 无方法 | 增删改查、迭代器、Stream |
| 内存 | 紧凑 | 有 elementData 引用数组额外开销 |
| 适用 | 固定长度、性能敏感、多维计算 | 日常业务、长度不确定 |

**性能敏感场景**（如数值计算、序列化缓冲、`ArrayList` 内部实现）用数组；业务代码用 ArrayList。这也是 Netty `ByteBuf`、各类缓冲区底层都用数组的原因。

## 七、面试官追问环节

**Q1：为什么数组用 == 比较不行？**
数组没重写 `equals()`/`hashCode()`，`==` 和 `equals()` 都是引用比较。用 `Arrays.equals()`（一维）/ `Arrays.deepEquals()`（多维）。

**Q2：new T[] 为什么编译不过？泛型数组怎么创建？**
泛型在编译期擦除，JVM 无法在运行时确认元素类型，而数组需要运行时类型信息（协变 + ArrayStoreException 检查）。解决：`(T[]) new Object[size]`（如 ArrayList 就是这么干的）或 `Array.newInstance(Class, size)` 反射创建。

**Q3：Arrays.sort 和 Collections.sort 的关系？**
`Collections.sort(List)` 底层是 `List.sort()`，把 List 转成数组后调用 `Arrays.sort`（对象版 TimSort）再写回。

**Q4：怎么把数组转成真正的 List（可变）？**
`new ArrayList<>(Arrays.asList(...))`，或者 Java 9+：`List.of(...)`（不可变）。

**Q5：数组为什么快？**
连续内存 + 缓存局部性 + 无指针间接跳转 + JIT 边界检查消除。链表每个节点是一次 cache miss 的代价，数据量大时差距可达数量级。

## 八、总结

- 数组是**特殊的对象**：持有 length 字段、运行时类型具体化、连续内存布局；
- **协变 + 运行时检查**是数组区别于泛型的核心特性（也带来 ArrayStoreException）；
- `Arrays.sort`：基本类型走**双轴快排/插入/归并分级策略**，对象走 **TimSort（稳定）**，并行用 `parallelSort`；
- `binarySearch` 前必须排序，未命中返回 `-(插入点)-1`；
- 内容比较用 `Arrays.equals`，打印用 `Arrays.toString`，拷贝用 `System.arraycopy`。

数组很简单，但越简单的东西越见功底——把内存布局和排序分级策略讲出来，面试官就知道你是真懂而不是背 API。
