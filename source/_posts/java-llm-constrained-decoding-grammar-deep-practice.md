---
title: 【Java AI】结构化约束解码深度实战：JSON Schema、Grammar 与 logits 掩码的底层原理
date: 2026-11-24 08:15:00
tags:
  - Java
  - AI
  - 结构化输出
  - 约束解码
  - LLM
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】结构化约束解码深度实战：JSON Schema、Grammar 与 logits 掩码

## 前言：为什么「让模型输出 JSON」永远有 1% 的失败率

几乎所有 Java 团队都写过这段代码：

```java
String prompt = "请输出 JSON，格式：{\"name\": \"...\", \"age\": 0}";
String raw = chatClient.prompt(prompt).call().content();
Order order = objectMapper.readValue(raw, Order.class);  // 偶尔在这里炸
```

失败的样子很固定：模型在 JSON 前面加了一句「好的，这是结果：」、用了单引号、多了一个逗号、把数字写成 `"18"`、或者输出到一半被 `max_tokens` 截断。

这类问题的根源是：**大模型生成的是 token 序列，它并不「知道」什么是合法 JSON**。你在 prompt 里写的格式要求，只是概率上的引导，不是硬约束。要让合法率从 99% 变成 100%，必须介入解码过程本身——这就是**约束解码（constrained decoding）**。

本篇讲三层东西：底层 logits 掩码怎么工作、各家后端怎么配、Java 侧怎么落地与兜底。本站已有一篇《结构化输出与 JSON Schema》讲 `BeanOutputConverter` 与强类型映射，本篇专攻**解码层**，两者互补。

---

## 二、原理：每一步都把不合法的 token 概率打成 -∞

自回归解码的每一步，模型会输出词表上每个 token 的 logits，然后采样。约束解码做的事情非常朴素：

```
1. 维护一个「当前语法状态」的自动机（JSON 语法 / 正则 / GBNF）
2. 对词表里每个 token，判断「接在当前前缀后面，是否仍是合法前缀」
3. 不合法的 token，logits 置为 -inf
4. 在剩余合法 token 上做 softmax + 采样
5. 用选中的 token 推进自动机状态，回到 1
```

关键点是第 2 步的「合法前缀」判定：**不要求 token 让整个输出合法，只要求它不破坏「还有可能变合法」这个性质**。比如已经输出了 `{"age": `，那么 `1` 合法（后面还能接 `}`），`"` 也合法（可以输出字符串），但 `}` 不合法（`age` 没有值）。

这就带来一个反直觉的现象：**约束解码只能保证语法合法，不能保证语义正确**。`{"age": 999999}` 语法完全合法，但业务上荒谬；`{"status": "cancelled"}` 符合 enum，但订单本来是已支付。语法约束和业务校验是两层，谁也不能替代谁。

### 三种约束表达能力的层级

| 约束方式 | 表达能力 | 典型实现 | 能否表达递归结构 |
|---|---|---|---|
| 正则（regex） | 正则语言 | Outlines、vLLM `guided_regex` | ❌ |
| JSON Schema → 正则/FSM | 大部分 JSON 结构 | Outlines、XGrammar 的 JSON 模式 | ⚠️ 有限（`$ref` 展开） |
| 上下文无关文法（CFG/GBNF） | 上下文无关语言 | llama.cpp GBNF、XGrammar CFG | ✅ |

为什么递归很重要？因为 JSON Schema 允许 `$ref` 自引用（树形结构、嵌套评论）。正则表达不了无限嵌套，只能展开到固定深度；GBNF 可以写成递归规则：

```gbnf
root   ::= object
object ::= "{" ws (pair ("," ws pair)*)? ws "}"
pair   ::= string ws ":" ws value
value  ::= object | array | string | number | "true" | "false" | "null"
array  ::= "[" ws (value ("," ws value)*)? ws "]"
string ::= "\"" ([^"\\] | "\\" .)* "\""
number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?
ws     ::= [ \t\n]*
```

### 代价：不是免费的午餐

