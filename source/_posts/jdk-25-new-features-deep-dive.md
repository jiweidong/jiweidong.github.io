---
title: 【前沿】JDK 25 LTS 新特性深度解析：紧凑对象头、分代 Shenandoah、作用域值转正与升级实战
date: 2026-10-03 08:00:03
tags:
  - Java
  - JDK 25
  - 新特性
  - LTS
categories:
  - Java
  - 前沿技术
author: 东哥
---

# 【前沿】JDK 25 LTS 新特性深度解析：紧凑对象头、分代 Shenandoah、作用域值转正与升级实战

## 面试官：JDK 21 之后，下一个该跳的 LTS 是哪个？

如果还停留在 JDK 8 / 11 / 17 的"三年一跳"节奏，那你可能已经错过了近两年 Java 平台最快的一轮演进。

**JDK 25 已于 2025 年 9 月发布，是继 JDK 8、11、17、21 之后的下一个 LTS**，官方支持周期长达 8 年以上。它把过去几个版本中大量 Preview / Incubator 特性正式转正，还带来了两个**实打实的性能改进**。

这篇文章把 JDK 25 的核心 JEP 逐个拆解，并给出升级建议。

---

## 一、JDK 25 一览表

JDK 25 的正式特性（Final）与预览特性（Preview）汇总：

| JEP | 名称 | 状态 | 看点 |
| --- | --- | --- | --- |
| 519 | Compact Object Headers | **正式** | 对象头 12→8 字节，内存直降 |
| 521 | Generational Shenandoah | **正式** | 低延迟 GC 终于分代 |
| 506 | Scoped Values | **正式** | 虚拟线程时代的 ThreadLocal 替代 |
| 511 | Module Import Declarations | **正式** | `import module` 一句话导模块 |
| 512 | Compact Source Files & Instance Main Methods | **正式** | 单文件程序不用写 class |
| 513 | Flexible Constructor Bodies | **正式** | `super()` 之前可以写代码 |
| 510 | Key Derivation Function API | **正式** | 标准 HKDF，密码学补齐 |
| 514 | AOT Command-Line Ergonomics | **正式** | AOT 缓存更易用 |
| 515 | AOT Method Profiling | **正式** | AOT + 方法画像，启动更快 |
| 518 | JFR Cooperative Sampling | **正式** | 采样停顿更小 |
| 520 | JFR Method Timing & Tracing | **正式** | 方法级耗时追踪 |
| 509 | JFR CPU-Time Profiling | 实验 | 按 CPU 时间采样 |
| 507 | Primitive Types in Patterns / instanceof / switch | 预览 | 原始类型模式匹配 |
| — | Structured Concurrency | 预览多轮 | 结构化并发（StructuredTaskScope） |

> 注：预览特性（Preview）需 `--enable-preview`，不建议生产使用。

---

## 二、重头戏一：紧凑对象头（JEP 519）

### 问题：每个对象都在"浪费"内存

64 位 HotSpot 的对象头是 **12 字节**：

```
+---------------------+---------------------+
|  Mark Word (8 字节)  |  Klass Pointer (4B) |  <- 开启压缩指针时
+---------------------+---------------------+
```

其中 Mark Word 存放哈希码、GC 年龄、锁状态；Klass Pointer 指向类元数据。加上字段对齐（8 字节对齐），一个**空对象**在堆上就要占 **16 字节**。

对一个小对象（比如只有 2 个 int 字段的 `Point`），头部占比高达 60% 以上。

### 方案：把对象头压到 8 字节

```
+---------------------+---------------------+
| Mark Word (4 字节)   |  Klass Pointer (4B)  |
+---------------------+---------------------+
```

把 Mark Word 压到 4 字节（通过把类指针与元数据分开存放等设计实现），对象头从 12 → 8 字节，**每个对象省 4 字节**。

### 收益

- **堆占用降低**：官方给出的大致量级是 **10%~20% 的堆缩减**（对象越小、数量越多，收益越明显）。
- **缓存友好**：同样的 L1/L2/L3 缓存能装下更多对象，间接提升吞吐。
- **对 GC 友好**：堆变小意味着 GC 压力变小。

