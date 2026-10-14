---
title: 【Java AI】Function Calling 深度实战：工具定义、参数 Schema 与 Spring AI/LangChain4j 落地
date: 2026-10-14 08:30:00
tags:
  - Java
  - AI
  - Function Calling
  - Spring AI
  - LangChain4j
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Function Calling 深度实战：工具定义、参数 Schema 与 Spring AI/LangChain4j 落地

## 前言

如果只让大模型"聊天"，它就是个更聪明的搜索引擎。**Function Calling（工具调用）是让 LLM 从"说"变成"做"的分水岭**：模型不再直接编造答案，而是输出一个结构化的"我要调用哪个函数、传什么参数"的意图，由你的 Java 程序真正执行，再把结果喂回模型。

对 Java 后端来说，这几乎是一个"平行世界已经熟悉的模式"：**模型 ≈ 服务发现 + 参数编排，函数 ≈ 你的 Service 方法，Schema ≈ 接口契约**。你写过的那些 `@RestController` + DTO 校验，在这里以 `@Tool` + JSON Schema 的形式重演。

这篇文章面向"想用 Java 落地 Agent"的工程师，讲清三件事：

1. Function Calling 的**协议本质**（模型到底输出了什么）；
2. **Spring AI** 与 **LangChain4j** 两套 Java 框架的落地写法；
3. 生产级**参数校验、错误处理、多工具编排、安全**与面试追问。

## 一、Function Calling 的本质：一次"结构化输出 + 二次调用"

很多人把 Function Calling 想得太玄。剥开看，它是**两轮请求 + 一次本地执行**：

```
第 1 轮：用户问题 + 工具清单（tools 定义）
         └─> 模型返回 finish_reason=tool_calls，内容是"要调用 getWeather(city=北京)"

本地执行：你的 Java 代码解析 tool_calls，反射调用真实方法，拿到结果

第 2 轮：把"工具执行结果"作为 role=tool 的消息追加，再问模型
         └─> 模型基于真实结果生成自然语言回答
```

关键认知：**模型不执行任何函数，它只输出"意图"（函数名 + JSON 参数）**。真正执行的永远是你的代码。这也意味着：**安全边界在你的代码里，不在模型里**——模型可能请求一个你不该暴露的权限，你必须自己把关。

### 工具定义的真相：本质是一段 JSON Schema

OpenAI 风格的工具定义长这样：

```json
{
  "type": "function",
  "function": {
    "name": "getWeather",
    "description": "查询指定城市的实时天气",
    "parameters": {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "城市名，如 北京" },
        "unit": { "type": "string", "enum": ["celsius", "fahrenheit"] }
      },
      "required": ["city"]
    }
  }
}
```

对 Java 工程师，这一段应该立刻唤起熟悉感：**这就是一个带注释的接口契约**。`description` 就是你的接口文档，`required` 就是 `@NotNull`，`enum` 就是枚举校验。区别在于：**这份契约是给"模型"看的，模型根据描述决定何时调用**——所以描述质量直接决定调用准确率。

## 二、Spring AI 落地：`@Tool` 注解

Spring AI 1.0 之后把 Function/Tool 统一为 **`@Tool`** 注解，配合 `ChatClient` 使用，写法非常 Spring：

```java
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.ai.chat.client.ChatClient;

@Service
public class WeatherTools {

    @Tool(description = "查询指定城市的实时天气")
    public Weather getWeather(
            @ToolParam(description = "城市名，如 北京") String city,
            @ToolParam(description = "温度单位: celsius 或 fahrenheit", required = false) String unit) {
        // 真实业务：调用内部天气服务
        return weatherService.query(city, unit == null ? "celsius" : unit);
    }

    @Tool(description = "查询某订单的当前状态")
    public OrderStatus getOrderStatus(
            @ToolParam(description = "订单号，18 位数字") String orderId) {
        return orderService.findStatus(orderId);
    }
}

@RestController
public class ChatController {

    private final ChatClient chatClient;

    public ChatController(ChatClient.Builder builder, WeatherTools weatherTools) {
        this.chatClient = builder
                .defaultSystem("你是一个助手，需要天气或订单信息时必须调用工具，不要编造。")
                .defaultTools(weatherTools)   // 注册工具
                .build();
    }

    @GetMapping("/chat")
    public String chat(@RequestParam String q) {
        return chatClient.prompt()
                .user(q)
                .call()
                .content();
    }
}
```

Spring AI 内部做了几件事：

1. 扫描 `@Tool` 方法，**根据方法签名 + 注解生成 JSON Schema**（参数名、类型、描述、required）；
2. 把 Schema 随请求发给模型；
3. 模型返回 tool_calls 时，Spring AI **反射调用你的方法**，并把结果序列化后回填；
4. 支持**自动多轮**（模型连续调用多个工具直到给出最终答案）。

> 注意：`@Tool` 的 `description` 和 `@ToolParam` 的 `description` **不是给人看的注释，而是给模型的 prompt**。写得越清楚，模型选错工具的概率越低。

