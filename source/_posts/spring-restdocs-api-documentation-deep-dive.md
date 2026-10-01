---
title: 【Spring Boot 实战】Spring REST Docs 深度解析：测试驱动 API 文档、Asciidoctor 与契约一致性
date: 2026-10-01 08:00:00
tags:
  - Java
  - Spring Boot
  - REST Docs
  - API 文档
categories:
  - Java
  - Spring 全家桶
author: 东哥
---

# 【Spring Boot 实战】Spring REST Docs 深度解析：测试驱动 API 文档、Asciidoctor 与契约一致性

## 面试官：你们项目的接口文档是怎么维护的？

这几乎是一道送命题。回答"用 Swagger 注解自动生成"的人，通常会被追问下一句：

> "那接口改了，文档忘了改怎么办？谁能保证文档和实现一致？"

Swagger / SpringDoc 的思路是**从代码注释和注解反推文档**，本质上文档是"实现的一种投影"。而 Spring REST Docs 走的是完全相反的路子：**文档由测试用例生成，测试失败则构建失败**。也就是说，文档不是"写"出来的，而是"测"出来的——文档和接口的一致性由 CI 强制保证。

这篇文章我们从问题出发，一路拆到源码级原理、Asciidoctor 处理链、再讲到生产实践的取舍。

## 一、Swagger 系方案的三个根本痛点

先把问题说清楚，才能理解 REST Docs 的设计动机。

| 维度 | Swagger / SpringDoc | Spring REST Docs |
| --- | --- | --- |
| 文档来源 | 代码注解 + 反射扫描 | 集成测试的请求/响应快照 |
| 一致性保证 | 靠人自觉 | 测试失败 → 构建失败 |
| 侵入性 | 注解污染业务代码 | 业务代码零侵入 |
| 请求/响应示例 | mock 手写或反射推导 | 真实请求/响应的真实数据 |
| 生成时机 | 应用启动时扫描 | 构建时（测试阶段） |
| 主要产物 | OpenAPI JSON + UI | AsciiDoc → HTML/PDF |

痛点一：**注解即文档，注解即谎言**。`@ApiParam("用户ID")` 写错了没人管，因为编译器不检查注解的语义。接口把 `Long` 改成 `String`，注解照样编译通过，UI 上仍显示旧类型。

痛点二：**示例数据是编的**。Swagger UI 里的示例 JSON 往往是手写的，字段名和真实 DTO 对不上、日期格式和 Jackson 配置不一致，前端照着调接口直接踩坑。

痛点三：**文档是"启动时可得的"，不是"构建时可验证的"**。只有应用跑起来扫描一遍才知道文档长什么样，没有任何机制能阻止一份错误文档被发布。

REST Docs 的核心洞察是：**唯一可信的接口契约，是一次真实调用留下的痕迹**。所以它把文档生成挂在了 `MockMvc` / `WebTestClient` / `RestAssured` 的调用链后面。

## 二、最小可运行示例

### 2.1 引入依赖

```xml
<dependency>
    <groupId>org.springframework.restdocs</groupId>
    <artifactId>spring-restdocs-mockmvc</artifactId>
    <scope>test</scope>
</dependency>
```

Gradle 项目还要加 Asciidoctor 插件：

```groovy
plugins {
    id 'org.asciidoctor.jvm.convert' version '4.0.2'
}

ext {
    snippetsDir = file('build/generated-snippets')
}

test {
    outputs.dir snippetsDir
    useJUnitPlatform()
}

asciidoctor {
    inputs.dir snippetsDir
    dependsOn test
    attributes 'snippets': snippetsDir
}
```

### 2.2 业务代码（零注解）

```java
@RestController
@RequestMapping("/api/users")
public class UserController {

    private final UserService userService;

    public UserController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/{id}")
    public UserVO getById(@PathVariable Long id) {
        return userService.getById(id);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public UserVO create(@RequestBody @Valid UserCreateCmd cmd) {
        return userService.create(cmd);
    }
}
```

注意：**没有一行 Swagger 注解**。这是 REST Docs 最大的工程价值之一——业务代码保持干净。

### 2.3 测试即文档

