---
title: 【可观测性】Prometheus 指标基数爆炸治理：从 label 设计到 Micrometer 注册表
date: 2026-11-27 08:10:00
tags:
  - Java
  - Prometheus
  - Micrometer
  - 可观测性
  - 生产实战
categories:
  - 可观测性
author: 东哥
---

# 【可观测性】Prometheus 指标基数爆炸治理：从 label 设计到 Micrometer 注册表

## 前言

一个周五下午，监控大盘突然大片空白，Prometheus 报 `out of memory`，被 OOMKilled 重启；重启后加载 WAL 又 OOM，循环了四次。

排查到最后，罪魁祸首是一行看起来很正常的 Spring Boot 代码：

```java
@Timed(value = "http.requests", extraTags = {"path"})
```

不，真正的元凶是 `path` 这个 tag 取到了**原始 URI**：

```
http_requests_total{path="/order/2026112700012345", status="200"} 1
http_requests_total{path="/order/2026112700012346", status="200"} 1
```

每天 200 万个订单 → 每天新增 200 万条时间序列。一周后，这个指标单独贡献了 **1400 万 series**，占满了整个 Prometheus 的内存。

这就是**基数爆炸（cardinality explosion）**：指标名不多，但 label 取值的组合数失控。它是 Prometheus 体系里最贵、也最常见的故障。

这篇文章讲清楚：基数为什么贵、Java 侧有哪五类爆炸源、怎么用 Micrometer 在**产生端**拦住、Prometheus 侧怎么兜底、以及一套可落地的治理流程。

---

## 一、先算清楚：基数到底有多贵

### 1.1 series 数量 = 指标 × label 值组合

Prometheus 的时间序列由 `指标名 + 全部 label` 唯一确定。假设：

```java
Counter.builder("biz_requests_total")
    .tag("tenant", tenantId)     // 2000 个租户
    .tag("endpoint", uri)        // 50 个接口
    .tag("status", status)       // 6 种状态
    .tag("region", region)       // 5 个地域
    .register(registry).increment();
```

理论组合数：`2000 × 50 × 6 × 5 = 300 万` series。每个 series 至少要有：

- TSDB 的 series 元数据（label 集合、指纹）；
- 倒排索引条目（每个 label value 一条 posting）；
- head block 里的 chunk 引用与样本。

工程经验值：**每条 active series 在 Prometheus head 中约占 2~4KB**（含索引与 chunk 预分配）。

300 万 series × 3KB ≈ **9GB 内存**。一个 16GB 的 Prometheus 直接被打穿。

### 1.2 磁盘也会跟着涨

| 参数 | 数值 |
|---|---|
| series 数 | 100 万 |
| 采样间隔 | 15s（每分钟 4 点） |
| 每点大小（压缩后） | ~1.5 字节 |
| 每天样本数 | 100万 × 4 × 60 × 24 = 5.76 亿 |
| 每天磁盘 | 5.76亿 × 1.5B ≈ 0.86GB |
| 保留 15 天 | ≈ 13GB |

看起来还好？把 series 换成 1000 万，就是 130GB；再叠加 remote write 的副本与多集群，成本会指数级上升。**基数优化的收益不是"省一点磁盘"，而是"让系统从崩溃边缘回来"。**

### 1.3 基数还会拖慢查询

PromQL 的 `rate(http_requests_total[5m])` 需要遍历所有匹配的 series。series 从 10 万涨到 1000 万，同样的查询从 200ms 变成 20s，Grafana 面板集体超时，值班同学以为"监控坏了"，实际上是"监控被自己的指标压死了"。

---

## 二、Java 侧的五类爆炸源

### 2.1 URI 直接进 label（最高频）

```java
// 反面教材
registry.counter("http_requests_total",
    "uri", request.getRequestURI(),   // /order/12345
    "method", request.getMethod(),
    "status", String.valueOf(response.getStatus())
).increment();
```

Spring Boot 2.x 的 `WebMvcTagsProvider` 默认会尝试用 `HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE` 拿到模板路径（`/order/{id}`），但如果：

- 请求没匹配到 Controller（404），pattern 为 null，退化成正的真实路径；
- 用了 `@RequestMapping("${dynamic}")` 或网关转发；
- 自定义了 `WebMvcTagsProvider` 且没保留模板逻辑；

就会退化成原始 URI。**404 扫描是最典型的触发场景**：攻击者扫 `/admin.php`、`/.env`，每个路径都生成一条 series，一晚上能打出几十万 series。

