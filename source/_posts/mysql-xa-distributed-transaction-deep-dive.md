---
title: 【MySQL 底层】XA 分布式事务深度解析：两阶段提交、InnoDB XA 实现与生产取舍
date: 2026-10-01 08:00:00
tags:
  - Java
  - MySQL
  - 分布式事务
  - XA
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 底层】XA 分布式事务深度解析：两阶段提交、InnoDB XA 实现与生产取舍

## 面试官：说说你了解的分布式事务方案

候选人一般会背出：2PC、3PC、TCC、Saga、本地消息表、最大努力通知。然后面试官会追一句：

> "那 MySQL 自带的 XA 事务你用过吗？它内部是怎么实现 Prepare 的？为什么那么多公司最后都放弃了 XA？"

这一问就筛掉一大半人。XA 是分布式事务里"看起来最正统、用起来最难受"的方案，理解它的实现原理，比背方案列表有价值得多。

## 一、XA 要解决什么问题

单机事务里，MySQL 靠 redo log + undo log 保证 ACID。但当一笔业务要**同时写入多个独立的数据库实例**时：

```
下单 → 订单库(order_db).insert(order)
     → 库存库(stock_db).update(stock)
     → 账户库(account_db).update(balance)
```

三个库三个连接，各自是独立事务，谁来保证"要么全成功，要么全回滚"？

XA 的答案：**引入一个协调者（Transaction Coordinator），把提交拆成两个阶段，用"准备"来换取"最终一致"。**

## 二、X/Open XA 规范

XA 规范由 X/Open 组织定义，包含两个角色和一组接口：

| 角色 | 职责 |
| --- | --- |
| RM（Resource Manager） | 资源管理器，如 MySQL Server |
| TM（Transaction Manager） | 事务管理器，如 Seata、Atomikos、Bitronix |

接口分两组：

- **TM 调用 RM（xa_ 前缀）**：`xa_start`、`xa_end`、`xa_prepare`、`xa_commit`、`xa_rollback`、`xa_recover`
- **应用调用 TM（TX_ 前缀）**：`TX_open`、`TX_begin`、`TX_commit`、`TX_rollback`

MySQL 实现了前者。你可以在 MySQL 里直接手敲这些命令：

```sql
XA START 'xid-001';
UPDATE stock SET count = count - 1 WHERE goods_id = 1001;
XA END 'xid-001';
XA PREPARE 'xid-001';

-- 另一个连接
XA START 'xid-002';
UPDATE balance SET amount = amount - 100 WHERE user_id = 1;
XA END 'xid-002';
XA PREPARE 'xid-002';

-- 协调者决定提交
XA COMMIT 'xid-001';
XA COMMIT 'xid-002';
```

XID（事务标识符）由三部分组成：

```
gtrid  : 全局事务 ID
bqual  : 分支限定符（每个 RM 分支唯一）
formatID: 格式标识
```

MySQL 里 XID 最长 128 字节，`gtrid` ≤ 64 字节，`bqual` ≤ 64 字节。这就是为什么很多框架用 UUID 拼接时会突然报 "XID too long"。

## 三、两阶段提交（2PC）的详细流程

```
        TM (协调者)
          │
   ┌──────┼──────┐
   │      │      │
  RM1    RM2    RM3
  (prep) (prep) (prep)     ← 阶段一：Prepare
   │      │      │
   └──────┼──────┘
          │  全部 OK ？
          ▼
   commit / rollback       ← 阶段二：Commit
```

**阶段一（Prepare）**：TM 向所有 RM 发送 prepare。RM 执行事务的所有写操作，**写 redo，但不写 commit 标记**，把事务置于 `PREPARED` 状态，持有行锁，然后返回 OK 或失败。

**阶段二（Commit）**：如果所有 RM 都 OK，TM 广播 commit，RM 落 commit 标记并释放锁；任一失败则广播 rollback。

### 2PC 的三个致命缺陷