```java
@WebMvcTest(UserController.class)
@AutoConfigureRestDocs(outputDir = "target/generated-snippets")
class UserControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private UserService userService;

    @Test
    void getUser() throws Exception {
        when(userService.getById(1L))
                .thenReturn(new UserVO(1L, "东哥", "dong@example.com"));

        mockMvc.perform(get("/api/users/{id}", 1L)
                        .accept(MediaType.APPLICATION_JSON))
                .andExpect(status().isOk())
                // 断言 + 文档生成，同一行完成
                .andDo(document("user/get-user",
                        pathParameters(
                                parameterWithName("id").description("用户 ID")
                        ),
                        responseFields(
                                fieldWithPath("id").description("用户 ID"),
                                fieldWithPath("name").description("用户名"),
                                fieldWithPath("email").description("邮箱")
                        )
                ));
    }
}
```

`andDo(document(...))` 是关键：它在断言通过之后，把这次真实请求的 `curl` 命令、HTTP 请求头、请求体、响应头、响应体、路径参数、请求字段、响应字段全部切成了**片段（snippet）**，落到 `target/generated-snippets/user/get-user/` 下：

```
user/get-user/
├── curl-request.adoc
├── http-request.adoc
├── http-response.adoc
├── httpie-request.adoc
├── request-body.adoc
├── response-body.adoc
├── path-parameters.adoc
└── response-fields.adoc
```

## 三、snippet 机制源码级剖析

面试如果要区分"用过"和"懂"，就看这一段。

### 3.1 入口：RestDocumentationResultHandler

`document("user/get-user", ...)` 返回的是一个 `RestDocumentationResultHandler`，它实现了 `ResultHandler` 接口。`MockMvc` 在请求执行完毕后，会把 `MvcResult` 依次交给注册的 `ResultHandler`：

```java
public interface ResultHandler {
    void handle(MvcResult result) throws Exception;
}
```

`RestDocumentationResultHandler.handle()` 内部做三件事：

1. 从 `MvcResult` 中取出请求、响应、`HandlerMethod`、`Exception`；
2. 组装一个 `Operation`（文档操作）；
3. 遍历所有 `Snippet`，让每个 snippet 自己决定要不要写文件、写什么内容。

```java
// 简化后的核心逻辑
public void handle(MvcResult result) throws Exception {
    AssertionErrors.assertTrue(...);
    this.snippetConfigurer.operationPreprocessors()
            .apply(new OperationRequest(...), operation);
    for (Snippet snippet : this.snippets) {
        this.writer.write(snippet, operation.getOutputDirectory());
    }
}
```

### 3.2 Snippet 抽象

```java
public interface Snippet {
    void document(Operation operation) throws IOException;
}
```

每个 snippet 都是"从 `Operation` 里抽一部分信息、渲染成 AsciiDoc 文本"的策略对象：

| Snippet | 输出内容 |
| --- | --- |
| `CurlRequestSnippet` | 可直接执行的 curl 命令 |
| `HttpRequestSnippet` | 原始 HTTP 请求报文 |
| `HttpResponseSnippet` | 原始 HTTP 响应报文 |
| `RequestFieldsSnippet` | 请求体字段 + 类型 + 描述 + 约束 |
| `ResponseFieldsSnippet` | 响应体字段，含 JSONPath |
| `PathParametersSnippet` | 路径参数表 |
| `RequestParametersSnippet` | query 参数表 |
| `RequestHeadersSnippet` | 请求头表 |
| `LinksSnippet` | HATEOAS 链接 |
| `RequestPartsSnippet` | multipart 分片 |

### 3.3 字段路径是怎么推导出来的

`ResponseFieldsSnippet` 继承自 `AbstractFieldsSnippet`，写文件时会调用 `createModel()`，把每个 `FieldDescriptor` 的 `path` 展开成带 JSONPath 的表格：

```java
FieldDescriptor fieldWithPath("data.items[].name")
```

数组用 `[]` 表示"每个元素都遵循此结构"，这是 REST Docs 用来描述 JSON 数组的约定。如果响应体里出现了**未在 `responseFields` 中声明的字段**，REST Docs 默认会直接抛异常：

```
org.springframework.restdocs.payload.PayloadHandlingException:
The following parts of the payload were not documented:
{
  "createTime": "2026-10-01 08:00:00"
}
```

这个"严格模式"是 REST Docs 最有杀伤力的特性——**它把"字段漏写文档"变成了编译/测试期错误**。如果你确实想放宽，可以：

