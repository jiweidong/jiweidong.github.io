---
title: 【微服务测试】契约测试深度实战：Pact 与 Spring Cloud Contract 从原理到落地
date: 2026-08-20 08:00:00
tags:
  - Java
  - 微服务
  - 测试
categories:
  - Java
  - 微服务
author: 东哥
---

# 【微服务测试】契约测试深度实战：Pact 与 Spring Cloud Contract 从原理到落地

## 问题：微服务联调为什么这么痛？

微服务化之后，服务间通过 HTTP/RPC 通信。最经典的痛点场景：

> 订单服务（消费方）调用用户服务（提供方）的 `GET /api/users/{id}`，联调时发现返回结构变了——字段 `nickname` 被改成了 `nickName`。用户服务自己测试全绿，订单服务却直接崩了。

传统解法是"集成测试 + 联调环境"，但问题很多：

- 联调环境不稳定，依赖方一多就互相阻塞
- 测试要在真实网络里跑，慢且脆弱
- 问题发现太晚——通常在开发后期

**契约测试（Contract Testing）** 就是来解决这个问题的：**消费方和提供方不联调，只对着同一份"契约"各自测试**。契约描述"请求长什么样、响应长什么样"，双方只要都满足契约，就能保证集成不出问题。

## 一、契约测试的核心思想

契约测试的出发点是：**消费方真正关心的，是提供方 API 的"形状"（Schema），而不是它的实现**。

```
传统方式： 消费方 ──真实调用──► 提供方（联调环境，不稳定）
契约方式： 消费方 ──验证──► 契约(Contract) ◄──验证── 提供方
```

消费方用 Mock 的提供方来测试自己，但 Mock 不是随便写的——**Mock 必须符合契约**；提供方用契约里的请求来测试自己，保证自己的实现符合契约。只要双方各自验证通过，集成就是可信的。

两个主流框架：

| 框架 | 契约由谁发起 | 契约格式 | 特点 |
|------|-------------|----------|------|
| **Pact** | 消费方先写（Consumer-Driven） | Pact JSON | 生态大、跨语言（JVM/JS/Python/Go...）、支持 HTTP 和消息 |
| **Spring Cloud Contract** | 提供方先写（Provider-Driven） | Groovy DSL / YAML | Spring 生态原生集成、可生成测试桩（Stub Runner） |

## 二、Pact：消费者驱动的契约测试

Pact 的核心流程是 **Pact Broker** 做契约中转：

```
1. 消费方写测试：定义期望的请求/响应 → 生成 Pact 文件
2. 消费方把 Pact 文件发布到 Pact Broker
3. 提供方从 Broker 拉取 Pact 文件 → 运行提供方验证测试
4. 双方全绿 = 契约成立（可安全集成）
```

### 2.1 消费方（订单服务）怎么测？

```java
@ExtendWith(PactConsumerTestExt.class)
public class UserServiceClientContractTest {

    // 1. 定义契约：期望 GET /api/users/100 返回 {id:100, nickname:"东哥"}
    @Pact(provider = "user-service", consumer = "order-service")
    public RequestResponsePact userByIdPact(PactDslWithProvider builder) {
        return builder
            .given("用户 100 存在")                    // provider state
            .uponReceiving("查询用户 100 的信息")
            .path("/api/users/100")
            .method("GET")
            .willRespondWith()
            .status(200)
            .body(new PactDslJsonBody()
                .integerType("id", 100)
                .stringType("nickname"))
            .toPact();
    }

    // 2. 用 Pact 生成的 MockServer 测自己的客户端代码
    @PactTestFor(pactMethod = "userByIdPact", providerName = "user-service")
    @Test
    void testGetUser(MockServer mockServer) {
        UserServiceClient client = new UserServiceClient(mockServer.getUrl());
        User user = client.getUser(100L);
        assertEquals(100, user.getId());
        assertEquals("东哥", user.getNickname());
    }
}
```

关键点：**PactDslJsonBody 里用 `integerType`/`stringType` 表示"字段类型 + 示例值"**，而不是写死值——这就是契约的"宽松匹配"能力：提供方返回任意整数的 id 都能通过验证，但字段缺失/类型不对就会失败。

### 2.2 提供方（用户服务）怎么验证？

```java
@ExtendWith(PactVerificationInvocationContextProvider.class)
public class UserServicePactVerificationTest {

    @BeforeEach
    void setUp() {
        // 提供方的真实应用（MockMvc 或 WebTestClient 均可）
        RestAssuredMockMvc.standaloneSetup(new UserController(new UserService()));
    }

    @PactVerification("user-service")
    @TestTemplate
    @ExtendWith(PactVerificationContextProvider.class)
    void verifyPact(PactVerificationContext context) {
        context.verifyInteraction();
    }
}
```

运行后，Pact 框架会从 Broker 拉取所有消费方发布的契约，逐个对提供方发起真实请求并校验响应。**提供方只需要保证"契约里的请求我能答对"**，不需要部署消费方。

### 2.3 关键概念：Provider State

契约测试有个天然难题：提供方验证时，数据环境是它自己的。契约里写了"用户 100 存在"，但提供方测试库里根本没有用户 100 怎么办？

Pact 的答案是 **Provider State（提供方状态）**——消费方在契约里声明前置状态，提供方在验证时准备该状态：

```java
@State("用户 100 存在")   // 对应契约里的 given("用户 100 存在")
public void user100Exists() {
    userRepository.save(new User(100L, "东哥"));
}
```

