---
title: 彻底搞懂 Java 四种引用类型：强软弱虚的原理、源码与应用场景
date: 2026-06-30 08:00:00
tags:
  - Java
  - JVM
  - 内存管理
categories:
  - Java
  - 深入Java
author: 东哥
---

# 彻底搞懂 Java 四种引用类型：强软弱虚的原理、源码与应用场景

## 面试官：Java 有哪几种引用类型？它们分别在什么场景下使用？

这是一道经典的 Java 进阶面试题，考察对 JVM 内存管理和垃圾回收的理解深度。本文将带你从源码到实战，彻底搞懂**强引用（Strong Reference）**、**软引用（SoftReference）**、**弱引用（WeakReference）** 和**虚引用（PhantomReference）**。

## 一、为什么需要多种引用类型？

在 Java 诞生初期，只有"强引用"这一种形式——只要对象可达，GC 就不会回收。这带来了一个问题：

> 当内存紧张时，某些**不那么重要**的对象（如缓存数据）能否先被回收，优先保障核心业务？

JDK 1.2 引入了 `java.lang.ref` 包，提供了三种新的引用类型，让开发者可以在「对象是否存活」这个决策上获得**更细粒度的控制权**。

四种引用类型的强度对比如下：

| 引用类型 | 回收时机 | 主要用途 | 是否可以拿到对象 |
|---------|---------|---------|---------------|
| 强引用 | 永不回收（OOM 才死） | 普通对象引用 | ✅ |
| 软引用 | 内存不足时回收 | 内存敏感缓存 | ✅ |
| 弱引用 | 下次 GC 就回收 | 缓存/容器（WeakHashMap） | ✅ |
| 虚引用 | 任何时候都可能回收 | 对象回收追踪（DirectBuffer 回收） | ❌ 永远拿不到 |

## 二、强引用

强引用就是我们最常写的代码：

```java
User user = new User();  // user 就是一个强引用
```

只要强引用还存在，GC 就**永远不会**回收被引用的对象，即使抛出 OOM 异常。

```java
public class StrongReferenceDemo {
    public static void main(String[] args) {
        Object obj = new Object();  // 强引用
        System.gc();
        System.out.println(obj);   // 对象还在，不会被回收
        
        obj = null;  // 取消强引用
        System.gc(); // 对象可以被回收了
    }
}
```

**注意：** 在方法内部使用局部变量时，即使没有显式设为 `null`，方法执行完后引用自动出栈，对象就会变得不可达。

## 三、软引用（SoftReference）

### 3.1 基本用法

```java
import java.lang.ref.SoftReference;

public class SoftReferenceDemo {
    public static void main(String[] args) {
        Object obj = new Object();
        SoftReference<Object> softRef = new SoftReference<>(obj);
        obj = null;  // 取消强引用，只剩软引用指向对象
        
        // 通过软引用获取对象
        Object ref = softRef.get();  // 内存充足时返回对象
        System.out.println(ref);     // 不为 null
    }
}
```

### 3.2 源码分析

```java
public class SoftReference<T> extends Reference<T> {
    // JVM 会保证软引用引用的对象在 OOM 之前被清除
    // 具体的清除时机由 GC 策略决定
    static private long clock;
    private long timestamp;
    
    public SoftReference(T referent) {
        super(referent);
        this.timestamp = clock;
    }
    
    public SoftReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
        this.timestamp = clock;
    }
}
```

`Reference` 类的核心字段：

```java
public abstract class Reference<T> {
    private T referent;         // 被引用的对象
    volatile ReferenceQueue<? super T> queue;  // 关联的引用队列
    volatile Reference next;    // 队列中的下一个
    transient private Reference<T> discovered; // GC 发现队列
    static private Lock lock;
    private static Reference<Object> pending;  // 待处理的引用链表
}
```

### 3.3 GC 回收策略

软引用对象的回收时机由 JVM 参数 `-XX:SoftRefLRUPolicyMSPerMB` 控制（默认 1000ms）：

> 公式：`clock - timestamp <= SoftRefLRUPolicyMSPerMB * HeapSizePerMB`

即：**软引用存活时间 ≤ 每 MB 堆空间允许的存活时间**。堆越大，软引用存活越久。

### 3.4 最佳实践：内存敏感缓存

```java
public class ImageCache {
    private static final int CACHE_CAPACITY = 100;
    private final Map<String, SoftReference<BufferedImage>> cache = 
        new LinkedHashMap<>(CACHE_CAPACITY, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, SoftReference<BufferedImage>> eldest) {
                return size() > CACHE_CAPACITY;
            }
        };
    
    public BufferedImage get(String key) throws IOException {
        SoftReference<BufferedImage> ref = cache.get(key);
        if (ref != null) {
            BufferedImage image = ref.get();
            if (image != null) {
                return image;  // 缓存命中
            }
            // 软引用已被 GC 回收
            cache.remove(key);
        }
        // 从磁盘重新加载
        BufferedImage image = loadFromDisk(key);
        cache.put(key, new SoftReference<>(image));
        return image;
    }
    
    private BufferedImage loadFromDisk(String key) throws IOException {
        return ImageIO.read(new File("/images/" + key + ".png"));
    }
}
```

