---
title: 【JVM 底层】类卸载（Class Unloading）与元空间回收深度解析：ClassLoader 泄漏排查实战
date: 2026-09-27 08:40:00
tags:
  - JVM
  - 类加载
  - 内存泄漏
  - 生产实战
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 底层】类卸载（Class Unloading）与元空间回收深度解析：ClassLoader 泄漏排查实战

## 面试官：Java 的类会被卸载吗？

这是一个「听起来简单，答起来很难」的问题。

大多数人的回答是：「类加载后就一直存在，直到 JVM 结束。」

这个答案**只对了一半**。准确地说：

> **类是可以被卸载的，但条件非常苛刻。** 类卸载的前提是它的 **ClassLoader 被回收**，而 ClassLoader 被回收的前提是「它加载的所有类都不再被引用，且它自己也不被引用」。

而现实中，**ClassLoader 泄漏是 Java 应用中非常隐蔽、后果非常严重的一类内存问题**，尤其在：

- Tomcat / Jetty 热部署（reload/undeploy）场景；
- OSGi、插件化框架；
- 频繁使用脚本引擎（Nashorn/GraalJS）、字节码生成（CGLIB/ASM/ByteBuddy）、动态代理；
- 自定义 ClassLoader 做隔离（如 Dubbo 的 SPI 类隔离、Arthas）。

这些场景下，**元空间（Metaspace）会持续增长，最终 `java.lang.OutOfMemoryError: Metaspace`**，而且重启前无法自愈。

这篇文章把类卸载的条件、Metaspace 回收机制、泄漏根因、排查手段和治理方案完整讲一遍。

---

## 一、类加载的生命周期回顾

类的完整生命周期：

```
加载 → 验证 → 准备 → 解析 → 初始化 → 使用 → 卸载
 ↓      ↓      ↓      ↓      ↓        ↓      ↓
 类加载器参与 ←───────────────────────────┤
                                          └─ 类卸载（需 ClassLoader 被回收）
```

关键点：

| 阶段 | 是否可卸载的决策点 |
| --- | --- |
| 加载 | 由某个 ClassLoader 加载，建立 ClassLoader ↔ Class 的引用关系 |
| 使用 | 实例、静态变量、反射引用都可能持有 Class |
| 卸载 | **必须等 ClassLoader 被 GC 回收** |

**核心不变量：JVM 不会单独卸载一个类。** 卸载的单位是「**ClassLoader + 它加载的所有类**」这个整体。

为什么？因为：

1. **Class 对象持有对 ClassLoader 的引用**（`Class.getClassLoader()`）；
2. ClassLoader 持有它加载的所有类的定义（`parallelLockMap`、`classes` 集合、`package2certs`）；
3. 类之间互相引用，无法单独卸载其中一个而不破坏一致性。

所以：**「类卸载」= 「ClassLoader 被回收」**。这就是问题的本质。

---

## 二、类被卸载的三个条件

JVM 规范对类卸载的要求（可归纳为三条）：

```
1. 该类的所有实例都已被回收（堆中无该类的实例）
2. 该类的 java.lang.Class 对象没有被任何地方引用
   （没有通过反射、Class 对象、静态字段等被引用）
3. 加载该类的 ClassLoader 实例已经被回收
   （没有任何地方引用这个 ClassLoader）
```

三条必须**同时满足**，等价于「该类彻底不可达」。

### 2.1 详细拆解

**条件 1：实例全部被回收**

```java
MyClass obj = new MyClass();
// 只要 obj 可达，MyClass 就不能卸载
obj = null;
// 现在实例可能被回收了
```

注意：**局部变量表中的引用、线程栈中的引用、ThreadLocal 中的引用**都算「可达」。

**条件 2：Class 对象无引用**

```java
Class<?> clazz = Class.forName("com.example.MyClass");
// 静态缓存了这个 clazz，就阻塞卸载
staticCache.add(clazz);   // ❌ 泄漏
```

常见坑：**用 `Class` 对象或 `Method`/`Field` 做缓存 key，会持有 ClassLoader 引用**。

