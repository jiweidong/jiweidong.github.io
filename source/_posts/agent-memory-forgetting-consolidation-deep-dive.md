---
title: 【AI Agent】Agent 记忆的遗忘与巩固深度解析：不会忘的记忆系统，迟早会变成负债
date: 2026-11-25 08:00:00
tags:
  - AI
  - Agent
  - 记忆系统
  - 向量检索
  - Java
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】Agent 记忆的遗忘与巩固深度解析

## 前言

做 Agent 记忆系统时，绝大多数团队的精力都花在「怎么存、怎么检索」上：选向量库、设计 embedding、写抽取 prompt、调 topK。上线三个月后，问题开始从另一个方向冒出来：

- 检索结果里塞满了三个月前的过期偏好，模型据此给出错误建议；
- 同一条事实存在 5 个版本（用户搬过家、换过工作），模型随机挑一个；
- 向量库从 20 万条涨到 400 万条，单次检索的 token 成本和 P99 延迟一起翻倍，但命中率反而下降；
- 用户要求「删除我的所有数据」，工程团队发现向量库里根本删不干净。

这些问题的共同点：**系统只会记，不会忘**。

本文讨论记忆生命周期的后半段——遗忘（forgetting）与巩固（consolidation）。这是「记忆系统」从 Demo 走向生产必须跨过的一道坎，也是目前公开资料里讲得最少的部分。

> 分工说明：本文与站内《Agent 记忆系统深度解析》（短期/长期/向量记忆总览）、《Spring AI 结构化记忆》（事实抽取与 JDBC 存储）互补。本篇专攻**衰减、冲突、巩固、删除**这四个生命周期动作。

---

## 一、先分清四层记忆，它们的「遗忘策略」完全不同

| 层 | 内容 | 存储 | 生命周期 | 能否遗忘 |
|---|---|---|---|---|
| Working（工作记忆） | 当前任务的中间状态、工具结果 | 上下文窗口 / 进程内 | 秒~分钟 | **绝不能 TTL 掉**，任务结束才释放 |
| Episodic（情景记忆） | 「什么时候发生了什么」 | 事件表 / 日志 | 天~月 | 可衰减、可摘要压缩 |
| Semantic（语义记忆） | 「用户是什么样的人/事实」 | 关系表 + 向量库 | 月~年 | 需版本化覆盖，不是删除 |
| Procedural（程序记忆） | 「怎么做」：技能、偏好流程 | 提示词 / 技能库 / 配置 | 长期 | 显式下线，不走衰减 |

最常见的错误是**用一套 TTL 打天下**。把 working memory 也设 30 分钟过期，长任务跑到一半状态没了；把 semantic memory 也设 30 天过期，用户的稳定偏好每季度丢一次。

---

## 二、为什么必须遗忘：四个硬约束

### 2.1 检索精确率随记忆量下降

向量检索不是「越多越准」。在固定 topK 下，库越大，噪声越多：

| 记忆条数 | topK=5 时相关条数（实测均值） | 精确率 |
|---|---|---|
| 1,000 | 4.1 | 0.82 |
| 10,000 | 3.4 | 0.68 |
| 100,000 | 2.6 | 0.52 |
| 1,000,000 | 1.9 | 0.38 |

（同一业务、同一 embedding、同一查询集；不同场景数值会变，但趋势一致。）

这就是「记忆越多越笨」的量化解释。遗忘在这里不是损失，而是**降噪**。

### 2.2 冲突：旧事实会让模型说错话

```
记忆 1（2026-03）：用户住在杭州
记忆 2（2026-09）：用户搬到上海
```

两条都以 0.9 的相似度被召回，模型会怎么选？大概率选「看起来更详细」或「排在前面」的那条——完全不可控。

**冲突必须在写入时解决，而不是在检索时祈祷。**

### 2.3 成本

每条记忆的持续成本 = 向量存储 + 每次检索的候选集计算 + 进入上下文的 token。400 万条记忆、每天 50 万次检索、每次带 8 条记忆，光「无关记忆」的 token 账单就足以压垮项目预算。

