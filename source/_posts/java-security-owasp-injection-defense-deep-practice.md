---
title: 【Java 安全】OWASP 注入类漏洞深度防御：SQL 注入、XSS、SSRF 与安全编码
date: 2026-09-17 08:00:00
tags:
  - Java
  - 安全
  - OWASP
categories:
  - Java
  - 安全
author: 东哥
---

# 【Java 安全】OWASP 注入类漏洞深度防御：SQL 注入、XSS、SSRF 与安全编码

## 面试官：用了 MyBatis，还会有 SQL 注入吗？

不少人以为"上了 ORM 框架就天然安全"，这是一个危险的错觉。真实世界里，注入类漏洞（Injection）常年霸榜 OWASP Top 10，而 Java 项目里最常见的翻车点恰恰是：

```xml
<!-- 看似"参数化了"，其实 # 被写成了 $ -->
<select id="query" resultType="User">
    SELECT * FROM users WHERE name LIKE '%${keyword}%'
</select>
```

`${}` 是**字符串拼接**，`#{}` 才是预编译占位符。一行符号之差，注入通道就开了。

本文不堆清单，而是把注入类漏洞的**成因模型**讲清楚：为什么预编译能防注入、什么情况下预编译会失效、XSS 与 SSRF 的本质区别，以及 Java 侧可落地的防御体系。

## 一、注入的本质：数据被当成了代码

所有注入类漏洞共享同一个根因：

> **系统没有严格区分"数据"和"代码/指令"，把外部输入当成了可执行结构的一部分。**

- SQL 注入：输入被拼进 SQL 语句结构；
- XSS：输入被拼进 HTML/JS 结构；
- 命令注入：输入被拼进 shell 命令；
- SSRF：输入被当成"要去访问的目标"，间接命令了服务端发起请求；
- 表达式注入（SpEL/OGNL）：输入被拼进表达式语言并被求值。

所以防御的核心不是"过滤危险字符"，而是**让输入永远只能待在数据位置**。

## 二、SQL 注入：预编译为什么有效

### 2.1 协议层面的区别

```java
// ❌ 拼接：数据库收到的是"一条完整的、结构已定的 SQL"
String sql = "SELECT * FROM users WHERE name = '" + name + "'";
stmt.executeQuery(sql);

// ✅ 预编译：数据库收到"SQL 模板 + 参数值"，两者分开发送
PreparedStatement ps = conn.prepareStatement("SELECT * FROM users WHERE name = ?");
ps.setString(1, name);
ps.executeQuery();
```

预编译（Prepared Statement）的安全性是**协议级**的：模板先被解析成语法树（此时结构已冻结），参数后到，只能填进占位符对应的数据槽，**不可能改变语法结构**。

即使参数是 `' OR '1'='1`，数据库也只会去匹配一个"名字叫 `' OR '1'='1` 的用户"，不会把它当条件。

### 2.2 `#{}` 与 `${}` 的边界

| 写法 | 机制 | 安全性 |
| --- | --- | --- |
| `#{}` | `PreparedStatement` 占位符，参数绑定 | 安全 |
| `${}` | 直接字符串替换 | **不安全** |
| `@Param` + `#{}` | 同上 | 安全 |
| `ORDER BY ${col}` | 无法预编译列名 | 必须白名单校验 |

必须用 `${}` 的场景其实只有**结构型参数**：动态表名、动态列名、`ORDER BY` 字段。此时唯一正确做法是**白名单枚举**：

```java
private static final Set<String> SORTABLE = Set.of("created_at", "amount", "id");

public List<Order> list(String sortBy, boolean asc) {
    String col = SORTABLE.contains(sortBy) ? sortBy : "created_at";
    String dir = asc ? "ASC" : "DESC";
    // col/dir 均来自白名单常量，不含用户原始输入
    return mapper.list(col, dir);
}
```

显式拒绝在 `ORDER BY` 上做任何"转义"——转义规则随数据库方言变化，白名单是唯一可靠的边界。

### 2.3 二次注入与编码绕过

- **二次注入**：数据先被安全地存进库（比如存了 `admin'--`），后来被**读出后拼接**进另一条 SQL。防御关键：**任何"回显拼接"都要重新走参数化**，不要因为"这是自己库里的数据"就放松。
- **宽字节注入**：`GBK` 编码下，`%df%27` 中的 `%df` 与转义符 `\`（`%5c`）拼成合法汉字，导致转义失效。现代做法是**全链路 UTF-8**，并且根本不用"转义型"防御。
- **HTTP 参数污染（HPP）**：`?id=1&id=2'` 场景下不同框架取值策略不同，可能绕过 WAF 规则。防御仍是参数化，而不是靠 WAF。

## 三、XSS：输出编码，而非输入过滤

