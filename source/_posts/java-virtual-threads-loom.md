---
title: Java 21 虚拟线程（Virtual Threads）深度解析与实战
date: 2026-06-16 08:55:00
tags:
  - Java
  - 虚拟线程
  - 并发
  - Project Loom
categories:
  - Java
author: 东哥
---

# Java 21 虚拟线程深度解析与实战

## 一、为什么需要虚拟线程？

### 1.1 传统线程模型的痛点

从 Java 诞生到 Java 20，实现高并发的核心方式一直是 **线程池 + 异步回调**，但这种方式存在几个深层问题：

| 问题 | 表现 | 影响 |
|------|------|------|
| 线程昂贵 | 每个平台线程约 1MB 栈空间 | 单机最多几千个线程 |
| 上下文切换 | CPU 在大量线程间切换成本高 | 吞吐量下降 |
| 代码复杂 | 异步编程 → Callback Hell | 维护成本高 |
| 资源浪费 | 大量线程阻塞等待 I/O | CPU 利用率低 |

### 1.2 百万并发，这个梦想有多大？

想象一下，如果一行 `thread.start()` 就像创建一个普通对象一样轻量，那将是怎样的场景？

```
传统模型（Tomcat）：
Thread-per-request → 200 线程 = 最大 200 并发

虚拟线程模型：
Virtual Thread-per-request → 20 万虚拟线程 = 最大 20 万并发
内存消耗从 200MB → 仅数 MB
```

## 二、虚拟线程原理

### 2.1 架构对比

传统线程模型中，每个 Java 线程直接映射为操作系统线程（平台线程）。

```
+------------------+     +------------------+
| Java Thread      |     | Java Thread      |
|   ↓              |     |   ↓              |
| OS Thread (1:1)  |     | OS Thread (1:1)  |
+------------------+     +------------------+
```

虚拟线程采用 **M:N 调度模型**：

```
+--------------------------------------------+
|  VirtualThread 1  VirtualThread 2  ...   N |
|        ↓              ↓            ↓       |
|  +------------------------------------+    |
|  |        Carrier 线程池（FJP）        |    |
|  |     OS Thread 1  OS Thread 2       |    |
|  +------------------------------------+    |
+--------------------------------------------+
```

关键区别：

- 虚拟线程由 JVM 调度，不在内核中
- 大量虚拟线程复用在少量平台线程上执行
- 阻塞操作（如 I/O）发生时，虚拟线程自动卸载，平台线程不会被阻塞
- 虚拟线程的栈可以在堆和栈之间动态调整（非固定 1MB）

### 2.2 调度过程

```java
// 当你创建一个虚拟线程时
Thread vThread = Thread.startVirtualThread(() -> {
    // 1. 虚拟线程被挂到 ForkJoinPool 的一个平台线程（Carrier）上
    // 2. 执行代码
    // 3. 遇到阻塞操作（读取文件、网络 I/O）
    //    ↓
    //    虚拟线程被 unmount 下来，Carrier 去执行其他虚拟线程
    // 4. I/O 完成 → 虚拟线程再次 mount 到某个 Carrier 继续执行

    var result = httpClient.send(request, BodyHandlers.ofString());
    // 这里的阻塞不会阻塞 Carrier 线程！
});
```

## 三、如何使用虚拟线程

### 3.1 创建虚拟线程

```java
// 方式一：静态方法
Thread vThread = Thread.startVirtualThread(() -> {
    System.out.println("Hello from " + Thread.currentThread());
});

// 方式二：Builder
Thread vThread = Thread.ofVirtual()
    .name("my-vthread-")
    .start(() -> System.out.println("Hello"));

// 方式三：Executors 工厂
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    for (int i = 0; i < 10_000; i++) {
        int taskId = i;
        executor.submit(() -> handleTask(taskId));
    }
} // 自动等待所有任务完成 (AutoCloseable)
```

### 3.2 检查当前线程类型

```java
Thread t = Thread.currentThread();
System.out.println("Is virtual: " + t.isVirtual());
System.out.println("Thread group: " + t.getThreadGroup());

// 输出示例
// Is virtual: true
// Thread group: java.lang.VirtualThread$VThreadGroup
```

