---
title: 【工程实战】ArchUnit 架构守护测试深度实战：把架构约束写进单元测试
date: 2026-09-12 08:00:00
tags:
  - Java
  - 架构
  - 测试
categories:
  - Java
  - 工程实践
author: 东哥
---

# 【工程实战】ArchUnit 架构守护测试深度实战：把架构约束写进单元测试

## 面试官：你们团队怎么保证架构不被写烂？

这个问题如果只回答「靠 Code Review 和文档」，基本就废了。真实项目里，架构腐化从来不是某一次大改动造成的，而是无数个「我就临时调一下」叠加出来的：

- Controller 里直接注入了 Mapper，Controller → DAO 的依赖倒挂了；
- 有人在 domain 包里面 `import` 了 `spring-web`，领域层被框架污染；
- 两个模块互相调用，A 依赖 B、B 又依赖 A，形成循环依赖，每次改都得一起改、一起发；
- 团队约定「service 层只能被 controller 调用」，半年后没人记得这条约定。

这些问题的共同点是：**编译器不管、单测不管、CI 也不管**，等发现的时候已经改不动了。

解决思路很直接 —— 把架构约束变成**可执行的测试**。这就是 ArchUnit 要解决的问题。

## 一、ArchUnit 是什么

ArchUnit 是一个轻量级的 Java 架构测试库，核心能力是：

> 用普通的单元测试（JUnit 4/5、TestNG）来断言代码的**架构约束**，比如依赖方向、分层规则、命名规范、循环依赖、注解使用等。

它和静态分析工具（Checkstyle、PMD、SpotBugs、SonarQube）的本质区别在于：

| 维度 | ArchUnit | 传统静态分析 |
| --- | --- | --- |
| 关注点 | 架构/依赖/分层规则 | 代码风格、缺陷模式、复杂度 |
| 规则表达 | 流式 DSL，可自定义 | 预设规则集 + 少量自定义 |
| 是否懂「架构」 | 懂（分层、切片、循环依赖） | 基本不懂 |
| 接入成本 | 一个测试依赖 | 独立平台 + 扫描任务 |
| 执行时机 | 单测阶段，秒级反馈 | 通常独立任务 |

一句话：Checkstyle 管「这一行怎么写的」，ArchUnit 管「这个包为什么能依赖那个包」。

### 引入依赖

```xml
<dependency>
    <groupId>com.tngtech.archunit</groupId>
    <artifactId>archunit-junit5</artifactId>
    <version>1.3.0</version>
    <scope>test</scope>
</dependency>
```

Gradle：

```groovy
testImplementation 'com.tngtech.archunit:archunit-junit5:1.3.0'
```

### 最小可用示例

```java
import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.lang.ArchRule;
import org.junit.jupiter.api.Test;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.*;

class ArchitectureTest {

    private static final JavaClasses CLASSES =
            new ClassFileImporter().importPackages("com.example.order");

    @Test
    void service_should_not_depend_on_controller() {
        ArchRule rule = noClasses()
                .that().resideInAPackage("..service..")
                .should().dependOnClassesThat().resideInAPackage("..controller..");

        rule.check(CLASSES);
    }
}
```

这十行代码，就把一条「service 不能依赖 controller」的架构约定固化成了 CI 会拦的红线。任何人提交违规代码，`mvn test` 直接失败，并且 ArchUnit 会把违规的类、行号、调用链全部打印出来。

## 二、Import：先把字节码变成架构模型

ArchUnit 不读源码，它读的是**编译后的 class 文件**（这是它快的原因，也是它只能看到字节码里存在的信息的原因）。

```java
// 导入整棵包树
JavaClasses classes = new ClassFileImporter().importPackages("com.example");

// 导入 classpath 上的所有类（慎用，慢）
JavaClasses all = new ClassFileImporter().importClasspath();

// 指定多个包
JavaClasses multi = new ClassFileImporter()
        .importPackages("com.example.order", "com.example.payment");

// 排除某些包
JavaClasses filtered = new ClassFileImporter()
        .importPackages("com.example")
        .that(new ClassFileImporter()... );
```

常用配置项：

```java
new ClassFileImporter()
        .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
        .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_ARCHIVES)
        .importPackages("com.example");
```

> ⚠️ 实践坑：如果工程里有 Lombok 生成的类、MapStruct 生成实现、或 `target/generated-sources` 里的代码，建议显式排除，否则规则会在生成类上误报。建议把每次导入的 `JavaClasses` 做成 `static` 常量，整个测试类只导入一次（导入是 ArchUnit 里最慢的一步）。

## 三、分层架构：LayeredArchitecture

分层是最常见的架构约束。ArchUnit 内置了 `layeredArchitecture()`：

```java
@ArchTest
static final ArchRule layered_architecture = 
    Architectures.layeredArchitecture()
        .consideringOnlyDependenciesInLayers()
        .layer("Controller").definedBy("..controller..")
        .layer("Service").definedBy("..service..")
        .layer("Repository").definedBy("..repository..")
        .layer("Domain").definedBy("..domain..")
        // 上层可以调用下层（按声明顺序自上而下）
        .whereLayer("Controller").mayNotBeAccessedByAnyLayer()
        .whereLayer("Service").mayOnlyBeAccessedByLayers("Controller")
        .whereLayer("Repository").mayOnlyBeAccessedByLayers("Service")
        .whereLayer("Domain").mayNotAccessAnyLayer();
```

