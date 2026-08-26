---
title: 【JVM 实战】JDK 命令行工具全家桶：jps、jstat、jmap、jstack、jcmd 实战详解
date: 2026-08-26 08:00:00
tags:
  - Java
  - JVM
  - 性能调优
  - 运维
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 实战】JDK 命令行工具全家桶：jps、jstat、jmap、jstack、jcmd 实战详解

## 面试官：线上 Java 服务 CPU 飙高、内存暴涨、接口卡死，你手上只有命令行工具，怎么排查？

生产环境往往没有图形界面、没有 IDE，甚至没有 Arthas（很多公司不允许随便装 agent）。这时候 **JDK 自带的命令行工具**就是你最可靠的武器——它们是 JDK 的一部分，**零依赖、随处可用**。

本文把最核心的 6 个命令讲透：**jps、jstat、jmap、jstack、jcmd、jinfo**，每个都配合真实排查场景，最后一节给出一套"线上故障排查 SOP"。

## 一、工具总览

| 命令 | 全称/作用 | 核心用途 | 常用场景 |
|------|----------|---------|---------|
| jps | Java Process Status | 查看 Java 进程 | 找到目标 PID |
| jstat | JVM Statistics Monitoring | JVM 统计信息 | GC、类加载、编译监控 |
| jmap | JVM Memory Map | 堆内存映像 | 堆信息、堆转储、OOM 定位 |
| jstack | Java Stack Trace | 线程堆栈 | 死锁、CPU 高、线程卡死 |
| jcmd | JVM Command | 多功能诊断 | 全家桶的"瑞士军刀" |
| jinfo | JVM Configuration Info | JVM 配置 | 查看/修改 VM 参数 |

> 注意：JDK 9+ 这些工具都在 `bin/` 下；JDK 8 及以前部分工具路径是 `jre/bin/` 或需要 `JAVA_HOME` 环境变量。另外 jmap/jstack 在 JDK 9+ 对**本地进程**仍可用，对远程进程需开 JMX 或改用 jcmd。

## 二、jps：一切排查的起点

```bash
# 查看本机所有 Java 进程
$ jps -l
12345 com.example.OrderApplication
23456 org.apache.catalina.startup.Bootstrap
```

常用参数：

| 参数 | 说明 |
|------|------|
| `-l` | 显示完整主类名或 jar 路径（最常用） |
| `-v` | 显示传给 JVM 的启动参数（可看到 -Xmx、-D 等） |
| `-m` | 显示 main 方法参数 |
| `-q` | 只显示 PID |

```bash
$ jps -lv
12345 com.example.OrderApplication -Xmx2g -Xms2g -Dspring.profiles.active=prod
```

**实战意义**：一眼看出哪个 Java 进程是谁、启动参数配了什么，排查"为什么这个服务内存这么小"先看这里。

## 三、jstat：GC 与类加载的实时监控

jstat 是**监控 JVM 运行状态**的头号工具，尤其是 GC。

### 3.1 查看 GC 情况

```bash
# 每 1 秒采样一次，连续 10 次
$ jstat -gcutil 12345 1000 10
  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
  0.00  99.84  45.20  78.34  92.11  88.50   1287   12.345    23    8.901   21.246
```

字段解读（`-gcutil` 显示**百分比**）：

| 字段 | 含义 | 报警信号 |
|------|------|---------|
| S0/S1 | Survivor 区使用率 | 长期 100% 且频繁 GC → 对象在幸存区来回拷贝 |
| E | Eden 区使用率 | 长期高位 → 对象分配快 |
| O | 老年代使用率 | **持续增长不回落 → 内存泄漏信号** |
| M | 元空间使用率 | 持续增长 → 动态生成类过多（反射/CGLIB 泄漏） |
| YGC/YGCT | Young GC 次数/耗时 | YGCT 飙升 → 新生代过小或对象分配过频 |
| FGC/FGCT | Full GC 次数/耗时 | **FGC 频繁 → 重大故障信号** |

