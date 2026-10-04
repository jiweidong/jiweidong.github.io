---
title: 【系统设计】订单系统架构设计：状态机、分库分表、超时取消与幂等设计
date: 2026-10-04 09:30:00
tags:
  - 系统设计
  - 高并发
  - 订单系统
  - 分库分表
categories:
  - 系统设计
  - 后端架构
author: 东哥
---

# 【系统设计】订单系统架构设计：状态机、分库分表、超时取消与幂等设计

## 面试官：设计一个电商订单系统，要支持下单、支付、超时关闭、退款和亿级数据

订单是电商的"合同"——它一旦生成就不能丢、不能错、不能重。所有高并发、一致性、幂等的问题，在订单系统里都会被放大。

这一篇按"下单链路 → 状态机 → 幂等 → 超时取消 → 分库分表 → 一致性"的顺序拆开讲。

---

## 一、下单链路

一笔正常下单要经历这些步骤：

```text
1. 参数校验（商品、地址、优惠券）
2. 价格试算（商品价 + 运费 - 优惠）
3. 预占库存（下单减库存 or 支付减库存）
4. 生成订单（订单主表 + 明细表）
5. 预占优惠券
6. 发起支付
7. 支付回调 → 扣减真实库存 → 更新订单状态
8. 履约（发货）→ 确认收货 → 完成
```

**关键决策：下单减库存还是支付减库存？**

| 时机 | 优点 | 缺点 |
| --- | --- | --- |
| 下单减库存 | 不会超卖，用户体验好 | 恶意占库存（下单不付款） |
| 支付减库存 | 无占库存 | 支付时可能没货，体验差 |

主流做法是**下单预占（Redis 扣减 + 订单维度锁定），支付确认，超时释放**——本质是"预占 + 超时回收"，兼顾不超卖和可回收。

---

## 二、订单状态机

订单状态必须用**状态机**管理，绝不能随意 `UPDATE status = x`：

```text
             ┌──────────────────────────────┐
             ▼                              │
  待支付 ──支付──▶ 已支付 ──发货──▶ 已发货 ──▶ 已完成
    │                │                 │
    │超时/取消        │退款             │退货
    ▼                ▼                 ▼
  已关闭          退款中 ──▶ 已退款   售后中
```

实现上，每次状态流转都必须**携带前置状态条件**：

```java
// 状态机 + 乐观锁，天然并发安全
public boolean transit(long orderId, OrderStatus from, OrderStatus to) {
    if (!OrderStatus.canTransit(from, to)) {
        throw new IllegalStateException("非法状态流转: " + from + " -> " + to);
    }
    int rows = orderMapper.transit(orderId, from, to);
    return rows > 0;  // 只允许 from 匹配的那一次成功
}
```

```sql
UPDATE `order`
SET status = #{to}, update_time = NOW()
WHERE id = #{orderId} AND status = #{from};
```

这样即使用户点击"支付"和"取消"并发到达，也只有一个能成功。**状态机是订单幂等的第一道防线**。

---

## 三、下单幂等：防重复提交

用户在弱网下连点提交，会产生两笔订单。三重防护：

1. **前端**：按钮置灰 + 防抖。
2. **Token 机制（推荐）**：

```java
// 进入结算页时发放 token
public String getOrderToken(long userId) {
    String token = UUID.randomUUID().toString();
    redis.setex("order:token:" + token, 1800, String.valueOf(userId));
    return token;
}

// 提交订单时消费 token（原子删除）
public void submit(OrderReq req) {
    String key = "order:token:" + req.getToken();
    Long removed = redis.delAndCheck(key); // Lua: 存在才删除
    if (removed == null) {
        throw new BizException("请勿重复提交");
    }
    // ... 继续下单
}
```

3. **DB 兜底**：`UNIQUE(user_id, out_trade_no)` 或 `UNIQUE(request_id)`，重复插入直接失败。

**注意**：`DEL` 要在事务/业务开始前执行（或使用 `GETDEL`），并且 token 要绑定 userId，防止串用。

---

## 四、订单号生成

订单号要求：全局唯一、趋势递增（利于 B+ 树写入）、不可猜测（防遍历）。

不要用纯自增 ID（会被竞对爬单量），推荐 **Snowflake 变体**：

```text
订单号 = 时间戳(41bit) | 机器/分片(10bit) | 序列号(12bit)
```

