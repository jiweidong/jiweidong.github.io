---
title: 【AI 体系】大模型幻觉治理与 Grounding 深度解析：引用强制、NLI 校验与弃答策略
date: 2026-11-11 08:20:00
tags:
  - AI
  - 幻觉治理
  - RAG
  - 评测
categories:
  - AI 体系
author: 东哥
---

# 【AI 体系】大模型幻觉治理与 Grounding 深度解析：引用强制、NLI 校验与弃答策略

## 前言

把 RAG 系统上线之后，产品经理最常问的一句话是："它说的对不对？" 而这恰恰是最难回答的问题。模型不会告诉你"我在编"，它用同样自信的语气输出正确和错误的内容。

幻觉（Hallucination）常被当成"模型能力问题"——等下一代模型就好了。但在工程视角，它更像一个**系统设计问题**：检索没给到证据、上下文组织混乱、Prompt 没有约束、输出没有校验、没有"不知道"的出口。这五个环节任一缺失，幻觉率就会显著上升，而它们全都在你的控制范围内。

本文把幻觉拆成可度量的类别，给出"输入—生成—输出"三层治理框架，并用 Java 落地一个可上线的 `GroundingVerifier`（引用存在性校验 + 逐句 NLI + 数值交叉校验 + 弃答决策），最后讲清楚怎么量化幻觉率、怎么校准弃答阈值。

---

## 一、幻觉的六种类型（先分类，才能度量）

| 类型 | 定义 | 例子 | 主要治理手段 |
|---|---|---|---|
| **事实性幻觉** | 与客观事实冲突 | "公司的 CEO 是张三"（实际是李四） | 检索 + 引用强制 |
| **忠实性幻觉** | 与给定上下文不一致 | 上下文说"增长 12%"，答"增长 21%" | 逐句 NLI 校验 |
| **引用幻觉** | 引用了不存在的来源/编号 | 引用 `[S7]`，但候选只有 5 条 | 引用 allowlist 校验 |
| **指令性幻觉** | 不遵守格式/范围约束 | 要求 3 条，输出 7 条；要求中文，输出英文 | 结构化输出 + 规则校验 |
| **时间性幻觉** | 用过期知识回答时效问题 | "最新版本是 2.1"（现在已是 4.0） | 时间元数据 + 知识截止声明 |
| **数值/单位幻觉** | 数字、单位、比例错误 | "3.2 亿"答成 "32 亿" | 数值抽取交叉比对 |

为什么要分类型？因为**度量方式不同**。事实性幻觉需要外部知识库比对，忠实性幻觉只需要上下文（这也是 RAG 场景最该盯的），引用幻觉纯规则就能查。混在一起谈"幻觉率 5%"没有意义，必须先定义分母。

---

## 二、三层治理框架

```
┌──────────────────── 输入层 ────────────────────┐
│ 检索质量（召回率/精度） · 上下文组织 · 证据覆盖度  │
│ 冲突检测（多源矛盾） · 时效标注 · 权限过滤        │
└───────────────────────┬────────────────────────┘
                        ▼
┌──────────────────── 生成层 ────────────────────┐
│ 角色约束（只依据材料） · 引用强制（[S1] 编号）    │
│ 不确定性表达（"材料未提及"） · 结构化输出        │
│ 温度调低 / 拒绝采样 / 自我检查                   │
└───────────────────────┬────────────────────────┘
                        ▼
┌──────────────────── 输出层 ────────────────────┐
│ 引用 allowlist 校验 · 逐句 NLI 蕴含判定         │
│ 数值/单位交叉校验 · 实体白名单 · 弃答决策        │
└────────────────────────────────────────────────┘
```

### 2.1 输入层：没有证据就不要问

最有效的抗幻觉手段不是 Prompt，而是**检索**。上下文里没有正确证据时，任何模型都只能编。

