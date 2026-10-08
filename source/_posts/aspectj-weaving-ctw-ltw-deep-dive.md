---
title: 【AOP 进阶】AspectJ 织入深度解析：CTW、LTW 与 Java Agent 加载期织入实战
date: 2026-10-08 08:30:00
tags:
  - Java
  - AOP
  - AspectJ
  - 字节码
categories:
  - Java
  - Java 进阶
author: 东哥
---

# 【AOP 进阶】AspectJ 织入深度解析：CTW、LTW 与 Java Agent 加载期织入实战

## 面试官：Spring AOP 为什么切不到自己的方法调用？

> "我写了个 `@Log` 注解，切面里打印日志。Service 里的 `save()` 调用了同类的 `doSave()`，两个方法都加了 `@Log`，
> 结果只有 `save()` 打了日志，`doSave()` 没有。为什么？"

这是 Spring AOP 的**经典自调用失效**问题。答案大家都知道："因为 Spring AOP 是基于**运行时代理**的，`this.doSave()` 走的是原始对象，不经过代理。"

但面试官如果接着问：

> "那如果我**必须**切到 `doSave()`，怎么办？"
> "Spring AOP 和 AspectJ 到底什么关系？"
> "生产上用 AspectJ 有什么坑？"

能答完整的人就很少了。这篇文章把 AOP 的实现方式讲到底：**源码级代理 → 编译期织入（CTW）→ 加载期织入（LTW）→ Java Agent 动态重转换**，每条路径都给可运行的配置。

---

## 一、先把概念分层：AOP 的四种实现方式

| 方式 | 织入时机 | 原理 | 能否切自调用 | 典型代表 |
| --- | --- | --- | --- | --- |
| **A. 运行时代理（Spring AOP）** | 运行时 | JDK 动态代理 / CGLIB 生成子类 | ❌ | Spring 事务、`@Cacheable` |
| **B. 编译期织入 CTW** | 编译期 | AspectJ 编译器（ajc）直接改字节码 | ✅ | AspectJ + Maven 插件 |
| **C. 编译后织入 (Binary Weaving)** | 编译后 | 对已有 `.class` 做织入 | ✅ | `aspectj-maven-plugin` |
| **D. 加载期织入 LTW** | 类加载时 | `-javaagent` + ClassFileTransformer | ✅ | aspectjweaver + `aop.xml` |
| **E. 运行期重转换（Agent）** | 运行时 | `Instrumentation.retransformClasses` | ✅ | Arthas、SkyWalking、平铺 Agent |

**核心结论**：**能不能切自调用，只取决于"方法体内部的调用指令是否被改写过"**。

- 代理模式**改的是调用方持有的对象引用**，方法体内的 `this.call()` 是 `invokevirtual` 直接调用，天然绕过代理；
- 织入模式**改的是字节码本身**，会生成 `doSave$ajc$...` 之类的合成方法，把原方法的调用点替换为对织入后方法的调用，所以自调用也能切到。

---

## 二、Spring AOP：代理模式的边界

### 2.1 代理模式的三种失效

```java
@Service
public class OrderService {

    @Transactional
    public void create() {
        this.doSave();      // ❌ 事务不生效：this 是原始对象
        doSave();           // ❌ 同上
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void doSave() { /* ... */ }
}
```

**Spring AOP 的三类失效**：

1. **自调用**：`this.xxx()` / `xxx()` 不走代理；
2. **`private` / `final` / `static` 方法**：CGLIB 无法覆写 `final`，`private` 天然不可见，`static` 不是虚分派；
3. **`final` 类**：CGLIB 无法继承。
4. **（易被忽略）对象由 `new` 创建而非 Spring 管理**：根本不进容器，谈不上代理。

### 2.2 那些"绕过失效"的土办法

```java
// 办法 1：注入自己（Spring 会注入代理，不是原始对象）
@Autowired private OrderService self;
public void create() { self.doSave(); }   // ✅ 走代理

// 办法 2：AopContext.currentProxy()（需要 @EnableAspectJAutoProxy(exposeProxy = true)）
((OrderService) AopContext.currentProxy()).doSave();

// 办法 3：把 doSave 抽到另一个 Bean（最推荐，架构更清晰）
```

**办法 3 是正解**：如果你需要"同一个类里的方法有不同事务传播行为"，这**本身就是设计味道**——把逻辑拆到独立 Bean，让调用关系变成正常的跨 Bean 调用。**不要为了绕过 AOP 限制而引入 AopContext，那会让代码依赖 AOP 框架实现细节。**

