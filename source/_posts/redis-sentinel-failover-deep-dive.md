---
title: 【Redis 原理】Redis Sentinel 哨兵深度解析：主观下线、客观下线与自动故障转移完整机制
date: 2026-09-08 08:00:00
tags:
  - Redis
  - 高可用
  - 哨兵
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Redis 原理】Redis Sentinel 哨兵深度解析：主观下线、客观下线与自动故障转移完整机制

## 面试官：主从复制模式下主节点挂了怎么办？Sentinel 是怎么发现并完成切换的？

主从复制解决了读扩展，但**主节点宕机后，从节点不会自动升级**——写服务就断了。Redis Sentinel（哨兵）就是来解决这个问题的：**监控 + 通知 + 自动故障转移**。它是 Redis 高可用架构里承上启下的一环（上承主从、下接 Cluster），面试必考。

本文把 Sentinel 的三个定时任务、主观下线（SDOWN）、客观下线（ODOWN）、Leader 选举、故障转移完整流程讲透，最后给出生产配置与脑裂防护。

---

## 一、Sentinel 是什么？解决了什么问题？

Sentinel 是一个**独立运行的 Redis 特殊进程**，不存储业务数据。它做四件事：

| 职责 | 说明 |
|------|------|
| 监控（Monitoring） | 持续检查主从节点是否存活 |
| 通知（Notification） | 节点异常时通过 API 通知运维/应用 |
| 自动故障转移（Automatic failover） | 主节点挂了，从从节点中选举新主并完成切换 |
| 配置提供者（Configuration provider） | 客户端通过 Sentinel 获取当前主节点地址 |

架构特点：

- **Sentinel 本身要部署成集群**（至少 3 个实例，奇数），避免 Sentinel 单点；
- Sentinel 之间相互通信、对主节点状态**投票表决**，防止误判；
- 客户端（如 Jedis/Lettuce）先连 Sentinel，再通过 `sentinel get-master-addr-by-name` 拿到真实主节点。

```
                     ┌──────────────┐
     客户端 ────────► │ Sentinel 集群 │  (3个哨兵互相监督)
                     └──────┬───────┘
                            │ 监控/投票/切换
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        ┌──────────┐   ┌──────────┐  ┌──────────┐
        │ Master   │◄──│ Slave-1  │  │ Slave-2  │
        └──────────┘   └──────────┘  └──────────┘
```

---

## 二、三个定时任务：Sentinel 的日常

每个 Sentinel 实例内部维护三个周期性任务（源码在 `sentinel.c`），这是理解一切的起点：

### 任务 1：每 10 秒向主从节点发 INFO 命令

目的：**发现新节点、更新拓扑**。INFO 返回里包含 `run_id`、`role`、`slave0/1...` 等字段，Sentinel 据此：

- 发现主节点下新挂的从节点，加入监控列表；
- 感知从节点的复制偏移量（后面选主要用）；
- 感知从节点提升为主节点（角色变化）。

### 任务 2：每 2 秒向 `__sentinel__:hello` 频道发布消息

每个 Sentinel 把自己的**地址、runid、对主节点的看法（当前 epoch + 是否认为主节点下线）**发布到这个频道，同时订阅该频道接收其他 Sentinel 的广播。作用：

- 交换彼此对主节点状态的判断；
- 发现新的 Sentinel 节点（自动加入集群）；
- **为后续 ODOWN 投票与 Leader 选举传递信息**。

### 任务 3：每 1 秒向所有实例（主、从、其他哨兵）发 PING

这是**心跳检测**，判断节点是否存活，是主观下线的依据。

> 面试可背的框架：Sentinel 通过「INFO 建拓扑、Pub/Sub 通消息、PING 探活」三个定时任务维持对整个主从体系的感知。

---

## 三、主观下线（SDOWN）与客观下线（ODOWN）

### 3.1 主观下线 Subjective Down

Sentinel 每 1 秒 PING 一次实例。如果**在 `down-after-milliseconds` 配置时间内没有收到有效回复**（PONG/LOADING/MASTERDOWN 之外的回复），该 Sentinel 就把这个实例标记为**主观下线**，实例状态置为 `SRI_S_DOWN`。

注意关键词「主观」：这只是**这一个 Sentinel 自己的判断**，可能因为网络抖动误判。所以 Redis 设计了客观下线机制来纠偏。

### 3.2 客观下线 Objective Down

**只有主节点**才存在客观下线流程（从节点和哨兵主观下线就够了）：

