---
title: 【生产实战】Java 应用 CPU 100% 问题排查实战：从定位到根治
date: 2026-07-02 08:00:00
tags:
  - Java
  - JVM
  - 性能调优
  - 运维
categories:
  - Java
  - 性能调优
author: 东哥
---

# 【生产实战】Java 应用 CPU 100% 问题排查实战：从定位到根治

## 概述

CPU 100% 是 Java 生产环境最常见的高危告警之一。应用响应变慢、请求超时、服务雪崩……背后往往都是 CPU 被打满。本文系统梳理 CPU 100% 的排查流程、十种典型案例和根治方案。

## 一、排查工具箱一览

| 阶段 | 工具 | 用途 | 定位速度 |
|------|------|------|----------|
| 快速定位 | `top` / `htop` | 找到 CPU 最高的进程 | ⚡ 秒级 |
| 线程定位 | `top -Hp` | 找到 CPU 最高的线程 | ⚡ 秒级 |
| 线程栈 | `jstack` | 查看线程正在执行的代码 | ⏱ 分钟级 |
| 火焰图 | `async-profiler` | 可视化热点方法 | 🔥 最直观 |
| 在线诊断 | Arthas | 动态追踪，无需重启 | 🚀 秒级 |
| 性能剖析 | JMC / JProfiler | 完整性能分析 | 📊 全面 |

## 二、六步排查法（标准流程）

### Step 1：找到 CPU 最高的进程

```bash
# top 命令，按 CPU 降序
top -c

# 或者只看一次，过滤 Java
top -b -n 1 | grep java
```

输出示例：
```
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
12345 admin     20   0 4584796 1.5g  25648 S 350.0  18.9 123:45.67 java -Xmx2g -jar app.jar
```

**关键信息：** PID = 12345，CPU = 350%（多核总和）

### Step 2：查看进程中 CPU 最高的线程

```bash
# 查看指定进程的线程 CPU 占用
top -Hp 12345
```

输出示例：
```
  PID USER      PR  NI    VIRT    RES    SHR S %CPU  %MEM     TIME+  COMMAND
12399 admin     20   0 4584796 1.5g  25648 R 98.3  18.9  45:12.34 java
12400 admin     20   0 4584796 1.5g  25648 R 97.1  18.9  44:56.78 java
```

发现线程 12399 和 12400 两个线程 CPU 接近 100%。

### Step 3：将线程 ID 转为十六进制

```bash
# 线程 ID 转十六进制（jstack 中用十六进制）
printf "%x\n" 12399
# 输出：306f

printf "%x\n" 12400
# 输出：3070
```

### Step 4：使用 jstack 查看线程栈

```bash
# 获取线程快照
jstack 12345 > /tmp/threaddump_$(date +%Y%m%d_%H%M%S).log

# 或者直接查看指定线程
jstack 12345 | grep -A 30 "0x306f"
```

**输出分析：**

```
"http-nio-8080-exec-10" #30 daemon prio=5 os_prio=0 tid=0x00007f...
   java.lang.Thread.State: RUNNABLE
    at java.util.regex.Matcher.find(Matcher.java:706)
    at java.util.regex.Pattern$GroupHead.match(Pattern.java:4804)
    at java.util.regex.Pattern$Branch.match(Pattern.java:4726)
    at java.util.regex.Matcher.find(Matcher.java:706)
    at com.example.service.ValidationService.validate(ValidationService.java:45)
    at com.example.controller.UserController.login(UserController.java:30)
    ...
```

🔥 **发现：** 线程卡在正则 `Matcher.find()` 中，典型的**灾难性回溯**。

### Step 5：使用 Arthas 在线诊断

```bash
# 启动 Arthas
curl -O https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar 12345

# 在 Arthas 控制台中：
# 1. 查看最忙碌的线程
thread -n 5

# 2. 分析热点方法
profiler start
# ... 等待 30 秒 ...
profiler stop --format html

# 3. 查看方法调用耗时
trace com.example.service.ValidationService validate
```

### Step 6：生成火焰图

```bash
# 使用 async-profiler 生成火焰图
./profiler.sh -d 30 -f /tmp/flamegraph.svg 12345

# 火焰图解读：
# - 顶部表示当前正在执行的方法
# - 宽度表示该方法的 CPU 占用时间比例
# - 颜色无特殊含义（通常暖色为 Java，冷色为系统）
```

## 三、十大典型案例分析

### 案例 1：正则灾难性回溯

**症状：** CPU 周期性飙升，请求高延迟。

**定位：** `jstack` 发现多个线程卡在 `Matcher.find()` 或 `Pattern$Curly.match`。

**根因：**

```java
// 问题代码
@Pattern(regexp = "^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$")
private String username;

// 输入：大量的连续字母+特殊字符，触发回溯爆炸
```

