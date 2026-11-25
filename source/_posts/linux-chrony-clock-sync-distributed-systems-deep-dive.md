---
title: 【性能调优】chrony 时钟同步深度解析：一次 30ms 时钟跳变如何打乱 TTL、锁与令牌
date: 2026-11-25 08:00:00
tags:
  - Linux
  - 分布式
  - 时钟同步
  - chrony
  - 生产实战
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】chrony 时钟同步深度解析：一次 30ms 时钟跳变如何打乱 TTL、锁与令牌

## 前言

分布式系统里有一个默认前提几乎从不被写进设计文档：**所有机器的时间是（近似）一致的**。

这个前提一旦破了，坏得非常有迷惑性——不是服务不可用，而是各种「偶发」「无法复现」的怪事：

- Redis `SETNX` 加锁，A 机器本地时间比 B 慢 30 秒，A 认为锁已过期，直接抢锁，两个客户端同时持锁。
- JWT 在 A 服务签发，`nbf` 是 A 的当前时间；B 服务时钟快 10 秒，校验直接失败，用户被踢下线。
- 定时任务在 02:00 执行，NTP step 把时间从 02:00:15 跳回 01:59:45，同一批任务在一个小时内跑了两次。
- Kafka 消息时间戳比生产时刻早 5 分钟，基于时间的窗口聚合全部错位。
- 证书「刚刚过期」，但 `date` 显示的日期是对的——因为 TLS 校验只差了几十秒。

上一篇文章（Java 时钟语义）我们讲的是**应用层应该用哪种时钟源**（`nanoTime` 用于测量，`currentTimeMillis` 用于时间点）。这一篇讲另一半：**机器时钟本身是怎么被校准的，以及校准过程会带来什么副作用**。

---

## 一、NTP 一次同步到底发生了什么

chrony 与上游服务器交换四个时间戳：

```
客户端                     服务端
  T1 ──────── 请求 ────────→ T2
  T4 ←─────── 响应 ────────  T3
```

- `T1`：客户端发送时刻（客户端时钟）
- `T2`：服务端收到时刻（服务端时钟）
- `T3`：服务端回复时刻（服务端时钟）
- `T4`：客户端收到时刻（客户端时钟）

推导：

```
往返延迟 delay = (T4 - T1) - (T3 - T2)
时钟偏差 offset = ((T2 - T1) + (T3 - T4)) / 2
```

这两个公式隐含了「去程与回程延迟对称」的假设。所以：

- 跨公网同步，`delay` 通常 10~50ms，`offset` 精度大致在 `delay/2` 量级；
- 同机房同步，`delay` 可以做到 0.1ms 级，`offset` 精度到几十微秒；
- **不对称路由**（去程 10ms、回程 40ms）会直接引入 15ms 的系统性偏差，这是「明明同步了但时间还是不准」的常见原因。

### 1.1 stratum 与层级

| stratum | 含义 | 精度量级 |
|---|---|---|
| 0 | 参考时钟（原子钟、GPS） | 基准 |
| 1 | 直连参考钟的服务器 | 微秒 |
| 2 | 同步自 stratum 1 | 亚毫秒~毫秒 |
| 3+ | 逐级下传 | 毫秒~几十毫秒 |
| 16 | 未同步（不可用） | — |

**生产环境不要直接指向公网池**。容器/云主机应指向云厂商的内网 NTP（通常 stratum 2~3，内网延迟低），或者自建一层 chrony 作为内网源，避免所有机器去打公网。

---

## 二、slew 与 step：两种校准方式的差别巨大

这是本文最关键的一节。

### 2.1 slew（平滑调整）

chrony 默认不会「跳时间」，而是**把本地时钟走快或走慢一点**，慢慢追上正确时间。最大调整速率由 `maxslewrate` 控制：

```conf
maxslewrate 83333    # 单位 ppm，83333 ppm ≈ 8.33%，即每秒最多纠正 83ms
```

追上 1 秒偏差需要约 12 秒。好处是：时间**单调**，不会出现「同一秒过两次」或「时间倒流」。代价是：偏差收敛慢。

### 2.2 step（直接跳变）

