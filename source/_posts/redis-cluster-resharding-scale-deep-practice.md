---
title: 【Redis 运维】Redis Cluster 扩缩容深度实战：16384 槽位、MOVED/ASK 重定向与平滑迁移
date: 2026-09-13 08:00:00
tags:
  - Redis
  - Redis Cluster
  - 集群
  - 扩容
  - 运维
categories:
  - 中间件
  - Redis
author: 东哥
---

# 【Redis 运维】Redis Cluster 扩缩容深度实战：16384 槽位、MOVED/ASK 重定向与平滑迁移

## 面试官：Redis Cluster 扩容的时候，线上请求会受影响吗？

「会吧……会有一段时间不可用。」

「具体是什么不可用？是全部失败，还是部分失败？失败的原因是什么？客户端要改代码吗？为什么是 16384 个槽而不是 65536 个？」

这一串追问，能把「用过 Redis Cluster」和「运维过 Redis Cluster」的人彻底分开。

这篇不讲「Cluster 是什么」（那是选型文章的事），而是**只讲集群运维**：

- 16384 个槽的内部结构，以及为什么是 16384；
- `MOVED` 和 `ASK` 的区别——**这是理解平滑迁移的唯一钥匙**；
- 扩缩容的完整操作流程与每一步的观测点；
- 迁移过程中的性能影响与流量控制参数；
- 集群故障、脑裂、槽丢失的处置；
- 客户端（Jedis / Lettuce / Redisson）在集群模式下的避坑。

---

## 一、Cluster 的内部结构：认识三个关键概念

### 1.1 数据分片：16384 个哈希槽

Redis Cluster 把整个键空间划分为 **16384 个槽（slot）**：

```
slot = CRC16(key) mod 16384
```

每个 master 节点负责**一段连续的槽区间**：

```
Cluster: 3 master
  node-1  slots 0     - 5460     (5461 个槽)
  node-2  slots 5461  - 10922    (5462 个槽)
  node-3  slots 10923 - 16383    (5461 个槽)
```

### 1.2 为什么是 16384，不是 65536？

这是面试高频题，有四个层面的原因（**回答其中 2~3 个就能拿分**）：

**原因一：心跳包大小**

Cluster 节点之间通过 Gossip 协议交换心跳，心跳包里**携带自己负责的槽位图**。槽位图用 **Bitmap** 表示：

- 16384 个槽 = 16384 bits = **2KB**。
- 65536 个槽 = 65536 bits = **8KB**。

心跳是**每秒发多次、节点数 O(n²)** 的通信。假设 100 个节点，每秒多次心跳：

```
16384 槽：2KB × 100 × 10/s ≈ 2MB/s 的纯槽位图开销
65536 槽：8KB × 100 × 10/s ≈ 8MB/s  ← 带宽被心跳吃满
```

所以 **16384 是「槽粒度」与「心跳开销」的平衡点**。

**原因二：集群规模上限**

Redis 官方设计里，**节点数建议不超过 1000**。16384 个槽在 1000 个节点下，平均每节点 16 个槽——已经足够细。再多的槽没有实际意义。

**原因三：位运算效率与压缩**

16384 = 2^14，槽位图可以用 `uint16` 的位图（`unsigned char[2048]`），**在 CPU 缓存行里做位运算非常高效**；而 65536 需要 8KB，超出 L1 缓存，遍历与求交集的成本显著上升。

**原因四：集群消息的序列化成本**

`CLUSTER SLOTS` / `CLUSTER NODES` 的输出长度与槽数量正相关。槽太多会让运维命令的响应体变大，也让客户端解析变慢。

### 1.3 节点角色与通信

```
        ┌─────────────┐
        │  master-1   │◀──┐
        │ slots 0-5460│   │
        └──────┬──────┘   │  Gossip（默认端口 16379 = 服务端口 + 10000）
   复制+选举   │          │  PING/PONG/PUBLISH/FAIL
        ┌──────▼──────┐   │
        │  slave-1    │   │
        └─────────────┘   │
                          │
   ┌─────────────┐  ┌─────┴───────┐
   │  master-2   │  │  master-3   │
   │ slots ...   │  │ slots ...   │
   └─────────────┘  └─────────────┘
```

**必须记住的两个端口**：

| 端口 | 用途 |
| --- | --- |
| `6379` | 客户端访问端口 |
| `16379`（= 6379 + 10000） | **集群总线（Cluster Bus）**，节点间通信 |

**`16379` 必须互通**，很多集群搭建失败都是因为安全组只放开了 `6379`。

### 1.4 集群状态与共识

- **`cluster_state: ok`**：所有 16384 个槽都有负责节点，且**多数 master 在线**。
- **`cluster_state: fail`**：有槽无人负责，或**多数 master 已下线**。

**关键：Cluster 的容错需要「多数 master 存活」。** 3 master 集群挂 2 个 → `cluster_state: fail` → **整个集群拒绝服务（即使还活着的那个 master 的槽是可用的）**。

这是 Cluster 相比 Sentinel 的最大劣势：**它是「全有或全无」**。

