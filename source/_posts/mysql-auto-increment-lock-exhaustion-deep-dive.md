---
title: 【MySQL 底层】AUTO_INCREMENT 深度解析：自增锁模式、批量插入空洞与主键耗尽治理
date: 2026-09-21 08:00:00
tags:
  - MySQL
  - InnoDB
  - 面试
  - 数据库
categories:
  - MySQL
  - 后端面试
author: 东哥
---

# 【MySQL 底层】AUTO_INCREMENT 深度解析：自增锁模式、批量插入空洞与主键耗尽治理

## 面试官：自增主键为什么会有空洞？这算不算问题？

这是 MySQL 面试里一个「看起来简单，深挖很深」的问题。绝大多数人答「因为回滚了」，然后就没了。但面试官想听的是：

- 自增值是在**什么时候**分配的？
- 分配之后**回滚会不会还回去**？
- **并发插入**时自增值怎么保证不重复？
- `innodb_autoinc_lock_mode` 的三种模式到底差在哪？
- 主键快用完了怎么办？

这四个问题串起来，才是完整的正确答案。这篇我们从源码行为讲到线上治理。

---

## 一、第一性原理：自增值的分配时机

### 1.1 核心结论

**InnoDB 的自增值是在「插入尝试」阶段分配的，且分配后立即持久化到内存计数器，不参与事务回滚。**

```sql
-- 当前 AUTO_INCREMENT = 100
BEGIN;
INSERT INTO t (name) VALUES ('a');   -- 分配 100，计数器变成 101
ROLLBACK;                            -- 回滚了数据，但 100 不会还回去
INSERT INTO t (name) VALUES ('b');   -- 分配 101
SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_NAME='t';
-- 结果：102
```

所以空洞的第一个来源就是：**回滚 / 插入失败，自增值不回退**。

### 1.2 为什么设计成「不回退」

这是**性能与并发的必然选择**。如果自增值要能回退，就意味着：

1. 每次分配都要**加锁并持有到事务结束**（否则无法回退）；
2. 多个并发事务的分配顺序必须严格串行化；
3. 事务回滚时要做「补偿减法」——但如果中间有其他事务已经分配了更大的值，减法就无意义了。

**MySQL 的选择是：自增值只保证「唯一且递增」，不保证「连续无空洞」。** 这是语义上的主动放弃，不是 bug。

---

## 二、自增锁与 `innodb_autoinc_lock_mode`

### 2.1 自增锁是什么

为了并发安全，InnoDB 内部有一把 **AUTO-INC 锁**（表级，但生命周期很短）。过去的实现是「语句级锁」：一条插入语句开始加锁，语句结束释放。

### 2.2 三种模式对比

`innodb_autoinc_lock_mode` 控制这张表：

| 模式值 | 名称 | 行为 | 风险 |
| --- | --- | --- | --- |
| 0 | traditional | 每个插入语句持有 AUTO-INC 锁到语句结束 | 并发差，但自增值连续 |
| 1 | consecutive（默认 ≤5.7） | 简单插入用轻量互斥量预分配；批量插入仍持表锁 | 简单插入快；批量仍可能阻塞 |
| 2 | interleaved（**MySQL 8.0 默认**） | 所有插入都用轻量互斥量，语句间可交错 | 并发最高，但同一条语句的 ID 可能不连续 |

**MySQL 8.0 把默认值改成了 2**，这是主从复制从 statement-based 转向 row-based 之后的必然选择。

### 2.3 模式 2 的具体含义（重点）

```sql
-- 一条批量插入语句
INSERT INTO t (name) VALUES ('a'),('b'),('c');
```

在 **mode 1** 下，这条语句会**一次性预分配 3 个连续 ID**（比如 10、11、12），保证同一条语句内部连续。

在 **mode 2** 下，这三个值可能变成 10、12、15——**因为中间的 11、13、14 被并发语句拿走了**。

**所以 mode 2 下「同一条 INSERT 语句内的自增 ID 不连续」是预期行为。** 如果你的业务依赖「同一批插入的 ID 连续」来做某些假设（比如分片路由），mode 2 会直接打破它。

