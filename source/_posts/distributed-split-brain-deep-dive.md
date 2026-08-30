---
title: 【分布式系统】脑裂（Split Brain）问题深度解析：ZooKeeper、Redis Sentinel、Elasticsearch 与 MySQL 主从的防脑裂机制
date: 2026-08-30 08:00:00
tags:
  - 分布式
  - 高可用
  - ZooKeeper
  - Redis
  - 系统设计
categories:
  - Java
  - 分布式
author: 东哥
---

# 【分布式系统】脑裂（Split Brain）问题深度解析：ZooKeeper、Redis Sentinel、Elasticsearch 与 MySQL 主从的防脑裂机制

## 面试官：什么是脑裂？为什么分布式系统里最怕脑裂？

**脑裂（Split Brain）** 是指一个集群因为网络分区（Network Partition），被切成了两个或多个「互相联系不上、但各自存活」的小团体，每个小团体都认为自己是集群的唯一主人，各自继续对外提供服务、各自做出决策。

> 用大白话说：一个大脑裂成了两个，两个「大脑」都觉得自己才是本体，于是开始各写各的账。

脑裂的可怕之处不在于「集群分开了」，而在于**分开之后双方都在写数据**，等网络恢复、双方重新合并时，数据已经互相矛盾，无法无损合并。

### 脑裂的两个经典危害场景

| 场景 | 危害 |
| --- | --- |
| 数据库主主 | 两个主库都接受写入，各自生成不同的 binlog，恢复后数据冲突，主键/唯一键直接爆掉 |
| 分布式锁 | 两个节点都认为自己持有锁，同时进入临界区，秒杀超卖、重复扣款随之而来 |
| 配置中心 | 两个「主」各自修改配置，客户端读到互相矛盾的结果 |
| 选主系统 | 出现两个 Leader，日志复制与提交序号错乱，数据一致性被彻底破坏 |

**面试追问：网络分区为什么一定会发生？**

因为分布式系统部署在不可靠的网络上：交换机故障、机架断电、光纤被挖断、GC 长暂停导致心跳超时……这些都会让节点之间的心跳长时间收不到。**注意：心跳超时 ≠ 对方宕机**，这可能只是网络问题，对方活得好好的——这正是脑裂的温床。

## 一、解决脑裂的通用思路：多数派（Quorum）与法定人数

所有防脑裂方案的底层，几乎都离不开**多数派原则（Majority/Quorum）**：

> 一个决策要被采纳，必须获得**超过半数**节点的同意（N/2 + 1）。

为什么「超过半数」能防脑裂？因为网络分区最多只能把集群切成**两个**互不相通的团体（更极端的切法更不可能出现两个以上的多数派）。两个团体中，**最多只有一个**能凑齐超过半数的节点。凑不齐多数派的那一方，就无权选主、无权提交数据——它只能「降级为从」或者「拒绝服务」。

这就是 CAP 理论里 CP 系统的核心动作：**用可用性换一致性**——小团体宁可不可用，也不能脑裂。

## 二、ZooKeeper：Quorum + ZAB 协议

### 2.1 半数机制

ZooKeeper 集群由奇数个节点组成（3、5、7……），写请求要提交，必须经过 **Leader 提出提案 → 超过半数 Follower 返回 ACK → Leader 提交** 的过程（ZAB 协议的原子广播阶段）。

网络分区发生时：

- 假设 5 节点 ZK，分成 3+2 两个区。
- 3 个节点的区能凑齐多数派（3 > 2.5），可以正常选出 Leader 并对外服务。
- 2 个节点的区凑不齐多数派，**无法选举 Leader**，对外表现为「连接被拒绝」或「只读」——它不会自己选一个 Leader 出来跟对面对着干。

### 2.2 新 Leader 的 epoch 机制

ZK 用 **epoch（任期/纪元）** 防止旧 Leader 复活后搞乱：

- 每个 Leader 都有一个递增的 epoch 编号。
- 分区恢复后，旧 Leader 如果还想提交提案，必须带上自己的 epoch；Follower 发现 epoch 小于当前 Leader 的 epoch，直接拒绝。
- 旧 Leader 在丢掉了 Leader 身份后，**即使网络恢复，也会主动降级为 Follower**。

```java
// 伪代码：ZAB 提案提交的多数派判定
class ZabProposal {
    long epoch;      // 当前 Leader 任期
    long zxid;       // 全局递增事务 ID，高 32 位是 epoch，低 32 位是序号
    byte[] data;
}

boolean canCommit(Proposal p, Set<Node> acks) {
    return acks.size() > clusterSize / 2;   // 多数派才允许提交
}
```

**面试追问：ZK 节点数为什么必须是奇数？**

- 防脑裂需要多数派，N 和 N+1（偶数）的多数派阈值可能相同：3 节点容错 1 台，4 节点同样只能容错 1 台（需要 3 票，3/4 > 2/4）。
- 4 节点分区成 2+2 时，**两边都凑不齐 3 票，集群整体不可用**——比 3 节点分区成 1+2（2 个节点的小团体还能服务）更差。
- 所以偶数节点只增加成本，不增加可用性，奇数才是性价比最优。

