---
title: 【AI 转型】AI 应用开发项目作品集实战：6 个可写进简历的落地项目
date: 2026-10-26 08:20:00
tags:
  - AI
  - 转型
  - 作品集
  - Java
  - Spring AI
  - Agent
categories:
  - AI 转型
author: 东哥
---

# 【AI 转型】AI 应用开发项目作品集实战：6 个可写进简历的落地项目

## 前言

「我在学大模型，也调过 OpenAI API，但简历上不知道写什么。」

这是我最近被问得最多的一句话。问题不在技术，而在**没有可验证的产出**。招聘方看 AI 应用开发岗，不会因为你「了解 RAG 概念」给你发 offer，而是要看：

1. 你有没有跑通过一条完整的链路（数据 → 检索 → 生成 → 评测）。
2. 你有没有处理过真实工程问题（延迟、成本、权限、幻觉）。
3. 你能不能说清楚取舍（为什么用这个向量库、为什么这么切分）。

所以作品集的核心不是「多」，而是**每个项目都能讲出 3 个决策 + 2 个指标 + 1 个踩坑**。

这篇文章给 6 个项目，全部用 Java 技术栈落地（Spring AI / LangChain4j / WebFlux / pgvector / MCP），每个都给出目标、架构、难点、可量化指标和简历写法。按难度递增排列，建议至少做前 3 个。

## 一、招聘方到底在看什么

| 维度 | 具体看什么 | 作品集怎么体现 |
|---|---|---|
| 工程完整度 | 有没有从 0 到 1 跑通 | README + 架构图 + 可运行 demo |
| 技术深度 | 是否理解原理而非调包 | 关键决策的对比与取舍 |
| 问题解决 | 遇到坑怎么定位 | 踩坑记录 + 优化前后数据 |
| 效果意识 | 有没有评测 | 黄金集 + 指标 + 回归 |
| 成本意识 | Token/延迟/并发 | 成本账本 + 缓存命中率 |

**反面案例**（几乎拿不到面试）：
- 「基于 LangChain 实现的聊天机器人」——没有场景、没有数据、没有指标。
- 一个 Jupyter Notebook 截图——无法证明工程能力。
- GitHub 只有 `git init` 一次提交——看不出迭代过程。

**正面案例**：
> 企业知识库问答系统：Spring Boot 3 + Spring AI + PostgreSQL/pgvector，接入 1.2 万份制度文档；实现基于标题层级的语义切分与混合检索（BM25 + 向量 + RRF 融合），Recall@5 从 61% 提升到 87%；加入引用溯源与部门级权限过滤，P95 延迟 1.4s，单次问答成本 0.003 元。

这一句话里有技术栈、有数据量、有方法、有指标。这就是差距。

## 二、项目 1：企业知识库 RAG 问答（必做）

### 目标
把一批非结构化文档（制度、手册、合同）变成可问答的知识库，答案必须带出处。

### 架构

```
文档上传 → 解析(PDF/Word/HTML) → 清洗 → 结构化切分 → Embedding
                                                    ↓
用户提问 → Query 改写 → 混合检索(BM25 + 向量 + RRF) → 重排 → 上下文组装
                                                    ↓
                                        LLM 生成 + 引用标注 + 权限过滤
```

### 技术栈
Spring Boot 3.3 + Spring AI 1.0 + PostgreSQL 16 + pgvector + MinIO + Redis（缓存）+ Micrometer

### 三个必须讲清楚的决策

**决策 1：切分策略**
不要用固定 500 字符。按文档结构切：标题层级 → 段落 → 句子，保留父子关系（small-to-big：用小子块检索，返回父块给 LLM）。这是 Recall 提升的最大来源。

**决策 2：检索融合**
纯向量对「专有名词、编号、缩写」召回差；纯 BM25 对同义表达差。用 RRF（Reciprocal Rank Fusion）融合两路，`score = Σ 1/(k + rank)`，k 取 60。比调权重稳。

**决策 3：权限过滤**
权限必须在**检索阶段**过滤，不能生成后再过滤——否则模型已经「看到」了无权限内容，属于数据泄露。pgvector 里把 `dept_id` 作为过滤条件加进 SQL。

