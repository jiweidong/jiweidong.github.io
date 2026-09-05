---
title: 【Redis 原理】Redis 主从复制深度解析：从全量同步、增量同步到 psync2 断线续传与复制安全
date: 2026-09-05 08:00:00
tags:
  - Redis
  - 缓存
  - 高可用
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Redis 原理】Redis 主从复制深度解析：从全量同步、增量同步到 psync2 断线续传与复制安全

## 面试官：你们 Redis 集群是怎么搭的？从节点数据从哪来？

"主从复制啊，主节点写，从节点同步数据，读写分离扛读流量……"——很多人能说出这句话，但再往下追问就卡壳了：

- 主从之间**第一次**怎么同步的？是全量还是增量？
- 从节点**断线重连**后，是全量重来还是接着同步？
- 主从切换后，**新主**的从节点要全量同步吗？
- `replid`、`repl_backlog`、`PSYNC`、`offset` 这些到底是什么？

Redis 主从复制是哨兵、Cluster 高可用的地基，也是面试的高频深水区。今天从命令到源码，把它彻底拆开。

## 一、先搭一个主从，看现象

```bash
# 主节点：6379
redis-server --port 6379

# 从节点：6380，指向主节点
redis-server --port 6380 --replicaof 127.0.0.1 6379
```

或者运行时用命令：

```bash
# 在 6380 上执行
127.0.0.1:6380> REPLICAOF 127.0.0.1 6379
OK
127.0.0.1:6380> INFO replication
# Replication
role:slave
master_host:127.0.0.1
master_link_status:up
slave_repl_offset:1234
```

主节点上能看到从节点信息：

```bash
127.0.0.1:6379> INFO replication
# Replication
role:master
connected_slaves:1
slave0:ip=127.0.0.1,port=6380,state=online,offset=1234,lag=0
```

**验证同步**：主节点 `SET foo bar`，从节点立刻能 `GET foo`。写主读从，读写分离的第一步就成了。

## 二、主从复制的完整流程（核心！）

一次从节点上线，背后经历了 **6 个阶段**：

### 阶段 1：保存主节点信息

从节点执行 `REPLICAOF` 后，只是把主节点地址**保存在内存**（`server.masterhost/masterport`），此时并没有建立连接，也没开始同步。

### 阶段 2：建立 TCP 连接

从节点有个**定时任务**（每秒执行一次 `replicationCron`），发现配置了主节点但没连上，就发起 TCP 连接，并专门开一个 socket 用于接收主节点推送的写命令。注意：这个 socket 是**独立的**，不占从节点处理客户端命令的连接。

### 阶段 3：发送 PING

连接建立后，从节点先发 `PING` 探活。如果主节点没响应或超时，从节点断开重连。这一步能提前发现网络问题，避免后面同步到一半失败。

### 阶段 4：身份校验

如果主节点配置了 `requirepass`，从节点需要配置 `masterauth`。校验通过才继续，否则断开。

### 阶段 5：发送 PSYNC，开始同步（关键！）

从节点发送：

```
PSYNC <replid> <offset>
```

这里分两种情况，先记住结论，后面细讲：
- **首次同步**：从节点还没有任何复制历史，发送 `PSYNC ? -1`，主节点决定做**全量同步**（FULLRESYNC）；
- **断线重连**：从节点带上自己之前的 `replid` 和复制偏移量 `offset`，主节点判断能不能**增量续传**（CONTINUE），能则只补差距数据。

### 阶段 6：命令传播

同步完成后进入**增量复制**阶段：主节点每执行一条写命令，都会把命令**写入复制缓冲区并推送给所有从节点**。从节点执行同样的命令，保持数据一致。

## 三、全量同步（FULLRESYNC）到底传了什么？

很多人以为全量同步就是"主节点把 RDB 文件发给从节点"，其实完整过程是 **RDB 快照 + 缓冲区命令补发** 的组合，缺一不可。看时序：

```
从节点                    主节点
  |  PSYNC ? -1             |
  |------------------------>|
  |  处理：执行 BGSAVE 生成 RDB
  |  同时：把 BGSAVE 期间的新写命令
  |        存入复制缓冲区 repl_backlog
  |<------- FULLRESYNC <replid> <offset>
  |  RDB 文件流式传输       |
  |<========================|
  |  清空旧数据，加载 RDB    |
  |  发送 ACK               |
  |------------------------>|
  |  补发缓冲区中的命令      |
  |<========================|  （从 BGSAVE 到 RDB 加载完
  |                          |    之间的写命令都在这）
```

**为什么要补发缓冲区命令？** 因为 `BGSAVE` 生成 RDB 需要时间（大实例可能几十秒），这期间主节点还在持续接收写命令。如果只传 RDB，从节点加载完的瞬间就已经落后了。所以 Redis 把 BGSAVE 开始后的写命令同时写进 `repl_backlog` 缓冲区，RDB 传完后再把缓冲区命令补发给从节点，保证**从节点状态 = 主节点开始 BGSAVE 时刻之后的所有变更**。

