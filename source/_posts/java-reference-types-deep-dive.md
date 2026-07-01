---
title: 【深入Java】四种引用类型深度解析：强引用、软引用、弱引用、虚引用与 ReferenceQueue
date: 2026-07-01 08:00:00
tags:
  - Java
  - JVM
  - 内存管理
  - GC
categories:
  - Java
  - JVM
author: 东哥
---

# 【深入Java】四种引用类型深度解析：强引用、软引用、弱引用、虚引用与 ReferenceQueue

## 前言

Java 的垃圾回收（GC）机制让开发者从手动管理内存中解放出来，但你真的了解 JVM 是如何判断一个对象「该不该回收」的吗？除了最常见的强引用之外，Java 还提供了软引用、弱引用和虚引用，它们在不同的场景下发挥着重要作用。

本文将从源码层面深入剖析这四种引用类型，并结合 ReferenceQueue 分析其内部协作机制。

---

## 一、四种引用类型概览

| 引用类型 | 回收时机 | 典型用途 | 是否可 get() |
|---------|---------|---------|------------|
| 强引用 | 永不回收（除非不可达） | 普通 new 对象 | 是 |
| 软引用 | OOM 前回收 | 内存敏感缓存 | 是 |
| 弱引用 | 下次 GC 即回收 | ThreadLocal、WeakHashMap | 是 |
| 虚引用 | 任何时候 | 跟踪对象回收（NIO DirectBuffer） | 否 |

### 1. 强引用（Strong Reference）

这是最常见的引用类型，形如 `Object obj = new Object()`。只要强引用还存在，GC 就永远不会回收被引用的对象，即使抛出 OOM。

```java
Object obj = new Object();  // 强引用
obj = null;                 // 显式断开，对象变为可回收
```

### 2. 软引用（SoftReference）

软引用使用 `java.lang.ref.SoftReference<T>` 类实现。当 JVM 内存充足时，软引用对象不会被回收；但当 JVM 检测到即将发生 OOM 时，会 **在 OOM 之前** 回收所有软引用对象。

```java
SoftReference<byte[]> cache = new SoftReference<>(new byte[1024 * 1024 * 100]); // 100MB
byte[] data = cache.get(); // 如果未被回收，返回对象；否则返回 null
if (data == null) {
    // 重新加载
}
```

**最佳实践**：软引用非常适合实现内存敏感缓存。Guava Cache 和 MyBatis 缓存中都有类似实现思路。

**注意**：在高版本 JDK（如 JDK 11+）中，如果没有 `-XX:-SoftRefLRUPolicyMSPerMB` 调整，软引用的存活时间与最近 GC 间隔有关。

### 3. 弱引用（WeakReference）

弱引用使用 `java.lang.ref.WeakReference<T>` 类实现。弱引用对象 **只要 GC 发生就会被回收**，无论内存是否充足。

```java
WeakReference<Object> weakRef = new WeakReference<>(new Object());
System.gc();  // 显式触发 GC
System.out.println(weakRef.get()); // 大概率输出 null
```

**经典应用**：
- **ThreadLocal**：ThreadLocalMap 中的 Entry 继承了 WeakReference，key（ThreadLocal 实例）是弱引用，防止 ThreadLocal 无法被回收导致内存泄漏。
- **WeakHashMap**：键为弱引用，当键不再被强引用时自动移除条目。

```java
// ThreadLocalMap.Entry 源码（简化）
static class Entry extends WeakReference<ThreadLocal<?>> {
    Object value;
    Entry(ThreadLocal<?> k, Object v) {
        super(k); // key 作为弱引用
        value = v;
    }
}
```

### 4. 虚引用（PhantomReference）

虚引用使用 `java.lang.ref.PhantomReference<T>` 类实现。虚引用的 `get()` 方法永远返回 `null`，这意味着 **无法通过虚引用获取对象实例**。它唯一的作用是当对象被回收时，收到一个系统通知。

```java
ReferenceQueue<Object> queue = new ReferenceQueue<>();
PhantomReference<Object> phantomRef = new PhantomReference<>(new Object(), queue);
// phantomRef.get() 始终返回 null
```

**经典应用**：**NIO DirectByteBuffer 的堆外内存回收**。DirectByteBuffer 使用虚引用 + Cleaner 机制，在 DirectByteBuffer 对象被 GC 回收时，自动释放对应的堆外内存。

```java
// DirectByteBuffer 内部（简化）
class DirectByteBuffer {
    private Cleaner cleaner;
    
    DirectByteBuffer(int cap) {
        // ... 分配堆外内存
        cleaner = Cleaner.create(this, new Deallocator(address, size));
        // Cleaner 本质上利用了虚引用机制
    }
}
```

