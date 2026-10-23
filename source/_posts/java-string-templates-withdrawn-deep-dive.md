---
title: 【Java 前沿】String Templates 深度解析：从 JEP 430 到被撤回，一场关于字符串拼接的设计博弈
date: 2026-10-23 08:00:00
tags:
  - Java
  - String Templates
  - JEP
  - 语法特性
  - 面试
categories:
  - Java 进阶
author: 东哥
---

# 【Java 前沿】String Templates 深度解析：从 JEP 430 到被撤回

## 前言

如果你在 2023 年关注过 JDK 21，一定记得那个看起来很美的东西：

```java
String name = "东哥";
int age = 30;
String msg = STR."我叫 \{name}，今年 \{age} 岁";
```

这就是 String Templates（字符串模板），JEP 430 在 JDK 21 作为**预览特性**引入，JDK 22 演进为 JEP 459，然后在 JDK 23 被**正式撤回（withdrawn）**。这是 Java 近十年来少见的「预览了两轮还被砍掉」的语言特性。

很多人只知道「它被砍了」，但面试里如果被追问「为什么被砍」「那现在拼字符串用什么」，答不上来就很尴尬。这篇文章把设计动机、API 形态、撤回原因、替代方案和真实踩坑一次讲透。

---

## 一、为什么 Java 需要字符串模板

先看 Java 拼接字符串的现状，四种写法各有各的难受：

```java
// 1. 加号拼接：可读性差，长表达式容易错
String sql = "select * from t_user where name = '" + name + "' and age > " + age;

// 2. StringBuilder：啰嗦，业务代码里噪音极大
String s = new StringBuilder()
        .append("name=").append(name)
        .append(", age=").append(age)
        .toString();

// 3. String.format：占位符与参数分离，参数多了容易错位
String s = String.format("name=%s, age=%d", name, age);

// 4. MessageFormat：支持命名，但单引号转义是地狱
String s = MessageFormat.format("name={0}, age={1}", name, age);
```

语言层面的痛点很明确：

1. **占位符和实参分离**，参数一多就错位，且编译期不校验类型；
2. **无法内嵌表达式**，`String.format` 只能塞值，不能算；
3. **无法做安全转义**，拼 SQL 拼 HTML 全靠人肉自觉，注入漏洞的温床；
4. **多行场景难看**，文本块（Text Block）解决了多行，但解决不了插值。

String Templates 的核心野心不是「让拼接好看点」，而是**把「模板 + 数据 → 结果」这个过程变成一个可被库接管、可校验、可转义的一等公民**。

---

## 二、API 长什么样：模板处理器才是灵魂

关键认知：String Templates 的重点**不是 `\{ }` 语法，而是「模板处理器（Template Processor）」**。语法只是糖，处理器才是安全边界。

一个模板表达式由三部分组成：

```
处理器.模板字符串
  |        |
 STR."Hello \{name}"
```

编译后等价于：

```java
StringTemplate st = StringTemplate.of(List.of("Hello ", ""), List.of(name));
String result = STR.process(st);   // 由处理器决定怎么拼
```

也就是说，`\{name}` 并不会被直接字符串化后塞进去，而是作为一个 **`StringTemplate` 对象**传给处理器，处理器拿到的是「片段列表 + 值列表」的结构化数据。这样处理器就可以：

- 对值做 **SQL 转义 / HTML 转义 / JSON 转义**；
- 校验值类型（比如只允许 `Integer`）；
- 甚至不拼接，直接把模板编译成 `PreparedStatement`。

JDK 内置了三个处理器：

| 处理器 | 作用 | 安全性 |
|---|---|---|
| `STR` | 直接字符串化拼接 | 不安全，等价于字符串拼接 |
| `FMT` | 支持 `%s` 等格式说明符（`\{name}%s`） | 不安全 |
| `RAW` | 不做任何处理，返回 `StringTemplate` 本身 | 需要自行处理 |

一个自定义处理器的例子（把模板变成预编译 SQL）：

```java
public class SqlProcessor implements StringTemplate.Processor<PreparedStatement, SQLException> {
    private final Connection conn;

    public SqlProcessor(Connection conn) { this.conn = conn; }

    @Override
    public PreparedStatement process(StringTemplate st) throws SQLException {
        StringBuilder sql = new StringBuilder();
        List<Object> args = new ArrayList<>();
        Iterator<String> frags = st.fragments().iterator();
        Iterator<Object> values = st.values().iterator();

        while (frags.hasNext()) {
            sql.append(frags.next());
            if (values.hasNext()) {
                sql.append('?');          // 值一律不拼进 SQL
                args.add(values.next());
            }
        }
        PreparedStatement ps = conn.prepareStatement(sql.toString());
        for (int i = 0; i < args.size(); i++) {
            ps.setObject(i + 1, args.get(i));
        }
        return ps;
    }
}
```

这才是模板真正的价值：**从「字符串拼装」升级为「结构化构造」**，把注入防护从「靠人记得转义」变成「处理器强制约束」。

---

## 三、为什么被撤回？四个致命问题

