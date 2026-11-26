---
title: 【Nginx 实战】proxy_buffering 深度实战：响应缓冲、临时文件与流式接口的生死线
date: 2026-11-26 08:00:00
tags:
  - Nginx
  - 中间件
  - SSE
  - 性能优化
  - Java
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】proxy_buffering 深度实战

## 前言

`proxy_buffering` 是 Nginx 里最容易被忽略、又最容易在半夜炸掉的指令之一。

它默认是 `on`。对普通 JSON 接口，这是好事：Nginx 先把上游响应收进内存缓冲，再慢慢发给客户端，上游连接可以尽快释放。但对下面这些场景，它就是灾难：

- SSE / 流式对话：前端一个字都不出来，等模型全部生成完才一次性刷屏；
- 大文件下载：Nginx 把响应当成缓冲对象，磁盘 `proxy_temp` 目录被写满；
- 慢客户端：一个 2G 的手机用户挂着下载，占住上游连接和缓冲，拖垮整个 upstream；
- 上游超时：明明上游 200ms 就返回了，客户端却等了 30 秒。

这些现象背后是同一套缓冲链路。本文把 `proxy_buffering` 的完整路径、参数计算、关闭时机、排障方法讲清楚，最后给出 Java 侧的配合方式。

> 分工说明：站内已有《Nginx proxy_cache 缓存实战》《Nginx location/rewrite》《Nginx stream 四层代理》等文章。本篇只讲**响应缓冲（buffering）**，不讲缓存（caching），两者是不同机制。

---

## 一、响应从上游到客户端，经过了几道手

一个请求进来，Nginx 作为反向代理，响应路径大致是：

```
upstream socket
   │  recv()
   ▼
proxy_buffer_size        ← 先读响应头（header）
   │
   ▼
proxy_buffers            ← 响应体进入内存缓冲（若干块）
   │  缓冲写满
   ▼
proxy_busy_buffers_size  ← 正在往客户端发的部分
   │  还不够
   ▼
proxy_temp_file          ← 落磁盘临时文件
   │
   ▼
client socket            ← 按客户端消费速度发送
```

关键点：**Nginx 会尽可能快地从上游读完响应**，然后把「发给客户端」这件事解耦。这样上游连接能快速归还，不被慢客户端拖住。这就是 buffering 的价值。

代价是：响应的实时性没了。对 SSE 这种「服务端持续产出、客户端持续消费」的协议，缓冲直接破坏了语义。

### 1.1 核心指令表

| 指令 | 默认值 | 作用 |
|---|---|---|
| `proxy_buffering` | `on` | 总开关 |
| `proxy_buffer_size` | 4k/8k | 存放响应头的缓冲区大小，也是 buffer 关闭时唯一使用的缓冲 |
| `proxy_buffers` | 8 4k/8k | 响应体缓冲区的数量和单块大小 |
| `proxy_busy_buffers_size` | 2×buffer_size | 正在发送给客户端的缓冲上限 |
| `proxy_max_temp_file_size` | 1024m | 单个响应允许写多少临时文件，0 表示禁用 |
| `proxy_temp_file_write_size` | 2×buffer_size | 一次写临时文件的块大小 |
| `proxy_temp_path` | `proxy_temp` | 临时文件目录 |
| `proxy_ignore_client_abort` | `off` | 客户端断开后是否继续读上游 |

一个常见的误解是：`proxy_buffers 8 4k` 意味着「最多缓冲 32k」。实际上 `proxy_busy_buffers_size` 通常按 2 倍单块计算，而且缓冲写满后会转临时文件，总缓冲量受 `proxy_max_temp_file_size` 限制，不是 32k。

---

## 二、默认配置在什么情况下会出事

### 2.1 SSE：流式变成「一次性」

Java 侧用 `SseEmitter`：

```java
@GetMapping(value = "/chat/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public SseEmitter stream(@RequestParam String q) {
    SseEmitter emitter = new SseEmitter(0L);
    executor.execute(() -> {
        try {
            for (String token : llmClient.stream(q)) {
                emitter.send(SseEmitter.event().data(token));
            }
            emitter.complete();
        } catch (Exception e) {
            emitter.completeWithError(e);
        }
    });
    return emitter;
}
```

本地测试一切正常，上了 Nginx 之后前端只收到一个「大包」。原因就是 `proxy_buffering on`：Nginx 把每个 chunk 攒进缓冲，直到缓冲满或响应结束才发给客户端。8k 缓冲对短回答来说，基本等于「全部结束才发」。

解决方式有两种：

**方式一：在 Nginx 关掉缓冲**

```nginx
location /api/chat/stream {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    proxy_buffering off;
    proxy_cache off;
    gzip off;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    add_header X-Accel-Buffering no;
}
```

