---
title: 【Java 21+】Scoped Values（作用域值）深度解析：虚拟线程时代的线程局部变量替代方案
date: 2026-07-10 08:00:20
tags:
  - Java
  - 并发
  - 虚拟线程
  - Scoped Values
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java 21+】Scoped Values（作用域值）深度解析：虚拟线程时代的线程局部变量替代方案

## 引言

在 Java 并发编程中，`ThreadLocal` 一直是传递"隐式上下文"的标准方案——从 Web 请求的 traceId 到事务管理的 connection，ThreadLocal 无处不在。

然而，虚拟线程时代的到来暴露了 ThreadLocal 的几个严重缺陷：

1. **内存泄漏风险**：虚拟线程数量可达百万级，每个 ThreadLocal 值都会常驻内存
2. **不可变性缺失**：任何代码都能修改 ThreadLocal 中的值，导致上下文漂移
3. **继承性混乱**：InheritableThreadLocal 在线程池场景下行为不可预测

JDK 21 以预览特性引入了 **Scoped Values（作用域值，JEP 429）**，并在 JDK 22+ 持续优化。这是 Java 为了解决上述问题给出的官方方案。

---

## 一、ThreadLocal 的困境

### 1.1 ThreadLocal 的典型用法

```java
public class RequestContext {
    private static final ThreadLocal<String> traceId =
        ThreadLocal.withInitial(() -> UUID.randomUUID().toString());
    private static final ThreadLocal<Long> userId =
        new ThreadLocal<>();

    public static String getTraceId() {
        return traceId.get();
    }

    public static void setUserId(Long uid) {
        userId.set(uid);
    }

    public static Long getUserId() {
        return userId.get();
    }

    public static void clear() {
        traceId.remove();
        userId.remove();
    }
}

// 使用场景：过滤器
@WebFilter("/*")
public class TraceFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request,
            ServletResponse response, FilterChain chain) {
        try {
            RequestContext.setUserId(extractUserId(request));
            chain.doFilter(request, response);
        } finally {
            RequestContext.clear(); // 容易忘记调用
        }
    }
}
```

### 1.2 ThreadLocal 的三大问题

**问题一：内存泄漏**

```java
// 在线程池场景中，ThreadLocal 值不会自动回收
ExecutorService pool = Executors.newFixedThreadPool(10);
for (int i = 0; i < 1000; i++) {
    pool.submit(() -> {
        // 写入 ThreadLocal 但忘记 remove()
        RequestContext.setUserId(userId);
        doWork();
        // 线程池线程复用，ThreadLocal 值一直保留
        // 如果 userId 对象很大，大量线程积累造成 OOM
    });
}
```

**问题二：任何代码都能修改（上下文漂移）**

```java
// 在任意地方都可以修改 ThreadLocal
public void processRequest(Request request) {
    RequestContext.setUserId(request.getUserId());

    // 调用第三方库
    someLibrary.doSomething(); // 这个库内部修改了 ThreadLocal！
    // 此处 RequestContext.getUserId() 可能已经变了
    // 这就是上下文漂移

    doNextStep(); // 使用的 userId 不可靠
}
```

**问题三：虚拟线程不可扩展**

```java
// 在虚拟线程中，ThreadLocal 会复制到每个虚拟线程
// 百万虚拟线程 → 每个线程持有 ThreadLocal 的副本
// 大量内存被 ThreadLocal 占用

try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    for (int i = 0; i < 1_000_000; i++) {
        executor.submit(() -> {
            // 每个虚拟线程创建一个 ThreadLocal 副本
            RequestContext.setUserId(userId);
            doWork();
            // 如果不 remove，1_000_000 个 ThreadLocal 实例
        });
    }
}
```

---

## 二、Scoped Values 基础概念

### 2.1 什么是 Scoped Values？

Scoped Values 是一种**不可变、线程安全、有明确作用域**的上下文值传递机制。它的核心思想是：

- **值一旦绑定，不可修改**（immutable）
- **值在 try-with-resources 块内有效**
- **作用域退出时，值自动恢复或清除**

### 2.2 基本用法

