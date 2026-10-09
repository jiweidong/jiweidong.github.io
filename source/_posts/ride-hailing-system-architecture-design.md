---
title: 【系统设计】网约车（打车）系统架构设计：LBS 派单、行程状态机与计费结算全解析
date: 2026-10-09 08:10:00
tags:
  - Java
  - 系统设计
  - 微服务
  - 架构
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】网约车（打车）系统架构设计：LBS 派单、行程状态机与计费结算全解析

## 面试官：让你设计一个网约车系统，你会怎么拆？

网约车（打车）是系统设计面试里的"高阶题"——它同时考验 **LBS 地理索引、实时匹配、状态机、计费与结算、高并发地标** 五个方向，比秒杀、订单更难糊弄。

面试官通常会层层递进：

1. 乘客发单，司机怎么找？为什么不用 MySQL 查距离？
2. 峰值几十万司机同时上报位置，位置数据怎么存？
3. 派单怎么保证公平和效率？抢单和派单有什么区别？
4. 行程状态怎么管？司机掉线、乘客取消怎么办？
5. 计费怎么算不出错？结算怎么和司机对账？

下面逐层拆。

## 一、整体架构与领域拆分

先做限界上下文（领域）划分：

| 领域 | 职责 | 核心存储 |
| --- | --- | --- |
| 乘客端（Passenger） | 发单、取消、评价、支付 | MySQL |
| 司机端（Driver） | 出车/收车、抢单、状态上报 | MySQL + Redis |
| 位置服务（Location） | 轨迹上报、附近司机查询 | Redis GEO / 自建 LBS |
| 派单引擎（Dispatch） | 匹配、派单、超时重派 | Redis + 规则引擎 |
| 行程服务（Trip） | 行程状态机、轨迹、时长里程 | MySQL + Kafka |
| 计价服务（Pricing） | 预估价、实时计价、动态调价 | 规则引擎 + Redis |
| 结算服务（Settlement） | 订单结算、司机钱包、对账 | MySQL + 账务表 |

整体链路：

```
乘客 App ──发单──▶ 订单服务 ──▶ 派单引擎 ──▶ 司机 App
                                    │
司机 App ──位置上报(3~5s)──▶ 位置服务(Redis GEO)
                                    │
行程中 ──轨迹/计价──▶ 行程服务 ──Kafka──▶ 计价/风控/结算
```

## 二、LBS：为什么不直接查数据库

最 naive 的方案：

```sql
-- 错误示范
SELECT * FROM driver_location
WHERE (lat-30.28)*(lat-30.28) + (lng-120.15)*(lng-120.15) < 0.01;
```

问题：

1. 全表扫描，几万个司机也扛不住 QPS。
2. 频繁 UPDATE 司机位置，MySQL 行锁 + 索引维护成本极高。
3. 距离公式还得转成米，无法走索引。

### 2.1 方案选型对比

| 方案 | 原理 | 优点 | 缺点 |
| --- | --- | --- | --- |
| MySQL + 空间索引 | R-Tree / SPATIAL | 功能全、支持多边形 | 写性能差，不适合高频更新 |
| **GeoHash 分桶** | 把 2D 编码成 1D 前缀 | ZSet 范围查询简单 | 边界问题需查 8 邻域 |
| **Redis GEO** | ZSet + GeoHash | O(log N) 附近查询、写入快 | 精度受限于 GeoHash 位数 |
| 自建网格（Uber H3） | 六边形网格分层 | 负载均衡、层次聚合 | 实现复杂 |
| Elasticsearch geo_point | Lucene 空间索引 | 支持复杂查询 | 延迟相对高，不适合实时派单 |

实战中主流组合是：**Redis GEO 做实时附近查询，ES/离线库做轨迹与历史分析**。

### 2.2 Redis GEO 实战

```bash
# 司机上报位置（GEOADD，O(log N)）
GEOADD driver:geo:city:hangzhou 120.153576 30.287459 "driver_1001"

# 找 3km 内最近 20 个司机（GEOSEARCH）
GEOSEARCH driver:geo:city:hangzhou FROMMEMBER driver_1001 BYRADIUS 3 km ASC COUNT 20

# 查询某司机位置
GEOPOS driver:geo:city:hangzhou "driver_1001"
```

Java 侧：

