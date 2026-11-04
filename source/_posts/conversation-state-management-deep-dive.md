---
title: 【AI Agent】对话状态管理深度解析：多轮上下文、检查点与状态机工程化
date: 2026-11-04 08:20:00
tags:
  - AI
  - Agent
  - 对话系统
  - 状态管理
  - Java
categories:
  - AI Agent
author: 东哥
---

# 【AI Agent】对话状态管理深度解析：多轮上下文、检查点与状态机工程化

## 前言

做 Agent 应用，很多人把 80% 的精力放在 prompt 和模型上，剩下 20% 放在工具调用上，然后发现一个诡异的现象：

- 单轮对话完美，多轮开始答非所问
- 用户改口说"不是这个，改成明天"，Agent 还在用昨天的日期
- 服务重启后，进行到一半的订票流程全丢
- 两个用户同时用一个 session id，答案互相串
- 用户问了三轮，token 消耗是第一轮的四倍

这些都不是模型问题，是**对话状态管理**的问题。

LLM 本身是**无状态函数**：`f(messages) → response`。所谓的"多轮对话"，全靠你把历史消息重新塞回去。而"Agent"比聊天机器人多了状态：**工具调用中间结果、待填充的槽位、已完成的步骤、用户身份与授权、暂停等待人工审批的挂起点**。

这篇从「状态到底包含什么」讲起，到「怎么存、怎么压缩、怎么恢复」，配 Java 落地代码。

---

## 一、对话状态到底包含什么

很多人的"状态"就是一个 `List<Message>`。这在 Chatbot 里勉强够，在 Agent 里远远不够。

| 状态类别 | 内容 | 生命周期 | 丢失后果 |
|---|---|---|---|
| 消息历史 | user/assistant/tool 消息列表 | 会话内 | 上下文断裂 |
| 槽位（Slot） | 订单号、日期、金额等待填参数 | 任务内 | 反复追问、参数错 |
| 任务状态 | 当前步骤、已完成步骤、分支选择 | 任务内 | 流程重来 |
| 工具调用记录 | 调用参数、返回结果、执行耗时 | 任务内 + 审计 | 重复调用、幂等破坏 |
| 长时记忆 | 用户偏好、历史事实摘要 | 跨会话 | "个性化"消失 |
| 会话元数据 | 用户身份、租户、权限、语言 | 会话内 | **越权** |
| 挂起点（HITL） | 等待人工审批的动作与参数 | 可跨天 | 审批丢失 |

⚠️ **最危险的是"会话元数据"**：如果 `userId` / `tenantId` 存在客户端传来的 session id 里，或者存在一个可以猜到的 key 里，就是水平越权漏洞。**身份必须来自认证上下文（JWT/Session），绝不能来自对话内容。**

`ai-agent-memory-system-deep-dive` 那篇讲的是跨会话的长期记忆（向量记忆、摘要压缩、遗忘策略）。这篇聚焦**会话内状态**：怎么组织、存储、恢复、并发安全。

---

## 二、三种主流状态管理范式

### 2.1 无状态 + 全量回放（Stateless Replay）

每次请求把完整消息历史发给模型，服务端不存任何状态。

```
Client 保存 messages[]  →  每次 POST 全量  →  服务端 f(messages)
```

- ✅ 服务端无状态，水平扩展零成本
- ✅ 天然支持"重新生成"、"编辑历史消息"
- ❌ 历史越来越长，token 成本线性增长
- ❌ 客户端可篡改历史（"你之前说可以退款"）→ **信任边界问题**
- ❌ 工具调用的中间结果（大 JSON）塞回客户端，体积爆炸

**适用**：轻量 Chatbot、公开 Demo。生产 Agent 不建议。

### 2.2 服务端状态 + 检查点（Checkpoint）

服务端维护 session state，每个"步骤"结束后做一次快照（checkpoint）。

```
POST /chat {sessionId, message}
  → load checkpoint(sessionId)
  → 追加用户消息
  → 执行 Agent 步骤（LLM 调用 / 工具调用）
  → save checkpoint(sessionId, newState)
  → return response
```

- ✅ 客户端不持有状态，安全
- ✅ 可断点恢复、可回放、可审计
- ✅ 支持 HITL（挂起 → 恢复）
- ❌ 需要存储层（Redis + DB）
- ❌ 并发写需要乐观锁
- ❌ checkpoint 体积会膨胀，需要压缩/裁剪

