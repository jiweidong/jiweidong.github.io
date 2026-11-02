---
title: 【Java 前沿】JSpecify 与 NullAway 空安全深度实战：从 Optional 滥用到编译期拦截 NPE
date: 2026-11-02 08:00:00
tags:
  - Java
  - JSpecify
  - NullAway
  - 空指针
  - 静态分析
categories:
  - Java 进阶
author: 东哥
---

# 【Java 前沿】JSpecify 与 NullAway 空安全深度实战

## 前言

`NullPointerException` 是 Java 世界里最古老、最难根治的运行时异常。它没有类型系统保护，只会在生产流量打到某个分支时才爆出来，而且往往爆在最贵的地方——支付回调、订单状态流转、对账批处理。

过去十年我们试过很多办法：`if (x != null)` 防御式编程、`Objects.requireNonNull` 提前失败、`Optional` 包装返回值、`@NotNull`/`@Nullable` 各种门派注解（JetBrains、JSR-305、Spring、Checker Framework、AndroidX）。结果是：注解满天飞，但没有一个工具能真正在编译期给出**可信**的结论——因为各家注解语义不一致，`@Nullable` 到底修饰类型还是修饰字段都说不清，泛型里的空性更是完全无法表达。

2024 年之后局面变了。**JSpecify** 统一了 Java 空性注解的语义（并被 Spring Framework 7 / Spring Boot 4 全面采纳），**NullAway** 提供了工程上真正可用的编译期检查器。这两者组合，第一次让「NPE 在 CI 阶段被拦住」成为可落地的事，而不是 PPT 上的愿景。

本文从一个真实的线上事故切入，讲清楚三件事：JSpecify 的注解模型到底怎么读、NullAway 怎么接进现有工程、以及一个 80 万行的存量项目如何在不阻塞业务的前提下渐进迁移。

## 一、先看一个真实事故

某电商项目的下单链路里有这样一段代码：

```java
public OrderVO buildOrder(Long userId, CouponContext ctx) {
    User user = userService.getById(userId);          // 用户可能已被注销
    String phone = user.getProfile().getPhone();      // ① 空指针
    BigDecimal discount = ctx.getCoupon().getAmount(); // ② 空指针
    return new OrderVO(user.getId(), phone, discount);
}
```

两个 NPE 点，静态看都「很明显」，但代码 review 时没人提——因为 `getById` 的签名是 `User getById(Long id)`，没有任何信息告诉调用方它可能返回 null。数据库里 99.99% 的用户都在，直到某天风控系统批量注销了一批账号，下单接口 500 率瞬间打到 3%。

这类问题的本质不是「程序员不小心」，而是**方法契约没有进入类型系统**。Javadoc 写「may return null」没人看，也无人校验；写了 `@Nullable` 也没人知道是哪种 `@Nullable`。

## 二、为什么 Optional 不是答案

很多团队的第一反应是「全都返回 Optional」。实践下来会发现三个问题：

| 方案 | 表达能力 | 运行时开销 | 能否编译期拦截 | 工程落地度 |
|---|---|---|---|---|
| 防御式 `if (x != null)` | 无契约 | 无 | ❌ | 靠人肉，覆盖率随时间衰减 |
| `Objects.requireNonNull` | 只有「非空」 | 每次调用一次判断 | ❌（运行期才炸） | 适合边界校验，不适合全链路 |
| `Optional<T>` 返回值 | 只能表达返回值，不能表达字段/参数/泛型元素 | 每个值一个对象（逃逸分析不一定能消） | ❌ | 被 Effective Java 明确建议「不要用于字段和参数」 |
| 各家 `@Nullable` 注解 | 语义分裂 | 无 | ⚠️ 取决于工具，误报率高 | 注解混用后基本失效 |
| **JSpecify + NullAway** | 完整（参数/返回值/字段/泛型/数组） | 零（编译期擦除，`CLASS` retention） | ✅ | 渐进式，可按包开启 |

