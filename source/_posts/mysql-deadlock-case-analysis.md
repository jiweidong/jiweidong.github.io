---
title: 【MySQL优化】死锁案例分析：从错误日志到彻底解决
date: 2026-07-02 08:00:00
tags:
  - MySQL
  - 数据库
  - 锁
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL优化】死锁案例分析：从错误日志到彻底解决

## 概述

MySQL 死锁是生产环境中最折磨人的问题之一。两个事务互相等待对方持有的锁，谁也不肯让步，InnoDB 只能通过回滚代价较小的事务来打破僵局。理解死锁的成因和排查方法是后端工程师的必备技能。

## 一、死锁的四个必要条件

MySQL InnoDB 的死锁需要同时满足以下四个条件：

| 条件 | 说明 | 举例 |
|------|------|------|
| 互斥 | 资源只能被一个事务持有 | 行锁、间隙锁 |
| 持有并等待 | 事务持有一个锁，同时等待另一个锁 | T1 持有 A 锁等待 B 锁 |
| 不可剥夺 | 事务释放前，其他事务不能强行夺取 | InnoDB 不支持下 |
| 循环等待 | 事务间形成等待环路 | T1 等 T2，T2 等 T1 |

InnoDB 默认开启死锁检测（`innodb_deadlock_detect = ON`），发现死锁后回滚**受影响事务中代价较小**的一个。

## 二、如何获取死锁信息

### 2.1 查看最新的死锁日志

```sql
-- 查看最近一次死锁详情
SHOW ENGINE INNODB STATUS\G
```

在输出中查找 `LATEST DETECTED DEADLOCK` 段。

### 2.2 开启死锁日志到错误日志

```ini
# my.cnf
innodb_print_all_deadlocks = ON
```

此配置会将每次死锁的详细信息记录到 MySQL error log，生产环境建议开启。

### 2.3 使用 performance_schema

```sql
-- 通过 performance_schema 监控锁等待
SELECT * FROM performance_schema.data_lock_waits\G

-- 查看当前持有锁的事务
SELECT * FROM performance_schema.data_locks\G
```

## 三、实战案例一：两个订单更新引起的死锁

### 场景描述

电商系统中，两个订单服务并发处理退款操作。

**表结构：**

```sql
CREATE TABLE `orders` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `order_no` varchar(32) NOT NULL COMMENT '订单号',
  `user_id` bigint(20) NOT NULL,
  `status` tinyint(4) NOT NULL DEFAULT '0',
  `amount` decimal(10,2) NOT NULL DEFAULT '0.00',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_order_no` (`order_no`),
  KEY `idx_user_id` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**并发 SQL 执行顺序：**

```
事务 A (退款订单1001和1002)        事务 B (退款订单1002和1001)
                                     BEGIN;
BEGIN;
UPDATE orders SET status=2          UPDATE orders SET status=2
  WHERE order_no='1001';              WHERE order_no='1002';
                                      -- 持有1002的行锁 ✅
UPDATE orders SET status=2          UPDATE orders SET status=2
  WHERE order_no='1002';              WHERE order_no='1001';
-- 等待 B 释放1002行锁 ❌             -- 等待 A 释放1001行锁 ❌
```

**死锁日志解读：**

```
------------------------
LATEST DETECTED DEADLOCK
------------------------
2026-07-02 08:15:23 0x7f1234567890
*** (1) TRANSACTION:
TRANSACTION 123456, ACTIVE 5 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 2 lock struct(s), heap size 1136, 2 row lock(s)
MySQL thread id 8, OS thread handle 14000, query id 100 localhost root updating
UPDATE orders SET status=2 WHERE order_no='1002'
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 123 page no 4 n bits 72 index uk_order_no of table `test`.`orders` 
trx id 123456 lock_mode X locks rec but not gap
Record lock, heap no 2 PHYSICAL RECORD: ...
--- 持有 order_no='1001' 的行锁

*** (2) TRANSACTION:
TRANSACTION 123457, ACTIVE 4 sec starting index read
mysql tables in use 1, locked 1
2 lock struct(s), heap size 1136, 2 row lock(s)
MySQL thread id 9, OS thread handle 14001, query id 101 localhost root updating
UPDATE orders SET status=2 WHERE order_no='1001'
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 123 page no 4 n bits 72 index uk_order_no of table `test`.`orders` 
trx id 123457 lock_mode X locks rec but not gap
Record lock, heap no 3 PHYSICAL RECORD: ...
--- 持有 order_no='1002' 的行锁

*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 123 page no 4 n bits 72 index uk_order_no of table `test`.`orders` 
trx id 123457 lock_mode X locks rec but not gap
Waiting for order_no='1001' 的行锁...

*** WE ROLL BACK TRANSACTION (2)
```

