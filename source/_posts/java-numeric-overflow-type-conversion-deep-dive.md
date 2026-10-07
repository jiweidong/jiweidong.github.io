---
title: 【Java 核心】数值溢出与类型转换陷阱深度解析：从二分查找经典 Bug 到 Math.addExact 实战
date: 2026-10-07 08:00:00
tags:
  - Java
  - Java基础
  - 面试
  - 类型系统
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【Java 核心】数值溢出与类型转换陷阱深度解析：从二分查找经典 Bug 到 Math.addExact 实战

## 面试官：你知道 JDK 里也藏了二十年的溢出 Bug 吗？

面试官刚坐下就抛出一个问题：

> "`Arrays.binarySearch` 你用过吧？如果让你手写二分查找，`mid` 怎么算？"

很多人下意识回答：

```java
int mid = (low + high) / 2;
```

"没错，教科书都这么写。"面试官点点头，"但 JDK 在 2006 年之后改成了 `mid = (low + high) >>> 1`，为什么？"

答案就两个字：**溢出**。

当 `low` 和 `high` 都接近 `Integer.MAX_VALUE` 时，`low + high` 会超过 `int` 的表示范围而回绕成负数，除以 2 得到负数下标，数组直接抛 `ArrayIndexOutOfBoundsException`。这个 Bug 在 JDK 里潜伏了近十年（著名的 "Extra, Extra - Read All About It: Nearly All Binary Searches and Mergesorts are Broken"），连 Java 之父 Joshua Bloch 都专门写博客复盘过。

数值溢出不是"小学数学题"，而是**生产事故级**的坑。这一篇我们从溢出原理讲到类型转换规则，再落到真实防御手段。

## 一、整数溢出的本质：补码回绕

Java 的 `int` 是 32 位**有符号补码**，取值 `[-2^31, 2^31-1]`，即 `[-2147483648, 2147483647]`。

补码的加减法本身就是"模 2³² 运算"，超出范围的部分被直接丢弃（回绕），不会报错、不会抛异常：

```java
int max = Integer.MAX_VALUE;        // 2147483647
System.out.println(max + 1);        // -2147483648  静默回绕！
System.out.println(max * 2);        // -2

long wrong = 1000 * 60 * 60 * 24 * 365;  // 全是 int 运算，先溢出再赋给 long
System.out.println(wrong);          // 1471228928（已经不是一年毫秒数了）
```

第三行是最典型的"**赋值给 long 也没用**"陷阱：Java 先按 `int` 完成右侧所有运算，结果已经错了，再宽化到 `long` 只是把错误值变大。

正确写法是让第一个操作数就是 `long`，触发整体提升：

```java
long days = 1000L * 60 * 60 * 24 * 365;   // 31536000000
```

### 常见溢出场景清单

| 场景 | 危险写法 | 后果 |
| --- | --- | --- |
| 二分查找 | `(low + high) / 2` | 负数下标，越界 |
| 时间计算 | `days * 24 * 3600 * 1000` | 天数为 int，>24 天就错 |
| 金额（分转元） | `cents * 100` 混用 | 精度/溢出双炸 |
| 累加统计 | `sum += value` 无边界 | 静默变负数，报表离谱 |
| 哈希/随机种子 | `a * 31 + b` 长链 | 溢出虽"可接受"但语义脆弱 |
| 时间戳差值 | `t2 - t1` 跨年比较 | 溢出导致比较逻辑反转 |

### 面试追问 1：为什么 `Math.abs(Integer.MIN_VALUE)` 还是负数？

因为 `Integer.MIN_VALUE = -2^31`，它的相反数 `+2^31` 已经超出 `int` 上界，取反后**回绕回自身**：

```java
System.out.println(Math.abs(Integer.MIN_VALUE));  // -2147483648
System.out.println(Math.abs((long) Integer.MIN_VALUE)); // 2147483648  正确
```

`Long.MIN_VALUE` 同理。所以任何"先取绝对值再比大小"的容量/差值逻辑，都必须先转 `long` 或直接比较原值。

## 二、隐式类型转换：JLS 到底怎么提升的

Java 的类型提升有明确规则（JLS §5.6），而不是"随便变宽"。二目运算按下表统一类型，**从中选最宽的那个**：

