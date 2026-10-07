---
title: 【系统设计】高并发告警系统架构设计：告警收敛、降噪、分级与值班升级全解析
date: 2026-10-07 08:40:00
tags:
  - 系统设计
  - 告警系统
  - 高可用
  - 可观测性
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】高并发告警系统架构设计：告警收敛、降噪、分级与值班升级全解析

## 面试官：监控告警一晚上发了 2000 条，怎么让它"不扰民"？

> "我们有 300 个服务、5 万台机器、每分钟产生百万级指标。现在的问题是：一个数据库抖动，相关服务全部触发告警，值班同学一晚上收到 2000 条告警，最后干脆把手机静音了——真出事也发现不了。你会怎么设计告警系统？"

这道题看着是"监控"，本质是**高并发 + 流式计算 + 状态管理 + 通知调度**的综合系统设计题。它比秒杀、订单那种"典型电商题"更贴近真实工程，也更容易被问到细节。

我们把答案拆成四层：**采集与规则评估 → 收敛降噪 → 分级与升级 → 通知与限流**。

## 一、告警全链路

```
指标/日志/事件
   │
   ▼
① 规则评估引擎（流式计算：Flink / 自研窗口）
   │  产出原始告警事件 AlertEvent
   ▼
② 收敛降噪层（Fingerprint 去重 / 分组 / 抑制 / 静默 / 抖动抑制）
   │  产出去重后的告警实例 AlertInstance
   ▼
③ 分级与路由（P0~P3、订阅关系、标签路由）
   │
   ▼
④ 通知与升级（渠道限流、值班排班、超时升级、失败重试）
   │
   ▼
⑤ 记录与追溯（告警历史、处理时间线、复盘数据）
```

设计目标定四个字：**准、快、少、全**——告警要准（不误报）、快（延迟秒级）、少（不刷屏）、全（不遗漏）。

任何两个都容易冲突：**要"少"就会漏，要"全"就会吵**。系统的价值就在于用**收敛算法**在中间找平衡。

## 二、第 ① 层：规则评估引擎

规则本质上是一条**带时间窗口的流式判断**：

```yaml
# 规则定义（示意）
rule:
  id: cpu_high
  metric: node_cpu_usage
  expression: "avg(5m) > 85"
  duration: "2m"          # 持续 2 分钟才触发，过滤瞬时尖峰
  forShard: groupBy(instanceId)
  severity: P2
  labels: [host, cluster, service]
```

用 Flink 表达大致是：

```java
DataStream<AlertEvent> alerts = metricStream
    .keyBy(Metric::getSeriesKey)                 // 按时间序列分组
    .window(SlidingEventTimeWindows.of(Time.minutes(5), Time.seconds(30)))
    .aggregate(new AvgAggregate())
    .filter(avg -> avg.getValue() > rule.getThreshold())
    .keyBy(Metric::getSeriesKey)
    .process(new DurationTrigger(rule.getDuration()))   // 持续 N 分钟才下发
    .map(AlertEvent::from);
```

### 为什么必须"持续 N 分钟才触发"？

这是**第一层降噪**。指标是带毛刺的：GC、定时任务、批量作业都会造成瞬时飙高。如果 1 个点的尖峰就告警，误报率会高到值班同学怀疑人生。

经验值：

| 指标类型 | 持续时间窗口 | 说明 |
| --- | --- | --- |
| CPU / 内存 | 2~5 分钟 | 瞬时尖峰常见，窗口要长 |
| 接口错误率 | 1~2 分钟 | 错误率是真信号，窗口可短 |
| 磁盘 / 连接数 | 5~10 分钟 | 缓慢变化，窗口取长减少抖动 |
| 进程存活 | 30 秒 × 3 次 | 需要快速发现，但要防网络抖动 |

**更高级的做法是"双阈值"**：高阈值立即触发（P1），低阈值持续触发（P3）。这样既能快速发现严重问题，又不会为轻微波动刷屏。

## 三、第 ② 层：收敛降噪（核心竞争力）

这里是告警系统真正的技术含量所在。六种手段，按顺序串联：

### 1. Fingerprint：给告警一个稳定身份

每条告警生成一个**指纹**，作为去重与状态跟踪的主键：

```java
public static String fingerprint(AlertEvent e) {
    String raw = String.join("|",
            e.getRuleId(),
            nullSafe(e.getLabels().get("cluster")),
            nullSafe(e.getLabels().get("service")),
            nullSafe(e.getLabels().get("instance")),
            nullSafe(e.getLabels().get("metric")));
    return DigestUtils.md5Hex(raw);   // 或 SHA-256
}
```

