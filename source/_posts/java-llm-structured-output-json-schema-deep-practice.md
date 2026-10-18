---
title: 【Java AI】结构化输出深度实战：JSON Schema、强类型映射与校验重试
date: 2026-10-18 08:15:00
tags:
  - Java
  - AI
  - Spring AI
  - LangChain4j
  - JSON Schema
  - 结构化输出
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】结构化输出深度实战：JSON Schema、强类型映射与校验重试

## 前言

「让大模型返回 JSON」是所有 AI 应用的第一道坎。你写了一行 prompt：`请以 JSON 格式返回`，测试时一切正常，上线后开始出现：

- 返回里带 ```json 代码块围栏，`ObjectMapper` 直接抛 `JsonParseException`；
- 字段名从 `userName` 变成 `user_name`，再变成 `用户名`；
- 数字字段返回 `"18"`（字符串），枚举返回 `"未知"`；
- 长文本被截断，JSON 少一个大括号；
- 模型很贴心地在 JSON 前后加了一句「好的，以下是结果：」。

这些问题的根因不是模型「不听话」，而是**你把结构化约束寄托在了自然语言上**。工程化的解法有三层：**Schema 约束 → 强类型反序列化 → 校验与重试**。缺一层，线上就一定会出问题。

这篇文章以 Java 技术栈为主线，讲清楚 JSON Schema 怎么写、Spring AI 与 LangChain4j 怎么落地、Jackson 怎么配、校验重试怎么做，最后给生产踩坑清单和面试追问。

---

## 一、四种结构化输出方案对比

| 方案 | 原理 | 可靠性 | 成本 | 适用 |
|---|---|---|---|---|
| Prompt 约定 | 自然语言要求「返回 JSON」 | ★★ | 最低 | Demo、内部工具 |
| JSON Mode | `response_format={"type":"json_object"}` | ★★★ | 低 | 简单对象，无严格 schema |
| Function Calling | 把 schema 当工具参数，模型「调用」 | ★★★★ | 中 | 需要模型主动决策的场景 |
| JSON Schema 严格模式 | 服务端约束解码，schema 级强制 | ★★★★★ | 中高 | 生产主力 |
| 本地约束解码 | vLLM guided decoding / GBNF | ★★★★★ | 高（自部署） | 私有化、极致稳定 |

### 1.1 JSON Mode 的局限

`json_object` 只保证「输出是合法 JSON」，**不保证字段符合你的 schema**。模型仍可能少字段、多字段、类型错。它解决的是「解析器不崩」，不是「业务可用」。

### 1.2 Strict 模式的硬性要求

OpenAI 的 `json_schema` strict 模式（以及多数兼容实现）要求：

1. `additionalProperties: false` —— 禁止多余字段；
2. **所有** properties 都必须在 `required` 里（想可选就用 `anyOf: [type, null]`）；
3. 不支持部分 JSON Schema 关键字（如 `patternProperties`、`minLength` 的某些组合）；
4. 嵌套深度和字段数有上限。

这带来一个反直觉的结论：**strict 模式不是「更宽松」，而是「更严格」**。你必须在 schema 里把所有字段声明为 required，然后用 nullable 表达可选。

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["title", "tags", "score", "summary"],
  "properties": {
    "title":   { "type": "string" },
    "tags":    { "type": "array", "items": { "type": "string" }, "maxItems": 8 },
    "score":   { "type": "number", "minimum": 0, "maximum": 1 },
    "summary": {
      "anyOf": [{ "type": "string" }, { "type": "null" }]
    }
  }
}
```

---

## 二、Spring AI 落地

### 2.1 BeanOutputConverter

Spring AI 提供 `BeanOutputConverter<T>`，做两件事：

1. `getFormat()`：根据 Java 类型生成 JSON Schema + 格式说明，拼进 prompt；
2. `convert(String)`：把模型返回的文本反序列化成对象（内部用 Jackson）。

