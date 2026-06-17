---
title: JVM 生产环境性能调优实战：案例、工具与参数精讲
date: 2026-06-17 13:00:00
tags:
  - JVM
  - 性能调优
  - GC
  - OOM
  - Java
categories:
  - Java
author: 东哥
---

# JVM 生产环境性能调优实战：案例、工具与参数精讲

## 一、JVM 调优的本质

JVM 调优的核心目标不是"把 GC 延迟降到 0"——这是不可能的。真正的目标是在**可用资源范围内**，找到 GC 频率、GC 停顿时间和吞吐量之间的最优平衡。

### 1.1 调优三角

```
        吞吐量
        ▲
       /|\
      / | \
     /  |  \
    /   |   \
   /    |    \
  ────────────► 低延迟
        \
         \
          \
           ▼
         内存占用
```

三种指标互斥：**不能既要吞吐高、又要延迟低、还要内存省。**

| 场景 | 优先级排序 | 调优方向 |
|------|-----------|---------|
| 在线交易系统 | 延迟 > 吞吐 > 内存 | G1 / ZGC，减少 STW |
| 批处理系统 | 吞吐 > 内存 > 延迟 | Parallel GC，拉大堆内存 |
| 流式计算 | 吞吐 > 延迟 > 内存 | G1 / Parallel，调优新生代 |
| 微服务（边缘） | 内存 > 延迟 > 吞吐 | 减小堆内存，ZGC |

## 二、GC 选型对比

### 2.1 主流 GC 参数对比

| GC | 适用场景 | JDK 版本 | STW 时间 | 吞吐量 | 核心参数 |
|----|---------|----------|---------|-------|---------|
| Serial | 单核、小内存 | 任意 | 长 | 低 | -XX:+UseSerialGC |
| Parallel | 批处理、关注吞吐 | 任意 | 短 | 高 | -XX:+UseParallelGC |
| CMS | 老年代低延迟 | 8 废弃、9 删除 | 短 | 中 | -XX:+UseConcMarkSweepGC |
| G1 | 大堆、平衡 | 8u40+ | 可预测 | 高 | -XX:+UseG1GC |
| ZGC | 超大堆、极低延迟 | 11u+ (15+ 生产) | < 1ms | 中高 | -XX:+UseZGC |
| Shenandoah | 超大堆、低延迟 | 12+ | < 10ms | 中高 | -XX:+UseShenandoahGC |

### 2.2 G1 GC 深度解析

G1（Garbage First）是 JDK 9 以后的默认 GC，将堆划分为 2048 个 Region，每个 Region 在 1-32MB 之间：

```
┌─────────────────────────────────────────────────────┐
│  Region 布局（G1 Heap）                               │
├────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬───┤
│ E  │ E  │ S  │ E  │ E  │ O  │ O  │ H  │ H  │ O  │ E │
├────┼────┼────┼────┼────┼────┼────┼────┼────┼────┼───┤
│ E  │ O  │ O  │ S  │ E  │ O  │ O  │ E  │ E  │ O  │ S │
├────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴───┤
│ E = Eden  |  S = Survivor  |  O = Old  |  H = Humongous │
└─────────────────────────────────────────────────────┘
```

**G1 关键参数调优：**

```bash
# 基础堆设置
-Xms8g -Xmx8g                 # 堆大小（建议设置相等避免动态调整）
-XX:+UseG1GC                  # 使用 G1（JDK 9+ 默认）

# 目标停顿时间
-XX:MaxGCPauseMillis=200      # 目标最大停顿时间（默认 200ms）
                              # 设置越小，GC 越频繁，吞吐越低

# Region 大小
-XX:G1HeapRegionSize=4m       # Region 大小（1-32MB）
                              # 大堆用大 Region，小堆用小 Region

# 新生代调优
-XX:G1NewSizePercent=5        # 新生代初始占比（默认 5%）
-XX:G1MaxNewSizePercent=60    # 新生代最大占比（默认 60%）

# 混合 GC 调优
-XX:InitiatingHeapOccupancyPercent=45  # 触发并发标记的堆占用（默认 45%）
-XX:G1MixedGCLiveThresholdPercent=85   # 混合 GC 存活对象阈值
-XX:G1MixedGCCountTarget=8            # 混合 GC 目标次数
```

### 2.3 ZGC 实战

ZGC 是 JDK 11 引入的极低延迟 GC，STW 时间控制在 1ms 以内，且不随堆大小增长。

```bash
# ZGC 配置（JDK 17+ 生产推荐）
-Xms16g -Xmx16g
-XX:+UseZGC

# 并发线程数
-XX:ConcGCThreads=4           # 默认：CPU 核数的 12.5%

# ZGC 关键调优
-XX:SoftMaxHeapSize=12g       # 软最大堆（给 GC 一些缓冲空间）
-XX:ZAllocationSpikeTolerance=2.0  # 分配尖峰容忍度（默认 2.0）

# 每 10 分钟主动 GC 防止碎片（ZGC 建议）
-XX:ZUncommitDelay=600        # 600 秒后归还未使用内存给 OS
```

