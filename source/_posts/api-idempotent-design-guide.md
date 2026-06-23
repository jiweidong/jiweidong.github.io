---
title: 接口幂等性设计方案全面对比：Token、去重表、状态机与分布式锁
date: 2026-06-23 08:01:00
tags:
  - 幂等
  - 高可用
  - 分布式
categories:
  - 架构
  - 系统设计
author: 东哥
---

# 接口幂等性设计方案全面对比：Token、去重表、状态机与分布式锁

## 面试官：支付系统怎么防止重复扣款？

幂等性（Idempotence）—— 这是面试高频题，也是生产系统最容易踩坑的地方。

## 一、什么是幂等？

**幂等**：同一个接口调用多次和调用一次产生的**业务效果相同**。

```
// 非幂等
UPDATE account SET balance = balance - 100 WHERE id = 1;
// 执行一次 → 余额少100
// 执行两次 → 余额少200 ❌

// 幂等
UPDATE account SET balance = 100 WHERE id = 1;
// 无论执行多少次 → 余额都是100 ✅
```

## 二、哪些场景需要幂等？

| 场景 | 风险 |
|------|------|
| **支付扣款** | 用户多点了一次"确认支付" |
| **下单接口** | 前端超时重试导致重复提交 |
| **MQ 消费** | 消费端宕机重启后重复消费 |
| **RPC 重试** | 服务超时导致客户端重试 |
| **定时任务** | 调度器重复触发 |

## 三、七种幂等方案详解

### 方案一：唯一约束（数据库防重）

利用数据库的唯一索引或联合唯一索引来防重。

```sql
-- 支付流水表
CREATE TABLE payment_record (
    id          BIGINT PRIMARY KEY AUTO_INCREMENT,
    order_no    VARCHAR(64) NOT NULL COMMENT '订单号',
    trade_no    VARCHAR(64) NOT NULL COMMENT '交易流水号',
    amount      DECIMAL(10,2),
    status      TINYINT,
    create_time DATETIME,
    -- 唯一约束
    UNIQUE KEY uk_trade_no (trade_no)
) ENGINE=InnoDB;
```

```java
public void processPayment(PaymentReq req) {
    try {
        paymentRecordMapper.insert(req.toRecord());
        // insert 成功 → 第一次请求，正常处理
        doPayment(req);
    } catch (DuplicateKeyException e) {
        // 重复请求，直接返回成功
        log.warn("Duplicate payment request: {}", req.getTradeNo());
    }
}
```

**优点：** 最强保证，数据绝对不重。
**缺点：** 不适合高并发写热点，DB 承载压力。

### 方案二：去重表（辅助表防重）

专门建一个去重表，和业务解耦。

```sql
CREATE TABLE idempotent_record (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,
    idempotent_key  VARCHAR(128) NOT NULL COMMENT '幂等键',
    biz_type        VARCHAR(32) NOT NULL COMMENT '业务类型',
    status          TINYINT DEFAULT 0 COMMENT '0=处理中 1=已完成',
    expire_time     DATETIME,
    UNIQUE KEY uk_key (idempotent_key)
) ENGINE=InnoDB;
```

```java
@Transactional
public void submitOrder(OrderDTO order) {
    String idempotentKey = order.getUserId() + "_" + order.getOrderNo();
    // 插入去重记录
    int rows = idempotentRecordDao.insertIfNotExist(idempotentKey, "ORDER");
    if (rows == 0) {
        throw new BusinessException("重复提交，请勿频繁操作");
    }
    // 执行下单逻辑
    orderService.createOrder(order);
    // 更新状态为已完成
    idempotentRecordDao.updateStatus(idempotentKey, Status.COMPLETED);
}
```

> **关键点**：INSERT 和业务操作要在**同一个事务**里。否则 INSERT 成功但业务失败就尴尬了。

### 方案三：Token 机制（前端 + 后端协同）

**流程：**

```
[客户端]                    [服务端]
    │                          │
    ├── 1. 请求 Token ────────→│
    │                          ├── 生成唯一 Token (Redis SET NX)
    │←──── 2. 返回 Token ─────┤
    │                          │
    ├── 3. 提交请求 + Token ──→│
    │                          ├── 4. 校验 Token (Redis DEL)
    │                          │     DEL 成功 → 正常处理
    │                          │     DEL 失败 → 重复请求
    │←──── 5. 返回结果 ───────┤
```

```java
// Token 生成
public String generateToken(String bizId) {
    String token = UUID.randomUUID().toString();
    // 设置 30 分钟过期
    redisTemplate.opsForValue().set(
        "idempotent:token:" + bizId,
        token,
        30, TimeUnit.MINUTES
    );
    return token;
}

// Token 校验（核心）
public boolean checkToken(String bizId, String token) {
    String key = "idempotent:token:" + bizId;
    // 使用 Lua 脚本保证原子性
    String lua = "if redis.call('get', KEYS[1]) == ARGV[1] then " +
                 "return redis.call('del', KEYS[1]) " +
                 "else return 0 end";
    Long result = redisTemplate.execute(
        new DefaultRedisScript<>(lua, Long.class),
        List.of(key), token
    );
    return result != null && result == 1L;
}
```

**优点：** 实现简单，适合前端防重复提交。
**缺点：** 需要额外一次网络请求获取 Token，多一次交互。

### 方案四：状态机（业务状态流转幂等）

利用业务状态的**单向性**保证幂等。

