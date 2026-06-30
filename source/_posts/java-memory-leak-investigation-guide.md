---
title: Java 内存泄漏排查全攻略：从堆转储到 MAT 实战
date: 2026-06-30 08:10:00
tags:
  - Java
  - JVM
  - 性能优化
  - 故障排查
categories:
  - Java
  - 性能调优
author: 东哥
---

# Java 内存泄漏排查全攻略：从堆转储到 MAT 实战

## 一、内存泄漏 vs 内存溢出

先理清两个概念：

| 概念 | 定义 | 表现 |
|------|------|------|
| **内存泄漏（Memory Leak）** | 无用对象持续被引用，GC 无法回收 | 占用逐渐增加，最终 OOM |
| **内存溢出（OOM）** | 对象需要内存但堆空间不足 | 直接抛出 OutOfMemoryError |

**泄漏是溢出的原因之一**，但不是唯一原因（也可能是对象过多、堆太小等）。

## 二、Java 内存泄漏的典型模式

### 2.1 静态集合类

最常见的内存泄漏——static 集合的生命周期 = 应用生命周期：

```java
public class CacheManager {
    // ❌ 静态 HashMap 永远不会被回收
    private static Map<String, Object> cache = new HashMap<>();
    
    public static void addData(String key, Object data) {
        cache.put(key, data);  // 只增不减
    }
}
```

**解决方案：** 使用 WeakHashMap、Guava Cache 或设置淘汰策略：

```java
private static Map<String, Object> cache = new ConcurrentHashMap<>();
// 配合定时清理任务
@Scheduled(fixedRate = 60_000) 
public void cleanUp() {
    // 移除过期数据
}
```

### 2.2 未关闭的资源

```java
// ❌ 文件流未关闭
public void readFile(String path) throws IOException {
    FileInputStream fis = new FileInputStream(path);
    byte[] data = new byte[1024];
    fis.read(data);
    // fis.close() 缺失 → 文件描述符泄漏
}

// ✅ try-with-resources 自动关闭
public void readFile(String path) throws IOException {
    try (FileInputStream fis = new FileInputStream(path)) {
        byte[] data = new byte[1024];
        fis.read(data);
    }
}
```

容易被忽略的资源类：

- 文件流（InputStream/OutputStream）
- 网络连接（Socket/HttpURLConnection）
- 数据库连接（Connection/Statement/ResultSet）
- **ThreadLocal 变量**（最常见！）

### 2.3 ThreadLocal 内存泄漏

```java
public class RequestContextHolder {
    // ThreadLocal 的 key 是弱引用，但 value 是强引用
    private static ThreadLocal<UserContext> contextHolder = new ThreadLocal<>();
    
    public static void set(UserContext ctx) {
        contextHolder.set(ctx);
    }
    
    public static UserContext get() {
        return contextHolder.get();
    }
}
```

**泄漏原理：**

```
Thread → ThreadLocalMap → Entry(key=ThreadLocal弱引用, value=UserContext强引用)
                                    ↓
                            key 被 GC 回收后
                            value 永远不会回收！
```

**解决方案：**

```java
// 每次使用后必须 remove
try {
    contextHolder.set(ctx);
    // 执行业务逻辑
} finally {
    contextHolder.remove();  // 避免泄漏
}
```

### 2.4 内部类持有外部类引用

```java
public class BigObject {
    private byte[] data = new byte[1024 * 1024 * 100];  // 100MB
    
    public class InnerClass {
        public void doSomething() {
            // 持有 BigObject.this 的隐式引用
            System.out.println("Working...");
        }
    }
}
```

如果外部类不再使用但内部类对象还在活跃，外部类的 100MB 数据就泄漏了。

### 2.5 集合中自定义 Key 未覆写 hashCode/equals

```java
public class UserKey {
    private String id;
    
    public UserKey(String id) {
        this.id = id;
    }
    // ❌ 没有 hashCode() 和 equals()
    // 导致 HashMap 中存入了重复 key，永远无法正确移除
}

public class LeakExample {
    private Map<UserKey, Object> map = new HashMap<>();
    
    public void process(String id) {
        map.put(new UserKey(id), new byte[1024*1024]);  // 每次put都插入新条目
        map.remove(new UserKey(id));  // 无法移除！hashCode/equals 不同
    }
}
```

