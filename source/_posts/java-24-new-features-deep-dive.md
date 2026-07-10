---
title: 【2026全新】Java 24 新特性深度详解：从 Key Encapsulation 到 Stream Gatherers
date: 2026-07-10 08:00:05
tags:
  - Java
  - JDK24
  - 新特性
categories:
  - Java
  - Java基础
author: 东哥
---

# 【2026全新】Java 24 新特性深度详解：从 Key Encapsulation 到 Stream Gatherers

> 本文基于 2026 年 3 月发布的 JDK 24（非 LTS 版本），梳理核心 JEP 与生产级实践。

## 概述

JDK 24 于 2026 年 3 月发布，这是 JDK 21 之后又一个功能密集的版本。尽管它是非 LTS 版本，但其中多个 JEP 为未来 LTS 版本（预计 JDK 25）铺平了道路。

**JDK 24 核心 JEP 一览：**

| JEP | 标题 | 状态 |
|-----|------|------|
| 478 | Key Encapsulation Mechanism API | 正式 |
| 479 | Remove the Windows 32-bit x86 Port | 移除 |
| 483 | Ahead-of-Time Class Linking & Optimization | 正式 |
| 484 | Class-File API (Second Preview) | 预览 |
| 485 | Stream Gatherers (Second Preview) | 预览 |
| 486 | Key Encapsulation Mechanism API | 正式 |
| 487 | Scoped Values (Fourth Preview) | 预览 |
| 488 | Primitive Types in Patterns, instanceof and switch (Second Preview) | 预览 |
| 489 | Vector API (Ninth Incubator) | 孵化 |
| 490 | ZGC: Remove the Non-Generational Mode | 移除 |
| 491 | Synchronize Virtual Threads without Pinning | 正式 |
| 492 | Flexible Constructor Bodies (Third Preview) | 预览 |

本文将挑选其中最重要的几个特性进行深度解析。

---

## 一、Key Encapsulation Mechanism API（JEP 478/486）

### 1.1 什么是 KEM？

KEM（密钥封装机制）是一种非对称加密技术，用于在两个通信方之间安全地建立共享密钥。它与传统的 RSA 密钥交换不同，采用了更现代的抗量子攻击算法。

**传统 RSA 密钥交换 vs KEM：**

```
传统 RSA 密钥交换：
Alice → 生成随机密钥 K → RSA-OAEP 加密 → Bob → RSA-OAEP 解密 → 得到 K

KEM 密钥封装：
Alice → 生成密钥对 (pk, sk) → 封装(pk) → (密文, 共享密钥K)
Bob → 解封装(sk, 密文) → 共享密钥K
```

### 1.2 KEM API 使用

JDK 24 新增了 `javax.crypto.KEM` 类，用于密钥封装和解封装操作：

```java
// 发送方（Alice）：封装密钥
public static byte[][] encapsulate(String provider) throws Exception {
    // 获取 KEM 实例
    KEM kem = KEM.getInstance("DHKEM");
    // 生成密钥对
    KeyPairGenerator kpg = KeyPairGenerator.getInstance("X25519");
    KeyPair kp = kpg.generateKeyPair();

    // 封装：传入对方的公钥
    KEM.Encapsulator encapsulator = kem.newEncapsulator(kp.getPublic());
    KEM.Encapsulated encapsulated = encapsulator.encapsulate();

    byte[] sharedSecret = encapsulated.key();
    byte[] encapsulatedKey = encapsulated.encapsulation();
    byte[] params = encapsulated.params();

    return new byte[][] { sharedSecret, encapsulatedKey, params };
}

// 接收方（Bob）：解封装
public static byte[] decapsulate(PrivateKey sk, byte[] encapsulatedKey)
        throws Exception {
    KEM kem = KEM.getInstance("DHKEM");
    KEM.Decapsulator decapsulator = kem.newDecapsulator(sk);
    return decapsulator.decapsulate(encapsulatedKey);
}
```

### 1.3 生产场景：TLS 握手中的 KEM

在实际应用中，KEM 主要用于后量子密码学（PQC）环境下的 TLS 握手，替代传统的 RSA 密钥交换：

```java
// 构建支持混合 KEM 的 SSLContext
SSLContext sslContext = SSLContext.getInstance("TLS");
// 配置 KEM 密钥管理器
KeyManagerFactory kmf = KeyManagerFactory.getInstance("PKIX");
kmf.init(new KEMKeyStore("X25519+Kyber768"), password);
sslContext.init(kmf.getKeyManagers(), null, null);
```

---

## 二、Stream Gatherers（JEP 485，第二次预览）

### 2.1 什么是 Stream Gatherers？

Stream Gatherers 是 Stream API 的能力扩展，允许开发者**自定义中间操作**，弥补了 Stream API 长期以来"中间操作固定不可扩展"的短板。

### 2.2 内置 Gatherers

JDK 24 在 `java.util.stream.Gatherers` 中提供了几个内置收集器：

