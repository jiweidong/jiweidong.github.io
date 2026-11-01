---
title: 【Java AI】工具调用协议深度对比：MCP、A2A 与 OpenAPI 的边界、选型与 Java 落地
date: 2026-11-01 08:20:00
tags:
  - Java
  - AI
  - MCP
  - A2A
  - Agent
  - OpenAPI
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】工具调用协议深度对比：MCP、A2A 与 OpenAPI

## 前言

2025 年之后，Agent 圈子里的协议讨论几乎被三个词占满：**MCP、A2A、OpenAPI**。

但中文技术圈里有一个普遍的误解：**把它们当成三选一的竞品**。"是不是有了 MCP 就不用 OpenAPI 了？""A2A 会不会取代 MCP？"——这类问题本身就问错了。

真相是：**它们处在三个不同的抽象层，解决三个不同的问题。**

| 协议 | 解决的问题 | 类比 |
|---|---|---|
| **OpenAPI** | 一个服务如何用机器可读的方式描述自己的 HTTP 接口 | "菜单"（有什么菜、怎么点） |
| **MCP** | 一个 AI 应用如何**动态发现并调用**外部工具、读取资源、加载 Prompt | "USB-C 接口"（插上就能用） |
| **A2A** | 一个 Agent 如何**委托任务**给另一个 Agent，并跟踪长任务状态 | "外包合同"（交给谁、进度如何、交付物在哪） |

用一句话概括三者关系：

> **OpenAPI 描述"能力"，MCP 暴露"能力给模型"，A2A 编排"能力的使用者"。**

这篇文章从 Java 工程师的视角，把三者的**协议结构、Java 落地代码、选型边界**讲清楚，最后给一套"三层组合"的架构方案。

---

## 一、先把三层抽象摆正

### 1.1 各自的"最小单元"

| 维度 | OpenAPI | MCP | A2A |
|---|---|---|---|
| 最小单元 | **Operation**（path + method） | **Tool / Resource / Prompt** | **Task**（含 Artifact） |
| 描述对象 | HTTP 接口契约 | 模型可调用的能力 | 智能体间的委托 |
| 传输 | HTTP/1.1、HTTP/2、gRPC（扩展） | JSON-RPC 2.0 over stdio / Streamable HTTP | JSON-RPC 2.0 over HTTP(S) + SSE |
| 发现机制 | 静态文档（`/openapi.json`） | `initialize` 握手 + `tools/list` 动态枚举 | `/.well-known/agent-card.json` |
| 认证 | 自定义（apiKey / OAuth2 / mTLS） | 传输层 + OAuth 2.1（规范推荐） | Agent Card 声明 `securitySchemes` |
| 状态 | 无状态（REST 语义） | 会话级（session） | **有状态任务机**（submitted/working/input-required/...） |
| 流式 | 无（需 SSE 扩展） | Streamable HTTP + 进度通知 | `message/stream`（SSE） |
| 面向对象 | 开发者 / 网关 | **模型（LLM）** | **另一个 Agent** |

### 1.2 为什么"面向对象"决定了协议形态

这是理解三者差异的关键。

**OpenAPI 是给"人 + 代码生成器"看的。** 它要求你写清楚 `requestBody` 的 schema、`responses` 的状态码、`security` 的方案。信息量很大，但**大部分对模型是噪音**——模型不关心 401 和 403 的区别，它只关心"我调这个工具需要什么参数、会得到什么"。

**MCP 是给"模型"看的。** 它的 `tools/list` 返回的是：

```json
{
  "name": "search_orders",
  "description": "按用户 ID 和状态查询订单列表。当用户问'我的订单到哪了'时使用。",
  "inputSchema": { "type": "object", "properties": { ... } }
}
```

注意 `description` 里那句**"当用户问'我的订单到哪了'时使用"**——这是给模型的**路由提示**，OpenAPI 里没有这个位置。MCP 的设计哲学是：**描述要面向"模型该在什么时候调用我"，而不是"这个接口的技术契约"。**

