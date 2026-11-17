---
title: 【系统设计】AI 客服系统架构设计：意图识别、RAG 知识库、人机协同与质检闭环
date: 2026-11-17 08:40:00
tags:
  - Java
  - AI
  - 系统设计
  - RAG
  - Agent
categories:
  - 系统设计
author: 东哥
---

# 【系统设计】AI 客服系统架构设计

## 前言

AI 客服是过去两年落地最密集的场景，也是最容易"Demo 惊艳、上线翻车"的场景。

Demo 阶段：接一个大模型，把 FAQ 塞进 prompt，问什么答什么，客户很满意。
上线三个月：答错政策导致赔付、A 客户看到 B 客户的订单、活动规则更新了但机器人还在说旧规则、用户骂了两句机器人还在机械回复"请问还有什么可以帮您"。

问题不在模型，而在**系统**。客服是一个"高准确率要求 + 强业务耦合 + 有法律后果"的场景，它需要的不是"会聊天的模型"，而是一套包含意图路由、知识检索、工具调用、人机协同、输出治理和评测闭环的工程体系。

本文给出一套可落地的架构设计，重点讲清楚每个模块的边界、失败模式和 Java 侧的实现要点。

---

## 一、需求与约束

### 1.1 功能域

| 域 | 典型问题 | 处理方式 |
|---|---|---|
| 售前咨询 | 产品参数、价格、优惠 | RAG 知识库 |
| 订单/物流 | 我的订单到哪了 | 工具调用（业务 API） |
| 售后 | 退款、换货、投诉 | 工作流 + 人工审批 |
| 政策解释 | 保修、发票、会员规则 | RAG + 版本化 |
| 闲聊/情绪 | 抱怨、辱骂 | 情绪识别 + 转人工 |

### 1.2 非功能指标

| 指标 | 目标 | 说明 |
|---|---|---|
| 首响延迟 | < 2s（流式首 token < 800ms） | 超过 3s 用户会重复提问 |
| 答案准确率 | > 92%（黄金集） | 低于 90% 不建议全量 |
| 幻觉率 | < 1% | 涉及金额/时效必须 0 容忍 |
| 一次解决率 | > 70% | 衡量"是否真的解决问题" |
| 转人工率 | 15%~30% | 太低说明硬撑，太高说明没用 |
| 单会话成本 | < 0.05 元 | 决定能否规模化 |

### 1.3 三种形态对比

| 形态 | 说明 | 适用阶段 |
|---|---|---|
| 坐席辅助 | AI 生成建议，人发送 | 冷启动，风险最低 |
| 人机协同 | AI 先答，不确定转人工 | 主力形态 |
| 全自动 | AI 独立完成闭环 | 仅限低风险标准化场景 |

**强烈建议按"辅助 → 协同 → 全自动"的顺序推进**，每一步都要有数据支撑再放开。

---

## 二、整体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ 接入层：App / Web / 小程序 / 企微 / 电话(ASR) / 邮件          │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 会话网关：鉴权、限流、会话路由、上下文加载、幂等              │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 理解层：意图识别 → 槽位抽取 → 情绪/风险识别 → 路由决策        │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 编排层：Agent / 工作流（RAG 问答、工具调用、多轮任务）        │
└───────┬───────────────────┬───────────────────┬──────────────┘
        ▼                   ▼                   ▼
   RAG 知识库          业务工具层          人工坐席系统
   (向量+关键词)     (订单/物流/退款)      (工单/会话/质检)
        │                   │                   │
        └───────────────────┴───────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 输出层：合规校验 → 引用校验 → 脱敏 → 兜底话术 → 流式输出     │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 数据层：会话日志、知识版本、标注数据、指标、审计              │
