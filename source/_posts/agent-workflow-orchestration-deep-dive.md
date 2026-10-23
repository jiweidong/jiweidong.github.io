---
title: 【AI Agent】智能体工作流编排深度解析：DAG、状态机与人工介入
date: 2026-10-23 08:40:00
tags:
  - AI
  - Agent
  - 工作流
  - 编排
  - 系统设计
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】智能体工作流编排深度解析：DAG、状态机与人工介入

## 前言

刚开始做 Agent，大家都是这么写的：

```java
while (!done) {
    response = llm.chat(messages, tools);
    if (response.hasToolCalls()) {
        results = executeTools(response.toolCalls());
        messages.addAll(results);
    } else {
        done = true;
    }
}
```

一个 `while` 循环，看起来很优雅。上线之后你会发现：

- 有的请求跑了 40 轮还没停，烧了 20 万 token；
- 第 3 步工具失败了，只能整条重跑；
- 用户等了 90 秒，产品经理要求「中间结果先展示」；
- 出了事故要复盘，但你不知道它当时到底走了哪条路径；
- 合规要求高风险操作必须人工确认，你没地方插这个「确认」。

这些问题**不是 Prompt 能解决的**，它们是编排问题。自由 Agent 循环适合探索，不适合生产。生产环境需要的是：**可预测的路径、可恢复的状态、可插入的人工节点、可回放的过程。**

这篇文章讲清三种编排范式（自由循环 / DAG / 状态机）的边界、Java 落地的编排引擎设计、human-in-the-loop 的正确实现，以及生产上的坑。

---

## 一、三种范式：先想清楚你要哪一种

| 维度 | 自由 Agent（ReAct 循环） | DAG 工作流 | 状态机（长事务） |
|---|---|---|---|
| 路径确定性 | 无（完全由模型决定） | 高（图结构固定） | 高（状态转移固定） |
| 灵活性 | 最高 | 中 | 低 |
| 可预测成本 | ❌ 不可控 | ✅ 可估算 | ✅ 可估算 |
| 可恢复性 | 难（要重放整个对话） | 中（可从节点重跑） | 高（状态持久化） |
| 人工介入 | 难插入 | 容易（加一个节点） | 天然支持（等待状态） |
| 可观测性 | 只有 trace | 节点级 | 状态级 |
| 适用场景 | 研究、开放探索、简单问答 | 大多数生产流程 | 长周期、跨天、需审批 |

**经验法则**：

- 如果业务流程**画得出来**，就用 DAG；
- 如果流程里有**等待人**、**等待外部事件**、**跨小时/跨天**，就用状态机；
- 只有在「你确实不知道下一步该干什么」时，才用自由 Agent，而且要**给它加上限**（最大轮数、最大 token、超时）。

实际生产系统往往是三者的组合：

```
DAG（外层骨架）
 ├─ 节点1：LLM 信息抽取
 ├─ 节点2：并行检索（向量库 + 关键词）
 ├─ 节点3：自由 Agent（负责"根据检索结果做多步推理"，有轮数上限）
 ├─ 节点4：人工审批（状态机，等待外部事件）
 └─ 节点5：LLM 生成最终答复
```

---

## 二、DAG 编排：把 Agent 拆成可运维的节点

### 2.1 节点类型设计

一个够用的节点模型只需要 6 种：

| 类型 | 作用 | 输入 | 输出 |
|---|---|---|---|
| `LlmNode` | 单次 LLM 调用 | 上下文变量 | 文本/结构化结果 |
| `ToolNode` | 调用一个工具/API | 参数（来自上下文） | 工具结果 |
| `ConditionNode` | 条件分支 | 上下文 | 下一节点 id |
| `ParallelNode` | 并行分支 | — | 汇聚结果 |
| `HumanNode` | 人工审批/补充 | 待审内容 | 审批结果 |
| `SubgraphNode` | 嵌套子图 | 上下文 | 子图输出 |

### 2.2 数据结构

