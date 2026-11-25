---
title: 【Redis 运维】连接治理深度实战：CLIENT LIST/KILL、输出缓冲与 maxmemory-clients
date: 2026-11-25 08:00:00
tags:
  - Redis
  - 中间件
  - 连接治理
  - 生产实战
  - 运维
categories:
  - 中间件
author: 东哥
---

# 【Redis 运维】连接治理深度实战：CLIENT LIST/KILL、输出缓冲与 maxmemory-clients

## 前言

大多数 Redis 事故的第一现场不是「key 太多」或「内存不够」，而是**连接**。

典型的两类故事：

- 某个服务发布时 pod 从 20 个扩到 120 个，每个 pod 的 Jedis 池 `maxTotal=50`，瞬间连上 6000 个连接，Redis `connected_clients` 打到 `maxclients`，新连接被拒，所有服务开始报 `ERR max number of clients reached`。
- 某个 Pub/Sub 消费者因为下游变慢不再读 socket，Redis 侧该连接的输出缓冲（`omem`）一路涨到 2GB，触发 `client-output-buffer-limit` 被杀；重连后重新订阅，再次堆积，形成「断开—重连—再堆积」的循环，最终把实例内存打爆。

这两类问题的共同点是：**Redis 有完整的连接治理工具，但很多人只会 `INFO clients` 看一眼数字**。本文把 `CLIENT LIST` / `CLIENT KILL` / 输出缓冲 / `maxmemory-clients` / `CLIENT PAUSE` 这一整套讲清楚，并给出 Java 侧的落地方式。

---

## 一、CLIENT LIST：连接的全息快照

```
127.0.0.1:6379> CLIENT LIST TYPE normal
id=1088 addr=10.0.3.17:54322 laddr=10.0.1.9:6379 fd=12 name=order-svc
age=18432 idle=0 flags=N db=0 sub=0 psub=0 ssub=0 multi=-1 watch=0
qbuf=26 qbuf-free=20448 argv-mem=10 multi-mem=0 tot-net-in=1841203
tot-net-out=9912311 rbs=1024 rbp=0 obl=0 oll=0 omem=0
tot-mem=20528 events=r cmd=hgetall user=default redir=-1 resp=2
```

逐字段的含义（挑最容易误读的说）：

| 字段 | 含义 | 易错点 |
|---|---|---|
| `id` | 连接唯一 ID，单调递增 | `CLIENT KILL ID` 用它，重启后失效 |
| `addr` / `laddr` | 对端 / 本地地址 | 容器 NAT 后 `addr` 可能是节点 IP，不是 pod IP |
| `fd` | 文件描述符 | 用于 `lsof` 交叉定位，`-1` 表示内部伪客户端 |
| `name` | `CLIENT SETNAME` 设置的名字 | **治理的第一抓手**，没名字就靠 addr 猜 |
| `age` | 连接存活秒数 | 长连接池的正常表现 |
| `idle` | 空闲秒数（最近一次交互） | 阻塞命令（BLPOP）期间仍算 idle |
| `flags` | 连接角色标记 | 见下表 |
| `qbuf` / `qbuf-free` | 输入缓冲已用/剩余 | `qbuf-free=0` 说明输入缓冲满，通常是客户端在灌大命令 |
| `obl` / `oll` / `omem` | 输出缓冲字节/列表对象数/总内存 | **Pub/Sub 与 replica 事故核心字段** |
| `tot-mem` | 该连接总内存（含缓冲、argv） | Redis 7 的 `maxmemory-clients` 就是按它算 |
| `cmd` | 最近执行的命令 | `cmd=monitor` 说明有人在 MONITOR，性能杀手 |
| `resp` | 协议版本 | RESP3 连接会多 `sub`/`psub` 语义差异 |

`flags` 的关键取值：

| flag | 含义 | 运维意义 |
|---|---|---|
| `N` | normal 普通客户端 | 业务连接 |
| `M` | master（当前实例作为从库时的上游） | 别乱 kill |
| `S` | replica | 别乱 kill，会触发全量同步 |
| `O` | MONITOR 模式 | **必须收敛，性能影响极大** |
| `x` | 处于 MULTI 事务中 | 长时间保持说明客户端写错了 |
| `d` | 被阻塞（BLPOP/BRPOP/WAIT 等） | 大量 `d` 说明有阻塞命令滥用 |
| `b` | 正在等待阻塞事件 | 同上 |
| `i` | 空闲等待命令 | 连接池空闲态 |
| `A` | close-as-apart（待关闭） | 即将断开 |
| `T` | 开启了 client-side caching（tracking） | 连接级缓存，需关注失效通知 |

---

## 二、CLIENT KILL：两种语法，别用错

### 2.1 老语法（只能按地址）

