---
title: 【Java实战】Java 模板引擎深度对比：Freemarker vs Thymeleaf vs Velocity 原理与选型
date: 2026-08-17 08:00:00
tags:
  - Java
  - 模板引擎
  - Spring Boot
  - 实战
categories:
  - Java
  - Web开发
author: 东哥
---

# 【Java实战】Java 模板引擎深度对比：Freemarker vs Thymeleaf vs Velocity 原理与选型

## 一、为什么还要聊模板引擎？

很多同学觉得"前后端分离时代，模板引擎已经过时了"。但实际上，模板引擎在以下场景依然大量存在：

- **服务端渲染页面（SSR）**：CMS 系统、后台管理、电商详情页首屏
- **代码生成器**：MyBatis-Plus Generator、自定义代码生成工具都靠模板引擎
- **邮件/短信通知**：订单通知、验证码邮件，模板化内容渲染
- **静态站点生成**：文档站、配置生成

面试中"模板引擎的原理是什么""Thymeleaf 和 Freemarker 怎么选"也是常考题。这篇文章把三大主流模板引擎的原理、语法、性能一次性讲透。

## 二、三大引擎的前世今生

| 引擎 | 诞生 | 特点 | 现状 |
|------|------|------|------|
| Velocity | 2001 | 古老、简单、性能好 | 2010 年后停止活跃，已边缘化 |
| Freemarker | 2000 | 通用型，独立于 Web，性能强 | 活跃维护，后端渲染首选 |
| Thymeleaf | 2011 | 天然 HTML 友好，支持原型即页面 | Spring Boot 官方推荐 |

## 三、核心原理：模板引擎到底干了什么？

所有模板引擎本质都是**编译器**：把模板文件编译成可执行的 Java 代码，然后执行产出文本。

以 Freemarker 为例，渲染一个 `hello.ftl`：

```ftl
Hello, ${name}! 今天是 ${date?string("yyyy-MM-dd")}
```

底层流程是：

1. **解析（Parse）**：读取模板文本，用词法分析器拆成 Token 流（文本块、插值 `${}`、指令 `<#if>` 等），构建**抽象语法树（AST）**——Freemarker 里叫 `TemplateElement`
2. **编译（Compile）**：把 AST 编译成内部指令对象（`TextBlock`、`Interpolation`、`IfBlock` 等），这一步只做一次，模板缓存起来
3. **执行（Render）**：传入数据模型（`data-model`），遍历指令树，输出到 Writer

关键点：**解析和编译只发生一次**（首次访问后缓存），后续渲染直接走编译后的指令树，所以性能瓶颈主要在模板查找和数据模型遍历。

### Freemarker 的渲染模型

```java
Configuration cfg = new Configuration(Configuration.VERSION_2_3_33);
cfg.setDirectoryForTemplateLoading(new File("/templates"));
cfg.setDefaultEncoding("UTF-8");

Template template = cfg.getTemplate("hello.ftl");  // 解析+编译+缓存
Map<String, Object> root = new HashMap<>();
root.put("name", "东哥");
template.process(root, new OutputStreamWriter(System.out));
```

`Configuration` 是线程安全的，全局只有一个；`Template` 编译后也被缓存。**每次请求复用同一个 Template 实例**，这是性能关键。

### Thymeleaf 的渲染模型

Thymeleaf 走的是**标签属性**路线：模板就是合法 HTML，动态内容通过 `th:` 属性表达：

```html
<p th:text="${user.name}">默认姓名</p>
```

渲染时 Thymeleaf 用 **DOM 解析器（AttoParser）** 把 HTML 解析成 DOM 树，遍历节点处理 `th:*` 属性，最后序列化输出。因为基于 DOM，Thymeleaf 天然支持**原型即页面**（直接浏览器打开模板也能看到静态效果），但代价是**解析开销远大于 Freemarker 的纯文本扫描**。

### Velocity 的渲染模型

Velocity 用 `#set`、`#foreach`、`$variable` 语法，VTL（Velocity Template Language）设计得尽量让非程序员能看懂。但项目 2010 年后基本停止维护，性能也不占优，新项目不建议用。

## 四、语法能力对比

| 能力 | Freemarker | Thymeleaf | Velocity |
|------|-----------|-----------|----------|
| 条件判断 | `#if/#elseif/#else` | `th:if/th:unless` | `#if/#elseif` |
| 循环 | `#list` | `th:each` | `#foreach` |
| 内置函数 | 丰富（`?string`、`?upper_case`、`?length`） | SpringEL/OGNL 表达式 | 有限 |
| 宏/片段复用 | `#macro` | `th:fragment` + `th:replace` | `#macro` |
| 国际化 | 内置 `#springMessage` | `#{}` 消息表达式 | 需外部整合 |
| 空值处理 | `!` 默认值：`${user!"游客"}` | `th:text="${user?.name}"` | 默认输出空 |

### Freemarker 常用指令示例

```ftl
<#list users as user>
  <#if user_index == 0>
    第一名：${user.name} ${user.score!0}
  <#elseif user.age gt 18>
    ${user.name}（成年）
  <#else>
    ${user.name}（未成年）
  </#if>
</#list>
```

