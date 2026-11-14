---
title: 【MySQL 中间件】数据库代理层深度解析：ProxySQL 连接复用、读写分离与 MySQL Router 选型
date: 2026-11-14 08:30:00
tags:
  - MySQL
  - ProxySQL
  - 中间件
  - 高可用
  - 连接池
categories:
  - MySQL
author: 东哥
---

# 【MySQL 中间件】数据库代理层深度解析

## 前言

单体应用连一个 MySQL，`HikariCP` 设个 20 连接就够了。但当应用实例扩到 200 个、每个 20 连接，就是 4000 个到数据库的连接——MySQL 每个连接一个线程，上下文切换、内存（`thread_stack` + net buffer）、`table_open_cache` 竞争全部上来，`Threads_running` 一高，RT 直接塌。

常规解法是「加个代理层」，让 4000 个客户端连接复用到 400 个后端连接。但代理层不是插上就完事，它引入了三个新问题：

1. **连接复用（multiplexing）什么时候是安全的？** 事务、session 变量、临时表、prepared statement 全都会让连接被「锁死」。
2. **读写分离的延迟谁负责？** 代理只按规则路由，不保证主从一致。
3. **配置改了为什么不生效？** ProxySQL 有三层配置（disk / memory / runtime），顺序错了就是白改。

这篇以 ProxySQL 为主线，对照 MySQL Router，把原理、配置、Java 侧协作和踩坑讲清楚。

---

## 一、代理层到底解决什么问题

| 问题 | 应用层解决 | 代理层解决 |
|---|---|---|
| 连接数爆炸 | 调小连接池（影响并发） | 连接复用，客户端多、后端少 |
| 读写分离 | 多数据源 + AOP 路由（侵入代码） | SQL 规则自动路由 |
| 主库故障摘除 | 改配置 + 重启 | 健康检查自动摘除 |
| 慢查询治理 | 应用埋点 | `stats_mysql_query_digest` 全局视图 |
| 灰度/影子库 | 改代码 | 规则镜像流量 |
| 分库分表 | 中间件或手写 | ProxySQL 支持有限（ShardingSphere 更强） |

**它不解决**：跨库事务、强一致读、SQL 性能问题。代理是「流量治理层」，不是「数据库能力层」。

---

## 二、ProxySQL 架构：两个端口 + 三层配置

```
        应用（HikariCP × N）
               │  6033（MySQL 协议）
               ▼
      ┌─────────────────────┐
      │      ProxySQL        │
      │  ┌───────────────┐   │
      │  │ Query Processor│  │  ← 规则匹配、改写、缓存
      │  ├───────────────┤   │
      │  │ Connection Pool│  │  ← 到后端的连接池 + 复用
      │  ├───────────────┤   │
      │  │ Monitor        │  │  ← 健康检查、延迟探测
      │  └───────────────┘   │
      └───────┬─────────────┘
              │ 3306
     ┌────────┴────────┐
     ▼                 ▼
  主库(10)          从库(20)
```

- **6033**：业务流量端口，MySQL 协议。
- **6032**：管理端口，也是 MySQL 协议，用 `mysql -uadmin -p -h127.0.0.1 -P6032` 连。

### 2.1 三层配置是最大的坑

```
DISK (sqlite3)  ──LOAD ... FROM DISK──▶  MEMORY  ──LOAD ... TO RUNTIME──▶  RUNTIME
     ▲                                      │                                │
     └──────── SAVE ... TO DISK ────────────┘                                │
                                                                            ▼
                                                                     实际生效的配置
```

| 层 | 含义 | 谁在用 |
|---|---|---|
| `RUNTIME` | 真正生效的内存结构 | 代理线程 |
| `MEMORY` | 可编辑的配置副本 | 你 `INSERT/UPDATE` 的表 |
| `DISK` | SQLite 持久化 | 重启后加载 |

标准操作顺序：

```sql
-- 1. 改 MEMORY 层
INSERT INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections)
VALUES (10, '10.0.0.11', 3306, 1, 200),
       (20, '10.0.0.12', 3306, 1, 200),
       (20, '10.0.0.13', 3306, 1, 200);

-- 2. 生效
LOAD MYSQL SERVERS TO RUNTIME;

-- 3. 持久化（否则重启丢失）
SAVE MYSQL SERVERS TO DISK;
```

**90% 的「配了不生效」都是漏了第 2 步或第 3 步。** 更隐蔽的是：只做了 `LOAD` 没做 `SAVE`，跑了一周重启后配置回到旧值。

---

## 三、连接复用（Multiplexing）：省连接，但会「锁会话」

### 3.1 原理

客户端连接建立后，ProxySQL 并不立刻分配后端连接，而是等第一条 SQL 到来时，从后端连接池里借一条。执行完、且会话状态「干净」时，连接归还池子，可以被其他客户端复用。

