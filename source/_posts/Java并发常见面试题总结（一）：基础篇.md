---
title: Java并发常见面试题总结（一）：基础篇
date: 2026-06-09 10:10:00
tags:
  - Java
  - 并发编程
  - 面试题
categories:
  - Java
  - 并发编程
---

# Java并发常见面试题总结（一）：基础篇

## 一、线程基础

### 1. 进程和线程的区别是什么？

**进程**是操作系统资源分配的最小单位，**线程**是 CPU 调度的最小单位。

| 对比维度 | 进程 | 线程 |
|---------|------|------|
| 资源开销 | 独立地址空间，切换开销大 | 共享进程资源，切换开销小 |
| 通信方式 | IPC（管道、消息队列、共享内存等） | 直接读写共享变量 |
| 独立性 | 进程间相互独立，一个崩溃不影响其他 | 一个线程崩溃可能导致整个进程崩溃 |
| 系统开销 | 创建/销毁进程开销大 | 创建/销毁线程开销小 |

**典型面试追问：** Java 是单线程还是多线程的？
> Java 程序天生就是多线程的。即使是简单的 `main()` 方法，也会启动 `main` 主线程、`Finalizer` 线程、`Reference Handler` 线程等多个 JVM 内部线程。

### 2. 创建线程有哪几种方式？

**方式一：继承 Thread 类**

```java
class MyThread extends Thread {
    @Override
    public void run() {
        System.out.println("线程执行中...");
    }
}
new MyThread().start();
```

**方式二：实现 Runnable 接口**（推荐，避免单继承限制）

```java
class MyTask implements Runnable {
    @Override
    public void run() {
        System.out.println("任务执行中...");
    }
}
new Thread(new MyTask()).start();
```

**方式三：实现 Callable 接口 + FutureTask**（可获取返回结果）

```java
class MyCallable implements Callable<String> {
    @Override
    public String call() {
        return "执行结果";
    }
}
FutureTask<String> task = new FutureTask<>(new MyCallable());
new Thread(task).start();
String result = task.get(); // 获取结果，会阻塞
```

**方式四：线程池（ExecutorService）**（最推荐，企业级使用）

```java
ExecutorService pool = Executors.newFixedThreadPool(10);
pool.execute(() -> System.out.println("任务执行"));
// 或
Future<String> future = pool.submit(() -> "结果");
pool.shutdown();
```

**⭐ 最佳实践：** 生产环境中**禁止使用 Executors 创建线程池**，应使用 `ThreadPoolExecutor` 手动配置参数，避免 OOM。

### 3. `start()` 和 `run()` 的区别？

- **`run()`**：普通方法调用，在当前线程中执行，不会创建新线程
- **`start()`**：启动新线程，JVM 会调用该线程的 `run()` 方法

```java
Thread t = new Thread(() -> System.out.println(Thread.currentThread().getName()));
t.run();   // 输出: main（主线程执行）
t.start(); // 输出: Thread-0（新线程执行）
```

### 4. 线程的生命周期有哪几种状态？

Java 线程有 **6 种状态**（定义在 `Thread.State` 枚举中）：

```
NEW → RUNNABLE → BLOCKED/WAITING/TIMED_WAITING → TERMINATED
```

| 状态 | 说明 |
|------|------|
| **NEW** | 新建，还未调用 `start()` |
| **RUNNABLE** | 就绪/运行中，等待 CPU 调度或正在执行 |
| **BLOCKED** | 阻塞，等待获取锁（synchronized） |
| **WAITING** | 等待，需被显式唤醒（`wait/join/park`） |
| **TIMED_WAITING** | 超时等待（`sleep/wait(time)/join(time)/parkNanos`） |
| **TERMINATED** | 终止，线程执行完毕 |

**状态转换图：**

```
NEW ──start()──▶ RUNNABLE ──run()结束──▶ TERMINATED
                    │
           获取锁失败/sync进入
                    ▼
                BLOCKED
                    │
           获取到锁/被notify
                    ▼
                RUNNABLE
                    │
         wait/join/park/sleep
                    ▼
          WAITING / TIMED_WAITING
                    │
          notify/notifyAll/超时
                    ▼
                RUNNABLE
```

---

## 二、synchronized 关键字

### 5. synchronized 的底层原理是什么？

**synchronized** 是 JVM 层面的互斥锁，底层基于 **Monitor 对象**（监视器锁）实现。

**在 Java 对象头中，Mark Word 记录了锁信息：**

