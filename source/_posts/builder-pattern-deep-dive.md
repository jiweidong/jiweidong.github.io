---
title: 【设计模式】建造者模式深度解析：从手写 Builder 到 Lombok @Builder 与框架级应用
date: 2026-08-12 08:00:00
tags:
  - Java
  - 设计模式
  - 源码
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】建造者模式深度解析：从手写 Builder 到 Lombok @Builder 与框架级应用

## 面试官：说说建造者模式和工厂模式的区别？什么时候用建造者？

**候选人**：建造者模式是分步构建对象，工厂模式是直接创建对象……

面试官追问：**"StringBuilder 是建造者模式吗？Lombok 的 @Builder 生成什么样的代码？你手写过 Builder 吗？"**

建造者模式（Builder Pattern）是日常开发中出现频率极高、但经常被"用过却说不清"的模式。今天从 GoF 定义出发，到手写实现、Lombok 原理，再到 Spring/MyBatis 等框架里的落地，一次讲透。

---

## 一、建造者模式：GoF 定义与核心思想

> **将一个复杂对象的构建与它的表示分离，使得同样的构建过程可以创建不同的表示。**

通俗解释：

- **复杂对象**：有很多属性、很多必填/选填组合、构建步骤有先后顺序的对象。
- **分离构建与表示**：客户端不直接 new 对象塞参数，而是通过 Builder **分步设置**，最后一步 `build()` 产出对象。

### 1.1 四个角色

| 角色 | 职责 | 举例 |
|------|------|------|
| **Builder（抽象建造者）** | 定义构建步骤的抽象接口 | `setName()`、`setAge()` |
| **ConcreteBuilder（具体建造者）** | 实现构建步骤，持有产品引用 | `UserBuilder` |
| **Director（指挥者）** | 编排构建步骤的顺序 | 可选的，链式调用常省略 |
| **Product（产品）** | 被构建的复杂对象 | `User` |

### 1.2 经典类图

```
Director ──▶ Builder（接口）
              ▲
              │
        ConcreteBuilder ──▶ Product
```

**注意**：现代 Java 开发中，**Director 通常被省略**——客户端自己通过链式调用控制顺序，这就是我们天天写的链式 Builder。

## 二、什么时候用建造者模式（面试必答）

适合场景（满足越多越该用）：

1. **属性特别多**：比如配置类、DTO，七八个以上字段，构造器参数列表惨不忍睹。
2. **必填选填混搭**：有些字段必须传，有些可选，用构造器只能写 N 个重载。
3. **对象不可变（immutable）**：所有字段 `final`，不提供 setter，只能通过 Builder 构建。
4. **构建有约束**：字段之间有依赖校验（如 a 和 b 必须同时设置），在 `build()` 里统一校验。
5. **构建步骤有顺序**：经典场景——组装电脑（CPU → 主板 → 内存 → 硬盘），步骤错了装不上。

### 2.1 反面教材：构造器地狱

```java
// 6 个参数已经是灾难，12 个参数直接放弃
new User("张三", 25, "北京", "13800000000", "zhangsan@example.com", "manager", true, false);
```

### 2.2 与工厂模式的本质区别（高频面试题）

| 维度 | 工厂模式 | 建造者模式 |
|------|---------|-----------|
| 关注点 | **创建哪个**对象（类型选择） | **怎么构建**对象（步骤组装） |
| 复杂度 | 对象相对简单，一次性创建 | 对象复杂，分步构建 |
| 返回时机 | 直接返回成品 | 构建中途返回 Builder，最后 build() 出成品 |
| 典型例子 | BeanFactory、简单工厂 | StringBuilder、Lombok @Builder |

**一句话**：工厂模式解决"**要哪个**"，建造者模式解决"**怎么拼**"。复杂对象的工厂内部也常组合建造者。

## 三、手写一个标准 Builder（核心能力）

### 3.1 经典实现（静态内部类 + 链式 + 不可变）