```
客户端 A ──┐
客户端 B ──┼──▶ 后端连接 #1（同一时刻只服务一个客户端）
客户端 C ──┘
```

所以 1000 个客户端连接，后端可能只有 50 条。这是「连接数问题」的核心解法。

### 3.2 什么情况下连接不能复用

只要会话状态「不可迁移」，连接就会被标记为 **multiplexing disabled**，直到会话重置：

| 触发条件 | 原因 |
|---|---|
| 开启事务（`BEGIN` / `autocommit=0`） | 事务绑定连接 |
| `SET` 会话变量（`SET NAMES`、`SET time_zone`、`SET sql_mode`） | 状态在连接上 |
| 创建临时表 | 临时表属于会话 |
| `GET_LOCK()` / 用户锁 | 锁绑定会话 |
| `LAST_INSERT_ID()` 依赖 | 返回值绑定连接 |
| 服务端 prepared statement | 句柄绑定连接 |
| `SELECT ... FOR UPDATE` 后续操作 | 需同一事务 |

于是出现一个反直觉现象：**应用里每建立一个连接就执行 `SET NAMES utf8mb4`，multiplexing 直接失效**，后端连接数等于客户端连接数，代理白装。

### 3.3 观测复用率

```sql
-- 管理端口
SELECT * FROM stats_mysql_connection_pool;
```

关键字段：

| 字段 | 含义 |
|---|---|
| `ConnUsed` | 当前被借出的后端连接 |
| `ConnFree` | 空闲可用 |
| `ConnOK` / `ConnERR` | 累计成功/失败 |
| `Queries` | 该 hostgroup 处理的查询数 |
| `Latency_us` | 后端往返延迟 |

复用率粗算：

```
复用率 ≈ 客户端并发连接数 / (ConnUsed 峰值)
```

如果 `ConnUsed` 长期接近客户端连接数，说明复用没生效，去查 `SET` 语句和事务边界。

```sql
-- 看哪些 digest 触发了会话锁定（ProxySQL 2.x）
SELECT * FROM stats_mysql_processlist;
SELECT digest_text, count_star, sum_time
FROM stats_mysql_query_digest
ORDER BY count_star DESC LIMIT 20;
```

---

## 四、查询规则：读写分离的正确姿势

### 4.1 hostgroup 规划

```
hostgroup 10  →  主库（写 + 强一致读）
hostgroup 20  →  从库（普通读）
hostgroup 30  →  影子库 / 灰度库
```

### 4.2 规则表

```sql
-- 写语句 → 主库
INSERT INTO mysql_query_rules
  (rule_id, active, match_digest, destination_hostgroup, apply)
VALUES
  (1, 1, '^INSERT', 10, 1),
  (2, 1, '^UPDATE', 10, 1),
  (3, 1, '^DELETE', 10, 1),
  (4, 1, '^REPLACE', 10, 1),
  (5, 1, '^SELECT.*FOR UPDATE', 10, 1);

-- 强一致读：命中特定注释走主库
INSERT INTO mysql_query_rules
  (rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES
  (10, 1, '^SELECT /\* master:true \*/', 10, 1);

-- 其余读 → 从库
INSERT INTO mysql_query_rules
  (rule_id, active, match_digest, destination_hostgroup, apply)
VALUES
  (100, 1, '^SELECT', 20, 1);

LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

注意：

- `rule_id` **从小到大匹配，命中 `apply=1` 就停止**。所以具体规则必须放在通用规则前面。
- `match_digest` 匹配的是「参数归一化后的 SQL」（`WHERE id = ?`），`match_pattern` 匹配原始文本（可带正则）。
- 默认规则（`rule_id` 最大的 catch-all）建议设 `apply=1`，避免未命中规则时走默认 hostgroup 造成写打从库。

### 4.3 从库延迟：代理不会替你等

`max_replication_lag` 只是「延迟超过阈值就把该从库摘掉」，不是「等到追平再读」。所以：

- 延迟阈值设太小（如 1s）会导致从库频繁抖动进出；
- 设太大（如 60s）会读到很旧的数据；
- **写后立刻读**必须显式走主库，靠注释 / 单独的读主方法 / `/*master*/` 前缀。

```java
// 写后读一致的显式路由
@Select("SELECT /* master:true */ balance FROM account WHERE id = #{id}")
BigDecimal selectForUpdateCheck(@Param("id") Long id);
```

这比「靠代理猜」可靠得多。

---

## 五、健康检查与故障摘除

```sql
UPDATE mysql_servers SET
  max_connections = 300,
  max_replication_lag = 10,
  max_latency_ms = 100