```java
responseFields(...).andWithPrefix("data.", ...)   // 批量声明前缀
// 或
relaxedResponseFields(...)                        // 允许未声明字段
```

但生产项目**强烈建议保持严格模式**，这才是它相对于 Swagger 的核心竞争力。

## 四、组装成可读文档：Asciidoctor

snippet 只是碎片，需要用户写一个 `.adoc` 索引把它们拼起来。

### 4.1 src/docs/asciidoc/index.adoc

```asciidoc
= 用户中心 API 文档
:doctype: book
:toc: left
:toclevels: 3
:snippets: ../../target/generated-snippets

== 获取用户详情

`GET /api/users/{id}`

=== 请求

include::{snippets}/user/get-user/http-request.adoc[]

=== 路径参数

include::{snippets}/user/get-user/path-parameters.adoc[]

=== 响应字段

include::{snippets}/user/get-user/response-fields.adoc[]

=== 响应示例

include::{snippets}/user/get-user/http-response.adoc[]

=== cURL 示例

include::{snippets}/user/get-user/curl-request.adoc[]
```

### 4.2 处理链

`asciidoctor` 任务内部是 AsciidoctorJ（Ruby Asciidoctor 的 JVM 封装），处理流程：

```
index.adoc
   │  Preprocessor  → 解析 include:: 指令，读入 snippet 文件
   │  Parser         → 生成 AST
   │  TreeProcessor  → 处理 :toc:、属性替换
   │  Converter      → HTML5 / PDF / DocBook 渲染
   ▼
build/docs/asciidoc/index.html
```

### 4.3 与构建产物集成

Spring Boot 项目常见的做法是把 HTML 挂在静态资源目录下：

```groovy
bootJar {
    dependsOn asciidoctor
    from("${asciidoctor.outputDir}") {
        into 'static/docs'
    }
}
```

这样发布后访问 `https://your-domain/docs/index.html` 就能看到文档，且文档**随 jar 一起版本化**。

## 五、进阶用法

### 5.1 用 constraints 描述校验规则

REST Docs 可以在需要时把 Bean Validation 约束渲染成表：

```java
responseFields(
        fieldWithPath("name").description("用户名")
)
.andWithPrefix("", ...);
```

结合 `mockMvc` 的 `@Valid` 行为，可以额外写一个**失败场景**的测试来记录错误响应结构：

```java
@Test
void createUser_nameBlank() throws Exception {
    mockMvc.perform(post("/api/users")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"name\":\"\"}"))
            .andExpect(status().isBadRequest())
            .andDo(document("user/create-validation-error",
                    responseFields(
                            fieldWithPath("code").description("错误码"),
                            fieldWithPath("message").description("错误信息"),
                            fieldWithPath("errors[].field").description("出错字段"),
                            fieldWithPath("errors[].reason").description("出错原因")
                    )));
}
```

### 5.2 复用默认 snippet

每个测试都要重复写 `responseFields` 很啰嗦，可以定义公共配置：

```java
public class ApiDocumentation {

    public static RestDocumentationResultHandler document(String identifier,
                                                          Snippet... snippets) {
        return org.springframework.restdocs.mockmvc.MockMvcRestDocumentation
                .document(identifier,
                        preprocessRequest(prettyPrint()),
                        preprocessResponse(prettyPrint()),
                        snippets);
    }
}
```

### 5.3 WebTestClient / RestAssured 版本

响应式项目用 `WebTestClientRestDocumentation`，端到端测试用 `RestAssuredRestDocumentation`，API 几乎一致：

```java
@Autowired
private WebTestClient webTestClient;

@Test
void getUser() {
    webTestClient.get().uri("/api/users/{id}", 1L)
            .exchange()
            .expectStatus().isOk()
            .expectBody()
            .consumeWith(document("user/get-user",
                    responseFields(fieldWithPath("name").description("用户名"))));
}
```

## 六、生产实践中的坑

### 坑 1：snippet 目录被清理

`mvn clean` 会删掉 `target/generated-snippets`，但 `asciidoctor` 阶段在 `test` 之后，所以必须显式声明依赖：

```groovy
asciidoctor {
    dependsOn test
    inputs.dir snippetsDir
}
```

