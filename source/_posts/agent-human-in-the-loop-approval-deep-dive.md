---
title: 【AI Agent】Human-in-the-Loop 深度解析：审批中断、超时恢复与人工介入的工程设计
date: 2026-11-06 08:00:00
tags:
  - AI
  - Agent
  - HITL
  - 系统设计
  - Java
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】Human-in-the-Loop 深度解析

## 前言：Agent 一旦能"动手"，刹车就必须是设计的一部分

我们做企业内部的运维 Agent，第一版非常惊艳：给它一个告警，它能自己查日志、定位服务、扩副本、回滚发布。演示的时候掌声一片。

上线第三天，它把一个"看起来 CPU 打满"的数据库只读副本判定为异常，然后自动执行了"重启"。那个副本正在跑一个 6 小时的报表导出，重启意味着 6 小时白干。

复盘的时候大家争论的点很有意思：**不是"Agent 判断错了"，而是"为什么它有权重启"**。

这就是 Human-in-the-Loop（HITL，人机协同）要解决的问题。它不是"给 Agent 加个确认弹窗"这么简单——**确认弹窗是最容易做错的一环**，因为它会让操作员产生"确认疲劳"，最后闭着眼点"同意"，比没有确认还糟。

这篇文章讲 HITL 的工程设计：什么该拦、怎么拦、拦住了之后状态怎么存、超时怎么办、恢复怎么保证不重复执行、以及怎么衡量这套机制到底有没有用。

---

## 一、先想清楚：什么该拦

一个常见的错误是"所有写操作都拦"。结果：审批率 90%，操作员 5 秒点一次同意，HITL 名存实亡。

正确的做法是**按"不可逆性 × 影响范围 × 可观测性"三维分级**：

| 等级 | 特征 | 例子 | 策略 |
|---|---|---|---|
| L0 只读 | 不改状态 | 查日志、查指标、读配置 | **不拦**，只审计 |
| L1 可逆 | 有回滚路径，影响单实例 | 扩缩容、重启单副本、改灰度比例 | **事后复核**（异步看板 + 异常告警） |
| L2 有条件可逆 | 可回滚但影响面大 / 回滚有代价 | 全量发布、批量配置下发、DB 索引变更 | **前置审批** |
| L3 不可逆 | 无法回滚 | 删除数据、转账、发外部邮件、删库 | **前置审批 + 双人复核 + 二次确认** |

三条工程规则：

1. **风险等级必须由工具元数据声明，不能由模型判断。** 模型判断"这个操作危不危险"是最不可靠的一环——它会被工具描述里的"这只是个无害的查询"骗过去。风险等级应该是工具注册时的静态属性（`riskLevel`），写在代码里、进代码评审。
2. **升级只能由人降级。** 模型不能自己把 L2 说成 L1。想调整等级，走配置变更流程。
3. **L1 也必须"可观测"**，否则事后复核变成事后追悔。

```java
public enum RiskLevel {
    L0_READ,          // 不拦
    L1_REVERSIBLE,    // 事后复核
    L2_GATED,         // 前置审批
    L3_IRREVERSIBLE   // 前置审批 + 双人 + 二次确认
}

public record ToolPolicy(
        String toolName,
        RiskLevel risk,
        Set<String> requiredApproverRoles,
        Duration approvalTtl,
        boolean requiresTwoPerson,
        String rollbackProcedure   // 文档链接，强制字段
) {}
```

`rollbackProcedure` 我强制设成必填——**一个你说不出怎么回滚的操作，就不该被 Agent 自动执行。**

---

## 二、三种 HITL 形态，别混用

很多人把 HITL 等同于"审批"，其实它有三种截然不同的形态，工程实现完全不同：

| 形态 | 时机 | 人工做什么 | 典型场景 | 状态复杂度 |
|---|---|---|---|---|
| **Approval Gate**（前置审批） | 执行前 | 同意 / 拒绝 | 转账、删除、发布 | 中（需要挂起 + 恢复） |
| **Edit & Continue**（人工改写） | 执行前 | 修改参数后放行 | Agent 生成的 SQL、生成的邮件草稿 | 高（需要参数回写 + 重新校验） |
| **Review**（后置复核） | 执行后 | 抽查、纠错、触发回滚 | L1 操作、Agent 生成的代码 | 低（异步，不影响主链路） |

