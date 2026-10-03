---
title: 【Java 安全】序列化过滤器（JEP 290 / ObjectInputFilter）深度解析：反序列化攻击的最后一道防线
date: 2026-10-03 08:00:04
tags:
  - Java
  - 安全
  - 反序列化
  - JEP 290
categories:
  - Java
  - 安全
author: 东哥
---

# 【Java 安全】序列化过滤器（JEP 290 / ObjectInputFilter）深度解析：反序列化攻击的最后一道防线

## 面试官：Java 反序列化漏洞，除了升级依赖版本，还能怎么防？

反序列化漏洞是 Java 安全里最经典、也最难缠的一类。从 2015 年 Apache Commons Collections 的 gadget 链引爆，到后来的 Fastjson、Jackson、Log4j，攻击者用一条精心构造的字节流，就能在你的服务器上执行任意命令。

很多人的回答停在"别用原生序列化""升级组件版本"。但面试官往往接着问：

- 如果我必须用原生反序列化，能拦住吗？
- **JEP 290** 是什么？为什么说它是"最后一道防线"？
- 白名单怎么写才安全？为什么黑名单注定失败？

这篇文章把 JDK 内置的**序列化过滤器**讲透——它从 JDK 9 引入（JEP 290），JDK 17 又做了上下文增强（JEP 415），是 JDK 层面给反序列化的"官方防线"。

---

## 一、反序列化为什么危险

`ObjectInputStream.readObject()` 的过程是：

```
读取字节流 → 解析类描述 → 反射创建对象（不走构造器） → 调用 readObject 恢复状态
```

三个危险点：

1. **类由流决定**——攻击者可以在流里塞任意类名，服务端会去加载并实例化它；
2. **不走构造器**——绕过了所有构造器里的校验逻辑；
3. **`readObject` / `readResolve` 是代码执行入口**——很多类的这些方法里有"副作用"，串联起来就是一条 gadget 链（RCE）。

最要命的是：**这些类往往是 JDK 或常用库自带的合法类**，你既不能删、也未必能升。

---

## 二、为什么黑名单治不好

历史上几乎所有防御尝试都从黑名单开始，也几乎全部失败：

| 黑名单思路 | 为什么失败 |
| --- | --- |
| 禁用 `InvokerTransformer` | CommonsCollections 有 ChainTransformer 等一堆等价链 |
| 禁用 `TemplatesImpl` | JDK 里还有其他"能加载字节码"的类 |
| 禁用某个反序列化框架 | 攻击面会转移到框架的依赖里（Redis/JNDI 协议） |
| 过滤特定字段名 | 属性名可被绕过 / 编码变形 |

核心原因：**Java 生态的类是无界的、不断增长的，你永远列不完"坏类"**。

所以正确的方向只有一个：**白名单——只允许明确需要的类反序列化，其余一律拒绝。**

这正是 JEP 290 的设计哲学。

---

## 三、JEP 290：`ObjectInputFilter`

JDK 9 引入 `java.io.ObjectInputFilter`，在 `ObjectInputStream` 内部建立**过滤钩子**：每读到一个类、每读一次数组、每递归一层，都会先经过过滤器判定。

### 接口

```java
@FunctionalInterface
public interface ObjectInputFilter {
    Status checkInput(FilterInfo info);

    enum Status {
        UNDECIDED,   // 交给下一个过滤器
        ALLOWED,     // 允许
        REJECTED     // 拒绝（抛 InvalidClassException）
    }

    interface FilterInfo {
        Class<?> serialClass();     // 当前要反序列化的类
        long arrayLength();         // 数组长度（-1 表示非数组）
        long depth();               // 当前嵌套深度
        long references();          // 已读对象引用数
        long streamBytes();         // 已读字节数
    }
}
```

### 过滤器能控制什么

| 维度 | 字段 | 防护目标 |
| --- | --- | --- |
| 类白/黑名单 | `serialClass()` | 阻止 gadget 类被实例化 |
| 数组长度 | `arrayLength()` | 阻止 `new byte[2GB]` 式 OOM |
| 嵌套深度 | `depth()` | 阻止深度嵌套导致的栈溢出 DoS |
| 引用数量 | `references()` | 阻止引用膨胀 DoS |
| 字节数 | `streamBytes()` | 阻止超大流 DoS |

