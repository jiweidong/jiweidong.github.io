---
title: 彻底搞懂 Java 字符串常量池与 intern 机制
date: 2026-06-27 08:00:00
tags:
  - Java
  - JVM
  - 面试
categories:
  - Java
  - JVM原理
author: 东哥
---

# 彻底搞懂 Java 字符串常量池与 intern 机制

## 面试官：new String("abc") 创建了几个对象？

这道面试经典题先开个头。在回答这个问题之前，我们需要先搞清楚 Java 字符串常量池（String Constant Pool）、字符串字面量、`intern()` 方法以及 JDK 版本演进带来的变化。

## 一、字符串常量池是什么？

### 1.1 概念

Java 字符串常量池（String Constant Pool）是 JVM 为优化字符串存储而开辟的一块特殊内存区域，用于存储**字符串字面量**和通过 `intern()` 方法进入的字符串对象。

核心思想：**复用字符串对象，减少内存开销**。

```java
String s1 = "hello";
String s2 = "hello";
System.out.println(s1 == s2); // true，指向常量池同一个对象
```

### 1.2 JDK 版本演进中的位置变化

| JDK 版本 | 常量池位置 | 说明 |
|---------|-----------|------|
| JDK 6 及以前 | 方法区（永久代） | 受 PermGen 大小限制，容易 OOM |
| JDK 7 | 堆内存 | 从永久代移到堆中，可被 GC 回收 |
| JDK 8+ | 堆内存 | 永久代被元空间取代，字符串常量池仍在堆中 |

> 这个移动非常关键：JDK 7 之前字符串常量池在永久代，GC 效率低，容易 OOM；JDK 7+ 移到堆后，字符串常量池中的对象可以被 Full GC 正常回收。

## 二、字符串字面量的创建流程

### 2.1 编译期处理

当我们在代码中写 `String s = "hello"` 时：

**编译阶段**：编译器将字符串字面量放入 `.class` 文件的常量池（Class Constant Pool）中。

**类加载阶段**：JVM 加载类时，会将 Class 常量池中的字符串常量加载到**运行时常量池**，然后在堆中创建字符串对象，并将引用放入**字符串常量池**（String Pool）。

```java
// 编译期已确定，直接引用常量池
String s1 = "hello";
String s2 = "hello";
// s1 == s2 为 true
```

### 2.2 new String("hello") 到底创建几个对象？

```java
String s = new String("hello");
```

这行代码可能创建 **1 个或 2 个对象**：

1. **如果常量池中还没有 "hello" 字面量**：编译期在 Class 常量池中有 "hello"，类加载时在堆中创建一个字符串对象并放入常量池。这一步发生在类加载期间。然后执行 `new String("hello")` 时，再在堆中创建一个新的 String 对象。所以是 **2 个对象**。

2. **如果常量池中已有 "hello"**：只有 `new` 创建的一个新对象。所以是 **1 个对象**。

```java
String s1 = "hello";          // 常量池创建 "hello"（类加载时）
String s2 = new String("hello"); // 堆上新创建一个对象
System.out.println(s1 == s2); // false

// 验证：
System.out.println(s1 == s2.intern()); // true，intern 返回常量池中的引用
```

### 2.3 字符串拼接的玄机

**编译期常量折叠**：

```java
final String a = "hello";
final String b = "world";
String c = a + b;  // 编译优化后：String c = "helloworld"
String d = "helloworld";
System.out.println(c == d); // true
```

final 修饰的变量在编译期被视为常量，编译器会直接进行折叠优化。

**运行期拼接**：

```java
String a = "hello";
String b = "world";
String c = a + b;
String d = "helloworld";
System.out.println(c == d); // false

// 底层：StringBuilder.append().toString()，产生新对象
```

但注意：

```java
String c = "hello" + "world"; // 编译期优化为 "helloworld"
String d = "helloworld";
System.out.println(c == d); // true，都是常量池中的对象
```

## 三、intern() 方法深度解析

### 3.1 intern() 的作用

`String.intern()` 是一个 native 方法，它的作用是：

1. 如果字符串常量池中已存在内容相同的字符串（通过 `equals()` 判断），则返回常量池中的引用
2. 如果不存在，则将当前字符串的引用放入常量池（JDK 7+），或复制对象到常量池（JDK 6）

### 3.2 JDK 6 与 JDK 7+ 的 intern() 差异

这是面试中的**高频考点**：

```java
// JDK 6
String s1 = new String("a") + new String("b");
s1.intern();
String s2 = "ab";
System.out.println(s1 == s2); // false

// JDK 7+
String s1 = new String("a") + new String("b");
s1.intern();
String s2 = "ab";
System.out.println(s1 == s2); // true
```

**为什么？**

| 版本 | intern() 行为 |
|------|-------------|
| JDK 6 | 将字符串对象**复制**到永久代常量池，返回新对象的引用。s1 是堆上对象，s2 是常量池对象，不同 |
| JDK 7+ | 常量池在堆中，首次 intern() 时直接将堆中对象的**引用**存入常量池。`s1.intern()` 把 s1 的引用存入常量池，`"ab"` 字面量直接引用常量池中已存的 s1 引用，所以 s1 == s2 |

再看一个变体：

```java
// JDK 7+
String s1 = new String("a") + new String("b");
String s2 = "ab";     // 先定义字面量，会在常量池创建 "ab"
s1.intern();          // 常量池已有 "ab"，直接返回，s1.intern() == s2
System.out.println(s1 == s2); // false
System.out.println(s1.intern() == s2); // true
```

**顺序决定结果**，这是很多面试题挖坑的地方。

### 3.3 经典 intern() 面试题

