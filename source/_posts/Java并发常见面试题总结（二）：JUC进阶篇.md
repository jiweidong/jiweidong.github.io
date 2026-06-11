---
title: Java并发常见面试题总结（二）：JUC进阶篇
date: 2026-06-09 10:15:00
tags:
  - Java
  - 并发编程
  - 面试题
  - JUC
categories:
  - Java
  - 并发编程
---

# Java并发常见面试题总结（二）：JUC进阶篇

## 一、AQS（AbstractQueuedSynchronizer）

### 1. AQS 的核心原理是什么？

**AQS**（AbstractQueuedSynchronizer）是 JUC 包的基石，`ReentrantLock`、`CountDownLatch`、`Semaphore`、`ReentrantReadWriteLock` 等同步器的底层实现都依赖 AQS。

**核心思想：** 如果请求的共享资源空闲，则将当前请求线程设为工作线程；否则将线程封装成一个 **Node 节点** 加入 **CLH 队列**，通过自旋 + CAS + LockSupport.park 阻塞等待。

**AQS 的核心组成：**

```
AQS（AbstractQueuedSynchronizer）
├── state（volatile int）        ← 同步状态，子类通过 getState/setState/compareAndSetState 操作
├── CLH 队列（双向链表）           ← 等待获取锁的线程队列
│   ├── Node.prev
│   ├── Node.next
│   ├── Node.thread               ← 等待的线程
│   └── Node.waitStatus           ← 等待状态（CANCELLED/SIGNAL/CONDITION/PROPAGATE）
└── ConditionObject（条件队列）    ← await/signal 使用的等待队列
```

**state 的含义由子类决定：**
- `ReentrantLock`：state = 0 表示未锁定，state > 0 表示重入次数
- `CountDownLatch`：state = 计数器初始值
- `Semaphore`：state = 可用许可数量
- `ReentrantReadWriteLock`：state 高 16 位 = 读锁计数，低 16 位 = 写锁计数

### 2. CLH 队列的工作原理

CLH 队列是一个 **FIFO 双向链表**，当一个线程获取锁失败时，AQS 会将该线程封装成 Node 加入队尾。

```java
// AQS 入队操作（核心代码示意）
private Node addWaiter(Node mode) {
    Node node = new Node(Thread.currentThread(), mode);
    Node pred = tail;
    if (pred != null) {
        node.prev = pred;
        if (compareAndSetTail(pred, node)) {  // CAS 设置尾节点
            pred.next = node;
            return node;
        }
    }
    enq(node); // 自旋入队
    return node;
}
```

**CLH 队列等待机制：**

```
    head                              tail
      ↓                                ↓
┌──────────┐    ┌──────────┐    ┌──────────┐
│ 哨兵节点  │ ←→ │ 线程A节点 │ ←→ │ 线程B节点 │
│ (已获取锁) │    │ (等待)   │    │ (等待)   │
└──────────┘    └──────────┘    └──────────┘
```

- **head 指向的节点**：当前持有锁的线程（或者说是已经获取到锁的线程的 Node）
- 每个 Node 通过 `prev` 和 `next` 指针形成双向链表
- 前驱节点释放锁后会唤醒后继节点

**自旋等待优化：** 在尝试获取锁时，AQS 会先自旋几次（`shouldParkAfterFailedAcquire`），避免频繁的线程阻塞/唤醒开销。

### 3. 可重入实现原理

`ReentrantLock` 的可重入性体现在：同一线程可以多次获取同一把锁而不被阻塞。

```java
// ReentrantLock 非公平锁的 lock() 方法（简化）
final void lock() {
    if (compareAndSetState(0, 1))     // CAS 尝试获取锁
        setExclusiveOwnerThread(Thread.currentThread());
    else
        acquire(1);
}

// acquire 中调用 tryAcquire
protected final boolean tryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState();
    if (c == 0) {
        if (!hasQueuedPredecessors() && compareAndSetState(0, acquires)) {
            setExclusiveOwnerThread(current);
            return true;
        }
    }
    // ⭐ 可重入关键：判断当前线程是否已经持有锁
    else if (current == getExclusiveOwnerThread()) {
        int nextc = c + acquires;  // state 累加
        if (nextc < 0) // overflow
            throw new Error("Maximum lock count exceeded");
        setState(nextc);
        return true;
    }
    return false;
}

// 释放锁时也对应递减
protected final boolean tryRelease(int releases) {
    int c = getState() - releases;
    if (Thread.currentThread() != getExclusiveOwnerThread())
        throw new IllegalMonitorStateException();
    boolean free = false;
    if (c == 0) {   // state 归零才算真正释放
        free = true;
        setExclusiveOwnerThread(null);
    }
    setState(c);
    return free;
}
```

