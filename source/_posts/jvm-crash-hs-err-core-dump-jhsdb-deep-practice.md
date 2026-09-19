---
title: 【JVM 实战】JVM 崩溃现场分析：hs_err_pid 日志、core dump 与 jhsdb 深度实战
date: 2026-09-19 08:10:00
tags:
  - Java
  - JVM
  - 线上排查
  - 性能调优
categories:
  - Java
  - JVM 实战
author: 东哥
---

# 【JVM 实战】JVM 崩溃现场分析：hs_err_pid 日志、core dump 与 jhsdb 深度实战

## 面试官：服务进程突然没了，日志里什么都没有，你怎么查？

这是线上最让人绝望的场景：没有任何业务异常日志，`docker ps` 里容器不见了，K8s 显示 `OOMKilled` 或者 `Exit Code 137`。大多数人第一反应是"重启一下试试"——然后同样的事故在一周后再次发生。

真正会排查的人，第一时间去找两样东西：**hs_err_pid 日志** 和 **core dump 文件**。前者是 JVM 自己写下的"临终遗言"，后者是整个进程内存的"遗体"。这篇文章把 JVM 崩溃分析的完整链路讲透，包括文件在哪、怎么读、怎么定位到代码。

## 一、JVM 崩溃的分类：先分清"谁杀了谁"

排查第一步是判断死亡类型，不同类型证据链完全不同：

| 类型 | 现象 | 关键证据 |
| --- | --- | --- |
| JVM 内部致命错误（SIGSEGV/SIGBUS） | 进程消失，产生 `hs_err_pid<n>.log` | hs_err 里的 Problematic frame |
| JVM 主动退出 | 日志有明确错误，退出码 1 | 应用日志 + OOM 信息 |
| 被 OS OOM Killer 杀死 | `dmesg` 有 `Out of memory: Kill process` | `Exit Code 137`，**没有** hs_err |
| 容器被 K8s 杀 | `OOMKilled` | `kubectl describe pod` 里的 Last State |
| Exit Code 134 | `System.exit` 被调用 / 崩溃 | 需区分是主动还是被动 |

**关键判据**：有 `hs_err_pid*.log` = JVM 自己崩了（Crash）；没有日志直接死 = 被外部杀（Kill）。这个区分决定了后面所有方向。

```bash
# 判断是否被 OS OOM Killer 杀掉
dmesg -T | grep -i -E "killed process|out of memory" | tail -20

# K8s 场景
kubectl describe pod <pod> | grep -A5 "Last State"

# 查找 hs_err 文件（注意容器里 JVM 默认写工作目录）
find / -name "hs_err_pid*.log" -mtime -1 2>/dev/null
```

**生产建议**：显式指定崩溃日志目录，避免容器重启后文件丢失：

```bash
java -XX:ErrorFile=/var/log/java/hs_err_%p.log \
     -XX:HeapDumpPath=/var/log/java/ \
     -XX:+HeapDumpOnOutOfMemoryError \
     -jar app.jar
```

## 二、解剖 hs_err_pid 日志：从头到尾读一遍

hs_err 文件的结构是固定的，按顺序读最高效。下面是一份真实文件的分段说明（这里用典型的 SIGSEGV 案例）。

### 头部：环境与崩溃摘要

```
# A fatal error has been detected by the Java Runtime Environment:
#
#  SIGSEGV (0xb) at pc=0x00007f8b2c41a3d9, pid=21847, tid=21902
#
# JRE version: OpenJDK Runtime Environment (17.0.9+9) (build 17.0.9+9)
# Java VM: OpenJDK 64-Bit Server VM (17.0.9+9, mixed mode, sharing)
# Problematic frame:
# J 3821 c2 com.example.trade.OrderMatcher.match(Ljava/util/List;)V
#
# Core dump will be written. Default location: /app/core.21847
```

信息密度极高：

- `SIGSEGV` 段错误 / `SIGBUS` 总线错误（常见于 mmap 文件被截断） / `SIGILL` 非法指令（常见于 CPU 指令集不兼容）。
- `Problematic frame` 是最关键的一行：
  - `J` = JIT 编译后的 Java 方法，`j` = 解释执行，`V` = VM 代码，`C` = 本地 C/C++ 代码，`v` = VM 生成的代码。
  - `c2` 说明这段代码被 C2 编译器优化过——**这往往是排查的转折点**。
  - 后面就是方法名与签名，直接指向嫌疑代码。

