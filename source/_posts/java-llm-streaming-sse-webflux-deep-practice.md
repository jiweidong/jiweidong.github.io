---
title: 【Java AI】大模型流式输出深度实战：SSE、WebFlux 与 Spring AI Streaming 全解析
date: 2026-10-13 08:00:00
tags:
  - Java
  - AI
  - SSE
  - WebFlux
  - Spring AI
  - 流式输出
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】大模型流式输出深度实战：SSE、WebFlux 与 Spring AI Streaming 全解析

## 前言

ChatGPT 之后，「打字机效果」成了大模型应用的标配。从体验上讲，用户等 10 秒看到一个完整答案，和 300ms 就看到第一个字、10 秒逐字吐完，感受天差地别 —— **首 Token 延迟（TTFT）比总耗时更影响体感**。

但流式输出并不是「加个 `stream: true`」那么简单。Java 后端落地时会撞上一连串工程问题：

- 用 `SseEmitter` 还是 WebFlux 的 `Flux<ServerSentEvent>`？虚拟线程出来后选型变了吗？
- Nginx / 网关一开代理，怎么「流」着流着就变成一次性返回了？
- 大模型连接超时、前端断线、用户点「停止生成」，服务端怎么感知并释放资源？
- 流式场景下怎么做 Token 统计、计费、审计、限流？
- SSE 断线能不能续传？`Last-Event-ID` 到底怎么用？

这篇文章一次讲清。

---

## 二、SSE 协议：为什么大模型选它而不是 WebSocket

**SSE（Server-Sent Events）** 是基于 HTTP 的单向服务器推送协议，本质是一个**永不结束、持续 flush 的 `text/event-stream` 响应**。

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

event: message
id: 1
data: {"delta":"你"}

data: {"delta":"好"}

data: {"delta":"，世界"}

```

协议要点：

| 字段 | 含义 |
|---|---|
| `data:` | 数据内容，多行会拼接 |
| `event:` | 事件类型，前端按类型分发 |
| `id:` | 消息 ID，断线重连时通过 `Last-Event-ID` 请求头回传 |
| `retry:` | 客户端重连间隔（ms） |
| `:comment` | 注释行，可做**心跳保活** |
| 空行 | 一个事件的结束标记 |

### SSE vs WebSocket vs 轮询

| 维度 | SSE | WebSocket | 长轮询 |
|---|---|---|---|
| 方向 | 单向（服务端→客户端） | 双向 | 单向 |
| 协议 | HTTP/1.1、HTTP/2 | 独立协议（HTTP 升级） | HTTP |
| 自动重连 | 浏览器原生支持 | 需自己实现 | 需自己实现 |
| 代理/网关兼容 | **好**（就是 HTTP） | 差（需 Upgrade 支持） | 好 |
| 二进制 | 不支持（文本） | 支持 | 支持 |
| 适用 | **LLM 流式、通知、进度** | 聊天室、协同编辑 | 兼容性兜底 |

**大模型对话选 SSE 的根本原因**：请求-响应模型天然是单向的（用户发一次，模型流式回一次），SSE 的自动重连、HTTP 兼容性、实现简单性全面胜出。**只有「用户边生成边打断/多轮实时纠偏」这类双向交互才需要 WebSocket。**

---

## 三、Java 侧两条路线：SseEmitter vs WebFlux

### 3.1 路线一：Spring MVC + SseEmitter（阻塞式，配虚拟线程）

```java
@RestController
public class ChatController {

    private final ChatClient chatClient; // Spring AI

    public ChatController(ChatClient.Builder builder) {
        this.chatClient = builder.build();
    }

    @GetMapping(value = "/api/chat/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter stream(@RequestParam String q) {
        SseEmitter emitter = new SseEmitter(180_000L); // 超时 3 分钟

        chatClient.prompt().user(q)
                .stream().content()
                .subscribe(
                        chunk -> {
                            try {
                                emitter.send(SseEmitter.event().data(chunk));
                            } catch (IOException e) {
                                throw new IllegalStateException("客户端已断开", e);
                            }
                        },
                        emitter::completeWithError,
                        emitter::complete
                );

        emitter.onTimeout(() -> log.warn("SSE 超时: {}", q));
        emitter.onError(e -> log.warn("SSE 错误", e));
        return emitter;
    }
}
```

**SseEmitter 的本质缺陷**：每个连接占用一个 Servlet 线程，等待期间线程是**阻塞**的。5000 个并发流式会话 = 5000 个线程。在 Java 21 之前，这基本等于事故。

**Java 21 虚拟线程改变了这个结论**：

```yaml
spring:
  threads:
    virtual:
      enabled: true   # Spring Boot 3.2+：Tomcat 请求用虚拟线程处理
```

虚拟线程让「阻塞式写法 + 高并发」成为可能，每个连接成本降到几 KB，`SseEmitter` 重新变得可用。**但注意：虚拟线程解决的是「线程成本」，不解决「连接不释放」—— 客户端断开时仍必须显式 `complete()`，否则虚拟线程会 park 住直到超时。**

### 3.2 路线二：WebFlux + Flux（响应式，天然流）

```java
@RestController
public class ReactiveChatController {