**关键点：** ReentrantLock 通过 `state` 计数实现重入，获取锁时 `state+1`，释放锁时 `state-1`，只有 `state=0` 才算完全释放。

---

## 二、CAS（Compare And Swap）

### 4. CAS 的底层实现是什么？

**CAS**（Compare And Swap）是一种无锁原子操作，包含三个操作数：**内存地址 V**、**预期值 A**、**新值 B**。仅当 V 的值等于 A 时，才将 V 更新为 B。

```java
// CAS 的语义（伪代码）
boolean compareAndSwap(V, A, B) {
    if (V == A) {
        V = B;
        return true;
    }
    return false;
}
```

**底层实现：**
- **硬件层面**：CPU 提供了 `cmpxchg` 指令（x86 架构），由硬件保证操作的原子性
- **Java 层面**：通过 `Unsafe` 类的 `compareAndSwapXXX` 方法调用 JNI 本地方法

```java
// Unsafe 类中的 CAS 方法（native）
public final native boolean compareAndSwapInt(
    Object o, long offset, int expected, int x
);
```

> `Unsafe` 类虽然名为"不安全"，但 JUC 包内部大量使用，普通开发者不应直接调用。

### 5. CAS 存在什么问题？如何解决 ABA 问题？

**CAS 的三大问题：**

| 问题 | 说明 | 解决方案 |
|------|------|---------|
| **ABA 问题** | 值从 A→B→A，CAS 误判为未修改 | `AtomicStampedReference`（带版本号） |
| **自旋开销大** | 长时间 CAS 不成功，CPU 空转 | `LongAdder`（分段累加） |
| **只能保证一个共享变量的原子操作** | 不能同时对多个变量 CAS | 使用 `AtomicReference` 封装对象 |

**ABA 问题示例：**

```java
// ABA 问题演示
AtomicInteger a = new AtomicInteger(1);
// 线程1: 期望 a 从 1 变成 2
// 线程2: a 1→2, a 2→1
// 线程1: CAS(1,2) 成功，但 a 已经被修改过了！

// 解决方案：使用带版本号的 AtomicStampedReference
AtomicStampedReference<Integer> ref = 
    new AtomicStampedReference<>(1, 0);
// 每次修改时传入预期版本号和新版本号
ref.compareAndSet(1, 2, ref.getStamp(), ref.getStamp() + 1);
```

### 6. Java 中的原子类有哪些？

`java.util.concurrent.atomic` 包提供了丰富的原子类：

| 类别 | 类名 | 说明 |
|------|------|------|
| 基本类型 | `AtomicInteger`、`AtomicLong`、`AtomicBoolean` | 原子更新单个变量 |
| 引用类型 | `AtomicReference`、`AtomicStampedReference`、`AtomicMarkableReference` | 原子更新对象引用 |
| 数组 | `AtomicIntegerArray`、`AtomicLongArray`、`AtomicReferenceArray` | 原子更新数组元素 |
| 字段更新器 | `AtomicIntegerFieldUpdater`、`AtomicLongFieldUpdater`、`AtomicReferenceFieldUpdater` | 原子更新对象的某个字段 |

```java
// AtomicInteger 常用方法
AtomicInteger count = new AtomicInteger(0);
count.incrementAndGet();   // ++i（原子自增并返回新值）
count.getAndIncrement();   // i++（返回旧值再自增）
count.addAndGet(5);        // 原子加5
count.compareAndSet(10, 20); // CAS 操作
```

### 7. LongAdder 相比 AtomicLong 的优势？

