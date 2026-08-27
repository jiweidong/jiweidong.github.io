---
title: 【Java 实战】SSE 服务端推送深度实战：从 EventSource 原理到 Spring 集成与 WebSocket 对比
date: 2026-08-27 08:00:00
tags:
  - Java
  - SSE
  - Spring Boot
  - Web
  - 实时通信
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Java 实战】SSE 服务端推送深度实战：从 EventSource 原理到 Spring 集成与 WebSocket 对比

## 面试官：实现一个"服务器主动推送"的功能，你选 WebSocket 还是 SSE？

AI 对话流式输出、股票行情、订单状态通知、任务进度条……这些场景都需要**服务端主动推送**。很多人第一反应是 WebSocket，但 WebSocket 是全双工协议，复杂度高；如果只是"服务端单向推送"，**SSE（Server-Sent Events，服务器发送事件）** 往往更简单、更合适。

今天彻底讲透 SSE：HTTP 协议层面的原理、浏览器 EventSource API、Spring Boot 集成（含流式 AI 响应场景）、以及和 WebSocket 的选型对比。

## 一、SSE 是什么

SSE 是 HTML5 标准的一部分，允许**服务器通过普通的 HTTP 连接向浏览器持续推送数据**。它的本质是：

> 一个**长连接**的 HTTP 响应，服务器不断往响应体里写文本数据，客户端通过 `EventSource` API 接收。

关键特性：
- **单向**：服务器 → 客户端（客户端要发数据走普通请求）
- **基于 HTTP**：无需额外协议，天然支持 HTTP/2、代理、鉴权
- **自动重连**：连接断开浏览器自动重连（EventSource 内置）
- **文本协议**：UTF-8 文本，格式简单

## 二、协议原理：SSE 的消息格式

SSE 的响应 Content-Type 是 `text/event-stream`，消息体是简单的文本行协议：

```http
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

data: 第一条消息内容

data: 第二条消息内容
data: 多行 data 会拼接成一个消息

event: customEvent
data: 带自定义事件类型的消息

id: 100
data: 带 id 的消息（用于断线重连续传）

retry: 3000
（告诉客户端重连间隔 3 秒）
```

### 字段说明

| 字段 | 含义 |
|------|------|
| `data:` | 消息数据，可多行，多行拼接为一条消息 |
| `event:` | 自定义事件名，默认是 `message` |
| `id:` | 消息 ID，断线重连时通过 `Last-Event-ID` 头传给服务器 |
| `retry:` | 重连间隔（毫秒） |
| 空行 | 消息分隔符 |

### 心跳保活

SSE 连接可能被代理/负载均衡器空闲超时断开，服务器需要定时发送**注释行**（以 `:` 开头）或空数据保活：

```
: heartbeat comment（注释行，客户端忽略）
```

## 三、客户端：EventSource API

### 3.1 基本用法

```javascript
const es = new EventSource('/api/sse/news');

// 默认 message 事件
es.onmessage = (event) => {
  console.log('收到:', event.data);
};

// 自定义事件
es.addEventListener('customEvent', (event) => {
  console.log('自定义事件:', event.data);
});

// 错误处理（断开会自动重连，error 事件也会触发）
es.onerror = (err) => {
  console.log('连接异常，EventSource 会自动重连');
};

// 手动关闭（不再自动重连）
// es.close();
```

### 3.2 断线重连的细节

EventSource 断开后默认**自动重连**，重连时会带上 `Last-Event-ID` 请求头，服务器可以根据它补发错过的消息（配合 `id:` 字段）。

```javascript
// 服务器返回 id: 100，断线后重连请求头：
// Last-Event-ID: 100
// 服务器从 101 开始补发
```

## 四、Spring Boot 集成 SSE

### 4.1 方式一：SseEmitter（传统 Controller）

Spring MVC 4.2+ 提供了 `SseEmitter`，最简单：

```java
@RestController
@RequestMapping("/api/sse")
public class SseController {

    @GetMapping(value = "/news", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter streamNews() {
        // 超时时间设为 0 表示不超时（或设合理值，如 30 分钟）
        SseEmitter emitter = new SseEmitter(0L);

        // 业务线程推送数据（不能用请求线程，它会阻塞）
        executor.submit(() -> {
            try {
                for (int i = 0; i < 10; i++) {
                    emitter.send(SseEmitter.event()
                            .name("news")
                            .data(Map.of("index", i, "time", System.currentTimeMillis())));
                    Thread.sleep(1000);
                }
                emitter.complete();  // 正常结束
            } catch (Exception e) {
                emitter.completeWithError(e);
            }
        });

        // 客户端断开回调
        emitter.onCompletion(() -> log.info("连接关闭"));
        emitter.onTimeout(() -> emitter.complete());
        emitter.onError(e -> log.error("连接异常", e));
        return emitter;
    }
}
```

### 4.2 方式二：WebFlux Flux（响应式，推荐）

```java
@RestController
public class FluxSseController {

    @GetMapping(value = "/api/sse/flux", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<ServerSentEvent<String>> stream() {
        return Flux.interval(Duration.ofSeconds(1))
                .map(i -> ServerSentEvent.<String>builder()
                        .event("tick")
                        .id(String.valueOf(i))
                        .data("第 " + i + " 条消息")
                        .build())
                .take(10);
    }
}
```

### 4.3 实战场景：AI 流式输出（模拟 GPT 打字机效果）

