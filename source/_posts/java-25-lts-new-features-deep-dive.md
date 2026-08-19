---
title: 【Java 25】Java 25 LTS 新特性深度解析：从 Scoped Values 转正到紧凑对象头与分代 Shenandoah
date: 2026-08-19 08:00:00
tags:
  - Java
  - JVM
  - 新特性
  - LTS
categories:
  - Java
  - Java 进阶
author: 东哥
---

# 【Java 25】Java 25 LTS 新特性深度解析：从 Scoped Values 转正到紧凑对象头与分代 Shenandoah

## 引言：Java 25 到底有多重要？

2025 年 9 月 16 日，JDK 25 正式 GA（General Availability）。这是继 JDK 21 之后的新一个 **LTS（长期支持）版本**，意味着它将获得至少 8 年的企业级支持，是下一个大规模生产落地的版本。

Java 25 一共集成了 **22 个 JEP**，其中不乏重量级变更：

- **JEP 506：Scoped Values 正式转正** —— 虚拟线程时代的 ThreadLocal 替代方案终于 Final
- **JEP 519：紧凑对象头（Compact Object Headers）** —— 每个对象平均省 8~16 字节，堆内存占用显著下降
- **JEP 521：分代 Shenandoah** —— 新一代低延迟垃圾收集器分代化
- **JEP 503：移除 32 位 x86 移植** —— 彻底告别 32 位时代
- **JEP 512：紧凑源文件与简化主方法转正** —— Java 从此可以像脚本一样跑

这篇文章会逐一拆解这些 JEP 的原理、用法与生产意义，并附上迁移建议和面试追问。

---

## 一、JEP 506：Scoped Values 正式转正（Final）

### 1.1 从 ThreadLocal 的痛点说起

ThreadLocal 的问题在之前的文章里反复讲过：

- **不可变性缺失**：任何代码都可以 `set()`，值可能被下游框架悄悄改写
- **内存泄漏风险**：线程池场景下，Entry 的 key 是弱引用，value 是强引用，不 remove 就可能泄漏
- **线程继承成本高**：`InheritableThreadLocal` 在创建子线程时深拷贝一份 map，虚拟线程动辄百万级，拷贝开销不可接受
- **与虚拟线程的"失配"**：虚拟线程挂载到平台线程时，ThreadLocal 语义混乱

**Scoped Values 就是冲着这些问题来的**，它把"线程局部变量"重新定义为"作用域内的不可变数据流"。

### 1.2 基本用法

```java
// 1. 声明一个 ScopedValue（类似 ThreadLocal 的静态变量）
private static final ScopedValue<String> REQUEST_ID = ScopedValue.newInstance();

// 2. 在作用域内绑定值
public void handle(HttpRequest request) {
    ScopedValue.where(REQUEST_ID, request.id())
               .run(() -> process(request));
}

// 3. 在作用域内的任意深度读取
public void process(HttpRequest request) {
    // 任意下游方法都可以读到，且无法修改
    String rid = REQUEST_ID.get();
    log.info("处理请求: {}", rid);
}
```

关键语义：

- `where(...).run(...)` 绑定只在**该 Runnable 执行期间**有效，退出作用域自动恢复
- `get()` 在未绑定作用域内调用会抛 `NoSuchElementException`
- 绑定关系**不可变**，子任务天然继承（无论线程池、虚拟线程还是结构化并发），无需拷贝
- 比 ThreadLocal 快得多：作用域进出是纯粹的栈操作，无哈希查找、无扩容

### 1.3 与 ThreadLocal 的对比表格

| 维度 | ThreadLocal | Scoped Values |
|---|---|---|
| 可变性 | 可变，任何代码可 set | 不可变，只读 |
| 生命周期 | 线程存活期间 | 作用域内 |
| 线程池/虚拟线程 | 需手动清理，有泄漏风险 | 天然安全，自动恢复 |
| 继承机制 | InheritableThreadLocal 深拷贝 | 子任务自动可见，零拷贝 |
| 性能 | Map 查找 + 可能扩容 | 栈帧操作，更快 |
| 状态 | JDK 1.2 起 | JDK 25 正式版 |

