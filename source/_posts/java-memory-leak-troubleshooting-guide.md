---
title: 【生产实战】Java 应用内存泄漏排查全攻略：从堆内泄漏到 Native Memory 泄漏
date: 2026-07-29 08:00:00
tags:
  - Java
  - JVM
  - 性能调优
  - 生产实战
categories:
  - Java
  - JVM 调优
author: 东哥
---

# 【生产实战】Java 应用内存泄漏排查全攻略：从堆内泄漏到 Native Memory 泄漏

## 前言

内存泄漏是 Java 应用最棘手的生产问题之一。与传统的 C/C++ 不同，Java 有 GC 自动管理内存，但这并不意味着不会泄漏。实际上，Java 内存泄漏的形式更多样、更隐蔽。

典型的症状：**内存占用缓慢上升 → Full GC 频繁 → 最终 OOM 或性能急剧下降**。

本文系统梳理各种内存泄漏场景、排查工具链与实战案例。

## 一、内存泄漏的分类

| 类型 | 描述 | 典型场景 |
|------|------|---------|
| **堆内泄漏** | 对象无法被 GC 回收 | 集合类无界增长、缓存未设上限 |
| **堆外泄漏** | DirectBuffer/Unsafe 未释放 | Netty 缓冲区、NIO 操作 |
| **Native Memory 泄漏** | JVM 本地内存膨胀 | ClassLoader 泄漏、线程泄漏、JNI 泄漏 |
| **MetaSpace 泄漏** | 方法区持续增长 | 动态类加载、CGLIB 代理类累积 |

## 二、堆内泄漏排查

### 2.1 典型案例：ThreadLocal 内存泄漏

这是最常见的堆内泄漏场景。

```java
public class ThreadLocalLeakService {
    private static final ThreadLocal<byte[]> TL = new ThreadLocal<>();

    public void process() {
        TL.set(new byte[10 * 1024 * 1024]); // 10MB
        // 没有调用 TL.remove()！
    }
}
```

**原理**：ThreadLocal 的 key 是弱引用，value 是强引用。线程池中的线程存活时间长，value 在线程存活期间永远不会被回收。

**排查方法**：用 MAT 查看 `ThreadLocalMap` 中是否有大量无用的 entry。

### 2.2 典型案例：静态集合无界增长

```java
@Component
public class CacheLeakService {
    // 静态 Map 不断增长，没有上限
    private static final Map<String, Order> ORDER_CACHE = new HashMap<>();

    public Order queryOrder(String orderId) {
        Order order = queryFromDB(orderId);
        ORDER_CACHE.put(orderId, order);  // 永不过期！
        return order;
    }
}
```

**修复**：使用 `Guava Cache` + 过期策略，或 `Caffeine` 配置最大容量。

### 2.3 典型案例：未取消的监听器/回调

```java
@Component
public class EventRegister {
    private final List<Listener> listeners = new CopyOnWriteArrayList<>();

    public void register(Listener listener) {
        listeners.add(listener);
    }
    // 没有提供 unregister 方法！
}
```

短期对象注册了监听器后销毁，但监听器列表仍然持有引用，导致短期对象无法被回收。

### 2.4 排查步骤

```
1. 发现症状：内存持续增长，GC 无法回收
     ↓
2. jmap -heap ${PID} 查看堆概况
     ↓
3. jmap -histo:live ${PID} 查看存活对象统计
     ↓
4. 定位 suspect：某种对象数量异常大
     ↓
5. jmap -dump:live,format=b,file=heap.hprof ${PID}  导出堆转储
     ↓
6. MAT / JProfiler 分析 GC Root 路径
```

**MAT 分析技巧**：
- **Leak Suspects Report**：自动给出嫌疑对象
- **Dominator Tree**：找最大的存活对象
- **Path to GC Roots**：看对象为什么存活
- **OQL 查询**：使用 `SELECT * FROM com.example.SomeClass` 筛选

## 三、堆外内存泄漏

### 3.1 DirectBuffer 泄漏

NIO 操作使用 `DirectByteBuffer` 分配堆外内存：

```java
// 未释放的场景
ByteBuffer buffer = ByteBuffer.allocateDirect(1024 * 1024 * 1024);
// 没有调用 ((DirectBuffer) buffer).cleaner().clean();
```

DirectBuffer 的回收依赖 `Cleaner` 机制，`Cleaner` 是 PhantomReference，在 GC 时由 `ReferenceHandler` 线程处理。如果 DirectBuffer 对象本身无法被 GC 回收（有引用），那堆外内存也永远不会释放。

**监控命令**：

```bash
# 查看堆外内存使用
jcmd ${PID} VM.native_memory

# 或通过 JMX
# java.nio.BufferPoolMXBean 中的 direct 指标
```

