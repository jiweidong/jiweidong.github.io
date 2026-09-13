---
title: 【MySQL 锁】元数据锁（MDL）与表锁深度解析：从 DDL 阻塞雪崩到线上事故排查
date: 2026-09-13 08:00:00
tags:
  - MySQL
  - 锁机制
  - MDL
  - 元数据锁
  - 线上事故
categories:
  - MySQL
  - 数据库底层
author: 东哥
---

# 【MySQL 锁】元数据锁（MDL）与表锁深度解析：从 DDL 阻塞雪崩到线上事故排查

## 面试官：线上突然大量请求超时，`SHOW PROCESSLIST` 里全是 `Waiting for table metadata lock`，你怎么查？

这是 MySQL 生产事故里**最经典、最容易被误判、也最容易被忽视**的一类问题。

大多数人聊 MySQL 锁，张口就是「行锁、间隙锁、临键锁、MVCC」。但真正在线上制造大规模故障的，往往不是行锁，而是**元数据锁（Metadata Lock，MDL）**——一个从 MySQL 5.5 开始默认开启、绝大多数人从未主动配置过、却能让整个库瞬间「雪崩」的锁。

这篇文章把 MDL 与表级锁从原理讲到事故排查：

- MDL 到底是什么结构？为什么它不需要你显式加锁？
- 为什么「一个长事务 + 一条 DDL」能把这个表的所有查询全部堵死？
- 为什么 `SHOW PROCESSLIST` 里明明看到一个长事务，杀了它却没用（或者杀了才真正的开始堵）？
- 5.7 的 `lock_wait_timeout` 默认值为什么是「事故放大器」？
- DDL 上线怎么做才安全？

---

## 一、MySQL 锁的完整层次：别只知道行锁

InnoDB 的锁体系比「行锁/表锁二分」复杂得多。先建立全局视图：

```
MySQL 锁
├── 全局锁（Global Lock）
│   ├── FLUSH TABLES WITH READ LOCK (FTWRL)  —— 备份用
│   └── mysqldump 全局只读锁
├── 表级锁（Table-Level Lock，Server 层实现）
│   ├── 表锁（Table Lock）—— MyISAM 时代主力，InnoDB 也有
│   │   ├── 表共享读锁（S）
│   │   └── 表独占写锁（X）
│   ├── 意向锁（Intention Lock，IS / IX）—— 表级，用于行锁与表锁的兼容判断
│   ├── 元数据锁（MDL）—— 保护表结构，5.5+ 自动加，Server 层
│   └── AUTO-INC 锁 —— 自增主键并发插入
└── 行级锁（Row-Level Lock，InnoDB 引擎层）
    ├── 记录锁 Record Lock
    ├── 间隙锁 Gap Lock
    ├── 临键锁 Next-Key Lock
    └── 插入意向锁 Insert Intention Lock
```

**关键认知：MDL 是 Server 层（SQL 层）的锁，不是 InnoDB 的锁。** 这一点极其重要，因为：

1. **它对所有存储引擎生效**（包括 MyISAM、Memory）。
2. **它不遵循 `innodb_lock_wait_timeout`，而遵循 `lock_wait_timeout`**（默认 **31536000 秒**，即 1 年！）。
3. **它由 `performance_schema.metadata_locks` 表（5.7+）监控，而不是 `information_schema.INNODB_TRX`。**

这三点，是几乎所有 MDL 事故排查跑偏的根源。

---

## 二、MDL 是什么，为什么要它

### 2.1 它要解决的问题：DDL 与 DML 的并发安全

在 5.5 之前，MySQL 有个著名 Bug：如果一个会话在读表 A，另一个会话 `ALTER TABLE A`，那么读会话的语句在**执行中途表结构被改了**，可能读到错乱的数据，甚至直接崩溃。

MDL 的引入就是解决这个：**只要有会话在访问某张表（无论读写），就给这张表加一个 MDL 锁；DDL 需要更强的 MDL 锁，两者互斥。**

### 2.2 MDL 的类型