规则说明：

- `whereLayer("Controller").mayNotBeAccessedByAnyLayer()` —— 最顶层的入口，不允许被任何层依赖；
- `whereLayer("Service").mayOnlyBeAccessedByLayers("Controller")` —— Service 只能被 Controller 调；
- `whereLayer("Domain").mayNotAccessAnyLayer()` —— 领域层是核心，**不允许依赖任何其他层**（依赖倒置的核心）。

这最后一条尤其重要：它保证了「领域层是纯业务代码」，一旦有人 `import` 了 Spring 或 MyBatis 的类型，测试立刻失败。

如果项目用了 DDD 洋葱/六边形架构，可以直接用内置的：

```java
@ArchTest
static final ArchRule onion = Architectures.onionArchitecture()
        .domainModels("..domain.model..")
        .domainServices("..domain.service..")
        .applicationServices("..application..")
        .adapter("web", "..adapter.web..")
        .adapter("persistence", "..adapter.persistence..");
```

`onionArchitecture()` 会自动保证：内层不认识外层、外层只能依赖内层、domainModel 不依赖 domainService。

## 四、依赖方向与自由规则

内置分层不够灵活时，用通用 DSL：

```java
@ArchTest
static final ArchRule domain_must_not_use_spring = noClasses()
        .that().resideInAPackage("..domain..")
        .should().dependOnClassesThat()
        .resideInAnyPackage("org.springframework..", "javax.persistence..", "jakarta.persistence..");

@ArchTest
static final ArchRule controller_must_not_use_mapper = noClasses()
        .that().resideInAPackage("..controller..")
        .should().dependOnClassesThat().resideInAPackage("..mapper..")
        .because("Controller 必须通过 Service 访问数据，禁止直连 DAO，避免事务与校验逻辑被绕过");
```

几个高频断言：

```java
// 只有工具类/常量类才应该是 static 方法持有者
classes().that().haveSimpleNameEndingWith("Utils")
        .should().haveOnlyPrivateConstructors();

// Service 实现必须带 @Service
classes().that().implement("..service.OrderService")
        .should().beAnnotatedWith(Service.class);

// 禁止使用 java.util.Date / SimpleDateFormat
noClasses().should().dependOnClassesThat()
        .haveFullyQualifiedName("java.text.SimpleDateFormat");

// 包内类不允许被包外访问（模块封装）
classes().that().resideInAPackage("..internal..")
        .should().bePackagePrivate();
```

`because("...")` 非常关键：它把「为什么有这条规则」写进了代码。当规则失败时，CI 日志里显示的是团队的设计意图，而不是一句冷冰冰的断言 —— 这是让架构规则活下去的核心。

## 五、切片与循环依赖检测

架构腐化最隐蔽的形式是**模块间循环依赖**。ArchUnit 用 `slices()` 来做：

```java
@ArchTest
static final ArchRule no_cycles_between_modules = slices()
        .matching("com.example.(*)..")        // 第一层包作为切片
        .should().beFreeOfCycles();

@ArchTest
static final ArchRule no_cycles_between_features = slices()
        .matching("com.example.order.(*)..")  // 按业务特性切片
        .should().beFreeOfCycles();
```

`matching` 里的 `(*)` 是**捕获组**，每个捕获到的值就是一个「切片」。上面的规则等价于「order、payment、inventory 等一级模块之间不允许互相循环依赖」。

也可以显式约束切片之间的依赖方向：

```java
@ArchTest
static final ArchRule module_dependency_direction = slices()
        .matching("com.example.(*)..")
        .should().notDependOnEachOther();
```

或者允许单向：

```java
@ArchTest
static final ArchRule payment_does_not_depend_on_order = slices()
        .matching("com.example.(*)..")
        .should().beFreeOfCycles()
        .and(slices().matching("com.example.order..")
                .should().onlyDependOnClassesThat()
                .resideOutsideOfPackage("com.example.payment.."));
```

> 实践建议：循环依赖规则往往一上来就红。正确的做法不是「先关掉」，而是**先生成一份当前违规快照**（见下一节 Freezing），然后立规则、逐步还债。

## 六、冻结规则：让存量债务不阻塞增量治理

这是 ArchUnit 最实用的特性之一。老项目一上线规则就报错 300 处，谁也不敢用。`FreezingArchRule` 可以：

> 第一次运行时，把当前所有违规记进一个存储（默认 `archunit_store` 目录），**规则视为通过**；之后只有**新增**的违规才会让测试失败。

```java
@ArchTest
static final ArchRule frozen_no_cycles = FreezingArchRule.freeze(
        slices().matching("com.example.(*)..").should().beFreeOfCycles()
);
```

存储位置与行为可以配置：

