---
title: 【JVM 底层】JVM 统一日志框架（-Xlog）深度解析：从 PrintGC 到结构化日志与生产级配置
date: 2026-09-14 08:00:00
tags:
  - Java
  - JVM
  - GC
  - 调优
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 底层】JVM 统一日志框架（-Xlog）深度解析：从 PrintGC 到结构化日志与生产级配置

## 面试官：线上要排查 GC 问题，你怎么开日志？`-XX:+PrintGCDetails` 还是 `-Xloggc`？

如果你的答案是上面两个，那面试官下一句一定是：**「这两套参数在 JDK 17 上还能用吗？」**

答案是不能——`-XX:+PrintGC*` 系列在 JDK 9 被标记废弃，JDK 11 之后大量参数虽然还能识别，但输出会被映射到新框架，且提示已废弃；到 JDK 14+（以及后续 LTS）很多参数直接报错或彻底移除。**统一日志框架（Unified Logging, JEP 158）** 才是现代 JVM 唯一的日志方式。

这篇文章系统讲清 `-Xlog` 的语法、标签体系、装饰器、输出控制和 GC 日志的实战阅读方法。

---

## 一、为什么需要统一日志？JDK 8 时代的四套日志体系

JDK 8 的 JVM 日志是「各自为政」的：

| 日志系统 | 开关参数 | 输出内容 |
| --- | --- | --- |
| GC 日志 | `-XX:+PrintGC`、`-XX:+PrintGCDetails`、`-Xloggc:file` | 垃圾回收 |
| 类加载日志 | `-XX:+TraceClassLoading`、`-XX:+TraceClassUnloading` | 类加载/卸载 |
| JIT 日志 | `-XX:+PrintCompilation`、`-XX:+PrintInlining` | 编译活动 |
| 安全/其他 | `-verbose:gc`、`-verbose:class`、`-Djava.security.debug` | 杂项 |

痛点非常明显：

- **无法组合过滤**：想看「GC + 类加载同时带时间戳」？做不到，两套格式互不相通
- **无法统一输出到文件**：`-Xloggc` 只管 GC，其他日志还在 stdout
- **没有级别概念**：打开 `-XX:+PrintInlining` 直接刷屏几十万行，无法降噪
- **格式各不相同**，日志采集系统要做多套正则
- **无法运行时动态开关**：想临时开个 `PrintSafepointStatistics`？得重启

JEP 158 的目标就是：**一套统一的、有级别的、可标签过滤的、可运行时控制的日志框架**。

---

## 二、-Xlog 完整语法

```
-Xlog:<tag-set>=<level>:<output>:<decorators>:<output-options>
```

四个部分用冒号分隔，除了第一段，其余都可省略。

### 2.1 tag-set（标签集）

`tag1+tag2+...` 或通配 `tag*`，多个 tag-set 用逗号分隔。**`+` 是 AND（同时具备这些标签），`,` 是 OR（另一条规则）。**

常见标签（JVM 启动时用 `-Xlog:help` 或 `java -Xlog:all=trace` 观察）：

| 分类 | 标签 | 含义 |
| --- | --- | --- |
| GC | `gc` | GC 基础事件 |
| | `gc+heap` | 堆使用量与容量变化 |
| | `gc+phases` | 各 GC 阶段耗时（G1/ZGC 很有用） |
| | `gc+age` | 对象年龄分布（`-XX:+PrintTenuringDistribution` 替代） |
| | `gc+ergo` | 人机工程学决策过程 |
| | `gc+start` / `gc+exit` | GC 线程启停 |
| 内存 | `safepoint` | 安全点耗时（排查 STW 元凶） |
| | `metaspace` | 元空间 |
| 类 | `class+load` / `class+unload` | 类加载/卸载 |
| 编译 | `compilation`、`jit+inlining` | JIT 编译与内联 |
| 运行时 | `os`、`thread`、`pagesize` | 操作系统、线程、页大小 |
| 其他 | `logging` | JVM 日志系统自身的日志（集成 log4j 时用） |

**注意 `gc` 是一个前缀标签，`gc*` 能匹配所有以 gc 开头的标签组合。**

### 2.2 level（级别）

`trace < debug < info < warning < error`。默认继承规则：指定 `gc=debug` 时，更严重的 `info/warning/error` 也会输出。

```bash
# 只输出 GC 的 info 及以上
-Xlog:gc=info

# 输出 GC 相关的所有细节（含 debug/trace）
-Xlog:gc*=debug
```