| 成本项 | 说明 | 量级 |
|---|---|---|
| 语法编译 | 首次请求把 schema 编译成自动机 | 几十 ms ~ 数秒（大 schema） |
| 每步掩码 | 遍历词表判断合法性 / 查预计算表 | 词表 10 万级，未优化时显著 |
| 前缀缓存 | 同一状态复用掩码 | 命中后接近零成本 |
| 首 token 延迟 | 编译 + 首次掩码 | TTFT 增加 10%~50% |
| 与投机解码冲突 | 草稿 token 也要过掩码，接受率下降 | 加速比下降 |
| 输出 token 数 | 严格 JSON 会多出引号/花括号 | 增加 5%~20% |

所以生产上有一个重要经验：**schema 要小而稳定**。把 200 个字段的巨型 DTO 丢给约束解码，编译慢、缓存命中差、首 token 延迟肉眼可见。正确做法是按场景拆成多个小 schema，或者只约束「关键字段」，其余让模型自由发挥后再校验。

---

## 三、各后端的配置方式（Java 视角）

### 3.1 OpenAI：`json_schema` + `strict`

```java
var body = Map.of(
    "model", "gpt-4.1",
    "messages", List.of(Map.of("role", "user", "content", "解析这句话里的订单信息：" + text)),
    "response_format", Map.of(
        "type", "json_schema",
        "json_schema", Map.of(
            "name", "order",
            "strict", true,
            "schema", orderSchema        // 必须是 strict 兼容的 schema
        )
    )
);
```

`strict: true` 有硬性要求，很多人栽在这：

- 每个 object 必须 `additionalProperties: false`
- **所有 properties 都必须出现在 `required` 里**（想可选就用 `["string","null"]` 联合类型）
- 不支持部分 JSON Schema 关键字（如 `patternProperties`、`minLength` 之外的一些约束）

满足之后，模型输出**保证符合 schema**。但注意：**保证的是「如果输出完整，则符合 schema」**。如果 `max_tokens` 太小被截断，你拿到的仍是不完整 JSON。所以 `finish_reason == "length"` 必须当成失败处理，而不是解析失败。

### 3.2 vLLM：`structured_outputs`（底层 xgrammar / outlines）

自建推理服务时，vLLM 的约束解码是性价比最高的方案：

```java
// vLLM 新版：structured_outputs 统一入口
Map<String, Object> payload = Map.of(
    "model", "Qwen2.5-32B-Instruct",
    "messages", messages,
    "max_tokens", 512,
    "temperature", 0,
    "structured_outputs", Map.of(
        "json", orderSchema            // 也支持 "regex" / "choice" / "grammar"
    )
);
```

```java
// 旧版 / 兼容写法：guided_json
payload.put("guided_json", orderSchema);
payload.put("guided_regex", "\\d{4}-\\d{2}-\\d{2}");
payload.put("guided_choice", List.of("paid", "unpaid", "refunded"));
```

Java 侧用 `RestClient` 调即可，没有 SDK 依赖：

```java
RestClient client = RestClient.builder()
    .baseUrl("http://vllm.internal:8000")
    .build();

String resp = client.post()
    .uri("/v1/chat/completions")
    .contentType(MediaType.APPLICATION_JSON)
    .body(payload)
    .retrieve()
    .body(String.class);
```

一个必须知道的细节：**vLLM 的 `guided_json` 只约束语法，不校验 `minimum`/`maximum`/`minLength` 这类语义约束**。schema 里写 `"age": {"type":"integer","minimum":0,"maximum":150}`，模型仍可能输出 `999`。范围校验必须在 Java 侧做。

### 3.3 Ollama / llama.cpp：`format` 与 `grammar`

```java
// Ollama：format 直接传 JSON Schema（新版），或传 "json" 走宽松模式
Map<String, Object> req = Map.of(
    "model", "qwen2.5:14b",
    "messages", messages,
    "stream", false,
    "format", orderSchema,
    "options", Map.of("temperature", 0, "num_predict", 512)
);
```