## 三、性能监控工具

### 3.1 命令行工具全家桶

```bash
# 1. jps —— 查看 Java 进程
jps -lvm

# 2. jstat —— GC 统计
jstat -gcutil <pid> 1000 10   # 每秒输出一次，共 10 次

# 输出解读:
# S0    S1    E      O      M     YGC    YGCT   FGC    FGCT   GCT
# 0.00  0.00  45.23  28.56  92.1  142    2.345  3      0.456  2.801
# S0/S1: Survivor 使用率
# E: Eden 使用率
# O: Old 使用率
# M: Metaspace 使用率
# YGC/YGCT: Young GC 次数/时间
# FGC/FGCT: Full GC 次数/时间

# 3. jstack —— 线程 Dump
jstack -l <pid> > threaddump.txt

# 4. jmap —— 堆 Dump
jmap -dump:live,format=b,file=heap.hprof <pid>

# 5. jcmd —— 综合诊断（JDK 8+）
jcmd <pid> VM.flags              # JVM 参数
jcmd <pid> VM.uptime             # 运行时间
jcmd <pid> GC.heap_info          # 堆信息
jcmd <pid> Thread.print          # 线程 Dump
jcmd <pid> VM.native_memory      # NMT (需开启 NativeMemoryTracking)
```

### 3.2 可视化工具

| 工具 | 用途 | 说明 |
|------|------|------|
| VisualVM | 综合分析 | JDK 自带，实时监控 |
| JMC (Java Mission Control) | 飞行记录 | JDK 11+ 单独下载 |
| GCeasy | GC 日志分析 | 在线工具 |
| MAT (Memory Analyzer) | 堆分析 | Eclipse 出品 |
| arthas | 在线诊断 | 阿里巴巴开源 |

### 3.3 Arthas 实战

```bash
# 启动 Arthas
java -jar arthas-boot.jar <pid>

# 常用命令
dashboard                    # 实时面板（线程、内存、GC）
thread -n 3                  # 最忙的 3 个线程
thread -b                    # 阻塞的线程（死锁检测）
sc -d com.example.OrderService  # 查看类信息
watch com.example.OrderService getOrder '{params,returnObj}' -x 2
                              # 观察方法入参和返回值
trace com.example.OrderService getOrder
                              # 方法调用链路耗时
monitor com.example.OrderService getOrder -c 5
                              # 每 5 秒监控方法调用
```

## 四、内存泄漏排查实战

### 4.1 OOM 类型

| OOM 类型 | 原因 | 特征 |
|---------|------|------|
| Java heap space | 堆内存满了 | 大对象/内存泄漏 |
| GC overhead limit exceeded | 98% 时间花在 GC | GC 死循环 |
| Direct buffer memory | 直接内存不足 | NIO/Buffer 泄漏 |
| Metaspace | 元空间满了 | 类加载器泄漏 |
| Unable to create new native thread | 线程数超限 | 线程泄漏 |

### 4.2 实战案例

**案例：ThreadLocal 内存泄漏**

```java
// 错误用法
public class UserContext {
    private static final ThreadLocal<User> currentUser = new ThreadLocal<>();
    
    public static void set(User user) {
        currentUser.set(user);
    }
    
    public static User get() {
        return currentUser.get();
    }
}

// 线程池中 ThreadLocal 持有用户对象不释放
// → 线程复用，ThreadLocalMap 中的 Entry 一直引用着 User
// → User 对象无法被 GC → OOM
```

**排查步骤：**

```bash
# Step 1: 查看 OOM 时堆占用
jstat -gcutil <pid> 2000 5

# Step 2: 获取堆 Dump
jmap -dump:live,format=b,file=heap.hprof <pid>

# Step 3: MAT 分析
# 打开 heap.hprof → Leak Suspects Report
# 查看 Biggest Objects → 按 retained heap 排序
# 定位到 ThreadLocal 相关的对象
```

**解决方案：**

```java
public class UserContext {
    private static final ThreadLocal<User> currentUser = new ThreadLocal<>();
    
    public static void set(User user) {
        currentUser.set(user);
    }
    
    public static User get() {
        return currentUser.get();
    }
    
    public static void clear() {
        currentUser.remove();  // 必须 remove()
    }
}

// 在 Filter 中确保每个请求结束时清理
@Component
public class UserContextFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request, ServletResponse response, 
                          FilterChain chain) throws IOException, ServletException {
        try {
            chain.doFilter(request, response);
        } finally {
            UserContext.clear();  // 确保清理
        }
    }
}
```

## 五、GC 日志分析

### 5.1 GC 日志配置

```bash
# G1 GC 日志（JDK 11+）
-Xlog:gc*:file=/logs/gc-%t.log:time,uptime,level,tags:filecount=10,filesize=20M

# JDK 8 G1 GC 日志（传统方式）
-XX:+PrintGCDetails
-XX:+PrintGCDateStamps
-XX:+PrintGCTimeStamps
-XX:+PrintAdaptiveSizePolicy
-XX:+UseGCLogFileRotation
-XX:NumberOfGCLogFiles=10
-XX:GCLogFileSize=20M
-Xloggc:/logs/gc.log
```

