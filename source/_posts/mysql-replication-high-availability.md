---
title: MySQL 主从复制与高可用架构实战
date: 2026-06-16 09:40:00
tags:
  - MySQL
  - 主从复制
  - 高可用
  - 分库分表
  - 读写分离
categories:
  - 数据库
author: 东哥
---

# MySQL 主从复制与高可用架构实战

## 一、为什么需要主从复制？

单个 MySQL 实例能支撑的并发量是有限的，而且一旦宕机，服务就完全不可用。

| 问题 | 单机 | 主从架构 |
|------|------|---------|
| 读压力 | 读写争抢，响应慢 | 读走从库，水平扩展 |
| 写压力 | 单点瓶颈 | 主库专注写 |
| 高可用 | 宕机 = 服务停 | 从库可升主 |
| 容灾 | 无 | 异地从库 |
| 数据安全 | 误删就没了 | 从库可延时备份 |

## 二、主从复制原理

### 2.1 核心流程

```
             Master                              Slave
   +-----------------------+            +-----------------------+
   |        事务提交        |            |                       |
   |           ↓           |            |                       |
   |  Binlog (二进制日志)    |  网络传输   |   Relay Log           |
   |  write → fsync        |----------->|   (中继日志)           |
   |           ↑           |            |           ↓           |
   |    Dump Thread        |            |   SQL Thread          |
   |   (转储线程)           |            |   (回放)              |
   +-----------------------+            +-----------------------+
                                                 ↓
                                        +-----------------------+
                                        |     数据文件            |
                                        +-----------------------+
```

**三个线程协作：**

| 线程 | 位置 | 职责 |
|------|------|------|
| **Dump Thread** | Master | 读取 Binlog 发送给 Slave |
| **IO Thread** | Slave | 接收 Binlog 写入 Relay Log |
| **SQL Thread** | Slave | 读取 Relay Log 回放 SQL |

### 2.2 Binlog 格式

```sql
-- 查看 binlog 格式
SHOW VARIABLES LIKE 'binlog_format';
```

| 格式 | 说明 | 优缺点 |
|------|------|--------|
| **STATEMENT** | 记录原始 SQL | 体积小，但 rand() 等函数可能不一致 |
| **ROW** | 记录行变更前后数据 | 一致性最好，但体积大 |
| **MIXED** | 自动选择 | 大部分 STATEMENT，不确定时用 ROW |

**生产推荐：ROW 格式**，配合 GTID 使用。

```sql
-- 二进制日志配置
SHOW BINARY LOGS;           -- 查看所有 binlog 文件
SHOW BINLOG EVENTS IN 'mysql-bin.000001';  -- 查看 binlog 内容

-- 解析 binlog 为 SQL
mysqlbinlog --base64-output=decode-rows -v mysql-bin.000001
```

### 2.3 GTID 复制（推荐）

GTID（Global Transaction Identifier）让每个事务都有全局唯一 ID：

```
GTID = server_uuid:transaction_id
例如：3E11FA47-71CA-11E1-9E33-C80AA9429562:1
```

**GTID 的优势：**

```sql
-- 传统复制需要手动指定 binlog 文件名和位置
CHANGE MASTER TO
  MASTER_LOG_FILE='mysql-bin.000001',
  MASTER_LOG_POS=107;

-- GTID 复制自动匹配
CHANGE MASTER TO
  MASTER_HOST='10.0.1.10',
  MASTER_USER='repl',
  MASTER_PASSWORD='xxx',
  MASTER_AUTO_POSITION=1;
```

## 三、主从配置实战

### 3.1 Master 配置

```ini
[mysqld]
server-id = 1                    # 唯一 ID，不能重复
log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
binlog_do_db = test_db           # 只复制该库（可选）
expire_logs_days = 7             # binlog 保留 7 天
max_binlog_size = 100M           # 单个 binlog 大小

# 以下两行是 GTID 复制要求
gtid_mode = ON
enforce_gtid_consistency = ON

# 推荐（并行复制需要）
binlog_group_commit_sync_delay = 100
binlog_group_commit_sync_no_delay_count = 10
```

```sql
-- 创建复制用户
CREATE USER 'repl'@'10.0.1.%' IDENTIFIED WITH mysql_native_password BY 'password';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'10.0.1.%';
FLUSH PRIVILEGES;
```

### 3.2 Slave 配置

```ini
[mysqld]
server-id = 2
log_bin = /var/log/mysql/mysql-bin.log
relay_log = /var/log/mysql/relay-bin
read_only = 1                    # 从库只读（防止误写）
relay_log_recovery = ON          # relay log 崩溃恢复

# 并行复制（MySQL 5.7+）
slave_parallel_workers = 4       # 4 个并行 SQL 线程
slave_parallel_type = LOGICAL_CLOCK
```

