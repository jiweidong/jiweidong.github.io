---
title: 【MySQL 运维】用户权限体系与安全加固深度实战：最小权限、角色与审计落地
date: 2026-09-24 08:40:00
tags:
  - MySQL
  - 安全
  - 运维
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 运维】用户权限体系与安全加固深度实战：最小权限、角色与审计落地

## 从一次"全权限账号被拖库"说起

某次复盘会，事故链条是这样的：一个内部数据同步服务用了 `root@'%'` 连库，密码写死在 Git 仓库里（后来仓库被误设为公开），攻击者拿这个账号 `SELECT ... INTO OUTFILE` 导出了全量用户表，还用 `LOAD_FILE()` 读了服务器上的配置文件。

**三处失误，每一处都能独立致命：**

1. 用了 root 而不是最小权限账号；
2. `host` 写成 `%`，任意机器可连；
3. 密码进代码仓库，且没有加密/轮转机制。

MySQL 的权限体系平时没什么存在感，但它是数据库安全的**第一道也是最后一道防线**。这篇文章把权限模型、账号安全、审计和加固清单一次性讲透，并给出 Java 应用侧的配合姿势。

## 一、权限模型：认证与授权是两个阶段

MySQL 处理一个连接请求分两步，很多人把它们混为一谈：

```
阶段 1：认证（Authentication）—— 你是谁？
  Client 发起连接 → MySQL 用 (user, host, password) 三元组匹配 mysql.user 表
  → 匹配成功则建立连接，否则报 Access denied for user

阶段 2：授权（Authorization）—— 你能干什么？
  每条 SQL 执行前 → 检查当前用户是否拥有该操作对应的权限
  → 权限列表在连接建立时被加载进内存（所以 GRANT 后老连接可能不生效）
```

**关键点：`user` + `host` 是联合主键。** `'app'@'192.168.1.%'` 和 `'app'@'%'` 是两个完全不同的账号。`host` 支持通配符：

| host 写法 | 含义 |
| --- | --- |
| `'app'@'localhost'` | 只能本机 socket / 127.0.0.1 连接 |
| `'app'@'192.168.1.10'` | 只能从这一个 IP 连 |
| `'app'@'192.168.1.%'` | 内网网段（生产推荐） |
| `'app'@'%'` | 任意主机（**危险，禁止用于业务账号**） |
| `''@'localhost'` | 匿名用户（**务必删除**） |

匹配规则是**最长匹配优先**：`'app'@'192.168.1.10'` 比 `'app'@'%'` 更精确，所以同一用户名可以按来源 IP 授予不同权限。

**权限信息的存储位置**（MySQL 8.0 起权限表迁到 InnoDB）：

```sql
-- 全局权限（*.*）
SELECT * FROM mysql.user WHERE user = 'app'\G

-- 库级权限（db.*）
SELECT * FROM mysql.db;

-- 表级权限（db.table）
SELECT * FROM mysql.tables_priv;

-- 列级权限（db.table.column）
SELECT * FROM mysql.columns_priv;

-- 存储过程/函数权限
SELECT * FROM mysql.procs_priv;
```

权限检查的粒度顺序是 **全局 → 库 → 表 → 列**，逐级向下检查，任何一级有权限即可通过（全局权限覆盖一切）。

## 二、账号与权限的正确操作姿势

### 建账号：三段式（CREATE → GRANT → FLUSH）

```sql
-- 1. 创建账号，指定来源网段 + 强密码
CREATE USER 'order_app'@'10.0.1.%'
  IDENTIFIED BY 'S7#kL9@mQ2!xP4z'          -- MySQL 8 默认 caching_sha2_password
  WITH MAX_USER_CONNECTIONS 200            -- 限制连接数，防止应用连接池失控打爆
       PASSWORD EXPIRE INTERVAL 90 DAY     -- 90 天强制改密
       FAILED_LOGIN_ATTEMPTS 5             -- 连续 5 次失败锁定
       PASSWORD_LOCK_TIME 1;               -- 锁定 1 天

-- 2. 只授必需的权限（业务账号通常只有 DML + 有限 DDL）
GRANT SELECT, INSERT, UPDATE, DELETE ON order_db.* TO 'order_app'@'10.0.1.%';

-- 3. 刷新权限（MySQL 8 中 GRANT 会自动刷，显式 FLUSH 兼容旧版本/习惯）
FLUSH PRIVILEGES;

-- 查看结果
SHOW GRANTS FOR 'order_app'@'10.0.1.%';
```