**指纹包含什么、不包含什么是设计要点**：

- 包含：规则 ID、集群、服务、实例、指标——这些决定"是不是同一件事"；
- 不包含：告警值、时间戳、traceId——这些会变化，包含进去就永远无法去重。

指纹相同 → 认为是**同一个告警实例的不同状态变化**。

### 2. 状态机：从 Firing 到 Resolved

告警不是"事件"而是"状态"。用状态机避免"同一个问题反复通知"：

```
         触发              恢复
  OK ──────────▶ FIRING ──────────▶ RESOLVED
   ▲               │                    │
   │               │ 再次触发（值变化）  │
   └───────────────┴────────────────────┘
```

只有 **OK → FIRING** 时才发"告警通知"，**FIRING → RESOLVED** 时才发"恢复通知"。中间值持续变化一律**不重复通知**（只更新记录）。

这一步就能砍掉 **80% 的重复告警**：过去那种"每分钟发一条 CPU 高"的刷屏，本质是把状态变化当成了独立事件。

### 3. 分组（Grouping）：把 500 条合并成 1 条

按指定标签聚合，同一组内只发一条摘要：

```java
// group by cluster + service，30s 窗口内的告警合并成一条
GroupKey key = GroupKey.of(alert.getLabels().get("cluster"),
                           alert.getLabels().get("service"));
groupBuffer.computeIfAbsent(key, k -> new AlertGroup(k))
           .add(alert, Duration.ofSeconds(30));
```

一个机房断电会导致 500 台机器同时失联。分组后变成一条："`cluster=shanghai` 下 500 个实例失联"。值班同学一眼看懂，而不是被 500 条淹没。

### 4. 抑制（Inhibition）：根因优先，屏蔽派生

规则之间声明依赖关系：**A 触发时，B 不再通知**。

```yaml
inhibit_rules:
  - source: "cluster_down"          # 根因
    target: "service_unavailable"   # 被抑制
    equal: [cluster]
```

机器宕机 → 上面的服务必然不可用 → 只要通知"机器宕机"就够了，服务告警全部抑制。这是从"500 条噪音"到"1 条根因"的关键一跳。

### 5. 静默（Silence）与维护窗口

运维做变更、发布、扩容时，主动声明"这段时间别报"：

```java
public record Silence(String matcher, Instant startsAt, Instant endsAt,
                      String createdBy, String comment) { }
```

匹配方式用标签表达式（如 `service=order AND env=prod`），并且**必须带到期时间**——永久静默是事故温床。实践建议单次静默不超过 4 小时，且强制填写原因。

### 6. 抖动抑制（Flapping Detection）

有的服务在阈值上下反复横跳，导致"告警-恢复-告警-恢复"循环。检测方式：

```java
// 滑动窗口内统计状态切换次数，超过阈值则进入"抖动"状态，延长通知间隔
if (stateChanges.inLast(Duration.ofMinutes(10)) > 6) {
    alert.markFlapping(true);
    notifier.throttleTo(Duration.ofMinutes(30));   // 降频到 30 分钟一次
}
```

Prometheus Alertmanager 就内置了类似逻辑（`resolve_timeout` + 分组等待），自研系统必须自己实现。

## 四、第 ③ 层：分级与路由

### 告警分级标准

| 级别 | 定义 | 响应 | 通知方式 |
| --- | --- | --- | --- |
| P0 / Critical | 核心链路不可用、资损 | 立即，5 分钟内 | 电话 + 短信 + IM + 全员群 |
| P1 / Major | 核心功能降级、容量告急 | 15 分钟内 | 短信 + IM + 值班群 |
| P2 / Minor | 非核心异常、指标越界 | 1 小时内 | IM + 邮件 |
| P3 / Info | 需要关注但不紧急 | 工作时间处理 | 邮件 / 工单 |

**分级不能由"指标类型"决定，必须由"影响面"决定**。同样 CPU 90%，在核心支付集群是 P1，在测试环境是 P3。所以规则里必须支持**环境标签 + 业务权重**的联合计算：

```java
Severity calcSeverity(AlertEvent e) {
    int base = rule.getSeverity().getLevel();            // 规则基线
    int weight = businessWeight(e.getLabels());          // 业务权重（核心链路 2，边缘 0）
    boolean prod = "prod".equals(e.getLabels().get("env"));
    int level = prod ? base - weight : base + 2;         // 非生产环境直接降到 P2/P3
    return Severity.of(clamp(level, 0, 3));
}
```