### 2.6 连接池未正确归还

```java
// ❌ 从连接池获取连接后未归还
public void processQueries() {
    for (int i = 0; i < 10000; i++) {
        Connection conn = dataSource.getConnection();
        Statement stmt = conn.createStatement();
        stmt.execute("SELECT 1");
        // conn.close() 缺失 → 连接池泄漏
        // 最终 "Connection is not available, request timed out"
    }
}
```

## 三、内存泄漏排查实战流程

### 3.1 监控指标：发现异常

**如何判断可能存在内存泄漏？**

1. **堆内存趋势持续上升**：使用 Prometheus + Grafana 监控 JVM 指标
2. **GC 频率越来越高**：Full GC 越来越频繁
3. **调用 JMX API 查看**

```java
// 通过 JMX 获取堆内存使用情况
MemoryMXBean memoryBean = ManagementFactory.getMemoryMXBean();
MemoryUsage heapUsage = memoryBean.getHeapMemoryUsage();
long used = heapUsage.getUsed();       // 已使用
long max = heapUsage.getMax();         // 最大值
double usageRatio = (double) used / max;
```

### 3.2 生成堆转储（Heap Dump）

**方式一：发生 OOM 时自动 dump**

```bash
java -XX:+HeapDumpOnOutOfMemoryError \
     -XX:HeapDumpPath=/tmp/heapdump.hprof \
     -jar myapp.jar
```

**方式二：使用 jmap 手动 dump**

```bash
# 找到 Java 进程 PID
jps -l

# 触发 full GC 后 dump
jmap -dump:live,format=b,file=/tmp/heapdump.hprof <pid>
```

**方式三：使用 jcmd（推荐，JDK 8+）**

```bash
jcmd <pid> GC.heap_dump /tmp/heapdump.hprof
```

### 3.3 使用 MAT 分析堆转储

**Eclipse Memory Analyzer（MAT）** 是分析堆转储的利器。

#### 第一步：加载 dump 文件

打开 MAT → File → Open Heap Dump → 选择 `.hprof` 文件

#### 第二步：检查 Leak Suspects

"Leak Suspects Report" → MAT 自动分析最可能的泄漏点：

```
Leak Suspects (2 suspects found)
├── Suspect 1: 94.3 MB
│   ThreadLocal 的 value 占据了 94.3 MB 堆空间
│   └── 问题类: com.example.RequestContextHolder
│
└── Suspect 2: 38.7 MB
    HashMap$Node 数组占据了 38.7 MB
    └── 问题类: com.example.CacheManager.cache
```

#### 第三步：Dominator Tree（支配树）

列出所有存活对象，按 Retained Heap 排序，找到最大的对象：

```
对象                                                  Retained Heap
├── java.util.HashMap@0x1234 (CacheManager.cache)   38.7 MB
│   ├── java.util.HashMap$Node[]                    38.7 MB
│   │   ├── com.example.SessionData                12.3 MB
│   │   ├── com.example.SessionData                12.3 MB
│   │   └── com.example.SessionData                12.3 MB
│
├── com.example.BigObject@0x5678                   100 MB
```

#### 第四步：GC Root Path to Objects

选中可疑对象 → "Merge Shortest Paths to GC Roots" → **排除软/弱引用**：

```
com.example.CacheManager.cache
└── class com.example.CacheManager (static field)
    └── ← System Class  ← GC Root
```

这就确认了：**CacheManager 的静态 cache 字段阻止了所有缓存对象的回收**。

### 3.4 使用 JProfiler / YourKit

商业工具提供了更直观的界面，特别适合实时监控：

- Class 视图：按类名看实例数和大小
- GC Root 查找：一键找到泄漏根路径
- CPU/Memory Record：录制一段时间的变化趋势

## 四、实战案例：ThreadLocal 泄漏排查

### 4.1 问题现象

某 Web 应用运行 24 小时后频繁 Full GC，响应变慢，最终 OOM。

### 4.2 jmap 排查步骤

