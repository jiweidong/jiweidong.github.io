---
title: 【生产实战】Java 线程 Dump 分析：从线程快照到性能问题定位
date: 2026-07-17 08:00:00
tags:
  - Java
  - 性能优化
  - Java故障排查
categories:
  - Java
  - Java基础
author: 东哥
---

# 【生产实战】Java 线程 Dump 分析：从线程快照到性能问题定位

## 引言：为什么需要线程 Dump？

线上 Java 应用出现以下问题时，线程 Dump 是你最有力的武器：

- ❌ **CPU 100%** —— 哪个线程在狂转？
- ❌ **系统卡死/无响应** —— 线程在等什么？
- ❌ **死锁** —— 哪些线程互相等待？
- ❌ **请求堆积** —— 线程池是否耗尽了？
- ❌ **接口响应慢** —— 是卡在 I/O 还是业务逻辑？

**线程 Dump**（又称线程快照、Thread Dump）就是 JVM 在某个时刻对所有线程状态的"快照"。它是**非侵入式**的，对生产环境几乎没有影响，是排查线上问题的首选手段。

## 一、获取线程 Dump 的 5 种方式

### 1.1 jstack（最常用）

```bash
# 先找到 Java 进程ID
jps -l
# 或
ps aux | grep java

# 获取线程 Dump
jstack -l <pid> > threaddump.txt
```

参数说明：
- `-l`：显示锁信息（LockInfo），分析死锁必加
- `-e`：显示详细信息

### 1.2 jcmd（JDK 8+ 推荐）

```bash
# JDK 8u40+ 推荐使用
jcmd <pid> Thread.print > threaddump.txt
```

`jcmd` 是 JDK 内置的诊断命令，统一了多种诊断操作：

```bash
jcmd <pid> help       # 查看所有可用命令
jcmd <pid> Thread.print -l   # 打印线程信息（带锁）
```

### 1.3 kill -3（Linux）

```bash
kill -3 <pid>
```

线程 Dump 会输出到 JVM 的标准输出（stdout），通常在应用日志中可以找到。此方式无需额外工具，但输出不易控制。

### 1.4 JMX 远程获取

通过 JMX 连接：

```java
// 代码方式
MBeanServerConnection mbsc = ManagementFactory
    .getPlatformMBeanServer();
ThreadMXBean threadMxBean = ManagementFactory
    .newPlatformMXBeanProxy(mbsc, 
        ManagementFactory.THREAD_MXBEAN_NAME, 
        ThreadMXBean.class);
ThreadInfo[] threadInfos = threadMxBean.dumpAllThreads(true, true);
```

### 1.5 VisualVM / Arthas

```bash
# Arthas 方式
thread -n 5          # 查看最忙碌的前5个线程
thread -b            # 查看 BLOCKED 的线程（检测死锁）
thread <threadId>    # 查看指定线程的栈信息
```

## 二、线程 Dump 结构解析

一个典型的线程 Dump 包含如下内容：

```
2026-07-17 08:00:00
Full thread dump OpenJDK 64-Bit Server VM (24.0+36 mixed mode, sharing):

"http-nio-8080-exec-10" #30 daemon prio=5 os_prio=0 cpu=12.34ms elapsed=456.78s tid=0x00007f8c28002800 nid=0x1a2b runnable  [0x00007f8c1b7fe000]
   java.lang.Thread.State: RUNNABLE
    at java.util.HashMap.getNode(java.base@24.0/HashMap.java:559)
    at java.util.HashMap.get(java.base@24.0/HashMap.java:555)
    at com.example.service.UserServiceImpl.getUser(UserServiceImpl.java:45)
    at com.example.controller.UserController.getUser(UserController.java:20)
    at jdk.internal.reflect.DirectMethodHandleAccessor.invoke(java.base@24.0/DirectMethodHandleAccessor.java:103)
    ... 省略 Spring AOP 代理调用 ...
    Locked ownable synchronizers:
    - <0x000000076b8e9a28> java.util.concurrent.ThreadPoolExecutor$Worker (a java.util.concurrent.locks.AbstractQueuedSynchronizer)
```

