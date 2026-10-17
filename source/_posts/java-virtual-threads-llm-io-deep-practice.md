---
title: 【Java AI】虚拟线程跑大模型 IO 深度实战：高并发 Agent 调用与阻塞式 SDK 治理
date: 2026-10-17 08:15:00
tags:
  - Java
  - AI
  - 虚拟线程
  - LLM
  - 高并发
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】虚拟线程跑大模型 IO 深度实战：高并发 Agent 调用与阻塞式 SDK 治理

## 前言

AI 应用和传统 CRUD 最大的差异之一：**请求的绝大部分时间都耗在外部 IO 上**——调用大模型 API、向量库检索、工具（Function Calling）执行、重排。一次 LLM 调用动辄 1~30 秒，而 CPU 几乎空转。

传统「平台线程（Platform Thread）+ 线程池」模型在这种场景下非常吃亏：一个平台线程约 1MB 栈、受 OS 线程数限制，几百并发就开始排队、内存暴涨。**Java 21 的虚拟线程（Virtual Threads）正是为此类「高并发阻塞 IO」场景设计的**——M:N 调度，一个线程几 KB，轻松支撑十万级并发「在飞」的请求。

但虚拟线程不是银弹：**`synchronized` 阻塞、native 调用、连接池、以及大量老旧的 LLM SDK 会把 `carrier thread` 钉住（pinning）**，让收益大打折扣。本文用 Java 技术栈把「虚拟线程跑大模型 IO」讲透，并给出可落地的治理方案。

---

## 一、为什么 LLM 场景特别适合虚拟线程

LLM 应用的负载画像：

| 特征 | 传统 CRUD | AI 应用 |
|---|---|---|
| 单请求耗时 | 几十 ms | 1~30 s |
| CPU 占比 | 中高 | 极低（等模型返回） |
| 并发模型 | 计算型 | **IO 等待型** |
| 瓶颈 | CPU | 外部 API 限流/延迟 |

这就是典型的 **「高并发 + 长时间阻塞 + 低 CPU」**。平台线程模型下，为了扛 5000 并发你要 5000 个 OS 线程（≈5GB 栈内存）——不可行。虚拟线程模型下，5000 个虚拟线程 ≈ 几十 MB，且调度开销极低。

```java
// 一行开启：每个请求一个虚拟线程
@Bean
public TomcatProtocolHandlerCustomizer<?> protocolHandler() {
    return protocolHandler -> protocolHandler.setExecutor(
        Executors.newVirtualThreadPerTaskExecutor());
}
```

Spring Boot 3.2+ 更简单——**一个配置开关**：

```yaml
spring:
  threads:
    virtual:
      enabled: true
```

或者显式声明执行器：

```java
@Bean(name = "applicationTaskExecutor")
public AsyncTaskExecutor virtualThreadExecutor() {
    return new TaskExecutorAdapter(Executors.newVirtualThreadPerTaskExecutor());
}
```

---

## 二、虚拟线程的核心机制（够用版）

- **虚拟线程**是 `Thread` 的实例，但不由 OS 直接调度，而由 `ForkJoinPool` 风格的 **carrier thread（载体线程）** 运行。
- 当虚拟线程执行**阻塞 IO**（`Socket`、`FileChannel`、`BlockingQueue`、`Thread.sleep` 等）时，JVM 会 **unmount（卸载）** 它，把 carrier thread 让给其他虚拟线程执行——**这就是吞吐的来源**。
- 反之，如果阻塞操作**无法被 JVM 感知**（`synchronized` 块、native 调用），虚拟线程会 **pin（钉住）** carrier thread，导致它无法被复用 → 吞吐退化，极端情况下线程饥饿。

> 记忆点：**虚拟线程的收益 = 挂起数 / carrier 数**。挂起被阻断（pinning），收益就归零。

---

## 三、实战：高并发 LLM 调用

### 3.1 用虚拟线程并发调用多模型/多工具

Agent 的典型形态是「一次请求里并发调用多个工具/模型」。用结构化并发（JDK 21 preview，JDK 25 正式）组织：

```java
// 用虚拟线程 + 结构化并发编排 Agent 的子任务
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    Supplier<String> rag = scope.fork(() -> vectorSearch(query));   // 向量检索
    Supplier<String> web = scope.fork(() -> webSearch(query));      // 联网检索
    Supplier<String> tools = scope.fork(() -> callTools(query));    // 工具调用

    scope.join();            // 等所有子任务
    scope.throwIfFailed();   // 任一失败则整体失败

    String context = rag.get() + web.get() + tools.get();
    return llm.complete(buildPrompt(context, query));
}
```

结构化并发的优势：**子任务生命周期被父级作用域约束**，父任务结束/失败会自动取消未完成的子任务，避免「孤儿请求」占着 LLM 配额。