```java
public sealed interface Node permits LlmNode, ToolNode, ConditionNode, ParallelNode, HumanNode {

    String id();

    /** 执行节点，返回输出变量与下一个节点（null 表示按出边自动流转） */
    NodeResult execute(WorkflowContext ctx) throws NodeException;

    /** 超时（毫秒），0 表示不限制 */
    default long timeoutMs() { return 60_000; }

    /** 失败重试策略 */
    default RetryPolicy retryPolicy() { return RetryPolicy.none(); }
}

public record LlmNode(
        String id,
        String model,
        String promptTemplate,
        Set<String> inputVars,
        String outputVar,
        int maxRetries
) implements Node { /* ... */ }

public record ToolNode(
        String id,
        String toolName,
        Map<String, String> argTemplates,   // 支持 ${var} 占位
        String outputVar,
        boolean idempotent                   // 是否可安全重试
) implements Node { /* ... */ }

public record HumanNode(
        String id,
        String title,
        String description,
        String payloadVar,
        Duration timeout,
        String outputVar
) implements Node { /* ... */ }
```

### 2.3 执行引擎：拓扑排序 + 层内并行

DAG 执行的核心是「按依赖分层，层内并行」：

```java
@Component
public class DagExecutor {

    private final NodeRegistry registry;
    private final CheckpointStore checkpointStore;
    private final ExecutorService ioPool =
            Executors.newVirtualThreadPerTaskExecutor();   // JDK 21+

    public WorkflowResult execute(WorkflowDef def, WorkflowContext ctx, String runId) {
        Map<String, NodeState> states = checkpointStore.loadOrInit(runId, def);

        List<List<String>> layers = topoSort(def);   // 分层
        for (List<String> layer : layers) {
            // 跳过已完成节点（断点续跑）
            List<String> pending = layer.stream()
                    .filter(id -> states.get(id).status() != Status.SUCCESS)
                    .toList();
            if (pending.isEmpty()) continue;

            List<Future<NodeResult>> futures = pending.stream()
                    .map(id -> ioPool.submit(() -> runNode(def.node(id), ctx, runId)))
                    .toList();

            for (int i = 0; i < futures.size(); i++) {
                String nodeId = pending.get(i);
                try {
                    NodeResult r = futures.get(i).get(
                            def.node(nodeId).timeoutMs(), TimeUnit.MILLISECONDS);
                    ctx.putAll(r.outputs());
                    states.put(nodeId, NodeState.success(r.outputs()));
                    checkpointStore.save(runId, nodeId, states.get(nodeId));
                } catch (TimeoutException e) {
                    futures.get(i).cancel(true);
                    states.put(nodeId, NodeState.failed("timeout"));
                    return WorkflowResult.failed(nodeId, "节点超时");
                } catch (Exception e) {
                    // 失败策略：重试 / 跳过 / 终止
                    if (!handleFailure(def, nodeId, ctx, states, e)) {
                        return WorkflowResult.failed(nodeId, e.getMessage());
                    }
                }
            }
        }
        return WorkflowResult.success(ctx);
    }
}
```

三个关键设计点：

**① 用虚拟线程跑 IO 密集节点。** LLM 调用、HTTP 工具调用全是阻塞 IO，平台线程池会被打满。JDK 21 的虚拟线程让「一个节点一个线程」变得廉价，代码是同步写法，心智负担为零。注意不要用 `synchronized` 包裹阻塞调用（会导致 pinning）。

**② 每个节点完成后立刻 checkpoint。** 这是「断点续跑」的基础。没有 checkpoint，第 8 个节点失败就要从第 1 个重跑，成本和时间都不可接受。

**③ 层内并行不等于全部并行。** 有些节点虽然在同一层，但会争抢同一个资源（比如同一个数据库连接池、同一个限流配额）。工程上要给节点打 `resourceGroup` 标签，同组内串行。

### 2.4 上下文（Context）管理

最容易被忽视、也最容易爆内存的部分。

```java
public class WorkflowContext {
    private final Map<String, Object> vars = new ConcurrentHashMap<>();
    private final Map<String, Integer> tokenUsage = new ConcurrentHashMap<>();
    private final int maxTotalTokens;

    public void put(String key, Object value) {
        // 大对象（如完整文档）只存引用，不存内容
        if (value instanceof String s && s.length() > 20_000) {
            String ref = blobStore.save(s);          // 存对象存储
            vars.put(key, new BlobRef(ref, s.length()));
        } else {
            vars.put(key, value);
        }
    }
}
```

**上下文不是越大越好。** 每个节点只应该拿到它声明的 `inputVars`，而不是整个上下文。否则：

- Prompt 越来越长，成本线性上升；
- 无关信息干扰模型判断；
- 前面节点的错误被无限传播。

```java
// ✅ 只注入声明的变量
Map<String, Object> input = node.inputVars().stream()
        .filter(ctx::has)
        .collect(Collectors.toMap(Function.identity(), ctx::get));
```