### 核心代码

```java
@Service
public class HybridRetriever {

    private final JdbcTemplate jdbc;
    private final EmbeddingModel embeddingModel;
    private final RerankClient rerankClient;

    public List<Chunk> retrieve(String query, UserCtx user, int topK) {
        float[] vec = embeddingModel.embed(query);
        // 向量召回 + 权限过滤（SQL 层）
        List<Chunk> vectorHits = jdbc.query("""
            SELECT id, doc_id, content, parent_id,
                   1 - (embedding <=> ?::vector) AS score
            FROM kb_chunk
            WHERE dept_id = ANY (?)
            ORDER BY embedding <=> ?::vector
            LIMIT ?
            """, mapper, toPgVector(vec), user.deptIds(), toPgVector(vec), topK * 3);

        // 关键词召回
        List<Chunk> bm25Hits = jdbc.query("""
            SELECT id, doc_id, content, parent_id,
                   ts_rank(to_tsvector('simple', content), plainto_tsquery('simple', ?)) AS score
            FROM kb_chunk
            WHERE dept_id = ANY (?) AND content ILIKE ?
            LIMIT ?
            """, mapper, query, user.deptIds(), "%" + query + "%", topK * 3);

        List<Chunk> fused = rrfFuse(vectorHits, bm25Hits);
        return rerankClient.rerank(query, fused, topK);   // 交叉编码器重排
    }

    private List<Chunk> rrfFuse(List<Chunk> a, List<Chunk> b) {
        Map<Long, Double> scores = new HashMap<>();
        for (int i = 0; i < a.size(); i++) scores.merge(a.get(i).id(), 1.0 / (60 + i + 1), Double::sum);
        for (int i = 0; i < b.size(); i++) scores.merge(b.get(i).id(), 1.0 / (60 + i + 1), Double::sum);
        return scores.entrySet().stream()
            .sorted(Map.Entry.<Long, Double>comparingByValue().reversed())
            .limit(20)
            .map(e -> chunkMap.get(e.getKey()))
            .toList();
    }
}
```

### 可量化指标
- Recall@5 / Recall@10（黄金集 200 条）
- 答案忠实度（人工或 LLM-as-judge 打分）
- P95 端到端延迟
- 单次问答 Token 成本
- 引用准确率（标注的来源是否真的支持结论）

### 简历写法
> **企业知识库智能问答系统**（Spring Boot 3 / Spring AI / pgvector）
> - 设计结构化切分 + small-to-big 检索策略，配合 BM25 与向量 RRF 融合及交叉编码器重排，黄金集 Recall@5 从 61% → 87%
> - 在检索 SQL 层实现部门级权限过滤，避免生成后过滤导致的越权泄露；引入引用溯源，答案可点回原文段落
> - 通过语义缓存（命中率 34%）与流式输出，P95 延迟 1.4s，单次问答成本下降 42%

## 三、项目 2：智能客服工单 Agent（必做）

### 目标
不是「聊天机器人」，而是能**查订单、改地址、发起退款**的 Agent，关键是权限与人工介入。

### 架构
ReAct 循环 + 工具集 + 状态机 + Human-in-the-loop

```
用户消息 → 意图识别 → Agent 规划 → 工具调用(查单/改址/退款)
                                      ↓ 高风险操作
                                   人工审批 → 执行 → 回复
```

### 三个必须讲清楚的决策

**决策 1：工具粒度**
不要做「一个大而全的 `handleOrder(action)`」，要做「`queryOrder(id)`、`updateAddress(id, addr)`、`applyRefund(id, reason)`」这种单一职责工具。参数 Schema 要严格，用 JSON Schema 约束枚举与格式。

**决策 2：高风险操作必须审批**
退款、改价、删除 → 生成「待审批动作」，写审批表，人工确认后由**独立执行器**落地，Agent 只负责提议。这是生产 Agent 的底线。

**决策 3：状态机兜底**
纯 ReAct 会跑飞（无限调工具、重复退款）。外层套状态机：`理解 → 查询 → 确认 → 执行 → 完成`，每步有最大步数与超时。

### 核心代码

