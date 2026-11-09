---
title: 【分布式实战】事务性发件箱（Transactional Outbox）深度实战：双写不一致、SKIP LOCKED 投递与幂等消费
date: 2026-11-09 08:00:00
tags:
  - 分布式
  - 微服务
  - Outbox
  - MySQL
  - Kafka
  - Java
categories:
  - 系统设计
author: 东哥
---

# 【分布式实战】事务性发件箱（Transactional Outbox）深度实战

## 前言：一个"偶发"的订单状态不一致

订单服务下单成功后发一条 Kafka 消息通知库存服务扣减。代码长这样：

```java
@Transactional
public void createOrder(Order order) {
    orderMapper.insert(order);          // 1. 写库
    kafkaTemplate.send("order-created", order.getId());  // 2. 发消息
}
```

上线三个月，出现了 17 笔"订单已创建但库存没扣"的脏数据。排查日志发现两种失败：

- **消息发送失败**（Broker 抖动 / 网络超时），异常抛出 → 事务回滚。这种情况是对的。
- **消息发送成功但事务提交失败**（数据库主从切换、连接被 kill、`@Transactional` 外层还有事务），或者**消息发出后进程被 Kill -9** → 消息已投递，数据不存在。这就是不一致的来源。

很多人第一反应是"加重试"。重试解决不了本质问题：**数据库事务和消息中间件是两个独立的事务边界，你无法让它们原子提交**。这正是分布式事务的经典难题。

两阶段提交（2PC/XA）能解决，但代价是性能腰斩 + 协调者单点 + 长事务锁行；Seata AT 能解决，但要引入额外组件和维护成本。

而 **Transactional Outbox（事务性发件箱）** 用一个非常朴素的思路绕开了这个问题：**既然两个事务无法原子，那就把它们变成一个事务**——把"要发的消息"当成一条业务数据，写进同一个数据库的同一张表。

本文讲透工程实现：表怎么设计、轮询投递和 CDC 投递怎么选、`SKIP LOCKED` 为什么是多实例轮询的关键、如何做到 at-least-once 下的幂等与顺序，以及我们在生产上踩过的六个坑。

## 一、双写不一致的三个窗口

先把问题定义清楚。任何"写库 + 发消息"的组合，都存在以下窗口：

| 窗口 | 场景 | 结果 |
|---|---|---|
| W1 | 写库成功、发消息抛异常 | 事务回滚，一致（但会误伤：消息可能已送达） |
| W2 | 发消息成功、事务提交失败 | **消息多发**，下游按不存在的订单操作 |
| W3 | 发消息成功、进程崩溃（未提交） | **消息多发**，同上 |
| W4 | 写库提交成功、发消息前进程崩溃 | **消息漏发**，下游永远不知道 |

W1 靠异常能兜住，W2/W3/W4 兜不住。其中 W4 最隐蔽——它要求"发消息"必须在提交之后，但只要放在提交之后，就有崩溃窗口。

**结论：在"两个系统各自独立提交"的模型下，这个问题无解。** 唯一出路是把消息的持久化和业务数据的持久化放进同一个本地事务。

## 二、Outbox 的核心思想

```
┌──────────────────────────────────────────┐
│         一个本地数据库事务                  │
│  ┌────────────┐    ┌──────────────────┐  │
│  │ insert     │    │ insert outbox    │  │
│  │ order      │    │ (event payload)  │  │
│  └────────────┘    └──────────────────┘  │
└──────────────────────────────────────────┘
              ↓ 提交成功（原子）
   ┌─────────────────────────────────────┐
   │ 独立的中继进程/线程 (Relay)           │
   │ 读 outbox → 投递 MQ/HTTP → 标记已发   │
   └─────────────────────────────────────┘
```

关键性质：

1. **原子性**：业务数据和事件在同一个 InnoDB 事务里，要么都成功要么都失败。InnoDB 的 redo log 保证了这一点。
2. **至少一次（at-least-once）**：Relay 可能在"发送成功、标记未完成"时崩溃，重启后会重发。**这是设计上接受的，不是 bug。**
3. **解耦投递通道**：Relay 可以是轮询线程，也可以是 binlog 订阅（CDC），业务代码不关心。
4. **可审计**：所有待发事件在库里可查、可重放、可人工补偿。这是它相比 2PC 的隐性优势。

