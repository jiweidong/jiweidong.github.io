---
title: 【JVM 底层】虚拟机栈与 StackOverflowError 深度解析：栈帧结构、-Xss 调优与 unable to create native thread 排查
date: 2026-09-18 08:00:00
tags:
  - Java
  - JVM
  - 虚拟机栈
  - 面试
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 底层】虚拟机栈与 StackOverflowError 深度解析：栈帧结构、-Xss 调优与 unable to create native thread 排查

## 面试官：StackOverflowError 和 OutOfMemoryError 有什么区别？

这是一个非常经典的追问开头。很多人下意识会回答「一个栈溢出、一个堆溢出」，但如果面试官继续追问「栈溢出为什么叫 Error 不叫 Exception」「`unable to create new native thread` 到底算栈的问题还是内存的问题」，能答清楚的人就不多了。

这篇文章我们把 Java 虚拟机栈从字节码层、参数层到生产排查层彻底拆开讲一遍。

---

## 一、先把运行时数据区的边界划清楚

JVM 运行时数据区按线程私有 / 共享划分：

| 区域 | 归属 | 是否会出现内存问题 | 典型异常 |
| --- | --- | --- | --- |
| 程序计数器（PC Register） | 线程私有 | 不会 | 无 |
| 虚拟机栈（VM Stack） | 线程私有 | 会 | `StackOverflowError` / `OutOfMemoryError` |
| 本地方法栈（Native Method Stack） | 线程私有 | 会 | 同上 |
| 堆（Heap） | 线程共享 | 会 | `OutOfMemoryError: Java heap space` |
| 方法区 / 元空间 | 线程共享 | 会 | `OutOfMemoryError: Metaspace` |
| 运行时常量池 | 方法区的一部分 | 会 | `OOM: Metaspace` |
| 直接内存 | 堆外 | 会 | `OOM: Direct buffer memory` |

关键点：**虚拟机栈是线程私有的，它的容量由每个线程自己的 `-Xss` 决定**。这一点直接决定了后面「线程数」与「内存」的所有推导。

Java 虚拟机栈描述的是 **Java 方法执行的内存模型**：每个方法执行时都会创建一个栈帧（Stack Frame），方法调用链就是栈帧入栈 / 出栈的过程。

```java
public class CallChain {
    static void a() { b(); }
    static void b() { c(); }
    static void c() { System.out.println("deep"); }
    public static void main(String[] args) { a(); }
}
```

执行 `main` 时栈是 `main → a → b → c` 四个栈帧。每个栈帧在编译期栈深度就已经确定了（`javap -v` 里的 `stack=...`、`locals=...`），这也是为什么 JVM 能在方法调用前就判断栈空间是否足够。

---

## 二、栈帧到底装了什么？

一个栈帧由四部分构成：

### 1. 局部变量表（Local Variable Table）

以变量槽（Slot）为最小单位，**32 位占用 1 个 slot，`long` / `double` 占用 2 个 slot**（注意：不是连续分配，是占用两个连续 slot，且不允许单独访问其中一个）。

两个高频考点：

- **实例方法的局部变量表第 0 个 slot 是 `this`**，因此实例方法比静态方法多占一个 slot；
- slot 是可以**复用**的（作用域结束后后面的变量可以占用同一个 slot），所以「局部变量表大小」并不等于「变量个数」。

```java
public void demo(long a, int b) {
    { int x = 1; }
    { int y = 2; } // y 可以复用 x 的 slot
}
```

### 2. 操作数栈（Operand Stack）

方法执行时的「计算工作台」，最大深度在编译期由 `max_stack` 决定。看一段字节码：

```java
public static int add(int a, int b) { return a + b; }
```

```text
0: iload_0        // 把第 0 个局部变量压入操作数栈
1: iload_1        // 把第 1 个局部变量压入操作数栈
2: iadd           // 弹出两个数相加，结果压栈
3: ireturn        // 返回栈顶
```

栈深度全程最大为 2，所以 `max_stack = 2`。**如果递归层次很深，每一层帧的 `max_stack` 都会实打实地占用空间**。

### 3. 动态链接（Dynamic Linking）

每个栈帧持有一个指向 **运行时常量池中该方法引用** 的指针。方法调用时的符号引用就靠它解析成直接引用。这也是 `invokedynamic`（Lambda 的底层）能实现「延迟解析」的基础。

### 4. 方法返回地址 + 附加信息

方法正常返回时把返回值传给上层；异常返回时需要通过 **异常表（Exception Table）** 找到匹配的 handler。附加信息里还包括调试相关的 `LineNumberTable`、`LocalVariableTable` 等（`-g` 编译才有）。

---

## 三、StackOverflowError 到底怎么触发的？

HotSpot 里有一个很粗暴但有效的判断：**每次方法调用前检查当前栈指针是否越界**。越界就抛 `StackOverflowError`。

