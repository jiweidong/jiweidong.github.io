---
title: 【MySQL 运维】多源复制（Multi-Source Replication）深度解析：多实例数据聚合与冲突治理
date: 2026-09-30 08:00:00
tags:
  - MySQL
  - 主从复制
  - 运维
  - 架构设计
categories:
  - 数据库
  - 中间件
author: 东哥
---

# 【MySQL 运维】多源复制（Multi-Source Replication）深度解析：多实例数据聚合与冲突治理

## 面试官：有 8 个分库，怎么做一张全局报表？

这是一个非常典型的真实需求：业务按用户 ID 水平分成了 8 个库，现在要做运营报表、离线分析或者全局搜索，需要把这 8 个分库的数据汇总到一个地方。

候选人的答案通常有三种：

1. 写个程序定时 `SELECT` 再 `INSERT`（数据同步服务）；
2. 用 Canal/Debezium 订阅 binlog 再写到汇总库；
3. 用 MySQL 自带的多源复制。

前两种方案大家都熟，第三种却经常被忽略。**MySQL 5.7 起正式支持多源复制（Multi-Source Replication）**，一个从库可以同时挂在多个主库下面，把多个实例的数据拉到一个实例里。本文就把这套机制讲透：怎么建、怎么防冲突、怎么监控、什么时候不该用。

## 一、多源复制解决什么问题

### 1.1 场景对比

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| 应用层定时同步 | 灵活、可做清洗 | 有延迟、要写代码、易漏数据、对主库有压力 |
| Canal/Debezium + MQ | 事件驱动、可扩展 | 组件多、运维复杂、要处理乱序与重复 |
| **多源复制** | 原生、零代码、延迟低（秒级） | 表结构冲突、GTID 管理复杂、只能"照搬"不能清洗 |

多源复制的最大价值是**原生**：不需要引入额外组件，不需要写一行同步代码，靠 MySQL 自己的复制通道就能把 N 个实例的数据拉到一起。它适合：

- 分库分表后的**汇总库 / 报表库**；
- **数据仓库落地层**（ODS 层）；
- 多机房数据**归集到中心**做统一查询；
- 扩容/迁移期间**多个老库向新库过渡**。

### 1.2 核心概念：复制通道（Replication Channel）

普通主从复制里，Slave 只有一组 IO/SQL 线程，主库信息存在 `master.info`（文件形式）。多源复制把它抽象成了**通道（channel）**：

- 每个通道 = 一个独立的主库连接 + 独立的 IO_THREAD + SQL_THREAD + 独立的元数据仓库；
- 通道有唯一名字，所有复制语句都要带 `FOR CHANNEL 'chname'`；
- 元数据建议存在表中（`master_info_repository=TABLE`、`relay_log_info_repository=TABLE`），这样 `performance_schema` 才能看到每个通道的状态。

```text
        ┌─────────────┐
        │  Master A   │──┐
        └─────────────┘  │   channel_01
                         ▼
        ┌─────────────┐  ┌──────────────────────┐
        │  Master B   │─▶│   Aggregate Slave     │
        └─────────────┘  │  IO/SQL 线程 × N      │
                         │  relay log per channel│
        ┌─────────────┐  └──────────────────────┘
        │  Master C   │─▶   channel_03
        └─────────────┘
```

## 二、从零搭建：完整可执行步骤

### 2.1 前置条件

| 项目 | 要求 |
| --- | --- |
| MySQL 版本 | ≥ 5.7.6（5.7 前不支持多源） |
| 主库 binlog | `log-bin=ON`、`binlog_format=ROW` |
| 从库 | `log_slave_updates=ON`（若还要级联）、`skip_slave_start` 视情况 |
| 元数据 | `master_info_repository=TABLE`、`relay_log_info_repository=TABLE` |
| 复制账号 | 各主库上都要有 `REPLICATION SLAVE` 权限 |

从库关键配置：

```ini
[mysqld]
server-id = 100
relay-log = /var/lib/mysql/relaylog
log-bin = /var/lib/mysql/binlog
gtid_mode = ON
enforce_gtid_consistency = ON
master_info_repository = TABLE
relay_log_info_repository = TABLE
# 多源复制下每个通道会各写一份 relay log，注意磁盘
relay_log_purge = ON
```

