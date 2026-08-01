---
title: Spring AI 实战：Java 大模型应用开发从入门到生产
date: 2026-08-01 08:00:00
tags:
  - Spring AI
  - 大模型
  - AI
  - 实战
categories:
  - Java
  - Spring 全家桶
author: 东哥
---

2025 年之后，大模型应用开发早已不是 Python 的专利。Spring AI 作为 Spring 生态官方的 AI 应用框架，让 Java 开发者可以用熟悉的依赖注入、模板化和可测试的方式接入 LLM、向量数据库和 RAG 全链路。这篇文章从零开始，带你掌握 Spring AI 的核心概念、常用 API 与生产级实践。

<!-- more -->

## 一、Spring AI 是什么？

Spring AI 是 Spring 官方推出的 AI 应用抽象层，对标 Python 生态的 LangChain。它的定位非常明确：**把与大模型交互的复杂性封装成 Spring 风格的组件**，让开发者像写普通 Service 一样写 AI 功能。

核心设计目标：

- **可移植性**：统一 ChatClient / ChatModel 接口，切换 OpenAI、通义千问、DeepSeek、Ollama 本地模型只改配置
- **可测试性**：支持 Mock 模型、录制回放，方便单元测试
- **可观测性**：与 Micrometer、OpenTelemetry 集成，天然接入 Spring Boot 3 的观测体系
- **生态整合**：向量库（Redis、Milvus、PgVector）、RAG、Function Calling 开箱即用

### 与其他框架的对比

| 维度 | Spring AI | LangChain4j | 自研 HTTP 调用 |
|------|-----------|-------------|----------------|
| Spring 生态集成 | ✅ 原生 | ✅ 良好 | ❌ 需自己写 |
| 模型支持 | 20+ 家 | 30+ 家 | 自己对接 |
| RAG / 向量库 | ✅ 内置抽象 | ✅ 丰富 | ❌ 手写 |
| 结构化输出 | ✅ | ✅ | ❌ |
| 学习成本 | 中 | 中高 | 低但维护成本高 |
| 官方维护 | Spring 团队 | 社区 | 自己 |

## 二、快速上手：五分钟跑通第一个对话

### 1. 引入依赖

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-model-openai</artifactId>
</dependency>
```

> 注意：Spring AI 需要 `Spring Boot 3.4+`，且依赖版本通过 BOM 管理，建议使用 `spring-ai-bom` 统一版本，避免依赖冲突。

### 2. 配置

```yaml
spring:
  ai:
    model:
      chat:
        openai:
          base-url: https://api.deepseek.com/v1   # 兼容 OpenAI 协议即可
          api-key: ${LLM_API_KEY}
          options:
            model: deepseek-chat
            temperature: 0.7
            max-tokens: 2048
```

只要对方提供 OpenAI 兼容协议（DeepSeek、智谱、通义、本地 vLLM 都支持），改个 base-url 就能切换。

### 3. 编写业务代码

```java
@Service
@RequiredArgsConstructor
public class ChatService {

    private final ChatClient.Builder chatClientBuilder;

    public String ask(String question) {
        ChatClient chatClient = chatClientBuilder.build();
        return chatClient.prompt()
                .system("你是一位资深的 Java 技术专家，回答要简洁、准确、有代码示例。")
                .user(question)
                .call()
                .content();
    }
}
```

`ChatClient` 是 Spring AI 的"门面"，类似 `RestClient`，支持流式、结构化输出、多轮对话、工具调用等全部能力，是整个框架使用频率最高的类。

## 三、核心概念逐一拆解

### 1. ChatClient 的三种调用方式

| 方式 | 方法 | 适用场景 |
|------|------|----------|
| 同步调用 | `.call()` | 大多数业务场景 |
| 流式调用 | `.stream()` | 打字机效果、长文本生成 |
| 响应式 | `.flux()` | WebFlux 全链路响应式 |

流式输出的典型写法：

```java
public Flux<String> streamAsk(String question) {
    return chatClient.prompt()
            .user(question)
            .stream()
            .content();   // Flux<String>，前端可用 SSE 推送
}
```

### 2. 结构化输出：让 JSON 不再靠"提示词碰运气"

模型返回 JSON 经常多一个反引号或少一个字段，Spring AI 提供了类型安全的结构化输出：

```java
public record BookReview(String bookName, int score, String summary) {}

BookReview review = chatClient.prompt()
        .user("请评价《三体》")
        .call()
        .entity(BookReview.class);
