---
title: 【Java 核心】类初始化时机与执行顺序深度解析：从 clinit 到父子类初始化陷阱
date: 2026-09-18 08:00:00
tags:
  - Java
  - JVM
  - 类加载
  - 面试
categories:
  - Java
  - Java基础
author: 东哥
---

# 【Java 核心】类初始化时机与执行顺序深度解析：从 clinit 到父子类初始化陷阱

## 面试官：这道题输出什么？

```java
class Parent {
    static { System.out.println("1 Parent static block"); }
    { System.out.println("2 Parent instance block"); }
    Parent() { System.out.println("3 Parent constructor"); }
}

class Child extends Parent {
    static { System.out.println("4 Child static block"); }
    { System.out.println("5 Child instance block"); }
    Child() { System.out.println("6 Child constructor"); }
}

public class Test {
    public static void main(String[] args) {
        new Child();
        new Child();
    }
}
```

能背出答案的人很多：`1 4 2 3 5 6 2 3 5 6`。但面试官接着问「**为什么静态块先执行父类的，而实例块先执行父类、构造器也是父类先**」「`<clinit>` 是干什么的」「什么情况下类**不会**被初始化」，能答完整的人就少了。

这篇文章把「类什么时候被初始化」和「初始化时谁先执行」这两个问题彻底拆开。

---

## 一、类的生命周期：七阶段

```text
加载 Loading
  → 验证 Verification
    → 准备 Preparation
      → 解析 Resolution
        → 初始化 Initialization
          → 使用 Using
            → 卸载 Unloading
```

其中「验证 / 准备 / 解析」统称 **连接（Linking）**。

各阶段的关键动作：

| 阶段 | 做什么 |
| --- | --- |
| 加载 | 通过类全限定名获取二进制字节流，生成 `Class` 对象 |
| 验证 | 文件格式、元数据、字节码、符号引用验证 |
| **准备** | 为**静态变量**分配内存并设置**零值**（不是代码里的初始值！） |
| 解析 | 符号引用 → 直接引用（可延迟到初始化后） |
| **初始化** | 执行类构造器 `<clinit>()`，真正赋上代码里的初始值 |

**准备阶段的坑**：

```java
public static int value = 123;                  // 准备阶段 value = 0
public static final int CONST = 123;            // 准备阶段直接就是 123（ConstantValue 属性）
public static final int COMPUTED = 1 + 2;       // 编译期常量折叠，也是 123
public static final String S = "hi";            // 字面量常量，准备阶段赋值
public static final Integer BOXED = 123;        // ⚠️ 不是编译期常量！准备阶段是 null
```

这就是经典面试题「`static final Integer` 与 `static final int` 的区别」——只有「基本类型或 String 的编译期常量」才会在准备阶段赋值。

---

## 二、`<clinit>()` 方法：初始化的执行体

`<clinit>()` 不是我们写的方法，是 **javac 自动生成的类初始化方法**。

生成规则：

1. **把所有静态变量的显式赋值语句和 `static {}` 块，按源码书写顺序收集起来**，合成 `<clinit>()`；
2. 如果类没有静态变量赋值也没有静态块，**不会生成** `<clinit>()`；
3. **接口不生成 `<clinit>()`**（除非有接口字段的赋值，那也只会生成用于字段赋值的最小逻辑，且接口初始化不要求父接口先初始化）；
4. `<clinit>()` **一定是线程安全的**：JVM 保证多线程同时初始化同一个类时只有一个线程执行，其他线程阻塞等待（这也是「静态内部类单例」线程安全的根源）。

反编译看真相：

```bash
javap -c -p Child.class
```

```text
static {};
  Code:
     0: getstatic     #7   // System.out
     3: ldc           #13  // String 4 Child static block
     5: invokevirtual #15  // println
     ...
```

顺序问题由此定案：**静态初始化的顺序就是源码顺序，写反了就会 NPE**：