### 3.2 查看堆分区容量

```bash
$ jstat -gccapacity 12345
 NGCMN    NGCMX     NGC     S0C   S1C       EC      OGCMN      OGCMX       OGC         OC      MCMN     MCMX      MC
 87040.0 1398272.0 1398272.0 46592.0 46592.0 1299456.0   174080.0  2796544.0  1048576.0  1048576.0      0.0 1075200.0 155648.0
```

### 3.3 实战判断：Full GC 频繁

```bash
$ jstat -gcutil 12345 2000 5
  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
  0.00   0.00  12.30  99.86  90.20  86.10   5012   78.121    456  320.445  398.566
```

老年代 99.86%、FGC 456 次且 FGCT 很大 → **老年代被打满，Full GC 基本停摆**。下一步用 jmap 看堆里是什么对象。

## 四、jmap：堆内存的 X 光机

### 4.1 查看堆概要

```bash
$ jmap -heap 12345
Heap Configuration:
   MinHeapFreeRatio         = 40
   MaxHeapFreeRatio         = 70
   MaxHeapSize              = 2147483648 (2048.0MB)
   NewSize                  = 891289600 (850.0MB)
   ...
Heap Usage:
PS Young Generation
Eden Space:
   capacity = 1333788672 (1272.0MB)
   used     = 1200891904 (1145.2MB)
   free     = 132896768 (126.8MB)
   90.03% used
PS Old Generation
   capacity = 805306368 (768.0MB)
   used     = 792985600 (756.2MB)
   free     = 12320768 (11.8MB)
   98.46% used
```

### 4.2 查看对象直方图（定位内存泄漏神器）

```bash
# 按对象实例数/占用空间排序，取前 20
$ jmap -histo:live 12345 | head -20

 num     #instances         #bytes  class name
----------------------------------------------
   1:        523,410    187,146,080  [B
   2:        412,880    165,152,000  [C
   3:      1,025,406     82,032,480  com.example.cache.OrderCache$CacheEntry
   4:        230,117     61,000,000  java.util.HashMap$Node
   5:         45,120     50,534,400  [Ljava.lang.Object;
```

**排查思路**：如果 `OrderCache$CacheEntry` 这种业务对象占了几个 GB，且数量持续增长 → 定位到缓存类没有清理逻辑（比如往 Map 里 put 但不淘汰）。如果全是 `[B`（byte[]）和 `[C`（char[]），多半是字符串/IO 缓冲泄漏。

### 4.3 生成堆转储（heap dump）

```bash
# 生成 hprof 文件（会 STW，谨慎在生产高峰期执行！）
$ jmap -dump:format=b,file=/tmp/heap_12345.hprof 12345

# 更推荐：用 jcmd，可指定只 dump live 对象，文件更小
$ jcmd 12345 GC.heap_dump /tmp/heap_12345.hprof
```

dump 出来的文件用 **MAT / JVisualVM** 分析，能看到支配树、泄漏嫌疑（Leak Suspects）。`-histo:live` 和 `-dump:live` 会先触发一次 Full GC，生产环境慎用，建议用不带 `live` 的版本或错峰执行。

## 五、jstack：线程的"心电图"

### 5.1 导出线程快照

```bash
# 导出所有线程的堆栈
$ jstack 12345 > /tmp/thread_12345.txt

# 统计线程状态分布（快速判断是否大量阻塞）
$ jstack 12345 | grep -E "java.lang.Thread.State" | sort | uniq -c
     32 java.lang.Thread.State: RUNNABLE
      8 java.lang.Thread.State: TIMED_WAITING (parking)
      5 java.lang.Thread.State: WAITING (parking)
      3 java.lang.Thread.State: BLOCKED
      1 java.lang.Thread.State: WAITING (on object monitor)
```

### 5.2 实战场景一：定位 CPU 100% 的线程

