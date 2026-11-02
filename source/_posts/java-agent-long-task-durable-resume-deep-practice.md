---
title: 【Java AI】Agent 长任务与断点续跑深度实战：检查点、确定性重放与幂等恢复
date: 2026-11-02 08:00:00
tags:
  - Java
  - AI
  - Agent
  - 持久化执行
  - 断点续跑
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Agent 长任务与断点续跑深度实战

## 前言

做一个 Demo Agent 很容易：`while (!done) { llm.think(); tool.call(); }`，三十分钟跑通。把它放到生产上处理「帮我调研 20 家供应商并生成比价报告」这种任务，问题立刻显现：

- 任务跑了 8 分钟，第 14 步时模型 API 返回 429，整个任务需要重来；
- 进程因为发布重启，运行中的 30 个任务全部丢失；
- 用户在审批节点点了「拒绝」，Agent 不知道该怎么回退，只能报错；
- 重跑时模型温度不同，之前调用的工具结果全变了，生成了一份完全不同的报告。

这些问题的共同点是：**Agent 的执行过程没有任何持久化，它是「一次性的内存计算」**。而真实的 Agent 任务本质上是**长事务**——持续几分钟到几小时，涉及外部副作用（发邮件、下单、写库），必须支持中断、恢复、补偿。

这正是「持久化执行（Durable Execution）」要解决的问题。Temporal、Cadence、Restate 这类产品把它做成了基础设施，但在 Java 团队里，用 Spring Boot + MySQL 实现一套「够用的」检查点机制，往往比引入新中间件更现实。

本文讲清楚三件事：Agent 长任务的故障模型、检查点机制的设计、以及一套可直接落地的 Java 实现。

## 一、Agent 长任务的四类故障

先把故障分类，才能设计对应的恢复策略：

| 故障类型 | 典型场景 | 是否可重试 | 恢复策略 |
|---|---|---|---|
| **瞬时故障** | LLM 429/503、网络抖动、工具超时 | ✅ 可重试 | 指数退避重试，同一 step 内 |
| **进程故障** | 发布重启、OOM、机器宕机 | ✅ 换实例重跑 | 从最近 checkpoint 恢复 |
| **业务失败** | 工具返回「库存不足」、模型判定无法完成 | ❌ 不重试 | 进入失败终态，或走补偿分支 |
| **人工中断** | 审批拒绝、超时未审、用户取消 | ⚠️ 视策略 | 挂起等待信号，或回滚 |

关键认知：**只有「瞬时故障」和「进程故障」能靠重试解决**。业务失败必须显式建模为状态转移，人工中断必须有一等公民的「等待态」。绝大多数 Agent 框架只处理了第一类，然后在第二类上丢任务、在第三、四类上直接崩。

## 二、持久化执行的三要素

任何 durable execution 系统，无论 Temporal 还是自研，都建立在三个机制上：

### 2.1 事件日志（Event Log）

不存「最终状态」，存「导致状态变化的事件序列」：

```
TaskStarted(taskId, plan)
StepScheduled(stepId=1, type=LLM_CALL, input={...})
StepCompleted(stepId=1, output={...}, tokens=1203)
StepScheduled(stepId=2, type=TOOL_CALL, tool=searchSupplier)
StepFailed(stepId=2, error=RATE_LIMIT, attempt=1)
StepCompleted(stepId=2, output={...}, attempt=2)
ApprovalRequested(stepId=3, approver=u100)
...
```

事件日志是 append-only 的，天然支持审计和回放。相比「直接存当前状态」，它多了一个能力：**你能精确知道任务是怎么走到这一步的**——这在 Agent 场景里极其重要，因为排查「模型为什么做了这个决策」需要的正是完整轨迹。

### 2.2 确定性重放（Deterministic Replay）

恢复时，系统重放事件日志，重建内存状态，然后从断点继续。这要求**重放过程必须是确定性的**：

- 时间：用日志里记录的时间戳，不能用 `System.currentTimeMillis()`
- 随机数：用日志里记录的种子或结果
- **LLM 调用**：用日志里记录的**响应快照**，绝不能重新调用（否则结果不同）
- 工具调用：同理，用记录的结果

这是自研方案最容易翻车的地方。很多人以为「恢复 = 从第 N 步重新跑」，结果第 N 步的 LLM 调用产生了不同输出，整个后续计划失效。

### 2.3 幂等副作用（Idempotent Side Effects）