Spring Boot 3.x 改用 Observation API，正确姿势是自定义 `ServerRequestObservationConvention`：

```java
@Component
public class TemplatedUriConvention extends DefaultServerRequestObservationConvention {

    @Override
    public KeyValues getLowCardinalityKeyValues(ServerRequestObservationContext context) {
        String uri = context.getCarrier().getAttribute(
            HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);

        // 没匹配到就归一到 UNKNOWN，绝不使用原始 URI
        String normalized = (uri == null) ? "UNKNOWN" : uri;

        // 再兜一层：路径参数之外的高基数片段（UUID、数字段）做模式化
        normalized = normalized.replaceAll("/[0-9a-fA-F-]{16,}", "/{id}")
                               .replaceAll("/\\d+", "/{n}");

        return super.getLowCardinalityKeyValues(context)
                    .and("uri", normalized);
    }
}
```

关键原则：**label 只能是"有限枚举"，不能是"用户输入"。**

### 2.2 动态业务维度

| 危险 label | 典型取值数 | 正确处理 |
|---|---|---|
| `userId` / `tenantId` | 万~百万 | 移到日志/trace；指标只留"租户等级"（free/pro/ent） |
| `orderId` / `traceId` | 无限 | 绝对禁止；用 exemplar 关联 |
| `exception.getMessage()` | 无限（含参数） | 用异常类名 + 错误码枚举 |
| `sql` 原文 | 无限 | 用 MyBatis statement id 或 SQL 指纹 |
| `clientIp` | 万级 | 只保留网段/地域，明细进日志 |
| `podName` | 百级（会滚动） | 可接受，但要用 `pod` 而非 `podName+revision` |

一条经验法则：**任何 label 的取值集合如果无法在代码里写成一个 `enum`，它就不该是 label。**

### 2.3 Histogram 桶数放大

Histogram 每个桶都是一条独立 series（`_bucket{le="..."}`），再加 `_sum` / `_count`。一个默认桶配置的 histogram：

```
http_server_requests_seconds_bucket{le="0.005"} 
... 共 15 个桶
+ _sum + _count
= 17 条 series / 每组 label
```

如果你有 50 个接口 × 6 个状态 × 15 个桶 = 4500 series，看起来不多；但一旦把 `uri` 换成真实路径，立刻变成 50 万 × 15。

治理手段：

- 只给核心接口开 histogram，其余用 summary 或只记 count；
- 桶按业务 SLO 定制（P50/P95/P99 附近加密，其余稀疏），不要用默认的 15 个；
- 高基数维度用 **native histogram**（Prometheus 2.40+ / OTel exponential histogram），它用稀疏表示，桶数不直接等于 series 数。

### 2.4 客户端默认 tag 与"环境标签"叠加

Micrometer 的 `commonTags` 常被塞进 `env`、`region`、`az`、`cluster`、`app`、`version`、`pod`、`node` 八个维度。八个维度本身不爆炸（每个都是有限枚举），但它们会和业务 label 做**笛卡尔积放大**：

```
(env 3) × (region 5) × (az 15) × (version 20 次发布) × (pod 200) = 90 万
```

其中 `version` 是最阴险的：每次发布新增一个版本号，旧 series 要等 5 分钟 stale 才失效，但如果你在做 A/B 或金丝雀，长期并存 5~10 个版本，基数直接翻十倍。

**建议**：`version` 只保留在 trace/log，指标里用 `major.minor` 或不带。

### 2.5 多实例 × 多指标的乘法效应

单看每个指标的 label 都"只有几十个值"，但 JVM 指标本身就有 200+ 个（`jvm_memory_used_bytes` 按 area×id、`jvm_gc_*` 按 cause、`http_server_requests` 按 uri×status×exception...）。

一个中等规模的 Spring Boot 应用，**默认 Micrometer + Actuator 就能产出 500~1500 series/pod**。100 个 pod 就是 5 万~15 万 series，这还没算业务指标。

所以治理的第一步永远是：**先量出来，再谈优化。**

---

## 三、定位：先找到"谁在贡献基数"

### 3.1 Prometheus 自带接口