**方式二：由应用返回响应头**

```java
response.setHeader("X-Accel-Buffering", "no");
```

Nginx 识别这个响应头后，会对该响应关闭缓冲，不需要改 `location`。适合「同一个接口有时流式、有时普通」的场景。

### 2.2 大文件下载：临时文件打满磁盘

如果上游返回一个 5GB 的文件，而客户端很慢，Nginx 会把响应体写到 `proxy_temp_path`。默认上限是 1GB/响应，但并发 10 个就是 10GB。磁盘打满后，Nginx 会报：

```
write() to "/var/lib/nginx/proxy/..." failed (28: No space left on device)
```

对下载类接口，正确做法是：

```nginx
location /files/ {
    proxy_pass http://backend;
    proxy_buffering off;
    proxy_max_temp_file_size 0;
    proxy_read_timeout 600s;
}
```

`proxy_max_temp_file_size 0` 表示完全不落盘；配合 `proxy_buffering off`，响应边收边发，内存占用也小。

### 2.3 慢客户端拖住上游

即使开了 buffering，如果响应一直写不完，上游连接仍然可能被占用。典型场景是「上游是流式接口，但 Nginx 没关缓冲」：Nginx 一边读上游、一边写临时文件，客户端越慢，临时文件越大，上游连接保持越久。

监控上看：

- `$upstream_response_time` 很小（上游很快就返回了）；
- `$request_time` 很大（客户端侧耗了很久）；
- `proxy_temp` 目录持续增长。

这三个信号同时出现，基本可以确定是缓冲 + 慢客户端。

---

## 三、gzip 和 buffering 的叠加陷阱

`gzip on` 要求 Nginx 拿到完整响应（或足够大的块）才能压缩，所以 **gzip 天然需要缓冲**。如果你在 SSE 接口上只关了 `proxy_buffering`，却忘了 `gzip off`，可能会出现：

- 响应被 gzip 模块缓冲，流式仍然不实时；
- `Content-Encoding: gzip` 下，SSE 的 `data:` 分块被合并；
- 某些客户端不 flush，前端解析器卡住。

SSE 接口的标准配置应该是「三关」：

```nginx
proxy_buffering off;
gzip off;
proxy_cache off;
```

如果全局开了 gzip，可以用 `gzip_types` 排除 `text/event-stream`，或在 location 里单独 `gzip off`。

---

## 四、配置模板：三类接口分开治理

不要用一个 `location /` 打天下。按响应特征拆成三类：

### 4.1 普通 JSON API

```nginx
location /api/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    proxy_buffering on;
    proxy_buffer_size 8k;
    proxy_buffers 16 8k;
    proxy_busy_buffers_size 32k;
    proxy_max_temp_file_size 64m;

    proxy_connect_timeout 3s;
    proxy_send_timeout 30s;
    proxy_read_timeout 30s;
}
```

### 4.2 SSE / 流式

```nginx
location /api/chat/stream {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;

    proxy_buffering off;
    gzip off;
    proxy_cache off;
    proxy_max_temp_file_size 0;

    # 流式接口不要用 30s 的读超时
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    send_timeout 600s;

    add_header X-Accel-Buffering no;
}
```

### 4.3 大文件下载

```nginx
location /files/ {
    proxy_pass http://backend;
    proxy_buffering off;
    proxy_max_temp_file_size 0;
    proxy_read_timeout 1800s;
    send_timeout 1800s;

    # 让 Nginx 直接走 sendfile（如果上游也是文件）
    proxy_set_header Range $http_range;
    proxy_set_header If-Range $http_if_range;
}
```

---

## 五、排障：怎么证明是 buffering 的锅

### 5.1 看时间和大小

在 `log_format` 里加上这些变量：

```nginx
log_format upstream '$remote_addr "$request" status=$status '
                    'req_time=$request_time up_time=$upstream_response_time '
                    'bytes=$body_bytes_sent up_bytes=$upstream_response_length '
                    'buf=$upstream_bytes_received';
```

判读：

| 现象 | 含义 |
|---|---|
| `up_time` 小、`req_time` 大 | 上游快，客户端慢，可能被缓冲/慢客户端拖住 |
| `up_bytes` 远大于 `bytes` | 响应在 Nginx 侧积压 |
| `up_time` 大 | 上游本身慢，与 buffering 无关 |

### 5.2 看临时文件

```bash
lsof +D /var/lib/nginx/proxy 2>/dev/null | head
du -sh /var/lib/nginx/proxy
```

如果请求进行中能看到大量 `proxy` 临时文件，说明响应在落盘。

### 5.3 看 error.log

典型日志：

```
a client request body is buffered to a temporary file
```