```java
@Service
@RequiredArgsConstructor
public class DriverLocationService {

    private final StringRedisTemplate redis;
    private static final String KEY = "driver:geo:city:hangzhou";

    /** 司机上报位置 */
    public void report(Long driverId, double lng, double lat) {
        redis.opsForGeo().add(KEY, new Point(lng, lat), "driver_" + driverId);
        // 同时写入心跳 TTL，用于判断司机是否在线
        redis.opsForValue().set("driver:online:" + driverId, "1", Duration.ofSeconds(30));
    }

    /** 附近司机 */
    public List<Long> nearby(double lng, double lat, double radiusKm, int limit) {
        Circle circle = new Circle(new Point(lng, lat),
                new Distance(radiusKm, Metrics.KILOMETERS));
        GeoResults<RedisGeoCommands.GeoLocation<String>> results =
                redis.opsForGeo().search(KEY,
                        GeoReference.fromCircle(circle),
                        GeoSearchCommandArgs.newGeoSearchArgs().includeDistance().sortAscending().limit(limit));
        return results.getContent().stream()
                .map(r -> Long.parseLong(r.getContent().getName().replace("driver_", "")))
                .collect(Collectors.toList());
    }
}
```

### 2.3 关键工程细节

**（1）分片（Sharding）**

司机量大时，Redis GEO 单 key 会变成热点。做法是按**城市 / 网格 / 区域**分片：

```
driver:geo:{city}:{gridId}
```

派单时只查乘客所在网格 + 8 邻域网格，避免"全城扫描"。

**（2）边界问题**

GeoHash 是矩形网格，附近查询必须查**9 个格子**（中心 + 8 邻域），否则会漏掉就在一墙之隔的司机。

**（3）位置过期**

司机掉线后位置不能一直留着。用 `driver:online:*` 的 TTL 心跳来过滤：

$$
\text{司机在线} \iff \text{心跳 key 存在} \land (\text{now} - \text{lastReport}) < 30s
$$

**（4）删除时机**

司机收车 / 长期无心跳要 `ZREM` 从 GEO 里摘除，否则"僵尸司机"会污染匹配结果。

## 三、派单引擎：抢单 vs 派单

| 模式 | 机制 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 抢单 | 广播给一批司机，先到先得 | 实现简单 | 不公平、易被外挂刷、偏远地区没人抢 |
| **派单** | 系统按策略指定司机 | 公平可控、可优化效率 | 需要司乘双方接受度模型 |
| 混合 | 近距离单抢单，远距离单派单 | 平衡 | 规则复杂 |

主流平台以**派单**为主。派单核心是"打分 + 并发抢占"。

### 3.1 派单打分模型

```java
public class DispatchScore {

    /** 综合得分：越大越好 */
    public static double score(Driver driver, Order order, DispatchContext ctx) {
        double distance = distanceCost(driver, order);       // 距离成本，越小越好
        double idle = idleTimeFactor(driver, ctx);           // 空闲时长，越久越优先
        double acceptRate = driver.getAcceptRate();          // 历史接单率
        double serviceScore = driver.getServiceScore();      // 服务分
        double direction = directionMatch(driver, order);    // 是否顺路

        return w1 * (1 / (distance + 0.1))
             + w2 * idle
             + w3 * acceptRate
             + w4 * serviceScore
             + w5 * direction;
    }
}
```

权重 `w1..w5` 通常由 **AB 实验 + 强化学习** 动态调整，不写死在代码里，而是放在规则引擎/配置中心。

### 3.2 派单的并发问题：一个订单只能派给一个司机

这是分布式系统中经典的**互斥**问题。三种做法：

**做法 A：Redis 原子抢占**

```java
public boolean tryDispatch(Long orderId, Long driverId) {
    Boolean ok = redis.opsForValue().setIfAbsent(
            "dispatch:lock:" + orderId, String.valueOf(driverId),
            Duration.ofSeconds(15));
    return Boolean.TRUE.equals(ok);
}
```

**做法 B：数据库乐观锁 / 唯一索引**

```sql
-- 订单表加唯一约束 CREATE UNIQUE INDEX uk_order ON trip_dispatch(order_id)
UPDATE trip SET driver_id = ?, status = 'DISPATCHED'
WHERE id = ? AND status = 'WAITING' AND driver_id IS NULL;
-- 受影响行数 = 1 才算抢到
```

