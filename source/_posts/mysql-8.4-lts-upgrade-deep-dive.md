---
title: 【MySQL 实战】MySQL 8.4 LTS 升级深度实战：破坏性变更、兼容性排查与 Java 侧回归
date: 2026-10-30 08:00:00
tags:
  - MySQL
  - 数据库
  - 版本升级
  - LTS
categories:
  - 数据库
author: 东哥
---

# 【MySQL 实战】MySQL 8.4 LTS 升级深度实战

## 前言

2026 年 4 月，MySQL 8.0 社区版正式结束生命周期（EOL）。这意味着继续停留在 8.0 的团队，要么买商业支持，要么尽快规划升级。而 8.4 是当前唯一的 **LTS（Long Term Support）** 版本，支持到 2032 年 4 月；9.x 系列属于 Innovation Release，每季度发版、生命周期短，适合尝鲜不适合长期承载核心库。

但升级 8.0 → 8.4 并不是"改个 yum 源重启"这么简单。8.4 引入了若干**破坏性变更**，其中最狠的一条是 `mysql_native_password` 默认禁用——这条直接把一大批老 Java 应用挡在门外。本文从版本节奏、破坏性变更、升级路径、Java 侧回归、性能回归排查五个维度完整拆一遍，都是生产上真正会踩的坑。

<!-- more -->

## 一、先把版本节奏搞清楚

| 版本 | 类型 | GA 时间 | EOL | 适合场景 |
|---|---|---|---|---|
| 5.7 | 旧 LTS | 2015-10 | 2023-10（已 EOL） | 必须升级 |
| 8.0 | LTS | 2018-04 | 2026-04（已 EOL） | 过渡中 |
| 8.4 | **LTS** | 2024-04 | 2032-04 | **核心生产库首选** |
| 9.x | Innovation | 2024-07 起每季度 | 下一个 LTS 发布即终止 | 预研、非核心 |

关键认知：**8.4 不是 8.0 的"小版本"**，它是 8.0 之后第一个 LTS，把 8.1~8.3 三个 Innovation 版本里的变更全部合并进来了。所以 8.0 → 8.4 实际跨越了四个版本的功能与行为变更。

升级路线有两种：

```text
路线 A（推荐，同大版本）：8.0.36+ → 8.4.x  直接 in-place 升级
路线 B（跨大版本）：5.7 → 8.0 → 8.4   必须逐级，不能跳
路线 C（停机窗口充足）：逻辑导出导入（mysqldump / mysqlsh util dumpAndLoad）
```

注意 8.0 侧的前置要求：**必须先升到 8.0.36 或更高**（官方推荐 8.0 最后一个版本），否则 `mysqlsh` 的升级检查器给出的结论不可靠。

## 二、破坏性变更清单（升级前必读）

| 变更项 | 8.0 行为 | 8.4 行为 | 影响面 |
|---|---|---|---|
| `mysql_native_password` | 可用 | **默认禁用**，需 `--mysql-native-password=ON` 才启用 | ★★★★★ 老客户端/老驱动全挂 |
| `mysql_native_password` 插件本身 | 内置 | 8.4 起降级为可选组件，**9.0 彻底移除** | ★★★★★ 必须迁移到 `caching_sha2_password` |
| `--skip-host-cache` / `--skip-name-resolve` 旧参数 | 支持 | 部分旧参数被移除/改名为 `--host-cache-size=0` | ★★☆ 启动直接失败 |
| `mysqlpump` | 可用（已弃用） | **移除** | ★★★ 备份脚本要换 |
| `mysql_upgrade` | 存在 | 8.0.16 起已废弃，8.4 移除 | ★★ 升级脚本要改 |
| `expire_logs_days` | 可用 | 移除，用 `binlog_expire_logs_seconds` | ★★ 配置项报错 |
| 默认认证插件 | `caching_sha2_password` | 同左，但**要求 TLS 或 RSA 公钥交换** | ★★★★ 连接串要加参数 |
| 保留字/关键字 | — | 新增保留字（如 `MANUAL`、`PARALLEL` 相关） | ★★ 隐式 SQL 报错 |
| `INFORMATION_SCHEMA` 部分表 | 存在 | 字段/行为调整，查询性能改善但结果集结构变化 | ★★ 监控采集脚本 |
| 默认 `innodb_redo_log_capacity` | 100MB（8.0.30+） | 同上，但自适应 flush 行为优化 | ★★ 写入吞吐变化 |
| 复制术语 | `MASTER/SLAVE` | 全面改为 `SOURCE/REPLICA`，旧语法仍兼容但告警 | ★ 脚本告警 |