| MDL 类型 | 缩写 | 谁加 | 语义 |
| --- | --- | --- | --- |
| MDL_SHARED_HIGH_PRIO | — | 只访问元数据（如表存在性检查） | 不涉及数据 |
| **MDL_SHARED_READ** | S | `SELECT` | 读数据 |
| **MDL_SHARED_WRITE** | S | `INSERT/UPDATE/DELETE` | 写数据 |
| MDL_SHARED_UPGRADABLE | S | DDL 的第一阶段 | 可升级，不与 S 冲突 |
| MDL_SHARED_READ_ONLY | S | — | 只读元数据 |
| **MDL_SHARED_NO_WRITE** | X | `ALTER` 部分阶段 | 阻塞写，不阻塞读 |
| MDL_SHARED_NO_READ_WRITE | X | — | 阻塞读写 |
| **MDL_EXCLUSIVE** | X | DDL / `LOCK TABLES` | 阻塞一切 |

**兼容性速记表（越往右越强）**：

| | S_READ | S_WRITE | S_UPGRADABLE | SHARED_NO_WRITE | EXCLUSIVE |
| --- | --- | --- | --- | --- | --- |
| **S_READ** | ✅ | ✅ | ✅ | ❌ | ❌ |
| **S_WRITE** | ✅ | ✅ | ✅ | ❌ | ❌ |
| **S_UPGRADABLE** | ✅ | ✅ | ✅ | ❌ | ❌ |
| **SHARED_NO_WRITE** | ❌ | ❌ | ❌ | ❌ | ❌ |
| **EXCLUSIVE** | ❌ | ❌ | ❌ | ❌ | ❌ |

**从这张表能读出三件事**：

1. **普通查询之间不会互相阻塞**（SELECT/SELECT、SELECT/DML 都兼容）。所以 MDL 平时完全无感。
2. **所有 DML 与「阻塞写」及以上的 MDL 互斥**。这就是雪崩的根源。
3. **`SHARED_UPGRADABLE` 是个「可升级」的过渡态**——DDL 先拿可升级锁（此时读能进来），再尝试升级为排他锁；升级时需要等待所有读释放，一旦等待，**后续的读也会被排在后面**。

### 2.3 一个必须知道的特性：MDL 是「自动加、事务结束才释放」

这是 MDL 最致命的设计：

> **MDL 不需要显式加锁，且它的释放时间点是「事务提交/回滚」，而不是「语句结束」。**

普通的 MDL 读锁是语句级释放（5.7.3+ 有优化，部分场景语句结束即可释放），但只要语句在**显式事务**中（`BEGIN` 之后），MDL 就会**持有到事务结束**。

所以这句话必须刻在脑子里：

> **「一个开着事务但长时间不提交的会话，会一直持有 MDL，从而阻塞所有 DDL。」**

这就是「长事务 + DDL」事故的第一块多米诺骨牌。

---

## 三、雪崩是怎么发生的：完整推演

### 3.1 事故场景复现

准备三张表，模拟真实场景：

```sql
-- 观测会话
CREATE TABLE t_order (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  order_no VARCHAR(64) NOT NULL,
  amount DECIMAL(12,2) NOT NULL,
  status TINYINT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_status (status)
) ENGINE=InnoDB;

INSERT INTO t_order (order_no, amount, status)
SELECT CONCAT('NO', n), n * 1.5, n % 5
FROM (SELECT @n := @n + 1 AS n FROM information_schema.columns a, information_schema.columns b,
      (SELECT @n := 0) t LIMIT 100000) x;
```

**会话 A：开一个长事务，查完不提交**

```sql
-- session A
BEGIN;
SELECT * FROM t_order WHERE id = 1;   -- 只要这条 SELECT 执行了，就持有 MDL_SHARED_READ
-- 然后……去做别的事，不提交，不结束
```

**会话 B：执行 DDL**

```sql
-- session B
ALTER TABLE t_order ADD COLUMN remark VARCHAR(255) DEFAULT NULL;
-- 结果：卡住，状态 Waiting for table metadata lock
```

**会话 C：再执行任何查询**

```sql
-- session C
SELECT * FROM t_order WHERE id = 2;
-- 结果：也卡住！同样是 Waiting for table metadata lock
```

**这就是雪崩。** 明明 C 只是读，为什么要等？

### 3.2 完整时序图

```
时间轴 →

session A:  BEGIN ── SELECT ─────────────────────────────── COMMIT
                        │持有 MDL_SHARED_READ
                        │（事务未结束，锁不释放）
                        ▼
session B:              ALTER TABLE ──[等待]──────────────────[获得锁, 执行DDL]
                        │已获得 MDL_SHARED_UPGRADABLE
                        │正在等待升级为 EXCLUSIVE
                        │↓↓↓ 排在它后面的请求全部被队列阻塞 ↓↓↓
                        ▼
session C:                     SELECT ──[等待]───────────────[继续被B阻塞]
session D:                     UPDATE ──[等待]───────────────[等待]
session E:                     SELECT ──[等待]───────────────[等待]
                               ...  连接池被耗尽，整个服务不可用
```

