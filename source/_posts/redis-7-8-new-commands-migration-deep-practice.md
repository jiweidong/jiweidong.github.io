---
title: 【Redis 8 实战】Redis 7/8 新命令族深度解析：多 key 原子操作、WAITAOF 与客户端适配
date: 2026-11-21 08:00:00
tags:
  - Redis
  - Java
  - Lettuce
  - Jedis
  - 中间件
categories:
  - 中间件实战
author: 东哥
---

# 【Redis 8 实战】Redis 7/8 新命令族深度解析

## 前言

大多数团队用 Redis 的方式，五年没变过：`GET`/`SET`/`HSET`/`EXPIRE`/`ZADD`，外加一个 `SETNX` 做分布式锁。但从 Redis 7.0 到 8.x，官方补了一大批"以前必须写 Lua 才能原子完成"的命令，也补了几个直接把线上事故概率降下来的运维命令。

问题在于：**这些命令很多 Java 客户端没有第一时间封装**，于是团队要么继续用 Lua，要么根本不知道有这些东西。更麻烦的是，有几个命令的返回值语义非常反直觉（比如 `SINTERCARD` 带 `LIMIT`、`WAITAOF` 返回两个数），照着自己想象用，会比不用更危险。

这篇文章按"能替代什么 Lua / 能防什么事故"来梳理 Redis 7/8 的新命令，并给出 Java 侧（Lettuce 6.x、Jedis 5.x）的落法与升级适配清单。

## 一、先给结论：哪些命令值得立刻用

| 命令 | 版本 | 替代了什么 | 立刻用的理由 |
|---|---|---|---|
| `LMPOP` / `BLMPOP` | 7.0 | 多次 `LPOP` 或 Lua | 一次原子地从多个 list 取元素，队列优先级场景标准解法 |
| `ZMPOP` / `BZMPOP` | 7.0 | `ZPOPMIN` 循环 | 同上，带 score 返回 |
| `SINTERCARD` | 7.0 | `SINTER` + `SCARD` | 只算基数不传元素，百万级集合省带宽 |
| `HGETDEL` / `HGETEX` / `HSETEX` | 8.0 | `HGET`+`HDEL` / `HGET`+`EXPIRE` | hash 字段级"取走即删"与"取值续期"，原子 |
| `WAITAOF` | 7.2 | 无法替代 | 等 AOF 落盘确认，`WAIT` 只管复制不管持久化 |
| `CLIENT NO-EVICT` | 7.0 | 无法替代 | 保护关键连接不被 `maxmemory-clients` 踢掉 |
| `CLIENT NO-TOUCH` | 7.2 | 无法替代 | 后台扫描不污染 LRU/LFU，保住热 key |
| `HSCAN ... NOVALUES` | 7.4 | 全量 `HKEYS` | 大 hash 只取字段名，流量降一个量级 |
| `CLUSTER SLOT-STATS` | 8.0 | 自己聚合 | 直接看每个槽的 key 数/CPU/网络，定位热点槽 |

下面挑几个容易踩坑的展开。

## 二、多 key 原子弹出：LMPOP / ZMPOP 家族

### 2.1 它解决的真实问题

"从三个队列里按优先级取一个任务"，老写法是：

```lua
-- 老方案：Lua 脚本
for i, k in ipairs(KEYS) do
  local v = redis.call('LPOP', k)
  if v then return {k, v} end
end
return nil
```

能跑，但有两个代价：脚本要加载、要维护 KEYS 数量、集群模式下所有 key 必须在同一个 slot（否则 CROSSSLOT 报错）。

新写法：

```text
LMPOP 3 queue:high queue:mid queue:low LEFT COUNT 10
```

返回值是两元组：`[key, [element...]]`，没取到时返回 `nil`（RESP3 下是 null）。

```java
// Lettuce 6.x：LMPOP 有原生封装
List<KeyValue<String, List<String>>> result = sync.lmpop(
        LMPopArgs.Builder.left().count(10),
        "queue:high", "queue:mid", "queue:low");

if (result != null && !result.isEmpty()) {
    String queue = result.get(0).getKey();
    List<String> values = result.get(0).getValue();
    // 注意：可能一次拿到 10 条，业务侧要按批处理
}
```

### 2.2 三个必须知道的坑

**坑一：`COUNT` 不是"每个 key 取 N 条"，而是"总共最多取 N 条"。**

它会按 key 顺序贪心：先从 `queue:high` 尽量取满 10 条，取不满才轮到下一个。所以如果 high 队列有 3 条，你会拿到 `[queue:high, [3 条]]`，**不会**继续去 mid 拿 7 条。想跨队列凑满一批，需要循环调用。