**A2A 是给"另一个 Agent"看的。** Agent 之间协作时，光有"能做什么"不够，还要有：

- **任务生命周期**：我交给你一个任务，你多久能完成？中途需要我补充信息吗（`input-required`）？
- **交付物**：你的产出是一个文本、一个文件、还是一张图（`Artifact` + `parts`）？
- **能力协商**：你支持流式吗？支持推送通知吗？你的输入输出模态是什么？

这三件事 OpenAPI 和 MCP 都不管。**A2A 补的正是"长任务编排"这一层。**

---

## 二、MCP：模型与工具之间的 USB-C

### 2.1 协议结构

MCP 的架构是 **Host / Client / Server** 三角：

```
┌─────────────────────────────────────┐
│  Host（Claude Desktop / 你的 AI 应用）│
│   ├── MCP Client A ──stdio──► Server A（本地文件系统）
│   ├── MCP Client B ──HTTP───► Server B（公司内部知识库）
│   └── MCP Client C ──HTTP───► Server C（Jira / Git）
└─────────────────────────────────────┘
```

**一个 Host 可以挂多个 Server**，这是 MCP 最重要的设计——工具不再是硬编码在应用里，而是**可插拔的外部进程/服务**。

三个服务端原语（Server → Client 提供）：

| 原语 | 语义 | 控制方 | 例子 |
|---|---|---|---|
| **Tools** | 可执行的动作 | **模型决定调用** | `create_ticket`、`run_sql` |
| **Resources** | 可读取的数据 | **应用决定注入** | `file:///docs/api.md` |
| **Prompts** | 可复用的模板 | **用户主动选择** | `/code-review` 斜杠命令 |

**这个"控制方"区分极其重要**：Tools 是 model-controlled（模型自主决定），Resources 是 application-controlled（应用按需塞进上下文），Prompts 是 user-controlled（用户显式触发）。搞混了就会做出"让模型自己决定读哪个文件"的危险设计。

客户端侧还有三个能力：**Sampling**（服务端反过来请求模型生成）、**Roots**（告知服务端可访问的目录边界）、**Elicitation**（服务端向用户追问）。这三个是"反向通道"，很多人不知道，导致把 MCP 当成单向 RPC 用。

### 2.2 传输：Streamable HTTP 取代了 HTTP+SSE

这一点必须更新认知：

- **2024-11-05 版**：`stdio` + `HTTP+SSE`（两个端点：GET 建 SSE 流，POST 发消息）
- **2025-03-26 版起**：`stdio` + **Streamable HTTP**（单端点，POST 请求，响应可以是 `application/json` 也可以是 `text/event-stream`）

Streamable HTTP 解决了旧方案的两个痛点：**① 需要维护长连接，Serverless/网关不友好；② 断线重连要靠 `Last-Event-ID` 恢复，实现复杂。**

现在单端点 + 可选流式，配合 `Mcp-Session-Id` 头做会话，对 Java 侧的 WebFlux / WebMVC 都友好得多。

### 2.3 Java 落地：Spring AI 三行暴露一个 MCP Server

**依赖：**

```xml
<!-- MCP Server（WebMVC 版，Servlet 栈） -->
<dependency>
  <groupId>org.springframework.ai</groupId>
  <artifactId>spring-ai-starter-mcp-server-webmvc</artifactId>
</dependency>
<!-- MCP Client -->
<dependency>
  <groupId>org.springframework.ai</groupId>
  <artifactId>spring-ai-starter-mcp-client</artifactId>
</dependency>
```

**服务端：把已有的 `@Tool` 方法直接暴露成 MCP 工具**

