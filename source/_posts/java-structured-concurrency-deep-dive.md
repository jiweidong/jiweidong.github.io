---
title: 【Java 21+】结构化并发（Structured Concurrency）深度解析：从原理到实战
date: 2026-07-10 08:00:00
tags:
  - Java
  - 并发
  - 虚拟线程
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java 21+】结构化并发（Structured Concurrency）深度解析：从原理到实战

## 引言

在传统的 Java 并发编程中，当我们提交多个任务到线程池时，任务之间的生命周期是"松散"的。主线程提交任务后就失去了对子任务的控制权——你不知道子任务何时完成、是否异常、如何聚合结果。这种编程模型容易导致线程泄漏、上下文漂移和错误处理缺失。

JDK 21 正式引入了 **结构化并发（Structured Concurrency，JEP 453）**，并在后续版本中持续完善。它借鉴了结构化编程的理念——**代码的结构等于并发的结构**，让多线程任务的提交、执行、取消和异常处理变得像同步代码一样清晰可控。

本文将全面解析结构化并发的设计思想、核心 API 与实战用法。

---

## 一、为什么要引入结构化并发？

### 1.1 传统并发模式的痛点

来看一个常见的多任务并发场景：

```java
// 传统方式：提交多个任务并等待结果
ExecutorService executor = Executors.newFixedThreadPool(3);
Future<String> task1 = executor.submit(() -> fetchUserData());
Future<String> task2 = executor.submit(() -> fetchOrderData());
Future<String> task3 = executor.submit(() -> fetchConfigData());

// 等待所有任务完成
try {
    String result1 = task1.get(5, TimeUnit.SECONDS);
    String result2 = task2.get(5, TimeUnit.SECONDS);
    String result3 = task3.get(5, TimeUnit.SECONDS);
    // 处理结果...
} catch (Exception e) {
    // 一个任务失败后，其他任务还在后台运行！
    // 无法优雅取消还在运行的子任务
    // 可能造成资源浪费
}
```

**传统方式存在几个严重问题：**

| 问题 | 描述 |
|------|------|
| **子任务泄漏** | 主任务抛出异常后，子任务仍可能在后台继续执行 |
| **取消困难** | 没有统一的生命周期管理，取消逻辑分散在各处 |
| **错误隔离差** | 一个子任务失败，你无法轻易取消其他仍在执行的子任务 |
| **观测困难** | 无法直观看到并发任务的边界和执行状态 |

### 1.2 结构化思想

结构化编程的核心理念是：**代码块应该有明确的入口和出口**。结构化并发将这个思想扩展到多线程：

```
┌────────────────────────────────────────┐
│  StructuredTaskScope 作用域             │
│  ┌──────────┐  ┌──────────┐           │
│  │  Task A  │  │  Task B  │           │
│  └────┬─────┘  └────┬─────┘           │
│       └──────┬───────┘                 │
│          ┌───▼────┐                    │
│          │ 合并结果 │                    │
│          └────────┘                    │
└────────────────────────────────────────┘
```

- 子任务的生命周期**严格嵌套**在父任务的作用域内
- 父任务提交所有子任务后**等待所有子任务完成**才能退出
- 任意子任务异常，父任务**自动取消其他未完成的子任务**
- 作用域关闭时，**所有的子任务都必须已经结束**

---

## 二、核心 API：StructuredTaskScope

结构化并发的核心是 `java.util.concurrent.StructuredTaskScope` 类，它提供了两种预定义的策略：

### 2.1 ShutdownOnFailure：任意失败即取消

最常见的场景：多个子任务并行执行，**任何一个失败则全部取消**。

```java
// 使用 ShutdownOnFailure 策略
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    // 递交子任务
    Subtask<String> userTask = scope.fork(() -> fetchUserData());
    Subtask<String> orderTask = scope.fork(() -> fetchOrderData());
    Subtask<String> configTask = scope.fork(() -> fetchConfigData());

    // 等待所有子任务完成或任意一个失败
    scope.join();
    // 检查是否有异常，有则抛出
    scope.throwIfFailed();

    // 获取结果（此时所有任务都已完成且无异常）
    String result = String.format("User:%s | Order:%s | Config:%s",
        userTask.get(), orderTask.get(), configTask.get());
    return result;
}
// 作用域结束，所有子任务自动关闭
```

**关键特性：**
- `scope.fork(task)` 提交子任务，返回 `Subtask<T>` 而非 `Future<T>`
- `scope.join()` 阻塞等待所有子任务结束（或被取消）
- `scope.throwIfFailed()` 如果有子任务失败，抛出异常
- 任意子任务抛出异常 → 自动关闭 scope → 其他未完成的子任务被 cancel
- `try-with-resources` 确保 scope 关闭时所有子任务终止

### 2.2 ShutdownOnSuccess：任意成功即取消

当多个子任务做相同的事情（冗余计算），只需要最快的那个结果：

