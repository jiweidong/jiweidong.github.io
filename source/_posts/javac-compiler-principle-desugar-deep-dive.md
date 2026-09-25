---
title: 【Java 核心】javac 编译原理深度解析：从源码到字节码的完整链路与语法糖揭秘
date: 2026-09-25 08:00:00
tags:
  - Java
  - JVM
  - 编译原理
  - 字节码
  - 面试
categories:
  - Java
  - Java核心
author: 东哥
---

# 【Java 核心】javac 编译原理深度解析：从源码到字节码的完整链路与语法糖揭秘

## 面试官：一行 Java 代码是怎么变成 class 文件的？

面试官推过来一行代码：

```java
public class Demo {
    public static String f(List<String> list) {
        int sum = 0;
        for (String s : list) {
            sum += Integer.parseInt(s);
        }
        return "sum=" + sum;
    }
}
```

「你说说，这段代码编译之后，字节码里还能看到 `for-each` 吗？泛型 `List<String>` 里的 `String` 还在吗？`"sum=" + sum` 是怎么拼接的？」

很多人能背出「编译期、运行期、字节码、JVM」，但一旦问到 **javac 到底做了哪几步、语法糖是在哪一步被抹掉的**，就开始含糊了。这篇就把 javac 的完整链路和最常考的「解语法糖（desugar）」环节讲透。

## 一、javac 的整体架构：一条流水线

javac 是 JDK 自带的编译器（`com.sun.tools.javac` 包），它并不是「读源码 → 直接吐字节码」这么简单，而是一条多阶段的流水线。核心流程可以概括为：

```
源码 .java
   │  ① 词法分析 Lexer / Scanner
   ▼
Token 流
   │  ② 语法分析 Parser
   ▼
抽象语法树 AST（JCTree）
   │  ③ 符号表 Enter
   ▼
符号表 + 注解处理（APT）
   │  ④ 标注 / 语义分析 Attr、Flow
   ▼
带类型的 AST
   │  ⑤ 解语法糖 Desugar（TransTypes / Lower）
   ▼
去糖后的 AST
   │  ⑥ 字节码生成 Gen / Code
   ▼
.class 文件
```

对应的入口是 `JavaCompiler`（`javax.tools.ToolProvider.getSystemJavaCompiler()`），真正干活的是 `com.sun.tools.javac.main.JavaCompiler#compile`，它串起了 `parse → enter → processAnnotations → attribute → flow → desugar → generate` 这些步骤。

| 阶段 | 关键类 | 做什么 |
| --- | --- | --- |
| 词法分析 | `Scanner` | 字符流 → Token 流 |
| 语法分析 | `JavacParser` | Token → AST |
| 符号表 | `Enter` / `MemberEnter` | 建立符号、作用域 |
| 注解处理 | `JavacProcessingEnvironment` | 运行 APT（编译期生成代码） |
| 语义分析 | `Attr` / `Check` / `Flow` | 类型检查、常量折叠、可达性分析 |
| 解语法糖 | `TransTypes` / `Lower` | 去除语法糖，降级为「朴素」代码 |
| 字节码生成 | `Gen` / `Code` | AST → 指令 + 常量池 + StackMapTable |

## 二、词法分析与语法分析：AST 长什么样

**词法分析**把字符流切成 Token：关键字、标识符、字面量、运算符、分号。javac 里叫 `Scanner`，输出 `Token` 枚举。

**语法分析**用递归下降解析器（`JavacParser`）把 Token 流组织成 AST。javac 的 AST 节点都继承自 `JCTree`，例如：

- `JCTree.JCClassDecl`：类声明
- `JCTree.JCMethodDecl`：方法声明
- `JCTree.JCForLoop`：普通 for
- `JCTree.JCEnhancedForLoop`：增强 for（for-each）
- `JCTree.JCBinary`：二元运算
- `JCTree.JCTypeApply`：带泛型参数的类型的应用

