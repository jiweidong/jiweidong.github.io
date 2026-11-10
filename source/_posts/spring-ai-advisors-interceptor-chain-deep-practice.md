---
title: 【Java AI】Spring AI Advisors 拦截链深度实战：ChatMemory、RAG 与自定义 Advisor 的执行顺序与上下文改写
date: 2026-11-10 08:15:00
tags:
  - Java
  - Spring AI
  - AI
  - Advisor
  - RAG
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Spring AI Advisors 拦截链深度实战

## 前言

写过 Spring MVC 的人，看到 `HandlerInterceptor` 都会觉得很自然：请求进来先过一遍拦截器，出去再回一遍，鉴权、日志、耗时统计全都挂在这条链上。

Spring AI 把这套思想原封不动搬到了 LLM 调用上，叫 **Advisor**。它是 `ChatClient` 的**环绕通知（around advice）**：你可以在 prompt 发给模型之前改写它，在响应回来之后加工它，也可以在这一层做重试、降级、缓存、审计、Token 记账。

为什么这个机制值得单独写一篇？因为**几乎所有生产级 AI 应用的横切关注点，最后都落在 Advisor 上**：

- 多轮对话记忆（`MessageChatMemoryAdvisor`）
- RAG 检索注入（`QuestionAnswerAdvisor`）
- 日志与 Trace（`SimpleLoggerAdvisor`）
- 内容护栏（`SafeGuardAdvisor`）
- Token 计量与成本账本
- 重试 / 降级 / 超时
- Prompt 版本与灰度

但官方文档只给了"怎么加一个 Advisor"，没讲**顺序错了会怎样**、**流式下 after 为什么拿不到完整响应**、**为什么你的历史消息翻倍了**。这篇补上这些。

> 版本说明：Spring AI 1.x 的 Advisor API 在里程碑版本间有过调整（早期是 `RequestResponseAdvisor` + `adviseRequest/adviseResponse`，1.0 起是 `CallAdvisor` / `StreamAdvisor` + `adviseCall/adviseStream`）。下面以 1.x 为主线，涉及具体方法签名的地方请以你引入的版本为准。

---

## 一、Advisor 在调用链的哪个位置

先建立一张全景图，不然后面顺序问题讲不清：

```
业务代码
  └─ ChatClient.prompt()...call()
       ├─ Advisor 1 (order=0)    ← 最外层
       │   ├─ Advisor 2 (order=100)
       │   │   ├─ Advisor 3 (order=200)
       │   │   │   └─ ChatModel.call()  → HTTP → LLM
       │   │   └─ after()
       │   └─ after()
       └─ after()
```

两条铁律：

1. **order 数值越小越靠外层**（和 Spring 的 `Ordered` 一致）。所以 `order=0` 的 `before()` 最先执行，`after()` 最后执行。
2. **`before()` 里改写的是"往下传的请求"，`after()` 里改写的是"往上传的响应"**。想影响模型输入就改 request，想影响业务拿到的结果就改 response。

对比一下 Spring 生态里几种"拦截"机制，选型时不容易搞混：

| 机制 | 作用对象 | 能否改写请求 | 能否改写响应 | 典型用途 |
|---|---|---|---|---|
| Servlet `Filter` | HTTP 请求 | ✅（包装 request） | ✅（包装 response） | 编码、CORS、全链路 TraceId |
| Spring MVC `HandlerInterceptor` | 控制器方法 | ⚠️ 只能读，改要包装 | ⚠️ 有限 | 鉴权、日志 |
| AOP `@Around` | 任意方法 | ✅（改参数） | ✅（改返回值） | 事务、缓存、监控 |
| **Spring AI `Advisor`** | **LLM 调用** | ✅（改 Prompt/上下文） | ✅（改 ChatResponse） | **记忆、RAG、护栏、计量** |

Advisor 和 AOP 长得很像，但有一个本质区别：**它操作的是"语义化的 Prompt 对象"，不是方法参数**。这让"往 system message 里塞一段检索到的文档"变成一行代码，而不是字符串拼接。

---

## 二、两个接口：CallAdvisor 与 StreamAdvisor

### 2.1 接口形态

```java
public interface CallAdvisor extends Advisor {
    ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain);
}

public interface StreamAdvisor extends Advisor {
    Flux<ChatClientResponse> adviseStream(ChatClientRequest request, StreamAdvisorChain chain);
}
```

`Advisor` 本身继承 `Ordered`，所以要实现 `getOrder()`（或用 `order(int)` 在注册时指定）。

