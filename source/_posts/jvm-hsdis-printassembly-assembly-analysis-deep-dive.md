---
title: 【JVM 底层】汇编级 JIT 分析：hsdis、PrintAssembly 与「代码到底跑成了什么」
date: 2026-11-28 08:05:00
tags:
  - Java
  - JVM
  - JIT
  - 汇编
  - 性能优化
categories:
  - JVM
author: 东哥
---

# 【JVM 底层】汇编级 JIT 分析：hsdis、PrintAssembly 与「代码到底跑成了什么」

## 前言

一个做过十几次「微优化」的接口，JMH 稳定在 1800 ops/ms，而同组同事写的等价实现是 5200 ops/ms。用 `-XX:+PrintCompilation` 看，两个方法都被 C2 编译了；用 `-XX:+PrintInlining` 看，内联也发生了；看字节码，几乎一模一样。

最后把 `hsdis` 挂上，`-XX:+PrintAssembly` 打出来，问题一目了然：同事的版本里，那个接口调用被彻底去虚拟化成了直接 `call`，而且数组边界检查被循环提升到外面只做了一次；我的版本里，每次循环都在做 `cmp + jae` 的边界检查，还有一个间接 `call`。

**字节码相同不代表机器码相同**。JIT 看到的是「运行时类型画像」，它在你的代码上做的假设、做的消除，全是字节码里看不出来的。

这篇讲三件事：怎么把汇编打出来、怎么读懂它、以及怎么用它验证「我以为 JIT 会做的优化，它到底做了没有」。

> 分工说明：站内已有《JIT 编译优化》《JIT Intrinsic 内建函数》《逃逸分析与标量替换》《Code Cache 调优》。本篇专攻**工具链与汇编阅读**：怎么拿到机器码、每一类指令对应什么 Java 语义、以及如何用最小实验验证优化是否发生。

---

## 一、工具链：hsdis 是什么，为什么 JDK 不自带

`hsdis` 是 HotSpot 的反汇编插件（一个动态库），HotSpot 通过它把生成的机器码交给反汇编器（内部用的是 binutils 的 libopcodes）。因为许可证和体积原因，Oracle/OpenJDK 的官方二进制**默认不带**它，需要单独获取或自行编译。

### 获取与放置

Linux x86_64 下需要的是 `libhsdis-amd64.so`：

```bash
# 方式一：发行版/第三方构建（如 liberica、zulu 的部分发行版自带 hsdis）
# 方式二：自己编译（需要 binutils 源码）
git clone https://github.com/openjdk/jdk
# 按 jdk/src/utils/hsdis/README 的说明，配置 --with-binutils=/path/to/binutils
# 产物：build/linux-x86_64-server-release/support/hsdis/libhsdis-amd64.so

# 放置位置（JDK 9+）
cp libhsdis-amd64.so $JAVA_HOME/lib/server/
# 验证
java -XX:+UnlockDiagnosticVMOptions -XX:+PrintAssembly -version 2>&1 | head
```

如果放错位置，JDK 会在 stderr 静默提示一句 `Could not load hsdis-amd64.so; library not loadable; PrintAssembly is disabled`。**很多人以为参数写错了，其实是库没加载上**。

### 最小可用参数组合

```bash
java -XX:+UnlockDiagnosticVMOptions \
     -XX:+PrintAssembly \
     -XX:PrintAssemblyOptions=intel \
     -XX:CompileCommand=print,com.example.Bench::hot \
     -XX:+PrintCompilation \
     -jar bench.jar
```

逐个解释：

| 参数 | 作用 | 坑 |
|---|---|---|
| `-XX:+UnlockDiagnosticVMOptions` | 解锁诊断参数 | 缺少它时 `PrintAssembly` 直接不生效 |
| `-XX:+PrintAssembly` | 输出反汇编 | 日志量极大，必须配 `CompileCommand` 收窄 |
| `-XX:PrintAssemblyOptions=intel` | Intel 语法 | 默认 AT&T（`movq 0x8(%rsi),%rax`），Intel 语法更接近 Java 教材 |
| `-XX:CompileCommand=print,Class::method` | 只打印指定方法 | 类名用全限定名，方法名不带签名 |
| `-XX:+PrintCompilation` | 打印编译事件 | 用来对齐「这次汇编对应哪次编译」 |