## 三、Redis Sentinel：quorum + majority

### 3.1 主观下线与客观下线

Sentinel 集群（通常 3 个 Sentinel）对 Redis 主节点做健康检查：

- **主观下线（sdown）**：单个 Sentinel 在 `down-after-milliseconds` 内没收到主节点的有效回复，它自己认为主节点挂了。
- **客观下线（odown）**：主观下线后，Sentinel 向其他 Sentinel 发起 `is-master-down-by-addr` 投票，**收到 quorum 个（可配置，通常也是多数派）确认**后，才判定客观下线，进入故障转移。

关键设计：**单台 Sentinel 说了不算，必须凑齐 quorum**——就是为了防止「这台 Sentinel 恰好网络抖动」造成的误判误切换。

### 3.2 故障转移的 majority 选举

确定客观下线后，Sentinel 们要**选出一个 Leader Sentinel** 来执行故障转移（把某个从节点提升为新主）。这个选举同样需要**超过半数 Sentinel 投票**。

网络分区时：3 个 Sentinel 分成 2+1，只有 2 个节点的区能选出 Leader Sentinel 并完成切换；1 个节点的区无法完成任何转移操作，老老实实等网络恢复。

### 3.3 Sentinel 的配置纪元

Redis Sentinel 用 `config-epoch`（配置纪元）标记每次故障转移的版本：

- 新主产生时，配置纪元 +1，并通过 `SENTINEL` 消息在 Sentinel 间传播。
- 旧纪元的信息不会被采纳——**配置纪元数字大的，永远覆盖数字小的**，从机制上杜绝「两个主」同时存在并被双方 Sentinel 各自承认。

**注意**：Sentinel 模式严格说不是强一致方案，极端情况下（例如 `min-replicas-to-write 0` + 分区+异步复制）仍可能丢数据或短暂双主。生产建议：

```conf
# redis.conf 关键防护参数
min-replicas-to-write 1      # 主库至少要有 1 个从库 ACK 才接受写入
min-replicas-max-lag 10      # 从库延迟超过 10 秒视为失联
```

这两行的作用：主库与从库失联（网络分区）后，主库会**拒绝写入**——宁可牺牲可用性，也不让分出去的小团体独自写数据，从源头掐灭脑裂。

## 四、Elasticsearch：discovery + minimum_master_nodes

### 4.1 选主条件

ES 集群选主需要满足：

- 候选节点 `discovery.seed_hosts` 能互相发现；
- 得票数达到 **`discovery.zen.minimum_master_nodes`**（ES 7 之后配置名改为 `cluster.initial_master_nodes` + `discovery.zen.minimum_master_nodes`，8.x 使用内置协调）。

ES 官方推荐：`minimum_master_nodes = (master-eligible 节点数 / 2) + 1`。

### 4.2 脑裂的经典成因

历史上 ES 脑裂最常见的原因就是 **`minimum_master_nodes` 配成 1 或者没配**：

- 3 个 master-eligible 节点分区成 2+1，如果 minimum=1，**两边各能选出自己的 master**，两个 master 同时接受写请求、各自维护集群状态，恢复后状态冲突。
- 正确配置 minimum=2：2 个节点的区能选主，1 个节点的区选不出来，只能报 `master_not_discovered_exception`。

```yaml
# elasticsearch.yml
discovery.zen.minimum_master_nodes: 2   # 3 个 master-eligible 节点时的推荐值
```

**ES 7.x/8.x 的更新**：新版本引入集群引导（bootstrap）与投票配置（voting configuration），把「固定 minimum_master_nodes」演进为**动态投票配置**——集群自动维护一个「有资格投票的节点集合」，选主只需该集合的多数派。这解决了节点增减时静态配置来不及调整的问题，但**多数派防脑裂的思想完全没变**。

## 五、MySQL 主从：半同步复制 + MHA/MGR 的防脑裂设计

### 5.1 主主复制是脑裂重灾区

MySQL 双主（互为主从）架构在两边都开启写入时，一旦分区：

- 两边各自生成 binlog，同一行数据被两边各改一次；
- `auto_increment` 冲突、唯一键冲突、数据行互相覆盖；
- 网络恢复后，复制链路互相应用对方的 binlog，直接报错或产生脏数据。

**经典教训**：双主架构必须「一主一写」或者「双主只允许单边写」，否则就是埋雷。

### 5.2 半同步复制（Semisync）

异步复制下，主库提交事务不等待从库 ACK，分区时从库落后数据直接丢。**半同步复制**要求：

- 主库提交事务时，至少等待 **1 个从库**（可配置 `rpl_semi_sync_master_wait_for_slave_count`）收到 binlog 并 ACK；
- ACK 超时（`rpl_semi_sync_master_timeout`）后降级为异步，并记录告警。

