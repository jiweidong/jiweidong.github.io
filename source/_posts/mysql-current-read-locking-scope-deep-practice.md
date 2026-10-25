---
title: 【MySQL 实战】一致性读与当前读深度实战：FOR UPDATE 加锁范围、库存扣减选型与锁等待排查
date: 2026-10-25 08:10:00
tags:
  - MySQL
  - InnoDB
  - 事务隔离
  - 锁
  - 高并发
  - Java
categories:
  - 数据库
author: 东哥
---

# 【MySQL 实战】一致性读与当前读深度实战：FOR UPDATE 加锁范围、库存扣减选型与锁等待排查

## 前言

库存扣减这个场景，把 MySQL 的「读语义」暴露得干干净净：

```sql
-- 方案 A：先查后改（90% 的人第一版代码）
SELECT stock FROM sku WHERE id = 100;
-- Java 里判断 stock >= 1
UPDATE sku SET stock = stock - 1 WHERE id = 100;
```

单机测试永远没问题，压测一上就超卖。因为它读的是**快照**（一致性读），查到的 stock 可能是 5 秒前的值；改的时候也没有「stock >= 1」的条件。

修完超卖之后，第二个问题来了：错误地加了 `FOR UPDATE` 但 `WHERE` 条件没走索引，锁从「行锁」升级成「表锁」，整个库的写操作全被堵住——**这比超卖更致命**。

这篇文章讲清楚：两种读语义到底差在哪、`FOR UPDATE` 的加锁范围由什么决定、库存扣减该选哪个方案、锁等待怎么定位。

---

## 一、一致性读 vs 当前读

InnoDB 有两种完全不同的读：

| | 一致性读（Consistent Read / 快照读） | 当前读（Current Read / 锁定读） |
|---|---|---|
| 触发方式 | 普通 `SELECT` | `SELECT ... FOR UPDATE`、`FOR SHARE`、`UPDATE`、`DELETE`、`INSERT` |
| 数据来源 | Undo Log 构造的历史版本（MVCC ReadView） | Buffer Pool 里的**最新已提交**版本 |
| 加锁 | ❌ 不加锁 | ✅ 加锁 |
| RC 下 | 每条语句新建 ReadView | 同左 |
| RR 下 | 事务内第一条快照读建 ReadView，**整个事务复用** | 同左 |
| 会阻塞吗 | 不会 | 会（锁冲突时） |

**关键认知**：`UPDATE` 语句里的 `WHERE` 条件是**当前读**——它必须看到最新值，否则「扣减」这件事就没有意义。所以：

```sql
-- 这一条是原子的、当前读、行锁，不会超卖
UPDATE sku SET stock = stock - 1 WHERE id = 100 AND stock >= 1;
```

`affected_rows = 0` 就代表库存不足，不需要先 SELECT。**这是最简单也最正确的方案**，后面会细说。

### RR 下的「快照」到底什么时候建立

这是面试必问、生产必踩的点：

```sql
-- 事务 A（RR）
START TRANSACTION;
SELECT * FROM sku WHERE id = 100;     -- ① 建立 ReadView（此刻 stock=10）
-- 事务 B 提交了 stock=5
SELECT * FROM sku WHERE id = 100;     -- ② 还是 10（复用 ReadView）
SELECT * FROM sku WHERE id = 100 FOR UPDATE;  -- ③ 5（当前读！）
COMMIT;
```

注意 ②③ 的差异：**同一个事务里，快照读和当前读会看到不同的值**。如果业务代码里「先 `SELECT` 判断，再 `UPDATE`」，而 `UPDATE` 又没带条件，就会基于过期快照做决策 → 超卖。如果带了条件，`WHERE stock >= 1` 是当前读，安全。

---

## 二、`FOR UPDATE` 的加锁范围由什么决定

一句话：**由「能否精确定位到唯一一行」决定**。分三种情况：

```sql
CREATE TABLE sku (
  id BIGINT PRIMARY KEY,
  sku_code VARCHAR(32) NOT NULL,
  stock INT NOT NULL,
  status TINYINT NOT NULL,
  KEY idx_code (sku_code),        -- 普通索引
  UNIQUE KEY uk_code (sku_code)   -- 假设这里是唯一索引的场景
) ENGINE=InnoDB;
```

