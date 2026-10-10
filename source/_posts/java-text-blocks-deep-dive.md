---
title: 【Java 核心】文本块（Text Blocks）深度解析：缩进剥离、转义规则与模板化演进
date: 2026-10-10 08:40:00
tags:
  - Java
  - Java 基础
  - 新特性
  - 面试
categories:
  - Java
  - Java 基础
author: 东哥
---

# 【Java 核心】文本块（Text Blocks）深度解析：缩进剥离、转义规则与模板化演进

## 面试官：写 SQL 的时候字符串换行很痛苦吧？Java 15 的文本块了解吗？

这道题看起来很简单，但真正能答出"缩进是怎么剥离的""文本块和普通字符串在字节码里有什么区别"的人不多。

文本块（Text Blocks，JEP 378）是 Java 15 正式引入的语法特性。它的定位很朴素：**让多行字符串在源码里保持可读**。但它背后涉及的**缩进剥离算法（incidental whitespace stripping）**、转义规则、以及编译期常量折叠，都是很好的面试素材。

本文从语法讲到字节码，把该踩的坑一次讲清楚。

---

## 一、基本语法：三个双引号

```java
// 传统写法：换行要 \n，SQL 拼接到怀疑人生
String sqlOld = "SELECT id, name, age\n" +
                "FROM   user\n" +
                "WHERE  age > 18\n" +
                "ORDER  BY age DESC";

// 文本块写法
String sql = """
        SELECT id, name, age
        FROM   user
        WHERE  age > 18
        ORDER  BY age DESC
        """;
```

两个语法硬性要求（否则编译报错）：

1. **开头的 `"""` 之后必须换行**（只能跟空格或 Tab，不能直接接内容）；
2. **结尾的 `"""` 必须单独占一行**（前面只能有空白，之后不能再跟内容）；

```java
// ❌ 编译错误: illegal text block open delimiter sequence
String a = """SELECT 1""";

// ❌ 编译错误: 内容在结尾分隔符之后
String b = """
    hello""";

// ✅ 正确
String c = """
    hello""";   // 这个其实也是合法的，结尾 """ 前只有换行
```

等等，第三种写法里结尾 `"""` 紧跟在 `hello` 后面换行——这是合法的，因为 `"""` 前面只有换行和空白。关键在于：**结尾分隔符必须位于一行的起始空白之后、行末位置**。

---

## 二、核心机制：缩进剥离算法

这是文本块最精妙、也最容易出错的部分。

### 规则

1. **内容行的"共同最小缩进"会被剥除**——算法统计所有非空白行（含结尾 `"""` 所在行）的最小缩进，然后从每一行移除这么多空白；
2. **结尾 `"""` 的位置参与计算**——因为结尾分隔符所在行的缩进也算一个"非空白"缩进的样本，所以**把结尾 `"""` 往左移，可以控制剥离的力度**；
3. **只有"偶然空白（incidental whitespace）"会被剥离**，用 `\s` 或 `\` 明确写出的空白会被保留。

```java
String s1 = """
        Hello
        World
        """;
// 等价于 "Hello\nWorld\n"  —— 8 个空格被剥离

String s2 = """
        Hello
    World
        """;
// 等价于 "    Hello\nWorld\n"
// 最小缩进 = 4（来自 World 那一行），所以 Hello 还留 4 个空格
```

**结尾分隔符控制剥离力度：**

```java
// 结尾 """ 深度缩进 → 剥离得少
String a = """
        line1
        line2
        """;        // "line1\nline2\n"

// 结尾 """ 顶到最左 → 所有缩进都被剥离
String b = """
        line1
        line2
""";                // "line1\nline2\n"  (最小缩进=0，hello前的8空格保留)
```

第二种写法里，最小缩进是 0（因为 `"""` 在列 0），所以 `line1`、`line2` 前面的 8 个空格全部保留！这是新手最常见的困惑：**"为什么我写了文本块，格式全乱了？"**——因为结尾分隔符的位置变了剥离基准。

### 用 `\` 抑制换行（行拼接）

```java
String path = """
        /usr/local/\
        bin/java";
// 等价于 "/usr/local/bin/java"
// 行尾的 \ 表示"本行不换行"，同时不产生额外空白
```

`\` 行尾转义是"把多行拼成一行"的官方手段，**用于生成超长单行字符串（如 base64、超长 URL）**。

### 用 `\s` 保留行尾空格

```java
String table = """
        a   \s
        b\s
        """;
// 每一行的行尾空格被保留（\s 是"显式空格"）
```

**为什么需要 `\s`？** 因为 IDE 的"保存时去除行尾空格"、代码格式化工具会默默删掉行尾空格。文本块的缩进剥离算法本身**不处理行尾空白**（行尾空格会保留），但工具链会破坏它。`\s` 是告诉编译器和格式化工具："这个空格是语义的一部分，别删"。

| 转义 | 含义 | 场景 |
| --- | --- | --- |
| `\` （行尾） | 抑制换行 | 拼超长单行字符串 |
| `\s` | 显式空格 | 保护行尾空格 |
| `\n` | 显式换行 | 需要行内换行 |
| `\"` | 双引号 | 内容里有 `"` |
| `\"""` | 三个双引号 | 内容里要有 `"""` |
| `\\` | 反斜杠 | Windows 路径 |

---

## 三、字节码层面：本质还是 String 常量

这是拉开区分度的地方。文本块**不是新类型**，它在编译期就被还原成普通 `String`。

```java
String s = """
        Hello
        World
        """;