```bash
# 查看集群状态
redis-cli -c -p 7001 cluster info
# cluster_state:ok
# cluster_slots_assigned:16384
# cluster_slots_ok:16384
# cluster_slots_pfail:0
# cluster_slots_fail:0
# cluster_known_nodes:6
# cluster_size:3          ← master 数量
# cluster_current_epoch:6
# cluster_my_epoch:1
# cluster_stats_messages_sent:...
```

---

## 二、MOVED 与 ASK：平滑迁移的唯一钥匙

**如果只能记住一个知识点，就记这个。**

### 2.1 MOVED：槽已经确定搬家了

```bash
$ redis-cli -c -p 7001 SET user:1001 "东哥"
-> Redirected to slot [12102] located at 127.0.0.1:7003
OK
```

客户端收到 `-MOVED 12102 127.0.0.1:7003` 时，理解为：

> **槽 12102 现在（永久）由 7003 负责，请更新你的槽位缓存，以后这类 key 直接去 7003。**

### 2.2 ASK：槽正在搬家中（临时重定向）

```bash
$ redis-cli -c -p 7001 GET user:2002
-> Redirected to slot [9000] located at 127.0.0.1:7002
(nil)
```

客户端收到 `-ASK 9000 127.0.0.1:7002` 时，理解为：

> **槽 9000 我还没搬完。这个 key 的具体数据现在在 7002（已经迁过去了），但槽的归属权还是我。请去 7002 取，并且带上 `ASKING` 命令；但不要更新你的槽位缓存——槽还没正式移交。**

### 2.3 两者的对比与内部机制

| 维度 | MOVED | ASK |
| --- | --- | --- |
| 含义 | 槽**已迁移完成** | 槽**正在迁移中** |
| 是否更新客户端槽位缓存 | **是** | **否** |
| 目标节点需要 `ASKING` | 不需要 | **需要** |
| 触发时机 | 槽编号已写入目标节点 | 源节点发现 key 不存在于本地 |
| 客户端行为 | 永久改路由 | 本次请求临时转发 |

**为什么 ASK 需要 `ASKING` 命令？**

因为目标节点此时**还不是**这个槽的主人。如果你直接去问它要 key，它可能因为「这个槽不归我管」而回 `MOVED`（把你打回源节点），形成**无限重定向死循环**。

`ASKING` 的作用是告诉目标节点：

> 「我知道这个槽还不归你，但请**本次**允许我访问。」

然后配合 **`CLIENT_CACHING` 与 cluster 的 `migrate` 内部标记**，目标节点会检查 `migrating_slots_to` / `importing_slots_from` 状态，允许这次访问。

```java
// Jedis 的 ASK 处理（简化逻辑，来自 JedisClusterConnectionHandler）
if (reply.startsWith("ASK")) {
    // 1. 不更新槽位缓存
    Jedis target = getConnectionFromNode(host, port);
    // 2. 先发 ASKING
    target.asking();
    // 3. 再发原命令
    return target.get(key);
}
```

### 2.4 迁移过程中的完整请求流程

假设把槽 9000 从 `node-1` 迁到 `node-2`：

```
阶段一：迁移前
  客户端 → node-1 请求 key=foo (slot 9000) → 正常返回

阶段二：迁移中（slot 9000 被标记 MIGRATING on node-1, IMPORTING on node-2）
  key=foo 已被迁移：
  客户端 → node-1 → [本地没有] → 返回 ASK 9000 node-2
  客户端 → node-2（带 ASKING） → 返回数据
  客户端**不更新缓存**，下次还是先问 node-1

  key=bar 还没被迁移：
  客户端 → node-1 → [本地有] → 正常返回数据

  key=baz 是新写入的（迁移中不存在的 key）：
  客户端 → node-1 → [本地没有且该 key 不存在]
  此时如果槽在 MIGRATING 状态，node-1 **拒绝写入**并返回：
    -ASK 9000 node-2   ← 让客户端去新节点写
  （这是 Redis 的保证：迁移中不会出现「同一个 key 在两处都不存在」）

阶段三：迁移完成（CLUSTER SETSLOT 9000 NODE node-2 广播完成）
  客户端 → node-1 → 返回 MOVED 9000 node-2
  客户端更新槽位缓存，之后直接访问 node-2
```

**关键保证（也是面试加分点）**：

> **Redis Cluster 的迁移是「原子到 key 级别」的——迁移过程中，同一个 key 绝不会出现「两边都不存在」或「两边数据不一致」的状态。** 因为：
> - key 还在源节点：源节点直接返回。
> - key 已迁走：源节点返回 ASK，客户端去目标节点拿。
> - key 不存在且槽在 MIGRATING：源节点拒绝写入并 ASK，客户端去目标节点写。
> - 因此**不存在数据丢失窗口**。

### 2.5 客户端的重定向处理能力

