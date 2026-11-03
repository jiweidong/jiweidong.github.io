---
title: 【Java AI】MCP Server 生产化深度实战：会话粘滞、工具级限流与审计闭环
date: 2026-11-03 08:15:00
tags:
  - Java
  - AI
  - MCP
  - Spring AI
  - Agent
  - 生产治理
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】MCP Server 生产化深度实战

## 前言

MCP（Model Context Protocol）的教程已经很多了：写个 `@Tool` 方法，起个 SSE 端点，Claude Desktop 一连，工具就跑起来了。

但真把它放到生产环境，问题会成堆出现：

- 部署了 3 个副本，客户端一连就随机打到不同 Pod，**initialize 之后的调用全部 400**
- 某个 Agent 疯狂调 `search_docs`，把整个 MCP Server 拖垮，**没有工具级限流**
- 出事了要复盘：谁在什么时候调了什么工具、参数是什么、返回多大、耗时多少——**一条审计都没有**
- 一个租户的工具调用超时了，客户端取消，**服务端还在跑，白烧 CPU**
- 工具返回 5MB JSON，直接把模型上下文撑爆

这篇是「把 MCP Server 变成可运维服务」的工程笔记。协议基础（JSON-RPC 消息格式、capabilities 协商、transport）这里不重复，直接讲生产化要解决的六件事。

---

## 一、先理清 MCP 的有状态性

这是所有生产问题的源头。

### 1.1 握手期建立了什么

```
Client                          Server
  │── initialize ──────────────▶│
  │◀───────────── result ───────│   协商 protocolVersion、capabilities
  │── notifications/initialized ▶│
  │── tools/list ───────────────▶│
  │◀───────────── tools ────────│
  │── tools/call ───────────────▶│
  │◀───────────── result ───────│
```

关键点：**`initialize` 建立了会话状态**，包括：

| 状态 | 说明 |
|---|---|
| protocolVersion | 双方协商的协议版本 |
| client capabilities | 客户端支持 sampling/roots/elicitation 吗 |
| server capabilities | 服务端提供 tools/resources/prompts/logging 吗 |
| session id | 传输层给的会话标识（HTTP 场景在 `Mcp-Session-Id` 头里） |
| 订阅关系 | resources/subscribe 的订阅列表 |
| 进度/取消上下文 | 进行中的请求 |

### 1.2 多副本为什么必然出问题

```
        ┌──────────────┐
        │  LB / Ingress│
        └──┬────┬────┬─┘
           │    │    │
        ┌──▼┐ ┌▼──┐ ┌▼──┐
        │Pod1│ │Pod2│ │Pod3│
        └────┘ └────┘ └────┘

initialize 落在 Pod1，session 存在 Pod1 的内存里
tools/call 被轮询到 Pod2 → Pod2 不认识这个 session → 404/400
```

这不是配置问题，是**架构问题**。三条路，各有代价。

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **会话粘滞** | Ingress 按 `Mcp-Session-Id` 做一致性哈希 / cookie affinity | 改动最小，性能最好 | Pod 重启即断；扩缩容会打散；长连接倾斜 |
| **外部会话存储** | session 存 Redis，任何 Pod 都能接管 | 无状态扩缩容；滚动发布不断连 | 每次请求多一次 Redis 往返；要处理 session 序列化 |
| **无状态化** | 不依赖服务端 session，客户端每次带全上下文 | 最干净，天然水平扩展 | 需要客户端配合；不适合 resources/subscribe |

**我的建议：默认走「外部会话存储 + 短 TTL」，需要推送的订阅类能力再叠加粘滞。**

理由：MCP 的 session 数据量很小（几 KB），Redis 完全扛得住；而无状态化要求改客户端，MCP 客户端生态还没那么配合。

---

## 二、会话存储落地

### 2.1 会话模型

```java
public record McpSession(
    String sessionId,
    String tenantId,
    String clientId,
    String protocolVersion,
    Set<String> clientCapabilities,
    Set<String> allowedTools,      // 租户级工具白名单
    Instant createdAt,
    Instant lastAccessAt
) implements Serializable {}
```

⚠️ **不要往 session 里塞大对象**（比如已加载的文档内容、对话历史）。session 是「协议状态」，不是「业务状态」。业务状态放业务存储，用 `tenantId + conversationId` 关联。

### 2.2 Redis 实现

