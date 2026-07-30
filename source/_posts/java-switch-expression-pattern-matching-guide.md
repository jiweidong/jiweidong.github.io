---
title: 【Java核心】Switch 表达式与模式匹配演进之路：从语句到表达式的全面升级
date: 2026-07-30 08:00:00
tags:
  - Java
  - 模式匹配
  - switch表达式
  - Java 14
categories:
  - Java
  - Java语言特性
author: 东哥
---

# 【Java核心】Switch 表达式与模式匹配演进之路：从语句到表达式的全面升级

## 从一个旧代码的痛点说起

```java
// 传统 switch 语句 — 你肯定写过这种代码
String result;
switch (day) {
    case MONDAY:
    case FRIDAY:
    case SUNDAY:
        result = "休息日";
        break;
    case THURSDAY:
    case SATURDAY:
        result = "工作日";
        break;
    case WEDNESDAY:
        result = "加班日";
        break;
    default:
        result = "未知";
}
```

这段代码的问题：
1. **break 陷阱**：漏写 break 导致 fall-through
2. **变量作用域混乱**：case 块共享作用域
3. **不能赋值**：switch 是语句，不是表达式
4. **类型局限**：仅支持整型、枚举、String（直到 Java 7）
5. **冗长**：大量样板代码

> 面试官：Java 的 switch 在最近的版本有哪些重大改进？你会用新的 switch 语法吗？

## 一、Switch 表达式（Java 14 正式版）

### 1.1 箭头语法

Java 14 正式引入了 switch 表达式（预览在 Java 12、13）：

```java
// ✅ 现代写法：箭头语法 + 表达式
String result = switch (day) {
    case MONDAY, FRIDAY, SUNDAY -> "休息日";
    case TUESDAY, THURSDAY, SATURDAY -> "工作日";
    case WEDNESDAY -> "加班日";
    default -> "未知";
};
```

**关键变化：**
- `->`（箭头）替代 `:`（冒号），**无 fall-through**
- switch 可以作为**表达式**使用，直接赋值
- 多值 case：`case A, B, C ->` 替代 `case A: case B: case C:`
- 必须穷举所有情况（默认要有 default）

### 1.2 yield 返回值

当 case 分支需要多行代码时，用 `yield` 返回值：

```java
int daysInMonth = switch (month) {
    case JANUARY, MARCH, MAY, JULY, AUGUST, OCTOBER, DECEMBER -> 31;
    case APRIL, JUNE, SEPTEMBER, NOVEMBER -> 30;
    case FEBRUARY -> {
        // 多行代码块
        boolean isLeapYear = Year.isLeap(year);
        if (isLeapYear) {
            System.out.println("Leap year!");
            yield 29;  // 使用 yield 返回值
        } else {
            yield 28;
        }
    }
    default -> throw new IllegalArgumentException("Invalid month: " + month);
};
```

> 💡 `yield` 是新的关键字，用于从 switch 表达式的 case 块中返回值。**它不是 break 的替代**——break 用于控制流程，yield 用于返回值。

### 1.3 传统冒号和箭头混合

```java
// 混合写法：冒号和箭头可以在同一个 switch 中混用
String result = switch (day) {
    case MONDAY:
        System.out.println("周一来了");
        yield "辛苦";
    case FRIDAY:
    case SUNDAY -> "休息";  // 箭头分支
    default -> "工作日";
};
```

不过不建议混用，**一致性更重要**，建议统一使用箭头语法。

## 二、模式匹配（Pattern Matching）

### 2.1 instanceof 模式匹配（Java 16 正式）

这是模式匹配在 Java 中的第一步：

```java
// ❌ 旧写法
if (obj instanceof String) {
    String s = (String) obj;
    System.out.println(s.length());
}

// ✅ 新写法（Java 16+）
if (obj instanceof String s) {
    System.out.println(s.length());
}
```

模式变量 `s` 的作用域在匹配 true 的块内，**无需显式强转**。

更强大的用法：

