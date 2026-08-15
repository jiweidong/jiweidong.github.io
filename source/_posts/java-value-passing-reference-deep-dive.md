---
title: 【面试必备】Java 到底是值传递还是引用传递？从 JVM 栈帧到方法调用的深度解析
date: 2026-08-14 08:00:00
tags:
  - Java
  - 基础
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】Java 到底是值传递还是引用传递？从 JVM 栈帧到方法调用的深度解析

## 面试官：Java 方法参数到底是值传递还是引用传递？

这是 Java 面试中出现频率最高的基础题之一，几乎每家公司的笔试或一面都会问。很多同学背过答案——"Java 只有值传递"——但一旦面试官追问"那为什么 `swap` 函数交换不了两个对象？为什么传引用对象进去方法里改了属性外面能看到？"，立刻就露馅了。

本文从 JVM 栈帧、堆内存布局、引用语义三个层面彻底讲透这个问题，让面试官无可追问。

---

## 一、结论先行：Java 只有值传递

先说结论：

> **Java 中方法参数的传递方式只有一种——值传递（pass by value）。**
>
> - 基本类型：传递的是**值的副本**
> - 引用类型：传递的是**引用（地址）的副本**

也就是说，方法内拿到的永远是一个"拷贝"，方法内对参数本身的重新赋值（`param = xxx`），**绝对不会**影响调用方的变量。但注意，如果参数是引用类型，通过这个引用的副本去修改对象内部状态（`param.setXxx()`），是能影响原对象的——因为两个引用指向同一个堆对象。

这个"引用副本 + 共享堆对象"的组合，正是无数人混淆"值传递"与"引用传递"的根源。

---

## 二、从 JVM 栈帧看本质

要真正理解值传递，必须理解方法调用时 JVM 做了什么。

### 2.1 栈帧与局部变量表

JVM 中每个方法调用都会创建一个**栈帧（Stack Frame）**，栈帧里有：

- **局部变量表（Local Variable Table）**：以槽（Slot）为单位，存放方法参数和局部变量
- **操作数栈（Operand Stack）**
- **动态链接、返回地址**等

当调用 `add(a, b)` 时，JVM 把实参的值 **拷贝** 到被调用方法栈帧的局部变量表中：

```
调用方栈帧                        被调用方栈帧
+------------------+             +------------------+
| a = 1            |  ──拷贝──>  | a' = 1 (槽0)     |
| b = 2            |  ──拷贝──>  | b' = 2 (槽1)     |
+------------------+             +------------------+
```

对于基本类型，拷贝的是数值本身；对于引用类型，拷贝的是**引用值（堆地址）**。两者都是"值"，区别只在于这个值代表什么。

### 2.2 图解：引用类型的传递

```java
public class Demo {
    public static void main(String[] args) {
        User user = new User("张三", 25);
        modify(user);                    // ①
        System.out.println(user.getName()); // 输出什么？
    }

    public static void modify(User u) {
        u.setName("李四");   // ② 通过引用副本修改堆对象
        u = new User("王五", 30); // ③ 重新赋值，只改变局部变量 u
    }
}
```

内存视角：

```
堆：
  User@0x100 "张三"  ──── 修改后 "李四"
  User@0x200 "王五"  （③ 新创建，方法结束后无引用，被 GC）

栈：
  main 栈帧:  user = 0x100
  modify 栈帧: u    = 0x100 ──→ ② 通过 0x100 改了堆对象
                    ③ 后 u = 0x200（不影响 main 里的 user）
```

所以 `main` 里最终输出 **"李四"**，而不是"王五"。这就是"引用副本能改对象内容，但不能换掉调用方的引用"。

---

## 三、经典代码验证

### 3.1 swap 交换不了基本类型

```java
public static void swap(int a, int b) {
    int tmp = a;
    a = b;
    b = tmp;
}

public static void main(String[] args) {
    int x = 1, y = 2;
    swap(x, y);
    System.out.println(x + ", " + y); // 输出 1, 2，交换失败
}
```

原因：`swap` 里交换的是局部变量表中 `a`、`b` 的拷贝，`main` 里的 `x`、`y` 毫发无损。

### 3.2 引用类型也交换不了

```java
public static void swap(User a, User b) {
    User tmp = a;
    a = b;
    b = tmp;   // 只是交换了栈帧里的两个引用副本
}

public static void main(String[] args) {
    User u1 = new User("张三");
    User u2 = new User("李四");
    swap(u1, u2);
    // u1 还是张三，u2 还是李四
}
```

同理，`swap` 只是把两个"引用副本"互换，堆上对象和调用方的引用变量都没变。

### 3.3 但修改对象内部是有效的

```java
public static void fill(User u) {
    u.setAge(30);          // 通过引用副本访问同一堆对象
    u.getList().add("x");  // 修改对象内部持有的引用（List 内部数组）
}
```