外部副作用必须幂等，因为恢复可能导致同一 step 执行两次（至少一次语义）。三种实现方式：

```java
// 方式一：幂等键 + 唯一索引（推荐）
INSERT INTO payment_order (biz_key, ...) VALUES ('task-123-step-5', ...)
ON DUPLICATE KEY UPDATE updated_at = NOW();

// 方式二：状态前置检查
if (order.getStatus() == PAID) return order;   // 已支付，直接返回

// 方式三：两阶段（预占 + 确认），配合超时回滚
```

## 三、架构设计：Plan → Step → Checkpoint

一个可落地的 Agent 长任务架构如下：

```
┌─────────────────────────────────────────────────┐
│  AgentTaskRunner（调度器，可水平扩展）             │
│    ├─ 拉取 RUNNABLE 任务（乐观锁抢占）             │
│    ├─ 加载 checkpoint → 重建上下文                │
│    └─ 逐步执行 → 每步落库 → 判断是否继续           │
└─────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────┐
│  agent_task（任务主表）                          │
│  agent_step（步骤表，append-only 事件日志）       │
│  agent_checkpoint（快照表，加速恢复）             │
└─────────────────────────────────────────────────┘
```

**为什么既要有 step 日志又要有 checkpoint？**

- step 日志是「事实来源」，完整但重放慢（几百步时要读几百行）；
- checkpoint 是「物化视图」，每 N 步存一次完整上下文，恢复时从最近的 checkpoint + 后续 step 增量重放。

这是数据库 WAL + checkpoint 的同构设计，成熟且有效。

### 3.1 表结构

```sql
CREATE TABLE agent_task (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,
    task_id         VARCHAR(64)  NOT NULL,
    task_type       VARCHAR(64)  NOT NULL,
    goal            TEXT         NOT NULL,
    status          ENUM('PENDING','RUNNING','WAITING_APPROVAL','FAILED','DONE','CANCELED') NOT NULL,
    plan_json       JSON         NULL,
    current_step    INT          NOT NULL DEFAULT 0,
    version         INT          NOT NULL DEFAULT 0,      -- 乐观锁
    lease_owner     VARCHAR(64)  NULL,                    -- 抢占者实例 ID
    lease_until     DATETIME(3)  NULL,                    -- 租约到期时间
    retry_count     INT          NOT NULL DEFAULT 0,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_task_id (task_id),
    KEY idx_status_lease (status, lease_until)
) ENGINE=InnoDB;

CREATE TABLE agent_step (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,
    task_id         VARCHAR(64)  NOT NULL,
    step_no         INT          NOT NULL,
    step_type       VARCHAR(32)  NOT NULL,   -- LLM_CALL / TOOL_CALL / DECISION / APPROVAL
    input_json      JSON         NOT NULL,
    output_json     JSON         NULL,
    status          ENUM('STARTED','SUCCEEDED','FAILED') NOT NULL,
    attempt         INT          NOT NULL DEFAULT 1,
    error_code      VARCHAR(64)  NULL,
    duration_ms     INT          NULL,
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_task_step_attempt (task_id, step_no, attempt),
    KEY idx_task (task_id, step_no)
) ENGINE=InnoDB;

CREATE TABLE agent_checkpoint (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,
    task_id         VARCHAR(64)  NOT NULL,
    step_no         INT          NOT NULL,
    context_json    JSON         NOT NULL,   -- 消息历史 + 中间产物 + 变量
    created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_task_step (task_id, step_no)
) ENGINE=InnoDB;
```

`uk_task_step_attempt` 这个唯一索引是幂等的第一道防线：同一 step 的同一 attempt 只能写一条，重复执行会直接冲突。

### 3.2 任务抢占：租约 + 乐观锁

多个实例同时跑，必须保证一个任务只被一个实例处理：

