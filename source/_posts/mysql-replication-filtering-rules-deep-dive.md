---
title: 【MySQL 底层】复制过滤规则深度解析：replicate-do-db 的跨库陷阱、GTID 空洞与替代方案
date: 2026-11-19 08:20:00
tags:
  - Java
  - MySQL
  - 主从复制
  - GTID
  - 数据库
categories:
  - 数据库
author: 东哥
---

# 【MySQL 底层】MySQL 复制过滤规则深度解析

## 前言

先看一个真实事故。

某业务做库表拆分，DBA 在从库上加了这么一行：

```ini
replicate-do-db = order
```

意图很明确：这个从库只同步 `order` 库，别把整个实例几百个库都拉过来。

三个月后做主从切换，新主库上 `order` 库少了 11 万行数据。排查发现：业务代码里有一段「跨库写入」——连接默认库是 `order`，但 SQL 写的是 `UPDATE user.points SET ...`。在 `replicate-do-db=order` 的规则下，这条语句被**静默过滤**了。

没有报错，没有延迟，`Seconds_Behind_Master` 一直是 0，GTID 集合完全一致。**唯一不对劲的地方，是数据对不上。**

这就是复制过滤最危险的特征：它不制造故障，它制造的是**沉默的数据分叉**。本文把过滤规则的作用域、格式依赖、GTID 交互和正确用法讲清楚。

---

## 一、过滤发生在哪一侧：这是第一个分水岭

MySQL 的复制过滤分两类，语义完全不同：

| 配置位置 | 参数 | 作用点 | 后果 |
|---|---|---|---|
| 源库（master） | `binlog-do-db` / `binlog-ignore-db` | 写 binlog 时 | **binlog 本身不完整** |
| 从库（replica） | `replicate-do-db` / `replicate-ignore-db` / `replicate-wild-do-table` … | 应用 relay log 时 | binlog 完整，但从库数据不全 |

### 1.1 源库过滤几乎总是错的

`binlog-do-db` 会让不匹配的事务**根本不进入 binlog**。这意味着：

- 基于 binlog 的 **PITR（按时间点恢复）** 无法恢复到一致状态；
- **CDC**（Canal / Debezium / Maxwell）拿不到完整变更；
- 新增从库、Clone、逻辑备份都可能缺数据；
- 最要命的是：这个「缺失」在源库上完全看不出来，只有当你需要 binlog 的那一天才会爆炸。

所以业界共识很明确：**不要在源库做过滤**。要拆分就拆实例，要部分同步就用 CDC 或逻辑导出。

### 1.2 从库过滤：能用，但必须理解语义

从库过滤至少保证 binlog 完整，代价是从库数据不全。它适合的场景很窄：

- 一个从库专门给某个业务做只读查询；
- 临时数据迁移过渡期；
- 明确的「单库从库」且业务保证不跨库写。

即便如此，也要用对参数。

---

## 二、`replicate-do-db` 到底匹配什么

这是全文最重要的一节。

### 2.1 语句格式 vs 行格式，行为不同

MySQL 文档里有一句很容易被略过的话：

> 使用语句格式复制时，`replicate-do-db` 基于**默认数据库**（`USE` 的库）判断；使用行格式复制时，基于**表实际所在的数据库**判断。

看这个例子：

```sql
USE order;
UPDATE user.points SET points = points + 10 WHERE user_id = 1001;
```

| binlog 格式 | 规则 `replicate-do-db=order` | 结果 |
|---|---|---|
| STATEMENT | 默认库是 `order` → 匹配 | 语句被复制 ✅ |
| ROW | 表在 `user` 库 → 不匹配 | 变更被过滤 ❌ |

同一行配置，换个 `binlog_format`，结果完全相反。如果生产是 ROW、测试是 STATEMENT，你会得到「测试环境一切正常，上线后数据静默丢失」的经典剧本。

### 2.2 更隐蔽的反向案例：源库 `binlog-do-db`

