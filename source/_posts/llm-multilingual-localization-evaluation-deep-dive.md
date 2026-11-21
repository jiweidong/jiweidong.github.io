---
title: 【AI 工程化】LLM 应用的多语言与本地化评测：Token 膨胀、语言漂移与质量门禁
date: 2026-11-21 08:40:00
tags:
  - AI
  - Java
  - 评测
  - 国际化
  - LLM
categories:
  - AI 工程
author: 东哥
---

# 【AI 工程化】LLM 应用的多语言与本地化评测

## 前言

做中文 LLM 应用时，团队往往只测中文；一旦要支持英语、日语、阿拉伯语，就会同时撞上三类问题：

- **成本问题**：同一段内容，日语比英语多 60% 的 token，阿拉伯语可能多 2 倍。预算按英语做的，上线第一个月就超。
- **质量问题**：模型用中文问、用英文答；或者答了中文但里面混着英文术语；再或者数字格式、日期顺序、姓名顺序全错。
- **评测问题**：BLEU 在中文上几乎没意义，LLM-as-Judge 又有明显的英语偏好，最后只能靠人肉看，无法进 CI。

这三件事看起来分散，本质是同一个：**多语言不是"翻译一遍 UI"，而是要为每种语言单独建一套度量与门禁**。这篇文章讲怎么建。

## 一、先算账：Token 膨胀是硬约束

### 1.1 为什么同样的意思，token 数差好几倍

BPE 类分词器的词表以英语语料为主。非拉丁文字被切得更碎：

| 语言 | 相对英语的 token 膨胀（经验值） | 主要原因 |
|---|---|---|
| 英语 | 1.0× | 基线 |
| 中文 | 1.4 ~ 2.0× | 常用词多为 1~2 token，生僻字逐字切 |
| 日语 | 1.6 ~ 2.2× | 汉字 + 假名混排，假名切碎 |
| 韩语 | 1.5 ~ 2.0× | 谚文音节组合多 |
| 阿拉伯语 | 2.0 ~ 3.0× | 词根-词缀屈折，形态丰富 |
| 泰语 | 3.0 ~ 5.0× | 无空格分词，子词边界模糊 |
| 印地语 | 2.5 ~ 4.0× | 天城文，词表覆盖低 |

⚠️ 这些数字**只能用来做量级判断**。不同 tokenizer（`cl100k_base` / `o200k_base` / SentencePiece / 各家私有）差异巨大，新一代词表对 CJK 明显更友好。**上线前必须用自己实际用的模型实测**，不要抄别人的表。

### 1.2 Java 侧怎么测

```xml
<dependency>
  <groupId>com.knuddels</groupId>
  <artifactId>jtokkit</artifactId>
  <version>1.1.0</version>
</dependency>
```

```java
public record LanguageCost(String lang, int chars, int tokens, double ratioToEnglish) {}

public List<LanguageCost> measure(Map<String, String> samplesByLang) {
    Encoding enc = Encodings.newDefaultEncodingRegistry()
            .getEncodingForModel(ModelType.GPT_4O);   // o200k

    int enTokens = enc.countTokens(samplesByLang.get("en"));
    return samplesByLang.entrySet().stream()
            .map(e -> new LanguageCost(
                    e.getKey(),
                    e.getValue().codePointCount(0, e.getValue().length()),
                    enc.countTokens(e.getValue()),
                    (double) enc.countTokens(e.getValue()) / enTokens))
            .sorted(Comparator.comparingDouble(LanguageCost::ratioToEnglish).reversed())
            .toList();
}
```

三个细节：

1. **用 `codePointCount` 而不是 `length()`**。`String.length()` 返回 UTF-16 code unit 数，emoji 和部分生僻汉字占 2 个 unit，直接算会把字数高估。
2. **jtokkit 只覆盖 OpenAI 系词表**。用 Claude、Gemini、Qwen 时必须调用对应 tokenizer，或者直接用 API 返回的 `usage`。
3. **账本永远以 API `usage` 为准**，本地估算只用于"发请求前"的预算拦截。

### 1.3 成本放大不是线性的

token 膨胀只是第一层。更深的影响：

| 影响 | 机制 | 放大倍数（经验） |
|---|---|---|
| 输入 token | 同样的 prompt 翻译后更长 | 1.5~3× |
| 输出 token | 模型用目标语言回答通常更长（中文除外） | 1.2~2× |
| 上下文占用 | 同样内容的对话历史更早触顶 | 1.5~3× |
| 缓存命中率 | 多语言 prompt 变体破坏前缀缓存 | 命中率降 20%~60% |
| 重试率 | 低资源语言质量差 → 校验失败重试 | 1.1~1.5× |