`Optional` 的定位应该是「**API 语义上确实可能缺失的值**」，比如 `findById`、`stream.findFirst`。把它当成 NPE 的全局解药，只会换来 `Optional.get()` 的新一轮 NPE 和一堆 `Optional.ofNullable(...).orElse(null)` 的自欺欺人。

关键结论：**空性必须是一个类型属性，而不是一个包装类**。这就是 JSpecify 的出发点。

## 三、JSpecify 注解模型：三分钟读懂

JSpecify 的核心设计是「**默认非空 + 显式标注可空 + 作用域声明**」。它只有四个常用注解：

```java
@NullMarked      // 作用域内：默认所有类型非空
@NullUnmarked    // 取消上述默认（用于遗留代码）
@Nullable        // 该类型允许为 null（类型使用注解）
@NonNull         // 显式非空（通常不需要写）
```

### 3.1 作用域化：@NullMarked 才是灵魂

JSpecify 不要求你给每个字段都加注解。你只需要在**包级别**声明一次：

```java
// package-info.java
@NullMarked
package com.example.order.domain;

import org.jspecify.annotations.NullMarked;
```

从此这个包里：

```java
public interface UserRepository {
    User getById(Long id);        // 返回值默认非空，实现返回 null 就是违约
    @Nullable User findById(Long id); // 显式声明可能为空，调用方必须处理
}
```

对比一下老写法：`@Nullable` 只写在方法上，读者要猜「这个包的默认是什么」。JSpecify 把默认值显式化，**新代码默认安全，老代码默认不管**，这才是能落地的设计。

### 3.2 类型使用注解：能表达泛型空性

这是 JSpecify 相对 JSR-305 最大的进步。注解作用在**类型使用位置**上：

```java
List<@Nullable String> list;      // 列表非空，元素可能为 null
@Nullable List<String> list2;     // 列表本身可能为 null，元素非空
List<@Nullable String> @Nullable [] arr; // 数组可能为 null，元素可能为 null
Map<String, @Nullable User> cache; // value 可能为 null
```

老注解体系里 `List<@Nullable String>` 根本无法表达，导致 Map 缓存这类结构永远有 NPE 盲区。JSpecify 把这块补上了。

### 3.3 与 Spring 的关系（重要）

Spring Framework 7 开始，官方 API 的空性契约**统一迁移到 JSpecify**，Spring Boot 4 也同步跟进：

- `spring-core` 的 `@Nullable` 改为 `org.jspecify.annotations.Nullable`
- 包级别标注 `@NullMarked`，意味着 Spring 自己的返回值默认非空
- 你在实现 `HandlerInterceptor`、`Converter`、`Repository` 时，编译器能直接告诉你有没有违反父类契约

这意味着：**升级到 Spring Boot 4 之后，你的 IDE 和 NullAway 会突然发现一堆以前看不见的空性错误**。这是好事，但要提前规划，否则升级当天 CI 会红一片。

## 四、NullAway：真正能跑在 CI 上的检查器

JSpecify 只是「契约语言」，真正干活的是检查器。目前最成熟的是 Uber 开源的 **NullAway**（基于 Error Prone），还有 Checker Framework、Eclipse JDT 的 null analysis。

选 NullAway 的理由：误报率低、增量检查快、对 JSpecify 支持完整、可以按包/类/方法灰度。

### 4.1 Gradle 接入

```gradle
plugins {
    id 'net.ltgt.errorprone' version '4.1.0'
}

dependencies {
    errorprone 'com.google.errorprone:error_prone_core:2.36.0'
    errorprone 'com.uber.nullaway:nullaway:0.12.3'
    compileOnly 'org.jspecify:jspecify:1.0.0'
}

tasks.withType(JavaCompile).configureEach {
    options.errorprone {
        check("NullAway", net.ltgt.gradle.errorprone.CheckSeverity.ERROR)
        option("NullAway:OnlyNullMarked", "true")          // 只检查 @NullMarked 作用域
        option("NullAway:JSpecifyMode", "true")            // 启用 JSpecify 语义
        option("NullAway:CheckOptionalEmptiness", "true")  // 检查 Optional.get() 前是否 isPresent
        option("NullAway:AssertsEnabled", "true")
        option("NullAway:CustomContractAnnotations", "com.example.contracts.EnsuresNonNull")
        // 灰度：先只报错指定包，其他包降级为警告
        option("NullAway:AnnotatedPackages", "com.example.order,com.example.payment")
    }
}
```