| 客户端 | MOVED | ASK | 说明 |
| --- | --- | --- | --- |
| Jedis Cluster | ✅ | ✅ | 内置槽位缓存（`JedisClusterInfoCache`） |
| Lettuce Cluster | ✅ | ✅ | 内置，且支持**拓扑自动刷新** |
| Redisson | ✅ | ✅ | 内置，支持 `MOVED`/`ASK` 自动重试 |
| Spring Data Redis（Lettuce） | ✅ | ✅ | 需确认 `ClusterTopologyRefreshOptions` 配置 |
| 自研 / 裸 socket | ❌ | ❌ | **不支持重定向，集群直接不可用** |

**结论：必须用支持 Cluster 协议的客户端。** 用单机客户端连集群，会不断收到 `MOVED` 错误。

---

## 三、扩容实战：加入新节点

### 3.1 场景与目标

```
现状：3 master + 3 slave，数据量 30GB，容量告急
目标：扩到 4 master + 4 slave，把新增的 master 分担一部分槽
```

### 3.2 步骤一：准备新节点

```bash
# 在新机器上启动 7007（先不加集群）
redis-server /etc/redis/7007.conf

# 7007.conf 关键配置
cat >> /etc/redis/7007.conf <<'EOF'
port 7007
cluster-enabled yes
cluster-config-file nodes-7007.conf
cluster-node-timeout 15000
bind 0.0.0.0
protected-mode no
appendonly yes
maxmemory 8gb
maxmemory-policy noeviction      # 集群模式建议 noeviction（见 5.3）
EOF
```

### 3.3 步骤二：把新节点加入集群

```bash
# 方式一：CLUSTER MEET（手工）
redis-cli -c -p 7007 cluster meet 127.0.0.1 7001

# 方式二：redis-cli --cluster add-node（推荐，会自动同步拓扑）
redis-cli --cluster add-node 127.0.0.1:7007 127.0.0.1:7001

# 此时 7007 会作为 master 加入，但负责 0 个槽
redis-cli -p 7007 cluster info | grep cluster_slots_assigned
# cluster_slots_assigned:0
```

**给新 master 配一个 slave**：

```bash
redis-cli --cluster add-node 127.0.0.1:7008 127.0.0.1:7001 \
  --cluster-slave --cluster-master-id <7007的node-id>
```

### 3.4 步骤三：迁移槽（核心步骤）

**方式一：自动 rebalance（简单但有风险）**

```bash
redis-cli --cluster rebalance 127.0.0.1:7001 \
  --cluster-use-empty-masters \
  --cluster-weight 7001=1 7002=1 7003=1 7007=1
```

`rebalance` 会**自动计算每个节点应该拥有的槽数并迁移**。**但它可能在业务高峰期执行，造成抖动。** 生产环境**谨慎使用**。

**方式二：手工指定迁移区间（推荐）**

```bash
# 从 7001 迁移 1000 个槽到 7007
redis-cli --cluster reshard 127.0.0.1:7001 \
  --cluster-from <7001的node-id> \
  --cluster-to <7007的node-id> \
  --cluster-slots 1000 \
  --cluster-yes \
  --cluster-timeout 5000 \
  --cluster-pipeline 10
```

**`--cluster-pipeline` 是关键性能参数**：它控制每次批量迁移多少个 key（默认 10）。**值越大迁移越快，但对源节点的 CPU 和网络冲击越大。**

```bash
# 高负载环境：调小 pipeline，加 sleep，慢慢迁
redis-cli --cluster reshard ... --cluster-pipeline 5

# 低峰期：加大 pipeline 快速完成
redis-cli --cluster reshard ... --cluster-pipeline 100
```

### 3.5 迁移的底层过程（理解这个，你才知道怎么控制影响）

对每一个正在迁移的槽，Redis 做的是：

```bash
# 1. 目标节点标记为「导入中」
CLUSTER SETSLOT 9000 IMPORTING <source-node-id>

# 2. 源节点标记为「迁出中」
CLUSTER SETSLOT 9000 MIGRATING <target-node-id>

# 3. 取出该槽下的所有 key
CLUSTER GETKEYSINSLOT 9000 100

# 4. 逐个迁移（MIGRATE 是原子操作：DUMP + 传输 + RESTORE + DEL）
MIGRATE 127.0.0.1 7007 "" 0 5000 KEYS key1 key2 ... key100

# 5. 槽下 key 全部迁完，正式移交
CLUSTER SETSLOT 9000 NODE <target-node-id>   # 在目标节点执行（变成主人）
CLUSTER SETSLOT 9000 NODE <target-node-id>   # 在源节点执行（放弃主人身份）
# 6. 通过 Gossip 广播给全集群
```

**关键观测点：`MIGRATE` 是阻塞的！**

`MIGRATE` 在源节点上**同步执行 DUMP + 传输 + DEL**。如果一次迁 100 个 key，其中有大 key（比如 1MB 的 Hash），源节点会被**阻塞几百毫秒**。

**所以迁移的关键控制手段是**：

1. **`--cluster-pipeline` 调小**（每次少迁几个）。
2. **避开大 key**（迁移前先找出大 key，对它们单独处理）。
3. **在低峰期执行**。
4. **监控源节点的 `latency` 与 `blocked_clients`**。