## 三、LangChain4j 落地：`@Tool` + `AiServices`

LangChain4j 的风格更"显式"，同样用 `@Tool`（`dev.langchain4j.agent.tool.Tool`）：

```java
import dev.langchain4j.agent.tool.Tool;
import dev.langchain4j.agent.tool.P;
import dev.langchain4j.service.AiServices;

public class OrderTools {

    @Tool("查询订单状态，返回订单的当前状态与物流信息")
    public String orderStatus(@P("订单号，18 位数字") String orderId) {
        return orderService.findStatus(orderId).toString();
    }

    @Tool("对指定订单发起退款，需订单号与退款金额（分）")
    public String refund(@P("订单号") String orderId,
                         @P("退款金额，单位为分") long amountInCents) {
        return refundService.refund(orderId, amountInCents) ? "退款已受理" : "退款失败";
    }
}

interface Assistant {
    String chat(String message);
}

public class AgentApp {
    public static void main(String[] args) {
        ChatLanguageModel model = OpenAiChatModel.builder()
                .apiKey(System.getenv("OPENAI_API_KEY"))
                .modelName("gpt-4o-mini")
                .build();

        Assistant assistant = AiServices.builder(Assistant.class)
                .chatLanguageModel(model)
                .tools(new OrderTools())
                .build();

        System.out.println(assistant.chat("帮我查下订单 123456789012345678 的状态"));
    }
}
```

LangChain4j 的特点：

- **`AiServices` 把"工具 + 模型 + 记忆"组合成一个接口代理**，你只面向 `Assistant` 接口编程；
- 支持**多轮工具调用**（`hallucinatedTool` 防护、最大迭代次数控制）；
- 与 `ChatMemory`、`RetrievalAugmentor`（RAG）无缝组合，适合做完整 Agent。

### Spring AI vs LangChain4j：怎么选

| 维度 | Spring AI | LangChain4j |
|---|---|---|
| 生态 | Spring 官方，跟 Spring Boot 自动配置深度集成 | 独立库，Spring 可集成 |
| 工具定义 | `@Tool` / `@ToolParam` | `@Tool` / `@P` |
| 面向风格 | `ChatClient` 流式链式调用 | `AiServices` 接口代理 |
| RAG | `VectorStore` + `Advisor` | `EmbeddingStore` + `RetrievalAugmentor` |
| Agent 能力 | 偏"应用集成"，Agent 编排需自己做 | 内置较多 Agent 抽象（工具、记忆、多轮） |
| 适合 | 已有 Spring 体系、想低侵入加 AI 能力 | 想做较完整 Agent / 多模型切换 |
| 观测 | Micrometer 原生 | 可接 Micrometer / LangSmith 风格 |

实战建议：**以 Spring 为主技术栈的团队优先 Spring AI**（配置、Bean、Actuator、可观测是现成的）；**要做重 Agent 编排、多模型切换的，LangChain4j 的抽象更顺手**。两者并不互斥。

## 四、生产级关键问题

### 4.1 参数校验：模型会"填错"

模型生成的 JSON 参数**经常不符合约束**：数字传成字符串、必填项缺失、枚举值编造。两层防御：

```java
@Tool(description = "查询订单状态")
public String orderStatus(@ToolParam(description = "18 位数字订单号") String orderId) {
    // ① 硬校验：绝不相信模型给的参数
    if (orderId == null || !orderId.matches("\\d{18}")) {
        return "参数错误：订单号必须是 18 位数字，请重新提供。"; // 把错误"返回给模型"
    }
    return orderService.findStatus(orderId).toString();
}
```

要点：**校验失败时不要把异常直接抛给框架**，而是**把"自然语言的错误信息"作为工具结果返回给模型**，让模型自我修正后重试。这是 Agent 自愈能力的一部分。

### 4.2 错误处理：工具抛异常怎么办

工具体内部调用下游失败（超时、500）时，直接抛异常会中断整条链路。更稳的做法是**把失败也结构化返回**：

```java
@Tool(description = "查询订单状态")
public String orderStatus(String orderId) {
    try {
        return orderService.findStatus(orderId).toString();
    } catch (FeignException.NotFound e) {
        return "未找到订单 " + orderId + "，请确认订单号。";
    } catch (Exception e) {
        log.warn("tool failed", e);
        return "系统繁忙，暂时无法查询，请稍后重试。";
    }
}
```

模型拿到"失败描述"后，可以决定"换个参数重试"或"告知用户"。同时你需要在**平台侧**限制最大工具调用轮数，防止模型陷入"失败→重试→失败"的无限循环。

### 4.3 多工具并行调用

现代模型支持一次返回**多个 tool_calls**（并行工具调用）。例如用户问"北京和上海今天天气"，模型可同时请求 `getWeather(北京)` 与 `getWeather(上海)`。框架通常会并行执行这些调用（Spring AI / LangChain4j 都支持），再把多个结果一起回填。

