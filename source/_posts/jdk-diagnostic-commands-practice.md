---
title: 【JVM 实战】JDK 自带诊断命令全攻略：jps、jstat、jmap、jstack、jinfo 与 jcmd 实战案例
date: 2026-08-31 08:00:00
tags:
  - JVM
  - 性能调优
  - 面试
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 实战】JDK 自带诊断命令全攻略：jps、jstat、jmap、jstack、jinfo 与 jcmd 实战案例

## 面试官：线上 Java 应用 CPU 飙高、内存暴涨，你第一反应用什么命令排查？

很多同学知道有 jstack、jmap 这些命令，但真到线上就只会重启。其实 JDK 自带的这几个诊断命令，**不需要装任何额外工具**，就能解决 80% 的线上问题。本文用真实场景带你逐个过一遍。

## 一、命令全家桶速览

| 命令 | 作用 | 常用场景 |
|------|------|---------|
| `jps` | 列出 Java 进程及主类 | 找到目标进程 PID |
| `jstat` | JVM 统计信息（GC、类加载、编译） | 观察 GC 频率、堆使用趋势 |
| `jmap` | 堆内存快照、堆直方图 | OOM 前看对象分布、导出 dump |
| `jstack` | 线程快照（线程栈） | CPU 飙高、死锁、线程阻塞 |
| `jinfo` | 查看/修改 JVM 参数 | 确认生效参数、打开 GC 日志 |
| `jcmd` | 多功能瑞士军刀 | 替代前面大部分命令 |

> ⚠️ 权限提醒：线上排查最好用与 Java 应用**相同的系统用户**执行，否则可能因权限不足报 `Unable to open socket file`；JDK 9+ 还可以配合 `-XX:+UsePerfData` 相关配置，但默认不用动。

## 二、jps：找到你的进程

```bash
$ jps -l
12345 com.example.demo.DemoApplication
23456 org.apache.catalina.startup.Bootstrap
$ jps -lv   # -l 完整类名，-v 显示传给 JVM 的参数
```

> 坑：`jps` 找不到进程？多半是进程是别的用户启动的，或容器里 PID namespace 隔离。可以用 `ps -ef | grep java` 兜底。

## 三、jstat：盯住 GC 和堆

jstat 是排查 GC 问题的第一工具，核心用法：

```bash
# 每 1000ms 输出一次 GC 统计，共 10 次
$ jstat -gcutil 12345 1000 10
  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
  0.00   0.00  68.24  45.12  92.31  88.12   1820    3.412     5    0.612    4.024
```

字段含义：

| 字段 | 含义 | 预警信号 |
|------|------|---------|
| S0/S1 | 两个 Survivor 区使用率 | 长期接近 100% 且对象不断晋升 → 检查晋升阈值 |
| E | Eden 使用率 | 频繁 0↔100 波动是正常的，持续高位说明分配压力大 |
| O | 老年代使用率 | **持续上升不回落 → 内存泄漏征兆** |
| M | 元空间使用率 | 持续增长 → 类加载器泄漏（热部署场景常见） |
| YGC/YGCT | Young GC 次数/耗时 | 次数暴涨 → 对象分配过快或 Eden 过小 |
| FGC/FGCT | Full GC 次数/耗时 | **FGC 频繁且 FGCT 大 → 严重问题，必须查** |

### 实战案例：老年代持续上涨

```
O: 40% → 55% → 70% → 85% → 92% → 95%（每次 FGC 后只回落到 90%+）
```

连续观察 30 分钟，老年代只升不降，Full GC 越来越频繁 → **基本可以判定存在内存泄漏**，下一步用 jmap 抓堆分析谁在泄漏。

## 四、jmap：看堆、导 dump

```bash
# 1. 堆直方图：按对象实例数/占用大小排序，快速定位"谁占内存"
$ jmap -histo:live 12345 | head -20

 num     #instances         #bytes  class name
----------------------------------------------
   1:        482312       27438120  [B
   2:        120003       21000528  com.example.cache.UserCache$Entry
   3:         80000       12800000  java.util.concurrent.ConcurrentHashMap$Node
   ...

# 2. 导出堆转储文件（生产慎用！会触发 Full GC 且停机会）
$ jmap -dump:format=b,file=/tmp/heap.hprof 12345
```

### 实战：直方图一眼看出泄漏

直方图里 `UserCache$Entry` 有 12 万个实例、占 21MB —— 而缓存理论上限是 1 万条。**说明缓存只进不出**，顺着代码找：是不是用了 `ConcurrentHashMap` 当缓存却没做淘汰？这就是泄漏点。

> ⚠️ 生产环境注意：`jmap -dump` 在 JDK 8 上会触发 **Full GC**，大堆（几十 GB）可能卡顿几十秒，务必低峰期执行。更安全的姿势：提前给应用加 `-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/data/dump/`，让 JVM 在 OOM 时自动留 dump，**自动 dump 不触发 Full GC，是生产首选**。

### 手动 dump 的替代：jcmd

```bash
$ jcmd 12345 GC.heap_dump /tmp/heap.hprof   # JDK 8u+ 支持，同样会 STW
```

## 五、jstack：线程在干什么

jstack 是排查**CPU 飙高、死锁、线程池打满**的利器：

```bash
$ jstack 12345 > /tmp/threads.txt
$ grep -A 20 "java.lang.Thread.State" /tmp/threads.txt
```

线程状态速查：