当偏差超过阈值时，chrony 会直接 set 系统时间（可能向前也可能向后）。默认策略：

```conf
makestep 1.0 3    # 前 3 次更新中，若 |offset| > 1 秒，则 step
```

这条配置的意思是「开机后的前 3 次同步允许跳变，之后即使偏差很大也只 slew」。很多发行版默认就是这个值。

**为什么 step 危险**：向后跳变会让「已经过去的时间」再走一遍，所有基于 wall clock 的逻辑都会重复执行或提前触发：

| 系统 | 向后跳 1 秒的后果 |
|---|---|
| Redis 过期 | 过期判断基于 wall clock，key 可能「复活」或延迟过期 |
| 分布式锁租约 | 持有者认为还有 5 秒，实际已过期，被他人抢占 |
| JWT `exp`/`nbf` | 令牌提前失效或被拒 |
| 定时任务 | `ScheduledExecutorService` 基于 `nanoTime`（不受影响），cron 基于 wall clock（会重复触发） |
| TLS 证书 | 有效期校验失败 |
| Kafka 时间索引 | 时间戳与 offset 的对应关系错乱 |
| 数据库 | `NOW()` 回退，`created_at` 出现「未来数据」 |

### 2.3 生产建议

```conf
# 允许开机阶段跳变，运行期只 slew
makestep 0.5 3
maxslewrate 500000      # 允许更快收敛（0.5s/s），但仍不跳变
```

对于延迟敏感、且已经稳定运行的系统，`maxslewrate` 可以放宽到 500000 ppm（每秒纠正 0.5 秒），这样几十毫秒的偏差能在 1 秒内平滑修正，而不会 step。

对于**虚拟机**还有额外注意：VM 被暂停（快照恢复、热迁移、宿主机休眠）后，时钟会一次性落后很多。这时只能 step。建议：

```conf
# 恢复后若偏差过大，允许跳一次
makestep 1.0 -1     # -1 表示不限制次数（慎用，仅适合可容忍跳变的机器）
```

`makestep ... -1` 不要用在数据库、消息队列节点上。

---

## 三、chrony 配置与诊断

### 3.1 一份生产可用的配置

```conf
# /etc/chrony.conf
# 内网源优先，公网兜底
server 10.0.0.11 iburst minpoll 4 maxpoll 6
server 10.0.0.12 iburst minpoll 4 maxpoll 6
pool ntp.aliyun.com iburst

driftfile /var/lib/chrony/drift
rtcsync                       # 定期把系统时间写回 RTC
makestep 0.5 3
maxslewrate 500000
logdir /var/log/chrony
log tracking statistics measurements
bindcmdaddress 127.0.0.1      # 只允许本机 chronyc，避免被外部探测
```

`minpoll 4 / maxpoll 6` 表示 16s~64s 一次轮询。默认范围更宽（64s~1024s），收敛更慢；内网源可以调紧。

### 3.2 chronyc 三件套

```bash
$ chronyc tracking
Reference ID    : 0A00000B (10.0.0.11)
Stratum         : 3
Ref time (UTC)  : Wed Nov 25 00:00:01 2026
System time     : 0.000123456 seconds fast of NTP time
Last offset     : +0.000098765 seconds
RMS offset      : 0.000234567 seconds
Frequency       : 12.345 ppm slow
Residual freq   : +0.001 ppm
Skew            : 0.012 ppm
Root delay      : 0.000987 seconds
Root dispersion : 0.001234 seconds
Update interval : 64.0 seconds
Leap status     : Normal
```

字段解读：

| 字段 | 含义 | 关注点 |
|---|---|---|
| `System time` | 当前系统时间与 NTP 的偏差 | **核心指标**，>100ms 告警 |
| `Last offset` | 最近一次测量的偏差 | 反映瞬时抖动 |
| `RMS offset` | 长期偏差的均方根 | 反映稳定性 |
| `Frequency` | 本地晶振频率偏差（ppm） | 持续增大说明晶振老化或虚拟机时钟不稳 |
| `Root delay` | 到 stratum 1 的往返延迟 | 跨公网通常 >10ms |
| `Root dispersion` | 累积误差 | 与 delay 一起决定「可信区间」 |
| `Leap status` | 闰秒状态 | `Insert second` / `Delete second` 要关注 |
| `Update interval` | 当前轮询间隔 | 突然变大说明源不稳 |

