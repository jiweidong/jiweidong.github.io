---
title: 【系统设计】企业知识库问答系统架构设计：文档解析、权限隔离与引用溯源
date: 2026-10-24 08:25:00
tags:
  - AI
  - 系统设计
  - RAG
  - 知识库
  - 权限控制
  - 引用溯源
categories:
  - AI 工程
author: 东哥
---

# 【系统设计】企业知识库问答系统架构设计：文档解析、权限隔离与引用溯源

## 前言

搭一个 RAG demo 只要两小时：`pdf → 切分 → embedding → 向量库 → 拼 prompt → 调模型`。但把它做成**企业内部可用的知识库问答**，通常要六个月。

差距不在模型，在四件事：

1. **文档解析**：企业文档是 PDF 扫描件、Word 里的合并单元格、PPT 里的图片、Confluence 导出页。解析质量直接决定上限。
2. **权限隔离**：员工 A 不能通过问答看到员工 B 的薪酬表。而向量检索天然是「按相似度返回 Top-K」——**它不管你有没有权限**。
3. **引用溯源**：回答必须能点回原文的具体段落，否则没人敢用（尤其在法务、财务、运维场景）。
4. **时效性**：文档更新、删除、改权限，索引必须跟上，否则就是「拿旧制度回答新问题」。

这篇文章给一套完整的架构设计，重点讲清三件事：**解析链路怎么分层、权限怎么做才能不漏、引用怎么做才可信**。代码用 Java（Spring Boot + Spring AI）视角。

---

## 一、先定指标，再谈架构

企业知识库问答不是「好玩」，是要被考核的。上线前必须和业务方对齐这组指标：

| 类别 | 指标 | 目标值 | 怎么测 |
|---|---|---|---|
| 效果 | 答案正确率 | > 80% | 黄金集人工标注 |
| 效果 | 引用准确率 | > 95% | 引用片段是否真能支撑结论 |
| 效果 | 拒答率（该拒的拒） | > 90% | 构造「库里没有」的问题 |
| 安全 | 越权召回率 | **0** | 红队测试：用低权限账号查高密文档 |
| 性能 | 首字节延迟 P95 | < 1.5s | 流式输出，首 token 时间 |
| 性能 | 完整回答 P95 | < 8s | 端到端 |
| 成本 | 单次问答成本 | < 0.05 元 | token 账单 / 请求数 |
| 运维 | 文档更新到可检索 | < 5 分钟 | 埋点 |

**注意「越权召回率 = 0」是硬指标，不是「越低越好」。** 这决定了权限必须在**检索前**生效，而不是事后过滤（后面详述）。

---

## 二、整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         接入层                                   │
│  Web / 企业微信 / 钉钉 / API     ── SSO 登录 ──▶ 用户身份+权限集  │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                       问答编排层（Orchestrator）                  │
│  ① Query 理解  ② 改写/扩展  ③ 权限过滤条件构造                    │
│  ④ 混合检索    ⑤ 重排      ⑥ 上下文组装   ⑦ 生成 + 引用绑定       │
└───────┬──────────────────────────────────┬──────────────────────┘
        ▼                                  ▼
┌───────────────────┐              ┌──────────────────────────────┐
│   检索服务         │              │        生成服务               │
│  · 向量检索(HNSW)  │              │  · LLM 网关（多模型路由）      │
│  · BM25 关键词     │              │  · 流式输出 SSE               │
│  · RRF 融合        │              │  · 引用校验 / 幻觉拦截         │
│  · Reranker 重排   │              │  · 内容安全审核               │
└─────────┬─────────┘              └──────────────────────────────┘
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                       索引层                                     │
│  向量库（Milvus/pgvector/ES）  全文索引（ES）  元数据库（MySQL）   │
└────────────────────────────┬────────────────────────────────────┘
                             ▲