XSS 的本质是"用户输入作为 HTML/JS 结构被浏览器执行"。防御原则只有一条：**按输出上下文做编码**。

| 输出位置 | 正确编码 | 错误做法 |
| --- | --- | --- |
| HTML 文本 | HTML 实体编码（`<` → `&lt;`） | 只过滤 `<script>` |
| HTML 属性 | HTML 属性编码 + **引号包裹** | 不加引号 |
| JS 变量 | JS 字符串编码（`\x3c`） | 用 HTML 编码糊弄 |
| URL 参数 | URL 编码 | 直接拼接 |
| CSS | CSS 转义 | — |

不同上下文需要不同编码器，这也是"XSS 过滤器"这条路走不通的原因——**同一个字符在 HTML 文本里需要转义，在纯数字上下文里可能完全多余**。

Java 侧落地：

```java
// Thymeleaf 默认转义，th:utext 才是"不转义"，慎用
<p th:text="${userInput}">safe</p>

// JSON 响应（前后端分离）用 Jackson 默认即可，
// 但要注意 Spring Boot 2.x 的 setSerializationInclusion 与 HTML 转义配置差异
```

前端再加一道 CSP：

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; object-src 'none'
```

CSP 是**纵深防御**：即使某处编码漏了，内联脚本也执行不了。注意别用 `unsafe-inline`，否则等于白配。

### 存储型 XSS 的特殊之处

存储型 XSS 的载荷躺在数据库里，**任何读该字段的页面都是受害者**。这意味着：

- 富文本场景（评论、CMS）不能简单全转义，需要**HTML 白名单净化**（如 OWASP Java HTML Sanitizer）；
- 净化必须发生在**写入时 + 读出时**双保险，且要防 mutation XSS（净化后浏览器解析结果与净化器理解不一致）。

## 四、SSRF：服务端被你当成了代理

SSRF（Server-Side Request Forgery）指攻击者控制服务端发起请求，典型入口是"图片 URL 导入""Webhook 回调""在线抓取"。

```java
// ❌ 直接把用户输入的 URL 交给 HttpClient
String url = request.getParameter("url");
HttpResponse resp = httpClient.send(HttpRequest.newBuilder(URI.create(url)).GET().build(), ...);
```

攻击者会传入：

- `http://169.254.169.254/latest/meta-data/` —— 云元数据服务，直接偷凭证（AWS/GCP/Azure 都中招过）；
- `http://127.0.0.1:6379/` —— 打内网 Redis；
- `http://internal-admin.svc.cluster.local/` —— K8s 集群内服务；
- `file:///etc/passwd` —— 本地文件读取（取决于客户端实现）。

### 4.1 三层防御

**第一层：协议白名单**

```java
private static final Set<String> ALLOWED_SCHEMES = Set.of("http", "https");

URI uri = URI.create(rawUrl);
if (!ALLOWED_SCHEMES.contains(uri.getScheme().toLowerCase())) {
    throw new IllegalArgumentException("scheme not allowed");
}
```

**第二层：解析后校验 IP（防 DNS Rebinding）**

关键顺序是"**先解析 → 校验 IP → 再用解析出的 IP 连接**"，而不是"校验域名后再让客户端自己解析"：

```java
InetAddress addr = InetAddress.getByName(uri.getHost());
if (addr.isLoopbackAddress() || addr.isAnyLocalAddress() || addr.isSiteLocalAddress()
        || addr.isLinkLocalAddress() || addr.isMulticastAddress()) {
    throw new IllegalArgumentException("private address not allowed");
}
// 还需拒绝：100.64.0.0/10(CGNAT)、169.254.0.0/16、::1、fc00::/7 等
```

注意 `getByName` 与真正建连之间仍存在 **TOCTOU 窗口**（DNS 可返回不同结果）。严格场景要用**自定义 DNS 解析器 + 连接级 IP 固定**，或干脆走正向代理并统一做策略。

**第三层：网络隔离**

- 出网走统一 egress proxy，只允许白名单域名；
- 内网元数据服务加 IMDSv2 / 或直接在网络策略上阻断；
- K8s NetworkPolicy 限制 pod 出网。

### 4.2 常见绕过手法与对策

| 绕过 | 例子 | 对策 |
| --- | --- | --- |
| 十进制/八进制 IP | `http://2130706433/` = 127.0.0.1 | 统一解析成 `InetAddress` 再判断 |
| 短域名/重定向 | `http://bit.ly/xxx` 302 到内网 | **禁止跟随重定向**，或每跳都校验 |
| URL 解析差异 | `http://evil.com@127.0.0.1/` | 用同一套标准 URI 解析器，别手写正则 |
| IPv6 映射 | `http://[::ffff:127.0.0.1]/` | 归一化到 IPv4 再判断 |

## 五、另外两类高频注入

