---
title: Redis 持久化机制深度解析：RDB vs AOF 原理、配置与生产最佳实践
date: 2026-07-18 08:00:00
tags:
  - Redis
  - 持久化
  - RDB
  - AOF
categories:
  - Redis
  - 中间件
author: 东哥
---

# Redis 持久化机制深度解析：RDB vs AOF 原理、配置与生产最佳实践

## 一、为什么 Redis 需要持久化？

Redis 是内存数据库，所有数据都存储在内存中。一旦进程退出或宕机，如果不做持久化，所有数据都将丢失。

> **面试官**：Redis 不是缓存吗，数据丢了有什么关系？

这就是很多人的理解误区。Redis 的典型使用场景包括：
- **缓存**：丢了可从 DB 恢复，容忍丢失
- **分布式锁**：丢了会导致锁失效，可能引发并发问题
- **计数/排行榜**：丢了需要重新计算
- **会话/Token**：丢了会导致用户强制下线
- **消息队列（Stream）**：丢了可能导致消息丢失

所以，**持久化不是可选项，而是必选项**。问题只在于：应该选 RDB 还是 AOF？如何配置才能兼顾性能和数据安全？

---

## 二、RDB 持久化（Redis DataBase）

RDB 是 Redis 默认的持久化方式，以**快照（snapshot）** 的形式保存某一时刻的完整数据。

### 2.1 原理：Copy-on-Write（写时复制）

RDB 的核心机制是 **fork() + 写时复制（COW）**：

```
Redis 进程（主进程）
    │
    ├─▶ 触发 BGSave
    │
    ├─▶ fork() 创建子进程
    │    子进程 = 父进程内存页表的完整副本
    │
    ├─▶ 子进程开始写 RDB 文件
    │    遍历所有 db → 所有 key-value → 序列化到临时文件
    │
    ├─▶ 在此期间，父进程继续处理请求
    │    如果某个内存页被修改 → 发生缺页中断 → 复制该页再修改
    │    未被修改的页：父子进程共享
    │
    └─▶ 子进程写完 → 临时文件 rename(2) 覆盖目标 RDB 文件
```

**关键点**：
- **fork() 开销**：fork() 需要复制页表，内存越大，fork 越慢。100GB 实例 fork 可能需要秒级
- **COW 开销**：写操作频繁时，父进程需要复制修改的内存页，内存实际占用可能升高
- **RDB 原子替换**：写临时文件 + rename 覆盖，保证 RDB 文件要么是旧的完整版，要么是新的完整版

### 2.2 触发方式

```bash
# 1. SAVE 命令（同步，阻塞）
127.0.0.1:6379> SAVE
OK

# 2. BGSAVE 命令（异步，推荐）
127.0.0.1:6379> BGSAVE
Background saving started

# 3. 自动触发（通过配置）
save 900 1      # 900秒内至少1个key变化
save 300 10     # 300秒内至少10个key变化
save 60 10000   # 60秒内至少10000个key变化

# 4. 关机时触发（shutdown 命令）
# 5. 主从全量复制
# 6. DEBUG RELOAD
```

### 2.3 RDB 文件结构

```
┌──────────────────────────────────┐
│ REDIS0009   ← Magic + Version    │ 9 bytes
├──────────────────────────────────┤
│ db_version                       │ 4 bytes（数据库版本号）
├──────────────────────────────────┤
│ DATABASES SECTION                │
│  ├─ SELECTDB 0                   │
│  │  ├─ RESIZEDB (hash size)      │
│  │  ├─ key-value pairs           │
│  │  └─ EXPIRETIME (if has TTL)   │
│  └─ SELECTDB 1 ...               │
├──────────────────────────────────┤
│ EOF                              │ 标记结束
├──────────────────────────────────┤
│ CRC64 校验和                     │ 8 bytes
└──────────────────────────────────┘
```

### 2.4 RDB 的优缺点

| 优点 | 缺点 |
|------|------|
| 文件紧凑，适合备份、跨机房传输 | 丢失数据较多（两次快照之间的数据） |
| 恢复速度快（直接载入内存） | fork() 可能阻塞主进程（大实例） |
| 子进程写文件，不阻塞主进程 | COW 可能导致内存膨胀 2 倍 |
| 支持压缩，节省磁盘空间 | 大数据集时 fork 时间可能到秒级 |

---

## 三、AOF 持久化（Append Only File）

AOF 以**追加日志**的方式记录每次**写操作命令**，重启时重新执行这些命令来恢复数据。

### 3.1 原理：写后日志（Write-Ahead Logging 的变体）

与大多数数据库（如 MySQL Binlog）的"写前日志"不同，Redis AOF 是**写后日志**：

```
Client 发送写命令
    │
    ├─▶ Redis 执行命令（修改内存数据）
    │
    └─▶ 将命令追加到 AOF 缓冲区（aof_buf）
         │
         └─▶ 根据刷盘策略写入磁盘（write + fsync）
```

**为什么是写后日志？**

