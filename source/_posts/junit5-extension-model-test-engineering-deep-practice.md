---
title: 【Java 工程化】JUnit 5 扩展模型深度解析：Extension SPI、并行执行与测试工程化落地
date: 2026-10-19 08:20:00
tags:
  - Java
  - JUnit5
  - 测试
  - 工程化
  - Spring Boot
categories:
  - Java 工程化
author: 东哥
---

# 【Java 工程化】JUnit 5 扩展模型深度解析：Extension SPI、并行执行与测试工程化落地

## 前言

大多数人用 JUnit 5 的姿势是这样的：

```java
@Test
void should_create_order() {
    Order order = service.create(new OrderCmd("SKU-1", 2));
    assertEquals(2, order.getQuantity());
}
```

会写 `@Test` 和 `assertEquals` 就够了——直到你遇到这些问题：

- 每个集成测试都要重复 `@SpringBootTest` + 建库 + 清数据，能不能自动化？
- 测试之间互相污染，单独跑通过、一起跑失败，为什么？
- CI 上 3000 个测试跑 40 分钟，怎么并行又不冲突？
- 想在每个测试前打印耗时、失败时自动截图/抓日志，写基类还是用注解？

这些问题的答案都在 **JUnit 5 的扩展模型（Extension Model）** 里。JUnit 5 相对 JUnit 4 最大的架构升级，不是 `@Test` 换了包，而是把"测试生命周期"变成了**可插拔的扩展点**。Spring Boot Test、Testcontainers、Mockito 的 `@Mock`、`@TempDir`、`@Timeout`——全都是扩展实现。

本文从架构分层讲到扩展点实现，再到并行执行与工程化落地。

---

## 一、架构：JUnit 5 是三层结构

```
┌──────────────────────────────────────────────┐
│  JUnit Jupiter（新编程模型：@Test/@Nested）    │
├──────────────────────────────────────────────┤
│  JUnit Platform（引擎注册、发现、执行、报告）    │
│    ├── jupiter-engine                        │
│    ├── vintage-engine（跑 JUnit 4/3 老测试）   │
│    └── 第三方引擎（Spock、Kotest…）            │
└──────────────────────────────────────────────┘
```

理解这一层很重要，因为：

- **IDE / Maven Surefire / Gradle 都只跟 Platform 打交道**，所以换引擎不用改构建
- **`junit-platform.properties` 是 Platform 级配置**（并行、命名、报告），不是 Jupiter 的
- **`Launcher API`** 可以让你在代码里编程式地跑测试（做自定义测试平台、测试报告聚合时很有用）

依赖上，Spring Boot 项目只需要：

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-test</artifactId>
    <scope>test</scope>
</dependency>
```

它已经带了 `junit-jupiter` + `mockito` + `assertj` + `jsonassert`。

---

## 二、Extension 模型：五个扩展点与执行顺序

JUnit 5 的扩展接口都是函数式/默认方法风格，你只需要实现关心的回调：

| 扩展接口 | 触发时机 | 典型用途 |
|---|---|---|
| `BeforeAllCallback` | 所有测试前（类级） | 启动容器、建库、加载配置 |
| `BeforeEachCallback` | 每个测试前 | 准备数据、设置 mock |
| `BeforeTestExecutionCallback` | 测试方法执行前（在 `@BeforeEach` 之后） | 计时、埋点 |
| `TestExecutionExceptionHandler` | 测试抛异常时 | 失败重试、截图、补充上下文 |
| `AfterEachCallback` / `AfterAllCallback` | 清理 | 回滚事务、停容器 |
| `ParameterResolver` | 解析方法参数 | 注入 `TestInfo`、临时目录、自定义上下文 |
| `TestInstancePostProcessor` | 实例创建后 | 依赖注入到测试实例 |

### 2.1 完整执行顺序（背下来）

```
BeforeAllCallback
  └─ @BeforeAll
       └─ BeforeEachCallback
            └─ @BeforeEach
                 └─ BeforeTestExecutionCallback
                      └─ @Test 方法
                 └─ AfterTestExecutionCallback
            └─ @AfterEach
       └─ AfterEachCallback
  └─ @AfterAll