┌────────────────────────────┴────────────────────────────────────┐
│                    文档接入 Pipeline（异步）                      │
│  采集 → 解析 → 清洗 → 切分 → 富化(元数据/权限) → 向量化 → 入库    │
│  失败重试 / 死信 / 版本管理 / 删除传播                             │
└─────────────────────────────────────────────────────────────────┘
```

**四个关键设计决策：**

1. **索引与问答完全解耦**，通过消息队列异步连接。文档接入慢不能影响问答可用性。
2. **检索是混合的**（向量 + 关键词），单一向量检索在专有名词、错误码、型号上必然翻车。
3. **权限是「检索条件」不是「结果过滤」**。
4. **生成必须有引用绑定**，且引用可校验。

---

## 三、文档解析：决定系统上限的一步

### 3.1 解析质量的三层

| 层级 | 内容 | 差距 |
|---|---|---|
| L1 纯文本 | 能抽出字 | 表格变乱码、标题层级丢失、页眉页脚混入 |
| L2 结构化 | 保留标题/列表/表格结构 | 需要版面分析 |
| L3 语义单元 | 识别章节、条款、代码块、图表标题 | 需要文档模型 + 规则 |

大多数团队停在 L1，然后在「切分」环节花大量时间补救——**这是本末倒置**。解析阶段丢的结构，切分阶段补不回来。

### 3.2 分类型选型

| 文档类型 | 推荐方案 | 注意点 |
|---|---|---|
| PDF（文本型） | Apache PDFBox 3.x 提取 + 坐标信息 | 多栏排版会串行，需要按 x 坐标重排 |
| PDF（扫描件） | OCR（PaddleOCR / 云 OCR）+ 版面分析 | 表格识别要单独模型 |
| Word (.docx) | Apache POI `XWPF` | 合并单元格、文本框、批注要特殊处理 |
| Excel | POI `XSSF` + EasyExcel 流式读 | 大表要按 Sheet 拆，别整个读进内存 |
| PPT | POI `XSLF` | 演讲者备注往往比正文更有价值 |
| HTML / Confluence | Jsoup + 自定义清洗规则 | 去掉导航、页脚、评论区 |
| Markdown | 直接按标题树解析 | 代码块要单独标记 |
| 图片 | 多模态模型生成描述 | 图片描述作为独立 chunk，关联原图 URL |

### 3.3 解析产物的统一模型

不管源格式是什么，最终都要归一到一个结构：

```java
public record ParsedDocument(
        String docId,
        String title,
        String sourceType,          // PDF / DOCX / HTML ...
        String version,             // 内容版本号
        List<Block> blocks
) {}

public sealed interface Block permits Heading, Paragraph, Table, CodeBlock, ImageBlock {
    int order();
    String text();
    Map<String, String> attrs();    // 层级、页码、坐标、样式
}

public record Heading(int order, int level, String text, Map<String, String> attrs) implements Block {}
public record Paragraph(int order, String text, Map<String, String> attrs) implements Block {}
public record Table(int order, List<List<String>> rows, String caption, Map<String, String> attrs) implements Block {}
public record CodeBlock(int order, String language, String code, Map<String, String> attrs) implements Block {}
public record ImageBlock(int order, String imageUrl, String ocrText, Map<String, String> attrs) implements Block {}
```

**这个模型是整个系统的地基。** 有了 `order` 和 `attrs`（页码、坐标），后面的「切分保留标题路径」和「引用定位到原文位置」才有可能。

### 3.4 清洗规则（别跳过）

真实企业文档里，30% 的 token 是噪声：

```java
public class TextCleaner {
    private static final Pattern PAGE_HEADER = Pattern.compile("^第\\s*\\d+\\s*页\\s*/?\\s*共?\\s*\\d*\\s*页?$");
    private static final Pattern CONFIDENTIAL = Pattern.compile("^(内部资料|机密|绝密|仅供内部使用).*$");
    private static final Pattern MULTI_BLANK  = Pattern.compile("\\n{3,}");

    public String clean(String raw) {
        return raw.lines()
                .map(String::strip)
                .filter(l -> !l.isEmpty())
                .filter(l -> !PAGE_HEADER.matcher(l).matches())
                .filter(l -> !CONFIDENTIAL.matcher(l).matches())
                .collect(Collectors.joining("\n"))
                .replaceAll(MULTI_BLANK.pattern(), "\n\n");
    }
}
```

**注意**：`CONFIDENTIAL` 这类标记不要直接删——它是重要的权限线索，应该抽出来写进元数据，而不是丢掉。

---

## 四、切分：结构优先，长度兜底

### 4.1 四种切分策略

| 策略 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| 固定长度 | 每 512 字符切 | 简单 | 切断句子、丢上下文 |
| 递归字符 | 按 `\n\n` → `\n` → `。` → `，` 逐级切 | 通用、可控 | 不理解结构 |
| 结构感知 | 按标题树切，超长再递归 | **推荐** | 依赖解析质量 |
| 语义切分 | 计算相邻句向量相似度，找断点 | 边界最准 | 贵、慢 |

**生产方案：结构感知 + 递归兜底 + 父子块。**

### 4.2 父块 / 子块（Parent-Child）

核心思想：**用小块检索（精准），用大块生成（上下文完整）。**

```java
public record ChildChunk(
        String id,            // docId:parentId:seq
        String parentId,
        String docId,
        String text,          // 200~400 token，用于向量化
        String headingPath,   // "第3章 > 3.2 退款政策 > 3.2.1 时效"
        int page,
        float[] vector
) {}

