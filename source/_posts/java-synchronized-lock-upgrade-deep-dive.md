---
title: 「面试官：谈谈 synchronized 的锁升级过程？」从偏向锁到重量级锁全解析
date: 2026-06-28 08:00:00
tags:
  - Java
  - 并发
  - JVM
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 「面试官：谈谈 synchronized 的锁升级过程？」从偏向锁到重量级锁全解析

## 面试开场

**面试官**：你平时用 synchronized 做同步吗？知道它的锁升级机制吗？

**我**：synchronized 在 JDK 6 之后引入了锁升级（锁膨胀）机制，不再是早期的纯重量级锁。锁的状态会从**无锁 → 偏向锁 → 轻量级锁 → 重量级锁**，且方向不可逆。

这是一道非常经典的并发面试题，几乎涵盖了 JVM、对象头、Mark Word、CAS、操作系统互斥量等多个知识点。今天就彻底把它讲透。

---

## 一、锁升级的背景：JDK 6 之前的 synchronized

在 JDK 6 之前，synchronized 的实现依赖于操作系统的 **Mutex Lock（互斥量）**，每次加锁/解锁都需要从用户态切换到内核态，这个切换成本非常高。因此早期大家都说 synchronized 是"重量级锁"，性能不如 java.util.concurrent 包中的 Lock。

JDK 6 对 synchronized 做了**大量优化**，引入了一系列的锁优化技术：

| 优化技术 | 说明 |
|---------|------|
| 偏向锁（Biased Locking） | 同一个线程多次获取同一把锁时，消除CAS开销 |
| 轻量级锁（Lightweight Locking） | 多线程交替执行，使用CAS自旋而非挂起线程 |
| 自适应自旋（Adaptive Spinning） | 根据上次自旋结果动态调整自旋次数 |
| 锁消除（Lock Elimination） | JIT 编译时发现不可能有竞争的锁直接去掉 |
| 锁粗化（Lock Coarsening） | 将多个连续的锁操作合并为一个 |

其中最有话题性的就是**锁升级流程**。

---

## 二、对象头与 Mark Word——锁的存储基石

要理解锁升级，首先要看懂 Java 对象在内存中的布局。

### 对象内存布局

```
|------------------|------------------|----------------|
|   Mark Word      |  Klass Pointer   |   Instance     |
|   (8字节/64位)   |   (8字节压缩后4) |      Data      |
|------------------|------------------|----------------|
```

**Mark Word** 是对象头的核心，它记录了对象运行时的数据，包括：
- 锁状态（偏向锁、轻量锁、重量锁等）
- 哈希码（identity hashcode）
- GC 分代年龄
- 偏向线程 ID

### Mark Word 的位结构（64位 JVM）

```
|----------------------|----------|--------|------|
| 状态                 | 锁标志位  | 是否偏向 | 存储内容 |
|----------------------|----------|--------|------|
| 无锁（Normal）       | 01       | 0      | hashCode(25)+age(4)+biased(1)+(01) |
| 偏向锁（Biased）     | 01       | 1      | thread(54)+epoch(2)+age(4)+biased(1)+(01) |
| 轻量级锁（Lightweight）| 00      | -      | 指向栈中锁记录的指针 |
| 重量级锁（Heavyweight）| 10      | -      | 指向互斥量的指针 |
| GC 标记              | 11       | -      | 空（GC时使用） |
```
> 锁标志位共 2 位，加上 1 位 biased（是否可偏向），共同决定锁状态。

关键点：**Mark Word 的存储内容会随锁状态变化而动态复用**，这也是为什么一个对象在没有哈希码时可以先进入偏向锁，但一旦调用了 `hashCode()` 就无法再进入偏向锁——因为 Mark Word 存了哈希码，没位置存线程 ID 了。

---

## 三、锁升级全过程图解

```
     无锁 (Normal)
         │
         ▼   偏向锁启用，线程第一次获取锁
     偏向锁 (Biased)
         │
         ▼   另一个线程尝试获取 → 撤销偏向
     轻量级锁 (Lightweight Lock)
         │
         ▼   自旋失败 → 膨胀
     重量级锁 (Heavyweight Lock)
```

> ⚠️ 锁升级是**单向不可逆**的，一旦升级为重量级锁就不会降级。

### 第一步：无锁 → 偏向锁