绝大多数场景你只需要实现 **`BaseAdvisor`**，它把"前置/后置"拆开了：

```java
public interface BaseAdvisor extends CallAdvisor, StreamAdvisor {

    default ChatClientRequest before(ChatClientRequest request, AdvisorChain chain) {
        return request;
    }

    default ChatClientResponse after(ChatClientResponse response, AdvisorChain chain) {
        return response;
    }

    // 框架用这两个默认方法把 before/after 串成环绕
    @Override
    default ChatClientResponse adviseCall(ChatClientRequest req, CallAdvisorChain chain) {
        ChatClientRequest processed = before(req, chain);
        ChatClientResponse resp = chain.nextCall(processed);
        return after(resp, chain);
    }

    @Override
    default Flux<ChatClientResponse> adviseStream(ChatClientRequest req, StreamAdvisorChain chain) {
        ChatClientRequest processed = before(req, chain);
        return chain.nextStream(processed).map(r -> after(r, chain));
    }
}
```

**注意 `adviseStream` 的 `after` 是"每个 chunk 调一次"**，不是"流结束时调一次"。这是流式场景下最容易写错的地方（后面第六节详述）。

### 2.2 请求与响应对象里有什么

```java
ChatClientRequest  req  = ...;
Prompt        prompt = req.prompt();     // messages + options
Map<String,Object> ctx = req.context();  // 跨 Advisor 传递的上下文（只读视图）

ChatClientResponse resp = ...;
ChatResponse  cr    = resp.chatResponse(); // 可能为 null（流式 chunk）
Map<String,Object> ctx2 = resp.context();
```

`context()` 是 Advisor 之间**传递元数据的通道**，也是和业务代码通信的通道：

```java
chatClient.prompt()
        .user("帮我查下订单")
        .advisors(a -> a
                .param("tenantId", tenantId)        // 业务传参
                .param("traceId", MDC.get("traceId")))
        .call()
        .content();
```

Advisor 里这样取：

```java
String tenantId = (String) request.context().get("tenantId");
```

这条链路非常有用：**你可以让业务代码只传一个 `tenantId`，由 Advisor 自动拼进 RAG 的过滤条件和 system prompt**，业务侧完全不需要知道 RAG 的存在。

---

## 三、内置 Advisor 清单与顺序陷阱

Spring AI 自带这些（1.x）：

| Advisor | 作用 | 建议 order | 备注 |
|---|---|---|---|
| `SimpleLoggerAdvisor` | 打印请求/响应 | 最小（最外层） | 想看**原始**请求就放最外；想看加工后请求就放最内 |
| `MessageChatMemoryAdvisor` | 按会话存取消息历史 | 小（靠外） | 存原始用户问题，别存拼接后的巨型 prompt |
| `PromptChatMemoryAdvisor` | 把记忆塞进 system prompt | 小（靠外） | 和上者二选一，别同时用 |
| `VectorStoreChatMemoryAdvisor` | 向量化长期记忆 | 小 | 检索型记忆，注意延迟 |
| `QuestionAnswerAdvisor` | RAG：检索 + 注入文档 | 中 | 官方推荐 0，按场景调 |
| `SafeGuardAdvisor` | 敏感词/护栏 | 很小（最外层） | 必须在最外层拦，不然白拦 |
| `ReReadingAdvisor` | 让模型复读问题（提升推理） | 中 | 会增加 token |

### 3.1 头号陷阱：memory 和 RAG 的顺序反了

这是我在真实项目里见过最多的坑，症状是：**多轮对话到第 3 轮，prompt 从 800 token 涨到 12000 token，成本翻 10 倍**。

原因链条：

```
memory 在内层（order 大）
  → RAG 先检索，把 6 段文档拼进 user message
  → memory 的 before() 把这条"已经拼接了文档"的 user message 存进历史
  → 下一轮把历史全部带上
  → 历史里全是文档正文 → prompt 爆炸
```

正确做法是 **memory 在外层（order 更小）**：

```java
ChatClient client = ChatClient.builder(chatModel)
        .defaultAdvisors(
                MessageChatMemoryAdvisor.builder(chatMemory).order(0).build(),   // 最外层：先取历史，后存原始问题
                QuestionAnswerAdvisor.builder(vectorStore)
                        .searchRequest(SearchRequest.builder().topK(4).build())
                        .order(100)                                              // 内层：注入文档
                        .build()
        )
        .build();
```

这样 memory 存的是**用户原始问题**，RAG 注入只发生在"发给模型的那一份"上，不进历史。

