---
title: 【并发编程】CompletionService 深度解析：ExecutorCompletionService 源码与并发任务编排实战
date: 2026-09-28 08:05:00
tags:
  - Java
  - 并发
  - CompletionService
  - 源码
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】CompletionService 深度解析：ExecutorCompletionService 源码与并发任务编排实战

## 面试官：一批任务并发提交，要求"谁先返回先处理谁"，你会怎么写？

很多人第一反应是 `ExecutorService.invokeAll()`。但只要追问一句"**如果 10 个任务里 9 个很快、1 个很慢，`invokeAll` 会怎样？**"——答案就暴露了：`invokeAll` 按**提交顺序**返回 `List<Future>`，你只能从头 `future.get()`，慢任务卡在第一位，后面的快任务结果全被堵在后面。**先完成的优势完全用不上**。

这正是 `CompletionService` 存在的意义。本文从痛点出发，把 `ExecutorCompletionService` 的源码、超时控制、异常处理、与 `CompletableFuture` 的选型，一次性讲透。

---

## 一、痛点重现：Future 的"顺序陷阱"

假设有一个"聚合查询"场景：根据用户 ID 并行查 5 个下游服务（用户、订单、积分、优惠券、风控），汇总后返回。

用 `ExecutorService` + `Future` 的朴素写法：

```java
List<Future<Object>> futures = new ArrayList<>();
for (Callable<Object> task : tasks) {
    futures.add(executor.submit(task));
}

// 按提交顺序阻塞等待，慢任务会阻塞后面的快任务
for (int i = 0; i < futures.size(); i++) {
    Object result = futures.get(i).get();   // 卡在任务 0 上，哪怕任务 3 早就好了
    results.add(result);
}
```

问题有两个：

1. **顺序阻塞**：`futures.get(i).get()` 严格按提交顺序等，无法利用"先完成先处理"；
2. **超时难做**：想对整体设 500ms 超时，只能自己算剩余时间，逐个 `get(remaining, TimeUnit)`，代码丑且容易出错。

如果改成"轮询所有 Future 看谁 done 了"，就变成 CPU 空转 + `Thread.sleep` 的丑陋实现——完全是 `CompletionService` 要解决的事。

---

## 二、CompletionService 接口设计

```java
public interface CompletionService<V> {
    // 提交任务
    Future<V> submit(Callable<V> task);
    Future<V> submit(Runnable task, V result);

    // 取出"下一个已完成"的任务的 Future（阻塞）
    Future<V> take() throws InterruptedException;

    // 取出"下一个已完成"的任务的 Future（非阻塞，没有则返回 null）
    Future<V> poll();

    // 带超时的 poll
    Future<V> poll(long timeout, TimeUnit unit)
            throws InterruptedException;
}
```

核心就一句：**`take()` 返回的是"已完成集合中先完成的那个"**，与提交顺序无关。它本质上把 `Executor`（负责执行）和 `BlockingQueue`（负责完成通知）组合了起来。

---

## 三、ExecutorCompletionService 源码剖析

### 3.1 组合结构

```java
public class ExecutorCompletionService<V> implements CompletionService<V> {
    private final Executor executor;
    private final AbstractExecutorService aes;
    private final BlockingQueue<Future<V>> completionQueue;
}
```

- `executor`：真正执行任务的地方（可以是 `ExecutorService`，也可以只是 `Executor`）；
- `completionQueue`：**完成队列**，默认是 `LinkedBlockingQueue`（可通过构造器换成 `ArrayBlockingQueue` 等有界队列）。

### 3.2 submit 的关键：QueueingFuture

```java
public Future<V> submit(Callable<V> task) {
    if (task == null) throw new NullPointerException();
    RunnableFuture<V> f = newTaskFor(task);
    executor.execute(new QueueingFuture(f));   // 包装后再提交
    return f;
}

private class QueueingFuture extends FutureTask<Void> {
    QueueingFuture(RunnableFuture<V> task) {
        super(task, null);           // 把一个 FutureTask 当成 Runnable 执行
        this.task = task;
    }
    protected void done() {          // 任务完成时由 FutureTask 回调
        completionQueue.add(task);   // 把"完成的 Future"放进队列
    }
    private final Future<V> task;
}
```

