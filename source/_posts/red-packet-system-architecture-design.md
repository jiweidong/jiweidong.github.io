---
title: 【系统设计】高并发红包系统架构设计：拆分算法、并发扣减与资金一致性
date: 2026-10-06 08:05:00
tags:
  - Java
  - 系统设计
  - 高并发
  - Redis
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】高并发红包系统架构设计：拆分算法、并发扣减与资金一致性

## 面试官：设计一个抢红包系统，要求不超发、不重复领、金额精确

红包是面试里的"小而深"经典题。它看上去比秒杀简单，但把"拆分算法 + 并发扣减 + 资金一致性 + 超时退回"揉在一起，能问出十几层。

先把需求钉死：

- 一个群红包总金额 `M` 元，个数 `N`，每人只能领一次；
- 抢的瞬间会瞬时高并发（群里有人发消息，几百人同时点）；
- 金额**精确到分**，所有人领取之和必须恰好等于 `M`，不能多不能少；
- 未领完的红包 24 小时后自动退回。

---

## 一、先算容量，再谈方案

假设峰值 QPS = 10 万/s（红包瞬时爆发完全可能）。

- 写操作：每个用户抢红包一次，即 10 万次扣减/s；
- 读操作：查询红包剩余数量（列表页再引流过来更多）；
- 金额精度：**必须用整数（分）**，禁用 `double`/`float`。

结论：**MySQL 扛不住这个写峰值，必须用 Redis 做前置扣减，MySQL 做最终账务落库。**

---

## 二、核心难点：红包金额怎么拆

这是红包题最独特的考点。总金额和个数确定后，怎么随机分配？

### 1. 二倍均值法（最常用）

每次随机区间为 `[0.01, 剩余金额 / 剩余人数 × 2]`，这样能保证每个人期望相等，且最后一个不会超。

```java
/**
 * 二倍均值法拆分红包
 * @param totalFen 总金额（分）
 * @param count    个数
 * @return 每个红包金额（分），顺序随机
 */
public static List<Integer> splitByDoubleAverage(int totalFen, int count) {
    List<Integer> result = new ArrayList<>(count);
    int restFen = totalFen;
    int restCount = count;
    ThreadLocalRandom random = ThreadLocalRandom.current();
    for (int i = 0; i < count - 1; i++) {
        // 每人至少留 1 分
        int max = restFen / restCount * 2;
        int amount = random.nextInt(1, max + 1); // [1, max]
        // 兜底：保证后面每人还有 1 分
        amount = Math.min(amount, restFen - (restCount - 1));
        result.add(amount);
        restFen -= amount;
        restCount--;
    }
    result.add(restFen); // 最后一个拿走剩余
    return result;
}
```

> 坑点：`restFen / restCount * 2` 在只剩 1 人时等于 `2 * restFen`，必须用 `restFen - (restCount - 1)` 做上界收敛，否则会超发。

### 2. 线段切割法

把总金额想象成一条长 `M` 的线段，随机切 `N-1` 刀，得到 `N` 段。要让每段至少 1 分，切割点需落在 `[i, M-(N-i)]` 内，且切割点要去重。

```java
public static List<Integer> splitByCut(int totalFen, int count) {
    TreeSet<Integer> cuts = new TreeSet<>();
    ThreadLocalRandom r = ThreadLocalRandom.current();
    while (cuts.size() < count - 1) {
        int point = r.nextInt(1, totalFen); // 切点范围 [1, totalFen-1]
        cuts.add(point);
    }
    List<Integer> res = new ArrayList<>(count);
    int prev = 0;
    for (int c : cuts) { res.add(c - prev); prev = c; }
    res.add(totalFen - prev);
    return res;
}
```

| 算法 | 方差 | 是否保证不超发 | 特点 |
| --- | --- | --- | --- |
| 二倍均值法 | 较大 | 是 | 实现简单，最常用 |
| 线段切割法 | 较大且均匀 | 是 | 需去重，切点多时性能下降 |
| 固定金额（普通红包） | 0 | 是 | 均分，无需随机 |

### 3. 两种拆分时机

