---
title: 【Java AI】大模型调用录制回放深度实战：VCR 模式、SSE 增量重放与 Prompt 变更回归门禁
date: 2026-11-13 08:30:00
tags:
  - Java
  - AI
  - 测试
  - LLM
  - 工程化
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】大模型调用录制回放深度实战：VCR 模式、SSE 增量重放与 Prompt 变更回归门禁

## 前言

给大模型写单元测试，是所有 AI 应用团队都会撞上的墙：

- 输出是概率性的，`assertEquals` 根本没法写；
- 每次 CI 都真调 API，慢、贵、还依赖网络；
- 改了一行 prompt，不知道会影响哪些 case；
- 模型厂商悄悄升级了版本，线上效果变了却没人发现。

传统做法是 mock 掉 SDK，但 mock 出来的响应是「人编的」，跟真实输出分布完全不一致，测了等于没测。业界成熟的解法是 **VCR（Video Cassette Recorder）模式**：第一次真实调用时把「请求 + 响应」录成磁带（cassette），之后所有测试都从磁带回放。这个模式在 HTTP 客户端领域（Ruby 的 VCR、Java 的 WireMock 录制）已经用了十几年，搬到 LLM 场景需要额外解决三个问题：

1. **流式响应（SSE）怎么录**——chunk 边界本身就是被测逻辑的一部分；
2. **请求指纹怎么算**——消息数组、工具定义、参数顺序都会变；
3. **断言怎么写**——不能用全文相等，否则模型一升级全红。

这篇文章给出一套完整的 Java 实现：OkHttp 拦截器录制、JSONL 磁带格式、SSE 增量重放、JUnit 5 扩展、以及基于黄金集的差分回归门禁。

## 一、为什么是「录制回放」而不是「mock」

| 方案 | 可复现 | 真实性 | 维护成本 | 适用 |
|---|---|---|---|---|
| 手写 Mock | ✅ | ❌ 分布失真 | 低 | 只测分支逻辑 |
| 真调 API | ❌ | ✅ | 高（钱 + 稳定性） | 探索期 |
| **录制回放** | ✅ | ✅（录制时刻的快照） | 中（磁带要更新） | **回归测试主力** |
| 本地小模型 | ✅ | ⚠️ 能力差距大 | 高（部署） | 特定场景 |

录制回放的核心价值：**把「不确定的外部依赖」变成「确定的测试夹具」**，同时又保留了真实响应的格式、字段、边界情况（比如模型返回了带 markdown 代码块的 JSON、返回了 `tool_calls` 而不是 content）。

## 二、磁带的数据模型

一条磁带 = 一次请求 + 一次响应（可能是流式）：

```json
{
  "id": "9f2c1a...",
  "recordedAt": "2026-11-13T02:11:03Z",
  "request": {
    "method": "POST",
    "url": "https://api.openai.com/v1/chat/completions",
    "headers": { "content-type": ["application/json"] },
    "bodySha256": "a1b2...",
    "body": { "model": "gpt-4o-2024-08-06", "messages": [...], "temperature": 0 }
  },
  "response": {
    "status": 200,
    "headers": { "content-type": ["text/event-stream"] },
    "streaming": true,
    "chunks": [
      { "delayMs": 42, "data": "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n" },
      { "delayMs": 8,  "data": "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\n" },
      { "delayMs": 0,  "data": "data: [DONE]\n\n" }
    ],
    "body": null
  }
}
```

几个设计决策：

- **`bodySha256` 用于匹配**，`body` 用于排查。匹配不用完整 body 字符串，因为 JSON 字段顺序、空白都可能变。
- **`chunks` 保留原始 SSE 帧**（含 `data: ` 前缀和 `\n\n`），这样回放时被测的 SSE 解析器走的是真实路径。
- **`delayMs` 记录 chunk 间隔**：回放时默认不 sleep（CI 要快），但可以开启「真实时序模式」来测超时/背压逻辑。
- **`streaming` 显式标记**，避免把流式响应当普通 JSON 回放导致解析器分支走错。

## 三、录制层：一个 OkHttp 拦截器搞定

绝大多数 Java LLM SDK（OpenAI 官方 SDK、LangChain4j 的 OpenAiChatModel、Spring AI 的 OpenAiApi）底层都是 OkHttp 或 RestClient。拦截 OkHttp 覆盖面最广：