public record ParentChunk(
        String parentId,
        String docId,
        String text,          // 800~1500 token，用于拼 prompt
        String headingPath,
        int startPage,
        int endPage
) {}
```

检索命中 `ChildChunk`，返回时替换成对应的 `ParentChunk` 内容。这样既保证召回精度，又保证生成时有足够上下文。

**实测收益**：在制度问答场景，父子块相比单层切分，答案正确率提升 8~15 个点。原因是很多问题的答案需要跨段落（比如「退款时效」在表格里，「例外情况」在下一段）。

### 4.3 切分参数

```yaml
rag:
  splitter:
    child-size: 350          # token
    child-overlap: 50
    parent-size: 1200
    min-chunk-size: 80       # 小于这个合并到上一块
    keep-heading-path: true  # 每个 chunk 前面拼上标题路径
    table-as-whole: true     # 表格不切，整块作为 chunk
    code-as-whole: true      # 代码块不切
```

**`keep-heading-path` 的隐藏价值**：它让 chunk 自带层级上下文。一个孤立的「时效为 7 个工作日」没有任何意义，加上「退款政策 > 审核通过后」才可检索、可理解。

---

## 五、权限隔离：这是最容易出事的地方

### 5.1 三种方案对比

| 方案 | 做法 | 安全性 | 性能 | 适用 |
|---|---|---|---|---|
| **前置过滤** | 检索时把权限作为 filter 下推给向量库 | **高** | 好 | 推荐 |
| 后置过滤 | 先检索 Top-100，再按权限过滤 | **低** | 差 | ❌ 不可用 |
| 分区索引 | 每个权限域一个 collection | 高 | 好 | 权限维度少、文档量巨大 |

**为什么后置过滤不可用**：假设用户只能看 100 篇文档中的 2 篇，检索 Top-10 全是无权文档，过滤完剩 0 条 → 系统「查不到」。加大 Top-K 到 1000 才能凑够，延迟爆炸，**而且过滤前的日志/缓存可能已经泄露了无权内容**。

### 5.2 权限模型设计

企业权限通常是「**多维叠加**」，不是单一 owner：

```java
public record DocAcl(
        String docId,
        String ownerId,
        Set<String> allowedUserIds,      // 白名单
        Set<String> allowedDeptIds,      // 部门
        Set<String> allowedRoleIds,      // 角色
        Set<String> deniedUserIds,       // 黑名单（优先级最高）
        String sensitivity               // PUBLIC / INTERNAL / CONFIDENTIAL / SECRET
) {}
```

配置示例（YAML 风格，便于业务方维护）：

```yaml
doc-acl:
  - doc-id: hr-salary-2026
    sensitivity: SECRET
    allowed-depts: [HR, FINANCE]
    allowed-roles: [HRBP]
    denied-users: [intern-001]
  - doc-id: tech-arch-guide
    sensitivity: INTERNAL
    allowed-depts: ["*"]        # 全员