**触发条件**：无锁状态的对象，被某个线程第一次获取 synchronized 锁时，且 JVM 启用了偏向锁（JDK 8 默认启用，JDK 15+ 默认关闭且 JDK 21 已移除）。

**流程**：
1. 线程 A 到达同步块，JVM 检查对象是否是"可偏向"状态（Mark Word 最后 3 位为 `101`）
2. 使用 CAS 将 Mark Word 中的 Thread ID 设置为当前线程 ID（偏向锁模式）
3. 如果成功：线程 A 获得偏向锁，之后进出同步块**不需要任何 CAS 或操作系统互斥**
4. 如果失败：说明存在竞争，进入偏向锁撤销流程

**偏向锁的意义**：消除同一个线程反复加锁/解锁的 CAS 开销。在单线程交替执行同一个同步块的场景中，偏向锁几乎零开销。

### 第二步：偏向锁 → 轻量级锁

**触发条件**：另一个线程 B 尝试获取这个已被线程 A 偏向锁定的对象。

**偏向锁撤销流程**：
1. 线程 B 检查 Mark Word，发现偏向线程 A（Thread ID == A）
2. 在**全局安全点**（SafePoint）暂停线程 A
3. 检查线程 A 是否还存活
   - 若已死亡：将对象头置为无锁状态或直接升级为轻量级锁
   - 若存活：检查 A 是否还在用这个锁
     - 若 A 不在同步块：将对象头置为无锁，重新偏向 B
     - 若 A 仍在同步块：撤销偏向，膨胀为轻量级锁
4. 恢复所有暂停线程

**偏向锁撤销的代价很大**！需要在全局安全点暂停所有线程，这本身就有 STW 的开销。因此对高竞争场景，偏向锁反而会成为性能瓶颈（这就是为什么 JDK 15+ 默认关闭偏向锁）。

### 第三步：轻量级锁 → 重量级锁

**触发条件**：多个线程同时竞争同一把轻量级锁，且 CAS 自旋超过阈值。

**轻量级锁加锁过程**：
1. 线程在自己的栈帧中创建 **Lock Record（锁记录）**
2. 将 Lock Record 中的 `Displaced Mark Word` 复制为当前 Mark Word
3. 尝试用 CAS 将对象头的 Mark Word 替换为指向 Lock Record 的指针
4. CAS 成功：获得锁
5. CAS 失败：说明有另一个线程已持有锁，进入**自旋**

**自旋优化**：
- JDK 6 前：固定自旋次数（默认 10 次）
- JDK 6+：**自适应自旋**，JVM 根据上一次在同一个锁上的自旋结果动态调整
  - 上次自旋成功了 → 这次多等一会儿
  - 上次自旋没成功 → 少等一会儿甚至直接挂起

**膨胀为重量级锁**：
1. 自旋超过阈值后，轻量级锁膨胀为重量级锁
2. 申请操作系统 Mutex Lock
3. 未获取到锁的线程进入阻塞状态（BLOCKED）
4. Mark Word 更新为指向重量级锁的指针（monitor 地址）
5. 锁标志位变为 `10`

---

## 四、源码角度验证锁升级

我们用一个简单的示例来观察锁升级行为：

```java
public class LockUpgradeDemo {

    static final Object lock = new Object();

    public static void main(String[] args) throws Exception {
        // 为了观察偏向锁，先让锁对象处于无锁可偏向状态
        System.out.println(ClassLayout.parseInstance(lock).toPrintable());
        
        synchronized (lock) {
            System.out.println("=== 线程A 获取锁 ===");
            System.out.println(ClassLayout.parseInstance(lock).toPrintable());
        }

        Thread.sleep(3000);
        System.out.println("=== 线程A 释放锁后 ===");
        System.out.println(ClassLayout.parseInstance(lock).toPrintable());

        Thread threadB = new Thread(() -> {
            synchronized (lock) {
                System.out.println("=== 线程B 获取锁 ===");
                System.out.println(ClassLayout.parseInstance(lock).toPrintable());
            }
        });
        threadB.start();
        threadB.join();
    }
}
```
> 需要引入 JOL（Java Object Layout）依赖：`org.openjdk.jol:jol-core`

运行结果大致可以看到：
```
OFFSET  SIZE   TYPE DESCRIPTION                    VALUE
0      4          (object header)                 05 00 00 00 (00000101)  → 偏向锁+无偏线程
// 加锁后：偏向线程ID指向线程A
0      4          (object header)                 05 48 e8 03 → 偏向线程A
// 线程B竞争后：变为轻量级锁
0      4          (object header)                 a8 f5 2e 02 → 指向Lock Record
// 进一步竞争：变为重量级锁
0      4          (object header)                 7a 36 1b 0b → 指向Monitor
```

