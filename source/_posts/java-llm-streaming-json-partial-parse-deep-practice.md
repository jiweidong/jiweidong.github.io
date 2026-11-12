---
title: 【Java AI】流式结构化输出与增量 JSON 解析深度实战：Jackson 增量解析、JSON Patch 与断点续传
date: 2026-11-12 08:25:00
tags:
  - Java
  - AI
  - SSE
  - Jackson
  - 流式输出
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】流式结构化输出与增量 JSON 解析深度实战：Jackson 增量解析、JSON Patch 与断点续传

## 前言

做 AI 应用一定会遇到这个矛盾：

- 产品要**结构化数据**（JSON），因为下游要入库、要渲染表格、要调工具；
- 用户要**流式体验**，因为等 8 秒才出结果的产品没人用。

于是你让模型输出 JSON，前端等完整 JSON 再解析——首屏 8 秒。你改成流式输出纯文本——结构化没了。很多团队就此妥协成"先流式展示，结束后再请求一次结构化"，成本翻倍还慢。

正确答案是：**JSON 本身就可以边生成边解析**。JSON 是自描述的前缀可解析格式，Jackson 的 `JsonParser` 从设计上就是流式的。本文讲清楚增量解析的三种方案、Java 实现、安全边界，以及生产上绕不开的 SSE 与断点续传问题。

---

## 一、先明确目标：什么叫"增量可用"

假设模型要输出一份订单摘要：

```json
{
  "orderNo": "SO202611120001",
  "amount": 1280.50,
  "items": [
    {"sku": "A-100", "qty": 2, "price": 640.25},
    {"sku": "B-200", "qty": 1, "price": 0.00}
  ],
  "risk": "LOW",
  "summary": "该订单金额较大，客户历史良好，建议正常放行。"
}
```

增量消费要能做到：

| 阶段 | 已生成字节 | 可以安全做什么 |
|---|---|---|
| `{"orderNo":"SO20` | 字段名都没闭合 | **什么都别做** |
| `{"orderNo":"SO202611120001",` | 一个完整键值 | 渲染订单号 |
| `...,"items":[{"sku":"A-100","qty":2}` | 数组元素完整 | 追加一行明细 |
| `...,"amount":128` | 数字可能还会继续 | **不能**当成最终金额 |
| 完整 `}` | 全部就绪 | 全量校验 + 落库 |

关键认知：**"字符串闭合"和"数字结束"是两个不同的事件**。JSON 里字符串以 `"` 结束是明确的；数字只有遇到 `,` `}` `]` 或 EOF 才知道结束。所以增量渲染时，数字字段必须**延迟一拍**。

---

## 二、三种方案对比

| 方案 | 原理 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| **A. 缓冲 + 全量重解析** | 每次追加后 `readTree(buffer)` | 实现最简单 | O(n²)，10KB 输出要解析上百次，CPU 浪费 | 原型、短输出 |
| **B. Jackson 增量 token 解析** | 阻塞 InputStream + `JsonParser` 逐 token | 线性复杂度、天然背压 | 需要处理"未闭合 token"的等待 | **推荐，通用** |
| **C. 服务端下发 JSON Patch** | 服务端维护文档，只推 `add/replace` 操作 | 网络最小、前端零解析 | 需要服务端跑完整状态机 | 大文档、协同编辑 |

方案 C 的本质是"把增量计算搬到服务端"。如果你的场景是"长文生成 + 结构化字段并存"，C 最省带宽；如果是"模型直接吐 JSON"，B 最直接。

下面重点讲 B。

---

## 三、方案 B 的核心：让 JsonParser 阻塞在 InputStream 上

Jackson 的 `JsonParser` 不需要完整输入。只要给它一个 `InputStream`，它在需要更多字节时会**阻塞读**，读到就继续吐 token。所以只要把 SSE 的每个 delta 塞进一个阻塞队列式的流，解析就自动是增量的：

