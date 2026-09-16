---
title: 【生产实战】async-profiler 火焰图深度解析：从采样原理到 CPU/内存/锁全维度线上排障
date: 2026-09-16 08:00:00
tags:
  - JVM
  - 性能调优
  - async-profiler
  - 火焰图
  - 线上排障
categories:
  - JVM
  - 性能优化
author: 东哥
---

# 【生产实战】async-profiler 火焰图深度解析：从采样原理到 CPU/内存/锁全维度线上排障

## 面试官：线上一个接口 CPU 飙到 100%，我给你 5 分钟，你怎么定位到具体代码行？

先排除错误答案：

- `jstack` 打 5 次，看哪个栈出现得多 —— 这是**穷人的采样器**，只能看"线程正在干什么"，看不到 CPU 时间占比，也看不到内核栈，命中率完全靠手气。
- `top -Hp` 找出最热的线程，再 `jstack` 比对 nid —— 能定位到线程，但接口一多、线程池一摊开，编号对到眼瞎。
- 上 JProfiler/YourKit —— 靠 **JVMTI 方法进出插桩**实现，方法级全量统计看着很爽，但采样有 **SafePoint Bias（安全点偏差）**，而且开销大，生产环境不敢开。

真正在生产环境里的标准动作是：**async-profiler 打一张火焰图，30 秒出结论。**

它是目前 Java 世界最主流的低开销采样剖析器。这篇文章把它的采样原理、参数体系、火焰图读法以及 CPU/内存/锁三类实战案例一次讲清。

---

## 一、为什么 async-profiler 准？—— 采样原理

传统采样器的两条老路：

| 方案 | 原理 | 致命缺陷 |
| --- | --- | --- |
| 字节码插桩（JProfiler/YourKit/部分 APM） | 在每个方法入口/出口埋点统计耗时 | 开销大（10%~50%）；改变 JIT 内联行为；统计的是"墙钟"不是 CPU |
| `Thread.getStackTrace()` 轮询采样（如早期 Sampler） | 单独线程定时打断目标线程取栈 | 取栈必须走到 **SafePoint**，热点代码往往在 SafePoint 之外，"采样点"被系统性地偏向能进安全点的位置 → **SafePoint Bias** |
| **async-profiler** | **AsyncGetCallTrace（JVMTI 提供的异步取栈）+ perf_events（内核侧采样）** | 采样发生在信号/中断上下文，**无需进入安全点**，不依赖 JVMTI 插桩 |

关键在于两点：

1. **`AsyncGetCallTrace` 是"异步"取栈**：它由 `SIGPROF` 信号触发，直接在当前指令处抓取 Java 调用栈，绕开了"必须到 Safepoint 才能取栈"的限制。
   > 代价是：栈顶可能抓不到"正在执行但还没登记"的方法——所以生产上要开 `-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints`，让 JIT 保留足够的调试信息，栈才完整。
2. **`perf_events` 采样内核侧**：通过 Linux `perf_event_open` 拿到硬件/软件事件（CPU cycles、cache-misses、page-faults），因此能产出**包含内核栈的完整火焰图**（`[vmlinux]`、`[kernel.kallsyms]`、syscall 帧）。
   > 如果拿不到 `perf_event_open` 权限（比如容器里 `perf_event_paranoid=3`），会自动退化为 `itimer`（`SIGPROF` 定时器）——**此时内核栈丢失、且对 CPU 时间不再精确**。

另外，它还有一条隐藏优势：**采样是"无侵入"的**，不在字节码里插桩，因此完全不影响 JIT 的逃逸分析、内联决策，火焰图上的内联关系是真实运行时的样子。

**开销**：官方口径 ~1%~2% CPU，实测在绝大多数服务上可以忽略。这也是它敢在高峰期直接打的原因。

---

## 二、安装与三种启动方式

```bash
# 1) 直接下载 release（国内可用 ghfast 代理）
curl -L -o async-profiler.tar.gz \
  https://ghfast.top/https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-x64.tar.gz
tar -xzf async-profiler.tar.gz && cd async-profiler-3.0-linux-x64
```

三种使用形态：

```bash
# A. attach 模式（推荐，无需改启动参数）：attach 到已运行的 JVM
./bin/asprof -d 30 -f /tmp/cpu.html 12345

# B. agent 模式：启动时挂载，适合采集启动阶段的 profile
java -agentpath:/opt/async-profiler/lib/libasyncProfiler.so=start,event=cpu,file=/tmp/cpu.html -jar app.jar

# C. 命令行交互模式：start / stop / status / dump
./bin/asprof start -e cpu,alloc -f /tmp/out.jfr 12345
./bin/asprof status 12345
./bin/asprof stop 12345
```