**适用**：生产级 Agent。**这是主流方案。**

### 2.3 事件溯源（Event Sourcing）

不存"状态快照"，存"状态变化的事件流"，状态靠重放事件重建。

```
events = [UserSaid("订明天"), SlotFilled(date=2026-11-05), ToolCalled(search, ...), ToolReturned(...)]
state = fold(events)
```

- ✅ 完整审计链，可精确回放到任意时刻
- ✅ 天然支持"从某步重试"
- ✅ 事件流可以喂给评测/训练
- ❌ 重放成本高（需要定期快照）
- ❌ 事件 schema 演进麻烦
- ❌ 对"LLM 输出不确定"的场景，重放未必得到相同结果

**适用**：金融/医疗等强审计场景，或需要"确定性重放"的长任务 Agent（见 `java-agent-long-task-durable-resume-deep-practice`）。

---

## 三、Checkpoint 的数据结构设计

一个能支撑生产的 checkpoint 长这样：

```java
public record AgentCheckpoint(
    String sessionId,
    String tenantId,
    String userId,            // ⭐ 来自认证上下文，不信客户端
    long version,             // 乐观锁版本号
    String status,            // RUNNING / WAITING_HUMAN / DONE / FAILED
    List<Message> messages,   // 裁剪后的消息历史
    Map<String, Object> slots,// 槽位
    List<ToolCallRecord> toolCalls,
    String pendingAction,     // HITL 挂起的动作（JSON）
    Instant createdAt,
    Instant updatedAt,
    int turnCount
) {}
```

### 3.1 为什么必须带 version

并发场景：用户在 Web 和手机同时发消息，两个请求同时读到 version=5 的 checkpoint，各自改完写回 → 后写的覆盖前写的，丢消息。

```java
public boolean saveIfVersionMatches(AgentCheckpoint cp) {
    int rows = jdbc.update("""
        UPDATE agent_checkpoint
           SET state_json = ?, version = version + 1, updated_at = now()
         WHERE session_id = ? AND version = ?
        """, toJson(cp), cp.sessionId(), cp.version());
    return rows == 1;
}
```

失败就重试（重读 → 重算 → 再写），或者直接返回"会话繁忙，请稍后"。**不要用 `last write wins`**，那是最容易在压测里暴露、在生产里静默丢数据的写法。

### 3.2 存储选型

| 存储 | 用途 | TTL | 说明 |
|---|---|---|---|
| Redis | 热状态（进行中会话） | 2~24h | 读写 < 1ms，用 Hash 结构存，字段级更新 |
| MySQL/PostgreSQL | 冷状态 + 审计 | 永久 / 90d | 会话结束后归档，支撑"历史会话"页面 |
| 对象存储 | 大 checkpoint（含工具原始返回） | 按需 | 只在 DB 存引用 |

Redis 存法（避免每次全量读写整个 JSON）：

```
HSET agent:cp:{sessionId}
     version 12
     status RUNNING
     tenant_id t_1001
     user_id u_88
     slots '{"date":"2026-11-05"}'
     messages_ref "cp:msg:{sessionId}:12"   # 消息体单独存
```

消息列表单独存一个 key，避免每次都搬运几十 KB 的历史。

### 3.3 Java 落地骨架

