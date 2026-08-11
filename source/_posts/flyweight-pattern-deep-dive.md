---
title: 【设计模式】享元模式深度解析：从 Integer 缓存到线程池的共享之道
date: 2026-08-11 10:00:00
tags:
  - Java
  - 设计模式
  - 享元模式
categories:
  - 设计模式
  - Java
author: 东哥
---

# 【设计模式】享元模式深度解析：从 Integer 缓存到线程池的共享之道

## 面试官：String、Integer 缓存、线程池、连接池，它们背后是同一个设计模式？

很多人在 JDK 里"见过"享元模式却认不出来：`Integer.valueOf(127)` 返回的是同一个对象、字符串常量池复用、线程池复用线程、连接池复用连接……这些全是**享元模式（Flyweight Pattern）**在不同层面的落地。

本文讲透享元模式的核心思想、内部状态与外部状态、源码案例，并带一个完整的实战示例，最后说清楚它和单例、对象池的区别。

<!-- more -->

## 一、享元模式是什么

享元模式：**通过共享技术有效支持大量细粒度对象的复用**。核心思想是：如果一个对象可以被多个场景共用，并且只需要区分"外部状态"，那就把对象池化，避免重复创建。

它的本质是"**对象级别的缓存**"，解决的问题是：**大量相似对象导致的内存浪费与创建开销**。

### 内部状态 vs 外部状态（最重要的概念）

| 维度 | 内部状态（Intrinsic） | 外部状态（Extrinsic） |
| --- | --- | --- |
| 定义 | 对象固有的、可共享的属性 | 随使用场景变化的属性 |
| 存放位置 | 存储在享元对象内部，创建后不变 | 由客户端持有，调用时传入 |
| 是否共享 | 共享 | 不共享 |
| 示例 | 棋子的"颜色"、字符的"字形" | 棋子的"坐标"、字符的"字号" |

**判断是否适合享元模式的标准**：能否把对象的属性拆成"不变的共享部分 + 变化的外部部分"。能拆，就有享元的空间。

## 二、经典结构

```
FlyweightFactory（享元工厂：维护池，getFlyweight 时复用或创建）
    │
    ▼
Flyweight（抽象享元：定义接口，接收外部状态）
    ▲
    │
ConcreteFlyweight（具体享元：持有内部状态，实现接口）
    ▲
    │
Client（客户端：创建/获取享元，传递外部状态）
```

```java
// 抽象享元
public interface ChessPiece {
    void display(int x, int y);   // x, y 是外部状态，调用时传入
}

// 具体享元：只持有内部状态（颜色）
public class ConcreteChessPiece implements ChessPiece {
    private final String color;   // 内部状态：黑/白，创建后不变

    public ConcreteChessPiece(String color) { this.color = color; }

    @Override
    public void display(int x, int y) {
        System.out.println(color + "棋子在 (" + x + ", " + y + ")");
    }
}

// 享元工厂
public class ChessPieceFactory {
    private static final Map<String, ChessPiece> POOL = new ConcurrentHashMap<>();

    public static ChessPiece get(String color) {
        // 池中已有则复用，没有才创建
        return POOL.computeIfAbsent(color, ConcreteChessPiece::new);
    }
}
```

一局象棋有 32 个棋子，但只有 2 种颜色——享元模式下只需创建 2 个对象，坐标作为外部状态传入。这就是"内存占用从 O(棋子数) 降到 O(种类数)"的魔力。

## 三、JDK 源码里的享元模式

### 3.1 Integer 缓存（最经典的例子）

```java
public static Integer valueOf(int i) {
    if (i >= IntegerCache.low && i <= IntegerCache.high)
        return IntegerCache.cache[i + (-IntegerCache.low)];  // 命中缓存，复用对象
    return new Integer(i);
}
```

`IntegerCache` 默认缓存 `-128 ~ 127`（`-XX:AutoBoxCacheSize` 可调上限）。所以：

```java
Integer a = 100, b = 100;
System.out.println(a == b);   // true，同一对象

Integer c = 200, d = 200;
System.out.println(c == d);   // false，超出缓存范围，各自 new
```

**面试必问**：为什么是 -128~127？因为这是 JLS 规范约定的范围（`IntegerCache.high` 默认 127），`valueOf` 对范围内的值必须返回缓存对象，保证 `==` 语义一致。

### 3.2 字符串常量池

```java
String s1 = "hello";        // 入常量池
String s2 = "hello";        // 直接复用池中对象
String s3 = new String("hello");  // 堆上新对象，但字面量仍进池
System.out.println(s1 == s2);     // true
System.out.println(s1 == s3);     // false
```

JVM 用 StringTable 维护字符串常量池，相同的字面量只存一份——大量重复字符串（如日志级别、状态码）被共享，极大节省内存。

### 3.3 线程池 / 连接池