```java
public record MovieReview(
        String title,
        List<String> tags,
        double score,
        String summary
) {}

BeanOutputConverter<MovieReview> converter = new BeanOutputConverter<>(MovieReview.class);

String prompt = """
        请分析下面这段影评，输出结构化结果。
        %s
        影评：%s
        """.formatted(converter.getFormat(), reviewText);

String raw = chatModel.call(prompt);
MovieReview review = converter.convert(raw);
```

`getFormat()` 生成的提示大致是：

```text
Your response should be in JSON format.
Do not include any explanations, only provide a RFC8259 compliant JSON response
following this format without deviation.
Here is the JSON Schema instance your output must adhere to:
{"$schema":"https://json-schema.org/draft/2020-12/schema",
 "type":"object",
 "properties":{"title":{"type":"string"}, ...},
 "required":["title","tags","score","summary"],
 "additionalProperties":false}
```

注意：**这段 schema 每次请求都会进 prompt**，是实打实的 input token。一个 20 字段的 schema 大约 800~1500 token，QPS 高时这笔成本很可观。优化手段见第五节。

### 2.2 ChatClient 的 entity() 快捷方式

Spring AI 1.0 之后更推荐 `ChatClient`：

```java
@RestController
public class ReviewController {

    private final ChatClient chatClient;

    public ReviewController(ChatClient.Builder builder) {
        this.chatClient = builder
                .defaultSystem("你是资深影评分析助手，只输出结构化结果。")
                .build();
    }

    @GetMapping("/review")
    public MovieReview analyze(@RequestParam String text) {
        return chatClient.prompt()
                .user(u -> u.text("分析影评：{text}").param("text", text))
                .call()
                .entity(MovieReview.class);      // 自动注入 format + 反序列化
    }
}
```

泛型集合用 `ParameterizedTypeReference`：

```java
List<MovieReview> list = chatClient.prompt()
        .user("列出 5 部科幻电影并打分")
        .call()
        .entity(new ParameterizedTypeReference<List<MovieReview>>() {});
```

> 注意：`entity()` 依赖模型返回可解析的 JSON。如果模型返回了 markdown 围栏，Spring AI 的 converter 会尝试清洗，但**不保证 100% 成功**。生产环境仍要加校验与重试。

### 2.3 显式开启 JSON Schema strict

如果你用的是 OpenAI 兼容模型，可以在 options 里指定 `responseFormat`：

```java
OpenAiChatOptions options = OpenAiChatOptions.builder()
        .model("gpt-4o-mini")
        .responseFormat(new ResponseFormat(
                ResponseFormat.Type.JSON_SCHEMA,
                """
                {"name":"movie_review","strict":true,
                 "schema":{"type":"object","additionalProperties":false,
                 "required":["title","tags","score","summary"],
                 "properties":{"title":{"type":"string"},
                   "tags":{"type":"array","items":{"type":"string"}},
                   "score":{"type":"number"},
                   "summary":{"type":"string"}}}}
                """))
        .temperature(0.2)
        .build();

String raw = chatModel.call(new Prompt(prompt, options)).getResult().getOutput().getText();
```

temperature 调低（0.1~0.3）能显著降低「自由发挥」的概率，但**不能替代 schema**。

---

## 三、LangChain4j 落地

LangChain4j 的 `AiServices` 走的是「接口 + 返回类型」路线，声明式更强：

```java
interface ReviewAnalyzer {

    @UserMessage("""
            分析下面的影评，提取标题、标签、评分（0~1）、一句话总结。
            影评：{{text}}
            """)
    MovieReview analyze(@V("text") String text);

    @UserMessage("把这段话拆成待办事项列表：{{text}}")
    List<TodoItem> todos(@V("text") String text);
}

ReviewAnalyzer analyzer = AiServices.builder(ReviewAnalyzer.class)
        .chatLanguageModel(model)
        .build();

MovieReview review = analyzer.analyze("这部电影的摄影非常出色……");
```

LangChain4j 内部会：

1. 根据方法返回类型生成 JSON Schema；
2. 把它注入到 prompt（`ServiceOutputParser`）；
3. 用 Jackson 反序列化，并剥离可能的 markdown 围栏。