| `WHERE` 条件 | RR 下的加锁范围 | 说明 |
|---|---|---|
| 主键等值：`id = 100` | 该行**聚簇索引记录锁** | 最理想 |
| 唯一索引等值（值存在）：`sku_code = 'A1'` | 唯一索引记录锁 + 对应聚簇索引记录锁 | 两把锁，但都是行级 |
| 唯一索引等值（值**不**存在） | **间隙锁**（Gap Lock） | 防幻读，锁住「值该插入的位置」 |
| 普通索引等值：`status = 1` | 命中行的记录锁 + 间隙锁（Next-Key Lock） | 会锁住 status=1 的整个区间 |
| 无索引条件：`remark = 'x'` | **全表所有 Next-Key Lock（近似表锁）** | 灾难，等于 `LOCK TABLES` |
| 范围条件：`id > 100 AND id < 200` | 区间内所有 Next-Key Lock | 范围多大锁多大 |

**所以第二条军规是：`FOR UPDATE` / `UPDATE` / `DELETE` 的 `WHERE` 必须走索引，且优先走主键或唯一索引。**

一个真实的锁升级案例：

```sql
-- 本想锁一行
SELECT * FROM sku WHERE status = 1 AND id = 100 FOR UPDATE;
```

优化器可能会选 `idx_status`（如果 status 的选择性统计被采样错误，或者 status=1 的行很少）。一旦走了 `idx_status`，它要先在 `idx_status` 上锁住「status=1 的整个区间」，再回表——**锁的范围从 1 行变成了「所有 status=1 的行」**。

用 `EXPLAIN` 确认，必要时强制索引：

```sql
EXPLAIN SELECT * FROM sku WHERE status = 1 AND id = 100 FOR UPDATE;
-- 出现 type=ALL 或 key=idx_status 都要警惕

SELECT * FROM sku FORCE INDEX(PRIMARY) WHERE status = 1 AND id = 100 FOR UPDATE;
```

### 两个常被忽略的加锁细节

1. **`FOR UPDATE` 不加锁的情况**：如果查询在 `WHERE` 里用到了**索引条件下推（ICP）**之外的非索引列过滤，InnoDB 会「先锁住索引命中的行，回表后再过滤」，**过滤掉的行也会被短暂加锁**（Server 层会解锁，但存在锁持有窗口）。这就是「明明只更新一行，却锁了一堆」的来源。

2. **`INSERT ... ON DUPLICATE KEY UPDATE` 的锁**：对唯一索引冲突插入时，会先加**间隙锁**再升级，高并发下极易死锁。电商的「加购/计数」场景要特别注意。

---

## 三、`FOR UPDATE` 家族的其他成员

| 语法 | 语义 | 场景 |
|---|---|---|
| `FOR UPDATE` | 排他锁（X） | 扣库存、状态机流转 |
| `FOR SHARE`（旧版 `LOCK IN SHARE MODE`） | 共享锁（S） | 读一份不允许被改的数据（很少用，容易死锁） |
| `FOR UPDATE NOWAIT` | 拿不到锁立即报错 | 用户交互型操作，不能等 |
| `FOR UPDATE SKIP LOCKED` | 跳过已锁行 | **任务队列抢单**（完美用法） |
| `FOR UPDATE OF t1` | 只锁指定表 | 多表 join |

`SKIP LOCKED` 是「用 MySQL 当轻量队列」的标准写法：

```sql
-- 多个 worker 并发抢任务，不会互相阻塞
SELECT id FROM job
WHERE status = 'PENDING'
ORDER BY id
LIMIT 10
FOR UPDATE SKIP LOCKED;

-- 然后在同一事务里 UPDATE status = 'RUNNING'
```

```java
@Transactional
public List<Job> fetchBatch(int size) {
    List<Job> jobs = jobMapper.selectPendingForUpdateSkipLocked(size);
    if (!jobs.isEmpty()) {
        jobMapper.markRunning(jobs.stream().map(Job::getId).toList());
    }
    return jobs;
}
```