### 3.6 迁移期间必须监控的指标

```bash
# 源节点：观察迁移进度与阻塞
redis-cli -p 7001 cluster info | grep -E "migrating|slots"
# cluster_slots_migrating:1

redis-cli -p 7001 info stats | grep -E "migrate|sync"
# sync_full / sync_partial_ok

redis-cli -p 7001 info clients | grep blocked
# blocked_clients:0     ← 迁移中最好不要持续 > 0

redis-cli -p 7001 info commandstats | grep migrate
# cmdstat_migrate:calls=...,usec=...,usec_per_call=...   ← 看单次 migrate 的平均耗时
```

```bash
# 实时监控迁移进度（每 2 秒刷新）
watch -n 2 'redis-cli --cluster check 127.0.0.1:7001 2>&1 | head -20'
```

### 3.7 扩容完成后的验证

```bash
# 1. 槽覆盖检查（必须 16384 全覆盖，无空洞）
redis-cli --cluster check 127.0.0.1:7001
# [OK] All 16384 slots covered.

# 2. 节点分布检查
redis-cli -p 7001 cluster nodes | awk '{print $2, $3, $9}' | sort

# 3. 数据一致性抽查（对比迁移前后各槽的 key 数量）
redis-cli --cluster call 127.0.0.1:7001 dbsize

# 4. 压测验证
redis-benchmark -h 127.0.0.1 -p 7001 -c 50 -n 100000 -t set,get -q
```

---

## 四、缩容实战：摘除节点

### 4.1 正确的缩容顺序

**顺序不能颠倒：先迁槽 → 再删节点。** 反过来会丢数据。

```bash
# 第 1 步：把待删节点的槽全部迁出（必须迁空）
redis-cli --cluster reshard 127.0.0.1:7001 \
  --cluster-from <待删节点id> \
  --cluster-to <接收节点id> \
  --cluster-slots <该节点的槽总数> \
  --cluster-yes

# 第 2 步：确认该节点槽数为 0
redis-cli -p 7007 cluster info | grep cluster_slots_assigned
# cluster_slots_assigned:0

# 第 3 步：删除节点
redis-cli --cluster del-node 127.0.0.1:7001 <待删节点id>
```

### 4.2 缩容的四个坑

**坑一：直接删有数据的节点 = 数据丢失。**

`del-node` 只是把节点从集群拓扑里摘掉。如果它还有槽和 key，那些 key 就**永远找不回来了**（`cluster_state` 也会变成 `fail`，因为槽无人负责）。

**坑二：缩容后 master 数量变少，容错能力下降。**

```
3 master → 可容忍 1 个 master 故障（多数派 = 2/3）
2 master → 0 容错！挂 1 个就 cluster_state:fail
```

**所以缩容到 2 master 是极其危险的操作，生产不建议。** 至少要保留 3 个 master。

**坑三：删除的是 slave 时，先确认对应 master 是否有其他 slave。**

```bash
# 删除前确认
redis-cli -p 7001 cluster nodes | grep slave
```

**坑四：忘记删除后清理 `nodes.conf`。**

被删节点的 `nodes-*.conf` 文件如果残留，重启时会尝试重新加入集群，导致拓扑反复震荡。**删除节点后，务必把该节点的数据目录（或至少 `nodes.conf`）清理掉**，并下线进程。

---

## 五、集群常见故障与处置

### 5.1 集群状态 fail 的三种原因

```bash
redis-cli -p 7001 cluster info | grep -E "^cluster_state|slots_fail|known_nodes|size"
```

| 原因 | 判据 | 处置 |
| --- | --- | --- |
| 有槽无人负责 | `cluster_slots_assigned < 16384` | 手工指派槽（见下） |
| 多数 master 下线 | `cluster_known_nodes` 减少，`cluster_size` 变小 | 恢复节点或重建集群 |
| 槽处于 fail 状态 | `cluster_slots_fail > 0` | 等自动故障转移；若失败则手工接管 |

**手工指派槽**（当槽无人负责时）：

```sql
-- 在可用节点上执行，把无主槽指派给自己
-- 注意：这是「修复」操作，可能导致数据不一致，仅在确认原节点不可恢复时使用
redis-cli -p 7001 cluster addslots 9000 9001 9002 ... 9010
```

### 5.2 自动故障转移不生效的原因

Cluster 的故障转移流程：

```
1. 节点 A 发 PING 给节点 B，B 超时未响应
2. A 把 B 标记为 PFAIL（主观下线）
3. 通过 Gossip 询问其他节点，多数节点也认为 B 不可达
4. A 把 B 标记为 FAIL（客观下线），并广播
5. B 的 slave 发起选举（需要获得「持有槽的 master」的多数票）
6. 选举成功 → slave 提升为 master → 接管 B 的槽 → 广播
```

**转移不生效的常见原因**：