```java
@Service
public class OrderTools {

    private final OrderRepository orderRepo;

    public OrderTools(OrderRepository orderRepo) {
        this.orderRepo = orderRepo;
    }

    @Tool(name = "search_orders",
          description = """
              按用户 ID 与订单状态查询订单列表。
              当用户询问“我的订单在哪 / 到哪了 / 什么时候发货”时调用本工具。
              status 传 ALL 表示不限状态。
              """)
    public List<OrderBrief> searchOrders(
            @ToolParam(description = "用户 ID，纯数字") long userId,
            @ToolParam(description = "订单状态：ALL / PAID / SHIPPED / DONE / REFUND") String status,
            @ToolParam(description = "最多返回条数，1~20，默认 5") int limit) {

        int n = Math.min(Math.max(limit, 1), 20);
        return orderRepo.findByUser(userId, status, n).stream()
                .map(OrderBrief::from)
                .toList();
    }
}
```

**暴露成 MCP 端点：**

```java
@Configuration
public class McpServerConfig {

    @Bean
    public ToolCallbackProvider orderToolProvider(OrderTools tools) {
        return MethodToolCallbackProvider.builder()
                .toolObjects(tools)
                .build();
    }
}
```

配置 `application.yml`：

```yaml
spring:
  ai:
    mcp:
      server:
        name: order-mcp-server
        version: 1.0.0
        type: SYNC
        protocol: STREAMABLE   # 新版规范传输
```

启动后，MCP 端点默认挂在 `/sse`（旧）或 `/mcp`（Streamable HTTP），`tools/list` 就能枚举到 `search_orders`。

**客户端：以编程方式调用远端 MCP 工具**

```java
@Configuration
public class McpClientConfig {

    @Bean(destroyMethod = "close")
    public McpSyncClient orderMcpClient() {
        HttpClientStreamableTransport transport =
                HttpClientStreamableHttpTransport.builder("http://order-svc:8080")
                        .endpoint("/mcp")
                        .build();

        McpSyncClient client = McpClient.sync(transport)
                .requestTimeout(Duration.ofSeconds(10))
                .capabilities(McpSchema.ClientCapabilities.builder()
                        .roots(true)          // 声明支持 roots 边界
                        .build())
                .build();

        client.initialize();   // 握手：交换 protocolVersion / capabilities
        return client;
    }
}
```

> **版本提示**：MCP Java SDK 与 Spring AI 的 MCP starter 在 0.x → 1.x 之间 API 变动较大（包名从 `io.modelcontextprotocol` 到 Spring AI 的封装层都有调整）。上面的写法对应 Streamable HTTP 时代，落地前请核对 `spring-ai-bom` 与你实际使用的 SDK 版本。

### 2.4 MCP 的优势与坑

**优势：**

- **动态发现**：`tools/list` 让"新增工具"不需要改 Agent 代码；
- **传输无关**：本地 stdio（零网络）、远端 Streamable HTTP 都能用；
- **权限边界清晰**：Roots 限定可访问目录，比"给个 API Key"精细得多。

**坑：**

| 坑 | 表现 | 对策 |
|---|---|---|
| 工具描述写得像 OpenAPI | 模型选错工具 / 参数传错 | description 必须写"**什么时候用**"，不是"这个接口是什么" |
| 工具数量爆炸 | `tools/list` 返回 80 个工具，token 爆掉，选择准确率暴跌 | 分组 + 工具检索（tool retrieval）+ 子 Agent 隔离工具域 |
| 无超时 | 一个慢工具拖死整个会话 | 客户端 `requestTimeout` + 服务端侧熔断 |
| 混淆 Tools 与 Resources | 让模型"自己决定读哪个文件" | 敏感资源用 application-controlled，不进 Tools |
| 长任务 | `tools/call` 是同步语义，跑 5 分钟就超时 | 长任务走 A2A 的任务模型，别硬塞 MCP |

---

## 三、A2A：Agent 之间的"外包合同"

### 3.1 为什么需要 A2A

一个真实场景：

> 用户说："帮我分析上季度华东区的销售下滑原因，出一份 PPT。"