用 Maven 时，`asciidoctor-maven-plugin` 要放在 `package` 阶段并绑定 `process-resources` 之后的执行。

### 坑 2：严格模式在分页响应上爆炸

分页响应常有 `total / pages / current / size / records` 等大量字段，每次都写一遍很痛苦。推荐把公共字段抽成常量：

```java
public final class PageFields {
    public static FieldDescriptor[] page(String prefix) {
        return new FieldDescriptor[]{
                fieldWithPath(prefix + "total").description("总条数"),
                fieldWithPath(prefix + "pages").description("总页数"),
                fieldWithPath(prefix + "current").description("当前页"),
                fieldWithPath(prefix + "records").description("数据列表")
        };
    }
}
```

### 坑 3：时间字段格式不一致

`LocalDateTime` 默认序列化成 `2026-10-01T08:00:00`，如果测试里 mock 的数据格式和线上 Jackson 配置不一致，文档就会误导前端。**正确做法是让测试走真实的对象映射器**，即不要 `@WebMvcTest` + mock 返回值里手写字符串，而是构造真实对象。

### 坑 4：REST Docs 与 OpenAPI 二选一吗？

不一定。常见组合是 **REST Docs 保证契约正确 + 用插件导出 OpenAPI**，但社区里更常见的是：

- 对外网关、需要 UI 调试 → SpringDoc（OpenAPI 生态、工具链丰富）；
- 对内核心接口、需要强一致 → REST Docs。

也可以让 REST Docs 生成 `openapi3` 片段（社区有 `spring-restdocs-openapi` 扩展），兼得两者。

## 七、面试高频追问

**Q1：REST Docs 和 Swagger 的本质区别是什么？**

一句话：Swagger 从实现反推文档，REST Docs 从**测试**产出文档。前者的一致性依赖人工纪律，后者由构建流程强制。

**Q2：为什么 REST Docs 的示例数据比 Swagger 可信？**

因为它记录的是**真实请求/响应**。`http-response.adoc` 里的 JSON 是 MockMvc 实际序列化出来的字节，字段名、嵌套结构、日期格式全都和线上一致（前提是你的测试配置和线上一致）。

**Q3：REST Docs 是怎么知道该写哪些字段的？**

不是"知道"，而是**你声明、它校验**。`responseFields(...)` 声明期望字段，生成时对比真实 payload，多写或漏写都会抛 `PayloadHandlingException`。这是它比反射扫描更聪明的地方——**契约是双向校验的**。

**Q4：如果接口频繁变更，维护成本会不会很高？**

会，但成本转移到了**正确的地方**。Swagger 的成本是"上线后发现文档错了再改"（线上事故成本），REST Docs 的成本是"改接口时测试红了"（开发期成本）。后者便宜得多。

**Q5：REST Docs 能否生成 OpenAPI 规范文件？**

原生不生成，它面向的是 AsciiDoc。需要 OpenAPI 时用社区扩展或在 CI 里额外跑一次 SpringDoc。二者可以共存，别强行二选一。

**Q6：`@AutoConfigureRestDocs` 做了什么？**

它注册了 `RestDocumentationContextProvider`、`SnippetConfigurer`、`OperationPreprocessorsConfigurer` 等 Bean，并配置 `MockMvcRestDocumentationConfigurer` 作为 MockMvc 的配置器，让 `document()` 能找到输出目录和格式化器。

## 八、总结

| 关注点 | 结论 |
| --- | --- |
| 一致性 | 测试驱动，构建期强制校验 |
| 侵入性 | 业务代码零注解 |
| 示例数据 | 真实请求/响应 |
| 学习曲线 | 需要写 AsciiDoc，前期成本略高 |
| 适合场景 | 对外核心 API、契约要求严格的项目 |
| 不适合 | 需要交互式调试 UI、接口海量且变更极快的场景 |

一句话收尾：**如果接口文档的可靠性对你很重要，那就别让"人"来保证它，让构建流水线来保证它。** REST Docs 的价值不在于它能生成文档，而在于它让"文档过期"这件事在 CI 里无处遁形。

---

**参考**

- Spring REST Docs 官方文档：https://docs.spring.io/spring-restdocs/docs/current/reference/html5/
- Asciidoctor 用户手册：https://docs.asciidoctor.org/asciidoctor/latest/