---

## 二、三层日志，别混着看

### 第一层：谁被编译了（PrintCompilation）

```
    142   45 %     4       com.example.Bench::hot @ 12 (156 bytes)
    143   46       3       com.example.Bench::cold (48 bytes)
    201   45       4       com.example.Bench::hot (156 bytes)   made not entrant
```

字段含义：

- `142`：JVM 启动后的毫秒数
- `45`：编译任务 ID
- `%`：这是一次 **OSR 编译**（On-Stack Replacement，循环执行中被就地编译）
- `4`：C2（分层编译的 0 解释、1-3 C1、4 C2）
- `@ 12`：OSR 的字节码位置
- `made not entrant`：这段代码被判定失效（去优化或类层次变化），后续调用会走新版本

**看到 `made not entrant` 就必须警觉**：说明你的「热点方法」在运行中反复失效重编，可能是类型画像不稳定（同一个调用点出现多种接收者类型），性能会周期性抖动。

### 第二层：优化决策（PrintInlining / PrintIntrinsics）

```bash
-XX:+UnlockDiagnosticVMOptions -XX:+PrintInlining
```

输出形如：

```
@ 12   com.example.Foo::bar (12 bytes)   inline (hot)
  @ 4   java.lang.String::length (6 bytes)   intrinsic
@ 20   com.example.Slow::work (340 bytes)   hot method too big
```

`hot method too big` 对应 `FreqInlineSize`（默认 325 字节）；`inline (hot)` 说明命中了热路径放宽；`intrinsic` 说明被内建函数替换。这一层能解释 80% 的「为什么没内联」。

### 第三层：机器码（PrintAssembly）

这才是本文主角。它输出的是「最终要执行的字节序列」，也是唯一能证明「优化真的发生了」的证据。

---

## 三、读汇编前必须知道的约定

HotSpot 的 C2 在 x86_64 上遵循一套内部约定，不懂这几条会完全读不懂：

| 约定 | 说明 |
|---|---|
| Java 参数寄存器 | 依次是 `rsi, rdx, rcx, r8, r9`（`rsi` 常是 `this`） |
| 返回值 | `rax`（long/int）、`xmm0`（float/double） |
| 对象布局 | 偏移 `0x0` 是 mark word（8B），`0x8` 是 Klass 指针（开启压缩类指针时 4B），字段从 `0x10` 开始 |
| 数组长度 | 偏移 `0x8`（对象头之后），元素从 `0x10`/`0x14` 开始（取决于元素类型） |
| 线程本地 | `r15` 通常是当前 JavaThread，`r12` 是 heap base（压缩 oops 时） |
| 异常/慢路径 | 通过 `call` 到 stub（如 `_UncommonTrapBlob`）实现，不是 `throw` 指令 |

一个最简单的例子，`int add(int a, int b) { return a + b; }` 编译后可能只有：

```asm
# {method} 'add' '(II)I'
mov    %edx,%eax      # eax = b
add    %esi,%eax      # eax += a
ret
```

没有栈帧、没有内存访问。这就是「JIT 把一切都消掉了」的样子。

---

## 四、五类指令，对应五类 Java 语义

### 1. 空指针检查 → `test` + 条件跳转

```asm
test   %rsi,%rsi
je     L_null_trap        # 跳到 uncommon trap，触发 NPE 并去优化
mov    0x10(%rsi),%eax    # 读字段
```

**这说明 JIT 把隐式 NPE 变成了显式检查**。如果某段代码在循环里反复做同一个对象的空检查，把这个对象提到循环外（或用局部变量固定）有时能帮助 C2 消除重复检查。

### 2. 数组边界检查 → `cmp` + `jae`

```asm
mov    0x8(%rsi),%edx     # edx = array.length
cmp    %edx,%ecx          # 比较 index 与 length
jae    L_range_trap       # 越界 -> uncommon trap
```

如果循环条件已经保证了 `i < arr.length`，C2 通常会**把检查提升到循环外**，或者在 `for (int i = 0; i < arr.length; i++)` 这种规范形态下彻底消除。这也是「增强 for 循环有时比手写索引快」的真实原因之一。

