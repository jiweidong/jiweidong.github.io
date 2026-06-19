---
title: Java 21 新特性详解：虚拟线程增强与模式匹配实战
date: 2026-06-19 08:30:00
tags:
  - Java
  - Java 21
  - 虚拟线程
categories:
  - Java
author: 东哥
---
Java 21（2023年9月 LTS）是继 Java 17 之后又一个重要的长期支持版本，引入了多项预览特性的正式版以及全新的语言增强。本文将深入解析 Java 21 的核心新特性，从虚拟线程实战到模式匹配、分代 ZGC 等，帮助读者快速掌握并用好这些新能力。

<!-- more -->

## 一、虚拟线程（Virtual Threads）正式版

虚拟线程在 Java 19 中作为预览特性引入，Java 20 再次预览，Java 21 终于正式转正。这是 Project Loom 最重要的产出，旨在从根本上简化高吞吐量并发应用的开发。

### 1.1 虚拟线程 vs 平台线程

| 对比维度 | 平台线程（OS Thread） | 虚拟线程（Virtual Thread） |
|---------|----------------------|--------------------------|
| 调度单位 | 操作系统线程 | JVM 管理，多路复用到少量 Carrier 线程 |
| 创建成本 | 高（约 1MB 栈空间） | 极低（约几百字节） |
| 上下文切换 | 内核态，开销大 | 用户态，开销极小 |
| 最大数量 | 几千到几万 | 数百万 |
| 适用场景 | CPU 密集型 | IO 密集型（等待时间长的任务） |

### 1.2 创建虚拟线程的四种方式

```java
// 方式1：使用 Thread.ofVirtual() 工厂方法
Thread vThread = Thread.ofVirtual()
    .name("my-virtual-thread")
    .unstarted(() -> {
        System.out.println("Hello from " + Thread.currentThread());
    });
vThread.start();
vThread.join();

// 方式2：直接启动
Thread vThread2 = Thread.startVirtualThread(() -> {
    System.out.println("Running in virtual thread");
});

// 方式3：使用 Executors.newVirtualThreadPerTaskExecutor()
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    for (int i = 0; i < 10_000; i++) {
        int taskId = i;
        executor.submit(() -> {
            System.out.println("Task " + taskId + " on " + Thread.currentThread());
            Thread.sleep(100); // 不会阻塞平台线程
            return taskId;
        });
    }
} // 隐式 shutdown，等待所有任务完成
```

### 1.3 虚拟线程的挂起与恢复机制

虚拟线程的核心原理是：当虚拟线程执行阻塞操作（如 `Thread.sleep()`、`Socket.read()`、`BlockingQueue.take()`）时，JVM 会自动将其挂起（yield），将 Carrier 线程释放给其他虚拟线程使用。阻塞操作恢复时，虚拟线程被重新调度。

```java
// 百万级虚拟线程示例
public class VirtualThreadDemo {
    public static void main(String[] args) throws Exception {
        long start = System.currentTimeMillis();

        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            for (int i = 0; i < 1_000_000; i++) {
                int taskId = i;
                executor.submit(() -> {
                    // 模拟 IO 操作
                    try { Thread.sleep(10); } catch (InterruptedException e) {}
                    return taskId;
                });
            }
        } // 所有虚拟线程在此处等待完成

        long end = System.currentTimeMillis();
        System.out.println("Completed 1,000,000 tasks in " + (end - start) + "ms");
    }
}
```

> **注意**：如果在平台线程中跑 100 万 `Thread.sleep(10)`，会直接 OOM。而虚拟线程可以轻松处理。

### 1.4 虚拟线程与 ThreadLocal

虚拟线程支持 ThreadLocal，但官方建议谨慎使用。因为虚拟线程数量巨大，ThreadLocal 占用的内存会随之线性增长：

```java
// 虚拟线程的 ThreadLocal 可能内存膨胀
private static final ThreadLocal<Map<String, Object>> requestContext = new ThreadLocal<>();

// 更好的方式：使用 Scoped Values（见下文）
```

## 二、结构化并发（StructuredTaskScope）

`StructuredTaskScope` 将并发任务的生命周期与代码块绑定——所有子任务必须在退出作用域前完成或被取消。这避免了任务泄漏，使得错误处理和取消语义更加清晰。

### 2.1 基本用法