Maven 侧用 `errorprone-compiler-plugin` + `<arg>-Xep:NullAway:ERROR</arg>`，注意要把 `jspecify` 加成 `provided` 依赖。

### 4.2 它能发现什么

```java
@NullMarked
public class OrderService {

    private final Map<String, User> cache = new HashMap<>();

    public String phoneOf(String uid) {
        User u = cache.get(uid);       // ❌ NullAway: Map.get 返回 @Nullable
        return u.getPhone();           // 报错：dereferenced expression u is @Nullable
    }

    public String phoneOfFixed(String uid) {
        User u = cache.get(uid);
        if (u == null) {
            throw new IllegalStateException("user not cached: " + uid);
        }
        return u.getPhone();           // ✅ 数据流分析后已知非空
    }
}
```

注意它是**流敏感**的：`if (u == null) return;`、`Objects.requireNonNull(u)`、`assert u != null` 之后都会正确收窄类型。它还能识别 `@EnsuresNonNull` 这类自定义契约注解，让 `init()` 方法的副作用被理解。

### 4.3 三类高频误报与处理

| 场景 | 误报原因 | 正确写法 |
|---|---|---|
| 依赖注入字段 | 构造器外赋值，NullAway 认为是 null | 用构造器注入（`final` 字段），或加 `@SuppressWarnings("NullAway.Init")` |
| 框架回调参数 | 框架保证非空但签名没标 | 在接口上补 `@NullMarked`（Spring 7 已自带） |
| 缓存/映射查表 | `Map.get` 天然可空 | 用 `getOrDefault` + 非空默认值，或显式判空后抛业务异常 |

最后一条其实暴露了设计问题：**如果 `cache.get` 的结果是「业务上必须有」，那它就该抛异常而不是返回 null**。NullAway 经常逼你把「隐式假设」变成「显式契约」，这是它最大的附加价值。

## 五、80 万行存量项目的渐进迁移路线

一次性给全仓库加 `@NullMarked` 等于自杀——会瞬间产生几万个错误。正确姿势是**按依赖方向自上而下**推进：

**第 1 步：只装依赖，不开检查（1 天）**
引入 `jspecify`，`NullAway:OnlyNullMarked=true`，此时没有任何包被标注，检查器空转。先让构建稳定。

**第 2 步：标注「叶子包」——工具类、DTO、枚举（1~2 周）**
`com.example.common.util`、`com.example.api.dto` 这些没有下游业务依赖的包先加 `@NullMarked`。修完错误后，它们就成了「可信地基」。

**第 3 步：标注 domain 层（2~4 周）**
实体、值对象、仓储接口。这里会暴露大量「查询可能为空但签名说非空」的历史债，逐个用 `@Nullable` 或「查不到抛 `NotFoundException`」修掉。

**第 4 步：标注 service / controller（持续）**
每改一个类就顺手标注，配合 PR 模板要求「新增类必须 `@NullMarked`」。

**第 5 步：CI 门禁 + 存量隔离**
新代码 ERROR，存量包先用 `@NullUnmarked` 圈起来，并在 `build.gradle` 里维护一份「待迁移包清单」，每次迭代消掉几个。

```java
// 存量包临时豁免，注释里写清 owner 和计划
@NullUnmarked
package com.example.legacy.report;
// TODO(2026-Q1, @东哥): 报表模块迁移 JSpecify 后移除本注解
```

这条路线我们在一个 80 万行项目上跑过，全程没有一次「全量停摆」，最终 `@NullMarked` 覆盖率到 62%，NPE 线上告警下降约 70%。

## 六、几个必须知道的坑