```java
public class RecorderInterceptor implements Interceptor {

    private final Path cassetteDir;
    private final Mode mode;                 // RECORD / REPLAY / PASSTHROUGH
    private final ObjectMapper mapper = new ObjectMapper();

    public enum Mode { RECORD, REPLAY, PASSTHROUGH }

    @Override
    public Response intercept(Chain chain) throws IOException {
        Request req = chain.request();
        String key = fingerprint(req);

        if (mode == Mode.REPLAY) {
            Cassette c = load(cassetteDir.resolve(key + ".json"));
            if (c == null) throw new IllegalStateException("cassette missing: " + key);
            return buildResponse(req, c);
        }

        Response resp = chain.proceed(req);
        if (mode == Mode.RECORD) {
            Cassette c = capture(req, resp);
            Files.createDirectories(cassetteDir);
            mapper.writeValue(cassetteDir.resolve(key + ".json").toFile(), c);
        }
        return resp;
    }

    /** 归一化后哈希：只取对语义有影响的字段 */
    private String fingerprint(Request req) {
        JsonNode body = readJson(req.body());
        ObjectNode normalized = mapper.createObjectNode();
        normalized.put("model", body.path("model").asText());
        normalized.set("messages", body.path("messages"));
        normalized.set("tools", body.path("tools"));
        normalized.put("temperature", body.path("temperature").asDouble(1.0));
        normalized.put("top_p", body.path("top_p").asDouble(1.0));
        normalized.put("stream", body.path("stream").asBoolean(false));
        normalized.put("max_tokens", body.path("max_tokens").asInt(-1));
        // 故意排除：user、request_id、metadata 等不影响输出的字段
        return sha256(normalized.toString());
    }
}
```

### 3.1 为什么指纹要「归一化」

直接哈希原始 body 会在这些情况下失配：

- Jackson 序列化字段顺序不稳定（尤其用 `Map` 承载参数时）；
- SDK 版本升级后新增了默认字段（如 `stream_options`）；
- 业务侧传了 `user`、`trace_id` 等与输出无关的字段。

归一化的原则：**只保留「能改变模型输出」的字段**。`model`、`messages`、`tools`、`temperature`、`top_p`、`max_tokens`、`response_format` 必留；`user`、`metadata`、自定义 header 必删。

### 3.2 流式响应的录制

录制流式响应不能直接 `resp.body().string()`——那会把流读干、返回给业务时已经空了。必须**边转发边录制**：

```java
private Cassette capture(Request req, Response resp) throws IOException {
    Cassette c = new Cassette();
    c.request = toRequestRecord(req);
    c.response.status = resp.code();

    String contentType = resp.header("Content-Type", "");
    c.response.streaming = contentType.contains("text/event-stream");

    if (!c.response.streaming) {
        // 注意：peekBody 有大小上限，非流式响应通常够用
        String body = resp.peekBody(8L * 1024 * 1024).string();
        c.response.body = body;
        return c;
    }

    // 流式：用 buffer + tee，把字节同时喂给录制器和下游
    ResponseBody original = resp.body();
    ByteArrayOutputStream recorded = new ByteArrayOutputStream();
    List<Chunk> chunks = new ArrayList<>();

    ResponseBody tee = new ResponseBody() {
        @Override public MediaType contentType() { return original.contentType(); }
        @Override public long contentLength() { return -1; }

        @Override public BufferedSource source() {
            BufferedSource src = original.source();
            return Okio.buffer(new ForwardingSource(src) {
                long last = System.nanoTime();
                @Override public long read(Buffer sink, long byteCount) throws IOException {
                    long n = super.read(sink, byteCount);
                    if (n == -1) return -1;
                    long now = System.nanoTime();
                    // 以空行（\n\n）为 SSE 帧边界切分，保留原始字节
                    byte[] buf = new byte[(int) n];
                    sink.copyTo(Okio.buffer(), sink.size() - n, n); // 简化示意
                    recorded.write(buf);
                    chunks.add(new Chunk((now - last) / 1_000_000, new String(buf, UTF_8)));
                    last = now;
                    return n;
                }
            });
        }
    };
    c.response.chunks = chunks;
    return c.withBody(tee);   // 生产实现里用 Interceptor 返回值重建 Response
}
```

工程上更稳的做法是**在 SSE 解析层录制**而不是在字节层：如果你的应用用一个 `SseEmitter`/`Flux<ChatChunk>` 的解析器，就在解析器出口录「结构化 chunk」，回放时序列化回 SSE 帧。字节层录制的优点是保真，缺点是分帧逻辑要自己处理 TCP 粘包。

## 四、回放层：MockWebServer 还是自建？

| 方案 | 优点 | 缺点 |
|---|---|---|
| `MockWebServer` + `Dispatcher` | 现成、支持 chunked | 每个测试要起服务，端口管理麻烦 |
| 自建 `HttpServer`（JDK 自带） | 零依赖、可控 | SSE 分帧要手写 |
| 拦截器内部直接返回 | 最快、无网络 | 绕过了 HTTP 层，测不到超时 |

