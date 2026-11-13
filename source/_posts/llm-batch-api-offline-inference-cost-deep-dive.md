---
title: 【AI 工程化】Batch API 与离线批量推理深度解析：五折成本的编排、对账与容错设计
date: 2026-11-13 08:40:00
tags:
  - AI
  - Java
  - 成本治理
  - 批处理
  - 架构设计
categories:
  - AI 工程
author: 东哥
---

# 【AI 工程化】Batch API 与离线批量推理深度解析：五折成本的编排、对账与容错设计

## 前言

大部分团队对 LLM 成本的注意力都放在在线链路上：缓存、限流、模型降级、Prompt 压缩。但真正的大头往往在离线任务：

- 历史 200 万条客服会话要做意图打标；
- 每天新增 30 万篇文档要做摘要和实体抽取；
- 商品库 50 万 SKU 要做标题生成与类目归类；
- 一次 RAG 索引重建要重算 800 万条 chunk 的 embedding；
- 模型/Prompt 升级要做全量回归评测。

这些任务的共同点是：**不要求实时、可以等几小时、但量极大**。对它们用同步 API，等于用「在线价格 + 在线限流」干「离线活」，成本能差出 3~10 倍。

主流厂商都提供了 Batch 接口（OpenAI Batch API、Anthropic Message Batches、Vertex AI Batch Prediction、Bedrock Batch Inference），共同特征是：**异步提交、24 小时窗口、约 50% 折扣、结果批量返回**。听起来很简单——上传一个 JSONL、等结果、下载。但真做到百万级稳定跑完，要解决的是**编排、幂等、部分失败、对账、成本归因**五件事。

这篇文章按「成本模型 → 协议形态 → Java 编排 → 容错对账 → 选型对比」拆开讲。

## 一、先把成本账算清楚

### 1.1 三段式成本结构

LLM 调用成本 = 输入 token × 输入单价 + 输出 token × 输出单价 + 请求固定开销。

以「100 万条客服会话意图打标」为例，假设：

- 每条输入 800 token（对话 + 指令 + few-shot）
- 每条输出 20 token（分类结果 JSON）
- 同步价格：输入 \$2.5 / 百万 token，输出 \$10 / 百万 token

```
同步成本 = 1,000,000 × 800/1e6 × 2.5 + 1,000,000 × 20/1e6 × 10
        = 2,000 + 200
        = $2,200
```

Batch 五折：

```
Batch 成本 = $1,100
```

再叠加三个优化：

| 优化手段 | 典型收益 | 前提 |
|---|---|---|
| Batch 折扣 | −50% | 任务可延迟 24h |
| Prompt 缓存（同前缀） | 输入成本 −50%~90% | 前缀稳定、厂商支持 |
| 输出结构化裁剪 | 输出 token −30%~60% | 用 JSON 字段名而非完整句子 |
| 小模型分流 | 整体 −70%~90% | 有高质量标注集可验证 |

组合后 100 万条打标从 \$2,200 降到 **\$150~300**，差了一个数量级。这就是为什么「离线任务必须走 Batch」不是优化项，而是基线。

### 1.2 但别忽略隐藏成本

| 隐藏成本 | 说明 | 量级 |
|---|---|---|
| 编排与运维 | 分片、重试、对账代码 | 1~2 人周 |
| 结果落库 | 百万行 upsert | 写库成本可能超过推理成本 |
| 失败重跑 | 长尾任务反复失败 | 5%~15% token 浪费 |
| 结果过期 | 24h 未完成的任务需重新提交 | 取决于队列深度 |
| 人工核对 | 抽样质量检查 | 持续成本 |

**结论：Batch 的收益在「量大 + 可延迟」，不是「所有任务都该 Batch」。** 单次几千条以内、要求小时级返回的，同步 + 并发就够。

## 二、协议形态：所有 Batch API 都是「文件进、文件出」

尽管各家字段不同，抽象出来的状态机是一样的：

```
1. 准备请求文件（JSONL，每行一条，带 custom_id）
        │
2. 上传文件 → 得到 file_id
        │
3. 创建 batch job（引用 file_id + 完成窗口）
        │
4. 轮询 job 状态：validating → in_progress → finalizing → completed
        │                                     ↘ failed / expired / cancelled
5. 下载 output_file_id 与 error_file_id
        │
6. 按 custom_id 逐行对账，落库
```