## 三、表设计：一张表承载所有事件

```sql
CREATE TABLE outbox_event (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  event_id      CHAR(36)        NOT NULL COMMENT '全局唯一，消费端幂等键',
  aggregate_type VARCHAR(64)    NOT NULL COMMENT 'ORDER / PAYMENT / USER',
  aggregate_id  VARCHAR(64)     NOT NULL COMMENT '聚合根 ID，用于分区键保证顺序',
  event_type    VARCHAR(128)    NOT NULL COMMENT 'OrderCreated / OrderPaid',
  payload       JSON            NOT NULL,
  headers       JSON            NULL     COMMENT 'traceId / schemaVersion / tenantId',
  status        TINYINT         NOT NULL DEFAULT 0 COMMENT '0=NEW 1=IN_FLIGHT 2=SENT 3=FAILED',
  retry_count   INT             NOT NULL DEFAULT 0,
  next_retry_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  lease_owner   VARCHAR(64)     NULL     COMMENT 'IN_FLIGHT 持有者',
  lease_until   DATETIME(3)     NULL     COMMENT '租约到期，可被抢占',
  created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_event_id (event_id),
  KEY idx_dispatch (status, next_retry_at, id),
  KEY idx_aggregate (aggregate_type, aggregate_id, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

几个设计决策的理由：

**① 为什么要 `event_id` 而不只用自增主键？**
自增 ID 在同一张分库表里会重复，且暴露数据量。`event_id`（UUID/Snowflake）是**跨库全局唯一**的，能直接作为下游的幂等键。

**② 为什么索引是 `(status, next_retry_at, id)`？**
投递查询是 `WHERE status = 0 AND next_retry_at <= NOW() ORDER BY id LIMIT N`。这个联合索引能同时覆盖过滤和排序，避免 filesort。**注意 `status` 的区分度问题**：如果 `SENT` 的数据不清理，`status=2` 会占 99% 的行，索引选择性劣化。所以必须配合归档/删除（见第七节）。

**③ 为什么需要 `lease_owner` / `lease_until`？**
多实例轮询时，如果只在内存里记"这批归我"，实例崩溃后这批事件会被永久卡在 `IN_FLIGHT`。用租约（lease）表达"我承诺在 X 时刻前处理完，超时别人可以抢"，是无协调者场景下的标准做法。

**④ `payload` 用 JSON 还是 TEXT？**
MySQL 8 的 JSON 类型有校验和部分函数支持，但**不要**在 `payload` 上建函数索引做查询——Outbox 表只按状态和时间查，payload 是"货物"不是"索引字段"。如果 payload 很大（> 100KB），考虑存对象存储 + 存引用，否则会让 redo/undo 变大、事务变慢。

## 四、两条投递路线：轮询 vs CDC

| 维度 | 轮询（Polling Publisher） | CDC（Log Tailing） |
|---|---|---|
| 实现 | 定时 `SELECT ... LIMIT N` | 订阅 binlog（Debezium / Canal） |
| 延迟 | 取决于轮询间隔（100ms~1s） | 毫秒~秒级 |
| 对数据库压力 | 有（频繁查询，可用索引缓解） | 低（读 binlog，从库/独立实例更佳） |
| 顺序性 | 需要自己保证（按 id 或聚合根串行） | 天然按 binlog 顺序 |
| 删除数据 | 可以删除（发完即删） | **不能删**，否则 CDC 捕获不到 DELETE 后的语义 |
| 运维复杂度 | 极低，一个定时任务 | 高，需要 Debezium/Canal 集群 |
| 适用规模 | 中小流量、事件量 < 10k/s | 大流量、已有 CDC 基础设施 |

**选择建议**：

- 事件量不大、团队小 → **轮询**。它简单到可以用 50 行代码写完，故障模式清晰。
- 已经有 Debezium/Canal 集群、事件量大 → **CDC**。注意 CDC 方案下不要删除 outbox 行（可以定期归档到另一张表，或标记 `archived`）。
- 混合方案：CDC 做实时投递，轮询做**兜底补偿**（扫 `status=0 AND created_at < now - 5min` 的漏网事件）。这是我们在生产上的最终选择——两套机制互为备份，代价只是多一个定时任务。

## 五、轮询投递的正确实现

### 5.1 为什么必须 `SKIP LOCKED`

假设 8 个实例同时跑 Relay，都用同一个 SQL：

```sql
SELECT id, event_id, event_type, payload, headers
FROM outbox_event
WHERE status = 0 AND next_retry_at <= NOW(3)
ORDER BY id
LIMIT 200
FOR UPDATE;
```

结果：8 个实例抢同一批行的行锁，7 个阻塞等待，然后拿到同样的数据重复发送。不仅浪费，还会把数据库连接池占满。

`SKIP LOCKED`（MySQL 8.0+ / PostgreSQL 9.5+）让查询**跳过已被其他事务锁定的行**，直接返回它自己能锁的那批：

```sql
SELECT id, event_id, event_type, payload, headers
FROM outbox_event
WHERE status = 0 AND next_retry_at <= NOW(3)
ORDER BY id
LIMIT 200
FOR UPDATE SKIP LOCKED;
```

这是"用数据库做分布式队列"的标准技巧。它的语义非常契合：**每个消费者只要能拿到不同的行就行，不需要严格的 FIFO 全局顺序。**

⚠️ 重要限制：`SKIP LOCKED` 在**主从架构下只在主库有意义**。读从库拿不到写锁，会退化成普通查询，多实例重复消费的问题原样存在。所以 Relay 必须连主库（或至少连可写的那个节点）。

### 5.2 两阶段标记：避免长事务持锁

最朴素的做法是在同一个事务里"取 → 发 → 标记"。问题是**发送是网络 IO**（Kafka 集群跨 AZ 时可能几十毫秒），事务持有行锁的时间被网络放大，高并发下会拖垮 outbox 表。

生产做法是拆成两个短事务 + 中间态：

```
事务1: SELECT ... FOR UPDATE SKIP LOCKED  →  UPDATE status=1, lease_owner=me, lease_until=now+30s  →  COMMIT
事务外: 批量 send 到 MQ（幂等 producer）
事务2: UPDATE status=2 WHERE id IN (...) AND lease_owner=me      ← 成功
       或 UPDATE status=0, retry_count+1, next_retry_at=退避时间 WHERE id IN (...) AND lease_owner=me  ← 失败