```java
@Service
public class CheckpointStore {
    private final StringRedisTemplate redis;
    private final ObjectMapper om;

    public AgentCheckpoint load(String sessionId) {
        Map<Object, Object> m = redis.opsForHash().entries("agent:cp:" + sessionId);
        if (m.isEmpty()) return AgentCheckpoint.empty(sessionId);
        String msgKey = (String) m.get("messages_ref");
        List<Message> msgs = msgKey == null ? List.of()
            : parseMessages(redis.opsForList().range(msgKey, 0, -1));
        return new AgentCheckpoint(
            sessionId,
            (String) m.get("tenant_id"),
            (String) m.get("user_id"),
            Long.parseLong((String) m.getOrDefault("version", "0")),
            (String) m.getOrDefault("status", "RUNNING"),
            msgs,
            om.readValue((String) m.getOrDefault("slots", "{}"), MAP_TYPE),
            List.of(),  // toolCalls 按需加载
            (String) m.get("pending_action"),
            null, null,
            Integer.parseInt((String) m.getOrDefault("turn_count", "0"))
        );
    }

    /** 用 Lua 保证 version 比较与写入的原子性 */
    public boolean compareAndSave(AgentCheckpoint cp, long expectedVersion) {
        String lua = """
            local v = redis.call('HGET', KEYS[1], 'version')
            if v and tonumber(v) ~= tonumber(ARGV[1]) then return 0 end
            for i = 2, #ARGV, 2 do
              redis.call('HSET', KEYS[1], ARGV[i], ARGV[i+1])
            end
            redis.call('HINCRBY', KEYS[1], 'version', 1)
            redis.call('EXPIRE', KEYS[1], 86400)
            return 1
            """;
        Long ok = redis.execute(new DefaultRedisScript<>(lua, Long.class),
            List.of("agent:cp:" + cp.sessionId()),
            String.valueOf(expectedVersion),
            "status", cp.status(),
            "slots", writeJson(cp.slots()),
            "turn_count", String.valueOf(cp.turnCount() + 1));
        return ok != null && ok == 1L;
    }
}
```

⚠️ **单 key 的 Lua 脚本在 Redis Cluster 下是安全的**（同 slot），但如果要同时写 `agent:cp:*` 和 `cp:msg:*` 两个 key，就必须用 hash tag 让它们落同一 slot：`agent:{sid}:cp` 和 `agent:{sid}:msg`。

---

## 四、上下文压缩：token 成本的主战场

第 10 轮对话时，把 10 轮历史全塞进去，input token 是第 1 轮的 10 倍还多。三种压缩策略：

### 4.1 滑动窗口 + 锚点

保留最近 N 轮 + **固定保留早期的关键信息**（系统提示、用户身份、已确认的槽位）：

```java
public List<Message> compress(List<Message> all, int maxTurns) {
    if (all.size() <= maxTurns * 2) return all;

    List<Message> head = all.subList(0, 2);            // system + 首个 user（含任务定义）
    List<Message> tail = all.subList(all.size() - maxTurns * 2, all.size());
    return Stream.concat(head.stream(), tail.stream()).toList();
}
```

简单粗暴但有效。**缺点**：中间轮次的信息彻底丢失，用户在第 3 轮说的关键约束可能在 12 轮时"忘了"。

### 4.2 滚动摘要

把被裁掉的部分让 LLM 摘要成一段"对话纪要"：

```java
public String summarizeDropped(List<Message> dropped) {
    return chatClient.prompt()
        .system("把以下对话压缩为要点清单，必须保留：用户身份/时间/金额/编号/明确否定的选项。不要编造。")
        .user(render(dropped))
        .call()
        .content();
}
```

摘要作为一条 `system` 或"历史纪要"消息插在窗口前面。

**关键设计**：摘要要**增量更新**而不是每次重摘（否则成本爆炸）。存一个 `summary` 字段 + `summarizedUpTo` 游标，每次只摘新增的丢弃部分，然后合并。

### 4.3 工具结果截断与引用化

工具返回 500KB 的 JSON，绝不能整个塞进上下文。策略：

```java
public String compactToolResult(String raw, int maxChars) {
    if (raw.length() <= maxChars) return raw;
    // 1. 保留结构，截断长数组
    JsonNode node = om.readTree(raw);
    trimArrays(node, 5);             // 每个数组只留前 5 个元素
    String compact = om.writeValueAsString(node);
    if (compact.length() <= maxChars) return compact;
    // 2. 还是太长 → 存对象存储，只给模型一个引用 + 概要
    String ref = blobStore.put(raw);
    return "结果过大，已存储。概要：" + summarize(raw) + "；引用：" + ref;
}
```

让模型知道"数据存在但我没看到全量"，比让它看不到任何东西好得多——它可以通过后续工具调用去查特定部分。

### 4.4 三种策略的组合模板

```
[system prompt]                 固定，不裁
[用户画像 + 长期记忆摘要]        固定，来自 memory 系统
[历史纪要 summary]              增量维护
[最近 N 轮 messages]            完整保留
[当前工具调用链]                只保留最近 3 次
```

这样能把一个 30 轮会话的上下文稳定控制在 4~8K token，而不是线性膨胀到 40K。

---

## 五、HITL：状态挂起与恢复