最后一条最容易被忽略：**质量差会反向推高成本**。一个阿拉伯语请求重试两次，成本直接 ×3，而这在"按语言看 P95 成本"的报表里才会暴露。

## 二、评测集怎么建

### 2.1 不要用翻译代替原生语料

最常见的错误做法：拿中文评测集机翻成 8 种语言，然后跑评测。问题在于：

- 机翻会引入"翻译腔"，模型输出正常表达反而被判低分。
- 真实用户的语言习惯、缩写、混语（比如中日夹杂英文）完全没覆盖。
- 文化特定内容（节日、法规、支付方式）机翻后失真。

务实的分层：

| 层级 | 来源 | 占比 | 用途 |
|---|---|---|---|
| L1 平行语料 | 已有的人工翻译内容（产品文档、帮助中心） | 30% | 跨语言一致性对比 |
| L2 原生语料 | 各地客服工单、社区提问、真实用户 query | 50% | 真实分布 |
| L3 对抗语料 | 混语、错别字、方言、全半角混排、emoji | 20% | 鲁棒性 |

L2 是最值钱也最难拿的。没有 L2 的评测集，测出来的分数和线上表现几乎不相关。

### 2.2 评测矩阵必须显式

不要只报一个"多语言平均分"。至少四个维度交叉：

```text
语言 × 任务类型 × 输入长度 × 领域
```

```java
public record EvalCase(
        String id,
        String lang,            // zh-CN, en-US, ja-JP, ar-SA ...
        TaskType task,          // QA, SUMMARIZE, EXTRACT, TRANSLATE, TOOL_CALL
        LengthBucket length,    // SHORT(<200 tok), MEDIUM, LONG(>2k tok)
        String domain,          // billing, tech, legal
        String input,
        String reference,       // 可为空（开放式任务）
        Map<String, String> localeHints   // 期望的日期/货币/单位格式
) {}
```

**为什么一定要分任务类型**：同一个模型在"翻译"任务上日语可能很好，在"工具调用"上日语可能一塌糊涂（因为 function schema 是英文的）。平均分会把这种差异完全抹掉。

### 2.3 Locale 相关的"硬断言"

有些错误不需要模型判分，规则就能抓，而且必须抓：

| 检查项 | 例子 | 判定方式 |
|---|---|---|
| 语言漂移 | 问日语答英语 | 用 `lingua` / `whatlang` 检测输出语言 |
| 混语率 | 中文回答里夹 30% 英文单词 | 按 token 语言占比阈值 |
| 日期格式 | `2026/11/21` vs `21.11.2026` vs `11/21/2026` | 正则 + `DateTimeFormatter` 按 locale 校验 |
| 数字格式 | `1,234.56` vs `1.234,56` | `DecimalFormat` 按 locale 解析 |
| 货币符号 | `¥` 是日元还是人民币 | locale + 上下文校验 |
| 阿拉伯数字变体 | 阿拉伯语用 `٠١٢٣` 还是 `0123` | Unicode 属性检查 |
| RTL 标记 | 阿拉伯语/希伯来语缺 `\u200F` 方向标记 | 渲染前检查 |
| 单位 | 英里/公里、摄氏/华氏 | 按 locale 白名单 |
| 姓名顺序 | 姓在前 vs 名在前 | 结构化字段校验 |

```java
public void assertLocaleFormat(String lang, String output) {
    Locale locale = Locale.forLanguageTag(lang);
    // 日期
    Matcher m = DATE_PATTERN.matcher(output);
    while (m.find()) {
        String candidate = m.group();
        // 用目标 locale 的 formatter 严格解析，失败即判错
        DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)
                .withLocale(locale)
                .parse(candidate);   // 抛异常 → 记一条 locale violation
    }
    // 数字：目标 locale 的 DecimalFormat 能否原样解析
    DecimalFormat df = (DecimalFormat) NumberFormat.getInstance(locale);
    df.setParseBigDecimal(true);
    // ...
}
```

这些断言的价值：**它们能进 CI，而且不花钱**。把规则能抓的全抓掉，剩下的才交给 LLM 判分，评测成本能降一个数量级。

## 三、质量指标：BLEU 不够，LLM-as-Judge 有偏

### 3.1 传统指标的适用边界