注意继承关系：

```java
StackOverflowError extends VirtualMachineError extends Error
```

所以它 **不是** `Exception`，`catch (Exception e)` 是抓不到的，必须 `catch (Throwable)` 或 `catch (Error)`。生产代码里用 `catch (Throwable)` 兜底在网关 / RPC 框架里并不少见，但要非常小心。

### 3.1 递归是最常见的元凶

```java
public static int f(int n) {
    if (n == 0) return 0;
    return n + f(n - 1);   // 没有尾调用优化，每层都要保存现场
}
```

为什么不能用尾递归优化解决？因为 **JVM 规范从未强制要求实现尾调用优化**，HotSpot 至今不支持，所以递归深度就是栈帧数量。

改写方向：

```java
public static int f(int n) {
    int sum = 0;
    for (int i = 1; i <= n; i++) sum += i;
    return sum;
}
```

或者自己用显式栈模拟：

```java
Deque<Integer> stack = new ArrayDeque<>();
```

### 3.2 递归爆栈的隐蔽来源

真实生产里爆栈很少是「自己写的递归」，更多是这些：

- **复杂 JSON 嵌套**：Fastjson / Jackson 解析深层嵌套对象，`enableUnsafe` 或递归下降解析器在超深结构上直接爆栈（历史上 Fastjson 的 DoS 问题就与深度限制有关）；
- **正则回溯**：某些正则引擎实现对嵌套量词是递归实现，恶意输入可以打爆栈；
- **组合树 / 目录树遍历**：JSON Schema 校验、AST 访问者、权限树递归；
- **`toString()` / `hashCode()` 互相引用**：对象图成环导致无限递归；
- **MyBatis / Spring 的嵌套代理**：极端情况下动态代理链过深。

**防御手段**：对任何用户可控的嵌套结构加深度上限（Jackson 的 `StreamReadConstraints.setMaxNestingDepth` 就是为此而生）。

### 3.3 一个反直觉的结论：爆栈和堆大小无关吗？

有办法可以「间接」影响：

- 当堆很大时（例如 `-Xmx8g`），进程地址空间被堆占用更多，**操作系统能留给线程栈的空间变少**；
- 线程栈在 Linux 上通常是 mmap 匿名映射，`-Xss1m` 是「预留」而非「立即提交」，但主线程的栈行为与普通线程不同（HotSpot 里主线程栈大小受 ulimit 影响）。

面试里常说「栈溢出和堆无关」，严格说应该是「**栈帧数量由 `-Xss` 与栈深决定，与堆大小没有直接因果关系**」。

---

## 四、-Xss 怎么设？各平台默认值是多少？

| 平台 | 默认栈大小 |
| --- | --- |
| Linux x64 | 1 MB |
| macOS x64/ARM | 1 MB |
| Windows x64 | 1 MB（早期 512KB） |
| Linux 主线程 | 通常受 `ulimit -s` 影响（8MB） |

常见调优结论：

- **框架类应用（Spring Boot + 嵌套调用深）建议 `-Xss512k` 或 `-Xss1m`**；
- **不要盲目调到 `-Xss10m`**：`-Xss` 会乘以线程数。1000 个线程 × 10MB（虚拟预留）= 10GB 虚拟地址空间，虽然 Linux 按需提交物理页，但会显著抬高 `vsize`，并可能触发 `max_map_count` 问题；
- **更小的 `-Xss` 换来更多线程数**，这也是 Nginx / Netty 类应用的思想：栈小、线程多。

经验公式（粗估物理内存占用）：

```text
线程栈物理占用 ≈ 活跃帧数量 × 帧大小（实际按页提交，通常几十 KB/线程）
虚拟占用      ≈ 线程数 × Xss
```

所以 **`-Xss` 调大时，真正危险的是 `虚拟内存` 与 `线程数上限`，不是 RSS**。

---

## 五、unable to create native thread —— 另一个最容易混的坑

报错长这样：

```text
java.lang.OutOfMemoryError: unable to create new native thread
```

很多人第一反应是「内存不够，加内存」。但它的真实含义是 **JVM 调用 `pthread_create` 失败了**。失败原因按出现频率排序：

1. **达到进程 / 用户线程数上限**
   - `ulimit -u`（用户级，最常见）；
   - `/proc/sys/kernel/threads-max`（系统级）；
   - `/proc/sys/kernel/pid_max`（PID 耗尽，容器里很常见）；
   - cgroup v1 `pids.max` / cgroup v2 `pids.max`（K8s Pod 的 PID 限制）。
2. **内存不足**：每个线程需要栈（`-Xss`）+ 内核 `task_struct` 开销，堆吃满后无法再分配线程栈；此时通常伴随 SWAP 打满、`vm.max_map_count` 超限（大量 mmap 段）。
3. **容器限额**：K8s 中 `resources.limits.memory` 与 pids limit 双限，往往表现为「内存看着没用完却创建不了线程」。

