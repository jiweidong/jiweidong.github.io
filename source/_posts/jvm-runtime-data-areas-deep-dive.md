---
title: 【JVM 底层】JVM 运行时数据区深度解析：从内存模型到 OOM 实战
date: 2026-08-23 08:00:00
tags:
  - JVM
  - 内存模型
  - 运行时数据区
  - OOM
  - 面试
categories:
  - JVM
  - JVM底层
author: 东哥
---

# 【JVM 底层】JVM 运行时数据区深度解析：从内存模型到 OOM 实战

## 面试官：说说 JVM 的运行时数据区，哪些是线程共享的？

> 这是 JVM 面试的第一道必考题。答全五个区域 + 直接内存只是及格，能讲清楚每个区域的**作用、异常类型、参数控制、OOM 案例**才是高分。本文按"是什么 → 存什么 → 怎么配置 → 出什么问题"的结构，把运行时数据区彻底讲透。

## 一、总览：运行时数据区全景图

JVM 执行 Java 程序时会把它管理的内存划分为若干区域，即**运行时数据区（Runtime Data Area）**。按《Java 虚拟机规范》（Java SE 17 版）分为：

```
┌─────────────────────────────────────────────┐
│             线程共享区域                      │
│  ┌───────────────────────────────────────┐  │
│  │              堆（Heap）                │  │  ← 对象实例、数组（GC 主战场）
│  ├───────────────────────────────────────┤  │
│  │  方法区（Method Area）→ 元空间 Metaspace│  │  ← 类信息、常量、静态变量
│  │  运行时常量池（Runtime Constant Pool）  │  │
│  └───────────────────────────────────────┘  │
├─────────────────────────────────────────────┤
│             线程私有区域                     │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐  │
│  │ 虚拟机栈   │ │ 本地方法栈 │ │ 程序计数器 │  │  ← 栈帧、native 方法、字节码行号
│  │(VM Stack) │ │(Native    │ │(PC Register)│ │
│  └───────────┘ └───────────┘ └───────────┘  │
├─────────────────────────────────────────────┤
│             直接内存（Direct Memory）        │  ← 堆外，NIO/Netty 使用
└─────────────────────────────────────────────┘
```

| 区域 | 线程共享？ | 存什么 | 异常 |
|---|---|---|---|
| 程序计数器 | 否（私有） | 当前线程执行的字节码行号 | 无（唯一不 OOM 的区域） |
| 虚拟机栈 | 否（私有） | 栈帧：局部变量表、操作数栈、动态链接、返回地址 | `StackOverflowError` / `OutOfMemoryError` |
| 本地方法栈 | 否（私有） | native 方法调用栈 | 同上 |
| 堆 | **是** | 对象实例、数组 | `OutOfMemoryError: Java heap space` |
| 方法区（元空间） | **是** | 类元信息、常量、静态变量、JIT 产物 | `OutOfMemoryError: Metaspace` |
| 直接内存 | — | NIO 的 DirectByteBuffer 数据 | `OutOfMemoryError: Direct buffer memory` |

## 二、程序计数器（Program Counter Register）

- **作用**：记录当前线程正在执行的字节码指令地址。多线程切换后，靠 PC 寄存器恢复到正确的执行位置；
- **特点**：
  1. 线程私有，**每个线程一个**；
  2. 执行 Java 方法时存字节码地址，执行 native 方法时为 undefined；
  3. **唯一不会抛出 OOM 的区域**（规范规定它不需要任何内存容量限制）。

## 三、虚拟机栈（Java Virtual Machine Stack）

### 3.1 栈帧结构

每次**方法调用**都会创建一个**栈帧（Stack Frame）**入栈，方法结束出栈。一个栈帧包含：

```
┌───────────────────────────────┐
│ 局部变量表 Local Variables    │  ← 基本类型、引用类型、returnAddress（槽位 slot，long/double 占 2 槽）
├───────────────────────────────┤
│ 操作数栈 Operand Stack        │  ← 字节码指令的运算工作区（iadd 从栈顶取数）
├───────────────────────────────┤
│ 动态链接 Dynamic Linking      │  ← 指向运行时常量池的方法引用（符号引用 → 直接引用）
├───────────────────────────────┤
│ 方法返回地址 Return Address   │  ← 正常返回 / 异常返回的恢复位置
├───────────────────────────────┤
│ 附加信息（如调试信息）        │
└───────────────────────────────┘
```

