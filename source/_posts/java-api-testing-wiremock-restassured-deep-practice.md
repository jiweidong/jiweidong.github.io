---
title: 【Java 工程】接口测试深度实战：WireMock 服务虚拟化与 REST Assured 断言体系
date: 2026-10-13 08:00:00
tags:
  - Java
  - 测试
  - WireMock
  - REST Assured
  - 工程实践
categories:
  - Java 深挖
author: 东哥
---

# 【Java 工程】接口测试深度实战：WireMock 服务虚拟化与 REST Assured 断言体系

## 前言

单元测试有 JUnit + Mockito，集成测试有 Testcontainers，但**接口层的自动化测试**长期被低估。很多团队的现状是：

- 单测覆盖率 80%，一上联调环境照样炸；
- 依赖的第三方接口（支付、短信、风控）不稳定，测试全看运气；
- 前端/客户端等接口等了三天，后端说「接口还没好」；
- 契约文档靠口口相传，字段改了自己都不知道。

这三个问题的共同解法是 **服务虚拟化（Service Virtualization）+ 断言体系**：

- **WireMock**：把「不稳定的第三方」「还没开发完的下游」变成可控的 HTTP 桩服务。
- **REST Assured**：用 Given/When/Then 的 DSL 写出可读性极强的接口断言。

本文把这两件工具从 API 讲到 Spring Boot 集成，再讲到契约测试与 CI 门禁。

---

## 二、WireMock：把 HTTP 依赖变成可编程的桩

### 2.1 为什么不是 Mockito？

`Mockito` mock 的是**对象方法调用**，适合单元测试。但接口测试关注的是**真实的 HTTP 行为**：

- 状态码、Header、Cookie、重定向
- 超时、连接重置、乱序响应
- chunked 传输、gzip 压缩、大报文
- 同一个 URL 依据 Query/Body 返回不同结果
- 有状态交互（第一次返回 A，第二次返回 B）

这些 Mockito 无能为力 —— 要么自己写个 Spring Controller 假装下游（脏），要么用 WireMock（专业）。

### 2.2 基础用法：Stub 的三种写法

```java
import com.github.tomakehurst.wiremock.WireMockServer;
import static com.github.tomakehurst.wiremock.client.WireMock.*;

public class WireMockBasics {

    public static void main(String[] args) {
        WireMockServer server = new WireMockServer(8089);
        server.start();

        // 写法一：静态 DSL
        stubFor(get(urlPathEqualTo("/api/user/1"))
                .withHeader("Authorization", matching("Bearer .*"))
                .willReturn(aResponse()
                        .withStatus(200)
                        .withHeader("Content-Type", "application/json")
                        .withBody("{\"id\":1,\"name\":\"东哥\"}")));

        // 写法二：按请求体匹配
        stubFor(post(urlEqualTo("/api/pay"))
                .withRequestBody(matchingJsonPath("$.amount", equalTo("100.00")))
                .willReturn(okJson("{\"success\":true}")));

        // 写法三：优先级 + 场景（有状态）
        stubFor(post(urlEqualTo("/api/order"))
                .inScenario("order-flow")
                .whenScenarioStateIs("Started")
                .willReturn(aResponse().withStatus(202))
                .willSetStateTo("confirmed"));

        stubFor(post(urlEqualTo("/api/order"))
                .inScenario("order-flow")
                .whenScenarioStateIs("confirmed")
                .willReturn(okJson("{\"status\":\"CONFIRMED\"}")));

        System.out.println("下游地址: " + server.baseUrl());
    }
}
```

**请求匹配器**（Request Matching）是 WireMock 的核心能力：

| 匹配维度 | 方法 | 说明 |
|---|---|---|
| URL | `urlEqualTo` / `urlPathEqualTo` / `urlMatching` | 精确 / 忽略 Query / 正则 |
| Header | `withHeader(k, matching(...))` | 支持 `absent()`、`equalTo` |
| Query | `withQueryParam(k, equalTo(v))` | 支持多值 |
| Body | `equalToJson`、`matchingJsonPath`、`equalToXml`、`matchingXPath` | JSON 支持 `ignoreExtraElements` |
| Cookie | `withCookie` | 会话场景 |
| 优先级 | `.atPriority(1)` | 数字越小优先级越高 |

### 2.3 故障注入：这才是接口测试的杀手锏

```java
// 模拟下游 500
stubFor(get(urlEqualTo("/api/risk"))
        .willReturn(aResponse().withStatus(500)));

// 模拟响应延迟 3 秒（测试超时/重试）
stubFor(get(urlEqualTo("/api/slow"))
        .willReturn(okJson("{}").withFixedDelay(3000)));

// 模拟连接被重置（测试熔断降级）
stubFor(get(urlEqualTo("/api/broken"))
        .willReturn(aResponse().withFault(Fault.CONNECTION_RESET_BY_PEER)));

// 模拟响应体乱码 / 空 body / 超大 body
stubFor(get(urlEqualTo("/api/huge"))
        .willReturn(ok().withBody(new byte[10 * 1024 * 1024])));
```

