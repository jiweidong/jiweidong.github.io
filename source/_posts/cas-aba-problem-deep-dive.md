---
title: 【面试必备】CAS 的 ABA 问题深度解析：从 ABA 复现到 AtomicStampedReference 与数据库版本号防重机制
date: 2026-08-30 10:00:00
tags:
  - Java
  - 并发
  - CAS
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【面试必备】CAS 的 ABA 问题深度解析：从 ABA 复现到 AtomicStampedReference 与数据库版本号防重机制

## 面试官：CAS 有个著名的 ABA 问题，你讲讲它是什么？怎么解决？

CAS（Compare And Swap，比较并交换）是无锁编程的基石，但它有一个经典陷阱：**ABA 问题**。很多人在面试时能背出「ABA 就是 A 变成 B 又变回 A」，但被追问「为什么这会有问题？AtomicStampedReference 是怎么解决的？数据库里有没有 ABA？」就卡壳了。这一篇从复现到源码，把 ABA 彻底讲透。

## 一、先复习：CAS 是什么

CAS 是一条 CPU 原子指令（`cmpxchg`），语义是：

> 如果内存当前值等于期望值 `expect`，就把它更新为 `update`，否则什么都不做；无论是否成功都返回当前值。

```java
// Java 中 CAS 的经典用法：AtomicInteger
AtomicInteger count = new AtomicInteger(0);

// 期望值是 0 时才更新为 1
count.compareAndSet(0, 1);   // 返回 true

// 期望值是 0 时更新失败（当前已是 1）
count.compareAndSet(0, 2);   // 返回 false
```

CAS 的三大优点：无锁、无阻塞、无上下文切换开销。它的问题也很著名：**只能保证「值没变」，不能保证「值没被改过」**——这就是 ABA 的根源。

## 二、ABA 问题到底是什么

### 2.1 问题定义

线程 1 读取共享变量，值为 **A**；随后线程 2 把它改成 **B**，又改回 **A**；线程 1 执行 CAS 时发现「当前值还是 A」，于是 CAS 成功——**但期间变量已经被改过两次了**。

```text
时间线：
T1 读取 → A
T2 修改 → A → B
T2 再改 → B → A
T1 CAS(A, C) → 成功！但中间的 B 去哪了？
```

### 2.2 为什么「改过又改回来」会有问题

表面看「值没变，CAS 成功没毛病」，但问题在于：**值相同 ≠ 状态没变**。在很多场景里，变量的值只是「状态」的投影，两次 A 之间可能发生了**对程序有影响的变化**。

## 三、经典复现场景：无锁栈

无锁栈（Treiber Stack）是 ABA 问题的教科书案例。栈顶操作 `pop` 时：

```java
// 无锁栈的 pop 操作
public class LockFreeStack<T> {
    private AtomicReference<Node<T>> top = new AtomicReference<>();

    static class Node<T> {
        final T value;
        volatile Node<T> next;
        Node(T value) { this.value = value; }
    }

    public T pop() {
        while (true) {
            Node<T> oldTop = top.get();
            if (oldTop == null) return null;
            Node<T> newTop = oldTop.next;
            if (top.compareAndSet(oldTop, newTop)) {
                return oldTop.value;
            }
            // 失败则自旋重试
        }
    }
}
```

### 3.1 线程交错复现 ABA

假设栈初始为 `A → B`（栈顶是 A，A 的 next 是 B）：

```text
线程 1：oldTop = A, newTop = B    ← 准备把栈顶从 A 换成 B
        然后线程 1 被挂起（时间片耗尽）

线程 2：pop() 得到 A
线程 2：pop() 得到 B（此时栈空了）
线程 2：push(A)  —— A 被复用！此时 A.next 已经被改成 null（或指向别处）
         栈变成 A → null

线程 1 恢复：CAS(top, A, B) —— 当前 top 还是 A！CAS 成功！
         但此时 B 早就被弹出去了，A.next 是 null
         栈变成了 B → ??? ，B 被重复返回，链表结构被破坏！
```

**核心问题**：线程 1 看到的「栈顶还是 A」是假象——这个 A 已经不是原来的 A 了（它被弹出过、被复用了）。CAS 用「值相等」骗过了自己。

### 3.2 不只是数据结构：ABA 的业务危害