注意：走 `status` 索引时依然是 Next-Key Lock，`SKIP LOCKED` 只影响「遇到已锁行怎么办」，不影响锁的范围。所以 `status` 的取值分布要合理（别用低区分度字段）。

---

## 四、库存扣减：四种方案的真实取舍

| 方案 | 并发安全 | QPS 上限 | 一致性 | 适用 |
|---|---|---|---|---|
| A. `UPDATE ... WHERE stock >= n` 原子扣减 | ✅ | 单行 1k~3k | 强 | 中小流量、库存准确性优先 |
| B. `SELECT ... FOR UPDATE` + 判断 + `UPDATE` | ✅ | 单行 500~1k（锁串行） | 强 | 需要「读后决策」的复杂业务 |
| C. 乐观锁（version / stock 条件） | ✅ | 单行 1k~3k，但失败率高 | 强 | 冲突少、可重试 |
| D. Redis 预扣 + 异步落库 | ✅（最终） | 10w+ | 最终 | 大促秒杀 |

### 方案 A：最推荐的第一选择

```java
@Mapper
public interface SkuMapper {
    @Update("""
        UPDATE sku SET stock = stock - #{n}, version = version + 1
        WHERE id = #{id} AND stock >= #{n}
        """)
    int deduct(@Param("id") long id, @Param("n") int n);
}
```

```java
@Transactional(rollbackFor = Exception.class)
public void deduct(long skuId, int n) {
    int rows = skuMapper.deduct(skuId, n);
    if (rows == 0) {
        throw new BizException("库存不足");
    }
    stockLogMapper.insert(new StockLog(skuId, -n));  // 流水
}
```

优点：一条 SQL、当前读、行锁、无锁等待放大、天然幂等边界清晰。
注意：**`stock >= n` 这个条件必须在 `WHERE` 里**，不能只在 Java 里判断。

### 方案 B：什么时候必须用 `FOR UPDATE`

当「扣减决策」依赖多个字段的组合判断，且不能在一条 SQL 里表达时：

```java
@Transactional(rollbackFor = Exception.class)
public void placeOrder(long skuId, int qty, long userId) {
    // 必须锁住这一行，后续判断才有效
    Sku sku = skuMapper.selectForUpdate(skuId);   // SELECT ... FOR UPDATE
    if (sku.getStatus() != 1) throw new BizException("商品已下架");
    if (sku.getStock() < qty) throw new BizException("库存不足");
    if (sku.getLimitPerUser() > 0 && userBought(userId, skuId) + qty > sku.getLimitPerUser()) {
        throw new BizException("超出限购");
    }
    skuMapper.deduct(skuId, qty);
}
```

**代价**：锁持有时间 = 从 `SELECT FOR UPDATE` 到 `COMMIT`，其中包括了 `userBought` 的查询（可能还查别的库）。这段时间的并发全部串行。

优化：把「不需要锁的判断」提到锁外，把「需要锁的判断」压到锁内：

```java
// 锁外做无副作用的预检查（快速失败，减少抢锁）
Sku snapshot = skuMapper.selectById(skuId);
if (snapshot.getStatus() != 1) throw new BizException("商品已下架");

// 锁内只做必须原子的判断
Sku sku = skuMapper.selectForUpdate(skuId);
if (sku.getStock() < qty) throw new BizException("库存不足");
skuMapper.deduct(skuId, qty);
```

### 方案 C：乐观锁的失败率

```sql
UPDATE sku SET stock = stock - #{n}, version = version + 1
WHERE id = #{id} AND version = #{version} AND stock >= #{n};
```

重试 3 次都失败就降级为 `BizException`。**冲突率高时，乐观锁会退化成「大量无效重试 + DB 压力翻倍」**，这是很多人踩过的坑：QPS 1000 时，如果同一行的并发是 50，那重试率接近 98%，实际 DB 请求变成 2000+。所以乐观锁只适合「冲突行分散」的场景（比如按 userId 分片的余额）。

### 方案 D：Redis 预扣（大促必备）

```
Lua 脚本原子扣减 Redis 库存 → 发 MQ → 异步落 MySQL → 对账补偿
```