```java
@Component
public class RedisSessionStore {
    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private static final Duration TTL = Duration.ofMinutes(30);

    public RedisSessionStore(StringRedisTemplate redis, ObjectMapper mapper) {
        this.redis = redis;
        this.mapper = mapper;
    }

    private String key(String sid) { return "mcp:session:" + sid; }

    public void save(McpSession s) {
        try {
            redis.opsForValue().set(key(s.sessionId()),
                mapper.writeValueAsString(s), TTL);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("session 序列化失败", e);
        }
    }

    public Optional<McpSession> load(String sid) {
        String json = redis.opsForValue().get(key(sid));
        if (json == null) return Optional.empty();
        try {
            McpSession s = mapper.readValue(json, McpSession.class);
            // 滑动续期：只在超过 1/3 TTL 未访问时才续，避免每次都写 Redis
            if (Duration.between(s.lastAccessAt(), Instant.now()).toMinutes() > 10) {
                save(new McpSession(s.sessionId(), s.tenantId(), s.clientId(),
                    s.protocolVersion(), s.clientCapabilities(), s.allowedTools(),
                    s.createdAt(), Instant.now()));
            }
            return Optional.of(s);
        } catch (JsonProcessingException e) {
            return Optional.empty();
        }
    }

    public void remove(String sid) { redis.delete(key(sid)); }
}
```

**滑动续期的细节很重要**：如果每次请求都 `EXPIRE`，高 QPS 下 Redis 写放大很严重。上面用「距上次访问超过 10 分钟才续」把写次数压到 1/20 以下。

### 2.3 与 Spring AI MCP Server 集成

Spring AI 的 MCP Server 支持自定义 `McpTransport` / session 管理。核心是拦截 HTTP 请求，在进入 MCP 处理链之前把 session 装进 ThreadLocal（或 `RequestContextHolder`）：

```java
@Component
public class McpSessionFilter extends OncePerRequestFilter {
    private final RedisSessionStore store;
    private static final ThreadLocal<McpSession> CURRENT = new ThreadLocal<>();

    public McpSessionFilter(RedisSessionStore store) { this.store = store; }

    public static McpSession current() {
        McpSession s = CURRENT.get();
        if (s == null) throw new IllegalStateException("无 MCP 会话上下文");
        return s;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse resp,
                                    FilterChain chain) throws ServletException, IOException {
        String sid = req.getHeader("Mcp-Session-Id");
        // initialize 请求没有 session id，放行让协议层创建
        if (sid != null) {
            Optional<McpSession> s = store.load(sid);
            if (s.isEmpty()) {
                resp.setStatus(404);
                resp.setContentType("application/json");
                resp.getWriter().write("""
                    {"jsonrpc":"2.0","error":{"code":-32001,"message":"session not found"}}
                    """);
                return;
            }
            CURRENT.set(s.get());
        }
        try {
            chain.doFilter(req, resp);
        } finally {
            CURRENT.remove();   // 必须清理，线程池复用会串租户
        }
    }
}
```

⚠️ **`CURRENT.remove()` 放在 finally 是硬要求**。Tomcat 线程池复用，漏了就是跨租户数据泄漏。

---

## 三、工具级限流

全局 QPS 限流不够——`search_docs`（调 ES，50ms）和 `generate_report`（调 LLM + 数据库，30s）对系统的压力完全不同。

### 3.1 三维限流模型

| 维度 | 键 | 目的 |
|---|---|---|
| 租户级 | `tenantId` | 防止单租户打爆整体 |
| 工具级 | `tenantId:toolName` | 保护重工具（LLM 调用、导出） |
| 并发级 | `tenantId:toolName` in-flight | 防止慢工具堆积 |

```java
@Component
public class ToolRateLimiter {
    // 每个 (tenant, tool) 一个令牌桶
    private final ConcurrentHashMap<String, Bucket> buckets = new ConcurrentHashMap<>();
    // 每个 (tenant, tool) 的并发上限
    private final ConcurrentHashMap<String, AtomicInteger> inflight = new ConcurrentHashMap<>();

    private static final Map<String, Integer> QPS = Map.of(
        "search_docs", 20,
        "query_metrics", 10,
        "generate_report", 2,      // 重工具，限死
        "send_email", 1            // 有外部副作用，最严
    );
    private static final Map<String, Integer> CONCURRENCY = Map.of(
        "generate_report", 4,
        "send_email", 2
    );

    public Permit acquire(String tenantId, String tool) {
        int qps = QPS.getOrDefault(tool, 5);
        Bucket b = buckets.computeIfAbsent(tenantId + ":" + tool,
            k -> Bucket.builder()
                    .addLimit(Bandwidth.classic(qps, Refill.greedy(qps, Duration.ofSeconds(1))))
                    .build());
        if (!b.tryConsume(1)) {
            throw new ToolLimitExceededException(tool, "QPS 超限: " + qps);
        }

        int maxConc = CONCURRENCY.getOrDefault(tool, 16);
        AtomicInteger c = inflight.computeIfAbsent(tenantId + ":" + tool, k -> new AtomicInteger());
        if (c.incrementAndGet() > maxConc) {
            c.decrementAndGet();
            throw new ToolLimitExceededException(tool, "并发超限: " + maxConc);
        }
        return new Permit(c);
    }

    public record Permit(AtomicInteger counter) implements AutoCloseable {
        @Override public void close() { counter.decrementAndGet(); }
    }
}
```