### 3.2 Netty 常见泄漏

Netty 使用池化的堆外内存（PooledByteBufAllocator），如果 ByteBuf 未释放：

```java
// 错误用法
ByteBuf buf = ctx.alloc().buffer(1024);
// 没有调用 buf.release()！
```

Netty 内置了检测机制：启动参数 `-Dio.netty.leakDetectionLevel=paranoid`，会在日志中输出泄漏点。

### 3.3 排查工具

```bash
# 启用 Native Memory Tracking
-XX:NativeMemoryTracking=detail

# 查看 NMT 差异（建议在稳定运行一段时间后快照对比）
jcmd ${PID} VM.native_memory baseline
# 运行一段时间后
jcmd ${PID} VM.native_memory summary.diff

# 查看 DirectBuffer 统计
jcmd ${PID} VM.native_memory summary | grep -i "Internal\|Direct"
```

**NMT 输出解读**：
```
Native Memory Tracking:

Total: reserved=10GB, committed=5GB
-                 Java Heap (reserved=2GB, committed=2GB)
                            (mmap: reserved=2GB, committed=2GB) 
-                     Class (reserved=1GB, committed=200MB)
                            (classes #9876)
-                    Thread (reserved=500MB, committed=500MB)
                            (thread #381)
-                      Code (reserved=250MB, committed=80MB)
-                        GC (reserved=200MB, committed=200MB)
-                  Compiler (reserved=20MB, committed=20MB)
-                  Internal (reserved=1.5GB, committed=1.2GB)  ← 可疑！
-                     Other (reserved=500MB, committed=200MB)
```

如果 Internal 或 Other 持续增长，说明有堆外内存泄漏。

## 四、MetaSpace 泄漏

### 4.1 典型场景：CGLIB 动态代理类堆积

```java
// 循环中不断创建新的代理类
for (int i = 0; i < 100000; i++) {
    Enhancer enhancer = new Enhancer();
    enhancer.setSuperclass(MyService.class);
    enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) -> {
        return proxy.invokeSuper(obj, args);
    });
    MyService proxy = (MyService) enhancer.create();  // 生成新类
    proxies.add(proxy);
}
```

**危害**：每个 Enhancer.create() 都会生成一个新的 Class 加载到 MetaSpace，即使代理对象被回收，Class 元数据也不会被卸载（除非自定义 ClassLoader 也被回收）。

**排查**：

```bash
# 查看加载的类数量
jcmd ${PID} VM.metaspace

# 查看动态生成的类
jcmd ${PID} GC.class_stats
```

### 4.2 ClassLoader 泄漏

这是最隐蔽的泄漏之一。常见于应用热部署场景：

```java
// Tomcat 热部署时，WebappClassLoader 被替换
// 但如果某个线程／静态变量持有旧 ClassLoader 中的对象引用
// → 整个 WebappClassLoader 都不会被卸载
// → 该 ClassLoader 加载的所有类都不会卸载
// → MetaSpace 不断膨胀
```

**排查工具**：

```bash
# 查看存活 ClassLoader
jcmd ${PID} VM.classloader_stats

# 使用 MAT 查看类加载器引用链
# 搜索 "ClassLoader" 实例，检查 Path to GC Roots
```

## 五、实战排查工具链

### 5.1 命令行快速诊断

```bash
# 1. 查看进程状态
top -H -p ${PID}                    # CPU 和内存

# 2. JVM 概览
jstat -gcutil ${PID} 5000 10       # GC 情况（隔 5 秒采集 10 次）
jstat -gccapacity ${PID} 5000 10   # 各代容量

# 3. 线程状态
jstack ${PID} > thread.dump        # 线程栈

# 4. 堆信息
jmap -heap ${PID}                   # 堆配置和使用概况
jmap -histo:live ${PID}             # 存活对象统计（会触发 Full GC）

# 5. 完整堆转储
jmap -dump:live,format=b,file=dump.hprof ${PID}
```

### 5.2 持续监控方案

对于生产环境，推荐使用：

```bash
# 启动参数配置
-XX:+HeapDumpOnOutOfMemoryError          # OOM 时自动 dump
-XX:HeapDumpPath=/var/dumps/             # dump 存放路径
-XX:+PrintGCDetails                      # GC 日志
-XX:+PrintGCDateStamps
-Xloggc:/var/logs/gc.log
-XX:NativeMemoryTracking=detail          # NMT 监控
-XX:+ExitOnOutOfMemoryError              # OOM 时自动退出（避免服务假死）
```

生产环境建议配合 **Prometheus + Grafana** 监控 JVM 指标：