**为什么 C 的 `SELECT` 会被阻塞？** 因为 MySQL 的 MDL 是**公平队列**：

1. B 已经拿到了 `SHARED_UPGRADABLE`（与读兼容），并**排队等待升级**。
2. 此时新的读请求（C、D、E）虽然理论上与 A 的读锁兼容，但**它们排在 B 的升级请求后面**——不能插队。
3. 于是所有后来的请求都被堵住，形成**连锁排队**。
4. 只有 A 提交（释放 MDL_SHARED_READ）→ B 升级成功 → 执行完 DDL → 队列才逐步疏通。

**核心结论：不是 DDL 阻塞了查询，而是「长事务阻塞了 DDL，DDL 又阻塞了所有后续查询」。** 这个顺序认知决定了排查方向。

### 3.3 更阴险的变体

**变体一：`SELECT ... S`（FOR UPDATE）**

```sql
BEGIN;
SELECT * FROM t_order WHERE id = 1 FOR UPDATE;
-- 持有 MDL_SHARED_WRITE + 行锁，同样阻塞 DDL
```

**变体二：未提交的「空闲事务」**

```sql
BEGIN;
UPDATE t_order SET status = 1 WHERE id = 1;
-- 网络断了一半，客户端卡死，事务既没提交也没回滚
-- 这个会话能挂着几小时，MDL 一直不释放
```

**变体三：`LOCK TABLES`**

```sql
LOCK TABLES t_order WRITE;   -- 拿的是 MDL_EXCLUSIVE，直接阻塞一切
-- 忘记 UNLOCK TABLES 的话，MDL 会持有到会话结束
```

**变体四：外键相关的隐式锁**

有外键的父子表，DDL 或者某些 DML 会**同时给关联表加 MDL**。这会导致你完全想不到的表被阻塞：

```sql
-- t_order_detail 有 FOREIGN KEY (order_id) REFERENCES t_order(id)
ALTER TABLE t_order ADD COLUMN remark VARCHAR(255);
-- 可能同时影响 t_order_detail 的 MDL
```

---

## 四、MDL 监控：怎么看见它

### 4.1 `performance_schema.metadata_locks`（5.7+ 主力）

```sql
-- 打开采集（默认可能关闭）
UPDATE performance_schema.setup_instruments
SET ENABLED = 'YES', TIMED = 'YES'
WHERE NAME = 'wait/lock/metadata/sql/mdl';

-- 永久生效放入 my.cnf
-- performance-schema-instrument='wait/lock/metadata/sql/mdl=ON'
```

**查询当前所有 MDL 及其归属会话**：

```sql
SELECT
    t1.OBJECT_TYPE,
    t1.OBJECT_SCHEMA,
    t1.OBJECT_NAME,
    t1.LOCK_TYPE,
    t1.LOCK_DURATION,
    t1.LOCK_STATUS,
    t2.PROCESSLIST_ID  AS conn_id,
    t2.PROCESSLIST_USER AS user,
    t2.PROCESSLIST_TIME AS age_sec,
    LEFT(t2.PROCESSLIST_INFO, 80) AS stmt
FROM performance_schema.metadata_locks t1
LEFT JOIN performance_schema.threads t2
       ON t1.OWNER_THREAD_ID = t2.THREAD_ID
WHERE t1.OBJECT_SCHEMA NOT IN ('performance_schema', 'mysql', 'information_schema')
ORDER BY t1.OBJECT_NAME, age_sec DESC;
```

**输出示例与判读**：