**坑二：`BLMPOP` 的阻塞只发生在"所有 key 都空"时。**

只要有一个 key 有数据就立刻返回。如果 high 队列长期有数据，`BLMPOP` 永远不会阻塞到 mid —— 这就是优先级队列的正确行为，但如果你指望"公平轮询"，得自己加轮转。

**坑三：集群模式下所有 key 必须在同一 slot。**

这点和 `MGET` 一样。跨 slot 会直接 `CROSSSLOT`。多队列按优先级取，通常用 hash tag 绑到一个槽：

```text
LMPOP 3 {task:1}:high {task:1}:mid {task:1}:low LEFT
```

代价是这个槽变成热点槽。Redis 8 的 `CLUSTER SLOT-STATS` 正好能观测这件事：

```text
CLUSTER SLOT-STATS ORDERBY CPU DESC LIMIT 5
```

返回每个槽的 `key-count`、`cpu-usec`、`network-bytes-in/out`。热点槽的识别人肉做很痛苦，这个命令是刚需。

## 三、SINTERCARD：省带宽，但 LIMIT 语义反直觉

`SINTERCARD numkeys key [key ...] [LIMIT limit]`

不带 `LIMIT` 时返回真实交集基数，这个没歧义。带 `LIMIT` 时：

> **只要交集基数 ≥ limit，就返回 limit 本身**，并且提前终止计算。

也就是说 `SINTERCARD 2 a b LIMIT 100` 返回 `100` 时，真实基数可能是 100，也可能是 100 万。它回答的是"是否至少有 100 个"，不是"有多少个"。

```java
// 判断两个集合是否有交集（最常见的用法）
Long n = sync.sintercard(2, "user:1:tags", "user:2:tags", 1);
boolean hasCommon = n != null && n > 0;   // LIMIT 1 就是 EXISTS 语义
```

这个用法非常实用：**`LIMIT 1` 等价于"两个大集合有没有交集"**，百万级集合也是 O(1) 级别提前返回，比 `SINTER` 把整个结果集拉回来强太多。

Java 客户端注意：Lettuce 的 `sintercard(int numKeys, String... keys)` 有重载，带 limit 的版本参数顺序是 `(numKeys, keys[], limit)`，别写反 —— 写反了不报错，只是结果错。

## 四、Hash 字段级 TTL 与取走即删

Redis 8.0 把"字段级过期"补齐了（`HEXPIRE`/`HTTL` 一族），同时加了三个组合命令：

| 命令 | 语义 | 典型场景 |
|---|---|---|
| `HGETDEL key FIELDS n field...` | 读 + 删，原子 | 一次性验证码、一次性 token |
| `HGETEX key [EX s\|PX ms\|EXAT ts\|PXAT ts\|PERSIST] FIELDS n field...` | 读 + 续期 | session 滑动过期 |
| `HSETEX key [FNX\|FXX] [EX s\|...] FIELDS n field value...` | 写 + 设过期 | 限流窗口、临时缓存 |

`HSETEX` 的 `FNX`/`FXX` 是字段级的存在性条件（Field Not eXists / Field eXists），等价于 hash 版本的 `SET NX`/`SET XX`。

```java
// 一次性验证码：读取成功即失效，避免并发重复使用
List<String> code = sync.hgetdel("otp:13800000000", "code");
if (code != null && !code.isEmpty()) {
    // 只有第一个拿到值的请求能进这里
}
```

**这里有个内存层面的坑**：字段级 TTL 不是免费的。Redis 用 `ebuckets` 维护过期字段，当 hash 从 `listpack` 转成 `hashtable` 时（字段数 > 128 或单值 > 64 字节），每个字段都要额外挂过期元数据。如果你的场景是"一个 hash 放 10 万个字段、每个字段都设 TTL"，内存放大会非常明显 —— 这种场景应该拆成独立 key。

判断编码：

```text
OBJECT ENCODING myhash     # listpack / hashtable
DEBUG HTSTATS-KEY myhash   # 字段数与 bucket 分布（需开 DEBUG）
```

## 五、WAITAOF：复制确认 ≠ 持久化确认

这是我认为 7.2 之后最被低估的命令。

- `WAIT numreplicas timeout`：等到 N 个副本**收到**了写命令（在副本的内存缓冲里，可能还没落盘）。
- `WAITAOF numlocal numreplicas timeout`：等到本地 AOF（`numlocal` 取 0/1）和 N 个副本的 AOF 都完成 fsync。