### 5.2 日志解读

```
[2026-06-17T10:15:30.123+0800][gc,start] GC(12) Pause Young (Normal) (G1 Evacuation Pause)
[2026-06-17T10:15:30.456+0800][gc,phases]   GC(12)   Pre Evacuate Collection Set: 0.5ms
[2026-06-17T10:15:30.457+0800][gc,phases]   GC(12)   Evacuate Collection Set: 32.1ms
[2026-06-17T10:15:30.459+0800][gc,phases]   GC(12)   Post Evacuate Collection Set: 1.8ms
[2026-06-17T10:15:30.459+0800][gc,phases]   GC(12)   Other: 0.6ms
[2026-06-17T10:15:30.459+0800][gc,stats ]   GC(12)   E: 512.0M->0.0B(512.0M)
[2026-06-17T10:15:30.459+0800][gc,stats ]   GC(12)   S: 64.0M->64.0M(64.0M)
[2026-06-17T10:15:30.459+0800][gc,stats ]   GC(12)   O: 3.2G->3.5G(8.0G)
[2026-06-17T10:15:30.459+0800][gc,stats ]   GC(12)   Metaspace: 256.0M->256.0M(512.0M)
[2026-06-17T10:15:30.459+0800][gc,cpu    ]   GC(12)   User=0.12s Sys=0.03s Real=0.035s
```

需要关注的指标：
- **Pause time**：STW 停顿时间（35ms，健康）
- **User/Real 比**：User >> Real 表示多线程 GC 有效
- **O 区增长**：老年代从 3.2G → 3.5G，增长正常
- **Metaspace**：稳定则没有类加载泄漏

## 六、调优案例实战

### 6.1 案例一：接口偶尔超时

**现象**：JVM 配置 8G 堆（-Xms8g -Xmx8g），接口正常时 50ms，但偶尔有 1-2s 超时。

**排查**：
```bash
# 查看 GC 统计
jstat -gcutil <pid> 2000
# 发现每 10-15 秒有一次 FGC，耗时 1.5-2s
```

**分析**：CMS 并发模式失败（Concurrent Mode Failure），老年代在 CMS 完成前就满了。

**修复**：
```bash
# 原参数
-Xms8g -Xmx8g -XX:+UseConcMarkSweepGC

# 新参数：
-Xms8g -Xmx8g -XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:ParallelGCThreads=8
-XX:ConcGCThreads=4
```

**结果**：G1 替代 CMS 后，最长停顿降低到 180ms，消除了超时。

### 6.2 案例二：Full GC 频繁

**现象**：生产环境 Full GC 每 5 分钟一次，系统响应变慢。

**排查**：
```bash
jcmd <pid> GC.heap_info
# 老年代几乎满了，但存活对象只有 30%

jmap -dump:live,format=b,file=heap.hprof <pid>
# MAT 分析发现大量 HashMap$Node 对象
```

**原因**：业务代码中使用了 `ConcurrentHashMap` 作为本地缓存，没有设置过期时间，大量数据堆积到老年代。

**修复**：改用 Caffeine 缓存并设置过期策略。

### 6.3 案例三：Metaspace OOM

**现象**：部署新版本后，运行几小时出现 Metaspace OOM。

**分析**：每次热部署或动态代理创建新的类加载器，旧加载器未被回收。

**修复**：
```bash
-XX:MaxMetaspaceSize=256m
-XX:+TraceClassLoading
-XX:+TraceClassUnloading
```
找到泄漏点后，修正类加载器未关闭的问题。

## 七、JVM 参数速查表

```bash
# ========== 通用参数 ==========
-server                                  # 服务器模式（默认）
-Xms4g -Xmx4g                            # 初始/最大堆（建议相等）
-Xss256k                                 # 线程栈大小（默认1M，可减至256k）
-XX:MetaspaceSize=256m                   # 元空间大小
-XX:MaxMetaspaceSize=256m                # 元空间最大大小
-XX:+AlwaysPreTouch                      # 启动时预占内存（减少运行时缺页）
-XX:+HeapDumpOnOutOfMemoryError          # OOM 时自动 Dump
-XX:HeapDumpPath=/logs/heapdump.hprof    # Dump 路径
-XX:+PrintCommandLineFlags               # 打印最终生效的 JVM 参数

# ========== 错误排查 ==========
-XX:+ExitOnOutOfMemoryError              # OOM 时自动退出
-XX:ErrorFile=/logs/hs_err_pid%p.log     # JVM Crash 日志
-XX:+CrashOnOutOfMemoryError             # OOM 时生成 Crash 文件
```

JVM 调优不是玄学，而是一项有方法可循的系统工程。核心思想是：**明确目标 → 监控现状 → 定位瓶颈 → 调整参数 → 验证效果**。熟练使用工具、理解 GC 原理、掌握常用参数，就能应对绝大多数生产性能问题。