| 指标 | 适用 | 不适用 |
|---|---|---|
| BLEU | 机器翻译（有参考译文） | 开放式生成、中文（分词敏感） |
| chrF / chrF++ | 形态丰富语言（土耳其语、芬兰语） | 语义等价但表达不同 |
| spBLEU | 多语言统一分词后的 BLEU | 仍依赖参考译文 |
| COMET / BLEURT | 神经指标，与人工相关性最好 | 需要模型推理，成本高，语言覆盖不均 |
| 精确匹配 / F1 | 抽取、分类、结构化输出 | 生成式回答 |
| 语义相似度（embedding） | 粗筛 | 细粒度质量、事实性 |

中文场景下 BLEU 的问题特别典型：分词不同、同义表达多，一个完全正确的回答 BLEU 可能只有 0.2。**用 BLEU 做中文质量门禁，等于用体温计量血压。**

### 3.2 LLM-as-Judge 的三种偏差

| 偏差 | 表现 | 缓解 |
|---|---|---|
| 英语偏好 | 同样质量，英文回答得分更高 | judge prompt 明确"忽略语言，只评内容"；用目标语言写评分标准 |
| 自我偏好 | 同家族模型给同家族输出更高分 | 用不同厂商模型做 judge；或双 judge 取一致性 |
| 长度偏好 | 长回答分更高 | 评分维度拆开（完整性/准确性/简洁性），并对长度做归一 |
| 位置偏好 | 成对比较时偏爱第一个 | 随机交换顺序，双向各评一次 |

**工程上最有效的三个手段**：

1. **成对比较（pairwise）优于绝对打分**。让 judge 说"A 和 B 哪个更好"比"给 1~10 分"稳定得多。
2. **强制给评分理由**，理由里必须引用原文片段。没有引用的分数直接丢弃。
3. **人工校准**：抽 100~200 条人工标注，算 judge 与人的 Cohen's kappa。**kappa < 0.6 就不要把 judge 分数当门禁**，只能当参考。

```java
public record JudgeResult(int score, String reason, List<String> citations) {}

public boolean isTrustworthy(JudgeResult r) {
    return r.reason() != null
        && r.reason().length() > 20
        && !r.citations().isEmpty();     // 没有引用 = 大概率在糊弄
}
```

### 3.3 三层门禁

```text
L1 规则断言（零成本，必须全过）
  └─ 语言一致、格式、禁用词、长度、结构化 schema
L2 指标阈值（低成本，按语言设不同阈值）
  └─ COMET / 语义相似度 / 关键词召回
L3 LLM Judge（高成本，只对 L1/L2 有争议的样本跑）
  └─ pairwise + 理由 + 引用
```

**按语言设不同阈值是关键**。低资源语言的绝对分数天然更低，如果全语言共用 0.8 的阈值，要么英语过松、要么泰语永远不达标。正确做法是给每种语言设一个"基线分 + 允许回退幅度"：

```java
record LangGate(String lang, double baseline, double maxRegression) {
    boolean pass(double score) { return score >= baseline - maxRegression; }
}
```

这样门禁回答的是"**这次改动有没有让这种语言变差**"，而不是"这种语言的绝对水平够不够"——后者是选型问题，前者才是回归问题。

## 四、Prompt 的多语言策略：三种方案对比

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| A. 全英文 prompt + "answer in {lang}" | system 用英文，只约束输出语言 | 维护成本低，指令遵循最好 | 输出可能夹英文术语；文化适配差 |
| B. 每种语言独立 prompt | 完整翻译 system + few-shot | 表达自然、文化贴合 | 维护 N 份，改动要同步 N 次 |
| C. 英文骨架 + 语言片段 | 结构英文，示例和术语表按语言注入 | 折中 | 复杂度高，需要模板引擎支持 |

实测经验：

- **指令遵循**：A > C > B。英文 system prompt 的约束力最强，"必须输出 JSON"这类硬约束尤其明显。
- **表达自然度**：B > C > A。日语敬语、阿拉伯语敬语体系，用英文 prompt 很难引导对。
- **一致性**：A 最好。B 的 N 份 prompt 很容易漂移。

务实结论：**硬约束用英文写，语气和文化适配用目标语言写**。也就是 C 方案，但把它简化成两段式：

```text
[SYSTEM - English, 固定]
You are a support assistant. Output MUST be valid JSON per schema.
Never invent order IDs. If unsure, set "confidence" < 0.5.

[STYLE - 目标语言, 可热更新]
下面的回答请使用{language}，语气{formality}，金额用{currency}，
日期格式为{datePattern}。禁止使用以下英文术语，改用：{glossary}
```

`STYLE` 段落可以放进配置中心，按语言热更新，不用发版。

### 4.1 语言漂移的根因

模型"答非所问语言"通常有三个原因：