对于需要「先思考再输出」的场景，可以用 `AiServices` 配合 `@SystemMessage`：

```java
@SystemMessage("""
        先在心里分析，再输出 JSON。
        只输出 JSON，不要任何解释文字。
        """)
```

### 3.1 枚举与日期

```java
public enum Sentiment { POSITIVE, NEUTRAL, NEGATIVE }

public record Review(
        String title,
        Sentiment sentiment,
        @JsonFormat(pattern = "yyyy-MM-dd") LocalDate publishedAt
) {}
```

枚举是高频翻车点：模型可能返回 `"positive"`（小写）、`"正面"`（中文）、`"POSITIVE "`（带空格）。Jackson 默认严格匹配，直接抛 `InvalidFormatException`。解决：

```java
public enum Sentiment {
    POSITIVE, NEUTRAL, NEGATIVE;

    @JsonCreator
    public static Sentiment from(String raw) {
        if (raw == null) return NEUTRAL;
        String v = raw.trim().toUpperCase(Locale.ROOT);
        return switch (v) {
            case "POSITIVE", "正面", "积极", "POS" -> POSITIVE;
            case "NEGATIVE", "负面", "消极", "NEG" -> NEGATIVE;
            default -> NEUTRAL;
        };
    }
}
```

### 3.2 列表返回的坑

模型返回 `List<T>` 时，可能给你：

- 纯数组 `[{...},{...}]` ✅
- 包了一层 `{"items":[...]}` ❌
- 包了一层 `{"result":[...]}` ❌

稳妥做法是定义一个包装类型，让 schema 明确：

```java
public record TodoList(List<TodoItem> items) {}
```

然后 `TodoList todos(String text)`。**用包装对象换取 schema 确定性，是值得的。**

---

## 四、强类型映射：Jackson 配置

结构化输出的下半场是反序列化。推荐一套「宽容读入、严格校验」的配置：

```java
@Bean
public ObjectMapper llmObjectMapper() {
    return JsonMapper.builder()
            // 模型偶尔多加字段，不要让整个请求失败
            .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            // 空字符串转 null，避免 "" -> 数字报错
            .enable(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT)
            // 允许 "18" -> 18（模型经常把数字写成字符串）
            .enable(DeserializationFeature.ACCEPT_STRING_AS_NUMBER)   // 注意：Jackson 无此开关，见下方说明
            .build();
}
```

> 说明：Jackson **没有** `ACCEPT_STRING_AS_NUMBER` 这个开关。数字/字符串互转要靠自定义 `Deserializer` 或 `CoercionConfig`：

```java
@Bean
public ObjectMapper llmObjectMapper() {
    ObjectMapper mapper = JsonMapper.builder()
            .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .enable(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT)
            .build();

    mapper.coercionConfigFor(LogicalType.Integer)
            .setCoercion(CoercionInputShape.String, CoercionAction.TryConvert);
    mapper.coercionConfigFor(LogicalType.Float)
            .setCoercion(CoercionInputShape.String, CoercionAction.TryConvert);
    mapper.coercionConfigFor(LogicalType.Boolean)
            .setCoercion(CoercionInputShape.String, CoercionAction.TryConvert);
    return mapper;
}
```

再配一个「清洗 + 解析」的工具方法：