三个关键约束（各家大同小异，踩坑前先查文档）：

| 约束 | 典型值 | 影响 |
|---|---|---|
| 单文件大小上限 | 100~500MB | 决定分片策略 |
| 单文件请求数上限 | 5 万~10 万 | 决定分片粒度 |
| 完成窗口 | 24h | 超时任务 `expired`，不退不补 |
| `custom_id` 限制 | ≤64 字符、`[a-zA-Z0-9_-]` | 不能直接用业务主键（含冒号/斜杠） |
| 结果顺序 | **不保证与输入一致** | 必须按 id 对账，不能按行号 |
| 结果有效期 | 30 天（文件可下载期） | 过期后无法补拉，要尽早落库 |

## 三、Java 编排：状态机 + 分片 + 断点续跑

### 3.1 表结构先行

Batch 任务的可恢复性来自「任务状态外置」，而不是内存里的 `Future`：

```sql
CREATE TABLE llm_batch_job (
  id              BIGINT PRIMARY KEY AUTO_INCREMENT,
  biz_type        VARCHAR(64)  NOT NULL,        -- order_intent / doc_summary
  provider        VARCHAR(32)  NOT NULL,        -- openai / anthropic / vertex
  model           VARCHAR(64)  NOT NULL,        -- 快照版本，如 gpt-4o-2024-08-06
  prompt_version  VARCHAR(32)  NOT NULL,
  shard_no        INT          NOT NULL,
  total_shards    INT          NOT NULL,
  item_count      INT          NOT NULL,
  remote_file_id  VARCHAR(128),
  remote_batch_id VARCHAR(128),
  status          VARCHAR(24)  NOT NULL,        -- PREPARED/UPLOADED/SUBMITTED/...
  output_file_id  VARCHAR(128),
  error_file_id   VARCHAR(128),
  input_tokens    BIGINT DEFAULT 0,
  output_tokens   BIGINT DEFAULT 0,
  cost_usd        DECIMAL(12,4) DEFAULT 0,
  created_at      DATETIME(3) NOT NULL,
  updated_at      DATETIME(3) NOT NULL,
  UNIQUE KEY uk_biz_shard (biz_type, prompt_version, shard_no),
  KEY idx_status (status, updated_at)
);

CREATE TABLE llm_batch_item (
  id           BIGINT PRIMARY KEY AUTO_INCREMENT,
  job_id       BIGINT NOT NULL,
  custom_id    VARCHAR(64) NOT NULL,
  biz_key      VARCHAR(128) NOT NULL,           -- 真实业务主键
  status       VARCHAR(24) NOT NULL,            -- PENDING/SUCCEEDED/FAILED/EXPIRED
  result_json  JSON NULL,
  error_type   VARCHAR(64) NULL,
  retry_count  INT NOT NULL DEFAULT 0,
  UNIQUE KEY uk_job_custom (job_id, custom_id),
  KEY idx_biz_key (biz_key)
);
```

两个设计要点：

- **`uk_biz_shard` 唯一键**保证「同一业务 + 同一 prompt 版本 + 同一分片」不会被重复提交（进程重启后的幂等基石）。
- **`custom_id` 与 `biz_key` 分离**：前者受厂商字符集限制，用 `sha1(biz_key).substring(0,32)`；后者保留真实主键用于回写。

### 3.2 请求构造：每行一条，严格 NDJSON