---

## 五、面试追问高频考点

### Q1：为什么调用了 hashCode() 后不能进入偏向锁？

因为偏向锁的 Mark Word 只有 54 位存线程 ID，而 hashCode 需要 25 位偏存储空间。当对象调用了 `hashCode()`，Mark Word 中已经存了哈希码，没有空间再存线程 ID，所以只能作为**无锁不可偏向**状态。

如果对象已处于偏向锁，再调用 `hashCode()`，会直接撤销偏向锁，升级为重量级锁（因为轻量锁的 Mark Word 也没有位置存 hashCode）。

所以：**偏向锁和无锁状态的 hashCode 不能共存**。

### Q2：重量级锁的 Monitor 是什么？

Monitor 是操作系统层面的同步机制，在 Java 中对应 `ObjectMonitor`，每个 Java 对象关联一个 Monitor（通过 `ObjectSynchronizer::inflate` 膨胀）：

```cpp
// ObjectMonitor 核心结构（简化）
ObjectMonitor {
    volatile markOop   _header;      // 对象头
    void*              _object;      // 关联的对象
    void*              _owner;       // 持有锁的线程
    ObjectWaiter*      _WaitSet;     // wait() 等待队列
    ObjectWaiter*      _EntryList;   // 等待锁的 BLOCKED 队列
    volatile intptr_t  _count;       // 递归计数
};
```

重量级锁下，未获取锁的线程进入 `_EntryList`，被 `park()` 挂起；持有锁的线程调用 `wait()` 时进入 `_WaitSet`。`notify/notifyAll` 从 WaitSet 移回 EntryList。

### Q3：锁消除和锁粗化是什么？

**锁消除**：
```java
public String concat(String s1, String s2) {
    StringBuffer sb = new StringBuffer();  // StringBuffer 的方法都加了 synchronized
    sb.append(s1);                         // JIT 发现 sb 是局部变量，不会逃逸
    sb.append(s2);                         // 直接消除锁操作
    return sb.toString();
}
```

**锁粗化**：
```java
public void append() {
    StringBuffer sb = new StringBuffer();
    for (int i = 0; i < 100; i++) {
        sb.append(i);  // 每次 append 都要加锁解锁
    }
    // JIT 粗化为：在最外层加一次锁，循环结束后释放
}
```

### Q4：为什么 JDK 15 默认关闭偏向锁？

因为偏向锁的撤销需要在**全局安全点**执行，当高并发下频繁发生偏向锁撤销时，带来的 STW 和撤销开销反而大于其带来的收益。JDK 15 默认禁用了偏向锁，JDK 21 甚至彻底移除了偏向锁实现。

> `-XX：-UseBiasedLocking` JDK 15 后默认就是 false

### Q5：synchronized 和 ReentrantLock 怎么选？

| 维度 | synchronized | ReentrantLock |
|------|-------------|---------------|
| 锁机制 | 对象头 Monitor + JVM | AQS + CAS + LockSupport |
| 灵活性 | 固定非公平 | 公平/非公平可配置 |
| 等待可中断 | 不支持 | 支持 lockInterruptibly() |
| 超时 | 不支持 | 支持 tryLock(timeout) |
| 条件等待 | 只能 wait/notify | 多个 Condition |
| 性能 | 优化后与 ReentrantLock 相当 | 相当 |

**建议**：新代码推荐用 `synchronized`（简洁、无忘记释放风险），需要超时/中断/多条件等高级功能时用 `ReentrantLock`。

---

## 六、总结

回到面试官的问题，一句话总结锁升级：

> 在 JDK 6 之后，synchronized 不再是单纯的重量级锁。JVM 会根据锁的竞争情况，自动将锁从无锁 → 偏向锁 → 轻量级锁 → 重量级锁单向升级，配合自适应自旋、锁消除、锁粗化等优化，使得 synchronized 在大多数场景下性能与 ReentrantLock 相当甚至更好。

理解锁升级，本质上是理解了**操作系统内核态/用户态切换成本**与**用户态 CAS 自旋成本**之间的权衡——能用 CAS 解决的就别挂起线程，这是所有并发优化的底层逻辑。