> 小坑：attach 模式依赖 JVM 的 Attach API，某些安全加固环境（禁用了 `jdk.attach` 或容器里 `/tmp` 不可共享）会失败，此时改用 agent 模式，或在容器内执行。

---

## 三、参数体系：先把这三组搞清楚

### 3.1 事件类型：`-e`

| 事件 | 含义 | 默认采样间隔 | 典型问题 |
| --- | --- | --- | --- |
| `cpu` | CPU 时间（perf_events 或 itimer） | 10ms | 忙等、死循环、算法复杂度、JIT/C2 编译开销 |
| `alloc` | 堆分配（TLAB/AllocTracer 采样） | ~512KB | 内存分配风暴、大对象、GC 压力来源 |
| `lock` | 锁阻塞（monitor enter / park 等） | 10ms | 锁竞争、`synchronized` 热点、线程池内的串行化 |
| `wall` | 墙钟时间（含阻塞/等待/IO/睡眠） | 10ms | 接口慢但 CPU 不高：IO 等待、连接池耗尽、下游卡顿 |
| `itimer`/`ctimer` | 定时器采样（无 perf 权限时） | 10ms | 兜底方案 |
| `cache-misses` 等 | 硬件性能计数事件 | 视事件 | 缓存行伪共享、内存局部性差 |

### 3.2 输出与时长：`-d` / `-f` / `-o`

```bash
# 采集 60 秒，输出交互式 HTML 火焰图
./bin/asprof -e cpu -d 60 -f /tmp/cpu.html <pid>

# 输出 JFR 格式，用 JMC 打开做关联分析
./bin/asprof -e cpu,alloc,lock -d 60 -o jfr -f /tmp/p.jfr <pid>

# 输出折叠栈（collapsed），喂给 FlameGraph 脚本或做二次统计
./bin/asprof -e cpu -d 30 -o collapsed -f /tmp/p.txt <pid>

# 输出调用树（text/tree），适合在终端里 grep 热点
./bin/asprof -e cpu -d 30 -o tree -f /tmp/p.txt <pid>
```

### 3.3 过滤与拆分：`-t` / `-s` / `-I` / `-X` / `--all-user`

| 参数 | 作用 |
| --- | --- |
| `-t` | **按线程拆分**，火焰图里能看到哪个线程池/哪个业务线程在烧 CPU |
| `-s` | 类名用简名（`Foo`）而非全限定名（`com.a.b.Foo`），图更清爽 |
| `-I <pattern>` | 只统计匹配的栈（include） |
| `-X <pattern>` | 排除匹配的栈（exclude），比如过滤掉 GC 线程 |
| `--all-user` | 只采用户态，排除内核帧，专注 Java 侧 |
| `--cstack fp\|dwarf\|lbr` | 内核栈展开方式（默认 fp 帧指针，容器/JIT 环境下 dwarf 更准） |
| `--total` | 用总数而非百分比标注 |

**高频组合拳**：

```bash
# CPU 高：先看全局，再按线程拆分定位到池子
./bin/asprof -e cpu -d 30 -f /tmp/cpu.html <pid>
./bin/asprof -e cpu -d 30 -t -f /tmp/cpu-t.html <pid>

# 只关心业务代码：排除内核与 JIT/GC 干扰
./bin/asprof -e cpu -d 30 --all-user -X 'G1.*' -X 'C2 CompilerThread.*' -f /tmp/cpu-biz.html <pid>

# 接口慢但 CPU 空：抓 wall clock
./bin/asprof -e wall -d 30 -t -f /tmp/wall.html <pid>

# 内存涨得快：抓分配热点
./bin/asprof -e alloc -d 60 -f /tmp/alloc.html <pid>
```

---

## 四、火焰图到底怎么看

### 4.1 三条读数规则

- **横轴不是时间，是样本占比**：某个框越宽，说明栈里包含它的样本越多。横轴的左右顺序**没有意义**，不要按"从左到右"读时序。
- **纵轴是调用深度**：底部是调用者，越往上越深，**最顶端的框是采样时正在执行的方法**。
- **看图先看"平地"**：一大片又宽又平的框（顶部没有更深的子调用）代表——**这个方法自己在消耗 CPU**，而不是在调用别人。这是最值钱的信号。

### 4.2 四种典型形态与结论