**注意：JEP 290 不只防 RCE，还防 DoS**——这一点常被忽略。

---

## 四、过滤器表达式的语法

JEP 290 定义了一套紧凑的过滤器 DSL，可直接写成字符串：

| 语法 | 含义 | 示例 |
| --- | --- | --- |
| `com.foo.Bar` | 精确类 | 只允许这一个类 |
| `com.foo.*` | 某包下的类 | `com.myapp.dto.*` |
| `com.foo.**` | 某包及子包 | `com.myapp.**` |
| `*` | 所有类（谨慎） | — |
| `!com.foo.Bar` | 拒绝某类（黑名单） | `!*` 表示"拒绝所有" |
| `maxdepth=100` | 最大嵌套深度 | — |
| `maxrefs=10000` | 最大引用数 | — |
| `maxbytes=1048576` | 最大读取字节 | — |
| `maxarray=1000000` | 最大数组长度 | — |

一个**白名单 + 限制**的典型写法：

```
com.myapp.dto.**;com.myapp.model.**;java.lang.String;java.lang.Integer;java.util.ArrayList;java.util.HashMap;maxdepth=20;maxrefs=100000;maxbytes=1048576;maxarray=1000000;!*
```

**关键点**：变量（`maxdepth` 等）在**前**，类模式在**后**；是否命中按顺序判定；结尾的 `!*` 是"默认拒绝"的兜底。

---

## 五、四种配置方式

### 方式 1：全局系统属性 `jdk.serialFilter`（最推荐）

```bash
java -Djdk.serialFilter="com.myapp.dto.**;java.lang.String;java.lang.Integer;\
java.util.ArrayList;java.util.HashMap;maxdepth=20;maxbytes=1048576;!*" -jar app.jar
```

优点：不改代码，运维可配，**覆盖整个 JVM**。这也是生产最容易落地的方式。

### 方式 2：代码里设置全局过滤器

```java
ObjectInputFilter filter = ObjectInputFilter.Config.createFilter(
        "com.myapp.dto.**;java.lang.*;java.util.*;!*");

ObjectInputFilter.Config.setSerialFilter(filter);

// 方式 3 的 SPI 变体：设置工厂（见下）
// ObjectInputFilter.Config.setSerialFilterFactory(...);
```

注意：**全局过滤器只能设置一次**，重复设置会抛 `IllegalStateException`。所以要在应用启动早期设置。

### 方式 3：单个流级过滤器（最细粒度）

```java
try (ObjectInputStream ois = new ObjectInputStream(input)) {
    ois.setObjectInputFilter(info -> {
        Class<?> clazz = info.serialClass();
        if (clazz == null) {
            return ObjectInputFilter.Status.UNDECIDED;   // 非类事件交给全局
        }
        // 只允许我的 DTO 包
        if (clazz.getName().startsWith("com.myapp.dto.")) {
            // 同时限制深度与字节数，防 DoS
            if (info.depth() > 20 || info.streamBytes() > 1024 * 1024) {
                return ObjectInputFilter.Status.REJECTED;
            }
            return ObjectInputFilter.Status.ALLOWED;
        }
        return ObjectInputFilter.Status.REJECTED;
    });

    Object obj = ois.readObject();
}
```

流级过滤器会与全局过滤器**级联**（先流级、再全局），任一层 REJECTED 就拒绝。

### 方式 4：JEP 415 —— SPI 工厂，按上下文选择

JDK 17 之前，全局过滤器只有"一个"，难以适配"RMI 用一套、应用缓存用另一套"的多上下文场景。JEP 415 引入 **`jdk.serialFilterFactory` 系统属性**（过滤器工厂 SPI）：

```java
public class MyFilterFactory implements BinaryOperator<ObjectInputFilter> {
    @Override
    public ObjectInputFilter apply(ObjectInputFilter current, ObjectInputFilter next) {
        // current: 已有的流级过滤器
        // next:    之前设置的过滤器
        // 返回合并后的过滤器
        return ObjectInputFilter.merge(current, next);
    }
}
```

