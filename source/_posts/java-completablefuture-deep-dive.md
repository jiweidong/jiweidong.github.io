---
title: 【Java 并发】CompletableFuture 深度解析：从异步回调到任务编排的源码级实战
date: 2026-09-04 08:00:00
tags:
  - Java
  - 并发
  - 异步编程
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【Java 并发】CompletableFuture 深度解析：从异步回调到任务编排的源码级实战

## 面试官：Future 用得好好的，为什么还要用 CompletableFuture？

老规矩，先抛场景。你用 `ExecutorService.submit()` 拿一个 `Future`，想等结果只能 `future.get()`——**阻塞**。想"结果出来了再干点别的"？要么轮询 `isDone()`，要么 `get()` 挂起线程。更别提串多个异步任务：查用户 → 查订单 → 查物流，每一步都要等上一步，中间全是阻塞等待和手动拼接。代码写出来又丑又难维护，线程资源还白占。

`CompletableFuture` 就是来治这个病的：它把"异步结果"和"回调动作"解耦，支持**链式编排、并行聚合、异常恢复**，是 JDK 8 引入、JDK 9+ 持续增强的异步编程神器，也是 Java 21 虚拟线程时代之前"异步编排"的主流答案。

---

## 一、先跑起来：两个入口方法

`CompletableFuture` 创建异步任务有两个静态入口：

| 方法 | 返回值 | 说明 |
|---|---|---|
| `runAsync(Runnable)` | `CompletableFuture<Void>` | 无返回值，跑完即止 |
| `supplyAsync(Supplier<U>)` | `CompletableFuture<U>` | 有返回值，可继续编排 |
| 带 Executor 版本 | 同上 | 指定线程池执行，**强烈推荐** |

```java
// 不带线程池：走 ForkJoinPool.commonPool()，生产环境大忌（后面细说）
CompletableFuture<String> f1 = CompletableFuture.supplyAsync(() -> {
    // 模拟 RPC 调用
    return rpcClient.queryUser(1001);
});

// 带线程池：业务代码必须这么写
ExecutorService bizPool = Executors.newFixedThreadPool(8);
CompletableFuture<String> f2 = CompletableFuture.supplyAsync(
    () -> rpcClient.queryUser(1001), bizPool);
```

`get()` 仍然会阻塞，所以核心用法是**挂回调**，而不是去拿结果。

---

## 二、回调家族：thenApply / thenAccept / thenRun 等

拿到 `CompletableFuture` 后，可以在它完成时自动执行后续动作：

```java
CompletableFuture<String> cf = CompletableFuture
    .supplyAsync(() -> rpcClient.queryUser(1001), bizPool) // 异步查用户
    .thenApply(user -> user.getVipLevel())                 // 结果转换：User -> int
    .thenApply(level -> level >= 3 ? "VIP用户" : "普通用户") // 再转换
    .thenAccept(label -> log.info("用户标签：{}", label))   // 消费，无返回值
    .thenRun(() -> log.info("全链路完成"));                  // 跑个收尾动作
```

常用方法速查表：

| 方法 | 入参 | 返回值 | 语义 |
|---|---|---|---|
| `thenApply(Function)` | 上一步结果 | 新结果 | 转换（映射） |
| `thenAccept(Consumer)` | 上一步结果 | Void | 消费结果 |
| `thenRun(Runnable)` | 无 | Void | 只关心执行完毕 |
| `whenComplete(BiConsumer)` | 结果+异常 | 原样传递 | 无论成败都回调，**不吞异常** |
| `exceptionally(Function)` | 异常 | 恢复结果 | 异常时给兜底值 |
| `handle(BiFunction)` | 结果+异常 | 新结果 | 成败都处理并转换 |

**关键区别：`whenComplete` 与 `handle` 都不影响异常传播，而 `exceptionally` 会把异常"消化"掉恢复出正常值。**