## 四、弱引用（WeakReference）

### 4.1 基本用法

```java
import java.lang.ref.WeakReference;

public class WeakReferenceDemo {
    public static void main(String[] args) {
        Object obj = new Object();
        WeakReference<Object> weakRef = new WeakReference<>(obj);
        obj = null;  // 取消强引用
        
        System.gc();  // 触发 GC
        
        System.out.println(weakRef.get());  // null！弱引用已被回收
    }
}
```

输出结果：

```
null
```

**关键区别：** 软引用在内存不足时才回收，弱引用**只要 GC 运行就回收**。

### 4.2 源码简析

```java
public class WeakReference<T> extends Reference<T> {
    public WeakReference(T referent) {
        super(referent);
    }
    
    public WeakReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
    }
}
```

比 SoftReference 更简单，没有 clock/timestamp 逻辑。

### 4.3 WeakHashMap：弱引用的典型应用

```java
import java.util.WeakHashMap;

public class WeakHashMapDemo {
    public static void main(String[] args) {
        WeakHashMap<Key, String> map = new WeakHashMap<>();
        
        Key key = new Key("data");
        map.put(key, "valuable data");
        
        System.out.println(map.size());  // 1
        key = null;  // 取消强引用
        System.gc();
        
        // WeakHashMap 在下次操作时会自动清除已被 GC 回收的 entry
        System.out.println(map.size());  // 0
    }
    
    static class Key {
        private final String id;
        Key(String id) { this.id = id; }
    }
}
```

`WeakHashMap` 使用 `ReferenceQueue` 追踪被回收的 key：

```java
public class WeakHashMap<K, V> {
    private final ReferenceQueue<K> queue = new ReferenceQueue<>();
    
    private static class Entry<K, V> extends WeakReference<Object> {
        V value;
        final int hash;
        Entry<K, V> next;
        
        Entry(K key, V value, ReferenceQueue<K> queue) {
            super(key, queue);  // key 作为弱引用
            this.value = value;
            this.hash = key.hashCode();
        }
    }
    
    // 每次操作时，先清除已被回收的 entry
    private void expungeStaleEntries() {
        for (Entry<K, V> e; (e = (Entry<K, V>) queue.poll()) != null; ) {
            // 从哈希表中移除这个 entry
        }
    }
}
```

### 4.4 应用场景

| 场景 | 说明 |
|------|------|
| WeakHashMap | 当 key 不再被外部引用时自动清理 |
| ThreadLocal | ThreadLocalMap 的 Entry 使用弱引用指向 ThreadLocal |
| 框架内的缓存 | 需要自动清理的短生命周期缓存 |

## 五、虚引用（PhantomReference）

### 5.1 基本用法

```java
import java.lang.ref.PhantomReference;
import java.lang.ref.ReferenceQueue;

public class PhantomReferenceDemo {
    public static void main(String[] args) throws InterruptedException {
        ReferenceQueue<Object> queue = new ReferenceQueue<>();
        Object obj = new Object();
        PhantomReference<Object> phantomRef = new PhantomReference<>(obj, queue);
        obj = null;
        
        // phantomRef.get() 永远返回 null！
        System.out.println(phantomRef.get());  // null
        
        System.gc();
        Thread.sleep(100);
        
        // 对象被回收后，虚引用会被放入 ReferenceQueue
        System.out.println(queue.poll() != null);  // true
    }
}
```

### 5.2 源码分析

```java
public class PhantomReference<T> extends Reference<T> {
    public T get() {
        return null;  // 永远返回 null！
    }
    
    public PhantomReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
    }
}
```

**注意：** 虚引用的构造函数**必须**传入 `ReferenceQueue`。因为没有队列你就无法知道对象何时被回收。

### 5.3 虚引用的 GC 流程

虚引用的回收机制与其他引用类型不同，分为**三步**：

1. **Finalizer 执行**：对象被 GC 标记为可回收，执行 `finalize()`
2. **对象回收**：真正回收对象内存
3. **入队通知**：将 `PhantomReference` 加入 `ReferenceQueue`

这意味着：**当你在 ReferenceQueue 中拿到 PhantomReference 时，对象已经被完全回收了。**

### 5.4 经典应用：NIO DirectByteBuffer 回收

虚引用最经典的应用是 Netty 和 JDK 中 `DirectByteBuffer` 的堆外内存回收：

```java
// JDK DirectByteBuffer 源码（简化）
class DirectByteBuffer {
    private static class Deallocator implements Runnable {
        private long address;  // 堆外内存地址
        
        @Override
        public void run() {
            // 释放堆外内存
            Unsafe.getUnsafe().freeMemory(address);
        }
    }
    
    private final Cleaner cleaner;  // 继承 PhantomReference
    
    DirectByteBuffer(int cap) {
        long base = 0;
        try {
            base = Unsafe.getUnsafe().allocateMemory(cap);
        } catch (OutOfMemoryError e) {
            throw e;
        }
        
        cleaner = Cleaner.create(this, new Deallocator(base));
        // 当 DirectByteBuffer 对象被 GC 回收时，
        // Cleaner 会触发 Deallocator 释放堆外内存
    }
}
```