这个任务需要：查数（SQL Agent）→ 归因（分析 Agent）→ 作图（图表 Agent）→ 排版（文档 Agent）。**四个 Agent，跨三四个团队，跑 10 分钟。**

用 MCP 做行不行？勉强——你把另外三个 Agent 都包装成 `tools/call` 的工具。但立刻遇到：

1. **同步语义**：`tools/call` 期望快速返回。跑 10 分钟的任务，HTTP 早断了。
2. **没有状态**：中途"需要用户确认口径"这种情况没法表达。
3. **没有交付物概念**：返回一个 30MB 的 PPT 二进制？塞在 JSON 里？
4. **没有能力协商**：调用方不知道对方支不支持流式、支不支持图片输入。

**A2A 就是为"Agent 委托长任务"设计的。**

### 3.2 Agent Card：能力自描述

每个 A2A Server 在 `/.well-known/agent-card.json` 暴露自己的能力：

```json
{
  "protocolVersion": "0.2.5",
  "name": "sales-analysis-agent",
  "description": "销售数据分析智能体。可执行同比/环比归因、区域下钻、异常检测，输出结构化报告。",
  "url": "https://ai.example.com/a2a/sales",
  "preferredTransport": "JSONRPC",
  "version": "1.4.0",
  "capabilities": {
    "streaming": true,
    "pushNotifications": false,
    "stateTransitionHistory": true
  },
  "defaultInputModes": ["text/plain", "application/json"],
  "defaultOutputModes": ["text/markdown", "application/json"],
  "skills": [
    {
      "id": "quarterly-attribution",
      "name": "季度归因分析",
      "description": "对指定季度、指定区域的销售数据进行同比/环比归因，输出 Top5 影响因子。",
      "tags": ["sales", "attribution", "analytics"],
      "examples": ["分析 2026Q3 华东区销售下滑原因", "对比 2026Q3 与 2026Q2 华南区 GMV"]
    }
  ],
  "securitySchemes": {
    "oauth2": { "type": "oauth2", "flows": { "clientCredentials": { "tokenUrl": "https://auth.example.com/token", "scopes": { "a2a.invoke": "调用 A2A 接口" } } } }
  },
  "security": [{ "oauth2": ["a2a.invoke"] }]
}
```

**`skills` 是关键设计**：它是"能力目录"，调用方 Agent 可以只看 skills 决定要不要委托，而不需要理解内部实现。这和 MCP 的 `tools/list` 是同一个思路，但粒度更粗（一个 skill 可能对应内部几十次 LLM 调用）。

### 3.3 任务模型：A2A 的灵魂

A2A 的核心不是"发消息"，而是 **Task 状态机**：

```
submitted ──► working ──► completed
                │  ▲
                │  └── input-required（需要调用方补充信息）
                ├──► failed
                ├──► canceled
                └──► rejected
       └──► auth-required（需要额外授权）
```

对应 JSON-RPC 方法：

| 方法 | 作用 |
|---|---|
| `message/send` | 发消息，同步返回 Task 或 Message |
| `message/stream` | 发消息，SSE 流式返回状态变更与增量产物 |
| `tasks/get` | 查任务状态（长轮询） |
| `tasks/cancel` | 取消任务 |
| `tasks/pushNotificationConfig/set` | 注册 webhook，任务完成时回调 |

**`input-required` 这个状态是 A2A 相对 MCP 的杀手级差异。** 它把"多轮澄清"变成了协议级能力：Agent 干到一半发现口径不清，把任务挂到 `input-required`，调用方补上信息后继续 `working`——**这中间可以隔几分钟甚至几小时，任务不丢。**

### 3.4 Java 落地：一个最小 A2A Server

A2A 官方有 Java SDK（`io.github.a2asdk` 系列，Spring Boot starter 也在推进中）。核心是实现 **AgentExecutor**：