`LongAdder` 是 JDK 1.8 引入的，其主要优势在于 **高并发下的性能优化**。

**AtomicLong 的问题：** 在高并发场景下，大量线程同时 CAS 同一个变量，会导致大量 CAS 失败，引发严重的 **自旋开销** 和 **缓存一致性问题**（多 CPU 核之间的 cache line 频繁失效）。

**LongAdder 的设计思路（空间换时间）：**

```
LongAdder
├── base           ← 无竞争时的基础值
└── Cell[] cells   ← 有竞争时，每个线程操作自己的 Cell
```

**工作流程：**
1. 无竞争时：直接操作 `base`（相当于 AtomicLong）
2. 有竞争时：将累加操作分散到 `Cell[]` 数组中的不同槽位
3. 求和时：`sum = base + sum(cells)`

```java
LongAdder counter = new LongAdder();
counter.increment();  // 自动选择 Cell 或 base
counter.add(10);
long result = counter.sum();  // 最终结果
```

**适用场景对比：**

| 场景 | 推荐工具 | 原因 |
|------|---------|------|
| 低频更新、高频读取 | `AtomicLong` | sum() 需要遍历 Cells，有性能开销 |
| 高频更新、低频读取（如计数器、统计指标） | `LongAdder` | 写入性能远优于 AtomicLong |

> JDK 1.8 还引入了 `LongAccumulator`，可以自定义累加函数（不仅仅是求和）。

---

## 三、线程池

### 8. 线程池的 7 大核心参数是什么？

```java
public ThreadPoolExecutor(
    int corePoolSize,           // 1️⃣ 核心线程数
    int maximumPoolSize,        // 2️⃣ 最大线程数
    long keepAliveTime,         // 3️⃣ 空闲线程存活时间
    TimeUnit unit,              // 4️⃣ 时间单位
    BlockingQueue<Runnable> workQueue, // 5️⃣ 阻塞队列
    ThreadFactory threadFactory,       // 6️⃣ 线程工厂
    RejectedExecutionHandler handler   // 7️⃣ 拒绝策略
);
```

### 9. 线程池的执行流程是怎样的？

```
                  提交任务
                     │
                     ▼
              ┌──────────────┐
              │  corePoolSize │←── 是否达到核心线程数？
              │  已满？       │
              └──────┬───────┘
              是↓           ↓否
         ┌──────────────┐   创建核心线程执行
         │  工作队列     │
         │  已满？       │
         └──────┬───────┘
         是↓           ↓否
    ┌──────────────┐   加入队列等待
    │ maxPoolSize  │
    │ 已满？       │
    └──────┬───────┘
    是↓           ↓否
  ┌──────────┐   创建非核心线程执行
  │ 拒绝策略  │
  └──────────┘
```

**流程图总结：**

```
1️⃣ 核心线程未满  →  创建核心线程执行任务
2️⃣ 核心线程已满  →  任务加入阻塞队列
3️⃣ 队列已满      →  创建非核心线程执行
4️⃣ 线程数已达最大 →  执行拒绝策略
```

### 10. 线程池的 4 种拒绝策略

| 拒绝策略 | 说明 | 适用场景 |
|---------|------|---------|
| `AbortPolicy`（默认） | 抛出 `RejectedExecutionException` | 必须处理的任务 |
| `CallerRunsPolicy` | 由提交任务的线程自己执行 | 降级处理，放慢提交速度 |
| `DiscardPolicy` | 丢弃任务，不抛异常 | 可丢失的非重要任务 |
| `DiscardOldestPolicy` | 丢弃队列中最老的任务，重新提交 | 时效性要求高的场景 |

```java
// 自定义拒绝策略示例
ThreadPoolExecutor executor = new ThreadPoolExecutor(
    2, 5, 60, TimeUnit.SECONDS,
    new ArrayBlockingQueue<>(100),
    (r, executor) -> {
        // 记录日志 + 将任务持久化到数据库
        log.warn("任务被拒绝: {}", r.toString());
        saveToDB(r);  // 后续通过定时任务重新提交
    }
);
```

### 11. 如何合理配置线程池大小？