```
+-------------+---------------+------------+-------------------+----------------+-----------+---------+------+--------+--------------------------------+
| OBJECT_TYPE | OBJECT_SCHEMA | OBJECT_NAME| LOCK_TYPE         | LOCK_DURATION  |LOCK_STATUS| conex_id| user | age_s  | stmt                           |
+-------------+---------------+------------+-------------------+----------------+-----------+---------+------+--------+--------------------------------+
| TABLE       | demo          | t_order    | SHARED_READ       | TRANSACTION    | GRANTED   |     101 | app  |    612 | SELECT * FROM t_order WHERE ...|
| TABLE       | demo          | t_order    | SHARED_UPGRADABLE | TRANSACTION    | GRANTED   |     205 | dba  |     48 | ALTER TABLE t_order ADD ...    |
| TABLE       | demo          | t_order    | SHARED_READ       | STATEMENT      | PENDING   |     310 | app  |     45 | SELECT * FROM t_order WHERE ...|
| TABLE       | demo          | t_order    | SHARED_READ       | STATEMENT      | PENDING   |     311 | app  |     44 | SELECT * FROM t_order WHERE ...|
+-------------+---------------+------------+-------------------+----------------+-----------+---------+------+--------+--------------------------------+
```

**判读三步**：

1. **找 `LOCK_STATUS = GRANTED` 且 `LOCK_DURATION = TRANSACTION` 的会话**（这里是 101，612 秒）——这就是**罪魁祸首长事务**。
2. **找 `LOCK_STATUS = PENDING` 的会话**——这些是被堵住的受害者，数量就是「雪崩规模」。
3. **看 `SHARED_UPGRADABLE` 的 GRANTED**（205）——这是正在等待升级的 DDL，它是「闸门」。

> **注意 `LOCK_DURATION` 的取值**：`STATEMENT` 表示语句级（语句结束就释放，一般无害），`TRANSACTION` 表示事务级（**危险，需要提交才释放**）。**看到 `TRANSACTION` 就要警觉。**

### 4.2 `sys.schema_table_lock_waits`（更友好）

MySQL 5.7+ 提供了 `sys` 库的视图，直接给出「谁在等谁」：

```sql
SELECT
    waiting_pid        AS blocked_pid,
    waiting_query      AS blocked_query,
    blocking_pid       AS blocking_pid,
    blocking_query     AS blocking_query,
    waiting_age        AS wait_seconds
FROM sys.schema_table_lock_waits
ORDER BY wait_seconds DESC;
```

**这个视图是 MDL 排查的首选**，因为 5.7.9+ 之后它**也包含 MDL 等待**（早期版本只包含表锁）。

### 4.3 `SHOW PROCESSLIST` / `information_schema.processlist`

```sql
SELECT id, user, host, db, command, time, state, LEFT(info, 100) AS stmt
FROM information_schema.processlist
WHERE state LIKE '%metadata lock%'
   OR command = 'Query'
ORDER BY time DESC;
```

**关键判读技巧**：

- `state = 'Waiting for table metadata lock'` 的是**受害者**（不是元凶）。
- **真正的元凶是 `Command = 'Sleep'` 且 `time` 很大的会话！** 因为长事务在没有语句执行时，会话状态就是 `Sleep`。

```sql
-- 直接找元凶：开了事务但闲置的会话
SELECT id, user, host, db, time AS idle_sec, state, info
FROM information_schema.processlist
WHERE command = 'Sleep'
  AND time > 60
ORDER BY time DESC;
```

```sql
-- 结合 InnoDB 事务表，找「有活跃事务但 SQL 为空」的会话（最典型的元凶）
SELECT
    trx.trx_id,
    trx.trx_mysql_thread_id  AS conn_id,
    trx.trx_state,
    TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) AS trx_age_sec,
    trx.trx_rows_locked,
    trx.trx_rows_modified,
    p.user, p.host, p.db, p.command, LEFT(p.info, 60) AS stmt
FROM information_schema.INNODB_TRX trx
JOIN information_schema.processlist p ON trx.trx_mysql_thread_id = p.id
WHERE TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) > 30
ORDER BY trx_age_sec DESC;
```

**这个 SQL 是排查 MDL 事故的核武器**：`trx_started` 很早 + `p.command = 'Sleep'` = 长事务闲置会话 = 元凶。

---

## 五、处置：怎么解开，以及为什么不能乱杀

### 5.1 正确的处置顺序

**第一步：找到元凶，不要盲杀受害者。**

```sql
-- 用 4.3 的 SQL 找到 conn_id（假设是 101）
```

**第二步：优先尝试「优雅结束」——让业务侧提交/回滚。**

如果是业务代码里的连接泄漏（忘记 commit/rollback），杀掉会话可能导致业务状态不一致。理想顺序：

1. 通知业务方主动提交或回滚该会话。
2. 如果是可安全回滚的只读事务，直接 `KILL`。

**第三步：KILL 元凶，观察雪崩是否疏通。**

