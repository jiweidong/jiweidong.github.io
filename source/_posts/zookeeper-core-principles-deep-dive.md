---
title: ZooKeeper 核心原理深度解析：ZAB 协议、Watcher 机制与分布式协调实战
date: 2026-08-11 09:30:00
tags:
  - Java
  - ZooKeeper
  - 分布式协调
  - ZAB
categories:
  - 分布式
  - 中间件
author: 东哥
---

# ZooKeeper 核心原理深度解析：ZAB 协议、Watcher 机制与分布式协调实战

## 面试官：ZooKeeper 到底是怎么保证数据一致性的？

在 Dubbo、Kafka、HBase、Flink 等大量分布式系统中，ZooKeeper 都扮演着"分布式协调者"的角色：服务注册发现、分布式锁、Leader 选举、配置管理。但很多人停留在"会用客户端 API"的层面，被问到 **ZAB 协议和 Paxos 的区别**、**Watcher 为什么会失效**、**为什么 ZK 不适合存大量数据** 时就答不上来。

本文从数据模型、ZAB 协议、Watcher 机制、会话管理四个维度深度拆解，最后给出分布式锁的完整实现与生产实践。

<!-- more -->

## 一、数据模型：一棵内存 ZNode 树

ZooKeeper 的数据模型是一棵**层次化的命名空间树**，节点称为 ZNode：

```
/apps
  ├── /apps/web        持久节点
  ├── /apps/workers
  │     ├── /apps/workers/worker-0000000001   临时顺序节点
  │     └── /apps/workers/worker-0000000002
  └── /apps/config
        └── /apps/config/db.yml
```

| 节点类型 | 特性 | 典型用途 |
| --- | --- | --- |
| 持久节点（Persistent） | 客户端断开仍存在 | 配置、元数据 |
| 临时节点（Ephemeral） | 会话结束自动删除 | 服务在线状态、分布式锁 |
| 顺序节点（Sequential） | 自动追加单调递增序号 | 公平锁、任务编号 |
| 容器节点（Container） | 子节点清空后自动删除 | 业务容器 |
| TTL 节点 | 带过期时间 | 限流、临时配置 |

ZNode 同时拥有** stat 状态信息**：`czxid`（创建事务 ID）、`mzxid`（修改事务 ID）、`version`（版本号）、`ephemeralOwner`（临时节点所属会话 ID）等。`version` 是乐观锁的基础——CAS 更新数据就靠它。

**关键限制**：ZK 全量数据保存在内存，单节点默认约 1MB 单条数据上限（`jute.maxbuffer`），所以它定位是"协调元数据"，不是数据库。

## 二、ZAB 协议：ZooKeeper 的一致性灵魂

ZAB（ZooKeeper Atomic Broadcast，原子广播协议）是 ZK 专门设计的一致性协议，保证**崩溃恢复 + 原子广播**。

### 2.1 三种角色与三种状态

| 角色 | 职责 |
| --- | --- |
| Leader | 唯一的写入口，负责事务提案与广播 |
| Follower | 处理读请求，参与投票，转发写请求给 Leader |
| Observer | 只读，不参与投票，用于扩展读能力 |

状态机：`LOOKING`（选举中）→ `FOLLOWING` / `LEADING` / `OBSERVING`。

### 2.2 原子广播阶段（正常运行期）

Leader 处理一次写请求的完整流程：

```
客户端 → Follower 转发 → Leader
  1. Leader 生成事务 Proposal，分配单调递增的 zxid
  2. 向所有 Follower 广播 PROPOSAL
  3. Follower 写入本地事务日志后回复 ACK
  4. Leader 收到多数派（过半）ACK → 广播 COMMIT
  5. Follower 提交事务并通知客户端
```

核心保证：

- **zxid 全局有序**：高 32 位是 Leader 纪元（epoch），低 32 位是事务计数器。新 Leader 上任 epoch +1，计数器归零，保证新旧 Leader 的事务顺序不混乱；
- **过半 ACK**：只要大多数节点确认，事务就提交——这是容错的基础，5 节点集群允许挂 2 台；
- **先写磁盘日志再响应**：事务必须落盘（`sync`）才 ACK，保证崩溃后能恢复。

### 2.3 崩溃恢复阶段（Leader 挂了怎么办）

恢复流程（Fast Leader Election）：