**CPU 密集型任务：** `N + 1`（N = CPU 核数）
- 计算为主，线程多了反而增加上下文切换

**IO 密集型任务：** `2N` 或更大
- IO 等待时线程阻塞，可让更多线程利用 CPU

**通用公式（参考《Java 并发编程实战》）：**

```
线程数 = N * U * (1 + W/C)

N = CPU 核数
U = 目标 CPU 利用率（0~1）
W/C = 等待时间 / 计算时间
```

**最佳实践：** 生产环境通过压测确定最优值，预留 20% 的缓冲。

```java
// 工具类：获取 CPU 核数
int cores = Runtime.getRuntime().availableProcessors();

// IO 密集型（等待时间约为计算时间的 10 倍）
int poolSize = cores * (1 + 10);  // ≈ 2N

// 如果有阻塞操作（数据库、RPC、文件IO）
// 建议通过动态调整 + 压测验证
```

### 12. 如何优雅地关闭线程池？

```java
ExecutorService executor = Executors.newFixedThreadPool(10);

// 步骤1: shutdown() - 不再接受新任务，等待已提交任务完成
executor.shutdown();

try {
    // 步骤2: awaitTermination() - 等待指定时间，等待现有任务终止
    if (!executor.awaitTermination(60, TimeUnit.SECONDS)) {
        // 步骤3: shutdownNow() - 强制停止正在执行的任务
        executor.shutdownNow();
        
        // 步骤4: 再次等待，确认完全停止
        if (!executor.awaitTermination(60, TimeUnit.SECONDS)) {
            System.err.println("线程池未能完全终止");
        }
    }
} catch (InterruptedException e) {
    // 当前线程被中断，强制关闭
    executor.shutdownNow();
    Thread.currentThread().interrupt();
}
```

**shutdown vs shutdownNow：**

| 方法 | 行为 |
|------|------|
| `shutdown()` | 不再接受新任务，等待已提交和执行中的任务完成 |
| `shutdownNow()` | 尝试停止所有正在执行的任务，返回未执行的任务列表 |

### 13. 为什么禁止使用 Executors 创建线程池？

**《阿里巴巴 Java 开发手册》明确禁止！**

```java
// ❌ 禁止使用 - 可能 OOM
ExecutorService pool1 = Executors.newFixedThreadPool(10);
// 内部使用 LinkedBlockingQueue，容量为 Integer.MAX_VALUE
// 任务积压过多会 OOM

ExecutorService pool2 = Executors.newCachedThreadPool();
// 最大线程数为 Integer.MAX_VALUE
// 线程创建过多会 OOM

ExecutorService pool3 = Executors.newScheduledThreadPool(10);
// 内部使用 DelayedWorkQueue，容量为 Integer.MAX_VALUE

// ✅ 推荐使用 - 手动配置 ThreadPoolExecutor
ThreadPoolExecutor executor = new ThreadPoolExecutor(
    2, 5, 60L, TimeUnit.SECONDS,
    new ArrayBlockingQueue<>(100),
    new ThreadPoolExecutor.CallerRunsPolicy()
);
```

---

## 四、阻塞队列

### 14. 常用的阻塞队列有哪些？

| 阻塞队列 | 底层结构 | 特性 | 适用场景 |
|---------|---------|------|---------|
| `ArrayBlockingQueue` | 数组 + 有界 | 公平/非公平锁可选 | 生产者消费者 |
| `LinkedBlockingQueue` | 链表 + 可选有界 | 默认容量 Integer.MAX_VALUE | 线程池默认队列 |
| `SynchronousQueue` | 无容量 | 每个插入必须等待一个取出 | 直接交接（CachedThreadPool 使用） |
| `PriorityBlockingQueue` | 堆（数组） + 无界 | 支持优先级排序 | 优先级任务队列 |
| `DelayQueue` | PriorityBlockingQueue 封装 | 延迟执行 | 定时任务调度 |
| `LinkedTransferQueue` | 链表 | transfer() 方法支持直接交接 | 高性能无锁队列 |

### 15. 阻塞队列的核心方法