⚠️ 注意：**多源复制下 `server-id` 必须唯一且非 0**，且各通道不能复用同一个中继日志文件名前缀，MySQL 会自动加通道名后缀。

### 2.2 GTID 模式下的搭建（推荐）

GTID 模式是多源复制的**首选**，因为它用 `source_id:transaction_id` 唯一标识事务，天然避免"同一事务被重复执行"。

先在每个主库上确认 GTID 状态：

```sql
-- 在每个主库上执行
SHOW MASTER STATUS\G
-- 输出示例：
-- Executed_Gtid_Set: 3f2b1c9d-...:1-100025
```

在从库上建立通道（5.7 用 `CHANGE MASTER TO ... FOR CHANNEL`，8.0.23+ 推荐 `SOURCE` 语法）：

```sql
-- 通道 1：master_a
CHANGE MASTER TO
  MASTER_HOST='10.0.1.11',
  MASTER_PORT=3306,
  MASTER_USER='repl',
  MASTER_PASSWORD='Repl@2026',
  MASTER_AUTO_POSITION=1
FOR CHANNEL 'master_a';

-- 通道 2：master_b
CHANGE MASTER TO
  MASTER_HOST='10.0.1.12',
  MASTER_PORT=3306,
  MASTER_USER='repl',
  MASTER_PASSWORD='Repl@2026',
  MASTER_AUTO_POSITION=1
FOR CHANNEL 'master_b';

-- 通道 3：master_c
CHANGE MASTER TO
  MASTER_HOST='10.0.1.13',
  MASTER_PORT=3306,
  MASTER_USER='repl',
  MASTER_PASSWORD='Repl@2026',
  MASTER_AUTO_POSITION=1
FOR CHANNEL 'master_c';
```

`MASTER_AUTO_POSITION=1` 就是 GTID 模式的开关，它会自动协商起点，**不需要手动指定 binlog file/pos**——这正是 GTID 在多源场景下最大的价值。

启动所有通道（8.0.22+ 支持 `FOR CHANNEL ALL`）：

```sql
-- MySQL 8.0.22+
START REPLICA FOR CHANNEL 'master_a';
START REPLICA FOR CHANNEL 'master_b';
START REPLICA FOR CHANNEL 'master_c';

-- 5.7 语法
START SLAVE FOR CHANNEL 'master_a';
START SLAVE FOR CHANNEL 'master_b';
START SLAVE FOR CHANNEL 'master_c';

-- 8.0.22+ 一次性启动全部
START REPLICA FOR CHANNEL ALL;
```

### 2.3 非 GTID 模式的坑

如果用 binlog 位置（`MASTER_LOG_FILE` + `MASTER_LOG_POS`），每条通道要单独取值，重启后位置管理很容易错乱。**除非有历史包袱，否则多源复制一律上 GTID。**

## 三、多源复制的核心难题：冲突

这是多源复制最容易翻车的地方。多个主库的数据汇入同一个从库，冲突来源有四类：

### 3.1 主键 / 唯一键冲突

最典型：分库时各库自增 ID 都从 1 开始，汇总时直接撞车。

```sql
-- Master A: INSERT INTO t_user(id, name) VALUES (1, 'alice');
-- Master B: INSERT INTO t_user(id, name) VALUES (1, 'bob');
-- 汇总从库执行第二条时报：
-- ERROR 1062 (23000): Duplicate entry '1' for key 'PRIMARY'
```

**解决方案：**

| 方案 | 做法 | 适用 |
| --- | --- | --- |
| 全局唯一 ID | 分库时就使用雪花/Segment ID，不依赖自增 | 最推荐，从源头解决 |
| 自增步长错开 | 主库 A `auto_increment_offset=1, step=3`；B 为 2；C 为 3 | 老系统兼容 |
| 表名前缀隔离 | 同步后落到 `ma_user`、`mb_user` | 报表/归档场景 |
| 忽略错误 | `slave_skip_errors=1062`（危险！） | 仅应急 |

第三步依赖 `replicate-rewrite-db` 或 `replicate-wild-do-table` 做库表映射——**但注意 `replicate-rewrite-db` 不能改表名，只能改库名**，想要表名前缀得靠业务层或后续 ETL。

### 3.2 DDL 冲突

```sql
-- Master A: ALTER TABLE t_order ADD COLUMN coupon_id BIGINT;
-- Master B: ALTER TABLE t_order ADD COLUMN coupon_id VARCHAR(64);
```

