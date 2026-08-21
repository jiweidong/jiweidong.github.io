---
title: 【并发编程】SynchronousQueue 与 TransferQueue 深度解析：无缓冲队列的源码级探索
date: 2026-08-21 08:00:00
tags:
  - Java
  - 并发
  - 源码
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】SynchronousQueue 与 TransferQueue 深度解析：无缓冲队列的源码级探索

## 面试官：SynchronousQueue 容量是 0，那它凭什么还能叫队列？

大多数人对队列的第一印象是"先进先出的容器"，而 `SynchronousQueue` 恰恰是 BlockingQueue 家族里最叛逆的一个：**它的容量永远是 0，内部不存储任何元素**。一个线程 `put()` 一个元素，必须等另一个线程 `take()` 把它接走，put 才能返回；反之亦然。它本质是一个"线程间交接"的通道，而不是缓冲容器。

正因为这个特性，`Executors.newCachedThreadPool()` 才敢用它当工作队列——因为任务不会被积压，来了就交给线程处理，没线程就现场新建，从而实现了"无线程上限的弹性线程池"。

```java
// 经典用法：缓存线程池的工作队列
public static ExecutorService newCachedThreadPool() {
    return new ThreadPoolExecutor(0, Integer.MAX_VALUE,
            60L, TimeUnit.SECONDS,
            new SynchronousQueue<Runnable>());
}
```

如果面试官继续追问"它内部到底怎么实现交接的"，那就要进入源码层面了。今天我们从 `Transferer` 抽象说起，彻底吃透 `SynchronousQueue` 的两套实现（公平/非公平），再对比它的"亲兄弟" `LinkedTransferQueue`。

## 一、整体架构：Transferer 是灵魂

`SynchronousQueue` 的核心是一个内部抽象类 `Transferer`：

```java
abstract static class Transferer<E> {
    abstract E transfer(E e, boolean timed, long nanos);
}
```

- `e != null`：表示生产者要**移交**数据，返回值为空表示成功（被消费者接走）
- `e == null`：表示消费者要**接收**数据，返回值即收到的元素

`transfer` 这一个方法同时承载了 put / take / offer / poll 四种操作，堪称"一招鲜吃遍天"。

`SynchronousQueue` 在构造时根据 `fair` 参数选择两种实现：

| 构造参数 | 内部实现 | 特点 |
|---------|---------|------|
| `fair = false`（默认） | `TransferStack` | 后进先出（LIFO），吞吐量更高，但可能造成"饥饿" |
| `fair = true` | `TransferQueue` | 先进先出（FIFO），公平交接，吞吐略低 |

## 二、TransferStack：非公平模式下的栈式交接

`TransferStack` 用**栈**来组织等待的线程节点，节点有三种状态：

```java
static final class SNode {
    volatile SNode next;   // 栈的下一个节点
    volatile SNode match;  // 与当前节点配对的节点
    volatile Thread waiter;// 等待线程
    Object item;           // 数据
    int mode;              // REQUEST(0) 数据 / DATA(1) 数据 / FULFILLING(2)
}
```

**核心算法（dual stack / 双重数据结构）**：

1. 线程 A 来 put(1)，发现栈空 → 把自己包装成 `DATA` 节点压栈，然后自旋 + 阻塞等待配对
2. 线程 B 来 take()，发现栈顶是 `DATA` 节点 → 知道自己来"履行"（fulfill）对方了，于是压入一个 `FULFILLING` 节点
3. B 把 A 的节点标记为已配对（`match` 指向自己），唤醒 A，取走数据
4. 弹栈清理

关键源码（JDK 8 简化版）：

```java
SNode s = null;
if (e == null || (s = snode(s, e, h, mode)) != null) {
    // 尝试压栈
    if (casHead(h, s = snode(s, e, h, mode))) {
        // 自旋等待配对，超时则取消
        SNode m = awaitFulfill(s, timed, nanos);
        if (m == s) {          // 被取消了
            clean(s);          // 清理节点
            return null;
        }
        ...
    }
}
```

为什么非公平模式吞吐更高？因为**栈顶总是最新到达的线程**，新来的请求"插队"概率最大，热点集中在栈顶，CAS 竞争面小，缓存友好；代价是栈底的线程可能长期等不到配对（饥饿）。

## 三、TransferQueue：公平模式下的队列式交接

`TransferQueue` 用**队列**组织等待者，严格 FIFO：

```java
static final class QNode {
    volatile QNode next;
    volatile Object item;  // 数据；配对后置为自身（标记已消费）
    volatile Thread waiter;
    final boolean isData;  // 区分生产者/消费者
}
```

公平模式的流程：

1. 队列为空或队首节点类型与当前线程"同类"（都是生产者或都是消费者）→ 入队等待
2. 队首是"异类"节点 → 直接接管（fulfill）队首节点，出队，完成交接

```java
// 核心：节点入队后自旋/阻塞，被配对后返回
QNode s = new QNode(e, isData);
if (casTail(t = tail, s)) {       // CAS 入队
    ...
    Object x = awaitFulfill(s, e, timed, nanos);
    if (x == e) {                  // 等待超时取消
        clean(s);
        return null;
    }
    ...
}
```

对比一下两套实现：

| 维度 | TransferStack（非公平） | TransferQueue（公平） |
|------|----------------------|---------------------|
| 数据结构 | 栈（LIFO） | 队列（FIFO） |
| 公平性 | 后到先服务，可能饥饿 | 先到先服务 |
| 吞吐量 | 高（热点集中栈顶） | 略低 |
| 适用场景 | 追求性能、不关心顺序 | 需要公平、避免线程饿死 |

