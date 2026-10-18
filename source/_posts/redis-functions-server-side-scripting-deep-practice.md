---
title: 【Redis 实战】Redis Functions 深度实战：服务端函数、Lua 脚本治理与原子性边界
date: 2026-10-18 08:10:00
tags:
  - Java
  - Redis
  - Lua
  - 分布式
  - 中间件
categories:
  - Java 深挖
author: 东哥
---

# 【Redis 实战】Redis Functions 深度实战：服务端函数、Lua 脚本治理与原子性边界

## 前言

`EVAL` 大概是 Redis 里被滥用最多的命令之一。限流、扣库存、分布式锁续期、幂等校验，全都往里塞一段 Lua。短期很爽，长期很痛：

- 脚本字符串散落在几十个 Java 类里，改一行要发版；
- 没有版本概念，线上到底跑的是哪一版脚本说不清；
- `SCRIPT FLUSH` 之后所有 `EVALSHA` 报 `NOSCRIPT`，流量一冲就雪崩；
- 没有统一的权限边界，谁都能 `EVAL` 一段死循环把实例拖垮；
- 集群模式下 key 跨 slot 直接报 `CROSSSLOT`。

Redis 7.0 引入的 **Functions（服务端函数）** 就是来收拾这个烂摊子的：脚本变成「库（library）」，有名字、有版本、持久化、可复制、可管理，客户端只负责 `FCALL` 调用。

这篇文章讲清楚三件事：**Functions 的模型与生命周期**、**Java 侧怎么落地**、**原子性与集群边界在哪**。最后给一份「Lua → Functions」的迁移清单和面试追问。

---

## 一、从 EVAL 到 FCALL：模型变化

### 1.1 EVAL 的问题

```java
// 典型写法：脚本内嵌在 Java 代码里
String script = """
    if redis.call('EXISTS', KEYS[1]) == 1 then
        return 0
    end
    redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
    return 1
    """;
redisTemplate.execute(new DefaultRedisScript<>(script, Long.class), keys, args);
```

问题清单：

| 问题 | 表现 |
|---|---|
| 脚本无独立生命周期 | `SCRIPT FLUSH`、主从切换、实例迁移后缓存失效 |
| 无版本管理 | 改脚本靠发版，回滚靠 Git |
| 无统一审计 | 不知道谁在什么时候执行了什么脚本 |
| 无法复用 | 相同逻辑在多个服务里复制粘贴 |
| 调试困难 | 只能靠 `redis.log` 和返回值猜 |

`EVALSHA` 稍好一点（只传 SHA1），但依然要客户端自己处理 `NOSCRIPT` 回退。

### 1.2 Functions 的模型

Functions 把脚本组织成**库**，库加载到 Redis 后常驻，并可被复制到副本、写入 AOF/RDB。

```lua
#!lua name=ratelimit

local function sliding_window(keys, args)
    local key = keys[1]
    local now = tonumber(args[1])
    local window = tonumber(args[2])
    local limit = tonumber(args[3])

    redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
    local count = redis.call('ZCARD', key)
    if count >= limit then
        return 0
    end
    redis.call('ZADD', key, now, now .. '-' .. math.random())
    redis.call('PEXPIRE', key, window)
    return 1
end

redis.register_function{
    function_name = 'sliding_window',
    callback = sliding_window,
    flags = { 'no-writes' },   -- 注意：这里其实有写，下面会讲为什么不能这么写
    description = '滑动窗口限流'
}
```

客户端调用：

```bash
FCALL ratelimit sliding_window 1 rate:user:1001 1710000000000 60000 100
```

和 EVAL 的对比：

| 维度 | EVAL / EVALSHA | Functions |
|---|---|---|
| 存储 | 脚本缓存（易失） | 库常驻 + 持久化 |
| 版本 | 无 | 库名 + 可 `FUNCTION LIST` 查看 |
| 复制 | 脚本不复制 | 库随复制传播 |
| 集群 | 手动保证同 slot | keyspec 声明，路由更清晰 |
| 管理 | `SCRIPT KILL` | `FUNCTION LIST/STATS/DUMP/RESTORE/FLUSH/KILL` |
| 调用 | `EVAL`/`EVALSHA` | `FCALL`/`FCALL_RO` |