两个主库对同一张表结构做了不同变更，从库必然报错。**多源复制的第一原则：源端表结构必须严格一致，DDL 要走统一发布流程。**

MySQL 8.0 的 `replicate-*-do-table` 过滤器是在 SQL 线程执行前过滤的，但**DDL 过滤不可靠**（尤其 `DROP DATABASE`、跨库 `RENAME`），所以在多源场景下过滤规则要尽量窄。

### 3.3 更新丢失（Lost Update）

两个主库更新同一行：A 把 status 改成 1，B 改成 2。谁最后到从库，谁生效——**另一条更新静默丢失，且不报错**（因为行存在，只是值被覆盖）。

这类冲突**没有技术手段能自动解决**，只能靠业务设计：

- 从源头保证不同源库不写同一行数据（分片键保证）；
- 或者汇总库只做 append-only 的事实表（报表场景的常见选择）。

### 3.4 元数据冲突：`mysql` 系统库

多源复制切记**不要在从库同步 `mysql` 库**。多个主库的用户、权限、`存储过程` 定义会互相覆盖，轻则权限错乱，重则 `@` 用户被删导致复制账号失效。

```ini
# 从库 my.cnf：过滤系统库
replicate-ignore-db = mysql
replicate-ignore-db = information_schema
replicate-ignore-db = performance_schema
replicate-ignore-db = sys
```

## 四、冲突处理策略：三个开关

### 4.1 `slave_exec_mode`

```ini
# IDEMPOTENT 模式：把"找不到行"和"唯一键冲突"都当成成功跳过
slave_exec_mode = IDEMPOTENT   # 默认 STRICT
```

`IDEMPOTENT` 只对 **ROW 格式**的复制有效，它是多源复制的常用兜底。但它有严重的副作用：

- `DELETE`/`UPDATE` 找不到行 → 静默跳过（数据不一致！）；
- `INSERT` 冲突 → 静默忽略（丢失数据！）。

**所以它的定位是"让复制别停"，而不是"让数据对"。** 一旦开启，就必须配套数据校验工具（pt-table-checksum / 自研对账）定期核对。

### 4.2 `sql_slave_skip_counter` 与 `slave_skip_errors`

```sql
-- 跳过 N 个事件（注意：GTID 模式下不支持！GTID 模式要用空事务补 GTID）
STOP SLAVE SQL_THREAD FOR CHANNEL 'master_a';
SET GLOBAL sql_slave_skip_counter = 1;
START SLAVE SQL_THREAD FOR CHANNEL 'master_a';

-- GTID 模式下跳过错误事务的正确姿势
STOP REPLICA FOR CHANNEL 'master_a';
SET GTID_NEXT = '3f2b1c9d-1111-1111-1111-111111111111:100026';
BEGIN; COMMIT;
SET GTID_NEXT = 'AUTOMATIC';
START REPLICA FOR CHANNEL 'master_a';
```

这是**必须掌握**的运维技能：GTID 模式下 `sql_slave_skip_counter` 直接报错 `ERROR 1858`，只能通过"注入空事务"把 GTID 标记为已执行。

### 4.3 长期方案：业务侧收敛

| 冲突类型 | 长期解法 |
| --- | --- |
| 主键冲突 | 全局 ID（雪花 / Redis INCR / 号段） |
| 唯一键冲突 | 唯一键加分片前缀（`uk(tenant_id, biz_no)`） |
| 更新冲突 | 分片键保证行归属唯一；或改为 append-only |
| DDL 冲突 | 统一 DDL 发布平台，禁止绕开发布 |
| 系统库冲突 | 复制过滤器排除 |

## 五、监控：怎么看多源复制的健康度

### 5.1 性能视图（推荐）

```sql
-- 每个通道一行
SELECT
  CHANNEL_NAME,
  SERVICE_STATE,
  COUNT_TRANSACTIONS_IN_QUEUE     AS queue_tx,
  COUNT_TRANSACTIONS_RETRIES      AS retries,
  SOURCE_UUID,
  LAST_ERROR_NUMBER,
  LAST_ERROR_MESSAGE,
  APPLYING_TRANSACTION
FROM performance_schema.replication_applier_status_by_worker_0;
```