### 线程信息：崩溃的是哪个线程

```
---------------  T H R E A D  ---------------
Current thread (0x00007f8b1000b800):  JavaThread "pool-3-thread-7" ...
```

同时会打印**所有线程栈**（Native frames + Java frames）。两个用法：

1. 找 `Current thread` 的完整栈，看它当时在干什么。
2. 搜索 `Found one Java-level deadlock` 或看是否有大量线程卡在同一位置（可能是一致性问题导致的间接崩溃）。

### 堆与内存区域摘要

```
Heap:
 psyounggen      total 634880K, used 342112K [0x...)
  eden space 524288K, 65% used
  from space 110592K, 0% used
  to   space 110592K, 0% used
 paroldgen       total 1398144K, used 1123456K
Metaspace       used 128781K, capacity 131072K, committed 131072K, reserved 1114112K
```

**如果 Metaspace 的 used ≈ capacity ≈ reserved，极可能是类加载器泄漏**；如果堆 used 接近 total 且 `reserved` 也顶到上限，是内存不足（OOM 型崩溃）。

### 编译事件与代码缓存

```
Compilation events (10 events):
Event: 120.345 Thread 0x00007f8b0c1de800 3821  4  com.example...::match (836 bytes)
```

C2 刚编译完这个方法就崩了，**这就是最直接的嫌疑对象**。此时应对策略是：

```bash
# 1) 排除法：关掉该方法的 JIT 编译（-XX:CompileCommand）
java -XX:CompileCommand=exclude,com.example.trade.OrderMatcher::match -jar app.jar

# 2) 降低编译等级，看是否还崩
java -XX:-TieredCompilation ...
java -XX:TieredStopAtLevel=1 ...
```

如果加上 `-XX:CompileCommand=exclude` 后不再崩溃，基本可以确认是 JIT 编译器的问题（经典案例：某些 JDK 版本的 C2 向量化优化 bug）。处置：升级 JDK 小版本 / 换 `-XX:-UseCompressedOops` 等临时绕过。

### 内存映射与信号

```
Dynamic libraries:
...
Memory: 4k page, physical 16367488k(1234567k free), swap 0k(0k free)
```

`/proc/maps` 的完整快照。**某个库的地址范围被覆盖**、`swap` 为 0 且物理内存几乎占满是常见线索。macOS/Windows 的段也有对应段落。

## 三、Core Dump：JVM 的完整遗体

hs_err 是"摘要"，core dump 是"全部"。有了 core，就能用 `jhsdb` 做**死后验尸（post-mortem）**：看堆对象、看线程栈、看非堆内存，就像进程还活着一样。

### 开启 core dump

```bash
# 1) 解除 core 大小限制（容器内注意 ulimit 是宿主限制）
ulimit -c unlimited

# 2) 设置 core 文件名模式（带 pid 防覆盖）
echo '/var/log/java/core.%p' | sudo tee /proc/sys/kernel/core_pattern

# 3) JVM 侧：崩溃时生成 core（默认 -XX:+CreateCoredumpOnCrash 已开）
#    若为信号触发（如手动 kill -3 不产生 core）
java -XX:+CreateCoredumpOnCrash -XX:ErrorFile=/var/log/java/hs_err_%p.log -jar app.jar
```

**容器内三大坑**：
1. 容器默认 `ulimit -c 0`，必须显式设置；
2. `core_pattern` 若写成 `|/usr/share/apport/apport ...`（Ubuntu）会把 core 交给 apport 处理，文件不在预期位置；
3. 宿主 `core_pattern` 与容器 PID 命名空间不一致，core 会出现在宿主的 `/proc/1/root/` 下。

### 用 jhsdb 分析 core

`jhsdb` 是 JDK 9+ 整合的 Serviceability Agent 前端，是老 `jmap -dump`、`jstack` 在核心转储上的替代。

