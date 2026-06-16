---
title: MySQL InnoDB 存储引擎与 B+ 树原理全解
date: 2026-06-16 09:10:00
tags:
  - MySQL
  - InnoDB
  - B+树
  - 存储引擎
categories:
  - 数据库
author: 东哥
---

# MySQL InnoDB 存储引擎与 B+ 树原理全解

## 一、为什么 InnoDB 成了 MySQL 的默认引擎？

MySQL 5.5 起，InnoDB 取代 MyISAM 成为默认存储引擎。核心原因：

| 特性 | InnoDB | MyISAM |
|------|--------|--------|
| 事务 | ✅ ACID 支持 | ❌ 不支持 |
| 行锁 | ✅ 行级锁 | ❌ 表级锁 |
| 外键 | ✅ | ❌ |
| 崩溃恢复 | ✅ Redo Log 自动恢复 | ❌ 需手动修复 |
| MVCC | ✅ | ❌ |
| 全文索引 | ✅ (5.6+) | ✅ |
| 聚簇索引 | ✅ | ❌ |

选型结论：

> **OLTP（在线事务处理）场景一律选 InnoDB**。MyISAM 仅在只读、表量小、不需要事务的场合还能一战。

## 二、InnoDB 的核心存储结构

### 2.1 表空间（Tablespace）

```
InnoDB 表空间
 ├── 系统表空间 (ibdata1)
 │    ├── Double Write Buffer
 │    ├── Insert Buffer (Change Buffer)
 │    ├── Undo Log
 │    └── 数据字典
 ├── 独立表空间 (xxx.ibd)
 │    ├── 段 (Segment)
 │    ├── 段 (Segment)
 │    └── ...
 └── 临时表空间 (ibtmp1)
```

**配置推荐：**

```ini
[mysqld]
# 启用独立表空间（默认开启），每张表一个 ibd 文件
innodb_file_per_table = 1

# 系统表空间文件大小，避免自动扩展过于频繁
innodb_data_file_path = ibdata1:1G:autoextend

# Undo 表空间独立
innodb_undo_tablespaces = 4
```

### 2.2 页（Page）— InnoDB 最小的 IO 单元

```
+---------------------------+  ← 页头 (Page Header)
| 页号、类型、LSN、校验和     |     38 字节
+---------------------------+
| 系统行记录 (Infimum / Supremum) |
+---------------------------+
| 用户记录 (User Records)    |  ← 存入实际数据
|     ↓                     |
|     Row 1                 |
|     Row 2                 |
|     ...                   |
+---------------------------+
| 空闲空间 (Free Space)      |
+---------------------------+
| 页目录 (Page Directory)    |
+---------------------------+
| 页尾 (File Trailer)       |  ← 校验和 + LSN（8 字节）
+---------------------------+
```

**关键参数：**

```sql
-- 查看页大小（默认 16KB）
SHOW VARIABLES LIKE 'innodb_page_size';
-- 16KB = 16384 bytes
```

页类型：

| 页类型 | 说明 | 存储内容 |
|--------|------|---------|
| INDEX 页 | B+ 树节点 | 索引记录 |
| DATA 页 | 数据页 | 行记录 |
| UNDO 页 | 撤销段 | 回滚信息 |
| BLOB 页 | 大对象 | TEXT/BLOB 溢出数据 |

## 三、B+ 树索引原理

### 3.1 B+ 树 vs B 树

| 对比项 | B 树 | B+ 树 |
|--------|------|-------|
| 数据存储位置 | 叶子 + 非叶子节点都存 | **仅叶子节点存数据** |
| 叶子节点结构 | 独立 | 双向链表连接 |
| 范围查询 | 中序遍历效率低 | 叶子链表直接扫描 |
| 查找稳定性 | 不一定（可能在中间节点找到） | 必须到叶子 |
| IO 次数 | 较少（但范围查询差） | 较稳定（范围查询极强） |

**B+ 树的最大优势就是范围查询和排序：**