```java
// llama.cpp server：传 GBNF 字符串
Map<String, Object> req = Map.of(
    "prompt", prompt,
    "grammar", gbnf,          // 上面那段 GBNF
    "temperature", 0,
    "n_predict", 512
);
```

llama.cpp 的 `json_schema` 转换在部分版本里对 `$ref`、`anyOf` 支持不完整，遇到复杂 schema 建议**先本地转成 GBNF 并单测**，不要假设线上一定成功。

---

## 四、Java 落地：schema 从哪来、结果怎么验

### 4.1 用代码生成 schema，而不是手写字符串

手写 JSON Schema 字符串是维护灾难。用 `victools/jsonschema-generator` 从 Java 类生成，schema 与 DTO 永远同步：

```java
SchemaGeneratorConfig config = new SchemaGeneratorConfigBuilder(
        SchemaVersion.DRAFT_2020_12, OptionPreset.PLAIN_JSON)
    .with(Option.FORBIDDEN_ADDITIONAL_PROPERTIES_BY_DEFAULT)
    .build();

SchemaGenerator generator = new SchemaGenerator(config);
JsonNode schema = generator.generateSchema(OrderExtraction.class);
String schemaJson = schema.toString();
```

配合 `jakarta.validation` 注解，可以把 `@NotNull`、`@Min` 映射成 schema 约束（需要额外配置），但记住前面说的：**这些约束在多数推理后端不会被执行**。

### 4.2 解析 + 校验 + 重试的闭环

约束解码把失败率从 1% 降到接近 0，但工程上仍要闭环，因为还有截断、超时、后端降级（比如约束解码不可用时回退到普通模式）：

```java
public <T> T extract(String text, Class<T> type) {
    String schema = schemaFor(type);
    String lastError = null;

    for (int attempt = 1; attempt <= 3; attempt++) {
        LlmResult r = llm.structured(text, schema, attempt);
        if (r.finishReason() == FinishReason.LENGTH) {
            lastError = "output truncated";
            continue;                       // 截断重试：加大 max_tokens
        }
        try {
            JsonNode node = mapper.readTree(r.content());
            Set<ValidationMessage> errors = validator.validate(node);
            if (!errors.isEmpty()) {
                lastError = errors.toString();
                continue;                   // 语义校验失败：把错误回灌
            }
            return mapper.treeToValue(node, type);
        } catch (JsonProcessingException e) {
            lastError = e.getOriginalMessage();
        }
    }
    throw new StructuredOutputException("failed after 3 attempts: " + lastError);
}
```

三个细节决定这套代码在生产里是否好用：

1. **重试要带错误信息**（"上次输出缺少字段 `amount`，请补全"），而不是原样重发。带反馈的重试成功率能从 60% 提到 90%。
2. **重试要换策略**：第一次约束解码、第二次降 temperature、第三次拆小 schema。同参数重试只是浪费钱。
3. **失败要可观测**：记录 `attempt`、`finish_reason`、校验错误类型。如果某类错误突然上涨，往往是 schema 变更或后端版本升级导致的。

---

## 五、五个生产级坑

### 坑 1：把「语法合法」当成「业务正确」

最危险的组合是：约束解码 + 直接入库。模型输出 `{"orderId": "A123", "action": "refund"}`，语法完美，但 `orderId` 是幻觉出来的。**约束只保证形状，不保证事实**。所有涉及写操作的字段，必须回到数据库校验。

### 坑 2：流式场景下「边流边解析」踩空

约束解码下，流式返回的每个 chunk 都是**合法前缀**，但不是合法 JSON。`{"a": 1` 是合法前缀，`json.loads` 会失败。正确做法是增量解析（Jackson 的 `JsonParser` 在 `ALLOW_...` 模式下可以容忍不完整输入），并且**只在流结束后才做业务决策**。

### 坑 3：schema 里的 `anyOf` 让编译时间爆炸

`anyOf`/`oneOf` 会被展开成多个分支，自动机状态数呈乘积增长。一个含 5 个 `anyOf`、每个 4 分支的 schema，状态数可能是 1024 倍。表现是**首请求延迟几秒甚至超时**。解法：拆成多次调用，或改成「判别字段 + 扁平结构」。

