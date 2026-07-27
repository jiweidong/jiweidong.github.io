---
title: 【并发编程】Java Thread 源码深度解析：线程状态机、生命周期与操作系统线程映射
date: 2026-07-27 08:00:00
tags:
  - Java
  - 线程
  - Thread
  - 并发编程
  - JVM
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】Java Thread 源码深度解析：线程状态机、生命周期与操作系统线程映射

## 前言

提起 Java 多线程，每个人都能说出继承 `Thread` 或实现 `Runnable`。但 `Thread` 类的底层源码是怎样的？Java 线程和操作系统线程是什么关系？`start()` 和 `run()` 底层到底做了什么？

这些问题是 Java 面试中最高频的"基础深挖"类题目——看似基础，想答得深入却需要真正理解源码。

本文从 `Thread` 源码出发，深入分析线程的创建、启动、状态切换、生命周期以及底层实现。

---

## 一、Thread 类的整体架构

```java
// java.lang.Thread (JDK 21 源码概览)
public class Thread implements Runnable {
    // 线程名
    private volatile String name;
    
    // 线程优先级（1-10，默认5）
    private int priority;
    
    // 是否为守护线程
    private boolean daemon;
    
    // 线程组
    private ThreadGroup group;
    
    // 上下文类加载器
    private ClassLoader contextClassLoader;
    
    // 线程本地变量
    ThreadLocal.ThreadLocalMap threadLocals = null;
    ThreadLocal.ThreadLocalMap inheritableThreadLocals = null;
    
    // 可执行目标（Runnable 任务）
    private Runnable target;
    
    // 线程状态（volatile 保证可见性）
    private volatile int threadStatus;
    
    // ⭐ 真正的操作系统线程句柄（native 层）
    private long tid;       // 线程 ID
    private volatile long nativeParkEventPointer; // 用于 park/unpark
}
```

### 1.1 Thread 的构造方法链

```java
// 无参构造
public Thread() {
    init(null, null, "Thread-" + nextThreadNum(), 0);
}

// 指定 Runnable
public Thread(Runnable target) {
    init(null, target, "Thread-" + nextThreadNum(), 0);
}

// 指定名称
public Thread(String name) {
    init(null, null, name, 0);
}

// 核心——init 方法
private void init(ThreadGroup g, Runnable target, String name, long stackSize, 
                  AccessControlContext acc, boolean inheritThreadLocals) {
    // 1. 线程名不能为空
    if (name == null) throw new NullPointerException("name cannot be null");
    this.name = name;
    
    // 2. 设置当前线程为父线程
    Thread parent = currentThread();
    
    // 3. 设置线程组
    if (g == null) {
        g = parent.getThreadGroup();
    }
    
    // 4. 设置守护线程标志（继承父线程的 daemon 属性）
    this.daemon = parent.isDaemon();
    
    // 5. 设置优先级（不能超过线程组的最大优先级）
    this.priority = parent.getPriority();
    
    // 6. 设置上下文类加载器
    if (SecurityManager == null || isCCLOverridden(parent.getClass()))
        this.contextClassLoader = parent.getContextClassLoader();
    
    // 7. 设置可继承的 ThreadLocal
    if (inheritThreadLocals && parent.inheritableThreadLocals != null)
        this.inheritableThreadLocals = 
            ThreadLocal.createInheritedMap(parent.inheritableThreadLocals);
    
    // 8. 分配线程 ID（静态原子变量生成）
    this.tid = nextThreadID();
    
    // 9. 设置堆栈大小（0 表示使用 JVM 默认值）
    this.stackSize = stackSize;
}
```

**关键洞察**：新线程会**继承**父线程的 daemon、优先级、contextClassLoader、inheritableThreadLocals 等属性。这就是为什么守护线程里创建的子线程默认也是守护线程。

---

## 二、线程状态机

### 2.1 Java 中的 6 种线程状态