| 参与类型 | 提升结果 |
| --- | --- |
| byte / short / char | int |
| int / long | long |
| long / float | float |
| float / double | double |
| 任意 + String | String（拼接） |

关键点：**`byte`、`short`、`char` 参与运算一律先提升为 `int`**，这也是为什么下面这段代码编译不过：

```java
short a = 1, b = 2;
// short c = a + b;  // 编译错误：a+b 的结果是 int
short c = (short) (a + b);  // 必须显式窄化
```

### 复合赋值运算符的隐藏窄化

`+=`、`*=` 这类复合赋值**内置了一次隐式窄化转换**：

```java
byte b = 127;
b += 1;              // 合法，等价于 b = (byte)(b + 1) → -128
// b = b + 1;        // 非法：需要 (byte) 强转

int i = 1;
i += 1.5;            // 合法，i = (int)(1 + 1.5) = 2，小数被直接截断
```

这是很多"字段莫名变负"的元凶：`counter += delta` 在 `byte`/`short` 上回绕是静默的。

### 面试追问 2：三元表达式为什么突然抛 NPE？

三元运算符 `?:` 会对两个分支做**类型统一**，如果一边是基本类型、一边是包装类型，会发生**自动拆箱**：

```java
Map<String, Integer> map = new HashMap<>();
Integer value = map.get("not-exist");   // null

// 条件为 false 时本应走 0，但整个表达式类型被统一为 int
// 于是 value 被拆箱 → NullPointerException
int result = true ? 0 : value;
```

修复方式是把 `0` 写成 `Integer.valueOf(0)`，或者干脆用 `Objects.requireNonNullElse`。这是"**隐式拆箱 NPE**"的经典变体，答案在 JLS §15.25 的三元表达式类型规则里。

## 三、浮点数：不是溢出，但同样致命

`float`/`double` 遵循 IEEE 754，二进制无法精确表示大多数十进制小数：

```java
System.out.println(0.1 + 0.2);        // 0.30000000000000004
System.out.println(0.1f + 0.2f);      // 0.3 附近但 binary 不同
System.out.println(1.0 - 0.9);        // 0.09999999999999998
System.out.println(1.0 / 0);          // Infinity（整数除 0 才抛异常）
```

**金额、计数、任何要求精确的十进制运算，一律用 `BigDecimal`**，并且：

```java
// ❌ 用 double 构造，误差直接带进来
new BigDecimal(0.1);          // 0.1000000000000000055511151231257827...

// ✅ 用 String 或 valueOf 构造
new BigDecimal("0.1");        // 精确的 0.1
BigDecimal.valueOf(0.1);      // 内部用 Double.toString，也安全

// ✅ 除法必须指定精度和舍入模式，否则除不尽抛 ArithmeticException
BigDecimal a = new BigDecimal("1");
BigDecimal b = new BigDecimal("3");
a.divide(b, 2, RoundingMode.HALF_UP);   // 0.33
```

还有一个高频坑：**`BigDecimal.equals` 会比较 scale**：

```java
new BigDecimal("1.0").equals(new BigDecimal("1.00"));        // false！
new BigDecimal("1.0").compareTo(new BigDecimal("1.00"));     // 0（相等）
```

所以集合去重、Map 的 key、断言比较，用 `compareTo` 或先 `stripTrailingZeros`。

### 浮点溢出与特殊值

浮点不会"回绕"，而是产生 `Infinity` / `-Infinity` / `NaN`，且 `NaN != NaN`：

```java
double x = 1e308 * 10;         // Infinity
System.out.println(x == x);    // true
double nan = 0.0 / 0.0;        // NaN
System.out.println(nan == nan);        // false
System.out.println(Double.isNaN(nan)); // true  ← 必须这样判断
```

在风控、计费、指标聚合里，一个 `NaN` 可能让整个求和结果变成 `NaN`，必须显式校验。

## 四、生产级防御：Math.exact 家族与溢出检测

JDK 8 提供了 `Math.addExact` / `subtractExact` / `multiplyExact` / `toIntExact`，**溢出时直接抛 `ArithmeticException`**，把静默错误变成快速失败：

