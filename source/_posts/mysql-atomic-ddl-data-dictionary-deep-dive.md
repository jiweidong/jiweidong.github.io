---
title: 【MySQL 8 底层】原子 DDL 与数据字典深度解析：从 .frm 分裂到 SDI 统一
date: 2026-11-03 08:05:00
tags:
  - MySQL
  - InnoDB
  - 原子 DDL
  - 数据字典
  - 数据库
categories:
  - MySQL
author: 东哥
---

# 【MySQL 8 底层】原子 DDL 与数据字典深度解析

## 前言

很早以前我遇到过一个线上事故：MySQL 5.7 主库执行 `ALTER TABLE` 时机器掉电，重启后表打不开了，报 `Table 'xxx' doesn't exist in engine`。数据文件还在，`.frm` 也在，但就是打不开。

根因就是 **MySQL 8.0 之前元数据是「双写」的**：

- Server 层把表结构写进 `.frm` 文件（还有 `.TRG`、`.par`、`.opt` 等）
- InnoDB 层把表定义写进自己的数据字典（`SYS_TABLES`、`SYS_COLUMNS` 等隐藏表）

两份元数据不在一个事务里。DDL 执行到一半崩溃，两份就对不上，表就废了。

MySQL 8.0 做的事叫**原子 DDL（Atomic DDL）**，前提是把数据字典统一到 InnoDB 里（**Transactional Data Dictionary**）。这篇文章把这条链路拆开讲：元数据存哪、DDL 怎么保证原子、崩溃怎么恢复、以及作为 Java 后端你该怎么配合。

---

## 一、MySQL 5.7 的元数据为什么一定会出问题

### 1.1 双写结构

| 元数据 | 5.7 存储位置 | 事务性 |
|---|---|---|
| 表结构（列、索引定义） | `.frm` 文件（Server 层） | ❌ 文件系统操作 |
| 触发器 | `.TRG` 文件 | ❌ |
| 分区信息 | `.par` 文件 | ❌ |
| 表选项 | `.opt` 文件 | ❌ |
| InnoDB 表空间/索引根页 | InnoDB 内部 `SYS_*` 表 | ✅ |
| 统计信息 | `mysql.innodb_table_stats` | ✅ |

关键矛盾：**`.frm` 的写入是文件系统操作，没有事务、没有 redo、没有原子 rename 保证**（虽然用了临时文件 + rename 的近似原子，但多文件之间无法原子）。

### 1.2 崩溃场景推演

`ALTER TABLE t ADD COLUMN c INT` 在 5.7 的实际步骤：

1. 建临时表 `#sql-xxx`，复制数据（COPY 算法）
2. rename 原表 → 备份名，临时表 → 原名（两次 rename）
3. 更新 `.frm`
4. 更新 InnoDB 字典
5. 删备份表

任何一步崩溃，都可能出现「`.frm` 说有 c 列，InnoDB 字典说没有」或「表文件在，字典里没注册」。前者报 `Unknown column`，后者报 `doesn't exist in engine`。

---

## 二、MySQL 8.0 的数据字典

### 2.1 全部塞进 InnoDB

8.0 起：

- **所有元数据都是 InnoDB 表**，物理上位于 `mysql.ibd`
- 逻辑上是一堆 `dd::` 开头的系统表（`dd::tables`、`dd::columns`、`dd::indexes`、`dd::tablespaces`、`dd::schemata`…）
- `.frm`、`.TRG`、`.par`、`.opt` 全部**移除**
- 数据字典的读写走正常的 InnoDB 事务，有 redo、有 undo、有 MVCC

这就把「元数据变更」从「文件系统操作」变成了「事务操作」——原子性的地基就有了。

### 2.2 SDI：还能从 .ibd 里读出表结构

有个很实用的问题：既然 `.frm` 没了，那我拿到一个 `.ibd` 文件，怎么知道表结构？

