---
title: 【JVM 底层】JIT 去优化（Deoptimization）深度解析：Uncommon Trap、OSR 与热点代码回退
date: 2026-10-18 08:05:00
tags:
  - Java
  - JVM
  - JIT
  - 性能优化
  - 编译原理
categories:
  - Java 深挖
author: 东哥
---

# 【JVM 底层】JIT 去优化（Deoptimization）深度解析：Uncommon Trap、OSR 与热点代码回退

## 前言

提到 JIT，大部分人能说出「热点代码编译成机器码」「C1 快、C2 优化狠」「分层编译」。但很少有人关注 JIT 的**反向过程**：已经被编译成机器码的方法，会因为一个假设不成立，被**打回解释执行**。

这就是去优化（Deoptimization）。

它是 JVM 里最优雅也最容易被忽视的机制之一。理解它，你能解释很多「玄学」现象：

- 为什么服务刚启动时很快，跑了几小时反而慢了？
- 为什么加了一个实现类，某个接口调用突然掉了 30% 性能？
- 为什么 `@SneakyThrows`、动态代理、CGLIB 会让 C2 的优化失效？
- 为什么 `-XX:+PrintCompilation` 里同一个方法被反复编译（made not entrant）？

这篇文章从分层编译讲到去优化触发条件、栈上替换过程、日志观察方法、代码实验、生产案例和调优参数，最后给出面试追问。内容偏底层，但每一节都对应一个可观测的现象。

---

## 一、背景：分层编译的五层结构

HotSpot 的分层编译（Tiered Compilation）把执行状态分成五层：

| 层级 | 名称 | 编译器 | 特点 |
|---|---|---|---|
| 0 | 解释执行 | 无 | 启动快，逐条解释，带完整 profiling |
| 1 | C1 无 profiling | C1 | 简单优化，无 profile 数据 |
| 2 | C1 带轻量 profiling | C1 | 有限 profile（方法调用计数、分支） |
| 3 | C1 带完整 profiling | C1 | 完整 profile（类型、分支、循环），**最常用** |
| 4 | C2 | C2 | 基于 profile 做激进优化（内联、逃逸分析、CHM） |

典型路径：`0 → 3 → 4`。方法先被 C1 编译并**顺便收集 profile**，跑够热度后交给 C2 做深度优化。

关键点：**C2 的优化全部建立在「profile 显示的假设」上**。比如：

- 「这个 `invokeinterface` 的接收者类型 99.9% 是 `ArrayList`」→ 生成**单态内联缓存**，直接调用 `ArrayList.get`；
- 「这个 `if (obj != null)` 分支从来没走进过」→ 把 else 分支标记为 **uncommon trap**，移到代码末尾，主路径不留分支；
- 「这个类没有被继承过」→ 省略虚方法表查找，直接静态绑定；
- 「这个数组访问不会越界」→ 省略边界检查（range check elimination）。

只要假设被打破，JVM 就必须**把执行状态从优化后的机器码恢复到解释器能理解的状态**，然后重新解释执行。这个恢复过程就是去优化。

---

## 二、去优化的四大触发条件

### 2.1 Uncommon Trap（罕见陷阱）

C2 在编译时会插入 `uncommon_trap` 指令，对应「profile 里几乎不会发生」的分支。执行到它就触发去优化。

典型场景：

```java
public int classify(Object o) {
    if (o instanceof String s) {      // profile: 99.99% 是 String
        return s.length();
    }
    return -1;                         // 极少走，标记为 uncommon trap
}
```

当第一次传入 `Integer` 时，C2 编译的代码走到 trap，JVM 做三件事：

1. 把当前栈帧「反优化」成解释器帧（重建局部变量、操作数栈、monitor）；
2. 把该方法标记为 `made not entrant`（不再进入新调用）；
3. 重新解释执行，并**更新 profile**（现在知道有 Integer 分支了）。