```java
public final class LlmJson {

    private static final Pattern FENCE =
            Pattern.compile("```(?:json)?\\s*(.*?)\\s*```", Pattern.DOTALL);

    public static <T> T parse(String raw, Class<T> type, ObjectMapper mapper) {
        String cleaned = clean(raw);
        try {
            return mapper.readValue(cleaned, type);
        } catch (JsonProcessingException e) {
            throw new LlmParseException("JSON 解析失败: " + preview(cleaned), e);
        }
    }

    static String clean(String raw) {
        if (raw == null) throw new LlmParseException("模型返回为空");
        String s = raw.trim();
        Matcher m = FENCE.matcher(s);
        if (m.find()) s = m.group(1).trim();          // 剥离 ```json 围栏
        int start = s.indexOf('{');
        int end = s.lastIndexOf('}');
        if (start >= 0 && end > start) {
            s = s.substring(start, end + 1);          // 去掉前后解释文字
        }
        return s;
    }

    private static String preview(String s) {
        return s.length() <= 200 ? s : s.substring(0, 200) + "...";
    }
}
```

**注意**：`indexOf('{')` / `lastIndexOf('}')` 的粗暴截取对嵌套数组也有效，但如果模型在 JSON 前写了带花括号的解释（少见），会误截。更稳的是用 `JsonParser` 做流式扫描，找到第一个完整 token 树。

---

## 五、校验与重试：把不确定性关进笼子

### 5.1 Bean Validation

```java
public record MovieReview(
        @NotBlank @Size(max = 100) String title,
        @NotNull @Size(min = 1, max = 8) List<@NotBlank String> tags,
        @DecimalMin("0.0") @DecimalMax("1.0") double score,
        @NotBlank @Size(max = 200) String summary
) {}
```

```java
private final Validator validator;

public MovieReview validate(MovieReview r) {
    Set<ConstraintViolation<MovieReview>> errors = validator.validate(r);
    if (!errors.isEmpty()) {
        throw new LlmValidationException(errors.stream()
                .map(v -> v.getPropertyPath() + " " + v.getMessage())
                .toList());
    }
    return r;
}
```

### 5.2 带错误反馈的重试

关键点：**重试时把校验错误告诉模型**，而不是原样重发。

```java
public MovieReview analyzeWithRetry(String text, int maxAttempts) {
    String lastError = null;
    for (int i = 0; i < maxAttempts; i++) {
        String prompt = buildPrompt(text, lastError);
        String raw = chatModel.call(prompt);
        try {
            MovieReview parsed = LlmJson.parse(raw, MovieReview.class, mapper);
            return validate(parsed);
        } catch (LlmParseException | LlmValidationException e) {
            lastError = e.getMessage();
            log.warn("structured output attempt {} failed: {}", i + 1, lastError);
        }
    }
    throw new LlmStructuredOutputException("重试 " + maxAttempts + " 次仍失败", lastError);
}
```

`buildPrompt` 里追加：

```text
上一次输出存在以下问题：score 必须在 0 到 1 之间，你返回了 8.5。
请修正后重新输出，只输出 JSON。
```

实测这套「错误反馈 + 重试」能把失败率从 3%~5% 降到 0.2% 以下（取决于模型）。重试次数建议 2~3 次，超过就降级。

### 5.3 降级策略

重试仍失败时，不要抛 500 给用户。三条路：

1. **返回部分结果**：用默认值填充缺失字段，标记 `degraded=true`；
2. **切换模型**：小模型失败 → 大模型兜底（成本换成功率）；
3. **转人工/异步补偿**：写入待处理队列，后台二次处理。

---

## 六、流式结构化输出

`entity()` 是阻塞式，拿不到「边生成边渲染」的体验。流式结构化输出需要**增量 JSON 解析**：

```java
chatClient.prompt()
        .user(prompt)
        .stream()
        .content()
        .scan(new StringBuilder(), (sb, chunk) -> sb.append(chunk))
        .subscribe(acc -> {
            // 每来一个 chunk，尝试解析已有前缀（不完整时抛异常忽略）
            PartialJson.tryExtract(acc.toString())
                    .ifPresent(partial -> sse.send(partial));
        });