用 Bucket4j 是因为它支持**本地 + 分布式**两种模式。多副本下如果要求「全局精确 QPS」，要接 Redis 后端；如果只要求「单副本不被打爆」，本地桶就够（总限额 ≈ 副本数 × 单副本限额）。

### 3.2 拒绝时返回什么

MCP 的错误要区分两类：

| 类型 | JSON-RPC 层 | 说明 |
|---|---|---|
| 协议错误 | `error` 对象 | session 不存在、方法不支持 |
| 工具执行错误 | `result.isError: true` | 工具内部业务失败 |

限流属于「工具执行错误」，应该返回 `isError: true` 且内容可读，让模型能理解并调整策略：

```java
@Tool(description = "在知识库中搜索文档。注意：单租户限 20 QPS，超限时请降低调用频率或合并查询。")
public String searchDocs(String query, int topK) {
    try (var permit = limiter.acquire(currentTenant(), "search_docs")) {
        return doSearch(query, topK);
    } catch (ToolLimitExceededException e) {
        // 不要抛异常让框架包装成协议错误
        return "调用被限流：" + e.getMessage() + "。建议：缩小查询范围，或在 2 秒后重试一次。";
    }
}
```

⚠️ 这里有个反直觉的点：**给模型的错误信息要「可执行」**。写「rate limit exceeded」模型只会重试；写「2 秒后重试一次」模型才会退避。这是 prompt 工程和服务工程的交界。

---

## 四、鉴权与多租户隔离

### 4.1 信任链

```
用户 → 授权服务器（OAuth 2.1）→ access token
                                    ↓
Agent 平台 → 带 token 调 MCP Server → 验签、解出 tenant/scope
                                    ↓
MCP Server → tool allowlist 校验 → 执行
```

⚠️ **绝对不要用「MCP Server 内置管理员账号」直连数据库**。一旦某个工具的参数被注入（模型被诱导），就是全库泄露。每个租户应该有独立的数据视图（行级权限或独立 schema）。

### 4.2 工具白名单

```java
@Component
public class ToolGuard {
    // 工具 → 需要的 scope
    private static final Map<String, String> REQUIRED_SCOPE = Map.of(
        "search_docs",     "docs:read",
        "query_metrics",   "metrics:read",
        "generate_report", "report:write",
        "send_email",      "mail:send"
    );

    public void check(McpSession session, String tool) {
        String need = REQUIRED_SCOPE.get(tool);
        if (need == null) {
            throw new ForbiddenToolException("未注册的工具: " + tool);
        }
        if (!session.allowedTools().contains(tool)) {
            throw new ForbiddenToolException("租户未开通工具: " + tool);
        }
        if (!session.clientCapabilities().contains("scope:" + need)) {
            throw new ForbiddenToolException("缺少 scope: " + need);
        }
    }
}
```

**两层校验缺一不可**：`allowedTools` 是「这个租户买了哪些能力」（业务开通），`scope` 是「这个 token 被授权做什么」（安全边界）。只查一层，要么越权、要么误拒。

---

## 五、审计：出事了能查

### 5.1 必记字段

| 字段 | 示例 | 用途 |
|---|---|---|
| `trace_id` | `a1b2c3...` | 串起模型调用链 |
| `tenant_id` / `client_id` | `t-1024` | 责任归属 |
| `tool` | `search_docs` | 行为 |
| `args_hash` | `sha256:...` | 去重 + 隐私（不存原文） |
| `args_size` / `result_size` | `256B / 48KB` | 发现异常大请求 |
| `latency_ms` | `123` | 性能 |
| `status` | `ok / error / limited / denied` | 结果分类 |
| `error_code` | `-32001` | 排障 |
| `model` | `gpt-x` / `qwen-y` | 成本归因 |