**关键区别在"主链路是否阻塞"**：Approval Gate 和 Edit 会阻塞 Agent 的执行流（可能几分钟到几天），Review 不阻塞。

这决定了架构：**阻塞型 HITL 必须依赖持久化，不能依赖内存里的线程等待。** 一个等待 3 天的审批，你的 Tomcat 线程早被回收了，Pod 早就滚动了 5 次。

---

## 三、状态机：HITL 的核心是一个持久化状态机

### 3.1 状态定义

```
                 ┌──────────────┐
   执行工具 ───▶ │  PENDING     │  已创建审批请求，尚未有人处理
                 └──────┬───────┘
                        │
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
  ┌──────────┐   ┌───────────┐   ┌────────────┐
  │ APPROVED │   │ REJECTED  │   │  EXPIRED   │
  └────┬─────┘   └─────┬─────┘   └─────┬──────┘
       │               │               │
       ▼               ▼               ▼
  ┌──────────┐   ┌───────────┐   ┌────────────┐
  │ RESUMING │   │ CANCELLED │   │ CANCELLED  │  ← 超时默认 = 拒绝，不是放行
  └────┬─────┘   └───────────┘   └────────────┘
       │
       ▼
  ┌──────────┐        ┌──────────┐
  │ EXECUTING│──失败─▶│  FAILED  │
  └────┬─────┘        └──────────┘
       ▼
  ┌──────────┐
  │ COMPLETED│
  └──────────┘
```

**最容易做错的两个决策：**

1. **超时后的默认行为**。必须是"拒绝 + 通知发起方"，**绝不是"放行"**。我见过有系统写 `if (timeout) approve()`，理由是"避免阻塞业务"——这在 L3 场景下等于没有审批。
2. **`RESUMING` 必须是一个独立状态**，不能从 `APPROVED` 直接跳 `COMPLETED`。因为恢复执行可能失败（下游服务已下线、参数已过期），需要重试和幂等保护。

### 3.2 表结构

```sql
CREATE TABLE agent_approval (
    id                BIGINT PRIMARY KEY AUTO_INCREMENT,
    approval_key      VARCHAR(64)  NOT NULL,        -- 幂等键（唯一）
    task_id           VARCHAR(64)  NOT NULL,        -- 所属 Agent 任务
    step_id           VARCHAR(64)  NOT NULL,        -- 任务内第几步
    tool_name         VARCHAR(128) NOT NULL,
    risk_level        VARCHAR(16)  NOT NULL,
    arguments_json    JSON         NOT NULL,        -- 参数快照（关键！）
    context_snapshot  JSON         NOT NULL,        -- 模型推理摘要 + 引用证据
    status            VARCHAR(16)  NOT NULL,
    version           INT          NOT NULL DEFAULT 0,  -- 乐观锁
    requested_by      VARCHAR(64)  NOT NULL,
    requested_at      DATETIME(3)  NOT NULL,
    expires_at        DATETIME(3)  NOT NULL,
    decided_by        VARCHAR(64),
    decided_at        DATETIME(3),
    decision_comment  VARCHAR(1024),
    idempotency_key   VARCHAR(64),                  -- 执行期幂等
    UNIQUE KEY uk_approval_key (approval_key),
    UNIQUE KEY uk_task_step (task_id, step_id),
    KEY idx_status_expire (status, expires_at)
) ENGINE=InnoDB;
```

三个字段值得单独说：

- **`arguments_json`（参数快照）**：审批人看到的必须是"将要执行的**确切**参数"，而不是"Agent 说要执行的参数"。恢复执行时必须用这份快照，不能重新生成——否则审批的和执行的不是一回事（TOCTOU 漏洞）。
- **`context_snapshot`（上下文快照）**：包含模型为什么这么决策、引用了哪些证据。**只给审批人一句"Agent 想重启 db-replica-3，同意吗？"是无效审批**，人没有判断依据，只能盲批。
- **`uk_task_step`**：同一任务的同一步骤只能有一个审批单，从数据库层面杜绝"重复发起审批"。