```java
public enum State {
    NEW,        // 新建，尚未 start()
    RUNNABLE,   // 可运行（就绪 + 运行中）
    BLOCKED,    // 阻塞等待监视器锁
    WAITING,    // 无限期等待（Object.wait() 无超时 / Thread.join() / LockSupport.park()）
    TIMED_WAITING, // 限时等待（Thread.sleep() / Object.wait(timeout) / Thread.join(timeout)）
    TERMINATED; // 终止
}
```

### 2.2 线程状态转换图

```
                        ┌───────────────────────────┐
                        │          NEW               │
                        │  (new Thread() 创建后)      │
                        └─────────────┬─────────────┘
                                      │ start()
                                      ↓
                        ┌───────────────────────────┐
        ┌──────────────>│        RUNNABLE            │<──────────────┐
        │               │  (就绪队列 / 正在运行)       │               │
        │               └────┬──────────┬──────────┬─┘               │
        │                    │          │          │                  │
        │        获取锁失败   │   sleep() │ wait()  │ 等待 I/O        │
        │                    │   join()  │ park()  │ 或锁竞争结束     │
        ↓                    ↓          ↓          │                  │
   ┌────────┐        ┌──────────┐  ┌──────────┐    │                  │
   │BLOCKED │        │TIMED_WAI-│  │ WAITING  │    │                  │
   │等待锁   │        │  TING    │  │ 无限期等待 │    │                  │
   └────┬───┘        └─────┬────┘  └────┬─────┘    │                  │
        │                  │            │           │                  │
        │    超时/notify/  │     notify/│           │                  │
        │    interrupt     │    unpark   │           │                  │
        └──────────────────┴────────────┴───────────┘                  │
               ↓                                                       │
        ┌───────────────────────────┐                                  │
        │       TERMINATED          │──────────────────────────────────┘
        │  (run() 正常结束 / 异常)    │     (不可逆，不能再次 start())
        └───────────────────────────┘
```

### 2.3 验证状态转换的代码示例

```java
public class ThreadStateDemo {
    public static void main(String[] args) throws Exception {
        Thread t = new Thread(() -> {
            try {
                Thread.sleep(500);
                synchronized (ThreadStateDemo.class) {
                    Thread.sleep(500);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
        
        // NEW
        System.out.println("After new: " + t.getState());

        t.start();
        // RUNNABLE
        System.out.println("After start: " + t.getState());

        Thread.sleep(100);
        // 大概率是 TIMED_WAITING (Thread.sleep)
        System.out.println("During sleep: " + t.getState());

        t.join();
        // TERMINATED
        System.out.println("After join: " + t.getState());
    }
}
```

---

## 三、start() 方法的底层机制

`start()` 是最关键的方法——它让 Java 线程从 NEW 进入 RUNNABLE。

### 3.1 start() 源码

```java
public synchronized void start() {
    // 1. 检查线程状态——只能 start() 一次
    if (threadStatus != 0)
        throw new IllegalThreadStateException();
    
    // 2. 通知线程组：此线程即将启动
    group.add(this);
    
    // 3. ⭐ JNI 调用——创建操作系统的原生线程
    boolean started = false;
    try {
        start0();  // native 方法
        started = true;
    } finally {
        try {
            if (!started) {
                group.threadStartFailed(this);
            }
        } catch (Throwable ignore) {}
    }
}

// JNI 方法——调用 JVM 创建操作系统线程
private native void start0();
```

### 3.2 start0() 的 JVM 实现

`start0()` 是 native 方法，在 HotSpot 源码中的对应实现：

```cpp
// HotSpot: src/hotspot/share/runtime/thread.cpp
static void JVM_StartThread(JNIEnv* env, jobject jthread) {
    // 1. 创建原生线程
    JavaThread* java_thread = new JavaThread(&thread_entry, ..);
    
    // 2. 在操作系统层面创建线程
    //    —— 在 Linux 上通过 pthread_create
    //    —— 在 Windows 上通过 CreateThread
    os::create_thread(java_thread, ..);
    
    // 3. 启动线程
    //    —— 不同平台实现不同
    //    —— Linux: pthread_create 并设置 CPU 亲和性
    os::start_thread(java_thread);
}
```