```sql
-- B+ 树叶子节点的双向链表让这条 SQL 非常高效
SELECT * FROM user WHERE id BETWEEN 100 AND 200;
-- 找到 100 然后沿着叶子链表往后遍历即可
```

### 3.2 聚簇索引（Clustered Index）

InnoDB 的数据就是索引，索引就是数据：

```
InnoDB 聚簇索引结构（以主键为例）：

         [50]
        /    \
     [20]    [80]
    /   \    /   \
  [10] [30] [60] [90]    ← 叶子节点，存完整行数据
   ↓    ↓    ↓    ↓
  (leaf nodes are linked as doubly linked list)
```

**聚簇索引规则：**

```sql
-- 1. 有主键 → 主键就是聚簇索引
CREATE TABLE user (
    id INT PRIMARY KEY,   -- 聚簇索引
    name VARCHAR(50),
    age INT
);

-- 2. 无主键但有唯一非空列 → 该列为聚簇索引
CREATE TABLE user (
    uuid VARCHAR(36) NOT NULL UNIQUE,  -- 聚簇索引
    name VARCHAR(50)
);

-- 3. 都没有 → InnoDB 自动生成 6 字节的 ROW_ID
-- 查看隐藏列
SELECT _rowid FROM user;  -- 某些情况下可用
```

**聚簇索引对性能的影响：**

```sql
-- ✅ 主键建议用自增 INT/BIGINT
-- 自增主键插入时只追加到末尾，不会触发页分裂
CREATE TABLE t1 (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    data VARCHAR(100)
);

-- ❌ 随机主键（UUID）频繁页分裂，写入性能差
CREATE TABLE t2 (
    id VARCHAR(36) PRIMARY KEY,  -- UUID 随机
    data VARCHAR(100)
);
```

**页分裂代价：**

```
插入自增主键：     [10]→[20]→[30]→[40]→[50]  ← 尾部追加，无分裂
插入随机主键：     [10]→[40]→[20]→[???]       ← 页满，需要分裂
                        ↑
                新页：复制一半数据过去，更新指针
```

### 3.3 二级索引（Secondary Index / 非聚簇索引）

```sql
-- 创建二级索引
CREATE INDEX idx_name ON user(name);

-- 二级索引结构：
-- 叶子节点存储：name + 主键 id
-- 不存整行数据！
```

**回表查询过程：**

```sql
SELECT * FROM user WHERE name = '张三';
```

```
Step 1: 走索引 idx_name
       在 B+ 树中找到 name='张三' 的叶子节点
       得到主键 id = 100

Step 2: 回表
       通过主键 100 到聚簇索引的 B+ 树查找
       找到完整行数据返回

共计 2 次 B+ 树查找
```

### 3.4 覆盖索引（Covering Index）

```sql
-- 如果查询只需要 name 和 age
-- 创建联合索引
CREATE INDEX idx_name_age ON user(name, age);

-- 这个查询不需要回表！
SELECT name, age FROM user WHERE name = '张三';
```

**判断是否覆盖索引：**

```sql
EXPLAIN SELECT name, age FROM user WHERE name = '张三';
-- Extra: Using index    ← 表示覆盖索引，不需要回表

EXPLAIN SELECT * FROM user WHERE name = '张三';
-- Extra: NULL          ← 需要回表
```

## 四、索引下推（Index Condition Pushdown, ICP）

MySQL 5.6 引入的优化：

```sql
-- 联合索引 (name, age)
SELECT * FROM user WHERE name LIKE '张%' AND age > 18;
```

**无 ICP（回表后才过滤）：**
```
索引查找 name LIKE '张%' → 得到 3 行主键
回表 3 次               → 得到 3 行完整数据
再过滤 age > 18        → 最终 2 行
```

**有 ICP（引擎层直接过滤）：**
```
索引查找 name LIKE '张%'
在引擎层用 age > 18 直接在索引上过滤 → 只剩 2 行
回表 2 次               → 最终 2 行
节省 1 次回表！
```

```sql
-- 查看 ICP 是否生效
EXPLAIN SELECT * FROM user WHERE name LIKE '张%' AND age > 18;
-- Extra: Using index condition   ✅ ICP 生效
```