```java
/**
 * 把"异步到达的字节块"伪装成阻塞 InputStream。
 * 关键：read() 在没有数据时阻塞，而不是返回 -1（否则 Jackson 认为流结束）。
 */
public class ChunkedInputStream extends InputStream {

    private final BlockingQueue<byte[]> queue = new LinkedBlockingQueue<>();
    private byte[] current;
    private int pos;
    private volatile boolean completed;
    private volatile RuntimeException error;

    public void feed(String text) {
        if (text != null && !text.isEmpty()) {
            queue.offer(text.getBytes(StandardCharsets.UTF_8));
        }
    }

    /** 上游结束（收到 finish / [DONE]） */
    public void complete() {
        completed = true;
        queue.offer(new byte[0]);   // 唤醒阻塞的 read
    }

    public void fail(RuntimeException e) {
        this.error = e;
        complete();
    }

    @Override
    public int read() throws IOException {
        byte[] one = new byte[1];
        int n = read(one, 0, 1);
        return n == -1 ? -1 : (one[0] & 0xFF);
    }

    @Override
    public int read(byte[] b, int off, int len) throws IOException {
        while (current == null || pos >= current.length) {
            if (error != null) throw new IOException("upstream failed", error);
            if (completed && queue.isEmpty()) return -1;
            try {
                current = queue.take();      // 阻塞等待下一块
                pos = 0;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted", e);
            }
        }
        int n = Math.min(len, current.length - pos);
        System.arraycopy(current, pos, b, off, n);
        pos += n;
        return n;
    }
}
```

⚠️ 两个致命细节：

1. **不能用 `available()` 判断结束**，也不能在没数据时返回 `-1`——Jackson 会立刻抛出"Unexpected end-of-input"。
2. **UTF-8 多字节字符会被 SSE 分片切断**。上面按 `String` 转 `byte[]` 是全字符安全的（因为上游已经是解码后的字符串）；但如果你在**字节层**做代理转发，必须用增量 UTF-8 解码器，否则中文会变成 `�`。

### 3.1 消费端：逐 token 构建事件

```java
public class JsonStreamReader {

    private final ObjectMapper mapper = new ObjectMapper();

    /** 逐层回调：路径 + 值 */
    public void consume(InputStream in, BiConsumer<String, Object> onValue) throws IOException {
        JsonFactory factory = mapper.getFactory();
        try (JsonParser p = factory.createParser(in)) {

            Deque<String> path = new ArrayDeque<>();
            Deque<Boolean> isArray = new ArrayDeque<>();

            while (true) {
                JsonToken t = p.nextToken();     // 这里会阻塞等待更多字节
                if (t == null) break;            // 真正的流结束

                switch (t) {
                    case START_OBJECT -> { }
                    case START_ARRAY -> { }
                    case FIELD_NAME -> path.addLast(p.currentName());
                    case END_OBJECT, END_ARRAY -> {
                        if (!path.isEmpty()) path.pollLast();
                    }
                    case VALUE_STRING -> emit(path, isArray, p.getText(), onValue);
                    case VALUE_NUMBER_INT, VALUE_NUMBER_FLOAT ->
                            // 注意：数字 token 只有在遇到分隔符后才完整
                            emit(path, isArray, p.getNumberValue(), onValue);
                    case VALUE_TRUE, VALUE_FALSE -> emit(path, isArray, p.getBooleanValue(), onValue);
                    default -> { }
                }
            }
        }
    }

    private void emit(Deque<String> path, Deque<Boolean> arr, Object v,
                      BiConsumer<String, Object> cb) {
        String key = arr.peek() != null && arr.peek() ? path.peekLast() + "[]" : String.join(".", path);
        cb.accept(key, v);
    }
}
```

这段代码的价值在于：**遇到未闭合的字符串时，`nextToken()` 会阻塞，而不是报错**。等下一个 delta 到达，解析自然继续。这就是"流式 + 结构化"能同时成立的底层原因。

### 3.2 但"数字"仍然是个坑

看这个序列：

```
delta1: {"amount": 12
delta2: 80.5,
```

`nextToken()` 在 delta1 之后**不会**返回 `VALUE_NUMBER_INT(12)`，它会一直等到遇到 `,` 才确认数字是 `1280.5`。这是 Jackson 的正确行为，也是我们要的——但意味着**数字字段天然延迟**。如果你的 UI 需要"金额滚动增长"的效果，必须自己实现"前缀数字估算"，并明确标注为"预估中"。

