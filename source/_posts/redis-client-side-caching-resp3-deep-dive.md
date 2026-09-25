---
title: 【Redis 原理】Redis 客户端缓存（Client-side Caching）与 RESP3 深度解析
date: 2026-09-25 08:00:00
tags:
  - Redis
  - RESP3
  - 客户端缓存
  - 缓存架构
  - 中间件
categories:
  - Redis
  - 中间件
author: 东哥
---

# 【Redis 原理】Redis 客户端缓存（Client-side Caching）与 RESP3 深度解析

## 面试官：本地缓存和 Redis 的一致性，你怎么解？

「你们用了 Caffeine 做本地缓存，Redis 里改了数据，本地缓存怎么失效？」

大部分人的答案是：「设短 TTL」「延迟双删」「订阅 Redis 的发布订阅频道」。面试官往往会追问一句：

「那如果我有 500 个实例，每个实例都在本地缓存了同一批热点数据，Redis 6 给了你一个官方方案，你了解吗？」

这就是 **客户端缓存（Client-side Caching）**——Redis 6.0 引入、依赖 **RESP3** 协议的通知机制。它把「失效广播」这件事从业务代码下沉到了 Redis 协议层。这篇把它讲透。

## 一、为什么要客户端缓存

多级缓存的经典结构是「本地缓存 → Redis → DB」：

```
请求 → Caffeine（μs 级） → Redis（~1ms，含网络） → MySQL
```

本地缓存的价值在于**消除网络往返**。对于秒杀热点 Key、配置项、排行榜 TopN 这类「读极多写极少」的数据，本地缓存的收益非常明显：单次访问从 1ms 降到 100ns 级别。

但代价是**一致性**：

| 方案 | 一致性 | 复杂度 | 缺点 |
| --- | --- | --- | --- |
| 短 TTL | 弱 | 低 | 有窗口期；TTL 短则命中率低 |
| 手动双删 | 中 | 中 | 时序难控，仍有窗口 |
| 发布订阅广播失效 | 强 | 中 | 需要额外 topic/连接，消息不保证送达 |
| **客户端缓存（Redis 6+）** | 强 | 中 | 需要 RESP3 与客户端支持 |

客户端缓存要解决的核心问题就是：**Redis 端的数据变了，怎么让所有持有本地副本的客户端立刻知道**。

## 二、RESP3：一切的协议基础

RESP2 只有几种基本类型，且**没有推送信道**——服务端无法主动往一个请求-响应式的连接上「插话」。RESP3 的关键改进：

1. **`HELLO` 命令**：协商协议版本，`HELLO 3` 切到 RESP3，返回服务端信息（版本、模式、角色、模块）。
2. **新增类型**：Map（`%`）、Set（`~`）、Double（`,`）、Boolean（`#`）、Big Number（`(`）、Null（`_`）、Push（`>`）、Verbatim String（`=`）、Blob Error（`!`）。
3. **Push 类型（`>`）**：**服务端可以主动推送数据**，与请求响应共享同一连接，这是客户端缓存失效通知的传输载体。

```
客户端                          Redis
  |-- HELLO 3 ------------------>|
  |<-- %7 map (server, version) -|
  |-- CLIENT TRACKING ON ------->|
  |<-- +OK ----------------------|
  |-- GET user:1 --------------->|
  |<-- $12 "payload" ------------|
  |         ... 其他客户端改写 user:1 ...
  |<-- >2 invalidate [user:1] ---|   <-- 服务端主动推送失效
```

## 三、两种跟踪模式

### 3.1 默认模式（Default Tracking）

```bash
CLIENT TRACKING ON
```

客户端通知 Redis：「这个连接读过的 Key，如果被改了，请通知我」。Redis 在**服务端跟踪表（tracking table）**里记录「哪些 Key 被哪些连接读过」：

- 客户端 `GET user:1` → Redis 记录 `user:1 → {conn A}`。
- 任意客户端 `SET user:1 xxx` → Redis 查表，向 `conn A` 推送 `invalidate`，并删除该 Key 的跟踪记录。

