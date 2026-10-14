---
title: 【Java 前沿】Java 22 与 23 新特性深度解析：从构造函数前置语句到原始类型模式匹配
date: 2026-10-14 08:00:00
tags:
  - Java
  - Java 22
  - Java 23
  - 新特性
  - 面试
categories:
  - Java 进阶
author: 东哥
---

# 【Java 前沿】Java 22 与 23 新特性深度解析

## 前言

很多团队的升级路线里存在一个"跳版"现象：从 Java 17 / 21 直接跳到 24 / 25，中间的 **Java 22、Java 23** 被当成"过渡版本"忽略。但这两版并不是空窗期——它们包含了多个对**业务代码写法**和**底层能力**都有实质影响的 JEP：`Statements before super(...)`、`Foreign Function & Memory API` 转正、`Stream Gatherers`、`String Templates`、原始类型模式匹配、模块导入声明等。

面试中如果被问到"Java 最近几个版本都带来了什么"，能讲清楚 22/23 的目标与取舍，比只会背"虚拟线程"要明显高一档。本文按"语法糖 / 底层能力 / 并发与 GC"三条线,把 Java 22 与 23 的关键 JEP 拆开讲，并给出代码与落地判断。

## 一、Java 版本节奏与 22/23 的定位

Java 从 2017 年起采用**六个月一个版本**的节奏，每两年出一个 LTS。注意一个常被误解的点：**每个特性至少要经过 1 次 preview（预览），部分特性要 2~3 次**，所以"22/23 看起来没大东西"往往是因为它们承载了大量 **preview / 二次 preview**。

| 版本 | 类型 | 主要定位 |
|---|---|---|
| 21 | LTS | 虚拟线程转正、分代 ZGC、模式匹配 switch 转正、Sequenced Collections |
| 22 | 非 LTS | FFM API 转正、构造函数前置语句、多文件源码运行、Gatherers 预览 |
| 23 | 非 LTS | 原始类型模式匹配预览、模块导入声明预览、Markdown 文档注释、ZGC 分代默认 |
| 24 | 非 LTS | Class-File API 转正、Stream Gatherers 转正、KEM（后量子） |
| 25 | LTS | Scoped Values 转正、紧凑对象头、分代 Shenandoah |

也就是说：**22/23 是"打地基"的两个版本**，很多在 24/25 转正的特性，其 API 形态正是在这两版里定型的。升级到 24/25 时如果跳过对 22/23 特性的理解，遇到 API 变化会一头雾水。

## 二、Java 22：把"底层能力"补上

### 2.1 JEP 454：Foreign Function & Memory API 转正（FFM）

这是 Java 22 最重要的转正特性。它要解决的是长期被 `JNI` 和 `Unsafe` 把持的两件事：**调用本地函数** 与 **安全地操作堆外内存**。

过去调 native 代码只有两条路：

- `JNI`：要写 C 头文件、编译动态库、跨平台维护成本极高；
- `Unsafe` / `DirectByteBuffer`：能读写堆外内存，但 `Unsafe` 的 `allocateMemory`/`freeMemory` 需要手工配对，野指针会让整个 JVM 崩溃（不是抛异常，是 segfault）。

FFM 用 `Arena` 做**内存生命周期管理**，把"谁负责释放"变成作用域问题：

```java
import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;

public class FfmDemo {
    public static void main(String[] args) throws Throwable {
        // 查找 C 标准库的 strlen
        Linker linker = Linker.nativeLinker();
        SymbolLookup stdlib = linker.defaultLookup();
        MethodHandle strlen = linker.downcallHandle(
                stdlib.find("strlen").orElseThrow(),
                FunctionDescriptor.of(ValueLayout.JAVA_LONG, ValueLayout.ADDRESS));

        // Arena 是一个"作用域"，离开 try 块内存自动释放
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment cString = arena.allocateFrom("Hello FFM");
            long len = (long) strlen.invoke(cString);
            System.out.println("strlen = " + len); // 9
        } // 此处 cString 已被释放，配合 Valhalla 时代的确定性清理
    }
}
```