答案是 **SDI（Serialized Dictionary Information）**：每个 `.ibd` 文件里都内嵌了一份 JSON 格式的表定义。可以这样读：

```bash
# 从 ibd 文件里 dump 出 JSON 格式的表定义
ibd2sdi /var/lib/mysql/test/t.ibd

# 输出节选
{
  "object":
  {
    "mysqld_version_id": 80040,
    "dd_version": 80023,
    "sdi_version": 80019,
    "object_typename": "table",
    "object": {
      "name": "t",
      "columns": [
        {"name": "id", "type": 4, "is_nullable": false, ...},
        {"name": "c",  "type": 4, "is_nullable": true,  ...}
      ],
      ...
    }
  }
}
```

这个能力在数据恢复场景非常关键：**没有 `.frm`、没有备份、只有 `.ibd` 时，靠 SDI 就能重建 `CREATE TABLE`**。

也可以在库里查：

```sql
-- 需要 DEBUG 权限或者用 ibd2sdi
SELECT * FROM information_schema.innodb_tablespaces;
```

### 2.3 字典表的组织

几个要点（面试常问）：

| 概念 | 说明 |
|---|---|
| `mysql.ibd` | 数据字典表空间，8.0 起必须存在 |
| 隐藏库 `mysql` | 存放 `dd::` 表，`SHOW TABLES` 看不到 |
| 表 ID | 全局递增，跨 DB 唯一，由字典统一分配 |
| 表空间 ID | 同上，8.0 起由字典统一管理，不再依赖 `innodb_tablespace_map` |
| 缓存层 | `dd::cache`（`Dictionary_client`），减少字典表访问 |

---

## 三、原子 DDL 到底保证了什么

### 3.1 语义定义

一个 DDL 语句（以及它隐含的多步操作）满足：

1. **数据字典更新**
2. **存储引擎操作**（建/删表空间、改索引）
3. **写 binlog**
4. **提交（或回滚）**

这四件事构成一个**原子单元**：要么全成功，要么全不生效。

具体到 `ALTER TABLE`：数据字典变更、存储引擎变更、binlog 事件，要么一起提交，要么一起回滚。不会出现「字典改了、引擎没改」的中间态。

### 3.2 实现：DDL Log

难点在于：**InnoDB 的数据变更可以靠 undo 回滚，但「建了表空间文件」「删了表空间文件」这类操作无法回滚。**

所以 8.0 引入 **InnoDB DDL Log**（内部叫 `ddl_log`，位于 `mysql.ibd` 的隐藏表），记录「已完成的物理动作」：

- 提交前崩溃 → 重放 DDL Log，把已做的物理动作**前滚**（redo/undo 覆盖不到的部分）
- 提交后崩溃 → 正常 redo 恢复

恢复阶段的判定逻辑大致是：

```
1. 扫描 DDL Log
2. 对每条记录判定：对应事务是否已提交？
   ├─ 已提交 → 前滚未完成的物理操作
   └─ 未提交 → 回滚/清理临时产物
3. 校验字典一致性，发现孤儿表空间则告警/删除
```

### 3.3 支持原子 DDL 的语句

| 语句 | 原子 DDL |
|---|---|
| `CREATE TABLE` / `DROP TABLE` | ✅ |
| `ALTER TABLE` | ✅（部分引擎操作除外） |
| `CREATE/DROP INDEX` | ✅ |
| `RENAME TABLE`（多表） | ✅ |
| `TRUNCATE TABLE` | ✅ |
| `CREATE/DROP VIEW` | ✅ |
| `CREATE/DROP TABLESPACE` | ✅（通用表空间） |
| `CREATE/DROP USER`、`GRANT` | ✅（走 ACL 表，事务性） |
| `CREATE/DROP DATABASE` | ✅ |
| **`ALTER TABLE ... PARTITION` 的部分组合** | ⚠️ 有限制 |

⚠️ 注意：原子 DDL 保证的是**元数据一致性**，不保证「DDL 不锁表」「DDL 秒级完成」。这是两码事，很多人混为一谈。