```bash
# 按指标名排序的 series 数 Top 20
curl -s http://prom:9090/api/v1/status/tsdb | jq '
  .data.seriesCountByMetricName[:20]'

# label 值数量 Top（哪个 label 在膨胀）
curl -s http://prom:9090/api/v1/status/tsdb | jq '
  .data.labelValueCountByLabelName[:20]'

# 单个 label 的内存占用
curl -s http://prom:9090/api/v1/status/tsdb | jq '
  .data.memoryInBytesByLabelName[:20]'
```

### 3.2 PromQL 侧

```promql
# 每个指标的 series 数（注意：本身也可能很贵，低峰期跑）
topk(20, count by (__name__) ({__name__=~".+"}))

# 某个 label 的取值数量
count(count by (uri) (http_server_requests_seconds_count))

# 抓取侧：每个 target 抓了多少样本
topk(20, scrape_samples_scraped)
```

`scrape_samples_scraped` 是最实用的入口指标：它告诉你"每个 pod 贡献了多少样本"，除以 pod 数就是单实例基数。

### 3.3 Java 侧离线分析

不用连 Prometheus，直接在应用里把注册表 dump 出来：

```java
@Component
public class CardinalityReporter {

    private final MeterRegistry registry;

    @Scheduled(fixedDelay = 3_600_000)
    public void report() {
        Map<String, Long> byName = registry.getMeters().stream()
            .collect(Collectors.groupingBy(
                m -> m.getId().getName(), Collectors.counting()));

        byName.entrySet().stream()
              .sorted(Map.Entry.<String, Long>comparingByValue().reversed())
              .limit(20)
              .forEach(e -> log.warn("meter={} series={}", e.getKey(), e.getValue()));

        // 高危 label 扫描：某个 tag key 的取值数
        Map<String, Set<String>> tagValues = new HashMap<>();
        registry.getMeters().forEach(m -> m.getId().getTags().forEach(t ->
            tagValues.computeIfAbsent(t.getKey(), k -> new HashSet<>()).add(t.getValue())));

        tagValues.forEach((k, v) -> {
            if (v.size() > 100) {
                log.error("HIGH CARDINALITY TAG: {} has {} distinct values", k, v.size());
            }
        });
    }
}
```

这段代码应该加到所有核心服务的启动自检里——**基数问题必须在产生端发现，等 Prometheus 报 OOM 就晚了。**

---

## 四、治理六招（按优先级排序）

### 4.1 第一招：label 白名单

在代码评审阶段就卡住：新增 label 必须在 `METRIC_LABEL_WHITELIST` 里注册，且注明取值上限。

```java
public final class MetricLabels {
    // key -> 允许的最大取值数
    public static final Map<String, Integer> LIMITS = Map.of(
        "uri", 200, "method", 10, "status", 20, "exception", 50,
        "tenant_tier", 3, "region", 10
    );
}
```

### 4.2 第二招：Micrometer MeterFilter 硬拦截

Micrometer 提供了内置的基数守卫，这是**性价比最高的一招**：

```java
@Configuration
public class MetricsGuardConfig {

    @Bean
    public MeterFilter cardinalityGuard() {
        // 单个指标名 + 单个 tag key，最多允许 100 个不同取值
        // 超出的 meter 直接 DENY，并可通过 onMeterDenied 打点告警
        return MeterFilter.maximumAllowableTags(
            "http.server.requests", "uri", 100,
            MeterFilterReply.DENY);
    }

    @Bean
    public MeterFilter globalTagGuard() {
        return new MeterFilter() {
            @Override
            public MeterFilterReply accept(Meter.Id id) {
                for (Tag tag : id.getTags()) {
                    Integer limit = MetricLabels.LIMITS.get(tag.getKey());
                    if (limit == null && !SAFE_TAGS.contains(tag.getKey())) {
                        // 未注册的 tag key 一律拒绝（灰度期可先 WARN）
                        log.warn("deny unknown tag key={} meter={}",
                                 tag.getKey(), id.getName());
                        return MeterFilterReply.DENY;
                    }
                    if (limit != null && tag.getValue().length() > 64) {
                        return MeterFilterReply.DENY;
                    }
                }
                return MeterFilterReply.NEUTRAL;
            }
        };
    }
}
```

`MeterFilterReply` 的三个取值：

| 返回值 | 行为 | 用途 |
|---|---|---|
| `ACCEPT` | 立即接受，跳过后续 filter | 白名单快速通道 |
| `NEUTRAL` | 交给下一个 filter | 默认 |
| `DENY` | 丢弃该 meter | 兜底拦截 |