```java
public class BatchRequestBuilder {

    private final ObjectMapper mapper = new ObjectMapper();

    /** 单文件 ≤ 5 万条 / ≤ 200MB，双阈值任一触顶就切下一片 */
    public List<Path> buildShards(List<Task> tasks, Path workDir) throws IOException {
        List<Path> shards = new ArrayList<>();
        List<String> lines = new ArrayList<>();
        long bytes = 0;
        int idx = 0;

        for (Task t : tasks) {
            String line = mapper.writeValueAsString(toRequestLine(t));
            lines.add(line);
            bytes += line.getBytes(StandardCharsets.UTF_8).length + 1;

            if (lines.size() >= 50_000 || bytes >= 200L * 1024 * 1024) {
                shards.add(write(workDir, idx++, lines));
                lines.clear();
                bytes = 0;
            }
        }
        if (!lines.isEmpty()) shards.add(write(workDir, idx, lines));
        return shards;
    }

    private ObjectNode toRequestLine(Task t) {
        ObjectNode line = mapper.createObjectNode();
        line.put("custom_id", customIdOf(t.bizKey()));   // sha1 前 32 位
        line.put("method", "POST");
        line.put("url", "/v1/chat/completions");
        ObjectNode body = line.putObject("body");
        body.put("model", "gpt-4o-2024-08-06");
        body.put("temperature", 0);
        body.put("max_tokens", 64);                      // 卡死输出上限，防跑飞
        ArrayNode messages = body.putArray("messages");
        messages.addObject().put("role", "system").put("content", systemPrompt());
        messages.addObject().put("role", "user").put("content", truncate(t.text(), 6_000));
        // 结构化输出：能显著压缩输出 token
        body.putObject("response_format").put("type", "json_object");
        return line;
    }
}
```

三个容易被忽略的细节：

1. **`max_tokens` 必须设**。Batch 里一条输出跑飞，可能吃掉几千 token，乘以百万条就是灾难。
2. **输入要截断**。超长对话直接截断到 token 预算内（按字符粗估即可），否则单条超限整行失败。
3. **NDJSON 不能有 BOM、不能有尾随逗号、最后一行也要有换行**。很多「文件校验失败」都是这三件事。

### 3.3 提交与轮询：指数退避 + 状态收敛

```java
@Component
public class BatchPoller {

    private static final Set<String> TERMINAL =
            Set.of("completed", "failed", "expired", "cancelled");

    @Scheduled(fixedDelay = 60_000)
    public void poll() {
        List<BatchJob> running = jobRepo.findByStatusIn(
                List.of("SUBMITTED", "IN_PROGRESS", "FINALIZING"));

        for (BatchJob job : running) {
            try {
                RemoteBatch remote = client.getBatch(job.getRemoteBatchId());
                job.setStatus(mapStatus(remote.status()));
                if (remote.outputFileId() != null) job.setOutputFileId(remote.outputFileId());
                if (remote.errorFileId() != null)  job.setErrorFileId(remote.errorFileId());

                if (TERMINAL.contains(remote.status())) {
                    downloadAndReconcile(job);
                }
                jobRepo.save(job);
            } catch (RateLimitException e) {
                // 轮询也要限流：别把管理接口打成 429
                sleep(jitter(e.retryAfterSeconds()));
            } catch (Exception e) {
                log.warn("poll failed, jobId={}", job.getId(), e);
                // 不抛：单条失败不能中断整批轮询
            }
        }
    }
}
```

轮询策略经验值：

| 任务规模 | 轮询间隔 | 说明 |
|---|---|---|
| < 5 万条 | 30s | 通常 10~40 分钟完成 |
| 5~50 万条 | 60~120s | 别更密，管理接口也有配额 |
| > 50 万条 | 300s | 观察 `completed` 比例即可 |

**不要用固定 sleep 轮询几十个 job**，用调度框架（XXL-Job / Quartz / Spring `@Scheduled`）统一扫表，天然支持重启恢复。

### 3.4 结果对账：顺序不保证，必须按 id 匹配