---

## 三、状态机编排：长周期与人工介入的正确姿势

DAG 有个根本限制：**它是「一次执行」的模型**。一旦需要「停下来等三天」，DAG 就跑不下去了——你不能让一个线程挂三天。

状态机模型换个思路：**把「执行」变成「状态转移」，每次转移都是一次短事务。**

### 3.1 状态与事件

```
         ┌──────────┐
         │  CREATED │
         └────┬─────┘
              │ START
              ▼
       ┌─────────────┐  TOOL_FAILED   ┌──────────┐
       │  EXECUTING  │ ──────────────►│ RETRYING │
       └──────┬──────┘                └────┬─────┘
              │ NEED_APPROVAL               │ RETRY
              ▼                             └──────► EXECUTING
      ┌────────────────┐
      │ WAITING_HUMAN  │  APPROVED
      └───────┬────────┘ ─────────────► EXECUTING
              │ REJECTED
              ▼
        ┌──────────┐         COMPLETED
        │ REJECTED │      ┌──────────┐
        └──────────┘      │ COMPLETED│
                          └──────────┘
```

### 3.2 状态持久化表结构

```sql
CREATE TABLE agent_workflow_instance (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,
    run_id          VARCHAR(64)  NOT NULL UNIQUE,
    workflow_key    VARCHAR(128) NOT NULL,
    workflow_version INT         NOT NULL,
    current_state   VARCHAR(64)  NOT NULL,
    context_json    JSON         NOT NULL,
    node_states_json JSON        NOT NULL,
    tenant_id       VARCHAR(64)  NOT NULL,
    created_at      DATETIME(3)  NOT NULL,
    updated_at      DATETIME(3)  NOT NULL,
    expire_at       DATETIME(3)  NULL,
    KEY idx_state (current_state, updated_at),
    KEY idx_tenant (tenant_id, created_at)
);

CREATE TABLE agent_workflow_event (
    id          BIGINT PRIMARY KEY AUTO_INCREMENT,
    run_id      VARCHAR(64) NOT NULL,
    event_type  VARCHAR(64) NOT NULL,
    payload     JSON        NULL,
    created_at  DATETIME(3) NOT NULL,
    KEY idx_run (run_id, id)
);
```

**为什么要单独一张事件表？** 因为「当前状态」只告诉你「现在在哪」，而「事件流」告诉你「怎么走到这里的」。排查线上问题时，后者比前者有用一百倍。

### 3.3 转移的幂等性

状态机的每一次转移都必须是**幂等**的，因为：

- 消息可能重复投递；
- 回调可能重试；
- 用户可能连点两次「同意」。

```java
@Transactional
public boolean transit(String runId, String event, String expectedState, Map<String, Object> payload) {
    // 乐观锁 + 状态校验，一条 SQL 完成原子转移
    int updated = jdbc.update("""
            UPDATE agent_workflow_instance
               SET current_state = ?, context_json = ?, updated_at = NOW(3), version = version + 1
             WHERE run_id = ? AND current_state = ? AND version = ?
            """, nextState(event), toJson(payload), runId, expectedState, version);

    if (updated == 0) {
        // 状态已变或并发冲突：要么是重复事件（幂等返回），要么是非法转移（报错）
        WorkflowInstance cur = load(runId);
        if (cur.currentState().equals(nextState(event))) {
            return true;      // 幂等：已经在目标状态
        }
        throw new IllegalStateTransitionException(runId, expectedState, event);
    }
    eventStore.append(runId, event, payload);
    return true;
}
```

**核心是 `WHERE current_state = ? AND version = ?`**，用数据库的原子性保证「只有一个执行者能完成这次转移」。这比分布式锁更简单、更可靠。

### 3.4 超时与补偿

长期等待的流程必须有超时兜底：

```java
@Scheduled(fixedDelay = 60_000)
public void scanTimeout() {
    List<WorkflowInstance> expired = jdbc.query("""
            SELECT * FROM agent_workflow_instance
             WHERE current_state = 'WAITING_HUMAN'
               AND updated_at < DATE_SUB(NOW(), INTERVAL 72 HOUR)
             LIMIT 500
            """, mapper);

    for (WorkflowInstance inst : expired) {
        // 超时不等于失败：可以走"默认批准"或"自动拒绝 + 通知"
        transit(inst.runId(), "TIMEOUT", "WAITING_HUMAN",
                Map.of("action", "AUTO_REJECT", "reason", "审批超时"));
        notifier.notifyOwner(inst);
    }
}
```