### 5.2 统一拦截

Spring AI 的 `@Tool` 方法可以用 AOP 统一拦截，避免每个工具手写审计：

```java
@Aspect
@Component
public class ToolAuditAspect {
    private final AuditLogger audit;

    @Around("@annotation(org.springframework.ai.tool.annotation.Tool)")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        McpSession s = McpSessionFilter.current();
        String tool = pjp.getSignature().getName();
        long start = System.nanoTime();
        String status = "ok";
        String err = null;
        int outSize = 0;

        try {
            Object result = pjp.proceed();
            outSize = estimateSize(result);
            return result;
        } catch (Throwable t) {
            status = t instanceof ToolLimitExceededException ? "limited"
                   : t instanceof ForbiddenToolException ? "denied" : "error";
            err = t.getClass().getSimpleName();
            throw t;
        } finally {
            audit.log(new AuditEvent(
                MDC.get("traceId"), s.tenantId(), s.clientId(), tool,
                hashArgs(pjp.getArgs()), estimateArgsSize(pjp.getArgs()), outSize,
                (System.nanoTime() - start) / 1_000_000, status, err,
                MDC.get("model")
            ));
        }
    }
}
```

⚠️ **`args_hash` 而不是 `args` 原文**：工具参数里经常有用户手机号、身份证、订单号。审计日志要能「证明调过」，但不能成为第二个数据泄露面。真要存原文，走加密 + 单独审批的调试通道。

### 5.3 结果大小治理

这是 MCP 特有的一类问题：**工具返回的大 JSON 会直接吃满模型上下文**。

```java
@Component
public class ResultSizeGuard {
    private static final int MAX_CHARS = 8_000;      // 单次工具结果上限
    private static final int MAX_ITEMS = 50;

    public String truncate(String json) {
        if (json == null || json.length() <= MAX_CHARS) return json;
        return json.substring(0, MAX_CHARS) +
            "\n\n[结果已截断：原始长度 " + json.length() +
            " 字符。请缩小查询范围或使用分页参数 offset 继续。]";
    }
}
```

**截断提示必须告诉模型「怎么拿到剩下的」**，否则它会反复重试同样的查询。

---

## 六、超时、取消与幂等

### 6.1 超时分层

| 层 | 建议值 | 说明 |
|---|---|---|
| 工具内部 IO（DB/HTTP） | 3s | 必须小于工具总超时 |
| 工具总超时 | 10s | 超过就返回 `isError` |
| MCP 请求超时（客户端） | 15s | 留缓冲 |
| 会话 TTL | 30min | 见上文 |

```java
public String generateReport(String id) {
    CompletableFuture<String> f = CompletableFuture.supplyAsync(
        () -> doGenerate(id), toolExecutor);
    try {
        return f.get(10, TimeUnit.SECONDS);
    } catch (TimeoutException e) {
        f.cancel(true);          // 尝试中断
        throw new ToolTimeoutException("报告生成超时（10s），请改用摘要模式");
    } catch (Exception e) {
        throw new ToolExecutionException(e.getMessage(), e);
    }
}
```

⚠️ `CompletableFuture.cancel(true)` **不会真的中断正在跑的线程**（它只标记状态）。要真正中断，必须让任务内部响应 `Thread.interrupted()`，或者用 `FutureTask` + 可中断的 IO（NIO Channel / `HttpClient` 的 `cancel`）。

### 6.2 幂等键

有副作用的工具（发邮件、下单、转账）必须支持幂等：

```java
@Tool(description = "发送通知邮件。idempotencyKey 用于去重，相同 key 24 小时内只发一次。")
public String sendEmail(String to, String subject, String body, String idempotencyKey) {
    String k = "mcp:idem:mail:" + idempotencyKey;
    Boolean first = redis.opsForValue().setIfAbsent(k, "1", Duration.ofHours(24));
    if (Boolean.FALSE.equals(first)) {
        return "已发送过（幂等命中），未重复发送。";
    }
    doSend(to, subject, body);
    return "发送成功";
}
```

模型会重试、会重复规划、会在不同轮次调同一个工具。**幂等不是可选项，是 MCP 工具的默认要求。**

---

## 七、可观测指标

