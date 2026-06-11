---
title: Java Stream API 实战指南
date: 2026-06-08 23:22:00
tags: [Java, Stream]
categories: Java
---

## 什么是 Stream？

Stream 是 Java 8 引入的函数式编程概念，它提供了一种高效、声明式的数据处理方式。

## 常用操作

### 1. 创建 Stream

```java
// 从集合创建
List<String> list = Arrays.asList("a", "b", "c");
Stream<String> stream = list.stream();

// 从数组创建
Stream<Integer> stream2 = Arrays.stream(new Integer[]{1, 2, 3});

// 使用 Stream.of
Stream<String> stream3 = Stream.of("x", "y", "z");
```

### 2. 中间操作

```java
// filter - 过滤
list.stream().filter(s -> s.startsWith("a"));

// map - 映射
list.stream().map(String::toUpperCase);

// sorted - 排序
list.stream().sorted();

// distinct - 去重
list.stream().distinct();
```

### 3. 终端操作

```java
// forEach - 遍历
list.stream().forEach(System.out::println);

// collect - 收集为集合
List<String> result = list.stream()
    .filter(s -> s.length() > 2)
    .collect(Collectors.toList());

// count - 计数
long count = list.stream().count();

// reduce - 归约
Optional<String> concat = list.stream()
    .reduce((a, b) -> a + "," + b);
```

## 实战案例

### 分组统计

```java
Map<Integer, List<User>> groupByAge = users.stream()
    .collect(Collectors.groupingBy(User::getAge));
```

### 多字段排序

```java
list.stream()
    .sorted(Comparator.comparing(User::getAge)
        .thenComparing(User::getName))
    .collect(Collectors.toList());
```

Stream API 能大幅简化集合操作，让代码更简洁、更具可读性。用好 Stream，写 Java 更有底气。
