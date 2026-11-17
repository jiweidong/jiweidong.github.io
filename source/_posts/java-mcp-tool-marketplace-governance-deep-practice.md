---
title: 【Java AI】MCP 工具市场治理深度实战：准入、评级、灰度与下线的全生命周期
date: 2026-11-17 08:30:00
tags:
  - Java
  - AI
  - MCP
  - Agent
  - 工程化
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】MCP 工具市场治理深度实战

## 前言

第一版 MCP 接入通常很美好：给 Agent 挂三个工具（查订单、查物流、查库存），Demo 效果惊艳。

半年后变成这样：

- 工具从 3 个涨到 120 个，其中 8 个叫 `query_order`、`get_order_info`、`order_query`，模型随机选一个；
- 某个团队把工具 schema 从 `{"orderId": "string"}` 改成 `{"id": "string"}`，没通知任何人，线上 Agent 静默失败；
- 三个工具的后端服务已经下线两个月，但市场里还挂着，模型每次调用都报错，然后开始"编造"结果；
- 一个工具有 `delete_record` 权限，但没人知道它被哪些 Agent 引用了，不敢下线也不敢收紧。

这些问题的本质是：**工具已经变成了"面向模型的 API 资产"，但治理水平还停留在"配置文件里写几行 JSON"**。

我们已经在四篇 MCP 文章里分别讲过协议原理、Server 生产化、供应链安全、MCP/A2A/OpenAPI 协议对比。本文专攻**市场层（Marketplace）**：工具如何准入、如何评级、如何灰度、如何安全下线，以及一个 Java 侧的统一工具网关怎么实现。

---

## 一、为什么需要独立的"工具市场"层

先明确边界：

| 层次 | 解决的问题 | 本文是否覆盖 |
|---|---|---|
| 协议层（MCP） | 怎么通信、怎么描述工具 | 否 |
| Server 层 | 单个 Server 怎么部署、限流、审计 | 否（已有专文） |
| 供应链安全 | 工具是否被投毒、是否被篡改 | 部分（准入环节） |
| **市场层** | 工具怎么被发现、评级、灰度、下线 | **是** |

市场层的核心价值是把"工具"当成**有生命周期的产品**来管理，而不是一次性的配置。它要回答五个问题：

1. 有哪些工具可用？（发现）
2. 这个工具能不能信？（评级）
3. 这次变更影响谁？（灰度）
4. 谁还在用它？（依赖画像）
5. 什么时候可以下线？（退役）

---

## 二、数据模型：工具清单是第一等公民

```java
public record ToolManifest(
        String toolId,              // 全局唯一，namespace.action 形式
        String displayName,
        String version,             // semver，发布后不可变
        String serverId,
        JsonNode inputSchema,       // JSON Schema 2020-12
        JsonNode outputSchema,
        Set<String> scopes,         // 需要的权限
        String owner,               // 负责团队
        DataClass dataClass,        // PUBLIC / INTERNAL / PII / SECRET
        Duration timeout,
        String slaLevel,            // S0/S1/S2
        Instant deprecationDate,    // null 表示长期支持
        Map<String, String> labels  // 用于检索：域、场景、语言
) {}

public enum DataClass { PUBLIC, INTERNAL, PII, SECRET }
```

四个设计决策：

1. **`toolId` 不可变**：工具重命名是"下线 + 新建"，不是原地改名。否则历史审计全部断链。
2. **`version` 不可变**：同一 version 的 schema 哈希必须固定，任何修改都要发新版本。
3. **`scopes` 显式声明**：工具不能"隐式拥有"调用方权限，必须显式申请。
4. **`dataClass` 决定出网策略**：`SECRET` 级别的工具不允许把结果回传给外部模型。

---

## 三、准入：五道门

### 3.1 Schema 合法性

```java
public class SchemaValidator {

    private final JsonSchemaFactory factory =
            JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);

    public void validate(ToolManifest manifest) {
        // 1. 顶层必须是 object 且有 properties
        JsonNode schema = manifest.inputSchema();
        if (!"object".equals(schema.path("type").asText())) {
            throw new InvalidToolException("inputSchema.type 必须为 object");
        }
        // 2. 必须禁止额外字段，防止模型乱传参数
        if (!schema.path("additionalProperties").isBoolean()
                || schema.path("additionalProperties").asBoolean()) {
            throw new InvalidToolException("inputSchema 必须 additionalProperties=false");
        }
        // 3. 自身必须是合法的 JSON Schema
        factory.getSchema(schema).validate(new ObjectMapper().createObjectNode());
    }
}
```