更完整的一张表（8.0.22+）：

```sql
SELECT
  CHANNEL_NAME,
  SERVICE_STATE,
  RECEIVED_TRANSACTION_SET,
  LAST_ERROR_NUMBER,
  LAST_ERROR_MESSAGE,
  LAST_ERROR_TIMESTAMP,
  LAST_HEARTBEAT_TIMESTAMP
FROM performance_schema.replication_connection_status;
```

### 5.2 延迟计算（多源下不能只看 Seconds_Behind_Master）

`Seconds_Behind_Master`（8.0.22+ 改名 `Seconds_Behind_Source`）在多源复制下**极不可靠**：

- 它基于 SQL 线程执行到的事件时间戳与当前时间差；
- **如果某条通道根本没有流量，它会显示 0（其实只是没数据）**；
- 一个大事务会让它长时间显示为某个值，误导判断。

正确做法：**用 `pt-heartbeat` 或自研心跳表**，把主库时间戳写进一张表，从库读出来算差值：

```bash
pt-heartbeat --update --daemonize \
  --host=10.0.1.11 --database=heartbeat \
  --create-table --interval=1 --table=heartbeat_a

# 在从库上监控
pt-heartbeat --monitor --host=aggregate-slave --database=heartbeat \
  --table=heartbeat_a --master-server-id=11
```

或者自研：

```sql
-- 每个主库上，由定时任务执行
UPDATE hb_channel SET ts = NOW(6) WHERE channel = 'master_a';

-- 从库上查询延迟
SELECT channel, TIMESTAMPDIFF(MICROSECOND, ts, NOW(6))/1000 AS lag_ms
FROM hb_channel;
```

### 5.3 关键告警项

| 指标 | 阈值 | 说明 |
| --- | --- | --- |
| `SERVICE_STATE` ≠ ON | 立即告警 | 通道停了 |
| `LAST_ERROR_NUMBER` ≠ 0 | 立即告警 | 复制中断 |
| relay log 磁盘占用 | > 80% | 多通道 × 多 relay log，磁盘吃紧 |
| `COUNT_TRANSACTIONS_IN_QUEUE` | 持续 > 1000 | SQL 线程跟不上 |
| 心跳延迟 | > 10s | 业务可感知 |
| `Retrieved_Gtid_Set` 停滞 | > 5min | IO 线程或网络问题 |

## 六、多源复制 vs 其他方案的选型

| 维度 | 多源复制 | Canal + Kafka | 应用双写 |
| --- | --- | --- | --- |
| 引入组件 | 无 | Canal、Kafka、消费端 | 无（但侵入业务） |
| 数据延迟 | 百毫秒~秒级 | 秒级 | 取决于实现 |
| 数据清洗能力 | 无（原样照搬） | 强 | 强 |
| 冲突处理 | 弱（IDEMPOTENT/跳过） | 强（消费端可定制） | 强 |
| 运维复杂度 | 中 | 高 | 低但代码复杂 |
| 对主库压力 | binlog dump，极小 | 同样极小 | 有查询压力 |
| 适合场景 | 汇总库、冷数据归集 | 实时数仓、CDC 全场景 | 简单小规模 |

**选型建议：**

- 只是想把几个库合起来做只读查询/报表 → **多源复制**，性价比最高；
- 需要数据清洗、格式转换、下发到 ES/数仓 → **Canal/Debezium**；
- 数据量极小、表结构简单 → 应用层同步也能接受。

## 七、实战案例：8 个分库汇总到一个报表库

**背景**：8 个分库（`db_user_0` ~ `db_user_7`），每库 `t_order` 表结构相同，需汇总到 `db_report`。

**步骤 1：统一表结构**

```sql
-- 提前用 gh-ost / pt-online-schema-change 把 8 个库的 t_order 结构对齐
-- 校验：
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA LIKE 'db_user_%' AND TABLE_NAME='t_order'
ORDER BY TABLE_NAME, ORDINAL_POSITION;
```

**步骤 2：确认无主键冲突**

```sql
-- 各库自增起点错开（历史数据已在，需确保未来不冲突）
-- db_user_0: auto_increment_increment=8, offset=1
-- db_user_1: auto_increment_increment=8, offset=2
-- ...
-- 或者业务已用雪花 ID（此时无需处理）
```

**步骤 3：从库建通道**

