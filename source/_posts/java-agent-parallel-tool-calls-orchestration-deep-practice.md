---
title: 【Java AI】Agent 并行工具调用深度实战：依赖分析、虚拟线程编排与部分失败治理
date: 2026-11-26 08:00:00
tags:
  - Java
  - AI
  - Agent
  - Function Calling
  - 虚拟线程
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】Agent 并行工具调用深度实战

## 前言

一个查订单的 Agent，用户问：「帮我看看订单 A1001 和 A1002 哪个先到，顺便查下这两个包裹的物流。」

模型很聪明，一次返回了三个工具调用：

- `getOrder(A1001)`
- `getOrder(A1002)`
- `getLogistics(A1001)`、`getLogistics(A1002)`

如果串行执行，每个 600ms，总耗时 2.4s；如果全部并行，理论上 600ms 就能完成。但很多团队做完并行之后，反而出现了新问题：

- 两个工具同时改同一个订单，后写的覆盖先写的；
- 工具结果回填顺序错乱，模型把 A1001 的物流安到了 A1002 上；
- 一个工具超时，整个 `CompletableFuture.allOf` 抛异常，其他已经成功的结果全丢了；
- 并行度不设上限，一次 20 个工具把下游数据库打挂。

**并行工具调用不是「把 for 循环换成 parallelStream」**。它涉及协议语义、依赖分析、并发控制、结果组装、失败策略五个层面。

> 分工说明：站内已有《Agent 工作流编排》（跨步骤 DAG、状态机、人工介入）、《Agent 失败分类与重试预算》（失败语义与预算）。本篇专攻**单轮 LLM 返回多个 tool_calls 时的执行层设计**。

---

## 一、一个真实批次长什么样

把上面的场景拆开，一轮完整的工具批次包含四个阶段：

```
LLM 返回 tool_calls[]
        │
        ▼
[1] 解析与校验：JSON 参数合法？工具存在？权限允许？
        │
        ▼
[2] 依赖分析：哪些能并行，哪些必须串行
        │
        ▼
[3] 执行：有界并发 + 每工具超时 + 取消传播
        │
        ▼
[4] 组装：按 id 回填 + 错误结构化 + 截断
        │
        ▼
再次调用 LLM，生成最终回答
```

大多数线上事故出在第 2 步和第 4 步：要么把有依赖的调用并行了，要么结果顺序/身份错乱。协议本身反而最简单。

---

## 二、协议层：多个 tool_calls 长什么样

### 2.1 OpenAI Chat Completions

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [
    {
      "id": "call_001",
      "type": "function",
      "function": { "name": "getOrder", "arguments": "{\"orderId\":\"A1001\"}" }
    },
    {
      "id": "call_002",
      "type": "function",
      "function": { "name": "getOrder", "arguments": "{\"orderId\":\"A1002\"}" }
    }
  ]
}
```

回填时，每个结果必须是一条独立消息，且 `tool_call_id` 对齐：

```json
{ "role": "tool", "tool_call_id": "call_001", "content": "{\"status\":\"SHIPPED\"}" }
{ "role": "tool", "tool_call_id": "call_002", "content": "{\"status\":\"CREATED\"}" }
```

`parallel_tool_calls` 参数默认是 `true`，可以显式设为 `false` 强制模型一次只调一个。注意：它只是「建议模型并行」，**不代表你的执行器必须并行**，也不保证模型一定返回多个。

### 2.2 Anthropic Messages

Anthropic 用 content block：

```json
{
  "role": "assistant",
  "content": [
    { "type": "tool_use", "id": "toolu_01", "name": "getOrder", "input": { "orderId": "A1001" } },
    { "type": "tool_use", "id": "toolu_02", "name": "getOrder", "input": { "orderId": "A1002" } }
  ]
}
```

回填是 `user` 消息里的 `tool_result` block：

```json
{
  "role": "user",
  "content": [
    { "type": "tool_result", "tool_use_id": "toolu_01", "content": "{\"status\":\"SHIPPED\"}" },
    { "type": "tool_result", "tool_use_id": "toolu_02", "content": "{\"status\":\"CREATED\"}" }
  ]
}
```

### 2.3 两家协议的共同点

| 维度 | 共同要求 |
|---|---|
| 身份 | 每个调用有唯一 id，结果必须按 id 回填 |
| 顺序 | 结果消息的顺序最好与调用顺序一致，降低模型混淆 |
| 参数 | arguments 是 JSON 字符串，需要二次解析与校验 |
| 错误 | 工具失败也要回填，内容里说明错误，而不是直接吞掉 |
| 并行 | 协议支持一次多个，但是否并行由执行器决定 |

---

## 三、先做依赖分析，再谈并行

### 3.1 三类工具关系

| 关系 | 例子 | 能否并行 |
|---|---|---|
| 独立读 | `getOrder(A)`、`getOrder(B)` | 能 |
| 依赖 | 先 `createOrder` 拿 orderId，再 `pay(orderId)` | 不能，必须串行 |
| 互斥写 | `updateStatus(A, PAID)`、`updateStatus(A, CANCELED)` | 不能，且要定序 |

模型返回的 tool_calls 通常已经是「它认为可以一起做」的，但模型并不了解你的业务约束。执行器必须自己再做一次依赖分析。

### 3.2 给工具打元数据

```java
public enum ToolEffect { READ, WRITE, DESTRUCTIVE }