```java
@Repository
public class AgentTaskRepository {

    private final JdbcTemplate jdbc;

    /** 抢占任务：租约 + 版本号双重保护 */
    public Optional<AgentTask> acquire(String instanceId, Duration lease) {
        // 1. 先选出候选任务（status=RUNNING 且租约已过期，或 PENDING）
        List<AgentTask> candidates = jdbc.query("""
            SELECT * FROM agent_task
             WHERE status IN ('PENDING','RUNNING')
               AND (lease_until IS NULL OR lease_until < NOW(3))
             ORDER BY updated_at
             LIMIT 10
            """, ROW_MAPPER);

        for (AgentTask t : candidates) {
            // 2. CAS 更新，失败说明被别的实例抢走了
            int updated = jdbc.update("""
                UPDATE agent_task
                   SET lease_owner = ?, lease_until = DATE_ADD(NOW(3), INTERVAL ? SECOND),
                       status = 'RUNNING', version = version + 1
                 WHERE task_id = ? AND version = ?
                   AND (lease_until IS NULL OR lease_until < NOW(3))
                """, instanceId, lease.toSeconds(), t.getTaskId(), t.getVersion());
            if (updated == 1) {
                return Optional.of(t.withVersion(t.getVersion() + 1));
            }
        }
        return Optional.empty();
    }

    /** 续租：长任务每步都要续，否则会被别的实例抢走 */
    public boolean renew(String taskId, String instanceId, Duration lease) {
        return jdbc.update("""
            UPDATE agent_task
               SET lease_until = DATE_ADD(NOW(3), INTERVAL ? SECOND)
             WHERE task_id = ? AND lease_owner = ?
            """, lease.toSeconds(), taskId, instanceId) == 1;
    }
}
```

租约时间要大于「单步最长执行时间」。LLM 调用通常 10~60 秒，工具调用可能 5 分钟，所以租约设 10 分钟比较稳妥，配合每步续租。

## 四、核心执行器：确定性重放

```java
@Component
public class AgentTaskRunner {

    private static final int CHECKPOINT_INTERVAL = 5;

    private final AgentTaskRepository taskRepo;
    private final AgentStepRepository stepRepo;
    private final CheckpointRepository ckptRepo;
    private final LlmClient llm;
    private final ToolRegistry tools;

    public void runOnce(String instanceId) {
        taskRepo.acquire(instanceId, Duration.ofMinutes(10)).ifPresent(task -> {
            try {
                execute(task, instanceId);
            } catch (Exception e) {
                log.error("task {} failed", task.getTaskId(), e);
                taskRepo.markFailed(task.getTaskId(), e.getMessage());
            }
        });
    }

    private void execute(AgentTask task, String instanceId) {
        // ① 恢复上下文：checkpoint + 后续 step 增量重放
        AgentContext ctx = restore(task);

        // ② 从 currentStep 继续
        int stepNo = task.getCurrentStep();
        while (stepNo < ctx.getPlan().size()) {
            // ③ 幂等：该 step 已成功则跳过（恢复场景常见）
            Optional<AgentStep> done = stepRepo.findSucceeded(task.getTaskId(), stepNo);
            if (done.isPresent()) {
                ctx.applyOutput(stepNo, done.get().getOutputJson());
                stepNo++;
                continue;
            }

            // ④ 续租，防止长任务被抢
            if (!taskRepo.renew(task.getTaskId(), instanceId, Duration.ofMinutes(10))) {
                log.warn("lease lost, abort task {}", task.getTaskId());
                return;
            }

            PlanStep step = ctx.getPlan().get(stepNo);
            if (step.requiresApproval() && !ctx.isApproved(stepNo)) {
                taskRepo.markWaitingApproval(task.getTaskId(), stepNo);
                return;   // 挂起，等审批信号唤醒
            }

            // ⑤ 执行并记录（注意：先记 STARTED 再执行，崩溃后可识别「执行中」）
            long stepRowId = stepRepo.start(task.getTaskId(), stepNo, step);
            try {
                StepResult result = dispatch(step, ctx);
                stepRepo.succeed(stepRowId, result);
                ctx.applyOutput(stepNo, result.getOutput());
            } catch (RetryableException e) {
                stepRepo.fail(stepRowId, e.code(), e.getMessage());
                if (++attemptExceeded(stepNo)) {
                    taskRepo.markFailed(task.getTaskId(), "retry exhausted");
                    return;
                }
                continue;   // 同一 step 重试
            }

            // ⑥ 落 checkpoint
            if (stepNo % CHECKPOINT_INTERVAL == 0) {
                ckptRepo.save(task.getTaskId(), stepNo, ctx.snapshot());
            }
            taskRepo.advance(task.getTaskId(), stepNo + 1);
            stepNo++;
        }
        taskRepo.markDone(task.getTaskId());
    }

    /** 恢复：最近 checkpoint + 重放后续成功的 step */
    private AgentContext restore(AgentTask task) {
        AgentContext ctx = ckptRepo.findLatest(task.getTaskId())
                .map(ckpt -> AgentContext.fromJson(ckpt.getContextJson()))
                .orElseGet(() -> AgentContext.fresh(task.getGoal(), task.getPlanJson()));

        int from = ctx.getLastStep() + 1;
        for (AgentStep s : stepRepo.findSucceededAfter(task.getTaskId(), from)) {
            ctx.applyOutput(s.getStepNo(), s.getOutputJson());
        }
        return ctx;
    }
}
```