这一步只关心「语法对不对」，不关心「类型对不对」。所以 `String s = 1;` 能顺利建树，报错要等到语义分析阶段。

## 三、符号表与语义分析：类型检查发生在哪里

`Enter` 阶段把类、字段、方法登记进符号表（`Symbol` / `Scope`），解决「这个名字指向哪个声明」。

`Attr` 阶段做标注（attribute）——给每个 AST 节点贴上类型信息，这是真正的类型检查：

- 变量是否已声明、方法是否存在且可访问
- 泛型类型是否匹配（**类型推断也在这里**）
- 重载方法选择（静态分派在第 15 节会讲到，这是一次「编译期选择」）

`Flow` 阶段做数据流分析，最典型的是**确定性赋值（definite assignment）**：

```java
int x;
if (flag) { x = 1; }
System.out.println(x); // 编译错误：可能尚未初始化
```

这就是 `Flow` 报出来的，而不是运行时。同时它还会做**常量折叠**：

```java
final int A = 2 * 3 + 4;   // 编译期直接算成 10
static final String S = "a" + "b"; // 编译期拼成 "ab"
```

这里有个经典面试点：**`final` 修饰的基本类型/字符串常量，是编译期常量**，会被内联到使用处，因此改了常量值却只重新编译一半代码，就会出现「旧值还在」的诡异现象（常量传播陷阱）。

## 四、解语法糖（Desugar）：javac 最值得深挖的一步

Java 语法糖是指**对程序员友好但 JVM 并不认识**的语法。javac 在 `desugar` 阶段把它们「降级」为更朴素的形式。注意：**这一步发生在 AST 层面**，也就是说除 Lambda 的 `invokedynamic` 外，大多数糖在字节码里完全看不到痕迹。

下面逐条拆。

### 4.1 增强 for（for-each）→ 迭代器 / 下标循环

数组形式的 for-each 会被降级为普通下标循环；集合形式的会被降级为显式迭代器：

```java
// 源码
for (String s : list) { sum += Integer.parseInt(s); }

// 脱糖后（等价形式）
for (Iterator<String> it = list.iterator(); it.hasNext(); ) {
    String s = it.next();
    sum += Integer.parseInt(s);
}
```

**面试追问**：为什么删除集合元素时会抛 `ConcurrentModificationException`？
因为 for-each 用的是迭代器，迭代器内部维护 `modCount`，`add/remove` 会修改 `modCount` 导致 `checkForComodification` 失败。正确做法是用 `Iterator.remove()` 或 `removeIf`。

### 4.2 泛型擦除 → 强转插入

泛型信息在 `Attr` 阶段用于类型检查，在 `desugar` 阶段被擦除（`TransTypes`）。`List<String>` 变成 `List`，取值处被插入 `checkcast`：

```java
// 脱糖后
for (Iterator it = list.iterator(); it.hasNext(); ) {
    String s = (String) it.next(); // 插入 checkcast
    ...
}
```

这就是「泛型是编译期语法糖」的由来。桥接方法（bridge method）、通配符、类型擦除带来的重载冲突，都是这一机制的直接后果。

### 4.3 自动装箱 / 拆箱 → valueOf / xxxValue

```java
Integer a = 1;      // Integer.valueOf(1)
int b = a;          // a.intValue()
a++;                // a = Integer.valueOf(a.intValue() + 1)
```

**坑点**：循环里做 `Long sum` 累加会创建大量对象，是性能热点；同时 `Integer` 缓存只覆盖 `-128~127`，所以 `Integer.valueOf(127) == Integer.valueOf(127)` 为 `true`，`128` 则为 `false`。

### 4.4 可变参数 → 数组

```java
void f(String... args) { }
// 等价于 void f(String[] args)
```

调用 `f("a", "b")` 会被编译成 `f(new String[]{"a", "b"})`。所以「传数组」和「传列表」是两回事。