### 2.1 最致命的一条：认证插件

8.4 启动时如果检测到还有用户使用 `mysql_native_password`，并且没有显式开启该插件，会直接报错：

```text
[ERROR] [MY-000067] [Server] Plugin mysql_native_password reported:
  'mysql_native_password' is deprecated and will be removed in a future release.
```

更麻烦的是**客户端侧**。Java 应用常见三种翻车姿势：

1. 老版本 Connector/J（5.1.x、8.0.11 之前）**不支持** `caching_sha2_password`，连接直接抛 `Unable to load authentication plugin 'caching_sha2_password'`。
2. Connector/J 8.x 支持，但在**非 SSL 连接**下需要服务端 RSA 公钥，未加 `allowPublicKeyRetrieval=true` 会报 `Public Key Retrieval is not allowed`。
3. 连接池里已经建立的旧连接，在升级后第一次重连才暴露问题——**灰度期间看起来一切正常，切换后批量雪崩**。

正确做法是"**先双插件并行，再逐步迁移**"：

```sql
-- 第一步：升级前先确认哪些账号还在用 native password
SELECT user, host, plugin
FROM mysql.user
WHERE plugin = 'mysql_native_password';

-- 第二步：8.4 上临时开启（写在 my.cnf，不是运行时）
-- [mysqld]
-- mysql-native-password=ON

-- 第三步：逐个账号切换到 caching_sha2_password
ALTER USER 'app_user'@'%'
  IDENTIFIED WITH caching_sha2_password BY 'NewP@ssw0rd';

-- 第四步：确认应用侧（JDBC + 连接池）全部改造完成后再关掉
```

Java 侧连接串最终形态：

```properties
jdbc:mysql://db-host:3306/app?useSSL=true\
  &requireSSL=false\
  &allowPublicKeyRetrieval=true\
  &serverTimezone=Asia/Shanghai\
  &useUnicode=true&characterEncoding=utf8\
  &rewriteBatchedStatements=true\
  &cachePrepStmts=true&prepStmtCacheSize=250
```

> 生产建议：`allowPublicKeyRetrieval=true` 只在**内网**且无法配 TLS 时临时使用。它允许客户端向服务端索取 RSA 公钥，理论上存在中间人风险。正规做法是开启 TLS 或预置 `serverRSAPublicKeyFile`。

## 三、升级检查器：别跳过这一步

MySQL Shell 自带 `checkForServerUpgrade`，能扫出 90% 的兼容性问题，包括保留字冲突、字符集问题、认证插件、废弃参数、分区表不兼容等。

```bash
# 1. 安装 mysqlsh（8.4 版本，与目标版本一致）
# 2. 对源库跑检查（只读，不锁表，但会有元数据查询压力，建议低峰）
mysqlsh --uri root@old-host:3306 \
  -- util checkForServerUpgrade \
  --outputFormat=JSON \
  --outputFile=/tmp/upgrade_report.json

# 3. 关注三档结论
#    errors   -> 必须修，否则升级失败
#    warnings -> 升级后行为变化，需评估
#    notices  -> 提示信息
```

检查报告里最容易被忽略的是 **`--outputFormat=JSON` 之外的普通输出**里那条：