```java
// 结构化并发示例：同时查询多个数据源
record Response(String user, String orders, String notifications) {}

Response readAllData() throws ExecutionException, InterruptedException {
    try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
        // 并发提交三个任务
        StructuredTaskScope.Subtask<String> userTask =
            scope.fork(() -> fetchUser());
        StructuredTaskScope.Subtask<String> ordersTask =
            scope.fork(() -> fetchOrders());
        StructuredTaskScope.Subtask<String> notifTask =
            scope.fork(() -> fetchNotifications());

        // 等待所有任务完成或任一失败
        scope.join();
        scope.throwIfFailed(); // 如果有任务异常，抛出

        // 聚合结果
        return new Response(
            userTask.get(),
            ordersTask.get(),
            notifTask.get()
        );
    }
}
```

### 2.2 错误处理策略

```java
// ShutdownOnFailure：任一任务失败即取消其他任务（默认策略）
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    // ...
}

// ShutdownOnSuccess：任一任务成功即取消其他任务
try (var scope = new StructuredTaskScope.ShutdownOnSuccess<String>()) {
    scope.fork(() -> fetchFromServiceA());
    scope.fork(() -> fetchFromServiceB());
    scope.fork(() -> fetchFromServiceC());
    String result = scope.join().result(); // 返回第一个成功的结果
}
```

### 2.3 与 CompletableFuture 对比

| 维度 | CompletableFuture | StructuredTaskScope |
|-----|-------------------|-------------------|
| 线程泄漏风险 | 有 | 无（try-with-resources 自动管理） |
| 错误传播 | .exceptionally() 链式处理 | throwIfFailed() 集中处理 |
| 取消语义 | 需手动控制 | 自动取消子任务 |
| 代码可读性 | 链式调用，调试困难 | 线性代码，易于调试 |
| 嵌套作用域 | 难以管理 | 清晰的作用域嵌套 |

## 三、作用域值（Scoped Values）

Scoped Values 是 ThreadLocal 的替代方案，专为解决虚拟线程场景下 ThreadLocal 的内存膨胀问题。

```java
// 定义作用域值
private static final ScopedValue<String> REQUEST_ID = ScopedValue.newInstance();

void handleRequest(String requestId) {
    // 绑定值到当前线程的作用域
    ScopedValue.where(REQUEST_ID, requestId)
        .run(() -> {
            // 在此作用域内，所有代码都可以读取 REQUEST_ID
            processRequest();
        });
}

void processRequest() {
    // 获取作用域绑定的值
    String reqId = REQUEST_ID.get();
    System.out.println("Processing request: " + reqId);

    // 在虚拟线程中调用其他方法
    validateRequest();
    saveToDatabase();
}

void validateRequest() {
    // 子调用也可以读取
    System.out.println("Validating: " + REQUEST_ID.get());
}
```

**Scoped Values vs ThreadLocal**：

```java
// ThreadLocal：可变，任何方法都可以修改
private static final ThreadLocal<String> ctx = new ThreadLocal<>();
ctx.set("value");       // 可在任何地方修改
ctx.get();              // 读取
ctx.remove();           // 删除

// Scoped Value：不可变（一旦绑定，作用域内不变）
private static final ScopedValue<String> SCOPED = ScopedValue.newInstance();
ScopedValue.where(SCOPED, "value").run(() -> {
    // SCOPED.get() 总是返回 "value"
    // 在此作用域内不能被覆盖
});
```

**不可变性的优势**：Scoped Values 的不可变性使得数据流更加透明，减少了并发程序中的意外修改 bug。同时也避免了 ThreadLocal 在多线程场景下的内存泄漏问题。

## 四、Record Patterns 与 Pattern Matching

### 4.1 Record Patterns（正式版）

Record Patterns 在 Java 19 预览，Java 21 正式转正。它允许在解构 Record 时直接提取组件值：

```java
// 定义 Record
record Point(int x, int y) {}
record Line(Point start, Point end) {}

// 使用 Record Pattern 解构
void printSum(Object obj) {
    if (obj instanceof Point(int x, int y)) {
        // x 和 y 已经自动提取
        System.out.println(x + y);
    }
}

// 嵌套 Record Pattern
void printLine(Object obj) {
    if (obj instanceof Line(Point(int x1, int y1), Point(int x2, int y2))) {
        System.out.println("Line from (" + x1 + "," + y1 + ") to (" + x2 + "," + y2 + ")");
    }
}
```

### 4.2 Pattern Matching for switch（正式版）

Switch 的模式匹配同样在 Java 21 转正，支持对任意类型进行匹配和模式解构：

