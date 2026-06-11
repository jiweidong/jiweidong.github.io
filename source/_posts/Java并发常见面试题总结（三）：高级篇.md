---
title: Java并发常见面试题总结（三）：高级篇
date: 2026-06-09 10:20:00
tags:
  - Java
  - 并发编程
  - 面试题
  - JUC
  - 虚拟线程
categories:
  - Java
  - 并发编程
---

# Java并发常见面试题总结（三）：高级篇

## 一、ConcurrentHashMap 源码分析

### 1. JDK 7 与 JDK 8 的 ConcurrentHashMap 区别

| 对比维度 | JDK 7 | JDK 8 |
|---------|-------|-------|
| **数据结构** | Segment + HashEntry + 数组+链表 | Node + 数组+链表+红黑树 |
| **锁粒度** | Segment 分段锁（继承 ReentrantLock） | synchronized + CAS（锁链表头节点） |
| **并发度** | 固定 Segment 数组大小（默认16） | 动态扩容，锁粒度更细 |
| **寻址** | 两次 Hash（找 Segment → 找 Entry） | 一次 Hash 找到数组下标 |
| **查询性能** | 链表遍历 O(n) | 链表 O(n) / 红黑树 O(log n) |
| **size() 方法** | 先乐观尝试，失败则加锁所有 Segment | 通过 baseCount + CounterCell 累加（类似 LongAdder） |

**数据结构对比图：**

```
JDK 7:
┌──────────┐
│ Segment0 │ → HashEntry[] → [Entry] → [Entry]
├──────────┤
│ Segment1 │ → HashEntry[] → [Entry]
├──────────┤
│ ...      │
├──────────┤
│Segment15 │ → HashEntry[] → [Entry] → [Entry] → [Entry]
└──────────┘

JDK 8:
┌─────────────────────────────────────┐
│ table (Node[])                      │
├─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┤
│0│1│2│3│4│5│6│7│8│9│...│N│   │   │   │
└─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┴─┘
 │     │           │
 │     │           └── Node → Node（链表长度>8时转为红黑树）
 │     │
 │     └── Node（单个节点）
 │
 └── TreeNode（红黑树）
```

### 2. JDK 8 ConcurrentHashMap 的 put 流程

```java
// put 方法核心逻辑（JDK 8 简化示意）
final V putVal(K key, V value, boolean onlyIfAbsent) {
    // 1. 计算 hash
    int hash = spread(key.hashCode());
    
    for (Node<K,V>[] tab = table;;) {      // 自旋 CAS
        Node<K,V> f; int n, i, fh;
        
        // 2. 首次 put，初始化数组（懒加载）
        if (tab == null || (n = tab.length) == 0)
            tab = initTable();
        
        // 3. 数组下标 i 处没有节点 → CAS 直接放进去
        else if ((f = tabAt(tab, i = (n - 1) & hash)) == null) {
            if (casTabAt(tab, i, null, new Node<K,V>(hash, key, value)))
                break;  // CAS 成功，跳出循环
        }
        
        // 4. 正在扩容 → 协助扩容（ForwardingNode）
        else if ((fh = f.hash) == MOVED)
            tab = helpTransfer(tab, f);
        
        // 5. 有 hash 冲突，加锁链表头节点
        else {
            V oldVal = null;
            synchronized (f) {           // 锁住链表头节点
                if (tabAt(tab, i) == f) {  // 双重检查
                    if (fh >= 0) {         // 链表遍历
                        // 遍历链表，找到则替换，未找到则插入尾部
                    } else if (f instanceof TreeBin) { // 红黑树插入
                    }
                }
            }
        }
    }
    // 6. 计数 + 检查是否需要扩容
    addCount(1L, binCount);
}
```

**JDK 8 亮点设计：**
- `synchronized` 替换 `ReentrantLock`：JDK 6 优化后 synchronized 性能不输 Lock
- 锁粒度更细：仅锁数组的某个桶（链表头），而非 Segment
- CAS 无锁化：数组初始化和空槽位插入使用 CAS
- 红黑树：链表长度 ≥ 8 时转为红黑树（TREEIFY_THRESHOLD=8），提高查询效率