### 3.3 Linux 平台的 pthread_create

```cpp
// HotSpot: src/hotspot/os/linux/os_linux.cpp
bool os::create_thread(Thread* thread, ...) {
    pthread_t tid;
    // 创建 pthread
    int ret = pthread_create(&tid, &attr, 
                             (void* (*)(void*)) java_start, 
                             thread);
    if (ret != 0) {
        return false;
    }
    return true;
}

// 线程入口函数
static void* java_start(Thread* thread) {
    // 设置线程栈大小
    // 设置信号掩码
    // 初始化 JNI
    // 调用 Thread::run()
    thread->run();
    return 0;
}
```

**核心结论**：`t.start()` → `start0()` JNI → HotSpot 创建 `JavaThread` → `pthread_create` 创建 OS 线程 → 新线程执行 Java 线程的 `run()` 方法。

> 在虚拟线程（Virtual Threads）中，这种 1:1 的 OS 线程映射变为 M:N 的载体线程调度——这也是虚拟线程能支持百万级并发的根本原因。

---

## 四、run() 方法的执行流

```java
// Thread.run()
@Override
public void run() {
    if (target != null) {
        target.run();  // 执行传入的 Runnable
    }
}
```

**重要区分**：

```java
Thread t = new Thread(() -> System.out.println("running"));

t.run();    // ❌ 不会创建新线程！在当前线程同步执行
t.start();  // ✅ 新线程异步执行 run()
```

**图解**：
```
t.run() → 只在 main 线程中执行 run()，没有新线程
t.start() → 创建 OS 线程 → OS 线程调用 t.run()
```

---

## 五、线程的终止机制

### 5.1 为什么 stop() 被弃用？

```java
@Deprecated(since = "1.2")
public final void stop() {
    // 强制终止线程——释放所有监视器锁
    // 导致对象状态不一致，已被弃用
}
```

`stop()` 被弃用是因为它会强制终止线程并释放所有锁，导致被保护的数据处于 **不一致状态**。例如，线程正在向 BankAccount 转账——从 A 扣钱后、加到 B 前被 stop()，钱就丢了。

### 5.2 正确的终止方式：中断协作

```java
public class GracefulShutdown {
    
    public static void main(String[] args) throws InterruptedException {
        Thread worker = new Thread(() -> {
            // 通过 Thread.currentThread().isInterrupted() 检查中断标志
            while (!Thread.currentThread().isInterrupted()) {
                try {
                    // 模拟工作
                    Thread.sleep(100);
                } catch (InterruptedException e) {
                    // sleep() 被中断时，会清除中断标志
                    // 需要重新设置中断标志
                    Thread.currentThread().interrupt();
                    System.out.println("收到中断信号，清理资源...");
                    break;
                }
            }
            System.out.println("Worker 结束");
        });
        
        worker.start();
        Thread.sleep(500);
        worker.interrupt();  // 设置中断标志
    }
}
```

**中断机制的底层操作：**

```java
// Thread.interrupt()
public void interrupt() {
    if (this != currentThread()) {
        checkAccess();
    }
    synchronized (blockerLock) {
        Interruptible b = blocker;
        if (b != null) {
            interrupt0();    // native 方法，设置中断标志
            b.interrupt(this); // 通知 I/O 中断
            return;
        }
    }
    interrupt0();
}
```

---

## 六、线程调度与优先级

### 6.1 线程优先级

```java
// Thread 中的优先级常量
public static final int MIN_PRIORITY = 1;
public static final int NORM_PRIORITY = 5;
public static final int MAX_PRIORITY = 10;
```

**重要事实**：Java 线程优先级在大多数操作系统上**只是建议性**的：

