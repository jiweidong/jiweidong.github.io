---
title: 【生产实战】Java 日志风暴与磁盘打满治理：异步队列、采样限流与结构化日志
date: 2026-11-22 08:20:00
tags:
  - Java
  - 日志
  - Logback
  - 运维
  - 故障排查
categories:
  - 生产实战
author: 东哥
---

# 【生产实战】Java 日志风暴与磁盘打满治理

## 前言

凌晨两点，磁盘使用率告警 95%。登上去一看，`/var/log/app` 下面躺着一个 48GB 的 `app.log`，最后 100 万行全是同一句：

```
ERROR c.e.order.service.OrderService - 下单失败, orderId=null
```

业务其实只挂了一个下游接口，但异常被放在循环里打印，每次重试打一遍堆栈，一分钟写出 2GB。

日志本来是排障工具，配置不当就成了**故障放大器**：磁盘打满 → 应用写日志阻塞 → 接口超时 → 更多重试 → 更多日志。这个正反馈闭环可以在十分钟内拖垮整个集群。

这篇文章讲清楚日志的写入链路、四类放大机制，以及一套「限流 + 收敛 + 轮转 + 应急」的治理方案。

---

## 一、日志是怎么写到磁盘的

```
Logger.info()
  → Filter（级别/条件）
    → Appender（Console / File / Async）
      → Encoder（PatternLayout / JSON）
        → OutputStream.write()
          → 内核 page cache
            → 后台 flush → 磁盘
```

几个关键事实：

1. **默认 FileAppender 是同步的**。`write()` 会走锁 + 系统调用，磁盘慢时直接阻塞业务线程。日志打太多，接口 RT 会被日志拖垮。
2. **`immediateFlush=true`（默认）** 意味着每条日志都 flush，吞吐极差。生产应关闭，靠 OS 刷盘。
3. **AsyncAppender 不是银弹**。它内部是 `ArrayBlockingQueue`，队列满了默认**丢弃**（`discardingThreshold`），你会在最需要日志的时候丢日志。
4. 写文件只是写 page cache，**真正落盘是异步的**。所以「日志写了但机器断电丢了」是正常的，不要用日志做审计账本。

---

## 二、四类日志放大机制

### 2.1 循环内打日志

```java
for (Order order : orders) {          // 10 万条
    try {
        push(order);
    } catch (Exception e) {
        log.error("推送失败, order={}", order, e);  // 10 万条堆栈
    }
}
```

一条堆栈平均 2~5KB，10 万条就是 200~500MB。正确做法是**聚合 + 采样**：

```java
int failed = 0;
for (Order order : orders) {
    try {
        push(order);
    } catch (Exception e) {
        failed++;
        if (failed <= 3) {                     // 只打前 3 条完整堆栈
            log.error("push failed, orderId={}", order.getId(), e);
        }
    }
}
if (failed > 3) {
    log.error("push failed summary: total={}, sample=3, firstOrderId={}",
            failed, firstFailedId);
}
```

### 2.2 异常重复打印

三层 catch 各打一次，同一条异常在日志里出现三遍：

```java
// Controller
catch (Exception e) { log.error("请求失败", e); throw e; }
// Service
catch (Exception e) { log.error("业务失败", e); throw e; }
// GlobalExceptionHandler
catch (Exception e) { log.error("全局异常", e); }
```

规范：**只在「处理异常的那一层」打印堆栈**，中间层要么不打，要么只打 `e.getMessage()` 并带 `traceId`。

### 2.3 框架访问日志双写

Nginx access log + Spring Boot access log + APM 采样日志 + 业务日志，同一个请求写四份。高峰期 QPS 5000，每份 500 字节，一天就是 800GB。

对策：明确分工。Nginx 记录入口与状态码，应用只记录业务关键节点与异常，APM 负责链路。

### 2.4 DEBUG 误开 + 大对象打印

```java
log.debug("request body: {}", JSON.toJSONString(hugeRequest));
```

即使 `debug` 没开，`JSON.toJSONString()` 也已经执行了——**参数拼接发生在级别判断之前**（除非用 `isDebugEnabled()` 或占位符延迟求值）。一个 5MB 的请求体，序列化一次几十毫秒，纯浪费 CPU。