```java
@RestController
public class AiChatController {

    @PostMapping(value = "/api/ai/chat", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter chat(@RequestBody ChatRequest request) {
        SseEmitter emitter = new SseEmitter(0L);
        aiService.streamResponse(request.getPrompt())
                .doOnNext(token -> safeSend(emitter, token))  // 每产生一个 token 推一次
                .doOnComplete(emitter::complete)
                .doOnError(emitter::completeWithError)
                .subscribe();
        return emitter;
    }

    private void safeSend(SseEmitter emitter, String token) {
        try {
            emitter.send(SseEmitter.event().name("token").data(token));
        } catch (IOException e) {
            emitter.completeWithError(e);  // 客户端断开时停止
        }
    }
}
```

前端拿到 token 逐字渲染，就是"打字机"效果。**这就是 ChatGPT 网页端流式输出的实现原理之一**（OpenAI API 本身也支持 SSE 格式）。

### 4.4 注意事项

1. **必须异步推送**：`SseEmitter` 的 send 不能放在请求线程里 sleep，会占满 Tomcat 线程池（每个长连接占一个线程）。生产上用 WebFlux（Netty）或专门的推送线程池。
2. **代理超时配置**：Nginx 默认 `proxy_read_timeout 60s`，长连接会被断开，要调大并配 `proxy_buffering off`：

```nginx
location /api/sse/ {
    proxy_pass http://backend;
    proxy_buffering off;                # 关闭缓冲，数据实时转发
    proxy_read_timeout 3600s;           # 长连接超时
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding off;
}
```

3. **鉴权**：SSE 是普通 HTTP 请求，可以正常走 Cookie/Token 鉴权，`EventSource` 默认不带自定义 Header（浏览器限制），Token 可以放 Cookie 或 URL 参数（注意安全）或用 `EventSource` 的 polyfill 支持 Header。
4. **连接数监控**：每个 SSE 连接占一个连接，推送量大时要关注服务器连接数（`netstat` 监控 ESTABLISHED 数量）。

## 五、SSE vs WebSocket：怎么选

| 对比项 | SSE | WebSocket |
|--------|-----|-----------|
| 方向 | 服务器 → 客户端（单向） | 全双工（双向） |
| 协议 | 基于 HTTP/HTTPS | 独立 ws/wss 协议 |
| 复杂度 | 低（纯文本协议） | 高（帧、握手、心跳、二进制） |
| 自动重连 | ✅ 内置 | ❌ 需自己实现 |
| 消息 ID 续传 | ✅ 内置（Last-Event-ID） | ❌ 需自己实现 |
| 二进制数据 | ❌ 只支持文本（可 Base64） | ✅ 原生支持 |
| 浏览器兼容 | 现代浏览器均支持 | 现代浏览器均支持 |
| 穿透性 | ✅ 走 80/443，代理友好 | ❌ 需要代理支持 Upgrade |
| 服务端开销 | 低（每个连接一个线程/协程） | 较高 |
| 典型场景 | 行情、通知、AI 流式、进度条 | 聊天、游戏、协同编辑 |

### 选型建议

- **服务端单向推送、数据是文本** → 无脑选 SSE：简单、可靠、省心
- **需要双向实时交互**（聊天、游戏、白板）→ WebSocket
- **AI 对话流式输出** → SSE（OpenAI/Claude 等 API 都是 SSE 格式）
- **需要二进制流**（音视频帧）→ WebSocket 或 WebRTC

## 六、面试高频追问

**Q1：SSE 和轮询、长轮询有什么区别？**
A：普通轮询是客户端定时发请求，浪费带宽、延迟高；长轮询是服务器 hold 住请求直到有数据再返回，但每次都要重新建立连接；SSE 是一个持续的长连接，服务器随时可推，浏览器自动重连，是三者中最高效的。

**Q2：SSE 连接断开会自动重连吗？漏掉的消息怎么办？**
A：EventSource 自动重连；配合消息 `id` 字段，重连时发送 `Last-Event-ID`，服务器可以补发遗漏消息，实现"断点续传"。

**Q3：为什么 SSE 能跨过代理而 WebSocket 不行？**
A：SSE 就是普通 HTTP GET 请求的响应，代理服务器天然认识 HTTP；WebSocket 需要 101 协议升级，老代理不支持或配置不当会断开。这就是 SSE 穿透性好的原因。

**Q4：SSE 在高并发下有什么瓶颈？**
A：长连接占用服务器资源（连接数、线程/协程），单机连接数有上限；推送量大时网络带宽是瓶颈。解法：WebFlux 非阻塞模型、横向扩容 + 负载均衡（注意 Nginx 配置）、Redis Pub/Sub 或 MQ 做跨节点广播。

**Q5：多实例部署时怎么把消息推送到正确的连接？**
A：连接绑定在某台实例上，需要**路由或广播**：用 Redis Pub/Sub、MQ（Kafka/RabbitMQ）把消息广播到所有实例，每台实例只推送自己持有的连接；或用 Redis 存储"连接 → 实例"映射做精准路由。

## 总结

SSE 是常被低估的实时通信方案：它用最朴素的 HTTP 长连接 + 文本协议，实现了自动重连、断点续传、代理友好的服务端推送。Spring 生态里 `SseEmitter` 和 WebFlux `Flux<ServerSentEvent>` 都有成熟支持，AI 流式输出更是让 SSE 重新成为主流。面试时能讲清协议格式、自动重连机制、与 WebSocket 的选型对比，这道题就稳了。