| 原因 | 检查 |
| --- | --- |
| `cluster-node-timeout` 太大 | 默认 15000ms，转移至少需要这个时间 |
| master 数量不足多数派 | 3 master 挂 2 → 无法选举 |
| slave 与 master 断连时间过长 | 超过 `cluster-node-timeout * cluster-slave-validity-factor` 时 slave 不参选 |
| slave 数据太旧 | 检查 `cluster-slave-validity-factor`（默认 10，设为 0 表示不校验） |
| 网络分区导致脑裂，两个分区各自以为自己是多数 | 见 5.4 |

```ini
# 让故障转移更快（代价：更容易误判）
cluster-node-timeout 5000

# slave 参选的数据新鲜度校验（0 = 禁用校验，不推荐）
cluster-slave-validity-factor 10
```

### 5.3 关于 `maxmemory-policy` 的坑

**Cluster 模式下，`maxmemory-policy` 必须是 `noeviction`**（至少官方强烈建议）。

原因：如果开启 LRU 淘汰，**不同节点的淘汰行为不一致**，会导致：

- 同一份数据（主从）在 master 和 slave 上被独立淘汰，主从数据不一致。
- 迁移中的 key 可能被淘汰，导致迁移数据不完整。

**正确做法**：

```ini
maxmemory 8gb
maxmemory-policy noeviction    # 内存满时拒绝写入，由应用侧感知并扩容
```

```ini
# 如果你确实要用淘汰策略，只在「纯缓存、可容忍丢失」的场景，且理解风险
# maxmemory-policy allkeys-lru
```

**监控 `maxmemory` 使用率并提前扩容**，而不是靠淘汰兜底：

```bash
redis-cli -p 7001 info memory | grep -E "used_memory_human|maxmemory_human|maxmemory_policy"
redis-cli -p 7001 info memory | grep mem_fragmentation_ratio
```

### 5.4 集群脑裂

Cluster 的脑裂场景：网络分区把 6 个节点分成 3+3，如果分成的是「3 master vs 3 slave」，问题不大。但如果分区后**两侧都有 master**，且各自都认为自己是多数派，就会各自写入，产生数据分歧。

**Redis Cluster 的天然保护**：**写入需要「持有槽的 master 的多数派」都在线**。所以少数派分区会变成 `cluster_state:fail`，**拒绝写入**——这是 CAP 中的 CP 选择（牺牲可用性保一致性）。

**处置**：

```bash
# 1. 先确认分区两侧的状态
redis-cli -p 7001 cluster info | grep cluster_state
redis-cli -p 7004 cluster info | grep cluster_state

# 2. 网络恢复后，检查是否出现槽冲突（同一槽被两个节点声称拥有）
redis-cli --cluster check 127.0.0.1:7001   # 会报 SLOT CONFLICT

# 3. 用 CLUSTER SETSLOT ... STABLE 或重新指派修复
redis-cli -p 7001 cluster setslot <slot> stable
```

**预防**：

```ini
# 确保奇数个 master（3/5/7），避免对半分裂
# 跨机房部署时，把 master 分散在不同机房
cluster-require-full-coverage yes    # 默认 yes：有槽不可用则整个集群不可用（更安全）
```

**`cluster-require-full-coverage` 的取舍**：

| 值 | 行为 | 适用 |
| --- | --- | --- |
| `yes`（默认） | 有槽不可用 → **整个集群拒绝所有请求** | 数据一致性优先 |
| `no` | 只拒绝受影响槽的请求，**其他槽正常服务** | 可用性优先 |

**这个参数值得认真评估**：设为 `yes` 时，一个小故障会放大成全局不可用；设为 `no` 时，只有部分数据不可用。

---

## 六、客户端避坑：Jedis / Lettuce / Redisson

### 6.1 Spring Boot + Lettuce 的拓扑刷新配置

**默认配置在集群扩缩容后会出问题**——客户端可能一直用旧拓扑，收到大量 `MOVED`。

```yaml
spring:
  data:
    redis:
      cluster:
        nodes:
          - 127.0.0.1:7001
          - 127.0.0.1:7002
          - 127.0.0.1:7003
        max-redirects: 3          # 最多重定向次数，防死循环
      lettuce:
        pool:
          max-active: 16
          max-idle: 8
          min-idle: 2
          max-wait: 3000ms
        cluster:
          refresh:
            adaptive: true         # 自适应刷新（收到 MOVED 就刷新）
            period: 30s            # 定时刷新（兜底）
```

```java
@Configuration
public class RedisClusterConfig {

    @Bean
    public LettuceClientConfigurationBuilderCustomizer clusterTopologyCustomizer() {
        return builder -> builder.clientOptions(
                ClientOptions.builder()
                        .disconnectedBehavior(ClientOptions.DisconnectedBehavior.REJECT_COMMANDS)
                        .autoReconnect(true)
                        .socketOptions(SocketOptions.builder()
                                .connectTimeout(Duration.ofSeconds(3))
                                .keepAlive(true)
                                .build())
                        .build()
        ).topologyRefreshOptions(
                ClusterTopologyRefreshOptions.builder()
                        // 自适应刷新：收到 MOVED / ASK 时触发
                        .enableAllAdaptiveRefreshTriggers()
                        .enablePeriodicRefresh(Duration.ofSeconds(30))
                        .dynamicRefreshSources(true)
                        .closeStaleConnections(true)
                        .build()
        );
    }
}
```

