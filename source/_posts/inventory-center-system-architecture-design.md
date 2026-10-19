---
title: 【系统设计】库存中心架构设计：多仓库存、预占释放、超卖防护与热点扣减
date: 2026-10-19 08:00:00
tags:
  - 系统设计
  - 高并发
  - 库存
  - 分布式
  - Redis
  - Java
categories:
  - 系统设计
author: 东哥
---

# 【系统设计】库存中心架构设计：多仓库存、预占释放、超卖防护与热点扣减

## 前言

在电商、票务、SaaS 资源配额这些系统里，**库存是最容易出现"看起来很简单、上线就出事"的模块**。

很多人对库存的理解停留在一条 SQL：

```sql
update stock set quantity = quantity - 1 where sku_id = ? and quantity > 0;
```

这条 SQL 在单库单表、几百 QPS 的场景下没问题。但只要出现下面任意一种情况，它就会崩：

- 单个爆款 SKU 每秒几千次扣减（热点行）
- 一次下单要锁多个 SKU，部分成功部分失败（事务边界）
- 下单后 30 分钟未支付要归还库存（延时释放）
- 多仓发货，需要按收货地址选仓（多仓库存）
- 大促期间要临时把库存按渠道切分（渠道库存）

本文从**领域模型**出发，把库存中心拆成「模型 → 一致性语义 → 核心链路 → 热点治理 → 对账补偿」五层，给出可以直接落地的设计，以及 Java 侧的关键代码。

---

## 一、先建模：库存不是一个数字，而是一组状态

初学者最容易犯的错误是把库存设计成 `stock` 单表的一个 `quantity` 字段。真实业务里，库存至少要拆成四个量：

| 字段 | 含义 | 谁在写 |
|---|---|---|
| `available` | 可售库存（能被新订单占用） | 扣减、释放、回补 |
| `locked` | 锁定库存（已下单未支付） | 预占、确认、释放 |
| `deducted` | 已扣减库存（已支付/已出库） | 确认扣减 |
| `in_transit` | 在途库存（采购/调拨中） | 入库单、调拨单 |

核心恒等式：

```
物理库存 physical = available + locked + deducted
可售库存 sellable   = available + in_transit(可提前售卖的部分) - 安全库存
```

### 1.1 库存的维度：SKU × 仓 × 渠道 × 批次

真实库存的主键不是 `sku_id`，而是：

```
(sku_id, warehouse_id, channel_id, batch_no)
```

- **仓库维度**：多仓发货、就近履约、区域限售
- **渠道维度**：天猫、抖音、自营小程序的库存要隔离，否则超卖
- **批次维度**：生鲜、医药要按批次先进先出（FIFO）和效期管理

工程上的折中：**明细表按多维存，汇总表按 (sku, warehouse) 存**，汇总表用于高频查询，明细表用于履约和审计。

### 1.2 库存流水（ledger）是唯一真相

库存余额是**推导出来的结果**，流水才是事实。每一笔变动写一条流水：

```
biz_type: ORDER_LOCK / ORDER_CONFIRM / ORDER_RELEASE / PURCHASE_IN / TRANSFER_OUT / CHECK_FIX
biz_no:   业务单号（幂等键）
delta:    +N / -N
before, after
```

这条设计带来三个好处：**可审计**、**可重放**、**可对账**。当余额和流水对不上时，能定位到具体哪一笔。

---

## 二、一致性语义：你要的是"强一致"还是"最终一致"

库存是典型的**读多写多、强竞争**资源。必须先明确业务能接受哪种语义：

| 方案 | 一致性 | 吞吐 | 适用场景 |
|---|---|---|---|
| 数据库行锁 `for update` | 强一致 | 低（百级 TPS） | 库存量小、SKU 分散 |
| 数据库乐观锁 `version` | 强一致（有重试） | 中 | 常规下单 |
| Redis 预扣 + DB 异步落账 | 最终一致 | 高（万级 TPS） | 大促、秒杀 |
| 分段库存（分桶） | 最终一致（桶内强一致） | 极高 | 单 SKU 热点 |
| 预占 + TCC 补偿 | 最终一致 | 中高 | 跨服务多资源 |

**关键认知**：库存不需要"全局强一致"，它需要的是**不超卖（不允许少卖可以接受）+ 最终对账平衡**。这个认知决定了后面所有设计。

> 面试可以这么答：库存的一致性目标是"**不超卖**"这一条不变量（invariant），而不是所有副本实时相等。所以可以用"预扣 + 异步落账 + 定时对账"的组合，把强一致的边界收缩到单个分桶内。

---

## 三、核心链路：预占 → 确认 → 释放

### 3.1 状态机