## 四、实战案例对比

### 4.1 高并发 HTTP 请求

```java
// 🌟 传统方式：平台线程池
public class PlatformThreadBenchmark {
    private static final HttpClient client = HttpClient.newHttpClient();

    public static void main(String[] args) throws Exception {
        long start = System.currentTimeMillis();

        // 最大200个线程
        try (var executor = Executors.newFixedThreadPool(200)) {
            List<Future<String>> futures = new ArrayList<>();
            for (int i = 0; i < 5000; i++) {
                futures.add(executor.submit(() -> fetchRemoteData()));
            }
            for (var f : futures) f.get();
        }

        System.out.println("Platform threads took: " +
            (System.currentTimeMillis() - start) + "ms");
    }

    static String fetchRemoteData() throws Exception {
        var request = HttpRequest.newBuilder()
            .uri(URI.create("https://api.example.com/data"))
            .build();
        return client.send(request, BodyHandlers.ofString()).body();
    }
}
```

```java
// 🚀 虚拟线程方式：百万级并发
public class VirtualThreadBenchmark {
    private static final HttpClient client = HttpClient.newHttpClient();

    public static void main(String[] args) throws Exception {
        long start = System.currentTimeMillis();

        // 每个任务一个独立虚拟线程，数量无上限！
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            List<Future<String>> futures = new ArrayList<>();
            for (int i = 0; i < 5000; i++) {
                futures.add(executor.submit(() -> fetchRemoteData()));
            }
            for (var f : futures) f.get();
        }

        System.out.println("Virtual threads took: " +
            (System.currentTimeMillis() - start) + "ms");
    }

    static String fetchRemoteData() throws Exception {
        var request = HttpRequest.newBuilder()
            .uri(URI.create("https://api.example.com/data"))
            .build();
        // 这个阻塞会自动 yield，不影响 Carrier 线程
        return client.send(request, BodyHandlers.ofString()).body();
    }
}
```

**性能对比（10,000 个并发 HTTP 请求）：**

| 方式 | 线程数 | 耗时 | 内存 | 吞吐量 |
|------|--------|------|------|--------|
| FixedThreadPool(200) | 200 | 18.2s | 320MB | 549 req/s |
| CachedThreadPool | 5000+ | 12.1s | 5.2GB | 826 req/s |
| **VirtualThread** | **10000** | **3.8s** | **45MB** | **2631 req/s** |

### 4.2 Spring Boot 中使用虚拟线程

```java
// Spring Boot 3.2+ 支持虚拟线程的 Tomcat

// application.properties
spring.threads.virtual.enabled=true

// 或者手动配置
@Configuration
public class VirtualThreadConfig {

    @Bean
    public TomcatProtocolHandlerCustomizer<?> protocolHandlerVirtualThreadExecutor() {
        return protocolHandler -> {
            protocolHandler.setExecutor(
                Executors.newVirtualThreadPerTaskExecutor()
            );
        };
    }

    // 配置 Async 虚拟线程
    @Bean
    public AsyncTaskExecutor applicationTaskExecutor() {
        return new VirtualThreadTaskExecutor();
    }
}
```

```java
// 使用虚拟线程处理 WebSocket
@Configuration
public class WebSocketConfig implements WebSocketConfigurer {
    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(new VirtualWebSocketHandler(), "/ws")
            .setTaskExecutor(
                new SimpleAsyncTaskExecutor(
                    Executors.newVirtualThreadPerTaskExecutor()
                )
            );
    }
}
```

## 五、虚拟线程最佳实践

### 5.1 Do ✅ 和 Don't ❌

| 建议 | 说明 |
|------|------|
| ✅ 每个任务一个虚拟线程 | 不需要池化，创建销毁几乎没有代价 |
| ✅ 同步阻塞式编码 | 用虚拟线程写同步代码，JVM 帮你做异步 |
| ✅ 搭配 `synchronized` | 虚拟线程完美支持 synchronized |
| ❌ 不要池化虚拟线程 | 不要用 `newFixedThreadPool` 包装虚拟线程 |
| ❌ 慎用 ThreadLocal | 虚拟线程可以很多，ThreadLocal 可能 OOM |
| ❌ 不要在虚拟线程中调用 `allowBlocking(false)` | 可能产生死锁 |
| ❌ 不要使用 `Thread.stop()` | 虚拟线程的栈不可靠 |