> 但要注意：如果 memory 在外层，检索时用的 query 是"带历史的消息列表"，`QuestionAnswerAdvisor` 默认取最后一条 user message 做检索。多轮指代（"那它的价格呢"）会检索不准。这时要么在 RAG 之前加一个 **query 改写 Advisor**（把指代补全成独立问题），要么显式传 `searchRequest` 的 query。这是个典型的"顺序换来的新问题"，得知道自己在换什么。

### 3.2 二号陷阱：Advisor 被注册两遍

```java
// 全局注册了
.defaultAdvisors(MessageChatMemoryAdvisor.builder(memory).build())

// 单次调用又加了一遍
.advisors(MessageChatMemoryAdvisor.builder(memory).build())
```

结果：历史消息被 `before()` 插入两次 → 模型看到重复对话 → 回答开始复读。

**规则：Advisor 是有状态/有副作用的，同一种只能挂一次。** 建议只在 `defaultAdvisors` 注册，单次调用只传 `param`。

### 3.3 三号陷阱：护栏放错位置

`SafeGuardAdvisor` 如果 order 比 RAG 大（在内层），那么检索到的文档里如果含有违规内容，它拦不住——因为它只检查了用户输入，而文档是 RAG 注入的。

**护栏永远放最外层**（order 最小），且要**两个方向都查**：`before()` 查输入，`after()` 查输出。输入拦的是用户，输出拦的是模型（含 RAG 注入导致的中毒输出）。

---

## 四、实战：四个生产级自定义 Advisor

### 4.1 Token 计量与成本账本

最刚需的一个。LLM 应用不做 Token 记账，等于电商不做订单金额。

```java
@Component
public class TokenAccountingAdvisor implements CallAdvisor, StreamAdvisor {

    private static final Logger log = LoggerFactory.getLogger(TokenAccountingAdvisor.class);

    private final MeterRegistry meterRegistry;
    private final TokenPriceTable priceTable;   // 按 model 查单价

    public TokenAccountingAdvisor(MeterRegistry meterRegistry, TokenPriceTable priceTable) {
        this.meterRegistry = meterRegistry;
        this.priceTable = priceTable;
    }

    @Override
    public String getName() {
        return "token-accounting";
    }

    @Override
    public int getOrder() {
        return 900;   // 靠内层：拿到的是已加工请求 + 真实 usage
    }

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain) {
        long start = System.nanoTime();
        ChatClientResponse response = chain.nextCall(request);
        record(request, response, System.nanoTime() - start, false);
        return response;
    }

    @Override
    public Flux<ChatClientResponse> adviseStream(ChatClientRequest request, StreamAdvisorChain chain) {
        long start = System.nanoTime();
        // 流式 usage 通常在最后一个 chunk 的 metadata 里
        AtomicReference<ChatClientResponse> last = new AtomicReference<>();
        return chain.nextStream(request)
                .doOnNext(last::set)
                .doFinally(signal -> record(request, last.get(), System.nanoTime() - start, true));
    }

    private void record(ChatClientRequest req, ChatClientResponse resp, long nanos, boolean streaming) {
        if (resp == null || resp.chatResponse() == null) {
            return;
        }
        var usage = resp.chatResponse().getMetadata().getUsage();
        if (usage == null) {
            return;   // 有些模型/网关不返回 usage，必须容忍 null
        }
        String model = resp.chatResponse().getMetadata().getModel();
        String tenant = String.valueOf(req.context().getOrDefault("tenantId", "unknown"));

        long prompt = usage.getPromptTokens();
        long completion = usage.getCompletionTokens();
        double cost = priceTable.cost(model, prompt, completion);

        meterRegistry.counter("llm.tokens",
                "model", model, "type", "prompt", "tenant", tenant).increment(prompt);
        meterRegistry.counter("llm.tokens",
                "model", model, "type", "completion", "tenant", tenant).increment(completion);
        meterRegistry.counter("llm.cost.usd", "model", model, "tenant", tenant).increment(cost);

        log.info("llm usage tenant={} model={} prompt={} completion={} cost={} stream={} elapsedMs={}",
                tenant, model, prompt, completion, String.format("%.6f", cost), streaming, nanos / 1_000_000);
    }
}
```

三个必须容忍的边界：

- `usage` 可能为 `null`（部分兼容 OpenAI 协议的网关不返回）
- `getModel()` 可能返回 `null`
- 流式场景下前面的 chunk 全是空 `chatResponse`，**不要在每个 chunk 里记账**