或者"日期 + 分库位 + 自增序列"，例如 `20261004108000001234`。

⚠️ 面试追问点：**分库分表后，订单号里要不要带分片信息？**

要。把 `user_id` 的分片位编码进订单号，可以让"按订单号查订单"无需二次路由：

```java
// 从订单号解析分片
int shard = (int) ((orderNo >>> 12) & 0x3FF);
```

否则按订单号查需要先查"订单号→用户"的映射表，多一次 IO。

---

## 五、超时取消：延迟任务方案对比

用户下单后 30 分钟未支付要自动关闭并释放库存。这是订单系统最经典的定时问题。

| 方案 | 精度 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 扫表（定时任务） | 分钟级 | 实现最简单 | 大表扫不动，延迟高 |
| 延迟队列（RocketMQ 定时消息） | 秒级 | 可靠、解耦 | 消息堆积、需处理重复 |
| 时间轮（Netty HashedWheel） | 秒级 | 内存高效 | 重启丢失，需持久化 |
| Redis ZSet | 秒级 | 简单、可查 | 大 ZSet 内存高 |
| RabbitMQ TTL + DLX | 秒级 | 成熟 | 队头阻塞（TTL 不能乱序） |

主流是 **RocketMQ 定时/延迟消息**，消费时先**校验订单状态**，只有仍是"待支付"才关闭：

```java
@RocketMQMessageListener(topic = "order-timeout", consumerGroup = "order-close")
public class OrderTimeoutConsumer implements RocketMQListener<Long> {
    public void onMessage(Long orderId) {
        Order order = orderMapper.selectById(orderId);
        if (order == null || order.getStatus() != OrderStatus.WAIT_PAY) {
            return; // 已支付或已取消，幂等忽略
        }
        orderService.close(orderId, CloseReason.TIMEOUT);
    }
}
```

**兜底**：延迟消息可能丢，所以再加一个**每 5 分钟扫表补偿**（按 `create_time` 索引扫描 30 分钟前的待支付订单）。延迟消息负责实时性，扫表负责兜底。

**释放库存要注意**：可能出现"释放库存"和"用户支付"并发。用状态机 CAS：先 `UPDATE order SET status=CLOSED WHERE id=? AND status=WAIT_PAY`，只有成功的那个才去回滚库存。否则会把已支付订单的库存也释放掉，导致超卖。

---

## 六、分库分表

订单表是典型的"数据量爆炸 + 生命周期长"的表，单表过千万就必须分片。

**分片键选择**：

| 分片键 | 优点 | 缺点 |
| --- | --- | --- |
| user_id | 用户查自己的订单（覆盖 90% 查询） | 运营按订单/时间查要跨片 |
| order_id | 单订单查询快 | 用户订单列表要跨片 |
| 时间 | 冷热分离容易 | 热点集中在新表 |

**最优解是 user_id 分片 + 异构索引/ES 支撑运营查询**：

```text
写：user_id % 1024 → order_{0..1023}
读（C 端）：带 user_id，单分片
读（运营/后台）：走 ES / 数仓（Canal 订阅 binlog 同步）
```

订单主表分片，**订单明细表、支付流水表同分片键**，保证同一订单的数据落在同一库，避免分布式事务。

**历史数据归档**：3 个月前的已完结订单移到历史库/冷存储，主库只保留热数据，索引小、写入快。

---

## 七、与库存/优惠券的最终一致

下单涉及订单、库存、优惠券、支付多个服务。不要用 XA，用**本地消息表 / 事务消息（最终一致）**：

```java
@Transactional
public void createOrder(OrderReq req) {
    orderMapper.insert(order);            // 1. 本地事务：写订单
    orderItemMapper.batchInsert(items);   // 2. 本地事务：写明细
    localMsgMapper.insert(msg);           // 3. 本地事务：写本地消息表
}

// 4. 后台任务扫描 status=0 的消息投递到 MQ，成功后置 1
// 5. 下游（库存/券）消费并处理，处理结果用自己的幂等键保证
```

**反查补偿**（可靠消息最终一致的核心）：下游处理成功后回执，上游把消息置为已完成；超时未回执则重投。这样即使消息中间件丢消息，也能通过"本地消息表 + 定时重投"补上。

---

## 八、订单查询与读写分离