```java
// Spring Boot Actuator + Micrometer 自动暴露 JVM 指标
// jvm_memory_used_bytes
// jvm_gc_pause_seconds
// jvm_classes_loaded_classes
```

### 5.3 在线排查工具

| 工具 | 用途 | 优点 |
|------|------|------|
| **Arthas** | 在线诊断 | 无需 restart，动态追踪 |
| **async-profiler** | CPU/内存采样 | 低开销，支持火焰图 |
| **JMC (Java Mission Control)** | JDK 内置 | 包含 JFR 飞行记录 |
| **MAT** | 堆转储分析 | 功能最全的离线分析 |

**Arthas 排查示例**：

```bash
# 查看前 N 个最大对象
arthas> dashboard

# 查看类的实例数
arthas> vmtool --action countInstances --className java.util.HashMap

# 追踪某个方法的调用
arthas> trace com.example.UserService queryUser

# 查看对象引用路径
arthas> vmtool --action getInstances --className com.example.OrderService --limit 10
```

## 六、内存泄漏排查决策树

```
内存持续增长？
    ↓
jstat -gcutil：看 GC 情况
    ↓
YGCT 正常，FGCT 持续升高 → 老年代泄漏
    ↓
jmap -histo:live → 找到数量异常的对象
    ↓
导出 heap dump → MAT 分析
    ↓
找到 GC Root 路径 → 定位泄漏点
```

**对比排查表**：

| 症状 | 可能原因 | 排查工具 |
|------|---------|---------|
| Heap 占用持续上升 | 静态集合泄漏、ThreadLocal | MAT heap dump |
| Full GC 频繁但 Heap 正常 | 堆外内存泄漏、Direct Buffer | NMT、pmap |
| MetaSpace 持续增长 | 动态类加载、ClassLoader 泄漏 | jcmd VM.metaspace |
| 进程 RSS 远大于 Xmx | 堆外内存、Native 内存泄漏 | NMT diff、pmap |
| GC 正常但 OOM | 直接内存泄漏 | NMT、Netty leak 检测 |

## 七、常见内存泄漏预防

### 7.1 代码层面的最佳实践

```java
// 1. ThreadLocal 用完必 remove
ThreadLocal<Object> tl = new ThreadLocal<>();
try {
    tl.set(data);
    doSomething();
} finally {
    tl.remove();  // 一定在 finally 中清理
}

// 2. 集合设置上限
LoadingCache<String, Order> cache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(30, TimeUnit.MINUTES)
    .build(this::loadOrder);

// 3. 注册监听器后必须取消
@Component
public class SafeEventRegister {
    // 使用 WeakReference 避免泄漏
    private final List<WeakReference<Listener>> listeners = new CopyOnWriteArrayList<>();

    public void register(Listener listener) {
        listeners.add(new WeakReference<>(listener));
    }
}

// 4. Stream/IO 使用 try-with-resources
try (FileInputStream fis = new FileInputStream("test.txt")) {
    // 自动关闭
}

// 5. 静态集合使用软/弱引用
private static final Map<String, WeakReference<BigData>> CACHE = new ConcurrentHashMap<>();
```

### 7.2 监控告警配置

```yaml
# Prometheus AlertManager 规则示例
groups:
  - name: JVM memory alerts
    rules:
      - alert: HeapUsageHigh
        expr: jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"} > 0.85
        for: 10m
        annotations:
          summary: "堆内存使用超过 85%"

      - alert: OldGenHigh
        expr: jvm_memory_used_bytes{id="G1 Old Gen"} / jvm_memory_max_bytes{id="G1 Old Gen"} > 0.9
        for: 15m
        annotations:
          summary: "老年代使用超过 90%，可能有泄漏风险"

      - alert: MetaspaceHigh
        expr: jvm_memory_used_bytes{id="Metaspace"} / jvm_memory_max_bytes{id="Metaspace"} > 0.85
        for: 10m
        annotations:
          summary: "Metaspace 使用超过 85%"
```

## 八、总结

内存泄漏排查最重要的不是工具，而是**方法论**：

1. **定性**：确定是哪类泄漏（堆内/堆外/Metaspace）
2. **定位**：找到泄漏点（哪个对象、哪个类、哪行代码）
3. **定量**：评估影响范围（泄漏速度、峰值需求）
4. **修复**：最小化改动修复，避免引发新问题

| 阶段 | 常用命令 |
|------|---------|
| 快速判断 | `top` + `jstat -gcutil` |
| 堆内定位 | `jmap -dump` → MAT |
| 堆外定位 | `jcmd VM.native_memory diff` |
| Metaspace | `jcmd VM.metaspace` |
| 在线诊断 | Arthas + async-profiler |

掌握了这些套路，无论是线上 Full GC 频繁还是容器 OOM Kill，都能有条不紊地排查定位。