Agent 要做"删除生产库数据"这种操作，必须人工审批。这就是 Human-in-the-loop。

状态机：

```
RUNNING ──需要审批──> WAITING_HUMAN ──批准──> RUNNING ──> DONE
                          │
                          └──拒绝──> REJECTED
                          └──超时──> EXPIRED
```

```java
public AgentResponse step(AgentCheckpoint cp, String userInput) {
    switch (cp.status()) {
        case "WAITING_HUMAN" -> throw new IllegalStateException("会话正在等待审批");
        case "DONE", "REJECTED", "EXPIRED" ->
            throw new IllegalStateException("会话已结束，请新开会话");
        default -> { /* 继续 */ }
    }

    AgentStep next = planner.next(cp, userInput);

    if (next.requiresApproval()) {
        String actionJson = om.writeValueAsString(next.action());
        approvalService.create(ApprovalRequest.builder()
            .sessionId(cp.sessionId())
            .action(actionJson)
            .requestedBy(cp.userId())
            .expiresAt(Instant.now().plus(Duration.ofHours(24)))
            .build());
        checkpointStore.save(cp.withStatus("WAITING_HUMAN").withPendingAction(actionJson));
        return AgentResponse.suspended("该操作需要审批，已提交给管理员");
    }

    AgentStep result = executor.execute(next);
    checkpointStore.save(cp.append(result));
    return AgentResponse.ok(result.output());
}
```

### 三个必须注意的点

1. **挂起状态不能占用线程**。审批可能要等几小时，绝不能 `Thread.sleep` 或阻塞等待。用事件驱动：审批通过后由回调/消息触发 `resume(sessionId)`。
2. **审批要有超时与幂等**。审批人点两次"通过"，不能执行两次操作。用 `approvalId` + 数据库唯一约束 + 动作幂等键（idempotency key）。
3. **挂起期间的状态要防篡改**。用户可以在挂起期间继续发消息试图改变待审批动作的内容（"顺便把表也删了"）。**待审批动作一旦生成就冻结，任何修改都要作废重新审批。**

---

## 六、六个生产踩坑

**坑 1：sessionId 用 UUID 但存在 URL 里**
`?sessionId=xxx` 会被日志、Referer、浏览器历史记录泄漏。**用 Cookie（HttpOnly + Secure）或 Authorization header**，并且 session 必须绑定 userId 校验。

**坑 2：checkpoint 无限增长**
一个跑了 200 轮的会话，checkpoint 有 3MB，每次请求读写 3MB → 延迟和 Redis 内存都爆。**必须设上限**：超过 N 轮做归档，超过 M 字节做压缩，超过 TTL 直接清理。

**坑 3：TTL 与业务语义冲突**
Redis 设 2h TTL，用户在 2h 后回来说"继续刚才那个"，状态没了，Agent 从头问。**要区分"技术 TTL"和"业务会话期"**：技术层用 Redis 存热态，业务层用 MySQL 存会话骨架，恢复时从 MySQL 重建最小状态。

**坑 4：多实例部署时用了本地缓存**
`ConcurrentHashMap<String, AgentCheckpoint>` 在单机跑得好好的，上了 3 个 Pod 之后，用户请求打到不同实例，状态随机消失。**检查清单第一条：状态必须外置。**

**坑 5：压缩摘要时把权限信息摘没了**
摘要 prompt 让模型"压缩为要点"，模型可能把"该用户是财务部"这种关键上下文当成冗余删掉。**身份/权限/租户这类字段绝不进摘要，必须是结构化的固定字段。**

**坑 6：工具调用结果在重放时重新执行**
断点恢复时，把整个消息历史重放给模型，模型决定"再调一次支付接口"。**工具调用必须记录在 checkpoint 里，重放时直接命中缓存结果，绝不能重新执行有副作用的操作。** 这是长任务 Agent 的头号事故源。

---

## 七、评测：怎么验证状态管理是对的

状态管理的 bug 特别隐蔽（"偶尔答错"），必须靠自动化评测：