### 4.5 字符串拼接 → StringBuilder / invokedynamic

JDK 8 及以前，`"sum=" + sum` 会生成 `StringBuilder` 的 `append` 链；JDK 9 之后引入 `StringConcatFactory`，改成一条 `invokedynamic` 指令，由 `LambdaMetafactory`/`StringConcatFactory` 在**首次运行**时生成最优拼接策略（可能直接用 `MethodHandle` 拼字节数组，减少中间对象）：

```
// JDK 9+
invokedynamic #7  // makeConcatWithConstants:(I)Ljava/lang/String;
```

对比：

| 写法 | 编译产物 | 说明 |
| --- | --- | --- |
| `"a" + "b"` | 常量 `"ab"` | 常量折叠，无运行时开销 |
| 变量拼接（JDK 8） | `StringBuilder.append` | 循环内会反复 new，需手动提 StringBuilder |
| 变量拼接（JDK 9+） | `invokedynamic` | 首次链接开销，之后高效 |
| `String.join` / `StringBuilder` | 复用同一 buffer | 大循环首选 |

### 4.6 try-with-resources → try/finally + addSuppressed

```java
try (InputStream in = open()) {
    ...
}
// 脱糖后
InputStream in = open();
Throwable primary = null;
try { ... }
catch (Throwable t) { primary = t; throw t; }
finally {
    if (in != null) {
        if (primary != null) {
            try { in.close(); }
            catch (Throwable t) { primary.addSuppressed(t); }
        } else { in.close(); }
    }
}
```

**面试追问**：如果 `try` 块和 `close()` 都抛异常，谁被抛出？——`try` 块的异常是主异常，`close()` 的异常被 `addSuppressed` 挂上去（`getSuppressed()` 可取）。这正是 try-with-resources 优于手写 finally 的地方。

### 4.7 Lambda 与 `invokedynamic`

Lambda 是**唯一在字节码里留有明显痕迹**的语法糖：编译期只生成一条 `invokedynamic` + 一个私有静态合成方法（lambda body，命名为 `lambda$xxx$0`），运行时由 `LambdaMetafactory` 在第一次执行到该指令时动态生成实现类（`$Lambda$1/0x...`）。

```java
Runnable r = () -> System.out.println("hi");
// 字节码：invokedynamic #7 // run:()Ljava/lang/Runnable;
// 私有合成方法：private static void lambda$main$0()
```

要点：
- Lambda **不生成独立的 class 文件**（运行期在内存里定义），而匿名内部类会生成 `Outer$1.class`。
- Lambda 的实例 `getClass()` 名字形如 `Demo$$Lambda$14/0x0000000800c00a40`。
- 方法引用（`String::length`）同样走 `invokedynamic`，但可能不需要合成方法。

### 4.8 switch、枚举、内部类、assert、类型注解

- **增强 switch（箭头、yield、表达式）**：脱糖为普通 `switch` + 临时变量，或 `tableswitch/lookupswitch`。
- **枚举**：脱糖为一个 `final class XxxEnum extends Enum`，枚举常量是 `public static final` 字段，`values()` 返回克隆的数组，`valueOf` 走 `Enum.valueOf`。
- **内部类**：非静态内部类会持有外部类引用（`this$0` 字段），构造器多一个外部类参数。这也是匿名内部类/非静态内部类可能**内存泄漏**的根源。
- **assert**：默认被禁用，开启后脱糖为 `if (!$assertionsDisabled && !cond) throw new AssertionError()`。
- **字符串 switch**：JDK 7 起脱糖为「先算 `hashCode` 再 `equals` 校验」的两级 switch。

## 五、字节码生成：Gen 与 StackMapTable

最后一步 `Gen`/`Code` 把 AST 翻译成 JVM 指令，同时：