几个关键点：

1. **`Arena.ofConfined()`**：只在当前线程使用，开销最小；`ofShared()` 可跨线程；`ofAuto()` 交给 GC 回调释放。
2. **`downcallHandle`**：把 C 函数包装成 `MethodHandle`，调用时无 JNI 那套包装开销，JIT 能内联（成为 intrinsic）。
3. **`StructLayout` / `ValueLayout`**：用声明式描述内存布局，取代手算偏移量。

**面试追问：FFM 与 JNI、Unsafe 的关系？**
- FFM 目标是**在大多数场景取代 JNI**，尤其"偶尔调一次 native"的场景，不必再维护 C 编译链；
- FFM 也**部分取代 `Unsafe`**：`MemorySegment` 有边界检查（可选无检查的 `MemorySegment.NULL` 比较），是"安全 + 可控"的折中；
- 但真正的性能极限场景下，`Unsafe`/`VarHandle` 仍有其位置，FFM 不是万能。

### 2.2 JEP 447：`super(...)` 之前的语句

这是一个**纯语法解放**且非常实用的改动。Java 有一条历史铁律：子类构造函数里，**`super()` 调用必须是第一条语句**。这导致"想先校验参数、再调父类构造"时只能把逻辑塞进静态方法，写起来别扭：

```java
// Java 21 及以前：只能靠静态方法绕
class Point {
    Point(int x, int y) { /* ... */ }
}

class PositivePoint extends Point {
    PositivePoint(int x, int y) {
        super(checkPositive(x), checkPositive(y)); // 必须第一条，且只能塞静态方法
    }
    private static int checkPositive(int v) {
        if (v < 0) throw new IllegalArgumentException("negative: " + v);
        return v;
    }
}

// Java 22：可以在 super 前写"不引用 this"的语句
class PositivePointJava22 extends Point {
    PositivePointJava22(int x, int y) {
        if (x < 0 || y < 0) {
            throw new IllegalArgumentException("坐标不能为负: " + x + "," + y);
        }
        super(x, y); // 现在 super 不必是第一条
    }
}
```

关键约束：`super` 之前的语句**不能访问 `this`**（不能读字段、调用实例方法），因为此时对象还没被初始化。这样编译器依然能保证父类构造先于任何实例字段访问。

**生产价值**：减少了大量为了迎合语法而拆出来的静态校验方法，构造逻辑更自然。

### 2.3 JEP 461：Stream Gatherers（预览）

`Stream` 的中间操作以前只有 `map/filter/flatMap/...` 这些官方内置的。**Gatherers** 允许你**自定义中间操作**，等价于"把 `collect` 的能力搬到了中间态"。

经典例子：**固定窗口**（把流每 3 个元素切成一批）：

```java
record Window<T>(List<T> items) {}

List<Window<Integer>> windows = Stream.of(1,2,3,4,5,6,7,8,9)
        .gather(Gatherers.windowFixed(3))
        .map(Window::new)
        .toList();
// [[1,2,3],[4,5,6],[7,8,9]]
```

也可以实现**去重相邻**、**滑动窗口**、**扫描（前缀和）**等：

```java
// 前缀和
List<Long> prefix = Stream.of(1L,2L,3L,4L)
        .gather(Gatherers.scan(() -> 0L, Long::sum))
        .toList();
// [1,3,6,10]
```

这填补了 Java 流式 API 长期的空白——以前这类需求要么退化成 `for` 循环，要么用第三方库（如 Vavr、jOOλ）。24 版已转正。

### 2.4 其他值得记的 22 特性

- **JEP 458**：`java Main.java` 直接运行**多文件**源码程序（以前只能一个文件，跨文件要编译）。
- **JEP 459**：`String Templates` 预览（`STR."Hello \{name}"`）——**注意：该预览特性在后续版本被撤回重设计**，面试时可作为"特性被撤回"的案例。
- **JEP 456**：未命名变量与模式（`_`），配合模式匹配忽略不需要的绑定。