注意 `gt`、`lt`、`gte`、`lte` 是 Freemarker 的安全比较运算符（`>` `<` 在 XML/HTML 中要转义）。

### Thymeleaf 常用属性示例

```html
<tr th:each="user : ${users}" th:class="${userStat.index == 0} ? 'first' : ''">
  <td th:text="${user.name}">张三</td>
  <td th:text="${#numbers.formatDecimal(user.score, 1, 2)}">88.50</td>
  <td th:if="${user.age >= 18}">成年</td>
</tr>
```

## 五、性能对比：谁最快？

业界大量基准测试（如 jmh 模板引擎 benchmark）结论基本一致：

**Velocity ≈ Freemarker > Thymeleaf（自然模板模式）**

Thymeleaf 最慢，原因：
1. DOM 解析 + 序列化开销大（HTML 解析器 vs 纯文本扫描）
2. SpringEL 表达式求值比 Freemarker 的自定义表达式慢
3. `th:*` 属性节点遍历有额外开销

但注意：**性能差距在真实业务中往往被放大讨论**。如果页面本身有 DB 查询、Redis 访问，模板渲染占比很小。Freemarker 渲染 1 万次约几百毫秒，Thymeleaf 约 1-2 秒级别——对大多数后台系统无感，但对**高并发 C 端页面**选 Freemarker 更稳。

### 性能优化三板斧（以 Freemarker 为例）

```java
// 1. 开启模板缓存（默认开，生产务必确认）
cfg.setCacheStorage(new freemarker.cache.MruCacheStorage(20, 250));
cfg.setTemplateUpdateDelayMilliseconds(60000); // 开发改小，生产 60s+

// 2. 关闭不必要的功能
cfg.setWhitespaceStripping(true);   // 去除多余空白
cfg.setNumberFormat("0.##");        // 避免 Locale 相关的性能开销

// 3. 输出用缓冲 Writer
template.process(root, new BufferedWriter(outWriter, 8192));
```

## 六、Spring Boot 集成实战

### Freemarker 集成

```yaml
spring:
  freemarker:
    template-loader-path: classpath:/templates/
    suffix: .ftl
    cache: true
    charset: UTF-8
```

```java
@Controller
public class OrderController {
    @GetMapping("/order/{id}")
    public String order(@PathVariable Long id, Model model) {
        model.addAttribute("order", orderService.getById(id));
        return "order";  // 渲染 templates/order.ftl
    }
}
```

### Thymeleaf 集成（Spring Boot 默认）

```yaml
spring:
  thymeleaf:
    prefix: classpath:/templates/
    suffix: .html
    cache: true
```

```html
<!DOCTYPE html>
<html xmlns:th="http://www.thymeleaf.org">
<body>
  <h1 th:text="${order.orderNo}">订单号</h1>
</body>
</html>
```

## 七、选型建议

| 场景 | 推荐 | 理由 |
|------|------|------|
| 高并发 C 端 SSR 页面 | Freemarker | 渲染快、模板缓存成熟 |
| 邮件/短信通知模板 | Freemarker | 非 HTML 场景，纯文本模板高效 |
| 代码生成器 | Freemarker | 模板即文本，`<#list>` 生成代码非常顺 |
| 前后端协作、设计师参与 | Thymeleaf | 原型即页面，浏览器可直接预览 |
| 需要 Spring 生态深度整合 | Thymeleaf | Spring 官方推荐，SpringEL 无缝 |
| 遗留系统维护 | Velocity | 能不动就不动 |

## 八、面试常见追问

**Q1：模板引擎和 JSP 有什么区别？**
JSP 由容器（Tomcat）编译成 Servlet，强依赖 Web 容器；模板引擎是独立的库，不依赖容器，编译产物是纯文本输出逻辑，天然适合非 Web 场景（邮件、代码生成）。

**Q2：Freemarker 的 `${}` 和 `#{}` 有什么区别？**
`${}` 是插值表达式，输出变量值；`#{}` 通常用于国际化消息（配合 Spring 的 `#springMessage`）。另外 `<#...>` 是指令（if、list 等）。

**Q3：模板渲染慢怎么排查？**
① 确认模板缓存是否开启（生产环境 cache=true）；② 检查模板里是否做了复杂逻辑（循环里调 service 是大忌——模板只做展示，逻辑放 Controller）；③ 检查数据模型是否过大（整表查出再在模板里过滤，应该换成查询时过滤）；④ 用火焰图看是否卡在 `parse()`（首次加载）还是 `render()`。

**Q4：模板注入攻击（SSTI）是什么？**
如果用户输入直接拼进模板或作为表达式执行，攻击者可以注入恶意指令读取服务器文件。防御：用户输入永远只作为**数据**传入，绝不拼接进模板文本；对暴露的管理端模板上传功能做好权限控制。

## 总结

模板引擎的选型本质是**性能 vs 开发体验**的权衡：Freemarker 是"快而简"，Thymeleaf 是"美而全"。理解它们的编译原理（解析→AST→渲染）后，无论换哪个引擎都能快速上手，面试时也能讲出底层逻辑而不是背 API。