```

### 5.3 权限如何下推到向量库

向量库的 filter 表达能力有限，通常是「标量字段 + 布尔表达式」。所以要把 ACL **展开成可过滤的标量字段**：

```java
public record VectorMeta(
        String docId,
        String chunkId,
        String sensitivity,
        List<String> allowDepts,     // 数组字段
        List<String> allowRoles,
        List<String> allowUsers,
        List<String> denyUsers,
        long version,
        String status                // ACTIVE / DELETED
) {}
```

检索时构造 filter：

```java
public String buildFilter(UserContext user) {
    // 用户能看到：公开 或 部门命中 或 角色命中 或 用户白名单命中
    // 并且：不在黑名单，且状态为 ACTIVE
    return """
        status == "ACTIVE"
        && !(denyUsers in [%s])
        && (
             sensitivity == "PUBLIC"
             || allowDepts in [%s]
             || allowRoles in [%s]
             || allowUsers in [%s]
           )
        """.formatted(
            joinQuoted(user.userId()),
            joinQuoted(user.deptIds()),
            joinQuoted(user.roleIds()),
            joinQuoted(user.userId()));
}
```

**三个必须注意的点：**

1. **部门要包含父部门**。用户在「技术部 > 后端组」，应该能看到「技术部」级的文档。查询前把 `deptIds` 展开成完整路径集合。
2. **黑名单优先级最高**，用 `!(denyUsers in [...])` 而不是靠「不在白名单」。
3. **`status == "ACTIVE"` 必须带**，这是防「已删除文档泄露」的最后一道闸。

### 5.4 权限变更的传播

改权限不需要重新向量化（向量只跟内容有关），只需要更新元数据：

```java
@EventListener
public void onAclChanged(AclChangedEvent e) {
    vectorStore.updateMetadata(e.docId(), Map.of(
            "allowDepts", e.newAcl().allowedDeptIds(),
            "allowRoles", e.newAcl().allowedRoleIds(),
            "allowUsers", e.newAcl().allowedUserIds(),
            "denyUsers",  e.newAcl().deniedUserIds(),
            "sensitivity", e.newAcl().sensitivity()
    ));
    // 同时失效该文档相关的答案缓存
    answerCache.evictByDocId(e.docId());
}
```

**别忘了失效缓存**。如果你的答案缓存 key 里没有权限维度，A 问过的问题被缓存后，B 可能直接拿到 A 的答案——这是真实发生过的越权事故。

**缓存 key 必须包含「权限指纹」**：

```java
String cacheKey = sha256(query + "|" + user.permissionFingerprint() + "|" + indexVersion);
```

`permissionFingerprint` 是「部门集合 + 角色集合 + 密级上限」的哈希。

### 5.5 红队测试清单

上线前必须跑一遍：

- [ ] 低权限账号直接问「高管薪酬表内容」
- [ ] 用同义词绕过（「工资明细」「薪资结构」）
- [ ] 问「总结一下我不能看的那些文档」
- [ ] 通过引用链接直接访问（引用 URL 是否也鉴权）
- [ ] 缓存穿透（A 问过，B 再问）
- [ ] 历史会话（权限被回收后，旧会话是否还能看到）
- [ ] 导出功能（对话导出是否带权限校验）
- [ ] 管理员降权后，其创建的知识库是否仍可见

---

## 六、引用溯源：让答案可被审计

### 6.1 引用必须满足三条

1. **可定位**：能跳到原文的页码 + 段落，最好高亮
2. **可校验**：引用片段里确实包含支撑答案的句子
3. **可追溯**：知道这条引用来自哪个版本的文档

### 6.2 数据结构

```java
public record Citation(
        int index,              // [1] [2]
        String docId,
        String docTitle,
        String chunkId,
        String headingPath,
        int page,
        String snippet,         // 引用原文（≤200 字）
        String sourceUrl,       // 带定位参数的深链
        String docVersion,      // 文档版本
        double score            // 检索得分，便于排查
) {}

public record Answer(
        String text,
        List<Citation> citations,
        boolean refused,        // 是否拒答
        String refuseReason
) {}
```

### 6.3 生成时强制引用

Prompt 里必须硬性约束：

```
你是企业知识库助手。请严格基于【参考资料】回答。

规则：
1. 每个结论后面必须标注来源编号，格式 [1]、[2]。
2. 如果参考资料中没有答案，直接回答"知识库中未找到相关信息"，禁止推测。
3. 不得引用【参考资料】之外的内容。
4. 如果资料之间冲突，指出冲突并分别标注来源。

【参考资料】
[1] (来源: 员工手册 v3.2, 第 4 章 4.3 节)
...内容...

[2] (来源: 报销制度 v1.8, 第 2 章)
...内容...
```

### 6.4 引用校验（关键环节）

模型会编造引用编号，也可能引用了一段但不支持结论。**必须做程序化校验**：

```java
public class CitationValidator {

    /** 校验 1：编号必须存在 */
    public void validateIndexes(Answer answer, List<Citation> available) {
        Set<Integer> valid = available.stream().map(Citation::index).collect(Collectors.toSet());
        for (int idx : extractIndexes(answer.text())) {
            if (!valid.contains(idx)) {
                throw new InvalidCitationException("引用了不存在的编号: " + idx);
            }
        }
    }