### 2.3 output（输出目标）

| 写法 | 含义 |
| --- | --- |
| `stdout` | 标准输出（默认） |
| `stderr` | 标准错误 |
| `file=/var/log/jvm/gc.log` | 写入文件 |

### 2.4 decorators（装饰器）——让日志结构化

这是最实用的部分，输出前缀可自由组合：

| 装饰器 | 输出示例 | 说明 |
| --- | --- | --- |
| `time` | `[2026-09-14T08:00:00.123+0800]` | ISO-8601 绝对时间 |
| `utctime` | `[2026-09-14T00:00:00.123+0000]` | UTC 绝对时间 |
| `uptime` | `[123.456s]` | JVM 启动后秒数 |
| `millis` | `[123456ms]` | 毫秒数 |
| `timen`（JDK 11+）| `[123.456789s]` | 纳秒级 uptime |
| `level` | `[info][warning]` | 日志级别 |
| `tags` | `[gc,heap]` | 标签集 |
| `pid` | `[12345]` | 进程 ID |
| `tid` | `[123]` | 线程 ID |
| `hostname` | `[node-01]` | 主机名 |

不写装饰器时，默认是 `uptime` + `level` + `tags`。

### 2.5 output-options（文件轮转）

| 选项 | 说明 |
| --- | --- |
| `filecount=N` | 保留 N 个轮转文件（`0` 表示不轮转） |
| `filesize=SIZE` | 单文件大小，支持 `k/m/g` |
| `-XX:+UseGCLogFileRotation` 已被取代 | 现在用 `filecount` + `filesize` |

---

## 三、常用配置清单（可直接抄）

### 3.1 生产环境推荐（GC 日志落文件 + 轮转）

```bash
java -Xms4g -Xmx4g \
  -Xlog:gc*,gc+heap=debug,gc+age=trace,safepoint=info:file=/var/log/app/gc-%p.log:time,uptime,level,tags:filecount=10,filesize=50M \
  -jar app.jar
```

要点：

- `%p` 是 PID 占位符（还有 `%t` 时间戳、`%%` 百分号），多实例部署必备，避免日志互相覆盖
- `filecount=10,filesize=50M` → 最多占 500MB 磁盘，必须设上限，否则日志撑爆磁盘把服务搞挂
- `safepoint=info` 在排查「GC 不长但停顿很长」时非常关键

### 3.2 排查类加载问题

```bash
-Xlog:class+load=info,class+unload=info:file=/var/log/app/class.log:time,uptime,level,tags
```

用于定位「`Metaspace OOM`」「类加载器泄漏」——观察是否有类被反复加载而不卸载。

### 3.3 排查 JIT 与启动优化

```bash
-Xlog:compilation=info,jit+inlining=debug:file=/var/log/app/jit.log:uptime,level,tags
```

`jit+inlining=debug` 会打印内联决策树，用于验证热点方法是否被内联。

### 3.4 打开 JVM 日志系统自身的调试（对接 log4j）

```bash
-Xlog:logging=debug:file=jvm-logs.log
```

这样能看到「哪条日志规则匹配了哪个输出器」，规则写错时非常有用。

### 3.5 同时输出到多个目标

多条规则用逗号分隔：

```bash
-Xlog:gc=info:stdout:uptime,level,tags,gc*=debug:file=/var/log/app/gc.log:time,level,tags
```

注意：`stdout` 那条后面还要跟装饰器，语法上是「第一段 tag-set 无冒号时视为 stdout + 装饰器」，简写要小心。**推荐显式写全**，可读性更好。

### 3.6 运行时动态调整（jcmd）

```bash
# 查看当前规则
jcmd <pid> VM.log list

# 动态加日志，无需重启
jcmd <pid> VM.log output=/tmp/tmp-gc.log what=gc* decorators=time,uptime

# 关闭
jcmd <pid> VM.log disable
```

这是统一日志最被低估的能力：**线上临时开 GC 细节日志，不用重启**。

---

## 四. 读懂一行 G1 GC 日志

```
[2026-09-14T08:00:01.234+0800][info][gc] GC(42) Pause Young (Normal) (G1 Evacuation Pause) 512M->180M(2048M) 23.456ms
```

逐段拆解：