```java
// ❌ 典型泄漏：静态 Map 缓存 Method
private static final Map<Class<?>, Method> METHOD_CACHE = new ConcurrentHashMap<>();

// 正确做法：用 WeakReference 或用 String 类型的类名做 key
private static final Map<String, Method> METHOD_CACHE = new ConcurrentHashMap<>();
```

**条件 3：ClassLoader 实例被回收**

ClassLoader 本身也是对象，它也可能被：

- 静态变量引用；
- 线程（`Thread.contextClassLoader`）；
- ThreadLocal 引用；
- 未关闭的资源引用；
- 已加载类的静态字段引用（循环引用，但只要外部无引用，循环引用也能被 GC 回收）。

### 2.2 一个关键理解：循环引用不是问题

很多人以为「类引用 ClassLoader，ClassLoader 引用类，互相引用所以永远不能回收」。

这是错的。**JVM 用可达性分析（而不是引用计数）**，只要这批对象整体对外不可达，就能被整体回收。

```
GC Roots
   │
   ├─ Thread A ──▶ MyClassLoader ──▶ MyClass ──▶ MyClassLoader (循环)
   │                    ▲
   │                    └── 有 GC Root 引用，无法回收
```

只要切断 `Thread A → MyClassLoader` 这条边，整个闭环就能被回收。

---

## 三、Metaspace 的回收机制

### 3.1 什么是 Metaspace

JDK 8 用 **Metaspace** 取代了 **PermGen**：

| 维度 | PermGen（JDK 7 及以前） | Metaspace（JDK 8+） |
| --- | --- | --- |
| 位置 | 堆内（连续） | **本地内存（Native Memory）** |
| 大小控制 | `-XX:MaxPermSize` | `-XX:MaxMetaspaceSize`（默认无限） |
| 回收 | Full GC | 类卸载时才回收 |
| OOM 错误 | `PermGen space` | `Metaspace` |
| 碎片化 | 严重 | 较好（Chunk 管理） |

Metaspace 存放：**类元数据、方法元数据、常量池、注解、字节码（部分）**。

### 3.2 关键参数

```bash
-XX:MetaspaceSize=256m           # 首次 GC 阈值（不是初始大小！触发 GC 后动态调整）
-XX:MaxMetaspaceSize=512m        # 上限，不设则无限（危险！）
-XX:MinMetaspaceFreeRatio=40     # GC 后最小空闲比例，低于则扩容
-XX:MaxMetaspaceFreeRatio=70     # GC 后最大空闲比例，高于则缩容
-XX:+ClassUnloading              # 允许类卸载（默认开启）
-XX:+ClassUnloadingWithConcurrentMark  # 并发标记阶段也卸载类（G1 默认开启）
```

⚠️ **`MetaspaceSize` 是「首次触发 GC 的阈值」，不是初始分配的容量。** 这是个非常容易误解的点。

**强烈建议设置 `MaxMetaspaceSize`**，否则元空间无限增长会耗尽整机内存，触发系统 OOM Killer（比 OOM 异常更难排查）。

### 3.3 什么时候会发生类卸载

关键：**类卸载不是独立触发的，它依附于 GC。**

| GC 类型 | 是否卸载类 |
| --- | --- |
| Young GC（Minor GC） | ❌ 不卸载 |
| Full GC（Serial/Parallel/CMS） | ✅ 卸载 |
| CMS 并发周期 | ✅（`-XX:+CMSClassUnloadingEnabled`，JDK 8 默认开） |
| G1 并发标记周期 | ✅（`-XX:+ClassUnloadingWithConcurrentMark`，默认开） |
| ZGC / Shenandoah 并发周期 | ✅（并发类卸载） |

**所以：如果你的应用长期没有 Full GC（比如用了 G1 + 大堆 + 低分配率），Metaspace 里的垃圾类就不会被回收！**

这是一个隐蔽的坑：

```
应用长期只做 Young GC
  -> 没有并发标记周期 / Full GC
  -> 类卸载不发生
  -> Metaspace 持续增长
  -> MetaspaceSize 触发的 "Full GC" 其实是 "Metadata GC Threshold"
```