```java
public class User {
    // 1. 不可变：final 字段，无 setter
    private final String name;      // 必填
    private final int age;          // 必填
    private final String address;   // 选填
    private final String phone;     // 选填

    // 2. 私有构造器，参数是 Builder
    private User(Builder builder) {
        this.name = builder.name;
        this.age = builder.age;
        this.address = builder.address;
        this.phone = builder.phone;
    }

    // 3. 静态工厂方法返回 Builder（推荐写法）
    public static Builder builder() {
        return new Builder();
    }

    // 4. Builder 静态内部类
    public static class Builder {
        private String name;
        private int age;
        private String address;
        private String phone;

        // 必填参数通过 builder() 或 Builder 构造器传入
        private Builder() {}

        public Builder name(String name) {
            this.name = name;
            return this;  // 返回 this 实现链式调用
        }

        public Builder age(int age) {
            this.age = age;
            return this;
        }

        public Builder address(String address) {
            this.address = address;
            return this;
        }

        public Builder phone(String phone) {
            this.phone = phone;
            return this;
        }

        // 5. build()：统一校验 + 构建
        public User build() {
            if (name == null || name.isEmpty()) {
                throw new IllegalStateException("name is required");
            }
            if (age < 0 || age > 150) {
                throw new IllegalArgumentException("age invalid: " + age);
            }
            return new User(this);
        }
    }

    // 6. getter
    public String getName() { return name; }
    public int getAge() { return age; }
    // ...
}
```

### 3.2 使用

```java
User user = User.builder()
        .name("张三")
        .age(25)
        .address("北京")
        .build();  // 缺 phone，走默认 null
```

**亮点**：

- 必填校验集中在 `build()`，**构造合法对象是"一次性"的**——不存在半成品对象泄漏。
- 不可变对象天然线程安全，适合做配置、缓存 key。
- 客户端代码可读性极佳，参数和值一一对应。

## 四、Lombok @Builder 原理：编译期魔法

### 4.1 用法

```java
@Data
@Builder
public class User {
    private String name;
    private int age;
    private String address;
}
```

### 4.2 它替你生成了什么（用 javap 反编译看真相）

```bash
javap -p User.class
```

生成的关键成员：

```java
public class User {
    private String name;
    private int age;
    private String address;

    // 全参构造器（包级私有，@Builder 会生成）
    User(String name, int age, String address) { ... }

    // 静态方法
    public static User.UserBuilder builder() { ... }

    // 静态内部类 UserBuilder
    public static class UserBuilder {
        private String name;
        private int age;
        private String address;

        public User.UserBuilder name(String name) { this.name = name; return this; }
        public User.UserBuilder age(int age) { this.age = age; return this; }
        public User.UserBuilder address(String address) { this.address = address; return this; }
        public User build() { return new User(name, age, address); }
        public String toString() { ... }
    }
}
```

**本质**：Lombok 通过**注解处理器（APT）**在编译期修改 AST（抽象语法树），把 `@Builder` 展开成我们第三节手写的那些代码。所以运行时没有任何反射开销，和手写性能完全一致。

### 4.3 高级玩法

```java
@Builder(builderMethodName = "newBuilder", buildMethodName = "create")
@Builder.Default  // 给字段默认值
private String status = "ACTIVE";

@Builder(toBuilder = true)  // 生成 toBuilder()：基于现有对象修改再构建
User user2 = user.toBuilder().age(26).build();
```

**坑提醒**：

- `@Builder` 与 `@NoArgsConstructor` / `@AllArgsConstructor` 组合时，`@Builder` 会生成自己的全参构造器，**与 @AllArgsConstructor 冲突**（编译器报错）。解决：`@Builder` + `@AllArgsConstructor(access = AccessLevel.PACKAGE)` 或直接只留 `@Builder`。
- `@Builder` 与继承：子类 Builder 不会自动包含父类字段，需要 `@SuperBuilder`（Lombok 1.18.2+）。

## 五、框架中的建造者模式（面试加分项）

### 5.1 StringBuilder：教科书级简化 Builder

```java
StringBuilder sb = new StringBuilder();
sb.append("a").append("b").append("c");  // 链式设置
String result = sb.toString();           // build()
```

- Product：`String`（不可变）。
- Builder：`StringBuilder`（可变缓冲）。
- `toString()` 就是 `build()`。

