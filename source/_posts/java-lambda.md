---
title: Java Lambda 表达式从入门到精通
date: 2026-06-08 23:30:00
tags: [Java, Lambda, 函数式编程]
categories: Java
---

## 什么是 Lambda 表达式？

Lambda 表达式是 Java 8 引入的最重要的特性之一，它允许把函数作为方法的参数传递，让代码更简洁、更灵活。

### 基本语法

```java
(参数列表) -> { 方法体 }
```

- **左侧**：参数列表（可以省略参数类型）
- **右侧**：Lambda 体（表达式或代码块）

## 一、Lambda 入门示例

### 1. 无参数

```java
// 传统方式
Runnable r1 = new Runnable() {
    @Override
    public void run() {
        System.out.println("Hello");
    }
};

// Lambda 方式
Runnable r2 = () -> System.out.println("Hello");
```

### 2. 一个参数

```java
// 传统方式
Consumer<String> c1 = new Consumer<String>() {
    @Override
    public void accept(String s) {
        System.out.println(s);
    }
};

// Lambda 方式
Consumer<String> c2 = s -> System.out.println(s);
```

### 3. 多个参数

```java
// 传统方式
Comparator<Integer> comp1 = new Comparator<Integer>() {
    @Override
    public int compare(Integer a, Integer b) {
        return a.compareTo(b);
    }
};

// Lambda 方式
Comparator<Integer> comp2 = (a, b) -> a.compareTo(b);
```

## 二、函数式接口

Lambda 表达式需要函数式接口的支持。函数式接口是**只有一个抽象方法**的接口，用 `@FunctionalInterface` 注解标记。

Java 8 内置了四大核心函数式接口：

| 接口 | 参数 | 返回值 | 用途 |
|------|------|--------|------|
| `Predicate<T>` | T | boolean | 断言 |
| `Consumer<T>` | T | void | 消费 |
| `Function<T,R>` | T | R | 转换 |
| `Supplier<T>` | 无 | T | 供给 |

### Predicate 示例

```java
Predicate<String> isEmpty = s -> s.isEmpty();
Predicate<String> isLongerThan3 = s -> s.length() > 3;

// 组合使用
Predicate<String> complex = isEmpty.negate().and(isLongerThan3);
System.out.println(complex.test("hello")); // true
```

### Consumer 示例

```java
Consumer<String> print = s -> System.out.println(s);
Consumer<String> log = s -> System.out.println("[LOG] " + s);

// 链式调用
print.andThen(log).accept("Hello");
// 输出：
// Hello
// [LOG] Hello
```

### Function 示例

```java
Function<String, Integer> toLength = s -> s.length();
Function<Integer, String> toString = i -> "长度: " + i;

// 组合
Function<String, String> composed = toLength.andThen(toString);
System.out.println(composed.apply("Java")); // 长度: 4
```

## 三、方法引用

当 Lambda 体只有一行且调用已有方法时，可以用方法引用进一步简化。

```java
// Lambda
list.forEach(s -> System.out.println(s));

// 方法引用
list.forEach(System.out::println);
```

四种方法引用形式：

| 类型 | 语法 | 示例 |
|------|------|------|
| 静态方法引用 | `类名::静态方法` | `Integer::parseInt` |
| 实例方法引用 | `对象::实例方法` | `System.out::println` |
| 特定类型方法引用 | `类名::实例方法` | `String::length` |
| 构造方法引用 | `类名::new` | `ArrayList::new` |

## 四、实战案例

### 1. 集合排序

```java
List<String> names = Arrays.asList("Bob", "Alice", "Charlie", "David");

// Lambda 排序
names.sort((a, b) -> a.compareTo(b));

// 方法引用
names.sort(String::compareTo);

// 更简洁
names.sort(Comparator.naturalOrder());
```

### 2. 集合过滤

```java
List<User> users = getUsers();

// 过滤出年龄大于 18 的用户
List<User> adults = users.stream()
    .filter(u -> u.getAge() > 18)
    .collect(Collectors.toList());

// 按年龄排序
List<User> sorted = users.stream()
    .sorted(Comparator.comparing(User::getAge))
    .collect(Collectors.toList());

// 提取姓名列表
List<String> names = users.stream()
    .map(User::getName)
    .collect(Collectors.toList());
```

### 3. 自定义函数式接口

```java
@FunctionalInterface
interface Calculator {
    int calculate(int a, int b);
}

// 使用 Lambda 实现不同运算
Calculator add = (a, b) -> a + b;
Calculator subtract = (a, b) -> a - b;
Calculator multiply = (a, b) -> a * b;

System.out.println(add.calculate(5, 3));      // 8
System.out.println(subtract.calculate(5, 3)); // 2
System.out.println(multiply.calculate(5, 3)); // 15
```

### 4. 延迟执行

```java
public static void log(Level level, Supplier<String> msgSupplier) {
    if (level == Level.ERROR) {
        System.out.println(msgSupplier.get());
    }
}

// 只有满足条件时才计算日志内容
log(Level.ERROR, () -> "复杂计算: " + expensiveOperation());
```

## 五、Lambda 与匿名内部类的区别

| 对比项 | Lambda | 匿名内部类 |
|--------|--------|-----------|
| 关键字 | `->` | `new` |
| 接口限制 | 必须是函数式接口 | 任意接口或类 |
| this 指向 | 外部类 | 匿名内部类自身 |
| 编译产物 | invokedynamic | 生成 class 文件 |
| 性能 | 更好（延迟加载） | 稍差 |

## 总结

Lambda 表达式让 Java 代码更简洁、更灵活。配合 Stream API 和函数式接口，可以写出高效的函数式代码。核心要点：

1. **语法**：`(参数) -> { 方法体 }`
2. **函数式接口**：只有一个抽象方法的接口
3. **方法引用**：`::` 操作符进一步简化代码
4. **与 Stream 结合**：过滤、映射、归约一气呵成

多写多用，Lambda 会成为你 Java 工具箱里的利器！