```java
public class Order {
    static { b = 2; }              // 合法但不能读（非法前向引用限制）
    static int a = b + 1;          // b 已赋值，a = 3
    static int b = 1;              // 覆盖为 1
}
```

运行结果：`a = 3, b = 1`。因为 `static { b = 2; }` 先执行，再 `a = b + 1 = 3`，最后 `b = 1`。**这是合法的**（赋值可以前向引用），但「读」不行：

```java
static { System.out.println(a); }  // ❌ 编译错误：illegal forward reference
static int a = 1;
```

---

## 三、什么时候会触发初始化：主动引用的六种场景

JVM 规范定义了「有且仅有」这 6 种情况会触发初始化（首次主动引用）：

| # | 触发条件 | 示例 |
| --- | --- | --- |
| 1 | `new`、`getstatic`、`putstatic`、`invokestatic` 指令 | `new Child()`、`Child.staticField = 1`、`Child.staticMethod()` |
| 2 | 反射调用 | `Class.forName("com.Child")`、`Class.getMethod` 等 |
| 3 | 初始化子类时，先初始化父类 | `new Child()` 会先初始化 `Parent` |
| 4 | 虚拟机启动时的主类 | `java Test` 中的 `Test` |
| 5 | `MethodHandle` / `VarHandle` 解析 | `MethodHandles.lookup().findStatic(...)` |
| 6 | 默认方法所属接口的实现类初始化 | JDK 8 的 default method 场景 |

注意第 3 条是**递归向上**的：初始化子类 → 先初始化父类 → 再初始化父类的父类……

---

## 四、被动引用：这三种情况**不会**触发初始化

这是面试最爱挖的坑。

### 4.1 通过子类引用父类的静态字段

```java
class Parent { static int p = 10; static { System.out.println("Parent init"); } }
class Child extends Parent { static { System.out.println("Child init"); } }

public static void main(String[] args) {
    System.out.println(Child.p);
}
```

输出：`Parent init` / `10`。**`Child` 没有被初始化！** 因为 `Child.p` 编译后被优化成 `Parent.p`，只有定义该字段的类会被初始化。

### 4.2 通过数组定义引用类

```java
Parent[] arr = new Parent[10];
```

**不会初始化 `Parent`**。数组类型是 JVM 动态生成的 `[LParent;`，它由 `newarray` / `anewarray` 创建，只加载不初始化。

### 4.3 引用编译期常量

```java
class Const { static final String S = "hello"; static { System.out.println("Const init"); } }

public static void main(String[] args) {
    System.out.println(Const.S);
}
```

输出只有 `hello`。因为 `S` 是编译期常量，在**编译时就已经内联进调用类的常量池**，运行时根本没有 `getstatic Const.S` 这条指令。

**推论**：常量内联会导致一个非常现实的问题——**改了常量值，其它类不重新编译就不生效**。这也是很多「为什么我改成 1 了还是走 0 分支」事故的根源。

### 4.4 补充：`Class.forName` vs `ClassLoader.loadClass`

```java
Class.forName("com.Child");                    // 会初始化（默认 initialize=true）
ClassLoader.getSystemClassLoader().loadClass("com.Child");  // 只加载，不初始化
Class.forName("com.Child", false, cl);         // 只加载，不初始化
```

这个差异在 JDBC 驱动加载的历史里非常著名：老代码要写 `Class.forName("com.mysql.jdbc.Driver")` 才能注册驱动，因为驱动类的 `static {}` 块里有 `DriverManager.registerDriver`。

---

## 五、执行顺序：一张图看清

对于 `new Child()`，完整顺序是：