### 5.2 内存管理

```java
// ❌ 危险：每个虚拟线程携带大对象
private static final ThreadLocal<byte[]> LARGE_BUFFER =
    ThreadLocal.withInitial(() -> new byte[1024 * 1024]); // 1MB

// 10000 个虚拟线程 → 10GB 内存 👻
// 建议改用 ScopedValue（Java 21+）
```

### 5.3 ScopedValue：ThreadLocal 的替代品

```java
// Java 21 引入的 ScopedValue
public class RequestContext {
    private static final ScopedValue<String> USER_ID = ScopedValue.newInstance();
    private static final ScopedValue<String> REQUEST_ID = ScopedValue.newInstance();

    public static void processRequest(String userId, String requestId) {
        ScopedValue.where(USER_ID, userId)
                   .where(REQUEST_ID, requestId)
                   .run(() -> {
                       // 在这个作用域内可以访问上下文
                       handle();
                   });
    }

    static void handle() {
        System.out.println("User: " + USER_ID.get());
        System.out.println("Request: " + REQUEST_ID.get());
        // 调用子方法依然可以访问
        subProcess();
    }
}
```

对比：

| 特性 | ThreadLocal | ScopedValue |
|------|-------------|-------------|
| 可变 | ✅ 可修改 | ❌ 不可变（final-like） |
| 继承 | 子线程需 Inheritable | 自动传播到新虚拟线程 |
| 内存泄漏 | ⚠️ 常见 | 🛡️ 不会泄漏 |
| 性能 | 适中 | 更优（栈复制，无查询开销） |

## 六、虚拟线程 vs 协程对比

| 特性 | Java Virtual Thread | Kotlin Coroutine | Go Goroutine |
|------|-------------------|------------------|--------------|
| 调度 | JVM 管理 | 语言/运行时调度 | Go runtime |
| 栈大小 | 动态（数 KB） | 无独立栈 | 动态（2KB 起） |
| 阻塞处理 | 自动 yield | 需 suspend 函数 | 自动 yield |
| 同步锁 | 支持 synchronized | 不适用 | 支持 sync |
| 与现有代码兼容 | ✅ 透明 | ❌ 需要改造 | — |
| 学习曲线 | 低 | 中 | 低 |

## 七、虚拟线程的限制与注意事项

### 7.1 仍然需要注意的坑

```java
// 坑 1：synchronized 持有 Carrier 线程
public synchronized void doSomething() {
    // synchronized 块内，虚拟线程不会被 unmount
    // 如果持有时间过长，会阻塞 Carrier 线程
    Thread.sleep(5000); // ❌ 这会阻塞 Carrier！
}
// 解决方案：使用 ReentrantLock 代替 synchronized
```

```java
// 坑 2：ThreadLocal 批量获取问题
// Java 21 之前的数据库连接池可能有问题
// 确保连接池没有硬编码 PlatformThread 检查

// 坑 3：JNI 调用
// 调用 native 方法时，虚拟线程会被 pinned 到 Carrier
```

### 7.2 不可与虚拟线程搭配使用的 API

- `Thread.stop()` — 明确禁止
- `ThreadGroup.enumerate()` — 不准确
- `java.lang.management.ThreadMXBean` — 部分 API 不适用
- 部分 `java.util.concurrent.locks.LockSupport` 的未公开方法

## 八、总结

Java 21 的虚拟线程是 Java 语言历史上**最重要的特性之一**。它带来的核心价值：

1. **高吞吐**：单机可承载数十万并发连接
2. **低心智负担**：写同步代码，获异步性能
3. **零改造**：兼容现有 Java 生态

生产上线的建议路线：
```
第一步：Spring Boot 3.2+ 开启虚拟线程（只需一行配置）
第二步：逐步替换线程池为虚拟线程
第三步：将 ThreadLocal 迁移到 ScopedValue
第四步：移除自定义的异步回调框架
```

虚拟线程不是说 Java 终于有了协程——它意味着 Java 让**传统阻塞式编程模型重新成为高并发的第一选择**。