```
           ┌──────┐   支付    ┌──────┐   发货    ┌──────┐   完成
待支付 ──→ 已支付 ──→ 已发货 ──→ 已完成
  │                            ↑
  └──── 取消 ──→ 已取消 ──────┘
```

```java
public boolean updateOrderStatus(Long orderId, 
                                  OrderStatus fromStatus, 
                                  OrderStatus toStatus) {
    // WHERE 条件同时匹配当前状态，天然幂等
    int rows = orderMapper.updateStatus(
        orderId, fromStatus, toStatus
    );
    return rows > 0;
}

// 调用
if (updateOrderStatus(orderId, OrderStatus.UNPAID, OrderStatus.PAID)) {
    // 正常处理
} else {
    // 重复请求或状态不对
}
```

**优点：** 零额外存储，利用业务状态自然防重。
**缺点：** 只适合有明确状态流转的业务。

### 方案五：Redis SET NX + 过期时间

```java
public boolean tryLock(String key, String requestId, long expireMs) {
    // SET NX EX 原子操作
    return redisTemplate.opsForValue()
        .setIfAbsent(key, requestId, expireMs, TimeUnit.MILLISECONDS);
}

public boolean unlock(String key, String requestId) {
    // Lua 脚本保证只有持有者才能释放
    String lua = "if redis.call('get', KEYS[1]) == ARGV[1] then " +
                 "return redis.call('del', KEYS[1]) " +
                 "else return 0 end";
    return redisTemplate.execute(...) == 1L;
}

// 使用
String reqId = UUID.randomUUID().toString();
String lockKey = "lock:order:" + orderNo;
if (tryLock(lockKey, reqId, 3000)) {
    try {
        processOrder(orderNo);
    } finally {
        unlock(lockKey, reqId);
    }
}
```

### 方案六：全局 ID + 防重表（去重表升级版）

| 字段 | 说明 |
|------|------|
| idempotent_key | 业务幂等ID（订单号 + 操作类型） |
| biz_status | 业务状态 |
| gmt_create | 首次请求时间 |
| gmt_modified | 最后更新时间 |

每次请求先查询 idempotent_key：
- **不存在** → 插入，执行业务逻辑
- **存在且已完成** → 直接返回成功
- **存在但处理中** → 等待或报错

### 方案七：MQ 消费幂等 —— 消费记录表

```sql
CREATE TABLE mq_consume_record (
    message_id      VARCHAR(64) PRIMARY KEY,
    biz_key         VARCHAR(128),
    status          TINYINT COMMENT '0=待处理 1=已处理',
    consume_time    DATETIME
);
```

```java
@KafkaListener(topics = "payment_topic")
public void onMessage(ConsumerRecord<String, String> record) {
    String messageId = record.key();
    // INSERT IGNORE 天然幂等
    int rows = consumeRecordDao.insertIgnore(messageId);
    if (rows == 1) {
        doBizLogic(record.value());
        consumeRecordDao.updateStatus(messageId, 1);
    }
}
```

## 四、九种方案横向对比

| 方案 | 实现难度 | 性能 | 可靠性 | 额外依赖 | 适用场景 |
|------|---------|------|--------|---------|---------|
| 唯一约束 | 低 | 中 | ★★★★★ | 无 | 核心金融交易 |
| 去重表 | 中 | 中 | ★★★★★ | MySQL | 订单创建 |
| Token 机制 | 中 | 高 | ★★★★ | Redis | 前端防重复 |
| 状态机 | 低 | 高 | ★★★★ | 无 | 有状态的业务 |
| Redis NX | 中 | 高 | ★★★ | Redis | 轻量防重 |
| 全局ID+防重 | 高 | 中 | ★★★★★ | DB | 资金类 |
| MQ消费记录 | 中 | 高 | ★★★★★ | DB | 消息消费 |

## 五、最佳实践

### 分层防御体系

```
[客户端]    按钮置灰 + Token 预取
    ↓
[网关层]    请求去重（Nginx Lua / 网关过滤）
    ↓
[业务层]    状态机 + 去重表
    ↓
[数据层]    唯一约束兜底
```

### 幂等键设计原则

- **粒度适中**：一个幂等键对应一次完整业务操作
- **业务相关**：包含 user_id + biz_type + biz_id
- **唯一可算**：不依赖前端传入，服务端能自行计算

### 常见陷阱

```
❌ 幂等查询用 POST（不幂等）→ 应该用 GET
❌ 悲观锁 for update → 改成乐观锁 version
❌ 先查询再判断 → 改成 INSERT ON DUPLICATE KEY
```

## 六、面试追问

> **Q：去重表方案的性能瓶颈在哪？**
> A：在 INSERT 操作。高并发下唯一索引冲突会产生大量死锁。解决方案：用 Redis 前置过滤 + 间隔批量刷 DB。

> **Q：分布式环境下 Token 如何同步？**
> A：Token 存储在 Redis，本身就是分布式共享的。多个实例都能校验。

> **Q：如果业务执行一半宕机了怎么办？**
> A：幂等记录状态设为"处理中"，配合补偿任务/MQ 查询最终状态来决定是回滚还是重试。这就是 **TCC 模式**的思想。

---

**总结：** 没有万能方案。支付扣款用唯一约束，下单用 Token 机制 + 去重表，MQ 消费用消费记录表。**组合 > 单一**，分层防御才是王道。