    private final ChatClient chatClient;

    @GetMapping(value = "/api/chat/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<ServerSentEvent<String>> stream(@RequestParam String q) {

        Flux<String> content = chatClient.prompt().user(q).stream().content();

        return content
                .index()  // 生成序号作为 event id
                .map(tuple -> ServerSentEvent.<String>builder()
                        .id(String.valueOf(tuple.getT1()))
                        .event("delta")
                        .data(tuple.getT2())
                        .build())
                .concatWith(Flux.just(ServerSentEvent.<String>builder()
                        .event("done").data("[DONE]").build()))
                .doOnCancel(() -> log.info("客户端取消生成: {}", q))
                .doFinally(sig -> log.info("流结束: {}", sig))
                .onErrorResume(e -> Flux.just(ServerSentEvent.<String>builder()
                        .event("error").data("生成失败，请重试").build()));
    }
}
```

WebFlux 的优势：

- **非阻塞、事件驱动**，一个线程处理成千上万连接（Netty EventLoop）；
- **背压**：`Flux` 天然支持，下游消费慢时会向上游施加压力（虽然 SSE 场景下背压意义有限）；
- **组合能力强**：`merge`/`zip`/`timeout`/`retryWhen` 都可以直接用在流上；
- **取消语义清晰**：`doOnCancel` 能在客户端断开时立刻感知，释放上游模型连接。

### 3.3 选型结论

| 场景 | 推荐 | 理由 |
|---|---|---|
| 已有 Spring MVC 单体 | MVC + SseEmitter + 虚拟线程 | 改造成本最低，团队熟悉 |
| 高并发 AI 网关 / 聚合多模型流 | WebFlux + Flux | 连接密度高，取消/组合语义强 |
| 需要边生成边调工具（Agent） | WebFlux | 流式编排能力更强 |
| 团队不熟悉响应式 | MVC + 虚拟线程 | 避免「用错响应式反而更慢」 |

**务实建议**：不要为了流式而全面改造 WebFlux。**Spring AI 在两种栈下都能 `stream()`**，先把流式能力做出来，再根据压测决定。

---

## 四、Spring AI 的 Streaming 抽象

Spring AI 把流式统一成了 `StreamResponseSpec`：

```java
// 最简：只拿文本
Flux<String> flux = chatClient.prompt()
        .user("用 Java 解释零拷贝")
        .stream()
        .content();

// 拿完整 ChatResponse（含元数据：模型、Token 用量）
Flux<ChatResponse> responses = chatClient.prompt()
        .user("...")
        .stream()
        .chatResponse();

