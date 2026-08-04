---
title: Java 字符串拼接性能深度对比：+、StringBuilder、StringBuffer 与 String.join 的真相
date: 2026-08-04 10:00:00
tags:
  - Java
  - 基础
  - 性能
categories:
  - Java
  - Java基础
author: 东哥
---

# Java 字符串拼接性能深度对比：+、StringBuilder、StringBuffer 与 String.join 的真相

## 面试官：Java 里字符串拼接有几种方式？哪个性能最好？

**候选人：** 常见的有五种：`+` 运算符、`String.concat()`、`StringBuilder`、`StringBuffer`、`String.join()`。性能上：**循环内拼接用 StringBuilder，单次拼接 `+` 就够了**，StringBuffer 因为有 synchronized 反而最慢。

**面试官：** 那 `+` 在 JDK 8 和 JDK 9+ 的底层实现有什么变化？为什么循环里不能用 `+`？

## 一、为什么要关心字符串拼接？—— String 的不可变性

### 1.1 不可变性的代价

```java
String s = "a";
s = s + "b";   // 发生了什么？
```

`String` 是 **final 不可变类**，`s + "b"` 并不会修改原来的 `"a"`，而是：

1. 创建一个新 char 数组，长度 = `"a".length() + "b".length()`
2. 把 `"a"` 和 `"b"` 的内容复制进去
3. 返回新 String 对象

也就是说：**每次拼接都是一次数组分配 + 两次数组复制**。在循环里反复 `+`，会产生大量中间对象，触发频繁 GC。

```java
// 危险写法：循环内使用 +
String result = "";
for (int i = 0; i < 10000; i++) {
    result += i;   // 每次迭代创建一个新 String + 新 char[]
}
```

这段代码会创建 **10000 个中间 String 对象**和 **10000 个 char 数组**，总复制数据量约 O(n²)。

### 1.2 各种拼接方式的本质

| 方式 | 底层实现 | 线程安全 | 适用场景 |
|------|---------|---------|---------|
| `+` | 编译器优化（见下文） | — | 少量拼接 |
| `concat()` | 新数组复制 | 否 | 少量拼接 |
| `StringBuilder` | 可变 char[]，自动扩容 | 否 | 循环/大量拼接（首选） |
| `StringBuffer` | 同 StringBuilder | 是（synchronized） | 多线程共享拼接 |
| `String.join()` | 内部 StringBuilder | 否 | 集合/数组拼接分隔符 |
| `String.format()` | Formatter | 否 | 格式化场景 |

## 二、`+` 运算符的编译期魔法

### 2.1 JDK 8 及之前：StringBuilder 糖衣

JDK 8 中，`"a" + b + "c"` 会被 javac 编译成：

```java
// 源码
String s = "a" + name + "c";

// 编译后等价于
String s = new StringBuilder().append("a").append(name).append("c").toString();
```

**所以单次 `+` 拼接性能与 StringBuilder 几乎无差别**（甚至 `+` 可读性更好）。

### 2.2 JDK 9+：invokedynamic + StringConcatFactory

JDK 9 引入了 **JEP 280：Indify String Concatenation**，`+` 不再编译成 `new StringBuilder()`，而是编译成 `invokedynamic` 指令：

```java
// JDK 9+ 字节码层面
invokedynamic #makeConcatWithConstants:(String, String)String
```

实际执行时由 `StringConcatFactory` 决定拼接策略，JDK 内部有多种策略（`StringBuilderStrategy`、`StringConcatStrategy`（直接分配大数组）、`MH_INLINE_SIZED_EXACT` 等），JIT 还能进一步优化。

**好处**：
- 拼接策略**运行时可切换**，JDK 升级无需重新编译
- 可以**精确预分配**最终数组大小（一次分配，无需扩容），比固定 StringBuilder 默认 16 容量更高效
- 为未来的优化留了后门

### 2.3 为什么循环里 `+` 依然不行？

编译器**只优化单条语句内**的拼接。循环体里每次迭代都是独立的 `+` 表达式，每次迭代都会创建一个新的 StringBuilder（JDK 8）或触发一次 invokedynamic 拼接（JDK 9+），**循环外无法复用**：