- **证据覆盖度**：把用户问题拆成若干"子断言"（sub-claim），检查每个子断言在召回块里是否有支撑。覆盖率 < 60% 时，直接走"信息不足"路径，而不是让模型硬答。
- **冲突检测**：多条上下文互相矛盾时（不同版本的制度、不同日期的价格），要么按时间取最新，要么显式提示冲突，**绝不能让模型"融合"出一个中间答案**。
- **时效标注**：每个块带 `effectiveDate`，Prompt 里明确"今天是 2026-11-11"，并要求"若材料早于问题所涉时间，需说明"。

### 2.2 生成层：把"不许编"写成可执行的约束

一段经过生产验证的约束模板：

```text
你是企业知识库助手。严格遵守：
1. 只能使用 <context> 中标注编号的材料回答；不得使用任何外部知识。
2. 每个事实性陈述后必须附引用编号，格式 [S1]；一句话最多引 2 个来源。
3. 若材料不足以回答，直接输出："根据现有资料无法确定……"，并说明缺少什么信息。
4. 不得推测、不得补全、不得把不同材料的数字合并计算，除非明确说明计算过程。
5. 涉及金额、比例、日期时，原样引用材料中的数值与单位。
6. 输出为 JSON：{"answer": "...", "citations": ["S1","S3"], "confidence": "high|medium|low", "missing": "..."}
```

注意第 6 条：**让模型自评置信度并结构化输出**，是后续校验的输入。虽然模型自评不可全信，但它与"弃答策略"结合后能显著降低严重错误率。

### 2.3 输出层：三道机器校验

这是本文的重点，也是 Java 工程能发挥的地方。

---

## 三、GroundingVerifier：可上线的 Java 校验链

校验链设计原则：**便宜的先跑，贵的后跑；任何一道不通过就走降级路径，不要"尽力修复"**。

```
answer + citations + contexts
   │
   ├─ 1. 引用 allowlist 校验（规则，<1ms）
   ├─ 2. 数值/单位交叉校验（正则+比对，~1ms）
   ├─ 3. 逐句 NLI 蕴含判定（小模型，10~100ms，可并行）
   └─ 4. 决策：PASS / REPAIR / ABSTAIN
```

### 3.1 引用存在性校验

```java
import java.util.*;
import java.util.regex.*;

public record Citation(String id, String text) {}

public record VerificationResult(Decision decision, List<String> issues, double groundedness) {
    public enum Decision { PASS, REPAIR, ABSTAIN }
}

public class CitationChecker {

    private static final Pattern CITE = Pattern.compile("\\[(S\\d{1,2})]");

    /** 引用编号必须在候选集合里，且被引用块必须真的被用于支撑 */
    public List<String> check(String answer, Map<String, Citation> candidates) {
        List<String> issues = new ArrayList<>();
        Set<String> cited = new LinkedHashSet<>();
        Matcher m = CITE.matcher(answer);
        while (m.find()) cited.add(m.group(1));

        if (cited.isEmpty() && !answer.contains("无法确定")) {
            issues.add("NO_CITATION: 有事实性陈述但无引用");
        }
        for (String id : cited) {
            if (!candidates.containsKey(id)) {
                issues.add("DANGLING_CITATION: " + id + " 不在候选集");
            }
        }
        // 引用块是否为空（空块被引用 = 造假）
        for (String id : cited) {
            Citation c = candidates.get(id);
            if (c != null && (c.text() == null || c.text().isBlank())) {
                issues.add("EMPTY_SOURCE: " + id + " 内容为空");
            }
        }
        return issues;
    }
}
```

### 3.2 数值与单位交叉校验

数值幻觉是最容易被机器抓住、也最容易被用户发现的类型：