```
        ┌────────────┐  支付成功   ┌────────────┐
下单 ──▶ │  LOCKED    │ ─────────▶ │  DEDUCTED  │
        │ (锁定库存)  │            │ (已扣减)    │
        └─────┬──────┘            └────────────┘
              │ 超时未支付 / 取消
              ▼
        ┌────────────┐
        │  RELEASED  │  (库存回到 available)
        └────────────┘
```

三个动作对应三个接口，**每个接口都必须幂等**：

```java
public interface InventoryService {
    /** 预占：下单时调用，成功即锁定 */
    LockResult lock(LockCommand cmd);

    /** 确认：支付回调时调用，locked -> deducted */
    void confirm(String bizNo);

    /** 释放：取消/超时调用，locked -> available */
    void release(String bizNo, ReleaseReason reason);
}
```

### 3.2 幂等键设计

幂等键 = `biz_type + biz_no + sku_id + warehouse_id`。落库时建唯一索引：

```sql
CREATE TABLE inventory_ledger (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  biz_type VARCHAR(32) NOT NULL,
  biz_no VARCHAR(64) NOT NULL,
  sku_id BIGINT NOT NULL,
  warehouse_id BIGINT NOT NULL,
  delta INT NOT NULL,
  status TINYINT NOT NULL,     -- 1 处理中 2 成功 3 失败
  gmt_create DATETIME DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_biz (biz_type, biz_no, sku_id, warehouse_id)
);
```

插入冲突 = 已经处理过，直接返回上次结果（查询流水 status）。这是**最便宜也最可靠**的幂等实现，比分布式锁简单得多。

### 3.3 释放为什么要"延时"

订单超时未支付要归还库存，但不能在下单接口里同步 `sleep 30 分钟`。常见做法：

- **延时消息**（RocketMQ 延时级别 / Kafka + 时间轮）
- **定时扫表**（每 5 分钟扫 `status=LOCKED and expire_at < now()`）
- **Redis ZSet 延时队列**（score = 到期时间戳）

工业界通常是**延时消息为主 + 定时扫表兜底**。因为消息可能丢、可能重复，扫表保证最终一定能释放；而重复释放靠状态机 + 幂等键挡住。

---

## 四、超卖防护的四道防线

### 4.1 第一道：数据库乐观锁（兜底）

```sql
UPDATE inventory
SET available = available - #{qty}, version = version + 1
WHERE sku_id = #{skuId}
  AND warehouse_id = #{warehouseId}
  AND available >= #{qty}
  AND version = #{version};
```

影响行数为 0 就重试或失败。**注意**：`available >= qty` 这个条件必须和更新放在同一条 SQL 里，不能先查再判断——那是典型的 check-then-act 竞态。

### 4.2 第二道：Redis 预扣（削峰）

```lua
-- KEYS[1] = stock:{sku}:{warehouse}
-- ARGV[1] = qty
local stock = tonumber(redis.call('GET', KEYS[1]) or '-1')
if stock < 0 then return -1 end          -- 未初始化
if stock < tonumber(ARGV[1]) then return 0 end  -- 不足
redis.call('DECRBY', KEYS[1], ARGV[1])
return 1
```

Lua 脚本在 Redis 单线程内原子执行，天然防并发。要点：

1. **key 必须带 hash tag**（`stock:{sku123}:1`），保证同一 SKU 落在同一 slot，否则集群模式下 Lua 多 key 会报 CROSSSLOT。
2. **返回 -1 表示未预热**，要回源 DB 加载，不要当成"无库存"。
3. Redis 只是"闸门"，**DB 才是账本**。Redis 扣成功但 DB 扣失败时，要么回滚 Redis，要么记异常单异步补偿。

### 4.3 第三道：分段库存（解决单 key 热点）

单个爆款 SKU 即使在 Redis 里也是一个 hot key：所有请求打到同一个 slot、同一个线程。解决办法是把库存拆成 N 个桶：

```
stock:{sku123}:1:bucket:0  = 25
stock:{sku123}:1:bucket:1  = 25
...
stock:{sku123}:1:bucket:7  = 25
```

扣减时随机选一个桶，桶内不足就换桶（重试 2~3 次）：

```java
public boolean tryDeduct(long skuId, int warehouseId, int qty) {
    int buckets = 8;
    int start = ThreadLocalRandom.current().nextInt(buckets);
    for (int i = 0; i < buckets; i++) {
        int idx = (start + i) % buckets;
        String key = "stock:{" + skuId + "}:" + warehouseId + ":bucket:" + idx;
        Long r = redis.execute(DEDUCT_SCRIPT, Collections.singletonList(key),
                               String.valueOf(qty));
        if (r != null && r == 1L) {
            recordBucket(skuId, warehouseId, idx, qty); // 记录用于对账/回滚
            return true;
        }
    }
    return false;
}
```