调用方能看到 `age == 30`、list 里有 `"x"`。这是因为引用副本 `u` 和调用方的 `user` 指向**同一个堆对象**，修改的是对象内部状态，而不是参数本身。

### 3.4 常见误区的反面例证

```java
public static void change(String s) {
    s = "world";  // String 不可变 + 重新赋值，外面不受影响
}
String str = "hello";
change(str);
System.out.println(str); // 仍是 hello
```

有人拿这个例子说"String 特殊，是值传递"，**这是错的**。任何引用类型参数重新赋值都影响不了外面，String 只是因为不可变让"修改内部"这条路也走不通而已。同理，`Integer`、`Long` 等包装类型也一样。

---

## 四、C/C++ 对比：什么是真正的引用传递

为了加深理解，看看 C++ 的引用传递：

```cpp
void swap(int &a, int &b) {   // 引用参数：操作的是实参本身
    int tmp = a;
    a = b;
    b = tmp;
}
int x = 1, y = 2;
swap(x, y);  // x=2, y=1，真的交换了
```

C++ 的 `&` 引用是实参的**别名**，方法内对参数的操作就是对实参的操作。而 Java 没有这种机制——Java 的引用变量本质上是指针的封装，传参时传递的是指针值（地址值）的副本。这就是"Java 只有值传递"的最硬核证据。

---

## 五、面试官追问环节

### Q1：数组传参是值传递还是引用传递？

数组也是引用类型，传递的是数组引用（首地址）的副本。所以：

```java
public static void fill(int[] arr) {
    arr[0] = 100;   // 有效！改的是同一个数组对象
    arr = new int[3]; // 无效！只是局部变量重新指向新数组
}
```

### Q2：那为什么经常有人说 Java 是引用传递？

因为他们混淆了"传递引用变量的值"和"引用传递"。准确的说法是：

- **按值传递（pass by value）**：方法得到的是实参的副本
- **按引用传递（pass by reference）**：方法直接操作实参本身（别名）

Java 传递引用类型时，传递的是"引用值"，本质仍是按值传递。判断标准只有一个：**方法内对参数重新赋值，能否影响调用方的变量。** 显然不能——所以是值传递。

### Q3：引用副本到底是什么？占多少内存？

引用副本就是栈帧局部变量表中的一个 Slot（32 位 JVM 占 4 字节，64 位 JVM 开启压缩指针后也占 4 字节，未压缩占 8 字节），存的是堆对象的地址。它和调用方的引用变量是两个独立的存储位置，只是存的值（地址）相同。

### Q4：和 Go、Python 对比呢？

- **Go**：切片、map、channel 等引用类型传参时传递的是引用值的副本，语义与 Java 类似
- **Python**：官方术语是"对象引用传递"（pass-by-object-reference），实参是对象的引用副本，行为与 Java 高度一致——改对象内部有效，重新赋值无效

---

## 六、生产实践中的避坑点

### 6.1 不要在方法内修改入参集合

```java
// 反例：悄悄污染了调用方的 list
public void process(List<String> list) {
    list.removeIf(s -> s.startsWith("temp"));  // 调用方数据被改
}

// 正例：防御性拷贝
public void process(List<String> list) {
    List<String> copy = new ArrayList<>(list);
    copy.removeIf(s -> s.startsWith("temp"));
}
```

### 6.2 返回引用时的泄露风险

```java
private List<String> cache = new ArrayList<>();

// 反例：调用方拿到内部引用，可以随意修改缓存
public List<String> getCache() {
    return cache;
}

// 正例：返回不可变视图或副本
public List<String> getCache() {
    return Collections.unmodifiableList(cache);
}
```

### 6.3 警惕"改了没生效"的经典 Bug

```java
// 错误：以为传引用就能给调用方的对象赋值
public void init(User user) {
    user = new User("初始化后的用户");  // 外面拿到的还是 null！
}

// 正确：要么返回新对象，要么修改入参内部
public User init(User user) {
    return user == null ? new User("初始化后的用户") : user;
}
```

---

## 七、总结

| 问题 | 结论 |
|------|------|
| Java 的传参方式 | 只有值传递 |
| 基本类型传参 | 传递数值副本，方法内修改不影响实参 |
| 引用类型传参 | 传递引用值（地址）副本，重新赋值不影响实参 |
| 引用类型修改内部状态 | 有效，因为副本与实参指向同一堆对象 |
| 判断标准 | 方法内对参数重新赋值能否影响调用方变量 |

**一句话背下来：Java 传的是"引用的值"，不是"引用传递"；方法内换不了调用方的引用，但可以改共享对象的内容。**

面试时能说出"JVM 栈帧局部变量表拷贝 + 堆对象共享"这个层面的解释，就足够把这道送分题变成加分题了。
