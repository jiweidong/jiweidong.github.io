---
title: 【Java 21+ 并发】虚拟线程 Pinning 深度解析：synchronized 陷阱、定位手段与 JDK 24 修复
date: 2026-09-21 08:00:00
tags:
  - Java
  - 虚拟线程
  - 并发
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【Java 21+ 并发】虚拟线程 Pinning 深度解析：synchronized 陷阱、定位手段与 JDK 24 修复

## 面试官：虚拟线程你都上生产了，那遇到过 Pinning 吗？

这个问题是虚拟线程面试的「分水岭」。能说出「虚拟线程 = 用户态轻量线程、由 ForkJoinPool 调度、`synchronized` 会阻塞载体线程」的是及格线；能讲清楚**为什么 `synchronized` 会导致 pinning、怎么定位、JDK 24 怎么修的**，才是真正在生产里趟过坑的人。

先说结论：**虚拟线程（Virtual Thread）的核心卖点是「遇到阻塞就卸载（unmount）载体线程」。而 Pinning 就是指——本该卸载的虚拟线程，因为某种原因无法卸载，只能傻等，把宝贵的载体线程（Carrier Thread）一起拖住。**

Pinning 是虚拟线程最容易被低估的性能杀手。因为它的表现非常隐蔽：程序不报错，吞吐却上不去。

---

## 一、回顾：虚拟线程为什么不阻塞载体线程

虚拟线程的执行模型是 **M:N 调度**：

```text
   N 个虚拟线程（百万级）          M 个载体线程（= CPU 核数）
  ┌──────┐ ┌──────┐ ┌──────┐
  │ VT-1 │ │ VT-2 │ │ VT-3 │  ...
  └──┬───┘ └──┬───┘ └──┬───┘
     │        │        │
     └────────┼────────┘
              ▼
      ForkJoinPool（默认并行度 = CPU 核数）
     ┌────────┐ ┌────────┐
     │Carrier1│ │Carrier2│
     └────────┘ └────────┘
```

当虚拟线程执行到一个**可卸载的阻塞操作**时：

```java
Thread.sleep(1000);              // 卸载
socket.getInputStream().read();  // 卸载（NIO 已适配）
queue.take();                    // 卸载（java.util.concurrent 已适配）
park();                          // 卸载
```

JVM 会把虚拟线程的**栈帧从载体线程的栈上「搬运」到堆上**（continuation 的 stack chunk），然后释放载体线程去跑别的虚拟线程。等到 I/O 就绪、等待条件满足，再把栈搬回来继续执行。

**关键前提：栈能搬。** 只要栈上有「JVM 无法搬运或无法安全恢复」的东西，就不能卸载。

---

## 二、Pinning 的两个经典原因

### 2.1 原因一：`synchronized` 块（JDK 21~23）

这是最著名的坑。在 JDK 21 到 23 中：

```java
// ❌ 会 pinning
synchronized (lock) {
    Thread.sleep(1000);      // 无法卸载！载体线程被占用
}

// ✅ 不会 pinning
lock.lock();                 // ReentrantLock
try {
    Thread.sleep(1000);      // 正常卸载
} finally {
    lock.unlock();
}
```

**为什么 `synchronized` 会 pin？**

因为 `synchronized` 在 HotSpot 里的实现是 **monitor（对象头 Mark Word + ObjectMonitor）**，而 ObjectMonitor 记录的是**线程身份**。虚拟线程在被卸载/重新挂载时，可能会**运行在不同的载体线程上**。如果持有 monitor 的虚拟线程被卸载，monitor 的所有者信息就「悬空」了——从其他线程视角看，这个 monitor 被一个「当前没有任何载体运行」的线程持有，会导致：

- 其他真实线程尝试获取该 monitor 时无法推进；
- 死锁检测、所有权判断全部失效。

所以 HotSpot 的选择是：**只要虚拟线程持有 `synchronized` 监视器，就禁止卸载（pin 住）**。这是正确性优先的保守策略。

### 2.2 原因二：Native 栈帧

当调用栈上存在 **native 方法帧**（JNI）时，同样无法卸载：

