---
title: 【MySQL 实战】可传输表空间深度实战：大表跨实例迁移、.ibd/.cfg 与一致性校验
date: 2026-11-27 08:05:00
tags:
  - MySQL
  - InnoDB
  - 数据迁移
  - 生产实战
categories:
  - 数据库
author: 东哥
---

# 【MySQL 实战】可传输表空间深度实战：大表跨实例迁移、.ibd/.cfg 与一致性校验

## 前言

一张 480GB 的订单明细表要从老集群搬到新集群。

先算一下常规方案的时间账：

- `mysqldump`：单线程导出约 40MB/s，480GB 需要 3.3 小时，导入再 5 小时以上，还得考虑 binlog 追平；
- XtraBackup 全量：快，但整个实例 3TB，为了搬一张表要复制 3TB，网络和存储都不划算；
- 逻辑复制（CDC 双写）：最平滑，但要改应用、要处理 DDL、要保证顺序，工期两周。

这时候正确工具是 **InnoDB 可传输表空间（Transportable Tablespace）**：直接把 `.ibd` 文件拷过去，`IMPORT TABLESPACE` 挂载，480GB 在千兆网络下约 1.5 小时，停机窗口只需要最后切换的几秒。

但它有一堆"看起来能用、实际上会炸"的边界：版本、页大小、加密、全文索引、外键、统计信息、space id。这篇文章把原理、完整流程、校验与踩坑全部讲透。

---

## 一、为什么 `.ibd` 不能直接 `cp`

很多人第一反应：既然 `innodb_file_per_table=ON`，一张表就是一个 `.ibd`，那我直接拷贝文件再重启不就行了？

不行。原因是 InnoDB 的表空间文件里**没有完整的"我是谁"信息**，数据页只记录 `SPACE ID`（4 字节），页内不存表名。实例启动时，InnoDB 通过数据字典（MySQL 8.0 之后是 `mysql.ibd` 里的 SDI）把 `space id → 表名 → 文件路径` 关联起来。

直接拷贝会导致两个问题：

1. **space id 冲突**：源实例的 `space id=137` 和目标实例已有的 `137` 撞车，InnoDB 会拒绝启动或报错；
2. **元数据缺失**：目标实例的数据字典里没有这张表的定义，文件成了"孤儿"。

所以官方流程的核心是：**先在目标端建好表（占位 + 生成字典项），`DISCARD` 掉它的表空间（保留字典项、删掉文件），再把源端的 `.ibd` 放到目标路径，最后 `IMPORT` 让 InnoDB 校验并接管。**

中间那个 `.cfg` 文件（MySQL 5.7 起）携带了表结构校验信息（列类型、列顺序、索引定义），导入时用来做一致性比对，防止"文件是 A 表、字典是 B 表"这种灾难。

---

## 二、完整流程（同版本、非加密、file-per-table）

### 2.1 目标端：建表并 DISCARD

```sql
-- 1) 表结构必须与源端完全一致（建议直接 SHOW CREATE TABLE 复制）
CREATE TABLE `order_detail` (
  `id` bigint unsigned NOT NULL,
  `order_no` varchar(64) NOT NULL,
  `sku_id` bigint unsigned NOT NULL,
  `qty` int NOT NULL,
  `amount` decimal(18,2) NOT NULL,
  `created_at` datetime(3) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_order_no` (`order_no`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 2) 丢弃空表空间（会删除目标端的 .ibd，保留字典项）
ALTER TABLE order_detail DISCARD TABLESPACE;
```

`DISCARD` 之后目标端的 `.ibd` 不存在了，此时**不要**对该表做任何 DML，否则会报 `Tablespace is missing`。

### 2.2 源端：加锁导出

```sql
-- 会话 A：持有导出锁，期间该表只读
FLUSH TABLES order_detail FOR EXPORT;
```

这条命令做了三件事：

1. 等待该表上的所有事务结束，加表级共享锁（阻塞写，允许读）；
2. 把该表的脏页全部刷盘；
3. 在数据目录生成 `order_detail.cfg`（表结构元数据）。

**注意：`FOR EXPORT` 期间该表不可写**，这是整个方案唯一的"业务可见"影响。对大表来说，刷脏页可能需要几十秒到几分钟，务必在低峰期做，并提前用 `SHOW ENGINE INNODB STATUS` 看 `Pending writes` 估算。

```bash
# 会话 A 保持不关闭！锁释放 = UNLOCK TABLES 或会话断开
# 会话 B：拷贝文件（此时文件是静态的）
cp /var/lib/mysql/orderdb/order_detail.ibd /transfer/
cp /var/lib/mysql/orderdb/order_detail.cfg /transfer/
```

### 2.3 目标端：导入

```bash
# 文件属主必须是 mysql:mysql，权限 640，否则导入报权限错误
chown mysql:mysql /var/lib/mysql/orderdb/order_detail.{ibd,cfg}
```

```sql
ALTER TABLE order_detail IMPORT TABLESPACE;
```

导入时 InnoDB 会：

1. 读取 `.cfg`，与数据字典中的表定义逐列比对（列名、类型、顺序、索引）；
2. 检查 `.ibd` 头部页的 `space id`、页大小、server 版本标记；
3. 把文件"注册"进当前实例，更新数据字典；
4. 打开表，此时可以正常读写。

### 2.4 校验（别跳过这一步）

```sql
-- 行数（大表用近似值先看量级）
SELECT table_rows FROM information_schema.tables
WHERE table_schema='orderdb' AND table_name='order_detail';