> 在 Spring Boot 里若不想用 preview API，可直接用 `Executors.newVirtualThreadPerTaskExecutor()` + `CompletableFuture`：

```java
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    var f1 = CompletableFuture.supplyAsync(() -> vectorSearch(query), executor);
    var f2 = CompletableFuture.supplyAsync(() -> webSearch(query), executor);
    CompletableFuture.allOf(f1, f2).join();
}
```

### 3.2 限流：虚拟线程不替你解决上游配额

**虚拟线程解决「本地线程不够」，不解决「上游模型限流」。** 如果你无限并发打 OpenAI/通义千问，会被 429 打回来。必须加**并发闸门**：

```java
// 用 Semaphore 限制「同时在飞」的 LLM 请求数
private final Semaphore llmGate = new Semaphore(64);   // 上游并发上限

public String callLlm(String prompt) throws InterruptedException {
    llmGate.acquire();
    try {
        return llmClient.complete(prompt);   // 阻塞 IO，虚拟线程会在此卸载
    } finally {
        llmGate.release();
    }
}
```

> 也可以在网关层/HTTP 客户端层做限流（Resilience4j `RateLimiter`/`Bulkhead`）。但**Semaphore + 虚拟线程**的组合非常契合：acquire 本身也是可挂起的阻塞点。

### 3.3 超时：必须有，且要能中断

LLM 调用没有超时 = 拿线上赌运气。

```java
public String callLlmWithTimeout(String prompt, Duration timeout) {
    try {
        return CompletableFuture
            .supplyAsync(() -> llmClient.complete(prompt), virtualExecutor)
            .orTimeout(timeout.toMillis(), TimeUnit.MILLISECONDS)
            .join();
    } catch (CompletionException e) {
        if (e.getCause() instanceof TimeoutException) {
            throw new LlmTimeoutException("LLM 调用超时");
        }
        throw e;
    }
}
```

> ⚠️ 光超时不够：如果底层 HTTP 客户端**不响应中断**，虚拟线程超时后仍会占着连接。要选**支持中断/取消**的客户端（如 JDK `HttpClient` 的 `sendAsync` + `HttpClient` 超时、或 Netty 系客户端的 read timeout）。

---

## 四、最大的坑：pinning（钉住载体线程）

这是虚拟线程上生产**必须治理**的问题。

### 4.1 两类 pinning

1. **`synchronized` 块内阻塞**：JDK 21 下，虚拟线程在 `synchronized` 里挂起会 pin 住 carrier。**JDK 24（JEP 491）已修复**，但如果你用 JDK 21/22/23，必须处理。
2. **native 方法/外部函数（FFM）调用中阻塞**：JVM 无法卸载，直接 pin。

### 4.2 定位 pinning

```bash
# JDK 21+ 开启 pinning 追踪
-Djdk.tracePinnedThreads=full      # 打印完整堆栈（JDK 21）
-Djdk.tracePinnedThreads=short     # 简略（JDK 21）

# JDK 24+ 用 JFR 事件
jcmd <pid> JFR.start settings=profile
# 查看 jdk.VirtualThreadPinned 事件
```

> JDK 21 的 `-Djdk.tracePinnedThreads=full` 是最实用的手段：直接把「哪个 `synchronized` 块钉住了载体线程」的栈打出来。

### 4.3 治理手段

- **把 `synchronized` 换成 `ReentrantLock`**（`Lock` 的阻塞是可挂起的）：
  ```java
  // ❌ 会 pin
  synchronized (lock) { blockingIo(); }
  // ✅ 可挂起
  lock.lock();
  try { blockingIo(); } finally { lock.unlock(); }
  ```
- **避免在虚拟线程里调用老旧的 native/SDK**。
- **升级到 JDK 24+**（JEP 491 修复了 `synchronized` pinning）。

**重点：LLM SDK 里常见的 pinning 源**——很多 JSON 解析、连接池、日志框架内部用了 `synchronized`。比如：

- 老版本 Jackson 某些路径、日志 appender；
- 数据库/HTTP 连接池的同步加锁；
- 一些向量库 Java 客户端用了 `synchronized`。

所以**上虚拟线程前，务必压测 + 开 `tracePinnedThreads` 观察**。

---

## 五、连接池与资源：别让虚拟线程被「池」卡死

虚拟线程的哲学是**「不要池化线程」**，但**下面的资源仍必须池化且有界**：

| 资源 | 是否池化 | 注意 |
|---|---|---|
| 虚拟线程 | ❌ 不要池化 | 用 `newVirtualThreadPerTaskExecutor` |
| HTTP 连接 | ✅ 必须池化 | 限制 max connections，否则打爆上游 |
| DB 连接 | ✅ 必须池化 | HikariCP，注意虚拟线程下 `maxPoolSize` 要匹配 |
| 信号量闸门 | ✅ 有界 | 限并发 |