### 只读账号（报表/BI/数据同步）

```sql
CREATE USER 'bi_readonly'@'10.0.2.%' IDENTIFIED BY '...';
GRANT SELECT, SHOW VIEW ON report_db.* TO 'bi_readonly'@'10.0.2.%';

-- 加上资源限制，防止一个大查询把库拖垮
ALTER USER 'bi_readonly'@'10.0.2.%'
  WITH MAX_QUERIES_PER_HOUR 5000
       MAX_USER_CONNECTIONS 20;
```

### 列级权限（脱敏场景）

```sql
-- 只允许读手机号的掩码列，不允许读明文列
GRANT SELECT (id, name, phone_masked) ON user_db.user TO 'cs_agent'@'10.0.3.%';
```

**实战建议**：列级权限维护成本高，更适合用**视图**替代：

```sql
CREATE VIEW user_db.v_user_masked AS
SELECT id, name, CONCAT(LEFT(phone,3),'****',RIGHT(phone,4)) AS phone FROM user_db.user;

GRANT SELECT ON user_db.v_user_masked TO 'cs_agent'@'10.0.3.%';
```

### 角色（MySQL 8.0 引入）

角色是一组权限的命名集合，解决了"每次加人/改权限都要逐条 GRANT"的痛点：

```sql
-- 定义角色
CREATE ROLE 'role_app_rw', 'role_readonly', 'role_dba';

GRANT SELECT, INSERT, UPDATE, DELETE ON order_db.* TO 'role_app_rw';
GRANT SELECT ON *.* TO 'role_readonly';

-- 授权给用户（可以授多个角色）
GRANT 'role_app_rw' TO 'order_app'@'10.0.1.%';

-- 关键：设置默认启用角色（否则登录后角色不生效！）
ALTER USER 'order_app'@'10.0.1.%' DEFAULT ROLE 'role_app_rw';

-- 审查角色的权限
SHOW GRANTS FOR 'role_app_rw';
```

**大坑**：`GRANT role TO user` 之后如果不执行 `SET DEFAULT ROLE` 或 `SET ROLE`，用户登录后**什么权限都没有**（角色默认是禁用状态）。这是 MySQL 8 角色最常踩的坑。

## 三、最小权限原则：先列清单，再发权限

最小权限不是"少给点"，而是**基于操作清单精确授予**。给业务账号授权前，先回答这几个问题：

| 问题 | 影响 |
| --- | --- |
| 需要建表/改表吗？ | 决定是否给 `CREATE`/`ALTER`/`DROP`（生产通常由发布系统用独立账号执行 DDL） |
| 需要 `DROP` 吗？ | 业务账号一般**不需要**，`DELETE` 已足够 |
| 需要锁表/杀连接吗？ | `PROCESS`/`SUPER` 属于运维权限，绝不能给业务账号 |
| 需要读文件吗？ | `FILE` 权限配合 `SELECT ... INTO OUTFILE` / `LOAD_FILE` 可以直接读服务器文件，**最高危** |
| 需要建存储过程吗？ | `CREATE ROUTINE` 配合 `DEFINER` 提权是经典攻击面 |

**常见反模式清单**（自查一下你负责的系统踩了几个）：