WHERE hostgroup_id = 20;
```

| 参数 | 作用 | 建议 |
|---|---|---|
| `max_connections` | 该后端最大连接数 | 按后端 `max_connections` 的 70% 分配 |
| `max_replication_lag` | 延迟超阈值摘除 | 5~10s，配合业务容忍度 |
| `max_latency_ms` | ping 延迟超阈值摘除 | 100ms 起，避免网络抖动误杀 |
| `mysql-monitor_ping_interval` | ping 间隔 | 默认 10s |
| `mysql-monitor_read_only_interval` | 只读探测 | 用于识别主从切换 |

**故障切换**：ProxySQL 只负责「发现并摘除」，**不负责选主**。选主要靠 MHA / Orchestrator / MGR / 云数据库。切换后主库 IP 变化，需要更新 `mysql_servers`（或用 ProxySQL Cluster 同步）。

```bash
# 常见做法：切换脚本里调管理端口
mysql -uadmin -padmin -h127.0.0.1 -P6032 -e "
  UPDATE mysql_servers SET hostgroup_id=10 WHERE hostname='10.0.0.12';
  UPDATE mysql_servers SET hostgroup_id=20 WHERE hostname='10.0.0.11';
  LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
```

---

## 六、MySQL Router：另一种思路

MySQL Router 是 InnoDB Cluster / ReplicaSet 官方组件，它**从集群元数据读拓扑**，不需要手工维护 host 列表。

| 维度 | ProxySQL | MySQL Router |
|---|---|---|
| 拓扑来源 | 手工配置 `mysql_servers` | InnoDB Cluster 元数据（自动） |
| 端口模型 | 单端口 + 规则路由 | 多端口固定角色：6446 读写 / 6447 只读 |
| SQL 规则/改写 | ✅ 强 | ❌ 无 |
| 查询缓存 | ✅ | ❌ |
| 连接复用 | ✅ multiplexing | ❌ 基本透传 |
| 分片 | 有限 | ❌（Router 不管分片） |
| 运维复杂度 | 中（三层配置） | 低（跟随集群） |
| 适用 | 自建主从、复杂路由 | InnoDB Cluster、官方栈 |

**选择建议**：

- 自建主从 + 需要读写分离/缓存/灰度 → ProxySQL；
- 用 InnoDB Cluster / MGR，想要「零配置跟随拓扑」→ Router；
- 需要分库分表 + 分布式事务 → ShardingSphere-Proxy（另一类产品）。

---

## 七、Java 侧协作：双层连接池的账要算清

### 7.1 连接池参数重算

应用连代理，代理连数据库，是**两层池**：

```
应用实例 200 × maximumPoolSize 20 = 4000 客户端连接
                     ↓ ProxySQL multiplexing
              后端连接 300（主 100 + 从 200）
```

代理生效后，应用侧连接池可以显著调小：

```yaml
spring:
  datasource:
    url: jdbc:mysql://proxysql.internal:6033/order_db?useSSL=false&serverTimezone=Asia/Shanghai
    hikari:
      maximum-pool-size: 8        # 不是越大越好
      minimum-idle: 4
      connection-timeout: 3000
      idle-timeout: 600000
      max-lifetime: 1200000       # 必须小于代理/后端 wait_timeout
      keepalive-time: 300000
```

经验公式：

```
总后端连接 ≈ 峰值 QPS × 平均 RT(秒) × 安全系数(1.5~2)
```

例：峰值 5000 QPS，平均 RT 5ms → 5000 × 0.005 × 1.8 ≈ 45 条后端连接。给 100 条绰绰有余。**连接不是并发能力，线程才是。**

### 7.2 JDBC 参数：别让驱动把复用搞坏

```java
String url = "jdbc:mysql://proxysql:6033/order_db"
    + "?useLocalSessionState=true"        // 驱动本地判断会话状态，减少 SET
    + "&useServerPrepStmts=false"         // 走客户端预编译，避免服务端句柄绑定连接
    + "&cachePrepStmts=true"
    + "&prepStmtCacheSize=256"
    + "&rewriteBatchedStatements=true"
    + "&useCursorFetch=false"
    + "&serverTimezone=Asia/Shanghai";
```

关键点：

| 参数 | 作用 | 为什么和代理有关 |
|---|---|---|
| `useLocalSessionState=true` | 驱动自己记住 autocommit/isolation，不再每次 `SET` | 少发 `SET` → 少锁会话 |
| `useServerPrepStmts=false` | 客户端预编译 | 服务端 prepared statement 绑定后端连接，破坏复用 |
| `cachePrepStmts=true` | 复用客户端 PS 对象 | 减少解析开销 |
| `rewriteBatchedStatements=true` | 批量 INSERT 合并 | 显著降低网络往返 |

### 7.3 不要在应用层再做一次读写分离

很多项目同时开了 `AbstractRoutingDataSource` 和 ProxySQL 规则，结果：

- 应用把 `SELECT` 路由到从库数据源；
- ProxySQL 再按规则路由一次；
- 两层规则不一致时，写后读打到了从库 → 脏读。

**二选一**。代理层做路由，应用层就只保留一个数据源；应用层做路由，代理就只做连接池和故障摘除。

### 7.4 事务边界要短

长事务会让后端连接长时间被占用，复用率归零，还会导致：

- 代理连接池耗尽（`ConnUsed` 打满，新请求排队）；
- 主库 `innodb_history_list_length` 上涨，undo 膨胀；
- 从库延迟。

```java
// 反例：事务里调远程服务
@Transactional
public void createOrder(OrderCmd cmd) {
    orderMapper.insert(cmd.toOrder());
    inventoryClient.deduct(cmd.getSkuId());   // 远程调用，几百 ms
    couponClient.use(cmd.getCouponId());      // 又几百 ms
}