| 形态 | 含义 | 下一步 |
| --- | --- | --- |
| 顶部一大片平坦的宽框 | 自身耗 CPU 的热点方法（正则、序列化、加密、循环） | 读代码优化算法 / 换实现 |
| 底部宽、顶部细密的塔 | 调用链深，分散在大量小方法 | 看是否有重复调用、可否缓存 |
| 出现 `G1 Young RemSet` / `V8` 之类 GC 帧且占比高 | GC 开销大（分配率高或堆配置不合理） | 转 `-e alloc` 找分配热点 |
| 出现 `[vmlinux]`、`sys_read`、`__futex_wait` 等内核帧 | 系统调用/锁等待是瓶颈 | 结合 `wall` 事件与锁分析 |
| `C2 CompilerThread` 占比异常高 | JIT 编译本身在烧 CPU（通常是"编译风暴"） | 看是否有大量动态类生成/大方法 |

### 4.3 交互技巧

- 点击任意框可以**放大**，只看该子树。
- 搜索框支持正则，搜 `sql|json|regex` 快速定位可疑包。
- 页面底部可切换 **Top Methods / Top Classes / Top Packages** 视图——**想快速给结论，直接看 Top Methods 就够了**，火焰图主要用于验证调用路径。

---

## 五、三类实战案例

### 案例一：CPU 100%，火焰图定位到正则回溯

**现象**：订单导出接口 CPU 突增，QPS 下降，GC 正常，线程无死锁。

```bash
./bin/asprof -e cpu -d 30 -f /tmp/cpu.html <pid>
```

火焰图顶部出现一片宽平的：

```
java.util.regex.Pattern$Curly.match
java.util.regex.Pattern$Loop.match
java.util.regex.Pattern$GroupHead.match
com.xx.common.util.PhoneUtil.isValid
```

**结论**：某手机号校验用的正则写了嵌套量词（类似 `(\d+)*`），遇到超长非法输入触发**灾难性回溯（Catastrophic Backtracking）**，单个请求就能吃掉一个核。

**修复**：正则改写为等价但线性的表达式，或加长度预校验（`if (s.length() > 20) return false;`）。**这类问题用 `jstack` 是发现不了的**——线程状态就是 `RUNNABLE`，没有任何异常。

### 案例二：接口慢但 CPU 只有 10%，用 wall 找到连接池耗尽

**现象**：P99 从 80ms 涨到 3s，CPU/GC 都正常，机器负载低。

```bash
./bin/asprof -e wall -d 30 -t -f /tmp/wall.html <pid>
```

火焰图按线程拆分后显示：大量线程栈停在

```
java.lang.Object.wait
com.zaxxer.hikari.pool.HikariPool.getConnection
com.xx.mapper.UserMapper.selectById
```

**结论**：线程不是"忙"，而是"等"——**HikariCP 连接池被占满**。进一步用 `jstack` 看持锁线程，发现有个查询没走索引，单次耗时 2s，把 10 个连接全占了。

**修复**：SQL 加索引 + 连接池超时（`connectionTimeout`）暴露问题 + 慢 SQL 监控告警。

> **经验法则：`cpu` 火焰图看不到问题，就一定要打 `wall` 火焰图。** 这是 async-profiler 相比"CPU 采样器"的最大价值增量。

### 案例三：内存分配风暴，`alloc` 定位到隐式装箱

**现象**：Young GC 频率从 2/min 变成 60/min，TP99 抖动。

```bash
./bin/asprof -e alloc -d 60 -f /tmp/alloc.html <pid>
```

分配火焰图顶部：

```
java.lang.Integer.valueOf
com.xx.service.StatService.calcScore
java.util.stream.Collectors.toList
```

**结论**：循环里对几百万条数据做 `map(Integer::...)`，触发海量 `Integer` 装箱（每次分配 16 字节），同时在用 Stream 的 `boxed()` 反复生成中间对象。

**修复**：改用 `IntStream`/原始类型流，或直接换循环 + 预分配数组。

**关键点**：`alloc` 火焰图的宽度是**分配字节数占比**（采样估算），不是对象个数；它能直接告诉你"GC 压力是从哪一行代码来的"，这是 `jstat`/GC 日志给不了的粒度。

---

## 六、与其它工具的组合拳

单靠一张火焰图不够，生产排障的完整链路是：

```text
top / pidstat        → 先确认是 CPU、内存、IO 还是上下文切换问题
      ↓
async-profiler       → 定位到热点方法 / 分配点 / 锁等待点（本图）
      ↓
jstack / jcmd        → 结合线程状态验证（BLOCKED / WAITING / RUNNABLE）
      ↓
JFR                  → 需要事件级证据时（异常数、锁统计、GC 明细、网络 IO）
      ↓
Arthas / MAT         → 动态反编译 / 对象引用链定位
```