- ❌ 业务账号用 `root`
- ❌ `GRANT ALL PRIVILEGES ON *.*`（等价于给 root）
- ❌ `host` 用 `%`
- ❌ 给业务账号 `FILE`、`SUPER`、`PROCESS`、`CREATE USER`
- ❌ 给业务账号 `GRANT OPTION`（能把权限转授他人，等于权限扩散）
- ❌ 开发/测试环境账号能连生产库
- ❌ 密码在代码/配置里明文且多年不轮转
- ❌ 存在匿名用户 `''@'localhost'`
- ❌ `mysql.user` 里有历史遗留的离职员工账号

## 四、账号安全加固

### 1. 密码策略组件

MySQL 8 提供 `validate_password` 组件：

```sql
INSTALL COMPONENT 'file://component_validate_password';

SET GLOBAL validate_password.policy = STRONG;      -- LOW/MEDIUM/STRONG
SET GLOBAL validate_password.length = 12;
SET GLOBAL validate_password.mixed_case_count = 1;
SET GLOBAL validate_password.number_count = 1;
SET GLOBAL validate_password.special_char_count = 1;

-- 验证策略是否生效
SELECT * FROM mysql.component WHERE component_urn LIKE '%validate_password%';
```

写入 `my.cnf` 让它持久化（避免重启失效）：

```ini
[mysqld]
validate_password.policy = STRONG
validate_password.length = 12
default_authentication_plugin = caching_sha2_password
```

### 2. 密码轮转与账号过期

```sql
-- 强制某账号立即改密
ALTER USER 'order_app'@'10.0.1.%' PASSWORD EXPIRE;

-- 定期检查即将过期的账号
SELECT user, host, password_last_changed,
       DATEDIFF(NOW(), password_last_changed) AS days_used
FROM mysql.user
WHERE password_last_changed IS NOT NULL
ORDER BY days_used DESC;
```

### 3. 认证插件选择

| 插件 | 特点 | 建议 |
| --- | --- | --- |
| `caching_sha2_password` | MySQL 8 默认，SHA-256 + 缓存，支持 SSL | ✅ 推荐 |
| `mysql_native_password` | 老插件，SHA-1，安全性低 | ⚠️ 兼容老客户端用，逐步淘汰 |
| `sha256_password` | 每次都走 SSL 或 RSA 交换，开销大 | 特殊场景 |
| `auth_socket` | 用操作系统用户认证 | 只用于本机运维账号 |

Java 侧要注意：**MySQL Connector/J 8.x 支持 `caching_sha2_password`**，但 5.x 驱动不支持，会报 `Unable to load authentication plugin 'caching_sha2_password'`。这是升级 MySQL 8 后应用连不上库的头号原因。

### 4. 强制 SSL 连接

```sql
-- 要求该账号必须用 TLS 连接
ALTER USER 'order_app'@'10.0.1.%' REQUIRE SSL;

-- 检查连接是否加密
SHOW STATUS LIKE 'Ssl_cipher';
SELECT * FROM performance_schema.session_status
WHERE VARIABLE_NAME IN ('Ssl_cipher','Ssl_version');
```

Java 侧 JDBC URL：

```
jdbc:mysql://10.0.1.20:3306/order_db
  ?useSSL=true&requireSSL=true&verifyServerCertificate=true
  &sslMode=VERIFY_CA&trustCertificateKeyStoreUrl=file:/opt/app/truststore.jks
  &trustCertificateKeyStorePassword=***
```

⚠️ 注意 `useSSL=false` 在 JDBC 中会把 `sslMode` 覆盖为 `DISABLED`，生产环境务必显式配置 `sslMode`。

## 五、审计：出了事得能查

### 1. 轻量方案：general_log（慎用）

```sql
SET GLOBAL general_log = 'ON';
SET GLOBAL general_log_file = '/var/log/mysql/general.log';
```

**代价极大**：记录所有语句，IO 和磁盘消耗高，生产上只能临时开启排障，绝不能长期跑。

### 2. binlog 审计（推荐）

用一个专用账号执行所有写操作，然后通过 binlog 回溯：

```bash
# 解析 binlog，按用户过滤
mysqlbinlog --base64-output=DECODE-ROWS -v \
  --start-datetime='2026-09-24 00:00:00' \
  mysql-bin.000123 | grep -A3 "order_app"
```