-- 精确行数（会走索引/全表，大表慎用）
SELECT COUNT(*) FROM order_detail;

-- 统计信息必须重建，否则执行计划可能劣化
ANALYZE TABLE order_detail;

-- 表空间归属确认
SELECT name, space_type, row_format, space
FROM information_schema.innodb_tablespaces
WHERE name LIKE '%order_detail%';
```

**强烈建议做业务级校验**：抽样 1000 行按主键比对关键字段，或者按时间分区做分段 `CHECKSUM TABLE`（`CHECKSUM TABLE` 对 InnoDB 是实时计算，480GB 可能跑很久，务必分片）。

---

## 三、五个必须提前确认的兼容性条件

这张表如果有一条不满足，流程就会在 `IMPORT` 阶段失败（而且报错信息往往很含糊）。

| 条件 | 检查方式 | 不满足的后果 |
|---|---|---|
| **页大小一致** | `SHOW VARIABLES LIKE 'innodb_page_size'` | 报错，无法导入（页大小是物理格式） |
| **版本兼容** | 源 ≤ 目标，且不跨大版本降级 | 8.0 → 5.7 一定失败；5.7 → 8.0 需先升级格式 |
| **行格式** | `SHOW TABLE STATUS` 看 `Row_format` | `COMPACT`/`DYNAMIC` 混用可能报 schema mismatch |
| **加密状态** | `SHOW CREATE TABLE` 看 `ENCRYPTION` | 加密表空间需要目标端持有**同一把 master key** |
| **无 DATA DIRECTORY** | `SHOW CREATE TABLE` | 使用独立目录的表空间不支持 export |

### 3.1 加密表空间是最常见的坑

如果源表是 `ENCRYPTION='Y'`，`.ibd` 是用表空间密钥加密的，而表空间密钥又被 master key 加密后存在源实例的 keyring 里。**只拷 `.ibd` 过去，目标端没有对应的 master key，文件就是一堆随机字节。**

三个可行方案：

1. **迁移 keyring**（最彻底）：把源实例 keyring 里的 master key 导入目标 keyring，需要 keyring 组件支持导出；
2. **先解密再迁移**（最简单）：
   ```sql
   ALTER TABLE order_detail ENCRYPTION='N';  -- 会重建表，480GB 需要很久
   ```
3. **用逻辑复制**：加密是物理层特性，逻辑导出天然没有这个问题。

如果选择方案 2，记得评估重建期间的磁盘空间（需要额外一份表大小的空间）和 IO 影响。

### 3.2 全文索引不跟着走

InnoDB 的全文索引有一批辅助表（`FTS_DOC_ID_INDEX`、`FTS_*_INDEX_1~6` 等），它们**不在同一个 `.ibd` 里**，`IMPORT TABLESPACE` 不会带过来。导入后表能读，但全文检索会失效或直接报错。

正确做法：导入完成后重建全文索引。

```sql
ALTER TABLE article DROP INDEX ft_content;
ALTER TABLE article ADD FULLTEXT INDEX ft_content (title, content) WITH PARSER ngram;
```

### 3.3 外键与触发器

- **外键**：InnoDB 在导入时会检查外键引用的表是否存在。建议导入前 `SET foreign_key_checks=0`，导入后再打开并校验数据完整性（`pt-online-schema-change` / `gh-ost` 也是同样处理）。
- **触发器**：触发器属于数据字典，不在 `.ibd` 里，需要在目标端单独创建。这是最容易被遗漏的一项——迁移完发现"审计日志不写了"，查半天才发现触发器没建。

### 3.4 分区表

分区表的每个分区是独立的表空间文件（`order_detail#p#p202601.ibd`），导出时需要逐个处理，或者直接对整个表做 `FLUSH TABLES ... FOR EXPORT`（会生成每个分区的 `.cfg`）。导入时用 `ALTER TABLE ... IMPORT PARTITION p202601 TABLESPACE` 逐个导入，**不能一条命令导入整个分区表**。