```bash
$ chronyc sources -v
MS Name/IP address   Stratum Poll Reach LastRx Last sample
===============================================================
^* 10.0.0.11            3    4   377    32   +12us[ +18us] +/-  210us
^+ 10.0.0.12            3    4   377    30   -45us[ -38us] +/-  240us
^- ntp.aliyun.com       2    6   377   120  -1.2ms[-1.1ms] +/-   18ms
```

首列标记含义：

| 标记 | 含义 |
|---|---|
| `*` | 当前选中的同步源 |
| `+` | 可用的备选源 |
| `-` | 被合并算法排除的源 |
| `?` | 不可达 / 未通过测试 |
| `x` | 被判定为 falseticker（时间明显错误） |

`Reach` 是八进制位图（377 = 最近 8 次全部成功，0 = 全失败）。`LastRx` 是距上次收到响应的秒数。

```bash
$ chronyc sourcestats -v
```

用来判断「源本身是否稳定」：`Std Dev` 大说明该源抖动大，应降权或移除。

### 3.3 常见故障对照表

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `Reach=0` | 防火墙挡 UDP 123 / 源不可达 | `nc -u -z <ip> 123` 验证 |
| `Stratum=16` | 未同步成功 | 检查源配置与网络 |
| offset 持续单向增长 | 本地晶振偏差大 / 源频率不准 | 看 `Frequency`，必要时换源 |
| offset 忽正忽负大幅抖动 | 网络不对称 / 源负载高 | 改用内网源，缩短 poll |
| `System time` 正常但业务报时间错 | 容器/进程时区（`TZ`）问题，不是时钟问题 | 区分「时区」与「时钟」 |
| 从库/节点间时间差固定 8 小时 | 时区配置（UTC vs Asia/Shanghai） | 统一 `timedatectl set-timezone` |
| chronyd 启动后立即 step | `makestep` 生效 | 属正常，注意首次启动窗口 |

---

## 四、容器与虚拟机：时钟的边界

### 4.1 容器没有自己的时钟

容器共享宿主内核，`CLOCK_REALTIME` 是**全局的**，per-container 无法修改（`clock_settime` 需要 `CAP_SYS_TIME`，且影响整个宿主机）。所以：

- 「在容器里装 chrony」通常无效（除非 privileged + 独立 time namespace，K8s 很少这么干）；
- 正确做法是**保证宿主机/节点时钟正确**，容器继承；
- 容器里的 `date` 看起来不对，99% 是**时区**问题（`TZ` 环境变量或镜像里没装 tzdata），不是时钟问题。

```dockerfile
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
```

### 4.2 虚拟机时钟漂移的四个来源

| 来源 | 影响 |
|---|---|
| CPU steal time | 虚拟 CPU 被抢占，guest 内时钟走慢 |
| 宿主负载高 | 同上，且延迟抖动 |
| 快照恢复 / 热迁移 | 时钟一次性落后几分钟 |
| 宿主休眠 | 同上，可能几小时 |

对策：

1. 节点上启用 chrony，并把 `maxslewrate` 调大；
2. K8s 场景用 DaemonSet 部署 node-exporter 采集 `node_timex_offset_seconds`，offset > 100ms 告警；
3. 关键有状态服务（MySQL、Kafka、etcd）避免与高负载任务混部；
4. 云厂商提供「时钟同步服务」时优先使用（如内网 NTP 域名）。

---

## 五、时钟不准会打坏哪些中间件

### 5.1 Redis

- `EXPIRE`/`TTL` 基于服务端 wall clock，主从之间若时间差大，从库的过期判断会与主库不一致（读到「已过期但未删」的 key）。
- `SET key val NX PX 30000` 做锁：持锁方与抢锁方时钟不一致时，租约失去意义。**这就是 Redlock 争议的核心之一**。
- 解决：锁场景不要依赖绝对时间，用「fencing token + 单调递增版本」；或者接受「时钟偏差 < 锁租约/10」的前提并监控。