public record ToolMeta(
        String name,
        ToolEffect effect,
        String resourceType,
        boolean idempotent,
        Duration timeout) {
}
```

关键字段是 `resourceType` 和「从参数里提取资源 id 的方法」：

```java
public interface ResourceKeyExtractor {
    /** 返回本次调用会触碰的资源键，例如 order:A1001 */
    Set<String> extract(String toolName, JsonNode arguments);
}
```

### 3.3 构建依赖图

规则可以很简单：

1. 两个 `READ` 且资源键不相交 → 可并行；
2. 任一 `WRITE`/`DESTRUCTIVE` → 与同资源键的其他调用串行，按模型返回顺序执行；
3. 参数里引用了前面调用的输出（例如 `$call_001.orderId`）→ 硬依赖，必须等前面完成；
4. 无法判断资源键 → 保守串行。

```java
public List<List<ToolCall>> buildWaves(List<ToolCall> calls, ResourceKeyExtractor extractor) {
    List<List<ToolCall>> waves = new ArrayList<>();
    Set<String> written = new HashSet<>();
    List<ToolCall> current = new ArrayList<>();

    for (ToolCall call : calls) {
        ToolMeta meta = registry.get(call.name());
        Set<String> keys = extractor.extract(call.name(), call.arguments());

        boolean conflict = meta.effect() != ToolEffect.READ
                || keys.stream().anyMatch(written::contains)
                || hasUnresolvedReference(call);

        if (conflict) {
            if (!current.isEmpty()) {
                waves.add(current);
                current = new ArrayList<>();
            }
            waves.add(List.of(call));
            if (meta.effect() != ToolEffect.READ) {
                written.addAll(keys);
            }
        } else {
            current.add(call);
        }
    }
    if (!current.isEmpty()) {
        waves.add(current);
    }
    return waves;
}
```

这个算法是「按波次执行」：每一波内部可以并行，波次之间串行。它比完整 DAG 调度简单，但对 LLM 单轮工具调用足够。

---

## 四、执行器：虚拟线程 + 有界并发 + 超时

### 4.1 不要用公共 ForkJoinPool

`parallelStream()` 用的是公共 ForkJoinPool，阻塞型工具调用会占满线程，影响整个 JVM。IO 密集型任务应该用虚拟线程：

```java
@Component
public class ParallelToolExecutor {

    private final ExecutorService executor =
            Executors.newVirtualThreadPerTaskExecutor();
    private final Semaphore permits;

    public ParallelToolExecutor(@Value("${agent.tool.max-concurrency:8}") int maxConcurrency) {
        this.permits = new Semaphore(maxConcurrency);
    }

    public ToolResult execute(ToolCall call, ToolCallback callback) {
        try {
            permits.acquire();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return ToolResult.error(call.id(), "interrupted");
        }
        try {
            return CompletableFuture
                    .supplyAsync(() -> doCall(call, callback), executor)
                    .orTimeout(timeoutOf(call).toMillis(), TimeUnit.MILLISECONDS)
                    .exceptionally(ex -> ToolResult.error(call.id(), rootMessage(ex)))
                    .join();
        } finally {
            permits.release();
        }
    }