1. **不阻塞写性能**：先执行成功再写日志，即使日志写入失败也不影响数据
2. **语法检查**：写入 AOF 的命令都是执行成功的，不会有不合法命令
3. **恢复可靠**：AOF 中每条命令都曾在内存中生效过

### 3.2 AOF 刷盘策略

```conf
# appendfsync always    # 每条命令都 fsync（最安全，最慢）
appendfsync everysec    # 每秒 fsync 一次（推荐，折中）
# appendfsync no        # 由操作系统决定刷盘时机（最快，最不安全）
```

三种策略对比：

| 策略 | 丢失数据 | 写性能 | 适用场景 |
|------|---------|--------|---------|
| always | 最多 1 条命令 | 最慢（约 10000 ops/s） | 金融、数据不能丢 |
| everysec | 最多 1 秒内的数据 | 中等（约 100000 ops/s） | **绝大多数生产场景** |
| no | 可能丢失多个时间窗口 | 最快 | 能容忍大量丢失的场景 |

### 3.3 AOF 重写（Rewrite）

随着时间推移，AOF 文件会越来越大。例如对一个 key 做了 1000 次 INCR，AOF 中会有 1000 行命令，但恢复时只需要 `SET key 1000` 这一条。

**AOF 重写机制**：用最小的命令集合重新描述当前内存中的数据。

```
重写前 AOF（1000 条 INCR 命令）：
INCR counter
INCR counter
INCR counter
... （997 条省略）
INCR counter

重写后 AOF（1 条命令 + 其他 key）：
*3\r\n$3\r\nSET\r\n$7\r\ncounter\r\n$4\r\n1000\r\n
...（其他 key 的 SET 命令）
```

**重写过程**（BGREWRITEAOF）：

```
Redis 主进程
    │
    ├─▶ fork() 创建子进程
    │
    ├─▶ 子进程开始写新 AOF 文件（基于 fork 时的内存快照）
    │    逐 key 生成 SET 命令
    │
    ├─▶ 同时，父进程将增量命令写入 AOF 重写缓冲区（aof_rewrite_buf）
    │
    ├─▶ 子进程写完新 AOF → 通知父进程
    │
    ├─▶ 父进程将重写缓冲区的增量命令追加到新 AOF
    │
    └─▶ rename(2) 新 AOF 覆盖旧 AOF
```

**重写触发条件**：

```conf
auto-aof-rewrite-percentage 100    # AOF 文件比上次重写时增长了 100%
auto-aof-rewrite-min-size 64mb     # AOF 文件至少 64MB 才触发
```

### 3.4 AOF 的优缺点

| 优点 | 缺点 |
|------|------|
| 数据丢失少（everysec 最多丢 1 秒） | AOF 文件比 RDB 大 |
| AOF 文件可读、可编辑 | 恢复速度比 RDB 慢 |
| 支持增量备份 | 写性能受 fsync 策略影响 |
| 重写机制控制文件大小 | 重写期间可能会有性能抖动 |

---

## 四、混合持久化（Redis 4.0+）

这是面试中的**加分项**。

### 4.1 为什么要混合？

- **RDB 恢复快**，但丢失数据多
- **AOF 丢数据少**，但恢复慢
- **混合持久化** = 兼具两者的优点

### 4.2 工作原理

```conf
# 开启混合持久化
aof-use-rdb-preamble yes
```

在 AOF 重写时，新 AOF 文件的前半部分是 **RDB 格式的快照**，后半部分是重写期间的**增量 AOF 命令**：

```
┌─────────────────────────────────────┐
│  RDB 格式的快照数据（紧凑，加载快）    │  ← 新的 RDB 格式
│  ┌───────────────────────────────┐  │
│  │ REDIS0009 │ DB 数据 │ CRC64  │  │
│  └───────────────────────────────┘  │
├─────────────────────────────────────┤
│  AOF 格式的增量命令（精确到秒级）     │  ← 重写缓冲区内容
│  SET user:1 "abc"                   │
│  INCR views                         │
│  ...                                │
└─────────────────────────────────────┘
```

恢复时：
1. Redis 先解析 RDB 部分，直接载入内存（极快）
2. 然后执行 AOF 部分的增量命令，补全重写期间的数据变化

---

## 五、RDB vs AOF 深度对比

| 维度 | RDB | AOF | 混合（Redis 4+） |
|------|-----|-----|------------------|
| **数据完整性** | 丢失最后 1 次快照后的所有数据 | everysec 丢 1s，always 丢 0 条 | everysec 丢 1s，恢复更快 |
| **文件大小** | 小（压缩） | 大（命令原文） | 中等（RDB + 少量 AOF） |
| **恢复速度** | ⚡ 非常快 | 🐢 慢（逐条执行命令） | ⚡ 快（RDB 部分直接加载） |
| **fork 开销** | 快照时有 | 重写时有 | 重写时有 |
| **CPU 影响** | 快照时高（压缩） | 写频繁时高（fsync） | 同 AOF |
| **内存影响** | COW 可能翻倍 | 基本无（重写时 COW） | 同 RDB |
| **可读性** | 二进制不可读 | 纯文本可读 | 混合不可直接读 |
| **适用场景** | 备份、灾难恢复 | 生产环境数据安全 | **现代 Redis 推荐** |

