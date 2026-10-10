---
title: 【系统设计】高并发抢票系统架构设计：库存分桶、排队削峰与订单一致性
date: 2026-10-10 08:00:00
tags:
  - Java
  - 系统设计
  - 高并发
  - 架构
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】高并发抢票系统架构设计：库存分桶、排队削峰与订单一致性

## 面试官：如果让你设计一个"12306 抢票"系统，瞬时几十万 QPS，怎么保证不崩？

这是系统设计面试里最经典的"三高"题目之一。答不好的人通常有两个毛病：

1. 上来就说"加 Redis 缓存、加 MQ 削峰"，但说不出**为什么要削、削完之后一致性怎么保证**；
2. 完全忽略抢票业务的两个特殊约束——**库存必须严格不超卖**，以及**必须对用户公平**（不能谁网速快谁先买到）。

这篇文章我从业务特征出发，一层层把架构拆开讲清楚：流量怎么进来、库存怎么扣、订单怎么落、故障怎么兜底。全程配代码和表格，可以直接拿去面试复述。

---

## 一、先分析业务特征，别急着画架构图

抢票和普通电商下单的差别，决定了架构的取舍：

| 维度 | 普通电商下单 | 抢票 |
| --- | --- | --- |
| 流量形态 | 相对平稳，可预测 | **瞬时尖峰**，开售 1 秒涌入全量流量 |
| 读写比 | 读多写少 | 读极多、写在开售瞬间极度集中 |
| 库存粒度 | SKU 级 | **车次 × 日期 × 席别 × 区间** 多维度 |
| 一致性要求 | 允许短暂超卖后补偿 | **绝不允许超卖**（涉及实名制与运力） |
| 公平性 | 不关心 | **强要求**，需要排队/随机化 |
| 用户行为 | 少量正常请求 | 大量脚本、代抢、黄牛 |

两个关键结论：

- **读请求可以无限水平扩展，写请求必须被"排队"**——因为库存这个资源本身就是串行的。
- **峰值远大于均值**，所以架构设计的目标不是"扛住峰值"，而是"把峰值削成均值能承受的形状"。

```mermaid
graph LR
  A[瞬时百万请求] --> B[前端排队页/静态化]
  B --> C[接入层限流+验证码]
  C --> D[网关: 风控+限购+签名]
  D --> E[排队服务/令牌发放]
  E --> F[异步抢票队列 MQ]
  F --> G[库存服务: 分桶扣减]
  G --> H[订单服务: 落库]
  H --> I[支付/超时回滚]
```

---

## 二、接入层：把 90% 的无效流量挡在外面

### 1. 静态化 + CDN

车次信息、余票**展示**这类接口，本质上是"几乎只读"的。做法：

- 车次基础信息全量静态化，推到 CDN；
- 余票用"**近似值 + 秒级刷新**"口径，允许展示层有 1~2 秒延迟，前端提示"余票仅供参考，以提交结果为准"。

一句话：**展示层可以不准，扣减层必须精确。**

### 2. 多级限流

按维度分别限：

| 层级 | 手段 | 目的 |
| --- | --- | --- |
| 用户维度 | 设备指纹 + 账号维度频控 | 拦截脚本刷 |
| 接口维度 | 令牌桶 / 滑动窗口 | 保护后端 |
| 全局维度 | 集群限流（Sentinel 集群流控 / Redis + Lua） | 兜底 |
| 地域维度 | 边缘节点限流 | 就近拦截 |

Redis + Lua 做用户维度频控的经典实现：

```java
// KEYS[1] = 频控 key, ARGV[1] = 窗口秒数, ARGV[2] = 阈值
private static final String RATE_LIMIT_LUA =
    "local n = redis.call('INCR', KEYS[1]) " +
    "if n == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end " +
    "if n > tonumber(ARGV[2]) then return 0 else return 1 end";

public boolean allow(String uid, String api, int limit) {
    String key = "rl:" + api + ":" + uid;
    Long r = redis.execute(
        new DefaultRedisScript<>(RATE_LIMIT_LUA, Long.class),
        Collections.singletonList(key),
        String.valueOf(limit), "1");
    return r != null && r == 1L;
}
```

> 为什么用 Lua？因为 `INCR` 和 `EXPIRE` 必须是原子的。如果分两条命令发，第一次 INCR 之后进程崩溃，这个 key 会变成永不过期的计数器，用户被永久封禁。

### 3. 验证码与"答题"

验证码不是为了"证明你是人"，而是为了**给请求加一个几十到几百毫秒的延迟**。这个延迟本身就是最有效的削峰手段——它把"1 秒内 100 万并发"摊平成了"10 秒内 100 万请求"。

---

## 三、核心难题：库存怎么扣才不超卖、不热点

### 1. 为什么不能直接 `UPDATE ... WHERE stock > 0`

```sql
UPDATE ticket_stock SET stock = stock - 1
WHERE train_no = ? AND travel_date = ? AND seat_type = ? AND stock > 0;
```

这条 SQL 本身是幂等安全的（乐观锁思想，靠 `stock > 0` 兜底），单机场景能用。但在抢票场景里它有两个致命问题：