### 各部分含义

| 字段 | 示例 | 含义 |
|------|------|------|
| 线程名称 | `http-nio-8080-exec-10` | 线程标识名，Tomcat 线程池命名规则 |
| 线程类型 | `daemon` | 是否守护线程 |
| 优先级 | `prio=5` | Java 线程优先级 |
| OS 优先级 | `os_prio=0` | 操作系统优先级 |
| CPU 时间 | `cpu=12.34ms` | 该线程累积 CPU 时间（关键指标！） |
| 存活时间 | `elapsed=456.78s` | 线程存活秒数 |
| 线程 ID | `tid=0x00007f8c28002800` | JVM 内部线程 ID |
| 本地线程 ID | `nid=0x1a2b` | 操作系统线程 ID（对应 top -H 的 PID） |
| 状态 | `runnable` | 线程状态 |
| 栈地址 | `[0x00007f8c1b7fe000]` | 线程栈的内存地址范围 |

### 线程状态（重要！）

```
NEW          —— 新建，未启动
RUNNABLE     —— 正在运行 或 就绪等待 CPU 调度
BLOCKED      —— 等待锁（被其他线程持有）
WAITING      —— 无限期等待（Object.wait() 无超时）
TIMED_WAITING —— 有时间限制的等待
TERMINATED   —— 已结束
```

**⚠️ 注意**：`RUNNABLE` 不等于"正在使用 CPU"！它可能正在等待 I/O（如网络读取、磁盘读取）。

## 三、常见问题排查实战

### 案例1：CPU 100% 排查

**现象**：线上服务器 CPU 飙升到 100%，接口响应极慢。

**排查步骤**：

```bash
# 第1步：找到 Java 进程
top

# 第2步：查看进程内各线程的 CPU 使用（-H 表示线程级别）
top -Hp <pid>

# 第3步：找到 CPU 占用最高的线程，记录 PID（假设为 6688）
# 第4步：将 PID 转为十六进制（nid 匹配用）
printf "%x\n" 6688
# 输出：1a20

# 第5步：获取线程 Dump
jstack -l <pid> > dump.txt

# 第6步：在 dump 中搜索 nid=0x1a20
cat dump.txt | grep -A 30 "nid=0x1a20"
```

**实战代码示例——死循环场景**：

```java
// 问题代码：HashMap 在并发 resize 时可能产生死循环（JDK 7）
public class HashMapDeadLoop {
    private static final Map<String, String> map = new HashMap<>();
    
    public static void main(String[] args) {
        // 多个线程并发 put 触发 resize，导致循环链表
        for (int i = 0; i < 100; i++) {
            new Thread(() -> {
                while (true) {
                    map.put(Thread.currentThread().getName(), "value");
                }
            }).start();
        }
    }
}
```

**线程 Dump 分析**：
```
"Thread-23" #23 daemon prio=5 cpu=9865.12ms elapsed=10.23s tid=... nid=0x1a20 runnable
  java.lang.Thread.State: RUNNABLE
    at java.util.HashMap.put(HashMap.java:611)
    at java.util.HashMap.putVal(HashMap.java:632)
    at com.example.HashMapDeadLoop.lambda$main$0(HashMapDeadLoop.java:15)
    ...
```

**看到什么**：`cpu=9865.12ms` 在 10 秒内跑了近 10 秒 CPU → **这个线程在疯狂计算**。

**解决方案**：使用 `ConcurrentHashMap` 替代 `HashMap`。

### 案例2：死锁检测

**现象**：系统卡死，部分接口完全无响应。

**排查**：

```bash
jstack -l <pid> | grep -A 20 "deadlock"
```

**输出示例**：