| 场景 | ABA 的危害 |
| --- | --- |
| 无锁栈/队列 | 链表节点被复用，结构损坏、元素重复返回 |
| 账户余额 CAS | 余额 100 → 扣 100 → 充 100，中间那笔「扣款」的状态丢失 |
| 资源分配 | 资源被释放又分配给了别人，旧持有者 CAS 成功导致资源被双重占用 |

## 四、解决方案一：AtomicStampedReference（版本号）

### 4.1 原理：值 + 版本号打包

`AtomicStampedReference` 把「引用值」和「整数版本号（stamp）」打包成一个 `Pair` 对象，CAS 时**值和版本号必须同时匹配**才成功：

```java
AtomicStampedReference<String> ref = new AtomicStampedReference<>("A", 0);

// 修改时带上版本号
ref.compareAndSet("A", "B", 0, 1);   // 期望值 A、期望版本 0 → 成功，版本变为 1

// 线程 1 的场景：
int[] stampHolder = new int[1];
String current = ref.get(stampHolder);   // 读取值和当前版本
int stamp = stampHolder[0];
// 即使值还是 A，只要版本号变了，CAS 就会失败
boolean ok = ref.compareAndSet(current, "C", stamp, stamp + 1);
```

### 4.2 无锁栈的正确写法

```java
public class LockFreeStack<T> {
    private AtomicStampedReference<Node<T>> top = new AtomicStampedReference<>(null, 0);

    public T pop() {
        int[] stampHolder = new int[1];
        while (true) {
            Node<T> oldTop = top.get(stampHolder);
            int stamp = stampHolder[0];
            if (oldTop == null) return null;
            Node<T> newTop = oldTop.next;
            if (top.compareAndSet(oldTop, newTop, stamp, stamp + 1)) {
                return oldTop.value;
            }
        }
    }
}
```

**关键**：每成功操作一次，版本号 +1。即使值从 A 变 B 又变回 A，版本号也回不去了——ABA 被版本号「盯死」。

### 4.3 源码剖析：为什么它能防 ABA

```java
// JDK 源码：AtomicStampedReference 内部结构
private static class Pair<T> {
    final T reference;   // 引用值
    final int stamp;     // 版本号
    private Pair(T reference, int stamp) {
        this.reference = reference;
        this.stamp = stamp;
    }
    static <T> Pair<T> of(T reference, int stamp) {
        return new Pair<T>(reference, stamp);
    }
}

private volatile Pair<T> pair;   // 值 + 版本号原子地绑定在一起

public boolean compareAndSet(T expectedReference, T newReference,
                             int expectedStamp, int newStamp) {
    Pair<T> current = pair;
    return expectedReference == current.reference &&   // 引用相等
           expectedStamp == current.stamp &&           // 版本相等（关键！）
           ((newReference == current.reference && newStamp == current.stamp) ||
            casPair(current, Pair.of(newReference, newStamp)));
}
```

**注意**：stamp 是 `int`，普通 `int` 读写本身就是原子的，所以 Pair 里的 reference 和 stamp 不存在「读到一半」的问题；而 pair 是 `volatile`，保证可见性。整个 CAS 变成「对 Pair 对象的 CAS」——版本号跟着值一起变，ABA 无机可乘。

### 4.4 AtomicMarkableReference：只关心「改没改过」

有些场景我们只关心「这个值是否被动过」，不关心动过几次，这时可以用 `AtomicMarkableReference`——它只有 boolean 标记位：

```java
AtomicMarkableReference<String> ref = new AtomicMarkableReference<>("A", false);
ref.compareAndSet("A", "B", false, true);   // 标记从 false → true
```

典型用途：**标记资源是否已被释放**（如 `ReentrantReadWriteLock` 内部就用了类似思路处理「写锁是否被持有过」）。区别一句话：

| 类 | 附带信息 | 能检测 |
| --- | --- | --- |
| AtomicStampedReference | int 版本号（可多次递增） | 改动次数/版本演进 |
| AtomicMarkableReference | boolean 标记 | 是否被动过（只关心有无） |

## 五、解决方案二：数据库里的 ABA（版本号机制）

### 5.1 数据库 CAS：UPDATE ... WHERE 条件

数据库里的 ABA 同样经典。比如「余额扣减」用 CAS 写法：