responses.subscribe(r -> {
    String text = r.getResult().getOutput().getText();
    // 流式过程中，usage 通常只有最后一个 chunk 有值
    if (r.getMetadata().getUsage() != null) {
        log.info("token usage: {}", r.getMetadata().getUsage());
    }
});
```

**关键工程细节：**

1. **Usage 只在末尾可用的模型**。OpenAI 兼容接口需要在请求里加 `stream_options: {"include_usage": true}` 才会在最后一块返回 usage。**流式计费必须自己兜底估算**（用 tiktoken 类库按字符近似），否则对账对不上。
2. **`[DONE]` 标记**。OpenAI 协议用 `data: [DONE]` 结束；Spring AI 会把它转成 `onComplete`。自己解析 SSE 时别把 `[DONE]` 当正文。
3. **工具调用 + 流式**：Function Calling 的流式返回里，`tool_calls` 是**分片增量**的（name 先来，arguments 逐段来），必须自己拼装后再执行。这是 Agent 流式化最容易踩的坑。
4. **多模态/推理模型的 `reasoning_content`**：DeepSeek-R1 类模型会额外返回思考过程，需要单独字段透传给前端，别和正文混在一起。

### 4.1 多模型统一网关的流式适配

企业里往往要同时接 OpenAI、Claude、通义、DeepSeek。差异点：

| 差异 | OpenAI 兼容 | Anthropic | 说明 |
|---|---|---|---|
| 结束标记 | `data: [DONE]` | `event: message_stop` | 需统一转义 |
| 增量字段 | `choices[0].delta.content` | `content_block_delta.delta.text` | 需统一为 `delta` |
| Usage 位置 | 末块（需显式开启） | `message_delta.usage` | 需归一化 |
| 错误事件 | `data: {"error":...}` | `event: error` | 需统一错误码 |

**最佳实践：在网关层把各家差异归一化成统一的 `event: delta / done / error` 三段式**，前端只对接一套协议。

---

## 五、生产踩坑清单（血泪版）

1. **Nginx 缓冲导致「假流式」**。默认 `proxy_buffering on` 会把响应攒够再发。必须配置：

```nginx
location /api/chat/stream {
    proxy_pass http://backend;
    proxy_buffering off;
    proxy_cache off;
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding off;   # 某些版本需要关掉
    proxy_read_timeout 300s;          # 流式必须放大读超时
    gzip off;                         # gzip 会缓冲，务必关闭
}
```

2. **网关/负载均衡的 idle timeout**。SLB、API Gateway 默认 60s 空闲断连。要么配心跳（每 15s 发一个 `:ping` 注释行），要么调大超时。
3. **响应头缺 `X-Accel-Buffering: no`**。即使 Nginx 配了，某些云原生网关仍会缓冲；加这个响应头可让 Nginx 单请求级别关闭缓冲。
4. **HTTP/2 与 `Content-Length` 冲突**。SSE 不要设置 `Content-Length`，否则代理可能等齐再发。
5. **客户端断开的资源泄漏**。`SseEmitter` 必须监听 `onCompletion`/`onError`/`onTimeout`，并在回调里取消上游模型请求（WebFlux 用 `doOnCancel`）。否则用户刷新页面 = 服务端仍在烧 Token。
6. **超时设置不一致**。模型 SDK 的超时、Servlet 的 async timeout、Nginx 的 read timeout、网关的 idle timeout，四层必须**从内到外递增**，否则内层还没结束，外层已经断开。
7. **日志把整段响应打出来**。流式高频日志会拖慢甚至 OOM。应改为「只记首字延迟 + 总耗时 + Token 数」。
8. **`SseEmitter` 在过滤器中提前 commit**。如果全局 Filter 里读了 `response.getOutputStream()` 或设置了 `Content-Length`，SSE 会直接失效。
9. **CORS 与 EventSource 的限制**。原生 `EventSource` 不支持自定义 Header（无法带 `Authorization`）。生产方案：用 `fetch + ReadableStream` 手动解析 SSE，或用 Cookie + 同源网关。

---

## 六、断线续传：`Last-Event-ID` 实战

SSE 原生支持断线重连，但**续传要靠服务端配合**：

```java
@GetMapping(value = "/api/chat/stream/{sessionId}", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<ServerSentEvent<String>> resume(
        @PathVariable String sessionId,
        @RequestHeader(value = "Last-Event-ID", required = false) Integer lastEventId) {

    int from = lastEventId == null ? 0 : lastEventId + 1;

    return tokenBuffer.slice(sessionId, from)   // 从缓冲区取未消费的 token
            .map(new TokenChunkMapper());       // 重新包装成 SSE 事件
}
```

要点：

- **服务端必须缓存已发送的 token 序列**（内存 ring buffer + TTL，或 Redis），否则续传无从谈起。
- 断线超过缓存窗口就只能**重放全量**（重新生成）或返回明确错误，不能假装续传。
- `id:` 建议用**单调递增序号**而非时间戳/UUID，便于定位续传位点。

---

## 七、面试高频追问

**Q1：SSE 用 HTTP/1.1 还是 HTTP/2？**
浏览器对同域名 HTTP/1.1 有 6 连接限制，多个 SSE 会互相阻塞，因此生产**优先 HTTP/2**（多路复用）。HTTP/2 下 SSE 依然工作，但要确保代理不缓冲。

**Q2：虚拟线程出来后，还需要 WebFlux 吗？**
对于「每请求一个阻塞调用」的简单流式场景，虚拟线程 + MVC 完全够用，代码更易维护。WebFlux 的价值在于**复杂流编排**（多模型竞速、Agent 循环、背压）和高连接密度下的更低开销。

**Q3：流式响应怎么统计 Token 和费用？**
两层：模型返回的数字（准确但可能缺）+ 本地估算（tiktoken/jtokkit，兜底）。流式场景建议**边流边累加**，会话结束落库，并对「客户端提前断开」的会话按已生成量计费。

**Q4：如何实现「停止生成」？**
前端 `AbortController.abort()`（fetch 方案）或关闭 EventSource → 服务端收到 `doOnCancel`/`onError` → 取消上游模型调用（`Disposable.dispose()` 或 Reactor 的 cancel 传播）→ 记录已生成内容。

---

## 八、总结

| 关注点 | 落地要点 |
|---|---|
| 协议 | SSE（`text/event-stream`），HTTP/2 优先，心跳保活 |
| Java 实现 | MVC + 虚拟线程（简单）/ WebFlux + Flux（复杂编排） |
| Spring AI | `.stream().content()` / `.chatResponse()`，注意 usage 与 `[DONE]` |
| 代理 | 关缓冲、关 gzip、放大 read timeout、加 `X-Accel-Buffering: no` |
| 可靠性 | 监听取消、四层超时递增、`Last-Event-ID` 续传 |
| 治理 | Token 累加计费、首字延迟监控、统一错误事件 |

流式输出是 AI 应用「体感」的第一道门槛，也是最容易被低估的工程战场。对 Java 后端来说，它把**并发模型、网络协议、代理配置、资源生命周期**这四块老本行一次性拉满 —— 这正是 Java 工程师转型 AI 应用开发时最该抓住的差异化优势。