```java
// 1. 定义 ScopedValue（类似 ThreadLocal 的声明）
public class AppContext {
    public static final ScopedValue<String> TRACE_ID =
        ScopedValue.newInstance();
    public static final ScopedValue<Long> USER_ID =
        ScopedValue.newInstance();
}

// 2. 绑定值（在作用域范围内有效）
public class TraceFilter {
    public void doFilter(Request request, Response response) {
        String traceId = generateTraceId();
        Long userId = extractUserId(request);

        // ScopedValue.where() 返回一个 Carrier
        // Carrier.where() 可以链式绑定多个值
        ScopedValue
            .where(AppContext.TRACE_ID, traceId)
            .where(AppContext.USER_ID, userId)
            .run(() -> {
                // 在此作用域内可以读取 TRACE_ID 和 USER_ID
                handleRequest(request, response);
            });
        // 作用域结束，值自动恢复（外部看不到这个 traceId）
    }

    private void handleRequest(Request req, Response res) {
        // 读取 ScopedValue（永不返回 null）
        String traceId = AppContext.TRACE_ID.get();
        Long userId = AppContext.USER_ID.get();
        log.info("Handling request: traceId={}, userId={}", traceId, userId);

        service.process(req); // 内部同样可以读取
    }
}
```

### 2.3 ScopedValue API 详解

```java
public final class ScopedValue<T> {
    // 创建新的 ScopedValue 实例
    static <T> ScopedValue<T> newInstance();

    // 获取当前线程绑定的值
    // 如果未绑定，抛出 NoSuchElementException
    T get();

    // 判断当前线程是否绑定了值
    boolean isBound();

    // 绑定单个值并执行
    static <T, R, X extends Throwable>
    R where(ScopedValue<T> key, T value,
            Callable<? extends R> operation) throws X;

    // Carrier 类用于绑定多个值
    final class Carrier {
        <T> Carrier where(ScopedValue<T> key, T value);
        void run(Runnable op);
        <R, X extends Throwable> R call(Callable<R> op) throws X;
    }
}
```

---

## 三、深入原理

### 3.1 不可变性保证

ScopedValue 绑定后**不能被修改**：

```java
ScopedValue<String> SV = ScopedValue.newInstance();

ScopedValue.where(SV, "initial").run(() -> {
    String val = SV.get(); // "initial"

    // ❌ 无法修改：没有 set() 方法！
    // SV.set("new value"); // 编译错误

    // ✅ 可以通过嵌套创建新的作用域
    ScopedValue.where(SV, "overridden").run(() -> {
        String inner = SV.get(); // "overridden"
    });

    // 嵌套返回后，值自动恢复为 "initial"
    String restored = SV.get(); // "initial"
});
```

### 3.2 作用域嵌套与值继承

```java
public class ScopedNestingExample {
    private static final ScopedValue<String> USER_ROLE =
        ScopedValue.newInstance();
    private static final ScopedValue<String> REQUEST_ID =
        ScopedValue.newInstance();

    public void processApiRequest() {
        ScopedValue
            .where(REQUEST_ID, "req-001")
            .where(USER_ROLE, "admin")
            .run(() -> {
                // 外层作用域：REQUEST_ID=req-001, USER_ROLE=admin
                String role = USER_ROLE.get();    // "admin"
                String reqId = REQUEST_ID.get();  // "req-001"

                // 内层覆盖 USER_ROLE
                ScopedValue.where(USER_ROLE, "viewer").run(() -> {
                    String innerRole = USER_ROLE.get();   // "viewer"
                    String innerReqId = REQUEST_ID.get(); // "req-001" (继承)
                });

                // 退出内层后，USER_ROLE 恢复为 "admin"
                String restoredRole = USER_ROLE.get(); // "admin"
            });
    }
}
```

**嵌套规则：**
- 内层作用域**继承**外层绑定的值
- 内层可以**覆盖**某个值的绑定（覆盖只在当前作用域有效）
- 退出内层作用域时，值**自动恢复**为外层值
- 内部不能**改变**外层的值（因为没有 set 方法）

---

## 四、虚拟线程中的 Scoped Values

### 4.1 Scoped Values 天然支持虚拟线程

这是 Scoped Values 相比 ThreadLocal 最大的优势：

```java
// 虚拟线程 + Scoped Values
public class VirtualThreadExample {
    private static final ScopedValue<String> REQUEST_ID =
        ScopedValue.newInstance();
    private static final ScopedValue<String> TENANT_ID =
        ScopedValue.newInstance();

    public void handleRequests(List<Request> requests) {
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            for (Request request : requests) {
                String requestId = UUID.randomUUID().toString();
                String tenantId = request.getTenant();

                executor.submit(() ->
                    // ScopedValue 会自动绑定到虚拟线程
                    ScopedValue
                        .where(REQUEST_ID, requestId)
                        .where(TENANT_ID, tenantId)
                        .run(() -> processRequest(request))
                );
            }
        }
    }

    private void processRequest(Request request) {
        // 读取值
        String reqId = REQUEST_ID.get();
        String tenant = TENANT_ID.get();

        // 调用其他方法时自动传递
        service.callExternalApi(reqId, tenant);
    }
}
```