```text
The following issues were found:
  1) Usage of db objects with names conflicting with new reserved keywords.
     Table: app.order   Column: rank
```

`rank`、`groups`、`system`、`manual` 这些在 8.0 就已经是保留字，但 8.4 又新增了一批。**表名/列名撞上保留字的，升级后 SELECT 会直接语法错误**——而这类错误往往在某个冷门接口才触发，测试环境根本覆盖不到。

## 四、生产升级步骤（可回滚版）

```text
T-7d   ：跑 checkForServerUpgrade，出问题清单并逐项修复
T-3d   ：在预发环境用真实数据量做全量演练（含从库提升）
T-1d   ：全量备份 + binlog 位点记录 + 应用侧连接池参数预发验证
T-0    ：
  1. 停写（或切只读）           SET GLOBAL super_read_only = ON;
  2. 记录位点                   SHOW MASTER STATUS;   -- 记 File + Position
  3. 优雅停库                   mysqladmin shutdown
  4. 备份 datadir（物理拷贝，最快回滚手段）
  5. 替换二进制 + 更新 my.cnf   （保留旧 datadir 备回滚）
  6. 启动 8.4，观察 error log   （重点看认证插件、废弃参数）
  7. 跑 mysqlsh 校验           util checkForServerUpgrade 反向确认
  8. 逐表 ANALYZE TABLE 重建统计信息
  9. 从库依次升级（先升从库再升主库更安全）
  10. 打开写流量（先 1% → 10% → 100%）
T+1d   ：观察慢查询、连接数、复制延迟、错误日志
```

**回滚方案**：8.4 → 8.0 是**不支持降级**的（数据字典版本号单向）。唯一可靠的回滚是把备份的 8.0 datadir 拷回来，或者用逻辑备份重建。所以第 4 步的物理备份不是可选项。

## 五、Java 侧回归清单

升级数据库，Java 应用的回归点比想象的多：

| 回归项 | 具体风险 | 验证方法 |
|---|---|---|
| JDBC 驱动 | Connector/J 8.0.x 部分版本对 8.4 有兼容 bug | 升到 9.x（`com.mysql:mysql-connector-j:9.1.0+`） |
| 认证 | `caching_sha2_password` + 非 TLS | 连接池满负荷重连压测 |
| 时区 | `serverTimezone` 未设导致时间偏移 8 小时 | 插入 `DATETIME` 后比对 |
| 批处理 | `rewriteBatchedStatements` 行为微调 | 批量插入 10w 行耗时对比 |
| XA / 分布式事务 | 8.4 对 XA 的 `XID` 处理更严格 | Seata AT 模式全链路 |
| 保留字 | 列名/表名撞新保留字 | 跑全量 SQL 语法检查 |
| 元数据查询 | `INFORMATION_SCHEMA` 字段变化 | 监控/巡检脚本 |
| 字符集 | 默认仍是 `utf8mb4_0900_ai_ci`，但排序规则比较行为 | 排序、去重、唯一索引场景 |
| JSON | 8.4 JSON 函数对非法输入更严格 | JSON 字段写入链路 |
| 分区表 | 部分旧分区定义不支持 | `SHOW CREATE TABLE` 逐表核对 |

Connector/J 升级本身就有一个坑：9.x 把 `com.mysql.jdbc.Driver` 彻底移除，只保留 `com.mysql.cj.jdbc.Driver`。老项目 `spring.datasource.driver-class-name` 里写旧类名的，启动直接 `ClassNotFoundException`。

```yaml
spring:
  datasource:
    driver-class-name: com.mysql.cj.jdbc.Driver   # 必须
    hikari:
      connection-timeout: 3000
      validation-timeout: 1000
      maximum-pool-size: 20
      # 升级期间建议打开，尽早暴露失效连接
      keepalive-time: 30000
```

## 六、性能回归：升级后一定要做的三件事

**第一件：重建统计信息。**