---

## 四、DDL 算法：INSTANT / INPLACE / COPY

原子 DDL 解决「崩了会不会坏」，算法解决「执行时锁不锁表、要不要重建」。这两条线要分开理解。

| 算法 | 是否重建表 | 是否允许并发 DML | 元数据锁 | 典型耗时 |
|---|---|---|---|---|
| `INSTANT` | ❌ 只改字典 | ✅ | 极短 | 毫秒级 |
| `INPLACE`（rebuild=OFF） | ❌ | ✅ | 短 | 秒级 |
| `INPLACE`（rebuild=ON） | ✅ | ✅（并发 DML） | 中 | 与数据量线性 |
| `COPY` | ✅ | ❌ | **全程阻塞写** | 最慢 |

MySQL 8.0 的 `INSTANT` 逐步扩展：

| 版本 | INSTANT 能力 |
|---|---|
| 8.0.12 | 新增列到**末尾**、改默认值 |
| 8.0.29 | **任意位置**加列、删列（需要 rebuild 的例外） |
| 8.0.32+ | 更多类型变更 |

8.0.29 的「任意位置加列」用的是 **row version + 行内默认值** 机制：新行按新格式写，旧行按需转换。所以会有：

```sql
-- 查看表的行格式版本
SELECT NAME, TOTAL_ROW_VERSIONS FROM information_schema.INNODB_TABLES
WHERE NAME = 'test/t';

-- 行版本数有上限（默认 64），超了就得 rebuild
```

⚠️ **`TOTAL_ROW_VERSIONS` 超过 64 会导致后续 INSTANT 加列失败，退化为 rebuild。** 这是线上高频加列场景的隐藏炸弹。

### 4.1 指定算法与锁

```sql
-- 强制 instant，不满足就报错（推荐：早失败早发现）
ALTER TABLE t ADD COLUMN c INT, ALGORITHM=INSTANT;

-- 允许并发读写（INPLACE），不阻塞 DML
ALTER TABLE t ADD COLUMN d INT, ALGORITHM=INPLACE, LOCK=NONE;

-- 查看 DDL 进度（8.0）
SELECT * FROM performance_schema.events_stages_current
WHERE EVENT_NAME LIKE '%alter%';
```

生产建议：**永远显式写 `ALGORITHM` 和 `LOCK`**。一是防止优化器「贴心地」降级到 COPY，二是让变更评审时能一眼看出影响面。

---

## 五、真正的生产痛点：不是原子性，是 MDL

原子 DDL 让「崩溃坏表」几乎绝迹，但线上 DDL 事故 90% 是另一类：**MDL（Metadata Lock）等待把整张表锁死**。

### 5.1 事故链

```
长事务（一个跑了 30 分钟的 SELECT）持有 MDL 读锁
        ↓
ALTER TABLE 申请 MDL 写锁，进入等待队列
        ↓
后续所有 SELECT/UPDATE 因为「队列公平」排在 ALTER 后面
        ↓
表彻底不可用，连接池打满，服务雪崩
```

关键点：**MDL 的等待队列是「插队禁止」的**。一个 DDL 在等，后面所有请求都得等它。

### 5.2 排查

```sql
-- 8.0：直接看元数据锁等待
SELECT * FROM performance_schema.metadata_locks
WHERE OBJECT_SCHEMA = 'biz' AND OBJECT_NAME = 'orders';

-- 看谁在阻塞（含等待时长）
SELECT
  p.id, p.user, p.time, p.state,
  LEFT(p.info, 80) AS sql_text,
  l.OBJECT_TYPE, l.LOCK_TYPE, l.LOCK_STATUS
FROM performance_schema.metadata_locks l
JOIN performance_schema.threads t ON l.OWNER_THREAD_ID = t.THREAD_ID
JOIN information_schema.processlist p ON t.PROCESSLIST_ID = p.id
WHERE l.OBJECT_SCHEMA = 'biz';
```