```bash
# 1. 查看进程
jps -l | grep myapp
# 输出: 12345 /opt/myapp/myapp.jar

# 2. 查看堆概览
jmap -heap 12345
# 输出显示: Old Gen 使用率 99%

# 3. 查看 GC 情况
jstat -gcutil 12345 2000
# 输出:
#  S0     S1     E      O      M     YGC     YGCT    FGC    FGCT
#  0.00   0.00  98.5  99.2  95.3  2347   12.347   847   89.234
# FGC=847 次数异常！

# 4. 查看存活对象
jmap -histo:live 12345 | head -20

# 输出:
#  num     #instances         #bytes  class name
# ─────────────────────────────────────────────────
#    1:         98765     123456789  [B
#    2:         98765      98765432  com.example.UserContext
#    3:         12345      24678901  java.lang.ThreadLocal$ThreadLocalMap$Entry
```

UserContext 实例数 98765，明显泄漏！

### 4.3 修复代码

```java
// 修复前
@WebFilter("/api/*")
public class ContextFilter implements Filter {
    public void doFilter(ServletRequest request, ServletResponse response, 
                         FilterChain chain) throws Exception {
        UserContext ctx = buildContext(request);
        RequestContextHolder.set(ctx);
        chain.doFilter(request, response);
        // ❌ 没有 remove
    }
}

// 修复后
@WebFilter("/api/*")
public class ContextFilter implements Filter {
    public void doFilter(ServletRequest request, ServletResponse response, 
                         FilterChain chain) throws Exception {
        UserContext ctx = buildContext(request);
        try {
            RequestContextHolder.set(ctx);
            chain.doFilter(request, response);
        } finally {
            RequestContextHolder.remove();  // ✅ 确保清理
        }
    }
}
```

### 4.4 验证结果

修复后监控对比：

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| Full GC 频率 | 35 次/小时 | 0-2 次/小时 |
| Old Gen 使用率 | 稳定 99% | 稳定 30% |
| UserContext 实例数 | ~10万 | ~50 |
| 应用运行时间 | <24h OOM | 稳定运行 |

## 五、常见 OOM 类型与排查要点

| OOM 错误 | 原因 | 排查方向 |
|---------|------|---------|
| `Java heap space` | 堆内存不足 | 对象泄漏 / 堆太小 |
| `GC overhead limit exceeded` | GC 无效，回收 <2% 堆 | 内存泄漏（GC 白忙） |
| `Metaspace` | 元空间溢出 | 动态类加载 / CGLIB 代理 |
| `Direct buffer memory` | 堆外内存泄漏 | DirectByteBuffer / Netty |
| `Unable to create new native thread` | 线程数超限 | 线程泄漏 / ulimit |
| `Requested array size exceeds VM limit` | 数组太大 | 集合无限增长 |

## 六、预防措施

```bash
# 生产环境 JVM 参数最佳实践
java -Xms4g -Xmx4g \
     -XX:+HeapDumpOnOutOfMemoryError \
     -XX:HeapDumpPath=/var/log/heapdump.hprof \
     -XX:MetaspaceSize=256m \
     -XX:MaxMetaspaceSize=256m \
     -XX:+PrintGCDetails \
     -XX:+PrintGCDateStamps \
     -Xloggc:/var/log/gc.log \
     -jar myapp.jar
```

**代码层面：**
- ✅ 使用 try-finally / try-with-resources 管理资源
- ✅ ThreadLocal 使用后必须 remove
- ✅ 静态集合设置淘汰策略或用 Guava Cache
- ✅ 内部类使用 static 避免持有外部引用
- ✅ 自定义 Key 覆写 hashCode 和 equals
- ✅ 使用连接池参数 `max-active` 限制最大连接数

## 七、面试常见追问

**Q：出问题后为什么先重启而不是排查？**

A：生产环境**先止损再根因**。重启恢复服务是第一优先级，dump 文件保留后慢慢分析。

**Q：jmap -dump:live 和普通 dump 的区别？**

A：`live` 参数会先触发一次 Full GC，只 dump 存活对象。dump 文件更小，分析更快，但丢失了泄漏对象的信息。排查泄漏建议用**不 live 的 dump**，可以看清泄漏的分布。

**Q：Metaspace 泄漏常见于什么场景？**

A：动态代理（CGLIB）、热部署、Groovy 脚本动态编译。Metaspace 存的是类的元数据，GC 回收条件苛刻——需要类加载器被回收。

---

*内存泄漏排查是 Java 高级开发必备的救命技能。熟练使用 MAT/jprofiler 和合理的 JVM 参数配置，能在关键时刻找回数小时甚至数天的排障时间。*