### 4.2 重试与降级 Advisor

```java
@Component
public class ResilientCallAdvisor implements CallAdvisor {

    private final RetryTemplate retry;       // spring-retry
    private final ChatModel fallbackModel;   // 备用模型

    @Override public String getName() { return "resilient"; }
    @Override public int getOrder() { return 950; }   // 紧贴模型调用

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain) {
        return retry.execute(ctx -> {
            try {
                return chain.nextCall(request);
            } catch (NonRetryableAiException e) {
                throw e;
            } catch (RuntimeException e) {
                // 限流/5xx/超时才重试；4xx 参数错误重试没用
                ctx.setAttribute("lastError", e);
                throw e;
            }
        }, ctx -> {
            // 重试耗尽 → 降级到备用模型（直接调 ChatModel，绕过 advisor chain）
            log.warn("primary model exhausted, fallback", ctx.getLastThrowable());
            ChatResponse r = fallbackModel.call(request.prompt());
            return ChatClientResponse.builder().chatResponse(r).build();
        });
    }
}
```

**关键设计点**：降级走 `fallbackModel.call()` 而不是 `chain.nextCall()`。因为 `nextCall` 会再次进入内层 Advisor 链，可能触发第二次重试，形成"重试套重试"。降级路径要**明确、短、可控**。

### 4.3 输出结构校验 Advisor（结构化输出的兜底）

`BeanOutputConverter` 解析失败是常态（模型偶尔会加 ```json 围栏或多余说明）。用 Advisor 做"解析失败 → 自动重试一次"：

```java
public class JsonRepairAdvisor implements CallAdvisor {

    private final BeanOutputConverter<?> converter;
    private final ChatModel model;

    @Override public int getOrder() { return 800; }

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain) {
        ChatClientResponse resp = chain.nextCall(request);
        String text = resp.chatResponse().getResult().getOutput().getText();
        try {
            converter.convert(text);
            return resp;   // 解析成功，直接返回
        } catch (Exception e) {
            log.warn("structured output parse failed, retry with repair prompt");
            Prompt repair = new Prompt(List.of(
                    new SystemMessage("你是 JSON 修复器。只输出合法 JSON，不要任何解释和代码围栏。"),
                    new UserMessage("把下面的内容修复成符合 schema 的 JSON：\n" + text + "\n\nschema:\n"
                            + converter.getJsonSchema())
            ));
            ChatResponse fixed = model.call(repair);
            return ChatClientResponse.builder()
                    .chatResponse(fixed)
                    .context(resp.context())
                    .build();
        }
    }
}
```

**为什么放在 Advisor 而不是业务代码里**？因为所有用结构化输出的地方都需要它，而业务代码里每处都写一遍 `try-catch + 重试` 是灾难。这是横切关注点的经典定义。

### 4.4 Prompt 版本注入 Advisor

```java
public class PromptVersionAdvisor implements CallAdvisor {

    private final PromptRegistry registry;   // 从配置中心/DB 读版本化 prompt

    @Override public int getOrder() { return 100; }   // 靠外层，在 RAG 之前定 system prompt

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest request, CallAdvisorChain chain) {
        String version = (String) request.context().getOrDefault("promptVersion", "stable");
        String systemPrompt = registry.get("order-assistant", version);

        // 在 system message 里追加（保留原有的，不覆盖）
        Prompt augmented = request.prompt().augmentSystemMessage(
                sys -> sys.getText() + "\n\n" + systemPrompt);

        return chain.nextCall(
                ChatClientRequest.builder().prompt(augmented).context(request.context()).build());
    }
}
```

`augmentSystemMessage` 比"自己 new 一个 Prompt 拼 messages"安全得多——它保留原有的 options、tools、media 等信息，只改文本。

---

## 五、注册方式：全局 vs 单次

```java
@Configuration
public class ChatClientConfig {

    @Bean
    public ChatClient chatClient(ChatModel model,
                                 ChatMemory memory,
                                 VectorStore vectorStore,
                                 List<Advisor> advisors) {   // 自动收集所有 Advisor Bean
        return ChatClient.builder(model)
                .defaultSystem("你是东哥商城的订单助手，回答要简洁。")
                .defaultAdvisors(
                        new SafeGuardAdvisor(List.of("密码", "身份证"), 0),   // 最外层
                        MessageChatMemoryAdvisor.builder(memory).order(10).build(),
                        new PromptVersionAdvisor(registry),
                        QuestionAnswerAdvisor.builder(vectorStore).order(200).build(),
                        new TokenAccountingAdvisor(meterRegistry, priceTable),
                        new SimpleLoggerAdvisor()
                )
                .build();
    }
}
```

单次调用只传参数，不重复加 Advisor：

```java
String answer = chatClient.prompt()
        .user(question)
        .advisors(a -> a
                .param(ChatMemory.CONVERSATION_ID, conversationId)
                .param("tenantId", tenantId)
                .param("promptVersion", "v3"))
        .call()
        .content();