**`enableAllAdaptiveRefreshTriggers()` 是集群扩缩容的关键配置**——没有它，客户端只能靠定时刷新，期间会持续报 `MOVED` 错误。

### 6.2 Redisson 的关键配置

```java
@Configuration
public class RedissonConfig {

    @Bean(destroyMethod = "shutdown")
    public RedissonClient redissonClient() {
        Config config = new Config();

        config.useClusterServers()
              .addNodeAddress(
                      "redis://127.0.0.1:7001", "redis://127.0.0.1:7002",
                      "redis://127.0.0.1:7003", "redis://127.0.0.1:7004")
              // 扫描间隔（默认 10s）：发现拓扑变化的周期
              .setScanInterval(2000)
              // 集群操作超时
              .setTimeout(3000)
              .setConnectTimeout(5000)
              // 重试次数与间隔
              .setRetryAttempts(3)
              .setRetryInterval(1500)
              // 从节点读取（默认 SLAVE，读走 slave）
              .setReadMode(ReadMode.SLAVE)
              .setSubscriptionMode(SubscriptionMode.MASTER)
              .setPassword("your-password");

        return Redisson.create(config);
    }
}
```

**注意 `setReadMode(ReadMode.SLAVE)`**：

- 优点：读请求分散到 slave，提升读吞吐。
- **代价：可能读到过期数据（主从异步复制的固有延迟）**。

**如果业务不能容忍读到旧数据，必须设为 `ReadMode.MASTER`。**

### 6.3 五个必须知道的客户端坑

**坑一：`max-redirects` 太小会导致正常请求失败。**

扩容期间，一个请求可能需要连续重定向：`源节点 → ASK 目标 → MOVED 新节点`。如果 `max-redirects = 1`，第二次重定向就会报错：

```
Too many Cluster redirections
```

**建议 3~5。**

**坑二：Lua 脚本里的所有 key 必须在同一个节点（同一个槽）。**

```java
// ❌ 会失败：两个不同的键可能不在同一节点
String script = "return redis.call('get', KEYS[1]) + redis.call('get', KEYS[2])";
List<String> keys = Arrays.asList("user:1", "order:2");
// 报错：CROSSSLOT Keys in request don't hash to the same slot

// ✅ 用 hash tag 强制同槽
List<String> keys = Arrays.asList("{order}:1", "{order}:2");
// {order} 会参与 CRC16，因此这两个 key 保证在同一个槽
```

**hash tag 规则**：`{...}` 中的内容参与哈希计算。所以 `{order}:1` 和 `{order}:2` 一定在同一槽。

**坑三：`MGET` / `MSET` / `DEL` 多 key 命令会 CROSSSLOT。**

```java
// ❌ 跨槽会报错
redisTemplate.opsForValue().multiGet(Arrays.asList("user:1", "user:2"));

// ✅ 强制同槽（牺牲分布均匀性）
redisTemplate.opsForValue().multiGet(Arrays.asList("{user}:1", "{user}:2"));

// ✅ 或在客户端侧拆成多次单 key 请求（推荐，保持分布均匀）
List<Object> results = keys.stream()
        .map(k -> redisTemplate.opsForValue().get(k))
        .collect(Collectors.toList());
```

**坑四：`keys` 命令在集群里只查当前节点。**

```bash
# ❌ 只查了一个节点的 key
redis-cli -p 7001 keys "user:*"

# ✅ 遍历所有节点
redis-cli --cluster call 127.0.0.1:7001 keys "user:*"
```

**生产环境禁止 `keys`**，用 `scan`（但 `scan` 在集群里也需要逐节点遍历）。

**坑五：Pub/Sub 在 Cluster 模式是「广播」的。**

Cluster 的 Pub/Sub 会把消息**广播到所有节点**（不是按槽路由）。所以：

- 订阅者连到任意节点都能收到消息（**这对业务是好事**）。
- 但**广播本身有开销**，大规模 Pub/Sub 会放大集群间网络流量。

**替代方案**：用 `Redis Stream`（支持按 key 路由到特定槽）或外部的 Kafka/RocketMQ。

---

## 七、完整运维清单

### 7.1 上线前检查

- [ ] master 数量为**奇数**且 **≥ 3**
- [ ] 每个 master 至少 **1 个 slave**
- [ ] `cluster-node-timeout` 设置合理（5~15 秒，跨机房要考虑 RTT）
- [ ] 服务端口与 **集群总线端口（+10000）** 都已开通
- [ ] `maxmemory` 与 `maxmemory-policy noeviction` 已设置
- [ ] 关闭 `save`/`appendonly` 策略评估过（Cluster 建议 `appendonly yes` + `everysec`）
- [ ] 客户端使用 **Cluster 模式**（非单机模式）
- [ ] 客户端配置了 `max-redirects` 与**拓扑自适应刷新**
- [ ] 业务代码中不存在跨槽的 `MGET`/`Lua`（或已用 hash tag）