```
CLIENT KILL 10.0.3.17:54322
```

只能按 `addr` 精确匹配，杀一个连接。适合「定位到具体 IP 后精准处理」。

### 2.2 新语法（过滤器，推荐）

```
CLIENT KILL TYPE normal MAXAGE 3600 SKIPME yes
```

支持的过滤器：

| 过滤器 | 说明 | 典型用法 |
|---|---|---|
| `ID <id>` | 按连接 ID | 精确杀单条 |
| `TYPE normal\|master\|replica\|pubsub` | 按角色 | 只杀业务连接，保护主从 |
| `USER <user>` | 按 ACL 用户 | 隔离某个租户/服务的连接 |
| `ADDR <ip:port>` | 按对端地址 | 定位到具体实例 |
| `LADDR <ip:port>` | 按本地地址 | 多网卡场景 |
| `SKIPME yes\|no` | 是否跳过当前连接 | **默认 yes**，脚本里杀自己要注意 |
| `MAXAGE <seconds>` | 存活超过 N 秒 | 清理「僵尸长连接」 |

实战示例：

```bash
# 1. 找出 1 小时以上没动静的普通客户端（排除主从与订阅）
CLIENT LIST TYPE normal
# 逐条看 idle，再批量杀
CLIENT KILL TYPE normal MAXAGE 7200 SKIPME yes

# 2. 只清理某个服务的连接（服务已下线但连接还在）
CLIENT KILL USER order-svc

# 3. 清理所有 MONITOR 会话（谨慎）
CLIENT LIST | grep "cmd=monitor"
CLIENT KILL ID 12345
```

**重要限制**：`CLIENT KILL` 是「关闭连接」，不是「取消正在执行的命令」。如果目标连接正卡在一条耗时命令上，kill 请求要等命令执行完才会生效（Redis 单线程）。所以要杀「慢命令」占用的连接，先看 `SLOWLOG`，必要时用 `SCRIPT KILL` / `FUNCTION KILL`（只对只读脚本有效）。

### 2.3 命名规范：治理的前提

```java
// Lettuce
RedisClient client = RedisClient.create(uri);
StatefulRedisConnection<String, String> conn = client.connect();
conn.setClientName("order-svc@pod-7f9c");
```

```yaml
# Spring Boot 里统一加前缀
spring:
  data:
    redis:
      client-name: order-svc
```

命名建议 `{service}@{instance}`，长度控制在 64 字节内。没有名字的连接在事故时只能靠 `addr` 反查 NAT 表，等于没有可观测性。

---

## 三、输出缓冲：最容易被忽视的 OOM 来源

### 3.1 三个缓冲配置

```conf
# 普通客户端：hard 0 表示不限制（危险）
client-output-buffer-limit normal 0 0 0
# 从库：600MB 硬限 / 300MB 软限持续 60s
client-output-buffer-limit replica 629145600 314572800 60
# Pub/Sub：32MB 硬限 / 8MB 软限持续 60s
client-output-buffer-limit pubsub 33554432 8388608 60
```

语义：

- **hard limit**：一旦超过，立即断开，不看时间。
- **soft limit**：超过后持续 `soft seconds` 秒才断开；期间若降到阈值以下则重置。
- **normal 默认 0 0 0 = 不限制**，这是大量事故的根源——一个不读响应的普通客户端可以把 Redis 内存吃光。

### 3.2 一条命令如何撑爆内存

```
客户端: GET big-hash          # 命令很小
Redis:   返回 500MB 的 HGETALL 结果
```

如果客户端此时不读（GC 停顿、线程池打满、网络拥塞），这 500MB 会先落在该连接的输出缓冲里。`omem` 涨、`oll` 涨，`used_memory` 跟着涨。多个这样的连接叠加，就会触发 `maxmemory` 淘汰甚至 OOM。

**结论**：`client-output-buffer-limit normal` 不要保持 0。建议按「最大可接受单次响应」设定，例如 `256mb 64mb 60`。

### 3.3 Pub/Sub 的经典雪崩

```
发布端 QPS 5000，消息 10KB → 50MB/s
订阅端消费能力 5MB/s
→ 差值全部堆在 omem
→ 达到 pubsub hard limit 被断开
→ 客户端自动重连 + 重新 SUBSCRIBE
→ 继续堆积（Redis 不保留历史，重连后只收新消息，但消费能力依旧不足）
→ 循环断开，日志刷屏，监控告警风暴
```

正确解法不是调大 limit，而是：

1. **换成 Redis Streams**（有 consumer group、有 ACK、有堆积上限），而不是 Pub/Sub。
2. 若必须用 Pub/Sub，在客户端做**有界队列 + 丢弃策略**（丢旧保新），并监控丢弃计数。
3. 用 `CLIENT LIST TYPE pubsub` 找出 `omem` 最大的连接，先限流再谈扩容。