## 四、put / take 的完整调用链

以默认非公平模式为例：

```
put(e)          → transfer(e, true, 0)   // 无限等待
offer(e)        → transfer(e, true, 0)   // 立即返回，失败返回 false
offer(e, t, ns) → transfer(e, true, ns)  // 限时等待
take()          → transfer(null, true, 0) // 无限等待
poll()          → transfer(null, true, 0) // 立即返回
```

注意一个细节：`put` 和 `offer` 最终调用的都是同一个 `transfer`，区别只在 `timed` 参数。而 `awaitFulfill` 内部采用 **自旋 + LockSupport.park** 的两段式等待——先自旋一段时间（默认 32 次），没等到再挂起线程，这样能兼顾短交接场景的性能和长等待场景的 CPU 占用。

## 五、LinkedTransferQueue：有容量的"传递队列"

`LinkedTransferQueue` 是 `SynchronousQueue` 的增强版，它有两个身份：

- 它是一个**有容量的无界队列**（基于链表），可以正常入队出队
- 它实现了 `TransferQueue` 接口，支持**传递语义**（transfer / tryTransfer）

关键区别在 `xfer` 方法：

```java
public boolean add(E e)   { xfer(e, true, ASYNC, 0); return true; }
public void put(E e)      { xfer(e, true, ASYNC, 0); }
public boolean offer(E e) { xfer(e, true, ASYNC, 0); return true; }

public void transfer(E e) throws InterruptedException {
    if (xfer(e, true, SYNC, 0) != null)   // SYNC：必须等消费者接手才返回
        Thread.interrupted();
}

public boolean tryTransfer(E e) {         // ASYNC 变体：没人接手就入队
    return xfer(e, true, NOW, 0) == null;
}
```

`xfer` 的四种模式：

| 模式 | 行为 |
|------|------|
| `NOW` | 有消费者立即交接，否则返回失败（不等待不入队） |
| `ASYNC` | 有消费者立即交接，否则元素入队（对应 put/add） |
| `SYNC` | 有消费者立即交接，否则阻塞等待（对应 transfer） |
| `TIMED` | 限时等待交接 |

它同样使用"双重队列"算法（节点既可以是数据节点也可以是请求节点），并且从 JDK 8 开始引入了 `Spliterator` 和 CAS 优化，性能上被称为"无界版 SynchronousQueue + 普通队列的合体"。

## 六、SynchronousQueue vs LinkedTransferQueue vs ArrayBlockingQueue(1)

| 对比项 | SynchronousQueue | LinkedTransferQueue | ArrayBlockingQueue(1) |
|--------|-----------------|--------------------|---------------------|
| 容量 | 0 | 无界 | 1 |
| 是否缓冲 | 不缓冲，必须配对 | 可缓冲可传递 | 缓冲 1 个 |
| 公平模式 | 支持（构造参数） | 不支持（近似 FIFO） | 支持 |
| 内存占用 | 极低（无元素存储） | 随元素增长 | 固定 |
| 典型场景 | 缓存线程池、连接交接 | 生产者消费者 + 需要 transfer 语义 | 单缓冲槽、背压 |

**面试高频追问：为什么 ThreadPoolExecutor 的缓存线程池要选 SynchronousQueue？**

答：缓存线程池的定位是"任务来了立即执行"。如果用一个有容量的队列，任务会先排队而不是触发新线程创建，就违背了"缓存"的弹性语义。SynchronousQueue 容量为 0，`execute` 时任务无法入队，必然触发 `addWorker` 创建新线程；同时线程空闲 60 秒后会被回收，实现弹性伸缩。但这也意味着**它几乎不适合生产环境做核心业务队列**——任何提交-消费之间的抖动都会导致线程无限膨胀，把 CPU 和内存打爆。

**再追问：SynchronousQueue 的 put 和 offer 有什么区别？**

put 是无限阻塞直到消费者接手；offer 立即返回 boolean 表示是否成功交接。实际生产中做"排队失败快速失败"用 offer，做"必须交接"用 put。

**灵魂追问：transfer 方法和 put 的区别？**

put 只保证"数据被接走"；transfer 额外保证"接走数据的消费者已经处理完交接"——准确说是保证数据**直接交付**给消费者而不经过缓冲。transfer 返回时，消费者一定已经拿到了元素。

## 七、实战建议

1. **别用 SynchronousQueue 做业务缓冲队列**，它是"交接"工具不是"缓冲"工具
2. 需要公平处理（比如多个消费者抢任务）时用 `fair = true`，否则默认非公平即可
3. 需要"有消费者立即直投、无消费者就排队"的语义时，`LinkedTransferQueue.transfer()` 是最佳选择
4. 结合虚拟线程（Java 21+）使用时，SynchronousQueue 依然线程安全，但注意虚拟线程被 park 后不占平台线程，交接模型更从容

## 总结

SynchronousQueue 用"双重数据结构"（dual data structure）实现了零缓冲线程交接：非公平版是栈，公平版是队列，核心都是 `Transferer.transfer()` 一法四用。LinkedTransferQueue 在其之上扩展出"可缓冲的传递语义"。理解它们，你才算真正看懂了 BlockingQueue 家族的两极——一端是无限缓冲的 LinkedBlockingQueue，另一端是零缓冲的 SynchronousQueue。