### 3. 虚调用 → 直接 `call` 还是间接 `call`

```asm
# 未去虚拟化（单态但还没优化 / 多态）
mov    (%rsi),%rax          # 取 Klass
mov    0x1b8(%rax),%rax     # 取 vtable 中的方法槽
call   *%rax

# 去虚拟化 + 内联之后：整个调用消失，直接是方法体的指令
```

**去虚拟化的前提是「这个调用点只见过一种接收者类型」**（monomorphic）。一旦出现第二种类型，C2 会插入类型检查 + uncommon trap，或者直接 `made not entrant` 重编。这就是「加了第二个实现类，接口突然变慢」的机制。

### 4. 锁 → `lock cmpxchg`

```asm
lock cmpxchg %rdx,(%rsi)   # 轻量级锁 CAS 抢 mark word
jne  L_inflate_or_slow     # 失败 -> 走 ObjectMonitor::enter
```

看到 `lock` 前缀就说明这里有原子操作。如果是「本该没有竞争的锁」却频繁出现 `lock cmpxchg` 甚至 `call ObjectMonitor::enter`，说明锁竞争或锁消除没生效（例如锁对象逃逸了）。

### 5. 内建函数 → stub `call`

```asm
call   Stub::jbyte_disjoint_arraycopy
```

看到 `call Stub::xxx` **不是没内联**，而是命中了 intrinsic：`System.arraycopy`、`Arrays.copyOf`、`String.indexOf`、`Math.sqrt` 等会被替换成高度优化的手写汇编或 stub。这和「普通 Java 方法调用的 `call`」完全不同。

同理，`call` 到 `_UncommonTrapBlob` 也不是业务调用，而是「假设失败时的逃生通道」。

---

## 五、四个可以自己复现的实验

### 实验 1：逃逸分析是否消掉了对象分配

```java
@Benchmark
public long scalar() {
    Point p = new Point(1, 2);   // 期望被标量替换
    return p.x + p.y;
}
```

汇编里如果看到 **没有任何 `new` 相关的分配调用**（没有 `call Stub::new_instance`、没有 `TLAB` 相关指令），只有两次常量加法或直接返回常量 3，就说明标量替换生效了。

### 实验 2：接口去虚拟化

```java
interface Op { int apply(int x); }
static final class Inc implements Op { public int apply(int x) { return x + 1; } }

// 只喂 Inc 实例
for (int i = 0; i < 1_000_000; i++) sum += op.apply(i);
```

第一次跑：应该看到直接内联后的 `add`。然后改成在循环里混入第二个实现类，重跑，观察 `PrintCompilation` 出现 `made not entrant`，汇编里出现 vtable 间接调用 + 类型检查。**这是理解「单态/双态/巨态」最直观的实验**。

### 实验 3：自动向量化（SuperWord）

```java
for (int i = 0; i < n; i++) c[i] = a[i] + b[i];
```

C2 的 SuperWord（`-XX:+UseSuperWord`，默认开）会把 4 个 int 打包成 `xmm` 做 `paddd`：

```asm
vmovdqu (%rsi,%rcx,4),%xmm0
vpaddd  (%rdx,%rcx,4),%xmm0,%xmm0
vmovdqu %xmm0,(%rdi,%rcx,4)
```

看到 `vpaddd` / `vmulpd` 就说明向量化了。注意 Java 的自动向量化非常保守：循环体复杂、有分支、有跨迭代依赖就会退化，这也是 Vector API 存在的意义。

### 实验 4：内联失败的边界

把方法体故意写到 400 字节以上，观察 `PrintInlining` 输出 `hot method too big`，再对比 `-XX:CompileCommand=inline,Class::method` 强制内联后的汇编差异。**这是验证「方法拆分对性能有实际影响」的唯一硬证据**。

---

## 六、六个必须知道的坑