1. 某 Sentinel 主观判定主节点下线后，向其他 Sentinel 发送命令：
   ```
   SENTINEL is-master-down-by-addr <ip> <port> <current_epoch> <runid>
   ```
2. 其他 Sentinel 根据自己的 PING 结果回复「是/否认为主节点已下线」。
3. 发起者统计回复，**当确认下线的 Sentinel 数量 ≥ 配置的 quorum**（如 `sentinel monitor mymaster 127.0.0.1 6379 2` 中的 2），就将主节点标记为**客观下线** `SRI_O_DOWN`，进入故障转移流程。

```
Sentinel A: 我认为 master 挂了 (SDOWN)
   │ 广播 is-master-down-by-addr
   ▼
Sentinel B: 我也认为挂了 ✓
Sentinel C: 我认为还活着 ✗
   │
   └─ 确认数(2) ≥ quorum(2) → ODOWN，开始故障转移
```

> quorum 只用于判定「是否客观下线」，**不代表实际执行切换的票数**——切换由后面选举出的 Leader Sentinel 执行。

---

## 四、Leader 选举：谁来做故障转移？

主节点被判定 ODOWN 后，需要选出一个 **Leader Sentinel** 来执行故障转移。选举机制模仿 Raft：

1. 每个发现 ODOWN 的 Sentinel 都会**自荐**成为 Leader：向其他 Sentinel 发送 `is-master-down-by-addr`，带上自己的 runid 和一个**自增的 configuration epoch（配置纪元）**，相当于竞选宣言。
2. 其他 Sentinel 收到竞选请求后，**在同一个 epoch 内只能投一票**（先到先得），把票投给第一个请求者。
3. 竞选者统计收到的票数，**超过半数（> Sentinel 总数/2）即当选 Leader**。
4. 如果本轮无人过半（票数分散），随机等待后进入**下一个 epoch 重新选举**。

关键设计点：

- **epoch 机制**：每次故障转移对应一个递增的配置纪元，用于标识「这次切换」的唯一性，避免不同 Sentinel 各自为政产生多个新主（脑裂防护之一）。客户端和从节点都认 epoch 最大的配置。
- 选举的是「执行者」，而不是「新主节点」——选主是 Leader 接下来的工作。

---

## 五、故障转移：完整切换流程

Leader Sentinel 选出后，执行以下步骤：

### Step 1：从从节点中筛选出候选池

过滤掉不合格的从节点：

- 断线超过一定时间的（主观下线或与主节点断开超过阈值）；
- 最近没跟主节点同步过的（**复制偏移量落后太多**，数据太旧）；
- 优先级 `replica-priority` 为 0 的（**0 表示永远不参与选举**，可用来指定某些从节点只做灾备）。

### Step 2：对候选从节点排序，选出新主

排序规则依次比较（优先级高者胜出）：

1. **`replica-priority` 越小越优先**（默认 100，可手动给机器配置高的从节点设小值）；
2. 优先级相同，**复制偏移量（slave_repl_offset）越大越优先**——谁的数据最接近旧主谁上；
3. 再相同，**runid 字典序小的优先**（纯兜底随机性）。

### Step 3：执行切换

1. 向选中的从节点发送 `SLAVEOF NO ONE`，让它**变为主节点**，停止复制；
2. 短暂等待（`slave-promotion-innodb` 类似机制，实际是等它完成角色切换），确认新主可写；
3. 向其他从节点发送 `SLAVEOF <新主ip> <新主port>`，让它们**改换门庭**复制新主；
4. **更新自身的配置**：把旧主地址替换成新主，epoch +1，并通过 `__sentinel__:hello` 频道广播新拓扑；
5. 旧主如果恢复，Sentinel 发现它回来后，会把它降级为从节点并指向新主复制（旧主已被标记，通过 `SLAVEOF` 重新纳入）。

### Step 4：通知客户端

Sentinel 不主动推消息给业务客户端（除非客户端订阅了 `+switch-master` 频道），主流客户端（Jedis/Lettuce）的 Sentinel 模式会：

- 启动时通过 `sentinel get-master-addr-by-name` 获取主节点；
- 运行时若连接失败，重新向 Sentinel 拉取最新主节点地址。

所以**客户端配置里连的是 Sentinel 地址列表，而不是主节点地址**。

---

## 六、生产配置与脑裂防护

### 6.1 最小生产配置