**默认模式是「按需注册」**：只有被读过的 Key 才占跟踪表空间，内存更省，但每次读都要在服务端写一条记录，有一定写开销。

**关键限制**：如果客户端只在本地缓存里保存了数据，Redis 不知道它读过什么——**首次读必须走 Redis**（或至少在 Redis 上「登记」一次）。这通过 `CLIENT CACHING YES` 实现：

```bash
CLIENT CACHING YES   # 下一条只读命令的结果会被跟踪
GET user:1
CLIENT CACHING NO    # 关闭（默认行为取决于 CLIENT TRACKING 的 OPTIN/OPTOUT）
```

`CLIENT TRACKING ON OPTIN`：默认不跟踪，需 `CLIENT CACHING YES` 显式开启**下一条**命令的跟踪。
`CLIENT TRACKING ON OPTOUT`：默认跟踪，可用 `CLIENT CACHING NO` 排除下一条。
这两种在「批量读很多 Key 但只缓存其中少数」时很有用，能省跟踪表内存。

### 3.2 广播模式（Broadcast Tracking，BCAST）

```bash
CLIENT TRACKING ON BCAST PREFIX user: PREFIX config:
```

默认模式需要「读一次才注册」，广播模式则是**客户端声明自己关心哪些前缀，服务端不做逐 Key 记录，只要前缀匹配就被通知**。

特点：

- **不占跟踪表**（无逐 Key 内存开销）；
- **但会增加服务端与网络开销**：任何匹配前缀的 Key 变更，都要把通知推给所有订阅了该前缀的连接。前缀越宽，通知越多。
- 适合**键空间有限且高频读**的场景（如固定的配置 Key、少量热点字典）。

**面试追问：BCAST 为什么不用跟踪表？**
因为广播模式是「按前缀订阅」，服务端只需在键被修改时对前缀做匹配，不需要维护「Key→连接」的映射。代价是同一前缀下任意 Key 的改动都会通知到全部订阅者，可能产生大量无用通知。

### 3.3 两种模式对比

| 维度 | 默认模式 | 广播模式（BCAST） |
| --- | --- | --- |
| 注册方式 | 读取时自动注册（或 CLIENT CACHING） | 按前缀订阅 |
| 服务端内存 | 占跟踪表，与跟踪 Key 数成正比 | 几乎不占 |
| 通知精度 | 精确到被改的 Key | 前缀内所有改动（可能冗余） |
| 适用场景 | Key 多、访问分散 | Key 少、访问集中 |
| 关键参数 | `tracking-table-max-keys` | `PREFIX` |

## 四、重定向：RESP3 之外的客户端怎么办

老客户端可能不支持 RESP3 Push 或不想在业务连接上处理异步消息。Redis 提供了**重定向**：把失效通知推到**另一个连接的 Pub/Sub 频道**。

```bash
# 连接 2 先订阅
SUBSCRIBE __redis__:invalidate

# 连接 1：开启跟踪，并把通知重定向到连接 2
CLIENT TRACKING ON REDIRECT 2
```

**重要限制**：一旦使用 `REDIRECT`，该连接**只能用 RESP2**（重定向的设计就是在不支持 Push 的客户端上工作）。另外，被重定向的连接**不能带 `PREFIX` 的 BCAST 以外的语义……**更准确地说，`REDIRECT` 与 `BCAST` 可以组合，但 `REDIRECT` 必须指定一个真实的客户端 ID，且该客户端必须已订阅 `__redis__:invalidate`。

**易错点**：把 `REDIRECT` 指向自己（`REDIRECT <自己的ID>`）在 RESP3 下不会走 Push，而是走订阅频道；很多教程在这里坑过。

## 五、运维与观测命令