### 2.3 那什么时候必须用织入？

真实需要 AspectJ 织入的场景并不多，但都很"硬"：

- **要切自调用**，且**不能改架构**（比如给第三方 SDK 的方法加监控）；
- **要切 `private` / `final` 方法**；
- **要对 `new` 出来的对象生效**（比如 `new ArrayList<>()` 也想被切）；
- **要切构造函数、字段访问、`static` 初始化**（Spring AOP 完全做不到）；
- **要极高的性能**（LTW 无代理对象，调用是普通虚方法，几乎没有开销）。

---

## 三、AspectJ 的 Join Point 模型：比 Spring 强在哪

Spring AOP 只支持 **method execution** 一种连接点。AspectJ 支持：

| 连接点类型 | Pointcut 表达式 | 说明 |
| --- | --- | --- |
| 方法执行 | `execution(* com.x..*.*(..))` | 二者都支持 |
| 方法调用 | `call(* com.x..*.*(..))` | **调用点**（在调用方织入） |
| 构造方法 | `execution(com.x.Foo.new(..))` | Spring 不支持 |
| 字段读写 | `get(int com.x.Foo.f)` / `set(...)` | Spring 不支持 |
| 静态初始化 | `staticinitialization(com.x..*)` | Spring 不支持 |
| Handler | `handler(Exception)` | 异常处理器执行点 |
| 条件 | `if(...)` / `cflow(...)` / `within(...)` | 流程/上下文条件 |

两个**面试高频**的区别：

- **`execution` vs `call`**：
  - `execution` 在**被调方法的内部**织入（方法入口）；**只要方法被执行就会触发**，包括 `this` 调用、反射调用；
  - `call` 在**调用方**织入（调用指令之前）；**只有通过这个调用点触发**，反射调用、`this` 调用（如果调用点没被织入的话）不会触发；
  - `call` 能拿到 `JoinPoint.getThis()` 是调用方对象，`execution` 拿到的是被调方对象。

```java
// 只切"在 OrderService 里调用 save 的位置"
@Pointcut("call(* com.x.OrderMapper.save(..)) && within(com.x.OrderService)")
public void saveFromOrderService() {}
```

- **`cflow`（控制流）**：切"在某个方法调用链内的所有点"。

```java
@Pointcut("call(* com.x..*.*(..)) && cflow(execution(* com.x.TxManager.begin(..)))")
public void inTransaction() {}
```

**`cflow` 性能代价很高**（需要维护控制流栈，JIT 也难以优化），生产上慎用 Large-scale `cflow`。

---

## 四、编译期织入（CTW）：Maven 配置与反编译验证

### 4.1 依赖

```xml
<dependencies>
  <dependency>
    <groupId>org.aspectj</groupId>
    <artifactId>aspectjrt</artifactId>
    <version>1.9.22</version>
  </dependency>
</dependencies>

<build>
  <plugins>
    <plugin>
      <groupId>dev.aspectj</groupId>
      <artifactId>aspectj-maven-plugin</artifactId>   <!-- 1.9.x 后维护版 -->
      <version>1.14</version>
      <configuration>
        <complianceLevel>21</complianceLevel>
        <source>21</source>
        <target>21</target>
        <showWeaveInfo>true</showWeaveInfo>
        <Xlint>ignore</Xlint>
        <aspectLibraries>
          <!-- 如果切面在别的 module，需要引用并织入其 jar -->
          <aspectLibrary>
            <groupId>com.mycompany</groupId>
            <artifactId>my-aspects</artifactId>
          </aspectLibrary>
        </aspectLibraries>
      </configuration>
      <executions>
        <execution>
          <goals>
            <goal>compile</goal>       <!-- 编译期织入 -->
            <goal>test-compile</goal>
          </goals>
        </execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

### 4.2 一个切面

```java
@Aspect
public class TimingAspect {

    private static final Logger log = LoggerFactory.getLogger(TimingAspect.class);