- **行锁热点**：同一个车次所有请求都锁同一行，InnoDB 行锁直接变成串行排队，TPS 上不去；
- **打满数据库连接**：瞬时几十万请求，连接池瞬间耗尽。

### 2. 方案：Redis 预扣减 + 库存分桶

**第一步：把库存搬到 Redis，用 Lua 保证原子扣减。**

```java
// KEYS[1] = 库存 key
// ARGV[1] = 本次扣减数量
private static final String DEDUCT_LUA =
    "local stock = tonumber(redis.call('GET', KEYS[1]) or '-1') " +
    "if stock < 0 then return -1 end " +          // 未预热
    "if stock < tonumber(ARGV[1]) then return 0 end " + // 库存不足
    "redis.call('DECRBY', KEYS[1], ARGV[1]) " +
    "return 1";

public DeductResult deduct(String key, int qty) {
    Long r = redis.execute(new DefaultRedisScript<>(DEDUCT_LUA, Long.class),
        Collections.singletonList(key), String.valueOf(qty));
    if (r == null || r == -1) return DeductResult.NOT_READY;
    return r == 1 ? DeductResult.SUCCESS : DeductResult.SOLD_OUT;
}
```

**第二步：分桶，解决单 key 热点。**

即便用 Lua，所有请求打同一个 key 仍然会集中在 Redis 的**同一个 slot、同一个节点**上。解决办法是把 1000 张票拆成 20 个桶，每个桶 50 张：

```java
private static final int BUCKET_COUNT = 20;

// KEY 形如 stock:train:G1234:2026-10-10:seat:0 ~ seat:19
public String pickBucket(String base) {
    // 随机 + 时间片轮转，避免所有请求都打到 0 号桶
    int idx = ThreadLocalRandom.current().nextInt(BUCKET_COUNT);
    return base + ":" + idx;
}

// 扣减失败（本桶耗尽）时，再遍历其余桶，纯内存操作，很快
public boolean deductWithFallback(String base, int qty) {
    int start = ThreadLocalRandom.current().nextInt(BUCKET_COUNT);
    for (int i = 0; i < BUCKET_COUNT; i++) {
        int idx = (start + i) % BUCKET_COUNT;
        if (deduct(base + ":" + idx, qty) == DeductResult.SUCCESS) {
            return true;
        }
    }
    return false;
}
```

分桶的收益非常直观：

| 方案 | 单 key QPS 上限 | 热点问题 | 实现复杂度 |
| --- | --- | --- | --- |
| 直接 MySQL 扣减 | 数百 | 严重行锁 | 低 |
| 单 key Redis Lua | 数万 | Redis 单节点热点 | 中 |
| **分桶 + Redis Lua** | **线性扩展** | **基本消除** | 中 |
| Redis Cluster 分桶 | 线性扩展 | 消除且可横向扩 | 中高 |

**第三步：异步落库，保证最终一致。**

Redis 扣减成功后，发送 MQ 消息，由订单服务消费落库：

```java
public void tryGrab(GrabRequest req) {
    // 1. 幂等校验（用户维度请求号去重）
    if (!idempotentService.firstTime(req.getRequestId())) {
        throw new BizException("重复提交");
    }
    // 2. Redis 分桶扣减
    if (!stockService.deductWithFallback(stockBase(req), 1)) {
        throw new BizException("已售罄");
    }
    // 3. 发消息（事务消息/本地消息表保证不丢）
    mqProducer.send("TICKET_ORDER_CREATE", req);
}
```

---

## 四、排队削峰：把"抢"变成"排"

这是 12306 真正的精髓：**用户看到的是"排队中"，系统内部其实是在按序放行**。

### 1. 排队令牌模型

1. 用户点击"提交订单" → 网关生成一个**排队号**（Redis `INCR` 全局自增），返回前端进入排队页；
2. 前端轮询排队进度（或长连接推送）；
3. 后台 worker 按排队号顺序**放行**到库存扣减环节，每次放行 N 个（N 根据后端水位动态调整）；
4. 放行成功的用户拿到"下单资格"（token，短 TTL），才允许真正提交订单。

```java
// 放行：每批放行的数量随后端水位动态调整
public void release() {
    int available = backendWaterLevel();     // 后端剩余处理能力
    int batch = Math.max(1, Math.min(available, MAX_BATCH));
    for (int i = 0; i < batch; i++) {
        String uid = redis.lpop("queue:waiting");
        if (uid == null) break;
        redis.setex("queue:pass:" + uid, 60, "1"); // 60 秒下单资格
    }
}
```

### 2. 排队 vs 直接扣减 的本质区别

| 维度 | 直接扣减 | 排队放行 |
| --- | --- | --- |
| 后端压力 | 等于请求量 | **可控水位** |
| 用户体验 | 秒回"已售罄" | 排队中，有心理预期 |
| 公平性 | 拼网速 | **先到先得** |
| 实现复杂度 | 低 | 高（需排队页 + 推送） |

> 面试话术：**排队的本质是用空间换时间，用"确定的等待"换"确定的不崩"。** 峰值请求量除以可承受的处理速率，就是排队时长；只要排队时长在用户容忍范围内，这个方案就是成立的。