1. **few-shot 示例是英文**：模型倾向于模仿示例的语言。示例必须和目标输出语言一致。
2. **工具返回英文**：检索到的文档是英文，模型会顺着英文答。需要在 prompt 里显式要求"翻译后再回答"。
3. **多轮历史混语**：用户第一轮中文、第三轮英文，模型会跟随最近一轮。需要显式的 `response_language` 状态，而不是靠推断。

```java
// 显式维护输出语言，不靠模型猜
String responseLanguage = session.languageOverride() != null
        ? session.languageOverride()
        : detectLanguage(lastUserMessage);   // 只在首轮检测
```

## 五、把评测接进 CI

```java
public final class MultilingualGate {

    private final Map<String, LangGate> gates;
    private final EvalDataset dataset;          // 按语言索引
    private final JudgeClient judge;            // 可替换/可 mock

    public GateReport run(Set<String> languages) throws Exception {
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            List<Future<LangReport>> futures = languages.stream()
                    .map(lang -> executor.submit(() -> evalOne(lang)))
                    .toList();

            List<LangReport> reports = new ArrayList<>();
            for (Future<LangReport> f : futures) reports.add(f.get());

            List<String> failures = reports.stream()
                    .filter(r -> !gates.get(r.lang()).pass(r.score()))
                    .map(r -> "%s: %.3f < %.3f".formatted(
                            r.lang(), r.score(), gates.get(r.lang()).baseline()
                                    - gates.get(r.lang()).maxRegression()))
                    .toList();

            return new GateReport(reports, failures);
        }
    }
}
```

三个工程要点：

1. **虚拟线程按语言并行**，一种语言一个任务，天然隔离。几十种语言也不怕。
2. **每种语言独立基线**，如上文所述。
3. **失败信息要能定位到 case**，不能只报"日语不达标"。输出 top-10 退化样本，附 diff。

CI 里的运行策略：

| 触发 | 范围 | 预算 |
|---|---|---|
| 每次 PR | L1 规则 + 抽样 20 条/语言 | < 2 分钟 |
| 每日定时 | 全量 L1 + L2 | 30 分钟 |
| 发版前 | 全量三层 + 人工抽检 50 条 | 2 小时 |

## 六、面试追问

**Q：为什么不能直接用翻译后的评测集？**

机翻会把源语言的表达习惯带进目标语言，模型输出正常的目标语言表达反而被判"不相似"。更严重的是它丢失了真实用户分布 —— 真实用户会用缩写、混语、错别字、方言，机翻语料一条都没有。

**Q：LLM-as-Judge 在多语言场景下最大的风险是什么？**

英语偏好 + 自我偏好叠加。同家族模型评自己的英文输出，分数会系统性偏高。缓解手段是跨厂商 judge + 成对比较 + 人工 kappa 校准，三者缺一不可。

**Q：token 膨胀对架构有什么影响？**

三方面：成本预算要按语言分档；上下文窗口在非英语下"缩水"，长文档 RAG 的切分策略要按语言调整；前缀缓存命中率下降，语义缓存的收益在多语言下会显著变低。极端情况下（泰语、印地语），同样的对话轮数会提前触顶，需要更激进的摘要压缩。

**Q：怎么判断"语言漂移"是模型问题还是 prompt 问题？**

做对照实验：固定 prompt，只换 few-shot 示例的语言。如果换成目标语言示例后漂移消失，是 prompt 问题；如果仍然漂移，再看工具返回的语言。90% 的漂移来自示例语言和工具输出，真正的模型能力问题很少。

## 七、落地清单

1. 上线前实测每种语言的 token 膨胀，别抄别人的表。
2. 字数统计用 `codePointCount`，不用 `length()`。
3. 评测集必须有原生语料（L2），占比不低于 50%。
4. 评测矩阵按 语言 × 任务 × 长度 × 领域 切分，别只看平均分。
5. 规则能抓的（语言、格式、数字、日期）全部做成硬断言，进 CI。
6. 每种语言独立基线 + 允许回退幅度，门禁判"是否变差"而不是"是否够好"。
7. LLM Judge 必须做 kappa 校准，低于 0.6 只作参考。
8. 硬约束用英文 prompt，语气文化用目标语言片段，两段式拆分。
9. few-shot 示例的语言必须与目标输出一致。
10. 显式维护 `response_language` 状态，不靠模型推断。

多语言不是一个"翻译"问题，是一个**度量**问题。你无法改进你无法度量的东西，而在多语言场景下，默认的度量方式（英语中心的 BLEU、单一平均分、无校准的 judge）几乎全是错的。把度量建对，剩下的优化才有方向。