1. **同步阻塞**：Prepare 之后，所有 RM 的行锁一直持有，直到阶段二结束。参与方越多、协调者越慢，锁等待越久，吞吐断崖式下跌。
2. **协调者单点**：TM 在阶段一之后崩溃，RM 就永远卡在 `PREPARED` 状态，锁不释放。这是最被诟病的问题。
3. **数据不一致**：阶段二中部分 RM commit 成功、部分网络超时，就出现"部分提交"。只能靠人工或补偿。

## 四、InnoDB 内部：XA 是怎么落盘的

这是本文最硬核的部分。MySQL 的 XA 并非独立引擎，而是**复用了 InnoDB 的两阶段提交机制**。

### 4.1 三个关键结构

**1）事务对象上的 XA 状态**

`trx_t` 中有一个 `xid_t xid` 字段，`trx->state` 会经历：

```
TRX_STATE_ACTIVE → TRX_STATE_PREPARED → TRX_STATE_COMMITTED_IN_MEMORY
```

**2）undo 段上的 XA 标记**

`XA PREPARE` 时，InnoDB 会把事务的 undo 段 `TRX_UNDO_PREPARED` 标记写进 **undo log header**，并把 XID 追加写入 undo 页。在 `rollback segment array` 的 `insert_undo_list` 里，该事务被移动到"已 prepared"链表。

**3）Prepared 事务的持久化与恢复**

关键点：**Prepare 阶段必须落盘**，否则崩溃后无法恢复。但 MySQL 又不想为 XA 单独引入一套日志，于是它这样做：

- 在 prepare 阶段，InnoDB 写一条 **XA PREPARE 日志**到 redo log（`MLOG_XA_PREPARE`）；
- 同时确保 **binlog 中不写 prepare 记录**；
- 只有到阶段二 commit 时，才写 binlog 并落 redo 的 commit 标记。

崩溃恢复时，InnoDB 扫描 redo log，遇到 `MLOG_XA_PREPARE` 就把该事务收集起来，再结合 undo 段的 XA 标记重建 prepared 事务列表。`XA RECOVER` 命令读的正是这份列表：

```sql
mysql> XA RECOVER;
+----------+--------------+--------------+------+
| formatID | gtrid_length | bqual_length | data |
+----------+--------------+--------------+------+
|        1 |            7 |            3 | xid1 |
+----------+--------------+--------------+------+
```

> 注意：`XA RECOVER` 只列出**当前会话有权限看到**的 prepared 事务。5.7 之前还要求连接不能处于 XA 状态内。

### 4.2 为什么"挂了之后数据不一致"

经典故障：`XA COMMIT` 只成功了一半，然后 TM 挂了。此时：

- RM1 已 commit，行锁释放，数据可见；
- RM2 仍处于 `PREPARED`，**行锁未释放**，其他事务阻塞。

其他会话的 `update` 会一直等锁，看起来像"数据库卡死了"。排查方法：

```sql
-- 找到 prepared 事务
XA RECOVER;

-- 看谁在持锁
SELECT * FROM performance_schema.data_locks WHERE LOCK_STATUS = 'GRANTED';
SELECT * FROM performance_schema.data_lock_waits;

-- 看阻塞源头
SELECT trx_id, trx_state, trx_started, trx_mysql_thread_id
FROM information_schema.innodb_trx
WHERE trx_state = 'PREPARED';
```

这正是 2PC 缺陷 3 的真实写照，也是 XA 在生产中被嫌弃的第一原因。

## 五、Java 侧的 XA：谁在当 TM

### 5.1 原生 JDBC 的 XAConnection

MySQL Connector/J 提供了 `MysqlXAConnection`：

```java
MysqlDataSource ds = new MysqlDataSource();
ds.setUrl("jdbc:mysql://db1:3306/order_db");
XAConnection xaConn = ds.getXAConnection();
XAResource xaRes = xaConn.getXAResource();
Xid xid = new MysqlXid("gtrid".getBytes(), "bqual1".getBytes(), 1);

xaRes.start(xid, XAResource.TMNOFLAGS);
// ... 执行业务 SQL ...
xaRes.end(xid, XAResource.TMSUCCESS);
int rc = xaRes.prepare(xid);       // 阶段一
if (rc == XAResource.XA_OK) {
    xaRes.commit(xid, false);      // 阶段二
}
```