- **预拆分**：发包时就把 N 个金额算好，写入 Redis List。抢的时候直接 `LPOP`，天然原子，不超发。
- **实时拆**：抢的时候用 Lua 从剩余金额里算。省内存，但 Lua 里做随机 + 校验复杂，且金额分布容易被反推。

**工程上推荐预拆分**：一个 100 人红包只占 100 个 List 元素，内存开销可忽略，换来的是极致简单的原子性。

---

## 三、整体架构

```
Client ──► API 网关（限流/鉴权）
              │
              ├─► 红包服务（无状态，水平扩容）
              │        │
              │        ├─► Redis Cluster
              │        │      ├─ redpacket:amount:{id} → list（预拆金额）
              │        │      ├─ redpacket:stock:{id}  → 剩余个数
              │        │      └─ redpacket:user:{id}   → set（已领用户）
              │        │
              │        └─► MQ（异步落库 / 资金流水）
              │                 │
              │                 └─► MySQL（红包主表 + 领取明细表 + 资金流水）
              │
              └─► 定时任务：24h 过期退回未被领完的金额
```

### Redis 结构设计

| Key | 类型 | 说明 |
| --- | --- | --- |
| `rp:amount:{id}` | List | 预拆分金额（分），`LPOP` 取出 |
| `rp:user:{id}` | Set | 已领取 userId，做幂等 |
| `rp:meta:{id}` | Hash | 总金额、剩余个数、过期时间、状态 |
| `rp:lock:{id}:{uid}` | String | 可选，防止同一用户并发重复领 |

---

## 四、抢红包的原子性：Lua 一把梭

核心要求：**判重、扣库存、取金额** 三步必须原子。

```lua
-- KEYS[1] = rp:user:{id}   KEYS[2] = rp:amount:{id}
-- ARGV[1] = userId        ARGV[2] = 红包ID
-- 返回: -1 已领过; -2 已抢完; >0 领取金额(分)

-- 1) 判重（SADD 返回 1 表示首次加入）
if redis.call('SADD', KEYS[1], ARGV[1]) == 0 then
    return -1
end

-- 2) 取金额（LPOP 原子，天然不超发）
local amount = redis.call('LPOP', KEYS[2])
if not amount then
    -- 抢完，回滚判重标记，避免用户被"锁死"
    redis.call('SREM', KEYS[1], ARGV[1])
    return -2
end

return tonumber(amount)
```

Java 侧调用（Spring Data Redis）：

```java
private static final RedisScript<Long> GRAB_SCRIPT =
        RedisScript.of(LUA_SRC, Long.class);

public long grab(String packetId, long userId) {
    Long r = redis.execute(GRAB_SCRIPT,
            List.of("rp:user:" + packetId, "rp:amount:" + packetId),
            String.valueOf(userId));
    if (r == null) throw new IllegalStateException("redis error");
    if (r == -1) throw new BizException("已经领过啦");
    if (r == -2) throw new BizException("手慢了，红包已被抢完");
    return r; // 金额（分）
}
```

**为什么用 Lua 而不用 Redis 事务（MULTI/EXEC）？** 因为事务里无法根据前一个命令的结果做分支；`WATCH` 乐观锁在 10 万 QPS 下重试率极高。Lua 脚本在 Redis 单线程里执行，天然串行、天然原子。

---

## 五、落库与资金一致性

Redis 是"高性能缓存"，不能当账本。抢到之后必须异步落到 MySQL：

```java
@Transactional
public void persistGrab(GrabRecord record) {
    // 1) 幂等：insert ignore 或唯一索引兜底
    int rows = grabMapper.insertIgnore(record);
    if (rows == 0) return; // 已存在，直接返回
    // 2) 更新红包已领金额/个数
    packetMapper.increaseReceived(record.getPacketId(), record.getAmountFen());
}
```

表设计要点：