### 5.3 防御

| 措施 | 说明 |
|---|---|
| `lock_wait_timeout` 调小 | DDL 等待超时早失败（会话级 `SET SESSION lock_wait_timeout = 5`） |
| DDL 前杀长事务 | 先 `information_schema.innodb_trx` 找长事务 |
| 业务低峰执行 | 但别指望——低峰也有定时任务 |
| 拆分大表 DDL | 用 gh-ost / pt-osc（见下文） |
| 应用侧加 DDL 开关 | 灰度期间对相关表做降级读 |

### 5.4 什么时候还需要 gh-ost / pt-osc

原子 DDL 不等于在线 DDL。下面这些场景，官方工具仍然不够：

1. **需要保留原表**（`--preserve-triggers`、可回滚）
2. **需要限流**（控制主从延迟）
3. **需要分片切换**（业务双写期间）
4. **超大表**（几亿行，INPLACE 的 rebuild 期间 IO 打满）

```bash
# gh-ost 典型用法：限流 + 主从延迟保护
gh-ost \
  --host=127.0.0.1 --database=biz --table=orders \
  --alter="ADD COLUMN remark VARCHAR(64) DEFAULT NULL" \
  --max-load='Threads_running=30' \
  --critical-load='Threads_running=100' \
  --max-lag-millis=1500 \
  --chunk-size=1000 \
  --allow-on-master \
  --execute
```

---

## 六、Java 侧怎么配合

### 6.1 Flyway / Liquibase 的定位

工具只负责「按版本顺序执行 SQL」，**不负责在线变更安全**。所以：

- ✅ 用 Flyway 管理 schema 版本
- ❌ 别指望它帮你处理 MDL、限流、回滚

```java
// Spring Boot + Flyway 的最小配置
@Configuration
public class FlywayConfig {
    @Bean
    public Flyway flyway(DataSource ds) {
        return Flyway.configure()
            .dataSource(ds)
            .locations("classpath:db/migration")
            .baselineOnMigrate(true)
            // DDL 也可能被 MDL 卡住，别用无限等待
            .initSql("SET SESSION lock_wait_timeout = 10")
            .validateOnMigrate(true)
            .load();
    }
}
```

### 6.2 变更安全的三条硬规则

1. **DDL 与应用发布解耦**：先加列（可空/带默认），再发代码，最后清老列。**永远不要在同一次发布里删列**。
2. **给 DDL 单独的连接和超时**：别用业务连接池执行 DDL，避免拖垮池子。
3. **DDL 必须可重入**：`CREATE TABLE IF NOT EXISTS`、先查 `information_schema` 再决定。

```java
// 加列前先探测，避免灰度环境重复执行报错
public boolean columnExists(DataSource ds, String table, String column) throws SQLException {
    try (Connection c = ds.getConnection();
         PreparedStatement ps = c.prepareStatement(
             "SELECT 1 FROM information_schema.columns " +
             "WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?")) {
        ps.setString(1, table);
        ps.setString(2, column);
        try (ResultSet rs = ps.executeQuery()) {
            return rs.next();
        }
    }
}
```

### 6.3 崩溃恢复后的自检

应用启动时可以校验关键表结构，避免「字典和代码不一致」直接报 `Unknown column`：

```java
@Component
public class SchemaGuard implements ApplicationRunner {
    private final JdbcTemplate jdbc;
    public SchemaGuard(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    @Override
    public void run(ApplicationArguments args) {
        Integer n = jdbc.queryForObject(
            "SELECT COUNT(*) FROM information_schema.columns " +
            "WHERE table_schema = DATABASE() AND table_name = 'orders' " +
            "AND column_name IN ('remark','channel')", Integer.class);
        if (n == null || n < 2) {
            throw new IllegalStateException("orders 表结构不完整，疑似 DDL 未生效，拒绝启动");
        }
    }
}
```