```sql
USE order;
INSERT INTO user.points_log(user_id, delta) VALUES (1001, 10);
```

配置 `binlog-do-db=order`：

- 默认库是 `order` → **这条语句被写入 binlog**；
- 但它写的是 `user` 库的表；
- 从库如果没有 `user.points_log` 或结构不同 → `1146 Table doesn't exist`，复制直接停。

于是源库过滤既能「漏」，也能「多」，取决于语句的默认库和实际表的错配。这类问题在存储过程、触发器、事件调度里尤其常见，因为它们的默认库继承关系更难判断。

### 2.3 表级规则才是可预测的

```ini
replicate-wild-do-table = order.%
```

表级规则按**实际表名**匹配，不受 `USE` 影响，也不受语句跨库影响。通配符：

- `%` 匹配任意多个字符；
- `_` 匹配单个字符；
- 需要转义时用 `\%`。

```ini
# 只同步 order 库，但排除日志表
replicate-wild-do-table = order.%
replicate-wild-ignore-table = order.%_log
```

注意：**`replicate-wild-ignore-table` 的优先级高于 do 规则**，ignore 命中就丢弃。

---

## 三、规则的匹配顺序：混用是事故之源

MySQL 的过滤规则不是「所有规则取交集」，而是有明确的判定顺序：

1. 先判断**库级**规则（`replicate-do-db` / `replicate-ignore-db`）；
2. 再判断**表级**规则（`replicate-do-table` / `replicate-wild-do-table` 等）；
3. 命中即决定，不再往下走。

这意味着：

```ini
replicate-do-db = order
replicate-wild-do-table = user.points_log
```

你以为「order 库 + user.points_log 表」都会同步，实际上库级规则先命中/拦截，表级规则可能根本没机会生效。**库级与表级混用，行为很难在脑子里推演。**

工程建议只有一条：**只用 `replicate-wild-do-table` / `replicate-wild-ignore-table`，不要用 `*-do-db`。**

---

## 四、GTID 模式下的「假一致」

这是复制过滤最反直觉的部分。

### 4.1 从库过滤：GTID 齐全，数据缺失

在 GTID 模式下，从库收到一个事务后：

1. 事务写入 relay log；
2. 事务的 GTID 被记入 `gtid_executed`；
3. 应用阶段被过滤规则跳过，**数据不变**。

于是：

```sql
-- 源库
SELECT @@GLOBAL.gtid_executed;
-- 3f9a...:1-982341

-- 从库
SELECT @@GLOBAL.gtid_executed;
-- 3f9a...:1-982341   ← 一模一样
```

`gtid_executed` 相同、`Seconds_Behind_Source=0`、`Replicate_Wild_Do_Table` 也符合预期——所有监控都是绿的，**但数据就是不一样**。

更麻烦的是后续操作：

- 用这个从库再做一次级联复制，下游会继承同样的缺口；
- 用 `mysqldump --set-gtid-purged=ON` 备份恢复，GTID 会「跳过」那些从未应用的变更；
- 主从切换后，新主库直接缺数据，而且找不到任何错误日志。

### 4.2 源库过滤：GTID 本身缺失

源库 `binlog-do-db` 更彻底：事务不写 binlog，GTID 也不产生。`gtid_executed` 是自洽的，但它描述的是一个**比真实数据更小的历史**。任何依赖 binlog 的系统（CDC、审计、恢复）都会静默偏差。

### 4.3 如何发现

```sql
-- 源库与从库分别执行，比较差集（需在从库执行，参数为源库集合）
SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '3f9a...:1-982341');
```

但注意：**这个方法只能发现「少事务」，发现不了「事务在但数据被过滤」**。从库过滤恰恰是后者。

真正可靠的对账手段是数据层校验：

- `pt-table-checksum` 分块校验（注意它会走复制，过滤表要显式排除）；
- 业务侧行数/金额/最大 ID 的周期对账；
- 双写期做逐条 diff。