```bash
# 1. 找到 CPU 占用最高的线程 PID（注意是"线程的十进制 PID"）
$ top -Hp 12345
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
23456 root      20   0 27.5g 3.2g  12m R 99.7   8.0   152:33.32 java

# 2. 转成十六进制（jstack 里线程 ID 是十六进制）
$ printf "%x\n" 23456
5ba0

# 3. 在 jstack 输出里搜这个十六进制线程 ID
$ jstack 12345 | grep -A 30 "nid=0x5ba0"
"http-nio-8080-exec-12" #89 daemon prio=5 os_prio=0 cpu=...
   java.lang.Thread.State: RUNNABLE
        at com.example.service.OrderService.calculatePrice(OrderService.java:88)
        at com.example.service.OrderService.getOrderDetail(OrderService.java:120)
        ...
        at sun.misc.Unsafe.park(Native Method)   # 或看到正则回溯、死循环等
```

**经典结论**：`RUNNABLE` + 业务代码 + 自旋/循环 → 死循环或正则灾难性回溯；`WAITING (parking)` 大量 → 线程池队列堆积或锁等待。

### 5.3 实战场景二：定位死锁

```bash
$ jstack 12345 | grep -A 20 "Found one Java-level deadlock"
Found one Java-level deadlock:
=============================
"Thread-A":
  waiting to lock monitor 0x00007f (object 0x00000000d5a0, a java.lang.Object),
  which is held by "Thread-B"
"Thread-B":
  waiting to lock monitor 0x00007f (object 0x00000000d5b0, a java.lang.Object),
  which is held by "Thread-A"

Java stack information for the threads listed above:
===================================================
```

jstack 会**自动检测并打印死锁**，连锁的持有关系都给你理清楚了，直接改代码顺序即可。

### 5.4 实战场景三：接口卡死/无响应

连续抓 3 次线程快照（间隔 3 秒），对比看哪些线程**一直没动**：

```bash
for i in 1 2 3; do jstack 12345 > /tmp/jstack_$i.txt; sleep 3; done
# 对比：同一个线程 ID 三次都停在同一个方法 → 该处阻塞
```

常见阻塞点：数据库连接池耗尽（`WAITING` 在 `HikariPool.getConnection`）、HTTP 调用无超时、分布式锁未释放。

## 六、jcmd：新一代诊断瑞士军刀

JDK 7+ 引入，JDK 9+ 推荐用它替代部分 jmap/jstack 功能，因为 **jcmd 是官方主推的诊断入口**，且对进程的侵入更可控。

```bash
# 列出所有可用命令
$ jcmd 12345 help

# 查看 JVM 版本与启动参数
$ jcmd 12345 VM.version
$ jcmd 12345 VM.flags            # 查看最终生效的 VM 参数（含默认值）
$ jcmd 12345 VM.command_line     # 查看原始启动命令行

# 系统属性
$ jcmd 12345 VM.system_properties

# 触发 GC
$ jcmd 12345 GC.run

# 堆转储（比 jmap -dump 更推荐）
$ jcmd 12345 GC.heap_dump /tmp/heap_12345.hprof

# 线程转储（替代 jstack）
$ jcmd 12345 Thread.print

# 查看 GC 统计（替代 jstat -gc 的即时版）
$ jcmd 12345 GC.class_histogram
```

**jcmd vs jmap/jstack**：

| 对比 | jcmd | jmap/jstack |
|------|------|-------------|
| 官方推荐度 | JDK 9+ 主推 | 仍可用，部分功能 deprecated |
| 远程进程 | 需 JMX | 老工具支持（已弱化） |
| 功能覆盖 | 全能（含 VM 参数、系统属性、perf 数据） | 单点功能 |
| 内存 dump | `GC.heap_dump` | `-dump` |

## 七、jinfo：查看与修改运行参数

```bash
# 查看所有 VM 参数
$ jinfo 12345

# 查看单个参数
$ jinfo -flag MaxHeapSize 12345
-XX:MaxHeapSize=2147483648

# 动态修改部分可热调参数（JDK 8+，仅限可写标志）
$ jinfo -flag +PrintGCDetails 12345
```