推荐：**单元测试用拦截器直接返回，集成测试用 `MockWebServer`**。

`MockWebServer` 回放 SSE 的关键是 `setBody` + `throttleBody`：

```java
MockWebServer server = new MockWebServer();
Cassette c = loadCassette("9f2c1a...");

MockResponse resp = new MockResponse()
        .setResponseCode(c.response.status)
        .setHeader("Content-Type", "text/event-stream")
        .setHeader("Cache-Control", "no-cache");

for (Chunk chunk : c.response.chunks) {
    resp.addChunk(chunk.data);      // 保留 data: ...\n\n 原样
}
resp.setBodyDelay(0, TimeUnit.MILLISECONDS);   // 默认不延迟
server.enqueue(resp);

OpenAiChatModel model = OpenAiChatModel.builder()
        .baseUrl(server.url("/v1").toString())
        .apiKey("test")
        .build();

Flux<String> stream = model.stream("你好");
StepVerifier.create(stream)
        .expectNext("你", "好")
        .verifyComplete();
```

`addChunk` 与 `setBody` 的区别很重要：`addChunk` 生成 `Transfer-Encoding: chunked` 的分块响应，**这才是真实 SSE 的传输形态**；`setBody` 是一次性 body，测不出「解析器是否正确处理跨 chunk 边界的半个 JSON」。

## 五、断言：三层递进，别用全文相等

### 5.1 第一层：结构断言（必须）

```java
@Test
void shouldReturnValidJsonSchema() {
    OrderExtract result = extractor.extract("帮我下单两杯美式，明天下午送到公司");
    assertThat(result.items()).hasSize(2);
    assertThat(result.items()).allSatisfy(i ->
            assertThat(i.product()).isIn("美式", "拿铁", "摩卡"));
    assertThat(result.deliveryTime()).isNotNull();
}
```

### 5.2 第二层：语义断言（推荐）

```java
// 关键实体必须出现，禁用词必须不出现
assertThat(result.answer())
        .contains("退款")
        .doesNotContain("无法处理")
        .doesNotContain("作为AI");
```

### 5.3 第三层：LLM-as-Judge（离线、昂贵、单独 stage）

```java
@Tag("judge")
@Test
void answerShouldBeGrounded() {
    String answer = ragService.answer("退货政策是什么？");
    JudgeScore score = judge.evaluate(
            JudgeRequest.builder()
                    .criteria("答案必须只基于给定上下文，且引用具体条款编号")
                    .context(retrievedContext)
                    .answer(answer)
                    .build());
    assertThat(score.overall()).isGreaterThanOrEqualTo(4);   // 1~5 分
}
```

三层的关系：**第一层每次 CI 都跑（秒级），第二层每次都跑（毫秒级），第三层只在 prompt/model 变更时跑（分钟级 + 花钱）**。

## 六、差分回归：Prompt 变更的门禁

这才是录制回放最大的价值：**同一批磁带，跑两个版本的 prompt，输出差异一目了然**。

```java
public class PromptDiffRunner {

    record CaseResult(String caseId, boolean pass, long tokens, long latencyMs, String output) {}

    public DiffReport run(Path cassetteDir, PromptVersion candidate) {
        List<String> caseIds = listCaseIds(cassetteDir);
        List<CaseResult> baseline = new ArrayList<>();
        List<CaseResult> candidateResults = new ArrayList<>();

        for (String id : caseIds) {
            // 同一个输入，两套 prompt 各跑一次（走真实模型，不走回放）
            baseline.add(execute(id, PromptRegistry.active()));
            candidateResults.add(execute(id, candidate));
        }
        return DiffReport.builder()
                .total(caseIds.size())
                .baselinePassRate(passRate(baseline))
                .candidatePassRate(passRate(candidateResults))
                .tokenDelta(totalTokens(candidateResults) - totalTokens(baseline))
                .latencyP95Delta(p95(candidateResults) - p95(baseline))
                .regressions(regressed(baseline, candidateResults))
                .build();
    }
}
```

门禁规则示例（放在 CI 的 `prompt-eval` stage）：

```yaml
gate:
  min_pass_rate: 0.95                 # 绝对下限
  max_pass_rate_drop: 0.02            # 相对基线下降不超过 2 个百分点
  max_token_increase: 0.15            # token 成本上涨不超过 15%
  max_p95_latency_increase_ms: 300
  block_on_regression_cases: true     # 有任何一条从 pass 变 fail 就阻断
```

四个门禁维度的取舍：

- **pass rate** 是硬指标，掉 2 个点通常意味着某类意图挂了；
- **token 成本**容易被忽略，一个「让模型更详细地回答」的改动可能让成本翻倍；
- **P95 延迟**在流式场景等价于用户体验；
- **单 case 回退**最有价值——它直接告诉你「哪条业务挂了」，而不是一个抽象的百分比。