### 3. ConcurrentHashMap 的 size() 方法

在 JDK 8 中，ConcurrentHashMap 使用 **baseCount + CounterCell[]** 类似 LongAdder 的设计来统计元素数量。

```java
// JDK 8 ConcurrentHashMap 的 size() 实现
public int size() {
    long n = sumCount();
    return (n < 0L) ? 0 : (n > (long)Integer.MAX_VALUE) ? Integer.MAX_VALUE : (int)n;
}

// sumCount() 内部
final long sumCount() {
    CounterCell[] cs = counterCells;
    long sum = baseCount;
    if (cs != null) {
        for (CounterCell c : cs)
            if (c != null)
                sum += c.value;  // 累加所有 CounterCell 的值
    }
    return sum;
}
```

**为什么不像 HashMap 一样直接维护一个 size 变量？**
- 多线程同时 put/remove，一个 volatile 变量难以承受高并发的 CAS 竞争
- 使用 baseCount + CounterCell 分散竞争，大幅提升性能

**JDK 7 的 size() 实现：**
1. 先尝试两次不加锁地统计各 Segment 的 size（modCount 一致则返回）
2. 如果不一致，则加锁所有 Segment 后重新统计

### 4. ConcurrentHashMap 为什么是线程安全的？

```
线程安全保障机制：
┌────────────────────────────────────────────┐
│  1. 数组初始化：CAS（compareAndSet）        │
│  2. 空槽位插入：CAS（tabAt → casTabAt）      │
│  3. 链表插入/删除：synchronized 锁头节点     │
│  4. 扩容迁移：synchronized + 协助扩容机制     │
│  5. 计数统计：baseCount + CounterCell       │
│  6. 红黑树操作：TreeBin 内部读写锁           │
└────────────────────────────────────────────┘
```

**遍历安全：** ConcurrentHashMap 的迭代器是 **弱一致性（weakly consistent）** 的，遍历时可以看到已修改的数据，但不保证遍历开始时所有数据都被迭代到（不会抛 ConcurrentModificationException）。

---

## 二、CopyOnWriteArrayList

### 5. CopyOnWriteArrayList 的原理

**CopyOnWriteArrayList**（写时复制数组列表）是线程安全的 ArrayList 变体。其核心思想是 **读写分离**：

```
读取操作：无锁，直接读数组（零开销）
写入操作：加锁，复制一份新数组，在新数组上修改，然后替换引用

读取线程                                         写入线程
    │                                               │
    │  array = [A, B, C, D]                         │
    │       ↑                                       │
    │  get(2) → 直接读，无锁                        │
    │                                               │
    │                                        lock.lock()
    │                                               │
    │  array = [A, B, C, D]                         │
    │  get(2) → 仍然读旧数组                        │
    │                               newArray = copy(array)
    │                               newArray.add("E")
    │                               setArray(newArray)  ← 替换引用
    │                                        lock.unlock()
    │                                               │
    │  array = [A, B, C, D, E]                      │
    │  get(2) → 现在读新数据                        │
```

**源码核心：**

```java
public class CopyOnWriteArrayList<E> {
    private transient volatile Object[] array;

    // 读：无锁，直接读
    public E get(int index) {
        return (E) getArray()[index];
    }

    // 写：加锁 + 复制
    public boolean add(E e) {
        final ReentrantLock lock = this.lock;
        lock.lock();
        try {
            Object[] elements = getArray();
            int len = elements.length;
            Object[] newElements = Arrays.copyOf(elements, len + 1); // 复制
            newElements[len] = e;  // 修改
            setArray(newElements); // 替换
            return true;
        } finally {
            lock.unlock();
        }
    }
}
```

### 6. CopyOnWriteArrayList 的适用场景

**优点：**
- 读操作性能极高（无锁，无阻塞）
- 遍历操作绝对线程安全（迭代器遍历的是不可变的快照）