```java
// 向多个数据源并发查询，取最快返回的结果
try (var scope = new StructuredTaskScope.ShutdownOnSuccess<String>()) {
    scope.fork(() -> queryPrimaryDB());
    scope.fork(() -> queryReplicaDB());
    scope.fork(() -> queryCache());

    // 等待任意一个成功返回
    String result = scope.join().result();
    System.out.println("最快返回的结果: " + result);
    return result;
}
```

常见应用场景：
- 多路异地容灾查询
- 冗余健康检查
- 多缓存层并发读取

---

## 三、实战案例：构建高并发查询服务

### 3.1 路由查询服务

假设我们要构建一个用户详情聚合服务，需要并发查询多个数据源：

```java
public class UserDetailService {
    private final UserClient userClient;
    private final OrderClient orderClient;
    private final CouponClient couponClient;

    /**
     * 结构化并发聚合用户信息
     */
    public UserDetailVO getUserDetail(Long userId)
            throws InterruptedException, ExecutionException {

        try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
            // 三个查询并发执行
            Subtask<UserInfo> userSub = scope.fork(
                () -> userClient.getUserInfo(userId));
            Subtask<List<OrderVO>> orderSub = scope.fork(
                () -> orderClient.getUserOrders(userId));
            Subtask<List<CouponVO>> couponSub = scope.fork(
                () -> couponClient.getUserCoupons(userId));

            // 等待所有完成
            scope.join();
            scope.throwIfFailed();

            // 聚合结果
            return new UserDetailVO(
                userSub.get(),
                orderSub.get(),
                couponSub.get()
            );
        }
    }
}
```

**对比传统 CompletableFuture 写法：**

| 维度 | CompletableFuture | StructuredTaskScope |
|------|-------------------|-------------------|
| 代码复杂度 | 链式调用，异常处理分散 | 线性代码，try-catch 清晰 |
| 取消语义 | `allOf()` 不提供自动取消 | 失败自动取消其他子任务 |
| 作用域管理 | 无，需手动管理 | try-with-resources 自动管理 |
| 子任务观测 | 难以观测 | 可通过 scope 获取子任务状态 |

### 3.2 超时与降级

结合虚拟线程和超时机制：

```java
public ProductDetailVO getProductDetail(Long productId, Duration timeout) {
    try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
        Subtask<ProductBasic> basic = scope.fork(() ->
            productService.getBasic(productId));
        Subtask<PriceInfo> price = scope.fork(() ->
            priceService.calculatePrice(productId));
        Subtask<List<ReviewVO>> reviews = scope.fork(() -> {
            // 评论查询如果超时则降级返回空列表
            try {
                return reviewService.getReviews(productId);
            } catch (TimeoutException e) {
                log.warn("Review query timeout for product: {}", productId);
                return List.of();
            }
        });

        scope.join(timeout);
        // 如果超时，join() 返回后手动检查并处理
        if (scope.isShutdown()) {
            // 超时降级处理
            return buildFallbackProduct(productId);
        }
        scope.throwIfFailed();

        return new ProductDetailVO(basic.get(), price.get(), reviews.get());
    }
}
```

---

## 四、自定义策略：实现更复杂的并发模式

当预置的 ShutdownOnFailure 和 ShutdownOnSuccess 不够用时，我们可以继承 StructuredTaskScope 实现自定义策略。

### 4.1 实现"多数派成功"策略

```java
public class QuorumScope<T> extends StructuredTaskScope<T> {
    private final int quorumSize;
    private final AtomicInteger successCount = new AtomicInteger(0);
    private final AtomicInteger failureCount = new AtomicInteger(0);
    private final CopyOnWriteArrayList<T> results = new CopyOnWriteArrayList<>();
    private final CopyOnWriteArrayList<Exception> exceptions = new CopyOnWriteArrayList<>();

    public QuorumScope(int quorumSize, String name, ThreadFactory factory) {
        super(name, factory);
        this.quorumSize = quorumSize;
    }

    @Override
    protected void handleComplete(Subtask<? extends T> subtask) {
        switch (subtask.state()) {
            case SUCCESS -> {
                results.add(subtask.get());
                if (successCount.incrementAndGet() >= quorumSize) {
                    shutdown(); // 达到多数派即关闭
                }
            }
            case FAILED -> {
                exceptions.add((Exception) subtask.exception());
                if (failureCount.incrementAndGet() > quorumSize) {
                    shutdown(); // 失败太多也关闭
                }
            }
        }
    }

    /** 获取成功的结果列表 */
    public List<T> results() { return List.copyOf(results); }
    /** 获取失败的异常列表 */
    public List<Exception> exceptions() { return List.copyOf(exceptions); }
}
```

使用方式：

```java
try (var scope = new QuorumScope<String>(2, "quorum", threadFactory)) {
    scope.fork(() -> callService("node-1"));
    scope.fork(() -> callService("node-2"));
    scope.fork(() -> callService("node-3"));

    scope.join();
    List<String> results = scope.results();
    // 只要有两个节点返回成功即可
    if (results.size() >= 2) {
        return results.get(0); // 取第一个成功结果
    }
    throw new QuorumNotMetException(
        "Quorum not met, failures: " + scope.exceptions());
}
```