AfterAllCallback
```

> **面试常问**：`@BeforeEach` 和 `BeforeEachCallback` 谁先执行？
> 扩展回调在外层。所以扩展可以"包裹"用户代码——这正是能做**计时、事务、重试**的原因。

### 2.2 一个完整的自定义扩展

需求：每个测试方法打印耗时，失败时输出参数。

```java
public class TimingExtension implements
        BeforeTestExecutionCallback, AfterTestExecutionCallback,
        TestExecutionExceptionHandler {

    private static final String START = "start";

    @Override
    public void beforeTestExecution(ExtensionContext ctx) {
        ctx.getStore(Namespace.create(getClass()))
           .put(START, System.nanoTime());
    }

    @Override
    public void afterTestExecution(ExtensionContext ctx) {
        long start = ctx.getStore(Namespace.create(getClass()))
                        .remove(START, Long.class);
        long costMs = (System.nanoTime() - start) / 1_000_000;
        System.out.printf("[%s] %s took %d ms%n",
                ctx.getTestClass().map(Class::getSimpleName).orElse("?"),
                ctx.getDisplayName(), costMs);
    }

    @Override
    public void handleTestExecutionException(ExtensionContext ctx, Throwable t)
            throws Throwable {
        System.err.printf("FAILED: %s, tags=%s%n",
                ctx.getDisplayName(), ctx.getTags());
        throw t;   // 必须重新抛出，否则测试会被当成通过
    }
}
```

注意 `ExtensionContext.Store`：这是扩展之间**传递状态**的官方方式，作用域有 `GLOBAL / CLASS / METHOD` 三级，避免用静态变量（并行执行时会串数据）。

### 2.3 注册扩展的三种方式

| 方式 | 写法 | 作用域 | 适用 |
|---|---|---|---|
| 声明式 | `@ExtendWith(TimingExtension.class)` | 类/方法 | 无状态扩展 |
| 编程式（实例） | `@RegisterExtension TimingExtension ext = ...` | 实例字段 | 需要构造参数、`@BeforeEach` 里配置 |
| 自动注册 | `META-INF/services/org.junit.jupiter.api.extension.Extension` | 全局 | 公司级统一扩展（如日志、租户上下文） |

**关键区别**：`@ExtendWith` 的扩展由 JUnit 反射实例化，无法注入依赖；`@RegisterExtension` 用你自己 new 的对象，可以持有状态。

```java
class OrderServiceTest {

    @RegisterExtension
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16")
            .withDatabaseName("order");

    @RegisterExtension
    TimingExtension timing = new TimingExtension();