| 工具 | 最擅长 | 短板 |
| --- | --- | --- |
| async-profiler | CPU/分配/锁/墙钟的低开销采样，火焰图可视 | 不提供事件级明细与内存对象图 |
| JFR | 事件级、持续低开销、可长期开启 | 可视化与分析需 JMC，火焰图不如 asprof 直观 |
| jstack | 瞬时线程状态、死锁检测 | 无法统计 CPU 占比 |
| MAT | 堆转储对象引用链、支配树 | 离线、需要 dump（会暂停服务） |
| Arthas | 动态反编译、trace 单方法耗时、watch 参数 | 高频 trace 有开销 |

---

## 七、生产落地注意事项

1. **权限**：`perf_event_open` 需要 `kernel.perf_event_paranoid <= 2`（或 root/CAP_PERFMON）。容器里常被限制，此时：
   - 用 `--all-user` 只采用户态；
   - 或用 `--fdtransfer` 让宿主机上的 perf 帮你采内核栈；
   - 或退化为 `itimer`（记得它**有 SafePoint 偏差**）。
2. **务必开 `-XX:+DebugNonSafepoints`**：否则 JIT 优化后的代码栈信息会缺失，火焰图上大量栈顶被归到 `[unknown]`。
3. **采样时长**：30~60 秒是甜点区。太短样本不足，图抖动大；太长文件大且噪音多。
4. **容器/PPID 问题**：容器 PID namespace 下，宿主机上 attach 需要 host PID；建议在容器内采集或使用 agent 模式。
5. **低内存机器**：HTML 火焰图文件在几十 MB 量级，记得采完及时转存/清理，别把磁盘塞满。
6. **定期采集，而非出事才采**：把"高峰期 1% 采样 60s"做成例行巡检，才能建立性能基线，出事时才有对照。

---

## 八、面试常见追问

**Q1：为什么 async-profiler 没有 SafePoint Bias？**

因为它走 `AsyncGetCallTrace`（信号异步取栈）而非 JVMTI 方法插桩或轮询取栈，采样点落在任意指令处，不需要线程主动走到安全点。轮询式采样器必须在安全点取栈，导致"能在安全点出现的位置"被高估。

**Q2：火焰图上一大片平坦的框，一定是热点吗？**

是"自身消耗 CPU"的信号，但要排除**内联**造成的错觉：JIT 内联后，子方法会消失、并入父帧。所以要开 `-XX:+DebugNonSafepoints`，并理解"火焰图反映的是 JIT 优化后的真实调用形态"。

**Q3：`-e cpu` 和 `-e wall` 什么时候用哪个？**

CPU 高用 `cpu`；**接口慢但 CPU 不高，一定用 `wall`**。`wall` 包含线程阻塞/等待时间，是定位"锁、IO、连接池、下游超时"的利器。反过来，如果 CPU 高但 `wall` 看不出东西，说明线程真的在算（而不是在等）。

**Q4：采样剖析能抓到"偶发"问题吗？**

能，但需要足够样本。偶发问题（如 1/10000 才触发的慢路径）要么延长采样时间，要么在复现时针对性采样，要么结合 JFR 的事件流（如 `jdk.ObjectAllocationSample`、`jdk.JavaMonitorEnter`）做长期观察。

**Q5：async-profiler 和 JFR 该选哪个？**

不冲突，是互补：**JFR 用于"长期、事件级、多维度"的观察（可 7×24 开启），async-profiler 用于"短时、高分辨率、可视化"的定点攻坚**。理想形态是 JFR 常开做基线 + 出问题时 asprof 打火焰图秒定位。

---

## 九、小结

| 要点 | 结论 |
| --- | --- |
| 采样机制 | `AsyncGetCallTrace` + `perf_events`，无 SafePoint Bias，含内核栈 |
| 开销 | ~1%~2%，生产可直开 |
| 四类事件 | `cpu`（算）、`alloc`（分）、`lock`（争）、`wall`（等） |
| 看图三规则 | 宽=占比、深=调用栈、平顶=自身热点 |
| 第一动作 | 先看 Top Methods，再回火焰图验证路径 |
| 必备参数 | `-d 30~60`、`-f xxx.html`、`-t`（分线程）、`--all-user`（去内核） |
| 最容易漏的 | `-XX:+DebugNonSafepoints`，否则栈顶是 `[unknown]` |
| 排障铁律 | CPU 高看 `cpu`，**CPU 不高看 `wall`** |

火焰图的价值不在于"好看"，而在于它把一个模糊的"接口变慢了"问题，压缩成了一次 30 秒的采样 + 一张可以指着说话的图。**会用 jstack 是及格，会用 async-profiler 才是生产级。**
