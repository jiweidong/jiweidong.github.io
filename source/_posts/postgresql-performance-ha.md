---
title: PostgreSQL 性能优化与高可用架构实战
date: 2026-06-16 08:15:00
tags:
  - PostgreSQL
  - 数据库
  - 性能优化
  - 高可用
categories: 数据库
updated: 2026-06-16 08:15:00
description: 深入讲解PostgreSQL性能调优、配置参数、索引类型、查询优化、分区表，以及流复制、Patroni、Pgpool-II等高可用方案和备份恢复策略。
---

## 一、PostgreSQL 性能调优

PostgreSQL 性能调优不是一蹴而就的，它是一个持续迭代的过程。本文将从配置参数、索引类型、查询优化、分区表等维度深入探讨。

### 1.1 核心配置参数调优

PostgreSQL 的默认配置是为小型开发环境设计的。生产环境必须根据硬件资源进行针对性调整。

#### 关键参数对比表

| 参数 | 默认值 | 优化建议 | 说明 |
|------|--------|---------|------|
| `shared_buffers` | 128MB | 物理内存的 25%（不超过 8GB 时建议 25%，超过 8GB 建议 8GB 固定） | 共享缓冲区，**不是**总缓冲区大小 |
| `effective_cache_size` | 4GB | 物理内存的 50%~75% | 帮助优化器判断索引扫描成本 |
| `work_mem` | 4MB | 16MB~64MB（根据并发连接数调整） | 排序、Hash 等操作使用的内存，⚠️ 注意：`total = work_mem * max_connections` |
| `maintenance_work_mem` | 64MB | 1GB~2GB | VACUUM、CREATE INDEX 等维护操作 |
| `wal_buffers` | 16MB | 16MB~64MB（write-heavy 场景建议 64MB） | WAL 写入缓冲区大小 |
| `random_page_cost` | 4.0 | 1.1（SSD） / 4.0（HDD） | 随机 IO 成本，SSD 上降低可让优化器更多使用索引扫描 |
| `effective_io_concurrency` | 1 | 200（SSD） / 2（HDD） | PostgreSQL 可以并发执行的 IO 操作数 |
| `wal_level` | replica | replica（生产） | 决定 WAL 包含的信息量 |
| `max_connections` | 100 | 视业务而定，建议配合连接池 | 每个连接消耗约 10MB 内存 |
| `checkpoint_timeout` | 5min | 15min~30min | 检查点间隔，越长写入吞吐越高，但崩溃恢复越慢 |
| `max_wal_size` | 1GB | 4GB~16GB | 最大 WAL 文件大小 |

#### 计算示例（32GB 内存，16 核，SSD 的服务器）

```ini
# postgresql.conf 优化配置
shared_buffers = 8GB              # 25% of 32GB, capped at 8GB
effective_cache_size = 24GB       # 75% of 32GB
work_mem = 32MB                   # 假设 200 并发连接: 32MB * 200 = 6.4GB
maintenance_work_mem = 2GB        # 加速维护操作
wal_buffers = 64MB                # WAL 写缓冲
random_page_cost = 1.1            # SSD 环境
effective_io_concurrency = 200    # SSD 高并发
max_connections = 200             # 配合 PgBouncer 连接池
checkpoint_timeout = 15min
max_wal_size = 8GB
min_wal_size = 2GB
```

### 1.2 索引类型与选择

PostgreSQL 拥有丰富的索引类型，每种类型适用于不同的查询模式。

#### B-Tree 索引（默认）

```sql
-- 最通用的索引类型，支持 < <= = >= > 和 IN、BETWEEN
CREATE INDEX idx_users_email ON users(email);

-- 多列索引，注意列顺序：等值条件放前面，范围条件放后面
CREATE INDEX idx_users_status_created ON users(status, created_at DESC);

-- 部分索引：只索引特定数据子集，体积小、写入快
CREATE INDEX idx_active_users ON users(created_at) WHERE status = 'active';

-- 索引 INCLUDE 列（覆盖索引，PG 11+）
CREATE INDEX idx_orders_user_id ON orders(user_id) INCLUDE (total_amount, status);
-- 当查询仅需 user_id + total_amount + status 时，无需回表
```

#### GiST 索引（全文搜索、地理空间）