    /** 切 service 包下所有 public 方法，包括 private 方法调用链 */
    @Around("execution(public * com.demo.service..*(..))")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        String sig = pjp.getSignature().toShortString();
        long start = System.nanoTime();
        try {
            return pjp.proceed();
        } finally {
            long cost = (System.nanoTime() - start) / 1_000_000;
            if (cost > 200) {
                log.warn("SLOW {} cost={}ms args={}", sig, cost, Arrays.toString(pjp.getArgs()));
            }
        }
    }

    /** 只切自调用也能生效 —— 这是 CTW 相对 Spring AOP 的核心优势 */
    @Around("execution(private * com.demo.service.OrderService.doSave(..))")
    public Object aroundPrivate(ProceedingJoinPoint pjp) throws Throwable {
        return pjp.proceed();
    }
}
```

### 4.3 验证：反编译看字节码

CTW 之后，`OrderService.doSave()` 会多出一些东西：

```bash
javap -p -c target/classes/com/demo/service/OrderService.class | less
```

你会看到：

```
private void doSave();
   0: invokestatic  #12  // Method com/demo/aspect/TimingAspect.aspectOf:()Lcom/demo/aspect/TimingAspect;
   3: ...                 // 进入 around 通知
   8: invokevirtual #15  // Method doSave_aroundBody0:()V   ← 原始方法体被抽出
```

**关键点**：AspectJ 会把你的方法体抽成一个 `doSave_aroundBody0` 合成方法，然后让 `doSave()` 变成"调用切面 → 切面内调用 `_aroundBody0`"。因为**改的是 `doSave()` 本身的指令**，所以 `this.doSave()` 也会走到通知中。

### 4.4 CTW 的优缺点

| 优点 | 缺点 |
| --- | --- |
| 无反射开销，性能几乎等同手写 | **构建变慢**（ajc 编译全量） |
| 支持所有连接点（构造/字段/private/static） | 需要改造构建流程（Maven/Gradle/Bazel 都要配） |
| 自调用生效 | **IDE 直接运行会失效**（必须走 Maven 编译产物；IDEA 要开 AspectJ 支持并设 `ajc` 编译器） |
| 不依赖运行期 agent | `ajc` 与 Lombok / MapStruct 等注解处理器**顺序冲突**常见 |
| 可读（`showWeaveInfo` 可见织入日志） | 调试时栈里多一层 `_aroundBody`，略绕 |

> **Lombok + AspectJ 冲突**是最常见的踩坑：两者都要改字节码，执行顺序不对会互相覆盖（比如 `@Data` 生成的 getter 没被织入）。解决办法是把 Lombok 的注解处理放在 ajc 之前（Maven 里先 `lombok-maven-plugin` delombok，或用 `dev.aspectj` 版本的 plugin 并显式配 `-proc`）。

---

## 五、加载期织入（LTW）：不改构建，靠 Agent

LTW 是**生产环境最常用**的 AspectJ 方式：不改编译流程，只在 JVM 启动时挂一个 `-javaagent`。

### 5.1 依赖

```xml
<dependency>
  <groupId>org.aspectj</groupId>
  <artifactId>aspectjweaver</artifactId>   <!-- 内含 LTW 的 agent -->
  <version>1.9.22</version>
</dependency>
```

### 5.2 `META-INF/aop.xml`

```xml
<!DOCTYPE aspectj PUBLIC
    "-//AspectJ//DTD//EN" "https://www.eclipse.org/aspectj/dtd/aspectj.dtd">
<aspectj>
    <weaver options="-verbose -Xlint:ignore">
        <!-- 只扫描应用自己的包，指定 include 可以显著降低启动开销 -->
        <include within="com.demo..*"/>
        <!-- 排除不需要织入的部分 -->
        <exclude within="com.demo.generated..*"/>
    </weaver>

    <aspects>
        <aspect name="com.demo.aspect.TimingAspect"/>
    </aspects>
</aspectj>
```

### 5.3 启动参数

```bash
java -javaagent:/path/aspectjweaver-1.9.22.jar \
     -Dorg.aspectj.weaver.loadtime.definition=META-INF/aop.xml \
     -jar app.jar