```java
FreezingArchRule.freeze(rule)
    .persistIn(new FileBasedViolationStore(...))
    .associateViolationLinesVia(new ...);
```

默认存储是文本文件，**一定要提交到 Git**（和测试一起 review），这样团队能直观看到「债务在减少还是增加」。当存量清零后，把 `FreezingArchRule` 拆掉，换成原始规则即可。

## 七、Maven / Gradle 与 CI 集成

### Maven

```xml
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-surefire-plugin</artifactId>
    <configuration>
        <!-- ArchUnit 报错信息很长，加大输出 -->
        <argLine>-Xmx512m</argLine>
    </configuration>
</plugin>
```

架构测试就是普通单测，`mvn test` 会自动执行。建议：

- 把架构测试放在单独目录 `src/test/java/.../architecture/`；
- 在 CI 里**单独一个 job** 跑架构测试，失败时快速失败（`mvn test -Dtest=ArchitectureTest`），给开发者即时反馈；
- 用 `@AnalyzeClasses(packages = "com.example")` 注解方式可以在类级别统一指定导入范围：

```java
@AnalyzeClasses(packages = "com.example", importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureTest {
    @ArchTest
    static final ArchRule rule1 = ...;
    @ArchTest
    static final ArchRule rule2 = ...;
}
```

### Gradle

```groovy
tasks.register('architectureTest', Test) {
    useJUnitPlatform()
    include '**/architecture/**'
}
```

## 八、真实落地建议与常见坑

**1. 规则要少而硬，不要多而软。**
一个项目 10~20 条核心规则足够。规则太多，每次重构都在和测试打架，最后一定有人加 `@Disabled`。

**2. 用 `because()` 写清业务理由。**
「domain 不能依赖 Spring，因为领域层需要能被纯单元测试覆盖、且未来可能被抽取为独立模块」—— 这种规则活得更久。

**3. 导入范围要收敛。**
`importPackages("com.example")` 比 `importClasspath()` 快 10 倍以上。测试类里把 `JavaClasses` 做成 static 常量，避免每个测试方法重复导入。

**4. 排除生成代码。**

```java
ImportOption excludeGenerated = location -> 
        location.contains("/generated-sources/") || location.contains("/target/generated");
```

**5. 内部类与匿名类误报。**
`noClasses().that().resideInAPackage("..domain..")` 会匹配到 `..domain..` 下的内部类，多数情况符合预期；但如果只想匹配顶层类，加 `.that().areTopLevelClasses()`。

**6. ArchUnit 与 Spring 的边界。**
ArchUnit 不启动 Spring 容器，所以它**看不到**运行时的代理（比如 `@Transactional` 生成的 CGLIB 子类）。它验证的是「源码级别的静态依赖」，这恰好也是我们想要的 —— 规则简单、快、无副作用。

**7. 别用它做业务断言。**
它是架构工具，不是 Mockito 的替代品。

## 九、面试常见追问

**Q1：ArchUnit 和 SonarQube 的架构规则有什么区别？**
SonarQube 有「依赖循环」「分层」类规则，但表达力有限、需要平台、反馈慢；ArchUnit 是白盒 DSL，规则即代码、跟着仓库走、单测阶段秒级反馈，且能表达「切片」「依赖方向」「注解」这类语义化约束。二者不冲突，ArchUnit 管红线，SonarQube 管质量门禁。

**Q2：为什么说「架构要可测试」？**
因为不可测试的约束等于没有约束。文档会过期、Review 会疲劳、口头约定会被遗忘，而**测试会一直运行**。架构守护测试把「团队共识」变成「机器执行的契约」，这是架构治理从「靠人」到「靠系统」的关键一步。

**Q3：规则失败了但业务确实需要打破怎么办？**
三种处理：① 临时 `@Disabled` + TODO 责任人（最差，容易被遗忘）；② 用 `FreezingArchRule` 把这一次加入白名单并记录原因；③ 真正地去改架构（比如引入接口做依赖倒置）。推荐 ② 或 ③，并且**每一次破例都要在 PR 里被 review 到**。

**Q4：能在 ArchUnit 里做性能/复杂度约束吗？**
可以部分做（比如「Service 类方法数不超过 N」需要用 `ClassFileImporter` + 自定义 `ArchCondition`），但这类更适合交给 PMD/SonarQube。ArchUnit 的主场是**依赖与结构**。

## 十、小结

| 能力 | API |
| --- | --- |
| 分层约束 | `Architectures.layeredArchitecture()` |
| 洋葱架构 | `Architectures.onionArchitecture()` |
| 依赖方向 | `noClasses().that()...should().dependOnClassesThat()...` |
| 循环依赖 | `slices().matching("..(*)..").should().beFreeOfCycles()` |
| 命名/注解/可见性 | `classes().that().haveSimpleNameEndingWith()` / `beAnnotatedWith()` |
| 存量治理 | `FreezingArchRule.freeze(rule)` |

一句话总结：**让架构约束变成 CI 里一条会失败的测试，它才真正存在。** ArchUnit 不是银弹，但它用极低的成本，把「架构靠自觉」变成了「架构靠机器」。