你在设计工具时要注意**幂等与并发安全**——并行调用意味着同一个工具体可能被同时进入。

### 4.4 安全：别把"内部接口"整个暴露给模型

这是最容易被忽视的。**工具集就是你的攻击面**：

- **最小权限**：只暴露必要的工具，`refund`、`deleteUser` 这类高危操作要么不暴露，要么加审批；
- **参数注入**：工具参数若被拼进 SQL / 命令 / URL，模型可能被诱导注入恶意值 → 必须参数化、白名单；
- **越权**：模型不知道"当前用户是谁"，工具体内要用**当前会话的用户身份**做鉴权，绝不能只信模型给的 `userId` 参数；
- **人工确认**：金额、删除、转账类工具，执行前走 human-in-the-loop 确认。

```java
@Tool(description = "发起退款")
public String refund(
        @ToolParam(description = "订单号") String orderId,
        @ToolParam(description = "退款金额（分）") long amount) {
    // 身份来自服务端上下文，绝不来自模型参数
    User current = SecurityContextHolder.getContext().getUser();
    if (!orderService.isOwner(current, orderId)) {
        return "无权操作该订单。";
    }
    if (amount > current.getRefundLimit()) {
        return "超过单笔退款限额，需人工审批。";
    }
    return refundService.refund(orderId, amount) ? "退款已受理" : "退款失败";
}
```

## 五、与 MCP 的关系

Function Calling 是**"模型 ↔ 你的应用"**的调用协议；而 **MCP（Model Context Protocol）** 是**"应用 ↔ 工具服务"**的标准化协议。二者层次不同：

- 你实现了 Function Calling，就能让一次对话调用工具；
- 你把工具封装成 **MCP Server**，就能让**任意**支持 MCP 的客户端（Claude Desktop、IDE、你的 Agent）复用同一套工具，无需每个平台重写。

Java 生态里可以用 **Spring AI 的 MCP 支持** 或 **LangChain4j 的 MCP** 把现有 `@Tool` 直接暴露为 MCP Server。这也是"Java 后端技能平移到 AI"的绝佳落点：**你熟悉的服务治理思想（接口契约、鉴权、限流、可观测），在 MCP 里几乎原样重演。**

## 六、面试高频追问

**Q1：Function Calling 和 RAG 的区别？**
RAG 是"**注入知识**"（检索文档塞进上下文），解决"模型不知道你的私有知识"；Function Calling 是"**执行动作 / 取实时数据**"，解决"模型不能实时查询或操作"。两者常一起用：先 RAG 找依据，再 Function Calling 查实时状态。

**Q2：模型怎么决定调用哪个工具？**
靠**工具名 + description + 参数 Schema** 与用户意图的语义匹配（本质是模型内部的模式识别）。所以**描述写得好不好，直接决定准确率**。工具太少或描述模糊会"该调不调"，工具太多会"调错"。

**Q3：工具调用的结果会进入上下文吗？会消耗 token 吗？**
会。工具返回结果会作为消息追加进对话历史，**计入上下文与计费**。所以工具应**返回精简结构化数据**，而不是把一整张表 dump 回去。

**Q4：如何防止模型编造不存在的工具或参数？**
参数 Schema 用 `enum` 约束取值、`required` 约束必填；服务端**永远二次校验**；开启框架的严格模式（如 OpenAI `strict: true` 结构化输出）能显著降低"编造"。

**Q5：多个工具可以并行调用吗？Java 里怎么处理？**
可以。模型一次返回多个 `tool_calls`，框架并发执行（可用虚拟线程 / 线程池），结果按 `tool_call_id` 配对回填。注意工具体要线程安全 + 幂等。

**Q6：工具调用需要幂等吗？为什么？**
需要。网络重试、模型重试、并行调用都可能导致同一工具被重复执行。写操作类工具（下单、退款）必须有幂等键。

## 七、踩坑清单

1. **`description` 是 prompt，不是注释**——认真写，包含"何时用、参数含义、边界"。
2. **绝不信任模型给的参数**——服务端二次校验 + 参数化查询。
3. **鉴权用服务端身份，不用模型参数**。
4. **工具失败返回自然语言，而非抛异常**，让模型自愈；同时限制最大轮数防死循环。
5. **工具返回值要精简**，否则 token 成本与上下文迅速膨胀。
6. **高危工具加人工确认 / 审批流**。
7. **给工具调用打日志 + Trace**（工具名、参数、耗时、结果状态），这是 AI 应用可观测的基本盘。

## 八、小结

Function Calling 是 Java 工程师切入 AI 应用开发的"最短路径"：你已有的**接口契约、参数校验、鉴权、幂等、可观测**经验，几乎可以平移过来，只是把"给前端看的契约"换成"给模型看的 Schema"。掌握 Spring AI 的 `@Tool` 与 LangChain4j 的 `AiServices`，再补上**校验、错误自愈、安全边界、MCP 复用**这四块，你就能把一个"会聊天的模型"变成"能干活的应用"——这正是 AI 应用开发岗最核心的日常。