> 注意：Functions **不是** Lua 的替代品，它还是 Lua 5.1 引擎（Redis 7.0），只是把「脚本」升级成了「可管理的一等公民」。

---

## 二、库的定义规则与生命周期

### 2.1 库的强制约定

一个库必须满足：

1. 第一行是 `#!lua name=<libname>` 的 shebang；
2. 库名全局唯一，重复加载会报 `ERR Library 'xxx' already exists`；
3. 库内通过 `redis.register_function` 注册一个或多个函数；
4. 函数名在**整个实例**内唯一（不是库内唯一）。

加载：

```bash
FUNCTION LOAD "#!lua name=ratelimit
local function sliding_window(keys, args) ... end
redis.register_function('sliding_window', sliding_window)
"
```

`FUNCTION LOAD REPLACE` 用于覆盖同名库（这是发布新版本的入口）。

### 2.2 生命周期

```text
FUNCTION LOAD  →  库进入内存  →  随 RDB/AOF 持久化
                      ↓
              FUNCTION LIST / STATS 可观测
                      ↓
        FUNCTION DUMP → 二进制快照 → FUNCTION RESTORE 到其他实例
                      ↓
              FUNCTION FLUSH [ASYNC|SYNC] 卸载
```

关键行为：

- **持久化**：库会写进 RDB（作为 payload）和 AOF（`FUNCTION LOAD` 命令），重启后自动恢复；
- **复制**：主节点加载库后，会以命令形式传播给副本，副本无需单独加载；
- **主从切换**：新主已有库（因为复制过），客户端不需要重新 `FUNCTION LOAD`；
- **`FUNCTION FLUSH`**：卸载所有库，**不可恢复**（除非有 dump）。生产环境应禁止直接执行。

### 2.3 函数 flags 与 keyspec

`register_function` 的完整表形式：

```lua
redis.register_function{
    function_name = 'deduct_stock',
    callback = deduct_stock,
    flags = { 'no-writes' },          -- 只读函数，可在副本执行
    description = '原子扣减库存',
    -- Redis 7.2+ 支持 keyspec，声明 key 的位置
}
```

常用 flags：

| flag | 含义 | 使用场景 |
|---|---|---|
| `no-writes` | 函数不写数据 | 只读查询，可路由到副本（`FCALL_RO`） |
| `allow-oom` | OOM 时仍允许执行 | 需要清理内存的函数（慎用） |
| `allow-stale` | 允许在数据过期（stale）副本执行 | 只读、可容忍陈旧 |
| `no-cluster` | 禁止在集群模式执行 | 依赖全局状态的函数 |
| `allow-cross-slot-keys` | 允许跨 slot key | **极危险**，破坏集群语义 |

`keyspec`（Redis 7.2+）让 Redis 知道函数会访问哪些 key，用于集群路由和 ACL：

```lua
redis.register_function{
    function_name = 'transfer',
    callback = transfer,
    flags = { 'no-writes' },   -- 示例，实际转账是写
    description = '账户转账'
}
```

> 一个高频误解：**`no-writes` 不是「声明式优化」，而是硬约束**。标了 `no-writes` 的函数里调用 `SET` 会直接报错。上面第一个示例里我故意写错，就是为了提醒这一点——限流函数有写操作，**不能**标 `no-writes`。

---

## 三、三个生产级函数实现

### 3.1 原子扣减库存（防超卖）

```lua
#!lua name=inventory

local function deduct(keys, args)
    local stockKey = keys[1]
    local qty = tonumber(args[1])
    if qty <= 0 then
        return -2                       -- 参数非法
    end
    local stock = tonumber(redis.call('GET', stockKey))
    if stock == nil then
        return -1                       -- 商品不存在
    end
    if stock < qty then
        return 0                        -- 库存不足
    end
    redis.call('DECRBY', stockKey, qty)
    return stock - qty                  -- 返回剩余库存
end

redis.register_function{
    function_name = 'deduct',
    callback = deduct,
    description = '原子扣减库存，返回剩余库存；0=不足，-1=不存在，-2=非法'
}
```