### 开启方式

```bash
java -XX:+UseCompactObjectHeaders -Xmx4g -jar app.jar
```

### 注意事项

- 不是所有场景都自动受益，**需要压测验证**；
- 与某些依赖对象头布局的 JNI/原生库、Unsafe 用法可能不兼容（比如自己扫描对象头的工具）；
- 序列化/反序列化如果依赖对象内存布局（极少见）需回归测试。

**这是 JDK 25 最值得升级的理由之一**：不改一行业务代码，白拿 10%+ 内存收益。

---

## 三、重头戏二：分代 Shenandoah（JEP 521）

Shenandoah 是老牌低延迟 GC（目标停顿 < 10ms），但长期以来**没有分代**，导致：

- 每次 GC 都要扫描整个堆；
- 短命对象与长命对象混在一起，回收效率低；
- 面对大堆时，GC 的 CPU 开销量明显高于 G1/ZGC。

JEP 521 让 Shenandoah 拥有了**年轻代 / 老年代的分代结构**：

```bash
java -XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational -Xmx32g -jar app.jar
```

**收益**：年轻代单独回收，大部分对象在年轻代就被清理，**GC 频率更高但每次更便宜**，整体吞吐和停顿都改善。

至此，主流低延迟 GC 格局变为：

| GC | 分代 | 最大堆 | 停顿 | 特点 |
| --- | --- | --- | --- | --- |
| G1 | 是 | 大 | 数十~数百 ms | 通用默认 |
| ZGC | 是（JDK 21+） | 极大 | < 1ms | 超大堆首选 |
| Shenandoah | **是（25+）** | 大 | < 10ms | 低延迟、并发整理 |

---

## 四、Scoped Values 正式转正（JEP 506）

`ThreadLocal` 在虚拟线程时代的三个致命问题：

1. **一个虚拟线程一个副本**——百万虚拟线程 = 百万副本，内存爆炸；
2. **可变 + 无边界**——`set` 之后忘了 `remove` 就是泄漏；
3. **继承语义混乱**——`InheritableThreadLocal` 与线程池组合基本不可用。

**Scoped Values** 的思路：**不可变 + 作用域绑定 + 自动传播**。

```java
public static final ScopedValue<UserContext> CURRENT_USER = ScopedValue.newInstance();

public void handleRequest(Request req) {
    // 绑定：只在 run() 的作用域内可见，退出自动"解除"
    ScopedValue.where(CURRENT_USER, loadUser(req))
               .run(() -> {
                   orderService.create();      // 内部可直接读
                   logService.audit();
               });
}

public void audit() {
    // 子线程 / 子任务自动继承（结构化并发下）
    UserContext ctx = CURRENT_USER.get();
    System.out.println("audit by " + ctx.userId());
}
```

对比 `ThreadLocal`：

| 维度 | ThreadLocal | ScopedValue |
| --- | --- | --- |
| 可变性 | 可变，可 set/reset | **不可变**，只在 where 内有效 |
| 生命周期 | 手动 remove，易泄漏 | 作用域结束自动失效 |
| 虚拟线程友好 | 每个 VT 一份副本 | 共享、无副本膨胀 |
| 向下传递 | InheritableThreadLocal 有限支持 | 与结构化并发原生配合 |
| 性能 | 有副本与清理成本 | 读开销极低 |

**坑点**：`ScopedValue` 不支持从任意线程读取——只有**在 `where(...).run()` 调用链内**（含其派生线程/结构化并发子任务）才能 `get()`。跨线程池传递需要显式包装。

---

## 五、零样板代码：Compact Source Files（JEP 512）

以前写个 hello world：

```java
public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("Hello, World!");
    }
}
```

JDK 25：

```java
void main() {
    System.out.println("Hello, World!");
}
```

直接 `java Hello.java` 运行，不需要 `public class`、不需要 `static`、不需要 `String[] args`。适合教学、脚本、原型验证。

配合 **JEP 511 Module Import Declarations**：