```sql
-- 杀掉元凶（注意：会回滚其事务，大事务回滚可能很慢！）
KILL 101;

-- 如果 KILL CONNECTION 因为回滚大事务迟迟不结束，可以尝试：
-- KILL QUERY 101;   -- 只杀当前语句，但事务仍在（对 Sleep 会话无效）
```

### 5.2 ⚠️ 为什么「盲杀受害者」是错的

如果你看到一堆 `Waiting for table metadata lock` 就去杀它们：

1. **杀了受害者，队列长度不变**——因为元凶还在，DDL 还在排队。
2. **更糟的情况**：如果 DDL 是你误开的，杀掉 DDL 会话之后，**队列里排在 DDL 后面的受害者会立即获得锁并执行**——但此时元凶（长事务）**依然持有 MDL_SHARED_READ**，它们依然被阻塞。你只是白折腾一轮。
3. **最坏的情况**：连续杀会话可能触发应用端的连接重建风暴，**雪崩规模反而扩大**。

**记住：MDL 事故只有一个元凶（或少数几个），受害者的数量是无意义的指标。**

### 5.3 三种「杀不掉」的情况

| 现象 | 原因 | 应对 |
| --- | --- | --- |
| `KILL` 后会话长时间不消失 | 大事务回滚中（`trx_state = 'ROLLING BACK'`） | 只能等。回滚速度受 `innodb_io_capacity` 影响。**禁止再杀** |
| `KILL` 后新连接继续堆积 | DDL 仍在队列中，且未提交的长事务还有多个 | 用 4.1 的 SQL 找出**所有** `LOCK_DURATION = TRANSACTION` 的 GRANTED 会话，逐个处理 |
| 杀掉元凶后 DDL 报错 `Lock wait timeout exceeded` | `lock_wait_timeout` 到期 | 重新执行 DDL |

### 5.4 临时止血：把 `lock_wait_timeout` 调小

```sql
-- 查看（默认 31536000 = 1 年，等于「永不超时」）
SHOW VARIABLES LIKE 'lock_wait_timeout';

-- 临时调小（会话级），让被阻塞的请求快速失败，保护连接池
SET SESSION lock_wait_timeout = 5;
```

**为什么建议调小？** 因为默认 1 年意味着被阻塞的查询会**一直挂着**，把连接池占满，进而导致整个应用不可用。**快速失败（抛异常）远好于慢速堆积（雪崩）。**

```ini
# my.cnf 全局设置（建议 5~30 秒，视业务而定）
lock_wait_timeout = 10
```

**注意取舍**：调太小会导致正常的 DDL 与 DML 竞争时频繁失败（比如批量导入时的锁等待），需要结合业务评估。

---

## 六、根治：从「事后救火」到「事前预防」

### 6.1 长事务治理（最根本）

**监控 + 告警 + 主动清理**三件套：

```sql
-- 定时任务（比如每 10 秒）：找出超过 60 秒的活跃事务
SELECT trx_mysql_thread_id, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_sec,
       trx_rows_modified, LEFT(trx_query, 80)
FROM information_schema.INNODB_TRX
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60;
```

**应用层规则**：

```java
// ❌ 典型的长事务写法：事务里做 RPC 调用 / 循环处理
@Transactional
public void batchProcess(List<Long> ids) {
    for (Long id : ids) {
        OrderEntity order = orderRepository.findById(id).orElseThrow();
        remoteService.notify(order);          // 远程调用可能超时 3 秒
        orderService.update(order);
        Thread.sleep(100);                    // 更离谱的写法
    }
}
```

```java
// ✅ 缩小事务范围：事务只包住 DB 操作
public void batchProcess(List<Long> ids) {
    for (Long id : ids) {
        OrderEntity order = orderQueryService.get(id);
        remoteService.notify(order);        // RPC 在事务外
        orderCommandService.update(order);  // 事务只在这里，毫秒级
    }
}
```

**三条硬规则**：

1. **事务里禁止 RPC / HTTP / MQ 发送**（网络抖动 = 长事务）。
2. **事务里禁止循环 N 次**（改成小批量 + 分批提交）。
3. **事务里禁止 `SELECT` 大量数据**（大结果集 + 长时间 = 长事务）。

### 6.2 DDL 上线规范（治标也治本）

**规则一：DDL 前先检查长事务。**