1. 构建**常量池**（`CONSTANT_Utf8/Class/String/Methodref/...`）；
2. 计算 `max_stack` / `max_locals`；
3. 生成**异常表**（try-catch-finally 的保护区）；
4. 生成 **StackMapTable**（Java 6 起，用于类型校验的栈映射帧），也就是 `【JVM 底层】字节码校验机制深度解析` 里提到的验证基础。

## 六、实战：亲眼看见脱糖

### 6.1 看字节码

```bash
javac Demo.java
javap -c -p -v Demo.class
```

观察点：
- `for-each` 变成了 `Iterator.hasNext/next`；
- 泛型 `List<String>` 在描述符里是 `Ljava/util/List;`（擦除）；
- 取值前有 `checkcast java/lang/String`；
- 拼接是 `invokedynamic makeConcatWithConstants`（JDK 9+）。

### 6.2 看「脱糖后的源码」

javac 有个隐藏开关 `-XD-printflat`，可以打印 desugar 之后的源码（近似）：

```bash
javac -XD-printflat -d out Demo.java
```

### 6.3 用 JCTree API 自己写个分析器

通过 `com.sun.source.util.JavacTask` 和 `TreeScanner`，可以在编译期访问 AST，这和自己写注解处理器（APT）是同一条技术路线：

```java
JavacTask task = (JavacTask) compiler.getTask(null, fm, null, null, null,
        List.of(new JavaFileObject(...)));
for (CompilationUnitTree unit : task.parse()) {
    unit.accept(new TreeScanner<Void, Void>() {
        @Override public Void visitMethodInvocation(MethodInvocationTree node, Void p) {
            System.out.println("调用方法: " + node.getMethodSelect());
            return super.visitMethodInvocation(node, p);
        }
    }, null);
}
```

## 七、面试追问合集

**Q1：Java 是编译型还是解释型？**
两者都是。javac 把源码编译成字节码（编译），JVM 再用解释器执行、用 JIT 把热点代码编译成本地机器码（编译）。所以更准确的说法是「编译 + 解释 + 即时编译」的混合模式。

**Q2：语法糖是编译器还是 JVM 干的？**
绝大多数在 javac 的 desugar 阶段（AST 层面）完成，字节码里看不到。唯一例外是 Lambda/方法引用，编译期只留 `invokedynamic`，真正实现类是运行期 `LambdaMetafactory` 生成的。

**Q3：为什么泛型要擦除？**
为了**向后兼容**：JDK 5 引入泛型时，必须让 1.4 编译的类库与 5.0 的代码共存。擦除让泛型不进入字节码，从而复用了既有的 `List` 类文件。代价是没有运行时类型信息、不能 `new T[]`、不能对泛型做 `instanceof`。

**Q4：`-XD-printflat` 打印的是最终字节码吗？**
不是，是脱糖后的源码近似，方便你理解编译器做了哪些改写。要看最终形态仍得用 `javap`。

**Q5：常量折叠会带来什么线上事故？**
把带版本的常量（如接口/协议名）定义在 `static final` 里，若两边分开编译，改动后可能只有一边重新编译，导致「常量传播」旧值。解法：改动常量后全量编译，或改为 `static final` 但通过方法读取（不内联）。

## 八、总结

- javac 是一条流水线：`词法 → 语法 → 符号表/注解 → 语义分析 → 解语法糖 → 字节码生成`。
- 类型检查、重载选择、常量折叠在 `Attr/Flow`；语法糖在 `desugar`；`invokedynamic` 与运行期链接是 Lambda 的特殊路径。
- 理解 desugar，才能解释「为什么 for-each 删元素会 CME」「为什么泛型不能 new 数组」「为什么 try-with-resources 能把 close 的异常挂成 suppressed」「为什么 Lambda 没有独立 class 文件」。
- 亲手用 `javap -c -p -v` 和 `-XD-printflat` 验证一遍，比背十遍概念都管用。

下一篇我们继续扒 JVM 的另一条暗线：类加载之后的**链接与初始化**，看看字节码是怎么真正「活」起来的。