这是全篇最精妙的设计，拆开看三层：

1. `QueueingFuture` 本身也是一个 `FutureTask`，但它执行的"任务"是**另一个 FutureTask**（`RunnableFuture` 是 `Runnable`，所以能直接当任务跑）；
2. 真正的业务任务 `f` 在 `executor.execute` 时被运行，运行完 `FutureTask` 会调用它自己的 `done()` 钩子；
3. `QueueingFuture` 覆写了 `done()`，**把内层已完成的 `task` 丢进 `completionQueue`**。

于是"完成事件"就被转换成了一次"入队操作"。`take()` 从队列取，天然就是"先完成先出队"（FIFO 的完成顺序）。

### 3.3 take / poll

```java
public Future<V> take() throws InterruptedException {
    return completionQueue.take();
}
public Future<V> poll() {
    return completionQueue.poll();
}
```

极简。取值时不需要任何锁，依赖 `BlockingQueue` 的线程安全与阻塞语义。

### 3.4 为什么 done() 里 add 是安全的？

`FutureTask.done()` 在 `FutureTask.run()` 的收尾阶段被调用（`set()`/`setException()` 之后），此时任务状态已终态、结果可见，`add` 到队列后，`take()` 方 `get()` 必然能拿到结果，不存在可见性问题。这也是 `FutureTask` 内部 `state` 用 volatile 保证的原因。

> 面试追问：**"如果完成队列满了会怎样？"**
>
> 答：默认 `LinkedBlockingQueue` 是**无界**的，永远不会满，但极端情况下（任务量巨大且消费者不取）可能撑爆内存。若构造时传入有界队列（如 `ArrayBlockingQueue(100)`），`done()` 里的 `add` 会变成阻塞——注意 `done()` 是在**工作线程**里执行的，会**占住线程池线程**，严重时导致线程池死锁（所有线程都卡在 add 上，没人消费）。所以生产上一般用默认无界队列，靠消费端及时 `take()` 来控内存。

---

## 四、三种并发编排方案对比

| 维度 | Future + ExecutorService | CompletionService | CompletableFuture |
|---|---|---|---|
| 完成顺序 | 提交顺序 | **先完成先返回** | 回调/组合式 |
| 超时控制 | 手动算剩余时间 | take/poll 天然支持 | `orTimeout`/`completeOnTimeout` |
| 异常处理 | `get()` 抛 ExecutionException | 同左 | `exceptionally`/`handle` |
| 结果聚合 | 手工循环 | 手工循环（但按完成序） | `allOf`/`anyOf`/`thenCombine` |
| 可读性 | 一般 | 高（贴近"生产者-消费者"） | 链式，但嵌套深时难读 |
| 适用场景 | 简单并行 | **批量任务 + 秒级超时 + 谁先好先处理** | 复杂依赖编排、异步链 |

一句话选型：

- 只要"**并发执行一批任务，按完成顺序处理，整体带超时**" → `CompletionService`；
- 有 A→B→C 的**依赖关系**、需要组合多个异步结果 → `CompletableFuture`；
- 只想要最简单的并行等全部完成 → `invokeAll`。

---

## 五、实战一：批量 RPC 聚合 + 整体超时