```
无锁状态 → 偏向锁 → 轻量级锁 → 重量级锁
```

**锁升级过程（JDK 1.6 优化后）：**

```
偏向锁 ──> 轻量级锁 ──> 重量级锁（锁膨胀，不可逆）
```

- **偏向锁**：同一线程多次获取锁时，减少 CAS 操作
- **轻量级锁**：多线程交替执行时，使用 CAS 自旋获取锁
- **重量级锁**：多线程竞争激烈时，升级为操作系统 Mutex 锁

**代码层面：**

```java
// 1. 同步代码块（使用 monitorenter/monitorexit 指令）
synchronized (this) {
    // 临界区
}

// 2. 同步方法（使用 ACC_SYNCHRONIZED 标志）
public synchronized void method() {
    // 临界区
}
```

**字节码对比：**
- `synchronized` 代码块：编译为 `monitorenter` + `monitorexit` 两条指令
- `synchronized` 方法：在方法标志位设置 `ACC_SYNCHRONIZED`

### 6. synchronized 和 volatile 的区别？

| 对比 | synchronized | volatile |
|------|-------------|----------|
| 原子性 | ✅ 保证 | ❌ 不保证 |
| 可见性 | ✅ 保证 | ✅ 保证 |
| 有序性 | ✅ 保证（禁止重排序） | ✅ 保证（禁止重排序） |
| 是否阻塞 | ✅ 阻塞 | ❌ 非阻塞 |
| 使用场景 | 复合操作、多条语句同步 | 单一变量读写、状态标志 |

```java
// volatile 适用场景：单一状态标志位
volatile boolean running = true;
// 线程1
while (running) { /* 循环 */ }
// 线程2
running = false; // 停止线程1
```

**volatile 原理：** 加入 `volatile` 关键字后，编译时会增加 `Lock` 前缀指令，该指令强制将对内存的修改立即写回主存，并使其他 CPU 的缓存行失效（**缓存一致性协议**，如 MESI）。

### 7. synchronized 和 Lock 的区别？

| 对比 | synchronized | Lock（ReentrantLock） |
|------|-------------|----------------------|
| 实现层级 | JVM 层面 | JDK API 层面 |
| 锁获取 | 自动获取/释放 | 需手动 `lock()` 和 `unlock()` |
| 可中断性 | 等待不可中断 | `lockInterruptibly()` 可响应中断 |
| 超时机制 | 无 | `tryLock(time, unit)` |
| 公平性 | 非公平 | 支持公平/非公平 |
| 条件变量 | `wait/notify` | `Condition.await/signal` |
| 性能 | 优化后和 Lock 接近 | 高并发下略优 |

```java
// Lock 的使用模板
Lock lock = new ReentrantLock();
lock.lock();
try {
    // 临界区
} finally {
    lock.unlock(); // 必须在 finally 中释放
}
```

---

## 三、volatile 关键字

### 8. volatile 能保证原子性吗？

**不能。** volatile 只能保证可见性和有序性，不能保证原子性。

```java
volatile int count = 0;

// 多线程执行 count++，结果会小于预期
// 因为 count++ = 读 + 改 + 写，三步操作，volatile 只保证每一步的可见性
```

要保证原子性，需使用 `synchronized`、`AtomicInteger` 或 `Lock`。

```java
AtomicInteger count = new AtomicInteger(0);
count.incrementAndGet(); // CAS 操作，保证原子性
```

### 9. volatile 如何禁止指令重排？

volatile 通过在读写操作前后插入**内存屏障（Memory Barrier）**来禁止指令重排序。

**JVM 内存屏障策略：**

```
// 写 volatile 变量
StoreStore 屏障 → volatile 写操作 → StoreLoad 屏障

// 读 volatile 变量
LoadLoad 屏障 → volatile 读操作 → LoadStore 屏障
```

**经典案例：DCL 单例模式**

```java
public class Singleton {
    private static volatile Singleton instance;
    
    private Singleton() {}
    
    public static Singleton getInstance() {
        if (instance == null) {               // 第一次检查
            synchronized (Singleton.class) {
                if (instance == null) {       // 第二次检查
                    instance = new Singleton(); // volatile 防止指令重排
                }
            }
        }
        return instance;
    }
}
```

**为什么必须加 volatile？**
`instance = new Singleton()` 在字节码层面分三步：
1. 分配内存空间
2. 初始化对象
3. 将引用指向内存地址

不加 volatile 时，2 和 3 可能被重排，导致其他线程拿到**未初始化完成**的对象。