```sql
-- 配置复制
CHANGE MASTER TO
  MASTER_HOST='10.0.1.10',
  MASTER_PORT=3306,
  MASTER_USER='repl',
  MASTER_PASSWORD='password',
  MASTER_AUTO_POSITION=1;

-- 启动复制
START SLAVE;

-- 查看复制状态
SHOW SLAVE STATUS \G

-- 重点关注：
-- Slave_IO_Running: Yes
-- Slave_SQL_Running: Yes
-- Seconds_Behind_Master: 0
```

### 3.3 复制状态监控

```sql
-- 复制延迟监控
SHOW SLAVE STATUS \G

-- 关键字段：
-- Slave_IO_State: Waiting for master to send event
-- Master_Log_File: mysql-bin.000032      -- 主库当前 binlog
-- Read_Master_Log_Pos: 956789            -- IO 线程读到的位置
-- Relay_Log_File: relay-bin.000008       -- 当前 relay log
-- Relay_Log_Pos: 456789                  -- SQL 线程执行到的位置
-- Relay_Master_Log_File: mysql-bin.000032
-- Slave_IO_Running: Yes
-- Slave_SQL_Running: Yes
-- Seconds_Behind_Master: 2               -- 延迟秒数（不是绝对精确）
```

**生产监控脚本：**

```bash
#!/bin/bash
# 监控复制延迟
DELAY=$(mysql -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master" | awk '{print $2}')
if [ "$DELAY" -gt 60 ]; then
    echo "CRITICAL: Replication delay $DELAY seconds"
    # 触发告警...
fi
```

## 四、常见复制问题

### 4.1 主从延迟

**延迟原因：**

| 原因 | 说明 | 解决 |
|------|------|------|
| 大事务 | 一个事务更新 100 万行 | 拆分成小事务 |
| 主库 DDL | ALTER TABLE 阻塞 SQL 线程 | 使用 pt-online-schema-change |
| 从库配置低 | CPU/IO 跟不上主库 | 从库配置与主库一致 |
| 单线程回放 | 历史遗留 | 开启并行复制 |

**业务侧应对：**

```java
// 强制读主库（重要数据）
@Transactional
public Order getLatestOrder(Long userId) {
    // 使用 @Master 注解强制走主库
    return orderMapper.selectLatestByUserId(userId);
}

// 容忍短暂延迟的场景
public List<Order> getHistoryOrders(Long userId) {
    // 读从库，容忍几秒延迟
    return orderReadMapper.selectByUserId(userId);
}
```

```yaml
# ShardingSphere 读写分离配置
spring.shardingsphere.rules.readwrite-splitting:
  data-sources:
    rw_ds:
      type: Static
      props:
        write-data-source-name: ds-master
        read-data-source-names: ds-slave-0,ds-slave-1
  load-balancers:
    round_robin:
      type: ROUND_ROBIN
```

### 4.2 主从数据不一致

```bash
# 使用 pt-table-checksum 校验一致性
pt-table-checksum h=10.0.1.10,u=root,p=xxx \
  --replicate=test.checksums --no-check-binlog-format

# 不一致时修复
pt-table-sync h=10.0.1.10,u=root,p=xxx \
  h=10.0.1.11,u=root,p=xxx \
  --replicate=test.checksums --print

# 确认无误后执行同步
pt-table-sync h=10.0.1.10,u=root,p=xxx \
  h=10.0.1.11,u=root,p=xxx --execute
```

## 五、高可用架构方案

### 5.1 方案对比

| 方案 | 自动切换 | 一致性 | 运维复杂度 | 适用场景 |
|------|---------|--------|-----------|---------|
| **MHA** | ✅ | 最终 | 高 | 中小规模（传统方案） |
| **Orchestrator** | ✅ | 强 | 中 | 中小规模（推荐） |
| **MySQL InnoDB Cluster** | ✅ | 强 | 低 | 官方方案（8.0+） |
| **ProxySQL + 主从** | 依赖组件 | 最终 | 中 | 读写分离场景 |
| **Galera / Percona XtraDB** | ✅ | 强 | 中 | 多写场景 |

### 5.2 MHA 架构（经典方案）

