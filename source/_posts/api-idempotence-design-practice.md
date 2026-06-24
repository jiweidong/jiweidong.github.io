---
title: 【高并发设计】接口幂等性方案全解析：从原理到代码实战
date: 2026-06-24 08:00:00
tags:
  - Java
  - 系统设计
  - 高并发
  - 幂等
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【高并发设计】接口幂等性方案全解析：从原理到代码实战

## 一、什么是幂等性？

> **幂等（Idempotent）**：在编程中，一个幂等操作的特点是其任意多次执行所产生的影响均与一次执行的影响相同。

举个生活例子：**电梯按钮**——按一次电梯到1楼，按十次电梯还是到1楼，结果不会变。这就是幂等。

在分布式系统中，幂等性尤为重要，因为网络不可靠，重试是常态。

### 为什么需要幂等？

| 场景 | 问题 | 后果 |
|------|------|------|
| 支付接口重试 | 用户点了两次"支付" | 重复扣款 |
| 订单创建重试 | 提交订单超时，自动重试 | 生成重复订单 |
| MQ 消息重复消费 | 消费成功但 ACK 失败 | 重复处理 |
| 前端重复提交 | 用户狂点提交按钮 | 数据重复 |

> **幂等设计是分布式系统的第一道防线。**

## 二、幂等实现方案全景图

```
方案对比总览
┌─────────────────────────────────────────────────┐
│                 幂等方案                          │
├─────────────────────────────────────────────────┤
│ 1. 数据库唯一约束     ⭐ 简单可靠，基础方案       │
│ 2. 分布式锁            ⭐ 通用性强，适合复杂业务   │
│ 3. Token 机制          ⭐ 防止重复提交，最常用     │
│ 4. 状态机              ⭐ 适合有状态流转的业务     │
│ 5. 去重表              ⭐ 数据库中间表方案         │
│ 6. 全局唯一ID          ⭐ 接口天然幂等             │
└─────────────────────────────────────────────────┘
```

## 三、方案一：数据库唯一约束（最基础）

利用数据库的唯一索引来保证幂等。

### 3.1 业务唯一键

```sql
-- 订单表，使用业务订单号作为唯一约束
CREATE TABLE `t_order` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `order_no` VARCHAR(64) NOT NULL COMMENT '订单号（业务唯一键）',
  `status` TINYINT NOT NULL DEFAULT 0,
  `amount` DECIMAL(10,2) NOT NULL,
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_order_no` (`order_no`)  -- 唯一约束保证幂等
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

```java
@Service
public class OrderService {
    
    @Transactional
    public Order createOrder(OrderDTO dto) {
        Order order = new Order();
        order.setOrderNo(dto.getOrderNo());  // 前端生成的唯一订单号
        order.setAmount(dto.getAmount());
        order.setStatus(OrderStatus.PENDING);
        
        try {
            orderMapper.insert(order);
            return order;
        } catch (DuplicateKeyException e) {
            // 重复插入 → 查询已有订单返回
            log.warn("订单已存在，返回已有订单: {}", dto.getOrderNo());
            return orderMapper.selectByOrderNo(dto.getOrderNo());
        }
    }
}
```

**优点**：实现简单，数据库原生保证。
**缺点**：依赖数据库，性能受限于 DB；不适合分布式事务场景。

## 四、方案二：Token 机制（最常用、推荐）

**原理**：每次请求前先获取一个 token，请求时携带 token，服务端校验后删除。一个 token 只能用一次。

### 4.1 完整实现

```java
@Component
public class IdempotentTokenService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    /**
     * 1. 创建 Token
     */
    public String createToken() {
        String token = UUID.randomUUID().toString().replace("-", "");
        // 存入 Redis，设置 30 分钟过期
        redisTemplate.opsForValue().set(
            IDEMPOTENT_KEY_PREFIX + token, 
            "1", 
            30, 
            TimeUnit.MINUTES
        );
        return token;
    }
    
    /**
     * 2. 校验并删除 Token（Lua 脚本保证原子性）
     */
    public boolean checkAndDeleteToken(String token) {
        if (StringUtils.isBlank(token)) {
            return false;
        }
        
        // Lua 脚本：GET + DEL 原子操作
        String luaScript = """
            local key = KEYS[1]
            local exists = redis.call('GET', key)
            if exists then
                redis.call('DEL', key)
                return 1
            else
                return 0
            end
            """;
        
        Long result = redisTemplate.execute(
            new DefaultRedisScript<>(luaScript, Long.class),
            Collections.singletonList(IDEMPOTENT_KEY_PREFIX + token)
        );
        
        return Long.valueOf(1).equals(result);
    }
}
```

### 4.2 注解 + AOP 切面实现

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Idempotent {
    /**
     * Token 来源（参数名或请求头）
     */
    String tokenSource() default "idempotent-token";
}
```

```java
@Aspect
@Component
public class IdempotentAspect {
    
    @Autowired
    private IdempotentTokenService tokenService;
    