---

## 四、Java 实现：挂起与恢复

### 4.1 挂起

```java
@Service
public class ApprovalService {

    private final ApprovalRepository repo;
    private final ApprovalNotifier notifier;
    private final Clock clock;

    /** Agent 执行到高危工具时调用：创建审批单并抛出挂起信号 */
    @Transactional
    public ApprovalTicket requestApproval(AgentContext ctx, ToolCall call, ToolPolicy policy) {
        String approvalKey = ctx.taskId() + ":" + ctx.stepId();

        // 幂等：重复请求返回已有单据，不重复通知
        return repo.findByApprovalKey(approvalKey).orElseGet(() -> {
            ApprovalTicket t = new ApprovalTicket();
            t.setApprovalKey(approvalKey);
            t.setTaskId(ctx.taskId());
            t.setStepId(ctx.stepId());
            t.setToolName(call.toolName());
            t.setRiskLevel(policy.risk());
            t.setArgumentsJson(call.arguments());          // 快照，不可变
            t.setContextSnapshot(buildSnapshot(ctx, call)); // 推理摘要 + 证据
            t.setStatus(Status.PENDING);
            t.setRequestedBy(ctx.userId());
            t.setRequestedAt(Instant.now(clock));
            t.setExpiresAt(Instant.now(clock).plus(policy.approvalTtl()));
            repo.insert(t);

            // 按角色路由通知；L3 需要双人
            notifier.notifyApprovers(t, policy.requiredApproverRoles(),
                                     policy.requiresTwoPerson());
            return t;
        });
    }
}
```

注意这里**没有阻塞等待**。Agent 的执行器收到 `ApprovalTicket` 后，把任务状态标记为 `WAITING_APPROVAL`，然后**正常返回**，释放线程。等审批结果到来时，由另一个入口触发恢复。

### 4.2 决策（并发安全）

```java
@Transactional
public void decide(long approvalId, String approverId, Decision decision,
                   String comment, int expectedVersion) {
    ApprovalTicket t = repo.selectForUpdate(approvalId);   // SELECT ... FOR UPDATE

    if (t.getStatus() != Status.PENDING) {
        throw new IllegalStateException("already decided: " + t.getStatus());
    }
    if (Instant.now(clock).isAfter(t.getExpiresAt())) {
        // 到期后不再接受决策，转 EXPIRED
        t.setStatus(Status.EXPIRED);
        repo.update(t);
        throw new ApprovalExpiredException(approvalId);
    }
    if (t.getRequestedBy().equals(approverId)) {
        throw new IllegalStateException("self-approval forbidden");   // 禁止自批
    }
    if (t.getVersion() != expectedVersion) {
        throw new OptimisticLockException("stale view, please refresh");
    }

    t.setStatus(decision == Decision.APPROVE ? Status.APPROVED : Status.REJECTED);
    t.setDecidedBy(approverId);
    t.setDecidedAt(Instant.now(clock));
    t.setDecisionComment(comment);
    repo.updateWithVersion(t);   // version = version + 1
}
```

四个防护点：**行锁防并发、状态检查防重复决策、时间检查防过期决策、自批检查防绕过**。

> 关于"禁止自批"：很多系统允许发起人自己批准，理由是"小团队没别人"。我的建议是——如果要放开，必须是**配置项 + 审计 + 每日报表**，而不是静默默认允许。

### 4.3 恢复执行（幂等是生命线）