```sql
-- 线程 1：期望余额 100，扣成 90
UPDATE account SET balance = 90 WHERE id = 1 AND balance = 100;
-- 如果中间余额被改成 50 又改回 100，这条 SQL 依然会成功！—— 这就是数据库版 ABA
```

### 5.2 版本号方案（乐观锁）

解决方式就是**乐观锁版本号**——和 AtomicStampedReference 的思路一模一样：

```sql
-- 1. 查询时带上版本号
SELECT id, balance, version FROM account WHERE id = 1;
-- 结果：balance=100, version=3

-- 2. 更新时校验版本号，并让版本号 +1
UPDATE account
SET balance = 90, version = version + 1
WHERE id = 1 AND version = 3;
-- 影响行数 = 1 表示成功；= 0 表示版本已被别人改过，重试
```

```java
// MyBatis 乐观锁写法
@Update("UPDATE account SET balance = #{balance}, version = version + 1 " +
        "WHERE id = #{id} AND version = #{version}")
int updateWithVersion(Account account);

// 业务代码
Account acc = accountMapper.selectById(1);
acc.setBalance(acc.getBalance() - 10);
int rows = accountMapper.updateWithVersion(acc);
if (rows == 0) {
    throw new OptimisticLockException("数据已被修改，请刷新重试");
}
```

**对比**：

| 对比项 | Java CAS + ABA | 数据库 CAS + ABA |
| --- | --- | --- |
| 问题根源 | 值相同 ≠ 状态没变 | 同上 |
| 解法 | AtomicStampedReference（stamp） | version 字段（乐观锁） |
| 本质 | 值 + 版本号一起比较 | WHERE 里加 version 条件 + 自增 |
| 失败处理 | 自旋重试 | 返回影响行数 0，业务层重试/报错 |

### 5.3 其他数据库防 ABA 手段

- **时间戳字段**：`WHERE update_time = 旧值`，但时间戳精度不够时可能漏判（秒级时间戳并发下容易撞车）；
- **唯一约束/唯一键**：用业务唯一键约束直接堵死「重复状态」；
- **分布式锁 + 版本号双保险**：分布式锁防并发，版本号防 ABA，两者互补。

## 六、面试高频追问汇总

**Q1：ABA 的本质是什么？**
A：CAS 只校验「当前值 == 期望值」，但无法知道值是否「被改过又改回来」。当值只是状态投影时，两次相同的值可能代表完全不同的状态，导致 CAS 误判成功。

**Q2：为什么 AtomicStampedReference 能解决？**
A：它把值和 int 版本号绑定成一个不可变 Pair，CAS 必须「值相等且版本号相等」才成功；每次修改版本号 +1，版本号单调递增，永远回不到旧值，ABA 的「A→B→A」在版本号维度上不成立。

**Q3：stamp 用 int，会不会溢出？**
A：理论上会（约 21 亿次修改），但实际场景几乎不可能；如果真有这种极端场景，可以用 LongAdder 思路扩展或换方案。

**Q4：数据库乐观锁和 AtomicStampedReference 是一回事吗？**
A：思想完全一致——都是「值 + 版本号」双重校验。区别在载体：一个是 Java 内存变量，一个是数据库行；失败处理也不同：Java 自旋重试，数据库靠影响行数判断后由业务层处理。

**Q5：什么场景下 ABA 无伤大雅？**
A：只关心「最终值」的场景（如计数器累加、无状态标志位），ABA 不影响正确性；只有「中间过程有意义」的场景（链表结构、资源占用、金额流水）才必须防。

## 七、总结

| 层级 | 防 ABA 手段 | 适用场景 |
| --- | --- | --- |
| Java 并发 | AtomicStampedReference（stamp） | 无锁数据结构、引用型共享变量 |
| Java 并发 | AtomicMarkableReference（mark） | 只关心「是否被动过」 |
| 数据库 | version 乐观锁字段 | 行数据更新、金额扣减 |
| 数据库 | 唯一约束/时间戳 | 从数据模型层面杜绝重复状态 |
| 业务层 | 分布式锁 + 版本号 | 高并发写 + 强一致性要求 |

**一句话总结**：ABA 问题的本质是「CAS 只认值不认过程」，解法万变不离其宗——**给状态加一个单调递增的版本号，让「变回去」在版本维度上永远不可能**。面试时先讲无锁栈复现（体现你真的懂），再对比 AtomicStampedReference 与数据库乐观锁（体现举一反三），这道题稳拿高分。
