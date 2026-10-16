---
title: 【Java 面试】JVM 高频面试题总结：内存结构、垃圾回收、类加载与调优 40 问
date: 2026-10-16 08:00:00
tags:
  - Java
  - JVM
  - 面试
  - 垃圾回收
  - 类加载
categories:
  - Java 面试
author: 东哥
---

# 【Java 面试】JVM 高频面试题总结：内存结构、垃圾回收、类加载与调优 40 问

## 前言

JVM 是 Java 面试里**区分度最高的模块**：八股好背，但面试官只要往下追问两层，就能看出你是"背过"还是"真的用过"。这篇文章把 JVM 面试拆成五条主线——运行时数据区、对象与内存分配、垃圾回收、类加载、故障排查与调优——每条主线给出**高频问题 + 标准回答 + 面试官可能的追问 + 加分答法**，并配上能跑起来的代码与参数。

> 适用人群：有 1~5 年 Java 经验、准备跳槽的后端工程师。建议先自己答一遍，再看"加分答法"。

## 一、运行时数据区：那几张图到底在画什么

**Q1：JVM 运行时数据区有哪些？哪些线程私有？**

- 线程私有：**程序计数器（PC）、虚拟机栈、本地方法栈**。
- 线程共享：**堆、方法区（JDK8 起为元空间 Metaspace，位于本地内存）**。
- 此外还有**直接内存**（Direct Memory，NIO/Netty 大量使用，不受 `-Xmx` 限制，受 `-XX:MaxDirectMemorySize` 与物理内存限制）。

**加分答法**：不要只背名字，补一句"为什么"——

- 为什么方法区要挪到本地内存？因为永久代（PermGen）用 `-XX:MaxPermSize` 固定，动态生成类（CGLIB 代理、Groovy、热部署）容易触发 `OutOfMemoryError: PermGen space`；JDK8 换成元空间后按需向 OS 申请，只受机器内存限制。
- 字符串常量池 JDK7 起从方法区**挪到了堆**，因为它本质是 `StringTable`（一个 HashTable），放堆里便于 GC。

**Q2：栈帧里有什么？**

局部变量表、操作数栈、动态链接、方法返回地址、附加信息。局部变量表以 **Slot** 为单位（32 位一个 Slot，`long/double` 占两个）。

**追问**：为什么递归太深报的是 `StackOverflowError` 而不是 `OutOfMemoryError`？因为栈是**固定大小**（`-Xss`），装不下新栈帧就抛 SOE；而堆是弹性扩容的，装不下才抛 OOM。

## 二、对象的一生与内存分配

**Q3：对象创建的过程？**

类加载检查 → 分配内存（指针碰撞 / 空闲列表）→ 内存置零 → 设置对象头（Mark Word + 类型指针）→ 执行 `<init>`。

**Q4：对象在堆上如何分配？TLAB 是什么？**

```java
// 逃逸分析 + 标量替换：下面这个对象可能根本不进堆
public int calc() {
    Point p = new Point(1, 2); // 未逃逸，JIT 可能标量替换到栈上
    return p.x + p.y;
}
```

- **TLAB（Thread Local Allocation Buffer）**：每个线程在 Eden 里预分配一小块私有内存，分配时**无需加锁**（否则多线程指针碰撞要 CAS）。
- **逃逸分析**：对象未逃逸出方法 → 可**栈上分配**；对象可拆散 → **标量替换**；对象不可变 → **锁消除**。生产上用 `-XX:+DoEscapeAnalysis`（默认开）。

**追问**：`new` 出来的对象一定在堆上吗？不一定——逃逸分析后可能栈上分配或被标量替换，但这是 JIT 优化，语义上仍当它是堆对象。

**Q5：对象的内存布局？**

对象头（Mark Word：哈希码/GC 分代年龄/锁状态；Klass Pointer）+ 实例数据 + 对齐填充（8 字节对齐）。**指针压缩** `-XX:+UseCompressedOops` 让 64 位下引用只占 4 字节（堆 < 32G 时默认开），能省 30%+ 内存。

## 三、垃圾回收：从"怎么判断"到"怎么回收"

**Q6：如何判断对象可以回收？为什么不用引用计数？**

用**可达性分析**，GC Roots 包括：虚拟机栈局部变量、方法区静态变量/常量、本地方法栈 JNI 引用、活跃线程等。不用引用计数是因为**循环引用**无法回收（`a.b=b; b.a=a;`）。

**Q7：三种垃圾回收算法与分代设计？**

| 算法 | 优点 | 缺点 | 适用 |
|---|---|---|---|
| 标记-清除 | 简单 | 碎片化、效率低 | CMS |
| 标记-复制 | 无碎片、快 | 浪费一半空间 | 新生代（Serial/ParNew/G1 的 Survivor） |
| 标记-整理 | 无碎片 | 移动对象成本高 | 老年代（Serial Old/G1） |

**分代假说**：绝大多数对象朝生夕死 → 新生代用复制（Eden:S0:S1 = 8:1:1，浪费仅 10%）；少数长期存活 → 老年代用整理。

**Q8：对象什么时候进老年代？**

1. 年龄达到 `-XX:MaxTenuringThreshold`（默认 15）；
2. **动态年龄判定**：Survivor 中同龄对象总和 > Survivor 一半，则 ≥ 该年龄的直接晋升；
3. **大对象**直接进老年代（`-XX:PretenureSizeThreshold`）；
4. **空间分配担保**：Minor GC 前若老年代可用空间 < 新生代存活对象总大小，则触发担保（可能 Full GC）。