    /** 校验 2：引用片段必须能在原文中找到（防模型改写引用） */
    public void validateSnippet(Citation c, String originalChunkText) {
        String normalized = normalize(c.snippet());
        if (!normalize(originalChunkText).contains(normalized)) {
            throw new InvalidCitationException("引用内容与原文不符: " + c.chunkId());
        }
    }

    /** 校验 3：答案里的关键数字/日期必须出现在引用片段中 */
    public void validateFacts(String answerText, List<Citation> citations) {
        String corpus = citations.stream().map(Citation::snippet).collect(Collectors.joining("\n"));
        for (String token : extractNumbersAndDates(answerText)) {
            if (!corpus.contains(token)) {
                log.warn("疑似幻觉：答案中的 '{}' 未在任何引用中出现", token);
                // 可配置为：降级为"仅供参考" / 直接拒答
            }
        }
    }

    private String normalize(String s) {
        return s.replaceAll("\\s+", "").replaceAll("[，。、；：]", "");
    }
}
```

**校验 3 是最有效的一条**。企业问答里最致命的错误是数字错（「报销上限 5000」答成「8000」）。数字和日期是最容易程序化验证的事实。

### 6.5 拒答策略

```
检索最高分 < 阈值        → 直接拒答（不调模型，省钱）
检索结果全部被权限过滤掉  → "未找到你有权限查看的资料"
引用校验失败              → 降级：返回原文片段，不给结论
生成内容包含"根据我的理解" → 强制重生成或拒答
```

**拒答不是失败，是能力。** 一个从不拒答的知识库，等于一个不能信任的知识库。

---

## 七、时效性：删除比新增更难

### 7.1 三种变更

| 变更 | 处理 | 难点 |
|---|---|---|
| 新增文档 | 解析 → 切分 → 向量化 → 入库 | 幂等（重复投递不能产生重复 chunk） |
| 修改内容 | 差量更新 chunk（见 Embedding 一文） | 切分点漂移 |
| 删除文档 | 元数据置 `DELETED` + 异步物理删 | 三个存储要一致 |

### 7.2 删除的完整链路

```java
@Transactional
public void deleteDocument(String docId) {
    // 1. 业务库标记删除（真相源）
    documentRepo.markDeleted(docId);

    // 2. 发事件（事务提交后发送，避免事务回滚但消息已发）
    eventPublisher.publishEvent(new DocumentDeletedEvent(docId));
}

