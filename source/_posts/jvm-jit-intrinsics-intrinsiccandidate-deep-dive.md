---
title: 【JVM 底层】JIT Intrinsic 内建函数深度解析：为什么 System.arraycopy 比手写循环快 8 倍
date: 2026-11-06 08:00:00
tags:
  - Java
  - JVM
  - JIT
  - 性能优化
  - 面试
categories:
  - JVM
author: 东哥
---

# 【JVM 底层】JIT Intrinsic 内建函数深度解析

## 前言：一个让我怀疑人生的压测结果

去年做一个日志采集 Agent 的性能优化，场景很朴素：把 `ByteBuffer` 里的字节搬到一个 4KB 的临时数组，然后做一次查找。我最初写的是手写 `for` 循环：

```java
byte[] dst = new byte[len];
for (int i = 0; i < len; i++) {
    dst[i] = src[i];
}
```

同事实在看不下去，换成了 `System.arraycopy(src, 0, dst, 0, len)`。JMH 跑下来，**吞吐差了 8 倍**。

我当时的第一反应是"JIT 应该会把我的循环优化成一样啊"。答案是不会。因为 `System.arraycopy` 走的是 **Intrinsic（内建函数）** 通道——JIT 根本不去优化它的 Java 方法体，而是直接用一段手写的汇编 stub 把那句调用整个替换掉。你的 Java 循环优化得再好，也是在"普通编译器优化"的天花板下比赛，而 intrinsic 直接换了一条赛道。

这篇文章把 intrinsic 讲透：它是什么、HotSpot 里怎么实现、哪些方法有、为什么你会"明明用了 intrinsic 却还是慢"、以及怎么诊断。

---

## 一、Intrinsic 到底是什么

JVM 规范里，`System.arraycopy` 是一个 `native` 方法（`private static native void arraycopy(...)`）。但在 HotSpot 里，它几乎从来不会被真正"调用"到 native 层。

编译期（C2 的 `LibraryCallKit`）会做这样一件事：**按"类名 + 方法名 + 精确签名"三元组去查一张 intrinsic 表，命中就把这个调用点替换成一段特殊构造的 IR（理想图），最终由后端生成专用机器码或直接跳到运行时 stub。**

关键在于"**替换**"而不是"内联展开"：

| 机制 | 做法 | 谁受益 |
|---|---|---|
| 普通内联（Inlining） | 把被调方法的 IR 复制进调用者 | 任何小方法 |
| Intrinsic | 用 JVM 内置实现整个替换调用点 | 只有白名单方法 |
| Native 方法 | 走 JNI，穿越 Java/native 边界 | 无法内联的库函数 |

所以在 `-XX:+PrintCompilation` 里，你会看到 `System.arraycopy` 所在的调用者被编译，但你**永远不会看到 `java.lang.System::arraycopy` 自己被编译成一个 Java 方法**——它根本没有 Java 方法体可编。

### 1.1 一张表决定一切：`vmIntrinsics`

HotSpot 源码里有一份枚举 `vmIntrinsics`（`vmSymbols.hpp` / `vmIntrinsics.hpp`），定义了类似：

```cpp
do_intrinsic(_arraycopy,        java_lang_System,       arraycopy_name, arraycopy_signature, F_S)
do_intrinsic(_copyOf,           java_util_Arrays,       copyOf_name, copyOf_signature, F_S)
do_intrinsic(_equals,           java_util_Arrays,       equals_name, equals_signature, F_S)
do_intrinsic(_vectorizedMismatch, java_util_ArraysSupport, vectorizedMismatch_name, ..., F_S)
do_intrinsic(_bitCount_i,       java_lang_Integer,      bitCount_name, int_bitCount_signature, F_S)
do_intrinsic(_indexOfL,         java_lang_StringLatin1, indexOf_name, ..., F_S)
```

每一项都绑定了**精确签名**。这就是所有"intrinsic 失效"故事的根源：签名差一个字，匹配不上，退回普通 Java 实现。

### 1.2 `@IntrinsicCandidate`：一个"给人看"的注解

JDK 16 起，这些方法上多了一个注解：

```java
@IntrinsicCandidate
public static native void arraycopy(Object src, int srcPos,
                                    Object dest, int destPos, int length);
```