**Q9：Minor GC / Major GC / Full GC 的区别？**

Minor GC 只清新生代；Major/Old GC 清老年代；Full GC 清理**整个堆和方法区**，会 STW，是调优要重点压制的对象。常见触发原因：`System.gc()`、老年代空间不足、元空间不足、空间分配担保失败、CMS 的 Concurrent Mode Failure。

**Q10：G1 vs ZGC 怎么选？**

| 收集器 | 停顿 | 堆规模建议 | 特点 |
|---|---|---|---|
| G1 | 可预测（`-XX:MaxGCPauseMillis`） | 4~32G | Region 化、Mixed GC、默认 JDK9+ |
| ZGC | < 1ms（不分代时代） | 大内存 8G~TB | 染色指针 + 读屏障，几乎不 STW |
| Shenandoah | 低停顿 | 中大堆 | 与 ZGC 定位类似 |

**加分答法**：ZK/JDK 版本 + 业务 SLO（比如 P99 < 200ms）→ 先定停顿目标，再选收集器；大堆 + 极低延迟选 ZGC，通用选 G1。

## 四、类加载：双亲委派不是背口诀

**Q11：类加载过程？**

加载 → 验证 → 准备 → 解析 → 初始化，之后是使用和卸载。**准备阶段**给静态变量赋零值，**初始化阶段**才执行 `clinit` 赋值。

```java
public class Init {
    static int a = 1;              // 准备阶段 a=0，初始化阶段 a=1
    static final int B = 2;        // 常量，编译期入常量池，准备阶段就是 2
    static final int C = (int)(Math.random()*10); // 运行期常量，初始化阶段才赋值
}
```

**Q12：双亲委派模型与破坏它的场景？**

加载时先委派给父加载器，父加载不了才自己加载，保证核心类不被篡改。破坏场景：
- **SPI（JDBC）**：`Thread.currentThread().getContextClassLoader()`——父加载器要反向加载子类加载器的实现；
- **Tomcat**：WebappClassLoader 先自己加载（应用隔离），再委派；
- **OSGi/热部署**：追求隔离与动态性。

**追问**：怎么自己写一个类加载器？继承 `ClassLoader` 重写 `findClass`（别重写 `loadClass`，否则破坏双亲委派），读取 `.class` 字节后 `defineClass`。

## 五、排查与调优：面试官最爱问的"实际场景"

**Q13：线上 CPU 100% 怎么排查？**

```bash
top -Hp <pid>            # 找到占 CPU 的线程 tid
printf "%x\n" <tid>      # tid 转 16 进制
jstack <pid> | grep -A30 <hex-tid>   # 定位线程栈
# 更进一步：async-profiler 出火焰图
./profiler.sh -d 30 -f cpu.html <pid>
```

常见根因：死循环、正则回溯（`(a+)+` 灾难性回溯）、频繁 Full GC、锁竞争自旋。

**Q14：OOM 堆转储怎么分析？**

```bash
# 启动参数，OOM 时自动 dump
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/data/dump
# 分析
jmap -histo:live <pid> | head -20     # 快速看对象直方图
# 再用 MAT 打开 .hprof，看 Dominator Tree 找"支配"内存的对象
```

**加分答法**：区分五种 OOM——`Java heap space`（堆泄漏/大对象）、`Metaspace`（动态生成类过多）、`GC overhead limit exceeded`（GC 救不回来）、`Direct buffer memory`（堆外没释放）、`unable to create native thread`（线程数超限，检查线程池与 `-Xss`）。

**Q15：为什么用 IDEA 调试时改代码能生效？**

热部署/热替换（HotSwap）——`Instrumentation` 提供 `redefineClasses`，JVM 本身就支持方法体替换（但不能改方法签名、增删字段）。JRehbel/Spring Boot DevTools 在此之上扩展。

## 六、高频追问速查（收尾）

- **`-Xms` 和 `-Xmx` 设成一样好吗？** 好，避免堆反复伸缩带来的抖动、也利于容器内存核算。
- **为什么元空间也会 OOM？** 动态代理/CGLIB/Groovy 不停生成类，`-XX:MaxMetaspaceSize` 未设上限时会吃满物理内存。
- **堆外内存泄漏怎么查？** `-XX:NativeMemoryTracking=summary` + `jcmd <pid> VM.native_memory`，或 NMT + `pmap` 对差。
- **CMS 的 Concurrent Mode Failure 是什么？** 并发清理时老年代又满了，被迫退化成 Serial Old 单线程 Full GC，停顿暴涨——调优靠降低 CMS 触发阈值（`-XX:CMSInitiatingOccupancyFraction`）。

## 总结

JVM 面试的破题逻辑：**先讲机制，再讲"为什么这么设计"，最后落到一个你亲手处理过的案例**。运行时数据区是地基，垃圾回收是核心，类加载是隔离与动态性的关键，排查调优是区分度所在。把本文的 40 问过一遍，再挑 2~3 个自己真踩过的坑（比如正则回溯打满 CPU、堆外泄漏吃光容器内存）讲成故事，JVM 这一关基本就稳了。

下一篇会写 **Spring 高频面试题总结**，把 IoC/AOP/事务/循环依赖串成一条线，欢迎关注。