```java
// 传统方式：一堆 if-else
String formatValue(Object obj) {
    if (obj instanceof String s) {
        return "String: " + s;
    } else if (obj instanceof Integer i) {
        return "Integer: " + i;
    } else if (obj instanceof Long l) {
        return "Long: " + l;
    } else if (obj instanceof Double d) {
        return "Double: " + d;
    } else {
        return "Unknown";
    }
}

// Java 21：使用 switch 模式匹配（简洁且类型安全）
String formatValue(Object obj) {
    return switch (obj) {
        case String s -> "String: " + s;
        case Integer i -> "Integer: " + i;
        case Long l    -> "Long: " + l;
        case Double d  -> "Double: " + d;
        case null      -> "null";     // 显式处理 null（Java 17 需要单独判断）
        default        -> "Unknown";
    };
}
```

**switch 模式匹配的强大之处——结合 Record Pattern**：

```java
sealed interface Vehicle permits Car, Bike, Truck {}
record Car(String brand, int doors) implements Vehicle {}
record Bike(String brand, boolean hasBasket) implements Vehicle {}
record Truck(String brand, int loadCapacity) implements Vehicle {}

String describe(Vehicle v) {
    return switch (v) {
        case Car(String brand, int doors) -> brand + " car with " + doors + " doors";
        case Bike(String brand, boolean hasBasket) ->
            brand + " bike" + (hasBasket ? " with basket" : "");
        case Truck(String brand, int load) ->
            brand + " truck, capacity: " + load + "kg";
    };
}
```

**Guarded Patterns（带条件的模式匹配）**：

```java
String classifyNumber(Object obj) {
    return switch (obj) {
        case Integer i when i > 0 -> "Positive integer: " + i;
        case Integer i when i < 0 -> "Negative integer: " + i;
        case Integer i            -> "Zero";
        case null                 -> "null";
        default                   -> "Not an integer";
    };
}
```

## 五、有序集合（Sequenced Collections）

Java 21 引入了 `SequencedCollection`、`SequencedSet`、`SequencedMap` 三个新接口，为有序集合提供了统一的操作 API。

### 5.1 SequencedCollection

```java
// 新的接口层次：Collection -> SequencedCollection -> List/Deque

List<String> list = List.of("a", "b", "c");

// 新增方法
String first = list.getFirst();   // "a"（代替 list.get(0)）
String last  = list.getLast();    // "c"（代替 list.get(list.size()-1)）

// 逆序视图（反向迭代器）
SequencedCollection<String> reversed = list.reversed();
// reversed: ["c", "b", "a"]

// 可变的 SequencedCollection 还支持 addFirst/addLast
ArrayList<String> mutableList = new ArrayList<>(List.of("a", "b", "c"));
mutableList.addFirst("z");  // [z, a, b, c]
mutableList.addLast("x");   // [z, a, b, c, x]
```

### 5.2 SequencedMap

```java
SequencedMap<String, Integer> map = new LinkedHashMap<>();
map.put("one", 1);
map.put("two", 2);
map.put("three", 3);

// 访问首尾条目
Map.Entry<String, Integer> first = map.firstEntry();  // "one"=1
Map.Entry<String, Integer> last  = map.lastEntry();   // "three"=3

// 逆序视图
SequencedMap<String, Integer> reversed = map.reversed();
// reversed: {"three"=3, "two"=2, "one"=1}

// 首尾操作
map.putFirst("zero", 0);   // {"zero"=0, "one"=1, "two"=2, "three"=3}
map.putLast("four", 4);    // {"zero"=0, "one"=1, "two"=2, "three"=3, "four"=4}

// 获取正序/逆序的 key 集合
SequencedSet<String> keys = map.sequencedKeySet();
```

### 5.3 统一 API 的好处

| 场景 | Java 17 写法 | Java 21 写法 |
|-----|-------------|-------------|
| 获取列表第一个元素 | list.get(0) | list.getFirst() |
| 获取列表最后一个元素 | list.get(list.size()-1) | list.getLast() |
| 列表第一个插入 | list.add(0, elem) | list.addFirst(elem) |
| 获取 Map 第一个条目 | 不支持（需遍历） | map.firstEntry() |
| 逆序迭代 List | Collections.reverse(list).forEach() | list.reversed().forEach() |
| LinkedHashSet 首元素 | set.iterator().next() | set.getFirst() |

## 六、分代 ZGC（Generational ZGC）

ZGC 在 Java 15 作为实验性特性引入，Java 21 的分代 ZGC 是其重要演进。分代 ZGC 引入老年代（Old Generation）和年轻代（Young Generation）的概念，提高了 GC 效率。

```java
// 启用分代 ZGC
// -XX:+UseZGC -XX:+ZGenerational

// 传统 ZGC 的配置
// -XX:+UseZGC -XX:-ZGenerational

// 查看 ZGC 日志
// -Xlog:gc* -Xlog:gc+stats*
```

**分代 ZGC 与传统 ZGC 对比**：