### 路由：告警该发给谁

路由按标签树匹配（Alertmanager 的 `route` 模型）：

```yaml
route:
  receiver: default-im
  group_by: [cluster, service]
  routes:
    - matchers: [env="prod", severity="P0"]
      receiver: oncall-phone
      repeat_interval: 5m
    - matchers: [team="payment"]
      receiver: payment-team-im
    - matchers: [env="test"]
      receiver: dev-null          # 黑洞，直接丢弃
```

## 五、第 ④ 层：通知与升级

### 通知限流：防止"告警风暴"打爆渠道

短信网关、电话 API 都是有配额和成本的。必须限流：

```java
public class NotifyRateLimiter {

    // 按"接收人 + 渠道"限流：同一人同一渠道，5 分钟内最多 3 条
    private final Cache<String, RateLimiter> limiters =
            Caffeine.newBuilder().expireAfterAccess(Duration.ofMinutes(10)).build();

    public boolean allow(String receiver, Channel channel) {
        RateLimiter limiter = limiters.get(receiver + ":" + channel,
                k -> RateLimiter.of(k, RateLimiterConfig.custom()
                        .limitForPeriod(3)
                        .limitRefreshPeriod(Duration.ofMinutes(5))
                        .timeoutDuration(Duration.ZERO)
                        .build()));
        return limiter.acquirePermission();
    }
}
```

超过限额的告警**不是丢弃，而是降级**：短信 → IM，IM → 邮件，聚合成"过去 5 分钟还有 47 条告警"一条摘要。

### 值班与升级（Escalation）

升级策略要时间驱动 + 确认驱动：

```
T+0     发送 P1 到值班 IM
T+5min  未被认领（ack）→ 补发短信
T+10min 仍未认领 → 电话呼叫值班人
T+15min 仍未认领 → 升级到 backup 值班
T+30min 仍未认领 → 升级到 leader / 全员群
```

**"认领（acknowledge）"是核心概念**：值班同学点一下"我看到了"，升级链就停。这既避免了重复打扰，也留下了"谁在什么时候响应"的审计数据，是复盘的基础。

### 通知的可靠投递

通知本身也要高可用：**发失败要重试，但不能重试到刷屏**。

```java
@Retryable(
    retryFor = { IOException.class },
    maxAttempts = 3,
    backoff = @Backoff(delay = 1000, multiplier = 2)
)
public void send(Notification n) { ... }
```

重试用**指数退避 + 上限**，超过上限进死信队列（DLQ）落库，由独立的补偿任务扫描，避免"通知失败"本身演变成"通知风暴"。

## 六、数据模型设计

四张核心表就够：

```sql
-- 1. 告警规则
CREATE TABLE alert_rule (
  id            BIGINT PRIMARY KEY AUTO_INCREMENT,
  name          VARCHAR(128) NOT NULL,
  expression    VARCHAR(512) NOT NULL,       -- 阈值表达式
  duration_sec  INT NOT NULL DEFAULT 120,    -- 持续时长
  severity      TINYINT NOT NULL,            -- 0~3
  labels        JSON NOT NULL,               -- 匹配标签
  enabled       TINYINT NOT NULL DEFAULT 1,
  version       INT NOT NULL DEFAULT 1,
  updated_at    DATETIME NOT NULL
);

-- 2. 告警实例（按指纹唯一，状态机载体）
CREATE TABLE alert_instance (
  id            BIGINT PRIMARY KEY AUTO_INCREMENT,
  fingerprint   CHAR(32) NOT NULL,
  rule_id       BIGINT NOT NULL,
  status        VARCHAR(16) NOT NULL,        -- FIRING / RESOLVED / ACKED
  severity      TINYINT NOT NULL,
  labels        JSON NOT NULL,
  current_value DECIMAL(20,4),
  started_at    DATETIME NOT NULL,
  updated_at    DATETIME NOT NULL,
  resolved_at   DATETIME,
  acked_by      VARCHAR(64),
  acked_at      DATETIME,
  UNIQUE KEY uk_fp_status (fingerprint, status),
  KEY idx_status_sev (status, severity)
);

-- 3. 订阅关系（谁关心什么）
CREATE TABLE alert_subscription (
  id            BIGINT PRIMARY KEY AUTO_INCREMENT,
  matchers      JSON NOT NULL,               -- 标签匹配表达式
  channels      JSON NOT NULL,               -- [IM, SMS, PHONE, EMAIL]
  receiver_type VARCHAR(16) NOT NULL,        -- USER / TEAM / ROTA
  receiver_id   VARCHAR(64) NOT NULL,
  enabled       TINYINT NOT NULL DEFAULT 1
);

-- 4. 通知记录（审计 + 去重 + 复盘）
CREATE TABLE alert_notification (
  id            BIGINT PRIMARY KEY AUTO_INCREMENT,
  instance_id   BIGINT NOT NULL,
  channel       VARCHAR(16) NOT NULL,
  receiver      VARCHAR(64) NOT NULL,
  status        VARCHAR(16) NOT NULL,        -- SENT / FAILED / THROTTLED
  error_msg     VARCHAR(512),
  sent_at       DATETIME NOT NULL,
  KEY idx_instance (instance_id)
);
```