```

实现要点：

- 用 `com.fasterxml.jackson.core.JsonParser` 的 `nextToken()` 逐步读，遇到 `JsonEOFException` 就保留状态等下一个 chunk；
- 只推「已完整」的字段，比如 `title` 完整了就先渲染标题，`tags` 数组逐个 push；
- 不要在每个 chunk 上 `readValue` 整个字符串（O(n²) 且必然失败）。

这也是 AI 产品体验的关键：**用户看到字在动，感知延迟下降一个数量级**，即使总耗时不变。

---

## 七、生产踩坑清单

**坑 1：schema 太大，token 成本失控。**
20 个字段的 schema 每次 1k+ token。优化：① 精简字段描述；② 把 schema 放到 system prompt 并利用 prompt caching；③ 拆分：先让模型输出「分类」，再按分类调用不同的窄 schema。

**坑 2：strict 模式下字段全 required，模型开始编造。**
所有字段必填，模型没信息就编。解决：允许 `null`（`anyOf`），并在 prompt 里明确「未知填 null，不要猜测」。

**坑 3：嵌套过深导致截断。**
三层嵌套 + 长数组，`max_tokens` 一超就截断。对策：限制 `maxItems`、拆成两次调用、把 `max_tokens` 调到足够大并监控 `finish_reason=length`。

**坑 4：数字精度。**
模型返回 `0.30000000000000004` 或 `1e-3`。金额类字段**不要用 double**，用 `BigDecimal` + 字符串传输，schema 用 `"type":"string","pattern":"^\\d+(\\.\\d{1,2})?$"`。

**坑 5：中文枚举值。**
schema 里用 `enum` 限定英文值，别让模型自由发挥中文同义词。

**坑 6：忽略 `finish_reason`。**
`length` 表示截断，`content_filter` 表示被拦。必须检查，否则会把半截 JSON 当成功。

**坑 7：重试没有幂等保护。**
如果结构化输出后面还跟着「写库」动作，重试可能重复写入。重试应只包住「生成+解析」，副作用放在成功后一次性执行。

---

## 八、面试追问

**Q1：JSON Mode 和 JSON Schema 有什么区别？**
JSON Mode 只保证输出是合法 JSON；JSON Schema（strict）还保证字段、类型、必填项符合约定，通常由服务端约束解码实现。前者解决「能解析」，后者解决「能直接用」。

**Q2：strict 模式为什么要求所有字段 required？**
约束解码需要在生成每个 token 时判断「下一个 token 是否合法」。可选字段会让状态机出现「跳过该字段」的分支，实现复杂且易错，所以规范要求用 `anyOf: [T, null]` 表达可选。

**Q3：Spring AI 的 `BeanOutputConverter` 做了什么？**
两件事：根据 Java Bean 生成 JSON Schema 并拼进 prompt（`getFormat()`）；把返回文本反序列化为对象（`convert()`）。它不负责调用模型，也不负责业务校验。

**Q4：模型返回 markdown 围栏怎么办？**
解析前清洗：正则提取 ```json 代码块内容，或截取第一个 `{` 到最后一个 `}`。更稳的是用流式 JSON parser 定位第一个完整 JSON 值。

**Q5：如何提高结构化输出的成功率？**
五件事：① 用 strict schema；② temperature 降到 0.1~0.3；③ 字段名和描述清晰，给枚举；④ 校验失败时把错误反馈给模型重试；⑤ 控制输出长度，避免截断。

**Q6：流式场景怎么做结构化输出？**
增量解析：维护缓冲区，用 `JsonParser` 逐 token 读取，遇到不完整就等待；已完成的字段立即推送。不能每个 chunk 都整体反序列化。

**Q7：为什么不建议用 `Map<String,Object>` 接收？**
失去编译期类型检查，字段名拼错、类型不匹配都要到运行时才发现；业务代码里到处 `(String) map.get("x")`，可维护性差。强类型 record 是更好的契约。

---

## 总结

结构化输出是一条三段式的流水线：

1. **约束**：用 JSON Schema（strict）把「格式」变成硬约束，而不是祈祷模型听话；
2. **映射**：Jackson 宽容读入 + 自定义 Coercion + 枚举兜底，把「模型的自由」收敛成「Java 的类型」；
3. **校验**：Bean Validation + 错误反馈重试 + 降级，把「偶发失败」变成「可控失败」。

在 Java 生态里，Spring AI 的 `entity()` 和 LangChain4j 的「接口返回 POJO」已经把前两层封装得很好，但**第三层必须自己写**。线上稳定性的差距，几乎全在这一层。