返回值是两个整数：`[local, replicas]`。

```text
SET order:123 paid
WAITAOF 1 1 100
# 返回 [1, 1] 才表示：本地 AOF 已 fsync，且 1 个副本的 AOF 已 fsync
```

### 5.1 为什么 `WAIT` 不够

很多"Redis 保证不丢数据"的方案写的是 `WAIT 1 100`。但副本收到写命令只是进了 `repl_buffer`/socket，副本自己也可能在 fsync 之前宕机。如果主从同时故障（同机架、同可用区、同一次内核 panic），`WAIT` 返回成功也可能丢。

`WAITAOF` 才真正回答"数据是否落到了磁盘"。

### 5.2 三个前提条件

1. 本地必须开 `appendonly yes`，否则 `numlocal=1` 永远返回 0。
2. 副本也必须开 AOF，否则副本侧永远不计入。
3. `appendfsync everysec` 下，最长有 1 秒的窗口 —— `WAITAOF` 会等这一秒过去，**P99 延迟直接加 1s**。对延迟敏感的交易链路，这个代价通常不可接受，只能对账补偿。

所以务实结论：**`WAITAOF` 适合低频、高价值的写（支付回调落库、订单状态终态），不适合高频写。** 高频场景还是"Redis 做缓存 + DB 做真相源"。

### 5.3 Java 侧

Lettuce 目前对 `WAITAOF` 没有专门 API（版本跟进慢），用自定义命令：

```java
RedisCodec<String, String> codec = StringCodec.UTF8;
RedisCommands<String, String> custom = connection.sync();

// Lettuce 的 dispatch 需要协议层支持，实践中更稳的做法是走原生 ProtocolKeyword
ProtocolKeyword waitAof = new ProtocolKeyword() {
    private final byte[] bytes = "WAITAOF".getBytes(StandardCharsets.US_ASCII);
    @Override public byte[] getBytes() { return bytes; }
};

List<Object> r = (List<Object>) custom.dispatch(
        CommandType.valueOf("WAITAOF"),   // 或用自定义 CommandType
        new StatusOutput<>(codec),
        new CommandArgs<>(codec).add(1).add(1).add(100));
```

如果团队不想碰底层 dispatch，最省事的方案是给这类命令单独开一个 Jedis 连接（Jedis 的 `sendCommand` 更直接），别和主链路共用。

## 六、连接治理：CLIENT NO-EVICT 与 NO-TOUCH

### 6.1 `maxmemory-clients` 会踢掉你的关键连接

Redis 7.0 引入客户端输出缓冲总量限制 `maxmemory-clients`（默认 0，很多云托管默认设成 5%）。超限时，Redis 会按内存占用从大到小**断开**客户端。

问题：一个慢消费者订阅了大 pub/sub 频道，或者一个大 `SCAN` 的客户端，可能把整个连接池挤爆，导致业务连接被踢，表现为间歇性 `connection reset`。

```text
CLIENT NO-EVICT ON     # 当前连接豁免于 client eviction
```

Lettuce 里可以在连接初始化时发一次：

```java
connection.sync().dispatch(...);  // 或连接建立后执行一次
```

注意 **`NO-EVICT` 是连接级、非持久化**：连接断了重连后失效，必须在 `RedisConnectionStateListener` 里重发。这一点非常容易漏，漏了等于没设。

### 6.2 `CLIENT NO-TOUCH` 保护热 key

默认情况下，**任何**读命令都会更新 key 的 LRU 时钟或 LFU 计数器。你的后台任务每小时 `SCAN` 一遍全库做统计，会把所有冷 key 的访问时间刷成"刚刚"，于是 LRU 淘汰彻底失效 —— 内存满了以后开始随机淘汰，热 key 也可能被踢。

```text
CLIENT NO-TOUCH ON
SCAN 0 COUNT 1000
CLIENT NO-TOUCH OFF
```

这是运维脚本的标配。同样，`NO-TOUCH` 也是连接级状态，用完必须关，否则这条连接上正常业务的读也不会更新 LRU —— 比不设更糟。

## 七、升级适配清单

### 7.1 客户端版本对应

| 客户端 | 支持 LMPOP | 支持 HGETDEL/HSETEX | 支持 WAITAOF |
|---|---|---|---|
| Jedis 5.0+ | ✅ | ✅（5.2+） | ❌ 需 `sendCommand` |
| Lettuce 6.3+ | ✅ | ✅（6.4+） | ❌ 需自定义 |
| Redisson 3.27+ | ✅（RScoredSortedSet 等） | 部分 | ❌ |