└──────────────────────────────────────────────────────────────┘
```

设计要点：

1. **理解层和编排层分离**：意图识别用便宜的小模型/规则，编排才用大模型，成本能降 60% 以上；
2. **RAG 和工具是并列能力**，不是二选一：知识类问题走 RAG，状态类问题走工具；
3. **输出层是最后一道闸门**，所有回答（包括工具返回的结果）都要过一遍。

---

## 三、意图识别与路由

### 3.1 三级路由

```java
public RouteDecision route(Query query, SessionContext ctx) {
    // L1：规则/关键词，覆盖高频明确意图，延迟 < 1ms
    Optional<Intent> rule = ruleMatcher.match(query.text());
    if (rule.isPresent() && rule.get().confidence() > 0.95) {
        return RouteDecision.of(rule.get());
    }

    // L2：小模型分类（BERT/DistilBERT 蒸馏），延迟 10~30ms
    IntentPrediction pred = smallModel.predict(query.text(), ctx.recentTurns());
    if (pred.confidence() > 0.80) {
        return RouteDecision.of(pred.intent());
    }

    // L3：大模型兜底 + 澄清，延迟 300~800ms
    return RouteDecision.clarify(pred.topK(2));
}
```

### 3.2 三种方案对比

| 方案 | 延迟 | 准确率 | 成本 | 适用 |
|---|---|---|---|---|
| 规则/关键词 | < 1ms | 高（限定场景） | ≈0 | 高频明确意图 |
| 小模型分类 | 10~30ms | 85%~92% | 低 | 主力 |
| LLM 分类 | 300~800ms | 92%~96% | 高 | 长尾/兜底 |

### 3.3 拒识比误判更重要

客服场景的错误代价不对称：**答错 > 不答**。所以必须有拒识机制：

```java
if (pred.confidence() < 0.55 || pred.margin() < 0.15) {
    return RouteDecision.handoff("意图不明确，转人工");
}
```

`margin` 是 Top1 与 Top2 的差值。差值小说明模型"在两个意图之间犹豫"，这时候追问一句"您是想咨询退款进度，还是想申请退款？"比强行猜一个要好得多。

### 3.4 槽位抽取

多轮任务必须维护槽位：

```java
public record SlotState(
        String intent,
        Map<String, Object> filled,     // orderId, reason, amount...
        Set<String> missing
) {}
```

缺槽位时不要一次性问五个问题，按重要性逐个追问，每轮只问一个。

---

## 四、RAG 知识库

### 4.1 知识来源与分块策略

| 来源 | 结构 | 分块策略 |
|---|---|---|
| FAQ | 一问一答 | 整条作为一个 chunk，不切分 |
| 产品文档 | 标题层级 | 按二级标题切，保留标题路径 |
| 政策条款 | 条款编号 | 按条款切，保留生效日期 |
| 历史工单 | 问题+解决方案 | 一问一答配对，附人工标注质量分 |

**FAQ 千万不要按固定长度切**。一条"退款多久到账"的答案被切成两半，检索到前半段就会答出"退款需要 1-3 个工作日"，丢掉"原路退回"的关键信息。

### 4.2 元数据设计

```java
public record KnowledgeChunk(
        String chunkId,
        String docId,
        String version,
        String tenantId,          // 多租户隔离
        String productLine,
        String category,
        Instant effectiveFrom,    // 生效时间
        Instant effectiveTo,
        DataClass dataClass,
        String content,
        float[] embedding
) {}
```

`effectiveFrom/effectiveTo` 是客服场景的刚需。活动政策每月都变，如果知识库不做版本化，模型会把去年的规则答给今年的用户。

### 4.3 检索策略

```java
public List<KnowledgeChunk> retrieve(Query query, SessionContext ctx) {
    // 1. 混合检索：向量 + BM25
    List<ScoredChunk> vectorHits = vectorStore.search(query.embedding(), 20, filter(ctx));
    List<ScoredChunk> keywordHits = keywordIndex.search(query.text(), 20, filter(ctx));

    // 2. RRF 融合
    List<ScoredChunk> fused = rrfFuse(vectorHits, keywordHits, 60);

    // 3. 重排（可选，延迟 +80ms，准确率 +8%）
    List<ScoredChunk> reranked = reranker.rerank(query.text(), fused, 5);

    // 4. 时效过滤：只保留当前生效的版本
    return reranked.stream()
            .filter(c -> c.isEffectiveAt(Instant.now()))
            .toList();
}
```

混合检索是必须的：向量检索对"同义表达"友好，但对**订单号、产品型号、专有名词**很差；BM25 正好互补。

### 4.4 引用与溯源

每条回答都要能追溯到 chunk：

```json
{
  "answer": "退款将在 1-3 个工作日原路退回。",
  "citations": [
    {"docId": "policy-refund-2026", "chunkId": "c-12", "version": "v3"}
  ]
}
```

这不只是"显得专业"，而是**出问题时的唯一证据链**。没有引用的回答，在客诉复盘时无法判断是知识错了还是模型错了。

---

## 五、工具调用：连接业务系统

### 5.1 工具清单

| 工具 | 类型 | 权限 | 风险 |
|---|---|---|---|
| `order.query.detail` | 读 | order:read | 低 |
| `logistics.query.track` | 读 | logistics:read | 低 |
| `refund.query.status` | 读 | refund:read | 低 |
| `refund.apply.create` | 写 | refund:write | **高** |
| `address.update` | 写 | user:write | **高** |

### 5.2 写操作必须有人工闸门

```java
public ToolResult invokeWriteTool(ToolCall call, SessionContext ctx) {
    // 1. 幂等键：同一会话同一操作只执行一次
    String idempotencyKey = ctx.sessionId() + ":" + call.toolId() + ":" + call.argsHash();
    if (idempotencyRepo.exists(idempotencyKey)) {
        return idempotencyRepo.get(idempotencyKey);
    }

    // 2. 金额/影响面阈值
    BigDecimal amount = call.argAsDecimal("amount");
    if (amount != null && amount.compareTo(new BigDecimal("500")) > 0) {
        return ToolResult.requireApproval("金额超过 500 元，需人工审核");
    }

    // 3. 二次确认：让用户明确说"确认"
    if (!ctx.hasExplicitConfirmation(call.toolId())) {
        return ToolResult.requireConfirmation("即将为您申请退款 199 元，确认吗？");
    }

    // 4. 执行 + 审计
    ToolResult result = toolExecutor.execute(call);
    audit.log(ctx, call, result);
    idempotencyRepo.save(idempotencyKey, result);
    return result;
}
```

三条硬规则：**幂等键必须有、金额阈值必须设、二次确认不能省**。

### 5.3 权限隔离

工具必须用**服务身份**调用后端，而不是用户的 token。否则一旦模型被诱导调用 `refund.apply.create`，就会以用户身份真实退款。

```java
// 错误做法：直接把用户 token 透传给业务系统
headers.set("Authorization", "Bearer " + userToken);