**修复：**

```java
// 使用原子组防止回溯
@Pattern(regexp = "^[A-Za-z0-9]+(?>[._-][A-Za-z0-9]+)*$")
```

### 案例 2：死循环/无限循环

**症状：** CPU 一直 100%，线程状态为 RUNNABLE。

**定位：** `jstack` 看到某个线程一直在同一个方法内循环。

```java
// 问题代码
public Result process(Order order) {
    while (order.getStatus() != OrderStatus.PAID) {
        // 没有 sleep 也没有等待条件变化！
        // 自旋空转，占满 CPU
    }
    return doPay(order);
}
```

**修复：**

```java
public Result process(Order order) throws InterruptedException {
    // 方案一：加上合适的等待
    while (order.getStatus() != OrderStatus.PAID) {
        Thread.sleep(100); // 避免空转
        order = orderRepository.findById(order.getId());
    }
    
    // 方案二：使用 CountDownLatch/CompletableFuture 等待
    return doPay(order);
}
```

### 案例 3：频繁 Full GC

**症状：** CPU 高，但 `top -Hp` 看线程 CPU 不高，`top` 整体 CPU 高。

**定位：** 使用 `jstat -gcutil`：

```bash
jstat -gcutil 12345 1000 5

  S0     S1     E      O      M     YGC     YGCT    FGC    FGCT     GCT
  0.00   0.00   98.2   99.8   95.3   3456    78.45   231   345.67   424.12
```

**发现：** FGC（Full GC 次数）231 次，FGCT（Full GC 耗时）345 秒！

Full GC 的标记-压缩阶段需要扫描整个堆，虽然 GC 线程是 **CPU 密集型** 操作，但 `top -Hp` 看到的是 GC 线程而非业务线程消耗 CPU。

**修复：** 调整堆大小、排查内存泄漏。

### 案例 4：序列化/JSON 处理瓶颈

**症状：** 大对象需要频繁序列化/反序列化，CPU 高。

```java
// 问题代码：每次请求都序列化整个大对象
public String buildBigResponse() {
    BigData data = loadBigData();
    return JSON.toJSONString(data); // 数据量巨大！
}
```

**修复：**

```java
// 方案一：缓存序列化结果
@Cacheable(value = "bigData", key = "#root.methodName")
public String buildBigResponse() {
    BigData data = loadBigData();
    return JSON.toJSONString(data);
}

// 方案二：使用字段过滤
@JSONField(serialize = false) // 忽略不需要的字段
private String largeField;

// 方案三：流式输出
@Override
public void writeTo(OutputStream out) {
    // 使用流式 JSON 输出，减少内存占用
}
```

### 案例 5：大量的日志打印

**日志框架本身可能消耗大量 CPU，尤其是在 ERROR 级别下打印完整的堆栈。**

```java
try {
    // 业务代码
} catch (Exception e) {
    // ❌ 热点代码里频繁打日志
    // 每秒钟打印几千次，包括完整的堆栈信息
    logger.error("Processing failed for order: " + orderId, e);
}
```

**修复：**

```java
try {
    // 业务代码
} catch (Exception e) {
    // ✅ 低频、控制日志量
    if (logger.isDebugEnabled()) {
        logger.debug("Processing failed: {}", orderId, e);
    }
    // 或者使用采样日志
    if (counter.incrementAndGet() % 100 == 0) {
        logger.error("Processing failed (sampled): {}", orderId, e);
    }
}
```

### 案例 6：非预期的加密操作

```java
// RSA 私钥解密（CPU 密集型操作）
for (int i = 0; i < 10000; i++) {
    Cipher cipher = Cipher.getInstance("RSA");
    cipher.init(Cipher.DECRYPT_MODE, privateKey);
    cipher.doFinal(data);  // 巨慢！
}
```

**修复：** 
- 使用对称加密（AES）代替非对称加密
- 缓存 `Cipher` 实例（线程局部变量）
- 使用内存缓存减少加密次数

### 案例 7：无限创建线程

```java
// ❌ 每个请求都新建线程
new Thread(() -> doHeavyWork()).start();

// 线程创建和销毁消耗大量 CPU
// 线程数过多后上下文切换也消耗 CPU
```

**修复：** 使用线程池复用线程。

### 案例 8：大并发下的 HashMap 死循环

JDK 7 中 `HashMap` 在多线程扩容时可能形成环形链表，导致 `get()` 死循环。

```java
HashMap<String, Object> map = new HashMap<>(); // ❌ 不是线程安全的！

// 多个线程并发 put 触发 resize → 死循环
```

**修复：** 使用 `ConcurrentHashMap`。

### 案例 9：大量数学计算