```java
ExecutorService pool = Executors.newFixedThreadPool(10);
pool.execute(task);   // 复用池中线程，而非每次 new Thread()
```

线程池复用的是"线程对象"，避免线程创建/销毁的昂贵开销；数据库连接池、HTTP 连接池同理——**池化是享元思想在资源管理上的应用**。

### 3.4 Boolean、Byte、Character 缓存

- `Boolean.TRUE / FALSE`：只有两个实例；
- `Byte` 全部缓存；
- `Character` 缓存 `\u0000 ~ \u007F`（ASCII 范围）。

## 四、实战：游戏中的子弹特效池

场景：射击游戏里大量子弹特效对象，每个都有位置、方向等**变化属性**，但纹理、音效等资源是**共享的**。用享元模式避免每发子弹都加载一份资源。

```java
// 外部状态：每颗子弹独立的运动数据
public class BulletState {
    private float x, y, vx, vy;
    private boolean alive = true;
    // getter / setter 省略
}

// 享元：共享的资源与行为模板
public class BulletFlyweight {
    private final String texturePath;   // 内部状态：共享纹理
    private final int damage;           // 内部状态：共享属性

    public BulletFlyweight(String texturePath, int damage) {
        this.texturePath = texturePath;
        this.damage = damage;
    }

    public void fire(BulletState state) {
        // 使用外部状态推进子弹
        while (state.isAlive()) {
            state.setX(state.getX() + state.getVx());
            state.setY(state.getY() + state.getVy());
            // 渲染时使用共享纹理
        }
    }
}

public class BulletFlyweightFactory {
    private static final Map<String, BulletFlyweight> POOL = new HashMap<>();

    public static BulletFlyweight get(String texturePath, int damage) {
        String key = texturePath + "#" + damage;
        return POOL.computeIfAbsent(key, k -> new BulletFlyweight(texturePath, damage));
    }
}
```

效果：10000 颗子弹只创建几种纹理的享元对象，配合对象池复用 `BulletState`，内存和 GC 压力大幅下降。

## 五、享元 vs 单例 vs 对象池

| 模式 | 核心 | 数量 | 典型场景 |
| --- | --- | --- | --- |
| 单例模式 | 全局唯一 | 1 个 | 配置管理器、Logger |
| 享元模式 | 按内部状态共享 | 每个内部状态 1 个（有限多个） | Integer 缓存、字符渲染 |
| 对象池 | 复用+回收 | 有上限的 N 个 | 线程池、连接池 |

三者区别一句话：**单例管"只有一个"，享元管"同类的只存一份"，对象池管"用完还回来继续用"**。线程池其实同时体现了享元（线程对象共享）和对象池（任务队列回收复用）的思想。

## 六、享元模式的优缺点与适用场景

### 优点
- 大幅减少对象数量，降低内存占用与 GC 压力；
- 重复对象的创建开销被摊薄；
- 内部状态集中管理。

### 缺点
- 需要拆分内/外部状态，增加了设计复杂度；
- 外部状态由客户端维护，容易引入并发安全问题（**享元对象必须线程安全，因为它被多线程共享**）；
- 池的管理本身有成本，对象种类极多时池反而浪费。

### 适用场景
1. 系统中存在大量相似对象；
2. 对象可以拆分内部/外部状态；
3. 对象创建成本高（资源加载、网络连接、线程）；
4. 缓存池容量可控（Integer 缓存、线程池、连接池）。

## 七、面试常见追问

**Q1：享元模式在 String 上的应用，new String("a") 和 "a" 有什么区别？**
字面量 `"a"` 直接复用常量池对象；`new String("a")` 会在堆上新建对象（但字面量本身仍入池）。`intern()` 方法可以主动把堆上字符串加入常量池并返回池中引用。

**Q2：享元对象如何保证线程安全？**
享元对象的内部状态创建后不可变（用 `final`），可变的部分全部外置为外部状态由调用方持有；工厂本身用 `ConcurrentHashMap` + `computeIfAbsent` 保证并发获取安全。

**Q3：Integer 缓存能改吗？**
可以，`-XX:AutoBoxCacheSize=256` 可扩大缓存上限（JVM 参数），但业务代码不应该依赖 `==` 比较 Integer，永远用 `equals`。

**Q4：什么时候不该用享元模式？**
对象种类很多且各自独有属性占大头、外部状态复杂到难以剥离、池化收益小于维护成本（如对象很小且创建廉价）时，不要硬套享元。

## 总结

享元模式是"**用空间换时间**"与"**用共享换内存**"的经典平衡：把对象拆成可共享的内部状态和可变化的的外部状态，用工厂统一管理池。它藏在 Integer 缓存、String 常量池、线程池、连接池、字符渲染引擎等无数底层实现里——识别它、说清它、用对它，是 Java 面试和系统设计都绕不开的基本功。