### 坑 4：数字精度被语法吃掉

GBNF 的 number 规则允许 `1.`、`01`、`1e999` 这类中间/异常形态；某些实现会把大整数输出成科学计数法。Java 侧用 `BigDecimal` 接收，并且对金额字段强制 `scale=2`、范围校验，不要直接 `doubleValue()`。

### 坑 5：约束解码与工具调用混用

Function Calling 的参数本质上也是一次结构化输出。如果后端支持，**给工具参数也加 grammar 约束**，能显著降低「参数缺失/类型错误」导致的工具调用失败。但注意：工具的 JSON Schema 往往包含嵌套对象和可选字段，要按后端的 strict 要求改写（全部 required + 可空类型）。

---

## 六、效果评测：别只看「合法率」

做约束解码的收益评估，至少要四个指标：

| 指标 | 定义 | 期望 |
|---|---|---|
| 语法合法率 | `JSON.parse` 成功比例 | 99% → 100% |
| 语义正确率 | 字段值与标准答案一致 | 不应下降超过 1% |
| TTFT 增量 | 首 token 延迟变化 | < 30% |
| 单位成功成本 | 总成本 / 成功条数 | 下降（少了重试） |

**语义正确率一定要单独测**。约束解码有一个隐蔽的副作用：语法被锁死后，模型可能为了「满足结构」而编造字段值（尤其是必填但信息缺失的字段）。所以 schema 里该可空的字段要可空，别为了 strict 把所有字段都设成必填。

建议用 100~200 条黄金集做 A/B：同一批输入，一组用约束解码，一组用 prompt + 重试，比较四个指标。多数场景下约束解码在「单位成功成本」上是明显赢的，因为省掉了重试和二次调用。

---

## 七、面试追问

**Q1：约束解码是在模型侧还是应用侧？**
在推理服务的解码循环里。应用侧只能通过 API 参数（`guided_json`/`format`/`grammar`）把约束传给推理服务；纯 API 调用方拿不到 logits，无法在 JVM 内做掩码。

**Q2：为什么约束解码不能保证 JSON 一定完整？**
它保证每一步都合法，但生成长度由 `max_tokens`/`stop` 控制。达到长度上限时会在一个合法前缀处截断，例如 `{"a": 1, "b":`——前缀合法，整体不完整。所以必须检查 `finish_reason`。

**Q3：正则约束和 JSON Schema 约束哪个更好？**
简单格式（日期、手机号、枚举）用正则更轻量；结构化对象用 JSON Schema 更可维护。JSON Schema 最终也会被编译成正则或自动机，表达能力受后端实现限制。

**Q4：约束解码会不会让模型「变笨」？**
会有一点。语法约束缩小了搜索空间，可能排除掉模型本来想表达的合理内容（尤其是需要先「想一想」再输出的任务）。所以复杂推理任务建议**先自由生成思维链，再单独做一次结构化抽取**，而不是全程约束。

**Q5：Java 侧能不能自己做约束解码？**
只有在你自建推理（DJL/ONNX Runtime/TensorRT）并能拿到 logits 时才可能，需要实现 `LogitsProcessor` 并维护自动机状态。工程成本很高，除非有强合规需求（不能出内网），否则没必要。

### 落地检查清单

- [ ] schema 由代码生成，且纳入版本管理
- [ ] 后端参数正确（strict 要求、`additionalProperties: false`、全部 required）
- [ ] `finish_reason == length` 视为失败并重试
- [ ] 语法校验之外，有业务/语义校验
- [ ] 流式解析只做展示，最终决策在完整响应后
- [ ] 记录合法率、语义正确率、TTFT 增量、单位成功成本
- [ ] 大 schema 拆小，避免 `anyOf` 状态爆炸

约束解码是「把概率问题变成工程问题」的典型手段：它不能让你不写校验，但能让你的校验从「天天救火」变成「兜底防线」。对 Java 团队来说，这项能力的价值不在于理解自动机，而在于**知道边界在哪、把兜底写对**。