### 3.2 两个经典问题

**Q1：栈溢出的两种姿势**

```java
// ① 无限递归 → StackOverflowError
public void loop() {
    loop();   // 栈帧无限入栈，深度超过默认（约 512KB-1MB，看 JVM 实现）
}

// ② 栈内放超大局部变量 → OOM
public void big() {
    byte[] arr = new byte[1024 * 1024 * 100];  // 局部变量表槽位放不下，尝试扩容失败
}
```

**Q2：栈深度和 Xss 的关系**

```bash
java -Xss256k   # 默认 Linux x64 约 1MB，调小可增加线程数，但递归深度下降
```

**栈帧大小由局部变量表 + 操作数栈决定，编译期即可确定**，这也是 JVM 不需要对栈做 GC 的原因——栈帧随方法调用出栈，生命周期明确。

## 四、本地方法栈（Native Method Stack）

- 与虚拟机栈作用类似，但服务于 **native 方法**（如 `Thread.start()` 底层调用的 JNI 方法）；
- HotSpot 虚拟机把两者**合二为一**（`-Xss` 同时控制）；
- 异常与虚拟机栈相同。

## 五、堆（Heap）：GC 的主战场

### 5.1 结构（分代模型）

```
堆（-Xms 初始 / -Xmx 最大）
├── 新生代 Young Gen（默认 1/3）→ 对象"出生地"，Minor GC 频繁
│   ├── Eden（默认 8/10）→ 新对象优先分配
│   ├── Survivor 0（1/10）
│   └── Survivor 1（1/10）→ 复制算法，年龄 +1
└── 老年代 Old Gen（默认 2/3）→ 年龄达标（默认 15）晋升，Major GC 较慢
```

### 5.2 关键参数

```bash
-Xms512m -Xmx512m        # 初始/最大堆（生产建议相等，避免扩容抖动）
-Xmn256m                 # 新生代大小
-XX:NewRatio=2           # 老年代:新生代 = 2:1
-XX:SurvivorRatio=8      # Eden:Survivor = 8:1
-XX:MaxTenuringThreshold=15  # 晋升年龄阈值
```

### 5.3 OOM 实战：Java heap space

```java
List<byte[]> list = new ArrayList<>();
while (true) {
    list.add(new byte[10 * 1024 * 1024]);  // 每轮 10MB
}
// 异常：java.lang.OutOfMemoryError: Java heap space
```

排查三板斧：
1. `jmap -dump:format=b,file=heap.hprof <pid>` 或 `-XX:+HeapDumpOnOutOfMemoryError` 自动转储；
2. MAT / JProfiler 分析 **Dominator Tree**（支配树）找大对象；
3. 重点看：对象是否被静态集合持有（`static List`）、缓存无淘汰、连接未释放。

## 六、方法区与运行时常量池：从 PermGen 到 Metaspace

### 6.1 存什么

- **类元信息**：类名、访问修饰符、字段/方法描述、接口信息；
- **运行时常量池**：字面量（字符串、final 常量）+ 符号引用（类、方法、字段的符号）；
- **静态变量**（JDK 7 后对象实例部分移到堆，类型信息仍在方法区）；
- **JIT 编译产物**（代码缓存）。

### 6.2 演进历史

| 版本 | 实现 | 参数 | 特点 |
|---|---|---|---|
| JDK 6 及以前 | **永久代 PermGen**（堆内） | `-XX:PermSize -XX:MaxPermSize` | 大小固定，易 OOM：`PermGen space` |
| JDK 7 | 永久代，字符串常量池移到堆 | 同上 | 过渡期 |
| **JDK 8+** | **元空间 Metaspace**（本地内存） | `-XX:MetaspaceSize -XX:MaxMetaspaceSize` | 默认使用**本地内存**，默认无上限 |

**为什么改元空间？**
1. 永久代大小难预估，字符串常量池 + 类加载过多极易 OOM；
2. 永久代需要 Full GC 才能回收，元空间由本地内存管理，**类卸载（如热部署）更彻底**；
3. 本地内存不再受堆大小限制，减少"容量焦虑"，但**要设上限防失控**。

### 6.3 OOM 实战：Metaspace

