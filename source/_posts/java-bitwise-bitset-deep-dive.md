---
title: 【Java进阶】Java 位运算与 BitSet 实战：从源码到性能优化
date: 2026-07-07 08:00:00
tags:
  - Java
  - 位运算
  - BitSet
  - 性能优化
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java进阶】Java 位运算与 BitSet 实战：从源码到性能优化

## 为什么位运算值得认真学？

很多 Java 开发者日常 CRUD 很少用到位运算，觉得它只是面试点缀。但事实上，位运算在**高性能编程、权限控制、状态压缩、网络协议解析、布隆过滤器**等场景中扮演着不可替代的角色。

一个典型对比：

```java
// 传统做法：4个 boolean 字段
boolean flag1, flag2, flag3, flag4;  // 占用 4 字节

// 位运算做法：一个 int 搞定
int flags = 0;                          // 占用 4 字节，可以存 32 个标志位
flags |= 1 << 0;   // 设置第 1 位
flags |= 1 << 3;   // 设置第 4 位
boolean has3 = (flags & (1 << 2)) != 0;  // 检查第 3 位
```

**位运算为什么快？** 因为 CPU 对位操作是原生支持的，一个时钟周期就能完成，比乘除法快几十倍，比分支跳转更没有预测开销。

本文将从位运算基础知识出发，深入到 `BitSet` 源码分析与实战应用。

---

## 一、Java 位运算基础速查

### 1.1 7 种位运算符

| 运算符 | 名称 | 说明 | 示例 |
|-------|------|------|------|
| `&` | 按位与 | 两位都为 1 才为 1 | `0b1100 & 0b1010 = 0b1000` |
| `|` | 按位或 | 有一位为 1 即为 1 | `0b1100 | 0b1010 = 0b1110` |
| `^` | 按位异或 | 两位不同为 1 | `0b1100 ^ 0b1010 = 0b0110` |
| `~` | 按位取反 | 0变1，1变0 | `~0b1100 = 0b0011`（仅低4位） |
| `<<` | 左移 | 左移，低位补0 | `5 << 2 = 20` |
| `>>` | 右移 | 右移，高位补符号位 | `-5 >> 2 = -2` |
| `>>>` | 无符号右移 | 右移，高位补0 | `-5 >>> 2 = 1073741822` |

### 1.2 常用位运算技巧

**检查某一位是否为 1**：
```java
boolean isSet = (flags & (1 << index)) != 0;
```

**设置某一位为 1**：
```java
flags |= (1 << index);
```

**清除某一位（设为 0）**：
```java
flags &= ~(1 << index);
```

**翻转某一位**：
```java
flags ^= (1 << index);
```

**取最低位的 1**（经典技巧）：
```java
int lowestOne = n & -n;
// 原理：-n = ~n + 1，与原数按位与只保留最低位的 1
```

**判断 2 的幂**：
```java
boolean powerOf2 = (n > 0) && ((n & (n - 1)) == 0);
```

### 1.3 位运算的性能优势实测

一个简单的基准测试：10 亿次取模运算

```java
// 取模运算（%）
int mod = value % 8;    // ~40ms

// 位运算替代（仅当除数是 2 的幂时有效）
int mod = value & 7;    // ~5ms，快约 8 倍
```

**核心原则**：当除数是 2 的幂时，`x % n` 等价于 `x & (n - 1)`。

---

## 二、BitSet 源码深度解析

### 2.1 BitSet 是什么？

`BitSet` 是 Java 提供的一个**位向量（Bit Vector）**实现，可以动态增长，用于高效存储和操作位（bit）数据。

```java
BitSet bits = new BitSet();
bits.set(0);
bits.set(1000000);  // 自动扩容
System.out.println(bits.get(1000000));  // true
```

### 2.2 底层存储结构

`BitSet` 内部使用 `long[]` 数组存储（而非 `byte[]`）：

```java
public class BitSet implements Cloneable, Serializable {
    private long[] words;     // 存储位数据的 long 数组
    private int wordsInUse;   // 实际使用的 word 数量
    private transient boolean sizeIsSticky; // 是否用户指定了初始大小
}
```

