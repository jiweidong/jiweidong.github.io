---
title: 【MySQL 高可用】MySQL 半同步复制深度解析：从异步复制丢数据到主从数据可靠性进阶
date: 2026-09-06 08:00:00
tags:
  - MySQL
  - 主从复制
  - 高可用
  - 半同步
categories:
  - 数据库
  - MySQL 高可用
author: 东哥
---

# 【MySQL 高可用】MySQL 半同步复制深度解析：从异步复制丢数据到主从数据可靠性进阶

## 一个真实的"事故"

凌晨 2 点，主库服务器硬件故障宕机。DBA 熟练地执行切换脚本，把流量切到从库——然后业务炸了：**最近 30 秒的订单全部消失**，用户投诉如潮。

复盘时发现：主从是**异步复制**，主库宕机那一刻，最新一批 binlog 还没来得及传给从库，主库就断电了。**提交成功的事务，就这么丢了。**

这就是异步复制的天然缺陷。怎么解决？今天的主角——**半同步复制（Semi-Synchronous Replication）**。

## 一、先搞清楚异步复制为什么丢数据

MySQL 默认的主从复制是**异步**的，完整链路：

```
主库: 客户端 -> SQL 层提交事务 -> 写 binlog(commit) -> 返回"提交成功"给客户端
                                         |
                                         v   (异步，不等待)
从库: IO 线程拉取 binlog -> 写入 relay log -> SQL 线程回放 -> 数据落地
```

关键点：**主库 commit 成功后就立刻应答客户端，根本不关心从库有没有收到 binlog**。于是存在一个"丢失窗口"：

- 窗口起点：事务写入 binlog 并 commit；
- 窗口终点：从库 IO 线程把该事务的 binlog 拉到本地。

窗口内主库宕机（且 binlog 未同步出去）→ 事务丢失。就算你开了 `sync_binlog=1`、`innodb_flush_log_at_trx_commit=1`（双 1），那也只是保证**主库本地**不丢，挡不住"主库没来得及把 binlog 发给从库"这个跨机问题。

## 二、半同步复制的核心思想

半同步复制的设计目标：**主库提交事务时，必须等到至少一个从库确认"我已经收到这个 binlog"，才向客户端返回成功**。

```
主库: 客户端 -> 写 binlog -> 等待从库 ACK（默认等1个）-> commit -> 返回成功
                                  ^
                                  |  （同步等待）
从库: IO 线程收到 binlog -> 写入 relay log -> 回 ACK 给主库 -> SQL 线程异步回放
```

与异步复制相比，多了一次**网络往返等待**；与"全同步"（如 MySQL Cluster NDB，所有节点都落盘才算成功）相比，它只要求"**收到并写入 relay log**"，不要求"已应用"——**从库回放仍然是异步的**。这是一个在性能与可靠性之间取的平衡点。

### 2.1 历史与形态

| 版本 | 形态 | 说明 |
|------|------|------|
| MySQL 5.5 | 半同步插件诞生 | `semisync_master.so` / `semisync_slave.so` |
| MySQL 5.7 | 增强半同步（after_sync） | 修复了 5.6 及之前的丢失窗口问题 |
| MySQL 8.0.26+ | 官方组件化 | `INSTALL COMPONENT 'file://component_semi_sync'` 替代插件方式，机制一致 |

### 2.2 关键参数 `rpl_semi_sync_master_wait_point`（5.7+）

这是理解半同步的核心，有两个取值：

**`AFTER_COMMIT`（5.5/5.6 时代的行为）**

```
1. 引擎层提交事务（commit）
2. 写 binlog
3. 等待从库 ACK  -> 此时事务对其他会话已经可见！
4. 返回客户端成功
```

问题：第 3 步等待期间，事务已提交、其他客户端可能已经读到这笔数据；如果此时主库宕机、从库恰好没收到 binlog，切换后这笔"已被别人读到的事务"就丢了——**数据一致性被破坏**（从库缺数据，且主库曾对外可见）。

**`AFTER_SYNC`（5.7 默认，增强半同步）**