---

## 四、更省心的路线：让模型输出 NDJSON

如果你能控制协议，最稳的方案是**不要输出一个大 JSON**，而是输出"一行一个事件"：

```json
{"type":"field","path":"orderNo","value":"SO202611120001"}
{"type":"item","index":0,"sku":"A-100","qty":2,"price":640.25}
{"type":"item","index":1,"sku":"B-200","qty":1,"price":0.00}
{"type":"field","path":"summary","value":"该订单金额较大..."}
{"type":"done","finishReason":"stop","usage":{"prompt":812,"completion":233}}
```

好处：

- 每行都是**独立完整 JSON**，解析零状态，出错只丢一行；
- 天然支持"流式插入"语义（`type` 决定怎么消费），不需要 JSON Patch 的路径运算；
- 中断后重连只需要记住"最后消费到第几行"。

在 Spring AI 里可以这样约束（Prompt 层）：

```
你必须输出 NDJSON：每行一个 JSON 对象，禁止数组包裹，禁止 markdown 代码块。
第 1 行必须是 {"type":"meta",...}，最后一行必须是 {"type":"done"}。
```

配合 `ChatClient` 的流式 API：

```java
Flux<String> lines = chatClient.prompt()
        .system(NDJSON_SYSTEM_PROMPT)
        .user(userQuery)
        .stream()
        .content();

lines.map(String::trim)
     .filter(s -> s.startsWith("{"))
     .map(this::parseLine)          // 单行解析，失败可跳过
     .subscribe(event -> dispatcher.dispatch(event),
                err -> log.warn("stream broken", err),
                () -> log.info("stream done"));
```

> 注意：模型偶尔会"忘记"换行，把两个对象粘在一行。所以生产上仍要用"括号配平"做行切分（数 `{` 和 `}`，字符串内的括号不计），而不是无脑 `split("\n")`。

---

## 五、安全边界：增量阶段绝对不要做的事

| 危险动作 | 后果 | 正确做法 |
|---|---|---|
| 用未闭合的数字做金额计算 | 把 `128` 当最终值（实际 `1280.50`） | 数字字段延迟到 token 完成 |
| 用半截字符串拼 SQL / 命令 | 注入、执行错误语句 | 只做"显示"，执行必须等全量校验 |
| 增量触发工具调用 | 参数缺字段、类型错 | 工具调用等 `VALUE_END` 后统一校验 |
| 增量写入数据库 | 脏数据、重复写 | 全量 schema 校验通过后一次写入 |
| 把增量内容当可信 | 模型可能在末尾"反转"前文 | 最终结果以完整文档为准，UI 标注"生成中" |

一句话原则：**增量用于"展示"，完整用于"决策"**。所有副作用（写库、调工具、发消息）必须发生在上游 `finish` 之后。

---

## 六、SSE 落地：五个必踩的坑

### 6.1 Nginx 缓冲

```nginx
location /api/ai/stream {
    proxy_pass http://backend;
    proxy_buffering off;              # 必须
    proxy_cache off;
    proxy_read_timeout 300s;          # 默认 60s 会切断长回答
    chunked_transfer_encoding on;
    gzip off;                         # 压缩会攒包
    add_header X-Accel-Buffering no;  # 兜底（后端也可设此头）
}
```

没有 `proxy_buffering off`，你会看到"憋 20 秒然后一次性吐出全部"——这是 SSE 排查的第一现场。

### 6.2 心跳与超时

```java
Flux<ServerSentEvent<String>> body = contentFlux
        .map(s -> ServerSentEvent.<String>builder(s).event("delta").build())
        .mergeWith(Flux.interval(Duration.ofSeconds(15))
                .map(i -> ServerSentEvent.<String>builder("").event("ping").build()))
        .concatWith(Flux.just(ServerSentEvent.<String>builder("[DONE]").event("done").build()))
        .timeout(Duration.ofMinutes(5));
```

