---
title: 【MySQL 实战】MySQL 批量插入性能优化：从 JDBC 批处理到 MyBatis-Plus 十万级数据写入
date: 2026-09-07 08:00:00
tags:
  - MySQL
  - 性能优化
  - JDBC
  - MyBatis-Plus
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 实战】MySQL 批量插入性能优化：从 JDBC 批处理到 MyBatis-Plus 十万级数据写入

## 场景：为什么批量插入会这么慢？

先看一个真实案例：某后台系统每天需要从 Excel 导入 10 万条订单数据，第一版代码用循环单条 INSERT，跑一次要 **40 分钟**，直接被业务方投诉。改成批量插入后，耗时降到 **20 秒以内**。

性能差距为什么这么大？我们先从 MySQL 执行一条 INSERT 的完整开销说起。

### 一条 INSERT 到底做了什么

一次单条 INSERT 的开销拆开看：

| 开销项 | 说明 | 量级 |
|---|---|---|
| 网络 RTT | 客户端与服务端一次往返 | 内网 0.1~0.5ms |
| SQL 解析 | 词法/语法/语义分析 | 0.01~0.1ms |
| 计划生成 | 优化器选择执行计划 | 0.01~0.1ms |
| 事务开销 | 开启事务、redo log 写入 | 0.1ms 级 |
| 索引维护 | B+ 树插入、页分裂 | 0.1~1ms |
| **fsync 刷盘**（默认每次提交） | 把 redo log 刷到磁盘 | **0.5~10ms** |

循环 10 万次单条插入 = 10 万次网络往返 + 10 万次 SQL 解析 + 10 万次事务提交刷盘。**瓶颈根本不在 SQL 本身，而在"次数"**——尤其每次提交的 fsync，是数量级上的杀手。

> 面试官追问：为什么说 fsync 是最大的开销？
> InnoDB 的 redo log 默认在每次事务提交时刷盘（`innodb_flush_log_at_trx_commit=1`），而一次磁盘 fsync 的延迟在机械盘上是毫秒级、SSD 上也要几百微秒。10 万次提交就是 10 万次刷盘，这是循环单条插入慢的根本原因。

## 第一板斧：JDBC 批处理（addBatch / executeBatch）

JDBC 规范提供了批处理 API：

```java
// ❌ 错误示范：循环单条插入
for (Order order : orderList) {
    PreparedStatement ps = conn.prepareStatement(INSERT_SQL);
    ps.setLong(1, order.getId());
    ps.executeUpdate();  // 每次都全链路走一遍
}

// ✅ 正确示范：批处理
try (PreparedStatement ps = conn.prepareStatement(INSERT_SQL)) {
    for (Order order : orderList) {
        ps.setLong(1, order.getId());
        ps.setString(2, order.getUserId());
        ps.addBatch();
        // 每 500 条提交一批，防止 batch 过大占内存
        if (batchCount % 500 == 0) {
            ps.executeBatch();
            ps.clearBatch();
        }
    }
    ps.executeBatch(); // 收尾
}
```

但很多人在用 `executeBatch()` 之后发现**性能没提升甚至更慢**——为什么？因为 MySQL 的 JDBC 驱动默认是**一条一条把 SQL 发给服务端**的！

### 关键参数：rewriteBatchedStatements

MySQL Connector/J 有一个默认关闭的开关：

```
jdbc:mysql://localhost:3306/test?rewriteBatchedStatements=true&useServerPrepStmts=false
```

- `rewriteBatchedStatements=false`（默认）：`addBatch` 只是把 SQL 攒在客户端，`executeBatch()` 时驱动仍然**逐条发送**，批处理形同虚设。
- `rewriteBatchedStatements=true`：驱动会把一批 `INSERT INTO t VALUES (?)` 重写成**一条多值 INSERT**：`INSERT INTO t VALUES (...),(...),(...)`，一次网络往返发送，服务端一次解析执行。

实测对比（内网环境、10 万条、单事务）：

| 方案 | 耗时 |
|---|---|
| 循环单条 INSERT（每次提交） | ~40 min |
| executeBatch（未开 rewrite） | ~35 min（几乎没提升） |
| executeBatch + rewriteBatchedStatements | ~8 s |
| 手工拼接多值 INSERT（每批 500 条） | ~6 s |

> ⚠️ 踩坑提醒：
> 1. `rewriteBatchedStatements` 对 `INSERT ... ON DUPLICATE KEY UPDATE` 也能重写，但对带 `SELECT` 的 `INSERT ... SELECT` 无效。
> 2. 开启后 `executeBatch` 的返回值语义会变（返回的是受影响行数合计，而不是每条一个 int[]），部分 ORM 依赖返回值时要注意。
> 3. 单批大小建议 200~1000 条：太小网络往返多，太大单条 SQL 超过 `max_allowed_packet`（默认 64MB）直接报错，且事务过大锁持有时间变长。

