---
title: Java 性能调优实战：从 JVM 到代码优化
date: 2026-06-15 23:30:00
tags:
  - Java
  - 性能调优
  - JVM
  - GC
categories:
  - Java
author: 东哥
---

# Java 性能调优实战：从 JVM 到代码优化

> 性能调优是后端工程师的核心技能。本文从 JVM 内存调优、GC 优化、代码微优化、工具使用四个维度，系统梳理 Java 性能调优的方法论和实战技巧。

## 一、性能调优方法论

### 1.1 调优原则

```
调优 ≠ 炫技，请遵循以下原则：
1. 先测量，后优化（没有数据就没有真相）
2. 避免过早优化（大部分瓶颈不在你想象的地方）
3. 从全局出发（不要为了局部性能牺牲整体）
4. 以业务指标为准（TP99、吞吐量、可用性）
```

### 1.2 性能指标

| 指标 | 含义 | 黄金法则 |
|------|------|----------|
| TP99 | 99% 的请求在 Xms 内完成 | 互联网服务 < 200ms |
| TP999 | 99.9% 的请求在 Xms 内完成 | < 1s |
| QPS/TPS | 每秒查询/事务数 | 越高越好 |
| GC 暂停 | 垃圾回收导致的停顿 | 单次 < 50ms |
| 内存占用 | 堆内存使用量 | 不频繁 Full GC |
| CPU 使用率 | CPU 繁忙程度 | 平均 < 80% |
| IO 等待 | 磁盘/网络 IO 等待时间 | 越低越好 |

## 二、JVM 内存调优

### 2.1 堆内存配置

```bash
# 基础 JVM 参数（8GB 内存服务器）
-Xms4g                    # 初始堆大小
-Xmx4g                    # 最大堆大小
-Xmn2g                    # 新生代大小
-XX:MetaspaceSize=256m    # 元空间
-XX:+UseG1GC              # G1 垃圾回收器

# 详细配置
-XX:SurvivorRatio=8       # Eden:Survivor = 8:1:1
-XX:MaxTenuringThreshold=15  # 晋升老年代年龄
```

### 2.2 G1 调优参数

```bash
# G1 专用参数
-XX:MaxGCPauseMillis=50      # 期望 GC 暂停时间
-XX:G1HeapRegionSize=4m      # Region 大小（1-32MB）
-XX:InitiatingHeapOccupancyPercent=45  # 触发并发标记的堆占用率
-XX:G1MixedGCLiveThresholdPercent=85    # Mixed GC 阈值
-XX:G1NewSizePercent=5                  # 新生代比例
-XX:G1ReservePercent=15

# G1 日志
-Xlog:gc*:gc.log:time,uptime,level,tags
```

### 2.3 内存泄漏排查

```java
// 典型的内存泄漏场景
public class MemoryLeakExample {
    private static final List<byte[]> CACHE = new ArrayList<>();
    
    public void leak() {
        while (true) {
            CACHE.add(new byte[1024 * 1024]);  // 不断增长
            Thread.sleep(100);
        }
    }
}
```

**排查步骤：**
```bash
1. jps -l            # 找到进程 PID
2. jmap -heap PID     # 查看堆内存使用
3. jmap -histo PID    # 查看对象统计
4. jmap -dump:live,format=b,file=heap.hprof PID  # 生成堆转储
   # 分析工具：MAT / JProfiler / VisualVM
5. jstack PID         # 线程快照
```

## 三、GC 优化实战

### 3.1 GC 算法选择

| 场景 | 推荐 GC | 说明 |
|------|---------|------|
| 单机小堆 (<4G) | Serial/Parallel | 简单高效 |
| 多核大堆 (4-32G) | G1 | 平衡吞吐和延迟 |
| 超大堆 (>32G) | Shenandoah/ZGC | 亚毫秒级暂停 |
| 低延迟要求 | ZGC | 暂停 < 10ms |

### 3.2 G1 GC 日志分析