---

## 五、动态修改与多源复制

### 5.1 `CHANGE REPLICATION FILTER`

MySQL 5.7+ 支持在线修改，不必重启：

```sql
CHANGE REPLICATION FILTER
  REPLICATE_WILD_DO_TABLE = ('order.%'),
  REPLICATE_WILD_IGNORE_TABLE = ('order.%_log');
```

多源复制必须指定通道，否则会改到所有通道：

```sql
CHANGE REPLICATION FILTER
  REPLICATE_WILD_DO_TABLE = ('order.%')
  FOR CHANNEL 'ch_order';
```

这是一个高频事故：多源环境下漏写 `FOR CHANNEL`，把另外几个通道的规则一起覆盖了。

### 5.2 查看当前规则

```sql
SHOW REPLICA STATUS\G
```

关注这些字段：

```
Replicate_Do_DB:
Replicate_Ignore_DB:
Replicate_Do_Table:
Replicate_Ignore_Table:
Replicate_Wild_Do_Table: order.%
Replicate_Wild_Ignore_Table: order.%_log
```

多源复制用 `SHOW REPLICA STATUS FOR CHANNEL 'ch_order'`。

---

## 六、过滤与高可用组件的冲突

| 组件 | 是否兼容过滤 | 说明 |
|---|---|---|
| 异步/半同步复制 | 兼容 | 但数据可能不一致 |
| MGR（组复制） | **不支持** | 成员必须数据完全一致，过滤会导致成员分叉 |
| Clone 插件 | 不适用 | 整实例物理拷贝，绕过过滤 |
| Orchestrator / MHA | 需注意 | 切换后新主可能缺数据，拓扑修复会放大问题 |
| Canal / Debezium | 不适用 | 它们读源库 binlog，源库过滤会让 CDC 缺事件 |
| 逻辑备份 `mysqldump` | 不适用 | 导出的是从库现有数据，缺口被固化 |

特别说 MGR：组复制要求所有成员应用相同的事务集，复制过滤在组复制通道上不被支持。**只要用了 MGR，就别想用过滤做库表裁剪**，只能在业务层拆库或拆实例。

---

## 七、正确做法：四条路线

### 路线 1：拆实例（首选）

需要独立同步的业务，直接独立实例 + 独立复制链路。成本是机器，收益是语义清晰：没有过滤，就没有隐性缺口。

### 路线 2：CDC 做逻辑订阅

源库保持完整 binlog（`binlog_format=ROW`、`binlog_row_image=FULL`），用 Canal/Debezium 按库表订阅，写到目标库或消息队列。

优点：

- 源库 binlog 完整，PITR 不受影响；
- 过滤逻辑在 CDC 侧，可观测、可重放；
- 支持字段级裁剪、脱敏、路由。

### 路线 3：必须过滤时，只用表级规则

```ini
replicate-wild-do-table = order.%
replicate-wild-ignore-table = order.%_log
```

并且：

- 强制 `binlog_format=ROW`；
- 应用层禁止跨库写（用 ArchUnit/代码扫描卡住 `db1.t` 这种写法）；
- 上线前用真实 SQL 回放验证过滤结果。

### 路线 4：逻辑导出 + 增量补齐

初始化用 `mysqldump --databases order` 或 `mysqlpump`，增量用 CDC。适合迁移期，不适合长期架构。

---

## 八、Java 侧：把「过滤配置」纳入启动自检

复制过滤的问题在于「配置错了不会报错」。那就让它报错。