## 第二板斧：事务边界控制

批量插入时，**每批一个事务**而不是"十万条一个事务"或"每条一个事务"：

```java
Connection conn = dataSource.getConnection();
conn.setAutoCommit(false);          // 关闭自动提交
try {
    // ... 批处理循环，每 500 条 flush 一次
    conn.commit();                   // 最后统一提交
} catch (Exception e) {
    conn.rollback();
} finally {
    conn.setAutoCommit(true);
    conn.close();
}
```

- 每条一个事务：10 万次 fsync，最慢。
- 十万条一个事务：redo log 巨大、undo 膨胀，一旦失败**全部回滚**，还会拖垮从库（大事务导致主从延迟）。
- 每 500~1000 条一个事务：失败只回滚当前批次，且能配合"断点续导"定位到失败批次。

## 第三板斧：MyBatis / MyBatis-Plus 层优化

### 方式一：foreach 多值插入（XML）

```xml
<insert id="batchInsert" parameterType="list">
    INSERT INTO `order` (id, user_id, amount, status)
    VALUES
    <foreach collection="list" item="item" separator=",">
        (#{item.id}, #{item.userId}, #{item.amount}, #{item.status})
    </foreach>
</insert>
```

注意两点：
1. **必须拼接 `rewriteBatchedStatements=true` 意义不大**——因为 SQL 已经是一条多值语句，重点是把 `max_allowed_packet` 调大、控制每批条数。
2. MySQL 对单条 INSERT 的 VALUES 数量有限制吗？理论上没有硬限制，受 `max_allowed_packet` 约束，实践上每批 500~1000 条最稳。

### 方式二：MyBatis-Plus 的 saveBatch 到底快不快？

`IService.saveBatch(list)` 底层走的是 `SqlSessionTemplate` 的 **ExecutorType.BATCH** 执行器，代码在 `MybatisBatchUtils` / `SqlHelper` 中批量提交。它的逻辑是：

```java
// MyBatis-Plus 内部大致逻辑
SqlSession sqlSession = sqlSessionFactory.openSession(ExecutorType.BATCH);
try {
    for (int i = 0; i < list.size(); i++) {
        mapper.insert(list.get(i));
        if ((i + 1) % batchSize == 0) {
            sqlSession.flushStatements();  // 触发一次 executeBatch
        }
    }
} finally {
    sqlSession.close();
}
```

**注意**：MyBatis 的 `ExecutorType.BATCH` 只是把多条单行 INSERT 攒起来复用同一个 PreparedStatement 批量执行，**它依赖 JDBC 驱动层的批处理**——也就是说，如果连接串没开 `rewriteBatchedStatements=true`，MyBatis-Plus 的 `saveBatch` 也快不到哪里去！这是很多人的误区：以为换了 `saveBatch` 就万事大吉，其实关键在 JDBC URL 参数。

实测：MyBatis-Plus `saveBatch` 10 万条，
- 不开 `rewriteBatchedStatements`：约 30s；
- 开启后：约 5~8s。

### 方式三：真正快的方案——MySQL LOAD DATA

如果数据在文件里（或能先生成文件），`LOAD DATA LOCAL INFILE` 是 MySQL 批量导入的**天花板**：

```sql
LOAD DATA LOCAL INFILE '/tmp/orders.csv'
INTO TABLE `order`
FIELDS TERMINATED BY ',' 
LINES TERMINATED BY '\n'
(id, user_id, amount, status);
```

它绕过 SQL 解析层，直接走服务端导入引擎，10 万条只需 1~2 秒。Spring 里通过 `JdbcTemplate` 也能触发。缺点是要处理文件生成、字符集、唯一键冲突，适合离线/定时导入场景。

## 各种方案横评

| 方案 | 10万条耗时（内网参考） | 复杂度 | 适用场景 |
|---|---|---|---|
| 循环单条 INSERT | 30~40 min | 低 | 仅测试/低频 |
| JDBC executeBatch + rewrite | ~8 s | 低 | 通用首选 |
| MyBatis foreach 多值 | ~6 s | 低 | MyBatis 项目 |
| MyBatis-Plus saveBatch + rewrite | ~6 s | 极低 | 快速开发 |
| LOAD DATA INFILE | ~2 s | 中 | 离线大批量 |
| 多线程并发批量插入 | 视线程数 | 高 | 单表写入瓶颈后 |

