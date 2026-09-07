---
title: 【MySQL 运维】MySQL 表碎片化深度解析：页分裂与空洞的产生、检测与 OPTIMIZE TABLE 重建优化
date: 2026-09-07 08:02:00
tags:
  - MySQL
  - InnoDB
  - 性能优化
  - 运维
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MySQL 运维】MySQL 表碎片化深度解析：页分裂与空洞的产生、检测与 OPTIMIZE TABLE 重建优化

## 一个线上事故：删除一半数据，表反而更慢了？

某订单归档系统上线半年后，运维定期把 3 个月前的订单从 `order` 表 DELETE 掉。某天 DBA 发现：这张表**明明只剩 2000 万行**（高峰期 6000 万），但查询却越来越慢，磁盘占用还有 30GB 不降。

问题出在哪？答案就是**表碎片（fragmentation）**。DELETE 掉的行并没有真正释放空间，InnoDB 只是把它们标记为"可复用"，数据页里留下大量**空洞**；而频繁的随机更新又让索引页不断**分裂**，物理存储的连续性被破坏——InnoDB 不得不扫描大量"半空"的页来找到数据。

## 一、碎片是怎么产生的？三种来源

### 1. DELETE 留下的空洞

InnoDB 以 **页（Page，默认 16KB）** 为单位管理数据。DELETE 一行并不会立即把页里的空间归还给文件系统，而是在行记录上打删除标记，页内留下空洞。这些空洞只能被**后续插入的、大小相近的行**复用：

```sql
-- 大量删除后，页内空间分布变成这样（示意）
-- | 行1 | 空洞 | 行3 | 空洞 | 空洞 | 行6 |
```

如果后续插入的行大小差异大（比如归档表字段变长），空洞就永远填不满。结果：**逻辑上行数少了，物理上占用的页没少**，全表扫描要读的页数不变甚至更多。

### 2. 随机插入/更新导致的页分裂

B+ 树索引页满了之后，再插入就要**页分裂**：InnoDB 申请新页，把原页一半的记录搬过去。如果插入顺序是随机的（比如 UUID 主键、随机字符串索引），分裂会持续发生，新页在磁盘上往往不连续，造成：

- 索引逻辑有序，物理上散落；
- 范围扫描（`range scan`）需要跳转大量离散页，随机 IO 暴增；
- 顺序插入（自增主键）只在最右页追加，几乎不分裂——这也是**推荐自增主键**的底层原因之一。

### 3. 变长字段的原地更新

`UPDATE` 把行的某个 `VARCHAR` 字段从短变长，原页放不下时，InnoDB 会把整行**迁移到新页**（页内只留一个指针，称为"行迁移"）。频繁的"先删后插"式更新（如状态字段反复流转）会让行散落在不同页，同样制造碎片。

> 面试官追问：碎片会影响哪些操作？
> 1. **全表扫描**：扫描的页数远多于实际需要的页数，IO 放大；
> 2. **范围查询**：逻辑相邻的数据物理不相邻，随机 IO 代替顺序 IO；
> 3. **缓存命中率**：碎片多的表，同样大小的 Buffer Pool 能装下的有效数据更少；
> 4. **备份与主从**：物理备份体积虚胖，从库回放也更慢。

## 二、怎么检测表碎片？三条命令

### 1. information_schema 统计（最常用）

```sql
SELECT 
    table_name,
    ROUND(data_length / 1024 / 1024, 2) AS data_mb,
    ROUND(index_length / 1024 / 1024, 2) AS index_mb,
    ROUND(data_free / 1024 / 1024, 2) AS free_mb,
    table_rows
FROM information_schema.tables
WHERE table_schema = 'your_db'
ORDER BY data_free DESC;
```

`data_free` 就是"已分配但空闲"的空间（单位字节）。当 `data_free / data_length` 超过 **20%~30%**，就该考虑整理碎片了。注意：`table_rows` 是估算值（InnoDB 按页采样），仅供参考。

### 2. 查看每个表的大小与碎片率

```sql
-- MySQL 8.0 可以直接查
SELECT 
    table_name,
    ROUND(((data_length + index_length) - data_free) / (data_length + index_length) * 100, 2) AS usage_pct,
    ROUND(data_free / 1024 / 1024, 2) AS free_mb
FROM information_schema.tables
WHERE table_schema = 'your_db';
```

### 3. 确认是否真的"虚胖"

对比两个数字：逻辑数据量（`SELECT COUNT(*)` + `AVG_ROW_LENGTH`）与物理文件大小（`ls -lh /var/lib/mysql/库名/表名.ibd` 或 8.0 的 `ibd2sdi`）。物理文件远大于逻辑估算值，基本可以判定碎片严重。

## 三、OPTIMIZE TABLE：原理与正确用法

### 原理：重建表

`OPTIMIZE TABLE t` 的本质是**重建表**：新建一个结构相同的临时表，把原表数据按主键顺序重新插入，然后原子替换。效果：

- 数据页被紧凑排列，空洞消失；
- 索引按主键顺序重建，物理连续性恢复；
- 表空间文件缩小（如果开了独立表空间 `innodb_file_per_table=ON`）。

MySQL 5.7+ 的 OPTIMIZE 走的是 **Online DDL**（`ALGORITHM=INPLACE`），整个过程允许并发 DML，不会锁死业务。但要注意：

```sql
-- 标准用法
OPTIMIZE TABLE `order`;

-- 只整理索引/只整理主键（5.7+ 支持分区粒度）
ALTER TABLE `order` FORCE;  -- 效果等同于 OPTIMIZE
```