它的全名是 `jdk.internal.vm.annotation.IntrinsicCandidate`，**只在 JDK 源码里可见，不参与编译，不影响字节码，也不影响 JIT 决策**。它的作用是告诉 JVM 工程师和普通读者："这个方法可能被 JIT 特殊处理，改动语义前先看 intrinsic 实现"。

⚠️ 划重点：**不要以为加上这个注解你的方法就变快了**。它在 `jdk.internal.vm.annotation` 包里，你自己加的类要么编译不通过（模块未导出），要么加上了也毫无作用——HotSpot 只认那张 `vmIntrinsics` 表。

JDK 16 之前它叫 `@HotSpotIntrinsicCandidate`，如果你看到老文章讲这个名字，是同一件事。

---

## 二、HotSpot 里到底有多少 intrinsic

按功能粗分类（JDK 21/25 大致情况）：

| 类别 | 代表方法 | 替换成什么 |
|---|---|---|
| 数组复制 | `System.arraycopy`、`Arrays.copyOf` | 平台汇编 stub（`arrayof_*_arraycopy`），小对象走 rep movs，大对象走向量化循环 |
| 数组比较 | `Arrays.equals`、`ArraysSupport.vectorizedMismatch` | AVX2/AVX-512 一次比 32/64 字节 |
| 字符串 | `StringLatin1.indexOf/compareTo`、`StringUTF16.*`、`String.indexOf` | SSE2/AVX2 的 `pcmpestri` / `vpcmpeqb` |
| 位运算 | `Integer.bitCount`、`Long.numberOfLeadingZeros`、`Integer.reverse` | `POPCNT`、`LZCNT`、`BSWAP` 单条指令 |
| 数学 | `Math.sqrt/sin/cos/log/exp/fma`、`Math.abs/max/min` | 直接映射到 FPU/SIMD 指令，`StrictMath` 则保证位级一致 |
| 内存/原子 | `Unsafe.compareAndSetInt`、`VarHandle` 各访问模式、`Unsafe.copyMemory` | `LOCK CMPXCHG`、`MOV` 序列 |
| 线程/系统 | `Thread.currentThread`、`Thread.onSpinWait`、`System.nanoTime` | 读 TLS 寄存器、`PAUSE` 指令、`RDTSC`/`CLOCK_MONOTONIC` |
| 对象身份 | `Object.getClass`、`Object.hashCode`、`System.identityHashCode` | 直接读 Mark Word / Klass 指针 |
| 其他 | `System.currentTimeMillis`、`Reference.get`、`StringLatin1.inflate` | 读 vDSO、读 referent 字段 |

`Object.getClass()` 那个特别值得说：它被 intrinsic 化成**一次内存读**（读对象头的 Klass 指针），所以你写 `if (obj.getClass() == Foo.class)` 几乎零成本。但如果写成 `obj instanceof Foo` 加一堆泛型，编译器可能给你生成不同的东西。

---

## 三、源码级：一个 intrinsic 是怎么被"命中"的

以 `Arrays.equals(byte[], byte[])` 为例，HotSpot 的 `LibraryCallKit::inline_array_equals` 大致逻辑：

```cpp
bool LibraryCallKit::inline_array_equals(StrIntrinsicNode::ArgEnc ae) {
  assert(argument(0)->bottom_type()->isa_aryptr(), "array");
  Node* a1 = argument(0);
  Node* a2 = argument(1);
  Node* a1_len = load_array_length(a1);
  Node* a2_len = load_array_length(a2);
  // 长度不等直接 false
  Node* cmp = _gvn.transform(new CmpINode(a1_len, a2_len));
  Node* bol = _gvn.transform(new BoolNode(cmp, BoolTest::ne));
  IfNode* iff = create_and_map_if(...);
  // 长度相等 -> vectorizedMismatch，返回首个不等位置
  Node* mism = make_runtime_call(RC_LEAF, OptoRuntime::vectorizedMismatch_Type(), ...);
}
```

你能看到三个特征：**类型系统是"编译期已知的"（`isa_aryptr`）、长度是直接读对象头的、比较走的是 `vectorizedMismatch` 运行时调用。** 这三个特征也解释了所有失效场景。