实际上 JVM 会在 Metaspace 达到阈值时主动触发 GC（称为 `GCLocker` / `Metadata GC Threshold`），日志里能看到：

```
[Full GC (Metadata GC Threshold) ...]
```

但这类 GC 的**类卸载效果依赖具体回收器**。G1 上 `ClassUnloadingWithConcurrentMark` 默认开启，效果较好；CMS 需要显式开启 `CMSClassUnloadingEnabled`（JDK 8 默认开）。

### 3.4 观察类卸载

```bash
# 1. 打印类加载/卸载统计（需要 -XX:+TraceClassLoading / -XX:+TraceClassUnloading）
-XX:+TraceClassLoading
-XX:+TraceClassUnloading
-Xlog:class+load=info:file=classload.log        # JDK 9+
-Xlog:class+unload=info:file=classunload.log

# 2. 看累计加载/卸载数
jstat -class <pid> 1000
```

```
Loaded  Bytes  Unloaded  Bytes     Time
 45231  89234.5     1234   2312.3    12.34
```

**`Unloaded` 长期为 0 是一个危险信号**：说明类从来没有被卸载过，Metaspace 只会涨不会落。

```bash
# 3. 看 Metaspace 使用
jstat -gc <pid>
# M（Metaspace 使用量）、CCS（压缩类空间）、MC（Metaspace 容量）、MU（Metaspace 已用）

jcmd <pid> VM.metaspace
```

输出（JDK 11+）：

```
Metaspace Utilization (used, committed, reserved):
  Non-class:     12.34 MB used,  14.00 MB committed,  1.03 GB reserved.
      Class:     45.67 MB used,  48.00 MB committed,  1.03 GB reserved.
       Both:     58.01 MB used,  62.00 MB committed,  1.03 GB reserved.

Virtual space:
  Chunk freelists: ...
Non-class space:  15 chunks (of which 3 free)
Class space:      30 chunks (of which 0 free)
```

### 3.5 深入：Metaspace 的内存管理

JDK 8+ 的 Metaspace 用 **Virtual Space List + Chunk** 管理：

| 概念 | 说明 |
| --- | --- |
| Virtual Space | 向 OS 申请的内存区域（`mmap`），按 Chunk 切分 |
| Chunk | 基本分配单位，分 4 类：Class Space、Specialized、Small、Medium、Humongous |
| Class Space | 存放 `Klass` 结构等，**不会被复用**（释放后整个 chunk 归还） |
| Non-class Space | 方法元数据、常量池等，**可以复用**（通过 freelist） |

**关键差异**：

- **Class Space 不可复用**：卸载一个类，只是标记 chunk 里的空间空闲，**但 chunk 本身只有在整个 chunk 都空时才归还**；如果 chunk 里有一个类泄漏，整个 chunk 无法释放；
- **Non-class Space 可复用**：通过 freelist 复用，碎片化容忍度更高。

这解释了为什么**「只泄漏少数几个类」也可能导致 Class Space 持续增长**——因为 chunk 粒度是 4KB~1MB（取决于类型）。

---

## 四、ClassLoader 泄漏的六大根因

### 4.1 ThreadLocal 未清理（最常见）

```java
// ❌ 泄漏
public class UserContext {
    private static final ThreadLocal<MyClassLoader> HOLDER = new ThreadLocal<>();

    public static void set(MyClassLoader cl) {
        HOLDER.set(cl);
    }
    // 没有 remove() 方法！
}
```

为什么泄漏：**线程池的线程会长期存活**，`Thread.threadLocals` → `ThreadLocalMap.Entry` → `value`（ClassLoader）形成强引用链。

```java
// ✅ 正确：使用后清理
try {
    UserContext.set(cl);
    doWork();
} finally {
    UserContext.remove();   // 必须！
}
```

**更强的实践**：ThreadLocal 存的值本身用 **WeakReference** 包一层，或者干脆不要在线程级上下文里存 ClassLoader。

### 4.2 线程的 contextClassLoader 未恢复

```java
// ❌ 泄漏
Thread t = new Thread(() -> {
    Thread.currentThread().setContextClassLoader(myClassLoader);
    // 线程结束后没有恢复，如果线程来自线程池 -> 泄漏
});
```