**为什么 `alert_instance` 要按 `fingerprint + status` 建唯一索引？** 用数据库的唯一约束兜底幂等——高并发下可能有多个评估节点同时产出同一指纹的告警，靠 insert 冲突来收敛，比应用层加锁更可靠。

## 七、高可用与性能设计

| 关注点 | 方案 |
| --- | --- |
| 规则评估吞吐 | Flink / Kafka Streams 水平扩展，按 `seriesKey` 分区保证同序列状态一致 |
| 去重状态存储 | Redis（`SETNX` 指纹）+ 本地 Caffeine 多级缓存 |
| 状态持久化 | Redis 定期快照 + 落库 `alert_instance`，重启可恢复 |
| 通知解耦 | 收敛后写 Kafka topic，通知服务独立消费，避免慢渠道阻塞评估 |
| 防单点 | 评估服务无状态多副本，Redis 集群 / Sentinel 高可用 |
| 防雪崩 | 通知侧独立限流 + 熔断（渠道挂了不影响告警记录落库） |
| 时钟一致 | 全链路 NTP，窗口以 **事件时间** 而非处理时间计算 |
| 数据量治理 | `alert_notification` 按月分区，历史归档到对象存储 |

**关于"用哪个窗口"**：一定要用**事件时间（event time）+ watermark**，而不是处理时间。否则网络抖动导致数据乱序时，同一个"5 分钟窗口"在不同节点算出的结果不一致，告警会飘。

## 八、面试追问速查

| 追问 | 回答要点 |
| --- | --- |
| 怎么防止同一个问题反复通知？ | 状态机 + 指纹：只在 OK→FIRING 和 FIRING→RESOLVED 两个跃迁时通知；再加 `repeat_interval` 兜底 |
| 机器宕机导致 500 条告警怎么办？ | 分组（按 cluster/service）+ 抑制（根因规则抑制派生规则） |
| 误报太多怎么优化？ | 拉长持续时间窗口、双阈值、引入同比/环比动态基线、维护期静默 |
| 怎么保证不漏报？ | 收敛只影响"通知"，不影响落库；所有原始告警事件都持久化，可回放 |
| 通知渠道挂了怎么办？ | 渠道级熔断 + 降级链（电话→短信→IM→邮件）+ 死信重试 |
| 如何支持动态规则？ | 规则存 DB + 配置版本号，评估引擎监听变更（Redis Pub/Sub 或 Nacos 长轮询）热更新 |
| 告警延迟要求？ | 秒级到分钟级：评估 ≤30s，收敛窗口 ≤30s，通知 ≤10s，总延迟控制在 1~2 分钟 |
| 怎么评估告警质量？ | 指标：告警量/人·天、误报率、MTTA（平均响应时间）、MTTR、被静默比例、ack 率 |

## 小结

告警系统的设计哲学，一句话概括：

> **用流式计算解决"算得快"，用状态机 + 指纹解决"不重复"，用分组 + 抑制 + 静默解决"不刷屏"，用分级 + 升级解决"不漏掉"。**

四个模块各解决一个问题，缺一个都会退化：没有状态机 → 刷屏；没有抑制 → 噪音淹没根因；没有升级 → 半夜没人理；没有落库 → 复盘无据可依。

**最后一句大实话**：再好的告警算法也救不了"阈值拍脑袋"的规则。让告警"准"，60% 靠规则治理，40% 才靠系统设计。所以成熟团队都会做**告警治理专项**——每月盘一次"Top 20 最吵的规则"，这才是把值班同学从手机静音里救出来的真正办法。
