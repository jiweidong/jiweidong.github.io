---
title: 【Redis 实战】Redis 事务深度解析：MULTI/EXEC/WATCH 原理与 Lua 脚本对比
date: 2026-08-06 08:00:00
tags:
  - Java
  - Redis
  - 中间件
  - 面试
categories:
  - Java
  - Redis
author: 东哥
---

# 【Redis 实战】Redis 事务深度解析：MULTI/EXEC/WATCH 原理与 Lua 脚本对比

## 面试官：Redis 的事务和 MySQL 的事务有什么区别？Redis 事务能回滚吗？

Redis 事务是面试中**高频且容易答错**的考点。很多人的第一反应是「Redis 事务就是一组命令的批量执行」，但面试官往往会在后面连续追问：**「它能回滚吗？」「有隔离性吗？」「WATCH 是什么？」「为什么不建议用事务而用 Lua？」**

这篇文章把 Redis 事务从命令到原理、从对比到实战彻底讲透。

---

## 一、Redis 事务的核心命令

Redis 事务通过四个命令实现：`MULTI`、`EXEC`、`DISCARD`、`WATCH`。

| 命令 | 作用 |
|------|------|
| `MULTI` | 开启事务，标记事务开始 |
| `EXEC` | 执行事务队列中的所有命令 |
| `DISCARD` | 取消事务，清空命令队列 |
| `WATCH` | 监视一个或多个 key，事务执行前若被修改则事务被打断 |

### 基本用法

```bash
127.0.0.1:6379> MULTI
OK
127.0.0.1:6379> SET account:1001:balance 100
QUEUED
127.0.0.1:6379> DECRBY account:1001:balance 30
QUEUED
127.0.0.1:6379> EXEC
1) OK
2) (integer) 70
```

执行过程分三个阶段：

```text
1. 客户端发送 MULTI → 进入事务状态
2. 后续命令不立即执行，而是进入命令队列（返回 QUEUED）
3. 发送 EXEC → 一次性按顺序执行队列中的全部命令
```

**核心特征**：事务期间命令只是「排队」，不执行；`EXEC` 时才真正按顺序批量执行。这保证了**事务内命令的原子性（要么都执行，要么都不执行）**——在单线程 Redis 中，EXEC 期间的命令不会被其他客户端的命令插队。

---

## 二、Redis 事务的四大特性（ACID 逐项分析）

这是面试必考。用 ACID 框架对比 MySQL 事务：

| 特性 | Redis 事务 | 说明 |
|------|-----------|------|
| **原子性 Atomicity** | ✅ 部分保证 | 命令按顺序整体执行，不会被打断；但**不支持回滚**，执行中某条命令报错不影响其他命令继续执行 |
| **一致性 Consistency** | ✅ 基本保证 | 单线程顺序执行，事务前后数据状态保持一致 |
| **隔离性 Isolation** | ✅ 天然隔离 | Redis 单线程模型，事务执行期间不会被其他命令插入（WATCH 提供乐观锁级别的隔离保障） |
| **持久性 Durability** | ❌ 不保证 | 依赖 RDB/AOF 持久化配置；若事务执行后、持久化前宕机，数据可能丢失 |

### 关键点：Redis 事务「不支持回滚」

为什么 Redis 事务不支持回滚？官方给出的理由非常实在：

1. **命令入队阶段就会做语法/类型检查**，语法错误（如命令不存在、参数个数不对）在 `EXEC` 前就能发现并拒绝，事务根本不会执行。
2. 运行时错误（如对 string 执行 LPUSH）是**编程错误**，属于开发者的责任，回滚也救不了逻辑错误。
3. Redis 追求**简单和性能**，回滚机制会让实现复杂化，违背设计哲学。

```bash
127.0.0.1:6379> MULTI
OK
127.0.0.1:6379> SET key1 v1
QUEUED
127.0.0.1:6379> LPUSH key1 v2        # 运行时错误：key1 是 string
QUEUED
127.0.0.1:6379> SET key2 v2
QUEUED
127.0.0.1:6379> EXEC
1) OK
2) (error) WRONGTYPE Operation against a key holding the wrong kind of value
3) OK                    # key2 照常执行，没有回滚！
```

**结论**：Redis 事务的原子性 ≠ MySQL 的原子性。MySQL 事务强调「全成功或全失败（回滚）」，Redis 事务强调「**按顺序整体执行、不被插队**」，但执行过程中单条命令失败不影响后续命令。

---

## 三、WATCH：Redis 的乐观锁

WATCH 是 Redis 事务的「**检查再执行**」（check-and-set）机制，用来解决并发竞争问题。

### 典型场景：库存扣减

```bash
# 客户端 A：监视库存，开启事务扣减
127.0.0.1:6379> WATCH stock:iphone15
OK
127.0.0.1:6379> GET stock:iphone15
(integer) 10
127.0.0.1:6379> MULTI
OK
127.0.0.1:6379> DECR stock:iphone15
QUEUED

# 此时客户端 B 抢先修改了 stock:iphone15
# 客户端 A 执行 EXEC
127.0.0.1:6379> EXEC
(nil)            # 事务被放弃，返回 nil，因为监视的 key 被修改了
```

### WATCH 原理

```text
1. WATCH key 后，Redis 给该 key 打上「被监视」标记，并记录版本
2. EXEC 执行前，Redis 检查所有被监视的 key 是否在 WATCH 之后被修改过
3. 只要有一个被修改 → 事务直接放弃（返回 nil），不执行队列
4. 全部没被修改 → 正常执行事务，同时清除 WATCH 标记
```

**注意两个细节**：