### 1.4 典型场景

- 请求链路透传：traceId、userId、租户 ID
- 安全上下文：认证信息只读传递
- 结构化并发（StructuredTaskScope）中的子任务参数传递

> **注意**：Scoped Values **不是** ThreadLocal 的完全替代品。如果你确实需要"每个线程一个可变状态"，ThreadLocal 依然是对的；Scoped Values 面向的是"一次绑定、只读传递"的数据流场景。

---

## 二、JEP 519：紧凑对象头（Compact Object Headers）

### 2.1 对象头到底有多"胖"？

在 64 位 JVM 上，一个普通 Java 对象（无锁状态）的对象头通常由两部分组成：

- **Mark Word**：64 bit，存哈希码、GC 年龄、锁状态等
- **Klass Pointer**：64 bit（默认开启压缩指针时为 32 bit）

合起来 **96 bit（12 字节）**；如果关掉压缩指针，就是 **128 bit（16 字节）**。

对于海量小对象（如 `Integer`、Map.Entry、大量 POJO），对象头占比极其惊人——一个只装一个 int 的 `Integer` 对象，数据只有 4 字节，对象头 12 字节，**头身比 3:1**。

### 2.2 紧凑对象头做了什么

JEP 519 的核心思路：**去掉 Mark Word 中 64 位里用不到的部分，把对象头压到 64 bit（8 字节）**，同时把一些信息挪到别处：

- 哈希码（identityHashCode）改为**延迟计算并缓存到别处**（首次调用才生成，且不再缓存于对象头）
- 锁状态相关位重新设计布局
- 配合 JEP 503 移除 32 位移植，64 位下可以默认开启

JDK 24 以 JEP 450 实验性引入（`-XX:+UnlockExperimentalVMOptions -XX:+UseCompactObjectHeaders`），**JDK 25 中默认启用**，无需任何参数。

### 2.3 效果与代价

**收益**：

- 对象头从 12~16 字节降到 8 字节
- 大规模对象图的内存占用平均下降 **10%~20%**（官方基准中部分场景达 20%+）
- 同等堆内存能容纳更多对象，GC 压力也随之降低

**代价**：

- `System.identityHashCode()` 的首次调用会有额外开销（生成并旁路缓存）
- 某些依赖对象头内部布局的底层库（如 Unsafe 操作、部分序列化框架）需要适配
- 偏向锁本身早已废弃（JDK 15），新布局不再有任何兼容负担

### 2.4 生产建议

- 堆内存紧张、对象密度高的服务（缓存、网关、大数据处理），升级 JDK 25 后通常**白嫖**一波内存红利
- 用 `-XX:+PrintFlagsFinal | grep CompactObjectHeaders` 确认当前状态
- 如遇兼容问题可回退：`-XX:-UseCompactObjectHeaders`

---

## 三、JEP 521：分代 Shenandoah（Generational Shenandoah）

### 3.1 Shenandoah 的背景

Shenandoah 是 Red Hat 贡献的低延迟垃圾收集器，核心卖点是**并发 evacuation（搬移）**，让 GC 停顿与堆大小无关，目标是把停顿压到 10ms 以下。但它有个老毛病：**不做分代**，导致全堆每次都要并发标记和搬移，吞吐量吃亏。

### 3.2 分代化解决了什么

JEP 521 借鉴了 ZGC 分代化的成功经验（JDK 21 的 JEP 439）：

- **新生代**：对象创建密集，用**复制算法**快速回收，大部分对象活不到老年代
- **老年代**：存活对象少而稳定，搬移频率低
- 通过**卡表（Card Table）+ 记忆集**记录跨代引用，避免全堆扫描