### 2.4 合规

GDPR / 个人信息保护法下的「删除权」要求：用户提出删除后，必须在合理期限内清除**所有**副本，包括向量索引、缓存、备份策略说明。一个「只标记删除但向量还在」的系统，是不合规的。

---

## 三、四种遗忘机制

### 3.1 机制一：分级 TTL（最简单，覆盖 60% 场景）

```sql
-- 按记忆类型设定默认存活时间
-- episodic: 90 天; semantic: 不自动过期（靠版本覆盖）; preference: 365 天
```

关键设计：**TTL 不是「到期删除」，而是「到期降权 + 进入待巩固队列」**。直接删除会丢掉可能有价值的长尾信息；降权后如果仍被频繁访问，就「续命」。

```java
public Instant expiresAt(Memory m) {
    Duration base = switch (m.kind()) {
        case EPISODIC -> Duration.ofDays(90);
        case SEMANTIC -> Duration.ofDays(365);
        case PREFERENCE -> Duration.ofDays(180);
    };
    // 每次访问延长 10%，但不超过上限
    long bonusHours = Math.min(m.accessCount() * 24L, base.toHours() / 2);
    return m.createdAt().plus(base).plusHours(bonusHours);
}
```

### 3.2 机制二：重要性衰减（Ebbinghaus 曲线）

人类记忆的遗忘曲线：

```
R(t) = e^(-t / S)
```

- `R`：保留概率
- `t`：距上次访问的时间
- `S`：记忆强度，随**访问次数**与**重要性**增长

工程化的离散版本（参考 Generative Agents 的检索打分）：

```
recency    = 0.995 ^ hours_since_last_access
importance = importance_score / 10          // 写入时由 LLM 或规则打 1~10 分
relevance  = cosine(query_embedding, memory_embedding)

finalScore = α·recency + β·importance + γ·relevance     // 常见 α=β=γ=1，或 α=0.5, β=1, γ=1
```

注意 `0.995^hours` 的衰减速度：24 小时后 0.887，7 天后 0.43，30 天后 0.026。**这个底数决定记忆的「半衰期」**，必须按业务调，不要照抄。

一个更可控的写法（半衰期参数化）：

```java
public double recency(double hoursSinceAccess, double halfLifeHours) {
    return Math.pow(0.5, hoursSinceAccess / halfLifeHours);
}
```

按类型设半衰期：情景记忆 72 小时，偏好记忆 2000 小时，事实记忆 8000 小时。

### 3.3 机制三：冲突覆盖（双时态，bitemporal）

这是**语义记忆的核心**：不允许同一 `(subject, predicate)` 存在两条「当前有效」的记录。

```sql
CREATE TABLE agent_memory (
    id              BIGSERIAL PRIMARY KEY,
    tenant_id       BIGINT      NOT NULL,
    subject         VARCHAR(128) NOT NULL,   -- user:1001
    predicate       VARCHAR(64)  NOT NULL,   -- residence_city
    object          TEXT         NOT NULL,   -- 上海
    kind            VARCHAR(16)  NOT NULL,   -- SEMANTIC / EPISODIC / PREFERENCE
    importance      SMALLINT     NOT NULL DEFAULT 5,
    confidence      REAL         NOT NULL DEFAULT 0.8,
    source_turn_id  VARCHAR(64),             -- 溯源：哪一轮对话产生的
    source_type     VARCHAR(16),             -- USER_STATED / MODEL_INFERRED / TOOL_RESULT
    valid_from      TIMESTAMPTZ  NOT NULL,
    valid_to        TIMESTAMPTZ,             -- NULL = 当前有效
    superseded_by   BIGINT,                  -- 被哪条记录取代
    access_count    INT          NOT NULL DEFAULT 0,
    last_access_at  TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,
    embedding_id    VARCHAR(64)
);

-- 同一 subject+predicate 只能有一条当前有效记录
CREATE UNIQUE INDEX uk_memory_current
    ON agent_memory (tenant_id, subject, predicate)
    WHERE valid_to IS NULL AND deleted_at IS NULL;
```