1. **分层编译让你看到的不是最终形态**。默认 0-4 层，C1 先上，C2 后上。想只看 C2：`-XX:-TieredCompilation`（注意这会改变整体性能特征，只用于观察）。
2. **OSR 编译的代码和普通编译不一样**。`%` 标记的那次编译是「循环执行到一半就地替换」，它的栈帧布局和循环结构都不同。分析热点循环时要分清看的是哪一次。
3. **`PrintAssembly` 本身严重拖慢程序**。它要格式化成千上万行文本，还会影响 code cache 行为。**永远不要**在压测时开着它取性能数据。
4. **汇编随 JDK 版本变化**。同一段 Java 在 JDK 8 / 17 / 21 上生成的指令可能完全不同（比如偏向锁在 15 之后被废弃、ZGC 屏障、CDS 影响常量折叠）。结论必须绑定版本。
5. **`compileonly` 会让方法永远停留在解释执行的其他调用点**，改变内联决策，实验时要清楚自己在测什么。
6. **`-XX:+PrintOptoAssembly` 需要 fastdebug 构建**，生产版 JDK 用不了，别照抄博客。生产可用的是 `PrintAssembly`（配合 hsdis）和 `-Xlog:jit+compilation=debug`。

---

## 七、生产环境怎么用（不用 hsdis 的替代方案）

线上不可能挂 `PrintAssembly`，但可以做三件事：

```bash
# 1. 编译事件与去优化（开销很小，可常开采样）
-Xlog:jit+compilation=info:file=/var/log/app/jit.log:time,uptime:filecount=5,filesize=20M

# 2. JFR 采集编译事件
-XX:StartFlightRecording=settings=profile,dumponexit=true

# 3. 热点方法定位
async-profiler: ./profiler.sh -e cpu -d 30 -f /tmp/flame.html <pid>
```

配合 `jcmd <pid> Compiler.queue`、`jcmd <pid> Compiler.codecache` 可以判断：

- 是否有方法在反复 `made not entrant`（类型画像不稳 / 类加载导致去优化）；
- code cache 是否接近满（`CodeCache is full` 之后 JIT 完全停止，性能断崖）；
- 编译线程是否排队（大量方法等待编译，启动期抖动）。

JFR 里的 `jdk.Compilation` 事件带 `compileId`、`method`、`compileLevel`、`succeeded`、`isOsr`，足以定位「哪个方法编译失败/被禁用」。

---

## 八、面试追问

**Q1：字节码一样，为什么性能差很多？**
因为 JIT 依赖运行时类型画像做去虚拟化、内联、逃逸分析、边界检查消除。画像不同（单态 vs 多态）、内联预算不同、循环形态不同，最终机器码可以完全不同。

**Q2：`call` 出现在汇编里，是不是说明没内联？**
不一定。可能是 intrinsic stub（`arraycopy`）、可能是 uncommon trap、可能是真正的未内联调用。要看 `call` 的目标符号。

**Q3：为什么方法被 `made not entrant`？**
常见原因：类层次变化（新子类加载导致去虚拟化假设失效）、类型画像变化（单态变多态）、依赖的常量/method handle 失效、显式去优化（`Deoptimize` 指令）。频繁发生意味着性能抖动。

**Q4：`-XX:MaxInlineSize` 和 `-XX:FreqInlineSize` 有什么区别？**
前者是「非热点方法」的内联上限（默认 35 字节），后者是「热点方法」的上限（默认 325 字节）。调大能内联更多，但会增加编译时间和 code cache 压力。

**Q5：为什么不能靠微基准测试的汇编结论直接指导生产？**
因为生产环境的调用点画像更复杂（多实现、多分支）、有 OSR、有去优化、有 GC 屏障差异。汇编只能证明「这条路径上 JIT 做了什么」，不能证明「整体更快」。

---

## 小结

- `hsdis` 让 HotSpot 把机器码打出来，是验证 JIT 优化的**唯一硬证据**；
- 三层日志分工明确：`PrintCompilation` 看谁被编译、`PrintInlining` 看决策、`PrintAssembly` 看结果；
- 读汇编先认约定：参数寄存器、对象头偏移、数组长度偏移、stub 调用；
- 五类指令对应五类语义：空检查、边界检查、虚调用、锁、intrinsic；
- 汇编会随版本和画像变化，任何结论都要绑定「JDK 版本 + 输入分布」。

会用 `PrintAssembly` 的人，和只会看火焰图的人，差距不在工具，而在「能不能证明」。火焰图告诉你哪里热，汇编告诉你为什么热。