结果：**停顿时间依然低延迟，但吞吐量大幅提升**，特别适合"分配速率高、存活率低"的典型服务端负载。

### 3.3 使用方式与参数

```bash
# JDK 25 中分代 Shenandoah 为默认模式
java -XX:+UseShenandoahGC -jar app.jar

# 显式指定分代模式
java -XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational -jar app.jar

# 非分代（遗留模式，不推荐新项目使用）
java -XX:+UseShenandoahGC -XX:ShenandoahGCMode=non-generational -jar app.jar
```

### 3.4 与 G1 / ZGC 的定位对比

| GC | 停顿目标 | 吞吐 | 适用场景 |
|---|---|---|---|
| G1 | 可配置（默认 200ms） | 高 | 大多数服务端，默认选择 |
| ZGC（分代） | 亚毫秒~毫秒级 | 中高 | 超大堆（几十 GB~TB）、极致低延迟 |
| Shenandoah（分代） | 毫秒级 | 中高 | 中大型堆、低延迟 + 吞吐兼顾 |

**选型建议**：没有银弹。延迟敏感型选 ZGC 或 Shenandoah，吞吐优先且堆不大选 G1。JDK 25 上 Shenandoah 的性价比明显提升，值得重新做一轮压测对比。

---

## 四、JEP 512：紧凑源文件与简化主方法转正

这个 JEP 让 Java 真正有了"脚本感"。JDK 21 起多次预览，JDK 25 正式落地：

```java
// Hello.java —— 无需 class 声明、无需 public static void main
void main() {
    System.out.println("Hello, Java 25!");
}
```

直接运行：

```bash
java Hello.java
```

要点：

- **无类声明**：编译器自动推导类名
- **无修饰符 main**：`void main()` 即可，同时兼容传统 `public static void main(String[])`
- **launch 单文件源码**：`java Hello.java` 直接解释执行，无需先 `javac`

这对**教学、脚本化运维工具、算法刷题**是巨大福音，也让 Java 在"小而快的工具"领域有了和 Python 掰手腕的底气。

---

## 五、JEP 511：模块导入声明 + JEP 513：灵活构造器体

### 5.1 模块导入声明

```java
// 一次性导入整个模块的公开类型
import module java.base;

import module java.sql;

public class Demo {
    public static void main(String[] args) {
        // 无需逐个 import，直接使用
        var list = java.util.List.of(1, 2, 3);
    }
}
```

适合快速原型和脚本场景；IDE 中大型项目仍建议显式 import，保持代码可读性。

### 5.2 灵活构造器体

以前 Java 强制要求：构造器第一条语句必须是 `super(...)` 或 `this(...)`。这导致一个经典痛点——**想在调用 super 之前校验参数、准备数据，做不到**，只能写静态工厂方法绕。

JEP 513 允许在 `super()` 之前写语句（不能读取正在构造的实例字段）：

```java
public class Child extends Parent {
    Child(int age) {
        if (age < 0) throw new IllegalArgumentException("age 非法");
        super(age);
        // 后续初始化...
    }
}
```

注意限制：

- 前置语句**不能访问 this 的实例字段/方法**（此时对象还没初始化完）
- 但可以访问参数、静态成员，也可以做参数校验和预处理

这让构造器表达力更强，也消除了大量"静态工厂方法"的样板代码。

---

## 六、JEP 510：密钥派生函数 API（KDF）

密码学领域的新成员。`javax.crypto.KDF` 提供了统一的**密钥派生函数**接口：

```java
KDF kdf = KDF.getInstance("HKDF-SHA256");
KDFParameterSpec spec = new HKDFParameterSpec(inputKey, salt, info, 32);
SecretKey key = kdf.deriveKey("AES", spec);
```

内置支持 HKDF、X9.63、Concat KDF 等，统一了各家算法混乱的 API，为 TLS 1.3、签名等场景提供标准实现。

---