### 3.1 从节点加载 RDB 时还能服务吗？

默认**不能**。Redis 从节点加载 RDB 期间会阻塞，不响应客户端命令（这是从节点短暂的不可用窗口，大实例要格外注意）。加载完成后才恢复服务并开始接收增量命令。

### 3.2 全量同步的几个开销（面试加分点）

| 开销 | 说明 |
|------|------|
| 主节点 BGSAVE fork | fork 会阻塞主进程（毫秒级），且 Copy-On-Write 可能让内存翻倍式增长 |
| RDB 传输带宽 | 大实例 RDB 几个 GB，传输占满内网带宽，可能拖慢主节点正常服务 |
| 从节点清空+加载 | 旧数据全清，加载期间阻塞 |
| 级联同步 | 多个从节点同时全量，主节点要 fork 多次 → **用树状拓扑**缓解 |

**优化手段**：`repl-diskless-sync yes`（无盘复制：主节点不落盘，直接 socket 流式传 RDB）；多个从节点**错峰**上线，避免同时触发全量。

## 四、断线重连：psync 与增量续传

### 4.1 老版本 SYNC 的痛点

Redis 2.8 之前只有 `SYNC` 命令：从节点只要断线重连，主节点就**无条件全量同步**。频繁断线 = 频繁全量 = 主节点反复 fork、带宽反复打满。

### 4.2 PSYNC 的增量续传

Redis 2.8 引入 `PSYNC`：主节点维护一个**复制积压缓冲区 `repl_backlog`**（默认 1MB，环形），记录自己执行过的写命令和对应偏移量。从节点重连时带上自己的 `replid` 和 `offset`：

```
PSYNC <replid> <offset>
```

主节点判断：
- `replid` 匹配 且 `offset` 之后的数据还在 `repl_backlog` 里 → 回复 `CONTINUE`，**只补发缺失的命令**（增量同步）；
- `replid` 不匹配 或 offset 太旧、数据已被环形缓冲区覆盖 → 回复 `FULLRESYNC`，退回全量。

```bash
# 从节点断线 10 秒重连后
master_link_status:up
master_sync_in_progress:0          # 没有进行全量同步
slave_repl_offset:2048             # offset 连续增长
```

**面试追问：repl_backlog 调多大？** 太小 → 从节点断线稍久就追不上，被迫全量；太大 → 浪费内存。经验：`repl_backlog_size = 主节点每秒写命令量 × 期望容忍的断线秒数`，一般 64MB~256MB 起步，再按 `master_repl_offset - slave_repl_offset` 的监控值动态调。

### 4.3 psync2：主从切换不再全量（Redis 4.0）

4.0 之前有个大坑：主从切换后，**新主**（原从）的 `replid` 变了，其他从节点来同步时 replid 不匹配 → 全部被迫**全量同步**。切换一次，集群抖动一次。

4.0 的 `psync2` 解决了它：

- 主从复制时，**从节点会记住主的 replid**（`server.replid` 会传给从，从节点把它存为 `master_replid`，切换成主时沿用）；
- 主从切换时，新主**继承原主的 replid**（`replid` 不变，`replid2` 记录旧值用于容错）；
- 其他从节点用旧 replid + offset 来同步，新主发现数据还在 backlog 里 → `CONTINUE`，增量续传，**避免全量**。

```bash
# 切换后的新主 INFO replication
replid:1a2b3c...     # 沿用原主 replid
replid2:0000000000000000000000000000000000000000
```

### 4.4 replid 和 replid2 到底是啥？

- **replid**：当前实例的复制 ID，标识"我这条复制链路的历史"。主从一致时，从节点的 replid 与主节点相同（表示"我来自这条主线"）。实例第一次成为主（或执行 `REPLICAOF no one` 且没有继承）时生成新的 replid。
- **replid2**：记录**上一个** replid，用于主从切换后的容错——让"旧主线"的从节点还能通过旧 replid 找到自己（走增量而不是全量）。

一个从节点全量同步完成后，主节点会发来自己的 replid，从节点存下来。断线重连时用这个 replid 发 PSYNC，主节点比对一致才允许增量。

## 五、主从复制下的几个经典"坑"（面试高频）

### 5.1 主从数据不一致是必然的！

复制是**异步**的：主节点执行完写命令就返回客户端，命令推送到从节点有网络延迟。所以：
- **强一致场景不能读从库**（刚写完就读从库可能读不到）；
- 缓解：`WAIT numreplicas timeout` 命令可以让主节点等待指定数量的从节点确认后再返回（牺牲可用性换一致性，用得很少）；
- 监控：`master_repl_offset`（主）与 `slave_repl_offset`（从）的差就是复制延迟，Lag 告警就盯它。