```java
public class SalesAnalysisExecutor implements AgentExecutor {

    private final AttributionService attributionService;

    public SalesAnalysisExecutor(AttributionService svc) {
        this.attributionService = svc;
    }

    @Override
    public void execute(RequestContext context, EventQueue eventQueue) {
        TaskUpdater updater = new TaskUpdater(context, eventQueue);

        // 1. 标记进入 working
        updater.startWork();

        String query = extractText(context.getMessage());
        AnalysisRequest req = parse(query);

        // 2. 信息不全 → 请求补充（A2A 特有）
        if (req.quarter() == null || req.region() == null) {
            updater.requiresInput("请补充季度（如 2026Q3）与区域（如 华东区）");
            return;
        }

        // 3. 干活，中间可以多次推送进度（流式）
        updater.updateStatus(TaskState.WORKING, "正在拉取销售明细…");
        SalesSlice slice = attributionService.load(req);

        updater.updateStatus(TaskState.WORKING, "正在做同比归因…");
        AttributionResult result = attributionService.attribute(slice);

        // 4. 产出 Artifact（结构化交付物）
        updater.addArtifact("attribution-report", "归因报告",
                List.of(new TextPart(result.toMarkdown())),
                Map.of("mimeType", "text/markdown"));

        updater.complete();
    }

    @Override
    public void cancel(RequestContext context, EventQueue eventQueue) {
        new TaskUpdater(context, eventQueue).cancel();
    }
}
```

**调用方（Java Client）：**

```java
A2AClient client = A2AClient.fromCardUrl(
        "https://ai.example.com/.well-known/agent-card.json",
        new JdkA2AHttpClient());

// 非流式
SendMessageResponse resp = client.sendMessage(new SendMessageRequest()
        .withMessage(Message.builder()
                .role(Message.Role.USER)
                .parts(List.of(new TextPart("分析 2026Q3 华东区销售下滑原因")))
                .build()));

if (resp.getTask() != null && resp.getTask().getStatus().getState() == TaskState.INPUT_REQUIRED) {
    // 补信息后继续同一个 taskId
    client.sendMessage(new SendMessageRequest()
            .withMessage(Message.builder()
                    .taskId(resp.getTask().getId())
                    .role(Message.Role.USER)
                    .parts(List.of(new TextPart("季度 2026Q3，区域 华东区")))
                    .build()));
}
```

**这个"补信息后继续同一 taskId"的模式，是 A2A 最实用的地方。** 换成 MCP，你得自己维护会话状态；换成纯 HTTP，你得自己建任务表。

### 3.5 A2A 的坑

| 坑 | 说明 |
|---|---|
| 以为 A2A 替代 MCP | 层级不同。A2A 的 Agent 内部照样用 MCP 拿工具 |
| 忽略 Agent Card 版本 | `protocolVersion` 不匹配会静默降级或报错 |
| 长任务不注册 webhook | 靠 `tasks/get` 轮询，QPS 全花在查状态上 |
| 流式不处理重连 | `message/stream` 断线后要能靠 taskId 续上 |
| 安全边界模糊 | Agent 之间互相调用容易形成"越权链"，必须做**委托凭证**（token exchange），不能简单透传用户 token |

最后一条尤其重要：**A2A 里的权限传播是难题。** Agent A 代表用户 U 调用 Agent B，B 该拿什么凭证？直接透传 U 的 token？那 B 就获得了 U 的全部权限，违反最小权限。正确做法是 **OAuth 2.0 Token Exchange（RFC 8693）**，换取一个 scope 收窄的、带 `act` 声明的委托 token。

---

## 四、OpenAPI：别忘了它才是"事实标准"

### 4.1 OpenAPI 在 AI 时代的两个角色

**角色一：工具schema 的事实来源。** 大部分企业的内部服务早就有了 OpenAPI 文档。让模型调用这些服务，最省事的路径就是把 OpenAPI operation 转成 function calling 的 tool schema。

**角色二：MCP Server 的生成器。** 与其手写 MCP Server，不如拿 OpenAPI 自动生成——这是目前生态里最成熟的路径。