Java 调用：

```java
@Component
public class InventoryRepository {

    private final StringRedisTemplate redis;

    public DeductResult deduct(String sku, int qty) {
        Long remain = redis.execute((RedisCallback<Long>) conn ->
            conn.functionCall(
                FunctionArgs.Builder.function("inventory", "deduct")
                    .keys("stock:" + sku)
                    .arg(String.valueOf(qty))
                    .build()
            )
        );
        if (remain == null) throw new IllegalStateException("fcall returned null");
        if (remain == -1) return DeductResult.notFound();
        if (remain == -2) return DeductResult.badRequest();
        if (remain == 0)  return DeductResult.soldOut();
        return DeductResult.success(remain);
    }
}
```

> 上面用的是 Spring Data Redis 3.x 的 `RedisConnection#functionCall`（底层封装 `FCALL`）。如果你的版本没有该方法，可以用 `LettuceConnection` 的 `fcall`，或直接 `redisTemplate.execute(connection -> connection.execute("FCALL", ...))` 走原生命令。

几个要点：

- **不要在函数里做多 key 操作**（除非同 slot）。`stock:{sku1}` 和 `stock:{sku2}` 用 hash tag 保证同 slot。
- **返回码不要用字符串**，用整数/数组，解析成本和歧义都更低。
- **函数内不要 `KEYS` 扫描**，Redis 单线程，一个 `KEYS *` 能把实例卡死。

### 3.2 幂等令牌（SetNX + 过期）

```lua
#!lua name=idempotent

local function acquire(keys, args)
    local key = keys[1]
    local token = args[1]
    local ttl = tonumber(args[2])
    local ok = redis.call('SET', key, token, 'NX', 'PX', ttl)
    if ok then return 1 else return 0 end
end

local function release(keys, args)
    local key = keys[1]
    local token = args[1]
    if redis.call('GET', key) == token then
        return redis.call('DEL', key)
    end
    return 0
end

redis.register_function('acquire', acquire)
redis.register_function('release', release)
```

这个例子说明 Functions 的**复用价值**：`acquire`/`release` 成对注册在同一个库里，多个服务共享同一套语义，不会出现「A 服务删锁没校验 token」的低级 bug。

### 3.3 滑动窗口限流（修正版）

```lua
#!lua name=ratelimit

local function sliding_window(keys, args)
    local key = keys[1]
    local now = tonumber(args[1])
    local window = tonumber(args[2])
    local limit = tonumber(args[3])
    local member = args[4]

    redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
    if redis.call('ZCARD', key) >= limit then
        return 0
    end
    redis.call('ZADD', key, now, member)
    redis.call('PEXPIRE', key, window)
    return 1
end

redis.register_function('sliding_window', sliding_window)
```

> 不标 `no-writes`，因为它确实写。`member` 由客户端传入 UUID，避免同一毫秒内多个请求用相同 score 覆盖（`ZADD` 相同 member 是更新，不是新增）。

---

## 四、原子性边界：Functions 能保证什么，不能保证什么

这是面试最爱问、生产最容易踩的部分。

### 4.1 能保证的

- **单命令级原子**：函数执行期间，Redis 不会插入其他命令（单线程模型）。
- **全有或全无（对内存状态）**：函数内多条写命令，要么都执行，要么在报错前已执行的保留（**注意：Redis 不支持回滚**）。
- **隔离性**：函数执行期间没有其他客户端能看到中间状态。

### 4.2 不能保证的

| 误解 | 事实 |
|---|---|
| 「函数报错会自动回滚」 | **不会**。Lua 脚本/函数执行到一半报错，之前的写已生效 |
| 「函数能保证跨实例原子」 | 不能，只在单个 Redis 实例/单 slot 内原子 |
| 「函数能替代分布式事务」 | 不能，跨服务、跨库的一致性仍需 Saga/TCC |
| 「函数执行不会被中断」 | 超过 `lua-time-limit`（默认 5s）会记录慢日志；只读函数可被 `FUNCTION KILL` 终止，写函数**不能**被杀 |
| 「函数里可以随便 `sleep`」 | 没有 `sleep`，`redis.call` 之外的阻塞会拖死整个实例 |