**超时策略要按业务定**：

| 场景 | 超时策略 |
|---|---|
| 低风险操作（改文案） | 超时自动批准 |
| 中风险（退款 < 500 元） | 超时升级到上级审批 |
| 高风险（删除数据、转账） | 超时自动拒绝 |
| 合规场景 | 超时拒绝 + 记录审计 |

---

## 四、Human-in-the-loop：不是加个弹窗那么简单

人工介入是 Agent 落地企业场景的**硬门槛**。但绝大多数实现都有问题。

### 4.1 四个必须解决的问题

| 问题 | 错误做法 | 正确做法 |
|---|---|---|
| 等待期间资源占用 | 线程阻塞等 | 持久化状态 + 外部事件唤醒 |
| 审批内容不完整 | 只给一句「是否同意」 | 给「原始输入 + 中间结果 + 拟执行动作 + 影响范围」 |
| 超时无兜底 | 永远挂着 | 分级超时策略 |
| 无法撤回 | 审批即执行 | 审批与执行分离，中间留可撤销窗口 |

### 4.2 审批卡片应该包含什么

这是产品体验问题，但工程上要保证数据可得：

```java
public record ApprovalPayload(
        String title,                 // "退款审批：订单 #12345"
        String reason,                // Agent 为什么要做这个操作
        List<Evidence> evidences,     // 支撑证据（检索到的政策条款、订单详情）
        List<PlannedAction> actions,  // 将要执行的具体动作（可展示 diff）
        RiskAssessment risk,          // 金额、不可逆性、影响用户数
        List<String> alternatives     // 可选的其他处理方式
) {}
```

**关键在 `PlannedAction` 要能展示「diff」**：不是「将更新订单状态」，而是「订单状态：`PAID` → `REFUNDING`；退款金额：¥299.00；库存：`+1`」。人工审批的价值在于「能判断」，而判断需要具体信息。

### 4.3 实现：不阻塞线程的等待

```java
public class HumanApprovalService {

    /** 发起审批：落库 + 推送，立刻返回 */
    public void requestApproval(String runId, ApprovalPayload payload) {
        jdbc.update("""
                INSERT INTO agent_approval (run_id, payload_json, status, created_at, expire_at)
                VALUES (?, ?, 'PENDING', NOW(3), DATE_ADD(NOW(3), INTERVAL ? HOUR))
                """, runId, toJson(payload), payload.timeoutHours());

        // 推送给人（IM / 邮件 / 工单系统），不阻塞
        notifier.push(payload.assignee(), payload);
    }

    /** 人工操作回调：幂等 */
    @Transactional
    public void decide(String approvalId, Decision decision, String operator, String comment) {
        int updated = jdbc.update("""
                UPDATE agent_approval
                   SET status = ?, operator = ?, comment = ?, decided_at = NOW(3)
                 WHERE id = ? AND status = 'PENDING'
                """, decision.name(), operator, comment, approvalId);

        if (updated == 0) {
            // 已被处理过：幂等返回，不重复推进工作流
            log.info("审批已被处理，忽略重复回调 approvalId={}", approvalId);
            return;
        }
        // 幂等成功后，才推进状态机
        workflowEngine.transit(runIdOf(approvalId),
                decision == Decision.APPROVE ? "APPROVED" : "REJECTED",
                "WAITING_HUMAN", Map.of("operator", operator));
    }
}
```

**注意顺序**：先原子更新审批单（唯一性保证），成功后才推进工作流。反过来会导致「工作流推进两次」。

### 4.4 审批疲劳

这是最容易被忽视的产品问题。如果 Agent 每一步都要人确认，人会开始无脑点「同意」——**审批就失去了意义，还增加了延迟**。

治理手段：

| 手段 | 做法 |
|---|---|
| 风险分级 | 只有高风险才强制人工，低风险自动执行 + 事后审计 |
| 批量审批 | 同类低风险操作合并成一条「批量同意 20 条」 |
| 信任累积 | 同一 Agent 在同一场景连续 N 次正确 → 提升自动执行额度 |
| 抽样复核 | 自动执行的操作按 5% 抽样人工复核 |
| 明确边界 | 用规则（金额、数据范围、可逆性）而不是模型判断是否需要审批 |