### 5.2 MySQL

- `NOW()`、`CURRENT_TIMESTAMP` 来自服务器时钟；主从时间不一致会导致 `created_at` 乱序、基于时间的增量同步漏数据。
- `binlog` 的 `timestamp` 影响 CDC 工具（Debezium 等）的事件时间。
- 建议：`--log_timestamps=SYSTEM` 并统一时区为 UTC 存储、展示层转换；监控主从 `TIMESTAMPDIFF(SECOND, NOW(), ...)`。

### 5.3 Kafka

- 消息 `timestamp` 用于时间索引（`kafka-log-dirs` 按时间段删除、Streams 窗口、KSQL 时间语义）。
- 生产端时钟慢 10 分钟，基于 event-time 的窗口会全部延迟触发。
- 建议：`log.message.timestamp.type=CreateTime`（默认）时严格保证 broker 与 producer 时钟；对时间敏感场景可改用 `LogAppendTime`，由 broker 统一打时间戳。

### 5.4 TLS / JWT

- 证书 `notBefore`/`notAfter` 校验直接比较系统时间；偏差几秒就可能「刚签发的证书不可用」。
- JWT 的 `exp`/`nbf`/`iat` 同理。**建议在服务端校验时留 30~60s 的 clock skew 容忍**：

```java
JwtParser parser = Jwts.parser()
    .clockSkewSeconds(60)     // 允许 60 秒偏差
    .verifyWith(publicKey)
    .build();
```

这不是「掩盖问题」，而是分布式系统的必要容错。

---

## 六、Java 侧：正确测量与偏差感知

### 6.1 测量耗时永远用 nanoTime

```java
long start = System.nanoTime();
doWork();
long costMs = (System.nanoTime() - start) / 1_000_000;
```

`currentTimeMillis` 会被 NTP slew/step 影响，跨机器比较更是不可靠；`nanoTime` 是单调的（JVM 保证不倒退），适合测量「经过时间」。

### 6.2 可注入时钟，便于测试

```java
public class TokenService {
    private final Clock clock;

    public TokenService(Clock clock) {
        this.clock = clock;   // 生产用 Clock.systemUTC()，测试用 Clock.fixed(...)
    }

    public boolean isExpired(Instant exp) {
        // 留 30 秒容忍，避免节点间小偏差造成误判
        return Instant.now(clock).minusSeconds(30).isAfter(exp);
    }
}
```

### 6.3 启动自检：把时钟偏差暴露出来

```java
@Component
public class ClockSkewGuard implements ApplicationRunner {

    private static final Duration MAX_SKEW = Duration.ofMillis(500);

    @Override
    public void run(ApplicationArguments args) throws Exception {
        // 用一次 HTTP HEAD 请求的 Date 头估算偏差（粗粒度，够用）
        HttpResponse<Void> resp = HttpClient.newHttpClient().send(
                HttpRequest.newBuilder(URI.create("https://www.baidu.com"))
                        .method("HEAD", HttpRequest.BodyPublishers.noBody()).build(),
                HttpResponse.BodyHandlers.discarding());

        long serverMillis = ZonedDateTime
                .parse(resp.headers().firstValue("date").orElseThrow(),
                       DateTimeFormatter.RFC_1123_DATE_TIME)
                .toInstant().toEpochMilli();
        long skew = System.currentTimeMillis() - serverMillis;

        if (Math.abs(skew) > MAX_SKEW.toMillis()) {
            log.error("clock skew detected: {} ms, 请检查 chrony/节点时间同步", skew);
            // 可配置为 fail-fast，避免带着错误时间对外提供服务
        }
    }
}
```

更严谨的做法是解析 `chronyc tracking` 的 `System time`，通过 node-exporter 的 `node_timex_offset_seconds` 上报 Prometheus。

### 6.4 雪花 ID 的回拨保护