### 3.1 `vectorizedMismatch` 为什么重要

`String.equals` 的底层（JDK 9+）长这样：

```java
public boolean equals(Object anObject) {
    if (this == anObject) return true;
    return (anObject instanceof String aString)
            && (!COMPACT_STRINGS || this.coder == aString.coder)
            && StringLatin1.equals(value, aString.value);
}
```

而 `StringLatin1.equals` 最终调到 `ArraysSupport.mismatch(a, b, length)`，`mismatch` 又是 `vectorizedMismatch` 的 intrinsic。也就是说 **`String.equals` 的比较速度取决于 CPU 的向量宽度**：支持 AVX2 的机器上一次比 32 字节，纯标量实现一次比 8 字节（long）。这就是为什么"同样的代码，换台机器快 3 倍"经常不是玄学。

---

## 四、六种"我明明用了却还是慢"的真实原因

这是本文最有价值的部分。以下每一条我都在生产或压测中踩过。

### 4.1 签名失配：调错了重载

```java
// ✅ 命中 _arraycopy
System.arraycopy(src, 0, dst, 0, len);

// ❌ 不命中：走普通 Java 循环 + 泛型擦除后的 Object[] 检查
List<Byte> list = ...;
Byte[] arr = list.toArray(new Byte[0]);
```

更隐蔽的是 `Arrays.copyOf`：`copyOf(byte[], int)` 有 intrinsic，但你如果经过 `Collection.toArray`、`Stream.toArray`，中间多了一次装箱和反射数组创建，intrinsic 帮不上忙。

**实测**（JMH，4KB byte[]，JDK 21，AMD EPYC）：

| 写法 | ops/ms | 相对 |
|---|---|---|
| 手写 for 循环 | 42 | 1.0× |
| `System.arraycopy` | 336 | 8.0× |
| `Arrays.copyOf` | 318 | 7.6× |
| `ByteBuffer.put(byte[])` | 291 | 6.9× |
| `list.stream()` + 装箱 | 11 | 0.26× |

注意最后一行：**流式装箱把 intrinsic 的收益全吃掉了，还倒亏 4 倍。**

### 4.2 类型不是"编译期已知的数组"

```java
public static <T> void copy(T[] src, T[] dst) {
    System.arraycopy(src, 0, dst, 0, src.length);  // 编译期只知道 Object[]
}
```

`Object[]` 的 arraycopy 会走 **oop 数组的通用 stub**，每个元素都要做一次类型检查 + 写屏障（因为可能是引用），比 `byte[]` 的 `rep movsb` 慢一个数量级。如果你的拷贝发生在 `byte[]` 上却写成了通用泛型工具方法，恭喜你，性能回到了十年前。

### 4.3 intrinsic 被"条件"关掉了

HotSpot 有些 intrinsic 有前置条件，比如 `String.indexOf` 的 `_indexOfL` 在 `-XX:-UseSSE42Intrinsics` 或者 CPU 不支持时会退回 `StringLatin1.indexOf` 的 Java 实现。

另一种常见情况是 **`-XX:DisableIntrinsic`**。某些 APM Agent 为了插桩方便会禁用部分 intrinsic，或者你为了排查问题手动加了参数忘了删：

```bash
# 查看当前被禁用的 intrinsic
java -XX:+UnlockDiagnosticVMOptions -XX:+PrintFlagsFinal -version | grep Disable
```

### 4.4 编译层级没到 C2

intrinsic 大量在 **C2** 里实现。如果方法只被 C1 编译（分层编译的 level 1/2/3），很多 intrinsic 不生效或者只有简化版。低流量接口跑了三个月还停在 C1，压测一上来才"突然变快"，就是这个原因。

诊断：

```bash
java -XX:+UnlockDiagnosticVMOptions -XX:+PrintCompilation -XX:+PrintIntrinsics ...
```

`-XX:+PrintIntrinsics` 会打印每个被成功/失败使用的 intrinsic，输出形如：

```
  @ 12   java.lang.System::arraycopy (0 bytes)   (intrinsic)
  @ 27   java.util.Arrays::equals (0 bytes)      (intrinsic)
```

括号里的 `(intrinsic)` 就是命中标志。