```java
// BigDecimal 使用字符串构造（慢！）
BigDecimal result = new BigDecimal("0.1")
    .multiply(new BigDecimal("0.2"))
    .divide(new BigDecimal("0.3"), 10, RoundingMode.HALF_UP);
```

**优化：**

```java
// 使用常量缓存
private static final BigDecimal ONE_TENTH = new BigDecimal("0.1");

// 合理使用 valueOf（Cache 了 [-128, 128] 范围）
BigDecimal result = BigDecimal.valueOf(0.1)
    .multiply(BigDecimal.valueOf(0.2));
```

### 案例 10：JIT 编译开销

应用刚启动时，**JIT 编译器** 会占用大量 CPU。`-XX:+PrintCompilation` 可以查看编译情况。正常现象，但如果：

- 反复提交较大的方法（`-XX:CompileThreshold` 过小）
- 逃逸分析失败导致大量内联失效
- 代码缓存区满导致撤销编译（`CodeCache is full`）

**优化：** 预热、调整 CodeCache 大小。

## 四、Arthas 实战技巧

### 4.1 一键定位 CPU 最高线程

```bash
# 在 Arthas 中执行
thread -n 5

# 输出：
# 线程名称                         CPU占用    状态
# http-nio-8080-exec-10            43.2%      RUNNABLE
# "scheduling-1"                   12.1%      TIMED_WAITING
```

### 4.2 追踪方法调用耗时

```bash
# 查看方法调用栈及耗时
trace com.example.service.UserService login
# 输出每个调用的耗时明细

# 按耗时排名
stack com.example.service.UserService login -n 5
```

### 4.3 火焰图

```bash
# 生成 CPU 火焰图
profiler start
# 等待 30-60 秒
profiler stop --format html -o /tmp/flamegraph.html
```

## 五、容器环境下的特殊排查

### 5.1 容器 CPU 限制感知

K8s 下的 Java 应用默认可能忽略容器 CPU 限制：

```yaml
# 容器资源限制
resources:
  limits:
    cpu: "2"
  requests:
    cpu: "1"
```

```bash
# Java 8u131+ / Java 10+ 支持容器CPU感知
-XX:+UseContainerSupport
-XX:ActiveProcessorCount=2
```

### 5.2 Java 8 容器环境特别配置

```bash
# JDK 8u131+ 支持
-XX:+UnlockExperimentalVMOptions
-XX:+UseCGroupMemoryLimitForHeap
-XX:+PrintFlagsFinal | grep UseContainer
```

## 六、预防性配置

### JVM 参数

```bash
# 生产必备 JVM 参数
-Xms4g -Xmx4g
-XX:+UseG1GC
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/data/dumps/
-XX:+PrintGCDetails
-XX:+PrintGCDateStamps
-Xloggc:/data/gc/gc.log
-XX:+UseContainerSupport
-XX:ActiveProcessorCount=4
```

### 监控告警

```bash
# Prometheus 告警规则
- alert: HighCPUUsage
  expr: process_cpu_usage > 0.8
  for: 5m
  annotations:
    summary: "{{ $labels.instance }} CPU usage > 80%"
```

## 七、面试官追问

> Q1：jstack 常用于排查哪些类型的 CPU 问题？

- **RUNNABLE 状态**：正常执行业务代码，看是否死循环或热点方法
- **BLOCKED 状态**：锁竞争激烈，CPU 花在线程调度上
- **TIMED_WAITING**：线程池配置不当导致频繁创建/销毁线程

> Q2：为什么 CPU 高但 jstack 抓不到热点线程？

可能原因：JIT 编译的 C2/GC 线程在短时间内执行完热点代码（jstack 是快照，没抓到执行点）。建议多抓几次或使用 `async-profiler` 持续采样。

> Q3：CPU 100% 和 I/O 密集型的区分？

查看 `top -Hp` 中线程的 CPU 占用比例。如果很多线程 CPU > 80% 说明是 **CPU 密集型**；如果大量线程处于 WAITING/BLOCKED 而 CPU < 30% 说明是 **I/O 密集型**。

> Q4：Full GC 为什么会导致 CPU 飙升？

Full GC 涉及：标记（Mark）、扫描（Scan）、清除（Sweep）、压缩（Compact）四个阶段，其中标记和压缩阶段需要遍历/移动大量对象。GC 线程本身就是 CPU 密集型的。另外 CMS 的并发标记阶段也会占用多核 CPU。

## 八、结语

CPU 100% 问题排查的核心是 **定位热点代码**。善用辅助工具，按标准流程一步步来，绝大多数问题可以在 15 分钟内找到根因。

**排查口诀：**
- `top` 看进程 → `top -Hp` 看线程 → `printf "%x"` 转十六进制
- `jstack` 看线程栈 → `Arthas` 看热点方法 → 修复代码

**一句话总结：CPU 飙高别慌，先看 jstack 在哪跑。**