桶的粒度是个权衡：桶越多并发越高，但**碎片化浪费**越严重（每个桶剩 1 件卖不掉就是少卖）。经验值：桶数 ≈ 峰值 QPS / 单 key 承载能力，且保证每桶库存 ≥ 峰值单笔购买量。

### 4.4 第四道：请求侧限流 + 排队

库存防护不能只靠下游。入口层要按「SKU 维度」限流：

- 网关按 `sku_id` 做令牌桶，超过阈值直接返回"活动太火爆"
- 大促用**答题/预约/摇号**把无效流量挡在门外
- 队列化：请求先入 MQ，消费端匀速扣减，前端展示"排队中"

> 一句话总结：**限流挡住 80% 的流量，缓存挡住 19%，数据库兜底 1%。**

---

## 五、多仓库存：选址与调拨

### 5.1 履约选仓策略

下单时要决定"从哪个仓发货"，常见策略：

| 策略 | 规则 | 优点 | 缺点 |
|---|---|---|---|
| 就近仓 | 按收货地址距离排序 | 时效好、运费低 | 可能拆单 |
| 库存优先 | 有货的仓优先 | 拆单少 | 时效差 |
| 成本优先 | 运费 + 仓内成本最低 | 成本低 | 时效不可控 |
| 分仓规则引擎 | 区域/渠道/品类规则 | 灵活 | 维护成本高 |

工程实现：**选仓服务输出候选仓列表 + 优先级**，库存中心按优先级依次尝试预占，失败则降级到下一个仓。这个"降级链"要显式记录下来，方便履约侧和客服排查。

### 5.2 调拨的库存语义

调拨单 `A 仓 → B 仓` 在途期间：

- A 仓：`available - N`，`deducted + N`（已出库）
- 在途：`in_transit + N`
- B 仓：收货后 `in_transit - N`，`available + N`

**在途库存不能直接卖**，除非业务允许"预售在途"。这一点必须在建模阶段就跟业务确认清楚，否则上线后会出现"卖了没货"。

### 5.3 库存同步：CDC 而不是双写

很多公司有多个系统都要读库存（商品详情、履约、财务）。如果每个系统各自双写，必然不一致。正确做法：

1. 库存中心是**唯一写入口**
2. 通过 **binlog CDC（Canal/Debezium）** 把流水投递到 Kafka
3. 下游各自消费、各自建读模型（CQRS）

这样库存中心只负责"写 + 强一致校验"，查询侧完全解耦，也不怕下游加系统。

---

## 六、对账与补偿：接受不一致，但要能发现

分布式系统里"不出现不一致"是幻想，**"能快速发现并修复不一致"才是工程能力**。

### 6.1 三层对账

| 层次 | 频率 | 内容 | 处理 |
|---|---|---|---|
| 实时对账 | 秒级 | Redis 余额 vs DB 余额 | 差异超阈值告警 |
| 准实时对账 | 分钟级 | DB 余额 vs 流水汇总 | 自动修复 |
| T+1 全量对账 | 每天 | 库存中心 vs WMS/财务 | 出差异单人工介入 |

### 6.2 差异自动修复的原则

```java
// 伪代码：以流水为准，重算余额
long ledgerSum = ledgerMapper.sumDelta(skuId, warehouseId);
long balance = inventoryMapper.getAvailable(skuId, warehouseId);
if (ledgerSum != balance) {
    alert.warn("stock mismatch", skuId, warehouseId, ledgerSum, balance);
    if (autoFixEnabled && Math.abs(ledgerSum - balance) < FIX_THRESHOLD) {
        inventoryMapper.forceSet(skuId, warehouseId, ledgerSum, "AUTO_FIX");
    }
}
```

**只在差异小于阈值时自动修复**，大额差异必须人工确认——防止程序 bug 把正确数据"修"成错误数据。

### 6.3 补偿的三种模式

| 模式 | 实现 | 适用 |
|---|---|---|
| 重试 | 指数退避 + 死信队列 | 下游临时故障 |
| 冲正 | 反向流水（+N 抵消 -N） | 业务失败需回滚 |
| 人工工单 | 差异单 + 审批 | 大额、复杂场景 |

---

## 七、Java 落地：一个可用的库存扣减骨架