@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
public void onDeleted(DocumentDeletedEvent e) {
    // 3. 向量库/全文索引软删除（保证检索立即不可见）
    vectorStore.markDeleted(e.docId());
    searchIndex.markDeleted(e.docId());
    // 4. 失效缓存
    answerCache.evictByDocId(e.docId());
    // 5. 投递到延迟队列，24h 后物理删除（留出回滚窗口）
    cleanupQueue.schedule(e.docId(), Duration.ofHours(24));
}
```

**为什么「软删除 + 延迟物理删」**：误删是常态。留 24 小时窗口，运维可以一键恢复；物理删完就真的没了。

### 7.3 对账任务

每周跑一次全量对账，三个存储两两比对：

```java
@Scheduled(cron = "0 0 3 * * SUN")
public void reconcile() {
    Set<String> dbDocs = documentRepo.listActiveIds();
    Set<String> vectorDocs = vectorStore.listDocIds();

    Set<String> orphanInVector = difference(vectorDocs, dbDocs);   // 向量库多余
    Set<String> missingInVector = difference(dbDocs, vectorDocs);  // 向量库缺失

    log.info("对账: 多余 {} 条, 缺失 {} 条", orphanInVector.size(), missingInVector.size());
    // 多余 → 删除；缺失 → 重新入队
}
```

**没有对账的 RAG 系统，半年后一定会出现「查不到已存在的文档」和「查到已删除的文档」两个方向的 bug。**

---

## 八、容量与成本估算

假设：5000 员工，日活 1000，人均 10 次问答，文档 50 万页。

| 项目 | 估算 | 说明 |
|---|---|---|
| Chunk 数 | 50 万页 × 1.5 ≈ 75 万 | 每页约 1.5 个 chunk |
| 向量存储 | 75 万 × 1024 × 4B ≈ 3 GB | 单副本，含图索引 ~4 GB |
| 原文存储 | 50 万页 × 3KB ≈ 1.5 GB | 对象存储 |
| 元数据 | 75 万 × 300B ≈ 225 MB | MySQL |
| 日请求量 | 1000 × 10 = 1 万次 | 峰值按 5 倍 = 5 万/天 |
| 单次 token | 输入 3000（检索+历史）+ 输出 400 | 父子块 + 重排后 |
| 日 token | 1 万 × 3400 = 3400 万 | |
| 日成本 | ≈ 3400 万 × 3 元/百万 ≈ 100 元 | 按混合单价粗算 |
| 月成本 | ≈ 3000 元 | 含 embedding 摊销 |

**优化空间：**

- **缓存**：重复问题占比 30~50%，命中即省；
- **意图分流**：简单问题走小模型，复杂问题走大模型，可省 40%；
- **检索压缩**：把 10 个 chunk 压成 5 个（去重 + 摘要），输入 token 减半。

---

## 九、演进的四个阶段

| 阶段 | 能力 | 团队规模 | 周期 |
|---|---|---|---|
| P0 能用 | 单文档类型、全量重建、无权限 | 1 人 | 2 周 |
| P1 好用 | 多格式、增量更新、文档级权限、引用 | 2~3 人 | 2 个月 |
| P2 可信 | 混合检索 + 重排、引用校验、评测体系、拒答 | 4~5 人 | 4 个月 |
| P3 智能 | Agentic RAG、多轮改写、权限继承、主动推送 | 6+ 人 | 6 个月+ |

**别一上来就做 P3。** 大部分企业内部需求，P1 + P2 的混合检索和引用校验就能满足 90% 的场景。

---

## 十、面试追问

**Q1：为什么权限过滤必须在检索前？**

因为向量检索返回的是「最相似 Top-K」。如果先检索后过滤，一是 Top-K 可能被无权文档占满导致查不到，二是过滤前的中间结果可能进日志/缓存造成泄露，三是放大 Top-K 会让延迟和成本不可控。**安全要求决定了过滤必须下推。**

**Q2：父块/子块索引解决了什么问题？**

解决了「检索精度」与「生成上下文完整性」的矛盾。小块向量表达更聚焦、召回更准；大块包含更多上下文、生成更完整。用小块检索、大块生成，两头的好处都拿到。

**Q3：怎么防止模型编造引用？**

三道校验：编号必须存在于候选集、引用片段必须能在原文中匹配（做归一化后 substring 匹配）、答案中的数字/日期必须出现在引用片段里。第三条能抓住最常见的幻觉类型。

**Q4：文档删除怎么保证「立即不可见」？**

业务库标记删除 → 检索侧元数据立即置 `DELETED`（filter 生效，秒级不可见）→ 缓存失效 → 24 小时后物理删除。关键是**检索侧永远带 `status = ACTIVE` 条件**，即使下游同步失败也不会泄露。

**Q5：为什么要混合检索？**

向量检索擅长语义泛化，弱在精确匹配（错误码、型号、人名、条款号）。BM25 正好相反。两者用 RRF 融合，能同时覆盖「意思相近」和「字面精确」两类需求。实测 Recall@10 通常能提升 10 个点以上。

**Q6：知识库和微调怎么选？**

知识频繁变化、需要引用、需要权限控制 → RAG；风格/格式/领域语言习惯需要固化 → 微调。企业知识问答 95% 的场景应该用 RAG，因为**微调无法解决「知识过期」和「引用溯源」**。

**Q7：怎么评估这套系统好不好？**

三层：检索层看 Recall@K / MRR（黄金集）；生成层看答案正确率、引用准确率、拒答准确率；业务层看采纳率、二次追问率、人工工单下降量。**只看最后一层会被「用户不问」误导**，必须三层都看。

---

## 十一、总结

企业知识库问答的架构，本质是把四个「不性感但决定成败」的工程问题解决好：

1. **解析**：结构化模型 + 分类型选型，别指望切分补救；
2. **切分**：结构感知 + 父子块，标题路径必须带；
3. **权限**：过滤下推 + 缓存隔离 + 红队验证，`status=ACTIVE` 永远带着；
4. **引用**：编号校验 + 片段校验 + 数字校验，拒答是能力不是缺陷。

再叠加「增量更新 + 定时对账」保证时效，「混合检索 + 重排」保证效果，「评测体系」保证可迭代。

模型会换、框架会换，这四件事不会变。**把地基做对，换哪家大模型都能用；地基做错，换 GPT-5 也救不回来。**