```java
// 典型场景
FileInputStream.read()          // JDK 21 里是 native read，会 pin
Socket.getInputStream().read()  // 早期实现也有此问题
LoadLibrary / JNI 调用
本地加密库、图像库、数据库驱动中的 native 调用
```

**注意区分**：`FileInputStream` 在新版本里已经用 FFM/NIO 重写；而第三方 native 库（比如某些加密 SDK、`libjpeg` 封装）短期无解。

不过，native pinning 的影响通常可控，因为 **native 调用大多很快返回**，不会长时间占用载体线程。**真正致命的是「在 synchronized 里做长时间阻塞 I/O」**。

---

## 三、Pinning 的危害：吞吐断崖

假设你的服务有 **8 个 CPU 核**，ForkJoinPool 并行度 = 8，即 8 个载体线程。

**理想情况（无 pinning）**：

```text
10,000 个虚拟线程，每个都在等数据库响应（耗时 50ms）
→ 8 个载体线程轮流服务，实际并发度 = 10,000
→ 吞吐 ≈ 10,000 / 0.05s = 200,000 QPS（理论）
```

**Pinning 情况（每个请求在 synchronized 里阻塞 50ms）**：

```text
同一时刻最多只有 8 个虚拟线程真正在「等待」
其余 9,992 个虚拟线程排队等不到载体线程！
→ 实际并发度 = 8
→ 吞吐 ≈ 8 / 0.05s = 160 QPS
```

**并发能力从一万掉到八。** 这就是为什么线上表现是「CPU 不高、QPS 很低、线程 dump 看不出问题」。

更隐蔽的是：

- **线程数看起来正常**（虚拟线程数量统计会显示很多，但它们都在等载体）；
- **CPU 利用率不高**（确实没算什么东西）；
- **GC 正常、内存正常**；
- **只有在压力上来时才暴露**，低峰期完全看不出。

---

## 四、怎么定位 Pinning

### 4.1 JFR 事件：`jdk.VirtualThreadPinned`

这是官方推荐的定位手段。启动 JFR 录制：

```bash
java -XX:StartFlightRecording=filename=vt.jfr,duration=60s,settings=profile -jar app.jar
```

然后用 `jfr` 命令查看：

```bash
jfr print --events jdk.VirtualThreadPinned vt.jfr
```

输出会包含：

```text
jdk.VirtualThreadPinned {
  startTime = 08:12:33.421
  duration = 1.05 s
  eventThread = "virtual-1234" (virtual)
  stackTrace = [
    com.example.UserService.queryUser(String) line: 42
    com.example.UserService$$Lambda$123/0x... run()
    ...
  ]
}
```

**关键字段是 `stackTrace`——它会直接指到引发 pinning 的那一行。**

### 4.2 诊断阈值：`jdk.tracePinnedThreads`

老一些的 JDK 版本支持这个诊断开关，可以打印 pinning 栈：

```bash
java -Djdk.tracePinnedThreads=full -jar app.jar
```

或者只打印摘要：`-Djdk.tracePinnedThreads=short`。

> **注意**：这个选项在 JDK 24 之后因为 `synchronized` 不再 pin 而基本失去意义。JDK 21~23 可用。

### 4.3 自定义监控：虚拟线程 API

JDK 21+ 提供了 `Thread.currentThread().isVirtual()` 和 `Thread.ofVirtual()` 等 API，可以自己埋点：

```java
public class PinningMonitor {
    public static void watch(String name, Runnable task) {
        Thread t = Thread.ofVirtual().name(name).start(() -> {
            long start = System.nanoTime();
            task.run();
            long cost = System.nanoTime() - start;
            // 结合 JFR 事件做告警
        });
    }
}
```

更实用的做法是**订阅 JFR 流式事件**（JDK 14+ 的 `jdk.jfr.consumer`）：

```java
try (RecordingStream rs = new RecordingStream()) {
    rs.enable("jdk.VirtualThreadPinned").withThreshold(Duration.ofMillis(20));
    rs.onEvent("jdk.VirtualThreadPinned", e -> {
        log.warn("Pinned for {} ms, stack: {}",
                e.getDuration().toMillis(),
                e.getStackTrace());
    });
    rs.start();
}
```