System.out.println(s.getClass());   // class java.lang.String
```

`javap -c` 看字节码：

```
0: ldc  #7   // String Hello\nWorld\n
2: astore_1
```

结论：

1. **文本块在编译期就是常量**，进入常量池，用 `ldc` 加载；
2. 因此它**参与常量折叠与字符串常量池（intern）机制**，和普通字面量没有区别；
3. **没有任何运行时开销**，不存在"文本块比字符串拼接慢"的问题——它就是在源码层面更好写的字面量。

```java
// 编译期就完成拼接，最终只有一个常量
String a = """
        Hello""";
String b = "Hello";
System.out.println(a == b);        // true（都在常量池）
System.out.println(a.intern() == b); // true

// 对比：运行时拼接不在常量池
String c = "Hel" + "lo";           // 编译期折叠，c == b 也是 true
String d = new String("Hello");    // 堆上对象，d == b 是 false
```

> **注意**：既然文本块是编译期常量，就**不能**在文本块里插值（没有变量替换能力）。这是它和"字符串模板（String Templates）"最大的区别。

### 文本块 vs 拼接 vs StringBuilder

| 方式 | 编译期/运行期 | 可读性 | 性能 |
| --- | --- | --- | --- |
| 文本块 | 编译期常量 | 最好 | 最好（无开销） |
| `+` 拼接字面量 | 编译期折叠 | 差 | 好 |
| `+` 拼接变量 | 运行期（Java 9+ 用 `invokedynamic`） | 差 | 中 |
| `StringBuilder` | 运行期 | 差 | 好（循环场景） |
| `String.format` | 运行期 | 中 | 差（解析格式串） |

**循环内拼接用 StringBuilder 或 `String.join`，静态模板用文本块，动态值用拼接或模板字符串。**

---

## 四、实战场景

### 1. SQL

```java
private static final String FIND_BY_CONDITION = """
        SELECT u.id, u.name, o.amount
        FROM   t_user u
        JOIN   t_order o ON o.user_id = u.id
        WHERE  u.status = 1
          AND  o.create_time >= ?
        ORDER  BY o.create_time DESC
        LIMIT  ?
        """;
```

> 提示：**不要把用户输入直接往文本块里塞**。文本块是编译期常量，天然免疫 SQL 注入——但一旦用 `String.format` 往里拼参数，就又回到注入风险里了。正确做法是保持 `?` 占位符交给 PreparedStatement。

### 2. JSON

```java
private static final String CREATE_ORDER_TEMPLATE = """
        {
          "orderNo": "%s",
          "amount": %d,
          "items": []
        }
        """;

String body = String.format(CREATE_ORDER_TEMPLATE, orderNo, amount);
```

### 3. HTML / 邮件模板

```java
private static final String WELCOME_MAIL = """
        <html>
          <body>
            <h2>欢迎 %s 加入</h2>
            <p>请点击 <a href="%s">这里</a> 激活账号。</p>
          </body>
        </html>
        """;
```

### 4. 正则表达式

```java
// 传统写法转义地狱
String regexOld = "(?x) ^(\\d{4})-(\\d{2})-(\\d{2})$";
// 文本块 + (?x) 自由模式，注释和空格不影响匹配
String regex = """
        (?x)                    # 自由模式：忽略空白与注释
        ^(\\d{4})               # 年
        -(\\d{2})               # 月
        -(\\d{2})$              # 日
        """;
```

> `(?x)` 是正则的"注释模式"，配合文本块简直是天作之合。这个技巧在面试里说出来很加分。

### 5. Shell 脚本 / Dockerfile 片段

```java
String deployScript = """
        #!/bin/bash
        set -e
        cd /opt/app
        ./stop.sh || true
        cp %s app.jar
        nohup java -jar app.jar > app.log 2>&1 &
        """.formatted(jarName);
```

`String.formatted()`（Java 15+）是 `String.format` 的实例方法版本，配合文本块更顺手。

---

## 五、常见坑

### 坑 1：结尾 `"""` 位置导致意外缩进

```java
// 期望 "name: tom"，实际 "        name: tom"
String bad = """
        name: tom
        """;     // 等一下——这个是剥掉的
```

真正的坑是**混合场景**：

```java
String json = """
        {
            "a": 1
        }