```
1. 写 binlog
2. 等待从库 ACK（至少一个从库收到并写入 relay log）
3. 引擎层提交事务（commit）  -> 收到 ACK 之前，事务对其他会话不可见
4. 返回客户端成功
```

把"等待 ACK"挪到"引擎提交"**之前**：主库在收到 ACK 前不会提交事务，因此不存在"已提交但从库没有"的不一致窗口。**只要客户端收到成功响应，就代表事务的 binlog 已经在至少一个从库手上**——这才是"半同步"真正的可靠性价值。

## 三、半同步的工作细节与"降级"机制

### 3.1 几个重要参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `rpl_semi_sync_master_enabled` | OFF | 主库开启半同步 |
| `rpl_semi_sync_slave_enabled` | OFF | 从库开启半同步 |
| `rpl_semi_sync_master_timeout` | 10000ms | 等待 ACK 超时时间 |
| `rpl_semi_sync_master_wait_for_slave_count` | 1 | 至少等几个从库 ACK |
| `rpl_semi_sync_master_wait_point` | AFTER_SYNC | 等待时机（5.7+） |

### 3.2 超时降级：半同步 -> 异步 -> 半同步

半同步不是"要么全有要么全无"：如果等待 ACK **超过 `rpl_semi_sync_master_timeout`**（比如从库全部宕机、或网络抖动），主库**自动降级为异步复制**继续服务，保证可用性；从库恢复后，主库检测到从库追上来，再自动切回半同步。

```sql
-- 查看当前是否处于半同步状态（ON/OFF）
SHOW STATUS LIKE 'Rpl_semi_sync_master_status';
-- 半同步成功应答的事务数 / 降级为异步的事务数
SHOW STATUS LIKE 'Rpl_semi_sync_master_yes_tx';
SHOW STATUS LIKE 'Rpl_semi_sync_master_no_tx';
```

**监控要点**：`Rpl_semi_sync_master_no_tx` 持续增长 = 长期处于降级状态，说明从库或网络有问题，需要告警介入。很多"半同步开了等于没开"的事故，就是降级了没人发现。

### 3.3 一主多从怎么等？

`rpl_semi_sync_master_wait_for_slave_count=1` 表示**只要任意一个从库 ACK 即可**（默认），不必等所有从库。这也是性能与可靠性的折中：等 N 个从库 ACK，可靠性更高，但主库提交延迟随 N 线性上升，且一个慢从库会拖垮全局。

## 四、部署实战（5.7 插件方式）

主库执行：

```sql
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_master_timeout = 3000;   -- 建议 3s 内，别太长
-- 确认生效
SHOW PLUGINS;  -- 看到 rpl_semi_sync_master 状态为 ACTIVE
```

从库执行：

```sql
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';
SET GLOBAL rpl_semi_sync_slave_enabled = 1;
STOP SLAVE IO_THREAD;   -- 重启 IO 线程让半同步生效
START SLAVE IO_THREAD;
```

持久化（写进 my.cnf，避免重启丢失）：

```ini
[mysqld]
plugin-load="rpl_semi_sync_master=semisync_master.so;rpl_semi_sync_slave=semisync_slave.so"
rpl_semi_sync_master_enabled=1
rpl_semi_sync_slave_enabled=1
rpl_semi_sync_master_timeout=3000
```

MySQL 8.0.26+ 推荐组件方式：

```sql
INSTALL COMPONENT 'file://component_semi_sync';
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_slave_enabled = 1;
```

验证是否真正生效：主库执行大事务时观察 `Rpl_semi_sync_master_status=ON`、`yes_tx` 增长；把从库停掉再提交事务，超过 timeout 后 `status` 会变 OFF（降级异步）。

## 五、性能影响与架构建议

半同步的本质是"**每个事务多一次主->从的往返 RTT**"（等待 ACK），对提交延迟的影响：