---

## 七、升级与迁移的坑

### 7.1 5.7 → 8.0 的字典升级

升级时 mysqld 会把 `.frm` 里的定义读出来，写入新的 InnoDB 字典。这一步是**单向、不可逆**的（降级只能靠备份）。

注意事项：

- 升级前必须 `mysqlcheck -u root -p --all-databases` 检查一致性
- 存在**孤儿 `.frm`**（找不到对应表空间）会导致升级失败，要先清理
- 升级后 `mysql.ibd` 会显著变大（字典表都在这）
- 备份工具要升级（Percona XtraBackup 8.0 版本对应）

### 7.2 表空间导入导出

```sql
-- 8.0 支持「导出表空间 + 导出 SDI」，无需 .cfg
FLUSH TABLES t FOR EXPORT;
-- 拷贝 t.ibd 和 t.sdi
UNLOCK TABLES;

-- 目标库
ALTER TABLE t DISCARD TABLESPACE;
-- 拷入 t.ibd
ALTER TABLE t IMPORT TABLESPACE;
```

关键变化：8.0 不再需要 `.cfg` 文件，SDI 已经内嵌在 `.ibd` 里。

---

## 八、面试追问

**Q1：MySQL 8.0 的原子 DDL 是怎么实现的？**
依赖两个前提：(1) 数据字典统一到 InnoDB（`dd::` 表），元数据变更本身是事务；(2) InnoDB DDL Log 记录无法用 redo/undo 覆盖的物理动作（建/删表空间文件），崩溃恢复时据此前滚或清理。三者（字典、引擎、binlog）作为一个原子单元提交。

**Q2：原子 DDL 是不是就不用担心 DDL 锁表了？**
完全不是。原子 DDL 解决的是**崩溃一致性**；锁表问题来自 MDL 和算法选择（COPY 全程阻塞写）。两件事互相独立。

**Q3：`ALGORITHM=INSTANT` 加列为什么能毫秒完成？**
只改数据字典，不动数据文件。已有行不立即改写，而是记录「行版本」，读取时按版本做默认值补全（row version + instant default）。代价是行版本数有上限（默认 64），超了就要 rebuild。

**Q4：为什么 DDL 会阻塞后面的 SELECT？**
因为 MDL 有等待队列且不允许插队。DDL 申请写锁在排队时，后续读请求的读锁也要排队，形成「表级雪崩」。这是设计上的公平性代价。

**Q5：`ibd2sdi` 有什么用？**
从 `.ibd` 文件里解析出内嵌的 SDI JSON，拿到完整表定义。用于没有 `.frm`、没有备份的灾难恢复场景，也用于审计/校验表结构。

**Q6：8.0 删了 `.frm`，那 `SHOW CREATE TABLE` 从哪读？**
从数据字典（`dd::tables` / `dd::columns`）拼装，走 `Dictionary_client` 缓存。物理上在 `mysql.ibd`。

---

## 九、总结

把这条链路收束成一张图：

```
SQL 层 DDL
   ↓ 解析、权限、打开表（MDL 写锁）
数据字典事务（dd::tables / dd::columns）
   ↓
存储引擎操作（建表空间/改索引，写 InnoDB DDL Log）
   ↓
写 binlog
   ↓
提交 → 释放 MDL
   ↓
崩溃恢复：redo/undo + DDL Log 前滚 → 字典一致性校验
```

三句话记住：

1. **8.0 之前的问题不是「慢」，是「元数据双写且无事务」**
2. **原子 DDL 保证一致性，不保证可用性**——MDL 才是线上事故主力
3. **INSTANT 有行版本上限**，高频加列的表要盯 `TOTAL_ROW_VERSIONS`

DB 变更这件事，最贵的从来不是执行时间，而是「不可回滚的中间态」。原子 DDL 把 MySQL 从「靠人肉小心」推进到「靠机制保证」，这才是 8.0 最被低估的升级理由。
