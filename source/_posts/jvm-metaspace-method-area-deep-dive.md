---
title: 【JVM 底层】方法区与元空间深度解析：从 PermGen 到 Metaspace 的演进与内存调优
date: 2026-08-12 08:00:00
tags:
  - Java
  - JVM
  - 内存
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 底层】方法区与元空间深度解析：从 PermGen 到 Metaspace 的演进与内存调优

## 面试官：JDK 8 为什么要用 Metaspace 替换 PermGen？两者到底有什么区别？

**候选人**：因为 PermGen 会 OOM，Metaspace 用的是本地内存……

面试官：**"那 Metaspace 会 OOM 吗？什么情况下会？"**

这个问题背后是 JVM 内存区域中最"抽象"的一块——**方法区**。它存什么、什么时候分配、什么时候回收、为什么从堆搬到本地内存，今天一次讲透。

---

## 一、方法区（Method Area）：规范与实现

### 1.1 规范层面

JVM 规范定义：方法区是**所有线程共享**的内存区域，存储：

- 类的**结构信息**（字段、方法、接口、常量池等）
- **运行时常量池**（Runtime Constant Pool，Class 文件常量池的运行态版本）
- 类变量（static 字段，JDK 7 后随对象移到堆）
- 方法字节码、JIT 编译后的机器码等

**注意**：方法区是 JVM 规范里的**逻辑概念**，不是具体实现。

### 1.2 实现层面（重点）

| 版本 | 实现 | 位置 | 默认上限 |
|------|------|------|---------|
| JDK 7 及之前 | PermGen（永久代） | 堆外但受堆大小约束（逻辑上属堆） | `-XX:MaxPermSize`，默认约 64~256M |
| JDK 8 及之后 | Metaspace（元空间） | **本地内存（Native Memory）** | 默认**无上限**（受物理内存约束） |
| JDK 17+ | Metaspace（继续演进） | 本地内存 | 同上，且支持压缩类空间 |

**关键演进时间线：**

- JDK 7：字符串常量池、静态变量从 PermGen **移到堆**。
- JDK 8：整个 PermGen 移除，方法区由 **Metaspace** 实现，占用本地内存。
- JDK 9+：字符串常量池改为紧凑字符串（Compact Strings），类元数据继续优化。

## 二、PermGen 为什么被淘汰

### 2.1 核心痛点

1. **大小难以预估**：类元数据多少取决于加载的类数量、动态代理、反射、热部署等，很难提前定 `MaxPermSize`。设小了频繁 `java.lang.OutOfMemoryError: PermGen space`，设大了浪费内存。
2. **GC 效率问题**：PermGen 在堆内，Full GC 时要扫描它；且老年代 GC 算法对"类卸载"这种低频操作支持不佳。
3. **字符串常量池 OOM**：JDK 7 前，字符串常量在 PermGen，intern 大量字符串很容易撑爆永久代。

### 2.2 经典的 PermGen OOM 场景（面试要会讲）

```java
// 动态生成大量类（如 CGLIB 代理、反射、JSP 热编译）
for (int i = 0; i < 100000; i++) {
    Enhancer enhancer = new Enhancer();
    enhancer.setSuperclass(TestBean.class);
    enhancer.setCallback(NoOp.INSTANCE);
    enhancer.create(); // 每次生成一个新代理类 → 类元数据暴涨
}
```

JDK 7 下直接报 `PermGen space`；JDK 8 下同样代码则是 **`Metaspace` OOM**（如果设置了上限）或**把物理内存耗尽**（如果不设上限）。

## 三、Metaspace 的内存模型

### 3.1 组成结构

Metaspace 分为两大部分：

| 区域 | 内容 | 大小控制 |
|------|------|---------|
| **Class Space（类空间）** | Klass 结构（类元数据本身） | `-XX:CompressedClassSpaceSize`（默认 1G） |
| **Non-Class Space** | 方法字节码、常量池、注解等 | 受 `-XX:MaxMetaspaceSize` 控制 |

**注意**：仅当开启**压缩类指针**（`-XX:+UseCompressedClassPointers`，64 位默认开启）时才有 Class Space。它是一段**连续**的本地内存，地址与堆相关（位于堆后面），这也是为什么它能用 32 位压缩指针。

### 3.2 内存分配与增长

Metaspace 按**Chunk（块）**分配：

```
Metaspace
  ├── Class Space（1G 默认，连续）
  └── Non-Class Space
        ├── Chunk 1（分配给类加载器 A）
        ├── Chunk 2（分配给类加载器 B）
        └── ...
```

- 每个**类加载器**持有一组 Chunk，类元数据在 Chunk 内分配。
- Chunk 用完会向 Metaspace 虚拟内存分配器申请新的。
- **虚拟空间（Virtual Space）**按需映射本地内存，不会一次性占满。

### 3.3 为什么默认无上限

Metaspace 默认 `MaxMetaspaceSize` 为无限（仅受 64 位地址空间和物理内存限制）。JVM 设计者认为：类元数据不像堆对象那样无限增长，合理情况下有自然上限，不该预先设死。

**但这带来一个真实风险：类加载器泄漏时，Metaspace 会无限增长，直到把整台机器的内存吃光（OOM Killer 干掉进程）。** 所以生产环境**必须设置上限**。

## 四、Metaspace 的回收：类卸载机制

### 4.1 类卸载的三个条件（面试必背）

一个类要被卸载，必须同时满足：