| 操作 | 抛异常 | 返回特殊值 | 阻塞 | 超时 |
|------|--------|-----------|------|------|
| 插入 | `add(e)` | `offer(e)` | `put(e)` | `offer(e, time, unit)` |
| 移除 | `remove()` | `poll()` | `take()` | `poll(time, unit)` |
| 检查 | `element()` | `peek()` | 无 | 无 |

```java
// 经典生产者-消费者模式
BlockingQueue<String> queue = new ArrayBlockingQueue<>(10);

// 生产者
new Thread(() -> {
    try {
        queue.put("task-" + i);   // 队列满时阻塞
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
    }
}).start();

// 消费者
new Thread(() -> {
    try {
        String task = queue.take();  // 队列空时阻塞
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
    }
}).start();
```

---

## 五、同步工具类

### 16. CountDownLatch 原理与使用

**CountDownLatch**（倒计时门闩）：允许一个或多个线程等待其他线程完成操作。

```java
public class CountDownLatchExample {
    public static void main(String[] args) throws InterruptedException {
        int threadCount = 5;
        CountDownLatch latch = new CountDownLatch(threadCount);
        
        for (int i = 0; i < threadCount; i++) {
            new Thread(() -> {
                try {
                    System.out.println(Thread.currentThread().getName() + " 执行任务");
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    latch.countDown();  // 计数器减1
                }
            }, "线程-" + i).start();
        }
        
        latch.await();  // 主线程等待，直到计数器归零
        System.out.println("所有任务完成，继续执行");
    }
}
```

**原理：** CountDownLatch 基于 AQS 实现，state 初始值为计数器值。`countDown()` 方法调用 `releaseShared(1)` 释放共享锁，`await()` 方法调用 `acquireSharedInterruptibly(1)` 获取共享锁，当 `state=0` 时获取成功。

**注意：** CountDownLatch 的计数器是 **一次性** 的，用完无法重置。

### 17. CyclicBarrier 原理与使用

**CyclicBarrier**（循环屏障）：让一组线程到达一个屏障（同步点）时被阻塞，直到最后一个线程到达，屏障打开，所有被拦截的线程继续执行。

```java
public class CyclicBarrierExample {
    public static void main(String[] args) {
        int threadCount = 5;
        CyclicBarrier barrier = new CyclicBarrier(threadCount, () -> {
            System.out.println("=== 所有线程到达屏障，执行屏障动作 ===");
        });
        
        for (int i = 0; i < threadCount; i++) {
            new Thread(() -> {
                try {
                    System.out.println(Thread.currentThread().getName() + " 到达屏障");
                    barrier.await();  // 等待其他线程
                    System.out.println(Thread.currentThread().getName() + " 通过屏障");
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }, "线程-" + i).start();
        }
    }
}
```

**CountDownLatch vs CyclicBarrier：**

| 对比维度 | CountDownLatch | CyclicBarrier |
|---------|---------------|--------------|
| 核心机制 | 计数器递减 | 计数器递增到达阈值 |
| 能否复用 | ❌ 一次性 | ✅ 可循环使用（`reset()`） |
| 参与者 | 一个线程等待多个 | 多个线程互相等待 |
| 屏障动作 | 无 | 可指定到达屏障后的回调 |
| 实现方式 | AQS `Shared` 模式 | `ReentrantLock` + `Condition` |

### 18. Semaphore 原理与使用

**Semaphore**（信号量）：控制同时访问特定资源的线程数量（限流/限并发）。

```java
public class SemaphoreExample {
    public static void main(String[] args) {
        // 同时最多允许 3 个线程访问
        Semaphore semaphore = new Semaphore(3);
        
        for (int i = 0; i < 10; i++) {
            new Thread(() -> {
                try {
                    semaphore.acquire();  // 获取许可
                    System.out.println(Thread.currentThread().getName() + " 获取许可");
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    semaphore.release();  // 释放许可
                    System.out.println(Thread.currentThread().getName() + " 释放许可");
                }
            }, "线程-" + i).start();
        }
    }
}
```

**应用场景：**
- 数据库连接池限流
- 接口限流（控制并发请求数）
- 文件访问控制