```
-Djdk.serialFilterFactory=com.myapp.MyFilterFactory
```

`ObjectInputFilter.merge(a, b)` 的语义：**任一 REJECTED 则拒绝；否则任一 ALLOWED 则允许；都 UNDECIDED 则 UNDECIDED**。这正是"全局 + 上下文"叠加的安全默认。

**实践建议**：默认**不要**用 `setSerialFilterFactory` 去覆盖全局过滤器；JEP 415 的设计就是让工厂做**叠加**而非替换，防止某个组件悄悄削弱全局防护。

---

## 六、JDK 内建的"过滤器集成点"

JEP 290 的另一个价值：JDK 把过滤器接入了**内建的反序列化入口**，覆盖了很多默认攻击面：

| 入口 | 说明 |
| --- | --- |
| RMI（`UnicastRemoteObject`） | 默认有过滤器；JDK 会合并用户过滤器 |
| JMX（RMI Connector） | 默认限制为部分安全类型 |
| JNDI / LDAP | 远程类加载默认关闭 |
| HTTP Session（Tomcat 等） | 容器会设置会话反序列化过滤器 |
| JDK 自带组件的内部流 | 有各自的默认过滤器 |

**这意味着**：即使你的业务代码直接用了 `ObjectInputStream`，很多"系统性入口"也已经默认加了约束。但**你自己写的反序列化仍必须显式配置过滤器**。

---

## 七、一个可落地的白名单模板

假设 `OrderMessage` 通过 Kafka/MQ 以 Java 原生序列化传输，需要：`OrderMessage`、其内部 `List<OrderItem>`、`ItemStatus` 枚举、以及 `java.util` 集合类。

```java
public final class DeserializationSecurity {

    private static final ObjectInputFilter FILTER = ObjectInputFilter.Config.createFilter(
            // —— 业务类白名单（收窄到具体包）——
            "com.myapp.order.message.**;" +
            "com.myapp.common.enums.**;" +
            // —— 必要的 JDK 基础类型 ——
            "java.lang.String;java.lang.Integer;java.lang.Long;" +
            "java.lang.Boolean;java.lang.Double;java.lang.Number;" +
            "java.time.**;" +
            "java.util.ArrayList;java.util.LinkedList;" +
            "java.util.HashMap;java.util.LinkedHashMap;java.util.HashSet;" +
            "java.util.UUID;java.util.concurrent.ConcurrentHashMap;" +
            "java.math.BigDecimal;" +
            // —— 资源上限（防 DoS）——
            "maxdepth=32;maxrefs=100000;maxbytes=4194304;maxarray=1000000;" +
            // —— 默认拒绝 ——
            "!*");

    static {
        ObjectInputFilter.Config.setSerialFilter(FILTER);
    }

    public static Object deserialize(byte[] data) throws IOException, ClassNotFoundException {
        try (ObjectInputStream ois = new ObjectInputStream(new ByteArrayInputStream(data))) {
            ois.setObjectInputFilter(FILTER);
            return ois.readObject();
        }
    }
}
```

### 逐条讲解设计要点

| 设计 | 原因 |
| --- | --- |
| 用 `**` 收窄到业务包 | 不用宽泛的 `com.myapp.*`，避免误放 |
| 只列必要的 JDK 类 | `java.lang.*` 太宽，`Class`、`Runtime` 等可能被利用 |
| 显式限制 `maxdepth/maxrefs/maxbytes` | 防 DoS，不只是防 RCE |
| 结尾 `!*` | 默认拒绝，任何未列出的类直接失败 |
| 流级也 `setObjectInputFilter` | 双保险，防止全局被覆盖 |

---

## 八、更彻底的方向：别用原生序列化

过滤器是"防线"，不是"银弹"。真正安全的做法是**从源头消灭原生反序列化**：

| 替代方案 | 适用 |
| --- | --- |
| JSON（Jackson / Gson） | 绝大多数业务消息、缓存 |
| Protobuf / Thrift | 高性能、强 schema、跨语言 |
| Avro | 数据管道、Schema 演进 |
| 自定义二进制 | 极致性能场景 |