心跳解决两件事：穿透中间设备的空闲超时（多数 LB 是 60s），以及让客户端能区分"模型在思考"和"连接已死"。

### 6.3 断线续传：`Last-Event-ID`

```java
// 服务端：每个事件带自增 id
long seq = 0;
ServerSentEvent.<String>builder(payload).id(String.valueOf(seq++)).event("delta").build();

// 服务端：重连时从 Checkpoint 恢复
@GetMapping(value = "/stream/{convId}", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<ServerSentEvent<String>> resume(@PathVariable String convId,
                                            @RequestHeader(value = "Last-Event-ID", required = false) String lastId) {
    long from = lastId == null ? 0 : Long.parseLong(lastId) + 1;
    return generator.resume(convId, from);   // 从快照 + 未消费事件重放
}
```

前提是**服务端要能重放**：把已生成的 delta 按序号落到 Redis List（带 TTL），或者干脆保存"已生成全文"，重连时把 `substring(consumedLength)` 一次性补发。

### 6.4 背压与取消

`Flux` 默认不丢数据，但如果下游（浏览器）慢，token 会在内存里堆积。生产上要设上限：

```java
contentFlux
    .onBackpressureBuffer(1000, BufferOverflowStrategy.DROP_OLDEST)
    .doOnCancel(() -> llmCall.cancel());   // 用户关页面 → 立刻取消上游，省钱
```

`doOnCancel` 非常重要：LLM 调用按 token 计费，用户断了还继续生成就是纯烧钱。实测中一个 10 万 DAU 的 AI 应用，不做取消传播会多花 8%~15% 的 token 费用。

### 6.5 代理压缩

`gzip` 对 SSE 是灾难：压缩器要攒够一个 block 才输出。如果前面有 CDN/WAF，务必确认它不会对 `text/event-stream` 做压缩或缓冲。

---

## 七、完整链路示意

```
LLM provider (chunked)
   │  delta: "{\"orderNo\":\"SO20"
   ▼
Spring WebFlux controller
   │  ChunkedInputStream.feed(delta)
   ▼
Jackson JsonParser (阻塞等待更多字节)
   │  token: FIELD_NAME orderNo / VALUE_STRING SO202611120001
   ▼
业务事件 → SSE (event: field, id: 17)
   │
   ▼
浏览器 EventSource → 局部更新 UI
```

整条链路上**没有任何一处等待完整响应**，首字节延迟 = 模型首个 token 的延迟。

---

## 八、面试追问

**Q1：为什么不用 `readTree` 反复解析？**
`readTree` 每次都要从缓冲区开头重新词法分析，总成本 O(n²)。1 万字符的输出会触发上百次全量解析，CPU 直接打满，而且每次都创建新对象，GC 压力大。

**Q2：Jackson 怎么知道 JSON 还没结束？**
`JsonParser` 是"拉取式"的：它在 token 边界需要更多输入时会调用底层 `InputStream.read()`。只要这个 `read()` 阻塞（而不是返回 -1），解析器就一直等。这就是"流式"的本质——**阻塞发生在 IO 层，而不是解析层**。

**Q3：流式输出时如何保证 JSON 合法性？**
两道防线：增量阶段只做"宽容解析"（能解析多少展示多少）；结束后用 `ObjectMapper.readValue(full, TypeRef)` 做严格校验 + Bean Validation，失败则重试或降级。

---

## 九、总结

- **JSON 天然支持流式解析**，前提是把"到达的字节"喂给一个会阻塞的 `InputStream`。
- 三种方案：全量重解析（简单但 O(n²)）、Jackson 增量 token（推荐）、服务端 JSON Patch（省带宽）。
- **数字字段天然延迟**，字符串闭合即安全；增量只用于展示，决策必须等全量校验。
- 能改协议就上 **NDJSON**，一行一事件，错误隔离、重连简单。
- SSE 生产五坑：Nginx 缓冲、缺心跳、无 `Last-Event-ID`、取消不传播、代理压缩。

把这条链路打通之后，"结构化"和"秒出字"就不再是二选一——这也是 AI 应用体验分水岭的一部分。