// 正确做法：服务身份 + 用户上下文显式传递 + 后端二次校验
headers.set("Authorization", "Bearer " + serviceToken);
headers.set("X-Acting-User", userId);
headers.set("X-Acting-Session", sessionId);
```

---

## 六、人机协同

### 6.1 转人工触发条件

```java
public boolean shouldHandoff(SessionContext ctx, AgentResponse resp) {
    return resp.confidence() < 0.6
        || ctx.sentiment() == Sentiment.ANGRY
        || ctx.containsSensitiveWords()
        || ctx.consecutiveUnresolved() >= 2
        || ctx.userRequestedHuman()
        || resp.toolFailed()
        || ctx.turnCount() > 8;          // 多轮未解决，及时止损
}
```

### 6.2 交接包

转人工不是"把聊天记录甩过去"，而是要生成结构化交接包：

```java
public record HandoffPackage(
        String sessionId,
        String summary,                 // LLM 生成的一句话摘要
        String intent,
        Map<String, Object> slots,      // 已确认的订单号、金额、诉求
        List<String> attemptedActions,  // 已尝试过的操作
        Sentiment sentiment,
        String suggestedReply,          // 建议话术
        List<Citation> citations
) {}
```

坐席看到这 8 个字段，5 秒内就能接管；只给一堆聊天记录，坐席要重新读 3 分钟。

### 6.3 三种协同模式

| 模式 | AI 角色 | 人工角色 | 适用 |
|---|---|---|---|
| 坐席辅助 | 生成建议、检索知识 | 审核并发送 | 冷启动、高风险 |
| 人机协同 | 先答，不确定转人工 | 接管复杂会话 | 主力 |
| 全自动 | 独立闭环 | 仅处理投诉 | 标准化低风险 |

---

## 七、输出治理：最后一道闸门

```java
public Output validate(String answer, List<Citation> citations, SessionContext ctx) {
    // 1. 敏感词/违规话术
    if (sensitiveFilter.hit(answer)) {
        return Output.fallback("抱歉，这个问题我帮您转接人工客服。");
    }

    // 2. 承诺类话术检测（赔款、时效、绝对化用语）
    if (commitmentDetector.hit(answer)) {
        return Output.fallback("具体赔付方案以人工客服确认为准。");
    }

    // 3. 引用校验：答案中的关键事实必须能在 citations 中找到
    if (!citationChecker.support(answer, citations)) {
        return Output.fallback("我暂时没有找到准确的政策依据，为您转接人工。");
    }

    // 4. 脱敏：手机号、地址、身份证
    String masked = piiMasker.mask(answer);
    return Output.ok(masked, citations);
}
```

### 7.1 必须拦截的三类话术

| 类型 | 例子 | 原因 |
|---|---|---|
| 金额承诺 | "我们赔您 500 元" | 无权限，且构成要约 |
| 时效承诺 | "明天一定到" | 不可控 |
| 绝对化 | "绝对不会出问题" | 合规风险 |

### 7.2 兜底不是"道歉"

兜底话术要满足三个条件：**承认没解决、给出下一步、不承诺**。

```text
❌ "抱歉，我没听懂。"（用户更生气）
✅ "这个问题涉及您的账户具体情况，我为您转接人工客服，预计等待 30 秒。"
```

---

## 八、评测与运营闭环

### 8.1 离线评测

| 指标 | 定义 | 目标 |
|---|---|---|
| 意图准确率 | Top1 命中 / 总数 | > 92% |
| 检索召回率 | 正确 chunk 在 Top5 中 | > 90% |
| 答案准确率 | 人工判定正确 / 总数 | > 92% |
| 幻觉率 | 无依据的事实陈述 / 总数 | < 1% |
| 拒识准确率 | 该拒识的拒识了 | > 85% |

黄金集建议 500~1000 条，覆盖：高频问题 60%、长尾 25%、对抗/诱导 15%。每次知识库或 prompt 变更都要跑全量回归。

### 8.2 在线指标

```text
一次解决率 = 未转人工且未二次进线的会话 / 总会话
转人工率   = 转人工会话 / 总会话
满意度     = 好评数 / 评价总数
平均轮次   = 总轮次 / 总会话
单会话成本 = 总 token 成本 / 总会话
```

### 8.3 标注回流

```java
@Scheduled(cron = "0 0 3 * * ?")
public void buildTrainingSet() {
    // 1. 抽检：低置信 + 用户差评 + 转人工 的会话优先
    List<Session> candidates = sessionRepo.findForReview(
            Instant.now().minus(1, ChronoUnit.DAYS), 200);

    // 2. 人工标注后入库
    // 3. 每周增量微调小模型 / 更新黄金集
}
```

**没有标注回流的 AI 客服，三个月后一定会退化**：知识在变、用户在变、模型没变。

---

## 九、成本与容量

### 9.1 模型分级

| 环节 | 模型 | 单次成本占比 |
|---|---|---|
| 意图识别 | 小模型 / 规则 | 5% |
| 检索 | Embedding（短文本） | 5% |
| 生成 | 大模型 | 80% |
| 审核 | 小模型 | 10% |

### 9.2 缓存策略

- **精确缓存**：FAQ 标准问法，命中率 25%~35%，直接返回；
- **语义缓存**：相似度 > 0.95 复用，命中率 10%~15%，需谨慎（容易答非所问）；
- **工具结果缓存**：订单状态缓存 30s，物流缓存 5min。

### 9.3 容量算例

```text
日会话 10 万，平均 4 轮，每轮输入 2500 token、输出 200 token
日 token = 10万 × 4 × 2700 ≈ 10.8 亿
按 ¥2/百万 token 计 ≈ ¥2160/天 ≈ ¥6.5 万/月
```

引入意图分级（60% 走小模型）+ 缓存（30% 命中）后，成本可降到 1/4 左右。

---

## 十、踩坑清单

1. **知识库脏数据**：三年前的活动规则没下线，模型答得理直气壮。必须有 `effectiveTo`。
2. **权限越界**：A 用户问"我的订单"，工具用服务身份查了全表，返回了 B 的订单。必须在工具层强制 `userId` 过滤。
3. **政策更新不及时**：知识库更新了，但向量索引没重建，检索到的还是旧 chunk。
4. **全自动一步到位**：没有灰度、没有人工兜底，第一天就出赔付事故。
5. **只优化模型不优化知识**：90% 的错答是知识缺失或过期，不是模型不行。
6. **兜底话术机械**：用户骂人时回"请问还有什么可以帮您"，直接把客诉升级成舆情。
7. **没有引用**：出问题无法定责，也无法定位是检索错还是生成错。
8. **忽略电话渠道**：ASR 识别错误会放大所有下游问题，电话场景要单独评测。

---

## 十一、面试追问

**Q1：AI 客服和普通 RAG 问答有什么区别？**

三点：① 有业务动作（工具调用），不只是"回答"；② 有强合规约束（金额、时效、隐私）；③ 有明确的人机边界（什么时候必须转人工）。所以它更像"带风控的工作流系统"，而不是"聊天机器人"。

**Q2：怎么降低幻觉率？**

四层：知识层（高质量、时效性、引用）、检索层（混合检索 + 重排，保证召回）、生成层（强制基于引用回答、不确定就拒答）、输出层（引用校验、承诺检测、兜底）。单靠 prompt 说"不要编造"是最弱的一层。

**Q3：转人工率越低越好吗？**

不是。转人工率过低往往意味着"AI 在硬撑"，一次解决率反而下降，客诉上升。健康区间通常是 15%~30%，要结合一次解决率和满意度一起看。

**Q4：多租户下怎么保证知识隔离？**

三道：① 向量库按 `tenantId` 做 metadata filter（必须下推到检索层，不能后过滤）；② 工具调用强制带租户上下文；③ 缓存 key 必须包含租户维度。任何一层漏了都会串数据。

**Q5：怎么评估一个客服 AI 项目是否成功？**

看业务指标而不是模型指标：一次解决率、转人工率、满意度、单会话成本、客诉率。模型准确率 95% 但一次解决率只有 40%，说明"答得对但没解决问题"，项目依然是失败的。

---

## 总结

AI 客服的难点从来不是"让模型会说话"，而是让它在**该答的时候答对、不该答的时候闭嘴、该转人的时候果断转**。

一套可落地的架构包含六层：

1. **接入与会话网关**：统一入口、上下文、幂等；
2. **理解层**：三级意图路由 + 拒识 + 槽位；
3. **编排层**：RAG 与工具并列，按问题类型分流；
4. **人机协同**：明确触发条件 + 结构化交接包；
5. **输出治理**：合规、引用、脱敏、兜底四道闸；
6. **评测闭环**：离线黄金集 + 在线业务指标 + 标注回流。

把这条链路跑通，模型只是其中的一个零件；把这条链路跑不通，换再强的模型也救不了。