**升级前必做**：把 `INFO server` 的 `redis_version` 打到启动日志里，并在客户端封装层做能力探测。理由很简单 —— 云托管 Redis 的版本号和开源版不是一回事，很多"8.0"实例其实缺命令。

```java
public final class RedisCapability {
    private final int major, minor;

    public boolean supports(String feature) {
        return switch (feature) {
            case "lmpop"     -> major > 7 || (major == 7);
            case "hgetdel"   -> major >= 8;
            case "waitaof"   -> major > 7 || (major == 7 && minor >= 2);
            case "slot-stats"-> major >= 8;
            default -> false;
        };
    }
}
```

能力探测不要用 `COMMAND INFO xxx` 的返回是否为空来判断 —— 部分代理层（如某些云 Redis 代理、Twemproxy）会假装支持然后转发失败。

### 7.2 集群/代理兼容性

| 环境 | 风险点 |
|---|---|
| Redis Cluster | 多 key 命令必须同 slot；`CLUSTER SLOT-STATS` 需逐节点执行 |
| 云 Redis 代理模式 | 多 key 命令可能被代理拒绝或跨 slot 转发失败 |
| Twemproxy / Predixy | 基本不支持 7.0+ 新命令，需先在测试环境验证 |
| 主从 + 读写分离 | `WAITAOF` 只对主库有意义 |

**经验值**：凡是"多 key 原子"的新命令，先在**代理层**做一次 `COMMAND` 探测或直接跑一遍集成测试。代理层是新命令最大的黑洞，比客户端严重得多。

### 7.3 灰度顺序

1. 测试环境全量跑新命令的集成测试（含集群模式）。
2. 生产先只读路径用（`SINTERCARD`、`HSCAN NOVALUES`），风险最低。
3. 写路径（`LMPOP`、`HGETDEL`）按业务维度灰度 1% → 10% → 100%，观察 `latency_percentiles_usec_lmpop` 和错误率。
4. `WAITAOF` 只在低频高价值链路开，且必须配超时降级。

## 八、面试追问

**Q：`WAIT` 和 `WAITAOF` 的本质区别是什么？**

`WAIT` 确认的是"副本收到了命令字节"，`WAITAOF` 确认的是"本地/副本的 AOF 完成了 fsync"。前者防的是主库单点故障，后者防的是主机掉电/内核崩溃这类"内存丢了但连接还通"的场景。真正要防数据丢失，还得看 `appendfsync` 策略和副本数量。

**Q：`LMPOP` 和 Lua 脚本比，优势在哪？**

一是省掉脚本加载与 SHA 管理；二是集群模式下 Lua 同样受 CROSSSLOT 限制，并没有优势；三是 `LMPOP` 是原生命令，代理层/监控的兼容性更好。但 `LMPOP` 只能"按 key 顺序贪心取"，做不了 Lua 那样的复杂条件判断。

**Q：为什么 `SINTERCARD` 带 `LIMIT` 会返回 `limit` 而不是真实值？**

因为它的设计目标是"提前终止"，一旦数到 limit 就没必要继续扫描。这既是性能来源，也是语义陷阱 —— 需要精确基数时不能带 `LIMIT`。

**Q：`CLIENT NO-EVICT` 设了还会被踢吗？**

会。它只豁免 client eviction（`maxmemory-clients` 触发的那一类），不豁免 `maxmemory` 达到后写命令返回 OOM error，也不豁免运维手动 `CLIENT KILL`，更不豁免网络层超时。而且要重连后重设。

## 九、落地踩坑清单

1. **`COUNT` 是总量不是每 key 量** —— 优先级队列场景最容易错。
2. **`SINTERCARD LIMIT` 返回的是上限** —— 别拿它算 UV。
3. **字段级 TTL 有内存放大** —— hash 字段数上万时不要给每个字段设 TTL。
4. **`WAITAOF` 在 `everysec` 下有 1s 延迟** —— 高频链路禁用。
5. **`NO-EVICT`/`NO-TOUCH` 是连接级状态** —— 重连后必须重设。
6. **代理层不支持新命令** —— 升级前跑通集成测试，不要只测单机。
7. **能力探测不能只看版本号** —— 云托管版本号不可信。
8. **`HSCAN NOVALUES` 是 7.4+** —— 7.2 的实例会直接语法错误。

Redis 的新命令不是"炫技"，它们大多是把"以前必须写 Lua 且有坑"的操作标准化了。真正值钱的不是记住命令名，而是知道**每个命令在什么边界上会骗你**。上面这几条，就是我在生产里被教育过的部分。