配合 `binlog_rows_query_log_events=ON`，可以在 ROW 格式下也记录原始 SQL 文本，审计更友好。

### 3. 审计插件（企业级）

- **MySQL Enterprise Audit**：官方插件，功能完整但需商业授权；
- **MariaDB Audit Plugin**：可以跑在 MySQL 上，记录连接、查询、表访问；
- **Percona Audit Log Plugin**：Percona Server 自带；
- **代理层审计**：通过 Database Proxy（如 ProxySQL、ShardingSphere-Proxy）统一记录，好处是**应用无感且不可绕过**。

无论哪种方案，审计日志要满足三点：**独立存储、只追加、有留存周期**。审计日志和数据库放同一台机器，等于给了攻击者"擦除证据"的机会。

### 4. 应用侧审计（Java）

数据库权限管不到的"业务级审计"要在应用层做。推荐用 Spring AOP + 异步落库：

```java
@Aspect
@Component
public class AuditAspect {
    private static final Logger log = LoggerFactory.getLogger(AuditAspect.class);

    @Around("@annotation(audited)")
    public Object around(ProceedingJoinPoint pjp, Audited audited) throws Throwable {
        String user = CurrentUserHolder.get();          // 从 ThreadLocal / SecurityContext 取
        long start = System.nanoTime();
        try {
            Object result = pjp.proceed();
            log.info("AUDIT op={} user={} method={} cost={}ms result=OK",
                    audited.value(), user, pjp.getSignature().toShortString(),
                    (System.nanoTime() - start) / 1_000_000);
            return result;
        } catch (Throwable e) {
            log.warn("AUDIT op={} user={} method={} result=FAIL msg={}",
                    audited.value(), user, pjp.getSignature().toShortString(), e.getMessage());
            throw e;
        }
    }
}
```

审计日志包含**谁（user）、何时（timestamp）、做了什么（op）、结果（成功/失败）**四要素，通过 MDC 串上 traceId，就能和链路追踪系统打通。

## 六、加固清单（Checklist）

| 类别 | 检查项 | 命令 / 位置 |
| --- | --- | --- |
| 账号 | 删除匿名用户 | `DROP USER ''@'localhost';` |
| 账号 | 删除 test 库和历史账号 | `DROP DATABASE test;` |
| 权限 | 业务账号无 `FILE`/`SUPER`/`PROCESS` | `SHOW GRANTS FOR ...` |
| 权限 | 无 `GRANT OPTION` | 检查 `mysql.user.Grant_priv` |
| 权限 | host 精确到网段，不用 `%` | `SELECT user,host FROM mysql.user;` |
| 密码 | 策略组件开启，长度 ≥ 12 | `validate_password.*` |
| 密码 | 90 天轮转 | `PASSWORD EXPIRE INTERVAL` |
| 网络 | `bind-address` 绑定内网 IP | `my.cnf [mysqld]` |
| 网络 | 3306 不对公网开放 | 安全组 / iptables |
| 连接 | 业务账号强制 SSL | `ALTER USER ... REQUIRE SSL` |
| 日志 | 审计日志独立存储 | 审计插件 / 代理层 |
| 备份 | 备份文件加密且权限最小 | `chmod 600` + GPG |
| 应用 | 代码无明文密码 | 配置中心 / Jasypt / KMS |
| 应用 | 全部使用 PreparedStatement | 代码审查 / Sonar |

一键自查 SQL：

```sql
-- 1. 列出所有账号及来源
SELECT user, host, plugin, password_last_changed,
       account_locked, password_expired
FROM mysql.user ORDER BY user;

-- 2. 找出权限过大的账号
SELECT user, host FROM mysql.user
WHERE Super_priv = 'Y' OR File_priv = 'Y' OR Grant_priv = 'Y';

-- 3. 找出 ALL 权限的库级授权
SELECT user, host, db FROM mysql.db
WHERE Select_priv='Y' AND Insert_priv='Y' AND Update_priv='Y'
  AND Delete_priv='Y' AND Drop_priv='Y' AND Grant_priv='Y';
```