```text
1. 加载并验证 Parent、Child
2. Parent 准备（静态字段零值）
3. Parent <clinit> 执行 → 父类静态变量/静态块（源码顺序）
4. Child  准备
5. Child  <clinit> 执行 → 子类静态变量/静态块（源码顺序）
   —— 到此为止是「类初始化」，只做一次 ——
6. 分配实例对象内存，实例字段设为零值
7. 调用 Parent 构造器：
     a. 隐式/显式 super()（Object 构造器）
     b. Parent 实例变量显式赋值 + Parent 实例块（源码顺序）
     c. Parent 构造器方法体
8. 调用 Child 构造器：
     a. super() 已在第 7 步完成
     b. Child 实例变量显式赋值 + Child 实例块（源码顺序）
     c. Child 构造器方法体
```

**关键结论两条**：

1. **静态部分：父类全部先于子类**（因为 `<clinit>` 执行前 JVM 保证父类已初始化）；
2. **实例部分：父类的「实例变量赋值 + 实例块 + 构造器」整体先于子类的对应部分**（因为子类构造器第一行是 `super()`）。

所以回到开头那道题，两次 `new Child()` 的输出是：

```text
1 Parent static block     ← 只在第一次 new Child() 里出现
4 Child static block      ← 同样只有一次
2 Parent instance block
3 Parent constructor
5 Child instance block
6 Child constructor
2 Parent instance block
3 Parent constructor
5 Child instance block
6 Child constructor
```

---

## 六、写代码时最容易踩的 5 个坑

### 坑 1：构造器里调用被子类 Override 的方法

```java
class Parent {
    Parent() { print(); }          // 危险！
    void print() { System.out.println("parent"); }
}
class Child extends Parent {
    private final int x = 42;
    @Override void print() { System.out.println("child " + x); }
}
```

`new Child()` 输出 `child 0`。因为 `Parent` 构造器执行时，`Child` 的实例变量还没赋值（`x` 还是零值）。**构造器里调用可覆写方法是反模式**，框架里（如 Spring 的 `@PostConstruct` 之外的初始化）也常因此出 bug。

### 坑 2：静态字段初始化顺序依赖

```java
class Config {
    static final Map<String, Integer> MAP = new HashMap<>();
    static { MAP.put("a", 1); }     // 顺序正确
}
```

如果 `static {}` 写在 `MAP` 声明之前 → `NullPointerException`（`MAP` 还是 null）。

### 坑 3：`<clinit>` 死锁

类初始化持有「初始化锁」，如果两个类的 `<clinit>` 互相引用，就会出现多线程死锁：

```java
class A { static { new B(); } }
class B { static { new A(); } }
```

单线程下这是合法的（递归初始化是允许的），但多线程下（线程 T1 初始化 A、T2 初始化 B）就会死锁。`jstack` 里能看到 `WAITING` 在线程状态为 `in Object.wait()` / `Initializing` 的堆栈上。

实测最真实的案例是 **数据库驱动的静态注册 + 类加载器顺序**、**Log4j 初始化 + 配置类互相引用**。

### 坑 4：依赖常量内联导致的热更新失效

前面提过：`static final` 常量（基本类型 / String 字面量）会被编译期内联，改常量值后依赖方必须重新编译。

```java
// 模块 A
public static final int TIMEOUT = 3000;
// 模块 B（编译时已内联 3000）
if (t > A.TIMEOUT) { ... }
```

改成 `5000` 后如果 B 的 class 没重新编译，仍然是 3000。**推论：不要用 `public static final` 常量做「可配置项」**，要用配置文件或 `static` 非 final 字段。

### 坑 5：接口字段的初始化时机

```java
interface I {
    int X = new Random().nextInt();   // 编译报错？不，是被禁止的（非确定值）
    // 接口字段必须是 public static final，且必须初始化
}
```

接口字段默认 `public static final`。接口的初始化不会因为子类/实现类被初始化而触发，只有 **主动读取接口字段** 时才触发。

一个反直觉结论：

```java
class C implements I { static { System.out.println("C init"); } }
interface I { static { System.out.println("I init"); } }  // 语法不合法！

// 接口只能这样「初始化」：
interface I { int X = compute(); static int compute() { System.out.println("I init"); return 1; } }
```

---

## 七、两个面试题实战解析

### 题 1