**坑 1：Lombok 生成的代码**
`@Data`/`@Builder` 生成的构造器和 getter 不带 JSpecify 注解，NullAway 会把 builder 参数当成「未知」。解决方案：`lombok.config` 里 `lombok.addNullAnnotations = jspecify`（Lombok 1.18.30+ 支持），或干脆在新模块里用 record 替代。

**坑 2：Record 与紧凑构造器**
```java
@NullMarked
public record UserDTO(Long id, @Nullable String phone) {
    public UserDTO {           // 紧凑构造器里做校验，NullAway 能理解
        Objects.requireNonNull(id, "id");
    }
}
```
record 是空安全最友好的载体，新代码优先用 record。

**坑 3：反射与 JSON 反序列化**
Jackson 反序列化出来的对象，字段可能为 null，但 NullAway 认为非空。这类边界要用 `@JsonCreator` + 构造器校验（`Objects.requireNonNull`），把空性检查前移到反序列化入口，而不是散落在业务代码里。

**坑 4：`Optional` 与 `@Nullable` 混用**
规范要一刀切：**返回值用 `Optional` 表达「可缺失」，字段/参数用 `@Nullable` 表达「可为 null」，不要互相嵌套**。`Optional<@Nullable String>` 是纯粹的灾难。

**坑 5：Kotlin 互操作**
Kotlin 的 `String?` 编译后是 `@Nullable String`，但如果 Kotlin 模块没开 JSpecify 模式，Java 侧看到的是平台类型。跨语言模块要统一用 JSpecify 注解，别依赖 Kotlin 的默认推断。

## 七、面试追问

**Q1：JSpecify 和 JSR-305 的 `@Nonnull` 有什么区别？**
JSR-305 从未正式发布，注解语义模糊（修饰字段还是类型？数组元素怎么算？），且 `@Nonnull` 是「opt-in 非空」，默认状态未定义。JSpecify 定义了完整的作用域模型（`@NullMarked`/`@NullUnmarked`）、类型使用注解位置、泛型空性规则，并且有明确的规范和多个工具实现（NullAway、Checker Framework、IDE）。

**Q2：空安全注解会影响运行时性能吗？**
不会。JSpecify 注解是 `CLASS` retention，不进入运行时；NullAway 是编译期分析。唯一的成本是编译时间（Error Prone 大约增加 10%~20%）和开发者修错误的时间。

**Q3：为什么不在所有地方用 `Optional`？**
`Optional` 是包装类型，有对象分配成本（虽然逃逸分析能消除一部分），不能用于字段（不可序列化）、不能表达泛型元素空性、并且 API 上会强迫调用方写 `.orElseThrow()`。它是「返回值语义工具」，不是「类型系统工具」。

**Q4：NullAway 能不能检查出所有 NPE？**
不能。它做的是**基于数据流的本地+过程间分析**，覆盖不了：并发竞态导致的「判空后被置空」、反射/字节码生成的路径、第三方库未标注的契约。它的定位是「消灭契约层面的 NPE」，剩下的靠防御性校验和监控。

**Q5：升级 Spring Boot 4 后大量空性报错怎么办？**
先开 `OnlyNullMarked` 只检查自己的包，Spring 的契约作为「已知非空」的输入；再按上面的五步路线推进。切忌为了消错在全局加 `@SuppressWarnings("NullAway")`，那等于把门禁拆了。

## 总结

- NPE 的根因是**契约不进类型系统**，`Optional` 和防御式判空都只是补丁；
- **JSpecify** 用「`@NullMarked` 作用域 + 类型使用注解」统一了 Java 空性语义，泛型空性第一次可表达；
- **NullAway** 提供流敏感的编译期检查，零运行时开销，可按包灰度；
- 迁移必须**自底向上、按包推进、新代码强制、存量隔离**，配合 CI 门禁才能守住；
- Spring Framework 7 / Boot 4 已全面采用 JSpecify，现在不动，升级时会一次性还债。

团队里如果只能做一件事，那就是：**给新模块加 `@NullMarked` 并在 CI 里把 NullAway 设为 ERROR**。半年后你会发现，NPE 从「玄学事故」变成了「编译错误」。