```
Found one Java-level deadlock:
=============================
"Thread-A":
  waiting to lock monitor 0x00007f8c2803a800 (object 0x000000076b8e1234, a java.lang.String)
  which is held by "Thread-B"

"Thread-B":
  waiting to lock monitor 0x00007f8c2803a900 (object 0x000000076b8e5678, a java.lang.String)
  which is held by "Thread-A"

Java stack information for the threads:
"Thread-A":
    at com.example.DeadLockService.methodA(DeadLockService.java:25)
    - waiting to lock <0x000000076b8e1234> (a java.lang.String)
    - locked <0x000000076b8e5678> (a java.lang.String)
"Thread-B":
    at com.example.DeadLockService.methodB(DeadLockService.java:40)
    - waiting to lock <0x000000076b8e5678> (a java.lang.String)
    - locked <0x000000076b8e1234> (a java.lang.String)
```

**jstack 自动做了死锁检测**，直接告诉你在哪、等什么锁、被谁持有。

**典型死锁代码**：

```java
public class DeadLockDemo {
    private static final String LOCK_A = "LockA";
    private static final String LOCK_B = "LockB";
    
    public static void main(String[] args) {
        new Thread(() -> {
            synchronized (LOCK_A) {
                sleep(100); // 确保另一个线程拿到 LOCK_B
                synchronized (LOCK_B) {
                    System.out.println("Thread A done");
                }
            }
        }, "Thread-A").start();
        
        new Thread(() -> {
            synchronized (LOCK_B) {
                synchronized (LOCK_A) {
                    System.out.println("Thread B done");
                }
            }
        }, "Thread-B").start();
    }
}
```

### 案例3：线程池耗尽分析

**现象**：请求大量超时，错误日志显示 ThreadPool 拒绝任务。

**线程 Dump 特征**：

```
"http-nio-8080-exec-1" #11 daemon prio=5 tid=... nid=... waiting for monitor entry
  java.lang.Thread.State: BLOCKED (on object monitor)
    at com.example.service.SlowService.findUser(SlowService.java:35)
    - waiting to lock <0x000000076b8e9999> (a java.util.HashMap)

"http-nio-8080-exec-2" #12 daemon prio=5 tid=... nid=... waiting for monitor entry
  java.lang.Thread.State: BLOCKED (on object monitor)
    at com.example.service.SlowService.findUser(SlowService.java:35)
    - waiting to lock <0x000000076b8e9999> (a java.util.HashMap)

// ... 几十个线程都在 waiting for the same lock ！
```

**分析结论**：
- 大量 Tomcat 工作线程都 **BLOCKED** 在同一个锁上
- 说明某个资源成为热点，串行化了所有请求
- 线程池被占满 → 新请求进不来 → 超时

**修复**：找到被锁定的 `findUser()` 方法，优化加锁范围或用读写锁/ConcurrentHashMap 替代。

### 案例4：数据库连接池耗尽

**现象**：接口响应极慢，数据库 CPU 正常但连接超时。

**线程 Dump 特征**：

```
"http-nio-8080-exec-5" #15 daemon prio=5 tid=... nid=... waiting on condition
  java.lang.Thread.State: TIMED_WAITING (parking)
    at jdk.internal.misc.Unsafe.park(Native Method)
    - parking to wait for  <0x000000076b8eaaaa> (a java.util.concurrent.locks.AbstractQueuedSynchronizer$ConditionObject)
    at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:196)
    at org.springframework.jdbc.datasource.DataSourceUtils...
```

**关键信号**：
- 状态：`TIMED_WAITING (parking)` — 在 `HikariPool.getConnection()` 等待
- 说明所有数据库连接都被占用了，新请求在排队等连接

**解决办法**：
1. 增大 HikariCP 最大连接数
2. 排查 SQL 慢查询，缩短事务时间
3. 检查是否存在连接泄漏（未正常释放）

## 四、线程 Dump 分析工具

### 4.1 在线分析工具

- **https://fastthread.io/** —— 上传 dump 自动分析，图表化展示
- **https://threadreaper.takipi.com/** —— 堆栈聚合分析
- **https://spotify.github.io/thread-dump-analyzer/** —— Spotify 开源工具

### 4.2 常用命令速查