### 2.4 什么时候必须用 mode 0/1

- **依赖 statement-based binlog 复制**：必须用 0 或 1，否则主从自增 ID 会不一致（这正是老版本默认 1 的原因）；
- **业务强依赖 ID 连续性**：用 1（锁的代价要自己评估）；
- **其他情况**：用 2，享受高并发。

查看与设置：

```sql
SHOW VARIABLES LIKE 'innodb_autoinc_lock_mode';

-- 动态修改（需权限；MySQL 8.0 支持在线改）
SET GLOBAL innodb_autoinc_lock_mode = 1;
```

> **注意**：MySQL 8.0 下改这个参数需要重启才完全生效的旧版本已经过去，8.0 支持动态设置，但改回去会有一致性风险，线上改前务必评估 binlog 格式。

---

## 三、空洞的全部来源

把空洞来源列全，面试才完整：

| 来源 | 是否可避免 | 说明 |
| --- | --- | --- |
| 事务回滚 | 否 | 自增值不回退 |
| 唯一键冲突/插入失败 | 否 | 已分配即消耗 |
| `INSERT ... SELECT` 批量申请 | 否 | 预分配会按需多申请 |
| `REPLACE` / `INSERT ... ON DUPLICATE KEY UPDATE` | 否 | 先尝试插入，冲突时消耗 ID |
| 批量插入中途失败 | 否 | 已分配的 ID 不回收 |
| 主从切换/自增值持久化策略 | 部分 | 8.0 有持久化优化，见下节 |
| `innodb_autoinc_lock_mode = 2` 并发交错 | 是（改模式） | 语句内不连续 |
| 批量申请倍数预分配 | 否 | 见 3.1 |

### 3.1 一个反直觉的点：预分配倍数增长

InnoDB 对批量插入的 ID 申请不是「申请 n 个」这么简单，而是**按 1、2、4、8、16…的倍数增长**：

```text
第 1 次申请：1 个
第 2 次申请：2 个
第 3 次申请：4 个
第 4 次申请：8 个
...
```

这意味着**即使你实际只用了 3 个，也可能申请了 4 个**，多出来的就直接浪费（成为空洞）。这是 `INSERT ... SELECT` 类语句空洞多的原因。

---

## 四、自增值的持久化：MySQL 8.0 的重要改进

### 4.1 老问题（5.7 及以前）

MySQL 5.7 及以前，自增计数器的最大值**只存在内存中**，重启后要重新计算：

```sql
-- 5.7 行为
-- AUTO_INCREMENT 当前是 1000，删除所有数据后重启
-- 重启后重算：max(id) 为空 → AUTO_INCREMENT 重置为 1
-- ⚠️ 于是新的插入会分配 1、2、3... 如果这些 ID 曾经被用过且 binlog 里还有记录 → 主从不一致
```

**这曾是主从数据不一致的经典坑**：主库重启后 ID 从 1 开始，从库上却已经有历史记录，导致主键冲突或复制中断。

### 4.2 MySQL 8.0 的修复

MySQL 8.0 把自增计数器的最大值**持久化到 redo log**，每次变更都写：

- 崩溃恢复时，从 redo log 恢复计数器，**不会回退到 max(id)+1**；
- 涉及持久化的关键点：`counter` 值与 2^32 的阶段性持久化策略（减少写放大）。

```sql
-- 8.0 验证：删除全部数据并重启后
SHOW CREATE TABLE t;
-- AUTO_INCREMENT 依然是删除前的值 + 1，不会重置
```

**这就是为什么升级到 8.0 后，自增值「只会变大不会变小」这个特性最可靠。** 顺便也意味着：**8.0 之后主库重启导致的 ID 回退问题基本消失。**

---

## 五、上线治理：自增主键耗尽

### 5.1 如何判断快耗尽了

```sql
-- 方案一：查当前值
SELECT AUTO_INCREMENT FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'your_db' AND TABLE_NAME = 'your_table';

-- 方案二：查最大值
SELECT MAX(id) FROM your_table;
```