```java
@Component
public class RefundTool implements Function<RefundRequest, RefundResult> {

    private final RefundService refundService;
    private final ApprovalService approvalService;

    @Override
    public RefundResult apply(RefundRequest req) {
        // 不直接退款，生成审批单
        var ticket = approvalService.create(ApprovalType.REFUND, req);
        return new RefundResult("PENDING_APPROVAL", ticket.id(),
            "退款申请已提交审批，单号 " + ticket.id());
    }
}
```

```java
@Bean
public ChatClient supportAgent(ChatClient.Builder builder, OrderTools orderTools, RefundTool refundTool) {
    return builder
        .defaultSystem("""
            你是电商客服助手。规则：
            1. 只处理订单相关问题，其他问题礼貌拒绝
            2. 退款必须走 RefundTool，不得承诺具体到账时间
            3. 信息不足时先追问，不要臆测
            4. 不要输出用户手机号、完整地址
            """)
        .defaultFunctions("queryOrder", "updateAddress", "applyRefund")
        .build();
}
```

### 可量化指标
- 工具调用成功率
- 任务完成率（端到端解决比例）
- 平均轮次（越少越好）
- 越权操作拦截率（应为 100%）
- 人工转接率

### 简历写法
> **客服工单智能体**（Spring AI Function Calling / 状态机 / 审批流）
> - 基于 ReAct + 状态机双层编排实现查单、改址、退款等 8 个工具调用，端到端任务完成率 76%，平均 2.3 轮解决
> - 对退款等高风险操作设计「提议-审批-执行」三段式，Agent 无直接写权限，越权操作 100% 拦截
> - 引入工具调用预算与超时熔断，异常会话从 12% 降至 2.1%

## 四、项目 3：代码评审 Copilot（差异化强）

### 目标
在 PR 提交时自动做代码审查，输出结构化意见（文件、行号、级别、建议）。

### 技术栈
Spring Boot + MCP Server（读取 Git/仓库）+ 静态分析（SpotBugs/Checkstyle）+ LLM 结构化输出

### 亮点设计
1. **不把整个仓库塞给模型**：先用 diff + 依赖图定位变更影响面，只送相关文件与调用方。
2. **规则先行，模型补充**：静态分析能查的（空指针、资源泄漏、SQL 注入）交给工具，模型只做「设计、可读性、边界条件」。
3. **结构化输出 + 校验**：JSON Schema 约束，解析失败重试并降级为纯文本评论。
4. **MCP 暴露工具**：`getDiff`、`getFileContext`、`getCallers`、`postComment`，让 Agent 自主决定读多少上下文。

### 可量化指标
- 有效意见占比（人工标注「有价值」的比例）
- 误报率
- 单 PR 评审耗时与 Token 成本
- 采纳率

### 简历写法
> **AI 代码评审助手**（Spring AI + MCP + SpotBugs）
> - 设计「静态规则兜底 + LLM 语义审查」双层架构，仅将 diff 影响面送入模型，单 PR Token 成本控制在 0.02 元
> - 通过 MCP 暴露 5 个仓库读取工具，Agent 按需拉取调用链上下文，有效意见率 68%，误报率 9%
> - 结构化输出采用 JSON Schema + 两次重试降级，解析失败率从 7% 降至 0.3%

## 五、项目 4：数据分析 Agent（NL2SQL）

### 目标
业务人员用自然语言问数，系统生成 SQL、执行、画图、给结论。

### 关键难点
1. **Schema 太大**：不能全塞 prompt。用「表/字段向量检索 + 业务指标语义层」只送相关表和字段。
2. **只读与限流**：独立只读账号、`LIMIT` 强制、查询超时、禁止 DDL/DML。
3. **结果正确性**：生成 SQL 后先 `EXPLAIN` 估算行数，再执行；结果为空时自动改写重试。
4. **多轮澄清**：「上个月」是自然月还是滚动 30 天？歧义必须问。

### 可量化指标
- SQL 执行成功率
- 结果正确率（对照人工 SQL）
- 平均澄清轮次
- 危险 SQL 拦截率