> 注意：去优化不是「撤销编译」，已经编译的机器码还在，只是入口被禁用了。等热度再次达标，C2 会**基于新 profile 重新编译**。

### 2.2 类层次结构变化（CHM，Class Hierarchy Mutation）

这是生产中最常见的去优化来源。C2 的**类层次分析（CHA）**会记录「某接口只有一个实现」「某方法没有被覆写」，并据此做**单态内联**。

```java
public interface PayService { void pay(); }

// 假设全工程只有一个实现
public class AlipayService implements PayService {
    public void pay() { /* ... */ }
}

public void handle(PayService s) {
    s.pay();    // C2: 只有一个实现，直接内联 AlipayService.pay
}
```

某天你加了一个 `WechatPayService implements PayService`，JVM 在类加载时会走 `ClassHierarchyWalker`，发现已有优化假设失效，于是：

- 把所有依赖「PayService 单实现」的编译代码标记为 `made not entrant`；
- 相关调用点下次执行时回到解释器，重新收集 profile；
- 等再次变热，C2 编译成**双态内联缓存**（bimorphic）或直接虚调用。

这就解释了那个经典现象：**上线一个新实现类，接口 QPS 掉了 30%，过几分钟自己恢复了**——恢复的过程就是重新编译。

### 2.3 偏向锁撤销（Biased Locking Revocation）

偏向锁假设「锁总是被同一个线程获取」，因此把线程 ID 写进对象头，后续加解锁只需一次 CAS 比较。

一旦**另一个线程**尝试获取这把锁，就要撤销偏向：

1. 在该线程到达**安全点（safepoint）**时暂停；
2. 遍历栈帧，找到持有偏向锁的帧，修改锁记录（Lock Record）；
3. 升级为轻量级锁，并**对该线程的编译代码去优化**（因为编译代码里可能省略了完整的锁逻辑）。

JDK 15 起偏向锁默认关闭（JEP 374），JDK 18 后彻底移除相关代码，所以这条现在主要出现在 JDK 8/11 的老系统里。但**「撤销偏向锁导致 STW」**仍然是老系统 GC 日志里 `RevokeBias` 的来源。

### 2.4 编译假设失效的其他来源

| 触发源 | 说明 | 典型日志 |
|---|---|---|
| 空指针检查假设 | profile 显示某处永不为 null，C2 省略 null check | `uncommon trap: reason=null_check` |
| 数组越界假设 | 循环内边界检查被消除，越界时 trap | `reason=range_check` |
| 类型假设 | 强制类型转换的 profile 失效 | `reason=class_check` |
| 内联假设 | 被内联的方法被覆写 | `made not entrant` |
| 常量折叠 | `static final` 被反射修改（极少） | 重新编译 |

---

## 三、去优化的执行过程：栈上重建

去优化最复杂的部分是**栈帧重建**。C2 编译后的栈帧和解释器帧布局完全不同：

- 解释器帧：局部变量表 + 操作数栈，格式固定；
- C2 帧：寄存器分配 + 栈槽复用，很多「变量」其实只在寄存器里，甚至被常量折叠掉了。

为了能恢复，C2 在编译时生成 **debug info（ScopeDesc）**，记录每个机器码 PC 对应的「逻辑状态」：

```text
pc=0x00007f...  bci=42  scope=classify  locals=[o, s]  stack=[]
```

去优化时，`Deoptimization::unpack_frames` 会：

1. 根据 PC 找到 `ScopeDesc`；
2. 把寄存器/栈槽里的值搬回解释器帧的局部变量表；
3. 重建操作数栈；
4. 把返回地址改成解释器入口的 `deopt handler`；
5. 继续执行。

这也是为什么 **`-XX:+PrintDeoptimization` 只在 debug 版 JVM 可用**——完整日志会打印每个栈帧的重建细节，信息量巨大。

### 3.1 made not entrant vs made zombie

`-XX:+PrintCompilation` 里两个高频标记：