**对 `BIGINT UNSIGNED`**，上限是 18,446,744,073,709,551,615（约 1.8×10^19）。按每秒 1 万条插入算，能用 5.8 亿年——**基本不用担心**。

**对 `INT UNSIGNED`**，上限 4,294,967,295（约 42.9 亿）。**这是真正会耗尽的类型。**

```text
INT 有符号：2,147,483,647（21.4 亿）
INT 无符号：4,294,967,295（42.9 亿）
```

**如果一张表每天插入 1000 万行，INT UNSIGNED 大约 430 天就撞墙。**

### 5.2 撞墙会发生什么

```sql
ERROR 1062 (23000): Duplicate entry '4294967295' for key 'PRIMARY'
```

或者：

```sql
ERROR 1467 (HY000): Failed to read auto-increment value from storage engine
```

**表现是：批量插入开始报主键冲突，服务雪崩。** 注意这个错误不会「优雅降级」——它是硬失败。

### 5.3 治理手段

**① 从建表规范上杜绝（最优先）**

```sql
-- ✅ 永远用 BIGINT UNSIGNED 作为代理主键
CREATE TABLE t (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ...
    PRIMARY KEY (id)
) ENGINE=InnoDB;

-- ❌ 不要用 INT，哪怕是「小表」
```

这条规范的成本是每行多 4 字节，收益是永不耗尽。**极其划算。**

**② 已经用了 INT 的存量表：在线改类型**

```sql
-- MySQL 8.0 支持在线的部分 DDL，但改主键类型通常是 COPY 算法
ALTER TABLE t MODIFY id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;
```

**注意**：这条 DDL 会锁表/重建表，大表必须用 `gh-ost` 或 `pt-online-schema-change`。先评估：

```sql
-- 看会用什么算法
ALTER TABLE t MODIFY id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, ALGORITHM=INPLACE;
-- 如果报错 "ALGORITHM=INPLACE is not supported" → 必须走 COPY，用 gh-ost
```

**③ 重置计数器（危险，需评估）**

```sql
-- 把计数器拉到指定值
ALTER TABLE t AUTO_INCREMENT = 4000000000;
```

> ⚠️ **致命提醒**：如果表中已有 `id >= 4000000000` 的记录，这条语句**没有任何效果**（自增值不会小于 max(id)+1）。而且如果强行让计数器变小再插入，会和已有记录冲突。

**④ 终极方案：改业务主键策略**

- 用**雪花算法（Snowflake）**生成分布式唯一 ID，彻底摆脱单表自增；
- 或者用**号段模式**（Leaf、美团 Leaf-segment），DB 只存号段元数据，每次批量取一段，写入压力极低。

```java
// 雪花算法核心：时间戳 + 机器ID + 序列号
public long nextId() {
    long ts = System.currentTimeMillis();
    if (ts < lastTimestamp) {
        throw new IllegalStateException("Clock moved backwards");
    }
    if (ts == lastTimestamp) {
        sequence = (sequence + 1) & SEQUENCE_MASK;
        if (sequence == 0) {
            ts = waitNextMillis(lastTimestamp);   // 同毫秒序列用尽，等下一毫秒
        }
    } else {
        sequence = 0;
    }
    lastTimestamp = ts;
    return ((ts - EPOCH) << TIMESTAMP_SHIFT)
         | (workerId << WORKER_ID_SHIFT)
         | sequence;
}
```

**雪花算法的取舍**：

| 优点 | 缺点 |
| --- | --- |
| 趋势递增，索引友好 | 依赖系统时钟，回拨要处理 |
| 本地生成，无网络开销 | 机器 ID 需要分配管理 |
| 性能极高（单机 40 万+/s） | ID 较长（19 位），可读性差 |

---

## 六、监控告警怎么做

**不要等撞墙才发现。** 建立一个巡检 SQL：