### 4.1 LLM 调用必须记录响应快照

这是整套机制的核心。**恢复时绝不能重新调模型**：

```java
public StepResult dispatch(PlanStep step, AgentContext ctx) {
    return switch (step.getType()) {
        case LLM_CALL -> {
            // 先查是否已有记录（重放路径）
            Optional<String> recorded = stepRepo.findRecordedOutput(
                    ctx.getTaskId(), step.getNo());
            if (recorded.isPresent()) {
                yield StepResult.of(recorded.get());     // 直接用快照，零成本零漂移
            }
            LlmResponse resp = llm.chat(ctx.buildMessages(step));
            yield StepResult.of(resp.getContent())
                    .withMeta(Map.of(
                        "model", resp.getModel(),
                        "promptTokens", resp.getUsage().getPrompt(),
                        "completionTokens", resp.getUsage().getCompletion(),
                        "temperature", resp.getTemperature(),
                        "seed", resp.getSeed()          // 便于事后复现
                    ));
        }
        case TOOL_CALL -> {
            // 工具调用同样要幂等 + 记录
            Object out = tools.invoke(step.getToolName(), step.getArgs(),
                                      ctx.idempotencyKey(step.getNo()));
            yield StepResult.of(out);
        }
        default -> throw new IllegalStateException("unknown step: " + step.getType());
    };
}
```

注意 `seed` 字段：即使你记录快照，也应该把温度、种子、模型版本一起存下来。排查「为什么这次结果不对」时，这些元数据比结果本身更有价值。

### 4.2 人工审批：用信号唤醒，不用轮询

```java
@RestController
@RequestMapping("/api/agent")
public class ApprovalController {

    @PostMapping("/{taskId}/approve")
    public void approve(@PathVariable String taskId,
                        @RequestBody ApprovalRequest req) {
        // 1. 校验审批人权限（RBAC）
        // 2. 写入审批事件（step 日志的一种）
        stepRepo.recordApproval(taskId, req.getStepNo(), req.getApprover(), req.getDecision());
        // 3. 唤醒任务：清空租约，让调度器重新捡起来
        taskRepo.wakeUp(taskId);   // status=RUNNING, lease_until=NULL
    }
}
```

挂起时 `status=WAITING_APPROVAL`，调度器的查询条件里**不包含**这个状态，所以不会被空转拉取。收到审批后再改回 `RUNNING` 并清空租约，下一轮调度自然捡起——这是「信号驱动」而非「轮询」。

配合超时策略：`WAITING_APPROVAL` 超过 24 小时自动转 `CANCELED`，由定时任务扫描。

## 五、自研 vs Temporal：怎么选

| 维度 | 自研（Spring Boot + MySQL） | Temporal / Cadence |
|---|---|---|
| 上手成本 | 低（团队熟悉的技术栈） | 中（新中间件 + 新编程模型） |
| 确定性重放 | **自己保证**，容易写错 | 框架强制执行（禁止非确定性代码） |
| 定时器/延迟 | 靠 DB 轮询或延迟队列 | 原生支持，精确到秒 |
| 版本管理 | 自己设计（step schema 演进） | 内置 Workflow Versioning |
| 可观测性 | 自己埋点 | 内置 Web UI + 事件历史 |
| 运维成本 | 无新增组件 | 需要部署 Temporal 集群（或云服务） |
| 适用规模 | 日均 < 10 万任务 | 百万级，跨团队复用 |

**结论**：如果 Agent 任务是产品的核心链路、且需要跨团队复用，直接上 Temporal（Java SDK 成熟，`@WorkflowMethod` + `@ActivityMethod` 就是天然的 step 抽象）。如果是「业务系统里嵌一个 AI 功能」，自研这套够用，且不引入运维负担。

Temporal 的映射关系很直接：

| 本文概念 | Temporal 概念 |
|---|---|
| `agent_task` | Workflow Execution |
| `PlanStep` | Activity |
| `agent_step` 日志 | Event History（自动） |
| `agent_checkpoint` | 不需要（History 即状态） |
| 审批信号 | Signal |
| 租约 | Workflow Task Lease（内置） |