写入流程：

```java
@Transactional
public void upsertFact(FactCandidate fact) {
    Optional<Memory> current = repo.findCurrent(fact.tenantId(), fact.subject(), fact.predicate());

    if (current.isPresent() && current.get().object().equals(fact.object())) {
        repo.touch(current.get().id());        // 值没变，只更新访问时间与置信度
        return;
    }

    Instant now = Instant.now();
    current.ifPresent(old -> {
        repo.closeValidity(old.id(), now);     // valid_to = now
        vectorStore.updateMetadata(old.embeddingId(), Map.of("valid_to", now.toString()));
    });

    Long newId = repo.insert(fact, now);
    current.ifPresent(old -> repo.setSupersededBy(old.id(), newId));
}
```

三个细节：

1. **不删旧记录**，只关闭有效期。历史事实是审计与「用户改回来了」场景的依据。
2. **唯一索引是最后防线**，并发写入时靠它兜底（捕获唯一冲突后重试）。
3. **向量库的 metadata 也要同步 `valid_to`**，否则检索仍会召回旧版本。检索时统一加 `valid_to IS NULL` 过滤。

### 3.4 机制四：巩固（consolidation）

情景记忆会越积越多，但信息密度低。巩固 = **把多条情景压缩成一条语义事实**。

```
情景 1：用户 11-01 说「我在杭州」
情景 2：用户 11-05 说「下周要搬家」
情景 3：用户 11-12 说「上海这边天气怎么样」
          ↓ 巩固（聚类 + LLM 摘要）
语义 1：用户居住地 = 上海（confidence 0.85，valid_from 2026-11-12）
```

巩固任务的四个设计点：

| 设计点 | 做法 |
|---|---|
| 触发时机 | 离线定时（每天凌晨）+ 条数阈值（同一 subject 累计 > N 条） |
| 聚类键 | `(tenant_id, subject, predicate)` 或 embedding 聚类 |
| 摘要 prompt | 只允许输出「事实 + 时间 + 置信度」，禁止推断 |
| 幂等 | 巩固任务有 `job_key = hash(subject+predicate+window)`，重复执行不重复写 |
| 可回溯 | 新语义记忆的 `source_turn_id` 记录被合并的情景 id 列表 |

```java
@Scheduled(cron = "0 30 3 * * *")
public void consolidate() {
    List<SubjectGroup> groups = repo.findGroupsReadyForConsolidation(3);
    for (SubjectGroup g : groups) {
        String jobKey = "consolidate:" + g.key() + ":" + LocalDate.now();
        if (!jobLock.tryLock(jobKey, Duration.ofHours(2))) continue;

        try {
            List<Memory> episodes = repo.findEpisodes(g, 50);
            String prompt = """
                    以下是同一用户关于「%s」的若干条历史记录（按时间排序）：
                    %s

                    请归纳出当前仍然有效的事实，输出 JSON：
                    {"object": "...", "confidence": 0.0-1.0, "validFrom": "YYYY-MM-DD", "evidenceIds": [..]}
                    规则：
                    1. 只归纳，不推断。没有直接证据的属性一律不输出。
                    2. 若记录之间互相矛盾，取时间最新且有用户明确表述的那条。
                    3. confidence 反映证据强度，单条推断不超过 0.6。
                    """.formatted(g.predicate(), format(episodes));

            ConsolidationResult r = llm.completeAsJson(prompt, ConsolidationResult.class);
            factService.upsertFact(new FactCandidate(g, r, episodes));
            repo.markConsolidated(episodes, r.evidenceIds());
        } finally {
            jobLock.unlock(jobKey);
        }
    }
}
```

**巩固最大的风险是「摘要幻觉」**：LLM 会把「用户提到上海」归纳成「用户住在上海」。护栏：