## 三、Java 23：为 LTS 铺路的"预览集中营"

### 3.1 JEP 455：原始类型模式匹配（预览）

这是模式匹配演化的一块**关键拼图**。此前 `instanceof` / `switch` 的模式匹配只支持**引用类型**，基础类型要先装箱：

```java
// 以前：必须装箱
Object v = 42;
if (v instanceof Integer i && i > 0) { ... }

// Java 23 预览：可以在模式匹配里做原始类型窄化
// switch (v) {
//     case int i when i > 0 -> "正整数";
//     case double d        -> "浮点";
//     default              -> "其他";
// }
```

它的目标是让 `switch` 成为**统一的分派结构**：既能匹配引用类型、也能匹配原始类型，还能用 `when` 守卫条件。这也是"模式匹配 + Record 模式 + 原始类型模式"三者合流的前置条件。

### 3.2 JEP 476：模块导入声明（预览）

单类导入要写 `import com.foo.Bar;`，导入**一整个模块导出的所有包**以前没有语法。模块导入声明让：

```java
// import module java.base;   // 预览语法
// 等价于按需导入 java.base 导出的所有 public 类型
```

好处是写"探索性代码"/脚本时不用一长串 import。但要注意**可读性与命名冲突**（不同模块导出同名类），所以作为预览特性仍在打磨。

### 3.3 JEP 474：ZGC 默认改为分代模式

ZGC 早期是**非分代**的（不分年轻代/老年代，全堆一起标记）。Java 21 引入分代 ZGC（JEP 439），到 **Java 23 直接把默认模式切成分代 ZGC**。分代 ZGC 通过"年轻代回收更频繁、更聚焦"大幅降低了分配速率高场景下的开销。

```bash
# 显式用分代 ZGC（23+ 其实已是默认）
java -XX:+UseZGC -XX:+ZGenerational ...   # 21-22 需要这个参数
# 23+ 想退回非分代：
java -XX:+UseZGC -XX:-ZGenerational ...
```

**面试点**：分代 ZGC 的核心直觉是"大部分对象朝生夕死"，把回收集中在年轻代，能显著减少每次 GC 的标记扫描量；代价是额外的记忆集/跨代引用维护（与 G1 的记忆集思路类似）。

### 3.4 JEP 467：Markdown 文档注释

这是一个**工程体验**层面的改进：Javadoc 现在支持用 **Markdown** 写，而不是只能写 HTML：

```java
/// 计算两数之和。
///
/// 使用示例：
/// ```java
/// int r = MathUtil.add(1, 2); // 3
/// ```
/// - 支持**加粗**
/// - 支持 `行内代码`
///
/// @param a 第一个加数
/// @param b 第二个加数
public static int add(int a, int b) { return a + b; }
```

用 `///` 而不是 `/** */`。好处：写文档不再需要 `{@code}`、`<p>` 这些噪音，团队文档可维护性提升。

### 3.5 其他 23 关键 JEP

| JEP | 内容 | 状态 |
|---|---|---|
| 471 | 弃用 `sun.misc.Unsafe` 的内存访问方法 | 弃用（为 FFM 让路） |
| 469 | Vector API（第 8 轮孵化） | 孵化 |
| 480 | Structured Concurrency（第 3 次预览） | 预览 |
| 481 | Scoped Values（第 3 次预览） | 预览（25 转正） |
| 482 | 灵活构造函数体（第 2 次预览） | 预览 |
| 473 | Stream Gatherers（第 2 次预览） | 预览 |

注意 **480 / 481 / 482**：结构化并发、作用域值、灵活构造体这三个"虚拟线程配套"特性，在 23/24 反复预览，直到 25 才转正。这解释了为什么"虚拟线程好是好，但生产配套能力要等 LTS"。

## 四、落地建议：到底要不要升到 22/23？