## 七、五个真实的坑

**坑 1：磁带进了 Git，带着 API Key。** 请求头里常有 `Authorization: Bearer sk-...`。录制时必须过滤 `authorization`、`api-key`、`cookie`，并在 CI 加 secret 扫描（gitleaks）。

**坑 2：忘了 `temperature=0` 也不是确定性的。** 浮点累加顺序、batch 大小变化、GPU 型号不同都会导致微小差异；模型厂商静默升级更会让输出大变。**磁带的价值不是「永远一致」，而是「可追溯到某个时刻的真实响应」**——所以 `recordedAt` 和 `model` 版本必须写进磁带。

**坑 3：模型别名导致磁带错配。** 用 `gpt-4o` 而不是 `gpt-4o-2024-08-06`，厂商一升级，同样的指纹命中旧磁带，测试「通过」但线上行为已变。**生产必须 pin 到带日期的快照版本**。

**坑 4：Embedding 调用没录。** 只录了 chat，RAG 测试每次真调 embedding，向量轻微变化导致召回集合变化，测试随机红。**所有外部模型调用（chat / embedding / rerank / moderation）都要录**。

**坑 5：并发测试写同一份磁带。** 多个测试并行 `RECORD`，文件互相覆盖，磁带损坏。用「测试方法名 + 线程 id」做二级目录，或录制阶段强制串行。

## 八、磁带生命周期管理

磁带不是录一次就永远有效，它有自己的生命周期：

| 阶段 | 动作 |
|---|---|
| 新增功能 | `RECORD` 录制新 case |
| Prompt 迭代 | 保留旧磁带，新磁带放 `v2/` 目录，差分对比 |
| 模型升级 | 全量重录（这是「预期变更」，需要人工 review diff） |
| 清理 | 90 天未命中的磁带归档到对象存储，别塞在 repo 里 |

目录结构建议：

```
src/test/resources/cassettes/
├── chat/
│   ├── order-extract/
│   │   ├── simple-order.json
│   │   └── multi-item-order.json
│   └── refund-qa/
│       └── policy-001.json
└── embedding/
    └── product-desc-001.json
```

一个 case 一个文件，diff 时能精确到 case，而不是一坨 5000 行的 JSONL。

## 九、面试常见追问

**Q1：大模型输出不确定，你怎么写测试？**

三层：结构断言（schema/字段）→ 语义断言（关键实体/禁用词）→ LLM-as-Judge（离线）。测试的目标不是「输出等于某个字符串」，而是「输出满足业务约束」。录制回放保证输入侧确定，断言保证输出侧有边界。

**Q2：录制回放和 mock 的本质区别？**

mock 的响应是人编的，只能验证「代码怎么处理这个响应」；录制回放的响应是真实模型产生的，能验证「真实分布下代码是否健壮」，还能在模型升级时做差分对比。

**Q3：磁带会不会过期？怎么管理？**

会。磁带绑定「模型版本 + prompt 版本 + 代码版本」。策略是：模型 pin 快照版本，prompt 变更走新目录 + 差分，磁带带 `recordedAt` 与 `model` 元数据，定期重录（如每季度）并把 diff 作为 review 材料。

**Q4：流式响应的测试重点是什么？**

不是「最终拼出的文本对不对」，而是：① 跨 chunk 边界的半个 JSON 能否正确解析；② `[DONE]` 之后的残留处理；③ 客户端断连后上游是否取消；④ 首 token 延迟（TTFT）与 chunk 间隔是否在预算内。

**Q5：怎么防止 prompt 改动引入回归？**

黄金集（50~200 条覆盖核心意图的 case）+ 差分运行 + 四维门禁（pass rate / token / P95 / 单 case 回退）。关键是**黄金集要包含历史故障 case**——每次线上出问题，就把它变成一条永久 case。

## 十、总结

- LLM 测试的核心矛盾是「输出不确定」vs「CI 要求确定」，录制回放是当前性价比最高的解法。
- 录制在 HTTP 层做（OkHttp 拦截器覆盖最广），指纹要归一化，只保留影响输出的字段。
- 流式响应必须逐 chunk 录制并保留 SSE 帧边界，否则测不到解析器的粘包处理。
- 断言分三层：结构 → 语义 → Judge，前两层进每次 CI，第三层只在变更时跑。
- 磁带必须绑定模型快照版本，携带 `recordedAt`，并纳入 prompt 差分门禁。

把「录制回放 + 差分门禁」这套基建做起来，你的 AI 应用才从「改完上线试试看」进入「改完敢上线」的阶段。
