---
title: 【数据库实战】MySQL Online DDL 方案深度对比：pt-osc、gh-ost 与原生 DDL
date: 2026-07-04 08:00:00
tags:
  - MySQL
  - DDL
  - 数据库运维
  - 性能优化
categories:
  - MySQL
author: 东哥
---

# 【数据库实战】MySQL Online DDL 方案深度对比：pt-osc、gh-ost 与原生 DDL

## 背景

在生产环境中，随着业务演进，我们经常需要对大表执行 DDL 操作——加字段、建索引、改列类型等。对于百万甚至千万级的大表，直接在原表上执行 `ALTER TABLE` 会导致表锁、主从延迟、甚至拖垮数据库。如何在不影响线上服务的前提下安全执行 DDL，是每个 DBA 和后端工程师必须掌握的技能。

目前业界主流方案有三种：

- **MySQL 原生 Online DDL**（MySQL 5.6+ 引入）
- **pt-online-schema-change**（Percona Toolkit）
- **gh-ost**（GitHub 出品，无触发器方案）

本文将从原理、流程、锁策略、性能、适用场景等方面对三者进行全面对比。

---

## 一、MySQL 原生 Online DDL

### 1.1 原理与演进

MySQL 5.6 引入了 Online DDL（`ALGORITHM=INPLACE`），打破了早期版本中 DDL 必须 copy table 加只读锁的限制。

MySQL 8.0 进一步增强了 Online DDL 的能力：

| 操作类型 | ALGORITHM | LOCK 策略 | 是否允许并发 DML |
|---------|-----------|-----------|---------------|
| 添加二级索引 | INPLACE | NONE | ✅ |
| 添加普通列 | INPLACE | NONE | ✅（8.0 起） |
| 修改列数据类型 | COPY | SHARED | ❌ |
| 添加/删除主键 | COPY | SHARED | ❌ |
| 重命名列 | INPLACE | NONE | ✅ |
| 修改列默认值 | INPLACE | NONE | ✅ |

### 1.2 执行流程

```
1. 检查权限与存储引擎能力
2. 创建临时 ibd 文件
3. 原表允许 DML，同时记录增量变更到日志缓冲区
4. 数据页逐行复制到新文件
5. 应用日志缓冲区的变更（replay）
6. 表空间切换（原子操作）
7. 删除旧文件
```

### 1.3 优缺点

**优点：**
- 内置支持，无需安装额外工具
- 对于简单的 DDL（添加索引、添加列）能做到真正的 Online
- MySQL 8.0 支持原子 DDL

**缺点：**
- 对大表而言，COPY 模式的 DDL 依然会阻塞写入
- 主从场景下，从库同样执行 DDL，可能导致从库延迟
- 内存消耗大（需要额外的 innodb_online_alter_log_max_size 空间）
- 不支持所有操作类型使用 INPLACE 算法

```sql
-- 原生 Online DDL 示例
ALTER TABLE `order` 
ADD COLUMN `remark` VARCHAR(200) DEFAULT '' COMMENT '备注',
ALGORITHM=INPLACE, 
LOCK=NONE;
```

---

## 二、pt-online-schema-change（pt-osc）

### 2.1 工作原理

pt-osc 由 Percona Toolkit 提供，核心思路是**通过触发器同步增量数据**：

```
1. 创建与原表结构相同的空临时表（`_order_new`）
2. 在临时表上执行 ALTER TABLE 修改结构
3. 在原表上创建三个触发器（INSERT/UPDATE/DELETE）
   → 将原表的增量变更同步到临时表
4. 分批逐行复制原表数据到临时表（chunk）
5. 复制完成后，原子性地 RENAME 交换表名
6. 删除原表（备份或直接删）及触发器
```

### 2.2 核心参数

```bash
# 基本用法
pt-online-schema-change \
  h=127.0.0.1,P=3306,u=root,p=xxx,D=mydb,t=orders \
  --alter "ADD COLUMN status TINYINT DEFAULT 0" \
  --execute

# 限速控制
pt-online-schema-change \
  --chunk-time=1 \
  --chunk-size=500 \
  --max-load=Threads_running=50 \
  --alter "ADD INDEX idx_created_at(created_at)" \
  D=mydb,t=orders \
  --execute
```