| 指标 | 类型 | 告警建议 |
|---|---|---|
| `mcp_tool_calls_total{tool,status}` | Counter | 错误率 > 5% |
| `mcp_tool_latency_seconds{tool}` | Histogram | P99 > 10s |
| `mcp_tool_result_bytes{tool}` | Histogram | P99 > 100KB |
| `mcp_session_active` | Gauge | 突增/突降 30% |
| `mcp_session_miss_total` | Counter | > 0 持续 1min（说明粘滞/存储有问题） |
| `mcp_tool_limited_total{tool,tenant}` | Counter | 单租户突增 |
| `mcp_inflight{tool}` | Gauge | 达到并发上限 80% |

```java
// Micrometer 打点
Timer.builder("mcp.tool.latency")
     .tag("tool", tool)
     .tag("status", status)
     .register(meterRegistry)
     .record(Duration.ofMillis(elapsed));
```

`mcp_session_miss_total` 这个指标特别值得单独告警——它直接反映「会话粘滞失效」或「Redis 挂了」，是 MCP Server 最典型的一类故障。

---

## 八、踩坑清单

1. **多副本不共享 session**：最经典，表现为「概率性 404」。上线前必须多副本压测。
2. **ThreadLocal 不清理**：Tomcat 线程复用导致跨租户串数据。所有 `set` 必须配 `remove` in finally。
3. **审计记了参数原文**：日志成了 PII 泄露源。存 hash。
4. **工具返回超大结果**：撑爆上下文，模型开始胡言乱语。必须截断 + 分页提示。
5. **限流返回协议错误**：模型无法理解，直接失败。应返回 `isError: true` + 可执行建议。
6. **`CompletableFuture.cancel` 以为是停止**：实际只是标记，线程还在跑。
7. **有副作用工具没幂等**：模型重试导致重复发邮件/重复下单。
8. **`resources/subscribe` 在多副本下丢通知**：订阅状态在 Pod 内存里，另一个 Pod 不知道。要么粘滞，要么把订阅关系放 Redis + 广播。
9. **工具描述写得太简**：模型选错工具，然后疯狂试错，token 成本翻倍。「描述即 prompt」，要写清适用场景和限制。
10. **不限制单次会话的总 token**：一个死循环 Agent 能烧掉几百块。必须有会话级预算。

---

## 九、面试追问

**Q1：MCP 为什么是有状态的？多副本怎么解决？**
`initialize` 协商了 protocolVersion、双方 capabilities、session id，后续请求都依赖这些上下文。三条路：会话粘滞（Ingress 按 session id 哈希）、外部会话存储（Redis，推荐）、完全无状态化（客户端带全上下文，需客户端配合）。

**Q2：MCP Server 的限流为什么不能只做全局 QPS？**
工具成本差异巨大：`search_docs` 50ms，`generate_report` 30s 且调 LLM。全局 QPS 限住了轻工具也拦不住重工具堆积。要三维：租户级、工具级、并发级。

**Q3：工具返回内容太大怎么办？**
两层：服务端截断（带「如何取剩余」的提示）+ 工具本身支持分页参数。绝不能直接截断不说，否则模型会重试同样的调用。

**Q4：审计为什么存参数 hash 而不是原文？**
工具参数常含 PII（手机号、身份证）。审计的目标是「可追溯」，hash 足够证明「调过什么」，同时不制造新的泄露面。需要原文时走加密 + 审批的调试通道。

**Q5：MCP 的错误怎么分类？**
协议层错误用 JSON-RPC `error`（-32xxx code，如 session 不存在）；工具执行错误用 `result.isError: true` + 文本内容。分类错了会导致客户端行为异常（该重试的不重试，该终止的反复重试）。

**Q6：怎么防止 Agent 无限调用工具烧钱？**
四道闸：单工具 QPS、单工具并发、会话级调用次数上限、会话级 token 预算。最后一道最关键——它约束的是「总成本」而不是「速率」。

---

## 十、总结

MCP 把「工具接入」标准化了，但**标准化的是协议，不是运维**。生产化要补的六块：

```
会话      → 外部存储 + 滑动续期 + 优雅失效
限流      → 租户 × 工具 × 并发 三维
鉴权      → OAuth token → scope → 工具白名单（两层）
审计      → 全链路 trace + 参数 hash + 结果大小
超时      → 分层超时 + 真正的取消 + 幂等键
可观测    → 七类指标，session_miss 单独告警
```

一句话总结：**MCP Server 不是「暴露几个函数」，而是一个「多租户、有状态、有副作用、成本敏感」的在线服务**。用写微服务的那套工程纪律去对待它，才不会被 Agent 的「不可预测调用」打穿。