```java
public class Singleton {
    private static Singleton instance = new Singleton();
    public static int counter1;
    public static int counter2 = 0;

    private Singleton() {
        counter1++;
        counter2++;
    }
    public static Singleton getInstance() { return instance; }

    public static void main(String[] args) {
        Singleton s = Singleton.getInstance();
        System.out.println(s.counter1);
        System.out.println(s.counter2);
    }
}
```

输出：`1` 和 `0`。

解析：`<clinit>` 顺序为 —— `instance = new Singleton()` 触发构造器，此时 `counter1`、`counter2` 还是准备阶段的零值 0，构造器执行后变成 1、1；随后 `<clinit>` 继续执行 `counter2 = 0`，把 `counter2` **覆盖回 0**。所以最终 `counter1=1, counter2=0`。

这个题完美演示了「**实例构造与静态赋值混在一起时的顺序陷阱**」。

### 题 2

```java
public class Test {
    public static void main(String[] args) {
        System.out.println(B.a);
        System.out.println(B.b);
    }
}
class A {
    static { System.out.println("A static"); }
    static int a = 1;
}
class B extends A {
    static { System.out.println("B static"); }
    static int b = 2;
}
```

输出：

```text
A static
1
B static
2
```

解析：`B.a` 实际是 `A.a`，只初始化 `A`；之后访问 `B.b` 时才初始化 `B`（并因第 3 条先确保 `A` 已初始化，但 `A` 已完成，不重复）。

---

## 八、面试追问合集

**Q1：`<clinit>` 与 `<init>` 有什么区别？**
`<clinit>` 是类初始化方法（静态），由 javac 收集静态赋值与静态块生成，JVM 保证线程安全且只执行一次；`<init>` 是实例构造器（对应字节码 `invokespecial <init>`），每次 `new` 都执行。`<clinit>` 不能被显式调用，也不能被继承。

**Q2：类初始化能被中断吗？**
`<clinit>` 执行中抛出的异常会被包装成 `ExceptionInInitializerError` 抛给调用方，并且**该类会被标记为「初始化失败」**，后续任何再次触发初始化的调用都会抛 `NoClassDefFoundError`（而不是再执行一次）。这是排查「莫名其妙 NoClassDefFoundError」的关键线索。

**Q3：静态内部类为什么能实现懒加载单例？**
因为「初始化类的 6 种主动引用」里不包含「外部类访问内部类」——只有真正调用 `Holder.INSTANCE` 时才触发 `Holder` 初始化，而 `<clinit>` 线程安全，天然保证单例。

**Q4：双重检查锁为什么要 `volatile`？**
`instance = new Singleton()` 不是原子操作（分配、初始化、赋值三步），可能重排序导致别的线程看到「非 null 但未初始化」的对象，`volatile` 禁止该重排序。

**Q5：类什么时候被卸载？**
满足三个条件才会卸载：该类的所有实例已回收、`ClassLoader` 已回收、对应的 `Class` 对象无引用。这也是热部署 / OSGi / Tomcat 重复部署内存泄漏的根源——只要有一个静态引用挂住 `ClassLoader`，类就永远卸载不掉。

---

## 九、总结

| 问题 | 答案 |
| --- | --- |
| 静态与实例的顺序 | 静态：父类 → 子类；实例：父类（实例块+构造器）→ 子类 |
| 初始化触发时机 | 6 种主动引用；被动引用（子类引父类静态字段、数组、编译期常量）不触发 |
| 常量内联 | `static final` 基本类型/String 字面量会被内联，改值需重新编译依赖方 |
| 线程安全 | `<clinit>` 由 JVM 加锁，天然线程安全，但可能死锁 |
| 失败的后果 | `ExceptionInInitializerError` + 后续 `NoClassDefFoundError` |

一句话收尾：**「类初始化」是一次性的静态过程，「实例初始化」是每次 `new` 都重演的动态过程；把这两条线分开记，所有输出顺序题都会变成送分题。**