但**没人会手写这个**，因为要自己实现 TM 的日志、恢复、超时补偿。实际项目都用容器管理：

### 5.2 Atomikos / Bitronix（JTA 实现）

```java
@Bean(initMethod = "init", destroyMethod = "close")
public UserTransactionManager userTransactionManager() {
    UserTransactionManager tm = new UserTransactionManager();
    tm.setForceShutdown(false);
    tm.setTransactionTimeout(30);
    return tm;
}
```

然后配合 `AtomikosDataSourceBean` 包装多个物理数据源，用 `@Transactional` 交给 JTA 管理。缺点是：**JTA 是同步阻塞的，连接池必须长期持有 XA 连接，性能损耗大**。

### 5.3 Seata 的 XA 模式

Seata 1.2 之后提供 XA 模式，把 TM 抽到 Seata Server：

```java
// 数据源代理需替换为 DataSourceProxyXA
@Bean
public DataSource dataSource(DruidDataSource druid) {
    return new DataSourceProxyXA(druid);
}
```

```yaml
seata:
  data-source-proxy-mode: XA
```

Seata XA 模式解决了 2PC 的两个工程问题：

1. **协调者高可用**：Seata Server 集群 + 事务日志表 `global_table` / `branch_table`，协调者挂了可以恢复；
2. **分支事务自动补偿**：阶段二失败可重试。

但**同步阻塞的本质没变**，因此 Seata 官方更推荐 AT 模式。

## 六、XA 与 binlog 的纠葛（面试加分项）

这是很多人不知道的细节：**XA 事务在 prepare 阶段不能写 binlog 到磁盘（不含 commit 标记）**。

原因在于 MySQL 的**组提交（Group Commit）**设计：

```
binlog 落盘 ←→ InnoDB 提交
     ↑ 必须保证二者原子
```

`binlog_order_commits` 和 `binlog_group_commit_sync_delay` 这类参数在 XA 场景下要格外小心。如果 binlog 在 prepare 时写入了但事务最终 rollback，从库就会多出一个"幻影事务"。

所以 MySQL 的处理是：

| 阶段 | redo log | binlog | 锁 |
| --- | --- | --- | --- |
| Prepare | 写，含 `MLOG_XA_PREPARE` | 不写 | 持有 |
| Commit | 写 commit 标记 | 写并落盘 | 释放 |
| Rollback | 写 rollback | 不写 | 释放 |

另外，**XA 事务不能跨 binlog 的 `XA PREPARE` 边界做 crash-safe 恢复**，除非开启 `innodb_support_xa`（5.7 默认 ON；8.0 该参数已废弃，XA 支持改为默认强制）。

## 七、生产实践：XA 的三个真实约束

### 约束 1：全局锁持有时间 = 网络 RTT × 参与者数量

假设 3 个库，Prepare 到 Commit 间隔 20ms，QPS 1000，那么平均会有 `1000 × 3 × 0.02 = 60` 个事务同时持锁。若某库慢查询把 Prepare 拖到 200ms，持锁事务瞬间到 600，锁冲突率飙升。

**缓解**：把所有参与库放在同一机房（RTT < 1ms），`innodb_flush_log_at_trx_commit` 视情况调整，但**不要为了 XA 把它设成 2**，那会牺牲崩溃安全性。

### 约束 2：连接池要支持 XA

普通 HikariCP 连接不能直接参与 XA（`XAConnection` 需要池化 `XAConnection` 而非 `Connection`）。所以要么用 Atomikos 的 `AtomikosDataSourceBean`，要么用 Seata 的 `DataSourceProxyXA`。**这也是很多团队 XA 落地的第一个坑**。

### 约束 3：prepared 事务需要巡检

线上必须有巡检脚本，定期执行 `XA RECOVER`，发现超过阈值时间的 prepared 事务就告警：

```sql
SELECT trx_id, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS held_seconds
FROM information_schema.innodb_trx
WHERE trx_state = 'PREPARED'
  AND TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60;
```

人工处理：

```sql
XA COMMIT 'xid1';     -- 或者
XA ROLLBACK 'xid1';
```