```java
CompletableFuture<Integer> cf = CompletableFuture
    .supplyAsync(() -> 100 / 0, bizPool)          // 抛 ArithmeticException
    .exceptionally(ex -> {                          // 兜底恢复
        log.error("计算失败：{}", ex.getMessage());
        return -1;                                  // 异常被消化，后面正常走
    })
    .thenApply(v -> v + 1);                         // 这里拿到的是 0，不会中断
```

**面试追问：`thenApply` 和 `thenCompose` 有什么区别？**
`thenApply` 里如果返回一个 `CompletableFuture`，会被当成普通对象**再包一层**，变成 `CompletableFuture<CompletableFuture<U>>`——嵌套地狱。`thenCompose` 会帮你**展平**，等价于 `flatMap`：

```java
// thenApply 嵌套：类型是 CompletableFuture<CompletableFuture<Order>>
CompletableFuture<CompletableFuture<Order>> bad = cf.thenApply(
    id -> CompletableFuture.supplyAsync(() -> orderService.get(id)));

// thenCompose 展平：类型是 CompletableFuture<Order>
CompletableFuture<Order> good = cf.thenCompose(
    id -> CompletableFuture.supplyAsync(() -> orderService.get(id)));
```

`thenApply` 适合"纯计算转换"，`thenCompose` 适合"下一步也是异步任务"。

---

## 三、并行编排：allOf / anyOf / thenCombine

### 3.1 thenCombine：两个任务并行，结果合并

```java
CompletableFuture<User> userF = CompletableFuture
    .supplyAsync(() -> userService.get(1001), bizPool);
CompletableFuture<Order> orderF = CompletableFuture
    .supplyAsync(() -> orderService.latest(1001), bizPool);

// 两个异步任务并行执行，都完成后把结果合并成页面模型
CompletableFuture<PageVO> pageF = userF.thenCombine(orderF,
    (user, order) -> PageVO.of(user, order));
```

### 3.2 allOf：N 个任务全部完成

```java
List<CompletableFuture<Price>> futures = skuIds.stream()
    .map(id -> CompletableFuture.supplyAsync(
        () -> priceService.query(id), bizPool))
    .collect(Collectors.toList());

// 注意：allOf 返回 CompletableFuture<Void>，不聚合结果！
CompletableFuture<Void> all = CompletableFuture.allOf(
    futures.toArray(new CompletableFuture[0]));

all.thenApply(v -> futures.stream()
        .map(CompletableFuture::join)   // 此时全部已完成，join 不会真正阻塞
        .collect(Collectors.toList()))
   .thenAccept(prices -> log.info("批量价格：{}", prices));
```

**面试追问：为什么 allOf 返回 Void？**
因为 N 个任务的返回类型各不相同，没法统一泛型。所以 `allOf` 只负责"等全部完成"这个信号，结果自己从原 future 列表里 `join()` 取——此时全部完成，`join()` 不会阻塞，这是标准姿势。

### 3.3 anyOf：任意一个完成即可

```java
// 多数据源查价格，谁先返回用谁（超时兜底场景很常见）
CompletableFuture<Object> first = CompletableFuture.anyOf(
    CompletableFuture.supplyAsync(() -> priceA.query(skuId), bizPool),
    CompletableFuture.supplyAsync(() -> priceB.query(skuId), bizPool));
```

`anyOf` 返回 `CompletableFuture<Object>`，需要自己 cast。

**面试追问：`get()` 和 `join()` 有什么区别？**
两者都是阻塞拿结果。区别在异常处理：`get()` 抛受检异常 `ExecutionException`/`InterruptedException`（要 try-catch），`join()` 抛**非受检**的 `CompletionException`（可不用捕获）。函数式回调链里到处都是 `join()`，就是因为不用写 try-catch；`get()` 还能传超时时间 `get(3, TimeUnit.SECONDS)`。

---

## 四、源码剖析：CompletableFuture 是怎么"自动回调"的？

### 4.1 核心字段

```java
public class CompletableFuture<T> implements Future<T>, CompletionStage<T> {
    volatile Object result;          // 完成结果：正常值 或 AltResult(包装异常)
    volatile Completion stack;       // 依赖栈：等待该 future 完成的后续动作链表
    // ...
}
```