**做法 C：Lua 脚本保证"判断 + 抢占"原子**

```lua
-- KEYS[1]=order_dispatch_key ARGV[1]=driverId ARGV[2]=ttl
if redis.call('EXISTS', KEYS[1]) == 1 then
    return 0
end
redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2])
return 1
```

无论哪种，都必须满足 **CP（一致性）** 而不是 **AP**——同一订单绝不能派给两个司机（否则会出现两个司机都去接同一个乘客的严重体验和安全问题）。

### 3.3 派单超时与重派

司机接了单但不响应（其实新司机会有"接单确认"按钮），或长时间未接单，需要重派：

```
派单 → 等待确认（15s）
        ├─ 接受 → 生成行程
        ├─ 拒绝 → 从候选队列取下一位，继续派
        └─ 超时 → 重新打分派给下一位
```

用**延时队列**（RocketMQ 延迟消息 / Redis ZSet / 时间轮）实现超时触发：

```java
// RocketMQ 延时消息（简化）
rocketMQTemplate.syncSend("dispatch-timeout-topic",
        MessageBuilder.withPayload(new DispatchTimeout(orderId, driverId)).build(),
        3000, 5 /* 延迟级别 */);
```

消费超时消息时，先判断订单是否已派单成功——**幂等 + 状态判断**是这里的关键。

## 四、行程状态机

行程状态必须**严格受控**，否则会出现"已完成还能取消"这种资损/纠纷。

状态定义：

| 状态 | 说明 | 允许的下一步 |
| --- | --- | --- |
| CREATED | 已创建待派单 | DISPATCHING / CANCELED |
| DISPATCHING | 派单中 | ACCEPTED / CANCELED |
| ACCEPTED | 司机已接单 | ARRIVED / CANCELED |
| ARRIVED | 司机到达上车点 | STARTED / CANCELED |
| STARTED | 行程中 | COMPLETED / ABNORMAL |
| COMPLETED | 已完成 | 待支付 / 已支付 |
| CANCELED | 已取消 | — |
| ABNORMAL | 异常结束 | 人工处理 |

实现方式：**状态机 + 乐观锁**。

```java
@Transactional
public void transit(Long tripId, TripStatus from, TripStatus to, String operator) {
    int rows = tripMapper.updateStatus(tripId, from, to);
    if (rows == 0) {
        throw new IllegalStateException(
            "行程状态流转失败，可能已被并发修改: " + tripId + " " + from + "->" + to);
    }
    // 记录状态流转流水，便于对账与追溯
    tripStatusLogMapper.insert(new TripStatusLog(tripId, from, to, operator, now()));
    // 发领域事件，驱动下游（计价、通知、结算）
    eventPublisher.publishEvent(new TripStatusChangedEvent(tripId, from, to));
}
```

```sql
UPDATE trip SET status = #{to}, update_time = NOW()
WHERE id = #{id} AND status = #{from};
```

**核心思想**：状态流转不是"直接改字段"，而是"满足前置状态才能改"，用 `WHERE status = from` 实现 CAS。

### 4.1 异常场景处理

| 场景 | 处理 |
| --- | --- |
| 司机接单后掉线 | 心跳超时 → 触发重派 / 客服介入 |
| 乘客取消 | 按时间点差异化计费（免费/收违约金） |
| 行程中网络中断 | 客户端本地缓存轨迹，恢复后补传 |
| 司机误点到达 | 允许状态回退（需审计日志） |
| 支付超时 | 订单挂起 + 催付 + 影响信用分 |

## 五、计费与结算

计费是"绝不能错"的部分，必须**可复现、可审计、可对账**。

### 5.1 计价模型

```
总价 = 起步价
     + 里程费 × 里程(km)
     + 时长费 × 时长(min)
     + 远途费(超过 X km 的部分加价)
     + 夜间费 / 恶劣天气溢价
     + 动态调价系数(供需比)
     - 优惠券 / 折扣
```

实现上通常抽象成 **计费规则链**：

```java
public interface FareRule {
    BigDecimal apply(FareContext ctx, BigDecimal current);
}

// 组合执行：起步价 → 里程费 → 时长费 → 动态溢价 → 优惠
BigDecimal fare = rules.stream()
        .reduce(BigDecimal.ZERO, (acc, rule) -> rule.apply(ctx, acc), BigDecimal::add);
```