**公平性配置：**
```java
Semaphore fairSemaphore = new Semaphore(3, true);  // 公平模式（FIFO）
Semaphore unfairSemaphore = new Semaphore(3, false); // 非公平模式（默认）
```

---

## 六、Fork/Join 框架

### 19. Fork/Join 框架的原理是什么？

**Fork/Join** 是 JDK 1.7 引入的并行计算框架，核心思想是 **分治法（Divide and Conquer）** + **工作窃取（Work Stealing）**。

**工作流程：**

```
      大型任务
         │
    ┌────┴────┐
    │  Fork   │ ← 分割为子任务
    └────┬────┘
         │
   ┌─────┼─────┐
   │     │     │
 子任务 子任务 子任务  ← 并行执行
   │     │     │
   └─────┼─────┘
    ┌────┴────┐
    │  Join   │ ← 合并结果
    └─────────┘
```

**工作窃取算法：** 空闲线程从其他线程的队列尾部"窃取"任务来执行，充分利用 CPU 资源。

```java
// ForkJoinPool 中的双端队列（Deque）
// 每个工作线程维护自己的任务队列
Thread A: [taskA1, taskA2, taskA3, ...] ← 从头部取任务
Thread B: [taskB1, taskB2, taskB3, ...] ← 从头部取任务
                        ↑
                空闲线程从尾部窃取任务
```

### 20. 使用 Fork/Join 进行归并排序

```java
public class MergeSortTask extends RecursiveAction {
    private final int[] array;
    private final int left;
    private final int right;
    private static final int THRESHOLD = 1000;  // 阈值

    public MergeSortTask(int[] array, int left, int right) {
        this.array = array;
        this.left = left;
        this.right = right;
    }

    @Override
    protected void compute() {
        if (right - left <= THRESHOLD) {
            // 小于阈值，直接排序
            Arrays.sort(array, left, right + 1);
            return;
        }
        
        int mid = left + (right - left) / 2;
        
        // Fork 子任务
        MergeSortTask leftTask = new MergeSortTask(array, left, mid);
        MergeSortTask rightTask = new MergeSortTask(array, mid + 1, right);
        
        invokeAll(leftTask, rightTask);  // 提交两个子任务
        
        // Join 合并结果
        merge(array, left, mid, right);
    }
    
    private void merge(int[] array, int left, int mid, int right) {
        // 归并两个有序子数组
        int[] temp = new int[right - left + 1];
        int i = left, j = mid + 1, k = 0;
        while (i <= mid && j <= right) {
            temp[k++] = array[i] <= array[j] ? array[i++] : array[j++];
        }
        while (i <= mid) temp[k++] = array[i++];
        while (j <= right) temp[k++] = array[j++];
        System.arraycopy(temp, 0, array, left, temp.length);
    }
}

// 使用
ForkJoinPool pool = new ForkJoinPool();
MergeSortTask task = new MergeSortTask(array, 0, array.length - 1);
pool.invoke(task);  // 提交并等待完成
```

**RecursiveAction vs RecursiveTask：**

| 类 | 返回值 | 适用场景 |
|----|--------|---------|
| `RecursiveAction` | 无返回值 | 数据排序、遍历 |
| `RecursiveTask<V>` | 有返回值 | 求和、统计、搜索 |

---

## 总结

JUC 进阶篇涵盖了并发编程的核心工具类。面试要点：

1. **AQS** 是 JUC 的基石，理解 CLH 队列 + state 的核心设计
2. **CAS** 是无锁编程的基础，注意 ABA 问题的解决方案
3. **线程池** 是生产环境最常用的并发工具，务必掌握 7 大参数和执行流程
4. **阻塞队列** 区分核心方法（put/take 阻塞 vs offer/poll 超时）
5. **CountDownLatch/CyclicBarrier/Semaphore** 各自的使用场景
6. **Fork/Join** 掌握分治 + 工作窃取思想

下一篇：[《Java并发常见面试题总结（三）：高级篇》](/2026/06/09/Java并发常见面试题总结（三）：高级篇/) 将深入 ConcurrentHashMap、CompletableFuture、虚拟线程等高级主题。