**注意**：这是"简化版"Builder——Builder 直接参与构建（持有产品状态），GoF 标准版是 Builder 持有产品引用、逐步填充。两者核心思想一致：**分步构建 + 链式调用**。

### 5.2 Spring 的 UriComponentsBuilder / BeanDefinitionBuilder

```java
// Spring 构建 URI（Netty/WebFlux 场景常见）
URI uri = UriComponentsBuilder.fromPath("/api/users")
        .queryParam("page", 1)
        .queryParam("size", 10)
        .build()
        .toUri();

// Spring 构建 BeanDefinition
BeanDefinitionBuilder builder = BeanDefinitionBuilder
        .genericBeanDefinition(MyService.class)
        .addPropertyValue("timeout", 5000)
        .setScope(BeanDefinition.SCOPE_PROTOTYPE);
registry.registerBeanDefinition("myService", builder.getBeanDefinition());
```

### 5.3 MyBatis 的 XMLStatementBuilder / SqlSourceBuilder

MyBatis 解析 Mapper XML 时，`XMLStatementBuilder` 解析 SQL 语句构建 `MappedStatement`，内部还嵌套 `SqlSourceBuilder`（解析 `#{}` 占位符）——典型的**复杂对象分步构建**。

### 5.4 其他常见例子

| 框架/类 | Builder 用法 |
|---------|-------------|
| OkHttp | `new Request.Builder().url(...).header(...).build()` |
| Retrofit | `new Retrofit.Builder().baseUrl(...).addConverterFactory(...).build()` |
| Netty | `ServerBootstrap.group(...).channel(...).childHandler(...)` |
| HikariCP | `HikariConfig` 用 setter + `new HikariDataSource(config)` |

**规律**：凡是"配置项多 + 需要不可变 + 链式可读"的 API，框架都爱用 Builder。这也是为什么面试官爱问——**它是你天天在用的模式**。

## 六、进阶：泛型 Builder 与继承（高级话题）

### 6.1 泛型自引用 Builder（解决继承链式问题）

```java
public abstract class BaseBuilder<T extends BaseBuilder<T>> {
    protected String commonField;

    @SuppressWarnings("unchecked")
    public T commonField(String v) {
        this.commonField = v;
        return (T) this;  // 返回子类型，链式不中断
    }
}

public class ChildBuilder extends BaseBuilder<ChildBuilder> {
    private String childField;

    public ChildBuilder childField(String v) {
        this.childField = v;
        return this;
    }

    public Child build() { return new Child(this); }
}
```

**效果**：

```java
Child child = new ChildBuilder()
        .commonField("父类字段")   // 返回 ChildBuilder，链式不断
        .childField("子类字段")
        .build();
```

这就是 Lombok `@SuperBuilder` 的实现思路。

### 6.2 与"流式 API"的关系

建造者模式是流式 API（Fluent API）的典型载体，但**流式 API ≠ 建造者模式**：流式 API 只强调"链式调用返回 this"，建造者还强调"构建过程与最终产品分离"。比如 `Stream.map().filter()` 是流式但不是建造者。

## 七、面试追问速查

| 问题 | 答案要点 |
|------|---------|
| 建造者 vs 工厂？ | 工厂管"选哪个类型"，建造者管"怎么分步拼" |
| 为什么用 Builder？ | 参数多、必选可选混搭、要不可变对象、要集中校验 |
| Builder 能保证不可变吗？ | 能，字段 final + 私有构造器 + 无 setter |
| build() 里做什么？ | 必填校验、字段依赖校验、默认值填充、返回产品 |
| Lombok @Builder 原理？ | 注解处理器编译期改 AST 生成 Builder 代码，零运行时开销 |
| StringBuilder 算 Builder 吗？ | 算简化版：分步 append + toString() 收尾 |
| 链式调用怎么实现？ | 每个 setter 返回 this（泛型返回子类型可解决继承问题） |

---

**总结**：建造者模式是"复杂对象构建"的标准答案。手写一遍、看懂 Lombok 生成的字节码、再想想 StringBuilder 和 OkHttp 的设计，你就能在面试中从"背定义"升级到"讲原理"。日常写代码时，遇到 5 个以上参数的对象，请自觉掏出 Builder。