```java
// 逻辑运算符中的模式匹配
if (obj instanceof String s && s.length() > 5) {
    System.out.println("长度超过5的字符串: " + s);
}

// 不能这样用（因为 || 没有短路保证类型安全）
// if (obj instanceof String s || s.length() > 5) { }  // ❌ 编译错误
```

### 2.2 Switch 模式匹配（Java 17 预览 → Java 21 正式）

这是 Java 模式匹配能力的核心升级：

```java
// ❌ 旧写法
public String formatValue(Object value) {
    String formatted;
    if (value instanceof Integer) {
        formatted = "int: " + ((Integer) value);
    } else if (value instanceof Long) {
        formatted = "long: " + ((Long) value);
    } else if (value instanceof String) {
        formatted = "str: " + ((String) value);
    } else if (value instanceof Double) {
        formatted = "double: " + ((Double) value);
    } else {
        formatted = "unknown: " + value;
    }
    return formatted;
}

// ✅ 新写法（Java 21+）
public String formatValue(Object value) {
    return switch (value) {
        case Integer i  -> "int: " + i;
        case Long l     -> "long: " + l;
        case String s   -> "str: " + s;
        case Double d   -> "double: " + d;
        case null       -> "null!";  // null 不再是禁区！
        default         -> "unknown: " + value;
    };
}
```

**模式匹配 switch 的核心能力：**
- switch 可以匹配任意类型（不再限于整形/String/枚举）
- 类型匹配后自动绑定变量
- `null` 可以作为合法 case（Java 17+）
- 守卫模式（guarded pattern）

### 2.3 守卫模式（Guarded Pattern）

```java
public String classify(Object value) {
    return switch (value) {
        case String s && s.length() > 10 -> "长字符串: " + s;
        case String s                    -> "短字符串: " + s;
        case Integer i && i > 0          -> "正数: " + i;
        case Integer i && i == 0         -> "零";
        case Integer i                   -> "负数: " + i;
        case null                        -> "null";
        default                          -> "其他类型";
    };
}
```

守卫模式使用 `&&` 在匹配类型后增加条件判断，**注意不能使用 `||`**。

## 三、Record 模式匹配（Java 21 正式）

### 3.1 Record 解构

这是 Java 21 带来的一大亮点：

```java
// 定义一个 Record
record Point(int x, int y) {}
record Line(Point start, Point end) {}

// 传统方式
public void printLine(Line line) {
    if (line != null) {
        Point start = line.start();
        Point end = line.end();
        System.out.println(start.x() + "," + start.y() + " → " + end.x() + "," + end.y());
    }
}

// Record 模式匹配（Java 21+）
public void printLine(Line line) {
    if (line instanceof Line(Point(var sx, var sy), Point(var ex, var ey))) {
        System.out.println(sx + "," + sy + " → " + ex + "," + ey);
    }
}
```

### 3.2 嵌套 Record 模式

```java
sealed interface Shape permits Circle, Rectangle {}
record Circle(Point center, double radius) implements Shape {}
record Rectangle(Point topLeft, Point bottomRight) implements Shape {}

public String describeShape(Shape shape) {
    return switch (shape) {
        case Circle(Point(var x, var y), var r) 
            && r > 10 -> "大圆: 圆心(" + x + "," + y + ") 半径" + r;
        case Circle(_, var r) -> "小圆: 半径" + r;  // `_` 表示忽略的值
        case Rectangle(Point(var x1, var y1), Point(var x2, var y2)) -> 
            "矩形: (" + x1 + "," + y1 + ") - (" + x2 + "," + y2 + ")";
        case null -> "null shape";
    };
}
```

Java 22+ 允许使用 `_` 通配符表示不关心的值，提升代码可读性。

## 四、Sealed Class 与 Switch 的完美配合

```java
// 定义密封类
sealed interface Vehicle permits Car, Bike, Truck {}
final class Car implements Vehicle { int seats; }
final class Bike implements Vehicle { String type; }
final class Truck implements Vehicle { double loadCapacity; }

// 编译期间确保穷举
public String describeVehicle(Vehicle v) {
    return switch (v) {
        case Car c -> "轿车: " + c.seats + "座";
        case Bike b -> "自行车: " + b.type;
        case Truck t -> "卡车: 载重" + t.loadCapacity + "吨";
        // 不需要 default！编译器知道所有子类型已被覆盖
    };
}
```