// 正例：事务只包 DB 操作，远程调用放外面（配合本地消息表/事务性发件箱）
public void createOrder(OrderCmd cmd) {
    inventoryClient.deduct(cmd.getSkuId());
    couponClient.use(cmd.getCouponId());
    txTemplate.executeWithoutResult(s -> orderMapper.insert(cmd.toOrder()));
}
```

---

## 八、生产踩坑清单

1. **`SET NAMES` 每连接执行** → multiplexing 失效，后端连接数暴涨。
2. **改了 MEMORY 没 `LOAD ... TO RUNTIME`** → 配置不生效，排查半天。
3. **只 `LOAD` 不 `SAVE`** → 重启回滚，事故延迟一周爆发。
4. **规则顺序错**：`^SELECT` 放在 `^SELECT ... FOR UPDATE` 前面 → 加锁读打到从库，业务出现「锁不住」。
5. **`max_replication_lag` 设 0** → 所有从库被摘除，读全部压主库。
6. **XA 事务经过 ProxySQL** → 不支持（连接复用无法保证 XA 粘性），分布式事务要走别的方案。
7. **`KILL` 语句** → 代理上 kill 的是客户端连接，后端连接可能继续跑；要在后端 kill。
8. **字符集不一致** → 代理透传，但客户端 `character_set_client` 与表不一致时仍会乱码；统一 utf8mb4。
9. **`Prepared statement needs to be re-prepared`（1615）** → 通常是 DDL 后服务端 PS 失效，配合 `useServerPrepStmts=false` 或重试。
10. **代理单点** → ProxySQL 自身要做主备 + keepalived/VIP，或用 ProxySQL Cluster。

---

## 九、面试追问

**Q1：ProxySQL 的连接复用是怎么实现的？**
A：客户端连接与后端连接解耦，SQL 到达时从池里借后端连接，执行完且会话状态干净就归还。会话一旦有事务、会话变量、临时表、用户锁、服务端 PS，就被标记为不可复用。

**Q2：为什么 `SET NAMES utf8mb4` 会破坏复用？**
A：它是会话级变量，状态绑定在具体连接上，代理不能把它带到别的客户端会话里，只能锁定该连接直到会话重置。

**Q3：读写分离后如何保证写后读一致？**
A：显式路由（SQL 注释 / 独立方法走主库）、或写后一段时间内强制读主、或用 GTID 等待（`WAIT_FOR_EXECUTED_GTID_SET`）。代理的 `max_replication_lag` 只能摘除延迟过大的从库，不保证一致性。

**Q4：ProxySQL 三层配置为什么这么设计？**
A：RUNTIME 是无锁读的热路径结构，MEMORY 是可编辑副本，DISK 是持久化。分层的目的是「改配置不影响正在服务的流量」，但代价是必须显式 LOAD/SAVE。

**Q5：ProxySQL 能替代分库分表中间件吗？**
A：不能。它能做规则路由和简单分片（按 schema 或注释），但不做 SQL 解析重写、跨分片聚合、分布式事务。分库分表要用 ShardingSphere 这类。

**Q6：应用连接池和代理连接池怎么配？**
A：应用侧调小（8~16），代理侧按「峰值 QPS × RT × 系数」估算后端连接；关键是让代理的复用真正生效，而不是把连接数从应用搬到代理。

---

## 总结

代理层的本质是**把「连接」和「路由」从应用里抽出来，做成一个可观测、可动态调整的流量层**。它的收益（连接复用、故障摘除、统一治理）很实在，但前提是：

1. 会话保持干净（少 `SET`、短事务、客户端预编译）；
2. 配置三层顺序正确（MEMORY → RUNTIME → DISK）；
3. 读写分离的规则与一致性策略想清楚，不要和应用层重复。

把这三件事做好，代理层就是稳定的基础设施；做不好，它就是新的故障源。

下一篇进入 AI 方向，聊一个很少被 Java 工程师碰、但效果很猛的话题：ColBERT 的 late interaction 检索——为什么它能在不牺牲召回的前提下，把「重排」的延迟压下来。