| 状态 | 含义 | 常见原因 |
|------|------|---------|
| RUNNABLE | 运行中（可能正在执行代码，也可能在等待 IO） | 正常/CPU 密集 |
| WAITING | 无限期等待（park、wait、join） | 线程池空闲、锁等待 |
| TIMED_WAITING | 有限期等待（sleep、wait(timeout)） | 定时任务、轮询 |
| BLOCKED | 阻塞在 synchronized 锁上 | **锁竞争激烈 → 性能瓶颈** |
| DEADLOCK | 检测到死锁 | 程序 bug，必须修复 |

### 实战 1：CPU 100% 定位（经典三板斧）

```bash
# ① 找到 CPU 最高的 Java 线程 PID（注意是进程内线程号）
$ top -Hp 12345
   PID USER  %CPU
  23456 root  99.5

# ② 转成十六进制（jstack 里的 nid 是十六进制）
$ printf '%x\n' 23456
5ba0

# ③ 在 jstack 输出里定位
$ jstack 12345 | grep -A 30 "nid=0x5ba0"
"http-nio-8080-exec-3" #27 daemon prio=5 os_prio=0 tid=0x... nid=0x5ba0 runnable
    at java.util.HashMap.getNode(HashMap.java:575)
    at com.example.service.OrderService.queryOrder(OrderService.java:88)
    ...
```

定位到 `OrderService.queryOrder` 第 88 行在 HashMap.get 上死循环/热点 → 打开代码，多半是**高并发下 HashMap 并发操作导致链表成环**（JDK 7 经典问题）或某算法复杂度退化。三板斧 30 秒定位问题，这就是 jstack 的价值。

### 实战 2：死锁检测

```bash
$ jstack 12345 | grep -A 15 "deadlock"
Found one Java-level deadlock:
"thread-B": waiting to lock monitor 0x... (object 0x..., a com.example.Account)
"thread-A": waiting to lock monitor 0x... (object 0x..., a com.example.Account)
```

jstack 会**自动检测并打印死锁**，直接把互相等待的锁对象指出来。配合 `jstack` 输出里两个线程的持有/等待关系，改代码方向非常明确。

### 实战 3：线程池被打满

大量 `WAITING (parking)` 的线程，堆栈都停在 `ThreadPoolExecutor.getTask()` —— 说明**线程池里全是空闲等待的线程**。如果任务队列还是满的、大量任务被拒绝，那就是任务积压：要么线程池太小，要么任务执行太慢（IO 阻塞、外部依赖超时）。

## 六、jinfo：查看/修改 JVM 参数

```bash
# 查看所有参数及生效值
$ jinfo -flags 12345
-XX:MaxHeapSize=2147483648 -XX:+UseG1GC ...

# 查看单个参数是否生效
$ jinfo -flag MaxMetaspaceSize 12345

# 动态开启 GC 日志（无需重启！）
$ jinfo -flag +PrintGCDetails 12345
$ jinfo -flag +PrintGCDateStamps 12345
```

> 场景：线上 GC 异常但当时没开 GC 日志？用 jinfo 动态打开，等复现后再关掉 —— 不用重启应用，完美。

## 七、jcmd：一个顶五个

jcmd 是 JDK 7+ 的「瑞士军刀」，用法：`jcmd <pid> <command>`：

```bash
$ jcmd 12345 help                          # 查看该 JVM 支持的所有命令
$ jcmd 12345 VM.version                    # 查看版本
$ jcmd 12345 VM.flags                      # 等价 jinfo -flags
$ jcmd 12345 GC.heap_info                  # 查看堆内存概况
$ jcmd 12345 GC.class_histogram            # 等价 jmap -histo
$ jcmd 12345 Thread.print                   # 等价 jstack
$ jcmd 12345 GC.heap_dump /tmp/heap.hprof  # 等价 jmap -dump
```

## 八、常见问题排查套路总结

| 现象 | 命令组合 | 思路 |
|------|---------|------|
| CPU 100% | top -Hp → jstack | 找到热点线程 → 定位代码行 |
| 内存持续上涨 | jstat -gcutil → jmap -histo | 确认老年代涨 → 看对象分布找泄漏 |
| 服务假死/请求无响应 | jstack | 看线程卡在什么锁/IO 上 |
| Full GC 频繁 | jstat -gcutil → jmap | 堆太小/泄漏/大对象 |
| 接口变慢 | jstack 多次采样 | 多次快照看线程在等什么 |
| 死锁 | jstack | 自动检测并打印 |
| 参数不确定 | jinfo -flags | 确认生效配置 |

## 面试高频追问清单

1. jstat 里哪些字段能预警内存泄漏？
2. jmap -dump 生产环境有什么风险？更安全的方式是什么？
3. 线程的 BLOCKED 和 WAITING 有什么区别？怎么从 jstack 判断锁竞争？
4. CPU 100% 的完整排查步骤是什么？
5. jinfo 能动态改哪些参数？改 JVM 参数需要重启吗？
6. 生产环境 Java 进程 PID 和容器 PID 对不上怎么办？（用 `jps` 在容器内执行，或 `nsenter` 进入容器命名空间）

## 小结

六个命令记住一个口诀：**jps 找人、jstat 看 GC、jmap 看堆、jstack 看线程、jinfo 改参数、jcmd 全都有**。线上问题不可怕，可怕的是只会重启。把这套命令练熟，你就能在面试官面前把「CPU 飙高排查」从 `top` 一路讲到 `jstack` 定位到具体代码行，这比背任何八股都加分。