JEP 459 之后，JDK 23 直接 withdraw。官方给出的理由集中在几点，每一点都值得细品。

### 3.1 `\{ }` 语法与「模板即字符串」的认知冲突

Java 的用户心智里，`"..."` 就是字符串。引入 `\{` 之后，同样的双引号内部语义变了，但**只有带处理器前缀时才是模板**：

```java
String a = "Hello \{name}";        // 编译错误
String b = STR."Hello \{name}";    // OK
```

更麻烦的是嵌套、转义、文本块三种语法叠加时的歧义：文本块里 `\` 是转义符，`\{` 要不要特殊处理？`\\{` 表示什么？语言设计上一旦引入「双引号内的特殊插值字符」，向后兼容的字符串转义规则就会变得极其微妙，编译器团队和 IDE 团队都要付出巨大成本。

### 3.2 处理器参数化带来的类型系统负担

`STR` 是一个 `Processor<String, RuntimeException>`，而自定义处理器可以是任意返回类型和任意受检异常：

```java
PreparedStatement ps = SQL."""
    select * from t_user where id = \{id}
    """;
```

这导致**异常推断**变得非常复杂（`process` 抛什么，整个表达式就抛什么），而 Java 的受检异常推断本来就保守。语言团队评估后认为收益不足以抵消复杂度。

### 3.3 与既有生态的重叠

`String.format`、`MessageFormat`、文本块、各家模板引擎（FreeMarker、Thymeleaf、Mustache）已经把场景瓜分完了。String Templates 想统一江湖，但它既不能替代模板引擎（缺循环、条件、布局），又比 `String.format` 复杂得多，处于一个尴尬的中间地带。

### 3.4 安全预期落空

最初的卖点是「安全拼接」，但实际落地时：

- `STR` 是默认推荐用法，它**恰恰是不安全的**；
- 真正安全的处理器要自己写，普通业务开发不会写；
- 一旦 `STR` 成为习惯，模板注入防护反而被弱化。

用一句大白话总结：**收益不够大，复杂度太高，安全承诺兑现不了，所以砍掉重新想。**

> 面试追问：那 Java 有没有可能重新引入？
> 答：截至目前没有正式回归。社区讨论的方向更偏向「减少语法侵入」，比如用方法调用形式而非新的字符串字面量语法。但短期内不该把它当成可依赖的特性。

---

## 四、2026 年的替代方案全景对比

既然被撤回了，实际工程里我们该用什么？一张表说清。

| 方案 | 表达式支持 | 类型安全 | 自动转义 | 性能 | 适用场景 |
|---|---|---|---|---|---|
| `+` 拼接 | 否 | 编译期部分 | 否 | 差（循环内） | 极短字符串、日志少量 |
| `StringBuilder` | 否 | 否 | 否 | 好 | 循环拼接、手工控制 |
| `String.join` | 否 | 否 | 否 | 好 | 集合连接 |
| `String.format` | 否 | 否（运行期） | 否 | 中（每次解析格式串） | 简单格式化、日志 |
| `MessageFormat` | 否 | 否 | 否 | 中 | 国际化、命名占位 |
| 文本块 `"""` | 否 | — | 否 | 好 | 多行 SQL/JSON/HTML |
| 模板引擎 | 是 | 否 | 部分支持 | 中 | 页面渲染、复杂模板 |
| 日志占位符 `{}` | 否 | 否 | 否 | 好（惰性） | 日志输出 |

### 4.1 文本块 + `formatted()`：目前最实用的组合

```java
String sql = """
        select id, name, age
        from t_user
        where tenant_id = %d
          and name like '%%%s%%'
        """.formatted(tenantId, keyword);
```

注意 `%%` 的转义——文本块里 `%s` 依然会被 `formatted` 解析，这一点经常踩坑。

### 4.2 `String.format` 的 Locale 陷阱

```java
// 危险：在 locale=fr_FR / de_DE 的机器上会输出 3,14
String s1 = String.format("%.2f", 3.14);

// 正确：显式指定 Locale
String s2 = String.format(Locale.ROOT, "%.2f", 3.14);
```

线上曾经出现过「本地测试通过、海外机器金额变成 `1.234,56`」的事故，根因就是没指定 Locale。**所有和机器、金额、日期相关的格式化，一律 `Locale.ROOT` 或显式业务 Locale。**

### 4.3 `MessageFormat` 的单引号地狱

```java
// 期望输出：It's {0}
// 实际输出：Its 0     —— 单引号把 {0} 当成字面量吃掉了
String s = MessageFormat.format("It's {0}", "me");

// 正确：单引号要写成两个
String s2 = MessageFormat.format("It''s {0}", "me");
```

这也是为什么很多团队禁用 `MessageFormat` 做业务文案。

### 4.4 日志：永远用占位符，不要用拼接

```java
// 错误：无论日志级别如何，字符串都会被拼接
log.debug("user=" + user + ", req=" + JSON.toJSONString(req));

// 正确：不输出时零成本
log.debug("user={}, req={}", user, req);
```

`JSON.toJSONString(req)` 这种开销大的操作，即使被 `log.debug` 包住，只要没做 `isDebugEnabled()` 判断就依然会执行。这是最常见的性能浪费之一。

---

## 五、如果真要做「安全模板」，工程上怎么落地

没有语言特性，就用「约定 + 封装 + 静态检查」三件套。

### 5.1 封装一个类型化的 SQL 构造器

```java
public final class Sql {
    private final StringBuilder sb = new StringBuilder();
    private final List<Object> params = new ArrayList<>();

    public static Sql of(String head) {
        Sql s = new Sql();
        s.sb.append(head);
        return s;
    }

    public Sql param(Object v) {
        sb.append('?');
        params.add(v);
        return this;
    }

    public Sql append(String literalSql) {
        sb.append(' ').append(literalSql);   // 只允许拼常量片段
        return this;
    }

    public <T> List<T> query(JdbcTemplate jdbc, RowMapper<T> mapper) {
        return jdbc.query(sb.toString(), mapper, params.toArray());
    }
}
```

用法：

```java
List<User> users = Sql.of("select * from t_user where tenant_id =")
        .param(tenantId)
        .append("and name like")
        .param("%" + keyword + "%")
        .query(jdbc, userRowMapper);
```

参数永远走 `?`，拼接永远只拼常量，注入面直接归零。

### 5.2 用 ArchUnit 或自定义规则守住边界

```java
@ArchTest
static final ArchRule no_string_concat_in_sql =
    noClasses().should().callMethod(String.class, "concat", String.class)
        .because("SQL 一律使用参数化构造，禁止字符串拼接");
```

### 5.3 输出转义：HTML / JSON 场景

```java
// Spring 的 HtmlUtils 可以处理 HTML 转义
String safe = HtmlUtils.htmlEscape(userInput);

// JSON 用序列化器，永远不要手拼
String json = objectMapper.writeValueAsString(payload);
```

---

## 六、面试高频追问

**Q1：String Templates 为什么被撤回？**
答：语法侵入性（`\{` 破坏字符串字面量心智）、处理器参数化带来的类型与受检异常推断复杂度、与既有格式化/模板引擎生态重叠、以及 `STR` 默认不安全导致「安全拼接」的卖点落空。四者叠加，收益/成本比不成立。

**Q2：`STR."a \{x} b"` 和 `"a " + x + " b"` 有什么本质差别？**
答：前者编译后产生 `StringTemplate` 对象，值不被提前字符串化，处理器可以拿到结构化数据做校验与转义；后者在编译期就退化为 `StringBuilder.append`，值一定被 `String.valueOf` 处理，没有任何拦截点。所以前者是「可编程的模板」，后者是「纯拼接」。

**Q3：`String.format` 和 `MessageFormat` 怎么选？**
答：格式说明符（数字、日期、宽度）用 `String.format`；需要命名占位、国际化的固定文案用 `MessageFormat`。但 `MessageFormat` 的单引号转义极易踩坑，业务文案建议走 i18n 资源文件 + 明确规范。

**Q4：文本块里的 `%s` 需要转义吗？**
答：如果后面调用 `.formatted(...)`，需要写成 `%%s`；如果只是普通字符串，`%s` 没有特殊含义，不需要处理。

**Q5：为什么循环里不要用 `+` 拼接？**
答：`+` 编译后是 `new StringBuilder().append()`，循环内每次迭代都新建对象，复杂度从 O(n) 变成 O(n²)，且产生大量短命对象加重 GC 压力。JDK 9 之后虽然有 `invokedynamic` 优化的 `StringConcatFactory`，但那只优化单次表达式，循环仍要手写 `StringBuilder`。

**Q6：`StringBuilder` 和 `StringBuffer` 怎么选？**
答：`StringBuilder` 非线程安全但快，方法内局部变量一律用它；`StringBuffer` 每个方法都 `synchronized`，只在确实需要跨线程共享同一个缓冲时才用——而这种场景在实践中几乎不存在，正确做法是每个线程各自持有 `StringBuilder`。

---

## 七、总结

| 维度 | 结论 |
|---|---|
| 特性状态 | JDK 21 预览 → JDK 22 二次预览 → JDK 23 撤回，当前不可用 |
| 核心思想 | 模板处理器接管「片段 + 值」，实现校验与转义 |
| 撤回主因 | 语法侵入、类型复杂度、生态重叠、安全卖点落空 |
| 当前最佳实践 | 文本块 + `formatted()`；日志用占位符；SQL 参数化构造；JSON 走序列化器 |
| 长期价值 | 它提出的「结构化模板 + 处理器」思想，会影响后续 Java 在安全拼接方向的设计 |

技术选型最怕的不是「不知道新特性」，而是「不知道新特性为什么死」。String Templates 的撤回恰好说明了一件朴素的事：**语言设计里，可预测性和低心智负担，往往比语法糖更重要。** 对我们写业务的人来说，把文本块、`formatted`、参数化 SQL、日志占位符这四件事做扎实，比追一个新语法有价值得多。