**注意**：大部分参数（如 -Xmx）**不能**运行时修改，能改的只有标记为"manageable"的标志（如某些 GC 日志开关、`-XX:+HeapDumpOnOutOfMemoryError` 等）。查看哪些可改：

```bash
$ java -XX:+PrintFlagsFinal -version | grep manageable
```

## 八、线上故障排查 SOP（一套组合拳）

### 场景 A：CPU 飙高

```bash
top -Hp <pid>            # 1. 找 CPU 最高的线程（十进制）
printf "%x\n" <tid>      # 2. 转十六进制
jstack <pid> > dump.txt  # 3. 抓线程快照
grep "nid=0x..." dump.txt # 4. 定位代码行
```

### 场景 B：内存暴涨 / OOM

```bash
jstat -gcutil <pid> 1000 5   # 1. 看 GC 与老年代趋势
jmap -histo <pid> | head     # 2. 看对象分布
jcmd <pid> GC.heap_dump /tmp/a.hprof  # 3. 抓堆转储
# 4. MAT 分析 Leak Suspects
```

### 场景 C：接口无响应 / 假死

```bash
jstack <pid> > dump1.txt; sleep 3; jstack <pid> > dump2.txt
# 对比两次快照中停滞的线程
grep -E "WAITING|BLOCKED" dump1.txt | sort | uniq -c
```

### 场景 D：服务启动就挂 / 参数怀疑

```bash
jps -lv                 # 看启动参数
jinfo <pid>             # 看生效参数
jcmd <pid> VM.flags     # 核对最终配置
```

## 九、最佳实践与注意事项

1. **生产环境不要乱用 `-histo:live` 和 `-dump:live`**：会触发 Full GC 造成 STW，高峰期慎用。
2. **jmap/jstack 会短暂暂停 JVM**（依赖安全点），抓快照本身有轻微开销，批量抓取注意错峰。
3. **堆转储文件很大**（≈堆大小），先确认磁盘空间，dump 后立即压缩或转移。
4. **老年代持续上升 + FGC 频繁**是内存泄漏的典型双信号，配合 `-verbose:gc` 日志交叉验证。
5. **容器环境注意**：在 Docker/K8s 里执行 `jps` 看不到宿主机其他进程属正常；确认以**与业务进程相同的用户**执行（常见权限问题）。
6. **JDK 8 与 11+ 输出格式有差异**（如 GC 名字：PSYoungGen vs G1 Young Generation），别被吓到。
7. **善用 jcmd 替代**：新项目统一用 jcmd，它是 Oracle 官方推荐的统一入口。

## 十、面试追问汇总

1. **CPU 100% 排查完整流程？** top -Hp → 转十六进制 → jstack → 定位代码（见场景 A）。
2. **jmap -histo 和 -dump 区别？** histo 是对象直方图（轻量），dump 是完整堆快照（重量，可离线分析）。
3. **怎么看内存泄漏？** jstat 看老年代持续增长 + jmap -histo 看业务对象数量爆炸 + MAT 确认 GC Root 引用链。
4. **jstack 里 BLOCKED 和 WAITING 区别？** BLOCKED 是等 synchronized 锁（竞争激烈）；WAITING 是等通知（park/wait/join）。
5. **Full GC 频繁怎么查？** jstat -gcutil 确认 FGC 频率 → jmap -histo 看大对象 → 检查代码中大对象分配、缓存无界、连接池泄漏。
6. **jcmd 相比 jmap/jstack 的优势？** 统一入口、功能更全、官方主推、可查看 VM 参数与系统属性。

## 总结

这套命令行工具是 Java 开发者的**基本功**：`jps` 找进程、`jstat` 看 GC、`jmap` 查内存、`jstack` 诊线程、`jcmd` 全能替代、`jinfo` 调参数。建议每个工具都亲手在测试环境跑一遍，把"CPU 高、内存涨、接口卡"三个经典场景的 SOP 练熟——线上出问题时，这几条命令就是你的救命稻草。