---

## 五、订单一致性与超时回滚

库存预扣了，但用户可能不付款。所以必须有一个**超时回滚**机制。

### 1. 订单状态机

```
WAIT_PAY ──支付成功──> PAID ──出票──> ISSUED
    │
    └──15分钟超时/取消──> CANCELLED ──> 回滚库存
```

### 2. 延时消息实现超时回滚

```java
// RocketMQ 任意时间定时消息 / RabbitMQ 死信队列 / Redis ZSet 时间轮均可
mqProducer.sendDelay("TICKET_ORDER_TIMEOUT", orderId, 15 * 60 * 1000);

@MQListener("TICKET_ORDER_TIMEOUT")
public void onTimeout(String orderId) {
    // CAS 改状态，只有从 WAIT_PAY 才能改成 CANCELLED，天然幂等
    boolean ok = orderMapper.cancelIfWaitingPay(orderId);
    if (ok) {
        ticketStockService.giveBack(orderId);   // 回滚 Redis 分桶 + 后续落库
    }
}
```

```sql
UPDATE ticket_order
SET status = 'CANCELLED'
WHERE order_id = ? AND status = 'WAIT_PAY';
```

**关键：靠"状态机 + CAS 更新 + 唯一索引"保证幂等，不要靠"消息只投递一次"。**

### 3. 库存回滚也要幂等

用一张 `stock_rollback_log` 表，`order_id` 建唯一索引。回滚前先插入，插入冲突说明已经回滚过，直接返回。这是"**去重表**"的经典用法。

---

## 六、防刷与公平性

| 手段 | 说明 |
| --- | --- |
| 设备指纹 | 单设备并发/频率限制 |
| 实名 + 限购 | 一个证件同一车次限 N 张 |
| 行为风控 | 抢票脚本特征（固定 UA、无鼠标轨迹）接入风控模型 |
| 候补队列 | 售罄后转入候补，退票时按候补顺序分配，削弱"瞬时抢"的收益 |
| 随机化放票 | 分批次放票时间抖动，避免所有人卡在同一毫秒 |

**候补机制是公平性的终极大招**：它把"抢"变成了"排队等"，黄牛的脚本优势直接被抹平。这也是 12306 实际采用的方案。

---

## 七、降级预案

抢票系统的稳定性优先级排序：**下单 > 余票查询 > 推荐/广告**。

1. 余票查询失败 → 返回缓存快照，前端提示"数据可能有延迟"；
2. 风控服务超时 → **放行**（风控是"宁可漏过不可错杀"吗？不是，抢票场景建议降级为"仅放行低风险用户"）；
3. 支付链路拥堵 → 排队页限流；
4. Redis 分桶不可用 → 切到"数据库乐观锁直扣"的降级通道（容量骤降，但保证不超卖）。

---

## 八、面试常见追问

**Q1：Redis 挂了，库存不就丢了吗？**
答：Redis 只是"预扣减"，最终库存以 MySQL 为准。Redis 挂掉后可以从 DB 重建库存快照（重建期间用降级通道，数据库乐观锁直扣）。真正的风险是"Redis 扣减成功但 MQ 丢了"，这要靠**本地消息表 / 事务消息**兜底。

**Q2：分桶会不会导致某桶售罄但总量还有？**
答：会，所以要"扣减失败就遍历其余桶"。桶数量不宜过多（20~100 足够），否则遍历开销和库存碎片都会变大。桶的粒度可以是"每桶 20~50 张"。

**Q3：为什么不用消息队列直接削峰就行？**
答：MQ 削的是"处理速率"，削不了"库存争抢"。库存扣减必须在**用户同步等待的窗口内**给出确定结果（买到/没买到），否则无法返回用户。所以削峰和库存一致性是两个正交的问题，都要解决。

**Q4：秒杀和抢票的区别？**
答：秒杀是"少量商品 + 大量人"，核心是**防超卖 + 限购 + 削峰**；抢票是"分维度库存 + 实名 + 公平性硬要求"，还要处理**区间票复用**（同一座位不同区间可复用）这个真正的难点——这需要把库存拆到"站间段"维度，用位图或区间树管理。

**Q5：区间票复用怎么建模？**
答：把一趟车拆成若干站间段（如 A-B、B-C、C-D），每张票占用一段或连续多段。用 `BitSet`/`RoaringBitmap` 表示每个座位的占用区间，`A→D` 需要 B、C 两段都空闲。查询"能否买入"就变成位运算的与操作，天然适合 Redis Bitmap。

---

## 总结

抢票系统的设计主线就三句话：

1. **接入层做减法**——静态化、多级限流、验证码延迟，把无效流量挡在门外；
2. **扣减层做拆分**——Redis Lua 原子化 + 库存分桶消除热点 + 排队放行控制水位；
3. **一致性做兜底**——异步落库 + 状态机 CAS + 去重表 + 超时回滚，保证最终不超卖、不重复。

把这三条讲清楚，再补上防刷、降级、公平性的思考，这道系统设计题基本就是满分回答了。