### 5.2 从节点会执行过期键删除吗？

会，但**策略不同**：主节点删除过期键时会**显式发送 DEL 命令**给从节点，从节点"听命令"删除；从节点自己**不会主动惰性删除或定期删除**过期键（避免主从删除时机不一致）。所以从节点上可能短暂读到"逻辑上已过期"的键——直到主节点的 DEL 到达。这也是读写分离下缓存不一致的一个隐蔽来源。

### 5.3 从节点只读，但别忘了这两个例外

从节点默认 `replica-read-only yes`，但要注意：从节点**可以**执行 `FLUSHALL`、`SHUTDOWN` 这类管理命令（需要权限的人为操作）；另外如果配置了 `replica-read-only no`，从节点本地写入的数据在**下次全量同步时会被清掉**，别拿从节点当临时存储。

### 5.4 全量同步期间主节点挂了怎么办？

从节点正在接收 RDB 时主节点宕机 → 从节点会**周期性重试**（`repl-timeout` 默认 60s 内没收到数据就判定超时），重新发起 PSYNC。如果此时已经有哨兵在选主，从节点可能先完成重新同步、再响应哨兵的选举，逻辑上要小心处理"同步中不接受成为主节点"的竞态——哨兵协议里从节点在 `SLAVE_OF` 切换时如果正处于全量同步，会推迟应答。

### 5.5 从节点能写吗？为什么从节点挂了对主节点没影响？

从节点挂了，主节点只在 `INFO replication` 里把它标记为 `state:disconnected`，**继续正常服务**，不会阻塞写。这也是主从复制"高可用读、弱可用写"的定位——写的高可用要靠**哨兵**把从节点提升为主，或者 **Cluster** 的分片容错。

## 六、复制安全与一致性细节

### 6.1 认证与加密

- 主节点 `requirepass`，从节点必须配 `masterauth`（**密码明文会出现在配置里，用 `redis-cli` 的 `CONFIG SET` 或密钥管理注入**）；
- 跨机房复制建议走 **TLS**（`tls-replication yes`）；
- `rename-command` 可以禁用从节点上的危险命令。

### 6.2 复制拓扑怎么设计？

```
      [Master]
      /  |  \
 [S1] [S2] [S3]        ← 星型：S3 全量时 Master fork 三次
      |
     [S4]               ← 树型：S4 从 S3 同步，减轻 Master 压力
```

- 从节点少于 10 个：星型即可；
- 大量从节点/跨机房：树型级联，从节点 `REPLICAOF` 另一个从节点；
- 读流量大：读写分离 + 多从节点 + 客户端侧路由（或 Proxy）；
- 注意级联从节点的延迟会**逐级累加**。

### 6.3 怎么监控复制健康？

```bash
redis-cli -p 6379 INFO replication    # offset、lag、connected_slaves
redis-cli -p 6380 INFO replication    # master_link_status、master_sync_in_progress
```

关键指标：`master_link_status:up`、`slave_repl_offset` 追平速度、`master_sync_in_progress:0`（长时间为 1 说明全量同步卡住）、`lag`（心跳间隔，过大说明网络异常）。接入 Prometheus 的 redis_exporter 后，这几个指标直接配告警：lag > 阈值、link 断开、全量同步超过 N 分钟。

## 七、一图流总结 + 面试话术

```
主从复制 = 全量同步（首次/RDB 兜底） + 增量同步（命令传播）
         + psync 断点续传（repl_backlog 兜底）
         + psync2 主从切换免全量（replid 继承）

关键命令：REPLICAOF / PSYNC <replid> <offset> / FULLRESYNC / CONTINUE
关键配置：repl-backlog-size、repl-diskless-sync、masterauth、replica-read-only
```

**面试话术模板**：Redis 主从复制分全量与增量两个阶段。首次同步走全量：从节点发 `PSYNC ? -1`，主节点 `BGSAVE` 生成 RDB 并同时把新写命令缓存进 repl_backlog，RDB 传完后从节点加载，主节点再补发缓冲命令。之后进入命令传播的增量阶段。从节点断线重连时发 `PSYNC <replid> <offset>`，如果 offset 还在主节点的复制积压缓冲区内就 `CONTINUE` 增量续传，否则退化为全量。4.0 的 psync2 让主从切换后新主沿用旧 replid，其他从节点可以增量续传而不用全量。复制是异步的，所以读写分离有延迟窗口，强一致场景不能读从库。

主从复制只是 Redis 高可用的第一步——它解决了"读的扩展"，写节点还是单点。下一篇可以接着聊哨兵（Sentinel）是怎么在主节点宕机时自动完成故障转移的，或者 Cluster 怎么把写也分片出去的。地基打牢了，上层建筑才稳。