```java
@Service
public class ApprovalResumer {

    private final ApprovalRepository repo;
    private final AgentTaskStore taskStore;
    private final IdempotentExecutor executor;

    @Scheduled(fixedDelay = 5_000)
    public void resumeApproved() {
        // 分页捞取待恢复的单据，避免一次拉太多
        List<ApprovalTicket> batch = repo.findByStatusAndExpiresAfter(
                Status.APPROVED, Instant.now(), PageRequest.of(0, 100));

        for (ApprovalTicket t : batch) {
            // CAS 抢占：把 APPROVED -> RESUMING，只有一个实例能成功
            if (!repo.casStatus(t.getId(), Status.APPROVED, Status.RESUMING)) {
                continue;   // 别的实例抢到了
            }
            try {
                // 必须用审批时的参数快照，不能重新生成
                ToolCall call = ToolCall.fromJson(t.getArgumentsJson());
                String idemKey = t.getApprovalKey();   // 幂等键 = 审批键

                ToolResult result = executor.executeOnce(idemKey, () ->
                        toolInvoker.invoke(t.getToolName(), call));

                taskStore.appendStepResult(t.getTaskId(), t.getStepId(), result);
                repo.casStatus(t.getId(), Status.RESUMING, Status.COMPLETED);
                taskStore.wake(t.getTaskId());          // 唤醒 Agent 主循环继续下一步
            } catch (Exception e) {
                repo.casStatus(t.getId(), Status.RESUMING, Status.FAILED);
                taskStore.fail(t.getTaskId(), t.getStepId(), e);
            }
        }
    }
}
```

三个关键设计：

1. **`casStatus(APPROVED → RESUMING)` 是分布式锁**，避免多副本同时恢复导致重复执行。
2. **`executeOnce(idemKey, ...)` 是幂等执行**：内部先查"这个幂等键是否已有执行记录"，有则直接返回结果。注意——**如果下游工具本身不支持幂等（比如"发邮件"），这里只能保证"最多一次"或"至少一次"，必须业务侧接受其中一种语义**。这一点必须在工具注册时就标注清楚。
3. **恢复不是"重跑整个任务"，而是"从断点续跑"**。这依赖 Agent 的持久化执行能力（事件日志 + 确定性重放）。如果你的 Agent 是纯内存的 ReAct 循环，做不到断点续跑，那 HITL 就只能做成"短时阻塞"（适合分钟级审批），做不了天级审批。

### 4.4 超时处理

```java
@Scheduled(fixedDelay = 60_000)
public void expireStale() {
    int n = repo.expireBatch(Status.PENDING, Status.EXPIRED, Instant.now(), 500);
    if (n > 0) {
        log.warn("expired {} approval requests", n);
        metrics.counter("hitl.expired").increment(n);
    }
}
```

配套两条规则：

- **过期前 25% 时间点提醒一次**（`expires_at - ttl*0.25`），避免"审批人没看到"导致的过期。
- **过期后任务进入 `CANCELLED`，并把"未执行的原因"回写给模型**，让 Agent 能向用户解释"因为审批超时，我没有执行重启"。这比静默失败体验好得多。

---

## 五、指标：怎么证明 HITL 真的有用

这套机制的隐性成本很高（人力 + 延迟），必须能被衡量，否则半年后就会有人提"要不我们把审批去掉吧"。

| 指标 | 定义 | 健康区间 | 异常含义 |
|---|---|---|---|
| **审批率** | 需审批步骤 / 总步骤 | 10%~25% | >40% 说明风险分级太保守，人在盲批 |
| **同意率** | APPROVED / 总决策 | 80%~95% | >98% 说明审批无信息量；<60% 说明 Agent 判断力差 |
| **P50/P95 等待** | 请求到决策耗时 | P95 < 30min | 过长说明路由/通知有问题 |
| **超时率** | EXPIRED / 总请求 | <5% | 高说明审批人负载或通知链路坏 |
| **驳回后重试成功率** | 驳回→修正→通过的比例 | >70% | 低说明反馈信息不足 |
| **人工改写率** | Edit 形态占比 | 观察值 | 上升说明 Agent 参数生成不稳 |
| **审批后失败率** | COMPLETED 中 FAILED 占比 | <2% | 高说明审批的是"过时参数" |

**同意率 98% 是个危险信号**——它意味着审批人对 Agent 已经形成了"无脑信任"，HITL 退化成了合规表演。这时候应该做的不是加更多审批，而是**把 L2 里那些真的从不被拒的操作降级为 L1**，把人的注意力集中到真正危险的地方。

---

## 六、五个反模式

**反模式 1：只给一句"确认吗？"**
审批人看不到参数、看不到推理依据、看不到影响面，只能盲批。**审批 UI 必须包含：确切参数、Agent 的决策理由、引用的证据、影响范围、回滚方式。**

