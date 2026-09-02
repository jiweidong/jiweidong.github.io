---
title: 【Java 并发】守护线程与 JVM 优雅退出深度解析：从 Daemon 线程原理到 ShutdownHook 实战
date: 2026-09-02 08:00:00
tags:
  - Java
  - 并发
  - JVM
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【Java 并发】守护线程与 JVM 优雅退出深度解析：从 Daemon 线程原理到 ShutdownHook 实战

## 面试官：说说守护线程是什么？为什么 main 线程结束程序还没退出？ShutdownHook 有什么用？

守护线程（Daemon Thread）是 Java 并发里"不起眼但关键时刻要命"的知识点：平时没人注意，一旦线上出现"kill 进程数据没刷完""线程池不退出导致容器无法停机"，大家才想起它。今天把守护线程和 JVM 退出机制一次讲透。

---

## 一、什么是守护线程？

### 1.1 两类线程

| 类型 | 特点 | 典型例子 |
| --- | --- | --- |
| 用户线程（User Thread） | JVM 只要还有用户线程存活就不会退出 | main 线程、业务工作线程 |
| 守护线程（Daemon Thread） | 服务于用户线程，所有用户线程结束后 JVM 直接退出，守护线程被强制终止 | GC 线程、JIT 编译线程、监控/心跳线程 |

### 1.2 创建方式

```java
Thread t = new Thread(() -> {
    while (true) {
        // 心跳上报逻辑
        try { Thread.sleep(5000); } catch (InterruptedException ignored) {}
    }
});
t.setDaemon(true);   // 必须在 start() 之前设置
t.start();
```

```java
// 线程池方式：ThreadFactory 里设置
ExecutorService pool = Executors.newFixedThreadPool(2, r -> {
    Thread t = new Thread(r);
    t.setDaemon(true);
    return t;
});
```

> 注意：**setDaemon(true) 必须在 start() 之前调用**，否则抛 IllegalThreadStateException。线程池默认创建的是**非守护线程**，这也是为什么很多后台线程池应用"关不掉"。

### 1.3 守护线程的继承规则

**新线程的 daemon 状态继承自创建它的线程**：

```java
public class DaemonInheritDemo {
    public static void main(String[] args) {
        Thread t = new Thread(() -> {
            // 在守护线程里创建子线程
            Thread child = new Thread(() -> System.out.println("child isDaemon="
                    + Thread.currentThread().isDaemon()));
            child.start();
        });
        t.setDaemon(true);
        t.start();
        // 输出: child isDaemon=true（继承自守护线程）
    }
}
```

**注意坑**：如果在 main 里创建线程池，池内线程默认继承 main（非守护），即使你希望它是后台线程也必须显式设置。

---

## 二、JVM 退出机制：为什么程序"退不出去"？

### 2.1 JVM 退出的三种方式

1. **正常退出**：main 方法返回，且没有其他非守护线程存活
2. **System.exit()**：显式调用（会触发 ShutdownHook）
3. **异常退出**：未捕获异常、`Runtime.halt()`、OOM、外部 kill -9

### 2.2 关键规则（面试必答）

> **JVM 退出条件：所有非守护线程都执行完毕。** 只要有任何一个用户线程存活，JVM 就不会退出；守护线程的存在与否不影响退出判断。

```java
public class JvmExitDemo {
    public static void main(String[] args) {
        Thread daemon = new Thread(() -> {
            while (true) { /* 死循环 */ }
        });
        daemon.setDaemon(true);
        daemon.start();          // 守护线程：不影响退出

        Thread user = new Thread(() -> {
            try { Thread.sleep(10_000); } catch (InterruptedException ignored) {}
            System.out.println("user thread done");
        });
        user.start();            // 用户线程：JVM 要等它 10 秒

        System.out.println("main done");
        // main 返回后 JVM 并不退出，要等 user 线程跑完
    }
}
```

### 2.3 守护线程被"强制终止"意味着什么？

所有用户线程结束后，JVM 直接 halt，守护线程**不会收到任何通知**，处于 running 状态被硬杀：

- **finally 块不一定会执行**（不保证执行）
- **资源不保证释放**：文件句柄、socket、DB 连接可能没关
- 所以：**守护线程里不要放必须落盘/必须提交的业务逻辑**

```java
Thread daemon = new Thread(() -> {
    try {
        // 业务
    } finally {
        // 不可靠！JVM 退出时可能根本不执行到这里
        flushToDisk();
    }
});
daemon.setDaemon(true);
```

---

## 三、ShutdownHook：JVM 退出时的"最后补救"

### 3.1 是什么

`Runtime.addShutdownHook(Thread hook)` 注册一个钩子线程，**在 JVM 开始关闭流程时执行**（正常退出或收到 SIGTERM 时），用于清理资源、优雅停机。

### 3.2 触发场景