### 4.2 与 ThreadLocal 的虚拟线程对比

```java
// ThreadLocal 在虚拟线程中的问题
private static final ThreadLocal<String> TL_TRACE_ID = new ThreadLocal<>();

// 每个虚拟线程都会持有 ThreadLocal 的副本
// 100 万虚拟线程 = 100 万个 TraceId 值的引用
// GC 无法回收，因为载体线程持有强引用

// ScopedValues 在虚拟线程中的优势
private static final ScopedValue<String> SV_TRACE_ID =
    ScopedValue.newInstance();

// ScopedValue 由 JVM 内部管理，不占用虚拟线程的用户栈
// 值存储在载体线程的栈帧中，作用域结束自动清除
```

**内存占用对比：**

| 指标 | ThreadLocal | ScopedValue |
|------|-------------|-------------|
| 100 万虚拟线程 | ~64 MB 额外内存 | ~0（由 JVM 高效管理） |
| 值生命周期 | 直到 remove() 或线程结束 | 作用域结束立即回收 |
| GC 压力 | 高 | 低 |
| 载体线程堆积 | 内存泄漏风险 | 无泄漏风险 |

---

## 五、生产实战

### 5.1 替代 MDC（日志诊断上下文）

```java
// 传统：使用 SLF4J MDC（基于 ThreadLocal）
// MDC 在虚拟线程中存在同样的问题

// 方案：ScopedValue 封装日志上下文
public class LogContext {
    public static final ScopedValue<String> TRACE_ID =
        ScopedValue.newInstance();
    public static final ScopedValue<String> USER_ID =
        ScopedValue.newInstance();

    // 包装 MDC 适配器，在作用域启动/结束时同步
    public static <R> R withContext(
            String traceId, String userId,
            Callable<R> operation) throws Exception {
        return ScopedValue
            .where(TRACE_ID, traceId)
            .where(USER_ID, userId)
            .call(() -> {
                // 同步到 MDC（作为桥梁，逐步迁移）
                MDC.put("traceId", traceId);
                MDC.put("userId", userId);
                try {
                    return operation.call();
                } finally {
                    MDC.clear();
                }
            });
    }
}

// 使用方式
@WebFilter
public class LogContextFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request,
            ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        String traceId = UUID.randomUUID().toString().substring(0, 12);
        String userId = extractUserId(request);

        try {
            LogContext.withContext(traceId, userId, () -> {
                chain.doFilter(request, response);
                return null;
            });
        } catch (Exception e) {
            throw new ServletException(e);
        }
    }
}
```

### 5.2 多租户上下文

```java
public class TenantContext {
    public static final ScopedValue<String> TENANT_ID =
        ScopedValue.newInstance();
    public static final ScopedValue<DataSource> TENANT_DS =
        ScopedValue.newInstance();

    public static <R> R withTenant(
            String tenantId,
            Callable<R> operation) throws Exception {
        // 根据租户查找对应的数据源
        DataSource ds = DataSourceRouter.getDataSource(tenantId);
        return ScopedValue
            .where(TENANT_ID, tenantId)
            .where(TENANT_DS, ds)
            .call(operation);
    }
}

// 在数据访问层使用
@Repository
public class OrderRepository {
    @Autowired
    private DataSource defaultDataSource;

    public List<Order> findOrdersByUser(Long userId) {
        // 获取当前租户的数据源
        if (TenantContext.TENANT_DS.isBound()) {
            // 多租户模式
            return queryWithDS(TenantContext.TENANT_DS.get(), userId);
        }
        // 非多租户模式
        return queryWithDS(defaultDataSource, userId);
    }
}
```

### 5.3 事务传播场景

```java
// 使用 ScopedValue 替代 ThreadLocal 进行事务传播
public class TransactionContext {
    public static final ScopedValue<Transaction> CURRENT_TX =
        ScopedValue.newInstance();

    public static <R> R withTransaction(
            TransactionManager tm,
            Callable<R> operation) throws Exception {
        Transaction tx = tm.begin();
        try {
            return ScopedValue
                .where(CURRENT_TX, tx)
                .call(operation);
        } catch (Exception e) {
            tx.rollback();
            throw e;
        }
        // tx.commit() 或 tx.rollback()
        // 作用域结束，事务引用自动释放
    }
}

// 嵌套事务传播
@Transactional
public void outerMethod() {
    // 开启一个事务作用域
    TransactionContext.withTransaction(tm, () -> {
        dao.save(entity1);

        // 内层方法调用，传播当前事务
        innerMethod(); // 自动继承 CURRENT_TX

        return null;
    });
}

private void innerMethod() {
    // 自动获取到外层的事务
    Transaction tx = TransactionContext.CURRENT_TX.get();
    dao.save(entity2, tx); // 共享同一个事务
}
```