- `result`：任务完成后的结果。异常用内部类 `AltResult` 包装（`AltResult(ex)`），`null` 表示未完成。
- `stack`：**后进先出的依赖链表**。每个 `thenApply` 等调用都会把封装了回调的 `Completion` 节点压入这个栈。

### 4.2 完成时如何触发后续？

核心方法 `postComplete()`：当任务完成（`result` 被赋值）后，会沿着 `stack` 链表依次弹出每个依赖节点，把"父完成"这个事件传递给它们。每个回调内部类（如 `UniApply`）自己维护一个状态机：

```
UniApply 节点状态流转：
EMPTY -> SIGNAL -> (父完成) -> 执行 fn -> 设置子 future 的 result -> 继续传播
```

大致流程（简化）：

```java
// thenApply 的本质：把当前 future 记为 src，创建子 future dst，
// 压入 src.stack，注册 UniApply 依赖节点
public <U> CompletableFuture<U> thenApply(Function<? super T,? extends U> fn) {
    return uniApplyStage(null, fn);   // null 表示沿用父任务的线程池
}

// 父任务完成时：postComplete 弹栈，调用 UniApply.tryFire
// tryFire 里执行 fn.apply(父结果)，把结果写入子 future 的 result，
// 再对子 future 执行 postComplete，像多米诺骨牌一样一路推下去
```

所以整条链的本质是：**一棵由 future 节点和 Completion 依赖边组成的 DAG，父节点完成时沿依赖边向下游广播**。这也是为什么它能支撑复杂的异步编排——每个节点只关心"我依赖谁、谁依赖我"。

### 4.3 面试追问：异常在链上怎么传播？

链上的异常默认**逐级包装但不中断传播方向**：某个节点抛异常，异常会作为 `AltResult` 写进该节点 result，然后继续传给下游节点；下游如果是 `thenApply`（纯转换），会把异常**原样转发**给更下游，自己什么都不做；只有遇到 `exceptionally`/`handle` 才会拦截恢复。所以异常可以"穿过"整条链，直到被恢复点接住，或者最终 `get()/join()` 时抛出来。**写回调链时最怕每个节点都 try-catch 把异常吞了，排查时一脸懵。**

---

## 五、线程池陷阱：commonPool 与 async 后缀

### 5.1 默认线程池为什么是坑？

不带 Executor 的 `supplyAsync`/`thenApplyAsync` 走 `ForkJoinPool.commonPool()`：

- 线程数 = `CPU 核数 - 1`（最小 1）；
- 它被**全 JVM 共享**，其他并行流、`ForkJoinTask` 都在抢它；
- 一旦某个任务阻塞（RPC、DB 查询），**线程被占满后所有异步任务全部排队**——线上事故高发点。

**生产规范：所有异步入口显式传业务线程池，绝不用 commonPool 跑 IO 任务。**

### 5.2 面试追问：`thenApply` 和 `thenApplyAsync` 有什么区别？

| 方法 | 执行线程 | 说明 |
|---|---|---|
| `thenApply` | 父任务完成的线程（或调用线程） | 谁完成谁执行，省一次线程切换 |
| `thenApplyAsync` | 公共 ForkJoinPool / 指定线程池 | 必定提交到线程池执行 |

**坑点**：`thenApply` 的执行线程不确定——如果父任务已经完成，它会在**你调用 thenApply 的那个线程**上同步执行！所以回调里有耗时操作（DB、RPC）时，要么用 `thenApplyAsync`，要么确保整条链都在业务线程池里跑，否则可能把 Web 请求线程/主线程阻塞住。

### 5.3 线程池饥饿：异步套异步的经典死锁

```java
// 反例：线程池只有 2 个线程，任务 A 内部又 await 一个子异步任务
ExecutorService pool = Executors.newFixedThreadPool(2);

CompletableFuture.supplyAsync(() -> {
    // 任务 A：占用了池中 1 个线程，然后阻塞等子任务
    CompletableFuture<String> sub = CompletableFuture
        .supplyAsync(() -> heavyWork(), pool);  // 子任务需要另一个线程
    return sub.join();   // 如果池里另一个线程也被类似任务占着 -> 死等
}, pool);
```