```java
import module java.base;      // 一行导入整个 java.base 模块导出的包

void main() {
    var list = new ArrayList<String>();   // 不用再 import java.util.ArrayList
    list.add("hi");
    System.out.println(list);
}
```

注意区分：`import module` 导入的是**模块导出的所有包**，不是类；它解决的是"为了用几个类写了一屏 import"的样板问题。

---

## 六、灵活构造器（JEP 513）

以前，`super()` 必须是构造器的第一条语句，导致"参数校验、字段计算"无处安放：

```java
// 老写法：要么重复校验，要么抽静态方法
class PositivePoint extends Point {
    PositivePoint(int x, int y) {
        super(x, y);            // 必须先调用
        if (x < 0 || y < 0) throw new IllegalArgumentException();  // 校验发生在 super 之后
    }
}
```

JDK 25 允许多条语句出现在 `super()` **之前**（只要不引用未初始化的 `this`）：

```java
class PositivePoint extends Point {
    PositivePoint(int x, int y) {
        if (x < 0 || y < 0) {                 // 先校验
            throw new IllegalArgumentException("negative");
        }
        var norm = normalize(x, y);           // 先计算
        super(norm.x, norm.y);                // 再调用父类构造器
    }
}
```

好处：

- 校验前移，"对象不可能进入非法状态"；
- 避免为了复用校验逻辑而写静态辅助方法；
- 与 Records、密封类的紧凑构造器风格统一。

---

## 七、启动提速：AOT 命令链（JEP 514/515）

JDK 24 引入 AOT 类加载/链接，JDK 25 进一步增强：

```bash
# 1. 录制训练运行
java -XX:AOTMode=record -XX:AOTConfiguration=app.aotconf -jar app.jar

# 2. 生成 AOT 缓存（可结合方法画像）
java -XX:AOTMode=create -XX:AOTConfiguration=app.aotconf -XX:AOTCache=app.aot -jar app.jar

# 3. 生产使用
java -XX:AOTCache=app.aot -jar app.jar
```

收益：**启动时间与预热时间显著缩短**，对 Serverless、弹性扩缩容、CLI 工具非常关键。它不像 GraalVM Native Image 那样牺牲 JIT 峰值性能——**AOT 只是把"类加载/链接/部分画像"的活儿提前干完**，运行期依然是完整的 JIT。

---

## 八、密码学：KDF API（JEP 510）

以前做密钥派生要么自己拼 `MessageDigest`（容易出错），要么引 BouncyCastle。JDK 25 提供标准 API：

```java
import javax.crypto.KDF;
import javax.crypto.SecretKey;
import javax.crypto.spec.HKDFParameterSpec;
import javax.crypto.spec.SecretKeySpec;

KDF hkdf = KDF.getInstance("HKDF-SHA256");
SecretKey ikm = new SecretKeySpec(masterKey, "HKDF");

var spec = HKDFParameterSpec.ofExtract()
        .addIKM(ikm)
        .addSalt(salt)
        .thenExpand(info, 32);

SecretKey derived = hkdf.deriveKey("AES", spec);
```

安全合规场景（金融、政企）终于不需要第三方库就能实现 HKDF。

---

## 九、JFR 三连增强（JEP 509/518/520）

JFR（Java Flight Recorder）是线上诊断的第一利器，JDK 25 把它又推进了一步：

- **JEP 518 协作采样（Cooperative Sampling）**：JFR 采样不再需要安全点（safepoint），大幅减少采样带来的停顿与偏差；
- **JEP 520 方法耗时追踪**：可以追踪具体方法的耗时，定位"哪个方法慢"更直接；
- **JEP 509 CPU 时间采样（实验）**：按 CPU 时间而非墙上时间采样，更适合识别真实 CPU 热点。

配合 JDK 21+ 的 `jcmd <pid> JFR.start`，线上排查体验已经非常成熟。

---

## 十、其他值得关注的变化

**预览特性**（需 `--enable-preview`）：