**Tomcat 的经典泄漏就包含这一条**。Tomcat 在 webapp 卸载时会检查：

```
The web application [/app] created a ThreadLocal with key of type [...] 
and a value of type [...] but failed to remove it when the web application 
was stopped. This is very likely to create a memory leak.
```

### 4.3 静态字段持有 Class / ClassLoader

```java
// ❌ 各种静态缓存
private static final List<Class<?>> ALL_CLASSES = new ArrayList<>();
private static final Map<String, Object> BEAN_CACHE = new HashMap<>();
private static final Set<Method> METHODS = new HashSet<>();
```

**排查思路**：任何 `static` 的 `Map`/`List`/`Set`/`Cache`，如果 key 或 value 是 `Class`/`Method`/`Field`/`Constructor`/`ClassLoader`，都是高危。

**正确的替代**：

```java
// ✅ 用弱引用
private static final Map<Class<?>, Object> CACHE = new WeakHashMap<>();

// ✅ 用 ClassLoader 的弱引用
private static final Map<String, Method> METHOD_CACHE = new ConcurrentHashMap<>();

// ✅ 用 Caffeine 设置 weakKeys
Cache<Class<?>, Object> cache = Caffeine.newBuilder()
        .weakKeys()
        .weakValues()
        .build();
```

### 4.4 未关闭的资源

```java
// ❌ 注册了 Driver 但没注销
DriverManager.registerDriver(new MyDriver());   // DriverManager 是 bootstrap 加载的，
                                                // 它持有 MyDriver 实例 -> 持有 ClassLoader

// ✅ Tomcat 卸载 webapp 时会自动清理 DriverManager
// 手动清理：
Enumeration<Driver> drivers = DriverManager.getDrivers();
while (drivers.hasMoreElements()) {
    Driver d = drivers.nextElement();
    if (d.getClass().getClassLoader() == myClassLoader) {
        DriverManager.deregisterDriver(d);
    }
}
```

其他未关闭资源：`Timer`、`Thread`、`ScheduledExecutorService`、`Selector`、`JMX MBean`、`URLStreamHandlerFactory`、`Logger`（Logback 的 LoggerContext）。

### 4.5 动态生成的类（Lambda / 代理 / CGLIB）

这是**现代 Java 应用最常见的隐性来源**。

| 来源 | 是否可卸载 | 说明 |
| --- | --- | --- |
| CGLIB 代理类 | ✅（需自己缓存） | 每次 `Enhancer.create()` 都可能生成新类 |
| JDK 动态代理 | ✅（有内置缓存） | `Proxy.newProxyInstance` 有 `proxyClassCache`（弱引用） |
| Lambda | ✅（JDK 15+ 隐藏类） | 隐藏类是弱引用，可被卸载 |
| ASM/ByteBuddy 生成类 | ✅（需自己管理） | 频繁生成会撑爆 Metaspace |
| ScriptEngine 编译的类 | ⚠️ | 每次 `eval` 都可能生成新类 |
| JSP 编译的类 | ⚠️ | JSP 改动后旧类需卸载 |

**CGLIB 的经典坑**：

```java
// ❌ 每次调用都创建新的 Enhancer
public Object createProxy(Class<?> target) {
    Enhancer enhancer = new Enhancer();
    enhancer.setSuperclass(target);
    enhancer.setCallback(new MyInterceptor());
    return enhancer.create();   // 每次都生成新类！Metaspace 爆炸
}

// ✅ 缓存 Enhancer（CGLIB 内部有 AbstractClassGenerator 的缓存，但要正确配置）
private final Map<Class<?>, Enhancer> enhancerCache = new ConcurrentHashMap<>();
```

**脚本引擎的坑**：

```java
// ❌ 每次 eval 都新建引擎并编译
ScriptEngine engine = new ScriptEngineManager().getEngineByName("nashorn");
engine.eval(script);   // 编译出的类无法释放（引擎持有）

// ✅ 复用引擎 + 显式清理
// 或改用 Invocable 缓存 CompiledScript
CompiledScript compiled = ((Compilable) engine).compile(script);
```