**解决方案：**

```java
// 方案一：统一加锁顺序（推荐）
// 按照订单号排序后再更新
public void refundOrders(List<String> orderNos) {
    orderNos.sort(String::compareTo); // 统一升序
    for (String orderNo : orderNos) {
        orderMapper.updateStatus(orderNo, 2);
    }
}

// 方案二：减少锁范围，将多笔update改为一次批量更新
@Update("UPDATE orders SET status=#{status} " +
        "WHERE order_no IN " +
        "<foreach collection='orderNos' item='no' open='(' separator=',' close=')'>#{no}</foreach>")
int batchUpdateStatus(@Param("orderNos") List<String> orderNos, @Param("status") int status);
```

## 四、实战案例二：间隙锁导致的死锁

### 场景描述

库存扣减时，先查询再更新，配合唯一索引。

**表结构：**

```sql
CREATE TABLE `inventory` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `sku_code` varchar(32) NOT NULL,
  `quantity` int NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_sku` (`sku_code`)
) ENGINE=InnoDB;
```

**数据状态：** 已有 4 条 sku 记录：`SKU001, SKU005, SKU010, SKU015`

**并发执行：**

```
事务 A: INSERT INTO inventory(sku_code, quantity) VALUES('SKU008', 100);
事务 B: INSERT INTO inventory(sku_code, quantity) VALUES('SKU012', 100);
事务 C: INSERT INTO inventory(sku_code, quantity) VALUES('SKU007', 100);
```

**执行时序：**
```
T1: 事务A INSERT SKU008 → 在(005,010)之间插入 → 获取间隙锁 (005,010) + 插入意向锁
T2: 事务B INSERT SKU012 → 在(010,015)之间插入 → 获取间隙锁 (010,015) + 插入意向锁  
T3: 事务C INSERT SKU007 → 在(005,010)之间插入 → 获取间隙锁并向A等待插入意向锁
                                                                                                                                                   T4: 事务A/事务B 的插入意向锁激活 → 互相等待
                                                                                                              → 死锁！
```

**原因分析：** 
- 插入意向锁（Insert Intention Lock）之间是**兼容的**，但间隙锁（Gap Lock）是**互斥的**
- 多个事务在相邻间隙插入时，相互等待对方的间隙锁释放，形成循环等待

**解决方案：**

```sql
-- 方案一：使用唯一索引/主键降级
-- 用分布式ID生成器确保skucode不冲突，使用 ON DUPLICATE KEY UPDATE
INSERT INTO inventory(sku_code, quantity) VALUES('SKU008', 100)
ON DUPLICATE KEY UPDATE quantity = quantity + VALUES(quantity);

-- 方案二：降低隔离级别（业务可接受的话）
-- 使用 READ COMMITTED 级别，InnoDB 不会加间隙锁
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- 方案三：预先对间隙加锁，序列化插入
SELECT * FROM inventory WHERE sku_code > 'SKU005' FOR UPDATE;
```

## 五、实战案例三：唯一索引冲突造成的死锁

### 场景描述

并发插入订单时，先检查是否存在，不存在则插入。典型的 "先查后插" 模式。

```sql
-- 业务代码伪代码
@Transactional
public void createOrder(Order order) {
    // Step 1: 查询是否存在
    Order exist = orderMapper.selectByOrderNo(order.getOrderNo());
    // Step 2: 不存在则插入
    if (exist == null) {
        orderMapper.insert(order);
    }
}
```

**并发导致死锁的过程：**

```
事务 A (order_no='ORD001')        事务 B (order_no='ORD001')
BEGIN;                               BEGIN;
SELECT * FROM orders                 SELECT * FROM orders  
  WHERE order_no='ORD001';             WHERE order_no='ORD001';
-- 结果为空                          -- 结果为空
INSERT INTO orders(...)              INSERT INTO orders(...)
  VALUES('ORD001',...);                VALUES('ORD001',...);
-- 持有唯一索引的 S 锁               -- 持有唯一索引的 S 锁
-- 尝试获取 X 锁，等待 B 释放 S ❌    -- 尝试获取 X 锁，等待 A 释放 S ❌
-- DEADLOCK!                         -- DEADLOCK!
```

**解决方案：**

```java
// 方案一：使用 INSERT IGNORE + 唯一索引（推荐）
@Insert("INSERT IGNORE INTO orders(order_no, user_id, amount, status) " +
        "VALUES(#{orderNo}, #{userId}, #{amount}, #{status})")