1. **延迟敏感**：跨机房部署时 RTT 可能 30~50ms，每次提交都等，TPS 直接崩。**半同步要求主从同机房/同城低延迟网络**；
2. **5.7 的 group commit 优化**：多个事务可以批量等待 ACK，摊薄了单事务开销，性能比 5.6 好很多；
3. **调优方向**：`timeout` 设短（如 1~3s）快速降级保可用性；`wait_for_slave_count` 保持 1；从库用 SSD + 大 `relay_log` 避免 IO 抖动导致频繁降级；
4. **别和异步从库混用想当然**：半同步只对"ACK 的那个从库"有意义，其他异步从库该丢还是丢。

架构建议：**半同步 + 一主一从（或一主多从但只等 1 个 ACK）+ 同机房部署**，是 MySQL 高可用方案里性价比最高的组合，也是 MHA、Orchestrator 等切换工具最常搭配的复制形态。

## 六、半同步的边界：它解决不了什么？

面试官最爱问："半同步是不是就零丢失了？"——**不是**，它的保证有明确边界：

1. **只保证"收到 relay log"，不保证"已应用"**：从库 ACK 时事务只写进了 relay log，SQL 线程回放是异步的。从库在回放前宕机，relay log 里的数据在从库恢复后仍会继续回放（relay log 是持久化的），但如果 relay log 本身损坏/丢失，依然会丢；
2. **降级窗口存在**：ACK 超时降级为异步期间，丢数据风险回到异步水平；
3. **主库自身"已提交但未及同步"的极端场景**：比如 `AFTER_SYNC` 下主库写完 binlog、从库也收到并 ACK，但主库在引擎 commit 前宕机——从库 relay log 里有这个事务，主库没提交。若从库被提升，这个事务会被应用（因为 binlog 里它是个完整事务），出现"从库比原主库多一个事务"的微妙不一致（需要通过 GTID 与原主库比对处理）；
4. **半同步管不了"逻辑错误"**：`DROP TABLE`、`UPDATE` 忘加 WHERE——复制是忠实的，错误也会被复制过去，这类问题要靠备份、延迟从库、binlog 闪回等方案兜底。

所以生产环境的完整姿势是：**半同步复制（缩短丢失窗口）+ 定期全量备份 + binlog 增量备份 + 切换预案演练**，四者缺一不可。半同步解决的是"物理故障导致的最新事务丢失"，而不是所有数据安全问题。

## 七、三种复制形态对比

| 维度 | 异步复制 | 半同步复制 | 组复制 MGR |
|------|---------|-----------|-----------|
| 主库应答时机 | commit 即应答 | 等 1+ 从库 ACK 后应答 | 多数派确认后提交 |
| 数据丢失风险 | 高（有窗口） | 低（基本消除常规窗口） | 极低（多数派协议） |
| 性能影响 | 无 | 每次事务 +1 RTT | 更高（Paxos 类协议开销） |
| 部署复杂度 | 低 | 低 | 高 |
| 自动故障转移 | 需外部工具 | 需外部工具 | 内置 |
| 适用场景 | 容忍丢失、追求性能 | **绝大多数生产主从** | 要求强一致的多节点 |

## 八、面试追问速答

**Q：为什么从库只要"写入 relay log"就 ACK，不等应用完？**
为了性能。等应用完意味着从库的 SQL 线程回放速度要跟主库一致，任何慢 SQL、大事务都会反压主库提交。半同步的定位是"防丢失"，不是"强一致读"——要读己之写、实时一致，请走主库或引入 MGR/中间件方案。

**Q：半同步下从库延迟还有意义吗？**
有。半同步只保证 relay log 层面不丢，从库**应用延迟**（SQL 线程落后）依然存在，读写分离场景照样可能读到旧数据，主从延迟监控一个都不能少。

**Q：切换时怎么选新主？**
优先选"ACK 过的从库"（它手上的 binlog 最全），配合 GTID 检查各从库的已执行位点，选 `Executed_Gtid_Set` 最新的从库提升，避免选到一个缺数据的从库造成二次丢失。

**Q：什么时候用全同步（NDB）或 MGR？**
金融级强一致、多个副本必须同时可读可写、且能接受更高延迟和复杂度时，考虑 MGR（MySQL 原生，基于 Paxos）；NDB Cluster 场景更小众。绝大多数互联网业务，**半同步 + 可靠的切换编排**已经足够。