```sql
-- 文本搜索（GIN 更优时以下用 GiST）
CREATE INDEX idx_document_body ON documents USING gin(to_tsvector('english', body));

-- 地理空间查询（PostGIS）
CREATE INDEX idx_locations_geo ON locations USING gist(geo_point);
SELECT * FROM locations WHERE ST_DWithin(geo_point, ST_MakePoint(116.4, 39.9), 10000);
```

#### BRIN 索引（时序数据）

```sql
-- 适合物理上顺序排列的数据（如时间序列），体积远小于 B-Tree
CREATE INDEX idx_logs_created_at ON logs USING brin(created_at)
  WITH (pages_per_range = 32); -- 每 32 个 page 存储一个摘要

-- 相比 B-Tree 索引可减少 95%+ 的空间占用
```

#### 索引选择决策树

```
数据是否顺序插入（时间序列等）?
├─ 是 → BRIN 索引
└─ 否 → 查询类型?
   ├─ 精确匹配 (=) → B-Tree
   ├─ 范围查询 (>, <, BETWEEN) → B-Tree
   ├─ 全文搜索 → GIN
   ├─ 数组包含 → GIN
   ├─ JSONB 查询 → GIN (jsonb_path_ops)
   ├─ 相似度/模糊搜索 → pg_trgm GIN
   └─ 地理空间 → GiST / SP-GiST
```

### 1.3 查询优化与 EXPLAIN ANALYZE

#### EXPLAIN ANALYZE 实战

```sql
-- 原始查询：查找过去 24 小时内订单金额超过 1000 的活跃用户
EXPLAIN (ANALYZE, BUFFERS, TIMING, COSTS)
SELECT u.id, u.name, COUNT(o.id) as order_count, SUM(o.amount) as total_amount
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE u.status = 'active'
  AND o.created_at >= NOW() - INTERVAL '24 hours'
  AND o.amount > 1000
GROUP BY u.id, u.name
HAVING COUNT(o.id) >= 2
ORDER BY total_amount DESC
LIMIT 20;
```

**典型的低效执行计划问题及优化：**

| 执行计划特征 | 问题 | 解决方案 |
|------------|------|---------|
| `Seq Scan on large_table` | 全表扫描大表 | 检查 WHERE 条件是否有索引，统计信息是否最新 |
| `Nested Loop` 评估行数远小于实际 | 统计信息过期 | 执行 `ANALYZE` 更新统计信息 |
| `Sort (external sort)` | work_mem 不足 | 增大 work_mem，或优化排序语句 |
| `Hash Join` 估计 vs 实际偏差大 | 列相关性导致统计不准 | 创建扩展统计信息 |

```sql
-- 创建扩展统计信息（PG 10+）
CREATE STATISTICS s_user_status_amount (dependencies) ON status, amount FROM orders;
ANALYZE orders;
```

#### 查询优化常见技巧

```sql
-- 1. 避免函数包裹索引列（索引失效）
-- 低效（不会走 idx_orders_created_at）:
SELECT * FROM orders WHERE DATE(created_at) = '2026-06-16';
-- 高效（走索引）:
SELECT * FROM orders
  WHERE created_at >= '2026-06-16 00:00:00'
    AND created_at < '2026-06-17 00:00:00';

-- 2. 使用 EXISTS 替代 COUNT > 0
-- 低效:
SELECT * FROM users u
  WHERE (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) > 0;
-- 高效:
SELECT * FROM users u
  WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- 3. 联合查询时注意 NULL 处理
-- COALESCE / NULLS LAST 帮助排序
SELECT * FROM products ORDER BY discount DESC NULLS LAST;

-- 4. 使用物化 CTE（PG 12-）或内联 CTE（PG 12+）
WITH popular_products AS MATERIALIZED (
  SELECT product_id, COUNT(*) as sales
  FROM orders
  GROUP BY product_id
  ORDER BY sales DESC
  LIMIT 100
)
SELECT p.*, pp.sales
FROM products p JOIN popular_products pp ON p.id = pp.product_id;
```

### 1.4 分区表