| 平台 | 优先级映射 | 实际效果 |
|------|-----------|---------|
| Linux | 1-10 映射到 nice 值 -20~19 | **几乎无效果**。Linux 的完全公平调度器（CFS）基本无视 nice 值的细微差别 |
| Windows | 1-10 映射到 7 个优先级类 | 有效。高优先级线程获得更多 CPU 时间 |
| macOS | 1-10 映射到 0-47 | 有一定效果 |

**实战中不要依赖优先级来控制线程调度**——不同平台行为不一致。

### 6.2 yield() 和 sleep()

```java
// 提示调度器：当前线程愿意放弃 CPU
// 只是提示，调度器可能忽略
public static native void yield();

// 当前线程暂停指定毫秒
// 不释放已持有的锁！
public static native void sleep(long millis) throws InterruptedException;
```

```java
// sleep 的精确版本
public static void sleep(long millis, int nanos) 
    throws InterruptedException {
    if (millis < 0) throw new IllegalArgumentException("timeout value is negative");
    if (nanos < 0 || nanos > 999999) throw new IllegalArgumentException("nanosecond timeout value out of range");
    if (nanos >= 500000 || (nanos != 0 && millis == 0)) {
        millis++;
    }
    sleep(millis);
}
```

---

## 七、join() 实现原理

```java
// Thread.join()
public final synchronized void join(long millis) throws InterruptedException {
    long base = System.currentTimeMillis();
    long now = 0;

    if (millis < 0) throw new IllegalArgumentException("timeout value is negative");

    if (millis == 0) {
        // 无限等待——直到 isAlive() 返回 false
        while (isAlive()) {
            wait(0);  // ⭐ 依赖 wait/notify 机制
        }
    } else {
        while (isAlive()) {
            long delay = millis - now;
            if (delay <= 0) break;
            wait(delay);
            now = System.currentTimeMillis() - base;
        }
    }
}
```

**join 的底层机制**：

```
main 线程调用 t.join():
    → main 线程进入 t 对象的等待集 (wait set)
    → main 线程状态变为 WAITING 或 TIMED_WAITING
    
t 线程执行完毕时:
    → JVM 在 native 层调用 t.notifyAll()
    → main 线程被唤醒，继续执行
```

**关键代码（HotSpot 源码）**：

```cpp
// HotSpot: src/hotspot/share/runtime/thread.cpp
void JavaThread::exit() {
    // ... 清理资源 ...
    
    // 通知所有等待此线程结束的线程
    ensure_join(this);
}

static void ensure_join(JavaThread* thread) {
    // 获取 Thread 对象的监视器锁
    Handle threadObj(thread, thread->threadObj());
    
    ObjectLocker lock(threadObj, thread);
    // 清理线程对象
    thread->clear_pending_exception();
    
    // ⭐ notifyAll() 唤醒所有通过 join() 等待的线程
    java_lang_Thread::set_thread_status(threadObj(), TERMINATED);
    lock.notifyAll(thread);
}
```

这就是为什么 `join()` 是 `synchronized` 方法——它在当前线程对象上调用 `wait()`，需要持有该对象的监视器锁。

---

## 八、守护线程

```java
public class DaemonDemo {
    public static void main(String[] args) throws InterruptedException {
        Thread daemon = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(1000);
                    System.out.println("守护线程运行中...");
                } catch (InterruptedException e) {
                    break;
                }
            }
        });
        daemon.setDaemon(true);  // 必须在 start() 之前设置
        daemon.start();
        
        Thread.sleep(3000);
        System.out.println("主线程结束，JVM 退出，守护线程自动终止");
    }
}
```

**守护线程的特性：**

1. `setDaemon(true)` 必须在 `start()` **之前**调用，否则抛出 `IllegalThreadStateException`
2. JVM 在**所有非守护线程终止后**立即退出，不等待守护线程
3. 守护线程中的 finally 块**不一定执行**（JVM 直接退出）
4. 新线程默认继承父线程的 daemon 标志