先给结论：**业务系统不要停在 22/23，要么用 21 LTS，要么等/用 25 LTS。** 22/23 的价值在于"理解演进"与"验证新特性"。

| 场景 | 建议 |
|---|---|
| 生产业务系统 | 选 LTS：21 或 25。22/23 非 LTS，只有 6 个月支持 |
| 想用 FFM / Gatherers 等 | 22 已有 FFM 转正；Gatherers 建议用 24+ 转正版 |
| 想评估虚拟线程配套 | 关注 25 LTS（Scoped Values 转正） |
| 想提前验证特性 | 用 22/23 做 PoC，但代码里标注 preview 需要 `--enable-preview` |

**踩坑提示**：

1. **`--enable-preview` 有强绑定**：预览特性编译出的 class 文件带有版本标记，只能在**同一个 JDK 版本**下运行。哪怕同为 23，`23.0.1` 与 `23.0.2` 之间的 preview 也要求版本严格匹配，否则 `UnsupportedClassVersionError`。
2. **预览 API 会变**：`String Templates` 就是活生生的反面教材（22 预览、23 二次预览，后被撤回）。所以**绝不要把预览特性写进生产代码**。
3. **升级要看 GC 默认值变化**：23 起 ZGC 默认分代，如果原来显式依赖了非分代 ZGC 的行为，升级后停顿特性会变，需要重新压测。

## 五、面试高频追问

**Q1：`super(...)` 之前能写语句，那能不能读 `this` 的字段？**
不能。语法规则明确禁止在 `super()` 之前访问 `this`（包括字段、实例方法、`this` 引用本身），因为父类尚未初始化，此时读子类字段在语义上是"未定义状态"。编译器会报错。

**Q2：FFM 的 `Arena` 和 GC 有什么关系？同一个 `MemorySegment` 跨线程能访问吗？**
`Arena.ofConfined()` 绑定的内存只有创建线程能访问，跨线程访问会抛 `IllegalStateException`；`ofShared()` 支持多线程但同步开销更大；`ofAuto()` 由 GC 的 Cleaner 机制在不可达时释放。关键：FFM 内存是**堆外**的，GC 不会移动它，所以地址稳定，适合传给 native 函数。

**Q3：为什么 `Stream Gatherers` 被称为"缺失的中间操作"？**
因为 `Stream` 的中间操作必须是"1:N 有状态/无状态转换"，而官方只提供了有限几个。Gatherers 用 `Gatherer<T,A,R>`（初始化器 + 集成器 + 收集器 + 完成器）让开发者自定义，语义上介于 `map` 和 `collect` 之间，填补了"有状态中间流"的能力空缺。

**Q4：Java 22 弃用 `Unsafe` 内存方法，那 Netty、Kafka 客户端的零拷贝怎么办？**
它们正在迁移到 FFM 或 `VarHandle`。`VarHandle` 在 JDK 9 就提供了大部分原子/内存序操作，而堆外读写由 FFM `MemorySegment` 承接。真实世界的迁移是渐进的，短期内 `Unsafe` 仍能通过 `--add-exports` 使用，但会在未来版本移除。

## 六、小结

- **Java 22** 是"底层能力补齐"版：FFM 转正（取代 JNI/Unsafe 的方向）、构造函数前置语句、Gatherers 预览。
- **Java 23** 是"LTS 铺路"版：原始类型模式匹配、模块导入声明、Markdown 文档注释、ZGC 默认分代。
- 两者都属于**非 LTS**，生产应停在 21/25；但理解它们，才能读懂 24/25 的转正清单与 API 定型过程。
- 面试落点：能讲清"每个特性解决了什么历史痛点、现在的约束是什么、生产该不该用"，比罗列 JEP 编号有价值得多。

下一阶段建议结合 **Java 24 的 Class-File API / Stream Gatherers 转正** 与 **Java 25 的 Scoped Values / 紧凑对象头**一起看，形成一条完整的"21→25 演进"叙述线。