**缺点：**
- 写操作开销大（每次修改都复制整个数组，O(n) 复制 + O(n) 内存）
- 内存占用翻倍（新数组 + 旧数组同时存在，直到 GC）
- 只能保证**最终一致性**，不能保证**实时一致性**（读可能读到旧数据）

**适用场景：**

| ✅ 适合 | ❌ 不适合 |
|---------|---------|
| 读远多于写（读多写少） | 写频繁（每次复制开销大） |
| 集合较小（元素 < 1000） | 集合很大（复制成本过高） |
| 允许短暂的数据不一致 | 要求强一致性 |
| 不需要频繁增删改的遍历 | 需要实时最新数据的场景 |

**典型应用：** 白名单、黑名单配置；订阅者列表更新频率低、读取频率高。

---

## 三、CompletableFuture

### 7. CompletableFuture 的 Async 方法

`CompletableFuture` 是 JDK 1.8 引入的异步编程工具，弥补了 `Future` 的不足（无法手动完成、无法回调组合、阻塞获取结果）。

**四个静态创建方法：**

```java
// 1. runAsync - 无返回值
CompletableFuture<Void> future = CompletableFuture.runAsync(() -> {
    System.out.println("异步执行，无返回值");
});

// 2. supplyAsync - 有返回值（默认使用 ForkJoinPool.commonPool()）
CompletableFuture<String> future = CompletableFuture.supplyAsync(() -> {
    return "异步结果";
});

// 3. runAsync + 自定义线程池
ExecutorService executor = Executors.newFixedThreadPool(5);
CompletableFuture<Void> future = CompletableFuture.runAsync(() -> {
    // 使用自定义线程池执行
}, executor);

// 4. supplyAsync + 自定义线程池
CompletableFuture<String> future = CompletableFuture.supplyAsync(() -> {
    return "结果";
}, executor);
```

**Async 后缀的含义：**

| 方法 | 执行线程 |
|------|---------|
| `thenApply(fn)` | 沿用前一个任务线程 |
| `thenApplyAsync(fn)` | 使用 ForkJoinPool.commonPool() |
| `thenApplyAsync(fn, executor)` | 使用指定线程池 |

### 8. 回调与组合操作

**链式回调：**

```java
CompletableFuture.supplyAsync(() -> {
    return "Hello";
}).thenApply(result -> {
    return result + " World";       // 转换结果
}).thenApply(String::toUpperCase)   // 再转换
  .thenAccept(result -> {
    System.out.println(result);     // "HELLO WORLD" - 消费结果
}).thenRun(() -> {
    System.out.println("全部完成");  // 无需结果
});
```

**异常处理：**

```java
CompletableFuture.supplyAsync(() -> {
    if (Math.random() > 0.5) throw new RuntimeException("出错啦");
    return "成功";
}).exceptionally(ex -> {
    System.out.println("捕获异常: " + ex.getMessage());
    return "默认值";  // 异常时返回默认值
}).thenAccept(System.out::println);

// 更精确的处理：handle 可以接收正常结果和异常
CompletableFuture.supplyAsync(() -> {
    return "正常结果";
}).handle((result, ex) -> {
    if (ex != null) {
        System.out.println("异常: " + ex.getMessage());
        return "降级结果";
    }
    return result;
});
```

**多 Future 组合：**

```java
// thenCompose - 两个 Future 串联（依赖关系）
CompletableFuture<String> future1 = CompletableFuture.supplyAsync(() -> "第一步");
CompletableFuture<String> combined = future1.thenCompose(result ->
    CompletableFuture.supplyAsync(() -> result + " → 第二步")
);

// thenCombine - 两个 Future 并联（无依赖关系）
CompletableFuture<String> f1 = CompletableFuture.supplyAsync(() -> "任务A");
CompletableFuture<String> f2 = CompletableFuture.supplyAsync(() -> "任务B");
CompletableFuture<String> result = f1.thenCombine(f2, (a, b) -> a + " + " + b);
// 结果: "任务A + 任务B"

// allOf - 等待所有完成
CompletableFuture<Void> all = CompletableFuture.allOf(f1, f2);
all.join();  // 阻塞等待所有任务完成

// anyOf - 任意一个完成即返回
CompletableFuture<Object> any = CompletableFuture.anyOf(f1, f2);
```