**推荐线上常驻一个低频告警**：阈值设 20ms 以上，超过就上报。这是把「玄学性能问题」变成「可观测问题」的关键。

---

## 五、修复方案

### 5.1 方案一：用 `ReentrantLock` 替换 `synchronized`（万能解）

```java
// ❌ 坏味道
public synchronized void doWork() {
    httpClient.send(req);   // 长时间阻塞
}

// ✅ 好味道
private final ReentrantLock lock = new ReentrantLock();

public void doWork() {
    lock.lock();
    try {
        httpClient.send(req);
    } finally {
        lock.unlock();
    }
}
```

`java.util.concurrent.locks` 下的锁**已经全面适配虚拟线程**：等待锁时会卸载，被唤醒时重新挂载。

**注意区分两类锁的语义：**

| 锁 | 虚拟线程行为 | 建议 |
| --- | --- | --- |
| `synchronized` | JDK ≤23：pinning；JDK 24+：可卸载 | JDK 24+ 可放心用 |
| `ReentrantLock` | 一直支持卸载 | 最稳妥 |
| `ReentrantReadWriteLock` | 支持卸载 | 读多写少优选 |
| `StampedLock` | 支持（但有 `synchronized` 内部细节需注意） | 谨慎 |
| `Semaphore` / `CountDownLatch` | 支持卸载 | 放心用 |

### 5.2 方案二：缩短 `synchronized` 临界区

如果实在不想改锁，**把阻塞操作移出同步块**：

```java
// ❌
synchronized (this) {
    Result r = slowRemoteCall();   // 50ms
    cache.put(key, r);
}

// ✅
Result r = slowRemoteCall();       // 在锁外做 I/O
synchronized (this) {
    cache.put(key, r);             // 临界区变成几纳秒
}
```

这个重构的本质是：**`synchronized` 只用来保护共享状态的读写，不要用来「串行化 I/O」**。很多老代码里 `synchronized` 是顺手加的「整块方法锁」，这是 pinning 的重灾区。

### 5.3 方案三：升级到 JDK 24+

**JEP 491（JDK 24）彻底解决了 `synchronized` 的 pinning 问题。**

核心思路是：**让虚拟线程在持有 monitor 时也能卸载**。实现上做了两件事：

1. **为虚拟线程重新设计 monitor 的所有权模型**——把 monitor 的所有者从「物理线程」改成「虚拟线程身份」，这样卸载后所有权依然有效；
2. **处理 monitor 与载体线程的解耦**——当虚拟线程被卸载时，如果它持有 monitor，JVM 需要保证其他线程在 `monitorenter` 时能看到正确的所有权状态，并能被正确唤醒。

从 JDK 24 开始：

```java
// JDK 24+：不再 pinning！
synchronized (lock) {
    Thread.sleep(1000);   // 正常卸载，载体线程去做别的
}
```

**所以升级路线图很清晰：**

- JDK 21/22/23：能用虚拟线程，但要严格自查 `synchronized`；
- **JDK 24+：放心用 `synchronized`**，pinning 只剩 native 帧一种原因。

### 5.4 方案四：处理 native pinning

- **优先替换实现**：`FileInputStream` → `Files.newInputStream` 或 `FileChannel`；
- **能异步就异步**：把 native 调用丢到平台线程池（`Executors.newFixedThreadPool`）里执行，虚拟线程只做编排；
- **实在不行就接受**：评估 native 调用的耗时，只要不是长阻塞，影响可控。

```java
// 把 native 阻塞调用隔离到平台线程池
private static final ExecutorService NATIVE_POOL =
        Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors() * 2);

public CompletableFuture<byte[]> nativeCall(byte[] in) {
    return CompletableFuture.supplyAsync(() -> nativeEncrypt(in), NATIVE_POOL);
}
```

---

## 六、一个完整的排查案例

**现象**：某订单查询接口改成虚拟线程后，压测 QPS 反而从 3,000 掉到 400，CPU 只有 15%。