**最后一条最重要**：**「是否需要人工审批」必须由确定性规则决定，不能交给 LLM 判断。** 让模型自己说「这个操作很危险，请人工确认」，等于让它既当运动员又当裁判。

---

## 五、可观测：编排系统的生命线

Agent 工作流的调试难度远高于普通服务，因为「同样的输入可能走出不同的路径」。必须做到**全链路可回放**。

### 5.1 必须记录的四类数据

| 数据 | 内容 | 用途 |
|---|---|---|
| 节点执行记录 | nodeId、输入 hash、输出、耗时、token、模型 | 定位哪个节点慢/贵/错 |
| LLM 调用详情 | prompt 全文、response 全文、工具调用、finish_reason | 复盘模型决策 |
| 状态转移日志 | from → to、触发事件、操作者 | 排查流程卡住 |
| 成本归因 | 按 run / 节点 / 租户聚合 token | 成本治理 |

### 5.2 Trace 结构

```
run_id = r-8f3a...
├── span: workflow.execute (总耗时 42.3s, cost 12,400 tokens)
│   ├── span: node.extract (2.1s, 800 tokens)
│   ├── span: node.retrieve (0.4s, 0 tokens)
│   ├── span: node.reason_agent (28.7s, 9,200 tokens, 6 rounds)
│   │   ├── span: llm.call#1
│   │   ├── span: tool.call#1 (search_order)
│   │   ├── span: llm.call#2
│   │   └── ...
│   ├── span: node.approval (waiting 8m12s)
│   └── span: node.generate (3.0s, 2,400 tokens)
```

接 OpenTelemetry 的话，`run_id` 作为 traceId，每个节点一个 span，LLM 调用的 token 数作为 span attribute。这样在 Jaeger/Tempo 里可以直接看到「哪一步最贵」。

### 5.3 三个关键告警

| 告警 | 阈值 | 含义 |
|---|---|---|
| 单 run token 超限 | > 50k | 死循环或上下文失控 |
| 单 run 时长超限 | > 5min（非等待态） | 卡住 |
| 工具失败率 | > 10% | 下游故障 |
| 同一节点重试次数 | > 3 | 该节点设计有问题 |

---

## 六、和成熟框架怎么选

| 方案 | 类型 | 优势 | 劣势 | 适用 |
|---|---|---|---|---|
| 自研 DAG 引擎 | DAG | 完全可控、轻量 | 要自己写持久化/重试/监控 | 流程稳定、团队有工程能力 |
| Spring AI + 自研编排 | DAG | 与 Java 栈无缝 | 同上 | Java 团队首选 |
| LangChain4j AiServices | 轻编排 | 上手快 | 复杂流程表达力弱 | 简单多步 Agent |
| Temporal | 状态机/工作流 | 持久化、重试、定时器极强 | 学习曲线陡、要跑集群 | 长周期、高可靠要求 |
| Camunda / Flowable | BPMN | 可视化、审批流成熟 | 与 LLM 集成要自己写 | 重审批的业务流程 |
| Airflow / Dagster | 数据 DAG | 调度成熟 | 面向批处理，不适合在线请求 | 离线数据处理 |

**我的建议**：

- 在线、低延迟（< 30s）、流程固定的 → **自研 DAG**（几百行代码就够）；
- 需要等待人/等待外部事件、跨小时跨天 → **Temporal** 或**自研状态机 + 数据库**；
- 已经是 BPMN 体系的公司 → **Flowable**，在 ServiceTask 里调 LLM；
- 不要为了「看起来专业」上 Temporal，运维成本是真实的。

---

## 七、生产踩坑清单

| 坑 | 现象 | 修复 |
|---|---|---|
| 无最大轮数限制 | 单次请求 40 轮，烧 20 万 token | `maxRounds` + `maxTokens` + 超时三重限制 |
| 全量上下文透传 | prompt 越来越长，成本线性涨 | 节点声明 `inputVars`，只注入需要的 |
| 无 checkpoint | 第 8 步失败从头重跑 | 每节点完成即持久化 |
| 工具不幂等却重试 | 重复扣款、重复下单 | 工具打 `idempotent` 标记，非幂等不自动重试 |
| 并行节点争抢资源 | 连接池耗尽 | 节点打 `resourceGroup`，组内串行 |
| 审批阻塞线程 | 线程池打满 | 持久化 + 事件唤醒 |
| 审批单重复处理 | 工作流推进两次 | 审批单 `WHERE status='PENDING'` 原子更新 |
| 状态转移竞态 | 两个回调同时推进 | 乐观锁 `version` |
| 无法回放 | 出事故查不出原因 | 落库 prompt/response/事件流 |
| 版本升级破坏在途流程 | 老 run 跑到新节点上报错 | `workflow_version` 固定，在途流程走老版本定义 |