### 7.2 扩容/缩容前检查

- [ ] 确认在**业务低峰期**执行
- [ ] 已备份（`redis-cli --cluster call ... bgsave` 或从库备份）
- [ ] 已找出并处理**大 key**（`redis-cli --bigkeys` 或 `--memkeys`）
- [ ] `--cluster-pipeline` 已按负载调小
- [ ] 已准备监控面板：`cluster_slots_migrating`、`blocked_clients`、`cmdstat_migrate`、节点 CPU、网络
- [ ] 应用侧已配置好拓扑刷新，**升级前验证过重定向处理**

### 7.3 核心监控指标

```bash
# 集群健康
cluster_state                          # 必须 ok
cluster_slots_assigned                 # 必须 16384
cluster_slots_fail                     # 必须 0
cluster_known_nodes                    # 节点总数
cluster_size                           # master 数量
cluster_slots_migrating                # 迁移中槽数（正常应为 0）

# 内存
used_memory_human / maxmemory_human
mem_fragmentation_ratio                # > 1.5 关注，> 2 需整理

# 客户端的体验
blocked_clients                        # 持续 > 0 要排查
connected_clients
instantaneous_ops_per_sec
latency_percentiles_usec

# 迁移相关
cmdstat_migrate                        # usec_per_call 突增 = 有大 key
```

### 7.4 一个真实的扩容事故复盘

**背景**：3 master 集群（每个 5GB 数据），扩容到 5 master。用 `--cluster rebalance` 在**下午 3 点**执行。

**现象**：

1. 迁移开始 3 分钟后，客户端开始大量报错 `JedisClusterMaxAttemptsException`。
2. 同时 `blocked_clients` 从 0 涨到 20+。
3. 应用 P99 从 5ms 涨到 800ms。

**根因**（三个叠加）：

1. **`rebalance` 使用了默认 pipeline（10），且没有限速**，单位时间内迁移太多 key。
2. **集群里有一批大 key**（单 key 约 500KB 的 Hash，用于存用户画像），`MIGRATE` 时源节点被阻塞数十毫秒。
3. **客户端 `max-redirects` 只有 1**，迁移期间重定向链变长，直接报错。

**修复**：

1. 立即中断迁移（`redis-cli --cluster reshard` 支持中断，或临时终止进程）。
2. 先处理大 key：把 500KB 的 Hash 拆成多个小 Hash（`HGETALL` 分批改 key 名）。
3. 改为**凌晨执行**，`--cluster-pipeline 5`，并分批（每次迁 200 槽）执行。
4. 客户端 `max-redirects` 调到 5，开启 `enableAllAdaptiveRefreshTriggers()`。

**结果**：第二次迁移全程 `blocked_clients = 0`，P99 峰值 20ms，业务无感知。

**三条教训**：

1. **不要用 `rebalance` 在生产高峰期做全量均衡。**
2. **迁移前必须找大 key**——它们才是真正的阻塞源。
3. **客户端的重定向容忍度必须提前调好**，否则集群还没事，客户端先崩了。

---

## 八、面试高频追问

**Q1：Redis Cluster 迁移槽的时候，数据会丢失吗？**

**不会丢。** Redis 的迁移保证是 key 级别的原子性：

- key 还在源节点 → 源节点直接返回。
- key 已迁到目标 → 源节点返回 `ASK`，客户端去目标节点取（带 `ASKING`）。
- key 不存在且槽在 MIGRATING → 源节点拒绝写入并 `ASK`，客户端去目标节点写。

所以**不存在「两边都没有」的窗口**。但要注意：**如果在迁移过程中发生节点故障，且该槽的 slave 数据落后，可能出现数据不一致**——这是主从异步复制的固有风险，不是迁移本身的问题。

**Q2：为什么 3 个 master 挂 2 个，整个集群就不可用了？**

两个条件同时不满足：

1. **多数 master 不在线**（3 个里挂了 2 个，只剩 1 个，不构成多数派）→ 无法选举、无法维持 `cluster_state: ok`。
2. **需要迁移的槽失去负责节点** → `cluster_slots_assigned < 16384`。

由于默认 `cluster-require-full-coverage yes`，只要有一批槽无人负责，**整个集群拒绝所有请求**——包括那些槽还完好的数据。这是 Cluster 相比 Sentinel 最需要提前告知业务方的特性。

**Q3：`cluster-require-full-coverage` 该设 yes 还是 no？**

| 场景 | 建议 |
| --- | --- |
| 数据一致性优先（如订单、账户缓存） | `yes`（默认，失败要失败得彻底，避免读到部分旧数据） |
| 可用性优先（如商品热搜、推荐） | `no`（部分不可用总比全不可用好） |
| 混合业务 | 拆分集群：关键数据独立集群设 `yes`，非关键数据设 `no` |