```java
@Component
public class ReplicationFilterGuard implements ApplicationRunner {

    private final JdbcTemplate jdbc;

    @Override
    public void run(ApplicationArguments args) {
        List<Map<String, Object>> rows = jdbc.queryForList("SHOW REPLICA STATUS");
        if (rows.isEmpty()) {
            return; // 不是从库
        }
        Map<String, Object> status = rows.get(0);

        List<String> problems = new ArrayList<>();
        for (String col : List.of("Replicate_Do_DB", "Replicate_Ignore_DB",
                                  "Replicate_Do_Table", "Replicate_Ignore_Table")) {
            Object v = status.get(col);
            if (v != null && !v.toString().isBlank()) {
                problems.add(col + "=" + v);
            }
        }

        Object wildDo = status.get("Replicate_Wild_Do_Table");
        if (wildDo != null && !wildDo.toString().isBlank()) {
            log.warn("从库启用了表级复制过滤: {}", wildDo);
        }

        if (!problems.isEmpty()) {
            // 库级过滤：直接告警，要求改用表级规则
            log.error("检测到库级复制过滤，存在跨库写入被静默丢弃的风险: {}", problems);
            meterRegistry.counter("mysql.replication.filter.risky").increment();
        }
    }
}
```

再配合一个数据对账任务：

```java
// 每天凌晨对核心表做行数与金额校验
long sourceCount = sourceJdbc.queryForObject("SELECT COUNT(*) FROM order.orders", Long.class);
long replicaCount = replicaJdbc.queryForObject("SELECT COUNT(*) FROM order.orders", Long.class);
if (Math.abs(sourceCount - replicaCount) > threshold) {
    alert("order.orders 主从行数偏差: source=%d replica=%d".formatted(sourceCount, replicaCount));
}
```

行数对账有局限（删除+插入可能抵消），但对「整段事务被过滤」这类事故非常敏感，成本也低。

---

## 九、切换演练清单

主从切换会把「从库缺数据」直接变成「生产缺数据」。演练时逐项确认：

1. `SHOW REPLICA STATUS` 的 `Replicate_*` 字段是否符合预期；
2. 源库与从库核心表行数、金额、最大 ID 是否一致；
3. `pt-table-checksum` 是否通过（过滤表要单独处理）；
4. `gtid_executed` 是否一致（一致不代表数据一致，只代表事务集一致）；
5. 切换后 CDC 是否能从新主继续消费；
6. 备份恢复演练是否覆盖被过滤的表。

---

## 十、面试追问

**Q1：`replicate-do-db` 在 ROW 和 STATEMENT 下行为一样吗？**

不一样。STATEMENT 按默认库（`USE` 的库）判断，ROW 按表实际所在库判断。跨库语句在两种格式下可能得到完全相反的结果。

**Q2：为什么说源库 `binlog-do-db` 很危险？**

它让不匹配的事务根本不进 binlog，破坏 PITR、CDC、克隆和增量恢复，而且源库本身看不出任何异常。

**Q3：从库过滤后，GTID 集合会不一致吗？**

通常一致。被过滤的事务仍写入 relay log 并把 GTID 记入 `gtid_executed`，只是不应用数据。所以「GTID 一致」不能证明「数据一致」。

**Q4：MGR 能用复制过滤吗？**

不能。组复制要求成员数据完全一致，过滤会导致成员分叉，官方不支持在组复制通道上使用复制过滤。

**Q5：那正确的库表裁剪方案是什么？**

优先级：拆实例 > CDC 逻辑订阅 > 表级 `replicate-wild-do-table`（强制 ROW + 禁止跨库写）。源库过滤不在选项里。

---

## 十一、总结

复制过滤的坑，本质是三个「不对称」：

1. **格式不对称**：同一条规则在 STATEMENT / ROW 下语义不同；
2. **层级不对称**：库级规则先于表级规则，混用时行为难推演；
3. **观测不对称**：GTID 一致、延迟为 0、监控全绿，但数据已经少了。

所以结论很硬：

- 源库永不过滤；
- 从库只用表级规则；
- 跨库写必须从代码层禁掉；
- 把过滤配置和数据对账纳入启动自检与日常巡检。

数据复制这件事，最贵的从来不是带宽，而是**你以为同步了**。