### 5.1 命令注入

```java
// ❌
Runtime.getRuntime().exec("ping -c 1 " + userInput);

// ✅ 用数组形式，参数与命令分离
new ProcessBuilder("ping", "-c", "1", userInput).start();
```

`ProcessBuilder` 的变参形式**不经过 shell**，因此 `;`、`|`、`&&` 都只是普通字符。若必须用 shell，则输入必须白名单（如只允许 `[A-Za-z0-9.-]+`）。

### 5.2 SpEL / OGNL 表达式注入

Spring 里只要出现"用户输入参与表达式求值"，就是高危：

```java
// ❌ 用户能控制 expression 时，可以执行任意代码
SpelExpressionParser parser = new SpelExpressionParser();
parser.parseExpression(userInput).getValue();
```

类似风险点还有：

- MyBatis 动态 SQL 里的 `${}`
- 日志配置的 JNDI（Log4Shell 的根因）
- 反序列化入口（`ObjectInputStream`、部分 Fastjson 版本）

**通用原则**：表达式/反序列化/模板引擎这类"能执行代码的组件"，绝不能让外部输入决定其**结构**。

## 六、Java 安全编码清单

1. **参数化一切查询**：MyBatis 用 `#{}`，JPA 用 `setParameter`，JDBC 用 `PreparedStatement`；动态表名/列名走白名单。
2. **输出按上下文编码**：模板引擎别用"不转义"API；JSON 接口 + CSP。
3. **出网请求做白名单 + 重定向管控 + IP 校验**。
4. **命令执行用数组形式**，禁 shell 拼接。
5. **不信任任何反序列化入口**：用 `ObjectInputFilter`（JEP 290）做类白名单。
6. **依赖安全**：接入 OWASP Dependency-Check 或 Snyk，把 CVE 拦截在构建期。
7. **最小权限**：数据库账号别用 root，应用账号只给必要表的 DML；云上元数据走 IMDSv2。
8. **WAF 是补充不是主力**：WAF 规则可被绕过，它挡的是"脚本小子"，不是设计缺陷。

```java
// ObjectInputFilter 示例：只允许安全类型反序列化
ObjectInputStream ois = new ObjectInputStream(input);
ois.setObjectInputFilter(info -> {
    Class<?> clazz = info.serialClass();
    if (clazz == null) return ObjectInputFilter.Status.UNDECIDED;
    return ALLOWED_WHITELIST.contains(clazz.getName())
            ? ObjectInputFilter.Status.ALLOWED
            : ObjectInputFilter.Status.REJECTED;
});
```

## 面试追问连击

**追问 1：预编译为什么能防注入？**
因为 SQL 模板与参数在**协议层面分开发送**，模板先被解析固化语法结构，参数只能填充数据位，无法改变结构。转义型防御靠"规则猜输入"，预编译靠"结构上不可能"，量级不同。

**追问 2：`#{}` 一定安全吗？**
在参数位置上是。但如果 `${}` 用于拼接表名、列名、`ORDER BY`，预编译救不了——那不是参数位置，而是结构位置。所以答案取决于**位置**，而不只是符号。

**追问 3：XSS 防御应该过滤输入还是编码输出？**
编码输出。同一份输入在不同上下文（HTML/JS/URL/CSS）需要不同编码，输入过滤无法预知输出上下文，必然过严或过松。输入侧可以做校验（拒绝明显非法），但安全边界在输出侧。

**追问 4：SSRF 里为什么"校验域名"不够？**
DNS 可被攻击者控制，且存在解析与连接之间的 TOCTOU 窗口（DNS Rebinding）；此外重定向会让校验过的 URL 跳到内网。所以必须"解析后校验 IP + 禁止跟随重定向 + 网络层隔离"三件套。

**追问 5：Spring Boot 项目怎么系统化落地上述防御？**
构建期：Dependency-Check / CodeQL 静态扫描；编码期：统一切面封装出网请求（统一做白名单与 IP 校验）、统一参数化 DAO 规范；运行期：CSP、最小权限、WAF + 异常告警；再加上定期的渗透测试。安全不是某个注解，而是**一条从编码到运行时的流水线**。

## 小结

- 注入的共同根因是"数据被当成代码"，防御的共同解法是"结构与数据分离"。
- SQL：`#{}` 参数化，结构型参数用白名单；警惕二次注入与宽字节。
- XSS：按输出上下文编码 + CSP 纵深防御 + 富文本走净化白名单。
- SSRF：协议白名单、解析后校验 IP、禁重定向、网络隔离。
- 命令执行用数组形式；表达式与反序列化永远不让外部决定结构。

安全编码的性价比极高：**上面每一条都只需要改几行代码，而一个注入漏洞可能直接导致整库泄露**。这笔账，值得每个后端工程师算清楚。