### 4.2 "任务分组"场景：分阶段并发

有时我们需要**分阶段**执行并发任务，第二阶段依赖第一阶段的某些结果：

```java
// 第一阶段：获取商品信息和用户信息（并行）
try (var phase1 = new StructuredTaskScope.ShutdownOnFailure()) {
    Subtask<Product> productSub = phase1.fork(() -> getProduct(id));
    Subtask<User> userSub = phase1.fork(() -> getUser(uid));
    phase1.join();
    phase1.throwIfFailed();

    Product product = productSub.get();
    User user = userSub.get();

    // 第二阶段：根据第一阶段结果做并行处理
    try (var phase2 = new StructuredTaskScope.ShutdownOnFailure()) {
        Subtask<Price> priceSub = phase2.fork(() ->
            calcPrice(product, user.getVipLevel()));
        Subtask<Inventory> invSub = phase2.fork(() ->
            checkInventory(product.getId(), 1));
        phase2.join();
        phase2.throwIfFailed();

        return new OrderPreview(
            product, priceSub.get(), invSub.get(), user
        );
    }
}
```

---

## 五、结构化并发 vs 其他并发模型的对比

| 特性 | ThreadPool + Future | CompletableFuture | 响应式编程 (Reactor) | 结构化并发 |
|------|-------------------|-------------------|--------------------|-----------|
| **代码风格** | 命令式 | 链式回调 | 流式声明 | 命令式 |
| **作用域管理** | 无 | 无 | 有（订阅范围） | ✅ 严格嵌套 |
| **自动取消** | 手动 | 手动 | 部分 | ✅ 内建 |
| **异常传播** | 分散 | `.exceptionally()` | `.onErrorXxx()` | ✅ 统一 throw |
| **虚拟线程** | 兼容 | 兼容 | 部分 | ✅ 原生 |
| **调试难度** | 高 | 中 | 高（调用栈复杂） | ✅ 低（线性栈） |
| **学习曲线** | 低 | 中 | 高 | 低 |

---

## 六、最佳实践与注意事项

### ✅ 最佳实践

1. **搭配虚拟线程使用**：结构化并发 + 虚拟线程 = 最佳的并发编程体验
2. **作用域尽量短小**：一个 StructuredTaskScope 对应一个业务操作
3. **用 try-with-resources**：确保 scope 一定被关闭
4. **嵌套作用域**：分阶段并发可以用嵌套的 scope
5. **Subtask.get() 在 join() 之后调用**：确保任务已完成

### ❌ 常见陷阱

```java
// ❌ 错误：在 fork 之后直接 get()
Subtask<User> sub = scope.fork(() -> getUser());
User user = sub.get();  // 可能还没执行完！

// ✅ 正确：先 join 等待，再获取结果
scope.join();
User user = sub.get();
```

```java
// ❌ 错误：在 scope 外部持有子任务引用
Subtask<User> leaked;
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    leaked = scope.fork(() -> getUser());
}
leaked.get(); // scope 已关闭，子任务可能已被取消

// ✅ 正确：所有操作在 scope 内完成
try (var scope = ...) {
    Subtask<User> sub = scope.fork(() -> getUser());
    scope.join();
    User user = sub.get();
    handle(user);
}
```

### 性能考量

结构化并发本身的开销极低，主要是 `fork` 时的任务提交成本。相比于传统线程池：
- 没有线程池的队列阻塞
- 配合虚拟线程，每个任务就是一个轻量级协程
- 取消机制的实现是 O(1) 的（标记关闭 + interruption）

---

## 七、面试常见追问

**Q：结构化并发和虚拟线程是什么关系？**
A：两者是互补关系。虚拟线程解决了"线程作为资源稀缺"的问题，让每个任务可以有自己的线程；结构化并发解决了"并发任务的生命周期管理"问题。两者结合使用效果最佳。

**Q：StructuredTaskScope 和 ExecutorService 的区别？**
A：ExecutorService 是"提交后就不管了"的松散模型；StructuredTaskScope 是"提交-等待-关闭"的严格作用域模型。后者保证了子任务不会泄漏。

**Q：ShutdownOnFailure 在超时场景怎么处理？**
A：使用带超时的 `join(Duration)`，超时后 scope 不会自动 shutdown，需要手动判断并处理超时逻辑。

**Q：结构化并发是否取代了 CompletableFuture？**
A：不替代，但适用于不同场景。结构化并发适合**命令式的并发调用**场景（并发请求多个服务），CompletableFuture 适合**异步编排**场景（链式回调、延迟触发）。

---

## 总结

结构化并发是 Java 并发编程的一项里程碑改进。它让多线程代码的**生命周期管理、异常处理、取消语义、可观测性**都得到了质的提升。配合虚拟线程，我们可以写出既高效又优雅的并发代码——不再需要闭着眼睛在脑子里推演线程状态，代码本身就告诉了你并发结构。

如果你还在用 JDK 17 以下版本，是时候考虑升级了。结构化并发 + 虚拟线程的组合拳，将彻底改变 Java 服务端的编码方式。