**当 switch 穷举了 sealed 类的所有子类型时，不需要 default 分支。** 如果以后新增 `Bus` 子类，编译器会**直接报错**提示你修改 switch。

## 五、性能分析

很多人担心模式匹配会有性能开销。来看看实际表现：

| 方式 | 字节码实现 | 性能表现 |
|------|-----------|---------|
| 传统 if-else | tableswitch/lookupswitch | 最快 |
| 传统 switch | tableswitch/lookupswitch | 最快 |
| instanceof 模式匹配 | 编译为普通 instanceof | 无额外开销 |
| switch 模式匹配（类型匹配） | 编译为线性比较（实际测试） | 略慢于传统 switch |
| switch 模式匹配（Record 解构） | 调用 accessor 方法 | 无额外开销 |
| 守卫模式 | 编译为 && 条件 | 等价于加 if |

**结论：模式匹配的运行时开销几乎为零**（对于类型匹配和 Record 解构），编译器会将其优化为与传统方式几乎相同的字节码。

```java
// 示例：模式匹配 vs 传统写法
public boolean isEven(Object o) {
    // 模式匹配写法
    return o instanceof Integer i && i % 2 == 0;
    
    // 编译后等价于
    // return o instanceof Integer && ((Integer) o) % 2 == 0;
}
```

## 六、演进路线图

| Java 版本 | 特性 | 状态 |
|-----------|------|------|
| Java 7 | switch 支持 String | 正式 |
| Java 12 | switch 表达式（预览） | 预览 |
| Java 13 | switch 表达式 + yield（预览） | 预览 |
| Java 14 | switch 表达式 | **正式** |
| Java 16 | instanceof 模式匹配 | **正式** |
| Java 17 | switch 模式匹配（预览） | 预览 |
| Java 19 | Record 模式（预览） | 预览 |
| Java 21 | switch 模式匹配 + Record 模式 | **正式** |
| Java 22 | 通配符 `_` 优化 | 正式 |
| Java 24+ | 未来：deconstruction 增强 | 持续演进 |

## 七、常见面试题

### Q1: 箭头 switch 和冒号 switch 的区别？

> 箭头 switch 使用 `->`，无 fall-through，case 默认不穿透。冒号 switch 使用 `:`，需要手动 break。箭头 switch 可以作为表达式使用并返回值。**推荐所有新代码使用箭头语法。**

### Q2: yield 和 return 有什么区别？

> `yield` 从 switch 表达式的 case 块返回值。`return` 从整个方法返回。在 switch 表达式的块中使用 `return` 会**直接退出方法**。

### Q3: 编译能检查 switch 是否穷举吗？

> 可以。当 switch 的目标是 `sealed` 类型或 `enum` 时，如果穷举了所有可能性，编译器可以省略 default 分支。如果后续新增子类/枚举常量，编译器会**报错**提示未处理。这是类型安全的重大提升。

### Q4: 模式匹配会影响性能吗？

> 基本不影响。实例类型检查被编译为 `instanceof` 指令，Record 解构编译为 accessor 调用，守卫模式编译为 `&&` 条件。编译器还会进行**优化排序**，将最常用的模式放在前面。实际测试中，模式匹配与传统写法性能差异在 **1-3%** 以内。

## 总结

从 Java 14 的 switch 表达式，到 Java 16 的 instanceof 模式匹配，再到 Java 21 全面推出的 switch 模式匹配和 Record 模式，Java 正在经历一次**语言级别的范式升级**。

```
传统 Java：         命令式 + 大量样板代码
现代 Java（21+）：  声明式 + 模式匹配 + 表达式风格
```

切换到新语法的好处非常明显：
1. **更少的代码**：减少 40-60% 的样板代码
2. **更安全**：编译器可以检查穷举性、null 安全
3. **更可读**：意图直接表达，而非通过流程控制隐式表达
4. **零开销**：编译器优化，运行时无额外开销

如果你还在用 Java 8-11，这些特性足以成为**升级到 Java 21 的理由**。