```java
@FunctionalInterface
interface LongBinaryOp { long apply(long a, long b); }

public final class OverflowGuard {

    /** 安全累加，溢出即抛出，避免报表静默变负 */
    public static long safeSum(long... values) {
        long sum = 0L;
        for (long v : values) {
            sum = Math.addExact(sum, v);
        }
        return sum;
    }

    /** 分转元：用整数分做运算，只在输出时转小数，全程无浮点 */
    public static BigDecimal fenToYuan(long fen) {
        return BigDecimal.valueOf(fen, 2);   // 2 位 scale，精确
    }

    /** 容量计算：先提升到 long，再判断是否越界 */
    public static int toIntSafely(long bytes) {
        return Math.toIntExact(bytes);       // 超出 int 直接抛 ArithmeticException
    }

    /** 用 BigInteger 兜底需要精确大数累加的场景 */
    public static BigInteger safeProduct(int a, int b, int c) {
        return BigInteger.valueOf(a)
                .multiply(BigInteger.valueOf(b))
                .multiply(BigInteger.valueOf(c));
    }
}
```

配套的单元测试应该是"**溢出即失败**"的断言，而不是 `assertTrue(sum < 0)`：

```java
@Test
void addExact_shouldThrowOnOverflow() {
    assertThrows(ArithmeticException.class,
            () -> Math.addExact(Integer.MAX_VALUE, 1));
}

@Test
void fenToYuan_shouldKeepScale() {
    assertEquals(new BigDecimal("12.34"),
            OverflowGuard.fenToYuan(1234));
}

@Test
void ternary_unboxing_npe() {
    Integer value = null;
    assertThrows(NullPointerException.class,
            () -> { int r = true ? 0 : value; });
}
```

### 防御式检查清单

| 场景 | 推荐做法 |
| --- | --- |
| 时间/容量计算 | 首操作数写成 `L` 后缀字面量 |
| 用户输入转数字 | `Math.toIntExact` + 捕获 `ArithmeticException` |
| 金额运算 | `BigDecimal` + `String` 构造 + 显式 `RoundingMode` |
| 累加统计 | `Math.addExact` 或 `BigInteger` |
| 比较 BigDecimal | 一律 `compareTo`，禁止 `equals` |
| 浮点判等 | 用 `Math.abs(a-b) < EPS` 或 `Double.compare` |
| 判 NaN/Infinity | `Double.isNaN` / `isInfinite` |
| 压测数据构造 | 边界值：`MAX_VALUE`、`MIN_VALUE`、0、-1 |

## 五、面试收尾：一句话答透

面试官最后问："如果让你总结 Java 数值这套东西，你会怎么说？"

可以这样回答：

> 一是**补码是模运算**，整数溢出不会报错只会回绕，所以时间、容量、金额计算必须先把操作数提升到 `long` 或用 `Math.exact*` 快速失败；
> 二是**类型提升和窄化是编译期规则**，`byte`/`short` 参与运算升 `int`，复合赋值和三元表达式会隐式窄化/拆箱，导致静默截断和 NPE；
> 三是**浮点不精确且不可用 `==`**，需要精确十进制就用 `BigDecimal`，并且注意 `equals` 比 scale、除法要指定舍入模式。

三句话，把"溢出—转换—精度"三层坑全覆盖。这也是为什么 JDK 自己的 `binarySearch` 都要写 `(low + high) >>> 1` —— **库代码的每一处奇怪写法，背后大概率都有一个血泪 Bug**。

### 常见追问速查

| 追问 | 要点 |
| --- | --- |
| `i++` 和 `++i` 在溢出时区别？ | 都回绕，区别只在表达式取值 |
| `char` 能存中文吗？ | 能（BMP 内），但算 `char+char` 得 `int` |
| `Integer` 缓存范围？ | `-128 ~ 127`，`==` 比较在边界外会 false |
| `float` 精度多少位？ | 约 7 位有效十进制，`double` 约 15~16 位 |
| 为什么 `1.0/0` 不抛异常？ | IEEE 754 定 `Infinity`，整数除 0 才抛 `ArithmeticException` |
| `Long` 也会溢出吗？ | 会，纳秒级时间戳运算极易溢出，用 `Math.multiplyExact` |