有了这些，你就能真正验证自己代码的**熔断、重试、降级、超时**逻辑，而不是「假想它有效」。

### 2.4 录制与回放（Proxy Record）

真实下游还在、但你想固定测试数据时，可以让 WireMock 做代理并录制：

```bash
# 代理并录制到 mappings 目录
java -jar wiremock-standalone.jar \
  --proxy-all="https://real-api.example.com" \
  --record-mappings \
  --root-dir=./wiremock
```

或者编程式：

```java
server.startRecording(recordSpec()
        .forTarget("https://real-api.example.com")
        .captureHeader("Authorization")
        .extractTextBodiesOver(10));
// ... 跑一遍真实请求 ...
server.stopRecording();
```

**踩坑**：录制的 stub 默认是「精确匹配」，一旦请求参数变化就会 miss 并返回 404。生产用法是录制后**手工改写为模糊匹配**（`matchingJsonPath`），否则维护成本极高。

### 2.5 Spring Boot 集成

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureWireMock(port = 0) // 随机端口，避免 CI 冲突
class PaymentServiceTest {

    @Value("${wiremock.server.port}")
    int wiremockPort;

    @Autowired
    private PaymentService paymentService;

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry registry) {
        // 把业务代码里的下游 URL 指向 WireMock
        registry.add("payment.gateway.url",
                () -> "http://localhost:" + wiremockPort);
    }

    @Test
    void should_return_false_when_gateway_timeout() {
        stubFor(post(urlEqualTo("/pay"))
                .willReturn(aResponse().withFixedDelay(6000)));

        // 验证业务在超时后返回失败而不是抛异常
        assertThat(paymentService.pay(100L)).isFalse();
    }
}
```

关键点：**`@AutoConfigureWireMock(port = 0)`** 让端口随机，彻底避免 CI 上并行构建的端口冲突；再用 `@DynamicPropertySource` 把下游地址注入。这是 Spring Boot 3.x 下的标准写法。

---

## 三、REST Assured：把断言写成「人话」

REST Assured 的价值在于 **Given / When / Then 的语义化 DSL**，以及内置的 JSON/XML 路径断言。

```java
import static io.restassured.RestAssured.*;
import static org.hamcrest.Matchers.*;

class UserApiTest {

    @Test
    void get_user_should_return_expected_fields() {
        given()
                .baseUri("http://localhost:8080")
                .header("Authorization", "Bearer " + token)
                .queryParam("withDetail", true)
                .log().ifValidationFails()          // 只在失败时打印请求，减少日志噪音
        .when()
                .get("/api/users/{id}", 1)
        .then()
                .statusCode(200)
                .contentType(ContentType.JSON)
                .header("X-Request-Id", not(emptyString()))
                .body("id", equalTo(1))
                .body("name", equalTo("东哥"))
                .body("roles", hasItems("ADMIN", "USER"))
                .body("roles", hasSize(2))
                .time(lessThan(500L), TimeUnit.MILLISECONDS); // 顺带做性能门禁
    }
}
```

### 3.1 JSON Schema 校验：防止字段静默变更

字段级断言容易漏，JSON Schema 可以整体卡住结构：

```java
given()
.when()
        .get("/api/users/1")
.then()
        .assertThat()
        .body(matchesJsonSchemaInClasspath("schemas/user-schema.json"));
```

**这是防「下游偷偷改字段」的最有效手段** —— 多加一个字段、少一个必填字段、类型从 int 变 string，都会直接失败。

### 3.2 认证与 Token 复用

```java
private static String token;

@BeforeAll
static void auth() {
    token = given()
            .contentType(JSON)
            .body(Map.of("username", "admin", "password", "***"))
    .when()
            .post("/api/auth/login")
    .then()
            .statusCode(200)
            .extract().path("data.token");
}

@BeforeAll
static void setup() {
    RestAssured.requestSpecification = new RequestSpecBuilder()
            .setBaseUri("http://localhost:8080")
            .addHeader("Authorization", "Bearer " + token)
            .setContentType(JSON)
            .build();
}
```

### 3.3 与 WireMock 组合：契约式接口测试

```java
@Test
void service_should_handle_downstream_degradation() {
    // 1. 下游返回 503
    stubFor(get(urlEqualTo("/risk/check")).willReturn(aResponse().withStatus(503)));

    // 2. 调用自己的接口
    given()
            .body(Map.of("userId", 1, "amount", 100))
    .when()
            .post("/api/order/submit")
    .then()
            .statusCode(200)
            .body("riskLevel", equalTo("UNKNOWN"))   // 降级策略生效
            .body("manualReview", equalTo(true));

    // 3. 反向校验：确认我们确实调用了下游，且带了正确的 Header
    verify(postRequestedFor(urlEqualTo("/risk/check"))
            .withHeader("X-Trace-Id", matching(".+")));
}
```

**WireMock 的 `verify` + REST Assured 的断言组合**，是验证「服务编排逻辑」的最佳姿势：既验证输出，也验证「对下游的调用行为」。

---

## 四、契约测试：从「联调」到「自动门禁」

### 4.1 消费者驱动的契约（Pact）

接口测试的下一步是把「消费者期望」变成契约文件，让提供方在 CI 中自动验证：

```java
@ExtendWith(PactConsumerTestExt.class)
class OrderClientPactTest {