```java
// JDK 8 编译后（简化）
for (int i = 0; i < 10000; i++) {
    result = new StringBuilder(result).append(i).toString();  // 每次 new！
}
```

### 2.4 循环内 StringBuilder 的正确姿势

```java
StringBuilder sb = new StringBuilder();   // 可以预估容量
for (int i = 0; i < 10000; i++) {
    sb.append(i);
}
String result = sb.toString();
```

**容量预估是关键**：

```java
// 已知最终长度约 5000 字符，直接指定容量，避免扩容
StringBuilder sb = new StringBuilder(5000);
```

StringBuilder 默认容量 16，append 时容量不够会**扩容**：`newCapacity = (oldCapacity << 1) + 2`，即翻倍扩容 + 数组复制。如果最终字符串很长，会经历多次扩容复制，提前指定容量可完全避免。

## 三、StringBuilder vs StringBuffer：synchronized 的代价

### 3.1 源码对比

```java
// StringBuilder.append —— 无锁
public StringBuilder append(String str) {
    super.append(str);
    return this;
}

// StringBuffer.append —— 加锁
public synchronized StringBuffer append(String str) {
    toStringCache = null;
    super.append(str);
    return this;
}
```

StringBuffer 的每个方法都有 `synchronized` 修饰，保证**同一时刻只有一个线程能修改**。但在单线程场景下，这个锁是纯开销（偏向锁已取消，现代 JVM 每次都是轻量级锁 CAS 或重量级锁）。

### 3.2 性能测试（JMH 示例）

```java
@Benchmark
public String stringBuilder() {
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < 100; i++) sb.append(i);
    return sb.toString();
}

@Benchmark
public String stringBuffer() {
    StringBuffer sb = new StringBuffer();
    for (int i = 0; i < 100; i++) sb.append(i);
    return sb.toString();
}
```

典型结果（JDK 17，单线程）：

| 拼接 100 次 | 吞吐量 | 相对耗时 |
|-------------|--------|---------|
| StringBuilder | ~5000 万 ops/s | 1x |
| StringBuffer | ~3000 万 ops/s | ~1.6x 慢 |
| `+`（循环内） | ~800 万 ops/s | ~6x 慢 |

**结论**：单线程永远选 StringBuilder；StringBuffer 只在你确定要**多个线程共享同一个拼接对象**时才用——而这种场景本身非常罕见（更推荐用线程局部 StringBuilder 或直接让各线程拼自己的）。

## 四、其他拼接方式的细节

### 4.1 concat()

```java
String s = "a".concat("b").concat("c");
```

`concat` 每次也创建新数组，与 `+` 单次性能相当，但**链式调用多次时**效率不如 StringBuilder（每次都要建新 String）。可读性一般，使用率低。

### 4.2 String.join()

```java
String.join(",", "a", "b", "c");          // "a,b,c"
String.join(",", list);                    // 集合拼接
StringJoiner joiner = new StringJoiner(",", "[", "]");  // 带前后缀
joiner.add("a").add("b");                  // "[a,b]"
```

`String.join` 内部就是 StringBuilder + 分隔符逻辑。**拼接集合/数组时它最简洁**，且内部会先累加总长度再一次性分配，避免多次扩容。

### 4.3 Stream Collectors.joining()

```java
list.stream().collect(Collectors.joining(","));
```

适合配合 stream 使用，内部同样是 StringBuilder（`StringJoiner`）。

### 4.4 String.format() 与消息模板

```java
String s = String.format("%s-%d", name, age);
```

`format` 内部走 `Formatter`，解析格式化字符串 + 反射/转换，**性能最差**（比 `+` 慢一个数量级），只在需要格式化语义（补零、对齐、日期格式）时使用。

## 五、现代 Java 的进阶方案：Text Blocks 与模板字符串

### 5.1 Text Blocks（JDK 15+，文本块）

```java
String json = """
    {
      "name": "%s",
      "age": %d
    }
    """.formatted(name, age);
```

文本块让多行字符串的可读性大幅提升，配合 `formatted()` 做占位符替换。

### 5.2 字符串模板 String Templates（JDK 21+，预览）

JDK 21 引入了 **JEP 430：String Templates（预览）**：

```java
String s = STR."Hello \{name}, you are \{age} years old";
```