```java
import java.math.BigDecimal;
import java.util.*;
import java.util.regex.*;

public class NumericChecker {

    // 匹配 3.2亿 / 12% / 1,234.5 万元 / 2024年
    private static final Pattern NUM = Pattern.compile(
            "(\\d[\\d,]*(?:\\.\\d+)?)\\s*(%|％|亿|万|千|元|万元|亿元|人|台|天|个月|年)?");

    public List<String> check(String answer, List<Citation> contexts) {
        List<String> issues = new ArrayList<>();
        String corpus = String.join("\n", contexts.stream().map(Citation::text).toList());

        Matcher m = NUM.matcher(answer);
        while (m.find()) {
            String raw = m.group(1).replace(",", "");
            String unit = m.group(2) == null ? "" : m.group(2);
            BigDecimal value = new BigDecimal(raw);

            // 在上下文中查找同值（允许单位不同但数值等价的情况交由人工规则）
            boolean found = containsNumber(corpus, value);
            if (!found) {
                issues.add("NUM_NOT_IN_CONTEXT: " + raw + unit);
            }
        }
        return issues;
    }

    private boolean containsNumber(String corpus, BigDecimal v) {
        Matcher m = NUM.matcher(corpus);
        while (m.find()) {
            try {
                if (new BigDecimal(m.group(1).replace(",", "")).compareTo(v) == 0) return true;
            } catch (NumberFormatException ignored) { }
        }
        return false;
    }
}
```

> 注意：数值校验的误报率不低（模型可能做了合理的加法，比如"合计 1.2 亿"来自 0.7 + 0.5）。所以它的定位是**标记可疑项**，不是直接拒答；把 `NUM_NOT_IN_CONTEXT` 计入风险分，与 NLI 结果联合决策。

### 3.3 逐句 NLI 蕴含判定

把答案切成句子，对每个句子找"最相关的上下文块"，判定 `entailment / neutral / contradiction`：

```java
import java.util.*;
import java.util.concurrent.*;

public class SentenceGrounder {

    private final NliClient nli;              // 小型 cross-encoder（如 bge-reranker + NLI 头）
    private final ExecutorService pool;       // 虚拟线程池，IO 密集

    public SentenceGrounder(NliClient nli) {
        this.nli = nli;
        this.pool = Executors.newVirtualThreadPerTaskExecutor();
    }

    public record SentenceScore(String sentence, String label, double score, String bestSource) {}

    public List<SentenceScore> verify(String answer, List<Citation> contexts, long timeoutMs) {
        List<String> sentences = splitSentences(answer);
        List<Future<SentenceScore>> futures = new ArrayList<>();

        for (String s : sentences) {
            if (!isFactual(s)) continue;      // 跳过"总结如下"这类非事实句
            futures.add(pool.submit(() -> {
                String best = null;
                double bestScore = -1;
                String bestLabel = "neutral";

                for (Citation c : contexts) {
                    NliClient.Result r = nli.entail(s, c.text());
                    if (r.entailment() > bestScore) {
                        bestScore = r.entailment();
                        bestLabel = r.label();
                        best = c.id();
                    }
                }
                return new SentenceScore(s, bestLabel, bestScore, best);
            }));
        }

        List<SentenceScore> out = new ArrayList<>();
        long deadline = System.currentTimeMillis() + timeoutMs;
        for (Future<SentenceScore> f : futures) {
            try {
                long remain = Math.max(1, deadline - System.currentTimeMillis());
                out.add(f.get(remain, TimeUnit.MILLISECONDS));
            } catch (Exception e) {
                out.add(new SentenceScore("", "timeout", 0, null));  // 超时按未通过处理
            }
        }
        return out;
    }

    private static List<String> splitSentences(String text) {
        return Arrays.stream(text.split("(?<=[。！？.!?])\\s*"))
                .map(String::strip).filter(s -> !s.isEmpty()).toList();
    }

    private static boolean isFactual(String s) {
        return !s.matches("^(总结|综上|以下|首先|其次|最后)[:：]?.*") && s.length() > 6;
    }
}
```

判定聚合与决策：

```java
public VerificationResult decide(List<SentenceScore> scores, List<String> ruleIssues) {
    long total = Math.max(1, scores.size());
    long supported = scores.stream().filter(s -> "entailment".equals(s.label())).count();
    long contradicted = scores.stream().filter(s -> "contradiction".equals(s.label())).count();

    double groundedness = (double) supported / total;

    if (contradicted > 0) {
        return new VerificationResult(Decision.ABSTAIN,
                List.of("CONTRADICTION: " + contradicted + " 句与材料矛盾"), groundedness);
    }
    if (groundedness >= 0.85 && ruleIssues.isEmpty()) {
        return new VerificationResult(Decision.PASS, List.of(), groundedness);
    }
    if (groundedness >= 0.6) {
        return new VerificationResult(Decision.REPAIR,
                List.of("LOW_GROUNDEDNESS: " + String.format("%.2f", groundedness)), groundedness);
    }
    return new VerificationResult(Decision.ABSTAIN,
            List.of("INSUFFICIENT_EVIDENCE"), groundedness);
}
```