---

## 四、线程通信

### 10. wait/notify 和 sleep 的区别？

| 对比 | wait/notify | sleep |
|------|------------|-------|
| 所属类 | Object 类 | Thread 类 |
| 释放锁 | ✅ 释放锁 | ❌ 不释放锁 |
| 唤醒方式 | 需 notify/notifyAll 唤醒 | 时间到自动唤醒 |
| 使用前提 | 必须在 synchronized 块中 | 无要求 |
| 用途 | 线程间通信 | 让出 CPU 指定时间 |

```java
// wait/notify 经典模式：生产者-消费者
synchronized (queue) {
    while (queue.isEmpty()) {
        queue.wait(); // 释放锁，等待生产者
    }
    queue.poll();
    queue.notifyAll(); // 通知生产者
}
```

### 11. `notify()` 和 `notifyAll()` 的区别？

- **`notify()`**：随机唤醒一个等待线程（可能导致信号丢失）
- **`notifyAll()`**：唤醒所有等待线程（更安全，推荐使用）

**为什么推荐 notifyAll？**
`notify()` 唤醒的线程可能不是期望的线程，造成**信号丢失**或**死锁**。

### 12. `Thread.join()` 的作用？

`join()` 让当前线程等待目标线程执行完毕。

```java
Thread t = new Thread(() -> {
    // 耗时任务
});
t.start();
t.join(); // 主线程等待 t 执行完毕
System.out.println("t 已结束，继续执行");
```

**原理：** `join()` 内部调用了 `wait(0)`，当目标线程执行完毕后，JVM 会调用 `notifyAll()` 唤醒等待线程。

---

## 五、并发编程基础问题

### 13. 什么是线程安全？如何保证？

**线程安全**：多个线程同时访问共享数据时，程序仍然能正确执行。

**保证线程安全的几种方式：**

| 方式 | 说明 | 示例 |
|------|------|------|
| 互斥同步 | 加锁，保证临界区互斥访问 | synchronized、Lock |
| 非阻塞同步 | CAS，无锁编程 | AtomicInteger、LongAdder |
| 无同步方案 | 不共享数据 | ThreadLocal、局部变量 |
| 不可变对象 | 数据不可修改 | final、不可变集合 |

### 14. ThreadLocal 的原理？

**ThreadLocal** 为每个线程维护一份独立的变量副本，实现线程隔离。

**底层原理：**

```
Thread
  └── ThreadLocalMap          ← 每个线程维护自己的 Map
        ├── Entry(key=TL1, value="线程A的副本")
        ├── Entry(key=TL2, value="线程A的另一份副本")
        └── ...
```

**关键点：**
- ThreadLocalMap 的 key 是 **弱引用（WeakReference）**，防止内存泄漏
- 但 value 是强引用，使用完需调用 `remove()` 避免内存泄漏

```java
private static ThreadLocal<SimpleDateFormat> dateFormat = 
    ThreadLocal.withInitial(() -> new SimpleDateFormat("yyyy-MM-dd"));

// 线程安全地使用 SimpleDateFormat（该类本身非线程安全）
String date = dateFormat.get().format(new Date());
```

**内存泄漏场景：** 线程池中线程复用，ThreadLocal 使用完后未 remove，导致 value 一直无法回收。

### 15. 什么是上下文切换？开销有多大？

**上下文切换**：CPU 从一个线程切换到另一个线程执行时，需要保存当前线程的状态（程序计数器、寄存器等），加载新线程的状态。

**开销包括：**
- 保存/恢复寄存器状态
- 缓存失效（L1/L2 cache miss）
- TLB（页表缓存）失效
- 操作系统调度开销

**减少上下文切换的方法：**
- 无锁并发编程（CAS）
- 减少线程数（合理设置线程池大小）
- 使用协程（虚拟线程）
- 避免创建过多线程

---

## 总结

Java 并发编程的基础奠定了后续 JUC 工具类的理解基石。核心要点：

1. **线程的 6 种状态**和状态转换是面试必问
2. **synchronized** 理解锁升级过程和 Monitor 原理
3. **volatile** 搞清楚可见性、有序性，但不能保证原子性
4. **wait/notify** 必须在 synchronized 块中使用
5. **ThreadLocal** 注意内存泄漏问题

下一篇：[《Java并发常见面试题总结（二）：JUC进阶篇》](/2026/06/09/Java并发常见面试题总结（二）：JUC进阶篇/) 将深入讲解 JUC 包中的核心工具类。