```bash
# 加载 core + java 可执行文件（版本必须匹配！）
jhsdb jmap --binaryheap --exe /usr/lib/jvm/java-17/bin/java \
           --core /var/log/java/core.21847 --dumpfile /tmp/heap.hprof

# 直接在 core 上执行 jstack
jhsdb jstack --exe $JAVA_HOME/bin/java --core /var/log/java/core.21847

# 查看堆摘要（相当于 jmap -heap）
jhsdb jmap --heap --exe $JAVA_HOME/bin/java --core /var/log/java/core.21847

# 查看对象直方图（相当于 jmap -histo，无需 dump 全堆）
jhsdb jmap --histo --exe $JAVA_HOME/bin/java --core /var/log/java/core.21847
```

拿到 `heap.hprof` 后用 MAT（Memory Analyzer）打开，就能用 OQL 查询对象引用链：

```sql
-- MAT OQL：查找所有大于 10MB 的 char[] 并回溯持有者
SELECT * FROM char[] t WHERE t.@retainedHeapSize > 1024*1024*10
```

### Serviceability Agent 的"活体检尸"

进程还活着但卡死时（比如 Stop-The-World 卡住、native 死锁），可以直接 attach：

```bash
# 对运行中的进程使用 SA（会挂起进程！生产慎用）
jhsdb jstack --pid 21847
jhsdb jmap --histo --pid 21847

# 查看本地内存映射
jhsdb jmap --permstat --pid 21847   # 类加载器统计，找泄漏的 ClassLoader
```

**强烈建议**：`jhsdb` 会 STW，生产上先 `-XX:+HeapDumpBeforeFullGC` 或用 `jcmd` 轻量采集，`jhsdb` 只作为最后手段。

## 四、崩溃排查的标准 SOP

把上面的知识串成一套可执行的流程，下次事发直接照做：

**第 1 步（1 分钟内）分清是 Crash 还是 Kill**

```bash
ls -lh /var/log/java/hs_err_pid*.log 2>/dev/null && echo "=== JVM 崩溃 ===" || echo "=== 被外部杀死 ==="
dmesg -T | grep -i "killed process" | tail -5
```

**第 2 步 若有 hs_err，先看 4 个位置**

```bash
ERR=/var/log/java/hs_err_pid21847.log
sed -n '1,30p' "$ERR"                       # 头部：信号 + Problematic frame
grep -n -A 30 "Current thread" "$ERR" | head -60   # 崩溃线程栈
grep -n -E "Metaspace|psyounggen|paroldgen|G1 |ZHeap" "$ERR"  # 内存
grep -c "^" "$ERR"; grep -n "Dynamic libraries" "$ERR"
```

判读口诀：
- `Problematic frame` 在 `V`/`v` → JVM 自身疑点（换 JDK 版本）；
- 在 `J` → 应用代码 + JIT 优化，先用 `CompileCommand=exclude` 验证；
- 在 `C` → 本地库（JNI、Netty epoll、gRPC、JDBC native）；重点查本地库版本与 `LD_LIBRARY_PATH`；
- 在 `j`/解释执行 → 更可能是 JVM bug 或堆损坏。

**第 3 步 若是被 Kill，属 OOM 型**

```bash
# 进容器看 cgroup 限制与实际用量
cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes
cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes
# JVM 是否感知容器限制
java -XX:+PrintFlagsFinal -version | grep -E "MaxHeapSize|UseContainerSupport"
```

**第 4 步 修复与验证**

- 调整 `-Xmx` 时**必须给堆外留足空间**：Netty DirectBuffer、Metaspace、线程栈、JIT 代码缓存、JNI 都会占本地内存。经验公式：`容器限制 ≈ 堆 * 1.3 + 512MB`（堆外大户另算）。
- 加 `-XX:MaxDirectMemorySize`、调小 `-Xss`、限制线程数，都是为了压住本地内存。
- 上监控：崩溃率、`Exit Code` 分布、`container_memory_working_set_bytes` 曲线。

## 五、五个高频崩溃案例