```

租约到期后（`lease_until < now`），别的实例可以接管 `IN_FLIGHT` 的事件——这就是崩溃恢复。

### 5.3 Java 实现

写侧（业务 + outbox 同事务）：

```java
@Service
public class OrderService {

    private final OrderMapper orderMapper;
    private final OutboxMapper outboxMapper;
    private final ObjectMapper json;

    @Transactional(rollbackFor = Exception.class)
    public void createOrder(Order order) throws JsonProcessingException {
        orderMapper.insert(order);

        OutboxEvent event = OutboxEvent.builder()
                .eventId(UUID.randomUUID().toString())
                .aggregateType("ORDER")
                .aggregateId(order.getId())
                .eventType("OrderCreated")
                .payload(json.writeValueAsString(OrderCreatedPayload.from(order)))
                .status(0)
                .build();
        outboxMapper.insert(event);
        // 事务提交时，业务数据和事件一起落盘
    }
}
```

投递侧（Spring `@Scheduled` + 虚拟线程并发发送）：

```java
@Component
public class OutboxRelay {

    private static final int BATCH = 200;
    private final OutboxMapper outboxMapper;
    private final KafkaTemplate<String, String> kafka;
    private final String owner = InetAddress.getLocalHost().getHostName();

    @Scheduled(fixedDelay = 200)
    public void relay() {
        List<OutboxRow> rows = outboxMapper.claim(owner, BATCH);   // SKIP LOCKED + 租约
        if (rows.isEmpty()) return;

        // 批量发送：失败的单独收集，避免一条坏消息拖累整批
        List<Long> sent = new ArrayList<>(rows.size());
        List<Long> failed = new ArrayList<>();
        for (OutboxRow row : rows) {
            try {
                kafka.send(row.getEventType(), row.getAggregateId(), row.getPayload())
                     .get(3, TimeUnit.SECONDS);   // 分区键 = aggregateId，保证同一聚合根有序
                sent.add(row.getId());
            } catch (Exception e) {
                failed.add(row.getId());
            }
        }
        if (!sent.isEmpty())  outboxMapper.markSent(sent, owner);
        if (!failed.isEmpty()) outboxMapper.markRetry(failed, owner, 5000); // 5s 后重试
    }
}
```

对应的 SQL（XML / 注解）：

```xml
<select id="claim" resultType="OutboxRow">
  SELECT id, event_id, aggregate_id, event_type, payload, retry_count
  FROM outbox_event
  WHERE (status = 0 AND next_retry_at &lt;= NOW(3))
     OR (status = 1 AND lease_until &lt; NOW(3))
  ORDER BY id
  LIMIT #{limit}
  FOR UPDATE SKIP LOCKED