```

Spring Boot 里更简单的写法：

```bash
java -javaagent:aspectjweaver.jar -jar app.jar
```

Spring 也会识别 LTW：加上 `@EnableLoadTimeWeaving`（Spring 的 LTW 与 AspectJ 的 LTW 是两套东西，**Spring LTW 只用于 `@Configurable` / `LoadTimeWeaverAware`，不负责切面**，容易混淆）。

### 5.4 LTW 的生产注意点

| 事项 | 说明 |
| --- | --- |
| **容器环境** | 要保证 `aspectjweaver.jar` 在镜像里，且路径稳定（别用 `/root/.m2/...`） |
| **启动开销** | 织入发生在类加载时，**首部类加载变慢**，一般 +5%~20% 启动时间 |
| **`include` 精确化** | 不写 `include` 会扫全部加载的类，启动暴慢；**务必精确到包** |
| **`-Xlint`/`-verbose`** | 排查期开，生产关（日志噪音） |
| **类卸载/热部署** | Spring Boot DevTools 重启时类加载器换了，agent 会重复织入，可能出诡异问题 |
| **GraalVM Native** | LTW 基于 `java.lang.instrument`，**native image 不支持**，必须改 CTW 或放弃 AOP |

---

## 六、运行期重转换：Agent 的 `retransformClasses`

SkyWalking、Arthas、Pinpoint 这类 APM/诊断工具，用的是**第三种**方式：Java Agent 在运行时**重新转换已加载的类**。

### 6.1 `ClassFileTransformer` 原型

```java
public class RetransformAgent {

    public static void premain(String args, Instrumentation inst) {
        inst.addTransformer(new TraceTransformer(), true /* canRetransform */);
    }

    public static void agentmain(String args, Instrumentation inst) throws Exception {
        inst.addTransformer(new TraceTransformer(), true);
        // 对已经加载的目标类做重转换
        for (Class<?> c : inst.getAllLoadedClasses()) {
            if (inst.isModifiableClass(c) && c.getName().startsWith("com.demo.service")) {
                inst.retransformClasses(c);
            }
        }
    }

    static class TraceTransformer implements ClassFileTransformer {
        @Override
        public byte[] transform(ClassLoader loader, String className,
                                Class<?> classBeingRedefined,
                                ProtectionDomain pd, byte[] classfileBuffer) {
            if (!className.startsWith("com/demo/service")) return null;  // 不关心返回 null
            // 用 ASM/ByteBuddy 在方法前后插入计时逻辑
            return TraceBytecodeWeaver.weave(classfileBuffer);
        }
    }
}
```

### 6.2 为什么 APM 都用 Agent 而不是 AspectJ

| 维度 | AspectJ LTW | Java Agent + ASM/ByteBuddy |
| --- | --- | --- |
| 触发时机 | 类加载时 | 类加载时 **或运行时重转换** |
| 是否可动态启停 | ❌ | ✅（agentmain 可随时附着） |
| 定位 | 业务 AOP 切面 | **可观测性 / 诊断 / 无侵入增强** |
| 生态 | AspectJ 语法 | ByteBuddy 的 `Advice`/`AgentBuilder` 更灵活 |
| 典型 | 日志、权限、重试 | SkyWalking、Arthas、JProfiler、New Relic |

**ByteBuddy 的 `AgentBuilder`** 是现在的主流写法，语法比裸 ASM 友好得多：

```java
new AgentBuilder.Default()
    .type(ElementMatchers.nameStartsWith("com.demo.service"))
    .transform((builder, type, cl, module, pd) ->
        builder.method(ElementMatchers.isPublic())
               .intercept(Advice.to(TimingAdvice.class)))
    .installOn(inst);