编译器在**编译期**就能确定拼接结构，生成高效的字符串构建代码，性能上优于或持平 StringBuilder，同时**天然防注入**（可通过自定义 TemplateProcessor 转义 SQL/HTML）。这是未来字符串拼接的主流方向（JDK 23 中仍在预览演进，改名为 Template Processor 相关 API）。

## 六、字符串拼接避坑指南

### 6.1 坑一：循环内 `+`（最经典）

前面已详述，O(n²) 复制 + 海量中间对象。**凡是循环内拼接，一律 StringBuilder（预分配容量）**。

### 6.2 坑二：拼接大量 null

```java
String s = null;
String r = s + "!";   // "null!" —— 不是 NPE，是字符串 "null"！
```

`+` 会把 null 转成 `"null"` 拼接进去，容易产生线上数据事故（如日志里出现 "null"）。拼接前务必判空或用 `Objects.toString(s, "")`。

### 6.3 坑三：在锁内拼接

无谓地让 StringBuilder 拼接待在 synchronized 块里，属于**无意义的锁竞争**。StringBuilder 本身线程不安全，但"局部变量 + 单线程使用"就是安全的，不需要加锁。

### 6.4 坑四：滥用 StringBuffer

看到 `StringBuffer` 就以为更安全而全局使用——**局部变量场景它只有缺点没有优点**。IDEA 甚至会提示 "StringBuffer may be replaced with StringBuilder"。

### 6.5 坑五：StringBuilder 容量过小导致频繁扩容

```java
StringBuilder sb = new StringBuilder();       // 默认 16
for (int i = 0; i < 100000; i++) sb.append(i);
// 会扩容约 log2(最终长度/16) 次，每次扩容都复制整个数组
```

预估容量（如 `new StringBuilder(totalLength)`）或至少给个合理初始值。

## 七、面试官追问环节

### Q1：为什么 String 设计成不可变？

四个原因：
1. **字符串常量池复用**：不可变才能安全缓存，JVM 才能用常量池共享实例
2. **安全性**：作为参数（类名、URL、密码）传递时不会被篡改
3. **线程安全**：不可变对象天然线程安全
4. **hashCode 缓存**：hash 值可以缓存，HashMap 中 String key 性能好

### Q2：`new String("abc")` 和 `"abc"` 的区别？

`"abc"` 走常量池（若不存在则创建并放入池）；`new String("abc")` 在堆上**新建对象**（常量池里可能已有一个 `"abc"`）。前者创建 0~1 个对象，后者一定创建 1 个堆对象（可能 +1 个池对象）。日常用字面量即可。

### Q3：StringBuilder 的扩容机制？

初始容量 16，`append` 时若容量不足：`newCapacity = (oldCapacity << 1) + 2`（约 1.5~2 倍），然后 `Arrays.copyOf` 复制到新数组。JDK 17 起 `AbstractStringBuilder` 增加了容量溢出保护（`newCapacity` 可能为负时抛 `OutOfMemoryError`）。

### Q4：如何判断一个字符串拼接代码写得是否高效？

看三点：① 是否在循环里拼接（应提出来）；② 是否预估了容量；③ 是否在无并发场景误用 StringBuffer/加锁。

### Q5：`"a" + "b" + "c"`（全字面量）是什么时候拼接的？

**编译期**！全字面量的常量表达式会在 javac 阶段直接折叠成 `"abc"`，运行时零开销。只有含变量时才会走运行时拼接。

## 八、总结

| 场景 | 推荐方案 |
|------|---------|
| 单次/少量拼接 | `+`（可读性好，编译优化后与 StringBuilder 无异） |
| 循环/大量拼接 | `StringBuilder` + 容量预估 |
| 多线程共享拼接对象 | `StringBuffer`（极罕见） |
| 集合/数组拼接分隔符 | `String.join()` / `Collectors.joining()` |
| 格式化输出 | `String.format()` / `formatted()` |
| 未来趋势 | String Templates（JDK 21+ 预览） |

一句话：**别在循环里用 `+`，别在单线程用 `StringBuffer`，能用 `join` 就别手写分隔符逻辑**——字符串拼接的性能问题，九成出在这三个习惯上。
