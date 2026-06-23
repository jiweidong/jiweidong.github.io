---
title: Java 对象内存布局深度解析：对象头、Mark Word、指针压缩与 JOL 实战
date: 2026-06-23 08:04:00
tags:
  - JVM
  - 内存
  - 性能优化
categories:
  - Java
  - JVM
author: 东哥
---

# Java 对象内存布局深度解析：对象头、Mark Word、指针压缩与 JOL 实战

## 面试官：一个 Object 对象在内存中占多少字节？

"8 字节？16 字节？" —— 能准确回答这个问题的 Java 开发者不超过 20%。

## 一、Java 对象的内存布局

一个 Java 对象在堆内存中分为三部分：

```
┌──────────────────────────────────────────────┐
│              对象头 (Object Header)           │
│  ├─ Mark Word (标记字)                        │
│  └─ klass pointer (类型指针)                  │
├──────────────────────────────────────────────┤
│              实例数据 (Instance Data)          │
├──────────────────────────────────────────────┤
│              对齐填充 (Padding)                │
└──────────────────────────────────────────────┘
```

### 1.1 对象头 (Object Header)

**Mark Word**：存储对象运行时数据

| 位数 (64 位 JVM) | 内容 |
|------------------|------|
| 8 bytes (64 bit) | Mark Word |

Mark Word 在不同锁状态下复用存储：

| 锁状态 | 锁标志位 | Mark Word 内容（64位） |
|--------|---------|----------------------|
| 无锁 | 01 | unused(25) + identity_hashcode(31) + unused(1) + age(4) + biased_lock(1) + lock(2) |
| 偏向锁 | 01 | thread_id(54) + epoch(2) + unused(1) + age(4) + biased_lock(1) + lock(2) |
| 轻量级锁 | 00 | ptr_to_lock_record(62) + lock(2) |
| 重量级锁 | 10 | ptr_to_monitor(62) + lock(2) |
| GC 标记 | 11 | 空 (mark 用于 GC 转发) |

**klass pointer**：指向类的元数据指针

```
Mark Word (8 bytes) + klass pointer (4 or 8 bytes) = 12 or 16 bytes
```

### 1.2 实例数据

存放对象的成员变量。HotSpot 对字段有**重排序**规则：

```
字段重排序规则（按大小从大到小）：
1. doubles / longs     (8 bytes)
2. ints / floats       (4 bytes)
3. shorts / chars      (2 bytes)
4. booleans / bytes    (1 byte)
5. references          (4 or 8 bytes)
6. 子类字段排在父类之后
```

### 1.3 对齐填充

Java 对象大小必须是 **8 字节的倍数**（HotSpot 要求）。不够就 padding。

## 二、JOL 实战：动手看对象布局

### 2.1 引入 JOL

```xml
<dependency>
    <groupId>org.openjdk.jol</groupId>
    <artifactId>jol-core</artifactId>
    <version>0.17</version>
</dependency>
```

### 2.2 一个空 Object 占多大？

```java
public class JOLSample {
    public static void main(String[] args) {
        Object obj = new Object();
        // 打印 VM 详情
        System.out.println(VM.current().details());
        // 打印对象布局
        System.out.println(ClassLayout.parseInstance(obj).toPrintable());
    }
}
```

**输出（64 位 JVM，指针压缩开启）：**

```
# Running 64-bit HotSpot VM.
# Objects are 8 bytes aligned.
# Field sizes by type: 4, 1, 1, 2, 2, 4, 4, 8, 8 [bytes]
# Array base offsets: 8, 4, 0, 0, 0, 0, 0, 0, 0 [bytes]

java.lang.Object object internals:
OFF  SZ   TYPE DESCRIPTION               VALUE
  0   8        (object header: mark)     0x0000000000000001 (non-biasable)
  8   4        (object header: class)    0x00000af4
 12   4        (loss due to the next object alignment)
Instance size: 16 bytes
Space losses: 0 bytes internal + 4 bytes external = 4 bytes total
```

> **结果：一个空的 Object 占 16 字节**（Mark Word 8 + klass pointer 4 + padding 4）

### 2.3 查看各种类型的大小