### 4.2 Java 落地：OpenAPI → Tool 自动转换

```java
@Component
public class OpenApiToolFactory {

    /** 把 OpenAPI 文档里的所有 operation 转成 Spring AI 的 ToolCallback */
    public List<ToolCallback> build(String specUrl, String baseUrl, RestClient restClient) {
        OpenAPI api = new OpenAPIV3Parser().read(specUrl);

        List<ToolCallback> tools = new ArrayList<>();
        api.getPaths().forEach((path, item) ->
            item.readOperations().forEach(op -> {
                String toolName = toolName(op);              // operationId 或 method+path 派生
                String desc = buildDescription(path, op);    // ★ 关键：面向模型重写
                JsonNode schema = toJsonSchema(op);          // 参数 → JSON Schema

                tools.add(FunctionToolCallback.builder(toolName, (args) -> invoke(restClient, baseUrl, path, op, args))
                        .description(desc)
                        .inputSchema(new MethodParameter[0]) // 或用 inputType(record) 强类型
                        .build());
            })
        );
        return tools;
    }

    private String buildDescription(String path, Operation op) {
        // 不要直接把 OpenAPI summary 塞进去！补充"何时使用"和副作用说明
        StringBuilder sb = new StringBuilder();
        sb.append(op.getSummary() == null ? path : op.getSummary()).append('\n');
        if (op.getDescription() != null) sb.append(op.getDescription()).append('\n');
        sb.append("HTTP: ").append(op.getHttpMethod()).append(' ').append(path).append('\n');
        sb.append("副作用: ").append(isReadOnly(op) ? "只读，可安全重试" : "有副作用，勿重复调用");
        return sb.toString();
    }
}
```

### 4.3 直接拿 OpenAPI 当工具的三个致命问题

**问题 1：粒度太细，工具爆炸。**

一个中等规模的电商后台，OpenAPI 里有 300 个 operation。全塞给模型：

- `tools` 数组直接 6 万 token，**还没开始对话就烧掉一半上下文**；
- 模型选择准确率断崖下跌（经验上超过 20~30 个工具后开始明显退化）。

**解法：**

1. **按业务域切分**（订单域 / 商品域 / 用户域），每个 Agent 只挂自己域的 10~20 个工具；
2. **工具检索（tool retrieval）**：先用向量检索从 300 个工具里召回 top 8，再注入；
3. **抽象高层工具**：把"查订单 + 查物流 + 查退款"合成一个 `get_order_full_status`，比让模型自己编排三个接口稳得多。

**问题 2：语义缺位。**

OpenAPI 的 `summary` 是写给人看的："GET /api/v1/orders/{id}"。模型需要的是："当用户想知道某个订单的详情时调用；id 是订单号不是用户 ID；不存在的订单返回 404，此时应告知用户订单号可能有误。"

**description 的质量直接决定工具调用的准确率**，这活儿没法自动化，必须人工写。

**问题 3：认证与幂等语义丢失。**

OpenAPI 里的 `security` 是给网关看的，模型不知道"这个接口需要用户级 token"。如果 Agent 用服务账号的高权限 token 去调，就会**越权**。

**解法：工具层做权限收敛。**

```java
public ToolCallback withPermission(FunctionToolCallback delegate, Set<String> requiredScopes) {
    return new PermissionCheckedTool(delegate, requiredScopes);
}
// 调用前校验当前用户是否具备 scope，不具备则返回明确的错误信息给模型
// 而不是抛 403 让模型瞎猜
```

**幂等性同理**：写操作（POST/PUT）必须在 description 里明确标注"有副作用"，并在工具实现里做幂等键，否则模型重试一次就多下一单。

### 4.4 三者对比总表