    @Around("@annotation(idempotent)")
    public Object around(ProceedingJoinPoint joinPoint, Idempotent idempotent) throws Throwable {
        // 从请求参数中获取 token
        String token = extractToken(joinPoint, idempotent.tokenSource());
        
        if (StringUtils.isBlank(token)) {
            throw new BizException("幂等Token不能为空");
        }
        
        // 校验并删除 token
        if (!tokenService.checkAndDeleteToken(token)) {
            throw new BizException("请勿重复提交");
        }
        
        return joinPoint.proceed();
    }
}
```

### 4.3 前端配合

```javascript
// 1. 进入页面时获取 token
const tokenRes = await axios.get('/api/idempotent/token');

// 2. 提交请求时携带 token
const res = await axios.post('/api/order/create', {
    ...orderData,
    idempotentToken: tokenRes.data
});
```

**优点**：简单通用，适合绝大多数写接口。
**缺点**：需要两次请求（拿 token → 提交），增加一次网络开销。

## 五、方案三：分布式锁方案

适用于 **需要根据业务条件判断幂等** 的场景，比如一个活动只能参与一次。

### 5.1 基于 Redis 分布式锁

```java
@Service
public class CouponService {
    
    @Autowired
    private RedisTemplate<String, String> redisTemplate;
    
    private static final String LOCK_KEY_PREFIX = "lock:coupon:receive:";
    
    /**
     * 领取优惠券 - 一人只能领一次
     */
    @Transactional
    public CouponResult receiveCoupon(Long userId, Long couponActivityId) {
        String lockKey = LOCK_KEY_PREFIX + userId + ":" + couponActivityId;
        
        // 尝试获取锁（等待 2 秒，自动释放 5 秒）
        Boolean locked = redisTemplate.opsForValue()
            .setIfAbsent(lockKey, "1", 5, TimeUnit.SECONDS);
        
        if (Boolean.FALSE.equals(locked)) {
            throw new BizException("操作太频繁，请稍后再试");
        }
        
        try {
            // 2. 业务校验：是否已领取
            if (couponMapper.countByUserAndActivity(userId, couponActivityId) > 0) {
                return CouponResult.alreadyReceived();
            }
            
            // 3. 核心业务
            Coupon coupon = new Coupon();
            coupon.setUserId(userId);
            coupon.setActivityId(couponActivityId);
            coupon.setAmount(new BigDecimal("100"));
            couponMapper.insert(coupon);
            
            return CouponResult.success(coupon);
        } finally {
            // 释放锁
            redisTemplate.delete(lockKey);
        }
    }
}
```

**优化**：使用 Lua 脚本 + 唯一值保证锁的释放安全：

```java
// Lua 脚本：只在值匹配时删除
String luaScript = """
    if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('DEL', KEYS[1])
    end
    return 0
    """;
```

## 六、方案四：状态机模式

对于有**明确状态流转**的业务（订单、审批流等），利用状态机天然保证幂等：

```java
public enum OrderStatus {
    PENDING(0, "待支付"),
    PAID(1, "已支付"),     // 只有 PENDING 可以 → PAID
    SHIPPED(2, "已发货"),  // 只有 PAID 可以 → SHIPPED
    DELIVERED(3, "已送达"),
    CANCELLED(-1, "已取消");

    private final int code;
    private static final Map<Integer, Set<Integer>> TRANSITIONS = new HashMap<>();

    static {
        // 定义允许的状态流转
        TRANSITIONS.put(PENDING.code, Set.of(PAID.code, CANCELLED.code));
        TRANSITIONS.put(PAID.code, Set.of(SHIPPED.code, CANCELLED.code));
        TRANSITIONS.put(SHIPPED.code, Set.of(DELIVERED.code));
    }

    public boolean canTransitionTo(OrderStatus target) {
        Set<Integer> allowed = TRANSITIONS.get(this.code);
        return allowed != null && allowed.contains(target.code);
    }
}
```

```java
@Transactional
public void updateOrderStatus(Long orderId, OrderStatus newStatus) {
    // 关键：在 SQL 中校验状态，原子更新
    int rows = orderMapper.updateStatusIfAllowed(orderId, newStatus.code());
    if (rows == 0) {
        throw new BizException("状态更新失败，请检查当前状态");
    }
}
```

```xml
<!-- MyBatis: 使用旧状态作为条件 -->
<update id="updateStatusIfAllowed">
    UPDATE t_order 
    SET status = #{newStatus}, update_time = NOW()
    WHERE id = #{orderId} 
      AND (/* 按业务规则判断是否允许此状态变更 */)