三个工程要点：

1. **用虚拟线程跑 NLI**：一句一流是典型 IO/推理密集场景，`newVirtualThreadPerTaskExecutor` 比固定线程池简洁且不阻塞。
2. **必须有超时**：校验链总预算建议不超过端到端延迟的 15%（如总 3s，校验 ≤ 450ms）。超时句子按"未通过"计，宁可降级也不要拖死主链路。
3. **NLI 模型要小而专**：用 300M~600M 的 cross-encoder 做句级蕴含足够，别用大模型逐句判断（成本与延迟都撑不住）。

### 3.4 REPAIR 怎么修

`REPAIR` 不是让模型重新生成整段（那样可能引入新幻觉），而是**删除无支撑句子 + 保留有引用的句子 + 追加不确定性说明**：

```
原文：A 产品 2024 年营收 3.2 亿[S1]，同比增长 40%（无引用），预计 2025 年翻倍（无引用）。
修复：A 产品 2024 年营收 3.2 亿[S1]。其余信息现有资料未提供。
```

这种"减法式修复"比"重新生成"更安全，也更容易解释。

---

## 四、弃答策略：给系统一个"不知道"的出口

一个不会说"不知道"的 RAG 系统，必然用编造来填补空白。弃答设计要回答三个问题：

### 4.1 什么时候弃答

| 信号 | 阈值（起始值） | 说明 |
|---|---|---|
| 检索最高分 | < 0.35（余弦） | 与知识库完全无关 |
| 证据覆盖度 | < 0.6 | 子断言多数无支撑 |
| 逐句 groundedness | < 0.6 | 答案大部分无依据 |
| 存在矛盾句 | ≥ 1 | 与材料直接冲突，必须弃答 |
| 引用悬空 | ≥ 1 | 引用不存在的来源 |

### 4.2 怎么弃答（三级而不是二值）

```
L1 直接回答：  groundedness ≥ 0.85 且无规则违规
L2 带保留回答：0.6 ≤ groundedness < 0.85 → 前置"根据现有资料，可能……"，并列出未覆盖部分
L3 弃答：      groundedness < 0.6 或存在矛盾 → "根据现有资料无法确定 X，建议补充 Y"
```

**L2 是最有价值的一档**：它把"不确定"显式化，用户知道该自己核实，而不是被自信的错误误导。

### 4.3 阈值怎么校准

不要拍脑袋。用黄金集画两条曲线：

1. 横轴阈值，纵轴**幻觉率**（人工标注的错误答案占比）——单调下降。
2. 横轴阈值，纵轴**误拒率**（本可正确回答却被拒）——单调上升。

取"幻觉率 ≤ 2% 前提下误拒率最小"的点。经验上业务可接受 3%~8% 的误拒，换取 10 倍量级的严重错误下降，是划算的。

---

## 五、评测：幻觉率到底怎么算

### 5.1 指标体系

| 指标 | 定义 | 采集方式 |
|---|---|---|
| Faithfulness | 有上下文支撑的断言数 / 总断言数 | NLI 自动 + 人工抽检 5% |
| Answer Correctness | 与标准答案语义一致 | LLM-as-Judge + 人工校准 |
| Citation Precision | 引用正确的比例 | 规则 + 人工 |
| Citation Recall | 应引用却未引用的比例 | 人工抽检 |
| Abstention Quality | 该拒的拒了、该答的答了 | 黄金集（含"应拒"样本） |
| Severe Error Rate | 会造成业务损失的错误率 | 人工标注，重点指标 |

**黄金集构造**（200~500 条）：

- 60% 常规问题（可从知识库回答）
- 20% 边界问题（部分可答，应走 L2）
- 15% 无答案问题（知识库确实没有，应弃答）
- 5% 对抗问题（诱导编造、越权、要求超出材料推理）