```java
// JDK Cleaner 源码（简化）
public class Cleaner extends PhantomReference<Object> {
    private static final ReferenceQueue<Object> dummyQueue = new ReferenceQueue<>();
    private static final Set<Cleaner> cleaners = new HashSet<>();
    
    private final Runnable thunk;
    
    private Cleaner(Object referent, Runnable thunk) {
        super(referent, dummyQueue);
        this.thunk = thunk;
    }
    
    public static Cleaner create(Object ob, Runnable thunk) {
        Cleaner cleaner = new Cleaner(ob, thunk);
        cleaners.add(cleaner);
        return cleaner;
    }
    
    public void clean() {
        cleaners.remove(this);
        thunk.run();  // 执行清理任务
    }
}
```

## 六、引用队列（ReferenceQueue）

引用队列是引用对象的**通知机制**：

```java
ReferenceQueue<Object> queue = new ReferenceQueue<>();

// 所有引用类型都可以关联队列
SoftReference<Object> softRef = new SoftReference<>(obj, queue);
WeakReference<Object> weakRef = new WeakReference<>(obj, queue);
PhantomReference<Object> phantomRef = new PhantomReference<>(obj, queue);

// 当对象被回收后，对应的引用对象会进入队列
Reference<?> ref = queue.remove();  // 阻塞直到有引用入队
```

### Reference Handler 守护线程

JVM 内部有一个高优先级的 `Reference Handler` 线程，不断地将 GC 发现的待处理引用（`pending` 链表）入队到对应的 `ReferenceQueue` 中：

```java
// Reference.java 中的 Handler 线程
private static class ReferenceHandler extends Thread {
    public void run() {
        while (true) {
            tryHandlePending(true);
        }
    }
}

static boolean tryHandlePending(boolean waitForNotify) {
    Reference<Object> r;
    synchronized (lock) {
        if (pending != null) {
            r = pending;
            pending = r.discovered;
            r.discovered = null;
        } else {
            // 没有待处理的引用，等待 GC 通知
            lock.wait();
            return false;
        }
    }
    
    // 将引用入队
    r.enqueue();
    return true;
}
```

## 七、四种引用对比总结

| 维度 | 强引用 | 软引用 | 弱引用 | 虚引用 |
|------|-------|-------|-------|-------|
| 是否需要队列 | 不需要 | 可选 | 可选 | **必须** |
| get() 返回值 | 对象本身 | 对象或 null | 对象或 null | 永远 null |
| GC 回收条件 | 永不 | OOM 之前 | 下次 GC | 任何时候 |
| 典型用途 | 普通对象 | 缓存系统 | WeakHashMap | DirectBuffer 回收 |
| 源码复杂度 | Java 层面无 | 有 clock 逻辑 | 极简 | 极简 |

## 八、面试常见追问

**Q：软引用在 GC 时一定会被回收吗？**

A：不一定。取决于 `-XX:SoftRefLRUPolicyMSPerMB` 参数。默认 1000ms，表示每 MB 堆空间允许软引用存活 1 秒。堆越大，软引用存活越久。

**Q：WeakHashMap 的 Entry 为什么用弱引用指向 key？**

A：因为这样当 key 不再被外部强引用时，Entry 会自动失效。下次操作 WeakHashMap 时通过 `expungeStaleEntries()` 清理，避免内存泄漏。

**Q：虚引用与 finalize() 的区别？**

A：`finalize()` 在对象被回收前执行对象可能被"复活"。虚引用在对象被回收后通知，且 `get()` 永远返回 null，不可能复活。因此虚引用更安全可靠，推荐使用 Cleaner 代替 finalize()。

**Q：为什么 Netty 要自己实现堆外内存回收，而不是依赖 DirectByteBuffer 的 Cleaner？**

A：DirectByteBuffer 的 Cleaner 依赖于 GC 触发，**回收时机不可控**。Netty 使用引用计数 + 对象池，在确认不再使用时立即归还到池中或调用 `Unsafe.freeMemory()`，实现了**确定性的内存释放**。

## 九、实战建议

1. **缓存优先用 WeakHashMap 还是 Guava Cache？** → Guava Cache 提供了更丰富的过期策略和容量控制，但 `WeakHashMap` 轻量无依赖
2. **DirectBuffer 是虚引用的最佳实践**，建议在生产中遇到堆外内存泄漏时先理解这个机制
3. **ReferenceQueue 是监控 GC 行为的好工具**，可以用来统计对象回收情况

---

*Java 引用类型是理解 JVM 内存管理的必修课。掌握它们，你就能写出更健壮、更内存友好的 Java 程序。*