```java
@Service
public class InventoryDeductService {

    private final StringRedisTemplate redis;
    private final InventoryMapper mapper;
    private final LedgerService ledger;

    private static final DefaultRedisScript<Long> SCRIPT = new DefaultRedisScript<>(
        "local s = tonumber(redis.call('GET', KEYS[1]) or '-1') " +
        "if s < 0 then return -1 end " +
        "if s < tonumber(ARGV[1]) then return 0 end " +
        "redis.call('DECRBY', KEYS[1], ARGV[1]) return 1", Long.class);

    @Transactional(rollbackFor = Exception.class)
    public boolean deduct(Long skuId, Integer warehouseId, int qty, String bizNo) {
        // 1. 幂等：流水唯一索引，冲突即已处理
        if (ledger.exists("ORDER_LOCK", bizNo, skuId, warehouseId)) {
            return ledger.isSuccess("ORDER_LOCK", bizNo, skuId, warehouseId);
        }
        // 2. 缓存闸门
        String key = "stock:{" + skuId + "}:" + warehouseId;
        Long r = redis.execute(SCRIPT, Collections.singletonList(key), String.valueOf(qty));
        if (r == null || r != 1L) {
            return false;   // -1 未预热 / 0 不足
        }
        try {
            // 3. DB 乐观锁兜底
            int rows = mapper.deduct(skuId, warehouseId, qty);
            if (rows == 0) {
                redis.opsForValue().increment(key, qty);  // 回滚缓存
                return false;
            }
            ledger.success("ORDER_LOCK", bizNo, skuId, warehouseId, -qty);
            return true;
        } catch (Exception e) {
            redis.opsForValue().increment(key, qty);      // 回滚缓存
            throw e;
        }
    }
}
```

要点说明：

- `@Transactional` 只覆盖 DB 部分，**Redis 不在事务里**，所以必须显式回滚
- 缓存回滚用 `increment(key, qty)` 而不是重设值，避免覆盖其他线程的扣减
- 幂等判断放在最前面，避免重复请求穿透到 DB

---

## 八、生产踩坑清单

1. **缓存预热缺失导致集体回源**：活动开始瞬间 Redis key 不存在，全部请求打到 DB。解决：活动前 10 分钟异步预热 + 布隆过滤器标记生效 SKU。
2. **`DECRBY` 扣成负数**：Lua 里忘了判断 `s < qty`，或用了 `INCRBY -qty` 绕过了检查。解决：所有扣减必须走同一个脚本。
3. **释放库存把别人锁的也放了**：释放时只按 `sku_id` 操作，没校验 `biz_no`。解决：释放必须带幂等键，且只能释放自己锁定的数量。
4. **分布式事务超时导致"扣了没记"**：DB 提交成功但 MQ 发送失败。解决：本地消息表（同库同事务写消息，再异步投递）。
5. **热点 SKU 打爆 Redis 单分片**：没做分桶或 hash tag 不对，导致跨 slot 报错。解决：`{sku}` 包裹 + 分桶。
6. **对账把正常在途算成差异**：对账口径没排除 `in_transit`。解决：对账前先对齐口径文档。

---

## 九、面试常见追问

**Q1：为什么不用分布式锁扣库存？**
分布式锁把并发变成串行，单 SKU 吞吐直接掉到锁的 QPS 上限（通常几千）。库存扣减是"减法"操作，天然适合用原子操作（Lua / `update ... where available >= n`）而不是互斥。锁适合"必须串行"的场景（如生成连续单号），不适合高并发计数。

**Q2：Redis 扣成功、DB 扣失败怎么办？**
两条路：① 同步回滚 Redis（本文代码）；② 不回滚，记一条"待补偿"记录，异步任务重试 DB，重试失败再回滚。大促时优先②，因为同步回滚会拉长 RT、放大雪崩风险。

**Q3：分段库存怎么保证不超卖？**
桶内是原子的（Lua / DB 行锁），跨桶不存在共享状态，所以"每桶不超卖" ⇒ "总量不超卖"。代价是碎片化导致的少卖，用"桶间调剂"任务定期把小桶余量合并。

**Q4：库存和订单的一致性怎么保证？**
订单创建 → 库存预占（同步，失败则订单失败）→ 支付成功 → 库存确认（异步，可重试）→ 超时未付 → 库存释放（延时消息 + 扫表兜底）。核心是**每一步都有幂等键 + 状态机**，任何一步失败都能重放。

**Q5：大促前你会做哪些准备？**
容量评估（峰值 QPS × 单请求耗时）→ 热点 SKU 识别与分桶 → 缓存预热 → 限流阈值设定 → 降级预案（关闭非核心校验）→ 压测（全链路）→ 对账任务提前跑通 → 值班与回滚方案。

---

## 十、总结

库存中心的难点从来不是"减一"，而是：

1. **建模**：把 available/locked/deducted/in_transit 拆清楚，流水为真相
2. **语义**：明确"不超卖"是唯一硬不变量，其余允许最终一致
3. **分层防护**：限流 → 缓存 → 分桶 → DB 乐观锁，四道防线各司其职
4. **可观测**：三层对账 + 差异告警，接受不一致但必须能发现
5. **幂等**：所有写操作都有业务幂等键，唯一索引是最便宜的分布式锁

把这五点讲清楚，无论是做系统设计还是面试，都已经超过大多数候选人。
