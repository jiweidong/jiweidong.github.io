---
title: 【并发编程】乐观锁与悲观锁深度解析：CAS、版本号机制与数据库实现
date: 2026-08-18 08:00:00
tags:
  - Java
  - 并发
  - 乐观锁
  - 悲观锁
  - MySQL
  - 面试
categories:
  - Java
  - 并发编程
author: 东哥
---

# 【并发编程】乐观锁与悲观锁深度解析：CAS、版本号机制与数据库实现

## 面试官：你项目里扣库存，用的乐观锁还是悲观锁？

这是并发场景的"必考题"。很多人的答案是背出来的："悲观锁就是锁住，乐观锁就是 CAS"。但一问到"什么场景选哪个、各自的坑在哪"，就露馅了。

本文把乐观锁和悲观锁从思想、实现、源码到实战场景一次讲透。

---

## 一、两种锁的哲学

### 悲观锁（Pessimistic Lock）
**思想：冲突一定会发生，所以先锁再干。**

- 操作数据前先加锁，其他事务/线程必须等待；
- 数据库层面：`SELECT ... FOR UPDATE`、`SELECT ... LOCK IN SHARE MODE`；
- Java 层面：`synchronized`、`ReentrantLock`；
- 适用：写多读少、冲突概率高的场景。

### 乐观锁（Optimistic Lock）
**思想：冲突是少数，所以先干再验，冲突了重试。**

- 不加锁，更新时校验数据是否被改过（版本号/时间戳/CAS）；
- 数据库层面：`UPDATE ... SET version = version + 1 WHERE version = ?`；
- Java 层面：`AtomicInteger`、`LongAdder`、`StampedLock` 的乐观读；
- 适用：读多写少、冲突概率低的场景。

> 一个容易混淆的点：**乐观锁不是数据库或 Java 内置的"锁"，而是一种并发控制策略**。它靠"版本校验 + 条件更新"实现，没有传统意义上的加锁动作。

---

## 二、Java 层面：synchronized vs CAS

### 悲观锁的典型：synchronized / ReentrantLock

```java
// 悲观锁：同一时刻只有一个线程能进入
public synchronized void deductStock(int num) {
    int stock = stockMapper.getStock();   // 读
    if (stock < num) throw new BizException("库存不足");
    stockMapper.updateStock(stock - num); // 写
}
```

**注意这里的坑**：上面这段代码锁的是 JVM 内的对象，如果服务是集群部署（多实例），synchronized 只能锁住本实例，**跨实例的并发依然会超卖**。这引出了分布式锁的话题（Redis 分布式锁 / ZooKeeper 锁），但那是另一个维度——本文先聚焦单机 + 数据库层面。

### 乐观锁的典型：CAS（Compare And Swap）

```java
AtomicInteger stock = new AtomicInteger(100);
// 循环尝试，直到成功
while (true) {
    int current = stock.get();
    if (stock.compareAndSet(current, current - 1)) break;
}
```

CAS 的三个问题，面试必问：

**1. ABA 问题**：线程 A 读到 100，线程 B 改成 90 又改回 100，A 的 CAS 依然成功——中间状态被"抹掉"了。解决：加版本号，`AtomicStampedReference`。

```java
AtomicStampedReference<Integer> ref = new AtomicStampedReference<>(100, 0);
// 比较时同时比较引用值和版本号
ref.compareAndSet(100, 99, ref.getStamp(), ref.getStamp() + 1);
```

**2. 自旋开销**：高竞争下 CAS 一直失败重试，CPU 空转。JVM 有自适应自旋，但极端场景仍会退化。解决：LongAdder 分段累加，减少竞争。

**3. 只能保证单个变量的原子性**：多个变量要原子更新时，CAS 无能为力。解决：封装成对象用 `AtomicReference`，或加锁。

### 乐观读的进阶：StampedLock

```java
StampedLock lock = new StampedLock();
long stamp = lock.tryOptimisticRead();   // 乐观读，不加锁
int x = data;                            // 读
if (!lock.validate(stamp)) {             // 期间有写？验证版本
    stamp = lock.readLock();             // 升级为悲观读锁
    try { x = data; } finally { lock.unlockRead(stamp); }
}
```

**tryOptimisticRead 不是真正的锁**，它只记录一个版本戳，读完后 validate 校验期间有没有写操作。读多写少场景性能极佳。

---

## 三、数据库层面：行锁 vs 版本号

### 悲观锁：SELECT ... FOR UPDATE

```sql
-- 事务 A：锁住这条库存记录
START TRANSACTION;
SELECT stock FROM product WHERE id = 1 FOR UPDATE;
-- 事务 B 对同一行的 FOR UPDATE 会阻塞，直到 A 提交
UPDATE product SET stock = stock - 1 WHERE id = 1;
COMMIT;
```

**关键细节**：

- `FOR UPDATE` 是**当前读**（加的是排他锁），必须配合事务使用，事务提交/回滚才释放锁；
- 只有命中索引的行才会锁行，**没走索引会退化成锁表**（全表扫描所有行都加锁）；
- 在 InnoDB 下，`FOR UPDATE` 对不存在的行会加**间隙锁**（Gap Lock），可能引发死锁或锁范围扩大；
- **锁的粒度是行，不是"库存数字"**——同一条记录上的所有操作串行化，吞吐量受限。

### 乐观锁：版本号 + 条件更新

```sql
-- 1. 先查出版本号
SELECT id, stock, version FROM product WHERE id = 1;  -- version = 3
-- 2. 条件更新：版本号必须还是 3
UPDATE product
SET stock = stock - 1, version = version + 1
WHERE id = 1 AND version = 3;
-- 3. 影响行数 = 0 说明被别人改了，重试
```