| 片段 | 含义 |
| --- | --- |
| `GC(42)` | 第 42 次 GC，用于和并发阶段日志关联 |
| `Pause Young (Normal)` | 年轻代停顿（Normal 表示普通 YGC，Concurrent Start 表示并发标记启动） |
| `(G1 Evacuation Pause)` | 具体原因：转移暂停 |
| `512M->180M` | GC 前堆占用 → GC 后堆占用 |
| `(2048M)` | 当前总容量（注意不等于 `-Xmx`，G1 会动态扩缩） |
| `23.456ms` | 本次停顿耗时 |

再看并发阶段（`-Xlog:gc+phases=debug`）：

```
[info][gc,phases] GC(42)   Concurrent Mark Cycle 45.678ms
[info][gc,phases] GC(42)     Scan Root Region 3.210ms
[info][gc,phases] GC(42)     Mark From Roots  12.345ms
[info][gc,phases] GC(42)     Preclean   5.678ms
[info][gc,phases] GC(42)     Remark   8.901ms
[info][gc,phases] GC(42)     Cleanup  2.345ms
```

并发阶段不 STW，但**长时间占用 CPU**，如果应用是 CPU 密集型，并发标记会直接抢走算力，表现为「吞吐下降但停顿正常」。

堆容量变化（`-Xlog:gc+heap=debug`）可以看到 G1 的动态扩缩：

```
[debug][gc,heap] GC(42) Heap before GC invocations=42 (full 0): ... 
[debug][gc,heap] GC(42)  eden: 512M(536M)->0B(536M)
[debug][gc,heap] GC(42)  survivors: 0B(32M)->32M(32M)
[debug][gc,heap] GC(42)  free regions: 1200
```

---

## 五、用 GC 日志做判断：4 个典型模式

### 模式 1：Young GC 频繁，间隔 < 1s

```
GC(100) Pause Young (Normal) 180M->160M(1024M) 15ms
GC(101) Pause Young (Normal) 175M->158M(1024M) 14ms   // 间隔 600ms
GC(102) Pause Young (Normal) 178M->162M(1024M) 16ms
```

**特征**：每次回收后存活对象几乎没变（160M→158M），说明都是短命对象。
**结论**：正常但过于频繁，可适当增大 Eden（`-Xmn` / `-XX:G1NewSizePercent`）或检查是否创建了过多临时对象。

### 模式 2：Full GC 反复出现（G1 应尽量避免）

```
GC(500) Pause Full (G1 Compaction Pause) 1900M->1200M(2048M) 3200ms
```

**原因候选**：晋升失败（Humongous 大对象）、元空间不足、显式 `System.gc()`。
**排查**：配合 `-Xlog:gc+ergo*=debug` 与 `-XX:+ExplicitGCInvokesConcurrent`。

### 模式 3：停顿时间忽高忽低

开 `safepoint` 日志对比：

```
[safepoint] Safepoint "G1CollectFull", Time since last: 12345 ms, Reaching safepoint: 150us, At safepoint: 3200us, Total: 4500us
```

若 `Time since last`（到上次安全点的间隔）异常大，说明有线程长时间没到安全点——典型元凶是**编译后的大循环**（可数循环会在循环末尾插安全点，但 JIT 优化后可能消除），或 `Thread.sleep` 之外的长阻塞。

### 模式 4：日志里出现 `to-space exhausted`

```
GC(77) Pause Young (Normal) (G1 Evacuation Pause) 2000M->1950M(2048M) 450ms
      to-space exhausted
```

存活对象多到 Survivor 装不下，转移失败退化成 Full GC。**对策**：加 `-XX:InitiatingHeapOccupancyPercent`（提前启动并发标记）、增大 `-XX:G1ReservePercent`、或根本原因是内存泄漏（先看 GC 后占用是否持续上涨）。

---

## 六、从旧参数到新参数的映射（迁移必看）

| JDK 8 参数 | JDK 9+ 等价写法 |
| --- | --- |
| `-XX:+PrintGC` | `-Xlog:gc` |
| `-XX:+PrintGCDetails` | `-Xlog:gc*` |
| `-Xloggc:/path/gc.log` | `-Xlog:gc:file=/path/gc.log` |
| `-XX:+PrintGCTimeStamps` | 装饰器 `uptime` |
| `-XX:+PrintGCDateStamps` | 装饰器 `time` |
| `-XX:+PrintTenuringDistribution` | `-Xlog:gc+age=trace` |
| `-XX:+PrintHeapAtGC` | `-Xlog:gc+heap=debug` |
| `-XX:+PrintClassHistogram` | `-Xlog:class+histo=trace`（JDK 8 后期） |
| `-XX:+PrintCompilation` | `-Xlog:compilation=info` |
| `-XX:+TraceClassLoading` | `-Xlog:class+load=info` |
| `-XX:+PrintSafepointStatistics` | `-Xlog:safepoint` |
| `-XX:GCLogFileSize` / `NumberOfGCLogFiles` | `filesize` / `filecount` output-options |
| `-verbose:gc` | `-Xlog:gc` |