配合 `min-replicas-to-write` 的思想，可以做到「从库失联 → 主库拒绝写」，保证任何时刻数据只存在于一个可写节点侧。

### 5.3 MHA / MGR / 高可用方案

- **MHA**：主库宕机后由 Manager 选出数据最完整的新主，但 MHA 本身**不防脑裂**，需要依赖 SSH 互连 + 外部仲裁（如 ZK）来保证只有一个 Manager 执行切换。
- **MGR（MySQL Group Replication）**：基于 Paxos 的组复制，写入必须经**组内多数派**同意，天然防脑裂——分区后少数派节点直接拒绝写入，多数派继续服务。
- **Orchestrator / VIP 方案**：靠仲裁节点（比如 3 台仲裁机）决定谁持有 VIP，仲裁同样要多数派。

## 六、业务层防脑裂：分布式锁的终极防护

就算中间件层面都防住了，业务代码里用分布式锁时也逃不开脑裂：

### 6.1 Redis 分布式锁的脑裂问题（Redlock 的争议）

经典场景：A 拿到 Redis 锁，GC 停顿 10 秒，锁过期了；B 拿到锁开始干活；A 恢复后以为锁还是自己的，两个线程同时进临界区——**这就是广义的「应用层脑裂」**。

防护手段：

1. **锁续期（看门狗）**：Redisson 的 `watchdog` 默认 30 秒续期，防止业务没干完锁先过期；
2. **加锁时写入唯一标识（UUID/线程ID）**，释放时用 Lua 脚本比对后删除，防止误删别人的锁；
3. **Fencing Token（ fencing token）**：每次加锁拿到一个单调递增的 token，写数据时带上 token，服务端校验 token 是否最新——这是 Martin Kleppmann 提出的对抗「锁过期」的正解，比单纯续期更硬核。

```java
// Redisson 看门狗自动续期示例
RLock lock = redissonClient.getLock("order:" + orderId);
lock.lock();   // 默认 leaseTime=-1 时启动 watchdog，每 1/3 leaseTime 续期一次
try {
    // 业务逻辑
} finally {
    lock.unlock();
}
```

### 6.2 ZooKeeper 锁为什么不怕脑裂

ZK 锁基于临时顺序节点 + Watch：

- 客户端持有锁 = 持有一个**临时节点**，会话断开节点自动消失，锁自动释放，不会出现「持有者失联但锁还在」；
- 所有竞争者按序号排队，**锁的判定依赖 ZK 集群的多数派共识**，ZK 自己防住了脑裂，业务锁自然安全。

代价是性能不如 Redis，所以业界常见组合：**并发高、容忍短暂不一致用 Redis 锁；强一致、绝不能双写用 ZK/etcd 锁**。

## 七、面试高频追问汇总

**Q1：为什么网络分区无法避免？**
A：硬件故障、链路抖动、GC 长暂停、虚拟机迁移都会造成节点间短暂失联，分布式系统必须把「分区」当作常态来设计（P 是 CAP 里唯一不可选的）。

**Q2：多数派为什么能防脑裂？**
A：任意网络分区最多把集群分成两个不相通的团体，两个团体不可能同时凑齐超过半数节点，因此最多只有一个团体能完成「选主/提交」，另一个只能降级等待。

**Q3：3 节点和 4 节点，容错能力一样吗？**
A：一样，都是最多容忍 1 台故障；但 4 节点在 2+2 分区时整体不可用，3 节点在 1+2 分区时还能服务，所以奇数节点性价比更高。

**Q4：脑裂恢复后数据怎么办？**
A：分情况。强一致系统（ZK/MGR）靠 epoch/zxid 和多数派丢弃少数派数据，直接恢复；弱一致系统（Redis 异步复制）要人工比对、补数据甚至回滚；所以生产上要尽量让「少数派不写数据」。

**Q5：业务上怎么低成本防脑裂？**
A：写前自检（连不上对端就拒绝写）、锁带唯一标识 + 续期 + fencing token、数据库层加版本号乐观锁兜底、监控脑裂指标（主备心跳、双主告警）。

## 八、总结

| 系统 | 防脑裂核心机制 | 少数派的表现 |
| --- | --- | --- |
| ZooKeeper | Quorum 选主 + ZAB epoch/zxid | 无法选主，拒绝服务 |
| Redis Sentinel | sdown→odown 双重确认 + majority 选主 + config-epoch | 无法切换，等待恢复 |
| Elasticsearch | minimum_master_nodes / 动态投票配置 | 报 master_not_discovered |
| MySQL MGR | Paxos 组内多数派提交 | 拒绝写入 |
| 业务分布式锁 | 续期 + 唯一标识 + fencing token | 锁自动释放/续期失败 |

**一句话总结**：脑裂的本质是「网络分区下多个团体各自为政」，而所有成熟方案的核心都是**多数派仲裁**——让少数派学会「闭嘴」，宁可不可用，不可不一致。面试时把这条主线讲清楚，再展开各中间件的具体实现，就能拿捏住这道题。