1. 该类的所有**实例**都已被回收（堆中无存活对象）。
2. 该类的 **ClassLoader** 已被回收（没有引用指向它）。
3. 该类对应的 `java.lang.Class` 对象**没有任何地方引用**（反射、静态字段都不持有）。

**重要推论：**

- **系统类加载器（AppClassLoader）加载的类永远不会被卸载**（条件 2 不满足），所以应用启动加载的类常驻 Metaspace。
- **只有自定义类加载器**（Tomcat 的 WebAppClassLoader、OSGi、热部署框架）才有类卸载的可能。
- 类卸载发生在 **Full GC / Concurrent GC** 阶段（G1 是并发标记后）。

### 4.2 热部署为什么会 Metaspace 泄漏

```java
// 每次热部署创建一个新类加载器
URLClassLoader loader = new URLClassLoader(urls);
Class<?> clazz = loader.loadClass("com.example.Controller");
// ... 如果旧 loader 还被引用着（比如存进了静态 Map）
```

**常见泄漏根因：**

- 旧 ClassLoader 被静态变量/ThreadLocal 持有 → 无法回收 → 它加载的所有类永不卸载 → Metaspace 只增不减。
- Tomcat 反复 reload 应用但 WebappClassLoader 引用未清理。
- 解决：用 `jmap -clstats <pid>` 查看每个类加载器加载的类数量，定位泄漏的 loader。

## 五、调优参数与监控

### 5.1 参数总表

| 参数 | 作用 | 建议 |
|------|------|------|
| `-XX:MaxMetaspaceSize` | Metaspace 上限 | **生产必设**，如 512m~1g |
| `-XX:MetaspaceSize` | 初始触发 GC 的阈值（不是初始大小） | 默认约 21M，触发 Full GC |
| `-XX:MinMetaspaceFreeRatio` | GC 后 Metaspace 空闲比例下限 | 默认 40 |
| `-XX:MaxMetaspaceFreeRatio` | GC 后空闲比例上限 | 默认 70 |
| `-XX:CompressedClassSpaceSize` | 压缩类空间大小 | 默认 1G，类多可调大 |
| `-XX:+UseCompressedClassPointers` | 开启压缩类指针 | 64 位默认开启 |

**注意坑**：`MetaspaceSize` 不是"初始分配大小"，而是"**首次触发 Metaspace GC 的阈值**"。设置过小会导致**频繁 Full GC**。

### 5.2 监控命令

```bash
# 查看 Metaspace 使用情况（JDK 8+）
jstat -gcutil <pid> 1000
# 输出中 M / CCS 列：
#   M    = Metaspace 使用率
#   CCS  = 压缩类空间使用率

# 查看类加载/卸载统计
jstat -class <pid>

# 查看每个类加载器详情（JDK 8+）
jmap -clstats <pid>

# 结合 GC 日志
java -Xlog:gc+metaspace=info -jar app.jar
```

### 5.3 日志解读

```
[gc,metaspace] GC(4) Metaspace: 49152K(51200K) -> 48128K(49152K)
```

- `49152K(51200K)`：使用 48M / 上限 50M。
- 若每次 GC 后 Metaspace 只增不减 → 大概率**类加载器泄漏**。

## 六、实战案例

**案例：JSP 应用反复编译导致 Metaspace 涨满**

现象：某老项目（JDK 8 + Tomcat）运行几天后 Full GC 频繁，Metaspace 使用率 99%。

排查：

```bash
# 1. 确认是 Metaspace 问题
jstat -gcutil <pid> | awk '{print $1, $8}'
# M 列持续逼近 100%

# 2. 查看类加载器
jmap -clstats <pid> > clstats.txt
# 发现几十个 org.apache.jasper.servlet.JasperLoader 实例
```

根因：JSP 文件每次修改被 Tomcat 重新编译，新的 `JasperLoader` 加载新类，旧 loader 被 Servlet 容器内部的缓存引用，无法卸载。

解决：

1. 关闭 JSP 热编译（生产环境不应修改 JSP）。
2. 排查容器缓存引用，升级 Tomcat 版本。
3. 设置 `MaxMetaspaceSize` 兜底，避免拖垮整机。

## 七、面试追问速查

| 问题 | 答案要点 |
|------|---------|
| 方法区存什么？ | 类结构、运行时常量池、字节码、JIT 机器码（静态变量 JDK7 后移到堆） |
| 为什么移除 PermGen？ | 大小难预估、GC 效率差、字符串常量 OOM |
| Metaspace 会 OOM 吗？ | 会！不设上限吃光物理内存，设上限抛 Metaspace OOM |
| 什么情况下类会被卸载？ | 实例无引用 + ClassLoader 无引用 + Class 对象无引用，三条件同时满足 |
| 为什么系统类加载器加载的类不卸载？ | 条件 2 永不满足，ClassLoader 一直被引用 |
| 怎么定位 Metaspace 泄漏？ | jmap -clstats 看类加载器数量 + GC 日志看 Metaspace 只增不减 |
| Metaspace 参数怎么设？ | MaxMetaspaceSize 必设；MetaspaceSize 是 GC 阈值不是初始大小 |

---

**总结**：方法区是 JVM 内存模型中最"虚"的一块，但线上问题却非常实在——热部署泄漏、动态代理 OOM、Metaspace 吃满内存。理解 PermGen → Metaspace 的演进逻辑，掌握类卸载三条件，再配合 `jmap -clstats` 和 GC 日志定位问题，这块知识就能从"背概念"变成"能实战"。