### 9. 实战：并行查询多个服务

```java
public class CompletableFutureDemo {
    
    public static void main(String[] args) {
        ExecutorService executor = Executors.newFixedThreadPool(10);
        
        long start = System.currentTimeMillis();
        
        // 并行查询三个服务
        CompletableFuture<String> userFuture = CompletableFuture
            .supplyAsync(() -> queryUserInfo(1L), executor)
            .exceptionally(e -> "用户服务异常");
            
        CompletableFuture<String> orderFuture = CompletableFuture
            .supplyAsync(() -> queryOrderList(1L), executor)
            .exceptionally(e -> "订单服务异常");
            
        CompletableFuture<String> couponFuture = CompletableFuture
            .supplyAsync(() -> queryCouponInfo(1L), executor)
            .exceptionally(e -> "优惠券服务异常");
        
        // 等待所有服务返回，聚合结果
        CompletableFuture<Void> all = CompletableFuture
            .allOf(userFuture, orderFuture, couponFuture);
        
        String result = all.thenApply(v -> {
            String user = userFuture.join();
            String order = orderFuture.join();
            String coupon = couponFuture.join();
            return String.format(
                "用户信息: %s\n订单信息: %s\n优惠券: %s",
                user, order, coupon
            );
        }).join();
        
        System.out.println(result);
        System.out.println("总耗时: " + (System.currentTimeMillis() - start) + "ms");
        
        executor.shutdown();
    }
    
    // 模拟耗时服务调用
    static String queryUserInfo(Long userId) {
        sleep(200);
        return "用户-张三";
    }
    
    static String queryOrderList(Long userId) {
        sleep(300);
        return "订单-共10条";
    }
    
    static String queryCouponInfo(Long userId) {
        sleep(150);
        return "优惠券-5张";
    }
    
    static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) {}
    }
}
```

**串行 vs 并行对比：** 上述代码如果串行执行需要 650ms（200+300+150），并行执行只需要约 300ms（取最慢服务的耗时）。

---

## 四、虚拟线程（Virtual Thread）

### 10. 什么是虚拟线程？原理是什么？

**虚拟线程**（Virtual Thread）是 JDK 21 正式发布（预览于 JDK 19/20）的轻量级线程（Project Loom），由 JVM 管理而非操作系统。

**核心概念对比：**

```
传统平台线程（Platform Thread / OS Thread）
┌─────────────────────────────────────────┐
│ 由操作系统内核管理                        │
│ 栈空间 ~1MB，创建 10 万个可能 OOM        │
│ 上下文切换代价大（系统调用）               │
│ 线程池复用是必要的                        │
└─────────────────────────────────────────┘

虚拟线程（Virtual Thread）
┌─────────────────────────────────────────┐
│ 由 JVM 管理（用户态）                     │
│ 栈空间 ~数百字节，可创建数百万个           │
│ 切换代价极小（纯 Java 代码）              │
│ 无需线程池，每个任务一个虚拟线程           │
└─────────────────────────────────────────┘
```

**虚拟线程的工作原理（M:N 调度模型）：**

```
                    M 个虚拟线程
         ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
         │ VT_1 │ │ VT_2 │ │ VT_3 │ │ VT_4 │ ...
         └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘
            │         │         │         │
            ▼         ▼         ▼         ▼
         ┌──────────────────────────────────────┐
         │          JVM 调度器（ForkJoinPool）    │
         └──────────────────────────────────────┘
            │         │         │         │
            ▼         ▼         ▼         ▼
         ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
         │ OS_1 │ │ OS_2 │ │ OS_3 │ │ OS_4 │ ...
         └──────┘ └──────┘ └──────┘ └──────┘
                    N 个平台线程（载体线程 Carrier Thread）
```

**关键特性：**
- 虚拟线程是 **M:N 调度模型**（M 个虚拟线程映射到 N 个平台线程）
- 虚拟线程遇到阻塞操作（如 IO、sleep、lock）时，会自动 **yield（让出）** 载体线程，载体线程去执行其他虚拟线程
- **不需要** 将 IO 操作改为异步回调，用同步代码即可获得异步性能