### 4.3 超时治理

```conf
# redis.conf
lua-time-limit 5000          # 5s，超过后 Redis 开始拒绝其他命令并记录日志
busy-reply-threshold 5000    # 别名，两者等价
```

超过阈值后：

- Redis 返回 `BUSY Redis is busy running a script`；
- 只有 `FUNCTION KILL`（只读函数）或 `SHUTDOWN NOSAVE` 能解；
- **写函数无法被 kill**，只能等它跑完或重启——这是生产事故的经典形态。

所以函数必须**短小**：O(1) 或 O(logN)，绝不循环大集合。

---

## 五、集群模式注意事项

### 5.1 同 slot 约束

```bash
# 错误：两个 key 落在不同 slot
FCALL transfer 2 account:1 account:2 100
# CROSSSLOT Keys in request don't hash to the same slot
```

解决：用 hash tag。

```bash
FCALL transfer 2 account:{1001} account:{1001}:vip 100
```

`{1001}` 内的内容参与 hash，两个 key 落同一 slot。

### 5.2 库的传播

- 集群模式下，`FUNCTION LOAD` 需要在**每个 master** 上执行（或用 `redis-cli --cluster call`）；
- 副本通过复制获得库，不需要单独加载；
- `FUNCTION LIST` 只显示当前节点，排查时要逐节点查。

```bash
redis-cli --cluster call 10.0.0.1:6379 FUNCTION LIST
```

### 5.3 路由

`FCALL` 的第一个 key 决定路由节点。如果函数声明了 keyspec，客户端（如 Lettuce）可以自动路由；否则需要业务自己算 slot。

---

## 六、Java 客户端落地

### 6.1 Lettuce

```java
RedisClient client = RedisClient.create("redis://localhost:6379");
StatefulRedisConnection<String, String> conn = client.connect();
RedisCommands<String, String> cmd = conn.sync();

// 加载库（通常在启动时做一次）
String lib = """
    #!lua name=demo
    redis.register_function('ping_fn', function(keys, args)
        return redis.call('PING')
    end)
    """;
cmd.functionLoad(lib, true);   // replace = true

// 调用
Object result = cmd.fcall("demo", "ping_fn", new String[]{}, new String[]{});
```

### 6.2 Spring Data Redis

```java
@Configuration
public class RedisFunctionConfig {

    @Bean
    public ApplicationRunner loadFunctions(StringRedisTemplate redis) {
        return args -> redis.execute((RedisCallback<String>) conn ->
            conn.functionLoad(RedisFunctionLibrary.of("""
                #!lua name=inventory
                redis.register_function('deduct', function(keys, args)
                    local stock = tonumber(redis.call('GET', KEYS[1]))
                    local qty = tonumber(ARGV[1])
                    if stock == nil or stock < qty then return 0 end
                    return redis.call('DECRBY', KEYS[1], qty)
                end)
                """), true)
        );
    }
}
```

**启动加载的幂等性**：用 `FUNCTION LOAD REPLACE` 而不是 `FUNCTION LOAD`，否则多实例同时启动会报 `Library already exists`。更好的是**用配置中心控制版本**，只在版本变化时加载。

### 6.3 版本管理实践

推荐做法：

1. 库名带语义：`inventory`、`ratelimit`、`idempotent`，不要用 `lib1`；
2. 函数签名稳定：参数顺序、返回码一旦发布不要改，新增用新函数名；
3. 发布流程：`FUNCTION DUMP` 备份 → `FUNCTION LOAD REPLACE` → 灰度验证 → 全量；
4. 回滚：`FUNCTION RESTORE <dump> REPLACE` 或重新加载旧版本；
5. 监控：`FUNCTION STATS` 看调用次数、错误数、平均耗时。

```bash
FUNCTION STATS
# running_script: (empty)
# engines: { LUA: { libraries_count: 3, functions_count: 7 } }
```

---

## 七、迁移清单：从 Lua 到 Functions