```sql
ALTER TABLE order_detail IMPORT PARTITION p202601 TABLESPACE;
ALTER TABLE order_detail IMPORT PARTITION p202602 TABLESPACE;
```

---

## 四、在线迁移：把停机窗口压到秒级

`FOR EXPORT` 期间表只读，480GB 刷脏 + 拷贝 1.5 小时，业务不可接受。所以真实的大表迁移都是**"全量 + 增量追平"**：

```
T0: 记录源端 binlog 位点（GTID 或 file+pos）
T1: FLUSH TABLES ... FOR EXPORT，拷贝 .ibd/.cfg，UNLOCK（源端恢复读写）
T2: 目标端 IMPORT，ANALYZE
T3: 用 CDC（Canal/Debezium）从 T0 位点开始回放增量到目标端
T4: 业务低峰，短暂停写（秒级）→ 追平最后一点增量 → 校验 → 切流量
```

关键点：

- **T1 的锁只持续到文件拷贝完成**。如果拷贝 1.5 小时，锁就持 1.5 小时，所以更常见的做法是"打快照 + 从快照拷贝"（云盘快照/LVM），把锁时间压到秒级；
- **T3 的增量必须幂等**：CDC 回放用 `INSERT ... ON DUPLICATE KEY UPDATE` 或按主键 `REPLACE`，避免重复应用；
- **T4 的停写窗口**要提前演练，包含"追平 → 校验 → DNS/配置切换 → 回滚预案"。

### 4.1 用快照规避长锁

```bash
# LVM 场景：先加锁，创建快照，立刻解锁，再从快照挂载拷贝
mysql -e "FLUSH TABLES order_detail FOR EXPORT;" &
# 等 .cfg 出现
lvm lvcreate -L 600G -s -n order_snap /dev/vg0/mysql
mysql -e "UNLOCK TABLES;"
# 从快照挂载后慢慢拷，不影响线上
```

这样源表的只读窗口从 1.5 小时降到几十秒。

---

## 五、Java 侧编排与校验代码

把整个流程做成可重跑的运维工具，比手工敲 SQL 可靠得多。

```java
@Component
public class TablespaceMigrator {

    private final JdbcTemplate source;
    private final JdbcTemplate target;

    /** 目标端：建表 + DISCARD，幂等 */
    public void prepare(String ddl) {
        target.execute("SET foreign_key_checks = 0");
        target.execute(ddl); // CREATE TABLE IF NOT EXISTS 语义需自行保证
        target.execute("ALTER TABLE order_detail DISCARD TABLESPACE");
    }

    /** 源端：导出（返回后必须尽快 UNLOCK） */
    public void exportOnSource() {
        source.execute("FLUSH TABLES order_detail FOR EXPORT");
        // 注意：此方法返回后连接仍在池里，锁不会自动释放！
        // 生产中应使用独立连接并在 finally 中 UNLOCK TABLES
    }

    /** 目标端：导入 + 重建统计信息 + 校验 */
    public ImportResult importAndVerify() {
        target.execute("ALTER TABLE order_detail IMPORT TABLESPACE");
        target.execute("ANALYZE TABLE order_detail");

        Long rows = target.queryForObject(
            "SELECT COUNT(*) FROM order_detail", Long.class);

        // 抽样校验：按主键区间各取 1000 行做字段级对比
        List<Map<String, Object>> sample = target.queryForList(
            "SELECT * FROM order_detail ORDER BY id LIMIT 1000");
        boolean sampleOk = sample.stream().allMatch(this::rowMatchesSource);

        return new ImportResult(rows, sampleOk);
    }

    private boolean rowMatchesSource(Map<String, Object> row) {
        Map<String, Object> src = source.queryForMap(
            "SELECT * FROM order_detail WHERE id = ?", row.get("id"));
        return src.equals(row);
    }
}
```

三个工程细节：

1. **`FLUSH TABLES ... FOR EXPORT` 的锁绑定在连接上**。如果用连接池，方法返回后连接归还，锁的归属就变得不可控。务必用 `DataSource.getConnection()` 拿独立连接，`finally` 里 `UNLOCK TABLES` 并关闭。
2. **`IMPORT` 期间目标表不可访问**，要在发布系统里做成"维护模式"的一部分，避免健康检查打到该表。
3. **`COUNT(*)` 在大表上是全索引扫描**，480GB 可能要十几分钟。用 `information_schema.tables.table_rows` 做量级校验，精确校验放到业务低峰。

---

## 六、六个真实踩坑