```java
// 用 CGLIB/ASM 疯狂生成新类
while (true) {
    Enhancer enhancer = new Enhancer();
    enhancer.setSuperclass(OOMClass.class);
    enhancer.setUseCache(false);
    enhancer.create();
}
// 启动加 -XX:MaxMetaspaceSize=64m
// 异常：java.lang.OutOfMemoryError: Metaspace
```

典型场景：**热部署/动态代理类爆炸**（每次部署生成新类加载器 + 新类，旧类未被卸载）。

## 七、直接内存（Direct Memory）

- **位置**：堆外，受**本机总内存**限制（`-XX:MaxDirectMemorySize` 默认等于堆最大值）；
- **用途**：NIO 的 `DirectByteBuffer`、Netty 的堆外内存池、`mmap`；
- **优势**：**零拷贝**——省去堆内 ↔ 系统内存的复制，I/O 性能高（`FileChannel.map`、`sendfile`）；
- **风险**：不受 GC 管理（只靠 `Cleaner` 虚引用回收），**内存泄漏排查难**。

```java
ByteBuffer buffer = ByteBuffer.allocateDirect(1024 * 1024);  // 堆外 1MB
// OOM: java.lang.OutOfMemoryError: Direct buffer memory
```

## 八、内存分配与回收的一句话总结

| 问题 | 答案 |
|---|---|
| 新对象去哪？ | Eden（大对象直接进老年代，`-XX:PretenureSizeThreshold`） |
| 谁负责线程私有分配？ | **TLAB**（Thread Local Allocation Buffer），每个线程在 Eden 划一块，避免竞争 |
| 什么情况进老年代？ | 年龄达标 / 大对象 / Survivor 放不下（动态年龄判断） |
| 谁清理内存？ | Minor GC（新生代复制算法）、Major/Full GC（老年代标记整理/混合回收）、ZGC/G1 并发回收 |
| 谁不参与 GC？ | 程序计数器、虚拟机栈、本地方法栈（栈帧出栈即释放） |

## 九、高频面试追问

**Q1：String 的常量池在哪个区域？**
JDK 7+ 字符串常量池在**堆**（`intern()` 的字符串是堆对象）；JDK 6 及以前在永久代。类相关的运行时常量池在方法区/元空间。

**Q2：堆和栈的区别？**
堆存对象（线程共享、GC 管理、内存大）；栈存局部变量和调用帧（线程私有、自动释放、内存小）。`new` 出来的对象引用在栈，对象本体在堆。

**Q3：方法区会 GC 吗？**
会，但条件苛刻：类的所有实例被回收、类加载器可回收、无反射引用。**热部署依赖方法区 GC（类卸载）**，元空间时代更高效。

**Q4：为什么 PC 寄存器不 OOM？**
规范规定它不需要内存容量限制，只是记录行号，不存在容量问题。

**Q5：`-Xss` 调小有什么影响？**
单线程栈容量变小 → 递归深度下降；但**总内存固定时能创建更多线程**（栈内存 = 线程数 × Xss）。

**Q6：怎么确认一个 OOM 是堆的还是元空间的？**
看异常信息：`Java heap space` → 堆；`Metaspace` → 方法区；`Direct buffer memory` → 直接内存；`unable to create native thread` → 栈/OS 线程资源耗尽。

**Q7：对象一定在堆上分配吗？**
不一定。**逃逸分析**后，未逃逸对象可能**栈上分配**（方法结束自动销毁，无 GC 压力）；标量替换后甚至不创建对象，直接用局部变量。

## 十、总结

- **线程私有三件套**：程序计数器（行号）、虚拟机栈（栈帧）、本地方法栈（native）——随线程生灭，不 GC；
- **线程共享两件套**：堆（对象）、方法区/元空间（类信息）——GC 主战场；
- **堆外补充**：直接内存，零拷贝利器但需警惕泄漏；
- **OOM 四连**：heap space（堆）、Metaspace（元空间）、Direct buffer memory（直接内存）、StackOverflow（栈深度）；
- **记住一个图**：栈管运行、堆管存储、方法区管类型、PC 管位置——面试画出来，分数就到手了。

运行时数据区是整个 JVM 知识的"地图"，后面学 GC、类加载、调优都要在这张地图上展开。把这张图刻进脑子，JVM 系列就成功了一半。