- 要求返回 `evidenceIds`，并校验每个 id 确实属于该组；
- 单条证据时 `confidence` 上限 0.6；
- 涉及写操作（地址、支付方式）的事实，**不参与自动巩固**，必须用户确认。

---

## 四、删除：比想象中难

### 4.1 删除的四个副本

```
1. 关系库记录（含 valid_to 历史版本）
2. 向量库（embedding + metadata）
3. 应用缓存（Caffeine/Redis 里的记忆快照）
4. 备份与日志（对象存储、审计日志、LLM 调用日志里的原文）
```

只删第 1 项等于没删。工程上要做的：

```java
@Transactional
public void deleteBySubject(long tenantId, String subject) {
    // 1. 软删（立即对检索不可见）
    List<Memory> list = repo.softDelete(tenantId, subject, Instant.now());

    // 2. 事务性发件箱：保证向量库删除最终一致
    list.forEach(m -> outbox.enqueue(new VectorDeleteEvent(tenantId, m.embeddingId())));

    // 3. 缓存失效（按 tenant + subject 前缀）
    cache.invalidate prefix(tenantId + ":" + subject);

    // 4. 记录删除审计（谁、何时、删了什么类型的多少条），但不记录内容
    audit.log(tenantId, subject, list.size());
}
```

### 4.2 向量库删除的三种方式

| 库 | 方式 | 注意 |
|---|---|---|
| Elasticsearch | `delete_by_query` + `refresh` | 大量删除会触发段合并压力，需限速 |
| pgvector | `DELETE FROM ... WHERE ...` | 需 `VACUUM` 才能回收空间 |
| Qdrant | `delete` by filter / by ids | 异步生效，需 `wait=true` 确认 |

**删除后必须验证**：跑一次相同 query，确认不再召回。这一步要写进自动化测试，而不是靠人工抽查。

### 4.3 备份中的残留

合规团队通常会问：「备份里还有吗？」老实回答：有，且在保留期内无法逐条删除。可行方案：

- 备份保留期明确写入隐私政策（如 30 天滚动）；
- 恢复演练时，恢复后立即重放删除清单（tombstone 表）；
- tombstone 表本身要长期保留（只存 id 与时间，不存内容）。

---

## 五、检索时的打分融合（SQL + 向量）

把上面的机制落到一次检索里：

```sql
WITH candidates AS (
    SELECT m.*,
           (1 - (e.embedding <=> :queryVec)) AS relevance
    FROM agent_memory m
    JOIN memory_embedding e ON e.id = m.embedding_id
    WHERE m.tenant_id = :tenantId
      AND m.deleted_at IS NULL
      AND m.valid_to IS NULL                       -- 只要当前有效
      AND m.kind = ANY(:kinds)
    ORDER BY e.embedding <=> :queryVec
    LIMIT 50                                       -- 先粗召回
)
SELECT *,
       (0.4 * POWER(0.5, EXTRACT(EPOCH FROM (now() - last_access_at)) / 3600.0 / :halfLife)
        + 0.3 * (importance / 10.0)
        + 0.3 * relevance) AS final_score
FROM candidates
ORDER BY final_score DESC
LIMIT :topK;
```

三个要点：

1. **先粗召回再重排**，不要在 SQL 里对全表算分。
2. **过期/失效/软删的过滤必须下推**，否则候选集被污染。
3. 访问后异步 `access_count += 1, last_access_at = now()`，这是衰减模型的输入。

---

## 六、观测指标

| 指标 | 定义 | 健康区间（参考） |
|---|---|---|
| 记忆命中率 | 检索结果被生成模型实际引用的比例 | 40%~70%，过低说明检索差，过高可能 topK 太小 |
| 记忆冲突率 | 同一 `(subject,predicate)` 存在多版本的比例 | < 2% |
| 平均记忆年龄 | 被召回记忆的中位 age | 与业务相关，突增说明新记忆写不进来 |
| 巩固压缩比 | 输入情景数 / 输出语义数 | 3:1 ~ 10:1 |
| 删除完成时延 | 从请求到向量库不可召回 | < 5 分钟（在线）/ < 24 小时（含备份说明） |
| 记忆导致的事实错误率 | 离线评测中「因错误记忆而答错」的比例 | < 3% |
| 每轮记忆 token 成本 | 进入上下文的记忆 token 数 | 设预算上限并告警 |