## 七、JEP 503：移除 32 位 x86 移植 & 其他值得关注的 JEP

### 7.1 移除 32 位 x86

JDK 24 标记弃用（JEP 501），JDK 25 正式**移除**。32 位 x86 的 Linux/Windows 用户将无法运行 JDK 25+。影响面已经很小——云原生时代几乎全是 64 位，但这意味着**老旧的 32 位服务器部署需要提前规划升级**。

### 7.2 其他亮点速览

| JEP | 内容 | 状态 |
|---|---|---|
| JEP 507 | 原始类型在模式匹配（int 等直接 switch 匹配） | 第三预览 |
| JEP 508 | Vector API（SIMD 向量计算） | 第十孵化 |
| JEP 502 | Stable Values（可缓存的 Scoped Values） | 预览 |
| JEP 505 | 结构化并发 | 第五预览 |
| JEP 514/515 | AOT 命令行参数增强 + 预热方法剖析 | 正式 |
| JEP 518/520 | JFR 协作采样、方法计时与追踪 | 正式/实验 |
| JEP 470 | PEM 编码密码学对象 | 预览 |

可以看到：**Structured Concurrency 和 Primitive Patterns 还在预览**，预计 JDK 26（2026 年 9 月）转正，届时将是又一个值得关注的大版本。

---

## 八、迁移到 JDK 25 的实战建议

1. **先跑兼容性测试**：重点排查反射、Unsafe、序列化、字节码增强（CGLIB/ASM）类库
2. **关注对象头变化**：`-XX:-UseCompactObjectHeaders` 是回退开关；压测对比堆占用
3. **GC 重新选型**：分代 Shenandoah 值得重新压测；老项目 G1 参数（如 `-XX:MaxGCPauseMillis`）在新版本同样适用
4. **替换 ThreadLocal 传递场景**：新代码优先 Scoped Values；存量代码渐进迁移
5. **升级构建工具链**：确保 Maven/Gradle 插件、Lombok、MapStruct 等注解处理器支持 JDK 25

---

## 面试官常见追问

**Q：Scoped Values 和 ThreadLocal 本质区别是什么？**
A：ThreadLocal 是"线程"维度的可变存储，任何代码都能改，线程池下要手动清理；Scoped Values 是"作用域"维度的不可变绑定，绑定值只读、自动恢复、子任务零拷贝继承，且和虚拟线程/结构化并发天然契合。

**Q：紧凑对象头为什么能省内存？会不会影响 hashCode？**
A：把 64 位 Mark Word 中冗余的锁信息压缩到更小布局，整体对象头从 12~16 字节降到 8 字节。identityHashCode 改为延迟生成并旁路缓存，首次调用有少量额外开销，但绝大多数对象从未被调用过 hashCode，总体收益远大于代价。

**Q：分代 Shenandoah 相比 ZGC 怎么选？**
A：两者都是低延迟路线。ZGC 分代化更早、超大堆场景验证更充分；Shenandoah 分代化后吞吐更优、实现更简洁。建议以真实业务负载 + 堆大小做压测对比，通常：堆超大（>64G）偏 ZGC，中大型堆且要求低延迟偏 Shenandoah。

**Q：JDK 25 为什么移除 32 位 x86？**
A：32 位平台使用率极低，维护成本高；且紧凑对象头、更大的堆地址空间等现代特性都依赖 64 位。移除后 JVM 可以精简代码路径，也让对象头压缩等优化可以默认开启。

---

## 总结

Java 25 是一个"稳中带狠"的 LTS：**Scoped Values 转正**解决并发数据传递痛点，**紧凑对象头**白送内存红利，**分代 Shenandoah** 让低延迟 GC 更实用，**脚本式启动**降低 Java 上手门槛。对于 2026 年的新项目，JDK 25 已经是最值得选择的基线版本；存量项目也建议尽快纳入升级评估，尤其是内存敏感型服务，收益非常直接。