### 简历写法
> **自然语言数据分析 Agent**（Spring AI + ClickHouse + 语义层）
> - 构建指标语义层 + 表字段向量召回，将 Schema 上下文从 4 万 token 压缩到 1.2k，SQL 准确率 82%
> - 设计只读沙箱（只读账号 / 强制 LIMIT / 5s 超时 / AST 校验），危险语句 100% 拦截
> - 空结果自动改写与多轮澄清机制，端到端可用率从 54% 提升至 79%

## 六、项目 5：多模型 LLM 网关

### 目标
统一接入 OpenAI / Claude / 通义 / DeepSeek / 本地 Ollama，做路由、降级、配额、计费、可观测。

### 核心能力
| 能力 | 实现 |
|---|---|
| 协议适配 | 统一内部请求/响应模型，适配各家差异 |
| 路由 | 按模型能力、成本、租户等级路由 |
| 降级 | 主模型超时/5xx → 备模型；连续失败熔断 |
| 配额 | 租户级 RPM/TPM，Redis 令牌桶 |
| 计费 | 按 token 记账，落库 + 日报 |
| 可观测 | Trace ID 贯穿，记录首 token 延迟、总延迟、token 数 |

### 亮点
- **流式透传**：WebFlux + SSE，网关不缓冲，逐块转发。
- **熔断与半开**：Resilience4j，按模型维度隔离。
- **成本路由**：简单任务走小模型，复杂任务走大模型，用分类器或规则判定。

### 简历写法
> **多模型 LLM 网关**（Spring Cloud Gateway + WebFlux + Resilience4j）
> - 统一 5 家模型供应商协议，实现按能力/成本的动态路由与自动降级，整体可用性 99.95%
> - 基于 Redis 令牌桶实现租户级 RPM/TPM 配额，配合模型维度熔断，雪崩请求拦截率 100%
> - SSE 流式透传 + Trace 埋点，首 Token 延迟 P95 320ms，Token 账本支撑按租户成本分摊

## 七、项目 6：文档处理流水线（工程化最扎实）

### 目标
每天处理上万份 PDF/扫描件，做解析、分类、抽取、入库。这是最能体现「工程能力」的项目，因为全是脏活。

### 关键设计
1. **异步流水线**：上传 → 消息队列 → 解析 Worker → 抽取 Worker → 入库，每步可重试、可补偿。
2. **幂等**：以文件 SHA-256 为键，重复上传不重复处理。
3. **结构化抽取**：LLM + JSON Schema，字段缺失走规则兜底（正则/版式）。
4. **失败隔离**：单文件失败不影响批次，进死信队列 + 人工复核台。
5. **成本控制**：先规则抽取，置信度低的字段才调模型。

### 可量化指标
- 单文档处理成本
- 抽取字段准确率（分字段统计）
- 吞吐（份/分钟）
- 死信率

### 简历写法
> **智能文档处理流水线**（Spring Boot + RabbitMQ + Spring AI）
> - 设计「规则优先 + LLM 兜底」的字段抽取策略，单文档成本降低 71%，字段平均准确率 94%
> - 基于 SHA-256 幂等 + 死信队列 + 人工复核台，万份级批次处理死信率 0.4%
> - 流水线水平扩展，吞吐从 120 份/分钟提升至 900 份/分钟

## 八、项目结构模板（每个项目都该长这样）

```
project/
├── README.md                 # 一句话定位 + 架构图 + 快速启动 + 指标
├── docs/
│   ├── architecture.md       # 架构与关键决策（ADR）
│   ├── evaluation.md         # 评测方案与结果
│   └── pitfalls.md           # 踩坑记录
├── docker-compose.yml        # 一键起依赖（pgvector/redis/minio）
├── src/main/java/...
├── src/test/java/...         # 至少覆盖检索与工具调用
└── eval/
    ├── golden-set.jsonl      # 黄金集
    └── run_eval.py           # 评测脚本（或用 Java）
```

### README 模板

```markdown
# 项目名

一句话说明解决什么问题。

## 效果
| 指标 | 数值 |
|---|---|
| Recall@5 | 87% |
| P95 延迟 | 1.4s |
| 单次成本 | ¥0.003 |

## 架构
（图）

## 关键决策
1. 为什么用结构化切分而不是固定长度 —— ...
2. 为什么用 RRF 而不是加权 —— ...

## 快速开始
docker compose up -d && ./mvnw spring-boot:run

## 踩坑
- 问题 → 定位 → 解决 → 数据
```