```
                     +-----------------+
                     |   Application    |
                     +--------+--------+
                              |
                     +--------v--------+
                     |     VIP         |
                     | (10.0.1.100)    |
                     +--------+--------+
                              |
        +---------------------+---------------------+
        |                                           |
+-------v-------+                          +--------v-------+
|   Master      |<----- 复制 --------------|   Slave 1      |
| (10.0.1.10)   |                          | (10.0.1.11)    |
+---------------+                          +----------------+
        |                                           |
        |                                           |
        +------- 复制 ------------------------------+
                                                    |
                                            +-------v-------+
                                            |   Slave 2      |
                                            | (10.0.1.12)    |
                                            +----------------+

+-------------------------------------------------------+
| MHA Manager（独立的监控节点）                            |
| 1. 监控主库健康                                        |
| 2. 故障时自动选新主                                     |
| 3. 切换 VIP                                            |
| 4. 其余从库指向新主                                     |
+-------------------------------------------------------+
```

### 5.3 Orchestrator（推荐方案）

Orchestrator 是 GitHub 开源的 MySQL 高可用管理工具，支持 GUI。

```bash
# orchestrator 配置示例
orchestrator -c discover -i 10.0.1.10:3306

# 手动故障切换
orchestrator -c graceful-master-takeover \
  -i m_hostname:3306 \
  -d s_hostname:3306
```

### 5.4 MySQL InnoDB Cluster（官方方案，8.0+）

```bash
# 使用 MySQL Shell 部署
mysqlsh

# 创建集群
var cluster = dba.createCluster('myCluster');
cluster.addInstance('root@10.0.1.11:3306');
cluster.addInstance('root@10.0.1.12:3306');

# 查看状态
cluster.status();

# 自动故障转移
# Router 自动发现新主
mysqlrouter --bootstrap root@10.0.1.10:3306 --user=mysqlrouter
```

## 六、分库分表（Sharding）

### 6.1 什么时候需要分库分表？

```sql
-- 单表超过 500 万行或磁盘超过 500GB
-- 单库连接数瓶颈（max_connections 不够）
-- 写入 IO 成为瓶颈

-- 查看表大小
SELECT
    table_schema AS '数据库',
    table_name AS '表名',
    round(((data_length + index_length) / 1024 / 1024), 2) AS '大小(MB)'
FROM information_schema.TABLES
WHERE table_schema = 'test_db'
ORDER BY (data_length + index_length) DESC;
```

### 6.2 分库分表策略

| 策略 | 说明 | 适用场景 |
|------|------|---------|
| **垂直拆分** | 按业务模块拆分到不同库 | 微服务解耦 |
| **水平拆分** | 按分片键拆分到不同表 | 单表数据量大 |

**水平分片算法：**

```java
// 取模分片
int shard = userId % 16;  // 16 张表

// 范围分片
// user_0000: id 1-1000000
// user_0001: id 1000001-2000000

// 一致性哈希
int shard = (userId.hashCode() & Integer.MAX_VALUE) % 1024;
```

### 6.3 ShardingSphere 实战

```yaml
# ShardingSphere-JDBC 配置
spring.shardingsphere:
  datasource:
    names: ds0, ds1, ds2
    ds0:
      url: jdbc:mysql://10.0.1.10:3306/order_db0
    ds1:
      url: jdbc:mysql://10.0.1.11:3306/order_db1
    ds2:
      url: jdbc:mysql://10.0.1.12:3306/order_db2
  rules:
    sharding:
      tables:
        t_order:
          actual-data-nodes: ds$->{0..2}.t_order_$->{0..15}
          table-strategy:
            standard:
              sharding-column: order_id
              sharding-algorithm-name: order-mod
          database-strategy:
            standard:
              sharding-column: user_id
              sharding-algorithm-name: db-mod
      sharding-algorithms:
        order-mod:
          type: MOD
          props:
            sharding-count: 16
        db-mod:
          type: MOD
          props:
            sharding-count: 3
```

### 6.4 分库分表的坑

| 问题 | 说明 | 解决方案 |
|------|------|----------|
| 跨分片查询 | 分页/排序需合并 | 避免跨分片查询 |
| 分布式事务 | 跨库一致性 | Seata / TCC |
| 自增主键 | 各分片自增冲突 | 雪花算法 / 分布式 ID |
| 扩容困难 | 取模分片扩容要迁移 | 一致性哈希 / 双倍扩容 |

## 七、总结

MySQL 的高可用架构演进路线：

```
单机 → 主从复制 → 读写分离 → MHA/Orchestrator → InnoDB Cluster → 分库分表
                           ↓                       ↓
                      应对读瓶颈               应对写瓶颈
```

**核心建议：**

1. **首先做好主从复制**（binlog ROW + GTID + 并行复制）
2. **监控复制延迟**，大事务拆分
3. **高可用优先选 Orchestrator** 或官方 InnoDB Cluster
4. **分库分表是最后手段**，先考虑缓存、读写分离、连接池优化
5. **数据一致性高于一切**，读写分离时要识别关键路径强制读主库