### 2.3 优缺点

**优点：**
- 成熟稳定，10 年+的生产验证
- 支持丰富的限速、暂停、监控选项
- 可在操作前进行安全检查（`--dry-run`）

**缺点：**
- 依赖触发器，对原表有性能影响
- 触发器的额外开销在高并发写入场景下不可忽略
- 主从切换后触发器会丢失
- 不支持外键表（或需要额外的 `--alter-foreign-keys-method` 参数）
- 触发器可能导致死锁

### 2.4 触发器性能开销

测试数据（10万行写入）：

| 指标 | 无触发器 | 有触发器 | 性能下降 |
|------|---------|---------|---------|
| TPS | 4500 | 3100 | ~31% |
| P99 延迟 | 8ms | 15ms | ~87% |

---

## 三、gh-ost（GitHub Online Schema Migration）

### 3.1 工作原理

gh-ost 是 GitHub 开源的 Online DDL 工具，**最大的创新在于彻底抛弃了触发器**，转而通过 Binlog 同步实现增量数据追踪：

```
1. 创建影子表（`_order_gho`）
2. 在影子表上执行 ALTER TABLE
3. 通过 Binlog 连接伪装为从库
   → 读取原表的行变更事件（Row-Based Replication）
4. 将变更事件应用到影子表
   → 同时进行全量数据复制（chunk-by-chunk）
5. 全量复制完成后，等待 Binlog 追平
6. 原子切换：RENAME 原表为 _order_del，影子表为 order
7. 删除旧表（可选 --postpone-cut-over-flag-file）
```

### 3.2 两种执行模式

**直连模式（直接写 MySQL）：**
```bash
gh-ost \
  --host=127.0.0.1 \
  --port=3306 \
  --user=root \
  --password=xxx \
  --database=mydb \
  --table=orders \
  --alter="ADD COLUMN status TINYINT DEFAULT 0" \
  --execute
```

**代理模式（通过从库同步）：**
```bash
gh-ost \
  --host=127.0.0.1 \
  --port=3306 \
  --assume-master-host=192.168.1.10:3306 \
  --database=mydb \
  --table=orders \
  --alter="ADD INDEX idx_status(status)" \
  --execute
```

### 3.3 关键特性

```bash
# 优雅暂停与恢复
gh-ost ... --throttle-flag-file=/tmp/ghost-pause

# 可推迟切换（指定触发文件）
gh-ost ... --postpone-cut-over-flag-file=/tmp/ghost-cut-over

# 检查主从延迟
gh-ost ... --max-lag-millis=1500

# 测试运行（不实际修改）
gh-ost ... --test-on-replica --execute
```

### 3.4 优缺点

**优点：**
- **无触发器**：对被迁移表的写入性能几乎无额外开销
- **可暂停/可控制**：通过文件信号即可暂停/恢复
- **可审计**：输出详细的进度和 Binlog 位置信息
- **可推迟切换**：适合需要在特定时间窗口完成 DDL 的场景
- **从库友好**：可以在从库测试验证再切换主库执行

**缺点：**
- 要求 MySQL 开启 Row-Based Binlog（`binlog_format=ROW`）
- 要求 Binlog 保留足够长的时间（否则全量复制期间断档）
- 配置相对复杂，需要额外 Binlog 连接
- 对 Binlog 写入量会有一定增加

---

## 四、三方案全维度对比

| 维度 | 原生 Online DDL | pt-osc | gh-ost |
|------|---------------|--------|--------|
| 安装依赖 | 无 | 需安装 Perl + Percona Toolkit | 需下载 gh-ost 二进制 |
| 同步机制 | InnoDB 日志缓冲 | 触发器 | Binlog 伪装从库 |
| 对原表影响 | 低（INPLACE） | 中（触发器开销） | 极低 |
| DML 并发 | ✅（部分操作） | ✅ | ✅ |
| 暂停/恢复 | ❌ | ❌ | ✅（文件信号） |
| 切换控制 | 自动 | 自动 | ✅（可推迟） |
| 限速策略 | 无 | chunk-time/max-load | chunk-size/max-lag |
| 主从延迟感知 | ❌ | ❌ | ✅ |
| 外键支持 | ✅ | 需额外参数 | ✅ |
| 操作复杂度 | 低 | 中 | 中高 |
| Binlog 要求 | 无 | 无 | 必须 RBR |
| 社区活跃度 | MySQL 官方 | Percona（维护中） | GitHub（活跃） |
| 大表（1T+）表现 | 一般（内存受限） | 良好 | 优秀 |