- **原始类型模式匹配（JEP 507）**：`if (obj instanceof int i)`、`switch` 支持原始类型，消除大量装箱；
- **结构化并发（Structured Concurrency）**：`StructuredTaskScope` 继续预览，与 Scoped Values 是虚拟线程体系的两大支柱；
- **Vector API**：SIMD 持续 incubator / preview。

**废弃与移除**：32 位 x86 支持继续收敛；一些老 GC（如 CMS 早已移除）与旧 API 持续清理——升级前务必用 `jdeprscan` 扫一遍。

---

## 十一、升级到底值不值？一份决策清单

**值得升级的理由**：

1. 白拿 **10%~20% 内存收益**（Compact Object Headers）；
2. 虚拟线程体系成熟（Scoped Values + 结构化并发 + 分代 Shenandoah）；
3. AOT 缓存让启动/弹性扩缩容更快；
4. 长达 8 年+ 的 LTS 支持，维护成本低。

**升级前的检查项**：

| 检查项 | 工具/手段 |
| --- | --- |
| 废弃 API | `jdeprscan --release 25 app.jar` |
| 反射/Unsafe 私有 API | 跑一遍单测 + 集成测试 |
| 字节码增强框架 | 升级 ByteBuddy / ASM / CGLIB 到最新版 |
| 序列化兼容 | 回归跨版本数据 |
| 对象头布局依赖 | 谨慎开启 Compact Object Headers，先压测 |
| 三方 native 库 | 确认有对应 JDK 25 构建 |

**升级路径建议**：JDK 8/11 → （经 17）→ 21 → 25。跨版本跨度大时，先升到 21 验证虚拟线程与 GC 行为，再进 25 拿分代 Shenandoah 与紧凑对象头。

---

## 十二、面试常见追问

**Q1：为什么对象头能压到 8 字节？**
64 位下 Mark Word 要存哈希、GC 年龄、锁状态，原本 8 字节；紧凑对象头通过把"类指针"等元数据信息重新组织并利用 32 位空间，把 Mark Word 压到 4 字节 + 4 字节类指针 = 8 字节。它依赖 64 位寻址与类元数据的组织方式，因此需要 JVM 支持。

**Q2：Scoped Values 能替代 ThreadLocal 吗？**
大多数"请求上下文传递"场景可以，且更安全。但如果你需要**跨线程池、跨响应式边界、可变状态**，Scoped Value 不适用（它不可变且只在作用域内可见），仍需 ThreadLocal 或显式参数传递。

**Q3：AOT 缓存和 GraalVM Native Image 有什么区别？**
AOT 缓存只是把类加载/链接/部分方法画像**提前算好存盘**，运行期仍是标准 JVM + JIT，峰值性能不受影响；Native Image 则把整个应用编译成本地可执行文件，启动极快、内存极低，但牺牲运行期动态能力与峰值性能。

**Q4：分代 Shenandoah 相比 G1、ZGC 怎么选？**
大堆 + 低延迟 + 想要并发整理选 Shenandoah；超大堆（TB 级）+ 极致低停顿选 ZGC；追求通用与成熟生态选 G1。JDK 25 后 Shenandoah 终于具备分代能力，竞争力明显提升。

**Q5：紧凑对象头会不会影响锁性能？**
Mark Word 压缩后仍要承载锁状态与哈希码，HotSpot 做了相应权衡。官方数据显示整体是收益，但对**高度竞争锁**的极端场景建议压测对比。

---

## 十三、总结

JDK 25 是一个"**性能白拿 + 语法收敛 + 虚拟线程体系成型**"的 LTS：

- **Compact Object Headers**：内存 ×0.8~0.9，白拿；
- **Generational Shenandoah**：低延迟 GC 补上分代；
- **Scoped Values 转正**：虚拟线程时代告别 ThreadLocal 泄漏；
- **Compact Source Files / Module Import / Flexible Constructors**：样板代码大幅收敛；
- **AOT 缓存 + JFR 增强**：启动更快、诊断更准。

如果你还在 JDK 8/11，**JDK 21 是过渡站，JDK 25 是下一站**。升级不会一夜之间发生，但从今天开始用 `jdeprscan` 扫一遍技术债，是最划算的开始。