---

## 六、生产环境最佳实践

### 6.1 推荐配置

```conf
# ---------- RDB 配置（做备份用）----------
save 900 1
save 300 10
save 60 10000
rdbcompression yes                    # 开启 LZF 压缩
rdbchecksum yes                       # 开启 CRC64 校验
dbfilename dump.rdb

# ---------- AOF 配置（保证数据安全）----------
appendonly yes                        # 开启 AOF
appendfilename "appendonly.aof"
appendfsync everysec                  # 每秒刷盘（最佳折中）
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes                # 允许加载截断的 AOF（重启不崩）
aof-use-rdb-preamble yes              # 开启混合持久化（Redis 4.0+）

# ---------- 大数据实例调优 ----------
# 如果实例 > 30GB，调大重写缓冲区限制
repl-backlog-size 256mb

# 关闭 RDB 如果不需要（纯 AOF 场景）
# save ""
```

### 6.2 备份策略

```bash
# 1. 每天凌晨 RDB 备份到远程
0 3 * * * cp /data/redis/dump.rdb /backup/redis/$(date +\%Y\%m\%d)-dump.rdb

# 2. 备份 AOF 文件（重写后复制）
0 4 * * * cp /data/redis/appendonly.aof /backup/redis/$(date +\%Y\%m\%d)-appendonly.aof

# 3. 安全建议：同步到另外一台机器的对象存储（OSS/S3）
```

### 6.3 数据恢复流程

```bash
# 场景：Redis 宕机，手动恢复

# 1. 停止 Redis
redis-cli shutdown

# 2. 选择恢复源
# 优先使用 AOF（数据更新）或混合持久化文件
ls -la /data/redis/
# 确认 appendonly.aof 或 dump.rdb

# 3. 如果需要使用旧 RDB + AOF 恢复
#    确保配置为 appendonly yes，启动时会自动加载 AOF

# 4. 启动 Redis
redis-server /etc/redis/redis.conf

# 5. 检查数据完整性
redis-cli --bigkeys
redis-cli INFO keyspace

# 6. 验证关键数据
redis-cli GET important:key
```

### 6.4 监控指标

```bash
# 关键监控指标
redis-cli INFO Persistence

# 重点关注
# rdb_last_save_time：最后一次 RDB 保存时间
# rdb_bgsave_in_progress：RDB 是否正在执行
# aof_enabled：AOF 是否开启
# aof_last_rewrite_time_sec：最近一次重写耗时
# aof_current_size：当前 AOF 文件大小
# aof_base_size：AOF 重写的基准大小
```

---

## 七、面试高频追问

**Q1：RDB 和 AOF 能不能同时开启？**

> 可以。Redis 4.0 之前，AOF 优先用于恢复（数据更完整）。Redis 4.0+ 开启混合持久化后，AOF 文件本身就是 RDB + AOF 的混合体，恢复了 RDB 的快速加载能力。

**Q2：BGSAVE 执行过程中 Redis 挂了会怎样？**

> - 子进程写的是临时文件，如果子进程挂了，临时文件被删除，数据不受影响
> - 如果父进程挂了，子进程变成孤儿进程，等它写完临时文件后会被 Redis 启动时的逻辑正确加载（如果临时文件存在且完整）
> - 但更常见的情况是：挂了→重启→从磁盘加载 RDB/AOF 恢复

**Q3：为什么 AOF 恢复比 RDB 慢？**

> RDB 是序列化的二进制数据，直接载入内存即可。AOF 需要逐条重新执行命令，包括各类型数据结构的构建过程（例如 ziplist→skiplist 转换），速度自然慢。混合持久化用 RDB 做基础载荷，就解决了这个问题。

**Q4：AOF always 为什么这么慢？**

> fsync 是同步系统调用，需要等待磁盘 IO 完成才返回。即使 SSD 的 fsync 也需要几十微秒到几毫秒，而纯内存操作是亚微秒级。所以 always 策略下，Redis 的写吞吐会被磁盘 IOPS 限制，通常只有 1-2 万 QPS。

**Q5：RDB 持久化时对内存的使用有什么影响？**

> fork() 时复制页表需要与内存大小成正比的额外内存。COW 机制下，如果写操作密集，父进程需要复制修改的内存页，可能导致内存使用量飙升到接近 2 倍。建议给 Redis 实例预留 50% 的额外内存用于应对 BGSAVE/BGREWRITEAOF。

---

## 八、总结

| 场景 | 推荐持久化方式 |
|------|--------------|
| 纯缓存（数据可丢失） | 仅 RDB 或关持久化 |
| 常规业务系统 | AOF everysec + RDB + 混合持久化 |
| 金融级数据安全 | AOF always + RDB 定期备份 |
| 大实例（> 50GB） | AOF everysec + 调大 rewrite 间隔 |
| 用作消息队列 | AOF everysec + 混合持久化 |

**一句话总结**：生产环境推荐 **AOF everysec + 混合持久化 + RDB 定期备份**，兼顾数据安全、恢复速度和运维可靠性。
