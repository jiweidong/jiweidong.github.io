---
title: 【面试必备】equals 与 hashCode 深度解析：从 Object 源码到集合去重原理
date: 2026-08-10 08:00:00
tags:
  - Java
  - 基础
  - 集合
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 【面试必备】equals 与 hashCode 深度解析：从 Object 源码到集合去重原理

## 面试官：为什么重写 equals 必须重写 hashCode？不重写会怎样？

这道题几乎每个 Java 面试都会问，但能答到点子上的不多。很多人只会背结论：「不重写 hashCode，HashMap 就会出 bug」。但「为什么」以及「内部到底发生了什么」，需要从 Object 源码、散列原理、HashMap 的 put/get 流程一层层拆开看。

今天这篇，我们从 Object 的两个默认实现讲起，用源码 + 手写示例 + 反例演示，把 equals、hashCode、散列冲突、集合去重这些点一次讲透。

## 一、Object 的默认实现

### 1.1 equals：默认比较引用

```java
// Object.java
public boolean equals(Object obj) {
    return (this == obj);
}
```

`Object.equals` 就是 `==`，比较的是**内存地址**。两个 `new` 出来的对象地址不同，所以默认 equals 返回 false。

### 1.2 hashCode：默认与内存地址相关

```java
// Object.java 的 native 方法
public native int hashCode();
```

`Object.hashCode` 是 native 方法，默认实现通常基于对象的内存地址（HotSpot 里是对象的随机值/地址派生的一个值），不同对象的 hashCode 一般不同（不绝对，可能碰撞）。

### 1.3 两者的契约（Java 官方规范）

`Object` 文档中定义了 hashCode 的约定：

1. **一致性**：同一对象多次调用 hashCode 必须返回相同值（equals 没变的前提下）。
2. **equals 相等 ⇒ hashCode 相等**：如果 a.equals(b) 为 true，那么 a.hashCode() 必须等于 b.hashCode()。
3. **hashCode 相等 ≠ equals 相等**：两个对象 hashCode 相同，equals 不一定相等（散列碰撞）。

其中第 2 条是**必须**遵守的，违反它会导致基于散列的集合（HashMap、HashSet、HashTable）行为错乱。

## 二、为什么「重写 equals 必须重写 hashCode」？

### 2.1 反例：只重写 equals，不重写 hashCode

```java
public class Person {
    private String id;
    private String name;

    public Person(String id, String name) {
        this.id = id;
        this.name = name;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        Person p = (Person) o;
        return Objects.equals(id, p.id) && Objects.equals(name, p.name);
    }
    // 注意：没有重写 hashCode！
}

// 使用
Person p1 = new Person("1001", "东哥");
Person p2 = new Person("1001", "东哥");

System.out.println(p1.equals(p2));          // true（逻辑相等）

HashSet<Person> set = new HashSet<>();
set.add(p1);
set.add(p2);
System.out.println(set.size());             // 2 ！明明逻辑相等，却存了两个
```

### 2.2 HashSet.add 的源码流程

为什么 set 里会有两个相等的对象？看 HashSet 的 add —— 它底层就是 HashMap：

```java
// HashSet.java
public boolean add(E e) {
    return map.put(e, PRESENT) == null;   // 把元素当 key 存入 HashMap
}
```

HashMap.put 的流程（JDK 8）：

```java
public V put(K key, V value) {
    return putVal(hash(key), key, value, false, true);
}

static final int hash(Object key) {
    int h;
    // key.hashCode() 高 16 位异或低 16 位，让散列更均匀
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}
```

关键点来了：HashMap 先算 `hashCode` 定位**桶（bucket）**，再在桶内用 `equals` 比较。p1 和 p2 的 hashCode 不同（默认实现），所以它们被放进了**不同的桶**，`equals` 根本没机会被调用——两个对象互不可见，就都存进去了。

### 2.3 更隐蔽的问题：可变对象当 key

```java
Person p = new Person("1001", "东哥");
HashMap<Person, String> map = new HashMap<>();
map.put(p, "工程师");

p.setName("西姐");   // 修改了参与 hashCode 计算的字段！

map.get(new Person("1001", "西姐"));  // null！找不到
map.get(new Person("1001", "东哥"));  // 也 null！还是找不到
```

修改对象后，其 hashCode 变了，但它在 HashMap 里还挂在**旧桶**上，`get` 按新 hashCode 去新桶找，自然找不到。**所以：参与 equals/hashCode 的字段应当是「不可变」的，或者干脆不要用可变对象做 key**。

## 三、为什么 HashMap 不直接用 equals 定位？

这是面试的高频追问。答案是**性能**：

- `equals` 需要遍历比较字段，成本高；`hashCode` 是 O(1) 的整数运算。
- 先 hashCode 定位桶，把「全量比较」降为「桶内少量比较」。理想情况下每个桶只有一个元素，`get` 就是 O(1)。