---

## 六、ScopedValues vs ThreadLocal 全面对比

| 特性 | ThreadLocal | ScopedValue |
|------|-------------|-------------|
| **可修改性** | ✅ 可读写（set/get） | ❌ 只读（get only） |
| **生命周期** | 直到 remove() 或线程结束 | try-with-resources 作用域 |
| **虚拟线程支持** | ❌ 内存占用大 | ✅ 轻量级 |
| **内存泄漏风险** | ❌ 高 | ✅ 无 |
| **继承性** | InheritableThreadLocal（问题多） | ✅ 嵌套自动继承/覆盖 |
| **上下文漂移** | ❌ 容易被第三方库修改 | ✅ 不可变，不能被修改 |
| **性能** | 好（但是软引用维护复杂） | 更好（JVM 内建支持） |
| **是否可替换 MDC** | ✅ 目前主流 | ⚠️ 需要适配层 |
| **JDK 版本** | 1.2+ | 21+（预览），24+（持续优化） |

---

## 七、从 ThreadLocal 迁移到 ScopedValues

### 7.1 迁移步骤

```java
// 第1步：定义 ScopedValue 常量
// ThreadLocal 版本
public class OldContext {
    private static final ThreadLocal<String> USER_ID =
        new ThreadLocal<>();
    public static void setUserId(String uid) { USER_ID.set(uid); }
    public static String getUserId() { return USER_ID.get(); }
    public static void clear() { USER_ID.remove(); }
}

// ScopedValue 版本
public class NewContext {
    public static final ScopedValue<String> USER_ID =
        ScopedValue.newInstance();
    // 注意：没有 set/clear 方法，只有 get
}

// 第2步：修改调用方
// 旧的调用方式
OldContext.setUserId(userId);
try {
    doWork();
} finally {
    OldContext.clear();
}

// 新的调用方式
ScopedValue.where(NewContext.USER_ID, userId).run(() -> {
    doWork();
});

// 第3步：内部读取方式改变
// OldContext.getUserId() → NewContext.USER_ID.get()
```

### 7.2 兼容过渡方案

对于大型项目，可以同时支持两种方式，逐步迁移：

```java
public class HybridContext {
    private static final ThreadLocal<String> TL_USER_ID =
        new ThreadLocal<>();
    public static final ScopedValue<String> SV_USER_ID =
        ScopedValue.newInstance();

    // 兼容旧代码
    public static String getUserId() {
        if (SV_USER_ID.isBound()) {
            return SV_USER_ID.get(); // 优先使用 ScopedValue
        }
        return TL_USER_ID.get(); // 回退到 ThreadLocal
    }

    // 旧的 set/clear 保留...
    public static void setUserId(String uid) { TL_USER_ID.set(uid); }
    public static void clear() { TL_USER_ID.remove(); }
}
```

---

## 八、常见问题

**Q：ScopedValue.get() 做了什么？**
A：它会沿着调用栈向上查找最近的绑定。如果 `where(x, v)` 在当前调用栈上绑定了该 ScopedValue，返回对应的 v；如果没有绑定，抛出 `NoSuchElementException`。

**Q：ScopedValue 和 ThreadLocal 哪个性能更好？**
A：在虚拟线程场景下，ScopedValue 明显更好（不占用线程本地存储）。在平台线程中，两者性能接近，ScopedValue 可能略胜一筹，因为不需要维护 ThreadLocalMap 的 Entry 引用链。

**Q：什么场景下不适合 ScopedValues？**
A：需要频繁修改上下文值的场景（如计数器、循环变量）不适合 ScopedValue。这种场景建议使用方法参数显式传递。

**Q：ScopedValues 是否完全替代 ThreadLocal？**
A：对于"一次性绑定、作用域内读取"的场景（traceId、userId、租户信息），ScopedValues 是更好的选择。对于"可变上下文、累加器"等场景，ThreadLocal 仍然适用。

---

## 总结

Scoped Values 是 Java 为虚拟线程时代准备的隐式上下文传递方案。它以**不可变性、作用域化、自动清理**为核心设计，解决了 ThreadLocal 长期以来的内存泄漏、上下文漂移和虚拟线程兼容性问题。

下次当你需要为请求传递隐式上下文时，不要再条件反射地使用 ThreadLocal 了——试试 Scoped Values，你的代码会因此更安全、更清晰。