决策依据是**其他分支是否已提交**——如果其他分支都提交了，这里就必须 commit；否则出现不一致。

## 八、XA vs 其他分布式事务方案

| 方案 | 一致性 | 性能 | 侵入性 | 适用场景 |
| --- | --- | --- | --- | --- |
| XA / 2PC | 强一致 | 差（同步阻塞） | 低（对业务透明） | 少量库、低并发、强一致要求 |
| TCC | 最终一致 | 好 | 高（需写三个方法） | 金融核心、可拆分业务 |
| Saga | 最终一致 | 好 | 中（需补偿） | 长流程、多服务 |
| 本地消息表 | 最终一致 | 好 | 中 | 跨服务、可接受延迟 |
| 最大努力通知 | 最终一致 | 最好 | 低 | 对账、通知类 |
| Seata AT | 最终一致 | 较好 | 低 | 大多数微服务场景 |

**一句话结论**：如果业务能接受最终一致，就别用 XA；如果业务真的不能接受最终一致（比如跨库强一致的账务），那 XA 的存在意义就在于——它是唯一"对业务代码几乎透明"的强一致方案。

## 九、面试高频追问

**Q1：XA 的 Prepare 阶段到底做了什么？**

执行事务的所有写操作，把 undo 段标记为 `TRX_UNDO_PREPARED`，写入 `MLOG_XA_PREPARE` redo 日志，事务进入 PREPARED 状态，**持有所有行锁但不提交**，最后向 TM 返回成功。

**Q2：为什么 Prepare 之后不能写 binlog？**

因为 binlog 是"已提交事务"的日志，从库据此重放。如果在 Prepare 写了 binlog 而事务最终回滚，从库就会出现主库不存在的数据。所以 binlog 只在 Commit 阶段写。

**Q3：MySQL 崩溃后怎么恢复 prepared 事务？**

InnoDB 恢复时扫描 redo log 中的 `MLOG_XA_PREPARE` 记录，结合 undo 段的 XA 标记，重建 prepared 事务链表。恢复完成后，这些事务仍然处于 prepared 状态，需要协调者（TM）来驱动 commit/rollback，或者 DBA 手工处理。

**Q4：XA 事务能和其他非 XA 事务混用吗？**

不能。XA 事务期间如果执行了非 XA 语句，或者在一个已是 XA 状态的会话里再 `XA START`，MySQL 会直接报错。一个连接同时只能有一个活动 XA 事务。

**Q5：为什么不推荐在生产用 XA？**

三点：同步阻塞导致吞吐低；协调者故障产生悬挂事务；死锁与锁等待放大。除非跨库强一致是硬需求，否则 TCC 或本地消息表更实用。

**Q6：Seata 的 AT 模式和 XA 模式本质区别？**

XA 是**数据库层面的两阶段提交**，prepare 后就持锁；AT 是**应用层面的两阶段提交**，一阶段直接提交本地事务并写 undo_log，二阶段异步删除 undo_log 或反向补偿，因此**不长期持锁**，性能更好，但一致性是最终一致。

## 十、总结

XA 的设计哲学很朴素：**用"准备"换取"可回滚"，用"阻塞"换取"强一致"**。它把所有复杂度都压在了数据库和协调者之间，让业务代码看起来只是普通事务——这是它唯一的、也是巨大的优点。

但代价同样巨大：锁的持有时间被网络 RTT 放大，协调者成为单点，悬挂事务需要人工兜底。所以现实中的选择通常是：

- **能用最终一致，就别用 XA**；
- **一定要强一致，先问能不能把数据放进一个库**；
- **确实跨库强一致且并发不高**，XA 才是那个"虽然丑但正确"的答案。

理解 XA 的价值，不在于你会不会 `XA START`，而在于你能不能说清楚**它为什么慢、为什么可能不一致、以及当不一致发生时你怎么查**。

---

**参考**

- MySQL 官方文档：XA Transactions
- 《MySQL 技术内幕：InnoDB 存储引擎》—— 事务的实现章节
- X/Open CAE Specification: Distributed Transaction Processing: The XA Specification
