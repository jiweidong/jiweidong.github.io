---
title: 【Java 基础】重载 vs 重写深度解析：从语法规则到 JVM 方法分派机制
date: 2026-08-23 08:00:00
tags:
  - Java
  - 重载
  - 重写
  - JVM
  - 面试
categories:
  - Java
  - Java基础
author: 东哥
---

# 【Java 基础】重载 vs 重写深度解析：从语法规则到 JVM 方法分派机制

## 面试官：重载（Overload）和重写（Override）有什么区别？

> 这道题几乎是 Java 面试的"开胃菜"，但大多数人的答案停留在"参数列表不同 vs 方法签名相同"的语法层面。真正拉开差距的是追问：**JVM 如何决定调用哪个重载方法？多态调用在字节码层面怎么实现？** 本文带你从语法规则一路挖到 JVM 方法分派机制。

## 一、语法规则：先分清"是什么"

### 1.1 重载（Overload）：同一个类中方法名相同，参数列表不同

```java
public class Calculator {
    public int add(int a, int b) {
        return a + b;
    }

    public double add(double a, double b) {   // ✅ 参数类型不同
        return a + b;
    }

    public int add(int a, int b, int c) {      // ✅ 参数个数不同
        return a + b + c;
    }

    // ❌ 编译错误：只改返回值类型不构成重载
    // public long add(int a, int b) { return a + b; }
}
```

**重载的判断标准**：
- 方法名**相同**；
- 参数列表**不同**（个数、类型、顺序任一不同）；
- **返回值类型、访问修饰符、异常声明与重载无关**；
- 发生在**同一个类**中（也包括继承场景下父类方法在子类中的重载，如 `Object` 的 `equals(Object)` 和自定义的 `equals(String)`）。

### 1.2 重写（Override）：子类重新实现父类方法

```java
class Animal {
    public void speak() {
        System.out.println("动物叫");
    }
}

class Dog extends Animal {
    @Override
    public void speak() {   // ✅ 方法签名与父类完全一致
        System.out.println("汪汪汪");
    }
}
```

**重写的判断标准**：
- 方法签名（方法名 + 参数列表）与父类**完全一致**；
- 返回值类型可以相同，或为父类返回值类型的**子类型**（**协变返回类型**，JDK 5+）；
- 访问修饰符**不能比父类更严格**（父类 `protected`，子类不能 `private`）；
- 抛出的受检异常**不能比父类更宽**（父类抛 `IOException`，子类可以抛 `FileNotFoundException` 或更少）；
- 只能重写**非 private、非 static、非 final** 的方法；
- `@Override` 注解不是必须的，但推荐加——编译器会帮你校验签名。

### 1.3 一个最容易混淆的坑

```java
class Parent {
    public void print(String s) {
        System.out.println("Parent: " + s);
    }
}

class Child extends Parent {
    // 这是重载不是重写！参数列表不同（Object vs String）
    public void print(Object o) {
        System.out.println("Child: " + o);
    }

    @Override
    public void print(String s) {  // 这才是重写
        System.out.println("Child-Override: " + s);
    }
}
```

判断技巧：**看方法签名（名 + 参数）是否与父类方法完全一致**。一致是重写，不一致是重载（即使方法名相同）。

## 二、JVM 方法分派：字节码层面的真相

面试官追问：**调用一个方法时，JVM 怎么知道调用哪个？** 这就要讲到 JVM 的方法调用指令和分派机制了。

### 2.1 四种方法调用指令

| 指令 | 作用 | 分派方式 |
|---|---|---|
| `invokestatic` | 调用静态方法 | 静态分派（编译期确定） |
| `invokespecial` | 调用构造方法、private 方法、super 方法 | 静态分派 |
| `invokevirtual` | 调用实例方法（非 private） | **动态分派**（运行时确定） |
| `invokeinterface` | 调用接口方法 | **动态分派**（运行时确定） |
| `invokedynamic` | JDK 7+，Lambda/字符串拼接等 | 动态分派（更灵活） |