```sql
-- DDL 前的「体检」SQL，必须在 DDL 前执行
SELECT COUNT(*) AS long_trx_count
FROM information_schema.INNODB_TRX
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 10;
-- 返回值 > 0 就绝对不要执行 DDL！
```

**规则二：DDL 前设置短超时。**

```sql
SET SESSION lock_wait_timeout = 3;   -- DDL 最多等 3 秒，宁失败不雪崩
ALTER TABLE t_order ADD COLUMN remark VARCHAR(255) DEFAULT NULL;
```

这样如果 DDL 抢不到锁，**3 秒后自己失败退出**，不会把后面的查询全部堵死。这是**DBA 最重要的一个习惯**。

**规则三：大表 DDL 用工具。**

```bash
# gh-ost：基于 binlog 的无触发器在线改表
gh-ost \
  --host=127.0.0.1 --port=3306 --user=ghost --password=xxx \
  --database=demo --table=t_order \
  --alter="ADD COLUMN remark VARCHAR(255) DEFAULT NULL" \
  --allow-on-master \
  --chunk-size=1000 \
  --max-load='Threads_running=50' \
  --critical-load='Threads_running=200' \
  --cut-over=default \
  --execute

# pt-online-schema-change：基于触发器
pt-online-schema-change \
  --alter "ADD COLUMN remark VARCHAR(255) DEFAULT NULL" \
  D=demo,t=t_order \
  --chunk-size=1000 \
  --max-lag=2 \
  --critical-load="Threads_running=100" \
  --set-vars="lock_wait_timeout=3" \
  --execute
```

**注意两者的关键差异**：

| 维度 | gh-ost | pt-osc |
| --- | --- | --- |
| 同步机制 | 读 binlog（**无触发器**） | 触发器（**有写放大**） |
| 对主库影响 | 低 | 中（触发器同步写） |
| 需要权限 | REPLICATION SLAVE | TRIGGER |
| 外键支持 | 弱 | 好 |
| 暂停/恢复 | 支持（可交互） | 支持 |

两者都**必须设置 `lock_wait_timeout`**，并且**在副本延迟可控时执行**。

**规则四：DDL 窗口 + 灰度。**

- 在业务低峰期（凌晨）做。
- 先在**只读副本**上演练。
- 先在小表验证 SQL 正确性。

### 6.3 其他预防手段

**手段一：`innodb_lock_wait_timeout` 与 `lock_wait_timeout` 双管齐下**

| 参数 | 作用范围 | 默认值 | 建议 |
| --- | --- | --- | --- |
| `innodb_lock_wait_timeout` | **InnoDB 行锁**等待 | 50 秒 | 10~30 秒 |
| `lock_wait_timeout` | **MDL / 表锁**等待 | 31536000 秒 | 10~30 秒（DDL 会话 3 秒） |

**这两个参数管的是不同的锁，必须分别设置。** 很多人只调了前者，MDL 事故照样发生。

**手段二：用 `ALTER ... , ALGORITHM=INPLACE` 减少阻塞时间**

```sql
-- 显式指定算法，确认是否支持在线执行（不支持会直接报错，避免长时间表锁）
ALTER TABLE t_order ADD INDEX idx_created (created_at), ALGORITHM=INPLACE, LOCK=NONE;
```

- `LOCK=NONE`：不阻塞读写（需要算法支持）。
- `LOCK=SHARED`：不阻塞读，阻塞写。
- `LOCK=EXCLUSIVE`：阻塞读写。

**但注意**：`ALGORITHM=INPLACE` 只是减少了**DDL 执行期间**的锁时间，**完全无法解决「元凶长事务 + DDL 排队」导致的前置阻塞**。所以它不能替代「DDL 前检查长事务」。

**手段三：在线 DDL 的 `LOCK=NONE` 仍会短暂升级为排他锁**

8.0 的 online DDL 在**开始（prepare）和结束（commit）**两个阶段，仍需要短暂的 `MDL_EXCLUSIVE`。如果这两个瞬间抢不到锁，就会进入排队 → 雪崩。**这就是 `SET SESSION lock_wait_timeout = 3` 的价值。**

### 6.4 应用侧：连接泄漏防治

MDL 事故最常见的应用层原因是「**连接泄漏 + 事务未结束**」：

```java
// ❌ 手动管理事务，异常路径漏了 rollback
Connection conn = dataSource.getConnection();
conn.setAutoCommit(false);
try {
    // ...
    conn.commit();
} catch (Exception e) {
    log.error("error", e);
    // 忘了 conn.rollback()，连接被还回池里时事务还开着！
} finally {
    // 甚至忘了 conn.close()
}
```