| 场景 | 是否触发 ShutdownHook |
| --- | --- |
| main 正常返回 | ✅ |
| System.exit() | ✅ |
| Ctrl+C（SIGINT） | ✅ |
| kill <pid>（SIGTERM） | ✅ |
| kill -9（SIGKILL） | ❌ 无法捕获 |
| 系统断电/宕机 | ❌ |

```java
public class ShutdownHookDemo {
    public static void main(String[] args) {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("开始优雅停机...");
            // 关闭线程池、刷盘、释放连接、通知注册中心下线
            ExecutorService pool = AppContext.getPool();
            pool.shutdown();
            try {
                pool.awaitTermination(10, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            System.out.println("资源清理完成");
        }));

        // 业务代码...
        System.out.println("业务运行中，等待退出信号");
    }
}
```

### 3.3 执行顺序与注意点

- **多个 Hook 并发执行**，无序，且都受 `-XX:+ShutdownHookTimeout` 类超时控制
- **Hook 执行期间**，JVM 仍在关闭流程中，禁止继续 new 线程/发起 IO 可能不生效
- **Hook 里不能再调用 System.exit()**，会卡死关闭流程（源码里会锁死）

### 3.4 典型实战：注册中心优雅下线

```java
Runtime.getRuntime().addShutdownHook(new Thread(() -> {
    // 1. 向 Nacos/Consul 注销服务，让流量先摘掉
    registry.deregister(serviceName, ip, port);
    // 2. 等待存量请求处理完
    gracefulShutdown(30, TimeUnit.SECONDS);
    // 3. 关闭连接池等
    dataSource.close();
}));
```

先摘流量 → 再等存量请求 → 最后释放资源，这就是 K8s/云原生下 Pod 优雅退出的 Java 侧实现。

---

## 四、Spring Boot 中的优雅停机（面试加分）

Spring Boot 2.3+ 内置优雅停机：

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
```

收到 SIGTERM 后：

1. 停止接收新请求
2. 等待处理中的请求完成（最多 30 秒）
3. 触发 Spring 的 `@PreDestroy` / `DisposableBean` 清理
4. JVM 退出

**底层就是 ShutdownHook + 容器生命周期管理**。面试时可以串起来讲：kill -9 无法触发 → 生产必须用 SIGTERM（`kill <pid>`），配合 K8s preStop 等待优雅退出完成。

---

## 五、守护线程的典型应用场景

| 场景 | 说明 |
| --- | --- |
| JVM 内置 GC / JIT 线程 | 都是守护线程，JVM 退出时无需等待 |
| 心跳/健康检查线程 | 应用级心跳上报，随应用退出而结束 |
| 监控统计线程 | 定时采集指标，不影响主流程退出 |
| 本地缓存定时刷新 | 缓存刷新线程设为守护，避免阻塞停机 |

```java
// 生产案例：JVM 指标采集守护线程
public class MetricsCollector {
    private final ScheduledExecutorService scheduler =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "metrics-collector");
                t.setDaemon(true);          // 守护：不阻碍应用退出
                return t;
            });

    public void start() {
        scheduler.scheduleAtFixedRate(this::collect, 0, 10, TimeUnit.SECONDS);
    }
}
```

---

## 六、面试高频追问

**Q1：守护线程和用户线程的本质区别是什么？**
不是优先级、不是执行内容，而是**对 JVM 退出判断的影响**：守护线程不阻止 JVM 退出，用户线程会。

**Q2：守护线程里 finally 一定会执行吗？**
不保证。用户线程全部结束后 JVM 直接 halt 守护线程，finally 可能来不及执行。守护线程内不要放"必须完成"的逻辑。

**Q3：线程池的线程是守护线程吗？**
默认不是。Executors 创建的线程池默认非守护，即使 main 结束，池内线程还活着 JVM 就不会退出——这正是很多后台程序"kill 不掉"的原因。需要时通过 ThreadFactory 设置。

**Q4：kill -9 能触发 ShutdownHook 吗？**
不能。SIGKILL 无法被捕获，只有 SIGTERM（kill 默认）、SIGINT（Ctrl+C）能触发。生产环境优雅停机必须用 SIGTERM。

**Q5：ShutdownHook 执行超时了会怎样？**
JVM 会等 Hook 执行完再退出；若 Hook 死循环或阻塞，进程会一直不退。所以 Hook 里要做超时控制（awaitTermination 带超时），并保持逻辑简单。

---

## 总结

- **守护线程**：服务于用户线程，JVM 退出时被强制终止，`setDaemon(true)` 须在 start 前调用
- **退出规则**：所有非守护线程结束，JVM 才退出——这是"程序退不掉"的根本原因
- **ShutdownHook**：SIGTERM/System.exit 时的清理钩子，用于优雅停机、摘流量、刷资源
- **生产实践**：守护线程管后台任务，用户线程管业务，kill 用 SIGTERM 不用 -9
- **一句话心法**：把"必须做完的事"交给用户线程或 ShutdownHook，把"可随时丢弃的活"交给守护线程