```

### 5.1 顺序总表（可直接抄）

| order | Advisor | 理由 |
|---|---|---|
| 0 | `SafeGuardAdvisor`（输入侧） | 最外层，最先拦恶意输入 |
| 10 | `SimpleLoggerAdvisor` | 记录原始请求 |
| 20 | `MessageChatMemoryAdvisor` | 取历史、存原始问题 |
| 100 | `PromptVersionAdvisor` | 定 system prompt |
| 200 | `QueryRewriteAdvisor`（可选） | 指代消解，为检索准备独立 query |
| 300 | `QuestionAnswerAdvisor` | 注入检索文档 |
| 900 | `TokenAccountingAdvisor` | 拿真实 usage |
| 950 | `ResilientCallAdvisor` | 紧贴模型调用，重试/降级 |
| `MAX` | 输出护栏（after） | 最后一个看输出 |

> 这张表是"默认合理值"，不是教条。**判断原则只有一条：谁的输出是谁的输入。** 依赖关系决定顺序。

---

## 六、流式场景的四个坑

### 6.1 `after()` 每个 chunk 都会调

```java
@Override
public Flux<ChatClientResponse> adviseStream(ChatClientRequest req, StreamAdvisorChain chain) {
    return chain.nextStream(req).map(r -> {
        // ⚠️ 这里会执行 N 次（N = chunk 数）
        // 别在这里做：写库、发消息、累加计数器、调用外部 API
        return r;
    });
}
```

正确姿势：`doOnNext` 收集、`doFinally` 收尾，或者用 `Flux` 的 `reduce`/`last`。

### 6.2 流式下改写输出很难

`CallAdvisor` 的 `after()` 可以返回一个全新的 `ChatClientResponse`，因为此时文本已经完整。但**流式下你拿到的是增量 token，想"改写整段文本"必须先聚合**，而聚合会破坏流式的意义（用户要边生成边看）。

所以原则是：

- **流式下只做"观察"和"增量过滤"**（如敏感词逐字过滤、字符计数）
- **需要整段改写的能力（如 JSON 修复、二次总结）放到非流式路径**，或者流结束后在应用层做
- 输出护栏在流式下要么做"逐 chunk 滑动窗口匹配"，要么在结束时做"事后审计 + 告警"，不要在流中间阻塞

### 6.3 阻塞调用会毁掉流

```java
// ❌ 在流式管道里做同步 HTTP / JDBC
return chain.nextStream(req).map(r -> {
    auditService.save(r);       // 阻塞！整个流被拖慢
    return r;
});

// ✅ 异步/批量
return chain.nextStream(req)
        .doOnNext(r -> auditQueue.offer(r))   // 有界队列 + 后台批写
        .doOnError(e -> log.error("stream error", e));
```

WebFlux 的事件循环线程被阻塞，症状是"流式响应卡顿 + 吞吐骤降"，而且线程栈上什么都看不出来（因为不是死锁，是慢）。

### 6.4 取消（cancel）要能清理

用户关掉页面 → 客户端断开 → `Flux` 被 cancel。这时候：

- 已消耗的 Token **照样计费**（模型那边已经生成了）
- 你的"记账"如果只在 `doOnComplete` 里做，会漏
- 用 `doFinally(signalType -> ...)`，`signalType` 包含 `CANCEL`

---

## 七、可观测性：把 Advisor 链接进 Trace

Advisor 天然是埋点的最佳位置，因为它是唯一"能看到完整请求和响应"的地方。

```java
@Component
public class TracingAdvisor implements CallAdvisor, StreamAdvisor {

    private final Tracer tracer;

    @Override public int getOrder() { return 850; }