    @Test
    void should_lock_stock() { /* ... */ }
}
```

`static` 字段 = 类级（所有测试共享，启动一次）；非 `static` = 方法级（每个测试重新创建）。Testcontainers 一定要用 `static`，否则每个测试都启一个容器，CI 直接爆炸。

---

## 三、ParameterResolver：把"测试上下文"变成参数

这是最被低估的扩展点。它让你可以这样写测试：

```java
@Test
void should_parse_config(TestInfo info, @TempDir Path tmp) {
    // info: 当前测试的显示名、标签、方法
    // tmp: 自动创建/清理的临时目录
}
```

`@TempDir` 和 `TestInfo` 就是内置的 `ParameterResolver`。

### 3.1 自定义参数解析：注入"当前用户"

```java
@Target({ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
public @interface CurrentUser {}

public class CurrentUserResolver implements ParameterResolver {
    @Override
    public boolean supportsParameter(ParameterContext pc, ExtensionContext ec) {
        return pc.isAnnotated(CurrentUser.class)
            && pc.getParameter().getType() == User.class;
    }

    @Override
    public Object resolveParameter(ParameterContext pc, ExtensionContext ec) {
        return UserContext.get();   // 从 ThreadLocal / 测试容器取
    }
}
```

配合 Spring Boot Test 使用时要注册为 `@ExtendWith` 或放进 `@SpringBootTest` 的组合注解里。**Spring 的 `SpringExtension` 本身也是一个 `ParameterResolver`**——它负责解析 `@Autowired` 等注入，这就是 Spring 测试能"自动注入"的原理。

---

## 四、生命周期与并行执行：测试互相污染的根因

### 4.1 TestInstance 生命周期

默认 JUnit 5 是 **PER_METHOD**：每个测试方法创建一个新实例。

```java
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class BatchJobTest {
    // 一个实例跑所有测试，@BeforeAll 可以是非 static
    @BeforeAll
    void init() { }
}
```

`PER_CLASS` 的好处是 `@BeforeAll` 能访问实例字段；坏处是**测试之间有状态残留**。除非你有明确的"一次初始化很贵"的需求，否则坚持 `PER_METHOD`。

### 4.2 并行执行配置

在 `src/test/resources/junit-platform.properties`：

```properties
junit.jupiter.execution.parallel.enabled=true
junit.jupiter.execution.parallel.mode.default=concurrent
junit.jupiter.execution.parallel.mode.classes.default=concurrent
junit.jupiter.execution.parallel.config.strategy=fixed
junit.jupiter.execution.parallel.config.fixed.parallelism=8
junit.jupiter.execution.parallel.config.fixed.max-pool-size=16
```

三档模式要理解清楚：

| 配置项 | 含义 |
|---|---|
| `mode.default` | 同一类内的方法之间是否并发 |
| `mode.classes.default` | 不同测试类之间是否并发 |
| `same_thread` | 串行 |

**并行最大的风险是共享资源竞争**：数据库、静态变量、端口、临时目录、Mock 的全局状态。JUnit 提供了资源锁来声明冲突：

```java
@Test
@ResourceLock("DATABASE")
void test_a() { }

@Test
@ResourceLock(value = "DATABASE", mode = ResourceAccessMode.READ)
void test_b() { }
```

同名锁的 `READ_WRITE` 互斥，`READ` 之间可并发。**这是并行化落地的关键手段**：先给所有碰 DB 的测试加 `READ_WRITE` 锁，再逐步把只读测试标成 `READ`，性能就能慢慢提上来。

### 4.3 Maven Surefire 并行（另一层并行）

注意：**Surefire 的 `forkCount` 和 JUnit 的并行是两回事**。

```xml
<plugin>
  <groupId>org.apache.maven.plugins</groupId>
  <artifactId>maven-surefire-plugin</artifactId>
  <configuration>
    <forkCount>2</forkCount>
    <reuseForks>true</reuseForks>
    <argLine>-Xmx1g</argLine>
  </configuration>
</plugin>
```

- `forkCount` = 开几个 JVM 进程（进程级隔离，内存翻倍）
- JUnit 并行 = 单进程内多线程（省内存，但共享状态）

小内存机器（比如 2C4G 的 CI）建议 `forkCount=1` + JUnit 并行 4~8 线程；大机器可以 `forkCount=2~4`。**两者叠加会把 CPU 打满，反而更慢。**

---

## 五、动态测试与嵌套：把测试写成数据驱动

### 5.1 @Nested：用内部类表达业务语义

```java
class StockServiceTest {

    @Nested
    @DisplayName("库存预占")
    class Lock {
        @Test void 库存充足时成功() { }
        @Test void 库存不足时失败() { }
        @Test void 重复请求幂等() { }
    }

    @Nested
    @DisplayName("库存释放")
    class Release {
        @Test void 释放后回到可售() { }
    }
}
```

好处是报告可读性极强，失败时一眼看出是哪个业务分支。注意：`@Nested` 内部类不能是 `static`，且外部的 `@BeforeEach` 会先执行。

### 5.2 @TestFactory：运行时生成用例

```java
@TestFactory
Stream<DynamicTest> 库存边界用例() {
    List<Integer> cases = List.of(0, 1, 99, 100, 101);
    return cases.stream().map(qty ->
        dynamicTest("购买 " + qty + " 件", () -> {
            boolean ok = service.tryLock("SKU-1", qty);
            assertEquals(qty <= 100, ok);
        }));
}
```

数据驱动测试（从 CSV/DB 加载用例）就该用它，而不是写十个几乎相同的 `@Test`。

---

## 六、Spring Boot 场景：扩展模型怎么被用起来的

`@SpringBootTest` 的本质是：

```java
@ExtendWith(SpringExtension.class)   // ← 元注解
public @interface SpringBootTest { ... }
```

`SpringExtension` 实现了几乎全部扩展点：

- `BeforeAllCallback`：启动/复用 `ApplicationContext`
- `ParameterResolver`：解析 `@Autowired`、`@Value`、`@MockBean`
- `TestExecutionExceptionHandler`：把异常包上 Spring 上下文信息

所以你能这样写：

```java
@SpringBootTest
@AutoConfigureMockMvc
class OrderApiTest {

    @Autowired MockMvc mvc;
    @MockitoBean  // Spring Boot 3.4+ 替代 @MockBean
    PaymentClient paymentClient;

    @Test
    void should_return_400_when_stock_short() throws Exception {
        mvc.perform(post("/orders").contentType(APPLICATION_JSON)
                .content("{\"skuId\":1,\"qty\":999}"))
           .andExpect(status().isBadRequest());
    }
}
```

**上下文缓存**是 Spring 测试性能的核心：相同的 `@SpringBootTest` 配置会复用同一个 `ApplicationContext`。所以：

- 不要在每个测试类上加不同的 `@TestPropertySource`（会导致缓存失效，反复启动上下文）
- 用 `@DirtiesContext` 要谨慎，它会强制重建上下文
- 用 `@MockitoBean` 而不是 `@MockBean`（3.4 起弃用）

---

## 七、工程化：让测试真正跑得快、跑得稳

### 7.1 测试分层与执行策略

| 层次 | 技术 | 数量占比 | 单测耗时 |
|---|---|---|---|
| 单元测试 | JUnit + Mockito | 70% | < 10ms |
| 切片测试 | `@WebMvcTest` / `@DataJpaTest` | 20% | 100ms~1s |
| 集成测试 | `@SpringBootTest` + Testcontainers | 10% | 1~10s |

CI 上分阶段跑：PR 阶段只跑单元 + 切片（3 分钟内），合并后跑全量集成。

### 7.2 常用内置扩展清单

| 注解/扩展 | 作用 | 坑 |
|---|---|---|
| `@TempDir` | 临时目录 | 默认清理，`cleanup=NEVER` 可保留排查 |
| `@Timeout(5)` | 超时中断 | 只能中断可响应中断的代码 |
| `@Disabled("原因")` | 跳过 | 必须写原因，否则半年后没人敢删 |
| `@Tag("slow")` | 分组 | 配合 `-Dgroups=!slow` 排除 |
| `@RepeatedTest(10)` | 重复执行 | 用于探测偶发失败 |
| `assertAll` | 聚合断言 | 避免第一个断言失败就看不到后续 |
| `@TestMethodOrder` | 指定顺序 | **强烈不建议**依赖顺序 |

### 7.3 避免"偶发失败"（flaky）的四条铁律

1. **禁止 `Thread.sleep`**：用 Awaitility 的 `await().atMost(...)` 轮询条件
2. **禁止依赖执行顺序**：每个测试自己准备数据、自己清理
3. **禁止共享可变静态状态**：用 `ExtensionContext.Store` 或 `ThreadLocal` + `@AfterEach` 清理
4. **时间要可注入**：用 `Clock` 而不是 `System.currentTimeMillis()`

```java
@Test
void should_expire_after_30_minutes() {
    Clock clock = Clock.fixed(Instant.parse("2026-10-19T00:00:00Z"), ZoneOffset.UTC);
    OrderService svc = new OrderService(clock);
    // 断言过期逻辑，而不是真的等 30 分钟
}
```

---

## 八、面试常见追问

**Q1：JUnit 4 的 `@RunWith` 和 JUnit 5 的 `@ExtendWith` 有什么区别？**
`@RunWith` 是"替换整个 Runner"，一个测试类只能有一个，扩展之间无法组合；`@ExtendWith` 可以注册**多个**扩展，按注册顺序形成责任链，粒度也更细（可加在方法上）。这是 JUnit 5 能支持 Spring + Mockito + Testcontainers 共存的原因。

**Q2：多个扩展的执行顺序怎么控制？**
实现 `Ordered` 接口或用 `@Order`，数值越小越先执行。注意 `Before*` 按顺序正序执行，`After*` 逆序执行（像栈一样包裹）。Spring 的 `SpringExtension` 通常要求排在前面。

**Q3：`@MockBean` 为什么被废弃？**
它会**污染 Spring 上下文缓存**：每个不同的 mock 组合都会创建一个新的 `ApplicationContext`，导致测试越跑越慢。Spring Boot 3.4 引入 `@MockitoBean`，配合 `MockitoTestExecutionListener` 在测试方法级重置 mock，不再重建上下文。

**Q4：怎么让集成测试在 CI 上稳定？**
Testcontainers + 固定的镜像 tag（不要 `latest`）+ 容器复用（`reuse=true`）+ 健康检查等待（`waitingFor`）+ 端口随机分配（不要写死 3306）。再加 `@Timeout` 兜底，避免卡死整个流水线。

**Q5：测试覆盖率越高越好吗？**
不是。覆盖率是"有没有测到"，不是"测得对不对"。追求行覆盖 100% 会写出大量无断言的垃圾测试。实践：核心领域逻辑 80%+ 分支覆盖，胶水代码不追求，用变异测试（PIT）验证断言的有效性。

---

## 九、总结

JUnit 5 的扩展模型是"测试框架的 SPI"，掌握它之后你会发现：

- **重复的测试脚手架** → 一个 `BeforeEachCallback` 解决
- **测试污染/偶发失败** → `@ResourceLock` + 独立数据 + 可注入时钟
- **CI 太慢** → JUnit 并行 + Surefire fork 分层配置 + 测试金字塔
- **框架怎么做到自动注入** → 都是 `ParameterResolver`

真正拉开工程师差距的，不是"会不会写断言"，而是**能不能把测试体系做成可持续演进的工程资产**。这一点，在面试里比背十个注解值钱得多。