| 报错 / 现象 | 根因 | 处理 |
|---|---|---|
| `ERROR 1808 (HY000): Schema mismatch` | `.cfg` 与字典定义不一致（列顺序、字符集、行格式） | 用源端 `SHOW CREATE TABLE` 原样建表，别手写 |
| `ERROR 1812: Tablespace is missing` | 忘了 `DISCARD`，或文件路径/权限不对 | 确认 `innodb_file_per_table=ON`、属主 `mysql:mysql` |
| `ERROR 1813: Tablespace exists` | 目标端 `.ibd` 还在 | 必须先 `DISCARD` 再放文件 |
| 导入成功但全文检索报错 | FTS 辅助表没跟过来 | 重建 FULLTEXT 索引 |
| 导入后查询突然走全表扫描 | 统计信息为空/过期 | `ANALYZE TABLE`，确认 `innodb_stats_persistent=ON` |
| 导入后写入报 `Duplicate entry` | 增量回放重复应用 | CDC 侧做幂等（主键 upsert） |

还有一个隐蔽的坑：**`lower_case_table_names` 不一致**。Linux 默认 0（大小写敏感），如果源端是 0、目标端是 1，表名大小写会在字典里被归一化，`.cfg` 校验可能通过但后续访问路径对不上。跨平台迁移（Linux → Windows 容器）时尤其要注意，这个参数**只能在初始化时设置**，事后改需要重建实例。

---

## 七、方案对比：什么时候该用它

| 方案 | 停机时间 | 适合数据量 | 跨版本 | 复杂度 | 主要限制 |
|---|---|---|---|---|---|
| `mysqldump` / `mydumper` | 小时级 | < 100GB | 支持 | 低 | 慢、锁表/一致性快照 |
| XtraBackup 全量 | 小时级 | 整实例 | 部分支持 | 中 | 搬整实例，不能单表 |
| **可传输表空间** | **秒级（配合快照）** | **100GB~TB** | **仅向上兼容** | 中 | 页大小/加密/版本限制 |
| CDC 双写 | 分钟级 | 任意 | 支持 | 高 | 要处理 DDL、顺序、幂等 |
| 云 DMS | 分钟级 | 任意 | 支持 | 低（付费） | 成本、厂商绑定 |

**决策建议**：

- 单表 100GB 以上、同大版本、非加密 → 可传输表空间是性价比最高的；
- 需要跨大版本升级 → 老老实实逻辑复制或原地升级；
- 表有复杂外键/触发器/全文索引 → 先评估重建成本，必要时退回逻辑方案；
- 业务完全不能停 → CDC 双写是唯一解，可传输表空间只用来"打底"（先搬历史，再追增量）。

---

## 八、面试高频追问

**Q1：可传输表空间为什么需要 `.cfg`？**
`.ibd` 里只有 space id 和数据页，没有表结构。`.cfg` 由 `FLUSH TABLES ... FOR EXPORT` 生成，记录了列定义、索引、行格式等元数据，导入时用于与目标端数据字典比对，防止表结构不匹配导致数据错乱。

**Q2：为什么必须先 `DISCARD`？**
`IMPORT` 的语义是"用一个外部文件替换现有表空间"。目标端必须先有字典项（建表）且没有物理文件（DISCARD），InnoDB 才能把文件注册进去。直接放文件会被认为文件已存在或孤儿文件。

**Q3：`FOR EXPORT` 期间能读吗？**
能读不能写。它加的是共享锁，会阻塞 DML，并强制刷脏页、生成 `.cfg`。锁跟着会话走，`UNLOCK TABLES` 或会话断开才释放。

**Q4：跨版本能迁吗？**
只能"低版本 → 高版本"，且需要目标版本能识别源端的表空间格式。8.0 → 5.7 绝对不行；5.7 → 8.0 通常可行，但建议先在测试环境验证 `.cfg` 校验。

**Q5：加密表怎么办？**
表空间密钥被 master key 加密，必须让目标实例能解出同一把 master key（迁移 keyring），或者先在源端 `ENCRYPTION='N'` 解密重建后再迁。

---

## 九、总结

可传输表空间的本质是**"物理文件 + 字典注册"**，它把"搬数据"变成了"搬文件"，因此绕过了 SQL 层的所有开销，但也因此对物理格式（页大小、版本、加密、行格式）极度敏感。

落地清单：

1. 迁前三查：页大小、版本方向、是否加密；
2. 目标端严格按源端 `SHOW CREATE TABLE` 建表，再 `DISCARD`；
3. `FOR EXPORT` 的锁绑会话，用独立连接 + `finally UNLOCK`；
4. 大表用"快照 + 增量 CDC"把只读窗口压到秒级；
5. 导入后必做 `ANALYZE TABLE` + 抽样校验 + 重建 FTS/触发器；
6. 把 `lower_case_table_names`、`foreign_key_checks` 这类"环境差异"写进检查清单。

搬 480GB 表的正确姿势，不是找一个更快的 `mysqldump`，而是**别用逻辑导出**。