```java
// Boolean - 16 bytes
Boolean b = Boolean.TRUE;

// Integer - 16 bytes  
Integer i = 128;

// Long - 24 bytes（8 + 4 + 4 = 16，但 Long 内部有 8 字节 value）
```

### 2.4 自定义对象

```java
public class MyObject {
    private boolean flag = true;   // 1 byte
    private int id = 1;            // 4 bytes
    private long value = 100L;    // 8 bytes
    private Object ref = null;    // 4 bytes (compressed oop)
    private byte b = 0;           // 1 byte
    private short s = 0;          // 2 bytes
}
```

JOL 输出：

```
OFF  SZ   TYPE         DESCRIPTION       VALUE
  0   8                 (object header: mark)   0x0000000000000001
  8   4                 (object header: class)  0xf800cd25
 12   4                 (alignment/padding gap)  
 16   8   long          MyObject.value          100
 24   4   int           MyObject.id             1
 28   2   short         MyObject.s              0
 30   1   byte          MyObject.b              0
 31   1   boolean       MyObject.flag           true
 32   4   Object        MyObject.ref            null
 36   4                 (loss due to the next object alignment)
Instance size: 40 bytes
```

**注意：** HotSpot 重排序后，long 在最前面，接着是 int→short→byte→boolean→reference。

## 三、指针压缩（Compressed OOPs）

### 3.1 为什么需要指针压缩？

64 位 JVM 中，引用指针占 8 字节。如果堆内存 < 32GB，指针压缩可以将引用变为 4 字节：

```
32GB 堆 / 8字节指针 = 4G 个对象引用
32GB 堆 / 4字节压缩指针 = 8G 个对象引用
```

**开启压缩（默认开启）：** `-XX:+UseCompressedOops`
**关闭压缩：** `-XX:-UseCompressedOops`

### 3.2 指针压缩原理

压缩原理：对象地址都是 **8 字节对齐**的，所以地址后 3 位总是 0。存储时右移 3 位去掉末尾零，使用时左移 3 位恢复：

```
实际地址: 0x7FFF_FF00_0008
存储时:   0xFFFF_FE00_0001  (右移3位)
使用时:   0x7FFF_FF00_0008  (左移3位)
```

```java
// JVM 底层实现大致逻辑
class CompressedOops {
    long encode(long rawAddress) {
        if (isHeapBelow32GB) {
            // 右移 3 位，压缩成 32 位
            return rawAddress >>> 3;
        }
        return rawAddress; // 不压缩
    }

    long decode(long compressed) {
        if (isHeapBelow32GB) {
            // 左移 3 位，恢复完整地址
            return compressed << 3;
        }
        return compressed;
    }
}
```

### 3.3 指针压缩的影响

| 场景 | 开启压缩 | 关闭压缩 | 差值 |
|------|---------|---------|------|
| Object | 16 字节 | 16 字节 | 0（需要 padding） |
| Integer | 16 字节 | 24 字节 | 8 字节 |
| MyObject(6字段) | 40 字节 | 48 字节 | 8 字节 |
| String (JDK 17) | 24 字节 | 32 字节 | 8 字节 |

### 3.4 什么情况下指针压缩失效？

```java
// 堆 > 32GB 自动关闭指针压缩
java -Xmx40g MyApp
// 显式关闭
java -XX:-UseCompressedOops -Xmx20g MyApp
```

## 四、数组对象内存布局

数组对象比普通对象多了一个 **数组长度**（4字节）：

```
┌──────────────────────────────────────┐
│  Mark Word (8 bytes)                  │
├──────────────────────────────────────┤
│  klass pointer (4 bytes compressed)   │
├──────────────────────────────────────┤
│  array length (4 bytes)               │  ← 数组特有
├──────────────────────────────────────┤
│  array[0]                             │
│  array[1]                             │
│  ...                                  │
├──────────────────────────────────────┤
│  padding (8 字节对齐)                  │
└──────────────────────────────────────┘
```

```java
int[] arr = new int[10];
// JOL Output:
// Mark Word: 8 bytes
// Klass: 4 bytes
// Length: 4 bytes
// Data: 10 * 4 = 40 bytes
// Padding: 0 bytes (40 is multiple of 8)
// Total: 56 bytes
```