**JDK 15+ 的隐藏类（Hidden Class）**是重要改进：Lambda、方法引用生成的类通过 `Lookup.defineHiddenClass` 定义，**不可被反射发现、天然可卸载**，这解决了一大批 Lambda 泄漏问题。

### 4.6 缓存与框架

| 框架/组件 | 泄漏点 |
| --- | --- |
| Spring | `defaultListableBeanFactory` 的 beanDefinitionNames（应用中持有一个就全泄漏） |
| MyBatis | `Configuration.mappedStatements` |
| Logback | `LoggerContext` 里的 loggerCache |
| 注册中心客户端 | 心跳线程持有 ClassLoader |
| 分布式追踪 | 增强的类 + ThreadLocal 上下文 |
| Jackson | `TypeFactory` 的缓存（对 `Class` 有引用） |

---

## 五、排查方法论

### 5.1 第一步：确认是 Metaspace 问题

```bash
# 看 Metaspace 使用趋势
jstat -gc <pid> 5000
# MC / MU 持续增长且 Unloaded=0 -> 确认

# 看 GC 日志里的 Metaspace 变化
grep -i "metaspace" gc.log | tail -20
```

GC 日志（JDK 9+ 统一日志）示例：

```
[2.345s][info][gc,heap,exit] Heap
[2.345s][info][gc,metaspace] Metaspace: 45231K(46208K)->45120K(46208K)
```

### 5.2 第二步：看类加载统计

```bash
jcmd <pid> GC.class_stats
# 需要 -XX:+UnlockDiagnosticVMOptions
```

输出按 ClassLoader 分组的类数量：

```
Index Super InstBytes KlassBytes annotations ... ClassName
...
# ClassLoader 级别的统计更直观
```

更实用的是 `jcmd <pid> VM.classloader_stats`（JDK 11+）：

```
ClassLoader         Parent              CLD*               Classes   ChunkSz   BlockSz  Type
0x0000000000000000  0x0000000000000000  0x00007f...       1024      65536     57344    <boot>
0x00007f1234abc000  0x0000000000000000  0x00007f...        312      32768     28672    MyClassLoader@0x...
```

**找到 Classes 数量多、且不断增长的 ClassLoader**，就是嫌疑对象。

### 5.3 第三步：Heap Dump + MAT 分析

这是**最有效**的手段：

```bash
jmap -dump:live,format=b,file=heap.hprof <pid>
# 或用 jcmd（更安全，不 STW 太久）
jcmd <pid> GC.heap_dump /tmp/heap.hprof
```

**MAT 排查路径**：

1. **Histogram** → 搜索 `ClassLoader` 子类，看实例数；
2. **Dominator Tree** → 找最大的对象，看是谁持有 ClassLoader；
3. **Path to GC Roots**（**排除弱引用**）→ 找到强引用链：
   ```
   MyClassLoader
     <- value of ThreadLocalMap$Entry (thread: pool-1-thread-3)
       <- threadLocals of Thread
         <- worker of ThreadPoolExecutor
           <- static field of Executors  ❌ 泄漏根因
   ```

**核心技巧：一定要画 GC Roots 路径（Path to GC Roots → exclude weak/soft references）**，MAT 会直接告诉你谁在引用。

### 5.4 第四步：JFR 记录类卸载

```bash
-XX:StartFlightRecording=duration=300s,filename=app.jfr,settings=profile
```

在 JMC 里看 `Class Loading` / `Class Unloading` 事件，找出生成类最多的来源。

### 5.5 第五步：Arthas 快速定位

```bash
# 类加载器统计
classloader -t
# 输出 ClassLoader 树 + 每个加载了多少类

# 反查某个类由哪个 ClassLoader 加载
sc -d com.example.MyClass | grep classLoaderHash

# 查看 ClassLoader 加载的所有类
classloader -a -c <classLoaderHash>

# 查看类的来源（哪个 jar）
classloader -c <hash> -r com/example/MyClass.class
```