## 六、五个生产坑

**坑 1：把「执行中」当成「未执行」**
如果只在 step 成功后写日志，崩溃时正在执行的 step 状态未知。正确做法是**先写 `STARTED` 再执行**，恢复时看到 `STARTED` 就知道「可能已产生副作用」，需要走幂等检查而不是直接重跑。

**坑 2：checkpoint 太大**
把完整消息历史（含 50 轮对话、每个工具返回的 10KB JSON）塞进 checkpoint，单行能到几 MB，MySQL 的 `max_allowed_packet` 直接顶爆。解决方案：checkpoint 只存「结构化状态 + 引用」，大文本存对象存储，DB 里存 URL。

**坑 3：重放时调用了真实工具**
最危险的错误。恢复逻辑里如果漏了「先查记录」，就会重复发邮件、重复下单。防线是**工具层强制幂等键**，即使被调两次也不会产生两个副作用。

**坑 4：租约续不上导致双跑**
GC 停顿超过租约时间，另一个实例抢走任务，原实例恢复后继续执行 → 双跑。防线是每次写库都带 `lease_owner` 条件（`WHERE lease_owner = ?`），一旦租约丢失，后续写入全部失败，任务自然停止。

**坑 5：step 编号不稳定**
如果 Plan 是模型动态生成的，恢复时重新生成 Plan 会导致 step 编号完全错位。**Plan 必须在任务开始时生成一次并持久化**，后续只允许「追加」不允许「重排」。需要重规划时，追加一个新的 `REPLAN` step，产生新的 step 序列。

## 七、面试追问

**Q1：Agent 长任务和普通异步任务有什么区别？**
普通异步任务（如导出报表）通常是「幂等的、可重跑的、无状态的」，失败重跑成本低。Agent 长任务有三个额外特征：**执行路径由模型动态决定（不确定）、每步有外部副作用（不可随意重跑）、耗时长且成本高（重跑要重新烧 token）**。所以必须有检查点和确定性重放。

**Q2：为什么不能简单地「记录最后成功的 step，从下一步重跑」？**
因为下一步的输入依赖前面所有 step 的输出（尤其是模型的推理链）。如果不恢复上下文，模型会在「失忆」状态下继续，产出完全不同的结果。而且很多 step 的输出是非确定性的（LLM 采样），必须用快照而不是重算。

**Q3：Temporal 是怎么保证确定性的？**
它用「事件历史 + 确定性重放」：Workflow 代码必须是确定性的（不能直接调 `System.currentTimeMillis()`、不能有随机数、不能直接做 IO），所有非确定性操作都封装成 Activity，Activity 的结果写入历史。重放时 Workflow 代码重新执行，但 Activity 调用直接返回历史结果，所以状态能精确重建。

**Q4：检查点频率怎么定？**
权衡「恢复速度」和「写入开销」。太频繁（每步）会让 DB 成为瓶颈，尤其 checkpoint 大的时候；太稀疏（每 50 步）恢复时要重放很多。经验值：**每 5 步或每 30 秒取二者先到**，且必须在「高成本 step」（长 LLM 调用、付费工具）之后立即打点。

**Q5：多 Agent 协作场景下，这套机制够用吗？**
不够。多 Agent 需要额外解决「消息传递的持久化」和「子任务的父子关系」。可以复用同一套 step 日志，但要给每个 Agent 分配独立的 task_id，并用 `parent_task_id` 建立层级；同时把 Agent 间消息也当作事件写入日志，才能保证恢复后协作状态一致。

## 总结

- Agent 长任务的本质是**长事务**，必须支持中断、恢复、补偿；
- 持久化执行的三要素：**事件日志、确定性重放、幂等副作用**，缺一不可；
- 实现上采用 `task 主表 + step 事件表 + checkpoint 快照表`，用租约 + 乐观锁做任务抢占；
- **LLM 响应必须落快照**，恢复时绝不重新调用，否则结果漂移；
- 人工审批用「状态挂起 + 信号唤醒」，不要轮询；
- 规模小就自研（Spring Boot + MySQL 足够），核心链路跨团队复用时上 Temporal。

写完这套机制后，你会对「Agent 是分布式系统」这句话有更深的理解：它不是「调个大模型」，而是「一个有状态、有副作用、需要容错的长时间计算」。把它当分布式系统设计，问题就都变成了已知问题。