| 步骤 | 动作 | 注意 |
|---|---|---|
| 1 | 盘点所有 `EVAL`/`DefaultRedisScript` | 按业务域归类 |
| 2 | 合并同类脚本为库 | 一域一库，避免巨型库 |
| 3 | 明确每个函数的 key 与 flags | 只读的标 `no-writes` |
| 4 | 统一返回码 | 整数优于字符串 |
| 5 | 改造客户端为 `FCALL` | 保留 `EVAL` 兜底一个版本 |
| 6 | 加监控与告警 | 调用量、错误率、P99 |
| 7 | 下线旧脚本 | `SCRIPT FLUSH` 前确认无调用 |

**不要一次性全迁**。建议先迁「读多写少、逻辑稳定」的函数（如限流、幂等），把扣库存这类强一致逻辑放在第二轮，配合双写对比。

---

## 八、踩坑记录

**坑 1：标了 `no-writes` 却写了数据。**
运行时报 `ERR Write commands are not allowed from read-only scripts`。排查时先看 flags。

**坑 2：函数里用了 `math.random()`。**
Lua 的随机数在 Redis 里是**确定性**的（相同 seed），多个副本执行会得到相同结果，看似没问题；但如果你把它当唯一 member，会覆盖。用客户端传入 UUID。

**坑 3：`FUNCTION LOAD` 没加 REPLACE，滚动发布时一半实例失败。**
启动脚本要幂等。

**坑 4：集群下只在单节点加载。**
`FCALL` 路由到没加载库的节点，报 `ERR Function not found`。用 `--cluster call` 全量加载。

**坑 5：函数执行 6s，Redis 进入 BUSY，所有业务超时。**
函数内不要做 O(N) 操作；`ZREMRANGEBYSCORE` 的范围要配合窗口大小控制基数。

**坑 6：误执行 `FUNCTION FLUSH`。**
这是不可逆操作。生产环境应通过 ACL 禁止普通账号执行 `FUNCTION FLUSH`/`FUNCTION RESTORE`。

---

## 九、面试追问

**Q1：Redis Functions 和 Lua 脚本的本质区别？**
Lua 脚本是「一次性的代码片段」，靠 SHA1 缓存；Functions 是「持久化的库」，有名字、版本、复制与持久化语义，客户端通过 `FCALL` 按名调用。Functions 解决的是脚本的**工程化治理**问题，不是性能问题。

**Q2：Functions 能保证原子性吗？能回滚吗？**
能保证「执行期间不被打断」的原子性（单线程），但**不能回滚**。函数中途报错，已执行的写命令保留。需要回滚语义只能靠业务补偿。

**Q3：`no-writes` flag 的作用？**
声明函数只读。Redis 会拒绝函数内的写命令，并允许 `FCALL_RO` 在副本上执行。它是**硬约束**，不是提示。

**Q4：集群模式下 Functions 有什么限制？**
① 库要在每个 master 加载；② 函数内所有 key 必须同 slot（用 hash tag）；③ `FCALL` 按第一个 key 路由；④ `allow-cross-slot-keys` 会破坏集群语义，不要用。

**Q5：函数执行超时了怎么办？**
超过 `lua-time-limit` 后 Redis 返回 BUSY。只读函数可以 `FUNCTION KILL`；**写函数不能被杀**，只能等或重启。所以函数必须短小，禁止大范围扫描。

**Q6：为什么不用 Redis 事务（MULTI/EXEC）替代？**
`MULTI/EXEC` 不能做条件判断（WATCH 是乐观锁，冲突要重试），也不支持「读-判断-写」的原子逻辑。Functions 可以在服务端做分支，这是核心差异。

---

## 总结

Redis Functions 的价值不在「更快」，而在「更可控」：

1. **可管理**：库名、版本、dump/restore，告别散落的脚本文本；
2. **可复制**：随主从复制和持久化传播，不再担心 `SCRIPT FLUSH`；
3. **可观测**：`FUNCTION LIST/STATS` 提供调用维度的指标；
4. **边界清晰**：flags 和 keyspec 把「能做什么」显式声明出来。

但它不是银弹：**不能回滚、不能跨 slot、不能长耗时**。把函数当成「Redis 内部的一段短小存储过程」，而不是「万能事务」，才是正确的用法。