```java
// ✅ 交给 Spring 管理事务
@Service
public class OrderTxService {
    @Transactional(rollbackFor = Exception.class)
    public void doSomething() { }
}
```

或者用 try-with-resources：

```java
try (Connection conn = dataSource.getConnection()) {
    conn.setAutoCommit(false);
    try {
        // ...
        conn.commit();
    } catch (Exception e) {
        conn.rollback();
        throw e;
    }
}
```

**排查连接池泄漏的监控指标**：

```yaml
# HikariCP
spring:
  datasource:
    hikari:
      maximum-pool-size: 20
      leak-detection-threshold: 60000   # 连接借出超过 60s 未归还就打印堆栈
```

**`leak-detection-threshold` 是排查连接泄漏的最佳工具**，它会直接打印「谁借了连接不还」的堆栈。

---

## 七、一张排障决策表

线上遇到锁等待时，按这个表走：

| 现象 | 判定 | 处置 |
| --- | --- | --- |
| `Waiting for table metadata lock` 大量出现 | **MDL 雪崩** | 查 `sys.schema_table_lock_waits` 找 GRANTED + TRANSACTION 的会话 |
| 元凶会话 `Command = Sleep` 且 `time` 大 | 长事务闲置 | 优先让业务提交/回滚；确认可回滚后 `KILL` |
| `trx_state = 'ROLLING BACK'` | 正在回滚大事务 | **等待**，不能再杀 |
| `Waiting for table level lock` | MyISAM 表锁 或 InnoDB 表锁 | 检查是否有 `LOCK TABLES`、`ALTER`、`TRUNCATE` |
| `Lock wait timeout exceeded` | 行锁等待超时 | 查 `INNODB_TRX` + `INNODB_LOCKS`，找互相等待的事务（死锁/长事务） |
| 连接池打满、请求全超时 | 雪崩已发生 | 先 `SET GLOBAL lock_wait_timeout=5` 止血，再处理元凶 |
| DDL 请求堆积但无受害者 | DDL 在等 MDL | 直接 `KILL` DDL 会话（最安全，无副作用） |

**记住那条最重要的判据**：

> **要区分「谁在等锁」和「谁在持锁」。`Waiting for table metadata lock` 是「等锁者」，它旁边那个 `Sleep` 的、`LOCK_DURATION = TRANSACTION` 的才是「持锁者」。杀等锁者没用，要杀就杀持锁者。**

---

## 八、面试高频追问

**Q1：MDL 和 InnoDB 的表锁有什么区别？**

| 维度 | MDL | InnoDB 表锁（含意向锁） |
| --- | --- | --- |
| 实现层 | **Server 层（SQL 层）** | **InnoDB 引擎层** |
| 触发 | **自动加**（任何表访问） | 显式（`LOCK TABLES`）或行锁推导 |
| 超时参数 | `lock_wait_timeout` | `innodb_lock_wait_timeout` |
| 保护对象 | **表结构（元数据）** | 表数据 |
| 生效引擎 | **所有引擎** | 仅 InnoDB |
| 监控表 | `performance_schema.metadata_locks` | `INNODB_TRX` / `INNODB_LOCKS` |

**Q2：为什么 `SELECT` 也能阻塞 `ALTER TABLE`？**

因为 `SELECT` 会持有 `MDL_SHARED_READ`，而 `ALTER TABLE` 需要 `MDL_EXCLUSIVE`，两者互斥。所以 DDL 必须等所有读会话结束。**而且，只要这个 SELECT 在显式事务里，MDL 就持有到事务结束，不是语句结束。**

**Q3：为什么只有 MDL 会在没有任何数据修改的情况下造成大范围阻塞？**

因为 MDL 是**队列式**的：

1. DDL 拿到 `SHARED_UPGRADABLE`（与读兼容）。
2. DDL 请求升级为 `EXCLUSIVE` 时被长事务阻塞。
3. **后续所有请求不能插队**，只能排在被阻塞的 DDL 后面。

所以一个长事务 + 一条 DDL，就足以把整张表的所有访问串成一条队列。

**Q4：`ALTER TABLE` 加了 `ALGORITHM=INPLACE, LOCK=NONE` 就不会阻塞了吗？**