### 11. 虚拟线程的使用方式

```java
// 方式一：Thread.ofVirtual()
Thread vThread = Thread.ofVirtual()
    .name("my-virtual-thread")
    .start(() -> {
        System.out.println("虚拟线程执行: " + Thread.currentThread());
    });
vThread.join();

// 方式二：Executors.newVirtualThreadPerTaskExecutor()
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    for (int i = 0; i < 100_000; i++) {
        executor.submit(() -> {
            // 轻松创建 10 万个虚拟线程任务
            handleRequest();
        });
    }
}  // try-with-resources 自动关闭

// 方式三：Thread.startVirtualThread()
Thread.startVirtualThread(() -> {
    System.out.println("快速启动虚拟线程");
});
```

### 12. 虚拟线程的适用场景和注意事项

**✅ 适合场景：**

| 场景 | 说明 |
|------|------|
| **高 IO 密集型** | 大量 HTTP 请求、数据库查询、RPC 调用 |
| **短连接任务** | 每个请求创建一个虚拟线程，用完即弃 |
| **大量并发** | 需要百万级并发连接时（如 API Gateway） |
| **同步代码风格** | 希望用同步代码实现高并发，无需异步回调 |

**❌ 不适合场景：**

| 场景 | 原因 |
|------|------|
| CPU 密集型任务 | 虚拟线程无法利用更多 CPU 核，平台线程即可 |
| synchronized 中的阻塞操作 | 虚拟线程在 synchronized 块中无法 yield（固定 Pin 住平台线程） |
| 依赖 ThreadLocal 大量使用 | 虚拟线程数量巨大，ThreadLocal 内存开销不可忽视 |
| JNI 调用 | Native 代码无法感知虚拟线程 |

**⚠️ 注意事项：**

```java
// ❌ 不要在 synchronized 块中长时间阻塞（会导致虚拟线程 pinned）
synchronized (lock) {
    Thread.sleep(1000); // 虚拟线程被 pinned，无法 yield
}

// ✅ 使用 ReentrantLock 替代
Lock lock = new ReentrantLock();
lock.lock();
try {
    Thread.sleep(1000); // 虚拟线程可以 yield
} finally {
    lock.unlock();
}
```

---

## 五、并发编程实战经验总结

### 13. 并发编程六大原则

| 原则 | 说明 | 示例 |
|------|------|------|
| **单一职责** | 锁/线程池只用来解决一个问题 | 不要用一把锁保护不相关的数据 |
| **最少持有** | 尽可能缩小同步块范围 | synchronized (this) { 只放必要代码 } |
| **避免嵌套锁** | 减少锁的嵌套使用 | 嵌套锁容易导致死锁 |
| **优先无锁** | 能用 CAS/原子类就不用锁 | AtomicInteger > synchronized |
| **合理拆分** | 大锁拆小锁，提高并发度 | ConcurrentHashMap 的桶锁 |
| **做好降级** | 并发控制异常时要有容错机制 | 拒绝策略、超时降级 |

### 14. 死锁的产生与预防

**死锁的四个必要条件（缺一不可）：**

```
1. 互斥：资源一次只能被一个线程占用
2. 持有并等待：持有资源的同时等待更多资源
3. 非抢占：资源不能被强制夺走
4. 循环等待：多个线程形成资源等待环路
```

```java
// 经典死锁示例
public class DeadlockDemo {
    private final Object lockA = new Object();
    private final Object lockB = new Object();

    public void method1() {
        synchronized (lockA) {
            Thread.sleep(100);
            synchronized (lockB) { // 等待 lockB
                // ...
            }
        }
    }

    public void method2() {
        synchronized (lockB) {
            Thread.sleep(100);
            synchronized (lockA) { // 等待 lockA（形成环路）
                // ...
            }
        }
    }
}
```

**预防死锁的策略：**