</select>

<update id="markSent">
  UPDATE outbox_event
  SET status = 2, lease_owner = NULL, lease_until = NULL
  WHERE lease_owner = #{owner} AND id IN
  <foreach collection="ids" item="id" open="(" separator="," close=")">#{id}</foreach>
</update>
```

注意 `markSent` 里的 `lease_owner = #{owner}` 是**乐观校验**：如果租约已过期被别的实例接管，你不能再把状态改成 `SENT`（虽然重复发送已经发生了，但至少不会覆盖别人的状态机）。

### 5.4 Kafka Producer 侧要开幂等

```yaml
spring:
  kafka:
    producer:
      acks: all
      enable-idempotence: true          # 幂等生产者，避免网络重试导致 broker 侧重复
      properties:
        max.in.flight.requests.per.connection: 5
```

`enable.idempotence=true` 会保证**同一个 producer 会话内**的重试不重复写入，但它**不能解决跨会话（进程重启）的重复**。所以下游的幂等仍然必须做。

## 六、消费端幂等：at-least-once 的另一半

Outbox 保证了"不丢"，代价是"可能重复"。消费端必须把重复变成无副作用。

### 6.1 去重表（最可靠）

```sql
CREATE TABLE consumed_event (
  event_id       CHAR(36)     NOT NULL,
  consumer_group VARCHAR(64)  NOT NULL,
  consumed_at    DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (event_id, consumer_group)
) ENGINE=InnoDB;
```

消费逻辑：

```java
@Transactional
public void onOrderCreated(OrderCreatedEvent event) {
    int inserted = dedupMapper.tryInsert(event.eventId(), "inventory-consumer");
    if (inserted == 0) {
        return;   // 已消费过，直接跳过（唯一键冲突）
    }
    inventoryService.deduct(event.orderId(), event.items());
}
```

**关键：去重表的插入必须和业务操作在同一个事务里。** 否则"插入成功、业务失败"会导致消息被永久丢弃。

### 6.2 业务唯一键（更优雅）

如果业务本身有天然唯一键（订单号 + 商品 ID + 操作类型），直接靠唯一索引兜底，连去重表都省了：

```sql
INSERT INTO inventory_deduction (order_id, sku_id, qty)
VALUES (?, ?, ?)
ON DUPLICATE KEY UPDATE id = id;   -- 幂等
```

### 6.3 幂等 ≠ 完全去重

有些操作天然不幂等（比如"余额 +100"）。必须改成**状态机式**语义：`UPDATE account SET status='PAID' WHERE id=? AND status='UNPAID'`，用 `affectedRows` 判断是否首次生效。

## 七、顺序性、积压与清理

### 7.1 顺序性

Outbox 只能保证"入库顺序 = id 顺序"，投递时如果多线程并发发送，顺序就乱了。

三种保证方式：