---

## 二、ReferenceQueue 的作用

引用队列 `ReferenceQueue` 是与三种引用类型（软、弱、虚）配合使用的核心机制。当引用对象所引用的对象被 GC 回收时，JVM 会将该 **引用对象本身**（而非被引用的对象）加入到关联的 ReferenceQueue 中。

```java
ReferenceQueue<Object> queue = new ReferenceQueue<>();
WeakReference<Object> ref = new WeakReference<>(new Object(), queue);

System.gc();
Thread.sleep(100); // 等待 GC 完成

Reference<?> removed = queue.poll(); // 非阻塞方式获取
if (removed == ref) {
    System.out.println("弱引用对象已被回收，ref 已入队");
}
```

**应用场景**：
- **资源清理**：当对象被回收时，从队列中取出 Reference，执行资源释放逻辑。
- **缓存失效通知**：配合软引用实现缓存，当缓存条目被回收时收到通知。

---

## 三、源码分析：Reference 内部机制

所有的引用类型都继承了 `java.lang.ref.Reference<T>` 抽象类。它的内部设计值得关注：

```java
public abstract class Reference<T> {
    private T referent;          // 被引用的对象
    volatile ReferenceQueue<? super T> queue; // 关联的引用队列
    volatile Reference next;     // 链表节点
    
    // 由 JVM 设置：表示该引用处于 pending 状态（referent 即将被回收）
    private static Reference<Object> pending = null;
    
    // JVM 层面的处理线程 ReferenceHandler
    private static class ReferenceHandler extends Thread {
        public void run() {
            while (true) {
                tryHandlePending(true); // 处理 pending 链表中的 Reference
            }
        }
    }
    
    static {
        Thread handler = new ReferenceHandler("Reference Handler");
        handler.setDaemon(true);
        handler.start();
    }
}
```

**核心流程**：
1. GC 检测到对象的引用强度不足，准备回收。
2. JVM 将对应的 Reference 对象放入 `pending` 链表。
3. `ReferenceHandler` 守护线程不断从 `pending` 链表中取出 Reference。
4. 如果关联了 `ReferenceQueue`，将 Reference 入队。
5. 同时会触发 `Cleaner` 的 `clean()` 方法（虚引用场景）。

---

## 四、面试常见追问

**Q1：为什么 ThreadLocal 的 key 要设计为弱引用？**

防止内存泄漏。如果 key 是强引用，即使业务代码中 ThreadLocal 对象已经不再使用（强引用断开），ThreadLocalMap 中的 Entry 仍然持有 ThreadLocal 的强引用，导致 ThreadLocal 无法被 GC，发生内存泄漏。设计为弱引用后，一旦外部强引用断开，下次 GC 就会被回收。

**Q2：有了弱引用为什么还要软引用？**

两种引用的回收策略不同。软引用只在内存不足时回收，适合缓存场景；弱引用每次 GC 都回收，回收更激进。缓存场景用软引用更合适，减少不必要的回收。

**Q3：虚引用为什么无法获取对象实例？**

虚引用的设计目的就是 **只跟踪回收事件，不干扰对象生命周期**。如果可以通过虚引用获取对象实例，可能会复活对象（finalize 机制），破坏了虚引用的设计语义。因此 `PhantomReference.get()` 强制返回 null。

**Q4：ReferenceQueue 和 finalize() 有什么区别？**

- `finalize()`：对象被回收前的回调，但执行时机不确定，性能差，JDK 9 已标记为 `@Deprecated`
- `ReferenceQueue`：由 `ReferenceHandler` 线程处理，效率高，回收实时性强

---

## 总结

| 类型 | 回收策略 | 可与 Queue 配合 | get() 可用 | 使用场景 |
|-----|---------|:----------:|:---------:|---------|
| 强引用 | 永不回收 | × | ✓ | 日常开发 |
| 软引用 | OOM 前回收 | ✓ | ✓ | 缓存系统 |
| 弱引用 | 下次 GC 回收 | ✓ | ✓ | ThreadLocal、WeakHashMap |
| 虚引用 | 任意时刻 | ✓ | ✗ | DirectBuffer 回收跟踪 |

理解 Java 的四种引用类型，不仅能帮你写出更健壮的代码，更是深入理解 JVM 内存管理和 GC 机制的关键一步。在面试中，这也是考察候选人对 Java 理解深度的高频考点。

> **下期预告**：我们将深入分析 JIT 即时编译技术——逃逸分析、栈上分配与标量替换的原理，敬请期待！