**为什么用 long[] 而不是 byte[]？**
- 对 64 位 CPU 友好，减少寻址次数
- JVM 的内存对齐对 long 更友好
- 内部移位计算以 64 为基，减少索引计算

### 2.3 核心源码分析

**set(int bitIndex)**：
```java
public void set(int bitIndex) {
    if (bitIndex < 0)
        throw new IndexOutOfBoundsException("bitIndex < 0: " + bitIndex);

    int wordIndex = wordIndex(bitIndex);  // bitIndex >> 6（除以 64）
    expandTo(wordIndex);                  // 容量不够则扩容

    words[wordIndex] |= (1L << bitIndex); // 核心：位或操作
    // 注意：1L << bitIndex 用的是 long 左移，bitIndex 会被截断为低 6 位
    // 因为 Java 中 long 移位只取低 6 位（0~63）
}
```

这里隐含着 Java 语言的一个小陷阱：

```java
// 看似左移 65 位，实际上相当于 65 % 64 = 1 位
long value = 1L << 65;  // 等价于 1L << 1，结果为 2
```

**get(int bitIndex)**：
```java
public boolean get(int bitIndex) {
    if (bitIndex < 0)
        throw new IndexOutOfBoundsException("bitIndex < 0: " + bitIndex);

    int wordIndex = wordIndex(bitIndex);
    return (wordIndex < wordsInUse)    // 索引在有效范围内
        && ((words[wordIndex] & (1L << bitIndex)) != 0);  // 检查对应位
}
```

**扩容机制**：
```java
private void expandTo(int wordIndex) {
    int wordsRequired = wordIndex + 1;
    if (wordsInUse < wordsRequired) {
        ensureCapacity(wordsRequired);
        wordsInUse = wordsRequired;
    }
}

private void ensureCapacity(int wordsRequired) {
    if (words.length < wordsRequired) {
        // 扩容策略：至少 2 倍，但不超过设定的大小限制
        int request = Math.max(2 * words.length, wordsRequired);
        words = Arrays.copyOf(words, request);
    }
}
```

### 2.3 BitSet 对比 boolean[]

| 对比维度 | BitSet | boolean[] |
|---------|--------|-----------|
| 内存占用 | 1 位/元素 | 1 字节/元素 |
| 1 千万标志位 | ~1.2 MB | ~10 MB |
| 随机访问 | O(1) | O(1) |
| 批量操作 | 位运算并行处理 | 循环遍历 |
| 动态扩容 | 自动 | 需手动创建新数组 |
| 序列化 | 支持 | 原生支持 |

**内存模型分析**：一个 `boolean[]` 在 HotSpot 中实际占用 **1 字节**（不是 1 位），而 `BitSet` 每个标志只占 1 位，空间效率是 boolean[] 的 **8 倍**。

### 2.4 批量位操作

`BitSet` 真正强大的地方是批量位操作：

```java
BitSet a = new BitSet();
BitSet b = new BitSet();
// ... 设置一些位

a.and(b);      // 按位与（交集）
a.or(b);       // 按位或（并集）
a.xor(b);      // 按位异或
a.andNot(b);   // a & ~b（差集）
```

这些操作内部使用长整型数组的循环处理，一次处理 64 位：

```java
public void and(BitSet set) {
    if (this == set) return;
    while (wordsInUse > set.wordsInUse)
        words[--wordsInUse] = 0;

    for (int i = 0; i < wordsInUse; i++)
        words[i] &= set.words[i];  // 一次处理 64 位

    recalculateWordsInUse();
}
```

---

## 三、实战案例

### 3.1 权限管理：位掩码模式