**README 里的「效果」表格是最重要的**。招聘方 30 秒扫一眼，看到数字才会继续看代码。

## 九、指标怎么量化（没有真实流量怎么办）

自己造评测集，这是完全被认可的做法：

1. **黄金集**：从真实文档/问题里挑 100~300 条，人工标注标准答案或正确文档 ID。
2. **LLM-as-judge**：用强模型按 rubric 打分（忠实度、相关性、完整性），抽样人工校验一致率。
3. **A/B 对比**：改一个变量（切分策略/检索方式/模型），跑同一套集，出对比表。
4. **压测**：JMeter/wrk 打 QPS，记录 P50/P95/P99。

关键是**有对照、有前后**。「Recall 87%」不如「Recall 从 61% 提升到 87%」有说服力。

## 十、常见踩坑

| 坑 | 后果 | 怎么避免 |
|---|---|---|
| 只做 demo，没有评测 | 面试一问就露馅 | 必须建黄金集 |
| 堆功能不讲取舍 | 显得没思考 | 每个项目写 3 条 ADR |
| 忽略成本 | 生产不可用 | 记录 token/次、缓存命中率 |
| 忽略权限 | 数据泄露 | 检索层过滤 + 审计 |
| 用「LangChain 聊天机器人」当项目 | 毫无区分度 | 选有真实约束的场景 |
| 代码不可运行 | 直接扣分 | docker-compose 一键起 |
| 没有提交历史 | 看不出迭代 | 分阶段提交，写 commit message |
| 简历写技术栈清单 | 空洞 | 写「做了什么 + 效果 + 数字」 |

## 十一、12 周执行节奏

| 周 | 任务 | 产出 |
|---|---|---|
| 1-2 | LLM 基础、Prompt、Spring AI 入门 | 能跑通对话 + 流式 |
| 3-5 | 项目 1：RAG 知识库 | 可 demo + 黄金集 + 指标 |
| 6-7 | 项目 2：客服 Agent | 工具调用 + 审批流 |
| 8-9 | 项目 5：LLM 网关 | 路由/降级/配额 |
| 10 | 项目 3 或 4（选一个） | 差异化项目 |
| 11 | 补评测、压测、文档 | README + ADR + 评测报告 |
| 12 | 简历改写、模拟面试 | 3 个项目讲透 |

每周至少 10 小时。**不要同时开三个项目**，做完一个再下一个，完成度比数量重要。

## 十二、面试常见追问

**Q1：你的 RAG 项目 Recall 87%，怎么测的？**
黄金集 200 条问题，人工标注每条对应的正确 chunk ID；检索返回 Top5，命中即算对；用脚本批量跑，输出 Recall@5。同时抽 50 条做人工复核，确认标注一致性。

**Q2：为什么用 RRF 而不是给两路打分加权？**
BM25 和向量相似度的分数量纲不同，加权需要归一化且对数据分布敏感；RRF 只用排名，天然免疫量纲问题，鲁棒性好，调参少。

**Q3：Agent 怎么防止乱调工具？**
三层：Prompt 约束 + 工具 Schema 严格校验 + 外层状态机限制步数与合法转移；高风险工具不直接执行，生成审批单。

**Q4：项目里最难的工程问题是什么？**
（准备一个真实故事）比如：切分后子块丢失上下文导致答案断章取义 → 改成 small-to-big，检索用子块、返回父块，同时控制父块大小避免超上下文 → Recall 提升但延迟上升 → 加语义缓存与并行检索，把 P95 拉回 1.4s。

## 总结

作品集的本质是**用工程证据证明你能交付**。6 个项目不必全做，但前三个（RAG、Agent、网关）覆盖了当前 AI 应用岗 80% 的考察点。

记住三句话：

1. **没有指标的 project 只是 demo。**
2. **没有取舍的技术栈只是清单。**
3. **没有踩坑的项目说明你没真跑过。**

把这三件事补齐，你的简历会从「在学习 AI」变成「做过 AI 系统」——这是两个完全不同的段位。