```

### 6.3 `retransform` 的限制（面试加分点）

1. **不能增删字段/方法、不能改方法签名、不能改父类** —— 只能改方法体；
2. **不能改类结构**，否则会抛 `UnsupportedOperationException`；
3. **重转换对已 JIT 编译的方法需要去优化（deoptimize）**，有短暂性能波动；
4. **`ClassFileTransformer` 返回 `null` 表示不修改**，这是约定，不要返回空数组（会清空类）；
5. **类已被 `retransform` 后，再次 `retransform` 传的是"上一次织入后的字节码"**，因此要保证织入是**幂等**的，否则会叠加多层增强（典型事故：双份日志、双份耗时）。

### 6.4 用 Arthas 现场看看有没有被织入

```bash
# 反编译某个方法，看是否有 agent 插入的代码
jad com.demo.service.OrderService
# 查看类加载器 / 是否被 transform
sc -d com.demo.service.OrderService
```

---

## 七、怎么选：一张决策表

| 需求 | 推荐方案 |
| --- | --- |
| 事务、缓存、简单日志（Spring Bean 方法） | **Spring AOP**（代理） |
| 切自调用 / private / final | **CTW 或 LTW** |
| 切第三方 jar 里的类 | **Binary Weaving（对 jar 织入）或 LTW** |
| 想在运行时动态开关 | **Java Agent + ByteBuddy** |
| APM / 链路追踪 / 无侵入诊断 | **Java Agent（Agent 生态）** |
| GraalVM Native Image | **CTW**（LTW/Agent 都不行） |
| 极简构建，不想动 pom | **LTW**（加 `-javaagent` 而已） |

---

## 八、性能：三种方式的量级

用 JMH 粗测（同一方法调用 1 亿次，纳秒级）：

| 方式 | 单次额外开销 | 说明 |
| --- | --- | --- |
| 无 AOP | ~2 ns | 基线（虚方法调用） |
| AspectJ CTW/LTW（无通知执行） | ~3~5 ns | 仅多一次判断/调用 |
| Spring AOP（CGLIB） | ~30~80 ns | 反射调用链 + `ReflectiveMethodInvocation` |
| Spring AOP（JDK 动态代理） | ~40~120 ns | 多一层 `Method.invoke` |

**结论**：AspectJ 织入比 Spring 代理**快一个数量级**，但**对绝大多数业务系统都不是瓶颈**——一次 DB 查询就是几百微秒，省几十纳秒毫无意义。**所以选型的第一顺位永远是"能不能满足需求"，而不是"快不快"。**

---

## 九、面试常见追问

**Q1：Spring AOP 和 AspectJ 的关系？**
Spring AOP 是**独立的代理实现**，它**借用了 AspectJ 的注解（`@Aspect`/`@Pointcut`）和 Pointcut 表达式语法**，但不使用 AspectJ 的织入器（除非你显式启用 CTW/LTW）。**"注解是 AspectJ 的，引擎是 Spring 自己的"**——这是最容易被混淆的一点。

**Q2：Spring AOP 能切 `private` 方法吗？**
不能。CGLIB 覆写不了 `private`；`@Transactional` 加在 private 方法上**会被静默忽略**（有的版本会警告）。AspectJ 可以。

**Q3：`@Transactional` 加在接口上还是实现类上？**
都可以，但注解本身**不会被继承**（`@Inherited` 只对类有效）。`@Transactional` 通过 `TransactionAttributeSource` 在运行时查找，能处理接口方法，但**能标在实现类上就标在实现类上**，语义最清晰。

**Q4：LTW 会不会影响线上稳定性？**
LTW 增加类加载时间，并可能在织入失败时报 `ClassFormatError`。**必须做全量集成测试 + 灰度**。另外 `include` 一定精确，否则启动会从 10 秒变成 60 秒。

**Q5：为什么 Agent 重转换会"双份日志"？**
`retransformClasses` 会把**当前字节码**（可能已含上次增强）再喂给 transformer。如果你的 transformer 不判断"是否已增强"，就会二次插入。**标准做法**：用 ByteBuddy 的 `alreadyInstrumented` 检查，或在类里打标记字段。

**Q6：动态 AOP 会破坏可观测性吗？**
会带来困扰：栈里多 `_aroundBody`、堆 dump 里多合成方法、`javap` 与源码对不上。**建议**：① 只在必要模块开 AOP；② 用 `showWeaveInfo` 记录织入了哪些类；③ 给 AOP 生成的日志打统一 tag，方便识别。

---

## 十、总结

AOP 的四种实现，本质是"**在哪个阶段修改字节码**"的选择：

```
源码 ──[CTW: ajc]──> class ──[Binary Weaving]──> jar
                       │
                       ├── 类加载 ──[LTW: aspectjweaver]──> JVM 内的 Class
                       └── 运行中 ──[Agent: retransform]──> 重新定义的 Class

而 Spring AOP 不碰字节码 —— 它在运行期"造一个替身对象"。
```

记住三句话：

1. **代理改的是引用，织入改的是指令** —— 这就是"自调用能不能切"的根因；
2. **能用 Spring AOP 就别上 AspectJ** —— 复杂度、构建侵入、调试成本都是真实成本；
3. **Agent 是运行期 AOP 的终极形态** —— 它撑起了整个 Java 可观测性生态。

下次有人问你"Spring AOP 切不到自调用怎么办"，你可以先答三种工程解法（拆 Bean / 注入代理 / `AopContext`），再补一句"如果这些都不行，说明你需要 AspectJ 的织入能力，CTW 或 LTW 都能切 `private` 和 `this` 调用"——这一层，就已经甩开大部分候选人了。