**Arthas 的 `classloader -t` 是排查泄漏的快速入口**，能一眼看出哪个 ClassLoader 加载了几万个类。

### 5.6 第六步：监控告警

```
# Prometheus + Micrometer
jvm_classes_loaded_classes           # 已加载类数
jvm_classes_unloaded_classes_total   # 累计卸载类数
jvm_memory_used_bytes{area="nonheap",id="Metaspace"}

# 告警规则
- alert: MetaspaceGrowing
  expr: jvm_memory_used_bytes{id="Metaspace"} > 400e6
        and delta(jvm_classes_loaded_classes[1h]) > 1000
```

**指标设计要点**：看**「类加载数增速」**比看**「Metaspace 绝对值」**更早发现问题。

---

## 六、实战：一次 Tomcat 频繁 reload 导致 Metaspace OOM

### 6.1 现象

测试环境每次发布（Tomcat reload）后，Metaspace 增长 40MB 不回落；连续发布 12 次后，`java.lang.OutOfMemoryError: Metaspace`。

### 6.2 排查

```bash
$ jstat -class 12345
Loaded  Bytes   Unloaded  Bytes   Time
185432  372891  0        0.0     0.00
```

**Unloaded = 0**，12 次 reload 一个类都没卸载。

```bash
$ jcmd 12345 VM.classloader_stats | head -20
ClassLoader             Classes   ChunkSz   BlockSz
<bootstrap>             1024      65536     57344
WebappClassLoader@1a2b   4213     262144    245760
WebappClassLoader@3c4d   4198     262144    245760
WebappClassLoader@5e6f   4189     262144    245760
... (12 个 WebappClassLoader，每个都还活着)
```

**12 个 WebappClassLoader 全部存活**，说明每次 reload 旧 ClassLoader 都没被回收。

### 6.3 定位引用链

Heap Dump + MAT "Path to GC Roots"：

```
WebappClassLoader@1a2b
  <- contextClassLoader of Thread "pool-2-thread-7"
    <- (thread is alive, from a leaked ExecutorService)
      <- executor field of MyScheduledTask
        <- static field SCHEDULER of com.example.TaskManager  (WebappClassLoader 加载)
          <- (循环)
```

同时 MAT 发现：

```
MyUserContext
  <- value of ThreadLocalMap$Entry
    <- threadLocals of Thread "http-nio-8080-exec-5"
```

### 6.4 根因（三个叠加）

1. **静态 `ScheduledExecutorService` 未关闭**：`TaskManager.SCHEDULER` 是静态字段，webapp 停止时没有 `shutdownNow()`，线程一直活着，线程的 `contextClassLoader` 指向旧 WebappClassLoader；
2. **ThreadLocal 未 remove**：`MyUserContext` 里的 ThreadLocal 在线程池线程上残留，value 持有业务类；
3. **JDBC 驱动未注销**：自定义 Driver 被注册到 `DriverManager`（Bootstrap 加载），持有 WebappClassLoader。

### 6.5 治理

```java
// 修复 1：实现 ServletContextListener，在 contextDestroyed 中释放所有资源
@WebListener
public class ResourceCleanupListener implements ServletContextListener {

    @Override
    public void contextDestroyed(ServletContextEvent sce) {
        // ① 关闭线程池
        TaskManager.shutdown();

        // ② 注销 JDBC 驱动
        ClassLoader cl = Thread.currentThread().getContextClassLoader();
        Enumeration<Driver> drivers = DriverManager.getDrivers();
        while (drivers.hasMoreElements()) {
            Driver driver = drivers.nextElement();
            if (driver.getClass().getClassLoader() == cl) {
                try {
                    DriverManager.deregisterDriver(driver);
                } catch (SQLException e) {
                    log.warn("deregister driver failed", e);
                }
            }
        }

        // ③ 清理 Logback LoggerContext
        LoggerContext loggerContext = (LoggerContext) LoggerFactory.getILoggerFactory();
        loggerContext.stop();

        // ④ 关闭 Timer / 网络客户端
        HttpClientHolder.close();
    }
}
```

