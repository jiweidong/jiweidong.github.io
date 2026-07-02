---
title: 【生产实战】Java OOM 排查实战：从堆转储到 MAT 分析
date: 2026-07-02 08:00:00
tags:
  - Java
  - JVM
  - 性能调优
categories:
  - Java
  - JVM
author: 东哥
---

# 【生产实战】Java OOM 排查实战：从堆转储到 MAT 分析

## 概述

OutOfMemoryError（OOM）是 Java 生产环境中最具破坏力的故障之一。一次 OOM 可能导致整个应用不可用，甚至引发雪崩效应。本文从实战角度出发，系统梳理 OOM 的排查思路、常用工具和典型案例。

## 一、OOM 的类型与触发场景

### 1.1 Java heap space

最常见的 OOM，堆内存不足。

```java
// 典型触发场景：内存泄漏或堆太小
List<byte[]> list = new ArrayList<>();
while (true) {
    list.add(new byte[1024 * 1024]); // 每秒泄漏1MB
}
```

**常见原因：**
- 内存泄漏（对象无法被 GC 回收）
- 堆大小设置不足（-Xmx 过小）
- 大对象/大数组直接进入老年代
- 流量突增导致对象创建远快于 GC 回收

### 1.2 Metaspace

```java
// 使用 CGLIB 动态生成大量类
while (true) {
    Enhancer enhancer = new Enhancer();
    enhancer.setSuperclass(OomTest.class);
    enhancer.setUseCache(false);
    enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) -> proxy.invokeSuper(obj, args));
    enhancer.create();
}
```

**常见原因：**
- CGLIB/ASM 动态生成类过多（如 Spring AOP 代理滥用）
- 类加载器泄漏（Tomcat 热部署反复加载类）
- JSP 文件大量动态编译

### 1.3 GC overhead limit exceeded

```java
// GC 花费超过 98% 时间，回收不到 2% 堆内存
Map<Integer, String> map = System.getProperties();
Random r = new Random();
while (true) {
    map.put(r.nextInt(), "value");
}
```

JVM 主动触发此异常以防止系统完全卡死。本质是堆已满且 GC 无法有效回收。

### 1.4 Unable to create new native thread

```java
while (true) {
    new Thread(() -> {
        try { Thread.sleep(Long.MAX_VALUE); } 
        catch (InterruptedException e) { }
    }).start();
}
```

**常见原因：**
- 线程池配置过大
- 操作系统线程数限制（ulimit -u）
- 容器内存限制未正确传递

### 1.5 Direct buffer memory

NIO 直接内存使用超出 -XX:MaxDirectMemorySize 限制。Netty、gRPC 等框架常见。

## 二、OOM 排查工具箱

| 工具 | 用途 | 适用场景 |
|------|------|----------|
| jmap | 生成堆转储、查看堆信息 | 实时在线分析 |
| jstat | 监控 GC 情况 | 定位 GC 频率异常 |
| jstack | 线程快照 | 线程死锁/阻塞分析 |
| MAT | 堆转储离线分析 | 深度分析泄漏根源 |
| JProfiler | 商业级性能分析 | 完整性能剖析 |
| Arthas | 在线诊断 | 生产环境无侵入排查 |

## 三、实战案例：一次典型的堆内存泄漏排查

### 3.1 现象

某订单服务上线新版本后，运行 12 小时后触发 OOM，监控报警：

```
Exception in thread "http-nio-8080-exec-10"
java.lang.OutOfMemoryError: Java heap space
```

### 3.2 排查步骤

**Step 1：确认 JVM 参数**

```bash
# 查看启动参数
ps aux | grep java
jcmd 12345 VM.flags
```

发现 `-Xms512m -Xmx512m`，堆设置偏小，但 12 小时才 OOM，说明大概率有泄漏。

**Step 3：实时观察 GC 情况**

```bash
# 每1秒输出一次GC信息
jstat -gcutil 12345 1000 10

  S0     S1     E      O      M     YGC     YGCT    FGC    FGCT     GCT
  0.00   0.00   95.2   88.3   90.1   1256    12.345   3      1.234    13.579
  0.00   0.00   96.8   91.2   90.1   1257    12.346   3      1.234    13.580
  0.00   0.00   97.5   92.8   90.1   1258    12.347   3      1.234    13.581
```

**发现：** 老年代（O）占用持续上升，YGC 次数增加但 Full GC 没有执行，说明老年代在慢慢涨满。

**Step 3：获取堆转储**

```bash
# 方式一：jmap（生产环境谨慎使用，会STW）
jmap -dump:live,format=b,file=/tmp/heap.hprof 12345

# 方式二：jcmd（推荐，影响更小）
jcmd 12345 GC.heap_dump /tmp/heap.hprof

# 方式三：-XX:+HeapDumpOnOutOfMemoryError（自动dump，推荐配置）
# 自动在OOM时生成dump文件到指定路径
```

**Step 4：使用 MAT 分析堆转储**

导入 `heap.hprof` 到 Eclipse MAT。

**核心分析指标：**
- **Histogram**：查看各类型实例数量和占用大小
- **Dominator Tree**：按保留堆大小排序的对象树
- **Leak Suspects**：MAT 自动识别的泄漏嫌疑点
- **GC Roots**：追踪对象引用链