**最危险的组合**：`newVirtualThreadPerTaskExecutor()` 接收无限任务 + 每次任务都从连接池借连接。如果连接池上限 20，而瞬时来了 10000 个虚拟线程，结果是 **10000 个虚拟线程排队等 20 个连接**——比你想象的还容易 stack/内存问题（每个排队的虚拟线程仍持有 prompt 等对象）。

**正确做法**：在**任务提交点**就用 Semaphore 限制了整体并发，或者让连接池超时 fail-fast。

```java
// 虚拟线程 + 有界闸门，避免「无限虚拟线程等有限连接」
private static final Semaphore GATE = new Semaphore(200);

public CompletionStage<Result> handle(Request req) {
    return CompletableFuture.supplyAsync(() -> {
        try {
            GATE.acquire();
            try { return process(req); } finally { GATE.release(); }
        } catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new RuntimeException(e); }
    }, virtualExecutor);
}
```

---

## 六、虚拟线程不适合的场景

虚拟线程**不是**用来加速 CPU 密集任务的：

- 大量 CPU 计算（加密、压缩、复杂算法）：虚拟线程不会让 CPU 变多，反而增加调度开销。
- **注意**：虚拟线程的 `carrier` 数量默认等于 CPU 核数，**CPU 密集型任务放进虚拟线程池会退化成串行**。
- 需要线程亲和/`ThreadLocal` 大量状态缓存：虚拟线程每个都是新线程，`ThreadLocal` 无复用意义，且要注意 `ThreadLocal` 泄漏（虚拟线程很短命，但数量巨大）。

> LLM 场景的「本地重排序（rerank 模型跑本地 CPU）」「向量相似度暴力计算」属于 CPU 密集，应放到**独立的平台线程池**，不要混进虚拟线程池。

---

## 七、生产落地检查清单

1. ✅ 开启 `spring.threads.virtual.enabled=true`（Spring Boot 3.2+）或自定义 `VirtualThreadPerTaskExecutor`。
2. ✅ 用 **Semaphore / 网关限流** 控制「在飞」的 LLM 并发数，匹配上游配额。
3. ✅ **HTTP/DB 连接池有界**，并设置获取超时（fail-fast）。
4. ✅ 所有 LLM 调用**显式超时**，并选用**可中断**的 HTTP 客户端。
5. ✅ JDK 21/22/23：开 `-Djdk.tracePinnedThreads=full` 排查 pinning；**能升级就升 JDK 24+**（JEP 491）。
6. ✅ 把 `synchronized` 热路径换成 `ReentrantLock`。
7. ✅ CPU 密集型子任务（本地 rerank / 向量计算）隔离到独立平台线程池。
8. ✅ 压测对比「平台线程池 vs 虚拟线程」的吞吐/延迟/TPS，别凭感觉。

---

## 八、面试高频追问

**Q1：虚拟线程为什么适合 LLM 应用？**
因为 LLM 调用是「高并发 + 长阻塞 + 低 CPU」的 IO 密集场景，虚拟线程在阻塞时卸载载体线程，能用极小的内存成本支撑海量并发等待。

**Q2：什么是 pinning？怎么排查和解决？**
虚拟线程在 `synchronized` 块或 native 调用中阻塞时无法卸载，会钉住载体线程导致吞吐退化。排查：JDK 21 用 `-Djdk.tracePinnedThreads=full`，JDK 24+ 用 JFR `jdk.VirtualThreadPinned` 事件。解决：`synchronized` → `ReentrantLock`，避免 native 阻塞，升级到修复了 JEP 491 的 JDK 24+。

**Q3：虚拟线程能替代线程池吗？**
不能一概而论。虚拟线程替代的是「一请求一线程」的平台线程池；但**连接、限流闸门、CPU 密集任务仍需池化/隔离**。CPU 密集任务放虚拟线程还可能导致载体线程退化成串行。

**Q4：虚拟线程下线程池 `ThreadLocal` 还有意义吗？**
虚拟线程短命且不复用，`ThreadLocal` 的复用收益没了；反而要注意每次创建都带状态的开销。上下文传递可考虑 `ScopedValue`（JDK 21+）。

**Q5：并发调用 LLM 时，限流该放哪层？**
本地用 `Semaphore`/Resilience4j 控在飞请求，网关层做全局限流与配额，客户端层设超时与重试（带退避），三层配合。

---

## 结语

虚拟线程是为「大模型时代的高并发阻塞 IO」量身定制的工具：它让 Java 后端用极低成本扛住海量 Agent 调用。但它**不解决上游限流、不解决 pinning、不解决连接池瓶颈**——真正的生产落地，是「虚拟线程 + 有界闸门 + 有界连接池 + 可中断超时 + pinning 治理」的组合拳。把这套组合拳打顺，你的 AI 应用才能在 Java 栈上既高并发又稳定。