```
2026-06-15T10:00:00.000+0800: [GC pause (G1 Evacuation Pause)
  (young), 0.0234567 secs]
  [Parallel Time: 20.0 ms]
   [GC Worker Start (ms):  1000.0  1010.0  ...]
   [Ext Root Scanning (ms):  2.0  2.5  ...]
   [Update RS (ms):  1.5  1.8  ...]
   [Scan RS (ms):  3.0  2.9  ...]
   [Code Root Scanning (ms):  0.0  0.1  ...]
   [Object Copy (ms):  12.0  11.5  ...]
   [GC Worker End (ms):  1020.0  1020.5  ...]
   [GC Worker Other (ms):  1.0  0.9  ...]
  [Eden: 1024M(1024M)->0.0B(1024M) Survivors: 128M->128M]
  [Heap: 2048M(4096M)->1024M(4096M)]
  [Pause Time: 23.4 ms]
```

**关键指标解读：**
- `Pause Time`：暂停时间，目标 < 50ms
- `Object Copy`：对象复制时间，过大说明存活对象多
- `Eden: 1024M->0.0B`：Eden 区完全清空，正常

### 3.3 Full GC 排查

```bash
# Full GC 触发原因
[Full GC (Metadata GC Threshold) ...  # 元空间不足
[Full GC (Ergonomics) ...             # 并行 GC 内部决定
[Full GC (System.gc()) ...            # 代码显式调用
[Full GC (Allocation Failure) ...     # 老年代空间不足

# 优化思路
1. 增大新生代：-Xmn
2. 调整晋升阈值：-XX:MaxTenuringThreshold
3. 降低并发标记阈值：-XX:InitiatingHeapOccupancyPercent
4. 增大总堆内存
```

## 四、代码层面优化

### 4.1 字符串优化

```java
// ❌ 差：循环拼接字符串
String s = "";
for (int i = 0; i < 10000; i++) {
    s += i;  // 每次创建新对象，O(N²)
}

// ✅ 好：使用 StringBuilder
StringBuilder sb = new StringBuilder(10000);
for (int i = 0; i < 10000; i++) {
    sb.append(i);
}
String result = sb.toString();

// ✅ 更好：预估容量
StringBuilder sb = new StringBuilder(capacity);
```

### 4.2 集合优化

```java
// ✅ 指定初始容量
Map<String, User> map = new HashMap<>(1024);  // 避免 rehash
List<User> list = new ArrayList<>(500);

// ✅ 使用原始类型集合（避免装箱）
// 使用 fastutil / koloboke
IntList list = new IntArrayList();

// ✅ 避免在循环中调用 size() 方法
for (int i = 0; i < list.size(); i++) { }  // OK，ArrayList 的 size() 是 O(1)

// ❌ 频繁 resize
Map<String, String> map = new HashMap<>();  // 默认 16，频繁扩容
```

### 4.3 Stream 性能对比

```java
// 数据量 < 1000：for 循环最快
// 数据量 1000-10000：Stream 并行可能更快
// 数据量 > 10000：parallelStream 显著优势

// ❌ 小数据用并行流
smallList.parallelStream()  // 线程调度开销 > 收益

// ✅ 大数据用并行流
bigList.parallelStream()
    .filter(x -> x.getStatus() > 0)
    .map(User::getName)
    .collect(Collectors.toList());
```

### 4.4 锁优化

```java
// 1. 缩小锁范围
// ❌ 锁住整个方法
public synchronized void process() {
    // 100ms 非临界区代码
    count++;
    // 100ms 非临界区代码
}

// ✅ 只锁必要代码
public void process() {
    // 100ms 非临界区代码
    synchronized(this) {
        count++;
    }
    // 100ms 非临界区代码
}

// 2. 使用读写锁
private final ReadWriteLock lock = new ReentrantReadWriteLock();

public String read() {
    lock.readLock().lock();
    try { return data; } 
    finally { lock.readLock().unlock(); }
}

public void write(String value) {
    lock.writeLock().lock();
    try { this.data = value; } 
    finally { lock.writeLock().unlock(); }
}

// 3. CAS 替代锁
private final AtomicLong counter = new AtomicLong(0);
counter.incrementAndGet();  // 无锁并发安全
```

### 4.5 缓存优化