**最后一条特别容易被忽略**：工作流定义是会迭代的，但在途的 run 必须继续用**它启动时的版本**执行。否则你改了一个节点 id，三天前启动、还在等审批的 run 恢复时就会 `NullPointerException`。`workflow_version` 必须进 run 的元数据。

---

## 八、面试高频追问

**Q1：什么时候用 DAG，什么时候用状态机？**
答：看「执行是否需要跨越长时间等待」。DAG 是一次执行的模型，适合同步/短异步流程（秒级到分钟级）；状态机把执行拆成多次短事务，适合需要等待人、等待外部事件、跨小时跨天的流程。实践中常见的是「DAG 内嵌状态机节点」：整体流程用 DAG，审批节点用状态机实现。

**Q2：Agent 死循环怎么防？**
答：四层防护——① 最大轮数（通常 10–15）；② 最大 token 预算（按 run 累计）；③ 墙钟超时；④ 重复检测（连续两轮工具调用参数完全相同则强制终止）。第四层最有效，因为死循环往往表现为「反复调同一个工具、同样的参数」。

**Q3：为什么不能让 LLM 自己决定是否需要人工审批？**
答：因为审批是安全控制点，控制点不能由被控制对象决定。模型可能被 prompt 注入影响，也可能判断失误。正确做法是用确定性规则（金额阈值、数据范围、操作可逆性、是否涉及 PII）决定，模型只负责提供审批所需的上下文。

**Q4：工作流恢复时怎么保证不重复执行已完成的节点？**
答：两层保证。① 节点完成即写 checkpoint，恢复时跳过 `status=SUCCESS` 的节点；② 节点本身要幂等（工具调用带幂等键，写操作带唯一约束），因为「完成但 checkpoint 未写入」的窗口无法完全消除，只能靠幂等兜底。

**Q5：并行节点怎么处理部分失败？**
答：三种策略，按业务选——① `ALL_OR_NOTHING`：任一失败则整体失败（适合强一致场景）；② `BEST_EFFORT`：失败节点输出 null，继续执行（适合补充信息类，如「多路检索」）；③ `QUORUM(n)`：成功数达到 n 即继续（适合投票类）。策略必须在节点上显式声明，不能全局默认。

**Q6：为什么用数据库乐观锁而不是分布式锁做状态转移？**
答：因为状态转移本身就是一次数据库写操作，把「校验 + 更新」放在同一条 `UPDATE ... WHERE state=? AND version=?` 里，天然原子，无需额外组件。分布式锁要处理锁超时、锁续期、锁误删，复杂度高且引入新的故障点。只有在「转移涉及多个外部副作用」时才需要分布式锁或事务消息。

**Q7：Agent 工作流的成本怎么控？**
答：四个手段——① 节点级 token 预算（超了降级到小模型或截断）；② 缓存（相同子问题复用，尤其工具调用结果）；③ 模型路由（简单节点用便宜模型）；④ 上下文裁剪（只传必要变量）。其中「上下文裁剪」收益最大，因为成本几乎线性于输入长度。

---

## 九、总结

用一张表收尾：

| 你遇到的问题 | 说明你缺什么 |
|---|---|
| 成本不可控、动不动跑几十轮 | 缺上限（轮数/token/超时） |
| 失败就整条重跑 | 缺 checkpoint |
| 不知道它为什么这么答 | 缺节点级 trace |
| 高风险操作不敢放给它 | 缺 human-in-the-loop |
| 上线后改流程，在途任务全挂 | 缺 workflow_version |
| 审批变成无脑点同意 | 缺风险分级与批量审批 |

**核心认知的转变**：从「我要让 Agent 更聪明」，转到「我要让 Agent 的行为可预测、可恢复、可审计」。前者是模型能力问题，后者是工程问题。而在生产环境里，**后者决定了你能不能上线**。

自由 Agent 循环是原型工具，DAG 和状态机才是生产工具。三者不是替代关系，而是分层关系：外层用 DAG 保证流程可控，内层用自由 Agent 处理不确定性，关键节点用状态机等待人与事件。把这三层拼对了，Agent 才真正从 demo 变成系统。