**不是。** `LOCK=NONE` 只保证 DDL 的**执行阶段**不阻塞 DML，但：

1. **准备阶段和提交阶段仍需要短暂的 `MDL_EXCLUSIVE`**——如果此时有长事务，照样排队雪崩。
2. **它不解决「DDL 排队期间后续请求全部阻塞」的问题**。

所以正确做法是 **「DDL 前查长事务 + `SET SESSION lock_wait_timeout = 3` + 低峰执行」**，而不是迷信 `LOCK=NONE`。

**Q5：为什么不建议在生产使用 `FLUSH TABLES WITH READ LOCK` 做备份？**

因为 `FTWRL` 会：

1. 加**全局读锁**，期间**所有表的写操作全部阻塞**。
2. 如果此时有慢查询（比如一个大 `SELECT`），`FTWRL` 会等它结束——期间整个实例的写全部停摆。

**替代方案**：

- `mysqldump --single-transaction`（InnoDB，用一致性快照，不加全局锁）。
- **物理备份**：Percona XtraBackup / MySQL Enterprise Backup。
- **从只读副本备份**（最推荐）。

**Q6：`TRUNCATE TABLE` 和 `DELETE FROM` 在锁上有什么本质区别？**

- `TRUNCATE` 是 **DDL**：需要 `MDL_EXCLUSIVE`，**隐式提交事务**，**不能回滚**，且会**重建表空间**（自增 ID 归零）。
- `DELETE` 是 **DML**：加行锁（其实是删除所有行的行锁），**可以回滚**，自增 ID 不归零，但会产生大量 undo/binlog。

所以在有长事务的系统里，`TRUNCATE` 是**高危操作**——它可能触发和 `ALTER` 一样的 MDL 雪崩。

---

## 九、总结

```
MDL 与表锁
├── 层次
│   ├── Server 层：全局锁、表锁、意向锁、MDL、AUTO-INC 锁
│   └── InnoDB 层：记录锁、间隙锁、临键锁
├── MDL 关键特性
│   ├── 自动加（任何表访问），无需显式
│   ├── 释放点是「事务结束」，不是「语句结束」  ← 事故根源
│   ├── 队列式（公平），后面的请求不能插队        ← 雪崩机制
│   └── 超时看 lock_wait_timeout（默认 1 年！）   ← 事故放大器
├── 雪崩链
│   长事务(持有 S_READ, TRANSACTION)
│     → DDL 排队等待升级
│       → 后续所有请求排到 DDL 后面
│         → 连接池耗尽 → 服务不可用
├── 排查
│   ├── sys.schema_table_lock_waits       ← 首选，直接给出阻塞关系
│   ├── performance_schema.metadata_locks ← 看 LOCK_STATUS / LOCK_DURATION
│   ├── INNODB_TRX + processlist          ← 找「长时间 Sleep + 早开始的事务」
│   └── 判据：等锁者 vs 持锁者，不要杀错
├── 处置
│   ├── 先找元凶（GRANTED + TRANSACTION），不是杀受害者
│   ├── ROLLING BACK 的会话禁止再杀
│   └── 止血：SET GLOBAL lock_wait_timeout = 5
└── 预防
    ├── 长事务治理（事务内禁止 RPC / 循环 / 大批量）
    ├── DDL 规范（前置检查 + lock_wait_timeout=3 + 低峰 + 工具）
    ├── 双超时参数（innodb_lock_wait_timeout + lock_wait_timeout）
    └── 连接泄漏监控（HikariCP leak-detection-threshold）
```

如果面试官再问「线上大量 `Waiting for table metadata lock` 怎么查」，你的回答应该是：

> 「这是典型的 MDL 雪崩。先看 `sys.schema_table_lock_waits` 定位阻塞关系，再看 `performance_schema.metadata_locks` 里 `LOCK_STATUS=GRANTED` 且 `LOCK_DURATION=TRANSACTION` 的会话——那才是元凶长事务，`Waiting` 的只是受害者。处置上先让业务提交/回滚，确认可回滚再 KILL；正在 `ROLLING BACK` 的绝不能杀。止血用 `SET GLOBAL lock_wait_timeout=5` 让请求快速失败，避免连接池被打满。根因治理是长事务管控 + DDL 前检查 + DDL 会话设置 3 秒超时 + 用 gh-ost/pt-osc 做大表变更。」

这套回答，比背「间隙锁和临键锁的区别」更能体现你**真的处理过线上问题**。