---

## 四、maxmemory-clients：Redis 7 的连接级内存治理

Redis 7.0 引入：

```conf
maxmemory-clients 5%      # 也可写绝对值，如 512mb；默认 0 = 不限制
```

语义：所有客户端连接的总内存（`tot-mem` 之和）超过阈值时，Redis 会**主动断开占用最大的连接**（按 `tot-mem` 排序），直到降到阈值以下。

这是「防止单个客户端吃光内存」的最后一道闸。注意三点：

1. **它不是淘汰 key**，是断连接。被断的客户端会重连，如果根因没解决，会反复被杀。
2. 排序依据是 `tot-mem`（含输入输出缓冲），不是「谁发的命令多」。
3. 建议设为 `maxmemory` 的 5%~10%：太小会误杀正常大响应，太大则失去保护意义。

配套的两个连接级开关（7.0+）：

```
CLIENT NO-EVICT ON     # 该连接不被 maxmemory-clients 驱逐（给监控/运维连接用）
CLIENT NO-TOUCH ON     # 该连接访问的 key 不更新 LRU/LFU（给扫描类任务用，避免污染热数据）
```

`NO-TOUCH` 在跑 `SCAN`/离线统计时非常有用：否则一次全量扫描会把所有 key 的 `idle` 刷新，LRU 直接失效。

---

## 五、输入缓冲与协议层防护

| 配置 | 默认 | 作用 |
|---|---|---|
| `client-query-buffer-limit` | 1GB | 单连接输入缓冲上限，防「大命令灌入」 |
| `proto-max-bulk-len` | 512MB | 单个 bulk 字符串上限 |
| `maxclients` | 10000 | 总连接数上限 |

输入侧的典型攻击/事故是「客户端拼了一个 800MB 的 `SET` 或 `MSET`」，`qbuf` 涨到上限后连接被断。防护：

```conf
client-query-buffer-limit 64mb    # 业务侧单条命令不应超过这个量级
proto-max-bulk-len 32mb
```

注意：调小这两个值会让「大 value 写入」失败，所以**先治理大 key，再收紧参数**。顺序反了会直接打断业务。

---

## 六、CLIENT PAUSE：主从切换期的写保护

```
CLIENT PAUSE 5000 WRITE    # 暂停所有写命令 5 秒（读不受影响）
CLIENT PAUSE 5000 ALL      # 读写都暂停
CLIENT UNPAUSE
```

典型场景：主从切换（Sentinel/Cluster failover）时，客户端还没感知新主，旧主仍在接收写。暂停写可以把「脑裂窗口」压到最小。Java 侧（Lettuce/Jedis）通常在运维脚本里调用，而不是业务代码。

注意：`CLIENT PAUSE` 是**服务端挂起命令处理**，不是拒绝；客户端会看到延迟上升而不是报错。所以暂停时间要短（通常 1~5s），并且配合客户端的 `socketTimeout` 设置，避免客户端先超时重试造成双写。

---

## 七、连接数估算与 Java 侧治理

### 7.1 用 Little 定律算连接池

```
并发连接数 ≈ QPS × 平均耗时(秒)
```

例：单实例 QPS 20000，平均 Redis 耗时 0.5ms → 需要约 10 个「同时在飞」的连接。加上突发余量，池大小 20~30 足够。

很多团队 `maxTotal=200`，不是因为算出来需要，而是「怕不够」。而 `连接数 = pod 数 × 池大小`，在 K8s 弹性伸缩下会瞬间放大 10 倍。

### 7.2 三层配额必须对齐

```
Redis maxclients
  ≥ Σ(每个服务的 pod 上限 × 每 pod 连接上限) × 1.3（余量）
```

建议在发布流水线里做静态校验：解析每个服务的 `spring.data.redis.lettuce.pool.max-active` 与 HPA 的 `maxReplicas`，算出理论上限，超过 `maxclients` 的 70% 直接卡发布。

### 7.3 Java 侧关键配置

```yaml
spring:
  data:
    redis:
      client-name: order-svc
      timeout: 2s
      lettuce:
        pool:
          max-active: 32
          max-idle: 16
          min-idle: 4
          max-wait: 500ms
        shutdown-timeout: 200ms
```

Lettuce 的连接模型与 Jedis 不同：**默认共享一个连接**（多路复用），只有 `pool` 显式启用或 Pub/Sub、事务、阻塞命令才需要额外连接。所以「Lettuce 连接数爆炸」通常来自：

1. 每个请求 `RedisClient.create()` 新建客户端（最严重的错误）；
2. Pub/Sub 每个订阅者一条连接；
3. 使用了 `@Transactional`（MULTI）导致连接不能复用。