`additionalProperties=false` 是一条硬性规则。我们线上遇到过模型给 `query_order` 传了 `{"order_id": 123, "explain": true}`，后端把 `explain` 当成 SQL 注释拼进了查询——虽然没造成注入，但暴露了"宽松 schema = 不可控输入"。

### 3.2 命名规范

```text
<domain>.<resource>.<action>
例：order.query.detail、logistics.query.track、refund.apply.create
```

禁止的行为：

- 使用通用名（`query`、`get`、`search`）；
- 同一语义出现多个名字（`getOrder` / `queryOrder` / `fetch_order`）；
- 名字里带版本号（版本用 `version` 字段表达）。

市场侧要做**同义词检测**：把工具描述向量化，相似度 > 0.9 的候选打回，要求合并或明确差异化。

### 3.3 权限最小化

```java
public void checkScopes(ToolManifest manifest) {
    Set<String> forbidden = Set.of("*", "admin", "root");
    if (manifest.scopes().stream().anyMatch(forbidden::contains)) {
        throw new InvalidToolException("禁止使用通配或管理员权限");
    }
    if (manifest.scopes().contains("write") && manifest.dataClass() == DataClass.SECRET) {
        throw new InvalidToolException("SECRET 级数据不允许写操作");
    }
}
```

### 3.4 数据分级与出网审批

| 数据级别 | 示例 | 允许回传模型 | 额外要求 |
|---|---|---|---|
| PUBLIC | 商品介绍 | 是 | 无 |
| INTERNAL | 内部库存 | 是（脱敏） | 字段白名单 |
| PII | 手机号、地址 | 仅脱敏后 | 可逆脱敏 + 审计 |
| SECRET | 密钥、完整身份证 | 否 | 只允许返回布尔/统计值 |

### 3.5 可观测性前置

没有指标的 Server 不允许上架。最低要求：

- 每次调用上报 trace（含 toolId、version、耗时、状态）；
- 错误率、P99 延迟可查询；
- 支持按租户维度切分。

---

## 四、评级：用数据决定工具排序

工具多了以后，模型选错工具是主要错误来源。评级的目的不是"发奖"，而是**给模型和开发者一个排序信号**。

### 4.1 评分模型

| 维度 | 权重 | 计算方式 |
|---|---|---|
| 可用性 | 40% | 1 - 错误率（7 天滑动） |
| 延迟 | 20% | P99 相对 SLA 的达标率 |
| 稳定性 | 15% | 版本变更导致的错误突增次数 |
| 文档质量 | 10% | 描述完整性、示例数、schema 注释 |
| 安全 | 15% | 高危调用拦截率、审计合规 |

```java
public ToolScore score(ToolMetrics m, ToolManifest manifest) {
    double availability = 1.0 - Math.min(1.0, m.errorRate7d());
    double latency = Math.min(1.0, m.slaTargetMs() / Math.max(1, m.p99Ms()));
    double stability = 1.0 - Math.min(1.0, m.regressionCount() / 5.0);
    double docs = docScore(manifest);
    double security = 1.0 - Math.min(1.0, m.securityIncidents() / 3.0);

    double total = availability * 0.40 + latency * 0.20
                 + stability * 0.15 + docs * 0.10 + security * 0.15;
    return new ToolScore(total, grade(total));
}

private String grade(double s) {
    if (s >= 0.95) return "S";
    if (s >= 0.85) return "A";
    if (s >= 0.70) return "B";
    return "C";
}
```

### 4.2 评级怎么用

- **S/A**：默认推荐给模型，出现在工具检索的前列；
- **B**：可用，但在工具超过 30 个时降权；
- **C**：默认隐藏，只有显式指定才注入上下文。

这一步很关键：**工具数量是上下文预算的敌人**。120 个工具的 schema 全塞进 prompt，轻松超过 3 万 token，还会显著降低模型选工具的准确率。评级 + 检索是控制工具上下文的两把刀。

---

## 五、灰度与版本

### 5.1 版本不可变

```text
1.0.0 → 1.0.1（修 bug，schema 不变）
1.1.0 → 新增可选参数
2.0.0 → 删除/重命名参数（breaking change）
```