---

## 五、选型建议

### 场景一：简单加索引/加列，表大小 < 100G
```sql
-- 直接用原生 Online DDL
ALTER TABLE `table` ADD INDEX idx_col(col), ALGORITHM=INPLACE, LOCK=NONE;
```

### 场景二：大表（>100G），高并发写入
```bash
# 推荐 gh-ost，无触发器，对业务几乎无感
gh-ost --database=mydb --table=big_table \
  --alter="MODIFY COLUMN content LONGTEXT" \
  --execute
```

### 场景三：Binlog 未开启 RBR 或无法开启
```bash
# 只能选 pt-osc
pt-online-schema-change D=mydb,t=table \
  --alter="ADD COLUMN new_col INT" --execute
```

### 场景四：需要在指定时间窗口完成切换
```bash
# gh-ost 的推迟切换特性最合适
gh-ost ... --postpone-cut-over-flag-file=/tmp/hold \
  --execute
# 凌晨 2 点在另一终端执行：
touch /tmp/hold-release  # 触发切换
```

### 场景五：从库验证后再上主库
```bash
# gh-ost 支持从库测试模式
gh-ost --test-on-replica --execute
```

---

## 六、MySQL 8.0 原生 DDL 改进

MySQL 8.0 在 DDL 方面做了重大改进：

1. **原子 DDL**：DDL 操作整体提交或回滚，不会出现中间状态
2. **即时 DDL（INSTANT）**：MySQL 8.0.12 起支持 `ALGORITHM=INSTANT`
   - 只修改元数据，不涉及数据复制
   - 目前仅支持**添加列**（追加到最后一列）、删除列的部分场景

```sql
-- 8.0.12+ 几乎无成本的操作
ALTER TABLE `table` ADD COLUMN `version` INT DEFAULT 1,
    ALGORITHM=INSTANT;
```

3. **并行 DDL 线程**：8.0.27+ 支持并行构建二级索引，大幅缩短索引创建时间

```sql
-- 设置并行度
SET GLOBAL innodb_ddl_threads = 4;
ALTER TABLE `table` ADD INDEX idx_big(col), ALGORITHM=INPLACE;
```

---

## 七、最佳实践总结

1. **先评估 DDL 类型**：能用原生 INPLACE/INSTANT 就用原生，简单、可靠
2. **大表优先 gh-ost**：无触发器、可控性强、支持 Binlog 追平
3. **pt-osc 是通用备选**：兼容性好，当 gh-ost 不满足条件时使用
4. **监控与限速**：无论用哪种方案，都要关注主从延迟和数据库负载
5. **预演**：先在从库/测试环境验证 DDL 脚本
6. **择时执行**：尽量在业务低峰期操作，预留回滚方案
7. **备份**：DDL 前做好数据备份，必要时在 ddl 前 `FLUSH TABLES WITH READ LOCK`

```bash
# 完整的安全 DDL 流程
# 1. 检查表大小
SELECT table_name, ROUND(((data_length + index_length) / 1024/1024),2) AS size_mb 
FROM information_schema.tables WHERE table_schema='mydb' AND table_name='orders';

# 2. 检查当前负载
SHOW GLOBAL STATUS LIKE 'Threads_running';

# 3. 选择方案并执行（先 dry-run）
gh-ost ... --dry-run

# 4. 低峰期执行
gh-ost ... --execute

# 5. 验证结果
SHOW CREATE TABLE orders;
```

掌握 Online DDL 方案的选择和最佳实践，是在生产环境中安全操作数据库的关键技能。希望本文能帮你在大表变更时做出更明智的决策。