这样消费方可以描述各种场景（用户存在/不存在/无权限），提供方逐一准备数据验证，覆盖率达到"穷举业务分支"。

## 三、Spring Cloud Contract：提供方驱动的契约测试

Spring 生态的官方方案，流程与 Pact 相反：**提供方先写契约**，然后：

1. 提供方基于契约生成**测试用例**并验证自己的实现
2. 同时生成**Stub（测试桩）**发布到 Maven 仓库
3. 消费方用 Stub Runner 拉取 Stub 做测试，无需真实提供方

### 3.1 提供方写契约（Groovy DSL）

```groovy
// src/test/resources/contracts/user/getUserById.groovy
Contract.make {
    description("根据 ID 查询用户")
    request {
        method GET()
        url "/api/users/100"
    }
    response {
        status 200
        headers {
            contentType(applicationJson())
        }
        body([
            id      : 100,
            nickname: "东哥"
        ])
    }
}
```

### 3.2 提供方验证

```java
// 添加 spring-cloud-contract-verifier 依赖后，
// 构建时自动生成 ContractVerifierTest 并执行
@SpringBootTest
@AutoConfigureMockMvc
public class ContractVerifierTest extends ContractVerifierBase {
    // 生成的测试会向 /api/users/100 发请求并校验响应
}
```

### 3.3 消费方用 Stub Runner

```java
@SpringBootTest
@AutoConfigureStubRunner(
    ids = "com.example:user-service:+:stubs:8080",  // 自动起一个桩服务
    stubsMode = StubRunnerProperties.StubsMode.LOCAL)
class OrderServiceIntegrationTest {
    // 测试里直接调用 http://localhost:8080/api/users/100，
    // 返回的正是契约里定义的响应
}
```

**Stub 的价值**：消费方的集成测试可以完全本地化、并行化，不用等提供方部署，也不用连联调环境。

## 四、Pact vs Spring Cloud Contract 怎么选？

| 维度 | Pact | Spring Cloud Contract |
|------|------|----------------------|
| 驱动方 | 消费方驱动（更贴近真实需求） | 提供方驱动（提供方把控 API） |
| 语言生态 | 跨语言，全栈适用 | JVM/Spring 生态优先 |
| 契约仓库 | Pact Broker（独立部署） | Maven 私服（Stub 走制品库） |
| 消息场景 | 支持（Pact 4 消息契约） | 支持（消息契约 DSL） |
| 学习成本 | 中（Broker 要部署运维） | 低（与 Spring 测试体系天然融合） |
| 适合场景 | 异构语言团队、消费方驱动 API 设计 | 全 Java 团队、已有 Maven 制品流 |

**选型建议**：
- 全 Java + Spring 生态 → Spring Cloud Contract，落地成本最低
- 多语言微服务（Java + Go + Node）→ Pact，跨语言是硬需求
- 想推行"消费方驱动设计"（API 由需求方定义）→ Pact

## 五、落地避坑指南

### 5.1 契约要"松匹配"
契约里用类型匹配而非值匹配（`integerType`、`eachLike`、`regexp`），否则提供方每次调整数据都会误伤消费方测试。**契约描述的是 API 形状，不是具体数据**。

### 5.2 契约变更要管理
契约是接口的"法律文件"，变更要走评审。Pact Broker 有 **pending 机制**：新契约先标记 pending，给消费方/提供方留出适配窗口，避免"契约一更新，对方立刻红"。

### 5.3 别把契约测试当集成测试
契约测试解决的是"接口形状一致"，不验证"两端业务逻辑联合正确"。**契约测试 + 少量关键链路端到端测试**组合才是正解，全量 E2E 会退回联调地狱。

### 5.4 CI 集成
- 消费方 CI：跑契约测试 → 发布契约到 Broker
- 提供方 CI：拉取全部契约 → 跑验证 → 发布验证结果
- 用 **can-i-deploy**（Pact）或契约版本管理判断"当前版本能否安全上线"

### 5.5 覆盖范围要有取舍
不是所有接口都值得契约测试。**跨团队、跨系统、变更频繁的接口**是重点；内部方法调用、团队内稳定接口不值得付出维护成本。

## 六、面试追问环节

**Q1：契约测试和 Mock 测试什么区别？**
答：Mock 测试里 Mock 的行为是"自己写的"，可能和真实提供方不一致——测了也白测；契约测试里的 Mock（或 Stub）是由契约驱动的，契约经过提供方验证，所以消费方测试可信。

**Q2：契约测试能替代集成测试吗？**
答：不能完全替代。契约保证接口形状一致，但真实网络、鉴权、限流、数据一致性等问题仍需要端到端测试覆盖。业界实践是"契约测试为主 + 核心链路 E2E 为辅"。

**Q3：Provider State 解决了什么问题？**
答：解决了"提供方验证环境没有消费方假设的数据"的问题。消费方在契约里声明场景（given），提供方按场景准备数据再验证，让验证覆盖各种业务分支而不是只有 happy path。

**Q4：什么时候引入契约测试收益最大？**
答：团队规模大、服务间依赖多、联调频繁阻塞、或者有外部供应商/异构语言服务时。两个服务、一个团队维护，契约测试的维护成本可能大于收益。

## 总结

契约测试是微服务时代的"接口单元测试"：把"联调"从"跑真实环境"变成"对契约各自验证"。Pact 的消费方驱动适合跨语言团队，Spring Cloud Contract 的全 Java 落地更轻。记住核心心法：**契约是接口形状的约定，松匹配、管变更、进 CI——集成可信，联调不痛。**