```sql
-- 8 个通道，脚本化生成
-- change_master_0.sql ~ change_master_7.sql
CHANGE MASTER TO
  MASTER_HOST='10.0.1.11', MASTER_PORT=3306,
  MASTER_USER='repl', MASTER_PASSWORD='***',
  MASTER_AUTO_POSITION=1
FOR CHANNEL 'db_user_0';

-- 过滤系统库 + 只同步需要的库
-- my.cnf:
-- replicate-wild-do-table = db_user_%.t_order
-- replicate-wild-do-table = db_user_%.t_order_item
-- replicate-ignore-db = mysql
```

**步骤 4：启动与验证**

```sql
START REPLICA FOR CHANNEL ALL;

SELECT CHANNEL_NAME, SERVICE_STATE, LAST_ERROR_MESSAGE
FROM performance_schema.replication_connection_status;

-- 对账（关键！）
SELECT COUNT(*), SUM(amount) FROM db_report.t_order;   -- 汇总库
-- 各主库分别求和，再相加比对
```

**踩坑记录：**

1. 忘了加 `replicate-wild-do-table`，结果把 `mysql` 库也同步了，一个主库把从库的 `repl` 用户删了，所有通道全断——**系统库过滤是必做项**；
2. `slave_exec_mode=IDEMPOTENT` 掩盖了主键冲突，直到对账时才发现少了几万行；
3. 主库一次 `ALTER TABLE` 加了列但没同步到其他 7 个库，导致从库报 `Unknown column`，通道卡住 4 小时。

## 八、面试常见追问

**Q1：多源复制和多主复制（Multi-Master）是一回事吗？**

不是。多源复制是"多写一读"（多个主库 → 一个从库）；多主复制通常指多个节点都可写且互相复制（如 MGR、双主双写），后者要解决写冲突和环回（`auto_increment_offset`、`log_slave_updates`）。多源复制是**单向汇聚**，目标是从库只读。

**Q2：从库挂了，重启后各通道会自己恢复吗？**

如果是正常关机（没有 `skip_slave_start`），且元数据存在表中，通道状态会被持久化，重启后自动恢复。但要注意 `master_info_repository=FILE` 时，多通道的元数据文件是 `master.info-<channel>`，容易丢。**一律用 TABLE 模式。**

**Q3：一个从库能挂多少个源？**

理论上限是 `max_replication_channels`（MySQL 8.0 默认 256）。但实际受限于：每个通道一组线程 + 一份 relay log + 一个连接，**超过 10~20 个源就该考虑拆成多个从库或改用 CDC 方案**。线程数开销和 relay log 磁盘压力是主要瓶颈。

**Q4：GTID 模式下，从库突然多出一个源没见过的 GTID，会怎样？**

会直接报错 `ERROR 1789`/`ERROR 1840`，因为 GTID 一致性校验不通过。这通常意味着源端做了 `RESET MASTER` 或者误同步了 `mysql.gtid_executed`。解决方式是核对 `@@gtid_executed` 并注入空事务补齐。

**Q5：多源复制能用于双向同步（双活）吗？**

不能。两个库互相同步会形成环回，数据重复执行，而且多源复制本身是单向设计。双活应该用 MGR（Group Replication）或业务层路由，不要用多源复制硬凑。

**Q6：怎么保证汇总库的数据"最终正确"？**

复制只能保证"最终同步"，不能保证"业务正确"。必须配套：(1) 源端禁用非幂等 DDL；(2) 定期 `pt-table-checksum` 对账；(3) 关键表用 app 层对账任务比对条数与金额；(4) 记录每通道的 `Executed_Gtid_Set` 以便精确定位差异。

## 九、总结

多源复制的本质是**"用原生的复制通道替代自研同步服务"**，它的价值在于零代码、低延迟、运维可控；它的代价是把冲突问题从"应用层可定制逻辑"变成了"数据库层只能跳过"。

用一句话记住它的适用边界：

> **结构一致、分片隔离、只读汇总的场景，多源复制是最优解；一旦需要清洗、转换、双向同步，立刻换 CDC 方案。**

上线前务必确认三件事：GTID 是否开启、系统库是否过滤、对账机制是否就位。这三件做对了，多源复制就是一把非常好用的刀；做错了，它会在某个凌晨给你一个静默的数据不一致。