## 七、面试常见追问

**Q1：GRANT 之后需要 FLUSH PRIVILEGES 吗？**

MySQL 中通过 `GRANT`/`CREATE USER`/`REVOKE` 语句修改权限时，服务端会自动重载权限表，**不需要** `FLUSH PRIVILEGES`。只有当你**直接修改了 `mysql.user` 等权限表**（比如 `UPDATE mysql.user SET ...`）或手动导入权限表时，才必须 `FLUSH PRIVILEGES` 让内存缓存重新加载。这条常识在面试里经常变成"陷阱题"。

**Q2：为什么 GRANT 后应用还是报没有权限？**

常见原因有三个：① 应用连接池里的**老连接**在建立时缓存了权限，需要重连才生效（`SHOW PROCESSLIST` 看连接时长）；② 账号 `host` 不匹配——你可能 GRANT 给了 `'app'@'192.168.1.%'`，但应用实际从 `10.0.x.x` 连过来，匹配到了另一个 `'app'@'%'` 账号；③ MySQL 8 的角色没设置 `DEFAULT ROLE`，登录后角色未启用。

**Q3：`SELECT ... INTO OUTFILE` 为什么危险？**

它需要 `FILE` 权限，能把查询结果写到**服务器文件系统**（不只是数据目录），攻击者可以配合 `LOAD_FILE()` 读敏感文件、写 WebShell 到站点目录。防御就是：业务账号**绝不授予 `FILE`**；`secure_file_priv` 设置为固定目录（或空值禁用导入导出）；`--secure-file-priv` 只允许特定路径。

**Q4：root 应该怎么用？**

- root 账号**只允许 `root@localhost`**（甚至用 `auth_socket` 插件绑定系统用户），禁止 `root@%`；
- 应用、监控、备份、DDL 发布各用独立账号；
- 日常运维用带 `SUPER`/`PROCESS` 的专用运维账号，root 只在紧急时使用；
- 开启 `PASSWORD EXPIRE` 和登录审计。

**Q5：数据库密码在 Java 应用里怎么管？**

分级方案：① 最基础——配置中心（Apollo/Nacos）+ 环境变量，避免明文进 Git；② 进阶——Jasypt 加密配置项，密钥由环境变量注入；③ 生产级——KMS/Vault 动态密钥，应用启动时拉取，支持自动轮转；④ 最高——数据库代理（ShardingSphere-Proxy/ProxySQL）做统一账号管理，应用只连代理，真实库密码不下发到应用节点。

## 八、总结

MySQL 安全加固的核心就三条主线：

```
1. 权限最小化
   root 只留 localhost；业务账号按操作清单精确 GRANT；
   host 精确到网段；禁用 FILE/SUPER/PROCESS/GRANT OPTION；
   MySQL 8 用角色管理权限集合（记得 SET DEFAULT ROLE！）

2. 认证强化
   caching_sha2_password + 强密码策略（validate_password）+ 定期轮转
   + 登录失败锁定 + MAX_USER_CONNECTIONS + 强制 SSL

3. 可审计、可追溯
   binlog / 审计插件 / 代理层审计（独立存储、只追加、留留存）
   + 应用层 AOP 业务审计（谁、何时、做什么、结果）
   + 密钥进配置中心/KMS，绝不明文入库入仓
```

最后一句经验：**数据库安全的成本主要在"设计阶段"，而不是"事故之后"。** 一个 `GRANT ALL ON *.*` 省下的五分钟，可能要用一次全量数据泄露来偿还。每次上线新服务时，把"账号开通"当成一个正经的评审项——权限清单写清楚、来源网段写清楚、轮转机制写清楚，这三样做扎实，你就能挡住 90% 的数据库安全事故。

顺便，把这篇文章里的自查 SQL 存下来，下个季度做安全审计时直接跑一遍，你会发现至少有十几项可以立刻修掉。