订单系统是典型的**写少读多但读很重**：一笔订单会写下单、支付、发货、收货多次更新，但会被用户、客服、运营反复查询。

查询分为两类：

| 查询类型 | 特征 | 方案 |
| --- | --- | --- |
| C 端（我的订单） | 带 user_id，高频 | 分片直查 + 分页游标 |
| 后台（运营/客服） | 多维度组合，低频但重 | 走 ES / 数仓，禁止直查主库 |

**读多主从**：主库写入，从库承担 C 端查询。但要注意**主从延迟**：用户支付成功立刻查订单，如果走了从库可能读到旧状态。解法是"**写后短时间内的读走主库**"，比如支付成功后 2 秒内的查询强制走主库（可以基于订单的 `update_time` 判断）。

```java
// 支付成功后立即查询，强制主库，避免主从延迟导致的状态回退
public Order queryAfterPay(long orderId) {
    Order o = readOnlyTemplate.query(orderId);   // 默认从库
    if (o.getUpdateTime() != null
        && System.currentTimeMillis() - o.getUpdateTime().getTime() < 2000) {
        o = masterTemplate.query(orderId);       // 2 秒内改走主库
    }
    return o;
}
```

**热点订单**：大促期间单个爆款订单可能被反复查询（比如客服批量查询、用户频繁刷新），可以在应用层加**短 TTL 本地缓存**（1~3 秒），既缓解 DB 压力，又不会让状态明显滞后。

## 九、售后退款流程

售后是订单状态机的延伸，也是幂等最容易出问题的地方：

```text
已支付/已发货 ──申请退款──▶ 退款中 ──渠道退款成功──▶ 已退款
                              │
                              └──驳回──▶ 回到原状态
```

几个设计要点：

1. **退款单独立成表**，与订单是一对多（一个订单可以多次部分退款）；
2. 退款要以**支付流水号**为幂等键，防止重复退款给用户打两次钱；
3. 退款金额必须做**上限校验**：`已退款总额 + 本次退款 ≤ 实付金额`，用条件更新保证并发安全；
4. 退款要**异步调用支付渠道**（渠道可能超时），状态用"退款中"中间态承接口径不一致。

```sql
UPDATE refund_order
SET status = 2, refund_time = NOW()
WHERE id = #{id} AND status = 1;  -- 只有"发起中"才能变"成功"
```

⚠️ 面试高频追问：**渠道退款成功了，但我们回调没收到怎么办？** 答案是**主动查询 + 对账**：定时任务扫描"退款中"超过 N 分钟的退款单，主动查渠道状态，并以渠道结果为准修正本地状态；每日再与渠道对账一次。

## 面试官追问

**Q：订单支付回调重复（微信/支付宝会重试），怎么保证不重复入账？**

A：三层：
1. **回调幂等**：以 `out_trade_no`（商户订单号）为幂等键，`UNIQUE` 约束或 Redis `SETNX`；
2. **状态机**：只有 `WAIT_PAY → PAID` 的 CAS 能成功，重复回调拿到 0 行直接返回成功；
3. **对账**：每日与支付渠道对账，差异补单。

**Q：如何防止"支付成功但订单没更新"？**

A：这是典型的消息丢失场景。除了回调，还要加**主动查询**：定时任务扫描"待支付超过 1 分钟"的订单，主动查支付渠道状态。查询与回调都可能重复，所以两者都走同一套幂等逻辑。

**Q：用户订单列表分页，跨分片怎么排序？**

A：分片查询后内存归并（每片取 top N，再全局归并）。深分页用**游标分页**（`WHERE create_time < lastTime ORDER BY create_time DESC LIMIT 20`），避免 `OFFSET` 全片扫描。

---

## 总结

| 问题 | 方案 |
| --- | --- |
| 重复下单 | Token + 唯一索引双保险 |
| 状态混乱 | 状态机 + CAS 条件更新 |
| 超时关闭 | 延迟消息 + 扫表兜底 |
| 数据量 | user_id 分片 + ES 异构索引 + 历史归档 |
| 分布式一致 | 本地消息表 / 事务消息 + 对账 |
| 支付回调 | out_trade_no 幂等 + 主动查询补偿 |

订单系统的设计哲学是：**状态机管流转，幂等键管重复，最终一致管跨服务**。把这三件事做扎实，订单就不会出错。