| 评测项 | 方法 | 通过标准 |
|---|---|---|
| 多轮一致性 | 构造 10 轮剧本，中途改口 | 最终槽位全部正确 |
| 并发安全 | 同一 session 并发 10 个请求 | 无消息丢失、version 单调递增 |
| 断点恢复 | 在第 k 步 kill 进程后重启 | 从第 k 步继续，不重复执行副作用 |
| 压缩不丢关键信息 | 20 轮后问第 2 轮的约束 | 能正确回答 |
| 越权防护 | 用 A 的 sessionId 配 B 的 token | 403 |
| 上下文成本 | 统计每轮 input token | 不随轮次线性增长 |

一个可用的剧本测试骨架：

```java
@Test
void multiTurnSlotFilling() {
    String sid = sessionService.create("u_88", "t_1001");
    agent.chat(sid, "帮我订机票");                       // 缺日期、目的地
    agent.chat(sid, "去杭州");                            // 补目的地
    agent.chat(sid, "不是杭州，是上海");                   // 改口 ⭐
    AgentResponse r = agent.chat(sid, "明天出发");
    assertThat(r.text()).contains("上海").doesNotContain("杭州");
    assertThat(checkpointStore.load(sid).slots())
        .containsEntry("destination", "上海")
        .containsEntry("date", "2026-11-05");
}
```

"改口"是最容易被忽略、也最容易在真实用户身上发生的场景。**没有"改口覆盖"逻辑的 Agent，本质上是个只认第一遍输入的表单。**

---

## 八、面试常见追问

**Q1：为什么 LLM 应用需要状态管理？模型不是有上下文窗口吗？**
模型的上下文窗口是"一次请求内的输入长度"，不是"服务端持久状态"。每次 HTTP 请求都是独立的无状态调用，所谓的"记忆"完全靠你把历史消息重新组装进 messages 数组。所以状态管理的本质是"如何组装、存储、裁剪这份输入"。

**Q2：Serverless / 多实例部署怎么管状态？**
状态必须外置到 Redis/DB，进程内不存任何会话数据。同时注意：①Lua/CAS 保证并发安全 ②压缩/摘要这类 CPU 活在请求线程里做会有延迟尖峰，考虑异步预计算 ③冷启动时从 DB 重建状态要有超时保护。

**Q3：为什么不直接把历史全塞给模型？反正 context window 有 128K。**
三个成本：①钱——input token 按量计费，200 轮对话能烧掉几十万 token；②延迟——prefill 阶段与输入长度近似线性，128K 上下文的 TTFT 可能是 4K 的 20 倍；③质量——长上下文里模型对中间部分的注意力会衰减（"lost in the middle"），塞得越多不一定越准。

**Q4：Checkpoint 和事件溯源怎么选？**
需要"任意时刻回放 + 强审计"选事件溯源（金融、医疗）；需要"简单、够用、性能好"选 checkpoint 快照。**工业界常见组合：事件溯源存审计流（append-only），定期生成 checkpoint 快照加速恢复。** 这是数据库 WAL + 检查点的同一套思路。

**Q5：怎么处理"用户中途完全换话题"？**
两条路：①**话题检测 + 新开分支**——用轻量分类器或规则判断新话题与当前任务的槽位重叠度，低于阈值就开新会话（但要保留长期记忆）；②**软重置**——清空槽位与任务状态，保留消息历史。**不要硬把新话题塞进旧任务的槽位**，那是"答非所问"最常见的根因。

---

## 九、小结

- LLM 是无状态函数，"多轮"全靠你把历史搬来搬去；Agent 还把工具结果、槽位、挂起点都变成了状态。
- 三种范式：无状态全量回放（简单但不安全）、**检查点快照（生产主流）**、事件溯源（强审计）。
- Checkpoint 必须带 `version` 做乐观锁，存储分层（Redis 热 / DB 冷 / 对象存储大块）。
- 上下文压缩三件套：滑动窗口 + 锚点、滚动增量摘要、工具结果截断引用化。目标是把 token 稳定在 4~8K，而不是随轮次线性膨胀。
- HITL 挂起不能阻塞线程，要事件驱动恢复；待审批动作一旦生成就冻结，且必须幂等。
- 六个坑：sessionId 泄漏、checkpoint 无限增长、TTL 与业务冲突、本地缓存、摘要丢权限、重放重执行副作用。
- 评测重点是三件事：**改口覆盖、并发安全、断点恢复**。

做到这些，你的 Agent 才能从"Demo 里能聊两句"变成"用户敢把真实业务交给它"。这两者之间的距离，就是状态管理。