给 Jackson 也配上白名单（`activateDefaultTyping` 的多态反序列化同样危险）：

```java
PolymorphicTypeValidator ptv = BasicPolymorphicTypeValidator.builder()
        .allowIfSubType("com.myapp.")
        .allowIfSubType("java.util.")
        .build();
ObjectMapper mapper = JsonMapper.builder()
        .activateDefaultTyping(ptv, ObjectMapper.DefaultTyping.NON_FINAL)
        .build();
```

**注意**：Jackson 的 `enableDefaultTyping()`（老 API，无校验器）是多个 CVE 的源头，**任何 `@class` 全开的多态反序列化都必须配 `PolymorphicTypeValidator`**。

---

## 九、常见误区

| 误区 | 事实 |
| --- | --- |
| "设了 `jdk.serialFilter` 就万事大吉" | 全局过滤器可能被组件用 `setSerialFilterFactory` 削弱；仍需流级校验 |
| "过滤器只防 RCE" | 它同时防 DoS（深度/引用/字节/数组上限） |
| "白名单可以写 `java.**`" | 太宽，JDK 里有可用于攻击的类（如动态代理、类加载相关） |
| "过滤器能防所有反序列化漏洞" | 它只作用于 `ObjectInputStream`；JNDI、fastjson、Jackson、XStream 等各自的反序列化要走各自的防御 |
| "黑名单够用了" | 类是无界的，黑名单必然漏 |
| "过滤器会影响性能" | 判定是常量级比较，开销极小 |

---

## 十、面试常见追问

**Q1：JEP 290 和 JEP 415 的区别？**
JEP 290（JDK 9）引入 `ObjectInputFilter` 与 `jdk.serialFilter` 全局过滤器；JEP 415（JDK 17）引入 **上下文相关的过滤器工厂**（`jdk.serialFilterFactory`、`setSerialFilterFactory`），解决"不同来源的反序列化需要不同策略"的问题，并明确工厂应做**合并叠加**而非替换。

**Q2：过滤器被拒绝时抛什么异常？**
`java.io.InvalidClassException`，消息类似 `filter status: REJECTED`。生产上把它当成"安全事件"报警，而不是普通业务异常。

**Q3：为什么 `readObject` 不走构造器，过滤器却能拦住？**
过滤器是在 `ObjectInputStream` 解析**类描述**、准备实例化之前调用的，早于任何 gadget 代码执行。这正是它有效的关键——**在危险类被加载/实例化之前就拒绝**。

**Q4：`jdk.serialFilter` 对第三方框架的反序列化有效吗？**
只对使用 `ObjectInputStream` 的框架有效。fastjson、Jackson、XStream、Hessian、Kryo 等有自己的反序列化实现，需要各自的防御（白名单/校验器/禁用 autoType）。Kryo 尤其要注意 `setRegistrationRequired(true)`。

**Q5：如何验证过滤器生效？**
构造一个白名单外的类做反序列化，观察是否抛 `InvalidClassException: filter status: REJECTED`；同时检查启动日志里是否成功设置了全局过滤器（可打印 `ObjectInputFilter.Config.getSerialFilter()` 确认）。

---

## 十一、总结

- **反序列化漏洞的根源**：类由流决定、不走构造器、`readObject` 是执行入口。
- **黑名单注定失败**，正确方向是**白名单 + 资源上限 + 默认拒绝**。
- **JEP 290（JDK 9）** 提供 `ObjectInputFilter`、过滤器表达式与 `jdk.serialFilter` 全局配置，是 JDK 层面的官方防线。
- **JEP 415（JDK 17）** 用过滤器工厂 SPI 支持**上下文相关**的过滤策略，且强制"合并叠加"语义。
- **落地清单**：全局属性兜底 + 关键流显式 `setObjectInputFilter` + 限制 `maxdepth/maxrefs/maxbytes/maxarray` + 结尾 `!*` + 报警 REJECTED。
- **终极方案**：能用 JSON/Protobuf 就别用 Java 原生序列化；Jackson 多态必须配 `PolymorphicTypeValidator`。

一句话：**过滤器不是让反序列化变安全，而是让"不该出现的类"根本没有机会出现。**