**案例 1：Netty DirectBuffer OOM 导致进程被杀。** 堆看起来很正常（`used 1.2G/2G`），但容器 RSS 顶满。用 NMT（`-XX:NativeMemoryTracking=summary` + `jcmd <pid> VM.native_memory summary`）一眼看到 `Internal` 段暴涨。根因是 `ByteBuf` 未 `release()`，处置是用 `ResourceLeakDetector` 抓引用计数泄漏点。

**案例 2：Metaspace OOM 崩溃。** 每次热部署/动态代理生成新类，ClassLoader 无法回收。`jhsdb jmap --permstat` 会列出每个 ClassLoader 加载的类数，找出持续增长的元凶。

**案例 3：SIGBUS 出现在 mmap 文件。** 内存映射文件被 `truncate` 或磁盘满，访问映射区触发 SIGBUS。hs_err 的 frame 里能看到 `Unsafe_GetByte`、`MappedByteBuffer`。

**案例 4：SIGILL。** 编译机用 AVX-512 生成镜像，运行机 CPU 不支持。属于"环境不一致"型崩溃，看 `CPU` 段的 `AVX` 标志位即可确认。

**案例 5：C2 编译优化 bug。** 前述 `-XX:CompileCommand=exclude` 验证法。典型诱因是字符串去重、`G1` 的 SATB、`Vector API`（孵化）：`-XX:-UseVectorizedMismatch` 之类的开关能收窄范围。

## 六、面试追问清单

**Q1：hs_err 里 Problematic frame 的 `J 3821 c2` 是什么意思？**
`J` 表示 JIT 编译后的 Java 帧；`3821` 是编译任务 ID；`c2` 表示由 C2 服务端编译器产出。这意味着崩溃发生在被激进优化过的代码里，优先怀疑 JIT。

**Q2：为什么容器里经常找不到 core dump？**
`ulimit -c` 默认为 0；`core_pattern` 未改（默认写到进程工作目录，容器重启即丢）；或 `core_pattern` 以 `|` 开头交给外部程序处理。

**Q3：`jmap -dump` 和 `jhsdb jmap --binaryheap` 的区别？**
前者在活进程上通过 attach 机制抓快照（会 STW，且依赖 `AttachListener`）；后者直接读 core 文件，进程已死也能用，且不依赖目标 JVM 的 attach 能力。分析崩溃现场时后者是唯一选择。

**Q4：没有 hs_err，如何确认是被 OOM Killer 杀的？**
看 `dmesg` 的 `Out of memory: Killed process <pid> (java)`；K8s 场景看 Pod 的 `Last State: Terminated, Reason: OOMKilled, ExitCode: 137`。同时对比 `container_memory_working_set_bytes` 与 limit 的曲线。

**Q5：为什么 `-Xmx` 设成容器 limit 的 90% 是危险配置？**
因为 Metaspace、代码缓存、线程栈、DirectBuffer、JNI、JVM 自身结构全部在堆外。堆顶到 limit 之间没有余量时，OS 会先杀进程，而不是等 JVM 抛 OOM。

**Q6：jhsdb 与 MAT 如何配合？**
`jhsdb jmap --binaryheap` 产出标准 hprof，MAT 负责支配树、泄漏嫌疑报告、OQL。区分：jhsdb 负责"从 core 里取出堆"，MAT 负责"理解堆"。

## 七、最佳实践总结

1. **默认开启**：`-XX:+HeapDumpOnOutOfMemoryError`、`-XX:ErrorFile` 指向持久卷、`-XX:+CreateCoredumpOnCrash`。
2. **core_pattern 与 ulimit** 进镜像时就要配好，别等事故现场才发现写不出来。
3. **保留 hs_err 至少 7 天**并接入日志采集；这是唯一能自证"JVM 崩了"的证据。
4. **NMT 常开 summary 模式**，堆外问题才不会变成盲区。
5. **分析顺序固定**：信号 → Problematic frame → 崩溃线程栈 → 内存区域 → 编译事件，不要跳步。
6. **修复先止血再定位**：`CompileCommand=exclude`、降级 JIT、回滚版本都能争取时间，但根因一定要写进复盘。

崩溃不可怕，可怕的是没有现场。把 hs_err 和 core dump 变成常规武器，JVM 的"死因"就从玄学变成了证据链。