两个线程都被"外层任务"占住并各自 `join()` 等子任务，子任务永远排不到线程 → **线程池饥饿死锁**。解决：子任务用独立线程池；或外层不要同步等待，继续用回调编排。

---

## 六、超时与取消

JDK 9 起支持超时控制，生产必用：

```java
// 超时抛 TimeoutException（get 时体现）或触发 exceptionally
CompletableFuture<String> cf = CompletableFuture
    .supplyAsync(() -> rpc.query(), bizPool)
    .completeOnTimeout("兜底数据", 2, TimeUnit.SECONDS) // 超时给默认值
    .exceptionally(ex -> {
        log.error("查询异常", ex);
        return "兜底数据";
    });

// 或者：超时直接异常
cf.orTimeout(2, TimeUnit.SECONDS);
```

注意：`completeOnTimeout`/`orTimeout` **不会取消底层任务**，任务还在线程池里跑，只是 future 先"完成"了——这也是为什么线程池要设置合理的队列策略，防止超时任务堆积。

---

## 七、实战：一次查询编排的完整示例

需求：查商品详情页 = 商品基础信息 + 库存 + 评价数，三个 RPC 无依赖，要求并行、总耗时取最慢者，单接口失败不影响整体（用兜底值）。

```java
@Service
public class ProductDetailService {

    // 建议：业务统一线程池，参考 CPU 密集/IO 密集配置，并带监控
    private final ExecutorService bizPool = Executors.newFixedThreadPool(16);

    public ProductDetailVO getDetail(Long skuId) {
        CompletableFuture<Product> baseF = async(() -> productRpc.getBase(skuId));
        CompletableFuture<Stock> stockF = async(() -> stockRpc.getStock(skuId));
        CompletableFuture<Long> commentF = async(() -> commentRpc.count(skuId));

        return CompletableFuture.allOf(baseF, stockF, commentF)
            .thenApply(v -> ProductDetailVO.builder()
                .product(baseF.join())
                .stock(stockF.join())
                .commentCount(commentF.join())
                .build())
            // 单个失败不影响主流程
            .exceptionally(ex -> {
                log.error("查询商品详情异常 skuId={}", skuId, ex);
                return ProductDetailVO.fallback(skuId);
            })
            .join();  // Web 层同步等待聚合结果
    }

    private <T> CompletableFuture<T> async(Supplier<T> supplier) {
        return CompletableFuture.supplyAsync(supplier, bizPool);
    }
}
```

---

## 八、总结：面试问答速记

**Q1：CompletableFuture 和 FutureTask 的区别？**
FutureTask 只能"阻塞等待一个任务的结果"，任务间无法编排；CompletableFuture 是完整异步编程模型：回调、组合、聚合、异常恢复，且内部用无锁的 CAS + 依赖链表实现，性能更好。

**Q2：回调链的执行线程如何确定？**
非 Async 方法在"父任务完成线程"上执行；Async 方法提交到 commonPool 或指定线程池。不确定时用 Async + 显式线程池。

**Q3：怎么处理异步任务的异常？**
链式用 `exceptionally`/`handle` 恢复；最终出口用 `join()`/`get()` 捕获；绝不在回调里静默吞异常。

**Q4：批量异步任务怎么等？**
`allOf`（全完成）+ `join` 取结果；`anyOf`（任一完成）。注意 allOf 返回 Void。

**Q5：生产上还有什么坑？**
① 用 commonPool 跑 IO → 线程饥饿；② 异步链里同步 join 子任务 → 池饥饿死锁；③ 忘记超时 → 任务悬挂；④ 回调里做耗时操作阻塞请求线程；⑤ 线程池无监控 → 故障不可见。

一句话总结：**CompletableFuture 把"异步结果"变成了一棵可编排的依赖树，回调代替阻塞、组合代替串行、恢复代替崩溃——用好它，并发代码的复杂度能降一个数量级。**