**排查步骤**：

1. `jstack` 看载体线程栈——发现 8 个 ForkJoinPool worker 全部卡在同一个方法上：

```text
"ForkJoinPool-1-worker-1" ...
   at com.example.OrderCache.get(OrderCache.java:88)
   - waiting to lock <0x0000000712ab1234> (a com.example.OrderCache)
   at com.example.OrderService.query(OrderService.java:31)
```

2. 看第 88 行——`synchronized (this) { ... httpClient.get(...) ... }`；
3. 开 JFR，`jfr print --events jdk.VirtualThreadPinned` 确认 pinning，栈一致；
4. **修复**：把 HTTP 调用移到 `synchronized` 外，只把 `cache.put` 留在临界区；
5. **结果**：QPS 从 400 恢复到 4,200。

**教训**：虚拟线程不是「换成 `Thread.ofVirtual()` 就变快」。**它是把「阻塞等待」的成本从「占一个线程」降到「占一段堆内存」，前提是等待真的能够卸载。**

---

## 七、面试常见追问

**Q1：除了 `synchronized` 和 native，还有别的原因会 pin 吗？**

有。理论上任何导致**「栈不可搬运」或「JVM 无法安全恢复」**的情况都会。已知的还有：`class` 初始化过程、`Object.wait()`（实际也会 pin，本质是 monitor）、某些 JDK 内部持有原始锁的操作。面试时答 `synchronized` + native 帧这两条主因即可，能补充「本质是 monitor / 栈帧不可搬运」就更好。

**Q2：`Thread.sleep()` 会 pin 吗？**

单独调用不会。`Thread.sleep` 本身就是虚拟线程可卸载的阻塞点。**但如果你在 `synchronized` 块里 `sleep`，就会 pin。** 这就是最容易踩的组合。

**Q3：`ReentrantLock` 为什么就能卸载？**

因为 AQS 的等待队列是基于 `Node` 对象 + `LockSupport.park()` 实现的，**所有者信息记录在 AQS 的 `exclusiveOwnerThread` 字段（对象引用），不依赖物理线程身份**。虚拟线程 park 时挂起，unpark 时唤醒，JVM 能准确保存/恢复虚拟线程状态。

**Q4：虚拟线程数受什么限制？**

不受线程栈大小限制（栈在堆上，按需分配并会收缩），但受**内存**和**下游容量**限制。常见误区：以为可以随便开 100 万个然后打数据库——结果把数据库连接池打爆。**虚拟线程适合「大量、可等待」的 I/O 密集场景，不是用来绕过下游容量瓶颈的。**

**Q5：怎么决定该用虚拟线程还是响应式（WebFlux）？**

| 维度 | 虚拟线程 | 响应式 |
| --- | --- | --- |
| 编程模型 | 同步阻塞，直观 | 异步回调/链式，学习成本高 |
| 调试 | 栈完整，好排查 | 栈被切碎，难跟踪 |
| 存量代码 | 几乎零改造 | 需要全量重写 |
| 背压 | 无 | 原生支持 |
| 适用 | I/O 密集、代码以阻塞风格为主 | 高并发流式、需要背压 |

**我的建议**：**优先虚拟线程**。它用最低的心智成本拿到大部分异步收益；只有在需要精细背压控制、或者已经在响应式栈上时，才选 WebFlux。

---

## 八、总结

把这篇的核心压缩成一张清单：

- **Pinning = 虚拟线程无法卸载，载体线程被拖住**；
- **两大原因**：`synchronized` 监视器（JDK ≤23）、native 栈帧；
- **危害**：并发度塌缩到载体线程数，CPU 不高但 QPS 暴跌；
- **定位**：JFR 的 `jdk.VirtualThreadPinned` 事件 + 栈；`-Djdk.tracePinnedThreads`（≤23）；
- **修复**：`ReentrantLock` 替换、缩短临界区、隔离 native 调用、**升 JDK 24+（JEP 491 根治 `synchronized` 问题）**；
- **原则**：虚拟线程解决的是「等待的成本」，不是「下游的容量」。