`2.0.0` 必须保留 `1.x` 至少一个 deprecation 周期，否则线上 Agent 会大面积失败。

### 5.2 分桶灰度

```java
public String resolveVersion(ToolManifest manifest, String tenantId) {
    int bucket = Math.floorMod(
            Hashing.murmur3_32_fixed().hashString(tenantId, UTF_8).asInt(), 10_000);

    if (bucket < manifest.canaryPermille()) {     // 例如 50 = 0.5%
        return manifest.canaryVersion();
    }
    return manifest.stableVersion();
}
```

用 **租户 ID** 而不是请求 ID 分桶，保证同一租户体验一致，否则会出现"同一个用户一会儿成功一会儿失败"。

### 5.3 影子调用

新版本上线前，让 1% 的流量同时调用新旧版本，只对新版本做"记录不返回"：

```java
public ToolResult invokeWithShadow(ToolCall call) {
    ToolResult primary = gateway.invoke(call.toolId(), call.stableVersion(), call.args());

    if (call.shadowEnabled()) {
        CompletableFuture.runAsync(() -> {
            try {
                ToolResult shadow = gateway.invoke(call.toolId(), call.canaryVersion(), call.args());
                shadowComparator.compare(call, primary, shadow);   // 记录差异
            } catch (Exception e) {
                metrics.counter("tool.shadow.error").increment();
            }
        }, shadowExecutor);   // 独立线程池 + 限流，绝不阻塞主链路
        }
    return primary;
}
```

影子调用的三个纪律：**独立线程池、独立限流、结果不参与业务**。

---

## 六、下线：比上线更难

### 6.1 四阶段退役

```text
T-30d：标记 deprecated，市场显示"即将下线"，调用返回 warning 字段
T-14d：只读演练，调用仍成功但记录"僵尸调用方"
T-7d ：对未迁移的调用方发送告警（按 owner 聚合）
T-0  ：拒绝调用，返回明确错误码 TOOL_RETIRED
```

### 6.2 依赖画像

下线前必须知道"谁在用"：

```sql
-- 从 trace 表里聚合调用方
SELECT caller_app, COUNT(*) AS calls, MAX(call_time) AS last_call
FROM tool_invocation_trace
WHERE tool_id = 'order.query.detail'
  AND call_time > NOW() - INTERVAL 90 DAY
GROUP BY caller_app
ORDER BY calls DESC;
```

90 天 0 调用的工具进入"僵尸工具"清单，按月清理。

### 6.3 不允许"静默下线"

这是最容易被忽略的一条。工具直接消失，模型不会报错，而是**换一个工具或者开始编造**。所以下线必须：

1. 在市场里保留 tombstone 记录；
2. 调用时返回结构化错误：`{"error": "TOOL_RETIRED", "replacement": "order.query.detail.v2"}`；
3. 错误信息会进入模型的上下文，让它知道该换工具，而不是瞎猜。

---

## 七、运行时网关：一个入口管所有工具

```java
@Component
public class McpToolGateway {

    private final ToolRegistry registry;
    private final AuthorizationService auth;
    private final RateLimiter rateLimiter;
    private final AuditLogger audit;

    public ToolResult invoke(ToolCall call, CallerContext caller) {
        ToolManifest manifest = registry.resolve(call.toolId(), call.version());

        // 1. 鉴权：调用方是否有该 scope
        auth.check(caller, manifest.scopes());

        // 2. 限流：按 工具 × 租户 双维度
        rateLimiter.acquire(manifest.toolId(), caller.tenantId());

        // 3. 参数校验：schema + 业务规则
        schemaValidator.validate(manifest, call.args());

        // 4. 调用
        long start = System.nanoTime();
        ToolResult result;
        try {
            result = doInvoke(manifest, call.args());
        } catch (Exception e) {
            audit.logFailure(caller, manifest, e);
            throw new ToolInvocationException(manifest.toolId(), e);
        } finally {
            metrics.record(manifest.toolId(), System.nanoTime() - start);
        }

        // 5. 结果净化：按数据分级裁剪字段
        ToolResult sanitized = resultSanitizer.sanitize(manifest.dataClass(), result);

        // 6. 审计：谁、在哪个会话、调了什么、返回多大
        audit.logSuccess(caller, manifest, call.args(), sanitized);
        return sanitized;
    }
}
```

顺序很重要：**鉴权必须在限流之前**（否则未授权请求也能消耗配额），**净化必须在审计之前**（审计日志不能落原始 PII）。