| 维度 | 非分代 ZGC | 分代 ZGC |
|-----|-----------|---------|
| 堆结构 | 单一区域 | 分年轻代 + 老年代 |
| 小型对象处理 | 全堆扫描 | 主要扫描年轻代 |
| CPU 开销 | 约 10-15% | 约 5-8% |
| 内存开销（额外） | 约 3% | 约 3% |
| 最大暂停时间 | < 1ms | < 1ms |
| 吞吐量 | 基准 | 提升 20-30% |
| 兼容性 | Java 15+ | Java 21+ |

## 七、String Templates（预览）

Java 21 的 String Templates 允许在字符串字面量中嵌入动态表达式，是预览特性，需要 `--enable-preview` 开启。

```java
// STR 模板处理器
String name = "Alice";
int age = 30;
String msg = STR."User: \{name}, Age: \{age}";
// => "User: Alice, Age: 30"

// 更复杂的表达式
String query = STR."""
    SELECT * FROM users
    WHERE name = '\{name}'
    AND age >= \{age}
    """;

// 自定义模板处理器
TemplateProcessor<String> SQL_ESCAPE = StringTemplate.Processor.of(
    st -> st.fragments().get(0) +
        st.values().stream()
            .map(v -> v.toString().replace("'", "''"))
            .collect(Collectors.joining("", "", st.fragments().get(st.fragments().size() - 1)))
);

String safeQuery = SQL_ESCAPE."SELECT * FROM users WHERE name = '\{name}'";
```

## 八、未命名变量和模式（预览）

Java 21 引入了 `_` 关键字作为未命名变量和模式的占位符，用于在不关心值的地方避免声明无用的变量名。

```java
// 未命名变量：try-with-resources 中
try (var _ = ctx.openResource()) {
    // 不关心资源引用
}

// 未命名变量：lambda 表达式
list.stream()
    .map(_ -> "ignored")
    .forEach(System.out::println);

// 未命名模式：switch 中使用
String describe(Object obj) {
    return switch (obj) {
        case Integer _ -> "int";  // 不关心具体值
        case String _  -> "str";  // 不关心具体值
        default        -> "other";
    };
}

// catch 块中忽略异常
try {
    // ...
} catch (Exception _) {  // 不关心异常详情
    System.out.println("Operation failed");
}

// 赋值时忽略返回值
var _ = map.put("key", "value");  // 不关心旧值
```

**需要注意**：`_` 作为未命名变量是预览特性，且不能与 Java 9 弃用的 `_` 标识符兼容。如果代码中使用了 `_` 作为普通变量名，升级时需要先迁移。

## Java 17 与 Java 21 特性对照表

| 特性 | Java 17 LTS | Java 21 LTS |
|-----|------------|------------|
| 虚拟线程 | ❌ | ✅ 正式版 |
| 结构化并发 | ❌ | ✅ 预览 |
| Scoped Values | ❌ | ✅ 预览 |
| Record | ✅ 正式版 | ✅ 正式版 + Record Patterns |
| 模式匹配 switch | ✅ 预览 | ✅ 正式版 |
| 密封类 | ✅ 正式版 | ✅ 正式版 |
| 文本块 | ✅ 正式版 | ✅ 正式版 + String Templates(预览) |
| 有序集合 API | ❌ | ✅ 新接口 |
| 分代 ZGC | ❌ | ✅ |
| 未命名变量/模式 | ❌ | ✅ 预览 |
| 矢量 API | ❌ | ✅ 第六次孵化 |
| 外部函数&内存 API | ❌ | ✅ 第三次预览 |

## 从 Java 17 迁移到 Java 21 的建议

1. **优先尝试虚拟线程**：改造 IO 密集型服务，使用 `Executors.newVirtualThreadPerTaskExecutor()` 替代传统线程池
2. **尝试结构化并发**：在需要编排多个并行任务的场景中，用 `StructuredTaskScope` 替代 `CompletableFuture`
3. **启用分代 ZGC**：如果当前使用 G1GC 且遇到延迟问题，分代 ZGC 是一个很好的选择
4. **渐进式使用新语法**：Record Patterns 和 Switch 模式匹配可以逐步替换传统的 if-else 链
5. **避免过早使用预览特性**：String Templates 和未命名变量需要 `--enable-preview`，生产环境建议先观望

Java 21 是继 Java 17 之后的又一个里程碑 LTS 版本。虚拟线程的正式发布将为 Java 生态在高并发 IO 密集型领域注入新的活力，而结构化并发和 Scoped Values 则让并发编程更加安全可控。如果你正在规划 Java 版本的升级路线，建议直接瞄准 Java 21，跳过 18/19/20 等短期版本。