| 标记 | 含义 | 后续行为 |
|---|---|---|
| `made not entrant` | 该方法不再接受**新**调用，但栈上已有的调用可以继续跑完 | 等所有旧帧退出后，标记为 zombie |
| `made zombie` | 没有任何栈帧引用，机器码可被回收 | 代码缓存空间可复用 |

`made not entrant` 是「软下线」，`made zombie` 才是「可回收」。这解释了为什么高频去优化会导致**代码缓存（CodeCache）碎片化**：大量 not entrant 的代码占着空间却不能立刻复用。

---

## 四、怎么观察去优化

### 4.1 PrintCompilation

```bash
java -XX:+PrintCompilation -XX:+UnlockDiagnosticVMOptions \
     -XX:+PrintInlining -XX:+PrintCodeCache \
     -jar app.jar
```

输出示例：

```text
  12345  456 %     4       com.example.PayHandler::handle @ 18 (56 bytes)   made not entrant
  12346  457       3       com.example.PayHandler::handle (56 bytes)
  12347  458 %     4       com.example.PayHandler::handle @ 18 (56 bytes)
```

字段含义：

- `%`：OSR 编译（On-Stack Replacement，循环回边触发的编译）；
- `4`：C2 编译；
- `made not entrant`：被去优化；
- 同一个方法反复出现 `3 → 4 → not entrant → 4`：**去优化风暴**的信号。

如果每秒出现几十条 `made not entrant`，基本可以确定有东西在不断改变类层次或触发 uncommon trap。

### 4.2 JFR 的 Deoptimization 事件

JFR 有专门的 `jdk.Deoptimization` 事件：

```bash
jcmd <pid> JFR.start name=deopt settings=profile duration=60s
jcmd <pid> JFR.dump name=deopt filename=/tmp/deopt.jfr
jfr print --events jdk.Deoptimization /tmp/deopt.jfr
```

输出包含：

```text
jdk.Deoptimization {
  startTime = 12:34:56.789
  reason = "unstable_if"
  compileId = 4567
  compiler = "C2"
  method = "com.example.PayHandler.handle(PayService)"
  lineNumber = 42
  bci = 18
}
```

`reason` 是关键：

| reason | 含义 | 常见原因 |
|---|---|---|
| `unstable_if` | 分支方向反复变化 | 业务分支抖动（如 A/B 实验） |
| `unstable_fp` | 浮点运算结果不稳定 | 极少见 |
| `class_check` | 类型检查假设失效 | 新增实现类、多态膨胀 |
| `null_check` | 空值假设失效 | 首次出现 null |
| `range_check` | 数组边界假设失效 | 边界数据 |
| `bimorphic`/`megamorphic` | 调用点类型膨胀 | 接口实现过多 |

### 4.3 代码缓存监控

```bash
jcmd <pid> Compiler.codecache
```

```text
CodeCache: size=245760Kb used=180000Kb max_used=200000Kb free=65760Kb
 bounds [0x00007f..., 0x00007f...]
 total_blobs=12000 nmethods=11000 adapters=900
 compilation: enabled
```

如果 `nmethods` 很高但 `used` 接近 `size`，且大量 `made not entrant`，说明代码缓存在被去优化「污染」。可以考虑：

- 调大 `-XX:ReservedCodeCacheSize=512m`；
- 开启 `-XX:+UseCodeCacheFlushing`（JDK 8 默认开，JDK 11+ 行为有变化）；
- 减少动态生成类（Groovy、SpEL、大量 CGLIB 代理）。

---

## 五、可复现的实验

### 5.1 实验一：新增实现类触发 CHM