**我的建议：不要用 `no` 来「掩盖」集群健康问题。** 出现部分槽不可用，应该把它当成故障来处理（修复节点），而不是允许长期带病运行。

**Q4：迁移大 key 怎么办？**

三条路：

1. **拆 key**：把大 Hash/List/ZSet 按业务维度拆成多个小 key（最根本）。
2. **单独处理**：先不迁移含大 key 的槽，用 `redis-cli --cluster reshard` 精确指定，在业务最低峰专门迁。
3. **用工具辅助**：`redis-cli --bigkeys` / `--memkeys` 先定位，再用 `MIGRATE` 手动迁单个大 key，配合 `redis-cli -p X debug sleep` 观察阻塞。

**根本建议：大 key 本身就是治理对象，不该等到迁移才处理。**

**Q5：Cluster 和 Sentinel 的运维复杂度差在哪？**

| 维度 | Sentinel | Cluster |
| --- | --- | --- |
| 分片 | 无（单 master 容量上限 = 机器内存） | **原生分片（可水平扩容）** |
| 扩容 | 只能垂直扩容（升配置） | **水平扩槽** |
| 容错粒度 | **单主故障自动切换** | 多数 master 存活才可用 |
| 客户端 | 通过 Sentinel 发现 master，**改动小** | **必须支持 Cluster 协议** |
| 多 key 操作 | 无限制 | **CROSSSLOT 限制** |
| Lua 脚本 | 无限制 | 所有 key 必须同槽 |
| Pub/Sub | 无限制 | 广播 |
| 运维复杂度 | 中 | **高**（槽管理、迁移、脑裂） |
| 适合 | 数据量 < 单机内存 | 数据量 > 单机内存 |

**结论：能不用 Cluster 就不用。** 单机内存够用 + 需要高可用 → 主从 + Sentinel 更简单可靠。

---

## 九、总结

```
Redis Cluster 运维核心
├── 结构
│   ├── 16384 槽（CRC16(key) mod 16384），为什么不是 65536？
│   │   ├── 槽位图大小（2KB vs 8KB）× 每秒心跳 × O(n²) 流量
│   │   ├── 槽位图位运算与 CPU 缓存友好
│   │   └── 节点数上限 1000，16384 已足够细
│   ├── 端口：6379（服务）+ 16379（集群总线）
│   └── 可用性：需要「持有槽的多数 master」存活（全有或全无）
├── 重定向（最关键）
│   ├── MOVED：槽已移交 → 客户端**更新**槽位缓存
│   ├── ASK：槽迁移中 → 客户端**不更新**缓存，带 ASKING 临时转发
│   └── 迁移的 key 级原子保证：不存在「两边都不存在」的窗口
├── 扩容流程
│   ├── add-node → add-node（slave） → reshard（迁槽）→ check 验证
│   ├── 关键参数：--cluster-pipeline（批量大小，控制阻塞）
│   └── 关键风险：MIGRATE 阻塞（大 key 是元凶）
├── 缩容流程
│   ├── **先迁空槽 → 再 del-node**（顺序颠倒 = 丢数据）
│   └── 不要缩到 2 master（0 容错）
├── 故障处置
│   ├── cluster_state: fail 三类原因（槽无主 / 多数 master 挂 / 槽 fail）
│   ├── 故障转移流程：PFAIL → FAIL → 选举 → 接管
│   ├── 脑裂：少数派分区变 fail，拒绝写入（CP 选择）
│   └── cluster-require-full-coverage 的取舍
└── 客户端
    ├── 必须用 Cluster 客户端（Jedis Cluster / Lettuce / Redisson）
    ├── Lettuce 必须开 enableAllAdaptiveRefreshTriggers()
    ├── max-redirects 设 3~5
    └── hash tag { } 解决 CROSSSLOT；MGET/Lua 必须同槽
```

三句话总结：

1. **`MOVED` 是「搬家完成了」，`ASK` 是「正在搬家」——这条区别，是理解 Redis Cluster 平滑迁移的全部关键。**
2. **迁移的性能风险不在槽，而在 key：`MIGRATE` 是阻塞的，大 key 就是线上抖动的元凶。**
3. **Cluster 的运维复杂度远高于 Sentinel（槽管理、脑裂、CROSSSLOT、客户端适配），能用 Sentinel + 单机内存解决的场景，不要上 Cluster。**

如果面试官再问「Redis Cluster 扩容会影响线上吗」，你的回答可以是这样：

> 「会，但可控。影响来自两处：一是 `MIGRATE` 在源节点上是阻塞的，遇到大 key 会造成毫秒级抖动；二是迁移期间请求需要 `ASK` 重定向，如果客户端没配拓扑自适应刷新或 `max-redirects` 太小，会直接报错。所以扩容的正确姿势是：先找大 key 并处理，选择低峰期执行，把 `--cluster-pipeline` 调小分批迁移，同时提前把客户端的重定向容忍度和拓扑刷新配好。迁移本身不会丢数据，因为 Redis 保证了 key 级别的原子性——源节点有就直接返回，已迁走就 ASK 到目标节点。」