注意 `DENY` 是**静默丢弃**，所以一定要配 `onMeterDenied` 回调或日志，否则你会"优化"掉关键指标而不自知。

### 4.3 第三招：把高基数维度赶到 trace / log

指标回答"整体趋势"，trace 回答"这一次为什么慢"，log 回答"具体是谁"。三者职责不同，别让指标干 trace 的活。

```java
// 错误：userId 进 metric
Counter.builder("order_created_total").tag("userId", uid).register(r).increment();

// 正确：metric 只留可聚合维度，userId 进 trace baggage / 日志 MDC
Span.current().setAttribute("user.id", uid);
MDC.put("userId", uid);
Counter.builder("order_created_total")
       .tag("channel", channel)      // 枚举：app/web/api
       .tag("payType", payType)      // 枚举
       .register(r).increment();
```

需要"从指标跳到具体请求"时，用 **exemplar**：Micrometer 1.11+ 支持把 traceId 写入 exemplar，Grafana 可以直接从 P99 的点跳到那条 trace，完全不增加 series。

### 4.4 第四招：histogram 桶精简

```java
@Bean
public MeterRegistryCustomizer<MeterRegistry> histogramTuning() {
    return registry -> registry.config().meterFilter(
        new MeterFilter() {
            @Override
            public DistributionStatisticConfig configure(Meter.Id id,
                    DistributionStatisticConfig config) {
                if (id.getName().startsWith("http.server.requests")) {
                    return DistributionStatisticConfig.builder()
                        // 只保留 SLO 相关的 6 个桶
                        .serviceLevelObjectives(
                            Duration.ofMillis(50).toNanos(),
                            Duration.ofMillis(100).toNanos(),
                            Duration.ofMillis(300).toNanos(),
                            Duration.ofMillis(1000).toNanos(),
                            Duration.ofMillis(3000).toNanos())
                        .percentilesHistogram(false)
                        .build()
                        .merge(config);
                }
                return config;
            }
        });
}
```

桶从 15 个降到 5 个，`_bucket` series 直接减少 2/3。对绝大多数业务，"P99 落在 300ms 还是 1s 桶"比"精确到 5ms"更有意义。

### 4.5 第五招：Prometheus 侧 relabel 兜底

客户端改不完（老服务、第三方 exporter）时，在抓取侧做最后一道防线：

```yaml
scrape_configs:
  - job_name: 'spring-boot'
    metric_relabel_configs:
      # 1) 直接丢弃高基数指标
      - source_labels: [__name__]
        regex: 'http_requests_total_by_user.*'
        action: drop

      # 2) 把高基数 label 直接删除（指标保留，维度丢失）
      - regex: 'userId|orderId|traceId'
        action: labeldrop

      # 3) 值改写：把无限取值映射到有限桶
      - source_labels: [uri]
        regex: '/order/[0-9]+'
        target_label: uri
        replacement: '/order/{id}'

      # 4) 保留策略：只留白名单 label
      - regex: 'instance|job|app|env|uri|method|status|exception'
        action: labelkeep
```

`labelkeep` 是最强硬也最有效的一招——**白名单式保留，其余全丢**。风险是可能丢掉你后面想用的维度，建议先在测试环境跑一周对比。

注意：`metric_relabel_configs` 在**抓取后、入库前**执行，所以 `scrape_samples_scraped` 仍然包含被丢弃的样本，`scrape_samples_post_metric_relabeling` 才是入库量。这两个指标的差值就是 relabel 的收益。

### 4.6 第六招：预聚合并分层存储

- **recording rules**：把高频查询预先聚合成低基数指标（如 `job:http_request_rate5m`），面板查聚合结果而不是原始 series；
- **remote write 到 Mimir/Thanos**：短期高精度留在本地 Prometheus，长期降采样归档；
- **按租户分片**：多租户平台把大租户拆到独立 Prometheus 实例，避免"一个租户打挂所有人"。

---

## 五、治理流程：从告警到闭环

```
1. 发现
   ├─ 告警：PrometheusSeriesLimitApproaching（head series > 80% 限额）
   ├─ 告警：scrape_samples_scraped 周环比 > 30%
   └─ 巡检：每周跑一次 topk series 报表

2. 定位
   ├─ /api/v1/status/tsdb → seriesCountByMetricName
   ├─ labelValueCountByLabelName → 哪个 label 在膨胀
   └─ 应用侧 CardinalityReporter → 哪个 pod / 哪个 meter

3. 止血
   ├─ Prometheus 侧 labeldrop / drop（分钟级生效）
   └─ 应用侧 MeterFilter DENY（需发布）

4. 根治
   ├─ 改 label 设计（枚举化、模板化）
   ├─ 高基数维度迁到 trace/log
   └─ 加 CI 门禁：新增 label 必须注册上限

5. 防回归
   ├─ 单元测试断言 tag 集合（SimpleMeterRegistry）
   └─ 发布前对比 scrape_samples_scraped 基线
```