```java
public interface Shape { double area(); }

public class Circle implements Shape {
    public double area() { return 3.14 * 2 * 2; }
}

public class Bench {
    static double sum(Shape s, int n) {
        double total = 0;
        for (int i = 0; i < n; i++) total += s.area();
        return total;
    }

    public static void main(String[] args) throws Exception {
        Shape s = new Circle();
        // 预热：让 C2 编译并内联 Circle.area
        for (int i = 0; i < 20_000; i++) sum(s, 10_000);

        long t1 = System.nanoTime();
        sum(s, 100_000_000);
        System.out.println("before: " + (System.nanoTime() - t1) / 1_000_000 + "ms");

        // 关键：运行时加载第二个实现，触发 CHM
        Class<?> square = Class.forName("Square");
        Shape sq = (Shape) square.getDeclaredConstructor().newInstance();

        long t2 = System.nanoTime();
        double x = 0;
        for (int i = 0; i < 100_000_000; i++) x += sq.area();
        System.out.println("after: " + (System.nanoTime() - t2) / 1_000_000 + "ms, " + x);
    }
}
```

加上 `-XX:+PrintCompilation`，你会看到 `Bench::sum` 在 `Square` 加载后出现 `made not entrant`，随后被重新编译。

### 5.2 实验二：unstable_if

```java
static int hot(boolean flag, int n) {
    int c = 0;
    for (int i = 0; i < n; i++) {
        if (flag) c++;      // 始终 true 时，C2 会把 else 变 uncommon trap
        else c--;
    }
    return c;
}
```

先固定 `flag=true` 预热，再在循环中途切到 `false`，用 JFR 观察 `unstable_if`。

---

## 六、生产案例：三个真实场景

### 6.1 案例一：动态代理导致 megamorphic call site

**现象**：某服务接入 APM 后，核心接口 P99 从 12ms 涨到 40ms，CPU user 上升 25%。

**排查**：`-XX:+PrintCompilation` 发现 `OrderService::create` 反复 `made not entrant`。JFR 的 `jdk.Deoptimization` 显示 `reason=megamorphic`。

**根因**：APM 用 ByteBuddy 给每个 Service 生成了代理类，原本单态的 `orderService.create()` 调用点变成了「代理类 + 原类」双态，再叠加 Spring 的 `@Transactional` CGLIB 代理，最终变成 megamorphic，C2 放弃内联。

**解决**：把 APM 的代理改成「只增强入口 Controller」，Service 层不生成代理；或者升级 APM 版本使用更轻量的字节码注入。

### 6.2 案例二：灰度开关导致分支抖动

**现象**：灰度期间，推荐接口耗时曲线呈锯齿状，每隔几十秒抖动一次。

**排查**：JFR 显示 `unstable_if` 高频出现，方法集中在 `RecommendRouter::route`。

**根因**：灰度比例按用户 ID 哈希，同一批流量里新旧逻辑各占 10%/90%，但分支方向在**同一次压测循环内**反复变化。C2 无法预测分支，把两种路径都编译，还不断去优化。

**解决**：把灰度判断**提前到请求入口**，分成两个独立的 `Flux`/方法，让每个调用点内部的分支稳定；或者用「按流量分桶的路由表」替代 if/else。

### 6.3 案例三：代码缓存满导致「越跑越慢」

**现象**：服务运行 8 小时后 RT 缓慢上升，重启即恢复。

**排查**：`jcmd Compiler.codecache` 显示 `used` 接近 `size`，且 `nmethods` 异常高；`PrintCompilation` 大量 `made zombie` 后没有新编译。

**根因**：使用了 Groovy 脚本做规则引擎，每次规则变更都生成新类，导致代码缓存被撑满；JIT 编译器因空间不足停止编译，热点代码退回解释执行。

**解决**：规则引擎改为解释执行（或缓存 Class）、调大 `ReservedCodeCacheSize`、开启 `UseCodeCacheFlushing`，并把规则编译放到独立进程。

---

## 七、调优参数速查