```java
class Permission {
    public static final int READ    = 1 << 0;  // 0001
    public static final int WRITE   = 1 << 1;  // 0010
    public static final int DELETE  = 1 << 2;  // 0100
    public static final int ADMIN   = 1 << 3;  // 1000

    private int permissions;

    public void grant(int permission) {
        permissions |= permission;
    }

    public void revoke(int permission) {
        permissions &= ~permission;
    }

    public boolean has(int permission) {
        return (permissions & permission) == permission;
    }

    public boolean hasAll(int... perms) {
        int mask = 0;
        for (int p : perms) mask |= p;
        return (permissions & mask) == mask;
    }
}

// 使用
Permission p = new Permission();
p.grant(Permission.READ | Permission.WRITE);
p.has(Permission.READ);    // true
p.has(Permission.DELETE);  // false
```

### 3.2 布隆过滤器（Bloom Filter）

布隆过滤器的核心就是位数组 + 多个哈希函数：

```java
class SimpleBloomFilter {
    private final BitSet bits;
    private final int size;
    private final int hashCount;

    public SimpleBloomFilter(int size, int hashCount) {
        this.bits = new BitSet(size);
        this.size = size;
        this.hashCount = hashCount;
    }

    public void add(String value) {
        for (int i = 0; i < hashCount; i++) {
            int hash = hash(value, i);
            bits.set(hash);
        }
    }

    public boolean mightContain(String value) {
        for (int i = 0; i < hashCount; i++) {
            int hash = hash(value, i);
            if (!bits.get(hash)) return false;
        }
        return true;
    }

    private int hash(String value, int seed) {
        // 简化实现：不同 seed 产生不同 hash
        return Math.abs((value.hashCode() ^ seed * 0x9E3779B9) % size);
    }
}
```

### 3.3 海量数据去重

假设需要处理 10 亿个 URL，判断哪些已访问过：

```java
// 使用 HashSet 会爆内存（10亿 × 引用 ≈ 40GB+）
// 使用 BitSet：只需要 10亿/8 ≈ 125MB

BitSet visited = new BitSet(1_000_000_000);

void visit(String url) {
    int hash = Math.abs(url.hashCode() % 1_000_000_000);
    if (!visited.get(hash)) {
        visited.set(hash);
        process(url);
    }
}
```

**注意**：哈希冲突会导致误判，实际项目中可能需要结合多个哈希函数或使用布隆过滤器。

---

## 四、面试常见追问

### Q1：`BitSet` 是线程安全的吗？
不是。如果需要线程安全，可以在外部加锁，或者使用 `Collections.synchronizedSet()` 包装，但更好的方案是用 `AtomicLongArray` 实现自己的线程安全位集。

### Q2：为什么 `1L << 64` 的结果不是 0？
Java 语言规范规定，long 移位只取移位量的低 6 位（0~63）：
```java
1L << 64;   // 等价于 1L << (64 & 0x3F) = 1L << 0 = 1
1L << -1;   // 等价于 1L << (-1 & 0x3F) = 1L << 63
```
这是一个常见的坑，BitSet 内部依赖这个特性来正确处理 `1L << (index % 64)`。

### Q3：`BitSet` 的 `cardinality()` 如何高效计算？
`BitSet` 通过 `Long.bitCount()` 计算每个 long 中 1 的个数：
```java
public int cardinality() {
    int sum = 0;
    for (int i = 0; i < wordsInUse; i++)
        sum += Long.bitCount(words[i]);
    return sum;
}
```
`Long.bitCount()` 是 JDK 的 intrinsic 方法，会被 JIT 编译为 CPU 的 `popcount` 指令（一条指令完成）。

### Q4：BitSet 和 Redis Bitmap 有什么区别？
Redis Bitmap 是分布式位图，支持跨进程共享，而 BitSet 只在单 JVM 内。但底层原理相同——都是位数组 + 位运算。

---

## 总结

位运算和 BitSet 是 Java 高性能编程的重要工具：

1. **位运算**：比常规数学运算快一个数量级，适合权限控制、状态标记、掩码计算
2. **BitSet**：内存效率是 boolean[] 的 8 倍，支持高效批量位操作和动态扩容
3. **典型应用**：布隆过滤器、海量数据去重、权限系统、位标记状态机

实际开发中，当你的数据以"标志位"或"集合隶属关系"的形式存在，且对内存或性能敏感时，优先考虑位方案。