```conf
# sentinel.conf
port 26379
# 监控主节点：名称 mymaster，地址 127.0.0.1:6379，quorum=2（需2个哨兵确认才判定客观下线）
sentinel monitor mymaster 127.0.0.1 6379 2
# 主观下线判定时间：10秒没响应即认为主观下线
sentinel down-after-milliseconds mymaster 10000
# 故障转移后，同时命令多少个从节点同步新主（避免全量同步风暴）
sentinel parallel-syncs mymaster 1
# 故障转移超时时间
sentinel failover-timeout mymaster 180000
# 主节点至少要能连上1个从节点才接受写入（脑裂防护）
sentinel min-replicas-to-write mymaster 1
# 从节点数据延迟超过10秒，主节点拒绝写入
sentinel min-replicas-max-lag mymaster 10
```

> 注意：老版本配置项是 `min-slaves-to-write` / `min-slaves-max-lag`，Redis 5+ 更名为 `min-replicas-*`。

### 6.2 脑裂问题与 min-replicas 防护

**脑裂场景**：主节点与从节点/Sentinel 网络分区，但主节点本身还活着，客户端继续向它写数据；此时 Sentinel 判定主节点 ODOWN 并切换出新主，分区恢复后旧主降级为从节点——**分区期间的写入全部丢失**。

**防护方案**：`min-replicas-to-write 1` + `min-replicas-max-lag 10` 组合拳：

- 主节点发现**能联系的从节点少于 1 个**，或从节点数据延迟超过 10 秒，就**拒绝写入**（返回错误）；
- 网络分区时旧主联系不上从节点 → 写请求被拒 → 数据不会产生「分区期间的新写入」→ 切换后无丢失。

代价是**牺牲可用性换一致性**：极端情况下主节点会短暂拒绝写入，需要业务侧权衡（写降级 + 告警）。

---

## 七、Sentinel vs Cluster，怎么选？

| 维度 | Sentinel | Redis Cluster |
|------|----------|---------------|
| 数据分片 | 不分片，所有节点全量数据 | 16384 个槽自动分片 |
| 容量扩展 | 靠从节点读扩展，写不扩展 | 在线扩缩容，读写都可扩展 |
| 故障转移 | Sentinel 投票选主 | 集群内部 Gossip + 投票 |
| 客户端复杂度 | 连 Sentinel 获取主地址 | 直连任意节点，Moved/Ask 重定向 |
| 适用规模 | 缓存小规模、读多写少、已有主从 | 大规模数据、需要水平扩展 |

**选型结论**：数据量在单机内存能装下（如几十 GB 内），用「主从 + Sentinel」最合适，架构简单、运维成本低；数据量超单机内存、要水平扩展，直接上 Cluster。

---

## 八、面试常见追问

**Q1：SDOWN 和 ODOWN 有什么区别？**
SDOWN 是单个 Sentinel 的主观判断（PING 超时）；ODOWN 只针对主节点，是多个 Sentinel（≥quorum）确认后的客观结论，是触发故障转移的前提。从节点/Sentinel 只有 SDOWN。

**Q2：quorum 设 2 代表需要 2 个哨兵同意才切换吗？**
不完全是。quorum 是判定 ODOWN 的门槛；真正执行切换前还要选 Leader，Leader 需要**超过半数** Sentinel 的选票。例如 5 个 Sentinel、quorum=3：需要 3 个确认 ODOWN，然后竞选 Leader 需要至少 3 票。

**Q3：新主是怎么选出来的？**
三层筛选：剔除断线/落后太多的从节点和 replica-priority=0 的；然后按 replica-priority 小 → 复制偏移量大 → runid 小的顺序排序，第一名当选。

**Q4：旧主恢复了会怎样？会数据冲突吗？**
旧主恢复后 Sentinel 发现它是旧主角色，会命令它 `SLAVEOF` 新主变成从节点，全量同步新主数据。因为旧主在分区期间的写入已被 min-replicas 机制挡住（或即使有写入也会被覆盖），最终以新主数据为准。

**Q5：Sentinel 自己挂了怎么办？**
Sentinel 是集群部署（奇数 ≥3），单个 Sentinel 挂掉不影响整体监控；只要存活 Sentinel 过半，就能正常完成 ODOWN 判定和 Leader 选举。Sentinel 全部挂掉则失去自动切换能力，但主从复制本身不受影响，读仍可用。

---

## 总结

Sentinel 的核心可以浓缩成一句话：**用三个定时任务维持感知（INFO/PubSub/PING），用 SDOWN→ODOWN 两级判定确认主节点死亡，用类 Raft 的 epoch 选举选出执行者，用「优先级+复制偏移量」选出新主，最后用 min-replicas 参数守住脑裂防线**。把这条链路讲清楚，Redis 高可用这块基本就过关了。