```sql
-- 创建分区表（按时间分区）
CREATE TABLE orders_partitioned (
  id BIGSERIAL,
  user_id BIGINT NOT NULL,
  amount NUMERIC(10,2) NOT NULL,
  status VARCHAR(20),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- 创建月分区（PG 13+ 支持 PRUNE）
CREATE TABLE orders_202601 PARTITION OF orders_partitioned
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE orders_202602 PARTITION OF orders_partitioned
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE orders_202603 PARTITION OF orders_partitioned
  FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE orders_202604 PARTITION OF orders_partitioned
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE orders_202605 PARTITION OF orders_partitioned
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE orders_202606 PARTITION OF orders_partitioned
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

-- 创建默认分区，防止未覆盖的数据写入失败
CREATE TABLE orders_default PARTITION OF orders_partitioned DEFAULT;

-- 在每个分区上创建本地索引
CREATE INDEX idx_orders_202601_user_id ON orders_202601(user_id);
CREATE INDEX idx_orders_202602_user_id ON orders_202602(user_id);
-- ...每个分区都建立索引

-- 注意：也可以在父表上创建全局索引（PG 12+）
CREATE INDEX idx_orders_user_id_all ON orders_partitioned(user_id);
```

**分区表的优势：**
- **查询裁剪（Partition Pruning）：** 只扫描匹配分区
- **数据管理：** 直接删除旧分区（`DROP TABLE orders_202501`）远快于 DELETE
- **维护窗口：** 单个分区 VACUUM 无需锁全表

## 二、高可用架构

### 2.1 流复制架构

PostgreSQL 原生的流复制是高可用的基础。

```
流复制异步模式架构:
+------------------+              +------------------+
|   Primary (读写)   |  WAL Stream  |  Standby (只读)   |
|   Port: 5432      | -----------> |   Port: 5432      |
|                    |              |                    |
|  streaming_replication: on      |  hot_standby: on   |
+------------------+              +------------------+
          |                               |
          +--- wal_sender                +--- wal_receiver
          +--- max_wal_senders = 5       +--- recovery.conf
```

**流复制配置步骤：**

```bash
# 1. 主库 postgresql.conf
wal_level = replica
max_wal_senders = 5
wal_keep_size = 1024          # MB，保留足够 WAL 供从库追赶
hot_standby = on              # 允许从库只读查询

# 2. 主库 pg_hba.conf (允许从库连接复制)
# TYPE  DATABASE  USER       ADDRESS         METHOD
host    replication replicator  192.168.1.0/24  md5

# 3. 从库创建基础备份
pg_basebackup -h primary_ip -D /var/lib/pgsql/16/data \
  -U replicator -P -v --wal-method=stream

# 4. 从库 standby.signal (PG 12+，旧版本使用 recovery.conf)
touch /var/lib/pgsql/16/data/standby.signal

# 5. 从库 postgresql.conf 配置连接主库
primary_conninfo = 'host=primary_ip port=5432 user=replicator password=xxx'
```

### 2.2 Patroni 高可用集群

Patroni 是目前最流行的 PostgreSQL HA 解决方案，使用分布式一致性存储（etcd/Consul/ZooKeeper）来管理主从切换。

```
Patroni 集群架构:

                  +------------------+
                  |    etcd 集群     |
                  | (leader election) |
                  +--------+---------+
                           |
          +----------------+----------------+
          |                |                |
  +-------+------+  +-----+-------+  +------+-------+
  | Patroni Node 1|  | Patroni Node 2|  | Patroni Node 3|
  | PostgreSQL(主) |  | PostgreSQL(从) |  | PostgreSQL(从) |
  +-------+------+  +------+--------+  +------+--------+
          |                |                |
      HAProxy / PgBouncer (连接路由)
          |
    Application Clients
```

**Patroni 关键特性：**
- 自动故障转移：主库宕机时自动选举新主库
- 自动成员发现：通过 etcd 注册和发现节点
- 无脑裂保证：使用 **L真正的分布式锁** + **同步提交** 防止双主
- REST API：通过 Patroni REST API 管理集群

```yaml
# patroni.yml 配置示例
scope: pg-cluster
namespace: /service/
name: pg-node-01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.1.10:8008

etcd:
  hosts: 192.168.1.100:2379,192.168.1.101:2379,192.168.1.102:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 300
        shared_buffers: 8GB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.1.10:5432
  data_dir: /var/lib/pgsql/16/data
  bin_dir: /usr/pgsql-16/bin
  authentication:
    replication:
      username: replicator
      password: strong_password
    superuser:
      username: postgres
      password: super_strong_password
  parameters:
    wal_level: replica
    hot_standby: on
    max_wal_senders: 5
    wal_keep_size: 1024
```