**注意 `stock = stock - 1` 而不是 `stock = 旧值 - 1`**：直接在 SQL 里做减法，配合 `WHERE stock >= num` 可以做到**不读旧值、原子扣减**，这是数据库层面最优雅的扣库存写法：

```sql
UPDATE product SET stock = stock - #{num}
WHERE id = #{id} AND stock >= #{num};
-- 影响行数 = 1 扣减成功；= 0 库存不足或已被并发改掉
```

### 版本号 vs 条件扣减，选哪个？

| 方式 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| 版本号 | WHERE version = ? | 通用，任意字段可校验 | 每次更新多一次读；ABA 天然免疫 |
| 条件扣减 | WHERE stock >= num | 一条 SQL 原子完成 | 只适用于数值型业务规则 |

**实战建议**：扣库存这类"数值减少"业务，用条件扣减（SQL 层面原子）；"整行数据被谁改过"这类业务，用版本号。

---

## 四、扣库存完整方案对比

### 方案 A：悲观锁（SELECT FOR UPDATE + UPDATE）

```java
@Transactional
public void deductByPessimistic(Long productId, int num) {
    Product p = productMapper.selectByIdForUpdate(productId); // FOR UPDATE
    if (p.getStock() < num) throw new BizException("库存不足");
    productMapper.updateStock(productId, p.getStock() - num);
}
```

优点：实现简单，强一致。缺点：锁等待降低并发；**事务里持有锁时间越长，死锁概率越高**；需要事务包裹，长事务风险大。

### 方案 B：乐观锁版本号（循环重试）

```java
public void deductByOptimistic(Long productId, int num) {
    for (int i = 0; i < 3; i++) {   // 最多重试 3 次
        Product p = productMapper.selectById(productId);
        if (p.getStock() < num) throw new BizException("库存不足");
        int rows = productMapper.deductWithVersion(productId, num, p.getVersion());
        if (rows > 0) return;        // 成功
    }
    throw new BizException("系统繁忙，请重试");
}
```

优点：无锁等待，高并发吞吐好。缺点：冲突多时重试浪费 DB 资源；重试次数上限内没成功就失败。

### 方案 C：条件原子扣减（推荐）

```java
@Transactional
public boolean deductByCondition(Long productId, int num) {
    return productMapper.deductStockIfEnough(productId, num) > 0;
}
```

```sql
UPDATE product SET stock = stock - #{num} WHERE id = #{id} AND stock >= #{num}
```

**为什么推荐**：一条 SQL 原子完成"校验 + 扣减"，没有读-改-写窗口期，不需要显式版本号，行锁持有时间极短（仅此一条 UPDATE）。高并发秒杀场景下这是数据库层的首选。剩余库存不够时，配合 Redis 预扣减做前置过滤即可。

---

## 五、面试官连环追问

**Q1：synchronized 和 ReentrantLock 哪个是乐观锁？**
都不是，两者都是悲观锁（互斥）。Java 里真正的乐观锁是 CAS 一族（Atomic 类、LongAdder）。注意 **synchronized 有锁升级（偏向锁→轻量级锁→重量级锁）**，轻量级锁阶段本质是 CAS 自旋，但整体仍属悲观锁策略。

**Q2：乐观锁一定比悲观锁快吗？**
不一定。**竞争激烈时 CAS 自旋空转 + 大量重试，性能反而更差**；悲观锁的阻塞让出 CPU，系统整体更平稳。选型看冲突概率：读多写少用乐观锁，写多冲突多用悲观锁。

**Q3：MySQL 的 FOR UPDATE 和 Java 的 synchronized 有什么区别？**
范围不同：FOR UPDATE 锁的是**数据库行**，跨进程、跨实例生效（分布式环境有效）；synchronized 锁的是 **JVM 对象**，只在本进程内生效。**多实例部署必须用数据库锁或分布式锁，不能指望 synchronized**。

**Q4：版本号机制能防止 ABA 吗？**
能。版本号每次修改 +1，A→B→A 过程中版本号已经变了，CAS 校验版本号会失败。`AtomicStampedReference` 就是这个思路的 Java 实现。

**Q5：乐观锁重试会带来什么问题？**
一是数据库压力（每次重试都是一次 SELECT + UPDATE）；二是**重试期间业务时间戳可能过期**（如限时活动）；三是不适合写多场景。所以重试要有次数上限，且配合"库存不足/冲突"的降级策略。

**Q6：Redis 分布式锁算乐观锁还是悲观锁？**
setnx 实现的互斥锁本质是**悲观锁**（先锁后干）；而 Redis 的 WATCH + 事务、Lua 脚本条件更新则偏乐观锁思路。**锁的分类看"先锁后干"还是"先干后验"，与存储介质无关**。

---

## 六、总结

| 维度 | 悲观锁 | 乐观锁 |
|------|--------|--------|
| 核心思想 | 先锁后干 | 先干后验 |
| Java 实现 | synchronized、ReentrantLock | Atomic 类、CAS、StampedLock 乐观读 |
| 数据库实现 | SELECT ... FOR UPDATE | 版本号 / 条件更新 |
| 冲突处理 | 阻塞等待 | 重试 |
| 适用场景 | 写多、冲突高 | 读多、冲突低 |
| 主要风险 | 死锁、长事务、锁表 | ABA、自旋开销、重试压力 |

最后记住实战口诀：**单机并发用 synchronized/CAS，跨实例必须上分布式锁；数据库扣减优先条件原子更新，复杂业务用版本号；冲突多选悲观，冲突少选乐观**。把"哲学 + 实现 + 选型"三层都答出来，这道题就稳了。