### 2.2 重载是静态分派：编译期就定好了

```java
public class Dispatch {
    static class Animal {}
    static class Dog extends Animal {}

    public void choose(Animal a) { System.out.println("animal"); }
    public void choose(Dog d) { System.out.println("dog"); }

    public static void main(String[] args) {
        Dispatch d = new Dispatch();
        Animal a = new Dog();
        d.choose(a);   // 输出：animal！
    }
}
```

为什么 `a` 的实际类型是 `Dog`，却调用了 `choose(Animal)`？

因为**重载方法的选择发生在编译期**，编译器看到的是变量的**静态类型**（`Animal`），所以选择参数类型为 `Animal` 的重载版本。这被称为**静态分派（Static Dispatch）**。

反编译看字节码：

```java
invokevirtual #7  // Method choose:(Lcom/example/Dispatch$Animal;)V
```

指令中**已经写死了 `Animal` 参数类型**的方法引用，编译期完成绑定。

### 2.3 重写是动态分派：运行时看实际类型

```java
Animal a = new Dog();
a.speak();   // 输出：汪汪汪（调用的是 Dog 的 speak）
```

`invokevirtual` 指令在**运行时**解析：JVM 根据**栈顶对象的实际类型**（`Dog`）查找方法。查找过程：

1. 在**实际类型的方法表**中查找与"方法名 + 描述符"匹配的方法；
2. 找到则调用；找不到则沿**继承链向上**查找；
3. 都没找到抛 `AbstractMethodError`。

这就是**动态分派（Dynamic Dispatch）**，也是**多态**的底层实现。

### 2.4 方法表（Method Table）与虚方法

JVM 在类加载的**连接阶段（解析）**会为类建立**方法表**（vtable / itable），表中每个**虚方法**（可被重写的方法）对应一个偏移量。`invokevirtual` 通过 `对象引用 + 方法表偏移量` 直接定位：

```
Dog 的方法表（简化）：
[0] toString()        → Object.toString
[1] hashCode()        → Object.hashCode
[2] equals(Object)    → Object.equals
[3] speak()           → Dog.speak        ← 覆盖了 Animal 的入口
[4] bark()            → Dog.bark
```

方法表本质是**空间换时间**的优化：不用每次调用都做字符串匹配查找，而是常数时间通过索引定位。子类重写父类方法时，**入口在方法表中的位置与父类保持一致**，只是指向的实现不同——这正是动态绑定的核心。

> 补充：`final` 方法和 `private` 方法不进虚方法表，因为它们不可能被重写；`static` 方法也不参与动态分派。

### 2.5 一个经典的"重载 + 重写"混合面试题

```java
class A {
    public void show(A a) { System.out.println("A.show(A)"); }
    public void show(D d) { System.out.println("A.show(D)"); }
}

class B extends A {
    public void show(B b) { System.out.println("B.show(B)"); }   // 重载
    @Override
    public void show(A a) { System.out.println("B.show(A)"); }   // 重写
}

class D extends B {}

public static void main(String[] args) {
    A a1 = new A(); A a2 = new B(); B b = new B(); D d = new D();
    a1.show(b);   // ①
    a2.show(d);   // ②
    b.show(d);    // ③
}
```

输出：① `A.show(A)` ② `B.show(A)` ③ `B.show(B)`

解析：
- **①**：编译期按静态类型 `A` + 参数静态类型 `B` 选择 `show(A)`（B 是 A 的子类，最匹配 A 版本）；运行期 a1 实际类型是 A，调用 A 的实现 → `A.show(A)`。
- **②**：编译期 `a2` 静态类型是 A，参数 `d` 静态类型是 D，选择 `show(A)`；运行期 a2 实际类型是 B，B 重写了 `show(A)` → `B.show(A)`。
- **③**：编译期 `b` 静态类型是 B，`B` 类中有 `show(B)`（重载）最匹配参数 D → 选 `show(B)`；运行期 B 未重写它 → `B.show(B)`。

**口诀**："重载看静态类型（编译期），重写看实际类型（运行期）"。