Java 侧核心是 Lua 保证「判断 + 扣减」原子：

```java
private static final String DEDUCT_LUA = """
    local stock = tonumber(redis.call('GET', KEYS[1]))
    if stock == nil then return -1 end
    local n = tonumber(ARGV[1])
    if stock < n then return 0 end
    redis.call('DECRBY', KEYS[1], n)
    return 1
    """;

public boolean tryDeduct(long skuId, int n) {
    Long r = redis.execute(new DefaultRedisScript<>(DEDUCT_LUA, Long.class),
            List.of("stock:" + skuId), String.valueOf(n));
    return r != null && r == 1L;
}
```

代价是**对账**：必须有「Redis 与 DB 库存差异」的定时校准，否则 Redis 挂了/重启就全乱。这套方案的复杂度是方案 A 的 10 倍，**没有秒杀流量不要上**。

---

## 五、锁等待与死锁排查

### 5.1 实时看谁在等谁

```sql
-- MySQL 8.0
SELECT
  r.trx_id waiting_trx_id,
  r.trx_mysql_thread_id waiting_thread,
  r.trx_query waiting_query,
  b.trx_id blocking_trx_id,
  b.trx_mysql_thread_id blocking_thread,
  b.trx_query blocking_query
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID
JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID;
```

看具体锁在哪个索引、哪一行：

```sql
SELECT * FROM performance_schema.data_locks
WHERE OBJECT_NAME = 'sku' ORDER BY INDEX_NAME, LOCK_DATA;
-- LOCK_MODE: X,REC_NOT_GAP  → 行锁（理想）
--            X,GAP           → 间隙锁（注意）
--            X               → Next-Key Lock
--            X,TABLE         → 表级意向锁（危险）
```

一把锁在 `LOCK_MODE` 里出现 `GAP` 或没有 `REC_NOT_GAP`，基本可以断定是索引问题。

### 5.2 死锁日志怎么看

```sql
SHOW ENGINE INNODB STATUS\G
-- 找 LATEST DETECTED DEADLOCK 段
```

死锁日志的关键信息：

```
*** (1) TRANSACTION:
TRANSACTION 1234, ACTIVE 3 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 2 lock struct(s), heap size 1136, 1 row lock(s)
UPDATE sku SET stock = stock - 1 WHERE sku_code = 'A1' AND status = 1
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS ... index `idx_status` ... 
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS ... index `PRIMARY` ...
```

读法：**「持有 idx_status 的锁，等待 PRIMARY 的锁」+ 另一事务相反** → 典型的两条不同索引路径交叉死锁。解决办法：**让两个事务走同一条索引路径**（加 `FORCE INDEX` 或统一查询条件），或者按固定顺序加锁。

### 5.3 三条防死锁的工程手段

1. **统一加锁顺序**：多行更新时 `ORDER BY id` 排序后依次加锁。
2. **缩短事务**：不要在事务里做 RPC、发 MQ、写日志文件。事务里只有 DB 操作。
3. **降低隔离级别到 RC**（业务允许时）：RC 下没有间隙锁，死锁概率大幅下降。这也是很多互联网公司默认 RC 的原因。代价是「不可重复读」和需要 binlog 用 ROW 格式。

---

## 六、Java 侧三个必踩的坑

### 坑 1：`@Transactional` 失效导致锁提前释放

```java
public void service(Long id) {          // ← 没有 @Transactional
    repo.selectForUpdate(id);            // 自己一个事务，立刻提交，锁释放！
    // 这里已经没锁了
    repo.deduct(id, 1);
}
```

`FOR UPDATE` 的锁只在**事务内**有效。没有事务包裹，`SELECT FOR UPDATE` 执行完就自动提交并释放锁。**这是最常见的「加了 FOR UPDATE 还超卖」的原因**。

### 坑 2：锁等待超时太短 / 太长

```sql
-- 会话级
SET SESSION innodb_lock_wait_timeout = 5;
```

```yaml
# 连接串上带超时，避免默认 50s 把线程池拖死
spring:
  datasource:
    url: jdbc:mysql://...:3306/db?sessionVariables=innodb_lock_wait_timeout=3
```