1. 各节点进入 `LOOKING`，广播自己的 `(zxid, sid)` 组合，**zxid 大的节点优先当选**（数据最新者胜出）；
2. 获得多数派投票的节点成为新 Leader；
3. 新 Leader 与 Follower 同步：比对彼此的 zxid，**丢弃未提交的提案，补发已提交但 Follower 缺失的提案**；
4. 同步完成后进入 `LEADING` 状态，对外恢复服务。

**这里有个高频面试点**：ZAB 丢弃"未提交事务"是否会造成数据丢失？不会——因为那些事务从未对客户端返回成功（未过半 ACK），丢弃是符合线性一致语义的；而一旦对客户端确认过的事务，一定已被多数节点持久化，新 Leader 必然包含它。

### 2.4 ZAB vs Paxos vs Raft

| 维度 | ZAB | Paxos | Raft |
| --- | --- | --- | --- |
| 设计目标 | 原子广播 + 崩溃恢复 | 共识算法理论 | 共识算法工程化 |
| Leader | 选举产生，写唯一入口 | 可有多个提议者 | 选举产生，任期 Term |
| 顺序保证 | zxid 全局有序 | 依赖选主 | 日志索引 + Term |
| 可理解性 | 较复杂 | 难 | 最易 |
| 典型应用 | ZooKeeper | Chubby（论文） | Etcd、Consul |

## 三、Watcher 机制：ZooKeeper 的"订阅-通知"

Watcher 是 ZK 客户端监听数据变化的机制，也是面试重灾区。

### 3.1 工作机制

```java
// 客户端注册监听
zooKeeper.getData("/apps/config/db.yml", new Watcher() {
    @Override
    public void process(WatchedEvent event) {
        // 节点数据变化时回调
        log.info("节点变化: type={}, path={}", event.getType(), event.getPath());
    }
}, null);
```

流程：

```
客户端注册 Watcher → 服务端把 Watcher 存到对应 ZNode 的 watch 集合
  → 节点数据变化（setData/delete/create）
  → 服务端把事件通知发送给客户端（异步、不携带数据）
  → 客户端回调 process()，之后 Watcher 自动失效
```

### 3.2 三大特性（必须记住）

1. **一次性触发**：Watcher 触发一次后立即失效，需要业务代码**重新注册**。这是最常见的坑——漏掉重注册，监听就永久失效了；
2. **异步通知**：服务端发送通知与客户端回调之间存在窗口期，客户端拿到的可能是旧数据，**回调里应重新 getData 拉取最新值**；
3. **轻量级**：事件通知只带 `(type, path, state)`，不带数据内容，避免大对象传输。

### 3.3 Watcher 事件类型

| 事件类型 | 触发场景 |
| --- | --- |
| `NodeCreated` | 节点被创建 |
| `NodeDeleted` | 节点被删除 |
| `NodeDataChanged` | 节点数据被修改 |
| `NodeChildrenChanged` | 子节点新增/删除 |
| `None` | 连接状态变化（SessionExpired / AuthFailed 等） |

## 四、会话管理：临时节点的生命周期

- 客户端创建连接时发起 Session 创建请求，获得 `sessionId` 与超时时间（`sessionTimeout`）；
- 客户端通过**心跳（ping）**维持会话，服务端按 `tickTime` 检查会话活跃度；
- 会话超时（`sessionTimeout`）后，该会话创建的**所有临时节点被自动清理**，同时触发对应 Watcher；
- `SessionExpired` 与 `ConnectionLoss` 的区别：前者是会话真的没了（临时节点已删），后者是连接断了但会话可能还在——**遇到 SessionExpired 必须重建会话并重新注册所有临时节点**。

## 五、实战：基于 ZooKeeper 的分布式锁

### 5.1 非公平锁（临时节点，简单但容易羊群效应）

```java
public boolean tryLock(String lockPath) throws Exception {
    try {
        zooKeeper.create(lockPath, new byte[0],
                ZooDefs.Ids.OPEN_ACL_UNSAFE, CreateMode.EPHEMERAL);
        return true;   // 创建成功即拿到锁
    } catch (KeeperException.NodeExistsException e) {
        return false;  // 节点已存在，锁被占用
    }
}
```

问题：锁释放（节点删除）时，所有等待者同时被唤醒去抢——**羊群效应**。