```

底层原理是 `BeanOutputConverter`：它先让模型按指定的 JSON Schema 输出，再用 Jackson 反序列化，配合 `format=json` 约束，实测成功率远高于裸提示词。

### 3. Function Calling：让模型能"调用你的代码"

这是企业落地的关键能力——模型本身不联网、不算账，但你可以把工具注册给它：

```java
@Bean
public ToolCallback weatherTool() {
    return ToolCallbacks.from("get_weather",
            "查询指定城市的天气", 
            new Function<WeatherRequest, WeatherResponse>() {
                @Override
                public WeatherResponse apply(WeatherRequest req) {
                    return weatherService.query(req.city());
                }
            });
}

// 使用时
String answer = chatClient.prompt()
        .user("北京明天适合跑步吗？")
        .tools(weatherTool())
        .call()
        .content();
```

模型会在需要时"请求"调用该工具，框架自动把结果回填给模型生成最终答案。注意 Tool 参数建议用 `@JsonClassDescription` 描述清楚，描述越详细，模型调用准确率越高。

### 4. RAG：让模型回答"你私有的知识"

RAG（检索增强生成）四步：**切分 → 向量化 → 存储 → 检索生成**。

```java
@Service
@RequiredArgsConstructor
public class RagService {

    private final VectorStore vectorStore;
    private final ChatClient chatClient;

    public void ingest(String text) {
        // 1. 切分文档
        TokenTextSplitter splitter = new TokenTextSplitter();
        List<Document> docs = splitter.apply(List.of(new Document(text)));
        // 2. 向量化并存入 Redis（需要 redis-spring-boot-starter）
        vectorStore.add(docs);
    }

    public String ask(String question) {
        return chatClient.prompt()
                .advisors(a -> a.param("vector_store", vectorStore)
                        .param("top_k", 5)
                        .param("similarity_threshold", 0.5))
                .user(question)
                .call()
                .content();
    }
}
```

`QuestionAnswerAdvisor` 会自动完成"检索 → 拼装上下文 → 生成"的流程。生产环境注意：**文档切分大小直接决定回答质量**，中文场景建议按 300~500 字切分并保留 10%~15% 重叠，避免语义被截断。

## 四、生产环境避坑指南

1. **超时与重试**：LLM 接口延迟波动极大，必须配置超时。Spring AI 底层走 RestClient，可全局配置连接/读取超时，并配合 Spring Retry 做指数退避重试（仅对网络错误重试，业务错误别重试）。

2. **Token 成本控制**：系统提示词尽量精简；长对话用 `MessageWindowChatMemory` 限制上下文窗口大小，防止 token 费用失控：

```java
chatClient.mutate()
    .defaultAdvisors(MessageWindowChatMemory.builder()
        .maxMessages(10).build())
    .build();
```

3. **敏感信息防泄漏**：AI 功能必须做输入输出审计，日志里不要打全量 Prompt；涉及用户隐私的字段先脱敏再送模型。

4. **降级方案**：模型不可用时降级到规则引擎/固定话术，用 Resilience4j 包裹 AI 调用，别让 AI 故障拖垮主链路。

5. **并发与限流**：模型厂商有 RPM/TPM 配额，用信号量或限流器控制并发，避免 429 风暴。

## 五、面试官可能追问

**Q1：Spring AI 和直接用 HTTP 调 OpenAI 有什么区别？**
答：核心是抽象与生态。Spring AI 把模型切换、结构化输出、RAG、工具调用封装成统一模型，且与 Spring 的配置体系、可观测性、测试体系深度集成。直接 HTTP 调用在简单场景更快，但多模型、多场景下维护成本高。

**Q2：Function Calling 的原理是什么？**
答：模型本身不执行代码。框架先把工具的描述（名称、参数 Schema）随请求发给模型，模型判断需要时返回 tool_calls 指令，框架执行对应 Java 方法并把结果作为新消息回传，模型基于结果生成最终回复。本质是多轮对话中注入工具结果。

**Q3：RAG 和微调怎么选？**
答：RAG 适合知识频繁更新、需要可溯源（引用出处）的场景，成本低、无训练风险；微调适合改变模型行为风格、提升特定领域格式能力的场景，但成本高、更新慢。生产上通常先用 RAG，仍不满足再考虑微调。

## 总结

Spring AI 让 Java 开发者能以极低的成本进入大模型应用开发。本文从 ChatClient、结构化输出、Function Calling、RAG 到生产避坑，覆盖了一条完整的落地链路。记住核心心法：**AI 能力是组件，业务稳定是底线**——所有 AI 调用都要有超时、重试、降级和审计。