锁等待超时后会抛 `LockWaitTimeoutException`，**此时事务被回滚但可能已经产生部分副作用**（如果之前有非事务性操作，如 MQ 已经发出）。所以超时值要和「HikariCP 的 connectionTimeout」+「Tomcat 线程超时」做全局预算分配：`锁等待 3s < 连接超时 5s < 接口超时 8s`。

### 坑 3：`SELECT FOR UPDATE` 查出大量数据 + `LIMIT`

```sql
-- 想锁 10 条，但 ORDER BY 走的是无索引字段
SELECT * FROM job WHERE status = 'PENDING' ORDER BY create_time LIMIT 10 FOR UPDATE;
```

如果 `create_time` 没有索引，MySQL 会**先扫描全表 → 排序（filesort）→ 取 10 条**，而扫描过程中命中的行**都可能被加锁**（RR 下 Next-Key Lock）。正确做法是给 `(status, create_time)` 建联合索引，让 `ORDER BY` 走索引，锁范围就收敛到 `status='PENDING' AND create_time < ...` 这一段。

---

## 七、面试追问

**Q1：为什么 `UPDATE` 不需要先 `SELECT`？**
因为 `UPDATE ... WHERE` 本身就是当前读 + 行锁 + 原子执行，`WHERE stock >= 1` 保证「判断与修改」在同一原子操作内。先 SELECT 反而引入了「快照过期」和「额外 RTT」两个问题。

**Q2：RR 下 `SELECT FOR UPDATE` 能防幻读吗？**
能。间隙锁（Gap Lock）锁住「不存在的区间」，别的事务无法在该区间插入。但 RC 下没有间隙锁，所以 RC 无法防幻读。

**Q3：为什么唯一索引等值查询「值不存在」时还要加间隙锁？**
正是为了防幻读——如果只查不锁，别的事务可以插入这个值，导致同一事务两次查询结果不同。

**Q4：`UPDATE` 的行数 = 0 但没报错，可能是什么原因？**
三种可能：① `WHERE` 没命中任何行；② 命中了但新值与原值相同（`affected_rows` 返回 0，`changed_rows` 才算真修改），此时 MySQL 默认不更新也不加 `UPDATE_TIME`；③ 被别的会话锁住后超时（会抛异常，不是返回 0）。判断时要看 `affected_rows` 而不是「是否抛异常」。

**Q5：`IN` 查询里包含不存在的值，`FOR UPDATE` 会锁多少行？**
如果是主键 `IN (1,2,999)`，会锁 1、2 两行，并对 999 所在的间隙加间隙锁（RR）。所以 `IN` 列表里塞了大量不存在的 ID 时，锁范围会意外扩大。

**Q6：`SELECT ... FOR UPDATE` 在从库上执行会怎样？**
从库默认 `read_only`，加锁读会报错或不允许（取决于 `super_read_only`）。所有加锁读必须走主库。读写分离的框架（ShardingSphere、MyBatis 拦截器）通常只按「是否写 SQL」路由，`SELECT FOR UPDATE` 需要**显式强制主库**，这是读写分离项目里经典的「刚下单查不到」问题根源。

---

## 八、总结

1. 普通 `SELECT` 是快照读，`FOR UPDATE`/`UPDATE`/`DELETE` 是当前读，两者在同一事务内可能看到不同的值。
2. 扣库存首选 `UPDATE ... WHERE stock >= n`，一条 SQL 解决判断 + 修改 + 加锁。
3. `FOR UPDATE` 的锁范围由索引决定：主键/唯一索引等值 → 行锁；普通索引 → Next-Key Lock；无索引 → 近似表锁。
4. `FOR UPDATE` 必须在事务内，否则锁立刻释放（最常见的超卖原因）。
5. 用 `performance_schema.data_locks` 看 `LOCK_MODE`，出现 `GAP` 就是索引没走对。
6. 防死锁三板斧：统一加锁顺序、缩短事务、降级到 RC。
7. 高并发到 Redis 预扣之前，先把方案 A 的性能压榨干净——绝大多数业务根本到不了需要 Redis 扣库存的量级。