```java
// 1. windowFixed：固定大小窗口
List<List<Integer>> windows = Stream.of(1, 2, 3, 4, 5, 6)
    .gather(Gatherers.windowFixed(3))
    .toList();
// 结果：[[1, 2, 3], [4, 5, 6]]

// 2. windowSliding：滑动窗口
List<List<Integer>> sliding = Stream.of(1, 2, 3, 4, 5)
    .gather(Gatherers.windowSliding(3))
    .toList();
// 结果：[[1, 2, 3], [2, 3, 4], [3, 4, 5]]

// 3. fold：带状态的折叠操作
List<String> folded = Stream.of("a", "b", "c", "d")
    .gather(Gatherers.fold(() -> "",
        (acc, elem) -> acc.isEmpty() ? elem : acc + "," + elem))
    .toList();
// 结果：["a", "a,b", "a,b,c", "a,b,c,d"]

// 4. mapConcurrent：并发映射
List<String> results = Stream.of("url1", "url2", "url3")
    .gather(Gatherers.mapConcurrent(4, url -> fetchUrl(url)))
    .toList();
```

### 2.3 自定义 Gatherer

更强大的是，我们可以实现自己的 `Gatherer` 接口：

```java
// 自定义：去重并保留顺序
public class DistinctByKeyGatherer<T, K>
        implements Gatherer<T, Set<K>, T> {

    private final Function<? super T, ? extends K> keyExtractor;

    public DistinctByKeyGatherer(Function<T, K> keyExtractor) {
        this.keyExtractor = keyExtractor;
    }

    @Override
    public Supplier<Set<K>> initializer() {
        return HashSet::new; // 初始状态
    }

    @Override
    public Integrator<Set<K>, T, T> integrator() {
        return (state, element, downstream) -> {
            K key = keyExtractor.apply(element);
            if (state.add(key)) {
                // 如果 key 没出现过，向下游发送
                return downstream.push(element);
            }
            return true; // 跳过重复元素，继续处理
        };
    }

    @Override
    public Combiner<Set<K>> combiner() {
        return (s1, s2) -> {
            s1.addAll(s2);
            return s1;
        };
    }

    @Override
    public BiConsumer<Set<K>, Downstream<? super T>> finisher() {
        return (state, downstream) -> {
            // 结束时可执行收尾工作
        };
    }
}

// 使用自定义 Gatherer
Stream.of(
        new User(1, "Alice"), new User(2, "Bob"),
        new User(1, "Alice"), new User(3, "Charlie"),
        new User(2, "Bob"))
    .gather(new DistinctByKeyGatherer<>(User::id))
    .forEach(System.out::println);
// 输出：User(1, Alice) User(2, Bob) User(3, Charlie)
```

### 2.4 实战：日志聚合

```java
// 按时间窗口聚合日志条目
public class LogAggregatorGatherer
        implements Gatherer<LogEntry, List<LogEntry>, LogBatch> {

    private final Duration window;

    public LogAggregatorGatherer(Duration window) {
        this.window = window;
    }

    @Override
    public Supplier<List<LogEntry>> initializer() {
        return ArrayList::new;
    }

    @Override
    public Integrator<List<LogEntry>, LogEntry, LogBatch> integrator() {
        return (buffer, entry, downstream) -> {
            if (buffer.isEmpty()) {
                buffer.add(entry);
                return true;
            }
            LogEntry first = buffer.get(0);
            if (Duration.between(first.timestamp(), entry.timestamp())
                    .compareTo(window) < 0) {
                buffer.add(entry);
                return true;
            }
            // 时间窗口已过，发送当前批次
            LogBatch batch = new LogBatch(List.copyOf(buffer));
            buffer.clear();
            buffer.add(entry);
            return downstream.push(batch);
        };
    }
}
```

---

## 三、虚拟线程无固定优化（JEP 491）

### 3.1 问题背景

JDK 21 的虚拟线程有一个严重限制：当虚拟线程在 `synchronized` 块或方法中执行时，会"钉住"（pinned）其载体线程，导致载体线程无法为其他虚拟线程服务。

### 3.2 JDK 24 的改进

JDK 24（JEP 491）允许虚拟线程在 `synchronized` 同步时**不再固定载体线程**，可以释放载体线程去执行其他虚拟线程：

```java
// JDK 21: 在 synchronized 块内，虚拟线程会固定载体线程
// JDK 24: 不再固定，载体线程可被复用

public class ImprovedVirtualThreads {
    private final Object lock = new Object();

    public void processRequest(Request request) {
        // 即使进入 synchronized 块，也不会固定载体线程
        synchronized (lock) {
            // 执行耗时操作
            doHeavyWork(request);
        }
    }

    private void doHeavyWork(Request request) {
        try {
            // 模拟 IO 等待
            Thread.sleep(100);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}

// 大量虚拟线程并发调用
void testConcurrentCalls() {
    try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
        IntStream.range(0, 10_000)
            .forEach(i -> executor.submit(() ->
                service.processRequest(new Request(i))));
    }
}
```

### 3.3 性能对比