```java
// 修复 2：ThreadLocal 必须 remove
public class MyUserContext {
    private static final ThreadLocal<Context> HOLDER = new ThreadLocal<>();

    public static void set(Context ctx) { HOLDER.set(ctx); }

    public static Context get() { return HOLDER.get(); }

    public static void clear() { HOLDER.remove(); }   // ✅ 关键
}
```

```java
// 修复 3：filter 里保证清理
public class ContextFilter implements Filter {
    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        try {
            MyUserContext.set(buildContext(req));
            chain.doFilter(req, res);
        } finally {
            MyUserContext.clear();   // ✅ 无论如何都清理
        }
    }
}
```

### 6.6 效果

修复后：

```bash
$ jstat -class 12345
Loaded  Bytes   Unloaded  Bytes   Time
185432  372891  41203     82311   45.67
```

**Unloaded 从 0 变成 4 万+**，每次 reload 后 Metaspace 回落到基线，连续发布 30 次无异常。

---

## 七、预防清单

| 类别 | 检查项 | 做法 |
| --- | --- | --- |
| 参数 | 设置上限 | `-XX:MaxMetaspaceSize=512m`（必须！） |
| 参数 | 打点卸载日志 | `-Xlog:class+unload=info:file=unload.log` |
| 参数 | 保证类卸载 | G1 默认开 `ClassUnloadingWithConcurrentMark`；CMS 显式开 `CMSClassUnloadingEnabled` |
| 编码 | 静态缓存 | 禁止缓存 `Class`/`Method`/`ClassLoader`；必须缓存用 `WeakHashMap`/`weakKeys` |
| 编码 | ThreadLocal | 所有 `set` 必须有配对的 `remove`，用 try-finally 或 Filter/AOP 保证 |
| 编码 | 线程池 | 自建线程池必须有 `shutdown` 钩子（`contextDestroyed`/`@PreDestroy`） |
| 编码 | 资源注册 | `DriverManager`、JMX、`URLStreamHandlerFactory` 注册后必须注销 |
| 编码 | 动态类 | CGLIB/ASM 生成类必须缓存；脚本引擎复用 |
| 监控 | 指标 | 监控 `jvm_classes_loaded_classes` 增速 + Metaspace 使用量 |
| 监控 | 告警 | `Unloaded=0` 且 `Loaded` 持续增长 > 1 小时即告警 |
| 测试 | 验证 | 压测/多次 reload 后检查 Metaspace 是否回落 |

---

## 八、面试追问集

**Q1：Java 的类什么时候会被卸载？**

> 三个条件必须同时满足：① 该类的所有实例都已被回收；② 该类的 `Class` 对象没有被任何地方引用（反射、静态缓存等）；③ 加载该类的 `ClassLoader` 已被回收。因为 JVM 只能以「ClassLoader + 其加载的所有类」为单位卸载，所以本质是 **ClassLoader 被回收**。

**Q2：类卸载和 GC 是什么关系？**

> 类卸载**依附于 GC**，且只有在能进行**并发标记/Full GC** 的回收阶段才会执行。Young GC 不卸载类。G1 通过 `-XX:+ClassUnloadingWithConcurrentMark`（默认开）在并发标记周期卸载；CMS 需要 `-XX:+CMSClassUnloadingEnabled`。**如果应用长期没有并发标记周期，即使有垃圾类也不会被卸载。**

**Q3：PermGen 和 Metaspace 有什么区别？**

> PermGen 在堆内，大小受限（`MaxPermSize`），Full GC 时回收，容易 `PermGen space` OOM；Metaspace 在**本地内存**，默认无上限（必须设 `MaxMetaspaceSize`！），用 Virtual Space + Chunk 管理，其中 Class Space 的 chunk 不可复用、Non-class Space 可复用。

**Q4：类加载器和类互相引用，为什么还能被回收？**

> 因为 JVM 用的是**可达性分析**而非引用计数。只要从 GC Roots 出发找不到这个对象环，整个环就能被一起回收。关键是切断「外部到环内的引用」（如线程的 `contextClassLoader`、静态字段）。

**Q5：怎么排查 ClassLoader 泄漏？**