> ⚠️ 关键注意点：
> 1. **会消耗临时空间**：重建期间需要约等于表体积的额外磁盘空间（新表 + 原表并存），磁盘不足会失败。大表先用 `ALTER TABLE ... ENGINE=InnoDB` 的别名方式在低峰执行。
> 2. **是重量级操作**：虽然有 Online DDL 加持，但重建 100GB 的表仍会占用大量 IO 和 CPU，**必须在业务低峰期执行**，并观察主从延迟。
> 3. **会短暂锁表**：提交阶段的元数据锁（MDL）需要等待所有事务结束，长事务会卡住重建，甚至反过来阻塞业务——执行前先查 `information_schema.innodb_trx` 有没有大事务。

### 什么时候该做、多久做一次

| 信号 | 建议动作 |
|---|---|
| `data_free` 占比 > 30% | 安排 OPTIMIZE |
| 频繁 DELETE + 插入的流水/日志表 | 每月或每季度一次 |
| 大量随机更新（行迁移多） | 评估后低峰 OPTIMIZE |
| 只有顺序插入、几乎不删改的表 | 不需要（做了也没收益） |
| 大表（>50GB） | 优先考虑分区表 + 分区裁剪/分区 DROP，避免全表重建 |

## 四、大表碎片整理：pt-online-schema-change 与分区策略

### 1. 超过 50GB 的表：别直接 OPTIMIZE

直接 OPTIMIZE 大表风险高（耗时数小时、占用大量临时空间、主从延迟飙高）。业界标准做法是 **pt-online-schema-change**（Percona Toolkit）：

```bash
# 通过触发器把增量变更同步到新表，完成后再原子切换
pt-online-schema-change --alter "ENGINE=InnoDB" \
  D=your_db,t=order --execute --max-lag=5 --chunk-size=1000
```

`--alter "ENGINE=InnoDB"` 是"空操作"ALTER，目的纯粹是触发重建以整理碎片。工具会：
1. 创建结构相同的新表；
2. 分批拷贝旧表数据到新表（chunk 控制，不压垮主库）；
3. 用触发器同步拷贝期间的增量 DML；
4. 校验一致后原子 RENAME 切换。

### 2. 治本：用分区表替代"删除"

订单、日志这类**有明确时间维度的表**，碎片问题的根源是"删除历史数据"。与其 DELETE + 定期 OPTIMIZE，不如直接分区：

```sql
CREATE TABLE `order` (
    id BIGINT NOT NULL,
    created_at DATETIME NOT NULL,
    ...
) PARTITION BY RANGE (TO_DAYS(created_at)) (
    PARTITION p2026q1 VALUES LESS THAN (TO_DAYS('2026-04-01')),
    PARTITION p2026q2 VALUES LESS THAN (TO_DAYS('2026-07-01')),
    PARTITION p2026q3 VALUES LESS THAN (TO_DAYS('2026-10-01')),
    PARTITION p2026q4 VALUES LESS THAN (TO_DAYS('2027-01-01'))
);

-- 归档：直接 DROP 整个分区，瞬间完成且零碎片
ALTER TABLE `order` DROP PARTITION p2026q1;
```

`DROP PARTITION` 是**元数据级操作**，秒级完成，不产生任何碎片，比"DELETE + OPTIMIZE"优雅一个数量级。这是流水表治理碎片的最终答案。

## 五、一个完整的治理案例

场景：`log_record` 表，2 亿行，每天 DELETE 30 天前的数据，全表扫描越来越慢。

排查过程：
1. `information_schema.tables` 查到 `data_free` 高达 8.2GB，物理文件 22GB，但逻辑数据估算仅 9GB——**碎片率约 60%**；
2. 低峰期执行 `OPTIMIZE TABLE log_record`（约 40 分钟），完成后物理文件降到 9.5GB；
3. 全表扫描类慢查询从 3.2s 降到 1.1s，Buffer Pool 命中率明显回升；
4. 中期方案：把表改成按 `log_date` RANGE 分区，每月 `DROP PARTITION` 归档，碎片问题彻底消失。

## 面试连环问

**Q：DELETE 掉的数据会立刻释放磁盘空间吗？**
A：不会。InnoDB 只在页内做删除标记，空间留在页里供后续复用；只有页全部空闲才会被释放回表空间。所以大量 DELETE 后表文件大小基本不变。

**Q：OPTIMIZE TABLE 会锁表吗？业务能继续写吗？**
A：5.7+ 走 Online DDL（INPLACE 算法），拷贝阶段允许并发 DML；但最后切换阶段需要拿 MDL 锁，必须等已有事务结束，长事务会阻塞切换。所以仍建议低峰执行。

**Q：自增主键为什么不容易产生碎片？**
A：顺序插入只在 B+ 树最右侧追加，页满时新页紧邻分配，几乎不发生页分裂和行迁移；随机主键（UUID）会让插入落在索引中间位置，频繁页分裂导致物理离散。

**Q：如何判断一张表该不该 OPTIMIZE？**
A：看 `data_free` 占比（>30% 建议处理）、表是否有大量 DELETE/随机 UPDATE 历史、物理文件与逻辑数据量是否严重偏离。只读的、顺序写入的表不需要。

**Q：大表（100GB）碎片整理，有什么比 OPTIMIZE 更稳的方案？**
A：pt-online-schema-change 分批拷贝+触发器同步，控制主从延迟；或者按时间维度改分区表，用 DROP PARTITION 做归档。都避免了一次性重建大表的风险。

## 总结

碎片是 InnoDB 页式存储的必然产物，DELETE 空洞、随机插入页分裂、变长更新行迁移是三大来源。治理三板斧：**用 `data_free` 检测 → 小表低峰 OPTIMIZE / 大表 pt-osc → 流水表改分区用 DROP PARTITION 治本**。碎片问题不是"性能优化技巧"，而是 MySQL 运维的日常功课——它直接影响扫描页数、缓存命中率和磁盘成本，值得每季度体检一次。