| 维度 | OpenAPI | MCP | A2A |
|---|---|---|---|
| **层次** | 接口描述层 | 工具接入层 | Agent 协作层 |
| **消费方** | 开发者、代码生成器、网关 | LLM | 另一个 Agent |
| **发现** | 静态文档 | 运行时 `tools/list` | `agent-card.json` |
| **状态** | 无状态 | 会话级 | **任务级（有状态机）** |
| **流式** | 需额外定义 | Streamable HTTP | `message/stream` (SSE) |
| **长任务** | ❌ | ❌（同步语义） | ✅ 核心能力 |
| **人工介入** | ❌ | Elicitation（有限） | ✅ `input-required` |
| **交付物** | 响应体 | Tool result | **Artifact（多模态）** |
| **权限模型** | 自定义 | OAuth 2.1 推荐 | Agent Card + 委托凭证 |
| **Java 生态成熟度** | ★★★★★ | ★★★★☆（SDK 演进中） | ★★★☆ |
| **典型用途** | 服务契约、SDK 生成 | 给 Agent 挂工具/资源 | 多 Agent 编排、跨团队委托 |

---

## 五、组合架构：三层怎么一起用

真实生产系统里，三者是**叠起来用**的：

```
┌──────────────────────────────────────────────────────────┐
│  用户入口（Chat / IDE / 钉钉）                             │
└───────────────────────┬──────────────────────────────────┘
                        │
        ┌───────────────▼────────────────┐
        │  编排 Agent（Router）            │  ← A2A Client
        │  - 意图识别                      │
        │  - 任务分解                      │
        └───┬────────────┬───────────────┘
            │ A2A        │ A2A
   ┌────────▼──────┐  ┌──▼──────────────┐
   │ 数据 Agent     │  │ 文档 Agent       │
   │ (Text2SQL)    │  │ (PPT/Word)      │
   └────────┬──────┘  └──┬──────────────┘
            │ MCP         │ MCP
   ┌────────▼──────┐  ┌──▼──────────────┐
   │ MCP Server    │  │ MCP Server       │
   │ (DB / 数仓)    │  │ (模板 / 对象存储) │
   └────────┬──────┘  └──┬──────────────┘
            │ OpenAPI     │ OpenAPI
   ┌────────▼─────────────▼──────────────┐
   │  既有微服务（Spring Boot / 老系统）    │
   └─────────────────────────────────────┘
```

**每一层的职责：**

- **最底：OpenAPI** —— 你已有的 300 个 REST 接口，不用改，也不需要为 AI 重写。
- **中间：MCP** —— 把"这个 Agent 需要的那 15 个接口"包装成 MCP Server，加上**面向模型的描述**、**权限收敛**、**超时熔断**。
- **上层：A2A** —— 把"数据 Agent""文档 Agent"当成可委托的服务，用 Task 状态机管理长流程。

**这个分层的好处：**

1. **老系统零改造**：OpenAPI 是既有资产，MCP Server 是适配层；
2. **工具域隔离**：每个 Agent 只暴露自己 MCP Server 的工具，避免"300 个工具塞给一个模型"；
3. **长任务可恢复**：A2A 的 taskId 让"跑 10 分钟的 PPT 生成"变成可查询、可恢复、可人工介入的流程；
4. **权限可收敛**：MCP 层做 scope 校验，A2A 层做 token exchange，两层都不会把用户的超级 token 一路透传到底。

---

## 六、面试追问与踩坑清单

**Q1：MCP 和 Function Calling 是什么关系？**

Function Calling 是**模型侧的能力**（模型输出"我要调这个函数，参数是这些"）；MCP 是**工具侧的协议**（工具怎么被发现、怎么被调、结果怎么回）。二者互补：MCP Server 提供的 tools，最终会被转成模型的 function/tool schema 参与推理。**没有 MCP，Function Calling 照样能用（硬编码工具）；有了 MCP，工具变成可插拔的外部服务。**

**Q2：有了 A2A，还需要 MCP 吗？**

需要。A2A 只解决"Agent 之间怎么委托"，Agent 内部"怎么拿工具、怎么读资源"还是 MCP 的活。类比：A2A 是部门之间的工单系统，MCP 是部门内部的操作台。