> 五步：① `jstat -class` 看 `Unloaded` 是否为 0；② `jcmd VM.classloader_stats` 找出类数异常且持续增长的 ClassLoader；③ `jcmd GC.heap_dump` 导出堆；④ MAT 用 **Path to GC Roots（排除弱引用）** 找强引用链；⑤ Arthas 的 `classloader -t` 快速看 ClassLoader 树和类数量。**MAT 的 GC Roots 路径是关键，它会直接指出谁持有 ClassLoader。**

**Q6：ThreadLocal 为什么会造成 ClassLoader 泄漏？**

> 线程池的线程长期存活 → `Thread.threadLocals`（`ThreadLocalMap`）→ Entry 的 `value` 强引用 → 如果是 ClassLoader 或它加载的对象，就阻止了回收。**注意 Entry 的 key 是弱引用（ThreadLocal 本身），但 value 是强引用，所以 key 被回收后会留下 `key=null` 的 Entry，value 依然泄漏。** 所以必须手动 `remove()`。

**Q7：Lambda 会泄漏类吗？**

> 在 JDK 15 之前，Lambda 通过 `invokedynamic` + `LambdaMetafactory` 生成匿名内部类，这些类**会被 ClassLoader 持有**，频繁动态生成 Lambda（比如每次请求都从字符串动态生成）会累积。JDK 15+ 引入**隐藏类（Hidden Class）**，Lambda 生成的类不可反射发现、天然可卸载，问题大幅缓解。

**Q8：为什么必须设置 `MaxMetaspaceSize`？**

> 因为 Metaspace 默认无上限，泄漏时会一直向 OS 申请内存，最终可能触发**系统 OOM Killer** 杀掉进程（甚至杀掉同机其他进程），这比 `OutOfMemoryError` 更难排查。设置上限后，问题会在应用层以明确异常暴露出来。

**Q9：`-XX:MetaspaceSize` 是初始大小吗？**

> 不是！它是**首次触发 Metaspace GC 的阈值**（默认约 21MB）。JVM 在 Metaspace 使用量达到该值时触发一次 GC（日志里是 `Full GC (Metadata GC Threshold)`），然后根据 `MinMetaspaceFreeRatio`/`MaxMetaspaceFreeRatio` 动态调整阈值。所以常见建议是把它设大一点（如 256m），避免启动期频繁 GC。

**Q10：G1 和 CMS 在类卸载上有什么区别？**

> G1 默认开启 `ClassUnloadingWithConcurrentMark`，在**并发标记周期**就能卸载类，不需要 Full GC，停顿更短；CMS 需要 `CMSClassUnloadingEnabled`（JDK 8 默认开），在**并发周期**中卸载，但 CMS 被移除后（JDK 14+）已不再是选项。ZGC/Shenandoah 也支持并发类卸载，且停顿更低。

---

## 九、总结

类卸载的核心逻辑，用一张图记住：

```
        ┌──────────────────────────────────┐
        │  条件 1：无实例引用                │
        │  条件 2：无 Class 对象引用          │──┐
        │  条件 3：ClassLoader 被回收         │  │
        └──────────────────────────────────┘  │
                                               ▼
                                     ClassLoader 被 GC 回收
                                               │
                                               ▼
                              该类及其加载的所有类被一起卸载
                                               │
                                               ▼
                                  Metaspace 中对应 Chunk 可释放
```

三句话总结：

1. **类卸载的单位是 ClassLoader**，不是单个类；条件是「实例、Class 对象、ClassLoader 三者都不可达」；
2. **类卸载依附于 GC**，长期没有并发标记周期的应用，垃圾类不会被回收；
3. **ClassLoader 泄漏的元凶通常是 ThreadLocal、线程池线程、静态缓存和未注销的资源**，排查的杀手锏是 **MAT 的 Path to GC Roots**。

最后一条工程经验：**任何涉及「热部署、插件化、动态字节码」的系统，上线前必须做一次「反复加载卸载」的压力测试，并用 `jstat -class` 验证 `Unloaded` 是否正常增长。** 这个测试只要 10 分钟，能提前暴露 90% 的类加载器泄漏问题。