### 5.2 LLM-as-Judge 的校准

自动评测必须有校准，否则只是"用另一个模型的主观替代这个模型的主观"：

1. 抽样 100 条，人工标注。
2. 计算 judge 与人工的一致性（Cohen's κ），κ < 0.6 则调整 judge prompt 或换模型。
3. 定期（每月）复校，因为 judge 模型会升级。

### 5.3 线上度量

离线评测覆盖不了长尾。线上补两个信号：

- **用户反馈**：点赞/点踩 + "哪里不对"自由文本，按周聚类，形成"幻觉模式库"。
- **引用点击率**：用户点开引用块的比例；长期为 0 的引用段落，可能是"装饰性引用"（引了但没支撑）。

---

## 六、生产落地检查清单

| 环节 | 必做项 | 常见缺失 |
|---|---|---|
| 输入 | 证据覆盖度门禁、冲突检测、时效标注 | 只做 topK 检索，不看覆盖 |
| 生成 | 引用强制、结构化输出、低温度 | Prompt 里只有"不要编造"四个字 |
| 输出 | allowlist、NLI、数值校验、弃答 | 只靠人工抽检 |
| 延迟 | 校验预算 ≤ 15% 端到端 | NLI 串行跑，拖到 2s |
| 成本 | 小模型做校验、结果缓存 | 用 GPT-4 逐句判断 |
| 可观测 | groundedness 分布、弃答率、矛盾率 | 只看 QPS 和 token |
| 回归 | 黄金集进 CI，指标退化阻断发布 | 上线后才发现变差 |

---

## 七、面试常见追问

**Q1：RAG 能消除幻觉吗？**
不能。RAG 把"事实性幻觉"转化为"忠实性幻觉"——模型可能仍然不忠于给定材料。所以必须有输出层校验，RAG 只是把幻觉率从"不可控"降到"可度量、可治理"。

**Q2：为什么不用"让模型自我检查"作为主要手段？**
模型自检与生成共享同一套参数化知识，对同一错误往往"看不出错"。它的价值在于低成本过滤明显问题，不能作为唯一防线。工程上要外部证据（NLI/规则）与自检结合。

**Q3：Self-Consistency（多次采样投票）能降幻觉吗？**
对推理类任务有效（正确答案更稳定），对事实性幻觉效果有限——模型可能稳定地编同一个错。而且成本是 N 倍，只适合高价值低 QPS 场景。

**Q4：groundedness 高就说明答案对吗？**
不一定。groundedness 只衡量"是否忠于上下文"。如果检索到的上下文本身就是错的（知识库脏数据），答案会"高度 grounded 但事实错误"。所以要同时监控知识库质量与检索质量。

**Q5：为什么弃答阈值不能设得很高？**
误拒率会飙升，用户会觉得"这系统什么都不知道"，转而不用。弃答是权衡：把严重错误压到可接受水平，同时保留大多数可用回答。用黄金集画曲线取点，别拍脑袋。

**Q6：NLI 校验的延迟怎么控？**
三招：句级并行（虚拟线程）、小模型（300M 级 cross-encoder）、候选裁剪（只对最相关 3~5 个块做蕴含判定）。再加超时降级，宁可放过也不拖死。

---

## 八、小结

- 幻觉不是一个数，而是六类可分别度量的失败模式，先分类再谈治理。
- 三层治理：输入层保证"有证据"、生成层约束"只用证据"、输出层校验"真的用了证据"。
- Java 侧的核心资产是校验链：引用 allowlist（规则）→ 数值交叉（正则）→ 逐句 NLI（小模型并行）→ 三级决策（PASS/REPAIR/ABSTAIN）。
- 弃答是功能不是缺陷，三级输出（直答/保留/弃答）比二值判断更贴近真实业务。
- 阈值靠黄金集校准，指标要进 CI，线上靠反馈与引用点击率补长尾。
- RAG 把幻觉从"不可控"变成"可度量"，但真正把它压下去的，是输出层的工程校验。