```
put/get 流程：
1. hash(key) → 定位桶下标（O(1)）
2. 桶内链表/红黑树中，用 equals 逐个比较（桶内元素少，近似 O(1)）
```

HashMap 用 `(n - 1) & hash` 计算桶下标（n 是数组长度，2 的幂时等价于取模但更快），这也是为什么数组长度必须是 2 的幂。

## 四、hashCode 的正确写法

### 4.1 手写：经典 31 算法

Effective Java 推荐的写法，为什么用 31？因为 `31 * i == (i << 5) - i`，JVM 可以优化成移位减法的位运算，又快又能减少碰撞（奇素数乘法分布好）。

```java
@Override
public int hashCode() {
    int result = 1;
    result = 31 * result + (id == null ? 0 : id.hashCode());
    result = 31 * result + (name == null ? 0 : name.hashCode());
    return result;
}
```

### 4.2 现代写法：Objects.hash / 注解

```java
// 方式一：Objects.hash（内部就是 31 算法，注意会装箱）
@Override
public int hashCode() {
    return Objects.hash(id, name);
}

// 方式二：Java 7+ 的 Objects.equals 配合 Lombok @Data
// Lombok 的 @EqualsAndHashCode 会自动生成规范的 equals/hashCode
```

### 4.3 完整规范的 equals 写法

```java
@Override
public boolean equals(Object o) {
    // 1. 自反性：同一引用直接 true
    if (this == o) return true;
    // 2. 类型检查：null 或类型不同直接 false
    if (o == null || getClass() != o.getClass()) return false;
    // 3. 强转后逐字段比较
    Person p = (Person) o;
    return Objects.equals(id, p.id) && Objects.equals(name, p.name);
}
```

用 `getClass() != o.getClass()` 还是 `instanceof`？如果类不允许继承（如 final class），两者等价；如果考虑子类，`instanceof` 配合 `canEqual`（Lombok 的写法）更安全。**另外：equals 里比较的字段，hashCode 里必须也用上，且要一致**，否则契约照样被破坏。

## 五、equals 的五大性质（面试背书点）

| 性质 | 含义 | 违反后果 |
|------|------|----------|
| 自反性 | a.equals(a) == true | 集合 contains 自己都返回 false |
| 对称性 | a.equals(b) ⇔ b.equals(a) | 一个方向 true 一个方向 false |
| 传递性 | a=b 且 b=c ⇒ a=c | 子类继承场景最容易踩坑 |
| 一致性 | 字段不变则结果不变 | 可变字段参与比较会时真时假 |
| 非空性 | a.equals(null) == false | NPE 或逻辑错误 |

**对称性陷阱示例**：子类重写 equals 用 `instanceof` 判断父类，父类用 `getClass()` 判断，就会 a.equals(b) true 而 b.equals(a) false。规范做法：父类 equals 用 `getClass()`，或者子类不要重写父类的 equals（用 `canEqual` 模式）。

## 六、面试常见追问

**Q1：两个对象 hashCode 相同，equals 一定相同吗？**
不一定。这是散列碰撞，两个不同对象可能算出相同 hashCode。HashMap 会在同一桶里用 equals 区分它们（链表/红黑树）。

**Q2：String 的 hashCode 怎么算的？**
`s[0]*31^(n-1) + s[1]*31^(n-2) + ... + s[n-1]`，即多项式 `31 * h + char` 累加。String 缓存了 hash 字段（`private int hash;`），第一次算完存起来，之后 O(1) 返回——这也是 String 适合做 HashMap key 的原因之一（不可变 + 缓存哈希）。

**Q3：HashMap 中 equals 和 hashCode 各调用几次？**
put：hashCode 1 次（定位桶），equals 0 或多次（桶内已有元素时比较）。get：hashCode 1 次 + equals 0 或多次。极端碰撞时 equals 会调用多次。

**Q4：为什么用 31 不用 2？**
2 的幂会丢失信息（相当于移位），碰撞率高；31 是奇素数，乘法分布均匀且可被 JVM 优化为 `(i << 5) - i`，兼顾速度与分布。

**Q5：HashSet 去重原理？**
底层 HashMap，add 时以元素为 key。先 hashCode 定位桶，桶内再 equals 判断是否已有相等元素——两个都相同才算重复。

## 七、总结

| 要点 | 内容 |
|------|------|
| 默认实现 | equals 比较引用，hashCode 与内存地址相关 |
| 黄金契约 | equals 相等 ⇒ hashCode 必相等 |
| 违反后果 | HashMap/HashSet 去重失效、get 不到值 |
| 定位流程 | hashCode 找桶 → equals 桶内精确定位 |
| 正确写法 | 相同字段集合参与两者计算，Objects.equals/Objects.hash |
| 最佳实践 | key 对象不可变；字段要 final；别用可变字段算哈希 |

最后记住面试的完整回答链路：**Object 默认实现 → 契约规范 → HashMap 先 hashCode 后 equals 的查找流程 → 反例演示 → 正确写法**。能把这五步讲下来，这道题就是送分题。