**反模式 2：超时默认放行**
前面说过，再强调一次：**超时 = 拒绝**。要做"自动放行"，只能是显式的、按工具配置的策略，且必须落在 L1 及以下。

**反模式 3：让模型自己决定是否需要审批**
"模型判断这个操作危险，所以请求审批"——模型会被工具描述的"无害"话术骗过去。风险等级必须是**静态元数据**。

**反模式 4：恢复时重新生成参数**
审批的是 A，执行的是 B。这是最隐蔽的越权：审批人以为自己批了"重启 1 个副本"，实际执行的是"重启 10 个"。**必须用参数快照。**

**反模式 5：审批和权限混为一谈**
权限（`java-agent-tool-permission-security` 那篇讲的 RBAC/ABAC/沙箱）解决"Agent 有没有资格调这个工具"；HITL 解决"这一次具体调用要不要人点头"。**两者是串联关系，都不能省。** 只做权限不做审批，Agent 一旦有权限就能无限用；只做审批不做权限，审批人会被海量低价值请求淹没。

---

## 七、面试常见追问

**Q1：HITL 会不会让 Agent 失去意义？**

取决于分级。如果 90% 的操作都要人批，Agent 只是"自动填表机"。健康的分级是：L0/L1 占 80%+ 全自动，L2 占 15% 左右前置审批，L3 极少但严格。**HITL 的目标不是"减少人的参与"，而是"把人的注意力放到真正需要判断的地方"。**

**Q2：审批状态存在哪里？为什么不能用内存？**

必须持久化（DB）。原因：审批可能跨越数小时到数天，期间服务会重启、Pod 会滚动、节点会迁移。内存状态一丢，任务就永远卡在 `WAITING_APPROVAL`，而且没人知道它卡着。同时持久化才能支持"审批历史审计"这个合规刚需。

**Q3：多个副本同时扫描待恢复任务，怎么防重复执行？**

两级：**DB 层 CAS**（`UPDATE ... SET status='RESUMING' WHERE id=? AND status='APPROVED'`，靠影响行数判断）+ **执行层幂等键**（同一幂等键只执行一次）。只有 CAS 不够——因为 CAS 成功后进程可能崩溃在执行中，恢复时状态是 `RESUMING`，需要"僵死状态回收 + 幂等执行"配合。

**Q4：Edit 形态怎么实现？参数被改了，之前的校验还生效吗？**

不生效，必须**重新校验**。正确流程是：审批人改参数 → 服务端用**同一个 schema**重新校验 → 校验通过后更新 `arguments_json`（并记录 diff 到审计）→ 再走恢复。绝不能"因为人改的所以跳过校验"，人才是最容易手抖的一环。

**Q5：怎么避免审批人变成"橡皮图章"？**

四个手段：① 风险分级，只拦真正危险的；② 审批 UI 给足信息（参数、理由、证据、影响面）；③ 抽样事后审计审批质量（看有没有该拒没拒的）；④ **指标驱动**——同意率 >98% 就主动降级一批 L2 为 L1，让注意力重新分配。

---

## 八、落地清单

1. 工具注册时**强制声明** `riskLevel` + `requiredApproverRoles` + `rollbackProcedure`，缺一不可上线。
2. 审批单存 DB，字段必须含**参数快照 + 上下文快照 + 幂等键 + version**。
3. 超时 **= 拒绝**，过期前 25% 时间点提醒一次。
4. 恢复用 **CAS 抢占 + 幂等执行 + 参数快照**，三件套缺一不可。
5. 审批 UI 必须给"参数 / 理由 / 证据 / 影响面 / 回滚方式"五件套。
6. 监控七个指标，**同意率 >98% 视为告警**（说明审批已失去信息量）。
7. 权限与审批**串联**，不是二选一。

HITL 的本质不是"给 Agent 加限制"，而是**在 Agent 的能力边界上画一条人类可理解的线**。这条线画得好，Agent 才敢真正接管生产；画得不好，要么它闯祸，要么它被一堆无意义的弹窗废掉。