**所有金额用 `BigDecimal`（或更好用整数"分"存储）**，绝不能用 `double`。

### 5.2 结算与对账

结算的本质是**账务记账**，遵循复式记账思想：

| 账户 | 借（+) | 贷（−) |
| --- | --- | --- |
| 乘客应付 | — | 100 |
| 平台收入 | 20 | — |
| 司机应收 | 80 | — |

每一笔都要有唯一的**业务流水号**，保证幂等：

```java
// 幂等：同一 tripId 只结算一次
@Transactional
public void settle(Long tripId) {
    String bizNo = "SETTLE_" + tripId;
    if (accountFlowMapper.existsByBizNo(bizNo)) {
        return;                       // 已结算，幂等返回
    }
    // 写司机钱包、平台收入，写流水
    accountFlowMapper.insert(new AccountFlow(bizNo, tripId, amount, ...));
}
```

日终对账：把**平台账单**、**支付渠道账单**、**司机端流水**三方比对，差异走差错处理流程（挂账、人工核销、自动补单）。

## 六、高并发与稳定性

| 问题 | 方案 |
| --- | --- |
| 位置上报 QPS 高 | Redis Cluster 分片、批量上报、客户端节流（3~5s） |
| 派单风暴 | 异步化 + 队列削峰 + 按区域分片派单 |
| 城市级故障 | 多机房单元化（按城市路由） |
| 计价规则变更 | 规则引擎 + 灰度 + 版本化，支持回滚 |
| 司乘消息推送 | 长连接网关 + Kafka 扇出 |
| 数据一致性 | 本地消息表 / 事务消息 / 对账兜底 |

**单元化（Set）设计**是网约车的关键：按城市/区域切分，一个单元的故障不影响其他城市，且"人车位置"数据天然按城市聚集，符合就近路由。

## 七、面试追问

**Q1：为什么不用 MySQL 存司机位置？**

因为位置是**高频写 + 低价值 + 短生命周期**的数据，写入量是订单的几十倍，且查询模式是"附近"（范围查询 + 排序），MySQL 的 B+ 树对这种场景既不高效也不经济。Redis GEO 写入 O(log N)、查询 O(log N + M)，且天然支持过期与分数排序。

**Q2：GeoHash 精度怎么选？**

GeoHash 每多 1 位，精度约缩小到 1/32。常见选择：

| 位数 | 精度 |
| --- | --- |
| 5 | ~4.9km |
| 6 | ~1.2km |
| 7 | ~153m |
| 8 | ~38m |

派单查 3km 通常用 5~6 位，配合 9 邻域查询。

**Q3：派单一定要用分布式锁吗？**

不一定，但一定要有**互斥 + 幂等**。如果候选司机列表本身是串行消费的（每个订单只由一个消费者处理），状态机 + 乐观锁就够了；只有在多节点并发派同一订单时才需要分布式锁。核心是"同一订单同一时刻只有一个赢家"。

**Q4：动态调价怎么实现又不被骂？**

规则引擎 + 供需模型（区域级"需求/供给"比值），设置**封顶倍数**、**透明公示**、**异常检测**（防恶意抬价），并对极端情况做人工兜底。技术上不难，难的是产品与合规设计。

**Q5：行程中的轨迹怎么存？**

高频点存时序库/对象存储（按时段归档），关键节点（上车、到达、下车）存 MySQL。查询时按需拉取并做抽稀。直接全量进 MySQL 会爆炸。

## 八、小结

- **LBS 用 Redis GEO + 分片 + 9 邻域查询**，位置数据不要落 MySQL。
- **派单是互斥问题**：Redis 抢占 / 乐观锁 / Lua 原子操作，保证一单只派一人。
- **行程用状态机 + CAS 流转**，所有变更留流水，便于审计与对账。
- **计费用规则链 + BigDecimal（或整数分）**，结算用复式记账 + 幂等流水 + 三方对账。
- **稳定性靠单元化 + 异步削峰 + 本地消息表**，把"人车位置"按城市就近路由。

网约车的难点不在单个技术，而在于**地理、状态、资金三条链路必须在高并发下同时正确**。能把这三条讲清楚，这题就稳了。