```bash
CLIENT ID                        # 当前连接 ID（重定向要用）
CLIENT TRACKINGINFO              # 查看当前连接的跟踪状态、模式、前缀、重定向目标
CLIENT TRACKING ON BCAST PREFIX hb:
CLIENT TRACKING OFF              # 关闭跟踪
CLIENT KILL ID 42                # 关掉某连接（其跟踪记录一并清理）
```

配置项：

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `tracking-table-max-keys` | 1000000 | 跟踪表 Key 上限（默认模式） |
| `client-output-buffer-limit pubsub` | 32mb/8mb/60 | 推送缓冲上限（Pub/Sub 类似） |
| `maxmemory-policy` | noeviction | 跟踪表**不受 eviction 影响**，达到上限时按比例随机清理 |

⚠️ **跟踪表达到 `tracking-table-max-keys` 时会随机丢弃部分跟踪记录**，被丢弃的 Key 一旦变更，客户端就收不到通知 → **本地缓存可能永久脏**。所以务必监控跟踪表大小，并把 TTL 作为兜底。

## 六、客户端实战：Lettuce

Lettuce 从 6.x 起原生支持 RESP3 与客户端缓存：

```java
RedisClient client = RedisClient.create("redis://localhost:6379");
// 开启 RESP3
StatefulRedisConnection<String, String> conn = client.connect(
        RedisURI.create("redis://localhost:6379"), 
        RedisCodec.of(StringCodec.UTF8, StringCodec.UTF8));

// 使用内置的客户端缓存（本地缓存由 ClientSideCaching 封装，底层可挂 Caffeine）
CacheFrontend<String, String> frontend = ClientSideCaching.enable(
        CacheAccessor.forRules(conn, ClientSideCaching.defaultTrackingRules()),
        conn,                    // 用于跟踪的连接
        TrackingArgs.Builder.enabled());

String value = frontend.get("user:1");   // 命中本地则不访问 Redis
```

要点：
- Lettuce 会自动处理 `HELLO 3`、`CLIENT TRACKING`、失效 Push，并在收到 `invalidate` 时**使本地缓存条目失效**（不是更新，是删除，下次读再回源）。
- Jedis 4.x 也有 RESP3 支持（`JedisClientConfig.builder().protocol(RedisProtocol.RESP3)`），但客户端缓存的封装不如 Lettuce 成熟，很多团队基于 `JedisPubSub` + 自研实现。

## 七、和 Caffeine 自研方案的关系

一个常见的困惑：**我已经有 Caffeine，为什么还要 Redis 客户端缓存？**

其实二者**不冲突**，是不同层次：

| 层 | 组件 | 作用 |
| --- | --- | --- |
| 本地缓存容器 | Caffeine | 提供 TTL/LFU 淘汰、并发控制 |
| 失效通知 | Redis Tracking + RESP3 | 跨实例的失效广播 |
| 兜底 | TTL | 通知丢失时的最终一致性保障 |

换句话说，客户端缓存解决的是「**怎么让 Caffeine 跨实例及时失效**」，而 Caffeine 解决的是「本地怎么存、怎么淘汰」。

## 八、适用场景与坑

**适合**
- 读远多于写、Key 集合可控的热点数据（配置、字典、热门商品）；
- 对一致性敏感、TTL 不能太短的场景。

**不适合**
- Key 极度分散（默认模式跟踪表会膨胀）；
- 写极频繁（失效通知风暴，还不如直接读 Redis）；
- 需要 RESP2 的老客户端集群（只能用 REDIRECT，跳一层 Pub/Sub）。

**必须注意**
1. **失效通知是「尽力而为」**：连接断开期间的通知会丢失，所以 **TTL 兜底不可省**。
2. **不重连就永远脏**：客户端要正确处理重连后重新开启 tracking。
3. **跟踪表上限**：默认 100 万 Key，超了会随机清理，隐性脏读。
4. **通知不保证顺序**：并发改同一 Key 时有多次 invalidate，本地删除操作是幂等的，无需担心。
5. **集群模式**：客户端缓存工作在**单节点连接**维度；Redis Cluster 下每个分片节点独立维护跟踪表，客户端需对每个节点连接开启 tracking（Lettuce 已处理）。