    @Pact(consumer = "order-service", provider = "risk-service")
    public RequestResponsePact riskPact(PactDslWithProvider builder) {
        return builder
                .given("user 1 exists")
                .uponReceiving("a risk check request")
                .path("/risk/check")
                .method("POST")
                .body(new PactDslJsonBody().integerType("userId", 1).decimalType("amount", 100))
                .willRespondWith()
                .status(200)
                .body(new PactDslJsonBody().stringType("riskLevel", "LOW"))
                .toPact();
    }

    @Test
    @PactTestFor(pactMethod = "riskPact")
    void testPact(MockServer mockServer) {
        RiskClient client = new RiskClient(mockServer.getUrl());
        assertThat(client.check(1L, new BigDecimal("100")).getRiskLevel()).isEqualTo("LOW");
    }
}
```

**契约测试解决的核心痛点**：提供方改字段时，不需要等联调环境炸，CI 里契约校验就直接失败。

### 4.2 契约测试与接口测试的分工

| 层面 | 工具 | 验证什么 | 何时跑 |
|---|---|---|---|
| 单元测试 | JUnit + Mockito | 方法逻辑 | 每次提交 |
| 接口测试 | REST Assured + WireMock | 我方 HTTP 行为 + 下游编排 | 每次提交 |
| 契约测试 | Pact | 双方接口约定一致性 | 每次提交 + 提供方 CI |
| 端到端 | Testcontainers + 真实依赖 | 全链路 | 每日 / 发版前 |

---

## 五、生产踩坑清单

1. **端口冲突**。CI 并行构建时，固定端口必冲突。用 `port = 0`（随机）或 `@AutoConfigureWireMock(port = 0)`。
2. **Stub 优先级不生效**。WireMock 默认「后注册的优先」，但**同时使用 `.atPriority()` 时数字小的优先**，两者规则不同，容易踩坑。建议所有 stub 显式指定优先级。
3. **未匹配请求返回 404**。不是 WireMock 出错，而是 `Request Not Matched`。开启 `--verbose` 看 diff 日志，90% 是 Header/Content-Type 或 JSON 字段顺序问题。注意 `equalToJson` 默认不在乎顺序，但 `equalTo` 在乎。
4. **录制模式污染生产数据**。录制真实响应可能把 Token、手机号、订单号写进 stub 文件。**必须做脱敏**，或使用 `--capture-header` 白名单。
5. **REST Assured 静默忽略 SSL**。测试环境常加 `relaxedHTTPSValidation()`，这个配置**绝不能进生产代码**，建议放在 `@BeforeAll` 的测试专用 spec 里。
6. **`body()` 断言的路径语法**。JSON Path 中 `a.b` 和 `a[0].b` 语义不同，数组要显式下标；字段名含点号需转义。
7. **测试依赖时序**。接口测试中大量 `@BeforeAll` 共享 Token，一旦登录失败会导致全部用例失败且原因难查。建议 Token 获取加显式断言与重试。

---

## 六、面试高频追问

**Q1：接口测试和集成测试的区别？**
接口测试聚焦「HTTP 契约与行为」，依赖可以用桩替代；集成测试强调「真实组件协作」，通常用 Testcontainers 拉起真实 MySQL/Redis/Kafka。前者快、后者真，两者互补。

**Q2：为什么不用 MockMvc 而用 REST Assured？**
`MockMvc` 不经过真实网络栈（不起端口），测不到序列化、Header 大小限制、超时、连接复用等问题；REST Assured 走真实 HTTP，更接近生产。两者可以共存：MockMvc 测 Controller 切片，REST Assured 测端到端接口。

**Q3：WireMock 能不能测超时？**
能。`withFixedDelay` 只是让它「慢」，要测「连接超时后客户端行为」，还需要配合 `Fault.CONNECTION_RESET_BY_PEER` 或 `EMPTY_RESPONSE` 以及客户端侧 timeout 配置。

**Q4：契约测试能不能替代接口测试？**
不能。契约测试只保证「双方约定一致」，不保证你的业务逻辑正确。它是接口测试的补充，而不是替代。

---

## 七、总结

- **WireMock** 解决「环境不可控」：故障注入、录制回放、有状态场景，让接口测试从「祈祷式」变成「工程式」。
- **REST Assured** 解决「断言太啰嗦」：DSL + JSON Path + Schema 校验，让接口断言可读、可维护、可作性能门禁。
- **契约测试** 解决「协作断层」：把接口约定变成 CI 门禁，问题在提交时暴露，而不是在联调时爆雷。

一套完整的接口测试体系，是「能把线上事故挡在发布前」的核心资产。对准备跳槽的 Java 工程师来说，能把「服务虚拟化 + 断言体系 + 契约门禁」讲清楚，比多背十个设计模式更能体现工程素养。