**Q3：MCP 的 Tools 和 Resources 有什么区别？**

控制方不同。Tools 由**模型**自主决定调用（所以要有严格的输入校验和权限）；Resources 由**应用**决定何时注入上下文（所以不能由模型随意读取，尤其是敏感文件）。把敏感数据做成 Tool 让模型自由调用是典型的安全反模式。

**Q4：A2A 的 `input-required` 状态解决了什么问题？**

长任务的中途澄清。MCP 的 `tools/call` 是同步语义，没法"挂起 5 分钟等用户回答"；A2A 把任务挂到 `input-required`，调用方补信息后用同一 taskId 续跑。这让"多轮澄清 + 长流程"变成协议级能力，而不是自己造状态表。

**Q5：为什么不能直接把 OpenAPI 全量转成工具？**

三个原因：**上下文爆炸**（300 个 operation ≈ 6 万 token）、**选择准确率下降**（工具数超过 20~30 后明显退化）、**语义缺失**（OpenAPI 的 summary 面向人，不面向模型）。正确做法是切域 + 工具检索 + 人工重写 description。

**踩坑 1：MCP 工具描述写成接口文档。**
"查询订单接口，参数 userId/status"——模型不知道什么时候该用。要写"当用户问'我的订单到哪了'时调用"。

**踩坑 2：MCP 工具没有超时。**
一个下游慢查询把整个会话拖死。客户端必须设 `requestTimeout`，服务端必须有熔断。

**踩坑 3：用 MCP 跑长任务。**
`tools/call` 同步语义，跑 3 分钟必然超时/断连。超过 30 秒的任务，要么改成"提交任务 + 轮询"，要么上 A2A。

**踩坑 4：A2A 里直接透传用户 token。**
Agent 之间互相调用时透传用户 token = 权限放大。必须用 Token Exchange 换收窄 scope 的委托凭证。

**踩坑 5：忽略 `protocolVersion` 协商。**
MCP 和 A2A 都在快速演进（MCP 从 2024-11 到 2025-06 改了三次传输），版本不匹配时的降级行为差异很大。生产环境要**锁定版本 + 做兼容性测试**。

**踩坑 6：把 MCP Server 当无状态服务部署。**
Streamable HTTP 有 `Mcp-Session-Id` 会话，多副本部署必须做**会话粘滞**或**共享会话存储**，否则请求打到别的副本会 404。

---

## 七、总结

| 结论 | 说明 |
|---|---|
| 三者不是竞品 | OpenAPI 描述能力、MCP 暴露能力、A2A 编排能力，**分层叠加** |
| 选型口诀 | 有 REST 接口 → OpenAPI 转 MCP；本地工具 → MCP stdio；跨团队长任务 → A2A |
| MCP 的核心价值 | 工具**可插拔 + 动态发现**，以及"面向模型的描述"这层新语义 |
| A2A 的核心价值 | **Task 状态机**（尤其 `input-required`）+ Artifact 交付物 |
| 最容易翻车的地方 | 工具描述质量、工具数量爆炸、长任务用错协议、权限透传 |
| Java 落地现状 | Spring AI 的 MCP starter 已可用；A2A 官方 Java SDK 在快速演进，生产用需锁版本 |

协议之争最好的结局，不是"谁赢"，而是**大家都变成基础设施**。就像今天没人争论"用 HTTP 还是用 TCP"——它们在不同层，各干各的活。

MCP、A2A、OpenAPI 大概率也会走到这一步：**OpenAPI 继续描述你的老服务，MCP 是你给 Agent 装工具的标准插座，A2A 是 Agent 之间的工单系统。** 一个成熟的 Java 团队，三样都得会。

> 下一篇会写 **MCP Server 的生产化**：多副本会话粘滞、工具级限流与配额、工具调用审计日志、以及"工具描述"的 A/B 评测方法（怎么量化 description 改动的效果）。