```java
String s = new String("1");
s.intern();
String s2 = "1";
System.out.println(s == s2); // false

String s3 = new String("1") + new String("1");
s3.intern();
String s4 = "11";
System.out.println(s3 == s4); // true (JDK 7+)
```

第一段：`new String("1")` 时，"1" 已经在常量池中（类加载时创建的），所以 intern() 没效果，s2 拿的是常量池原有对象。

第二段：`"11"` 不在常量池，`s3.intern()` 将 s3 的引用放入常量池，`"11"` 直接使用该引用。

## 四、字符串常量池的 GC 与大小配置

### 4.1 GC 行为

JDK 7+ 字符串常量池在堆中，StringTable 本质上是一个 HashMap，当发生 GC 时，没有被引用的字符串常量也会被回收。

### 4.2 大小调整

```bash
# -XX:StringTableSize 设置 StringTable 的桶数量（建议设置为质数）
-XX:StringTableSize=1000003  # 默认为 60013（JDK 11+ 为 65536）

# -XX:+PrintStringTableStatistics 打印 StringTable 统计
-XX:+PrintStringTableStatistics
```

> 如果应用中有大量 intern() 的字符串，增大 StringTableSize 可以减少哈希冲突，提升性能。

### 4.3 实际应用：大量字符串去重

```java
// 读取大量重复字符串时使用 intern() 节省内存
public class StringDeduplicationExample {
    private static final Map<String, Data> cache = new ConcurrentHashMap<>();
    
    public Data getData(String key) {
        // 使用 intern() 确保相同的 key 复用同一个字符串对象
        String internedKey = key.intern();
        return cache.computeIfAbsent(internedKey, this::loadData);
    }
}
```

但注意：**过度使用 intern() 可能导致 StringTable 膨胀**，影响 GC 扫描效率。

## 五、深入理解 String 不可变性

### 5.1 String 为什么设计为不可变？

1. **字符串常量池的基础**：如果 String 可变，常量池中的对象被修改会影响所有引用
2. **安全性**：类加载、网络连接、数据库驱动等场景广泛使用 String 作为参数
3. **线程安全**：不可变对象天然线程安全
4. **Hash 缓存**：String 的 hash 值可以缓存

```java
public final class String
    implements java.io.Serializable, Comparable<String>, CharSequence {
    
    // 不可变：final 数组，不提供修改方法
    private final char value[];  // JDK 8 及以前
    // private final byte[] value; // JDK 9+ 使用 byte[] + coder 编码标识
    
    // hash 缓存
    private int hash; // 默认为 0
}
```

### 5.2 JDK 9 的字符串压缩

JDK 9 引入了 **Compact Strings**（JEP 254）：

```java
// JDK 9+ 的 String 实现
private final byte[] value;
private final byte coder; // 0: LATIN1, 1: UTF16
```

- 如果字符串内容可以用 ISO-8859-1/Latin-1 表示（单字节字符），使用 byte[] 每个字符占 1 字节
- 否则使用 UTF-16 编码，每个字符占 2 字节

> 大多数实际字符串是 Latin-1 可表示的，内存占用降低约 50%。

## 六、总结与面试清单

### 核心要点

| 问题 | 答案要点 |
|------|---------|
| `new String("a")` 创建几个对象？ | 1 或 2 个，取决于常量池是否已有 |
| String 常量池在哪个区域？ | JDK 6 在永久代，JDK 7+ 在堆 |
| `s1 == s2` 和 `s1.equals(s2)` 区别？ | == 比较引用，equals 比较内容 |
| intern() 的作用？ | 获取/存入常量池引用，复用字符串 |
| String 为什么不可变？ | 常量池、安全、线程安全、Hash 缓存 |

### 面试追问整理

**Q：`String s = "a" + "b" + "c"` 创建了几个对象？**
A：编译期优化为 `"abc"`，只创建了字符串常量池中的 1 个对象。

**Q：StringBuilder 和 StringBuffer 的区别？**
A：StringBuilder 非线程安全（JDK 1.5+），StringBuffer 线程安全但性能差。循环拼接字符串时，编译器会自动使用 StringBuilder，但循环内拼接会在每次迭代都 new 一个 StringBuilder，推荐手动使用。

**Q：为什么阿里巴巴 Java 规范说不要在循环中使用字符串拼接？**
A：循环内 `str += i` 等价于每次 new StringBuilder().append().toString()，产生大量临时对象。

**Q：你经历过字符串导致的 OOM 吗？**
A：比如日志解析场景，大量不同内容的字符串持续生成，每个都调用 intern()，导致 StringTable 膨胀，GC 无法回收，最终 OOM。解决方案：限制 intern() 使用范围，或限制字符串对象数量。

### 最佳实践

1. **能用字面量就不用 new**：`String s = "hello"` 优于 `new String("hello")`
2. **字符串常量相等用 == 判断**：常量池复用保证相同内容指向相同引用
3. **大字符串用 StringBuilder**：避免产生大量中间对象
4. **谨慎使用 intern()**：仅在高重复、有限集合的字符串场景下使用
5. **配置合理的 StringTableSize**：大量 intern() 场景下提高性能

### 代码自测

下面这段代码输出什么？评论区留下你的答案：

```java
String s1 = new StringBuilder("计算机").append("技术").toString();
System.out.println(s1.intern() == s1);

String s2 = new StringBuilder("ja").append("va").toString();
System.out.println(s2.intern() == s2);
```

> 提示：第二个输出是 false，因为 **"java"** 这个字符串在 JVM 启动时就已经被加载到常量池了（JVM 内部使用），所以 intern() 返回的是已有引用，不是 s2 的引用。