- WATCH 是**乐观锁**：不加锁、不阻塞，靠「执行前校验版本」来保证一致性，失败就让客户端重试。
- **WATCH 必须在 MULTI 之前调用**；EXEC/DISCARD/UNWATCH 后 WATCH 自动失效。
- 被监视 key 被修改的判断基于「该 key 是否发生过写操作」，包括过期、淘汰导致的删除也算修改。

### 并发扣库存的经典完整实现（Java + Spring Data Redis）

```java
public boolean deductStock(String key, int amount) {
    while (true) {
        // 1. 监视库存 key
        sessionCallback.execute(ops -> {
            ops.watch(key);
            return null;
        });
        // 2. 读取当前库存
        Integer stock = (Integer) redisTemplate.opsForValue().get(key);
        if (stock == null || stock < amount) {
            return false; // 库存不足
        }
        // 3. 开启事务扣减
        try {
            List<Object> results = redisTemplate.execute(new SessionCallback<List<Object>>() {
                @Override
                public List<Object> execute(RedisOperations ops) {
                    ops.multi();
                    ops.opsForValue().decrement(key, amount);
                    return ops.exec();
                }
            });
            if (results == null || results.isEmpty()) {
                // EXEC 返回 null：说明 WATCH 的 key 被并发修改了，重试
                continue;
            }
            return true; // 扣减成功
        } finally {
            redisTemplate.unwatch();
        }
    }
}
```

**WATCH 的局限**：实现复杂（循环重试）、读改写三步分离、高并发下冲突重试率高。所以生产环境扣库存更推荐 Lua 脚本（见下文）。

---

## 四、Redis 事务 vs Lua 脚本：为什么推荐 Lua？

**这是面试的终极追问**，也是生产实践的关键决策点。

### Lua 脚本执行事务

```lua
-- stock_deduct.lua：原子扣库存（含库存检查）
local stock = redis.call('GET', KEYS[1])
if not stock then
    return -1
end
if tonumber(stock) < tonumber(ARGV[1]) then
    return -2
end
redis.call('DECRBY', KEYS[1], ARGV[1])
return 0
```

```java
// Java 调用
DefaultRedisScript<Long> script = new DefaultRedisScript<>(
    "local stock = redis.call('GET', KEYS[1]) ... ", Long.class);
Long result = redisTemplate.execute(script, 
    Collections.singletonList("stock:iphone15"), 1);
```

### 对比表

| 对比项 | Redis 事务（MULTI/EXEC） | Lua 脚本 |
|--------|--------------------------|----------|
| 原子性 | ✅ 整体执行 | ✅ 整体执行 |
| 回滚 | ❌ 不支持 | ❌ 不支持 |
| 条件逻辑（if/while） | ❌ 做不到，只能排队 | ✅ 完整编程能力 |
| 读改写一体 | ❌ 需要 WATCH + 重试 | ✅ 脚本内直接完成 |
| 复杂业务 | ❌ 命令队列是「死」的 | ✅ 逻辑封装在脚本中 |
| 网络开销 | 多条命令多次交互 | 一次 EVAL 调用 |
| 推荐度 | 简单批量场景 | **生产环境首选** |

**核心结论**：Lua 脚本是 Redis 事务的**超集和替代品**。Redis 官方也建议：**能用 Lua 解决的就用 Lua，事务只适合「无逻辑的批量命令」场景**。Lua 天然具备 WATCH 想实现的「读-判断-写」原子操作能力，还避免了乐观锁重试。

### 注意事项

- Lua 脚本默认以**写命令**方式传播（Redis 7+ 支持 `EVAL_RO`/函数只读传播），主从复制和集群模式下注意脚本的确定性（不要用随机函数如 `time()`，否则从节点复制结果不一致）。
- 脚本执行期间阻塞 Redis 主线程，**脚本要短小精悍**，避免长循环。
- 集群模式下所有 key 必须在同一个 slot（用 `{}` 哈希标签：`KEYS[1] = {stock}:iphone15`），否则报 `CROSSSLOT` 错误。

---

## 五、Redis 事务的实际应用与面试总结

### 什么时候用 Redis 事务？

1. **简单批量执行**：多个无依赖命令需要一次性下发，减少 RTT（但通常 Pipeline 更合适）。
2. **配合 WATCH 的 CAS 场景**：如秒杀库存、分布式计数（前提是并发不高）。
3. **保证顺序执行**：需要一组命令按固定顺序不被插队执行。

### 高频面试追问

1. **Redis 事务为什么不支持回滚？** → 入队阶段语法检查 + 运行时错误属编程错误 + 设计追求简单高性能。
2. **MULTI 和 Pipeline 的区别？** → MULTI 保证原子性（不被打断）；Pipeline 只是批量发送减少网络往返，**不保证原子性**。
3. **WATCH 是乐观锁还是悲观锁？** → 乐观锁，不阻塞，执行前校验版本，失败重试。
4. **Redis 事务与 Lua 如何选择？** → 无逻辑批量用事务；有判断逻辑、要原子读改写用 Lua。
5. **Redis 事务能保证持久性吗？** → 不能，依赖持久化配置；AOF 每次写盘（always）也只是执行后持久化，宕机窗口仍可能丢数据。
6. **Redis 事务隔离性如何？** → 单线程 + 顺序执行，天然隔离；但事务未 EXEC 前其他客户端看不到中间状态，也看不到 QUEUED 的命令效果。

### 一句话总结

**Redis 事务 = MULTI（排队） + EXEC（按序执行） + WATCH（乐观锁校验），原子但不回滚，隔离天然但持久靠配置；复杂事务场景请用 Lua 脚本替代。** 面试时能把这四层（命令层、ACID 层、WATCH 层、Lua 对比层）讲清楚，Redis 事务这个考点就满分了。