## 九、生产落地清单与监控

把客户端缓存推到生产，至少要落实这几件事：

**接入侧**

1. 明确「哪些 Key 参与客户端缓存」，用 `BCAST + PREFIX` 或 `OPTIN` 把范围收窄，别让跟踪表无界膨胀。
2. 本地统一只做「删除失效」不做「更新失效」——收到 `invalidate` 就 `cache.invalidate(key)`，下次读回源，避免把过期/旧值写进本地。
3. 每个本地条目都带 **TTL + 随机抖动** 作为兜底，防止通知丢失导致永久脏。
4. 回源加**单飞（singleflight）**，避免热点 Key 失效瞬间出现惊群。

**运维侧**

| 指标 | 关注点 | 告警建议 |
| --- | --- | --- |
| `INFO clients` 的 `tracking_clients` | 开启跟踪的连接数 | 异常突增说明客户端没正确关闭 |
| 跟踪表大小 | 默认模式内存占用 | 接近 `tracking-table-max-keys` 必须扩容或改 BCAST |
| `client-output-buffer-limit pubsub` | 推送缓冲溢出 | 溢出会静默丢通知 → 本地缓存脏 |
| 连接断开/重连次数 | 断连期间通知丢失 | 重连后必须重新发 `CLIENT TRACKING ON` |

**降级预案**：一旦客户端缓存机制异常（重连风暴、跟踪表打满），可临时切到「纯 TTL 短缓存」模式，牺牲一点一致性换可用性。

```java
// 伪代码：收到 invalidate 后的标准处理
frontend.listenInvalidations();      // Lettuce 内部注册 Push 监听
onInvalidate(keys -> keys.forEach(caffeine::invalidate)); // 只删不写
```

## 十、面试追问合集

**Q1：客户端缓存的失效通知会丢吗？**
会话级是「尽力而为」：连接断开、推送缓冲溢出（`client-output-buffer-limit`）、跟踪表超限被随机清理，都会导致通知丢失。所以它保证的是「**大多数情况下的强一致 + TTL 兜底**」，不是绝对一致。

**Q2：默认模式为什么要 `CLIENT CACHING YES`？**
因为 Redis 只知道「你读过的 Key」，不知道「你在本地缓存了哪些 Key」。默认模式下普通 `GET` 会自动注册；`OPTIN` 模式下需要显式声明下一条命令要参与跟踪。这是为了让你能精确控制跟踪范围、节省跟踪表内存。

**Q3：和 Binlog/CDC 方案比呢？**
CDC（Canal/Debezium → MQ）也能广播失效，且能做到跨存储（DB 变更驱动）。但它链路更长、延迟更高、运维更重。客户端缓存是「Redis 自己就是数据源」时的最轻量方案。二者常并存：DB → CDC 更新缓存 → Redis Tracking 通知实例。

**Q4：会不会造成惊群？**
会。热点 Key 失效后，数千个实例同时回源 Redis/DB。缓解：本地做「单飞（singleflight）」合并回源、加随机抖动 TTL、对回源加本地限流。

## 十一、总结

- 客户端缓存 = **RESP3 的 Push 能力 + 服务端跟踪表 + 客户端的本地缓存失效**。
- 默认模式精确但占内存（需读时注册）；BCAST 按前缀订阅、几乎不占内存但通知可能冗余。
- `REDIRECT` 是给不支持 RESP3 的客户端的降级方案，靠 Pub/Sub 频道转发。
- 它把「跨实例缓存一致性」从业务代码下沉到协议层，但**永远要用 TTL 和容错兜底**——通知可能丢。
- 落地时优先 Lettuce 6+；Caffeine 负责本地容器，Redis 负责失效广播，两者配合而非替代。

下一篇继续聊 Redis 的协议层：**RESP3 的 Push 机制还能怎么用**——以及 Redis 7 的 `Functions` 如何替代 Lua 脚本。