## 五、自适应哈希索引（Adaptive Hash Index, AHI）

InnoDB 自动将频繁访问的索引页加载到哈希表中：

```
条件：B+ 树某页被连续访问 N 次（N 可配置）
       ↓
InnoDB 自动为该页建哈希索引
       ↓
等值查询时直接 O(1) 命中，跳过 B+ 树查找
```

```sql
-- 查看 AHI 状态
SHOW ENGINE INNODB STATUS \G
-- 搜索 "Hash table size" 和 "heap size"

-- 查看 AHI 命中率
SHOW STATUS LIKE '%adaptive_hash%';
```

## 六、Double Write Buffer — 数据持久化的保障

InnoDB 的页是 16KB，但 OS 的写入单位是 4KB（page）。如果 16KB 只写了 8KB 就崩溃，就会产生"部分写损坏"。

**解决：**

```
写入流程：
行数据 → Buffer Pool → Double Write Buffer(2MB)
                           ↓
                    同时写入 ibdata1 的双写区域(顺序写)
                    和真正的数据文件位置(随机写)
                           ↓
崩溃恢复时，如果数据页损坏 → 从 Double Write Buffer 恢复
```

```sql
-- 查看双写开关（建议保持开启）
SHOW VARIABLES LIKE 'innodb_doublewrite';
-- 在 NVMe SSD 上可以考虑关闭换取性能
-- SET GLOBAL innodb_doublewrite = 0;
```

## 七、Change Buffer — 二级索引写入优化

修改二级索引时，如果索引页不在 Buffer Pool 中，不会立即读入，而是缓存修改到 Change Buffer：

**适用操作：** INSERT、UPDATE、DELETE 的二级索引修改

**合并时机：**
- 该索引页被读取到 BP 时
- BP 空间不足时
- 后台线程定期合并

```sql
-- Change Buffer 大小配置
SHOW VARIABLES LIKE 'innodb_change_buffer_max_size';
-- 默认 25（占 Buffer Pool 的 25%）
-- 如果二级索引修改多，可以调大
```

## 八、常见面试题

### Q1：为什么 MySQL 的 IO 单位是 16KB？

```text
原因：
1. 磁盘 IO 耗时主要在于寻道（≈10ms）
2. 一次 16KB 比 4 次 4KB 快得多（少 4 倍寻道）
3. B+ 树的一个节点刚好放一页，每个节点足够大
   减少树高度（3 层 B+ 树 ≈ 存储千万级数据）
```

### Q2：一个 3 层 B+ 树能存多少数据？

```text
假设：
- 页大小 16KB
- 主键 BIGINT（8 字节）+ 指针（6 字节）= 14 字节/条
- 每页能存：16KB / 14 ≈ 1170 条索引记录
- 叶子节点每行数据 ≈ 1KB

计算：
- 第一层（根）：1 页，指向 1170 个中间节点
- 第二层（中间）：1170 页，指向 1170×1170 = 1,368,900 个叶子节点
- 第三层（叶子）：每页 16 条数据（16KB/1KB）

总数据量 ≈ 1,368,900 × 16 ≈ 21,902,400 ≈ 2200 万条

结论：2200 万数据量下，B+ 树只需 3 次 IO 就能定位到数据。
```

## 九、总结

| 知识点 | 一句话 | 面试价值 |
|--------|--------|---------|
| B+ 树 | 叶子存数据 + 双向链表，范围查询王者 | ⭐⭐⭐⭐⭐ |
| 聚簇索引 | 主键即数据，自增主键更优 | ⭐⭐⭐⭐⭐ |
| 覆盖索引 | 不回表、IO 最少，终极优化手段 | ⭐⭐⭐⭐⭐ |
| ICP | 引擎层过滤，减少回表次数 | ⭐⭐⭐⭐ |
| AHI | 自动建立，等值查询 O(1) | ⭐⭐⭐ |
| Double Write | 防部分写损坏 | ⭐⭐⭐ |
| Change Buffer | 延迟合并二级索引修改 | ⭐⭐⭐ |