排查：

```bash
# 按 name 聚合连接数
redis-cli CLIENT LIST | awk '{for(i=1;i<=NF;i++) if($i ~ /^name=/) print $i}' | sort | uniq -c | sort -rn
```

输出会直接告诉你「哪个服务连太多」。

---

## 八、一次真实事故的完整复盘

**现象**：Redis 内存 3 小时内从 8GB 涨到 16GB 触发淘汰，业务 P99 从 2ms 涨到 800ms。

**排查路径**：

1. `INFO memory` → `used_memory` 高，`mem_fragmentation_ratio` 1.05（不是碎片）。
2. `INFO clients` → `connected_clients` 12000（maxclients 10000，已有拒绝）。
3. `CLIENT LIST` 按 `omem` 排序 → 3 个连接各占 1.2GB，`cmd=subscribe`。
4. 定位到某推荐服务：订阅了「全量商品变更」频道，但消费线程池只有 2 个线程，跟不上 3000 QPS 的发布。

**处置**：

1. 立即 `CLIENT KILL ID ...` 杀掉 3 条订阅连接（业务降级为拉模式）。
2. 把 `client-output-buffer-limit pubsub` 从 `0 0 0` 改为 `64mb 16mb 60`。
3. 长期改造：Pub/Sub → Streams + consumer group，消费端有界队列 + 丢弃计数。

**根因**：不是 Redis 配置问题，是「用 Pub/Sub 做可靠消息」的架构误用，加上输出缓冲无限制把问题放大成了内存事故。

---

## 九、监控与告警

| 指标 | 来源 | 阈值 |
|---|---|---|
| `connected_clients` | INFO clients | > maxclients × 0.7 |
| `blocked_clients` | INFO clients | 持续 > 0 且上升 |
| `client_recent_max_output_buffer` | INFO clients | 接近 pubsub/normal limit |
| 单连接 `omem` 最大值 | CLIENT LIST 采样 | > 64MB |
| `rejected_connections` | INFO stats | > 0 立即告警 |
| `maxmemory_clients` 驱逐次数 | INFO stats（`evicted_clients`） | > 0 说明有客户端在吃内存 |
| 按 name 聚合的连接数 | 定时采集 CLIENT LIST | 单服务突增 50% |

---

## 十、面试追问

**Q1：`CLIENT KILL` 能杀掉正在执行 `KEYS *` 的连接吗？**
不能立刻。Redis 单线程，kill 要等当前命令执行完。要中断长时间脚本用 `SCRIPT KILL`（只读脚本可杀），慢命令只能靠 `SLOWLOG` 定位后从源头禁掉。

**Q2：为什么 `idle` 很小但连接还是堆积？**
`idle` 只反映「最近一次交互」，连接池里的连接会被心跳/`PING` 刷新。判断堆积要看「按 name 分组的连接数」和「服务实例数 × 池大小」，而不是 `idle`。

**Q3：`maxmemory-clients` 和 `maxmemory` 淘汰有什么区别？**
前者按连接内存（`tot-mem`）断连接，后者按 key 的 LRU/LFU/random 淘汰数据。两者独立生效，一个治「连接吃内存」，一个治「数据吃内存」。

**Q4：为什么从库连接的输出缓冲要单独限制？**
全量同步（RDB + 增量）期间，主库要把大量写命令推给从库；如果从库网络慢，缓冲会暴涨。不限制会拖垮主库内存，所以 replica 的 limit 通常比 normal 更严格。

**Q5：RESP3 的 client-side caching 会带来什么连接问题？**
每个开启 tracking 的连接都要维护失效通知状态（`tracking_clients` 指标），并且失效消息也占输出缓冲。大量短连接开启 tracking 会导致通知风暴，建议只对长连接池开启，并设置 `CLIENT TRACKING ... OPTIN` 控制粒度。

---

## 总结

- `CLIENT LIST` 是连接治理的入口：先看 `flags` 分清角色，再看 `omem`/`qbuf` 找异常，最后按 `name` 聚合定位服务。
- `CLIENT KILL` 用过滤器语法，永远记得 `TYPE` 保护主从、`SKIPME` 防止自杀。
- 输出缓冲是隐藏的 OOM 源，`normal` 不要留 0；Pub/Sub 堆积要用 Streams 或有界队列解决，不是调大 limit。
- `maxmemory-clients` + `NO-EVICT` + `NO-TOUCH` 是 Redis 7 之后的三件套，分别治「连接吃内存」「保护运维连接」「扫描污染 LRU」。
- Java 侧的核心不是调参数，而是**连接命名 + 池大小与服务副本数的乘积校验 + 禁止每请求新建客户端**。

连接治理这件事，做得好没人会注意到；做得不好，一次发布就能让整个缓存层躺下。