| 方式 | 做法 | 代价 |
|---|---|---|
| 单线程投递 | Relay 单线程按 id 顺序发 | 吞吐受限（一般够用：单线程 Kafka 发送可达 1~2 万 TPS） |
| 按聚合根分区 | `kafka.send(topic, aggregateId, payload)` + 单分区内串行 | 同一聚合根有序，不同聚合根并行 |
| 版本号 + 下游重排 | payload 带 `version`，下游丢弃旧版本 | 下游复杂度上升 |

实践推荐：**按 `aggregate_id` 做 Kafka 分区键 + 单线程按 id 投递**。前者保证同一订单的事件落在同一分区、被同一消费者按序处理；后者保证 outbox 内部的顺序。

### 7.2 积压监控

必须监控四个指标：

```java
// 待投递积压量（最核心）
gauge("outbox.pending", () -> mapper.countByStatus(0));
// 最老待投递事件的年龄（秒）
gauge("outbox.oldest.pending.age.seconds", () -> mapper.oldestAgeSeconds());
// 失败重试量
gauge("outbox.failed", () -> mapper.countByStatus(3));
// 租约超时被抢占的次数（说明 Relay 有崩溃/卡顿）
counter("outbox.lease.steal");
```

告警规则：`oldest.pending.age > 60s` 或 `pending > 10000` 立即告警。**Outbox 积压是所有"最终一致"系统里最先暴露问题的指标。**

### 7.3 清理策略

`SENT` 的行必须清理，否则表无限膨胀、索引选择性劣化、DDL 变慢。三种方案：

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| 定时删除 | 每 5 分钟 `DELETE ... WHERE status=2 AND created_at < now-1d LIMIT 2000` | 简单 | 产生碎片，需配合 `innodb_purge` |
| 分区表 | 按天 RANGE 分区，`DROP PARTITION` | 零成本删除 | DDL 复杂，跨分区查询 |
| 归档表 | 移动到 `outbox_event_archive` | 保留审计 | 多一次写 |

**推荐：分区表 + DROP PARTITION**（MySQL 8 支持 `ALTER TABLE ... DROP PARTITION` 秒级完成）。如果没有分区，至少用"小批量循环删除"避免长事务：

```java
int deleted;
do {
    deleted = mapper.deleteBatch(2000);   // WHERE status=2 AND created_at < ?
    if (deleted > 0) Thread.sleep(50);    // 让 purge 线程跟上
} while (deleted == 2000);
```

## 八、方案对比：Outbox 到底该放在什么位置

| 方案 | 一致性 | 性能 | 复杂度 | 适用场景 |
|---|---|---|---|---|
| 直接双写 | 弱（有丢/重窗口） | 最好 | 最低 | 允许丢消息的日志类场景 |
| **Transactional Outbox** | **最终一致** | **好**（多一次 insert） | **中** | **绝大多数业务事件** |
| RocketMQ 事务消息 | 最终一致 | 好 | 中（绑定 MQ） | 已用 RocketMQ，且愿意实现回查接口 |
| 2PC / XA | 强一致 | 差（同步阻塞） | 高 | 极少，仅强一致金融场景 |
| Seata AT | 最终一致 | 中（全局锁） | 高 | 已有 Seata 体系 |
| CDC 直读 binlog | 最终一致 | 好 | 高 | 已有 Debezium/Canal |

一句话结论：**Outbox 是"最终一致"场景下性价比最高的方案，它用一次额外 insert 换掉了整个分布式事务的复杂度。**

## 九、六个生产踩坑

**坑 1：`@Transactional` 没生效，outbox 和业务不同事务。**
最常见的原因：同类内部方法调用（自调用不走代理）、异常被 catch 掉没抛出、方法不是 public、事务管理器配错（多数据源时用了默认的）。上线前必须写一个"故意失败"的集成测试，断言 outbox 表里没有残留行。

**坑 2：把大 payload 塞进 outbox。**
一条 500KB 的 JSON 事件，让 redo log 暴涨、事务变长、主从延迟变大。**Outbox 里只放"事件 ID + 关键字段"，大对象存对象存储，下游按需拉取。**

**坑 3：`status = 0` 用错类型导致索引失效。**
`status` 是 `TINYINT`，SQL 里写 `status = '0'`（字符串）会触发隐式转换，索引可能失效。统一用整型常量。