## 多线程并发插入：什么时候用、怎么用才安全

单连接批处理到极限后（比如目标 100 万条、要求 30 秒内完成），可以上多线程：

```java
// 线程池 + 分片，每片一个连接
int total = 1_000_000;
int batch = 1000;
ExecutorService pool = Executors.newFixedThreadPool(8);
CountDownLatch latch = new CountDownLatch(total / batch);
for (int i = 0; i < total; i += batch) {
    List<Order> subList = data.subList(i, Math.min(i + batch, total));
    pool.submit(() -> {
        try (SqlSession session = sqlSessionFactory.openSession(ExecutorType.BATCH)) {
            OrderMapper mapper = session.getMapper(OrderMapper.class);
            for (Order o : subList) {
                mapper.insert(o);
            }
            session.commit();
        } finally {
            latch.countDown();
        }
    });
}
latch.await();
pool.shutdown();
```

必须注意的坑：
1. **连接数 = 线程数**，一个线程一个独立 Connection，别共享连接（连接不是线程安全的）。
2. 线程数别盲目加大：InnoDB 写入瓶颈常在磁盘 IO 和 redo log，8~16 个线程通常是甜点区，再往上可能反而变慢（锁竞争、上下文切换）。
3. 多线程+大事务会放大死锁概率，两个线程插入顺序不一致时尤其危险。**保证每个线程处理的数据在主键/唯一键上不重叠、插入顺序一致**。
4. 唯一键冲突时，`ON DUPLICATE KEY UPDATE` 与 `INSERT IGNORE` 会引入额外开销，能先清洗数据就别在库里兜底。

## 索引对插入的影响

插入慢的另一半原因常常是**索引太多**。每插一行，所有二级索引都要维护：

- 表上有 5 个二级索引，插入开销约为只有主键时的 5~6 倍；
- 二级索引列值随机（如 UUID 字符串），B+ 树节点频繁分裂，产生大量随机 IO；
- **建议：大批量导入前先评估能否临时删掉非必要二级索引，导入完成后再重建**（生产环境需走变更流程，评估期间查询影响）。

主键也尽量用自增/有序 ID：`AUTO_INCREMENT` 顺序写入，B+ 树只在最右页追加，几乎无页分裂；UUID 主键则会让索引页频繁"随机插入+分裂"，慢 5~10 倍且碎片严重。

## 面试连环问

**Q：`executeBatch()` 和循环 `executeUpdate()` 的本质区别？**
A：循环执行是"解析→执行→提交"反复全链路；批处理把多条 SQL 攒在一起。但注意 MySQL 驱动默认不重写 SQL，需要 `rewriteBatchedStatements=true` 才能合并为多值 INSERT 减少网络往返。

**Q：为什么加了 `rewriteBatchedStatements=true` 就能快一个数量级？**
A：默认情况下驱动把批里的每条 SQL 原样逐条发送，服务端逐条解析执行，网络往返次数没变；开启后驱动把同构的 INSERT 重写成一条多值语句，一次发送、一次解析、一次执行，网络 IO 和解析开销都摊薄到每条记录上。

**Q：批量插入时事务怎么控制最好？**
A：每 500~1000 条一个事务。太小则 fsync 频繁；太大则 redo/undo 膨胀、锁持有时间长、失败全回滚、拖慢从库。

**Q：MyBatis-Plus 的 `saveBatch` 为什么有时不快？**
A：它只是切换成 BATCH 执行器批量提交，底层仍走 JDBC 批处理。JDBC URL 没开 `rewriteBatchedStatements=true` 时驱动逐条发送，性能提升有限。另外批量大小默认 1000，要根据 `max_allowed_packet` 调整。

**Q：10 万条数据导入，让你设计最优方案，怎么答？**
A：分点：① 数据能落文件优先 `LOAD DATA`；② 否则 JDBC 批处理 + rewrite + 每 500~1000 条一事务；③ 先删非必要二级索引、保证主键有序；④ 必要时多线程分片并发（每线程独立连接、数据分片不重叠）；⑤ 失败可重试：记录断点或批次号，支持续导。

## 总结

批量插入优化的本质就一句话：**减少"次数"**——减少网络往返次数、减少 SQL 解析次数、减少事务提交/fsync 次数。落地优先级：先加 `rewriteBatchedStatements=true`（一行配置，收益最大），再控事务边界，然后考虑 foreach 多值/`saveBatch`，最后才是多线程和 LOAD DATA。生产环境务必用真实数据量压测，因为不同配置组合（batch size、线程数、索引数量）的差距可以达到 100 倍以上。