    @Override
    public ChatClientResponse adviseCall(ChatClientRequest req, CallAdvisorChain chain) {
        Span span = tracer.nextSpan()
                .name("llm.call")
                .tag("gen_ai.system", "openai")
                .tag("gen_ai.request.model", modelName(req))
                .tag("llm.prompt.messages", String.valueOf(req.prompt().getInstructions().size()))
                .tag("tenant.id", String.valueOf(req.context().get("tenantId")))
                .start();

        try (Tracer.SpanInScope ws = tracer.withSpan(span)) {
            ChatClientResponse resp = chain.nextCall(req);
            var usage = resp.chatResponse().getMetadata().getUsage();
            if (usage != null) {
                span.tag("gen_ai.usage.input_tokens", String.valueOf(usage.getPromptTokens()));
                span.tag("gen_ai.usage.output_tokens", String.valueOf(usage.getCompletionTokens()));
            }
            return resp;
        } catch (RuntimeException e) {
            span.tag("error", e.getClass().getSimpleName());
            throw e;
        } finally {
            span.end();
        }
    }
}
```

**注意：不要把完整 prompt 原文当 span tag 打进去。** 里面有用户隐私、有检索到的内部文档。要么做脱敏摘要，要么只打 message 数量和长度。这是最常见的合规事故。

---

## 八、面试常见追问

**Q1：Advisor 和 AOP 有什么区别？为什么不直接用 `@Around` 切 `ChatModel.call()`？**
A：技术上可以，但会丢掉三样东西：① **语义**——AOP 只能拿到 `Prompt` 参数，无法区分"这是用户输入还是 RAG 注入的文档"；② **组合性**——Advisor 有 order、有 context 通道、可全局注册可单次覆盖，AOP 的切点表达式做不到"按租户动态启停"；③ **流式支持**——`StreamAdvisor` 直接操作 `Flux`，AOP 切 `Flux` 返回值需要在业务层做 `doOnNext`，侵入性强。Advisor 本质是"为 LLM 调用设计的领域特定中间件"。

**Q2：为什么 memory advisor 要在 RAG 外层？**
A：因为 memory 的职责是"存用户说的话"，RAG 的职责是"给模型补知识"。如果 memory 在内层，它存的是已经被 RAG 拼接过的巨型 user message，历史会随轮次线性膨胀（每轮都带上一轮的全文文档）。放外层则历史里只有原始问题。代价是检索 query 可能带指代（"那它的价格呢"），需要额外的 query 改写。

**Q3：流式响应下怎么统计 Token？**
A：两条路：① 从最后一个 chunk 的 `metadata.usage` 取（OpenAI 兼容协议通常在 `stream_options: {include_usage: true}` 时返回）；② 网关/模型不返回 usage 时，用 tokenizer 本地估算（会有 5%~15% 偏差，只用于监控不用计费）。实现上必须用 `doFinally`，否则客户端 cancel 时会漏记。

**Q4：Advisor 里抛异常会怎样？**
A：异常会沿链向外传播，最终抛给业务代码。**内层 Advisor 抛的异常，外层 Advisor 的 `after()` 不会执行**（因为没有正常返回值）。所以：① 不要在 `after()` 里做必须执行的清理，用 `try-finally`；② 想统一兜底就在最外层 Advisor 里 catch；③ 流式下异常是 `onError` 信号，用 `doOnError` 处理。

**Q5：多个 Advisor 都要改 prompt，会冲突吗？**
A：不会"冲突"，但会**叠加**，而且顺序影响结果。比如两个 Advisor 都调 `augmentSystemMessage`，最终 system message 是两次追加的结果（顺序由 order 决定）。危险的是"一个覆盖、一个追加"——如果某个 Advisor 直接 `new Prompt(...)` 重建，前面 Advisor 的修改就丢了。**规范：只做追加（augment），不重建 Prompt**，除非你明确知道自己在覆盖什么。

---

## 九、总结

- Advisor = `ChatClient` 的环绕拦截器，是 LLM 应用所有横切关注点的落点。
- **order 越小越外层**；`before` 改输入，`after` 改输出。
- 顺序判断的唯一原则：**谁的输出是谁的输入**。memory 在 RAG 外层、护栏在最外层、计量靠内层。
- 同一种 Advisor 只能注册一次，重复注册会让历史消息翻倍。
- 流式场景 `after` 每 chunk 调一次，只做观察和增量过滤，别做阻塞 IO 和整段改写。
- `context()` 是 Advisor 与业务之间的参数通道，业务只传 `tenantId`，其余交给 Advisor。
- 埋点时**别把 prompt 原文打进 span**，那是合规雷区。

Advisor 这个机制看着简单，但它决定了一件事：**你的 AI 应用逻辑是散落在 100 个 service 方法里，还是收敛在一条可测试、可观测、可灰度的链上。** 后者才是能上生产的样子。