```sql
CREATE TABLE red_packet (
  id            BIGINT PRIMARY KEY,
  total_fen     BIGINT NOT NULL,
  count         INT    NOT NULL,
  received_fen  BIGINT NOT NULL DEFAULT 0,
  received_cnt  INT    NOT NULL DEFAULT 0,
  status        TINYINT NOT NULL DEFAULT 0, -- 0 进行中 1 已抢完 2 已过期退回
  expire_time   DATETIME NOT NULL,
  version       INT NOT NULL DEFAULT 0
) ENGINE=InnoDB;

CREATE TABLE red_packet_record (
  id         BIGINT PRIMARY KEY,
  packet_id  BIGINT NOT NULL,
  user_id    BIGINT NOT NULL,
  amount_fen BIGINT NOT NULL,
  create_time DATETIME NOT NULL,
  UNIQUE KEY uk_packet_user (packet_id, user_id)  -- 幂等唯一键
) ENGINE=InnoDB;
```

**唯一索引 `uk_packet_user` 是幂等的最后一道防线**：即使 Redis 判重被绕过（比如多机房、缓存丢失重放），数据库也不会重复入账。

### 对账

资金类系统必须对账。每天用定时任务比对：

- Redis 剩余金额 + MySQL 已领金额 == 总金额；
- 领取明细条数 == MySQL 已领个数；
- 与上游支付/账户流水核对。

---

## 六、过期退回

24 小时未领完的红包要退回发红包人。做法：

1. 发包时把 `packetId` 加入**延迟队列**（Redis ZSet 或 RocketMQ 延迟消息）；
2. 到期扫描：`status=进行中` 且有剩余 → 退回剩余金额，`status=已过期`；
3. 退回动作走资金服务，保证与领取用的是同一套账务。

```java
// 用 ZSet + 定时轮询做延迟队列（也可用 RocketMQ 延迟消息）
public void returnExpired() {
    Set<String> ids = redis.opsForZSet()
            .rangeByScore("rp:delay", 0, System.currentTimeMillis());
    for (String id : ids) {
        // 加分布式锁，防止多实例重复退回
        if (!lockHelper.tryLock("rp:return:" + id, 10, TimeUnit.SECONDS)) continue;
        try {
            doReturn(id);
            redis.opsForZSet().remove("rp:delay", id);
        } finally {
            lockHelper.unlock("rp:return:" + id);
        }
    }
}
```

---

## 七、防刷与限流

- **网关限流**：按 userId + 红包维度做令牌桶；
- **接口幂等**：同一用户同一红包的并发请求，用 `SADD`/唯一索引兜底；
- **风控**：同一设备、同一 IP 短时间大量领取直接拦截；
- **验证码/滑块**：大额红包可加人机校验。

---

## 八、面试追问连环炮

**Q1：预拆分会不会泄露金额？**
会。所以 Redis 上的金额只存分值和顺序，不对客户端暴露；客户端拿到的只有自己那一个金额。若担心运维人员窥探，可对金额列表做加密或改为"实时拆 + 加密随机种子"。

**Q2：Redis 挂了怎么办？**
Redis Cluster 主从 + 哨兵；同时用 MySQL 唯一索引兜底。极端情况下降级为"直接查 MySQL 抢"，性能下降但绝不超发/重复。

**Q3：为什么不用 MySQL 行锁扣减？**
`UPDATE ... WHERE stock > 0` 在 10 万 QPS 下会把行锁打成热点，连接池和响应时间都撑不住。Redis 单线程 + Lua 才是高并发扣减的正解。

**Q4：二倍均值法为什么能保证不超发？**
每次取值的上界是 `剩余金额 / 剩余人数 × 2`，数学上剩余金额始终 ≥ 剩余人数（每份至少 1 分），配合兜底 `Math.min` 就能保证最后一个恰好拿完。

**Q5：金额为什么必须用分？**
`double` 的 0.1+0.2≠0.3，资金系统用浮点等于埋雷。Java 里要么用 `long` 存储分，要么用 `BigDecimal`（但性能更差）。**落库统一存 `BIGINT` 分**，展示时再除 100。

---

## 九、总结

红包系统的本质是三个词：

1. **预拆分**——把随机性提前算好，抢的时候只剩原子 `LPOP`；
2. **Redis + Lua**——判重、扣减、取金额一体化，天然抗并发；
3. **唯一索引对账**——Redis 保性能，MySQL 保正确，双保险兜底资金。

把这三点讲清楚，再补上过期退回和防刷，这道题就算答满了。