### 2.3 Pgpool-II 连接池与读写分离

Pgpool-II 提供连接池、读写分离、负载均衡等功能。

```
应用 -> Pgpool-II -> PostgreSQL 集群
                    |
  读查询 -> Standby (负载均衡)
  写查询 -> Primary
  只读事务 -> Standby
```

```ini
# pgpool.conf 关键配置
listen_addresses = '*'
port = 9999
backend_hostname0 = '192.168.1.10'
backend_port0 = 5432
backend_weight0 = 1    # 写权重
backend_hostname1 = '192.168.1.11'
backend_port1 = 5432
backend_weight1 = 3    # 读权重（可以是多个从库的总和）
backend_hostname2 = '192.168.1.12'
backend_port2 = 5432
backend_weight2 = 3

# 读写分离
master_slave_mode = on
master_slave_sub_mode = 'stream'
# 将只读查询发送到 Standby
allow_sql_comments = on
white_function_list = '.*get.*,.*select.*'
black_function_list = '.*nextval.*,.*setval.*,.*insert.*,.*update.*,.*delete.*'
```

## 三、备份与恢复

### 3.1 pg_dump 逻辑备份

```bash
# 全量备份
pg_dump -h localhost -U postgres -d mydb -F c -f /backup/mydb_20260616.dump

# 并行备份（多 CPU 加速）
pg_dump -j 4 -F d -f /backup/mydb_dir mydb

# 恢复
pg_restore -d mydb -j 4 /backup/mydb_20260616.dump
```

### 3.2 pg_basebackup 物理备份

```bash
# 基础备份（必须用于 PITR 和流复制）
pg_basebackup -h localhost -U replicator -D /backup/base_20260616 \
  -X stream -P -v

# 使用压缩
pg_basebackup -h localhost -U replicator -D /backup/base_20260616 \
  -X stream -P -z --compress=9
```

### 3.3 PITR（时间点恢复）

```ini
# 在 postgresql.conf 中开启归档
archive_mode = on
archive_command = 'test ! -f /archive/%f && cp %p /archive/%f'
archive_timeout = 300
```

```bash
# 恢复到指定时间点
# 1. 恢复基础备份
tar -xzf /backup/base_20260616.tar.gz -C /var/lib/pgsql/16/data/
# 2. 配置 recovery.conf
echo "restore_command = 'cp /archive/%f %p'" > recovery.conf
echo "recovery_target_time = '2026-06-16 07:30:00 CST'" >> recovery.conf
echo "recovery_target_action = 'promote'" >> recovery.conf
# 3. 启动 PostgreSQL，自动 PITR
pg_ctl start
```

## 四、监控体系

```sql
-- 查看当前活跃查询
SELECT pid, usename, query, state, wait_event_type, wait_event,
       query_start, NOW() - query_start as duration
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;

-- 查看表大小与死元组比例
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
       pg_size_pretty(pg_total_relation_size(relid)) as total_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;

-- 查看索引使用情况
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read,
       idx_tup_fetch, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;
```

**推荐监控工具：** pg_stat_statements（必装）、pgBadger（日志分析）、pg_stat_monitor（Percona 出品）、Prometheus + postgres_exporter（主流方案）。

## 五、总结

PostgreSQL 的性能优化和高可用是一个系统工程：

1. **配置调优**要从硬件资源出发，用 `shared_buffers`、`effective_cache_size`、`work_mem` 三个参数打好地基
2. **索引选择**决定了查询的性能上限，B-Tree、GiST、GIN、BRIN 各有所长
3. **查询优化**依赖 EXPLAIN ANALYZE 作为分析工具，统计信息是最容易被忽视的关键
4. **高可用架构**建议使用 Patroni + etcd + 流复制 的组合，这是当前社区公认的最佳实践
5. **备份**必须定期验证（`pg_restore` 测试），否则灾难发生时备份可能不可用

> **一句话总结：** PostgreSQL 的性能极限取决于你对它的理解深度，从参数调优到索引策略，从复制架构到备份恢复，每一个环节都值得深入探索。