```java
private long lastTimestamp = -1L;

public synchronized long nextId() {
    long now = System.currentTimeMillis();
    if (now < lastTimestamp) {
        long drift = lastTimestamp - now;
        if (drift <= 5) {
            // 小幅回拨：自旋等待
            now = waitUntil(lastTimestamp);
        } else {
            throw new IllegalStateException("clock moved backwards: " + drift + "ms");
        }
    }
    // ... 正常生成
    lastTimestamp = now;
    return id;
}
```

**关键**：回拨超过阈值必须抛异常而不是「继续用旧时间戳」，否则会生成重复 ID。

---

## 七、观测与告警方案

Node Exporter 已经采集了时钟指标，直接可用：

```yaml
# 告警规则示例
- alert: NodeClockSkewHigh
  expr: abs(node_timex_offset_seconds) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "节点 {{ $labels.instance }} 时钟偏差 {{ $value }}s"

- alert: NodeClockNotSynchronising
  expr: node_timex_sync_status == 0
  for: 10m
  labels:
    severity: critical
```

关键指标：

| 指标 | 含义 |
|---|---|
| `node_timex_offset_seconds` | 当前偏差（核心） |
| `node_timex_sync_status` | 1 = 已同步，0 = 未同步 |
| `node_timex_maxerror_seconds` | 最大误差上界 |
| `node_timex_estimated_error_seconds` | 估计误差 |
| `node_timex_frequency_adjustment_ratio` | 频率调整量，突变说明晶振/虚拟化异常 |

分级阈值建议：

- `> 50ms`：warning（可能影响毫秒级 TTL/锁）
- `> 500ms`：critical（JWT、证书、定时任务开始出问题）
- `sync_status == 0` 持续 10 分钟：critical（可能已经 step 或未同步）

---

## 八、面试追问

**Q1：NTP 能保证多精确？**
取决于网络。同机房内网 0.1~1ms，跨公网 10~50ms。跨机房做「强一致时间」不可行，需要逻辑时钟（Lamport/HLC）或版本号。

**Q2：slew 和 step 怎么选？**
运行期只 slew（保持单调），只在开机初始化或 VM 恢复时允许 step。数据库/消息队列节点必须禁用运行期 step。

**Q3：容器时间不准怎么办？**
容器共享宿主时钟，改容器没用。修宿主机 chrony，并检查容器 `TZ` 时区配置。K8s 节点用 DaemonSet 采集 `node_timex_offset_seconds`。

**Q4：Redis 分布式锁为什么和时钟有关？**
锁的过期依赖服务端 TTL（相对时间，基于 monotonic 计时更可靠），但「客户端认为锁还有多久」依赖本地时钟。Redlock 的争议点之一就是多节点时钟漂移假设。工程上更稳的是 fencing token。

**Q5：`System.currentTimeMillis()` 会被 NTP 影响吗？**
会。它读 `CLOCK_REALTIME`，NTP slew 会让它走得稍快/稍慢，step 会直接跳变。所以测量耗时用 `nanoTime`（`CLOCK_MONOTONIC`），它不受 NTP 调整影响。

**Q6：闰秒怎么处理？**
两种主流方案：`leapsecmode slew`（chrony 把 1 秒分摊到一段时间，推荐）或 leap smear（Google 方案，把 1 秒摊到 24 小时）。绝不要让内核直接插入 23:59:60，2012 年那次闰秒导致大量 Java/MySQL 服务卡死。

---

## 总结

- 时间同步不是「装个 NTP 就完事」，**校准方式（slew vs step）比校准精度更影响业务**。
- 运行期永远优先 slew；step 只留给开机和 VM 恢复，并且要评估影响面。
- 容器没有独立时钟，K8s 场景的治理点在节点；虚拟机要额外防 steal time 与快照恢复。
- 应用层要做的三件事：测量用 `nanoTime`、时间点用可注入 `Clock`、跨节点校验留 30~60s 的 skew 容忍。
- 监控只有两个核心指标：`node_timex_offset_seconds` 与 `node_timex_sync_status`，但必须真的配上告警。

时钟这种东西，正常时你永远想不起它；出问题时，它会让所有「看起来正确」的代码同时出错。把它当成一个需要被监控的基础依赖，而不是操作系统的一个默认行为。