```java
public void downloadAndReconcile(BatchJob job) throws IOException {
    Path out = fileClient.download(job.getOutputFileId(), job.getId());
    Path err = job.getErrorFileId() == null ? null
             : fileClient.download(job.getErrorFileId(), job.getId());

    Map<String, BatchItem> byCustomId = itemRepo.findByJobId(job.getId()).stream()
            .collect(Collectors.toMap(BatchItem::getCustomId, i -> i));

    try (BufferedReader r = Files.newBufferedReader(out, UTF_8)) {
        String line;
        while ((line = r.readLine()) != null) {
            JsonNode node = mapper.readTree(line);
            String customId = node.path("custom_id").asText();
            BatchItem item = byCustomId.get(customId);
            if (item == null) continue;                        // 未知 id，忽略并告警

            JsonNode response = node.path("response");
            if (response.path("status_code").asInt() == 200) {
                item.markSucceeded(extractContent(response));
            } else {
                item.markFailed(response.path("body").path("error").path("type").asText());
            }
        }
    }

    if (err != null) {
        // error 文件里的行同样要落库，否则这些 item 永远 PENDING
        try (BufferedReader r = Files.newBufferedReader(err, UTF_8)) {
            String line;
            while ((line = r.readLine()) != null) {
                JsonNode node = mapper.readTree(line);
                BatchItem item = byCustomId.get(node.path("custom_id").asText());
                if (item != null) item.markFailed(node.path("error").path("type").asText());
            }
        }
    }

    // 收尾：既不在 output 也不在 error 的，标记 EXPIRED（超窗口）
    int expired = itemRepo.markMissingAsExpired(job.getId());
    job.setStatus("DONE");
    log.info("reconciled job={} items={} expired={}", job.getId(), byCustomId.size(), expired);
}
```

**这一步是最容易写错的地方**：只解析 `output_file_id`、不解析 `error_file_id`，会导致失败条目永远停在 `PENDING`，对账报表看起来「完成率 99%」，实际有 1% 数据黑洞。

## 四、幂等、重试与「部分失败」的分类治理

### 4.1 三层幂等

| 层 | 手段 | 防什么 |
|---|---|---|
| 提交层 | `uk_biz_shard` 唯一键 + 状态机 CAS | 进程重启重复提交、重复计费 |
| 条目层 | `custom_id = sha1(biz_key + prompt_version)` | 同一业务被两个分片包含 |
| 落库层 | 业务表按 `biz_key` upsert | 结果重复写入 |

### 4.2 失败分类：只有一类值得重试

| 错误类型 | 例子 | 处置 |
|---|---|---|
| 请求级不可恢复 | `invalid_request_error`（超长、格式错） | 修正构造逻辑，**不重试**，进死信 |
| 内容级拒绝 | `content_filter` | 记录并跳过，业务侧兜底 |
| 服务级可恢复 | `rate_limit`、`server_error`、`timeout` | 重新打包成新 batch，**只重试这些** |
| 任务级过期 | `expired`（超 24h 未完成） | 缩小分片重新提交 |
| 结果缺失 | output/error 都没有 | 视为过期，重新提交 |

重试要**重新打包成新 batch**，而不是在原 batch 上重发——大多数 Batch API 不支持向已提交任务追加。

### 4.3 重试的 token 浪费要度量

```java
double wastedRatio = (double) retriedTokens / totalTokens;   // 目标 < 5%
```

超过 10% 说明请求构造有系统性问题（常见：单条超长、`max_tokens` 太小导致截断被判失败、JSON 模式与 prompt 冲突）。

## 五、容量与调度：别让离线任务打爆在线配额

大多数厂商的 Batch 与同步 API **共享组织的 TPM/RPM 配额**（部分厂商有独立 Batch 配额，需确认）。设计原则：

1. **配额分区**：在线链路独立 API Key / 独立项目，Batch 用另一个，避免互相挤占。
2. **错峰**：Batch 提交放在业务低峰（如凌晨 1~5 点），大分片在窗口前期提交，给 24h 留余量。
3. **分片大小与并发 job 数**：并发 4~8 个 job、单片 5 万条，是「吞吐 / 失败影响面」的平衡点——单片太大，失败了重跑贵；太小，管理开销大。
4. **优先级队列**：业务紧急的（如当日要出的报表）走同步 + 并发，不排 Batch 队。

一个容量估算示例：

```
目标：8 小时内处理 200 万条
单片 5 万条 → 40 个分片
并发 8 个 job → 5 轮
单 job 平均 45 分钟 → 5 × 45min ≈ 3.75h  ✅ 有 2 倍余量
```

## 六、选型：Batch API / 自建离线推理 / 小模型微调

| 方案 | 单位成本 | 启动成本 | 弹性 | 适用 |
|---|---|---|---|---|
| 同步 API | 1.0× | 0 | 高 | 实时、小批量 |
| **Batch API** | **0.5×** | 低 | 高（有 24h 窗口） | **十万~千万级、可延迟** |
| 自建 vLLM 离线 | 0.1~0.3× | 高（GPU + 运维） | 低 | 稳定大规模、有 GPU 团队 |
| 小模型微调 | 0.05~0.15× | 中（标注 + 训练） | 高 | 任务单一、质量可验证 |
| 规则 + 模型分级 | 0.02~0.1× | 中 | 高 | 高确定性场景 |