### 5.2 公平锁（临时顺序节点 + 最小序号监听，推荐）

```java
public class ZkDistributedLock {
    private final ZooKeeper zooKeeper;
    private final String lockRoot = "/locks";
    private String currentPath;

    public boolean tryLock(String lockName, long timeout) throws Exception {
        // 1. 创建临时顺序节点
        currentPath = zooKeeper.create(lockRoot + "/" + lockName + "-",
                new byte[0], ZooDefs.Ids.OPEN_ACL_UNSAFE,
                CreateMode.EPHEMERAL_SEQUENTIAL);

        // 2. 获取所有兄弟节点
        List<String> children = zooKeeper.getChildren(lockRoot, false);
        List<String> sorted = children.stream()
                .filter(c -> c.startsWith(lockName + "-"))
                .sorted().collect(Collectors.toList());

        // 3. 自己是最小序号 → 拿到锁
        String myName = currentPath.substring(currentPath.lastIndexOf('/') + 1);
        if (myName.equals(sorted.get(0))) {
            return true;
        }

        // 4. 监听前一个节点，等待其释放
        String prevPath = lockRoot + "/" + sorted.get(sorted.indexOf(myName) - 1);
        CountDownLatch latch = new CountDownLatch(1);
        zooKeeper.exists(prevPath, event -> latch.countDown());
        return latch.await(timeout, TimeUnit.MILLISECONDS);
    }

    public void unlock() throws Exception {
        zooKeeper.delete(currentPath, -1);  // 删除节点即释放锁
    }
}
```

公平锁的好处：每个等待者只监听**前一个节点**，释放时只唤醒一个节点，避免了羊群效应；缺点是每个锁操作有多次 RTT，性能一般。

**生产建议**：纯 ZK 锁性能有限（每秒几百次级别），高并发场景优先 Redis/Redisson 分布式锁；需要**强一致 + 可重入 + 无羊群效应**的场景（如跨机房协调、元数据操作）才用 ZK 锁。

## 六、典型应用场景总结

| 场景 | 实现思路 |
| --- | --- |
| 服务注册发现（Dubbo） | 服务提供者创建临时节点，消费者监听子节点变化 |
| 分布式配置 | 持久节点存配置，客户端注册 Watcher 实时感知变更 |
| Leader 选举 | 抢临时节点，抢到者当 Leader，节点删除触发重新选举 |
| 分布式锁 | 临时顺序节点 + 最小序号（如上） |
| 分布式队列 | 顺序节点 + 序号消费 |
| 元数据存储（Kafka） | broker 注册、topic 分区元数据、Controller 选举 |

## 七、面试常见追问

**Q1：为什么 ZK 不适合存大量数据？**
数据全量在内存，节点过多/数据过大导致 GC 压力大、同步慢，写性能急剧下降。官方建议单节点数据量控制在几百 MB 内，单条数据不超过 1MB。

**Q2：Watcher 监听为什么只能触发一次？**
设计如此：避免客户端长期持有大量 Watcher 造成服务端内存膨胀和通知风暴。所以业务代码必须在回调里重新注册，或使用 Curator 的 `PathChildrenCache` / `TreeCache` 帮你自动重注册。

**Q3：ZAB 和 Raft 都要求多数派，集群最少几台？**
3 台（允许挂 1 台）；生产建议 5 台（允许挂 2 台，且支持滚动升级）。偶数节点没意义——2 台挂 1 台就没法过半，不如 3 台。

**Q4：客户端连接断了，临时节点会立即删除吗？**
不会。连接断开后进入重连窗口（`sessionTimeout` 内），期间节点保留；超过 `sessionTimeout` 未恢复才判定会话过期并删除节点。

**Q5：ZK 读写性能如何？**
读性能好（Follower/Observer 均可读，天然支持水平扩展读）；写性能差（所有写必须经 Leader 广播且过半落盘）。所以"读多写少"的协调元数据是 ZK 的舒适区。

## 总结

ZooKeeper 的核心就三件事：**一棵内存 ZNode 树（数据模型）、ZAB 协议（一致性）、Watcher（变更通知）**。理解 ZAB 的"过半提交 + zxid 有序 + 崩溃恢复丢弃未确认事务"，理解 Watcher 的"一次性 + 异步 + 轻量"，再亲手实现一把公平锁，ZooKeeper 相关的面试题和实战就都能拿下了。