</update>
```

**优点**：完全依赖数据库，天然幂等。
**缺点**：业务复杂时状态机维护成本高。

## 七、方案五：去重表方案

专门建立一张去重表，用于幂等校验：

```sql
CREATE TABLE `t_idempotent` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `idempotent_key` VARCHAR(128) NOT NULL COMMENT '幂等键（业务唯一标识）',
  `status` TINYINT NOT NULL DEFAULT 0 COMMENT '处理状态: 0-处理中, 1-已完成',
  `result` TEXT COMMENT '处理结果（JSON）',
  `expire_time` DATETIME NOT NULL COMMENT '过期时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_idempotent_key` (`idempotent_key`),
  INDEX `idx_expire` (`expire_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

```java
@Service
public class PaymentService {
    
    @Autowired
    private IdempotentMapper idempotentMapper;
    
    @Transactional
    public PayResult processPayment(PayRequest request) {
        String bizKey = "pay:" + request.getOrderNo() + ":" + request.getPayChannel();
        
        // 1. 插入去重记录（利用唯一索引）
        try {
            IdempotentRecord record = new IdempotentRecord();
            record.setIdempotentKey(bizKey);
            record.setStatus(0);
            record.setExpireTime(LocalDateTime.now().plusDays(1));
            idempotentMapper.insert(record);
        } catch (DuplicateKeyException e) {
            // 已处理的请求，返回之前的结果
            return idempotentMapper.getResult(bizKey);
        }
        
        // 2. 执行业务逻辑
        PayResult result = payChannel.pay(request);
        
        // 3. 更新去重记录状态
        idempotentMapper.markCompleted(bizKey, JSON.toJSONString(result));
        
        return result;
    }
}
```

**注意**：去重表需要定期清理过期数据，避免数据膨胀。

## 八、方案六：全局唯一 ID 方案

利用业务本身的唯一性，设计天然幂等的接口：

```java
// 参数中包含业务唯一 ID
POST /api/order/create
{
    "orderNo": "202406241234567890",  // 由客户端生成的唯一订单号
    "amount": 99.00
}
```

服务端以 `orderNo` 为键做幂等处理（结合方案一或五）。

**全局唯一 ID 生成方式**：

| 方案 | 优点 | 缺点 |
|------|------|------|
| UUID | 简单，无中心化 | 无序，索引性能差 |
| 雪花算法 | 有序，高性能 | 依赖机器时钟 |
| Redis INCR | 简单，有序 | 需要 Redis 可用 |
| 数据库自增 | 可靠 | 扩展性差 |

## 九、各方案适用场景对比

| 方案 | 适用场景 | 复杂度 | 性能 | 可靠性 |
|------|---------|-------|------|-------|
| 唯一约束 | 创建类操作（订单、用户） | ⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| Token 机制 | 前端重复提交、通用读接口 | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 分布式锁 | 秒杀、抢券、一人一次 | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 状态机 | 订单流转、审批流 | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| 去重表 | 支付、MQ 消费 | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| 全局唯一 ID | 本身就是幂等设计 | ⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |

## 十、MQ 消费幂等实战

消息队列重复消费是典型场景，**RocketMQ 自带去重机制**：

```java
@RocketMQMessageListener(topic = "order_topic", consumerGroup = "order_group")
@Component
public class OrderMessageListener implements RocketMQListener<MessageExt> {
    
    @Override
    public void onMessage(MessageExt message) {
        // 1. 从消息中获取唯一标识
        String msgId = message.getMsgId();          // RocketMQ 的消息 ID
        String bizKey = message.getKeys();          // 业务 key
        
        // 2. 基于消息幂等处理
        String idempotentKey = "msg:" + bizKey;
        
        // 利用 Redis SETNX 保证消息只被消费一次
        Boolean success = redisTemplate.opsForValue()
            .setIfAbsent(idempotentKey, "1", 1, TimeUnit.DAYS);
        
        if (Boolean.FALSE.equals(success)) {
            log.info("消息已被消费，跳过: {}", bizKey);
            return;
        }
        
        // 3. 执行业务逻辑
        processOrder(message);
    }
}
```

**Kafka 消费幂等**：

```java
@KafkaListener(topics = "order-topic")
public void onMessage(ConsumerRecord<String, String> record) {
    // Kafka 每条消息自带 offset + partition 作为唯一标识
    String idempotentKey = record.topic() + ":" + 
                           record.partition() + ":" + 
                           record.offset();
    // ... 同样使用去重逻辑
}
```

## 十一、幂等设计八大原则

1. **唯一标识先行**：每个写接口必须有唯一标识
2. **先查后写**：业务处理前先查询是否已处理
3. **幂等不依赖前端**：前端可以做防重复，但不能替代后端
4. **关键操作必须要幂等**：支付、下单、退款、发券
5. **读接口天然幂等**：GET、查询不需要幂等设计
6. **长时间超时要重试**：超时不等于失败，要做好重试准备
7. **去重记录要过期**：防止数据无限膨胀
8. **熔断降级不影响幂等**：熔断期间也要保证幂等

## 十二、总结

幂等性是分布式系统的"安全带"，不能没有。选择方案时：

- **简单场景** → 数据库唯一约束（最可靠）
- **通用场景** → Token 机制（最常用）
- **并发场景** → 分布式锁 + 状态机
- **消息场景** → 去重表/Redis 去重

记住一句话：**接口设计时假设一切都会重试，这样的系统才足够健壮。**

🔥 **面试追问准备**：
1. Token 方案的缺陷是什么？（占用存储、过期处理）
2. 分布式锁方案如何保证锁释放的安全性？
3. 去重表方案如何性能优化？（索引优化、分表、过期清理策略）
4. 在分布式事务（TCC/Seata）中，幂等是如何实现的？