```java
// 策略1：固定锁获取顺序（破坏循环等待）
// 所有线程按 lockA → lockB 的顺序获取锁
public void safeMethod() {
    synchronized (lockA) {
        synchronized (lockB) {
            // ...
        }
    }
}

// 策略2：使用 tryLock 带超时（破坏非抢占）
Lock lock1 = new ReentrantLock();
Lock lock2 = new ReentrantLock();

public boolean tryLockBoth() {
    while (true) {
        if (lock1.tryLock()) {
            try {
                if (lock2.tryLock(1, TimeUnit.SECONDS)) {
                    try {
                        return true;  // 获取两把锁成功
                    } finally {
                        lock2.unlock();
                    }
                }
            } finally {
                lock1.unlock();  // 获取 lock2 失败，释放 lock1
            }
        }
        // 重试或失败
    }
}

// 策略3：使用并发工具类
// 使用显式锁 + LockSupport 而非 synchronized 嵌套
```

### 15. 线程安全的最佳实践清单

```java
// ✅ 1. 优先使用不可变对象
public final class ImmutablePoint {
    private final int x;
    private final int y;
    // 只有 getter，没有 setter
}

// ✅ 2. 缩小锁范围
// ❌ 不好：锁住整个方法
public synchronized void update() {
    // 100 行非临界区代码
    sharedVar++;  // 只有这一行需要同步
}

// ✅ 好：只锁临界区
public void update() {
    // 100 行非临界区代码
    synchronized (this) {
        sharedVar++;
    }
}

// ✅ 3. 使用并发集合而非手动同步
// ❌ 不好
Map<String, String> map = Collections.synchronizedMap(new HashMap<>());
// ✅ 好
ConcurrentHashMap<String, String> map = new ConcurrentHashMap<>();

// ✅ 4. 线程名称调试
Thread.currentThread().setName("order-processor-" + orderId);

// ✅ 5. 捕获 InterruptedException 时恢复中断状态
try {
    Thread.sleep(1000);
} catch (InterruptedException e) {
    Thread.currentThread().interrupt();  // 恢复中断状态
    // 根据业务决定是否退出
}

// ✅ 6. 使用 try-finally 释放锁
Lock lock = new ReentrantLock();
lock.lock();
try {
    // 临界区
} finally {
    lock.unlock();  // 确保释放
}
```

### 16. 并发性能调优思路

| 问题 | 定位方法 | 常见原因 |
|------|---------|---------|
| **CPU 高** | `top` → `jstack` 查看线程栈 | 死循环、频繁 GC、CAS 自旋 |
| **响应慢** | `arthas` 看耗时方法 | 锁竞争、IO 阻塞、线程池满 |
| **死锁** | `jstack` 查看 BLOCKED 线程 | 嵌套锁、顺序不一致 |
| **OOM** | `jmap` dump 堆分析 | ThreadLocal 未释放、队列积压 |
| **频繁 Full GC** | `jstat` 看 GC 情况 | 创建大量短期对象、大对象 |

**调优步骤：**

```
1️⃣ 发现问题：监控报警、日志、APM 工具
2️⃣ 定位阻塞点：jstack、arthas、async-profiler
3️⃣ 分析原因：锁竞争 → 拆分 / CAS → 使用 LongAdder
4️⃣ 验证方案：压测对比 QPS、TP99、CPU 利用率
5️⃣ 灰度上线：逐步放量，观察监控指标
```

---

## 总结

高级篇涵盖了并发编程中最深度的面试考点和实战经验：

1. **ConcurrentHashMap**：面试必问，重点掌握 JDK 7/8 的区别、put 流程、size 实现
2. **CopyOnWriteArrayList**：读写分离思想，适合读多写少的场景
3. **CompletableFuture**：异步编程利器，掌握回调组合和处理异常
4. **虚拟线程**：JDK 21 的大杀器，理解原理和适用场景
5. **实战经验**：死锁预防、最佳实践、性能调优思路

并发编程是一个需要理论和实践紧密结合的领域。理解底层原理（AQS、CAS、内存模型），掌握核心工具（线程池、ConcurrentHashMap、CompletableFuture），并在实际项目中多总结多优化，才能做到游刃有余。