注意这是 **request body**（客户端上传），对应 `client_body_buffer_size`，不是 `proxy_buffering`。响应侧一般不会主动打日志，只能靠临时文件和耗时判断。

### 5.4 用 curl 验证是否流式

```bash
curl -N -H "Accept: text/event-stream" https://api.example.com/api/chat/stream
```

`-N` 关闭 curl 自己的缓冲。如果本地直连后端是逐行输出，经过 Nginx 变成一次性输出，问题就在 Nginx。

---

## 六、Java 侧要配合的四件事

### 6.1 正确设置 Content-Type

SSE 必须是：

```java
produces = MediaType.TEXT_EVENT_STREAM_VALUE
```

如果写成 `application/json`，Nginx 和浏览器都可能按普通响应处理，缓冲行为更不可控。

### 6.2 及时 flush

Spring MVC 的 `SseEmitter.send()` 会 flush；但如果用 `ResponseBodyEmitter` 或原生 `OutputStream`，要显式 flush：

```java
response.setContentType("text/event-stream");
response.setCharacterEncoding("UTF-8");
response.setHeader("Cache-Control", "no-cache");
response.setHeader("X-Accel-Buffering", "no");

PrintWriter writer = response.getWriter();
for (String token : tokens) {
    writer.write("data: " + token + "\n\n");
    writer.flush();
}
```

### 6.3 不要用 gzip 压缩流式响应

如果 Java 侧用了 `CompressionFilter` 或 Spring Boot 的 `server.compression.enabled=true`，要排除 SSE：

```yaml
server:
  compression:
    enabled: true
    mime-types: application/json,text/html,text/css,application/javascript
    # 不要包含 text/event-stream
```

### 6.4 超时要大于业务最长耗时

流式对话可能持续几分钟。Java 侧：

```java
SseEmitter emitter = new SseEmitter(600_000L); // 10 分钟
```

Nginx 侧 `proxy_read_timeout` 要大于等于这个值，否则 Nginx 会先断开，前端收到「网络错误」。

---

## 七、几个容易搞混的指令

| 指令 | 管什么 | 常见误用 |
|---|---|---|
| `proxy_buffering` | 响应体是否缓冲 | 以为关了就不读上游 |
| `proxy_buffer_size` | 响应头缓冲 | 调很大以为能缓冲响应体 |
| `client_body_buffer_size` | 请求体缓冲 | 和响应缓冲混淆 |
| `proxy_cache` | 是否缓存响应 | 以为关了 buffering 就不缓存 |
| `proxy_request_buffering` | 请求体是否先收完再转发 | 大上传要关 |
| `sendfile` | 零拷贝发文件 | 对代理响应无效 |

特别是 `proxy_request_buffering`：上传大文件时，Nginx 默认会先把整个请求体收完再转发给上游，这会让上传看起来「卡住很久然后突然完成」。需要流式上传时要关：

```nginx
proxy_request_buffering off;
```

---

## 八、面试追问

**Q1：`proxy_buffering off` 后，Nginx 还读上游吗？**

读，但变成「边读边发」，不再积压。此时 `proxy_buffer_size` 仍然用于响应头，响应体基本不占大缓冲。

**Q2：为什么 SSE 要关 gzip？**

gzip 压缩需要攒数据才能出块，会破坏 SSE 的实时性；而且 `Content-Encoding: gzip` 下，浏览器的事件流解析器可能拿不到完整的 `data:` 边界。

**Q3：`proxy_buffering on` 一定比 off 快吗？**

对「上游快、客户端慢」的场景，on 更快，因为上游连接能尽快释放；对「上游持续产出」的流式场景，on 会破坏实时性；对「大文件」场景，on 可能写满磁盘。没有绝对优劣，要看响应形态。

**Q4：`X-Accel-Buffering: no` 和 `proxy_buffering off` 有什么区别？**

前者是应用级、按响应生效；后者是 location 级、对该 location 所有响应生效。多租户或混合接口用前者更灵活。

**Q5：临时文件目录应该放哪？**

放独立磁盘或 tmpfs（如果内存足够），不要和系统盘、日志盘共用。要监控目录大小和 inode，避免打满根分区。

---

## 九、总结

记住四句话：

1. `proxy_buffering` 默认开，普通 API 受益，流式接口受害；
2. SSE 要「三关」：`proxy_buffering off`、`gzip off`、`proxy_cache off`；
3. 大文件要 `proxy_max_temp_file_size 0`，否则临时文件能打满磁盘；
4. 排障看 `$request_time` 与 `$upstream_response_time` 的差值，再看临时文件。

缓冲本身不是问题，问题是「用默认配置应对所有响应形态」。把接口按 JSON、流式、下载三类拆开，这类事故基本可以绝迹。