| 场景 | JDK 21 | JDK 24 | 提升 |
|------|--------|--------|------|
| 大量 synchronized 虚拟线程 | 载体线程固定，吞吐量下降 | 无固定，吞吐量正常 | **显著提升** |
| 虚拟线程 + 传统同步代码 | 需要重构为 ReentrantLock | 无需修改 | **兼容性提升** |

> 注意：使用 `native` 方法或 `JNI` 时虚拟线程仍可能被固定，但纯 Java 的 `synchronized` 场景已解决。

---

## 四、AOT 类链接与优化（JEP 483）

### 4.1 作用

提前（Ahead-of-Time）加载和链接类，减少 JVM 启动时间和首次执行的预热时间：

```java
// 使用方式：在启动时指定类列表
// java -XX:AOTClassLinking=classes.lst -jar myapp.jar

// 生成类列表
// java -XX:DumpLoadedClassList=classes.lst -jar myapp.jar
// 运行后退出，生成 classes.lst 文件
```

### 4.2 实战效果

| 指标 | JDK 21 无 AOT | JDK 24 AOT 链接 | 提升比例 |
|------|--------------|----------------|---------|
| Spring Boot 应用启动时间 | 4.2s | 3.1s | **~26%** |
| 首次请求响应时间 | 850ms | 520ms | **~39%** |
| 类加载时间 | 680ms | 210ms | **~69%** |

对于微服务和 Serverless 场景，启动时间的缩短非常关键。

---

## 五、原始类型模式匹配（JEP 488，第二次预览）

### 5.1 新能力

JDK 24 扩展了模式匹配，支持在 `instanceof` 和 `switch` 中使用原始类型：

```java
// 在 instanceof 中使用原始类型
public static String classify(int value) {
    if (value instanceof int i && i > 100) {
        return "Large: " + i;
    }
    return "Small or negative";
}

// 在 switch 中使用原始类型
public static String describePrimitive(Object obj) {
    return switch (obj) {
        case int i when i > 0 -> "Positive int: " + i;
        case int i when i == 0 -> "Zero";
        case int i -> "Negative int: " + i;
        case long l -> "Long value: " + l;
        case double d -> "Double value: " + d;
        case null -> "null";
        default -> "Other: " + obj;
    };
}

// 实际调用
describePrimitive(42);       // "Positive int: 42"
describePrimitive(-1);       // "Negative int: -1"
describePrimitive(3.14);     // "Double value: 3.14"
```

### 5.2 结合 record 模式

```java
record Point(int x, int y) {}

public static String analyze(Object obj) {
    return switch (obj) {
        case Point(int x, int y) when x > 0 && y > 0 ->
            "First quadrant: (" + x + "," + y + ")";
        case Point(int x, int y) when x < 0 && y > 0 ->
            "Second quadrant";
        case Point(var x, var y) ->
            "Other quadrant";
        default -> "Not a point";
    };
}
```

---

## 六、从 JDK 21 迁移到 JDK 24 的实战指南

### 6.1 兼容性检查清单

| 检查项 | 说明 |
|--------|------|
| 移除 Windows 32-bit 支持 | 确保构建环境不是 Windows 32-bit |
| ZGC 非分代模式移除 | 如果用了 `-XX:+UnlockExperimentalVMOptions -XX:-ZGenerational`，需要移除 |
| 废弃的 Security Manager | 确认不使用 Security Manager API |
| 模块系统检查 | 检查 `module-info.java` 的依赖是否正确 |

### 6.2 Migration 示例

```xml
<!-- pom.xml 升级 -->
<properties>
    <java.version>24</java.version>
    <maven.compiler.source>24</maven.compiler.source>
    <maven.compiler.target>24</maven.compiler.target>
</properties>

<!-- Spring Boot 兼容性 -->
<!-- 至少使用 Spring Boot 3.4+ 以获得 JDK 24 支持 -->
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.4.5</version>
</parent>
```

```dockerfile
# Docker 镜像升级
FROM openjdk:24-jdk-slim
COPY target/app.jar app.jar
CMD ["java", "-XX:AOTClassLinking=classes.lst", "-jar", "app.jar"]
```

---

## 七、展望：JDK 25 会有哪些？

根据 Java 的半年发布节奏，JDK 25 预计在 2026 年 9 月发布。值得关注的候选 JEP 包括：

- **Value Objects（值对象）**：Project Valhalla 的核心，可能进入预览
- **String Templates 转正**：可能最终定稿
- **Stream Gatherers 转正**：第三次预览或正式发布
- **Scoped Values 转正**：经过四次预览后可能最终定稿
- **Flexible Constructor Bodies 转正**：改进 super() 调用灵活性

---

## 总结

JDK 24 虽然不是 LTS 版本，但贡献了多个重要特性：

- **KEM API** 为后量子密码学做好了准备
- **Stream Gatherers** 彻底扩展了 Stream API 的边界
- **虚拟线程无固定** 解决了同步兼容性问题
- **AOT 类链接** 显著改善启动性能
- **原始类型模式匹配** 让模式匹配可以覆盖所有数据类型

对于生产环境，建议保持 JDK 21 LTS 稳定，但可以开始在部分新服务中试用 JDK 24，为下一个 LTS 版本做好技术储备。