| 参数 | 作用 | 建议 |
|---|---|---|
| `-XX:+PrintCompilation` | 打印编译/去优化事件 | 排障时开，常开会拖慢启动 |
| `-XX:+UnlockDiagnosticVMOptions -XX:+PrintInlining` | 打印内联决策 | 分析内联失败原因 |
| `-XX:+UseCodeCacheFlushing` | 清理僵尸代码 | 默认开启，动态类多时必开 |
| `-XX:ReservedCodeCacheSize=256m` | 代码缓存上限 | 大应用建议 256~512m |
| `-XX:TieredStopAtLevel=1` | 只用 C1 | 启动优先的场景（短生命周期任务） |
| `-XX:-TieredCompilation` | 关闭分层编译 | **不推荐**，会失去 profile 优化 |
| `-XX:CompileThreshold=10000` | 编译阈值 | 一般不动，压测时注意预热 |
| `-XX:-DoEscapeAnalysis` | 关闭逃逸分析 | 仅在排查标量替换问题时临时用 |

### 7.1 关于「预热」

去优化让「预热」变得更复杂：**预热不仅要让方法变热，还要让 profile 稳定**。

压测脚本如果只用一种数据类型、一种分支方向，C2 会做出激进假设；真实流量一上来，假设失效，服务反而变慢。所以生产压测应该：

1. **多样化输入**：null、空集合、多实现、边界值都要覆盖；
2. **足够长的稳定期**：让 profile 稳定后再看 P99；
3. **关注 `made not entrant` 数量**：稳态下应该接近 0。

---

## 八、面试追问

**Q1：什么是去优化？为什么需要它？**
去优化是把已编译的优化代码回退到解释执行的过程。因为 C2 的优化依赖 profile 假设（单态、非空、不越界），假设失效时必须恢复正确语义，否则会算错。它是「激进优化 + 正确性」之间的安全阀。

**Q2：去优化和反编译有什么区别？**
去优化是运行时行为，只恢复**执行状态**（栈帧、局部变量），不生成源码；反编译是静态分析字节码还原 Java 代码。两者没有关系。

**Q3：`made not entrant` 和 `made zombie` 的区别？**
`not entrant` 表示不再接受新调用，但栈上旧帧还能跑完；`zombie` 表示没有任何栈帧引用，机器码可回收。前者是逻辑下线，后者是物理可回收。

**Q4：为什么新增一个接口实现类会影响性能？**
C2 的 CHA 会基于「接口只有一个实现」做单态内联。新增实现会触发类层次变更，使依赖该假设的编译代码全部 `made not entrant`，调用点退回解释器并重新收集 profile，直到再次编译。

**Q5：OSR 是什么？和去优化有什么关系？**
OSR（On-Stack Replacement）是「栈上替换」：一个正在解释执行的长循环，热度达到阈值后，**在循环回边处**直接把解释帧替换成编译帧，不用等方法返回。它是「优化方向」的栈替换；去优化是反方向。两者共用同一套栈帧重建机制。

**Q6：如何减少去优化？**
① 减少运行期动态生成类；② 避免调用点类型膨胀（接口收敛、避免万能 Object 参数）；③ 灰度分支前置，避免热点循环内分支抖动；④ 保证压测输入多样性，让 profile 更接近真实；⑤ 代码缓存足够大，避免因空间不足停止编译。

**Q7：偏向锁撤销为什么会 STW？**
撤销需要在安全点遍历目标线程的栈，找到锁记录并修改对象头，期间该线程必须暂停。JDK 15 后偏向锁默认禁用，这个问题在新版本上基本消失。

---

## 总结

去优化是 JIT 的「纠错机制」，也是理解 JVM 性能波动的钥匙。记住这条因果链：

> **profile 假设 → C2 激进优化 → 假设失效 → uncommon trap / CHM → 栈帧重建 → 解释执行 → 重新收集 profile → 重新编译**

线上遇到「越跑越慢」「加个类就变慢」「灰度期间抖动」，先别怀疑 GC，打开 `-XX:+PrintCompilation` 和 JFR 的 `jdk.Deoptimization`，看 `reason` 是什么。多数时候，答案就在那几行日志里。