**对比：** `int[10]` 占 56 字节，`Integer[10]` 占约 **176 字节**（56 字节数组头 + 10 × 12 字节 Integer 对象引用）。

## 五、锁升级与对象头变化

### 5.1 无锁 → 偏向锁

```java
// 无锁状态：Mark Word 无 hashcode
MyObject obj = new MyObject();
System.out.println(ClassLayout.parseInstance(obj).toPrintable());

// 调用 hashCode 后，偏向锁不可用
obj.hashCode();
System.out.println(ClassLayout.parseInstance(obj).toPrintable());
```

关键：**一旦调用 hashCode()，mark word 中就没有空间存储偏向线程 ID 了，对象进入轻量级锁路径。**

### 5.2 轻量级锁

```java
synchronized (obj) {
    // Mark Word 变成指向 Lock Record 的指针
    System.out.println(ClassLayout.parseInstance(obj).toPrintable());
}
```

### 5.3 重量级锁

```java
// 多个线程竞争时，锁会升级
// Mark Word 变成指向 Monitor 的指针
```

## 六、实际应用：内存优化案例

### 案例 1：长连接 Session 对象

```java
// 优化前：使用包装类型
public class Session {
    private Long userId;          // 24 bytes (Long对象)
    private Long createTime;      // 24 bytes
    private Integer status;       // 16 bytes (Integer对象)
    private AtomicInteger count;  // 40 bytes + 对象引用
}
// 对象本身 ~72 bytes + 4个子对象 ~104 bytes = ~176 bytes

// 优化后：使用原生类型
public class Session {
    private long userId;          // 8 bytes
    private long createTime;      // 8 bytes
    private int status;           // 4 bytes
    private int count;            // 4 bytes
}
// ~40 bytes，节省 77% 内存！
```

### 案例 2：Boolean 缓存陷阱

```java
// Boolean.TRUE / Boolean.FALSE 是唯一实例
// 但 Boolean[] 和 boolean[] 天差地别
boolean[] flags = new boolean[1000];   // 1004 bytes
Boolean[] flagsObj = new Boolean[1000]; // 56 + 1000*4 + 1000*16 + padding ≈ 20504 bytes

// boolean 比 Boolean 节省 20 倍内存！
```

### 案例 3：字符串去重

```java
// JDK 17 String 内部
// char[] (或 byte[]) + coder + hash = 24 bytes (对象头) + char[] 引用 + 2个int
// 字符串去重会复用底层 char[] 减少内存
```

## 七、JVM 对象内存对齐总结

| 对象类型 | 开启指针压缩 | 关闭指针压缩 | 说明 |
|---------|------------|------------|------|
| Object | 16 B | 16 B | 无实例数据，padding 额外 |
| new int[0] | 16 B | 24 B | 数组头多了 length(4B) |
| new String("a") | 24 B | 32 B | 包含 char[] 引用 |
| Boolean (value) | 16 B | 24 B | 包装对象开销大 |
| Long (value) | 24 B | 24 B | 包装 + 8 字节 value |

## 八、面试追问

> **Q：Java 对象为什么要求 8 字节对齐？**
> A：CPU 访问内存时，8 字节对齐可以减少访问次数。一个 8 字节的 long 如果跨了两个 cache line，需要两次读取 + 拼接，性能损失严重。

> **Q：-XX:+UseCompressedOops 能减少多少内存？**
> A：普遍减少 30%~50%。引用从 8 字节变成 4 字节，一个 HashMap 全部优化可减少 40%+ 内存。

> **Q：为什么堆超过 32GB 时指针压缩自动关闭？**
> A：压缩指针用 32 位（4 字节）表示地址，左移 3 位最大寻址 2^32 * 8 = 32GB。超出此范围，4 字节不够用。

> **Q：实际项目中怎么观测对象内存？**
> A：JOL 工具最直接，JMH + JOL 组合做基准测试；生产环境用 jmap -histo:live 看实例数，用 jcmd GC.class_stats 看更详细的分析。

---

**总结：** 理解 Java 对象内存布局是 JVM 调优的基础。对象头 12~16 字节、指针压缩的神奇效果、包装类型开销——这些知识能帮你写出更高效的内存敏感代码。不多说，赶紧打开 JOL 跑一跑，你对自己写的对象会有全新的认识。