```sql
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    AUTO_INCREMENT,
    CASE COLUMN_TYPE
        WHEN 'int' THEN 2147483647
        WHEN 'int unsigned' THEN 4294967295
        WHEN 'bigint' THEN 9223372036854775807
        WHEN 'bigint unsigned' THEN 18446744073709551615
    END AS max_value,
    ROUND(AUTO_INCREMENT /
        CASE COLUMN_TYPE
            WHEN 'int' THEN 2147483647
            WHEN 'int unsigned' THEN 4294967295
            WHEN 'bigint' THEN 9223372036854775807
            WHEN 'bigint unsigned' THEN 18446744073709551615
        END * 100, 2) AS used_percent
FROM information_schema.TABLES t
JOIN information_schema.COLUMNS c
  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
 AND t.TABLE_NAME = c.TABLE_NAME
 AND c.COLUMN_KEY = 'PRI'
WHERE t.AUTO_INCREMENT IS NOT NULL
  AND COLUMN_TYPE LIKE '%int%'
HAVING used_percent > 60   -- 超过 60% 就告警
ORDER BY used_percent DESC;
```

**告警阈值建议**：

- `> 60%`：低优先级提醒，排期处理；
- `> 80%`：高优先级，制定迁移方案；
- `> 90%`：**紧急**，立刻启动在线 DDL 或切换发号器。

---

## 七、面试常见追问

**Q1：自增主键用完了，插入会怎样？**

报 `Duplicate entry`（1062）或 `Failed to read auto-increment value`（1467）。**不会自动扩宽类型，也不会报「类型不够」这种友好的错误**，直接就是主键冲突，非常难排查——因为第一反应往往是「怎么会有重复 ID」。

**Q2：为什么不用 UUID 做主键？**

因为 InnoDB 是**聚簇索引**，主键决定物理存储顺序。UUID 是随机的，会导致：

- **页分裂频繁**，B+ 树填充率下降（可能掉到 50%）；
- **插入随机化**，Buffer Pool 命中率下降；
- **二级索引变大**（每个二级索引都存主键值），UUID 36 字节 vs BIGINT 8 字节。

如果非要用 UUID，用 **UUIDv7（时间有序）** 或 `BINARY(16)` 存储，能缓解大部分问题。

**Q3：`INSERT ... ON DUPLICATE KEY UPDATE` 会消耗自增 ID 吗？**

会。它先尝试插入（消耗 ID），冲突了再改走 UPDATE 分支。**所以这个语句的 ID 空洞特别大。**

**Q4：主从复制里自增 ID 怎么保证一致？**

- **statement-based**：必须 `innodb_autoinc_lock_mode = 0/1`，否则从库重放时 ID 分配可能不同；
- **row-based（8.0 默认）**：binlog 里直接记录具体 ID 值，无需从库重新分配，**所以可以放心用 mode 2**。

**Q5：怎么避免自增 ID 空洞？**

**没法避免，也不该避免。** 你只能：

1. 接受空洞（推荐）——ID 的唯一性和递增性才是关键，连续性对业务无意义；
2. 如果业务真的需要连续编号（如发票号），**不要用主键**，用单独的业务流水号表 + 串行发放，并且要接受吞吐下降和分布式下的复杂度。

**记住一句话：自增主键是「技术主键」，不是「业务编号」。把它们混用是设计错误。**

---

## 八、总结

| 要点 | 结论 |
| --- | --- |
| 分配时机 | 插入尝试时分配，立即前移计数器 |
| 回滚行为 | 不回退，空洞永久存在 |
| 锁模式 | 8.0 默认 interleaved(2)，并发最高但语句内不连续 |
| 持久化 | 8.0 起持久化到 redo log，重启不回退 |
| 空洞来源 | 回滚、冲突、批量预分配、REPLACE/ON DUPLICATE |
| 耗尽风险 | INT 会耗尽（43 亿），BIGINT UNSIGNED 不会 |
| 建表规范 | **一律 BIGINT UNSIGNED** |
| 监控 | 巡检 `information_schema`，60/80/90 三档告警 |

面试里如果能把「为什么不回退」解释成「唯一性优先于连续性，这是分布式的必然取舍」，再补一句「8.0 用 redo log 持久化解决了重启回退问题」，这道题就算答透了。