```sql
-- 8.0 的统计信息在 8.4 上可能不准，尤其是直方图
ANALYZE TABLE app.orders UPDATE HISTOGRAM ON status, created_at WITH 100 BUCKETS;
-- 或者批量
SELECT CONCAT('ANALYZE TABLE ', table_schema, '.', table_name, ';')
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema');
```

**第二件：抓 Top SQL 对比执行计划。**

8.4 的优化器在 **hash join** 的成本模型上有调整，某些 8.0 上走 `BNL` 的查询会改走 `Hash Join`，大表关联可能从"慢"变"快"，也可能反过来。用 `EXPLAIN ANALYZE` 逐条比对核心 SQL：

```sql
EXPLAIN ANALYZE
SELECT o.id, o.amount, u.nickname
FROM orders o
JOIN users u ON u.id = o.user_id
WHERE o.created_at >= '2026-10-01'
  AND o.status = 'PAID';
```

**第三件：盯 InnoDB 层指标。**

```sql
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';
SHOW GLOBAL STATUS LIKE 'Innodb_row_lock%';
SHOW GLOBAL STATUS LIKE 'Threads_connected';
```

8.4 调整了 redo log 的自适应刷盘策略，写入型业务的 `innodb_redo_log_capacity` 可能需要从默认值往上调（比如 2~4GB），否则高并发下会出现 `log file sync` 抖动。

## 七、面试常见追问

**Q1：8.4 相比 8.0 最大的不兼容点是什么？**

`mysql_native_password` 默认禁用。它同时影响服务端（账号认证）和客户端（驱动能力），是升级中最容易造成全站不可用的一条。其次是保留字扩充和 `mysqlpump`、`mysql_upgrade` 等工具移除。

**Q2：为什么 8.4 强制推 `caching_sha2_password`？**

SHA-256 加盐 + 服务端缓存已认证凭据，避免每次连接都做完整哈希；同时支持 TLS 通道内的快速认证和 RSA 公钥交换的非 TLS 认证。相比 `mysql_native_password` 的 SHA1 两次哈希，抗彩虹表和中间人能力强得多。

**Q3：in-place 升级和逻辑升级怎么选？**

in-place 快（分钟级到小时级），但不可回滚、依赖数据字典升级、跨大版本不能跳。逻辑升级慢（小时级到天级），但可以顺便做字符集/引擎/分区整理，且能在新库上验证后再切流量。核心库建议 in-place + 物理备份兜底，超大库（TB 级）建议逻辑迁移配合双写。

**Q4：升级后发现某张表查询变慢，怎么定位？**

先 `ANALYZE TABLE` 重建统计信息，再 `EXPLAIN ANALYZE` 看实际行数与预估行数差异；差异大说明基数估算失准，可以补直方图。其次看是否命中新保留字导致索引失效，最后用 `optimizer_trace` 看优化器决策路径。

**Q5：从库升级顺序为什么建议先升从库？**

从库不承载写流量，先升从库可以在低风险环境验证复制兼容性（8.4 的 binlog 事件格式、GTID 行为有调整）。从库升级完成且复制正常，再对主库做切换，出问题时可以把从库当验证环境而不是生产灾难。

## 八、总结

| 阶段 | 关键动作 | 判断标准 |
|---|---|---|
| 评估 | `checkForServerUpgrade` + 认证插件盘点 | errors 清零 |
| 改造 | Connector/J 9.x + `caching_sha2_password` | 预发全链路通过 |
| 演练 | 真实数据量 in-place 演练 | 耗时、回滚耗时可控 |
| 切换 | 停写 → 备份 → 升级 → 灰度放量 | 错误率、P99 无异常 |
| 稳定 | 统计信息重建 + 慢 SQL 对比 | 无新增慢查询 |

MySQL 8.4 升级本质是一次"**认证体系 + 优化器行为**"的双重迁移，数据库侧的活其实不多，真正的工作量在 Java 应用侧。提前把驱动、连接串、连接池、XA 这几块打透，升级窗口就能压缩到 30 分钟以内。