```java
// 1. 本地缓存（Caffeine）
Cache<Long, User> cache = Caffeine.newBuilder()
    .maximumSize(10000)
    .expireAfterWrite(10, TimeUnit.MINUTES)
    .recordStats()
    .build();

User user = cache.get(id, key -> userMapper.selectById(key));

// 2. 对象池（池化重对象）
// 使用 commons-pool2
GenericObjectPool<Connection> pool = new GenericObjectPool<>(factory);
```

## 五、性能监控工具

### 5.1 JDK 内置工具

```bash
# jps：查看 Java 进程
jps -lvm

# jstat：GC 统计（关键！）
jstat -gcutil PID 1000 10     # 每秒输出 GC 信息
# 输出：S0 S1 E O M CCS YGC YGCT FGC FGCT CGC CGCT GCT

# jmap：内存映射
jmap -heap PID                # 堆配置和使用情况
jmap -histo:live PID | head   # 存活对象统计

# jstack：线程快照
jstack PID | grep -A 10 "BLOCKED"  # 死锁检测

# jcmd：综合诊断
jcmd PID VM.native_memory summary  # NMT 查看
jcmd PID GC.heap_info              # 堆信息
jcmd PID Thread.print              # 线程 dump
```

### 5.2 火焰图

```bash
# 使用 async-profiler
# CPU 火焰图
profiler.sh -e cpu -d 30 -f cpu.html PID

# 分配采样火焰图
profiler.sh -e alloc -d 30 -f alloc.html PID

# 锁火焰图
profiler.sh -e lock -d 30 -f lock.html PID
```

## 六、数据库层面的优化

### 6.1 连接池配置

```yaml
# HikariCP 最佳实践
spring:
  datasource:
    hikari:
      maximum-pool-size: 20      # 核心池大小
      minimum-idle: 5            # 最小空闲
      connection-timeout: 5000   # 连接超时
      idle-timeout: 300000       # 空闲超时
      max-lifetime: 1200000      # 最大生命周期
```

### 6.2 SQL 优化

```sql
-- ❌ 差：SELECT *
SELECT * FROM orders WHERE user_id = 100;

-- ✅ 好：只查需要的字段
SELECT id, order_no, amount FROM orders WHERE user_id = 100;

-- 批量操作
-- ❌ 差：逐条插入
INSERT INTO orders (...) VALUES (...);  -- N 次
INSERT INTO orders (...) VALUES (...);  -- N 次

-- ✅ 好：批量插入
INSERT INTO orders (user_id, amount) VALUES
(1, 100), (2, 200), (3, 300);  -- 1 次

-- 分页优化（深分页）
-- ❌ 差
SELECT * FROM orders LIMIT 100000, 20;

-- ✅ 好：游标分页
SELECT * FROM orders WHERE id > 100000 ORDER BY id LIMIT 20;
```

## 七、全链路压测

### 7.1 压测工具

```bash
# Apache JMeter（GUI 压测）
jmeter -n -t test.jmx -l result.jtl

# wrk（HTTP 压测）
wrk -t12 -c400 -d30s http://localhost:8080/api

# ab（简单压测）
ab -n 10000 -c 100 http://localhost:8080/api
```

### 7.2 压测指标解读

```
Requests per second:    4821.37 [#/sec] (mean)
Time per request:       20.744 [ms] (mean)
Transfer rate:          1024.00 [Kbytes/sec]

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.5      1      10
Processing:    10   19   5.2     18     200
Waiting:        8   15   4.1     14     180
Total:         10   20   5.3     19     210

Percentage of the requests served within a certain time (ms)
  50%     19
  66%     21
  75%     23
  80%     25
  90%     30     ← TP90
  95%     35     ← TP95
  98%     50     ← TP98
  99%     65     ← TP99
 100%    210
```

## 八、总结

Java 性能调优是一个系统工程，建议按照以下步骤进行：

1. **建立基线**：先跑一次压测，收集关键指标
2. **识别瓶颈**：用工具定位到底是 CPU、内存、IO 还是锁
3. **分层优化**：代码 → JVM → 数据库 → 架构
4. **效果验证**：优化后重新压测对比
5. **监控上线**：接入 Prometheus + Grafana 持续监控

记住一句话：**不要猜测性能瓶颈，测量它。**