```java
public Map<String, Object> aggregate(long userId, long timeoutMs)
        throws InterruptedException, TimeoutException {

    ExecutorService pool = ThreadPoolHolder.getPool();
    CompletionService<Entry<String, Object>> cs =
            new ExecutorCompletionService<>(pool);

    List<String> services = List.of("user", "order", "point", "coupon", "risk");
    for (String svc : services) {
        cs.submit(() -> Map.entry(svc, remoteCall(svc, userId)));
    }

    Map<String, Object> result = new HashMap<>();
    long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs);

    for (int i = 0; i < services.size(); i++) {
        long remain = deadline - System.nanoTime();
        if (remain <= 0) {
            throw new TimeoutException("聚合超时, 已完成 " + result.size() + " 项");
        }
        Future<Entry<String, Object>> f = cs.poll(remain, TimeUnit.NANOSECONDS);
        if (f == null) {
            throw new TimeoutException("聚合超时");
        }
        try {
            Entry<String, Object> e = f.get();
            result.put(e.getKey(), e.getValue());
        } catch (ExecutionException ex) {
            // 单个服务失败不影响整体：降级为默认值
            log.warn("服务 {} 调用失败, 降级", ex.getCause().getMessage());
        }
    }
    return result;
}
```

这一段包含四个生产级要点：

1. **用 `poll(remain)` 而不是 `take()`**，把"整体 deadline"平摊到每一次等待，超时是精确的；
2. **单任务失败降级**：`ExecutionException` 单独 catch，避免一个下游挂掉拖垮整个聚合；
3. **超时必须配合取消**（见下节），否则线程池里的慢任务还在跑；
4. **`poll` 返回 null 也要判**，这是超时信号。

---

## 六、超时之后：别忘了取消

`TimeoutException` 抛出后，那些**没完成的任务仍在执行**，会继续占用线程、连接、下游资源。正确做法是维护一份"未完成 Future"列表，超时后统一 `cancel(true)`：

```java
List<Future<?>> pending = new ArrayList<>();
for (String svc : services) {
    pending.add(cs.submit(() -> remoteCall(svc, userId)));
}
...
// 超时分支
finally {
    for (Future<?> f : pending) {
        if (!f.isDone()) {
            f.cancel(true);   // 中断任务线程
        }
    }
}
```

注意 `cancel(true)` 只是**向线程发送中断信号**，能否真正停下取决于任务是否响应中断：

- 阻塞在 `InterruptibleChannel`、`Lock.lockInterruptibly()`、`BlockingQueue.take()` 的任务会立即抛出 `InterruptedException` 退出；
- 而 HTTP 客户端若不支持中断（或 socket 读不响应中断），协程不会停——所以网络调用必须配 **connectTimeout / readTimeout**，"中断"只是兜底，不是银弹。

---

## 七、实战二：多路并发取"最快结果"（hedged request）

考试系统/秒杀场景常见需求：同时请求主备两个机房，**谁先成功用谁**，另一个取消。

```java
public String hedgedQuery(String sql) throws Exception {
    CompletionService<String> cs = new ExecutorCompletionService<>(pool);
    List<Future<String>> fs = new ArrayList<>();
    fs.add(cs.submit(() -> queryFrom("dc-a", sql)));
    fs.add(cs.submit(() -> queryFrom("dc-b", sql)));

    try {
        for (int i = 0; i < 2; i++) {
            try {
                return cs.take().get();   // 第一个成功的直接返回
            } catch (ExecutionException ignore) {
                // 这个副本失败，等另一个
            }
        }
        throw new RuntimeException("两个副本都失败");
    } finally {
        fs.forEach(f -> f.cancel(true));  // 拿到结果后取消所有剩余请求
    }
}
```

`finally` 里的 `cancel` 非常关键：**不做的话，另一个副本的请求会白跑一趟**，白白消耗下游资源。这就是"对冲请求"（hedged request）的标准实现。

---

## 八、与 Guava / CompletableFuture 的对照实现

同样的"先完成先处理"，用 `CompletableFuture` 写：

```java
CompletableFuture<?>[] cfs = services.stream()
    .map(svc -> CompletableFuture.supplyAsync(() -> remoteCall(svc, userId), pool)
        .handle((r, ex) -> ex == null ? Map.entry(svc, r) : null))
    .toArray(CompletableFuture[]::new);

CompletableFuture.allOf(cfs).orTimeout(500, TimeUnit.MILLISECONDS).join();
// 再遍历取结果
```