决策树：

```
单次任务量 < 1 万条？
  └─ 是 → 同步 API + 并发（Batch 的编排成本不划算）
  └─ 否 → 可延迟 24h？
        ├─ 是 → 有 GPU 团队且月消耗 > $5k？
        │        ├─ 是 → 自建 vLLM 离线（配 Batch 兜底峰值）
        │        └─ 否 → Batch API
        └─ 否 → 同步 + 缓存 + 小模型分流
```

## 七、观测：五个必须上报表的指标

| 指标 | 定义 | 告警阈值 |
|---|---|---|
| 完成率 | `SUCCEEDED / 总条目` | < 95% |
| 过期率 | `EXPIRED / 总条目` | > 1% |
| 单条成本 | `cost_usd / SUCCEEDED` | 环比上涨 > 20% |
| 端到端时延 | 提交 → 落库完成 | > 窗口的 70% |
| 重试 token 占比 | `retried_tokens / total_tokens` | > 10% |

再加一个业务侧的**抽样质量指标**：每天从成功结果里随机抽 200 条人工/LLM 复核，准确率跌破基线就暂停任务。**成本优化最大的风险不是多花钱，而是省了钱但结果全错，还没人发现。**

## 八、面试/设计追问

**Q1：设计一个百万级文档打标系统，怎么控制成本？**

四层：① 规则/小模型预筛，只把难例送大模型；② 大模型走 Batch（五折 + 24h 窗口）；③ Prompt 前缀稳定以命中缓存；④ 输出用 JSON 短字段，`max_tokens` 卡死。再加幂等与对账，保证重跑不重复计费。

**Q2：Batch 任务 24 小时没跑完怎么办？**

先看状态：`expired` 说明排队超窗口，根因通常是分片太大或提交时间太晚。处置：缩小分片（如 1 万条/片）、增加并发 job 数、把提交时间提前到低峰起点。同时对 `expired` 条目重新打包提交，并在对账表里记录重试次数。

**Q3：怎么保证不重复计费、不重复写库？**

提交层唯一键（业务 + prompt 版本 + 分片号）防重复提交；条目层 `custom_id` 由 `sha1(biz_key + prompt_version)` 生成，天然去重；落库层按 `biz_key` upsert。三层任一层生效都不会产生重复数据，全生效才是「最坏情况也不出错」。

**Q4：结果文件顺序和输入不一致，怎么对账？**

只能按 `custom_id` 匹配，绝不能按行号。工程上先把该 job 的所有 item 按 `custom_id` 加载成 `Map`，再逐行消费 output/error 文件，最后把「两个文件都没出现」的条目标记为 `EXPIRED`。

**Q5：Batch 和「异步任务队列 + 同步 API」有什么区别？**

后者是你自己实现异步（提交到 MQ，worker 调同步 API），成本还是同步价，但延迟可控（分钟级）；Batch 是厂商侧的离线调度，成本五折但延迟以小时计、且有 24h 窗口风险。**要便宜选 Batch，要可控选自建异步。**

## 九、总结

- Batch API 的本质是「用延迟换价格」，五折是基线，叠加缓存/裁剪/小模型分流可到 0.1×。
- 协议形态统一为「JSONL 进、文件出」，但有六个硬约束：文件大小、条数、24h 窗口、`custom_id` 字符集、结果乱序、文件有效期。
- Java 侧的核心不是调 SDK，而是**状态机外置 + 三层幂等 + 按 id 对账 + 失败分类重试**。
- 最容易漏的两件事：不解析 `error_file_id`（数据黑洞）、不设 `max_tokens`（成本跑飞）。
- 观测五指标：完成率、过期率、单条成本、端到端时延、重试 token 占比，再加一个质量抽样。

把离线批量这条链路做扎实，LLM 应用的成本曲线才会从「随用量线性上涨」变成「随规模边际递减」——这也是 AI 应用能不能真正规模化的分水岭。