    private ToolResult doCall(ToolCall call, ToolCallback callback) {
        try {
            String output = callback.call(call.arguments());
            return ToolResult.ok(call.id(), output);
        } catch (Exception e) {
            return ToolResult.error(call.id(), e.getMessage());
        }
    }
}
```

要点：

- **信号量限流**：虚拟线程很便宜，但下游数据库、HTTP 服务不便宜；
- **每工具独立超时**：不要用一个全局 `allOf` 超时；
- **异常转成结果**：工具失败不能让整批失败；
- **`join()` 在调用线程**：虚拟线程上阻塞成本低，但仍建议在请求线程聚合。

### 4.2 用 StructuredTaskScope 表达「同生共死」

如果业务要求「一个失败就全部取消」，可以用结构化并发：

```java
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    List<StructuredTaskScope.Subtask<ToolResult>> tasks = calls.stream()
            .map(c -> scope.fork(() -> execute(c, callbacks.get(c.name()))))
            .toList();

    scope.join();
    scope.throwIfFailed();

    return tasks.stream().map(Subtask::get).toList();
} catch (Exception e) {
    // 任一失败，其他分支已被取消
    throw new ToolBatchException("batch failed", e);
}
```

注意：`ShutdownOnFailure` 会取消其他分支，但**已经产生的副作用不会回滚**。写工具要谨慎使用这种模式。

### 4.3 取消传播

用户点「停止」时，要能取消还没完成的工具：

```java
private final Map<String, Future<?>> running = new ConcurrentHashMap<>();

public void cancelAll(String conversationId) {
    running.forEach((id, f) -> f.cancel(true));
}
```

HTTP 客户端要支持中断（OkHttp 的 `Call.cancel()`、JDK HttpClient 的 `cancel`），否则 `Future.cancel` 只是把线程标记为中断，底层请求还在跑。

---

## 五、结果组装：顺序、id、错误

### 5.1 按调用顺序回填

模型对「第几个结果对应第几个调用」有隐含预期。即使用 id 对齐，乱序也容易让模型混淆。建议：

```java
Map<String, ToolResult> byId = results.stream()
        .collect(Collectors.toMap(ToolResult::callId, r -> r));

List<ToolResponseMessage.ToolResponse> ordered = calls.stream()
        .map(c -> new ToolResponseMessage.ToolResponse(
                c.id(), c.name(), byId.get(c.id()).content()))
        .toList();
```

### 5.2 错误也是结果

不要把失败的工具从结果里删掉。模型需要知道「这个工具失败了」，才能决定重试、换工具或向用户解释：

```json
{
  "role": "tool",
  "tool_call_id": "call_002",
  "content": "{\"error\":\"TIMEOUT\",\"message\":\"getOrder timed out after 800ms\",\"retryable\":true}"
}
```

### 5.3 结果截断

并行 10 个工具，每个返回 20KB，一次就是 200KB，直接爆上下文。执行器要统一截断：

```java
private String truncate(String content, int maxChars) {
    if (content == null || content.length() <= maxChars) {
        return content;
    }
    return content.substring(0, maxChars)
            + "\n...[truncated, original length=" + content.length() + "]";
}
```

截断策略要按工具类型区分：列表类保留前 N 条，详情类保留关键字段，日志类保留头尾。

---

## 六、Spring AI 与 LangChain4j 的落地差异

### 6.1 Spring AI：默认自动执行，想并行要自己接管

Spring AI 的 `ChatClient` 在 `tools()` 注册工具后，默认由框架内部循环执行工具调用。它适合「串行、简单」的场景。要做并行，需要自己拿 `ChatModel` 的原始响应：

```java
ChatResponse response = chatModel.call(new Prompt(messages, options));
AssistantMessage message = response.getResult().getOutput();

List<AssistantMessage.ToolCall> calls = message.getToolCalls();
if (calls.size() > 1) {
    List<ToolResult> results = parallelToolExecutor.executeBatch(calls, registry);
    messages.add(message);
    messages.add(ToolResponseMessage.builder()
            .responses(results.stream()
                    .map(r -> new ToolResponseMessage.ToolResponse(
                            r.callId(), r.toolName(), r.content()))
                    .toList())
            .build());
    // 再调一次模型，让它基于结果生成最终回答
}
```

注意：Spring AI 不同版本 API 有差异（`ToolCall` 的字段访问器、`ToolResponseMessage` 的构造方式），落地时以项目依赖版本为准。

### 6.2 LangChain4j：AiServices 与手动 ToolSpecification

LangChain4j 的 `AiServices` 也是自动执行工具。要手动控制，可以用 `ToolSpecification` + 自己解析 `ToolExecutionRequest`：

```java
List<ToolExecutionRequest> requests = response.aiMessage().toolExecutionRequests();
List<CompletableFuture<ToolExecutionResultMessage>> futures = requests.stream()
        .map(req -> CompletableFuture.supplyAsync(
                () -> executeAndWrap(req), executor))
        .toList();