**实际发现：**

通过 MAT 的 Leak Suspects 发现：

```
One instance of "java.util.HashMap" loaded by "org.apache.catalina.loader.WebappClassLoader"
occupies 287,345,432 (92.8%) bytes.
The memory is accumulated in one instance of "java.util.HashMap".
```

点击查看 Dominator Tree，发现这个 HashMap 中有超过 50 万个订单对象。

**Step 5：定位问题代码**

通过 GC Root 追溯引用链：
```
Thread @ 0x6c0aeb280
  └── WebContainer @ 0x6c34a1230
       └── HTTPServlet.service()
            └── OrderServiceImpl
                 └── orderCache (HashMap) ← 罪魁祸首！
```

**根因：** 开发人员使用了一个 `static HashMap<String, Order>` 作为本地缓存，只增不删。

```java
// 问题代码
public class OrderServiceImpl {
    private static Map<String, Order> orderCache = new HashMap<>(); // 没有容量限制！
    
    public Order getOrder(String orderId) {
        if (!orderCache.containsKey(orderId)) {
            orderCache.put(orderId, orderDao.findById(orderId));
        }
        return orderCache.get(orderId);
    }
}
```

**修复方案：**

```java
// 修复方案一：Guava Cache（推荐）
private static LoadingCache<String, Order> orderCache = 
    Caffeine.newBuilder()
        .maximumSize(5000)
        .expireAfterWrite(30, TimeUnit.MINUTES)
        .build(key -> orderDao.findById(key));

// 修复方案二：定时清理
private static Map<String, Order> orderCache = 
    Collections.synchronizedMap(
        new LinkedHashMap<String, Order>(16, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, Order> eldest) {
                return size() > 5000;
            }
        });
```

### 实战经验总结

| 排查方向 | 关键工具 | 判断标准 |
|----------|----------|----------|
| 堆太小 | jstat GC 曲线 | Full GC 频繁，GC 后老年代下降明显 |
| 内存泄漏 | MAT Leak Suspects | GC 后老年代不降反升 |
| 线程泄漏 | jstack / top -H | 线程数持续上升 |
| 直接内存 | pmap / NMT | NMT 跟踪 direct buffer 增长 |

## 四、预防 OOM 最佳实践

### 4.1 JVM 参数配置

```bash
# 必须配置的参数
-Xms4g -Xmx4g                     # 堆大小（生产建议4G-8G）
-XX:+HeapDumpOnOutOfMemoryError   # OOM时自动dump
-XX:HeapDumpPath=/data/dumps/     # dump文件目录
-XX:+PrintGCDetails               # 打印GC详情
-XX:+PrintGCDateStamps            # GC时间戳
-Xloggc:/data/gc/gc.log           # GC日志文件
-XX:+UseG1GC                      # 推荐G1垃圾收集器
-XX:MetaspaceSize=256m             # 元空间大小
```

### 4.2 容器化注意事项

```yaml
# K8s Deployment 配置
resources:
  requests:
    memory: "2Gi"
  limits:
    memory: "4Gi"
# JVM 参数需感知容器限制
# Java 10+ 自动识别容器内存限制 (-XX:+UseContainerSupport)
```

### 4.3 代码层面

1. **集合类**：使用 `List`/`Map` 时预估大小，用完清理
2. **文件流**：始终使用 try-with-resources
3. **线程池**：使用 `ThreadPoolExecutor` 而非 `new Thread()`
4. **连接池**：设置合理的最大连接数和超时时间
5. **本地缓存**：必须设置最大容量和过期时间

## 五、面试官常见追问

> Q1：jmap -dump:live 和 普通 dump 的区别？

`-dump:live` 只 dump 存活对象（先触发 Full GC），dump 文件更小，但会触发 STW。不指定 live 则 dump 全部对象（包括不可达对象），文件更大但更完整。

> Q2：OOM 一定会立即报错吗？

不一定。有些 JVM 参数（如 -XX:+ExitOnOutOfMemoryError）会主动退出，默认情况下 OOM 发生在 **分配新对象时**，且同一线程抛出 OOM 后如果捕获异常继续运行，**其他线程不一定立即受影响**（取决于堆状态和 GC 策略）。

> Q3：MAT 中的 Shallow Heap 和 Retained Heap 有什么区别？

- **Shallow Heap**：对象自身占用的内存大小（仅对象头 + 字段引用）
- **Retained Heap**：对象被 GC 回收时，一起被回收的所有对象大小总和（即该对象支配的所有对象）

```
示例：一个 HashMap 的 shallow heap 可能只有几百字节，
但 retained heap 可以是几百 MB（因为包含所有 entry 和 value 对象）
```

## 六、结语

OOM 排查是 Java 开发者必须掌握的核心技能。关键在于：**配好自动 dump、善用分析工具、理解对象引用链**。遇到 OOM 别慌，按本文的排查流程一步步来，绝大多数问题都能定位。

**一句话总结：配好 -XX:+HeapDumpOnOutOfMemoryError，OOM 就变成了一个可复现的问题。**