---

## 九、Thread vs Runnable vs Callable

| 特性 | Thread | Runnable | Callable |
|------|--------|----------|----------|
| 返回值 | 无 | 无 | 有（Future） |
| 异常处理 | 只能在内部 catch | 只能在内部 catch | 可抛异常给调用方 |
| 复用 | 每次都要 new | 可复用执行 | 可复用执行 |
| 启动方式 | start() | new Thread(r).start() | 线程池 submit() |
| 灵活性 | 受单继承限制 | 接口，更灵活 | 接口，更灵活 |

**推荐做法**：**永远优先使用 Runnable/Callable + 线程池**，而不是直接继承 Thread。

---

## 十、Thread 类中的 ThreadLocal 机制

```java
// Thread 类中维护了两个 ThreadLocalMap
// 每个线程都有自己的 ThreadLocalMap
ThreadLocal.ThreadLocalMap threadLocals = null;
ThreadLocal.ThreadLocalMap inheritableThreadLocals = null;
```

- `threadLocals` — 当前线程的 ThreadLocal 变量
- `inheritableThreadLocals` — 可被子线程继承的 ThreadLocal 变量（new Thread 时复制）

详见之前关于 ThreadLocal 源�的深度文章。

---

## 十一、面试高频追问

### Q1：Thread.sleep(0) 有什么用？

主动触发一次**线程上下文切换**。虽然不暂停任何时间，但会让当前线程**重新参与 CPU 竞争**。在极端的自旋等待场景下可用于让出 CPU。

### Q2：线程池中如何拿到线程的异常？

```java
// 方式一：UncaughtExceptionHandler
Thread t = new Thread(() -> { throw new RuntimeException("异常"); });
t.setUncaughtExceptionHandler((thread, throwable) -> {
    System.out.println("线程 " + thread.getName() + " 异常: " + throwable.getMessage());
});
t.start();

// 方式二：线程池中通过 submit() 获取 Future
ExecutorService pool = Executors.newFixedThreadPool(2);
Future<?> future = pool.submit(() -> { throw new RuntimeException("异常"); });
try {
    future.get();  // 抛出 ExecutionException
} catch (ExecutionException e) {
    System.out.println("任务异常: " + e.getCause().getMessage());
}
```

### Q3：一个线程可以 start() 两次吗？

不可以。`start()` 会检查 `threadStatus != 0`，第二次调用时会是 `TERMINATED` 状态，抛出 `IllegalThreadStateException`。

### Q4：线程是越轻量越好吗？

在传统平台线程中，**每个线程都对应一个 OS 线程**，创建、上下文切换、销毁都有成本。所以线程池是必要的。这也是 Java 21 引入虚拟线程（Virtual Threads）的原因——虚拟线程是 JVM 管理的用户态线程，创建成本极低。

### Q5：Java 线程和 OS 线程是什么关系？

**1:1 关系**（平台线程）。每个 Java 线程在 HotSpot JVM 中都对应一个操作系统原生线程（Linux 上是 pthread，Windows 上是 Windows Thread）。`start()` 就是调用 `pthread_create` 创建 OS 线程。

---

## 总结

线程看似基础，但 `Thread` 类的源码中包含了大量设计精妙的机制：

- **状态机**：6 种状态 + wait/notify 机制构成完整的线程生命周期
- **native 方法**：start0() → HotSpot → pthread_create，是 Java 跨平台线程的基石
- **join 机制**：基于 wait/notify 的线程间协作通信
- **中断协作**：替代废弃的 stop()，提供优雅终止能力
- **ThreadLocal 继承**：父子线程间的上下文传递

理解这些底层机制后，你在面对线程相关问题时（死锁分析、线程 dump 解读、性能调优），会更有全局视角——知道哪些行为是 JVM 层面的，哪些是 OS 层面的，哪些是 JDK 库层面的。