List<ToolExecutionResultMessage> results = futures.stream()
        .map(CompletableFuture::join)
        .toList();
```

两家框架的共同点是：**自动执行适合 Demo，生产级并行要自己接管执行层**。

---

## 七、观测：并行到底省了多少

| 指标 | 定义 | 用途 |
|---|---|---|
| `agent.tool.batch.size` | 单轮 tool_calls 数量 | 判断模型是否真的并行 |
| `agent.tool.parallel.degree` | 实际并发数 | 对比 batch size，发现串行化 |
| `agent.tool.wall.time` | 整批墙钟时间 | 评估优化效果 |
| `agent.tool.sum.time` | 各工具耗时之和 | 计算理论节省 |
| `agent.tool.save.ratio` | `1 - wall/sum` | 并行收益 |
| `agent.tool.fail.rate` | 按工具名维度 | 定位不稳定工具 |
| `agent.tool.timeout.rate` | 超时占比 | 调超时阈值 |

一个真实的对比：

| 场景 | 串行 | 并行 | 节省 |
|---|---|---|---|
| 4 个独立查询，每个 600ms | 2.4s | 0.65s | 73% |
| 2 读 1 写，写依赖其中一个读 | 1.8s | 1.2s | 33% |
| 3 个写同一订单 | 1.8s | 1.8s（串行） | 0% |

如果 `save.ratio` 长期为 0，说明依赖分析把太多调用串行化了，要检查资源键提取是否过粗（比如把所有订单都映射成 `order:*`）。

---

## 八、踩坑清单

1. **`parallel_tool_calls=false` 不是万能的**：它只影响模型，不阻止你自己并行。
2. **`allOf` 的异常会丢结果**：用 `exceptionally` 把每个 future 转成结果对象，不要让它抛。
3. **工具结果必须带 id**：少了 id，模型会瞎猜对应关系。
4. **写工具不要并行**：即使资源键不同，也要考虑数据库连接池和锁竞争。
5. **超时要小于上游总超时**：工具 800ms、Agent 总预算 3s，别让单个工具吃掉全部预算。
6. **虚拟线程不是无限并发**：下游连接池只有 20 个连接，开 200 个虚拟线程只会排队。
7. **取消要传到 HTTP 层**：`Future.cancel` 不等于请求取消。
8. **截断要在执行器做**：不要指望模型自己忽略超长结果。
9. **幂等键在首次调用前生成**：重试时复用，不要在重试时重新生成。

---

## 九、面试追问

**Q1：模型一次返回多个 tool_calls，你怎么决定哪些能并行？**

先给工具打 `READ/WRITE/DESTRUCTIVE` 标签和资源键，再按「读读可并行、写与同资源串行、有参数依赖必须串行」构建波次。无法判断资源键时保守串行。

**Q2：为什么不用 `parallelStream`？**

它使用公共 ForkJoinPool，阻塞型 IO 会占满线程，影响整个 JVM；而且没有每任务超时和取消语义。虚拟线程 + 信号量更合适。

**Q3：一个工具失败了，整批要不要失败？**

看业务。查询类可以 best-effort，把错误作为结果回填让模型决策；写操作类建议 fail-fast，但要注意已执行的副作用无法自动回滚，需要补偿或幂等。

**Q4：并行结果太多导致上下文爆炸怎么办？**

在执行器层按工具类型截断，保留关键字段；必要时对结果做摘要后再回填，并记录原始结果的引用 id 供后续按需取用。

**Q5：怎么证明并行有效？**

看 `wall time` 与 `sum time` 的比值。如果 batch size 很大但 save ratio 很低，说明依赖分析过度保守或下游被限流。

---

## 十、总结

并行工具调用的本质是「一个小型调度器」：

1. 协议层保证 id 对齐、顺序稳定、错误可见；
2. 依赖层用工具元数据 + 资源键做波次划分；
3. 执行层用虚拟线程 + 信号量 + 独立超时；
4. 结果层按 id 回填、截断、错误结构化；
5. 观测层看并行度、节省率、失败率。

把这五层做扎实，Agent 的工具调用才能既快又稳。否则「并行」只是把串行的 bug 放大成并发的 bug。