**坑 4：Relay 和业务共用连接池。**
Relay 的 `SELECT ... FOR UPDATE` 会长时间持有行锁和连接，和业务线程抢 HikariCP 连接。**给 Relay 独立的小连接池（2~4 个连接）。**

**坑 5：重试没有退避，把下游打挂。**
失败立即重试 = 在下游故障时制造雪崩。必须用指数退避 + 抖动：`next_retry_at = now + min(2^n, 300) * (0.5 + rand())` 秒。重试超过 N 次（比如 10 次）转入 `FAILED` 状态，进人工补偿队列。

**坑 6：以为 CDC 方案不需要管 outbox 表。**
CDC 订阅 binlog，如果把 outbox 行删了，Debezium 的删除事件也会被投递（取决于配置），可能造成下游困惑。CDC 方案下**只标记不删除**，或用 `archive` 标记 + 定期归档。

## 十、面试追问

**Q1：为什么不用 RocketMQ 的事务消息？**
事务消息把"消息"和"本地事务"做成了半消息 + 回查，本质解决的是同一个问题，但代价是：① 强绑定 MQ 厂商；② 必须实现回查接口（查本地事务状态），回查逻辑本身要幂等且可靠；③ 消息积压时清理困难。Outbox 不绑定任何 MQ，可以随时换投递通道（甚至先发 HTTP，后来改 Kafka），且所有事件在库里可审计、可重放。**如果已经在用 RocketMQ 且团队熟悉，事务消息也是合理选择；如果还没定 MQ，Outbox 更灵活。**

**Q2：Outbox 能保证 exactly-once 吗？**
不能。任何跨系统的"恰好一次"都是幻觉。Outbox 保证的是 at-least-once（不丢），exactly-once 需要"幂等消费"在业务语义上实现。**面试时一定要主动说这句话，这是加分项。**

**Q3：`SKIP LOCKED` 在什么情况下会失效？**
① MySQL 5.7 及以下不支持；② 读从库（拿不到写锁）；③ 隔离级别为 READ UNCOMMITTED 时不加锁；④ 查询走不到索引时全表扫描 + 锁大量行，性能崩溃。

**Q4：多个实例轮询，会不会出现"事件被跳过"？**
不会。`SKIP LOCKED` 跳过的是"已被锁定"的行，那些行正被别的实例处理；未锁定的行一定会被某个实例取到。真正可能"卡住"的是 `IN_FLIGHT` 且租约过期的行——这就是为什么查询条件里要 `OR (status=1 AND lease_until < NOW())`。

**Q5：Outbox 表的写入会不会成为性能瓶颈？**
在极高写入场景（> 5 万 TPS）下，自增主键和索引维护确实会争用。缓解手段：① 按 `aggregate_id` 哈希分表；② 用 Snowflake 代替自增 ID（避免热点页争用）；③ 批量插入（一次事务插多条事件）；④ 把 outbox 放到独立的库实例，避免和业务表抢 buffer pool。

**Q6：怎么测试 Outbox 的正确性？**
三个层次的测试：① **故障注入**：在 `kafka.send` 后、`markSent` 前 kill 进程，重启后验证事件被重发且下游幂等；② **并发测试**：8 个实例同时跑 Relay，断言每个 `event_id` 至少被投递一次、无遗漏；③ **对账**：业务表条数 vs outbox 表条数 vs 下游消费条数，三者最终收敛。

## 十一、总结

Outbox 模式的精髓不是"多一张表"，而是**把分布式一致性问题降维成本地事务 + 幂等消费**：

1. **写侧**：业务数据 + 事件在同一个 InnoDB 事务，靠 redo log 保证原子性；
2. **投递侧**：`SKIP LOCKED` + 租约 + 两阶段标记，多实例安全、崩溃可恢复；
3. **消费侧**：去重表 / 业务唯一键 / 状态机，把 at-least-once 变成"业务上恰好一次"；
4. **运维侧**：积压年龄是核心指标，清理策略必须在上线前就设计好。

最后一句经验：**别在没有 Outbox 的系统里做跨服务的状态变更。** 你省下的那张表，迟早会变成对账脚本和半夜的告警电话。