""";     // 结尾顶格 → 最小缩进 0 → 全部保留！
```

**规则记牢：结尾分隔符的缩进 = 剥离基准的上限。结尾顶格，什么都不剥。**

### 坑 2：IDEA 格式化会改变语义

IDE 的"重排代码"可能会移动结尾 `"""` 的位置，从而**改变字符串内容**。所以：

- 提交前用测试断言校验文本块内容；
- 或对内容敏感的文本块加 `// formatter:off` 注释；
- Java 团队一般约定：**结尾 `"""` 与内容保持同级缩进**。

### 坑 3：CRLF / LF 换行差异

文本块里的换行**在源码中是 LF**，但编译后取决于... 实际上，**文本块的行终止符在编译时会被规范化为 `\n`**（无论源文件是什么换行符）。如果业务需要 `\r\n`（比如生成 Windows 批处理文件），必须显式写：

```java
String bat = """
        @echo off\
        \r
        echo hello
        """;
```

这点在跨平台生成文件时非常容易踩坑。

### 坑 4：与 `equals` / `stripIndent` 的关系

`String.stripIndent()` 和文本块的剥离算法**是同源的**：文本块编译后等价于"字符串字面量 + stripIndent"。

```java
String a = """
        hello
        world
        """;

// 等价写法
String b = "hello\nworld\n";

System.out.println(a.equals(b));   // true
```

还有 `String.stripIndent()`（显式剥离缩进）、`String.indent(n)`（增加缩进）、`String.transform()`，这些一起构成了 Java 12+ 的字符串 API 增强。

```java
String code = "<root>\n<item/>\n</root>";
String pretty = code.indent(2);    // 每行加 2 个空格
```

---

## 六、延伸：字符串模板的"夭折"（JEP 430 → 459）

文本块最大的遗憾是**不能插值**。Java 21 曾以预览特性引入字符串模板（String Templates，JEP 430）：

```java
// Java 21 preview（已撤回）
String name = "东哥";
String msg = STR."Hello \{name}, today is \{LocalDate.now()}";
```

它引入了 `STR` / `FMT` / `RAW` 三种模板处理器，试图在**安全的前提下**做插值（模板处理器可以校验并转义，避免 SQL 注入）。

但到了 **JDK 23，字符串模板被"撤回"（withdrawn）**——官方认为设计仍有问题（模板处理器难以组合、易被误用）。

| 版本 | 状态 |
| --- | --- |
| JDK 21 | 首次预览（JEP 430） |
| JDK 22 | 第二次预览（JEP 459） |
| JDK 23+ | **撤回**（withdrawn，不再预览） |

**面试时的价值点**：能说出"字符串模板在 JDK 21/22 预览、JDK 23 被撤回"，说明你在跟踪 JLS 演进，而不是只会背语法。

**当前推荐的替代方案**：

1. 静态模板 → 文本块；
2. 少量插值 → `String.formatted()` / `String.format()`；
3. 复杂模板 → 用模板引擎（FreeMarker / Velocity / Thymeleaf）；
4. 结构化输出 → Jackson 序列化对象，**别手拼 JSON**。

---

## 七、面试常见追问

**Q1：文本块是编译期还是运行期特性？**
答：**纯编译期**。它被还原为普通 `String` 常量，进入常量池，字节码里就是一条 `ldc`，没有任何运行时开销。

**Q2：文本块的缩进是怎么处理的？**
答：计算所有非空白行（包含结尾 `"""` 所在行）的**最小公共缩进**，从每行剥离该数量的空白；用 `\s` 可保护行尾空格，用行尾 `\` 可抑制换行。

**Q3：文本块会有性能问题吗？**
答：不会，反而更好。它是常量，拼接字面量还会经过 `invokedynamic`（Java 9+），文本块直接 `ldc`。

**Q4：文本块能替代 StringBuilder 吗？**
答：不能。文本块是静态常量，**循环里的动态拼接**依然要用 `StringBuilder`。二者解决的是不同问题。

**Q5：为什么 `"""` 内不能直接写变量？**
答：因为它本质是字面量，编译期就要确定值。变量插值属于"字符串模板"的范畴，而该特性已在 JDK 23 被撤回，目前没有正式替代。

**Q6：`String.stripIndent()` 和文本块的关系？**
答：文本块的缩进处理等价于对字符串调用 `stripIndent()`，两者共享同一套"偶然空白剥离"算法。文本块可以看成语法的糖，`stripIndent()` 是它的语义内核。

---

## 总结

文本块这个小特性，值得记住四点：

1. **语法约束**：开头 `"""` 后必须换行，结尾 `"""` 必须单独占一行；
2. **缩进剥离**：按"非空白行（含结尾分隔符行）的最小缩进"剥离，**结尾分隔符位置决定剥离力度**，这是最大的坑；
3. **编译期常量**：等价于 `字面量 + stripIndent()`，进常量池，无运行时开销，不可插值；
4. **演进现状**：字符串模板（JEP 430/459）已在 JDK 23 撤回，静态模板继续用文本块，动态插值用 `formatted()` 或模板引擎。

把"缩进剥离算法"和"编译期常量 + stripIndent 等价"这两点讲透，这道题就不只是"知道有这个语法"，而是"真的懂它"。