```bash
# 统计各状态的线程数
grep "java.lang.Thread.State" dump.txt | sort | uniq -c

# 输出示例：
#  45 java.lang.Thread.State: RUNNABLE
#  12 java.lang.Thread.State: TIMED_WAITING (parking)
#   3 java.lang.Thread.State: BLOCKED
#   5 java.lang.Thread.State: WAITING (on object monitor)

# 查看所有 BLOCKED 线程
grep -B 5 "BLOCKED" dump.txt

# 查看带锁信息的死锁
grep -A 2 "deadlock" dump.txt

# 查看 WAITING 线程
grep -B 3 "WAITING (on object monitor)" dump.txt

# 找出 cpu 时间最高的线程（JDK 9+）
grep "cpu=" dump.txt | sort -t'=' -k2 -rn | head -10
```

### 4.3 Arthas 实时诊断

```bash
# 在 Arthas 中查看最耗 CPU 的线程
thread -n 5

# 查看线程池状态
thread --state BLOCKED

# 查看线程 ID 的完整堆栈（用十六进制 nid）
thread 0x1a2b
```

## 五、面试常见问答

**Q1：线程 Dump 和 Heap Dump 有什么区别？**

| 对比项 | Thread Dump | Heap Dump |
|--------|-------------|-----------|
| 数据内容 | 线程栈 + 锁信息 | 堆中所有对象 + 引用关系 |
| 文件大小 | 几十 KB | 几百 MB ~ GB |
| 获取速度 | 毫秒级 | 秒级，会 STW |
| 对生产影响 | 几乎无影响 | 较明显（GC Roots 遍历） |
| 解决问题 | 死锁、CPU 高、线程池问题 | OOM、内存泄漏 |

**Q2：获取线程 Dump 会对应用有影响吗？**

A：`jstack` 和 `kill -3` 只是在某个时刻对线程栈做快照，**不会触发 GC，不会 STW（Stop The World）**，对生产环境基本无影响。**可以放心在生产环境使用**。

**Q3：何时需要连续多次抓取 Dump？**

A：建议连续抓 3-5 次，每次间隔 5-10 秒。原因：
- 一次 Dump 只能看到某一瞬间的状态
- 通过多次对比，可以判断线程是一直 BLOCKED 还是瞬时状态
- 对于死锁检测，一次就能发现；对于热点锁，多次 Dump 能确认规律

**Q4：线程状态为 RUNNABLE 但为什么 CPU 不高？**

A：`RUNNABLE` 表示线程"可运行"，不是"正在使用 CPU"。当线程在**网络 I/O 读取**（如 Socket.read）或**磁盘 I/O** 时，也是 `RUNNABLE` 状态（因为底层系统调用被 Java 视为可运行）。真正判断 CPU 使用要看 `cpu=` 字段或通过 `top -H` 查看。

## 六、生产环境最佳实践

1. **事先开启 -XX:+PrintConcurrentLocks**：在线程 Dump 中包含更详细的锁信息
2. **不要等到故障才学分析**：在测试环境演练几次，熟悉常见模式
3. **用 Docker 时注意**：`jstack` 需在容器内执行或通过 `docker exec` 进入
4. **保留 Dump 文件**：事后归档到日志中心，便于根因分析
5. **配合监控使用**：在 CPU > 80% 时自动触发 Dump 抓取并保存
6. **JDK 9+ 的 `cpu=` 字段**非常有用，按时间排序即可找出最忙的线程

## 七、总结

线程 Dump 分析是 Java 开发者的**必备技能**，尤其在线上故障排查中：

1. **CPU 100%** → `top -H` 找到热点线程 → `jstack` 匹配 nid → 查看代码
2. **死锁** → `jstack -l` 自动检测，一目了然
3. **线程池耗尽** → 大量 BLOCKED/WAITING → 分析锁竞争或连接池
4. **请求慢** → 对比 Dump 找 WAITING/BLOCKED 热点

关键在于**读得懂栈帧，认得出模式**。建议在本地和测试环境多演练几次，到线上就不会慌了。