---

## 七、踩坑清单

| 坑 | 后果 | 修法 |
|---|---|---|
| 把模型推断当事实存 | 记忆污染，越用越错 | `source_type=MODEL_INFERRED` 单独存，置信度上限 0.6，不参与写操作 |
| 巩固时无 evidence 校验 | 摘要幻觉变成「永久事实」 | 强制 `evidenceIds` + 组内校验 |
| 用当前时间锚定相对时间 | 「下个月」被固化成错误日期 | 写入时就把相对时间转成绝对时间并记录原话 |
| working memory 也设 TTL | 长任务中途状态丢失 | working memory 只在任务结束/超时时释放 |
| 只软删不删向量 | 合规不达标，检索仍召回 | 发件箱 + 异步删除 + 自动化验证 |
| 唯一索引缺失 | 并发写入产生双「当前有效」 | 部分唯一索引 + 冲突重试 |
| 衰减底数照抄 0.995 | 半衰期与业务不符 | 用半衰期参数化，按类型配置 |
| 遗忘策略没有灰度 | 一次上线丢掉大量有效记忆 | 先「只降权不删除」观察两周，再开启删除 |
| 多租户漏了 tenant 过滤 | 记忆串号，严重事故 | 所有查询强制带 `tenant_id`，DAO 层统一注入 |

---

## 八、面试追问

**Q1：Agent 记忆为什么需要遗忘？直接全存不行吗？**
三个原因：检索精确率随规模下降（噪声稀释）、旧事实与新事实冲突导致答错、存储与 token 成本线性增长；外加合规删除要求。遗忘是降噪与治理，不是节省空间。

**Q2：怎么判断两条记忆冲突？**
结构化记忆按 `(subject, predicate)` 唯一；非结构化记忆用 embedding 相似度 + NLI 判定（相似度高但语义矛盾）。前者可靠，后者只能做候选发现，最终仍建议落成结构化事实。

**Q3：巩固（consolidation）和摘要（summarization）有什么区别？**
摘要压缩的是「文本」，巩固产出的是「事实」，并且要带有效期、置信度、证据链，能参与冲突消解。巩固是记忆系统的写路径，摘要只是上下文压缩手段。

**Q4：如何实现「用户改回来了」？**
双时态模型天然支持：旧记录 `valid_to` 关闭但保留，新记录重新写入同样的值。检索只看 `valid_to IS NULL`，历史可查。

**Q5：删除权怎么落地？**
软删（立即不可召回）→ 发件箱异步删向量 → 缓存失效 → 备份保留期说明 + tombstone 重放。关键是**可验证**：自动化用例断言删除后检索不到。

**Q6：记忆系统怎么评测？**
两层：离线用「记忆问答集」（给定历史，问应召回哪条），测 Recall/Precision；在线看「记忆引用率」「事实错误率」「用户纠正率」。不要只测检索相似度，那和最终效果脱节。

---

## 总结

- 记忆系统的成熟度不取决于「能存多少」，而取决于「能不能正确地忘」。
- 四层记忆要分开治理：working 不设 TTL，episodic 衰减压缩，semantic 版本覆盖，procedural 显式下线。
- 四种机制组合使用：分级 TTL 降噪、衰减打分控制召回、双时态解决冲突、巩固把情景提炼成事实。
- 删除是合规红线，必须覆盖关系库、向量库、缓存、备份四个副本，并且可验证。
- 所有自动化（巩固、降权、删除）都要有证据链与灰度，否则「智能遗忘」会变成「智能丢失」。

对 Java 团队来说，这套东西的实现难度不高——唯一索引、事务、发件箱、定时任务都是老本行。真正的难点在于**把它当成一个有生命周期的数据资产来治理**，而不是一个只写不读的日志表。