```java
if (log.isDebugEnabled()) {
    log.debug("request body: {}", JSON.toJSONString(req));
}
```

更隐蔽的是 `toString()` 里带出了整个关联对象图，一条日志打 10MB。

---

## 三、磁盘打满后的连锁反应

磁盘 100% 不是「日志写不进去」这么简单：

| 组件 | 影响 |
|---|---|
| 应用 | 日志写入抛 `IOException`，若未捕获会中断业务 |
| Kafka | 日志段无法写入，Broker 直接不可用 |
| MySQL | binlog 无法写，所有写事务失败 |
| Elasticsearch | 索引进入 read-only block |
| K8s | 节点 `DiskPressure`，开始驱逐 Pod |
| Docker | 容器日志写满，`json-file` 驱动导致容器卡死 |

最坑的是：**磁盘满时日志也写不出来**，你失去了最重要的排障手段。所以必须留「应急通道」——控制台输出或独立小分区。

---

## 四、治理方案：四层防线

### 4.1 第一层：日志轮转（保命）

Logback 的 `SizeAndTimeBasedRollingPolicy` 是生产标配：

```xml
<appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
  <file>/var/log/app/app.log</file>
  <rollingPolicy class="ch.qos.logback.core.rolling.SizeAndTimeBasedRollingPolicy">
    <fileNamePattern>/var/log/app/app.%d{yyyy-MM-dd}.%i.log.gz</fileNamePattern>
    <maxFileSize>512MB</maxFileSize>
    <maxHistory>7</maxHistory>
    <totalSizeCap>20GB</totalSizeCap>
    <cleanHistoryOnStart>true</cleanHistoryOnStart>
  </rollingPolicy>
  <encoder>
    <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} %-5level [%thread] [%X{traceId}] %logger{36} - %msg%n</pattern>
  </encoder>
</appender>
```

要点：

- `totalSizeCap` 必须设，否则 `maxHistory` 在高写入量下依然会撑爆；
- `cleanHistoryOnStart=true` 能在重启时清理历史；
- 压缩用 gz，文本日志压缩比通常 10:1 以上。

### 4.2 第二层：异步 + 有界队列（性能）

```xml
<appender name="ASYNC" class="ch.qos.logback.classic.AsyncAppender">
  <appender-ref ref="FILE"/>
  <queueSize>8192</queueSize>
  <discardingThreshold>20</discardingThreshold>
  <neverBlock>true</neverBlock>
  <includeCallerData>false</includeCallerData>
</appender>
```

- `neverBlock=true`：队列满时直接丢，绝不阻塞业务线程；
- `discardingThreshold=20`：剩余容量低于 20% 时丢弃 INFO 及以下；
- `includeCallerData=false`：避免每次取栈帧，性能差一个数量级。

代价是可能丢日志。所以**关键业务日志（审计、资金）必须走同步或独立 appender**，不能和诊断日志混在一起。

### 4.3 第三层：采样与限流（治本）

Logback 自带 `TurboFilter`，可以在格式化之前拦截，成本极低：

```java
public class RateLimitTurboFilter extends TurboFilter {
    private final Cache<String, AtomicInteger> counters =
            Caffeine.newBuilder().expireAfterWrite(1, TimeUnit.MINUTES).build();

    @Override
    public FilterReply decide(Marker marker, Logger logger, Level level,
                              String format, Object[] params, Throwable t) {
        if (level != Level.ERROR) {
            return FilterReply.NEUTRAL;
        }
        String key = logger.getName() + ":" + (t == null ? format : t.getClass().getName());
        AtomicInteger c = counters.get(key, k -> new AtomicInteger());
        int n = c.incrementAndGet();
        if (n <= 5) {
            return FilterReply.NEUTRAL;       // 每分钟前 5 条正常输出
        }
        if (n == 6) {
            logger.warn("log rate limited for key={}", key);
        }
        return FilterReply.DENY;
    }
}
```

注册：

```xml
<turboFilter class="com.example.logging.RateLimitTurboFilter"/>
```

按「异常类型 + logger 名」做 key，既能保留样本，又能把风暴压到每分钟 5 条。