### 7.1 结果净化

```java
public ToolResult sanitize(DataClass level, ToolResult raw) {
    return switch (level) {
        case PUBLIC, INTERNAL -> raw.truncate(MAX_CHARS);
        case PII -> raw.maskFields(PII_FIELDS).truncate(MAX_CHARS);
        case SECRET -> raw.aggregateOnly();   // 只保留统计值
    };
}
```

`truncate` 不是可选项。我们见过一个工具返回 2MB 的 JSON，直接把上下文窗口撑爆，模型开始胡言乱语。

---

## 八、指标：市场健康度

| 指标 | 定义 | 健康阈值 |
|---|---|---|
| 工具重复率 | 语义相似度 > 0.9 的工具对数 / 总对数 | < 5% |
| 僵尸工具率 | 90 天 0 调用 / 总工具数 | < 10% |
| 平均评级 | S/A 占比 | > 60% |
| 工具选择错误率 | 模型选了非预期工具的比例 | < 3% |
| 平均工具数/会话 | 注入上下文的工具数 | < 20 |
| 下线通知覆盖率 | 已通知调用方 / 应通知 | 100% |

其中"平均工具数/会话"最容易被忽略，但它直接决定 token 成本和选择准确率。

---

## 九、踩坑清单

1. **工具名冲突**：`get_order` 和 `query_order` 同时存在，模型随机选。市场层必须做同名/近义检测。
2. **schema 放宽**：为了"兼容"把 `additionalProperties` 设为 true，结果模型传了一堆幻觉参数。
3. **静默下线**：工具消失后模型开始编造结果，比报错更危险。
4. **工具太多**：120 个工具全量注入，token 爆炸 + 准确率下降。必须做检索 + 评级。
5. **权限隐式继承**：工具用调用方的 token 直连业务系统，等于把用户权限放大到工具的全部能力。必须用独立的服务身份 + scope 校验。
6. **审计只记成功**：失败的调用同样需要审计，尤其是权限拒绝和参数校验失败。
7. **版本回滚不彻底**：只回滚了 schema，没回滚后端服务，导致"schema 对但行为不对"。

---

## 十、面试追问

**Q1：MCP 工具市场和 API 网关有什么区别？**

API 网关面向"人/应用"消费，核心是路由、鉴权、限流；工具市场面向"模型"消费，额外需要：工具描述的可读性（模型要能理解）、schema 严格性（模型会乱传参）、评级排序（模型选择能力有限）、tombstone 机制（模型需要知道工具没了）。相同点是都需要统一入口、审计和配额。

**Q2：为什么工具版本必须不可变？**

因为 Agent 的行为依赖工具 schema。可变版本意味着"同一个 toolId 在不同时间有不同契约"，历史 trace 无法复现，回归测试失去基准，出问题也无法定位是模型变了还是工具变了。

**Q3：工具太多导致模型选错，怎么解？**

三层：① 按会话意图做工具检索（RAG over tools），只注入 Top-K；② 用评级做排序和降权；③ 把"工具选择"本身做成一次显式的规划步骤，而不是让模型在 100 个工具里自由发挥。

**Q4：怎么安全地下线一个工具？**

先做依赖画像（trace 聚合调用方），再走四阶段：deprecated 警告 → 只读演练 → 定向告警 → 拒绝调用。拒绝时返回结构化错误和替代工具，让模型能自我纠正。绝不静默删除。

**Q5：工具的结果为什么要净化？**

三个原因：① 防止 PII 进入模型上下文和日志；② 控制 token（大结果会撑爆窗口）；③ 防止提示注入（工具返回的内容里可能藏着指令）。净化应该在网关层统一做，而不是指望每个 Server 自觉。

---

## 总结

工具市场的本质，是把"给模型用的 API"纳入工程治理：

- **准入**靠五道门：schema、命名、权限、分级、可观测；
- **评级**靠数据：可用性、延迟、稳定性、文档、安全；
- **灰度**靠分桶 + 影子调用，租户维度保证体验一致；
- **下线**靠依赖画像 + tombstone，绝不静默消失；
- **运行**靠统一网关：鉴权 → 限流 → 校验 → 调用 → 净化 → 审计。

当工具从 3 个涨到 100 个，决定系统上限的不再是模型能力，而是**你管理这 100 个工具的能力**。