int insertIgnore(Order order);

// 方案二：分布式锁（对同一个订单做互斥）
public void createOrderWithLock(Order order) {
    String lockKey = "order:create:" + order.getOrderNo();
    RLock lock = redissonClient.getLock(lockKey);
    lock.lock(5, TimeUnit.SECONDS);
    try {
        Order exist = orderMapper.selectByOrderNo(order.getOrderNo());
        if (exist == null) {
            orderMapper.insert(order);
        }
    } finally {
        lock.unlock();
    }
}

// 方案三：SELECT ... FOR UPDATE（悲观锁）  
// 先锁住记录，防止并发插入
```

## 六、死锁排查 Checklist

| 排查步骤 | 命令/工具 | 检查要点 |
|----------|-----------|----------|
| 1. 获取死锁日志 | `SHOW ENGINE INNODB STATUS;` | 分析锁等待和事务 SQL |
| 2. 开启详细日志 | `innodb_print_all_deadlocks=ON` | 记录所有死锁到 error log |
| 3. 查看当前事务 | `SELECT * FROM information_schema.INNODB_TRX;` | 长时间未提交的事务 |
| 4. 查看锁等待 | `SELECT * FROM performance_schema.data_lock_waits;` | 等待链分析 |
| 5. 查看锁信息 | `SELECT * FROM performance_schema.data_locks;` | 锁类型和锁模式 |
| 6. 分析业务代码 | 检查 SQL 加锁顺序和事务大小 | 是否可统一加锁顺序 |

## 七、预防死锁的最佳实践

### 7.1 SQL 层面

1. **统一加锁顺序**：多行更新时，按主键或唯一键排序
2. **缩小事务范围**：不必要的操作移出事务
3. **使用相等条件**：WHERE 条件尽量使用等值查询，减少间隙锁
4. **合理使用索引**：无索引的条件会使行锁升级为表锁

### 7.2 应用层面

```java
// 重试机制：捕获 DeadlockLoserDataAccessException 后重试
@Retryable(value = {DeadlockLoserDataAccessException.class}, 
           maxAttempts = 3, backoff = @Backoff(delay = 100, multiplier = 2))
@Transactional
public void updateWithRetry() {
    // 可能发生死锁的业务逻辑
}
```

### 7.3 MySQL 参数层面

```ini
# 降低死锁检测开销
innodb_deadlock_detect = ON       # 默认开启，死锁频繁时考虑关闭
innodb_print_all_deadlocks = ON   # 生产开启

# 大并发下的优化
innodb_lock_wait_timeout = 50     # 锁等待超时（秒），默认50s
```

> **注意：** 极端高并发场景（如秒杀），`innodb_deadlock_detect=ON` 本身有性能开销。若确认无死锁风险（单行更新），可关闭死锁检测使用锁超时机制。

## 八、面试官追问

> Q1：死锁检测的代价有多大？

死锁检测通过 **等待图（Wait-for Graph）** 实现，每次加锁等待时都要遍历事务等待关系。当并发事务数很多（1000+）时，死锁检测的 CPU 开销显著。高并发场景下如果业务可接受锁超时报错，可考虑关闭死锁检测。

> Q2：INSERT 操作什么时候会加锁？

INSERT 在不同场景下加锁不同：
- **普通 INSERT**：在插入位置加 X 锁 + 插入意向锁
- **INSERT ... SELECT**：对 SELECT 的行加 S 锁（RR 级别下）
- **INSERT ON DUPLICATE KEY**：检查重复时加 S 锁，插入/更新时转 X 锁

> Q3：为什么 RR 级别下更容易死锁？

RR（REPEATABLE READ）级别下 InnoDB 使用**间隙锁（Gap Lock）**防止幻读。间隙锁是范围锁，极其容易形成锁等待环路。RC 级别无间隙锁，死锁概率显著降低。

## 九、结语

死锁排查的关键在于**理解锁类型**（行锁、间隙锁、临键锁、插入意向锁）和**事务间的加锁顺序**。面对死锁，先看 `SHOW ENGINE INNODB STATUS` 的 LATEST DETECTED DEADLOCK 段，按本文的方法分析锁等待链，问题通常能迎刃而解。

**一句话总结：统一加锁顺序 + 缩小事务范围 + 利用重试机制，死锁不再是噩梦。**