### 4.4 第四层：结构化日志（可分析）

```json
{"ts":"2026-11-22T02:14:31.221+08:00","level":"ERROR",
 "traceId":"a1b2c3","service":"order","event":"push_failed",
 "orderId":"10086","downstream":"coupon","errCode":"TIMEOUT","costMs":3001}
```

结构化日志的价值：

- 字段可索引，能按 `orderId` 精确检索，不用正则捞；
- 体积比多行堆栈小，便于集中采集；
- 天然适配 Loki / ES / ClickHouse。

但注意：**堆栈仍然需要**。推荐「结构化字段 + 单独 stack 字段」，并配合采样。

---

## 五、容器环境的额外约束

K8s/Docker 场景下，应用日志最好直接输出 stdout，由容器运行时收集：

```yaml
# docker-compose 限制单容器日志
logging:
  driver: json-file
  options:
    max-size: "100m"
    max-file: "3"
```

K8s 里 `json-file` 默认不限大小，节点磁盘会被慢慢吃光。要么配 `kubelet --container-log-max-size`，要么用 containerd 的 `max_container_log_line_size`，要么直接上日志采集 sidecar/DaemonSet。

**不要**在容器里既写文件又写 stdout，双份放大。

---

## 六、磁盘已经满了怎么办

### 6.1 先确认是不是「删了没释放」

```bash
df -h                      # 分区满
du -sh /var/log/* | sort -h | tail
lsof +L1 | grep deleted    # 被删除但仍被进程持有的文件
```

如果日志被 `rm` 了但进程还开着 fd，空间不会释放。正确处理：

```bash
# 用 truncate 清空，而不是 rm（对正在写的文件）
: > /var/log/app/app.log
```

对已经 `rm` 的文件，只能重启进程或 `gdb` 关 fd。

### 6.2 应急三板斧

1. **立刻降级日志级别**：通过配置中心把 `com.example` 调到 WARN，或动态调整 Logback 级别（Spring Boot Actuator `/loggers`）；
2. **清空最大文件**：`truncate -s 0`，保留 inode；
3. **临时扩容/挂新盘**：把日志目录软链到新盘，`mv` + `ln -s`。

### 6.3 恢复后必须做的事

- 找到风暴源：按 logger 名聚合日志量，`awk` 或 Loki 查询；
- 加上限流 filter，并在压测环境验证；
- 检查轮转配置是否生效（`totalSizeCap` 是否真的清理了）；
- 给磁盘加 80%/90% 两级告警，别等 100%。

---

## 七、面试追问

**Q：日志打太多导致接口变慢，怎么优化？**

先分清是同步 IO 阻塞还是对象序列化开销。同步 FileAppender 改成 AsyncAppender + 有界队列；关闭 `immediateFlush`；避免无谓的 `toString()`/JSON 序列化；对高频日志做采样；把审计日志与诊断日志分离。

**Q：AsyncAppender 会丢日志吗？**

会。队列满时根据 `discardingThreshold` 和 `neverBlock` 决定丢弃或阻塞。这是有意的取舍：宁可丢日志也不能阻塞业务。关键日志必须走独立同步通道。

**Q：为什么磁盘满了应用会「假死」？**

写日志的系统调用会阻塞或抛异常；如果日志框架内部有锁，所有业务线程会排队等锁；同时 Kafka/MySQL 等依赖也可能因磁盘满而不可用，形成连锁故障。

**Q：日志级别怎么设计？**

生产默认 INFO；框架 DEBUG 只在排障时临时开；ERROR 只用于「需要人介入」的情况，业务校验失败用 WARN；审计日志独立 logger + 独立文件 + 更长保留期。

---

## 八、总结

1. 日志是 IO，不是免费的。同步写、大对象序列化、循环打印都会直接吃掉接口 RT。
2. 四类放大机制：循环内打日志、异常重复打印、框架双写、DEBUG 误开。
3. 治理四层：轮转保命、异步提性能、限流治根因、结构化提可分析性。
4. 磁盘满时先 `truncate` 不要 `rm`，先降级别再找风暴源。
5. 给日志留一条「应急通道」，否则最需要日志的时候你什么都没有。

日志规范不是洁癖，是容量规划的一部分。