### 4.5 GraalVM 的 intrinsic 是另一套

如果你跑 Graal JIT（`-XX:+UseJVMCICompiler`）或 native-image，intrinsic 的实现和覆盖范围与 C2 **不完全一致**。Graal 用 `@Substitute` 手写替代实现，某些 C2 有的 intrinsic Graal 没有，反之亦然。native-image 更极端：它在 AOT 阶段就把 `System.arraycopy` 展开成目标平台代码，几乎总比 JVM 模式快，但也更难诊断。

**结论：跨 JIT 做性能对比时，先确认 intrinsic 覆盖面一致，否则你测的是编译器的差异，不是代码的差异。**

### 4.6 手写循环反而更快的场景

不是所有情况 intrinsic 都赢。以下两种手写更快：

1. **极短长度**（< 16 字节）：intrinsic 有固定的分支判断和 stub 跳转开销，JIT 对小循环完全展开后可能更快。`System.arraycopy` 内部其实也做了 `len < 32` 的快速路径，所以差距通常在 5% 以内，不值得优化。
2. **需要同时做变换**：如果拷贝之后立刻要逐字节处理（比如 trim、转大写），合成一次循环比"arraycopy + 二次遍历"快，因为省掉了一次内存往返和 cache 污染。

---

## 五、面试常见追问

**Q1：`System.arraycopy` 和 `Arrays.copyOf` 的区别？谁更快？**

`arraycopy` 要求目标数组已存在且足够长，纯拷贝；`copyOf` 会先创建新数组再拷贝，多一次分配（可能触发 GC），但它是 `arraycopy` 的超集语义（可扩容/截断）。同长度场景下 `arraycopy` 略快，差距主要在分配成本。

**Q2：为什么 `System.arraycopy` 是 native 方法却不慢？**

因为它几乎不走 JNI。JIT 在编译期把调用点替换成 intrinsic（专用 stub 或内联循环），完全不穿越 Java/native 边界。只有解释执行阶段才会真的走到 native 实现。

**Q3：`Object.hashCode()` 为什么那么快？**

默认实现是 identity hash，intrinsic 化成从 Mark Word 里读预先算好的 31 位哈希（第一次调用时才生成，若对象处于偏向锁状态会在对象头里腾挪）。所以"hashCode 慢"通常是你重写了它并在里面做了重活。

**Q4：`String.equals` 为什么比 `Objects.equals` 快？**

`String.equals` 第一步就是引用相等短路，然后走 `StringLatin1.equals` → `vectorizedMismatch` intrinsic，一次比较 32 字节；`Objects.equals` 多一层泛型调用和 null 判断，虽然会被内联，但类型信息不如直接 `String.equals` 精确，向量化路径可能降级。

**Q5：怎么证明一个方法用了 intrinsic？**

三件套：`-XX:+PrintIntrinsics` 看命中日志、`-XX:+PrintCompilation` 确认编到 C2、JITWatch 或 `-XX:CompileCommand=print,*Foo.bar` 看生成的汇编里有没有 `vpcmpeqb`/`rep movs`/`popcnt` 这类指令。

---

## 六、落地清单

给还在"凭感觉优化"的同学一张 checklist：

1. **拷贝/比较/位运算**这三类场景优先用 JDK 现成 API，别手写；手写前先 JMH 测。
2. 泛型工具方法里做数组拷贝时，**为 `byte[]`/`char[]`/`int[]` 各写一个特化重载**，别让它们都退化到 `Object[]`。
3. 热路径上避免 `Stream` + 装箱的"顺手写法"，它会吃掉 intrinsic 收益还制造 GC 压力。
4. 上线前用 `-XX:+PrintIntrinsics`（临时开）扫一遍关键类，确认核心路径真的命中了。
5. 用 APM Agent 时确认它没有禁用 intrinsic；升级 JDK 后重新验证一遍。
6. 性能对比实验必须**同 JDK 同 CPU 同编译层级**，否则你测的是环境差异。

Intrinsic 是 JVM 里"看不见的手"：它不写在你的代码里，也不出现在字节码里，但它决定了你的热路径是跑在高速公路上还是乡间土路上。理解了它，你才真正理解"为什么 Java 能快"。