排查命令一览：

```bash
# 当前进程线程数
cat /proc/<pid>/status | grep Threads
ls /proc/<pid>/task | wc -l

# 系统/用户级线程限制
ulimit -u
cat /proc/sys/kernel/threads-max
cat /proc/sys/kernel/pid_max

# map count（mmap 段上限，代码缓存/线程栈都算）
cat /proc/sys/vm/max_map_count
cat /proc/<pid>/maps | wc -l

# 谁在疯狂建线程
jstack <pid> | grep -c 'java.lang.Thread.State'
```

**最有价值的排查动作**：`jstack` 输出按线程名前缀聚合，找出那个「一秒钟建一批」的线程池。

```bash
jstack <pid> | grep '^"' | sed 's/".*//' | sort | uniq -c | sort -rn | head -20
```

典型根因是 **线程池被当作每次请求都新建**（`Executors.newFixedThreadPool` 在方法内创建）、或者 **HTTP 客户端每次调用新建连接池**。这类问题在代码 review 里几乎必抓。

---

## 六、两个 Error 的定位手段

### 6.1 StackOverflowError 的日志

JVM 默认只打印 **1024 层** 栈信息（`-XX:MaxJavaStackTraceDepth=1024`）。想看到真正深的那一层：

```bash
# 打印更多（注意：太大可能造成日志爆炸）
-XX:MaxJavaStackTraceDepth=20000
```

Fastjson 之类的框架日志里你会看到：

```text
java.lang.StackOverflowError: null
    at com.xxx.Parser.parse(...)
    at com.xxx.Parser.parse(...)
    ... （重复 1024 行）
```

**重复模式本身就是答案**：哪个方法在重复出现，就是爆栈点。

### 6.2 OOM: unable to create native thread 的日志

它**不会**生成 heap dump（因为不是堆耗尽），所以别指望 `-XX:+HeapDumpOnOutOfMemoryError`。要在 `-Xlog` 或 `hs_err_pid` 文件里找线程快照：

```bash
-XX:ErrorFile=/var/log/java/hs_err_pid%p.log
-XX:+CreateCoredumpOnCrash
```

### 6.3 Arthas 快速定位

```bash
# 看栈深度最深的调用
stack java.lang.Thread  # 追踪指定方法的调用栈

# 观察线程数趋势
dashboard
thread -n 5             # CPU 占用最高的 5 个线程
thread -b               # 死锁 / 阻塞检测
```

---

## 七、面试追问合集

**Q1：栈帧在堆上还是栈上？**
栈帧在虚拟机栈上，但 **逃逸分析后的对象可以被「标量替换」到栈上**（准确说是拆散为标量放进寄存器 / 栈帧），这是 JIT 的优化，不是 JVM 规范行为。经典追问是「对象一定分配在堆上吗」——答案是不一定。

**Q2：`-Xss` 设大一点能解决所有栈溢出吗？**
不能。它是缓解而非治疗，会付出线程数上限与虚拟内存的代价。正确做法是消除无界递归 / 给嵌套深度设上限。

**Q3：为什么 `catch (Exception)` 抓不到 StackOverflowError？**
因为 `StackOverflowError` 继承自 `VirtualMachineError` → `Error`，不在 `Exception` 分支上。而且此时栈已经很浅，能做的处理非常有限。

**Q4：无限递归一定能爆栈吗？**
不一定。如果递归里创建了大量对象，可能 GC 先顶不住抛出堆 OOM；如果递归发生在极少栈帧中（如循环内的递归），可能先 OOM。谁先抛出取决于栈空间与堆空间谁先耗尽。

**Q5：**`-Xss` 与 `Thread` 构造函数的 stackSize 谁优先？**
`new Thread(null, runnable, name, stackSize)` 显式指定优先；未指定时用 `-Xss`。注意 stackSize 是 hint，具体实现可忽略。

---

## 八、小结

| 问题 | 根因 | 排查入口 | 治理 |
| --- | --- | --- | --- |
| `StackOverflowError` | 栈帧数量超过 `-Xss` 允许的深度 | 日志里的重复帧模式 | 消除无界递归、限制嵌套深度 |
| `OOM: unable to create new native thread` | `pthread_create` 失败 | `ulimit -u`、`threads-max`、`pid_max`、cgroup pids | 收敛线程池、修正线程泄漏 |
| 线程创建慢 / CPU 高 | 线程数过多导致上下文切换 | `jstack` 线程名聚合 | 所有 IO 共用受控线程池 |

一句话总结：**栈的问题看「深度」，线程创建的问题看「限额」，不要一看到 OOM 就往 `-Xmx` 上加内存。**