对比结论：

- `CompletableFuture.allOf` **只在全部完成后才触发**，实现不了"边完成边处理"的流式消费；想要流式，得用 `CompletableFuture` + `BlockingQueue` 自己拼，或直接用 `CompletionService`；
- `CompletionService` 的代码是**同步阻塞风格**，异常处理是显式的 `try/catch`，调试友好；
- `CompletableFuture` 的代码是**声明式链式风格**，可读性好，但异常容易"静默丢失"，且栈信息不直观。

所以很多团队的经验是：**批量聚合用 CompletionService，复杂编排用 CompletableFuture**。

---

## 九、高频踩坑清单

1. **`take()` 在任务全部完成后仍会永久阻塞**：如果任务数算错（比如多 take 了一次），线程会一直挂着。务必用 `for (i < N)` 计数。
2. **异常任务也会进完成队列**：`done()` 无论成功失败都会被调用，所以 `ExecutionException` 必须在消费侧处理，否则会被吞。
3. **完成队列与线程池不是一回事**：`CompletionService` 只是"再包装"，底层线程池的队列、拒绝策略仍然适用，别混淆。
4. **不要在 `done()` 里做重活**：它在工作线程执行，会拖慢任务回收。用无界队列是权衡后的选择。
5. **`poll()` 空轮询**：非阻塞 `poll()` 返回 null 时不要裸写 `while(true)` 忙等，会烧 CPU，要么用 `poll(timeout)`，要么加退避。
6. **务必传自定义线程池**：`new ExecutorCompletionService<>(executor)` 里的 `executor` 千万不要用 `Executors.newCachedThreadPool()`，无界线程 + 无界队列 = OOM 隐患，生产必须用有界队列 + 命名线程 + 拒绝策略。

---

## 十、面试追问连环炮

**Q：CompletionService 能不能保证"任务完成的先后顺序与入队顺序严格一致"？**
A：不保证。它保证的是"**已入队的先出队**"（FIFO）。多个任务几乎同时完成时，`done()` 的调用顺序由线程调度决定，存在微小乱序。业务上只要求"近似先完成先处理"即可。

**Q：`take()` 和 `poll()` 会抛出任务本身的异常吗？**
A：不会。队列里存的是 `Future`，异常封装在 `Future.get()` 里。`take()` 只可能抛 `InterruptedException`。

**Q：能不能用它实现"滑动窗口限流式并发"？**
A：可以。提交 N 个后，每 `take()` 一个就补提交一个，始终维持 N 个在途任务，这正是"并发度可控的批处理"的经典写法：

```java
int window = 8;
for (int i = 0; i < window && it.hasNext(); i++) cs.submit(it.next());
while (submitted < total) {
    cs.take().get();
    if (it.hasNext()) cs.submit(it.next());
    submitted++;
}
```

**Q：`QueueingFuture` 为什么继承 `FutureTask<Void>` 而不是实现 `Runnable`？**
A：因为它需要"被执行"（必须有 `run()`），而 `FutureTask` 天然实现了 `RunnableFuture`，把它自己作为任务提交给 executor 就能借用 `FutureTask` 的 `done()` 回调机制，省去了自己实现回调的复杂度。这是"用组合 + 继承复用钩子"的典型手法。

---

## 总结

`CompletionService` 的源码不到 100 行，但它把并发编程里两个最朴素的东西组合出了优雅的能力：**用线程池负责"跑"，用阻塞队列负责"通知"**。

记住三句话：

1. **提交顺序 ≠ 完成顺序**，需要"先完成先处理"就用它；
2. **`poll(剩余时间)` 是超时控制的标准姿势**，超时后记得 `cancel(true)`；
3. **异常任务也会入队**，消费侧必须处理 `ExecutionException`。

下次面试再被问到"并发取最快结果""批量任务带整体超时"，你就有了一套可以直接写出来、还能扛住追问的答案。