## 三、深入追问：几个魔鬼细节

### 3.1 协变返回类型（Covariant Return Type）

```java
class Animal {
    public Animal clone() { ... }
}
class Dog extends Animal {
    @Override
    public Dog clone() { ... }   // ✅ JDK 5+ 允许返回子类型
}
```

底层原理：编译器在 `Dog` 中生成一个**桥方法（Bridge Method）**返回 `Animal`，内部调用返回 `Dog` 的方法，保持方法表签名一致。

### 3.2 重载时 null 的歧义

```java
public void test(String s) {}
public void test(Integer i) {}

test(null);  // ❌ 编译错误：ambiguous，编译器无法确定选择哪个
```

`null` 同时是 `String` 和 `Integer` 的子类型，编译器无法比较两者优先级。但如果有 `Object` 重载版本，`test(null)` 会选择最具体的 `String`/`Integer` 版本。

### 3.3 重载与可变参数（varargs）

```java
public void go(int... args) {}
public void go(int a, int... args) {}

go();       // 选 int... 版本（更精确匹配空参数）
go(1);      // 选 int, int... 版本（固定参数优先于可变参数）
```

**固定参数优先级 > 可变参数**，这是编译器的重载解析规则。

### 3.4 `@Override` 的编译器守护

不加 `@Override` 时，想重写却写错了参数（变成重载），编译器不报错，程序行为与预期不符：

```java
class Cat extends Animal {
    // 本意是重写 speak()，结果拼错签名变成重载
    public void speak(String s) { ... }
}

Animal c = new Cat();
c.speak();   // 调用的还是父类的 speak()，猫不会叫了 🐱
```

加了 `@Override` 编译器直接报错，把问题拦截在编译期。**生产代码必须加**。

## 四、重载重写 vs 其他语言机制

| 维度 | 重载 Overload | 重写 Override |
|---|---|---|
| 发生位置 | 同一个类（含继承中的新方法） | 子类重写父类方法 |
| 方法签名 | 参数列表不同 | 参数列表完全一致 |
| 绑定时机 | **编译期**（静态分派） | **运行期**（动态分派） |
| JVM 指令 | `invokevirtual` 编译期定引用 | `invokevirtual` 运行期查方法表 |
| 目的 | 扩展同名的便利方法 | 多态：同一调用，不同行为 |
| 返回值 | 无关 | 可协变 |
| 修饰符 | 无关 | 不能更严格 |
| 典型场景 | 构造器重载、`println` 全家桶 | 模板方法模式、策略模式、框架扩展点 |

## 五、生产实践建议

1. **重写必加 `@Override`**：让编译器替你校验签名；
2. **重载别滥用**：超过 3-4 个重载版本考虑用不同方法名或建造者模式，否则可读性崩坏；
3. **别重载可变参数和固定参数混合**：调用歧义防不胜防；
4. **设计"扩展点"时用重写**：父类留钩子方法（模板方法模式），子类重写实现差异化逻辑；
5. **警惕构造器里的动态分派**：

```java
class Base {
    public Base() {
        init();  // 调用的是子类重写的方法！
    }
    protected void init() {}
}
class Sub extends Base {
    private String name = "ok";
    @Override
    protected void init() {
        System.out.println(name);  // 输出 null！子类字段还没初始化
    }
}
```

构造器调用虚方法时，子类字段尚未初始化——**在构造器中避免调用可重写方法**（Effective Java 第 19 条）。

## 六、总结

- **重载**：同名不同参，**编译期静态分派**，看变量的**静态类型**；
- **重写**：同签名字类实现，**运行期动态分派**，看对象的**实际类型**；
- JVM 通过 `invokevirtual` + **方法表**实现多态，常数时间定位，空间换时间；
- 面试加分点：静态分派 vs 动态分派、方法表结构、协变返回类型与桥方法、构造器中调用虚方法的陷阱。

把语法、字节码指令、方法表三层讲清楚，这道"开胃菜"也能吃出硬核的味道。