**别在 JDK 17+ 上继续用左边这些**：JDK 9 起废弃警告，JDK 11 后部分参数被忽略，JDK 14+ 很多直接 `Unrecognized VM option` 启动失败。

---

## 七、生产环境 7 个注意事项

1. **一定要限制磁盘占用**。`filecount` + `filesize` 缺一不可，见过因为 GC 日志写满磁盘导致整个 Pod 崩溃的案例。
2. **多实例必须用 `%p`**。否则同一台机器上多个 JVM 会互相覆盖日志。
3. **文件路径要提前创建并赋予写权限**。JVM 不会自动创建目录。
4. **`-Xlog:gc*` 在高频 GC 场景下日志量极大**。QPS 高、Young GC 每秒一次时，一天可能几 GB。建议生产用 `gc*=debug` 而不是 `gc*=trace`，或配合异步日志（`-Xlog:async`，JDK 13+）。
5. **`-Xlog:async` 降低日志对业务线程的影响**（日志写入转移到单独的线程），但会丢失崩溃前最后一部分缓冲日志，排查启动崩溃时慎用。
6. **别用 stdout 输出 GC 日志**。在容器里 stdout 会进日志采集系统，把业务日志淹没；也可能被 `System.out` 重定向而混淆。
7. **GC 日志与监控系统对接**。推荐用 `gc-viewer`（JDK 自带，`jdk/bin/gcviewer`）、GCeasy、或 Prometheus 的 `jvm_gc_*` 指标做长期趋势。**日志用于事后深度分析，指标用于实时报警。**

---

## 八、面试追问连环炮

**Q1：`-Xlog:gc` 和 `-Xlog:gc*` 有什么区别？**
`gc` 是精确匹配「只带 gc 标签」的事件；`gc*` 是前缀通配，匹配 `gc`、`gc+heap`、`gc+phases`、`gc+age` 等所有组合。日常排查用 `gc*`。

**Q2：`-Xlog` 里的 `+` 和 `,` 分别是什么语义？**
`+` 是标签求交集（AND），`gc+heap` 表示同时带 gc 和 heap 标签的事件；`,` 分隔多条独立规则（OR / 分别配置输出）。

**Q3：怎么在不重启的情况下临时开 GC 日志？**
`jcmd <pid> VM.log output=/tmp/gc.log what=gc* decorators=time,uptime,level,tags`，用 `jcmd VM.log list` 查看，`VM.log disable` 关闭。

**Q4：为什么 GC 停顿不长，但应用还是卡顿？**
打开 `-Xlog:safepoint` 看到达安全点的耗时；再把 `gc+phases` 打开看并发阶段耗时（抢 CPU）；另外考虑 JIT 去优化（`-Xlog:jit+deopt`）。卡顿不一定来自 GC。

**Q5：容器里 GC 日志时间戳不对怎么办？**
容器默认 UTC，加 `-Duser.timezone=Asia/Shanghai` 或用 `utctime` 装饰器统一按 UTC 分析，避免跨时区误判。

---

## 九、总结

- **JDK 9 之后只有一套日志**：`-Xlog`，四段式语法 `tag-set=level:output:decorators:output-options`
- **标签是维度**：`gc`、`safepoint`、`class+load`、`compilation`、`gc+phases`，`+` 是交集、`*` 是通配
- **装饰器决定结构化程度**：生产必备 `time,uptime,level,tags`，多实例加 `pid`
- **必须设轮转上限**：`filecount=10,filesize=50M`，否则日志撑爆磁盘
- **`jcmd VM.log` 可以运行时动态调整**，是线上排查的杀手锏
- **看懂日志的四种模式**：YGC 频繁、Full GC 反复、停顿抖动、to-space exhausted

GC 日志不是「开了就行」的摆设，它是把 JVM 内部状态外化的唯一低成本手段。会开、会读、会用，才是真正的调优能力。