### 5.1 CI 门禁示例

```java
@Test
void uriTagMustBeTemplated() {
    MockMvc mockMvc; // 注入
    SimpleMeterRegistry registry = new SimpleMeterRegistry();

    // 打两个不同 id 的请求
    mockMvc.perform(get("/order/1001"));
    mockMvc.perform(get("/order/1002"));

    Set<String> uris = registry.getMeters().stream()
        .filter(m -> m.getId().getName().equals("http.server.requests"))
        .flatMap(m -> m.getId().getTags().stream())
        .filter(t -> t.getKey().equals("uri"))
        .map(Tag::getValue)
        .collect(Collectors.toSet());

    // 两个请求必须归一到同一个模板，否则 label 基数随流量线性增长
    assertEquals(Set.of("/order/{id}"), uris);
}
```

这个测试很便宜，但能挡住 80% 的基数回归。

---

## 六、成本算式：给老板看的数字

假设治理前后：

| 指标 | 治理前 | 治理后 |
|---|---|---|
| 单 pod series | 1200 | 600 |
| pod 数 | 300 | 300 |
| 总 series | 36 万 | 18 万 |
| Prometheus 内存 | 1.1GB | 0.55GB |
| 15 天磁盘 | 4.7GB | 2.3GB |
| P99 查询延迟 | 3.2s | 0.9s |

如果 series 到了 300 万（真实事故量级），内存从 9GB 降到 4.5GB，意味着**Prometheus 从"必须 32GB 机器"变成"16GB 够用"**，同时 GC 压力和查询超时率同步下降。

---

## 七、面试高频追问

**Q1：什么是高基数？为什么 Prometheus 怕它？**
高基数指某个 label 的取值集合接近无限（用户 ID、订单号、原始 URL）。Prometheus 为每个唯一 label 组合维护独立 series（索引 + chunk），内存和磁盘随 series 数线性增长，且查询需要遍历所有匹配 series，因此基数是 Prometheus 最主要的容量约束。

**Q2：Micrometer 里怎么限制基数？**
`MeterFilter.maximumAllowableTags(name, tagKey, max, reply)` 限制单指标单 tag 的取值数；自定义 `MeterFilter.accept()` 做全局白名单；配合 `MeterFilterReply.DENY` 丢弃。注意要记录被拒次数，避免静默丢指标。

**Q3：Spring Boot 3 里 `uri` tag 怎么保证是模板？**
用 `ServerRequestObservationConvention`（默认 `DefaultServerRequestObservationConvention`），从 `HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE` 取模板路径；对 404/未匹配请求归一到 `UNKNOWN`，并对路径中的数字/UUID 段做模式化。

**Q4：`labeldrop` 和 `drop` 的区别？**
`drop` 丢弃整条样本（指标消失）；`labeldrop` 只删除指定 label（指标保留，但该维度丢失，可能造成不同来源的 series 合并）。前者适合废弃指标，后者适合去掉高基数维度。

**Q5：histogram 的桶会增加基数吗？**
会。每个桶是一条 `_bucket{le=...}` series，桶数直接乘到 series 数上。所以高基数指标上开大 histogram 是"基数 × 桶数"的双重放大。

---

## 八、总结

指标基数的本质是**"维度组合的笛卡尔积"**，而 Prometheus 的存储模型决定了它必须为每个组合付出固定成本。

五条落地原则：

1. **label 只能枚举，不能是用户输入**——URI 模板化、异常用类名、用户标识进 trace；
2. **在产生端拦截**——Micrometer `MeterFilter` 是最后一道也是最便宜的一道闸门；
3. **histogram 桶按 SLO 定制**，别用默认 15 个；
4. **Prometheus 侧 `labelkeep` 白名单**兜底存量服务；
5. **CI 里加基数断言**，让"多加一个 tag"在合并前就被拦住。

监控系统最讽刺的故障，是"被监控自己压死"。把基数管住，比加机器便宜两个数量级。
